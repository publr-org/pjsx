//! `Publr.t`, `Publr.tn`, `Publr.tx` in a server render: the text in the reader's language,
//! from the catalogue the host hands the render (`Translator`), else the source text, with
//! its `{name}` placeholders filled. The host decides the language and the plural form;
//! the render knows only the message.
const std = @import("std");

/// The host's catalogue: `lookup` answers the translated text of a message, the form for
/// `count` when the message has a plural, or null when it has none.
pub const Translator = struct {
    context: *const anyopaque,
    lookup: *const fn (
        context: *const anyopaque,
        message_context: []const u8,
        id: []const u8,
        plural: []const u8,
        count: ?f64,
    ) ?[]const u8,
};

pub const Placeholder = struct {
    name: []const u8,
    value: []const u8,
};

pub const Message = struct {
    context: []const u8 = "",
    id: []const u8,
    /// The source's plural (`{count} records`), empty for a message without one.
    plural: []const u8 = "",
    count: ?f64 = null,
    values: []const Placeholder = &.{},
};

/// The message as the reader reads it. `translator` is the host's `*const Translator`, or
/// null where the render has none: the source text, its English plural chosen by `count`.
pub fn translate(
    arena: std.mem.Allocator,
    translator: ?*const anyopaque,
    message: Message,
) std.mem.Allocator.Error![]const u8 {
    const found: ?[]const u8 = if (translator) |pointer| blk: {
        const host: *const Translator = @ptrCast(@alignCast(pointer));

        break :blk host.lookup(host.context, message.context, message.id, message.plural, message.count);
    } else null;
    const source = if (message.plural.len > 0 and message.count != null and message.count.? != 1)
        message.plural
    else
        message.id;

    return fill(arena, found orelse source, message);
}

/// `{name}` replaced by its value, `{count}` by the count, and `{name, select, a {…} other
/// {…}}` by the arm the value names (else `other`), itself filled; an unknown name stays as
/// it is. A select inside a select's arm is filled too, a few levels deep.
fn fill(arena: std.mem.Allocator, text: []const u8, message: Message) std.mem.Allocator.Error![]const u8 {
    return fill_depth(arena, text, message, 0);
}

const depth_max: u32 = 4;

fn fill_depth(arena: std.mem.Allocator, text: []const u8, message: Message, depth: u32) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '{') == null or depth == depth_max) return text;

    var out: std.Io.Writer.Allocating = .init(arena);
    var index: usize = 0;

    while (index < text.len) {
        const open = std.mem.indexOfScalarPos(u8, text, index, '{') orelse {
            out.writer.writeAll(text[index..]) catch return error.OutOfMemory;
            break;
        };
        const close = matching(text, open) orelse {
            out.writer.writeAll(text[index..]) catch return error.OutOfMemory;
            break;
        };

        out.writer.writeAll(text[index..open]) catch return error.OutOfMemory;

        const inner = text[open + 1 .. close];
        const written = if (std.mem.indexOf(u8, inner, ", select,")) |at|
            try fill_depth(arena, arm_of(inner, at, try value_of(arena, inner[0..at], message)), message, depth + 1)
        else
            try value_of(arena, inner, message);

        out.writer.writeAll(written orelse text[open .. close + 1]) catch return error.OutOfMemory;
        index = close + 1;
    }

    return out.written();
}

/// The `}` that closes the `{` at `open`, counting the ones nested inside.
fn matching(text: []const u8, open: usize) ?usize {
    var depth: u32 = 0;
    var index = open;

    while (index < text.len) : (index += 1) {
        if (text[index] == '{') depth += 1;
        if (text[index] == '}') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }

    return null;
}

/// The arm of `name, select, key {text} … other {text}` that `value` names, else `other`'s.
fn arm_of(inner: []const u8, at: usize, value: ?[]const u8) []const u8 {
    var rest = inner[at + ", select,".len ..];
    var fallback: []const u8 = "";

    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        const key = std.mem.trim(u8, rest[0..open], " ");
        const close = matching(rest, open) orelse break;
        const arm = rest[open + 1 .. close];

        if (value != null and std.mem.eql(u8, key, value.?)) return arm;
        if (std.mem.eql(u8, key, "other")) fallback = arm;
        rest = rest[close + 1 ..];
    }

    return fallback;
}

fn value_of(arena: std.mem.Allocator, name: []const u8, message: Message) std.mem.Allocator.Error!?[]const u8 {
    for (message.values) |placeholder| {
        if (std.mem.eql(u8, placeholder.name, name)) return placeholder.value;
    }

    if (std.mem.eql(u8, name, "count")) {
        if (message.count) |count| return try @import("semantics.zig").number_to_string(arena, count);
    }

    return null;
}

test "the source text without a catalogue, its plural by count, placeholders filled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("Save", try translate(arena, null, .{ .id = "Save" }));
    try std.testing.expectEqualStrings("3 records", try translate(arena, null, .{
        .id = "{count} record",
        .plural = "{count} records",
        .count = 3,
    }));
    try std.testing.expectEqualStrings("Kept for 30 days", try translate(arena, null, .{
        .id = "Kept for {days} days",
        .values = &.{.{ .name = "days", .value = "30" }},
    }));
}

test "select: the arm the value names, else other, filled in turn" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "{type.gender, select, feminine {Nowa} neuter {Nowe} other {Nowy}} {type}";
    const feminine = try translate(arena, null, .{
        .id = text,
        .values = &.{ .{ .name = "type.gender", .value = "feminine" }, .{ .name = "type", .value = "strona" } },
    });
    const unknown = try translate(arena, null, .{
        .id = text,
        .values = &.{.{ .name = "type", .value = "produkt" }},
    });

    try std.testing.expectEqualStrings("Nowa strona", feminine);
    try std.testing.expectEqualStrings("Nowy produkt", unknown);
}

test "a catalogue's text, chosen by the host" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Polish = struct {
        fn lookup(_: *const anyopaque, _: []const u8, id: []const u8, _: []const u8, count: ?f64) ?[]const u8 {
            if (std.mem.eql(u8, id, "Save")) return "Zapisz";
            if (count != null) return "{count} rekordów";
            return null;
        }
    };
    const host: Translator = .{ .context = &arena_state, .lookup = Polish.lookup };

    try std.testing.expectEqualStrings("Zapisz", try translate(arena, &host, .{ .id = "Save" }));
    try std.testing.expectEqualStrings("5 rekordów", try translate(arena, &host, .{
        .id = "{count} record",
        .plural = "{count} records",
        .count = 5,
    }));
}
