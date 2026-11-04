//! Shared XXH3 hashing, options and secret handling for 64-bit and 128-bit results. The original
//! design is by Yann Collet and the xxHash contributors; upstream credits FARSH for the default
//! secret. Algorithm reference: https://github.com/Cyan4973/xxHash/tree/c87183a

const std = @import("std");
const small = @import("xxh3_small.zig");
const long = @import("xxh3_long.zig");
pub const State = @import("xxh3_stream.zig").State;

/// Selects a 64-bit seed or a caller-provided XXH3 secret. Combined seed and secret is not a mode.
pub const Xxh3Options = struct {
    /// Default seed zero, another seed, or a secret of at least 136 bytes.
    mode: union(enum) { seed: u64, secret: []const u8 } = .{ .seed = 0 },
};

/// Smallest custom secret accepted by the stable XXH3 interface.
pub const min_secret_size = 136;

pub fn hash64(input: []const u8, seed: u64, secret: ?[]const u8) u64 {
    const options: SecretMode = if (secret) |key| .{ .secret = key } else .{ .seed = seed };
    return @truncate(hash(64, input, options));
}

pub fn hash128(input: []const u8, seed: u64, secret: ?[]const u8) u128 {
    const options: SecretMode = if (secret) |key| .{ .secret = key } else .{ .seed = seed };
    return hash(128, input, options);
}

pub const SecretMode = union(enum) { seed: u64, secret: []const u8 };

// For long seeded inputs XXH3 requires a derived copy; byte order remains fixed on every target.
pub fn deriveSeededSecret(seed: u64) [192]u8 {
    var derived: [192]u8 = undefined;
    for (0..12) |pair| {
        const offset = pair * 16;
        const first = std.mem.readInt(u64, default_secret[offset..][0..8], .little);
        const second = std.mem.readInt(u64, default_secret[offset + 8 ..][0..8], .little);
        std.mem.writeInt(u64, derived[offset..][0..8], first +% seed, .little);
        std.mem.writeInt(u64, derived[offset + 8 ..][0..8], second -% seed, .little);
    }
    return derived;
}

test "seeded secret adds and subtracts the seed in alternating words" {
    try std.testing.expectEqual(default_secret, deriveSeededSecret(0));
    const derived = deriveSeededSecret(1);
    try std.testing.expectEqual(0xbe4ba423396cfeb9, std.mem.readInt(u64, derived[0..8], .little));
    try std.testing.expectEqual(0x1cad21f72c81017b, std.mem.readInt(u64, derived[8..16], .little));
    try std.testing.expectEqual(
        0x280416958f3acb46,
        std.mem.readInt(u64, derived[176..184], .little),
    );
    try std.testing.expectEqual(
        0x7e404bbbcafbd7ae,
        std.mem.readInt(u64, derived[184..192], .little),
    );
}

pub fn hashUpTo240(
    comptime result_bits: u8,
    input: []const u8,
    seed: u64,
    borrowed_secret: ?[]const u8,
) u128 {
    if (result_bits != 64 and result_bits != 128) @compileError(
        "XXH3 result width must be 64 or 128",
    );
    std.debug.assert(input.len <= 240);
    const secret = borrowed_secret orelse &default_secret;
    if (input.len <= 16) {
        if (result_bits == 128) return small.hash128(input, secret[0..96], seed);
        return small.hash64(input, secret[0..96], seed);
    }
    const result = small.hash(result_bits, input, secret, seed);
    return (@as(u128, result.high) << 64) | result.low;
}

pub fn hash(comptime result_bits: u8, input: []const u8, options: SecretMode) u128 {
    if (result_bits != 64 and result_bits != 128) @compileError(
        "XXH3 result width must be 64 or 128",
    );
    const seed: u64 = switch (options) {
        .seed => |value| value,
        .secret => 0,
    };
    const borrowed_secret: ?[]const u8 = switch (options) {
        .seed => null,
        .secret => |value| value,
    };
    const secret = borrowed_secret orelse &default_secret;
    std.debug.assert(secret.len >= 136);
    if (input.len <= 16) {
        if (result_bits == 128) return small.hash128(input, secret[0..96], seed);
        return small.hash64(input, secret[0..96], seed);
    }
    if (input.len <= 240) {
        if (result_bits == 64) {
            if (borrowed_secret) |key| return hashMediumSecret64(input, key);
        }
        return hashUpTo240(result_bits, input, seed, borrowed_secret);
    }
    // The 64-bit caller benefits from inlining; keep 128-bit short calls free of long-path storage.
    return if (result_bits == 64) @call(.always_inline, hashLong, .{
        result_bits, input, options,
    }) else @call(.never_inline, hashLong, .{ result_bits, input, options });
}

// For seeded long-medium inputs the default secret is known at compile time.
pub noinline fn hashSeededLongMedium64(input: []const u8, seed: u64) u64 {
    std.debug.assert(input.len >= 161 and input.len <= 240);
    const result = @call(.always_inline, small.hash, .{ 64, input, &default_secret, seed });
    return result.low;
}

fn hashMediumSecret64(input: []const u8, secret: []const u8) u64 {
    const result = @call(.always_inline, small.hash, .{ 64, input, secret, 0 });
    return result.low;
}

fn hashLong(comptime result_bits: u8, input: []const u8, options: SecretMode) u128 {
    var derived: [192]u8 = undefined;
    const long_secret: []const u8 = switch (options) {
        .secret => |value| value,
        .seed => |seed| if (seed == 0) &default_secret else seeded: {
            derived = deriveSeededSecret(seed);
            break :seeded &derived;
        },
    };
    const result = long.hash(result_bits, input, long_secret);
    return (@as(u128, result.high) << 64) | result.low;
}

pub const default_secret = [_]u8{
    0xb8, 0xfe, 0x6c, 0x39, 0x23, 0xa4, 0x4b, 0xbe, 0x7c, 0x01, 0x81, 0x2c, 0xf7, 0x21, 0xad, 0x1c,
    0xde, 0xd4, 0x6d, 0xe9, 0x83, 0x90, 0x97, 0xdb, 0x72, 0x40, 0xa4, 0xa4, 0xb7, 0xb3, 0x67, 0x1f,
    0xcb, 0x79, 0xe6, 0x4e, 0xcc, 0xc0, 0xe5, 0x78, 0x82, 0x5a, 0xd0, 0x7d, 0xcc, 0xff, 0x72, 0x21,
    0xb8, 0x08, 0x46, 0x74, 0xf7, 0x43, 0x24, 0x8e, 0xe0, 0x35, 0x90, 0xe6, 0x81, 0x3a, 0x26, 0x4c,
    0x3c, 0x28, 0x52, 0xbb, 0x91, 0xc3, 0x00, 0xcb, 0x88, 0xd0, 0x65, 0x8b, 0x1b, 0x53, 0x2e, 0xa3,
    0x71, 0x64, 0x48, 0x97, 0xa2, 0x0d, 0xf9, 0x4e, 0x38, 0x19, 0xef, 0x46, 0xa9, 0xde, 0xac, 0xd8,
    0xa8, 0xfa, 0x76, 0x3f, 0xe3, 0x9c, 0x34, 0x3f, 0xf9, 0xdc, 0xbb, 0xc7, 0xc7, 0x0b, 0x4f, 0x1d,
    0x8a, 0x51, 0xe0, 0x4b, 0xcd, 0xb4, 0x59, 0x31, 0xc8, 0x9f, 0x7e, 0xc9, 0xd9, 0x78, 0x73, 0x64,
    0xea, 0xc5, 0xac, 0x83, 0x34, 0xd3, 0xeb, 0xc3, 0xc5, 0x81, 0xa0, 0xff, 0xfa, 0x13, 0x63, 0xeb,
    0x17, 0x0d, 0xdd, 0x51, 0xb7, 0xf0, 0xda, 0x49, 0xd3, 0x16, 0x55, 0x26, 0x29, 0xd4, 0x68, 0x9e,
    0x2b, 0x16, 0xbe, 0x58, 0x7d, 0x47, 0xa1, 0xfc, 0x8f, 0xf8, 0xb8, 0xd1, 0x7a, 0xd0, 0x31, 0xce,
    0x45, 0xcb, 0x3a, 0x8f, 0x95, 0x16, 0x04, 0x28, 0xaf, 0xd7, 0xfb, 0xca, 0xbb, 0x4b, 0x40, 0x7e,
};

test {
    _ = State;
    _ = small;
    _ = long;
}
