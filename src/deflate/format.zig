//! RFC 1951 wire fields and match-code admission.

const std = @import("std");

/// RFC 1951 wire order of the dynamic block's code-length alphabet.
pub const precode_order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// Match lengths for symbols 257..285, before their extra bits are added.
pub const length_base = [_]u16{
    3,   4,   5,   6,   7,   8,   9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99,
    115, 131, 163, 195, 227, 258,
};

/// Extra-bit counts corresponding to length_base.
pub const length_extra = [_]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
};

/// Match distances for symbols 0..29, before their extra bits are added.
pub const distance_base = [_]u16{
    1,   2,   3,   4,    5,    7,    9,    13,   17,   25,   33,    49,    65,    97, 129, 193, 257,
    385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
};

/// Extra-bit counts corresponding to distance_base.
pub const distance_extra = [_]u8{
    0,  0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
};

/// Length-code offset for an admitted match length in 3..258; add 257 for its wire symbol.
pub fn lengthSlot(length: usize) u8 {
    if (length == 258) return 28;
    if (length <= 10) return @intCast(length - 3);
    const order: u8 = @intCast(std.math.log2_int(usize, length - 3) - 2);
    const shift: std.math.Log2Int(usize) = @intCast(order);
    return @intCast(@as(usize, order) * 4 + ((length - 3) >> shift));
}

/// Distance symbol for an admitted backward distance in 1..32768.
pub fn distanceSlot(distance: usize) u8 {
    if (distance <= 4) return @intCast(distance - 1);
    const order: u8 = @intCast(std.math.log2_int(usize, distance - 1) - 1);
    const shift: std.math.Log2Int(usize) = @intCast(order);
    return @intCast(@as(usize, order) * 2 + ((distance - 1) >> shift));
}

test "encoder slot formulas cover every RFC length and distance" {
    for (3..259) |length| {
        const slot = lengthSlot(length);
        const shift: std.math.Log2Int(usize) = @intCast(length_extra[slot]);
        const maximum = length_base[slot] + (@as(usize, 1) << shift) - 1;
        try std.testing.expect(length >= length_base[slot]);
        try std.testing.expect(length <= maximum);
        if (length == 258) try std.testing.expectEqual(28, slot);
    }
    for (1..32769) |distance| {
        const slot = distanceSlot(distance);
        const shift: std.math.Log2Int(usize) = @intCast(distance_extra[slot]);
        const maximum = distance_base[slot] + (@as(usize, 1) << shift) - 1;
        try std.testing.expect(distance >= distance_base[slot]);
        try std.testing.expect(distance <= maximum);
    }
}
