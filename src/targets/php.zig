//! PHP emitter for the public, validated scalar contract. No source reparsing.
const std = @import("std");
const portable = @import("../portable.zig");
const compiler = @import("../compiler.zig");
const util = @import("../util.zig");
const Error = portable.Error;
const Expr = compiler.ExpressionIR;
const Node = compiler.NodeIR;

pub fn emit(a: std.mem.Allocator, p: *const portable.Program, _: portable.Options) Error![]const u8 {
    var e = Emitter{ .a = a, .p = p, .out = .init(a) };
    const w = &e.out.writer;
    try w.writeAll(@embedFile("php/runtime.php"));
    try w.writeAll("\nnamespace {\nuse Publr\\Portable\\V1 as R;\nreturn static function(array $props): string {\n");
    for (p.module.component.props.keys()) |name| {
        const spec = p.module.component.props.get(name).?;
        const key = try e.quote(name);
        const kind = switch (spec.type) {
            .number, .optional_number => "number",
            .boolean, .optional_boolean => "boolean",
            else => "string",
        };
        try w.print("$props[{s}] = R::prop($props, {s}, '{s}', {s}, ", .{ key, key, kind, if (spec.optional or spec.type == .optional_number or spec.type == .optional_string or spec.type == .optional_boolean) @as([]const u8, "true") else "false" });
        if (spec.default) |v| {
            switch (v) {
                .number => |n| try e.number(n),
                .boolean => |b| try w.writeAll(if (b) "true" else "false"),
                .string => |s| try w.writeAll(try e.quote(s)),
            }
        } else try w.writeAll("R::undefined()");
        try w.writeAll(");\n");
    }
    for (p.module.component.locals, 0..) |local, i| {
        try w.print("$l{d} = ", .{i});
        if (local.value.* == .function and !p.types.contains(local.value.function.body)) try w.writeAll("null") else try e.expr(local.value);
        try w.writeAll(";\n");
    }
    if (p.server_extensions and p.module.component.root.* == .element and p.module.component.root.element.name == .intrinsic and util.eql(p.module.component.root.element.name.intrinsic.name, "html"))
        try w.writeAll("return '<!doctype html>' . R::child(")
    else
        try w.writeAll("return R::child(");
    try e.node(p.module.component.root);
    try w.writeAll(");\n};\n}\n");
    return e.out.written();
}

const Emitter = struct {
    a: std.mem.Allocator,
    p: *const portable.Program,
    out: std.Io.Writer.Allocating,
    parameters: std.ArrayList(struct { name: []const u8, code: []const u8 }) = .empty,
    counter: usize = 0,

    fn quote(e: *Emitter, s: []const u8) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(e.a);
        try out.writer.writeByte('\'');
        for (s) |byte| {
            if (byte == '\'' or byte == '\\') try out.writer.writeByte('\\');
            try out.writer.writeByte(byte);
        }
        try out.writer.writeByte('\'');
        return out.written();
    }
    fn number(e: *Emitter, n: f64) Error!void {
        try e.out.writer.print("R::fromBits('{x:0>16}')", .{@as(u64, @bitCast(n))});
    }
    fn expr(e: *Emitter, x: *const Expr) Error!void {
        const w = &e.out.writer;
        switch (x.*) {
            .literal => |v| switch (v) {
                .number => |n| try e.number(n),
                .string => |s| try w.writeAll(try e.quote(s)),
                .boolean => |b| try w.writeAll(if (b) "true" else "false"),
                .null => try w.writeAll("null"),
            },
            .absent => try w.writeAll("R::undefined()"),
            .reference => |r| {
                if (r.source == .prop) return w.print("$props[{s}]", .{try e.quote(r.name)});
                var at = e.parameters.items.len;
                while (at > 0) {
                    at -= 1;
                    const param = e.parameters.items[at];
                    if (util.eql(param.name, r.name)) return w.writeAll(param.code);
                }
                for (e.p.module.component.locals, 0..) |local, i| {
                    if (util.eql(local.name, r.name)) return w.print("$l{d}", .{i});
                }
                try w.writeAll(if (util.eql(r.name, "NaN")) "NAN" else "INF");
            },
            .member => try e.expr(e.p.stateInitial(x).?),
            .unary => |u| {
                try w.writeAll(if (util.eql(u.operator, "!")) "(!R::truthy(" else "(-(");
                try e.expr(u.argument);
                try w.writeAll("))");
            },
            .operation => |o| {
                const op = e.p.operations.get(x).?;
                const helper: ?[]const u8 = switch (op) {
                    .number_divide => "fdiv",
                    .number_remainder => "R::remainder",
                    .logical_and => "R::logicalAnd",
                    .logical_or => "R::logicalOr",
                    .nullish => "R::coalesce",
                    else => null,
                };
                if (helper) |name| {
                    try w.print("{s}(", .{name});
                    try e.expr(o.left);
                    try w.writeAll(", ");
                    if (op == .logical_and or op == .logical_or or op == .nullish) try w.writeAll("fn() => ");
                    try e.expr(o.right);
                } else {
                    try w.writeByte('(');
                    try e.expr(o.left);
                    const operator: []const u8 = switch (op) {
                        .number_add => "+",
                        .number_subtract => "-",
                        .number_multiply => "*",
                        .string_concat => ".",
                        .equal => "===",
                        .not_equal => "!==",
                        .number_less => "<",
                        .number_less_equal => "<=",
                        .number_greater => ">",
                        .number_greater_equal => ">=",
                        else => unreachable,
                    };
                    try w.print(" {s} ", .{operator});
                    try e.expr(o.right);
                }
                try w.writeByte(')');
            },
            .conditional => |c| {
                try w.writeAll("(R::truthy(");
                try e.expr(c.@"test");
                try w.writeAll(") ? ");
                try e.expr(c.consequent);
                try w.writeAll(" : ");
                try e.expr(c.alternate);
                try w.writeByte(')');
            },
            .template => |t| {
                try w.writeAll("(''");
                for (t.parts) |part| {
                    try w.writeAll(" . ");
                    switch (part) {
                        .string => |s| try w.writeAll(try e.quote(s)),
                        .expression => |v| {
                            try w.writeAll("R::text(");
                            try e.expr(v);
                            try w.writeByte(')');
                        },
                    }
                }
                try w.writeByte(')');
            },
            .function => |f| {
                const saved = e.parameters.items.len;
                defer e.parameters.shrinkRetainingCapacity(saved);
                try w.writeAll("static function(");
                for (f.parameters, 0..) |parameter, i| {
                    if (i != 0) try w.writeAll(", ");
                    e.counter += 1;
                    const name = try util.fmt(e.a, "$arg{d}", .{e.counter});
                    try e.parameters.append(e.a, .{ .name = parameter, .code = name });
                    try w.writeAll(name);
                }
                try w.writeAll(") use ($props");
                for (e.p.module.component.locals, 0..) |_, i| try w.print(", &$l{d}", .{i});
                try w.writeAll(") { return ");
                try e.expr(f.body);
                try w.writeAll("; }");
            },
            .call => |c| {
                if (c.callee.* == .reference) {
                    try e.expr(c.callee);
                    try w.writeByte('(');
                } else try w.writeAll(if (e.p.operations.get(x).? == .number_min) "R::minimum(" else "R::maximum(");
                for (c.arguments, 0..) |arg, i| {
                    if (i != 0) try w.writeAll(", ");
                    try e.expr(arg);
                }
                try w.writeByte(')');
            },
            .node => |n| try e.node(n.node),
            else => unreachable,
        }
    }
    fn children(e: *Emitter, nodes: []const *const Node) Error!void {
        try e.out.writer.writeByte('[');
        for (nodes, 0..) |child, i| {
            if (i != 0) try e.out.writer.writeAll(", ");
            try e.node(child);
        }
        try e.out.writer.writeByte(']');
    }
    fn hasState(e: *Emitter, x: *const Expr) bool {
        if (e.p.stateInitial(x) != null) return true;
        return switch (x.*) {
            .unary => |u| e.hasState(u.argument),
            .operation => |o| e.hasState(o.left) or e.hasState(o.right),
            .conditional => |c| e.hasState(c.@"test") or e.hasState(c.consequent) or e.hasState(c.alternate),
            .template => |t| blk: {
                for (t.parts) |part| if (part == .expression and e.hasState(part.expression)) break :blk true;
                break :blk false;
            },
            .function => |f| e.hasState(f.body),
            .call => |c| blk: {
                if (c.callee.* == .reference) {
                    for (e.p.module.component.locals) |local| {
                        if (util.eql(local.name, c.callee.reference.name) and local.value.* == .function and e.hasState(local.value)) break :blk true;
                    }
                }
                for (c.arguments) |arg| if (e.hasState(arg)) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }
    fn wire(e: *Emitter, x: *const Expr) Error!?[]const u8 {
        if (e.p.stateInitial(x) != null) return try util.fmt(e.a, "${s}", .{x.member.property.string});
        if (x.* == .unary and util.eql(x.unary.operator, "!")) {
            if (try e.wire(x.unary.argument)) |inner| return try util.fmt(e.a, "not {s}", .{inner});
        }
        if (e.hasState(x)) return @import("../err.zig").fail("pjsx: {s}: unsupported PHP state wire expression", .{e.p.module.filename});
        return null;
    }
    fn node(e: *Emitter, n: *const Node) Error!void {
        const w = &e.out.writer;
        switch (n.*) {
            .text => |t| try w.writeAll(try e.quote(t.value)),
            .expression => |x| {
                if (try e.wire(x.value)) |spec| {
                    try w.print("R::element('span', [['data-p-text', {s}]], [", .{try e.quote(spec)});
                    try e.expr(x.value);
                    try w.writeAll("])");
                } else try e.expr(x.value);
            },
            .fragment => |f| {
                try w.writeAll("R::fragment(");
                try e.children(f.children);
                try w.writeByte(')');
            },
            .element => |el| {
                if (el.name == .component) {
                    const file = e.p.componentFile(el.name.component.name).?;
                    const php_file = try util.fmt(e.a, "/{s}.php", .{std.fs.path.stem(std.fs.path.basename(file))});
                    try w.print("new \\Publr\\Portable\\Html((require __DIR__ . {s})([", .{try e.quote(php_file)});
                    for (el.attributes, 0..) |attr, i| {
                        if (i != 0) try w.writeAll(", ");
                        try w.print("{s} => ", .{try e.quote(attr.attribute.name)});
                        try e.expr(attr.value());
                    }
                    try w.writeAll("]))");
                    return;
                }
                try w.print("R::element({s}, [", .{try e.quote(el.name.intrinsic.name)});
                var bindings: std.Io.Writer.Allocating = .init(e.a);
                var events: std.Io.Writer.Allocating = .init(e.a);
                for (el.attributes) |attr| {
                    const name = attr.attribute.name;
                    if (e.p.server_extensions and std.mem.startsWith(u8, name, "on")) {
                        if (events.written().len != 0) try events.writer.writeByte(';');
                        try events.writer.print("click:{s}", .{attr.value().reference.name});
                        continue;
                    }
                    if (try e.wire(attr.value())) |spec| {
                        if (bindings.written().len != 0) try bindings.writer.writeByte(';');
                        try bindings.writer.print("{s}:{s}", .{ name, spec });
                    }
                    try w.print("[{s}, ", .{try e.quote(name)});
                    try e.expr(attr.attribute.value);
                    try w.writeAll("], ");
                }
                if (n == e.p.module.component.root) {
                    if (e.p.module.component.family) |family| try w.print("['data-p-store', {s}], ", .{try e.quote(family.store)});
                }
                if (bindings.written().len > 0) try w.print("['data-p-bind', {s}], ", .{try e.quote(bindings.written())});
                if (events.written().len > 0) try w.print("['data-p-on', {s}], ", .{try e.quote(events.written())});
                try w.writeAll("], ");
                try e.children(el.children);
                try w.writeByte(')');
            },
        }
    }
};
