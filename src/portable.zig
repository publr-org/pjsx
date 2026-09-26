//! Public portable target SDK. Prepare once, then hand the same typed program
//! to each emitter. Version 1's mandatory scalar profile is deliberately explicit:
//! accepted expressions preserve JS semantics; unsupported features diagnose.
const std = @import("std");
const compiler = @import("compiler.zig");
const analyze = @import("analyze.zig");
const ast = @import("ast.zig");
const util = @import("util.zig");
const err = @import("err.zig");
const zig = @import("targets/zig.zig");

pub const semantics = @import("runtime/semantics.zig");
pub const api_version: u32 = 1;
pub const profile = "publr-portable/scalars/1";
pub const server_profile = "publr-php/server/1";
pub const Error = err.Error || std.Io.Writer.Error;
const Expr = compiler.ExpressionIR;
const Node = compiler.NodeIR;

pub const Type = struct {
    kind: enum { number, string, boolean, undefined, null, node, function },
    optional: bool = false,
};

/// Resolved operations: a community emitter never needs to guess what '+'
/// means or whether a logical operand is evaluated eagerly.
pub const Operation = enum {
    number_add,
    number_subtract,
    number_multiply,
    number_divide,
    number_remainder,
    number_min,
    number_max,
    string_concat,
    equal,
    not_equal,
    number_less,
    number_less_equal,
    number_greater,
    number_greater_equal,
    logical_and,
    logical_or,
    nullish,
};

pub const Target = struct {
    name: []const u8,
    api: u32 = api_version,
    semantics_version: u32 = semantics.version,
    compile: *const fn (std.mem.Allocator, *const Program, Options) Error![]const u8,
};

pub const Options = struct { runtime_import: []const u8 = "publr/dom" };

pub const Program = struct {
    module: *const compiler.ModuleIR,
    /// PHP document/composition and scalar local-store extension; not scalar certification.
    server_extensions: bool = false,
    types: std.AutoHashMapUnmanaged(*const Expr, Type) = .empty,
    operations: std.AutoHashMapUnmanaged(*const Expr, Operation) = .empty,
    locals: util.OrderedMap(Type),
    allocator: std.mem.Allocator,
    active_helpers: util.OrderedMap(bool),
    signatures: util.OrderedMap([]const Type),

    /// Stable external SDK envelope. Paths address the embedded IR; numeric
    /// payloads use binary64 tags and annotations carry resolved operation kinds.
    pub fn writeJson(p: *const Program, w: *std.Io.Writer) Error!void {
        try w.print("{{\"targetApi\":{d},\"semanticsVersion\":{d},\"profile\":\"{s}\",\"ir\":", .{ api_version, semantics.version, if (p.server_extensions) server_profile else profile });
        try compiler.writeLosslessJson(p.allocator, p.module, w);
        try w.writeAll(",\"expressions\":[");
        var first = true;
        for (p.module.component.locals, 0..) |local, i| try p.annotate(w, local.value, try util.fmt(p.allocator, "/component/locals/{d}/value", .{i}), &first);
        try p.annotateNode(w, p.module.component.root, "/component/root", &first);
        try w.writeAll("]}");
    }

    fn annotate(p: *const Program, w: *std.Io.Writer, e: *const Expr, pointer: []const u8, first: *bool) Error!void {
        if (p.types.get(e)) |t| {
            if (!first.*) try w.writeByte(',');
            first.* = false;
            try w.writeAll("{\"path\":");
            try std.json.Stringify.value(pointer, .{}, w);
            try w.writeAll(",\"type\":");
            try std.json.Stringify.value(t, .{}, w);
            if (p.operations.get(e)) |op| {
                try w.writeAll(",\"operation\":");
                try std.json.Stringify.value(op, .{}, w);
            }
            try w.writeByte('}');
        }
        switch (e.*) {
            .unary => |u| try p.annotate(w, u.argument, try util.concat(p.allocator, &.{ pointer, "/argument" }), first),
            .operation => |o| {
                try p.annotate(w, o.left, try util.concat(p.allocator, &.{ pointer, "/left" }), first);
                try p.annotate(w, o.right, try util.concat(p.allocator, &.{ pointer, "/right" }), first);
            },
            .conditional => |c| {
                try p.annotate(w, c.@"test", try util.concat(p.allocator, &.{ pointer, "/test" }), first);
                try p.annotate(w, c.consequent, try util.concat(p.allocator, &.{ pointer, "/consequent" }), first);
                try p.annotate(w, c.alternate, try util.concat(p.allocator, &.{ pointer, "/alternate" }), first);
            },
            .template => |t| for (t.parts, 0..) |part, i| {
                if (part == .expression) try p.annotate(w, part.expression, try util.fmt(p.allocator, "{s}/parts/{d}", .{ pointer, i }), first);
            },
            .call => |c| for (c.arguments, 0..) |arg, i| try p.annotate(w, arg, try util.fmt(p.allocator, "{s}/arguments/{d}", .{ pointer, i }), first),
            .function => |f| try p.annotate(w, f.body, try util.concat(p.allocator, &.{ pointer, "/body" }), first),
            .node => |n| try p.annotateNode(w, n.node, try util.concat(p.allocator, &.{ pointer, "/node" }), first),
            else => {},
        }
    }

    fn annotateNode(p: *const Program, w: *std.Io.Writer, node_ir: *const Node, pointer: []const u8, first: *bool) Error!void {
        switch (node_ir.*) {
            .expression => |e| try p.annotate(w, e.value, try util.concat(p.allocator, &.{ pointer, "/value" }), first),
            .element => |el| {
                for (el.attributes, 0..) |attr, i| try p.annotate(w, attr.value(), try util.fmt(p.allocator, "{s}/attributes/{d}/value", .{ pointer, i }), first);
                for (el.children, 0..) |child, i| try p.annotateNode(w, child, try util.fmt(p.allocator, "{s}/children/{d}", .{ pointer, i }), first);
            },
            .fragment => |f| for (f.children, 0..) |child, i| try p.annotateNode(w, child, try util.fmt(p.allocator, "{s}/children/{d}", .{ pointer, i }), first),
            .text => {},
        }
    }

    pub fn emit(program: *const Program, target: Target, options: Options) Error![]const u8 {
        if (target.api != api_version or target.semantics_version != semantics.version)
            return err.fail("pjsx: {s}: incompatible portable target {s} (API {d}, semantics {d})", .{ program.module.filename, target.name, target.api, target.semantics_version });
        if (program.server_extensions and !util.eql(target.name, "php")) return program.fail("server extension on a scalar-only target");
        return target.compile(program.allocator, program, options);
    }

    fn fail(p: *const Program, feature: []const u8) Error {
        return err.fail("pjsx: {s}: {s}: unsupported {s}", .{ p.module.filename, if (p.server_extensions) server_profile else profile, feature });
    }

    pub fn stateInitial(p: *const Program, e: *const Expr) ?*const Expr {
        if (!p.server_extensions or e.* != .member) return null;
        const family = p.module.component.family orelse return null;
        const m = e.member;
        if (m.object.* != .reference or !util.eql(m.object.reference.name, family.state) or m.property != .string) return null;
        for (family.initial) |field| if (util.eql(field.field, m.property.string)) return field.value;
        return null;
    }

    pub fn componentFile(p: *const Program, name: []const u8) ?[]const u8 {
        for (p.module.component.imports) |entry| {
            if (!util.hasPjsxExtension(entry.source)) continue;
            for (entry.names) |binding| if (!binding.type_only and util.eql(binding.local, name)) return entry.source;
        }
        return null;
    }

    fn expr(p: *Program, e: *const Expr) Error!Type {
        if (p.types.get(e)) |t| return t;
        const t: Type = switch (e.*) {
            .literal => |v| .{ .kind = switch (v) {
                .number => .number,
                .string => .string,
                .boolean => .boolean,
                .null => .null,
            } },
            .absent => .{ .kind = .undefined },
            .reference => |r| blk: {
                if (r.source == .prop) {
                    const prop = p.module.component.props.get(r.name) orelse return p.fail("unknown prop");
                    break :blk try p.propType(prop);
                }
                if (p.locals.get(r.name)) |t| break :blk t;
                if (util.eql(r.name, "NaN") or util.eql(r.name, "Infinity")) break :blk .{ .kind = .number };
                return p.fail(try util.fmt(p.allocator, "reference '{s}'", .{r.name}));
            },
            .member => blk: {
                const initial = p.stateInitial(e) orelse return p.fail("unsupported state member");
                break :blk try p.expr(initial);
            },
            .unary => |u| blk: {
                const argument = try p.expr(u.argument);
                if (util.eql(u.operator, "!")) break :blk .{ .kind = .boolean };
                if (util.eql(u.operator, "-") and argument.kind == .number and !argument.optional) break :blk argument;
                return p.fail("unary operation");
            },
            .operation => |o| blk: {
                const left = try p.expr(o.left);
                const right = try p.expr(o.right);
                var op: Operation = undefined;
                var result = left;
                if (util.eql(o.operator, "&&") or util.eql(o.operator, "||")) {
                    op = if (util.eql(o.operator, "&&")) .logical_and else .logical_or;
                    if (right.kind == .node and op == .logical_and) result = right else if (left.kind != right.kind) return p.fail("logical operands with different value types") else result.optional = left.optional or right.optional;
                } else if (util.eql(o.operator, "??")) {
                    op = .nullish;
                    if (left.kind == .null or left.kind == .undefined) result = right else if (left.kind != right.kind) return p.fail("nullish operands with different value types") else result.optional = right.optional;
                } else if (util.eql(o.operator, "===") or util.eql(o.operator, "!==")) {
                    op = if (util.eql(o.operator, "===")) .equal else .not_equal;
                    if (left.kind != right.kind or left.optional or right.optional) return p.fail("strict equality across optional or different value types");
                    result = .{ .kind = .boolean };
                } else if (left.kind == .number and right.kind == .number and !left.optional and !right.optional) {
                    op = if (util.eql(o.operator, "+")) .number_add else if (util.eql(o.operator, "-")) .number_subtract else if (util.eql(o.operator, "*")) .number_multiply else if (util.eql(o.operator, "/")) .number_divide else if (util.eql(o.operator, "%")) .number_remainder else if (util.eql(o.operator, "<")) .number_less else if (util.eql(o.operator, "<=")) .number_less_equal else if (util.eql(o.operator, ">")) .number_greater else if (util.eql(o.operator, ">=")) .number_greater_equal else return p.fail("numeric operator");
                    if (op == .number_less or op == .number_less_equal or op == .number_greater or op == .number_greater_equal) result = .{ .kind = .boolean };
                } else if (left.kind == .string and right.kind == .string and !left.optional and !right.optional and util.eql(o.operator, "+")) {
                    op = .string_concat;
                } else return p.fail("operator requiring implicit coercion");
                try p.operations.put(p.allocator, e, op);
                break :blk result;
            },
            .conditional => |c| blk: {
                _ = try p.expr(c.@"test");
                const yes = try p.expr(c.consequent);
                const no = try p.expr(c.alternate);
                if (yes.kind != no.kind) {
                    if (yes.kind == .null or yes.kind == .undefined) break :blk .{ .kind = no.kind, .optional = true };
                    if (no.kind == .null or no.kind == .undefined) break :blk .{ .kind = yes.kind, .optional = true };
                    return p.fail("conditional branches with different value types");
                }
                break :blk .{ .kind = yes.kind, .optional = yes.optional or no.optional };
            },
            .template => |t| blk: {
                for (t.parts) |part| if (part == .expression) {
                    const value = try p.expr(part.expression);
                    if (value.optional or (value.kind != .number and value.kind != .string)) return p.fail("template interpolation of non-number/string values");
                };
                break :blk .{ .kind = .string };
            },
            .function => .{ .kind = .function },
            .call => |c| blk: {
                if (c.callee.* == .reference) {
                    const name = c.callee.reference.name;
                    if ((p.locals.get(name) orelse return p.fail("unknown helper")).kind != .function) return p.fail("call of a non-function");
                    for (p.module.component.locals) |local| {
                        if (!util.eql(local.name, name) or local.value.* != .function) continue;
                        if (p.active_helpers.has(name)) return p.fail("recursive helper");
                        const f = local.value.function;
                        if (f.parameters.len != c.arguments.len) return p.fail("helper argument count");
                        const args = try p.allocator.alloc(Type, c.arguments.len);
                        for (c.arguments, 0..) |arg, i| args[i] = try p.expr(arg);
                        if (p.signatures.get(name)) |known| {
                            for (known, args) |x, y| if (!std.meta.eql(x, y)) return p.fail("polymorphic helper");
                        } else try p.signatures.put(name, args);
                        const saved = p.locals;
                        p.locals = try saved.clone();
                        defer p.locals = saved;
                        try p.active_helpers.put(name, true);
                        defer p.active_helpers.remove(name);
                        for (f.parameters, args) |parameter, arg| try p.locals.put(parameter, arg);
                        const result = try p.expr(f.body);
                        if (result.kind == .node or result.kind == .function) return p.fail("helper returning a node or function");
                        break :blk result;
                    }
                    return p.fail("helper alias");
                }
                if (c.callee.* != .member) return p.fail("function call");
                const m = c.callee.member;
                if (m.object.* != .reference or !util.eql(m.object.reference.name, "Math") or p.locals.has("Math") or m.object.reference.source == .prop or m.property != .string or
                    (!util.eql(m.property.string, "min") and !util.eql(m.property.string, "max")) or c.arguments.len != 2) return p.fail("function call");
                for (c.arguments) |arg| {
                    const value = try p.expr(arg);
                    if (value.kind != .number or value.optional) return p.fail("non-numeric Math operand");
                }
                try p.operations.put(p.allocator, e, if (util.eql(m.property.string, "min")) .number_min else .number_max);
                break :blk .{ .kind = .number };
            },
            .node => |n| blk: {
                try p.node(n.node);
                break :blk .{ .kind = .node };
            },
            else => return p.fail(try util.fmt(p.allocator, "expression {s}", .{@tagName(e.*)})),
        };
        try p.types.put(p.allocator, e, t);
        return t;
    }

    fn propType(p: *Program, prop: analyze.PropSchema) Error!Type {
        if (prop.nullable) return p.fail("nullable prop contract");
        const kind: @FieldType(Type, "kind") = switch (prop.type) {
            .number, .optional_number => .number,
            .string, .optional_string => .string,
            .boolean, .optional_boolean => .boolean,
            else => return p.fail("non-scalar prop contract"),
        };
        if (prop.default_expression != null and prop.default == null) return p.fail("executable parameter default");
        return .{ .kind = kind, .optional = (prop.optional or prop.type == .optional_number or prop.type == .optional_string or prop.type == .optional_boolean) and prop.default == null };
    }

    fn node(p: *Program, n: *const Node) Error!void {
        switch (n.*) {
            .text => {},
            .expression => |e| {
                if ((try p.expr(e.value)).kind == .function) return p.fail("function as child");
            },
            .fragment => |f| for (f.children) |child| try p.node(child),
            .element => |element| {
                if (element.name != .intrinsic) {
                    if (!p.server_extensions or element.name != .component or p.componentFile(element.name.component.name) == null) return p.fail("unresolved component call");
                    if (element.children.len != 0) return p.fail("component children (use explicit scalar props)");
                    for (element.attributes) |attribute| {
                        if (attribute != .attribute) return p.fail("component directive");
                        const t = try p.expr(attribute.value());
                        if (t.kind == .node or t.kind == .function) return p.fail("non-scalar component prop");
                    }
                    return;
                }
                const tag = element.name.intrinsic.name;
                if (util.eql(tag, "script")) {
                    var external = false;
                    for (element.attributes) |attr| if (attr == .attribute and util.eql(attr.attribute.name, "src") and attr.value().* == .literal and attr.value().literal == .string and attr.value().literal.string.len > 0) {
                        external = true;
                    };
                    if (!p.server_extensions or !external or element.children.len != 0) return p.fail("inline script (use an external script)");
                }
                if (util.eql(tag, "style") or util.eql(tag, "svg") or util.eql(tag, "math")) return p.fail("raw-text or foreign-namespace element");
                for (element.attributes) |attribute| {
                    if (attribute != .attribute) return p.fail("client directive or event");
                    const a = attribute.attribute;
                    if (p.server_extensions and (std.mem.startsWith(u8, a.name, "data-p-") or util.eql(a.name, "data-p"))) return p.fail("handwritten hydration wire attribute");
                    if (p.server_extensions and std.mem.startsWith(u8, a.name, "on")) {
                        const family = p.module.component.family orelse return p.fail("event outside a local store");
                        var known = false;
                        for (family.actions) |action| if (a.value.* == .reference and util.eql(action, a.value.reference.name)) {
                            known = true;
                        };
                        if (!known or !util.eql(a.name, "onClick")) return p.fail("unsupported SSR event (expected a named local-store click action)");
                        continue;
                    }
                    if (p.server_extensions and util.eql(a.name, "class") and a.value.* == .literal and a.value.literal == .string) continue;
                    if (util.eql(a.name, "...") or util.eql(a.name, "style") or util.eql(a.name, "class") or util.eql(a.name, "className") or std.mem.startsWith(u8, a.name, "on")) return p.fail("spread, style, class or event attribute");
                    const value = try p.expr(a.value);
                    if (value.kind == .node or value.kind == .function) return p.fail("node/function-valued attribute");
                }
                for (element.children) |child| try p.node(child);
            },
        }
    }
};

/// Arena-owned typed program and lossless in-memory IR. Callers must supply the
/// same validated prop domain to both targets; nullable props are not v1 scalars.
pub fn prepare(a: std.mem.Allocator, source: []const u8, filename: []const u8, resolver: ?@import("types.zig").Resolver) Error!Program {
    return prepareImpl(a, source, filename, resolver, false);
}

/// PHP server extension: document templates, imported components with scalar
/// props, and local scalar-store click/binding wires. Other constructs diagnose.
pub fn prepareServer(a: std.mem.Allocator, source: []const u8, filename: []const u8, resolver: ?@import("types.zig").Resolver) Error!Program {
    return prepareImpl(a, source, filename, resolver, true);
}

fn prepareImpl(a: std.mem.Allocator, source: []const u8, filename: []const u8, resolver: ?@import("types.zig").Resolver, server: bool) Error!Program {
    const parsed = try analyze.parsePjsxWithResolver(a, source, filename, resolver);
    const module = try compiler.createPjsxModuleWithResolver(a, source, filename, resolver);
    // Never silently drop executable statements that the legacy component IR
    // doesn't represent. Browser-only modules retain the mechanical DOM API.
    for (parsed.component.fn_node.body.?.statements) |statement| {
        if (statement.type == .ReturnStatement) break;
        if (statement.type == .FunctionDeclaration) continue;
        if (statement.type != .VariableDeclaration) return err.fail("pjsx: {s}:{d}: {s}: unsupported statement {s}", .{ filename, statement.start, profile, statement.type.name() });
        for (statement.declarations) |d| {
            if (d.id == null or d.id.?.type != .Identifier or d.init == null)
                return err.fail("pjsx: {s}:{d}: {s}: unsupported local binding", .{ filename, statement.start, profile });
        }
    }
    for (parsed.program.statements) |statement| {
        const d = if (statement.type == .ExportNamedDeclaration) statement.declaration orelse continue else statement;
        if (d == parsed.component.fn_node or (d.type == .TSDeclaration and (std.mem.startsWith(u8, parsed.canonical[d.start..], "type ") or std.mem.startsWith(u8, parsed.canonical[d.start..], "interface "))) or d.type == .EmptyStatement) continue;
        if (d.type == .ImportDeclaration) {
            if (d.import_kind == .type) continue;
            const specifier = d.source.?.stringValue() orelse "";
            if (server and d.specifiers.len > 0 and (util.hasPjsxExtension(specifier) or (util.eql(specifier, "publr/dom") or util.eql(specifier, "publr-dom") or util.eql(specifier, "publr")) or util.eql(specifier, "publr-js"))) continue;
        }
        if (server and module.component.family != null and d.type == .VariableDeclaration) {
            const family = module.component.family.?;
            var known = d.declarations.len > 0;
            for (d.declarations) |decl| {
                var declared = false;
                if (decl.id != null) {
                    declared = util.eql(decl.id.?.name, family.state);
                    for (family.actions) |action| declared = declared or util.eql(decl.id.?.name, action);
                }
                known = known and declared;
            }
            if (known) continue;
        }
        return err.fail("pjsx: {s}:{d}: {s}: unsupported executable module statement", .{ filename, d.start, profile });
    }
    if (server) {
        for (module.component.imports) |entry| {
            if (!util.hasPjsxExtension(entry.source)) continue;
            const loader = resolver orelse return err.fail("pjsx: {s}: component imports require a resolver", .{filename});
            const imported = (try loader.load(loader.context, a, filename, entry.source)) orelse return err.fail("pjsx: {s}: component module not found: {s}", .{ filename, entry.source });
            const child = try analyze.parsePjsxWithResolver(a, imported.code, imported.filename, resolver);
            for (entry.names) |binding| {
                if (binding.type_only) continue;
                if (!util.eql(binding.imported, child.component.name)) return err.fail("pjsx: {s}: {s} does not export component {s}", .{ filename, entry.source, binding.imported });
            }
        }
    }
    const copy = try a.create(compiler.ModuleIR);
    copy.* = module.*;
    copy.semantics_version = semantics.version;
    var p = Program{ .module = copy, .server_extensions = server, .allocator = a, .locals = .init(a), .active_helpers = .init(a), .signatures = .init(a) };
    if (server) {
        if (copy.component.reactive != null) return p.fail("non-family reactive store");
        if (copy.component.family) |family| {
            if (family.seed_exprs.len != 0 or family.refs.len != 0 or copy.component.store_registration == null or copy.component.root.* != .element) return p.fail("unsupported local-store seed, ref or root");
            for (family.initial) |field| {
                const initial = field.value orelse return p.fail("unservable state initializer");
                if (initial.* != .literal) return p.fail("non-literal state initializer");
                _ = try p.expr(initial);
            }
        }
    }
    for (copy.component.props.values()) |prop| _ = try p.propType(prop);
    for (copy.component.locals) |local| {
        const t = try p.expr(local.value);
        if (t.kind == .node) return p.fail("non-scalar local binding");
        try p.locals.put(local.name, t);
    }
    try p.node(copy.component.root);
    return p;
}

pub fn zigTarget() Target {
    return .{ .name = "zig", .compile = emitZig };
}
pub fn phpTarget() Target {
    return .{ .name = "php", .compile = @import("targets/php.zig").emit };
}
pub fn domTarget() Target {
    return .{ .name = "js-dom", .compile = emitDom };
}

fn emitZig(a: std.mem.Allocator, p: *const Program, _: Options) Error![]const u8 {
    return (try zig.lowerPjsxToZig(a, p.module, &.{})).code;
}

/// DOM generation consumes exactly the validated IR used by SSR. Original
/// source is used only by the browser-only transform, never by this emitter.
fn emitDom(a: std.mem.Allocator, p: *const Program, options: Options) Error![]const u8 {
    var e = DomEmitter{ .a = a, .program = p, .out = .init(a) };
    const w = &e.out.writer;
    try w.print("import * as $$dom from {s};\nexport function {s}(props) {{\n", .{ try util.jsonString(a, options.runtime_import), p.module.component.name });
    for (p.module.component.snapshots, 0..) |name, i| {
        const spec = p.module.component.props.get(name).?;
        try w.print("const p{d} = props[{s}];\n", .{ i, try util.jsonString(a, name) });
        if (spec.default) |default| {
            try w.print("const d{d} = p{d} === undefined ? {s} : p{d};\n", .{ i, i, if (default == .number) (if (default.number == 0 and std.math.signbit(default.number)) @as([]const u8, "-0") else try util.numberToString(a, default.number)) else try default.toJs().toJson(a), i });
        }
    }
    for (p.module.component.locals, 0..) |local, i| {
        try w.print("const l{d} = ", .{i});
        if (local.value.* == .function and !p.types.contains(local.value.function.body)) try w.writeAll("undefined") else try e.expr(local.value);
        try w.writeAll(";\n");
    }
    try w.writeAll("return ");
    try e.node(p.module.component.root);
    try w.writeAll(";\n}\n");
    return @import("specialize.zig").compile(a, e.out.written(), p.module.filename, options.runtime_import);
}

const DomEmitter = struct {
    a: std.mem.Allocator,
    program: *const Program,
    out: std.Io.Writer.Allocating,
    parameters: std.ArrayList(struct { name: []const u8, code: []const u8 }) = .empty,
    counter: usize = 0,

    fn expr(e: *DomEmitter, x: *const Expr) Error!void {
        const w = &e.out.writer;
        switch (x.*) {
            .literal => |v| switch (v) {
                .string => |s| try w.writeAll(try util.jsonString(e.a, s)),
                .number => |n| if (n == 0 and std.math.signbit(n)) try w.writeAll("-0") else try w.writeAll(try util.numberToString(e.a, n)),
                .boolean => |b| try w.writeAll(if (b) "true" else "false"),
                .null => try w.writeAll("null"),
            },
            .absent => try w.writeAll("undefined"),
            .reference => |r| {
                if (r.source == .prop) {
                    for (e.program.module.component.snapshots, 0..) |name, i| {
                        if (util.eql(name, r.name)) {
                            try w.print("{s}{d}", .{ if (e.program.module.component.props.get(name).?.default != null) @as([]const u8, "d") else "p", i });
                            return;
                        }
                    }
                    try w.print("props[{s}]", .{try util.jsonString(e.a, r.name)});
                } else {
                    var at = e.parameters.items.len;
                    while (at > 0) {
                        at -= 1;
                        const parameter = e.parameters.items[at];
                        if (util.eql(parameter.name, r.name)) {
                            try w.writeAll(parameter.code);
                            return;
                        }
                    }
                    for (e.program.module.component.locals, 0..) |local, i| {
                        if (util.eql(local.name, r.name)) {
                            try w.print("l{d}", .{i});
                            return;
                        }
                    }
                    try w.writeAll(r.name);
                }
            },
            .unary => |u| {
                try w.print("({s}(", .{u.operator});
                try e.expr(u.argument);
                try w.writeAll("))");
            },
            .operation => |o| {
                try w.writeByte('(');
                try e.expr(o.left);
                const operator: []const u8 = switch (e.program.operations.get(x).?) {
                    .number_add, .string_concat => "+",
                    .number_subtract => "-",
                    .number_multiply => "*",
                    .number_divide => "/",
                    .number_remainder => "%",
                    .equal => "===",
                    .not_equal => "!==",
                    .number_less => "<",
                    .number_less_equal => "<=",
                    .number_greater => ">",
                    .number_greater_equal => ">=",
                    .logical_and => "&&",
                    .logical_or => "||",
                    .nullish => "??",
                    else => unreachable,
                };
                try w.print(" {s} ", .{operator});
                try e.expr(o.right);
                try w.writeByte(')');
            },
            .conditional => |c| {
                try w.writeByte('(');
                try e.expr(c.@"test");
                try w.writeAll(" ? ");
                try e.expr(c.consequent);
                try w.writeAll(" : ");
                try e.expr(c.alternate);
                try w.writeByte(')');
            },
            .template => |t| {
                try w.writeAll("(\"\"");
                for (t.parts) |part| {
                    try w.writeAll(" + ");
                    switch (part) {
                        .string => |s| try w.writeAll(try util.jsonString(e.a, s)),
                        .expression => |v| try e.expr(v),
                    }
                }
                try w.writeByte(')');
            },
            .function => |f| {
                const saved = e.parameters.items.len;
                defer e.parameters.shrinkRetainingCapacity(saved);
                try w.writeByte('(');
                for (f.parameters, 0..) |parameter, i| {
                    if (i != 0) try w.writeAll(", ");
                    e.counter += 1;
                    const name = try util.fmt(e.a, "arg{d}", .{e.counter});
                    try e.parameters.append(e.a, .{ .name = parameter, .code = name });
                    try w.writeAll(name);
                }
                try w.writeAll(") => (");
                try e.expr(f.body);
                try w.writeByte(')');
            },
            .call => |c| {
                if (c.callee.* == .reference) {
                    try e.expr(c.callee);
                    try w.writeByte('(');
                } else try w.print("Math.{s}(", .{c.callee.member.property.string});
                for (c.arguments, 0..) |arg, i| {
                    if (i != 0) try w.writeAll(", ");
                    try e.expr(arg);
                }
                try w.writeByte(')');
            },
            .node => |n| try e.node(n.node),
            else => unreachable, // prepare checked every expression
        }
    }

    fn node(e: *DomEmitter, n: *const Node) Error!void {
        const w = &e.out.writer;
        switch (n.*) {
            .text => |t| try w.writeAll(try util.jsonString(e.a, t.value)),
            .expression => |x| {
                try w.writeAll("() => (");
                try e.expr(x.value);
                try w.writeByte(')');
            },
            .fragment => |f| {
                try w.writeAll("$$dom.Fragment({children: [");
                for (f.children, 0..) |child, index| {
                    if (index != 0) try w.writeAll(", ");
                    try e.node(child);
                }
                try w.writeAll("]})");
            },
            .element => |el| {
                try w.print("$$dom.h({s}, {{", .{try util.jsonString(e.a, el.name.intrinsic.name)});
                for (el.attributes, 0..) |attr, i| {
                    if (i != 0) try w.writeAll(", ");
                    try w.print("{s}: () => (", .{try util.jsonString(e.a, attr.attribute.name)});
                    try e.expr(attr.attribute.value);
                    try w.writeByte(')');
                }
                try w.writeByte('}');
                for (el.children) |child| {
                    try w.writeAll(", ");
                    try e.node(child);
                }
                try w.writeByte(')');
            },
        }
    }
};

test "portable target preparation resolves operators and emits from IR without reparsing source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try prepare(arena.allocator(),
        \\export function Example({a, b}: {a: number; b: number}) {
        \\  const show = a + b <= 0.3;
        \\  return <span>{show ? "Shown" : "Hidden"}</span>;
        \\}
    , "Example.ptsx", null);
    var operations = p.operations.valueIterator();
    var add = false;
    var less_equal = false;
    while (operations.next()) |operation| {
        add = add or operation.* == .number_add;
        less_equal = less_equal or operation.* == .number_less_equal;
    }
    try std.testing.expect(add and less_equal);
    @constCast(p.module).source = "this is no longer valid source";
    _ = try p.emit(domTarget(), .{});
    _ = try p.emit(zigTarget(), .{});
    _ = try p.emit(phpTarget(), .{});
    var incompatible = domTarget();
    incompatible.semantics_version += 1;
    try std.testing.expectError(error.Pjsx, p.emit(incompatible, .{}));
    incompatible = zigTarget();
    incompatible.api += 1;
    try std.testing.expectError(error.Pjsx, p.emit(incompatible, .{}));
}

test "portable profiles reject unrepresented effects, coercions and recursive helpers before emission" {
    const sources = [_][]const u8{
        "export function X({a}: {a: number}) { a++; return <span>{a}</span>; }",
        "export function X({a}: {a: number}) { return <span>{a + \"x\"}</span>; }",
        "export function X() { const f = (x: number) => f(x); return <span>{f(1)}</span>; }",
        "export function X() { return <span>{Date.now()}</span>; }",
        "const hidden = sideEffect(); export function X() { return <span>OK</span>; }",
        "export function X({a}: {a: number | null}) { return <span>{a}</span>; }",
        "export function X({a}: {a?: number}) { return <span>{a === null}</span>; }",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.Pjsx, prepare(arena.allocator(), source, "rejected.ptsx", null));
        try std.testing.expect(std.mem.indexOf(u8, err.message(), "rejected.ptsx") != null);
    }
}

test "portable JSON carries lossless defaults and resolvable typed expression paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try prepare(a,
        \\export function Example({a = -0}: {a?: number}) {
        \\  const result = a + 0.2;
        \\  return <span data-value={result}>{`${a}:${result}`}</span>;
        \\}
    , "Example.ptsx", null);
    var out: std.Io.Writer.Allocating = .init(a);
    try p.writeJson(&out.writer);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{});
    try std.testing.expectEqualStrings(profile, value.object.get("profile").?.string);
    const ir = value.object.get("ir").?;
    const encoded_default = ir.object.get("component").?.object.get("props").?.object.get("a").?.object.get("default").?.object.get("binary64").?.string;
    try std.testing.expectEqualStrings("8000000000000000", encoded_default);
    for (value.object.get("expressions").?.array.items) |annotation| {
        var current = ir;
        var parts = std.mem.splitScalar(u8, annotation.object.get("path").?.string[1..], '/');
        while (parts.next()) |part| current = switch (current) {
            .object => |object| object.get(part) orelse return error.TestUnexpectedResult,
            .array => |array| array.items[try std.fmt.parseInt(usize, part, 10)],
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expect(current == .object and current.object.contains("kind"));
    }
}

test "PHP document extension is explicit and cannot masquerade as the scalar profile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "export function Page() { return <html><head><script type=\"module\" src=\"/app.js\" /></head><body class=\"page\">Hello</body></html>; }";
    try std.testing.expectError(error.Pjsx, prepare(a, source, "Page.ptsx", null));
    const program = try prepareServer(a, source, "Page.ptsx", null);
    const php = try program.emit(phpTarget(), .{});
    try std.testing.expect(std.mem.indexOf(u8, php, "<!doctype html>") != null);
    try std.testing.expectError(error.Pjsx, program.emit(domTarget(), .{}));
    var json: std.Io.Writer.Allocating = .init(a);
    try program.writeJson(&json.writer);
    try std.testing.expect(std.mem.indexOf(u8, json.written(), server_profile) != null);
}

test "PHP document extension rejects inline code, side effects and unrepresentable store behavior" {
    const cases = [_][]const u8{
        "export function X() { return <script>{\"alert(1)\"}</script>; }",
        "import './side-effect.js'; export function X() { return <div/>; }",
        "export function X() { return <button onClick={() => alert(1)}>Go</button>; }",
        "export function X() { return <div data-p-store=\"manual\"/>; }",
        "import { Publr } from 'publr-dom'; export const state = Publr.reactive({ get open() { return true; } }); export function X() { return <div hidden={!state.open}/>; }",
    };
    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.Pjsx, prepareServer(arena.allocator(), source, "rejected.ptsx", null));
    }
}

test "PHP SSR store expressions must have a supported live wire, not only an initial value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const program = try prepareServer(a, "import { Publr } from 'publr-dom'; export const state = Publr.reactive({ value: 1 }); export function X() { return <div>{state.value + 1}</div>; }", "X.ptsx", null);
    try std.testing.expectError(error.Pjsx, program.emit(phpTarget(), .{}));
    try std.testing.expect(std.mem.indexOf(u8, err.message(), "unsupported PHP state wire") != null);
}
