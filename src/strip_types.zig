//! TypeScript type stripping — the replacement for oxc-transform's
//! `transformSync` in the DOM pipeline. Re-parses the transformed module,
//! collects every TypeScript-only range the parser skipped (annotations, type
//! parameters/arguments, `as` tails, modifiers, …) plus whole type-only
//! declarations/imports/exports found in the AST, and removes them.
//!
//! oxc-transform also re-prints the module through its code generator, which
//! drops redundant parentheses (`($$p.x ?? (1))` → `$$p.x ?? 1`, `!(!(x))` →
//! `!!x`). Consumers of the DOM output depend on that shape, so the same
//! precedence-safe paren removal is applied here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Node = ast.Node;
const parser = @import("parser.zig");
const err = @import("err.zig");

const Range = [2]u32;

fn lessRange(_: void, a: Range, b: Range) bool {
    return a[0] < b[0];
}

const Collector = struct {
    allocator: Allocator,
    source: []const u8,
    ranges: std.ArrayList(Range),

    fn add(self: *Collector, start: u32, end: u32) anyerror!void {
        if (end > start) try self.ranges.append(self.allocator, .{ start, end });
    }

    /// Range of a type specifier including the comma that separates it from a
    /// neighbour. A specifier followed by a value specifier takes the comma
    /// after it; one followed only by other type specifiers (or nothing) takes
    /// the comma before it, so a run of trailing type specifiers removes as
    /// one piece and leaves no dangling comma behind.
    fn specifierRange(self: *Collector, list: []*Node, index: usize, comptime kind: []const u8) Range {
        const spec = list[index];
        var value_follows = false;
        for (list[index + 1 ..]) |later| if (@field(later, kind) != .type) {
            value_follows = true;
        };
        if (value_follows) return .{ spec.start, list[index + 1].start };
        // Nothing but types (or the brace) follows: take the comma before, and
        // the trailing comma after, so the last value specifier ends the list.
        var end: u32 = spec.end;
        while (end < self.source.len and std.ascii.isWhitespace(self.source[end])) end += 1;
        if (end < self.source.len and self.source[end] == ',') end += 1 else end = spec.end;
        return .{ if (index > 0) list[index - 1].end else spec.start, end };
    }

    fn visit(self: *Collector, node: *Node) anyerror!void {
        switch (node.type) {
            .TSDeclaration => try self.add(node.start, node.end),
            .ImportDeclaration => {
                if (node.import_kind == .type) return self.add(node.start, node.end);
                var value_count: usize = 0;
                for (node.specifiers) |spec| if (spec.import_kind != .type) {
                    value_count += 1;
                };
                if (node.specifiers.len > 0 and value_count == 0) return self.add(node.start, node.end);
                for (node.specifiers, 0..) |spec, index| if (spec.import_kind == .type) {
                    const range = self.specifierRange(node.specifiers, index, "import_kind");
                    try self.add(range[0], range[1]);
                };
            },
            .ExportNamedDeclaration => {
                if (node.export_kind == .type) return self.add(node.start, node.end);
                if (node.declaration) |declaration| if (declaration.type == .TSDeclaration) return self.add(node.start, node.end);
                var value_count: usize = 0;
                for (node.specifiers) |spec| if (spec.export_kind != .type) {
                    value_count += 1;
                };
                if (node.specifiers.len > 0 and value_count == 0 and node.declaration == null) return self.add(node.start, node.end);
                for (node.specifiers, 0..) |spec, index| if (spec.export_kind == .type) {
                    const range = self.specifierRange(node.specifiers, index, "export_kind");
                    try self.add(range[0], range[1]);
                };
            },
            .ExportDefaultDeclaration => {
                if (node.declaration) |declaration| if (declaration.type == .TSDeclaration) return self.add(node.start, node.end);
            },
            else => {},
        }
    }
};

const ParenContext = enum { free, arrow_body, unary_not, other };

fn isPrimary(node: *Node) bool {
    return switch (node.type) {
        .Identifier, .Literal, .MemberExpression, .CallExpression, .ChainExpression, .ThisExpression, .Super, .TemplateLiteral, .TaggedTemplateExpression, .ArrayExpression, .ObjectExpression, .NewExpression, .JSXElement, .JSXFragment, .MetaProperty, .ImportExpression => true,
        else => false,
    };
}

fn parenContext(parent: *Node, field: ast.Field) ParenContext {
    return switch (parent.type) {
        .ArrayExpression, .CallExpression, .NewExpression, .ReturnStatement, .VariableDeclarator, .JSXExpressionContainer, .TemplateLiteral, .ThrowStatement, .SpreadElement, .AssignmentPattern => switch (field) {
            .callee, .id => .other,
            else => .free,
        },
        .Property => if (field == .value_node and !parent.computed) .free else .other,
        .MemberExpression => if (field == .property and parent.computed) .free else .other,
        .AssignmentExpression => if (field == .right) .free else .other,
        .ConditionalExpression => if (field == .test_) .other else .free,
        .ArrowFunctionExpression => if (field == .body and parent.expression_body) .arrow_body else .other,
        .UnaryExpression => if (std.mem.eql(u8, parent.operator, "!")) .unary_not else .other,
        else => .other,
    };
}

fn canDropParens(source: []const u8, node: *Node, inner: *Node, context: ParenContext) bool {
    if (inner.type == .SequenceExpression) return false;
    // oxc keeps parens around parenthesized function expressions.
    if (inner.type == .ArrowFunctionExpression or inner.type == .FunctionExpression) return false;
    // A line terminator between `(` and the contents would let ASI change the
    // meaning (`return (\n x)` → `return;`), so keep such pairs.
    if (std.mem.indexOfScalar(u8, source[node.start + 1 .. inner.start], '\n') != null) return false;
    if (context == .arrow_body) return inner.type != .ObjectExpression;
    if (inner.type == .ObjectExpression or inner.type == .FunctionExpression or inner.type == .ClassExpression) return context == .free;
    if (isPrimary(inner)) return true;
    if (context == .free) return true;
    if (context == .unary_not) return inner.type == .UnaryExpression and std.mem.eql(u8, inner.operator, "!");
    return false;
}

fn collectParens(collector: *Collector, node: *Node, context: ParenContext) anyerror!void {
    if (node.type == .ParenthesizedExpression) {
        const inner = node.expression.?;
        if (canDropParens(collector.source, node, inner, context)) {
            try collector.add(node.start, node.start + 1);
            try collector.add(node.end - 1, node.end);
            return collectParens(collector, inner, context);
        }
        return collectParens(collector, inner, .other);
    }
    for (ast.childFields(node.type)) |cf| {
        if (cf[1]) {
            for (ast.getList(node, cf[0])) |child| if (child) |c| try collectParens(collector, c, parenContext(node, cf[0]));
        } else if (ast.getSingle(node, cf[0])) |child| {
            try collectParens(collector, child, parenContext(node, cf[0]));
        }
    }
}

/// Remove TypeScript syntax from `code`, returning plain JavaScript.
pub fn stripTypes(allocator: Allocator, code: []const u8, filename: []const u8) err.Error![]const u8 {
    const parsed = parser.parseWithTypeRanges(allocator, code, filename) catch |e| switch (e) {
        error.Pjsx => {
            const message = try allocator.dupe(u8, err.message());
            return err.fail("pjsx: {s}: {s}", .{ filename, message });
        },
        else => return e,
    };
    var collector = Collector{ .allocator = allocator, .source = code, .ranges = .empty };
    try collector.ranges.appendSlice(allocator, parsed.ts_ranges);
    ast.walk(parsed.program, &collector, Collector.visit) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    collectParens(&collector, parsed.program, .other) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    std.mem.sort(Range, collector.ranges.items, {}, lessRange);

    var out: std.ArrayList(u8) = .empty;
    var pos: u32 = 0;
    for (collector.ranges.items) |range| {
        if (range[1] <= pos) continue;
        const start = @max(range[0], pos);
        try out.appendSlice(allocator, code[pos..start]);
        // Keep line structure: preserve newlines inside the removed range.
        for (code[start..range[1]]) |c| if (c == '\n') try out.append(allocator, '\n');
        pos = range[1];
    }
    try out.appendSlice(allocator, code[pos..]);
    return out.toOwnedSlice(allocator);
}

test "stripTypes removes annotations, type imports and type declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try stripTypes(arena.allocator(),
        \\import type { TextProps } from "./Text.ptsx";
        \\import { Text as Typography, type Other, TEXT_VARIANTS } from "./Text.ptsx";
        \\import { type Only } from "./only";
        \\import {
        \\  Unit,
        \\  type CssUnit,
        \\  type UnitValue,
        \\} from "./unit";
        \\interface Props { a: string }
        \\type Alias<T> = T | null;
        \\export const toggle = (event: Event): void => { state.open = !state.open!; };
        \\function f<T>($$p: Props, x?: number) { return $$p as any; }
        \\const y = f<string>($$p, 1);
        \\const z = [($$p.a ?? (1)), !(!(x)), !((a ?? b) || c), () => ({ k: (v) }), (a, b), ($$p.o).map(($$i) => ($$i)), (
        \\  x), ((e) => e)];
    , "x.ts");
    try std.testing.expectEqualStrings(
        \\
        \\import { Text as Typography, TEXT_VARIANTS } from "./Text.ptsx";
        \\
        \\import {
        \\  Unit
        \\
        \\
        \\} from "./unit";
        \\
        \\
        \\export const toggle = (event) => { state.open = !state.open; };
        \\function f($$p, x) { return $$p; }
        \\const y = f($$p, 1);
        \\const z = [$$p.a ?? 1, !!x, !((a ?? b) || c), () => ({ k: v }), (a, b), $$p.o.map(($$i) => $$i), (
        \\  x), ((e) => e)];
    , out);
}
