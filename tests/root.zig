//! Integration suite: the original `tests/*.test.js` suite ported one test at
//! a time, exercising only the public `pjsx` module the way a consumer would.
//! Assertions keep the original regex patterns verbatim (see regex.zig).
pub const regex = @import("regex.zig");
pub const compiler = @import("compiler.zig");
pub const zig_gaps = @import("zig_gaps.zig");
pub const props = @import("props.zig");
pub const zig_target = @import("zig_target.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
