//! A tiny dynamic JavaScript value with the operator semantics the reference
//! compiler relies on when it constant-folds and statically evaluates source
//! expressions (`==`, `===`, `+`, `<`, truthiness, `String()`, `Number()`,
//! `JSON.stringify`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util.zig");
const ast = @import("ast.zig");

pub const Value = union(enum) {
    undefined,
    null,
    boolean: bool,
    number: f64,
    string: []const u8,
    array: []const Value,
    object: []const Field,

    pub const Field = struct { key: []const u8, value: Value };

    pub fn fromLiteral(literal: ast.LiteralValue) Value {
        return switch (literal) {
            .none => .undefined,
            .null => .null,
            .boolean => |b| .{ .boolean = b },
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = s },
            .regex, .bigint => .undefined,
        };
    }

    pub fn toLiteral(self: Value) ast.LiteralValue {
        return switch (self) {
            .undefined => .none,
            .null => .null,
            .boolean => |b| .{ .boolean = b },
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = s },
            .array, .object => .none,
        };
    }

    pub fn isNullish(self: Value) bool {
        return self == .undefined or self == .null;
    }

    pub fn isObjectLike(self: Value) bool {
        return self == .array or self == .object;
    }

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .undefined, .null => false,
            .boolean => |b| b,
            .number => |n| !(n == 0 or std.math.isNan(n)),
            .string => |s| s.len != 0,
            .array, .object => true,
        };
    }

    /// `Number(value)`
    pub fn toNumber(self: Value) f64 {
        return switch (self) {
            .undefined => std.math.nan(f64),
            .null => 0,
            .boolean => |b| if (b) 1 else 0,
            .number => |n| n,
            .string => |s| blk: {
                const trimmed = util.trim(s);
                if (trimmed.len == 0) break :blk 0;
                break :blk std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
            },
            .array => |items| if (items.len == 0) 0 else if (items.len == 1) items[0].toNumber() else std.math.nan(f64),
            .object => std.math.nan(f64),
        };
    }

    /// `String(value)`
    pub fn toString(self: Value, allocator: Allocator) Allocator.Error![]const u8 {
        return switch (self) {
            .undefined => allocator.dupe(u8, "undefined"),
            .null => allocator.dupe(u8, "null"),
            .boolean => |b| allocator.dupe(u8, if (b) "true" else "false"),
            .number => |n| util.numberToString(allocator, n),
            .string => |s| allocator.dupe(u8, s),
            .array => |items| blk: {
                var parts: util.StringList = .empty;
                for (items) |item| try parts.append(allocator, if (item.isNullish()) "" else try item.toString(allocator));
                break :blk util.join(allocator, parts.items, ",");
            },
            .object => allocator.dupe(u8, "[object Object]"),
        };
    }

    /// `JSON.stringify(value)`; `undefined` at the top level yields "undefined" (like `String(JSON.stringify(x))`).
    pub fn toJson(self: Value, allocator: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.writeJson(allocator, &out);
        return out.toOwnedSlice(allocator);
    }

    fn writeJson(self: Value, allocator: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
        switch (self) {
            .undefined => try out.appendSlice(allocator, "undefined"),
            .null => try out.appendSlice(allocator, "null"),
            .boolean => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
            .number => |n| {
                if (std.math.isNan(n) or std.math.isInf(n)) {
                    try out.appendSlice(allocator, "null");
                } else {
                    try out.appendSlice(allocator, try util.numberToString(allocator, n));
                }
            },
            .string => |s| try util.appendJsonString(allocator, out, s),
            .array => |items| {
                try out.append(allocator, '[');
                for (items, 0..) |item, i| {
                    if (i > 0) try out.append(allocator, ',');
                    if (item == .undefined) try out.appendSlice(allocator, "null") else try item.writeJson(allocator, out);
                }
                try out.append(allocator, ']');
            },
            .object => |fields| {
                try out.append(allocator, '{');
                var first = true;
                for (fields) |field| {
                    if (field.value == .undefined) continue;
                    if (!first) try out.append(allocator, ',');
                    first = false;
                    try util.appendJsonString(allocator, out, field.key);
                    try out.append(allocator, ':');
                    try field.value.writeJson(allocator, out);
                }
                try out.append(allocator, '}');
            },
        }
    }

    /// `a === b`
    pub fn strictEquals(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .undefined, .null => true,
            .boolean => a.boolean == b.boolean,
            .number => a.number == b.number,
            .string => util.eql(a.string, b.string),
            .array => a.array.ptr == b.array.ptr and a.array.len == b.array.len,
            .object => a.object.ptr == b.object.ptr and a.object.len == b.object.len,
        };
    }

    /// `a == b`
    pub fn looseEquals(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) == std.meta.activeTag(b)) return strictEquals(a, b);
        if (a.isNullish() and b.isNullish()) return true;
        if (a.isNullish() or b.isNullish()) return false;
        if (a == .boolean) return looseEquals(.{ .number = a.toNumber() }, b);
        if (b == .boolean) return looseEquals(a, .{ .number = b.toNumber() });
        if (a == .number and b == .string) return a.number == b.toNumber();
        if (a == .string and b == .number) return a.toNumber() == b.number;
        if (a.isObjectLike() and !b.isObjectLike()) return false;
        if (b.isObjectLike() and !a.isObjectLike()) return false;
        return false;
    }

    /// `a + b`
    pub fn add(a: Value, b: Value, allocator: Allocator) Allocator.Error!Value {
        if (a == .string or b == .string or a.isObjectLike() or b.isObjectLike()) {
            const left = try a.toString(allocator);
            const right = try b.toString(allocator);
            return .{ .string = try util.concat(allocator, &.{ left, right }) };
        }
        return .{ .number = a.toNumber() + b.toNumber() };
    }

    /// `a < b` (numeric or string comparison).
    pub fn lessThan(a: Value, b: Value) bool {
        if (a == .string and b == .string) return std.mem.order(u8, a.string, b.string) == .lt;
        const l = a.toNumber();
        const r = b.toNumber();
        if (std.math.isNan(l) or std.math.isNan(r)) return false;
        return l < r;
    }

    /// `a <= b`
    pub fn lessThanOrEqual(a: Value, b: Value) bool {
        if (a == .string and b == .string) return std.mem.order(u8, a.string, b.string) != .gt;
        const l = a.toNumber();
        const r = b.toNumber();
        if (std.math.isNan(l) or std.math.isNan(r)) return false;
        return l <= r;
    }

    /// Property lookup on objects/arrays (`value[segment]`); undefined otherwise.
    pub fn get(self: Value, key: []const u8) Value {
        switch (self) {
            .object => |fields| {
                for (fields) |field| if (util.eql(field.key, key)) return field.value;
                return .undefined;
            },
            .array => |items| {
                if (util.eql(key, "length")) return .{ .number = @floatFromInt(items.len) };
                const index = std.fmt.parseInt(usize, key, 10) catch return .undefined;
                return if (index < items.len) items[index] else .undefined;
            },
            .string => |s| {
                if (util.eql(key, "length")) return .{ .number = @floatFromInt(s.len) };
                return .undefined;
            },
            else => return .undefined,
        }
    }
};

test "loose equality follows JavaScript coercion" {
    try std.testing.expect(Value.looseEquals(.null, .undefined));
    try std.testing.expect(Value.looseEquals(.{ .number = 1 }, .{ .string = "1" }));
    try std.testing.expect(!Value.looseEquals(.{ .number = 0 }, .null));
    try std.testing.expect(Value.looseEquals(.{ .boolean = true }, .{ .number = 1 }));
    try std.testing.expect(!Value.strictEquals(.{ .number = 1 }, .{ .string = "1" }));
}

test "add concatenates when either side is a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sum = try Value.add(.{ .number = 1 }, .{ .number = 2 }, a);
    try std.testing.expectEqual(@as(f64, 3), sum.number);
    const text = try Value.add(.{ .string = "h" }, .{ .number = 2 }, a);
    try std.testing.expectEqualStrings("h2", text.string);
}

test "toJson matches JSON.stringify for nested values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]Value{ .{ .string = "a" }, .{ .number = 1.5 }, .undefined };
    const value = Value{ .array = &items };
    try std.testing.expectEqualStrings("[\"a\",1.5,null]", try value.toJson(a));
}
