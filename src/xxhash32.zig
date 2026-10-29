//! Computes noncryptographic 32-bit XXH32 hashes for checksums and lookup keys.
//! `hash` uses seed zero and `hashSeeded` accepts any u32 seed. Both accept
//! exact, unaligned byte slices without padding.
//!
//! For incremental input, start a `Hasher` with `.init` or seeded `reset`,
//! append fragments with `update` and read `final` snapshots. Calls allocate
//! nothing, retain no input and need no cleanup. Copies of a state continue
//! independently; assign `.init` to start again. See hashSeeded for an
//! executable one-shot and incremental example.
//!
//! Numeric results are independent of host byte order. The upstream canonical
//! four bytes use big-endian order; LZ4 frame fields use little-endian order.
//!
//! Algorithm specification and streaming reference:
//! https://github.com/Cyan4973/xxHash/blob/v0.8.4/doc/xxhash_spec.md
//! https://github.com/Cyan4973/xxHash/blob/v0.8.4/xxhash.h

const std = @import("std");
const testing = std.testing;

// Yann Collet's xxHash specification defines the word mixing. A stripe feeds
// four independent accumulators with little-endian words; rotations and odd
// multipliers mix each contribution. The lanes converge before the final short
// tail and avalanche. This implementation keeps a copied partial stripe for
// streaming and retains long-input mode when its length counter wraps.
// https://github.com/Cyan4973/xxHash/blob/c87183a/doc/xxhash_spec.md

const prime_1: u32 = 0x9e3779b1;
const prime_2: u32 = 0x85ebca77;
const prime_3: u32 = 0xc2b2ae3d;
const prime_4: u32 = 0x27d4eb2f;
const prime_5: u32 = 0x165667b1;

/// Incremental seeded XXH32 state. Retains accumulators and at most 15 tail
/// bytes. Initialize before updating; copies are independent.
pub const Hasher = struct {
    /// Four running stripe accumulators; initialize with `.init` or `reset`.
    accumulators: [4]u32 = initialAccumulators(0),
    /// Accepted byte count modulo 2^32.
    total: u32 = 0,
    /// Copied bytes of the incomplete stripe; only the `buffered` prefix is
    /// active.
    tail: [16]u8 = @splat(0),
    /// Active tail length, always less than 16 in a valid state.
    buffered: u8 = 0,
    /// Remembers that a full stripe was processed, independently of counter
    /// wrapping.
    striped: bool = false,

    /// Seed-zero initial state. Copy or assign to begin another stream.
    pub const init: Hasher = .{};

    /// Starts a stream with any seed in possibly uninitialized storage.
    pub fn reset(self: *Hasher, seed: u32) void {
        self.* = .{ .accumulators = initialAccumulators(seed) };
    }

    /// Appends exact bytes. Total length contributes modulo 2^32; streams
    /// longer than 4 GiB retain the long-input accumulator path after wrapping.
    /// Input must remain readable and must not overlap this mutable state until
    /// return.
    pub fn update(self: *Hasher, input: []const u8) void {
        self.total +%= @truncate(input.len);
        var bytes = input;
        if (bytes.len < 16 - @as(usize, self.buffered)) {
            @memcpy(self.tail[self.buffered..][0..bytes.len], bytes);
            self.buffered += @intCast(bytes.len);
            return;
        }

        self.striped = true;
        if (self.buffered != 0) {
            const take = 16 - @as(usize, self.buffered);
            @memcpy(self.tail[self.buffered..], bytes[0..take]);
            consume(&self.accumulators, &self.tail);
            bytes = bytes[take..];
        }
        while (bytes.len >= 16) : (bytes = bytes[16..]) consume(
            &self.accumulators,
            bytes[0..16],
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

    /// Returns a snapshot without resetting. Later updates extend this stream.
    pub fn final(self: *const Hasher) u32 {
        const result: u32 = blk: {
            if (self.striped) break :blk merge(self.accumulators);
            break :blk self.accumulators[2] +% prime_5;
        };
        return finish(result +% self.total, self.tail[0..self.buffered]);
    }
};

/// Hashes a complete exact byte slice with seed zero and no retained state.
pub fn hash(bytes: []const u8) u32 {
    return hashSeeded(0, bytes);
}

/// Hashes exactly `bytes` with the supplied seed. Empty and unaligned slices
/// need no padding. The numeric result retains no input or other resource.
pub fn hashSeeded(seed: u32, bytes: []const u8) u32 {
    var cursor: usize = 0;
    var result = seed +% prime_5;
    if (bytes.len >= 16) {
        var accumulators = initialAccumulators(seed);
        while (bytes.len - cursor >= 16) : (cursor += 16) {
            consume(&accumulators, bytes[cursor..][0..16]);
        }
        result = merge(accumulators);
    }
    return finish(result +% @as(u32, @truncate(bytes.len)), bytes[cursor..]);
}

test hashSeeded {
    // Independent XXH32 result from xxHash v0.8.4, also retained in
    // test_vectors.
    try testing.expectEqual(0xaa3da8ff, hashSeeded(1, "abc"));

    var state: Hasher = .init;
    state.reset(1);
    state.update("a");
    state.update("bc");
    try testing.expectEqual(0xaa3da8ff, state.final());
}

fn initialAccumulators(seed: u32) [4]u32 {
    return .{
        seed +% prime_1 +% prime_2,
        seed +% prime_2,
        seed,
        seed -% prime_1,
    };
}

inline fn consume(accumulators: *[4]u32, bytes: *const [16]u8) void {
    inline for (0..4) |i| {
        const word = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
        accumulators[i] = rotate(
            accumulators[i] +% word *% prime_2,
            13,
        ) *% prime_1;
    }
}

inline fn merge(accumulators: [4]u32) u32 {
    var result = rotate(accumulators[0], 1);
    result +%= rotate(accumulators[1], 7);
    result +%= rotate(accumulators[2], 12);
    result +%= rotate(accumulators[3], 18);
    return result;
}

inline fn finish(initial: u32, bytes: []const u8) u32 {
    var result = initial;
    var cursor: usize = 0;
    while (bytes.len - cursor >= 4) : (cursor += 4) {
        const word = std.mem.readInt(u32, bytes[cursor..][0..4], .little);
        result = rotate(result +% word *% prime_3, 17) *% prime_4;
    }
    for (bytes[cursor..]) |byte| {
        const contribution = @as(u32, byte) *% prime_5;
        result = rotate(result +% contribution, 11) *% prime_1;
    }

    result ^= result >> 15;
    result *%= prime_2;
    result ^= result >> 13;
    result *%= prime_3;
    return result ^ (result >> 16);
}

fn rotate(value: u32, count: u5) u32 {
    return std.math.rotl(u32, value, count);
}

// Frozen numeric results from xxHash v0.8.4's XXH32. The reference code is
// copyright Yann Collet, BSD-2-Clause. No reference code is linked here.
// https://github.com/Cyan4973/xxHash/blob/v0.8.4/xxhash.h
const test_vectors = [_]struct {
    seed: u32,
    text: []const u8,
    expected: u32,
}{
    .{ .seed = 0, .text = "", .expected = 0x02cc5d05 },
    .{ .seed = 0, .text = "a", .expected = 0x550d7456 },
    .{ .seed = 0, .text = "abc", .expected = 0x32d153ff },
    .{ .seed = 1, .text = "", .expected = 0x0b2cb792 },
    .{ .seed = 1, .text = "abc", .expected = 0xaa3da8ff },
    .{ .seed = 0xffffffff, .text = "abc", .expected = 0xb22b1420 },
};

test "XXH32 independent seeded vectors" {
    for (test_vectors) |vector| {
        try testing.expectEqual(
            vector.expected,
            hashSeeded(vector.seed, vector.text),
        );
        var state: Hasher = .init;
        state.reset(vector.seed);
        state.update(vector.text);
        try testing.expectEqual(vector.expected, state.final());
    }
}

test "XXH32 every split, snapshots, independent copies and reset" {
    var storage: [1057]u8 = undefined;
    for (&storage, 0..) |*byte, i| byte.* = @truncate(i * 31 + 17);
    for ([_]u32{ 0, 1, 0xffffffff, prime_1 }) |seed| {
        for ([_]usize{ 0, 1, 15, 31 }) |offset| {
            for (0..130) |length| {
                const bytes = storage[offset..][0..length];
                const expected = std.hash.XxHash32.hash(seed, bytes);
                try testing.expectEqual(expected, hashSeeded(seed, bytes));
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
                }
            }
            const bytes = storage[offset..][0..1026];
            for (0..bytes.len + 1) |split| {
                var state: Hasher = .init;
                state.reset(seed);
                state.update(bytes[0..split]);
                state.update(bytes[split..]);
                try testing.expectEqual(
                    std.hash.XxHash32.hash(seed, bytes),
                    state.final(),
                );
            }
        }
    }
    var state: Hasher = .init;
    for (storage) |byte| state.update(&.{byte});
    try testing.expectEqual(hash(&storage), state.final());
    state = .init;
    try testing.expectEqual(hash(""), state.final());
}

test "XXH32 reset initializes storage and snapshots own pending bytes" {
    const text = "a partially buffered input";
    var input = text.*;
    var state: Hasher = undefined;
    state.reset(0xffffffff);
    state.update(&input);
    const prefix = state.final();
    var copy = state;
    @memset(&input, 0xff);
    copy.update(" suffix");
    try testing.expectEqual(std.hash.XxHash32.hash(0xffffffff, text), prefix);
    try testing.expectEqual(prefix, state.final());
    try testing.expectEqual(
        std.hash.XxHash32.hash(0xffffffff, text ++ " suffix"),
        copy.final(),
    );
    state.reset(1);
    state.update("abc");
    try testing.expectEqual(@as(u32, 0xaa3da8ff), state.final());
}

test "XXH32 exact input at Linux protected pages" {
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
                std.hash.XxHash32.hash(0, input),
                hash(input),
            );
            var state: Hasher = .init;
            state.reset(1);
            const split = @min(input.len, 15);
            state.update(input[0..split]);
            state.update(input[split..]);
            try testing.expectEqual(
                std.hash.XxHash32.hash(1, input),
                state.final(),
            );
        }
    }
}

test "XXH32 synthetic counter wraps retain the stripe branch" {
    // Independent facts from xxHash v0.8.4 at c87183a. The public C digest
    // supplies these results. Synthetic counters do not claim an executed
    // prefix of 2^32 bytes.
    const cases = [_]struct {
        seed: u32,
        before: u32,
        after: u32,
    }{
        .{ .seed = 0, .before = 0x1e2c5776, .after = 0x1229a425 },
        .{ .seed = 1, .before = 0xc77b0ad5, .after = 0xf5929925 },
    };
    const stripe = "0123456789abcdef";
    for (cases) |case| {
        var state: Hasher = .init;
        state.reset(case.seed);
        state.update(stripe);
        state.total = 0xfffffff0;
        state.update(stripe);
        try testing.expectEqual(case.before, state.final());
        state.update("a");
        try testing.expectEqual(case.after, state.final());
    }
}
