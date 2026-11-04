//! Computes noncryptographic XXH3-64 hashes from exact byte slices. `hash` uses seed zero;
//! `hashSeeded` accepts any 64-bit seed. Custom secrets use the shared `Xxh3Options` type.
//!
//! Streaming states allocate nothing. `final` returns a snapshot and independent copies can
//! continue separately. A custom secret is borrowed and must remain immutable, alive and disjoint
//! from every mutable state copy until that copy is reinitialized or no longer used. Input passed
//! to `update` must not overlap the mutable state. Numeric results are host-order integers; use
//! big-endian bytes for xxHash's canonical representation.
//!
//! Algorithm reference: https://github.com/Cyan4973/xxHash/blob/v0.8.4/xxhash.h

const Xxh3_64 = @This();

/// Internal state; initialize and modify it only through this type's functions.
state: core.State,

const core = @import("xxh3.zig");
const overlaps = @import("../common/byte_ranges.zig").overlaps;
const Xxh3Options = core.Xxh3Options;
const std = @import("std");
const testing = std.testing;

/// Starts or restarts a stream with any 64-bit seed in caller-owned storage, which may be
/// undefined. A previous custom-secret borrow ends when this call succeeds.
pub fn init(self: *Xxh3_64, seed: u64) void {
    self.state.reset(seed);
}

/// Starts a stream using a seed or a borrowed custom secret. Secrets must contain at least 136
/// bytes and must not overlap this state. A failed initialization leaves the entire state
/// unchanged, including when its storage was undefined. A failed call preserves any previous secret
/// borrow. A borrowed secret must remain immutable, alive and disjoint from all mutable state
/// copies until each copy is successfully reinitialized or no longer used.
pub fn initWithOptions(
    self: *Xxh3_64,
    options: Xxh3Options,
) error{ InvalidSecret, StorageOverlap }!void {
    switch (options.mode) {
        .seed => |seed| self.init(seed),
        .secret => |secret| {
            if (secret.len < core.min_secret_size) return error.InvalidSecret;
            if (overlaps(secret, std.mem.asBytes(self))) return error.StorageOverlap;
            self.state.resetSecret(secret);
        },
    }
}

test initWithOptions {
    const secret: [137]u8 = @splat(0xa5);
    var state: Xxh3_64 = undefined;
    state.init(0);
    try state.initWithOptions(.{ .mode = .{ .secret = &secret } });
    state.update("abc");
    // Independent XXH3-64 result from xxHash v0.8.4.
    try testing.expectEqual(@as(u64, 0xfd6e986c28fac4d3), state.final());
}

/// Appends bytes without retaining them. Input must not overlap this mutable state. The total
/// length wraps modulo 2^64 and the digest follows the reference's wrapped-length behavior.
pub fn update(self: *Xxh3_64, input: []const u8) void {
    self.state.update(input);
}

test update {
    var state: Xxh3_64 = undefined;
    state.init(1);
    state.update("a");
    const prefix = state.final();
    var copy = state;
    state.update("bc");
    copy.update("bc");
    try testing.expectEqual(hashSeeded(1, "a"), prefix);
    try testing.expectEqual(@as(u64, 0x6b4467b443c76228), state.final());
    try testing.expectEqual(state.final(), copy.final());
}

/// Returns the current digest without resetting or consuming the state.
pub fn final(self: *const Xxh3_64) u64 {
    return self.state.final64();
}

/// Hashes an exact byte slice using seed zero.
pub fn hash(bytes: []const u8) u64 {
    return core.hash64(bytes, 0, null);
}

/// Hashes an exact byte slice with a 64-bit seed.
pub fn hashSeeded(seed: u64, bytes: []const u8) u64 {
    if (bytes.len >= 161 and bytes.len <= 240) {
        return core.hashSeededLongMedium64(bytes, seed);
    }
    return core.hash64(bytes, seed, null);
}

test hashSeeded {
    // Independent values from xxHash v0.8.4.
    try testing.expectEqual(@as(u64, 0x78af5f94892f3950), hash("abc"));
    try testing.expectEqual(@as(u64, 0x6b4467b443c76228), hashSeeded(1, "abc"));
}

/// Hashes an exact byte slice with a seed or a secret of at least 136 bytes. The secret and input
/// are borrowed only for this call; they may overlap each other.
pub fn hashWithOptions(options: Xxh3Options, bytes: []const u8) error{InvalidSecret}!u64 {
    switch (options.mode) {
        .seed => |seed| return hashSeeded(seed, bytes),
        .secret => |secret| {
            if (secret.len < core.min_secret_size) return error.InvalidSecret;
            return core.hash64(bytes, 0, secret);
        },
    }
}

test "seeded long-medium boundaries match xxHash v0.8.4" {
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index * 53 + 7);
    const cases = [_]struct {
        len: usize,
        digest: u64,
    }{
        .{ .len = 128, .digest = 0x19a845799509077f },
        .{ .len = 129, .digest = 0x1077bedbd97a0393 },
        .{ .len = 143, .digest = 0x1be07e2f7ff2b5fd },
        .{ .len = 144, .digest = 0x53b6fab8a3a9eca2 },
        .{ .len = 159, .digest = 0xfc4f8b19a9b20e41 },
        .{ .len = 160, .digest = 0xf1bb0982e4c60ef1 },
        .{ .len = 161, .digest = 0x3ef0208e976488e1 },
        .{ .len = 162, .digest = 0x56dffa9f4a9ca88c },
        .{ .len = 191, .digest = 0x2741da4ac9bb5f47 },
        .{ .len = 192, .digest = 0x4b151ec64af8abd0 },
        .{ .len = 223, .digest = 0x19eeb57d3550ce23 },
        .{ .len = 224, .digest = 0x803c1c0545228a9c },
        .{ .len = 239, .digest = 0xa4c3555280546d1c },
        .{ .len = 240, .digest = 0x1417be7a7db2430c },
        .{ .len = 241, .digest = 0x795290bfcafe284b },
    };
    for (cases) |case| {
        try testing.expectEqual(case.digest, hashSeeded(0xfedcba9876543210, bytes[0..case.len]));
    }
}

test "failed option initialization preserves the state" {
    var state: Xxh3_64 = undefined;
    state.init(1);
    state.update("prefix");
    const before = state.final();
    const too_short: [135]u8 = @splat(0);
    try testing.expectError(
        error.InvalidSecret,
        state.initWithOptions(.{ .mode = .{ .secret = &too_short } }),
    );
    try testing.expectEqual(before, state.final());
    const self_bytes = std.mem.asBytes(&state);
    try testing.expectError(
        error.StorageOverlap,
        state.initWithOptions(.{ .mode = .{ .secret = self_bytes[0..136] } }),
    );
    try testing.expectEqual(before, state.final());
    var uninitialized: Xxh3_64 = undefined;
    try testing.expectError(
        error.InvalidSecret,
        uninitialized.initWithOptions(.{ .mode = .{ .secret = &too_short } }),
    );
    uninitialized.init(1);
    uninitialized.update("abc");
    try testing.expectEqual(@as(u64, 0x6b4467b443c76228), uninitialized.final());
}

test "failed initialization preserves borrowed state and successful initialization releases it" {
    var secret: [137]u8 = @splat(0xa5);
    const options: Xxh3Options = .{ .mode = .{ .secret = &secret } };
    var state: Xxh3_64 = undefined;
    @memset(std.mem.asBytes(&state), 0xa5);
    try state.initWithOptions(options);
    state.update("prefix");
    var copy = state;
    const before = std.mem.asBytes(&state).*;
    try testing.expectError(
        error.InvalidSecret,
        state.initWithOptions(.{ .mode = .{ .secret = secret[0..135] } }),
    );
    try testing.expectEqualSlices(u8, &before, std.mem.asBytes(&state));
    state.update("suffix");
    copy.update("suffix");
    try testing.expectEqual(try hashWithOptions(options, "prefixsuffix"), state.final());
    try testing.expectEqual(state.final(), copy.final());
    state.init(1);
    copy.init(1);
    @memset(&secret, 0);
    state.update("abc");
    try testing.expectEqual(hashSeeded(1, "abc"), state.final());
}

test "upstream vectors and streaming boundaries" {
    // Expected digests: xxHash v0.8.4 (c87183a77d67), scalar reference, deterministic inputs.
    var bytes: [4096]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i * 131 + (i >> 3) * 17 + 19);
    var secret: [200]u8 = undefined;
    for (&secret, 0..) |*byte, i| byte.* = @truncate(i * 71 + 13);
    const cases = [_]struct {
        len: usize,
        seed: u64,
        secret_len: usize,
        digest: u64,
    }{
        .{ .len = 0, .seed = 0x0, .secret_len = 0, .digest = 0x2d06800538d394c2 },
        .{ .len = 16, .seed = 0x1, .secret_len = 0, .digest = 0xfb50452bad8e0a67 },
        .{ .len = 17, .seed = 0x8000000000000000, .secret_len = 0, .digest = 0x45d3427fcb78641b },
        .{ .len = 16, .seed = 0x0, .secret_len = 137, .digest = 0xd5d3fc7cd4df2e96 },
        .{ .len = 17, .seed = 0x0, .secret_len = 137, .digest = 0x4a1eabd8f99d7217 },
        .{ .len = 32, .seed = 0x0, .secret_len = 137, .digest = 0xb97156ae52d57af3 },
        .{ .len = 33, .seed = 0x0, .secret_len = 137, .digest = 0x26944dc55aa041b4 },
        .{ .len = 63, .seed = 0x0, .secret_len = 137, .digest = 0x9ef840fa952b8037 },
        .{ .len = 64, .seed = 0x0, .secret_len = 137, .digest = 0x82b606e83b113aa2 },
        .{ .len = 65, .seed = 0x0, .secret_len = 137, .digest = 0x5d31f0a77397cb08 },
        .{ .len = 95, .seed = 0x0, .secret_len = 137, .digest = 0xe1e0555ecf789cde },
        .{ .len = 96, .seed = 0x0, .secret_len = 137, .digest = 0xc960b1061300b192 },
        .{ .len = 97, .seed = 0x0, .secret_len = 137, .digest = 0x37e9dc28ec7ee181 },
        .{ .len = 127, .seed = 0x0, .secret_len = 136, .digest = 0x52f7b2c93ad17b19 },
        .{ .len = 128, .seed = 0x0, .secret_len = 200, .digest = 0x7d1e03ed5a09a823 },
        .{ .len = 129, .seed = 0x0, .secret_len = 137, .digest = 0xd3d3c8d6765b0401 },
        .{ .len = 240, .seed = 0x0, .secret_len = 192, .digest = 0x6dbe567d19b9d190 },
        .{ .len = 241, .seed = 0x0, .secret_len = 137, .digest = 0x9001792d67c8af44 },
        .{ .len = 241, .seed = 0x1, .secret_len = 0, .digest = 0x7c31b142d380250 },
        .{ .len = 256, .seed = 0x0, .secret_len = 136, .digest = 0x47a2ba6d75ab19d9 },
        .{ .len = 257, .seed = 0x0, .secret_len = 200, .digest = 0xd8f835e9f5cfdff },
        .{ .len = 576, .seed = 0x0, .secret_len = 136, .digest = 0x42d0ac1a6c4f29c },
        .{ .len = 1088, .seed = 0x0, .secret_len = 192, .digest = 0xec339e5c1e8f73d5 },
        .{ .len = 4096, .seed = 0xffffffffffffffff, .secret_len = 0, .digest = 0xec3056b241d36c45 },
    };
    const fragments = [_]usize{ 1, 63, 64, 65, 239, 240, 241, 255, 256, 257 };
    for (cases) |case| {
        const options: Xxh3Options = if (case.secret_len == 0) .{
            .mode = .{ .seed = case.seed },
        } else .{ .mode = .{ .secret = secret[0..case.secret_len] } };
        try testing.expectEqual(case.digest, try hashWithOptions(options, bytes[0..case.len]));
        for (fragments) |fragment| {
            var state: Xxh3_64 = undefined;
            try state.initWithOptions(options);
            var pos: usize = 0;
            while (pos < case.len) {
                const count = @min(fragment, case.len - pos);
                state.update(bytes[pos..][0..count]);
                pos += count;
            }
            try testing.expectEqual(case.digest, state.final());
            try testing.expectEqual(case.digest, state.final());
        }
    }
}

test "overlap admission leaves caller storage untouched" {
    var state: Xxh3_64 = undefined;
    @memset(std.mem.asBytes(&state), 0xa5);
    const before = std.mem.asBytes(&state).*;
    const raw = std.mem.asBytes(&state);
    try testing.expectError(
        error.InvalidSecret,
        state.initWithOptions(.{ .mode = .{ .secret = raw[0..135] } }),
    );
    try testing.expectEqualSlices(u8, &before, raw);
    try testing.expectError(
        error.StorageOverlap,
        state.initWithOptions(.{ .mode = .{ .secret = raw[0..136] } }),
    );
    try testing.expectEqualSlices(u8, &before, raw);
}

test "all short residual stripes and relocated copies" {
    var bytes: [1024]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i * 53 + 7);
    var secret: [202]u8 = undefined;
    for (&secret, 0..) |*byte, i| byte.* = @truncate(i * 71 + 13);
    const options: Xxh3Options = .{ .mode = .{ .secret = secret[1..201] } };
    for (1..64) |residual| {
        const end = 512 + residual;
        var state: Xxh3_64 = undefined;
        state.init(0xfedcba9876543210);
        state.update(bytes[0..end]);
        var moved = state;
        state.init(0);
        moved.update(bytes[end..]);
        try testing.expectEqual(hashSeeded(0xfedcba9876543210, &bytes), moved.final());
        try state.initWithOptions(options);
        state.update(bytes[0..end]);
        moved = state;
        state.init(0);
        moved.update(bytes[end..]);
        try testing.expectEqual(try hashWithOptions(options, &bytes), moved.final());
    }
}

test "64-byte updates preserve mixed-boundary snapshots" {
    // Independent XXH3-64 values from xxHash v0.8.4 for the inputs below.
    var bytes: [384]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i * 53 + 7);
    const secret: [137]u8 = @splat(0xa5);
    const cases = [_]struct {
        prefix: usize,
        seeded: [2]u64,
        secret: [2]u64,
    }{ .{ .prefix = 192, .seeded = .{
        0xe171c4058af35077, 0x91c39ffece9a3644,
    }, .secret = .{
        0x7557cb38d1c4decd, 0xcc599c907b6b63cf,
    } }, .{ .prefix = 193, .seeded = .{
        0x95204103d0e4fc0b, 0x8b32b8265caa0e41,
    }, .secret = .{
        0xfabef7a337d71faf, 0x9cd8d74a6e5eda3f,
    } }, .{ .prefix = 255, .seeded = .{
        0xa4adb43f78afc847, 0xc62e64a8cb0f27b8,
    }, .secret = .{
        0xe263db7d86655821, 0x247f046280cfa93b,
    } }, .{ .prefix = 256, .seeded = .{
        0x91c39ffece9a3644, 0xd17a63171dcc88d6,
    }, .secret = .{
        0xcc599c907b6b63cf, 0x21eee0af3b3595c9,
    } } };
    for (cases) |case| {
        inline for (.{ false, true }) |custom| {
            var state: Xxh3_64 = undefined;
            state.init(1);
            if (custom) try state.initWithOptions(.{ .mode = .{ .secret = &secret } });
            const expected = if (custom) case.secret else case.seeded;
            state.update(bytes[0..case.prefix]);
            state.update(bytes[case.prefix..][0..64]);
            try testing.expectEqual(expected[0], state.final());
            state.update(&.{});
            try testing.expectEqual(expected[0], state.final());
            state.update(bytes[case.prefix + 64 ..][0..64]);
            try testing.expectEqual(expected[1], state.final());
        }
    }
}
