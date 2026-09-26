//! HTML target: static templates plus companion store expressions/actions.
//! No DOM component import, node cursor, or DOM-shape replay is generated.
const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const util = @import("util.zig");
const err = @import("err.zig");
const A = std.mem.Allocator;
const S = []const u8;
const Node = ast.Node;
const Error = err.Error || std.Io.Writer.Error;

pub fn behavior(a: A, module: *const @import("compiler.zig").ModuleIR) Error!S {
    const canonical = try @import("canonicalize.zig").canonicalize(a, module.source);
    const source = try @import("intrinsics.zig").compile(a, canonical.code, module.filename, .{ .html = true });
    const program = try parser.parse(a, source, module.filename);
    var t = Transform{ .a = a, .source = source };
    const code = try t.emit(program);
    if (try @import("inline_html.zig").isStaticShell(a, module.source, module.filename))
        return @import("strip_types.zig").stripTypes(a, try std.fmt.allocPrint(a, "import * as $$html from \"publr/html\";\n{s}", .{code}), module.filename);
    const registration = try std.fmt.allocPrint(a, "import * as $$html from \"publr/html\";\n{s}\n$$html.register({s}, {s});\n", .{ code, try util.jsonString(a, try @import("compiled.zig").storeName(a, module)), module.component.name });
    return @import("strip_types.zig").stripTypes(a, registration, module.filename);
}
const Template = struct {
    markup: std.ArrayList(u8) = .empty,
    values: util.StringList = .empty,
    actions: util.StringList = .empty,
    slots: util.StringList = .empty,
    refs: util.StringList = .empty,
};
const Transform = struct {
    a: A,
    source: S,
    row_names: []const S = &.{},
    fn f(t: *Transform, comptime fmt: S, args: anytype) Error!S {
        return std.fmt.allocPrint(t.a, fmt, args);
    }
    fn q(t: *Transform, text: S) Error!S {
        return util.jsonString(t.a, text);
    }
    fn name(node: *Node) S {
        return if (node.type == .JSXNamespacedName) node.name_node.?.name else node.name;
    }
    fn emit(t: *Transform, node: *Node) Error!S {
        if (node.type == .Identifier) for (t.row_names) |row_name| {
            if (util.eql(node.name, row_name)) return t.f("{s}()", .{node.name});
        };
        if (node.type == .MemberExpression and !node.computed) return t.f("{s}{s}", .{ try t.emit(node.object.?), t.source[node.object.?.end..node.end] });
        if (node.type == .Property and !node.computed) {
            const v = node.value_node orelse return node.slice(t.source);
            if (node.shorthand) return t.f("{s}: {s}", .{ node.key.?.slice(t.source), try t.emit(v) });
            return t.f("{s}{s}", .{ t.source[node.start..v.start], try t.emit(v) });
        }
        if (node.type == .ImportDeclaration) {
            const spec = node.source.?.stringValue() orelse "";
            if (util.eql(spec, "publr/dom")) return t.f("{s}\"publr/html\"{s}", .{ t.source[node.start..node.source.?.start], t.source[node.source.?.end..node.end] });
            if (util.hasPjsxExtension(spec)) return t.f("{s}{s}{s}", .{ t.source[node.start..node.source.?.start], try t.q(try t.f("{s}.behavior.js", .{spec[0 .. spec.len - 5]})), t.source[node.source.?.end..node.end] });
        }
        if (node.type == .JSXElement or node.type == .JSXFragment) {
            var plan: Template = .{};
            try t.markup(node, &plan);
            return t.f("$$html.template({s}, {{{s}}}, {{{s}}}, [{s}], {{{s}}})", .{ try t.q(plan.markup.items), try util.join(t.a, plan.values.items, ","), try util.join(t.a, plan.actions.items, ","), try util.join(t.a, plan.slots.items, ","), try util.join(t.a, plan.refs.items, ",") });
        }
        if (node.type == .ConditionalExpression and (containsJSX(node.consequent.?) or containsJSX(node.alternate.?))) return t.f("$$html.when(() => ({s}), () => ({s}), () => ({s}))", .{ try t.emit(node.test_.?), try t.emit(node.consequent.?), try t.emit(node.alternate.?) });
        if (node.type == .LogicalExpression and util.eql(node.operator, "&&") and containsJSX(node.right.?)) return t.f("$$html.when(() => ({s}), () => ({s}))", .{ try t.emit(node.left.?), try t.emit(node.right.?) });
        // map callbacks receive live row/index readers, just like the DOM target.
        if (node.type == .CallExpression and node.callee.?.type == .MemberExpression and node.callee.?.property.?.isIdentifier("map") and node.arguments.len == 1 and containsJSX(node.arguments[0])) {
            const cb = node.arguments[0];
            if (!cb.isFunction() or cb.params.len == 0 or cb.params.len > 2) return err.failMsg("pjsx: HTML map requires a callback");
            const read = try t.emit(node.callee.?.object.?);
            const body = ast.unparen(cb.body.?);
            const jsx = if (body.type == .JSXElement) body else return err.failMsg("pjsx: HTML map requires an element callback body");
            var key_expr: ?*Node = null;
            for (jsx.opening_element.?.attributes) |attr| if (attr.type == .JSXAttribute and util.eql(name(attr.name_node.?), "key")) {
                key_expr = value(attr);
            };
            const key = try t.emit(key_expr orelse return err.failMsg("pjsx: HTML map requires an explicit key"));
            var params: util.StringList = .empty;
            for (cb.params) |param| {
                if (param.type != .Identifier) return err.failMsg("pjsx: HTML map parameters must be identifiers");
                try params.append(t.a, param.name);
            }
            const previous = t.row_names;
            defer t.row_names = previous;
            t.row_names = params.items;
            return t.f("$$html.map(() => ({s}), ({s}) => ({s}), ({s}) => ({s}))", .{ read, try util.join(t.a, params.items, ","), key, try util.join(t.a, params.items, ","), try t.emit(body) });
        }
        if (node.isFunction() and t.row_names.len > 0) {
            const previous = t.row_names;
            defer t.row_names = previous;
            var live: util.StringList = .empty;
            for (previous) |row_name| {
                var shadowed = false;
                for (node.params) |param| if (param.isIdentifier(row_name)) {
                    shadowed = true;
                };
                if (!shadowed) try live.append(t.a, row_name);
            }
            t.row_names = live.items;
            if (node.body) |body| return t.f("{s}{s}{s}", .{ t.source[node.start..body.start], try t.emit(body), t.source[body.end..node.end] });
        }
        return t.children(node);
    }
    fn containsJSX(node: *Node) bool {
        if (node.type == .JSXElement or node.type == .JSXFragment) return true;
        for (ast.childFields(node.type)) |field| {
            if (field[1]) {
                for (ast.getList(node, field[0])) |child| if (child) |c| {
                    if (containsJSX(c)) return true;
                };
            } else if (ast.getSingle(node, field[0])) |child| {
                if (containsJSX(child)) return true;
            }
        }
        return false;
    }
    fn add(t: *Transform, p: *Template, text: S) Error!void {
        try p.markup.appendSlice(t.a, text);
    }
    fn escaped(t: *Transform, text: S) Error!S {
        var out: std.ArrayList(u8) = .empty;
        for (text) |c| try out.appendSlice(t.a, switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => &.{c},
        });
        return out.toOwnedSlice(t.a);
    }
    fn site(node: *Node) S {
        if (node.type != .JSXElement) return "0";
        for (node.opening_element.?.attributes) |attr| if (attr.type == .JSXAttribute and util.eql(name(attr.name_node.?), "data-p-site")) return attr.value_node.?.stringValue() orelse "0";
        return "0";
    }
    fn value(attr: *Node) ?*Node {
        const v = attr.value_node orelse return null;
        return if (v.type == .JSXExpressionContainer) v.expression else v;
    }
    fn markup(t: *Transform, node: *Node, p: *Template) Error!void {
        if (node.type == .JSXFragment) {
            for (node.children) |child| try t.markup(child, p);
            return;
        }
        if (node.type == .JSXText) {
            try t.add(p, try t.escaped(try util.jsxText(t.a, node.slice(t.source))));
            return;
        }
        if (node.type == .JSXExpressionContainer) {
            const expression = node.expression orelse return;
            if (expression.type == .JSXEmptyExpression) return;
            const code = try t.emit(expression);
            try p.slots.append(t.a, code);
            // Intrinsic lowering gives every expression a source-stable slot identifier.
            const slot_id = if (expression.type == .CallExpression and expression.arguments.len > 0) expression.arguments[0].slice(t.source) else return err.failMsg("pjsx: HTML expression is missing its slot identity");
            try t.add(p, try t.f("<!--p:html:{s}--><!--/p:html:{s}-->", .{ slot_id, slot_id }));
            return;
        }
        if (node.type != .JSXElement) return err.failMsg("pjsx: unsupported HTML template node");
        const opening = node.opening_element.?;
        const tag = name(opening.name_node.?);
        const id = site(node);
        if (tag.len == 0) return err.failMsg("pjsx: HTML template needs a static element or imported component");
        if (std.ascii.isUpper(tag[0])) {
            var props: util.StringList = .empty;
            for (opening.attributes) |attr| {
                if (attr.type != .JSXAttribute) return err.failMsg("pjsx: HTML component spreads are unsupported");
                const key = name(attr.name_node.?);
                if (util.eql(key, "data-p-site")) continue;
                try props.append(t.a, try t.f("get {s}() {{ return {s}; }}", .{ try t.q(key), if (value(attr)) |v| try t.emit(v) else "true" }));
            }
            var child_plan: Template = .{};
            for (node.children) |child| try t.markup(child, &child_plan);
            if (util.eql(tag, "Loading")) {
                const child = try t.f("$$html.template({s}, {{{s}}}, {{{s}}}, [{s}], {{{s}}})", .{ try t.q(child_plan.markup.items), try util.join(t.a, child_plan.values.items, ","), try util.join(t.a, child_plan.actions.items, ","), try util.join(t.a, child_plan.slots.items, ","), try util.join(t.a, child_plan.refs.items, ",") });
                try p.slots.append(t.a, try t.f("$$html.slot({s}, () => $$html.Loading({{{s}}}, () => {s}))", .{ id, try util.join(t.a, props.items, ","), child }));
            } else try p.slots.append(t.a, try t.f("$$html.slot({s}, () => $$html.child({s}, {{{s}}}))", .{ id, tag, try util.join(t.a, props.items, ",") }));
            try t.add(p, try t.f("<!--p:html:{s}--><!--/p:html:{s}-->", .{ id, id }));
            return;
        }
        var text_slot: ?*Node = null;
        var meaningful: usize = 0;
        for (node.children) |child_node| {
            if (child_node.type == .JSXText and std.mem.trim(u8, child_node.slice(t.source), " \n\r\t").len == 0) continue;
            meaningful += 1;
            if (child_node.type == .JSXExpressionContainer and child_node.expression != null) {
                const exp = child_node.expression.?;
                if (exp.type == .CallExpression and exp.arguments.len == 2 and !containsJSX(exp.arguments[1])) text_slot = exp;
            }
        }
        if (meaningful != 1) text_slot = null;
        try t.add(p, try t.f("<{s}", .{tag}));
        if (text_slot) |part| {
            const binding = try t.f("v{s}", .{part.arguments[0].slice(t.source)});
            try t.add(p, try t.f(" data-p-text=\"${s}\"", .{binding}));
            try p.values.append(t.a, try t.f("{s}: {s}", .{ try t.q(binding), try t.emit(part.arguments[1]) }));
        }
        var classes: util.StringList = .empty;
        var class_literals: util.StringList = .empty;
        var dynamic_class = false;
        var events: util.StringList = .empty;
        var binds: util.StringList = .empty;
        var index: usize = 0;
        for (opening.attributes) |attr| {
            if (attr.type != .JSXAttribute) return err.failMsg("pjsx: HTML attribute spreads are unsupported");
            const key = name(attr.name_node.?);
            if (util.eql(key, "data-p-site")) continue;
            const current = index;
            index += 1;
            const v = value(attr);
            const code = if (v) |val| try t.emit(val) else "true";
            if (util.eql(key, "key")) {
                try p.values.append(t.a, try t.f("\"__key\": () => ({s})", .{code}));
                continue;
            }
            if (util.eql(key, "class")) {
                try classes.append(t.a, code);
                if (v != null and v.?.type == .Literal) {
                    if (v.?.stringValue()) |str| try class_literals.append(t.a, str);
                } else dynamic_class = true;
                continue;
            }
            const binding = try t.f("p{s}_{d}", .{ id, current });
            if (std.mem.startsWith(u8, key, "on") or std.mem.startsWith(u8, key, "$$on$")) {
                const event = if (std.mem.startsWith(u8, key, "$$on$")) try t.a.dupe(u8, key[5..]) else try t.a.dupe(u8, try util.eventDescriptor(t.a, key));
                for (event) |*c| if (c.* == '$') {
                    c.* = '.';
                };
                if (std.mem.startsWith(u8, key, "$$on$") and attr.value_node != null and attr.value_node.?.type == .Literal) {
                    try events.append(t.a, try t.f("{s}:{s}", .{ event, v.?.stringValue() orelse return err.failMsg("pjsx: HTML event action must be a string") }));
                    continue;
                }
                const action = if (v != null and v.?.type == .Identifier) v.?.name else binding;
                try events.append(t.a, try t.f("{s}:{s}", .{ event, action }));
                try p.actions.append(t.a, try t.f("{s}: (_dataset, {{event}}) => ({s})(event)", .{ try t.q(action), code }));
                continue;
            }
            if (util.eql(key, "ref")) {
                try t.add(p, try t.f(" data-p-ref=\"{s}\"", .{binding}));
                try p.refs.append(t.a, try t.f("{s}: {s}", .{ try t.q(binding), code }));
                continue;
            }
            const attribute = if (util.eql(key, "portal")) "data-p-portal" else if (util.eql(key, "anchor")) "data-p-anchor" else if (util.eql(key, "position")) "data-p-position" else key;
            if (v != null and v.?.type == .Literal) {
                if (v.?.value == .boolean) {
                    if (std.mem.startsWith(u8, attribute, "aria-")) try t.add(p, try t.f(" {s}=\"{s}\"", .{ attribute, if (v.?.value.boolean) "true" else "false" })) else if (v.?.value.boolean) try t.add(p, try t.f(" {s}", .{attribute}));
                } else try t.add(p, try t.f(" {s}=\"{s}\"", .{ attribute, try t.escaped(try @import("js.zig").Value.fromLiteral(v.?.value).toString(t.a)) }));
            } else if (v == null) try t.add(p, try t.f(" {s}", .{attribute})) else {
                if (util.eql(attribute, "data-p-portal") or util.eql(attribute, "data-p-position")) try t.add(p, try t.f(" {s}", .{attribute}));
                try binds.append(t.a, try t.f("{s}:${s}", .{ attribute, binding }));
                try p.values.append(t.a, try t.f("{s}: () => ({s})", .{ try t.q(binding), code }));
            }
        }
        if (classes.items.len > 0) {
            if (dynamic_class) {
                const binding = try t.f("p{s}_class", .{id});
                try binds.append(t.a, try t.f("class:${s}", .{binding}));
                try p.values.append(t.a, try t.f("{s}: () => $$html.className([{s}])", .{ try t.q(binding), try util.join(t.a, classes.items, ",") }));
            } else try t.add(p, try t.f(" class=\"{s}\"", .{try t.escaped(try util.join(t.a, class_literals.items, " "))}));
        }
        if (events.items.len > 0) try t.add(p, try t.f(" data-p-on=\"{s}\"", .{try t.escaped(try util.join(t.a, events.items, ";"))}));
        if (binds.items.len > 0) try t.add(p, try t.f(" data-p-bind=\"{s}\"", .{try t.escaped(try util.join(t.a, binds.items, ";"))}));
        try t.add(p, ">");
        if (text_slot == null) for (node.children) |child| try t.markup(child, p);
        for ([_]S{ "input", "img", "br", "hr", "meta", "link", "area", "base", "embed", "source", "track", "wbr", "col", "param" }) |void_tag| if (util.eql(tag, void_tag)) return;
        try t.add(p, try t.f("</{s}>", .{tag}));
    }
    fn children(t: *Transform, node: *Node) Error!S {
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
