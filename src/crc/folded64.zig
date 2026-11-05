//! Polynomial folding for CRC-64/XZ. Constants are derived from the normal generator polynomial.
//! Reflected Barrett reduction follows the XZ CRC design by Lasse Collin and Ilya Kurdyukov. Fold
//! powers and reciprocal below are calculated by polynomial arithmetic rather than imported. Design
//! reference:
//! https://github.com/tukaani-project/xz/blob/a6711d1c4ad681aad985372d01a7deb21b4a1b8b/src/liblzma/check/crc_x86_clmul.h
const std = @import("std");
const builtin = @import("builtin");
const Vector = @Vector(2, u64);
const normal: u128 = (@as(u128, 1) << 64) | 0x42f0e1eba9ea3693;
const reflected: u64 = 0xc96c5795d7870f42;
const x86 = switch (builtin.cpu.arch) {
    .x86, .x86_64 => builtin.cpu.hasAll(.x86, &.{ .sse2, .pclmul }),
    else => false,
};
const arm = builtin.cpu.arch == .aarch64 and builtin.cpu.hasAll(.aarch64, &.{ .aes, .neon });
pub const available = builtin.zig_backend == .stage2_llvm and (x86 or arm);

fn power(comptime exponent: usize) u64 {
    @setEvalBranchQuota(10000);
    var remainder: u128 = 1;
    for (0..exponent) |_| {
        remainder <<= 1;
        if (remainder >> 64 != 0) remainder ^= normal;
    }
    return @bitReverse(@as(u64, @intCast(remainder)));
}

fn reciprocal() u64 {
    var numerator: u128 = @as(u128, 1) << 127;
    var quotient: u64 = 0;
    for (0..64) |index| {
        const shift: u6 = @intCast(63 - index);
        if (numerator & (@as(u128, 1) << (64 + @as(u7, shift))) != 0) {
            numerator ^= normal << shift;
            quotient ^= @as(u64, 1) << shift;
        }
    }
    return @bitReverse(quotient);
}

inline fn multiply(left: Vector, right: Vector, comptime selector: u8) Vector {
    if (arm) {
        const second = if (selector == 0x10) @as(Vector, .{ right[1], 0 }) else right;
        return asm (if (selector == 0x11)
                "pmull2 %[out].1q, %[a].2d, %[b].2d"
            else
                "pmull %[out].1q, %[a].1d, %[b].1d"
            : [out] "=w" (-> Vector),
            : [a] "w" (left),
              [b] "w" (second),
        );
    }
    return asm (std.fmt.comptimePrint("pclmulqdq ${d}, %[b], %[out]", .{selector})
        : [out] "=x" (-> Vector),
        : [a] "0" (left),
          [b] "x" (right),
    );
}

fn load(bytes: *const [16]u8) Vector {
    return @bitCast(@as(@Vector(16, u8), bytes.*));
}

inline fn fold(current: Vector, next: Vector, comptime span: usize) Vector {
    const factors: Vector = .{ comptime power(span * 8 + 63), comptime power(span * 8 - 1) };
    return next ^ multiply(current, factors, 0x00) ^ multiply(current, factors, 0x11);
}

/// Appends at least sixteen exact bytes to a raw reflected remainder. Eight independent chains hide
/// carryless-multiply latency for bulk input. Scalar tails stay within the supplied slice.
pub fn update(initial: u64, bytes: []const u8) u64 {
    @setEvalBranchQuota(100000);
    var value = load(bytes[0..16]) ^ @as(Vector, .{ initial, 0 });
    var offset: usize = 16;
    if (bytes.len >= 128) {
        var lanes: [8]Vector = undefined;
        lanes[0] = value;
        inline for (1..8) |lane| lanes[lane] = load(bytes[lane * 16 ..][0..16]);
        offset = 128;
        while (bytes.len - offset >= 128) : (offset += 128) {
            inline for (
                0..8,
            ) |lane| lanes[lane] = fold(
                lanes[lane],
                load(bytes[offset + lane * 16 ..][0..16]),
                128,
            );
        }
        inline for (0..4) |lane| lanes[lane] = fold(lanes[lane], lanes[lane + 4], 64);
        inline for (0..2) |lane| lanes[lane] = fold(lanes[lane], lanes[lane + 2], 32);
        value = fold(lanes[0], lanes[1], 16);
    }
    while (bytes.len - offset >= 16) : (offset += 16) value = fold(
        value,
        load(bytes[offset..][0..16]),
        16,
    );
    const factors: Vector = .{ 0, comptime power(127) };
    value = multiply(value, factors, 0x10) ^ @as(Vector, .{ value[1], 0 });
    // The reflected degree-64 generator has one implicit high bit. The second product therefore
    // needs both its explicit low polynomial and the omitted x^64 contribution.
    const reduction: Vector = .{ reflected << 1, comptime reciprocal() };
    const quotient = multiply(value, reduction, 0x10);
    const product = multiply(quotient, reduction, 0x00);
    var remainder = (value ^ @as(Vector, .{ 0, quotient[0] }) ^ product)[1];
    for (bytes[offset..]) |byte| {
        remainder ^= byte;
        for (0..8) |_| {
            const carry = remainder & 1 != 0;
            remainder >>= 1;
            if (carry) remainder ^= reflected;
        }
    }
    return remainder;
}
