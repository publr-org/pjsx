//! The minimal `class_merge` implementation the library's own runtime tests
//! run against: a plain space-join. Real consumers provide a Tailwind-aware
//! resolver (the demo wires the Publr JIT's).
const std = @import("std");

pub fn merge_classes(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.mem.join(arena, " ", parts);
}
