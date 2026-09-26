//! Lexically resolved compiler declarations. Ordinary bindings remain snapshots.
const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const util = @import("util.zig");
const err = @import("err.zig");
const Node = ast.Node;
const A = std.mem.Allocator;
const S = []const u8;
const Kind = enum { ordinary, intrinsic, namespace, helper, row, repeat_index, operation, state, derived, awaited };
const Binding = struct { kind: Kind = .ordinary, name: S = "" };
const Env = std.StringHashMap(Binding);
const Edit = struct { node: *Node, text: S };

pub const Declaration = struct { start: usize, name: S, kind: S };
pub fn inspect(a: A, source: S, filename: S) err.Error![]const Declaration {
    const program = try parser.parse(a, source, filename);
    var t = Transform{ .a = a, .source = source, .runtime = "$$publr", .filename = filename };
    var env = Env.init(a);
    _ = try t.emit(program, &env);
    return t.declarations.items;
}
pub const Options = struct { runtime_import: S = "publr/runtime", html: bool = false };
pub fn compile(a: A, source: S, filename: S, options: Options) err.Error!S {
    const program = try parser.parse(a, source, filename);
    var t = Transform{ .a = a, .source = source, .runtime = "$$publr", .filename = filename, .html = options.html };
    var index: usize = 0;
    while (std.mem.indexOf(u8, source, t.runtime) != null) : (index += 1)
        t.runtime = try std.fmt.allocPrint(a, "$$publr{d}", .{index});
    var env = Env.init(a);
    const code = try t.emit(program, &env);
    if (!t.used and !t.html) return code;
    const helper_import = if (t.used_helpers) try std.fmt.allocPrint(a, "import * as {s}DOM from \"publr/dom\";\n", .{t.runtime}) else "";
    return std.fmt.allocPrint(a, "import * as {s} from {s};\n{s}{s}", .{ t.runtime, try util.jsonString(a, options.runtime_import), helper_import, code });
}

const Transform = struct {
    a: A,
    source: S,
    runtime: S,
    filename: S,
    html: bool = false,
    used: bool = false,
    used_helpers: bool = false,
    declarations: std.ArrayList(Declaration) = .empty,

    fn fail(node: *Node, comptime message: S) err.Error {
        return err.fail("pjsx: " ++ message ++ " (at offset {d})", .{node.start});
    }
    fn pattern(self: *Transform, node: *Node, env: *Env) err.Error!void {
        if (node.type == .Identifier) return env.put(node.name, .{});
        if (node.type == .Property) return self.pattern(node.value_node.?, env);
        if (node.type == .AssignmentPattern) return self.pattern(node.left.?, env);
        for (ast.childFields(node.type)) |field| {
            if (field[1]) {
                for (ast.getList(node, field[0])) |child| if (child) |c| try self.pattern(c, env);
            } else if (ast.getSingle(node, field[0])) |child| try self.pattern(child, env);
        }
    }
    fn declare(self: *Transform, node: *Node, env: *Env) err.Error!void {
        if (node.type == .ExportNamedDeclaration or node.type == .ExportDefaultDeclaration) {
            if (node.declaration) |d| try self.declare(d, env);
        } else if (node.type == .VariableDeclaration) {
            for (node.declarations) |d| try self.pattern(d.id.?, env);
        } else if (node.type == .FunctionDeclaration or node.type == .ClassDeclaration) {
            if (node.id) |id| try self.pattern(id, env);
        } else if (node.type == .ImportDeclaration) {
            for (node.specifiers) |spec| {
                const name = spec.local.?.name;
                const is_publr = node.import_kind != .type and spec.import_kind != .type and util.eql(node.source.?.stringValue() orelse "", "publr");
                const imported = if (spec.imported) |i| i.name else "";
                const kind: Kind = if (std.mem.endsWith(u8, node.source.?.stringValue() orelse "", ".zig")) .operation else if (!is_publr) .ordinary else if (spec.type == .ImportNamespaceSpecifier) .namespace else if (intrinsic(imported)) .intrinsic else if (isHelper(imported)) .helper else .ordinary;
                try env.put(name, .{ .kind = kind, .name = if (kind == .operation) try endpoint(self.a, self.filename, node.source.?.stringValue().?, imported) else imported });
            }
        }
    }
    fn isHelper(name: S) bool {
        for ([_]S{ "Show", "Switch", "Match", "For", "Repeat" }) |item| if (util.eql(name, item)) return true;
        return false;
    }
    fn intrinsic(name: S) bool {
        for ([_]S{ "state", "derived", "awaited", "isPending", "errorOf", "refresh", "valueOf" }) |item|
            if (util.eql(name, item)) return true;
        return false;
    }
    fn callName(node: *Node, env: *Env) ?S {
        if (node.type == .Identifier) {
            const binding = env.get(node.name) orelse return null;
            return if (binding.kind == .intrinsic) binding.name else null;
        }
        if (node.type == .MemberExpression and !node.computed and node.object.?.type == .Identifier) {
            const binding = env.get(node.object.?.name) orelse return null;
            if (binding.kind == .namespace and intrinsic(node.property.?.name)) return node.property.?.name;
        }
        return null;
    }
    fn mark(self: *Transform, node: *Node, env: *Env) err.Error!void {
        const declaration = if (node.type == .ExportNamedDeclaration) node.declaration orelse return else node;
        if (declaration.type != .VariableDeclaration) return;
        for (declaration.declarations) |d| {
            const init = if (d.init) |i| ast.unparen(i) else continue;
            if (init.type != .CallExpression) continue;
            const name = callName(init.callee.?, env) orelse continue;
            const kind: Kind = if (util.eql(name, "state")) .state else if (util.eql(name, "derived")) .derived else if (util.eql(name, "awaited")) .awaited else continue;
            if (node.type == .ExportNamedDeclaration) return fail(d, "reactive bindings cannot be exported; export a reader or an action");
            if (d.id.?.type != .Identifier) return fail(d, "reactive declarations require a single identifier; destructure a snapshot separately");
            if (kind == .state and declaration.kind != .let) return fail(d, "state declarations require let");
            if (kind != .state and declaration.kind != .@"const") return fail(d, "derived and awaited declarations require const");
            try env.put(d.id.?.name, .{ .kind = kind });
            try self.declarations.append(self.a, .{ .start = d.start, .name = d.id.?.name, .kind = name });
        }
    }
    fn reactiveBinding(node: *Node, env: *Env) ?Kind {
        if (node.type != .Identifier) return null;
        const b = env.get(node.name) orelse return null;
        return switch (b.kind) {
            .state, .derived, .awaited => b.kind,
            else => null,
        };
    }
    fn hoist(self: *Transform, node: *Node, env: *Env) err.Error!void {
        if (node.isFunction() or node.type == .ClassDeclaration or node.type == .ClassExpression) return;
        if (node.type == .VariableDeclaration and node.kind == .@"var") for (node.declarations) |d| try self.pattern(d.id.?, env);
        for (ast.childFields(node.type)) |field| {
            if (field[1]) {
                for (ast.getList(node, field[0])) |child| if (child) |c| try self.hoist(c, env);
            } else if (ast.getSingle(node, field[0])) |child| try self.hoist(child, env);
        }
    }
    fn patternCode(self: *Transform, node: *Node, env: *Env) err.Error!S {
        if (node.type == .Identifier) return node.slice(self.source);
        if (node.type == .AssignmentPattern) return self.splice(node, &.{
            .{ .node = node.left.?, .text = try self.patternCode(node.left.?, env) },
            .{ .node = node.right.?, .text = try self.emit(node.right.?, env) },
        });
        if (node.type == .Property and !node.computed) return self.splice(node, &.{.{ .node = node.value_node.?, .text = try self.patternCode(node.value_node.?, env) }});
        var edits: std.ArrayList(Edit) = .empty;
        for (ast.childFields(node.type)) |field| {
            if (field[1]) {
                for (ast.getList(node, field[0])) |child| if (child) |c| try edits.append(self.a, .{ .node = c, .text = try self.patternCode(c, env) });
            } else if (ast.getSingle(node, field[0])) |child| try edits.append(self.a, .{ .node = child, .text = try self.patternCode(child, env) });
        }
        return self.splice(node, edits.items);
    }
    fn scope(self: *Transform, node: *Node, env: *Env) err.Error!S {
        var local = try env.clone();
        if (node.isFunction()) {
            if (node.id) |id| try self.pattern(id, &local);
            for (node.params) |parameter| try self.pattern(parameter, &local);
            var changes: std.ArrayList(Edit) = .empty;
            for (node.params) |parameter| {
                try changes.append(self.a, .{ .node = parameter, .text = try self.patternCode(parameter, &local) });
            }
            if (node.body) |body| try self.hoist(body, &local);
            if (node.body) |body| try changes.append(self.a, .{ .node = body, .text = try self.emit(body, &local) });
            return self.splice(node, changes.items);
        }
        if (node.type == .Program) try self.hoist(node, &local);
        for (node.statements) |statement| try self.declare(statement, &local);
        for (node.statements) |statement| try self.mark(statement, &local);
        var actions: util.StringList = .empty;
        var reactive = false;
        for (node.statements) |statement| {
            if (statement.type == .VariableDeclaration) for (statement.declarations) |declaration| {
                if (declaration.id != null and reactiveBinding(declaration.id.?, &local) != null) reactive = true;
                if (declaration.id != null and declaration.id.?.type == .Identifier and declaration.init != null and declaration.init.?.isFunction())
                    try actions.append(self.a, declaration.id.?.name);
            };
            if (statement.type == .FunctionDeclaration and statement.id != null) try actions.append(self.a, statement.id.?.name);
        }
        if (reactive and actions.items.len > 0) {
            var changes: std.ArrayList(Edit) = .empty;
            for (node.statements) |statement| {
                const code = try self.emit(statement, &local);
                const replacement = if (statement.type == .ReturnStatement) try std.fmt.allocPrint(self.a, "{s}.captureActions({{{s}}});\n{s}", .{ self.runtime, try util.join(self.a, actions.items, ","), code }) else code;
                try changes.append(self.a, .{ .node = statement, .text = replacement });
            }
            self.used = true;
            return self.splice(node, changes.items);
        }
        return self.children(node, &local);
    }
    fn emit(self: *Transform, node: *Node, env: *Env) err.Error!S {
        if (helperName(node, env)) |name| {
            const output = try self.helper(node, name, env);
            return if (self.html) std.fmt.allocPrint(self.a, "$$html.slot({d}, () => ({s}))", .{ node.start, output }) else output;
        }
        if (self.html and node.type == .JSXElement) {
            const output = try self.children(node, env);
            const offset = std.mem.indexOfScalar(u8, output, ' ') orelse std.mem.indexOfScalar(u8, output, '>') orelse return output;
            const tag_end = blk: {
                var end: usize = 1;
                while (end < output.len and output[end] != ' ' and output[end] != '>' and output[end] != '/' and output[end] != '\n') : (end += 1) {}
                break :blk end;
            };
            _ = offset;
            return std.fmt.allocPrint(self.a, "{s} data-p-site=\"{d}\"{s}", .{ output[0..tag_end], node.start, output[tag_end..] });
        }
        if (node.type == .ReturnStatement and node.argument != null) {
            const argument = ast.unparen(node.argument.?);
            if (helperName(argument, env)) |_| return std.fmt.allocPrint(self.a, "return {s};", .{try self.emit(argument, env)});
        }
        if (node.type == .Program or node.type == .BlockStatement or node.isFunction()) return self.scope(node, env);
        if (node.type == .ImportDeclaration) {
            const spec = node.source.?.stringValue() orelse "";
            if (util.eql(spec, "publr")) {
                var remaining: util.StringList = .empty;
                var runtime_names: util.StringList = .empty;
                var dom_names: util.StringList = .empty;
                for (node.specifiers) |item| {
                    if (item.type != .ImportSpecifier) return node.slice(self.source);
                    const name = item.imported.?.name;
                    if (intrinsic(name) or isHelper(name)) continue;
                    const binding = if (util.eql(name, item.local.?.name)) name else try std.fmt.allocPrint(self.a, "{s} as {s}", .{ name, item.local.?.name });
                    if (util.eql(name, "Loading")) try dom_names.append(self.a, binding) else if (util.eql(name, "effect") or util.eql(name, "ref") or util.eql(name, "portal") or util.eql(name, "unportal")) try runtime_names.append(self.a, binding) else try remaining.append(self.a, item.slice(self.source));
                }
                var lines: util.StringList = .empty;
                if (remaining.items.len > 0) try lines.append(self.a, try std.fmt.allocPrint(self.a, "import {{{s}}} from \"publr\";", .{try util.join(self.a, remaining.items, ",")}));
                if (runtime_names.items.len > 0) try lines.append(self.a, try std.fmt.allocPrint(self.a, "import {{{s}}} from \"publr/runtime\";", .{try util.join(self.a, runtime_names.items, ",")}));
                if (dom_names.items.len > 0) try lines.append(self.a, try std.fmt.allocPrint(self.a, "import {{{s}}} from \"publr/dom\";", .{try util.join(self.a, dom_names.items, ",")}));
                return util.join(self.a, lines.items, "\n");
            }
            if (!std.mem.endsWith(u8, spec, ".zig")) return node.slice(self.source);
            var lines: util.StringList = .empty;
            for (node.specifiers) |item| {
                if (item.type != .ImportSpecifier) return fail(item, "native modules require named operation imports");
                const name = item.imported.?.name;
                try lines.append(self.a, try std.fmt.allocPrint(self.a, "const {s} = (...args) => {s}Operation({s}, args);", .{ item.local.?.name, self.runtime, try util.jsonString(self.a, try endpoint(self.a, self.filename, spec, name)) }));
            }
            return std.fmt.allocPrint(self.a, "import {{ operation as {s}Operation }} from \"publr/transport\";\n{s}", .{ self.runtime, try util.join(self.a, lines.items, "\n") });
        }
        if (node.type == .ExportNamedDeclaration and node.declaration == null) {
            for (node.specifiers) |spec| if (spec.local) |local| {
                if (reactiveBinding(local, env) != null) return fail(local, "reactive bindings cannot be exported; export a reader or an action");
            };
            return node.slice(self.source);
        }
        if (node.type == .ExportDefaultDeclaration and node.declaration != null and reactiveBinding(node.declaration.?, env) != null) return fail(node, "reactive bindings cannot be exported; export a reader or an action");
        if (node.type == .ClassDeclaration or node.type == .ClassExpression) {
            var local = try env.clone();
            if (node.id) |id| try self.pattern(id, &local);
            return self.children(node, &local);
        }
        if ((node.type == .MethodDefinition or node.type == .PropertyDefinition) and !node.computed) {
            if (node.value_node) |value| return self.splice(node, &.{.{ .node = value, .text = try self.emit(value, env) }});
            return node.slice(self.source);
        }
        if (node.type == .VariableDeclarator) return self.emitDeclaration(node, env);
        if (node.type == .AssignmentExpression or node.type == .UpdateExpression) return self.assignment(node, env);
        if (node.type == .CallExpression) {
            if (callName(node.callee.?, env)) |name| return self.metadata(node, name, env);
        }
        if (node.type == .Identifier) {
            if (env.get(node.name)) |b| if (b.kind == .row) return std.fmt.allocPrint(self.a, "{s}()", .{node.name});
            if (reactiveBinding(node, env) != null) return std.fmt.allocPrint(self.a, "{s}.read()", .{node.name});
            if (callName(node, env) != null) return fail(node, "compiler intrinsics cannot be aliased as values");
        }
        if (node.type == .MemberExpression) {
            const object = ast.unparen(node.object.?);
            if (reactiveBinding(object, env)) |kind| {
                if (kind == .awaited or kind == .derived) {
                    const property = if (node.computed) node.property.?.stringValue() else node.property.?.name;
                    if (property == null) return fail(node, "dynamic payload indexing requires valueOf(binding)[key]");
                    const method: ?S = if (util.eql(property.?, "isPending")) "pending" else if (util.eql(property.?, "isError")) "isError" else if (util.eql(property.?, "error")) "error" else null;
                    if (method) |m| return std.fmt.allocPrint(self.a, "{s}.{s}()", .{ object.name, m });
                }
            }
            if (node.computed) return self.children(node, env);
            return self.splice(node, &.{.{ .node = object, .text = try self.emit(object, env) }});
        }
        if (node.type == .Property and !node.computed) {
            const value = node.value_node.?;
            if (node.shorthand and reactiveBinding(value, env) != null)
                return std.fmt.allocPrint(self.a, "{s}: {s}", .{ node.key.?.slice(self.source), try self.emit(value, env) });
            return self.splice(node, &.{.{ .node = value, .text = try self.emit(value, env) }});
        }
        if (node.type == .CatchClause or node.type == .ForStatement or node.type == .ForOfStatement or node.type == .ForInStatement) {
            var local = try env.clone();
            if (node.param) |p| try self.pattern(p, &local);
            if (node.init) |init| {
                try self.declare(init, &local);
                try self.mark(init, &local);
            }
            if (node.left) |left| {
                if (reactiveBinding(left, env) != null) return fail(left, "loop assignment targets cannot be reactive bindings; use an explicit loop-local value");
                try self.declare(left, &local);
            }
            return self.children(node, &local);
        }
        return self.children(node, env);
    }
    fn helperName(node: *Node, env: *Env) ?S {
        if (node.type != .JSXElement) return null;
        const tag = node.opening_element.?.name_node.?;
        if (tag.type != .JSXIdentifier) return null;
        const binding = env.get(tag.name) orelse return null;
        return if (binding.kind == .helper) binding.name else null;
    }
    fn helperAttribute(node: *Node, name: S) ?*Node {
        for (node.opening_element.?.attributes) |attribute| {
            if (attribute.type == .JSXAttribute and util.eql(attribute.name_node.?.name, name)) return attribute;
        }
        return null;
    }
    fn helperValue(self: *Transform, node: *Node, name: S, fallback: S, env: *Env) err.Error!S {
        const attribute = helperAttribute(node, name) orelse return fallback;
        const value = attribute.value_node orelse return "true";
        return self.emit(if (value.type == .JSXExpressionContainer) value.expression.? else value, env);
    }
    fn helperChildren(self: *Transform, node: *Node, env: *Env) err.Error!S {
        var output: std.ArrayList(u8) = .empty;
        try output.appendSlice(self.a, "<>");
        for (node.children) |child| {
            const code = try self.emit(child, env);
            try output.appendSlice(self.a, if (helperName(child, env) != null) try std.fmt.allocPrint(self.a, "{{{s}}}", .{code}) else code);
        }
        try output.appendSlice(self.a, "</>");
        return output.toOwnedSlice(self.a);
    }
    fn helper(self: *Transform, node: *Node, name: S, env: *Env) err.Error!S {
        self.used = true;
        self.used_helpers = true;
        if (util.eql(name, "Match")) return fail(node, "Match must be a direct child of Switch");
        if (util.eql(name, "Show")) {
            const keyed = try self.helperValue(node, "keyed", "false", env);
            if (!util.eql(keyed, "true") and !util.eql(keyed, "false")) return fail(node, "Show keyed must be a static boolean");
        }
        const fallback = try self.helperValue(node, "fallback", "undefined", env);
        const fallback_fn = if (util.eql(fallback, "undefined")) fallback else try std.fmt.allocPrint(self.a, "() => ({s})", .{fallback});
        if (util.eql(name, "Show")) {
            if (helperAttribute(node, "when") == null) return fail(node, "Show requires when");
            return std.fmt.allocPrint(self.a, "{s}DOM.when(() => ({s}), () => ({s}), {s}, {s})", .{ self.runtime, try self.helperValue(node, "when", "false", env), try self.helperChildren(node, env), fallback_fn, try self.helperValue(node, "keyed", "false", env) });
        }
        if (util.eql(name, "Switch")) {
            var matches: util.StringList = .empty;
            for (node.children) |child| {
                if (child.type == .JSXText and std.mem.trim(u8, child.slice(self.source), " \n\r\t").len == 0) continue;
                if (child.type == .JSXExpressionContainer and child.expression == null) continue;
                const match = helperName(child, env) orelse return fail(child, "Switch accepts direct imported Match children only");
                if (!util.eql(match, "Match") or helperAttribute(child, "when") == null) return fail(child, "Switch requires Match children with when");
                const keyed = try self.helperValue(child, "keyed", "false", env);
                if (!util.eql(keyed, "true") and !util.eql(keyed, "false")) return fail(child, "Match keyed must be a static boolean");
                try matches.append(self.a, try std.fmt.allocPrint(self.a, "{{when: () => ({s}), make: () => ({s}), keyed: {s}}}", .{ try self.helperValue(child, "when", "false", env), try self.helperChildren(child, env), try self.helperValue(child, "keyed", "false", env) }));
            }
            return std.fmt.allocPrint(self.a, "{s}DOM.choose([{s}], {s})", .{ self.runtime, try util.join(self.a, matches.items, ","), fallback_fn });
        }
        var callback: ?*Node = null;
        for (node.children) |child| {
            if (child.type == .JSXText and std.mem.trim(u8, child.slice(self.source), " \n\r\t").len == 0) continue;
            if (child.type != .JSXExpressionContainer or child.expression == null or callback != null) return fail(child, "iteration helpers require one callback child");
            callback = ast.unparen(child.expression.?);
        }
        const cb = callback orelse return fail(node, "iteration helpers require a callback");
        if (!cb.isFunction() or cb.async or cb.params.len == 0 or cb.params.len > 2) return fail(cb, "iteration callbacks require identifier parameters");
        var local = try env.clone();
        for (cb.params) |param| {
            if (param.type != .Identifier) return fail(param, "iteration callbacks require identifier parameters");
            try local.put(param.name, .{ .kind = if (util.eql(name, "For")) .row else .repeat_index });
        }
        const body = try self.emit(cb.body.?, &local);
        var params: util.StringList = .empty;
        for (cb.params) |param| try params.append(self.a, param.name);
        const function = try std.fmt.allocPrint(self.a, "({s}) => {s}", .{ try util.join(self.a, params.items, ","), body });
        if (util.eql(name, "For")) {
            if (helperAttribute(node, "each") == null) return fail(node, "For requires each");
            const keyed = try self.helperValue(node, "keyed", "true", env);
            if (!util.eql(keyed, "true") and !util.eql(keyed, "false")) return fail(node, "For keyed must be a static boolean");
            if (util.eql(keyed, "false") and helperAttribute(node, "key") != null) return fail(node, "positional For cannot have key");
            return std.fmt.allocPrint(self.a, "{s}DOM.forEach(() => ({s}), {s}, {s}, {s}, {s})", .{ self.runtime, try self.helperValue(node, "each", "[]", env), try self.helperValue(node, "key", "undefined", env), function, fallback_fn, keyed });
        }
        if (helperAttribute(node, "count") == null or cb.params.len != 1) return fail(node, "Repeat requires count and one index parameter");
        return std.fmt.allocPrint(self.a, "{s}DOM.repeat(() => ({s}), () => ({s}), {s})", .{ self.runtime, try self.helperValue(node, "from", "0", env), try self.helperValue(node, "count", "0", env), function });
    }

    fn emitDeclaration(self: *Transform, node: *Node, env: *Env) err.Error!S {
        const raw = node.init orelse return node.slice(self.source);
        const init = ast.unparen(raw);
        if (reactiveBinding(node.id.?, env) != null and init.type == .CallExpression) {
            const name = callName(init.callee.?, env) orelse return fail(init, "invalid reactive initializer");
            if (init.arguments.len == 0 or init.arguments.len > (if (util.eql(name, "awaited")) @as(usize, 2) else @as(usize, 1))) return fail(init, "state/derived take one argument; awaited accepts optional cache options");
            const arg = init.arguments[0];
            if (util.eql(name, "awaited") and arg.type != .CallExpression) return fail(arg, "awaited requires an operation call; arguments must be read synchronously");
            if (util.eql(name, "derived") and (!arg.isFunction() or arg.params.len != 0 or arg.async))
                return fail(arg, "derived requires a synchronous zero-argument function");
            const expression = try self.emit(arg, env);
            const wrapped = if (util.eql(name, "awaited")) try std.fmt.allocPrint(self.a, "() => ({s})", .{expression}) else expression;
            self.used = true;
            const id = try util.jsonString(self.a, try std.fmt.allocPrint(self.a, "{s}@{d}", .{ node.id.?.name, node.start }));
            const inputs = if (arg.type == .CallExpression) blk: {
                var arguments: util.StringList = .empty;
                for (arg.arguments) |argument| try arguments.append(self.a, try self.emit(argument, env));
                break :blk try std.fmt.allocPrint(self.a, "() => [{s}]", .{try util.join(self.a, arguments.items, ", ")});
            } else "() => []";
            const cache = if (init.arguments.len == 2) try std.fmt.allocPrint(self.a, ", cache: () => (({s}).cache)", .{try self.emit(init.arguments[1], env)}) else "";
            var identity: S = "";
            if (util.eql(name, "awaited") and arg.callee.?.type == .Identifier) {
                if (env.get(arg.callee.?.name)) |operation| if (operation.kind == .operation) {
                    identity = try std.fmt.allocPrint(self.a, ", key: () => [{s}, ({s})()]", .{ try util.jsonString(self.a, operation.name), inputs });
                };
            }
            const text = if (util.eql(name, "state")) try std.fmt.allocPrint(self.a, "{s}.state({s}, {s})", .{ self.runtime, wrapped, id }) else if (util.eql(name, "awaited")) try std.fmt.allocPrint(self.a, "{s}.awaited({s}, {{ id: {s}, inputs: {s}{s}{s} }})", .{ self.runtime, wrapped, id, inputs, cache, identity }) else try std.fmt.allocPrint(self.a, "{s}.{s}({s}, {s})", .{ self.runtime, name, wrapped, id });
            return self.splice(node, &.{.{ .node = raw, .text = text }});
        }
        return self.splice(node, &.{
            .{ .node = node.id.?, .text = try self.patternCode(node.id.?, env) },
            .{ .node = raw, .text = try self.emit(raw, env) },
        });
    }
    fn metadata(self: *Transform, node: *Node, name: S, env: *Env) err.Error!S {
        if (util.eql(name, "state") or util.eql(name, "derived") or util.eql(name, "awaited"))
            return fail(node, "state, derived and awaited must directly initialize a lexical declaration");
        if (node.arguments.len != 1 or reactiveBinding(node.arguments[0], env) == null)
            return fail(node, "async metadata requires a reactive binding identifier");
        if (util.eql(name, "refresh") and reactiveBinding(node.arguments[0], env).? != .awaited)
            return fail(node, "refresh requires an awaited binding");
        self.used = true;
        return std.fmt.allocPrint(self.a, "{s}.{s}({s})", .{ self.runtime, name, node.arguments[0].name });
    }
    fn assignment(self: *Transform, node: *Node, env: *Env) err.Error!S {
        const target = ast.unparen(if (node.type == .UpdateExpression) node.argument.? else node.left.?);
        var base = target;
        while (base.type == .MemberExpression) base = ast.unparen(base.object.?);
        if (base.type == .Identifier) {
            if (env.get(base.name)) |binding| if (binding.kind == .row or binding.kind == .repeat_index)
                return fail(target, "iteration parameters are read-only; update source state instead");
        }
        if (target.type == .MemberExpression) {
            const object = ast.unparen(target.object.?);
            if (reactiveBinding(object, env)) |k| {
                if (k == .awaited or k == .derived) {
                    const property = if (target.computed) target.property.?.stringValue() else target.property.?.name;
                    if (property == null or util.eql(property.?, "isPending") or util.eql(property.?, "isError") or util.eql(property.?, "error"))
                        return fail(target, "async metadata is read-only; use valueOf(binding) to write payload members");
                }
            }
        }
        const kind = reactiveBinding(target, env) orelse {
            if (target.type == .ObjectPattern or target.type == .ArrayPattern) return fail(target, "destructuring assignments are not supported in compiled modules");
            return self.children(node, env);
        };
        if (kind != .state) return fail(target, "cannot assign to a derived or awaited binding");
        if (node.type == .UpdateExpression)
            return std.fmt.allocPrint(self.a, "{s}.update($$value => {{ const $$result = {s}$$value{s}; return [$$value, $$result]; }})", .{ target.name, if (node.prefix) node.operator else "", if (node.prefix) "" else node.operator });
        const right = try self.emit(node.right.?, env);
        const op = node.operator;
        if (util.eql(op, "=")) return std.fmt.allocPrint(self.a, "{s}.write({s})", .{ target.name, right });
        const binary = op[0 .. op.len - 1];
        if (util.eql(binary, "&&") or util.eql(binary, "||") or util.eql(binary, "??"))
            return std.fmt.allocPrint(self.a, "({s}.read() {s} {s}.write({s}))", .{ target.name, binary, target.name, right });
        return std.fmt.allocPrint(self.a, "{s}.write({s}.read() {s} ({s}))", .{ target.name, target.name, binary, right });
    }
    fn children(self: *Transform, node: *Node, env: *Env) err.Error!S {
        var edits: std.ArrayList(Edit) = .empty;
        for (ast.childFields(node.type)) |field| {
            if (field[1]) {
                for (ast.getList(node, field[0])) |child| if (child) |c| {
                    const code = if (self.html and (node.type == .JSXElement or node.type == .JSXFragment) and c.type == .JSXExpressionContainer and c.expression != null and c.expression.?.type != .JSXEmptyExpression)
                        try std.fmt.allocPrint(self.a, "{{$$html.slot({d}, () => ({s}))}}", .{ c.start, try self.emit(c.expression.?, env) })
                    else
                        try self.emit(c, env);
                    const wrapped = if ((node.type == .JSXElement or node.type == .JSXFragment) and helperName(c, env) != null) try std.fmt.allocPrint(self.a, "{{{s}}}", .{code}) else code;
                    try edits.append(self.a, .{ .node = c, .text = wrapped });
                };
            } else if (ast.getSingle(node, field[0])) |child|
                try edits.append(self.a, .{ .node = child, .text = try self.emit(child, env) });
        }
        return self.splice(node, edits.items);
    }
    fn splice(self: *Transform, node: *Node, edits: []const Edit) err.Error!S {
        const sorted = try self.a.dupe(Edit, edits);
        std.mem.sort(Edit, sorted, {}, struct {
            fn less(_: void, l: Edit, r: Edit) bool {
                return l.node.start < r.node.start;
            }
        }.less);
        var out: std.ArrayList(u8) = .empty;
        var pos = node.start;
        for (sorted) |edit| {
            if (edit.node.start < pos) continue;
            try out.appendSlice(self.a, self.source[pos..edit.node.start]);
            try out.appendSlice(self.a, edit.text);
            pos = edit.node.end;
        }
        try out.appendSlice(self.a, self.source[pos..node.end]);
        return out.toOwnedSlice(self.a);
    }
};

pub fn endpoint(a: A, filename: S, spec: S, name: S) err.Error!S {
    const module_path = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(filename) orelse ".", spec });
    const identity = try std.fmt.allocPrint(a, "{s}:{s}", .{ module_path, name });
    return std.fmt.allocPrint(a, "/_publr/{x}/{s}", .{ std.hash.Wyhash.hash(0, identity), name });
}

test "import resolution, lexical shadows, snapshots and assignment results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try compile(arena.allocator(),
        \\import { state as mutable, derived, isPending } from "publr";
        \\function Example() {
        \\ let n = mutable(1);
        \\ const snapshot = n;
        \\ const get = () => n;
        \\ const d = derived(() => n * 2);
        \\ const object = {n};
        \\ { const n = 9; use(n); }
        \\ function shadow(n) { return n; }
        \\ n += 2; n++; ++n; n ||= 7;
        \\ return isPending(d);
        \\}
    , "Example.ptsx", .{});
    for ([_]S{ "const snapshot = n.read()", "() => n.read()", "{n: n.read()}", "const n = 9; use(n)", "function shadow(n) { return n; }", "n.write(n.read() + (2))", "n.update($$value => { const $$result = $$value++; return [$$value, $$result]; })", "n.update($$value => { const $$result = ++$$value; return [$$value, $$result]; })", "(n.read() || n.write(7))", "$$publr.isPending(d)" }) |part|
        try std.testing.expect(std.mem.indexOf(u8, out, part) != null);
}

test "declaration diagnostics reject silently incorrect forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]S{
        "import {state} from 'publr'; const x = state(0);",
        "import {state} from 'publr'; let {x} = state({x:0});",
        "import {state} from 'publr'; export let x = state(0);",
        "import {derived} from 'publr'; const x = derived(() => 0); x++;",
        "import {state} from 'publr'; const alias = state;",
        "import {state} from 'publr'; use(state(0));",
    }) |source| try std.testing.expectError(error.Pjsx, compile(arena.allocator(), source, "bad.ptsx", .{}));
}

test "ordinary spelling and shadowed intrinsics retain JavaScript meaning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "import {state} from 'another-package'; function f(state) { let x = state(0); return x; }";
    try std.testing.expectEqualStrings(source, try compile(arena.allocator(), source, "plain.ts", .{}));
}
