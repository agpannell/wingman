//! Computes IEEE CRC-32 checksums over exact byte slices without allocation. Use it to check
//! content bytes or build gzip and PNG checksum fields. `hash` checksums a complete buffer. With
//! `Hasher` the caller appends fragments of one stream and reads the numeric u32 result from a
//! final snapshot.
//!
//! The caller owns the four-byte state. Input is consumed during each update and is never retained;
//! arbitrary alignment, empty fragments and exact input extents need no padding. `final` takes a
//! snapshot without resetting the stream. Copying the state permits independent continuation;
//! assigning a new `init` value starts another stream. Serialize mutation of a shared state. No
//! operation needs an allocator or cleanup. Empty input has checksum zero.
//!
//! Callers encode the numeric result for their format: gzip uses little-endian bytes and PNG uses
//! big-endian bytes. `combine` computes the checksum of concatenated sequences from their finalized
//! checksums and the second sequence's byte length. `CombineOperator` reuses that operation for a
//! fixed length. See `Hasher.update` for an incremental example.
//!
//! CPU features follow the compile-time target, with acceleration on supported x86 and AArch64
//! targets. This is the IEEE variant used by gzip and PNG. The x86 CRC32 instruction computes the
//! distinct CRC-32C (Castagnoli) variant. Format: https://www.rfc-editor.org/rfc/rfc1952

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

// A CRC treats input bits as polynomial coefficients, adding with XOR. Advancing a block is
// multiplication by a power of x modulo the generator. Folding applies that identity to several
// independent vectors, then joins them before a final 32-bit reduction. Carryless instructions
// multiply those polynomials; generated constants express the distance each vector advances.
//
// Eric Biggers' libdeflate 1.26 is a research reference for eight-way folding, shuffled tails and
// polynomial reduction. This implementation derives its tables, multipliers and shift masks in Zig,
// shares the fold across x86 and AArch64, and reads only supplied bytes.
// https://github.com/ebiggers/libdeflate/blob/92e6a0d/lib/x86/crc32_pclmul_template.h

const polynomial: u64 = 0x104c11db7;
const reflected_polynomial: u32 = 0xedb88320;

const pclmul = blk: {
    if (builtin.zig_backend != .stage2_llvm) break :blk false;
    if (builtin.cpu.arch != .x86 and builtin.cpu.arch != .x86_64) break :blk false;
    const carryless = std.Target.x86.featureSetHas(builtin.cpu.features, .pclmul);
    const sse2 = std.Target.x86.featureSetHas(builtin.cpu.features, .sse2);
    break :blk carryless and sse2;
};
const aarch64 = blk: {
    if (builtin.zig_backend != .stage2_llvm) break :blk false;
    break :blk builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .aarch64_be;
};
// Zig's AArch64 AES feature includes the 64-bit PMULL instructions.
const pmull = aarch64 and std.Target.aarch64.featureSetHasAll(builtin.cpu.features, &.{
    .aes, .neon,
});
const arm_crc = aarch64 and std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc);
const shuffled_tail = pclmul and std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3);
const folding = pclmul or pmull;
const updateSmall = if (arm_crc) armCrc else sliced;
const wide_bytes: usize = blk: {
    if (!pclmul) break :blk 16;

    const features = builtin.cpu.features;
    if (!std.Target.x86.featureSetHas(features, .vpclmulqdq)) break :blk 16;
    if (std.Target.x86.featureSetHas(features, .avx512f)) break :blk 64;
    if (std.Target.x86.featureSetHas(features, .avx2)) break :blk 32;
    break :blk 16;
};

/// Four-byte incremental IEEE CRC-32 state owned by the caller. Initialize before updating. Copies
/// continue independently and need no cleanup.
pub const Hasher = struct {
    /// Unfinalized CRC remainder; initialize through `init` or copy a valid state.
    remainder: u32 = 0xffffffff,

    /// Empty-stream state. Copy or assign `.init` to begin a new sequence with checksum zero.
    pub const init: Hasher = .{};

    /// Appends exactly `bytes` without retaining input or requesting memory.
    pub fn update(self: *Hasher, bytes: []const u8) void {
        if (folding and bytes.len >= 16) {
            self.remainder = updateFolded(self.remainder, bytes);
        } else {
            self.remainder = @call(.always_inline, updateSmall, .{ self.remainder, bytes });
        }
    }

    test update {
        const chunks = [_][]const u8{ "123", "456", "789" };
        var state: Hasher = .init;
        for (chunks) |chunk| state.update(chunk);

        try testing.expectEqual(@as(u32, 0xcbf43926), state.final());
    }

    /// Returns a numeric snapshot without resetting state; later updates extend the stream.
    pub fn final(self: Hasher) u32 {
        return ~self.remainder;
    }
};

/// Checksums one complete exact byte slice without allocation or retained state.
pub fn hash(bytes: []const u8) u32 {
    var state: Hasher = .init;
    // Keep the initial remainder visible in one-shot consumers even when incremental framing adds
    // other callers of the update kernel.
    @call(.always_inline, Hasher.update, .{ &state, bytes });
    return state.final();
}

test hash {
    // PNG includes the four-byte chunk type in its CRC. IEND has no data bytes.
    var field: [4]u8 = undefined;
    std.mem.writeInt(u32, &field, hash("IEND"), .big);
    try testing.expectEqual([4]u8{ 0xae, 0x42, 0x60, 0x82 }, field);
}

/// Immutable four-byte polynomial operator for repeated second-chunk lengths. Construct once with
/// `forLength`; copies can be shared across threads.
pub const CombineOperator = struct {
    factor: u32,

    /// Precomputes an operator for a second sequence of exactly `second_length` bytes. Accepts the
    /// full u64 length range without needing the source bytes.
    pub fn forLength(second_length: u64) CombineOperator {
        @setEvalBranchQuota(10000);
        var length = second_length;
        var factor: u32 = 0x80000000;
        var bit: usize = 0;
        while (length != 0) : (bit += 1) {
            if (length & 1 != 0) factor = multiplyPolynomial(byte_powers[bit], factor);
            length >>= 1;
        }
        return .{ .factor = factor };
    }

    /// Returns the checksum of the first sequence followed by the second. Supply their finalized
    /// checksums as `first` and `second`; the second sequence must have the length selected by
    /// `forLength`. The operator is unchanged and may be reused concurrently.
    pub fn apply(self: CombineOperator, first: u32, second: u32) u32 {
        return multiplyPolynomial(self.factor, first) ^ second;
    }
};

/// Returns the IEEE checksum of the concatenation of two byte sequences from their finalized
/// checksums. `second_length` is the exact byte length of the second sequence, including lengths
/// beyond addressable memory. Empty input has checksum zero. No source bytes, allocation or mutable
/// cache are needed.
pub fn combine(first: u32, second: u32, second_length: u64) u32 {
    return CombineOperator.forLength(second_length).apply(first, second);
}

test combine {
    const first = hash("1234");
    const second = hash("56789");
    try testing.expectEqual(@as(u32, 0xcbf43926), combine(first, second, 5));
}

const Fold = @Vector(2, u64);

const FoldResult = struct { value: Fold, position: usize };

// Fold input into one 128-bit polynomial. Eight independent lanes hide the multiply dependency for
// long spans; shorter spans use the same algebra with fewer lanes. The caller admits at least
// sixteen bytes and a target with carryless multiplication. Each fold's span is the byte distance
// between corresponding blocks; after the lanes join, reduce modulo the IEEE polynomial.
inline fn updateFolded(initial: u32, bytes: []const u8) u32 {
    var position: usize = 16;
    var folded: Fold = load(bytes[0..16]) ^ @as(Fold, .{ initial, 0 });
    if (wide_bytes > 16 and bytes.len >= 8 * wide_bytes) {
        const result = foldWide(bytes, initial);
        folded = result.value;
        position = result.position;
    } else if (wide_bytes > 16 and bytes.len >= wide_bytes) {
        const result = foldShortWide(bytes, initial);
        folded = result.value;
        position = result.position;
    } else if (bytes.len >= 128) {
        var lanes: [8]Fold = undefined;
        lanes[0] = folded;
        inline for (1..8) |lane| lanes[lane] = load(bytes[lane * 16 ..][0..16]);
        position = 128;
        while (bytes.len - position >= 128) : (position += 128) {
            inline for (0..8) |lane| {
                const next = load(bytes[position + lane * 16 ..][0..16]);
                lanes[lane] = fold(lanes[lane], next, 128);
            }
        }
        inline for (0..4) |lane| lanes[lane] = fold(lanes[lane], lanes[lane + 4], 64);
        inline for (0..2) |lane| lanes[lane] = fold(lanes[lane], lanes[lane + 2], 32);
        folded = fold(lanes[0], lanes[1], 16);
    }
    while (bytes.len - position >= 16) : (position += 16) {
        folded = fold(folded, load(bytes[position..][0..16]), 16);
    }
    if (shuffled_tail and position != bytes.len) {
        folded = foldTail(folded, bytes[bytes.len - 16 ..][0..16], bytes.len - position);
        position = bytes.len;
    }

    // Reduce the folded polynomial to the 32-bit remainder, then consume any scalar tail.
    const multipliers: Fold = .{ comptime power(159), comptime power(95) };
    folded = multiply(folded, multipliers, 0x10) ^ @as(Fold, .{ folded[1], 0 });
    const reduction: Fold = .{ comptime quotient95(), 0x1db710641 };
    const quotient = multiply(folded, reduction, 0x00);
    const product = multiply(quotient, reduction, 0x10);
    const crc: u32 = @truncate((folded ^ product)[1]);
    return @call(.always_inline, updateSmall, .{ crc, bytes[position..] });
}

inline fn foldWide(bytes: []const u8, crc: u32) FoldResult {
    const Wide = @Vector(wide_bytes / 8, u64);
    var lanes: [8]Wide = undefined;
    inline for (0..8) |lane| lanes[lane] = loadVector(bytes[lane * wide_bytes ..][0..wide_bytes]);
    lanes[0][0] ^= crc;
    var position: usize = 8 * wide_bytes;
    while (bytes.len - position >= 8 * wide_bytes) : (position += 8 * wide_bytes) {
        inline for (0..8) |lane| {
            const next = loadVector(bytes[position + lane * wide_bytes ..][0..wide_bytes]);
            lanes[lane] = foldVector(lanes[lane], next, 8 * wide_bytes);
        }
    }
    inline for (0..4) |lane| lanes[lane] = foldVector(lanes[lane], lanes[lane + 4], 4 * wide_bytes);
    inline for (0..2) |lane| lanes[lane] = foldVector(lanes[lane], lanes[lane + 2], 2 * wide_bytes);
    var value = foldVector(lanes[0], lanes[1], wide_bytes);
    while (bytes.len - position >= wide_bytes) : (position += wide_bytes) {
        const next = loadVector(bytes[position..][0..wide_bytes]);
        value = foldVector(value, next, wide_bytes);
    }
    return .{ .value = narrowVector(value), .position = position };
}

// Fold a short prefix in groups of four, two and one complete vectors. Every load stays within
// input; the returned position leaves any remaining bytes for the caller.
inline fn foldShortWide(bytes: []const u8, crc: u32) FoldResult {
    var first = loadVector(bytes[0..wide_bytes]);
    first[0] ^= crc;
    var position: usize = wide_bytes;
    if (bytes.len >= 2 * wide_bytes) {
        var second = loadVector(bytes[wide_bytes..][0..wide_bytes]);
        position = 2 * wide_bytes;
        if (bytes.len >= 4 * wide_bytes) {
            first = foldVector(
                first,
                loadVector(bytes[2 * wide_bytes ..][0..wide_bytes]),
                2 * wide_bytes,
            );
            second = foldVector(
                second,
                loadVector(bytes[3 * wide_bytes ..][0..wide_bytes]),
                2 * wide_bytes,
            );
            position = 4 * wide_bytes;
            if (bytes.len - position >= 2 * wide_bytes) {
                first = foldVector(
                    first,
                    loadVector(bytes[position..][0..wide_bytes]),
                    2 * wide_bytes,
                );
                second = foldVector(
                    second,
                    loadVector(bytes[position + wide_bytes ..][0..wide_bytes]),
                    2 * wide_bytes,
                );
                position += 2 * wide_bytes;
            }
        }
        first = foldVector(first, second, wide_bytes);
        if (bytes.len - position >= wide_bytes) {
            first = foldVector(first, loadVector(bytes[position..][0..wide_bytes]), wide_bytes);
            position += wide_bytes;
        }
    }
    return .{ .value = narrowVector(first), .position = position };
}

inline fn narrowVector(value: @Vector(wide_bytes / 8, u64)) Fold {
    const Pair = @Vector(4, u64);
    const pair: Pair = blk: {
        if (wide_bytes != 64) break :blk value;
        const low = @shuffle(u64, value, undefined, [4]i32{ 0, 1, 2, 3 });
        const high = @shuffle(u64, value, undefined, [4]i32{ 4, 5, 6, 7 });
        break :blk foldVector(low, high, 32);
    };
    const low = @shuffle(u64, pair, undefined, [2]i32{ 0, 1 });
    const high = @shuffle(u64, pair, undefined, [2]i32{ 2, 3 });
    return fold(low, high, 16);
}

inline fn foldVector(a: anytype, b: @TypeOf(a), comptime span: usize) @TypeOf(a) {
    const Wide = @TypeOf(a);
    const multipliers: Wide = comptime blk: {
        var words: [@typeInfo(Wide).vector.len]u64 = undefined;
        const low = power(span * 8 + 31);
        const high = power(span * 8 - 33);
        for (&words, 0..) |*word, index| word.* = if (index % 2 == 0) low else high;
        break :blk words;
    };
    const low = asm ("vpclmulqdq $0, %[b], %[a], %[out]"
        : [out] "=v" (-> Wide),
        : [a] "v" (a),
          [b] "v" (multipliers),
    );
    const high = asm ("vpclmulqdq $17, %[b], %[a], %[out]"
        : [out] "=v" (-> Wide),
        : [a] "v" (a),
          [b] "v" (multipliers),
    );
    return b ^ low ^ high;
}

fn loadVector(bytes: *const [wide_bytes]u8) @Vector(wide_bytes / 8, u64) {
    const packed_bytes: @Vector(wide_bytes, u8) = bytes.*;
    return @bitCast(packed_bytes);
}

inline fn fold(a: Fold, b: Fold, comptime span: usize) Fold {
    const multipliers: Fold = .{ comptime power(span * 8 + 31), comptime power(span * 8 - 33) };
    return b ^ multiply(a, multipliers, 0x00) ^ multiply(a, multipliers, 0x11);
}

// Previous folding consumed at least one complete block. The last sixteen input bytes include the
// unprocessed tail; overlapping that span avoids reading padding.
inline fn foldTail(value: Fold, last: *const [16]u8, remaining: usize) Fold {
    std.debug.assert(remaining >= 1 and remaining <= 15);
    const bytes: @Vector(16, u8) = @bitCast(value);
    const left_mask: @Vector(16, u8) = tail_shifts[remaining][0];
    const right_mask: @Vector(16, u8) = tail_shifts[remaining][1];
    const left = shuffleBytes(bytes, left_mask);
    const right = shuffleBytes(bytes, right_mask);
    const input: @Vector(16, u8) = last.*;
    const next = @select(u8, right_mask < @as(@Vector(16, u8), @splat(0x80)), right, input);
    return fold(@bitCast(left), @bitCast(next), 16);
}

// PSHUFB emits zero for mask bytes with their high bit set. The right mask selects retained
// remainder bytes; foldTail fills its zero lanes from the final input span.
const tail_shifts = blk: {
    var masks: [16][2][16]u8 = undefined;
    for (&masks, 0..) |*pair, remaining| {
        const padding = 16 - remaining;
        for (0..16) |index| {
            pair[0][index] = if (index >= padding) @intCast(index - padding) else 0x80;
            pair[1][index] = if (index < padding) @intCast(index + remaining) else 0x80;
        }
    }
    break :blk masks;
};

inline fn shuffleBytes(bytes: @Vector(16, u8), mask: @Vector(16, u8)) @Vector(16, u8) {
    if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx)) {
        return asm ("vpshufb %[mask], %[bytes], %[out]"
            : [out] "=x" (-> @Vector(16, u8)),
            : [bytes] "x" (bytes),
              [mask] "x" (mask),
        );
    }
    return asm ("pshufb %[mask], %[out]"
        : [out] "=x" (-> @Vector(16, u8)),
        : [bytes] "0" (bytes),
          [mask] "x" (mask),
    );
}

fn load(bytes: *const [16]u8) Fold {
    const packed_bytes: @Vector(16, u8) = bytes.*;
    return @bitCast(packed_bytes);
}

inline fn multiply(a: Fold, b: Fold, comptime selector: u8) Fold {
    if (pmull) {
        const right: Fold = if (selector == 0x10) .{ b[1], 0 } else b;
        // Normalize big-endian SIMD lane bytes at the assembly boundary.
        const big_endian = builtin.cpu.arch == .aarch64_be;
        const product = asm (switch (selector) {
                0x00, 0x10 => "pmull %[out].1q, %[a].1d, %[b].1d",
                0x11 => "pmull2 %[out].1q, %[a].2d, %[b].2d",
                else => @compileError("unsupported polynomial lane selector"),
            }
            : [out] "=w" (-> Fold),
            : [a] "w" (if (big_endian) @byteSwap(a) else a),
              [b] "w" (if (big_endian) @byteSwap(right) else right),
        );
        return if (big_endian) @byteSwap(product) else product;
    }
    if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx)) {
        return asm (std.fmt.comptimePrint("vpclmulqdq ${d}, %[b], %[a], %[out]", .{selector})
            : [out] "=x" (-> Fold),
            : [a] "x" (a),
              [b] "x" (b),
        );
    }
    return asm (std.fmt.comptimePrint("pclmulqdq ${d}, %[b], %[out]", .{selector})
        : [out] "=x" (-> Fold),
        : [a] "0" (a),
          [b] "x" (b),
    );
}

fn armCrc(initial: u32, bytes: []const u8) u32 {
    var crc = initial;
    var position: usize = 0;
    while (bytes.len - position >= 8) : (position += 8) {
        const word = std.mem.readInt(u64, bytes[position..][0..8], .little);
        crc = armCrcWord(crc, word);
    }

    inline for (.{ u32, u16, u8 }) |Word| {
        const size = @sizeOf(Word);
        if (bytes.len - position >= size) {
            crc = armCrcWord(crc, std.mem.readInt(Word, bytes[position..][0..size], .little));
            position += size;
        }
    }
    return crc;
}

inline fn armCrcWord(initial: u32, word: anytype) u32 {
    return asm (switch (@TypeOf(word)) {
            u64 => "crc32x %[out:w], %[crc:w], %[word]",
            u32 => "crc32w %[out:w], %[crc:w], %[word:w]",
            u16 => "crc32h %[out:w], %[crc:w], %[word:w]",
            u8 => "crc32b %[out:w], %[crc:w], %[word:w]",
            else => @compileError("unsupported CRC32 operand width"),
        }
        : [out] "=r" (-> u32),
        : [crc] "r" (initial),
          [word] "r" (if (@TypeOf(word) == u64) word else @as(u32, word)),
    );
}

// Eight tables encode the contribution of each byte position in a little-endian word. XORing those
// contributions advances eight bytes without eight serial table lookups. This portable path also
// owns tails on targets without an IEEE CRC instruction.
fn sliced(initial: u32, bytes: []const u8) u32 {
    var crc = initial;
    var position: usize = 0;
    while (bytes.len - position >= 8) : (position += 8) {
        const word = std.mem.readInt(u64, bytes[position..][0..8], .little) ^ crc;
        crc = 0;
        inline for (0..8) |byte| crc ^= tables[7 - byte][@as(u8, @truncate(word >> (8 * byte)))];
    }
    for (bytes[position..]) |byte| crc = tables[0][@as(u8, @truncate(crc)) ^ byte] ^ (crc >> 8);
    return crc;
}

const tables = blk: {
    @setEvalBranchQuota(30000);
    var result: [8][256]u32 = undefined;
    for (0..256) |index| {
        var crc: u32 = @intCast(index);
        for (0..8) |_| {
            const reduction: u32 = if (crc & 1 != 0) reflected_polynomial else 0;
            crc = (crc >> 1) ^ reduction;
        }
        result[0][index] = crc;
    }
    for (1..8) |slice| for (0..256) |index| {
        const previous = result[slice - 1][index];
        result[slice][index] = result[0][@as(u8, @truncate(previous))] ^ (previous >> 8);
    };
    break :blk result;
};

// Reflected polynomial multiplication: bit 31 is x^0. Derived from the IEEE polynomial; the
// independent matrix oracle in the tests uses another basis.
fn multiplyPolynomial(left: u32, right: u32) u32 {
    var a = left;
    var b = right;
    var result: u32 = 0;
    while (a != 0) : (a <<= 1) {
        if (a & 0x80000000 != 0) result ^= b;
        b = (b >> 1) ^ (reflected_polynomial & (0 -% (b & 1)));
    }
    return result;
}

const byte_powers: [64]u32 = blk: {
    @setEvalBranchQuota(10000);
    var powers: [64]u32 = undefined;
    var first: u32 = 0x80000000;
    for (0..8) |_| first = (first >> 1) ^ (reflected_polynomial & (0 -% (first & 1)));
    powers[0] = first;
    for (1..64) |i| powers[i] = multiplyPolynomial(powers[i - 1], powers[i - 1]);
    break :blk powers;
};

// Reflected representation of x^exponent mod G(x), G = x^32 + 0x04c11db7.
fn power(comptime exponent: usize) u32 {
    @setEvalBranchQuota(500000);
    var remainder: u64 = 1;
    for (0..exponent) |_| {
        remainder <<= 1;
        if (remainder & (1 << 32) != 0) remainder ^= polynomial;
    }
    return @bitReverse(@as(u32, @intCast(remainder)));
}

// Reflected quotient of x^95 / G(x), used by the final polynomial reduction.
fn quotient95() u64 {
    var numerator: u128 = @as(u128, 1) << 95;
    var quotient: u64 = 0;
    for (0..64) |index| {
        const shift: u7 = @intCast(63 - index);
        if (numerator & (@as(u128, 1) << (32 + shift)) != 0) {
            numerator ^= @as(u128, polynomial) << shift;
            quotient ^= @as(u64, 1) << @as(u6, @intCast(shift));
        }
    }
    return @bitReverse(quotient);
}

// Independent bit recurrence; keep its polynomial literal separate from production constants.
fn bitwiseRemainder(initial: u32, bytes: []const u8) u32 {
    var remainder = initial;
    for (bytes) |byte| {
        remainder ^= byte;
        for (0..8) |_| {
            const reduction: u32 = if (remainder & 1 != 0) 0xedb88320 else 0;
            remainder = (remainder >> 1) ^ reduction;
        }
    }
    return remainder;
}

// Independent GF(2) matrix exponentiation on the unfinalized bit recurrence. Columns represent the
// images of individual CRC bits, unlike the production reflected polynomial multiplier. Squaring
// advances twice as many zero bytes.
fn matrixCombine(first: u32, second: u32, length: u64) u32 {
    const Matrix = struct {
        fn times(matrix: [32]u32, vector: u32) u32 {
            var result: u32 = 0;
            for (0..32) |i| {
                if (vector & (@as(u32, 1) << @intCast(i)) != 0) result ^= matrix[i];
            }
            return result;
        }
    };
    var matrix: [32]u32 = undefined;
    for (&matrix, 0..) |*column, i| {
        column.* = @as(u32, 1) << @intCast(i);
        for (0..8) |_| {
            const reduction: u32 = if (column.* & 1 != 0) 0xedb88320 else 0;
            column.* = (column.* >> 1) ^ reduction;
        }
    }
    var remaining = length;
    var advanced = first;
    while (remaining != 0) : (remaining >>= 1) {
        if (remaining & 1 != 0) advanced = Matrix.times(matrix, advanced);
        var squared: [32]u32 = undefined;
        for (&squared, matrix) |*column, value| column.* = Matrix.times(matrix, value);
        matrix = squared;
    }
    return advanced ^ second;
}

test "CRC32 known IEEE facts and continued finalization" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(Hasher));
    try testing.expectEqual(@as(u32, 0), hash(""));
    try testing.expectEqual(@as(u32, 0xcbf43926), hash("123456789"));

    var state: Hasher = .init;
    state.update("1234");
    try testing.expectEqual(std.hash.Crc32.hash("1234"), state.final());
    const prefix = state.final();

    var copy = state;
    copy.update("abcd");
    try testing.expectEqual(std.hash.Crc32.hash("1234abcd"), copy.final());
    try testing.expectEqual(prefix, state.final());

    state.update("");
    state.update("56789");
    try testing.expectEqual(@as(u32, 0xcbf43926), state.final());

    state = .init;
    try testing.expectEqual(@as(u32, 0), state.final());
}

test "CRC32 exact alignment lengths chunks and independent bitwise oracle" {
    const backing = try testing.allocator.alloc(u8, 4096 + 32);
    defer testing.allocator.free(backing);
    for (backing, 0..) |*byte, index| byte.* = @truncate(index *% 73 +% (index >> 3));

    const lengths = blk: {
        const short = [_]usize{ 0, 1, 7, 8, 9, 15, 16, 17, 31, 32, 63, 64 };
        const blocks = [_]usize{ 127, 128, 129, 255, 256, 257, 511, 512 };
        const tails = [_]usize{
            513, 514, 515, 516, 517, 518, 519, 520, 521, 522, 523, 524, 525, 526, 527,
        };
        const large = [_]usize{ 1023, 4096 };
        break :blk short ++ blocks ++ tails ++ large;
    };
    for (0..32) |alignment| {
        for (lengths) |length| {
            const data = backing[alignment..][0..length];
            const expected = ~bitwiseRemainder(0xffffffff, data);
            try testing.expectEqual(expected, hash(data));
            for ([_]usize{ 1, 7, 16, 31, 128, 257 }) |chunk| {
                var state: Hasher = .init;
                var position: usize = 0;
                while (position < data.len) {
                    const end = position + @min(chunk, data.len - position);
                    state.update(data[position..end]);
                    position = end;
                }
                try testing.expectEqual(expected, state.final());
            }
        }
    }
}

test "CRC32 short vector admission every length alignment and incremental boundary" {
    const bytes = try testing.allocator.alloc(u8, 1024 + 64);
    defer testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index *% 197 +% (index >> 2));

    for (0..32) |alignment| {
        var oracle: u32 = 0xffffffff;
        for (0..1025) |length| {
            const data = bytes[alignment..][0..length];
            if (length != 0) oracle = bitwiseRemainder(oracle, data[length - 1 ..]);
            try testing.expectEqual(~oracle, hash(data));
            for ([_]usize{ 31, 63, 127, 255, 511 }) |split| {
                var state: Hasher = .init;
                const at = @min(split, length);
                state.update(data[0..at]);
                state.update(data[at..]);
                try testing.expectEqual(~oracle, state.final());
            }
        }
    }
}

test "CRC32 exact input ends stay within Linux protected pages" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
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
        try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(result));
    }

    const bytes = mapping[page..][0 .. 2 * page];
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index *% 149 +% (index >> 5));
    for (0..1025) |size| {
        for ([_][]const u8{ bytes[0..size], bytes[bytes.len - size ..] }) |input| {
            const expected = std.hash.Crc32.hash(input);
            try testing.expectEqual(expected, hash(input));
            var state: Hasher = .init;
            const split = @min(7, size);
            state.update(input[0..split]);
            state.update(input[split..]);
            try testing.expectEqual(expected, state.final());
        }
    }
    try testing.expectEqual(std.hash.Crc32.hash(bytes), hash(bytes));
}

test "CRC32 combining every split and reusable chunk operators" {
    var bytes: [1031]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i * 31 + 17);
    for ([_]usize{ 0, 1, 7, 16, 31, 32, 127, 1024, 1031 }) |length| {
        const expected = hash(bytes[0..length]);
        for (0..length + 1) |split| {
            const first = hash(bytes[0..split]);
            const second = hash(bytes[split..length]);
            const operator = CombineOperator.forLength(length - split);
            try testing.expectEqual(expected, combine(first, second, length - split));
            try testing.expectEqual(expected, operator.apply(first, second));
            try testing.expectEqual(second, operator.apply(0, second));
        }
    }

    const operator = CombineOperator.forLength(64);
    var combined: u32 = 0;
    for (0..16) |i| combined = operator.apply(combined, hash(bytes[i * 64 ..][0..64]));
    try testing.expectEqual(hash(bytes[0..1024]), combined);
}

test "CRC32 combining full u64 lengths matches independent matrix oracle" {
    const maximum = std.math.maxInt(u64);
    const cached = comptime CombineOperator.forLength(maximum);
    try testing.expectEqual(
        matrixCombine(0x12345678, 0x87654321, maximum),
        cached.apply(0x12345678, 0x87654321),
    );

    const lengths = blk: {
        const small = [_]u64{ 0, 1, 2, 65521 };
        const word_boundary = [_]u64{ 0xffffffff, 0x100000000 };
        const wide_boundary = [_]u64{ 0x7fffffffffffffff, 0x8000000000000000, 0xffffffffffffffff };
        break :blk small ++ word_boundary ++ wide_boundary;
    };
    for (lengths) |length| {
        for ([_]u32{ 0, 1, 0x12345678, 0xffffffff }) |first| {
            for ([_]u32{ 0, 0x87654321, 0xffffffff }) |second| {
                const expected = matrixCombine(first, second, length);
                try testing.expectEqual(expected, combine(first, second, length));
            }
        }
    }
    for (0..64) |bit| {
        const length = @as(u64, 1) << @intCast(bit);
        try testing.expectEqual(
            matrixCombine(0x89abcdef, 0x76543210, length),
            combine(0x89abcdef, 0x76543210, length),
        );
    }
}
