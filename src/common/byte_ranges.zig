//! Shared address-only overlap checks for borrowed byte ranges.

const std = @import("std");

/// Reports whether two borrowed byte spans share any byte; empty spans never overlap. Reads only
/// addresses and lengths, without inspecting or retaining either span. Pointer-end addition is
/// avoided so the comparison cannot overflow.
pub fn overlaps(first: []const u8, second: []const u8) bool {
    if (first.len == 0 or second.len == 0) return false;
    const a = @intFromPtr(first.ptr);
    const b = @intFromPtr(second.ptr);
    return if (a <= b) b - a < first.len else a - b < second.len;
}

/// Reports overlap after checking that both nonempty spans have representable end addresses. Empty
/// spans never overlap and do not require the other end address to be representable. Reads only
/// addresses and lengths; failure returns SizeOverflow without inspecting either span.
pub fn overlapsChecked(first: []const u8, second: []const u8) error{SizeOverflow}!bool {
    if (first.len == 0 or second.len == 0) return false;
    const a = @intFromPtr(first.ptr);
    const b = @intFromPtr(second.ptr);
    const end_a = std.math.add(usize, a, first.len) catch return error.SizeOverflow;
    const end_b = std.math.add(usize, b, second.len) catch return error.SizeOverflow;
    return a < end_b and b < end_a;
}

test overlapsChecked {
    var bytes: [4]u8 = undefined;
    try std.testing.expect(try overlapsChecked(bytes[0..2], bytes[1..3]));
    try std.testing.expect(!try overlapsChecked(bytes[0..2], bytes[2..4]));
    const last: [*]const u8 = @ptrFromInt(std.math.maxInt(usize));
    try std.testing.expectError(error.SizeOverflow, overlapsChecked(last[0..1], bytes[0..1]));
    try std.testing.expectError(error.SizeOverflow, overlapsChecked(bytes[0..1], last[0..1]));
    try std.testing.expect(!try overlapsChecked(&.{}, last[0..1]));
    try std.testing.expect(!try overlapsChecked(last[0..1], &.{}));
}

test "byte-range overlap preserves empty, touching and wrapped-address behavior" {
    var bytes: [8]u8 = undefined;
    try std.testing.expect(!overlaps(bytes[0..0], bytes[0..8]));
    try std.testing.expect(!overlaps(bytes[0..3], bytes[3..8]));
    try std.testing.expect(overlaps(bytes[0..4], bytes[3..8]));
    try std.testing.expect(overlaps(bytes[3..8], bytes[0..4]));

    // These address-only slices are never dereferenced; their ends would overflow a pointer-sized
    // integer if overlap were checked by adding the span length to its start address.
    const high = @as([*]const u8, @ptrFromInt(std.math.maxInt(usize) - 3))[0..8];
    const within = @as([*]const u8, @ptrFromInt(std.math.maxInt(usize) - 1))[0..1];
    try std.testing.expect(overlaps(high, within));
    try std.testing.expect(overlaps(within, high));
    const last: [*]const u8 = @ptrFromInt(std.math.maxInt(usize));
    try std.testing.expect(overlaps(last[0..1], last[0..1]));
}

test "byte spans distinguish empty touching and overlapping storage" {
    var storage: [16]u8 = undefined;
    try std.testing.expect(!overlaps(storage[0..0], &storage));
    try std.testing.expect(!overlaps(&storage, storage[16..16]));
    try std.testing.expect(!overlaps(storage[0..4], storage[4..8]));
    try std.testing.expect(!overlaps(storage[4..8], storage[0..4]));
    try std.testing.expect(overlaps(storage[0..4], storage[3..8]));
    try std.testing.expect(overlaps(storage[3..8], storage[0..4]));
    try std.testing.expect(overlaps(storage[0..8], storage[2..6]));
    try std.testing.expect(overlaps(storage[2..6], storage[0..8]));
}

test "separate live byte objects never overlap" {
    var first: [16]u8 = undefined;
    var second: [16]u8 = undefined;
    try std.testing.expect(!overlaps(&first, &second));
    try std.testing.expect(!overlaps(&second, &first));
}
