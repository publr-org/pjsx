//! Component model extraction (the reference `ast.ts`): parses a PJSX module,
//! validates the exported component + `<name>Props` schema, expands private
//! configured JSX, resolves prop bindings, and analyzes component-local
//! reactive state and module-level compound-family stores.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Node = ast.Node;
const err = @import("err.zig");
const util = @import("util.zig");
const js = @import("js.zig");
const parser = @import("parser.zig");
const canonicalize_mod = @import("canonicalize.zig");

pub const Error = err.Error;
const OrderedMap = util.OrderedMap;
const StringList = util.StringList;

pub const PropType = enum {
    string,
    boolean,
    action,
    ref,
    children,
    node,
    element,
    style,
    number,
    array,
    @"union",
    optional_number,
    optional_string,
    optional_boolean,

    pub fn name(self: PropType) []const u8 {
        return switch (self) {
            .optional_number => "optional-number",
            .optional_string => "optional-string",
            .optional_boolean => "optional-boolean",
            else => @tagName(self),
        };
    }

    pub fn parse(text: []const u8) ?PropType {
        inline for (std.meta.fields(PropType)) |field| {
            const value: PropType = @enumFromInt(field.value);
            if (util.eql(value.name(), text)) return value;
        }
        return null;
    }
};

pub const ItemType = enum {
    string,
    number,
    boolean,

    pub fn name(self: ItemType) []const u8 {
        return @tagName(self);
    }
};

/// A string, boolean or number literal from the schema.
pub const Primitive = union(enum) {
    string: []const u8,
    boolean: bool,
    number: f64,

    pub fn toJs(self: Primitive) js.Value {
        return switch (self) {
            .string => |s| .{ .string = s },
            .boolean => |b| .{ .boolean = b },
            .number => |n| .{ .number = n },
        };
    }

    pub fn fromLiteral(literal: ast.LiteralValue) ?Primitive {
        return switch (literal) {
            .string => |s| .{ .string = s },
            .boolean => |b| .{ .boolean = b },
            .number => |n| .{ .number = n },
            else => null,
        };
    }

    pub fn asString(self: Primitive) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn eqlString(self: Primitive, text: []const u8) bool {
        return switch (self) {
            .string => |s| util.eql(s, text),
            else => false,
        };
    }

    /// `String(value)`
    pub fn toString(self: Primitive, allocator: Allocator) Allocator.Error![]const u8 {
        return self.toJs().toString(allocator);
    }
};

pub const PropSchema = struct {
    type: PropType,
    optional: bool,
    typescript: ?*@import("types.zig").Type = null,
    nullable: bool = false,
    default_expression: ?*Node = null,
    default: ?Primitive = null,
    values: ?[]const Primitive = null,
    tag_from: ?[]const u8 = null,
    internal: bool = false,
    fields: ?*Schema = null,
    items: ?ItemType = null,
    variants: ?[]const []const u8 = null,
};

pub const Schema = OrderedMap(PropSchema);

pub const RefBinding = struct { name: []const u8, access: []const u8 };

pub const SeedAssignment = struct { field: []const u8, value: *Node, statement: *Node };

/// Component-local reactive state (`const state = Publr.reactive({...})`).
/// The `foreign` / `family_*` fields are the family-wire extension server
/// targets consume: a family root compiles like a local island, a part file
/// that imports the family compiles wire-only.
pub const ReactiveBinding = struct {
    state_name: []const u8,
    wire_name: []const u8,
    initial_state: *Node,
    state_statement: *Node,
    local_statements: []*Node,
    actions: []const []const u8,
    argument_actions: []const []const u8,
    refs: []const RefBinding,
    constants: OrderedMap(*Node),
    foreign: bool = false,
    family_seeds: ?[]const SeedAssignment = null,
    family_action_locals: ?OrderedMap([]const u8) = null,

    pub fn hasAction(self: *const ReactiveBinding, name: []const u8) bool {
        return util.containsString(self.actions, name);
    }

    pub fn hasRef(self: *const ReactiveBinding, name: []const u8) bool {
        for (self.refs) |ref| if (util.eql(ref.name, name)) return true;
        return false;
    }
};

/// A compound-family store declared at module level in the owning part's file.
pub const FamilyBinding = struct {
    state_name: []const u8,
    wire_name: []const u8,
    initial_state: *Node,
    state_statement: *Node,
    module_statements: []*Node,
    actions: []const []const u8,
    refs: []const RefBinding,
    seed_assignments: []const SeedAssignment,
};

/// Family bindings this module imports from another part's file.
pub const ImportedFamily = struct {
    state_local: ?[]const u8,
    action_locals: OrderedMap([]const u8),
};

pub const ComponentAst = struct {
    name: []const u8,
    fn_node: *Node,
    root: *Node,
    prop_bindings: OrderedMap([]const u8),
    reactive: ?ReactiveBinding,
};

pub const ParsedModule = struct {
    program: *Node,
    component: ComponentAst,
    schema: *Schema,
    props_type: ?*@import("types.zig").Type = null,
    schema_name: []const u8,
    family: ?FamilyBinding,
    imported_family: ?ImportedFamily,
    /// The canonical (TSX) source the offsets refer to.
    canonical: []const u8,
};

pub const FiniteStringMaps = OrderedMap(OrderedMap([]const u8));

// ── Node helpers ───────────────────────────────────────────────────────────

/// Strip TS wrappers and parentheses.
pub fn unwrap(node: *Node) *Node {
    var current = node;
    while (current.type == .TSAsExpression or current.type == .TSNonNullExpression or current.type == .TSSatisfiesExpression or current.type == .ParenthesizedExpression) {
        current = current.expression.?;
    }
    return current;
}

pub fn unwrapOpt(node: ?*Node) Error!*Node {
    const n = node orelse return err.failMsg("pjsx: expected an expression");
    return unwrap(n);
}

/// Static key of a `Property` / pattern property (`Identifier` name or literal text).
pub fn propertyName(allocator: Allocator, node: *const Node) Allocator.Error!?[]const u8 {
    if (node.computed) return null;
    const key = node.key orelse return null;
    if (key.type == .Identifier) return key.name;
    if (key.type == .Literal) return try js.Value.fromLiteral(key.value).toString(allocator);
    return null;
}

fn literalValue(allocator: Allocator, node: ?*Node, label: []const u8) Error!Primitive {
    const n = node orelse return err.fail("pjsx: {s} is required", .{label});
    const value = unwrap(n);
    if (value.type != .Literal) return err.fail("pjsx: {s} must be a literal", .{label});
    _ = allocator;
    return Primitive.fromLiteral(value.value) orelse err.fail("pjsx: {s} must be a string, boolean, or number literal", .{label});
}

fn objectFields(allocator: Allocator, node: *Node, label: []const u8) Error!OrderedMap(*Node) {
    const value = unwrap(node);
    if (value.type != .ObjectExpression) return err.fail("pjsx: {s} must be an object literal", .{label});
    var fields = OrderedMap(*Node).init(allocator);
    for (value.properties) |field| {
        if (field.type != .Property) return err.fail("pjsx: {s} does not support spreads", .{label});
        const name = try propertyName(allocator, field) orelse return err.fail("pjsx: {s} has an unsupported computed key", .{label});
        try fields.put(name, field.value_node.?);
    }
    return fields;
}

fn literalList(allocator: Allocator, node: *Node, label: []const u8, what: []const u8) Error![]const Primitive {
    if (unwrap(node).type != .ArrayExpression) return err.fail("pjsx: {s} must be an array", .{label});
    var list: std.ArrayList(Primitive) = .empty;
    const full = try util.fmt(allocator, "{s}.{s}", .{ label, what });
    _ = full;
    for (unwrap(node).elements) |entry| {
        try list.append(allocator, try literalValue(allocator, entry, label));
    }
    return list.toOwnedSlice(allocator);
}

pub fn parseSchema(allocator: Allocator, node: *Node, label: []const u8) Error!*Schema {
    const fields = try objectFields(allocator, node, label);
    const schema = try allocator.create(Schema);
    schema.* = Schema.init(allocator);

    for (fields.keys(), fields.values()) |name, raw_definition| {
        const field_label = try util.fmt(allocator, "{s}.{s}", .{ label, name });
        const definition = try objectFields(allocator, raw_definition, field_label);
        const type_literal = try literalValue(allocator, definition.get("type"), try util.fmt(allocator, "{s}.type", .{field_label}));
        const prop_type = (if (type_literal.asString()) |text| PropType.parse(text) else null) orelse {
            return err.fail("pjsx: {s} uses unsupported POC prop type {s}", .{ field_label, try type_literal.toJs().toJson(allocator) });
        };
        const optional = if (definition.has("optional"))
            (try literalValue(allocator, definition.get("optional"), try util.fmt(allocator, "{s}.optional", .{field_label}))).toJs().truthy()
        else
            false;
        const default_value: ?Primitive = if (definition.has("default"))
            try literalValue(allocator, definition.get("default"), try util.fmt(allocator, "{s}.default", .{field_label}))
        else if (prop_type == .boolean)
            .{ .boolean = false }
        else if (prop_type == .string and optional)
            .{ .string = "" }
        else
            null;
        const allowed_values: ?[]const Primitive = if (definition.get("values")) |values|
            try literalList(allocator, values, try util.fmt(allocator, "{s}.values", .{field_label}), "values")
        else
            null;
        const allowed_len = if (allowed_values) |values| values.len else 0;
        if (prop_type == .element and (allowed_len == 0 or default_value == null or default_value.? != .string)) {
            return err.fail("pjsx: {s} element props need string default and values", .{field_label});
        }
        var tag_from: ?[]const u8 = null;
        if (definition.has("tagFrom")) {
            const literal = try literalValue(allocator, definition.get("tagFrom"), try util.fmt(allocator, "{s}.tagFrom", .{field_label}));
            tag_from = literal.asString() orelse return err.fail("pjsx: {s}.tagFrom must be a string", .{field_label});
        }
        const internal = if (definition.has("internal"))
            (try literalValue(allocator, definition.get("internal"), try util.fmt(allocator, "{s}.internal", .{field_label}))).toJs().truthy()
        else
            false;
        const item_fields = definition.get("fields");
        var item_type: ?ItemType = null;
        if (definition.has("items")) {
            const literal = try literalValue(allocator, definition.get("items"), try util.fmt(allocator, "{s}.items", .{field_label}));
            const text = literal.asString() orelse "";
            item_type = if (util.eql(text, "string")) .string else if (util.eql(text, "number")) .number else if (util.eql(text, "boolean")) .boolean else return err.fail("pjsx: {s}.items uses an unsupported primitive type", .{field_label});
        }
        if (prop_type == .array and item_fields == null and item_type == null) {
            return err.fail("pjsx: {s} array props need fields or items", .{field_label});
        }
        if (prop_type == .array and item_fields != null and item_type != null) {
            return err.fail("pjsx: {s} array props cannot use both fields and items", .{field_label});
        }
        if (prop_type != .array and (item_fields != null or item_type != null)) {
            return err.fail("pjsx: {s}.fields/items are only valid for array props", .{field_label});
        }
        var union_variants: ?[]const []const u8 = null;
        if (definition.get("variants")) |variants| {
            const literals = try literalList(allocator, variants, try util.fmt(allocator, "{s}.variants", .{field_label}), "variants");
            var list: StringList = .empty;
            for (literals) |literal| try list.append(allocator, try literal.toString(allocator));
            union_variants = try list.toOwnedSlice(allocator);
        }
        if (prop_type == .@"union") {
            const ok = union_variants != null and union_variants.?.len == 2 and util.eql(union_variants.?[0], "string") and util.eql(union_variants.?[1], "number-string-tuple");
            if (!ok) return err.fail("pjsx: {s} union currently supports [\"string\", \"number-string-tuple\"]", .{field_label});
        }
        if (prop_type != .@"union" and union_variants != null) {
            return err.fail("pjsx: {s}.variants is only valid for union props", .{field_label});
        }
        try schema.put(name, .{
            .type = prop_type,
            .optional = optional,
            .default = default_value,
            .values = allowed_values,
            .tag_from = tag_from,
            .internal = internal,
            .fields = if (item_fields) |f| try parseSchema(allocator, f, try util.fmt(allocator, "{s}.fields", .{field_label})) else null,
            .items = item_type,
            .variants = union_variants,
        });
    }
    return schema;
}

fn findReturnJsx(body: *Node) ?*Node {
    for (body.statements) |statement| {
        if (statement.type != .ReturnStatement) continue;
        const argument = statement.argument orelse continue;
        const value = unwrap(argument);
        if (value.isJsx()) return value;
    }
    return null;
}

// ── Configured JSX expansion ───────────────────────────────────────────────

const Environment = OrderedMap(*Node);

const PrivateComponent = struct { fn_node: *Node, root: *Node };
const PrivateComponents = OrderedMap(PrivateComponent);

fn literalNode(allocator: Allocator, value: js.Value, source: ?*const Node) Allocator.Error!*Node {
    const node = try ast.newNode(allocator, .Literal, if (source) |s| s.start else 0, if (source) |s| s.end else 0);
    node.value = value.toLiteral();
    node.raw = if (value == .string) try util.jsonString(allocator, value.string) else try value.toString(allocator);
    return node;
}

const MemberKey = union(enum) { name: []const u8, index: f64 };

fn configuredMemberName(allocator: Allocator, node: *const Node) Allocator.Error!?MemberKey {
    if (!node.computed and node.property != null and node.property.?.type == .Identifier) {
        return .{ .name = node.property.?.name };
    }
    const property = if (node.property) |p| unwrap(p) else return null;
    if (property.type == .Literal) {
        switch (property.value) {
            .string => |s| return .{ .name = s },
            .number => |n| return .{ .index = n },
            else => {},
        }
    }
    _ = allocator;
    return null;
}

fn configuredObjectField(allocator: Allocator, node: *Node, key: []const u8) Allocator.Error!?*Node {
    const object = unwrap(node);
    if (object.type != .ObjectExpression) return null;
    for (object.properties) |field| {
        if (field.type == .Property) {
            if (try propertyName(allocator, field)) |name| {
                if (util.eql(name, key)) return field.value_node;
            }
        }
    }
    return null;
}

const Known = struct { known: bool, value: js.Value = .undefined };

fn configuredPrimitive(node: *Node) Known {
    const value = unwrap(node);
    if (value.type == .Literal) return .{ .known = true, .value = js.Value.fromLiteral(value.value) };
    if (value.isIdentifier("undefined")) return .{ .known = true, .value = .undefined };
    return .{ .known = false };
}

fn foldConfiguredExpression(allocator: Allocator, node: *Node) Error!*Node {
    const value = unwrap(node);
    if (value.type == .UnaryExpression and util.eql(value.operator, "!")) {
        const argument = configuredPrimitive(value.argument.?);
        if (argument.known) return literalNode(allocator, .{ .boolean = !argument.value.truthy() }, value);
    }
    if (value.type == .BinaryExpression or value.type == .LogicalExpression) {
        const left = configuredPrimitive(value.left.?);
        if (util.eql(value.operator, "&&") and left.known) {
            return if (left.value.truthy()) value.right.? else literalNode(allocator, left.value, value);
        }
        if (util.eql(value.operator, "||") and left.known) {
            return if (left.value.truthy()) literalNode(allocator, left.value, value) else value.right.?;
        }
        const right = configuredPrimitive(value.right.?);
        if (left.known and right.known) {
            const l = left.value;
            const r = right.value;
            const op = value.operator;
            if (util.eql(op, "===")) return literalNode(allocator, .{ .boolean = js.Value.strictEquals(l, r) }, value);
            if (util.eql(op, "!==")) return literalNode(allocator, .{ .boolean = !js.Value.strictEquals(l, r) }, value);
            if (util.eql(op, "==")) return literalNode(allocator, .{ .boolean = js.Value.looseEquals(l, r) }, value);
            if (util.eql(op, "!=")) return literalNode(allocator, .{ .boolean = !js.Value.looseEquals(l, r) }, value);
            if (util.eql(op, "+")) return literalNode(allocator, try js.Value.add(l, r, allocator), value);
            if (util.eql(op, "-")) return literalNode(allocator, .{ .number = l.toNumber() - r.toNumber() }, value);
            if (util.eql(op, "<")) return literalNode(allocator, .{ .boolean = js.Value.lessThan(l, r) }, value);
            if (util.eql(op, "<=")) return literalNode(allocator, .{ .boolean = js.Value.lessThanOrEqual(l, r) }, value);
            if (util.eql(op, ">")) return literalNode(allocator, .{ .boolean = js.Value.lessThan(r, l) }, value);
            if (util.eql(op, ">=")) return literalNode(allocator, .{ .boolean = js.Value.lessThanOrEqual(r, l) }, value);
        }
    }
    if (value.type == .ConditionalExpression) {
        const test_ = configuredPrimitive(value.test_.?);
        if (test_.known) return if (test_.value.truthy()) value.consequent.? else value.alternate.?;
    }
    return value;
}

fn substituteConfiguredExpression(allocator: Allocator, input: *Node, environment: *const Environment) Error!*Node {
    const node = unwrap(input);
    if (node.type == .Identifier) {
        if (environment.get(node.name)) |replacement| {
            return substituteConfiguredExpression(allocator, replacement, environment);
        }
    }

    if (node.type == .MemberExpression) {
        const object = try substituteConfiguredExpression(allocator, node.object.?, environment);
        const property = if (node.computed) try substituteConfiguredExpression(allocator, node.property.?, environment) else node.property.?;
        const member = try node.clone(allocator);
        member.object = object;
        member.property = property;
        if (try configuredMemberName(allocator, member)) |key| {
            const collection = unwrap(object);
            if (collection.type == .ObjectExpression) {
                const key_text = switch (key) {
                    .name => |n| n,
                    .index => |i| try util.numberToString(allocator, i),
                };
                if (try configuredObjectField(allocator, collection, key_text)) |field| {
                    return substituteConfiguredExpression(allocator, field, environment);
                }
            }
            if (collection.type == .ArrayExpression and key == .index) {
                const index = key.index;
                if (index >= 0 and index == @trunc(index) and @as(usize, @intFromFloat(index)) < collection.elements.len) {
                    if (collection.elements[@intFromFloat(index)]) |element| {
                        return substituteConfiguredExpression(allocator, element, environment);
                    }
                }
            }
        }
        return member;
    }

    if (node.type == .CallExpression) {
        const callee = try substituteConfiguredExpression(allocator, node.callee.?, environment);
        const args = try allocator.alloc(*Node, node.arguments.len);
        for (node.arguments, 0..) |argument, i| args[i] = try substituteConfiguredExpression(allocator, argument, environment);
        if (callee.type == .ArrowFunctionExpression and callee.params.len == args.len) {
            var call_environment = try environment.clone();
            for (callee.params, 0..) |parameter, index| {
                if (parameter.type == .Identifier) try call_environment.put(parameter.name, args[index]);
            }
            return substituteConfiguredExpression(allocator, callee.body.?, &call_environment);
        }
        const call = try node.clone(allocator);
        call.callee = callee;
        call.arguments = args;
        return call;
    }

    if (node.type == .ArrowFunctionExpression or node.type == .FunctionExpression) {
        var body_environment = try environment.clone();
        for (node.params) |parameter| {
            if (parameter.type == .Identifier) body_environment.remove(parameter.name);
        }
        const function = try node.clone(allocator);
        const body = node.body.?;
        function.body = if (body.type == .BlockStatement)
            try cloneConfiguredNode(allocator, body, &body_environment)
        else
            try substituteConfiguredExpression(allocator, body, &body_environment);
        return function;
    }

    const cloned = try cloneConfiguredNode(allocator, node, environment);
    return foldConfiguredExpression(allocator, cloned);
}

fn cloneConfiguredNode(allocator: Allocator, node: *Node, environment: *const Environment) Error!*Node {
    const result = try node.clone(allocator);
    for (ast.childFields(node.type)) |cf| {
        const field = cf[0];
        if (field == .property and node.type == .MemberExpression and !node.computed) continue;
        if (field == .key and node.type == .Property and !node.computed) continue;
        if (cf[1]) {
            const list = ast.getList(node, field);
            const copy = try allocator.alloc(?*Node, list.len);
            for (list, 0..) |entry, i| {
                copy[i] = if (entry) |child| try substituteConfiguredExpression(allocator, child, environment) else null;
            }
            ast.setList(result, field, copy);
        } else if (ast.getSingle(node, field)) |child| {
            ast.setSingle(result, field, try substituteConfiguredExpression(allocator, child, environment));
        }
    }
    return result;
}

const RefAnnotator = struct {
    allocator: Allocator,

    fn annotate(self: RefAnnotator, node: *Node, wire_path: []const u8, access_path: []const u8) Error!void {
        const value = unwrap(node);
        if (value.type == .CallExpression and value.callee.?.isIdentifier("ref")) {
            value.pjsx_ref_name = wire_path;
            value.pjsx_ref_access = access_path;
            return;
        }
        if (value.type == .ArrayExpression) {
            for (value.elements, 0..) |item, index| {
                if (item) |element| {
                    try self.annotate(
                        element,
                        try util.fmt(self.allocator, "{s}.{d}", .{ wire_path, index }),
                        try util.fmt(self.allocator, "{s}[{d}]", .{ access_path, index }),
                    );
                }
            }
            return;
        }
        if (value.type == .ObjectExpression) {
            for (value.properties) |field| {
                if (field.type != .Property) continue;
                if (try propertyName(self.allocator, field)) |key| {
                    try self.annotate(
                        field.value_node.?,
                        try util.fmt(self.allocator, "{s}.{s}", .{ wire_path, key }),
                        try util.fmt(self.allocator, "{s}.{s}", .{ access_path, key }),
                    );
                }
            }
        }
    }
};

fn configuredConstants(allocator: Allocator, fn_node: *Node) Error!OrderedMap(*Node) {
    var constants = OrderedMap(*Node).init(allocator);
    const annotator = RefAnnotator{ .allocator = allocator };
    const body = fn_node.body orelse return constants;
    for (body.statements) |statement| {
        if (statement.type != .VariableDeclaration or statement.kind != .@"const") continue;
        for (statement.declarations) |declaration| {
            const id = declaration.id orelse continue;
            if (id.type == .Identifier and declaration.init != null) {
                const value = unwrap(declaration.init.?);
                try annotator.annotate(value, id.name, id.name);
                try constants.put(id.name, value);
            }
        }
    }
    return constants;
}

fn resolveConfiguredCollection(allocator: Allocator, node: *Node, environment: *const Environment, constants: *const OrderedMap(*Node)) Error!*Node {
    const substituted = try substituteConfiguredExpression(allocator, node, environment);
    if (substituted.type == .Identifier) {
        if (constants.get(substituted.name)) |constant| {
            return resolveConfiguredCollection(allocator, constant, environment, constants);
        }
    }
    return substituted;
}

fn addActionAdapterBindings(allocator: Allocator, fn_node: *Node, bindings: *OrderedMap([]const u8)) Error!void {
    const body = fn_node.body orelse return;
    for (body.statements) |statement| {
        if (statement.type != .VariableDeclaration) continue;
        for (statement.declarations) |declaration| {
            const id = declaration.id orelse continue;
            if (id.type != .Identifier or declaration.init == null) continue;
            const adapter = unwrap(declaration.init.?);
            if (adapter.type != .ArrowFunctionExpression and adapter.type != .FunctionExpression) continue;
            var called_props = util.StringSet.init(allocator);
            const Ctx = struct {
                bindings: *OrderedMap([]const u8),
                called: *util.StringSet,
                fn visit(self: @This(), node: *Node) anyerror!void {
                    if (node.type != .CallExpression or node.callee.?.type != .Identifier) return;
                    if (self.bindings.get(node.callee.?.name)) |prop| try self.called.put(prop, {});
                }
            };
            ast.walk(adapter.body.?, Ctx{ .bindings = bindings, .called = &called_props }, Ctx.visit) catch |e| return @as(Error, @errorCast(e));
            if (called_props.count() == 1) try bindings.put(id.name, called_props.keys()[0]);
        }
    }
}

const ConfiguredMap = struct { items: []*Node, callback: *Node };

fn configuredMap(allocator: Allocator, node: *Node, environment: *const Environment, constants: *const OrderedMap(*Node)) Error!?ConfiguredMap {
    const expression = unwrap(node);
    if (expression.type != .CallExpression) return null;
    const callee = expression.callee.?;
    if (callee.type != .MemberExpression or callee.computed or callee.property.?.type != .Identifier or !util.eql(callee.property.?.name, "map")) return null;
    const collection = try resolveConfiguredCollection(allocator, callee.object.?, environment, constants);
    const callback = if (expression.arguments.len > 0) unwrap(expression.arguments[0]) else null;
    if (collection.type != .ArrayExpression or callback == null or callback.?.type != .ArrowFunctionExpression) return null;
    for (callback.?.params) |parameter| if (parameter.type != .Identifier) return null;
    var items: std.ArrayList(*Node) = .empty;
    for (collection.elements) |element| if (element) |e| try items.append(allocator, e);
    return .{ .items = try items.toOwnedSlice(allocator), .callback = callback.? };
}

fn privateConfiguredComponents(allocator: Allocator, program: *Node) Error!PrivateComponents {
    var components = PrivateComponents.init(allocator);
    for (program.statements) |statement| {
        if (statement.type != .FunctionDeclaration or statement.id == null or statement.body == null) continue;
        if (findReturnJsx(statement.body.?)) |root| {
            try components.put(statement.id.?.name, .{ .fn_node = statement, .root = root });
        }
    }
    return components;
}

fn privateComponentEnvironment(allocator: Allocator, component: PrivateComponent, node: *Node, environment: *const Environment) Error!Environment {
    const fn_node = component.fn_node;
    if (fn_node.params.len != 1 or fn_node.params[0].type != .ObjectPattern) {
        return err.failMsg("pjsx: private JSX components need one destructured props object");
    }
    var attributes = OrderedMap(*Node).init(allocator);
    for (node.opening_element.?.attributes) |attribute| {
        if (attribute.type != .JSXAttribute) return err.failMsg("pjsx: private JSX components do not support spread props");
        const name_node = attribute.name_node.?;
        if (name_node.type != .JSXIdentifier) return err.failMsg("pjsx: private JSX component props must be named");
        const name = name_node.name;
        if (attribute.value_node == null) {
            try attributes.put(name, try literalNode(allocator, .{ .boolean = true }, attribute));
        } else if (attribute.value_node.?.type == .Literal) {
            try attributes.put(name, attribute.value_node.?);
        } else if (attribute.value_node.?.type == .JSXExpressionContainer) {
            try attributes.put(name, try substituteConfiguredExpression(allocator, attribute.value_node.?.expression.?, environment));
        } else {
            return err.fail("pjsx: private JSX component prop {s} is unsupported", .{name});
        }
    }

    var component_environment = try environment.clone();
    for (fn_node.params[0].properties) |field| {
        if (field.type != .Property or field.computed) return err.failMsg("pjsx: private JSX component props must be simple properties");
        const source_name = try propertyName(allocator, field);
        var target = field.value_node.?;
        var fallback: ?*Node = null;
        if (target.type == .AssignmentPattern) {
            fallback = target.right;
            target = target.left.?;
        }
        if (source_name == null or target.type != .Identifier) return err.failMsg("pjsx: private JSX component props must use identifiers");
        const value = attributes.get(source_name.?) orelse fallback orelse {
            return err.fail("pjsx: private JSX component prop {s} is required", .{source_name.?});
        };
        if (value.type == .Identifier and util.eql(value.name, target.name)) {
            component_environment.remove(target.name);
        } else {
            try component_environment.put(target.name, value);
        }
    }
    return component_environment;
}

fn expandConfiguredChild(allocator: Allocator, child: *Node, environment: *const Environment, constants: *const OrderedMap(*Node), components: *const PrivateComponents, out: *std.ArrayList(*Node)) Error!void {
    if (child.isJsx()) {
        try out.append(allocator, try expandConfiguredNode(allocator, child, environment, constants, components));
        return;
    }
    if (child.type != .JSXExpressionContainer or child.expression == null) {
        try out.append(allocator, child);
        return;
    }
    const expression = if (environment.count() > 0) try substituteConfiguredExpression(allocator, child.expression.?, environment) else child.expression.?;
    if (try configuredMap(allocator, expression, environment, constants)) |mapping| {
        for (mapping.items, 0..) |item, index| {
            var item_environment = try environment.clone();
            if (mapping.callback.params.len > 0) {
                const item_parameter = mapping.callback.params[0];
                if (item_parameter.type == .Identifier) try item_environment.put(item_parameter.name, item);
            }
            if (mapping.callback.params.len > 1) {
                const index_parameter = mapping.callback.params[1];
                if (index_parameter.type == .Identifier) {
                    try item_environment.put(index_parameter.name, try literalNode(allocator, .{ .number = @floatFromInt(index) }, index_parameter));
                }
            }
            const body = try substituteConfiguredExpression(allocator, mapping.callback.body.?, &item_environment);
            if (body.isJsx()) {
                try out.append(allocator, try expandConfiguredNode(allocator, body, &item_environment, constants, components));
            } else {
                const container = try child.clone(allocator);
                container.expression = body;
                try expandConfiguredChild(allocator, container, &item_environment, constants, components, out);
            }
        }
        return;
    }

    const folded = if (environment.count() > 0) try foldConfiguredExpression(allocator, expression) else expression;
    if (folded.isJsx()) {
        try out.append(allocator, try expandConfiguredNode(allocator, folded, environment, constants, components));
        return;
    }
    const container = try child.clone(allocator);
    container.expression = folded;
    try out.append(allocator, container);
}

fn expandConfiguredNode(allocator: Allocator, node: *Node, environment: *const Environment, constants: *const OrderedMap(*Node), components: *const PrivateComponents) Error!*Node {
    if (!node.isJsx()) return substituteConfiguredExpression(allocator, node, environment);
    if (node.type == .JSXFragment) {
        const fragment = try node.clone(allocator);
        var children: std.ArrayList(*Node) = .empty;
        for (node.children) |child| try expandConfiguredChild(allocator, child, environment, constants, components, &children);
        fragment.children = try children.toOwnedSlice(allocator);
        return fragment;
    }

    const opening = node.opening_element.?;
    if (opening.name_node.?.type == .JSXIdentifier) {
        if (components.get(opening.name_node.?.name)) |component| {
            const component_environment = try privateComponentEnvironment(allocator, component, node, environment);
            return expandConfiguredNode(allocator, component.root, &component_environment, constants, components);
        }
    }

    const new_opening = try opening.clone(allocator);
    var attributes: std.ArrayList(*Node) = .empty;
    for (opening.attributes) |attribute| {
        if (attribute.type != .JSXAttribute or attribute.value_node == null or attribute.value_node.?.type != .JSXExpressionContainer) {
            try attributes.append(allocator, attribute);
            continue;
        }
        const container = attribute.value_node.?;
        const expression = if (environment.count() > 0) try substituteConfiguredExpression(allocator, container.expression.?, environment) else container.expression.?;
        const primitive = configuredPrimitive(expression);
        if (primitive.known and primitive.value == .undefined) continue;
        const new_attribute = try attribute.clone(allocator);
        const new_container = try container.clone(allocator);
        new_container.expression = expression;
        new_attribute.value_node = new_container;
        try attributes.append(allocator, new_attribute);
    }
    new_opening.attributes = try attributes.toOwnedSlice(allocator);
    const element = try node.clone(allocator);
    element.opening_element = new_opening;
    var children: std.ArrayList(*Node) = .empty;
    for (node.children) |child| try expandConfiguredChild(allocator, child, environment, constants, components, &children);
    element.children = try children.toOwnedSlice(allocator);
    return element;
}

fn expandConfiguredJsx(allocator: Allocator, root: *Node, fn_node: *Node, program: *Node) Error!*Node {
    const constants = try configuredConstants(allocator, fn_node);
    var aliases = Environment.init(allocator);
    for (constants.keys(), constants.values()) |name, candidate| {
        const value = unwrap(candidate);
        if (value.type == .Identifier or value.type == .MemberExpression) try aliases.put(name, value);
    }
    const components = try privateConfiguredComponents(allocator, program);
    return expandConfiguredNode(allocator, root, &aliases, &constants, &components);
}

// ── Prop bindings ──────────────────────────────────────────────────────────

fn destructuredProps(allocator: Allocator, fn_node: *Node) Error!OrderedMap([]const u8) {
    var names = OrderedMap([]const u8).init(allocator);
    if (fn_node.params.len == 0) return names;
    if (fn_node.params.len != 1) return err.failMsg("pjsx: component must take zero or one props object");
    const param = fn_node.params[0];
    if (param.type == .Identifier) {
        const props_name = param.name;
        try names.put(props_name, "$props");
        const Ctx = struct {
            allocator: Allocator,
            props_name: []const u8,
            names: *OrderedMap([]const u8),
            fn visit(self: @This(), record: *Node) anyerror!void {
                if (record.type != .MemberExpression) return;
                const object = record.object orelse return;
                if (!object.isIdentifier(self.props_name)) return;
                const property_node = record.property orelse return error.Pjsx;
                const property: ?[]const u8 = if (!record.computed and property_node.type == .Identifier)
                    property_node.name
                else if (record.computed and property_node.type == .Literal and property_node.value == .string)
                    property_node.value.string
                else
                    null;
                if (property == null) return err.failMsg("pjsx: component props need static property names");
                try self.names.put(try util.fmt(self.allocator, "{s}.{s}", .{ self.props_name, property.? }), property.?);
            }
        };
        ast.walk(fn_node.body.?, Ctx{ .allocator = allocator, .props_name = props_name, .names = &names }, Ctx.visit) catch |e| return @as(Error, @errorCast(e));
        return names;
    }
    if (param.type != .ObjectPattern) return err.failMsg("pjsx: component must take zero or one props object");
    for (param.properties) |field| {
        if (field.type != .Property or field.computed) return err.failMsg("pjsx: component prop rest/computed patterns are not supported");
        const source_name = try propertyName(allocator, field);
        var target = field.value_node.?;
        if (target.type == .AssignmentPattern) target = target.left.?;
        if (source_name == null or target.type != .Identifier) return err.failMsg("pjsx: component props must use simple identifiers");
        try names.put(target.name, source_name.?);
    }
    return names;
}

// ── Reactive state ─────────────────────────────────────────────────────────

/// `() => call(...)` / `() => { call(...); }` — the called expression.
pub fn arrowCall(node: *Node) ?*Node {
    const value = unwrap(node);
    if (value.type != .ArrowFunctionExpression or value.params.len != 0) return null;
    const body = unwrap(value.body.?);
    if (body.type == .CallExpression) return body;
    if (body.type == .BlockStatement and body.statements.len == 1 and body.statements[0].type == .ExpressionStatement) {
        const expression = unwrap(body.statements[0].expression.?);
        return if (expression.type == .CallExpression) expression else null;
    }
    return null;
}

const ActionMode = enum { event, arguments };

fn referencedActions(allocator: Allocator, root: *Node) Error!OrderedMap(ActionMode) {
    var actions = OrderedMap(ActionMode).init(allocator);
    const Ctx = struct {
        actions: *OrderedMap(ActionMode),
        fn visit(self: @This(), node: *Node) anyerror!void {
            if (node.type != .JSXAttribute) return;
            const name_node = node.name_node orelse return;
            if (name_node.type != .JSXIdentifier or !util.isEventProp(name_node.name)) return;
            const value = node.value_node orelse return;
            if (value.type != .JSXExpressionContainer) return;
            const expression = unwrap(value.expression.?);
            if (expression.type == .Identifier) {
                if (!self.actions.has(expression.name)) try self.actions.put(expression.name, .event);
                return;
            }
            if (arrowCall(expression)) |call| {
                if (call.callee.?.type == .Identifier) try self.actions.put(call.callee.?.name, .arguments);
            }
        }
    };
    ast.walk(root, Ctx{ .actions = &actions }, Ctx.visit) catch |e| return @as(Error, @errorCast(e));
    return actions;
}

fn containsIdentifier(node: *Node, name: []const u8) bool {
    const Pred = struct {
        fn check(target: []const u8, candidate: *Node) bool {
            return candidate.isIdentifier(target);
        }
    };
    return ast.contains(node, name, Pred.check);
}

fn isInitialReturn(statement: *Node, context_name: []const u8) bool {
    if (statement.type != .IfStatement or statement.alternate != null) return false;
    const test_ = unwrap(statement.test_.?);
    const checks_initial = test_.type == .MemberExpression and !test_.computed and
        test_.object != null and test_.object.?.isIdentifier(context_name) and
        test_.property != null and test_.property.?.isIdentifier("isInitial");
    if (!checks_initial) return false;
    const consequent = statement.consequent orelse return false;
    if (consequent.type == .ReturnStatement) return true;
    if (consequent.type == .BlockStatement) {
        for (consequent.statements) |candidate| if (candidate.type == .ReturnStatement) return true;
    }
    return false;
}

fn validateEffect(call: *Node, state_name: []const u8) Error!void {
    const callback = if (call.arguments.len > 0) unwrap(call.arguments[0]) else return;
    if ((callback.type != .ArrowFunctionExpression and callback.type != .FunctionExpression) or callback.body.?.type != .BlockStatement) return;
    if (callback.params.len == 0 or callback.params[0].type != .Identifier) return;
    const statements = callback.body.?.statements;
    var read_state = false;
    for (statements, 0..) |statement, index| {
        const reads_here = containsIdentifier(statement, state_name);
        if (isInitialReturn(statement, callback.params[0].name) and !read_state and !reads_here) {
            var later_reads = false;
            for (statements[index + 1 ..]) |candidate| {
                if (containsIdentifier(candidate, state_name)) later_reads = true;
            }
            if (later_reads) return err.fail("pjsx: effect() must read {s} before returning on context.isInitial", .{state_name});
        }
        read_state = read_state or reads_here;
    }
}

fn isReactiveCallee(callee: *Node) bool {
    if (callee.type == .Identifier) return util.eql(callee.name, "reactive");
    return callee.type == .MemberExpression and !callee.computed and
        callee.object.?.isIdentifier("Publr") and callee.property.?.isIdentifier("reactive");
}

/// `localeCompare` ordering for identifier-like strings.
fn localeLess(_: void, a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        const la = std.ascii.toLower(a[i]);
        const lb = std.ascii.toLower(b[i]);
        if (la != lb) return la < lb;
    }
    if (a.len != b.len) return a.len < b.len;
    for (0..n) |i| {
        if (a[i] != b[i]) return std.ascii.isLower(a[i]);
    }
    return false;
}

fn refLess(_: void, a: RefBinding, b: RefBinding) bool {
    return localeLess({}, a.name, b.name);
}

fn sortedRefs(allocator: Allocator, refs: *const OrderedMap(RefBinding)) Allocator.Error![]RefBinding {
    const list = try allocator.dupe(RefBinding, refs.values());
    std.mem.sort(RefBinding, list, {}, refLess);
    return list;
}

fn reactiveBinding(allocator: Allocator, fn_node: *Node, root: *Node, component_name: []const u8) Error!?ReactiveBinding {
    var state_name: ?[]const u8 = null;
    var initial_state: ?*Node = null;
    var state_statement: ?*Node = null;
    const body = fn_node.body orelse return null;

    for (body.statements) |statement| {
        if (statement.type != .VariableDeclaration) continue;
        for (statement.declarations) |declaration| {
            const init = declaration.init;
            const reactive_call = init != null and init.?.type == .CallExpression and isReactiveCallee(init.?.callee.?);
            if (declaration.id.?.type != .Identifier or !reactive_call) continue;
            const input = if (init.?.arguments.len > 0) init.?.arguments[0] else null;
            if (input == null or unwrap(input.?).type != .ObjectExpression) {
                return err.failMsg("pjsx: reactive() needs a statically analyzable object");
            }
            if (state_name != null) return err.failMsg("pjsx: a component may declare one local reactive state");
            state_name = declaration.id.?.name;
            initial_state = unwrap(input.?);
            state_statement = statement;
        }
    }

    if (state_name == null) return null;

    const all_referenced = try referencedActions(allocator, root);
    const bindings = try destructuredProps(allocator, fn_node);
    var referenced = OrderedMap(ActionMode).init(allocator);
    for (all_referenced.keys(), all_referenced.values()) |name, mode| {
        if (!bindings.has(name)) try referenced.put(name, mode);
    }
    var declared_functions = util.StringSet.init(allocator);
    var local_statements: std.ArrayList(*Node) = .empty;
    var refs = OrderedMap(RefBinding).init(allocator);
    for (body.statements) |statement| {
        if (statement == state_statement.? or statement.type == .ReturnStatement) continue;
        if (statement.type == .VariableDeclaration) {
            var contains_function = false;
            var contains_ref = false;
            for (statement.declarations) |declaration| {
                const id = declaration.id.?;
                if (id.type == .Identifier and declaration.init != null and
                    (declaration.init.?.type == .ArrowFunctionExpression or declaration.init.?.type == .FunctionExpression))
                {
                    try declared_functions.put(id.name, {});
                    contains_function = true;
                }
                if (declaration.init) |init| {
                    const Ctx = struct {
                        declaration: *Node,
                        refs: *OrderedMap(RefBinding),
                        contains_ref: *bool,
                        fn visit(self: @This(), candidate: *Node) anyerror!void {
                            if (candidate.type != .CallExpression or !candidate.callee.?.isIdentifier("ref")) return;
                            const decl_id = self.declaration.id.?;
                            const top_level_name: ?[]const u8 = if (decl_id.type == .Identifier and candidate == unwrap(self.declaration.init.?)) decl_id.name else null;
                            const name = candidate.pjsx_ref_name orelse top_level_name;
                            const access = candidate.pjsx_ref_access orelse top_level_name;
                            if (name != null and access != null) try self.refs.put(name.?, .{ .name = name.?, .access = access.? });
                            self.contains_ref.* = true;
                        }
                    };
                    ast.walk(init, Ctx{ .declaration = declaration, .refs = &refs, .contains_ref = &contains_ref }, Ctx.visit) catch |e| return @as(Error, @errorCast(e));
                }
            }
            if (contains_function or contains_ref) try local_statements.append(allocator, statement);
        } else if (statement.type == .FunctionDeclaration and statement.id != null) {
            try declared_functions.put(statement.id.?.name, {});
            try local_statements.append(allocator, statement);
        } else if (statement.type == .ExpressionStatement and statement.expression.?.type == .CallExpression and
            statement.expression.?.callee.?.isIdentifier("effect"))
        {
            try validateEffect(statement.expression.?, state_name.?);
            try local_statements.append(allocator, statement);
        }
    }

    for (referenced.keys()) |action| {
        if (!declared_functions.has(action)) {
            return err.fail("pjsx: reactive action {s} must be a named local function", .{action});
        }
    }

    const actions = try allocator.dupe([]const u8, referenced.keys());
    util.sortStrings(actions);
    var argument_actions: StringList = .empty;
    for (referenced.keys(), referenced.values()) |name, mode| {
        if (mode == .arguments) try argument_actions.append(allocator, name);
    }
    const argument_list = try argument_actions.toOwnedSlice(allocator);
    util.sortStrings(argument_list);

    return .{
        .state_name = state_name.?,
        .wire_name = try util.kebabCase(allocator, component_name),
        .initial_state = initial_state.?,
        .state_statement = state_statement.?,
        .local_statements = try local_statements.toOwnedSlice(allocator),
        .actions = actions,
        .argument_actions = argument_list,
        .refs = try sortedRefs(allocator, &refs),
        .constants = try configuredConstants(allocator, fn_node),
    };
}

/// `name(...)` or `Publr.name(...)`
pub fn isPublrCall(node: ?*Node, call_name: []const u8) bool {
    const n = node orelse return false;
    if (n.type != .CallExpression) return false;
    const callee = n.callee.?;
    if (callee.type == .Identifier) return util.eql(callee.name, call_name);
    return callee.type == .MemberExpression and !callee.computed and
        callee.object.?.isIdentifier("Publr") and callee.property.?.isIdentifier(call_name);
}

fn familyBinding(allocator: Allocator, program: *Node, fn_node: *Node, component_name: []const u8) Error!?FamilyBinding {
    var state_name: ?[]const u8 = null;
    var initial_state: ?*Node = null;
    var state_statement: ?*Node = null;
    var actions = util.StringSet.init(allocator);
    var module_statements: std.ArrayList(*Node) = .empty;
    var refs = OrderedMap(RefBinding).init(allocator);

    for (program.statements) |statement| {
        const exported = statement.type == .ExportNamedDeclaration;
        const declaration = (if (exported) statement.declaration else statement) orelse continue;

        if (declaration.type == .VariableDeclaration) {
            var carries = false;
            for (declaration.declarations) |item| {
                const id = item.id.?;
                if (id.type != .Identifier or item.init == null) continue;
                const init = unwrap(item.init.?);
                if (isPublrCall(init, "reactive")) {
                    if (!exported) return err.failMsg("pjsx: a module-level reactive family store must be exported");
                    if (!util.eql(id.name, "state")) return err.failMsg("pjsx: a module-level family store must be exported as `state`");
                    if (state_name != null) return err.failMsg("pjsx: a module may declare one family store");
                    const input = if (init.arguments.len > 0) init.arguments[0] else null;
                    if (input == null or unwrap(input.?).type != .ObjectExpression) {
                        return err.failMsg("pjsx: reactive() needs a statically analyzable object");
                    }
                    state_name = id.name;
                    initial_state = unwrap(input.?);
                    state_statement = declaration;
                    continue;
                }
                if (init.type == .ArrowFunctionExpression or init.type == .FunctionExpression) {
                    if (exported) try actions.put(id.name, {});
                    carries = true;
                }
                if (!exported) carries = true;
                const Ctx = struct {
                    item: *Node,
                    init: *Node,
                    refs: *OrderedMap(RefBinding),
                    carries: *bool,
                    fn visit(self: @This(), candidate: *Node) anyerror!void {
                        if (!isPublrCall(candidate, "ref")) return;
                        const item_id = self.item.id.?;
                        const top_level_name: ?[]const u8 = if (item_id.type == .Identifier and candidate == self.init) item_id.name else null;
                        const name = candidate.pjsx_ref_name orelse top_level_name;
                        const access = candidate.pjsx_ref_access orelse top_level_name;
                        if (name != null and access != null) try self.refs.put(name.?, .{ .name = name.?, .access = access.? });
                        self.carries.* = true;
                    }
                };
                ast.walk(init, Ctx{ .item = item, .init = init, .refs = &refs, .carries = &carries }, Ctx.visit) catch |e| return @as(Error, @errorCast(e));
            }
            if (carries and declaration != state_statement) try module_statements.append(allocator, declaration);
            continue;
        }

        if (declaration.type == .FunctionDeclaration and declaration.id != null) {
            const name = declaration.id.?.name;
            if (util.eql(name, component_name)) continue;
            // An exported function is an action; a private one is a helper the
            // actions call, carried like a private `const`. Components are not.
            if (exported) {
                try actions.put(name, {});
                try module_statements.append(allocator, declaration);
            } else if (name.len > 0 and !std.ascii.isUpper(name[0])) {
                try module_statements.append(allocator, declaration);
            }
            continue;
        }

        if (declaration.type == .ExpressionStatement and isPublrCall(declaration.expression, "effect")) {
            try module_statements.append(allocator, declaration);
        }
    }

    if (state_name == null) return null;

    var seeds: std.ArrayList(SeedAssignment) = .empty;
    if (fn_node.body) |body| {
        for (body.statements) |statement| {
            if (statement.type != .ExpressionStatement) continue;
            const expression = statement.expression.?;
            if (expression.type != .AssignmentExpression or !util.eql(expression.operator, "=")) continue;
            const left = expression.left.?;
            if (left.type == .MemberExpression and !left.computed and left.object.?.isIdentifier(state_name.?) and left.property.?.type == .Identifier) {
                try seeds.append(allocator, .{ .field = left.property.?.name, .value = expression.right.?, .statement = statement });
            }
        }
    }

    const action_list = try allocator.dupe([]const u8, actions.keys());
    util.sortStrings(action_list);

    return .{
        .state_name = state_name.?,
        .wire_name = try util.kebabCase(allocator, component_name),
        .initial_state = initial_state.?,
        .state_statement = state_statement.?,
        .module_statements = try module_statements.toOwnedSlice(allocator),
        .actions = action_list,
        .refs = try sortedRefs(allocator, &refs),
        .seed_assignments = try seeds.toOwnedSlice(allocator),
    };
}

/// The imported binding's exported name (`Identifier` name or string literal).
pub fn importedName(allocator: Allocator, specifier: *const Node) Allocator.Error![]const u8 {
    const imported = specifier.imported.?;
    if (imported.type == .Identifier) return imported.name;
    return js.Value.fromLiteral(imported.value).toString(allocator);
}

fn importedFamilyBindings(allocator: Allocator, program: *Node) Error!?ImportedFamily {
    var state_local: ?[]const u8 = null;
    var action_locals = OrderedMap([]const u8).init(allocator);

    for (program.statements) |statement| {
        if (statement.type != .ImportDeclaration or statement.import_kind == .type) continue;
        const source = statement.source.?.stringValue() orelse continue;
        if (!util.hasPjsxExtension(source)) continue;
        for (statement.specifiers) |specifier| {
            if (specifier.type != .ImportSpecifier or specifier.import_kind == .type) continue;
            const imported = try importedName(allocator, specifier);
            if (!util.startsWithLower(imported)) continue;
            if (util.eql(imported, "state")) state_local = specifier.local.?.name else try action_locals.put(specifier.local.?.name, imported);
        }
    }

    if (state_local == null and action_locals.count() == 0) return null;
    return .{ .state_local = state_local, .action_locals = action_locals };
}

// ── Entry ──────────────────────────────────────────────────────────────────

pub fn parsePjsx(allocator: Allocator, source: []const u8, filename: []const u8) Error!ParsedModule {
    return parsePjsxWithResolver(allocator, source, filename, null);
}

pub fn parsePjsxWithResolver(allocator: Allocator, source: []const u8, filename: []const u8, resolver: ?@import("types.zig").Resolver) Error!ParsedModule {
    const canonical = try canonicalize_mod.canonicalize(allocator, source);
    const program = parser.parse(allocator, canonical.code, filename) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.Pjsx => {
            const message = try allocator.dupe(u8, err.message());
            return err.fail("pjsx: {s}: {s}", .{ filename, message });
        },
    };

    var schemas = OrderedMap(*Schema).init(allocator);
    var components: std.ArrayList(ComponentAst) = .empty;

    for (program.statements) |statement| {
        if (statement.type != .ExportNamedDeclaration) continue;
        const declaration = statement.declaration orelse continue;

        if (declaration.type == .VariableDeclaration) {
            for (declaration.declarations) |item| {
                const id = item.id.?;
                if (id.type == .Identifier and std.mem.endsWith(u8, id.name, "Props") and item.init != null) {
                    try schemas.put(id.name, try parseSchema(allocator, item.init.?, id.name));
                }
            }
            continue;
        }

        if (declaration.type == .FunctionDeclaration and declaration.id != null and declaration.body != null) {
            if (findReturnJsx(declaration.body.?)) |returned_root| {
                const root = try expandConfiguredJsx(allocator, returned_root, declaration, program);
                var prop_bindings = try destructuredProps(allocator, declaration);
                try addActionAdapterBindings(allocator, declaration, &prop_bindings);
                try components.append(allocator, .{
                    .name = declaration.id.?.name,
                    .fn_node = declaration,
                    .root = root,
                    .prop_bindings = prop_bindings,
                    .reactive = try reactiveBinding(allocator, declaration, root, declaration.id.?.name),
                });
            }
        }
    }

    if (components.items.len != 1) {
        return err.fail("pjsx: {s} must export exactly one JSX component (found {d})", .{ filename, components.items.len });
    }

    const component = components.items[0];
    const schema_name = try util.concat(allocator, &.{ try util.lowerFirst(allocator, component.name), "Props" });
    const inferred = if (schemas.has(schema_name)) null else try @import("types.zig").infer(allocator, program, canonical.code, filename, component.fn_node, resolver);
    const schema = if (inferred) |result| result.schema else schemas.get(schema_name).?;

    for (component.prop_bindings.values()) |prop_name| {
        if (util.eql(prop_name, "$props")) continue;
        if (!schema.has(prop_name)) return err.fail("pjsx: {s} reads undeclared prop {s}", .{ component.name, prop_name });
    }

    const family = try familyBinding(allocator, program, component.fn_node, component.name);
    if (family != null and component.reactive != null) {
        return err.fail("pjsx: {s} cannot declare both a family store and component-local reactive state", .{component.name});
    }

    return .{
        .program = program,
        .component = component,
        .schema = schema,
        .props_type = if (inferred) |result| result.contract else null,
        .schema_name = schema_name,
        .family = family,
        .imported_family = try importedFamilyBindings(allocator, program),
        .canonical = canonical.code,
    };
}

pub fn collectFiniteStringMaps(allocator: Allocator, program: *Node) Error!FiniteStringMaps {
    var maps = FiniteStringMaps.init(allocator);
    for (program.statements) |statement| {
        const declaration = (if (statement.type == .ExportNamedDeclaration) statement.declaration else statement) orelse continue;
        if (declaration.type != .VariableDeclaration) continue;
        for (declaration.declarations) |item| {
            const id = item.id.?;
            if (id.type != .Identifier or item.init == null) continue;
            const value = unwrap(item.init.?);
            if (value.type != .ObjectExpression) continue;
            var entries = OrderedMap([]const u8).init(allocator);
            var finite = true;
            for (value.properties) |field| {
                if (field.type != .Property or field.computed) {
                    finite = false;
                    break;
                }
                const key = try propertyName(allocator, field);
                const field_value = unwrap(field.value_node.?);
                if (key == null or field_value.type != .Literal or field_value.value != .string) {
                    finite = false;
                    break;
                }
                try entries.put(key.?, field_value.value.string);
            }
            if (finite and entries.count() > 0) try maps.put(id.name, entries);
        }
    }
    return maps;
}

/// Module-level `const NAME = "literal"` (or a template literal with no interpolation):
/// values every target can inline wherever the name is read.
pub fn collectStringConstants(allocator: Allocator, program: *Node) Error!OrderedMap([]const u8) {
    var constants = OrderedMap([]const u8).init(allocator);
    for (program.statements) |statement| {
        const declaration = (if (statement.type == .ExportNamedDeclaration) statement.declaration else statement) orelse continue;
        if (declaration.type != .VariableDeclaration or declaration.kind != .@"const") continue;
        for (declaration.declarations) |item| {
            const id = item.id.?;
            if (id.type != .Identifier or item.init == null) continue;
            const value = unwrap(item.init.?);
            if (value.type == .Literal and value.value == .string) {
                try constants.put(id.name, value.value.string);
            } else if (value.type == .TemplateLiteral and value.expressions.len == 0 and value.quasis.len == 1) {
                try constants.put(id.name, value.quasis[0].cooked orelse continue);
            }
        }
    }
    return constants;
}

pub fn collectClassTokens(allocator: Allocator, parsed: *const ParsedModule) Error![]const []const u8 {
    var classes = util.StringSet.init(allocator);
    const finite_maps = try collectFiniteStringMaps(allocator, parsed.program);
    const Ctx = struct {
        allocator: Allocator,
        parsed: *const ParsedModule,
        classes: *util.StringSet,
        finite_maps: *const FiniteStringMaps,

        fn add(self: @This(), value: []const u8) Allocator.Error!void {
            for (try util.splitWhitespace(self.allocator, value)) |token| try self.classes.put(token, {});
        }

        fn visit(self: @This(), node: *Node) anyerror!void {
            if (node.type != .JSXAttribute) return;
            const name_node = node.name_node.?;
            if (name_node.type != .JSXIdentifier) return;
            const is_class = util.eql(name_node.name, "class") or util.eql(name_node.name, "className");
            // A component's `classes` prop at a call site carries utilities too; they must
            // reach the manifest like any `class` attribute would.
            const is_classes = util.eql(name_node.name, "classes");
            if (!is_class and !is_classes) return;
            const value = node.value_node;
            if (value != null and value.?.type == .Literal and value.?.value == .string) {
                try self.add(value.?.value.string);
                return;
            }
            if (value == null or value.?.type != .JSXExpressionContainer) {
                if (is_classes) return;
                return err.failMsg("pjsx: class must be a literal or finite literal expression");
            }
            const expression = unwrap(value.?.expression.?);
            if (is_classes) {
                // Whatever literal parts the expression carries, without insisting on any:
                // `classes={classes}` inside a component is that component's own concern.
                var found_in_classes = false;
                const Parts = struct {
                    outer: *const @This().Outer,
                    found: *bool,
                    const Outer = @TypeOf(self);
                    fn visitPart(inner: @This(), part: *Node) anyerror!void {
                        if (part.type == .Literal and part.value == .string) {
                            inner.found.* = true;
                            try inner.outer.add(part.value.string);
                        } else if (part.type == .TemplateLiteral) {
                            inner.found.* = true;
                            for (part.quasis) |quasi| try inner.outer.add(quasi.cooked orelse "");
                        }
                    }
                };
                try ast.walk(value.?.expression.?, Parts{ .outer = &self, .found = &found_in_classes }, Parts.visitPart);
                return;
            }
            const bindings = &self.parsed.component.prop_bindings;
            const bound_class_prop: ?[]const u8 = if (expression.type == .Identifier)
                bindings.get(expression.name)
            else if (expression.type == .MemberExpression and !expression.computed and expression.object.?.type == .Identifier and expression.property.?.type == .Identifier)
                bindings.get(try util.fmt(self.allocator, "{s}.{s}", .{ expression.object.?.name, expression.property.?.name }))
            else
                null;
            if (bound_class_prop != null and util.eql(bound_class_prop.?, "classes")) return;
            if (expression.type == .MemberExpression and !expression.computed and expression.property.?.isIdentifier("classes")) return;

            var found = false;
            const Inner = struct {
                outer: *const @This().Outer,
                found: *bool,
                const Outer = @TypeOf(self);
                fn visitPart(inner: @This(), part: *Node) anyerror!void {
                    if (part.type == .Literal and part.value == .string) {
                        inner.found.* = true;
                        try inner.outer.add(part.value.string);
                    } else if (part.type == .TemplateLiteral) {
                        inner.found.* = true;
                        for (part.quasis) |quasi| try inner.outer.add(quasi.cooked orelse "");
                    } else if (part.type == .MemberExpression and part.computed and part.object.?.type == .Identifier) {
                        const map = inner.outer.finite_maps.get(part.object.?.name) orelse return;
                        inner.found.* = true;
                        for (map.values()) |class_value| try inner.outer.add(class_value);
                    }
                }
            };
            try ast.walk(value.?.expression.?, Inner{ .outer = &self, .found = &found }, Inner.visitPart);
            if (!found) return err.failMsg("pjsx: dynamic class expressions need statically enumerable literals");
        }
    };
    ast.walk(parsed.component.root, Ctx{ .allocator = allocator, .parsed = parsed, .classes = &classes, .finite_maps = &finite_maps }, Ctx.visit) catch |e| return @as(Error, @errorCast(e));
    const list = try allocator.dupe([]const u8, classes.keys());
    util.sortStrings(list);
    return list;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const badge_source =
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
;

test "parsePjsx extracts the component, schema and class tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = parsePjsx(a, badge_source, "badge.pjsx") catch |e| {
        std.debug.print("{s}\n", .{err.message()});
        return e;
    };
    try std.testing.expectEqualStrings("Badge", parsed.component.name);
    try std.testing.expectEqualStrings("badgeProps", parsed.schema_name);
    try std.testing.expectEqual(PropType.string, parsed.schema.get("label").?.type);
    try std.testing.expectEqualStrings("label", parsed.component.prop_bindings.get("label").?);
    const classes = try collectClassTokens(a, &parsed);
    try std.testing.expectEqual(@as(usize, 4), classes.len);
    try std.testing.expectEqualStrings("inline-flex", classes[0]);
    try std.testing.expectEqualStrings("text-foreground", classes[3]);
}

test "parsePjsx requires one component and derives an empty props contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.Pjsx, parsePjsx(a,
        \\export const fieldProps = {};
        \\export function Field() { return <div />; }
        \\export function FieldLabel() { return <label />; }
    , "multi.ptsx"));
    try std.testing.expect(util.indexOf(err.message(), "must export exactly one JSX component (found 2)") != null);
    const widget = try parsePjsx(a, "export function Widget() { return <div />; }", "widget.ptsx");
    try std.testing.expectEqual(@as(usize, 0), widget.schema.count());
}

test "reactive state analysis finds actions, refs and the wire name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = parsePjsx(a,
        \\import { Publr } from "publr/dom";
        \\export const textDemoProps = {};
        \\export function TextDemo() {
        \\  const state = Publr.reactive({ open: false });
        \\  const panel = ref();
        \\  const open = () => { state.open = true; };
        \\  return <section><button onClick={open} onKeydown={() => open(1)}>Open</button><div ref={panel} $$show={state.open} /></section>;
        \\}
    , "text-demo.ptsx") catch |e| {
        std.debug.print("{s}\n", .{err.message()});
        return e;
    };
    const reactive = parsed.component.reactive.?;
    try std.testing.expectEqualStrings("state", reactive.state_name);
    try std.testing.expectEqualStrings("text-demo", reactive.wire_name);
    try std.testing.expectEqual(@as(usize, 1), reactive.actions.len);
    try std.testing.expectEqualStrings("open", reactive.actions[0]);
    try std.testing.expectEqualStrings("open", reactive.argument_actions[0]);
    try std.testing.expectEqualStrings("panel", reactive.refs[0].name);
    try std.testing.expectEqual(@as(usize, 2), reactive.local_statements.len);
}

test "family bindings and imported families are analyzed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = parsePjsx(a,
        \\import { Publr } from "publr/dom";
        \\export const state = Publr.reactive({ open: false });
        \\export const toggle = (event: Event) => { state.open = !state.open; };
        \\export const disclosureProps = { startOpen: { type: "boolean", optional: true, default: false } };
        \\export function Disclosure({ startOpen = false }) {
        \\  state.open = startOpen;
        \\  return <div data-part="disclosure" />;
        \\}
    , "Disclosure.ptsx") catch |e| {
        std.debug.print("{s}\n", .{err.message()});
        return e;
    };
    try std.testing.expectEqualStrings("disclosure", root.family.?.wire_name);
    try std.testing.expectEqualStrings("toggle", root.family.?.actions[0]);
    try std.testing.expectEqual(@as(usize, 1), root.family.?.seed_assignments.len);
    const part = try parsePjsx(a,
        \\import { state, toggle } from "./Disclosure.ptsx";
        \\export const disclosureButtonProps = {};
        \\export function DisclosureButton() { return <button onClick={toggle} aria-expanded={state.open} />; }
    , "DisclosureButton.ptsx");
    try std.testing.expectEqualStrings("state", part.imported_family.?.state_local.?);
    try std.testing.expectEqualStrings("toggle", part.imported_family.?.action_locals.get("toggle").?);
}

test "a family carries its private helper functions, never as actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try parsePjsx(a,
        \\import { Publr } from "publr/dom";
        \\export const state = Publr.reactive({ label: "" });
        \\function describe(count: number): string { return `${count} items`; }
        \\function Helper() { return <span />; }
        \\export function relabel(count: number) { state.label = describe(count); }
        \\export function Counter() { return <div data-part="counter">{state.label}</div>; }
    , "Counter.ptsx");
    const family = root.family.?;
    var carried = util.StringSet.init(a);
    for (family.module_statements) |statement| {
        if (statement.type == .FunctionDeclaration) try carried.put(statement.id.?.name, {});
    }
    try std.testing.expect(carried.has("describe"));
    try std.testing.expect(carried.has("relabel"));
    try std.testing.expect(!carried.has("Helper"));
    try std.testing.expect(!carried.has("Counter"));
    try std.testing.expectEqual(@as(usize, 1), family.actions.len);
    try std.testing.expectEqualStrings("relabel", family.actions[0]);
}

test "finite string maps are collected from module-level literal objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try parsePjsx(a,
        \\const toneClass = { draft: "text-muted-foreground", published: "text-success" };
        \\export const dotProps = { tone: { type: "string", default: "draft" } };
        \\export function Dot({ tone }) { return <span class={toneClass[tone]} />; }
    , "dot.ptsx");
    const maps = try collectFiniteStringMaps(a, parsed.program);
    try std.testing.expectEqualStrings("text-success", maps.get("toneClass").?.get("published").?);
    const classes = try collectClassTokens(a, &parsed);
    try std.testing.expectEqual(@as(usize, 2), classes.len);
}
