//! Shared XXH3 streaming history, stripe accumulation and snapshot finalization. Algorithm
//! reference: xxHash v0.8.4, designed by Yann Collet and contributors.

const std = @import("std");
const one_shot = @import("xxh3.zig");
const long = @import("xxh3_long.zig");
const default_secret: *const [192]u8 = &one_shot.default_secret;
const prime1: u64 = 0x9e3779b185ebca87;
const prime2: u64 = 0xc2b2ae3d27d4eb4f;

// The retained 256 bytes model reference buffer evolution even when the 64-bit total wraps. The
// separately tracked next stripe position prevents a stream fragment from changing block cadence.
const History = struct { bytes: [256]u8 = @splat(0), length: usize = 0 };
const Accumulator = struct {
    lanes: long.StripeAccumulator = .{},
    next_stripe: usize = 0,

    fn appendStripes(self: *Accumulator, data: []const u8, count: usize, secret: []const u8) void {
        const stripes_per_block = (secret.len - 64) / 8;
        var lanes = self.lanes;
        var next_stripe = self.next_stripe;
        var consumed: usize = 0;
        while (consumed < count) {
            const available = stripes_per_block - next_stripe;
            const run = @min(count - consumed, available);
            for (0..run) |index| {
                const data_offset = (consumed + index) * 64;
                const key_offset = (next_stripe + index) * 8;
                lanes.addStripe(data[data_offset..][0..64], secret[key_offset..][0..64]);
            }
            consumed += run;
            next_stripe += run;
            if (next_stripe == stripes_per_block) {
                lanes.scrambleBlock(secret[secret.len - 64 ..][0..64]);
                next_stripe = 0;
            }
        }
        self.lanes = lanes;
        self.next_stripe = next_stripe;
    }
};

// Writing directly into stream storage allows initialization without a returned-array copy while
// keeping the one-shot path independent. Both derivations must produce the same little-endian bytes.
inline fn writeSeededSecret(derived: *[192]u8, seed: u64) void {
    for (0..12) |pair| {
        const offset = pair * 16;
        const first = std.mem.readInt(u64, default_secret[offset..][0..8], .little);
        const second = std.mem.readInt(u64, default_secret[offset + 8 ..][0..8], .little);
        std.mem.writeInt(u64, derived[offset..][0..8], first +% seed, .little);
        std.mem.writeInt(u64, derived[offset + 8 ..][0..8], second -% seed, .little);
    }
}

test "stream secret writer matches shared derivation and preserves initialized history" {
    for ([_]u64{ 0, 1, 0x123456789abcdef0, 0xffffffffffffffff }) |seed| {
        var derived: [192]u8 = undefined;
        writeSeededSecret(&derived, seed);
        try std.testing.expectEqualSlices(u8, &one_shot.deriveSeededSecret(seed), &derived);
        var state: State = undefined;
        @memset(std.mem.asBytes(&state), 0xa5);
        state.reset(seed);
        try std.testing.expectEqualSlices(u8, &@as([256]u8, @splat(0)), &state.history.bytes);
        if (seed != 0) {
            try std.testing.expectEqualSlices(u8, &derived, &state.derived_secret);
        }
    }
}

pub const State = struct {
    accumulator: Accumulator,
    history: History,
    total: u64,
    seed: u64,
    borrowed_secret: ?[]const u8,
    derived_secret: [192]u8,

    pub fn reset(self: *State, seed: u64) void {
        self.configure(.{ .seed = seed });
    }

    pub fn resetSecret(self: *State, secret: []const u8) void {
        self.configure(.{ .secret = secret });
    }

    pub fn final64(self: *const State) u64 {
        return @truncate(self.digest(64));
    }

    pub fn final128(self: *const State) u128 {
        return self.digest(128);
    }

    fn configure(self: *State, options: one_shot.SecretMode) void {
        // A wrapped byte count can select a short digest, which reads initialized history bytes.
        self.history = .{};
        self.accumulator = .{};
        self.total = 0;
        self.seed = 0;
        self.borrowed_secret = null;
        switch (options) {
            .seed => |value| {
                self.seed = value;
                if (value != 0) writeSeededSecret(&self.derived_secret, value);
            },
            .secret => |value| self.borrowed_secret = value,
        }
    }

    fn secretBytes(self: *const State) []const u8 {
        if (self.borrowed_secret) |secret| return secret;
        return if (self.seed == 0) default_secret else &self.derived_secret;
    }

    pub fn update(self: *State, input: []const u8) void {
        self.total +%= @truncate(input.len);
        // Fixed-size fragments avoid the generic copy path while retaining exact bounds.
        switch (input.len) {
            64 => if (self.history.length <= 192) {
                @memcpy(self.history.bytes[self.history.length..][0..64], input[0..64]);
                self.history.length += 64;
                return;
            },
            16 => if (self.history.length <= 240) {
                @memcpy(self.history.bytes[self.history.length..][0..16], input[0..16]);
                self.history.length += 16;
                return;
            },
            8 => if (self.history.length <= 248) {
                @memcpy(self.history.bytes[self.history.length..][0..8], input[0..8]);
                self.history.length += 8;
                return;
            },
            3 => if (self.history.length <= 253) {
                @memcpy(self.history.bytes[self.history.length..][0..3], input[0..3]);
                self.history.length += 3;
                return;
            },
            else => {},
        }
        if (input.len <= self.history.bytes.len - self.history.length) {
            @memcpy(self.history.bytes[self.history.length..][0..input.len], input);
            self.history.length += input.len;
            return;
        }
        self.updateOverflow(input);
    }

    noinline fn updateOverflow(self: *State, input: []const u8) void {
        const secret = self.secretBytes();
        if (input.len == 64 and self.history.length == 256) {
            // This transition always flushes four stripes; specialize that fixed-size case.
            @call(
                .always_inline,
                Accumulator.appendStripes,
                .{ &self.accumulator, &self.history.bytes, 4, secret },
            );
            @memcpy(self.history.bytes[0..64], input[0..64]);
            self.history.length = 64;
            return;
        }
        var offset: usize = 0;
        if (self.history.length != 0) {
            const needed = self.history.bytes.len - self.history.length;
            @memcpy(self.history.bytes[self.history.length..], input[0..needed]);
            offset = needed;
            self.accumulator.appendStripes(&self.history.bytes, 4, secret);
            self.history.length = 0;
        }
        if (input.len - offset > self.history.bytes.len) {
            const complete = (input.len - offset - 1) / 64;
            self.accumulator.appendStripes(input[offset..], complete, secret);
            offset += complete * 64;
            // A short final tail can need bytes from this preceding stripe during finalization.
            @memcpy(self.history.bytes[192..256], input[offset - 64 ..][0..64]);
        }
        const tail = input[offset..];
        @memcpy(self.history.bytes[0..tail.len], tail);
        self.history.length = tail.len;
    }

    fn snapshotAccumulator(self: *const State, secret: []const u8) long.StripeAccumulator {
        var lanes = self.accumulator.lanes;
        if (self.history.length >= 64) {
            const ordinary = (self.history.length - 1) / 64;
            const stripes_per_block = (secret.len - 64) / 8;
            var next_stripe = self.accumulator.next_stripe;
            // A snapshot has at most three ordinary buffered stripes; handle them directly while
            // keeping the caller's stream unchanged.
            for (0..ordinary) |index| {
                lanes.addStripe(
                    self.history.bytes[index * 64 ..][0..64],
                    secret[next_stripe * 8 ..][0..64],
                );
                next_stripe += 1;
                if (next_stripe == stripes_per_block) {
                    lanes.scrambleBlock(secret[secret.len - 64 ..][0..64]);
                    next_stripe = 0;
                }
            }
            lanes.addStripe(
                self.history.bytes[self.history.length - 64 ..][0..64],
                secret[secret.len - 71 ..][0..64],
            );
        } else {
            // Reconstruct the final stripe from the preserved bytes and the current short tail.
            var stripe: [64]u8 = undefined;
            const previous = 64 - self.history.length;
            @memcpy(stripe[0..previous], self.history.bytes[256 - previous ..]);
            @memcpy(stripe[previous..], self.history.bytes[0..self.history.length]);
            lanes.addStripe(&stripe, secret[secret.len - 71 ..][0..64]);
        }
        return lanes;
    }

    fn digest(self: *const State, comptime result_bits: u8) u128 {
        if (result_bits != 64 and result_bits != 128) @compileError(
            "XXH3 result width must be 64 or 128",
        );
        if (self.total <= 240) {
            const input = self.history.bytes[0..@intCast(self.total)];
            return one_shot.hashUpTo240(result_bits, input, self.seed, self.borrowed_secret);
        }
        const secret = self.secretBytes();
        const lanes = self.snapshotAccumulator(secret);
        if (result_bits == 64) return lanes.finish(secret[11..][0..64], self.total *% prime1);
        return finishWide(lanes, secret, self.total);
    }
};

// Keep the two-merge path out of the common streaming caller's generated code.
noinline fn finishWide(lanes: long.StripeAccumulator, secret: []const u8, length: u64) u128 {
    const low = lanes.finish(secret[11..][0..64], length *% prime1);
    const high = lanes.finish(secret[secret.len - 75 ..][0..64], ~(length *% prime2));
    return (@as(u128, high) << 64) | low;
}

test "short fragment copies change only their exact history bytes" {
    var input: [272]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index * 53 + 7);
    const secret: [137]u8 = @splat(0xa5);
    for ([_]one_shot.SecretMode{ .{ .seed = 1 }, .{ .secret = &secret } }) |mode| {
        for (0..257) |prefix| {
            for (0..16) |fragment| {
                var state: State = undefined;
                state.configure(mode);
                state.update(input[0..prefix]);
                const before = state.history.bytes;
                state.update(input[prefix..][0..fragment]);
                if (prefix + fragment <= 256) {
                    var expected = before;
                    @memcpy(expected[prefix..][0..fragment], input[prefix..][0..fragment]);
                    try std.testing.expectEqual(prefix + fragment, state.history.length);
                    try std.testing.expectEqualSlices(u8, &expected, &state.history.bytes);
                }
                const all = input[0 .. prefix + fragment];
                try std.testing.expectEqual(one_shot.hash(64, all, mode), state.digest(64));
                try std.testing.expectEqual(one_shot.hash(128, all, mode), state.digest(128));
            }
        }
    }
}

test "fragmented updates and snapshots match one-shot seeded and secret modes" {
    var bytes: [2049]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index * 53 + 7);
    var secret: [137]u8 = undefined;
    for (&secret, 0..) |*byte, index| byte.* = @truncate(index * 71 + 13);
    for ([_]one_shot.SecretMode{ .{ .seed = 1 }, .{ .secret = &secret } }) |mode| {
        var state: State = undefined;
        state.configure(mode);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(offset + 64, bytes.len);
            state.update(bytes[offset..end]);
            try std.testing.expectEqual(one_shot.hash(64, bytes[0..end], mode), state.digest(64));
            try std.testing.expectEqual(one_shot.hash(128, bytes[0..end], mode), state.digest(128));
            offset = end;
        }
        var copy = state;
        copy.update("suffix");
        try std.testing.expectEqual(one_shot.hash(64, &bytes, mode), state.digest(64));
    }
}

test "16-byte fragments and snapshots cross history and secret-block boundaries" {
    var input: [784]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index * 53 + 7);
    var secret: [137]u8 = undefined;
    for (&secret, 0..) |*byte, index| byte.* = @truncate(index * 71 + 13);

    // Numeric digests from xxHash v0.8.4 with seed 1 and the custom secret above.
    const cases = [_]struct {
        length: usize,
        seeded64: u64,
        seeded128: u128,
        secret64: u64,
        secret128: u128,
    }{
        .{
            .length = 16,
            .seeded64 = 0x9393b52a802fc064,
            .seeded128 = 0x8b244aacf9035147e796c3d787d5bee3,
            .secret64 = 0x17d2d00a62a460f2,
            .secret128 = 0x5a98c44bc406fd83eb465bebb4cdfc00,
        },
        .{
            .length = 240,
            .seeded64 = 0x8a116a10ee5b006b,
            .seeded128 = 0x74e43c6a17f3f1fad7e3e7fa6f902d10,
            .secret64 = 0xb6ab8c833b4c6e53,
            .secret128 = 0x6bebd6e88303739ea2bec726543dfdde,
        },
        .{
            .length = 256,
            .seeded64 = 0xe171c4058af35077,
            .seeded128 = 0x632874bc3b4f1851e171c4058af35077,
            .secret64 = 0xb9df17fb0358a462,
            .secret128 = 0xe3917dc165c4117db9df17fb0358a462,
        },
        .{
            .length = 272,
            .seeded64 = 0x3fe76d4ab37cac86,
            .seeded128 = 0xade8deaf0e957e053fe76d4ab37cac86,
            .secret64 = 0xc5ef6f42d380005d,
            .secret128 = 0xf16f79ac707b8897c5ef6f42d380005d,
        },
        .{
            .length = 512,
            .seeded64 = 0x01aeacdf55f6a39b,
            .seeded128 = 0xbbba2d581e85f81601aeacdf55f6a39b,
            .secret64 = 0x2a23566f921e8536,
            .secret128 = 0xfccb74c0bedfb3b92a23566f921e8536,
        },
        .{
            .length = 528,
            .seeded64 = 0x37b5729ee6bb43f0,
            .seeded128 = 0x9cc9ffd9b4cbe19c37b5729ee6bb43f0,
            .secret64 = 0x79c4ff3176b2bf98,
            .secret128 = 0x7c7ae864cc796de379c4ff3176b2bf98,
        },
        .{
            .length = 768,
            .seeded64 = 0x983dc03140fedaa8,
            .seeded128 = 0x58f480ed7141b3fb983dc03140fedaa8,
            .secret64 = 0x455bf21001b3b6ba,
            .secret128 = 0xc45d37bedba3144c455bf21001b3b6ba,
        },
        .{
            .length = 784,
            .seeded64 = 0x5d518afa6ab825cd,
            .seeded128 = 0xd5928985346c81025d518afa6ab825cd,
            .secret64 = 0x6b9bc359710fbd45,
            .secret128 = 0xdc6f45532e637a4f6b9bc359710fbd45,
        },
    };
    var seeded: State = undefined;
    seeded.reset(1);
    var custom: State = undefined;
    custom.resetSecret(&secret);
    var offset: usize = 0;
    for (cases) |case| {
        while (offset < case.length) : (offset += 16) {
            const fragment = input[offset..][0..16];
            seeded.update(fragment);
            custom.update(fragment);
        }
        try std.testing.expectEqual(case.seeded64, seeded.final64());
        try std.testing.expectEqual(case.seeded128, seeded.final128());
        try std.testing.expectEqual(case.secret64, custom.final64());
        try std.testing.expectEqual(case.secret128, custom.final128());
        var seeded_copy = seeded;
        var custom_copy = custom;
        seeded_copy.update("suffix");
        custom_copy.update("suffix");
        try std.testing.expectEqual(case.seeded64, seeded.final64());
        try std.testing.expectEqual(case.secret128, custom.final128());
    }
}

test "secret-mode copies diverge without retaining the input" {
    var secret: [137]u8 = undefined;
    for (&secret, 0..) |*byte, index| byte.* = @truncate(index * 71 + 13);
    var original: State = undefined;
    original.resetSecret(&secret);
    var prefix = [_]u8{ 'a', 'b' };
    original.update(&prefix);
    var copy = original;
    @memset(&prefix, 0);
    original.update("c");
    copy.update("d");
    const options: one_shot.SecretMode = .{ .secret = &secret };
    try std.testing.expectEqual(one_shot.hash(128, "abc", options), original.digest(128));
    try std.testing.expectEqual(one_shot.hash(128, "abd", options), copy.digest(128));
    try std.testing.expectEqual(original.digest(128), original.digest(128));
}

test "synthetic counter wraps preserve reference snapshots and independent copies" {
    // Expected values: xxHash v0.8.4, c87183a, using zeroed initial state storage. After the
    // prefix, its totalLen was set to 0 -% gap; then the suffix was appended. This does not claim
    // that a stream of 2^64 bytes was processed.
    var input: [1024]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = @truncate(i * 131 + (i >> 3) * 17 + 19);
    var secret: [137]u8 = undefined;
    for (&secret, 0..) |*byte, i| byte.* = @truncate(i * 71 + 13);
    // Expected arrays are ordered by seed zero, seed one, then the 137-byte custom secret.
    const cases = [_]struct {
        prefix: usize,
        gap: u64,
        suffix: usize,
        expected64: [3]u64,
        expected128: [3]u128,
    }{ .{ .prefix = 256, .gap = 1, .suffix = 1, .expected64 = .{
        0x2d06800538d394c2, 0x4dc5b0cc826f6703,
        0xd7e03ade0d5d1fea,
    }, .expected128 = .{
        0x99aa06d3014798d86001c324468d497f, 0xd9265cc53bb2b9ae6131b78f753823cd,
        0x727fc9ec235130efbe9fa3050315264a,
    } }, .{ .prefix = 257, .gap = 3, .suffix = 19, .expected64 = .{
        0x6d0c544a5f0e3cbf, 0x833956aa5ba853ef,
        0x8c7194b5e7da571c,
    }, .expected128 = .{
        0x6216cf3d5da61b626e2708ecb6ddf8f0, 0x0d1dd0488b0be275f7c39b2165dee777,
        0x961b5b6d59208d6d3e660cb7577ecb14,
    } }, .{ .prefix = 65, .gap = 1, .suffix = 241, .expected64 = .{
        0x03cd521d1b70148c, 0x34e22829e76ae36a,
        0x52b104c974d7d3c3,
    }, .expected128 = .{
        0x2ed31ad641c7acd89efeef0e7d50c9d6, 0x37634a793f72be644bf8c37564f95183,
        0x15f9f54976badc4d256ec78109281249,
    } }, .{ .prefix = 257, .gap = 2, .suffix = 243, .expected64 = .{
        0xa945ea294afaf513, 0x958ab9076b00a78c,
        0x409ae681b5061435,
    }, .expected128 = .{
        0x2e861d28f20056c1a945ea294afaf513, 0x8a91be4ea627cbfe958ab9076b00a78c,
        0x6dbcb0b026e5aa0a409ae681b5061435,
    } } };
    const modes = [_]one_shot.SecretMode{ .{ .seed = 0 }, .{ .seed = 1 }, .{ .secret = &secret } };
    for (cases) |case| {
        for (modes, 0..) |mode, index| {
            var state: State = undefined;
            state.configure(mode);
            state.update(input[0..case.prefix]);
            state.total = 0 -% case.gap;
            var copy = state;
            const before64 = copy.final64();
            const before128 = copy.final128();
            const suffix = input[case.prefix..][0..case.suffix];
            state.update(suffix);
            try std.testing.expectEqual(before64, copy.final64());
            try std.testing.expectEqual(before128, copy.final128());
            try std.testing.expectEqual(case.expected64[index], state.final64());
            try std.testing.expectEqual(case.expected128[index], state.final128());
            copy.update(suffix);
            try std.testing.expectEqual(case.expected64[index], copy.final64());
            try std.testing.expectEqual(case.expected128[index], copy.final128());
        }
    }
}
