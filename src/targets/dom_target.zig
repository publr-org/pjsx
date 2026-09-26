//! PublrJS DOM target — one ordinary plugin over the public compiler contract
//! (the reference `targets/dom.ts`). It has no privileged path through core.

const std = @import("std");
const Allocator = std.mem.Allocator;
const err = @import("../err.zig");
const analyze = @import("../analyze.zig");
const dom = @import("../dom.zig");
const compiler = @import("../compiler.zig");

pub const DomTargetOptions = struct { runtime_import: ?[]const u8 = null, resolver: ?@import("../types.zig").Resolver = null };

pub const DomOutput = struct {
    code: []const u8,
    map: ?[]const u8,
    classes: []const []const u8,
};

pub fn lowerPjsxToDom(allocator: Allocator, source: []const u8, filename: []const u8, runtime_import: ?[]const u8) err.Error!DomOutput {
    return lowerPjsxToDomWithResolver(allocator, source, filename, runtime_import, null);
}

pub fn lowerPjsxToDomWithResolver(allocator: Allocator, source: []const u8, filename: []const u8, runtime_import: ?[]const u8, resolver: ?@import("../types.zig").Resolver) err.Error!DomOutput {
    const parsed = try analyze.parsePjsxWithResolver(allocator, source, filename, resolver);
    const result = try dom.transformPjsxToDom(allocator, source, .{ .filename = filename, .runtime_import = runtime_import orelse "publr/dom", .resolver = resolver });
    return .{ .code = result.code, .map = result.map, .classes = try analyze.collectClassTokens(allocator, &parsed) };
}

pub const DomTarget = compiler.TargetPlugin(DomTargetOptions, DomOutput);

fn compileDom(allocator: Allocator, module: *const compiler.ModuleIR, _: compiler.CompileContext, options: DomTargetOptions) err.Error!DomOutput {
    const result = try dom.transformPjsxToDom(allocator, module.source, .{ .filename = module.filename, .runtime_import = options.runtime_import orelse "publr/dom", .resolver = options.resolver });
    return .{ .code = result.code, .map = result.map, .classes = module.classes };
}

pub fn domTarget() DomTarget {
    return .{ .name = "publrjs-dom", .api_version = 1, .compile = compileDom };
}

test "domTarget is a plain plugin value with the public API version" {
    const target = domTarget();
    try std.testing.expectEqualStrings("publrjs-dom", target.name);
    try std.testing.expectEqual(@as(u32, 1), target.api_version);
}
