//! A view's compiled expressions on the server. The consumer runs them with its
//! JavaScript engine (`Expressions`); the answer comes back as JSON and is written
//! the way the browser's runtime applies the same value after hydration
//! (`publr-js/src/core/directives.ts`), so the first render and the live page agree.

const std = @import("std");
const semantics = @import("semantics.zig");

/// What runs compiled expressions: the consumer's engine, reached through the
/// request a render hands down.
pub const Expressions = struct {
    context: *anyopaque,
    /// Memory for one call's scope and answer, made free again after the call.
    scratch: *const fn (context: *anyopaque) std.mem.Allocator,
    reset: *const fn (context: *anyopaque) void,
    /// Runs `slot` of `module` with the module's state and the slot's scope, both
    /// JSON objects; answers the value as JSON, or `undefined`. One render instance
    /// hands the same `state` slice to every slot, so an engine may key work on it.
    run: *const fn (
        context: *anyopaque,
        arena: std.mem.Allocator,
        module: []const u8,
        slot: []const u8,
        state: []const u8,
        scope: []const u8,
    ) anyerror![]const u8,
};

/// A JavaScript value as the server read it back.
pub const Value = union(enum) {
    undefined,
    null,
    boolean: bool,
    number: f64,
    string: []const u8,
    /// An array or object, as JSON: a list's rows, a class array.
    json: []const u8,
};

/// JSON as it is, for a field whose value the compiler already wrote.
pub const Json = struct {
    text: []const u8,
};

pub const Error = error{ OutOfMemory, NoExpressions } || anyerror;

/// Runs a compiled expression with the scope `fields` (a struct of the names it
/// reads); `expressions` is the request's (null in a render that has no engine,
/// which a view with compiled expressions cannot do). The scope and the answer
/// live in the engine's scratch; the value, in `arena`.
pub fn evaluate(
    expressions: ?*const anyopaque,
    arena: std.mem.Allocator,
    module: []const u8,
    slot: []const u8,
    state: []const u8,
    fields: anytype,
) Error!Value {
    const engine: *const Expressions = @ptrCast(@alignCast(expressions orelse return error.NoExpressions));
    const scratch = engine.scratch(engine.context);
    defer engine.reset(engine.context);

    const scope = object(scratch, fields) catch try object(arena, fields);
    const answer = try engine.run(engine.context, scratch, module, slot, state, scope);
    return parse(arena, answer);
}

/// The engine's answer: `undefined`, or a value's JSON.
pub fn parse(arena: std.mem.Allocator, answer: []const u8) Error!Value {
    const text = std.mem.trim(u8, answer, " \n");
    if (text.len == 0 or std.mem.eql(u8, text, "undefined")) return .undefined;
    if (std.mem.eql(u8, text, "null")) return .null;
    if (std.mem.eql(u8, text, "true")) return .{
        .boolean = true,
    };
    if (std.mem.eql(u8, text, "false")) return .{
        .boolean = false,
    };
    switch (text[0]) {
        '"' => return .{
            .string = try std.json.parseFromSliceLeaky([]const u8, arena, text, .{
                .allocate = .alloc_always,
            }),
        },
        '[', '{' => return .{
            .json = try arena.dupe(u8, text),
        },
        else => return .{
            .number = std.fmt.parseFloat(f64, text) catch return .undefined,
        },
    }
}

/// JavaScript truthiness.
pub fn truthy(value: Value) bool {
    return switch (value) {
        .undefined, .null => false,
        .boolean => |boolean| boolean,
        .number => |number| number != 0 and !std.math.isNan(number),
        .string => |text| text.len != 0,
        .json => true,
    };
}

/// The value as JSX writes a child: nothing for null, undefined and booleans.
pub fn write_text(w: *std.Io.Writer, value: Value, escape: anytype) !void {
    switch (value) {
        .undefined, .null, .boolean => {},
        .number => |number| try semantics.write_number(w, number),
        .string => |text| try escape(w, text),
        .json => |text| try escape(w, text),
    }
}

/// The value as a bound attribute: absent for null, undefined and false; bare for
/// true; an `aria-*` boolean spelled out. Writes its own leading space.
pub fn write_attribute(w: *std.Io.Writer, name: []const u8, value: Value, escape: anytype) !void {
    switch (value) {
        .undefined, .null => {},
        .boolean => |boolean| if (std.mem.startsWith(u8, name, "aria-")) {
            try w.print(" {s}=\"{s}\"", .{ name, if (boolean) "true" else "false" });
        } else if (boolean) {
            try w.print(" {s}", .{name});
        },
        .number => |number| {
            try w.print(" {s}=\"", .{name});
            try semantics.write_number(w, number);
            try w.writeAll("\"");
        },
        .string => |text| {
            try w.print(" {s}=\"", .{name});
            try escape(w, text);
            try w.writeAll("\"");
        },
        .json => |text| {
            try w.print(" {s}=\"", .{name});
            try escape(w, text);
            try w.writeAll("\"");
        },
    }
}

/// The value as a class layer: a string, or an array of them, falsy items left out.
pub fn classes(arena: std.mem.Allocator, value: Value) Error![]const u8 {
    switch (value) {
        .undefined, .null, .boolean => return "",
        .number => |number| return semantics.number_to_string(arena, number),
        .string => |text| return text,
        .json => |text| {
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return "";
            var out: std.Io.Writer.Allocating = .init(arena);
            try write_class_items(&out.writer, parsed);
            return std.mem.trim(u8, out.written(), " ");
        },
    }
}

fn write_class_items(w: *std.Io.Writer, item: std.json.Value) !void {
    switch (item) {
        .string => |text| if (text.len > 0) try w.print("{s} ", .{text}),
        .array => |items| for (items.items) |inner| {
            if (inner != .array) {
                try write_class_items(w, inner);
            }
        },
        else => {},
    }
}

/// The value as a typed prop: a string, a number, a boolean, an enum by its tag, an
/// optional of those, or a slice or struct read from JSON.
pub fn into(comptime T: type, arena: std.mem.Allocator, value: Value) Error!T {
    switch (@typeInfo(T)) {
        .optional => |optional| return switch (value) {
            .undefined, .null => null,
            else => try into(optional.child, arena, value),
        },
        .bool => return truthy(value),
        .float => return switch (value) {
            .number => |number| @floatCast(number),
            .boolean => |boolean| if (boolean) 1 else 0,
            else => std.math.nan(T),
        },
        .@"enum" => return switch (value) {
            .string => |text| std.meta.stringToEnum(T, text) orelse error.InvalidEnumTag,
            else => error.InvalidEnumTag,
        },
        else => {},
    }
    if (T == []const u8) return switch (value) {
        .undefined, .null => "",
        .boolean => |boolean| if (boolean) "true" else "false",
        .number => |number| try semantics.number_to_string(arena, number),
        .string => |text| text,
        .json => |text| text,
    };
    return switch (value) {
        .json => |text| try std.json.parseFromSliceLeaky(T, arena, text, .{
            .ignore_unknown_fields = true,
        }),
        else => error.UnexpectedToken,
    };
}

/// A Zig value as the engine would hand it back: strings, numbers, booleans, enum
/// tags, an absent optional as `undefined`, anything else as JSON.
pub fn of(arena: std.mem.Allocator, value: anytype) Error!Value {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => return if (value) |present| of(arena, present) else .undefined,
        .bool => return .{
            .boolean = value,
        },
        .float, .comptime_float => return .{
            .number = value,
        },
        .int, .comptime_int => return .{
            .number = @floatFromInt(value),
        },
        .@"enum" => return .{
            .string = @tagName(value),
        },
        .null => return .null,
        else => {},
    }
    if (T == []const u8) return .{
        .string = value,
    };
    if (comptime @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one and @typeInfo(@typeInfo(T).pointer.child) == .array) {
        return .{
            .string = value,
        };
    }
    return .{
        .json = try std.json.Stringify.valueAlloc(arena, value, .{}),
    };
}

/// Which of `tags` a value names: its index, or `tags.len` when none (or not a string).
pub fn tag(arena: std.mem.Allocator, value: Value, tags: []const []const u8) Error!usize {
    _ = arena;
    if (value != .string) return tags.len;
    for (tags, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, value.string)) return index;
    }
    return tags.len;
}

/// A render instance for its compiled expressions: its state and its props as the
/// render holds them, written as JSON (`{"state":…,"props":…}`) on the first
/// expression that runs, once.
pub fn Instance(comptime StateFields: type, comptime PropsFields: type) type {
    return struct {
        state: StateFields,
        props: PropsFields,
        json: ?[]const u8 = null,
        state_json: ?[]const u8 = null,

        pub fn text(held: *@This(), arena: std.mem.Allocator) Error![]const u8 {
            if (held.json) |written| return written;
            const state_object = try held.state_text(arena);
            const props_object = try object(arena, held.props);
            held.json = try std.mem.concat(arena, u8, &.{ "{\"state\":", state_object, ",\"props\":", props_object, "}" });
            return held.json.?;
        }

        /// The state alone, as a family's parts read it.
        pub fn state_text(held: *@This(), arena: std.mem.Allocator) Error![]const u8 {
            if (held.state_json) |written| return written;
            held.state_json = try object(arena, held.state);
            return held.state_json.?;
        }
    };
}

/// A family root's state as its parts read it on the server: the store it is, the render
/// instance that holds it, and the family the root itself renders inside, so a part reaches
/// the nearest root of its own family past any other family between them.
pub const Family = struct {
    store: []const u8,
    held: *anyopaque,
    state_fn: *const fn (*anyopaque, std.mem.Allocator) Error![]const u8,
    parent: ?*const Family,
};

/// The family a root's render hands down, over its render instance (`held`).
pub fn family_of(store: []const u8, held: anytype, parent: ?*const Family) Family {
    const Held = @TypeOf(held.*);
    const Thunk = struct {
        fn state(context: *anyopaque, arena: std.mem.Allocator) Error![]const u8 {
            const instance_held: *Held = @ptrCast(@alignCast(context));
            return instance_held.state_text(arena);
        }
    };
    return .{
        .store = store,
        .held = held,
        .state_fn = &Thunk.state,
        .parent = parent,
    };
}

/// The state of the nearest root of `store` above a part, as JSON; `initial` (the store's
/// initial state, as a part with no root shares it in the browser) when there is none.
pub fn family_state(arena: std.mem.Allocator, family: ?*const Family, store: []const u8, initial: []const u8) Error!Json {
    var current = family;
    while (current) |found| : (current = found.parent) {
        if (std.mem.eql(u8, found.store, store)) return .{
            .text = try found.state_fn(found.held, arena),
        };
    }
    return .{
        .text = initial,
    };
}

pub fn instance(state: anytype, props: anytype) Instance(@TypeOf(state), @TypeOf(props)) {
    return .{
        .state = state,
        .props = props,
    };
}

/// A state or scope as a JSON object, from a struct of its fields: an absent
/// optional is left out, so the expression reads it as `undefined`.
pub fn object(arena: std.mem.Allocator, fields: anytype) Error![]const u8 {
    // Measured, then written once into exactly its size: grown a step at a time, every
    // outgrown buffer would stay in the arena, twice the object or more in all.
    var counting: std.Io.Writer.Discarding = .init(&.{});
    try write_object(&counting.writer, arena, fields);

    const bytes = try arena.alloc(u8, @intCast(counting.count));
    var out: std.Io.Writer = .fixed(bytes);
    try write_object(&out, arena, fields);
    std.debug.assert(out.end == bytes.len);
    return bytes;
}

fn write_object(w: *std.Io.Writer, arena: std.mem.Allocator, fields: anytype) !void {
    try w.writeAll("{");
    var separator: []const u8 = "";
    inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |field| {
        const value = @field(fields, field.name);
        const absent = comptime @typeInfo(field.type) == .optional;
        if (!absent or value != null) {
            try write_field(w, arena, separator, field.name, value);
            separator = ",";
        }
    }
    try w.writeAll("}");
}

/// A state or scope field as JSON (`"name":value`), written after `separator`.
pub fn write_field(w: *std.Io.Writer, arena: std.mem.Allocator, separator: []const u8, name: []const u8, value: anytype) !void {
    try w.print("{s}\"{s}\":", .{ separator, name });
    try write_json(w, arena, value);
}

/// A Zig value as JSON: an absent optional as `null` (a field left out reads as
/// `undefined` anyway), markup as `true` when there is some.
pub fn write_json(w: *std.Io.Writer, arena: std.mem.Allocator, value: anytype) !void {
    const T = @TypeOf(value);
    if (@typeInfo(T) == .optional) {
        if (value) |present| return write_json(w, arena, present);
        return w.writeAll("null");
    }
    if (T == Json) return w.writeAll(value.text);
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "is_empty")) {
        return w.writeAll(if (value.is_empty(arena)) "null" else "true");
    }
    // Straight into the writer: never a copy of the value's JSON in the arena first.
    try std.json.Stringify.value(value, .{}, w);
}

fn test_escape(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll(text);
}

test "an object leaves an absent optional out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try object(a, .{
        .tone = @as(?[]const u8, null),
        .size = "sm",
        .open = true,
    });
    try std.testing.expectEqualStrings("{\"size\":\"sm\",\"open\":true}", text);
}

test "an answer reads back as the value it was" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Value.undefined, try parse(a, "undefined"));
    try std.testing.expectEqualStrings("a\"b", (try parse(a, "\"a\\\"b\"")).string);
    try std.testing.expectEqual(@as(f64, 2.5), (try parse(a, "2.5")).number);
    try std.testing.expectEqualStrings("[1,2]", (try parse(a, "[1,2]")).json);
    try std.testing.expect(!truthy(try parse(a, "\"\"")));
    try std.testing.expect(truthy(try parse(a, "[]")));
}

test "a value writes as an attribute, a text, a class list and a typed prop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    try write_attribute(&out.writer, "disabled", .{
        .boolean = true,
    }, test_escape);
    try write_attribute(&out.writer, "aria-busy", .{
        .boolean = false,
    }, test_escape);
    try write_attribute(&out.writer, "hidden", .{
        .boolean = false,
    }, test_escape);
    try write_attribute(&out.writer, "href", .undefined, test_escape);
    try write_attribute(&out.writer, "title", .{
        .string = "x",
    }, test_escape);
    try std.testing.expectEqualStrings(" disabled aria-busy=\"false\" title=\"x\"", out.written());
    out.clearRetainingCapacity();
    try write_text(&out.writer, .{
        .number = 3,
    }, test_escape);
    try write_text(&out.writer, .{
        .boolean = true,
    }, test_escape);
    try std.testing.expectEqualStrings("3", out.written());
    try std.testing.expectEqualStrings("a b", try classes(a, .{
        .json = "[\"a\", \"\", false, \"b\"]",
    }));
    const Size = enum { sm, lg };
    try std.testing.expectEqual(Size.lg, try into(Size, a, .{
        .string = "lg",
    }));
    try std.testing.expectEqual(@as(?Size, null), try into(?Size, a, .undefined));
    const Row = struct {
        id: []const u8,
    };
    const rows = try into([]const Row, a, .{
        .json = "[{\"id\":\"a\",\"extra\":1}]",
    });
    try std.testing.expectEqualStrings("a", rows[0].id);
}
