//! Optional host adapter for relative TypeScript/TSX imports. The type resolver
//! itself remains I/O-free; build systems can supply their own package aliases.
const std = @import("std");
const types = @import("types.zig");
const err = @import("err.zig");

pub const FileResolver = struct {
    io: std.Io,
    imports: []const Import = &.{},
    pub const Import = struct { specifier: []const u8, filename: []const u8 };
    pub fn resolver(self: *FileResolver) types.Resolver {
        return .{ .context = self, .load = load };
    }
    fn load(context: *anyopaque, a: std.mem.Allocator, importer: []const u8, specifier: []const u8) err.Error!?types.Source {
        const self: *FileResolver = @ptrCast(@alignCast(context));
        for (self.imports) |entry| {
            if (std.mem.eql(u8, entry.specifier, specifier)) {
                const code = std.Io.Dir.cwd().readFileAlloc(self.io, entry.filename, a, .limited(16 << 20)) catch return err.fail("pjsx: cannot read type module {s}", .{entry.filename});
                return .{ .filename = entry.filename, .code = code };
            }
        }
        if (!std.mem.startsWith(u8, specifier, ".") and !std.fs.path.isAbsolute(specifier)) return null;
        const base = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(importer) orelse ".", specifier });
        for ([_][]const u8{ "", ".ts", ".tsx", ".ptsx", "/index.ts", "/index.tsx" }) |suffix| {
            const filename = try std.fmt.allocPrint(a, "{s}{s}", .{ base, suffix });
            const code = std.Io.Dir.cwd().readFileAlloc(self.io, filename, a, .limited(16 << 20)) catch |e| switch (e) {
                error.FileNotFound, error.IsDir, error.NotDir => continue,
                error.OutOfMemory => return error.OutOfMemory,
                else => return err.fail("pjsx: cannot read type module {s}: {s}", .{ filename, @errorName(e) }),
            };
            return .{ .filename = filename, .code = code };
        }
        return null;
    }
};
