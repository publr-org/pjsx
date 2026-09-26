//! Dialect canonicalizer (.ptsx/.pjsx) — rewrites the illegal-in-TSX attribute
//! spellings into parseable TSX attribute names, leaving everything else
//! byte-identical. This is the FIRST of the two compile stages; the output
//! parses with any TSX parser and is what the type-checker sees.
//!
//!   @click.prevent={h}        → $$on$click$prevent={h}
//!   :show={cond}              → $$show={cond}
//!   :key={k}                  → $$key={k}
//!   :class={v}                → $$class={v}
//!   :text={v}                 → $$text={v}
//!   :html={v}                 → $$html={v}
//!   :aria-label={v}           → $$b$aria-label={v}     (generic binding)
//!   :for={item of state.xs}   → $$for={(item) => (state.xs)}
//!
//! The scanner is string/comment/template aware so these patterns are never
//! rewritten inside literals. A rewrite candidate must be preceded by
//! whitespace and immediately followed by `={` — patterns that cannot occur in
//! valid TS expressions, which is what makes the dialect parseable at all.

const std = @import("std");
const Allocator = std.mem.Allocator;
const err = @import("err.zig");
const util = @import("util.zig");

/// `[originalOffset, originalLength, replacementLength]`
pub const Edit = struct { start: usize, original_len: usize, replacement_len: usize };

pub const Result = struct {
    code: []const u8,
    edits: []const Edit,
};

fn special(name: []const u8) ?[]const u8 {
    const table = [_][2][]const u8{
        .{ "show", "$$show" },
        .{ "key", "$$key" },
        .{ "class", "$$class" },
        .{ "text", "$$text" },
        .{ "html", "$$html" },
    };
    for (table) |entry| if (util.eql(entry[0], name)) return entry[1];
    return null;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Index just past the string literal starting at `i` (src[i] is the quote).
fn skipString(src: []const u8, start: usize) usize {
    var i = start;
    const quote = src[i];
    i += 1;
    while (i < src.len) {
        if (src[i] == '\\') {
            i += 2;
            continue;
        }
        if (src[i] == quote or (quote != '`' and src[i] == '\n')) return i + 1;
        if (quote == '`' and src[i] == '$' and i + 1 < src.len and src[i + 1] == '{') {
            i = skipBraces(src, i + 1);
            continue;
        }
        i += 1;
    }
    return i;
}

/// Index just past the balanced brace group starting at `i` (src[i] is `{`).
fn skipBraces(src: []const u8, start: usize) usize {
    var i = start;
    var depth: isize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '"' or c == '\'' or c == '`') {
            i = skipString(src, i);
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/");
            i = if (close) |pos| pos + 2 else src.len;
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
        i += 1;
    }
    return i;
}

/// Top-level ` of ` split for :for values; null when absent.
fn findOf(value: []const u8) ?usize {
    var depth: isize = 0;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (c == '"' or c == '\'' or c == '`') {
            i = skipString(value, i) - 1;
            continue;
        }
        if (c == '(' or c == '[' or c == '{') depth += 1;
        if (c == ')' or c == ']' or c == '}') depth -= 1;
        if (depth == 0 and std.mem.startsWith(u8, value[i..], " of ")) return i;
    }
    return null;
}

fn isAlpha(c: u8) bool {
    return std.ascii.isAlphabetic(c);
}
fn isAlnum(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

/// `^[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)*` — returns the matched length.
fn matchEventName(rest: []const u8) usize {
    var i: usize = 0;
    if (i >= rest.len or !isAlpha(rest[i])) return 0;
    while (true) {
        while (i < rest.len and isAlnum(rest[i])) i += 1;
        if (i + 1 < rest.len and rest[i] == '.' and isAlpha(rest[i + 1])) {
            i += 1;
            continue;
        }
        break;
    }
    return i;
}

/// `^[A-Za-z][A-Za-z0-9-]*` — returns the matched length.
fn matchBindName(rest: []const u8) usize {
    var i: usize = 0;
    if (i >= rest.len or !isAlpha(rest[i])) return 0;
    while (i < rest.len and (isAlnum(rest[i]) or rest[i] == '-')) i += 1;
    return i;
}

const directives = [_][]const u8{ "store", "data", "ref", "anchor", "portal", "position" };

/// `^@(store|data|ref|anchor|portal|position)(?=\s|\/|>|=)`
fn matchDirective(rest: []const u8) ?[]const u8 {
    for (directives) |d| {
        if (std.mem.startsWith(u8, rest, d)) {
            const after = rest[d.len..];
            if (after.len > 0 and (isWs(after[0]) or after[0] == '/' or after[0] == '>' or after[0] == '=')) return d;
        }
    }
    return null;
}

const Canonicalizer = struct {
    allocator: Allocator,
    src: []const u8,
    out: std.ArrayList(u8) = .empty,
    edits: std.ArrayList(Edit) = .empty,
    last: usize = 0,
    i: usize = 0,

    fn replace(self: *Canonicalizer, start: usize, end: usize, text: []const u8) Allocator.Error!void {
        try self.out.appendSlice(self.allocator, self.src[self.last..start]);
        try self.out.appendSlice(self.allocator, text);
        self.last = end;
        self.i = end;
        try self.edits.append(self.allocator, .{ .start = start, .original_len = end - start, .replacement_len = text.len });
    }
};

pub fn canonicalize(allocator: Allocator, src: []const u8) err.Error!Result {
    var c = Canonicalizer{ .allocator = allocator, .src = src };

    while (c.i < src.len) {
        const ch = src[c.i];

        if (ch == '/' and c.i + 1 < src.len and src[c.i + 1] == '/') {
            while (c.i < src.len and src[c.i] != '\n') c.i += 1;
            continue;
        }
        if (ch == '/' and c.i + 1 < src.len and src[c.i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, src, c.i + 2, "*/");
            c.i = if (close) |pos| pos + 2 else src.len;
            continue;
        }
        if (ch == '"' or ch == '\'' or ch == '`') {
            c.i = skipString(src, c.i);
            continue;
        }

        if ((ch == '@' or ch == ':') and c.i > 0 and isWs(src[c.i - 1])) {
            const rest = src[c.i..@min(src.len, c.i + 200)];
            const after = rest[1..];

            if (ch == '@') {
                if (matchDirective(after)) |directive| {
                    const text = try util.concat(allocator, &.{ "$$", directive });
                    try c.replace(c.i, c.i + 1 + directive.len, text);
                    continue;
                }
                const n = matchEventName(after);
                if (n > 0 and after.len > n and after[n] == '=' and after.len > n + 1 and
                    (after[n + 1] == '{' or after[n + 1] == '"' or after[n + 1] == '\''))
                {
                    const dotted = try util.replaceAll(allocator, after[0..n], ".", "$");
                    const text = try util.concat(allocator, &.{ "$$on$", dotted });
                    try c.replace(c.i, c.i + 1 + n, text);
                    continue;
                }
            } else if (std.mem.startsWith(u8, rest, ":for={")) {
                const open = c.i + 5;
                const close = skipBraces(src, open);
                const value = src[open + 1 .. close - 1];
                const at = findOf(value) orelse {
                    return err.fail(":for expects \"item of items\", got: {s}", .{util.trim(value)});
                };
                const binder = util.trim(value[0..at]);
                const source = util.trim(value[at + 4 ..]);
                const text = try util.fmt(allocator, "$$for={{({s}) => ({s})}}", .{ binder, source });
                try c.replace(c.i, close, text);
                continue;
            } else {
                const n = matchBindName(after);
                if (n > 0 and after.len > n and after[n] == '=' and after.len > n + 1 and
                    (after[n + 1] == '{' or after[n + 1] == '"' or after[n + 1] == '\''))
                {
                    const name = after[0..n];
                    const text = special(name) orelse try util.concat(allocator, &.{ "$$b$", name });
                    try c.replace(c.i, c.i + 1 + n, text);
                    continue;
                }
            }
        }

        c.i += 1;
    }

    try c.out.appendSlice(allocator, src[c.last..]);
    return .{ .code = try c.out.toOwnedSlice(allocator), .edits = try c.edits.toOwnedSlice(allocator) };
}

test "canonicalize rewrites directives, events and bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try canonicalize(a,
        \\<div @click.prevent={h} :show={cond} :aria-label={v} @store="x" @anchor :for={item of state.xs} @keydown.down.prevent="openFirst">
    );
    try std.testing.expectEqualStrings(
        \\<div $$on$click$prevent={h} $$show={cond} $$b$aria-label={v} $$store="x" $$anchor $$for={(item) => (state.xs)} $$on$keydown$down$prevent="openFirst">
    , result.code);
    try std.testing.expectEqual(@as(usize, 7), result.edits.len);
}

test "canonicalize leaves strings and comments untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "const s = \" :show={x}\"; // :key={k}\n/* @click={h} */ const t = `${a} :b={c}`;";
    const result = try canonicalize(a, src);
    try std.testing.expectEqualStrings(src, result.code);
}

test "canonicalize rejects :for without of" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Pjsx, canonicalize(arena.allocator(), "<li :for={items}>"));
    try std.testing.expect(std.mem.indexOf(u8, err.message(), ":for expects") != null);
}

fn fuzzCanonicalize(_: void, smith: *std.testing.Smith) !void {
    // Arbitrary bytes must never crash or hang the scanner; a diagnostic is fine.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var input: std.ArrayList(u8) = .empty;
    while (!smith.eos()) {
        const chunk = try input.addManyAsSlice(arena.allocator(), smith.value(u6));
        smith.bytes(chunk);
    }
    _ = canonicalize(arena.allocator(), input.items) catch |e| switch (e) {
        error.Pjsx => {},
        else => return e,
    };
}

test "fuzz: canonicalize survives arbitrary input" {
    try std.testing.fuzz({}, fuzzCanonicalize, .{});
}
