const std = @import("std");

/// The compiler as a library: pure Zig, no dependencies, no I/O. `src/root.zig`
/// is the curated public surface; everything else is reachable only through it,
/// which is what the amalgamation turns into real privacy.
pub fn build(b: *std.Build) *std.Build.Module {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    return b.addModule("pjsx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}
