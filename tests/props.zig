//! Schema-free TypeScript authoring through the public compiler APIs.
const std = @import("std");
const pjsx = @import("pjsx");

fn contains(source: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, source, expected) == null) {
        std.debug.print("expected {s} in:\n{s}\n", .{ expected, source });
        return error.TestExpectedEqual;
    }
}

fn lower(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    const module = try pjsx.compiler.createPjsxModule(a, source, "Example.ptsx");
    const program = try pjsx.targets.zig.Program.init(a, &.{module});
    return program.lower(a, "Example");
}

test "props derive from annotations and destructuring without implicit defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\type Props = { amount?: number; enabled?: boolean; required: boolean; mode?: "a" | "b"; label: string };
        \\export function Example({ amount = 1.25, enabled, required, mode, label = "Label" }: Props) {
        \\  return <div>{amount}{enabled && <b>On</b>}{label}</div>;
        \\}
    ;
    const parsed = try pjsx.analyze.parsePjsx(a, source, "Example.ptsx");
    try std.testing.expectEqual(@as(f64, 1.25), parsed.schema.get("amount").?.default.?.number);
    try std.testing.expect(!parsed.schema.get("label").?.optional);
    try std.testing.expect(parsed.schema.get("enabled").?.default == null);
    try std.testing.expect(parsed.schema.get("required").?.default == null);
    try std.testing.expect(parsed.schema.get("mode").?.default == null);
    const code = try lower(a, source);
    try contains(code, "amount: f64 = 1.25");
    try contains(code, "enabled: ?bool = null");
    try contains(code, "required: bool,");
    try contains(code, "mode: ?Mode = null");
    try contains(code, "props.enabled orelse false");
}

test "unannotated destructuring infers optional widened primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try pjsx.analyze.parsePjsx(arena.allocator(),
        \\export function Example({ amount = -1.25, label = "Hi", enabled = false }) { return <div>{label}</div>; }
    , "Example.ptsx");
    try std.testing.expectEqual(@as(f64, -1.25), parsed.schema.get("amount").?.default.?.number);
    try std.testing.expect(parsed.schema.get("label").?.optional);
    try std.testing.expect(parsed.schema.get("label").?.values == null);
    try std.testing.expect(parsed.schema.get("enabled").?.type == .boolean);
}

const Imports = struct {
    fn load(_: *anyopaque, _: std.mem.Allocator, _: []const u8, specifier: []const u8) pjsx.Error!?pjsx.TypeSource {
        if (!std.mem.eql(u8, specifier, "./types")) return null;
        return .{ .filename = "types.ts", .code =
        \\export const sizes = { small: "1", large: "2" } as const;
        \\export interface Base { size: keyof typeof sizes; hidden?: boolean; ignored: string; }
        \\export type Props = Omit<Base, "ignored"> & { size: "small" };
        };
    }
};

test "imported interfaces keyof and intersections preserve narrowed fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    const resolver = pjsx.TypeResolver{ .context = &context, .load = Imports.load };
    const parsed = try pjsx.analyze.parsePjsxWithResolver(arena.allocator(),
        \\import type { Props } from "./types";
        \\export function Example({ size, hidden }: Props) { return <div>{size}{hidden && <b>Hidden</b>}</div>; }
    , "Example.ptsx", resolver);
    try std.testing.expectEqual(@as(usize, 2), parsed.schema.count());
    const values = parsed.schema.get("size").?.values.?;
    try std.testing.expectEqual(@as(usize, 1), values.len);
    try std.testing.expectEqualStrings("small", values[0].string);
}

test "IR JSON retains union alternatives literal numbers and variadic tuple constraints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try pjsx.compiler.createPjsxModule(a,
        \\type Option = { value: number; label: string };
        \\type Props = ({ mode: "a"; count: 1 | 2 } | { mode: "b"; label: string }) & { options: readonly [Option, Option, ...Option[]] };
        \\export function Example({ mode }: Props) { return <div>{mode}</div>; }
    , "Example.ptsx");
    const contract = module.component.props_type.?;
    try std.testing.expect(contract.kind == .@"union");
    try std.testing.expectEqual(@as(usize, 2), contract.members.len);
    try std.testing.expect(contract.members[0].fields.has("count"));
    try std.testing.expect(!contract.members[0].fields.has("label"));
    const tuple = contract.members[0].fields.get("options").?.type;
    try std.testing.expect(tuple.rest);
    try std.testing.expectEqual(@as(usize, 3), tuple.members.len);
    const json = try pjsx.compiler.toJson(a, module);
    try contains(json, "\"propsType\":{\"kind\":\"union\"");
    try contains(json, "\"literal\":1");
    try contains(json, "\"rest\":true");
}

test "DOM defaults remain native and typed guards work through map scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const output = try pjsx.dom.transformPjsxToDom(arena.allocator(),
        \\type Props = { label?: string; enabled?: boolean; items: { label?: string; enabled?: boolean }[] };
        \\export function Example({ label = nextLabel(), enabled, items }: Props) {
        \\  return <div>{enabled && <b>On</b>}{items.map(item => <i>{item.label && <b>Label</b>}{item.enabled && <b>On</b>}</i>)}</div>;
        \\}
    , .{ .filename = "Example.ptsx" });
    try contains(output.code, "label = nextLabel()");
    try contains(output.code, "enabled === true");
    try contains(output.code, "$$p().label != null");
    try contains(output.code, "$$p().enabled === true");
    try std.testing.expect(std.mem.indexOf(u8, output.code, "??") == null);
}

test "Zig JSX guards test optional numbers and strings for presence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lower(arena.allocator(),
        \\export function Example({ label, count }: { label?: string; count?: number }) {
        \\  return <div>{label && <b>Label</b>}{count && <b>Count</b>}</div>;
        \\}
    );
    try contains(code, "props.label != null");
    try contains(code, "props.count != null");
    try contains(code, "count: ?f64 = null");
}

test "unsupported tuple shapes and Zig defaults fail instead of silently changing meaning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.Pjsx, pjsx.compiler.createPjsxModule(a,
        \\export function Example({ value }: { value: string | [boolean, number] }) { return <div />; }
    , "Example.ptsx"));
    try contains(pjsx.lastError(), "tuple");
    try std.testing.expectError(error.Pjsx, lower(a,
        \\export function Example({ value = next() }: { value?: number }) { return <div>{value}</div>; }
    ));
    try contains(pjsx.lastError(), "default expression");
    try std.testing.expectError(error.Pjsx, lower(a,
        \\export function Example({ value }: { value: string | null }) { return <div>{value}</div>; }
    ));
    try contains(pjsx.lastError(), "nullable");
}

test "a broad string union stays a string and a guard narrows a child prop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const leaf = try pjsx.compiler.createPjsxModule(a,
        \\export function Leaf({ label }: { label: string | "special" }) { return <span>{label}</span>; }
    , "Leaf.ptsx");
    try std.testing.expect(leaf.component.props.get("label").?.values == null);
    const example = try pjsx.compiler.createPjsxModule(a,
        \\import { Leaf } from "./Leaf.ptsx";
        \\export function Example({ label }: { label?: string }) { return <div>{label && <Leaf label={label} />}</div>; }
    , "Example.ptsx");
    const program = try pjsx.targets.zig.Program.init(a, &.{ leaf, example });
    const code = try program.lower(a, "Example");
    try contains(code, ".label = (props.label).?");
    try std.testing.expect(std.mem.indexOf(u8, code, "orelse") == null);
}

test "absent optional family seeds stay omitted from JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lower(arena.allocator(),
        \\import { reactive } from "publr/dom";
        \\export const state = reactive({ label: undefined as string | undefined });
        \\export function Example({ label }: { label?: string }) {
        \\  state.label = label;
        \\  return <div>{state.label}</div>;
        \\}
    );
    try contains(code, "if (props.label) |seed_");
    try contains(code, "seed_separator_");
    try std.testing.expect(std.mem.indexOf(u8, code, "orelse") == null);
}

test "structured family seeds render keyed rows and conditional hydration anchors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try lower(arena.allocator(),
        \\import { Publr } from "publr-jsx";
        \\export const state = Publr.reactive({ rows: [], shown: true });
        \\export function Example({ rows = [], shown = true }: { rows?: Array<{id: string; label: string}>; shown?: boolean }) {
        \\  state.rows = rows;
        \\  state.shown = shown;
        \\  return <ul>{state.shown && <li>Heading</li>}{state.rows.map(row => <li key={row.id}>{row.label}</li>)}</ul>;
        \\}
    );
    try contains(code, "rt.write_seed_value(w, arena, props.rows)");
    try contains(code, "rt.RootAttributeWriter.init(");
    try contains(code, "data-p-if");
    try contains(code, "rows: []const RowsItem = &.{}");
}
