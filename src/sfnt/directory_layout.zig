//! Bounds of the fixed SFNT directory header and table-record array. A collection can check this
//! framing before a caller selects a face; it does not admit the flavor or table payload ranges.

const std = @import("std");
const binary = @import("../common/font_binary.zig");

pub const header_size = 12;
pub const record_size = 16;

/// An incomplete directory or an unrepresentable array position.
pub const Error = binary.Error;

/// Returns the absolute end of the complete table-record array, without inspecting its records.
pub fn endOffset(source: []const u8, offset: usize) Error!usize {
    const header_end = try binary.arrayOffset(offset, 1, header_size);
    if (header_end > source.len) return error.InvalidFont;
    const table_count = try binary.read(u16, source, offset + 4);
    const records_end = try binary.arrayOffset(header_end, table_count, record_size);
    if (records_end > source.len) return error.InvalidFont;
    return records_end;
}

test endOffset {
    var bytes: [28]u8 = @splat(0);
    try std.testing.expectEqual(12, try endOffset(&bytes, 0));
    std.mem.writeInt(u16, bytes[4..6], 1, .big);
    try std.testing.expectEqual(28, try endOffset(&bytes, 0));
    try std.testing.expectError(error.InvalidFont, endOffset(bytes[0..27], 0));
    try std.testing.expectError(error.InvalidFont, endOffset(&bytes, 17));
    try std.testing.expectError(error.InvalidFont, endOffset(&bytes, std.math.maxInt(usize)));
}
