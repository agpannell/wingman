//! Deterministic binary floating-point rounding for PCM conversion.

const testing = @import("std").testing;
const float = @import("../common/float.zig");

const magnitude_mask: u64 = 0x7fff_ffff_ffff_ffff;
const overflow_midpoint: u64 = 0x47ef_ffff_f000_0000;

/// Reports whether the input bits narrow to a finite binary32 value under nearest-even rounding.
pub fn isFiniteResult(bits: u64) bool {
    return bits & magnitude_mask < overflow_midpoint;
}

/// Returns nearest-even binary32 bits, or null for nonfinite input or rounded overflow.
pub fn toF32Bits(bits: u64) ?u32 {
    if (!isFiniteResult(bits)) return null;
    return @bitCast(float.narrow32(@as(f64, @bitCast(bits))));
}

test "nearest-even narrowing covers zeros, ties and overflow boundaries" {
    // These literals include signed underflow ties and neighbors, ties near one, finite values just
    // below overflow, and the overflow midpoint where the result ceases to be finite.
    const cases = [_]struct {
        input: u64,
        expected: ?u32,
    }{
        .{ .input = 0, .expected = 0 },
        .{ .input = 0x8000_0000_0000_0000, .expected = 0x8000_0000 },
        .{ .input = 0x3690_0000_0000_0000, .expected = 0 },
        .{ .input = 0x3690_0000_0000_0001, .expected = 1 },
        .{ .input = 0xb690_0000_0000_0000, .expected = 0x8000_0000 },
        .{ .input = 0xb690_0000_0000_0001, .expected = 0x8000_0001 },
        .{ .input = 0x3ff0_0000_1000_0000, .expected = 0x3f80_0000 },
        .{ .input = 0x3ff0_0000_3000_0000, .expected = 0x3f80_0002 },
        .{ .input = 0x47ef_ffff_e000_0000, .expected = 0x7f7f_ffff },
        .{ .input = 0x47ef_ffff_efff_ffff, .expected = 0x7f7f_ffff },
        .{ .input = 0xc7ef_ffff_efff_ffff, .expected = 0xff7f_ffff },
        .{ .input = overflow_midpoint, .expected = null },
        .{ .input = 0xc7ef_ffff_f000_0000, .expected = null },
        .{ .input = 0x7ff0_0000_0000_0000, .expected = null },
        .{ .input = 0x7ff0_0000_0000_0001, .expected = null },
        .{ .input = 0xfff8_0000_0000_0001, .expected = null },
    };
    for (cases) |case| {
        try testing.expectEqual(case.expected, toF32Bits(case.input));
        try testing.expectEqual(case.expected != null, isFiniteResult(case.input));
    }
}
