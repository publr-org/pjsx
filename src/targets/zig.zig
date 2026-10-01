//! The `zig` server target: lowers PJSX component IR straight to Zig — no
//! ZSX, no runtime template engine. For every module it emits
//!
//!     pub const Props = struct { title: []const u8, … };
//!     pub fn render(w: *std.Io.Writer, arena: std.mem.Allocator, props: Props) !void
//!
//! plus, over a whole compile set (`Program`), `views.zig`, `classes.txt`
//! and `stores.js` (the client store registrations the IR carries).
//!
//! Reactivity lowers to the PublrJS wire contract: the server renders
//! `data-p-*` attributes and the client runtime hydrates them. Wires are
//! lowered from JSX state expressions; actions bind with `onX={fn}`;
//! family stores mark their root with `data-p-store` and a `data-p` seed;
//! wires cross component boundaries through the `publr_show`/`publr_bind_*`
//! transport props; `<Slot>` merges onto the caller's rendered child through
//! the runtime's `slot_props`. Anything the lowering does not understand
//! fails compilation with a message naming the module and the construct.
//!
//! Generated code imports the module named `runtime` — the library's
//! `src/runtime/server.zig`, wired by the consumer with a `class_merge`
//! implementation (see that file).
//!
//! Numbers preserve JavaScript binary64 semantics as `f64`.
//! Action props hold the bare action name
//! (`onClick: ?[]const u8`) with the event derived at the render site; a
//! component whose root cannot carry the show/text transport fails the build
//! at the call site instead of silently dropping the wire.

const std = @import("std");
const util = @import("../util.zig");
const compiler = @import("../compiler.zig");
const analyze = @import("../analyze.zig");
const err = @import("../err.zig");

const NodeIR = compiler.NodeIR;
const ExpressionIR = compiler.ExpressionIR;
const AttributeIR = compiler.AttributeIR;
const LiteralIR = compiler.LiteralIR;

pub const Error = err.Error || std.Io.Writer.Error;

/// The static type the lowering tracks for every expression it emits, so that a
/// value is escaped, printed, unwrapped or compared the right way.
const Type = union(enum) {
    string,
    opt_string,
    boolean,
    opt_boolean,
    number,
    opt_number,
    /// Pre-rendered HTML: written raw.
    node,
    opt_node,
    /// A slice of structs with these fields; a loop local over it is `item`.
    array: []const Field,
    item: []const Field,
    /// A slice of strings.
    strings,
    opt_strings,
    /// A closed string set, lowered to an enum named `name`.
    enumeration: Enumeration,
    opt_enumeration: Enumeration,
    /// `null`, as a literal.
    null,
    /// A reactive action named at compile time; `code` is its name as a Zig
    /// string literal.
    action_name,
    /// An action prop: `?[]const u8` holding an action name at runtime.
    action,
    /// A module-level finite string map, referenced but not yet keyed.
    finite_map: []const MapEntry,
    /// A finite map keyed by an enum expression; materializes as a `switch`.
    finite: Finite,
    /// A `string | [number, string]` union prop (the design system's
    /// BoxValue); lowered to a named Zig `union(enum)`.
    union_value: UnionInfo,
    /// `typeof <union>` — only meaningful compared against "string".
    union_typeof,
    /// The reactive/family state object itself — only meaningful inside the
    /// wire translator; reaching plain expression lowering is an error.
    state_root,
    /// A declared store ref (`ref={trigger}`); `code` is the raw ref name.
    ref_name,

    const Enumeration = struct {
        name: []const u8,
        values: []const []const u8,
    };

    const MapEntry = struct {
        key: []const u8,
        value: []const u8,
    };

    const Finite = struct {
        entries: []const MapEntry,
        key_code: []const u8,
        key_enum: Enumeration,
    };

    const UnionInfo = struct { name: []const u8 };

    fn is_optional(t: Type) bool {
        return switch (t) {
            .opt_string, .opt_boolean, .opt_number, .opt_node, .opt_enumeration, .opt_strings => true,
            else => false,
        };
    }

    fn unwrapped(t: Type) Type {
        return switch (t) {
            .opt_string => .string,
            .opt_boolean => .boolean,
            .opt_number => .number,
            .opt_node => .node,
            .opt_enumeration => |e| .{ .enumeration = e },
            .opt_strings => .strings,
            else => t,
        };
    }
};

const Field = struct {
    name: []const u8,
    type: Type,
    /// The Zig type as it appears in the `Props` struct.
    zig_type: []const u8,
    default: ?[]const u8,
    /// Scalar props carry a `publr_bind_<name>` wire alongside their value,
    /// so a caller's reactive binding crosses the component boundary.
    bind_transport: bool = false,
};

/// One module of the compile set, adapted from the typed IR into the shapes
/// the generator consumes.
const Module = struct {
    name: []const u8,
    /// The stem of the module's source file — imports name files, not
    /// components (`./Dropdown.ptsx` exports `DropdownMenu`).
    file_stem: []const u8,
    props: []const Field,
    /// Nested structs and enums the props need, already rendered as Zig.
    prop_types: []const u8,
    root: *const NodeIR,
    bindings: []const compiler.LocalIR,
    semantics_version: u32,
    /// Component local name → module name, from the IR's imports.
    imports: []const Import,
    classes: []const []const u8,
    /// The module's own store: `component.reactive` (component-local state)
    /// or `component.family` (module-level state shared with sibling parts).
    wire: ?Wire,
    /// Module-level finite string maps (`const SIZES = { xs: "…", … }`).
    finite_maps: []const FiniteMap,
    /// Module-level string constants (`const HATCH = "…"`), inlined where read.
    string_constants: []const Type.MapEntry = &.{},
    /// The module's client store registration, assembled into `stores.js`.
    store_registration: ?StoreRegistration,
    /// Whether the module's root can carry the show/text transport: an
    /// element root, a component-call root, or a conditional whose arms can
    /// (the `asChild` Trigger pattern). A fragment root cannot — passing a
    /// transport to such a component is a build error (the ZSX chain dropped
    /// it silently there; this backend refuses instead).
    transport_root: bool,

    const Wire = struct {
        store: []const u8,
        kind: enum { reactive, family },
        /// The exported state binding's name (`state`) for a family; a
        /// component-local `reactive()` references state as source "state".
        state_name: ?[]const u8,
        actions: []const []const u8,
        refs: []const []const u8,
        seed_exprs: []const Seed,
        initials: []const Initial,
    };
    const Seed = struct { field: []const u8, expr: *const ExpressionIR };
    const Initial = struct { field: []const u8, expr: ?*const ExpressionIR };
    const Import = struct { local: []const u8, imported: []const u8, module: []const u8 };
    const FiniteMap = struct { name: []const u8, entries: []const Type.MapEntry };
    const StoreRegistration = struct { store: []const u8, code: []const u8 };
};

/// A typed Zig expression the lowering produced.
const Lowered = struct {
    code: []const u8,
    type: Type,
};

const Local = struct {
    name: []const u8,
    type: Type,
    source_name: ?[]const u8 = null,
    /// A component-body binding's initializer, re-lowered where the binding
    /// fills a typed target (an enum prop) its string local cannot.
    binding: ?*const ExpressionIR = null,
};

const void_elements = [_][]const u8{
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
};

// ---- the public surface ----------------------------------------------------

pub const ZigOutput = struct { code: []const u8 };

/// A whole compile set: the adapted modules, sorted by name. Components
/// resolve their imports against it, so every module a view references must
/// be in the same program.
pub const Program = struct {
    modules: []const Module,

    pub fn init(arena: std.mem.Allocator, irs: []const *const compiler.ModuleIR) Error!Program {
        var modules = try arena.alloc(Module, irs.len);
        for (irs, 0..) |ir, i| {
            modules[i] = try adapt_module(arena, ir);
        }
        std.mem.sort(Module, modules, {}, module_less_than);
        return .{ .modules = modules };
    }

    /// The generated Zig for the named component.
    pub fn lower(program: Program, arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
        for (program.modules) |module| {
            if (std.mem.eql(u8, module.name, name)) {
                var gen: Generator = .init(arena, module, program.modules);
                return gen.lower_module();
            }
        }
        return err.fail("no module named {s} in the program", .{name});
    }

    /// `pub const <Name> = @import("<Name>.zig");` per module.
    pub fn viewsFile(program: Program, arena: std.mem.Allocator) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;

        try w.writeAll("//! Generated by pjsx_zig — do not edit. One namespace per PJSX module.\n");

        for (program.modules) |module| {
            try w.print("pub const {s} = @import(\"{s}.zig\");\n", .{ module.name, module.name });
        }

        return out.written();
    }

    /// Every utility class the compiler collected, sorted and deduped — the
    /// JIT's manifest.
    pub fn classesFile(program: Program, arena: std.mem.Allocator) Error![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;

        for (program.modules) |module| {
            for (module.classes) |class| {
                try all.append(arena, class);
            }
        }

        std.mem.sort([]const u8, all.items, {}, string_less_than);

        var out: std.Io.Writer.Allocating = .init(arena);
        var previous: []const u8 = "";

        for (all.items) |class| {
            if (std.mem.eql(u8, class, previous)) {
                continue;
            }
            try out.writer.print("{s}\n", .{class});
            previous = class;
        }

        return out.written();
    }

    /// The client half of every reactive module: its store registration,
    /// carried in the IR, assembled into the one module the server serves.
    /// Deduped by store name — a family's parts share their root's
    /// registration.
    pub fn storesFile(program: Program, arena: std.mem.Allocator) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;

        try w.writeAll(
            \\// Generated by pjsx_zig from the IR's store registrations — do not edit.
            \\// The client half of the reactive admin views and store families.
            \\import { Publr } from "./publr.js";
            \\
        );

        var seen: std.ArrayList([]const u8) = .empty;

        for (program.modules) |module| {
            const registration = module.store_registration orelse continue;
            const duplicate = for (seen.items) |name| {
                if (std.mem.eql(u8, name, registration.store)) break true;
            } else false;
            if (duplicate) continue;
            try seen.append(arena, registration.store);
            try w.print("\n// {s}\n{s}\n", .{ module.name, registration.code });
        }

        return out.written();
    }
};

/// One module against an explicit set — the target-plugin entry point.
pub fn lowerPjsxToZig(
    arena: std.mem.Allocator,
    module: *const compiler.ModuleIR,
    set: []const *const compiler.ModuleIR,
) Error!ZigOutput {
    var included = false;
    for (set) |candidate| {
        if (candidate == module) included = true;
    }
    const irs = if (included) set else blk: {
        const all = try arena.alloc(*const compiler.ModuleIR, set.len + 1);
        @memcpy(all[0..set.len], set);
        all[set.len] = module;
        break :blk all;
    };
    const program = try Program.init(arena, irs);
    return .{ .code = try program.lower(arena, module.component.name) };
}

fn module_less_than(_: void, a: Module, b: Module) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn string_less_than(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---- the IR, adapted --------------------------------------------------------

fn adapt_module(arena: std.mem.Allocator, ir: *const compiler.ModuleIR) Error!Module {
    if (ir.api_version != 1) {
        return err.fail("{s}: unsupported IR apiVersion {d}", .{ ir.component.name, ir.api_version });
    }
    const component = &ir.component;

    var wire: ?Module.Wire = null;

    if (component.reactive) |reactive| {
        if (reactive.refs.len != 0) {
            // Component-local refs need SSR-side ref plumbing nothing uses
            // yet; family refs (below) are the supported form.
            return err.fail("{s}: component-local refs are not lowered", .{component.name});
        }
        wire = .{
            .store = reactive.store,
            .kind = .reactive,
            .state_name = null,
            .actions = reactive.actions,
            .refs = &.{},
            .seed_exprs = &.{},
            .initials = try adapt_initials(arena, reactive.initial),
        };
    }

    if (component.family) |family| {
        var seed_exprs = try arena.alloc(Module.Seed, family.seed_exprs.len);
        for (family.seed_exprs, 0..) |seed, i| {
            seed_exprs[i] = .{ .field = seed.field, .expr = seed.value };
        }
        wire = .{
            .store = family.store,
            .kind = .family,
            .state_name = family.state,
            .actions = family.actions,
            .refs = family.refs,
            .seed_exprs = seed_exprs,
            .initials = try adapt_initials(arena, family.initial),
        };
    }

    var finite_maps: std.ArrayList(Module.FiniteMap) = .empty;
    for (ir.finite_maps.keys(), ir.finite_maps.values()) |name, entries| {
        var list = try arena.alloc(Type.MapEntry, entries.count());
        for (entries.keys(), entries.values(), 0..) |key, value, i| {
            list[i] = .{ .key = key, .value = value };
        }
        try finite_maps.append(arena, .{ .name = name, .entries = list });
    }

    var string_constants = try arena.alloc(Type.MapEntry, ir.string_constants.len);
    for (ir.string_constants, 0..) |constant, i| {
        string_constants[i] = .{ .key = constant.name, .value = constant.value };
    }

    var prop_types: std.Io.Writer.Allocating = .init(arena);
    const props = try adapt_props(arena, component.props, &prop_types.writer, component.name);

    var imports: std.ArrayList(Module.Import) = .empty;
    for (component.imports) |import| {
        for (import.names) |entry| {
            if (entry.type_only) continue;
            try imports.append(arena, .{
                .local = entry.local,
                .imported = entry.imported,
                .module = module_name_of(import.source),
            });
        }
    }

    return .{
        .name = component.name,
        .file_stem = module_name_of(ir.filename),
        .props = props,
        .prop_types = prop_types.written(),
        .root = component.root,
        .bindings = component.locals,
        .semantics_version = ir.semantics_version,
        .imports = imports.items,
        .classes = ir.classes,
        .wire = wire,
        .finite_maps = finite_maps.items,
        .string_constants = string_constants,
        .store_registration = if (component.store_registration) |registration|
            .{ .store = registration.name, .code = registration.code }
        else
            null,
        .transport_root = transports_at_root(component.root),
    };
}

fn adapt_initials(arena: std.mem.Allocator, initial: []const compiler.InitialIR) Error![]const Module.Initial {
    const out = try arena.alloc(Module.Initial, initial.len);
    for (initial, 0..) |entry, i| {
        out[i] = .{ .field = entry.field, .expr = entry.value };
    }
    return out;
}

/// See `Module.transport_root`.
fn transports_at_root(root: *const NodeIR) bool {
    return switch (root.*) {
        .element => true,
        .expression => |e| expression_transports(e.value),
        else => false,
    };
}

fn expression_transports(e: *const ExpressionIR) bool {
    return switch (e.*) {
        .node => |n| n.node.* == .element,
        .conditional => |c| expression_transports(c.consequent) and expression_transports(c.alternate),
        else => false,
    };
}

/// `./Layout.ptsx` → `Layout`: imports are resolved by the module's name, which
/// is the file stem by PJSX convention.
fn module_name_of(source: []const u8) []const u8 {
    if (std.mem.startsWith(u8, source, "publr/")) return source;
    const slash = std.mem.lastIndexOfScalar(u8, source, '/');
    const stem_start = if (slash) |index| index + 1 else 0;
    const dot = std.mem.indexOfScalarPos(u8, source, stem_start, '.') orelse source.len;

    return source[stem_start..dot];
}

/// The prop schema as typed fields, writing the nested struct and enum
/// declarations to `types` as it goes.
fn adapt_props(
    arena: std.mem.Allocator,
    schema: *const analyze.Schema,
    types: *std.Io.Writer,
    where: []const u8,
) Error![]const Field {
    var fields: std.ArrayList(Field) = .empty;

    for (schema.keys(), schema.values()) |name, spec| {
        // An internal element prop (`root` with `tagFrom`) is the component's
        // own business — its body picks the tag; callers never set it.
        if (spec.type == .element and spec.internal) {
            continue;
        }

        const empty_array_default = if (spec.default_expression) |expression|
            expression.type == .ArrayExpression and expression.elements.len == 0
        else
            false;
        if (spec.default_expression != null and spec.default == null and !empty_array_default) {
            return err.fail("{s}.{s}: this default expression cannot yet be lowered to Zig", .{ where, name });
        }
        if (spec.nullable and spec.type != .node) {
            return err.fail("{s}.{s}: this nullable prop cannot yet be represented faithfully by the Zig target", .{ where, name });
        }
        var prop_type: Type = undefined;
        var zig_type: ?[]const u8 = null;
        var default_code: ?[]const u8 = null;

        const enumerable = spec.type == .string or spec.type == .element;

        if (enumerable and spec.values != null) {
            const enum_name = if (std.mem.lastIndexOfScalar(u8, where, '.')) |dot|
                try std.fmt.allocPrint(arena, "{s}{s}", .{ try capitalize(arena, where[dot + 1 ..]), try capitalize(arena, name) })
            else
                try capitalize(arena, name);
            var tags: std.ArrayList([]const u8) = .empty;

            try types.print("pub const {s} = enum {{", .{enum_name});

            for (spec.values.?) |value| {
                const tag = value.asString() orelse return err.fail("{s}.{s}: non-string enum value", .{ where, name });
                try tags.append(arena, tag);
                try types.print(" @\"{s}\",", .{tag});
            }

            try types.writeAll(" };\n");

            const enumeration: Type.Enumeration = .{ .name = enum_name, .values = tags.items };
            // A default outside the value set (Input's `inputMode: ""`) means
            // "no value": the prop is optional and the attribute is omitted.
            const default_string: ?[]const u8 = if (spec.default) |d| d.asString() else null;
            const listed_default: ?[]const u8 = if (default_string) |d| blk: {
                for (tags.items) |tag| {
                    if (std.mem.eql(u8, tag, d)) break :blk d;
                }
                break :blk null;
            } else null;

            if ((spec.default != null and listed_default == null) or (spec.typescript != null and spec.optional and spec.default == null)) {
                prop_type = .{ .opt_enumeration = enumeration };
                zig_type = try std.fmt.allocPrint(arena, "?{s}", .{enum_name});
                default_code = "null";
            } else {
                prop_type = .{ .enumeration = enumeration };
                zig_type = enum_name;
                if (listed_default) |d| {
                    default_code = try std.fmt.allocPrint(arena, ".@\"{s}\"", .{d});
                }
            }
        } else switch (spec.type) {
            .element => return err.fail("{s}.{s}: an element prop needs values", .{ where, name }),
            .string => {
                // An optional string with a schema default is never absent: the
                // default fills it (`classes: ""` → `classes: []const u8 = ""`).
                if (spec.optional and spec.default == null) {
                    prop_type = .opt_string;
                    default_code = "null";
                } else {
                    prop_type = .string;
                    if (spec.default) |d| {
                        const text = d.asString() orelse return err.fail("{s}.{s}: non-string default", .{ where, name });
                        default_code = try zig_string(arena, text);
                    }
                }
            },
            .optional_string => {
                prop_type = .opt_string;
                default_code = "null";
            },
            .boolean => {
                prop_type = if (spec.typescript != null and spec.optional and spec.default == null) .opt_boolean else .boolean;
                default_code = if (spec.default) |d| switch (d) {
                    .boolean => |b| if (b) "true" else "false",
                    else => return err.fail("{s}.{s}: non-boolean default", .{ where, name }),
                } else if (spec.typescript == null) "false" else if (spec.optional) "null" else null;
            },
            .optional_boolean => {
                prop_type = .opt_boolean;
                default_code = "null";
            },
            .number => {
                prop_type = if (spec.optional and spec.default == null) .opt_number else .number;
                if (spec.optional and spec.default == null) default_code = "null";
                if (spec.default) |d| {
                    default_code = try zig_number_literal(arena, d, where, name);
                }
            },
            .optional_number => {
                prop_type = .opt_number;
                default_code = "null";
            },
            .node, .children => {
                prop_type = if (spec.optional) .opt_node else .node;
                if (spec.optional) default_code = "null";
            },
            .@"union" => {
                // The one union shape the design system uses: string | [number, string].
                const variants = spec.variants orelse return err.fail("{s}.{s}: union without variants", .{ where, name });
                const supported = variants.len == 2 and
                    std.mem.eql(u8, variants[0], "string") and
                    std.mem.eql(u8, variants[1], "number-string-tuple");
                if (!supported) return err.fail("{s}.{s}: only string|number-string-tuple unions are lowered", .{ where, name });

                const union_name = try capitalize(arena, name);
                try types.print(
                    "pub const {s} = union(enum) {{ string: []const u8, number_string_tuple: struct {{ f64, []const u8 }} }};\n",
                    .{union_name},
                );
                prop_type = .{ .union_value = .{ .name = union_name } };
                zig_type = union_name;
            },
            .action => {
                prop_type = .action;
                if (spec.optional or spec.typescript == null) default_code = "null";
            },
            .style => {
                // String styles only; object styles are not lowered.
                prop_type = .opt_string;
                if (spec.optional or spec.typescript == null) default_code = "null";
            },
            .array => {
                if (empty_array_default) default_code = "&.{}";
                if (spec.fields) |nested| {
                    const struct_name = try std.fmt.allocPrint(arena, "{s}Item", .{try capitalize(arena, name)});
                    var nested_types: std.Io.Writer.Allocating = .init(arena);
                    const item_fields = try adapt_props(arena, nested, &nested_types.writer, try std.fmt.allocPrint(arena, "{s}.{s}", .{ where, name }));

                    try types.writeAll(nested_types.written());
                    try types.print("pub const {s} = struct {{\n", .{struct_name});
                    try write_fields(types, item_fields);
                    try types.writeAll("};\n");

                    prop_type = .{ .array = item_fields };
                    zig_type = try std.fmt.allocPrint(arena, "[]const {s}", .{struct_name});
                } else if (spec.items) |items| {
                    if (items != .string) {
                        return err.fail("{s}.{s}: only string array items are lowered", .{ where, name });
                    }
                    prop_type = if (spec.optional and !empty_array_default) .opt_strings else .strings;
                    if (spec.optional and !empty_array_default) default_code = "null";
                } else {
                    return err.fail("{s}.{s}: an array prop needs fields or items", .{ where, name });
                }
            },
            else => return err.fail("{s}.{s}: prop type \"{s}\" is not lowered", .{ where, name, spec.type.name() }),
        }

        try fields.append(arena, .{
            .name = name,
            .type = prop_type,
            .zig_type = zig_type orelse type_code(prop_type),
            .default = default_code,
            .bind_transport = switch (prop_type) {
                .string, .opt_string, .boolean, .opt_boolean, .number, .opt_number, .enumeration, .opt_enumeration => true,
                else => false,
            },
        });
    }

    return fields.items;
}

/// TypeScript numbers retain their fractional value in the Zig f64 representation.
fn zig_number_literal(arena: std.mem.Allocator, value: analyze.Primitive, where: []const u8, name: []const u8) Error![]const u8 {
    switch (value) {
        .number => |n| {
            if (std.math.isNan(n)) return arena.dupe(u8, "std.math.nan(f64)");
            if (std.math.isInf(n)) return arena.dupe(u8, if (n > 0) "std.math.inf(f64)" else "(-std.math.inf(f64))");
            if (n == 0 and std.math.signbit(n)) return arena.dupe(u8, "-0.0");
            return std.fmt.allocPrint(arena, "{d}", .{n});
        },
        else => return err.fail("{s}.{s}: non-number default", .{ where, name }),
    }
}

fn write_fields(w: *std.Io.Writer, fields: []const Field) !void {
    for (fields) |f| {
        try w.print("    {f}: {s}", .{ std.zig.fmtId(f.name), f.zig_type });
        if (f.default) |d| {
            try w.print(" = {s}", .{d});
        }
        try w.writeAll(",\n");
    }
}

fn type_code(t: Type) []const u8 {
    return switch (t) {
        .string => "[]const u8",
        .opt_string => "?[]const u8",
        .boolean => "bool",
        .opt_boolean => "?bool",
        .number => "f64",
        .opt_number => "?f64",
        .node => "rt.Node",
        .opt_node => "?rt.Node",
        .strings => "[]const []const u8",
        .opt_strings => "?[]const []const u8",
        .action => "?[]const u8",
        .array, .item, .enumeration, .opt_enumeration, .null, .action_name, .finite_map, .finite, .state_root, .ref_name, .union_value, .union_typeof => unreachable,
    };
}

fn capitalize(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, name);
    if (out.len > 0) {
        out[0] = std.ascii.toUpper(out[0]);
    }
    return out;
}

/// `text` as a Zig string literal, quotes included.
fn zig_string(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    try w.writeByte('"');

    for (text) |char| {
        switch (char) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (char < 0x20 or char == 0x7f) {
                try w.print("\\x{x:0>2}", .{char});
            } else {
                try w.writeByte(char);
            },
        }
    }

    try w.writeByte('"');

    return out.written();
}

// ---- the lowering ----------------------------------------------------------

const ElementIR = @FieldType(NodeIR, "element");
const PlainAttrIR = @FieldType(AttributeIR, "attribute");

const Generator = struct {
    arena: std.mem.Allocator,
    module: Module,
    modules: []const Module,
    /// The function body, emitted statement by statement.
    body: std.Io.Writer.Allocating,
    /// The block structs behind `rt.block` nodes, one per component call with
    /// children, emitted after `render` at file scope so their parameters and
    /// aliases shadow nothing.
    blocks: std.Io.Writer.Allocating,
    /// Static HTML accumulated since the last dynamic statement; flushed as one
    /// `writeAll` before the next one.
    pending: std.ArrayList(u8),
    /// The writer variable the current statements write to: `w` at the top,
    /// a buffer's writer inside a component's children.
    writer_name: []const u8,
    locals: std.ArrayList(Local),
    present_values: std.ArrayList([]const u8) = .empty,
    wire_aliases: std.ArrayList([]const u8) = .empty,
    template_depth: u32 = 0,
    seeded_depth: u32 = 0,
    templates: std.ArrayList(struct { expression: *const ExpressionIR, name: []const u8 }) = .empty,
    /// The item structs and enums of asserted array literals (`[] as Row[]`),
    /// declared at file scope once per literal.
    asserted_types: std.ArrayList(u8) = .empty,
    asserted_arrays: std.ArrayList(struct { expression: *const ExpressionIR, lowered: Lowered }) = .empty,
    /// `a && b && <jsx/>` regrouped as `a && (b && <jsx/>)`, once per
    /// expression, so each guard is its own branch with a stable template id.
    split_guards: std.ArrayList(struct { expression: *const ExpressionIR, split: *const ExpressionIR }) = .empty,
    /// The expression whose static fallback is being lowered inside its own
    /// prop-wire branch, so it is not wired again there.
    prop_wire_skip: ?*const ExpressionIR = null,
    /// Names for prop-wire temporaries, counted apart so the plain lowering's
    /// names do not depend on them.
    prop_counter: u32 = 0,
    imports_used: std.ArrayList([]const u8),
    indent: u32,
    counter: u32,
    arena_used: bool,
    props_used: bool,
    /// A sibling family this module binds to through its imports
    /// (`import { state, toggle } from "./Dialog.ptsx"`): part modules wire
    /// to the family's store through DOM ancestry, so their bindings are
    /// *foreign* — wires without SSR initial values.
    foreign: ?Foreign,
    /// Set while the module's root element is being opened, so it can carry
    /// the `data-p-store` attribute and the `data-p` seed.
    root_store: ?[]const u8,
    root_seeds: []const Module.Seed,
    /// True while the module's root node renders: the root element (or each
    /// arm of a conditional root) receives the show/text transport plumbing.
    at_root: bool,

    const Foreign = struct {
        module_name: []const u8,
        state_local: ?[]const u8,
        actions: []const NamePair,
        refs: []const NamePair,
    };
    const NamePair = struct { local: []const u8, name: []const u8 };

    fn init(arena: std.mem.Allocator, module: Module, modules: []const Module) Generator {
        return .{
            .arena = arena,
            .module = module,
            .modules = modules,
            .body = .init(arena),
            .blocks = .init(arena),
            .pending = .empty,
            .writer_name = "w",
            .locals = .empty,
            .imports_used = .empty,
            .indent = 1,
            .counter = 0,
            .arena_used = false,
            .props_used = false,
            .foreign = null,
            .root_store = null,
            .root_seeds = &.{},
            .at_root = false,
        };
    }

    fn fail(gen: *Generator, comptime fmt: []const u8, args: anytype) Error {
        return err.fail("{s}: " ++ fmt, .{gen.module.name} ++ args);
    }

    /// Classifies every import from a sibling family module against that
    /// family's exported state/action/ref names.
    fn resolve_foreign(gen: *Generator) Error!void {
        var state_local: ?[]const u8 = null;
        var actions: std.ArrayList(NamePair) = .empty;
        var refs: std.ArrayList(NamePair) = .empty;
        var family_module: ?[]const u8 = null;

        for (gen.module.imports) |import| {
            const target = for (gen.modules) |candidate| {
                if (std.mem.eql(u8, candidate.file_stem, import.module) or
                    std.mem.eql(u8, candidate.name, import.module)) break candidate;
            } else continue;
            const wire = target.wire orelse continue;
            if (wire.kind != .family) continue;

            const is_state = if (wire.state_name) |state| std.mem.eql(u8, import.imported, state) else false;
            const is_action = for (wire.actions) |action| {
                if (std.mem.eql(u8, import.imported, action)) break true;
            } else false;
            const is_ref = for (wire.refs) |ref| {
                if (std.mem.eql(u8, import.imported, ref)) break true;
            } else false;

            if (!is_state and !is_action and !is_ref) continue;

            if (family_module) |known| {
                if (!std.mem.eql(u8, known, import.module)) {
                    return gen.fail("two family stores are imported ({s} and {s}); one is lowered", .{ known, import.module });
                }
            } else {
                family_module = import.module;
            }

            if (is_state) state_local = import.local;
            if (is_action) try actions.append(gen.arena, .{ .local = import.local, .name = import.imported });
            if (is_ref) try refs.append(gen.arena, .{ .local = import.local, .name = import.imported });
        }

        if (family_module) |name| {
            gen.foreign = .{
                .module_name = name,
                .state_local = state_local,
                .actions = actions.items,
                .refs = refs.items,
            };
        }
    }

    fn lower_module(gen: *Generator) Error![]const u8 {
        try gen.resolve_foreign();

        // A module that owns a store marks its root element as the island:
        // `data-p-store` (and the seed) belong on it. A component-call or
        // conditional root leaves the store to authored markup (a view may
        // place `data-p-store` by hand inside its layout).
        if (gen.module.wire) |wire| {
            const intrinsic_root = switch (gen.module.root.*) {
                .element => |element_ir| element_ir.name == .intrinsic,
                else => false,
            };
            if (intrinsic_root) {
                gen.root_store = wire.store;
                gen.root_seeds = wire.seed_exprs;
            } else if (wire.kind == .family) {
                return gen.fail("a family root must be an intrinsic element to carry its store", .{});
            }
        }

        for (gen.module.bindings) |binding| {
            // Event callbacks execute in the client companion, not during SSR.
            if (binding.value.* == .function) continue;
            const value = try gen.expression(binding.value);
            const name = try gen.fresh("local");
            try gen.line("const {s} = {s};", .{ name, value.code });
            try gen.line("_ = &{s};", .{name});
            try gen.locals.append(gen.arena, .{ .name = name, .source_name = binding.name, .type = value.type, .binding = binding.value });
        }
        gen.at_root = true;
        try gen.node(gen.module.root);
        gen.at_root = false;
        try gen.flush();

        var out: std.Io.Writer.Allocating = .init(gen.arena);
        const w = &out.writer;

        try w.print("//! Generated by pjsx_zig from {s}.ptsx — do not edit.\n", .{gen.module.name});
        try w.writeAll("const std = @import(\"std\");\nconst rt = @import(\"runtime\");\n");

        for (gen.imports_used.items) |name| {
            try w.print("const {s} = @import(\"{s}.zig\");\n", .{ name, name });
        }

        try w.writeAll("\n");
        try w.writeAll(gen.module.prop_types);
        try w.writeAll(gen.asserted_types.items);
        try w.writeAll("pub const Props = struct {\n");
        try write_fields(w, gen.module.props);
        try w.writeAll(
            \\    // The PublrJS transport: wires a caller hands across the
            \\    // component boundary, landing on this component's root.
            \\    publr_show: ?bool = null,
            \\    publr_show_wire: ?[]const u8 = null,
            \\    publr_text_wire: ?[]const u8 = null,
            \\
        );
        for (gen.module.props) |prop| {
            if (prop.bind_transport) {
                try w.print("    publr_bind_{s}: ?[]const u8 = null,\n", .{prop.name});
            }
        }
        try w.writeAll("};\n\n");
        try w.writeAll("pub fn render(w: *std.Io.Writer, arena: std.mem.Allocator, props: Props) !void {\n    @setFloatMode(.strict);\n");

        if (!gen.arena_used) {
            try w.writeAll("    _ = arena;\n");
        }
        if (!gen.props_used) {
            try w.writeAll("    _ = props;\n");
        }

        try w.writeAll(gen.body.written());
        try w.writeAll("}\n");
        try w.writeAll(gen.blocks.written());

        return out.written();
    }

    // -- statements --

    fn line(gen: *Generator, comptime fmt: []const u8, args: anytype) Error!void {
        try gen.flush();
        try gen.raw_line(fmt, args);
    }

    fn raw_line(gen: *Generator, comptime fmt: []const u8, args: anytype) Error!void {
        var level: u32 = 0;
        while (level < gen.indent) : (level += 1) {
            try gen.body.writer.writeAll("    ");
        }
        try gen.body.writer.print(fmt, args);
        try gen.body.writer.writeByte('\n');
    }

    fn static(gen: *Generator, text: []const u8) Error!void {
        try gen.pending.appendSlice(gen.arena, text);
    }

    fn flush(gen: *Generator) Error!void {
        if (gen.pending.items.len == 0) {
            return;
        }
        const literal = try zig_string(gen.arena, gen.pending.items);
        gen.pending.clearRetainingCapacity();
        try gen.raw_line("try {s}.writeAll({s});", .{ gen.writer_name, literal });
    }

    fn fresh_prop(gen: *Generator, comptime prefix: []const u8) Error![]const u8 {
        gen.prop_counter += 1;
        return std.fmt.allocPrint(gen.arena, prefix ++ "_w{d}", .{gen.prop_counter});
    }

    fn fresh(gen: *Generator, comptime prefix: []const u8) Error![]const u8 {
        gen.counter += 1;
        return std.fmt.allocPrint(gen.arena, prefix ++ "_{d}", .{gen.counter});
    }

    // -- nodes --

    fn node(gen: *Generator, n: *const NodeIR) Error!void {
        switch (n.*) {
            .text => |text| try gen.static_escaped(text.value, false),
            .fragment => |fragment| try gen.children(fragment.children),
            .expression => |expression_node| try gen.child_expression(expression_node.value),
            .element => |*element_ir| switch (element_ir.name) {
                .intrinsic => |intrinsic| try gen.element(intrinsic.name, element_ir),
                .component => |component_name| try gen.component(component_name.name, element_ir),
                .member => return gen.fail("member element names are not lowered", .{}),
            },
        }
    }

    fn children(gen: *Generator, list: []const *const NodeIR) Error!void {
        for (list) |child| {
            try gen.node(child);
        }
    }

    fn element(gen: *Generator, tag: []const u8, n: *const ElementIR) Error!void {
        try gen.element_body(.{ .static = tag }, n, null);
    }

    /// The tag of an element being emitted: known at compile time, or a bound
    /// Zig expression (a `<Dynamic>` whose `as` is computed).
    const TagRef = union(enum) {
        static: []const u8,
        runtime: []const u8,
    };

    const Event = struct {
        /// `click`, `keydown.enter.prevent` — the event name with its modifiers.
        descriptor: []const u8,
        action: ActionRef,

        const ActionRef = union(enum) {
            /// An action named at compile time.
            static: []const u8,
            /// An action prop: Zig code of type `?[]const u8`.
            runtime: []const u8,
        };
    };

    const Binding = struct { name: []const u8, wire: []const u8 };
    const SsrAttr = struct { name: []const u8, lowered: Lowered };

    const OwnInitial = union(enum) { lowered: Lowered, unservable };

    /// The seed expression behind an own-state wire (`state.value` on the
    /// family root, where `state.value = value ?? defaultValue` seeds it):
    /// the SSR initial the attribute renders while the wire hydrates.
    fn seed_lowered(gen: *Generator, e: *const ExpressionIR) Error!?Lowered {
        const wire = gen.module.wire orelse return null;
        const path = gen.wire_state_path(e) orelse return null;
        if (std.mem.indexOfScalar(u8, path.spec, '.') != null) return null;
        for (wire.seed_exprs) |seed| {
            if (std.mem.eql(u8, seed.field, path.spec)) {
                return try gen.expression(seed.expr);
            }
        }
        return null;
    }

    /// The SSR value behind an own-state wire: the seed expression when the
    /// field is seeded, the initial-state value otherwise; `.unservable` for
    /// getters and other fields the IR could not carry (the wire then
    /// hydrates without an SSR value, exactly as a foreign binding does).
    fn own_initial(gen: *Generator, e: *const ExpressionIR) Error!?OwnInitial {
        if (e.* == .member and e.member.property == .string and std.mem.eql(u8, e.member.property.string, "length")) {
            if (try gen.own_initial(e.member.object)) |initial| {
                if (initial == .lowered and (initial.lowered.type == .array or initial.lowered.type == .strings)) {
                    return .{ .lowered = .{ .code = try std.fmt.allocPrint(gen.arena, "@as(f64, @floatFromInt({s}.len))", .{initial.lowered.code}), .type = .number } };
                }
            }
        }
        if (gen.wire_state_path(e)) |path| {
            for (gen.wire_aliases.items) |alias| {
                if (!path.own or !std.mem.startsWith(u8, path.spec, alias)) continue;
                if (path.spec.len == alias.len or path.spec[alias.len] == '.') {
                    return .{ .lowered = try gen.expression(e) };
                }
            }
        }
        // A template over own state: its parts' initials, formatted.
        if (e.* == .template and try gen.wire_spec(e) != null) {
            return if (try gen.template_with(e, true)) |lowered| .{ .lowered = lowered } else .unservable;
        }
        if (e.* == .conditional) {
            if (try gen.own_initial(e.conditional.@"test")) |test_value| {
                if (test_value == .unservable) return .unservable;
                return .{ .lowered = try gen.select(try gen.truthy(test_value.lowered), try gen.expression(e.conditional.consequent), try gen.expression(e.conditional.alternate)) };
            }
        }
        // `!state.x` inverts its field's initial.
        if (e.* == .unary and std.mem.eql(u8, e.unary.operator, "!")) {
            const inner = (try gen.own_initial(e.unary.argument)) orelse return null;
            return switch (inner) {
                .unservable => .unservable,
                .lowered => |lowered| .{ .lowered = .{
                    .code = try std.fmt.allocPrint(gen.arena, "!{s}", .{try gen.truthy(lowered)}),
                    .type = .boolean,
                } },
            };
        }

        if (e.* == .operation) {
            const left_initial = try gen.own_initial(e.operation.left);
            const right_initial = try gen.own_initial(e.operation.right);
            if (left_initial != null or right_initial != null) {
                if ((left_initial != null and left_initial.? == .unservable) or (right_initial != null and right_initial.? == .unservable)) return .unservable;
                const left = if (left_initial) |initial| initial.lowered else try gen.expression(e.operation.left);
                const right = if (right_initial) |initial| initial.lowered else try gen.expression(e.operation.right);
                return .{ .lowered = try gen.operation_values(e, left, right) };
            }
        }
        if (try gen.seed_lowered(e)) |lowered| {
            return .{ .lowered = lowered };
        }
        const wire = gen.module.wire orelse return null;
        const path = gen.wire_state_path(e) orelse return null;
        if (std.mem.indexOfScalar(u8, path.spec, '.') != null) return null;
        for (wire.initials) |initial| {
            if (!std.mem.eql(u8, initial.field, path.spec)) continue;
            const expr = initial.expr orelse return .unservable;
            return .{ .lowered = try gen.expression(expr) };
        }
        return null;
    }

    /// Renders an SSR attribute from an already-lowered value: booleans as
    /// presence (`aria-*` as `"true"/"false"`), optionals only when present.
    fn ssr_attribute(gen: *Generator, raw_name: []const u8, lowered: Lowered) Error!void {
        const name = if (std.mem.eql(u8, raw_name, "focusScope")) "data-p-focus" else raw_name;
        const aria_boolean = lowered.type.unwrapped() == .boolean and std.mem.startsWith(u8, name, "aria-");

        switch (lowered.type.unwrapped()) {
            .boolean => if (aria_boolean) {
                try gen.static(" ");
                try gen.static(name);
                try gen.static("=\"");
                try gen.write_value(.{ .code = try gen.truthy(lowered), .type = .boolean });
                try gen.static("\"");
            } else {
                try gen.line("if ({s}) try {s}.writeAll(\" {s}\");", .{
                    try gen.truthy(lowered),
                    gen.writer_name,
                    name,
                });
            },
            .string, .number, .enumeration => {
                if (lowered.type.is_optional()) {
                    const binding = try gen.fresh("value");
                    try gen.line("if ({s}) |{s}| {{", .{ lowered.code, binding });
                    gen.indent += 1;
                    try gen.static(" ");
                    try gen.static(name);
                    try gen.static("=\"");
                    try gen.write_value(.{ .code = binding, .type = lowered.type.unwrapped() });
                    try gen.static("\"");
                    try gen.flush();
                    gen.indent -= 1;
                    try gen.line("}}", .{});
                } else {
                    try gen.static(" ");
                    try gen.static(name);
                    try gen.static("=\"");
                    try gen.write_value(lowered);
                    try gen.static("\"");
                }
            },
            else => return gen.fail("an SSR attribute \"{s}\" of type {s} is not lowered", .{ name, @tagName(lowered.type) }),
        }
    }

    fn element_body(gen: *Generator, tag: TagRef, n: *const ElementIR, skip: ?[]const u8) Error!void {
        var html_ssr: ?Lowered = null;
        var class_attrs: std.ArrayList(PlainAttrIR) = .empty;
        var events: std.ArrayList(Event) = .empty;
        var bindings: std.ArrayList(Binding) = .empty;
        var behavior_classes: std.ArrayList([]const u8) = .empty;
        var show_wire: ?[]const u8 = null;
        var text_wire: ?[]const u8 = null;
        var plain: std.ArrayList(PlainAttrIR) = .empty;
        var directives: std.ArrayList([]const u8) = .empty;
        var paired: std.ArrayList(PlainAttrIR) = .empty;
        var own_ssr: std.ArrayList(SsrAttr) = .empty;

        const attrs = n.attributes;

        for (attrs) |a| {
            switch (a) {
                .event => |ev| try events.append(gen.arena, try gen.event_of(ev)),
                .behavior => |behavior| {
                    const wire = try gen.wire_text(behavior.form, behavior.value);

                    if (std.mem.eql(u8, behavior.name, "show")) {
                        if (show_wire != null) return gen.fail("an element carries two `:show` wires", .{});
                        show_wire = wire;
                    } else if (std.mem.eql(u8, behavior.name, "text")) {
                        if (text_wire != null) return gen.fail("an element carries two `:text` wires", .{});
                        text_wire = wire;
                    } else if (std.mem.eql(u8, behavior.name, "class")) {
                        try behavior_classes.append(gen.arena, wire);
                    } else {
                        return gen.fail("behavior \"{s}\" is not lowered", .{behavior.name});
                    }
                },
                .binding => |binding| {
                    const wire = if (binding.form == .expression and binding.value.* != .literal)
                        (try gen.wire_spec(binding.value) orelse return gen.fail("binding {s} has no reactive source", .{binding.name})).spec
                    else
                        try gen.wire_text(binding.form, binding.value);
                    try bindings.append(gen.arena, .{ .name = binding.name, .wire = wire });
                },
                .attribute => |plain_attr| {
                    const name = plain_attr.name;
                    if (std.mem.eql(u8, name, "key")) continue;
                    const form = plain_attr.form;
                    const value = plain_attr.value;

                    if (skip) |skipped| {
                        if (std.mem.eql(u8, name, skipped)) continue;
                    }

                    if (std.mem.eql(u8, name, "innerHTML")) {
                        if (form == .expression) {
                            if (try gen.wire_spec(value)) |wired| {
                                try bindings.append(gen.arena, .{ .name = name, .wire = wired.spec });
                                if (wired.own) {
                                    if (try gen.own_initial(value)) |initial| {
                                        if (initial == .lowered and initial.lowered.type != .null) html_ssr = initial.lowered;
                                    }
                                }
                                continue;
                            }
                        }
                        const initial = try gen.expression(value);
                        if (initial.type != .null) html_ssr = initial;
                        continue;
                    }

                    if (std.mem.eql(u8, name, "class")) {
                        try class_attrs.append(gen.arena, plain_attr);
                        continue;
                    }
                    if (is_action_attribute(name)) {
                        try events.append(gen.arena, try gen.event_of_attribute(name, plain_attr));
                        continue;
                    }

                    // The universal directive spellings: `ref={x}` names a store
                    // ref, bare `portal`/`anchor` mark the element, `position`
                    // carries an alignment.
                    if (std.mem.eql(u8, name, "ref") and form == .expression) {
                        const lowered = try gen.expression(value);
                        if (lowered.type != .ref_name) {
                            return gen.fail("`ref` must name a declared store ref, got a {s}", .{@tagName(lowered.type)});
                        }
                        try directives.append(gen.arena, try std.fmt.allocPrint(gen.arena, " data-p-ref=\"{s}\"", .{lowered.code}));
                        continue;
                    }
                    if ((std.mem.eql(u8, name, "portal") or std.mem.eql(u8, name, "anchor")) and form == .bare) {
                        try directives.append(gen.arena, try std.fmt.allocPrint(gen.arena, " data-p-{s}", .{name}));
                        continue;
                    }
                    if (std.mem.eql(u8, name, "position")) {
                        try plain.append(gen.arena, plain_attr); // renamed to data-p-position at emission
                        continue;
                    }

                    // A style object with literal values is a static style text
                    // (camelCase keys kebab-cased, `--custom` kept).
                    if (std.mem.eql(u8, name, "style") and form == .expression and value.* == .object) {
                        try gen.static(" style=\"");
                        try gen.static_style_object(value);
                        try gen.static("\"");
                        continue;
                    }

                    // Two attributes with one name are the SSR + wire pair.
                    if (count_attribute(attrs, name) > 1) {
                        try paired.append(gen.arena, plain_attr);
                        continue;
                    }

                    // A single expression over reactive state is a wire. A
                    // foreign (part-of-family) binding gets no SSR value; the
                    // family root's own seeded fields render their seed
                    // expression as the SSR value, wire alongside.
                    if (form == .expression) {
                        if (try gen.wire_spec(value)) |wired| {
                            if (wired.own) {
                                const state = (try gen.own_initial(value)) orelse {
                                    return gen.fail("no SSR value for this module's own state behind \"{s}\"", .{name});
                                };
                                switch (state) {
                                    .lowered => |initial| if (std.mem.eql(u8, name, "hidden")) {
                                        if (show_wire != null) return gen.fail("an element carries two `:show` wires", .{});
                                        // hidden={state.x}: present when the initial is truthy.
                                        // Through `own_ssr` like every other SSR
                                        // value — writing it here would put it
                                        // wherever the generator's cursor happens
                                        // to be, which is outside the open tag
                                        // whenever the initial folds to a constant.
                                        // `ssr_attribute` renders a boolean as the
                                        // bare attribute already.
                                        try own_ssr.append(gen.arena, .{ .name = name, .lowered = initial });
                                        show_wire = try gen.invert_wire(wired.spec);
                                    } else {
                                        try own_ssr.append(gen.arena, .{ .name = name, .lowered = initial });
                                        try bindings.append(gen.arena, .{ .name = name, .wire = wired.spec });
                                    },
                                    .unservable => if (std.mem.eql(u8, name, "hidden")) {
                                        if (show_wire != null) return gen.fail("an element carries two `:show` wires", .{});
                                        show_wire = try gen.invert_wire(wired.spec);
                                    } else {
                                        try bindings.append(gen.arena, .{ .name = name, .wire = wired.spec });
                                    },
                                }
                                continue;
                            }
                            if (std.mem.eql(u8, name, "hidden")) {
                                if (show_wire != null) return gen.fail("an element carries two `:show` wires", .{});
                                show_wire = try gen.invert_wire(wired.spec);
                            } else {
                                try bindings.append(gen.arena, .{ .name = name, .wire = wired.spec });
                            }
                            continue;
                        }
                    }

                    try plain.append(gen.arena, plain_attr);
                },
            }
        }

        // SSR + wire pairs: the static member renders, the wired member joins
        // the bindings (`hidden` pairs with `data-p-show`, inverted).
        var pair_index: usize = 0;
        while (pair_index < paired.items.len) {
            const name = paired.items[pair_index].name;
            var static_member: ?PlainAttrIR = null;
            var wired_member: ?[]const u8 = null;
            var group_size: usize = 0;

            for (paired.items[pair_index..]) |member| {
                if (!std.mem.eql(u8, member.name, name)) break;
                group_size += 1;
                if (member.form == .expression) {
                    if (try gen.wire_spec(member.value)) |wired| {
                        // The pair's static member is the SSR value, so an
                        // own-state wire needs nothing more here.
                        if (wired_member != null) return gen.fail("\"{s}\" pairs two wires", .{name});
                        wired_member = wired.spec;
                        continue;
                    }
                }
                if (static_member != null) return gen.fail("\"{s}\" appears twice without a wire", .{name});
                static_member = member;
            }
            pair_index += group_size;

            const static_attr = static_member orelse return gen.fail("\"{s}\" pairs a wire with no static value", .{name});
            const wire = wired_member orelse return gen.fail("\"{s}\" appears twice without a wire", .{name});

            try plain.append(gen.arena, static_attr);
            if (std.mem.eql(u8, name, "hidden")) {
                if (show_wire != null) return gen.fail("an element carries two `:show` wires", .{});
                show_wire = try gen.invert_wire(wire);
            } else {
                try bindings.append(gen.arena, .{ .name = name, .wire = wire });
            }
        }

        // A sole child expression over state is a text wire: the element
        // gets `data-p-text` and renders its seeded SSR value (or nothing,
        // for a foreign binding) until hydration replaces it.
        var skip_children = false;
        var text_ssr: ?Lowered = null;
        // A sole child derived from wired props: the element carries the text
        // wire itself (a raw-text element cannot hold a span).
        var text_prop_wire: ?[]const u8 = null;
        var sole_child: ?*const ExpressionIR = null;
        if (n.children.len == 1 and n.children[0].* == .expression) {
            const only = n.children[0].expression.value;
            if (text_wire == null and !contains_jsx(only) and try gen.wire_spec(only) == null) {
                if (try gen.prop_wire(only, .value)) |wire| {
                    text_prop_wire = wire;
                    sole_child = only;
                }
            }
            if (try gen.wire_spec(only)) |wired| {
                if (text_wire != null) return gen.fail("an element carries two `:text` wires", .{});
                text_wire = wired.spec;
                skip_children = true;
                if (wired.own) {
                    if (try gen.own_initial(only)) |state| {
                        if (state == .lowered) text_ssr = state.lowered;
                    }
                }
            }
        }

        // Class layers that are ternaries over state become `data-p-class`
        // wire groups; the rest stay in the merge stack.
        var retained_classes: std.ArrayList(PlainAttrIR) = .empty;
        for (class_attrs.items) |a| {
            if (a.form == .expression) {
                if (try gen.class_wire_group(a.value)) |group| {
                    try behavior_classes.append(gen.arena, group.spec);
                    if (!group.own) continue;
                }
            }
            try retained_classes.append(gen.arena, a);
        }
        class_attrs = retained_classes;

        // Class layers derived from wired props: a group per layer, composed
        // at render time.
        var prop_classes: std.ArrayList([]const u8) = .empty;
        for (class_attrs.items) |a| {
            if (a.form != .expression) continue;
            if (try gen.prop_wire(a.value, .classes)) |wire| {
                try prop_classes.append(gen.arena, wire);
            } else if (try gen.prop_wire(a.value, .value)) |wire| {
                // A class list the caller wires (a `classes` prop): the
                // group is the value spec itself, in parentheses.
                try prop_classes.append(gen.arena, try std.fmt.allocPrint(gen.arena, "(if ({s}) |publr_classes| @as(?[]const u8, rt.concat(arena, &.{{ \"(\", publr_classes, \")\" }})) else @as(?[]const u8, null))", .{wire}));
            }
        }

        try gen.static("<");
        switch (tag) {
            .static => |text| try gen.static(text),
            .runtime => |code| try gen.line("try {s}.writeAll({s});", .{ gen.writer_name, code }),
        }

        // The module's store lands on its root element (set once, consumed by
        // the first element opened), followed by its `data-p` seed — the JSON
        // the client store is primed with, quotes attribute-escaped exactly
        // as the DOM runtime authors them.
        if (gen.root_store) |store_name| {
            gen.root_store = null;
            try gen.static(" data-p-store=\"");
            try gen.static_escaped(store_name, true);
            try gen.static("\"");

            if (gen.root_seeds.len > 0) {
                const seeds = gen.root_seeds;
                gen.root_seeds = &.{};
                try gen.static(" data-p=\"{");
                var has_optional = false;
                for (seeds) |seed| {
                    if ((try gen.expression(seed.expr)).type.is_optional()) has_optional = true;
                }
                const separator = if (has_optional) try gen.fresh("seed_separator") else "";
                if (has_optional) try gen.line("var {s}: []const u8 = \"\";", .{separator});
                for (seeds, 0..) |seed, index| {
                    var lowered = try gen.expression(seed.expr);
                    const optional = lowered.type.is_optional();
                    if (optional) {
                        const binding = try gen.fresh("seed");
                        try gen.line("if ({s}) |{s}| {{", .{ lowered.code, binding });
                        gen.indent += 1;
                        lowered = .{ .code = binding, .type = lowered.type.unwrapped() };
                    }
                    if (has_optional) {
                        try gen.line("try {s}.writeAll({s});", .{ gen.writer_name, separator });
                        try gen.line("{s} = \",\";", .{separator});
                    } else if (index > 0) try gen.static(",");
                    try gen.static("&quot;");
                    try gen.static(seed.field);
                    try gen.static("&quot;:");
                    switch (lowered.type) {
                        .string => try gen.line("try rt.write_seed_string({s}, {s});", .{ gen.writer_name, lowered.code }),
                        .boolean => try gen.line("try {s}.writeAll(if ({s}) \"true\" else \"false\");", .{ gen.writer_name, lowered.code }),
                        .number => try gen.line("try rt.write_number({s}, {s});", .{ gen.writer_name, lowered.code }),
                        .null => try gen.static("null"),
                        .array, .item, .strings => try gen.line("try rt.write_seed_value({s}, arena, {s});", .{ gen.writer_name, lowered.code }),
                        else => return gen.fail("a family seed of type {s} is not lowered", .{@tagName(lowered.type)}),
                    }
                    if (optional) {
                        try gen.flush();
                        gen.indent -= 1;
                        try gen.line("}}", .{});
                    }
                }
                try gen.static("}\"");
            }
        }

        var transport_parts: std.Io.Writer.Allocating = .init(gen.arena);

        for (plain.items) |a| {
            const rename: ?[]const u8 = if (std.mem.eql(u8, a.name, "position")) "data-p-position" else if (std.mem.eql(u8, a.name, "focusScope")) "data-p-focus" else null;
            try gen.attribute(a, rename);

            // An attribute bound to transportable props re-emits the wire a
            // caller may have handed through `publr_bind_<prop>`.
            if (rename == null and a.form == .expression) {
                var prop_sources: std.ArrayList([]const u8) = .empty;
                if (try gen.transparent_sources(a.value, &prop_sources)) {
                    var chain: std.Io.Writer.Allocating = .init(gen.arena);
                    for (prop_sources.items, 0..) |source, index| {
                        if (index > 0) try chain.writer.writeAll(" orelse ");
                        try chain.writer.print("props.publr_bind_{s}", .{source});
                    }
                    try transport_parts.writer.print(
                        " (if ({s}) |publr_wire| @as(?[]const u8, rt.concat(arena, &.{{ \"{s}:\", publr_wire }})) else @as(?[]const u8, null)),",
                        .{ chain.written(), a.name },
                    );
                } else if (try gen.prop_wire(a.value, .value)) |wire| {
                    try transport_parts.writer.print(
                        " (if ({s}) |publr_wire| @as(?[]const u8, rt.concat(arena, &.{{ \"{s}:\", publr_wire }})) else @as(?[]const u8, null)),",
                        .{ wire, a.name },
                    );
                }
            }
        }

        for (directives.items) |text| {
            try gen.static(text);
        }

        for (own_ssr.items) |attr| {
            try gen.ssr_attribute(attr.name, attr.lowered);
        }

        // The component-root transport: a caller's `hidden`/`:show`/`:text`
        // lands here through the publr_show/publr_show_wire/publr_text_wire
        // props (all null unless a call site set them).
        if (gen.at_root) {
            gen.at_root = false;
            gen.props_used = true;
            try gen.line("try rt.write_attr_cond({s}, \"hidden\", if (props.publr_show) |publr_show| @as(?bool, !publr_show) else @as(?bool, null));", .{gen.writer_name});
            try gen.line("try rt.write_attr_cond({s}, \"data-p-show\", props.publr_show_wire);", .{gen.writer_name});
            if (renders_children_prop(n)) {
                try gen.line("try rt.write_attr_cond({s}, \"data-p-text\", props.publr_text_wire);", .{gen.writer_name});
            }
        }

        if (class_attrs.items.len == 1) {
            try gen.attribute(class_attrs.items[0], null);
        } else if (class_attrs.items.len > 1) {
            try gen.merged_classes(class_attrs.items);
        }

        if (events.items.len > 0) {
            try gen.event_attribute(events.items);
        }

        if (transport_parts.written().len == 0) {
            if (bindings.items.len > 0) {
                try gen.static(" data-p-bind=\"");
                for (bindings.items, 0..) |binding, index| {
                    if (index > 0) try gen.static(";");
                    try gen.static_escaped(binding.name, true);
                    try gen.static(":");
                    try gen.static_escaped(binding.wire, true);
                }
                try gen.static("\"");
            }
        } else {
            // Static wires and transported ones join into one attribute at
            // run time (absent transports drop out).
            var join_parts: std.Io.Writer.Allocating = .init(gen.arena);
            if (bindings.items.len > 0) {
                var static_binds: std.Io.Writer.Allocating = .init(gen.arena);
                for (bindings.items, 0..) |binding, index| {
                    if (index > 0) try static_binds.writer.writeAll(";");
                    try static_binds.writer.print("{s}:{s}", .{ binding.name, binding.wire });
                }
                try join_parts.writer.print(" {s},", .{try zig_string(gen.arena, static_binds.written())});
            }
            try join_parts.writer.writeAll(transport_parts.written());
            gen.arena_used = true;
            try gen.line("try rt.write_attr_cond({s}, \"data-p-bind\", rt.join_optionals(arena, &.{{{s} }}, \";\"));", .{
                gen.writer_name,
                join_parts.written(),
            });
        }

        if (show_wire) |wire| {
            try gen.static(" data-p-show=\"");
            try gen.static_escaped(wire, true);
            try gen.static("\"");
        }
        if (text_wire) |wire| {
            try gen.static(" data-p-text=\"");
            try gen.static_escaped(wire, true);
            try gen.static("\"");
        }
        if (text_prop_wire) |wire| {
            try gen.line("try rt.write_attr_cond({s}, \"data-p-text\", {s});", .{ gen.writer_name, wire });
        }
        if (prop_classes.items.len > 0) {
            var groups: std.Io.Writer.Allocating = .init(gen.arena);
            for (behavior_classes.items) |wire| try groups.writer.print(" {s},", .{try zig_string(gen.arena, wire)});
            for (prop_classes.items) |wire| try groups.writer.print(" {s},", .{wire});
            gen.arena_used = true;
            try gen.line("try rt.write_attr_cond({s}, \"data-p-class\", rt.join_optionals(arena, &.{{{s} }}, \";\"));", .{ gen.writer_name, groups.written() });
        } else if (behavior_classes.items.len > 0) {
            try gen.static(" data-p-class=\"");
            for (behavior_classes.items, 0..) |wire, index| {
                if (index > 0) try gen.static(";");
                try gen.static_escaped(wire, true);
            }
            try gen.static("\"");
        }

        try gen.static(">");

        switch (tag) {
            // A computed tag is assumed non-void: every `<Dynamic>` in the
            // design system computes over non-void tags (a, button, h1…h6, …).
            .runtime => {},
            .static => |text| for (void_elements) |void_tag| {
                if (std.mem.eql(u8, text, void_tag)) {
                    return;
                }
            },
        }

        if (html_ssr) |html| {
            if (html.type != .string and html.type != .node) return gen.fail("innerHTML must be a string or rendered node", .{});
            if (html.type == .node) {
                gen.arena_used = true;
                try gen.line("try {s}.render({s}, arena);", .{ html.code, gen.writer_name });
            } else {
                try gen.line("try {s}.writeAll({s});", .{ gen.writer_name, html.code });
            }
        } else if (!skip_children) {
            const saved = gen.prop_wire_skip;
            if (sole_child != null) gen.prop_wire_skip = sole_child;
            try gen.children(n.children);
            gen.prop_wire_skip = saved;
        } else if (text_ssr) |initial| {
            // The text wire's SSR value stands in for the skipped child.
            try gen.write_value(initial);
        }
        try gen.static("</");
        switch (tag) {
            .static => |text| try gen.static(text),
            .runtime => |code| try gen.line("try {s}.writeAll({s});", .{ gen.writer_name, code }),
        }
        try gen.static(">");
    }

    /// Collects the transportable prop names behind a "transparent" bound
    /// expression — a plain prop reference, a `a ?? b` chain of them (a
    /// literal fallback is fine), or an empty-quasi template coercion. These
    /// are the attributes whose wire a caller may hand through
    /// `publr_bind_<prop>`.
    fn transparent_sources(gen: *Generator, e: *const ExpressionIR, out: *std.ArrayList([]const u8)) Error!bool {
        switch (e.*) {
            .reference => |reference_ir| {
                if (reference_ir.source != .prop) return false;
                const prop = find_field(gen.module.props, reference_ir.name) orelse return false;
                if (!prop.bind_transport) return false;
                try out.append(gen.arena, reference_ir.name);
                return true;
            },
            .operation => |operation_ir| {
                if (!std.mem.eql(u8, operation_ir.operator, "??")) return false;
                if (!try gen.transparent_sources(operation_ir.left, out)) return false;
                if (operation_ir.right.* == .literal) return true;
                return gen.transparent_sources(operation_ir.right, out);
            },
            .template => |template_ir| {
                var inner: ?*const ExpressionIR = null;
                for (template_ir.parts) |part| {
                    switch (part) {
                        .string => |text| if (text.len != 0) return false,
                        .expression => |part_expr| if (inner == null) {
                            inner = part_expr;
                        } else return false,
                    }
                }
                return if (inner) |expr| gen.transparent_sources(expr, out) else false;
            },
            else => return false,
        }
    }

    /// The literal wire text of a behavior or binding: `:show="$dirty"` passes
    /// `$dirty` through verbatim — the wire format is the authoring format.
    fn wire_text(gen: *Generator, form: compiler.AttributeForm, value: *const ExpressionIR) Error![]const u8 {
        if (form != .literal) {
            return gen.fail("a wire must be authored as its literal, e.g. :show=\"$dirty\"", .{});
        }
        return gen.literal_text(value);
    }

    /// An `@click.prevent="reset"` (or `@click={fn}`) event attribute.
    fn event_of(gen: *Generator, ev: @FieldType(AttributeIR, "event")) Error!Event {
        var descriptor: std.Io.Writer.Allocating = .init(gen.arena);

        try descriptor.writer.writeAll(ev.event);
        for (ev.modifiers) |modifier| {
            try descriptor.writer.print(".{s}", .{modifier});
        }

        if (ev.form == .literal) {
            return .{ .descriptor = descriptor.written(), .action = .{ .static = try gen.literal_text(ev.value) } };
        }

        return .{ .descriptor = descriptor.written(), .action = try gen.action_of(try gen.expression(ev.value)) };
    }

    /// An `onInput={syncTitle}` attribute: the event name comes from the
    /// attribute name, the action from the referenced reactive action or prop.
    fn event_of_attribute(gen: *Generator, name: []const u8, a: PlainAttrIR) Error!Event {
        if (a.form != .expression) {
            return gen.fail("\"{s}\" must reference an action", .{name});
        }

        const descriptor = try util.eventDescriptor(gen.arena, name);
        if (try gen.wire_spec(a.value)) |wired| {
            if (std.mem.indexOf(u8, wired.spec, "::") != null) return .{ .descriptor = descriptor, .action = .{ .static = wired.spec } };
        }
        return .{ .descriptor = descriptor, .action = try gen.action_of(try gen.expression(a.value)) };
    }

    fn action_of(gen: *Generator, lowered: Lowered) Error!Event.ActionRef {
        return switch (lowered.type) {
            .action_name => .{ .static = try unquoted(gen, lowered.code) },
            .action => .{ .runtime = lowered.code },
            else => gen.fail("an event handler must be a reactive action, got a {s}", .{@tagName(lowered.type)}),
        };
    }

    /// One `data-p-on` attribute for all of an element's events. All-static
    /// wires join at compile time; an action prop in the mix moves the whole
    /// attribute to `rt.write_wire_attr`, which skips absent actions and omits
    /// the attribute when none is set.
    fn event_attribute(gen: *Generator, events: []const Event) Error!void {
        var all_static = true;

        for (events) |event| {
            if (event.action == .runtime) all_static = false;
        }

        if (all_static) {
            try gen.static(" data-p-on=\"");
            for (events, 0..) |event, index| {
                if (index > 0) try gen.static(";");
                try gen.static_escaped(event.descriptor, true);
                try gen.static(":");
                try gen.static_escaped(event.action.static, true);
            }
            try gen.static("\"");
            return;
        }

        var parts: std.Io.Writer.Allocating = .init(gen.arena);

        for (events) |event| {
            const value = switch (event.action) {
                .static => |name| try zig_string(gen.arena, name),
                .runtime => |code| code,
            };
            try parts.writer.print(" .{{ .prefix = {s}, .value = {s} }},", .{
                try zig_string(gen.arena, try std.fmt.allocPrint(gen.arena, "{s}:", .{event.descriptor})),
                value,
            });
        }

        try gen.line("try rt.write_wire_attr({s}, \"data-p-on\", &.{{{s} }});", .{
            gen.writer_name,
            parts.written(),
        });
    }

    fn class_initial(gen: *Generator, e: *const ExpressionIR) Error!Lowered {
        if (try gen.class_wire_group(e)) |group| {
            if (group.own) {
                const initial = (try gen.own_initial(e.conditional.@"test")) orelse return gen.fail("no SSR initial for a reactive class", .{});
                if (initial == .unservable) return .{ .code = "\"\"", .type = .string };
                return .{ .code = try std.fmt.allocPrint(gen.arena, "(if ({s}) {s} else {s})", .{
                    try gen.truthy(initial.lowered),
                    (try gen.expression(e.conditional.consequent)).code,
                    (try gen.expression(e.conditional.alternate)).code,
                }), .type = .string };
            }
        }
        return gen.expression(e);
    }

    /// The inner ` p1, p2,` text of a `&.{ … }` class-part slice.
    fn class_parts(gen: *Generator, attrs: []const PlainAttrIR) Error![]const u8 {
        var parts: std.Io.Writer.Allocating = .init(gen.arena);

        for (attrs) |a| {
            if (a.form == .literal) {
                try parts.writer.print(" {s},", .{try zig_string(gen.arena, try gen.literal_text(a.value))});
                continue;
            }

            var lowered = if (std.mem.eql(u8, a.name, "class")) try gen.class_initial(a.value) else try gen.expression(a.value);

            if (lowered.type == .finite) {
                lowered = try gen.materialize_finite(lowered.type.finite);
            }

            switch (lowered.type) {
                .string => try parts.writer.print(" {s},", .{lowered.code}),
                .opt_string => try parts.writer.print(" ({s} orelse \"\"),", .{lowered.code}),
                else => return gen.fail("a class stack part is a {s}, which is not lowered", .{@tagName(lowered.type)}),
            }
        }

        return parts.written();
    }

    /// A stack of `class` attributes merges into one attribute through the
    /// consumer's class-merge implementation: a later conflicting utility
    /// wins, as in the DOM runtime.
    fn merged_classes(gen: *Generator, attrs: []const PlainAttrIR) Error!void {
        gen.arena_used = true;
        const parts = try gen.class_parts(attrs);
        try gen.static(" class=\"");
        try gen.line("try rt.write_merged({s}, arena, &.{{{s} }});", .{ gen.writer_name, parts });
        try gen.static("\"");
    }

    /// The raw text of a `zig_string` literal this generator produced (action
    /// names are identifiers, so nothing in them was escaped).
    fn unquoted(gen: *Generator, literal: []const u8) Error![]const u8 {
        if (literal.len < 2 or literal[0] != '"') {
            return gen.fail("an action name is not a literal", .{});
        }
        return literal[1 .. literal.len - 1];
    }

    /// A style object's fields as `prop:value` CSS text (camelCase keys
    /// kebab-cased, `--custom` kept); only literal string values are lowered
    /// (a reactive style field would need the `data-p-style` wire nothing in
    /// the corpus uses).
    fn style_object_text(gen: *Generator, e: *const ExpressionIR) Error![]const u8 {
        if (e.* != .object) return gen.fail("a style object without fields", .{});
        var out: std.Io.Writer.Allocating = .init(gen.arena);

        for (e.object.fields, 0..) |style_field, index| {
            const text = string_of_literal(style_field.value) orelse {
                return gen.fail("style map value \"{s}\" is not a literal string; reactive styles are not lowered", .{style_field.name});
            };

            if (index > 0) try out.writer.writeAll(";");
            if (std.mem.startsWith(u8, style_field.name, "--")) {
                try out.writer.writeAll(style_field.name);
            } else {
                for (style_field.name) |char| {
                    if (char >= 'A' and char <= 'Z') {
                        try out.writer.writeByte('-');
                        try out.writer.writeByte(char + ('a' - 'A'));
                    } else {
                        try out.writer.writeByte(char);
                    }
                }
            }
            try out.writer.writeAll(":");
            try out.writer.writeAll(text);
        }
        return out.written();
    }

    fn static_style_object(gen: *Generator, e: *const ExpressionIR) Error!void {
        try gen.static_escaped(try gen.style_object_text(e), true);
    }

    /// HTML-escapes authored text at compile time: `&`, `<`, `>` always; `"` too
    /// inside an attribute value.
    fn static_escaped(gen: *Generator, text: []const u8, in_attribute: bool) Error!void {
        for (text) |char| {
            switch (char) {
                '&' => try gen.static("&amp;"),
                '<' => try gen.static("&lt;"),
                '>' => try gen.static("&gt;"),
                '"' => try gen.static(if (in_attribute) "&quot;" else "\""),
                else => try gen.pending.append(gen.arena, char),
            }
        }
    }

    fn attribute(gen: *Generator, a: PlainAttrIR, name_override: ?[]const u8) Error!void {
        const name = name_override orelse a.name;

        if (a.form == .bare) {
            try gen.static(" ");
            try gen.static(name);
            return;
        }

        if (a.form == .literal) {
            try gen.static(" ");
            try gen.static(name);
            try gen.static("=\"");
            try gen.static_escaped(try gen.literal_text(a.value), true);
            try gen.static("\"");
            return;
        }

        var lowered = if (std.mem.eql(u8, a.name, "class")) try gen.class_initial(a.value) else try gen.expression(a.value);

        if (lowered.type == .finite) {
            lowered = try gen.materialize_finite(lowered.type.finite);
        }

        // ARIA states are enumerated, not boolean HTML attributes:
        // `aria-invalid={bool}` must serialize as `"true"`/`"false"`.
        const aria_boolean = lowered.type.unwrapped() == .boolean and std.mem.startsWith(u8, name, "aria-");

        switch (lowered.type.unwrapped()) {
            .boolean => if (aria_boolean) {
                if (lowered.type.is_optional()) {
                    const binding = try gen.fresh("value");
                    try gen.line("if ({s}) |{s}| {{", .{ lowered.code, binding });
                    gen.indent += 1;
                    try gen.static(" ");
                    try gen.static(name);
                    try gen.static("=\"");
                    try gen.write_value(.{ .code = binding, .type = .boolean });
                    try gen.static("\"");
                    try gen.flush();
                    gen.indent -= 1;
                    try gen.line("}}", .{});
                } else {
                    try gen.static(" ");
                    try gen.static(name);
                    try gen.static("=\"");
                    try gen.write_value(lowered);
                    try gen.static("\"");
                }
            } else {
                try gen.line("if ({s}) try {s}.writeAll(\" {s}\");", .{
                    try gen.truthy(lowered),
                    gen.writer_name,
                    name,
                });
            },
            .string, .number, .enumeration => {
                if (lowered.type.is_optional()) {
                    const binding = try gen.fresh("value");
                    try gen.line("if ({s}) |{s}| {{", .{ lowered.code, binding });
                    gen.indent += 1;
                    try gen.static(" ");
                    try gen.static(name);
                    try gen.static("=\"");
                    try gen.write_value(.{ .code = binding, .type = lowered.type.unwrapped() });
                    try gen.static("\"");
                    try gen.flush();
                    gen.indent -= 1;
                    try gen.line("}}", .{});
                } else {
                    try gen.static(" ");
                    try gen.static(name);
                    try gen.static("=\"");
                    try gen.write_value(lowered);
                    try gen.static("\"");
                }
            },
            .null => {},
            else => return gen.fail("attribute \"{s}\" has a value of type {s}, which is not lowered", .{
                name,
                @tagName(lowered.type),
            }),
        }
    }

    fn literal_text(gen: *Generator, value: *const ExpressionIR) Error![]const u8 {
        if (value.* != .literal) {
            return gen.fail("literal attribute carries a {s} expression", .{@tagName(value.*)});
        }

        return switch (value.literal) {
            .string => |s| s,
            .number => |number| try util.numberToString(gen.arena, number),
            .boolean => |b| if (b) "true" else "false",
            .null => gen.fail("literal of an unsupported type", .{}),
        };
    }

    /// `<Name attr=…>children</Name>`: children render into an arena buffer, then
    /// the callee's `render` runs with a `Props` literal.
    fn component(gen: *Generator, name: []const u8, n: *const ElementIR) Error!void {
        if (gen.is_publr_jsx_import(name)) {
            if (std.mem.eql(u8, name, "Dynamic")) {
                return gen.dynamic_element(n);
            }
            if (std.mem.eql(u8, name, "Slot")) {
                return gen.slot_element(n);
            }
            return gen.fail("publr-dom's <{s}> is not lowered", .{name});
        }

        const callee = gen.resolve_component(name) orelse {
            return gen.fail("component <{s}> is not imported", .{name});
        };

        var fields: std.Io.Writer.Allocating = .init(gen.arena);
        var forwarded: std.Io.Writer.Allocating = .init(gen.arena);
        var forwarded_binds: std.Io.Writer.Allocating = .init(gen.arena);

        for (n.attributes) |attr| {
            const plain_attr = switch (attr) {
                .attribute => |plain| plain,
                else => return gen.fail("<{s}> carries a {s}, which is not lowered", .{ name, @tagName(attr) }),
            };

            const attribute_name = plain_attr.name;
            if (std.mem.eql(u8, attribute_name, "key") and find_field(callee.props, "key") == null) continue;
            const form = plain_attr.form;
            const value = plain_attr.value;

            // `hidden` on a component call rides the show transport, with
            // inverted polarity.
            if (std.mem.eql(u8, attribute_name, "hidden") and find_field(callee.props, "hidden") == null) {
                if (!callee.transport_root) {
                    return gen.fail("<{s}> cannot carry a show transport: its root cannot receive it (see the header)", .{name});
                }
                if (form == .bare) {
                    try fields.writer.writeAll(" .publr_show = false,");
                } else if (form == .expression) {
                    if (try gen.wire_spec(value)) |wired| {
                        if (wired.own) {
                            const state = (try gen.own_initial(value)) orelse {
                                return gen.fail("no SSR value for this module's own state behind `hidden` on <{s}>", .{name});
                            };
                            switch (state) {
                                .lowered => |initial| try fields.writer.print(" .publr_show = !{s},", .{try gen.truthy(initial)}),
                                .unservable => {},
                            }
                        }
                        try fields.writer.print(" .publr_show_wire = {s},", .{try zig_string(gen.arena, try gen.invert_wire(wired.spec))});
                    } else {
                        const lowered = try gen.expression(value);
                        try fields.writer.print(" .publr_show = !{s},", .{try gen.truthy(lowered)});
                    }
                } else {
                    return gen.fail("`hidden` on <{s}> must be bare or an expression", .{name});
                }
                continue;
            }

            // JSX refs and events are root attributes even when the component
            // does not declare a bespoke prop for them.
            if (std.mem.eql(u8, attribute_name, "ref") and form == .expression) {
                const lowered = try gen.expression(value);
                if (lowered.type != .ref_name) return gen.fail("`ref` must name a declared store ref", .{});
                try forwarded.writer.print(" .{{ .name = \"data-p-ref\", .value = {s} }},", .{try zig_string(gen.arena, lowered.code)});
                continue;
            }
            if (is_action_attribute(attribute_name) and find_field(callee.props, attribute_name) == null) {
                const event = try gen.event_of_attribute(attribute_name, plain_attr);
                const code = switch (event.action) {
                    .static => |action| try zig_string(gen.arena, try std.fmt.allocPrint(gen.arena, "{s}:{s}", .{ event.descriptor, action })),
                    .runtime => |action| blk: {
                        gen.arena_used = true;
                        break :blk try std.fmt.allocPrint(gen.arena, "if ({s}) |publr_action| rt.concat(arena, &.{{ {s}, publr_action }}) else null", .{ action, try zig_string(gen.arena, try std.fmt.allocPrint(gen.arena, "{s}:", .{event.descriptor})) });
                    },
                };
                try forwarded.writer.print(" .{{ .name = \"data-p-on\", .value = {s} }},", .{code});
                continue;
            }

            const target = find_field(callee.props, attribute_name) orelse {
                // A rest attribute (`data-part`, `role`, `aria-*`…) forwards
                // onto the callee's rendered root element.
                if (!is_forwardable_attribute(attribute_name)) {
                    return gen.fail("<{s}> has no prop \"{s}\"", .{ name, attribute_name });
                }
                if (form == .bare) {
                    try forwarded.writer.print(" .{{ .name = \"{s}\", .value = null }},", .{attribute_name});
                } else if (form == .literal) {
                    try forwarded.writer.print(" .{{ .name = \"{s}\", .value = {s} }},", .{
                        attribute_name,
                        try zig_string(gen.arena, try gen.literal_text(value)),
                    });
                } else if (try gen.wire_spec(value)) |wired| {
                    // A reactive rest attribute forwards as a bind wire on
                    // the callee's root.
                    if (wired.own) {
                        if (try gen.own_initial(value)) |initial| {
                            if (initial == .lowered) {
                                const code = switch (initial.lowered.type) {
                                    .string, .opt_string => initial.lowered.code,
                                    else => return gen.fail("a forwarded initial attribute must be a string", .{}),
                                };
                                try forwarded.writer.print(" .{{ .name = \"{s}\", .value = {s} }},", .{ attribute_name, code });
                            }
                        }
                    }
                    try forwarded_binds.writer.print("{s}{s}:{s}", .{
                        if (forwarded_binds.written().len == 0) "" else ";",
                        attribute_name,
                        wired.spec,
                    });
                } else {
                    var lowered = try gen.expression(value);
                    if (lowered.type == .finite) lowered = try gen.materialize_finite(lowered.type.finite);
                    const code = switch (lowered.type) {
                        .string, .opt_string => lowered.code,
                        .enumeration => try std.fmt.allocPrint(gen.arena, "@tagName({s})", .{lowered.code}),
                        else => return gen.fail("a forwarded \"{s}\" is a {s}, which is not lowered", .{ attribute_name, @tagName(lowered.type) }),
                    };
                    try forwarded.writer.print(" .{{ .name = \"{s}\", .value = {s} }},", .{ attribute_name, code });
                }
                continue;
            };

            // A style object fills a string-typed style prop as its CSS text.
            if (form == .expression and std.mem.eql(u8, attribute_name, "style") and value.* == .object) {
                try fields.writer.print(" .{f} = {s},", .{
                    std.zig.fmtId(attribute_name),
                    try zig_string(gen.arena, try gen.style_object_text(value)),
                });
                continue;
            }

            if (form == .expression) {
                // A reactive binding crosses the boundary as the prop's wire;
                // a foreign one has no SSR value, so the prop keeps its
                // default until hydration.
                if (try gen.wire_spec(value)) |wired| {
                    if (!target.bind_transport) {
                        return gen.fail("<{s}>'s \"{s}\" cannot carry a wire (not a scalar prop)", .{ name, attribute_name });
                    }
                    if (wired.own) {
                        const state = (try gen.own_initial(value)) orelse {
                            return gen.fail("no SSR value for this module's own state on <{s}>", .{name});
                        };
                        switch (state) {
                            .lowered => |initial| try fields.writer.print(" .{f} = {s},", .{ std.zig.fmtId(attribute_name), (if (target.type.unwrapped() == .enumeration) try gen.enum_expression(value, target.type) else null) orelse try gen.coerce(initial, target.type) }),
                            .unservable => {},
                        }
                    }
                    // A template's prototype renders before any row: a prop
                    // the wire fills takes a placeholder — present, as the
                    // wired value is (`href === undefined` picks the tag).
                    if (!wired.own and gen.template_depth > 0) {
                        const required = target.default == null and !target.type.is_optional();
                        const placeholder: ?[]const u8 = switch (target.type) {
                            .string, .opt_string => "\"\"",
                            .enumeration => |e| if (required) try std.fmt.allocPrint(gen.arena, ".@\"{s}\"", .{e.values[0]}) else null,
                            .opt_enumeration => |e| try std.fmt.allocPrint(gen.arena, ".@\"{s}\"", .{e.values[0]}),
                            .number => if (required) "0" else null,
                            .opt_number => "0",
                            .boolean => if (required) "false" else null,
                            .opt_boolean => "false",
                            else => null,
                        };
                        if (placeholder) |code| try fields.writer.print(" .{f} = {s},", .{ std.zig.fmtId(attribute_name), code });
                    }
                    try fields.writer.print(" .publr_bind_{s} = {s},", .{ attribute_name, try zig_string(gen.arena, wired.spec) });
                    continue;
                }
            }

            // A value derived from this component's wired props hands its
            // wire on to the callee.
            if (form == .expression and target.bind_transport) {
                if (try gen.prop_wire(value, .value)) |wire| {
                    try fields.writer.print(" .publr_bind_{s} = {s},", .{ attribute_name, wire });
                }
            }

            const code = if (form == .bare)
                "true"
            else if (form == .literal)
                try gen.coerce_literal(try gen.literal_text(value), target.type)
            else blk: {
                if (target.type.unwrapped() == .enumeration) {
                    if (try gen.enum_expression(value, target.type)) |code| break :blk code;
                }
                const lowered = try gen.expression(value);
                // Each module declares its own array item structs. Copy by field
                // into the callee's schema instead of passing incompatible slices.
                if (lowered.type == .array and target.type == .array) {
                    gen.arena_used = true;
                    break :blk try std.fmt.allocPrint(
                        gen.arena,
                        "try rt.prop_array(@FieldType({s}.Props, \"{s}\"), arena, {s})",
                        .{ name, attribute_name, lowered.code },
                    );
                }
                // An optional fills a defaulted required prop through its
                // default (`value={maybe}` onto `placeholder: ""`).
                if (lowered.type.is_optional() and !target.type.is_optional() and
                    std.meta.activeTag(lowered.type.unwrapped()) == std.meta.activeTag(target.type))
                {
                    if (target.default) |default_code| {
                        break :blk try std.fmt.allocPrint(gen.arena, "({s} orelse {s})", .{ lowered.code, default_code });
                    }
                }
                break :blk try gen.coerce(lowered, target.type);
            };

            try fields.writer.print(" .{f} = {s},", .{ std.zig.fmtId(attribute_name), code });
        }

        // A component-call root passes the transport through.
        if (gen.at_root) {
            gen.at_root = false;
            gen.props_used = true;
            try fields.writer.writeAll(" .publr_show = props.publr_show, .publr_show_wire = props.publr_show_wire, .publr_text_wire = props.publr_text_wire,");
        }

        if (forwarded_binds.written().len > 0) {
            try forwarded.writer.print(" .{{ .name = \"data-p-bind\", .value = {s} }},", .{
                try zig_string(gen.arena, forwarded_binds.written()),
            });
        }

        try gen.flush();

        if (forwarded.written().len > 0) {
            const buffer = try gen.fresh("fwd");
            const writer = try std.fmt.allocPrint(gen.arena, "{s}_w", .{buffer});
            const outer = gen.writer_name;

            gen.arena_used = true;
            try gen.line("{{", .{});
            gen.indent += 1;
            try gen.line("var {s} = rt.ForwardAttributesWriter.init({s}, arena, &.{{{s} }});", .{ buffer, outer, forwarded.written() });
            try gen.line("const {s} = &{s}.writer;", .{ writer, buffer });
            gen.writer_name = writer;
            try gen.component_call(name, callee, fields.written(), n);
            gen.writer_name = outer;
            try gen.line("try {s}.finish();", .{buffer});
            gen.indent -= 1;
            try gen.line("}}", .{});
            return;
        }

        try gen.component_call(name, callee, fields.written(), n);
    }

    /// The render call for a resolved component: children become a block node
    /// (a capture struct over the props and loop items in scope, and a render
    /// function the callee calls when it reaches them), or pass as a plain
    /// string for string-typed children.
    fn component_call(gen: *Generator, name: []const u8, callee: Module, fields: []const u8, n: *const ElementIR) Error!void {
        const child_nodes = n.children;

        try gen.flush();

        if (child_nodes.len > 0) {
            const children_prop = find_field(callee.props, "children") orelse {
                return gen.fail("<{s}> takes no children", .{name});
            };

            // A string-typed children prop (an option's label) takes plain
            // text, not markup: a single text or string-expression child is
            // passed as the value — the callee escapes it when writing.
            if (children_prop.type == .string or children_prop.type == .opt_string) {
                if (child_nodes.len != 1) {
                    return gen.fail("<{s}>'s children prop is a string; only a single text or string child is lowered", .{name});
                }
                const child = child_nodes[0];
                const code = switch (child.*) {
                    .text => |text| try zig_string(gen.arena, text.value),
                    .expression => |expression_node| blk: {
                        const lowered = try gen.expression(expression_node.value);
                        break :blk try gen.coerce(lowered, children_prop.type);
                    },
                    else => return gen.fail("<{s}>'s children prop is a string; only a single text or string child is lowered", .{name}),
                };

                gen.arena_used = true;
                try gen.line("try {s}.render({s}, arena, .{{{s} .children = {s} }});", .{
                    name,
                    gen.writer_name,
                    fields,
                    code,
                });
                return;
            }

            if (children_prop.type != .node and children_prop.type != .opt_node) {
                return gen.fail("<{s}>'s children prop is a {s}, which is not lowered", .{
                    name,
                    @tagName(children_prop.type),
                });
            }

            const capture = try gen.fresh("children");
            const body_type = try capitalize(gen.arena, capture);

            try gen.block_struct(body_type, child_nodes);

            var captured: std.Io.Writer.Allocating = .init(gen.arena);
            try captured.writer.writeAll(" .props = &props,");
            for (gen.locals.items) |local| {
                try captured.writer.print(" .{s} = &{s},", .{ local.name, local.name });
            }

            gen.arena_used = true;
            gen.props_used = true;
            try gen.line("{{", .{});
            gen.indent += 1;
            try gen.line("const {s} = .{{{s} }};", .{ capture, captured.written() });
            try gen.line("try {s}.render({s}, arena, .{{{s} .children = rt.block(&{s}, {s}) }});", .{
                name,
                gen.writer_name,
                fields,
                capture,
                body_type,
            });
            gen.indent -= 1;
            try gen.line("}}", .{});
        } else {
            gen.arena_used = true;
            try gen.line("try {s}.render({s}, arena, .{{{s} }});", .{ name, gen.writer_name, fields });
        }
    }

    /// The file-scope struct behind one block node: `render(cap, w, arena)`
    /// rebinds the props and the loop items the caller had in scope from the
    /// capture, then writes the children as the caller's own body would.
    /// Generated into `blocks`, aside from the body being built.
    fn block_struct(gen: *Generator, body_type: []const u8, child_nodes: []const *const NodeIR) Error!void {
        try gen.flush();

        const saved_body = gen.body;
        const saved_indent = gen.indent;
        const saved_writer = gen.writer_name;
        gen.body = .init(gen.arena);
        gen.indent = 0;
        gen.writer_name = "w";

        try gen.line("", .{});
        try gen.line("const {s} = struct {{", .{body_type});
        gen.indent += 1;
        try gen.line("pub fn render(cap: anytype, w: *std.Io.Writer, arena: std.mem.Allocator) anyerror!void {{", .{});
        gen.indent += 1;
        try gen.line("_ = &arena;", .{});
        try gen.line("const props = cap.props.*;", .{});
        try gen.line("_ = &props;", .{});

        for (gen.locals.items) |local| {
            try gen.line("const {s} = cap.{s}.*;", .{ local.name, local.name });
            try gen.line("_ = &{s};", .{local.name});
        }

        for (child_nodes) |child| {
            try gen.node(child);
        }

        try gen.flush();
        gen.indent -= 1;
        try gen.line("}}", .{});
        gen.indent -= 1;
        try gen.line("}};", .{});

        const source = gen.body.written();
        gen.body = saved_body;
        gen.indent = saved_indent;
        gen.writer_name = saved_writer;
        try gen.blocks.writer.writeAll(source);
    }

    /// `<Slot …>{children}</Slot>` — the `asChild` pattern: no element of its
    /// own; the wrapper's attributes merge onto the caller's already-rendered
    /// child through `rt.slot_props`. Ordinary attributes replace, class
    /// merges, `data-p-on` layers join.
    fn slot_element(gen: *Generator, n: *const ElementIR) Error!void {
        const child_nodes = n.children;

        if (child_nodes.len != 1 or child_nodes[0].* != .expression) {
            return gen.fail("<Slot> takes exactly one child expression (the caller's children)", .{});
        }

        const child = try gen.expression(child_nodes[0].expression.value);
        const child_code = switch (child.type) {
            .node => try std.fmt.allocPrint(gen.arena, "(try rt.render_to_string(arena, {s}))", .{child.code}),
            .opt_node => try std.fmt.allocPrint(
                gen.arena,
                "(if ({s}) |publr_node| try rt.render_to_string(arena, publr_node) else \"\")",
                .{child.code},
            ),
            else => return gen.fail("<Slot>'s child is a {s}, not a node", .{@tagName(child.type)}),
        };

        var fields: std.Io.Writer.Allocating = .init(gen.arena);
        var class_attrs: std.ArrayList(PlainAttrIR) = .empty;
        var class_wires: std.ArrayList([]const u8) = .empty;
        var slot_events: std.ArrayList(Event) = .empty;
        var bind_wires: std.ArrayList([]const u8) = .empty;
        var show_field: ?[]const u8 = null;
        var paired: std.ArrayList(PlainAttrIR) = .empty;

        const attrs = n.attributes;

        for (attrs) |a| {
            if (a == .binding and (a.binding.form == .literal or a.binding.value.* == .literal)) {
                try bind_wires.append(gen.arena, try std.fmt.allocPrint(gen.arena, "{s}:{s}", .{ a.binding.name, try gen.wire_text(a.binding.form, a.binding.value) }));
                continue;
            }
            const plain_attr: PlainAttrIR = switch (a) {
                .attribute => |plain| plain,
                .binding => |binding| .{ .name = binding.name, .form = binding.form, .value = binding.value },
                else => return gen.fail("<Slot> carries a {s}, which is not lowered", .{@tagName(a)}),
            };
            const attr_name = plain_attr.name;
            const form = plain_attr.form;
            const value = plain_attr.value;

            if (std.mem.eql(u8, attr_name, "class")) {
                if (form == .expression) {
                    if (try gen.class_wire_group(value)) |group| {
                        try class_wires.append(gen.arena, group.spec);
                        if (!group.own) continue;
                    }
                }
                try class_attrs.append(gen.arena, plain_attr);
                continue;
            }

            if (is_action_attribute(attr_name)) {
                try slot_events.append(gen.arena, try gen.event_of_attribute(attr_name, plain_attr));
                continue;
            }

            if (std.mem.eql(u8, attr_name, "ref") and form == .expression) {
                const lowered = try gen.expression(value);
                if (lowered.type != .ref_name) {
                    return gen.fail("`ref` must name a declared store ref, got a {s}", .{@tagName(lowered.type)});
                }
                try fields.writer.print(" .@\"data-p-ref\" = \"{s}\",", .{lowered.code});
                continue;
            }
            if ((std.mem.eql(u8, attr_name, "portal") or std.mem.eql(u8, attr_name, "anchor")) and form == .bare) {
                try fields.writer.print(" .@\"data-p-{s}\" = true,", .{attr_name});
                continue;
            }

            if (count_attribute(attrs, attr_name) > 1) {
                try paired.append(gen.arena, plain_attr);
                continue;
            }

            if (form == .bare) {
                try fields.writer.print(" .@\"{s}\" = true,", .{attr_name});
                continue;
            }
            if (form == .literal) {
                try fields.writer.print(" .@\"{s}\" = {s},", .{ attr_name, try zig_string(gen.arena, try gen.literal_text(value)) });
                continue;
            }

            if (try gen.wire_spec(value)) |wired| {
                if (wired.own) return gen.fail("an SSR value from this module's own reactive state is not lowered yet (\"{s}\")", .{attr_name});
                if (std.mem.eql(u8, attr_name, "hidden")) {
                    show_field = try gen.invert_wire(wired.spec);
                } else {
                    try bind_wires.append(gen.arena, try std.fmt.allocPrint(gen.arena, "{s}:{s}", .{ attr_name, wired.spec }));
                }
                continue;
            }

            var lowered = try gen.expression(value);
            if (lowered.type == .finite) lowered = try gen.materialize_finite(lowered.type.finite);
            const code = switch (lowered.type) {
                .string, .opt_string, .boolean, .opt_boolean, .number, .opt_number => lowered.code,
                .enumeration => try std.fmt.allocPrint(gen.arena, "@tagName({s})", .{lowered.code}),
                .opt_enumeration => try std.fmt.allocPrint(
                    gen.arena,
                    "(if ({s}) |v| @as(?[]const u8, @tagName(v)) else @as(?[]const u8, null))",
                    .{lowered.code},
                ),
                else => return gen.fail("a <Slot> attribute is a {s}, which is not lowered", .{@tagName(lowered.type)}),
            };
            try fields.writer.print(" .@\"{s}\" = {s},", .{ attr_name, code });
        }

        // SSR + wire pairs (`aria-expanded="false"` + `aria-expanded={state.open}`).
        var pair_index: usize = 0;
        while (pair_index < paired.items.len) {
            const attr_name = paired.items[pair_index].name;
            var static_member: ?PlainAttrIR = null;
            var wired_member: ?[]const u8 = null;
            var group_size: usize = 0;

            for (paired.items[pair_index..]) |member| {
                if (!std.mem.eql(u8, member.name, attr_name)) break;
                group_size += 1;
                if (member.form == .expression) {
                    if (try gen.wire_spec(member.value)) |wired| {
                        if (wired.own) return gen.fail("an SSR value from this module's own reactive state is not lowered yet (\"{s}\")", .{attr_name});
                        wired_member = wired.spec;
                        continue;
                    }
                }
                static_member = member;
            }
            pair_index += group_size;

            const static_attr = static_member orelse return gen.fail("\"{s}\" pairs a wire with no static value", .{attr_name});
            const wire = wired_member orelse return gen.fail("\"{s}\" appears twice without a wire", .{attr_name});

            if (static_attr.form == .bare) {
                try fields.writer.print(" .@\"{s}\" = true,", .{attr_name});
            } else {
                try fields.writer.print(" .@\"{s}\" = {s},", .{
                    attr_name,
                    try zig_string(gen.arena, try gen.literal_text(static_attr.value)),
                });
            }
            if (std.mem.eql(u8, attr_name, "hidden")) {
                show_field = try gen.invert_wire(wire);
            } else {
                try bind_wires.append(gen.arena, try std.fmt.allocPrint(gen.arena, "{s}:{s}", .{ attr_name, wire }));
            }
        }

        if (class_attrs.items.len == 1 and class_attrs.items[0].form == .literal) {
            try fields.writer.print(" .class = {s},", .{
                try zig_string(gen.arena, try gen.literal_text(class_attrs.items[0].value)),
            });
        } else if (class_attrs.items.len > 0) {
            try fields.writer.print(" .class = try rt.merge_classes(arena, &.{{{s} }}),", .{try gen.class_parts(class_attrs.items)});
        }

        if (slot_events.items.len > 0) {
            var all_static = true;
            for (slot_events.items) |event| {
                if (event.action == .runtime) all_static = false;
            }

            if (all_static) {
                var joined: std.Io.Writer.Allocating = .init(gen.arena);
                for (slot_events.items, 0..) |event, index| {
                    if (index > 0) try joined.writer.writeAll(";");
                    try joined.writer.print("{s}:{s}", .{ event.descriptor, event.action.static });
                }
                try fields.writer.print(" .@\"data-p-on\" = {s},", .{try zig_string(gen.arena, joined.written())});
            } else {
                // An action prop in the mix: join the present wires at run
                // time (slot_props skips the field when none is set).
                gen.arena_used = true;
                var join_parts: std.Io.Writer.Allocating = .init(gen.arena);
                for (slot_events.items) |event| {
                    switch (event.action) {
                        .static => |action_name| try join_parts.writer.print(" {s},", .{
                            try zig_string(gen.arena, try std.fmt.allocPrint(gen.arena, "{s}:{s}", .{ event.descriptor, action_name })),
                        }),
                        .runtime => |code| try join_parts.writer.print(
                            " (if ({s}) |publr_action| @as(?[]const u8, rt.concat(arena, &.{{ \"{s}:\", publr_action }})) else @as(?[]const u8, null)),",
                            .{ code, event.descriptor },
                        ),
                    }
                }
                try fields.writer.print(" .@\"data-p-on\" = rt.join_optionals(arena, &.{{{s} }}, \";\"),", .{join_parts.written()});
            }
        }
        if (bind_wires.items.len > 0) {
            var joined: std.Io.Writer.Allocating = .init(gen.arena);
            for (bind_wires.items, 0..) |wire, index| {
                if (index > 0) try joined.writer.writeAll(";");
                try joined.writer.writeAll(wire);
            }
            try fields.writer.print(" .@\"data-p-bind\" = {s},", .{try zig_string(gen.arena, joined.written())});
        }
        if (show_field) |wire| {
            try fields.writer.print(" .@\"data-p-show\" = {s},", .{try zig_string(gen.arena, wire)});
        }
        if (class_wires.items.len > 0) {
            var joined: std.Io.Writer.Allocating = .init(gen.arena);
            for (class_wires.items, 0..) |wire, index| {
                if (index > 0) try joined.writer.writeAll(";");
                try joined.writer.writeAll(wire);
            }
            try fields.writer.print(" .@\"data-p-class\" = {s},", .{try zig_string(gen.arena, joined.written())});
        }

        // A Slot at the component root receives the transport too.
        if (gen.at_root) {
            gen.at_root = false;
            gen.props_used = true;
            try fields.writer.writeAll(" .hidden = if (props.publr_show) |publr_show| @as(?bool, !publr_show) else @as(?bool, null),");
            try fields.writer.writeAll(" .@\"data-p-show\" = props.publr_show_wire,");
        }

        gen.arena_used = true;
        try gen.line("try {s}.writeAll(rt.slot_props(arena, {s}, .{{{s} }}));", .{
            gen.writer_name,
            child_code,
            fields.written(),
        });
    }

    /// `<Dynamic as={…}>`: an intrinsic element whose tag is the `as` value —
    /// static when `as` is a literal, a bound Zig expression otherwise.
    fn dynamic_element(gen: *Generator, n: *const ElementIR) Error!void {
        const as: PlainAttrIR = for (n.attributes) |a| {
            if (a == .attribute and std.mem.eql(u8, a.attribute.name, "as")) {
                break a.attribute;
            }
        } else return gen.fail("<Dynamic> without an `as` attribute", .{});

        if (as.form == .literal) {
            return gen.element_body(.{ .static = try gen.literal_text(as.value) }, n, "as");
        }

        const lowered = try gen.expression(as.value);
        const code = switch (lowered.type) {
            .string => lowered.code,
            .enumeration => try std.fmt.allocPrint(gen.arena, "@tagName({s})", .{lowered.code}),
            else => return gen.fail("<Dynamic as> is a {s}, which is not lowered", .{@tagName(lowered.type)}),
        };
        const binding = try gen.fresh("tag");

        try gen.line("const {s} = {s};", .{ binding, code });
        try gen.element_body(.{ .runtime = binding }, n, "as");
    }

    fn is_publr_jsx_import(gen: *Generator, local: []const u8) bool {
        for (gen.module.imports) |import| {
            if (std.mem.eql(u8, import.local, local) and (std.mem.eql(u8, import.module, "publr/dom") or std.mem.eql(u8, import.module, "publr-dom") or std.mem.eql(u8, import.module, "publr") or std.mem.eql(u8, import.module, "publr-jsx"))) {
                return true;
            }
        }
        return false;
    }

    fn resolve_component(gen: *Generator, local: []const u8) ?Module {
        for (gen.module.imports) |import| {
            if (!std.mem.eql(u8, import.local, local)) {
                continue;
            }
            for (gen.modules) |candidate| {
                if (std.mem.eql(u8, candidate.file_stem, import.module) or
                    std.mem.eql(u8, candidate.name, import.module))
                {
                    for (gen.imports_used.items) |used| {
                        if (std.mem.eql(u8, used, local)) return candidate;
                    }
                    gen.imports_used.append(gen.arena, local) catch return null;
                    return candidate;
                }
            }
        }
        return null;
    }

    /// A value filling an enum prop, lowered against the target enum rather
    /// than as a string: a string literal (checked against the enum), a
    /// conditional of such values, `LOOKUP[key] ?? fallback` over a
    /// string-keyed finite map (each entry checked, the lookup an optional
    /// enum), and a component-body binding whose initializer is one of
    /// these — re-lowered here instead of read as its string local. Null
    /// when the value is none of these; the caller lowers it as usual.
    fn enum_expression(gen: *Generator, value: *const ExpressionIR, target: Type) Error!?[]const u8 {
        const enumeration = target.unwrapped().enumeration;
        switch (value.*) {
            .literal => |literal| if (literal == .string) return try gen.coerce_literal(literal.string, target),
            .conditional => |c| {
                const test_value = if (try gen.own_initial(c.@"test")) |initial| if (initial == .lowered) initial.lowered else try gen.expression(c.@"test") else try gen.expression(c.@"test");
                return try std.fmt.allocPrint(gen.arena, "(if ({s}) {s} else {s})", .{
                    try gen.truthy(test_value),
                    (try gen.enum_expression(c.consequent, target)) orelse try gen.coerce(try gen.expression(c.consequent), target),
                    (try gen.enum_expression(c.alternate, target)) orelse try gen.coerce(try gen.expression(c.alternate), target),
                });
            },
            .operation => |operation_ir| if (std.mem.eql(u8, operation_ir.operator, "??")) {
                if (try gen.string_lookup(operation_ir.left)) |lookup| {
                    const fallback = (try gen.enum_expression(operation_ir.right, target)) orelse try gen.coerce(try gen.expression(operation_ir.right), target);
                    return try gen.string_keyed_lookup(lookup.entries, lookup.key_code, enumeration, fallback);
                }
            },
            .member => if (try gen.string_lookup(value)) |lookup| {
                if (!target.is_optional()) {
                    return gen.fail("a string-keyed lookup cannot fill the required {s} enum without a `??` fallback", .{enumeration.name});
                }
                return try gen.string_keyed_lookup(lookup.entries, lookup.key_code, enumeration, null);
            },
            .reference => |reference_ir| if (reference_ir.source == .local) {
                if (gen.binding_of(reference_ir.name)) |initializer| return gen.enum_expression(initializer, target);
            },
            else => {},
        }
        return null;
    }

    const StringLookup = struct { entries: []const Type.MapEntry, key_code: []const u8 };

    /// The map and the lowered key of `TONES[kind]` over a finite map with a
    /// string key; null when the value is not such a lookup.
    fn string_lookup(gen: *Generator, value: *const ExpressionIR) Error!?StringLookup {
        if (value.* != .member or value.member.property == .string) return null;
        const object = try gen.expression(value.member.object);
        if (object.type != .finite_map) return null;
        const key = try gen.member_index(value.member.property);
        if (key.type != .string) return null;
        return .{ .entries = object.type.finite_map, .key_code = key.code };
    }

    /// The initializer of the component-body binding a local name resolves
    /// to, or null when it resolves to anything else.
    fn binding_of(gen: *Generator, name: []const u8) ?*const ExpressionIR {
        var index = gen.locals.items.len;
        while (index > 0) {
            index -= 1;
            const local = gen.locals.items[index];
            if (std.mem.eql(u8, local.source_name orelse local.name, name)) return local.binding;
        }
        return null;
    }

    fn coerce_literal(gen: *Generator, text: []const u8, target: Type) Error![]const u8 {
        return switch (target) {
            .string, .opt_string, .action => try zig_string(gen.arena, text),
            .node, .opt_node => try std.fmt.allocPrint(gen.arena, "rt.raw({s})", .{try zig_string(gen.arena, text)}),
            .union_value => try std.fmt.allocPrint(gen.arena, ".{{ .string = {s} }}", .{try zig_string(gen.arena, text)}),
            .enumeration, .opt_enumeration => |e| blk: {
                if (!util.containsString(e.values, text)) {
                    return gen.fail("\"{s}\" is not a value of the {s} enum", .{ text, e.name });
                }
                break :blk try std.fmt.allocPrint(gen.arena, ".@\"{s}\"", .{text});
            },
            .number, .opt_number => text,
            .boolean, .opt_boolean => text,
            else => gen.fail("a literal cannot fill a prop of type {s}", .{@tagName(target)}),
        };
    }

    fn coerce(gen: *Generator, lowered: Lowered, target: Type) Error![]const u8 {
        if (lowered.type.unwrapped() == .enumeration and target.unwrapped() == .enumeration) {
            const source_enum = lowered.type.unwrapped().enumeration;
            const target_enum = target.unwrapped().enumeration;
            var out: std.Io.Writer.Allocating = .init(gen.arena);
            if (lowered.type.is_optional()) try out.writer.print("(if ({s}) |publr_enum| ", .{lowered.code});
            try out.writer.print("(switch ({s}) {{", .{if (lowered.type.is_optional()) "publr_enum" else lowered.code});
            for (source_enum.values) |tag| {
                if (!util.containsString(target_enum.values, tag)) return gen.fail("enum value {s} is outside the destination type", .{tag});
                try out.writer.print(" .@\"{s}\" => .@\"{s}\",", .{ tag, tag });
            }
            try out.writer.writeAll(" })");
            if (lowered.type.is_optional()) try out.writer.writeAll(" else null)");
            return out.toOwnedSlice();
        }
        const same = std.meta.activeTag(lowered.type) == std.meta.activeTag(target);
        const widened = !lowered.type.is_optional() and
            std.meta.activeTag(lowered.type) == std.meta.activeTag(target.unwrapped());

        if (same or widened) {
            return lowered.code;
        }

        // An absent or null value fills any optional prop.
        if (lowered.type == .null and (target.is_optional() or target == .action)) {
            return "null";
        }

        if (target == .action and lowered.type == .action_name) {
            return lowered.code;
        }

        if (lowered.type == .finite) {
            return switch (target.unwrapped()) {
                .enumeration => |e| try gen.finite_to_enum(lowered.type.finite, e),
                .string => (try gen.materialize_finite(lowered.type.finite)).code,
                else => gen.fail("a finite map value cannot fill a prop of type {s}", .{@tagName(target)}),
            };
        }

        // A union crosses a component boundary by re-tagging into the
        // callee's identically-shaped union type.
        if (lowered.type == .union_value and target == .union_value) {
            return std.fmt.allocPrint(
                gen.arena,
                "(switch ({s}) {{ .string => |publr_string| .{{ .string = publr_string }}, .number_string_tuple => |publr_tuple| .{{ .number_string_tuple = publr_tuple }} }})",
                .{lowered.code},
            );
        }
        if (lowered.type == .string and target == .union_value) {
            return std.fmt.allocPrint(gen.arena, ".{{ .string = {s} }}", .{lowered.code});
        }

        // An enum value fills a string prop as its tag name.
        if (lowered.type == .enumeration and target.unwrapped() == .string) {
            return std.fmt.allocPrint(gen.arena, "@tagName({s})", .{lowered.code});
        }

        return gen.fail("a {s} value cannot fill a prop of type {s}", .{
            @tagName(lowered.type),
            @tagName(target),
        });
    }

    // -- expressions in child position: something is written --

    fn child_expression(gen: *Generator, e: *const ExpressionIR) Error!void {
        // Markup guarded by wired props: a `data-p-if` branch per arm when a
        // prop is wired, the plain branch otherwise.
        if (gen.prop_wire_skip != e) switch (e.*) {
            .conditional => |c| if (contains_jsx(c.consequent) or contains_jsx(c.alternate)) {
                if (try gen.prop_wire(c.@"test", .value)) |wire| {
                    return gen.prop_branches(e, wire, c.@"test", c.consequent, if (is_null_literal(c.alternate)) null else c.alternate);
                }
            },
            .operation => |operation_ir| if (std.mem.eql(u8, operation_ir.operator, "&&") and contains_jsx(operation_ir.right)) {
                if (try gen.prop_wire(operation_ir.left, .value)) |wire| {
                    return gen.prop_branches(e, wire, operation_ir.left, operation_ir.right, null);
                }
            },
            else => {},
        };

        switch (e.*) {
            .literal => |literal| {
                if (literal != .null and literal != .boolean) {
                    try gen.static_escaped(try gen.literal_text(e), false);
                }
                return;
            },
            .node => |node_expr| return gen.node(node_expr.node),
            .conditional => |conditional| {
                if (try gen.wire_spec(conditional.@"test")) |wired| {
                    try gen.reactive_branch(conditional.consequent, conditional.@"test", wired, false);
                    if (!is_null_literal(conditional.alternate))
                        try gen.reactive_branch(conditional.alternate, conditional.@"test", wired, true);
                    return;
                }
                const was_root = gen.at_root;
                gen.at_root = false;
                const test_code = try gen.truthy(try gen.expression(conditional.@"test"));
                try gen.line("if ({s}) {{", .{test_code});
                gen.indent += 1;
                gen.at_root = was_root;
                try gen.child_expression(conditional.consequent);
                gen.at_root = false;
                try gen.flush();
                gen.indent -= 1;

                if (is_null_literal(conditional.alternate)) {
                    try gen.line("}}", .{});
                } else {
                    try gen.line("}} else {{", .{});
                    gen.indent += 1;
                    gen.at_root = was_root;
                    try gen.child_expression(conditional.alternate);
                    gen.at_root = false;
                    try gen.flush();
                    gen.indent -= 1;
                    try gen.line("}}", .{});
                }
                return;
            },
            .operation => |operation_ir| {
                if (std.mem.eql(u8, operation_ir.operator, "??") and contains_jsx(operation_ir.right)) {
                    // `{children ?? <Fallback/>}` — an optional node with a
                    // declarative fallback.
                    const left = try gen.expression(operation_ir.left);
                    if (!left.type.is_optional()) {
                        return gen.fail("`??` with a JSX fallback needs an optional left side, got a {s}", .{@tagName(left.type)});
                    }
                    const binding = try gen.fresh("present");
                    try gen.line("if ({s}) |{s}| {{", .{ left.code, binding });
                    gen.indent += 1;
                    try gen.write_child_value(.{ .code = binding, .type = left.type.unwrapped() });
                    try gen.flush();
                    gen.indent -= 1;
                    try gen.line("}} else {{", .{});
                    gen.indent += 1;
                    try gen.child_expression(operation_ir.right);
                    try gen.flush();
                    gen.indent -= 1;
                    try gen.line("}}", .{});
                    return;
                }
                if (std.mem.eql(u8, operation_ir.operator, "&&") and contains_jsx(operation_ir.right)) {
                    if (try gen.wire_spec(operation_ir.left)) |wired| {
                        try gen.reactive_branch(operation_ir.right, operation_ir.left, wired, false);
                        return;
                    }
                    // `a && b && <jsx/>` over state: no one wire tests both,
                    // so each guard becomes its own branch.
                    if (try gen.split_guard(e)) |split| return gen.child_expression(split);
                    // `{cond && <jsx/>}` — preserve the selected operand in the portable contract.
                    const left = try gen.expression(operation_ir.left);
                    if (gen.module.semantics_version != 0) {
                        const name = try gen.fresh("guard");
                        try gen.line("const {s} = {s};", .{ name, left.code });
                        const saved = Lowered{ .code = name, .type = left.type };
                        try gen.line("if ({s}) {{", .{try gen.truthy(saved)});
                        gen.indent += 1;
                        try gen.child_expression(operation_ir.right);
                        try gen.flush();
                        gen.indent -= 1;
                        try gen.line("}} else {{", .{});
                        gen.indent += 1;
                        try gen.write_child_value(saved);
                        try gen.flush();
                        gen.indent -= 1;
                        try gen.line("}}", .{});
                        return;
                    }
                    const test_code = switch (left.type) {
                        .opt_boolean => try std.fmt.allocPrint(gen.arena, "({s} orelse false)", .{left.code}),
                        .opt_string, .opt_number, .opt_node, .opt_enumeration, .opt_strings, .action => try std.fmt.allocPrint(gen.arena, "({s} != null)", .{left.code}),
                        else => try gen.truthy(left),
                    };
                    try gen.line("if ({s}) {{", .{test_code});
                    gen.indent += 1;
                    const present_count = gen.present_values.items.len;
                    defer gen.present_values.shrinkRetainingCapacity(present_count);
                    if (left.type.is_optional() and left.type != .opt_boolean) try gen.present_values.append(gen.arena, left.code);
                    try gen.child_expression(operation_ir.right);
                    try gen.flush();
                    gen.indent -= 1;
                    try gen.line("}}", .{});
                    return;
                }
            },
            .call => if (is_map_call(e)) return gen.loop(e),
            .template => |template_ir| {
                for (template_ir.parts) |part| {
                    switch (part) {
                        .string => |text| try gen.static_escaped(text, false),
                        .expression => |part_expr| try gen.child_expression(part_expr),
                    }
                }
                return;
            },
            else => {},
        }

        // A state expression among other children renders as a text-wire
        // span (`{$path}` text holes, as the ZSX chain emits them), with
        // the servable initial as its SSR content.
        if (try gen.wire_spec(e)) |wired| {
            try gen.static("<span data-p-text=\"");
            try gen.static_escaped(wired.spec, true);
            try gen.static("\">");
            if (wired.own) {
                if (try gen.own_initial(e)) |state| {
                    if (state == .lowered) try gen.write_child_value(state.lowered);
                }
            }
            try gen.static("</span>");
            return;
        }
        // Text derived from wired props: a text-wire span when one is wired.
        if (!contains_jsx(e)) if (try gen.prop_wire(e, .value)) |wire| {
            const capture = try gen.fresh_prop("publr_text");
            try gen.line("const {s} = {s};", .{ capture, wire });
            try gen.line("if ({s} == null) {{", .{capture});
            gen.indent += 1;
            try gen.write_child_value(try gen.expression(e));
            try gen.flush();
            gen.indent -= 1;
            try gen.line("}} else {{", .{});
            gen.indent += 1;
            try gen.static("<span data-p-text=\"");
            try gen.line("try rt.escape({s}, {s}.?);", .{ gen.writer_name, capture });
            try gen.static("\">");
            try gen.write_child_value(try gen.expression(e));
            try gen.static("</span>");
            try gen.flush();
            gen.indent -= 1;
            try gen.line("}}", .{});
            return;
        };
        try gen.write_child_value(try gen.expression(e));
    }

    /// `{test && <A/>}` / `{test ? <A/> : <B/>}` whose test reads wired
    /// props: when the wire is present at render time, each arm is a
    /// `data-p-if` template (with its server-rendered initial) over it;
    /// otherwise the plain branch.
    fn prop_branches(gen: *Generator, e: *const ExpressionIR, wire: []const u8, condition: *const ExpressionIR, consequent: *const ExpressionIR, alternate: ?*const ExpressionIR) Error!void {
        const capture = try gen.fresh_prop("publr_branch");
        try gen.line("const {s} = {s};", .{ capture, wire });
        try gen.line("if ({s} == null) {{", .{capture});
        gen.indent += 1;
        const saved = gen.prop_wire_skip;
        gen.prop_wire_skip = e;
        try gen.child_expression(e);
        gen.prop_wire_skip = saved;
        try gen.flush();
        gen.indent -= 1;
        try gen.line("}} else {{", .{});
        gen.indent += 1;
        const present = try std.fmt.allocPrint(gen.arena, "{s}.?", .{capture});
        try gen.prop_branch(consequent, present, condition, false);
        if (alternate) |arm| try gen.prop_branch(arm, present, condition, true);
        try gen.flush();
        gen.indent -= 1;
        try gen.line("}}", .{});
    }

    fn prop_branch(gen: *Generator, body: *const ExpressionIR, capture: []const u8, condition: *const ExpressionIR, inverse: bool) Error!void {
        // A present optional is unwrapped inside the arm, as under a plain
        // `&&`; the prototype of such an arm renders only when it is present.
        const tested = try gen.expression(condition);
        const unwraps = !inverse and tested.type.is_optional() and tested.type != .opt_boolean;
        const present_count = gen.present_values.items.len;
        defer gen.present_values.shrinkRetainingCapacity(present_count);

        try gen.static("<template data-p-template=\"");
        try gen.static(try gen.template_id(body));
        try gen.static("\" data-p-if=\"");
        try gen.line("try rt.escape({s}, {s});", .{ gen.writer_name, capture });
        try gen.static("\"");
        if (inverse) try gen.static(" data-p-if-not");
        try gen.static(">");
        if (unwraps) {
            try gen.line("if ({s} != null) {{", .{tested.code});
            gen.indent += 1;
            try gen.present_values.append(gen.arena, tested.code);
        }
        gen.template_depth += 1;
        try gen.branch_body(body);
        gen.template_depth -= 1;
        if (unwraps) {
            try gen.flush();
            gen.indent -= 1;
            try gen.line("}}", .{});
            gen.present_values.shrinkRetainingCapacity(present_count);
        }
        try gen.static("</template>");

        // The server-rendered arm, tested as the plain branch tests it.
        const presence = unwraps and gen.module.semantics_version == 0;
        const test_code = if (presence) try std.fmt.allocPrint(gen.arena, "({s} != null)", .{tested.code}) else try gen.truthy(tested);
        try gen.line("if ({s}{s}) {{", .{ if (inverse) @as([]const u8, "!") else "", test_code });
        gen.indent += 1;
        if (unwraps) try gen.present_values.append(gen.arena, tested.code);
        const marker = try gen.fresh("branch_writer");
        const outer = gen.writer_name;
        try gen.line("var {s} = rt.RootAttributeWriter.init({s}, \"data-p-if-row\", null);", .{ marker, outer });
        gen.writer_name = try std.fmt.allocPrint(gen.arena, "(&{s}.writer)", .{marker});
        gen.seeded_depth += 1;
        try gen.branch_body(body);
        gen.seeded_depth -= 1;
        try gen.flush();
        gen.writer_name = outer;
        gen.indent -= 1;
        try gen.line("}}", .{});
    }

    /// `(a && b) && <jsx/>` as `a && (b && <jsx/>)` when `a && b` is not a
    /// wire but one of its guards is — the same rendering (a falsy guard is
    /// the value either way), with a branch per guard. One regrouping per
    /// expression, so the template ids agree between the prototype and the
    /// server-rendered rows.
    fn split_guard(gen: *Generator, e: *const ExpressionIR) Error!?*const ExpressionIR {
        for (gen.split_guards.items) |entry| {
            if (entry.expression == e) return entry.split;
        }
        const guards = e.operation.left;
        if (guards.* != .operation or !std.mem.eql(u8, guards.operation.operator, "&&")) return null;
        if (try gen.wire_spec(guards.operation.left) == null and try gen.wire_spec(guards.operation.right) == null) return null;

        const inner = try gen.arena.create(ExpressionIR);
        inner.* = .{ .operation = .{ .operator = "&&", .left = guards.operation.right, .right = e.operation.right } };
        const outer = try gen.arena.create(ExpressionIR);
        outer.* = .{ .operation = .{ .operator = "&&", .left = guards.operation.left, .right = inner } };
        try gen.split_guards.append(gen.arena, .{ .expression = e, .split = outer });
        return outer;
    }

    /// `xs.map((x) => <…/>)` → `for (xs) |x| { … }`.
    fn loop(gen: *Generator, e: *const ExpressionIR) Error!void {
        const call = e.call;

        if (call.callee.* != .member or call.arguments.len != 1) {
            return gen.fail("only `array.map((item) => …)` calls are lowered", .{});
        }
        const property = call.callee.member.property;
        if (property != .string or !std.mem.eql(u8, property.string, "map")) {
            return gen.fail("only `array.map((item) => …)` calls are lowered", .{});
        }

        const function = call.arguments[0];
        if (function.* != .function or function.function.parameters.len != 1) {
            return gen.fail("`.map` takes a one-parameter arrow function", .{});
        }

        if (try gen.wire_spec(call.callee.member.object)) |wired| {
            const parameter = function.function.parameters[0];
            try gen.wire_aliases.append(gen.arena, parameter);
            defer _ = gen.wire_aliases.pop();
            // Inside a server-rendered row the anchor carries only its id: the
            // runtime reads the loop spec and key from the prototype it registered
            // under that id, so the row does not repeat them.
            const anchor_only = gen.seeded_depth > 0 and gen.template_depth == 0;
            const body = function.function.body;
            try gen.static("<template data-p-template=\"");
            try gen.static(try gen.template_id(e));
            try gen.static("\" data-p-for");
            if (!anchor_only) {
                try gen.static("=\"");
                try gen.static_escaped(parameter, true);
                try gen.static(" of ");
                try gen.static_escaped(wired.spec, true);
                try gen.static("\"");
                if (body.* == .node and body.node.node.* == .element) {
                    for (body.node.node.element.attributes) |attr| {
                        if (attr == .attribute and std.mem.eql(u8, attr.attribute.name, "key")) {
                            const key = (try gen.wire_spec(attr.attribute.value)) orelse return gen.fail("a reactive list key must be a row path", .{});
                            try gen.static(" data-p-key=\"");
                            try gen.static_escaped(key.spec, true);
                            try gen.static("\"");
                        }
                    }
                }
            }
            try gen.static(">");
            if (!anchor_only) {
                gen.template_depth += 1;
                try gen.child_expression(body);
                gen.template_depth -= 1;
            }
            try gen.static("</template>");
            if (wired.own and gen.template_depth == 0) {
                if (try gen.own_initial(call.callee.member.object)) |initial| {
                    if (initial == .lowered) try gen.seeded_rows(initial.lowered, function.function);
                }
            }
            return;
        }
        const subject = try gen.expression(call.callee.member.object);
        const item_type: Type = switch (subject.type) {
            .array => |fields| .{ .item = fields },
            .strings => .string,
            else => return gen.fail("`.map` on a {s}, which is not a lowered array", .{@tagName(subject.type)}),
        };
        const parameter = function.function.parameters[0];

        try gen.line("for ({s}) |{s}| {{", .{ subject.code, parameter });
        gen.indent += 1;
        try gen.locals.append(gen.arena, .{ .name = parameter, .type = item_type });
        try gen.child_expression(function.function.body);
        try gen.flush();
        _ = gen.locals.pop();
        gen.indent -= 1;
        try gen.line("}}", .{});
    }

    fn template_id(gen: *Generator, expr: *const ExpressionIR) Error![]const u8 {
        for (gen.templates.items) |entry| {
            if (entry.expression == expr) return entry.name;
        }
        const name = try std.fmt.allocPrint(gen.arena, "{s}-{d}", .{ gen.module.name, gen.templates.items.len });
        try gen.templates.append(gen.arena, .{ .expression = expr, .name = name });
        return name;
    }

    fn reactive_branch(gen: *Generator, body: *const ExpressionIR, condition: *const ExpressionIR, wired: Wired, inverse: bool) Error!void {
        // Inside a server-rendered row the anchor carries only its id and its
        // direction: the runtime reads the condition from the prototype registered
        // under that id, so the row does not repeat it.
        const in_row = gen.seeded_depth > 0 and gen.template_depth == 0;
        try gen.static("<template data-p-template=\"");
        try gen.static(try gen.template_id(body));
        try gen.static("\" data-p-if");
        if (!in_row) {
            try gen.static("=\"");
            try gen.static_escaped(wired.spec, true);
            try gen.static("\"");
        }
        if (inverse) try gen.static(" data-p-if-not");
        try gen.static(">");
        if (!in_row) {
            gen.template_depth += 1;
            try gen.branch_body(body);
            gen.template_depth -= 1;
        }
        try gen.static("</template>");
        if (!wired.own or gen.template_depth > 0) return;
        const initial = (try gen.own_initial(condition)) orelse return;
        if (initial == .unservable) return;
        try gen.line("if ({s}{s}) {{", .{ if (inverse) @as([]const u8, "!") else "", try gen.truthy(initial.lowered) });
        gen.indent += 1;
        const marker = try gen.fresh("branch_writer");
        const outer = gen.writer_name;
        try gen.line("var {s} = rt.RootAttributeWriter.init({s}, \"data-p-if-row\", null);", .{ marker, outer });
        gen.writer_name = try std.fmt.allocPrint(gen.arena, "(&{s}.writer)", .{marker});
        gen.seeded_depth += 1;
        try gen.branch_body(body);
        gen.seeded_depth -= 1;
        try gen.flush();
        gen.writer_name = outer;
        gen.indent -= 1;
        try gen.line("}}", .{});
    }

    fn branch_body(gen: *Generator, body: *const ExpressionIR) Error!void {
        const wrapper = body.* != .node or body.node.node.* != .element;
        if (wrapper) try gen.static("<span class=\"contents\">");
        try gen.child_expression(body);
        if (wrapper) try gen.static("</span>");
    }

    fn seeded_rows(gen: *Generator, subject: Lowered, function: anytype) Error!void {
        const item_type: Type = switch (subject.type) {
            .array => |fields| .{ .item = fields },
            .strings => .string,
            else => return gen.fail("a seeded list needs an array", .{}),
        };
        const parameter = function.parameters[0];
        const index = try gen.fresh("row_index");
        try gen.line("for ({s}, 0..) |{s}, {s}| {{", .{ subject.code, parameter, index });
        gen.indent += 1;
        try gen.line("_ = &{s};", .{index});
        try gen.locals.append(gen.arena, .{ .name = parameter, .type = item_type });
        var key_code: []const u8 = index;
        if (function.body.* == .node and function.body.node.node.* == .element) {
            for (function.body.node.node.element.attributes) |attr| {
                if (attr == .attribute and std.mem.eql(u8, attr.attribute.name, "key")) {
                    key_code = (try gen.expression(attr.attribute.value)).code;
                }
            }
        }
        const key = try gen.fresh("row_key");
        const marker = try gen.fresh("row_writer");
        const outer = gen.writer_name;
        gen.arena_used = true;
        try gen.line("const {s} = try std.json.Stringify.valueAlloc(arena, {s}, .{{}});", .{ key, key_code });
        try gen.line("defer arena.free({s});", .{key});
        try gen.line("var {s} = rt.RootAttributeWriter.init({s}, \"data-p-for-key\", {s});", .{ marker, outer, key });
        gen.writer_name = try std.fmt.allocPrint(gen.arena, "(&{s}.writer)", .{marker});
        gen.seeded_depth += 1;
        try gen.child_expression(function.body);
        gen.seeded_depth -= 1;
        try gen.flush();
        gen.writer_name = outer;
        _ = gen.locals.pop();
        gen.indent -= 1;
        try gen.line("}}", .{});
    }

    /// Writes a lowered value according to its type: strings escaped, nodes raw,
    /// numbers printed, enums by tag, optionals only when present.
    fn write_child_value(gen: *Generator, value: Lowered) Error!void {
        if (value.type == .boolean or value.type == .opt_boolean) {
            try gen.line("_ = ({s});", .{value.code});
        } else if (value.type != .null) try gen.write_value(value);
    }

    fn write_value(gen: *Generator, lowered: Lowered) Error!void {
        if (lowered.type.is_optional()) {
            const binding = try gen.fresh("value");
            try gen.line("if ({s}) |{s}| {{", .{ lowered.code, binding });
            gen.indent += 1;
            try gen.write_value(.{ .code = binding, .type = lowered.type.unwrapped() });
            try gen.flush();
            gen.indent -= 1;
            try gen.line("}}", .{});
            return;
        }

        switch (lowered.type) {
            .string => try gen.line("try rt.escape({s}, {s});", .{ gen.writer_name, lowered.code }),
            .node => {
                gen.arena_used = true;
                try gen.line("try {s}.render({s}, arena);", .{ lowered.code, gen.writer_name });
            },
            .number => try gen.line("try rt.write_number({s}, {s});", .{ gen.writer_name, lowered.code }),
            .boolean => try gen.line("try {s}.writeAll(if ({s}) \"true\" else \"false\");", .{ gen.writer_name, lowered.code }),
            .null => {},
            .enumeration => try gen.line("try {s}.writeAll(@tagName({s}));", .{ gen.writer_name, lowered.code }),
            else => return gen.fail("a {s} cannot be written as text", .{@tagName(lowered.type)}),
        }
    }

    // -- the wire translator ------------------------------------------------
    //
    // JS expressions over reactive/family state translate to the PublrJS wire
    // DSL (the retired ZSX chain's `reactiveWireSpec`): `state.open` →
    // `$open`, `!state.open` → `not $open`,
    // `state.values.includes(Publr.dataset("value"))` → `$values contains
    // @value`, comparisons/`||`/ternary-with-literal-arms likewise. A part
    // module's binding is *foreign* (the store lives on a DOM ancestor), so
    // the wire is emitted without an SSR initial value; an own-module wire
    // renders its seed or initial-state value alongside.

    const Wired = struct { spec: []const u8, own: bool };

    /// `state.a.b` → the dotted path, empty for the state object itself;
    /// null when the expression is not a state member chain.
    fn wire_state_path(gen: *Generator, e: *const ExpressionIR) ?Wired {
        switch (e.*) {
            .reference => |reference_ir| {
                for (gen.wire_aliases.items) |alias| {
                    if (std.mem.eql(u8, alias, reference_ir.name)) {
                        for (gen.locals.items) |local| {
                            if (std.mem.eql(u8, local.name, alias)) return .{ .spec = alias, .own = true };
                        }
                        return .{ .spec = alias, .own = false };
                    }
                }
                if (reference_ir.source == .state) {
                    return .{ .spec = "", .own = true };
                }
                if (reference_ir.source != .local) return null;
                for (gen.locals.items) |local| {
                    if (std.mem.eql(u8, local.name, reference_ir.name)) return null;
                }
                if (gen.module.wire) |wire| {
                    if (wire.kind == .family and wire.state_name != null and std.mem.eql(u8, wire.state_name.?, reference_ir.name)) {
                        return .{ .spec = "", .own = true };
                    }
                }
                if (gen.foreign) |foreign| {
                    if (foreign.state_local) |state| {
                        if (std.mem.eql(u8, state, reference_ir.name)) return .{ .spec = "", .own = false };
                    }
                }
                return null;
            },
            .member => |member| {
                if (member.property != .string) return null;
                if (member.object.* == .member) {
                    const stores = member.object.member;
                    if (stores.property == .string and std.mem.eql(u8, stores.property.string, "stores") and stores.object.* == .reference and std.mem.eql(u8, stores.object.reference.name, "Publr")) {
                        return .{ .spec = std.fmt.allocPrint(gen.arena, "{s}::", .{member.property.string}) catch return null, .own = false };
                    }
                }
                const base = gen.wire_state_path(member.object) orelse return null;
                const path = if (std.mem.endsWith(u8, base.spec, "::"))
                    std.fmt.allocPrint(gen.arena, "{s}{s}", .{ base.spec, member.property.string }) catch return null
                else if (base.spec.len == 0)
                    member.property.string
                else
                    std.fmt.allocPrint(gen.arena, "{s}.{s}", .{ base.spec, member.property.string }) catch return null;
                return .{ .spec = path, .own = base.own };
            },
            else => return null,
        }
    }

    /// `Publr.dataset("value")` → `value`.
    fn dataset_name(gen: *Generator, e: *const ExpressionIR) ?[]const u8 {
        _ = gen;
        if (e.* != .call) return null;
        const call = e.call;
        if (call.arguments.len != 1) return null;
        if (call.callee.* != .member) return null;
        const member = call.callee.member;
        if (member.property != .string or !std.mem.eql(u8, member.property.string, "dataset")) return null;
        if (member.object.* != .reference or !std.mem.eql(u8, member.object.reference.name, "Publr")) return null;
        const argument = call.arguments[0];
        if (argument.* != .literal) return null;
        return if (argument.literal == .string) argument.literal.string else null;
    }

    /// A literal as wire text: strings quoted `'…'` with `\` and `'` escaped,
    /// everything else as its JSON text.
    fn wire_literal(gen: *Generator, e: *const ExpressionIR) Error!?[]const u8 {
        if (e.* != .literal) return null;
        return switch (e.literal) {
            .string => |text| blk: {
                var out: std.Io.Writer.Allocating = .init(gen.arena);
                try out.writer.writeByte('\'');
                for (text) |char| {
                    if (char == '\\' or char == '\'') try out.writer.writeByte('\\');
                    try out.writer.writeByte(char);
                }
                try out.writer.writeByte('\'');
                break :blk out.written();
            },
            .number => |number| try util.numberToString(gen.arena, number),
            .boolean => |b| if (b) "true" else "false",
            .null => null,
        };
    }

    /// The right side of a wire comparison: a literal or a dataset read.
    fn wire_rhs(gen: *Generator, e: *const ExpressionIR) Error!?[]const u8 {
        if (gen.dataset_name(e)) |name| {
            return try std.fmt.allocPrint(gen.arena, "@{s}", .{name});
        }
        return gen.wire_literal(e);
    }

    /// The expression as a wire spec, or null when it does not read state.
    fn wire_spec(gen: *Generator, e: *const ExpressionIR) Error!?Wired {
        if (gen.wire_state_path(e)) |path| {
            if (path.spec.len == 0) return null; // the bare state object is not a wire
            return .{ .spec = try std.fmt.allocPrint(gen.arena, "${s}", .{path.spec}), .own = path.own };
        }

        switch (e.*) {
            // The empty-template string coercion (`` `${state.n}` ``); a
            // template with text concatenates (`'More for ' + $row.title`).
            .template => |template_ir| {
                var inner: ?*const ExpressionIR = null;
                var plain = true;
                for (template_ir.parts) |part| {
                    switch (part) {
                        .string => |text| if (text.len != 0) {
                            plain = false;
                        },
                        .expression => |part_expr| if (inner == null) {
                            inner = part_expr;
                        } else {
                            plain = false;
                        },
                    }
                }
                if (plain) return if (inner) |expr| gen.wire_spec(expr) else null;

                var joined: std.Io.Writer.Allocating = .init(gen.arena);
                var own = false;
                var any_wire = false;
                for (template_ir.parts) |part| {
                    const operand = switch (part) {
                        .string => |text| blk: {
                            if (text.len == 0) continue;
                            if (std.mem.indexOfScalar(u8, text, '\'') != null) return null;
                            break :blk try std.fmt.allocPrint(gen.arena, "'{s}'", .{text});
                        },
                        .expression => |part_expr| blk: {
                            if (try gen.wire_spec(part_expr)) |wired| {
                                any_wire = true;
                                own = own or wired.own;
                                break :blk if (std.mem.indexOfAny(u8, wired.spec, " ()") == null) wired.spec else try std.fmt.allocPrint(gen.arena, "({s})", .{wired.spec});
                            }
                            const literal = (try gen.wire_literal(part_expr)) orelse return null;
                            break :blk literal;
                        },
                    };
                    if (joined.written().len > 0) try joined.writer.writeAll(" + ");
                    try joined.writer.writeAll(operand);
                }
                if (!any_wire) return null;
                return .{ .spec = joined.written(), .own = own };
            },
            .unary => |unary| {
                if (!std.mem.eql(u8, unary.operator, "!")) return null;
                const inner = (try gen.wire_spec(unary.argument)) orelse return null;
                return .{ .spec = try gen.invert_wire(inner.spec), .own = inner.own };
            },
            // `state.values.includes(Publr.dataset("value"))` → membership.
            .call => |call| {
                if (call.arguments.len != 1) return null;
                if (call.callee.* != .member) return null;
                const member = call.callee.member;
                if (member.property != .string or !std.mem.eql(u8, member.property.string, "includes")) return null;
                const receiver = gen.wire_state_path(member.object) orelse return null;
                if (receiver.spec.len == 0) return null;
                const rhs = (try gen.wire_rhs(call.arguments[0])) orelse return null;
                return .{
                    .spec = try std.fmt.allocPrint(gen.arena, "${s} contains {s}", .{ receiver.spec, rhs }),
                    .own = receiver.own,
                };
            },
            .operation => |operation_ir| {
                const operator = operation_ir.operator;
                const left = gen.wire_state_path(operation_ir.left) orelse return null;
                if (left.spec.len == 0) return null;

                const mapped: ?[]const u8 = if (std.mem.eql(u8, operator, "===") or std.mem.eql(u8, operator, "=="))
                    "=="
                else if (std.mem.eql(u8, operator, "!==") or std.mem.eql(u8, operator, "!="))
                    "!="
                else if (std.mem.eql(u8, operator, ">=") or std.mem.eql(u8, operator, "<=") or
                    std.mem.eql(u8, operator, ">") or std.mem.eql(u8, operator, "<"))
                    operator
                else if (std.mem.eql(u8, operator, "||"))
                    "~"
                else
                    null;

                if (mapped) |op| {
                    const rhs = (try gen.wire_rhs(operation_ir.right)) orelse return null;
                    return .{
                        .spec = try std.fmt.allocPrint(gen.arena, "${s} {s} {s}", .{ left.spec, op, rhs }),
                        .own = left.own,
                    };
                }
                return null;
            },
            // Ternary with literal arms: the two-arm bind form `cond -> a ~ b`.
            .conditional => |conditional| {
                const test_wire = (try gen.wire_spec(conditional.@"test")) orelse return null;
                const consequent = (try gen.wire_literal(conditional.consequent)) orelse return null;
                const alternate = (try gen.wire_literal(conditional.alternate)) orelse return null;
                return .{
                    .spec = try std.fmt.allocPrint(gen.arena, "{s} -> {s} ~ {s}", .{ test_wire.spec, consequent, alternate }),
                    .own = test_wire.own,
                };
            },
            else => return null,
        }
    }

    /// Preserve numeric negation: NaN makes !(a <= b) differ from a > b.
    fn invert_wire(gen: *Generator, spec: []const u8) Error![]const u8 {
        if (std.mem.startsWith(u8, spec, "not ")) {
            return spec[4..];
        }
        const pairs = [_][2][]const u8{
            .{ " != ", " == " },
            .{ " == ", " != " },
        };
        for (pairs) |pair| {
            if (std.mem.indexOf(u8, spec, pair[0])) |index| {
                return std.fmt.allocPrint(gen.arena, "{s}{s}{s}", .{
                    spec[0..index],
                    pair[1],
                    spec[index + pair[0].len ..],
                });
            }
        }
        return std.fmt.allocPrint(gen.arena, "not {s}", .{spec});
    }

    /// A class layer written as a ternary over state with literal string
    /// arms — the `cond -> a ~ b` class-wire group (class names unquoted).
    fn class_wire_group(gen: *Generator, e: *const ExpressionIR) Error!?Wired {
        if (e.* != .conditional) return null;
        const conditional = e.conditional;
        const test_wire = (try gen.wire_spec(conditional.@"test")) orelse return null;
        const consequent = string_of_literal(conditional.consequent) orelse return null;
        const alternate = string_of_literal(conditional.alternate) orelse return null;
        const when_true = std.mem.trim(u8, consequent, " ");
        const when_false = std.mem.trim(u8, alternate, " ");

        if (when_true.len == 0 and when_false.len == 0) return null;
        if (when_true.len != 0 and when_false.len != 0) {
            return .{ .spec = try std.fmt.allocPrint(gen.arena, "{s} -> {s} ~ {s}", .{ test_wire.spec, when_true, when_false }), .own = test_wire.own };
        }
        if (when_true.len != 0) {
            return .{ .spec = try std.fmt.allocPrint(gen.arena, "{s} -> {s}", .{ test_wire.spec, when_true }), .own = test_wire.own };
        }
        return .{
            .spec = try std.fmt.allocPrint(gen.arena, "{s} -> {s}", .{ try gen.invert_wire(test_wire.spec), when_false }),
            .own = test_wire.own,
        };
    }

    // -- prop wires ---------------------------------------------------------
    //
    // A component called inside a list template receives its row-dependent
    // props as wires (`publr_bind_<prop>`) with placeholder values. Every use
    // of such a prop re-emits the wire, composed at render time: the value is
    // evaluated at compile time for each value of the finite props it reads
    // (booleans, small enums), and the results become a match over each wired
    // prop's wire (`rt.wire_match`); unbounded props (strings, numbers, large
    // enums) stay operands (`($row.title)`), compared or concatenated in the
    // wire. Null when the expression reads no wirable prop, reads anything
    // else, or needs what the wire language cannot say.

    const PropWireMode = enum {
        /// A value spec (`data-p-text`, `data-p-bind`, `data-p-if`, a callee's
        /// `publr_bind_*`).
        value,
        /// A `data-p-class` group: the class lists become arms keyed by index,
        /// so each swap removes the lists of the other arms.
        classes,
    };

    const Const = union(enum) { string: []const u8, boolean: bool, number: f64, absent };

    const PropEval = union(enum) {
        constant: Const,
        /// Zig code of type `[]const u8`: a wire spec.
        spec: []const u8,
    };

    const Assigned = struct { name: []const u8, value: Const };

    /// Enums larger than this are unbounded operands, not matched per value.
    const prop_domain_max = 24;

    /// The runtime wire (Zig code of type `?[]const u8`, null when no prop it
    /// reads is wired) of a prop-derived expression; see above.
    fn prop_wire(gen: *Generator, e: *const ExpressionIR, mode: PropWireMode) Error!?[]const u8 {
        if (gen.prop_wire_skip) |skip| if (skip == e) return null;

        var names: std.ArrayList([]const u8) = .empty;
        if (!try gen.prop_dependencies(e, &names, 0)) return null;
        if (names.items.len == 0) return null;

        var finite: std.ArrayList(Field) = .empty;
        for (names.items) |name| {
            const field = find_field(gen.module.props, name).?;
            if (try gen.prop_domain(field) != null) try finite.append(gen.arena, field);
        }

        var classes: std.ArrayList([]const u8) = .empty;
        var assignment: std.ArrayList(Assigned) = .empty;
        const tree = (try gen.prop_tree(e, finite.items, &assignment, if (mode == .classes) &classes else null)) orelse return null;

        var any: std.Io.Writer.Allocating = .init(gen.arena);
        for (names.items, 0..) |name, index| {
            try any.writer.print("{s}props.publr_bind_{s} != null", .{ if (index == 0) "" else " or ", name });
        }
        gen.props_used = true;
        gen.arena_used = true;

        if (mode == .value) {
            return try std.fmt.allocPrint(gen.arena, "(if ({s}) {s} else @as(?[]const u8, null))", .{ any.written(), tree });
        }

        var arms: std.Io.Writer.Allocating = .init(gen.arena);
        try arms.writer.writeAll(" {");
        for (classes.items, 0..) |class, index| {
            try arms.writer.print("{s} '{d}': {s}", .{ if (index == 0) "" else ",", index, class });
        }
        try arms.writer.writeAll(" }");
        const capture = try gen.fresh_prop("publr_classes");
        return try std.fmt.allocPrint(
            gen.arena,
            "(if ({s}) (if ({s}) |{s}| @as(?[]const u8, rt.concat(arena, &.{{ rt.wire_group(arena, {s}), {s} }})) else @as(?[]const u8, null)) else @as(?[]const u8, null))",
            .{ any.written(), tree, capture, capture, try zig_string(gen.arena, arms.written()) },
        );
    }

    /// The finite values a prop takes — booleans, enums up to
    /// `prop_domain_max`, and `absent` for optionals; null when unbounded.
    fn prop_domain(gen: *Generator, field: Field) Error!?[]const Const {
        var values: std.ArrayList(Const) = .empty;
        switch (field.type.unwrapped()) {
            .boolean => {
                try values.append(gen.arena, .{ .boolean = true });
                try values.append(gen.arena, .{ .boolean = false });
            },
            .enumeration => |e| {
                if (e.values.len > prop_domain_max) return null;
                for (e.values) |tag| try values.append(gen.arena, .{ .string = tag });
            },
            else => return null,
        }
        if (field.type.is_optional()) try values.append(gen.arena, .absent);
        return values.items;
    }

    /// Collects the wirable props `e` reads, through the component's own
    /// bindings and finite maps; false when it reads anything else.
    fn prop_dependencies(gen: *Generator, e: *const ExpressionIR, names: *std.ArrayList([]const u8), depth: u32) Error!bool {
        if (depth > 16) return false;
        switch (e.*) {
            .literal, .absent => return true,
            .reference => |reference_ir| switch (reference_ir.source) {
                .prop => {
                    const field = find_field(gen.module.props, reference_ir.name) orelse return false;
                    if (!field.bind_transport) return false;
                    if (!util.containsString(names.items, reference_ir.name)) try names.append(gen.arena, reference_ir.name);
                    return true;
                },
                .local => {
                    if (gen.binding_of(reference_ir.name)) |initializer| return gen.prop_dependencies(initializer, names, depth + 1);
                    return gen.finite_map_named(reference_ir.name) != null;
                },
                else => return false,
            },
            .member => |member| switch (member.property) {
                .string => return false,
                .number => return gen.prop_dependencies(member.object, names, depth + 1),
                .expression => |key| return try gen.prop_dependencies(member.object, names, depth + 1) and
                    try gen.prop_dependencies(key, names, depth + 1),
            },
            .unary => |unary| return gen.prop_dependencies(unary.argument, names, depth + 1),
            .operation => |operation_ir| return try gen.prop_dependencies(operation_ir.left, names, depth + 1) and
                try gen.prop_dependencies(operation_ir.right, names, depth + 1),
            .conditional => |c| return try gen.prop_dependencies(c.@"test", names, depth + 1) and
                try gen.prop_dependencies(c.consequent, names, depth + 1) and
                try gen.prop_dependencies(c.alternate, names, depth + 1),
            .template => |template_ir| {
                for (template_ir.parts) |part| switch (part) {
                    .string => {},
                    .expression => |part_expr| if (!try gen.prop_dependencies(part_expr, names, depth + 1)) return false,
                };
                return true;
            },
            else => return false,
        }
    }

    /// The module's finite map of that name, unless a local shadows it.
    fn finite_map_named(gen: *Generator, name: []const u8) ?[]const Type.MapEntry {
        for (gen.locals.items) |local| {
            if (std.mem.eql(u8, local.source_name orelse local.name, name)) return null;
        }
        for (gen.module.finite_maps) |map| {
            if (std.mem.eql(u8, map.name, name)) return map.entries;
        }
        return null;
    }

    /// The decision tree over the finite props (Zig code of type
    /// `?[]const u8`): per prop, a match over its wire when wired, a switch
    /// on its value otherwise; at the leaves, the expression's value under
    /// the assignment as wire text (a class list's index in `classes` mode).
    fn prop_tree(gen: *Generator, e: *const ExpressionIR, finite: []const Field, assignment: *std.ArrayList(Assigned), classes: ?*std.ArrayList([]const u8)) Error!?[]const u8 {
        if (assignment.items.len == finite.len) {
            const result = (try gen.prop_eval(e, assignment.items, 0)) orelse return null;
            switch (result) {
                .constant => |value| {
                    if (classes) |list| {
                        const class = switch (value) {
                            .string => |text| std.mem.trim(u8, text, " "),
                            .absent => "",
                            else => return null,
                        };
                        const index = for (list.items, 0..) |known, index| {
                            if (std.mem.eql(u8, known, class)) break index;
                        } else blk: {
                            try list.append(gen.arena, class);
                            break :blk list.items.len - 1;
                        };
                        return try std.fmt.allocPrint(gen.arena, "@as(?[]const u8, \"'{d}'\")", .{index});
                    }
                    if (value == .absent) return "@as(?[]const u8, null)";
                    return try std.fmt.allocPrint(gen.arena, "@as(?[]const u8, {s})", .{try zig_string(gen.arena, (try gen.const_wire_text(value)) orelse return null)});
                },
                .spec => |code| {
                    if (classes != null) return null;
                    return try std.fmt.allocPrint(gen.arena, "@as(?[]const u8, {s})", .{code});
                },
            }
        }

        const field = finite[assignment.items.len];
        const domain = (try gen.prop_domain(field)).?;
        var subs = try gen.arena.alloc([]const u8, domain.len);
        for (domain, 0..) |value, index| {
            try assignment.append(gen.arena, .{ .name = field.name, .value = value });
            defer _ = assignment.pop();
            subs[index] = (try gen.prop_tree(e, finite, assignment, classes)) orelse return null;
        }

        // A tree that maps each value to itself is the wire itself.
        const identity = classes == null and !field.type.is_optional() and for (domain, subs) |value, sub| {
            const text = (try gen.const_wire_text(value)) orelse break false;
            const own = try std.fmt.allocPrint(gen.arena, "@as(?[]const u8, {s})", .{try zig_string(gen.arena, text)});
            if (!std.mem.eql(u8, own, sub)) break false;
        } else true;

        var arms: std.Io.Writer.Allocating = .init(gen.arena);
        for (domain, subs) |value, sub| {
            const key: []const u8 = switch (value) {
                .boolean => |b| if (b) "true" else "false",
                .string => |tag| (try gen.const_wire_text(value)) orelse return gen.fail("enum value {s} cannot be a wire key", .{tag}),
                .absent => "_",
                .number => unreachable,
            };
            try arms.writer.print(" .{{ .key = {s}, .value = {s} }},", .{ try zig_string(gen.arena, key), sub });
        }

        const value_code = try std.fmt.allocPrint(gen.arena, "props.{f}", .{std.zig.fmtId(field.name)});
        const unwrapped = if (field.type.is_optional()) try gen.fresh_prop("publr_value") else value_code;
        const switched = switch (field.type.unwrapped()) {
            .boolean => try std.fmt.allocPrint(gen.arena, "(if ({s}) {s} else {s})", .{ unwrapped, subs[0], subs[1] }),
            .enumeration => |enumeration| blk: {
                var cases: std.Io.Writer.Allocating = .init(gen.arena);
                for (enumeration.values, 0..) |tag, index| {
                    try cases.writer.print(" .@\"{s}\" => {s},", .{ tag, subs[index] });
                }
                break :blk try std.fmt.allocPrint(gen.arena, "(switch ({s}) {{{s} }})", .{ unwrapped, cases.written() });
            },
            else => unreachable,
        };
        const selected = if (field.type.is_optional())
            try std.fmt.allocPrint(gen.arena, "(if ({s}) |{s}| {s} else {s})", .{ value_code, unwrapped, switched, subs[subs.len - 1] })
        else
            switched;

        const capture = try gen.fresh_prop("publr_wire");
        if (identity) {
            return try std.fmt.allocPrint(gen.arena, "(if (props.publr_bind_{s}) |{s}| @as(?[]const u8, {s}) else {s})", .{ field.name, capture, capture, selected });
        }
        return try std.fmt.allocPrint(gen.arena, "(if (props.publr_bind_{s}) |{s}| @as(?[]const u8, rt.wire_match(arena, {s}, &.{{{s} }})) else {s})", .{
            field.name,
            capture,
            capture,
            arms.written(),
            selected,
        });
    }

    /// A compile-time value as wire text: strings quoted (with whichever
    /// quote they do not contain), `null` when absent.
    fn const_wire_text(gen: *Generator, value: Const) Error!?[]const u8 {
        return switch (value) {
            .string => |text| blk: {
                const quote: u8 = if (std.mem.indexOfScalar(u8, text, '\'') == null) '\'' else if (std.mem.indexOfScalar(u8, text, '"') == null) '"' else break :blk null;
                break :blk try std.fmt.allocPrint(gen.arena, "{c}{s}{c}", .{ quote, text, quote });
            },
            .boolean => |b| if (b) "true" else "false",
            .number => |n| try util.numberToString(gen.arena, n),
            .absent => "null",
        };
    }

    fn const_truthy(value: Const) bool {
        return switch (value) {
            .string => |text| text.len != 0,
            .boolean => |b| b,
            .number => |n| n != 0 and !std.math.isNan(n),
            .absent => false,
        };
    }

    fn const_equal(left: Const, right: Const) bool {
        return switch (left) {
            .string => |a| right == .string and std.mem.eql(u8, a, right.string),
            .boolean => |a| right == .boolean and a == right.boolean,
            .number => |a| right == .number and a == right.number,
            .absent => right == .absent,
        };
    }

    /// A wire operand for a result: a spec grouped, a constant as its text.
    fn prop_operand(gen: *Generator, value: PropEval) Error!?[]const u8 {
        return switch (value) {
            .spec => |code| try std.fmt.allocPrint(gen.arena, "rt.wire_group(arena, {s})", .{code}),
            .constant => |c| if (try gen.const_wire_text(c)) |text| try zig_string(gen.arena, text) else null,
        };
    }

    /// `e` under an assignment of its finite props: a constant, or a spec
    /// over its unbounded props; null when the wire language cannot say it.
    fn prop_eval(gen: *Generator, e: *const ExpressionIR, assignment: []const Assigned, depth: u32) Error!?PropEval {
        if (depth > 16) return null;
        switch (e.*) {
            .literal => |literal| return .{ .constant = switch (literal) {
                .string => |text| .{ .string = text },
                .number => |n| .{ .number = n },
                .boolean => |b| .{ .boolean = b },
                .null => .absent,
            } },
            .absent => return .{ .constant = .absent },
            .reference => |reference_ir| switch (reference_ir.source) {
                .prop => {
                    for (assignment) |assigned| {
                        if (std.mem.eql(u8, assigned.name, reference_ir.name)) return .{ .constant = assigned.value };
                    }
                    return .{ .spec = try std.fmt.allocPrint(gen.arena, "rt.wire_value(arena, props.publr_bind_{s}, props.{f})", .{ reference_ir.name, std.zig.fmtId(reference_ir.name) }) };
                },
                .local => {
                    const initializer = gen.binding_of(reference_ir.name) orelse return null;
                    return gen.prop_eval(initializer, assignment, depth + 1);
                },
                else => return null,
            },
            .member => |member| {
                if (member.object.* != .reference) return null;
                const entries = gen.finite_map_named(member.object.reference.name) orelse return null;
                const key: Const = switch (member.property) {
                    .string => return null,
                    .number => |n| .{ .number = n },
                    .expression => |key_expr| switch ((try gen.prop_eval(key_expr, assignment, depth + 1)) orelse return null) {
                        .constant => |c| c,
                        .spec => return null,
                    },
                };
                if (key != .string) return .{ .constant = .absent };
                return .{ .constant = if (finite_value(entries, key.string)) |value| .{ .string = value } else .absent };
            },
            .unary => |unary| {
                const argument = (try gen.prop_eval(unary.argument, assignment, depth + 1)) orelse return null;
                if (std.mem.eql(u8, unary.operator, "!")) return switch (argument) {
                    .constant => |c| .{ .constant = .{ .boolean = !const_truthy(c) } },
                    .spec => |code| .{ .spec = try std.fmt.allocPrint(gen.arena, "rt.concat(arena, &.{{ \"not \", rt.wire_group(arena, {s}) }})", .{code}) },
                };
                if (std.mem.eql(u8, unary.operator, "-") and argument == .constant and argument.constant == .number) {
                    return .{ .constant = .{ .number = -argument.constant.number } };
                }
                return null;
            },
            .operation => |operation_ir| {
                const operator = operation_ir.operator;
                const left = (try gen.prop_eval(operation_ir.left, assignment, depth + 1)) orelse return null;

                if (std.mem.eql(u8, operator, "&&") or std.mem.eql(u8, operator, "||") or std.mem.eql(u8, operator, "??")) {
                    const c = switch (left) {
                        .constant => |c| c,
                        .spec => return null,
                    };
                    const take_left = if (std.mem.eql(u8, operator, "&&")) !const_truthy(c) else if (std.mem.eql(u8, operator, "||")) const_truthy(c) else c != .absent;
                    return if (take_left) left else gen.prop_eval(operation_ir.right, assignment, depth + 1);
                }

                const right = (try gen.prop_eval(operation_ir.right, assignment, depth + 1)) orelse return null;
                const equality = std.mem.eql(u8, operator, "===") or std.mem.eql(u8, operator, "==");
                const inequality = std.mem.eql(u8, operator, "!==") or std.mem.eql(u8, operator, "!=");

                if (equality or inequality) {
                    if (left == .constant and right == .constant) {
                        return .{ .constant = .{ .boolean = const_equal(left.constant, right.constant) == equality } };
                    }
                    if (left == .spec and right == .spec) return null;
                    const spec = if (left == .spec) left.spec else right.spec;
                    const other = if (left == .spec) right.constant else left.constant;
                    const literal = (try gen.const_wire_text(other)) orelse return null;
                    return .{ .spec = try std.fmt.allocPrint(gen.arena, "rt.concat(arena, &.{{ rt.wire_group(arena, {s}), {s} }})", .{
                        spec,
                        try zig_string(gen.arena, try std.fmt.allocPrint(gen.arena, " {s} {s}", .{ if (equality) "==" else "!=", literal })),
                    }) };
                }

                if (std.mem.eql(u8, operator, "+")) {
                    if (left == .constant and right == .constant) {
                        if (left.constant == .number and right.constant == .number) return .{ .constant = .{ .number = left.constant.number + right.constant.number } };
                        if (left.constant == .string and right.constant == .string) {
                            return .{ .constant = .{ .string = try std.fmt.allocPrint(gen.arena, "{s}{s}", .{ left.constant.string, right.constant.string }) } };
                        }
                        return null;
                    }
                    return .{ .spec = try std.fmt.allocPrint(gen.arena, "rt.concat(arena, &.{{ {s}, \" + \", {s} }})", .{
                        (try gen.prop_operand(left)) orelse return null,
                        (try gen.prop_operand(right)) orelse return null,
                    }) };
                }
                return null;
            },
            .conditional => |c| {
                const test_value = (try gen.prop_eval(c.@"test", assignment, depth + 1)) orelse return null;
                switch (test_value) {
                    .constant => |value| return gen.prop_eval(if (const_truthy(value)) c.consequent else c.alternate, assignment, depth + 1),
                    .spec => |code| {
                        var arms: [2][]const u8 = undefined;
                        for ([_]*const ExpressionIR{ c.consequent, c.alternate }, 0..) |arm, index| {
                            arms[index] = switch ((try gen.prop_eval(arm, assignment, depth + 1)) orelse return null) {
                                .spec => |arm_code| arm_code,
                                .constant => |value| if (value == .absent) "null" else try zig_string(gen.arena, (try gen.const_wire_text(value)) orelse return null),
                            };
                        }
                        return .{ .spec = try std.fmt.allocPrint(gen.arena, "rt.wire_match(arena, {s}, &.{{ .{{ .key = \"true\", .value = {s} }}, .{{ .key = \"false\", .value = {s} }} }})", .{ code, arms[0], arms[1] }) };
                    },
                }
            },
            .template => |template_ir| {
                var text: std.Io.Writer.Allocating = .init(gen.arena);
                var operands: std.ArrayList([]const u8) = .empty;
                var all_constant = true;
                for (template_ir.parts) |part| {
                    const value: PropEval = switch (part) {
                        .string => |literal| .{ .constant = .{ .string = literal } },
                        .expression => |part_expr| (try gen.prop_eval(part_expr, assignment, depth + 1)) orelse return null,
                    };
                    switch (value) {
                        .constant => |c| switch (c) {
                            .string => |literal| try text.writer.writeAll(literal),
                            .number => |n| try text.writer.writeAll(try util.numberToString(gen.arena, n)),
                            else => return null,
                        },
                        .spec => |code| {
                            all_constant = false;
                            if (text.written().len > 0) {
                                try operands.append(gen.arena, try zig_string(gen.arena, (try gen.const_wire_text(.{ .string = text.written() })) orelse return null));
                                text = .init(gen.arena);
                            }
                            try operands.append(gen.arena, try std.fmt.allocPrint(gen.arena, "rt.wire_group(arena, {s})", .{code}));
                        },
                    }
                }
                if (all_constant) return .{ .constant = .{ .string = text.written() } };
                if (text.written().len > 0) {
                    try operands.append(gen.arena, try zig_string(gen.arena, (try gen.const_wire_text(.{ .string = text.written() })) orelse return null));
                }
                var joined: std.Io.Writer.Allocating = .init(gen.arena);
                for (operands.items, 0..) |operand, index| {
                    if (index > 0) try joined.writer.writeAll(" \" + \",");
                    try joined.writer.print(" {s},", .{operand});
                }
                return .{ .spec = try std.fmt.allocPrint(gen.arena, "rt.concat(arena, &.{{{s} }})", .{joined.written()}) };
            },
            else => return null,
        }
    }

    // -- expressions as Zig values --

    /// The expression as a typed Zig expression.
    fn expression(gen: *Generator, e: *const ExpressionIR) Error!Lowered {
        const lowered = try gen.expression_value(e);
        if (lowered.type.is_optional()) for (gen.present_values.items) |code| {
            if (util.eql(code, lowered.code)) return .{
                .code = try std.fmt.allocPrint(gen.arena, "({s}).?", .{lowered.code}),
                .type = lowered.type.unwrapped(),
            };
        };
        return lowered;
    }

    fn expression_value(gen: *Generator, e: *const ExpressionIR) Error!Lowered {
        switch (e.*) {
            .literal => |literal| return switch (literal) {
                .string => |s| .{ .code = try zig_string(gen.arena, s), .type = .string },
                .number => |number| .{
                    .code = if (std.math.isNan(number)) "std.math.nan(f64)" else if (std.math.isInf(number)) (if (number > 0) "std.math.inf(f64)" else "(-std.math.inf(f64))") else if (number == 0 and std.math.signbit(number)) "@as(f64, -0.0)" else try std.fmt.allocPrint(gen.arena, "@as(f64, {d})", .{number}),
                    .type = .number,
                },
                .boolean => |b| .{ .code = if (b) "true" else "false", .type = .boolean },
                .null => .{ .code = "null", .type = .null },
            },
            .call => |call| {
                if (call.callee.* == .reference) {
                    const name = call.callee.reference.name;
                    for (gen.module.bindings) |binding| {
                        if (!util.eql(binding.name, name) or binding.value.* != .function) continue;
                        const function = binding.value.function;
                        if (function.parameters.len != call.arguments.len) return gen.fail("helper {s}: argument count mismatch", .{name});
                        var args: std.ArrayList(Lowered) = .empty;
                        for (call.arguments) |argument| try args.append(gen.arena, try gen.expression(argument));
                        const count = gen.locals.items.len;
                        defer gen.locals.shrinkRetainingCapacity(count);
                        var prefix: std.Io.Writer.Allocating = .init(gen.arena);
                        const label = try gen.fresh("call");
                        for (function.parameters, args.items) |parameter, argument| {
                            const local = try gen.fresh("arg");
                            try prefix.writer.print("const {s} = {s}; _ = &{s}; ", .{ local, argument.code, local });
                            try gen.locals.append(gen.arena, .{ .name = local, .source_name = parameter, .type = argument.type });
                        }
                        const result = try gen.expression(function.body);
                        return .{ .code = try std.fmt.allocPrint(gen.arena, "{s}: {{ {s}break :{s} {s}; }}", .{ label, prefix.written(), label, result.code }), .type = result.type };
                    }
                }
                // The publr-dom render helpers with exact runtime twins.
                if (call.callee.* == .member) {
                    const callee_member = call.callee.member;
                    const method = if (callee_member.property == .string) callee_member.property.string else "";

                    // `Math.max` / `Math.min` over numbers.
                    if (callee_member.object.* == .reference and
                        std.mem.eql(u8, callee_member.object.reference.name, "Math") and
                        (std.mem.eql(u8, method, "max") or std.mem.eql(u8, method, "min")))
                    {
                        if (call.arguments.len != 2) return gen.fail("Math.{s} takes two arguments", .{method});
                        const left = try gen.expression(call.arguments[0]);
                        const right = try gen.expression(call.arguments[1]);
                        if (left.type != .number or right.type != .number) {
                            return gen.fail("Math.{s} requires numeric arguments", .{method});
                        }
                        return .{
                            .code = try std.fmt.allocPrint(gen.arena, "rt.number_{s}({s}, {s})", .{ method, left.code, right.code }),
                            .type = .number,
                        };
                    }

                    // `array.findIndex((item) => item.f === v)` → a labeled search
                    // loop returning the index, or -1, as a TypeScript number.
                    if (std.mem.eql(u8, method, "findIndex")) {
                        if (call.arguments.len != 1 or call.arguments[0].* != .function) {
                            return gen.fail("findIndex takes a one-parameter arrow function", .{});
                        }
                        const function = call.arguments[0].function;
                        if (function.parameters.len != 1) return gen.fail("findIndex takes a one-parameter arrow function", .{});
                        const parameter = function.parameters[0];

                        const subject = try gen.expression(callee_member.object);
                        const item_type: Type = switch (subject.type) {
                            .array => |item_fields| .{ .item = item_fields },
                            .strings => .string,
                            else => return gen.fail("findIndex on a {s} is not lowered", .{@tagName(subject.type)}),
                        };

                        try gen.locals.append(gen.arena, .{ .name = parameter, .type = item_type });
                        const predicate = try gen.truthy(try gen.expression(function.body));
                        _ = gen.locals.pop();

                        const label = try gen.fresh("publr_find");
                        const index_name = try gen.fresh("publr_index");
                        return .{
                            .code = try std.fmt.allocPrint(
                                gen.arena,
                                "{s}: {{ for ({s}, 0..) |{s}, {s}| {{ if ({s}) break :{s} @as(f64, @floatFromInt({s})); }} break :{s} @as(f64, -1); }}",
                                .{ label, subject.code, parameter, index_name, predicate, label, index_name, label },
                            ),
                            .type = .number,
                        };
                    }
                }
                if (call.callee.* == .reference) {
                    const callee_name = call.callee.reference.name;
                    if (gen.is_publr_jsx_import(callee_name)) {
                        if (std.mem.eql(u8, callee_name, "initials") and call.arguments.len == 1) {
                            const arg = try gen.expression(call.arguments[0]);
                            const text = switch (arg.type) {
                                .string => arg.code,
                                .opt_string => try std.fmt.allocPrint(gen.arena, "({s} orelse \"\")", .{arg.code}),
                                else => return gen.fail("initials() takes a string, got a {s}", .{@tagName(arg.type)}),
                            };
                            gen.arena_used = true;
                            return .{
                                .code = try std.fmt.allocPrint(gen.arena, "rt.initials(arena, {s})", .{text}),
                                .type = .string,
                            };
                        }
                        if (std.mem.eql(u8, callee_name, "gravatarUrl") and call.arguments.len == 2) {
                            const email = try gen.expression(call.arguments[0]);
                            const size = try gen.expression(call.arguments[1]);
                            if ((email.type != .string and email.type != .opt_string) or size.type != .number) {
                                return gen.fail("gravatarUrl() takes (email, size)", .{});
                            }
                            gen.arena_used = true;
                            return .{
                                .code = try std.fmt.allocPrint(gen.arena, "rt.gravatar_url(arena, {s}, {s})", .{ email.code, size.code }),
                                .type = .string,
                            };
                        }
                        return gen.fail("publr-dom's {s}() is not lowered", .{callee_name});
                    }
                }
                return gen.fail("expression kind \"call\" is not lowered here", .{});
            },
            // An empty array literal (`value ?? []`) is an empty string slice
            // unless a type assertion (`[] as Row[]`) gives its items.
            .array => |array| {
                if (array.items.len == 0) {
                    if (array.asserted) |spec| if (spec.fields != null) return gen.asserted_array(e, spec);
                    return .{ .code = "&.{}", .type = .strings };
                }
                return gen.fail("a non-empty array literal is not lowered", .{});
            },
            // `undefined` — an absent value; lowers exactly like the null literal
            // (`x === undefined` → a null check, an absent attribute is omitted).
            .absent => return .{ .code = "null", .type = .null },
            .reference => |reference_ir| return gen.reference(reference_ir.name, reference_ir.source),
            .member => |member| {
                const object = try gen.expression(member.object);

                if (member.property != .string) {
                    // `items[i]`: indexing a struct-array by an integer.
                    if (object.type == .array) {
                        const index = try gen.member_index(member.property);
                        if (index.type != .number) {
                            return gen.fail("an array index must be an integer, got a {s}", .{@tagName(index.type)});
                        }
                        return .{
                            .code = try std.fmt.allocPrint(gen.arena, "{s}[@intFromFloat({s})]", .{ object.code, index.code }),
                            .type = .{ .item = object.type.array },
                        };
                    }

                    // `value[0]` / `value[1]`: the tuple half of a BoxValue union.
                    if (object.type == .union_value) {
                        if (constant_index(member.property)) |tuple_index| {
                            if (tuple_index == 0 or tuple_index == 1) {
                                return .{
                                    .code = try std.fmt.allocPrint(
                                        gen.arena,
                                        "(switch ({s}) {{ .number_string_tuple => |publr_tuple| publr_tuple[{d}], else => unreachable }})",
                                        .{ object.code, tuple_index },
                                    ),
                                    .type = if (tuple_index == 0) .number else .string,
                                };
                            }
                        }
                        return gen.fail("only [0] and [1] index a union prop", .{});
                    }

                    // `SIZES[size]`: a finite map keyed by an enum expression.
                    if (object.type != .finite_map) {
                        return gen.fail("computed member access on a {s} is not lowered", .{@tagName(object.type)});
                    }

                    const key = try gen.member_index(member.property);

                    // `TONES[kind]` keyed by a string: an optional string,
                    // null when no entry matches (`TONES[kind] ?? "accent"`).
                    if (key.type == .string) {
                        return .{ .code = try gen.string_keyed_lookup(object.type.finite_map, key.code, null, null), .type = .opt_string };
                    }

                    if (key.type != .enumeration) {
                        return gen.fail("a finite map is keyed by a {s}; only enum and string keys are lowered", .{@tagName(key.type)});
                    }

                    return .{
                        .code = "",
                        .type = .{ .finite = .{
                            .entries = object.type.finite_map,
                            .key_code = key.code,
                            .key_enum = key.type.enumeration,
                        } },
                    };
                }

                const property_name = member.property.string;

                if (std.mem.eql(u8, property_name, "length")) {
                    switch (object.type) {
                        .array, .strings, .string => return .{
                            .code = try std.fmt.allocPrint(gen.arena, "@as(f64, @floatFromInt({s}.len))", .{object.code}),
                            .type = .number,
                        },
                        else => return gen.fail(".length of a {s}", .{@tagName(object.type)}),
                    }
                }

                switch (object.type) {
                    .item => |item_fields| {
                        const field_of_item = find_field(item_fields, property_name) orelse {
                            return gen.fail("no field \"{s}\" on the loop item", .{property_name});
                        };
                        return .{
                            .code = try std.fmt.allocPrint(gen.arena, "{s}.{s}", .{ object.code, property_name }),
                            .type = field_of_item.type,
                        };
                    },
                    else => return gen.fail("member \"{s}\" of a {s}", .{ property_name, @tagName(object.type) }),
                }
            },
            .unary => |unary| {
                const argument = try gen.expression(unary.argument);

                if (std.mem.eql(u8, unary.operator, "!")) {
                    return .{
                        .code = try std.fmt.allocPrint(gen.arena, "!{s}", .{try gen.truthy(argument)}),
                        .type = .boolean,
                    };
                }

                if (std.mem.eql(u8, unary.operator, "typeof")) {
                    if (argument.type != .union_value) {
                        return gen.fail("`typeof` on a {s} is not lowered", .{@tagName(argument.type)});
                    }
                    return .{ .code = argument.code, .type = .union_typeof };
                }

                if (std.mem.eql(u8, unary.operator, "-")) {
                    if (argument.type != .number) {
                        return gen.fail("unary `-` on a {s}", .{@tagName(argument.type)});
                    }
                    return .{
                        .code = try std.fmt.allocPrint(gen.arena, "(-{s})", .{argument.code}),
                        .type = .number,
                    };
                }

                return gen.fail("unary operator \"{s}\" is not lowered", .{unary.operator});
            },
            .operation => return gen.operation(e),
            .conditional => |conditional| {
                const test_code = try gen.truthy(try gen.expression(conditional.@"test"));
                const consequent = try gen.expression(conditional.consequent);
                const alternate = try gen.expression(conditional.alternate);

                return gen.select(test_code, consequent, alternate);
            },
            .template => return gen.template(e),
            .unsupported => |unsupported| return gen.fail("expression kind \"unsupported\" ({s}) is not lowered here", .{unsupported.feature}),
            else => return gen.fail("expression kind \"{s}\" is not lowered here", .{@tagName(e.*)}),
        }
    }

    /// An empty literal typed by its assertion: the item struct (and its
    /// enums) is declared at file scope and the literal is an empty slice of
    /// it.
    fn asserted_array(gen: *Generator, e: *const ExpressionIR, spec: *const analyze.PropSchema) Error!Lowered {
        for (gen.asserted_arrays.items) |entry| {
            if (entry.expression == e) return entry.lowered;
        }
        var schema: analyze.Schema = .init(gen.arena);
        const name = try gen.fresh("asserted");
        try schema.put(name, spec.*);
        var types: std.Io.Writer.Allocating = .init(gen.arena);
        const fields = try adapt_props(gen.arena, &schema, &types.writer, gen.module.name);
        try gen.asserted_types.appendSlice(gen.arena, types.written());
        const lowered: Lowered = .{
            .code = try std.fmt.allocPrint(gen.arena, "@as({s}, &.{{}})", .{fields[0].zig_type}),
            .type = fields[0].type,
        };
        try gen.asserted_arrays.append(gen.arena, .{ .expression = e, .lowered = lowered });
        return lowered;
    }

    /// A computed member property as a lowered index expression.
    fn member_index(gen: *Generator, property: compiler.MemberProperty) Error!Lowered {
        return switch (property) {
            .string => unreachable, // callers dispatch on != .string
            .number => |number| .{
                .code = try std.fmt.allocPrint(gen.arena, "@as(f64, {d})", .{number}),
                .type = .number,
            },
            .expression => |index_expr| try gen.expression(index_expr),
        };
    }

    fn reference(gen: *Generator, name: []const u8, source: compiler.ReferenceSource) Error!Lowered {
        switch (source) {
            .prop => {
                const prop = find_field(gen.module.props, name) orelse {
                    return gen.fail("reference to undeclared prop \"{s}\"", .{name});
                };
                gen.props_used = true;
                return .{
                    .code = try std.fmt.allocPrint(gen.arena, "props.{f}", .{std.zig.fmtId(name)}),
                    .type = prop.type,
                };
            },
            // A component-local `reactive()`'s state is referenced as source
            // "state"; a family's state is a plain local bound by import.
            .state => return .{ .code = "", .type = .state_root },
            .local => {
                var index = gen.locals.items.len;
                while (index > 0) {
                    index -= 1;
                    if (std.mem.eql(u8, gen.locals.items[index].source_name orelse gen.locals.items[index].name, name)) {
                        return .{ .code = gen.locals.items[index].name, .type = gen.locals.items[index].type };
                    }
                }

                if (gen.module.wire) |wire| {
                    for (wire.actions) |action| {
                        if (std.mem.eql(u8, action, name)) {
                            return .{ .code = try zig_string(gen.arena, name), .type = .action_name };
                        }
                    }
                    for (wire.refs) |ref| {
                        if (std.mem.eql(u8, ref, name)) {
                            return .{ .code = ref, .type = .ref_name };
                        }
                    }
                }

                if (gen.foreign) |foreign| {
                    if (foreign.state_local) |state| {
                        if (std.mem.eql(u8, state, name)) {
                            return .{ .code = "", .type = .state_root };
                        }
                    }
                    for (foreign.actions) |action| {
                        if (std.mem.eql(u8, action.local, name)) {
                            return .{ .code = try zig_string(gen.arena, action.name), .type = .action_name };
                        }
                    }
                    for (foreign.refs) |ref| {
                        if (std.mem.eql(u8, ref.local, name)) {
                            return .{ .code = ref.name, .type = .ref_name };
                        }
                    }
                }

                for (gen.module.finite_maps) |map| {
                    if (std.mem.eql(u8, map.name, name)) {
                        return .{ .code = "", .type = .{ .finite_map = map.entries } };
                    }
                }

                for (gen.module.string_constants) |constant| {
                    if (std.mem.eql(u8, constant.key, name)) {
                        return .{ .code = try zig_string(gen.arena, constant.value), .type = .string };
                    }
                }

                if (std.mem.eql(u8, name, "NaN")) return .{ .code = "std.math.nan(f64)", .type = .number };
                if (std.mem.eql(u8, name, "Infinity")) return .{ .code = "std.math.inf(f64)", .type = .number };
                return gen.fail("reference to unknown local \"{s}\"", .{name});
            },
            else => return gen.fail("reference to {s} \"{s}\" is not lowered", .{ @tagName(source), name }),
        }
    }

    fn operation(gen: *Generator, e: *const ExpressionIR) Error!Lowered {
        return gen.operation_values(e, try gen.expression(e.operation.left), try gen.expression(e.operation.right));
    }

    fn operation_values(gen: *Generator, e: *const ExpressionIR, left: Lowered, right: Lowered) Error!Lowered {
        const operator = e.operation.operator;

        if (std.mem.eql(u8, operator, "??")) {
            if (left.type == .null) return right;
            if (!left.type.is_optional()) {
                // A schema default already filled the value (`type ?? "button"`
                // on a defaulted prop): the left side alone is the answer.
                return left;
            }
            const right_code = if (left.type == .opt_enumeration and e.operation.right.* == .literal and e.operation.right.literal == .string)
                try gen.coerce_literal(e.operation.right.literal.string, left.type.unwrapped())
            else
                right.code;
            return .{
                .code = try std.fmt.allocPrint(gen.arena, "({s} orelse {s})", .{ left.code, right_code }),
                // `a orelse b` stays optional when the fallback is optional.
                .type = if (right.type.is_optional() or right.type == .null) left.type else left.type.unwrapped(),
            };
        }

        if (std.mem.eql(u8, operator, "&&") or std.mem.eql(u8, operator, "||")) {
            if (left.type == .boolean and right.type == .boolean) {
                return .{ .code = try std.fmt.allocPrint(gen.arena, "({s} {s} {s})", .{ left.code, if (std.mem.eql(u8, operator, "&&")) @as([]const u8, "and") else "or", right.code }), .type = .boolean };
            }
            const binding = try gen.fresh("logical");
            const label = try gen.fresh("select");
            const saved = Lowered{ .code = binding, .type = left.type };
            const is_and = std.mem.eql(u8, operator, "&&");
            const selected = try gen.select(try gen.truthy(saved), if (is_and) right else saved, if (is_and) saved else right);
            return .{
                .code = try std.fmt.allocPrint(gen.arena, "{s}: {{ const {s} = {s}; break :{s} {s}; }}", .{ label, binding, left.code, label, selected.code }),
                .type = selected.type,
            };
        }

        const equality = std.mem.eql(u8, operator, "===") or std.mem.eql(u8, operator, "==");
        const inequality = std.mem.eql(u8, operator, "!==") or std.mem.eql(u8, operator, "!=");

        if (equality or inequality) {
            const code = try gen.equals(left, right);
            return .{
                .code = if (inequality) try std.fmt.allocPrint(gen.arena, "!{s}", .{code}) else code,
                .type = .boolean,
            };
        }

        const ordering = std.mem.eql(u8, operator, "<") or std.mem.eql(u8, operator, ">") or
            std.mem.eql(u8, operator, "<=") or std.mem.eql(u8, operator, ">=");

        if (ordering) {
            if (left.type != .number or right.type != .number) {
                return gen.fail("`{s}` compares a {s} with a {s}", .{ operator, @tagName(left.type), @tagName(right.type) });
            }
            return .{
                .code = try std.fmt.allocPrint(gen.arena, "({s} {s} {s})", .{ left.code, operator, right.code }),
                .type = .boolean,
            };
        }

        if (std.mem.eql(u8, operator, "%") and left.type == .number and right.type == .number) {
            return .{ .code = try std.fmt.allocPrint(gen.arena, "rt.number_rem({s}, {s})", .{ left.code, right.code }), .type = .number };
        }

        const arithmetic = std.mem.eql(u8, operator, "+") or std.mem.eql(u8, operator, "-") or
            std.mem.eql(u8, operator, "*") or std.mem.eql(u8, operator, "/");

        if (arithmetic) {
            if (left.type == .number and right.type == .number) {
                return .{
                    .code = try std.fmt.allocPrint(gen.arena, "({s} {s} {s})", .{ left.code, operator, right.code }),
                    .type = .number,
                };
            }
            if (std.mem.eql(u8, operator, "+") and left.type == .string and right.type == .string) {
                gen.arena_used = true;
                return .{
                    .code = try std.fmt.allocPrint(gen.arena, "rt.concat(arena, &.{{ {s}, {s} }})", .{ left.code, right.code }),
                    .type = .string,
                };
            }
            return gen.fail("`{s}` on a {s} and a {s} is not lowered", .{ operator, @tagName(left.type), @tagName(right.type) });
        }

        return gen.fail("operator \"{s}\" is not lowered", .{operator});
    }

    fn equals(gen: *Generator, left: Lowered, right: Lowered) Error![]const u8 {
        if (left.type == .null and right.type == .null) return "true";
        if (right.type == .null or left.type == .null) {
            const subject = if (right.type == .null) left else right;
            if (!subject.type.is_optional()) {
                return gen.fail("comparing a {s} with null", .{@tagName(subject.type)});
            }
            return std.fmt.allocPrint(gen.arena, "({s} == null)", .{subject.code});
        }

        if (left.type == .union_typeof or right.type == .union_typeof) {
            const subject = if (left.type == .union_typeof) left else right;
            const literal = if (left.type == .union_typeof) right else left;
            if (literal.type != .string) {
                return gen.fail("`typeof` compares only with a string literal", .{});
            }
            const tag = try enum_tag(gen, literal.code);
            if (std.mem.eql(u8, tag, "string")) {
                return std.fmt.allocPrint(gen.arena, "({s} == .string)", .{subject.code});
            }
            return std.fmt.allocPrint(gen.arena, "({s} != .string)", .{subject.code});
        }

        if (left.type == .enumeration and right.type == .string) {
            return std.fmt.allocPrint(gen.arena, "({s} == .@\"{s}\")", .{ left.code, try enum_tag(gen, right.code) });
        }

        if (left.type == .string and right.type == .enumeration) {
            return std.fmt.allocPrint(gen.arena, "({s} == .@\"{s}\")", .{ right.code, try enum_tag(gen, left.code) });
        }

        if (left.type == .string and right.type == .string) {
            return std.fmt.allocPrint(gen.arena, "std.mem.eql(u8, {s}, {s})", .{ left.code, right.code });
        }

        if (std.meta.activeTag(left.type) == std.meta.activeTag(right.type) and
            (left.type == .number or left.type == .boolean or left.type == .enumeration))
        {
            return std.fmt.allocPrint(gen.arena, "({s} == {s})", .{ left.code, right.code });
        }

        return gen.fail("equality between a {s} and a {s}", .{ @tagName(left.type), @tagName(right.type) });
    }

    /// A lowered string literal (`"ok"`) as an enum tag name (`ok`).
    fn enum_tag(gen: *Generator, literal: []const u8) Error![]const u8 {
        if (literal.len < 2 or literal[0] != '"') {
            return gen.fail("an enum is compared with a non-literal string", .{});
        }
        return literal[1 .. literal.len - 1];
    }

    fn select(gen: *Generator, test_code: []const u8, consequent_raw: Lowered, alternate_raw: Lowered) Error!Lowered {
        var consequent = if (consequent_raw.type == .finite) try gen.materialize_finite(consequent_raw.type.finite) else consequent_raw;
        var alternate = if (alternate_raw.type == .finite) try gen.materialize_finite(alternate_raw.type.finite) else alternate_raw;

        // A union meeting a string context materializes its string half (the
        // ternary's test guarantees the variant).
        if (consequent.type == .union_value and alternate.type == .string) {
            consequent = try gen.union_as_string(consequent);
        }
        if (alternate.type == .union_value and consequent.type == .string) {
            alternate = try gen.union_as_string(alternate);
        }
        const tag_a = std.meta.activeTag(consequent.type);
        const tag_b = std.meta.activeTag(alternate.type);

        if (tag_a == tag_b) {
            return .{
                .code = try std.fmt.allocPrint(gen.arena, "(if ({s}) {s} else {s})", .{ test_code, consequent.code, alternate.code }),
                .type = consequent.type,
            };
        }

        if (std.meta.activeTag(consequent.type.unwrapped()) == std.meta.activeTag(alternate.type.unwrapped()) and
            (consequent.type.is_optional() or alternate.type.is_optional()))
        {
            const optional = if (consequent.type.is_optional()) consequent.type else alternate.type;
            const optional_code = switch (optional) {
                .opt_enumeration => |e| try std.fmt.allocPrint(gen.arena, "?{s}", .{e.name}),
                else => type_code(optional),
            };
            return .{
                .code = try std.fmt.allocPrint(gen.arena, "(if ({s}) @as({s}, {s}) else @as({s}, {s}))", .{ test_code, optional_code, consequent.code, optional_code, alternate.code }),
                .type = optional,
            };
        }

        if (consequent.type == .null or alternate.type == .null) {
            const present = if (consequent.type == .null) alternate else consequent;
            const optional: Type = switch (present.type) {
                .string => .opt_string,
                .number => .opt_number,
                .boolean => .opt_boolean,
                .node => .opt_node,
                .enumeration => |e| .{ .opt_enumeration = e },
                else => return gen.fail("a conditional mixes null with a {s}", .{@tagName(present.type)}),
            };
            const optional_code = switch (optional) {
                .opt_enumeration => |e| try std.fmt.allocPrint(gen.arena, "?{s}", .{e.name}),
                else => type_code(optional),
            };
            return .{
                .code = try std.fmt.allocPrint(gen.arena, "(if ({s}) @as({s}, {s}) else @as({s}, {s}))", .{
                    test_code,
                    optional_code,
                    consequent.code,
                    optional_code,
                    alternate.code,
                }),
                .type = optional,
            };
        }

        return gen.fail("a conditional mixes a {s} with a {s}", .{ @tagName(consequent.type), @tagName(alternate.type) });
    }

    /// `` `/post/${slug}` `` → `try std.fmt.allocPrint(arena, "/post/{s}", .{slug})`.
    fn template(gen: *Generator, e: *const ExpressionIR) Error!Lowered {
        return (try gen.template_with(e, false)).?;
    }

    /// The template with each part lowered as its SSR initial when `own`
    /// (null when a part has none the server can render).
    fn template_with(gen: *Generator, e: *const ExpressionIR, own: bool) Error!?Lowered {
        var format: std.Io.Writer.Allocating = .init(gen.arena);
        var arguments: std.Io.Writer.Allocating = .init(gen.arena);

        for (e.template.parts) |part| {
            const part_expr = switch (part) {
                .string => |text| {
                    for (text) |char| {
                        switch (char) {
                            '{' => try format.writer.writeAll("{{"),
                            '}' => try format.writer.writeAll("}}"),
                            else => try format.writer.writeByte(char),
                        }
                    }
                    continue;
                },
                .expression => |part_expr| part_expr,
            };

            const lowered = if (own) switch ((try gen.own_initial(part_expr)) orelse OwnInitial{ .lowered = try gen.expression(part_expr) }) {
                .lowered => |initial| initial,
                .unservable => return null,
            } else try gen.expression(part_expr);

            switch (lowered.type) {
                .string => try format.writer.writeAll("{s}"),
                .number => try format.writer.writeAll("{s}"),
                .enumeration => try format.writer.writeAll("{t}"),
                else => return gen.fail("a {s} inside a template string", .{@tagName(lowered.type)}),
            }

            if (lowered.type == .number) {
                try arguments.writer.print(" try rt.number_to_string(arena, {s}),", .{lowered.code});
            } else {
                try arguments.writer.print(" {s},", .{lowered.code});
            }
        }

        gen.arena_used = true;

        return .{
            .code = try std.fmt.allocPrint(gen.arena, "try std.fmt.allocPrint(arena, {s}, .{{{s} }})", .{
                try zig_string(gen.arena, format.written()),
                arguments.written(),
            }),
            .type = .string,
        };
    }

    /// The JavaScript truthiness of a lowered value as a Zig `bool`.
    fn truthy(gen: *Generator, lowered: Lowered) Error![]const u8 {
        return switch (lowered.type) {
            .boolean => lowered.code,
            .opt_boolean => try std.fmt.allocPrint(gen.arena, "({s} orelse false)", .{lowered.code}),
            .opt_string => try std.fmt.allocPrint(gen.arena, "(if ({s}) |value| value.len != 0 else false)", .{lowered.code}),
            .opt_node => blk: {
                gen.arena_used = true;
                break :blk try std.fmt.allocPrint(gen.arena, "(if ({s}) |value| !value.is_empty(arena) else false)", .{lowered.code});
            },
            .opt_number => try std.fmt.allocPrint(gen.arena, "(if ({s}) |value| value != 0 and !std.math.isNan(value) else false)", .{lowered.code}),
            .opt_enumeration => try std.fmt.allocPrint(gen.arena, "(if ({s}) |value| @tagName(value).len != 0 else false)", .{lowered.code}),
            .opt_strings, .action => try std.fmt.allocPrint(gen.arena, "({s} != null)", .{lowered.code}),
            .number => try std.fmt.allocPrint(gen.arena, "({s} != 0 and !std.math.isNan({s}))", .{ lowered.code, lowered.code }),
            .string => try std.fmt.allocPrint(gen.arena, "({s}.len != 0)", .{lowered.code}),
            .node => blk: {
                gen.arena_used = true;
                break :blk try std.fmt.allocPrint(gen.arena, "(!{s}.is_empty(arena))", .{lowered.code});
            },
            .enumeration => try std.fmt.allocPrint(gen.arena, "(@tagName({s}).len != 0)", .{lowered.code}),
            .array, .strings, .item => "true",
            .null => "false",
            .action_name, .finite_map, .finite, .state_root, .ref_name, .union_value, .union_typeof => gen.fail("a {s} has no truthiness", .{@tagName(lowered.type)}),
        };
    }

    /// The string half of a BoxValue union — reachable only where the
    /// authored `typeof` test already guarantees the variant.
    fn union_as_string(gen: *Generator, lowered: Lowered) Error!Lowered {
        return .{
            .code = try std.fmt.allocPrint(
                gen.arena,
                "(switch ({s}) {{ .string => |publr_string| publr_string, else => unreachable }})",
                .{lowered.code},
            ),
            .type = .string,
        };
    }

    /// `SIZES[size]` as a Zig string expression: a `switch` over the key's
    /// enum, one arm per tag, each a map entry's value.
    fn materialize_finite(gen: *Generator, f: Type.Finite) Error!Lowered {
        var out: std.Io.Writer.Allocating = .init(gen.arena);

        try out.writer.print("(switch ({s}) {{", .{f.key_code});

        for (f.key_enum.values) |tag| {
            const value = finite_value(f.entries, tag) orelse {
                return gen.fail("a finite map has no entry for \"{s}\"", .{tag});
            };
            try out.writer.print(" .@\"{s}\" => {s},", .{ tag, try zig_string(gen.arena, value) });
        }

        try out.writer.writeAll(" })");

        return .{ .code = out.written(), .type = .string };
    }

    /// `TONES[kind]` keyed by a string: a labeled block comparing the key
    /// with each entry, breaking with the entry's value and with `fallback`
    /// (null when not given) when none matches. The values are strings, or
    /// tags of `target` when given — enum literals typed by the block's
    /// result location, since the enum may be the callee's.
    fn string_keyed_lookup(gen: *Generator, entries: []const Type.MapEntry, key_code: []const u8, target: ?Type.Enumeration, fallback: ?[]const u8) Error![]const u8 {
        const label = try gen.fresh("publr_lookup");
        const key = try gen.fresh("publr_key");
        var out: std.Io.Writer.Allocating = .init(gen.arena);

        try out.writer.print("({s}: {{ const {s} = {s};", .{ label, key, key_code });

        for (entries) |entry| {
            const value = if (target) |e| blk: {
                if (!util.containsString(e.values, entry.value)) {
                    return gen.fail("\"{s}\" is not a value of the {s} enum", .{ entry.value, e.name });
                }
                break :blk try std.fmt.allocPrint(gen.arena, ".@\"{s}\"", .{entry.value});
            } else try std.fmt.allocPrint(gen.arena, "@as(?[]const u8, {s})", .{try zig_string(gen.arena, entry.value)});
            try out.writer.print(" if (std.mem.eql(u8, {s}, {s})) break :{s} {s};", .{ key, try zig_string(gen.arena, entry.key), label, value });
        }

        try out.writer.print(" break :{s} {s}; }})", .{ label, fallback orelse if (target == null) "@as(?[]const u8, null)" else "null" });

        return out.written();
    }

    /// `SIZES[size]` filling an enum prop (`SPINNER_SIZES[size]` → Icon's
    /// `size`): a `switch` mapping the key's tags to the target's tags.
    fn finite_to_enum(gen: *Generator, f: Type.Finite, target: Type.Enumeration) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(gen.arena);

        try out.writer.print("(switch ({s}) {{", .{f.key_code});

        for (f.key_enum.values) |tag| {
            const value = finite_value(f.entries, tag) orelse {
                return gen.fail("a finite map has no entry for \"{s}\"", .{tag});
            };
            const listed = for (target.values) |candidate| {
                if (std.mem.eql(u8, candidate, value)) break true;
            } else false;

            if (!listed) {
                return gen.fail("\"{s}\" is not a value of the {s} enum", .{ value, target.name });
            }

            try out.writer.print(" .@\"{s}\" => .@\"{s}\",", .{ tag, value });
        }

        try out.writer.writeAll(" })");

        return out.written();
    }
};

fn finite_value(entries: []const Type.MapEntry, key: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            return entry.value;
        }
    }
    return null;
}

/// `onInput`, `onClick` — an attribute that wires an action to an event.
fn is_action_attribute(name: []const u8) bool {
    return name.len > 2 and std.mem.startsWith(u8, name, "on") and std.ascii.isUpper(name[2]);
}

fn count_attribute(attrs: []const AttributeIR, name: []const u8) u32 {
    var count: u32 = 0;
    for (attrs) |other| {
        if (other == .attribute and std.mem.eql(u8, other.attribute.name, name)) count += 1;
    }
    return count;
}

/// Whether an element's children are exactly the `{children}` prop — the
/// shape whose text a caller may replace through the text transport.
fn renders_children_prop(n: *const ElementIR) bool {
    if (n.children.len != 1) return false;
    const only = n.children[0];
    if (only.* != .expression) return false;
    const value = only.expression.value;
    return value.* == .reference and std.mem.eql(u8, value.reference.name, "children");
}

/// A rest attribute a component call may forward onto the callee's rendered
/// root: hyphenated names (`data-part`, `aria-*`) plus a few plain HTML ones.
/// Authored `data-p-*` transport stays an error.
fn is_forwardable_attribute(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "data-p-") or std.mem.eql(u8, name, "data-p")) return false;
    if (std.mem.indexOfScalar(u8, name, '-') != null) return true;
    return std.mem.eql(u8, name, "role") or std.mem.eql(u8, name, "tabindex") or std.mem.eql(u8, name, "for");
}

fn find_field(fields: []const Field, name: []const u8) ?Field {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            return f;
        }
    }
    return null;
}

fn string_of_literal(e: *const ExpressionIR) ?[]const u8 {
    if (e.* != .literal) return null;
    return if (e.literal == .string) e.literal.string else null;
}

fn constant_index(property: compiler.MemberProperty) ?i64 {
    switch (property) {
        .string => return null,
        .number => |number| {
            if (number != @floor(number)) return null;
            return @intFromFloat(number);
        },
        .expression => |e| {
            if (e.* != .literal or e.literal != .number) return null;
            const number = e.literal.number;
            if (number != @floor(number)) return null;
            return @intFromFloat(number);
        },
    }
}

fn is_map_call(e: *const ExpressionIR) bool {
    if (e.* != .call) return false;
    const callee = e.call.callee;
    if (callee.* != .member) return false;
    return callee.member.property == .string and std.mem.eql(u8, callee.member.property.string, "map");
}

fn contains_jsx(e: *const ExpressionIR) bool {
    return switch (e.*) {
        .node => true,
        .conditional => |value| contains_jsx(value.consequent) or contains_jsx(value.alternate),
        .operation => |value| contains_jsx(value.left) or contains_jsx(value.right),
        else => false,
    };
}

fn is_null_literal(e: *const ExpressionIR) bool {
    return e.* == .literal and e.literal == .null;
}

// ---- tests ------------------------------------------------------------------------
//
// Source-based fixtures: small .ptsx modules through `createPjsxModule` and
// the target, asserting on the generated Zig — the same expectations the
// retired demo-side lowering carried as raw-JSON fixtures.

fn test_lower(arena: std.mem.Allocator, sources: []const [2][]const u8, which: []const u8) Error![]const u8 {
    var irs: std.ArrayList(*const compiler.ModuleIR) = .empty;
    for (sources) |pair| {
        try irs.append(arena, try compiler.createPjsxModule(arena, pair[1], pair[0]));
    }
    const program = try Program.init(arena, irs.items);
    return program.lower(arena, which);
}

test "zig_string escapes quotes, backslashes, newlines and control bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const literal = try zig_string(arena_state.allocator(), "a\"b\\c\nd\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\x01\"", literal);
}

test "module_name_of takes the file stem of an import specifier" {
    try std.testing.expectEqualStrings("Layout", module_name_of("./Layout.ptsx"));
    try std.testing.expectEqualStrings("Text", module_name_of("@publr/ui/Text.pjsx"));
    try std.testing.expectEqualStrings("Bare", module_name_of("Bare"));
}

test "array props are converted to the receiving component's item types" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sources = [_][2][]const u8{
        .{
            "Child.ptsx",
            \\export const childProps = {
            \\  options: { type: "array", fields: { label: { type: "string" } } },
            \\};
            \\export function Child({ options }) {
            \\  return <ul>{options.map((option) => <li>{option.label}</li>)}</ul>;
            \\}
        },
        .{
            "Parent.ptsx",
            \\import { Child } from "./Child.ptsx";
            \\export const parentProps = {
            \\  rows: { type: "array", fields: {
            \\    choices: { type: "array", fields: { label: { type: "string" } } },
            \\  } },
            \\};
            \\export function Parent({ rows }) {
            \\  return <div>{rows.map((row) => <Child options={row.choices} />)}</div>;
            \\}
        },
    };
    const source = try test_lower(arena, &sources, "Parent");
    try std.testing.expect(std.mem.indexOf(u8, source, "try rt.prop_array(@FieldType(Child.Props, \"options\"), arena, row.choices)") != null);
}

const test_layout_source =
    \\export type LayoutProps = { title: string; children?: unknown };
    \\export const layoutProps = {
    \\  title: { type: "string" },
    \\  children: { type: "node", optional: true },
    \\} as const;
    \\export function Layout({ title, children }: LayoutProps) {
    \\  return (
    \\    <body class="p-4">
    \\      {title}
    \\      {children}
    \\    </body>
    \\  );
    \\}
;

test "a small module lowers: props struct, escaped text, loop, conditional, component call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const page_source =
        \\import { Layout } from "./Layout.ptsx";
        \\export type PageProps = { posts: Array<{ slug: string }>; on?: boolean };
        \\export const pageProps = {
        \\  posts: { type: "array", fields: { slug: { type: "string" } } },
        \\  on: { type: "boolean", optional: true, default: false },
        \\} as const;
        \\export function Page({ posts, on = false }: PageProps) {
        \\  return (
        \\    <Layout title="Hi">
        \\      {on ? <b>a &amp; b</b> : null}
        \\      {posts.map((post) => (
        \\        <a href={`/post/${post.slug}`}>{post.slug}</a>
        \\      ))}
        \\    </Layout>
        \\  );
        \\}
    ;

    const sources = [_][2][]const u8{
        .{ "Layout.ptsx", test_layout_source },
        .{ "Page.ptsx", page_source },
    };

    const source = try test_lower(arena, &sources, "Page");

    try std.testing.expect(std.mem.indexOf(u8, source, "posts: []const PostsItem,") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "on: bool = false,") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (props.on) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "a &amp; b") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "for (props.posts) |post| {") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "allocPrint(arena, \"/post/{s}\", .{ post.slug, })") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "try rt.escape(w, post.slug);") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "try Layout.render(w, arena, .{ .title = \"Hi\", .publr_show = props.publr_show, .publr_show_wire = props.publr_show_wire, .publr_text_wire = props.publr_text_wire, .children = rt.block(&children_1, Children_1) });") != null);

    const layout_source = try test_lower(arena, &sources, "Layout");
    try std.testing.expect(std.mem.indexOf(u8, layout_source, "children: ?rt.Node = null,") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout_source, "try rt.escape(w, props.title);") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout_source, "try value_1.render(w, arena);") != null);
}

test "an unsupported construct fails with a message naming the module and construct" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An event whose handler is not an action.
    const bad_source =
        \\export const badProps = {} as const;
        \\export function Bad() {
        \\  return <p @click={"x"}>hi</p>;
        \\}
    ;
    try std.testing.expectError(
        error.Pjsx,
        test_lower(arena, &.{.{ "Bad.ptsx", bad_source }}, "Bad"),
    );
    try std.testing.expectEqualStrings(
        "Bad: an event handler must be a reactive action, got a string",
        err.message(),
    );

    // A wire authored as an expression instead of its literal.
    const behavior_source =
        \\export type Bad2Props = { on: boolean };
        \\export const bad2Props = { on: { type: "boolean" } } as const;
        \\export function Bad2({ on }: Bad2Props) {
        \\  return <p :show={on}>hi</p>;
        \\}
    ;
    try std.testing.expectError(
        error.Pjsx,
        test_lower(arena, &.{.{ "Bad2.ptsx", behavior_source }}, "Bad2"),
    );
    try std.testing.expectEqualStrings(
        "Bad2: a wire must be authored as its literal, e.g. :show=\"$dirty\"",
        err.message(),
    );
}

test "a family root carries its store; parts wire to it through imports" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A cut-down Dialog: the root owns the store; the part imports state, an
    // action and a ref, and authors an SSR+wire pair, a lone hidden wire, a
    // membership wire, directives, an action, and a class wire group.
    const root_source =
        \\import { Publr } from "publr/dom";
        \\export const state = Publr.reactive({ open: false, values: [] as string[] });
        \\export const panel = Publr.ref();
        \\export const openDialog = (event: Event) => {
        \\  state.open = true;
        \\};
        \\export type RootProps = { children: unknown };
        \\export const rootProps = { children: { type: "node" } } as const;
        \\export function Root({ children }: RootProps) {
        \\  return <div class="inline-block">{children}</div>;
        \\}
    ;
    const part_source =
        \\import { Publr } from "publr/dom";
        \\import { state, openDialog, panel } from "./Root.ptsx";
        \\export const partProps = {} as const;
        \\export function Part() {
        \\  return (
        \\    <button
        \\      aria-expanded="false"
        \\      aria-expanded={state.open}
        \\      hidden={!state.open}
        \\      data-open={state.values.includes(Publr.dataset("value"))}
        \\      ref={panel}
        \\      portal
        \\      onClick={openDialog}
        \\      class={state.open ? "font-medium" : ""}
        \\      class="flex"
        \\    >
        \\      x
        \\    </button>
        \\  );
        \\}
    ;

    const sources = [_][2][]const u8{
        .{ "Root.ptsx", root_source },
        .{ "Part.ptsx", part_source },
    };

    const root = try test_lower(arena, &sources, "Root");
    try std.testing.expect(std.mem.indexOf(u8, root, "data-p-store=\\\"") != null);

    const part = try test_lower(arena, &sources, "Part");
    try std.testing.expect(std.mem.indexOf(u8, part, "aria-expanded=\\\"false\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part, "data-p-bind=\\\"data-open:$values contains @value;aria-expanded:$open\\\"") != null or
        std.mem.indexOf(u8, part, "data-p-bind=\\\"aria-expanded:$open;data-open:$values contains @value\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part, "data-p-show=\\\"$open\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part, "data-p-ref=\\\"panel\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part, "data-p-portal") != null);
    try std.testing.expect(std.mem.indexOf(u8, part, "data-p-on=\\\"click:openDialog\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part, "data-p-class=\\\"$open -&gt; font-medium\\\"") != null);
    // The static class layer stays a plain attribute after the wire group
    // moved out of the stack.
    try std.testing.expect(std.mem.indexOf(u8, part, "class=\\\"flex\\\"") != null);
}

test "events, wires and the store attribute lower to data-p-*" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const demo_source =
        \\import { Publr } from "publr/dom";
        \\export type DemoProps = { title: string };
        \\export const demoProps = { title: { type: "string" } } as const;
        \\export function Demo({ title }: DemoProps) {
        \\  const state = Publr.reactive({ n: 0, dirty: false });
        \\  const sync = (event) => {
        \\    state.dirty = true;
        \\  };
        \\  const go = () => {
        \\    state.n = 0;
        \\  };
        \\  return (
        \\    <form>
        \\      <input onInput={sync} @keydown.enter.prevent="go" />
        \\      <span :text="$n">{title}</span>
        \\      <b class="hidden" :show="$dirty" :class="$dirty -> font-bold ~ font-normal" :aria-busy="$dirty">x</b>
        \\    </form>
        \\  );
        \\}
    ;

    const source = try test_lower(arena, &.{.{ "Demo.ptsx", demo_source }}, "Demo");

    try std.testing.expect(std.mem.indexOf(u8, source, "data-p-store=\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "data-p-on=\\\"input:sync;keydown.enter.prevent:go\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "data-p-text=\\\"$n\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "data-p-show=\\\"$dirty\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "data-p-class=\\\"$dirty -&gt; font-bold ~ font-normal\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "data-p-bind=\\\"aria-busy:$dirty\\\"") != null);
}

test "a string-typed children prop takes a single text child, and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const option_source =
        \\export type OptionProps = { children: string };
        \\export const optionProps = { children: { type: "string" } } as const;
        \\export function Option({ children }: OptionProps) {
        \\  return <span>{children}</span>;
        \\}
    ;
    const page_source =
        \\import { Option } from "./Option.ptsx";
        \\export const pageProps = {} as const;
        \\export function Page() {
        \\  return <Option>XS</Option>;
        \\}
    ;
    const bad_source =
        \\import { Option } from "./Option.ptsx";
        \\export const badProps = {} as const;
        \\export function Bad() {
        \\  return <Option><b>x</b></Option>;
        \\}
    ;

    const sources = [_][2][]const u8{
        .{ "Option.ptsx", option_source },
        .{ "Page.ptsx", page_source },
        .{ "Bad.ptsx", bad_source },
    };

    const source = try test_lower(arena, &sources, "Page");
    try std.testing.expect(std.mem.indexOf(u8, source, ".children = \"XS\" });") != null);

    try std.testing.expectError(error.Pjsx, test_lower(arena, &sources, "Bad"));
    try std.testing.expectEqualStrings(
        "Bad: <Option>'s children prop is a string; only a single text or string child is lowered",
        err.message(),
    );
}

test "action props, Dynamic, finite maps, class stacks and aria booleans lower" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A cut-down DS Button: Dynamic root with a computed tag, an action prop
    // wired through, a class stack over a finite map, an aria boolean.
    const button_source =
        \\import { Dynamic } from "publr/dom";
        \\export type ButtonProps = {
        \\  size?: "sm" | "md";
        \\  href?: string;
        \\  pressed?: boolean;
        \\  onClick?: unknown;
        \\  classes?: string;
        \\  children: unknown;
        \\};
        \\export const buttonProps = {
        \\  size: { type: "string", optional: true, default: "md", values: ["sm", "md"] },
        \\  href: { type: "optional-string", optional: true },
        \\  pressed: { type: "optional-boolean", optional: true },
        \\  onClick: { type: "action", optional: true },
        \\  classes: { type: "string", optional: true, default: "" },
        \\  children: { type: "node" },
        \\} as const;
        \\const SIZES = { sm: "h-8 px-2", md: "h-9 px-3" };
        \\export function Button({ size = "md", href, pressed, onClick, classes = "", children }: ButtonProps) {
        \\  return (
        \\    <Dynamic
        \\      as={href === undefined ? "button" : "a"}
        \\      class="inline-flex border"
        \\      class={SIZES[size]}
        \\      class={classes}
        \\      aria-pressed={pressed}
        \\      onClick={onClick}
        \\    >
        \\      {children}
        \\    </Dynamic>
        \\  );
        \\}
    ;
    const page_source =
        \\import { Publr } from "publr/dom";
        \\import { Button } from "@publr/ui/Button.ptsx";
        \\export const pageProps = {} as const;
        \\export function Page() {
        \\  const state = Publr.reactive({ n: 0 });
        \\  const go = () => {
        \\    state.n = 0;
        \\  };
        \\  return <Button size="sm" onClick={go}>Go</Button>;
        \\}
    ;

    const sources = [_][2][]const u8{
        .{ "Button.ptsx", button_source },
        .{ "Page.ptsx", page_source },
    };

    const source = try test_lower(arena, &sources, "Button");

    // The computed tag binds once and opens/closes the element.
    try std.testing.expect(std.mem.indexOf(u8, source, "const tag_1 = (if ((props.href == null)) \"button\" else \"a\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "try w.writeAll(tag_1);") != null);
    // Class merging uses the render arena even without another allocating expression.
    try std.testing.expect(std.mem.indexOf(u8, source, "_ = arena;") == null);
    // The class stack merges through the runtime; the finite map is a switch.
    try std.testing.expect(std.mem.indexOf(u8, source, "try rt.write_merged(w, arena, &.{ \"inline-flex border\", (switch (props.size) { .@\"sm\" => \"h-8 px-2\", .@\"md\" => \"h-9 px-3\", }), props.classes, });") != null);
    // The action prop becomes a runtime wire; aria booleans serialize as text.
    try std.testing.expect(std.mem.indexOf(u8, source, "try rt.write_wire_attr(w, \"data-p-on\", &.{ .{ .prefix = \"click:\", .value = props.onClick }, });") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (props.pressed) |value_") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "onClick: ?[]const u8 = null,") != null);

    const page = try test_lower(arena, &sources, "Page");

    // A local action fills an action prop as its name.
    try std.testing.expect(std.mem.indexOf(u8, page, ".onClick = \"go\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, ".size = .@\"sm\",") != null);
}

test "JSX own-state classes, window events and component refs lower without authored wires" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sources = [_][2][]const u8{
        .{
            "Control.ptsx",
            \\export const controlProps = {} as const;
            \\export function Control() { return <button>Go</button>; }
        },
        .{
            "List.ptsx",
            \\import { Publr } from "publr/dom";
            \\import { Control } from "./Control.ptsx";
            \\export const state = Publr.reactive({ busy: false });
            \\export const control = Publr.ref();
            \\export const go = () => { state.busy = true; };
            \\export const listProps = { busy: { type: "boolean" } } as const;
            \\export function List({ busy }) {
            \\  state.busy = busy;
            \\  return <div class="base" class={state.busy ? "busy" : "idle"} onWindowPopState={go}>
            \\    <Control ref={control} onClick={go} />
            \\  </div>;
            \\}
        },
    };
    const source = try test_lower(arena, &sources, "List");
    try std.testing.expect(std.mem.indexOf(u8, source, "if (props.busy)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "$busy -&gt; busy ~ idle") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "popstate.window:go") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".name = \"data-p-ref\", .value = \"control\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".name = \"data-p-on\", .value = \"click:go\"") != null);
}

test "shared JSX state, keyed rows and actions lower without a local state owner" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const source = try test_lower(arena_state.allocator(), &.{.{
        "Crumbs.ptsx",
        \\import { Publr } from "publr/dom";
        \\export const crumbsProps = {} as const;
        \\export function Crumbs() {
        \\  return <nav hidden={!Publr.stores.navigation.open}>
        \\    {Publr.stores.navigation.levels.map((level) => (
        \\      <a key={level.depth} href="#" data-depth={level.depth} onClick={Publr.stores.navigation.back}>{level.title}</a>
        \\    ))}
        \\  </nav>;
        \\}
    }}, "Crumbs");
    for ([_][]const u8{ "$navigation::open", "level of $navigation::levels", "$level.depth", "$level.title", "click:$navigation::back" }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, source, expected) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, source, "props.levels") == null);
}

test "JSX HTML regions preserve null fallbacks and render initial trusted HTML as content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sources = [_][2][]const u8{.{
        "Preview.ptsx",
        \\import { Publr } from "publr/dom";
        \\export const state = Publr.reactive({ html: null });
        \\export const previewProps = {} as const;
        \\export function Preview() {
        \\  return <main><div innerHTML={state.html}><b>Fallback</b></div><section focusScope innerHTML={"<em>Ready</em>"} /></main>;
        \\}
    }};
    const source = try test_lower(arena, &sources, "Preview");
    try std.testing.expect(std.mem.indexOf(u8, source, "innerHTML:$html") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Fallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "<em>Ready</em>") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "&lt;em&gt;") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "data-p-focus") != null);
}
