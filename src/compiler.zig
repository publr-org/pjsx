//! The public, target-neutral compiler contract (the reference `compiler.ts`):
//! a versioned `ModuleIR` built from the analyzed component model, JSON
//! serialization for out-of-process targets, and the `TargetPlugin`
//! orchestration. This file knows no backend by name — targets are values
//! passed by the caller.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Node = ast.Node;
const err = @import("err.zig");
const util = @import("util.zig");
const js = @import("js.zig");
const analyze = @import("analyze.zig");
const store = @import("store.zig");
const strip_types = @import("strip_types.zig");

pub const Error = err.Error;

pub const PJSX_COMPILER_API_VERSION: u32 = 1;

pub const Capability = enum {
    actions,
    components,
    conditionals,
    dynamic_elements,
    fragments,
    loops,
    portal,
    position,
    raw_html,
    reactivity,
    slot,
    styles,

    pub fn name(self: Capability) []const u8 {
        return switch (self) {
            .dynamic_elements => "dynamic-elements",
            .raw_html => "raw-html",
            else => @tagName(self),
        };
    }
};

pub const ReferenceSource = enum { prop, state, local, global };

pub const LiteralIR = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
    null,
};

pub const ReferenceIR = struct { name: []const u8, source: ReferenceSource };

pub const MemberProperty = union(enum) {
    string: []const u8,
    number: f64,
    expression: *const ExpressionIR,
};

pub const TemplatePart = union(enum) {
    string: []const u8,
    expression: *const ExpressionIR,
};

pub const ObjectFieldIR = struct { name: []const u8, value: *const ExpressionIR };

pub const ExpressionIR = union(enum) {
    literal: LiteralIR,
    reference: ReferenceIR,
    member: struct { object: *const ExpressionIR, property: MemberProperty },
    unary: struct { operator: []const u8, argument: *const ExpressionIR },
    operation: struct { operator: []const u8, left: *const ExpressionIR, right: *const ExpressionIR },
    conditional: struct { @"test": *const ExpressionIR, consequent: *const ExpressionIR, alternate: *const ExpressionIR },
    template: struct { parts: []const TemplatePart },
    /// `asserted` is the array's TypeScript assertion (`[] as Row[]`) as an
    /// array prop schema, so an empty literal keeps its item type.
    array: struct { items: []const *const ExpressionIR, asserted: ?*const analyze.PropSchema = null },
    object: struct { fields: []const ObjectFieldIR },
    call: struct { callee: *const ExpressionIR, arguments: []const *const ExpressionIR },
    function: struct { parameters: []const []const u8, body: *const ExpressionIR, locals: []const LocalIR = &.{} },
    node: struct { node: *const NodeIR },
    absent,
    unsupported: struct { feature: []const u8 },
};

/// How the attribute value was authored: `name`, `name="str"`, `name={…}`.
pub const AttributeForm = enum { bare, literal, expression };

pub const AttributeIR = union(enum) {
    attribute: struct { name: []const u8, form: AttributeForm, value: *const ExpressionIR, action_name: ?[]const u8 = null, source_index: usize = 0 },
    behavior: struct { name: []const u8, form: AttributeForm, value: *const ExpressionIR, source_index: usize = 0 },
    event: struct { event: []const u8, modifiers: []const []const u8, form: AttributeForm, value: *const ExpressionIR, action_name: ?[]const u8 = null, source_index: usize = 0 },
    binding: struct { name: []const u8, form: AttributeForm, value: *const ExpressionIR, source_index: usize = 0 },

    pub fn value(self: AttributeIR) *const ExpressionIR {
        return switch (self) {
            inline else => |v| v.value,
        };
    }
};

pub const ElementNameIR = union(enum) {
    intrinsic: struct { name: []const u8 },
    component: struct { name: []const u8 },
    member: struct { path: []const []const u8 },
};

pub const NodeIR = union(enum) {
    element: struct { site: usize = 0, name: ElementNameIR, attributes: []const AttributeIR, self_closing: bool, children: []const *const NodeIR },
    fragment: struct { children: []const *const NodeIR },
    text: struct { value: []const u8 },
    expression: struct { site: usize = 0, value: *const ExpressionIR },
};

pub const ImportNameIR = struct { imported: []const u8, local: []const u8, type_only: bool };
pub const ImportIR = struct { source: []const u8, names: []const ImportNameIR };

/// A family seed assignment (`state.x = expr`), carried as an IR expression
/// for SSR targets — the wire format serializes these under `extensions`.
pub const SeedIR = struct { field: []const u8, value: *const ExpressionIR };
/// One initial-state field; a null value is unservable (a getter, or an
/// expression the IR cannot carry) — an SSR target renders wire-only there.
pub const InitialIR = struct { field: []const u8, value: ?*const ExpressionIR };
/// The client half of a reactive module: its `Publr.createLocalStore(...)`
/// registration, type-stripped, ready to serve.
pub const StoreRegistrationIR = struct { name: []const u8, code: []const u8 };

/// Ordered component bindings. Initializers execute once before rendering.
/// The source offset is in the canonical TSX source retained by analysis.
pub const LocalIR = struct { name: []const u8, value: *const ExpressionIR, start: usize };

pub const ReactiveIR = struct {
    store: []const u8,
    actions: []const []const u8,
    refs: []const []const u8,
    initial: []const InitialIR = &.{},
};
pub const FamilyIR = struct {
    store: []const u8,
    state: []const u8,
    actions: []const []const u8,
    refs: []const []const u8,
    seeds: usize,
    seed_exprs: []const SeedIR = &.{},
    initial: []const InitialIR = &.{},
};

pub const ComponentIR = struct {
    name: []const u8,
    props: *const analyze.Schema,
    /// The complete TS contract, including correlations across object-union branches.
    props_type: ?*const @import("types.zig").Type = null,
    root: *const NodeIR,
    imports: []const ImportIR,
    /// Module specifiers of side-effect imports — the component's declared client behaviors.
    behaviors: []const []const u8,
    reactive: ?ReactiveIR,
    family: ?FamilyIR,
    store_registration: ?StoreRegistrationIR = null,
    locals: []const LocalIR = &.{},
    /// Props captured by parameter destructuring, as distinct from live props.x.
    snapshots: []const []const u8 = &.{},
};

pub const ModuleIR = struct {
    api_version: u32 = PJSX_COMPILER_API_VERSION,
    filename: []const u8,
    /// Retained for source maps and source-preserving targets; semantic targets use `component.root`.
    source: []const u8,
    component: ComponentIR,
    classes: []const []const u8,
    /// Module-level `const X = { key: "literal" }` lookup tables.
    finite_maps: analyze.FiniteStringMaps,
    /// Module-level `const X = "literal"` values. In-process targets only; the JSON IR
    /// does not carry them.
    string_constants: []const StringConstant = &.{},
    /// Sorted for determinism.
    capabilities: []const Capability,
    /// Legacy authoring preserves historical presence guards. The portable
    /// contract uses ordinary JavaScript && and carries its semantics version.
    semantics_version: u32 = 0,
};

// ── IR construction ────────────────────────────────────────────────────────

fn jsxText(allocator: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    return util.jsxText(allocator, raw);
}

fn staticName(allocator: Allocator, node: ?*const Node) Allocator.Error!?[]const u8 {
    const n = node orelse return null;
    if (n.type == .Identifier or n.type == .JSXIdentifier) return n.name;
    if (n.type == .Literal) return try js.Value.fromLiteral(n.value).toString(allocator);
    return null;
}

fn memberPath(allocator: Allocator, node: *Node) Allocator.Error!?[]const []const u8 {
    const value = analyze.unwrap(node);
    if (value.type == .Identifier or value.type == .JSXIdentifier) {
        const path = try allocator.alloc([]const u8, 1);
        path[0] = value.name;
        return path;
    }
    if (value.type != .MemberExpression and value.type != .JSXMemberExpression) return null;
    const parent = try memberPath(allocator, value.object.?) orelse return null;
    const property = try staticName(allocator, value.property) orelse return null;
    const path = try allocator.alloc([]const u8, parent.len + 1);
    @memcpy(path[0..parent.len], parent);
    path[parent.len] = property;
    return path;
}

fn box(allocator: Allocator, expression: ExpressionIR) Allocator.Error!*const ExpressionIR {
    const ptr = try allocator.create(ExpressionIR);
    ptr.* = expression;
    return ptr;
}

fn boxNode(allocator: Allocator, node: NodeIR) Allocator.Error!*const NodeIR {
    const ptr = try allocator.create(NodeIR);
    ptr.* = node;
    return ptr;
}

fn expressionIR(allocator: Allocator, node: *Node, parsed: *const analyze.ParsedModule) Error!*const ExpressionIR {
    const value = analyze.unwrap(node);
    const bindings = &parsed.component.prop_bindings;
    switch (value.type) {
        .Literal => {
            const literal: ?LiteralIR = switch (value.value) {
                .string => |s| .{ .string = s },
                .number => |n| .{ .number = n },
                .boolean => |b| .{ .boolean = b },
                .null => .null,
                else => null,
            };
            if (literal) |l| return box(allocator, .{ .literal = l });
            return box(allocator, .{ .unsupported = .{ .feature = "literal" } });
        },
        .Identifier => {
            if (util.eql(value.name, "undefined")) return box(allocator, .absent);
            if (bindings.get(value.name)) |prop| {
                if (!util.eql(prop, "$props")) return box(allocator, .{ .reference = .{ .name = prop, .source = .prop } });
            }
            if (parsed.component.reactive) |reactive| {
                if (util.eql(value.name, reactive.state_name)) {
                    return box(allocator, .{ .reference = .{ .name = value.name, .source = .state } });
                }
            }
            return box(allocator, .{ .reference = .{ .name = value.name, .source = .local } });
        },
        .JSXElement, .JSXFragment => return box(allocator, .{ .node = .{ .node = try nodeIR(allocator, value, parsed) } }),
        .MemberExpression => {
            const object = value.object.?;
            const prop: ?[]const u8 = if (object.type == .Identifier) bindings.get(object.name) else null;
            if (prop != null and util.eql(prop.?, "$props") and !value.computed and value.property.?.type == .Identifier) {
                return box(allocator, .{ .reference = .{ .name = value.property.?.name, .source = .prop } });
            }
            const property: MemberProperty = if (value.computed)
                .{ .expression = try expressionIR(allocator, value.property.?, parsed) }
            else
                .{ .string = try staticName(allocator, value.property) orelse "unknown" };
            return box(allocator, .{ .member = .{ .object = try expressionIR(allocator, object, parsed), .property = property } });
        },
        .UnaryExpression => return box(allocator, .{ .unary = .{
            .operator = value.operator,
            .argument = try expressionIR(allocator, value.argument.?, parsed),
        } }),
        .BinaryExpression, .LogicalExpression => return box(allocator, .{ .operation = .{
            .operator = value.operator,
            .left = try expressionIR(allocator, value.left.?, parsed),
            .right = try expressionIR(allocator, value.right.?, parsed),
        } }),
        .ConditionalExpression => return box(allocator, .{ .conditional = .{
            .@"test" = try expressionIR(allocator, value.test_.?, parsed),
            .consequent = try expressionIR(allocator, value.consequent.?, parsed),
            .alternate = try expressionIR(allocator, value.alternate.?, parsed),
        } }),
        .TemplateLiteral => {
            var parts: std.ArrayList(TemplatePart) = .empty;
            for (value.quasis, 0..) |quasi, index| {
                try parts.append(allocator, .{ .string = quasi.cooked orelse "" });
                if (index < value.expressions.len) {
                    try parts.append(allocator, .{ .expression = try expressionIR(allocator, value.expressions[index], parsed) });
                }
            }
            return box(allocator, .{ .template = .{ .parts = try parts.toOwnedSlice(allocator) } });
        },
        .ArrayExpression => {
            var items: std.ArrayList(*const ExpressionIR) = .empty;
            for (value.elements) |element| {
                if (element) |item| try items.append(allocator, try expressionIR(allocator, item, parsed));
            }
            return box(allocator, .{ .array = .{ .items = try items.toOwnedSlice(allocator), .asserted = try assertedArray(allocator, node, parsed) } });
        },
        .ObjectExpression => {
            var fields: std.ArrayList(ObjectFieldIR) = .empty;
            for (value.properties) |field| {
                if (field.type != .Property or field.computed) continue;
                const name = try staticName(allocator, field.key) orelse continue;
                try fields.append(allocator, .{ .name = name, .value = try expressionIR(allocator, field.value_node.?, parsed) });
            }
            return box(allocator, .{ .object = .{ .fields = try fields.toOwnedSlice(allocator) } });
        },
        .CallExpression => {
            var arguments: std.ArrayList(*const ExpressionIR) = .empty;
            for (value.arguments) |argument| try arguments.append(allocator, try expressionIR(allocator, argument, parsed));
            return box(allocator, .{ .call = .{
                .callee = try expressionIR(allocator, value.callee.?, parsed),
                .arguments = try arguments.toOwnedSlice(allocator),
            } });
        },
        .ArrowFunctionExpression, .FunctionExpression, .FunctionDeclaration => {
            var scoped = parsed.*;
            scoped.component.prop_bindings = try parsed.component.prop_bindings.clone();
            for (value.params) |parameter| {
                if (parameter.type == .Identifier) scoped.component.prop_bindings.remove(parameter.name);
            }
            var body_node = value.body;
            var locals: std.ArrayList(LocalIR) = .empty;
            if (body_node != null and body_node.?.type == .BlockStatement) {
                const statements = body_node.?.statements;
                for (statements) |statement| {
                    if (statement.type == .ReturnStatement) {
                        body_node = statement.argument;
                        break;
                    }
                    if (statement.type == .FunctionDeclaration and statement.id != null) {
                        try locals.append(allocator, .{ .name = statement.id.?.name, .value = try expressionIR(allocator, statement, &scoped), .start = statement.start });
                    } else if (statement.type == .VariableDeclaration) {
                        for (statement.declarations) |declaration| {
                            if (declaration.id == null or declaration.id.?.type != .Identifier or declaration.init == null) break;
                            const name = declaration.id.?.name;
                            scoped.component.prop_bindings.remove(name);
                            try locals.append(allocator, .{ .name = name, .value = try expressionIR(allocator, declaration.init.?, &scoped), .start = declaration.start });
                        }
                    } else if (statement.type != .EmptyStatement) break;
                }
            }
            const body: *const ExpressionIR = if (body_node != null and body_node.?.type == .BlockStatement)
                try box(allocator, .{ .unsupported = .{ .feature = "statement-function" } })
            else
                try expressionIR(allocator, body_node.?, &scoped);
            var parameters: util.StringList = .empty;
            for (value.params) |parameter| try parameters.append(allocator, try staticName(allocator, parameter) orelse "_");
            return box(allocator, .{ .function = .{ .parameters = try parameters.toOwnedSlice(allocator), .body = body, .locals = try locals.toOwnedSlice(allocator) } });
        },
        else => return box(allocator, .{ .unsupported = .{ .feature = value.type.name() } }),
    }
}

fn elementNameIR(allocator: Allocator, node: *Node) Allocator.Error!ElementNameIR {
    if (node.type == .JSXIdentifier) {
        return if (util.startsWithUpper(node.name)) .{ .component = .{ .name = node.name } } else .{ .intrinsic = .{ .name = node.name } };
    }
    const path = try memberPath(allocator, node) orelse blk: {
        const unknown = try allocator.alloc([]const u8, 1);
        unknown[0] = "unknown";
        break :blk unknown;
    };
    return .{ .member = .{ .path = path } };
}

fn attributeIR(allocator: Allocator, attribute: *Node, parsed: *const analyze.ParsedModule) Error!AttributeIR {
    if (attribute.type == .JSXSpreadAttribute) {
        return .{ .attribute = .{ .name = "...", .form = .expression, .value = try expressionIR(allocator, attribute.argument.?, parsed) } };
    }
    const name = try staticName(allocator, attribute.name_node) orelse "unknown";
    const value_node = attribute.value_node;
    const form: AttributeForm = if (value_node == null) .bare else if (value_node.?.type == .Literal) .literal else .expression;
    const value: *const ExpressionIR = if (value_node == null)
        try box(allocator, .{ .literal = .{ .boolean = true } })
    else if (value_node.?.type == .Literal)
        try expressionIR(allocator, value_node.?, parsed)
    else
        try expressionIR(allocator, value_node.?.expression.?, parsed);

    const raw_value = if (value_node) |v| (if (v.type == .JSXExpressionContainer) v.expression else v) else null;
    const action_name = if (raw_value != null and raw_value.?.type == .Identifier) raw_value.?.name else null;
    if (std.mem.startsWith(u8, name, "$$on$")) {
        var parts = std.mem.splitScalar(u8, name[5..], '$');
        const event = parts.first();
        var modifiers: util.StringList = .empty;
        while (parts.next()) |modifier| try modifiers.append(allocator, modifier);
        return .{ .event = .{
            .action_name = action_name,
            .event = if (event.len == 0) "unknown" else event,
            .modifiers = try modifiers.toOwnedSlice(allocator),
            .form = form,
            .value = value,
        } };
    }
    if (std.mem.startsWith(u8, name, "$$b$")) return .{ .binding = .{ .name = name[4..], .form = form, .value = value } };
    if (std.mem.startsWith(u8, name, "$$")) return .{ .behavior = .{ .name = name[2..], .form = form, .value = value } };
    return .{ .attribute = .{ .name = name, .form = form, .value = value, .action_name = action_name } };
}

fn childrenIR(allocator: Allocator, children: []*Node, parsed: *const analyze.ParsedModule) Error![]const *const NodeIR {
    var out: std.ArrayList(*const NodeIR) = .empty;
    for (children) |child| {
        if (child.type == .JSXText) {
            const raw = child.value.asString() orelse child.raw;
            const text = try jsxText(allocator, raw);
            if (text.len > 0) try out.append(allocator, try boxNode(allocator, .{ .text = .{ .value = text } }));
            continue;
        }
        if (child.type == .JSXExpressionContainer) {
            const expression = child.expression orelse continue;
            if (expression.type == .JSXEmptyExpression) continue;
            try out.append(allocator, try boxNode(allocator, .{ .expression = .{ .site = child.start, .value = try expressionIR(allocator, expression, parsed) } }));
            continue;
        }
        try out.append(allocator, try nodeIR(allocator, child, parsed));
    }
    return out.toOwnedSlice(allocator);
}

fn nodeIR(allocator: Allocator, node: *Node, parsed: *const analyze.ParsedModule) Error!*const NodeIR {
    const value = analyze.unwrap(node);
    if (value.type == .JSXElement) {
        const opening = value.opening_element.?;
        var attributes: std.ArrayList(AttributeIR) = .empty;
        for (opening.attributes, 0..) |attribute, index| {
            var attr = try attributeIR(allocator, attribute, parsed);
            switch (attr) {
                inline else => |*entry| entry.source_index = index,
            }
            if (attr == .attribute and util.eql(attr.attribute.name, "class") and attr.attribute.value.* == .array) {
                for (attr.attribute.value.array.items) |part| try attributes.append(allocator, .{ .attribute = .{ .name = "class", .form = .expression, .value = part, .source_index = index } });
            } else try attributes.append(allocator, attr);
        }
        return boxNode(allocator, .{ .element = .{
            .site = value.start,
            .name = try elementNameIR(allocator, opening.name_node.?),
            .attributes = try attributes.toOwnedSlice(allocator),
            .self_closing = opening.self_closing,
            .children = try childrenIR(allocator, value.children, parsed),
        } });
    }
    if (value.type == .JSXFragment) {
        return boxNode(allocator, .{ .fragment = .{ .children = try childrenIR(allocator, value.children, parsed) } });
    }
    return boxNode(allocator, .{ .expression = .{ .site = value.start, .value = try expressionIR(allocator, value, parsed) } });
}

fn behaviorsIR(allocator: Allocator, program: *Node) Allocator.Error![]const []const u8 {
    var out: util.StringList = .empty;
    for (program.statements) |statement| {
        if (statement.type != .ImportDeclaration) continue;
        const source = statement.source.?.stringValue() orelse continue;
        if (statement.specifiers.len == 0) try out.append(allocator, source);
    }
    return out.toOwnedSlice(allocator);
}

fn importsIR(allocator: Allocator, program: *Node) Allocator.Error![]const ImportIR {
    var out: std.ArrayList(ImportIR) = .empty;
    for (program.statements) |statement| {
        if (statement.type != .ImportDeclaration) continue;
        const source = statement.source.?.stringValue() orelse continue;
        var names: std.ArrayList(ImportNameIR) = .empty;
        for (statement.specifiers) |specifier| {
            if (specifier.type != .ImportSpecifier) continue;
            try names.append(allocator, .{
                .imported = try analyze.importedName(allocator, specifier),
                .local = specifier.local.?.name,
                .type_only = statement.import_kind == .type or specifier.import_kind == .type,
            });
        }
        try out.append(allocator, .{ .source = source, .names = try names.toOwnedSlice(allocator) });
    }
    return out.toOwnedSlice(allocator);
}

const CapabilitySet = std.EnumSet(Capability);

fn visitExpression(set: *CapabilitySet, expression: *const ExpressionIR) void {
    switch (expression.*) {
        .conditional => |c| {
            set.insert(.conditionals);
            visitExpression(set, c.@"test");
            visitExpression(set, c.consequent);
            visitExpression(set, c.alternate);
        },
        .call => |c| {
            if (c.callee.* == .member and c.callee.member.property == .string and util.eql(c.callee.member.property.string, "map")) {
                set.insert(.loops);
            }
            visitExpression(set, c.callee);
            for (c.arguments) |argument| visitExpression(set, argument);
        },
        .member => |m| {
            visitExpression(set, m.object);
            if (m.property == .expression) visitExpression(set, m.property.expression);
        },
        .unary => |u| visitExpression(set, u.argument),
        .operation => |o| {
            visitExpression(set, o.left);
            visitExpression(set, o.right);
        },
        .template => |t| for (t.parts) |part| {
            if (part == .expression) visitExpression(set, part.expression);
        },
        .array => |a| for (a.items) |item| visitExpression(set, item),
        .object => |o| for (o.fields) |field| visitExpression(set, field.value),
        .function => |f| visitExpression(set, f.body),
        .node => |n| visitNode(set, n.node),
        .literal, .reference, .absent, .unsupported => {},
    }
}

fn visitNode(set: *CapabilitySet, node: *const NodeIR) void {
    switch (node.*) {
        .fragment => |f| {
            set.insert(.fragments);
            for (f.children) |child| visitNode(set, child);
        },
        .element => |e| {
            if (e.name == .component) {
                set.insert(.components);
                if (util.eql(e.name.component.name, "Dynamic")) set.insert(.dynamic_elements);
                if (util.eql(e.name.component.name, "Slot")) set.insert(.slot);
            }
            for (e.attributes) |attribute| {
                switch (attribute) {
                    .event => set.insert(.actions),
                    .attribute => |a| if (util.eql(a.name, "style")) set.insert(.styles),
                    .behavior => |b| {
                        if (util.eql(b.name, "portal")) set.insert(.portal);
                        if (util.eql(b.name, "position")) set.insert(.position);
                        if (util.eql(b.name, "html")) set.insert(.raw_html);
                        if (util.eql(b.name, "for")) set.insert(.loops);
                        if (util.eql(b.name, "if")) set.insert(.conditionals);
                    },
                    .binding => {},
                }
                visitExpression(set, attribute.value());
            }
            for (e.children) |child| visitNode(set, child);
        },
        .expression => |x| visitExpression(set, x.value),
        .text => {},
    }
}

fn capabilitiesOf(allocator: Allocator, root: *const NodeIR, parsed: *const analyze.ParsedModule) Allocator.Error![]const Capability {
    var set = CapabilitySet.initEmpty();
    if (parsed.component.reactive != null) set.insert(.reactivity);
    for (parsed.schema.values()) |field| if (field.type == .action) set.insert(.actions);
    visitNode(&set, root);
    var list: std.ArrayList(Capability) = .empty;
    inline for (std.meta.fields(Capability)) |field| {
        const capability: Capability = @enumFromInt(field.value);
        if (set.contains(capability)) try list.append(allocator, capability);
    }
    // Sorted by kebab-case name (JS default string sort).
    const slice = try list.toOwnedSlice(allocator);
    std.mem.sort(Capability, slice, {}, struct {
        fn less(_: void, a: Capability, b: Capability) bool {
            return std.mem.order(u8, a.name(), b.name()) == .lt;
        }
    }.less);
    return slice;
}

pub fn createPjsxModule(allocator: Allocator, source: []const u8, filename: []const u8) Error!*ModuleIR {
    return createPjsxModuleWithResolver(allocator, source, filename, null);
}

pub fn createPjsxModuleWithResolver(allocator: Allocator, original_source: []const u8, filename: []const u8, resolver: ?@import("types.zig").Resolver) Error!*ModuleIR {
    const source = if (resolver) |r| try @import("inline_html.zig").expand(allocator, original_source, filename, r) else original_source;
    const parsed_value = try analyze.parsePjsxWithResolver(allocator, source, filename, resolver);
    const parsed = try allocator.create(analyze.ParsedModule);
    parsed.* = parsed_value;
    const root = try nodeIR(allocator, parsed.component.root, parsed);
    var reactive: ?ReactiveIR = null;
    if (parsed.component.reactive) |r| {
        reactive = .{
            .store = r.wire_name,
            .actions = r.actions,
            .refs = try refNames(allocator, r.refs),
            .initial = if (r.foreign) &.{} else try initialIR(allocator, r.initial_state, parsed),
        };
    }
    var family: ?FamilyIR = null;
    if (parsed.family) |f| {
        var seed_exprs = try allocator.alloc(SeedIR, f.seed_assignments.len);
        for (f.seed_assignments, 0..) |seed, i| {
            seed_exprs[i] = .{ .field = seed.field, .value = try expressionIR(allocator, seed.value, parsed) };
        }
        family = .{
            .store = f.wire_name,
            .state = f.state_name,
            .actions = f.actions,
            .refs = try refNames(allocator, f.refs),
            .seeds = f.seed_assignments.len,
            .seed_exprs = seed_exprs,
            .initial = try initialIR(allocator, f.initial_state, parsed),
        };
    }
    // The client half of a stateful module (a reactive binding or a family
    // root — a mere family part only imports its family and registers
    // nothing): the `Publr.createLocalStore(...)` registration, type-stripped
    // so the emitted JS carries no TypeScript annotations. Mirrors the
    // full-cms-ui `pjsx_ir` extension splice, failures included (fatal).
    var store_registration: ?StoreRegistrationIR = null;
    if (parsed.component.reactive != null or parsed.family != null) {
        if (try store.lowerParsedStoreRegistration(allocator, parsed)) |registration| {
            const stripped = try strip_types.stripTypes(allocator, registration.code, filename);
            store_registration = .{
                .name = registration.name,
                .code = std.mem.trimEnd(u8, stripped, "\n "),
            };
        }
    }
    const module = try allocator.create(ModuleIR);
    module.* = .{
        .filename = filename,
        .source = source,
        .component = .{
            .name = parsed.component.name,
            .locals = try localBindingsIR(allocator, parsed),
            .snapshots = try snapshotProps(allocator, parsed),
            .props = parsed.schema,
            .props_type = parsed.props_type,
            .root = root,
            .imports = try importsIR(allocator, parsed.program),
            .behaviors = try behaviorsIR(allocator, parsed.program),
            .reactive = reactive,
            .family = family,
            .store_registration = store_registration,
        },
        .classes = try analyze.collectClassTokens(allocator, parsed),
        .finite_maps = try analyze.collectFiniteStringMaps(allocator, parsed.program),
        .string_constants = try stringConstantsIR(allocator, parsed.program),
        .capabilities = try capabilitiesOf(allocator, root, parsed),
    };
    return module;
}

pub const StringConstant = struct { name: []const u8, value: []const u8 };

fn stringConstantsIR(allocator: Allocator, program: *Node) Error![]const StringConstant {
    const constants = try analyze.collectStringConstants(allocator, program);
    const list = try allocator.alloc(StringConstant, constants.count());
    for (constants.keys(), constants.values(), 0..) |name, value, index| {
        list[index] = .{ .name = name, .value = value };
    }
    return list;
}

fn localBindingsIR(allocator: Allocator, parsed: *const analyze.ParsedModule) Error![]const LocalIR {
    var locals: std.ArrayList(LocalIR) = .empty;
    const body = parsed.component.fn_node.body orelse return locals.items;
    for (body.statements) |statement| {
        if (statement.type == .ReturnStatement) break;
        if (statement.type == .FunctionDeclaration and statement.id != null) {
            try locals.append(allocator, .{ .name = statement.id.?.name, .value = try expressionIR(allocator, statement, parsed), .start = statement.start });
            continue;
        }
        if (statement.type != .VariableDeclaration) continue;
        if (parsed.component.reactive) |reactive| {
            if (statement == reactive.state_statement) continue;
        }
        for (statement.declarations) |declaration| {
            const id = declaration.id orelse continue;
            const init = declaration.init orelse continue;
            if (id.type != .Identifier or parsed.component.prop_bindings.has(id.name)) continue;
            try locals.append(allocator, .{ .name = id.name, .value = try expressionIR(allocator, init, parsed), .start = declaration.start });
        }
    }
    return locals.items;
}

fn snapshotProps(allocator: Allocator, parsed: *const analyze.ParsedModule) Error![]const []const u8 {
    var result: util.StringList = .empty;
    const parameters = parsed.component.fn_node.params;
    if (parameters.len == 0 or parameters[0].type != .ObjectPattern) return result.items;
    for (parameters[0].properties) |property| {
        if (try staticName(allocator, property.key)) |name| try result.append(allocator, name);
    }
    return result.items;
}

/// The initial-state object's fields as IR expressions; getters, setters and
/// anything the IR cannot carry become unservable (null) — an SSR target
/// renders those wire-only.
fn initialIR(allocator: Allocator, initial_state: *Node, parsed: *const analyze.ParsedModule) Error![]const InitialIR {
    var fields: std.ArrayList(InitialIR) = .empty;
    for (initial_state.properties) |property| {
        const key = property.key orelse continue;
        if (key.type != .Identifier) continue;
        const value: ?*const ExpressionIR = blk: {
            if (property.kind == .get or property.kind == .set) break :blk null;
            const value_node = property.value_node orelse break :blk null;
            break :blk expressionIR(allocator, value_node, parsed) catch null;
        };
        try fields.append(allocator, .{ .field = key.name, .value = value });
    }
    return fields.items;
}

/// The outermost `as`/`satisfies` type over an array literal, as an array
/// prop schema (see `ExpressionIR.array`).
fn assertedArray(allocator: Allocator, node: *Node, parsed: *const analyze.ParsedModule) Error!?*const analyze.PropSchema {
    var current = node;
    while (current.type == .TSAsExpression or current.type == .TSNonNullExpression or current.type == .TSSatisfiesExpression or current.type == .ParenthesizedExpression) {
        if (current.type != .TSNonNullExpression and current.type != .ParenthesizedExpression) {
            const annotation = current.type_annotation orelse break;
            const spec = @import("types.zig").assertedArray(allocator, parsed.program, parsed.canonical, "", annotation.slice(parsed.canonical)) orelse return null;
            const boxed = try allocator.create(analyze.PropSchema);
            boxed.* = spec;
            return boxed;
        }
        current = current.expression.?;
    }
    return null;
}

fn refNames(allocator: Allocator, refs: []const analyze.RefBinding) Allocator.Error![]const []const u8 {
    const out = try allocator.alloc([]const u8, refs.len);
    for (refs, 0..) |ref, i| out[i] = ref.name;
    return out;
}

pub fn collectPjsxClasses(allocator: Allocator, source: []const u8, filename: []const u8) Error![]const []const u8 {
    const module = try createPjsxModule(allocator, source, filename);
    return allocator.dupe([]const u8, module.classes);
}

// ── Target plugins ─────────────────────────────────────────────────────────

pub const CompileContext = struct {
    filename: []const u8,
    target_name: []const u8,

    /// `context.error(message)` — always fails with `pjsx: <file>: <target>: <message>`.
    pub fn @"error"(self: CompileContext, message: []const u8) Error {
        return err.fail("pjsx: {s}: {s}: {s}", .{ self.filename, self.target_name, message });
    }
};

pub fn TargetPlugin(comptime Options: type, comptime Output: type) type {
    return struct {
        name: []const u8,
        api_version: u32,
        capabilities: ?[]const Capability = null,
        compile: *const fn (Allocator, *const ModuleIR, CompileContext, Options) Error!Output,
    };
}

pub const SourceOrModule = union(enum) {
    source: []const u8,
    module: *const ModuleIR,
};

pub fn CompileOptions(comptime Options: type, comptime Output: type) type {
    return struct {
        filename: []const u8,
        target: TargetPlugin(Options, Output),
        target_options: Options,
    };
}

pub fn compilePjsx(comptime Options: type, comptime Output: type, allocator: Allocator, input: SourceOrModule, options: CompileOptions(Options, Output)) Error!Output {
    const target = options.target;
    if (target.api_version != PJSX_COMPILER_API_VERSION) {
        return err.fail("pjsx: target {s} uses compiler API {d}; expected {d}", .{ try util.jsonString(allocator, target.name), target.api_version, PJSX_COMPILER_API_VERSION });
    }
    const module: *const ModuleIR = switch (input) {
        .source => |source| try createPjsxModule(allocator, source, options.filename),
        .module => |module| module,
    };
    if (target.capabilities) |supported| {
        var missing: util.StringList = .empty;
        for (module.capabilities) |capability| {
            var found = false;
            for (supported) |s| if (s == capability) {
                found = true;
            };
            if (!found) try missing.append(allocator, capability.name());
        }
        if (missing.items.len > 0) {
            return err.fail("pjsx: target {s} does not support: {s}", .{ try util.jsonString(allocator, target.name), try util.join(allocator, missing.items, ", ") });
        }
    }
    const context = CompileContext{ .filename = module.filename, .target_name = target.name };
    return target.compile(allocator, module, context, options.target_options);
}

// ── JSON serialization (`JSON.stringify(module)`) ──────────────────────────

/// Streams the IR as JSON into any `std.Io.Writer` (a file, a socket, or an
/// `Allocating` writer for the string form).
const Json = struct {
    allocator: Allocator,
    out: *std.Io.Writer,
    lossless_numbers: bool = false,

    const WriteError = std.Io.Writer.Error || Allocator.Error;

    fn raw(self: *Json, text: []const u8) WriteError!void {
        try self.out.writeAll(text);
    }
    fn str(self: *Json, text: []const u8) WriteError!void {
        try util.writeJsonString(self.out, text);
    }
    fn num(self: *Json, value: f64) WriteError!void {
        if (self.lossless_numbers) {
            try self.out.print("{{\"binary64\":\"{x:0>16}\"}}", .{@as(u64, @bitCast(value))});
            return;
        }
        if (std.math.isNan(value) or std.math.isInf(value)) return self.raw("null");
        try self.raw(try util.numberToString(self.allocator, value));
    }
    fn key(self: *Json, name: []const u8, first: bool) WriteError!void {
        if (!first) try self.raw(",");
        try self.str(name);
        try self.raw(":");
    }
    fn strings(self: *Json, list: []const []const u8) WriteError!void {
        try self.raw("[");
        for (list, 0..) |item, i| {
            if (i > 0) try self.raw(",");
            try self.str(item);
        }
        try self.raw("]");
    }

    fn primitive(self: *Json, value: analyze.Primitive) WriteError!void {
        switch (value) {
            .string => |s| try self.str(s),
            .number => |n| try self.num(n),
            .boolean => |b| try self.raw(if (b) "true" else "false"),
        }
    }

    fn schema(self: *Json, s: *const analyze.Schema) WriteError!void {
        try self.raw("{");
        for (s.keys(), s.values(), 0..) |name, field, i| {
            try self.key(name, i == 0);
            try self.propSchema(field);
        }
        try self.raw("}");
    }

    fn propSchema(self: *Json, field: analyze.PropSchema) WriteError!void {
        try self.raw("{");
        try self.key("type", true);
        try self.str(field.type.name());
        try self.key("optional", false);
        try self.raw(if (field.optional) "true" else "false");
        if (field.default) |d| {
            try self.key("default", false);
            try self.primitive(d);
        }
        if (field.values) |values| {
            try self.key("values", false);
            try self.raw("[");
            for (values, 0..) |v, i| {
                if (i > 0) try self.raw(",");
                try self.primitive(v);
            }
            try self.raw("]");
        }
        if (field.tag_from) |tag_from| {
            try self.key("tagFrom", false);
            try self.str(tag_from);
        }
        if (field.internal) {
            try self.key("internal", false);
            try self.raw("true");
        }
        if (field.fields) |fields| {
            try self.key("fields", false);
            try self.schema(fields);
        }
        if (field.items) |items| {
            try self.key("items", false);
            try self.str(items.name());
        }
        if (field.variants) |variants| {
            try self.key("variants", false);
            try self.strings(variants);
        }
        try self.raw("}");
    }

    fn expression(self: *Json, e: *const ExpressionIR) WriteError!void {
        try self.raw("{");
        try self.key("kind", true);
        switch (e.*) {
            .literal => |l| {
                try self.str("literal");
                try self.key("value", false);
                switch (l) {
                    .string => |s| try self.str(s),
                    .number => |n| try self.num(n),
                    .boolean => |b| try self.raw(if (b) "true" else "false"),
                    .null => try self.raw("null"),
                }
            },
            .reference => |r| {
                try self.str("reference");
                try self.key("name", false);
                try self.str(r.name);
                try self.key("source", false);
                try self.str(@tagName(r.source));
            },
            .member => |m| {
                try self.str("member");
                try self.key("object", false);
                try self.expression(m.object);
                try self.key("property", false);
                switch (m.property) {
                    .string => |s| try self.str(s),
                    .number => |n| try self.num(n),
                    .expression => |x| try self.expression(x),
                }
            },
            .unary => |u| {
                try self.str("unary");
                try self.key("operator", false);
                try self.str(u.operator);
                try self.key("argument", false);
                try self.expression(u.argument);
            },
            .operation => |o| {
                try self.str("operation");
                try self.key("operator", false);
                try self.str(o.operator);
                try self.key("left", false);
                try self.expression(o.left);
                try self.key("right", false);
                try self.expression(o.right);
            },
            .conditional => |c| {
                try self.str("conditional");
                try self.key("test", false);
                try self.expression(c.@"test");
                try self.key("consequent", false);
                try self.expression(c.consequent);
                try self.key("alternate", false);
                try self.expression(c.alternate);
            },
            .template => |t| {
                try self.str("template");
                try self.key("parts", false);
                try self.raw("[");
                for (t.parts, 0..) |part, i| {
                    if (i > 0) try self.raw(",");
                    switch (part) {
                        .string => |s| try self.str(s),
                        .expression => |x| try self.expression(x),
                    }
                }
                try self.raw("]");
            },
            .array => |a| {
                try self.str("array");
                try self.key("items", false);
                try self.expressions(a.items);
            },
            .object => |o| {
                try self.str("object");
                try self.key("fields", false);
                try self.raw("[");
                for (o.fields, 0..) |field, i| {
                    if (i > 0) try self.raw(",");
                    try self.raw("{");
                    try self.key("name", true);
                    try self.str(field.name);
                    try self.key("value", false);
                    try self.expression(field.value);
                    try self.raw("}");
                }
                try self.raw("]");
            },
            .call => |c| {
                try self.str("call");
                try self.key("callee", false);
                try self.expression(c.callee);
                try self.key("arguments", false);
                try self.expressions(c.arguments);
            },
            .function => |f| {
                try self.str("function");
                try self.key("parameters", false);
                try self.strings(f.parameters);
                try self.key("body", false);
                try self.expression(f.body);
            },
            .node => |n| {
                try self.str("node");
                try self.key("node", false);
                try self.node(n.node);
            },
            .absent => try self.str("absent"),
            .unsupported => |u| {
                try self.str("unsupported");
                try self.key("feature", false);
                try self.str(u.feature);
            },
        }
        try self.raw("}");
    }

    fn expressions(self: *Json, list: []const *const ExpressionIR) WriteError!void {
        try self.raw("[");
        for (list, 0..) |item, i| {
            if (i > 0) try self.raw(",");
            try self.expression(item);
        }
        try self.raw("]");
    }

    fn attribute(self: *Json, a: AttributeIR) WriteError!void {
        try self.raw("{");
        try self.key("kind", true);
        switch (a) {
            .attribute => |x| {
                try self.str("attribute");
                try self.key("name", false);
                try self.str(x.name);
                try self.formValue(x.form, x.value);
            },
            .behavior => |x| {
                try self.str("behavior");
                try self.key("name", false);
                try self.str(x.name);
                try self.formValue(x.form, x.value);
            },
            .event => |x| {
                try self.str("event");
                try self.key("event", false);
                try self.str(x.event);
                try self.key("modifiers", false);
                try self.strings(x.modifiers);
                try self.formValue(x.form, x.value);
            },
            .binding => |x| {
                try self.str("binding");
                try self.key("name", false);
                try self.str(x.name);
                try self.formValue(x.form, x.value);
            },
        }
        try self.raw("}");
    }

    fn formValue(self: *Json, form: AttributeForm, value: *const ExpressionIR) WriteError!void {
        try self.key("form", false);
        try self.str(@tagName(form));
        try self.key("value", false);
        try self.expression(value);
    }

    fn elementName(self: *Json, name: ElementNameIR) WriteError!void {
        try self.raw("{");
        try self.key("kind", true);
        switch (name) {
            .intrinsic => |n| {
                try self.str("intrinsic");
                try self.key("name", false);
                try self.str(n.name);
            },
            .component => |n| {
                try self.str("component");
                try self.key("name", false);
                try self.str(n.name);
            },
            .member => |n| {
                try self.str("member");
                try self.key("path", false);
                try self.strings(n.path);
            },
        }
        try self.raw("}");
    }

    fn nodes(self: *Json, list: []const *const NodeIR) WriteError!void {
        try self.raw("[");
        for (list, 0..) |item, i| {
            if (i > 0) try self.raw(",");
            try self.node(item);
        }
        try self.raw("]");
    }

    fn node(self: *Json, n: *const NodeIR) WriteError!void {
        try self.raw("{");
        try self.key("kind", true);
        switch (n.*) {
            .element => |e| {
                try self.str("element");
                try self.key("name", false);
                try self.elementName(e.name);
                try self.key("attributes", false);
                try self.raw("[");
                for (e.attributes, 0..) |a, i| {
                    if (i > 0) try self.raw(",");
                    try self.attribute(a);
                }
                try self.raw("]");
                try self.key("selfClosing", false);
                try self.raw(if (e.self_closing) "true" else "false");
                try self.key("children", false);
                try self.nodes(e.children);
            },
            .fragment => |f| {
                try self.str("fragment");
                try self.key("children", false);
                try self.nodes(f.children);
            },
            .text => |t| {
                try self.str("text");
                try self.key("value", false);
                try self.str(t.value);
            },
            .expression => |x| {
                try self.str("expression");
                try self.key("value", false);
                try self.expression(x.value);
            },
        }
        try self.raw("}");
    }

    fn typeContract(self: *Json, t: *const @import("types.zig").Type) WriteError!void {
        try self.raw("{");
        try self.key("kind", true);
        try self.str(@tagName(t.kind));
        if (t.source.len > 0) {
            try self.key("source", false);
            try self.str(t.source);
        }
        if (t.literal) |literal| {
            try self.key("literal", false);
            try self.primitive(literal);
        }
        if (t.kind == .object) {
            try self.key("fields", false);
            try self.raw("{");
            for (t.fields.keys(), t.fields.values(), 0..) |name, field, i| {
                try self.key(name, i == 0);
                try self.raw("{");
                try self.key("optional", true);
                try self.raw(if (field.optional) "true" else "false");
                try self.key("type", false);
                try self.typeContract(field.type);
                try self.raw("}");
            }
            try self.raw("}");
        }
        if (t.item) |item| {
            try self.key("item", false);
            try self.typeContract(item);
        }
        if (t.members.len > 0) {
            try self.key("members", false);
            try self.raw("[");
            for (t.members, 0..) |member, i| {
                if (i > 0) try self.raw(",");
                try self.typeContract(member);
            }
            try self.raw("]");
        }
        if (t.rest) {
            try self.key("rest", false);
            try self.raw("true");
        }
        try self.raw("}");
    }

    fn module(self: *Json, m: *const ModuleIR) WriteError!void {
        try self.raw("{");
        try self.key("apiVersion", true);
        try self.raw(try util.fmt(self.allocator, "{d}", .{m.api_version}));
        try self.key("semanticsVersion", false);
        try self.raw(try util.fmt(self.allocator, "{d}", .{m.semantics_version}));
        try self.key("filename", false);
        try self.str(m.filename);
        try self.key("source", false);
        try self.str(m.source);
        try self.key("component", false);
        try self.raw("{");
        try self.key("name", true);
        try self.str(m.component.name);
        try self.key("props", false);
        try self.schema(m.component.props);
        if (m.component.props_type) |contract| {
            try self.key("propsType", false);
            try self.typeContract(contract);
        }
        try self.key("root", false);
        try self.node(m.component.root);
        try self.key("locals", false);
        try self.raw("[");
        for (m.component.locals, 0..) |local, i| {
            if (i != 0) try self.raw(",");
            try self.raw("{");
            try self.key("name", true);
            try self.str(local.name);
            try self.key("start", false);
            try self.raw(try util.fmt(self.allocator, "{d}", .{local.start}));
            try self.key("value", false);
            try self.expression(local.value);
            try self.raw("}");
        }
        try self.raw("]");
        try self.key("snapshots", false);
        try self.strings(m.component.snapshots);
        try self.key("imports", false);
        try self.raw("[");
        for (m.component.imports, 0..) |import, i| {
            if (i > 0) try self.raw(",");
            try self.raw("{");
            try self.key("source", true);
            try self.str(import.source);
            try self.key("names", false);
            try self.raw("[");
            for (import.names, 0..) |name, j| {
                if (j > 0) try self.raw(",");
                try self.raw("{");
                try self.key("imported", true);
                try self.str(name.imported);
                try self.key("local", false);
                try self.str(name.local);
                try self.key("typeOnly", false);
                try self.raw(if (name.type_only) "true" else "false");
                try self.raw("}");
            }
            try self.raw("]}");
        }
        try self.raw("]");
        try self.key("behaviors", false);
        try self.strings(m.component.behaviors);
        if (m.component.reactive) |r| {
            try self.key("reactive", false);
            try self.raw("{");
            try self.key("store", true);
            try self.str(r.store);
            try self.key("actions", false);
            try self.strings(r.actions);
            try self.key("refs", false);
            try self.strings(r.refs);
            try self.raw("}");
        }
        if (m.component.family) |f| {
            try self.key("family", false);
            try self.raw("{");
            try self.key("store", true);
            try self.str(f.store);
            try self.key("state", false);
            try self.str(f.state);
            try self.key("actions", false);
            try self.strings(f.actions);
            try self.key("refs", false);
            try self.strings(f.refs);
            try self.key("seeds", false);
            try self.raw(try util.fmt(self.allocator, "{d}", .{f.seeds}));
            try self.raw("}");
        }
        try self.raw("}");
        try self.key("classes", false);
        try self.strings(m.classes);
        try self.key("finiteMaps", false);
        try self.raw("{");
        for (m.finite_maps.keys(), m.finite_maps.values(), 0..) |name, entries, i| {
            try self.key(name, i == 0);
            try self.raw("{");
            for (entries.keys(), entries.values(), 0..) |k, v, j| {
                try self.key(k, j == 0);
                try self.str(v);
            }
            try self.raw("}");
        }
        try self.raw("}");
        try self.key("capabilities", false);
        try self.raw("[");
        for (m.capabilities, 0..) |c, i| {
            if (i > 0) try self.raw(",");
            try self.str(c.name());
        }
        try self.raw("]");
        try self.extensions(m);
        try self.raw("}");
    }

    /// Expressions and generated code that ride alongside the IR proper for
    /// SSR backends (family seeds, initial state, the client store
    /// registration). Omitted entirely when empty, so TS-compiler output
    /// (which carries none) stays byte-identical.
    fn extensions(self: *Json, m: *const ModuleIR) WriteError!void {
        const seeds: []const SeedIR = if (m.component.family) |f| f.seed_exprs else &.{};
        const initial: []const InitialIR = if (m.component.family) |f|
            f.initial
        else if (m.component.reactive) |r|
            r.initial
        else
            &.{};
        if (seeds.len == 0 and initial.len == 0 and m.component.store_registration == null) return;

        try self.key("extensions", false);
        try self.raw("{");
        var first = true;
        if (seeds.len > 0) {
            try self.key("familySeeds", first);
            first = false;
            try self.raw("[");
            for (seeds, 0..) |seed, i| {
                if (i > 0) try self.raw(",");
                try self.raw("{");
                try self.key("field", true);
                try self.str(seed.field);
                try self.key("value", false);
                try self.expression(seed.value);
                try self.raw("}");
            }
            try self.raw("]");
        }
        if (initial.len > 0) {
            try self.key("initialState", first);
            first = false;
            try self.raw("{");
            for (initial, 0..) |entry, i| {
                try self.key(entry.field, i == 0);
                if (entry.value) |value| {
                    try self.raw("{");
                    try self.key("expr", true);
                    try self.expression(value);
                    try self.raw("}");
                } else {
                    try self.raw("{\"unservable\":true}");
                }
            }
            try self.raw("}");
        }
        if (m.component.store_registration) |registration| {
            try self.key("storeRegistration", first);
            first = false;
            try self.raw("{");
            try self.key("name", true);
            try self.str(registration.name);
            try self.key("code", false);
            try self.str(registration.code);
            try self.raw("}");
        }
        try self.raw("}");
    }
};

/// Stream `JSON.stringify(module)` — the exact shape out-of-process targets
/// receive — into `writer`. `allocator` only backs transient number formatting.
pub fn writeJson(allocator: Allocator, module: *const ModuleIR, writer: *std.Io.Writer) Json.WriteError!void {
    var json = Json{ .allocator = allocator, .out = writer };
    try json.module(module);
}

/// Portable IR transport: every numeric payload is a tagged binary64 bit
/// pattern, including defaults. This never emits invalid JSON for infinities.
pub fn writeLosslessJson(allocator: Allocator, module: *const ModuleIR, writer: *std.Io.Writer) Json.WriteError!void {
    var json = Json{ .allocator = allocator, .out = writer, .lossless_numbers = true };
    try json.module(module);
}

/// `JSON.stringify(module)` as an owned string.
pub fn toJson(allocator: Allocator, module: *const ModuleIR) Allocator.Error![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    writeJson(allocator, module, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// AST expression → IR expression, for out-of-process consumers that carry
/// extra expressions alongside the module IR (an SSR backend's family seeds
/// and initial-state values).
pub fn expressionToIR(allocator: Allocator, node: *Node, parsed: *const analyze.ParsedModule) Error!*const ExpressionIR {
    return expressionIR(allocator, node, parsed);
}

/// One IR expression as JSON — the same encoding `toJson` uses.
pub fn expressionToJson(allocator: Allocator, e: *const ExpressionIR) Allocator.Error![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    var json = Json{ .allocator = allocator, .out = &out.writer };
    json.expression(e) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `JSON.parse(JSON.stringify(x))` deep-equals `x`: parse the JSON into a
/// generic value, re-serialize it, and compare against a canonical rendering.
fn jsonRoundTripEquals(allocator: Allocator, json: []const u8) !bool {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
    const once = try std.json.Stringify.valueAlloc(allocator, parsed, .{});
    const again = try std.json.parseFromSliceLeaky(std.json.Value, allocator, once, .{});
    const twice = try std.json.Stringify.valueAlloc(allocator, again, .{});
    return util.eql(once, twice) and util.eql(once, try std.json.Stringify.valueAlloc(allocator, parsed, .{}));
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

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "a third-party target compiles the public semantic IR without changing PJSX core" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const Options = struct { prefix: []const u8 };
    const Manifest = struct {
        fn compile(allocator: Allocator, module: *const ModuleIR, context: CompileContext, options: Options) Error![]const u8 {
            if (!util.eql(context.filename, "badge.pjsx")) return err.failMsg("wrong filename");
            if (module.component.root.* != .element) return err.failMsg("root is not an element");
            return util.fmt(allocator, "{s}:{s}:{s}", .{ options.prefix, module.component.name, try util.join(allocator, module.component.props.keys(), ",") });
        }
    };
    const target = TargetPlugin(Options, []const u8){ .name = "component-manifest", .api_version = 1, .compile = Manifest.compile };
    const output = try compilePjsx(Options, []const u8, a, .{ .source = badge_source }, .{ .filename = "badge.pjsx", .target = target, .target_options = .{ .prefix = "custom" } });
    try std.testing.expectEqualStrings("custom:Badge:label", output);
    const module = try createPjsxModule(a, badge_source, "badge.pjsx");
    try std.testing.expect(module.component.root.* == .element);
}

test "compilePjsx rejects a target on another compiler API version" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const Noop = struct {
        fn compile(_: Allocator, _: *const ModuleIR, _: CompileContext, _: void) Error!void {}
    };
    const target = TargetPlugin(void, void){ .name = "old", .api_version = 2, .compile = Noop.compile };
    try std.testing.expectError(error.Pjsx, compilePjsx(void, void, a, .{ .source = badge_source }, .{ .filename = "badge.pjsx", .target = target, .target_options = {} }));
    try std.testing.expectEqualStrings("pjsx: target \"old\" uses compiler API 2; expected 1", err.message());
}

test "compilePjsx rejects modules needing capabilities the target lacks" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const Noop = struct {
        fn compile(_: Allocator, _: *const ModuleIR, _: CompileContext, _: void) Error!void {}
    };
    const source =
        \\export const listProps = {};
        \\export function List() { return <><Item /></>; }
    ;
    const target = TargetPlugin(void, void){ .name = "plain", .api_version = 1, .capabilities = &.{.fragments}, .compile = Noop.compile };
    try std.testing.expectError(error.Pjsx, compilePjsx(void, void, a, .{ .source = source }, .{ .filename = "list.ptsx", .target = target, .target_options = {} }));
    try std.testing.expectEqualStrings("pjsx: target \"plain\" does not support: components", err.message());
}

test "the IR carries module-level finite string maps so targets need no AST" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const module = try createPjsxModule(a,
        \\const toneClass = {
        \\  draft: "text-muted-foreground",
        \\  published: "text-success",
        \\};
        \\
        \\export const dotProps = {
        \\  tone: { type: "string", default: "draft" },
        \\};
        \\
        \\export function Dot({ tone }) {
        \\  return <span data-part="dot" class={toneClass[tone]} />;
        \\}
    , "dot.ptsx");
    try std.testing.expectEqual(@as(usize, 1), module.finite_maps.count());
    const tone = module.finite_maps.get("toneClass").?;
    try std.testing.expectEqualStrings("text-muted-foreground", tone.get("draft").?);
    try std.testing.expectEqualStrings("text-success", tone.get("published").?);
    const json = try toJson(a, module);
    try std.testing.expect(util.indexOf(json, "\"finiteMaps\":{\"toneClass\":{\"draft\":\"text-muted-foreground\",\"published\":\"text-success\"}}") != null);
}

test "the whole IR survives a JSON round-trip for out-of-process targets" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const module = try createPjsxModule(a, badge_source, "badge.pjsx");
    const json = try toJson(a, module);
    try std.testing.expect(try jsonRoundTripEquals(a, json));
    try std.testing.expect(util.indexOf(json, "\"apiVersion\":1") != null);
    try std.testing.expect(util.indexOf(json, "\"root\":{\"kind\":\"element\"") != null);
    try std.testing.expect(util.indexOf(json, "\"capabilities\":[]") != null);
    try std.testing.expect(util.indexOf(json, "\"props\":{\"label\":{\"type\":\"string\",\"optional\":false}}") != null);
}

test "IR capabilities are sorted so serialized modules are byte-stable" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\export const demoProps = { items: { type: "array", items: "string" }, on: { type: "action", optional: true } };
        \\export function Demo({ items, on }) {
        \\  return <><Slot style={{}} @portal>{items.map((i) => <b>{i}</b>)}</Slot>{on ? <i /> : null}</>;
        \\}
    ;
    const module = try createPjsxModule(a, source, "demo.ptsx");
    try std.testing.expect(module.capabilities.len >= 5);
    var i: usize = 1;
    while (i < module.capabilities.len) : (i += 1) {
        try std.testing.expect(std.mem.order(u8, module.capabilities[i - 1].name(), module.capabilities[i].name()) == .lt);
    }
    try std.testing.expect(std.mem.indexOfScalar(Capability, module.capabilities, .loops) != null);
    try std.testing.expect(std.mem.indexOfScalar(Capability, module.capabilities, .conditionals) != null);
    try std.testing.expect(std.mem.indexOfScalar(Capability, module.capabilities, .slot) != null);
}

test "side-effect imports surface as explicit component behaviors" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const module = try createPjsxModule(a,
        \\import "../../behaviors/dropdown";
        \\
        \\export const menuProps = {
        \\  children: { type: "node" },
        \\};
        \\
        \\export function Menu({ children }) {
        \\  return (
        \\    <div data-part="menu" @store="dropdown-menu">
        \\      {children}
        \\    </div>
        \\  );
        \\}
    , "menu.ptsx");
    try std.testing.expectEqual(@as(usize, 1), module.component.behaviors.len);
    try std.testing.expectEqualStrings("../../behaviors/dropdown", module.component.behaviors[0]);
    const badge = try createPjsxModule(a, badge_source, "badge.pjsx");
    try std.testing.expectEqual(@as(usize, 0), badge.component.behaviors.len);
}

test "the compiler core contains no built-in backend names or target switch" {
    const core = @embedFile("compiler.zig") ++ "\n" ++ @embedFile("root.zig");
    // Skip this test's own body when scanning: everything above the marker.
    const marker = "the compiler core contains no built-in backend names";
    const scanned = core[0..std.mem.indexOf(u8, core, marker).?];
    for ([_][]const u8{ "DomOutput", "ZigOutput", "ReactTarget", "ZigTarget", "@import(\"targets/", "switch (target", "request.target" }) |pattern| {
        try std.testing.expect(util.indexOf(scanned, pattern) == null);
    }
}

test "the compiler contains no concrete component directives" {
    const files = @embedFile("canonicalize.zig") ++ "\n" ++ @embedFile("compiler.zig");
    const marker = "the compiler contains no concrete component directives";
    const scanned = files[0..std.mem.indexOf(u8, files, marker).?];
    for ([_][]const u8{ "$$accordion", "$$menu", "$$select", "$$unitControl", "data-p-accordion", "data-p-menu", "data-p-select", "data-p-unit-control" }) |pattern| {
        try std.testing.expect(util.indexOf(scanned, pattern) == null);
    }
}
