//! ESTree-shaped syntax tree (the shape oxc-parser produces), as one fat node
//! struct. The reference compiler treats nodes as loosely typed records and
//! walks/clones them generically over `Object.entries`; a uniform struct with a
//! comptime child-field table keeps those generic operations a direct port.
//!
//! Every node is arena-allocated and immutable after parsing except for the
//! `pjsx_*` annotation fields the analyzer writes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Type = enum {
    // Program / statements
    Program,
    BlockStatement,
    EmptyStatement,
    DebuggerStatement,
    ExpressionStatement,
    ReturnStatement,
    IfStatement,
    ForStatement,
    ForInStatement,
    ForOfStatement,
    WhileStatement,
    DoWhileStatement,
    BreakStatement,
    ContinueStatement,
    ThrowStatement,
    TryStatement,
    CatchClause,
    SwitchStatement,
    SwitchCase,
    LabeledStatement,
    VariableDeclaration,
    VariableDeclarator,
    FunctionDeclaration,
    ClassDeclaration,
    ClassExpression,
    ClassBody,
    MethodDefinition,
    PropertyDefinition,
    StaticBlock,
    ImportDeclaration,
    ImportSpecifier,
    ImportDefaultSpecifier,
    ImportNamespaceSpecifier,
    ExportNamedDeclaration,
    ExportDefaultDeclaration,
    ExportAllDeclaration,
    ExportSpecifier,
    // Expressions
    Identifier,
    PrivateIdentifier,
    Literal,
    TemplateLiteral,
    TemplateElement,
    TaggedTemplateExpression,
    ArrayExpression,
    ObjectExpression,
    Property,
    FunctionExpression,
    ArrowFunctionExpression,
    UnaryExpression,
    UpdateExpression,
    BinaryExpression,
    LogicalExpression,
    AssignmentExpression,
    ConditionalExpression,
    CallExpression,
    NewExpression,
    MemberExpression,
    ChainExpression,
    SequenceExpression,
    SpreadElement,
    YieldExpression,
    AwaitExpression,
    ThisExpression,
    Super,
    MetaProperty,
    ImportExpression,
    ParenthesizedExpression,
    // Patterns
    ObjectPattern,
    ArrayPattern,
    RestElement,
    AssignmentPattern,
    // JSX
    JSXElement,
    JSXFragment,
    JSXOpeningElement,
    JSXClosingElement,
    JSXOpeningFragment,
    JSXClosingFragment,
    JSXIdentifier,
    JSXNamespacedName,
    JSXMemberExpression,
    JSXAttribute,
    JSXSpreadAttribute,
    JSXExpressionContainer,
    JSXEmptyExpression,
    JSXSpreadChild,
    JSXText,
    // TypeScript (opaque: ranges only, no children)
    TSTypeAnnotation,
    TSType,
    TSTypeParameterDeclaration,
    TSTypeParameterInstantiation,
    TSAsExpression,
    TSSatisfiesExpression,
    TSNonNullExpression,
    TSTypeAssertion,
    TSDeclaration, // interface / type alias / enum / namespace / declare …

    pub fn name(self: Type) []const u8 {
        return @tagName(self);
    }

    pub fn isTs(self: Type) bool {
        return std.mem.startsWith(u8, @tagName(self), "TS");
    }
};

pub const LiteralValue = union(enum) {
    none,
    null,
    string: []const u8,
    number: f64,
    boolean: bool,
    regex: []const u8,
    bigint: []const u8,

    pub fn isString(self: LiteralValue) bool {
        return self == .string;
    }
    pub fn isNumber(self: LiteralValue) bool {
        return self == .number;
    }
    pub fn isBoolean(self: LiteralValue) bool {
        return self == .boolean;
    }
    /// JavaScript `value == null` for a literal payload.
    pub fn isNullish(self: LiteralValue) bool {
        return self == .null or self == .none;
    }
    pub fn asString(self: LiteralValue) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }
    pub fn asNumber(self: LiteralValue) ?f64 {
        return switch (self) {
            .number => |n| n,
            else => null,
        };
    }
};

pub const Kind = enum { init, get, set, constructor, method, @"var", let, @"const", using, none };
pub const ImportKind = enum { value, type };

pub const JsxGuard = enum { truthy, boolean, presence };

pub const Node = struct {
    pjsx_guard: JsxGuard = .truthy,
    type: Type,
    start: u32 = 0,
    end: u32 = 0,

    // Identifier / JSXIdentifier / PrivateIdentifier name; Property.kind etc. below.
    name: []const u8 = "",
    // Literal / JSXText / TemplateElement payload.
    value: LiteralValue = .none,
    raw: []const u8 = "",
    cooked: ?[]const u8 = null,
    tail: bool = false,
    operator: []const u8 = "",
    kind: Kind = .none,
    import_kind: ImportKind = .value,
    export_kind: ImportKind = .value,
    computed: bool = false,
    optional: bool = false,
    shorthand: bool = false,
    method: bool = false,
    static: bool = false,
    prefix: bool = false,
    async: bool = false,
    generator: bool = false,
    expression_body: bool = false,
    self_closing: bool = false,
    await_: bool = false,

    // Single child links (ESTree names).
    expression: ?*Node = null,
    object: ?*Node = null,
    property: ?*Node = null,
    left: ?*Node = null,
    right: ?*Node = null,
    test_: ?*Node = null,
    consequent: ?*Node = null,
    alternate: ?*Node = null,
    callee: ?*Node = null,
    id: ?*Node = null,
    body: ?*Node = null,
    key: ?*Node = null,
    value_node: ?*Node = null,
    init: ?*Node = null,
    update: ?*Node = null,
    argument: ?*Node = null,
    label: ?*Node = null,
    block: ?*Node = null,
    handler: ?*Node = null,
    finalizer: ?*Node = null,
    param: ?*Node = null,
    discriminant: ?*Node = null,
    super_class: ?*Node = null,
    tag: ?*Node = null,
    quasi: ?*Node = null,
    source: ?*Node = null,
    declaration: ?*Node = null,
    imported: ?*Node = null,
    exported: ?*Node = null,
    local: ?*Node = null,
    meta: ?*Node = null,
    opening_element: ?*Node = null,
    closing_element: ?*Node = null,
    opening_fragment: ?*Node = null,
    closing_fragment: ?*Node = null,
    name_node: ?*Node = null,
    namespace: ?*Node = null,
    type_annotation: ?*Node = null,
    type_parameters: ?*Node = null,
    type_arguments: ?*Node = null,
    return_type: ?*Node = null,

    // Child lists (ESTree names).
    statements: []*Node = &.{}, // Program.body / BlockStatement.body / StaticBlock.body / ClassBody.body
    declarations: []*Node = &.{},
    params: []*Node = &.{},
    arguments: []*Node = &.{},
    elements: []?*Node = &.{}, // ArrayExpression / ArrayPattern (holes are null)
    properties: []*Node = &.{},
    expressions: []*Node = &.{},
    quasis: []*Node = &.{},
    specifiers: []*Node = &.{},
    cases: []*Node = &.{},
    consequents: []*Node = &.{}, // SwitchCase.consequent
    attributes: []*Node = &.{},
    children: []*Node = &.{},

    // PJSX analyzer annotations (ast.ts `pjsxRefName` / `pjsxRefAccess`).
    pjsx_ref_name: ?[]const u8 = null,
    pjsx_ref_access: ?[]const u8 = null,

    pub fn is(self: *const Node, t: Type) bool {
        return self.type == t;
    }

    pub fn isJsx(self: *const Node) bool {
        return self.type == .JSXElement or self.type == .JSXFragment;
    }

    pub fn isFunction(self: *const Node) bool {
        return self.type == .FunctionDeclaration or self.type == .FunctionExpression or self.type == .ArrowFunctionExpression;
    }

    /// `node.type === "Identifier" && node.name === name`
    pub fn isIdentifier(self: *const Node, ident: []const u8) bool {
        return self.type == .Identifier and std.mem.eql(u8, self.name, ident);
    }

    /// Literal string payload, if this is a string literal.
    pub fn stringValue(self: *const Node) ?[]const u8 {
        if (self.type != .Literal) return null;
        return self.value.asString();
    }

    pub fn identifierName(self: ?*const Node) ?[]const u8 {
        const n = self orelse return null;
        return if (n.type == .Identifier or n.type == .JSXIdentifier) n.name else null;
    }

    /// Shallow copy into a fresh arena node.
    pub fn clone(self: *const Node, allocator: Allocator) Allocator.Error!*Node {
        const copy = try allocator.create(Node);
        copy.* = self.*;
        return copy;
    }

    pub fn slice(self: *const Node, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// Single-child fields, in ESTree property order per node type.
pub const single_fields = [_][]const u8{
    "id",          "meta",            "property",        "object",           "callee",           "tag",
    "quasi",       "left",            "right",           "test_",            "consequent",       "alternate",
    "argument",    "expression",      "label",           "block",            "handler",          "param",
    "finalizer",   "discriminant",    "init",            "update",           "super_class",      "key",
    "value_node",  "body",            "source",          "imported",         "local",            "exported",
    "declaration", "opening_element", "closing_element", "opening_fragment", "closing_fragment", "name_node",
    "namespace",
};

/// Ordered child fields per node type: `.{ field_name, is_list }`. Order
/// matches oxc's ESTree serialization so generic walks visit children in
/// source order like the reference implementation.
pub fn childFields(t: Type) []const ChildField {
    return switch (t) {
        .Program => &.{.{ .statements, true }},
        .BlockStatement, .StaticBlock, .ClassBody => &.{.{ .statements, true }},
        .ExpressionStatement => &.{.{ .expression, false }},
        .ReturnStatement, .ThrowStatement, .SpreadElement, .RestElement, .YieldExpression, .AwaitExpression, .UnaryExpression, .UpdateExpression => &.{.{ .argument, false }},
        .IfStatement, .ConditionalExpression => &.{ .{ .test_, false }, .{ .consequent, false }, .{ .alternate, false } },
        .ForStatement => &.{ .{ .init, false }, .{ .test_, false }, .{ .update, false }, .{ .body, false } },
        .ForInStatement, .ForOfStatement => &.{ .{ .left, false }, .{ .right, false }, .{ .body, false } },
        .WhileStatement => &.{ .{ .test_, false }, .{ .body, false } },
        .DoWhileStatement => &.{ .{ .body, false }, .{ .test_, false } },
        .BreakStatement, .ContinueStatement => &.{.{ .label, false }},
        .TryStatement => &.{ .{ .block, false }, .{ .handler, false }, .{ .finalizer, false } },
        .CatchClause => &.{ .{ .param, false }, .{ .body, false } },
        .SwitchStatement => &.{ .{ .discriminant, false }, .{ .cases, true } },
        .SwitchCase => &.{ .{ .test_, false }, .{ .consequents, true } },
        .LabeledStatement => &.{ .{ .label, false }, .{ .body, false } },
        .VariableDeclaration => &.{.{ .declarations, true }},
        .VariableDeclarator => &.{ .{ .id, false }, .{ .init, false } },
        .FunctionDeclaration, .FunctionExpression => &.{ .{ .id, false }, .{ .params, true }, .{ .body, false } },
        .ArrowFunctionExpression => &.{ .{ .params, true }, .{ .body, false } },
        .ClassDeclaration, .ClassExpression => &.{ .{ .id, false }, .{ .super_class, false }, .{ .body, false } },
        .MethodDefinition, .PropertyDefinition, .Property => &.{ .{ .key, false }, .{ .value_node, false } },
        .ImportDeclaration => &.{ .{ .specifiers, true }, .{ .source, false } },
        .ImportSpecifier => &.{ .{ .imported, false }, .{ .local, false } },
        .ImportDefaultSpecifier, .ImportNamespaceSpecifier => &.{.{ .local, false }},
        .ExportNamedDeclaration => &.{ .{ .declaration, false }, .{ .specifiers, true }, .{ .source, false } },
        .ExportDefaultDeclaration => &.{.{ .declaration, false }},
        .ExportAllDeclaration => &.{ .{ .exported, false }, .{ .source, false } },
        .ExportSpecifier => &.{ .{ .local, false }, .{ .exported, false } },
        .TemplateLiteral => &.{ .{ .quasis, true }, .{ .expressions, true } },
        .TaggedTemplateExpression => &.{ .{ .tag, false }, .{ .quasi, false } },
        .ArrayExpression, .ArrayPattern => &.{.{ .elements, true }},
        .ObjectExpression, .ObjectPattern => &.{.{ .properties, true }},
        .BinaryExpression, .LogicalExpression, .AssignmentExpression, .AssignmentPattern => &.{ .{ .left, false }, .{ .right, false } },
        .CallExpression, .NewExpression => &.{ .{ .callee, false }, .{ .arguments, true } },
        .MemberExpression, .JSXMemberExpression => &.{ .{ .object, false }, .{ .property, false } },
        .ChainExpression, .ParenthesizedExpression, .TSAsExpression, .TSSatisfiesExpression, .TSNonNullExpression, .TSTypeAssertion, .JSXExpressionContainer, .JSXSpreadChild => &.{.{ .expression, false }},
        .SequenceExpression => &.{.{ .expressions, true }},
        .MetaProperty => &.{ .{ .meta, false }, .{ .property, false } },
        .ImportExpression => &.{.{ .source, false }},
        .JSXElement => &.{ .{ .opening_element, false }, .{ .children, true }, .{ .closing_element, false } },
        .JSXFragment => &.{ .{ .opening_fragment, false }, .{ .children, true }, .{ .closing_fragment, false } },
        .JSXOpeningElement => &.{ .{ .name_node, false }, .{ .attributes, true } },
        .JSXClosingElement => &.{.{ .name_node, false }},
        .JSXNamespacedName => &.{ .{ .namespace, false }, .{ .name_node, false } },
        .JSXAttribute => &.{ .{ .name_node, false }, .{ .value_node, false } },
        .JSXSpreadAttribute => &.{.{ .argument, false }},
        else => &.{},
    };
}

pub const ChildField = struct { Field, bool };

pub const Field = enum {
    id,
    meta,
    property,
    object,
    callee,
    tag,
    quasi,
    left,
    right,
    test_,
    consequent,
    alternate,
    argument,
    expression,
    label,
    block,
    handler,
    param,
    finalizer,
    discriminant,
    init,
    update,
    super_class,
    key,
    value_node,
    body,
    source,
    imported,
    local,
    exported,
    declaration,
    opening_element,
    closing_element,
    opening_fragment,
    closing_fragment,
    name_node,
    namespace,
    statements,
    declarations,
    params,
    arguments,
    elements,
    properties,
    expressions,
    quasis,
    specifiers,
    cases,
    consequents,
    attributes,
    children,
};

pub fn getSingle(node: *const Node, field: Field) ?*Node {
    return switch (field) {
        inline else => |f| blk: {
            const fname = @tagName(f);
            if (@TypeOf(@field(node, fname)) == ?*Node) break :blk @field(node, fname);
            break :blk null;
        },
    };
}

pub fn setSingle(node: *Node, field: Field, value: ?*Node) void {
    switch (field) {
        inline else => |f| {
            const fname = @tagName(f);
            if (@TypeOf(@field(node, fname)) == ?*Node) @field(node, fname) = value;
        },
    }
}

/// List children; `elements` (which may hold holes) is exposed as optionals.
pub fn getList(node: *const Node, field: Field) []const ?*Node {
    return switch (field) {
        .elements => node.elements,
        inline else => |f| blk: {
            const fname = @tagName(f);
            if (@TypeOf(@field(node, fname)) == []*Node) {
                const list: []*Node = @field(node, fname);
                break :blk @as([]const ?*Node, @ptrCast(list));
            }
            break :blk &.{};
        },
    };
}

pub fn setList(node: *Node, field: Field, value: []?*Node) void {
    switch (field) {
        .elements => node.elements = value,
        inline else => |f| {
            const fname = @tagName(f);
            if (@TypeOf(@field(node, fname)) == []*Node) {
                @field(node, fname) = @as([]*Node, @ptrCast(value));
            }
        },
    }
}

/// Visit every child node in ESTree order (holes skipped).
pub fn eachChild(node: *const Node, context: anytype, comptime visit: fn (@TypeOf(context), *Node) anyerror!void) anyerror!void {
    for (childFields(node.type)) |cf| {
        if (cf[1]) {
            for (getList(node, cf[0])) |child| {
                if (child) |c| try visit(context, c);
            }
        } else if (getSingle(node, cf[0])) |child| {
            try visit(context, child);
        }
    }
}

/// Pre-order walk over the whole subtree (ast.ts `walkAst`).
pub fn walk(node: *Node, context: anytype, comptime visit: fn (@TypeOf(context), *Node) anyerror!void) anyerror!void {
    try visit(context, node);
    for (childFields(node.type)) |cf| {
        if (cf[1]) {
            for (getList(node, cf[0])) |child| {
                if (child) |c| try walk(c, context, visit);
            }
        } else if (getSingle(node, cf[0])) |child| {
            try walk(child, context, visit);
        }
    }
}

/// Does any node in the subtree satisfy `predicate`?
pub fn contains(node: *Node, context: anytype, comptime predicate: fn (@TypeOf(context), *Node) bool) bool {
    if (predicate(context, node)) return true;
    for (childFields(node.type)) |cf| {
        if (cf[1]) {
            for (getList(node, cf[0])) |child| {
                if (child) |c| if (contains(c, context, predicate)) return true;
            }
        } else if (getSingle(node, cf[0])) |child| {
            if (contains(child, context, predicate)) return true;
        }
    }
    return false;
}

/// `value.type === "ParenthesizedExpression" ? unparen(value.expression) : value`
pub fn unparen(node: *Node) *Node {
    var current = node;
    while (current.type == .ParenthesizedExpression) current = current.expression.?;
    return current;
}

pub fn newNode(allocator: Allocator, t: Type, start: u32, end: u32) Allocator.Error!*Node {
    const node = try allocator.create(Node);
    node.* = .{ .type = t, .start = start, .end = end };
    return node;
}

pub fn literalString(allocator: Allocator, value: []const u8, source: ?*const Node) Allocator.Error!*Node {
    const node = try newNode(allocator, .Literal, if (source) |s| s.start else 0, if (source) |s| s.end else 0);
    node.value = .{ .string = value };
    const util = @import("util.zig");
    node.raw = try util.jsonString(allocator, value);
    return node;
}

test "childFields order visits JSX element children in source order" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const el = try newNode(aa, .JSXElement, 0, 10);
    const opening = try newNode(aa, .JSXOpeningElement, 0, 3);
    const child = try newNode(aa, .JSXText, 3, 7);
    const closing = try newNode(aa, .JSXClosingElement, 7, 10);
    el.opening_element = opening;
    el.closing_element = closing;
    const kids = try aa.alloc(*Node, 1);
    kids[0] = child;
    el.children = kids;
    var seen: std.ArrayList(Type) = .empty;
    defer seen.deinit(a);
    const Ctx = struct {
        list: *std.ArrayList(Type),
        alloc: Allocator,
        fn visit(self: @This(), n: *Node) anyerror!void {
            try self.list.append(self.alloc, n.type);
        }
    };
    try walk(el, Ctx{ .list = &seen, .alloc = a }, Ctx.visit);
    try std.testing.expectEqualSlices(Type, &.{ .JSXElement, .JSXOpeningElement, .JSXText, .JSXClosingElement }, seen.items);
}
