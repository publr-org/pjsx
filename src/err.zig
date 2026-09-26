//! Compiler diagnostics. The TypeScript reference throws `Error` objects whose
//! message is the contract (tests match on it). Zig errors carry no payload, so
//! the message rides in a threadlocal that `fail` sets right before returning
//! `error.Pjsx`. Read it with `message()` immediately after catching.

const std = @import("std");

pub const Error = error{ Pjsx, OutOfMemory };

threadlocal var buffer: [4096]u8 = undefined;
threadlocal var length: usize = 0;

/// Record `fmt`/`args` as the diagnostic and return `error.Pjsx`.
pub fn fail(comptime fmt: []const u8, args: anytype) Error {
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch blk: {
        // Truncated: keep what fits.
        break :blk buffer[0..];
    };
    length = text.len;
    return error.Pjsx;
}

/// Record a literal diagnostic and return `error.Pjsx`.
pub fn failMsg(text: []const u8) Error {
    const n = @min(text.len, buffer.len);
    @memcpy(buffer[0..n], text[0..n]);
    length = n;
    return error.Pjsx;
}

/// The message of the most recent `fail` on this thread.
pub fn message() []const u8 {
    return buffer[0..length];
}

test "fail records the formatted message" {
    const result: Error!void = fail("pjsx: {s} is required", .{"label"});
    try std.testing.expectError(error.Pjsx, result);
    try std.testing.expectEqualStrings("pjsx: label is required", message());
}
