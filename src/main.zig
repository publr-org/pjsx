//! CLI: `pjsx <dom|zig|store|ir|classes|canonical> <file>... [--runtime-import X] [--out <dir>]`
//!
//! Streams each compiled output to stdout (code, JSON, or one class per line),
//! or — with `--out` — writes one file per input named after the component
//! module (`<Name>.js`, `<Name>.zig`, `<Name>.store.js`, `<Name>.ir.json`,
//! `<Name>.classes`). The `zig` command lowers each file through the `zig`
//! SSR target with a compile set of just that module, so cross-module
//! component imports will not resolve in this single-file mode — use
//! `pjsx.targets.zig.Program` for whole-set lowering. Diagnostics go to
//! stderr; exit status 1 on a compile error, 2 on usage errors.

const std = @import("std");
const Io = std.Io;
const pjsx = @import("pjsx");

const Command = enum { dom, zig, behavior, @"dom-zig", @"dom-behavior", php, store, ir, classes, canonical, @"portable-dom", @"portable-zig", @"portable-php", @"portable-ir" };

const Options = struct {
    command: Command,
    files: []const []const u8,
    runtime_import: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
};

fn usage() noreturn {
    std.log.err("usage: pjsx <dom|zig|behavior|dom-zig|dom-behavior|php|portable-dom|portable-zig|portable-php|portable-ir|store|ir|classes|canonical> <file>... [--runtime-import X] [--out <dir>]", .{});
    std.process.exit(2);
}

fn parseArgs(arena: std.mem.Allocator, args: []const [:0]const u8) !Options {
    if (args.len < 3) usage();
    const command = std.meta.stringToEnum(Command, args[1]) orelse usage();
    var files: std.ArrayList([]const u8) = .empty;
    var options = Options{ .command = command, .files = &.{} };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--runtime-import")) {
            i += 1;
            if (i >= args.len) usage();
            options.runtime_import = args[i];
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) usage();
            options.out_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            usage();
        } else {
            try files.append(arena, arg);
        }
    }
    if (files.items.len == 0) usage();
    options.files = files.items;
    return options;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Everything the compiler allocates lives as long as the process.
    const arena = init.arena.allocator();
    const options = try parseArgs(arena, try init.minimal.args.toSlice(arena));

    const cwd = Io.Dir.cwd();
    const out_dir: ?Io.Dir = if (options.out_dir) |dir| blk: {
        cwd.createDirPath(io, dir) catch |e| std.process.fatal("pjsx: cannot create {s}: {t}", .{ dir, e });
        break :blk try cwd.openDir(io, dir, .{});
    } else null;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);

    for (options.files) |file| {
        const source = cwd.readFileAlloc(io, file, arena, .limited(1 << 24)) catch |e| {
            std.process.fatal("pjsx: cannot read {s}: {t}", .{ file, e });
        };
        if (out_dir) |dir| {
            // Validation/lowering must succeed before replacing an existing artifact.
            var compiled: Io.Writer.Allocating = .init(arena);
            try compileTo(io, arena, &compiled.writer, options, file, source);
            var name_buffer: [Io.Dir.max_name_bytes]u8 = undefined;
            const name = try outputName(&name_buffer, options.command, file);
            const out_file = try dir.createFile(io, name, .{});
            defer out_file.close(io);
            var file_buffer: [4096]u8 = undefined;
            var file_writer: Io.File.Writer = .init(out_file, io, &file_buffer);
            try file_writer.interface.writeAll(compiled.written());
            try file_writer.interface.flush();
        } else {
            try compileTo(io, arena, &stdout_writer.interface, options, file, source);
        }
    }
    try stdout_writer.interface.flush(); // Don't forget to flush!
}

/// `<stem>.<extension>` for `--out`, where the stem is the input's basename
/// without its `.pjsx`/`.ptsx` extension.
fn outputName(buffer: []u8, command: Command, file: []const u8) ![]const u8 {
    const stem = std.fs.path.stem(std.fs.path.basename(file));
    const extension: []const u8 = switch (command) {
        .dom, .@"portable-dom" => "js",
        .zig, .@"portable-zig" => "zig",
        .store => "store.js",
        .behavior, .@"dom-behavior" => "behavior.js",
        .@"dom-zig" => "zig",
        .ir => "ir.json",
        .@"portable-ir" => "portable.json",
        .php, .@"portable-php" => "php",
        .classes => "classes",
        .canonical => "tsx",
    };
    return std.fmt.bufPrint(buffer, "{s}.{s}", .{ stem, extension });
}

/// Compile one module and stream the requested artifact into `writer`.
fn compileTo(io: Io, arena: std.mem.Allocator, writer: *Io.Writer, options: Options, file: []const u8, source: []const u8) !void {
    var resolver = pjsx.FileResolver{ .io = io };
    compile(arena, writer, options, file, source, resolver.resolver()) catch |e| switch (e) {
        // The diagnostic text is the contract (same as the TypeScript `Error`
        // message); print it verbatim rather than through the logger.
        error.Pjsx => {
            var buffer: [256]u8 = undefined;
            const stderr = try io.lockStderr(&buffer, null);
            stderr.file_writer.interface.print("{s}\n", .{pjsx.lastError()}) catch {};
            stderr.file_writer.interface.flush() catch {};
            io.unlockStderr();
            std.process.exit(1);
        },
        else => return e,
    };
}

fn compile(arena: std.mem.Allocator, writer: *Io.Writer, options: Options, file: []const u8, source: []const u8, resolver: pjsx.TypeResolver) !void {
    switch (options.command) {
        .@"portable-ir" => {
            const program = try pjsx.portable.prepare(arena, source, file, resolver);
            try program.writeJson(writer);
            try writer.writeByte('\n');
        },
        .@"portable-dom", .@"portable-zig", .@"portable-php" => {
            const program = try pjsx.portable.prepare(arena, source, file, resolver);
            const target = if (options.command == .@"portable-dom") pjsx.portable.domTarget() else if (options.command == .@"portable-php") pjsx.portable.phpTarget() else pjsx.portable.zigTarget();
            try writer.writeAll(try program.emit(target, .{ .runtime_import = options.runtime_import orelse "publr/dom" }));
        },
        .php => {
            const program = try pjsx.portable.prepareServer(arena, source, file, resolver);
            try writer.writeAll(try program.emit(pjsx.portable.phpTarget(), .{}));
        },
        .canonical => try writer.writeAll((try pjsx.canonicalize(arena, source)).code),
        .dom => try writer.writeAll((try pjsx.dom.transformPjsxToDom(arena, source, .{ .filename = file, .runtime_import = options.runtime_import orelse "publr/dom", .resolver = resolver })).code),
        // Single-file mode: the compile set is just this module, so
        // cross-module component imports will not resolve here.
        .@"dom-zig" => {
            const module = try pjsx.compiler.createPjsxModuleWithResolver(arena, source, file, resolver);
            try writer.writeAll(try pjsx.compiled.lowerDOM(arena, module));
        },
        .@"dom-behavior" => {
            const module = try pjsx.compiler.createPjsxModuleWithResolver(arena, source, file, resolver);
            try writer.writeAll(try pjsx.compiled.behaviorDOM(arena, module));
        },
        .behavior => {
            const module = try pjsx.compiler.createPjsxModuleWithResolver(arena, source, file, resolver);
            try writer.writeAll(try pjsx.compiled.behavior(arena, module));
        },
        .zig => {
            const module = try pjsx.compiler.createPjsxModuleWithResolver(arena, source, file, resolver);
            try writer.writeAll(try pjsx.compiled.lowerWithResolver(arena, module, resolver));
        },
        .store => {
            if (try pjsx.store.lowerParsedStoreRegistration(arena, &(try pjsx.analyze.parsePjsxWithResolver(arena, source, file, resolver)))) |registration| {
                try writer.writeAll(registration.code);
            }
        },
        .ir => {
            const module = try pjsx.compiler.createPjsxModuleWithResolver(arena, source, file, resolver);
            try pjsx.compiler.writeJson(arena, module, writer);
            try writer.writeByte('\n');
        },
        .classes => {
            for ((try pjsx.compiler.createPjsxModuleWithResolver(arena, source, file, resolver)).classes) |class| {
                try writer.print("{s}\n", .{class});
            }
        },
    }
}
