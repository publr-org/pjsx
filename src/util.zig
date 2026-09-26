//! JavaScript-semantics helpers the ports lean on: `JSON.stringify` for
//! strings, `String(number)`, `encodeURIComponent`, the JSX text whitespace
//! rule, and small string utilities.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const StringList = std.ArrayList([]const u8);

/// `JSON.stringify(string)`: quotes and escapes exactly like V8 (non-ASCII is
/// emitted verbatim; only `"`, `\` and control characters are escaped).
pub fn jsonString(allocator: Allocator, value: []const u8) Allocator.Error![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    writeJsonString(&out.writer, value) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Stream `JSON.stringify(value)` into `w`.
pub fn writeJsonString(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            0...7, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// Append `JSON.stringify(value)` to an `ArrayList(u8)` being assembled.
pub fn appendJsonString(allocator: Allocator, out: *std.ArrayList(u8), value: []const u8) Allocator.Error!void {
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, out);
    writeJsonString(&aw.writer, value) catch return error.OutOfMemory;
    out.* = aw.toArrayList();
}

/// JavaScript Number::toString, shared with generated server rendering.
pub const numberToString = @import("runtime/semantics.zig").number_to_string;

/// `encodeURIComponent(value)`.
pub fn encodeUriComponent(allocator: Allocator, value: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |c| {
        const keep = std.ascii.isAlphanumeric(c) or switch (c) {
            '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
            else => false,
        };
        if (keep) {
            try out.append(allocator, c);
        } else {
            var buf: [3]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(allocator, text);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

/// JSX text semantics: newline-adjacent edge whitespace dropped, interior
/// newline runs collapse to one space (the `jsxText` helper of the reference).
pub fn jsxText(allocator: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var text = raw;
    // ^[ \t]*\r?\n\s*
    {
        var i: usize = 0;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i < text.len and text[i] == '\r') i += 1;
        if (i < text.len and text[i] == '\n') {
            i += 1;
            while (i < text.len and isWhitespace(text[i])) i += 1;
            text = text[i..];
        }
    }
    // \s*\r?\n[ \t]*$
    {
        var j = text.len;
        while (j > 0 and (text[j - 1] == ' ' or text[j - 1] == '\t')) j -= 1;
        if (j > 0 and text[j - 1] == '\n') {
            j -= 1;
            if (j > 0 and text[j - 1] == '\r') j -= 1;
            while (j > 0 and isWhitespace(text[j - 1])) j -= 1;
            text = text[0..j];
        }
    }
    // \s*\r?\n\s* → " "
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (isWhitespace(text[i])) {
            var j = i;
            var has_newline = false;
            while (j < text.len and isWhitespace(text[j])) : (j += 1) {
                if (text[j] == '\n') has_newline = true;
            }
            if (has_newline) {
                try out.append(allocator, ' ');
            } else {
                try out.appendSlice(allocator, text[i..j]);
            }
            i = j;
        } else {
            try out.append(allocator, text[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// `value.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase()`
pub fn kebabCase(allocator: Allocator, value: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value, 0..) |c, i| {
        if (i > 0 and std.ascii.isUpper(c) and (std.ascii.isLower(value[i - 1]) or std.ascii.isDigit(value[i - 1]))) {
            try out.append(allocator, '-');
        }
        try out.append(allocator, std.ascii.toLower(c));
    }
    return out.toOwnedSlice(allocator);
}

pub fn lowerFirst(allocator: Allocator, value: []const u8) Allocator.Error![]const u8 {
    const out = try allocator.dupe(u8, value);
    if (out.len > 0) out[0] = std.ascii.toLower(out[0]);
    return out;
}

pub fn upperFirst(allocator: Allocator, value: []const u8) Allocator.Error![]const u8 {
    const out = try allocator.dupe(u8, value);
    if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

pub fn toLower(allocator: Allocator, value: []const u8) Allocator.Error![]const u8 {
    return std.ascii.allocLowerString(allocator, value);
}

pub fn startsWithUpper(value: []const u8) bool {
    return value.len > 0 and std.ascii.isUpper(value[0]);
}

pub fn startsWithLower(value: []const u8) bool {
    return value.len > 0 and std.ascii.isLower(value[0]);
}

/// `/^on[A-Z]/`
pub fn isEventProp(name: []const u8) bool {
    return name.len > 2 and name[0] == 'o' and name[1] == 'n' and std.ascii.isUpper(name[2]);
}

/// JSX event targets are explicit: onWindowPopState / onDocumentKeyDown.
pub fn eventDescriptor(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    for ([_][]const u8{ "Window", "Document" }) |target| {
        if (std.mem.startsWith(u8, name[2..], target) and name.len > 2 + target.len and std.ascii.isUpper(name[2 + target.len])) {
            return std.fmt.allocPrint(a, "{s}.{s}", .{ try toLower(a, name[2 + target.len ..]), try toLower(a, target) });
        }
    }
    return toLower(a, name[2..]);
}

/// `/^[A-Za-z_$][A-Za-z0-9_$]*$/`
pub fn isIdentifierName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        const ok = std.ascii.isAlphabetic(c) or c == '_' or c == '$' or (i > 0 and std.ascii.isDigit(c));
        if (!ok) return false;
    }
    return true;
}

/// `/\.p(?:j|t)sx$/`
pub fn hasPjsxExtension(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".pjsx") or std.mem.endsWith(u8, name, ".ptsx");
}

pub fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

pub fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\n\r\x0b\x0c");
}

pub fn join(allocator: Allocator, parts: []const []const u8, separator: []const u8) Allocator.Error![]const u8 {
    return std.mem.join(allocator, separator, parts);
}

pub fn concat(allocator: Allocator, parts: []const []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(allocator, u8, parts);
}

pub fn fmt(allocator: Allocator, comptime format: []const u8, args: anytype) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, format, args);
}

pub fn replaceAll(allocator: Allocator, value: []const u8, needle: []const u8, replacement: []const u8) Allocator.Error![]const u8 {
    return std.mem.replaceOwned(u8, allocator, value, needle, replacement);
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

pub fn containsString(list: []const []const u8, value: []const u8) bool {
    for (list) |item| if (eql(item, value)) return true;
    return false;
}

pub fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn sortStrings(list: [][]const u8) void {
    std.mem.sort([]const u8, list, {}, lessThanString);
}

/// Sorted, de-duplicated copy of `list` (`[...new Set(list)].sort()`).
pub fn sortedUnique(allocator: Allocator, list: []const []const u8) Allocator.Error![][]const u8 {
    var out: StringList = .empty;
    for (list) |item| {
        if (!containsString(out.items, item)) try out.append(allocator, item);
    }
    const slice = try out.toOwnedSlice(allocator);
    sortStrings(slice);
    return slice;
}

/// `value.trim().split(/\s+/)` non-empty tokens.
pub fn splitWhitespace(allocator: Allocator, value: []const u8) Allocator.Error![][]const u8 {
    var out: StringList = .empty;
    var it = std.mem.tokenizeAny(u8, value, " \t\n\r\x0b\x0c");
    while (it.next()) |token| try out.append(allocator, token);
    return out.toOwnedSlice(allocator);
}

/// Insertion-ordered string→V map (JavaScript `Map` semantics).
pub fn OrderedMap(comptime V: type) type {
    return struct {
        const Self = @This();
        map: std.StringArrayHashMapUnmanaged(V) = .empty,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }
        pub fn put(self: *Self, key: []const u8, value: V) Allocator.Error!void {
            try self.map.put(self.allocator, key, value);
        }
        pub fn get(self: *const Self, key: []const u8) ?V {
            return self.map.get(key);
        }
        pub fn has(self: *const Self, key: []const u8) bool {
            return self.map.contains(key);
        }
        pub fn remove(self: *Self, key: []const u8) void {
            _ = self.map.orderedRemove(key);
        }
        pub fn count(self: *const Self) usize {
            return self.map.count();
        }
        pub fn keys(self: *const Self) []const []const u8 {
            return self.map.keys();
        }
        pub fn values(self: *const Self) []V {
            return self.map.values();
        }
        pub fn clone(self: *const Self) Allocator.Error!Self {
            return .{ .allocator = self.allocator, .map = try self.map.clone(self.allocator) };
        }
    };
}

pub const StringSet = OrderedMap(void);

test "jsonString escapes like JSON.stringify" {
    const a = std.testing.allocator;
    const out = try jsonString(a, "a\"b\\c\nd\x01é");
    defer a.free(out);
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001é\"", out);
}

test "numberToString follows JavaScript formatting" {
    const a = std.testing.allocator;
    const cases = [_]struct { f64, []const u8 }{ .{ 50, "50" }, .{ 0.5, "0.5" }, .{ -3, "-3" }, .{ 12.25, "12.25" }, .{ 0, "0" } };
    for (cases) |case| {
        const out = try numberToString(a, case[0]);
        defer a.free(out);
        try std.testing.expectEqualStrings(case[1], out);
    }
}

test "jsxText collapses newline runs and trims newline-adjacent edges" {
    const a = std.testing.allocator;
    const out = try jsxText(a, "\n      Panel\n    ");
    defer a.free(out);
    try std.testing.expectEqualStrings("Panel", out);
    const inner = try jsxText(a, "a\n   b  c");
    defer a.free(inner);
    try std.testing.expectEqualStrings("a b  c", inner);
    const spaces = try jsxText(a, "  x  ");
    defer a.free(spaces);
    try std.testing.expectEqualStrings("  x  ", spaces);
}

test "kebabCase splits lower-upper boundaries" {
    const a = std.testing.allocator;
    const out = try kebabCase(a, "TextDemo2Box");
    defer a.free(out);
    try std.testing.expectEqualStrings("text-demo2-box", out);
}

test "encodeUriComponent percent-encodes reserved characters" {
    const a = std.testing.allocator;
    const out = try encodeUriComponent(a, "[\"a b\",1]");
    defer a.free(out);
    try std.testing.expectEqualStrings("%5B%22a%20b%22%2C1%5D", out);
}
