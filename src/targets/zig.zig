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
const expression_js = @import("expression_js.zig");
const slots_file = @import("zig_slots.zig");

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
    /// A compiled expression's value as the server ran it: `rt.Value`.
    value,

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

    const UnionInfo = struct {
        name: []const u8,
    };

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
            .opt_enumeration => |e| .{
                .enumeration = e,
            },
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
    /// List props carry one too: a caller's reactive list crosses the boundary, and the
    /// callee's `.map` over it draws a reactive list bound to the caller's state.
    list_transport: bool = false,
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
    /// A plain module's top-level helpers, for its compiled expressions' block.
    declarations: []const compiler.DeclarationIR = &.{},
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
    const Seed = struct {
        field: []const u8,
        expr: *const ExpressionIR,
    };
    const Initial = struct {
        field: []const u8,
        expr: ?*const ExpressionIR,
    };
    const Import = struct {
        local: []const u8,
        imported: []const u8,
        module: []const u8,
    };
    const FiniteMap = struct {
        name: []const u8,
        entries: []const Type.MapEntry,
    };
    const StoreRegistration = struct {
        store: []const u8,
        code: []const u8,
    };
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

/// The fields of a consumer's request struct, for `Program.request`: strings, booleans,
/// numbers, nodes (any struct with a `render_fn`), their optionals, string slices and
/// nested structs, which read as items.
pub fn requestFields(comptime Request: type) []const Field {
    return comptime request_fields_of(Request);
}

/// The fields a view reads; a `publr_` field is the render's own (its engine), not one.
fn request_fields_of(comptime Request: type) []const Field {
    const declared = @typeInfo(Request).@"struct".fields;
    var fields: [declared.len]Field = undefined;
    var count: usize = 0;
    for (declared) |field| {
        if (std.mem.startsWith(u8, field.name, "publr_")) continue;
        fields[count] = .{
            .name = field.name,
            .type = request_type(field.type),
            .zig_type = @typeName(field.type),
            .default = null,
        };
        count += 1;
    }
    const done = fields[0..count].*;
    return &done;
}

fn request_type(comptime Value: type) Type {
    if (Value == []const u8) return .string;
    if (Value == ?[]const u8) return .opt_string;
    if (Value == bool) return .boolean;
    if (Value == ?bool) return .opt_boolean;
    if (Value == f64) return .number;
    if (Value == ?f64) return .opt_number;
    if (Value == []const []const u8) return .strings;
    if (@typeInfo(Value) == .optional) {
        const child = @typeInfo(Value).optional.child;
        if (@typeInfo(child) == .@"struct" and @hasField(child, "render_fn")) return .opt_node;
    }
    if (@typeInfo(Value) == .@"struct") {
        if (@hasField(Value, "render_fn")) return .node;
        return .{
            .item = request_fields_of(Value),
        };
    }
    @compileError("a request field of type " ++ @typeName(Value) ++ " is not readable");
}

fn root_component_of(root: *const NodeIR) []const u8 {
    return switch (root.*) {
        .element => |element| switch (element.name) {
            .component => |component| component.name,
            else => "",
        },
        else => "",
    };
}

/// Attributes whose value is an address the browser follows or loads.
fn is_url_attribute(name: []const u8) bool {
    const names = [_][]const u8{ "href", "src", "action", "formaction", "poster" };

    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }

    return false;
}

/// `/admin`, not `//cdn.example` (another host) nor `#top` or `https://…`.
fn root_path(text: []const u8) bool {
    return text.len > 0 and text[0] == '/' and (text.len == 1 or text[1] != '/');
}

fn is_publr_request(member: anytype) bool {
    if (member.property != .string or !util.eql(member.property.string, "request")) return false;
    if (member.object.* != .reference) return false;
    return util.eql(member.object.reference.name, "Publr");
}

pub const ZigOutput = struct {
    code: []const u8,
};

/// A whole compile set: the adapted modules, sorted by name. Components
/// resolve their imports against it, so every module a view references must
/// be in the same program.
pub const Program = struct {
    modules: []const Module,
    /// What `Publr.request` holds in a server render: the fields of the consumer's
    /// `Request` (`requestFields`). Empty when the consumer declares none, and a read
    /// of `Publr.request` then fails the build.
    request: []const Field = &.{},
    /// Where in the request the path the project is served under is (`admin.base`): a root
    /// path in a URL attribute (`href="/admin"`) is written after it. Empty: written as is.
    url_base: []const u8 = "",
    /// Each lowered module's compiled expressions, by module name: those its bindings
    /// name, for `storesFile`, and those its render runs, for `serverFile`.
    slots: *slots_file.Table,
    server_slots: *slots_file.Table,
    /// The request field holding the consumer's `rt.Expressions`: set, the server runs
    /// the compiled expressions for their first values; empty, it lowers them to Zig.
    expressions_field: []const u8 = "",
    /// The request field holding the class book a render's classes are written with: set,
    /// every class stack is merged with it (`rt.write_merged_in`); empty, with the consumer's
    /// own.
    classes_field: []const u8 = "",
    /// The request field holding the page's set of templates written (`rt.Templates`): set,
    /// a prototype that is all fixed text is written once per page; empty, every time.
    templates_field: []const u8 = "",

    pub fn init(arena: std.mem.Allocator, irs: []const *const compiler.ModuleIR) Error!Program {
        var modules = try arena.alloc(Module, irs.len);
        for (irs, 0..) |ir, i| {
            modules[i] = try adapt_module(arena, ir);
        }
        std.mem.sort(Module, modules, {}, module_less_than);
        const slots = try arena.create(slots_file.Table);
        slots.* = .empty;
        const server_slots = try arena.create(slots_file.Table);
        server_slots.* = .empty;
        return .{
            .modules = modules,
            .slots = slots,
            .server_slots = server_slots,
        };
    }

    /// The generated Zig for the named component.
    pub fn lower(program: Program, arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
        for (program.modules) |module| {
            if (std.mem.eql(u8, module.name, name)) {
                var gen: Generator = .init(arena, module, program.modules);
                gen.request = program.request;
                gen.url_base = program.url_base;
                gen.expressions_field = program.expressions_field;
                gen.classes_field = program.classes_field;
                gen.templates_field = program.templates_field;
                const code = try gen.lower_module();
                try program.slots.put(arena, module.name, try gen.used_slots(code, .bound));
                try program.server_slots.put(arena, module.name, try gen.used_slots(code, .run));
                return code;
            }
        }
        return err.fail("no module named {s} in the program", .{name});
    }

    /// The generated Zig for the named component followed by its compiled
    /// expressions as comments, one per line: one text to read both from.
    pub fn listing(program: Program, arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
        const code = try program.lower(arena, name);
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll(code);
        for (program.slots.get(name) orelse &.{}) |slot| try out.writer.print("// slot {s}: {s}\n", .{ slot.name, slot.code });
        return out.written();
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

        // The wrapper a branch's body is drawn in when it is not one element.
        try all.append(arena, "contents");

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

    /// The compiled expressions as the server runs them: one function per module
    /// taking its state and answering its slots; the consumer's engine makes a
    /// module's table once per state (`__publr_table`) and runs slots on it with a
    /// scope (`__publr_call`), each answering the value as JSON or `undefined`.
    pub fn serverFile(program: Program, arena: std.mem.Allocator) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll("// Generated by pjsx_zig: the views' compiled expressions on the server — do not edit.\n");
        try out.writer.writeAll(slots_file.intrinsics);
        try out.writer.writeAll(slots_file.server_publr);
        try out.writer.writeAll("const views = {\n");
        for (program.modules) |module| {
            const slots = program.server_slots.get(module.name) orelse continue;
            if (slots.len == 0) continue;
            try out.writer.print("{s}\n", .{try slots_file.serverModule(arena, module.name, slots, module.declarations)});
        }
        try out.writer.writeAll(slots_file.server_run);
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

        // The intrinsics, when a browser slot calls one.
        for (program.modules) |module| {
            if (slots_file.calls_intrinsic(program.slots.get(module.name) orelse &.{})) {
                try w.writeAll(slots_file.intrinsics);
                break;
            }
        }

        // Modules without a store of their own register theirs by name, first: registering a
        // store hydrates the roots waiting for it, which may use them.
        for (program.modules) |module| {
            if (module.wire != null) continue;
            const slots = program.slots.get(module.name) orelse continue;
            if (slots.len == 0) continue;
            try w.print("\n// {s}\n{s}\n", .{ module.name, try slots_file.block(arena, slots, module.declarations) });
        }

        var seen: std.ArrayList([]const u8) = .empty;

        for (program.modules) |module| {
            const registration = module.store_registration orelse continue;
            const duplicate = for (seen.items) |name| {
                if (std.mem.eql(u8, name, registration.store)) break true;
            } else false;
            if (duplicate) continue;
            try seen.append(arena, registration.store);
            // The slots of every module owning this store, inside its factory.
            var owned: std.ArrayList(slots_file.Slot) = .empty;
            for (program.modules) |owner| {
                const wire = owner.wire orelse continue;
                if (!std.mem.eql(u8, wire.store, registration.store)) continue;
                try owned.appendSlice(arena, program.slots.get(owner.name) orelse &.{});
            }
            try w.print("\n// {s}\n{s}\n", .{ module.name, try slots_file.withFactoryMember(arena, registration.code, owned.items) });
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
    return .{
        .code = try program.lower(arena, module.component.name),
    };
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
            seed_exprs[i] = .{
                .field = seed.field,
                .expr = seed.value,
            };
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
            list[i] = .{
                .key = key,
                .value = value,
            };
        }
        try finite_maps.append(arena, .{
            .name = name,
            .entries = list,
        });
    }

    var string_constants = try arena.alloc(Type.MapEntry, ir.string_constants.len);
    for (ir.string_constants, 0..) |constant, i| {
        string_constants[i] = .{
            .key = constant.name,
            .value = constant.value,
        };
    }

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

    var prop_types: std.Io.Writer.Allocating = .init(arena);
    // The module's imports are declarations too: a prop's type never takes their names (an
    // `icon` prop beside an imported `Icon`).
    var type_names: TypeNames = .empty;
    for (imports.items) |import| try type_names.put(arena, import.local, {});
    const props = try adapt_props(arena, component.props, &prop_types.writer, component.name, &type_names);

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
            .{
                .store = registration.name,
                .code = registration.code,
            }
        else
            null,
        .transport_root = transports_at_root(component.root),
        .declarations = component.declarations,
    };
}

fn adapt_initials(arena: std.mem.Allocator, initial: []const compiler.InitialIR) Error![]const Module.Initial {
    const out = try arena.alloc(Module.Initial, initial.len);
    for (initial, 0..) |entry, i| {
        out[i] = .{
            .field = entry.field,
            .expr = entry.value,
        };
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
/// The item struct names a module declares so far: an array prop's items are named after
/// it (`changes` → `ChangesItem`), and a name already taken by another array of the same
/// name elsewhere in the props takes its parent's name in front (`OursSegmentsItem`).
const TypeNames = std.StringHashMapUnmanaged(void);

/// `preferred`, or, when the props already declare it (the same shape at another depth: a
/// list of files on a field, on a group's part and on a repeater's cell), the next ancestor
/// names in `where` in front of it, else a number after it.
fn free_name(arena: std.mem.Allocator, names: *TypeNames, where: []const u8, preferred: []const u8) Error![]const u8 {
    if (!names.contains(preferred)) return preferred;

    var candidate = preferred;
    var rest = where;

    while (std.mem.lastIndexOfScalar(u8, rest, '.')) |dot| {
        rest = rest[0..dot];
        const segment = rest[if (std.mem.lastIndexOfScalar(u8, rest, '.')) |inner| inner + 1 else 0..];
        candidate = try std.fmt.allocPrint(arena, "{s}{s}", .{ try capitalize(arena, segment), candidate });
        if (!names.contains(candidate)) return candidate;
    }

    var number: u32 = 2;

    while (number < 1000) : (number += 1) {
        const numbered = try std.fmt.allocPrint(arena, "{s}{d}", .{ preferred, number });
        if (!names.contains(numbered)) return numbered;
    }

    return err.fail("{s}: no free type name for {s}", .{ where, preferred });
}

fn item_struct_name(arena: std.mem.Allocator, names: *TypeNames, where: []const u8, name: []const u8) Error![]const u8 {
    const plain = try std.fmt.allocPrint(arena, "{s}Item", .{try capitalize(arena, name)});
    const taken = names.contains(plain);
    const parent = where[if (std.mem.lastIndexOfScalar(u8, where, '.')) |dot| dot + 1 else 0..];
    const preferred = if (!taken)
        plain
    else
        try std.fmt.allocPrint(arena, "{s}{s}", .{ try capitalize(arena, parent), plain });
    const chosen = try free_name(arena, names, where, preferred);

    try names.put(arena, chosen, {});
    return chosen;
}

fn adapt_props(
    arena: std.mem.Allocator,
    schema: *const analyze.Schema,
    types: *std.Io.Writer,
    where: []const u8,
    names: *TypeNames,
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
            const plain_name = if (std.mem.lastIndexOfScalar(u8, where, '.')) |dot|
                try std.fmt.allocPrint(arena, "{s}{s}", .{ try capitalize(arena, where[dot + 1 ..]), try capitalize(arena, name) })
            else
                try capitalize(arena, name);
            // A name the module already declares (an import) takes `Value` after it.
            const preferred = if (names.contains(plain_name))
                try std.fmt.allocPrint(arena, "{s}Value", .{plain_name})
            else
                plain_name;
            const enum_name = try free_name(arena, names, where, preferred);

            try names.put(arena, enum_name, {});
            var tags: std.ArrayList([]const u8) = .empty;

            try types.print("pub const {s} = enum {{", .{enum_name});

            for (spec.values.?) |value| {
                const tag = value.asString() orelse return err.fail("{s}.{s}: non-string enum value", .{ where, name });
                try tags.append(arena, tag);
                try types.print(" @\"{s}\",", .{tag});
            }

            try types.writeAll(" };\n");

            const enumeration: Type.Enumeration = .{
                .name = enum_name,
                .values = tags.items,
            };
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
                prop_type = .{
                    .opt_enumeration = enumeration,
                };
                zig_type = try std.fmt.allocPrint(arena, "?{s}", .{enum_name});
                default_code = "null";
            } else {
                prop_type = .{
                    .enumeration = enumeration,
                };
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
                prop_type = .{
                    .union_value = .{
                        .name = union_name,
                    },
                };
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
                    const struct_name = try item_struct_name(arena, names, where, name);
                    var nested_types: std.Io.Writer.Allocating = .init(arena);
                    const item_fields = try adapt_props(arena, nested, &nested_types.writer, try std.fmt.allocPrint(arena, "{s}.{s}", .{ where, name }), names);

                    try types.writeAll(nested_types.written());
                    try types.print("pub const {s} = struct {{\n", .{struct_name});
                    try write_fields(types, item_fields);
                    try types.writeAll("};\n");

                    prop_type = .{
                        .array = item_fields,
                    };
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
            .list_transport = prop_type == .array or prop_type == .strings,
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
        .value => "rt.Value",
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

test {
    std.testing.refAllDecls(expression_js);
    std.testing.refAllDecls(slots_file);
}

/// `text` as a Zig string literal, quotes included.
/// Whether generated `code` reads nothing of the instance it renders in: no prop but the
/// page's request and its family's state, and none of `locals`, the names declared around
/// it.
fn instance_free(code: []const u8, locals: []const Local) bool {
    var at: usize = 0;

    while (std.mem.indexOfPos(u8, code, at, "props.")) |found| {
        at = found + "props.".len;
        if (found > 0 and is_identifier_char(code[found - 1])) continue;
        // The page's request is one per page. A family's state reaches a prototype's
        // components only as `publr_prototype`, which leaves its values out.
        if (std.mem.startsWith(u8, code[at..], "publr_request")) continue;
        if (std.mem.startsWith(u8, code[at..], "publr_family")) continue;
        return false;
    }

    for (locals) |local| {
        if (mentions(code, local.name)) return false;
    }

    return true;
}

/// Whether `code` has `name` as a whole identifier.
fn mentions(code: []const u8, name: []const u8) bool {
    var at: usize = 0;

    while (std.mem.indexOfPos(u8, code, at, name)) |found| {
        at = found + name.len;
        const before_ok = found == 0 or !is_identifier_char(code[found - 1]);
        const after_ok = at >= code.len or !is_identifier_char(code[at]);
        if (before_ok and after_ok) return true;
    }

    return false;
}

fn is_identifier_char(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_' or char == '@';
}

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
    templates: std.ArrayList(struct {
        expression: *const ExpressionIR,
        name: []const u8,
    }) = .empty,
    /// The item structs and enums of asserted array literals (`[] as Row[]`),
    /// declared at file scope once per literal.
    asserted_types: std.ArrayList(u8) = .empty,
    asserted_arrays: std.ArrayList(struct {
        expression: *const ExpressionIR,
        lowered: Lowered,
    }) = .empty,
    /// `a && b && <jsx/>` regrouped as `a && (b && <jsx/>)`, once per
    /// expression, so each guard is its own branch with a stable template id.
    split_guards: std.ArrayList(struct {
        expression: *const ExpressionIR,
        split: *const ExpressionIR,
    }) = .empty,
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
    /// The request a server render reads as `Publr.request`, declared by the program.
    request: []const Field = &.{},
    request_used: bool = false,
    /// `Program.url_base`.
    url_base: []const u8 = "",
    /// A sibling family this module binds to through its imports
    /// (`import { state, toggle } from "./Dialog.ptsx"`): part modules wire
    /// to the family's store through DOM ancestry, so their bindings are
    /// *foreign* — wires without SSR initial values.
    /// The families this module is a part of: each one it imports state, actions or refs
    /// from.
    foreigns: []const Foreign,
    /// Set while the module's root element is being opened, so it can carry
    /// the `data-p-store` attribute and the `data-p` seed.
    root_store: ?[]const u8,
    root_seeds: []const Module.Seed,
    /// True while the module's root node renders: the root element (or each
    /// arm of a conditional root) receives the show/text transport plumbing.
    at_root: bool,
    /// The module's compiled expressions. One expression asked for twice in the
    /// same scope names one slot; a list's prototype and its server rows differ.
    slots: std.ArrayList(slots_file.Slot) = .empty,
    /// `Program.expressions_field`.
    expressions_field: []const u8 = "",
    /// `Program.classes_field`.
    classes_field: []const u8 = "",
    /// `Program.templates_field`.
    templates_field: []const u8 = "",
    /// The variable holding this render's state as JSON, where it is declared, and
    /// whether an expression read it.
    state_json: ?[]const u8 = null,
    state_offset: usize = 0,
    state_fields: []const u8 = "",
    state_json_used: bool = false,
    /// The Zig expression for the family roots this render is inside: the caller's, a
    /// family root's own once it declares it, a block's as it is rendered.
    family_code: []const u8 = "props.publr_family",
    /// A family root's store, kept for its render instance once the root element took it.
    family_store: ?[]const u8 = null,
    /// Above zero while a list's subject lowers: its rows are typed in the render,
    /// which an engine's value is not (yet).
    native_depth: u32 = 0,

    const Foreign = struct {
        module_name: []const u8,
        state_local: ?[]const u8,
        actions: []const NamePair,
        refs: []const NamePair,
    };
    const NamePair = struct {
        local: []const u8,
        name: []const u8,
    };

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
            .foreigns = &.{},
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
        var foreigns: std.ArrayList(Foreign) = .empty;

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

            // One entry per family, however many names come from it.
            const foreign = for (foreigns.items) |*known| {
                if (std.mem.eql(u8, known.module_name, import.module)) break known;
            } else blk: {
                try foreigns.append(gen.arena, .{
                    .module_name = import.module,
                    .state_local = null,
                    .actions = &.{},
                    .refs = &.{},
                });
                break :blk &foreigns.items[foreigns.items.len - 1];
            };

            if (is_state) foreign.state_local = import.local;
            if (is_action) foreign.actions = try append_pair(gen.arena, foreign.actions, .{
                .local = import.local,
                .name = import.imported,
            });
            if (is_ref) foreign.refs = try append_pair(gen.arena, foreign.refs, .{
                .local = import.local,
                .name = import.imported,
            });
        }

        gen.foreigns = foreigns.items;
    }

    fn append_pair(arena: std.mem.Allocator, pairs: []const NamePair, pair: NamePair) Error![]const NamePair {
        const grown = try arena.alloc(NamePair, pairs.len + 1);
        @memcpy(grown[0..pairs.len], pairs);
        grown[pairs.len] = pair;
        return grown;
    }

    /// The family whose state this module imports under `name`.
    fn foreign_of_state(gen: *const Generator, name: []const u8) ?Foreign {
        for (gen.foreigns) |foreign| {
            if (foreign.state_local) |state| if (std.mem.eql(u8, state, name)) return foreign;
        }
        return null;
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

        try gen.write_state_json();
        for (gen.module.bindings) |binding| {
            // Event callbacks execute in the client companion, not during SSR.
            if (binding.value.* == .function) continue;
            const value = try gen.expression(binding.value);
            const name = try gen.fresh("local");
            try gen.line("const {s} = {s};", .{ name, value.code });
            try gen.line("_ = &{s};", .{name});
            try gen.locals.append(gen.arena, .{
                .name = name,
                .source_name = binding.name,
                .type = value.type,
                .binding = binding.value,
            });
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

        if (gen.request_used) {
            try w.writeAll("const Request = @import(\"request\").Request;\n");
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
            \\    // The request a server render reads as `Publr.request`, handed down
            \\    // through every component call.
            \\    publr_request: ?*const anyopaque = null,
            \\    // Rendered as a template's prototype, before any row: props the row
            \\    // fills hold placeholders, so classes drawn from them are left out.
            \\    publr_prototype: bool = false,
            \\    // The family roots this component renders inside, whose state their
            \\    // parts read on the server; handed down through every component call.
            \\    publr_family: ?*const rt.Family = null,
            \\
        );
        for (gen.module.props) |prop| {
            if (prop.bind_transport or prop.list_transport) {
                try w.print("    publr_bind_{s}: ?[]const u8 = null,\n", .{prop.name});
            }
        }
        try w.writeAll("};\n\n");
        // What the module's root is drawn by, so a consumer can hold its pages to a set
        // of layouts at compile time; empty when the root is markup.
        try w.print("pub const root_component: []const u8 = \"{s}\";\n\n", .{root_component_of(gen.module.root)});
        try w.writeAll("pub fn render(w: *std.Io.Writer, arena: std.mem.Allocator, props: Props) !void {\n    @setFloatMode(.strict);\n");

        // Taken by address, never discarded: whether the body allocates is only known for
        // sure once it is written (a store's setup may or may not), and `_ = &arena` is
        // right either way.
        try w.writeAll("    _ = &arena;\n");
        if (!gen.props_used) {
            try w.writeAll("    _ = props;\n");
        }

        if (gen.state_json_used) {
            gen.arena_used = true;
            try w.writeAll(gen.body.written()[0..gen.state_offset]);
            try w.writeAll(try gen.instance_declaration());
            try w.writeAll(gen.body.written()[gen.state_offset..]);
        } else {
            try w.writeAll(gen.body.written());
        }
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
        try gen.element_body(.{
            .static = tag,
        }, n, null);
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

    const Binding = struct {
        name: []const u8,
        wire: []const u8,
    };
    const SsrAttr = struct {
        name: []const u8,
        lowered: Lowered,
    };

    const OwnInitial = union(enum) {
        lowered: Lowered,
        unservable,
    };

    /// The seed expression behind an own-state wire (`state.value` on the
    /// family root, where `state.value = value ?? defaultValue` seeds it):
    /// the SSR initial the attribute renders while the wire hydrates.
    /// The initial value of the own state field `e` reads, when no prop seeds it.
    fn unseeded_initial(gen: *Generator, e: *const ExpressionIR) ?*const ExpressionIR {
        const wire = gen.module.wire orelse return null;
        const path = gen.wire_state_path(e) orelse return null;
        if (std.mem.indexOfScalar(u8, path.spec, '.') != null) return null;
        for (wire.seed_exprs) |seed| {
            if (std.mem.eql(u8, seed.field, path.spec)) return null;
        }
        for (wire.initials) |initial| {
            if (std.mem.eql(u8, initial.field, path.spec)) return initial.expr;
        }
        return null;
    }

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

    /// A list's rows as the render holds them: a state field's seed or initial, or,
    /// for a list a computation makes from one (`state.items.filter(…)`), the
    /// engine's answer read into the rows of the list it starts from.
    fn list_rows(gen: *Generator, e: *const ExpressionIR) Error!?Lowered {
        if (try gen.foreign_rows(e)) |rows| return rows;
        if (try gen.native_initial(e)) |initial| {
            if (initial == .lowered) return initial.lowered;
        }
        if (gen.expressions_field.len == 0) return null;
        const base = array_base(e) orelse return null;
        const rows: Lowered = if (gen.wire_state_path(base) != null) blk: {
            const initial = (try gen.native_initial(base)) orelse return null;
            if (initial == .unservable) return null;
            break :blk initial.lowered;
        } else gen.attempt_native(base) catch return null;
        if (rows.type != .array and rows.type != .strings) return null;
        const value = switch (try gen.server_value(e)) {
            .lowered => |lowered| lowered,
            .unservable => return null,
        };
        gen.arena_used = true;
        return .{
            .code = try std.fmt.allocPrint(gen.arena, "(try rt.value_into(@TypeOf({s}), arena, {s}))", .{ rows.code, value.code }),
            .type = rows.type,
        };
    }

    /// Whether a part's reads of its family's state have a first value in the render:
    /// the engine runs them over the nearest root's state.
    fn family_served(gen: *const Generator) bool {
        return gen.expressions_field.len > 0;
    }

    /// A list of a family's state read from a part (`state.items`, or a computation
    /// from it): the engine's answer read into rows of the type of the root's prop
    /// that seeds the field. Null when the field is not seeded by a list prop.
    fn foreign_rows(gen: *Generator, e: *const ExpressionIR) Error!?Lowered {
        if (!gen.family_served() or gen.foreigns.len == 0) return null;
        // The field itself, or the field a computation keeps rows of.
        const base = array_base(e) orelse e;
        const path = gen.wire_state_path(base) orelse return null;
        if (!path.foreign or path.spec.len == 0 or std.mem.indexOfScalar(u8, path.spec, '.') != null) return null;
        const foreign = gen.foreign_of_state(state_root_name(base) orelse return null) orelse return null;
        const family = for (gen.modules) |candidate| {
            if (std.mem.eql(u8, candidate.file_stem, foreign.module_name) or std.mem.eql(u8, candidate.name, foreign.module_name)) break candidate;
        } else return null;
        const wire = family.wire orelse return null;
        const seed = for (wire.seed_exprs) |candidate| {
            if (std.mem.eql(u8, candidate.field, path.spec)) break candidate;
        } else return null;
        if (seed.expr.* != .reference or seed.expr.reference.source != .prop) return null;
        const prop = find_field(family.props, seed.expr.reference.name) orelse return null;
        if (prop.type != .array and prop.type != .strings) return null;
        const value = switch (try gen.server_value(e)) {
            .lowered => |lowered| lowered,
            .unservable => return null,
        };
        var imported = false;
        for (gen.imports_used.items) |used| {
            if (std.mem.eql(u8, used, family.name)) imported = true;
        }
        if (!imported) try gen.imports_used.append(gen.arena, family.name);
        gen.arena_used = true;
        return .{
            // A prototype (a part drawn inside a caller's template) has no rows.
            .code = try std.fmt.allocPrint(gen.arena, "(if (props.publr_prototype) @as(@FieldType({s}.Props, \"{s}\"), &.{{}}) else try rt.value_into(@FieldType({s}.Props, \"{s}\"), arena, {s}))", .{ family.name, prop.name, family.name, prop.name, value.code }),
            .type = prop.type,
        };
    }

    /// `native_expression`, leaving nothing behind when it fails.
    fn attempt_native(gen: *Generator, e: *const ExpressionIR) Error!Lowered {
        gen.native_depth += 1;
        defer gen.native_depth -= 1;
        return gen.attempt(e);
    }

    /// `expression` lowered in the render alone, for a list's subject.
    fn native_expression(gen: *Generator, e: *const ExpressionIR) Error!Lowered {
        gen.native_depth += 1;
        defer gen.native_depth -= 1;
        return gen.expression(e);
    }

    /// `own_initial` lowered in the render alone, for a list's subject.
    fn native_initial(gen: *Generator, e: *const ExpressionIR) Error!?OwnInitial {
        gen.native_depth += 1;
        defer gen.native_depth -= 1;
        return gen.own_initial(e);
    }

    /// The SSR value behind an own-state wire: the seed expression when the
    /// field is seeded, the initial-state value otherwise; `.unservable` for
    /// getters and other fields the IR could not carry (the wire then
    /// hydrates without an SSR value, exactly as a foreign binding does).
    fn own_initial(gen: *Generator, e: *const ExpressionIR) Error!?OwnInitial {
        const path = gen.wire_state_path(e);
        // A family's state read from a part: the engine runs it over the root's state.
        if (path) |wired| if (wired.foreign) {
            if (!wired.own or gen.native_depth > 0) return .unservable;
            return try gen.server_value(e);
        };
        if (path) |wired| {
            for (gen.wire_aliases.items) |alias| {
                if (!wired.own or !std.mem.startsWith(u8, wired.spec, alias)) continue;
                if (wired.spec.len == alias.len or wired.spec[alias.len] == '.') {
                    return .{
                        .lowered = try gen.expression(e),
                    };
                }
            }
        }
        // Anything but a field of the state itself is the engine's: a computation,
        // or a path into a field (`state.items.length`).
        const field = if (path) |wired| std.mem.indexOfScalar(u8, wired.spec, '.') == null else false;
        if (!field) {
            const call = (try gen.slot_call_for(e, .peek)) orelse return null;
            if (!call.live) return null;
            // Without an engine the render has no first value for it.
            if (gen.expressions_field.len == 0 or gen.native_depth > 0) return if (call.own) .unservable else null;
            return try gen.server_value(e);
        }
        if (try gen.seed_lowered(e)) |lowered| {
            return .{
                .lowered = lowered,
            };
        }
        const wire = gen.module.wire orelse return null;
        for (wire.initials) |initial| {
            if (!std.mem.eql(u8, initial.field, path.?.spec)) continue;
            const expr = initial.expr orelse return .unservable;
            return .{
                .lowered = try gen.expression(expr),
            };
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
                try gen.write_value(.{
                    .code = try gen.truthy(lowered),
                    .type = .boolean,
                });
                try gen.static("\"");
            } else {
                try gen.line("if ({s}) try {s}.writeAll(\" {s}\");", .{
                    try gen.truthy(lowered),
                    gen.writer_name,
                    name,
                });
            },
            .string, .number, .enumeration => try gen.value_attribute(name, lowered),
            .value => try gen.line("try rt.write_value_attribute({s}, \"{s}\", {s});", .{ gen.writer_name, name, lowered.code }),
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
        var style_object: ?*const ExpressionIR = null;

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
                    try bindings.append(gen.arena, .{
                        .name = binding.name,
                        .wire = wire,
                    });
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
                                try bindings.append(gen.arena, .{
                                    .name = name,
                                    .wire = wired.spec,
                                });
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

                    // A style object: literal values are a static style text
                    // (camelCase keys kebab-cased, `--custom` kept); values from
                    // props are written by the render; one over state is bound.
                    // Written after the tag opens, with the other attributes.
                    if (std.mem.eql(u8, name, "style") and form == .expression and value.* == .object) {
                        style_object = value;
                        if (!style_is_literal(value)) {
                            if (try gen.live_style(value)) |text| {
                                if (try gen.slot_static(text)) |wired| {
                                    try bindings.append(gen.arena, .{
                                        .name = "style",
                                        .wire = wired.spec,
                                    });
                                }
                            }
                        }
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
                                        try own_ssr.append(gen.arena, .{
                                            .name = name,
                                            .lowered = initial,
                                        });
                                        show_wire = try gen.invert_wire(wired.spec);
                                    } else {
                                        try own_ssr.append(gen.arena, .{
                                            .name = name,
                                            .lowered = initial,
                                        });
                                        try bindings.append(gen.arena, .{
                                            .name = name,
                                            .wire = wired.spec,
                                        });
                                    },
                                    .unservable => if (std.mem.eql(u8, name, "hidden")) {
                                        if (show_wire != null) return gen.fail("an element carries two `:show` wires", .{});
                                        show_wire = try gen.invert_wire(wired.spec);
                                    } else {
                                        try bindings.append(gen.arena, .{
                                            .name = name,
                                            .wire = wired.spec,
                                        });
                                    },
                                }
                                continue;
                            }
                            if (std.mem.eql(u8, name, "hidden")) {
                                if (show_wire != null) return gen.fail("an element carries two `:show` wires", .{});
                                show_wire = try gen.invert_wire(wired.spec);
                            } else {
                                try bindings.append(gen.arena, .{
                                    .name = name,
                                    .wire = wired.spec,
                                });
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
                try bindings.append(gen.arena, .{
                    .name = name,
                    .wire = wire,
                });
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
        // Per layer computed from wired props, the wire that fills it in the
        // browser; null for a layer drawn here alone (a bare string prop's
        // placeholder is already empty).
        const class_wires = try gen.arena.alloc(?[]const u8, class_attrs.items.len);
        @memset(class_wires, null);
        for (class_attrs.items, class_wires) |a, *layer_wire| {
            if (a.form != .expression) continue;
            if (try gen.prop_wire(a.value, .classes)) |wire| {
                layer_wire.* = wire;
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
                        lowered = .{
                            .code = binding,
                            .type = lowered.type.unwrapped(),
                        };
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
                        // A closed string set seeds as its tag: the browser reads the same string.
                        .enumeration => try gen.line("try rt.write_seed_string({s}, @tagName({s}));", .{ gen.writer_name, lowered.code }),
                        .boolean => try gen.line("try {s}.writeAll(if ({s}) \"true\" else \"false\");", .{ gen.writer_name, lowered.code }),
                        .number => try gen.line("try rt.write_number({s}, {s});", .{ gen.writer_name, lowered.code }),
                        .null => try gen.static("null"),
                        .array, .item, .strings => try gen.line("try rt.write_seed_value({s}, arena, {s});", .{ gen.writer_name, lowered.code }),
                        .value => try gen.line("try rt.write_seed_from_value({s}, {s});", .{ gen.writer_name, lowered.code }),
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

        if (style_object) |value| {
            if (style_is_literal(value)) {
                try gen.static(" style=\"");
                try gen.static_style_object(value);
                try gen.static("\"");
            } else if (try gen.live_style(value)) |text| {
                if (try gen.own_initial(text)) |initial| {
                    if (initial == .lowered) try gen.ssr_attribute("style", initial.lowered);
                }
            } else {
                try gen.dynamic_style(value);
            }
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

        const any_wired = for (class_wires) |wire| {
            if (wire != null) break true;
        } else false;
        if (any_wired) {
            try gen.merged_classes(class_attrs.items, class_wires);
        } else if (class_attrs.items.len > 0) {
            // Every class goes through the consumer's merge, which writes it as the page
            // sends it (short names, with the consumer's class book).
            try gen.merged_classes(class_attrs.items, null);
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
                try gen.render_node(html.code);
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
            return .{
                .descriptor = descriptor.written(),
                .action = .{
                    .static = try gen.literal_text(ev.value),
                },
            };
        }

        return .{
            .descriptor = descriptor.written(),
            .action = try gen.action_of(try gen.expression(ev.value)),
        };
    }

    /// An `onInput={syncTitle}` attribute: the event name comes from the
    /// attribute name, the action from the referenced reactive action or prop.
    fn event_of_attribute(gen: *Generator, name: []const u8, a: PlainAttrIR) Error!Event {
        if (a.form != .expression) {
            return gen.fail("\"{s}\" must reference an action", .{name});
        }

        const descriptor = try util.eventDescriptor(gen.arena, name);
        if (try gen.wire_spec(a.value)) |wired| {
            if (std.mem.indexOf(u8, wired.spec, "::") != null) return .{
                .descriptor = descriptor,
                .action = .{
                    .static = wired.spec,
                },
            };
        }
        return .{
            .descriptor = descriptor,
            .action = try gen.action_of(try gen.expression(a.value)),
        };
    }

    fn action_of(gen: *Generator, lowered: Lowered) Error!Event.ActionRef {
        return switch (lowered.type) {
            .action_name => .{
                .static = try unquoted(gen, lowered.code),
            },
            .action => .{
                .runtime = lowered.code,
            },
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
                const whole = (try gen.own_initial(e)) orelse return gen.fail("no SSR initial for a reactive class", .{});
                if (whole == .unservable) return .{
                    .code = "\"\"",
                    .type = .string,
                };
                if (whole.lowered.type == .value) {
                    gen.arena_used = true;
                    return .{
                        .code = try std.fmt.allocPrint(gen.arena, "(try rt.value_classes(arena, {s}))", .{whole.lowered.code}),
                        .type = .string,
                    };
                }
                return whole.lowered;
            }
        }
        return gen.expression(e);
    }

    /// The inner ` p1, p2,` text of a `&.{ … }` class-part slice.
    /// The class stack's parts as Zig values. A layer with a wire (`wires`, by
    /// layer) is left empty in a template's prototype: its value there is a
    /// placeholder, and the browser draws the row's.
    fn class_parts(gen: *Generator, attrs: []const PlainAttrIR, wires: ?[]const ?[]const u8) Error![]const u8 {
        var parts: std.Io.Writer.Allocating = .init(gen.arena);

        for (attrs, 0..) |a, index| {
            if (a.form == .literal) {
                try parts.writer.print(" {s},", .{try zig_string(gen.arena, try gen.literal_text(a.value))});
                continue;
            }

            var lowered = if (std.mem.eql(u8, a.name, "class")) try gen.class_initial(a.value) else try gen.expression(a.value);

            if (lowered.type == .finite) {
                lowered = try gen.materialize_finite(lowered.type.finite);
            }

            const part = switch (lowered.type) {
                .string => lowered.code,
                .opt_string => try std.fmt.allocPrint(gen.arena, "({s} orelse \"\")", .{lowered.code}),
                .value => value: {
                    gen.arena_used = true;
                    break :value try std.fmt.allocPrint(gen.arena, "(try rt.value_classes(arena, {s}))", .{lowered.code});
                },
                else => return gen.fail("a class stack part is a {s}, which is not lowered", .{@tagName(lowered.type)}),
            };
            const wire = if (wires) |by_layer| by_layer[index] else null;

            if (wire) |code| {
                gen.props_used = true;
                try parts.writer.print(" (if (props.publr_prototype and ({s}) != null) @as([]const u8, \"\") else {s}),", .{ code, part });
            } else {
                try parts.writer.print(" {s},", .{part});
            }
        }

        return parts.written();
    }

    /// A stack of `class` attributes merges into one attribute through the
    /// consumer's class-merge implementation: a later conflicting utility
    /// wins, as in the DOM runtime.
    fn merged_classes(gen: *Generator, attrs: []const PlainAttrIR, wires: ?[]const ?[]const u8) Error!void {
        gen.arena_used = true;
        const parts = try gen.class_parts(attrs, wires);
        try gen.static(" class=\"");
        if (try gen.class_book_code()) |book| {
            try gen.line("try rt.write_merged_in({s}, arena, {s}, &.{{{s} }});", .{ gen.writer_name, book, parts });
        } else {
            try gen.line("try rt.write_merged({s}, arena, &.{{{s} }});", .{ gen.writer_name, parts });
        }
        try gen.static("\"");
    }

    /// The class book, from the request the render was handed; null when the program names
    /// no field for it.
    fn class_book_code(gen: *Generator) Error!?[]const u8 {
        if (gen.classes_field.len == 0 or gen.request.len == 0) return null;
        gen.request_used = true;
        gen.props_used = true;
        return try std.fmt.allocPrint(gen.arena, "(if (props.publr_request) |publr_request| @as(*const Request, @ptrCast(@alignCast(publr_request))).{s} else null)", .{gen.classes_field});
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

    /// A style object over state as the `styleText(…)` call the browser and the
    /// engine both run (its CSS text); null when it reads no state.
    fn live_style(gen: *Generator, e: *const ExpressionIR) Error!?*const ExpressionIR {
        const call = (try gen.slot_call_for(e, .peek)) orelse return null;
        if (!call.live) return null;
        const callee = try gen.arena.create(ExpressionIR);
        callee.* = .{
            .reference = .{
                .name = "styleText",
                .source = .global,
            },
        };
        const arguments = try gen.arena.alloc(*const ExpressionIR, 1);
        arguments[0] = e;
        const text = try gen.arena.create(ExpressionIR);
        text.* = .{
            .call = .{
                .callee = callee,
                .arguments = arguments,
            },
        };
        return text;
    }

    /// A style object whose values the render knows (props, the engine's for a
    /// computation), written as `name:value` pairs, empty ones left out.
    fn dynamic_style(gen: *Generator, e: *const ExpressionIR) Error!void {
        var pairs: std.Io.Writer.Allocating = .init(gen.arena);
        for (e.object.fields) |style_field| {
            const lowered = try gen.expression(style_field.value);
            const text: []const u8 = switch (lowered.type) {
                .string => try std.fmt.allocPrint(gen.arena, "@as(?[]const u8, {s})", .{lowered.code}),
                .opt_string => lowered.code,
                .number => try std.fmt.allocPrint(gen.arena, "@as(?[]const u8, try rt.number_to_string(arena, {s}))", .{lowered.code}),
                .opt_number => try std.fmt.allocPrint(gen.arena, "(if ({s}) |number| @as(?[]const u8, try rt.number_to_string(arena, number)) else null)", .{lowered.code}),
                .enumeration => try std.fmt.allocPrint(gen.arena, "@as(?[]const u8, @tagName({s}))", .{lowered.code}),
                .null => "@as(?[]const u8, null)",
                .value => try gen.value_into(lowered.code, .opt_string),
                else => return gen.fail("style map value \"{s}\" is a {s}, which is not lowered", .{ style_field.name, @tagName(lowered.type) }),
            };
            try pairs.writer.print(" .{{ {s}, {s} }},", .{ try zig_string(gen.arena, try style_name(gen.arena, style_field.name)), text });
        }
        gen.arena_used = true;
        try gen.line("try rt.write_attr_cond({s}, \"style\", try rt.style_text(arena, &.{{{s} }}));", .{ gen.writer_name, pairs.written() });
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
            const text = try gen.literal_text(a.value);

            try gen.static(" ");
            try gen.static(name);
            try gen.static("=\"");
            if (is_url_attribute(name) and root_path(text)) {
                if (try gen.url_base_code()) |base| {
                    try gen.flush();
                    try gen.line("try rt.write_url_base({s}, {s});", .{ gen.writer_name, base });
                }
            }
            try gen.static_escaped(text, true);
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
                    try gen.write_value(.{
                        .code = binding,
                        .type = .boolean,
                    });
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
            .string, .number, .enumeration => try gen.value_attribute(name, lowered),
            .null => {},
            .value => if (std.mem.eql(u8, name, "class")) {
                gen.arena_used = true;
                try gen.value_attribute(name, .{
                    .code = try std.fmt.allocPrint(gen.arena, "(try rt.value_classes(arena, {s}))", .{lowered.code}),
                    .type = .string,
                });
            } else try gen.ssr_attribute(name, lowered),
            else => return gen.fail("attribute \"{s}\" has a value of type {s}, which is not lowered", .{
                name,
                @tagName(lowered.type),
            }),
        }
    }

    /// A string, number or enum attribute, an optional one only when present. A URL
    /// attribute's root path goes under the base the project is served at
    /// (`rt.url_base`, set by the host), unless it carries it already.
    fn value_attribute(gen: *Generator, name: []const u8, lowered: Lowered) Error!void {
        const url = is_url_attribute(name) and lowered.type.unwrapped() == .string;

        if (lowered.type.is_optional()) {
            const binding = try gen.fresh("value");
            try gen.line("if ({s}) |{s}| {{", .{ lowered.code, binding });
            gen.indent += 1;
            try gen.static(" ");
            try gen.static(name);
            try gen.static("=\"");
            if (url) try gen.url_base_for(binding);
            try gen.write_value(.{
                .code = binding,
                .type = lowered.type.unwrapped(),
            });
            try gen.static("\"");
            try gen.flush();
            gen.indent -= 1;
            try gen.line("}}", .{});
            return;
        }

        try gen.static(" ");
        try gen.static(name);
        try gen.static("=\"");
        if (url) {
            const binding = try gen.fresh("url");
            try gen.flush();
            try gen.line("const {s} = {s};", .{ binding, lowered.code });
            try gen.url_base_for(binding);
            try gen.write_value(.{
                .code = binding,
                .type = lowered.type,
            });
        } else {
            try gen.write_value(lowered);
        }
        try gen.static("\"");
    }

    /// A node written where it stands, handed the request this render holds.
    fn render_node(gen: *Generator, code: []const u8) Error!void {
        gen.props_used = true;
        try gen.line("try {s}.render_in({s}, arena, props.publr_request, {s});", .{ code, gen.writer_name, gen.family_code });
    }

    fn url_base_for(gen: *Generator, code: []const u8) Error!void {
        const base = try gen.url_base_code() orelse return;

        try gen.flush();
        try gen.line("try rt.write_url_base_for({s}, {s}, {s});", .{ gen.writer_name, base, code });
    }

    /// The base path out of the render's request (`Program.url_base`), empty in a render
    /// handed none; null when the program names no base.
    fn url_base_code(gen: *Generator) Error!?[]const u8 {
        if (gen.url_base.len == 0) return null;

        var fields = gen.request;
        var path = std.mem.splitScalar(u8, gen.url_base, '.');

        while (path.next()) |segment| {
            const field = find_field(fields, segment) orelse {
                return gen.fail("the URL base \"{s}\" is not a field of the request", .{gen.url_base});
            };
            switch (field.type) {
                .item => |inner| fields = inner,
                .string => if (path.peek() != null) {
                    return gen.fail("the URL base \"{s}\" is not a field of the request", .{gen.url_base});
                },
                else => return gen.fail("the URL base \"{s}\" is not a string", .{gen.url_base}),
            }
        }

        gen.request_used = true;
        gen.props_used = true;

        return try std.fmt.allocPrint(
            gen.arena,
            "(if (props.publr_request) |publr_base_request| @as(*const Request, @ptrCast(@alignCast(publr_base_request))).{s} else \"\")",
            .{gen.url_base},
        );
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
                                    .value => try gen.value_into(initial.lowered.code, .opt_string),
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

            // Markup for a node prop (`actions={<Button/>}`, `empty={none && <Empty/>}`):
            // a block node the callee renders where it reaches it, absent when guarded off.
            if (form == .expression and (target.type == .node or target.type == .opt_node) and contains_jsx(value)) {
                const markup = try gen.node_value(value);
                if (target.type == .node and markup.type != .node) {
                    return gen.fail("<{s}>'s \"{s}\" is required markup; a guard may leave it out", .{ name, attribute_name });
                }
                try fields.writer.print(" .{f} = {s},", .{ std.zig.fmtId(attribute_name), markup.code });
                continue;
            }

            // A literal list of objects fills an array prop: the callee's item type
            // gives each field its type (`parents={[{ label: "Structure", href }]}`).
            if (form == .expression and target.type == .array and value.* == .array and value.array.items.len > 0) {
                try fields.writer.print(" .{f} = {s},", .{
                    std.zig.fmtId(attribute_name),
                    try gen.object_list(name, target, value.array.items),
                });
                continue;
            }

            // A style object fills a string-typed style prop as its CSS text.
            if (form == .expression and std.mem.eql(u8, attribute_name, "style") and value.* == .object) {
                try fields.writer.print(" .{f} = {s},", .{
                    std.zig.fmtId(attribute_name),
                    try zig_string(gen.arena, try gen.style_object_text(value)),
                });
                continue;
            }

            // `is_new ? "New" : state.label`: the test is the server's to decide, an arm
            // reads state. The server picks the arm, and the callee gets its value and, when
            // the arm is a wire, its wire.
            if (form == .expression and target.bind_transport and value.* == .conditional) {
                if (try gen.prop_conditional(value, target)) |chosen| {
                    try fields.writer.print(" .{f} = {s}, .publr_bind_{s} = {s},", .{ std.zig.fmtId(attribute_name), chosen.value, attribute_name, chosen.wire });
                    continue;
                }
            }

            if (form == .expression) {
                // A reactive binding crosses the boundary as the prop's wire;
                // a foreign one has no SSR value, so the prop keeps its
                // default until hydration.
                if (try gen.wire_spec(value)) |wired| {
                    if (!target.bind_transport and !target.list_transport) {
                        return gen.fail("<{s}>'s \"{s}\" cannot carry a wire (not a scalar or list prop)", .{ name, attribute_name });
                    }
                    if (wired.own) {
                        const state = (try gen.own_initial(value)) orelse {
                            return gen.fail("no SSR value for this module's own state on <{s}>", .{name});
                        };
                        switch (state) {
                            .lowered => |initial| if (target.list_transport) {
                                // The caller's rows become the callee's row type.
                                gen.arena_used = true;
                                try fields.writer.print(" .{f} = try rt.prop_array(@FieldType({s}.Props, \"{s}\"), arena, {s}),", .{ std.zig.fmtId(attribute_name), name, attribute_name, initial.code });
                            } else try fields.writer.print(" .{f} = {s},", .{ std.zig.fmtId(attribute_name), (if (target.type.unwrapped() == .enumeration) try gen.enum_expression(value, target.type) else null) orelse try gen.coerce(initial, target.type) }),
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
                            .array, .strings => "&.{}",
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

        // Every call hands the request down, so any component may read it.
        gen.props_used = true;
        try fields.writer.writeAll(" .publr_request = props.publr_request,");
        try fields.writer.writeAll(if (gen.template_depth > 0) " .publr_prototype = true," else " .publr_prototype = props.publr_prototype,");
        try fields.writer.print(" .publr_family = {s},", .{gen.family_code});

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

    /// A node prop's value: markup becomes a block over the props and locals in scope, as a
    /// component's children do; `a && <X/>`, `a ? <X/> : <Y/>` and `a || b` choose between
    /// blocks, and an arm that renders nothing is null, so the callee sees it absent.
    fn node_value(gen: *Generator, e: *const ExpressionIR) Error!Lowered {
        switch (e.*) {
            .node => |node_expr| {
                const capture = try gen.fresh("markup");
                const body_type = try capitalize(gen.arena, capture);

                try gen.block_struct(body_type, &.{node_expr.node});

                var captured: std.Io.Writer.Allocating = .init(gen.arena);
                try captured.writer.writeAll(" .props = &props,");
                try captured.writer.print(" .publr_family = {s},", .{gen.family_code});
                try gen.capture_state(&captured.writer);
                for (gen.locals.items) |local| {
                    try captured.writer.print(" .{s} = &{s},", .{ local.name, local.name });
                }
                gen.props_used = true;
                try gen.line("const {s} = .{{{s} }};", .{ capture, captured.written() });
                return .{
                    .code = try std.fmt.allocPrint(gen.arena, "rt.block(&{s}, {s})", .{ capture, body_type }),
                    .type = .node,
                };
            },
            .conditional => |conditional| {
                const test_code = try gen.truthy(try gen.expression(conditional.@"test"));
                const consequent = try gen.optional_markup(conditional.consequent);
                const alternate = try gen.optional_markup(conditional.alternate);
                return .{
                    .code = try std.fmt.allocPrint(gen.arena, "(if ({s}) {s} else {s})", .{ test_code, consequent, alternate }),
                    .type = .opt_node,
                };
            },
            .operation => |operation_ir| {
                if (std.mem.eql(u8, operation_ir.operator, "&&")) {
                    const test_code = try gen.truthy(try gen.expression(operation_ir.left));
                    const markup = try gen.optional_markup(operation_ir.right);
                    return .{
                        .code = try std.fmt.allocPrint(gen.arena, "(if ({s}) {s} else null)", .{ test_code, markup }),
                        .type = .opt_node,
                    };
                }
                if (std.mem.eql(u8, operation_ir.operator, "||")) {
                    const left = try gen.optional_markup(operation_ir.left);
                    const right = try gen.optional_markup(operation_ir.right);
                    return .{
                        .code = try std.fmt.allocPrint(gen.arena, "({s} orelse {s})", .{ left, right }),
                        .type = .opt_node,
                    };
                }
                return gen.fail("markup combined with \"{s}\" is not lowered", .{operation_ir.operator});
            },
            else => {
                const lowered = try gen.expression(e);
                return switch (lowered.type) {
                    .node, .opt_node => lowered,
                    .null => .{
                        .code = "null",
                        .type = .opt_node,
                    },
                    else => gen.fail("a {s} where markup goes", .{@tagName(lowered.type)}),
                };
            },
        }
    }

    /// `node_value` as a `?rt.Node`, `null` for an arm that renders nothing.
    fn optional_markup(gen: *Generator, e: *const ExpressionIR) Error![]const u8 {
        if (is_null_literal(e) or e.* == .absent or (e.* == .literal and e.literal == .boolean)) {
            return "@as(?rt.Node, null)";
        }
        const markup = try gen.node_value(e);
        return std.fmt.allocPrint(gen.arena, "@as(?rt.Node, {s})", .{markup.code});
    }

    /// `&[_]Callee.ParentsItem{ .{ .label = "Structure", .href = … }, … }`: an array
    /// literal of object literals for an array prop, each field coerced to the item's type.
    fn object_list(gen: *Generator, callee: []const u8, target: Field, items: []const *const ExpressionIR) Error![]const u8 {
        const prefix = "[]const ";
        if (!std.mem.startsWith(u8, target.zig_type, prefix)) {
            return gen.fail("\"{s}\" takes no list of objects", .{target.name});
        }
        const item_type = target.zig_type[prefix.len..];
        var out: std.Io.Writer.Allocating = .init(gen.arena);
        try out.writer.print("&[_]{s}.{s}{{", .{ callee, item_type });
        for (items) |item| {
            if (item.* != .object) return gen.fail("a list for \"{s}\" holds only object literals", .{target.name});
            try out.writer.writeAll(" .{");
            for (item.object.fields) |object_field| {
                const field = find_field(target.type.array, object_field.name) orelse {
                    return gen.fail("\"{s}\" items have no field \"{s}\"", .{ target.name, object_field.name });
                };
                const lowered = try gen.expression(object_field.value);
                try out.writer.print(" .{f} = {s},", .{ std.zig.fmtId(object_field.name), try gen.coerce(lowered, field.type) });
            }
            try out.writer.writeAll(" },");
        }
        try out.writer.writeAll(" }");
        return out.written();
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
            try captured.writer.print(" .publr_family = {s},", .{gen.family_code});
            try gen.capture_state(&captured.writer);
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
        const saved_family = gen.family_code;
        // Restored however the block ends: a lowering that is attempted and fails
        // leaves the render it returns to as it was.
        defer gen.family_code = saved_family;
        gen.body = .init(gen.arena);
        gen.indent = 0;
        gen.writer_name = "w";
        gen.family_code = "publr_family";

        try gen.line("", .{});
        try gen.line("const {s} = struct {{", .{body_type});
        gen.indent += 1;
        try gen.line("pub fn render(cap: anytype, w: *std.Io.Writer, arena: std.mem.Allocator, publr_family_given: ?*const rt.Family) anyerror!void {{", .{});
        gen.indent += 1;
        try gen.line("_ = &arena;", .{});
        try gen.line("const props = cap.props.*;", .{});
        try gen.line("_ = &props;", .{});
        // Rendered inside the family roots of whoever renders the node, else the caller's.
        try gen.line("const publr_family: ?*const rt.Family = publr_family_given orelse cap.publr_family;", .{});
        try gen.line("_ = &publr_family;", .{});
        if (gen.state_json) |name| {
            try gen.line("const {s} = cap.{s};", .{ name, name });
            try gen.line("_ = &{s};", .{name});
        }

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
                .binding => |binding| .{
                    .name = binding.name,
                    .form = binding.form,
                    .value = binding.value,
                },
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
                if (wired.own and !wired.foreign) return gen.fail("an SSR value from this module's own reactive state is not lowered yet (\"{s}\")", .{attr_name});
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
                        if (wired.own and !wired.foreign) return gen.fail("an SSR value from this module's own reactive state is not lowered yet (\"{s}\")", .{attr_name});
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

        // Every class goes through the consumer's merge, which writes it as the page sends it.
        if (class_attrs.items.len > 0) {
            gen.arena_used = true;
            const parts = try gen.class_parts(class_attrs.items, null);
            if (try gen.class_book_code()) |book| {
                try fields.writer.print(" .class = try rt.merge_classes_in(arena, {s}, &.{{{s} }}),", .{ book, parts });
            } else {
                try fields.writer.print(" .class = try rt.merge_classes(arena, &.{{{s} }}),", .{parts});
            }
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
            return gen.element_body(.{
                .static = try gen.literal_text(as.value),
            }, n, "as");
        }

        const lowered = try gen.expression(as.value);
        const code = switch (lowered.type) {
            .string => lowered.code,
            .enumeration => try std.fmt.allocPrint(gen.arena, "@tagName({s})", .{lowered.code}),
            .value => try gen.value_into(lowered.code, .string),
            else => return gen.fail("<Dynamic as> is a {s}, which is not lowered", .{@tagName(lowered.type)}),
        };
        const binding = try gen.fresh("tag");

        try gen.line("const {s} = {s};", .{ binding, code });
        try gen.element_body(.{
            .runtime = binding,
        }, n, "as");
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
        // A live value is the engine's; `coerce` picks its tag.
        if (gen.expressions_field.len > 0 and gen.native_depth == 0 and gen.wire_state_path(value) == null) {
            if (try gen.slot_call_for(value, .peek)) |call| if (call.live) return null;
        }
        const enumeration = target.unwrapped().enumeration;
        // A state field no prop seeds starts at its initial value: `"md" as Size` is the
        // literal, checked against the enum like one written in place.
        if (gen.unseeded_initial(value)) |initial| {
            if (initial.* == .literal and initial.literal == .string) return try gen.coerce_literal(initial.literal.string, target);
        }
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

    const StringLookup = struct {
        entries: []const Type.MapEntry,
        key_code: []const u8,
    };

    /// The map and the lowered key of `TONES[kind]` over a finite map with a
    /// string key; null when the value is not such a lookup.
    fn string_lookup(gen: *Generator, value: *const ExpressionIR) Error!?StringLookup {
        if (value.* != .member or value.member.property == .string) return null;
        const object = try gen.expression(value.member.object);
        if (object.type != .finite_map) return null;
        const key = try gen.member_index(value.member.property);
        if (key.type != .string) return null;
        return .{
            .entries = object.type.finite_map,
            .key_code = key.code,
        };
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
        if (lowered.type == .value) return gen.value_into(lowered.code, target);
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
                    try gen.write_child_value(.{
                        .code = binding,
                        .type = left.type.unwrapped(),
                    });
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
                        const saved = Lowered{
                            .code = name,
                            .type = left.type,
                        };
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
                    // JavaScript truthiness, as the browser half decides it: an empty string,
                    // zero or a node that draws nothing is false, not only an absent value.
                    const test_code = try gen.truthy(left);
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
        try gen.template_body(try gen.template_id(body), false, body);
        if (unwraps) {
            try gen.flush();
            gen.indent -= 1;
            try gen.line("}}", .{});
            gen.present_values.shrinkRetainingCapacity(present_count);
        }
        try gen.static("</template>");

        // The server-rendered arm, tested as the plain branch tests it: JavaScript truthiness.
        const test_code = try gen.truthy(tested);
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
        inner.* = .{
            .operation = .{
                .operator = "&&",
                .left = guards.operation.right,
                .right = e.operation.right,
            },
        };
        const outer = try gen.arena.create(ExpressionIR);
        outer.* = .{
            .operation = .{
                .operator = "&&",
                .left = guards.operation.left,
                .right = inner,
            },
        };
        try gen.split_guards.append(gen.arena, .{
            .expression = e,
            .split = outer,
        });
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
            const parameter_source = function.function.parameters[0];
            const parameter = try gen.local_name(parameter_source);
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
                try gen.template_body(try gen.template_id(e), true, body);
            }
            try gen.static("</template>");
            if (wired.own and gen.template_depth == 0) {
                if (try gen.list_rows(call.callee.member.object)) |rows| try gen.seeded_rows(rows, function.function);
            }
            return;
        }
        if (gen.list_prop(call.callee.member.object)) |prop| {
            return gen.prop_list_loop(e, prop, function.function);
        }
        if (try gen.slot_call(call.callee.member.object)) |slot| {
            if (slot.live and slot.arguments.len > 0) {
                return gen.slot_list_loop(e, call.callee.member.object, function.function);
            }
        }
        const subject_expr = call.callee.member.object;
        const subject = if (gen.expressions_field.len > 0)
            gen.attempt_native(subject_expr) catch |failure| switch (failure) {
                error.Pjsx => (try gen.list_rows(subject_expr)) orelse return failure,
                else => return failure,
            }
        else
            try gen.native_expression(subject_expr);
        const item_type: Type = switch (subject.type) {
            .array => |fields| .{
                .item = fields,
            },
            .strings => .string,
            else => return gen.fail("`.map` on a {s}, which is not a lowered array", .{@tagName(subject.type)}),
        };
        const parameter_source = function.function.parameters[0];
        const parameter = try gen.local_name(parameter_source);

        try gen.line("for ({s}) |{s}| {{", .{ subject.code, parameter });
        gen.indent += 1;
        try gen.locals.append(gen.arena, .{
            .name = parameter,
            .source_name = parameter_source,
            .type = item_type,
        });
        try gen.child_expression(function.function.body);
        try gen.flush();
        _ = gen.locals.pop();
        gen.indent -= 1;
        try gen.line("}}", .{});
    }

    const ChosenArm = struct {
        value: []const u8,
        wire: []const u8,
    };

    /// A conditional prop whose test is not reactive but one of whose arms is: the value
    /// and the wire as the server picks them. Null when the test is reactive (a wire
    /// already) or neither arm is.
    fn prop_conditional(gen: *Generator, e: *const ExpressionIR, target: Field) Error!?ChosenArm {
        const conditional = e.conditional;
        if (try gen.wire_spec(conditional.@"test") != null) return null;
        const consequent = try gen.wire_spec(conditional.consequent);
        const alternate = try gen.wire_spec(conditional.alternate);
        if (consequent == null and alternate == null) return null;

        const tested = try gen.truthy(try gen.expression(conditional.@"test"));
        const arms = [2]*const ExpressionIR{ conditional.consequent, conditional.alternate };
        const wires = [2]?Wired{ consequent, alternate };
        var values: [2][]const u8 = undefined;
        var specs: [2][]const u8 = undefined;
        for (arms, wires, 0..) |arm, wired, index| {
            if (wired) |wire| {
                const initial = (try gen.own_initial(arm)) orelse return null;
                if (initial == .unservable) return null;
                values[index] = try gen.coerce(initial.lowered, target.type);
                specs[index] = try std.fmt.allocPrint(gen.arena, "@as(?[]const u8, {s})", .{try zig_string(gen.arena, wire.spec)});
            } else {
                values[index] = try gen.coerce(try gen.expression(arm), target.type);
                specs[index] = "@as(?[]const u8, null)";
            }
        }
        return .{
            .value = try std.fmt.allocPrint(gen.arena, "(if ({s}) {s} else {s})", .{ tested, values[0], values[1] }),
            .wire = try std.fmt.allocPrint(gen.arena, "(if ({s}) {s} else {s})", .{ tested, specs[0], specs[1] }),
        };
    }

    /// The list prop `e` names, when it is one a caller may hand in wired.
    fn list_prop(gen: *Generator, e: *const ExpressionIR) ?Field {
        if (e.* != .reference or e.reference.source != .prop) return null;
        const field = find_field(gen.module.props, e.reference.name) orelse return null;
        return if (field.list_transport) field else null;
    }

    /// `items.map(...)` over a list prop: wired by the caller, a reactive list bound to the
    /// caller's state (its prototype, then the rows the server draws, keyed as the runtime
    /// keeps them); handed in plain, the rows alone.
    fn prop_list_loop(gen: *Generator, e: *const ExpressionIR, prop: Field, function: anytype) Error!void {
        const parameter_source = function.parameters[0];
        const parameter = try gen.local_name(parameter_source);
        const capture = try gen.fresh("list_wire");
        const subject: Lowered = .{
            .code = try std.fmt.allocPrint(gen.arena, "props.{f}", .{std.zig.fmtId(prop.name)}),
            .type = prop.type,
        };
        gen.props_used = true;

        try gen.flush();
        // The reactive arm only where its rows can be a prototype; a list whose rows read
        // what a wire cannot say stays rows alone, as before.
        const reactive = try gen.trial(gen.indent + 1, struct {
            fn emit(inner: *Generator, args: anytype) Error!void {
                try inner.reactive_rows(args.e, args.function, args.capture, args.subject);
            }
        }.emit, .{
            .e = e,
            .function = function,
            .capture = capture,
            .subject = subject,
        });

        if (reactive) |arm| {
            try gen.line("if (props.publr_bind_{s}) |{s}| {{", .{ prop.name, capture });
            try gen.body.writer.writeAll(arm.body);
            try gen.blocks.writer.writeAll(arm.blocks);
            try gen.line("}} else {{", .{});
            gen.indent += 1;
        }
        const item_type: Type = switch (prop.type) {
            .array => |fields| .{
                .item = fields,
            },
            else => .string,
        };
        try gen.line("for ({s}) |{s}| {{", .{ subject.code, parameter });
        gen.indent += 1;
        try gen.locals.append(gen.arena, .{
            .name = parameter,
            .source_name = parameter_source,
            .type = item_type,
        });
        try gen.child_expression(function.body);
        try gen.flush();
        _ = gen.locals.pop();
        gen.indent -= 1;
        try gen.line("}}", .{});
        if (reactive != null) {
            gen.indent -= 1;
            try gen.line("}}", .{});
        }
    }

    const Arm = struct {
        body: []const u8,
        blocks: []const u8,
    };

    /// Runs `emit` into fresh buffers at `indent`; the code it wrote when it lowered, null
    /// (everything it touched put back) when it did not.
    fn trial(gen: *Generator, indent: u32, comptime emit: anytype, args: anytype) Error!?Arm {
        const saved_body = gen.body;
        const saved_blocks = gen.blocks;
        const saved_indent = gen.indent;
        const saved_templates = gen.templates.items.len;
        const saved_aliases = gen.wire_aliases.items.len;
        const saved_locals = gen.locals.items.len;
        const saved_imports = gen.imports_used.items.len;
        const saved_writer = gen.writer_name;
        const saved_depths = .{ gen.template_depth, gen.seeded_depth };

        gen.body = .init(gen.arena);
        gen.blocks = .init(gen.arena);
        gen.indent = indent;
        const lowered = if (emit(gen, args)) true else |failure| switch (failure) {
            error.Pjsx => false,
            else => return failure,
        };
        const arm: Arm = .{
            .body = gen.body.written(),
            .blocks = gen.blocks.written(),
        };

        gen.body = saved_body;
        gen.blocks = saved_blocks;
        gen.indent = saved_indent;
        gen.pending.clearRetainingCapacity();
        if (!lowered) {
            gen.templates.shrinkRetainingCapacity(saved_templates);
            gen.wire_aliases.shrinkRetainingCapacity(saved_aliases);
            gen.locals.shrinkRetainingCapacity(saved_locals);
            gen.imports_used.shrinkRetainingCapacity(saved_imports);
            gen.writer_name = saved_writer;
            gen.template_depth = saved_depths[0];
            gen.seeded_depth = saved_depths[1];
            return null;
        }
        return arm;
    }

    /// The prototype of a live list bound by `capture` (the runtime's spec of its subject),
    /// then the rows the server draws from `subject`; none when it has no first value.
    fn reactive_rows(gen: *Generator, e: *const ExpressionIR, function: anytype, capture: []const u8, subject: ?Lowered) Error!void {
        const parameter_source = function.parameters[0];
        const parameter = try gen.local_name(parameter_source);
        const body = function.body;
        try gen.wire_aliases.append(gen.arena, parameter);
        defer _ = gen.wire_aliases.pop();
        try gen.static("<template data-p-template=\"");
        try gen.static(try gen.template_id(e));
        try gen.static("\" data-p-for=\"");
        try gen.static_escaped(parameter, true);
        try gen.static(" of ");
        try gen.flush();
        try gen.line("try rt.escape({s}, {s});", .{ gen.writer_name, capture });
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
        try gen.static(">");
        try gen.template_body(try gen.template_id(e), true, body);
        try gen.static("</template>");
        if (subject) |rows| try gen.seeded_rows(rows, function);
        try gen.flush();
    }

    /// `state.items[key].map(...)`, a live list whose subject also reads props: bound by
    /// its compiled expression called with their values (`$e_Group_3(name: "seo")`). The
    /// browser draws its rows; the server has no first value for them.
    fn slot_list_loop(gen: *Generator, e: *const ExpressionIR, subject: *const ExpressionIR, function: anytype) Error!void {
        const spec = (try gen.slot_runtime(subject)) orelse return gen.fail("a live list's subject has no binding", .{});
        const capture = try gen.fresh("list_wire");

        try gen.flush();
        try gen.line("const {s} = {s}.?;", .{ capture, spec });
        try gen.reactive_rows(e, function, capture, null);
    }

    /// A template's prototype: written once per page when its code reads nothing of the
    /// instance (no prop but the page's request, no local from around it), since a later
    /// anchor of the same template finds it by id (the runtime keeps every prototype a page
    /// registers). One that reads its instance is written each time; so is every one in a
    /// render handed no set to keep the page's in.
    fn template_body(gen: *Generator, id: []const u8, comptime row: bool, body: *const ExpressionIR) Error!void {
        gen.template_depth += 1;
        defer gen.template_depth -= 1;

        const templates = (try gen.templates_code()) orelse {
            if (row) try gen.row_body(body) else try gen.branch_body(body);
            return;
        };
        const outer_locals = gen.locals.items.len;

        try gen.flush();
        const start = gen.body.written().len;
        if (row) try gen.row_body(body) else try gen.branch_body(body);
        try gen.flush();

        const code = try gen.arena.dupe(u8, gen.body.written()[start..]);

        if (!instance_free(code, gen.locals.items[0..outer_locals])) return;

        gen.body.shrinkRetainingCapacity(start);
        try gen.line("if (rt.first_template({s}, {s})) {{", .{ templates, try zig_string(gen.arena, id) });
        var lines = std.mem.splitScalar(u8, code, '\n');
        while (lines.next()) |code_line| {
            if (code_line.len == 0) continue;
            try gen.body.writer.writeAll("    ");
            try gen.body.writer.writeAll(code_line);
            try gen.body.writer.writeByte('\n');
        }
        try gen.line("}}", .{});
    }

    /// The page's set of templates written, from the request the render was handed; null
    /// when the program names no field for it.
    fn templates_code(gen: *Generator) Error!?[]const u8 {
        if (gen.templates_field.len == 0 or gen.request.len == 0) return null;
        gen.request_used = true;
        gen.props_used = true;
        return try std.fmt.allocPrint(gen.arena, "(if (props.publr_request) |publr_request| @as(*const Request, @ptrCast(@alignCast(publr_request))).{s} else null)", .{gen.templates_field});
    }

    fn template_id(gen: *Generator, expr: *const ExpressionIR) Error![]const u8 {
        for (gen.templates.items) |entry| {
            if (entry.expression == expr) return entry.name;
        }
        const name = try std.fmt.allocPrint(gen.arena, "{s}-{d}", .{ gen.module.name, gen.templates.items.len });
        try gen.templates.append(gen.arena, .{
            .expression = expr,
            .name = name,
        });
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
            try gen.template_body(try gen.template_id(body), false, body);
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

    /// A row's body, which carries the row's store and key, so it is one element: a body
    /// that is an expression (`item.primary && <form/>`) lands in a wrapper, or the row's
    /// store would sit on the branch's anchor and the branch's content would not see the item.
    fn row_body(gen: *Generator, body: *const ExpressionIR) Error!void {
        const wrapper = body.* != .node;
        if (wrapper) try gen.contents_wrapper();
        try gen.child_expression(body);
        if (wrapper) try gen.static("</span>");
    }

    /// The `<span class="contents">` a body that is not one element is wrapped in, its
    /// class through the consumer's merge like every other.
    fn contents_wrapper(gen: *Generator) Error!void {
        gen.arena_used = true;
        try gen.static("<span class=\"");
        if (try gen.class_book_code()) |book| {
            try gen.line("try rt.write_merged_in({s}, arena, {s}, &.{{ \"contents\", }});", .{ gen.writer_name, book });
        } else {
            try gen.line("try rt.write_merged({s}, arena, &.{{ \"contents\", }});", .{gen.writer_name});
        }
        try gen.static("\">");
    }

    fn branch_body(gen: *Generator, body: *const ExpressionIR) Error!void {
        const wrapper = body.* != .node or body.node.node.* != .element;
        if (wrapper) try gen.contents_wrapper();
        try gen.child_expression(body);
        if (wrapper) try gen.static("</span>");
    }

    fn seeded_rows(gen: *Generator, subject: Lowered, function: anytype) Error!void {
        const item_type: Type = switch (subject.type) {
            .array => |fields| .{
                .item = fields,
            },
            .strings => .string,
            else => return gen.fail("a seeded list needs an array", .{}),
        };
        const parameter_source = function.parameters[0];
        const parameter = try gen.local_name(parameter_source);
        const index = try gen.fresh("row_index");
        try gen.line("for ({s}, 0..) |{s}, {s}| {{", .{ subject.code, parameter, index });
        gen.indent += 1;
        try gen.line("_ = &{s};", .{index});
        try gen.locals.append(gen.arena, .{
            .name = parameter,
            .source_name = parameter_source,
            .type = item_type,
        });
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
        try gen.row_body(function.body);
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
            try gen.write_value(.{
                .code = binding,
                .type = lowered.type.unwrapped(),
            });
            try gen.flush();
            gen.indent -= 1;
            try gen.line("}}", .{});
            return;
        }

        switch (lowered.type) {
            .string => try gen.line("try rt.escape({s}, {s});", .{ gen.writer_name, lowered.code }),
            .node => {
                gen.arena_used = true;
                try gen.render_node(lowered.code);
            },
            .number => try gen.line("try rt.write_number({s}, {s});", .{ gen.writer_name, lowered.code }),
            .boolean => try gen.line("try {s}.writeAll(if ({s}) \"true\" else \"false\");", .{ gen.writer_name, lowered.code }),
            .null => {},
            .enumeration => try gen.line("try {s}.writeAll(@tagName({s}));", .{ gen.writer_name, lowered.code }),
            .value => try gen.line("try rt.write_value_text({s}, {s});", .{ gen.writer_name, lowered.code }),
            else => return gen.fail("a {s} cannot be written as text", .{@tagName(lowered.type)}),
        }
    }

    // -- wires ----------------------------------------------------------------
    //
    // What a binding names: a plain state or row path (`$open`, `$row.title`), its
    // negation for `hidden` (`not $open`), or a compiled expression's slot. A part
    // module's binding is *foreign* (the store lives on a DOM ancestor), so it has no
    // first value; an own one renders its seed, its initial, or the engine's value.

    const Wired = struct {
        spec: []const u8,
        own: bool,
        /// Reads the state of a family this module is a part of: the render has its
        /// first value only through the nearest root of that family (`own` then).
        foreign: bool = false,
    };

    // -- compiled expressions -----------------------------------------------
    //
    // A live expression is a function the browser runs, in `stores.js`, named in
    // the binding by its slot: `$e_Row_3`. The props and server loop locals it
    // reads are its arguments, because only the render knows them:
    // `$e_Badge_2(tone: $row.tone, size: "sm")`, each the caller's wire when it
    // has one, else the value as JSON. State and module helpers it reads by
    // closure, rows and imported state through its scope.

    const SlotArgument = struct {
        /// The name the function reads it under.
        name: []const u8,
        /// Zig code of its value at render time.
        value: []const u8,
        /// Zig code of the caller's wire for it, for a prop that can carry one.
        wire: ?[]const u8,
    };

    const SlotCall = struct {
        name: []const u8,
        arguments: []const SlotArgument,
        /// Reads state or a reactive row, so it is always bound; otherwise only
        /// when a caller wired one of its props.
        live: bool,
        /// Reads the module's own state or seeded rows: the render has its first value.
        own: bool,
        /// Reads the state of a family this module is a part of.
        foreign: bool = false,
        /// What the server hands it as its scope, or null when the render holds no
        /// value for something it reads (a family's state from a part, a row in a
        /// list's prototype).
        server_scope: ?[]const SlotArgument,
    };

    /// The expression's slot in the current scope; null when it reads nothing
    /// live and no prop a caller could wire.
    fn slot_call(gen: *Generator, e: *const ExpressionIR) Error!?SlotCall {
        return gen.slot_call_for(e, .bound);
    }

    /// `slot_call`, or for `.run` the slot of any printable expression, live or not:
    /// what the server runs for a first value.
    fn slot_call_for(gen: *Generator, e: *const ExpressionIR, use: enum { bound, run, peek }) Error!?SlotCall {
        if (!expression_js.printable(e)) return null;

        var pending: std.ArrayList(expression_js.Reference) = .empty;
        try pending.appendSlice(gen.arena, try expression_js.references(gen.arena, e));
        var parameters: std.ArrayList([]const u8) = .empty;
        var arguments: std.ArrayList(SlotArgument) = .empty;
        var inlined: std.ArrayList(usize) = .empty;
        var live = false;
        var own = false;
        var wirable = false;
        var foreign_state: ?[]const u8 = null;
        var server_scope: std.ArrayList(SlotArgument) = .empty;
        var servable = true;

        var index: usize = 0;
        while (index < pending.items.len) : (index += 1) {
            const read = pending.items[index];
            const name = read.name;
            switch (read.source) {
                .state => {
                    live = true;
                    own = true;
                },
                .prop => {
                    if (util.containsString(parameters.items, name)) continue;
                    const field = find_field(gen.module.props, name) orelse return gen.fail("prop \"{s}\" is not declared", .{name});
                    gen.props_used = true;
                    try parameters.append(gen.arena, name);
                    try arguments.append(gen.arena, .{
                        .name = name,
                        .value = try std.fmt.allocPrint(gen.arena, "props.{f}", .{std.zig.fmtId(name)}),
                        .wire = if (field.bind_transport) try std.fmt.allocPrint(gen.arena, "props.publr_bind_{s}", .{name}) else null,
                    });

                    wirable = wirable or field.bind_transport;
                },
                .local, .global => {
                    if (gen.is_alias(name)) {
                        live = true;
                        if (gen.server_local(name)) |zig_name| {
                            own = true;
                            if (!util.containsString(parameters.items, name)) try server_scope.append(gen.arena, .{
                                .name = name,
                                .value = zig_name,
                                .wire = null,
                            });
                        } else servable = false;
                        if (!util.containsString(parameters.items, name)) try parameters.append(gen.arena, name);
                        continue;
                    }
                    if (gen.module.wire) |wire| {
                        if (wire.state_name) |state| if (std.mem.eql(u8, state, name)) {
                            live = true;
                            own = true;
                            continue;
                        };
                    }
                    if (gen.foreign_of_state(name)) |foreign| {
                        if (foreign.state_local) |state| if (std.mem.eql(u8, state, name)) {
                            if (foreign_state) |known| if (!std.mem.eql(u8, known, name)) {
                                return gen.fail("one expression reads the state of two families ({s} and {s})", .{ known, name });
                            };
                            live = true;
                            own = own or gen.family_served();
                            servable = servable and gen.family_served();
                            foreign_state = name;
                            if (!util.containsString(parameters.items, name)) {
                                try parameters.append(gen.arena, name);
                                // The server reads it from the nearest root of the family.
                                gen.props_used = true;
                                gen.arena_used = true;
                                try server_scope.append(gen.arena, .{
                                    .name = name,
                                    .value = try std.fmt.allocPrint(gen.arena, "(try rt.family_state(arena, {s}, \"{s}\", {s}))", .{
                                        gen.family_code,
                                        try gen.foreign_store(foreign),
                                        try zig_string(gen.arena, try gen.foreign_initial(foreign)),
                                    }),
                                    .wire = null,
                                });
                            }
                            continue;
                        };
                    }
                    const binding_index = for (gen.module.bindings, 0..) |binding, at| {
                        if (std.mem.eql(u8, binding.name, name)) break at;
                    } else null;
                    if (binding_index) |at| {
                        if (std.mem.indexOfScalar(usize, inlined.items, at) == null) {
                            try inlined.append(gen.arena, at);
                            try pending.appendSlice(gen.arena, try expression_js.references(gen.arena, gen.module.bindings[at].value));
                        }
                        continue;
                    }
                    if (gen.server_local(name)) |zig_name| {
                        if (util.containsString(parameters.items, name)) continue;
                        try parameters.append(gen.arena, name);
                        try arguments.append(gen.arena, .{
                            .name = name,
                            .value = zig_name,
                            .wire = null,
                        });
                        try server_scope.append(gen.arena, arguments.items[arguments.items.len - 1]);
                        continue;
                    }
                    if (std.mem.eql(u8, name, "Publr") and reads_publr_stores(e)) live = true;
                },
            }
        }

        if (!live and !wirable and use != .run) return null;
        // Asked only whether it is live: nothing is registered.
        if (use == .peek) return .{
            .name = "",
            .arguments = arguments.items,
            .live = live,
            .own = own,
            .foreign = foreign_state != null,
            .server_scope = null,
        };

        std.mem.sort(usize, inlined.items, {}, std.sort.asc(usize));
        var body: std.Io.Writer.Allocating = .init(gen.arena);
        try body.writer.writeAll("(");
        if (parameters.items.len > 0) {
            try body.writer.writeAll("{ ");
            for (parameters.items, 0..) |parameter, at| {
                if (at > 0) try body.writer.writeAll(", ");
                try body.writer.writeAll(parameter);
            }
            try body.writer.writeAll(" }");
        }
        try body.writer.writeAll(") => ");
        const printed = try expression_js.print(gen.arena, e);
        if (inlined.items.len == 0) {
            try body.writer.writeAll(printed);
        } else {
            try body.writer.writeAll("{ ");
            for (inlined.items) |at| {
                const binding = gen.module.bindings[at];
                try body.writer.print("const {s} = {s}; ", .{ binding.name, try expression_js.print(gen.arena, binding.value) });
            }
            try body.writer.print("return {s}; }}", .{printed});
        }

        const code = body.written();
        for (gen.slots.items) |known| {
            if (known.expression == e and std.mem.eql(u8, known.code, code)) {
                return .{
                    .name = known.name,
                    .arguments = arguments.items,
                    .live = live,
                    .own = own,
                    .foreign = foreign_state != null,
                    .server_scope = if (servable) server_scope.items else null,
                };
            }
        }
        const name = try std.fmt.allocPrint(gen.arena, "e_{s}_{d}", .{ gen.module.name, gen.slots.items.len + 1 });
        try gen.slots.append(gen.arena, .{
            .name = name,
            .code = code,
            .expression = e,
            .props = try gen.props_read(arguments.items),
            .foreign = if (foreign_state) |local| .{
                .local = local,
                .store = try gen.foreign_store(gen.foreign_of_state(local).?),
            } else null,
        });
        return .{
            .name = name,
            .arguments = arguments.items,
            .live = live,
            .own = own,
            .foreign = foreign_state != null,
            .server_scope = if (servable) server_scope.items else null,
        };
    }

    /// The expression's first value, run by the consumer's engine: `rt.Value`, or
    /// unservable when the render holds no value for something it reads.
    fn server_value(gen: *Generator, e: *const ExpressionIR) Error!OwnInitial {
        const call = (try gen.slot_call_for(e, .run)) orelse return gen.fail("a server value for an expression that is not compiled", .{});
        const scope = call.server_scope orelse return .unservable;
        var fields: std.Io.Writer.Allocating = .init(gen.arena);
        for (scope) |field| try fields.writer.print(" .{f} = {s},", .{ std.zig.fmtId(field.name), field.value });
        gen.arena_used = true;
        return .{
            .lowered = .{
                .code = try std.fmt.allocPrint(gen.arena, "(try rt.evaluate({s}, arena, \"{s}\", \"{s}\", {s}, .{{{s} }}))", .{
                    try gen.expressions_code(),
                    gen.module.name,
                    call.name,
                    gen.state_code(),
                    fields.written(),
                }),
                .type = .value,
            },
        };
    }

    /// The consumer's engine, from the request the render was handed.
    fn expressions_code(gen: *Generator) Error![]const u8 {
        if (gen.request.len == 0) return gen.fail("compiled expressions run through the request, and the program declares none", .{});
        gen.request_used = true;
        gen.props_used = true;
        return std.fmt.allocPrint(gen.arena, "(if (props.publr_request) |publr_request| @as(*const Request, @ptrCast(@alignCast(publr_request))).{s} else null)", .{gen.expressions_field});
    }

    /// The props among a slot's arguments.
    fn props_read(gen: *Generator, arguments: []const SlotArgument) Error![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        for (arguments) |argument| {
            if (find_field(gen.module.props, argument.name) != null and std.mem.startsWith(u8, argument.value, "props.")) {
                try names.append(gen.arena, argument.name);
            }
        }
        return names.items;
    }

    /// The render instance's state and props as JSON, for an expression.
    fn state_code(gen: *Generator) []const u8 {
        if (gen.state_json) |name| {
            gen.state_json_used = true;
            gen.arena_used = true;
            gen.props_used = true;
            return std.fmt.allocPrint(gen.arena, "(try {s}.text(arena))", .{name}) catch "\"{}\"";
        }
        return "\"{}\"";
    }

    /// A block's capture of the render's state JSON, which it may read.
    fn capture_state(gen: *Generator, w: *std.Io.Writer) Error!void {
        const name = gen.state_json orelse return;
        gen.state_json_used = true;
        gen.arena_used = true;
        gen.props_used = true;
        try w.print(" .{s} = {s},", .{ name, name });
    }

    /// The module's state as the render holds it: each field's seed or initial value,
    /// as JSON, declared where the render starts and kept only when an expression
    /// reads it. A field the render cannot lower is left out (`undefined`).
    fn write_state_json(gen: *Generator) Error!void {
        if (gen.expressions_field.len == 0) return;
        try gen.flush();
        var fields: std.Io.Writer.Allocating = .init(gen.arena);
        const initials = if (gen.module.wire) |wire| wire.initials else &.{};
        const seeds = if (gen.module.wire) |wire| wire.seed_exprs else &.{};
        for (initials) |initial| {
            var value = initial.expr orelse continue;
            for (seeds) |seed| {
                if (std.mem.eql(u8, seed.field, initial.field)) value = seed.expr;
            }
            // A constant is its JSON; anything else, the render's value.
            if (try expression_js.json(gen.arena, value)) |constant| {
                try fields.writer.print(" .{f} = rt.Json{{ .text = {s} }},", .{ std.zig.fmtId(initial.field), try zig_string(gen.arena, constant) });
                continue;
            }
            const lowered = gen.expression(value) catch continue;
            switch (lowered.type) {
                .string, .opt_string, .boolean, .opt_boolean, .number, .opt_number, .array, .strings, .opt_strings, .enumeration, .opt_enumeration, .null, .item => {},
                else => continue,
            }
            try fields.writer.print(" .{f} = {s},", .{ std.zig.fmtId(initial.field), lowered.code });
        }
        gen.state_json = "publr_state";
        gen.state_offset = gen.body.written().len;
        gen.state_fields = fields.written();
        if (gen.is_family_root()) {
            gen.family_store = gen.root_store;
            gen.state_json_used = true;
            gen.arena_used = true;
            gen.props_used = true;
            gen.family_code = "publr_family";
        }
    }

    /// Whether this module is a family's root, which carries its store.
    fn is_family_root(gen: *Generator) bool {
        const wire = gen.module.wire orelse return false;
        return wire.kind == .family and gen.root_store != null;
    }

    /// The render instance, declared where the render starts: its state, and the props
    /// the module's server slots read (known once the module is lowered).
    fn instance_declaration(gen: *Generator) Error![]const u8 {
        const code = gen.body.written();
        var names: std.ArrayList([]const u8) = .empty;
        for (gen.slots.items) |slot| {
            const run = try std.fmt.allocPrint(gen.arena, "\"{s}\"", .{slot.name});
            if (std.mem.indexOf(u8, code, run) == null and std.mem.indexOf(u8, gen.blocks.written(), run) == null) continue;
            for (slot.props) |name| {
                if (!util.containsString(names.items, name)) try names.append(gen.arena, name);
            }
        }
        var props: std.Io.Writer.Allocating = .init(gen.arena);
        for (names.items) |name| try props.writer.print(" .{f} = props.{f},", .{ std.zig.fmtId(name), std.zig.fmtId(name) });
        const family = if (gen.family_store) |family_store| try std.fmt.allocPrint(
            gen.arena,
            "    var publr_family_held = rt.family_of(\"{s}\", publr_state, props.publr_family);\n    const publr_family: ?*const rt.Family = &publr_family_held;\n    _ = &publr_family;\n",
            .{family_store},
        ) else "";
        return std.fmt.allocPrint(
            gen.arena,
            "    var publr_state_held = rt.instance(.{{{s} }}, .{{{s} }});\n    const publr_state = &publr_state_held;\n    _ = &publr_state;\n{s}",
            .{ gen.state_fields, props.written(), family },
        );
    }

    /// Whether `name` (as the source spells it) is the row of a list the browser draws.
    fn is_alias(gen: *Generator, name: []const u8) bool {
        for (gen.wire_aliases.items) |alias| {
            if (std.mem.eql(u8, alias, name)) return true;
            if (std.mem.startsWith(u8, alias, "@\"") and std.mem.eql(u8, alias[2 .. alias.len - 1], name)) return true;
        }
        return false;
    }

    /// The Zig name of a value the render holds under `name` as the source spells it:
    /// a loop's row; null when there is none (a component binding is not one).
    fn server_local(gen: *Generator, name: []const u8) ?[]const u8 {
        var index = gen.locals.items.len;
        while (index > 0) {
            index -= 1;
            const local = gen.locals.items[index];
            if (local.binding != null) continue;
            if (std.mem.eql(u8, local.source_name orelse local.name, name)) return local.name;
        }
        return null;
    }

    /// Whether `e` reads markup (a node prop or local): its value may be that markup,
    /// which only the render can draw, so the engine does not compute it.
    fn reads_markup(gen: *Generator, e: *const ExpressionIR) Error!bool {
        for (try expression_js.references(gen.arena, e)) |read| {
            const read_type: ?Type = switch (read.source) {
                .prop => if (find_field(gen.module.props, read.name)) |field| field.type else null,
                .local, .global => for (gen.locals.items) |local| {
                    if (std.mem.eql(u8, local.source_name orelse local.name, read.name)) break local.type;
                } else null,
                .state => null,
            };
            const markup = read_type orelse continue;
            if (markup == .node or markup == .opt_node) return true;
        }
        return false;
    }

    /// A Zig value as an engine's value, where one meets the other.
    fn as_value(gen: *Generator, lowered: Lowered) Error!Lowered {
        if (lowered.type == .null) return .{
            .code = "rt.Value.null",
            .type = .value,
        };
        gen.arena_used = true;
        return .{
            .code = try std.fmt.allocPrint(gen.arena, "(try rt.value_of(arena, {s}))", .{lowered.code}),
            .type = .value,
        };
    }

    /// An engine's value as a typed prop: an enum by its tag among the type's own
    /// (an enum literal fills the callee's type), anything else through `rt.value_into`.
    fn value_into(gen: *Generator, code: []const u8, target: Type) Error![]const u8 {
        gen.arena_used = true;
        switch (target) {
            .enumeration, .opt_enumeration => |enumeration| {
                var out: std.Io.Writer.Allocating = .init(gen.arena);
                try out.writer.print("(switch (try rt.value_tag(arena, {s}, &.{{", .{code});
                for (enumeration.values) |tag| try out.writer.print(" \"{s}\",", .{tag});
                try out.writer.writeAll(" })) {");
                for (enumeration.values, 0..) |tag, index| try out.writer.print(" {d} => .@\"{s}\",", .{ index, tag });
                if (target == .opt_enumeration) {
                    try out.writer.writeAll(" else => null })");
                } else {
                    try out.writer.writeAll(" else => return error.InvalidEnumTag })");
                }
                return out.written();
            },
            .string, .opt_string, .boolean, .opt_boolean, .number, .opt_number, .strings, .opt_strings => {
                return std.fmt.allocPrint(gen.arena, "(try rt.value_into({s}, arena, {s}))", .{ type_code(target), code });
            },
            else => return gen.fail("a compiled expression cannot fill a prop of type {s} yet", .{@tagName(target)}),
        }
    }

    /// The initial state of the family this module imports its state from, as JSON: its
    /// constant fields, as a part with no root shares them in the browser.
    fn foreign_initial(gen: *Generator, foreign: Foreign) Error![]const u8 {
        for (gen.modules) |candidate| {
            if (!std.mem.eql(u8, candidate.file_stem, foreign.module_name) and !std.mem.eql(u8, candidate.name, foreign.module_name)) continue;
            const wire = candidate.wire orelse continue;
            var text: std.Io.Writer.Allocating = .init(gen.arena);
            try text.writer.writeAll("{");
            var separator: []const u8 = "";
            for (wire.initials) |initial| {
                const value = initial.expr orelse continue;
                const constant = (try expression_js.json(gen.arena, value)) orelse continue;
                try text.writer.print("{s}\"{s}\":{s}", .{ separator, initial.field, constant });
                separator = ",";
            }
            try text.writer.writeAll("}");
            return text.written();
        }
        return gen.fail("the family {s} has no store", .{foreign.module_name});
    }

    /// The store of the family this module imports its state from.
    fn foreign_store(gen: *Generator, foreign: Foreign) Error![]const u8 {
        for (gen.modules) |candidate| {
            if (std.mem.eql(u8, candidate.file_stem, foreign.module_name) or std.mem.eql(u8, candidate.name, foreign.module_name)) {
                if (candidate.wire) |wire| return wire.store;
            }
        }
        return gen.fail("the family {s} has no store", .{foreign.module_name});
    }

    /// The slot as a static wire: an expression whose wire the render need not finish.
    fn slot_static(gen: *Generator, e: *const ExpressionIR) Error!?Wired {
        const call = (try gen.slot_call(e)) orelse return null;
        if (call.arguments.len > 0 or !call.live) return null;
        return .{
            .spec = try std.fmt.allocPrint(gen.arena, "${s}", .{call.name}),
            .own = call.own,
            .foreign = call.foreign,
        };
    }

    /// The slot as Zig code of type `?[]const u8`: the call with its arguments, null
    /// when it reads nothing live and no caller wired a prop it reads.
    fn slot_runtime(gen: *Generator, e: *const ExpressionIR) Error!?[]const u8 {
        const call = (try gen.slot_call(e)) orelse return null;
        if (call.arguments.len == 0) {
            if (!call.live) return null;
            return try std.fmt.allocPrint(gen.arena, "@as(?[]const u8, \"${s}\")", .{call.name});
        }

        var parts: std.Io.Writer.Allocating = .init(gen.arena);
        var condition: std.Io.Writer.Allocating = .init(gen.arena);
        try parts.writer.print("\"${s}(\"", .{call.name});
        for (call.arguments, 0..) |argument, at| {
            try parts.writer.print(", \"{s}{s}: \", rt.slot_argument(arena, {s}, {s})", .{
                if (at > 0) ", " else "",
                argument.name,
                argument.wire orelse "null",
                argument.value,
            });
            if (argument.wire) |wire| {
                if (condition.written().len > 0) try condition.writer.writeAll(" or ");
                try condition.writer.print("{s} != null", .{wire});
            }
        }
        try parts.writer.writeAll(", \")\"");
        gen.arena_used = true;
        const value = try std.fmt.allocPrint(gen.arena, "@as(?[]const u8, rt.concat(arena, &.{{ {s} }}))", .{parts.written()});
        if (call.live) return value;
        return try std.fmt.allocPrint(gen.arena, "(if ({s}) {s} else @as(?[]const u8, null))", .{ condition.written(), value });
    }

    /// A slot wire's negation (`hidden={…}` binds `data-p-show`): the slot of `!(…)`.
    fn negated_slot(gen: *Generator, spec: []const u8) Error!?[]const u8 {
        if (!std.mem.startsWith(u8, spec, "$e_")) return null;
        const slot = for (gen.slots.items) |slot| {
            if (std.mem.eql(u8, slot.name, spec[1..])) break slot;
        } else return null;
        // `hidden={!state.open}` shows on `state.open` itself.
        if (slot.expression.* == .unary and std.mem.eql(u8, slot.expression.unary.operator, "!")) {
            if (try gen.wire_spec(slot.expression.unary.argument)) |inner| return inner.spec;
        }
        const negation = try gen.arena.create(ExpressionIR);
        negation.* = .{
            .unary = .{
                .operator = "!",
                .argument = slot.expression,
            },
        };
        const wired = (try gen.slot_static(negation)) orelse return null;
        return wired.spec;
    }

    /// The slots the generated code names: those a lowering asked for and then
    /// set aside are left out of `stores.js`.
    fn used_slots(gen: *Generator, code: []const u8, use: enum { bound, run }) Error![]const slots_file.Slot {
        var used: std.ArrayList(slots_file.Slot) = .empty;
        for (gen.slots.items) |slot| {
            // A binding names it `$e_…`; a server render, `"e_…"`.
            const named = switch (use) {
                .bound => try std.fmt.allocPrint(gen.arena, "${s}", .{slot.name}),
                .run => try std.fmt.allocPrint(gen.arena, "\"{s}\"", .{slot.name}),
            };
            if (std.mem.indexOf(u8, code, named) != null) try used.append(gen.arena, slot);
        }
        return used.items;
    }

    /// `state.a.b` → the dotted path, empty for the state object itself;
    /// null when the expression is not a state member chain.
    fn wire_state_path(gen: *Generator, e: *const ExpressionIR) ?Wired {
        switch (e.*) {
            .reference => |reference_ir| {
                for (gen.wire_aliases.items) |alias| {
                    if (std.mem.eql(u8, alias, reference_ir.name)) {
                        for (gen.locals.items) |local| {
                            if (std.mem.eql(u8, local.name, alias)) return .{
                                .spec = alias,
                                .own = true,
                            };
                        }
                        return .{
                            .spec = alias,
                            .own = false,
                        };
                    }
                }
                if (reference_ir.source == .state) {
                    return .{
                        .spec = "",
                        .own = true,
                    };
                }
                if (reference_ir.source != .local) return null;
                for (gen.locals.items) |local| {
                    if (std.mem.eql(u8, local.name, reference_ir.name)) return null;
                }
                if (gen.module.wire) |wire| {
                    if (wire.kind == .family and wire.state_name != null and std.mem.eql(u8, wire.state_name.?, reference_ir.name)) {
                        return .{
                            .spec = "",
                            .own = true,
                        };
                    }
                }
                if (gen.foreign_of_state(reference_ir.name)) |foreign| {
                    if (foreign.state_local) |state| {
                        if (std.mem.eql(u8, state, reference_ir.name)) return .{
                            .spec = "",
                            .own = gen.family_served(),
                            .foreign = true,
                        };
                    }
                }
                return null;
            },
            .member => |member| {
                if (member.property != .string) return null;
                if (member.object.* == .member) {
                    const stores = member.object.member;
                    if (stores.property == .string and std.mem.eql(u8, stores.property.string, "stores") and stores.object.* == .reference and std.mem.eql(u8, stores.object.reference.name, "Publr")) {
                        return .{
                            .spec = std.fmt.allocPrint(gen.arena, "{s}::", .{member.property.string}) catch return null,
                            .own = false,
                        };
                    }
                }
                const base = gen.wire_state_path(member.object) orelse return null;
                const path = if (std.mem.endsWith(u8, base.spec, "::"))
                    std.fmt.allocPrint(gen.arena, "{s}{s}", .{ base.spec, member.property.string }) catch return null
                else if (base.spec.len == 0)
                    member.property.string
                else
                    std.fmt.allocPrint(gen.arena, "{s}.{s}", .{ base.spec, member.property.string }) catch return null;
                return .{
                    .spec = path,
                    .own = base.own,
                    .foreign = base.foreign,
                };
            },
            else => return null,
        }
    }

    /// The expression as a wire spec, or null when it does not read state: a plain
    /// state or row path, else a compiled expression's slot.
    fn wire_spec(gen: *Generator, e: *const ExpressionIR) Error!?Wired {
        if (gen.wire_state_path(e)) |path| {
            if (path.spec.len == 0) return null; // the bare state object is not a wire
            return .{
                .spec = try std.fmt.allocPrint(gen.arena, "${s}", .{path.spec}),
                .own = path.own,
                .foreign = path.foreign,
            };
        }
        return gen.slot_static(e);
    }

    /// Preserve numeric negation: NaN makes !(a <= b) differ from a > b.
    fn invert_wire(gen: *Generator, spec: []const u8) Error![]const u8 {
        if (try gen.negated_slot(spec)) |negated| return negated;
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

    /// A class layer over state: its slot, whose value is the class list.
    fn class_wire_group(gen: *Generator, e: *const ExpressionIR) Error!?Wired {
        return gen.slot_static(e);
    }

    // -- prop wires ---------------------------------------------------------
    //
    // A component called inside a list template receives its row-dependent
    // props as wires (`publr_bind_<prop>`) with placeholder values. An expression
    // over such props is a compiled expression with them as arguments, each the
    // caller's wire (`$e_Badge_2(tone: $row.tone)`), bound only when a caller
    // wired one of them; a bare prop hands the caller's wire on unchanged.

    const PropWireMode = enum {
        /// A value spec (`data-p-text`, `data-p-bind`, `data-p-if`, a callee's
        /// `publr_bind_*`).
        value,
        /// A `data-p-class` group, whose value is the class list.
        classes,
    };

    /// The runtime wire (Zig code of type `?[]const u8`, null when no prop it
    /// reads is wired) of a prop-derived expression.
    fn prop_wire(gen: *Generator, e: *const ExpressionIR, mode: PropWireMode) Error!?[]const u8 {
        if (gen.prop_wire_skip) |skip| if (skip == e) return null;
        // A prop as it is: the caller's wire, unchanged. As a class layer it is a
        // value, grouped by the value form (a path is not a class group).
        if (e.* == .reference and e.reference.source == .prop) {
            if (mode == .classes) return null;
            const field = find_field(gen.module.props, e.reference.name) orelse return null;
            if (!field.bind_transport) return null;
            gen.props_used = true;
            return try std.fmt.allocPrint(gen.arena, "props.publr_bind_{s}", .{e.reference.name});
        }
        const call = (try gen.slot_call(e)) orelse return null;
        if (call.arguments.len == 0) return null;
        return gen.slot_runtime(e);
    }

    // -- expressions as Zig values --

    /// The expression as a typed Zig expression.
    fn expression(gen: *Generator, e: *const ExpressionIR) Error!Lowered {
        // With an engine, a live expression's value is the engine's, run as the
        // browser runs it; a plain path is read as it is.
        var fallback = false;
        if (gen.expressions_field.len > 0 and gen.native_depth == 0 and gen.wire_state_path(e) == null) {
            const live = if (try gen.slot_call_for(e, .peek)) |call| call.live else false;
            if (live) return gen.engine_value(e);
            // A static computation the render lowers itself where it can, the engine
            // where it cannot (decided 2026-10-08); a read (`row.title`) is read here.
            fallback = !is_read(e) and expression_js.printable(e) and !reads_request(e) and
                !try gen.reads_markup(e);
        }
        const lowered = if (fallback)
            gen.attempt(e) catch |failure| switch (failure) {
                error.Pjsx => return gen.engine_value(e),
                else => return failure,
            }
        else
            try gen.expression_value(e);
        if (lowered.type.is_optional()) for (gen.present_values.items) |code| {
            if (util.eql(code, lowered.code)) return .{
                .code = try std.fmt.allocPrint(gen.arena, "({s}).?", .{lowered.code}),
                .type = lowered.type.unwrapped(),
            };
        };
        return lowered;
    }

    /// The engine's value for `e`, or `undefined` when the render holds no value for
    /// something it reads.
    fn engine_value(gen: *Generator, e: *const ExpressionIR) Error!Lowered {
        return switch (try gen.server_value(e)) {
            .lowered => |lowered| lowered,
            .unservable => .{
                .code = "rt.Value.undefined",
                .type = .value,
            },
        };
    }

    /// `expression_value`, leaving nothing behind when it fails: what it wrote is
    /// taken back, so the engine can take the expression instead.
    fn attempt(gen: *Generator, e: *const ExpressionIR) Error!Lowered {
        const written = gen.body.writer.end;
        const pending = gen.pending.items.len;
        const counter = gen.counter;
        return gen.expression_value(e) catch |failure| {
            gen.body.writer.end = written;
            gen.pending.shrinkRetainingCapacity(pending);
            gen.counter = counter;
            return failure;
        };
    }

    fn expression_value(gen: *Generator, e: *const ExpressionIR) Error!Lowered {
        switch (e.*) {
            .literal => |literal| return switch (literal) {
                .string => |s| .{
                    .code = try zig_string(gen.arena, s),
                    .type = .string,
                },
                .number => |number| .{
                    .code = if (std.math.isNan(number)) "std.math.nan(f64)" else if (std.math.isInf(number)) (if (number > 0) "std.math.inf(f64)" else "(-std.math.inf(f64))") else if (number == 0 and std.math.signbit(number)) "@as(f64, -0.0)" else try std.fmt.allocPrint(gen.arena, "@as(f64, {d})", .{number}),
                    .type = .number,
                },
                .boolean => |b| .{
                    .code = if (b) "true" else "false",
                    .type = .boolean,
                },
                .null => .{
                    .code = "null",
                    .type = .null,
                },
            },
            .call => |call| {
                if (call.optional) return gen.fail("`?.()` is not lowered", .{});
                if (translation_of(call.callee)) |kind| return gen.translation(call.arguments, kind);
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
                            try gen.locals.append(gen.arena, .{
                                .name = local,
                                .source_name = parameter,
                                .type = argument.type,
                            });
                        }
                        const result = try gen.expression(function.body);
                        return .{
                            .code = try std.fmt.allocPrint(gen.arena, "{s}: {{ {s}break :{s} {s}; }}", .{ label, prefix.written(), label, result.code }),
                            .type = result.type,
                        };
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
                        const parameter_source = function.parameters[0];
                        const parameter = try gen.local_name(parameter_source);

                        const subject = try gen.expression(callee_member.object);
                        const item_type: Type = switch (subject.type) {
                            .array => |item_fields| .{
                                .item = item_fields,
                            },
                            .strings => .string,
                            else => return gen.fail("findIndex on a {s} is not lowered", .{@tagName(subject.type)}),
                        };

                        try gen.locals.append(gen.arena, .{
                            .name = parameter,
                            .source_name = parameter_source,
                            .type = item_type,
                        });
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
                    return .{
                        .code = "&.{}",
                        .type = .strings,
                    };
                }
                return gen.fail("a non-empty array literal is not lowered", .{});
            },
            // `undefined` — an absent value; lowers exactly like the null literal
            // (`x === undefined` → a null check, an absent attribute is omitted).
            .absent => return .{
                .code = "null",
                .type = .null,
            },
            .reference => |reference_ir| return gen.reference(reference_ir.name, reference_ir.source),
            .member => |member| {
                if (is_publr_request(member)) {
                    return gen.request_root();
                }
                const object = try gen.expression(member.object);
                // `a?.b` on a value the types say is there reads it; on one that may be
                // missing it is the engine's.
                if (member.optional and object.type.is_optional()) {
                    return gen.fail("`?.` on an optional {s} is not lowered", .{@tagName(object.type)});
                }

                if (member.property != .string) {
                    // `items[i]`: indexing a struct-array by an integer.
                    if (object.type == .array) {
                        const index = try gen.member_index(member.property);
                        if (index.type != .number) {
                            return gen.fail("an array index must be an integer, got a {s}", .{@tagName(index.type)});
                        }
                        return .{
                            .code = try std.fmt.allocPrint(gen.arena, "{s}[@intFromFloat({s})]", .{ object.code, index.code }),
                            .type = .{
                                .item = object.type.array,
                            },
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
                        return .{
                            .code = try gen.string_keyed_lookup(object.type.finite_map, key.code, null, null),
                            .type = .opt_string,
                        };
                    }

                    if (key.type != .enumeration) {
                        return gen.fail("a finite map is keyed by a {s}; only enum and string keys are lowered", .{@tagName(key.type)});
                    }

                    return .{
                        .code = "",
                        .type = .{
                            .finite = .{
                                .entries = object.type.finite_map,
                                .key_code = key.code,
                                .key_enum = key.type.enumeration,
                            },
                        },
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
                    return .{
                        .code = argument.code,
                        .type = .union_typeof,
                    };
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
            .chain => |chain| return gen.expression(chain.expression),
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
        var type_names: TypeNames = .empty;
        const fields = try adapt_props(gen.arena, &schema, &types.writer, gen.module.name, &type_names);
        try gen.asserted_types.appendSlice(gen.arena, types.written());
        const lowered: Lowered = .{
            .code = try std.fmt.allocPrint(gen.arena, "@as({s}, &.{{}})", .{fields[0].zig_type}),
            .type = fields[0].type,
        };
        try gen.asserted_arrays.append(gen.arena, .{
            .expression = e,
            .lowered = lowered,
        });
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

    /// `Publr.t("Save")`, `Publr.tx("verb", "Post")`, `Publr.tn("{count} record",
    /// "{count} records", count)`, each with an optional `{ name: value }` last: the message
    /// through the catalogue the request carries (`publr_translations`), else as written.
    /// The messages are literal strings, so they can be collected for translators.
    fn translation(gen: *Generator, arguments: []const *const ExpressionIR, kind: Translation) Error!Lowered {
        const texts: usize = switch (kind) {
            .t => 1,
            .tx, .tn => 2,
        };
        const fixed = texts + @as(usize, if (kind == .tn) 1 else 0);
        if (arguments.len < fixed or arguments.len > fixed + 1) {
            return gen.fail("Publr.{s} takes {d} arguments and an optional {{ name: value }}", .{ @tagName(kind), fixed });
        }
        var literals: [2][]const u8 = .{ "", "" };
        for (arguments[0..texts], 0..) |argument, index| {
            literals[index] = string_of_literal(argument) orelse
                return gen.fail("Publr.{s} takes literal strings, so they can be translated", .{@tagName(kind)});
        }
        const context = if (kind == .tx) literals[0] else "";
        const id = if (kind == .tx) literals[1] else literals[0];
        const plural = if (kind == .tn) literals[1] else "";
        const count = if (kind == .tn) try gen.expression(arguments[2]) else null;
        if (count) |lowered| if (lowered.type != .number) return gen.fail("Publr.tn counts a number", .{});

        var values: std.Io.Writer.Allocating = .init(gen.arena);
        if (arguments.len == fixed + 1) {
            const given = arguments[fixed];
            if (given.* != .object) return gen.fail("Publr.{s}'s last argument is {{ name: value }}", .{@tagName(kind)});
            for (given.object.fields) |field| {
                const lowered = try gen.expression(field.value);
                const text = switch (lowered.type) {
                    .string => lowered.code,
                    .number => try std.fmt.allocPrint(gen.arena, "try rt.number_to_string(arena, {s})", .{lowered.code}),
                    else => return gen.fail("a placeholder is a string or a number, not a {s}", .{@tagName(lowered.type)}),
                };
                try values.writer.print(" .{{ .name = {s}, .value = {s} }},", .{ try zig_string(gen.arena, field.name), text });
            }
        }

        gen.arena_used = true;
        gen.props_used = true;
        const catalogue = if (gen.request.len == 0)
            "null"
        else
            "(if (comptime @hasField(Request, \"publr_translations\")) (if (props.publr_request) |publr_translate_request| " ++
                "@as(*const Request, @ptrCast(@alignCast(publr_translate_request))).publr_translations else null) else null)";
        if (gen.request.len > 0) gen.request_used = true;

        return .{
            .code = try std.fmt.allocPrint(
                gen.arena,
                "(try rt.translate(arena, {s}, .{{ .context = {s}, .id = {s}, .plural = {s}, .count = {s}, .values = &[_]rt.Placeholder{{{s} }} }}))",
                .{
                    catalogue,
                    try zig_string(gen.arena, context),
                    try zig_string(gen.arena, id),
                    try zig_string(gen.arena, plural),
                    if (count) |lowered| try std.fmt.allocPrint(gen.arena, "@as(?f64, {s})", .{lowered.code}) else "null",
                    values.written(),
                },
            ),
            .type = .string,
        };
    }

    /// `Publr.request`: the request the render was handed, as an item of the declared
    /// fields. A render handed none fails at the read.
    fn request_root(gen: *Generator) Error!Lowered {
        if (gen.request.len == 0) {
            return gen.fail("Publr.request is read, but the program declares no request", .{});
        }
        gen.request_used = true;
        gen.props_used = true;
        return .{
            .code = "@as(*const Request, @ptrCast(@alignCast(props.publr_request orelse " ++
                "@panic(\"Publr.request read in a render handed no request\")))).*",
            .type = .{
                .item = gen.request,
            },
        };
    }

    /// A local's name as Zig spells it: one that is a keyword or a primitive (`type`,
    /// `error`) escaped (`@"type"`), so a list's `(type) => ...` lowers as written.
    fn local_name(gen: *Generator, name: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(gen.arena, "{f}", .{std.zig.fmtId(name)}) catch error.OutOfMemory;
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
            .state => return .{
                .code = "",
                .type = .state_root,
            },
            .local => {
                var index = gen.locals.items.len;
                while (index > 0) {
                    index -= 1;
                    if (std.mem.eql(u8, gen.locals.items[index].source_name orelse gen.locals.items[index].name, name)) {
                        return .{
                            .code = gen.locals.items[index].name,
                            .type = gen.locals.items[index].type,
                        };
                    }
                }

                if (gen.module.wire) |wire| {
                    // Inside a closure (a list's row) the module's own state is
                    // a plain local of its exported name.
                    if (wire.state_name) |state| {
                        if (std.mem.eql(u8, state, name)) return .{
                            .code = "",
                            .type = .state_root,
                        };
                    }
                    for (wire.actions) |action| {
                        if (std.mem.eql(u8, action, name)) {
                            return .{
                                .code = try zig_string(gen.arena, name),
                                .type = .action_name,
                            };
                        }
                    }
                    for (wire.refs) |ref| {
                        if (std.mem.eql(u8, ref, name)) {
                            return .{
                                .code = ref,
                                .type = .ref_name,
                            };
                        }
                    }
                }

                for (gen.foreigns) |foreign| {
                    if (foreign.state_local) |state| {
                        if (std.mem.eql(u8, state, name)) {
                            return .{
                                .code = "",
                                .type = .state_root,
                            };
                        }
                    }
                    for (foreign.actions) |action| {
                        if (std.mem.eql(u8, action.local, name)) {
                            return .{
                                .code = try zig_string(gen.arena, action.name),
                                .type = .action_name,
                            };
                        }
                    }
                    for (foreign.refs) |ref| {
                        if (std.mem.eql(u8, ref.local, name)) {
                            return .{
                                .code = ref.name,
                                .type = .ref_name,
                            };
                        }
                    }
                }

                for (gen.module.finite_maps) |map| {
                    if (std.mem.eql(u8, map.name, name)) {
                        return .{
                            .code = "",
                            .type = .{
                                .finite_map = map.entries,
                            },
                        };
                    }
                }

                for (gen.module.string_constants) |constant| {
                    if (std.mem.eql(u8, constant.key, name)) {
                        return .{
                            .code = try zig_string(gen.arena, constant.value),
                            .type = .string,
                        };
                    }
                }

                if (std.mem.eql(u8, name, "NaN")) return .{
                    .code = "std.math.nan(f64)",
                    .type = .number,
                };
                if (std.mem.eql(u8, name, "Infinity")) return .{
                    .code = "std.math.inf(f64)",
                    .type = .number,
                };
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
                return .{
                    .code = try std.fmt.allocPrint(gen.arena, "({s} {s} {s})", .{ left.code, if (std.mem.eql(u8, operator, "&&")) @as([]const u8, "and") else "or", right.code }),
                    .type = .boolean,
                };
            }
            const binding = try gen.fresh("logical");
            const label = try gen.fresh("select");
            const saved = Lowered{
                .code = binding,
                .type = left.type,
            };
            const is_and = std.mem.eql(u8, operator, "&&");
            const right_is_node = right.type == .node or right.type == .opt_node;
            const left_is_node = left.type == .node or left.type == .opt_node;

            // `flag && node`: markup when the guard holds, nothing otherwise, as JSX
            // renders a false child as nothing.
            if (is_and and right_is_node and !left_is_node) {
                const nothing = Lowered{
                    .code = "null",
                    .type = .null,
                };
                const guarded = try gen.select(try gen.truthy(saved), right, nothing);
                return .{
                    .code = try std.fmt.allocPrint(gen.arena, "{s}: {{ const {s} = {s}; break :{s} {s}; }}", .{ label, binding, left.code, label, guarded.code }),
                    .type = guarded.type,
                };
            }
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
            return .{
                .code = try std.fmt.allocPrint(gen.arena, "rt.number_rem({s}, {s})", .{ left.code, right.code }),
                .type = .number,
            };
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
        // One arm from the engine: the other becomes a value too.
        if (consequent.type == .value and alternate.type != .value) alternate = try gen.as_value(alternate);
        if (alternate.type == .value and consequent.type != .value) consequent = try gen.as_value(consequent);
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
                .enumeration => |e| .{
                    .opt_enumeration = e,
                },
                // Already optional (a prop that may be absent): null is one of its values.
                .opt_string, .opt_number, .opt_boolean, .opt_node, .opt_enumeration => present.type,
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

            const lowered = try gen.expression(part_expr);

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
            .value => try std.fmt.allocPrint(gen.arena, "rt.value_truthy({s})", .{lowered.code}),
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

        return .{
            .code = out.written(),
            .type = .string,
        };
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

/// The list a chain of array methods that keep the item type starts from
/// (`state.items.filter(…).slice(0, 3)` → `state.items`); null for anything else.
fn array_base(e: *const ExpressionIR) ?*const ExpressionIR {
    var current = e;
    var methods: u32 = 0;
    while (current.* == .call and current.call.callee.* == .member) {
        const member = current.call.callee.member;
        if (member.property != .string) break;
        const keeps = for ([_][]const u8{ "filter", "slice", "toSorted", "toReversed", "concat" }) |method| {
            if (std.mem.eql(u8, method, member.property.string)) break true;
        } else false;
        if (!keeps) break;
        current = member.object;
        methods += 1;
    }
    return if (methods > 0) current else null;
}

/// The name a state member chain starts from: `library` in `library.items.length`.
fn state_root_name(e: *const ExpressionIR) ?[]const u8 {
    var current = e;
    while (current.* == .member) current = current.member.object;
    return if (current.* == .reference) current.reference.name else null;
}

/// Whether every value of a style object is a literal string.
fn style_is_literal(e: *const ExpressionIR) bool {
    for (e.object.fields) |field| {
        if (string_of_literal(field.value) == null) return false;
    }
    return true;
}

/// A style key as CSS: camelCase kebab-cased, a `--custom` property as it is.
fn style_name(arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    if (std.mem.startsWith(u8, name, "--")) return name;
    var out: std.Io.Writer.Allocating = .init(arena);
    for (name) |char| {
        if (char >= 'A' and char <= 'Z') {
            try out.writer.writeByte('-');
            try out.writer.writeByte(char + ('a' - 'A'));
        } else {
            try out.writer.writeByte(char);
        }
    }
    return out.written();
}

/// Whether `e` only reads a value: a literal, a name, or a member of one.
fn is_read(e: *const ExpressionIR) bool {
    return switch (e.*) {
        .literal, .absent, .reference => true,
        .member => |member| member.property != .expression and is_read(member.object),
        else => false,
    };
}

/// `Publr.t`, `Publr.tn`, `Publr.tx`: a message in the reader's language.
const Translation = enum { t, tn, tx };

fn translation_of(callee: *const ExpressionIR) ?Translation {
    if (callee.* != .member) return null;
    const member = callee.member;
    if (member.property != .string or member.object.* != .reference) return null;
    if (!std.mem.eql(u8, member.object.reference.name, "Publr")) return null;
    return std.meta.stringToEnum(Translation, member.property.string);
}

/// Whether `e` reads `Publr.request`, which the engine's scope does not carry.
fn reads_request(e: *const ExpressionIR) bool {
    return switch (e.*) {
        .member => |member| (member.property == .string and std.mem.eql(u8, member.property.string, "request") and
            member.object.* == .reference and std.mem.eql(u8, member.object.reference.name, "Publr")) or
            reads_request(member.object) or (member.property == .expression and reads_request(member.property.expression)),
        .unary => |unary| reads_request(unary.argument),
        .operation => |operation| reads_request(operation.left) or reads_request(operation.right),
        .conditional => |conditional| reads_request(conditional.@"test") or reads_request(conditional.consequent) or reads_request(conditional.alternate),
        .call => |call| blk: {
            // A message reads the request's catalogue.
            if (translation_of(call.callee) != null) break :blk true;
            if (reads_request(call.callee)) break :blk true;
            for (call.arguments) |argument| if (reads_request(argument)) break :blk true;
            break :blk false;
        },
        .template => |template| blk: {
            for (template.parts) |part| if (part == .expression and reads_request(part.expression)) break :blk true;
            break :blk false;
        },
        .array => |array| blk: {
            for (array.items) |item| if (reads_request(item)) break :blk true;
            break :blk false;
        },
        .object => |object| blk: {
            for (object.fields) |field| if (reads_request(field.value)) break :blk true;
            break :blk false;
        },
        .function => |function| reads_request(function.body),
        else => false,
    };
}

/// Whether `e` reads a shared store (`Publr.stores.name…`).
fn reads_publr_stores(e: *const ExpressionIR) bool {
    switch (e.*) {
        .member => |member| {
            if (member.property == .string and std.mem.eql(u8, member.property.string, "stores") and
                member.object.* == .reference and std.mem.eql(u8, member.object.reference.name, "Publr")) return true;
            return reads_publr_stores(member.object);
        },
        .unary => |unary| return reads_publr_stores(unary.argument),
        .operation => |operation| return reads_publr_stores(operation.left) or reads_publr_stores(operation.right),
        .conditional => |conditional| return reads_publr_stores(conditional.@"test") or
            reads_publr_stores(conditional.consequent) or reads_publr_stores(conditional.alternate),
        .call => |call| {
            if (reads_publr_stores(call.callee)) return true;
            for (call.arguments) |argument| if (reads_publr_stores(argument)) return true;
            return false;
        },
        .template => |template| {
            for (template.parts) |part| if (part == .expression and reads_publr_stores(part.expression)) return true;
            return false;
        },
        else => return false,
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
        // `xs.map((x) => <…/>)` draws markup too: `{shown && xs.map(…)}` guards a list.
        .call => is_map_call(e),
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
    return program.listing(arena, which);
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

test "a guard over a mapped list lowers to an if around the loop" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sources = [_][2][]const u8{.{
        "Guarded.ptsx",
        \\export const guardedProps = {
        \\  shown: { type: "boolean" },
        \\  options: { type: "array", fields: { label: { type: "string" } } },
        \\};
        \\export function Guarded({ shown, options }) {
        \\  return <ul>{shown && options.map((option) => <li>{option.label}</li>)}</ul>;
        \\}
    }};
    const source = try test_lower(arena, &sources, "Guarded");
    try std.testing.expect(std.mem.indexOf(u8, source, "for (") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, source, "try Layout.render(w, arena, .{ .title = \"Hi\", .publr_request = props.publr_request, .publr_prototype = props.publr_prototype, .publr_family = props.publr_family, .publr_show = props.publr_show, .publr_show_wire = props.publr_show_wire, .publr_text_wire = props.publr_text_wire, .children = rt.block(&children_1, Children_1) });") != null);

    const layout_source = try test_lower(arena, &sources, "Layout");
    try std.testing.expect(std.mem.indexOf(u8, layout_source, "children: ?rt.Node = null,") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout_source, "try rt.escape(w, props.title);") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout_source, "try value_1.render_in(w, arena, props.publr_request, props.publr_family);") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, part, "data-open:$e_Part_2") != null);
    try std.testing.expect(std.mem.indexOf(u8, part, "aria-expanded:$open") != null);
    try std.testing.expect(std.mem.indexOf(u8, part, "// slot e_Part_2: ({ state }) => state.values.includes(Publr.dataset(\"value\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, part, "data-p-show=\\\"$open\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part, "data-p-ref=\\\"panel\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part, "data-p-portal") != null);
    try std.testing.expect(std.mem.indexOf(u8, part, "data-p-on=\\\"click:openDialog\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part, "data-p-class=\\\"$e_Part_3\\\"") != null);
    // The static class layer stays in the stack, through the merge, after the wire group
    // moved out of it.
    try std.testing.expect(std.mem.indexOf(u8, part, "rt.write_merged(w, arena, &.{ \"flex\", })") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, source, "try rt.write_merged(w, arena, &.{ \"inline-flex border\", (if (props.publr_prototype and ((if (props.publr_bind_size != null) @as(?[]const u8, rt.concat(arena, &.{ \"$e_Button_2(\", \"size: \", rt.slot_argument(arena, props.publr_bind_size, props.size), \")\" })) else @as(?[]const u8, null))) != null) @as([]const u8, \"\") else (switch (props.size) { .@\"sm\" => \"h-8 px-2\", .@\"md\" => \"h-9 px-3\", })), props.classes, });") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, source, "data-p-class=\\\"$e_List_1\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "// slot e_List_1: () => (state.busy ? \"busy\" : \"idle\")") != null);
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

test "with an engine, a live expression's first value is run on the server" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const module = try compiler.createPjsxModule(arena,
        \\import { Publr } from "publr-jsx";
        \\const TONES: Record<string, string> = { a: "text-a" };
        \\export const state = Publr.reactive({ items: [] as { tone: string }[], open: false });
        \\export function Panel({ items, label }: { items: { tone: string }[]; label: string }) {
        \\  state.items = items;
        \\  return <ul hidden={!state.open && state.items.length === 0} title={`${label}: ${state.items.length}`}>
        \\    {state.items.map((item) => <li class={TONES[item.tone] ?? "text-b"}>{item.tone}</li>)}
        \\  </ul>;
        \\}
    , "Panel.ptsx");
    var program = try Program.init(arena, &.{module});
    program.request = &.{.{
        .name = "path",
        .type = .string,
        .zig_type = "[]const u8",
        .default = null,
    }};
    program.expressions_field = "publr_expressions";
    const code = program.lower(arena, "Panel") catch |e| {
        std.debug.print("\n{s}\n", .{err.message()});
        return e;
    };
    try std.testing.expect(std.mem.indexOf(u8, code, "var publr_state_held = rt.instance(.{ .items = props.items, .open = rt.Json{ .text = \"false\" }, }, .{ .label = props.label, });") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "rt.evaluate((if (props.publr_request) |publr_request| @as(*const Request, @ptrCast(@alignCast(publr_request))).publr_expressions else null), arena, \"Panel\", \"e_Panel_3\", (try publr_state.text(arena)), .{ })") != null);
    // A row the render draws hands its value to the scope.
    try std.testing.expect(std.mem.indexOf(u8, code, "(try publr_state.text(arena)), .{ .item = item, })") != null);
    const server = try program.serverFile(arena);
    try std.testing.expect(std.mem.indexOf(u8, server, "  Panel: (state) => {\nconst TONES = { a: \"text-a\" };\nreturn {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, server, "globalThis.__publr_table") != null);
}

test "with an engine, a part in another file draws its family root's state on the server" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try compiler.createPjsxModule(arena,
        \\import { Publr } from "publr-jsx";
        \\export const state = Publr.reactive({ folder: "", items: [] as { title: string }[] });
        \\export function Library({ folder = "", items = [], children }: { folder?: string; items?: { title: string }[]; children?: JSX.Element }) {
        \\  state.folder = folder;
        \\  state.items = items;
        \\  return <div>{children}</div>;
        \\}
    , "Library.ptsx");
    const part = try compiler.createPjsxModule(arena,
        \\import { state } from "./Library.ptsx";
        \\export function LibraryGrid() {
        \\  return <ul data-current={state.folder === ""}>
        \\    {state.items.map((item) => <li>{item.title}</li>)}
        \\  </ul>;
        \\}
    , "LibraryGrid.ptsx");
    var program = try Program.init(arena, &.{ root, part });
    program.request = &.{.{
        .name = "path",
        .type = .string,
        .zig_type = "[]const u8",
        .default = null,
    }};
    program.expressions_field = "publr_expressions";
    const root_code = program.lower(arena, "Library") catch |e| {
        std.debug.print("\n{s}\n", .{err.message()});
        return e;
    };
    // The root hands its state down: to its children as they render, and to every call.
    try std.testing.expect(std.mem.indexOf(u8, root_code, "var publr_family_held = rt.family_of(\"library\", publr_state, props.publr_family);") != null);
    try std.testing.expect(std.mem.indexOf(u8, root_code, "render_in(w, arena, props.publr_request, publr_family);") != null);
    const part_code = program.lower(arena, "LibraryGrid") catch |e| {
        std.debug.print("\n{s}\n", .{err.message()});
        return e;
    };
    // A field it reads runs over the nearest root's state, else the store's initials.
    try std.testing.expect(std.mem.indexOf(u8, part_code, "(try rt.family_state(arena, props.publr_family, \"library\", \"{\\\"folder\\\":\\\"\\\",\\\"items\\\":[]}\"))") != null);
    // A list it reads draws its rows, typed as the root's prop that seeds it.
    try std.testing.expect(std.mem.indexOf(u8, part_code, "else try rt.value_into(@FieldType(Library.Props, \"items\"), arena,") != null);
    try std.testing.expect(std.mem.indexOf(u8, part_code, "const Library = @import(\"Library.zig\");") != null);
}

test "with an engine, a static expression the render cannot lower is the engine's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const module = try compiler.createPjsxModule(arena,
        \\const shout = (text: string) => text.toUpperCase() + "!";
        \\export function Label({ text, small }: { text: string; small: boolean }) {
        \\  return <span class={small ? "text-xs" : "text-sm"} title={shout(text)}>{text}</span>;
        \\}
    , "Label.ptsx");
    var program = try Program.init(arena, &.{module});
    program.request = &.{.{
        .name = "path",
        .type = .string,
        .zig_type = "[]const u8",
        .default = null,
    }};
    program.expressions_field = "publr_expressions";
    const code = try program.lower(arena, "Label");
    // The render lowers the ternary itself; the call is the engine's.
    try std.testing.expect(std.mem.indexOf(u8, code, "(if (props.small) \"text-xs\" else \"text-sm\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "rt.write_value_attribute(w, \"title\", (try rt.evaluate(") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "var publr_state_held = rt.instance(.{ }, .{ .text = props.text, });") != null);
    const server = try program.serverFile(arena);
    try std.testing.expect(std.mem.indexOf(u8, server, "const shout = (text) => text.toUpperCase() + \"!\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, server, "({ text }) => shout(text)") != null);
}

test "a slot that calls an intrinsic takes its JavaScript into the browser's stores" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const module = try compiler.createPjsxModule(arena,
        \\import { Publr, initials } from "publr-jsx";
        \\export const state = Publr.reactive({ name: "" });
        \\export function Badge() { return <span>{initials(state.name)}</span>; }
    , "Badge.ptsx");
    const program = try Program.init(arena, &.{module});
    _ = try program.lower(arena, "Badge");
    const stores = try program.storesFile(arena);
    try std.testing.expect(std.mem.indexOf(u8, stores, "const initials = (name) =>") != null);
    try std.testing.expect(std.mem.indexOf(u8, stores, "e_Badge_1: () => initials(state.name)") != null);
}

test "with an engine, a list a computation makes draws its rows from the engine's answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const module = try compiler.createPjsxModule(arena,
        \\import { Publr } from "publr-jsx";
        \\type Item = { label: string; on: boolean };
        \\export const state = Publr.reactive({ items: [] as Item[] });
        \\export function Picks({ items, rows }: { items: Item[]; rows: Item[] }) {
        \\  state.items = items;
        \\  return <div>
        \\    <ul>{state.items.filter((item) => item.on).map((item) => <li key={item.label}>{item.label}</li>)}</ul>
        \\    <ol>{rows.filter((row) => !row.on).map((row) => <li>{row.label}</li>)}</ol>
        \\  </div>;
        \\}
    , "Picks.ptsx");
    var program = try Program.init(arena, &.{module});
    program.request = &.{.{
        .name = "path",
        .type = .string,
        .zig_type = "[]const u8",
        .default = null,
    }};
    program.expressions_field = "publr_expressions";
    const code = program.lower(arena, "Picks") catch |e| {
        std.debug.print("\n{s}\n", .{err.message()});
        return e;
    };
    // The browser's list is the slot; the server's rows are its answer, typed as the state's.
    try std.testing.expect(std.mem.indexOf(u8, code, "data-p-for=\\\"item of $e_Picks_1\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "(try rt.value_into(@TypeOf(props.items), arena, (try rt.evaluate(") != null);
    // A list over props the render cannot filter is the engine's too.
    try std.testing.expect(std.mem.indexOf(u8, code, "(try rt.value_into(@TypeOf(props.rows), arena, (try rt.evaluate(") != null);
}

test "an unseeded state field cast to a string union fills an enum prop with its initial" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const grid = try compiler.createPjsxModule(arena,
        \\export function Grid({ size = "md" }: { size?: "sm" | "md" | "lg" }) {
        \\  return <div data-size={size} />;
        \\}
    , "Grid.ptsx");
    const picker = try compiler.createPjsxModule(arena,
        \\import { Publr } from "publr-jsx";
        \\import { Grid } from "./Grid.ptsx";
        \\export const state = Publr.reactive({ tile_size: "lg" as "sm" | "md" | "lg" });
        \\export function Picker() {
        \\  return <div><Grid size={state.tile_size} /></div>;
        \\}
    , "Picker.ptsx");
    var program = try Program.init(arena, &.{ grid, picker });
    const code = program.lower(arena, "Picker") catch |e| {
        std.debug.print("\n{s}\n", .{err.message()});
        return e;
    };
    try std.testing.expect(std.mem.indexOf(u8, code, ".size = .@\"lg\"") != null);
}

test "a style object is written inside the element's tag, not before it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const module = try compiler.createPjsxModule(arena,
        \\export function Dot({ tone = "red" }: { tone?: string }) {
        \\  return <p><span class="dot" style={{ left: "calc(1px + 2px)" }} title={tone}></span><i style={{ color: tone }}></i></p>;
        \\}
    , "Dot.ptsx");
    var program = try Program.init(arena, &.{module});
    const code = program.lower(arena, "Dot") catch |e| {
        std.debug.print("\n{s}\n", .{err.message()});
        return e;
    };
    try std.testing.expect(std.mem.indexOf(u8, code, "<span") != null);
    const tag = std.mem.indexOf(u8, code, "<span").?;
    const style = std.mem.indexOf(u8, code, "style=\\\"left:calc(1px + 2px)").?;
    try std.testing.expect(style > tag);
    const italic = std.mem.indexOf(u8, code, "<i").?;
    const color = std.mem.indexOf(u8, code, "\"style\", try rt.style_text").?;
    try std.testing.expect(color > italic);
}

test "the same enum shape at two depths gets two type names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const module = try compiler.createPjsxModule(arena,
        \\export type ShelfProps = {
        \\  files: Array<{ icon: "a" | "b" }>;
        \\  parts: Array<{ files: Array<{ icon: "a" | "b" }> }>;
        \\  cells: Array<{ files: Array<{ icon: "a" | "b" }> }>;
        \\};
        \\export function Shelf({ files, parts, cells }: ShelfProps) {
        \\  return <p data-count={`${files.length}${parts.length}${cells.length}`}></p>;
        \\}
    , "Shelf.ptsx");
    var program = try Program.init(arena, &.{module});
    _ = program.lower(arena, "Shelf") catch |e| {
        std.debug.print("\n{s}\n", .{err.message()});
        return e;
    };
}
