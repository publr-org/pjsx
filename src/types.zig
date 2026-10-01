//! TypeScript prop contracts. Type syntax is resolved from the original AST
//! ranges; no executable schema or filesystem access is needed by the compiler.
const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const canonicalize = @import("canonicalize.zig");
const util = @import("util.zig");
const err = @import("err.zig");
const analyze = @import("analyze.zig");
const Allocator = std.mem.Allocator;
const Error = err.Error;

pub const Source = struct { filename: []const u8, code: []const u8 };
pub const Resolver = struct {
    context: *anyopaque,
    load: *const fn (*anyopaque, Allocator, []const u8, []const u8) Error!?Source,
};
pub const Kind = enum { string, number, boolean, object, array, tuple, @"union", function, node, style, undefined, null, never, unknown };
pub const Property = struct { type: *Type, optional: bool = false };
pub const Type = struct {
    kind: Kind,
    fields: util.OrderedMap(Property),
    members: []const *Type = &.{},
    item: ?*Type = null,
    literal: ?analyze.Primitive = null,
    rest: bool = false,
    source: []const u8 = "",
};
const Module = struct { filename: []const u8, source: []const u8, program: *ast.Node };

pub const Context = struct {
    a: Allocator,
    resolver: ?Resolver,
    modules: util.OrderedMap(*Module),
    resolving: util.OrderedMap(bool),
    cache: util.OrderedMap(*Type),

    pub fn init(a: Allocator, resolver: ?Resolver) Context {
        return .{ .a = a, .resolver = resolver, .modules = .init(a), .resolving = .init(a), .cache = .init(a) };
    }
    fn make(c: *Context, kind: Kind) Error!*Type {
        const t = try c.a.create(Type);
        t.* = .{ .kind = kind, .fields = .init(c.a) };
        return t;
    }
    fn add(c: *Context, filename: []const u8, source: []const u8, program: *ast.Node) Error!*Module {
        const m = try c.a.create(Module);
        m.* = .{ .filename = filename, .source = source, .program = program };
        try c.modules.put(filename, m);
        return m;
    }
    fn imported(c: *Context, m: *Module, specifier: []const u8) Error!*Module {
        const resolver = c.resolver orelse return err.fail("pjsx: {s}: resolving imported type from {s} needs a source resolver", .{ m.filename, specifier });
        const source = try resolver.load(resolver.context, c.a, m.filename, specifier) orelse return err.fail("pjsx: {s}: cannot resolve type module {s}", .{ m.filename, specifier });
        if (c.modules.get(source.filename)) |found| return found;
        const canonical = try canonicalize.canonicalize(c.a, source.code);
        return c.add(source.filename, canonical.code, try parser.parse(c.a, canonical.code, source.filename));
    }
    fn textType(c: *Context, m: *Module, source: []const u8) Error!*Type {
        var p = try TypeParser.init(c, m, source);
        _ = try p.eat(":");
        const result = try p.parseUnion();
        _ = try p.eat(";");
        if (p.t.kind != .eof) return err.fail("pjsx: {s}: unsupported TypeScript type near {s}", .{ m.filename, p.t.text });
        result.source = source;
        return result;
    }
    fn named(c: *Context, m: *Module, name: []const u8, value: bool) Error!*Type {
        const key = try util.fmt(c.a, "{s}:{s}:{s}", .{ m.filename, if (value) "value" else "type", name });
        if (c.cache.get(key)) |t| return t;
        // A type that refers to itself (a tree of controls, a node with child
        // nodes) is opaque at the point of recursion: nothing that reads a
        // type here needs more than "present or not" from it.
        if (c.resolving.get(key) orelse false) return c.make(.unknown);
        try c.resolving.put(key, true);
        defer c.resolving.put(key, false) catch {};
        for (m.program.statements) |s| {
            const d = (if (s.type == .ExportNamedDeclaration) s.declaration else s) orelse continue;
            if (!value and d.type == .TSDeclaration) {
                var p = try TypeParser.init(c, m, d.slice(m.source));
                _ = try p.eat("declare");
                const is_interface = p.t.is("interface");
                if (!p.t.is("type") and !is_interface) continue;
                try p.next();
                if (!util.eql(p.t.text, name)) continue;
                try p.next();
                const result = if (is_interface) blk: {
                    var base = try c.make(.object);
                    if (try p.eat("extends")) {
                        while (true) {
                            base = try c.mergeObjects(base, try p.parsePostfix(), false);
                            if (!try p.eat(",")) break;
                        }
                    }
                    break :blk try c.mergeObjects(base, try p.parsePrimary(), false);
                } else blk: {
                    try p.expect("=");
                    break :blk try p.parseUnion();
                };
                try c.cache.put(key, result);
                return result;
            }
            if (value and d.type == .VariableDeclaration) {
                for (d.declarations) |decl| {
                    if (decl.id.?.isIdentifier(name) and decl.init != null) {
                        const result = try c.valueType(m, decl.init.?);
                        try c.cache.put(key, result);
                        return result;
                    }
                }
            }
            if (d.type == .ImportDeclaration) {
                for (d.specifiers) |spec| {
                    if (spec.local != null and spec.local.?.isIdentifier(name)) {
                        const imported_name = spec.imported orelse return err.fail("pjsx: {s}: namespace/default type imports are not yet supported", .{m.filename});
                        const result = try c.named(try c.imported(m, d.source.?.value.string), imported_name.name, value);
                        try c.cache.put(key, result);
                        return result;
                    }
                }
            }
            if (s.type == .ExportNamedDeclaration and s.declaration == null) {
                for (s.specifiers) |spec| {
                    if (spec.exported != null and spec.exported.?.isIdentifier(name)) {
                        const target = if (s.source) |src| try c.imported(m, src.value.string) else m;
                        const result = try c.named(target, spec.local.?.name, value);
                        try c.cache.put(key, result);
                        return result;
                    }
                }
            }
        }
        return err.fail("pjsx: {s}: cannot resolve TypeScript {s} {s}", .{ m.filename, if (value) "value" else "type", name });
    }
    fn valueType(c: *Context, m: *Module, raw: *ast.Node) Error!*Type {
        const node = analyze.unwrap(raw);
        if (node.type == .Literal) {
            const primitive = analyze.Primitive.fromLiteral(node.value) orelse return c.make(if (node.value == .null) .null else .unknown);
            const result = try c.make(switch (primitive) {
                .string => .string,
                .number => .number,
                .boolean => .boolean,
            });
            result.literal = primitive;
            return result;
        }
        if (node.type == .Identifier) return c.named(m, node.name, true);
        if (node.type == .UnaryExpression and util.eql(node.operator, "-")) {
            const t = try c.valueType(m, node.argument.?);
            if (t.literal != null and t.literal.? == .number) {
                const n = try c.make(.number);
                n.literal = .{ .number = -t.literal.?.number };
                return n;
            }
        }
        if (node.type == .ObjectExpression) {
            var result = try c.make(.object);
            for (node.properties) |prop| {
                if (prop.type == .SpreadElement) {
                    result = try c.mergeObjects(result, try c.valueType(m, prop.argument.?), false);
                } else {
                    const name = try analyze.propertyName(c.a, prop) orelse return err.fail("pjsx: {s}: cannot infer computed constant key", .{m.filename});
                    try result.fields.put(name, .{ .type = try c.valueType(m, prop.value_node.?) });
                }
            }
            return result;
        }
        if (node.type == .ArrayExpression) {
            const result = try c.make(.tuple);
            var items: std.ArrayList(*Type) = .empty;
            for (node.elements) |item| try items.append(c.a, try c.valueType(m, item orelse return err.failMsg("pjsx: sparse type constants are unsupported")));
            result.members = try items.toOwnedSlice(c.a);
            return result;
        }
        if (node.type == .CallExpression or node.type == .TemplateLiteral) return c.make(.unknown);
        if (node.type == .ArrowFunctionExpression or node.type == .FunctionExpression) return c.make(.function);
        if (node.type == .JSXElement or node.type == .JSXFragment) return c.make(.node);
        return err.fail("pjsx: {s}: cannot infer a prop type from {s}; add a TypeScript annotation", .{ m.filename, @tagName(node.type) });
    }
    fn combine(c: *Context, left: *Type, right: *Type) Error!*Type {
        if (left.kind == .never) return right;
        if (right.kind == .never) return left;
        const result = try c.make(.@"union");
        var members: std.ArrayList(*Type) = .empty;
        if (left.kind == .@"union") try members.appendSlice(c.a, left.members) else try members.append(c.a, left);
        if (right.kind == .@"union") try members.appendSlice(c.a, right.members) else try members.append(c.a, right);
        result.members = try members.toOwnedSlice(c.a);
        return result;
    }
    fn intersect(c: *Context, left: *Type, right: *Type) Error!*Type {
        if (left == right) return left;
        if (left.kind == .unknown) return right;
        if (right.kind == .unknown) return left;
        if (left.kind == .@"union" or right.kind == .@"union") {
            const alternatives = if (left.kind == .@"union") left else right;
            const other = if (left.kind == .@"union") right else left;
            var result = try c.make(.never);
            for (alternatives.members) |member| result = try c.combine(result, try c.intersect(member, other));
            return result;
        }
        if (left.kind != right.kind) return c.make(.never);
        if (left.kind == .object) return c.mergeObjects(left, right, false);
        if (left.kind == .array) {
            const result = try c.make(.array);
            result.item = try c.intersect(left.item.?, right.item.?);
            return result;
        }
        if (left.literal) |l| {
            if (right.literal) |r| {
                const equal = switch (l) {
                    .string => |v| r == .string and util.eql(v, r.string),
                    .number => |v| r == .number and v == r.number,
                    .boolean => |v| r == .boolean and v == r.boolean,
                };
                return if (equal) left else c.make(.never);
            }
            return left;
        }
        if (right.literal != null) return right;
        return switch (left.kind) {
            .string, .number, .boolean, .node, .undefined, .null, .never => left,
            else => err.fail("pjsx: intersection of {s} types cannot yet be lowered", .{@tagName(left.kind)}),
        };
    }
    fn mergeObjects(c: *Context, left: *Type, right: *Type, union_: bool) Error!*Type {
        if (left.kind != .object or right.kind != .object) return err.failMsg("pjsx: expected object types in props intersection");
        const result = try c.make(.object);
        for (left.fields.keys(), left.fields.values()) |name, field| {
            var f = field;
            if (right.fields.get(name)) |other| {
                f.type = if (union_) try c.combine(field.type, other.type) else try c.intersect(field.type, other.type);
                f.optional = if (union_) field.optional or other.optional else field.optional and other.optional;
            } else if (union_) f.optional = true;
            try result.fields.put(name, f);
        }
        for (right.fields.keys(), right.fields.values()) |name, field| {
            if (result.fields.has(name)) continue;
            var f = field;
            if (union_) f.optional = true;
            try result.fields.put(name, f);
        }
        return result;
    }
    fn object(c: *Context, t: *Type) Error!*Type {
        if (t.kind == .object) return t;
        if (t.kind != .@"union") return err.fail("pjsx: component props must have an object type, not {s}{s}{s}", .{ @tagName(t.kind), if (t.source.len > 0) " from " else "", t.source });
        var result: ?*Type = null;
        for (t.members) |member| {
            const obj = try c.object(member);
            result = if (result) |r| try c.mergeObjects(r, obj, true) else obj;
        }
        return result orelse c.make(.object);
    }
};

const TypeParser = struct {
    c: *Context,
    m: *Module,
    lex: lexer.Lexer,
    t: lexer.Token,
    fn init(c: *Context, m: *Module, source: []const u8) Error!TypeParser {
        var lex = lexer.Lexer.init(c.a, source);
        const t = try lex.next();
        return .{ .c = c, .m = m, .lex = lex, .t = t };
    }
    fn next(p: *TypeParser) Error!void {
        p.t = try p.lex.next();
    }
    fn eat(p: *TypeParser, s: []const u8) Error!bool {
        // `Readonly<Record<K, V>>` lexes its closers as one `>>` token; a
        // type argument list takes one of them and leaves the other.
        if (std.mem.eql(u8, s, ">") and p.t.kind == .punct and (std.mem.eql(u8, p.t.text, ">>") or std.mem.eql(u8, p.t.text, ">>>"))) {
            p.t.text = p.t.text[1..];
            p.t.start += 1;
            return true;
        }
        if (!p.t.is(s)) return false;
        try p.next();
        return true;
    }
    fn expect(p: *TypeParser, s: []const u8) Error!void {
        if (!try p.eat(s)) return err.fail("pjsx: {s}: expected {s} in type, found {s}", .{ p.m.filename, s, p.t.text });
    }
    fn parseUnion(p: *TypeParser) Error!*Type {
        _ = try p.eat("|");
        var result = try p.parseIntersection();
        while (try p.eat("|")) result = try p.c.combine(result, try p.parseIntersection());
        return result;
    }
    fn parseIntersection(p: *TypeParser) Error!*Type {
        var result = try p.parsePostfix();
        while (try p.eat("&")) {
            const right = try p.parsePostfix();
            result = try p.c.intersect(result, right);
        }
        return result;
    }
    fn parsePostfix(p: *TypeParser) Error!*Type {
        _ = try p.eat("readonly");
        var result = try p.parsePrimary();
        while (try p.eat("[")) {
            if (try p.eat("]")) {
                const array = try p.c.make(.array);
                array.item = result;
                result = array;
            } else {
                const index = try p.parseUnion();
                try p.expect("]");
                if (index.kind == .number and result.kind == .tuple) {
                    var items = try p.c.make(.never);
                    for (result.members) |member| items = try p.c.combine(items, member);
                    result = items;
                } else if (index.kind == .number and result.kind == .array) {
                    result = result.item.?;
                } else if (index.literal != null and index.literal.? == .string and result.kind == .object) {
                    result = (result.fields.get(index.literal.?.string) orelse return err.failMsg("pjsx: unknown indexed property")).type;
                } else return err.failMsg("pjsx: unsupported indexed access type");
            }
        }
        return result;
    }
    fn parsePrimary(p: *TypeParser) Error!*Type {
        const c = p.c;
        if (try p.eat("keyof")) {
            const object = try c.object(try p.parsePostfix());
            var result = try c.make(.never);
            for (object.fields.keys()) |name| {
                const literal = try c.make(.string);
                literal.literal = .{ .string = name };
                result = try c.combine(result, literal);
            }
            return result;
        }
        if (try p.eat("typeof")) {
            const name = p.t.text;
            try p.next();
            return c.named(p.m, name, true);
        }
        if (try p.eat("{")) {
            const object = try c.make(.object);
            while (!try p.eat("}")) {
                if (p.t.kind == .eof) return err.failMsg("pjsx: unterminated object type");
                if (p.t.is("readonly")) {
                    const saved = p.*;
                    try p.next();
                    if (p.t.is(":") or p.t.is("?")) p.* = saved;
                }
                if (try p.eat("[")) {
                    // Record/index signatures describe style objects; retain their value type.
                    while (!try p.eat("]")) {
                        if (p.t.kind == .eof) return err.failMsg("pjsx: unterminated index signature");
                        try p.next();
                    }
                    try p.expect(":");
                    object.item = try p.parseUnion();
                    object.kind = .style;
                } else {
                    const name = p.t.text;
                    try p.next();
                    const optional = try p.eat("?");
                    try p.expect(":");
                    const value = try p.parseUnion();
                    try object.fields.put(name, .{ .type = value, .optional = optional });
                }
                if (!try p.eat(";")) _ = try p.eat(",");
            }
            return object;
        }
        if (try p.eat("[")) {
            const tuple = try c.make(.tuple);
            var items: std.ArrayList(*Type) = .empty;
            while (!try p.eat("]")) {
                const rest = try p.eat("...");
                const item = try p.parseUnion();
                if (rest) {
                    tuple.rest = true;
                    try items.append(c.a, item.item orelse item);
                } else try items.append(c.a, item);
                if (!try p.eat(",")) {
                    try p.expect("]");
                    break;
                }
            }
            tuple.members = try items.toOwnedSlice(c.a);
            return tuple;
        }
        if (p.t.is("(")) {
            // A matching ')' followed by '=>' distinguishes a function type.
            const saved = p.*;
            var depth: usize = 0;
            while (true) {
                if (p.t.is("(")) depth += 1;
                if (p.t.is(")")) {
                    depth -= 1;
                    if (depth == 0) {
                        try p.next();
                        break;
                    }
                }
                if (p.t.kind == .eof) return err.failMsg("pjsx: unterminated function type");
                try p.next();
            }
            if (try p.eat("=>")) {
                // Callback argument/return syntax remains in source, while wire
                // lowering only needs to know that the value is callable.
                var nesting: usize = 0;
                while (p.t.kind != .eof) {
                    if (nesting == 0 and (p.t.is(";") or p.t.is(",") or p.t.is("}") or p.t.is(")"))) break;
                    if (p.t.is("(") or p.t.is("{") or p.t.is("[") or p.t.is("<")) nesting += 1;
                    if (p.t.is(")") or p.t.is("}") or p.t.is("]") or p.t.is(">")) {
                        if (nesting == 0) break;
                        nesting -= 1;
                    }
                    try p.next();
                }
                return c.make(.function);
            }
            p.* = saved;
            try p.expect("(");
            const result = try p.parseUnion();
            try p.expect(")");
            return result;
        }
        const token = p.t;
        try p.next();
        if (token.kind == .string or token.kind == .number or token.is("true") or token.is("false")) {
            const t = try c.make(if (token.kind == .string) .string else if (token.kind == .number) .number else .boolean);
            t.literal = if (token.kind == .string) .{ .string = token.text } else if (token.kind == .number) .{ .number = token.number } else .{ .boolean = token.is("true") };
            return t;
        }
        if (token.is("JSX")) {
            try p.expect(".");
            try p.expect("Element");
            return c.make(.node);
        }
        inline for (.{ "string", "number", "boolean", "undefined", "null", "never", "unknown" }) |name| {
            if (token.is(name)) return c.make(@field(Kind, name));
        }
        if (token.is("void")) return c.make(.undefined);
        if (token.is("Array") or token.is("ReadonlyArray")) {
            try p.expect("<");
            const t = try c.make(.array);
            t.item = try p.parseUnion();
            try p.expect(">");
            return t;
        }
        if (token.is("Record")) {
            try p.expect("<");
            _ = try p.parseUnion();
            try p.expect(",");
            const t = try c.make(.style);
            t.item = try p.parseUnion();
            try p.expect(">");
            return t;
        }
        if (token.is("Omit") or token.is("Pick") or token.is("Partial") or token.is("Required") or token.is("Readonly")) {
            try p.expect("<");
            const inner = try p.parseUnion();
            // `Readonly<Record<…>>`, `Partial<string[]>`: the modifier changes
            // nothing a schema reads, so the inner type passes through.
            if (inner.kind != .object and inner.kind != .@"union" and !token.is("Omit") and !token.is("Pick")) {
                try p.expect(">");
                return inner;
            }
            const original = try c.object(inner);
            const keys = if (try p.eat(",")) try p.parseUnion() else null;
            try p.expect(">");
            const t = try c.make(.object);
            for (original.fields.keys(), original.fields.values()) |name, field| {
                const included = if (keys) |k| containsLiteral(k, name) else false;
                if (token.is("Omit") and included or token.is("Pick") and !included) continue;
                var f = field;
                if (token.is("Partial")) f.optional = true;
                if (token.is("Required")) f.optional = false;
                try t.fields.put(name, f);
            }
            return t;
        }
        if (token.kind != .identifier) return err.fail("pjsx: {s}: unsupported type token {s}", .{ p.m.filename, token.text });
        return c.named(p.m, token.text, false);
    }
};

fn containsLiteral(t: *Type, value: []const u8) bool {
    if (t.literal) |l| return l.eqlString(value);
    for (t.members) |member| if (containsLiteral(member, value)) return true;
    return false;
}
fn includes(t: *Type, kind: Kind) bool {
    if (t.kind == kind) return true;
    if (t.kind == .@"union") for (t.members) |member| {
        if (includes(member, kind)) return true;
    };
    return false;
}
fn isStringType(t: *Type) bool {
    if (t.kind == .string) return true;
    if (t.kind != .@"union" or t.members.len == 0) return false;
    for (t.members) |member| if (!isStringType(member)) return false;
    return true;
}
fn onlyBoolean(t: *Type) bool {
    if (t.kind == .boolean) return true;
    if (t.kind != .@"union") return false;
    var found = false;
    for (t.members) |member| {
        if (member.kind == .null or member.kind == .undefined or member.kind == .never) continue;
        if (!onlyBoolean(member)) return false;
        found = true;
    }
    return found;
}
fn propSpec(c: *Context, t: *Type, optional: bool) Error!analyze.PropSchema {
    var s = analyze.PropSchema{ .type = .string, .optional = optional or includes(t, .undefined), .typescript = t, .nullable = includes(t, .null) };
    var core = t;
    if (t.kind == .@"union") {
        var values: std.ArrayList(analyze.Primitive) = .empty;
        var base: ?Kind = null;
        var homogeneous = true;
        var count: usize = 0;
        for (t.members) |member| {
            if (member.kind == .undefined or member.kind == .null or member.kind == .never) continue;
            core = member;
            count += 1;
            if (base) |b| {
                if (b != member.kind) homogeneous = false;
            } else base = member.kind;
            if (member.literal) |literal| try values.append(c.a, literal);
        }
        if (homogeneous and count > 0) {
            if (values.items.len < count and (base == .string or base == .number or base == .boolean)) core = try c.make(base.?);
            if (values.items.len == count and base == .string) {
                var unique: std.ArrayList(analyze.Primitive) = .empty;
                for (values.items) |value| {
                    var found = false;
                    for (unique.items) |prior| if (prior.eqlString(value.string)) {
                        found = true;
                        break;
                    };
                    if (!found) try unique.append(c.a, value);
                }
                s.values = try unique.toOwnedSlice(c.a);
            }
        } else if (includes(t, .node)) {
            core = try c.make(.node);
        } else if (includes(t, .style) and includes(t, .string)) {
            core = try c.make(.style);
        } else if (includes(t, .tuple) and includes(t, .string)) {
            for (t.members) |member| {
                if (member.kind == .string or member.kind == .undefined or member.kind == .null or member.kind == .never) continue;
                if (member.kind != .tuple or member.rest or member.members.len != 2 or member.members[0].kind != .number or !isStringType(member.members[1]))
                    return err.failMsg("pjsx: this string/tuple union cannot yet be lowered; supported tuple shape is [number, string]");
            }
            s.type = .@"union";
            s.variants = &.{ "string", "number-string-tuple" };
            return s;
        } else return err.fail("pjsx: heterogeneous prop union cannot yet be lowered: {s}", .{t.source});
    }
    s.type = switch (core.kind) {
        .string => .string,
        .number => .number,
        .boolean => .boolean,
        .node => .node,
        .function => .action,
        .style => .style,
        .array, .tuple => .array,
        else => return err.fail("pjsx: prop type {s} cannot be lowered; use an accurate TypeScript type", .{@tagName(core.kind)}),
    };
    if (core.literal != null and s.values == null and core.kind == .string) s.values = try c.a.dupe(analyze.Primitive, &.{core.literal.?});
    if (s.type == .array) {
        const item = if (core.item) |i| i else blk: {
            if (core.members.len == 0) return err.failMsg("pjsx: empty tuple prop is not yet lowered");
            var combined = core.members[0];
            for (core.members[1..]) |member| {
                if (member.kind == .object and combined.kind == .object) {
                    combined = try c.mergeObjects(combined, member, true);
                } else if (member.kind != combined.kind) return err.failMsg("pjsx: heterogeneous tuple items cannot yet be lowered");
            }
            break :blk combined;
        };
        if (item.kind == .object or item.kind == .@"union") {
            s.fields = try objectSchema(c, try c.object(item));
        } else s.items = switch (item.kind) {
            .string => .string,
            .number => .number,
            .boolean => .boolean,
            else => return err.failMsg("pjsx: unsupported array item type"),
        };
    }
    return s;
}
fn objectSchema(c: *Context, object: *Type) Error!*analyze.Schema {
    const schema = try c.a.create(analyze.Schema);
    schema.* = .init(c.a);
    for (object.fields.keys(), object.fields.values()) |name, field| {
        if (field.type.kind == .never or field.type.kind == .undefined) continue;
        try schema.put(name, try propSpec(c, field.type, field.optional));
    }
    return schema;
}

/// The asserted type of an array value (`[] as Row[]`) as an array prop
/// schema, so an empty literal keeps its item fields. Null when the type is
/// not an array or cannot be resolved in the module (an imported alias
/// without a resolver).
pub fn assertedArray(a: Allocator, program: *ast.Node, source: []const u8, filename: []const u8, annotation: []const u8) ?analyze.PropSchema {
    var c = Context.init(a, null);
    const m = c.add(filename, source, program) catch return null;
    const t = c.textType(m, annotation) catch return null;
    if (t.kind != .array) return null;
    return propSpec(&c, t, false) catch null;
}

pub const InferredProps = struct { schema: *analyze.Schema, contract: *Type };

pub fn infer(a: Allocator, program: *ast.Node, source: []const u8, filename: []const u8, function: *ast.Node, resolver: ?Resolver) Error!InferredProps {
    var c = Context.init(a, resolver);
    const m = try c.add(filename, source, program);
    if (function.params.len == 0) {
        const contract = try c.make(.object);
        return .{ .schema = try objectSchema(&c, contract), .contract = contract };
    }
    const param = function.params[0];
    const pattern = if (param.type == .AssignmentPattern) param.left.? else param;
    var contract: *Type = undefined;
    if (pattern.type_annotation) |annotation| {
        contract = try c.textType(m, annotation.slice(source));
    } else if (pattern.type == .ObjectPattern) {
        contract = try c.make(.object);
        for (pattern.properties) |field| {
            const name = try analyze.propertyName(a, field) orelse return err.failMsg("pjsx: computed inferred props need a type annotation");
            const binding = field.value_node.?;
            if (binding.type != .AssignmentPattern) return err.fail("pjsx: {s}.{s}: add a TypeScript prop annotation or an inferable default", .{ filename, name });
            const inferred = try c.valueType(m, binding.right.?);
            inferred.literal = null; // Normal mutable parameter inference widens literals.
            try contract.fields.put(name, .{ .type = inferred, .optional = true });
        }
    } else return err.fail("pjsx: {s}: component props need a TypeScript annotation", .{filename});
    const schema = try objectSchema(&c, try c.object(contract));
    if (pattern.type == .ObjectPattern) for (pattern.properties) |field| {
        const name = try analyze.propertyName(a, field) orelse continue;
        const binding = field.value_node.?;
        if (binding.type != .AssignmentPattern) continue;
        var s = schema.get(name) orelse continue;
        const value = analyze.unwrap(binding.right.?);
        s.default_expression = value;
        s.default = if (value.type == .Literal) analyze.Primitive.fromLiteral(value.value) else if (value.type == .UnaryExpression and util.eql(value.operator, "-") and value.argument.?.type == .Literal and value.argument.?.value == .number) .{ .number = -value.argument.?.value.number } else null;
        try schema.put(name, s);
    };
    return .{ .schema = schema, .contract = contract };
}

/// Publr JSX guards: booleans test true; optional non-booleans test presence.
/// This is confined to `&&` guarding JSX. Ordinary JS expressions are unchanged.
pub fn annotateGuards(a: Allocator, program: *ast.Node, source: []const u8, filename: []const u8, function: *ast.Node, resolver: ?Resolver) Error!void {
    if (function.params.len != 1 or function.body == null) return;
    const parameter = function.params[0];
    const pattern = if (parameter.type == .AssignmentPattern) parameter.left.? else parameter;
    const annotation = pattern.type_annotation orelse return;
    var c = Context.init(a, resolver);
    const m = try c.add(filename, source, program);
    const contract = try c.textType(m, annotation.slice(source));
    if (contract.kind != .object and contract.kind != .@"union") return;
    const object = try c.object(contract);
    var bindings = util.OrderedMap(Property).init(a);
    try bindPattern(&c, pattern, .{ .type = object }, &bindings);
    try annotateGuardNodes(&c, m, function.body.?, &bindings);
}

fn bindPattern(c: *Context, pattern: *ast.Node, property: Property, bindings: *util.OrderedMap(Property)) Error!void {
    if (pattern.type == .Identifier) {
        try bindings.put(pattern.name, property);
    } else if (pattern.type == .AssignmentPattern) {
        var supplied = property;
        supplied.optional = false;
        if (property.type.kind == .@"union") {
            supplied.type = try c.make(.never);
            for (property.type.members) |member| {
                if (member.kind != .undefined) supplied.type = try c.combine(supplied.type, member);
            }
        }
        try bindPattern(c, pattern.left.?, supplied, bindings);
    } else if (pattern.type == .ObjectPattern) {
        for (pattern.properties) |field| {
            if (field.type == .RestElement) {
                try bindPattern(c, field.argument.?, .{ .type = try c.make(.unknown) }, bindings);
                continue;
            }
            const name = try analyze.propertyName(c.a, field) orelse continue;
            const member = property.type.fields.get(name) orelse Property{ .type = try c.make(.unknown) };
            try bindPattern(c, field.value_node.?, member, bindings);
        }
    } else if (pattern.type == .ArrayPattern) {
        for (pattern.elements) |element| if (element) |value| {
            try bindPattern(c, value, .{ .type = try c.make(.unknown) }, bindings);
        };
    }
}

fn bindingForExpression(c: *Context, raw: *ast.Node, bindings: *const util.OrderedMap(Property)) Error!?Property {
    const node = analyze.unwrap(raw);
    if (node.type == .Identifier) return bindings.get(node.name);
    if (node.type == .MemberExpression) {
        const base = try bindingForExpression(c, node.object.?, bindings) orelse return null;
        const name = if (!node.computed and node.property.?.type == .Identifier) node.property.?.name else if (node.property.?.type == .Literal and node.property.?.value == .string) node.property.?.value.string else return null;
        if (util.eql(name, "length") and (base.type.kind == .array or base.type.kind == .tuple or base.type.kind == .string))
            return .{ .type = try c.make(.number) };
        if (base.type.kind != .object) return null;
        return base.type.fields.get(name);
    }
    if (node.type == .UnaryExpression and util.eql(node.operator, "!")) return .{ .type = try c.make(.boolean) };
    if (node.type == .Literal) {
        if (analyze.Primitive.fromLiteral(node.value)) |literal| {
            return .{ .type = try c.make(switch (literal) {
                .string => .string,
                .number => .number,
                .boolean => .boolean,
            }) };
        }
    }
    return null;
}

fn containsJsx(node: *ast.Node) bool {
    if (node.isJsx()) return true;
    for (ast.childFields(node.type)) |field| {
        if (field[1]) {
            for (ast.getList(node, field[0])) |child| if (child) |n| {
                if (containsJsx(n)) return true;
            };
        } else if (ast.getSingle(node, field[0])) |n| {
            if (containsJsx(n)) return true;
        }
    }
    return false;
}

fn annotateGuardNodes(c: *Context, m: *Module, node: *ast.Node, bindings: *util.OrderedMap(Property)) Error!void {
    if (node.type == .LogicalExpression and util.eql(node.operator, "&&")) {
        if (try bindingForExpression(c, node.left.?, bindings)) |property| {
            node.pjsx_guard = if (onlyBoolean(property.type)) .boolean else if (property.optional or includes(property.type, .undefined) or includes(property.type, .null)) .presence else .truthy;
        }
    }
    if (node.type == .BlockStatement) {
        var scope = try bindings.clone();
        for (node.statements) |statement| try annotateGuardNodes(c, m, statement, &scope);
        return;
    }
    if (node.type == .VariableDeclarator) {
        if (node.init) |value| try annotateGuardNodes(c, m, value, bindings);
        const pattern = node.id orelse return;
        const property: Property = if (pattern.type_annotation) |annotation|
            .{ .type = try c.textType(m, annotation.slice(m.source)) }
        else if (node.init) |value|
            try bindingForExpression(c, value, bindings) orelse .{ .type = try c.make(.unknown) }
        else
            .{ .type = try c.make(.unknown) };
        try bindPattern(c, pattern, property, bindings);
        return;
    }
    if (node.type == .CallExpression and node.callee.?.type == .MemberExpression and node.callee.?.property.?.isIdentifier("map") and node.arguments.len > 0) {
        const callback = analyze.unwrap(node.arguments[0]);
        if (callback.type == .ArrowFunctionExpression or callback.type == .FunctionExpression) {
            var scope = try bindings.clone();
            const collection = try bindingForExpression(c, node.callee.?.object.?, bindings);
            const item = if (collection) |value| value.type.item else null;
            for (callback.params, 0..) |parameter, i| {
                const inferred = if (i == 0) item orelse try c.make(.unknown) else try c.make(.number);
                try bindPattern(c, parameter, .{ .type = inferred }, &scope);
            }
            if (callback.body) |body| try annotateGuardNodes(c, m, body, &scope);
            return;
        }
    }
    if (node.type == .FunctionDeclaration or node.type == .FunctionExpression or node.type == .ArrowFunctionExpression) {
        if (node.body == null or !containsJsx(node.body.?)) return;
        var scope = try bindings.clone();
        for (node.params) |parameter| {
            const pattern = if (parameter.type == .AssignmentPattern) parameter.left.? else parameter;
            const contract = if (pattern.type_annotation) |annotation| try c.textType(m, annotation.slice(m.source)) else try c.make(.unknown);
            try bindPattern(c, parameter, .{ .type = contract }, &scope);
        }
        if (node.body) |body| try annotateGuardNodes(c, m, body, &scope);
        return;
    }
    for (ast.childFields(node.type)) |field| {
        if (field[1]) {
            for (ast.getList(node, field[0])) |child| if (child) |n| try annotateGuardNodes(c, m, n, bindings);
        } else if (ast.getSingle(node, field[0])) |n| try annotateGuardNodes(c, m, n, bindings);
    }
}
