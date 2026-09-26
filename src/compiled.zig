//! Universal compiled components: native calls, blocking HTML, and browser state transfer.
const std = @import("std");
const compiler = @import("compiler.zig");
const util = @import("util.zig");
const err = @import("err.zig");
const intrinsic = @import("intrinsics.zig");
const A = std.mem.Allocator;
const S = []const u8;
const E = compiler.ExpressionIR;
const N = compiler.NodeIR;
const Error = err.Error || std.Io.Writer.Error;

pub fn lowerDOM(a: A, module: *const compiler.ModuleIR) Error!S {
    return lowerTarget(a, module, false, null);
}
pub fn lower(a: A, module: *const compiler.ModuleIR) Error!S {
    return lowerTarget(a, module, true, null);
}
pub fn lowerWithResolver(a: A, module: *const compiler.ModuleIR, resolver: @import("types.zig").Resolver) Error!S {
    return lowerTarget(a, module, true, resolver);
}
fn lowerTarget(a: A, module: *const compiler.ModuleIR, html_mode: bool, resolver: ?@import("types.zig").Resolver) Error!S {
    const static_only = html_mode and try @import("inline_html.zig").isStaticShell(a, module.source, module.filename);
    var g = Generator{ .a = a, .module = module, .out = .init(a), .locals = .init(a), .metadata = .init(a), .html = html_mode and !static_only, .static_only = static_only, .resolver = resolver };
    const canonical = try @import("canonicalize.zig").canonicalize(a, module.source);
    g.declarations = try intrinsic.inspect(a, canonical.code, module.filename);
    for (module.component.props.values()) |prop| {
        if (prop.optional and prop.default == null) return err.failMsg("pjsx: native JSON props require scalar defaults for optional fields; undefined is not transferable");
        if (prop.default_expression != null and prop.default == null) return err.failMsg("pjsx: native prop defaults must be scalar literals");
    }
    const parsed = try @import("analyze.zig").parsePjsx(a, module.source, module.filename);
    if (parsed.component.fn_node.body) |body| for (body.statements) |statement| {
        switch (statement.type) {
            .ReturnStatement => break,
            .VariableDeclaration => for (statement.declarations) |declaration| {
                if (declaration.id == null or declaration.id.?.type != .Identifier or declaration.init == null)
                    return err.failMsg("pjsx: native declarations require initialized identifier bindings");
            },
            .FunctionDeclaration, .EmptyStatement => {},
            .ExpressionStatement => {
                const expression = statement.expression orelse return err.failMsg("pjsx: unsupported native statement");
                if (expression.type != .CallExpression or expression.callee == null or expression.callee.?.type != .Identifier)
                    return err.failMsg("pjsx: native setup supports declarations and client effects; move imperative work into an action");
                const name = g.resolve(expression.callee.?.name, "publr") orelse return err.failMsg("pjsx: browser-only setup must be inside effect");
                if (!util.eql(name, "effect")) return err.failMsg("pjsx: browser-only setup must be inside effect");
            },
            else => return err.failMsg("pjsx: unsupported native setup statement"),
        }
    };
    try g.generate();
    return g.out.written();
}
const Generator = struct {
    a: A,
    module: *const compiler.ModuleIR,
    out: std.Io.Writer.Allocating,
    locals: util.OrderedMap(S),
    metadata: util.StringSet,
    html: bool = false,
    static_only: bool = false,
    next: usize = 0,
    instance: S = "instance_id",
    declarations: []const intrinsic.Declaration = &.{},
    resolver: ?@import("types.zig").Resolver = null,
    fn write(g: *Generator, comptime fmt: S, args: anytype) Error!void {
        try g.out.writer.print(fmt, args);
    }
    fn quote(g: *Generator, value: S) Error!S {
        return util.jsonString(g.a, value);
    }
    fn fresh(g: *Generator) Error!S {
        g.next += 1;
        return std.fmt.allocPrint(g.a, "v{d}", .{g.next});
    }
    fn fail(comptime message: S) Error {
        return err.failMsg("pjsx: native compiled target: " ++ message);
    }
    fn resolve(g: *Generator, name: S, source: S) ?S {
        for (g.module.component.imports) |import| {
            if (!util.eql(import.source, source)) continue;
            for (import.names) |entry| if (!entry.type_only and util.eql(entry.local, name)) return entry.imported;
        }
        return null;
    }
    fn declarationKind(g: *Generator, expression: *const E) ?S {
        if (expression.* == .call and expression.call.callee.* == .reference) {
            if (g.resolve(expression.call.callee.reference.name, "publr")) |name| {
                if (util.eql(name, "mutation")) return name;
            }
        }
        for (g.module.component.locals) |local| {
            if (local.value != expression) continue;
            for (g.declarations) |declaration| if (declaration.start == local.start) return declaration.kind;
        }
        return null;
    }
    fn importedStore(g: *Generator, name: S) Error!S {
        const resolver = g.resolver orelse return fail("unknown local or browser-only expression");
        for (g.module.component.imports) |import| {
            for (import.names) |entry| {
                if (entry.type_only or !util.eql(entry.local, name)) continue;
                const loaded = (try resolver.load(resolver.context, g.a, g.module.filename, import.source)) orelse return fail("shared store module could not be resolved");
                const tree = try @import("parser.zig").parse(g.a, loaded.code, loaded.filename);
                var create_name: ?S = null;
                for (tree.statements) |statement| {
                    if (statement.type != .ImportDeclaration or statement.source == null or !util.eql(statement.source.?.stringValue() orelse "", "publr")) continue;
                    for (statement.specifiers) |spec| {
                        if (spec.imported != null and spec.local != null and util.eql(spec.imported.?.name, "createStore")) create_name = spec.local.?.name;
                    }
                }
                for (tree.statements) |statement| {
                    if (statement.type != .ExportNamedDeclaration) continue;
                    const declaration = statement.declaration orelse continue;
                    if (declaration.type != .VariableDeclaration) continue;
                    for (declaration.declarations) |decl| {
                        if (decl.id == null or !util.eql(decl.id.?.name, entry.imported)) continue;
                        const call = decl.init orelse return fail("shared store needs an initializer");
                        if (call.type != .CallExpression or call.callee == null or create_name == null or !util.eql(call.callee.?.name, create_name.?) or call.arguments.len != 2) return fail("native shared stores require createStore(name, factory)");
                        const factory = call.arguments[1];
                        if (factory.type != .ArrowFunctionExpression or factory.params.len != 0) return fail("native shared store factory must have no parameters");
                        var body = factory.body orelse return fail("shared store factory has no body");
                        while (body.type == .ParenthesizedExpression) body = body.expression orelse return fail("empty store factory");
                        if (body.type != .ObjectExpression) return fail("native shared store factory must return an object expression");
                        for (body.properties) |property| {
                            if (property.key == null or !util.eql(property.key.?.name, "state")) continue;
                            const value = property.value_node orelse return fail("shared store state is missing");
                            const source = try std.fmt.allocPrint(g.a, "export function StoreSeed() {{ const seed = {s}; return <div />; }}", .{value.slice(loaded.code)});
                            const seed = try compiler.createPjsxModule(g.a, source, "StoreSeed.ptsx");
                            const initial = seed.component.locals[0].value;
                            if (!staticStoreState(initial)) return fail("native shared store initial state must contain only literal data");
                            return g.emitExpression(initial);
                        }
                        return fail("shared store state is missing");
                    }
                }
            }
        }
        return fail("unknown local or browser-only expression");
    }
    fn staticStoreState(value: *const E) bool {
        return switch (value.*) {
            .literal => true,
            .object => |object| blk: {
                for (object.fields) |field| if (!staticStoreState(field.value)) break :blk false;
                break :blk true;
            },
            else => false,
        };
    }
    fn generate(g: *Generator) Error!void {
        try g.write("// Generated by PJSX. Native imports keep their authored relative paths.\nconst std = @import(\"std\");\nconst rt = @import(\"compiled_runtime\");\nconst V = rt.Value;\n", .{});
        try g.write("pub fn render(w: *std.Io.Writer, arena: std.mem.Allocator, ctx: anytype, props: V, instance_id: []const u8) !void {{\n_ = &ctx; _ = &instance_id; try rt.validate(props);\n", .{});
        var ids: util.StringList = .empty;
        var values: util.StringList = .empty;
        var cache_ids: util.StringList = .empty;
        var cache_values: util.StringList = .empty;
        for (g.module.component.locals) |binding| {
            if (binding.value.* == .function) continue;
            if (binding.value.* == .call and binding.value.call.callee.* == .reference) {
                if (g.resolve(binding.value.call.callee.reference.name, "publr")) |name| if (util.eql(name, "ref")) continue;
            }
            var value = binding.value;
            const kind = g.declarationKind(value);
            if (kind) |name| {
                if (value.call.arguments.len == 0 or value.call.arguments.len > (if (util.eql(name, "awaited")) @as(usize, 2) else @as(usize, 1))) return fail("invalid declaration options");
                if (util.eql(name, "derived")) {
                    const function = value.call.arguments[0];
                    if (function.* != .function or function.function.parameters.len != 0) return fail("derived takes a zero-argument function");
                    value = function.function.body;
                } else if (util.eql(name, "state") or util.eql(name, "awaited")) value = value.call.arguments[0];
            }
            const local = try g.fresh();
            // Mutations are idle during server rendering; never evaluate their callback.
            const code = if (kind != null and util.eql(kind.?, "mutation"))
                "try rt.object(arena, &.{\"isPending\", \"isError\", \"error\", \"value\"}, &.{V{ .bool = false }, V{ .bool = false }, V.null, V.null})"
            else try g.emitExpression(value);
            if (kind != null and util.eql(kind.?, "awaited") and std.mem.startsWith(u8, code, "try rt.native(")) {
                const resolved = try g.fresh();
                try g.write("const {s} = try rt.nativeResult{s};\nconst {s}: V = {s}.value; _ = &{s};\n", .{ resolved, code["try rt.native".len..], local, resolved, local });
                var options: S = "V.null";
                if (binding.value.call.arguments.len == 2) {
                    const second = binding.value.call.arguments[1];
                    if (second.* != .object) return fail("native awaited options require an object");
                    for (second.object.fields) |field| if (util.eql(field.name, "cache")) {
                        options = try g.emitExpression(field.value);
                    };
                }
                var identity: S = "V.null";
                const call = value.call;
                for (g.module.component.imports) |import| {
                    if (!std.mem.endsWith(u8, import.source, ".zig")) continue;
                    for (import.names) |entry| if (util.eql(entry.local, call.callee.reference.name)) {
                        var args: util.StringList = .empty;
                        for (call.arguments) |arg| try args.append(g.a, try g.emitExpression(arg));
                        identity = try std.fmt.allocPrint(g.a, "try rt.array(arena, &.{{V{{ .string = {s} }}, try rt.array(arena, &.{{{s}}})}})", .{ try g.quote(try intrinsic.endpoint(g.a, g.module.filename, import.source, entry.imported)), try util.join(g.a, args.items, ",") });
                    };
                }
                try cache_ids.append(g.a, try g.quote(binding.name));
                try cache_values.append(g.a, try std.fmt.allocPrint(g.a, "try rt.transferCache(arena, ctx, {s}.policy, {s}, {s})", .{ resolved, identity, options }));
            } else try g.write("const {s}: V = {s}; _ = &{s};\n", .{ local, code, local });
            try g.locals.put(binding.name, local);
            if (kind) |name| if (util.eql(name, "awaited") or util.eql(name, "derived")) {
                try g.metadata.put(local, {});
            };
            if (kind) |name| if (util.eql(name, "state") or util.eql(name, "awaited")) {
                if (util.eql(binding.name, "$props") or util.eql(binding.name, "$cache")) return fail("$props and $cache are reserved seed metadata names");
                if (util.eql(name, "state") and reconstructible(value)) continue;
                try ids.append(g.a, try g.quote(binding.name));
                try values.append(g.a, local);
            };
        }
        const root = g.module.component.root;
        const helper_root = root.* == .element and root.element.name == .component and g.resolve(root.element.name.component.name, "publr") != null;
        if (root.* != .fragment and (root.* != .element or root.element.name != .intrinsic) and !helper_root)
            return fail("native components require an intrinsic, fragment or structural helper root");
        try g.write("const initial_values = try rt.object(arena, &.{{{s}}}, &.{{{s}}});\nconst initial_cache = try rt.object(arena, &.{{{s}}}, &.{{{s}}});\nconst initial_seed = try rt.componentSeed(arena, initial_values, props, initial_cache);\n_ = &initial_seed;\n", .{ try util.join(g.a, ids.items, ","), try util.join(g.a, values.items, ","), try util.join(g.a, cache_ids.items, ","), try util.join(g.a, cache_values.items, ",") });
        if (helper_root) {
            try g.static("<template data-p-root-start");
            try g.rootAttributes();
            try g.static("></template>");
        }
        try g.node(root);
        if (helper_root) {
            try g.static("<template");
            try g.static(" data-p-root-end");
            try g.static("></template>");
        }
        try g.write("}}\n", .{});
        try g.dispatch();
        try g.write("pub fn writeTypes(w: *std.Io.Writer, module: []const u8) !bool {{\n_ = &w; _ = &module;\n", .{});
        for (g.module.component.imports) |import| {
            if (!std.mem.endsWith(u8, import.source, ".zig")) continue;
            try g.write("if (std.mem.eql(u8, module, {s})) {{\n", .{try g.quote(import.source)});
            for (import.names) |entry| try g.write("try rt.types(w, @import({s}).{s}, {s});\n", .{ try g.quote(import.source), entry.imported, try g.quote(entry.imported) });
            try g.write("return true;\n}}\n", .{});
        }
        try g.write("return false;\n}}\n", .{});
    }
    fn nativeCall(g: *Generator, call: @FieldType(E, "call")) Error!?S {
        if (call.callee.* != .reference) return null;
        const name = call.callee.reference.name;
        for (g.module.component.imports) |import| {
            if (!std.mem.endsWith(u8, import.source, ".zig")) continue;
            for (import.names) |entry| if (util.eql(entry.local, name)) {
                var args: util.StringList = .empty;
                for (call.arguments) |arg| try args.append(g.a, try g.emitExpression(arg));
                return try std.fmt.allocPrint(g.a, "try rt.native(@import({s}).{s}, ctx, arena, &.{{{s}}})", .{ try g.quote(import.source), entry.imported, try util.join(g.a, args.items, ",") });
            };
        }
        return null;
    }
    fn dispatch(g: *Generator) Error!void {
        try g.write("pub const operations = [_]struct {{ path: []const u8, module: []const u8, name: []const u8 }}{{\n", .{});
        for (g.module.component.locals) |binding| {
            const kind = g.declarationKind(binding.value) orelse continue;
            if (!util.eql(kind, "awaited")) continue;
            const call = binding.value.call.arguments[0];
            if (call.* != .call or call.call.callee.* != .reference) continue;
            for (g.module.component.imports) |import| {
                if (!std.mem.endsWith(u8, import.source, ".zig")) continue;
                for (import.names) |entry| if (util.eql(entry.local, call.call.callee.reference.name)) {
                    try g.write(".{{ .path = {s}, .module = {s}, .name = {s} }},\n", .{ try g.quote(try intrinsic.endpoint(g.a, g.module.filename, import.source, entry.imported)), try g.quote(import.source), try g.quote(entry.imported) });
                };
            }
        }
        try g.write("}};\n", .{});
        try g.write("pub fn dispatch(w: *std.Io.Writer, arena: std.mem.Allocator, ctx: anytype, path: []const u8, arguments: V) !bool {{\n_ = &w; _ = &arena; _ = &ctx; _ = &path; _ = &arguments;\n", .{});
        for (g.module.component.imports) |import| {
            if (!std.mem.endsWith(u8, import.source, ".zig")) continue;
            for (import.names) |entry| {
                // Only awaited declarations expose repeatable native operations.
                var exposed = false;
                for (g.module.component.locals) |binding| {
                    const kind = g.declarationKind(binding.value) orelse continue;
                    if (!util.eql(kind, "awaited")) continue;
                    const call = binding.value.call.arguments[0];
                    if (call.* == .call and call.call.callee.* == .reference and util.eql(call.call.callee.reference.name, entry.local)) exposed = true;
                }
                if (!exposed) continue;
                const path = try intrinsic.endpoint(g.a, g.module.filename, import.source, entry.imported);
                try g.write("if (std.mem.eql(u8, path, {s})) {{\nconst result = try rt.nativeResult(@import({s}).{s}, ctx, arena, try rt.items(arguments));\ntry rt.publishPolicy(ctx, result.policy);\ntry rt.json(w, arena, result.value);\nreturn true;\n}}\n", .{ try g.quote(path), try g.quote(import.source), entry.imported });
            }
        }
        try g.write("return false;\n}}\n", .{});
    }
    fn emitExpression(g: *Generator, expression: *const E) Error!S {
        return switch (expression.*) {
            .literal => |literal| switch (literal) {
                .null => "V.null",
                .string => |value| try std.fmt.allocPrint(g.a, "V{{ .string = {s} }}", .{try g.quote(value)}),
                .number => |value| try std.fmt.allocPrint(g.a, "V{{ .float = {d} }}", .{value}),
                .boolean => |value| if (value) "V{ .bool = true }" else "V{ .bool = false }",
            },
            .reference => |reference| if (reference.source == .prop) blk: {
                const key = try g.quote(reference.name);
                if (g.module.component.props.get(reference.name)) |prop| if (prop.default) |default| {
                    const fallback: E = .{ .literal = switch (default) {
                        .string => |v| .{ .string = v },
                        .number => |v| .{ .number = v },
                        .boolean => |v| .{ .boolean = v },
                    } };
                    break :blk try std.fmt.allocPrint(g.a, "(if (props == .object and props.object.contains({s})) try rt.get(props, {s}) else {s})", .{ key, key, try g.emitExpression(&fallback) });
                };
                break :blk try std.fmt.allocPrint(g.a, "try rt.get(props, {s})", .{key});
            } else g.locals.get(reference.name) orelse try g.importedStore(reference.name),
            .member => |member| blk: {
                const property: ?S = if (member.property == .string) member.property.string else if (member.property == .expression and member.property.expression.* == .literal and member.property.expression.literal == .string) member.property.expression.literal.string else null;
                if (property) |p| {
                    if (member.object.* == .reference and g.metadata.has(g.locals.get(member.object.reference.name) orelse "")) {
                        if (util.eql(p, "isPending") or util.eql(p, "isError")) break :blk "V{ .bool = false }";
                        if (util.eql(p, "error")) break :blk "V.null";
                    }
                    break :blk try std.fmt.allocPrint(g.a, "try rt.get({s}, {s})", .{ try g.emitExpression(member.object), try g.quote(p) });
                }
                const key = if (member.property == .expression) try g.emitExpression(member.property.expression) else try std.fmt.allocPrint(g.a, "V{{ .float = {d} }}", .{member.property.number});
                break :blk try std.fmt.allocPrint(g.a, "try rt.indexed(arena, {s}, {s})", .{ try g.emitExpression(member.object), key });
            },
            .operation => |operation| try g.emitOperation(operation),
            .unary => |unary| if (util.eql(unary.operator, "!"))
                try std.fmt.allocPrint(g.a, "V{{ .bool = !rt.truthy({s}) }}", .{try g.emitExpression(unary.argument)})
            else if (util.eql(unary.operator, "-")) try std.fmt.allocPrint(g.a, "V{{ .float = -(try rt.number({s})) }}", .{try g.emitExpression(unary.argument)}) else return fail("unsupported unary operator"),
            .conditional => |conditional| try std.fmt.allocPrint(g.a, "(if (rt.truthy({s})) {s} else {s})", .{ try g.emitExpression(conditional.@"test"), try g.emitExpression(conditional.consequent), try g.emitExpression(conditional.alternate) }),
            .array => |array| blk: {
                var items: util.StringList = .empty;
                for (array.items) |item| try items.append(g.a, try g.emitExpression(item));
                break :blk try std.fmt.allocPrint(g.a, "try rt.array(arena, &.{{{s}}})", .{try util.join(g.a, items.items, ",")});
            },
            .object => |object| blk: {
                var keys: util.StringList = .empty;
                var values: util.StringList = .empty;
                for (object.fields) |field| {
                    try keys.append(g.a, try g.quote(field.name));
                    try values.append(g.a, try g.emitExpression(field.value));
                }
                break :blk try std.fmt.allocPrint(g.a, "try rt.object(arena, &.{{{s}}}, &.{{{s}}})", .{ try util.join(g.a, keys.items, ","), try util.join(g.a, values.items, ",") });
            },
            .call => |call| blk: {
                if (call.callee.* == .member and call.callee.member.property == .string and (util.eql(call.callee.member.property.string, "map") or util.eql(call.callee.member.property.string, "filter"))) {
                    if (call.arguments.len != 1 or call.arguments[0].* != .function or call.arguments[0].function.parameters.len != 1) return fail("derived map requires one identifier parameter");
                    const function = call.arguments[0].function;
                    const source = try g.emitExpression(call.callee.member.object);
                    const previous = try g.locals.clone();
                    defer g.locals = previous;
                    const item = try g.fresh();
                    const label = try g.fresh();
                    try g.locals.put(function.parameters[0], item);
                    const result = try g.emitExpression(function.body);
                    if (util.eql(call.callee.member.property.string, "filter")) break :blk try std.fmt.allocPrint(g.a, "{s}: {{ var results: std.array_list.Managed(V) = .init(arena); for (try rt.items({s})) |{s}| {{ if (rt.truthy({s})) try results.append({s}); }} break :{s} V{{ .array = results }}; }}", .{ label, source, item, result, item, label });
                    break :blk try std.fmt.allocPrint(g.a, "{s}: {{ var results: std.array_list.Managed(V) = .init(arena); for (try rt.items({s})) |{s}| {{ try results.append({s}); }} break :{s} V{{ .array = results }}; }}", .{ label, source, item, result, label });
                }
                if (call.callee.* == .member and call.callee.member.property == .string) {
                    const member = call.callee.member;
                    const method = member.property.string;
                    if (member.object.* == .reference and util.eql(member.object.reference.name, "Math") and (util.eql(method, "min") or util.eql(method, "max"))) {
                        var args: util.StringList = .empty;
                        for (call.arguments) |arg| try args.append(g.a, try g.emitExpression(arg));
                        break :blk try std.fmt.allocPrint(g.a, "try rt.math({s}, &.{{{s}}})", .{ try g.quote(method), try util.join(g.a, args.items, ",") });
                    }
                    for ([_]S{ "includes", "startsWith", "endsWith", "toLowerCase", "toUpperCase", "trim" }) |allowed| if (util.eql(method, allowed)) {
                        var args: util.StringList = .empty;
                        for (call.arguments) |arg| try args.append(g.a, try g.emitExpression(arg));
                        break :blk try std.fmt.allocPrint(g.a, "try rt.stringMethod(arena, {s}, {s}, &.{{{s}}})", .{ try g.quote(method), try g.emitExpression(member.object), try util.join(g.a, args.items, ",") });
                    };
                }
                if (try g.nativeCall(call)) |code| break :blk code;
                if (call.callee.* == .reference) {
                    const name = g.resolve(call.callee.reference.name, "publr") orelse return fail("SSR awaited expressions must call an imported native .zig operation");
                    if (util.eql(name, "isPending")) break :blk "V{ .bool = false }";
                    if (util.eql(name, "errorOf")) break :blk "V.null";
                    if (util.eql(name, "valueOf") and call.arguments.len == 1) break :blk try g.emitExpression(call.arguments[0]);
                }
                return fail("unsupported call in native SSR");
            },
            else => return fail("unsupported expression in native SSR"),
        };
    }
    fn emitOperation(g: *Generator, operation: @FieldType(E, "operation")) Error!S {
        const left = try g.emitExpression(operation.left);
        const right = try g.emitExpression(operation.right);
        const op = operation.operator;
        if (util.eql(op, "&&") or util.eql(op, "||") or util.eql(op, "??")) {
            const local = try g.fresh();
            const test_expr = if (util.eql(op, "??")) try std.fmt.allocPrint(g.a, "{s} != .null", .{local}) else try std.fmt.allocPrint(g.a, "{s}rt.truthy({s})", .{ if (util.eql(op, "&&")) "!" else "", local });
            return std.fmt.allocPrint(g.a, "blk: {{ const {s} = {s}; break :blk if ({s}) {s} else {s}; }}", .{ local, left, test_expr, local, right });
        }
        for ([_]S{ "+", "-", "*", "/", "%", "===", "!==", "<", ">", "<=", ">=" }) |allowed| if (util.eql(op, allowed))
            return std.fmt.allocPrint(g.a, "try rt.binary(arena, {s}, {s}, {s})", .{ try g.quote(op), left, right });
        return fail("unsupported binary operator");
    }
    fn static(g: *Generator, text: S) Error!void {
        try g.write("try w.writeAll({s});\n", .{try g.quote(text)});
    }
    fn reconstructible(value: *const E) bool {
        return switch (value.*) {
            .literal => true,
            .reference => |ref| ref.source == .prop,
            .array => |array_value| blk: {
                for (array_value.items) |item| if (!reconstructible(item)) break :blk false;
                break :blk true;
            },
            .object => |object_value| blk: {
                for (object_value.fields) |field| if (!reconstructible(field.value)) break :blk false;
                break :blk true;
            },
            else => false,
        };
    }
    fn rootAttributes(g: *Generator) Error!void {
        if (g.static_only) return;
        try g.write("try rt.attribute(w, arena, \"data-p-store\", .{{ .string = {s} }});\nif (initial_seed.object.count() > 0) {{\nvar seed_json: std.Io.Writer.Allocating = .init(arena);\ntry rt.json(&seed_json.writer, arena, initial_seed);\ntry rt.attribute(w, arena, \"data-p\", .{{ .string = seed_json.written() }});\n}}\n", .{try g.quote(try storeName(g.a, g.module))});
    }
    fn attributeValue(element: @FieldType(N, "element"), name: S) ?*const E {
        for (element.attributes) |attribute| if (attribute == .attribute and util.eql(attribute.attribute.name, name)) return attribute.attribute.value;
        return null;
    }
    fn helperChildren(g: *Generator, children: []const *const N) Error!void {
        try g.static("<!--p:fragment-->");
        for (children) |child| try g.node(child);
        try g.static("<!--/p:fragment-->");
    }
    fn helper(g: *Generator, name: S, element: @FieldType(N, "element")) Error!void {
        if (util.eql(name, "Show")) {
            const condition = attributeValue(element, "when") orelse return fail("Show requires when");
            try g.static("<!--p:when-->");
            try g.write("if (rt.truthy({s})) {{\n", .{try g.emitExpression(condition)});
            try g.helperChildren(element.children);
            if (attributeValue(element, "fallback")) |fallback| {
                try g.write("}} else {{\n", .{});
                try g.emitChild(fallback);
            }
            try g.write("}}\n", .{});
            return g.static("<!--/p:when-->");
        }
        if (util.eql(name, "Switch")) {
            try g.static("<!--p:when-->");
            var first = true;
            for (element.children) |child| {
                if (child.* == .text and std.mem.trim(u8, child.text.value, " \n\r\t").len == 0) continue;
                if (child.* != .element or child.element.name != .component) return fail("Switch accepts direct Match children");
                const match = g.resolve(child.element.name.component.name, "publr") orelse return fail("Switch accepts imported Match children");
                if (!util.eql(match, "Match")) return fail("Switch accepts Match children");
                const condition = attributeValue(child.element, "when") orelse return fail("Match requires when");
                try g.write("{s}if (rt.truthy({s})) {{\n", .{ if (first) "" else " else ", try g.emitExpression(condition) });
                try g.helperChildren(child.element.children);
                try g.write("}}", .{});
                first = false;
            }
            if (attributeValue(element, "fallback")) |fallback| {
                if (!first) try g.write(" else {{\n", .{});
                try g.emitChild(fallback);
                if (!first) try g.write("}}\n", .{});
            }
            return g.static("<!--/p:when-->");
        }
        if (!util.eql(name, "For") and !util.eql(name, "Repeat")) return fail("Match must be inside Switch");
        var callback: ?*const E = null;
        for (element.children) |child| {
            if (child.* == .text and std.mem.trim(u8, child.text.value, " \n\r\t").len == 0) continue;
            if (child.* != .expression or child.expression.value.* != .function or callback != null) return fail("iteration helpers require one callback");
            callback = child.expression.value;
        }
        const function = (callback orelse return fail("iteration helper requires callback")).function;
        if (function.parameters.len == 0 or function.parameters.len > 2) return fail("iteration requires one or two identifier parameters");
        const previous_instance = g.instance;
        defer g.instance = previous_instance;
        const previous = try g.locals.clone();
        defer g.locals = previous;
        const source = try g.fresh();
        const item = try g.fresh();
        const index = try g.fresh();
        const key_local = try g.fresh();
        if (util.eql(name, "For")) {
            const each = attributeValue(element, "each") orelse return fail("For requires each");
            try g.write("const {s} = try rt.optionalItems({s});\n", .{ source, try g.emitExpression(each) });
            try g.static("<!--p:when-->");
            try g.write("if ({s}.len > 0) {{\n", .{source});
            try g.static("<!--p:list-->");
            const keys = try g.fresh();
            try g.write("var {s}: std.StringHashMap(void) = .init(arena);\nfor ({s}, 0..) |{s}, {s}| {{\n_ = &{s}; _ = &{s};\n", .{ keys, source, item, index, item, index });
            try g.locals.put(function.parameters[0], item);
            if (function.parameters.len > 1) try g.locals.put(function.parameters[1], try std.fmt.allocPrint(g.a, "V{{ .integer = @intCast({s}) }}", .{index}));
            var positional = false;
            if (attributeValue(element, "keyed")) |keyed| {
                if (keyed.* != .literal or keyed.literal != .boolean) return fail("For keyed must be a static boolean");
                positional = !keyed.literal.boolean;
            }
            var key_code = item;
            if (attributeValue(element, "key")) |key| {
                if (positional) return fail("positional For cannot have key");
                if (key.* != .function or key.function.parameters.len != 1) return fail("For key requires one identifier parameter");
                const before = try g.locals.clone();
                try g.locals.put(key.function.parameters[0], item);
                key_code = try g.emitExpression(key.function.body);
                g.locals = before;
            } else if (positional) key_code = try std.fmt.allocPrint(g.a, "V{{ .integer = @intCast({s}) }}", .{index});
            try g.write("const {s}: V = {s};\ntry rt.uniqueKey(arena, &{s}, {s});\ntry rt.row(w, arena, {s}, false);\n", .{ key_local, key_code, keys, key_local, key_local });
            g.instance = try std.fmt.allocPrint(g.a, "try rt.childInstance(arena, {s}, {s})", .{ previous_instance, key_local });
            try g.emitCallback(function);
            g.instance = previous_instance;
            try g.write("try rt.row(w, arena, {s}, true);\n}}\n", .{key_local});
            try g.static("<!--/p:list-->");
            if (attributeValue(element, "fallback")) |fallback| {
                try g.write("}} else {{\n", .{});
                g.locals = previous;
                try g.emitChild(fallback);
            }
            try g.write("}}\n", .{});
            return g.static("<!--/p:when-->");
        }
        if (function.parameters.len != 1) return fail("Repeat requires one index parameter");
        const count = attributeValue(element, "count") orelse return fail("Repeat requires count");
        const from = if (attributeValue(element, "from")) |value| try g.emitExpression(value) else "V{ .integer = 0 }";
        try g.write("const {s} = try rt.window({s}, {s});\n", .{ source, from, try g.emitExpression(count) });
        try g.static("<!--p:list-->");
        try g.write("for ({s}[0]..{s}[1]) |{s}| {{\nconst {s}: V = .{{ .integer = @intCast({s}) }};\ntry rt.row(w, arena, {s}, false);\n", .{ source, source, index, key_local, index, key_local });
        try g.locals.put(function.parameters[0], key_local);
        g.instance = try std.fmt.allocPrint(g.a, "try rt.childInstance(arena, {s}, {s})", .{ previous_instance, key_local });
        try g.emitCallback(function);
        try g.write("try rt.row(w, arena, {s}, true);\n}}\n", .{key_local});
        return g.static("<!--/p:list-->");
    }

    fn emitCallback(g: *Generator, function: @FieldType(E, "function")) Error!void {
        for (function.locals) |binding| {
            var value = binding.value;
            if (value.* == .function) continue;
            if (value.* == .call and value.call.callee.* == .reference) {
                if (g.resolve(value.call.callee.reference.name, "publr")) |name| {
                    if (util.eql(name, "ref")) continue;
                    if (util.eql(name, "awaited")) return fail("put row-local native awaited declarations in a child component for scoped result transfer");
                    if (util.eql(name, "state")) value = value.call.arguments[0];
                    if (util.eql(name, "derived")) value = value.call.arguments[0].function.body;
                }
            }
            const local = try g.fresh();
            try g.write("const {s}: V = {s}; _ = &{s};\n", .{ local, try g.emitExpression(value), local });
            try g.locals.put(binding.name, local);
        }
        try g.emitChild(function.body);
    }

    fn node(g: *Generator, node_ir: *const N) Error!void {
        const component = (g.html or g.static_only) and node_ir.* == .element and node_ir.element.name == .component;
        if (component) try g.static(try std.fmt.allocPrint(g.a, "<!--p:html:{d}-->", .{node_ir.element.site}));
        try g.nodeContents(node_ir);
        if (component) try g.static(try std.fmt.allocPrint(g.a, "<!--/p:html:{d}-->", .{node_ir.element.site}));
    }
    fn nodeContents(g: *Generator, node_ir: *const N) Error!void {
        switch (node_ir.*) {
            .text => |text| try g.write("try rt.escape(w, {s});\n", .{try g.quote(text.value)}),
            .fragment => |fragment| {
                const root = node_ir == g.module.component.root;
                if (root) {
                    try g.static("<p-fragment style=\"display:contents\"");
                    try g.rootAttributes();
                    try g.static(">");
                } else try g.static("<!--p:fragment-->");
                for (fragment.children) |child| try g.node(child);
                try g.static(if (root) "</p-fragment>" else "<!--/p:fragment-->");
            },
            .expression => |expression| {
                if (g.html or g.static_only) try g.static(try std.fmt.allocPrint(g.a, "<!--p:html:{d}-->", .{expression.site}));
                try g.emitChild(expression.value);
                if (g.html or g.static_only) try g.static(try std.fmt.allocPrint(g.a, "<!--/p:html:{d}-->", .{expression.site}));
            },
            .element => |element| {
                if (element.name == .component) {
                    const name = g.resolve(element.name.component.name, "publr") orelse {
                        for (g.module.component.imports) |import| {
                            if (!std.mem.endsWith(u8, import.source, ".ptsx") and !std.mem.endsWith(u8, import.source, ".pjsx")) continue;
                            for (import.names) |entry| if (util.eql(entry.local, element.name.component.name)) {
                                if (element.children.len != 0) return fail("native child slots must be explicit props in this profile");
                                var keys: util.StringList = .empty;
                                var values: util.StringList = .empty;
                                for (element.attributes) |attribute| if (attribute == .attribute) {
                                    const attr = attribute.attribute;
                                    if (std.mem.startsWith(u8, attr.name, "on") or attr.value.* == .function) continue;
                                    try keys.append(g.a, try g.quote(attr.name));
                                    try values.append(g.a, try g.emitExpression(attr.value));
                                };
                                const path = try std.fmt.allocPrint(g.a, "{s}.zig", .{import.source[0 .. import.source.len - 5]});
                                const id = try g.fresh();
                                try g.write("try @import({s}).render(w, arena, ctx, try rt.object(arena, &.{{{s}}}, &.{{{s}}}), try std.fmt.allocPrint(arena, \"{{s}}/{s}\", .{{{s}}}));\n", .{ try g.quote(path), try util.join(g.a, keys.items, ","), try util.join(g.a, values.items, ","), id, g.instance });
                                return;
                            };
                        }
                        return fail("unresolved native component import");
                    };
                    if (!util.eql(name, "Loading")) return g.helper(name, element);
                    try g.static("<!--p:loading-->");
                    for (element.children) |child| try g.node(child);
                    try g.static("<!--/p:loading-->");
                    return;
                }
                if (element.name != .intrinsic) return fail("dynamic component tags are unsupported");
                const tag = element.name.intrinsic.name;
                try g.static(try std.fmt.allocPrint(g.a, "<{s}", .{tag}));
                const text_binding = g.html and element.children.len == 1 and element.children[0].* == .expression and scalarChild(element.children[0].expression.value);
                if (text_binding) try g.write("try rt.attribute(w, arena, \"data-p-text\", .{{ .string = {s} }});\n", .{try g.quote(try std.fmt.allocPrint(g.a, "$v{d}", .{element.children[0].expression.site}))});
                var class_parts: util.StringList = .empty;
                var dynamic_class = false;
                if (g.html) for (element.attributes) |attribute| {
                    if (attribute == .attribute and util.eql(attribute.attribute.name, "class")) {
                        try class_parts.append(g.a, try g.emitExpression(attribute.attribute.value));
                        if (attribute.attribute.form == .expression and attribute.attribute.value.* != .literal) dynamic_class = true;
                    }
                };
                if (g.html) {
                    var events: util.StringList = .empty;
                    var bindings: util.StringList = .empty;
                    if (dynamic_class) try bindings.append(g.a, try std.fmt.allocPrint(g.a, "class:$p{d}_class", .{element.site}));
                    for (element.attributes) |attribute| {
                        const index = switch (attribute) {
                            inline else => |entry| entry.source_index,
                        };
                        const binding = try std.fmt.allocPrint(g.a, "p{d}_{d}", .{ element.site, index });
                        if (attribute == .event) {
                            const event = attribute.event;
                            try events.append(g.a, try std.fmt.allocPrint(g.a, "{s}{s}{s}:{s}", .{ event.event, if (event.modifiers.len > 0) "." else "", try util.join(g.a, event.modifiers, "."), event.action_name orelse (if (event.form == .literal and event.value.* == .literal and event.value.literal == .string) event.value.literal.string else binding) }));
                        } else if (attribute == .attribute) {
                            const attr = attribute.attribute;
                            if (util.eql(attr.name, "class")) continue;
                            if (std.mem.startsWith(u8, attr.name, "on")) {
                                try events.append(g.a, try std.fmt.allocPrint(g.a, "{s}:{s}", .{ try util.eventDescriptor(g.a, attr.name), attr.action_name orelse binding }));
                            } else if (util.eql(attr.name, "ref")) {
                                try g.write("try rt.attribute(w, arena, \"data-p-ref\", .{{ .string = {s} }});\n", .{try g.quote(binding)});
                            } else if (!util.eql(attr.name, "key") and attr.form == .expression and attr.value.* != .literal) {
                                try bindings.append(g.a, try std.fmt.allocPrint(g.a, "{s}:${s}", .{ if (util.eql(attr.name, "portal")) "data-p-portal" else if (util.eql(attr.name, "position")) "data-p-position" else attr.name, binding }));
                            }
                        }
                    }
                    if (events.items.len > 0) try g.write("try rt.attribute(w, arena, \"data-p-on\", .{{ .string = {s} }});\n", .{try g.quote(try util.join(g.a, events.items, ";"))});
                    if (bindings.items.len > 0) try g.write("try rt.attribute(w, arena, \"data-p-bind\", .{{ .string = {s} }});\n", .{try g.quote(try util.join(g.a, bindings.items, ";"))});
                }
                if (g.html and class_parts.items.len > 0) try g.write("try rt.attribute(w, arena, \"class\", try rt.className(arena, try rt.array(arena, &.{{{s}}})));\n", .{try util.join(g.a, class_parts.items, ",")});
                for (element.attributes) |attribute| {
                    if (attribute != .attribute) continue;
                    const attr = attribute.attribute;
                    if (g.html and util.eql(attr.name, "class")) continue;
                    if (util.eql(attr.name, "key") or util.eql(attr.name, "ref") or std.mem.startsWith(u8, attr.name, "on")) continue;
                    if (node_ir == g.module.component.root) {
                        for ([_]S{ "data-p", "data-p-component", "data-p-instance", "data-p-store", "data-p-state", "data-p-html", "data-p-site" }) |reserved|
                            if (util.eql(attr.name, reserved)) return fail("component root hydration attributes are reserved for compiler output");
                    }
                    // Ref-backed directives are connected by the browser companion.
                    // Native rendering must not evaluate browser-only element refs.
                    if ((util.eql(attr.name, "portal") or util.eql(attr.name, "position")) and attr.form == .expression and attr.value.* != .literal) {
                        try g.write("try rt.attribute(w, arena, {s}, .{{ .bool = true }});\n", .{try g.quote(if (util.eql(attr.name, "portal")) "data-p-portal" else "data-p-position")});
                        continue;
                    }
                    try g.write("try rt.attribute(w, arena, {s}, {s});\n", .{ try g.quote(if (util.eql(attr.name, "portal")) "data-p-portal" else if (util.eql(attr.name, "anchor")) "data-p-anchor" else if (util.eql(attr.name, "position")) "data-p-position" else attr.name), try g.emitExpression(attr.value) });
                }
                if (node_ir == g.module.component.root) try g.rootAttributes();
                try g.static(">");
                if (text_binding) {
                    try g.write("try rt.text(w, arena, {s});\n", .{try g.emitExpression(element.children[0].expression.value)});
                } else for (element.children) |child| try g.node(child);
                for ([_]S{ "input", "img", "br", "hr", "meta", "link", "area", "base", "embed", "source", "track", "wbr", "col", "param" }) |void_tag| if (util.eql(tag, void_tag)) return;
                try g.static(try std.fmt.allocPrint(g.a, "</{s}>", .{tag}));
            },
        }
    }
    fn scalarChild(value: *const E) bool {
        return switch (value.*) {
            .node, .function, .array, .object => false,
            .conditional => |v| scalarChild(v.consequent) and scalarChild(v.alternate),
            .operation => |v| scalarChild(v.left) and scalarChild(v.right),
            .call => |v| blk: {
                if (v.callee.* == .member and v.callee.member.property == .string and util.eql(v.callee.member.property.string, "map")) break :blk false;
                for (v.arguments) |arg| if (!scalarChild(arg)) break :blk false;
                break :blk true;
            },
            else => true,
        };
    }
    fn emitChild(g: *Generator, value: *const E) Error!void {
        if (g.static_only) {
            try g.write("try rt.text(w, arena, {s});\n", .{try g.emitExpression(value)});
            return;
        }
        if (value.* == .node) return g.node(value.node.node);
        if (value.* == .operation and util.eql(value.operation.operator, "&&") and value.operation.right.* == .node) {
            try g.static("<!--p:when-->");
            try g.write("if (rt.truthy({s})) {{\n", .{try g.emitExpression(value.operation.left)});
            try g.emitChild(value.operation.right);
            try g.write("}}\n", .{});
            try g.static("<!--/p:when-->");
            return;
        }

        if (value.* == .call and value.call.callee.* == .member and value.call.callee.member.property == .string and util.eql(value.call.callee.member.property.string, "map")) return g.list(value.call);
        if (value.* == .conditional and (value.conditional.consequent.* == .node or value.conditional.alternate.* == .node)) {
            try g.static("<!--p:when-->");
            try g.write("if (rt.truthy({s})) {{\n", .{try g.emitExpression(value.conditional.@"test")});
            try g.emitChild(value.conditional.consequent);
            try g.write("}} else {{\n", .{});
            try g.emitChild(value.conditional.alternate);
            try g.write("}}\n", .{});
            try g.static("<!--/p:when-->");
            return;
        }
        if (value.* == .literal and (value.literal == .string or value.literal == .number)) {
            try g.write("try rt.text(w, arena, {s});\n", .{try g.emitExpression(value)});
            return;
        }
        try g.static("<!--p:insert-->");
        try g.write("try rt.text(w, arena, {s});\n", .{try g.emitExpression(value)});
        try g.static("<!--/p:insert-->");
    }
    fn list(g: *Generator, call: @FieldType(E, "call")) Error!void {
        if (call.arguments.len != 1 or call.arguments[0].* != .function) return fail("map requires one callback");
        const function = call.arguments[0].function;
        if (function.parameters.len != 1 or function.body.* != .node or function.body.node.node.* != .element) return fail("keyed maps require a single identifier and an element body");
        const source = try g.emitExpression(call.callee.member.object);
        const item = try g.fresh();
        const previous = try g.locals.clone();
        defer g.locals = previous;
        try g.locals.put(function.parameters[0], item);
        var key: ?*const E = null;
        for (function.body.node.node.element.attributes) |attribute| if (attribute == .attribute and util.eql(attribute.attribute.name, "key")) {
            key = attribute.attribute.value;
        };
        const key_code = try g.emitExpression(key orelse return fail("native lists require an explicit key"));
        const previous_instance = g.instance;
        defer g.instance = previous_instance;
        g.instance = try std.fmt.allocPrint(g.a, "try rt.childInstance(arena, {s}, {s})", .{ previous_instance, key_code });
        try g.static("<!--p:list-->");
        try g.write("for (try rt.items({s})) |{s}| {{\ntry rt.row(w, arena, {s}, false);\n", .{ source, item, key_code });
        try g.node(function.body.node.node);
        try g.write("try rt.row(w, arena, {s}, true);\n}}\n", .{key_code});
        try g.static("<!--/p:list-->");
    }
};

test "native operations generate SSR, seeded identities and only declared read endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try compiler.createPjsxModule(a,
        \\import {state as mutable, awaited, derived, Loading} from "publr";
        \\import {users, save} from "./backend.zig";
        \\export function Users(props: {search: string}) {
        \\ let search = mutable(props.search);
        \\ const rows = awaited(users(search));
        \\ const names = derived(() => rows.map(row => row.name));
        \\ return <><Loading fallback={<i>Wait</i>}><ul>{rows.map(row => <li key={row.id}>{row.name}</li>)}</ul></Loading></>;
        \\}
    , "Users.ptsx");
    const code = try lower(a, module);
    for ([_]S{ "rt.nativeResult(@import(\"./backend.zig\").users", "data-p", "p:loading", "p:list", "rt.componentSeed", "pub fn dispatch", "rows" }) |part|
        try std.testing.expect(std.mem.indexOf(u8, code, part) != null);
    try std.testing.expect(std.mem.indexOf(u8, code, ").save") == null);
}

pub fn storeName(a: A, module: *const compiler.ModuleIR) Error!S {
    return std.fmt.allocPrint(a, "{s}_{x}", .{ module.component.name, std.hash.Wyhash.hash(0, module.filename) });
}
pub fn behaviorDOM(a: A, module: *const compiler.ModuleIR) Error!S {
    return std.fmt.allocPrint(a, "import {{createLocalStore}} from \"publr\";\nimport {{localComponent}} from \"publr/dom\";\nimport {{{s}}} from \"./{s}.js\";\ncreateLocalStore({s}, localComponent({s}));\n", .{ module.component.name, std.fs.path.stem(std.fs.path.basename(module.filename)), try util.jsonString(a, try storeName(a, module)), module.component.name });
}

test "native roots require an explicit host and reserve their hydration attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]S{
        "import {Loading} from 'publr'; export function Root() { return <Loading><b>one</b></Loading>; }",
        "export function Root() { return <div data-p-store='custom' />; }",
    }) |source| {
        const module = try compiler.createPjsxModule(a, source, "Root.ptsx");
        try std.testing.expectError(error.Pjsx, lower(a, module));
    }
}

pub fn behavior(a: A, module: *const compiler.ModuleIR) Error!S {
    return @import("html.zig").behavior(a, module);
}

test "native imported shared store reads literal initial state without running browser actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct {
        source: S,
        fn load(context: *anyopaque, _: A, _: S, _: S) err.Error!?@import("types.zig").Source {
            const self: *@This() = @ptrCast(@alignCast(context));
            return .{ .filename = "shared.ts", .code = self.source };
        }
    };
    var fixture = Fixture{ .source = "import {createStore as shared} from 'publr'; export const counter = shared('Counter', () => ({state: {count: 7}, actions: ({state}) => ({increment() {state.count++;}})}));" };
    const resolver: @import("types.zig").Resolver = .{ .context = &fixture, .load = Fixture.load };
    const module = try compiler.createPjsxModule(a, "import {counter as sharedCount} from './shared'; export function Counter() { return <output>{sharedCount.count}</output>; }", "Counter.ptsx");
    const code = try lowerWithResolver(a, module, resolver);
    try std.testing.expect(std.mem.indexOf(u8, code, ".float = 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "data-p-text") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "createStore") == null);
    fixture.source = "import {createStore} from 'publr'; export const counter = createStore('Counter', () => ({state: {count: window.start}}));";
    try std.testing.expectError(error.Pjsx, lowerWithResolver(a, module, resolver));
}

test "display-only composition shares parent HTML bindings and preserves stateful children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct {
        fn load(_: *anyopaque, _: A, _: S, _: S) err.Error!?@import("types.zig").Source {
            return .{ .filename = "Display.ptsx", .code = "export function Display(props: { value: number }) { return (<output>{props.value}</output>); }" };
        }
    };
    var context: u8 = 0;
    const resolver = @import("types.zig").Resolver{ .context = &context, .load = Fixture.load };
    const module = try compiler.createPjsxModuleWithResolver(a, "import { state } from 'publr'; import { Display } from './Display.ptsx'; export function Parent() { let count = state(0); function increment() { count++; } return <div><button onClick={increment}>Increment</button><Display value={count}/></div>; }", "Parent.ptsx", resolver);
    const native = try lowerWithResolver(a, module, resolver);
    const companion = try behavior(a, module);
    try std.testing.expect(std.mem.indexOf(u8, native, "Display.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, native, "data-p-text") != null);
    try std.testing.expect(std.mem.indexOf(u8, companion, "$$html.child(") == null);
    try std.testing.expect(std.mem.indexOf(u8, companion, "() => count.read()") != null);
    const static_module = try compiler.createPjsxModuleWithResolver(a, "import { Display } from './Display.ptsx'; export function Parent() { return <div><Display value={3}/></div>; }", "StaticParent.ptsx", resolver);
    const static_native = try lowerWithResolver(a, static_module, resolver);
    try std.testing.expect(std.mem.indexOf(u8, static_native, "data-p-store") == null);
    try std.testing.expect(std.mem.indexOf(u8, try behavior(a, static_module), "$$html.register(") == null);
}

test "static parent leaves native child boundaries intact without its own store" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try compiler.createPjsxModule(a, "import { Counter } from './Counter.ptsx'; export function Parent() { return <section><Counter initial={0}/><Counter initial={10}/></section>; }", "Parent.ptsx");
    const native = try lower(a, module);
    const companion = try behavior(a, module);
    try std.testing.expect(std.mem.indexOf(u8, native, "data-p-store") == null);
    try std.testing.expect(std.mem.indexOf(u8, native, "data-p-component") == null);
    try std.testing.expect(std.mem.indexOf(u8, native, "Counter.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, companion, "$$html.register(") == null);
    try std.testing.expect(std.mem.indexOf(u8, companion, "Counter.behavior.js") != null);
    const child = try compiler.createPjsxModule(a, "import { state } from 'publr'; export function Counter(props: { initial: number }) { let count = state(props.initial); function increment() { count++; } return <div><output>{count}</output><button onClick={increment}>Increment</button></div>; }", "Counter.ptsx");
    try std.testing.expect(std.mem.indexOf(u8, try lower(a, child), "data-p-store") != null);
    try std.testing.expect(std.mem.indexOf(u8, try behavior(a, child), "$$html.register(") != null);
}

test "mutation rendering is idle and never evaluates its write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try compiler.createPjsxModule(a,
        \\import { mutation as createMutation } from "publr";
        \\import { savePerson } from "./write";
        \\export function Save() {
        \\ const saving = createMutation(async () => await savePerson());
        \\ function save() { saving(); }
        \\ return (<button onClick={save} disabled={saving.isPending}>{saving.isError ? "Failed" : saving.value ? "Saved" : "Save"}</button>);
        \\}
    , "Save.ptsx");
    const code = try lower(a, module);
    try std.testing.expect(std.mem.indexOf(u8, code, "savePerson") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "isPending") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "V{ .bool = false }") != null);
}
