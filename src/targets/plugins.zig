//! Plugin values for the maintained targets. They live here rather than in
//! the lowering modules (`targets/zig.zig`, `targets/dom_target.zig`) so
//! those stay plain libraries; the split is organizational only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const err = @import("../err.zig");
const compiler = @import("../compiler.zig");
const zig_target = @import("zig.zig");
const dom_target = @import("dom_target.zig");

pub const lowerPjsxToDom = dom_target.lowerPjsxToDom;
pub const domTarget = dom_target.domTarget;
pub const DomOutput = dom_target.DomOutput;

pub const ZigTargetOptions = struct {
    /// The whole compile set — components resolve their imports against it.
    /// The compiled module itself may be included or not; it is added when
    /// absent.
    modules: []const *const compiler.ModuleIR = &.{},
};
pub const ZigTarget = compiler.TargetPlugin(ZigTargetOptions, zig_target.ZigOutput);

fn compileZig(allocator: Allocator, module: *const compiler.ModuleIR, _: compiler.CompileContext, options: ZigTargetOptions) err.Error!zig_target.ZigOutput {
    return zig_target.lowerPjsxToZig(allocator, module, options.modules) catch |e| switch (e) {
        // The lowering writes into allocating writers; a write failure is an
        // allocation failure.
        error.WriteFailed => error.OutOfMemory,
        error.Pjsx => error.Pjsx,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// The `zig` SSR target: PJSX IR → Zig render functions (see `targets/zig.zig`).
pub fn zigTarget() ZigTarget {
    return .{ .name = "zig", .api_version = 1, .compile = compileZig };
}
