const std = @import("std");

/// `pjsx <dom|zig|store|ir|classes> <file>...` — the compiler driven from the
/// command line; installed by the default step.
pub fn build(b: *std.Build, library: *std.Build.Module) void {
    const exe = b.addExecutable(.{
        .name = "pjsx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = library.resolved_target,
            .optimize = library.optimize,
            .imports = &.{.{ .name = "pjsx", .module = library }},
        }),
    });
    b.installArtifact(exe);
}
