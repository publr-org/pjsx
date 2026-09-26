//! PJSX — the Publr portable JSX compiler, in Zig.
//!
//! Pipeline: `canonicalize` (dialect → TSX) → parser (TSX → ESTree-shaped
//! AST) → `analyze` (component model, schema, reactive/family bindings) →
//! either the mechanical DOM transform (`dom`) or the semantic `compiler` IR
//! that target plugins (`targets.dom`, `targets.zig`) consume.
//!
//! This file is the whole public surface. The reference TypeScript package's
//! entry points map onto it — `@publr/pjsx` is `compiler`, `./ast` is
//! `analyze`, `./dom` is `dom`, `./target-dom` is `targets.dom`, `./minify`
//! is `minify` — and the Zig library adds its own `zig` SSR target
//! (`targets.zig`). Everything else in `src/` is private to the library —
//! which the amalgamation makes literal by re-computing `pub` from what is
//! reachable from here.
//!
//! All functions allocate their results from the allocator they are given;
//! pass an arena and free it in one go. Failures return `error.Pjsx` with the
//! diagnostic text — identical to the TypeScript `Error` message — available
//! from `lastError()`.

const std = @import("std");

/// Versioned numeric compatibility contract used by all maintained targets.
pub const semantics = @import("runtime/semantics.zig");
/// Typed portable program preparation and versioned Zig/DOM target SDK.
pub const portable = @import("portable.zig");
const ast_module = @import("ast.zig");
const err_module = @import("err.zig");
const util_module = @import("util.zig");
const lexer_module = @import("lexer.zig");
const parser_module = @import("parser.zig");
const canonicalize_module = @import("canonicalize.zig");
const js_module = @import("js.zig");
const analyze_module = @import("analyze.zig");
const transform_module = @import("transform.zig");
const strip_types_module = @import("strip_types.zig");
const store_module = @import("store.zig");
const dom_module = @import("dom.zig");
const compiler_module = @import("compiler.zig");
const minify_module = @import("minify.zig");
const targets_dom_module = @import("targets/dom_target.zig");
const targets_zig_module = @import("targets/zig.zig");
const targets_plugins_module = @import("targets/plugins.zig");

/// `error.Pjsx` (a compile diagnostic, see `lastError`) or `error.OutOfMemory`.
pub const Error = err_module.Error;
/// The diagnostic of the most recent `error.Pjsx` on this thread.
pub const lastError = err_module.message;

/// Dialect → TSX rewrite of the directive attribute spellings; the first
/// compile stage and what a type-checker sees.
pub const canonicalize = canonicalize_module.canonicalize;
pub const CanonicalResult = canonicalize_module.Result;
pub const CanonicalEdit = canonicalize_module.Edit;

/// `/\.p(?:j|t)sx(?:\?|$)/` — is this module id a PJSX module? (The Vite
/// adapter's gate; the adapter itself is JavaScript.)
pub fn isPjsxModule(id: []const u8) bool {
    const path = if (std.mem.indexOfScalar(u8, id, '?')) |q| id[0..q] else id;
    return util_module.hasPjsxExtension(path);
}

/// The syntax tree the analyzer exposes through `analyze.ParsedModule`.
pub const ast = struct {
    pub const Node = ast_module.Node;
    pub const Type = ast_module.Type;
    pub const LiteralValue = ast_module.LiteralValue;
    pub const walk = ast_module.walk;
    pub const eachChild = ast_module.eachChild;
    pub const unparen = ast_module.unparen;
};

/// Component model extraction (the TypeScript `ast.ts`).
pub const analyze = struct {
    pub const parsePjsx = analyze_module.parsePjsx;
    pub const parsePjsxWithResolver = analyze_module.parsePjsxWithResolver;
    pub const collectClassTokens = analyze_module.collectClassTokens;
    pub const collectFiniteStringMaps = analyze_module.collectFiniteStringMaps;
    pub const unwrap = analyze_module.unwrap;
    pub const ParsedModule = analyze_module.ParsedModule;
    pub const ComponentAst = analyze_module.ComponentAst;
    pub const Schema = analyze_module.Schema;
    pub const PropSchema = analyze_module.PropSchema;
    pub const PropType = analyze_module.PropType;
    pub const ItemType = analyze_module.ItemType;
    pub const Primitive = analyze_module.Primitive;
    pub const ReactiveBinding = analyze_module.ReactiveBinding;
    pub const FamilyBinding = analyze_module.FamilyBinding;
    pub const ImportedFamily = analyze_module.ImportedFamily;
    pub const RefBinding = analyze_module.RefBinding;
    pub const SeedAssignment = analyze_module.SeedAssignment;
    pub const FiniteStringMaps = analyze_module.FiniteStringMaps;
};

/// The public IR and target-plugin orchestration (the TypeScript `compiler.ts`).
pub const compiler = struct {
    pub const PJSX_COMPILER_API_VERSION = compiler_module.PJSX_COMPILER_API_VERSION;
    pub const createPjsxModule = compiler_module.createPjsxModule;
    pub const createPjsxModuleWithResolver = compiler_module.createPjsxModuleWithResolver;
    pub const compilePjsx = compiler_module.compilePjsx;
    pub const collectPjsxClasses = compiler_module.collectPjsxClasses;
    pub const writeJson = compiler_module.writeJson;
    pub const toJson = compiler_module.toJson;
    pub const expressionToIR = compiler_module.expressionToIR;
    pub const expressionToJson = compiler_module.expressionToJson;
    pub const TargetPlugin = compiler_module.TargetPlugin;
    pub const CompileOptions = compiler_module.CompileOptions;
    pub const CompileContext = compiler_module.CompileContext;
    pub const SourceOrModule = compiler_module.SourceOrModule;
    pub const Capability = compiler_module.Capability;
    pub const ModuleIR = compiler_module.ModuleIR;
    pub const ComponentIR = compiler_module.ComponentIR;
    pub const ReactiveIR = compiler_module.ReactiveIR;
    pub const FamilyIR = compiler_module.FamilyIR;
    pub const ImportIR = compiler_module.ImportIR;
    pub const ImportNameIR = compiler_module.ImportNameIR;
    pub const NodeIR = compiler_module.NodeIR;
    pub const ElementNameIR = compiler_module.ElementNameIR;
    pub const AttributeIR = compiler_module.AttributeIR;
    pub const AttributeForm = compiler_module.AttributeForm;
    pub const ExpressionIR = compiler_module.ExpressionIR;
    pub const ObjectFieldIR = compiler_module.ObjectFieldIR;
    pub const TemplatePart = compiler_module.TemplatePart;
    pub const MemberProperty = compiler_module.MemberProperty;
    pub const ReferenceIR = compiler_module.ReferenceIR;
    pub const ReferenceSource = compiler_module.ReferenceSource;
    pub const LiteralIR = compiler_module.LiteralIR;
};

/// The mechanical PublrJS DOM transform: any PJSX module, no schema needed.
pub const dom = struct {
    pub const transformPjsxToDom = dom_module.transformPjsxToDom;
    pub const DomTransformOptions = dom_module.DomTransformOptions;
    pub const DomTransformOutput = dom_module.DomTransformOutput;
    /// The second stage alone: canonical TSX → runtime calls, types intact.
    pub const transformPjsx = transform_module.transformPjsx;
    pub const TransformOptions = transform_module.Options;
    pub const TransformResult = transform_module.Result;
    /// Erase TypeScript syntax from a module (what `transformPjsxToDom` runs last).
    pub const stripTypes = strip_types_module.stripTypes;
};

/// The target-neutral client store-registration lowering: for stateful
/// components, the `Publr.createLocalStore(...)` companion module.
pub const store = struct {
    pub const lowerPjsxStoreRegistration = store_module.lowerPjsxStoreRegistration;
    pub const lowerParsedStoreRegistration = store_module.lowerParsedStoreRegistration;
    pub const StoreRegistrationOutput = store_module.StoreRegistrationOutput;
};

/// HTML whitespace/comment minification.
pub const minify = struct {
    pub const minifyHtml = minify_module.minifyHtml;
};

/// The maintained target plugins; consumers implement `compiler.TargetPlugin`
/// the same way.
pub const targets = struct {
    pub const dom = struct {
        pub const lowerPjsxToDom = targets_dom_module.lowerPjsxToDom;
        pub const lowerPjsxToDomWithResolver = targets_dom_module.lowerPjsxToDomWithResolver;
        pub const domTarget = targets_dom_module.domTarget;
        pub const DomTarget = targets_dom_module.DomTarget;
        pub const DomTargetOptions = targets_dom_module.DomTargetOptions;
        pub const DomOutput = targets_dom_module.DomOutput;
    };
    pub const zig = struct {
        pub const lowerPjsxToZig = targets_zig_module.lowerPjsxToZig;
        pub const Program = targets_zig_module.Program;
        pub const ZigOutput = targets_zig_module.ZigOutput;
    };
    pub const plugins = struct {
        pub const zigTarget = targets_plugins_module.zigTarget;
        pub const ZigTarget = targets_plugins_module.ZigTarget;
        pub const ZigTargetOptions = targets_plugins_module.ZigTargetOptions;
        pub const domTarget = targets_plugins_module.domTarget;
        pub const lowerPjsxToDom = targets_plugins_module.lowerPjsxToDom;
        pub const DomOutput = targets_plugins_module.DomOutput;
    };
};

test {
    // Pull every source file's inline tests into the unit-test build.
    inline for (.{
        ast_module,       err_module,          util_module,            lexer_module,
        parser_module,    canonicalize_module, js_module,              analyze_module,
        transform_module, strip_types_module,  dom_module,             compiler_module,
        minify_module,    targets_dom_module,  targets_plugins_module, targets_zig_module,
        store_module,     portable,            semantics,
    }) |module| std.testing.refAllDecls(module);
}

/// Host-supplied TypeScript module resolution.
pub const TypeResolver = @import("types.zig").Resolver;
pub const TypeSource = @import("types.zig").Source;
pub const FileResolver = @import("file_resolver.zig").FileResolver;

/// Native SSR and transport for compiled state components.
pub const compiled = @import("compiled.zig");

