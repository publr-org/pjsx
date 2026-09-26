//! Dialect transform (.ptsx/.pjsx) — the SECOND compile stage. Takes canonical
//! TSX (see canonicalize.zig), parses it, and replaces every JSX expression
//! with direct calls into the publr-dom runtime (h/Fragment/when/list/show/
//! component). Components stay ordinary functions that run ONCE; every dynamic
//! expression site becomes a thunk whose effect the runtime owns. No static
//! dependency analysis happens here — publr's proxy tracking resolves
//! dependencies at runtime, which is what keeps this transform mechanical.
//!
//! Sugar handled here, per the dialect spec:
//! - auto-thunking: any non-literal attr value / child expression → () => (…)
//! - {cond && <X/>} and ternaries with JSX branches → when()
//! - {xs.map((x) => <li>…)} (+ key/:key) → keyed list(), lazy per-row build
//! - $$show/$$for/$$key/$$class/$$text (canonical spellings of the dialect
//!   directives) → when()/show()/list()/class merge/text child
//! - $$on$event$mods → wrapped listeners (prevent/stop/key filters)
//! - live props: component call sites pass getters. Reading props.x remains
//!   live; destructuring is a normal JavaScript snapshot, with defaults
//!   evaluated once and only for undefined.
//!
//! Source maps: the reference returns a MagicString hires map. This port
//! returns `map = null`; the CMS consumes the code only, and a faithful
//! MagicString-compatible map is deliberately out of scope for now.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Node = ast.Node;
const parser = @import("parser.zig");
const err = @import("err.zig");
const util = @import("util.zig");

pub const Error = err.Error;

pub const Options = struct {
    /// Module specifier the emitted import points at. Default "publr/dom".
    runtime_import: ?[]const u8 = null,
    /// Omit the runtime import line (embedding/tests).
    bare: bool = false,
    filename: ?[]const u8 = null,
    resolver: ?@import("types.zig").Resolver = null,
};

pub const Result = struct {
    code: []const u8,
    /// Source map v3 JSON, or null (see module doc).
    map: ?[]const u8,
};

const Str = []const u8;
const StrList = std.ArrayList(Str);
const NodeList = std.ArrayList(*Node);
const Edit = struct { start: u32, end: u32, text: Str };
const Range = [2]u32;

const key_names = [_][2]Str{
    .{ "enter", "Enter" },         .{ "escape", "Escape" }, .{ "esc", "Escape" },     .{ "space", " " },
    .{ "tab", "Tab" },             .{ "up", "ArrowUp" },    .{ "down", "ArrowDown" }, .{ "left", "ArrowLeft" },
    .{ "right", "ArrowRight" },    .{ "home", "Home" },     .{ "end", "End" },        .{ "delete", "Delete" },
    .{ "backspace", "Backspace" },
};

fn keyName(mod: Str) ?Str {
    for (key_names) |entry| if (util.eql(entry[0], mod)) return entry[1];
    return null;
}

fn childNodes(a: Allocator, node: *Node) Allocator.Error![]*Node {
    var list: NodeList = .empty;
    for (ast.childFields(node.type)) |cf| {
        if (cf[1]) {
            for (ast.getList(node, cf[0])) |child| if (child) |c| try list.append(a, c);
        } else if (ast.getSingle(node, cf[0])) |child| try list.append(a, child);
    }
    return list.toOwnedSlice(a);
}

fn isJsxPredicate(_: void, node: *Node) bool {
    return node.isJsx();
}

fn hasJsx(node: *Node) bool {
    return ast.contains(node, {}, isJsxPredicate);
}

fn isFnNode(node: *Node) bool {
    return node.isFunction();
}

fn lessEdit(_: void, a: Edit, b: Edit) bool {
    return a.start < b.start;
}

fn lessNode(_: void, a: *Node, b: *Node) bool {
    return a.start < b.start;
}

const ForInfo = struct { binder: Str, src: Str };
const Layer = struct { static: bool, text: Str };
const Emitted = struct { code: Str, key: ?Str };

pub fn transformPjsx(allocator: Allocator, source: []const u8, opts: Options) Error!Result {
    const filename = opts.filename orelse "component.ptsx";
    const program = parser.parse(allocator, source, filename) catch |e| switch (e) {
        error.Pjsx => {
            const message = try allocator.dupe(u8, err.message());
            return err.fail("pjsx: parse error in {s}: {s}", .{ filename, message });
        },
        else => return e,
    };
    var t = Transformer{
        .a = allocator,
        .source = source,
        .resolver = opts.resolver,
        .filename = filename,
        .program = program,
        .used = util.StringSet.init(allocator),
    };
    var symbol_index: usize = 0;
    while (std.mem.indexOf(u8, source, t.runtime_name) != null) : (symbol_index += 1)
        t.runtime_name = try std.fmt.allocPrint(allocator, "$$dom{d}", .{symbol_index});
    return t.run(opts);
}

const Transformer = struct {
    a: Allocator,
    source: Str,
    runtime_name: Str = "$$dom",
    resolver: ?@import("types.zig").Resolver,
    filename: Str,
    program: *Node,
    used: util.StringSet,
    ident_edits: std.ArrayList(Edit) = .empty,
    remove_ranges: std.ArrayList(Range) = .empty,
    root_fragments: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn f(self: *Transformer, comptime fmt: Str, args: anytype) Error!Str {
        const result = try util.fmt(self.a, fmt, args);
        inline for (.{ "h(", "component(", "when(", "list(", "show(", "Fragment(" }) |prefix| {
            if (comptime std.mem.startsWith(u8, fmt, prefix)) return std.fmt.allocPrint(self.a, "{s}.{s}", .{ self.runtime_name, result });
        }
        return result;
    }

    fn json(self: *Transformer, value: Str) Error!Str {
        return util.jsonString(self.a, value);
    }

    fn errAt(comptime msg: Str, node: *Node) Error {
        return err.fail("pjsx: " ++ msg ++ " (at offset {d})", .{node.start});
    }

    fn errAtFmt(comptime msg: Str, args: anytype, node: *Node) Error {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, msg, args) catch buf[0..];
        return err.fail("pjsx: {s} (at offset {d})", .{ text, node.start });
    }

    fn src(self: *Transformer, start: u32, end: u32) Str {
        return self.source[start..end];
    }

    // Lexical reads in generated list callbacks and named props.

    fn collectPatternNames(pattern: *Node, into: *util.StringSet) Error!void {
        switch (pattern.type) {
            .Identifier => try into.put(pattern.name, {}),
            .ObjectPattern => for (pattern.properties) |p| {
                try collectPatternNames(if (p.type == .RestElement) p.argument.? else p.value_node.?, into);
            },
            .ArrayPattern => for (pattern.elements) |el| {
                if (el) |e| try collectPatternNames(e, into);
            },
            .AssignmentPattern => try collectPatternNames(pattern.left.?, into),
            .RestElement => try collectPatternNames(pattern.argument.?, into),
            else => {},
        }
    }

    fn collectStatementDecls(stmt: *Node, into: *util.StringSet) Error!void {
        if (stmt.type == .VariableDeclaration) {
            for (stmt.declarations) |d| try collectPatternNames(d.id.?, into);
        } else if ((stmt.type == .FunctionDeclaration or stmt.type == .ClassDeclaration) and stmt.id != null) {
            try into.put(stmt.id.?.name, {});
        }
    }

    fn rewriteBody(self: *Transformer, body: *Node, prop_map: *const util.OrderedMap(Str)) Error!void {
        var shadow = util.StringSet.init(self.a);
        try self.rewriteWalk(body, &shadow, prop_map);
    }

    fn rewriteWalk(self: *Transformer, node: *Node, shadow: *util.StringSet, prop_map: *const util.OrderedMap(Str)) Error!void {
        const t = node.type;
        if (t.isTs()) {
            if (t == .TSAsExpression or t == .TSNonNullExpression or t == .TSSatisfiesExpression) {
                try self.rewriteWalk(node.expression.?, shadow, prop_map);
            }
            return;
        }
        if (isFnNode(node)) {
            var inner = try shadow.clone();
            for (node.params) |p| try collectPatternNames(p, &inner);
            if (node.id) |id| try inner.put(id.name, {});
            if (node.body) |body| try self.rewriteWalk(body, &inner, prop_map);
            return;
        }
        if (t == .BlockStatement) {
            var inner = try shadow.clone();
            for (node.statements) |st| try collectStatementDecls(st, &inner);
            for (node.statements) |st| try self.rewriteWalk(st, &inner, prop_map);
            return;
        }
        if (t == .VariableDeclarator) {
            if (node.init) |init| try self.rewriteWalk(init, shadow, prop_map);
            return;
        }
        if (t == .Property and !node.computed) {
            const value = node.value_node.?;
            if (node.shorthand and value.type == .Identifier and !shadow.has(value.name) and prop_map.has(value.name)) {
                try self.ident_edits.append(self.a, .{
                    .start = value.start,
                    .end = value.end,
                    .text = try self.f("{s}: {s}", .{ value.name, prop_map.get(value.name).? }),
                });
                return;
            }
            try self.rewriteWalk(value, shadow, prop_map);
            return;
        }
        if (t == .MemberExpression and !node.computed) {
            try self.rewriteWalk(node.object.?, shadow, prop_map);
            return;
        }
        if (t == .JSXAttribute) {
            if (node.value_node) |value| try self.rewriteWalk(value, shadow, prop_map);
            return;
        }
        if (t == .JSXIdentifier or t == .JSXMemberExpression) return;
        if (t == .Identifier) {
            if (!shadow.has(node.name)) if (prop_map.get(node.name)) |text| {
                try self.ident_edits.append(self.a, .{ .start = node.start, .end = node.end, .text = text });
            };
            return;
        }
        for (try childNodes(self.a, node)) |child| try self.rewriteWalk(child, shadow, prop_map);
    }

    fn rewriteComponentProps(self: *Transformer, fn_node: *Node, prop_alias: Str) Error!void {
        const parameter = fn_node.params[0];
        const pattern = if (parameter.type == .AssignmentPattern) parameter.left.? else parameter;
        var prop_map = util.OrderedMap(Str).init(self.a);
        const fallback: Str = if (parameter.type == .AssignmentPattern)
            try self.f(" = {s}", .{self.src(parameter.right.?.start, parameter.right.?.end)})
        else
            "";
        const ta: Str = if (pattern.type_annotation) |ta| self.src(ta.start, ta.end) else "";

        if (pattern.type == .Identifier) {
            try self.ident_edits.append(self.a, .{ .start = parameter.start, .end = parameter.end, .text = try util.concat(self.a, &.{ prop_alias, ta, fallback }) });
            try prop_map.put(pattern.name, prop_alias);
            try self.rewriteBody(fn_node.body.?, &prop_map);
            return;
        }
    }

    fn findComponents(self: *Transformer, node: *Node, component_depth: usize) Error!void {
        if (isFnNode(node) and node.id != null and node.id.?.name.len > 0) {
            if (node.body) |body| try self.findRootFragments(body);
        }
        if (node.type == .VariableDeclarator and node.id != null and node.id.?.type == .Identifier and node.id.?.name.len > 0) {
            if (node.init) |init| if (isFnNode(init)) {
                if (init.body) |body| try self.findRootFragments(body);
            };
        }
        var child_depth = component_depth;
        if (isFnNode(node) and node.params.len == 1 and node.body != null and hasJsx(node.body.?)) {
            try @import("types.zig").annotateGuards(self.a, self.program, self.source, self.filename, node, self.resolver);
            const parameter = node.params[0];
            const pattern = if (parameter.type == .AssignmentPattern) parameter.left.? else parameter;
            // Destructuring is ordinary JavaScript: snapshot each property and
            // evaluate defaults once, only for undefined, in binding order.
            if (pattern.type == .Identifier) {
                var alias: Str = if (component_depth == 0) "$$p" else try self.f("$$p{d}", .{component_depth});
                if (std.mem.indexOf(u8, self.source, alias) != null) alias = try self.f("{s}Props{d}", .{ self.runtime_name, component_depth });
                try self.rewriteComponentProps(node, alias);
                child_depth += 1;
            }
        }
        for (try childNodes(self.a, node)) |child| try self.findComponents(child, child_depth);
    }

    fn findRootFragments(self: *Transformer, node: *Node) Error!void {
        const root = ast.unparen(if (node.type == .ReturnStatement) node.argument orelse return else node);
        if (root.type == .JSXFragment) {
            try self.root_fragments.put(self.a, root.start, {});
            return;
        }
        // Only direct return values, not nested JSX, variables or callbacks.
        if (node.type != .BlockStatement and node.type != .IfStatement and node.type != .SwitchStatement and node.type != .SwitchCase) return;
        for (try childNodes(self.a, node)) |child| try self.findRootFragments(child);
    }

    // ── Source slicing with ident edits applied ───────────────────────────

    fn slice(self: *Transformer, start: u32, end: u32) Error!Str {
        var out: std.ArrayList(u8) = .empty;
        var pos = start;
        for (self.ident_edits.items) |edit| {
            if (edit.start >= start and edit.end <= end) {
                try out.appendSlice(self.a, self.src(pos, edit.start));
                try out.appendSlice(self.a, edit.text);
                pos = edit.end;
            }
        }
        try out.appendSlice(self.a, self.src(pos, end));
        return out.toOwnedSlice(self.a);
    }

    fn findInnerJsx(self: *Transformer, node: *Node, root: *Node, into: *NodeList) Error!void {
        if (node != root and node.isJsx()) {
            try into.append(self.a, node);
            return;
        }
        for (try childNodes(self.a, node)) |child| try self.findInnerJsx(child, root, into);
    }

    /// Expression text with ident edits applied and nested JSX compiled.
    fn textFor(self: *Transformer, node: *Node) Error!Str {
        if (node.isJsx()) return (try self.emitJsx(node)).code;
        var inner: NodeList = .empty;
        try self.findInnerJsx(node, node, &inner);
        std.mem.sort(*Node, inner.items, {}, lessNode);
        var out: std.ArrayList(u8) = .empty;
        var pos = node.start;
        for (inner.items) |j| {
            try out.appendSlice(self.a, try self.slice(pos, j.start));
            try out.appendSlice(self.a, (try self.emitJsx(j)).code);
            pos = j.end;
        }
        try out.appendSlice(self.a, try self.slice(pos, node.end));
        return out.toOwnedSlice(self.a);
    }

    // ── Emission ──────────────────────────────────────────────────────────

    fn isStaticLiteral(e: *Node) bool {
        return e.type == .Literal or (e.type == .TemplateLiteral and e.expressions.len == 0);
    }

    fn branch(self: *Transformer, n: *Node) Error!Str {
        const inner = ast.unparen(n);
        if (inner.isJsx()) return (try self.emitJsx(inner)).code;
        return try self.f("({s})", .{try self.textFor(inner)});
    }

    const MapMatch = struct { target: *Node, arrow: *Node, row: *Node };

    fn matchMap(e: *Node) ?MapMatch {
        if (e.type != .CallExpression) return null;
        const callee = e.callee.?;
        if (callee.type != .MemberExpression or callee.computed or !util.eql(callee.property.?.name, "map") or e.arguments.len != 1) return null;
        const arrow = ast.unparen(e.arguments[0]);
        if (arrow.type != .ArrowFunctionExpression) return null;
        const body = arrow.body.?;
        if (body.type != .BlockStatement) {
            const row = ast.unparen(body);
            if (row.isJsx()) return .{ .target = callee.object.?, .arrow = arrow, .row = row };
            return null;
        }
        // A block body whose last statement returns the row: the statements
        // before it run once per row, inside the list callback.
        if (body.statements.len == 0) return null;
        const last = body.statements[body.statements.len - 1];
        if (last.type != .ReturnStatement or last.argument == null) return null;
        const row = ast.unparen(last.argument.?);
        if (row.isJsx()) return .{ .target = callee.object.?, .arrow = arrow, .row = row };
        return null;
    }

    fn emitList(self: *Transformer, target: *Node, params: []*Node, row: *Node, block: ?*Node) Error!Str {
        try self.used.put("list", {});
        const item_p: Str = if (params.len > 0) try self.slice(params[0].start, params[0].end) else "$it";
        const idx_p: Str = if (params.len > 1) try self.slice(params[1].start, params[1].end) else "$i";
        const key_expr = (try self.emitJsx(row)).key orelse idx_p;
        const previous_edits = try self.a.dupe(Edit, self.ident_edits.items);
        defer {
            self.ident_edits.clearRetainingCapacity();
            self.ident_edits.appendSlice(self.a, previous_edits) catch {};
        }
        var readers = util.OrderedMap(Str).init(self.a);
        for (params, 0..) |parameter, parameter_index| {
            if (parameter.type != .Identifier) return errAt("list callbacks require identifier parameters", parameter);
            try readers.put(parameter.name, try self.f("{s}()", .{if (parameter_index == 0) item_p else idx_p}));
        }
        self.ident_edits.clearRetainingCapacity();
        try self.rewriteBody(block orelse row, &readers);
        const reader_edits = try self.a.dupe(Edit, self.ident_edits.items);
        outer: for (previous_edits) |old| {
            for (reader_edits) |reader| if (reader.start == old.start and reader.end == old.end) continue :outer;
            try self.ident_edits.append(self.a, old);
        }
        std.mem.sort(Edit, self.ident_edits.items, {}, lessEdit);
        const emitted = try self.emitJsx(row);
        if (block) |b| {
            var prelude: std.ArrayList(u8) = .empty;
            for (b.statements[0 .. b.statements.len - 1]) |statement| {
                try prelude.appendSlice(self.a, try self.textFor(statement));
                try prelude.appendSlice(self.a, " ");
            }
            return try self.f("list(() => ({s}), ({s}, {s}) => ({s}), ({s}, {s}) => {{ {s}return {s}; }})", .{ try self.textFor(target), item_p, idx_p, key_expr, item_p, idx_p, prelude.items, emitted.code });
        }
        return try self.f("list(() => ({s}), ({s}, {s}) => ({s}), ({s}, {s}) => {s})", .{ try self.textFor(target), item_p, idx_p, key_expr, item_p, idx_p, emitted.code });
    }

    fn emitChildExpr(self: *Transformer, raw: *Node) Error!Str {
        const e = ast.unparen(raw);
        if (e.type == .CallExpression and e.callee.?.type == .MemberExpression) {
            const callee = e.callee.?;
            if (callee.object.?.type == .Identifier) {
                for (self.program.statements) |statement| {
                    if (statement.type != .ImportDeclaration or !util.eql(statement.source.?.stringValue() orelse "", "publr/dom")) continue;
                    for (statement.specifiers) |spec| if (spec.type == .ImportNamespaceSpecifier and util.eql(spec.local.?.name, callee.object.?.name)) {
                        for ([_]Str{ "when", "choose", "forEach", "repeat" }) |method| if (callee.property.?.isIdentifier(method)) return self.textFor(e);
                    };
                }
            }
        }
        if (e.type == .Literal and (e.value == .string or e.value == .number)) {
            return if (e.raw.len > 0) e.raw else try self.literalJson(e);
        }
        if (e.isJsx()) return (try self.emitJsx(e)).code;
        if (e.type == .LogicalExpression and util.eql(e.operator, "&&") and hasJsx(e.right.?)) {
            try self.used.put("when", {});
            const left = try self.textFor(e.left.?);
            const test_code = switch (e.pjsx_guard) {
                .truthy => left,
                .boolean => try self.f("({s}) === true", .{left}),
                .presence => try self.f("({s}) != null", .{left}),
            };
            return try self.f("when(() => ({s}), () => {s})", .{ test_code, try self.branch(e.right.?) });
        }
        if (e.type == .ConditionalExpression and (hasJsx(e.consequent.?) or hasJsx(e.alternate.?))) {
            try self.used.put("when", {});
            return try self.f("when(() => ({s}), () => {s}, () => {s})", .{ try self.textFor(e.test_.?), try self.branch(e.consequent.?), try self.branch(e.alternate.?) });
        }
        if (matchMap(e)) |map| return try self.emitList(map.target, map.arrow.params, map.row, if (map.arrow.body.?.type == .BlockStatement) map.arrow.body else null);
        return try self.f("() => ({s})", .{try self.textFor(e)});
    }

    fn literalJson(self: *Transformer, e: *Node) Error!Str {
        return switch (e.value) {
            .string => |s| try self.json(s),
            .number => |n| try util.numberToString(self.a, n),
            else => e.raw,
        };
    }

    fn emitChildren(self: *Transformer, children: []*Node) Error![]Str {
        var out: StrList = .empty;
        for (children) |child| {
            if (child.type == .JSXText) {
                const t = try util.jsxText(self.a, child.value.asString() orelse "");
                if (t.len > 0) try out.append(self.a, try self.json(t));
            } else if (child.isJsx()) {
                try out.append(self.a, (try self.emitJsx(child)).code);
            } else if (child.type == .JSXExpressionContainer) {
                if (child.expression) |expression| if (expression.type != .JSXEmptyExpression) {
                    try out.append(self.a, try self.emitChildExpr(expression));
                };
            } else {
                return errAtFmt("unsupported JSX child {s}", .{child.type.name()}, child);
            }
        }
        return out.toOwnedSlice(self.a);
    }

    fn isRenderable(self: *Transformer, child: *Node) Error!bool {
        if (child.type == .JSXText) return (try util.jsxText(self.a, child.value.asString() orelse "")).len > 0;
        if (child.type == .JSXExpressionContainer) {
            const expression = child.expression orelse return false;
            return expression.type != .JSXEmptyExpression;
        }
        return true;
    }

    fn renderableChildren(self: *Transformer, children: []*Node) Error![]*Node {
        var out: NodeList = .empty;
        for (children) |child| if (try self.isRenderable(child)) try out.append(self.a, child);
        return out.toOwnedSlice(self.a);
    }

    fn emitSingleComponentChild(self: *Transformer, children: []*Node) Error!?Str {
        const rendered = try self.renderableChildren(children);
        if (rendered.len != 1) return null;
        const child = rendered[0];
        if (child.type != .JSXExpressionContainer) return null;
        const raw = child.expression orelse return null;
        const expression = ast.unparen(raw);
        if (expression.isJsx()) return null;
        if (expression.type == .LogicalExpression and util.eql(expression.operator, "&&") and hasJsx(expression.right.?)) return null;
        if (expression.type == .ConditionalExpression and (hasJsx(expression.consequent.?) or hasJsx(expression.alternate.?))) return null;
        if (matchMap(expression) != null) return null;
        return try self.f("({s})", .{try self.textFor(expression)});
    }

    fn jsxElementName(node: *Node) ?Str {
        if (node.type != .JSXElement) return null;
        const name = node.opening_element.?.name_node.?;
        return if (name.type == .JSXIdentifier) name.name else null;
    }

    fn findAttribute(node: *Node, name: Str) ?*Node {
        for (node.opening_element.?.attributes) |attribute| {
            if (attribute.type == .JSXAttribute and attribute.name_node.?.type == .JSXIdentifier and util.eql(attribute.name_node.?.name, name)) return attribute;
        }
        return null;
    }

    const OptionParts = struct { label: Str, value: Str };

    fn optionParts(self: *Transformer, option: *Node, expected_name: Str) Error!?OptionParts {
        const name = jsxElementName(option) orelse return null;
        if (!util.eql(name, expected_name)) return null;
        const value_attribute = findAttribute(option, "value") orelse return null;
        const attr_value = value_attribute.value_node orelse return null;
        const value: ?Str = if (attr_value.type == .Literal)
            try self.slice(attr_value.start, attr_value.end)
        else if (attr_value.type == .JSXExpressionContainer)
            try self.textFor(ast.unparen(attr_value.expression.?))
        else
            null;
        const label_children = try self.renderableChildren(option.children);
        if (value == null or label_children.len != 1) return null;
        const label_child = label_children[0];
        const label: ?Str = if (label_child.type == .JSXText)
            try self.json(try util.jsxText(self.a, label_child.value.asString() orelse ""))
        else if (label_child.type == .JSXExpressionContainer and label_child.expression != null)
            try self.textFor(ast.unparen(label_child.expression.?))
        else
            null;
        if (label == null) return null;
        return .{ .label = label.?, .value = value.? };
    }

    fn emitOptionEntries(self: *Transformer, option_name: Str, children: []*Node) Error!?Str {
        const entries = try self.renderableChildren(children);
        if (entries.len == 1 and entries[0].type == .JSXExpressionContainer) {
            const expression = if (entries[0].expression) |e| ast.unparen(e) else null;
            const map = if (expression) |e| matchMap(e) else null;
            const parts = if (map) |m| try self.optionParts(m.row, option_name) else null;
            if (map == null or parts == null) return null;
            var parameters: StrList = .empty;
            for (map.?.arrow.params) |parameter| try parameters.append(self.a, try self.slice(parameter.start, parameter.end));
            return try self.f("({s}).map(({s}) => ({{ label: {s}, value: {s} }}))", .{ try self.textFor(map.?.target), try util.join(self.a, parameters.items, ", "), parts.?.label, parts.?.value });
        }
        var options: StrList = .empty;
        for (entries) |entry| {
            const option = (try self.optionParts(entry, option_name)) orelse return null;
            try options.append(self.a, try self.f("{{ label: {s}, value: {s} }}", .{ option.label, option.value }));
        }
        return try self.f("[{s}]", .{try util.join(self.a, options.items, ", ")});
    }

    fn emitOptionCollection(self: *Transformer, parent_name: Str, children: []*Node) Error!?Str {
        const outer_children = try self.renderableChildren(children);
        if (outer_children.len != 1) return null;
        const wrapper = outer_children[0];
        const wrapper_name = jsxElementName(wrapper) orelse return null;
        if (!util.eql(wrapper_name, try self.f("{s}Options", .{parent_name}))) return null;
        return try self.emitOptionEntries(try self.f("{s}Option", .{parent_name}), wrapper.children);
    }

    fn eventEntry(self: *Transformer, name: Str, handler: Str, node: *Node) Error!Str {
        var parts = std.mem.splitScalar(u8, name[5..], '$');
        const event = parts.next() orelse "";
        const prop = try self.f("on{s}{s}", .{ try util.upperFirst(self.a, event[0..@min(1, event.len)]), if (event.len > 0) event[1..] else "" });
        var body: StrList = .empty;
        var has_mods = false;
        while (parts.next()) |mod| {
            has_mods = true;
            if (util.eql(mod, "prevent")) {
                try body.append(self.a, "$e.preventDefault();");
            } else if (util.eql(mod, "stop")) {
                try body.append(self.a, "$e.stopPropagation();");
            } else if (keyName(mod)) |key| {
                try body.insert(self.a, 0, try self.f("if ($e.key !== {s}) return;", .{try self.json(key)}));
            } else {
                return errAtFmt("unsupported event modifier .{s}", .{mod}, node);
            }
        }
        if (!has_mods) return try self.f("{s}: ({s})", .{ prop, handler });
        return try self.f("{s}: ($e) => {{ {s} ({s})($e); }}", .{ prop, try util.join(self.a, body.items, " "), handler });
    }

    fn propKey(self: *Transformer, name: Str) Error!Str {
        return if (util.isIdentifierName(name)) name else try self.json(name);
    }

    fn isNullishExpression(expression: *Node) bool {
        return (expression.type == .Literal and expression.value.isNullish()) or (expression.type == .Identifier and util.eql(expression.name, "undefined"));
    }

    fn mergedAttributeExpression(self: *Transformer, attributes: []*Node) Error!Str {
        var current: ?Str = null;
        for (attributes) |attribute| {
            const value = attribute.value_node orelse {
                current = "true";
                continue;
            };
            if (value.type == .Literal) {
                if (!value.value.isNullish()) current = try self.slice(value.start, value.end);
                continue;
            }
            if (value.type != .JSXExpressionContainer) return errAt("unsupported duplicate attribute value", attribute);
            const expression = ast.unparen(value.expression.?);
            if (isNullishExpression(expression)) continue;
            const next = try self.textFor(expression);
            const definitely_defined = isStaticLiteral(expression) and !(expression.type == .Literal and expression.value.isNullish());
            current = if (current == null or definitely_defined) next else try self.f("(($$v) => $$v == null ? ({s}) : $$v)({s})", .{ current.?, next });
        }
        return current orelse "undefined";
    }

    fn emitJsx(self: *Transformer, node: *Node) Error!Emitted {
        if (node.type == .JSXFragment) {
            const kids = try self.emitChildren(node.children);
            if (self.root_fragments.contains(node.start)) {
                try self.used.put("h", {});
                return .{ .code = try self.f("h(\"p-fragment\", {{ style: \"display:contents\" }}{s})", .{if (kids.len > 0) try self.f(", {s}", .{try util.join(self.a, kids, ", ")}) else ""}), .key = null };
            }
            try self.used.put("Fragment", {});
            const code = if (kids.len > 0) try self.f("Fragment({{ children: [{s}] }})", .{try util.join(self.a, kids, ", ")}) else try self.f("Fragment({{}})", .{});
            return .{ .code = code, .key = null };
        }

        const opening = node.opening_element.?;
        const tag = opening.name_node.?;
        const intrinsic = tag.type == .JSXIdentifier and util.startsWithLower(tag.name);
        const tag_text = try self.slice(tag.start, tag.end);
        const option_collection: ?Str = if (intrinsic) null else try self.emitOptionCollection(tag_text, node.children);
        const is_slot = util.eql(tag_text, "Slot");

        var show_expr: ?Str = null;
        var for_info: ?ForInfo = null;
        var key_expr: ?Str = null;
        var text_expr: ?Str = null;
        var class_layers: std.ArrayList(Layer) = .empty;
        var entries: StrList = .empty;
        var component_entries: StrList = .empty;
        var literal_event_wires: StrList = .empty;
        var literal_bind_wires: StrList = .empty;
        const target: *StrList = if (intrinsic) &entries else &component_entries;

        var duplicate_attributes = util.OrderedMap(*NodeList).init(self.a);
        var emitted_duplicates = util.StringSet.init(self.a);
        for (opening.attributes) |attribute| {
            if (attribute.type != .JSXAttribute or attribute.name_node.?.type != .JSXIdentifier) continue;
            const name = attribute.name_node.?.name;
            if (util.eql(name, "class") or std.mem.startsWith(u8, name, "$$")) continue;
            const group = duplicate_attributes.get(name) orelse blk: {
                const list = try self.a.create(NodeList);
                list.* = .empty;
                try duplicate_attributes.put(name, list);
                break :blk list;
            };
            try group.append(self.a, attribute);
        }

        for (opening.attributes) |attr| {
            if (attr.type == .JSXSpreadAttribute) return errAt("spread props are not supported yet", attr);
            const name_node = attr.name_node.?;
            var name: Str = if (name_node.type == .JSXNamespacedName)
                try self.f("{s}:{s}", .{ name_node.namespace.?.name, name_node.name_node.?.name })
            else
                name_node.name;
            const value = attr.value_node;
            // Universal structural props route through the directive handlers on
            // intrinsic elements and Slot: anchor/portal (bare), position={...}.
            if (intrinsic or is_slot) {
                if (util.eql(name, "anchor") and value == null) name = "$$anchor" else if (util.eql(name, "portal")) name = "$$portal" else if (util.eql(name, "position") and value != null) name = "$$position";
            }
            const expr: ?*Node = if (value != null and value.?.type == .JSXExpressionContainer) ast.unparen(value.?.expression.?) else null;
            const expr_text: ?Str = if (expr) |e| try self.textFor(e) else null;
            const literal_string: ?Str = if (value != null and value.?.type == .Literal) value.?.stringValue() else null;

            if (util.eql(name, "$$for")) {
                if (expr == null or expr.?.type != .ArrowFunctionExpression) return errAt(":for canonical form must be an arrow", attr);
                for_info = .{
                    .binder = try self.slice(expr.?.params[0].start, expr.?.params[0].end),
                    .src = try self.textFor(ast.unparen(expr.?.body.?)),
                };
                continue;
            }
            if (util.eql(name, "$$key") or util.eql(name, "key")) {
                key_expr = expr_text;
                continue;
            }
            if (util.eql(name, "$$show")) {
                if (literal_string != null) {
                    try target.append(self.a, try self.f("\"data-p-show\": {s}", .{try self.slice(value.?.start, value.?.end)}));
                } else {
                    show_expr = expr_text;
                }
                continue;
            }
            // `hidden` on a component is the universal visibility prop: the show
            // wrapper with inverted polarity, applied to the component's root node.
            if (!intrinsic and util.eql(name, "hidden") and expr != null) {
                show_expr = if (expr_text) |text| try self.f("!({s})", .{text}) else "false";
                continue;
            }
            if (!intrinsic and util.eql(name, "hidden") and expr == null) {
                show_expr = "false";
                continue;
            }

            if (util.eql(name, "$$class")) {
                if (literal_string != null) {
                    try target.append(self.a, try self.f("\"data-p-class\": {s}", .{try self.slice(value.?.start, value.?.end)}));
                } else {
                    try class_layers.append(self.a, .{ .static = false, .text = expr_text orelse "undefined" });
                }
                continue;
            }
            if (util.eql(name, "$$text")) {
                if (literal_string != null) {
                    try target.append(self.a, try self.f("\"data-p-text\": {s}", .{try self.slice(value.?.start, value.?.end)}));
                } else {
                    text_expr = expr_text;
                }
                continue;
            }
            if (util.eql(name, "$$html")) return errAt(":html is not implemented yet (deferred to v1.1)", attr);
            if (util.eql(name, "$$store")) {
                if (!intrinsic or literal_string == null) return errAt("@store requires a string value on an intrinsic element", attr);
                try entries.append(self.a, try self.f("\"data-p-store\": {s}", .{try self.slice(value.?.start, value.?.end)}));
                continue;
            }
            if (util.eql(name, "$$data")) {
                if (!intrinsic or expr == null or expr.?.type != .ObjectExpression) return errAt("@data requires an object expression on an intrinsic element", attr);
                try entries.append(self.a, try self.f("\"data-p\": () => JSON.stringify({s})", .{expr_text.?}));
                continue;
            }
            if (util.eql(name, "$$ref")) {
                if ((!intrinsic and !is_slot) or literal_string == null) return errAt("@ref requires a string value on an intrinsic element or Slot", attr);
                try target.append(self.a, try self.f("\"data-p-ref\": {s}", .{try self.slice(value.?.start, value.?.end)}));
                continue;
            }
            if (util.eql(name, "$$portal")) {
                if (!intrinsic) return errAt("@portal requires an intrinsic element", attr);
                if (value == null) {
                    try entries.append(self.a, "\"data-p-portal\": true");
                } else if (value.?.type == .Literal) {
                    try entries.append(self.a, try self.f("\"data-p-portal\": {s}", .{try self.slice(value.?.start, value.?.end)}));
                } else {
                    try entries.append(self.a, try self.f("\"data-p-portal\": () => ({s})", .{expr_text.?}));
                }
                continue;
            }
            if (util.eql(name, "$$anchor")) {
                if ((!intrinsic and !is_slot) or value != null) return errAt("@anchor is a valueless intrinsic-element or Slot directive", attr);
                try target.append(self.a, "\"data-p-anchor\": true");
                continue;
            }
            if (util.eql(name, "$$position")) {
                if (!intrinsic or value == null) return errAt("@position requires an intrinsic-element value", attr);
                const position_value = if (value.?.type == .Literal) try self.slice(value.?.start, value.?.end) else try self.f("() => ({s})", .{expr_text.?});
                try entries.append(self.a, try self.f("\"data-p-position\": {s}", .{position_value}));
                continue;
            }
            if (std.mem.startsWith(u8, name, "$$on$")) {
                if (literal_string) |s| {
                    try literal_event_wires.append(self.a, try self.f("{s}:{s}", .{ try util.replaceAll(self.a, name[5..], "$", "."), s }));
                } else {
                    try target.append(self.a, try self.eventEntry(name, expr_text orelse "undefined", attr));
                }
                continue;
            }
            if (std.mem.startsWith(u8, name, "$$b$")) {
                const attr_name = name[4..];
                if (util.eql(attr_name, "if")) return errAt("conditional mounting is not a Publr directive; use :show", attr);
                if (literal_string) |s| {
                    try literal_bind_wires.append(self.a, try self.f("{s}:{s}", .{ attr_name, s }));
                } else if (intrinsic) {
                    try entries.append(self.a, try self.f("{s}: () => ({s})", .{ try self.propKey(attr_name), expr_text orelse "undefined" }));
                } else {
                    try component_entries.append(self.a, try self.getter(try self.propKey(attr_name), try self.f("({s})", .{expr_text orelse "undefined"})));
                }
                continue;
            }

            // Regular JSX attribute.
            if (util.eql(name, "class") and intrinsic) {
                if (value == null) {
                    try class_layers.append(self.a, .{ .static = true, .text = "\"\"" });
                } else if (value.?.type == .Literal) {
                    try class_layers.append(self.a, .{ .static = true, .text = try self.slice(value.?.start, value.?.end) });
                } else if (expr != null and isStaticLiteral(expr.?)) {
                    try class_layers.append(self.a, .{ .static = true, .text = expr_text.? });
                } else {
                    try class_layers.append(self.a, .{ .static = false, .text = expr_text orelse "undefined" });
                }
                continue;
            }
            if (util.eql(name, "class")) {
                if (value == null) {
                    try class_layers.append(self.a, .{ .static = true, .text = "\"\"" });
                } else if (value.?.type == .Literal) {
                    try class_layers.append(self.a, .{ .static = true, .text = try self.slice(value.?.start, value.?.end) });
                } else if (expr) |e| {
                    try class_layers.append(self.a, .{ .static = isStaticLiteral(e), .text = expr_text.? });
                }
                continue;
            }

            if (duplicate_attributes.get(name)) |group| if (group.items.len > 1) {
                if (emitted_duplicates.has(name)) continue;
                try emitted_duplicates.put(name, {});
                const merged = try self.mergedAttributeExpression(group.items);
                const entry: Str = if (intrinsic)
                    (if (util.isEventProp(name))
                        try self.f("{s}: ($e) => ({s})?.($e)", .{ try self.propKey(name), merged })
                    else if (util.eql(name, "ref"))
                        try self.f("ref: ($el) => ({s})?.($el)", .{merged})
                    else
                        try self.f("{s}: () => ({s})", .{ try self.propKey(name), merged }))
                else
                    try self.getter(try self.propKey(name), try self.f("({s})", .{merged}));
                try target.append(self.a, entry);
                continue;
            };

            var entry: Str = undefined;
            if (value == null) {
                entry = try self.f("{s}: true", .{try self.propKey(name)});
            } else if (value.?.type == .Literal) {
                entry = try self.f("{s}: {s}", .{ try self.propKey(name), try self.slice(value.?.start, value.?.end) });
            } else if (expr != null and isStaticLiteral(expr.?)) {
                entry = try self.f("{s}: {s}", .{ try self.propKey(name), expr_text.? });
            } else if (intrinsic and util.isEventProp(name)) {
                entry = try self.f("{s}: ({s})", .{ try self.propKey(name), expr_text orelse "undefined" });
            } else if (intrinsic and util.eql(name, "style") and expr != null and expr.?.type == .ObjectExpression) {
                var style_entries: StrList = .empty;
                for (expr.?.properties) |p| {
                    if (p.type != .Property or p.computed) return errAt("unsupported style object shape", p);
                    const k: Str = if (p.key.?.type == .Identifier) p.key.?.name else try literalToString(self.a, p.key.?);
                    const v_text = try self.textFor(p.value_node.?);
                    const is_lit = isStaticLiteral(ast.unparen(p.value_node.?));
                    try style_entries.append(self.a, try self.f("{s}: {s}", .{ try self.propKey(k), if (is_lit) v_text else try self.f("() => ({s})", .{v_text}) }));
                }
                entry = try self.f("style: {s}", .{try self.objectLiteral(style_entries.items)});
            } else if (intrinsic and util.eql(name, "ref")) {
                entry = try self.f("ref: ({s})", .{expr_text orelse "undefined"});
            } else if (intrinsic) {
                entry = try self.f("{s}: () => ({s})", .{ try self.propKey(name), expr_text orelse "undefined" });
            } else {
                // Component prop: functions pass as-is (stable), anything else becomes a live getter.
                const inner = if (expr) |e| ast.unparen(e) else null;
                entry = if (inner != null and (inner.?.type == .ArrowFunctionExpression or inner.?.type == .FunctionExpression))
                    try self.f("{s}: ({s})", .{ try self.propKey(name), expr_text.? })
                else
                    try self.getter(try self.propKey(name), try self.f("({s})", .{expr_text orelse "undefined"}));
            }
            try target.append(self.a, entry);
        }

        if (literal_event_wires.items.len > 0) {
            try target.append(self.a, try self.f("\"data-p-on\": {s}", .{try self.json(try util.join(self.a, literal_event_wires.items, ";"))}));
        }
        if (literal_bind_wires.items.len > 0) {
            try target.append(self.a, try self.f("\"data-p-bind\": {s}", .{try self.json(try util.join(self.a, literal_bind_wires.items, ";"))}));
        }
        var kids: []Str = if (option_collection != null) &.{} else try self.emitChildren(node.children);
        if (text_expr) |te| {
            const single = try self.a.alloc(Str, 1);
            single[0] = try self.f("() => ({s})", .{te});
            kids = single;
        }

        var core: Str = undefined;
        if (intrinsic) {
            if (class_layers.items.len > 0) {
                const class_entry = if (class_layers.items.len == 1 and class_layers.items[0].static)
                    try self.f("class: {s}", .{class_layers.items[0].text})
                else
                    try self.f("class: () => [{s}]", .{try self.joinLayers(class_layers.items)});
                try entries.insert(self.a, 0, class_entry);
            }
            try self.used.put("h", {});
            const props = if (entries.items.len > 0) try self.objectLiteral(entries.items) else "null";
            const kids_text = if (kids.len > 0) try self.f(", {s}", .{try util.join(self.a, kids, ", ")}) else "";
            core = try self.f("h({s}, {s}{s})", .{ try self.json(tag.name), props, kids_text });
        } else {
            if (class_layers.items.len > 0) {
                const layer_text = if (class_layers.items.len == 1) class_layers.items[0].text else try self.f("[{s}]", .{try self.joinLayers(class_layers.items)});
                try component_entries.append(self.a, try self.getter("class", layer_text));
            }
            if (option_collection) |oc| {
                try component_entries.append(self.a, try self.getter("children", oc));
            } else if (kids.len > 0) {
                const single_child: ?Str = if (text_expr == null) try self.emitSingleComponentChild(node.children) else null;
                const children_text = single_child orelse (if (kids.len == 1) kids[0] else try self.f("[{s}]", .{try util.join(self.a, kids, ", ")}));
                try component_entries.append(self.a, try self.getter("children", children_text));
            }
            try self.used.put("component", {});
            core = try self.f("component({s}, {s})", .{ tag_text, try self.objectLiteral(component_entries.items) });
        }

        if (show_expr) |se| {
            try self.used.put("show", {});
            core = try self.f("show({s}, () => ({s}))", .{ core, se });
        }
        if (for_info) |fi| {
            try self.used.put("list", {});
            core = try self.f("list(() => ({s}), ({s}, $i) => ({s}), ({s}, $i) => {s})", .{ fi.src, fi.binder, key_expr orelse "$i", fi.binder, core });
        }
        return .{ .code = core, .key = key_expr };
    }

    /// Object literal in oxc codegen shape: 0/1 properties inline, more one per line.
    fn objectLiteral(self: *Transformer, entries: []const Str) Error!Str {
        if (entries.len == 0) return "{}";
        if (entries.len == 1) return try self.f("{{ {s} }}", .{entries[0]});
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.a, "{\n\t");
        for (entries, 0..) |entry, index| {
            if (index > 0) try out.appendSlice(self.a, ",\n\t");
            try out.appendSlice(self.a, try util.replaceAll(self.a, entry, "\n", "\n\t"));
        }
        try out.appendSlice(self.a, "\n}");
        return out.toOwnedSlice(self.a);
    }

    /// Getter in oxc codegen shape.
    fn getter(self: *Transformer, name: Str, value: Str) Error!Str {
        return self.f("get {s}() {{\n\treturn {s};\n}}", .{ name, try util.replaceAll(self.a, value, "\n", "\n\t") });
    }

    fn joinLayers(self: *Transformer, layers: []const Layer) Error!Str {
        var texts: StrList = .empty;
        for (layers) |layer| try texts.append(self.a, layer.text);
        return util.join(self.a, texts.items, ", ");
    }

    fn findRoots(self: *Transformer, node: *Node, roots: *NodeList) Error!void {
        if (node.isJsx()) {
            try roots.append(self.a, node);
            return;
        }
        for (try childNodes(self.a, node)) |child| try self.findRoots(child, roots);
    }

    // ── Assemble ──────────────────────────────────────────────────────────

    // ── Family roots ──────────────────────────────────────────────────────
    //
    // A module that exports `state = Publr.reactive(...)` is a family root:
    // its parts import that store, the refs and the actions. The Zig target
    // materializes the store per rendered root; here the module-level
    // declarations move into a factory the runtime runs once per root
    // instance, and the exports the parts import become stand-ins that reach
    // the instance of the root they render under.

    fn unwrapTs(node: *Node) *Node {
        var current = node;
        while (true) {
            const t = current.type;
            if (t == .ParenthesizedExpression or t == .TSAsExpression or t == .TSNonNullExpression or t == .TSSatisfiesExpression) {
                current = current.expression orelse return current;
            } else return current;
        }
    }

    fn isPublrCall(node: *Node, name: Str) bool {
        const call = unwrapTs(node);
        if (call.type != .CallExpression) return false;
        const callee = call.callee orelse return false;
        if (callee.type != .MemberExpression or callee.computed) return false;
        return (callee.object orelse return false).isIdentifier("Publr") and (callee.property orelse return false).isIdentifier(name);
    }

    fn containsPublrCall(node: *Node, name: Str) bool {
        const Ctx = struct {
            name: Str,
            found: *bool,
            fn visit(self: @This(), candidate: *Node) anyerror!void {
                if (isPublrCall(candidate, self.name)) self.found.* = true;
            }
        };
        var found = false;
        ast.walk(node, Ctx{ .name = name, .found = &found }, Ctx.visit) catch return false;
        return found;
    }

    fn fileStem(filename: Str) Str {
        const base = if (std.mem.lastIndexOfScalar(u8, filename, '/')) |i| filename[i + 1 ..] else filename;
        return if (std.mem.indexOfScalar(u8, base, '.')) |i| base[0..i] else base;
    }

    fn isComponentName(name: Str) bool {
        return name.len > 0 and name[0] >= 'A' and name[0] <= 'Z';
    }

    /// The family factory and the forwarded exports, appended to the module;
    /// the carried statements are removed and the root component starts by
    /// creating its instance. Null when the module declares no family.
    fn lowerFamily(self: *Transformer, opts: Options) Error!?Str {
        var declares_family = false;
        for (self.program.statements) |statement| {
            if (statement.type != .ExportNamedDeclaration) continue;
            const declaration = statement.declaration orelse continue;
            if (declaration.type != .VariableDeclaration) continue;
            for (declaration.declarations) |item| {
                const id = item.id orelse continue;
                if (id.isIdentifier("state") and item.init != null and isPublrCall(item.init.?, "reactive")) declares_family = true;
            }
        }
        if (!declares_family) return null;

        const stem = fileStem(opts.filename orelse "");
        var root_fn: ?*Node = null;
        var first_component: ?*Node = null;
        for (self.program.statements) |statement| {
            if (statement.type != .ExportNamedDeclaration) continue;
            const declaration = statement.declaration orelse continue;
            if (declaration.type != .FunctionDeclaration or declaration.id == null) continue;
            const name = declaration.id.?.name;
            if (util.eql(name, stem)) root_fn = declaration;
            if (first_component == null and isComponentName(name)) first_component = declaration;
        }
        const root = root_fn orelse first_component orelse return null;
        const root_name = root.id.?.name;
        const family = try self.f("{s}Family", .{self.runtime_name});
        try self.used.put("family", {});

        var body: std.ArrayList(u8) = .empty;
        var names: StrList = .empty;
        var forwards: std.ArrayList(u8) = .empty;
        var forwarded = util.StringSet.init(self.a);
        for (self.program.statements) |statement| {
            const exported = statement.type == .ExportNamedDeclaration;
            const declaration = (if (exported) statement.declaration else statement) orelse continue;
            var carried = false;
            var action = false;
            if (declaration.type == .VariableDeclaration) {
                if (exported) {
                    var all_functions = declaration.declarations.len > 0;
                    for (declaration.declarations) |item| {
                        const init = if (item.init) |i| unwrapTs(i) else null;
                        if (init == null or !init.?.isFunction()) all_functions = false;
                        if (init != null and (isPublrCall(init.?, "reactive") or containsPublrCall(init.?, "ref"))) carried = true;
                    }
                    if (all_functions) {
                        carried = true;
                        action = true;
                    }
                } else carried = true;
                if (carried) for (declaration.declarations) |item| {
                    const id = item.id.?;
                    if (id.type != .Identifier) return errAt("a family module's declarations need identifier names", id);
                    try names.append(self.a, id.name);
                    if (exported) {
                        try forwarded.put(id.name, {});
                        try forwards.appendSlice(self.a, try self.f("export const {s} = {s}.{s}({s});\n", .{ id.name, family, if (action) "action" else "field", try self.json(id.name) }));
                    }
                };
            } else if (declaration.type == .FunctionDeclaration and declaration.id != null) {
                const name = declaration.id.?.name;
                if (declaration == root or isComponentName(name)) continue;
                carried = true;
                try names.append(self.a, name);
                if (exported) {
                    try forwarded.put(name, {});
                    try forwards.appendSlice(self.a, try self.f("export const {s} = {s}.action({s});\n", .{ name, family, try self.json(name) }));
                }
            } else if (declaration.type == .ExpressionStatement and declaration.expression != null and isPublrCall(declaration.expression.?, "effect")) {
                carried = true;
            }
            if (!carried) continue;
            try self.remove_ranges.append(self.a, .{ statement.start, statement.end });
            const text = try self.textFor(declaration);
            try body.appendSlice(self.a, "  ");
            try body.appendSlice(self.a, text);
            if (text.len > 0 and text[text.len - 1] != ';' and text[text.len - 1] != '}') try body.appendSlice(self.a, ";");
            try body.appendSlice(self.a, "\n");
        }

        // The root component creates its instance before its props are read
        // (a children getter builds the parts), and its body reaches the
        // carried locals that have no forwarded export.
        var taken = util.StringSet.init(self.a);
        for (root.params) |param| try collectPatternNames(param, &taken);
        if (root.body) |fn_body| for (fn_body.statements) |st| try collectStatementDecls(st, &taken);
        var private_locals: StrList = .empty;
        for (names.items) |name| if (!taken.has(name) and !forwarded.has(name)) try private_locals.append(self.a, name);
        const fn_body = root.body orelse return errAt("a family root needs a function body", root);
        if (private_locals.items.len > 0)
            try self.ident_edits.append(self.a, .{ .start = fn_body.start + 1, .end = fn_body.start + 1, .text = try self.f("\n  const {{ {s} }} = {s}.current();", .{ try util.join(self.a, private_locals.items, ", "), family }) });
        for (self.program.statements) |statement| {
            if (statement.type == .ExportNamedDeclaration and statement.declaration == root) {
                try self.ident_edits.append(self.a, .{ .start = statement.start, .end = root.id.?.end, .text = try self.f("export const {s} = {s}.root(function {s}", .{ root_name, family, root_name }) });
                try self.ident_edits.append(self.a, .{ .start = root.end, .end = root.end, .text = ");" });
            }
        }

        return try self.f("const {s} = {s}.family({s}, () => {{\n{s}  return {{ {s} }};\n}});\n{s}", .{ family, self.runtime_name, try self.json(root_name), body.items, try util.join(self.a, names.items, ", "), forwards.items });
    }

    fn run(self: *Transformer, opts: Options) Error!Result {
        try self.findComponents(self.program, 0);
        std.mem.sort(Edit, self.ident_edits.items, {}, lessEdit);

        var roots: NodeList = .empty;
        try self.findRoots(self.program, &roots);
        const family_tail = try self.lowerFamily(opts);
        std.mem.sort(Edit, self.ident_edits.items, {}, lessEdit);

        var overwrites: std.ArrayList(Edit) = .empty;
        for (self.ident_edits.items) |edit| {
            var in_root = false;
            for (roots.items) |r| if (edit.start >= r.start and edit.end <= r.end) {
                in_root = true;
                break;
            };
            if (!in_root and !self.removed(edit.start, edit.end)) try overwrites.append(self.a, edit);
        }
        for (roots.items) |root| {
            try overwrites.append(self.a, .{ .start = root.start, .end = root.end, .text = (try self.emitJsx(root)).code });
        }
        for (self.remove_ranges.items) |range| try overwrites.append(self.a, .{ .start = range[0], .end = range[1], .text = "" });
        std.mem.sort(Edit, overwrites.items, {}, lessEdit);

        var out: std.ArrayList(u8) = .empty;
        var pos: u32 = 0;
        for (overwrites.items) |edit| {
            if (edit.start < pos) continue; // overlapping edit — MagicString would have thrown
            try out.appendSlice(self.a, self.src(pos, edit.start));
            try out.appendSlice(self.a, edit.text);
            pos = edit.end;
        }
        try out.appendSlice(self.a, self.src(pos, @intCast(self.source.len)));

        var code: Str = try out.toOwnedSlice(self.a);
        // The family block leads the module: imports hoist above it, and the
        // root const that wraps the component needs it at evaluation.
        if (family_tail) |tail| code = try util.concat(self.a, &.{ tail, code });
        if (!opts.bare and self.used.count() > 0) {
            const import_line = try self.f("import * as {s} from {s};\n", .{ self.runtime_name, try self.json(opts.runtime_import orelse "publr/dom") });
            code = try util.concat(self.a, &.{ import_line, code });
        }
        return .{ .code = code, .map = null };
    }

    fn removed(self: *Transformer, start: u32, end: u32) bool {
        for (self.remove_ranges.items) |range| if (start >= range[0] and end <= range[1]) return true;
        return false;
    }
};

/// `String(literal.value)` for property keys.
fn literalToString(a: Allocator, node: *Node) Error!Str {
    return switch (node.value) {
        .string => |s| s,
        .number => |n| try util.numberToString(a, n),
        .boolean => |b| if (b) "true" else "false",
        .null => "null",
        else => node.raw,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The reference tests observe `transformPjsxToDom` output (canonicalize →
/// transform → type strip with oxc's paren normalisation); mirror that.
fn transformTest(a: Allocator, source: Str, filename: Str) !Str {
    const result = try @import("dom.zig").transformPjsxToDom(a, source, .{ .filename = filename });
    return result.code;
}

fn expectContains(haystack: Str, needle: Str) !void {
    if (util.indexOf(haystack, needle) == null) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

fn expectNotContains(haystack: Str, needle: Str) !void {
    if (util.indexOf(haystack, needle) != null) {
        std.debug.print("did not expect to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedNotContains;
    }
}

const badge_source =
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

test "one parsed component lowers to DOM" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(), badge_source, "badge.pjsx");
    try expectContains(code, "import * as $$dom from \"publr/dom\"");
    try expectContains(code, "element(\"span\"");
}

test "DOM components render through the runtime root-attribute forwarding boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\function Trigger({ label }) {
        \\  return <Dynamic as="button" aria-label={label}>{label}</Dynamic>;
        \\}
        \\export const trigger = <Trigger label="Open" data-part="trigger" aria-describedby="hint" />;
    , "trigger.ptsx");
    try expectContains(code, "import * as $$dom from \"publr/dom\"");
    try expectContains(code, "component(Trigger,");
    try expectContains(code, "component(Dynamic,");
    try expectContains(code, "\"data-part\": \"trigger\"");
    try expectContains(code, "\"aria-describedby\": \"hint\"");
}

test "a self-referential prop type and a Readonly<Record> lower to DOM" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\type Tree = { label: string; children?: Tree[] };
        \\type Values = Readonly<Record<string, string>>;
        \\function Branch({ tree, values }: { tree: Tree; values: Values }) {
        \\  return <li title={values.title}>{tree.label}{tree.children && <span>+</span>}</li>;
        \\}
        \\export const branch = <Branch tree={{ label: "root" }} values={{ title: "t" }} />;
    , "branch.ptsx");
    try expectContains(code, "component(Branch,");
    try expectContains(code, "element(\"li\"");
}

test "a reactive component child stays a live value instead of a nested thunk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\function Readout({ children }) {
        \\  return <output>{children}</output>;
        \\}
        \\function Editor({ state }) {
        \\  return <Readout>{state.label}</Readout>;
        \\}
    , "editor.ptsx");
    try expectContains(code, "get children() {\n\treturn state.label;\n}");
    try expectNotContains(code, "return () => state.label");
}

test "nested JSX-bearing callbacks keep distinct rewritten parameter scopes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\const variants = HIERARCHIES.flatMap((hierarchy) =>
        \\  INTENTS.map((intent) => ({
        \\    Demo: () => <Button hierarchy={hierarchy} intent={intent} />,
        \\  })),
        \\);
    , "nested-gallery-callbacks.ptsx");
    try expectContains(code, "flatMap(($$p) =>");
    try expectContains(code, "INTENTS.map(($$p1) =>");
    try expectContains(code, "get hierarchy() {\n\t\treturn $$p;\n\t}");
    try expectContains(code, "get intent() {\n\t\treturn $$p1;\n\t}");
}

test "typed option children lower to descriptor data in the DOM target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const code = try transformTest(a,
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
    , "range-scale-demo.ptsx");
    try expectContains(code, "get children() {\n\t\treturn options.map");
    try expectContains(code, "label: $$p.label");
    try expectContains(code, "value: $$p.value");
    try expectNotContains(code, "component(RangeScalePickerOptions");
    try expectNotContains(code, "component(RangeScalePickerOption");

    const static_code = try transformTest(a,
        \\export const picker = (
        \\  <RangeScalePicker value="sm" label="Spacing">
        \\    <RangeScalePickerOptions>
        \\      <RangeScalePickerOption value="xs">XS</RangeScalePickerOption>
        \\      <RangeScalePickerOption value="sm">SM</RangeScalePickerOption>
        \\    </RangeScalePickerOptions>
        \\  </RangeScalePicker>
        \\);
    , "static-range-scale.ptsx");
    try expectContains(static_code, "get children()");
    try expectContains(static_code, "label: \"XS\"");
    try expectContains(static_code, "value: \"xs\"");
    try expectNotContains(static_code, "component(RangeScalePickerOptions");
}

test "compound configuration-shaped children remain real component anatomy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
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
    , "box-value-fixture.ptsx");
    try expectContains(code, "component(BoxValueControlIcon");
    try expectContains(code, "component(SelectedSidesIcon");
    try expectContains(code, "component(BoxValueControlRangeScalePicker");
    try expectContains(code, "component(BoxValueControlRangeScalePickerOption");
    try expectContains(code, "component(BoxValueControlRangePicker");
    try expectNotContains(code, "rangeScalePickerOptions");
    try expectNotContains(code, "iconIsSelectedSidesIcon");
}

test "compound anatomy sharing the parent prefix remains rendered children" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\import { UnitControl } from "./UnitControl.ptsx";
        \\import { UnitControlInput } from "./UnitControlInput.ptsx";
        \\import { UnitControlUnit } from "./UnitControlUnit.ptsx";
        \\export const demoProps = {};
        \\export function Demo() {
        \\  return <UnitControl><UnitControlInput value={0} /><UnitControlUnit value="px" /></UnitControl>;
        \\}
    , "Demo.ptsx");
    try expectContains(code, "component(UnitControlInput, { value: 0 })");
    try expectContains(code, "component(UnitControlUnit, { value: \"px\" })");
    try expectNotContains(code, "inputValue:");
    try expectNotContains(code, "unitValue:");
}

test "conditional mounting is not exposed as a Publr directive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.Pjsx, transformTest(arena.allocator(), "export const item = <div :if={visible}>Item</div>;", "conditional-mount.ptsx"));
    try expectContains(err.message(), "conditional mounting is not a Publr directive; use :show");
}

test "repeated attributes merge in source order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
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
    , "panel.ptsx");
    try expectContains(code, "classes($$domElement, () => [\"w-full rounded-md\", classes]");
    try expectContains(code, "\"data-state\", () =>");
}

test ":show applies directly to component roots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\import { Icon } from "./Icon.ptsx";
        \\export const iconPairProps = {
        \\  visible: { type: "boolean", optional: true, default: false },
        \\};
        \\export function IconPair({ visible = false }) {
        \\  return (
        \\    <div>
        \\      <Icon :show={visible} />
        \\      <Icon :show={!visible} />
        \\    </div>
        \\  );
        \\}
    , "icon-pair.ptsx");
    try expectContains(code, "show($$dom.component(Icon,");
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
    \\    <button type="button" aria-expanded={state.open} onClick={toggle}>
    \\      {children}
    \\    </button>
    \\  );
    \\}
    \\
;

test "a family root makes its module state once per instance and forwards the exports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try transformTest(a, family_root_source, "Disclosure.ptsx");
    try expectContains(root, "const $$domFamily = $$dom.family(\"Disclosure\", () => {");
    try expectContains(root, "  const state = Publr.reactive({");
    try expectContains(root, "  const toggle = (event) => {");
    try expectContains(root, "  return { state, toggle };");
    try expectContains(root, "export const state = $$domFamily.field(\"state\");");
    try expectContains(root, "export const toggle = $$domFamily.action(\"toggle\");");
    try expectContains(root, "export const Disclosure = $$domFamily.root(function Disclosure({ startOpen = false, children }) {\n  state.open = startOpen");
    try expectNotContains(root, "$$domFamily.current()");
    try expectContains(root, "export const disclosureProps = {");
    try expectNotContains(root, "export const state = Publr.reactive");
    try expectNotContains(root, "Publr.createLocalStore");
    const part = try transformTest(a, family_part_source, "DisclosureButton.ptsx");
    try expectNotContains(part, "click:toggle");
    try expectNotContains(part, "family(");
    try expectContains(part, "state.open");
}

test "a family root carries refs, helpers and module effects and skips names its function declares" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\import { Publr } from "publr-jsx";
        \\export const state = Publr.reactive({ open: false });
        \\export const root = Publr.ref();
        \\let toggles = 0;
        \\const KEYS = ["Enter", " "];
        \\export function keydown(event: KeyboardEvent) {
        \\  if (KEYS.includes(event.key)) toggles++;
        \\}
        \\Publr.effect(() => {
        \\  console.log(state.open);
        \\});
        \\export const SIZES = ["sm", "md"];
        \\export function Disclosure({ KEYS = [] }: { KEYS?: string[] }) {
        \\  const toggles = 1;
        \\  return <div ref={root}>{toggles}</div>;
        \\}
    , "Disclosure.ptsx");
    try expectContains(code, "export const Disclosure = $$domFamily.root(function Disclosure({ KEYS = [] }) {\n  const toggles = 1;");
    try expectNotContains(code, "$$domFamily.current()");
    try expectContains(code, "  let toggles = 0;");
    try expectContains(code, "  Publr.effect(() => {");
    try expectContains(code, "  return { state, root, toggles, KEYS, keydown };");
    try expectContains(code, "export const root = $$domFamily.field(\"root\");");
    try expectContains(code, "export const keydown = $$domFamily.action(\"keydown\");");
    try expectContains(code, "export const SIZES = [\"sm\", \"md\"];");
}

test "a family root reaches carried locals without a forwarded export" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\import { Publr } from "publr-jsx";
        \\export const state = Publr.reactive({ open: false });
        \\const options = () => [];
        \\export function Menu() {
        \\  return <ul data-count={options().length}>{state.open}</ul>;
        \\}
    , "Menu.ptsx");
    try expectContains(code, "export const Menu = $$domFamily.root(function Menu() {\n  const { options } = $$domFamily.current();");
    try expectContains(code, "$$dom.family(\"Menu\", () => {\n  const state = Publr.reactive({ open: false });\n  const options = () => [];\n  return { state, options };\n});\nexport const state = $$domFamily.field(\"state\");\n");
}

test "a block-bodied map callback lowers as a list with its statements per row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\export function Rows({ rows }: { rows: { id: number; name: string }[] }) {
        \\  return (
        \\    <ul>
        \\      {rows.map((row) => {
        \\        const label = row.name.toUpperCase();
        \\        return <li key={row.id}>{label}</li>;
        \\      })}
        \\    </ul>
        \\  );
        \\}
    , "Rows.ptsx");
    try expectContains(code, "$$dom.list(() => rows, ($$p, $i) => $$p.id, ($$p, $i) => { const label = $$p().name.toUpperCase(); return ");
    try expectContains(code, "$$dom.insert(() => label)");
}

test "hidden on component calls rides the show transport with inverted polarity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\import { Icon } from "./Icon.ptsx";
        \\export const iconPairProps = {
        \\  active: { type: "boolean", optional: true, default: false },
        \\  muted: { type: "boolean", optional: true, default: false },
        \\};
        \\export function IconPair({ active = false, muted = false }) {
        \\  return (
        \\    <div>
        \\      <Icon hidden={!active} />
        \\      <Icon hidden={active} />
        \\      <Icon hidden={active || muted} />
        \\    </div>
        \\  );
        \\}
    , "icon-pair.ptsx");
    try expectContains(code, "show($$dom.component(Icon,");
    try expectContains(code, "!!active");
    try expectContains(code, "!(active || muted)");
}

test "portal, anchor, position and store directives lower to data-p attributes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const overlay = try transformTest(a,
        \\export const overlayProps = {
        \\  align: { type: "string", optional: true, default: "left", values: ["left", "right"] },
        \\};
        \\export function Overlay({ align = "left" }) {
        \\  return <div><button @anchor>Anchor</button><div @portal @position={align}>Panel</div></div>;
        \\}
    , "overlay.ptsx");
    try expectContains(overlay, "\"data-p-portal\", true");
    try expectContains(overlay, "\"data-p-anchor\", true");
    try expectContains(overlay, "\"data-p-position\", () => align");

    const island = try transformTest(a,
        \\export const islandProps = {};
        \\export function Island() {
        \\  return <section @store="example">Content</section>;
        \\}
    , "island.ptsx");
    try expectContains(island, "\"data-p-store\", \"example\"");
}

test "literal Publr store directives bind compound parts through their ancestor island" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\export const menuPartProps = {};
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
    , "menu-part.ptsx");
    try expectContains(code, "\"data-p-on\", \"click:toggle;keydown.down.prevent:openFirst;keydown.home.prevent:openFirst;keydown.end.prevent:openFirst\"");
    try expectContains(code, "\"data-p-bind\", \"aria-expanded:$open\"");
    try expectContains(code, "\"data-p-show\", \"$open\"");
    try expectContains(code, "\"data-p-class\", \"$open -> flex\"");
    try expectContains(code, "\"data-p-text\", \"$label\"");
}

test "nullish coalescing preserves JavaScript semantics in the DOM target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\export const fallbackProps = {
        \\  title: { type: "optional-string", optional: true },
        \\  hidden: { type: "optional-boolean", optional: true },
        \\  children: { type: "children", optional: true },
        \\  fallback: { type: "node" },
        \\};
        \\export function Fallback({ title, hidden, children, fallback }) {
        \\  return (
        \\    <section title={title ?? "Untitled"} hidden={hidden ?? false}>
        \\      {children ?? fallback}
        \\    </section>
        \\  );
        \\}
    , "fallback.ptsx");
    try expectContains(code, "title ?? \"Untitled\"");
    try expectContains(code, "hidden ?? false");
    try expectContains(code, "children ?? fallback");
}

test "a single props object preserves live component getters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\export const meterProps = {
        \\  value: { type: "number" },
        \\  label: { type: "string" },
        \\  onInput: { type: "action", optional: true },
        \\};
        \\export function Meter(props) {
        \\  return <input type="range" value={props.value} aria-label={props.label} onInput={props.onInput} />;
        \\}
    , "meter.ptsx");
    try expectContains(code, "value");
}

test "JSX window events and forwarded component refs use the shared DOM transport" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\import { Publr } from "publr/dom";
        \\import { Control } from "./Control.ptsx";
        \\export const state = Publr.reactive({ busy: false });
        \\export const control = Publr.ref();
        \\export const go = () => { state.busy = true; };
        \\export const listProps = {};
        \\export function List() {
        \\  return <div class={state.busy ? "busy" : ""} onWindowPopState={go}><Control ref={control} onClick={go} /></div>;
        \\}
    , "List.ptsx");
    try expectContains(code, "ownerDocument.defaultView, \"popstate\", go");
    try expectContains(code, "get ref()");
    try expectContains(code, "get onClick()");
    try expectContains(code, "state.busy");
}

test "shared state reads and actions compile in JSX without a local family" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = try transformTest(arena.allocator(),
        \\import { Publr } from "publr/dom";
        \\export const crumbsProps = {} as const;
        \\export function Crumbs() {
        \\  return <nav hidden={!Publr.stores.navigation.open} onClick={Publr.stores.navigation.back}>
        \\    {Publr.stores.navigation.levels.map((level) => <a key={level.depth}>{level.title}</a>)}
        \\  </nav>;
        \\}
    , "Crumbs.ptsx");
    try expectContains(code, "\"hidden\", () => !Publr.stores.navigation.open");
    try expectContains(code, "\"click\", Publr.stores.navigation.back");
    try expectContains(code, "Publr.stores.navigation.levels");
    try expectContains(code, "depth");
}
