const std = @import("std");
const build_library = @import("build/library.zig").build;
const build_cli = @import("build/cli.zig").build;
const build_tests = @import("build/tests.zig").build;
const amalgamate = @import("publr_tools").amalgamate;
const build_docs = @import("publr_tools").docs;

pub fn build(b: *std.Build) void {
    const library = build_library(b);
    const amalgamation = amalgamate(b, library, .{});

    build_cli(b, library);
    build_tests(b, library, amalgamation.module);
    build_docs(b, amalgamation, .{});
}
