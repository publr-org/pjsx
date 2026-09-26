//! Port of `tests/compiler.test.js` — one Zig test per original `test(...)`,
//! same names, same fixtures, same regex assertions for the DOM target. The
//! server-side halves originally asserted against the retired ZSX chain; they
//! now assert against the `zig` SSR target's generated source, matching exact
//! substrings of the emitted Zig instead of regexes (HTML attribute text
//! appears inside Zig string literals, so a quote is `\"` in the needles and
//! wire arrows are attribute-escaped as `-&gt;`).

const std = @import("std");
const pjsx = @import("pjsx");
const build_options = @import("build_options");
const regex = @import("regex.zig");
const expectMatch = regex.expectMatch;
const expectNoMatch = regex.expectNoMatch;

const analyze = pjsx.analyze;
const compiler = pjsx.compiler;
const dom = pjsx.dom;
const dom_target = pjsx.targets.dom;
const plugins = pjsx.targets.plugins;
const parsePjsx = analyze.parsePjsx;
const createPjsxModule = compiler.createPjsxModule;
const collectPjsxClasses = compiler.collectPjsxClasses;
const lowerPjsxToDom = dom_target.lowerPjsxToDom;
const lowerPjsxToZig = pjsx.targets.zig.lowerPjsxToZig;
const lowerPjsxStoreRegistration = pjsx.store.lowerPjsxStoreRegistration;
const transformPjsxToDom = dom.transformPjsxToDom;

const Arena = struct {
    inner: std.heap.ArenaAllocator,
    fn init() Arena {
        return .{ .inner = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }
    fn a(self: *Arena) std.mem.Allocator {
        return self.inner.allocator();
    }
    fn deinit(self: *Arena) void {
        self.inner.deinit();
    }
};

fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectStringList(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, x| try std.testing.expectEqualStrings(e, x);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\nexpected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("\nexpected NOT to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedNotContains;
    }
}

/// Surface the compiler diagnostic when an unexpected error escapes a test.
fn report(e: anyerror) anyerror {
    if (e == error.Pjsx) std.debug.print("\npjsx diagnostic: {s}\n", .{pjsx.lastError()});
    return e;
}

fn domCode(a: std.mem.Allocator, src: []const u8, filename: []const u8) ![]const u8 {
    return (lowerPjsxToDom(a, src, filename, null) catch |e| return report(e)).code;
}

/// One module through the `zig` SSR target, the compile set being just itself.
fn zigCode(a: std.mem.Allocator, src: []const u8, filename: []const u8) ![]const u8 {
    const module = createPjsxModule(a, src, filename) catch |e| return report(e);
    return (lowerPjsxToZig(a, module, &.{}) catch |e| return report(e)).code;
}

/// Lower `which` against a whole compile set, the way a build does — imports
/// resolve against the other modules.
fn zigCodeSet(a: std.mem.Allocator, sources: []const [2][]const u8, which: []const u8) ![]const u8 {
    var irs: std.ArrayList(*const compiler.ModuleIR) = .empty;
    for (sources) |pair| {
        try irs.append(a, createPjsxModule(a, pair[1], pair[0]) catch |e| return report(e));
    }
    const program = pjsx.targets.zig.Program.init(a, irs.items) catch |e| return report(e);
    return program.lower(a, which) catch |e| return report(e);
}

/// Like `zigCode`, but without the diagnostic dump — for expected failures.
fn zigError(a: std.mem.Allocator, src: []const u8, filename: []const u8) !void {
    _ = try lowerPjsxToZig(a, try createPjsxModule(a, src, filename), &.{});
}

fn zigErrorSet(a: std.mem.Allocator, sources: []const [2][]const u8, which: []const u8) !void {
    var irs: std.ArrayList(*const compiler.ModuleIR) = .empty;
    for (sources) |pair| try irs.append(a, try createPjsxModule(a, pair[1], pair[0]));
    const program = try pjsx.targets.zig.Program.init(a, irs.items);
    _ = try program.lower(a, which);
}

const source =
    \\
    \\export const badgeProps = {
    \\  label: { type: "string" },
    \\};
    \\
    \\export function Badge({ label }) {
    \\  return (
    \\    <span
    \\      data-part="badge"
    \\      class="inline-flex rounded-md px-2 text-foreground"
    \\    >
    \\      {label}
    \\    </span>
    \\  );
    \\}
    \\
;

test "the language accepts both .pjsx and .ptsx module names" {
    var arena = Arena.init();
    defer arena.deinit();
    try expectEqualStrings("Badge", (try parsePjsx(arena.a(), source, "badge.pjsx")).component.name);
    try expectEqualStrings("Badge", (try parsePjsx(arena.a(), source, "badge.ptsx")).component.name);
}

test "a component with an empty schema may omit the props parameter" {
    var arena = Arena.init();
    defer arena.deinit();
    const zero_props_source =
        \\
        \\export const markerProps = {};
        \\
        \\export function Marker() {
        \\  return <span data-part="marker">Marker</span>;
        \\}
        \\
    ;
    const dom_out = try domCode(arena.a(), zero_props_source, "marker.ptsx");
    const zig_out = try zigCode(arena.a(), zero_props_source, "marker.ptsx");

    try expectMatch(dom_out, "element\\(\\s*\"span\"", "");
    try expectContains(zig_out, "pub fn render(w: *std.Io.Writer, arena: std.mem.Allocator, props: Props) !void");
    try expectContains(zig_out, "<span data-part=\\\"marker\\\"");
}

test "utilities handed to a component's classes prop reach the class manifest" {
    var arena = Arena.init();
    defer arena.deinit();
    const card_source =
        \\import { Text } from "./Text.ptsx";
        \\
        \\export const cardProps = { title: { type: "string" } };
        \\
        \\export function Card({ title }) {
        \\  return (
        \\    <div class="rounded-md">
        \\      <Text variant="body-sm" classes="block truncate">{title}</Text>
        \\      <Text variant="body-sm" classes={`mt-1 ${title}`}>{title}</Text>
        \\    </div>
        \\  );
        \\}
        \\
    ;
    const classes = collectPjsxClasses(arena.a(), card_source, "card.ptsx") catch |e| return report(e);
    try expectStringList(&.{ "block", "mt-1", "rounded-md", "truncate" }, classes);
}

test "repeated class attributes merge in source order across DOM and Zig targets" {
    var arena = Arena.init();
    defer arena.deinit();
    const classes_source =
        \\
        \\export const panelProps = {
        \\  classes: { type: "string", optional: true, default: "" },
        \\  state: { type: "optional-string", optional: true },
        \\};
        \\
        \\export function Panel({ classes = "", state }) {
        \\  return (
        \\    <section
        \\      class="w-full rounded-md"
        \\      class={classes}
        \\      data-state="idle"
        \\      data-state={state}
        \\    >
        \\      Panel
        \\    </section>
        \\  );
        \\}
        \\
    ;
    const dom_out = lowerPjsxToDom(arena.a(), classes_source, "panel.ptsx", null) catch |e| return report(e);

    try expectMatch(dom_out.code, "classes\\(\\$\\$domElement, \\(\\) => \\[\"w-full rounded-md\", classes\\]", "");
    try expectMatch(dom_out.code, "\"data-state\", \\(\\) =>", "");
    try expectStringList(&.{ "rounded-md", "w-full" }, dom_out.classes);

    // The zig target merges class stacks through the runtime …
    const merged_source =
        \\
        \\export const panelProps = {
        \\  classes: { type: "string", optional: true, default: "" },
        \\};
        \\
        \\export function Panel({ classes = "" }) {
        \\  return <section class="w-full rounded-md" class={classes}>Panel</section>;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), merged_source, "panel.ptsx");
    try expectNotContains(zig_out, "_ = arena;");
    try expectContains(zig_out, "try rt.write_merged(w, arena, &.{ \"w-full rounded-md\", props.classes, });");

    // … but repeating any other attribute is only meaningful as an SSR + wire
    // pair, and fails loudly otherwise.
    try std.testing.expectError(error.Pjsx, zigError(arena.a(), classes_source, "panel.ptsx"));
    try expectEqualStrings("Panel: \"data-state\" appears twice without a wire", pjsx.lastError());
}

const icon_source =
    \\export const iconProps = { name: { type: "string", optional: true, default: "dot" } };
    \\export function Icon({ name = "dot" }) {
    \\  return <span data-icon={name} />;
    \\}
;

test ":show applies directly to component roots in the DOM target; the zig target takes hidden" {
    var arena = Arena.init();
    defer arena.deinit();
    const component_show_source =
        \\
        \\import { Icon } from "./Icon.ptsx";
        \\
        \\export const iconPairProps = {
        \\  visible: { type: "boolean", optional: true, default: false },
        \\};
        \\
        \\export function IconPair({ visible = false }) {
        \\  return (
        \\    <div>
        \\      <Icon :show={visible} />
        \\      <Icon :show={!visible} />
        \\    </div>
        \\  );
        \\}
        \\
    ;
    const dom_out = try domCode(arena.a(), component_show_source, "icon-pair.ptsx");
    try expectMatch(dom_out, "show\\(\\$\\$dom\\.component\\(Icon,", "");

    // The zig target's show transport on component calls is `hidden={…}` (see
    // the next test); a `:show` behavior on a component call fails loudly.
    try std.testing.expectError(error.Pjsx, zigErrorSet(arena.a(), &.{
        .{ "Icon.ptsx", icon_source },
        .{ "IconPair.ptsx", component_show_source },
    }, "IconPair"));
    try expectEqualStrings("IconPair: <Icon> carries a behavior, which is not lowered", pjsx.lastError());
}

const family_root_source =
    \\
    \\import { Publr } from "publr/dom";
    \\
    \\export const state = Publr.reactive({
    \\  open: false,
    \\  get label() {
    \\    return state.open ? "Shown" : "Hidden";
    \\  },
    \\});
    \\
    \\export const toggle = (event: Event) => {
    \\  state.open = !state.open;
    \\};
    \\
    \\export const disclosureProps = {
    \\  startOpen: { type: "boolean", optional: true, default: false },
    \\  children: { type: "node" },
    \\};
    \\
    \\export function Disclosure({ startOpen = false, children }) {
    \\  state.open = startOpen;
    \\  return (
    \\    <div data-part="disclosure">
    \\      {children}
    \\    </div>
    \\  );
    \\}
    \\
;

// The zig chain authors reactive attributes as SSR + wire pairs (the static
// value renders, the wire hydrates); a lone wired attribute fails the build.
const family_part_source =
    \\
    \\import { state, toggle } from "./Disclosure.ptsx";
    \\
    \\export const disclosureButtonProps = {
    \\  children: { type: "node" },
    \\};
    \\
    \\export function DisclosureButton({ children }) {
    \\  return (
    \\    <button type="button" aria-expanded="false" aria-expanded={state.open} onClick={toggle}>
    \\      {children}
    \\    </button>
    \\  );
    \\}
    \\
;

test "a family root compiles to a store island with seeds and a generated registration" {
    var arena = Arena.init();
    defer arena.deinit();
    const zig_out = try zigCode(arena.a(), family_root_source, "Disclosure.ptsx");

    try expectContains(zig_out, "data-p-store=\\\"disclosure\\\" data-p=\\\"{&quot;open&quot;:");
    try expectContains(zig_out, "try w.writeAll(if (props.startOpen) \"true\" else \"false\");");

    const registration = (lowerPjsxStoreRegistration(arena.a(), family_root_source, "Disclosure.ptsx") catch |e| return report(e)).?;
    try expectEqualStrings("disclosure", registration.name);
    try expectMatch(registration.code, "Publr\\.createLocalStore\\(\"disclosure\"", "");
    try expectMatch(registration.code, "open: false", "");
    try expectMatch(registration.code, "get label\\(\\)", "");
    try expectMatch(registration.code, "\"toggle\": \\(_dataset, context\\) => context\\?\\.event && toggle\\(context\\.event\\)", "");
}

test "a family part lowers imported state and actions onto the wire transport" {
    var arena = Arena.init();
    defer arena.deinit();
    const part = try zigCodeSet(arena.a(), &.{
        .{ "Disclosure.ptsx", family_root_source },
        .{ "DisclosureButton.ptsx", family_part_source },
    }, "DisclosureButton");

    try expectNotContains(part, "data-p-store");
    try expectContains(part, "aria-expanded=\\\"false\\\"");
    try expectContains(part, "data-p-bind=\\\"aria-expanded:$open\\\"");
    try expectContains(part, "data-p-on=\\\"click:toggle\\\"");
    try std.testing.expect((try lowerPjsxStoreRegistration(arena.a(), family_part_source, "DisclosureButton.ptsx")) == null);
}

test "DOM module objects remain ordinary shared exports" {
    var arena = Arena.init();
    defer arena.deinit();
    const root = try domCode(arena.a(), family_root_source, "Disclosure.ptsx");
    try expectContains(root, "state.open = startOpen");
    try expectNotContains(root, "Publr.createLocalStore");
    const part = try domCode(arena.a(), family_part_source, "DisclosureButton.ptsx");
    try expectContains(part, "state.open");
    try expectNotContains(part, "click:toggle");
}

test "hidden on component calls rides the show transport with inverted polarity" {
    var arena = Arena.init();
    defer arena.deinit();
    const component_hidden_source =
        \\
        \\import { Icon } from "./Icon.ptsx";
        \\
        \\export const iconPairProps = {
        \\  active: { type: "boolean", optional: true, default: false },
        \\  muted: { type: "boolean", optional: true, default: false },
        \\};
        \\
        \\export function IconPair({ active = false, muted = false }) {
        \\  return (
        \\    <div>
        \\      <Icon hidden={!active} />
        \\      <Icon hidden={active} />
        \\      <Icon hidden={active || muted} />
        \\    </div>
        \\  );
        \\}
        \\
    ;
    const dom_out = try domCode(arena.a(), component_hidden_source, "icon-pair.ptsx");
    const zig_out = try zigCodeSet(arena.a(), &.{
        .{ "Icon.ptsx", icon_source },
        .{ "IconPair.ptsx", component_hidden_source },
    }, "IconPair");

    try expectMatch(dom_out, "show\\(\\$\\$dom\\.component\\(Icon,", "");
    try expectMatch(dom_out, "!!active", "");
    try expectMatch(dom_out, "!\\(active \\|\\| muted\\)", "");
    try expectContains(zig_out, "try Icon.render(w, arena, .{ .publr_show = !!props.active, });");
    try expectContains(zig_out, "try Icon.render(w, arena, .{ .publr_show = !props.active, });");
    try expectContains(zig_out, "try Icon.render(w, arena, .{ .publr_show = !(props.active or props.muted), });");
}

test "conditional mounting is not exposed as a Publr directive" {
    var arena = Arena.init();
    defer arena.deinit();
    try std.testing.expectError(error.Pjsx, transformPjsxToDom(arena.a(), "export const item = <div :if={visible}>Item</div>;", .{ .filename = "conditional-mount.ptsx" }));
    try expectMatch(pjsx.lastError(), "conditional mounting is not a Publr directive; use :show", "");
}

test "the zig target does not inject formatting whitespace into raw-text element values" {
    var arena = Arena.init();
    defer arena.deinit();
    const textarea_source =
        \\
        \\export const textareaProps = {
        \\  value: { type: "optional-string", optional: true },
        \\};
        \\
        \\export function Textarea({ value }) {
        \\  return <textarea>{value}</textarea>;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), textarea_source, "textarea.ptsx");

    // The value write follows the open tag with no whitespace text between.
    try expectContains(zig_out,
        \\    try w.writeAll(">");
        \\    if (props.value) |value_1| {
        \\        try rt.escape(w, value_1);
        \\    }
        \\    try w.writeAll("</textarea>");
    );
}

test "one parsed component lowers to DOM and Zig" {
    var arena = Arena.init();
    defer arena.deinit();
    const dom_out = try domCode(arena.a(), source, "badge.pjsx");
    const zig_out = try zigCode(arena.a(), source, "badge.pjsx");

    try expectMatch(dom_out, "import \\* as \\$\\$dom from \"publr/dom\"", "");
    try expectMatch(dom_out, "element\\(\\s*\"span\"", "");
    try expectContains(zig_out, "pub fn render(w: *std.Io.Writer, arena: std.mem.Allocator, props: Props) !void");
    try expectContains(zig_out, "<span data-part=\\\"badge\\\"");
    try expectStringList(&.{ "inline-flex", "px-2", "rounded-md", "text-foreground" }, try collectPjsxClasses(arena.a(), source, "badge.pjsx"));
}

test "portal and anchored-position directives lower through DOM and Zig" {
    var arena = Arena.init();
    defer arena.deinit();
    const overlay_source =
        \\
        \\export const overlayProps = {
        \\  align: { type: "string", optional: true, default: "left", values: ["left", "right"] },
        \\};
        \\
        \\export function Overlay({ align = "left" }) {
        \\  return <div><button @anchor>Anchor</button><div @portal @position={align}>Panel</div></div>;
        \\}
        \\
    ;
    const dom_out = try domCode(arena.a(), overlay_source, "overlay.ptsx");

    try expectMatch(dom_out, "\"data-p-portal\", true", "");
    try expectMatch(dom_out, "\"data-p-anchor\", true", "");
    try expectContains(dom_out, "\"data-p-position\", () => align");

    // The zig chain's spellings are the bare attributes `portal`/`anchor` and
    // a plain `position={…}` (renamed to data-p-position at emission).
    const zig_overlay_source =
        \\
        \\export const overlayProps = {
        \\  align: { type: "string", optional: true, default: "left", values: ["left", "right"] },
        \\};
        \\
        \\export function Overlay({ align = "left" }) {
        \\  return <div><button anchor>Anchor</button><div portal position={align}>Panel</div></div>;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), zig_overlay_source, "overlay.ptsx");
    try expectContains(zig_out, "<button data-p-anchor>Anchor</button>");
    try expectContains(zig_out, " data-p-portal>Panel</div>");
    try expectContains(zig_out, "data-p-position=\\\"");
    try expectContains(zig_out, "try w.writeAll(@tagName(props.@\"align\"));");
}

test "generic literal local-store ownership lowers through DOM; the zig target derives stores from state" {
    var arena = Arena.init();
    defer arena.deinit();
    const island_source =
        \\
        \\export const islandProps = {};
        \\export function Island() {
        \\  return <section @store="example">Content</section>;
        \\}
        \\
    ;
    const dom_out = try domCode(arena.a(), island_source, "island.ptsx");
    try expectMatch(dom_out, "\"data-p-store\", \"example\"", "");

    // In the zig target, store ownership comes from `Publr.reactive` (see the
    // family and local-state tests); a literal `@store` fails loudly.
    try std.testing.expectError(error.Pjsx, zigError(arena.a(), island_source, "island.ptsx"));
    try expectEqualStrings("Island: behavior \"store\" is not lowered", pjsx.lastError());
}

test "optional array defaults lower through DOM and Zig" {
    var arena = Arena.init();
    defer arena.deinit();
    const collection_source =
        \\
        \\export const collectionProps = {
        \\  value: { type: "array", items: "string", optional: true },
        \\  defaultValue: { type: "array", items: "string", optional: true },
        \\  children: { type: "node" },
        \\};
        \\export function Collection({ value, defaultValue, children }) {
        \\  return <div data-controlled={value === undefined ? "false" : "true"}>{(value ?? defaultValue ?? []).map((item) => <input value={item} />)}{children}</div>;
        \\}
        \\
    ;
    _ = try domCode(arena.a(), collection_source, "collection.ptsx");
    const zig_out = try zigCode(arena.a(), collection_source, "collection.ptsx");

    try expectContains(zig_out, "value: ?[]const []const u8 = null,");
    try expectContains(zig_out, "defaultValue: ?[]const []const u8 = null,");
    try expectContains(zig_out, "(props.value == null)");
    try expectContains(zig_out, "for (((props.value orelse props.defaultValue) orelse &.{})) |item| {");
    try expectContains(zig_out, "<div data-controlled=\\\"");
}

test "Slot lowers to a structural child-root merge in the zig target" {
    var arena = Arena.init();
    defer arena.deinit();
    const slot_source =
        \\
        \\import { Slot } from "publr/dom";
        \\export const triggerProps = {
        \\  id: { type: "optional-string", optional: true },
        \\  classes: { type: "string", optional: true, default: "" },
        \\  children: { type: "node", optional: true },
        \\};
        \\export function Trigger({ id, classes = "", children }) {
        \\  return <Slot id={id} class={classes} data-part="trigger" aria-haspopup="menu" anchor>{children}</Slot>;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), slot_source, "Trigger.ptsx");

    try expectContains(zig_out, "rt.slot_props(arena, (if (props.children) |publr_node| try rt.render_to_string(arena, publr_node) else \"\"), .{ .@\"id\" = props.id, .@\"data-part\" = \"trigger\", .@\"aria-haspopup\" = \"menu\", .@\"data-p-anchor\" = true, .class = try rt.merge_classes(arena, &.{ props.classes, })");
    try expectNotContains(zig_out, "<Slot");
}

test "Slot transports adopted action props without referencing erased callbacks" {
    var arena = Arena.init();
    defer arena.deinit();
    const slot_source =
        \\
        \\import { Slot } from "publr/dom";
        \\export const triggerProps = {
        \\  children: { type: "node" },
        \\  onClick: { type: "action", optional: true },
        \\};
        \\export function Trigger({ children, onClick }) {
        \\  return <Slot data-part="trigger" onClick={onClick}>{children}</Slot>;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), slot_source, "Trigger.ptsx");

    // The action prop holds a name at runtime; the slot merge prefixes it with
    // its event and lands it on the child root's data-p-on.
    try expectContains(zig_out, ".@\"data-p-on\" = rt.join_optionals(arena, &.{ (if (props.onClick) |publr_action| @as(?[]const u8, rt.concat(arena, &.{ \"click:\", publr_action })) else @as(?[]const u8, null)), }, \";\")");
    try expectContains(zig_out, "onClick: ?[]const u8 = null,");
}

test "closed Dynamic roots lower without leaking the structural as prop" {
    var arena = Arena.init();
    defer arena.deinit();
    const text_source =
        \\
        \\import { Dynamic } from "publr/dom";
        \\export const textProps = {
        \\  as: { type: "element", optional: true, default: "span", values: ["span", "p", "strong"] },
        \\  children: { type: "node", optional: true },
        \\  variant: { type: "string", values: ["body-sm"] },
        \\};
        \\
        \\export function Text({ as = "span", children, variant }) {
        \\  return <Dynamic as={as} data-variant={variant}>{children}</Dynamic>;
        \\}
        \\
    ;
    const dom_out = try domCode(arena.a(), text_source, "text.ptsx");
    const zig_out = try zigCode(arena.a(), text_source, "text.ptsx");

    try expectMatch(dom_out, "component\\(Dynamic", "");
    // The tag binds once from the enum prop and opens/closes the element.
    try expectContains(zig_out, "const tag_1 = @tagName(props.as);");
    try expectContains(zig_out, "try w.writeAll(tag_1);");
    try expectContains(zig_out, "try w.writeAll(@tagName(props.variant));");
    try expectNotContains(zig_out, " as=");
}

test "a fixed Dynamic root lowers as one intrinsic element" {
    var arena = Arena.init();
    defer arena.deinit();
    const input_source =
        \\
        \\import { Dynamic } from "publr/dom";
        \\export const inputProps = {
        \\  root: { type: "element", internal: true, optional: true, default: "input", values: ["input"] },
        \\  value: { type: "optional-string", optional: true },
        \\};
        \\
        \\export function Input({ value }) {
        \\  return <Dynamic as="input" value={value} />;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), input_source, "Input.ptsx");

    try expectContains(zig_out, "try w.writeAll(\"<input\");");
    try expectNotContains(zig_out, "tag_1");
    try expectNotContains(zig_out, " as=");
}

test "an internal element descriptor derives a finite root without becoming a public prop" {
    var arena = Arena.init();
    defer arena.deinit();
    const heading_source =
        \\
        \\import { Dynamic } from "publr/dom";
        \\export const headingProps = {
        \\  root: {
        \\    type: "element",
        \\    internal: true,
        \\    optional: true,
        \\    default: "h1",
        \\    values: ["h1", "h2", "h3", "h4", "h5", "h6"],
        \\    tagFrom: "level",
        \\  },
        \\  level: { type: "number", values: [1, 2, 3, 4, 5, 6] },
        \\  children: { type: "node", optional: true },
        \\};
        \\
        \\export function Heading({ level, children }) {
        \\  return <Dynamic as={`h${level}`}>{children}</Dynamic>;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), heading_source, "Heading.ptsx");

    try expectNotContains(zig_out, "root:");
    try expectContains(zig_out, "level: f64,");
    try expectContains(zig_out, "const tag_1 = try std.fmt.allocPrint(arena, \"h{s}\", .{ try rt.number_to_string(arena, props.level), });");
    try expectNotContains(zig_out, " as=");
}

test "an internal element descriptor can derive its root from optional-string presence" {
    var arena = Arena.init();
    defer arena.deinit();
    const button_source =
        \\
        \\import { Dynamic } from "publr/dom";
        \\export const buttonProps = {
        \\  root: {
        \\    type: "element",
        \\    internal: true,
        \\    optional: true,
        \\    default: "button",
        \\    values: ["button", "a"],
        \\    tagFrom: "href",
        \\  },
        \\  children: { type: "node", optional: true },
        \\  href: { type: "optional-string", optional: true },
        \\  label: { type: "string" },
        \\};
        \\
        \\export function Button({ children, href, label }) {
        \\  return <Dynamic as={href === undefined ? "button" : "a"} href={href} aria-label={label}>{children}</Dynamic>;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), button_source, "Button.ptsx");

    try expectNotContains(zig_out, "root:");
    try expectContains(zig_out, "const tag_1 = (if ((props.href == null)) \"button\" else \"a\");");
    try expectContains(zig_out, "if (props.href) |value_2| {");
    try expectNotContains(zig_out, " as=");
}

test "the zig target links only imported PJSX modules used as JSX components" {
    var arena = Arena.init();
    defer arena.deinit();
    const text_module_source =
        \\
        \\export const textProps = {
        \\  variant: { type: "string", values: ["body-sm"] },
        \\  children: { type: "node", optional: true },
        \\};
        \\export function Text({ variant, children }) {
        \\  return <span data-variant={variant}>{children}</span>;
        \\}
        \\
    ;
    const example_source =
        \\
        \\import type { TextProps } from "../Text/Text.ptsx";
        \\import { Text as Typography, TEXT_VARIANTS } from "../Text/Text.ptsx";
        \\
        \\export const exampleProps = {};
        \\
        \\export function Example() {
        \\  return <Typography variant="body-sm">Hello</Typography>;
        \\}
        \\
    ;
    const zig_out = try zigCodeSet(arena.a(), &.{
        .{ "Text.ptsx", text_module_source },
        .{ "Example.ptsx", example_source },
    }, "Example");

    try expectContains(zig_out, "const Typography = @import(");
    try expectContains(zig_out, "try Typography.render(");
    try expectNotContains(zig_out, "TextProps");
    try expectNotContains(zig_out, "TEXT_VARIANTS");
}

test "compilePjsx exposes the same target-neutral API" {
    var arena = Arena.init();
    defer arena.deinit();
    const output = compiler.compilePjsx(plugins.ZigTargetOptions, pjsx.targets.zig.ZigOutput, arena.a(), .{ .source = source }, .{
        .filename = "badge.pjsx",
        .target = plugins.zigTarget(),
        .target_options = .{},
    }) catch |e| return report(e);

    try expectContains(output.code, "pub fn render(w: *std.Io.Writer, arena: std.mem.Allocator, props: Props) !void");
}

const ManifestOptions = struct { prefix: []const u8 };

fn manifestCompile(a: std.mem.Allocator, module: *const compiler.ModuleIR, context: compiler.CompileContext, options: ManifestOptions) pjsx.Error![]const u8 {
    std.testing.expectEqualStrings("badge.pjsx", context.filename) catch return error.Pjsx;
    std.testing.expect(module.component.root.* == .element) catch return error.Pjsx;
    const names = try std.mem.join(a, ",", module.component.props.keys());
    return std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ options.prefix, module.component.name, names });
}

test "a third-party target compiles the public semantic IR without changing PJSX core" {
    var arena = Arena.init();
    defer arena.deinit();
    const target = compiler.TargetPlugin(ManifestOptions, []const u8){
        .name = "component-manifest",
        .api_version = 1,
        .compile = manifestCompile,
    };
    const output = compiler.compilePjsx(ManifestOptions, []const u8, arena.a(), .{ .source = source }, .{
        .filename = "badge.pjsx",
        .target = target,
        .target_options = .{ .prefix = "custom" },
    }) catch |e| return report(e);

    try expectEqualStrings("custom:Badge:label", output);
    try std.testing.expect((try createPjsxModule(arena.a(), source, "badge.pjsx")).component.root.* == .element);
    try std.testing.expect(@TypeOf(plugins.domTarget().compile) == *const fn (std.mem.Allocator, *const compiler.ModuleIR, compiler.CompileContext, dom_target.DomTargetOptions) pjsx.Error!dom_target.DomOutput);
}

/// The original scans `dist/` (no tests); Zig keeps inline tests in the same
/// file, so scan only the code before the first test block.
fn readRepoFile(a: std.mem.Allocator, relative: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ build_options.root, relative });
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 24));
    const first_test = std.mem.indexOf(u8, text, "\ntest ") orelse return text;
    return text[0..first_test];
}

test "the compiler core contains no built-in backend names or target switch" {
    var arena = Arena.init();
    defer arena.deinit();
    const core = try readRepoFile(arena.a(), "src/compiler.zig");
    const entry = try readRepoFile(arena.a(), "src/root.zig");
    const joined = try std.mem.concat(arena.a(), u8, &.{ core, "\n", entry });

    try expectNoMatch(core, "\\b(?:DomOutput|ZigOutput|ReactTarget|ZigTarget)\\b", "");
    try expectNoMatch(core, "@import\\(\"targets/", "");
    try expectNoMatch(joined, "request\\.target|switch\\s*\\(.*target", "");
}

test "the compiler contains no concrete component directives" {
    var arena = Arena.init();
    defer arena.deinit();
    const files = [_][]const u8{ "src/canonicalize.zig", "src/compiler.zig", "src/store.zig", "src/transform.zig", "src/targets/zig.zig" };
    var parts: std.ArrayList([]const u8) = .empty;
    for (files) |file| try parts.append(arena.a(), try readRepoFile(arena.a(), file));
    const joined = try std.mem.join(arena.a(), "\n", parts.items);

    try expectNoMatch(joined, "(?:\\$\\$(?:accordion|menu|select|unitControl)|data-p-(?:accordion|menu|select|unit-control))", "");
}

test "DOM components render through the runtime root-attribute forwarding boundary" {
    var arena = Arena.init();
    defer arena.deinit();
    const output = transformPjsxToDom(arena.a(),
        \\function Trigger({ label }) {
        \\  return <Dynamic as="button" aria-label={label}>{label}</Dynamic>;
        \\}
        \\export const trigger = <Trigger label="Open" data-part="trigger" aria-describedby="hint" />;
    , .{ .filename = "trigger.ptsx" }) catch |e| return report(e);

    try expectMatch(output.code, "import \\* as \\$\\$dom from \"publr/dom\"", "");
    try expectMatch(output.code, "component\\(Trigger,", "");
    try expectMatch(output.code, "component\\(Dynamic,", "");
    try expectMatch(output.code, "\"data-part\": \"trigger\"", "");
    try expectMatch(output.code, "\"aria-describedby\": \"hint\"", "");
}

test "a reactive component child stays a live value instead of a nested thunk" {
    var arena = Arena.init();
    defer arena.deinit();
    const output = transformPjsxToDom(arena.a(),
        \\function Readout({ children }) {
        \\  return <output>{children}</output>;
        \\}
        \\function Editor({ state }) {
        \\  return <Readout>{state.label}</Readout>;
        \\}
    , .{ .filename = "editor.ptsx" }) catch |e| return report(e);

    try expectMatch(output.code, "get children\\(\\) \\{\\s*return state\\.label;\\s*\\}", "");
    try expectNoMatch(output.code, "get children\\(\\) \\{\\s*return \\(\\) => state\\.label", "");
}

test "nested JSX-bearing callbacks keep distinct rewritten parameter scopes" {
    var arena = Arena.init();
    defer arena.deinit();
    const output = transformPjsxToDom(arena.a(),
        \\const variants = HIERARCHIES.flatMap((hierarchy) =>
        \\  INTENTS.map((intent) => ({
        \\    Demo: () => <Button hierarchy={hierarchy} intent={intent} />,
        \\  })),
        \\);
    , .{ .filename = "nested-gallery-callbacks.ptsx" }) catch |e| return report(e);

    try expectMatch(output.code, "flatMap\\(\\(\\$\\$p\\) =>", "");
    try expectMatch(output.code, "INTENTS\\.map\\(\\(\\$\\$p1\\) =>", "");
    try expectMatch(output.code, "get hierarchy\\(\\) \\{\\s*return \\$\\$p;\\s*\\}", "");
    try expectMatch(output.code, "get intent\\(\\) \\{\\s*return \\$\\$p1;\\s*\\}", "");
}

test "typed option children lower to descriptor data in the DOM target" {
    var arena = Arena.init();
    defer arena.deinit();
    const output = transformPjsxToDom(arena.a(),
        \\function Demo({ options, value }) {
        \\  return (
        \\    <RangeScalePicker value={value} label="Spacing">
        \\      <RangeScalePickerOptions>
        \\        {options.map((option) => (
        \\          <RangeScalePickerOption value={option.value}>{option.label}</RangeScalePickerOption>
        \\        ))}
        \\      </RangeScalePickerOptions>
        \\    </RangeScalePicker>
        \\  );
        \\}
    , .{ .filename = "range-scale-demo.ptsx" }) catch |e| return report(e);

    try expectMatch(output.code, "get children\\(\\) \\{\\s*return options\\.map", "");
    try expectMatch(output.code, "label: \\$\\$p\\.label", "");
    try expectMatch(output.code, "value: \\$\\$p\\.value", "");
    try expectNoMatch(output.code, "component\\(RangeScalePickerOptions", "");
    try expectNoMatch(output.code, "component\\(RangeScalePickerOption", "");

    const static_output = transformPjsxToDom(arena.a(),
        \\export const picker = (
        \\  <RangeScalePicker value="sm" label="Spacing">
        \\    <RangeScalePickerOptions>
        \\      <RangeScalePickerOption value="xs">XS</RangeScalePickerOption>
        \\      <RangeScalePickerOption value="sm">SM</RangeScalePickerOption>
        \\    </RangeScalePickerOptions>
        \\  </RangeScalePicker>
        \\);
    , .{ .filename = "static-range-scale.ptsx" }) catch |e| return report(e);

    try expectMatch(static_output.code, "get children\\(\\)", "");
    try expectMatch(static_output.code, "label: \"XS\"", "");
    try expectMatch(static_output.code, "value: \"xs\"", "");
    try expectNoMatch(static_output.code, "component\\(RangeScalePickerOptions", "");
}

test "compound configuration-shaped children remain real component anatomy" {
    var arena = Arena.init();
    defer arena.deinit();
    const fixture_source =
        \\
        \\export const fixtureProps = {};
        \\
        \\export function Fixture() {
        \\  return (
        \\    <BoxValueControl label="Box value" defaultValue={[50, "px"]}>
        \\      <BoxValueControlIcon>
        \\        <SelectedSidesIcon top bottom size="lg" />
        \\      </BoxValueControlIcon>
        \\      <BoxValueControlRangeScalePicker>
        \\        <BoxValueControlRangeScalePickerOption value="small">Small</BoxValueControlRangeScalePickerOption>
        \\        <BoxValueControlRangeScalePickerOption value="large">Large</BoxValueControlRangeScalePickerOption>
        \\      </BoxValueControlRangeScalePicker>
        \\      <BoxValueControlRangePicker min={0} max={100} step={1} label="Custom box value" />
        \\    </BoxValueControl>
        \\  );
        \\}
        \\
    ;
    const dom_out = transformPjsxToDom(arena.a(), fixture_source, .{ .filename = "box-value-fixture.ptsx" }) catch |e| return report(e);

    try expectMatch(dom_out.code, "component\\(BoxValueControlIcon", "");
    try expectMatch(dom_out.code, "component\\(SelectedSidesIcon", "");
    try expectMatch(dom_out.code, "component\\(BoxValueControlRangeScalePicker", "");
    try expectMatch(dom_out.code, "component\\(BoxValueControlRangeScalePickerOption", "");
    try expectMatch(dom_out.code, "component\\(BoxValueControlRangePicker", "");
    try expectNoMatch(dom_out.code, "rangeScalePickerOptions", "");
    try expectNoMatch(dom_out.code, "iconIsSelectedSidesIcon", "");
}

test "compound anatomy sharing the parent prefix remains rendered children" {
    var arena = Arena.init();
    defer arena.deinit();
    const demo_source =
        \\
        \\import { UnitControl } from "./UnitControl.ptsx";
        \\import { UnitControlInput } from "./UnitControlInput.ptsx";
        \\import { UnitControlUnit } from "./UnitControlUnit.ptsx";
        \\export const demoProps = {};
        \\export function Demo() {
        \\  return <UnitControl><UnitControlInput value={0} /><UnitControlUnit value="px" /></UnitControl>;
        \\}
        \\
    ;
    const zig_out = try zigCodeSet(arena.a(), &.{
        .{
            "UnitControl.ptsx",
            \\export const unitControlProps = { children: { type: "node" } };
            \\export function UnitControl({ children }) {
            \\  return <div data-part="unit-control">{children}</div>;
            \\}
        },
        .{
            "UnitControlInput.ptsx",
            \\export const unitControlInputProps = { value: { type: "number" } };
            \\export function UnitControlInput({ value }) {
            \\  return <input value={value} />;
            \\}
        },
        .{
            "UnitControlUnit.ptsx",
            \\export const unitControlUnitProps = { value: { type: "string" } };
            \\export function UnitControlUnit({ value }) {
            \\  return <span>{value}</span>;
            \\}
        },
        .{ "Demo.ptsx", demo_source },
    }, "Demo");
    const dom_out = try domCode(arena.a(), demo_source, "Demo.ptsx");

    try expectContains(zig_out, "try UnitControlInput.render(w, arena, .{ .value = @as(f64, 0), });");
    try expectContains(zig_out, "try UnitControlUnit.render(w, arena, .{ .value = \"px\", });");
    try expectNotContains(zig_out, "inputValue");
    try expectNotContains(zig_out, "unitValue");
    try expectMatch(dom_out, "component\\(UnitControlInput, \\{ value: 0 \\}\\)", "");
    try expectMatch(dom_out, "component\\(UnitControlUnit, \\{ value: \"px\" \\}\\)", "");
    try expectNoMatch(dom_out, "inputValue:", "");
    try expectNoMatch(dom_out, "unitValue:", "");
}

test "nullish coalescing preserves JavaScript semantics and lowers to Zig optionals" {
    var arena = Arena.init();
    defer arena.deinit();
    const nullish_source =
        \\
        \\export const fallbackProps = {
        \\  title: { type: "optional-string", optional: true },
        \\  hidden: { type: "optional-boolean", optional: true },
        \\  children: { type: "children", optional: true },
        \\  fallback: { type: "node" },
        \\};
        \\
        \\export function Fallback({ title, hidden, children, fallback }) {
        \\  return (
        \\    <section title={title ?? "Untitled"} hidden={hidden ?? false}>
        \\      {children ?? fallback}
        \\    </section>
        \\  );
        \\}
        \\
    ;
    const dom_out = try domCode(arena.a(), nullish_source, "fallback.ptsx");
    const zig_out = try zigCode(arena.a(), nullish_source, "fallback.ptsx");

    try expectMatch(dom_out, "title \\?\\? \"Untitled\"", "");
    try expectMatch(dom_out, "hidden \\?\\? false", "");
    try expectMatch(dom_out, "children \\?\\? fallback", "");
    try expectContains(zig_out, "title: ?[]const u8 = null,");
    try expectContains(zig_out, "hidden: ?bool = null,");
    try expectContains(zig_out, "children: ?rt.Node = null,");
    try expectContains(zig_out, "try rt.escape(w, (props.title orelse \"Untitled\"));");
    try expectContains(zig_out, "if ((props.hidden orelse false)) try w.writeAll(\" hidden\");");
    try expectContains(zig_out, "try (props.children orelse props.fallback).render(w, arena);");
}

test "optional node children can fall back to declarative JSX" {
    var arena = Arena.init();
    defer arena.deinit();
    const button_source =
        \\
        \\import { Text } from "./Text.ptsx";
        \\export const buttonProps = {
        \\  children: { type: "node", optional: true },
        \\  label: { type: "string" },
        \\};
        \\export function Button({ children, label }) {
        \\  return <button>{children ?? <Text variant="body-md">{label}</Text>}</button>;
        \\}
        \\
    ;
    const zig_out = try zigCodeSet(arena.a(), &.{
        .{
            "Text.ptsx",
            \\export const textProps = {
            \\  variant: { type: "string", values: ["body-sm", "body-md"] },
            \\  children: { type: "node", optional: true },
            \\};
            \\export function Text({ variant, children }) {
            \\  return <span data-variant={variant}>{children}</span>;
            \\}
        },
        .{ "Button.ptsx", button_source },
    }, "Button");

    try expectContains(zig_out, "if (props.children) |present_1| {");
    try expectContains(zig_out, "try rt.escape(w, props.label);");
    try expectContains(zig_out, "try Text.render(w, arena, .{ .variant = .@\"body-md\", .children = rt.block(&children_2, Children_2) });");
}

test "conditionals with undefined lower to optional Zig attributes" {
    var arena = Arena.init();
    defer arena.deinit();
    const native_source =
        \\
        \\export const nativeProps = {
        \\  enabled: { type: "boolean" },
        \\  title: { type: "string" },
        \\};
        \\export function Native({ enabled, title }) {
        \\  return <button title={enabled ? title : undefined} disabled={enabled ? false : undefined} />;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), native_source, "Native.ptsx");

    try expectContains(zig_out, "if ((if (props.enabled) @as(?[]const u8, props.title) else @as(?[]const u8, null))) |value_1| {");
    try expectContains(zig_out, "try w.writeAll(\" title=\\\"\");");
}

test "optional props compare with undefined by optional presence" {
    var arena = Arena.init();
    defer arena.deinit();
    const link_source =
        \\
        \\export const linkProps = { href: { type: "optional-string", optional: true } };
        \\export function Link({ href }) {
        \\  return <span data-missing={href === undefined ? "true" : undefined} />;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), link_source, "Link.ptsx");

    try expectContains(zig_out, "(if ((props.href == null)) @as(?[]const u8, \"true\") else @as(?[]const u8, null))");
}

test "numbers lower to f64 props and decimal attribute text" {
    var arena = Arena.init();
    defer arena.deinit();
    const numeric_source =
        \\
        \\export const rangeProps = {
        \\  value: { type: "number" },
        \\  step: { type: "optional-number", optional: true },
        \\};
        \\
        \\export function Range({ value, step }) {
        \\  return <input type="range" value={value} step={step} />;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), numeric_source, "range.ptsx");

    try expectContains(zig_out, "value: f64,");
    try expectContains(zig_out, "step: ?f64 = null,");
    try expectContains(zig_out, "try rt.write_number(w, props.value);");
    try expectContains(zig_out, "if (props.step) |value_1| {");
}

test "structured arrays lower to typed Zig slices" {
    var arena = Arena.init();
    defer arena.deinit();
    const options_source =
        \\
        \\import { RangeBase } from "./RangeBase.ptsx";
        \\export const optionListProps = {
        \\  options: {
        \\    type: "array",
        \\    fields: {
        \\      label: { type: "string" },
        \\      value: { type: "string" },
        \\    },
        \\  },
        \\  value: { type: "string" },
        \\  onInput: { type: "action", optional: true },
        \\};
        \\
        \\export function OptionList({ options, value, onInput }) {
        \\  const emitInput = (event) => {
        \\    const option = options[Number(event.target.value)];
        \\    if (option) onInput?.(option.value);
        \\  };
        \\  return (
        \\    <RangeBase
        \\      value={Math.max(0, options.findIndex((option) => option.value === value))}
        \\      label={options[Math.max(0, options.findIndex((option) => option.value === value))].label}
        \\      onInput={emitInput}
        \\    />
        \\  );
        \\}
        \\
    ;
    const zig_out = try zigCodeSet(arena.a(), &.{
        .{
            "RangeBase.ptsx",
            \\export const rangeBaseProps = {
            \\  value: { type: "number" },
            \\  label: { type: "string" },
            \\  onInput: { type: "action", optional: true },
            \\};
            \\export function RangeBase({ value, label, onInput }) {
            \\  return <input type="range" value={value} aria-label={label} onInput={onInput} />;
            \\}
        },
        .{ "OptionList.ptsx", options_source },
    }, "OptionList");

    try expectContains(zig_out, "pub const OptionsItem = struct {\n    label: []const u8,\n    value: []const u8,\n};");
    try expectContains(zig_out, "options: []const OptionsItem,");
    try expectContains(zig_out, ".value = rt.number_max(@as(f64, 0), publr_find_1:");
    try expectContains(zig_out, "for (props.options, 0..) |option, publr_index_2|");
    try expectContains(zig_out, "std.mem.eql(u8, option.value, props.value)");
    // The forwarding adapter erases; the action wires straight through.
    try expectContains(zig_out, ".onInput = props.onInput,");
}

test "structured arrays support optional and node fields used by compound descriptors" {
    var arena = Arena.init();
    defer arena.deinit();
    const compound_source =
        \\
        \\export const compoundProps = {
        \\  parts: {
        \\    type: "array",
        \\    fields: {
        \\      kind: { type: "string" },
        \\      id: { type: "optional-string", optional: true },
        \\      content: { type: "node", optional: true },
        \\    },
        \\  },
        \\};
        \\
        \\export function Compound({ parts }) {
        \\  return <section>{parts[0].content}</section>;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), compound_source, "compound.ptsx");

    try expectContains(zig_out, "pub const PartsItem = struct {\n    kind: []const u8,\n    id: ?[]const u8 = null,\n    content: ?rt.Node = null,\n};");
}

test "local aliases of structured props resolve inside portable JSX" {
    var arena = Arena.init();
    defer arena.deinit();
    const alias_source =
        \\
        \\export const aliasProps = {
        \\  parts: {
        \\    type: "array",
        \\    fields: { enabled: { type: "boolean" }, label: { type: "string" } },
        \\  },
        \\};
        \\
        \\export function Alias({ parts }) {
        \\  const trigger = parts[0];
        \\  return <button aria-expanded={trigger.enabled}>{trigger.label}</button>;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), alias_source, "alias.ptsx");

    try expectContains(zig_out, "if (props.parts[@intFromFloat(@as(f64, 0))].enabled)");
    try expectContains(zig_out, "try rt.escape(w, props.parts[@intFromFloat(@as(f64, 0))].label);");
}

test "primitive arrays and closed unions remain typed in the zig target" {
    var arena = Arena.init();
    defer arena.deinit();
    const editor_source =
        \\
        \\export const editorProps = {
        \\  units: { type: "array", items: "string" },
        \\  defaultValue: {
        \\    type: "union",
        \\    variants: ["string", "number-string-tuple"],
        \\  },
        \\};
        \\
        \\export function Editor({ units, defaultValue }) {
        \\  return (
        \\    <select data-named={typeof defaultValue === "string"}>
        \\      {units.map((unit) => <option value={unit}>{unit}</option>)}
        \\    </select>
        \\  );
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), editor_source, "editor.ptsx");

    try expectContains(zig_out, "pub const DefaultValue = union(enum) { string: []const u8, number_string_tuple: struct { f64, []const u8 } };");
    try expectContains(zig_out, "units: []const []const u8,");
    try expectContains(zig_out, "if ((props.defaultValue == .string)) try w.writeAll(\" data-named\");");
    try expectContains(zig_out, "for (props.units) |unit| {");

    // Array literals filling component props are not lowered — loudly.
    try std.testing.expectError(error.Pjsx, zigErrorSet(arena.a(), &.{
        .{
            "ValuePreview.ptsx",
            \\export const valuePreviewProps = {
            \\  units: { type: "array", items: "string" },
            \\};
            \\export function ValuePreview({ units }) {
            \\  return <span>{units.map((unit) => <b>{unit}</b>)}</span>;
            \\}
        },
        .{
            "Caller.ptsx",
            \\import { ValuePreview } from "./ValuePreview.ptsx";
            \\export const callerProps = {};
            \\export function Caller() {
            \\  return <ValuePreview units={["px", "%"]} />;
            \\}
        },
    }, "Caller"));
    try expectEqualStrings("Caller: a non-empty array literal is not lowered", pjsx.lastError());
}

test "closed union narrowing lowers to tagged-union payload access" {
    var arena = Arena.init();
    defer arena.deinit();
    const union_source =
        \\
        \\export const unionValueProps = {
        \\  value: { type: "union", variants: ["string", "number-string-tuple"] },
        \\};
        \\export function UnionValue({ value }) {
        \\  return <span data-named={typeof value === "string"} data-number={typeof value === "string" ? 0 : value[0]}>x</span>;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), union_source, "union-value.ptsx");

    try expectContains(zig_out, "pub const Value = union(enum) { string: []const u8, number_string_tuple: struct { f64, []const u8 } };");
    try expectContains(zig_out, "if ((props.value == .string)) try w.writeAll(\" data-named\");");
    try expectContains(zig_out, "(switch (props.value) { .number_string_tuple => |publr_tuple| publr_tuple[0], else => unreachable })");
}

test "derived reactive values render their SSR initial without leaking props into the client store" {
    var arena = Arena.init();
    defer arena.deinit();
    const derived_source =
        \\
        \\import { Publr } from "publr/dom";
        \\
        \\export const derivedProps = {
        \\  options: {
        \\    type: "array",
        \\    fields: {
        \\      label: { type: "string" },
        \\      value: { type: "string" },
        \\    },
        \\  },
        \\  defaultValue: { type: "string" },
        \\};
        \\
        \\export function Derived({ options, defaultValue }) {
        \\  const state = Publr.reactive({
        \\    label: options[Math.max(0, options.findIndex((option) => option.value === defaultValue))].label,
        \\  });
        \\  return <output>{state.label}</output>;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), derived_source, "derived.ptsx");
    const store = lowerPjsxStoreRegistration(arena.a(), derived_source, "derived.ptsx") catch |e| return report(e);
    const store_code = if (store) |s| s.code else "";

    try expectContains(zig_out, "data-p-store=\\\"derived\\\"");
    try expectContains(zig_out, " data-p-text=\\\"$label\\\">");
    try expectContains(zig_out, "for (props.options, 0..)");
    try expectContains(zig_out, "std.mem.eql(u8, option.value, props.defaultValue)");
    try expectMatch(store_code, "label: undefined", "");
    try expectMatch(store_code, "const options = undefined;", "");
    try expectMatch(store_code, "const defaultValue = undefined;", "");
    try expectNoMatch(store_code, "Publr\\.reactive\\(\\{[^}]*options", "s");
}

test "numeric template interpolation and multiple action wires remain typed" {
    var arena = Arena.init();
    defer arena.deinit();
    const range_source =
        \\
        \\export const rangeProps = {
        \\  value: { type: "number" },
        \\  onInput: { type: "action", optional: true },
        \\  onChange: { type: "action", optional: true },
        \\};
        \\
        \\export function Range({ value, onInput, onChange }) {
        \\  return (
        \\    <input
        \\      type="range"
        \\      style={`--value:${value}`}
        \\      onInput={onInput}
        \\      onChange={onChange}
        \\    />
        \\  );
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), range_source, "range.ptsx");

    try expectContains(zig_out, "try rt.escape(w, try std.fmt.allocPrint(arena, \"--value:{s}\", .{ try rt.number_to_string(arena, props.value), }));");
    try expectContains(zig_out, "try rt.write_wire_attr(w, \"data-p-on\", &.{ .{ .prefix = \"input:\", .value = props.onInput }, .{ .prefix = \"change:\", .value = props.onChange }, });");
}

test "a reactive numeric field wires through an SSR + wire attribute pair" {
    var arena = Arena.init();
    defer arena.deinit();
    const numeric_value_source =
        \\
        \\import { Publr } from "publr/dom";
        \\
        \\export const numericValueProps = {
        \\  initial: { type: "number" },
        \\};
        \\
        \\export function NumericValue({ initial }) {
        \\  const state = Publr.reactive({ value: initial });
        \\  return <input value="0" value={state.value} />;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), numeric_value_source, "numeric-value.ptsx");

    try expectContains(zig_out, "data-p-store=\\\"numeric-value\\\" value=\\\"0\\\"");
    try expectContains(zig_out, " data-p-bind=\\\"value:$value\\\">");
}

test "component calls pass typed booleans and forward renamed action props by name" {
    var arena = Arena.init();
    defer arena.deinit();
    const component_source =
        \\
        \\import { RangePicker } from "./RangePicker.ptsx";
        \\export const boxProps = {
        \\  disabled: { type: "boolean", optional: true, default: false },
        \\  onTokenInput: { type: "action", optional: true },
        \\};
        \\
        \\export function Box({ disabled, onTokenInput }) {
        \\  return <RangePicker disabled={disabled} onInput={onTokenInput} />;
        \\}
        \\
    ;
    const zig_out = try zigCodeSet(arena.a(), &.{
        .{
            "RangePicker.ptsx",
            \\export const rangePickerProps = {
            \\  disabled: { type: "boolean", optional: true, default: false },
            \\  onInput: { type: "action", optional: true },
            \\};
            \\export function RangePicker({ disabled, onInput }) {
            \\  return <input type="range" disabled={disabled} onInput={onInput} />;
            \\}
        },
        .{ "Box.ptsx", component_source },
    }, "Box");

    // Action props hold the bare action name; the receiving render site
    // derives the event, so a renamed action needs no rewiring shim.
    try expectContains(zig_out, ".disabled = props.disabled,");
    try expectContains(zig_out, ".onInput = props.onTokenInput,");
}

test "Publr.reactive declares portable component-local state" {
    var arena = Arena.init();
    defer arena.deinit();
    const stateful_source =
        \\
        \\import { Publr } from "publr/dom";
        \\
        \\export const disclosureProps = {};
        \\
        \\export function Disclosure({}) {
        \\  const state = Publr.reactive({ open: false });
        \\  const open = () => {
        \\    state.open = true;
        \\  };
        \\
        \\  return (
        \\    <section>
        \\      <button onClick={open}>Open</button>
        \\      <div class="hidden" :show="$open">Contents</div>
        \\    </section>
        \\  );
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), stateful_source, "disclosure.ptsx");
    const store = lowerPjsxStoreRegistration(arena.a(), stateful_source, "disclosure.ptsx") catch |e| return report(e);
    const store_code = if (store) |s| s.code else "";

    try expectEqualStrings("state", (try parsePjsx(arena.a(), stateful_source, "disclosure.ptsx")).component.reactive.?.state_name);
    try expectContains(zig_out, "data-p-store=\\\"disclosure\\\"");
    try expectContains(zig_out, "data-p-on=\\\"click:open\\\"");
    try expectContains(zig_out, "data-p-show=\\\"$open\\\"");
    try expectMatch(store_code, "Publr\\.createLocalStore\\(\"disclosure\"", "");
    try expectMatch(store_code, "const state = Publr\\.reactive\\(\\{ open: false \\}\\)", "");
    try expectMatch(store_code, "\"open\": \\(_dataset, context\\)", "");
}

test "literal Publr store directives bind compound parts through their ancestor island" {
    var arena = Arena.init();
    defer arena.deinit();
    const menu_source =
        \\
        \\export const menuPartProps = {};
        \\
        \\export function MenuPart() {
        \\  return (
        \\    <div>
        \\      <button
        \\        @click="toggle"
        \\        @keydown.down.prevent="openFirst"
        \\        @keydown.home.prevent="openFirst"
        \\        @keydown.end.prevent="openFirst"
        \\        :aria-expanded="$open"
        \\      >Menu</button>
        \\      <div class="hidden" :show="$open" :class="$open -> flex" :text="$label">
        \\        Fallback
        \\      </div>
        \\    </div>
        \\  );
        \\}
        \\
    ;
    const dom_out = try domCode(arena.a(), menu_source, "menu-part.ptsx");
    const zig_out = try zigCode(arena.a(), menu_source, "menu-part.ptsx");

    try expectMatch(dom_out, "\"data-p-on\", \"click:toggle;keydown\\.down\\.prevent:openFirst;keydown\\.home\\.prevent:openFirst;keydown\\.end\\.prevent:openFirst\"", "");
    try expectMatch(dom_out, "\"data-p-bind\", \"aria-expanded:\\$open\"", "");
    try expectMatch(dom_out, "\"data-p-show\", \"\\$open\"", "");
    try expectMatch(dom_out, "\"data-p-class\", \"\\$open -> flex\"", "");
    try expectMatch(dom_out, "\"data-p-text\", \"\\$label\"", "");
    try expectContains(zig_out, "data-p-on=\\\"click:toggle;keydown.down.prevent:openFirst;keydown.home.prevent:openFirst;keydown.end.prevent:openFirst\\\"");
    try expectContains(zig_out, "data-p-bind=\\\"aria-expanded:$open\\\"");
    try expectContains(zig_out, "data-p-show=\\\"$open\\\"");
    try expectContains(zig_out, "data-p-text=\\\"$label\\\"");
    try expectContains(zig_out, "data-p-class=\\\"$open -&gt; flex\\\"");
}

test "Slot accepts explicit Publr binding directives" {
    var arena = Arena.init();
    defer arena.deinit();
    const trigger_source =
        \\
        \\import { Slot } from "publr/dom";
        \\
        \\export const triggerProps = {
        \\  children: { type: "node" },
        \\};
        \\
        \\export function Trigger({ children }) {
        \\  return (
        \\    <Slot :aria-expanded="$open" :disabled="$disabled">
        \\      {children}
        \\    </Slot>
        \\  );
        \\}
        \\
    ;
    // Literal directives carry a wire; expression directives derive it from state.
    const output = try zigCode(arena.a(), trigger_source, "trigger.ptsx");
    try expectMatch(output, "aria-expanded:\\$open", "");
}

test "reactive style maps are rejected loudly" {
    var arena = Arena.init();
    defer arena.deinit();
    const text_demo_source =
        \\
        \\import { Publr } from "publr/dom";
        \\
        \\export const textDemoProps = {};
        \\
        \\export function TextDemo() {
        \\  const state = Publr.reactive({ width: "20rem" });
        \\  return (
        \\    <div style={{ maxWidth: () => state.width }}>
        \\      Field label
        \\    </div>
        \\  );
        \\}
        \\
    ;
    try std.testing.expectError(error.Pjsx, zigError(arena.a(), text_demo_source, "text-demo.ptsx"));
    try expectEqualStrings("TextDemo: style map value \"maxWidth\" is not a literal string; reactive styles are not lowered", pjsx.lastError());
}

test "reactive scalar props carry their bind wire through component boundaries" {
    var arena = Arena.init();
    defer arena.deinit();
    const field_source =
        \\
        \\export const numberFieldProps = {
        \\  value: { type: "number" },
        \\};
        \\
        \\export function NumberField({ value }) {
        \\  return <input type="number" value={`${value}`} />;
        \\}
        \\
    ;
    const editor_source =
        \\
        \\import { Publr } from "publr/dom";
        \\import { NumberField } from "./NumberField.ptsx";
        \\
        \\export const editorProps = {};
        \\
        \\export function Editor() {
        \\  const state = Publr.reactive({ value: 0 });
        \\  return <NumberField value={state.value} />;
        \\}
        \\
    ;
    const sources = [_][2][]const u8{
        .{ "NumberField.ptsx", field_source },
        .{ "Editor.ptsx", editor_source },
    };
    const editor = try zigCodeSet(arena.a(), &sources, "Editor");
    const field = try zigCodeSet(arena.a(), &sources, "NumberField");

    try expectContains(editor, ".value = @as(f64, 0), .publr_bind_value = \"$value\",");
    try expectContains(field, "publr_bind_value: ?[]const u8 = null,");
    try expectContains(field, "(if (props.publr_bind_value) |publr_wire| @as(?[]const u8, rt.concat(arena, &.{ \"value:\", publr_wire })) else @as(?[]const u8, null))");
}

test "text wires cross component roots through the transport props" {
    var arena = Arena.init();
    defer arena.deinit();
    const parent_source =
        \\
        \\import { Text } from "./Text.ptsx";
        \\export const parentProps = {
        \\  value: { type: "string" },
        \\};
        \\
        \\export function Parent({ value }) {
        \\  return <Text>{value}</Text>;
        \\}
        \\
    ;
    const text_source =
        \\
        \\export const textProps = {
        \\  children: { type: "node" },
        \\};
        \\
        \\export function Text({ children }) {
        \\  return <span>{children}</span>;
        \\}
        \\
    ;
    const sources = [_][2][]const u8{
        .{ "Text.ptsx", text_source },
        .{ "Parent.ptsx", parent_source },
    };
    const parent = try zigCodeSet(arena.a(), &sources, "Parent");
    const text = try zigCodeSet(arena.a(), &sources, "Text");

    // The component-call root passes the whole transport through; the callee's
    // root receives a caller's text wire as data-p-text.
    try expectContains(parent, ".publr_text_wire = props.publr_text_wire,");
    try expectContains(text, "try rt.write_attr_cond(w, \"data-p-text\", props.publr_text_wire);");
}

test "component-local state renders SSR initials from semantic props" {
    var arena = Arena.init();
    defer arena.deinit();
    const selection_source =
        \\
        \\import { Publr } from "publr/dom";
        \\
        \\export const selectionProps = {
        \\  selectionKind: {
        \\    type: "string",
        \\    optional: true,
        \\    default: "sides",
        \\    values: ["sides", "corners"],
        \\  },
        \\  defaultSelection: {
        \\    type: "string",
        \\    values: ["Top", "Left", "All sides"],
        \\  },
        \\};
        \\
        \\export function Selection(props) {
        \\  const state = Publr.reactive({
        \\    kind: props.selectionKind ?? "sides",
        \\    selection: props.defaultSelection,
        \\    get left() {
        \\      return state.selection.includes("Left");
        \\    },
        \\  });
        \\  const selectAll = () => {
        \\    state.selection = "All sides";
        \\  };
        \\
        \\  return (
        \\    <section>
        \\      <span hidden={!state.left}>{state.selection}</span>
        \\      <button onClick={selectAll}>All</button>
        \\    </section>
        \\  );
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), selection_source, "selection.ptsx");
    const store = lowerPjsxStoreRegistration(arena.a(), selection_source, "selection.ptsx") catch |e| return report(e);
    const store_code = if (store) |s| s.code else "";

    try expectContains(zig_out, "data-p-store=\\\"selection\\\"");
    // The span renders its seeded SSR text and wires; the derived getter has
    // no SSR value, so the show wire hydrates without a static hidden.
    try expectContains(zig_out, "<span data-p-show=\\\"$left\\\" data-p-text=\\\"$selection\\\">");
    try expectContains(zig_out, "try w.writeAll(@tagName(props.defaultSelection));");
    try expectContains(zig_out, "data-p-on=\\\"click:selectAll\\\"");
    try expectMatch(store_code, "kind: \"sides\"", "");
    try expectMatch(store_code, "selection: undefined", "");
    try expectNoMatch(store_code, "Publr\\.reactive\\(\\{[^}]*props\\.", "s");
}

test "a single props object preserves live component getters across targets" {
    var arena = Arena.init();
    defer arena.deinit();
    const object_props_source =
        \\
        \\export const meterProps = {
        \\  value: { type: "number" },
        \\  label: { type: "string" },
        \\  onInput: { type: "action", optional: true },
        \\};
        \\
        \\export function Meter(props) {
        \\  return <input type="range" value={props.value} aria-label={props.label} onInput={props.onInput} />;
        \\}
        \\
    ;
    const dom_out = try domCode(arena.a(), object_props_source, "meter.ptsx");
    const zig_out = try zigCode(arena.a(), object_props_source, "meter.ptsx");

    try expectMatch(dom_out, "value", "");
    try expectContains(zig_out, "try rt.write_number(w, props.value);");
    try expectContains(zig_out, "try rt.escape(w, props.label);");
    try expectContains(zig_out, "try rt.write_wire_attr(w, \"data-p-on\", &.{ .{ .prefix = \"input:\", .value = props.onInput }, });");
}

test "ternary conditions preserve JavaScript optional string truthiness" {
    var arena = Arena.init();
    defer arena.deinit();
    const optional_source =
        \\
        \\export const hintProps = {
        \\  hint: { type: "optional-string", optional: true },
        \\};
        \\
        \\export function Hint({ hint }) {
        \\  return <div>{hint ? <span>{hint}</span> : null}</div>;
        \\}
        \\
    ;
    const zig_out = try zigCode(arena.a(), optional_source, "hint.ptsx");

    // The presence rule belongs to JSX && guards; a ternary keeps JS truthiness.
    try expectContains(zig_out, "if ((if (props.hint) |value| value.len != 0 else false)) {");
    try expectContains(zig_out, "if (props.hint) |value_1| {");
}

test "the Vite adapter transforms both PJSX extensions" {
    // The Vite plugin itself is JavaScript-only; its transform hook is
    // `transformPjsxToDom` gated on the `.pjsx|.ptsx` module id, which is what
    // this port exercises.
    var arena = Arena.init();
    defer arena.deinit();
    inline for (.{ "pjsx", "ptsx" }) |extension| {
        const id = "/project/badge." ++ extension;
        try std.testing.expect(pjsx.isPjsxModule(id));
        const result = transformPjsxToDom(arena.a(), source, .{ .filename = id }) catch |e| return report(e);
        try expectMatch(result.code, "element\\(\\s*\"span\"", "");
    }
}

test "the IR carries module-level finite string maps so targets need no AST" {
    var arena = Arena.init();
    defer arena.deinit();
    const map_source =
        \\
        \\const toneClass = {
        \\  draft: "text-muted-foreground",
        \\  published: "text-success",
        \\};
        \\
        \\export const dotProps = {
        \\  tone: { type: "string", default: "draft" },
        \\};
        \\
        \\export function Dot({ tone }) {
        \\  return <span data-part="dot" class={toneClass[tone]} />;
        \\}
        \\
    ;
    const module = createPjsxModule(arena.a(), map_source, "dot.ptsx") catch |e| return report(e);

    try std.testing.expectEqual(@as(usize, 1), module.finite_maps.count());
    const tone_class = module.finite_maps.get("toneClass").?;
    try expectStringList(&.{ "draft", "published" }, tone_class.keys());
    try expectEqualStrings("text-muted-foreground", tone_class.get("draft").?);
    try expectEqualStrings("text-success", tone_class.get("published").?);
}

/// `JSON.parse(JSON.stringify(x))` deep-equals `x`: parse the JSON into a
/// generic value, re-serialize it, and compare against a canonical rendering.
fn jsonRoundTripEquals(a: std.mem.Allocator, json: []const u8) !bool {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const once = try std.json.Stringify.valueAlloc(a, parsed, .{});
    const again = try std.json.parseFromSliceLeaky(std.json.Value, a, once, .{});
    const twice = try std.json.Stringify.valueAlloc(a, again, .{});
    return std.mem.eql(u8, once, twice);
}

test "the whole IR survives a JSON round-trip for out-of-process targets" {
    var arena = Arena.init();
    defer arena.deinit();
    const module = createPjsxModule(arena.a(), source, "badge.pjsx") catch |e| return report(e);
    const json = try compiler.toJson(arena.a(), module);

    // No field may vanish or degrade through serialization — the Zig target
    // receives exactly this. A Set would silently become {}.
    try std.testing.expect(try jsonRoundTripEquals(arena.a(), json));
    try expectMatch(json, "\"capabilities\":\\[", "");
    try expectMatch(json, "\"root\":\\{\"kind\":\"element\"", "");
}

test "IR capabilities are sorted so serialized modules are byte-stable" {
    var arena = Arena.init();
    defer arena.deinit();
    const first = (createPjsxModule(arena.a(), source, "badge.pjsx") catch |e| return report(e)).capabilities;
    var index: usize = 1;
    while (index < first.len) : (index += 1) {
        try std.testing.expect(std.mem.order(u8, first[index - 1].name(), first[index].name()) != .gt);
    }
}

test "side-effect imports surface as explicit component behaviors" {
    var arena = Arena.init();
    defer arena.deinit();
    const behavior_source =
        \\
        \\import "../../behaviors/dropdown";
        \\
        \\export const menuProps = {
        \\  children: { type: "node" },
        \\};
        \\
        \\export function Menu({ children }) {
        \\  return (
        \\    <div data-part="menu" @store="dropdown-menu">
        \\      {children}
        \\    </div>
        \\  );
        \\}
        \\
    ;
    const module = createPjsxModule(arena.a(), behavior_source, "menu.ptsx") catch |e| return report(e);
    try expectStringList(&.{"../../behaviors/dropdown"}, module.component.behaviors);
    // A named import is a dependency, not a behavior.
    try expectStringList(&.{}, (try createPjsxModule(arena.a(), source, "badge.pjsx")).component.behaviors);
}
