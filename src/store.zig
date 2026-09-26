//! Target-neutral store-registration lowering: for stateful components (a
//! `Publr.reactive` binding or a compound-family root), the client-side
//! `Publr.createLocalStore(...)` registration companion. Also home to the
//! server-expression typing helpers (`Kind`, `serverExpressionKind`, prop
//! seeds) the lowering shares with SSR targets.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Node = ast.Node;
const err = @import("err.zig");
const util = @import("util.zig");
const js = @import("js.zig");
const analyze = @import("analyze.zig");

const Error = err.Error;
const OrderedMap = util.OrderedMap;
const StringList = util.StringList;
const Schema = analyze.Schema;
const PropSchema = analyze.PropSchema;
const ReactiveBinding = analyze.ReactiveBinding;
const FiniteStringMaps = analyze.FiniteStringMaps;
pub const Bindings = OrderedMap([]const u8);
const unwrap = analyze.unwrap;
const eql = util.eql;

pub const StoreRegistrationOutput = struct {
    name: []const u8,
    code: []const u8,
};

pub fn fmt(a: Allocator, comptime format: []const u8, args: anytype) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, format, args);
}

pub fn jsonString(a: Allocator, value: []const u8) Allocator.Error![]const u8 {
    return util.jsonString(a, value);
}

/// `String(literal.value)`
pub fn literalString(a: Allocator, node: *const Node) Allocator.Error![]const u8 {
    return js.Value.fromLiteral(node.value).toString(a);
}

pub fn typeOf(node: ?*Node) ?ast.Type {
    const n = node orelse return null;
    return n.type;
}

pub fn isIdent(node: ?*Node, name: []const u8) bool {
    const n = node orelse return false;
    return n.isIdentifier(name);
}

pub fn isStringLiteral(node: *const Node) bool {
    return node.type == .Literal and node.value == .string;
}

pub fn staticKey(a: Allocator, node: *const Node) Allocator.Error!?[]const u8 {
    if (node.computed) return null;
    const key = node.key orelse return null;
    if (key.type == .Identifier) return key.name;
    if (key.type == .Literal) return try literalString(a, key);
    return null;
}

pub const Kind = enum {
    string,
    boolean,
    number,
    optional_number,
    raw,
    optional_string,
    optional_boolean,
    optional_raw,
    array,
    optional_array,
    @"union",
    null,
    unknown,

    fn fromItem(item: analyze.ItemType) Kind {
        return switch (item) {
            .string => .string,
            .number => .number,
            .boolean => .boolean,
        };
    }
};

fn loopBindingKind(binding: []const u8) ?Kind {
    if (!std.mem.startsWith(u8, binding, "$loop:")) return null;
    const rest = binding["$loop:".len..];
    const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
    const kind = rest[0..end];
    if (eql(kind, "string")) return .string;
    if (eql(kind, "number")) return .number;
    if (eql(kind, "boolean")) return .boolean;
    return null;
}

pub fn optionalInnerKind(kind: Kind) ?Kind {
    return switch (kind) {
        .optional_string => .string,
        .optional_boolean => .boolean,
        .optional_number => .number,
        .optional_raw => .raw,
        .optional_array => .array,
        else => null,
    };
}

pub fn nullishResultKind(left: Kind, right: Kind) Kind {
    const inner = optionalInnerKind(left) orelse return left;
    if (right == inner) return inner;
    if (right == left) return left;
    return .unknown;
}

pub fn boundPropName(a: Allocator, node: *Node, bindings: *const Bindings) Allocator.Error!?[]const u8 {
    const value = unwrap(node);
    if (value.type == .Identifier) {
        const name = bindings.get(value.name) orelse return null;
        return if (eql(name, "$props")) null else name;
    }
    if (value.type == .MemberExpression and typeOf(value.object) == .Identifier) {
        const property_node = value.property.?;
        const property: ?[]const u8 = if (!value.computed and property_node.type == .Identifier)
            property_node.name
        else if (value.computed and isStringLiteral(property_node))
            property_node.value.string
        else
            null;
        if (property) |p| return bindings.get(try fmt(a, "{s}.{s}", .{ value.object.?.name, p }));
    }
    return null;
}

/// Expression-emission context shared by the typing and printing passes.
pub const Ctx = struct {
    a: Allocator,
    bindings: *const Bindings,
    schema: *const Schema,
    finite_maps: *const FiniteStringMaps,

    pub fn withBindings(self: Ctx, bindings: *const Bindings) Ctx {
        return .{ .a = self.a, .bindings = bindings, .schema = self.schema, .finite_maps = self.finite_maps };
    }

    pub fn field(self: Ctx, name: ?[]const u8) ?PropSchema {
        return self.schema.get(name orelse return null);
    }

    pub fn boundProp(self: Ctx, node: *Node) Allocator.Error!?[]const u8 {
        return boundPropName(self.a, node, self.bindings);
    }
};

fn isComparison(op: []const u8) bool {
    const ops = [_][]const u8{ "==", "!=", "===", "!==", "<", "<=", ">", ">=" };
    return util.containsString(&ops, op);
}

pub fn isMathMinMax(node: *const Node) bool {
    if (node.type != .CallExpression) return false;
    const callee = node.callee.?;
    return callee.type == .MemberExpression and !callee.computed and isIdent(callee.object, "Math") and
        callee.property != null and (isIdent(callee.property, "min") or isIdent(callee.property, "max"));
}

pub fn isMemberCall(node: *const Node, method: []const u8) bool {
    if (node.type != .CallExpression) return false;
    const callee = node.callee.?;
    return callee.type == .MemberExpression and !callee.computed and isIdent(callee.property, method);
}

pub fn itemFieldOf(ctx: Ctx, indexed: *Node, name: []const u8) Allocator.Error!?PropSchema {
    const array_prop = try ctx.boundProp(indexed.object.?) orelse return null;
    const collection = ctx.field(array_prop) orelse return null;
    const fields = collection.fields orelse return null;
    return fields.get(name);
}

pub fn serverExpressionKind(ctx: Ctx, node: *Node) Error!Kind {
    const a = ctx.a;
    const value = unwrap(node);
    if (try ctx.boundProp(value)) |bound_prop| {
        if (loopBindingKind(bound_prop)) |loop_kind| return loop_kind;
        if (ctx.field(bound_prop)) |field| {
            switch (field.type) {
                .children, .node => return if (field.optional) .optional_raw else .raw,
                .optional_string => return .optional_string,
                .optional_boolean => return .optional_boolean,
                .optional_number => return .optional_number,
                .element, .style => return .string,
                .array => return if (field.optional) .optional_array else .array,
                .@"union" => return .@"union",
                .string => return .string,
                .boolean => return .boolean,
                .number => return .number,
                else => {},
            }
        }
    }
    if (value.type == .Literal) {
        switch (value.value) {
            .string => return .string,
            .boolean => return .boolean,
            .number => return .number,
            .null, .none => return .null,
            else => {},
        }
    }
    if (value.isIdentifier("undefined")) return .null;
    if (value.type == .ArrayExpression) return .array;
    if (value.type == .TemplateLiteral) return .string;
    if (value.type == .MemberExpression and value.computed) {
        const collection_prop = try ctx.boundProp(value.object.?);
        const collection_field = ctx.field(collection_prop);
        const index = unwrap(value.property.?);
        if (collection_field != null and collection_field.?.type == .array and collection_field.?.items != null) {
            return Kind.fromItem(collection_field.?.items.?);
        }
        if (collection_field != null and collection_field.?.type == .@"union" and index.type == .Literal and index.value == .number and
            (index.value.number == 0 or index.value.number == 1))
        {
            return if (index.value.number == 0) .number else .string;
        }
    }
    if (value.type == .MemberExpression and !value.computed and isIdent(value.property, "length") and
        (try serverExpressionKind(ctx, value.object.?)) == .array)
    {
        return .number;
    }
    if (value.type == .MemberExpression and !value.computed and typeOf(value.property) == .Identifier and
        unwrap(value.object.?).type == .MemberExpression)
    {
        const indexed = unwrap(value.object.?);
        if (try itemFieldOf(ctx, indexed, value.property.?.name)) |item_field| {
            switch (item_field.type) {
                .string => return .string,
                .number => return .number,
                .boolean => return .boolean,
                else => {},
            }
        }
    }
    if (isMemberCall(value, "findIndex") and (try serverExpressionKind(ctx, value.callee.?.object.?)) == .array) {
        return .number;
    }
    if (value.type == .CallExpression and isIdent(value.callee, "initials") and value.arguments.len == 1 and
        (try serverExpressionKind(ctx, value.arguments[0])) == .string)
    {
        return .string;
    }
    if (value.type == .CallExpression and isIdent(value.callee, "gravatarUrl") and value.arguments.len == 2) {
        const first = try serverExpressionKind(ctx, value.arguments[0]);
        if ((first == .string or first == .optional_string) and (try serverExpressionKind(ctx, value.arguments[1])) == .number) {
            return .string;
        }
    }
    if (isMathMinMax(value)) {
        var all_numbers = true;
        for (value.arguments) |argument| {
            if ((try serverExpressionKind(ctx, argument)) != .number) all_numbers = false;
        }
        if (all_numbers) return .number;
    }
    if (value.type == .MemberExpression and value.computed and typeOf(value.object) == .Identifier and
        ctx.finite_maps.has(value.object.?.name))
    {
        return .string;
    }
    if (value.type == .LogicalExpression) {
        const left = try serverExpressionKind(ctx, value.left.?);
        const right = try serverExpressionKind(ctx, value.right.?);
        if (eql(value.operator, "??")) return nullishResultKind(left, right);
        return if (left == right) left else .unknown;
    }
    if (value.type == .ConditionalExpression) {
        const consequent = try serverExpressionKind(ctx, value.consequent.?);
        const alternate = try serverExpressionKind(ctx, value.alternate.?);
        if (consequent == .null) return optionalized(alternate);
        if (alternate == .null) return optionalized(consequent);
        if ((consequent == .@"union" and alternate == .string) or (consequent == .string and alternate == .@"union")) {
            return .string;
        }
        return if (consequent == alternate) consequent else .unknown;
    }
    if (value.type == .UnaryExpression) {
        if (eql(value.operator, "!")) return .boolean;
        if (eql(value.operator, "typeof")) return .string;
        if ((eql(value.operator, "+") or eql(value.operator, "-")) and (try serverExpressionKind(ctx, value.argument.?)) == .number) {
            return .number;
        }
    }
    if (isMemberCall(value, "includes") and (try serverExpressionKind(ctx, value.callee.?.object.?)) == .string and
        value.arguments.len == 1 and (try serverExpressionKind(ctx, value.arguments[0])) == .string)
    {
        return .boolean;
    }
    if (value.type == .BinaryExpression) {
        if (isComparison(value.operator)) return .boolean;
        const left = try serverExpressionKind(ctx, value.left.?);
        const right = try serverExpressionKind(ctx, value.right.?);
        if (eql(value.operator, "+") and left == .string and right == .string) return .string;
        const arithmetic = [_][]const u8{ "+", "-", "*", "/", "%" };
        if (util.containsString(&arithmetic, value.operator) and left == .number and right == .number) return .number;
    }
    _ = a;
    return .unknown;
}

fn optionalized(kind: Kind) Kind {
    return switch (kind) {
        .string => .optional_string,
        .boolean => .optional_boolean,
        .number => .optional_number,
        .raw => .optional_raw,
        .array => .optional_array,
        else => kind,
    };
}

pub const ReactivePropSeed = struct {
    state_field: []const u8,
    prop_name: ?[]const u8,
    value: *Node,
};

fn initialBoundProp(a: Allocator, node: *Node, bindings: *const Bindings) Allocator.Error!?[]const u8 {
    const value = unwrap(node);
    if (try boundPropName(a, value, bindings)) |direct| return direct;
    if (value.type == .LogicalExpression and eql(value.operator, "??")) {
        return boundPropName(a, value.left.?, bindings);
    }
    return null;
}

fn expressionReadsBoundProp(a: Allocator, node: *Node, bindings: *const Bindings) bool {
    const Pred = struct {
        a: Allocator,
        bindings: *const Bindings,
        fn check(self: @This(), candidate: *Node) bool {
            const bound = boundPropName(self.a, candidate, self.bindings) catch return false;
            return bound != null;
        }
    };
    return ast.contains(node, Pred{ .a = a, .bindings = bindings }, Pred.check);
}

pub fn reactivePropSeeds(a: Allocator, reactive: *const ReactiveBinding, bindings: *const Bindings) Error![]const ReactivePropSeed {
    var seeds: std.ArrayList(ReactivePropSeed) = .empty;
    for (reactive.initial_state.properties) |field| {
        if (field.type != .Property) continue;
        // Getters are derived state — never a prop-driven seed.
        if (field.kind == .get) continue;
        const state_field = try staticKey(a, field);
        const prop_name = try initialBoundProp(a, field.value_node.?, bindings);
        const reads_prop = prop_name != null or expressionReadsBoundProp(a, field.value_node.?, bindings);
        if (state_field != null and reads_prop) {
            try seeds.append(a, .{ .state_field = state_field.?, .prop_name = prop_name, .value = field.value_node.? });
        }
    }
    return seeds.toOwnedSlice(a);
}

pub fn familyAsWireBinding(a: Allocator, parsed: *const analyze.ParsedModule) Error!?ReactiveBinding {
    const family = parsed.family orelse return null;
    var locals = OrderedMap([]const u8).init(a);
    for (family.actions) |name| try locals.put(name, name);
    return .{
        .state_name = family.state_name,
        .wire_name = family.wire_name,
        .initial_state = family.initial_state,
        .state_statement = family.state_statement,
        .local_statements = family.module_statements,
        .actions = family.actions,
        .argument_actions = &.{},
        .refs = family.refs,
        .constants = OrderedMap(*Node).init(a),
        .family_seeds = family.seed_assignments,
        .family_action_locals = locals,
    };
}

fn schemaFallback(field: ?PropSchema, kind: ?Kind) js.Value {
    _ = kind;
    if (field) |f| if (f.default) |default| return default.toJs();
    return .undefined;
}

fn seedStartDescending(_: void, left: ReactivePropSeed, right: ReactivePropSeed) bool {
    return left.value.start > right.value.start;
}

/// Node offsets refer to the canonical (TSX) source. The canonicalizer only
/// rewrites attribute spellings inside JSX, so the statements sliced here
/// (module-level and component-body declarations) are byte-identical to the
/// authored source.
pub fn lowerPjsxStoreRegistration(allocator: Allocator, source: []const u8, filename: []const u8) Error!?StoreRegistrationOutput {
    const parsed = try analyze.parsePjsx(allocator, source, filename);
    return lowerParsedStoreRegistration(allocator, &parsed);
}

pub fn lowerParsedStoreRegistration(allocator: Allocator, parsed_ptr: *const analyze.ParsedModule) Error!?StoreRegistrationOutput {
    const a = allocator;
    const parsed = parsed_ptr.*;
    const reactive: ReactiveBinding = parsed.component.reactive orelse (try familyAsWireBinding(a, &parsed)) orelse return null;
    const finite_maps = try analyze.collectFiniteStringMaps(a, parsed.program);
    const src = parsed.canonical;
    const ctx = Ctx{ .a = a, .bindings = &parsed.component.prop_bindings, .schema = parsed.schema, .finite_maps = &finite_maps };

    var prop_fallbacks: StringList = .empty;
    for (parsed.component.prop_bindings.keys(), parsed.component.prop_bindings.values()) |binding, prop_name| {
        if (!util.isIdentifierName(binding) or reactive.hasAction(binding)) continue;
        const field = parsed.schema.get(prop_name);
        const fallback = schemaFallback(field, null);
        const code = if (fallback == .undefined) "undefined" else try fallback.toJson(a);
        try prop_fallbacks.append(a, try fmt(a, "const {s} = {s};", .{ binding, code }));
    }

    const state_start = reactive.state_statement.start;
    var state: []const u8 = src[state_start..reactive.state_statement.end];
    const prop_seeds = try a.dupe(ReactivePropSeed, try reactivePropSeeds(a, &reactive, &parsed.component.prop_bindings));
    std.mem.sort(ReactivePropSeed, prop_seeds, {}, seedStartDescending);
    for (prop_seeds) |seed| {
        const field: ?PropSchema = if (seed.prop_name) |name| parsed.schema.get(name) else null;
        const kind = try serverExpressionKind(ctx, seed.value);
        const fallback = schemaFallback(field, kind);
        const start = seed.value.start - state_start;
        const end = seed.value.end - state_start;
        state = try util.concat(a, &.{ state[0..start], if (fallback == .undefined) "undefined" else try fallback.toJson(a), state[end..] });
    }
    var local_parts: StringList = .empty;
    for (reactive.local_statements) |statement| try local_parts.append(a, src[statement.start..statement.end]);
    const locals = try util.join(a, local_parts.items, "\n");
    var action_parts: StringList = .empty;
    for (reactive.actions) |name| {
        try action_parts.append(a, if (util.containsString(reactive.argument_actions, name))
            try fmt(a, "{s}: (_dataset, context) => context?.event && {s}(...JSON.parse(decodeURIComponent(_dataset[`pArgs${{context.event.type[0].toUpperCase()}}${{context.event.type.slice(1)}}`] || \"%5B%5D\")))", .{ try jsonString(a, name), name })
        else
            try fmt(a, "{s}: (_dataset, context) => context?.event && {s}(context.event)", .{ try jsonString(a, name), name }));
    }
    const actions = try util.join(a, action_parts.items, ",\n      ");
    var ref_parts: StringList = .empty;
    for (reactive.refs) |ref| try ref_parts.append(a, try fmt(a, "{s}: {s}", .{ try jsonString(a, ref.name), ref.access }));
    const refs = try util.join(a, ref_parts.items, ",\n      ");

    var code: std.ArrayList(u8) = .empty;
    try code.appendSlice(a, try fmt(a, "Publr.createLocalStore({s}, () => {{\n", .{try jsonString(a, reactive.wire_name)}));
    if (prop_fallbacks.items.len > 0) try code.appendSlice(a, try fmt(a, "  {s}\n", .{try util.join(a, prop_fallbacks.items, "\n  ")}));
    try code.appendSlice(a, try fmt(a, "  {s}\n", .{state}));
    if (locals.len > 0) try code.appendSlice(a, try fmt(a, "  {s}\n", .{try util.replaceAll(a, locals, "\n", "\n  ")}));
    try code.appendSlice(a, "  return {\n");
    try code.appendSlice(a, "    state,\n");
    try code.appendSlice(a, try fmt(a, "    actions: {{\n      {s}\n    }},\n", .{actions}));
    if (refs.len > 0) try code.appendSlice(a, try fmt(a, "    refs: {{\n      {s}\n    }},\n", .{refs}));
    try code.appendSlice(a, "  };\n");
    try code.appendSlice(a, "});\n");

    return .{ .name = reactive.wire_name, .code = try code.toOwnedSlice(a) };
}
