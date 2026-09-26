//! Portable expression semantics shared by the compiler and generated servers.
//! Hosts may specialize these operations only when observable behavior agrees.
const std = @import("std");

pub const version: u32 = 1;

/// Tagged scalar transport. Untagged application JSON is a different, smaller
/// value domain. Array envelopes cannot be mistaken for a scalar user value.
pub const Scalar = union(enum) { undefined, null, boolean: bool, number: f64, string: []const u8 };
pub const DecodeError = error{InvalidPortableScalar};

pub fn number_from_bits(hex: []const u8) DecodeError!f64 {
    if (hex.len != 16) return error.InvalidPortableScalar;
    for (hex) |c| if (!std.ascii.isHex(c)) return error.InvalidPortableScalar;
    const bits = std.fmt.parseInt(u64, hex, 16) catch return error.InvalidPortableScalar;
    return @bitCast(bits);
}

pub fn write_scalar(w: *std.Io.Writer, value: Scalar) std.Io.Writer.Error!void {
    switch (value) {
        .undefined => try w.writeAll("[\"undefined\"]"),
        .null => try w.writeAll("[\"null\"]"),
        .number => |n| try w.print("[\"number\",\"{x:0>16}\"]", .{@as(u64, @bitCast(n))}),
        .boolean => |b| try w.writeAll(if (b) "[\"boolean\",true]" else "[\"boolean\",false]"),
        .string => |s| {
            try w.writeAll("[\"string\",");
            try std.json.Stringify.value(s, .{}, w);
            try w.writeByte(']');
        },
    }
}

pub fn scalar_from_json(value: std.json.Value) DecodeError!Scalar {
    if (value != .array) return error.InvalidPortableScalar;
    const items = value.array.items;
    if (items.len == 0 or items[0] != .string) return error.InvalidPortableScalar;
    const tag = items[0].string;
    if (std.mem.eql(u8, tag, "undefined") and items.len == 1) return .undefined;
    if (std.mem.eql(u8, tag, "null") and items.len == 1) return .null;
    if (items.len != 2) return error.InvalidPortableScalar;
    if (std.mem.eql(u8, tag, "number") and items[1] == .string) return .{ .number = try number_from_bits(items[1].string) };
    if (std.mem.eql(u8, tag, "boolean") and items[1] == .bool) return .{ .boolean = items[1].bool };
    if (std.mem.eql(u8, tag, "string") and items[1] == .string and std.unicode.utf8ValidateSlice(items[1].string)) return .{ .string = items[1].string };
    return error.InvalidPortableScalar;
}

pub fn number_truthy(value: f64) bool {
    return value != 0 and !std.math.isNan(value);
}

pub fn number_min(a: f64, b: f64) f64 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(f64);
    if (a == 0 and b == 0) return if (std.math.signbit(a) or std.math.signbit(b)) -0.0 else 0.0;
    return @min(a, b);
}

pub fn number_max(a: f64, b: f64) f64 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(f64);
    if (a == 0 and b == 0) return if (std.math.signbit(a) and std.math.signbit(b)) -0.0 else 0.0;
    return @max(a, b);
}

pub fn number_rem(a: f64, b: f64) f64 {
    if (std.math.isNan(a) or std.math.isNan(b) or std.math.isInf(a) or b == 0) return std.math.nan(f64);
    if (std.math.isInf(b) or a == 0) return a;
    const result = @rem(a, b);
    return if (result == 0 and std.math.signbit(a)) -0.0 else result;
}

/// JS Number::toString, radix 10. Always format the shortest round-tripping
/// decimal; formatting an integral f64 through an integer changes JS output.
pub fn write_number(w: *std.Io.Writer, value: f64) std.Io.Writer.Error!void {
    if (std.math.isNan(value)) return w.writeAll("NaN");
    if (std.math.isInf(value)) return w.writeAll(if (value > 0) "Infinity" else "-Infinity");
    if (value == 0) return w.writeAll("0");
    var buffer: [512]u8 = undefined;
    const scientific = @abs(value) >= 1e21 or @abs(value) < 1e-6;
    const text = std.fmt.float.render(&buffer, value, .{ .mode = if (scientific) .scientific else .decimal }) catch unreachable;
    if (scientific) {
        const e = std.mem.indexOfScalar(u8, text, 'e').?;
        try w.writeAll(text[0 .. e + 1]);
        if (text[e + 1] != '-') try w.writeByte('+');
        return w.writeAll(text[e + 1 ..]);
    }
    return w.writeAll(text);
}

pub fn number_to_string(a: std.mem.Allocator, value: f64) std.mem.Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    write_number(&out.writer, value) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

test "portable number formatting preserves JS special values and notation thresholds" {
    const cases = [_]struct { f64, []const u8 }{
        .{ -0.0, "0" },                                  .{ std.math.nan(f64), "NaN" },
        .{ std.math.inf(f64), "Infinity" },              .{ -std.math.inf(f64), "-Infinity" },
        .{ 1e21, "1e+21" },                              .{ 1e-7, "1e-7" },
        .{ 1e-6, "0.000001" },                           .{ 1000000000000000100.0, "1000000000000000100" },
        .{ 0.1 + @as(f64, 0.2), "0.30000000000000004" },
    };
    for (cases) |case| {
        const text = try number_to_string(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case[1], text);
    }
}

test "portable min max and remainder preserve NaN and signed zero" {
    try std.testing.expect(std.math.isNan(number_max(std.math.nan(f64), 7)));
    try std.testing.expect(std.math.isNan(number_min(7, std.math.nan(f64))));
    try std.testing.expect(std.math.signbit(number_min(0, -0.0)));
    try std.testing.expect(!std.math.signbit(number_max(-0.0, 0)));
    try std.testing.expect(std.math.signbit(number_rem(-4, 2)));
    try std.testing.expect(std.math.isNan(number_rem(1, 0)));
}

test "scalar envelopes round trip exact numeric bits and reject ambiguous inputs" {
    const a = std.testing.allocator;
    var random = std.Random.DefaultPrng.init(0x50534a58);
    for (0..4096) |_| {
        const bits = random.random().int(u64);
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try write_scalar(&out.writer, .{ .number = @bitCast(bits) });
        const parsed = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
        defer parsed.deinit();
        const decoded = try scalar_from_json(parsed.value);
        try std.testing.expectEqual(bits, @as(u64, @bitCast(decoded.number)));
    }
    for ([_][]const u8{ "null", "0", "[]", "[\"number\",0]", "[\"number\",\"+000000000000000\"]", "[\"undefined\",null]", "[\"boolean\",1]", "[\"unknown\"]" }) |source| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, source, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidPortableScalar, scalar_from_json(parsed.value));
    }
}
