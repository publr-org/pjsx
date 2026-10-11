//! A live expression as JavaScript: the body of the slot function the browser
//! runs for a binding (`data-p-bind="disabled:$e_Row_3"`), printed from the IR.
//! Names print as the IR holds them: a prop under its prop name, the module's
//! state as `state`; the caller decides which of them the function receives
//! from its scope (`references`).

const std = @import("std");
const util = @import("../util.zig");
const compiler = @import("../compiler.zig");
const err = @import("../err.zig");

const ExpressionIR = compiler.ExpressionIR;

pub const Error = err.Error || std.Io.Writer.Error;

/// The expression as JavaScript source, parenthesized where precedence needs it.
pub fn print(arena: std.mem.Allocator, e: *const ExpressionIR) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try write(&out.writer, e);
    return out.written();
}

/// Whether `e` is a value JavaScript can compute: no markup, nothing the IR
/// could not carry. Markup is structure the render draws, not a value.
pub fn printable(e: *const ExpressionIR) bool {
    return switch (e.*) {
        .literal, .absent, .reference => true,
        .node, .unsupported => false,
        .member => |member| printable(member.object) and (member.property != .expression or printable(member.property.expression)),
        .unary => |unary| printable(unary.argument),
        .operation => |operation| printable(operation.left) and printable(operation.right),
        .conditional => |conditional| printable(conditional.@"test") and printable(conditional.consequent) and printable(conditional.alternate),
        .template => |template| for (template.parts) |part| {
            if (part == .expression and !printable(part.expression)) break false;
        } else true,
        .array => |array| for (array.items) |item| {
            if (!printable(item)) break false;
        } else true,
        .object => |object| for (object.fields) |field| {
            if (!printable(field.value)) break false;
        } else true,
        .call => |call| printable(call.callee) and for (call.arguments) |argument| {
            if (!printable(argument)) break false;
        } else true,
        .construct => |construct| printable(construct.callee) and for (construct.arguments) |argument| {
            if (!printable(argument)) break false;
        } else true,
        .chain => |chain| printable(chain.expression),
        .function => |function| printable(function.body) and for (function.locals) |local| {
            if (!printable(local.value)) break false;
        } else true,
    };
}

/// A constant expression (literals, and arrays and objects of them) as JSON; null for
/// anything else.
pub fn json(arena: std.mem.Allocator, e: *const ExpressionIR) Error!?[]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    if (!try write_json(&out.writer, e)) return null;
    return out.written();
}

fn write_json(w: *std.Io.Writer, e: *const ExpressionIR) Error!bool {
    switch (e.*) {
        .literal => try write(w, e),
        .array => |array| {
            try w.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try w.writeByte(',');
                if (!try write_json(w, item)) return false;
            }
            try w.writeByte(']');
        },
        .object => |object| {
            try w.writeByte('{');
            for (object.fields, 0..) |field, index| {
                if (index > 0) try w.writeByte(',');
                try util.writeJsonString(w, field.name);
                try w.writeByte(':');
                if (!try write_json(w, field.value)) return false;
            }
            try w.writeByte('}');
        },
        else => return false,
    }
    return true;
}

/// A free name the expression reads, with where the IR says it comes from.
pub const Reference = struct {
    name: []const u8,
    source: compiler.ReferenceSource,
};

/// Every free name `e` reads, once each, in first-read order. Names an arrow
/// function inside binds (`items.some((x) => x.on)`) are not free.
pub fn references(arena: std.mem.Allocator, e: *const ExpressionIR) Error![]const Reference {
    var found: std.ArrayList(Reference) = .empty;
    var bound: std.ArrayList([]const u8) = .empty;
    try collect(arena, e, &found, &bound);
    return found.items;
}

fn collect(arena: std.mem.Allocator, e: *const ExpressionIR, found: *std.ArrayList(Reference), bound: *std.ArrayList([]const u8)) Error!void {
    switch (e.*) {
        .literal, .absent, .unsupported => {},
        .reference => |reference| {
            if (reference.source != .prop and util.containsString(bound.items, reference.name)) return;
            for (found.items) |known| {
                if (known.source == reference.source and std.mem.eql(u8, known.name, reference.name)) return;
            }
            try found.append(arena, .{
                .name = reference.name,
                .source = reference.source,
            });
        },
        .member => |member| {
            try collect(arena, member.object, found, bound);
            if (member.property == .expression) try collect(arena, member.property.expression, found, bound);
        },
        .unary => |unary| try collect(arena, unary.argument, found, bound),
        .operation => |operation| {
            try collect(arena, operation.left, found, bound);
            try collect(arena, operation.right, found, bound);
        },
        .conditional => |conditional| {
            try collect(arena, conditional.@"test", found, bound);
            try collect(arena, conditional.consequent, found, bound);
            try collect(arena, conditional.alternate, found, bound);
        },
        .template => |template| for (template.parts) |part| {
            if (part == .expression) try collect(arena, part.expression, found, bound);
        },
        .array => |array| for (array.items) |item| try collect(arena, item, found, bound),
        .object => |object| for (object.fields) |field| try collect(arena, field.value, found, bound),
        .call => |call| {
            try collect(arena, call.callee, found, bound);
            for (call.arguments) |argument| try collect(arena, argument, found, bound);
        },
        .construct => |construct| {
            try collect(arena, construct.callee, found, bound);
            for (construct.arguments) |argument| try collect(arena, argument, found, bound);
        },
        .chain => |chain| try collect(arena, chain.expression, found, bound),
        .function => |function| {
            const depth = bound.items.len;
            defer bound.shrinkRetainingCapacity(depth);
            try bound.appendSlice(arena, function.parameters);
            for (function.locals) |local| {
                try collect(arena, local.value, found, bound);
                try bound.append(arena, local.name);
            }
            try collect(arena, function.body, found, bound);
        },
        .node => {},
    }
}

fn write(w: *std.Io.Writer, e: *const ExpressionIR) Error!void {
    switch (e.*) {
        .literal => |literal| switch (literal) {
            .string => |text| try util.writeJsonString(w, text),
            .number => |number| {
                var buffer: [1024]u8 = undefined;
                var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
                try w.writeAll(util.numberToString(fixed.allocator(), number) catch return err.fail("a number literal does not print", .{}));
            },
            .boolean => |boolean| try w.writeAll(if (boolean) "true" else "false"),
            .null => try w.writeAll("null"),
        },
        .absent => try w.writeAll("undefined"),
        .reference => |reference| try w.writeAll(reference.name),
        .member => |member| {
            try write_operand(w, member.object);
            if (member.optional) try w.writeAll("?.");
            switch (member.property) {
                .string => |name| if (util.isIdentifierName(name)) {
                    try w.print("{s}{s}", .{ if (member.optional) "" else ".", name });
                } else {
                    try w.writeAll("[");
                    try util.writeJsonString(w, name);
                    try w.writeAll("]");
                },
                .number => |number| {
                    try w.writeAll("[");
                    try write(w, &.{
                        .literal = .{
                            .number = number,
                        },
                    });
                    try w.writeAll("]");
                },
                .expression => |index| {
                    try w.writeAll("[");
                    try write(w, index);
                    try w.writeAll("]");
                },
            }
        },
        .unary => |unary| {
            try w.writeAll(unary.operator);
            if (std.ascii.isAlphabetic(unary.operator[0])) try w.writeByte(' ');
            try write_operand(w, unary.argument);
        },
        .operation => |operation| {
            try w.writeByte('(');
            try write(w, operation.left);
            try w.print(" {s} ", .{operation.operator});
            try write(w, operation.right);
            try w.writeByte(')');
        },
        .conditional => |conditional| {
            try w.writeByte('(');
            try write(w, conditional.@"test");
            try w.writeAll(" ? ");
            try write(w, conditional.consequent);
            try w.writeAll(" : ");
            try write(w, conditional.alternate);
            try w.writeByte(')');
        },
        .template => |template| {
            try w.writeByte('`');
            for (template.parts) |part| switch (part) {
                .string => |text| for (text) |char| {
                    if (char == '`' or char == '\\' or char == '$') try w.writeByte('\\');
                    try w.writeByte(char);
                },
                .expression => |inner| {
                    try w.writeAll("${");
                    try write(w, inner);
                    try w.writeByte('}');
                },
            };
            try w.writeByte('`');
        },
        .array => |array| {
            try w.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try w.writeAll(", ");
                try write(w, item);
            }
            try w.writeByte(']');
        },
        .object => |object| {
            try w.writeAll("({ ");
            for (object.fields, 0..) |field, index| {
                if (index > 0) try w.writeAll(", ");
                try util.writeJsonString(w, field.name);
                try w.writeAll(": ");
                try write(w, field.value);
            }
            try w.writeAll(" })");
        },
        .call => |call| {
            try write_operand(w, call.callee);
            if (call.optional) try w.writeAll("?.");
            try write_arguments(w, call.arguments);
        },
        .construct => |construct| {
            try w.writeAll("new ");
            try write_operand(w, construct.callee);
            try write_arguments(w, construct.arguments);
        },
        .chain => |chain| try write(w, chain.expression),
        .function => |function| {
            try w.writeByte('(');
            for (function.parameters, 0..) |parameter, index| {
                if (index > 0) try w.writeAll(", ");
                try w.writeAll(parameter);
            }
            try w.writeAll(") => ");
            if (function.locals.len == 0) {
                try write_operand(w, function.body);
                return;
            }
            try w.writeAll("{ ");
            for (function.locals) |local| {
                try w.print("const {s} = ", .{local.name});
                try write(w, local.value);
                try w.writeAll("; ");
            }
            try w.writeAll("return ");
            try write(w, function.body);
            try w.writeAll("; }");
        },
        .node => return err.fail("markup inside a live expression is not printed as JavaScript", .{}),
        .unsupported => |unsupported| return err.fail("expression kind \"{s}\" is not printed as JavaScript", .{unsupported.feature}),
    }
}

fn write_arguments(w: *std.Io.Writer, arguments: []const *const ExpressionIR) Error!void {
    try w.writeByte('(');
    for (arguments, 0..) |argument, index| {
        if (index > 0) try w.writeAll(", ");
        try write(w, argument);
    }
    try w.writeByte(')');
}

/// An operand of a member access, a call or a unary operator: wrapped unless it
/// binds at least as tightly already.
fn write_operand(w: *std.Io.Writer, e: *const ExpressionIR) Error!void {
    const tight = switch (e.*) {
        .literal => |literal| literal != .number,
        .reference, .member, .call, .template, .array, .absent, .operation, .conditional, .object => true,
        else => false,
    };
    if (tight) return write(w, e);
    try w.writeByte('(');
    try write(w, e);
    try w.writeByte(')');
}

fn expectPrints(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try compiler.createPjsxModule(a, source, "Probe.ptsx");
    const root = module.component.root.element;
    const value = root.attributes[0].value();
    try std.testing.expectEqualStrings(expected, try print(a, value));
}

test "a live expression prints as JavaScript with its names as the IR holds them" {
    try expectPrints(
        \\export const state = Publr.reactive({ editing: false, empty: true });
        \\export function Probe() { return <div hidden={!state.editing && state.empty} />; }
    , "(!state.editing && state.empty)");
    try expectPrints(
        \\const TONES: Record<string, string> = { a: "x" };
        \\export function Probe({ tone }: { tone: string }) { return <div class={TONES[tone] ?? "neutral"} />; }
    , "(TONES[tone] ?? \"neutral\")");
    try expectPrints(
        \\export const state = Publr.reactive({ items: [] as { on: boolean }[] });
        \\export function Probe() { return <div title={`${state.items.filter((item) => item.on).length} on`} />; }
    , "`${state.items.filter((item) => item.on).length} on`");
}

test "optional chains and `new` print as written" {
    try expectPrints(
        \\export const state = Publr.reactive({ items: [] as { value: string; on: boolean }[] });
        \\export function Probe() { return <div title={state.items.find((item) => item.on)?.value ?? ""} />; }
    , "(state.items.find((item) => item.on)?.value ?? \"\")");
    try expectPrints(
        \\export const state = Publr.reactive({ map: null as null | Record<string, string> });
        \\export function Probe() { return <div title={state.map?.["a"]?.toUpperCase?.()} />; }
    , "state.map?.[\"a\"]?.toUpperCase?.()");
    try expectPrints(
        \\export const state = Publr.reactive({ at: 0 });
        \\export function Probe() { return <div title={new Date(state.at).toISOString()} />; }
    , "(new Date(state.at)).toISOString()");
}

test "references are the expression's free names, without an arrow function's own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try compiler.createPjsxModule(a,
        \\export const state = Publr.reactive({ items: [] as { on: boolean }[] });
        \\export function Probe({ label }: { label: string }) {
        \\  return <div title={state.items.some((item) => item.on) ? label : TITLE} />;
        \\}
    , "Probe.ptsx");
    const found = try references(a, module.component.root.element.attributes[0].value());
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("state", found[0].name);
    try std.testing.expectEqualStrings("label", found[1].name);
    try std.testing.expectEqual(compiler.ReferenceSource.prop, found[1].source);
    try std.testing.expectEqualStrings("TITLE", found[2].name);
}
