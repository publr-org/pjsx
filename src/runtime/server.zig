//! What `zig`-target generated views need at run time, and nothing more: HTML
//! escaping, the class-stack merge, wire attributes, the slot (`asChild`)
//! merge, and `Node`, the shape of a `node` prop. The lowering
//! (`targets/zig.zig`) routes every `{expr}` of string type through `escape`;
//! a `node` prop is markup by construction (a caller's children streamed into
//! the callee's writer, or a string an app already rendered), so `escape` is
//! the only place user data meets markup.
//!
//! This file is not part of the library module: consumers wire it as their
//! generated code's `runtime` module, providing a `class_merge` import — a
//! module exposing `merge_classes(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8`,
//! typically a Tailwind-aware resolver so a later conflicting utility wins
//! (`max-w-xl` after `max-w-md` removes the earlier one). A plain
//! space-join is a valid minimal implementation. Results must remain valid for
//! the render arena's lifetime; allocation errors propagate to the renderer.
const std = @import("std");
pub const semantics = @import("semantics.zig");
pub const write_number = semantics.write_number;
pub const number_to_string = semantics.number_to_string;
pub const number_min = semantics.number_min;
pub const number_max = semantics.number_max;
pub const number_rem = semantics.number_rem;
const class_merge = @import("class_merge");

/// A `node` prop: markup that renders into whatever writer the callee hands
/// it, when the callee gets there. A caller's children are a `block` — the
/// generated capture struct and its render function — so nesting costs no
/// buffer and no copy; markup an app rendered ahead of time is `raw`.
pub const Node = struct {
    raw: ?[]const u8 = null,
    ctx: *const anyopaque = undefined,
    render_fn: ?*const fn (*const anyopaque, *std.Io.Writer, std.mem.Allocator) anyerror!void = null,

    pub fn render(node: Node, w: *std.Io.Writer, arena: std.mem.Allocator) anyerror!void {
        if (node.raw) |html| return w.writeAll(html);
        return node.render_fn.?(node.ctx, w, arena);
    }

    /// The JavaScript truthiness of a node: whether it renders anything. A raw
    /// string knows; a block renders once into a counting sink to find out.
    pub fn is_empty(node: Node, arena: std.mem.Allocator) bool {
        if (node.raw) |html| return html.len == 0;
        var probe: std.Io.Writer.Discarding = .init(&.{});
        node.render(&probe.writer, arena) catch return false;
        return probe.count + probe.writer.end == 0;
    }
};

pub const empty_node: Node = .{ .raw = "" };

/// Markup rendered ahead of time, written as it is.
pub fn raw(html: []const u8) Node {
    return .{ .raw = html };
}

/// A caller's children: `capture` points at the generated capture struct (the
/// props and loop items the block reads), `Body.render(capture, w, arena)`
/// writes them. The capture must outlive the callee's render call, which the
/// generated block scope guarantees.
pub fn block(capture: anytype, comptime Body: type) Node {
    const Capture = @TypeOf(capture.*);
    const Thunk = struct {
        fn call(ctx: *const anyopaque, w: *std.Io.Writer, arena: std.mem.Allocator) anyerror!void {
            const self: *const Capture = @ptrCast(@alignCast(ctx));
            return Body.render(self.*, w, arena);
        }
    };
    return .{ .ctx = capture, .render_fn = &Thunk.call };
}

/// A node as a string, for the two places that need to look at the markup:
/// the slot merge and an app's own splicing.
pub fn render_to_string(arena: std.mem.Allocator, node: Node) ![]const u8 {
    if (node.raw) |html| return html;
    var out: std.Io.Writer.Allocating = .init(arena);
    try node.render(&out.writer, arena);
    return out.written();
}

test "a block node streams into the writer it is given and knows when it is empty" {
    const Body = struct {
        fn render(cap: anytype, w: *std.Io.Writer, arena: std.mem.Allocator) anyerror!void {
            _ = &arena;
            const label = cap.label.*;
            try w.writeAll("<b>");
            try escape(w, label);
            try w.writeAll("</b>");
        }
    };
    const label: []const u8 = "a & b";
    const capture = .{ .label = &label };
    const node = block(&capture, Body);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try node.render(&out.writer, std.testing.allocator);
    try std.testing.expectEqualStrings("<b>a &amp; b</b>", out.written());
    try std.testing.expect(!node.is_empty(std.testing.allocator));
    try std.testing.expect(raw("").is_empty(std.testing.allocator));
    try std.testing.expect(!raw("x").is_empty(std.testing.allocator));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("<b>a &amp; b</b>", try render_to_string(arena_state.allocator(), node));
}

/// Array schemas are structural in PJSX; generated Zig modules own distinct
/// item types. Convert at component boundaries, including nested arrays.
pub fn prop_array(comptime Target: type, arena: std.mem.Allocator, source: anytype) !Target {
    if (Target == @TypeOf(source)) return source;
    const Item = @typeInfo(Target).pointer.child;
    const result = try arena.alloc(Item, source.len);
    for (source, result) |item, *output| {
        output.* = try prop_value(Item, arena, item);
    }
    return result;
}

fn prop_value(comptime Target: type, arena: std.mem.Allocator, source: anytype) error{OutOfMemory}!Target {
    if (Target == @TypeOf(source)) return source;
    switch (@typeInfo(Target)) {
        .@"struct" => |info| {
            var result: Target = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = try prop_value(field.type, arena, @field(source, field.name));
            }
            return result;
        },
        .pointer => |info| {
            if (info.size == .slice) return prop_array(Target, arena, source);
        },
        .optional => |info| {
            if (@typeInfo(@TypeOf(source)) == .optional) {
                return if (source) |value| try prop_value(info.child, arena, value) else null;
            }
            return try prop_value(info.child, arena, source);
        },
        .@"enum" => return std.meta.stringToEnum(Target, @tagName(source)) orelse
            @panic("incompatible array prop enum"),
        else => {},
    }
    return source;
}

test "array props cross module types with nested values and empty slices intact" {
    const SourceOption = struct { label: []const u8, selected: bool, kind: enum { first, second } };
    const TargetOption = struct { label: []const u8, selected: bool, kind: enum { second, first } };
    const Source = struct { name: []const u8, options: []const SourceOption, help: ?[]const u8 };
    const Target = struct { name: []const u8, options: []const TargetOption, help: ?[]const u8 };
    const source: []const Source = &.{
        .{ .name = "first", .options = &.{.{ .label = "A & B", .selected = true, .kind = .first }}, .help = "Help" },
        .{ .name = "second", .options = &.{}, .help = null },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try prop_array([]const Target, arena, source);

    try std.testing.expectEqualStrings("first", result[0].name);
    try std.testing.expectEqualStrings("A & B", result[0].options[0].label);
    try std.testing.expect(result[0].options[0].selected);
    try std.testing.expectEqual(.first, result[0].options[0].kind);
    try std.testing.expectEqualStrings("Help", result[0].help.?);
    try std.testing.expectEqualStrings("second", result[1].name);
    try std.testing.expectEqual(@as(usize, 0), result[1].options.len);
    try std.testing.expectEqual(null, result[1].help);
    const empty = try prop_array([]const Target, arena, source[0..0]);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const same = try prop_array([]const Source, arena, source);
    try std.testing.expectEqual(source.ptr, same.ptr);
}

test "array prop conversion reports allocation failures at every nesting level" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const SourceValue = struct { text: []const u8 };
            const Source = struct { values: []const SourceValue };
            const Target = struct { values: []const struct { text: []const u8 } };
            const values = [_]SourceValue{.{ .text = "nested" }} ** 256;
            const source: []const Source = &.{.{ .values = &values }};
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const result = try prop_array([]const Target, arena_state.allocator(), source);
            try std.testing.expectEqual(@as(usize, 256), result[0].values.len);
            try std.testing.expectEqualStrings("nested", result[0].values[0].text);
        }
    }.run, .{});
}

/// Writes `text` with the five HTML-special characters entity-escaped.
pub fn escape(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |char| {
        switch (char) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(char),
        }
    }
}

/// A stack of `class` attributes as one merged class list — the consumer's
/// resolver decides how conflicts settle.
pub fn merge_classes(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return class_merge.merge_classes(arena, parts);
}

/// Writes a merged class stack, escaped, into an attribute value the caller
/// has already opened.
pub fn write_merged(w: *std.Io.Writer, arena: std.mem.Allocator, parts: []const []const u8) !void {
    try escape(w, try merge_classes(arena, parts));
}

pub const Wire = struct {
    /// `click:`, `keydown.enter.prevent:` — the event descriptor with its
    /// trailing separator.
    prefix: []const u8,
    /// The action name; a null (an unset action prop) contributes nothing.
    value: ?[]const u8,
};

/// Writes one ` name="p1v1;p2v2"` attribute from the wires whose action is
/// set — or nothing at all when none is.
pub fn write_wire_attr(w: *std.Io.Writer, name: []const u8, wires: []const Wire) !void {
    var any = false;

    for (wires) |wire| {
        if (wire.value == null) continue;

        if (!any) {
            try w.writeAll(" ");
            try w.writeAll(name);
            try w.writeAll("=\"");
        } else {
            try w.writeAll(";");
        }
        any = true;
        try escape(w, wire.prefix);
        try escape(w, wire.value.?);
    }

    if (any) {
        try w.writeAll("\"");
    }
}

/// Joins string parts into one arena slice; empty parts are kept verbatim.
pub fn concat(arena: std.mem.Allocator, parts: []const []const u8) []const u8 {
    var length: usize = 0;
    for (parts) |part| length += part.len;
    const out = arena.alloc(u8, length) catch return "";
    var offset: usize = 0;
    for (parts) |part| {
        @memcpy(out[offset .. offset + part.len], part);
        offset += part.len;
    }
    return out;
}

// ---- prop wires --------------------------------------------------------------
//
// A component called with a wired prop (`publr_bind_<prop>`) re-emits the wire
// wherever it uses the prop, composed at render time: a value derived from the
// prop becomes a match over the caller's wire (`($row.nested -> 'small' ~
// 'default') { 'small': 'gap-2', 'default': 'gap-3' }`), a nested value spec
// in parentheses where the wire language takes a ref.

/// One arm of `wire_match`: a key as wire text (`'small'`, `true`, `_`) and
/// its payload spec; a null payload leaves the arm out (no value).
pub const WireArm = struct { key: []const u8, value: ?[]const u8 };

/// A wire as an operand: a plain `$path` or a quoted literal as is, anything
/// else parenthesized.
pub fn wire_group(arena: std.mem.Allocator, wire: []const u8) []const u8 {
    if (wire.len >= 2 and (wire[0] == '\'' or wire[0] == '"') and wire[wire.len - 1] == wire[0] and
        std.mem.indexOfScalar(u8, wire[1 .. wire.len - 1], wire[0]) == null) return wire;
    for (wire) |char| {
        const plain = std.ascii.isAlphanumeric(char) or char == '$' or char == '_' or char == '.' or char == ':';
        if (!plain) return concat(arena, &.{ "(", wire, ")" });
    }
    return wire;
}

/// `(disc) { key: payload, … }`, the arms with no payload left out.
pub fn wire_match(arena: std.mem.Allocator, disc: []const u8, arms: []const WireArm) []const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.print("{s} {{", .{wire_group(arena, disc)}) catch return "";
    var first = true;
    for (arms) |arm| {
        const value = arm.value orelse continue;
        out.writer.print("{s} {s}: {s}", .{ if (first) "" else ",", arm.key, wire_group(arena, value) }) catch return "";
        first = false;
    }
    out.writer.writeAll(" }") catch return "";
    return out.written();
}

/// A prop as a wire operand: its caller's wire when it has one, else its value
/// as a wire literal.
pub fn wire_value(arena: std.mem.Allocator, wire: ?[]const u8, value: anytype) []const u8 {
    if (wire) |present| return wire_group(arena, present);
    return wire_literal(arena, value);
}

/// A value as wire text: strings quoted, `null` for an absent optional.
pub fn wire_literal(arena: std.mem.Allocator, value: anytype) []const u8 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => return if (value) |inner| wire_literal(arena, inner) else "null",
        .bool => return if (value) "true" else "false",
        .float, .comptime_float => return number_to_string(arena, value) catch "",
        .@"enum" => return wire_literal(arena, @as([]const u8, @tagName(value))),
        else => {
            const text: []const u8 = value;
            const quote: []const u8 = if (std.mem.indexOfScalar(u8, text, '\'') == null) "'" else "\"";
            return concat(arena, &.{ quote, text, quote });
        },
    }
}

/// Joins the present, non-empty values with `sep`; null when none is.
pub fn join_optionals(arena: std.mem.Allocator, values: []const ?[]const u8, sep: []const u8) ?[]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var any = false;
    for (values) |value| {
        const present = value orelse continue;
        if (present.len == 0) continue;
        if (any) out.writer.writeAll(sep) catch return null;
        out.writer.writeAll(present) catch return null;
        any = true;
    }
    return if (any) out.written() else null;
}

/// Toggles a leading `not ` on a wire; null-preserving.
pub fn invert_wire(arena: std.mem.Allocator, wire: ?[]const u8) ?[]const u8 {
    const spec = wire orelse return null;
    if (std.mem.startsWith(u8, spec, "not ")) return spec[4..];
    return concat(arena, &.{ "not ", spec });
}

/// The `name?={value}` attribute: bool and ?bool are presence, an optional
/// value renders `name="value"` when present, anything else always renders.
/// Emits its own leading space; string values are escaped.
pub fn write_attr_cond(w: *std.Io.Writer, name: []const u8, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => if (value) try w.print(" {s}", .{name}),
        .optional => |optional| if (value) |inner| {
            if (optional.child == bool) {
                if (inner) try w.print(" {s}", .{name});
            } else {
                try write_attr_value(w, name, inner);
            }
        },
        .null => {},
        else => try write_attr_value(w, name, value),
    }
}

fn write_attr_value(w: *std.Io.Writer, name: []const u8, value: anytype) !void {
    try w.print(" {s}=\"", .{name});
    switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => try w.print("{d}", .{value}),
        else => try escape(w, value),
    }
    try w.writeAll("\"");
}

// ---- the slot merge (`asChild`) --------------------------------------------
//
// A trigger-style component may merge its behavior attributes (`data-p-*`
// wires, ARIA state, classes) straight onto the caller's child element instead
// of rendering its own wrapper — the Radix `asChild` pattern. The child is an
// already-rendered HTML string here, so the merge is a string transform on its
// first real element's opening tag, mirroring the DOM runtime (`slotProps`):
// ordinary attributes are component-owned and replace child values; `class`
// merges with a space, `style` and `data-p-on` with `;`, in child-first order.

fn is_tag_start(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// Byte offset in `html` where extra attributes can be inserted — just before
/// the first opening tag's closing `>` (or the `/` of `/>`). Quote-aware so a
/// `>` inside an attribute value doesn't fool it.
fn root_attr_insert_pos(html: []const u8) ?usize {
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        if (html[i] == '<' and i + 1 < html.len and is_tag_start(html[i + 1])) break;
    }
    if (i >= html.len) return null;
    var j = i + 1;
    var quote: u8 = 0;
    while (j < html.len) : (j += 1) {
        const c = html[j];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '>') break;
    }
    if (j >= html.len) return null;
    return if (j > 0 and html[j - 1] == '/') j - 1 else j;
}

const AttrRange = struct { start: usize, end: usize };

fn root_attr_range(html: []const u8, name: []const u8) ?AttrRange {
    const close = root_attr_insert_pos(html) orelse return null;
    var i: usize = 1;
    while (i < close and !std.ascii.isWhitespace(html[i]) and html[i] != '/') : (i += 1) {}
    while (i < close) {
        const start = i;
        while (i < close and std.ascii.isWhitespace(html[i])) : (i += 1) {}
        if (i >= close or html[i] == '/') break;
        const name_start = i;
        while (i < close and !std.ascii.isWhitespace(html[i]) and html[i] != '=' and html[i] != '/') : (i += 1) {}
        const attr_name = html[name_start..i];
        while (i < close and std.ascii.isWhitespace(html[i])) : (i += 1) {}
        if (i < close and html[i] == '=') {
            i += 1;
            while (i < close and std.ascii.isWhitespace(html[i])) : (i += 1) {}
            if (i < close and (html[i] == '"' or html[i] == '\'')) {
                const quote = html[i];
                i += 1;
                while (i < close and html[i] != quote) : (i += 1) {}
                if (i < close) i += 1;
            } else {
                while (i < close and !std.ascii.isWhitespace(html[i])) : (i += 1) {}
            }
        }
        if (std.mem.eql(u8, attr_name, name)) return .{ .start = start, .end = i };
    }
    return null;
}

fn splice(arena: std.mem.Allocator, html: []const u8, at: usize, insertion: []const u8) []const u8 {
    const out = arena.alloc(u8, html.len + insertion.len) catch return html;
    @memcpy(out[0..at], html[0..at]);
    @memcpy(out[at .. at + insertion.len], insertion);
    @memcpy(out[at + insertion.len ..], html[at..]);
    return out;
}

fn replace_range(arena: std.mem.Allocator, html: []const u8, range: AttrRange, replacement: []const u8) []const u8 {
    const size = html.len - (range.end - range.start) + replacement.len;
    const out = arena.alloc(u8, size) catch return html;
    @memcpy(out[0..range.start], html[0..range.start]);
    @memcpy(out[range.start .. range.start + replacement.len], replacement);
    @memcpy(out[range.start + replacement.len ..], html[range.end..]);
    return out;
}

fn encoded_attr_value(attribute: []const u8) []const u8 {
    const quote = std.mem.indexOfAny(u8, attribute, "\"'") orelse return "";
    const end = std.mem.lastIndexOfScalar(u8, attribute, attribute[quote]) orelse return "";
    return if (end > quote) attribute[quote + 1 .. end] else "";
}

fn merge_slot_attr(arena: std.mem.Allocator, html: []const u8, comptime name: []const u8, value: anytype) []const u8 {
    var rendered: std.Io.Writer.Allocating = .init(arena);
    write_attr_cond(&rendered.writer, name, value) catch return html;
    const attribute = rendered.written();
    if (attribute.len == 0) return html;
    const existing = root_attr_range(html, name) orelse {
        const at = root_attr_insert_pos(html) orelse return html;
        return splice(arena, html, at, attribute);
    };

    const sep = if (std.mem.eql(u8, name, "class"))
        " "
    else if (std.mem.eql(u8, name, "style") or std.mem.eql(u8, name, "data-p-on") or std.mem.eql(u8, name, "data-p-ref") or std.mem.eql(u8, name, "data-p-bind"))
        ";"
    else
        return replace_range(arena, html, existing, attribute);
    const previous = encoded_attr_value(html[existing.start..existing.end]);
    const next = encoded_attr_value(attribute);
    if (next.len == 0) return html;
    const merged = std.fmt.allocPrint(
        arena,
        " {s}=\"{s}{s}{s}\"",
        .{ name, previous, if (previous.len == 0) "" else sep, next },
    ) catch return html;
    return replace_range(arena, html, existing, merged);
}

/// Byte offset of the tag slot props must merge onto: transparent
/// `data-component=…; display:contents` component wrappers are skipped — a
/// box-less node has no rect to anchor to, and the DOM Slot runtime never
/// sees it either.
fn slot_merge_base(html: []const u8) usize {
    var base: usize = 0;
    while (true) {
        var i = base;
        while (i < html.len and !(html[i] == '<' and i + 1 < html.len and is_tag_start(html[i + 1]))) : (i += 1) {}
        if (i >= html.len) return base;
        const slice = html[i..];
        const close = root_attr_insert_pos(slice) orelse return i;
        const open_tag = slice[0..close];
        const transparent = std.mem.indexOf(u8, open_tag, "data-component=") != null and
            std.mem.indexOf(u8, open_tag, "display:contents") != null;
        if (!transparent) return i;
        var j = close;
        while (j < slice.len and slice[j] != '>') : (j += 1) {}
        if (j >= slice.len) return i;
        base = i + j + 1;
    }
}

/// Derive up to two uppercase initials from a person's name:
/// "Dawid Urbanski" → "DU", "hi" → "H". Mirrors the publr-dom `initials`
/// helper exactly: first Unicode scalar of the first two whitespace-separated
/// words, ASCII-uppercased (non-ASCII initials pass through unchanged).
pub fn initials(arena: std.mem.Allocator, name: []const u8) []const u8 {
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    var words: usize = 0;
    var iterator = std.mem.tokenizeAny(u8, name, " \t\n\r");
    while (iterator.next()) |word| {
        if (words == 2) break;
        const scalar_len = std.unicode.utf8ByteSequenceLength(word[0]) catch 1;
        const end = @min(scalar_len, word.len);
        if (end == 1 and word[0] >= 'a' and word[0] <= 'z') {
            buf[len] = word[0] - ('a' - 'A');
            len += 1;
        } else {
            @memcpy(buf[len .. len + end], word[0..end]);
            len += end;
        }
        words += 1;
    }
    if (len == 0) return "";
    const result = arena.alloc(u8, len) catch return "";
    @memcpy(result, buf[0..len]);
    return result;
}

/// Gravatar image URL for an email: MD5 of the lowercased,
/// whitespace-stripped address, with `d=blank` so addresses without a
/// Gravatar resolve to a transparent image. Mirrors the publr-dom
/// `gravatarUrl` helper exactly; the email is optional because PJSX
/// conditionals do not narrow Zig optionals.
pub fn gravatar_url(arena: std.mem.Allocator, email_opt: ?[]const u8, size: f64) []const u8 {
    const email = email_opt orelse "";
    var hasher = std.crypto.hash.Md5.init(.{});
    for (email) |c| {
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
            hasher.update(&[_]u8{std.ascii.toLower(c)});
        }
    }
    var hash: [16]u8 = undefined;
    hasher.final(&hash);
    const hex = std.fmt.bytesToHex(hash, .lower);
    return std.fmt.allocPrint(arena, "https://gravatar.com/avatar/{s}?d=blank&s={d}", .{ hex, size }) catch "";
}

/// A string value inside a `data-p` seed attribute: JSON-escaped first, then
/// HTML-attribute-escaped — so the browser's attribute decoding yields valid
/// JSON whatever the value contains. Writes its own `&quot;` delimiters.
pub fn write_seed_string(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("&quot;");
    for (text) |char| {
        switch (char) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\&quot;"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '\'' => try w.writeAll("&#39;"),
            else => if (char < 0x20) {
                try w.print("\\u{x:0>4}", .{char});
            } else {
                try w.writeByte(char);
            },
        }
    }
    try w.writeAll("&quot;");
}

/// Structured hydration state uses the same JSON then attribute escaping as strings.
pub fn write_seed_value(w: *std.Io.Writer, arena: std.mem.Allocator, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(arena, value, .{});
    defer arena.free(json);
    try escape(w, json);
}

pub const Attr = struct {
    name: []const u8,
    /// null renders the bare attribute (`hidden`), a value renders
    /// `name="value"` with the value escaped.
    value: ?[]const u8,
};

/// Splices forwarded rest attributes (`data-part`, `role`, `aria-*`…) onto the
/// first opening tag of an already-rendered component; unchanged when the
/// html has no element root or no attribute is given.
pub fn splice_attrs(arena: std.mem.Allocator, html: []const u8, attrs: []const Attr) []const u8 {
    var merged = html;
    for (attrs) |attr| {
        // Behavioral layers compose with the component's own handlers/refs.
        if (std.mem.eql(u8, attr.name, "data-p-on")) {
            merged = merge_slot_attr(arena, merged, "data-p-on", attr.value);
            continue;
        }
        if (std.mem.eql(u8, attr.name, "data-p-ref")) {
            merged = merge_slot_attr(arena, merged, "data-p-ref", attr.value);
            continue;
        }
        if (std.mem.eql(u8, attr.name, "data-p-bind")) {
            merged = merge_slot_attr(arena, merged, "data-p-bind", attr.value);
            continue;
        }
        const at = root_attr_insert_pos(merged) orelse return merged;
        var run: std.Io.Writer.Allocating = .init(arena);
        run.writer.print(" {s}", .{attr.name}) catch return merged;
        if (attr.value) |value| {
            run.writer.writeAll("=\"") catch return merged;
            escape(&run.writer, value) catch return merged;
            run.writer.writeAll("\"") catch return merged;
        }
        if (root_attr_range(merged, attr.name) == null) merged = splice(arena, merged, at, run.written());
    }
    return merged;
}

/// The PJSX `<Slot>` lowering target: `child` with each of `attrs`' fields
/// merged onto its first real element. Panics when the child has no element
/// root — that is an authoring error (`asChild` needs exactly one element).
pub fn slot_props(arena: std.mem.Allocator, child: []const u8, attrs: anytype) []const u8 {
    const base = slot_merge_base(child);
    if (root_attr_insert_pos(child[base..]) == null) @panic("Slot requires exactly one Element child");
    var merged = child[base..];
    inline for (@typeInfo(@TypeOf(attrs)).@"struct".fields) |field| {
        const value = @field(attrs, field.name);
        switch (@typeInfo(field.type)) {
            .optional => if (value) |inner| {
                merged = merge_slot_attr(arena, merged, field.name, inner);
            },
            else => merged = merge_slot_attr(arena, merged, field.name, value),
        }
    }
    if (base == 0) return merged;
    return concat(arena, &.{ child[0..base], merged });
}

test "escape covers the five special characters" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try escape(&out.writer, "a & <b> \"c\" 'd'");
    try std.testing.expectEqualStrings("a &amp; &lt;b&gt; &quot;c&quot; &#39;d&#39;", out.written());
}

test "initials derives up to two uppercase initials" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("DU", initials(arena, "Dawid Urbanski"));
    try std.testing.expectEqualStrings("DU", initials(arena, "dawid urbanski"));
    try std.testing.expectEqualStrings("H", initials(arena, "hi"));
    try std.testing.expectEqualStrings("AL", initials(arena, "  ada   lovelace  "));
    try std.testing.expectEqualStrings("OM", initials(arena, "Olivia Martin Rhye"));
    try std.testing.expectEqualStrings("", initials(arena, ""));
    try std.testing.expectEqualStrings("", initials(arena, "   "));
    try std.testing.expectEqualStrings("ŁU", initials(arena, "Łukasz urbanski"));
}

test "gravatar_url matches the publr-dom gravatarUrl contract" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "https://gravatar.com/avatar/55502f40dc8b7c769880b10874abc9d0?d=blank&s=80",
        gravatar_url(arena, "test@example.com", 80),
    );
    try std.testing.expectEqualStrings(
        gravatar_url(arena, "test@example.com", 40),
        gravatar_url(arena, "  TEST@EXAMPLE.COM  ", 40),
    );
    try std.testing.expectEqualStrings(gravatar_url(arena, null, 40), gravatar_url(arena, "", 40));
}

test "join_optionals combines present values and returns null when none is" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "click:open;input:sync",
        join_optionals(arena, &.{ "click:open", null, "input:sync" }, ";").?,
    );
    try std.testing.expect(join_optionals(arena, &.{ null, null }, ";") == null);
}

test "invert_wire toggles a leading not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("not $open", invert_wire(arena, "$open").?);
    try std.testing.expectEqualStrings("$open", invert_wire(arena, "not $open").?);
    try std.testing.expect(invert_wire(arena, null) == null);
}

test "write_attr_cond: presence for booleans, value for optionals, escaped" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try write_attr_cond(&out.writer, "required", true);
    try write_attr_cond(&out.writer, "disabled", false);
    try write_attr_cond(&out.writer, "hidden", @as(?bool, false));
    try write_attr_cond(&out.writer, "maxlength", @as(?i64, 120));
    try write_attr_cond(&out.writer, "data-x", @as(?[]const u8, "a<b"));
    try write_attr_cond(&out.writer, "data-y", @as(?[]const u8, null));
    try std.testing.expectEqualStrings(" required maxlength=\"120\" data-x=\"a&lt;b\"", out.written());
}

test "slot_props merges classes and lets component-owned attrs win" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = slot_props(arena, "<button id=\"child\" class=\"button primary\">Hi</button>", .{
        .id = "trigger",
        .class = "menu-trigger",
        .@"aria-haspopup" = "menu",
    });
    try std.testing.expectEqualStrings(
        "<button id=\"trigger\" class=\"button primary menu-trigger\" aria-haspopup=\"menu\">Hi</button>",
        out,
    );
}

test "slot_props merges data-p-on layers and is not fooled by > in values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = slot_props(arena, "<button title=\"a > b\" data-p-on=\"input:sync\">Hi</button>", .{
        .@"data-p-on" = "click:openDialog",
        .@"data-p-anchor" = true,
    });
    try std.testing.expectEqualStrings(
        "<button title=\"a > b\" data-p-on=\"input:sync;click:openDialog\" data-p-anchor>Hi</button>",
        out,
    );
}

test "slot_props merges through transparent display:contents component wrappers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = slot_props(
        arena,
        "<div data-component=\"Outer:Outer\" style=\"display:contents\">" ++
            "<div data-component=\"Inner:Inner\" style=\"display:contents\">" ++
            "<a href=\"/x\">Go</a></div></div>",
        .{ .@"data-p-ref" = "trigger" },
    );
    try std.testing.expectEqualStrings(
        "<div data-component=\"Outer:Outer\" style=\"display:contents\">" ++
            "<div data-component=\"Inner:Inner\" style=\"display:contents\">" ++
            "<a href=\"/x\" data-p-ref=\"trigger\">Go</a></div></div>",
        out,
    );
}

test "slot_props skips absent optional attrs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = slot_props(arena, "<input value=\"a\"/>", .{
        .@"data-p-on" = @as(?[]const u8, null),
        .@"data-x" = @as(?[]const u8, "1"),
    });
    try std.testing.expectEqualStrings("<input value=\"a\" data-x=\"1\"/>", out);
}

test "write_wire_attr skips unset actions and omits an empty attribute" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try write_wire_attr(&out.writer, "data-p-on", &.{
        .{ .prefix = "click:", .value = null },
        .{ .prefix = "input:", .value = "sync" },
        .{ .prefix = "change:", .value = "commit" },
    });
    try std.testing.expectEqualStrings(" data-p-on=\"input:sync;change:commit\"", out.written());

    var empty: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer empty.deinit();

    try write_wire_attr(&empty.writer, "data-p-on", &.{.{ .prefix = "click:", .value = null }});
    try std.testing.expectEqualStrings("", empty.written());
}

test "merge_classes delegates to the consumer's class_merge module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const merged = try merge_classes(arena.allocator(), &.{ "a", "b" });
    try std.testing.expect(merged.len >= 1);
}

/// The default a component declared for a prop, read off its generated `Props`
/// type.
///
/// A caller that holds an optional and has no opinion of its own hands the
/// component's default straight back to it — the call site does not restate
/// what the component already says. A struct literal cannot omit a field
/// conditionally at run time, so `x orelse prop_default(Props, "x")` is how a
/// maybe-null value reaches a prop that has one.
///
/// The return type follows the field's, so it composes with `orelse` whether
/// the prop is a plain string with a default or an optional one.
pub fn PropDefault(comptime Props: type, comptime name: []const u8) type {
    inline for (@typeInfo(Props).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, name)) return field.type;
    }
    @compileError(@typeName(Props) ++ " has no prop named " ++ name);
}

pub fn prop_default(comptime Props: type, comptime name: []const u8) PropDefault(Props, name) {
    inline for (@typeInfo(Props).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, name)) {
            const ptr = field.default_value_ptr orelse
                @compileError(@typeName(Props) ++ "." ++ name ++ " has no default");
            return @as(*const field.type, @ptrCast(@alignCast(ptr))).*;
        }
    }
    @compileError(@typeName(Props) ++ " has no prop named " ++ name);
}

test "component forwarding composes refs and handlers through a slot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const child = slot_props(arena, "<button data-p-ref=\"child\" data-p-on=\"click:childClick\">Go</button>", .{ .@"data-p-ref" = "trigger", .@"data-p-on" = "click:toggle" });
    const out = splice_attrs(arena, child, &.{ .{ .name = "data-p-ref", .value = "parent" }, .{ .name = "data-p-on", .value = "click:navigate" } });
    try std.testing.expectEqualStrings("<button data-p-ref=\"child;trigger;parent\" data-p-on=\"click:childClick;click:toggle;click:navigate\">Go</button>", out);
}

test "structured hydration seeds escape JSON as an HTML attribute" {
    const arena = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const rows = [_]struct { id: []const u8, label: []const u8 }{
        .{ .id = "one", .label = "<script>\"&\n" },
    };
    try write_seed_value(&out.writer, arena, &rows);
    try std.testing.expectEqualStrings(
        "[{&quot;id&quot;:&quot;one&quot;,&quot;label&quot;:&quot;&lt;script&gt;\\&quot;&amp;\\n&quot;}]",
        out.written(),
    );
}

/// Adds a hydration marker to the first opening tag without buffering a row.
/// Nested rows stream through the same writer, keeping render memory linear.
pub const RootAttributeWriter = struct {
    writer: std.Io.Writer,
    target: *std.Io.Writer,
    name: []const u8,
    value: ?[]const u8,
    phase: enum { before, tag, done } = .before,

    pub fn init(target: *std.Io.Writer, name: []const u8, value: ?[]const u8) RootAttributeWriter {
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} }, .target = target, .name = name, .value = value };
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *RootAttributeWriter = @fieldParentPtr("writer", writer);
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.write(bytes);
            consumed += bytes.len;
        }
        for (0..splat) |_| {
            try self.write(data[data.len - 1]);
            consumed += data[data.len - 1].len;
        }
        return consumed;
    }

    fn write(self: *RootAttributeWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (self.phase == .done) return self.target.writeAll(bytes);
        for (bytes, 0..) |byte, index| {
            if (self.phase == .before) {
                if (byte == '<') self.phase = .tag;
            } else if (std.ascii.isWhitespace(byte) or byte == '>' or byte == '/') {
                try self.target.writeAll(bytes[0..index]);
                try self.target.print(" {s}", .{self.name});
                if (self.value) |value| {
                    try self.target.writeAll("=\"");
                    try escape(self.target, value);
                    try self.target.writeByte('"');
                }
                self.phase = .done;
                return self.target.writeAll(bytes[index..]);
            }
        }
        try self.target.writeAll(bytes);
    }
};

test "root hydration markers stream across write boundaries" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var marker = RootAttributeWriter.init(&out.writer, "data-p-for-key", "\"a&b\"");
    try marker.writer.writeAll("<t");
    try marker.writer.writeAll("r");
    try marker.writer.writeAll(" class=\"row\"><td>Text</td></tr>");
    try std.testing.expectEqualStrings("<tr data-p-for-key=\"&quot;a&amp;b&quot;\" class=\"row\"><td>Text</td></tr>", out.written());
}

/// Rest attributes need only the opening tag, not a copy of the component body.
pub const ForwardAttributesWriter = struct {
    writer: std.Io.Writer,
    target: *std.Io.Writer,
    head: std.Io.Writer.Allocating,
    attrs: []const Attr,
    quote: u8 = 0,
    done: bool = false,

    pub fn init(target: *std.Io.Writer, arena: std.mem.Allocator, attrs: []const Attr) ForwardAttributesWriter {
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} }, .target = target, .head = .init(arena), .attrs = attrs };
    }

    pub fn finish(self: *ForwardAttributesWriter) std.Io.Writer.Error!void {
        if (!self.done) try self.target.writeAll(self.head.written());
        self.head.deinit();
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ForwardAttributesWriter = @fieldParentPtr("writer", writer);
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.write(bytes);
            consumed += bytes.len;
        }
        for (0..splat) |_| {
            try self.write(data[data.len - 1]);
            consumed += data[data.len - 1].len;
        }
        return consumed;
    }

    fn write(self: *ForwardAttributesWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (self.done) return self.target.writeAll(bytes);
        for (bytes, 0..) |byte, index| {
            if (self.quote != 0) {
                if (byte == self.quote) self.quote = 0;
            } else if (byte == '"' or byte == '\'') {
                self.quote = byte;
            } else if (byte == '>') {
                try self.head.writer.writeAll(bytes[0 .. index + 1]);
                try self.target.writeAll(splice_attrs(self.head.allocator, self.head.written(), self.attrs));
                self.done = true;
                return self.target.writeAll(bytes[index + 1 ..]);
            }
        }
        try self.head.writer.writeAll(bytes);
    }
};

test "forwarded bindings merge on an opening tag while the body streams" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out: std.Io.Writer.Allocating = .init(arena_state.allocator());
    var forward = ForwardAttributesWriter.init(&out.writer, arena_state.allocator(), &.{.{ .name = "data-p-bind", .value = "data-id:$id" }});
    try forward.writer.writeAll("<div title=\"a>");
    try forward.writer.writeAll("b\" data-p-bind=\"aria-expanded:$open\">Body</div>");
    try forward.finish();
    try std.testing.expectEqualStrings("<div title=\"a>b\" data-p-bind=\"aria-expanded:$open;data-id:$id\">Body</div>", out.written());
}
