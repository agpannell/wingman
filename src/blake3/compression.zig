//! Block compression, target-selected SIMD batches and root-output descriptors.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

pub const block_bytes = 64;
pub const chunk_bytes = 1024;
const blocks_per_chunk = chunk_bytes / block_bytes;
const Digest = [32]u8;
const compression = @This();
const ChainingValue = Cv;
const MessageBlock = Block;
const mode_flags = flags;

pub const Output = struct {
    cv: ChainingValue,
    block: MessageBlock,
    counter: u64,
    length: u32,
    flags: u32,

    pub inline fn chaining(self: Output, comptime kernel: compression.Kernel) ChainingValue {
        return compression.chaining(
            kernel,
            self.cv,
            self.block,
            self.counter,
            self.length,
            self.flags,
        );
    }

    pub inline fn parent(
        key: ChainingValue,
        left: ChainingValue,
        right: ChainingValue,
        mode: u32,
    ) Output {
        return .{
            .cv = key,
            .block = left ++ right,
            .counter = 0,
            .length = block_bytes,
            .flags = mode | mode_flags.parent,
        };
    }

    pub inline fn rootDigest(self: Output, comptime kernel: compression.Kernel) Digest {
        const cv = compression.chaining(
            kernel,
            self.cv,
            self.block,
            0,
            self.length,
            self.flags | mode_flags.root,
        );
        var result: Digest = undefined;
        compression.storeCv(cv, &result);
        return result;
    }

    pub fn writeRootBytes(
        self: Output,
        comptime kernel: compression.Kernel,
        offset: u64,
        out: []u8,
    ) void {
        var counter = offset / block_bytes;
        var skip: usize = @intCast(offset % block_bytes);
        var remaining = out;
        while (remaining.len != 0) {
            const words = compression.compress(
                kernel,
                self.cv,
                self.block,
                counter,
                self.length,
                self.flags | mode_flags.root,
            );
            var bytes: [block_bytes]u8 = undefined;
            for (words, 0..) |word, i| {
                const word_offset = i * @sizeOf(u32);
                std.mem.writeInt(u32, bytes[word_offset..][0..4], word, .little);
            }

            const count = @min(remaining.len, block_bytes - skip);
            @memcpy(remaining[0..count], bytes[skip..][0..count]);
            remaining = remaining[count..];
            counter += 1;
            skip = 0;
        }
    }
};

/// Eight chaining words in algorithm order, independent of host byte order.
pub const Cv = [8]u32;

/// One complete message block in algorithm word order.
pub const Block = [16]u32;

/// Algorithm initial words, also the unkeyed chaining key.
pub const iv: Cv = .{
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
};

/// Flags supplied by the chunk/tree/mode owner; the compression kernel adds none.
pub const flags = struct {
    /// First block within one algorithm chunk.
    pub const chunk_start: u32 = 1;
    /// Final block within one algorithm chunk, including empty input.
    pub const chunk_end: u32 = 2;
    /// A parent containing its two ordered child chaining values.
    pub const parent: u32 = 4;
    /// Final root compression producing digest or extended output.
    pub const root: u32 = 8;

    /// A caller-supplied keyed-hashing key.
    pub const keyed: u32 = 16;
    /// Hashing a derivation context to obtain its internal key.
    pub const derive_context: u32 = 32;
    /// Hashing derivation material with the context-derived key.
    pub const derive_material: u32 = 64;
};

/// Compile-time compression choice for the native owner and independent checks.
pub const Kernel = enum { scalar, row };

/// Row vectors are profitable candidates on targets with native four-word SIMD.
pub const preferred: Kernel = switch (builtin.cpu.arch) {
    .x86_64, .aarch64, .aarch64_be => .row,
    else => .scalar,
};

const has_avx512 = blk: {
    if (builtin.cpu.arch != .x86_64) break :blk false;
    const foundation = std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f);
    const vector_lengths = std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vl);
    break :blk foundation and vector_lengths;
};

/// Largest native word-parallel batch guaranteed by the selected target CPU.
pub const max_lanes: usize = switch (builtin.cpu.arch) {
    .x86_64 => blk: {
        if (has_avx512) break :blk 16;
        if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) break :blk 8;
        break :blk 4;
    },
    .aarch64, .aarch64_be => 4,
    else => 1,
};

/// Loads 0..64 bytes as sixteen little-endian words, zero-padding the unused block bytes. The
/// caller must supply at most 64 bytes; this primitive does not accept a longer slice.
pub inline fn loadBlock(bytes: []const u8) Block {
    std.debug.assert(bytes.len <= block_bytes);
    if (bytes.len == block_bytes and builtin.cpu.arch.endian() == .little) {
        const block: *align(1) const Block = @ptrCast(bytes.ptr);
        return block.*;
    }

    var result: Block = @splat(0);
    // Copy exactly the supplied tail once; LLVM can use bounded native copies rather than a
    // variable scalar-word loop. Absent bytes were already initialized to zero.
    switch (bytes.len) {
        1 => result[0] = bytes[0],
        16 => result[0..4].* = @as(*align(1) const [4]u32, @ptrCast(bytes.ptr)).*,
        32 => result[0..8].* = @as(*align(1) const [8]u32, @ptrCast(bytes.ptr)).*,
        else => @memcpy(std.mem.asBytes(&result)[0..bytes.len], bytes),
    }
    // A byte is already host-independent; wider native loads need word correction.
    if (bytes.len == 1) return result;
    if (builtin.cpu.arch.endian() != .little) {
        for (&result) |*word| word.* = @byteSwap(word.*);
    }
    return result;
}

/// Writes all chaining words as exactly 32 little-endian bytes.
pub fn storeCv(cv: Cv, out: *[32]u8) void {
    for (cv, 0..) |word, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], word, .little);
}

/// Compresses one message block and returns all sixteen output words. `cv` is the incoming chaining
/// value and `length` is the meaningful byte count, in 0..64. The caller supplies the algorithm's
/// counter and complete `block_flags`, including chunk/parent/root and mode flags.
pub inline fn compress(
    comptime kernel: Kernel,
    cv: Cv,
    block: Block,
    counter: u64,
    length: u32,
    block_flags: u32,
) Block {
    return switch (kernel) {
        .scalar => scalar(cv, block, counter, length, block_flags),
        .row => row(cv, block, counter, length, block_flags),
    };
}

/// Returns the first eight output words used by an interior chunk or parent.
pub inline fn chaining(
    comptime kernel: Kernel,
    cv: Cv,
    block: Block,
    counter: u64,
    length: u32,
    block_flags: u32,
) Cv {
    const words = compress(kernel, cv, block, counter, length, block_flags);
    return words[0..8].*;
}

/// Caller-retained scratch for a batch width of 4, 8 or 16. Contents are private to
/// `chunks`/`parents` and need no caller initialization.
pub fn MessageWorkspace(comptime lanes: usize) type {
    if (lanes != 4 and lanes != 8 and lanes != 16) {
        @compileError("BLAKE3 batch width must be 4, 8 or 16");
    }
    return struct {
        /// Backing storage; target-specific kernels may interpret its bytes as scratch records.
        words: [16]@Vector(lanes, u32),
    };
}

/// Hashes exactly `lanes` complete non-root chunks into supplied chaining values. Input is
/// `lanes * 1024` bytes, with `lanes` equal to 4, 8 or 16. The first chunk uses `counter`;
/// `counter + lanes - 1` must fit u64. Input, workspace and output must be disjoint.
pub noinline fn chunks(
    comptime lanes: usize,
    key: Cv,
    noalias input: [*]const u8,
    counter: u64,
    mode: u32,
    noalias messages: *MessageWorkspace(lanes),
    noalias out: *[lanes]Cv,
) void {
    const Word = @Vector(lanes, u32);
    const increments: Word = comptime blk: {
        var result: [lanes]u32 = undefined;
        for (&result, 0..) |*value, i| value.* = @intCast(i);
        break :blk result;
    };
    const base: Word = @splat(@truncate(counter));
    const low = base +% increments;
    const carry = @select(u32, low < base, @as(Word, @splat(1)), @as(Word, @splat(0)));
    const high_base: Word = @splat(@truncate(counter >> 32));
    const high = high_base +% carry;

    if (lanes == 16 and has_avx512) {
        const state: *ChunkWorkspace16 = @ptrCast(messages);
        state.key = key;
        state.counters = .{ low, high };
        state.mode = mode;
        state.initial = iv[0..4].*;
        state.input = input;
        state.permutations = .{ .{ 0, 1, 8, 9, 4, 5, 12, 13 }, .{ 2, 3, 10, 11, 6, 7, 14, 15 } };
        asm volatile (chunk_rounds
            :
            : [workspace] "r" (state),
            : .{
              .rax = true,
              .rcx = true,
              .rdx = true,
              .rdi = true,
              .cc = true,
              .zmm0 = true,
              .zmm1 = true,
              .zmm2 = true,
              .zmm3 = true,
              .zmm4 = true,
              .zmm5 = true,
              .zmm6 = true,
              .zmm7 = true,
              .zmm8 = true,
              .zmm9 = true,
              .zmm10 = true,
              .zmm11 = true,
              .zmm12 = true,
              .zmm13 = true,
              .zmm14 = true,
              .zmm15 = true,
              .zmm16 = true,
              .zmm17 = true,
              .zmm18 = true,
              .zmm19 = true,
              .zmm20 = true,
              .zmm21 = true,
              .zmm22 = true,
              .zmm23 = true,
              .zmm24 = true,
              .zmm25 = true,
              .zmm26 = true,
              .zmm27 = true,
              .zmm28 = true,
              .zmm29 = true,
              .zmm30 = true,
              .zmm31 = true,
              .memory = true,
            });
        storeColumns(lanes, @ptrCast(&state.cv), out);
        @memset(&messages.words, @splat(0));
        return;
    }

    var cv: [8]Word = undefined;
    inline for (0..8) |i| cv[i] = @splat(key[i]);
    for (0..blocks_per_chunk) |block| {
        loadColumns(lanes, input, chunk_bytes, block * block_bytes, messages);
        laneCompress(lanes, &cv, messages, .{ low, high }, chunkFlags(mode, block));
    }
    storeColumns(lanes, &cv, out);
    @memset(&messages.words, @splat(0));
}

/// Hashes exactly two complete contiguous chunks using paired four-word rows. Input spans 2048
/// bytes and must be disjoint from output; counter + 1 must fit. Target lowering uses only
/// guaranteed vector instructions, including narrower SIMD.
pub noinline fn pairChunks(
    key: Cv,
    noalias input: [*]const u8,
    counter: u64,
    mode: u32,
    noalias out: *[2]Cv,
) void {
    const P = @Vector(8, u32);
    var a: P = key[0..4].* ++ key[0..4].*;
    var b: P = key[4..8].* ++ key[4..8].*;
    const next = counter + 1;
    for (0..blocks_per_chunk) |block| {
        const first = loadBlock(input[block * block_bytes ..][0..block_bytes]);
        const second = loadBlock(input[chunk_bytes + block * block_bytes ..][0..block_bytes]);
        const v0: P = first[0..4].* ++ second[0..4].*;
        const v1: P = first[4..8].* ++ second[4..8].*;
        const v2: P = first[8..12].* ++ second[8..12].*;
        const v3: P = first[12..16].* ++ second[12..16].*;
        const m0 = @shuffle(u32, v0, v1, rowMask(8, .{ 0, 2, -1, -3 }));
        const m1 = @shuffle(u32, v0, v1, rowMask(8, .{ 1, 3, -2, -4 }));
        const m2 = @shuffle(u32, v2, v3, rowMask(8, .{ 0, 2, -1, -3 }));
        const m3 = @shuffle(u32, v2, v3, rowMask(8, .{ 1, 3, -2, -4 }));
        var c: P = iv[0..4].* ++ iv[0..4].*;
        const block_flags = chunkFlags(mode, block);
        var d: P = .{
            @truncate(counter),
            @truncate(counter >> 32),
            64,
            block_flags,
            @truncate(next),
            @truncate(next >> 32),
            64,
            block_flags,
        };
        rowRounds(8, &a, &b, &c, &d, .{ m0, m1, m2, m3 });
        a ^= c;
        b ^= d;
    }

    const first: [8]u32 = a;
    const second: [8]u32 = b;
    out[0] = first[0..4].* ++ second[0..4].*;
    out[1] = first[4..8].* ++ second[4..8].*;
}

/// Reduces exactly `lanes * 2` child CVs into `lanes` parent CVs. Input/output may overlap;
/// transpose workspace must be separate from both.
pub noinline fn parents(
    comptime lanes: usize,
    key: Cv,
    input: *const [lanes * 2]Cv,
    mode: u32,
    noalias messages: *MessageWorkspace(lanes),
    out: *[lanes]Cv,
) void {
    // These are host-native words, so byte-order correction differs from external chunks.
    loadColumns(lanes, @ptrCast(input), block_bytes, 0, messages);
    if (builtin.cpu.arch.endian() != .little) {
        inline for (&messages.words) |*word| word.* = @byteSwap(word.*);
    }

    var cv: [8]@Vector(lanes, u32) = undefined;
    inline for (0..8) |i| cv[i] = @splat(key[i]);
    laneCompress(lanes, &cv, messages, .{ @splat(0), @splat(0) }, mode | flags.parent);
    storeColumns(lanes, &cv, out);
    @memset(&messages.words, @splat(0));
}

/// Hashes `count` complete non-root chunks, where count is a power of two and at least two. Input
/// contains `count * 1024` bytes and output has room for `count` chaining values.
/// `counter + count - 1` must fit u64. Input/output must be disjoint; scratch is separate from both
/// and 64-byte aligned. Kernel selection follows the compile-time CPU target.
pub fn batchChunks(
    key: Cv,
    input: [*]const u8,
    counter: u64,
    mode: u32,
    count: usize,
    messages: *align(64) [256]u32,
    out: [*]Cv,
) void {
    inline for (.{ 16, 8, 4 }) |width| {
        if (comptime max_lanes >= width) {
            if (count >= width) {
                for (0..count / width) |group| {
                    const offset = group * width;
                    chunks(
                        width,
                        key,
                        input + offset * chunk_bytes,
                        counter + offset,
                        mode,
                        @ptrCast(messages),
                        out[offset..][0..width],
                    );
                }
                return;
            }
        }
    }
    for (0..count / 2) |group| {
        const offset = group * 2;
        pairChunks(key, input + offset * chunk_bytes, counter + offset, mode, out[offset..][0..2]);
    }
}

/// Reduces `count * 2` child chaining values into `count` parents. Count is a positive power of
/// two. Children/output may overlap; 64-byte-aligned scratch must be separate from both. Kernel
/// selection follows the compile-time CPU target.
pub fn batchParents(
    key: Cv,
    input: [*]const Cv,
    mode: u32,
    count: usize,
    messages: *align(64) [256]u32,
    out: [*]Cv,
) void {
    const input_address = @intFromPtr(input);
    const output_address = @intFromPtr(out);
    if (output_address > input_address) {
        const distance = output_address - input_address;
        if (distance < count * 2 * @sizeOf(Cv)) {
            // Input advances by two CVs per parent, but output by one. Start where their ranges
            // cross (or at the last parent) and work toward each end, so no write touches children
            // another parent still needs. Distances need not be whole CVs.
            const crossing = @min(distance / @sizeOf(Cv), count - 1);
            var remaining = crossing + 1;
            while (remaining != 0) {
                remaining -= 1;
                out[remaining] = Output.parent(
                    key,
                    input[remaining * 2],
                    input[remaining * 2 + 1],
                    mode,
                ).chaining(preferred);
            }
            for (crossing + 1..count) |i| {
                out[i] = Output.parent(
                    key,
                    input[i * 2],
                    input[i * 2 + 1],
                    mode,
                ).chaining(preferred);
            }
            return;
        }
    }

    inline for (.{ 16, 8, 4 }) |width| {
        if (comptime max_lanes >= width) {
            if (count >= width) {
                for (0..count / width) |group| {
                    const offset = group * width;
                    parents(
                        width,
                        key,
                        input[offset * 2 ..][0 .. width * 2],
                        mode,
                        @ptrCast(messages),
                        out[offset..][0..width],
                    );
                }
                return;
            }
        }
    }
    for (0..count) |i| {
        const left = input[i * 2];
        const right = input[i * 2 + 1];
        out[i] = Output.parent(key, left, right, mode).chaining(preferred);
    }
}

const schedule: [7][16]u8 = makeSchedule();

// Four independent mixes visit columns first, then diagonals, in every round.
const column_round: [4][4]usize = .{ .{
    0, 1, 2, 3,
}, .{
    4, 5, 6, 7,
}, .{
    8, 9, 10, 11,
}, .{
    12, 13, 14, 15,
} };

const diagonal_round: [4][4]usize = .{ .{
    0, 1, 2, 3,
}, .{
    5, 6, 7, 4,
}, .{
    10, 11, 8, 9,
}, .{
    15, 12, 13, 14,
} };

fn makeSchedule() [7][16]u8 {
    const permutation = [16]u8{ 2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8 };
    var result: [7][16]u8 = undefined;
    for (0..16) |i| result[0][i] = @intCast(i);
    for (1..7) |round| for (0..16) |i| {
        result[round][i] = result[round - 1][permutation[i]];
    };
    return result;
}

inline fn rotateRight(value: anytype, comptime count: u5) @TypeOf(value) {
    const complement: u5 = 32 - @as(u6, count);
    if (@TypeOf(value) == u32) return (value >> count) | (value << complement);
    return (value >> @splat(count)) | (value << @splat(complement));
}

inline fn mix(a: anytype, b: anytype, c: anytype, d: anytype, x: anytype, y: anytype) void {
    a.* +%= b.* +% x;
    d.* = rotateRight(d.* ^ a.*, 16);
    c.* +%= d.*;
    b.* = rotateRight(b.* ^ c.*, 12);
    a.* +%= b.* +% y;
    d.* = rotateRight(d.* ^ a.*, 8);
    c.* +%= d.*;
    b.* = rotateRight(b.* ^ c.*, 7);
}

inline fn mixState(
    state: *Block,
    comptime a: usize,
    comptime b: usize,
    comptime c: usize,
    comptime d: usize,
    x: u32,
    y: u32,
) void {
    mix(&state[a], &state[b], &state[c], &state[d], x, y);
}

fn scalar(cv: Cv, block: Block, counter: u64, length: u32, block_flags: u32) Block {
    const parameters: [4]u32 = .{
        @truncate(counter),
        @truncate(counter >> 32),
        length,
        block_flags,
    };
    var state: Block = cv ++ iv[0..4].* ++ parameters;
    inline for (schedule) |s| {
        mixState(&state, 0, 4, 8, 12, block[s[0]], block[s[1]]);
        mixState(&state, 1, 5, 9, 13, block[s[2]], block[s[3]]);
        mixState(&state, 2, 6, 10, 14, block[s[4]], block[s[5]]);
        mixState(&state, 3, 7, 11, 15, block[s[6]], block[s[7]]);
        mixState(&state, 0, 5, 10, 15, block[s[8]], block[s[9]]);
        mixState(&state, 1, 6, 11, 12, block[s[10]], block[s[11]]);
        mixState(&state, 2, 7, 8, 13, block[s[12]], block[s[13]]);
        mixState(&state, 3, 4, 9, 14, block[s[14]], block[s[15]]);
    }
    inline for (0..8) |i| {
        state[i] ^= state[i + 8];
        state[i + 8] ^= cv[i];
    }
    return state;
}

const Row = @Vector(4, u32);

inline fn row(cv: Cv, block: Block, counter: u64, length: u32, block_flags: u32) Block {
    const v0: Row = block[0..4].*;
    const v1: Row = block[4..8].*;
    const v2: Row = block[8..12].*;
    const v3: Row = block[12..16].*;
    const m0 = @shuffle(u32, v0, v1, [4]i32{ 0, 2, -1, -3 });
    const m1 = @shuffle(u32, v0, v1, [4]i32{ 1, 3, -2, -4 });
    const m2 = @shuffle(u32, v2, v3, [4]i32{ 0, 2, -1, -3 });
    const m3 = @shuffle(u32, v2, v3, [4]i32{ 1, 3, -2, -4 });

    var a: Row = cv[0..4].*;
    var b: Row = cv[4..8].*;
    var c: Row = iv[0..4].*;
    var d: Row = .{ @truncate(counter), @truncate(counter >> 32), length, block_flags };
    rowRounds(4, &a, &b, &c, &d, .{ m0, m1, m2, m3 });

    const first: [4]u32 = a ^ c;
    const second: [4]u32 = b ^ d;
    const third: [4]u32 = c ^ @as(Row, cv[0..4].*);
    const fourth: [4]u32 = d ^ @as(Row, cv[4..8].*);
    return first ++ second ++ third ++ fourth;
}

inline fn rowRounds(
    comptime width: usize,
    a: anytype,
    b: anytype,
    c: anytype,
    d: anytype,
    initial: [4]@Vector(width, u32),
) void {
    @setEvalBranchQuota(10000);
    var m0 = initial[0];
    var m1 = initial[1];
    var m2 = initial[2];
    var m3 = initial[3];
    inline for (0..7) |round| {
        mix(a, b, c, d, m0, m1);

        // Rotate rows into diagonals for the second mix, then restore column order.
        b.* = @shuffle(u32, b.*, undefined, rowMask(width, .{ 1, 2, 3, 0 }));
        c.* = @shuffle(u32, c.*, undefined, rowMask(width, .{ 2, 3, 0, 1 }));
        d.* = @shuffle(u32, d.*, undefined, rowMask(width, .{ 3, 0, 1, 2 }));
        mix(a, b, c, d, m2, m3);
        b.* = @shuffle(u32, b.*, undefined, rowMask(width, .{ 3, 0, 1, 2 }));
        c.* = @shuffle(u32, c.*, undefined, rowMask(width, .{ 2, 3, 0, 1 }));
        d.* = @shuffle(u32, d.*, undefined, rowMask(width, .{ 1, 2, 3, 0 }));

        if (round != 6) {
            // Each row holds alternating message words for four simultaneous mixes.
            const n0 = @shuffle(u32, m0, m1, rowMask(width, .{ 1, -2, -4, 2 }));
            const t1 = @shuffle(u32, m0, m2, rowMask(width, .{ 3, -2, 0, -1 }));
            const n1 = @shuffle(u32, t1, m3, rowMask(width, .{ 0, 1, 2, -3 }));
            const t2 = @shuffle(u32, m1, m2, rowMask(width, .{ 0, -3, 0, -3 }));
            const n2 = @shuffle(u32, t2, m3, rowMask(width, .{ 0, 1, -1, -4 }));
            const t3 = @shuffle(u32, m3, m1, rowMask(width, .{ 1, -3, 1, -3 }));
            const n3 = @shuffle(u32, t3, m2, rowMask(width, .{ 0, 1, -4, -1 }));
            m0 = n0;
            m1 = n1;
            m2 = n2;
            m3 = n3;
        }
    }
}

fn rowMask(comptime width: usize, comptime mask: [4]i32) [width]i32 {
    var result: [width]i32 = undefined;
    for (0..width) |i| {
        const base: i32 = @intCast((i / 4) * 4);
        const index = mask[i % 4];
        result[i] = if (index >= 0) base + index else index - base;
    }
    return result;
}

const Word16 = @Vector(16, u32);

fn Quad(comptime lanes: usize) type {
    const Word = @Vector(lanes, u32);
    return struct { a: Word, b: Word, c: Word, d: Word };
}

inline fn loadColumns(
    comptime lanes: usize,
    noalias input: [*]const u8,
    stride: usize,
    position: usize,
    noalias out: *MessageWorkspace(lanes),
) void {
    inline for (0..16 / lanes) |part| {
        const offset = position + part * lanes * 4;
        const a = loadQuad(lanes, input + offset, stride);
        if (lanes == 4) {
            inline for (.{ "a", "b", "c", "d" }, 0..) |field, i| {
                out.words[part * 4 + i] = @field(a, field);
            }
        } else {
            const b = loadQuad(lanes, input + offset + 4 * stride, stride);
            if (lanes == 8) {
                inline for (.{ "a", "b", "c", "d" }, 0..) |field, i| {
                    out.words[part * 8 + i] = zip(
                        lanes,
                        4,
                        8,
                        0,
                        @field(a, field),
                        @field(b, field),
                    );
                    out.words[part * 8 + i + 4] = zip(
                        lanes,
                        4,
                        8,
                        1,
                        @field(a, field),
                        @field(b, field),
                    );
                }
            } else {
                const c = loadQuad(lanes, input + offset + 8 * stride, stride);
                const d = loadQuad(lanes, input + offset + 12 * stride, stride);
                inline for (.{ "a", "b", "c", "d" }, 0..) |field, i| {
                    const low_a = quarters(0, @field(a, field), @field(b, field));
                    const high_a = quarters(1, @field(a, field), @field(b, field));
                    const low_b = quarters(0, @field(c, field), @field(d, field));
                    const high_b = quarters(1, @field(c, field), @field(d, field));
                    out.words[i] = quarters(0, low_a, low_b);
                    out.words[i + 4] = quarters(0, high_a, high_b);
                    out.words[i + 8] = quarters(1, low_a, low_b);
                    out.words[i + 12] = quarters(1, high_a, high_b);
                }
            }
        }
    }
}

inline fn storeColumns(
    comptime lanes: usize,
    cv: *const [8]@Vector(lanes, u32),
    out: *[lanes]Cv,
) void {
    const a = transposeQuad(lanes, cv[0], cv[1], cv[2], cv[3]);
    const b = transposeQuad(lanes, cv[4], cv[5], cv[6], cv[7]);
    if (lanes == 4) {
        inline for (.{ "a", "b", "c", "d" }, 0..) |field, lane| {
            const words = @shuffle(u32, @field(a, field), @field(b, field), [8]i32{
                0, 1, 2, 3, -1, -2, -3, -4,
            });
            const destination: *align(1) @Vector(8, u32) = @ptrCast(&out[lane]);
            destination.* = words;
        }
    } else if (lanes == 8) {
        inline for (.{ "a", "b", "c", "d" }, 0..) |field, lane| {
            const low: *align(1) @Vector(8, u32) = @ptrCast(&out[lane]);
            const high: *align(1) @Vector(8, u32) = @ptrCast(&out[lane + 4]);
            low.* = zip(lanes, 4, 8, 0, @field(a, field), @field(b, field));
            high.* = zip(lanes, 4, 8, 1, @field(a, field), @field(b, field));
        }
    } else {
        inline for (.{ .{ "a", "b" }, .{ "c", "d" } }, 0..) |fields, pair| {
            const i = pair * 2;
            const low_a = quarters(0, @field(a, fields[0]), @field(b, fields[0]));
            const low_b = quarters(0, @field(a, fields[1]), @field(b, fields[1]));
            const high_a = quarters(1, @field(a, fields[0]), @field(b, fields[0]));
            const high_b = quarters(1, @field(a, fields[1]), @field(b, fields[1]));
            const first: *align(1) Word16 = @ptrCast(&out[i]);
            const second: *align(1) Word16 = @ptrCast(&out[i + 8]);
            const third: *align(1) Word16 = @ptrCast(&out[i + 4]);
            const fourth: *align(1) Word16 = @ptrCast(&out[i + 12]);
            first.* = quarters(0, low_a, low_b);
            second.* = quarters(1, low_a, low_b);
            third.* = quarters(0, high_a, high_b);
            fourth.* = quarters(1, high_a, high_b);
        }
    }
}

inline fn loadQuad(comptime lanes: usize, input: [*]const u8, stride: usize) Quad(lanes) {
    const a = loadVector(lanes, input);
    const b = loadVector(lanes, input + stride);
    const c = loadVector(lanes, input + stride * 2);
    const d = loadVector(lanes, input + stride * 3);
    return transposeQuad(lanes, a, b, c, d);
}

inline fn transposeQuad(
    comptime lanes: usize,
    a: @Vector(lanes, u32),
    b: @Vector(lanes, u32),
    c: @Vector(lanes, u32),
    d: @Vector(lanes, u32),
) Quad(lanes) {
    const ab_low = zip(lanes, 1, 4, 0, a, b);
    const ab_high = zip(lanes, 1, 4, 1, a, b);
    const cd_low = zip(lanes, 1, 4, 0, c, d);
    const cd_high = zip(lanes, 1, 4, 1, c, d);
    return .{
        .a = zip(lanes, 2, 4, 0, ab_low, cd_low),
        .b = zip(lanes, 2, 4, 1, ab_low, cd_low),
        .c = zip(lanes, 2, 4, 0, ab_high, cd_high),
        .d = zip(lanes, 2, 4, 1, ab_high, cd_high),
    };
}

inline fn loadVector(comptime lanes: usize, bytes: [*]const u8) @Vector(lanes, u32) {
    const native: *align(1) const @Vector(lanes, u32) = @ptrCast(bytes);
    return if (builtin.cpu.arch.endian() == .little) native.* else @byteSwap(native.*);
}

inline fn zip(
    comptime lanes: usize,
    comptime group: usize,
    comptime bank: usize,
    comptime half: usize,
    a: @Vector(lanes, u32),
    b: @Vector(lanes, u32),
) @Vector(lanes, u32) {
    const mask = comptime blk: {
        @setEvalBranchQuota(10000);
        var result: [lanes]i32 = undefined;
        for (0..lanes) |i| {
            const within = i % bank;
            const bank_start = (i / bank) * bank;
            const half_start = half * (bank / 2);
            const group_start = (within / (2 * group)) * group;
            const index: i32 = @intCast(bank_start + half_start + group_start + within % group);
            result[i] = if ((within / group) % 2 == 0) index else ~index;
        }
        break :blk result;
    };
    return @shuffle(u32, a, b, mask);
}

inline fn quarters(comptime half: usize, a: Word16, b: Word16) Word16 {
    const mask: [16]i32 = blk: {
        if (half == 0) {
            break :blk .{ 0, 1, 2, 3, 8, 9, 10, 11, -1, -2, -3, -4, -9, -10, -11, -12 };
        }
        break :blk .{ 4, 5, 6, 7, 12, 13, 14, 15, -5, -6, -7, -8, -13, -14, -15, -16 };
    };
    return @shuffle(u32, a, b, mask);
}

inline fn laneCompress(
    comptime lanes: usize,
    cv: *[8]@Vector(lanes, u32),
    message: *const MessageWorkspace(lanes),
    counters: [2]@Vector(lanes, u32),
    block_flags: u32,
) void {
    if (lanes == 16 and has_avx512) {
        laneCompress16(cv, message, counters, block_flags);
        return;
    }

    var state: [16]@Vector(lanes, u32) = undefined;
    inline for (0..8) |i| state[i] = cv[i];
    inline for (0..4) |i| state[i + 8] = @splat(iv[i]);
    state[12] = counters[0];
    state[13] = counters[1];
    state[14] = @splat(block_bytes);
    state[15] = @splat(block_flags);
    inline for (schedule) |s| {
        laneQuarter(
            lanes,
            &state,
            message,
            column_round[0],
            column_round[1],
            column_round[2],
            column_round[3],
            s[0..8].*,
        );
        laneQuarter(
            lanes,
            &state,
            message,
            diagonal_round[0],
            diagonal_round[1],
            diagonal_round[2],
            diagonal_round[3],
            s[8..16].*,
        );
    }
    inline for (0..8) |i| cv[i] = state[i] ^ state[i + 8];
}

inline fn laneQuarter(
    comptime lanes: usize,
    state: *[16]@Vector(lanes, u32),
    message: *const MessageWorkspace(lanes),
    comptime a: [4]usize,
    comptime b: [4]usize,
    comptime c: [4]usize,
    comptime d: [4]usize,
    comptime s: [8]u8,
) void {
    inline for (0..4) |i| state[a[i]] +%= message.words[s[i * 2]];
    inline for (0..4) |i| state[a[i]] +%= state[b[i]];
    inline for (0..4) |i| state[d[i]] = rotateRight(state[d[i]] ^ state[a[i]], 16);
    inline for (0..4) |i| state[c[i]] +%= state[d[i]];
    inline for (0..4) |i| state[b[i]] = rotateRight(state[b[i]] ^ state[c[i]], 12);
    inline for (0..4) |i| state[a[i]] +%= message.words[s[i * 2 + 1]];
    inline for (0..4) |i| state[a[i]] +%= state[b[i]];
    inline for (0..4) |i| state[d[i]] = rotateRight(state[d[i]] ^ state[a[i]], 8);
    inline for (0..4) |i| state[c[i]] +%= state[d[i]];
    inline for (0..4) |i| state[b[i]] = rotateRight(state[b[i]] ^ state[c[i]], 7);
}

inline fn chunkFlags(mode: u32, block: usize) u32 {
    const start: u32 = if (block == 0) flags.chunk_start else 0;
    const end: u32 = if (block == blocks_per_chunk - 1) flags.chunk_end else 0;
    return mode | start | end;
}

// All thirty-two vector registers are occupied by the state and message words. Fixed bindings keep
// LLVM from spilling messages to reserve temporary registers. The generated instructions are the
// same seven algorithm rounds as the other kernels.
inline fn laneCompress16(
    cv: *[8]Word16,
    message: *const MessageWorkspace(16),
    counters: [2]Word16,
    block_flags: u32,
) void {
    var o0: Word16 = undefined;
    var o1: Word16 = undefined;
    var o2: Word16 = undefined;
    var o3: Word16 = undefined;
    var o4: Word16 = undefined;
    var o5: Word16 = undefined;
    var o6: Word16 = undefined;
    var o7: Word16 = undefined;
    asm ("movl $64, %%eax\nvpbroadcastd %%eax, %%zmm14\n" ++ lane_rounds
        : [v0] "={zmm0}" (o0),
          [v1] "={zmm1}" (o1),
          [v2] "={zmm2}" (o2),
          [v3] "={zmm3}" (o3),
          [v4] "={zmm4}" (o4),
          [v5] "={zmm5}" (o5),
          [v6] "={zmm6}" (o6),
          [v7] "={zmm7}" (o7),
        : [c0] "{zmm0}" (cv[0]),
          [c1] "{zmm1}" (cv[1]),
          [c2] "{zmm2}" (cv[2]),
          [c3] "{zmm3}" (cv[3]),
          [c4] "{zmm4}" (cv[4]),
          [c5] "{zmm5}" (cv[5]),
          [c6] "{zmm6}" (cv[6]),
          [c7] "{zmm7}" (cv[7]),
          [v8] "{zmm8}" (@as(Word16, @splat(iv[0]))),
          [v9] "{zmm9}" (@as(Word16, @splat(iv[1]))),
          [v10] "{zmm10}" (@as(Word16, @splat(iv[2]))),
          [v11] "{zmm11}" (@as(Word16, @splat(iv[3]))),
          [v12] "{zmm12}" (counters[0]),
          [v13] "{zmm13}" (counters[1]),
          [v15] "{zmm15}" (@as(Word16, @splat(block_flags))),
          [m0] "{zmm16}" (message.words[0]),
          [m1] "{zmm17}" (message.words[1]),
          [m2] "{zmm18}" (message.words[2]),
          [m3] "{zmm19}" (message.words[3]),
          [m4] "{zmm20}" (message.words[4]),
          [m5] "{zmm21}" (message.words[5]),
          [m6] "{zmm22}" (message.words[6]),
          [m7] "{zmm23}" (message.words[7]),
          [m8] "{zmm24}" (message.words[8]),
          [m9] "{zmm25}" (message.words[9]),
          [m10] "{zmm26}" (message.words[10]),
          [m11] "{zmm27}" (message.words[11]),
          [m12] "{zmm28}" (message.words[12]),
          [m13] "{zmm29}" (message.words[13]),
          [m14] "{zmm30}" (message.words[14]),
          [m15] "{zmm31}" (message.words[15]),
        : .{
          .rax = true,
          .zmm8 = true,
          .zmm9 = true,
          .zmm10 = true,
          .zmm11 = true,
          .zmm12 = true,
          .zmm13 = true,
          .zmm14 = true,
          .zmm15 = true,
        });
    cv.* = .{ o0, o1, o2, o3, o4, o5, o6, o7 };
}

const lane_rounds = makeLaneRounds();

fn makeLaneRounds() []const u8 {
    @setEvalBranchQuota(1000000);
    var result: []const u8 = "";
    for (schedule) |s| {
        result = result ++ asmQuarter(
            column_round[0],
            column_round[1],
            column_round[2],
            column_round[3],
            s[0..8].*,
        );
        result = result ++ asmQuarter(
            diagonal_round[0],
            diagonal_round[1],
            diagonal_round[2],
            diagonal_round[3],
            s[8..16].*,
        );
    }
    for (0..8) |i| {
        result = result ++ std.fmt.comptimePrint(
            "vpxord %%zmm{d}, %%zmm{d}, %%zmm{d}\n",
            .{ i + 8, i, i },
        );
    }
    return result;
}

fn asmQuarter(
    comptime a: [4]usize,
    comptime b: [4]usize,
    comptime c: [4]usize,
    comptime d: [4]usize,
    comptime s: [8]u8,
) []const u8 {
    var result: []const u8 = "";
    for (0..2) |half| {
        const rotate_d: usize = if (half == 0) 16 else 8;
        const rotate_b: usize = if (half == 0) 12 else 7;
        for (0..4) |i| {
            result = result ++ std.fmt.comptimePrint(
                "vpaddd %%zmm{d}, %%zmm{d}, %%zmm{d}\n",
                .{ s[i * 2 + half] + 16, a[i], a[i] },
            );
        }
        for (0..4) |i| {
            result = result ++ std.fmt.comptimePrint(
                "vpaddd %%zmm{d}, %%zmm{d}, %%zmm{d}\n",
                .{ b[i], a[i], a[i] },
            );
        }
        for (0..4) |i| {
            result = result ++ std.fmt.comptimePrint(
                "vpxord %%zmm{d}, %%zmm{d}, %%zmm{d}\n",
                .{ a[i], d[i], d[i] },
            );
        }
        for (0..4) |i| {
            result = result ++ std.fmt.comptimePrint(
                "vprord ${d}, %%zmm{d}, %%zmm{d}\n",
                .{ rotate_d, d[i], d[i] },
            );
        }
        for (0..4) |i| {
            result = result ++ std.fmt.comptimePrint(
                "vpaddd %%zmm{d}, %%zmm{d}, %%zmm{d}\n",
                .{ d[i], c[i], c[i] },
            );
        }
        for (0..4) |i| {
            result = result ++ std.fmt.comptimePrint(
                "vpxord %%zmm{d}, %%zmm{d}, %%zmm{d}\n",
                .{ c[i], b[i], b[i] },
            );
        }
        for (0..4) |i| {
            result = result ++ std.fmt.comptimePrint(
                "vprord ${d}, %%zmm{d}, %%zmm{d}\n",
                .{ rotate_b, b[i], b[i] },
            );
        }
    }
    return result;
}

// All addressable chunk scratch lives in the supplied message workspace. Transpose rows and
// algorithm state use fixed registers; no message matrix reaches memory.
const ChunkWorkspace16 = extern struct {
    cv: [8][16]u32 align(64),
    counters: [2][16]u32 align(64),
    mode: u32,
    initial: [4]u32,
    input: [*]const u8,
    permutations: [2][8]u64 align(64),
    key: Cv,
};

const chunk_rounds = makeChunkRounds();

fn makeChunkRounds() []const u8 {
    @setEvalBranchQuota(1000000);
    const vector_bytes = @sizeOf(Word16);
    const key_offset = @offsetOf(ChunkWorkspace16, "key");
    const mode_offset = @offsetOf(ChunkWorkspace16, "mode");
    const input_offset = @offsetOf(ChunkWorkspace16, "input");
    const initial_offset = @offsetOf(ChunkWorkspace16, "initial");
    const counters_offset = @offsetOf(ChunkWorkspace16, "counters");
    const permutations_offset = @offsetOf(ChunkWorkspace16, "permutations");
    const cv_offset = @offsetOf(ChunkWorkspace16, "cv");
    const prefetch_ahead = 3 * block_bytes;
    var result: []const u8 = "";
    for (0..8) |i| {
        result = result ++ std.fmt.comptimePrint(
            "vpbroadcastd {d}(%[workspace]), %%zmm{d}\n",
            .{ key_offset + i * @sizeOf(u32), i },
        );
    }
    result = result ++ std.fmt.comptimePrint(
        \\xorl %%eax, %%eax
        \\movq {d}(%[workspace]), %%rdi
        \\movl {d}(%[workspace]), %%ecx
        \\orl ${d}, %%ecx
        \\1:
        \\cmpl ${d}, %%eax
        \\jne 2f
        \\orl ${d}, %%ecx
        \\2:
        \\
    , .{
        input_offset,
        mode_offset,
        flags.chunk_start,
        chunk_bytes - block_bytes,
        flags.chunk_end,
    });

    for (0..2) |part| {
        // zmm0..7 retain chaining words. zmm8..15 transpose input rows into message columns in
        // zmm16..23 (first half) and zmm24..31 (second half).
        const base = 16 + part * 8;
        for (0..8) |i| {
            const low_offset = i * chunk_bytes + part * (block_bytes / 2);
            const high_offset = (i + 8) * chunk_bytes + part * (block_bytes / 2);
            const register = i + 8;
            result = result ++ std.fmt.comptimePrint(
                \\vmovdqu32 {d}(%%rdi,%%rax), %%ymm{d}
                \\vinserti64x4 $1, {d}(%%rdi,%%rax), %%zmm{d}, %%zmm{d}
                \\
            , .{ low_offset, register, high_offset, register, register });
        }
        if (part == 0) {
            // Interleave bounded prefetches with the two load/transpose phases.
            result = result ++ std.fmt.comptimePrint(
                \\cmpl ${d}, %%eax
                \\ja 3f
                \\
            , .{chunk_bytes - block_bytes - prefetch_ahead});
            for (0..16) |i| {
                result = result ++ std.fmt.comptimePrint(
                    "prefetcht0 {d}(%%rdi,%%rax)\n",
                    .{i * chunk_bytes + prefetch_ahead},
                );
            }
            result = result ++ "3:\n";
        }
        for (0..4) |pair| {
            const source = pair * 2 + 8;
            const target = base + pair * 2;
            result = result ++ std.fmt.comptimePrint(
                \\vpunpckldq %%zmm{d}, %%zmm{d}, %%zmm{d}
                \\vpunpckhdq %%zmm{d}, %%zmm{d}, %%zmm{d}
                \\
            , .{ source + 1, source, target, source + 1, source, target + 1 });
        }
        for (0..2) |group| {
            const source = base + group * 4;
            const target = group * 4 + 8;
            result = result ++ std.fmt.comptimePrint(
                \\vpunpcklqdq %%zmm{d}, %%zmm{d}, %%zmm{d}
                \\vpunpckhqdq %%zmm{d}, %%zmm{d}, %%zmm{d}
                \\vpunpcklqdq %%zmm{d}, %%zmm{d}, %%zmm{d}
                \\vpunpckhqdq %%zmm{d}, %%zmm{d}, %%zmm{d}
                \\
            , .{
                source + 2,
                source,
                target,
                source + 2,
                source,
                target + 1,
                source + 3,
                source + 1,
                target + 2,
                source + 3,
                source + 1,
                target + 3,
            });
        }
        result = result ++ std.fmt.comptimePrint(
            \\vmovdqa64 {d}(%[workspace]), %%zmm{d}
            \\vmovdqa64 {d}(%[workspace]), %%zmm{d}
            \\
        , .{ permutations_offset, base + 3, permutations_offset + vector_bytes, base + 7 });
        for (0..4) |i| {
            if (i != 3) {
                result = result ++ std.fmt.comptimePrint(
                    \\vmovdqa64 %%zmm{d}, %%zmm{d}
                    \\vmovdqa64 %%zmm{d}, %%zmm{d}
                    \\
                , .{ base + 3, base + i, base + 7, base + i + 4 });
            }
            result = result ++ std.fmt.comptimePrint(
                \\vpermi2q %%zmm{d}, %%zmm{d}, %%zmm{d}
                \\vpermi2q %%zmm{d}, %%zmm{d}, %%zmm{d}
                \\
            , .{ i + 12, i + 8, base + i, i + 12, i + 8, base + i + 4 });
        }
    }
    for (0..4) |i| {
        result = result ++ std.fmt.comptimePrint(
            "vpbroadcastd {d}(%[workspace]), %%zmm{d}\n",
            .{ initial_offset + i * @sizeOf(u32), i + 8 },
        );
    }
    result = result ++ std.fmt.comptimePrint(
        \\vmovdqa64 {d}(%[workspace]), %%zmm12
        \\vmovdqa64 {d}(%[workspace]), %%zmm13
        \\movl ${d}, %%edx
        \\vpbroadcastd %%edx, %%zmm14
        \\vpbroadcastd %%ecx, %%zmm15
        \\
    , .{ counters_offset, counters_offset + vector_bytes, block_bytes }) ++ lane_rounds;
    result = result ++ std.fmt.comptimePrint(
        \\movl {d}(%[workspace]), %%ecx
        \\addl ${d}, %%eax
        \\cmpl ${d}, %%eax
        \\jne 1b
        \\
    , .{ mode_offset, block_bytes, chunk_bytes });
    for (0..8) |i| {
        result = result ++ std.fmt.comptimePrint(
            "vmovdqa64 %%zmm{d}, {d}(%[workspace])\n",
            .{ i, cv_offset + i * vector_bytes },
        );
    }
    return result;
}

test "AVX-512 chunk scratch offsets and alignment fit retained message storage" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    try testing.expect(@sizeOf(ChunkWorkspace16) <= @sizeOf(MessageWorkspace(16)));
    try testing.expect(@alignOf(ChunkWorkspace16) <= @alignOf(MessageWorkspace(16)));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ChunkWorkspace16, "cv"));
    try testing.expectEqual(@as(usize, 512), @offsetOf(ChunkWorkspace16, "counters"));
    try testing.expectEqual(@as(usize, 640), @offsetOf(ChunkWorkspace16, "mode"));
    try testing.expectEqual(@as(usize, 644), @offsetOf(ChunkWorkspace16, "initial"));
    try testing.expectEqual(@as(usize, 664), @offsetOf(ChunkWorkspace16, "input"));
    try testing.expectEqual(@as(usize, 704), @offsetOf(ChunkWorkspace16, "permutations"));
    try testing.expectEqual(@as(usize, 832), @offsetOf(ChunkWorkspace16, "key"));
}

test "paired rows match scalar chunks across unaligned input and counter carry" {
    const allocator = testing.allocator;
    const input = try allocator.alloc(u8, 2048 + 64);
    defer allocator.free(input);
    for (input, 0..) |*byte, i| byte.* = @truncate(i *% 193 +% (i >> 9));

    const offsets = [_]usize{ 0, 1, 3, 31, 63 };
    const counters = [_]u64{ 0, 0xffffffff, 0x100000003 };
    const modes = [_]u32{ 0, 16, 32, 64 };
    for (offsets) |offset| for (counters) |counter| for (modes) |mode| {
        var actual: [2]Cv = undefined;
        pairChunks(iv, input.ptr + offset, counter, mode, &actual);
        for (0..2) |lane| {
            var expected = iv;
            for (0..blocks_per_chunk) |block| {
                const begin = offset + lane * chunk_bytes + block * block_bytes;
                const words = loadBlock(input[begin..][0..block_bytes]);
                const start_flag: u32 = if (block == 0) flags.chunk_start else 0;
                const last_block = block == blocks_per_chunk - 1;
                const end_flag: u32 = if (last_block) flags.chunk_end else 0;
                expected = chaining(
                    .scalar,
                    expected,
                    words,
                    counter + lane,
                    block_bytes,
                    mode | start_flag | end_flag,
                );
            }
            try testing.expectEqual(expected, actual[lane]);
        }
    };
}

test "scalar and row compression agree with counter carry and every flag" {
    var cv: Cv = undefined;
    var block: Block = undefined;
    for (&cv, 0..) |*word, i| word.* = @truncate(@as(u64, 0xdeadbeef12345678) *% (i + 1));
    for (&block, 0..) |*word, i| word.* = @truncate(@as(u64, 0xcabcfffffedc0123) *% (i + 1));

    const counters = [_]u64{ 0, 1, 0xffffffff, 0x100000000, 0x100000007, 0xffffffffffffffff };
    const lengths = [_]u32{ 0, 1, 31, 32, 63, 64 };
    const flag_sets = [_]u32{ 0, 1, 2, 3, 4, 8, 16, 32, 64, 127 };
    for (counters) |counter| for (lengths) |length| for (flag_sets) |block_flags| {
        try testing.expectEqual(
            scalar(cv, block, counter, length, block_flags),
            row(cv, block, counter, length, block_flags),
        );
    };
}

test "every word batch matches checked scalar chunks and overlapping parent reduction" {
    const allocator = testing.allocator;
    const input = try allocator.alloc(u8, 16 * 1024 + 64);
    defer allocator.free(input);
    for (input, 0..) |*byte, i| byte.* = @truncate(i *% 193 +% (i >> 9));
    const key: Cv = .{
        0xffffffff, 0x80000000, 0, 0xa7a7a7a7, 0xdeadbeef, 1, 0x7fffffff, 0x12345678,
    };
    const offsets = [_]usize{ 0, 1, 3, 31, 63 };
    const counters = [_]u64{ 0, 0xfffffffe, 0x100000003 };
    const modes = [_]u32{ 0, 16, 32, 64 };

    inline for (.{ 4, 8, 16 }) |lanes| {
        const workspace = try allocator.create(MessageWorkspace(lanes));
        defer allocator.destroy(workspace);
        const actual = try allocator.create([lanes]Cv);
        defer allocator.destroy(actual);
        const expected = try allocator.create([lanes]Cv);
        defer allocator.destroy(expected);
        const children = try allocator.create([lanes * 2]Cv);
        defer allocator.destroy(children);
        for (offsets) |offset| for (counters) |counter| for (modes) |mode| {
            chunks(lanes, key, input.ptr + offset, counter, mode, workspace, actual);
            for (0..lanes) |lane| {
                var cv = key;
                for (0..blocks_per_chunk) |block| {
                    const begin = offset + lane * chunk_bytes + block * block_bytes;
                    const words = loadBlock(input[begin..][0..block_bytes]);
                    const start_flag: u32 = if (block == 0) flags.chunk_start else 0;
                    const last_block = block == blocks_per_chunk - 1;
                    const end_flag: u32 = if (last_block) flags.chunk_end else 0;
                    cv = chaining(
                        .scalar,
                        cv,
                        words,
                        counter + lane,
                        block_bytes,
                        mode | start_flag | end_flag,
                    );
                }
                expected[lane] = cv;
            }
            try testing.expectEqual(expected.*, actual.*);
        };

        for (children, 0..) |*cv, i| for (cv, 0..) |*word, j| {
            word.* = @truncate((i + 1) *% 0xdeadbeef +% j *% 0xabcdef01);
        };
        for (0..lanes) |i| {
            const block = children[i * 2] ++ children[i * 2 + 1];
            expected[i] = chaining(.scalar, key, block, 0, block_bytes, flags.parent);
        }
        parents(lanes, key, children, 0, workspace, @ptrCast(children));
        try testing.expectEqual(expected.*, children[0..lanes].*);
    }
}

test "parent batches preserve children across every direction of overlap" {
    var children: [128]Cv = undefined;
    for (&children, 0..) |*cv, i| for (cv, 0..) |*word, j| {
        word.* = @truncate((i * 8 + j) *% 0x9e3779b9);
    };
    // SHA-256 fingerprints of all 64 parent CVs in little-endian order, independently generated
    // with upstream BLAKE3 1.8.7's blake3_compress_xof_portable, revision
    // f3149ec5bb5449af877ba20377a11008ff499fa2 (c/blake3_portable.c).
    const fingerprints = [_][]const u8{
        "7f1ec84215e0221e663ffd08503e116a4cab841f753cf52cdd424363f74c7f17",
        "3f41ec13ab45957cc2a9e4e8c8413d9b576e63016f9425753d2b643e706bc0a2",
        "de9d884b7bdafb7acee51bfe3e59f52c25188e9ccb47a39068ff97d91ec06654",
        "ff32945a9acdd4b4bb834dd4cadd36c0e03cd5668aae80b393db0794a0f77682",
    };
    for ([_]u32{ 0, 16, 32, 64 }, fingerprints) |mode, fingerprint| {
        var expected: [64]Cv = undefined;
        var encoded: [64 * 32]u8 = undefined;
        for (&expected, 0..) |*cv, i| {
            const block = children[i * 2] ++ children[i * 2 + 1];
            cv.* = chaining(.scalar, iv, block, 0, block_bytes, mode | flags.parent);
            storeCv(cv.*, encoded[i * 32 ..][0..32]);
        }
        var actual_fingerprint: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&encoded, &actual_fingerprint, .{});
        var expected_fingerprint: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected_fingerprint, fingerprint);
        try testing.expectEqual(expected_fingerprint, actual_fingerprint);

        for ([_]usize{ 1, 2, 4, 8, 16, 32, 64 }) |count| {
            // Word offsets also exercise overlap between CV boundaries. The separate guards detect
            // writes outside the output, including accidental child preservation.
            const words = count * 8;
            const offsets = [_]isize{
                -@as(isize, @intCast(words)) - 1,
                -1,
                0,
                1,
                7,
                8,
                9,
                @intCast(words / 2 - 1),
                @intCast(words / 2),
                @intCast(words / 2 + 1),
                @intCast(words - 1),
                @intCast(words),
                @intCast(words + 1),
                @intCast(words * 2 - 9),
                @intCast(words * 2 - 8),
                @intCast(words * 2 - 1),
                @intCast(words * 2),
                @intCast(words * 2 + 1),
            };
            for (offsets) |offset| {
                var memory: [260 * 8]u32 = @splat(0xa7a7a7a7);
                const input_start = 65 * 8;
                const input: [*]Cv = @ptrCast(memory[input_start..].ptr);
                @memcpy(input[0 .. count * 2], children[0 .. count * 2]);
                const before = memory;
                const output_start: usize = @intCast(input_start + offset);
                const output: [*]Cv = @ptrCast(memory[output_start..].ptr);
                var messages: [256]u32 align(64) = undefined;
                batchParents(iv, input, mode, count, &messages, output);
                try testing.expectEqualSlices(Cv, expected[0..count], output[0..count]);
                try testing.expectEqualSlices(
                    u32,
                    before[0..output_start],
                    memory[0..output_start],
                );
                const output_end = output_start + words;
                try testing.expectEqualSlices(u32, before[output_end..], memory[output_end..]);
            }
        }
    }
}
