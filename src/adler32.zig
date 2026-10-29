//! Computes RFC 1950 Adler-32 checksums over exact caller bytes without allocation. Use `hash` for
//! a complete buffer or append fragments to a caller-owned `Hasher` state.
//!
//! Updates consume their input without retaining it. Empty and unaligned fragments need no padding,
//! and chunk boundaries do not affect the result. `final` returns a snapshot without resetting the
//! stream. Empty input has checksum one.
//!
//! The result is a numeric u32; zlib encodes it in big-endian byte order. `combine` computes the
//! checksum of two concatenated sequences from their checksums and the second sequence's length,
//! without rereading either sequence. `CombineOperator` reuses that operation for a fixed length.
//! See `Hasher.update` for incremental input and `hash` for checksum byte encoding.
//!
//! CPU features follow the compile-time target. Algorithm: https://www.rfc-editor.org/rfc/rfc1950

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

// Eric Biggers' libdeflate 1.26 is a research reference for delayed weighting and byte dot
// products. This implementation expresses the checksum contributions with Zig vectors; arithmetic
// and reduction bounds follow RFC 1950. Portable columns, x86 SSE2/AVX2 and LLVM VNNI paths all
// read only supplied bytes.
// https://github.com/ebiggers/libdeflate/blob/92e6a0d/lib/x86/adler32_template.h

const modulus = 65521;
// Maximum bytes before reducing u32 sums, including the largest reduced incoming state.
const max_chunk_bytes = 5552;

const is_x86 = builtin.cpu.arch == .x86 or builtin.cpu.arch == .x86_64;
const sse2 = is_x86 and std.Target.x86.featureSetHas(builtin.cpu.features, .sse2);

// The wider assembly kernels require LLVM; other backends retain bounded columns.
const avx2 = blk: {
    if (!sse2 or builtin.zig_backend != .stage2_llvm) break :blk false;
    break :blk std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
};
const evex_vnni = avx2 and std.Target.x86.featureSetHasAll(builtin.cpu.features, &.{
    .avx512vnni, .avx512vl,
});
const vnni = blk: {
    if (!avx2) break :blk false;
    if (std.Target.x86.featureSetHas(builtin.cpu.features, .avxvnni)) break :blk true;

    break :blk evex_vnni;
};
const dot_bytes: usize = blk: {
    if (!vnni) break :blk 32;

    const wide_dots = std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vnni);
    const byte_masks = std.Target.x86.featureSetHas(builtin.cpu.features, .avx512bw);
    break :blk if (wide_dots and byte_masks) 64 else 32;
};
const column_bytes = if (avx2) 32 else 16;
// Masked byte loads skip inactive memory lanes. Narrow EVEX loads also require AVX-512VL.
const masked_tail = blk: {
    if (!vnni) break :blk false;
    if (!std.Target.x86.featureSetHas(builtin.cpu.features, .avx512bw)) break :blk false;
    break :blk dot_bytes == 64 or std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vl);
};

/// Eight-byte incremental state. Copies continue independently; assigning `.init` resets the
/// stream. Retains no input or allocator and needs no cleanup. Serialize mutation of a shared
/// state.
pub const Hasher = struct {
    /// Byte sum plus one, reduced modulo 65521.
    first: u32 = 1,
    /// Sum of successive `first` values, reduced modulo 65521.
    second: u32 = 0,

    /// Starts an empty stream with checksum one.
    pub const init: Hasher = .{};

    /// Appends bytes without retaining them or reading padding. Empty and unaligned spans are
    /// accepted. Start with `.init` or a valid copy and keep both sums reduced modulo 65521.
    pub fn update(self: *Hasher, bytes: []const u8) void {
        if (vnni and bytes.len >= 4 * dot_bytes) {
            return @call(.always_inline, updateDots, .{ self, bytes });
        }

        // One to three vectors plus a substantial remainder amortize a dedicated short kernel. Full
        // vectors and tails shorter than sixteen bytes retain the column route.
        if (masked_tail and bytes.len % dot_bytes >= 16) {
            return @call(.always_inline, updateShortDots, .{ self, bytes });
        }

        @call(.always_inline, updateColumns, .{ self, bytes });
    }

    test update {
        const chunks = [_][]const u8{ "123", "456", "789" };
        var state: Hasher = .init;
        for (chunks) |chunk| state.update(chunk);

        try testing.expectEqual(@as(u32, 0x091e01de), state.final());
    }

    /// Returns a snapshot without resetting the stream. The low 16 bits contain the byte sum and
    /// the high 16 bits contain the prefix sum.
    pub fn final(self: Hasher) u32 {
        return (self.second << 16) | self.first;
    }
};

/// Computes the numeric checksum of one complete buffer without allocation or retained input. zlib
/// stores this integer in big-endian order; the doctest writes those bytes into caller-owned footer
/// storage.
pub fn hash(bytes: []const u8) u32 {
    var state: Hasher = .init;
    // Inlining lets LLVM specialize the initial sums even when a caller also uses incremental
    // updates.
    @call(.always_inline, Hasher.update, .{ &state, bytes });
    return state.final();
}

test hash {
    var footer: [4]u8 = undefined;
    std.mem.writeInt(u32, &footer, hash("123456789"), .big);

    try testing.expectEqual([4]u8{ 0x09, 0x1e, 0x01, 0xde }, footer);
}

/// Immutable reduced length for combining repeated second-chunk sizes. Copies can be shared across
/// threads; construction and use allocate nothing.
pub const CombineOperator = struct {
    /// Initialize with `forLength` to store the second sequence's byte length modulo 65521.
    length_mod: u32,

    /// Reduces the second sequence's byte length modulo the Adler prime.
    pub fn forLength(second_length: u64) CombineOperator {
        return .{ .length_mod = @intCast(second_length % modulus) };
    }

    /// Returns the checksum of the first sequence followed by the second. Supply their finalized
    /// checksums as `first` and `second`; the second sequence must have the length selected by
    /// `forLength`. Neither sequence's original bytes are needed.
    pub fn apply(self: CombineOperator, first: u32, second: u32) u32 {
        // Both first sums include the initial one. Adding modulus - 1 removes it without underflow.
        const first_sum = first & 0xffff;
        const low = (first_sum + (second & 0xffff) + (modulus - 1)) % modulus;

        // Every byte in the second sequence adds the first sequence's byte sum to the prefix sum.
        const shifted_prefix = @as(u64, self.length_mod) * (first_sum + (modulus - 1));
        const high: u32 = @intCast((shifted_prefix + (first >> 16) + (second >> 16)) % modulus);
        return (high << 16) | low;
    }
};

/// Returns the checksum of concatenated sequences from their finalized checksums and the exact byte
/// length of the second sequence. Accepts the full u64 length range. Empty input has checksum one.
pub fn combine(first: u32, second: u32, second_length: u64) u32 {
    return CombineOperator.forLength(second_length).apply(first, second);
}

const ColumnBytes = @Vector(column_bytes, u8);
const Columns = @Vector(column_bytes / 2, u16);
const ColumnSums = @Vector(column_bytes / 8, u64);
const ColumnPairs = @Vector(column_bytes / 4, u32);

// A block of n bytes changes first by their sum and second by n*first plus a weighted sum: the
// first byte has weight n, the last weight one. Columns accumulate equal positions across blocks;
// prefixes account for earlier complete blocks. This removes the per-byte dependency from the inner
// loop without changing the checksum recurrence.
fn updateColumns(self: *Hasher, bytes: []const u8) void {
    const block_bytes = 2 * column_bytes;
    const chunk_bytes = blk: {
        // pmaddwd multiplies signed i16 lanes, so column values must stay below 32768.
        const column_limit = (32767 / 255) * block_bytes;
        const safe_bytes = @min(max_chunk_bytes, column_limit);
        break :blk safe_bytes / block_bytes * block_bytes;
    };

    var first = self.first;
    var second = self.second;
    var position: usize = 0;

    while (position < bytes.len) {
        const start = position;
        const end = position + @min(bytes.len - position, chunk_bytes);
        var columns_a: Columns = @splat(0);
        var columns_b: Columns = @splat(0);
        var columns_c: Columns = @splat(0);
        var columns_d: Columns = @splat(0);
        var sums: ColumnSums = @splat(0);
        var prefixes: ColumnSums = @splat(0);

        while (end - position >= block_bytes) : (position += block_bytes) {
            const a: ColumnBytes = bytes[position..][0..column_bytes].*;
            const b: ColumnBytes = bytes[position + column_bytes ..][0..column_bytes].*;
            prefixes += sums;
            sums += sumBytes(a) + sumBytes(b);

            columns_a += widenHalf(a, false);
            columns_b += widenHalf(a, true);
            columns_c += widenHalf(b, false);
            columns_d += widenHalf(b, true);
        }

        const weighted_a = weightPairs(columns_a, comptime columnWeights(0));
        const weighted_b = weightPairs(columns_b, comptime columnWeights(1));
        const weighted_c = weightPairs(columns_c, comptime columnWeights(2));
        const weighted_d = weightPairs(columns_d, comptime columnWeights(3));
        const weighted = weighted_a + weighted_b + weighted_c + weighted_d;

        second += blk: {
            const processed_bytes: u32 = @intCast(position - start);
            const incoming_sum = processed_bytes * first;
            const prefix_sum: u32 = @intCast(@reduce(.Add, prefixes));
            break :blk incoming_sum + block_bytes * prefix_sum + @reduce(.Add, weighted);
        };
        first += @intCast(@reduce(.Add, sums));

        while (position < end) : (position += 1) {
            first += bytes[position];
            second += first;
        }

        first %= modulus;
        second %= modulus;
    }

    self.first = first;
    self.second = second;
}

fn sumBytes(value: ColumnBytes) ColumnSums {
    if (avx2) return asm ("vpsadbw %[zero], %[value], %[result]"
        : [result] "=x" (-> ColumnSums),
        : [value] "x" (value),
          [zero] "x" (@as(ColumnBytes, @splat(0))),
    );
    if (sse2) return asm ("psadbw %[zero], %[value]"
        : [result] "=x" (-> ColumnSums),
        : [value] "0" (value),
          [zero] "x" (@as(ColumnBytes, @splat(0))),
    );
    return .{ @reduce(.Add, widenHalf(value, false)), @reduce(.Add, widenHalf(value, true)) };
}

fn widenHalf(value: ColumnBytes, comptime high: bool) Columns {
    // Keep the complete load shared with psadbw, rather than reloading four halves.
    if (avx2) return asm ((if (high) "vpunpckhbw" else "vpunpcklbw") ++
            " %[zero], %[value], %[result]"
        : [result] "=x" (-> Columns),
        : [value] "x" (value),
          [zero] "x" (@as(ColumnBytes, @splat(0))),
    );
    if (sse2) return asm ((if (high) "punpckhbw" else "punpcklbw") ++ " %[zero], %[value]"
        : [result] "=x" (-> Columns),
        : [value] "0" (value),
          [zero] "x" (@as(ColumnBytes, @splat(0))),
    );
    const indices: @Vector(8, i32) = blk: {
        if (high) break :blk .{ 8, 9, 10, 11, 12, 13, 14, 15 };
        break :blk .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    };
    return @as(Columns, @shuffle(u8, value, undefined, indices));
}

fn columnWeights(comptime group: usize) Columns {
    var weights: [column_bytes / 2]u16 = undefined;
    for (&weights, 0..) |*weight, index| {
        // Unpack instructions interleave within each 128-bit lane, also on AVX2.
        const source_index = blk: {
            const vector_start = (group / 2) * column_bytes;
            const half_start = (group % 2) * 8;
            const lane_start = (index / 8) * 16;
            break :blk vector_start + half_start + lane_start + index % 8;
        };
        weight.* = @intCast(2 * column_bytes - source_index);
    }
    return weights;
}

fn weightPairs(columns: Columns, weights: Columns) ColumnPairs {
    if (avx2) return asm ("vpmaddwd %[weights], %[columns], %[result]"
        : [result] "=x" (-> ColumnPairs),
        : [columns] "x" (columns),
          [weights] "x" (weights),
    );
    if (sse2) return asm ("pmaddwd %[weights], %[columns]"
        : [result] "=x" (-> ColumnPairs),
        : [columns] "0" (columns),
          [weights] "x" (weights),
    );
    const products = @as(@Vector(8, u32), columns) * @as(@Vector(8, u32), weights);
    const even = @shuffle(u32, products, undefined, @as(@Vector(4, i32), .{ 0, 2, 4, 6 }));
    const odd = @shuffle(u32, products, undefined, @as(@Vector(4, i32), .{ 1, 3, 5, 7 }));
    return even + odd;
}

const DotBytes = @Vector(dot_bytes, u8);
const DotSums = @Vector(dot_bytes / 4, u32);
const dot_weights: DotBytes = blk: {
    var weights: [dot_bytes]u8 = undefined;
    for (&weights, 0..) |*weight, index| weight.* = @intCast(dot_bytes - index);
    break :blk weights;
};

// VNNI sums four unsigned-byte/signed-byte products into each u32 lane. One dot product uses unit
// weights for the byte sum; another uses descending position weights for the prefix sum. Four
// independent chains expose parallel work, then the algebra below restores their order.
fn updateDots(self: *Hasher, bytes: []const u8) void {
    const group_bytes = 4 * dot_bytes;
    const chunk_bytes = max_chunk_bytes / group_bytes * group_bytes;
    var first = self.first;
    var second = self.second;
    var position: usize = 0;

    if (bytes.len > 65536) {
        // Align large inputs to avoid split loads. Reduce the scalar prefix before a full chunk.
        const prefix_bytes = (0 -% @intFromPtr(bytes.ptr)) & (dot_bytes - 1);
        if (prefix_bytes != 0) {
            while (position < prefix_bytes) : (position += 1) {
                first += bytes[position];
                second += first;
            }
            first %= modulus;
            second %= modulus;
        }
    }

    while (position < bytes.len) {
        // Four independent dot-product chains share one prefix accumulation. Whole groups keep
        // intermediate reductions out of the serial tail loop.
        const end = position + @min(bytes.len - position, chunk_bytes);
        const start = position;
        var sums: [4]DotSums = @splat(@splat(0));
        var weighted: [4]DotSums = @splat(@splat(0));
        var prefixes: DotSums = @splat(0);

        while (end - position >= group_bytes) : (position += group_bytes) {
            prefixes += (sums[0] + sums[1]) + (sums[2] + sums[3]);
            inline for (0..4) |group| {
                const data: DotBytes = bytes[position + group * dot_bytes ..][0..dot_bytes].*;
                weighted[group] = dotBytes(weighted[group], data, dot_weights);
                sums[group] = dotBytes(sums[group], data, @splat(1));
            }
        }

        // Bytes in the first vector also contribute to three later vectors, then two, then one.
        const within_group = blk: {
            const first_vector = sums[0] * @as(DotSums, @splat(3));
            const second_vector = sums[1] * @as(DotSums, @splat(2));
            break :blk first_vector + second_vector + sums[2];
        };
        const group_prefixes = prefixes * @as(DotSums, @splat(group_bytes));
        const vector_prefixes = within_group * @as(DotSums, @splat(dot_bytes));
        const group_weighted = (weighted[0] + weighted[1]) + (weighted[2] + weighted[3]);
        var weighted_sums = group_weighted + group_prefixes + vector_prefixes;
        var byte_sums = (sums[0] + sums[1]) + (sums[2] + sums[3]);

        while (end - position >= dot_bytes) : (position += dot_bytes) {
            const data: DotBytes = bytes[position..][0..dot_bytes].*;
            weighted_sums += byte_sums * @as(DotSums, @splat(dot_bytes));
            weighted_sums = dotBytes(weighted_sums, data, dot_weights);
            byte_sums = dotBytes(byte_sums, data, @splat(1));
        }

        if (masked_tail and end - position >= 16) {
            const count: u8 = @intCast(end - position);
            const data = loadMaskedTail(bytes.ptr + position, count);
            // Zero lanes beyond the real tail contribute nothing. Wrapping byte weights are
            // positive for every active byte and ignored elsewhere.
            const weight_offset = count -% @as(u8, dot_bytes);
            const tail_weights = dot_weights +% @as(DotBytes, @splat(weight_offset));
            weighted_sums += byte_sums * @as(DotSums, @splat(count));
            weighted_sums = dotBytes(weighted_sums, data, tail_weights);
            byte_sums = dotBytes(byte_sums, data, @splat(1));
            position = end;
        }

        const processed_bytes: u32 = @intCast(position - start);
        second += processed_bytes * first + @reduce(.Add, weighted_sums);
        first += @reduce(.Add, byte_sums);

        while (position < end) : (position += 1) {
            first += bytes[position];
            second += first;
        }
        first %= modulus;
        second %= modulus;
    }

    self.first = first;
    self.second = second;
}

// A short update needs no four-chain accumulation or chunk loop. Prefix sums account for complete
// vectors before the masked final span. All weights on active bytes are positive; inactive bytes
// are zero. At most 255 input bytes and reduced incoming sums keep both final scalar contributions
// inside u32.
fn updateShortDots(self: *Hasher, bytes: []const u8) void {
    std.debug.assert(bytes.len < 4 * dot_bytes and bytes.len % dot_bytes >= 16);
    var byte_sums: DotSums = @splat(0);
    var weighted_sums: DotSums = @splat(0);
    var position: usize = 0;

    while (bytes.len - position >= dot_bytes) : (position += dot_bytes) {
        const data: DotBytes = bytes[position..][0..dot_bytes].*;
        weighted_sums += byte_sums * @as(DotSums, @splat(dot_bytes));
        weighted_sums = dotBytes(weighted_sums, data, dot_weights);
        byte_sums = dotBytes(byte_sums, data, @splat(1));
    }

    const count: u8 = @intCast(bytes.len - position);
    const tail = loadMaskedTail(bytes.ptr + position, count);
    const weight_offset = count -% @as(u8, dot_bytes);
    const tail_weights = dot_weights +% @as(DotBytes, @splat(weight_offset));
    weighted_sums += byte_sums * @as(DotSums, @splat(count));
    weighted_sums = dotBytes(weighted_sums, tail, tail_weights);
    byte_sums = dotBytes(byte_sums, tail, @splat(1));

    const processed_bytes: u32 = @intCast(bytes.len);
    const prefix_sum = @reduce(.Add, weighted_sums);
    self.second = (self.second + processed_bytes * self.first + prefix_sum) % modulus;
    self.first = (self.first + @reduce(.Add, byte_sums)) % modulus;
}

fn dotBytes(sum: DotSums, bytes: DotBytes, weights: DotBytes) DotSums {
    // Unsigned bytes times signed weights, with four products per u32 lane. Full-vector weights are
    // positive; masked tails zero every inactive lane.
    if (dot_bytes == 32 and !evex_vnni) {
        // The plain mnemonic selects EVEX even on an AVX-VNNI-only target. VEX must be explicit,
        // and its operands must stay in the low sixteen vector registers.
        return asm ("{vex} vpdpbusd %[weights], %[bytes], %[sum]"
            : [result] "=x" (-> DotSums),
            : [sum] "0" (sum),
              [bytes] "x" (bytes),
              [weights] "x" (weights),
        );
    }
    return asm ("vpdpbusd %[weights], %[bytes], %[sum]"
        : [result] "=v" (-> DotSums),
        : [sum] "0" (sum),
          [bytes] "v" (bytes),
          [weights] "v" (weights),
    );
}

// The nonzero mask admits exactly count real source bytes and zeros all other lanes, including
// across an inaccessible page. The LLVM ^Yk constraint selects a nonzero mask register; k0 cannot
// mask this instruction.
fn loadMaskedTail(source: [*]const u8, count: u8) DotBytes {
    std.debug.assert(count > 0 and count < dot_bytes);
    const mask = (@as(u64, 1) << @as(u6, @intCast(count))) - 1;
    return asm ("vmovdqu8 (%[source]), %[result] {%[mask]}{z}"
        : [result] "=v" (-> DotBytes),
        : [source] "r" (source),
          [mask] "^Yk" (mask),
        : .{ .memory = true });
}

// Python zlib 1.3.2 facts: zlib.adler32(bytes([255]) * length). Maximum byte values stress vector
// columns, weighted sums and modular reductions.
const maximum_byte_facts = [_]struct {
    length: usize,
    expected: u32,
}{
    .{ .length = 0, .expected = 0x00000001 },
    .{ .length = 1, .expected = 0x01000100 },
    .{ .length = 31, .expected = 0xee3e1ee2 },
    .{ .length = 32, .expected = 0x0e2e1fe1 },
    .{ .length = 63, .expected = 0xd8c83ec2 },
    .{ .length = 64, .expected = 0x18983fc1 },
    .{ .length = 127, .expected = 0xa2907e82 },
    .{ .length = 128, .expected = 0x22207f81 },
    .{ .length = 255, .expected = 0x08f0fe02 },
    .{ .length = 256, .expected = 0x0800ff01 },
    .{ .length = 257, .expected = 0x080f000f },
    .{ .length = 4095, .expected = 0x9070efe3 },
    .{ .length = 4096, .expected = 0x8161f0e2 },
    .{ .length = 4097, .expected = 0x7351f1e1 },
    .{ .length = 5375, .expected = 0xfe2aeb2e },
    .{ .length = 5376, .expected = 0xea66ec2d },
    .{ .length = 5377, .expected = 0xd7a1ed2c },
    .{ .length = 5503, .expected = 0xbdb46abd },
    .{ .length = 5504, .expected = 0x297f6bbc },
    .{ .length = 5505, .expected = 0x963a6cbb },
    .{ .length = 5551, .expected = 0x56039a8d },
    .{ .length = 5552, .expected = 0xf18f9b8c },
    .{ .length = 5553, .expected = 0x8e299c8b },
    .{ .length = 11103, .expected = 0xc8493627 },
    .{ .length = 11104, .expected = 0xff6f3726 },
    .{ .length = 11105, .expected = 0x37a33825 },
    .{ .length = 16383, .expected = 0xed18c2b3 },
    .{ .length = 16384, .expected = 0xb0d9c3b2 },
    .{ .length = 16385, .expected = 0x7599c4b1 },
    .{ .length = 32767, .expected = 0xf8418673 },
    .{ .length = 32768, .expected = 0x7fc28772 },
    .{ .length = 32769, .expected = 0x08428871 },
    .{ .length = 65536, .expected = 0x77970ef2 },
    .{ .length = 65537, .expected = 0x87880ff1 },
    .{ .length = 65599, .expected = 0xfdea4db3 },
    .{ .length = 65600, .expected = 0x4cab4eb2 },
    .{ .length = 131072, .expected = 0xcf5c1de3 },
};

// Independent closed form for N copies of one byte: s1 = 1 + N*b, s2 = N + b*N*(N+1)/2. u128 holds
// the triangular number at the maximum u64 length. Reduce it before multiplying by the byte value
// to avoid overflowing u128.
fn repeatedByteChecksum(byte: u8, length: u64) u32 {
    const count: u128 = length;
    const reduced_count = count % 65521;
    const triangle = (count * (count + 1) / 2) % 65521;
    const first: u32 = @intCast((1 + reduced_count * byte) % 65521);
    const second: u32 = @intCast((reduced_count + triangle * byte) % 65521);
    return (second << 16) | first;
}

test "Adler32 known facts snapshots copies and reset" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Hasher));
    try testing.expectEqual(@as(u32, 1), hash(""));
    try testing.expectEqual(@as(u32, 0x091e01de), hash("123456789"));

    var state: Hasher = .init;
    state.update("1234");
    const prefix = state.final();
    try testing.expectEqual(std.hash.Adler32.hash("1234"), prefix);
    state.update("");
    try testing.expectEqual(prefix, state.final());

    var copy = state;
    copy.update("abcd");
    try testing.expectEqual(std.hash.Adler32.hash("1234abcd"), copy.final());
    try testing.expectEqual(prefix, state.final());

    state.update("56789");
    try testing.expectEqual(@as(u32, 0x091e01de), state.final());

    state = .init;
    try testing.expectEqual(@as(u32, 1), state.final());
}

test "incremental Adler matches independent std across vector and reduction boundaries" {
    const bytes = try testing.allocator.alloc(u8, 17000);
    defer testing.allocator.free(bytes);
    var random: std.Random.DefaultPrng = .init(0x61646c6572);
    random.random().bytes(bytes);
    const expected = std.hash.Adler32.hash(bytes);

    const chunk_sizes = [_]usize{ 1, 3, 16, 63, 64, 65, 5551, 5552, 5553, 8192, 17000 };
    for (chunk_sizes) |chunk_size| {
        var state: Hasher = .init;
        var position: usize = 0;
        while (position < bytes.len) {
            const end = position + @min(chunk_size, bytes.len - position);
            state.update(bytes[position..end]);
            state.update("");
            position = end;
        }
        try testing.expectEqual(expected, state.final());
    }
}

test "maximum-byte Adler facts hold for unaligned slices and incremental boundaries" {
    const bytes = try testing.allocator.alloc(u8, 131072 + 63);
    defer testing.allocator.free(bytes);
    @memset(bytes, 255);

    const chunk_sizes = [_]usize{
        1, 31, 32, 63, 64, 127, 128, 255, 256, 4096, 5376, 5504, 5552, 16383, 16384, 16385, 65537,
    };
    for (maximum_byte_facts) |vector| {
        for (0..64) |offset| {
            const input = bytes[offset..][0..vector.length];
            try testing.expectEqual(vector.expected, hash(input));
        }
        for (chunk_sizes) |chunk_size| {
            var state: Hasher = .init;
            var position: usize = 0;
            const input = bytes[1..][0..vector.length];
            while (position < input.len) {
                const end = position + @min(input.len - position, chunk_size);
                state.update(input[position..end]);
                state.update("");
                position = end;
            }
            try testing.expectEqual(vector.expected, state.final());
        }

        // A large second append must normalize the unaligned prefix after a nonempty state; the
        // independent fact covers the combined sequence.
        for ([_]usize{ 63, 4096, 5376, 65537 }) |split| {
            const input = bytes[1..][0..vector.length];
            const prefix = @min(split, input.len);
            var state: Hasher = .init;
            state.update(input[0..prefix]);
            state.update(input[prefix..]);
            try testing.expectEqual(vector.expected, state.final());
        }
    }
}

test "short Adler chunks preserve every length alignment and maximal reduced state" {
    const backing = try testing.allocator.alloc(u8, 1024 + 63);
    defer testing.allocator.free(backing);
    for (backing, 0..) |*byte, index| byte.* = @truncate(index *% 73 +% index / 7);

    for (0..64) |offset| {
        for (0..1025) |length| {
            const input = backing[offset..][0..length];
            try testing.expectEqual(std.hash.Adler32.hash(input), hash(input));

            var state = Hasher{ .first = 65520, .second = 65520 };
            state.update(input);
            try testing.expectEqual(std.hash.Adler32.permute(0xfff0fff0, input), state.final());
        }
    }

    const splits = [_]usize{ 1, 15, 16, 31, 32, 63, 64, 65, 127, 128, 129, 255, 256, 257 };
    for (splits) |split| {
        for (0..1025) |length| {
            const input = backing[3..][0..length];
            var state = Hasher{ .first = 65520, .second = 65520 };
            const cut = @min(split, length);
            state.update(input[0..cut]);
            state.update("");
            state.update(input[cut..]);
            try testing.expectEqual(std.hash.Adler32.permute(0xfff0fff0, input), state.final());
        }
    }
}

test "short Adler buffers terminate at inaccessible pages without padding" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const posix = std.posix;
    const page_size = std.heap.pageSize();
    const memory = try posix.mmap(
        null,
        3 * page_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer posix.munmap(memory);

    for ([_]usize{ 0, 2 }) |page| {
        const page_start = memory.ptr + page * page_size;
        const result = std.os.linux.mprotect(page_start, page_size, .{});
        try testing.expectEqual(.SUCCESS, posix.errno(result));
    }

    const bytes = memory[page_size..][0..page_size];
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index *% 73 +% index / 7);

    for (0..1025) |length| {
        for ([_]usize{ 0, page_size - length }) |offset| {
            const input = bytes[offset..][0..length];
            try testing.expectEqual(std.hash.Adler32.hash(input), hash(input));
            var state = Hasher{ .first = 65520, .second = 65520 };
            state.update(input);
            try testing.expectEqual(std.hash.Adler32.permute(0xfff0fff0, input), state.final());
        }
    }
}

test "Adler32 combining every split and reusable chunk operators" {
    var bytes: [1031]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i * 31 + 17);

    for ([_]usize{ 0, 1, 7, 16, 31, 32, 127, 1024, 1031 }) |length| {
        const expected = hash(bytes[0..length]);
        for (0..length + 1) |split| {
            const first = hash(bytes[0..split]);
            const second = hash(bytes[split..length]);
            const second_length = length - split;
            const operator = CombineOperator.forLength(second_length);
            try testing.expectEqual(expected, combine(first, second, second_length));
            try testing.expectEqual(expected, operator.apply(first, second));
            try testing.expectEqual(second, operator.apply(1, second));
        }
    }

    const operator = CombineOperator.forLength(64);
    var combined: u32 = 1;
    for (0..16) |i| combined = operator.apply(combined, hash(bytes[i * 64 ..][0..64]));
    try testing.expectEqual(hash(bytes[0..1024]), combined);
}

test "Adler32 virtual repeated bytes span the full u64 length range" {
    const lengths = blk: {
        const small = [_]u64{ 0, 1 };
        const near_modulus = [_]u64{ 65520, 65521, 65522 };
        const near_u32_max = [_]u64{ 0xffffffff, 0x100000000 };
        const near_u64_high_bit = [_]u64{ 0x7fffffffffffffff, 0x8000000000000000 };
        const near_u64_max = [_]u64{ 0xfffffffffffffffe, 0xffffffffffffffff };
        break :blk small ++ near_modulus ++ near_u32_max ++ near_u64_high_bit ++ near_u64_max;
    };
    for (lengths) |length| {
        for ([_]u8{ 0, 1, 127, 255 }) |byte| {
            for ([_]u64{ 0, length / 2, length }) |split| {
                const first = repeatedByteChecksum(byte, split);
                const second = repeatedByteChecksum(byte, length - split);
                const expected = repeatedByteChecksum(byte, length);
                try testing.expectEqual(expected, combine(first, second, length - split));
            }
        }
    }
}

test combine {
    const first = hash("Wiki");
    const second = hash("pedia");
    try testing.expectEqual(@as(u32, 0x11e60398), combine(first, second, 5));
}
