//! Inline display-only children into their owner's HTML binding scope.
const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const util = @import("util.zig");
const types = @import("types.zig");
const err = @import("err.zig");
const A = std.mem.Allocator;
const S = []const u8;
const N = ast.Node;
const Error = err.Error;
const View = struct { root: *N, param: S };

fn simpleExpression(n: *N, param: S) bool {
    if (n.type == .Literal) return true;
    return n.type == .MemberExpression and !n.computed and n.object.?.isIdentifier(param) and n.property.?.type == .Identifier;
}
// Component calls are safe in a static shell, but must never make a child
// eligible for display-only inlining: stateful descendants keep their owners.
fn importedComponent(program: *N, name: S) bool {
    for (program.statements) |statement| {
        if (statement.type != .ImportDeclaration) continue;
        const spec = statement.source.?.stringValue() orelse continue;
        if (!util.hasPjsxExtension(spec)) continue;
        for (statement.specifiers) |entry| {
            if (entry.type == .ImportSpecifier and entry.local != null and entry.local.?.isIdentifier(name)) return true;
        }
    }
    return false;
}
fn simpleTree(n: *N, param: S, shell: ?*N) bool {
    if (n.type == .JSXText) return true;
    if (n.type == .JSXExpressionContainer) return n.expression == null or simpleExpression(n.expression.?, param);
    if (n.type != .JSXElement and n.type != .JSXFragment) return false;
    if (n.type == .JSXElement) {
        const open = n.opening_element.?;
        const tag = open.name_node.?;
        if (tag.type != .JSXIdentifier or tag.name.len == 0) return false;
        if (!std.ascii.isLower(tag.name[0])) {
            const program = shell orelse return false;
            if (!importedComponent(program, tag.name)) return false;
        }
        for (open.attributes) |attr| {
            if (attr.type != .JSXAttribute) return false;
            const name = attr.name_node.?.name;
            if (std.mem.startsWith(u8, name, "on") or std.mem.startsWith(u8, name, "data-p") or util.eql(name, "ref")) return false;
            if (attr.value_node) |v| if (v.type != .Literal and !(v.type == .JSXExpressionContainer and simpleExpression(v.expression.?, param))) return false;
        }
    }
    for (n.children) |child| if (!simpleTree(child, param, shell)) return false;
    return true;
}
fn view(program: *N, requested: ?S, static_shell: bool) ?View {
    for (program.statements) |statement| {
        if (statement.type != .ExportNamedDeclaration) continue;
        const f = statement.declaration orelse continue;
        if (f.type != .FunctionDeclaration or f.body == null or f.id == null) continue;
        if (requested) |name| if (!util.eql(name, f.id.?.name)) continue;
        if (f.body.?.statements.len != 1 or f.params.len > 1) return null;
        const ret = f.body.?.statements[0];
        if (ret.type != .ReturnStatement or ret.argument == null) return null;
        const param = if (f.params.len == 1 and f.params[0].type == .Identifier) f.params[0].name else if (f.params.len == 0) "" else return null;
        const root = ast.unparen(ret.argument.?);
        if (static_shell and f.params.len != 0) return null;
        if (simpleTree(root, param, if (static_shell) program else null)) return .{ .root = root, .param = param };
    }
    return null;
}
pub fn isDisplayOnly(a: A, source: S, filename: S) Error!bool {
    return view(try parser.parse(a, source, filename), null, false) != null;
}
/// No local setup, incoming props, dynamic expressions, directives or helpers.
/// Imported children receive fixed props and activate at their own roots.
pub fn isStaticShell(a: A, source: S, filename: S) Error!bool {
    return view(try parser.parse(a, source, filename), null, true) != null;
}
const Edit = struct { start: usize, end: usize, text: S };
fn apply(a: A, source: S, edits: []Edit, start: usize, end: usize) Error!S {
    std.mem.sort(Edit, edits, {}, struct {
        fn less(_: void, x: Edit, y: Edit) bool {
            return x.start < y.start;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    var cursor = start;
    for (edits) |edit| {
        if (edit.start < cursor) continue;
        try out.appendSlice(a, source[cursor..edit.start]);
        try out.appendSlice(a, edit.text);
        cursor = edit.end;
    }
    try out.appendSlice(a, source[cursor..end]);
    return out.toOwnedSlice(a);
}
pub fn expand(a: A, source: S, filename: S, resolver: types.Resolver) Error!S {
    const program = try parser.parse(a, source, filename);
    var edits: std.ArrayList(Edit) = .empty;
    const Context = struct {
        a: A,
        source: S,
        filename: S,
        resolver: types.Resolver,
        program: *N,
        edits: *std.ArrayList(Edit),
        fn visit(c: @This(), n: *N) anyerror!void {
            if (n.type != .JSXElement or n.children.len != 0) return;
            const tag = n.opening_element.?.name_node.?;
            if (tag.type != .JSXIdentifier) return;
            for (c.program.statements) |statement| {
                if (statement.type != .ImportDeclaration) continue;
                const spec = statement.source.?.stringValue() orelse continue;
                if (!util.hasPjsxExtension(spec)) continue;
                for (statement.specifiers) |entry| {
                    if (entry.type != .ImportSpecifier or entry.local == null or entry.imported == null or !entry.local.?.isIdentifier(tag.name)) continue;
                    const loaded = (try c.resolver.load(c.resolver.context, c.a, c.filename, spec)) orelse continue;
                    const child_program = try parser.parse(c.a, loaded.code, loaded.filename);
                    const child = view(child_program, entry.imported.?.name, false) orelse continue;
                    var props = util.OrderedMap(S).init(c.a);
                    for (n.opening_element.?.attributes) |attr| {
                        if (attr.type != .JSXAttribute or attr.value_node == null) return;
                        var value = attr.value_node.?;
                        if (value.type == .JSXExpressionContainer) value = value.expression.?;
                        // Substitution must never repeat an effectful prop expression.
                        if (value.type != .Literal and value.type != .Identifier) return;
                        try props.put(attr.name_node.?.name, value.slice(c.source));
                    }
                    var replacements: std.ArrayList(Edit) = .empty;
                    const Replace = struct {
                        a: A,
                        param: S,
                        props: *util.OrderedMap(S),
                        edits: *std.ArrayList(Edit),
                        valid: *bool,
                        fn visit(r: @This(), node: *N) anyerror!void {
                            if (node.type != .MemberExpression or !node.object.?.isIdentifier(r.param)) return;
                            const value = r.props.get(node.property.?.name) orelse {
                                r.valid.* = false;
                                return;
                            };
                            try r.edits.append(r.a, .{ .start = node.start, .end = node.end, .text = value });
                        }
                    };
                    var valid = true;
                    try ast.walk(child.root, Replace{ .a = c.a, .param = child.param, .props = &props, .edits = &replacements, .valid = &valid }, Replace.visit);
                    if (!valid) return;
                    const text = try apply(c.a, loaded.code, replacements.items, child.root.start, child.root.end);
                    try c.edits.append(c.a, .{ .start = n.start, .end = n.end, .text = text });
                    return;
                }
            }
        }
    };
    ast.walk(program, Context{ .a = a, .source = source, .filename = filename, .resolver = resolver, .program = program, .edits = &edits }, Context.visit) catch |e| return @errorCast(e);
    return apply(a, source, edits.items, 0, source.len);
}

const Fixture = struct {
    code: S,
    fn load(context: *anyopaque, _: A, _: S, _: S) Error!?types.Source {
        const self: *@This() = @ptrCast(@alignCast(context));
        return .{ .filename = "Child.ptsx", .code = self.code };
    }
    fn resolver(self: *@This()) types.Resolver {
        return .{ .context = self, .load = load };
    }
};
test "display props lower directly to the parent binding with no child call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var child = Fixture{ .code = "export function Child(props: { value: number }) { return (<output>{props.value}</output>); }" };
    const source = "import { Child } from './Child.ptsx'; export function Parent() { let count = state(0); return <div><Child value={count} /><Child value={2} /></div>; }";
    const result = try expand(a, source, "Parent.ptsx", child.resolver());
    try std.testing.expect(std.mem.indexOf(u8, result, "<output>{count}</output><output>{2}</output>") != null);
    try std.testing.expect(try isDisplayOnly(a, child.code, "Child.ptsx"));
}
test "stateful children and effectful prop expressions retain their boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var child = Fixture{ .code = "export function Child(props: { value: number }) { let count = state(props.value); return <output>{count}</output>; }" };
    const source = "import { Child } from './Child.ptsx'; export function Parent() { return <div><Child value={count} /></div>; }";
    try std.testing.expectEqualStrings(source, try expand(a, source, "Parent.ptsx", child.resolver()));
    try std.testing.expect(!try isDisplayOnly(a, child.code, "Child.ptsx"));
    child.code = "export function Child(props: { value: number }) { return <output>{props.value}</output>; }";
    const effectful = "import { Child } from './Child.ptsx'; export function Parent() { return <div><Child value={next()} /></div>; }";
    try std.testing.expectEqualStrings(effectful, try expand(a, effectful, "Parent.ptsx", child.resolver()));
}

test "static shells may contain imported children without enabling display inlining" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "import { Counter as Child } from './Counter.ptsx'; export function Parent() { return <section><Child initial={0}/><div><Child initial={10}/></div></section>; }";
    try std.testing.expect(try isStaticShell(a, source, "Parent.ptsx"));
    try std.testing.expect(!try isDisplayOnly(a, source, "Parent.ptsx"));
    for ([_]S{
        "import { Child } from './Child.ptsx'; export function Parent(props: { initial: number }) { return <div><Child initial={props.initial}/></div>; }",
        "import { Child } from './Child.ptsx'; export function Parent() { return <div><Child initial={next()}/></div>; }",
        "import { Child } from './Child.ptsx'; export function Parent() { let count = state(0); return <div><Child initial={count}/></div>; }",
        "import { Child } from './Child.ptsx'; export function Parent() { effect(() => {}); return <div><Child initial={0}/></div>; }",
        "import { Child } from './Child.ptsx'; export function Parent() { return <div onClick={open}><Child initial={0}/></div>; }",
        "import { Child } from './Child.ptsx'; export function Parent() { return <div ref={target}><Child initial={0}/></div>; }",
        "import { Child } from './Child.ptsx'; export function Parent() { return <div data-p-store='manual'><Child initial={0}/></div>; }",
        "import { Show } from 'publr'; export function Parent() { return <div><Show when={true}>Hello</Show></div>; }",
    }) |dynamic| try std.testing.expect(!try isStaticShell(a, dynamic, "Parent.ptsx"));
}
