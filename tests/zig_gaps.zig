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
    var program = try pjsx.targets.zig.Program.init(a, irs.items);
    // As the admin builds them: the server's engine gives live expressions their
    // first values.
    program.request = pjsx.targets.zig.requestFields(struct {
        path: []const u8,
    });
    program.expressions_field = "publr_expressions";
    return program.listing(a, which);
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

fn expectContains(code: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, code, expected) == null) {
        std.debug.print("\nexpected to find:\n{s}\nin:\n{s}\n", .{ expected, code });
        return error.TestExpectedContains;
    }
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

test "closed gap: a JSX-valued component prop lowers as a block node" {
    // design-system-v2 BoxControl.next: actions={<span class="contents">…</span>}
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compile(arena.allocator(), &.{
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
    }, "BoxControl");
    try expectMatch(code, "\\.actions = rt\\.block\\(&markup_[0-9]+, Markup_[0-9]+\\),", "");
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

test "closed gap: optional chaining and `new` lower, natively or on the engine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const code = try lowers(a, "Chained",
        \\import { Publr } from "publr-jsx";
        \\export const state = Publr.reactive({ app: "" });
        \\export function Chained({ apps, at }: { apps: Array<{ value: string; selected: boolean }>; at: number }) {
        \\  state.app = apps.find((app) => app.selected)?.value ?? "";
        \\  return (
        \\    <ul data-at={new Date(at).toISOString()}>
        \\      {apps.map((app) => (
        \\        <li hidden={state.app === app?.value}>{app?.value}</li>
        \\      ))}
        \\    </ul>
        \\  );
        \\}
    );
    try expectContains(code, "pub fn render");
}

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

test "closed gap: a call the render cannot lower runs in the server's engine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowers(arena.allocator(), "Avatar",
        \\
        \\const abbreviate = (name: string) => name.slice(0, 2);
        \\export const avatarProps = { name: { type: "string" } };
        \\export function Avatar({ name }) {
        \\  return <span>{abbreviate(name)}</span>;
        \\}
    );
    try expectContains(code, "rt.write_value_text(w, (try rt.evaluate(");
    try expectContains(code, "// slot e_Avatar_1: ({ name }) => abbreviate(name)");
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

test "closed gap: an empty state array takes its item type from an `as` assertion" {
    // publr's admin switcher: `rows: [] as Row[]` with `type Row` declared
    // in the module; the rows' fields lower on the loop item.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowers(arena.allocator(), "Rows",
        \\
        \\import { Publr } from "publr-jsx";
        \\type Row = { name: string; current: boolean; tone: "success" | "accent" };
        \\export const state = Publr.reactive({ rows: [] as Row[], inline: [] as { label: string }[] });
        \\export function Rows() {
        \\  return <ul>
        \\    {state.rows.map((row) => <li key={row.name} data-current={row.current ? "yes" : "no"}>{row.name}</li>)}
        \\    {state.inline.map((entry) => <li key={entry.label}>{entry.label}</li>)}
        \\  </ul>;
        \\}
    );
    try expectMatch(code, "pub const Asserted_\\d+Tone = enum \\{ @\"success\", @\"accent\", \\};", "");
    try expectMatch(code, "pub const Asserted_\\d+Item = struct \\{\n    name: \\[\\]const u8,\n    current: bool,\n    tone: Asserted_\\d+Tone,\n\\};", "");
    try expectMatch(code, "for \\(@as\\(\\[\\]const Asserted_\\d+Item, &\\.\\{\\}\\), 0\\.\\.\\) \\|row, row_index_\\d+\\|", "");
    try expectMatch(code, "try rt.escape\\(\\(&row_writer_\\d+\\.writer\\), row\\.name\\);", "");
    try expectMatch(code, "for \\(@as\\(\\[\\]const Asserted_\\d+Item, &\\.\\{\\}\\), 0\\.\\.\\) \\|entry, row_index_\\d+\\|", "");
}

const switch_card_stub =
    \\export type SwitchCardProps = {
    \\  title: string;
    \\  tone?: "neutral" | "success" | "accent" | "warning";
    \\  current?: boolean;
    \\  size?: "default" | "small";
    \\  disabled?: boolean;
    \\  onClick?: (event: MouseEvent) => void;
    \\};
    \\export function SwitchCard({ title, tone = "neutral", current = false, size = "default", disabled = false, onClick }: SwitchCardProps) {
    \\  return <button data-tone={tone} data-size={size} aria-current={current} disabled={disabled} onClick={onClick}>{title}</button>;
    \\}
;

const button_stub =
    \\export type ButtonProps = {
    \\  intent?: "default" | "destructive";
    \\  title?: string;
    \\  onClick?: (event: MouseEvent) => void;
    \\  children: JSX.Element;
    \\};
    \\export function Button({ intent = "default", title, onClick, children }: ButtonProps) {
    \\  return <button data-intent={intent} title={title} onClick={onClick}>{children}</button>;
    \\}
;

test "closed gap: loop locals reach component props, children and guards inside a map" {
    // publr's admin switcher: each row is a SwitchCard and guarded Buttons
    // whose props, children and guards read the row.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = compile(arena.allocator(), &.{
        .{ "SwitchCard.ptsx", switch_card_stub },
        .{ "Button.ptsx", button_stub },
        .{
            "Switcher.ptsx",
            \\import { Publr } from "publr-jsx";
            \\import { Button } from "./Button.ptsx";
            \\import { SwitchCard } from "./SwitchCard.ptsx";
            \\type Row = { name: string; kind: string; title: string; tone: "success" | "accent" | "warning"; current: boolean; nested: boolean; running: boolean; confirm: boolean };
            \\export const state = Publr.reactive({ busy: false, rows: [] as Row[] });
            \\export const go = (event: Event) => {};
            \\export const stop = (event: Event) => {};
            \\export function Switcher() {
            \\  return <div>
            \\    {state.rows.map((row) => (
            \\      <div key={row.name} data-name={row.name}>
            \\        <SwitchCard title={row.title} tone={row.tone} current={row.current} size={row.nested ? "small" : "default"} disabled={state.busy} onClick={go} />
            \\        {!row.current && row.running && (<Button title="Stop" onClick={stop}>Stop</Button>)}
            \\        {!row.current && row.kind === "draft" && (
            \\          <Button intent={row.confirm ? "destructive" : "default"} onClick={stop}>{row.confirm ? "Delete" : "Delete…"}</Button>
            \\        )}
            \\      </div>
            \\    ))}
            \\  </div>;
            \\}
        },
    }, "Switcher") catch |e| {
        std.debug.print("\npjsx diagnostic: {s}\n", .{pjsx.lastError()});
        return e;
    };
    // The prototype: row fields are wires, a computed prop or a compound guard
    // is a compiled expression over the row.
    try expectContains(code, ".publr_bind_tone = \"$row.tone\"");
    try expectContains(code, ".publr_bind_size = \"$e_Switcher_1\"");
    try expectContains(code, "// slot e_Switcher_1: ({ row }) => (row.nested ? \"small\" : \"default\")");
    try expectContains(code, "data-p-if=\\\"$e_Switcher_2\\\">");
    try expectContains(code, "// slot e_Switcher_2: ({ row }) => (!row.current && row.running)");
    // The server-rendered rows: the loop local reaches props, guards and the
    // children blocks, and enum props take their values from the row.
    try expectMatch(code, "\\.title = row\\.title,", "");
    try expectMatch(code, "\\.tone = \\(switch \\(row\\.tone\\) \\{ \\.@\"success\" => \\.@\"success\", \\.@\"accent\" => \\.@\"accent\", \\.@\"warning\" => \\.@\"warning\", \\}\\)", "");
    // A row's computed props and guards are the engine's, with the row as their scope.
    try expectContains(code, "arena, \"Switcher\", \"e_Switcher_1\", (try publr_state.text(arena)), .{ .row = row, })");
    try expectContains(code, "if (rt.value_truthy((try rt.evaluate(");
    try expectContains(code, "arena, \"Switcher\", \"e_Switcher_2\", (try publr_state.text(arena)), .{ .row = row, })");
    try expectContains(code, "arena, \"Switcher\", \"e_Switcher_4\", (try publr_state.text(arena)), .{ .row = row, })");
    try expectMatch(code, "const children_\\d+ = \\.\\{ \\.props = &props, \\.publr_family = publr_family, \\.publr_state = publr_state, \\.row = &row, \\};", "");
    try expectMatch(code, "const row = cap\\.row\\.\\*;\n\\s*_ = &row;\n\\s*try w\\.writeAll\\(\"<template data-p-template=\\\\\"Switcher-3\\\\\" data-p-if></template>\"\\);\n\\s*if \\(row\\.confirm\\)", "");
}

test "closed gap: a string-keyed finite map lookup is an optional string" {
    // publr's admin switcher: `TONES[site_kind] ?? "accent"` with
    // a string key compares it with each entry.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowers(arena.allocator(), "Badge",
        \\
        \\export type BadgeProps = { kind: string };
        \\const TONES = { live: "success", draft: "warning" } as const;
        \\export function Badge({ kind }: BadgeProps) {
        \\  return <span data-tone={TONES[kind] ?? "accent"}>{kind}</span>;
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, code,
        \\((publr_lookup_1: { const publr_key_2 = props.kind; if (std.mem.eql(u8, publr_key_2, "live")) break :publr_lookup_1 @as(?[]const u8, "success"); if (std.mem.eql(u8, publr_key_2, "draft")) break :publr_lookup_1 @as(?[]const u8, "warning"); break :publr_lookup_1 @as(?[]const u8, null); }) orelse "accent")
    ) != null);
}

const status_button_stub =
    \\export type StatusButtonProps = { tone?: "neutral" | "success" | "accent" | "warning" };
    \\export function StatusButton({ tone = "neutral" }: StatusButtonProps) {
    \\  return <button data-tone={tone}>x</button>;
    \\}
;

const dot_stub =
    \\export type DotProps = { tone?: "success" | "accent" | "warning" };
    \\export function Dot({ tone }: DotProps) {
    \\  return <span data-tone={tone}>x</span>;
    \\}
;

const status_stub =
    \\export type StatusProps = { tone: "neutral" | "success" | "accent" };
    \\export function Status({ tone }: StatusProps) {
    \\  return <span data-tone={tone}>x</span>;
    \\}
;

test "closed gap: string values fill an enum prop through a component-body binding" {
    // publr's admin switcher: `const tone = TONES[kind] ?? "accent"` then
    // `<StatusButton tone={tone}>`: the binding's initializer is re-lowered
    // against the enum, each map value checked at compile time.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = compile(arena.allocator(), &.{
        .{ "StatusButton.ptsx", status_button_stub },
        .{ "Dot.ptsx", dot_stub },
        .{
            "Switch.ptsx",
            \\import { Dot } from "./Dot.ptsx";
            \\import { StatusButton } from "./StatusButton.ptsx";
            \\export type SwitchProps = { kind: string; on: boolean };
            \\const TONES = { live: "success", draft: "warning" } as const;
            \\export function Switch({ kind, on }: SwitchProps) {
            \\  const tone = TONES[kind as keyof typeof TONES] ?? "accent";
            \\  return <div>
            \\    <StatusButton tone={tone} />
            \\    <StatusButton tone="success" />
            \\    <Dot tone={on ? "success" : TONES[kind]} />
            \\  </div>;
            \\}
        },
    }, "Switch") catch |e| {
        std.debug.print("\npjsx diagnostic: {s}\n", .{pjsx.lastError()});
        return e;
    };
    try expectMatch(code, "\\.tone = \\(publr_lookup_\\d+: \\{ const publr_key_\\d+ = props\\.kind; if \\(std\\.mem\\.eql\\(u8, publr_key_\\d+, \"live\"\\)\\) break :publr_lookup_\\d+ \\.@\"success\"; if \\(std\\.mem\\.eql\\(u8, publr_key_\\d+, \"draft\"\\)\\) break :publr_lookup_\\d+ \\.@\"warning\"; break :publr_lookup_\\d+ \\.@\"accent\"; \\}\\)", "");
    try expectMatch(code, "\\.tone = \\.@\"success\"", "");
    // An optional enum prop takes a bare lookup: null when no entry matches.
    try expectMatch(code, "\\.tone = \\(if \\(props\\.on\\) \\.@\"success\" else \\(publr_lookup_\\d+: \\{ .* break :publr_lookup_\\d+ null; \\}\\)\\)", "");
}

test "authoring contract: an enum prop takes only its values, and a string-keyed lookup needs a fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A map value outside the enum, through a binding.
    try rejectsSet(arena.allocator(), "Switch", &.{
        .{ "StatusButton.ptsx", status_button_stub },
        .{
            "Switch.ptsx",
            \\import { StatusButton } from "./StatusButton.ptsx";
            \\export type SwitchProps = { kind: string };
            \\const TONES = { live: "success", draft: "danger" } as const;
            \\export function Switch({ kind }: SwitchProps) {
            \\  const tone = TONES[kind] ?? "accent";
            \\  return <StatusButton tone={tone} />;
            \\}
        },
    }, "\"danger\" is not a value of the Tone enum");
    // A fallback outside the enum.
    try rejectsSet(arena.allocator(), "Switch", &.{
        .{ "StatusButton.ptsx", status_button_stub },
        .{
            "Switch.ptsx",
            \\import { StatusButton } from "./StatusButton.ptsx";
            \\export type SwitchProps = { kind: string };
            \\const TONES = { live: "success" } as const;
            \\export function Switch({ kind }: SwitchProps) {
            \\  return <StatusButton tone={TONES[kind] ?? "loud"} />;
            \\}
        },
    }, "\"loud\" is not a value of the Tone enum");
    // A string-keyed lookup filling a required enum needs a fallback.
    try rejectsSet(arena.allocator(), "Switch", &.{
        .{ "Status.ptsx", status_stub },
        .{
            "Switch.ptsx",
            \\import { Status } from "./Status.ptsx";
            \\export type SwitchProps = { kind: string };
            \\const TONES = { live: "success" } as const;
            \\export function Switch({ kind }: SwitchProps) {
            \\  return <Status tone={TONES[kind]} />;
            \\}
        },
    }, "a string-keyed lookup cannot fill the required Tone enum without a `\\?\\?` fallback");
}

test "closed gap: a component re-emits the wires of its wired props" {
    // publr's admin switcher: SwitchCard inside the rows' template gets
    // `publr_bind_*` wires with placeholder values; its text, attributes,
    // class layers, guarded markup and nested components compose them.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_][2][]const u8{
        .{
            "Glyph.ptsx",
            \\export type GlyphProps = { name: "a" | "b"; label: string; size?: "xs" | "sm" };
            \\const SIZES = { xs: "size-3", sm: "size-4" } as const;
            \\export function Glyph({ name, label, size = "sm" }: GlyphProps) {
            \\  return <svg class={["shrink-0", SIZES[size]]} aria-label={`Icon ${label}`}><use href={`#icon-${name}`} /></svg>;
            \\}
        },
        .{
            "Card.ptsx",
            \\import { Glyph } from "./Glyph.ptsx";
            \\export type CardProps = { title: string; description?: string; icon: "a" | "b"; tone?: "success" | "accent"; current?: boolean; size?: "default" | "small" };
            \\const TONES = { success: "bg-success", accent: "bg-primary" } as const;
            \\export function Card({ title, description = "", icon, tone = "accent", current = false, size = "default" }: CardProps) {
            \\  const small = size === "small";
            \\  return <div class={["flex", small ? "gap-2" : "gap-3", current ? TONES[tone] : "bg-card"]} aria-current={current ? "true" : undefined}>
            \\    <Glyph name={icon} label={title} size={small ? "xs" : "sm"} />
            \\    <b>{title}</b>
            \\    {description !== "" && <i>{description}</i>}
            \\  </div>;
            \\}
        },
    };
    const card = compile(arena.allocator(), &sources, "Card") catch |e| {
        std.debug.print("\npjsx diagnostic: {s}\n", .{pjsx.lastError()});
        return e;
    };
    // Text: the element carries the wire of its sole child, as the caller handed it.
    try expectContains(card, "try rt.write_attr_cond(w, \"data-p-text\", props.publr_bind_title);");
    // Class layers: a compiled expression per layer, its props as arguments,
    // bound only when a caller wired one of them.
    try expectContains(card, "\"data-p-class\", rt.join_optionals(arena, &.{ (if (props.publr_bind_size != null) @as(?[]const u8, rt.concat(arena, &.{ \"$e_Card_2(\", \"size: \", rt.slot_argument(arena, props.publr_bind_size, props.size), \")\" }))");
    try expectContains(card, "// slot e_Card_2: ({ size }) => { const small = (size === \"small\"); return (small ? \"gap-2\" : \"gap-3\"); }");
    try expectContains(card, "// slot e_Card_3: ({ current, tone }) => (current ? TONES[tone] : \"bg-card\")");
    // Attributes: the same, joined into the element's bindings.
    try expectContains(card, "rt.concat(arena, &.{ \"aria-current:\", publr_wire })");
    try expectContains(card, "// slot e_Card_1: ({ current }) => (current ? \"true\" : undefined)");
    // Nested components: a prop passes on as it is, a derived value as a slot.
    try expectContains(card, ".publr_bind_name = props.publr_bind_icon,");
    try expectContains(card, ".publr_bind_size = (if (props.publr_bind_size != null) @as(?[]const u8, rt.concat(arena, &.{ \"$e_Card_7(\"");
    // Guarded markup: a `data-p-if` template over the slot, with its
    // server-rendered arm, and the plain branch when unwired.
    try expectContains(card, "rt.concat(arena, &.{ \"$e_Card_9(\", \"description: \", rt.slot_argument(arena, props.publr_bind_description, props.description), \")\" })");
    try expectContains(card, "// slot e_Card_9: ({ description }) => (description !== \"\")");
    try expectMatch(card, "<template data-p-template=\\\\\"Card-0\\\\\" data-p-if=\\\\\"", "");
    try expectContains(card, "rt.RootAttributeWriter.init(w, \"data-p-if-row\", null)");

    const glyph = try compile(arena.allocator(), &sources, "Glyph");
    // A template literal over props is a compiled expression like any other.
    try expectContains(glyph, "// slot e_Glyph_");
    try expectContains(glyph, "=> `#icon-${name}`");
    try expectContains(glyph, "=> `Icon ${label}`");
}

test "closed gap: a template's prototype leaves out classes drawn from props the row fills" {
    // publr's AI workspace: each paragraph's Text variant is chosen per row. The
    // prototype rendered it from a placeholder (the first variant, a large bold
    // heading), and the browser added the row's classes beside it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_][2][]const u8{
        .{
            "Badge.ptsx",
            \\export type BadgeProps = { tone: "loud" | "quiet"; children: JSX.Element };
            \\const TONES = { loud: "font-bold", quiet: "font-normal" } as const;
            \\export function Badge({ tone, children }: BadgeProps) {
            \\  return <span class={["inline", TONES[tone]]}>{children}</span>;
            \\}
        },
        .{
            "List.ptsx",
            \\import { Publr } from "publr-jsx";
            \\import { Badge } from "./Badge.ptsx";
            \\type Row = { name: string; loud: boolean };
            \\export const state = Publr.reactive({ rows: [] as Row[] });
            \\export function List() {
            \\  return <ul>{state.rows.map((row) => (
            \\    <li key={row.name}><Badge tone={row.loud ? "loud" : "quiet"}>{row.name}</Badge></li>
            \\  ))}</ul>;
            \\}
        },
    };
    const list = compile(arena.allocator(), &sources, "List") catch |e| {
        std.debug.print("\npjsx diagnostic: {s}\n", .{pjsx.lastError()});
        return e;
    };
    // The prototype says so; the rows the server renders pass on what they were told.
    try expectContains(list, ".publr_prototype = true,");
    try expectContains(list, ".publr_prototype = props.publr_prototype,");

    const badge = try compile(arena.allocator(), &sources, "Badge");
    // The row-filled layer is empty in a prototype; the browser draws it.
    try expectContains(badge, "(if (props.publr_prototype and ((if (props.publr_bind_tone != null)");
    try expectContains(badge, "@as([]const u8, \"\") else (switch (props.tone)");
}

const menu_stub =
    \\import { Publr } from "publr-jsx";
    \\export const state = Publr.reactive({ open: false });
    \\export const toggle = () => { state.open = !state.open; };
    \\export type MenuProps = { children: JSX.Element };
    \\export function Menu({ children }: MenuProps) {
    \\  return <div class="relative">{children}</div>;
    \\}
;

const menu_content_stub =
    \\import { state } from "./Menu.ptsx";
    \\export type MenuContentProps = { children: JSX.Element };
    \\export function MenuContent({ children }: MenuContentProps) {
    \\  return <div role="menu" hidden={!state.open}>{children}</div>;
    \\}
;

const labelled_button_stub =
    \\export type LabelledButtonProps = { label?: string; disabled?: boolean; children: JSX.Element };
    \\export function LabelledButton({ label, disabled = false, children }: LabelledButtonProps) {
    \\  return <button aria-label={label} disabled={disabled}>{children}</button>;
    \\}
;

test "closed gap: loop items and own state reach family components nested in family components" {
    // publr's admin switcher (drawer design): a DropdownMenu per row with a
    // templated label and row guards, and a Dialog whose form reads the
    // module's own state, both inside the Drawer's content.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = compile(arena.allocator(), &.{
        .{ "Menu.ptsx", menu_stub },
        .{ "MenuContent.ptsx", menu_content_stub },
        .{ "LabelledButton.ptsx", labelled_button_stub },
        .{
            "Switcher.ptsx",
            \\import { Publr } from "publr-jsx";
            \\import { LabelledButton } from "./LabelledButton.ptsx";
            \\import { Menu } from "./Menu.ptsx";
            \\import { MenuContent } from "./MenuContent.ptsx";
            \\type Row = { name: string; title: string; can_start: boolean };
            \\type Base = { name: string; label: string };
            \\export const state = Publr.reactive({ busy: false, kind: "draft", rows: [] as Row[], bases: [] as Base[] });
            \\export const start = (event: Event) => {};
            \\export function Switcher() {
            \\  return <div>
            \\    <Menu>
            \\      <MenuContent>
            \\        <select>{state.bases.map((base) => <option key={base.name} value={base.name}>{base.label}</option>)}</select>
            \\        {state.kind === "page" && <p>Role</p>}
            \\        <LabelledButton disabled={state.busy}>Create</LabelledButton>
            \\      </MenuContent>
            \\    </Menu>
            \\    {state.rows.map((row) => (
            \\      <div key={row.name}>
            \\        <Menu>
            \\          <LabelledButton label={`More for ${row.title}`}>More</LabelledButton>
            \\          <MenuContent>
            \\            {row.can_start && <button onClick={start}>Start</button>}
            \\          </MenuContent>
            \\        </Menu>
            \\      </div>
            \\    ))}
            \\  </div>;
            \\}
        },
    }, "Switcher") catch |e| {
        std.debug.print("\npjsx diagnostic: {s}\n", .{pjsx.lastError()});
        return e;
    };
    // The prototype: a template literal over the row is a compiled expression.
    try expectContains(code, ".publr_bind_label = \"$e_Switcher_2\"");
    try expectContains(code, "// slot e_Switcher_2: ({ row }) => `More for ${row.title}`");
    // The server-rendered rows: the label is the engine's, over the row.
    try expectContains(code, ".label = (try rt.value_into(?[]const u8, arena, (try rt.evaluate(");
    try expectContains(code, "\"e_Switcher_2\", (try publr_state.text(arena)), .{ .row = row, })");
    try expectMatch(code, "data-p-if=\\\\\"\\$row\\.can_start\\\\\"", "");
    // Own state inside the family's children: a list, a guard and a prop wire.
    try expectMatch(code, "data-p-for=\\\\\"base of \\$bases\\\\\"", "");
    try expectContains(code, "data-p-if=\\\"$e_Switcher_1\\\"");
    try expectContains(code, "// slot e_Switcher_1: () => (state.kind === \"page\")");
    try expectMatch(code, "\\.publr_bind_disabled = \"\\$busy\"", "");
}

test "closed gap: a module-level string constant is inlined where it is read" {
    // design-system StatusButton: const HATCH = "…"; <span style={HATCH} />
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try lowers(arena.allocator(), "Striped",
        \\const HATCH = "background-image: none";
        \\const LABEL = `Striped`;
        \\export const stripedProps = { live: { type: "boolean", optional: true } };
        \\export function Striped({ live = false }) {
        \\  return <b>{live ? <span class="solid">{LABEL}</span> : <span style={HATCH}>{LABEL}</span>}</b>;
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, out, "background-image: none") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Striped") != null);
}

test "closed gap: a wired optional prop is present, and a wired class list crosses into a nested component" {
    // publr's admin switcher (folder-nav design): FolderNavItemLink picks
    // its tag from `href === undefined` and hands `busy ? … : "hidden"` to
    // its spinner Icon's `classes`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_][2][]const u8{
        .{
            "Spinner.ptsx",
            \\export type SpinnerProps = { classes?: string };
            \\export function Spinner({ classes = "" }: SpinnerProps) {
            \\  return <svg class={["shrink-0", classes]} />;
            \\}
        },
        .{
            "NavLink.ptsx",
            \\import { Dynamic } from "publr-jsx";
            \\import { Spinner } from "./Spinner.ptsx";
            \\export type NavLinkProps = { href?: string; busy?: boolean; children?: JSX.Element };
            \\export function NavLink({ href, busy = false, children }: NavLinkProps) {
            \\  return <Dynamic as={href === undefined ? "span" : "a"} href={href}>
            \\    {children}
            \\    <Spinner classes={busy ? "ml-auto animate-spin" : "hidden"} />
            \\  </Dynamic>;
            \\}
        },
        .{
            "Nav.ptsx",
            \\import { Publr } from "publr-jsx";
            \\import { NavLink } from "./NavLink.ptsx";
            \\type Row = { name: string; busy: boolean };
            \\export const state = Publr.reactive({ rows: [] as Row[] });
            \\export function Nav() {
            \\  return <nav>{state.rows.map((row) => <NavLink key={row.name} href={`#${row.name}`} busy={row.busy}>x</NavLink>)}</nav>;
            \\}
        },
    };
    const nav = compile(arena.allocator(), &sources, "Nav") catch |e| {
        std.debug.print("\npjsx diagnostic: {s}\n", .{pjsx.lastError()});
        return e;
    };
    // The prototype's wired optional takes a present placeholder.
    try expectContains(nav, "NavLink.render(w, arena, .{ .href = \"\", .publr_bind_href = \"$e_Nav_1\", .publr_bind_busy = \"$row.busy\"");
    try expectContains(nav, "// slot e_Nav_1: ({ row }) => `#${row.name}`");

    const link = try compile(arena.allocator(), &sources, "NavLink");
    try expectContains(link, ".publr_bind_classes = (if (props.publr_bind_busy != null)");
    try expectContains(link, "=> (busy ? \"ml-auto animate-spin\" : \"hidden\")");

    // The nested component's class list: the caller's wire as a group.
    const spinner = try compile(arena.allocator(), &sources, "Spinner");
    try expectContains(spinner, "\"data-p-class\", rt.join_optionals(arena, &.{ (if (props.publr_bind_classes) |publr_classes| @as(?[]const u8, rt.concat(arena, &.{ \"(\", publr_classes, \")\" }))");
}

test "closed gap: a row of a reactive list reads the module's other state" {
    // publr's currency table: the default radio of each row compares the row's
    // position with `state.chosen`, a sibling field of the list it renders.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowers(arena.allocator(), "Picks",
        \\
        \\import { Publr } from "publr-jsx";
        \\export const state = Publr.reactive({ rows: [] as { index: number; code: string }[], chosen: 0 });
        \\export function Picks() {
        \\  return <ul>
        \\    {state.rows.map((row) => <li data-chosen={state.chosen === 1 ? "yes" : "no"}>{row.code}</li>)}
        \\  </ul>;
        \\}
    );
    try expectContains(code, "data-p-bind=\\\"data-chosen:$e_Picks_1\\\"");
    try expectContains(code, "// slot e_Picks_1: () => ((state.chosen === 1) ? \"yes\" : \"no\")");
}

test "closed gap: a row whose body is a guard lands in a wrapper that holds the row" {
    // publr's record actions: `state.actions.map((item) => item.primary && <form>…</form>)`.
    // The row's store belongs on one element; on the guard's bare anchor the form it
    // mounts is a sibling and reads no `$item`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowers(arena.allocator(), "Actions",
        \\import { Publr } from "publr-jsx";
        \\export const state = Publr.reactive({ actions: [] as { label: string; primary: boolean }[] });
        \\export function Actions() {
        \\  return <div>
        \\    {state.actions.map((item) => item.primary && <button>{item.label}</button>)}
        \\  </div>;
        \\}
    );
    // The wrapper's class goes through the merge like every other.
    try expectMatch(code, "data-p-for=\\\\\"item of \\$actions\\\\\"><span class=\\\\\"", "");
    try expectMatch(code, "&.\\{ \"contents\", \\}", "");
    try expectMatch(code, "\\\\\"><template data-p-template=\\\\\"[A-Za-z]+-1\\\\\" data-p-if=\\\\\"\\$item\\.primary\\\\\">", "");
}

test "closed gap: a wire compares one state value with another" {
    // publr's currency table: the default radio of each row is
    // `state.chosen === row.index`, which the runtime follows on both sides.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowers(arena.allocator(), "PicksBoth",
        \\
        \\import { Publr } from "publr-jsx";
        \\export const state = Publr.reactive({ rows: [] as { index: number; code: string }[], chosen: 0 });
        \\export function PicksBoth() {
        \\  return <ul>
        \\    {state.rows.map((row) => <li data-chosen={state.chosen === row.index ? "yes" : "no"}>{row.code}</li>)}
        \\  </ul>;
        \\}
    );
    try expectContains(code, "data-p-bind=\\\"data-chosen:$e_PicksBoth_1\\\"");
    try expectContains(code, "// slot e_PicksBoth_1: ({ row }) => ((state.chosen === row.index) ? \"yes\" : \"no\")");
}

test "closed gap: null against an optional prop" {
    // FolderNavItemLink drops a disabled entry's link: `disabled ? undefined : href`, where
    // `href` may already be absent.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowers(arena.allocator(), "Link",
        \\export type LinkProps = { href?: string; disabled?: boolean };
        \\export function Link({ href, disabled = false }: LinkProps) {
        \\  return <a href={disabled ? undefined : href}>x</a>;
        \\}
    );
    try expectMatch(code, "@as\\(\\?\\[\\]const u8, null\\) else @as\\(\\?\\[\\]const u8, props\\.href\\)", "");
}

const TestRequest = struct {
    session: struct {
        name: []const u8,
        email: []const u8,
    },
    signed_in: bool,
};

fn lowersWithRequest(a: std.mem.Allocator, sources: []const [2][]const u8, which: []const u8) ![]const u8 {
    var irs: std.ArrayList(*const pjsx.compiler.ModuleIR) = .empty;
    for (sources) |pair| {
        try irs.append(a, try pjsx.compiler.createPjsxModule(a, pair[1], pair[0]));
    }
    var program = try pjsx.targets.zig.Program.init(a, irs.items);
    program.request = pjsx.targets.zig.requestFields(TestRequest);
    return program.lower(a, which) catch |e| {
        std.debug.print("\npjsx diagnostic: {s}\n", .{pjsx.lastError()});
        return e;
    };
}

test "closed gap: a server render reads the request it was handed" {
    // publr's admin chrome reads who is signed in from the request, not from props
    // every page forwards.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowersWithRequest(arena.allocator(), &.{.{
        "Rail.ptsx",
        \\import { Publr } from "publr-jsx";
        \\export function Rail() {
        \\  return <nav>{Publr.request.signed_in && <span>{Publr.request.session.email}</span>}</nav>;
        \\}
    }}, "Rail");
    try expectMatch(code, "const Request = @import\\(\"request\"\\)\\.Request;", "");
    try expectMatch(code, "publr_request: \\?\\*const anyopaque = null,", "");
    try expectMatch(code, "props\\.publr_request orelse", "");
    try expectMatch(code, "\\)\\.\\*\\.session\\.email", "");
}

test "closed gap: every component call hands the request down" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowersWithRequest(arena.allocator(), &.{
        .{
            "Inner.ptsx",
            \\export function Inner() { return <span>hi</span>; }
        },
        .{
            "Outer.ptsx",
            \\import { Inner } from "./Inner.ptsx";
            \\export function Outer() { return <div><Inner /></div>; }
        },
    }, "Outer");
    try expectMatch(code, "Inner\\.render\\(w, arena, \\.\\{ \\.publr_request = props\\.publr_request,", "");
}

test "compiler gap: Publr.request without a declared request is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try pjsx.compiler.createPjsxModule(a,
        \\import { Publr } from "publr-jsx";
        \\export function Rail() { return <nav>{Publr.request.session.email}</nav>; }
    , "Rail.ptsx");
    const program = try pjsx.targets.zig.Program.init(a, &.{module});
    try std.testing.expectError(error.Pjsx, program.lower(a, "Rail"));
    try expectMatch(pjsx.lastError(), "declares no request", "");
}

test "closed gap: a flag guards a node prop" {
    // publr's FormBody: `{!bare && header}`, where `header` is an optional node.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowers(arena.allocator(), "Body",
        \\export type BodyProps = { bare?: boolean; header?: JSX.Element };
        \\export function Body({ bare = false, header }: BodyProps) {
        \\  return <div>{!bare && header}</div>;
        \\}
    );
    try expectMatch(code, "@as\\(\\?rt\\.Node, ", "");
}

test "closed gap: a literal list of objects fills an array prop" {
    // publr's pages name their parents in the crumbs: `parents={[{ label, href }]}`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowersWithRequest(arena.allocator(), &.{
        .{
            "Trail.ptsx",
            \\export type TrailProps = { parents: Array<{ label: string; href: string }> };
            \\export function Trail({ parents }: TrailProps) {
            \\  return <ol>{parents.map((parent) => <li><a href={parent.href}>{parent.label}</a></li>)}</ol>;
            \\}
        },
        .{
            "Page.ptsx",
            \\import { Trail } from "./Trail.ptsx";
            \\export function Page() { return <Trail parents={[{ label: "Structure", href: "/admin/structure" }]} />; }
        },
    }, "Page");
    try expectMatch(code, "\\.parents = &\\[_\\]Trail\\.ParentsItem\\{ \\.\\{ \\.label = \"Structure\", \\.href = \"/admin/structure\", \\},", "");
}

test "closed gap: markup fills a node prop, absent when guarded off" {
    // publr's layouts take slots: `actions={<Button/>}`, `empty={none && <Empty/>}`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowersWithRequest(arena.allocator(), &.{
        .{
            "Frame.ptsx",
            \\export type FrameProps = { actions?: JSX.Element; empty?: JSX.Element };
            \\export function Frame({ actions, empty }: FrameProps) {
            \\  return <div>{actions}{empty && <p>{empty}</p>}</div>;
            \\}
        },
        .{
            "Page.ptsx",
            \\import { Frame } from "./Frame.ptsx";
            \\export type PageProps = { none: boolean; label: string };
            \\export function Page({ none, label }: PageProps) {
            \\  return <Frame actions={<b>{label}</b>} empty={none && <i>nothing</i>} />;
            \\}
        },
    }, "Page");
    try expectMatch(code, "\\.actions = rt\\.block\\(&markup_[0-9]+, Markup_[0-9]+\\),", "");
    try expectMatch(code, "\\.empty = \\(if \\(props\\.none\\) @as\\(\\?rt\\.Node, rt\\.block\\(&markup_[0-9]+, Markup_[0-9]+\\)\\) else null\\),", "");
}

test "closed gap: a module names the component its root is drawn by" {
    // publr holds its admin pages to its layouts: `render.page` checks `root_component`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compile(arena.allocator(), &.{
        .{
            "Frame.ptsx",
            \\export function Frame() { return <main />; }
        },
        .{
            "Page.ptsx",
            \\import { Frame } from "./Frame.ptsx";
            \\export function Page() { return <Frame />; }
        },
    }, "Page");
    try expectMatch(code, "pub const root_component: \\[\\]const u8 = \"Frame\";", "");
}

test "closed gap: two lists with a list of the same name each get their own item type" {
    // The merge resolver: `theirs` and `ours`, each value with its `segments`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lowers(arena.allocator(), "Sides",
        \\type Value = { text: string; segments: Array<{ text: string; mark: string }> };
        \\export function Sides({ theirs, ours }: { theirs: Array<Value>; ours: Array<Value> }) {
        \\  return <div>{theirs.length}{ours.length}</div>;
        \\}
    );
    try expectMatch(code, "pub const SegmentsItem = struct", "");
    try expectMatch(code, "pub const OursSegmentsItem = struct", "");
}

test "closed gap: a prop's enum type never takes an imported component's name" {
    // The merge's field card: an `icon` prop beside the imported `Icon`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compile(arena.allocator(), &.{
        .{
            "Icon.ptsx",
            \\export function Icon({ name }: { name: "plus" | "link" }) { return <svg data-name={name} />; }
        },
        .{
            "Card.ptsx",
            \\import { Icon } from "./Icon.ptsx";
            \\export function Card({ icon }: { icon: "plus" | "link" }) { return <Icon name={icon} />; }
        },
    }, "Card");
    try expectMatch(code, "pub const IconValue = enum", "");
    try expectMatch(code, "const Icon = @import\\(\"Icon.zig\"\\);", "");
}

test "closed gap: a family seeds its state from a closed string set prop" {
    // publr's media library: the tile size arrives as `"sm" | "md" | "lg"` and seeds the
    // state the grid's `size` reads.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try lowers(arena.allocator(), "Tiles",
        \\import { Publr } from "publr-jsx";
        \\export const state = Publr.reactive({ size: "md" as "sm" | "md" | "lg" });
        \\export type TilesProps = { size?: "sm" | "md" | "lg" };
        \\export function Tiles({ size = "md" }: TilesProps) {
        \\  state.size = size;
        \\  return <div data-size={state.size} />;
        \\}
    );
    try expectMatch(out, "write_seed_string\\(w, @tagName\\(", "");
}
