//! Test-only backtracking regex matcher covering the JavaScript regex subset
//! used by the original `node:test` suite, so every `assert.match(code, /…/)`
//! ports with its pattern verbatim instead of a hand-translated substring.
//!
//! Supported: literals and escapes (`\s \S \d \D \w \W \b \B \n \t` and any
//! escaped punctuation), `.`, character classes with ranges and negation,
//! groups `( )` / `(?: )` / `(?= )`, alternation, quantifiers `* + ? {n} {n,}
//! {n,m}` (greedy, plus lazy `?` suffix), anchors `^ $`, and the `s` flag.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Op = union(enum) {
    char: u8,
    any,
    class: Class,
    split: struct { primary: usize, secondary: usize },
    jmp: usize,
    bol,
    eol,
    word_boundary: bool, // true = \b, false = \B
    lookahead: struct { body: usize, next: usize },
    match,
};

const Class = struct {
    negated: bool,
    ranges: []const [2]u8,

    fn contains(self: Class, c: u8) bool {
        var hit = false;
        for (self.ranges) |range| {
            if (c >= range[0] and c <= range[1]) hit = true;
        }
        return hit != self.negated;
    }
};

const CompileError = error{ UnsupportedGroup, UnbalancedParen, UnbalancedClass, UnsupportedClassEscape, TrailingPattern, OutOfMemory };

const Compiler = struct {
    allocator: Allocator,
    pattern: []const u8,
    pos: usize = 0,
    code: std.ArrayList(Op) = .empty,
    dotall: bool,

    fn emit(self: *Compiler, op: Op) CompileError!usize {
        try self.code.append(self.allocator, op);
        return self.code.items.len - 1;
    }

    fn peek(self: *const Compiler) ?u8 {
        return if (self.pos < self.pattern.len) self.pattern[self.pos] else null;
    }

    /// alternation := sequence ('|' sequence)*
    fn compileAlternation(self: *Compiler) CompileError!void {
        var splits: std.ArrayList(usize) = .empty;
        var jumps: std.ArrayList(usize) = .empty;
        while (true) {
            const split_at = try self.emit(.{ .split = .{ .primary = 0, .secondary = 0 } });
            try splits.append(self.allocator, split_at);
            self.code.items[split_at].split.primary = self.code.items.len;
            try self.compileSequence();
            if (self.peek() == '|') {
                self.pos += 1;
                const jump_at = try self.emit(.{ .jmp = 0 });
                try jumps.append(self.allocator, jump_at);
                self.code.items[split_at].split.secondary = self.code.items.len;
            } else {
                // Last branch: make its split unconditional-ish by pointing secondary at primary.
                self.code.items[split_at].split.secondary = self.code.items[split_at].split.primary;
                break;
            }
        }
        for (jumps.items) |jump_at| self.code.items[jump_at].jmp = self.code.items.len;
    }

    fn compileSequence(self: *Compiler) CompileError!void {
        while (self.peek()) |c| {
            if (c == '|' or c == ')') return;
            try self.compileTerm();
        }
    }

    fn compileTerm(self: *Compiler) CompileError!void {
        const start = self.code.items.len;
        const c = self.pattern[self.pos];
        self.pos += 1;
        switch (c) {
            '(' => {
                var lookahead = false;
                if (self.peek() == '?') {
                    self.pos += 1;
                    const kind = self.pattern[self.pos];
                    self.pos += 1;
                    if (kind == '=') lookahead = true else if (kind != ':') return error.UnsupportedGroup;
                }
                if (lookahead) {
                    const la = try self.emit(.{ .lookahead = .{ .body = 0, .next = 0 } });
                    self.code.items[la].lookahead.body = self.code.items.len;
                    try self.compileAlternation();
                    _ = try self.emit(.match);
                    self.code.items[la].lookahead.next = self.code.items.len;
                } else {
                    try self.compileAlternation();
                }
                if (self.peek() != ')') return error.UnbalancedParen;
                self.pos += 1;
            },
            '[' => try self.compileClass(),
            '.' => {
                if (self.dotall) {
                    _ = try self.emit(.any);
                } else {
                    _ = try self.emit(.{ .class = .{ .negated = true, .ranges = &.{.{ '\n', '\n' }} } });
                }
            },
            '^' => _ = try self.emit(.bol),
            '$' => _ = try self.emit(.eol),
            '\\' => try self.compileEscape(false),
            else => _ = try self.emit(.{ .char = c }),
        }
        try self.compileQuantifier(start);
    }

    fn escapeClass(c: u8) ?Class {
        return switch (c) {
            's' => .{ .negated = false, .ranges = &.{ .{ ' ', ' ' }, .{ '\t', '\r' } } },
            'S' => .{ .negated = true, .ranges = &.{ .{ ' ', ' ' }, .{ '\t', '\r' } } },
            'd' => .{ .negated = false, .ranges = &.{.{ '0', '9' }} },
            'D' => .{ .negated = true, .ranges = &.{.{ '0', '9' }} },
            'w' => .{ .negated = false, .ranges = &.{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '_', '_' } } },
            'W' => .{ .negated = true, .ranges = &.{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '_', '_' } } },
            else => null,
        };
    }

    fn escapeChar(c: u8) u8 {
        return switch (c) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'f' => 0x0c,
            'v' => 0x0b,
            else => c,
        };
    }

    fn compileEscape(self: *Compiler, in_class: bool) CompileError!void {
        const c = self.pattern[self.pos];
        self.pos += 1;
        if (!in_class and c == 'b') {
            _ = try self.emit(.{ .word_boundary = true });
            return;
        }
        if (!in_class and c == 'B') {
            _ = try self.emit(.{ .word_boundary = false });
            return;
        }
        if (escapeClass(c)) |class| {
            _ = try self.emit(.{ .class = class });
            return;
        }
        _ = try self.emit(.{ .char = escapeChar(c) });
    }

    fn compileClass(self: *Compiler) CompileError!void {
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.pos += 1;
        }
        var ranges: std.ArrayList([2]u8) = .empty;
        var first = true;
        while (true) {
            const c = self.peek() orelse return error.UnbalancedClass;
            if (c == ']' and !first) break;
            first = false;
            self.pos += 1;
            var lo: u8 = c;
            if (c == '\\') {
                const e = self.pattern[self.pos];
                self.pos += 1;
                if (escapeClass(e)) |class| {
                    if (class.negated) return error.UnsupportedClassEscape;
                    for (class.ranges) |range| try ranges.append(self.allocator, range);
                    continue;
                }
                lo = escapeChar(e);
            }
            var hi = lo;
            if (self.peek() == '-' and self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] != ']') {
                self.pos += 1;
                hi = self.pattern[self.pos];
                self.pos += 1;
                if (hi == '\\') {
                    hi = escapeChar(self.pattern[self.pos]);
                    self.pos += 1;
                }
            }
            try ranges.append(self.allocator, .{ lo, hi });
        }
        self.pos += 1; // ]
        _ = try self.emit(.{ .class = .{ .negated = negated, .ranges = try ranges.toOwnedSlice(self.allocator) } });
    }

    fn compileQuantifier(self: *Compiler, start: usize) CompileError!void {
        const q = self.peek() orelse return;
        var min: usize = 0;
        var max: ?usize = null;
        switch (q) {
            '*' => {
                self.pos += 1;
            },
            '+' => {
                self.pos += 1;
                min = 1;
            },
            '?' => {
                self.pos += 1;
                max = 1;
            },
            '{' => {
                const close = std.mem.indexOfScalarPos(u8, self.pattern, self.pos, '}') orelse return;
                const body = self.pattern[self.pos + 1 .. close];
                if (std.mem.indexOfScalar(u8, body, ',')) |comma| {
                    min = std.fmt.parseInt(usize, body[0..comma], 10) catch return;
                    max = if (comma + 1 < body.len) (std.fmt.parseInt(usize, body[comma + 1 ..], 10) catch return) else null;
                } else {
                    min = std.fmt.parseInt(usize, body, 10) catch return;
                    max = min;
                }
                self.pos = close + 1;
            },
            else => return,
        }
        var lazy = false;
        if (self.peek() == '?') {
            lazy = true;
            self.pos += 1;
        }
        const atom = try self.allocator.dupe(Op, self.code.items[start..]);
        self.code.shrinkRetainingCapacity(start);
        // Required repetitions.
        for (0..min) |_| try self.appendAtom(atom, start);
        if (max) |m| {
            // Optional repetitions: (atom)? repeated (m - min) times.
            for (0..m - min) |_| {
                const split_at = try self.emit(.{ .split = .{ .primary = 0, .secondary = 0 } });
                const body = self.code.items.len;
                try self.appendAtom(atom, start);
                const after = self.code.items.len;
                self.code.items[split_at].split = if (lazy) .{ .primary = after, .secondary = body } else .{ .primary = body, .secondary = after };
            }
        } else {
            // Star loop.
            const split_at = try self.emit(.{ .split = .{ .primary = 0, .secondary = 0 } });
            const body = self.code.items.len;
            try self.appendAtom(atom, start);
            _ = try self.emit(.{ .jmp = split_at });
            const after = self.code.items.len;
            self.code.items[split_at].split = if (lazy) .{ .primary = after, .secondary = body } else .{ .primary = body, .secondary = after };
        }
    }

    /// Append a copy of an atom's instructions, relocating absolute jump targets.
    fn appendAtom(self: *Compiler, atom: []const Op, original_start: usize) CompileError!void {
        const delta: isize = @as(isize, @intCast(self.code.items.len)) - @as(isize, @intCast(original_start));
        for (atom) |op| {
            const relocated: Op = switch (op) {
                .split => |s| .{ .split = .{ .primary = reloc(s.primary, delta), .secondary = reloc(s.secondary, delta) } },
                .jmp => |target| .{ .jmp = reloc(target, delta) },
                .lookahead => |l| .{ .lookahead = .{ .body = reloc(l.body, delta), .next = reloc(l.next, delta) } },
                else => op,
            };
            _ = try self.emit(relocated);
        }
    }

    fn reloc(target: usize, delta: isize) usize {
        return @intCast(@as(isize, @intCast(target)) + delta);
    }
};

pub const Regex = struct {
    code: []const Op,

    pub fn compile(allocator: Allocator, pattern: []const u8, flags: []const u8) CompileError!Regex {
        var compiler = Compiler{ .allocator = allocator, .pattern = pattern, .dotall = std.mem.indexOfScalar(u8, flags, 's') != null };
        try compiler.compileAlternation();
        if (compiler.pos != pattern.len) return error.TrailingPattern;
        _ = try compiler.emit(.match);
        return .{ .code = try compiler.code.toOwnedSlice(allocator) };
    }

    fn isWord(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    /// Returns the end position of a match starting at `pos`, or null.
    fn run(self: Regex, text: []const u8, pc_start: usize, pos_start: usize, depth: usize) ?usize {
        var pc = pc_start;
        var pos = pos_start;
        if (depth > 20000) return null;
        while (true) {
            switch (self.code[pc]) {
                .char => |c| {
                    if (pos >= text.len or text[pos] != c) return null;
                    pos += 1;
                    pc += 1;
                },
                .any => {
                    if (pos >= text.len) return null;
                    pos += 1;
                    pc += 1;
                },
                .class => |class| {
                    if (pos >= text.len or !class.contains(text[pos])) return null;
                    pos += 1;
                    pc += 1;
                },
                .split => |s| {
                    if (s.primary == s.secondary) {
                        pc = s.primary;
                        continue;
                    }
                    if (self.run(text, s.primary, pos, depth + 1)) |end| return end;
                    pc = s.secondary;
                },
                .jmp => |target| pc = target,
                .bol => {
                    if (pos != 0) return null;
                    pc += 1;
                },
                .eol => {
                    if (pos != text.len) return null;
                    pc += 1;
                },
                .word_boundary => |expect| {
                    const before = pos > 0 and isWord(text[pos - 1]);
                    const after = pos < text.len and isWord(text[pos]);
                    if ((before != after) != expect) return null;
                    pc += 1;
                },
                .lookahead => |l| {
                    if (self.run(text, l.body, pos, depth + 1) == null) return null;
                    pc = l.next;
                },
                .match => return pos,
            }
        }
    }

    /// First match at or after `from`: returns `.{ start, end }`.
    pub fn search(self: Regex, text: []const u8, from: usize) ?[2]usize {
        var start = from;
        while (start <= text.len) : (start += 1) {
            if (self.run(text, 0, start, 0)) |end| return .{ start, end };
        }
        return null;
    }

    pub fn matches(self: Regex, text: []const u8) bool {
        return self.search(text, 0) != null;
    }

    /// Number of non-overlapping matches (`(text.match(/…/g) ?? []).length`).
    pub fn count(self: Regex, text: []const u8) usize {
        var n: usize = 0;
        var from: usize = 0;
        while (self.search(text, from)) |found| {
            n += 1;
            from = if (found[1] > found[0]) found[1] else found[1] + 1;
        }
        return n;
    }
};

/// `assert.match(text, /pattern/flags)`
pub fn expectMatch(text: []const u8, comptime pattern: []const u8, comptime flags: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const re = try Regex.compile(arena.allocator(), pattern, flags);
    if (!re.matches(text)) {
        std.debug.print("\nexpected /{s}/{s} to match:\n{s}\n", .{ pattern, flags, text });
        return error.TestExpectedMatch;
    }
}

/// `assert.doesNotMatch(text, /pattern/flags)`
pub fn expectNoMatch(text: []const u8, comptime pattern: []const u8, comptime flags: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const re = try Regex.compile(arena.allocator(), pattern, flags);
    if (re.matches(text)) {
        std.debug.print("\nexpected /{s}/{s} NOT to match:\n{s}\n", .{ pattern, flags, text });
        return error.TestUnexpectedMatch;
    }
}

pub fn matchCount(text: []const u8, comptime pattern: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const re = try Regex.compile(arena.allocator(), pattern, "g");
    return re.count(text);
}

test "regex subset matches the suite's patterns" {
    try expectMatch("import { h } from \"publr/dom\";", "import \\{ h \\} from \"publr/dom\"", "");
    try expectMatch("h(\n  \"span\"", "h\\(\\s*\"span\"", "");
    try expectMatch("class: () => [\"w-full rounded-md\", $$p.classes ?? \"\"]", "class: \\(\\) => \\[\"w-full rounded-md\", \\$\\$p\\.classes \\?\\? \"\"\\]", "");
    try expectMatch("<p data-variant=", "<(?:p|strong|span)[^>]*\\sdata-variant=", "");
    try expectNoMatch("<p data-variant=\"x\">", "<(?:p|strong|span)[^>]*\\sas=", "");
    try expectMatch("<h3 >", "<h3[ >]", "");
    try expectMatch("a\nb foo", "a.*foo", "s");
    try expectNoMatch("a\nb foo", "a.*foo", "");
    try expectMatch("get children() {\n  return $$p.state.label;\n}", "get children\\(\\) \\{\\s*return \\$\\$p\\.state\\.label;\\s*\\}", "");
    try expectMatch("DomOutput", "\\b(?:DomOutput|ZsxOutput|ReactTarget|ZigTarget)\\b", "");
    try expectNoMatch("MyDomOutputs", "\\b(?:DomOutput|ZsxOutput)\\b", "");
    try expectMatch("from './targets/dom'", "from [\"']\\./targets/", "");
    try std.testing.expectEqual(@as(usize, 2), try matchCount(".@\"data-p-bind\" x .@\"data-p-bind\"", "\\.@\"data-p-bind\""));
    try expectMatch("@click=\"toggle\"", "@click=\"toggle\"", "");
    try expectMatch("x = 5", "^x = \\d+$", "");
    try expectMatch("abbb", "ab{2,3}$", "");
    try expectNoMatch("ab", "ab{2,3}$", "");
}
