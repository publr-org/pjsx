//! Context-sensitive TSX scanner. The parser drives every ambiguous rescan
//! (regex vs. division, template continuations, JSX text/tag tokens) the way
//! TypeScript's scanner does, so the lexer itself stays stateless apart from
//! its position — which makes speculative parsing a save/restore of `pos`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const err = @import("err.zig");

pub const TokenKind = enum {
    eof,
    identifier, // includes keywords; the parser inspects `text`
    private_name, // #name
    number,
    bigint,
    string,
    template_no_subst, // `…`
    template_head, // `…${
    template_middle, // }…${
    template_tail, // }…`
    regex,
    jsx_text,
    punct,
};

pub const Token = struct {
    kind: TokenKind = .eof,
    start: u32 = 0,
    end: u32 = 0,
    /// Decoded payload: identifier text, string/cooked template value, punctuator text.
    text: []const u8 = "",
    /// Cooked template value is invalid (bad escape) — only allowed in tagged templates.
    cooked_invalid: bool = false,
    number: f64 = 0,
    newline_before: bool = false,

    pub fn is(self: Token, text: []const u8) bool {
        return (self.kind == .punct or self.kind == .identifier) and std.mem.eql(u8, self.text, text);
    }
    pub fn isPunct(self: Token, text: []const u8) bool {
        return self.kind == .punct and std.mem.eql(u8, self.text, text);
    }
    pub fn isIdent(self: Token, text: []const u8) bool {
        return self.kind == .identifier and std.mem.eql(u8, self.text, text);
    }
};

pub const State = struct { pos: u32, token: Token };

pub const Lexer = struct {
    allocator: Allocator,
    src: []const u8,
    pos: u32 = 0,
    token: Token = .{},

    pub fn init(allocator: Allocator, src: []const u8) Lexer {
        return .{ .allocator = allocator, .src = src };
    }

    pub fn save(self: *const Lexer) State {
        return .{ .pos = self.pos, .token = self.token };
    }

    pub fn restore(self: *Lexer, state: State) void {
        self.pos = state.pos;
        self.token = state.token;
    }

    fn peekByte(self: *const Lexer, offset: u32) u8 {
        const at = self.pos + offset;
        return if (at < self.src.len) self.src[at] else 0;
    }

    fn fail(self: *const Lexer, comptime fmt: []const u8, args: anytype) err.Error {
        _ = self;
        return err.fail(fmt, args);
    }

    /// Skip whitespace and comments; report whether a line terminator was crossed.
    fn skipTrivia(self: *Lexer) err.Error!bool {
        var newline = false;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', 0x0b, 0x0c => self.pos += 1,
                '\n', '\r' => {
                    newline = true;
                    self.pos += 1;
                },
                '/' => {
                    if (self.peekByte(1) == '/') {
                        while (self.pos < self.src.len and self.src[self.pos] != '\n' and self.src[self.pos] != '\r') self.pos += 1;
                    } else if (self.peekByte(1) == '*') {
                        const close = std.mem.indexOfPos(u8, self.src, self.pos + 2, "*/") orelse
                            return self.fail("Unterminated multi-line comment", .{});
                        if (std.mem.indexOfAny(u8, self.src[self.pos..close], "\n\r") != null) newline = true;
                        self.pos = @intCast(close + 2);
                    } else return newline;
                },
                0xe2 => {
                    // U+2028 / U+2029 line separators
                    if (self.peekByte(1) == 0x80 and (self.peekByte(2) == 0xa8 or self.peekByte(2) == 0xa9)) {
                        newline = true;
                        self.pos += 3;
                    } else return newline;
                },
                0xc2 => {
                    if (self.peekByte(1) == 0xa0) self.pos += 2 else return newline; // NBSP
                },
                0xef => {
                    if (self.peekByte(1) == 0xbb and self.peekByte(2) == 0xbf) self.pos += 3 else return newline; // BOM
                },
                else => return newline,
            }
        }
        return newline;
    }

    pub fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c >= 0x80;
    }

    pub fn isIdentPart(c: u8) bool {
        return isIdentStart(c) or std.ascii.isDigit(c);
    }

    /// Scan the next token in expression/statement context.
    pub fn next(self: *Lexer) err.Error!Token {
        const newline = try self.skipTrivia();
        var tok = Token{ .start = self.pos, .newline_before = newline };
        if (self.pos >= self.src.len) {
            tok.kind = .eof;
            tok.end = self.pos;
            self.token = tok;
            return tok;
        }
        const c = self.src[self.pos];
        if (isIdentStart(c) or c == '\\') {
            if (c == '\\' and self.peekByte(1) != 'u') return self.fail("Invalid or unexpected token", .{});
            tok.kind = .identifier;
            tok.text = try self.scanIdentifier();
        } else if (c == '#' and isIdentStart(self.peekByte(1))) {
            self.pos += 1;
            tok.kind = .private_name;
            tok.text = try self.scanIdentifier();
        } else if (std.ascii.isDigit(c) or (c == '.' and std.ascii.isDigit(self.peekByte(1)))) {
            try self.scanNumber(&tok);
        } else if (c == '"' or c == '\'') {
            tok.kind = .string;
            tok.text = try self.scanString(c);
        } else if (c == '`') {
            self.pos += 1;
            try self.scanTemplateSpan(&tok, true);
        } else {
            tok.kind = .punct;
            tok.text = self.scanPunct();
        }
        tok.end = self.pos;
        self.token = tok;
        return tok;
    }

    fn scanIdentifier(self: *Lexer) err.Error![]const u8 {
        const start = self.pos;
        var has_escape = false;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (isIdentPart(c)) {
                self.pos += 1;
            } else if (c == '\\' and self.peekByte(1) == 'u') {
                has_escape = true;
                self.pos += 2;
                if (self.peekByte(0) == '{') {
                    while (self.pos < self.src.len and self.src[self.pos] != '}') self.pos += 1;
                    self.pos += 1;
                } else self.pos += 4;
            } else break;
        }
        const raw = self.src[start..self.pos];
        if (!has_escape) return raw;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\') {
                i += 2;
                const cp = try self.readUnicodeEscape(raw, &i);
                try appendCodepoint(self.allocator, &out, cp);
            } else {
                try out.append(self.allocator, raw[i]);
                i += 1;
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn readUnicodeEscape(self: *Lexer, raw: []const u8, i: *usize) err.Error!u21 {
        if (i.* < raw.len and raw[i.*] == '{') {
            i.* += 1;
            const close = std.mem.indexOfScalarPos(u8, raw, i.*, '}') orelse return self.fail("Invalid Unicode escape sequence", .{});
            const cp = std.fmt.parseInt(u21, raw[i.*..close], 16) catch return self.fail("Invalid Unicode escape sequence", .{});
            i.* = close + 1;
            return cp;
        }
        if (i.* + 4 > raw.len) return self.fail("Invalid Unicode escape sequence", .{});
        const cp = std.fmt.parseInt(u21, raw[i.* .. i.* + 4], 16) catch return self.fail("Invalid Unicode escape sequence", .{});
        i.* += 4;
        return cp;
    }

    fn scanNumber(self: *Lexer, tok: *Token) err.Error!void {
        const start = self.pos;
        tok.kind = .number;
        const c = self.src[self.pos];
        if (c == '0' and (self.peekByte(1) == 'x' or self.peekByte(1) == 'X' or self.peekByte(1) == 'o' or self.peekByte(1) == 'O' or self.peekByte(1) == 'b' or self.peekByte(1) == 'B')) {
            const base: u8 = switch (self.peekByte(1) | 0x20) {
                'x' => 16,
                'o' => 8,
                else => 2,
            };
            self.pos += 2;
            const digits_start = self.pos;
            while (self.pos < self.src.len and (std.ascii.isHex(self.src[self.pos]) or self.src[self.pos] == '_')) self.pos += 1;
            const digits = try stripUnderscores(self.allocator, self.src[digits_start..self.pos]);
            if (self.peekByte(0) == 'n') {
                self.pos += 1;
                tok.kind = .bigint;
                tok.text = self.src[start..self.pos];
                return;
            }
            tok.number = @floatFromInt(std.fmt.parseInt(u128, digits, base) catch 0);
            tok.text = self.src[start..self.pos];
            return;
        }
        while (self.pos < self.src.len and (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '_')) self.pos += 1;
        if (self.peekByte(0) == 'n') {
            self.pos += 1;
            tok.kind = .bigint;
            tok.text = self.src[start..self.pos];
            return;
        }
        if (self.peekByte(0) == '.') {
            self.pos += 1;
            while (self.pos < self.src.len and (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '_')) self.pos += 1;
        }
        if (self.peekByte(0) == 'e' or self.peekByte(0) == 'E') {
            const saved = self.pos;
            self.pos += 1;
            if (self.peekByte(0) == '+' or self.peekByte(0) == '-') self.pos += 1;
            if (std.ascii.isDigit(self.peekByte(0))) {
                while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
            } else self.pos = saved;
        }
        if (isIdentStart(self.peekByte(0))) return self.fail("Invalid number", .{});
        tok.text = self.src[start..self.pos];
        const digits = try stripUnderscores(self.allocator, tok.text);
        // Legacy octal (e.g. 010) is not supported in modules; parse as decimal.
        tok.number = std.fmt.parseFloat(f64, digits) catch return self.fail("Invalid number", .{});
    }

    fn stripUnderscores(allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
        if (std.mem.indexOfScalar(u8, text, '_') == null) return text;
        var out: std.ArrayList(u8) = .empty;
        for (text) |c| if (c != '_') try out.append(allocator, c);
        return out.toOwnedSlice(allocator);
    }

    fn scanString(self: *Lexer, quote: u8) err.Error![]const u8 {
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.pos >= self.src.len) return self.fail("Unterminated string", .{});
            const c = self.src[self.pos];
            if (c == quote) {
                self.pos += 1;
                break;
            }
            if (c == '\n' or c == '\r') return self.fail("Unterminated string", .{});
            if (c == '\\') {
                self.pos += 1;
                _ = try self.scanEscape(&out, false);
                continue;
            }
            try out.append(self.allocator, c);
            self.pos += 1;
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// Scan one escape (after the backslash). Returns false if the escape is
    /// invalid (only tolerated in tagged templates).
    fn scanEscape(self: *Lexer, out: *std.ArrayList(u8), template: bool) err.Error!bool {
        if (self.pos >= self.src.len) return self.fail("Unterminated string", .{});
        const c = self.src[self.pos];
        self.pos += 1;
        switch (c) {
            'n' => try out.append(self.allocator, '\n'),
            't' => try out.append(self.allocator, '\t'),
            'r' => try out.append(self.allocator, '\r'),
            'b' => try out.append(self.allocator, 0x08),
            'f' => try out.append(self.allocator, 0x0c),
            'v' => try out.append(self.allocator, 0x0b),
            '0' => {
                if (std.ascii.isDigit(self.peekByte(0))) {
                    if (template) return false;
                    return self.fail("Octal escape sequences are not allowed", .{});
                }
                try out.append(self.allocator, 0);
            },
            'x' => {
                if (self.pos + 2 > self.src.len) return self.fail("Invalid hexadecimal escape sequence", .{});
                const value = std.fmt.parseInt(u8, self.src[self.pos .. self.pos + 2], 16) catch {
                    if (template) return false;
                    return self.fail("Invalid hexadecimal escape sequence", .{});
                };
                self.pos += 2;
                try appendCodepoint(self.allocator, out, value);
            },
            'u' => {
                var i: usize = self.pos;
                const cp = self.readUnicodeEscape(self.src, &i) catch {
                    if (template) return false;
                    return self.fail("Invalid Unicode escape sequence", .{});
                };
                self.pos = @intCast(i);
                // Surrogate pair: 😀
                if (cp >= 0xd800 and cp <= 0xdbff and self.peekByte(0) == '\\' and self.peekByte(1) == 'u') {
                    var j: usize = self.pos + 2;
                    if (self.readUnicodeEscape(self.src, &j)) |low| {
                        if (low >= 0xdc00 and low <= 0xdfff) {
                            self.pos = @intCast(j);
                            const combined: u21 = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                            try appendCodepoint(self.allocator, out, combined);
                            return true;
                        }
                    } else |_| {}
                }
                try appendCodepoint(self.allocator, out, cp);
            },
            '\r' => {
                if (self.peekByte(0) == '\n') self.pos += 1;
            },
            '\n' => {},
            '1'...'9' => {
                if (template) return false;
                return self.fail("Octal escape sequences are not allowed", .{});
            },
            else => try out.append(self.allocator, c),
        }
        return true;
    }

    /// Scan a template span starting after '`' or after the '}' closing a substitution.
    fn scanTemplateSpan(self: *Lexer, tok: *Token, head: bool) err.Error!void {
        var out: std.ArrayList(u8) = .empty;
        var invalid = false;
        while (true) {
            if (self.pos >= self.src.len) return self.fail("Unterminated template literal", .{});
            const c = self.src[self.pos];
            if (c == '`') {
                self.pos += 1;
                tok.kind = if (head) .template_no_subst else .template_tail;
                break;
            }
            if (c == '$' and self.peekByte(1) == '{') {
                self.pos += 2;
                tok.kind = if (head) .template_head else .template_middle;
                break;
            }
            if (c == '\\') {
                self.pos += 1;
                if (!try self.scanEscape(&out, true)) invalid = true;
                continue;
            }
            if (c == '\r') {
                // Normalize CRLF / CR to LF in cooked and raw
                self.pos += 1;
                if (self.peekByte(0) == '\n') self.pos += 1;
                try out.append(self.allocator, '\n');
                continue;
            }
            try out.append(self.allocator, c);
            self.pos += 1;
        }
        tok.text = try out.toOwnedSlice(self.allocator);
        tok.cooked_invalid = invalid;
    }

    /// Called by the parser when the current token is `}` closing a template substitution.
    pub fn rescanTemplateContinuation(self: *Lexer) err.Error!Token {
        std.debug.assert(self.token.isPunct("}"));
        self.pos = self.token.start + 1;
        var tok = Token{ .start = self.token.start };
        try self.scanTemplateSpan(&tok, false);
        tok.end = self.pos;
        self.token = tok;
        return tok;
    }

    /// Called by the parser when a `/` or `/=` token begins an expression.
    pub fn rescanRegex(self: *Lexer) err.Error!Token {
        std.debug.assert(self.token.kind == .punct and self.token.text[0] == '/');
        const start = self.token.start;
        self.pos = start + 1;
        var in_class = false;
        while (true) {
            if (self.pos >= self.src.len) return self.fail("Unterminated regular expression", .{});
            const c = self.src[self.pos];
            if (c == '\n' or c == '\r') return self.fail("Unterminated regular expression", .{});
            if (c == '\\') {
                self.pos += 2;
                continue;
            }
            if (c == '[') in_class = true;
            if (c == ']') in_class = false;
            if (c == '/' and !in_class) {
                self.pos += 1;
                break;
            }
            self.pos += 1;
        }
        while (self.pos < self.src.len and isIdentPart(self.src[self.pos])) self.pos += 1;
        const tok = Token{ .kind = .regex, .start = start, .end = self.pos, .text = self.src[start..self.pos], .newline_before = self.token.newline_before };
        self.token = tok;
        return tok;
    }

    fn scanPunct(self: *Lexer) []const u8 {
        const rest = self.src[self.pos..];
        const candidates = [_][]const u8{
            ">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=",
            "=>",   "==",  "!=",  "<=",  ">=",  "&&",  "||",  "??",  "?.",  "++",  "--",
            "+=",   "-=",  "*=",  "/=",  "%=",  "&=",  "|=",  "^=",  "**",  "<<",  ">>",
        };
        for (candidates) |candidate| {
            if (std.mem.startsWith(u8, rest, candidate)) {
                // `?.` followed by a digit is `?` then `.5`
                if (std.mem.eql(u8, candidate, "?.") and rest.len > 2 and std.ascii.isDigit(rest[2])) continue;
                self.pos += @intCast(candidate.len);
                return candidate;
            }
        }
        self.pos += 1;
        return rest[0..1];
    }

    // ── JSX ────────────────────────────────────────────────────────────────

    /// Scan a token inside a JSX tag: single-char punctuators, dashed identifiers, raw strings.
    pub fn nextJsxTag(self: *Lexer) err.Error!Token {
        const newline = try self.skipTrivia();
        var tok = Token{ .start = self.pos, .newline_before = newline };
        if (self.pos >= self.src.len) {
            tok.kind = .eof;
            tok.end = self.pos;
            self.token = tok;
            return tok;
        }
        const c = self.src[self.pos];
        if (isIdentStart(c)) {
            tok.kind = .identifier;
            const start = self.pos;
            while (self.pos < self.src.len and (isIdentPart(self.src[self.pos]) or self.src[self.pos] == '-')) self.pos += 1;
            tok.text = self.src[start..self.pos];
        } else if (c == '"' or c == '\'') {
            tok.kind = .string;
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != c) self.pos += 1;
            if (self.pos >= self.src.len) return self.fail("Unterminated JSX attribute string", .{});
            tok.text = try decodeEntities(self.allocator, self.src[start..self.pos]);
            self.pos += 1;
        } else if (c == '{' or c == '}' or c == '<' or c == '>' or c == '/' or c == '=' or c == '.' or c == ':') {
            tok.kind = .punct;
            // `...` for spread attributes / children
            if (c == '.' and std.mem.startsWith(u8, self.src[self.pos..], "...")) {
                self.pos += 3;
                tok.text = "...";
            } else {
                self.pos += 1;
                tok.text = self.src[self.pos - 1 .. self.pos];
            }
        } else {
            return self.fail("Unexpected token in JSX", .{});
        }
        tok.end = self.pos;
        self.token = tok;
        return tok;
    }

    /// Scan a JSX child token: text up to `{` / `<`, or that punctuator.
    pub fn nextJsxChild(self: *Lexer) err.Error!Token {
        var tok = Token{ .start = self.pos };
        if (self.pos >= self.src.len) {
            tok.kind = .eof;
            tok.end = self.pos;
            self.token = tok;
            return tok;
        }
        const c = self.src[self.pos];
        if (c == '{' or c == '<') {
            tok.kind = .punct;
            self.pos += 1;
            tok.text = self.src[self.pos - 1 .. self.pos];
        } else {
            while (self.pos < self.src.len and self.src[self.pos] != '{' and self.src[self.pos] != '<') self.pos += 1;
            tok.kind = .jsx_text;
            tok.text = try decodeEntities(self.allocator, self.src[tok.start..self.pos]);
        }
        tok.end = self.pos;
        self.token = tok;
        return tok;
    }

    /// Reposition after a token was consumed in one mode so the next scan can use another.
    pub fn resetTo(self: *Lexer, pos: u32) void {
        self.pos = pos;
    }
};

pub fn appendCodepoint(allocator: Allocator, out: *std.ArrayList(u8), cp: u21) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch {
        // Lone surrogates: encode as WTF-8 replacement.
        try out.appendSlice(allocator, "\xef\xbf\xbd");
        return;
    };
    try out.appendSlice(allocator, buf[0..len]);
}

const named_entities = [_]struct { []const u8, u21 }{
    .{ "amp", '&' },      .{ "lt", '<' },       .{ "gt", '>' },       .{ "quot", '"' },      .{ "apos", '\'' },
    .{ "nbsp", 0xa0 },    .{ "copy", 0xa9 },    .{ "reg", 0xae },     .{ "hellip", 0x2026 }, .{ "mdash", 0x2014 },
    .{ "ndash", 0x2013 }, .{ "times", 0xd7 },   .{ "laquo", 0xab },   .{ "raquo", 0xbb },    .{ "rarr", 0x2192 },
    .{ "larr", 0x2190 },  .{ "bull", 0x2022 },  .{ "middot", 0xb7 },  .{ "trade", 0x2122 },  .{ "deg", 0xb0 },
    .{ "lsquo", 0x2018 }, .{ "rsquo", 0x2019 }, .{ "ldquo", 0x201c }, .{ "rdquo", 0x201d },  .{ "euro", 0x20ac },
};

/// Decode HTML character references in JSX text/attribute values.
pub fn decodeEntities(allocator: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, raw, i + 1, ';')) |semi| {
                const name = raw[i + 1 .. semi];
                if (name.len > 0 and name.len <= 10) {
                    var cp: ?u21 = null;
                    if (name[0] == '#') {
                        if (name.len > 1 and (name[1] == 'x' or name[1] == 'X')) {
                            cp = std.fmt.parseInt(u21, name[2..], 16) catch null;
                        } else {
                            cp = std.fmt.parseInt(u21, name[1..], 10) catch null;
                        }
                    } else {
                        for (named_entities) |entry| {
                            if (std.mem.eql(u8, entry[0], name)) cp = entry[1];
                        }
                    }
                    if (cp) |value| {
                        try appendCodepoint(allocator, &out, value);
                        i = semi + 1;
                        continue;
                    }
                }
            }
        }
        try out.append(allocator, raw[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "lexer scans strings, numbers, punctuators and templates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init(arena.allocator(), "const x = 'a\\n' + 0x10 ?? `t${y}u`; // c");
    const kinds = [_]TokenKind{ .identifier, .identifier, .punct, .string, .punct, .number, .punct, .template_head };
    for (kinds) |kind| {
        const tok = try lexer.next();
        try std.testing.expectEqual(kind, tok.kind);
    }
    try std.testing.expectEqualStrings("t", lexer.token.text);
    _ = try lexer.next(); // y
    _ = try lexer.next(); // }
    const tail = try lexer.rescanTemplateContinuation();
    try std.testing.expectEqual(TokenKind.template_tail, tail.kind);
    try std.testing.expectEqualStrings("u", tail.text);
    _ = try lexer.next(); // ;
    try std.testing.expectEqual(TokenKind.eof, (try lexer.next()).kind);
}

test "decodeEntities handles named and numeric references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try decodeEntities(arena.allocator(), "a &amp; b &#60; &#x3e; &unknown;");
    try std.testing.expectEqualStrings("a & b < > &unknown;", out);
}
