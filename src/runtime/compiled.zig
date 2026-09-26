//! Blocking SSR and generated endpoint support. All values and allocations are request-owned.
const std = @import("std");
pub const Value = std.json.Value;
const A = std.mem.Allocator;
const W = std.Io.Writer;
pub fn object(a: A, keys: []const []const u8, values: []const Value) !Value {
    var out: std.json.ObjectMap = .{};
    for (keys, values) |key, value| try out.put(a, key, value);
    return .{ .object = out };
}
// Seed fields use public state names. Defaults remain in the companion module.
pub fn componentSeed(a: A, values: Value, props: Value, cache: Value) !Value {
    var out = values;
    if (props != .null and (props != .object or props.object.count() > 0)) try out.object.put(a, "$props", props);
    if (cache.object.count() > 0) try out.object.put(a, "$cache", cache);
    return out;
}
pub fn array(a: A, values: []const Value) !Value {
    var out: std.array_list.Managed(Value) = .init(a);
    try out.appendSlice(values);
    return .{ .array = out };
}
pub fn get(value: Value, key: []const u8) !Value {
    if (value == .object) return value.object.get(key) orelse error.MissingProperty;
    if (value == .array and std.mem.eql(u8, key, "length")) return .{ .integer = @intCast(value.array.items.len) };
    if (value == .string and std.mem.eql(u8, key, "length")) return .{ .integer = @intCast(try std.unicode.calcUtf16LeLen(value.string)) };
    return error.MissingProperty;
}
pub fn items(value: Value) ![]const Value {
    return if (value == .array) value.array.items else error.ExpectedArray;
}
pub fn truthy(value: Value) bool {
    return switch (value) {
        .null => false,
        .bool => value.bool,
        .integer => value.integer != 0,
        .float => value.float != 0 and !std.math.isNan(value.float),
        .string => value.string.len != 0,
        else => true,
    };
}
pub fn number(value: Value) !f64 {
    return switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        .null => 0,
        .bool => if (value.bool) 1 else 0,
        .string => error.NumericCoercionRequiresExplicitConversion,
        else => error.ExpectedNumber,
    };
}
pub fn string(a: A, value: Value) ![]const u8 {
    return switch (value) {
        .string => value.string,
        .null => "null",
        .bool => if (value.bool) "true" else "false",
        .integer => try std.fmt.allocPrint(a, "{d}", .{value.integer}),
        .float => try @import("semantics.zig").number_to_string(a, value.float),
        else => error.ExpectedScalar,
    };
}
pub fn binary(a: A, comptime op: []const u8, left: Value, right: Value) !Value {
    if (comptime std.mem.eql(u8, op, "+")) {
        if (left == .string or right == .string) return .{ .string = try std.fmt.allocPrint(a, "{s}{s}", .{ try string(a, left), try string(a, right) }) };
    }
    if (comptime std.mem.eql(u8, op, "===") or std.mem.eql(u8, op, "!==")) {
        const equal = if (left == .string and right == .string) std.mem.eql(u8, left.string, right.string) else if (left == .null or right == .null) left == .null and right == .null else if (left == .bool or right == .bool) left == .bool and right == .bool and left.bool == right.bool else if ((left == .integer or left == .float) and (right == .integer or right == .float)) (try number(left)) == (try number(right)) else false;
        return .{ .bool = if (comptime std.mem.eql(u8, op, "!==")) !equal else equal };
    }
    if (left == .string and right == .string) {
        const order = std.mem.order(u16, try std.unicode.utf8ToUtf16LeAlloc(a, left.string), try std.unicode.utf8ToUtf16LeAlloc(a, right.string));
        if (comptime std.mem.eql(u8, op, ">")) return .{ .bool = order == .gt };
        if (comptime std.mem.eql(u8, op, "<")) return .{ .bool = order == .lt };
        if (comptime std.mem.eql(u8, op, ">=")) return .{ .bool = order != .lt };
        if (comptime std.mem.eql(u8, op, "<=")) return .{ .bool = order != .gt };
    }
    const l = try number(left);
    const r = try number(right);
    if (comptime std.mem.eql(u8, op, "+")) return .{ .float = l + r };
    if (comptime std.mem.eql(u8, op, "-")) return .{ .float = l - r };
    if (comptime std.mem.eql(u8, op, "*")) return .{ .float = l * r };
    if (comptime std.mem.eql(u8, op, "/")) return .{ .float = l / r };
    if (comptime std.mem.eql(u8, op, "%")) return .{ .float = @rem(l, r) };
    if (comptime std.mem.eql(u8, op, ">")) return .{ .bool = l > r };
    if (comptime std.mem.eql(u8, op, "<")) return .{ .bool = l < r };
    if (comptime std.mem.eql(u8, op, ">=")) return .{ .bool = l >= r };
    if (comptime std.mem.eql(u8, op, "<=")) return .{ .bool = l <= r };
    @compileError("Unsupported compiled binary operator");
}
pub fn escape(w: *W, input: []const u8) !void {
    for (input) |byte| switch (byte) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(byte),
    };
}
pub fn text(w: *W, a: A, value: Value) !void {
    if (value == .null or value == .bool) return;
    try escape(w, try string(a, value));
}
pub fn className(a: A, value: Value) anyerror!Value {
    if (!truthy(value)) return .{ .string = "" };
    var parts: std.ArrayList([]const u8) = .empty;
    switch (value) {
        .array => |array_values| for (array_values.items) |item| {
            const part = (try className(a, item)).string;
            if (part.len > 0) try parts.append(a, part);
        },
        .object => |object_values| {
            var iter = object_values.iterator();
            while (iter.next()) |entry| if (truthy(entry.value_ptr.*)) {
                try parts.append(a, entry.key_ptr.*);
            };
        },
        else => return .{ .string = try string(a, value) },
    }
    return .{ .string = try std.mem.join(a, " ", parts.items) };
}
pub fn attribute(w: *W, a: A, name: []const u8, value: Value) !void {
    const aria = std.mem.startsWith(u8, name, "aria-");
    if (value == .null or (value == .bool and !value.bool and !aria)) return;
    try w.writeByte(' ');
    try w.writeAll(name);
    if (value == .bool and !aria) return;
    try w.writeAll("=\"");
    try escape(w, try string(a, value));
    try w.writeByte('"');
}
pub fn json(w: *W, a: A, value: anytype) !void {
    if (@TypeOf(value) == Value) {
        try validate(value);
    } else {
        inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
            if (field.type == Value) try validate(@field(value, field.name));
        }
    }
    var out: W.Allocating = .init(a);
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = true }, &out.writer);
    // JSON script contents must never contain an HTML closing-tag opener.
    for (out.written()) |byte| switch (byte) {
        '<' => try w.writeAll("\\u003c"),
        '>' => try w.writeAll("\\u003e"),
        '&' => try w.writeAll("\\u0026"),
        else => try w.writeByte(byte),
    };
}
pub fn row(w: *W, a: A, value: Value, close: bool) !void {
    try validate(value);
    if (value == .object or value == .array) return error.InvalidRowKey;
    try w.writeAll(if (close) "<!--/p:row:" else "<!--p:row:");
    var out: W.Allocating = .init(a);
    if (value == .float) try @import("semantics.zig").write_number(&out.writer, value.float) else try std.json.Stringify.value(value, .{}, &out.writer);
    const hex = "0123456789ABCDEF";
    for (out.written()) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-_.!~*'()", byte) != null) try w.writeByte(byte) else {
            try w.writeByte('%');
            try w.writeByte(hex[byte >> 4]);
            try w.writeByte(hex[byte & 15]);
        }
    }
    try w.writeAll("-->");
}
/// Arguments and results are validated against the actual native signature.
/// Context is supplied by the host and never decoded from browser input.
pub fn native(comptime operation: anytype, ctx: anytype, a: A, args: []const Value) !Value {
    return (try nativeResult(operation, ctx, a, args)).value;
}
pub const OperationPolicy = struct {
    revision: u64 = 0,
    no_store: bool = false,
    revalidate: bool = false,
    expires: ?i64 = null,
    tags: []const []const u8 = &.{},
};
pub fn OperationResult(comptime T: type) type {
    return struct {
        pub const publr_operation_result = true;
        value: T,
        policy: OperationPolicy = .{},
    };
}
pub const ResolvedOperation = struct { value: Value, policy: OperationPolicy = .{} };
pub fn nativeResult(comptime operation: anytype, ctx: anytype, a: A, args: []const Value) !ResolvedOperation {
    const info = @typeInfo(@TypeOf(operation)).@"fn";
    if (args.len + 1 != info.params.len) return error.InvalidArguments;
    for (args) |arg| try validate(arg);
    var params: std.meta.ArgsTuple(@TypeOf(operation)) = undefined;
    params[0] = ctx;
    inline for (info.params[1..], 0..) |parameter, index| {
        const decoded = try std.json.parseFromValue(parameter.type.?, a, args[index], .{ .ignore_unknown_fields = false, .allocate = .alloc_always });
        params[index + 1] = decoded.value;
    }
    const result = try @call(.auto, operation, params);
    var out: W.Allocating = .init(a);
    const branded = comptime @typeInfo(@TypeOf(result)) == .@"struct" and @hasDecl(@TypeOf(result), "publr_operation_result");
    try std.json.Stringify.value(if (branded) result.value else result, .{}, &out.writer);
    const value = (try std.json.parseFromSlice(Value, a, out.written(), .{ .allocate = .alloc_always })).value;
    try validate(value);
    return .{ .value = value, .policy = if (branded) .{ .revision = result.policy.revision, .no_store = result.policy.no_store, .revalidate = result.policy.revalidate, .expires = result.policy.expires, .tags = result.policy.tags } else .{} };
}

pub fn types(w: *W, comptime operation: anytype, comptime name: []const u8) !void {
    const info = @typeInfo(@TypeOf(operation)).@"fn";
    try w.print("export declare function {s}(", .{name});
    inline for (info.params[1..], 0..) |parameter, index| {
        if (index != 0) try w.writeAll(", ");
        try w.print("arg{d}: ", .{index});
        try typeScript(w, parameter.type.?);
    }
    try w.writeAll("): Promise<");
    const Payload = @typeInfo(info.return_type.?).error_union.payload;
    try typeScript(w, if (@typeInfo(Payload) == .@"struct" and @hasDecl(Payload, "publr_operation_result")) @FieldType(Payload, "value") else Payload);
    try w.writeAll(">;\n");
}
fn typeScript(w: *W, comptime T: type) !void {
    switch (@typeInfo(T)) {
        .bool => try w.writeAll("boolean"),
        .int, .float, .comptime_int, .comptime_float => try w.writeAll("number"),
        .optional => |optional| {
            try typeScript(w, optional.child);
            try w.writeAll(" | null");
        },
        .pointer => |pointer| {
            if (pointer.size != .slice) @compileError("Native operation schemas support slices, not pointers");
            if (pointer.child == u8) try w.writeAll("string") else {
                try w.writeAll("Array<");
                try typeScript(w, pointer.child);
                try w.writeAll(">");
            }
        },
        .@"struct" => |structure| {
            try w.writeAll("{ ");
            inline for (structure.fields) |field| {
                try std.json.Stringify.value(field.name, .{}, w);
                try w.writeAll(": ");
                try typeScript(w, field.type);
                try w.writeAll("; ");
            }
            try w.writeAll("}");
        },
        .@"enum" => |enumeration| {
            inline for (enumeration.fields, 0..) |field, index| {
                if (index != 0) try w.writeAll(" | ");
                try std.json.Stringify.value(field.name, .{}, w);
            }
        },
        .void, .null => try w.writeAll("null"),
        else => @compileError("Unsupported native operation result schema"),
    }
}
pub fn childInstance(a: A, parent: []const u8, value: Value) ![]const u8 {
    var out: W.Allocating = .init(a);
    try out.writer.writeAll(parent);
    try out.writer.writeByte('/');
    // The row encoder is injective over the JSON key profile and HTML-safe.
    var encoded: W.Allocating = .init(a);
    try row(&encoded.writer, a, value, false);
    const bytes = encoded.written();
    try out.writer.writeAll(bytes[10 .. bytes.len - 3]);
    return out.written();
}

pub fn validate(value: Value) error{InvalidJsonValue}!void {
    switch (value) {
        .integer => |v| if (v < -9007199254740991 or v > 9007199254740991) {
            return error.InvalidJsonValue;
        },
        .float => |v| if (!std.math.isFinite(v) or (v == 0 and std.math.signbit(v))) {
            return error.InvalidJsonValue;
        },
        .string => |v| if (!std.unicode.utf8ValidateSlice(v)) {
            return error.InvalidJsonValue;
        },
        .array => |v| for (v.items) |item| {
            try validate(item);
        },
        .object => |v| for (v.values()) |item| {
            try validate(item);
        },
        .null, .bool => {},
        else => return error.InvalidJsonValue,
    }
}

pub fn optionalItems(value: Value) ![]const Value {
    return if (value == .null) &.{} else items(value);
}
pub fn indexed(a: A, value: Value, key: Value) !Value {
    if (value == .object) return get(value, try string(a, key));
    if (key == .string) return get(value, key.string);
    const n = try number(key);
    if (!std.math.isFinite(n) or n < 0 or @floor(n) != n) return error.InvalidIndex;
    if (value != .array or n >= @as(f64, @floatFromInt(value.array.items.len))) return error.InvalidIndex;
    return value.array.items[@intFromFloat(n)];
}
pub fn window(from: Value, count: Value) ![2]usize {
    const f = try number(from);
    const c = try number(count);
    const end = f + c;
    if (!std.math.isFinite(f) or !std.math.isFinite(c) or f < 0 or c < 0 or @floor(f) != f or @floor(c) != c or end > 9007199254740991) return error.InvalidWindow;
    return .{ @intFromFloat(f), @intFromFloat(end) };
}
pub fn uniqueKey(a: A, keys: *std.StringHashMap(void), key: Value) !void {
    if (key != .string and key != .integer and key != .float) return error.InvalidRowKey;
    try validate(key);
    const encoded = try std.fmt.allocPrint(a, "{s}:{s}", .{ if (key == .string) "s" else "n", try string(a, key) });
    const result = try keys.getOrPut(encoded);
    if (result.found_existing) return error.DuplicateRowKey;
}
pub fn math(comptime method: []const u8, args: []const Value) !Value {
    var value: f64 = if (std.mem.eql(u8, method, "min")) std.math.inf(f64) else -std.math.inf(f64);
    for (args) |arg| {
        const n = try number(arg);
        value = if (std.mem.eql(u8, method, "min")) @min(value, n) else @max(value, n);
    }
    return .{ .float = value };
}
pub fn stringMethod(a: A, comptime method: []const u8, value: Value, args: []const Value) !Value {
    if (value != .string) return error.ExpectedString;
    const input = value.string;
    if (comptime std.mem.eql(u8, method, "toLowerCase") or std.mem.eql(u8, method, "toUpperCase")) {
        if (args.len != 0) return error.InvalidArguments;
        // Explicit ASCII profile: reject Unicode rather than silently changing JS semantics.
        for (input) |byte| if (byte > 127) return error.UnicodeCaseMappingUnsupported;
        return .{ .string = if (comptime std.mem.eql(u8, method, "toLowerCase")) try std.ascii.allocLowerString(a, input) else try std.ascii.allocUpperString(a, input) };
    }
    if (comptime std.mem.eql(u8, method, "trim")) {
        if (args.len != 0) return error.InvalidArguments;
        for (input) |byte| if (byte > 127) return error.UnicodeTrimUnsupported;
        return .{ .string = std.mem.trim(u8, input, " \t\n\r\x0b\x0c") };
    }
    if (args.len != 1 or args[0] != .string) return error.InvalidArguments;
    const needle = args[0].string;
    return .{ .bool = if (comptime std.mem.eql(u8, method, "includes")) std.mem.indexOf(u8, input, needle) != null else if (comptime std.mem.eql(u8, method, "startsWith")) std.mem.startsWith(u8, input, needle) else std.mem.endsWith(u8, input, needle) };
}

pub fn transferCache(a: A, ctx: anytype, policy: OperationPolicy, key: Value, options: Value) !Value {
    var expires: i64 = policy.expires orelse 0;
    var tags: std.array_list.Managed(Value) = .init(a);
    for (policy.tags) |tag| try tags.append(.{ .string = tag });
    if (options == .object) {
        const ttl = try number(options.object.get("ttl") orelse return error.CacheTTLRequired);
        if (!std.math.isFinite(ttl) or ttl < 0 or ttl > 9007199254740991) return error.InvalidCacheTTL;
        const Context = switch (@typeInfo(@TypeOf(ctx))) {
            .pointer => |p| p.child,
            else => @TypeOf(ctx),
        };
        if (@typeInfo(Context) == .@"struct" and @hasField(Context, "now_ms")) {
            const limit = ctx.now_ms + @as(i64, @intFromFloat(ttl));
            expires = if (policy.expires) |backend| @min(backend, limit) else limit;
        } else return error.CacheClockRequired;
        if (options.object.get("tags")) |extra| for (try items(extra)) |tag| {
            if (tag != .string) return error.InvalidDependencyTag;
            try tags.append(tag);
        };
    }
    if (policy.no_store or policy.revalidate) expires = 0;
    return object(a, &.{ "key", "expires", "tags", "noStore", "revision" }, &.{ key, .{ .integer = expires }, .{ .array = tags }, .{ .bool = policy.no_store }, .{ .integer = @intCast(policy.revision) } });
}

pub fn publishPolicy(ctx: anytype, policy: OperationPolicy) !void {
    const Context = switch (@typeInfo(@TypeOf(ctx))) {
        .pointer => |p| p.child,
        else => @TypeOf(ctx),
    };
    if (@typeInfo(Context) == .@"struct" and @hasDecl(Context, "publrPolicy")) {
        try ctx.publrPolicy(policy);
    } else if (policy.no_store or policy.revalidate or policy.expires != null or policy.tags.len > 0) return error.PolicyHeadersRequired;
}
