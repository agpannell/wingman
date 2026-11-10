//! A nonempty rectangle on a stored image's top-left pixel grid. Image codecs share its checked
//! containment rules; selection does not resample pixels.

const std = @import("std");
const ImageRegion = @This();

/// Left edge in source texels.
x: u32,
/// Top edge in source texels.
y: u32,
/// Nonzero horizontal extent.
width: u32,
/// Nonzero vertical extent.
height: u32,

/// Empty, overflowing or out-of-bounds selection.
pub const Error = error{InvalidRegion};

/// Checks containment without overflowing an endpoint or permitting an empty selection.
pub fn validate(self: ImageRegion, source_width: u32, source_height: u32) ImageRegion.Error!void {
    if (self.width == 0 or self.height == 0) return error.InvalidRegion;
    if (self.x > source_width or self.y > source_height) return error.InvalidRegion;
    const remaining_width = source_width - self.x;
    const remaining_height = source_height - self.y;
    if (self.width > remaining_width or self.height > remaining_height) return error.InvalidRegion;
}

test "region containment rejects empty overflow and invalid endpoints" {
    try (ImageRegion{ .x = 1, .y = 2, .width = 3, .height = 4 }).validate(4, 6);
    try (ImageRegion{ .x = 0, .y = 0, .width = 1, .height = 1 }).validate(1, 1);
    for (
        [_]ImageRegion{
            .{ .x = 0, .y = 0, .width = 0, .height = 1 },
            .{ .x = 0, .y = 0, .width = 1, .height = 0 },
            .{ .x = 4, .y = 0, .width = 1, .height = 1 },
            .{ .x = 0, .y = 6, .width = 1, .height = 1 },
            .{ .x = 1, .y = 2, .width = 4, .height = 4 },
            .{ .x = 1, .y = 2, .width = 3, .height = 5 },
            .{ .x = 1, .y = 0, .width = std.math.maxInt(u32), .height = 1 },
            .{ .x = 0, .y = std.math.maxInt(u32), .width = 1, .height = 1 },
        },
    ) |region| try std.testing.expectError(error.InvalidRegion, region.validate(4, 6));
}
