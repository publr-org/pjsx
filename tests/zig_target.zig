//! The design-system corpus through the `zig` SSR target: every component in
//! `design-system-v2/src/components` compiles and lowers — the 143-module
//! guarantee the demo's conformance harness used to carry. Run with
//! `zig build test -Dds_root=<path to design-system-v2/src/components>`;
//! skipped when the option is unset.
const std = @import("std");
const pjsx = @import("pjsx");
const build_options = @import("build_options");

test "every design-system component lowers through the zig target" {
    const ds_root = build_options.ds_root orelse return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, ds_root, .{ .iterate = true });
    defer dir.close(io);

    var resolver = pjsx.FileResolver{ .io = io };
    var irs: std.ArrayList(*const pjsx.compiler.ModuleIR) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".ptsx") and
            !std.mem.endsWith(u8, entry.basename, ".pjsx")) continue;
        const source = try dir.readFileAlloc(io, entry.path, arena, .limited(4 << 20));
        const label = try std.fs.path.join(arena, &.{ ds_root, entry.path });
        const module = pjsx.compiler.createPjsxModuleWithResolver(arena, source, label, resolver.resolver()) catch |e| {
            std.debug.print("corpus: {s} does not compile: {s}\n", .{ entry.path, pjsx.lastError() });
            return e;
        };
        try irs.append(arena, module);
    }

    // The corpus is the whole design system; a near-empty walk means the
    // option points somewhere wrong.
    try std.testing.expect(irs.items.len >= 100);

    const program = try pjsx.targets.zig.Program.init(arena, irs.items);

    var failures: usize = 0;
    for (irs.items) |module| {
        _ = program.lower(arena, module.component.name) catch {
            std.debug.print("corpus: {s} does not lower: {s}\n", .{ module.component.name, pjsx.lastError() });
            failures += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
