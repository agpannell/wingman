//! Computes noncryptographic 64-bit XXH64 hashes of exact byte slices. Use it
//! for content checksums and lookup keys where inputs are trusted. `hash` uses
//! seed zero; `hashSeeded` accepts any 64-bit seed. Both return a copied
//! numeric result, consume unaligned input without padding, and perform no
//! allocation or I/O. The same bytes and seed give the same result across
//! targets because input words are read in little-endian order.
//!
//! One-shot calls retain no input pointer or mutable state. A `Hasher` starts
//! with `.init` or a seeded reset, accepts fragments with `update` and returns
//! `final` snapshots. No operation needs cleanup. Callers choose how to
//! serialize the numeric result; the upstream canonical eight bytes use
//! big-endian order. A Zstandard frame checksum instead stores the low 32 bits
//! of the seed-zero result in little-endian order.
//!
//! Algorithm specification:
//! https://github.com/Cyan4973/xxHash/blob/v0.8.3/doc/xxhash_spec.md

const std = @import("std");
const testing = std.testing;

// Yann Collet's xxHash specification defines the word mixing. A stripe feeds
// four independent accumulators with little-endian words; rotations and odd
// multipliers mix each contribution. The lanes converge before the final short
// tail and avalanche. This implementation keeps a copied partial stripe for
// streaming and retains long-input mode when its length counter wraps.
// https://github.com/Cyan4973/xxHash/blob/c87183a/doc/xxhash_spec.md

const prime_1: u64 = 11400714785074694791;
const prime_2: u64 = 14029467366897019727;
const prime_3: u64 = 1609587929392839161;
const prime_4: u64 = 9650029242287828579;
const prime_5: u64 = 2870177450012600261;

/// Incremental seeded XXH64 state. Updates consume exact, possibly unaligned
/// bytes and retain only accumulators and a partial stripe. Copies continue
/// independently; finalization is a snapshot. No allocation or cleanup.
pub const Hasher = struct {
    /// Four running stripe accumulators; initialize with `.init` or `reset`.
    accumulators: [4]u64 = initialAccumulators(0),
    /// Accepted byte count modulo 2^64.
    total: u64 = 0,
    /// Copied bytes of the incomplete stripe; only the `buffered` prefix is
    /// active.
    tail: [32]u8 = @splat(0),
    /// Active tail length, always less than 32 in a valid state.
    buffered: u8 = 0,
    /// Remembers that a full stripe was processed, independently of counter
    /// wrapping.
    striped: bool = false,

    /// Seed-zero initial state; assign it to begin another stream.
    pub const init: Hasher = .{};

    /// Starts another stream with any seed, in possibly uninitialized storage.
    pub fn reset(self: *Hasher, seed: u64) void {
        self.* = .{ .accumulators = initialAccumulators(seed) };
    }

    /// Appends bytes without retaining input. Length arithmetic wraps modulo
    /// 2^64, as does the algorithm's final length contribution. Input must
    /// remain readable and must not overlap this mutable state until return.
    pub fn update(self: *Hasher, input: []const u8) void {
        self.total +%= @intCast(input.len);
        var bytes = input;
        if (bytes.len < 32 - @as(usize, self.buffered)) {
            @memcpy(self.tail[self.buffered..][0..bytes.len], bytes);
            self.buffered += @intCast(bytes.len);
            return;
        }

        self.striped = true;
        if (self.buffered != 0) {
            const take = 32 - @as(usize, self.buffered);
            @memcpy(self.tail[self.buffered..], bytes[0..take]);
            consume(&self.accumulators, &self.tail);
            bytes = bytes[take..];
        }
        while (bytes.len >= 32) : (bytes = bytes[32..]) consume(
            &self.accumulators,
            bytes[0..32],
        );

        @memcpy(self.tail[0..bytes.len], bytes);
        self.buffered = @intCast(bytes.len);
    }

    test update {
        var state: Hasher = .init;
        state.reset(1);
        state.update("a");
        const prefix = state.final();
        state.update("bc");
        try testing.expectEqual(hashSeeded(1, "a"), prefix);
        try testing.expectEqual(hashSeeded(1, "abc"), state.final());
    }

    /// Returns the hash of accepted bytes without changing this state. Later
    /// updates extend the same stream; repeated snapshots are identical.
    pub fn final(self: *const Hasher) u64 {
        const result: u64 = blk: {
            if (self.striped) break :blk merge(self.accumulators);
            break :blk self.accumulators[2] +% prime_5;
        };
        return finish(result +% self.total, self.tail[0..self.buffered]);
    }
};

/// Hashes exactly `bytes` with seed zero, without allocation or retained state.
pub fn hash(bytes: []const u8) u64 {
    return hashSeeded(0, bytes);
}

test hash {
    const checksum = hash("abc");
    try testing.expectEqual(@as(u64, 0x44bc2cf5ad770999), checksum);
}

/// Hashes exactly `bytes` with the supplied `seed` and accepts unaligned input.
/// No padding is required. The returned integer retains no pointer or resource.
pub fn hashSeeded(seed: u64, bytes: []const u8) u64 {
    var cursor: usize = 0;
    var result: u64 = seed +% prime_5;
    if (bytes.len >= 32) {
        var accumulators = [_]u64{
            seed +% prime_1 +% prime_2,
            seed +% prime_2,
            seed,
            seed -% prime_1,
        };
        while (bytes.len - cursor >= 32) : (cursor += 32) {
            inline for (0..4) |i| {
                accumulators[i] = round(
                    accumulators[i],
                    read64(bytes, cursor + i * 8),
                );
            }
        }
        result = rotate(accumulators[0], 1);
        result +%= rotate(accumulators[1], 7);
        result +%= rotate(accumulators[2], 12);
        result +%= rotate(accumulators[3], 18);
        inline for (accumulators) |accumulator| {
            result ^= round(0, accumulator);
            result = result *% prime_1 +% prime_4;
        }
    }

    result +%= bytes.len;
    while (bytes.len - cursor >= 8) : (cursor += 8) {
        result ^= round(0, read64(bytes, cursor));
        result = rotate(result, 27) *% prime_1 +% prime_4;
    }
    if (bytes.len - cursor >= 4) {
        const word = std.mem.readInt(u32, bytes[cursor..][0..4], .little);
        result ^= @as(u64, word) *% prime_1;
        result = rotate(result, 23) *% prime_2 +% prime_3;
        cursor += 4;
    }
    for (bytes[cursor..]) |byte| {
        result ^= @as(u64, byte) *% prime_5;
        result = rotate(result, 11) *% prime_1;
    }
    result ^= result >> 33;
    result *%= prime_2;
    result ^= result >> 29;
    result *%= prime_3;
    result ^= result >> 32;
    return result;
}

test hashSeeded {
    const seed: u64 = 42;
    const checksum = hashSeeded(seed, "abc");
    try testing.expectEqual(@as(u64, 0x13c1d910702770e6), checksum);
}

fn initialAccumulators(seed: u64) [4]u64 {
    return .{
        seed +% prime_1 +% prime_2,
        seed +% prime_2,
        seed,
        seed -% prime_1,
    };
}

inline fn consume(accumulators: *[4]u64, bytes: *const [32]u8) void {
    inline for (
        0..4,
    ) |i| accumulators[i] = round(accumulators[i], read64(bytes, i * 8));
}

inline fn merge(accumulators: [4]u64) u64 {
    var result = rotate(accumulators[0], 1);
    result +%= rotate(accumulators[1], 7);
    result +%= rotate(accumulators[2], 12);
    result +%= rotate(accumulators[3], 18);
    inline for (accumulators) |accumulator| {
        result ^= round(0, accumulator);
        result = result *% prime_1 +% prime_4;
    }
    return result;
}

inline fn finish(initial: u64, bytes: []const u8) u64 {
    var result = initial;
    var cursor: usize = 0;
    while (bytes.len - cursor >= 8) : (cursor += 8) {
        result ^= round(0, read64(bytes, cursor));
        result = rotate(result, 27) *% prime_1 +% prime_4;
    }
    if (bytes.len - cursor >= 4) {
        const word = std.mem.readInt(u32, bytes[cursor..][0..4], .little);
        result ^= @as(u64, word) *% prime_1;
        result = rotate(result, 23) *% prime_2 +% prime_3;
        cursor += 4;
    }
    for (bytes[cursor..]) |byte| {
        result ^= @as(u64, byte) *% prime_5;
        result = rotate(result, 11) *% prime_1;
    }
    result ^= result >> 33;
    result *%= prime_2;
    result ^= result >> 29;
    result *%= prime_3;
    result ^= result >> 32;
    return result;
}

fn rotate(value: u64, count: u6) u64 {
    return std.math.rotl(u64, value, count);
}

fn round(accumulator: u64, value: u64) u64 {
    return rotate(accumulator +% value *% prime_2, 31) *% prime_1;
}

fn read64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

// Frozen numeric outputs from Zstandard 1.5.7's bundled ZSTD_XXH64. The
// reference xxHash code is copyright Yann Collet, BSD-2-Clause:
// https://github.com/facebook/zstd/blob/f8745da/lib/common/xxhash.h
const prefix_vectors = [_]struct {
    bytes: usize,
    hash: u64,
}{
    .{ .bytes = 0, .hash = 0xef46db3751d8e999 },
    .{ .bytes = 1, .hash = 0x633457081244afec },
    .{ .bytes = 3, .hash = 0xfcb3f6ba205d67e6 },
    .{ .bytes = 4, .hash = 0xeec284286c28301d },
    .{ .bytes = 7, .hash = 0xa4ed3671ec8df42e },
    .{ .bytes = 8, .hash = 0x434789cd14998437 },
    .{ .bytes = 15, .hash = 0x50216f3bd82a871e },
    .{ .bytes = 16, .hash = 0xa8259219bb07a963 },
    .{ .bytes = 31, .hash = 0x9c3f11697931332f },
    .{ .bytes = 32, .hash = 0x6e806bb02c091d33 },
    .{ .bytes = 33, .hash = 0xa707f8455d55fb7d },
    .{ .bytes = 63, .hash = 0x12382bc0d122e312 },
    .{ .bytes = 64, .hash = 0x8d681498496979c0 },
    .{ .bytes = 65, .hash = 0xbd2553644b8c0059 },
    .{ .bytes = 255, .hash = 0x7f2de25b6ef33488 },
    .{ .bytes = 1024, .hash = 0x20b65c5f24fce2a4 },
};

// Numeric outputs generated with XXH64 from xxHash v0.8.3, whose reference code
// is copyright (c) 2012-2023 Yann Collet, licensed BSD-2-Clause.
// https://github.com/Cyan4973/xxHash/blob/v0.8.3/xxhash.h
const seeded_lengths = [_]usize{ 0, 3, 31, 32, 33, 1024 };
const seeded_vectors = blk: {
    const Vector = struct { seed: u64, hashes: [seeded_lengths.len]u64 };
    const one: Vector = .{ .seed = 1, .hashes = .{
        0xd5afba1336a3be4b, 0x07b9cb622c8be259,
        0xcc6be4c4c8e18c13, 0xcebb91cd59829a16,
        0xf698d682e27495ff, 0x3ba93a47f26b5a8a,
    } };
    const all_bits: Vector = .{ .seed = 0xffffffffffffffff, .hashes = .{
        0x298f4c84b24f5380, 0x305b41494634382b,
        0x762bf07e32fd0b22, 0x508e7826939de129,
        0x8663b458f109718e, 0xfafdd2198093d443,
    } };
    const prime: Vector = .{ .seed = 0x9e3779b185ebca87, .hashes = .{
        0x6ec6d05f61c7e7a7, 0x93279d6319598428,
        0x6059d8e93e9c537d, 0x58744b00a801c62d,
        0xa7a612fc8f19553a, 0x92ef5febb161fefb,
    } };
    break :blk [_]Vector{ one, all_bits, prime };
};

test "XXH64 seed-zero vectors and every prefix match the standard reference" {
    try testing.expectEqual(@as(u64, 0xef46db3751d8e999), hash(""));
    try testing.expectEqual(@as(u64, 0xd24ec4f1a98c6e5b), hash("a"));
    try testing.expectEqual(@as(u64, 0x44bc2cf5ad770999), hash("abc"));
    const storage = try testing.allocator.alloc(u8, 1025);
    defer testing.allocator.free(storage);
    for (storage, 0..) |*byte, i| byte.* = @truncate(i * 31 + 17);
    for (prefix_vectors) |vector| {
        try testing.expectEqual(
            vector.hash,
            hash(storage[1..][0..vector.bytes]),
        );
    }
    for (0..1025) |count| {
        const bytes = storage[1..][0..count];
        try testing.expectEqual(std.hash.XxHash64.hash(0, bytes), hash(bytes));
    }
}

test "XXH64 seeded vectors and unaligned stripe boundaries match references" {
    const storage = try testing.allocator.alloc(u8, 4096 + 31);
    defer testing.allocator.free(storage);
    for (storage, 0..) |*byte, i| byte.* = @truncate(i * 31 + 17);

    for (seeded_vectors) |vector| {
        for (seeded_lengths, vector.hashes) |count, expected| {
            try testing.expectEqual(
                expected,
                hashSeeded(vector.seed, storage[1..][0..count]),
            );
        }
    }

    const seeds = [_]u64{
        0, 1, 0xffffffff00000000, 0xffffffffffffffff, prime_1,
    };
    const boundaries = [_]usize{
        255, 256, 257, 511, 512, 513, 1023, 1024, 1025, 4095, 4096,
    };
    for (0..32) |offset| {
        for (seeds) |seed| {
            for (0..129) |count| {
                const bytes = storage[offset..][0..count];
                try testing.expectEqual(
                    std.hash.XxHash64.hash(seed, bytes),
                    hashSeeded(seed, bytes),
                );
            }
            for (boundaries) |count| {
                const bytes = storage[offset..][0..count];
                try testing.expectEqual(
                    std.hash.XxHash64.hash(seed, bytes),
                    hashSeeded(seed, bytes),
                );
            }
        }
    }
}

test "XXH64 every split, snapshots, independent copies and seeded reset" {
    var storage: [1057]u8 = undefined;
    for (&storage, 0..) |*byte, i| byte.* = @truncate(i * 31 + 17);
    for ([_]u64{ 0, 1, 0xffffffffffffffff, prime_1 }) |seed| {
        for ([_]usize{ 0, 1, 31 }) |offset| {
            for (0..130) |length| {
                const bytes = storage[offset..][0..length];
                const expected = std.hash.XxHash64.hash(seed, bytes);
                for (0..length + 1) |split| {
                    var state: Hasher = .init;
                    state.reset(seed);
                    state.update(bytes[0..split]);
                    try testing.expectEqual(
                        hashSeeded(seed, bytes[0..split]),
                        state.final(),
                    );
                    var copy = state;
                    state.update("");
                    state.update(bytes[split..]);
                    copy.update(bytes[split..]);
                    try testing.expectEqual(expected, state.final());
                    try testing.expectEqual(expected, copy.final());
                    try testing.expectEqual(expected, state.final());
                }
            }
            const bytes = storage[offset..][0..1026];
            for (0..bytes.len + 1) |split| {
                var state: Hasher = .init;
                state.reset(seed);
                state.update(bytes[0..split]);
                state.update(bytes[split..]);
                try testing.expectEqual(hashSeeded(seed, bytes), state.final());
            }
        }
    }
    var state: Hasher = .init;
    for (storage) |byte| state.update(&.{byte});
    try testing.expectEqual(hash(&storage), state.final());
    state = .init;
    try testing.expectEqual(hash(""), state.final());
}

test "XXH64 reset initializes storage and snapshots own pending bytes" {
    const text = "a partially buffered input";
    var input = text.*;
    var state: Hasher = undefined;
    state.reset(0xffffffff00000001);
    state.update(&input);
    const prefix = state.final();
    var copy = state;
    @memset(&input, 0xff);
    copy.update(" suffix");
    try testing.expectEqual(
        std.hash.XxHash64.hash(0xffffffff00000001, text),
        prefix,
    );
    try testing.expectEqual(prefix, state.final());
    try testing.expectEqual(
        std.hash.XxHash64.hash(0xffffffff00000001, text ++ " suffix"),
        copy.final(),
    );
    state.reset(42);
    state.update("abc");
    try testing.expectEqual(@as(u64, 0x13c1d910702770e6), state.final());
}

test "XXH64 exact input at Linux protected pages" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const page = std.heap.pageSize();
    const mapping = try std.posix.mmap(
        null,
        4 * page,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(mapping);
    for ([_]usize{ 0, 3 * page }) |offset| {
        const result = std.os.linux.mprotect(mapping.ptr + offset, page, .{});
        try std.testing.expectEqual(
            std.posix.E.SUCCESS,
            std.posix.errno(result),
        );
    }
    const bytes = mapping[page..][0 .. 2 * page];
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i *% 173 +% (i >> 4));
    const protected = std.os.linux.mprotect(
        bytes.ptr,
        bytes.len,
        .{ .READ = true },
    );
    try std.testing.expectEqual(
        std.posix.E.SUCCESS,
        std.posix.errno(protected),
    );
    for (0..1025) |size| {
        for (
            [_][]const u8{ bytes[0..size], bytes[bytes.len - size ..] },
        ) |input| {
            try testing.expectEqual(
                std.hash.XxHash64.hash(0, input),
                hash(input),
            );
            var state: Hasher = .init;
            state.reset(0xffffffff00000001);
            const split = @min(input.len, 15);
            state.update(input[0..split]);
            state.update(input[split..]);
            try testing.expectEqual(
                std.hash.XxHash64.hash(0xffffffff00000001, input),
                state.final(),
            );
        }
    }
}

test "XXH64 synthetic counter wraps retain the stripe branch" {
    // Independent facts from xxHash v0.8.4 at c87183a. The C merge/finalize
    // primitives use modular length with the stripe branch retained. Synthetic
    // counters do not claim an executed prefix of 2^64 bytes.
    const cases = [_]struct {
        seed: u64,
        before: u64,
        after: u64,
    }{
        .{
            .seed = 0,
            .before = 0xef6cfa4c6bbe5c83,
            .after = 0x7f8783c5d6739ab4,
        },
        .{
            .seed = 1,
            .before = 0x519f21a86bd5b6f3,
            .after = 0xfba763837d9597cb,
        },
    };
    const stripe = "0123456789abcdef0123456789abcdef";
    for (cases) |case| {
        var state: Hasher = .init;
        state.reset(case.seed);
        state.update(stripe);
        state.total = 0xffffffffffffffe0;
        state.update(stripe);
        try testing.expectEqual(case.before, state.final());
        state.update("a");
        try testing.expectEqual(case.after, state.final());
    }
}
