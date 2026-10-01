//! Syntax-only entry point for embedders that already link the server runtime separately.
pub const ast = @import("ast.zig");
pub const template_syntax = @This();
pub const syntax = @import("parser.zig");
pub const lastError = @import("err.zig").message;
pub const dom = struct {
    pub const stripTypes = @import("strip_types.zig").stripTypes;
};
