//! Deterministic conversion between binary32 and binary64.

const std = @import("std");
const builtin = @import("builtin");

/// Widens exactly, preserving both zero signs and every finite binary32 encoding. Infinities remain
/// infinities. NaNs follow ordinary target widening.
pub fn widen32(source: f32) f64 {
    @setFloatMode(.strict);
    const bits: u32 = @bitCast(source);
    if (bits & 0x7f80_0000 != 0) return source;

    // Hardware widening can flush a subnormal before it reaches f64. Nonzero integer significands
    // reach normal f64 values before any floating-point comparison.
    const magnitude: f64 = @floatFromInt(bits & 0x007f_ffff);
    return if (bits & 0x8000_0000 == 0) magnitude * 0x1p-149 else -magnitude * 0x1p-149;
}

fn expectExactWidening() !void {
    // Cover zero, both subnormal boundaries, the smallest normal, one, the largest finite value and
    // infinity. Each fact is checked with both signs and under the caller's float modes.
    const cases = [_]struct {
        source: u32,
        expected: u64,
    }{
        .{ .source = 0, .expected = 0 },
        .{ .source = 1, .expected = 0x36a0_0000_0000_0000 },
        .{ .source = 0x007f_ffff, .expected = 0x380f_ffff_c000_0000 },
        .{ .source = 0x0080_0000, .expected = 0x3810_0000_0000_0000 },
        .{ .source = 0x3f80_0000, .expected = 0x3ff0_0000_0000_0000 },
        .{ .source = 0x7f7f_ffff, .expected = 0x47ef_ffff_e000_0000 },
        .{ .source = 0x7f80_0000, .expected = 0x7ff0_0000_0000_0000 },
    };

    for (cases) |case| for ([_]u32{ 0, 0x8000_0000 }) |sign| {
        var source = case.source | sign;
        // Keep conversion at runtime so the active rounding and flush controls are exercised.
        std.mem.doNotOptimizeAway(&source);
        const widened = widen32(@bitCast(source));
        const expected = case.expected | (@as(u64, sign) << 32);
        try std.testing.expectEqual(expected, @as(u64, @bitCast(widened)));
    };
}

test "binary32 widening preserves values in caller float modes" {
    try expectExactWidening();

    const Control = test_support.FloatControl;
    const original = Control.read() catch return;
    defer Control.set(original);
    const rounding_mask: u32 = 3 << 13;

    for (0..4) |mode| for ([_]u32{ 0, 1 << 6, 1 << 15, Control.flushing_mask }) |flush| {
        const rounding: u32 = @as(u32, @intCast(mode)) << 13;
        const control = (original & ~(rounding_mask | Control.flushing_mask)) | rounding | flush;
        Control.set(control);
        try expectExactWidening();
    };
}

/// Rounds finite binary64 to binary32 using nearest-even, preserving gradual underflow and signed
/// zero. Finite overflow becomes signed infinity; nonfinite inputs use the target float cast.
pub fn narrow32(source: f64) f32 {
    const bits: u64 = @bitCast(source);
    const magnitude = bits & 0x7fff_ffff_ffff_ffff;
    const sign: u32 = @truncate((bits >> 32) & 0x8000_0000);
    if (magnitude >= 0x7ff0_0000_0000_0000) return @floatCast(source);

    // The overflow threshold is halfway between the largest finite f32 and 2^128. f64's encoded
    // exponents 873 and 897 represent 2^-150 and 2^-126, the zero midpoint and minimum normal f32.
    if (magnitude >= 0x47ef_ffff_f000_0000) return @bitCast(sign | 0x7f80_0000);
    const exponent: u16 = @intCast(magnitude >> 52);
    if (exponent < 873) return @bitCast(sign);
    const significand = (magnitude & 0x000f_ffff_ffff_ffff) | 0x0010_0000_0000_0000;

    if (exponent < 897) {
        // Shift the f64 significand to units of the f32 subnormal quantum, 2^-149.
        const shift: u6 = @intCast(926 - exponent);
        return @bitCast(sign | @as(u32, @intCast(roundRight(significand, shift))));
    }

    // Shifting away the 29 extra fraction bits leaves exponent and fraction in f32 positions.
    // Rebiasing the exponent in that combined word lets a rounding carry advance it naturally.
    const rounded = roundRight(magnitude, 29) - (@as(u64, 896) << 23);
    return @bitCast(sign | @as(u32, @intCast(rounded)));
}

fn roundRight(value: u64, shift: u6) u64 {
    const whole = value >> shift;
    const remainder = value & ((@as(u64, 1) << shift) - 1);
    const half = @as(u64, 1) << (shift - 1);
    return whole + @intFromBool(remainder > half or (remainder == half and whole & 1 != 0));
}

test "binary64 narrowing handles ties, signed underflow and overflow" {
    const cases = [_]struct {
        input: u64,
        expected: u32,
    }{
        .{ .input = 0, .expected = 0 },
        .{ .input = 0x8000_0000_0000_0000, .expected = 0x8000_0000 },
        .{ .input = 0x3690_0000_0000_0000, .expected = 0 },
        .{ .input = 0x3690_0000_0000_0001, .expected = 1 },
        .{ .input = 0x3ff0_0000_1000_0000, .expected = 0x3f80_0000 },
        .{ .input = 0x3ff0_0000_3000_0000, .expected = 0x3f80_0002 },
        .{ .input = 0x47ef_ffff_efff_ffff, .expected = 0x7f7f_ffff },
        .{ .input = 0x47ef_ffff_f000_0000, .expected = 0x7f80_0000 },
    };
    for (cases) |case| {
        const source: f64 = @bitCast(case.input);
        const result: u32 = @bitCast(narrow32(source));
        try std.testing.expectEqual(case.expected, result);
    }
}

test "normal binary64 narrowing agrees with a significand-based reference" {
    // The 29 discarded bits straddle halfway; extreme fractions also exercise exponent carry.
    const fractions = [_]u64{ 0, 1, 0x7f_fffe, 0x7f_ffff };
    const tails = [_]u64{ 0, 0x0fff_ffff, 0x1000_0000, 0x1000_0001, 0x1fff_ffff };
    for (897..1151) |exponent| for (fractions) |fraction| for (tails) |tail| {
        for ([_]u64{ 0, 0x8000_0000_0000_0000 }) |sign| {
            var bits = sign | (@as(u64, @intCast(exponent)) << 52) | (fraction << 29) | tail;
            // A runtime input keeps the reference check from reducing to a compile-time cast.
            std.mem.doNotOptimizeAway(&bits);
            const significand = (bits & 0x000f_ffff_ffff_ffff) | 0x0010_0000_0000_0000;
            var rounded = significand >> 29;
            const remainder = significand & 0x1fff_ffff;
            if (remainder > 0x1000_0000 or (remainder == 0x1000_0000 and rounded & 1 != 0)) {
                rounded += 1;
            }
            var result_exponent: u32 = @intCast(exponent - 896);
            if (rounded == 0x0100_0000) {
                rounded >>= 1;
                result_exponent += 1;
            }
            const result_sign: u32 = @truncate(sign >> 32);
            const expected = result_sign | (result_exponent << 23) | @as(
                u32,
                @intCast(rounded & 0x007f_ffff),
            );
            const value: f64 = @bitCast(bits);
            try std.testing.expectEqual(expected, @as(u32, @bitCast(narrow32(value))));
        }
    };
}

/// Thread-local floating-point controls for internal contract tests.
pub const test_support = struct {
    /// Current-thread floating-point controls used by x86-64 contract tests.
    pub const FloatControl = struct {
        /// MXCSR FTZ/DAZ bits without exception or rounding changes.
        pub const flushing_mask: u32 = (1 << 15) | (1 << 6);

        /// Reads the complete word or skips a mode-specific test on other architectures.
        pub fn read() error{SkipZigTest}!u32 {
            if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
            var control: u32 = undefined;
            asm volatile ("stmxcsr (%%rax)"
                :
                : [control] "{rax}" (@intFromPtr(&control)),
                : .{ .memory = true });
            return control;
        }

        /// Installs a derived or saved word; unsupported architectures do nothing. Preserve
        /// reserved bits and exception masks; restore the complete original word.
        pub fn set(control: u32) void {
            if (builtin.cpu.arch != .x86_64) return;
            asm volatile ("ldmxcsr (%%rax)"
                :
                : [control] "{rax}" (@intFromPtr(&control)),
                : .{ .memory = true, .mxcsr = true });
        }
    };
};
