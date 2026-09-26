//! Every construct the `zig` SSR target cannot currently lower, pinned with a
//! minimal reproduction. Each case was found by lowering a real
//! design-system-v2 component; the comment names the component that hit it.
//!
//! These tests assert the CURRENT behavior so a fix is a deliberate, visible
//! change: when a gap is closed, its test moves from `rejects` to `lowers` and
//! the design system's committed target matrix must be updated in the same
//! change. A gap that starts lowering silently is a test failure here first.
//!
//! Port of the retired ZSX chain's `zsx-gaps` suite onto the `zig` target;
//! gaps whose construct left the authoring contract with that chain (the
//! `render={<el />}` escape) died with it.

const std = @import("std");
const pjsx = @import("pjsx");
const regex = @import("regex.zig");
const expectMatch = regex.expectMatch;

fn compile(a: std.mem.Allocator, sources: []const [2][]const u8, which: []const u8) ![]const u8 {
    var irs: std.ArrayList(*const pjsx.compiler.ModuleIR) = .empty;
    for (sources) |pair| {
        try irs.append(a, try pjsx.compiler.createPjsxModule(a, pair[1], pair[0]));
    }
    const program = try pjsx.targets.zig.Program.init(a, irs.items);
    return program.lower(a, which);
}

fn rejectsSet(a: std.mem.Allocator, comptime name: []const u8, sources: []const [2][]const u8, comptime message: []const u8) !void {
    const result = compile(a, sources, name);
    if (result) |_| {
        std.debug.print("\n{s} was expected to remain unsupported by the zig target\n", .{name});
        return error.TestExpectedRejection;
    } else |e| {
        try std.testing.expectEqual(error.Pjsx, e);
        try expectMatch(pjsx.lastError(), message, "");
    }
}

fn rejects(a: std.mem.Allocator, comptime name: []const u8, source: []const u8, comptime message: []const u8) !void {
    try rejectsSet(a, name, &.{.{ name ++ ".ptsx", source }}, message);
}

fn lowers(a: std.mem.Allocator, comptime name: []const u8, source: []const u8) ![]const u8 {
    return compile(a, &.{.{ name ++ ".ptsx", source }}, name) catch |e| {
        std.debug.print("\npjsx diagnostic: {s}\n", .{pjsx.lastError()});
        return e;
    };
}

test "compiler gap: a defaulted props parameter is rejected" {
    // design-system-v2 Separator: export function Separator(props = {})
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try rejects(arena.allocator(), "Separator",
        \\
        \\export const separatorProps = { id: { type: "optional-string", optional: true } };
        \\export function Separator(props = {}) {
        \\  return <div id={props.id} />;
        \\}
    , "component must take zero or one props object");
}

test "compiler gap: an inline arrow event handler cannot lower" {
    // design-system-v2 Select: onFocusout={(event) => { ... }}
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try rejects(arena.allocator(), "Select",
        \\
        \\export const selectProps = {};
        \\export function Select() {
        \\  return <div onFocusout={(event) => { event.stopPropagation(); }} />;
        \\}
    , "expression kind \"function\" is not lowered here");
}

test "compiler gap: a JSX-valued component prop cannot lower" {
    // design-system-v2 BoxControl.next: actions={<span class="contents">…</span>}
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try rejectsSet(arena.allocator(), "BoxControl", &.{
        .{
            "StyleControl.ptsx",
            \\export const styleControlProps = {
            \\  title: { type: "string" },
            \\  actions: { type: "node", optional: true },
            \\};
            \\export function StyleControl({ title, actions }) {
            \\  return <div title={title}>{actions}</div>;
            \\}
        },
        .{
            "BoxControl.ptsx",
            \\import { StyleControl } from "./StyleControl.ptsx";
            \\export const boxControlProps = {};
            \\export function BoxControl() {
            \\  return <StyleControl title="Padding" actions={<span class="contents">x</span>} />;
            \\}
        },
    }, "expression kind \"node\" is not lowered here");
}

test "closed gap: an array map may take a primitive-member body" {
    // The ZSX chain required a JSX body; the zig target lowers a member body
    // as escaped text inside the loop.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowers(arena.allocator(), "List",
        \\
        \\export const listProps = { items: { type: "array", fields: { v: { type: "string" } } } };
        \\export function List({ items }) {
        \\  return <div>{items.map((item) => item.v)}</div>;
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, code, "for (props.items) |item| {") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "try rt.escape(w, item.v);") != null);
}

// The next two are authoring requirements rather than compiler limitations:
// they are constraints components must satisfy, and are pinned so the contract
// stays explicit rather than folklore.

test "authoring contract: one JSX component per module" {
    // Field originally exported Field, FieldLabel, FieldDescription, FieldError
    // from one module; the parts had to move to sibling files.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try rejects(arena.allocator(), "Field",
        \\
        \\export const fieldProps = {};
        \\export function Field() { return <div />; }
        \\export function FieldLabel() { return <label />; }
    , "must export exactly one JSX component \\(found 2\\)");
}

test "authoring contract: schema-free components lower" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowers(arena.allocator(), "Widget",
        \\
        \\export function Widget() { return <div />; }
    );
    try expectMatch(code, "pub const Props = struct", "");
}

test "closed gap: the publr-dom initials helper lowers to rt.initials" {
    // design-system-v2 Avatar: the initials fallback derives from the `name`
    // prop through the shared publr-dom `initials` helper, whose server
    // runtime counterpart is `rt.initials`. Both implementations must stay
    // identical.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowers(arena.allocator(), "Avatar",
        \\
        \\import { initials } from "publr/dom";
        \\export const avatarProps = { name: { type: "string" } };
        \\export function Avatar({ name }) {
        \\  return <span>{initials(name)}</span>;
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, code, "rt.initials(arena, props.name)") != null);
}

test "open gap: arbitrary call expressions still fail lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try rejects(arena.allocator(), "Avatar",
        \\
        \\export const avatarProps = { name: { type: "string" } };
        \\export function Avatar({ name }) {
        \\  return <span>{abbreviate(name)}</span>;
        \\}
    , "expression kind \"call\" is not lowered here");
}

test "closed gap: the publr-dom gravatarUrl helper lowers to rt.gravatar_url" {
    // design-system-v2 Avatar: the gravatar layer derives its src from the
    // optional `email` prop; the runtime counterpart handles the optional.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowers(arena.allocator(), "Avatar",
        \\
        \\import { gravatarUrl } from "publr/dom";
        \\export const avatarProps = { email: { type: "optional-string", optional: true } };
        \\export function Avatar({ email }) {
        \\  return <span>{email != null && <img src={gravatarUrl(email, 80)} />}</span>;
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, code, "rt.gravatar_url(arena, props.email, @as(f64, 80))") != null);
}
