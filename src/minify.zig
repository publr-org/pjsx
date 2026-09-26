//! Output minification helpers. The reference `minify.ts` also exposed
//! `minifyJavaScript` / `minifyCss`, both thin wrappers over esbuild's
//! `transform`; there is no esbuild in Zig, so those are intentionally absent
//! rather than approximated. Only the hand-written HTML minifier is ported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util.zig");

/// Strip HTML comments, collapse whitespace runs to one space, drop
/// whitespace between tags, and trim.
pub fn minifyHtml(allocator: Allocator, source: []const u8) Allocator.Error![]const u8 {
    // /<!--[\s\S]*?-->/g → ""
    var without_comments: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        if (std.mem.startsWith(u8, source[i..], "<!--")) {
            if (std.mem.indexOfPos(u8, source, i + 4, "-->")) |close| {
                i = close + 3;
                continue;
            }
        }
        try without_comments.append(allocator, source[i]);
        i += 1;
    }
    // /\s+/g → " "
    var collapsed: std.ArrayList(u8) = .empty;
    var in_ws = false;
    for (without_comments.items) |c| {
        if (util.isWhitespace(c)) {
            if (!in_ws) try collapsed.append(allocator, ' ');
            in_ws = true;
        } else {
            try collapsed.append(allocator, c);
            in_ws = false;
        }
    }
    // />\s+</g → "><"
    const tight = try util.replaceAll(allocator, collapsed.items, "> <", "><");
    return allocator.dupe(u8, util.trim(tight));
}

test "minifyHtml strips comments and inter-tag whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try minifyHtml(arena.allocator(), "  <!-- hi -->\n<div>\n  <span>a  b</span>\n</div>\n");
    try std.testing.expectEqualStrings("<div><span>a b</span></div>", out);
}
