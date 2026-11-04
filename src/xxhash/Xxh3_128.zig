//! Computes noncryptographic XXH3-128 hashes from exact byte slices. `hash` uses seed zero;
//! `hashSeeded` accepts any 64-bit seed. Custom secrets use the shared `Xxh3Options` type.
//!
//! Streaming states allocate nothing. `final` returns a snapshot and independent copies can
//! continue separately. A custom secret is borrowed and must remain immutable, alive and disjoint
//! from every mutable state copy until that copy is reinitialized or no longer used. Input passed
//! to `update` must not overlap the mutable state. Numeric results are host-order integers; use
//! big-endian bytes for xxHash's canonical representation.
//!
//! Algorithm reference: https://github.com/Cyan4973/xxHash/blob/v0.8.4/xxhash.h

const Xxh3_128 = @This();

/// Internal state; initialize and modify it only through this type's functions.
state: core.State,

const core = @import("xxh3.zig");
const small = @import("xxh3_small.zig");
const overlaps = @import("../common/byte_ranges.zig").overlaps;
const Xxh3Options = core.Xxh3Options;
const std = @import("std");
const testing = std.testing;

/// Starts or restarts a stream with any 64-bit seed in caller-owned storage, which may be
/// undefined. A previous custom-secret borrow ends when this call succeeds.
pub fn init(self: *Xxh3_128, seed: u64) void {
    self.state.reset(seed);
}

/// Starts a stream using a seed or a borrowed custom secret. Secrets must contain at least 136
/// bytes and must not overlap this state. A failed initialization leaves the entire state
/// unchanged, including when its storage was undefined. A failed call preserves any previous secret
/// borrow. A borrowed secret must remain immutable, alive and disjoint from all mutable state
/// copies until each copy is successfully reinitialized or no longer used.
pub fn initWithOptions(
    self: *Xxh3_128,
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
    var state: Xxh3_128 = undefined;
    state.init(0);
    try state.initWithOptions(.{ .mode = .{ .secret = &secret } });
    state.update("abc");
    // Independent XXH3-128 result from xxHash v0.8.4.
    try testing.expectEqual(@as(u128, 0x42d23058767a303ffd6e986c28fac4d3), state.final());
}

/// Appends bytes without retaining them. Input must not overlap this mutable state. The total
/// length wraps modulo 2^64 and the digest follows the reference's wrapped-length behavior.
pub fn update(self: *Xxh3_128, input: []const u8) void {
    self.state.update(input);
}

test update {
    var state: Xxh3_128 = undefined;
    state.init(1);
    state.update("a");
    const prefix = state.final();
    var copy = state;
    state.update("bc");
    copy.update("bc");
    try testing.expectEqual(hashSeeded(1, "a"), prefix);
    try testing.expectEqual(@as(u128, 0x7577b06fae9ee3ed6b4467b443c76228), state.final());
    try testing.expectEqual(state.final(), copy.final());
}

/// Returns the current digest without resetting or consuming the state.
pub fn final(self: *const Xxh3_128) u128 {
    return self.state.final128();
}

/// Hashes an exact byte slice using seed zero.
pub fn hash(bytes: []const u8) u128 {
    return core.hash128(bytes, 0, null);
}

test hash {
    // The upstream canonical representation writes the numeric result in big-endian order.
    var canonical: [16]u8 = undefined;
    std.mem.writeInt(u128, &canonical, hash("abc"), .big);
    const expected = [16]u8{
        0x06, 0xb0, 0x5a, 0xb6, 0x73, 0x3a, 0x61, 0x85,
        0x78, 0xaf, 0x5f, 0x94, 0x89, 0x2f, 0x39, 0x50,
    };
    try testing.expectEqualSlices(u8, &expected, &canonical);
}

/// Hashes an exact byte slice with a 64-bit seed.
pub fn hashSeeded(seed: u64, bytes: []const u8) u128 {
    return core.hash128(bytes, seed, null);
}

test hashSeeded {
    // Independent values from xxHash v0.8.4.
    try testing.expectEqual(@as(u128, 0x6b05ab6733a618578af5f94892f3950), hash("abc"));
    try testing.expectEqual(@as(u128, 0x7577b06fae9ee3ed6b4467b443c76228), hashSeeded(1, "abc"));
}

/// Hashes an exact byte slice with a seed or a secret of at least 136 bytes. The secret and input
/// are borrowed only for this call; they may overlap each other.
pub fn hashWithOptions(options: Xxh3Options, bytes: []const u8) error{InvalidSecret}!u128 {
    switch (options.mode) {
        .seed => |seed| return hashSeeded(seed, bytes),
        .secret => |secret| {
            if (secret.len < core.min_secret_size) return error.InvalidSecret;
            if (bytes.len <= 16) return small.hash128(bytes, secret[0..96], 0);
            if (bytes.len >= 97 and bytes.len <= 128) {
                return small.hashSecret97To128(bytes, secret);
            }
            return core.hash128(bytes, 0, secret);
        },
    }
}

test "custom-secret medium boundaries support overlapping input" {
    // Independent results from xxHash v0.8.4 with a 137-byte overlapping secret.
    var bytes: [240]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index * 71 + 13);
    const options: Xxh3Options = .{ .mode = .{ .secret = bytes[0..137] } };
    const cases = [_]struct {
        len: usize,
        digest: u128,
    }{
        .{ .len = 0, .digest = 0x727fc9ec235130efbe9fa3050315264a },
        .{ .len = 1, .digest = 0xe04486fc98ecf703767667e909e84863 },
        .{ .len = 3, .digest = 0x30183c42435fe645ae9a2ace0b056d8a },
        .{ .len = 4, .digest = 0x93c6d9f7182264b59fe7879c8cbc48c6 },
        .{ .len = 8, .digest = 0xb8d05a274903c964404f7a976f55547a },
        .{ .len = 9, .digest = 0x43ee98f12641d421e7b14353a77a9831 },
        .{ .len = 16, .digest = 0x90633ff7b67ad40a894c71f26463c0af },
        .{ .len = 17, .digest = 0x96012c51b26558c98ca78781b1631d45 },
        .{ .len = 96, .digest = 0x8df65060bf831000f6a20047e3539aff },
        .{ .len = 97, .digest = 0x5b7d2a3b2024c54fcffcc6d5b370e04f },
        .{ .len = 111, .digest = 0x39bfbcd26f8e0aeb28a46f4dcd22cdfa },
        .{ .len = 112, .digest = 0x3ad7b3d16e2ab975b1b451e5bff76570 },
        .{ .len = 127, .digest = 0xdb54840219314cb617d3df8141600f58 },
        .{ .len = 128, .digest = 0x4242c07439a4413abe72de99d896c8aa },
        .{ .len = 129, .digest = 0xd00374632dbf0873ce71d2ee64fd615c },
    };
    for (cases) |case| {
        try testing.expectEqual(case.digest, try hashWithOptions(options, bytes[0..case.len]));
    }
}

test "failed option initialization preserves the state" {
    var state: Xxh3_128 = undefined;
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
    var uninitialized: Xxh3_128 = undefined;
    try testing.expectError(
        error.InvalidSecret,
        uninitialized.initWithOptions(.{ .mode = .{ .secret = &too_short } }),
    );
    uninitialized.init(1);
    uninitialized.update("abc");
    try testing.expectEqual(@as(u128, 0x7577b06fae9ee3ed6b4467b443c76228), uninitialized.final());
}

test "failed initialization preserves borrowed state and successful initialization releases it" {
    var secret: [137]u8 = @splat(0xa5);
    const options: Xxh3Options = .{ .mode = .{ .secret = &secret } };
    var state: Xxh3_128 = undefined;
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
        digest: u128,
    }{
        .{ .len = 0, .seed = 0x0, .secret_len = 0, .digest = 0x99aa06d3014798d86001c324468d497f },
        .{ .len = 16, .seed = 0x1, .secret_len = 0, .digest = 0x456885705cea2be05e7260753bae8f0e },
        .{
            .len = 17,
            .seed = 0x8000000000000000,
            .secret_len = 0,
            .digest = 0x28330a038eb4737b17aa0edf5f18bd00,
        },
        .{
            .len = 127,
            .seed = 0x0,
            .secret_len = 136,
            .digest = 0xe2d67515cde4c76c9cda96ef16db4758,
        },
        .{
            .len = 128,
            .seed = 0x0,
            .secret_len = 200,
            .digest = 0x1154a5bae7f345f838f87cb49c205ab,
        },
        .{
            .len = 129,
            .seed = 0x0,
            .secret_len = 137,
            .digest = 0x88d31a55f034f950a826d4cb480a2fd,
        },
        .{
            .len = 240,
            .seed = 0x0,
            .secret_len = 192,
            .digest = 0x5491a33bc62a424e0478efeffb8b6624,
        },
        .{ .len = 241, .seed = 0x1, .secret_len = 0, .digest = 0x529c502eaccf9f1a07c31b142d380250 },
        .{
            .len = 256,
            .seed = 0x0,
            .secret_len = 136,
            .digest = 0x80eae6f152080b8047a2ba6d75ab19d9,
        },
        .{
            .len = 257,
            .seed = 0x0,
            .secret_len = 200,
            .digest = 0x735b65a38f54449c0d8f835e9f5cfdff,
        },
        .{
            .len = 576,
            .seed = 0x0,
            .secret_len = 136,
            .digest = 0xff48c64a7ac63193042d0ac1a6c4f29c,
        },
        .{
            .len = 1088,
            .seed = 0x0,
            .secret_len = 192,
            .digest = 0xacfa1d4b62b909b3ec339e5c1e8f73d5,
        },
        .{
            .len = 4096,
            .seed = 0xffffffffffffffff,
            .secret_len = 0,
            .digest = 0x14f29e4ba87e6282ec3056b241d36c45,
        },
    };
    const fragments = [_]usize{ 1, 63, 64, 65, 239, 240, 241, 255, 256, 257 };
    for (cases) |case| {
        const options: Xxh3Options = if (case.secret_len == 0) .{
            .mode = .{ .seed = case.seed },
        } else .{ .mode = .{ .secret = secret[0..case.secret_len] } };
        try testing.expectEqual(case.digest, try hashWithOptions(options, bytes[0..case.len]));
        for (fragments) |fragment| {
            var state: Xxh3_128 = undefined;
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
    var state: Xxh3_128 = undefined;
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
        var state: Xxh3_128 = undefined;
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
    // Independent XXH3-128 values from xxHash v0.8.4 for the inputs below.
    var bytes: [384]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i * 53 + 7);
    const secret: [137]u8 = @splat(0xa5);
    const cases = [_]struct {
        prefix: usize,
        seeded: [2]u128,
        secret: [2]u128,
    }{ .{ .prefix = 192, .seeded = .{
        0x632874bc3b4f1851e171c4058af35077, 0x6e5a8485443088e091c39ffece9a3644,
    }, .secret = .{
        0x6463781a1d2429327557cb38d1c4decd, 0x1fe86bca6ddb33a0cc599c907b6b63cf,
    } }, .{ .prefix = 193, .seeded = .{
        0x81bead69c7783baa95204103d0e4fc0b, 0x813be16afee7595a8b32b8265caa0e41,
    }, .secret = .{
        0x1d367ca8e3bfbf5afabef7a337d71faf, 0x9d37633461486f5c9cd8d74a6e5eda3f,
    } }, .{ .prefix = 255, .seeded = .{
        0xd74b21cee1daaa09a4adb43f78afc847, 0xaa67064e4c7adebcc62e64a8cb0f27b8,
    }, .secret = .{
        0x9e457bfb0366d5e7e263db7d86655821, 0xe3beeb3e9ec5068f247f046280cfa93b,
    } }, .{ .prefix = 256, .seeded = .{
        0x6e5a8485443088e091c39ffece9a3644, 0xde499b3be57e37d0d17a63171dcc88d6,
    }, .secret = .{ 0x1fe86bca6ddb33a0cc599c907b6b63cf, 0x7e6f03a356476d1e21eee0af3b3595c9 } } };
    for (cases) |case| {
        inline for (.{ false, true }) |custom| {
            var state: Xxh3_128 = undefined;
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
