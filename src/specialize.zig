//! Remove runtime prop/child classification from compiler-owned elements.
const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const util = @import("util.zig");
const err = @import("err.zig");
const A = std.mem.Allocator;
const S = []const u8;
const Node = ast.Node;
pub fn compile(a: A, source: S, filename: S, runtime: S) err.Error!S {
    const program = try parser.parse(a, source, filename);
    var transform = Transform{ .a = a, .source = source, .runtime = runtime };
    for (program.statements) |statement| {
        if (statement.type != .ImportDeclaration or !util.eql(statement.source.?.stringValue() orelse "", runtime)) continue;
        for (statement.specifiers) |spec| if (spec.type == .ImportNamespaceSpecifier) {
            transform.namespace = spec.local.?.name;
            break;
        };
        if (transform.namespace.len != 0) break;
    }
    return transform.emit(program);
}
const Transform = struct {
    a: A,
    source: S,
    runtime: S,
    namespace: S = "",
    svg_context: bool = false,
    fn emit(t: *Transform, node: *Node) err.Error!S {
        if (node.type == .ImportDeclaration) {
            const source = node.source.?;
            const spec = source.stringValue() orelse "";
            if (util.hasPjsxExtension(spec)) return std.fmt.allocPrint(t.a, "{s}{s}{s}", .{ t.source[node.start..source.start], try util.jsonString(t.a, try std.fmt.allocPrint(t.a, "{s}.js", .{spec[0 .. spec.len - 5]})), t.source[source.end..node.end] });
        }
        if (node.type == .CallExpression and node.callee.?.type == .MemberExpression) {
            const callee = node.callee.?;
            if (callee.object.?.isIdentifier(t.namespace) and callee.property.?.isIdentifier("h")) return t.element(node);
            if (callee.object.?.isIdentifier(t.namespace) and callee.property.?.isIdentifier("Fragment")) {
                var kids: util.StringList = .empty;
                if (node.arguments.len == 1 and node.arguments[0].type == .ObjectExpression) {
                    for (node.arguments[0].properties) |property| if (property.key.?.isIdentifier("children")) {
                        for (property.value_node.?.elements) |child| if (child) |value| {
                            const code = try t.emit(value);
                            try kids.append(t.a, if (value.type == .Literal) try t.format("literal({s})", .{code}) else if (value.isFunction()) try t.format("insert({s})", .{code}) else code);
                        };
                    };
                }
                return std.fmt.allocPrint(t.a, "{s}.fragment(() => [{s}])", .{ t.namespace, try util.join(t.a, kids.items, ",") });
            }
        }
        return t.children(node);
    }
    fn format(t: *Transform, comptime fmt: S, args: anytype) err.Error!S {
        const renamed = try std.fmt.allocPrint(t.a, fmt, args);
        inline for (.{ "element(", "append(", "literal(", "insert(", "classes(", "styles(", "reference(", "event(", "attr(", "attribute(", "enhance(" }) |prefix| {
            if (comptime std.mem.startsWith(u8, fmt, prefix)) return std.fmt.allocPrint(t.a, "{s}.{s}", .{ t.namespace, renamed });
        }
        return renamed;
    }
    fn element(t: *Transform, node: *Node) err.Error!S {
        if (node.arguments.len < 2 or node.arguments[0].type != .Literal) return err.failMsg("pjsx: compiler elements require a static tag");
        const tag = node.arguments[0].stringValue().?;
        const previous_svg = t.svg_context;
        const svg = previous_svg or util.eql(tag, "svg");
        t.svg_context = svg and !util.eql(tag, "foreignObject");
        defer t.svg_context = previous_svg;
        const element_name = try std.fmt.allocPrint(t.a, "{s}Element", .{t.namespace});
        var lines: util.StringList = .empty;
        var directives: util.StringList = .empty;
        const props = node.arguments[1];
        if (props.type == .ObjectExpression) for (props.properties) |prop| {
            const name = if (prop.key.?.type == .Identifier) prop.key.?.name else prop.key.?.stringValue().?;
            for ([_]S{ "position", "portal", "focus", "ref" }) |directive| {
                const full = try std.fmt.allocPrint(t.a, "data-p-{s}", .{directive});
                if (util.eql(name, full)) try directives.append(t.a, try util.jsonString(t.a, directive));
            }
            const value = prop.value_node.?;
            const expr = try t.emit(value);
            const key = try util.jsonString(t.a, name);
            const line = if (util.eql(name, "class"))
                try t.format("classes({s}, {s});", .{ element_name, if (value.isFunction()) expr else try t.format("() => ({s})", .{expr}) })
            else if (util.eql(name, "style") and value.type == .Literal and value.stringValue() != null)
                try t.format("attribute({s}, \"style\", {s});", .{ element_name, expr })
            else if (util.eql(name, "style"))
                try t.format("styles({s}, {s});", .{ element_name, if (value.isFunction()) expr else try t.format("() => ({s})", .{expr}) })
            else if (util.eql(name, "ref"))
                try t.format("reference({s}, {s});", .{ element_name, expr })
            else if (std.mem.startsWith(u8, name, "onWindow") and name.len > 8)
                try t.format("event({s}.ownerDocument.defaultView, {s}, {s});", .{ element_name, try util.jsonString(t.a, try std.ascii.allocLowerString(t.a, name[8..])), expr })
            else if (std.mem.startsWith(u8, name, "on") and name.len > 2)
                try t.format("event({s}, {s}, {s});", .{ element_name, try util.jsonString(t.a, try std.ascii.allocLowerString(t.a, name[2..])), expr })
            else if (value.isFunction())
                try t.format("attr({s}, {s}, {s});", .{ element_name, key, expr })
            else
                try t.format("attribute({s}, {s}, {s});", .{ element_name, key, expr });
            try lines.append(t.a, line);
        };
        for (node.arguments[2..]) |child| {
            const value = try t.emit(child);
            const child_code = if (child.type == .Literal)
                try t.format("literal({s})", .{value})
            else if (child.isFunction())
                try t.format("insert({s})", .{value})
            else
                value;
            try lines.append(t.a, try t.format("append({s}, {s});", .{ element_name, child_code }));
        }
        if (directives.items.len > 0) try lines.append(t.a, try t.format("enhance({s}, [{s}]);", .{ element_name, try util.join(t.a, directives.items, ",") }));
        return t.format("element({s}, {s} => {{ {s} }}{s})", .{ try util.jsonString(t.a, tag), element_name, try util.join(t.a, lines.items, " "), if (svg) ", \"http://www.w3.org/2000/svg\"" else "" });
    }
    fn children(t: *Transform, node: *Node) err.Error!S {
        var nodes: std.ArrayList(*Node) = .empty;
        for (ast.childFields(node.type)) |field| {
            if (field[1]) {
                for (ast.getList(node, field[0])) |child| if (child) |c| try nodes.append(t.a, c);
            } else if (ast.getSingle(node, field[0])) |child| try nodes.append(t.a, child);
        }
        std.mem.sort(*Node, nodes.items, {}, struct {
            fn less(_: void, l: *Node, r: *Node) bool {
                return l.start < r.start;
            }
        }.less);
        var out: std.ArrayList(u8) = .empty;
        var pos = node.start;
        for (nodes.items) |child| {
            if (child.start < pos) continue;
            try out.appendSlice(t.a, t.source[pos..child.start]);
            try out.appendSlice(t.a, try t.emit(child));
            pos = child.end;
        }
        try out.appendSlice(t.a, t.source[pos..node.end]);
        return out.toOwnedSlice(t.a);
    }
};
