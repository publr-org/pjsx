const std = @import("std");

/// Unit tests live inline in `src/`; the ported `node:test` suite lives under
/// `tests/` and imports the library like a consumer. Both run against the
/// amalgamation as well, since that is the library consumers get: the one in
/// which everything outside the public surface is truly private.
pub fn build(b: *std.Build, library: *std.Build.Module, amalgamation: *std.Build.Module) void {
    const test_step = b.step("test", "Run all tests (unit + integration), on the source tree and on the amalgamation");

    // The integration suite reads repo sources for its "no backend names in
    // the core" contract tests.
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "root", b.build_root.path orelse ".");
    // The design-system corpus for the zig-target integration test; the test
    // skips when unset.
    test_options.addOption(?[]const u8, "ds_root", b.option([]const u8, "ds_root", "Path to design-system-v2/src/components for the corpus test"));

    for ([_]*std.Build.Module{ library, amalgamation }) |module| {
        const unit_tests = b.addTest(.{ .root_module = module });

        const integration_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = library.resolved_target.?,
            .optimize = library.optimize.?,
            .imports = &.{
                .{ .name = "pjsx", .module = module },
                .{ .name = "build_options", .module = test_options.createModule() },
            },
        });
        const integration_tests = b.addTest(.{ .root_module = integration_module });

        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
        test_step.dependOn(&b.addRunArtifact(integration_tests).step);
    }

    // The generated-code runtime (`src/runtime/server.zig`) is not part of the
    // library module — consumers wire it with their own `class_merge`. Its
    // tests run against the stub merge.
    const stub_class_merge = b.createModule(.{
        .root_source_file = b.path("tests/stub_class_merge.zig"),
        .target = library.resolved_target.?,
        .optimize = library.optimize.?,
    });
    const runtime_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/server.zig"),
        .target = library.resolved_target.?,
        .optimize = library.optimize.?,
        .imports = &.{.{ .name = "class_merge", .module = stub_class_merge }},
    });
    const runtime_tests = b.addTest(.{ .root_module = runtime_module });
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
}
