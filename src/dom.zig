//! Compile general-purpose PJSX into direct PublrJS DOM ESM.
//!
//! Unlike the portable multi-target lowerer, this mechanical DOM transform does
//! not require a component schema. It is therefore suitable for gallery
//! modules, application roots, and other browser-only PJSX composition.

const std = @import("std");
const Allocator = std.mem.Allocator;
const err = @import("err.zig");
const transform = @import("transform.zig");
const strip_types = @import("strip_types.zig");

pub const canonicalize = @import("canonicalize.zig").canonicalize;

pub const DomTransformOptions = struct {
    filename: []const u8,
    runtime_import: ?[]const u8 = null,
    state_runtime_import: []const u8 = "publr/runtime",
    resolver: ?@import("types.zig").Resolver = null,
};

pub const DomTransformOutput = struct {
    code: []const u8,
    /// Source map — see transform.zig; currently always null.
    map: ?[]const u8,
};

pub fn transformPjsxToDom(allocator: Allocator, source: []const u8, options: DomTransformOptions) err.Error!DomTransformOutput {
    const canonical = try canonicalize(allocator, source);
    const declarations = try @import("intrinsics.zig").compile(allocator, canonical.code, options.filename, .{ .runtime_import = options.state_runtime_import });
    const transformed = try transform.transformPjsx(allocator, declarations, .{
        .runtime_import = options.runtime_import,
        .filename = options.filename,
        .resolver = options.resolver,
    });
    const filename = try std.fmt.allocPrint(allocator, "{s}.ts", .{options.filename});
    const specialized = try @import("specialize.zig").compile(allocator, transformed.code, filename, options.runtime_import orelse "publr/dom");
    const stripped = try strip_types.stripTypes(allocator, specialized, filename);
    return .{ .code = stripped, .map = null };
}

test "transformPjsxToDom canonicalizes, transforms and strips types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try transformPjsxToDom(arena.allocator(),
        \\export const toggle = (event: Event) => {};
        \\export function Badge({ label }: { label: string }) {
        \\  return <span :show={label}>{label}</span>;
        \\}
    , .{ .filename = "badge.ptsx" });
    try std.testing.expect(std.mem.indexOf(u8, out.code, "(event) =>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.code, "Event") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.code, "show($$dom.element(\"span\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.code, "Badge({") != null);
}

test "only explicit component root fragments become p-fragment elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try transformPjsxToDom(arena.allocator(),
        \\export function Root() { return <><span>one</span><><span>two</span></></>; }
        \\export const arrow = () => <><i>three</i></>;
        \\export function Element() { return <div><><b>four</b></></div>; }
    , .{ .filename = "Roots.ptsx" });
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.code, ".element(\"p-fragment\""));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.code, ".fragment("));
    try std.testing.expect(std.mem.indexOf(u8, out.code, ".styles(") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.code, "p-island") == null);
}
