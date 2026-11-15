//! Encode repetitions at backward distance four using prebuilt Huffman codebooks. Sampled costs
//! select distributions suited to small byte residuals, while stored fallback bounds expansion. The
//! block encoder serves full and compact streams; the short operation needs no workspace. Packing
//! uses only instructions admitted by the compile-time target and respects padded-write margins
//! supplied by each operation.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("format.zig");
const HuffmanCodebook = @import("HuffmanCodebook.zig");
const DynamicBlockHeader = @import("DynamicBlockHeader.zig");
const BlockWriter = @import("BlockWriter.zig");
const EncodeWorkBudget = @import("EncodeWorkBudget.zig");
const addCount = EncodeWorkBudget.addCount;
const writeStoredBody = BlockWriter.writeStoredBody;
const canonical = HuffmanCodebook.canonical;
const lengthSlot = protocol.lengthSlot;
const length_base = protocol.length_base;
const length_extra = protocol.length_extra;
const precode_order = protocol.precode_order;
const runExtra = DynamicBlockHeader.runExtra;
const test_decoding = @import("../deflate.zig");
const test_encoding = @import("encode.zig");
const borrows = @import("block_borrows.zig");
const Encoder = test_encoding.StreamEncoder;
const FourByteRunEncoder = test_encoding.four_byte_runs.StreamEncoder;
const EncoderWorkspace = @import("EncodeWorkspace.zig");
const FourByteRunEncoderWorkspace = @import("FourByteRunWorkspace.zig");
const EncodeOptions = test_encoding.Options;
const CompactOptions = test_encoding.four_byte_runs.Options;
const EncodeAction = test_encoding.Action;
const encode = test_encoding.into;
const encodeBound = test_encoding.bound;

const slab_bytes = 65535;

// Prebuilt literal/length trees avoid constructing a Huffman tree for each run block. The
// zero-dominant tree gives zero a one-bit code; the balanced tree spends two bits on zero for
// shorter neighboring literals and long-run tokens. The zero/255-heavy tree favors zero and 255.
// The latter two cover thirty-two edge bytes with eight-bit codes for vector lookup and use
// twelve-bit middle codes. sampleRunBook prices sampled literals and runs; every tree retains the
// fourteen-bit writer cap.
const zero_dominant_book: Codebook = Codebook.init(
    .{
        1,  3,  4,  6,  7,  7,  8,  8,  9,  9,  9,  10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11,
        11, 12, 12, 12, 12, 12, 12, 12, 12, 13, 12, 13, 13, 13, 13, 13, 13, 13, 13, 13, 14, 13, 13,
        13, 14, 14, 13, 14, 13, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
        14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
        14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
        14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
        14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
        14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
        14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 13,
        14, 13, 13, 13, 13, 13, 13, 13, 13, 13, 14, 13, 13, 13, 13, 13, 13, 13, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 11, 12, 11, 12, 11, 11, 11, 11, 11, 10, 10, 10, 10, 10, 9,  9,  8,  7,  6,
        5,  4,  4,  14, 7,  6,  8,  9,  9,  8,  9,  11, 9,  11, 10, 11, 10, 11, 12, 13, 12, 13, 14,
        14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
    },
);

const balanced_book: Codebook = Codebook.init(
    .{
        2,  3,  4,  5,  6,  6,  6,  7,  7,  7,  7,  8,  8,  8,  8,  8,  12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 8,  8,  8,  8,  8,  7,  7,  7,  7,  7,  6,  6,  5,
        5,  4,  3,  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 11, 10, 11, 12,
        12, 10, 10, 11, 11, 11, 11, 12, 12, 5,
    },
);

// This zero/255-heavy tree reserves short codes for zero and 255, while all thirty-two edge bytes
// fit vector lookup. Middle bytes use twelve bits; lengths retain the fourteen-bit cap.
const zero_255_heavy_book: Codebook = Codebook.init(
    .{
        1,  5,  6,  7,  7,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  7,
        7,  6,  2,  14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 12, 11, 12, 13,
        13, 11, 12, 12, 13, 12, 13, 13, 13, 7,
    },
);

const run_books = [_]*const Codebook{ &zero_dominant_book, &balanced_book, &zero_255_heavy_book };

const CodebookChoice = enum {
    zero_dominant,
    balanced,
    zero_255_heavy,

    inline fn book(choice: CodebookChoice) *const Codebook {
        return switch (choice) {
            .zero_dominant => &zero_dominant_book,
            .balanced => &balanced_book,
            .zero_255_heavy => &zero_255_heavy_book,
        };
    }
};

// Relative prices preserve the absolute comparison, including each rounded per-byte match price.
// Adjacent signed fields keep both alternatives together for each sampled symbol or length.
const LiteralPriceDelta = packed struct(u16) { balanced: i8, zero_255_heavy: i8 };

const MatchPriceDelta = packed struct(u32) { balanced: i16, zero_255_heavy: i16 };

const run_literal_price_deltas: [256]LiteralPriceDelta = blk: {
    var deltas: [256]LiteralPriceDelta = undefined;
    for (
        &deltas,
        0..,
    ) |*delta, symbol| delta.* = .{
        .balanced = @intCast(
            @as(
                i16,
                balanced_book.header.literal.widths[symbol],
            ) - zero_dominant_book.header.literal.widths[symbol],
        ),
        .zero_255_heavy = @intCast(
            @as(
                i16,
                zero_255_heavy_book.header.literal.widths[symbol],
            ) - zero_dominant_book.header.literal.widths[symbol],
        ),
    };
    break :blk deltas;
};

const run_match_price_deltas: [259]MatchPriceDelta = blk: {
    @setEvalBranchQuota(10_000);
    var deltas: [259]MatchPriceDelta = @splat(.{ .balanced = 0, .zero_255_heavy = 0 });
    for (3..259) |length| {
        const zero_dominant = sampleMatchPrice(&zero_dominant_book, length);
        deltas[length] = .{
            .balanced = @intCast(
                @as(i32, sampleMatchPrice(&balanced_book, length)) - zero_dominant,
            ),
            .zero_255_heavy = @intCast(
                @as(i32, sampleMatchPrice(&zero_255_heavy_book, length)) - zero_dominant,
            ),
        };
    }
    break :blk deltas;
};

const Codebook = struct {
    /// Immutable payload/precode books and their code-length description.
    header: DynamicBlockHeader,
    /// Complete bytes of the prebuilt nonfinal dynamic header.
    header_wire: [96]u8,
    /// Initialized header_wire prefix; the remaining low bits are separate.
    header_bytes: usize,
    /// Header bits following its complete-byte prefix.
    header_tail: u64,
    /// Low bits retained in header_tail, fewer than eight.
    header_count: u8,
    /// Length-indexed packed distance-four match: low 24 bits are payload, high byte is width.
    match_tokens: [259]u32,
    /// Literal code in the low half and its width mask in the high half, used by PEXT packing.
    literal_lanes: [256]u32,
    /// Replicated edge-byte code/mask tables for vector shuffles.
    planes: [2][2]@Vector(32, u8),
    /// Both sixteen-byte edge ranges have codes no wider than eight bits.
    wide_edges: bool,
    /// Byte bias mapping the admitted literal range into shuffle indices.
    offset: u8,
    /// Exclusive biased-index limit admitted by the vector lookup.
    limit: u8,

    fn init(comptime widths: [286]u8) Codebook {
        @setEvalBranchQuota(200_000);
        var value: Codebook = std.mem.zeroes(Codebook);
        var capacity: u32 = 0;
        for (widths) |width| {
            if (width == 0 or width > 14) @compileError("invalid fixed run code width");
            capacity += @as(u32, 1) << @intCast(14 - width);
        }
        if (capacity != 1 << 14) @compileError("fixed run book must be complete");
        value.header.literal.widths = widths;
        canonical(&value.header.literal);
        value.header.distance.widths[3] = 1;
        canonical(&value.header.distance);
        @memset(value.header.precode.widths[0..15], 4);
        value.header.precode.widths[15] = 5;
        value.header.precode.widths[16] = 5;
        canonical(&value.header.precode);
        value.header.literal_count = 286;
        value.header.distance_count = 4;
        value.header.precode_count = 19;
        value.header.bits = 14 + 19 * 3;
        var all_widths: [290]u8 = undefined;
        @memcpy(all_widths[0..286], &widths);
        @memcpy(all_widths[286..290], value.header.distance.widths[0..4]);
        var pos: usize = 0;
        while (pos < all_widths.len) {
            const width = all_widths[pos];
            var end = pos + 1;
            while (end < all_widths.len and all_widths[end] == width) : (end += 1) {}
            value.header.runs[value.header.run_count] = .{ .symbol = width, .extra = 0 };
            value.header.run_count += 1;
            value.header.bits += value.header.precode.widths[width];
            pos += 1;
            while (end - pos >= 3) {
                const take = @min(6, end - pos);
                value.header.runs[value.header.run_count] = .{
                    .symbol = 16,
                    .extra = @intCast(take - 3),
                };
                value.header.run_count += 1;
                value.header.bits += value.header.precode.widths[16] + 2;
                pos += take;
            }
            while (pos < end) : (pos += 1) {
                value.header.runs[value.header.run_count] = .{ .symbol = width, .extra = 0 };
                value.header.run_count += 1;
                value.header.bits += value.header.precode.widths[width];
            }
        }

        for (3..259) |length| {
            const slot = lengthSlot(length);
            const code_width = value.header.literal.widths[257 + @as(usize, slot)];
            const extra_width = length_extra[slot];
            const code = @as(
                u32,
                value.header.literal.codes[257 + @as(usize, slot)],
            ) | (@as(u32, @intCast(length - length_base[slot])) << @intCast(code_width));
            const width = code_width + extra_width + 1;
            if (width > 24) @compileError("run match token exceeds its payload");
            value.match_tokens[length] = code | (@as(u32, width) << 24);
        }
        for (&value.literal_lanes, 0..) |*lane, symbol| {
            const width = widths[symbol];
            const mask: u16 = (@as(u16, 1) << @as(u4, @intCast(width))) - 1;
            lane.* = value.header.literal.codes[symbol] | (@as(u32, mask) << 16);
        }
        value.wide_edges = true;
        for (0..16) |i| {
            if (widths[i] > 8 or widths[240 + i] > 8) value.wide_edges = false;
        }
        value.offset = if (value.wide_edges) 16 else 6;
        value.limit = if (value.wide_edges) 32 else 14;
        var planes: [2][2][32]u8 = @splat(@splat(@splat(0)));
        if (value.wide_edges) {
            for (0..2) |side| for (0..32) |i| {
                const symbol = i % 16 + side * 240;
                planes[side][0][i] = @intCast(value.header.literal.codes[symbol]);
                planes[side][1][i] = @truncate(value.literal_lanes[symbol] >> 16);
            };
        } else {
            for (0..32) |i| {
                const index = i % 16;
                if (index >= 14) continue;
                const symbol = (index + 250) % 256;
                if (widths[symbol] > 8) @compileError("short run edge exceeds eight bits");
                planes[0][0][i] = @intCast(value.header.literal.codes[symbol]);
                planes[0][1][i] = @truncate(value.literal_lanes[symbol] >> 16);
            }
        }
        value.planes = .{ .{ planes[0][0], planes[0][1] }, .{ planes[1][0], planes[1][1] } };
        var writer: PackedWriter = .{
            .book = &value,
            .wire = &value.header_wire,
            .bits = 0,
            .count = 0,
            .pending = 0,
        };
        writer.put(0, 1);
        writer.put(2, 2);
        writer.put(value.header.literal_count - 257, 5);
        writer.put(value.header.distance_count - 1, 5);
        writer.put(value.header.precode_count - 4, 4);
        for (precode_order[0..value.header.precode_count]) |symbol| {
            writer.put(value.header.precode.widths[symbol], 3);
        }
        for (value.header.runs[0..value.header.run_count]) |run| {
            writer.symbol(&value.header.precode, run.symbol);
            writer.put(run.extra, runExtra(run.symbol));
        }
        writer.flush();
        value.header_bytes = writer.pending;
        value.header_tail = writer.bits;
        value.header_count = writer.count;
        if (writer.pending >= value.header_wire.len or writer.count >= 8) {
            @compileError("fixed run header exceeds its staging");
        }
        return value;
    }
};

const pext_run_literals = blk: {
    if (builtin.cpu.arch != .x86_64) break :blk false;
    // Keep FPNGE's scalar selection for these older AMD compiler targets.
    if (builtin.cpu.model == &std.Target.x86.cpu.znver1 or builtin.cpu.model == &std.Target.x86.cpu
        .znver2 or builtin.cpu.model == &std.Target.x86.cpu.bdver4) break :blk false;
    break :blk std.Target.x86.featureSetHasAll(builtin.cpu.features, &.{ .bmi2, .popcnt });
};

const vector_run_matches = switch (builtin.cpu.arch) {
    .x86, .x86_64 => std.Target.x86.featureSetHasAll(builtin.cpu.features, &.{.avx2}),
    else => false,
};

const run_literal_shuffle: @Vector(
    16,
    i32,
) = .{ 0, 1, 4, 5, 8, 9, 12, 13, 2, 3, 6, 7, 10, 11, 14, 15 };

const vector_run_octets = pext_run_literals and std.Target.x86.featureSetHasAll(
    builtin.cpu.features,
    &.{.avx2},
);

// Snapshot the immutable vector lookup once per block, independently of the mutable writer.
const LiteralLookup = struct {
    /// Replicated literal code/mask shuffle tables copied from the immutable selected book.
    planes: [2][2]@Vector(32, u8),
    /// Wrapping byte bias that maps admitted literals into shuffle indices.
    offset: u8,
    /// Exclusive biased-index limit for the admitted literal ranges.
    limit: u8,
    /// Tables cover both sixteen-byte edge ranges rather than the narrower zero-centered range.
    wide_edges: bool,

    inline fn init(book: *const Codebook) LiteralLookup {
        return .{
            .planes = book.planes,
            .offset = book.offset,
            .limit = book.limit,
            .wide_edges = book.wide_edges,
        };
    }
};

const PackedWriter = struct {
    /// Immutable selected distribution, separate from this mutable cursor.
    book: *const Codebook,
    /// Staged output with the wide-store margins required by putBytes/symbolSpan32.
    wire: []u8,
    /// Low pending payload bits.
    bits: u64,
    /// Pending bit count; each packing operation maintains its documented bound below 64.
    count: u8,
    /// Complete-byte prefix already emitted into wire.
    pending: usize,

    inline fn put(self: *PackedWriter, value: usize, width: u8) void {
        self.bits |= @as(u64, @intCast(value)) << @as(u6, @intCast(self.count));
        self.count += width;
        if (self.count >= 32) {
            std.mem.writeInt(u32, self.wire[self.pending..][0..4], @truncate(self.bits), .little);
            self.pending += 4;
            self.bits >>= 32;
            self.count -= 32;
        }
    }

    inline fn flush(self: *PackedWriter) void {
        if (self.count >= 16) {
            std.mem.writeInt(u16, self.wire[self.pending..][0..2], @truncate(self.bits), .little);
            self.pending += 2;
            self.bits >>= 16;
            self.count -= 16;
        }
        if (self.count >= 8) {
            self.wire[self.pending] = @truncate(self.bits);
            self.pending += 1;
            self.bits >>= 8;
            self.count -= 8;
        }
    }

    inline fn symbol(self: *PackedWriter, book: *const HuffmanCodebook, value: usize) void {
        self.put(book.codes[value], book.widths[value]);
    }

    // The caller keeps fewer than eight pending bits; four literals add at most 56.
    inline fn symbolQuad(self: *PackedWriter, values: *const [4]u8) void {
        var codes: u64 = 0;
        var width: u8 = 0;
        if (comptime pext_run_literals) {
            const joined = pextRunQuad(self.book, values);
            codes = joined.bits;
            width = joined.width;
        } else {
            var count: u6 = 0;
            inline for (0..4) |i| {
                const value = values[i];
                codes |= @as(u64, self.book.header.literal.codes[value]) << count;
                count += @intCast(self.book.header.literal.widths[value]);
            }
            width = count;
        }
        self.putBytes(codes, width);
    }

    inline fn symbolSpan32(self: *PackedWriter, values: *const [32]u8, lookup: LiteralLookup) void {
        if (comptime vector_run_octets) {
            const bytes: @Vector(32, u8) = values.*;
            const indices = bytes +% @as(@Vector(32, u8), @splat(lookup.offset));
            if (@reduce(.And, indices < @as(@Vector(32, u8), @splat(lookup.limit)))) {
                var planes: [2]@Vector(32, u8) = undefined;
                if (lookup.wide_edges) {
                    inline for (0..2) |plane| {
                        const low = asm ("vpshufb %[indices], %[table], %[result]"
                            : [result] "=v" (-> @Vector(32, u8)),
                            : [table] "v" (lookup.planes[0][plane]),
                              [indices] "v" (indices),
                        );
                        const high = asm ("vpshufb %[indices], %[table], %[result]"
                            : [result] "=v" (-> @Vector(32, u8)),
                            : [table] "v" (lookup.planes[1][plane]),
                              [indices] "v" (indices),
                        );
                        planes[plane] = @select(
                            u8,
                            bytes < @as(@Vector(32, u8), @splat(16)),
                            low,
                            high,
                        );
                    }
                } else {
                    inline for (
                        0..2,
                    ) |plane| planes[plane] = asm ("vpshufb %[indices], %[table], %[result]"
                        : [result] "=v" (-> @Vector(32, u8)),
                        : [table] "v" (lookup.planes[0][plane]),
                          [indices] "v" (indices),
                    );
                }
                const codes: @Vector(4, u64) = @bitCast(planes[0]);
                const masks: @Vector(4, u64) = @bitCast(planes[1]);
                inline for (0..4) |i| {
                    const joined = asm ("pext %[mask], %[bits], %[result]"
                        : [result] "=r" (-> u64),
                        : [bits] "r" (codes[i]),
                          [mask] "r" (masks[i]),
                    );
                    const width: u8 = @intCast(@popCount(masks[i]));
                    if (self.count + width >= 64) {
                        self.put(@as(u32, @truncate(joined)), 32);
                        self.putBytes(joined >> 32, width - 32);
                    } else {
                        self.putBytes(joined, width);
                    }
                }
                return;
            }
        }
        inline for (0..8) |i| self.symbolQuad(values[i * 4 ..][0..4]);
    }

    inline fn runMatch(self: *PackedWriter, length: usize) void {
        // The fixed token has at most 24 bits; the ordinary writer retains fewer than 32.
        const token = self.book.match_tokens[length];
        self.putBytes(token & 0x00ffffff, @intCast(token >> 24));
    }

    // Like FPNGE's writer, normalize the complete-byte prefix with one padded store. Callers supply
    // eight writable bytes and a total below 64 bits; fewer than eight remain.
    inline fn putBytes(self: *PackedWriter, codes: u64, width: u8) void {
        std.debug.assert(self.count + width < 64);
        self.bits |= codes << @as(u6, @intCast(self.count));
        self.count += width;
        std.mem.writeInt(u64, self.wire[self.pending..][0..8], self.bits, .little);
        const complete = self.count & ~@as(u8, 7);
        self.pending += complete / 8;
        self.bits >>= @as(u6, @intCast(complete));
        self.count -= complete;
    }
};

fn sampleMatchPrice(book: *const Codebook, length: usize) u16 {
    return @intCast(((book.match_tokens[length] >> 24) * 256 + length / 2) / length);
}

// FPNGE uses PEXT to join variable-length codes. Here four code/mask pairs preserve the existing
// fixed book, including its variable middle-symbol widths.
// https://github.com/veluca93/fpnge/blob/097ebccf3d3db443d9a8f238b1deed010a82f961/fpnge.cc
inline fn pextRunQuad(book: *const Codebook, values: *const [4]u8) struct { bits: u64, width: u8 } {
    const entries: @Vector(
        4,
        u32,
    ) = .{
        book.literal_lanes[values[0]],
        book.literal_lanes[values[1]],
        book.literal_lanes[values[2]],
        book.literal_lanes[values[3]],
    };
    const bytes: @Vector(16, u8) = @bitCast(entries);
    const lanes: @Vector(2, u64) = @bitCast(@shuffle(u8, bytes, undefined, run_literal_shuffle));
    const bits = asm ("pext %[mask], %[bits], %[result]"
        : [result] "=r" (-> u64),
        : [bits] "r" (lanes[0]),
          [mask] "r" (lanes[1]),
    );
    return .{ .bits = bits, .width = @intCast(@popCount(lanes[1])) };
}

/// Each slice/counter borrows the active block. Immutable literal lookup is snapshotted separately
/// from PackedWriter so mutable output state does not alias its vector tables.
pub const BlockEncoder = struct {
    /// Copied history followed by the source slab; only history + buffered bytes are initialized.
    data: []const u8,
    /// Source-slab offset; run matching only needs up to four preceding bytes.
    history: usize,
    /// Active source bytes to encode.
    buffered: usize,
    /// Borrowed staged output, including the bounded wide-store margin.
    wire: []u8,
    /// Stream-owned pending bits, shared with writer.
    bits: *u64,
    /// Stream-owned pending-bit count, shared with writer.
    bit_count: *u6,
    /// Stream-owned staged-byte count, shared with writer.
    pending: *usize,
    /// Cumulative allowance. Aggregate paths publish admitted local work on both success and error.
    work: EncodeWorkBudget,
    /// Same cursor/output/counters, used if the stored representation wins.
    writer: BlockWriter,

    /// Emit one block. The zero-dominant book's empty dynamic block needs 663 bits; through 35
    /// source bytes a stored block costs at most 322 bits, even at the worst incoming alignment.
    pub fn encode(self: BlockEncoder, final: bool) EncodeWorkBudget.Error!void {
        if (self.buffered <= 35) {
            return self.writer.stored(self.data[self.history..][0..self.buffered], final);
        }
        return self.encodeFourByteRuns(final);
    }
    // Charge each comparison, including the mismatch that ends a run.
    pub inline fn runLength(
        self: BlockEncoder,
        position: usize,
        end: usize,
        comptime bounded: bool,
        comptime unroll_long: bool,
        units: *u64,
        probes: *u64,
    ) EncodeWorkBudget.Error!usize {
        if (position < 4) return 1;
        if (bounded) {
            try self.work.admit(1);
            self.work.stats.match_probes = try addCount(self.work.stats.match_probes, 1);
        } else {
            units.* += 1;
            probes.* += 1;
        }
        const data = self.data;
        if (data[position] != data[position - 4]) return 1;
        const maximum = @min(258, end - position);
        var length: usize = 1;
        if (!bounded) {
            // Wide comparisons may inspect later bytes. Charge only the logical prefix through the
            // first mismatch, matching the bounded byte-wise path.
            if (comptime vector_run_matches) {
                // Most grouped candidates end quickly. Keep their first probe on the cheap word
                // path, then use vectors only after eight bytes agree.
                if (!unroll_long and maximum - length >= 8) {
                    const a = std.mem.readInt(u64, data[position + length ..][0..8], .little);
                    const b = std.mem.readInt(u64, data[position + length - 4 ..][0..8], .little);
                    const difference = a ^ b;
                    if (difference != 0) {
                        const matched = @as(usize, @intCast(@ctz(difference))) / 8;
                        units.* += matched + 1;
                        return length + matched;
                    }
                    units.* += 8;
                    length += 8;
                }
                while (maximum - length >= 32) {
                    const a: @Vector(32, u8) = data[position + length ..][0..32].*;
                    const b: @Vector(32, u8) = data[position + length - 4 ..][0..32].*;
                    const different: u32 = @bitCast(a != b);
                    if (different != 0) {
                        const matched: usize = @ctz(different);
                        units.* += matched + 1;
                        return length + matched;
                    }
                    units.* += 32;
                    length += 32;
                }
            } else if (unroll_long and maximum - length >= 32) {
                while (maximum - length >= 16) {
                    inline for (0..2) |group| {
                        const offset = length + group * 8;
                        const a = std.mem.readInt(u64, data[position + offset ..][0..8], .little);
                        const b = std.mem.readInt(
                            u64,
                            data[position + offset - 4 ..][0..8],
                            .little,
                        );
                        const difference = a ^ b;
                        if (difference != 0) {
                            const matched = @as(usize, @intCast(@ctz(difference))) / 8;
                            units.* += group * 8 + matched + 1;
                            return offset + matched;
                        }
                    }
                    units.* += 16;
                    length += 16;
                }
            }
            while (maximum - length >= 8) {
                const a = std.mem.readInt(u64, data[position + length ..][0..8], .little);
                const b = std.mem.readInt(u64, data[position + length - 4 ..][0..8], .little);
                const difference = a ^ b;
                if (difference != 0) {
                    const matched = @as(usize, @intCast(@ctz(difference))) / 8;
                    units.* += matched + 1;
                    return length + matched;
                }
                units.* += 8;
                length += 8;
            }
        }
        while (length < maximum) {
            if (bounded) try self.work.admit(1) else {
                units.* += 1;
            }
            if (data[position + length] != data[position + length - 4]) break;
            length += 1;
        }
        return length;
    }

    // Thirty-two spread windows estimate emitted literal and run prices. Each candidate extends at
    // most 258 bytes; the first four source bytes may need literal seeding.
    pub noinline fn sampleRunBook(
        self: BlockEncoder,
        comptime bounded: bool,
        units: *u64,
        probes: *u64,
    ) EncodeWorkBudget.Error!CodebookChoice {
        std.debug.assert(self.buffered >= 8192);
        const prefix = 4 -| self.history;
        const zero_dominant_header: i64 = 3 + zero_dominant_book.header.bits + zero_dominant_book
            .header.literal.widths[256];
        var balanced_header_delta: i64 = 3 + balanced_book.header.bits + balanced_book.header
            .literal.widths[256] - zero_dominant_header;
        var zero_255_header_delta: i64 = 3 + zero_255_heavy_book.header.bits + zero_255_heavy_book
            .header.literal.widths[256] - zero_dominant_header;
        if (bounded) try self.work.admit(prefix) else units.* += prefix;
        for (self.data[self.history..][0..prefix]) |value| {
            const delta = run_literal_price_deltas[value];
            balanced_header_delta += delta.balanced;
            zero_255_header_delta += delta.zero_255_heavy;
        }
        var balanced_sample_delta: i32 = 0;
        var zero_255_sample_delta: i32 = 0;
        const end = self.history + self.buffered;
        for (0..32) |i| {
            const position = self.history + prefix + i * (self.buffered - prefix - 258) / 31;
            const length = try self.runLength(position, end, bounded, true, units, probes);
            if (length >= 32) {
                const delta = run_match_price_deltas[length];
                balanced_sample_delta += delta.balanced;
                zero_255_sample_delta += delta.zero_255_heavy;
            } else {
                if (bounded) try self.work.admit(32) else units.* += 32;
                var balanced_literal_delta: i32 = 0;
                var zero_255_literal_delta: i32 = 0;
                for (self.data[position..][0..32]) |value| {
                    const delta = run_literal_price_deltas[value];
                    balanced_literal_delta += delta.balanced;
                    zero_255_literal_delta += delta.zero_255_heavy;
                }
                balanced_sample_delta += balanced_literal_delta * 8;
                zero_255_sample_delta += zero_255_literal_delta * 8;
            }
        }
        const bytes: i64 = @intCast(self.buffered - prefix);
        var choice: CodebookChoice = .zero_dominant;
        var best: i64 = 0;
        const balanced = @as(
            i64,
            balanced_sample_delta,
        ) * bytes + balanced_header_delta * (256 * 32);
        if (balanced < best) {
            choice = .balanced;
            best = balanced;
        }
        if (@as(
            i64,
            zero_255_sample_delta,
        ) * bytes + zero_255_header_delta * (256 * 32) < best) return .zero_255_heavy;
        return choice;
    }

    pub noinline fn preferStoredRuns(
        self: BlockEncoder,
        comptime bounded: bool,
        units: *u64,
        probes: *u64,
        group_literals: *bool,
        selected_choice: *CodebookChoice,
    ) EncodeWorkBudget.Error!bool {
        var header = &zero_dominant_book.header;
        selected_choice.* = .zero_dominant;
        if (self.buffered >= 4096) {
            const n: usize = 256;
            if (bounded) try self.work.admit(n) else {
                units.* += n;
            }
            if (self.buffered >= 8192) {
                selected_choice.* = try self.sampleRunBook(bounded, units, probes);
                header = &selected_choice.*.book().header;
            }
            var sample_bits: usize = 0;
            var matches: usize = 0;
            for (0..n) |i| {
                const pos = self.history + i * (self.buffered - 1) / (n - 1);
                const value = self.data[pos];
                sample_bits += header.literal.widths[value];
                if (pos >= 4) {
                    if (bounded) self.work.stats.match_probes = try addCount(
                        self.work.stats.match_probes,
                        1,
                    ) else {
                        probes.* += 1;
                    }
                    if (value == self.data[pos - 4]) matches += 1;
                }
                if (!bounded and i % 32 == 31 and matches >= n / 32) {
                    const remaining = n - 1 - i;
                    if (matches >= 224 or matches + remaining < 224) {
                        // All remaining positions are eligible once eight matches have been seen.
                        // Charge their logical probes even though the decision is already fixed.
                        probes.* += remaining;
                        group_literals.* = matches < 224;
                        return false;
                    }
                    // The stored choice is now impossible. Sample subsequent positions in groups of
                    // 32, checking the same thresholds at the same boundaries.
                    var block = i + 1;
                    while (block < n) : (block += 32) {
                        var j = block;
                        while (j < block + 32) : (j += 4) {
                            inline for (0..4) |lane| {
                                const next = self.history + (j + lane) * (self.buffered - 1) / (n -
                                    1);
                                matches += @intFromBool(self.data[next] == self.data[next - 4]);
                            }
                        }
                        probes.* += 32;
                        const rest = n - block - 32;
                        if (matches >= 224 or matches + rest < 224) {
                            probes.* += rest;
                            group_literals.* = matches < 224;
                            return false;
                        }
                    }
                    group_literals.* = matches < 224;
                    return false;
                }
            }
            // Keep the match-density result for stored preflight and small-block parsing. Larger
            // blocks use spans; small repetitive blocks retain byte-wise matching.
            group_literals.* = matches < 224;
            if (sample_bits > n * 10 and matches < n / 32) {
                const padding = (8 - (@as(u32, self.bit_count.*) + 3) % 8) % 8;
                const stored_bits: usize = 3 + padding + 32 + self.buffered * 8;
                return self.groupedRunsPreferStored(
                    selected_choice.*.book(),
                    bounded,
                    units,
                    probes,
                    stored_bits,
                );
            }
        }
        return false;
    }

    pub noinline fn groupedRunsPreferStored(
        self: BlockEncoder,
        book: *const Codebook,
        comptime bounded: bool,
        units: *u64,
        probes: *u64,
        stored_bits: usize,
    ) EncodeWorkBudget.Error!bool {
        const header = &book.header;
        var predicted: usize = 3 + header.bits + header.literal.widths[256];
        var cursor = self.history;
        const end = self.history + self.buffered;
        while (cursor < end and predicted < stored_bits) {
            // Match the span policy and strict writer cutoff, excluding the reserved end code.
            if (cursor >= 4 and end - cursor >= 32 and predicted - header.literal.widths[256] +
                448 < stored_bits)
            {
                if (bounded) {
                    try self.work.admit(32);
                    self.work.stats.match_probes = try addCount(self.work.stats.match_probes, 1);
                } else {
                    units.* += 32;
                    probes.* += 1;
                }
                const current: @Vector(32, u8) = self.data[cursor..][0..32].*;
                const prior: @Vector(32, u8) = self.data[cursor - 4 ..][0..32].*;
                if (@reduce(.And, current == prior)) {
                    const length = try self.runLength(cursor, end, bounded, false, units, probes);
                    predicted += book.match_tokens[length] >> 24;
                    cursor += length;
                } else {
                    for (self.data[cursor..][0..32]) |value| {
                        predicted += header.literal.widths[value];
                    }
                    cursor += 32;
                }
                continue;
            }
            if (cursor >= 4 and end - cursor >= 4) {
                if (bounded) {
                    try self.work.admit(4);
                    self.work.stats.match_probes = try addCount(self.work.stats.match_probes, 1);
                } else {
                    units.* += 4;
                    probes.* += 1;
                }
                const current = std.mem.readInt(u32, self.data[cursor..][0..4], .little);
                const prior = std.mem.readInt(u32, self.data[cursor - 4 ..][0..4], .little);
                if (((current ^ prior) & 0x00ffffff) != 0) {
                    var literal_bits: usize = 0;
                    for (
                        self.data[cursor..][0..4],
                    ) |value| literal_bits += header.literal.widths[value];
                    if (predicted - header.literal.widths[256] + literal_bits < stored_bits) {
                        predicted += literal_bits;
                        cursor += 4;
                        continue;
                    }
                }
            }
            const length = try self.runLength(cursor, end, bounded, false, units, probes);
            if (length >= 3) {
                const slot = lengthSlot(length);
                predicted += header.literal.widths[
                    257 + @as(
                        usize,
                        slot,
                    )
                ] + @as(usize, length_extra[slot]) + 1;
                cursor += length;
            } else {
                predicted += header.literal.widths[self.data[cursor]];
                cursor += 1;
            }
        }
        return predicted >= stored_bits;
    }

    // Prebuilt books favor byte residuals. Stored blocks bound expansion when the selected book
    // does not fit; the strategy deliberately does not search other match distances.
    pub noinline fn encodeFourByteRuns(
        self: BlockEncoder,
        final: bool,
    ) EncodeWorkBudget.Error!void {
        // Fixed-book initialization is bounded and is not charged as input-dependent work.
        const n: u64 = @intCast(self.buffered);
        // Sample plus both preflight and emission scans, including rejected grouped attempts.
        const book_work: u64 = if (n >= 8192) 32 * 258 + 4 else 0;
        const book_probes: u64 = if (n >= 8192) 32 else 0;
        const work_bound = 14 * n + 256 + book_work;
        const probe_bound = 4 * n + 256 + book_probes;
        if (self.work.limit -| self.work.stats.work_units >= work_bound and self.work.stats
            .match_probes <= std.math.maxInt(
            u64,
        ) - probe_bound) {
            return self.encodeRunsWithAccounting(final, false);
        }
        return self.encodeRunsWithAccounting(final, true);
    }

    pub noinline fn encodeRunsWithAccounting(
        self: BlockEncoder,
        final: bool,
        comptime bounded: bool,
    ) align(64) EncodeWorkBudget.Error!void {
        var units: u64 = 0;
        var probes: u64 = 0;
        defer if (!bounded) {
            self.work.stats.work_units += units;
            self.work.stats.match_probes += probes;
        };
        var group_literals = false;
        var choice: CodebookChoice = .zero_dominant;
        if (try self.preferStoredRuns(bounded, &units, &probes, &group_literals, &choice)) {
            return self.writer.stored(self.data[self.history..][0..self.buffered], final);
        }
        if (self.buffered >= 4096 and (group_literals or self.buffered >= 8192)) {
            return self.emitRuns(choice.book(), final, bounded, true, &units, &probes);
        }
        return self.emitRuns(&zero_dominant_book, final, bounded, false, &units, &probes);
    }

    pub inline fn emitRuns(
        self: BlockEncoder,
        book: *const Codebook,
        final: bool,
        comptime bounded: bool,
        comptime grouped: bool,
        units: *u64,
        probes: *u64,
    ) EncodeWorkBudget.Error!void {
        const header = &book.header;
        const start_pending = self.pending.*;
        const start_bits = self.bits.*;
        const start_count = self.bit_count.*;
        // Blocks start after pending bytes have drained. The stored-cost guard keeps staged bits
        // within the slab's byte length plus a small header; wire has 128 extra bytes for a final
        // token, the end code and wide stores.
        std.debug.assert(start_pending == 0 and self.buffered <= slab_bytes);
        const padding = (8 - (@as(u32, start_count) + 3) % 8) % 8;
        const stored_bits: usize = 3 + padding + 32 + self.buffered * 8;
        const limit_bits = stored_bits + start_count;
        const lookup = LiteralLookup.init(book);
        var writer: PackedWriter = .{
            .book = book,
            .wire = self.wire,
            .bits = self.bits.*,
            .count = self.bit_count.*,
            .pending = self.pending.*,
        };
        var publish_on_error = true;
        errdefer if (publish_on_error) {
            writer.flush();
            self.bits.* = writer.bits;
            self.bit_count.* = @intCast(writer.count);
            self.pending.* = writer.pending;
        };
        if (writer.count == 0) {
            std.debug.assert(writer.bits == 0);
            @memcpy(writer.wire[0..book.header_bytes], book.header_wire[0..book.header_bytes]);
            writer.wire[0] |= @intFromBool(final);
            writer.pending = book.header_bytes;
            writer.bits = book.header_tail;
            writer.count = book.header_count;
        } else {
            writer.put(@intFromBool(final), 1);
            writer.put(2, 2);
            writer.put(header.literal_count - 257, 5);
            writer.put(header.distance_count - 1, 5);
            writer.put(header.precode_count - 4, 4);
            for (
                precode_order[0..header.precode_count],
            ) |symbol| writer.put(header.precode.widths[symbol], 3);
            for (header.runs[0..header.run_count]) |run| {
                writer.symbol(&header.precode, run.symbol);
                writer.put(run.extra, runExtra(run.symbol));
            }
        }
        if (grouped) writer.flush();
        var position = self.history;
        const end = self.history + self.buffered;
        var fallback = false;
        while (position < end) {
            if (writer.pending * 8 + writer.count >= limit_bits) {
                fallback = true;
                break;
            }
            // Whole-span parser: reserve runs for complete repeated spans, otherwise emit the span
            // as literals without per-quad match decisions.
            if (grouped and position >= 4 and end - position >= 32 and writer.pending * 8 + writer
                .count + 448 < limit_bits)
            {
                if (bounded) {
                    try self.work.admit(32);
                    self.work.stats.match_probes = try addCount(self.work.stats.match_probes, 1);
                } else {
                    units.* += 32;
                    probes.* += 1;
                }
                const current: @Vector(32, u8) = self.data[position..][0..32].*;
                const prior: @Vector(32, u8) = self.data[position - 4 ..][0..32].*;
                if (@reduce(.And, current == prior)) {
                    const length = try self.runLength(position, end, bounded, false, units, probes);
                    writer.runMatch(length);
                    position += length;
                } else {
                    writer.symbolSpan32(self.data[position..][0..32], lookup);
                    position += 32;
                }
                continue;
            }
            // Loads may include later groups speculatively. Charge only groups whose comparisons
            // are actually reached; each literal needs at most 14 bits, so four groups need 224.
            if (grouped and !bounded and position >= 4 and end - position >= 16 and writer.pending *
                8 + writer.count + 224 < limit_bits)
            {
                const first = std.mem.readInt(
                    u64,
                    self.data[position..][0..8],
                    .little,
                ) ^ std.mem.readInt(u64, self.data[position - 4 ..][0..8], .little);
                const second = std.mem.readInt(
                    u64,
                    self.data[position + 8 ..][0..8],
                    .little,
                ) ^ std.mem.readInt(u64, self.data[position + 4 ..][0..8], .little);
                batch: {
                    inline for (0..4) |i| {
                        units.* += 4;
                        probes.* += 1;
                        const difference = if (i < 2) first else second;
                        if (((difference >> (32 * (i % 2))) & 0x00ffffff) == 0) {
                            const length = try self.runLength(
                                position,
                                end,
                                bounded,
                                false,
                                units,
                                probes,
                            );
                            writer.runMatch(length);
                            position += length;
                            break :batch;
                        }
                        writer.symbolQuad(self.data[position..][0..4]);
                        position += 4;
                    }
                }
                continue;
            }
            // If these three positions cannot begin a match, emit four literals together. A match
            // beginning later in the group may be skipped, trading ratio for fewer parser steps.
            if (grouped and position >= 4 and end - position >= 4) {
                // Admit the attempted four-byte comparison even if it cannot form a group.
                if (bounded) {
                    try self.work.admit(4);
                    self.work.stats.match_probes = try addCount(self.work.stats.match_probes, 1);
                } else {
                    units.* += 4;
                    probes.* += 1;
                }
                const current = std.mem.readInt(u32, self.data[position..][0..4], .little);
                const prior = std.mem.readInt(u32, self.data[position - 4 ..][0..4], .little);
                if (((current ^ prior) & 0x00ffffff) != 0) {
                    const remaining = limit_bits - (writer.pending * 8 + writer.count);
                    // The fixed run book has at most 14 bits per literal; four fit in 56 bits.
                    const fits = if (remaining > 4 * 14) true else blk: {
                        var literal_bits: usize = 0;
                        for (self.data[position..][0..4]) |value| {
                            literal_bits += header.literal.widths[value];
                        }
                        break :blk literal_bits < remaining;
                    };
                    if (fits) {
                        const values = self.data[position..][0..4];
                        writer.symbolQuad(values);
                        position += 4;
                        continue;
                    }
                }
            }
            const length = try self.runLength(position, end, bounded, !grouped, units, probes);
            if (length >= 3) {
                writer.runMatch(length);
                position += length;
            } else {
                writer.symbol(&header.literal, self.data[position]);
                position += 1;
                if (grouped) writer.flush();
            }
        }
        if (!fallback) {
            writer.symbol(&header.literal, 256);
            fallback = writer.pending * 8 + writer.count >= limit_bits;
        }
        if (fallback) {
            self.pending.* = start_pending;
            self.bits.* = start_bits;
            self.bit_count.* = start_count;
            publish_on_error = false;
            return self.writer.stored(self.data[self.history..][0..self.buffered], final);
        }
        writer.flush();
        self.bits.* = writer.bits;
        self.bit_count.* = @intCast(writer.count);
        self.pending.* = writer.pending;
        self.work.stats.blocks = try addCount(self.work.stats.blocks, 1);
        self.work.stats.dynamic_blocks = try addCount(self.work.stats.dynamic_blocks, 1);
    }
};

/// Workspace-free encoding for bounded complete inputs using the zero-dominant run book.
pub const short = struct {
    pub const Error = error{ LimitExceeded, OutputTooSmall, StorageOverlap };

    /// Maximum input length accepted by into.
    pub const max_input_bytes = 2048;

    /// Required output capacity, including temporary wide-write padding.
    pub const output_capacity = max_input_bytes + 128;

    /// Encodes a complete four-byte-run stream without a dictionary or work limit. Source and
    /// output must be disjoint. Output must have output_capacity bytes; the result borrows its
    /// prefix and padding after it may change. Oversized input returns LimitExceeded; length,
    /// capacity and overlap errors precede writes.
    pub fn into(source: []const u8, output: []u8) @This().Error![]u8 {
        if (source.len > max_input_bytes) return error.LimitExceeded;
        if (output.len < output_capacity) return error.OutputTooSmall;
        try disjoint(source, output);
        const wire: *[output_capacity]u8 = output[0..output_capacity];
        var count: usize = 0;
        var fallback = source.len <= 35;
        if (!fallback) {
            @memcpy(
                wire[0..zero_dominant_book.header_bytes],
                zero_dominant_book.header_wire[0..zero_dominant_book.header_bytes],
            );
            wire[0] |= 1;
            var writer: PackedWriter = .{
                .book = &zero_dominant_book,
                .wire = wire,
                .bits = zero_dominant_book.header_tail,
                .count = zero_dominant_book.header_count,
                .pending = zero_dominant_book.header_bytes,
            };
            const limit_bits = 40 + source.len * 8;
            var position: usize = 0;
            while (position < source.len) {
                if (writer.pending * 8 + writer.count >= limit_bits) {
                    fallback = true;
                    break;
                }
                var length: usize = 1;
                if (position >= 4 and source[position] == source[position - 4]) {
                    const maximum = @min(258, source.len - position);
                    while (maximum - length >= 8) {
                        const a = std.mem.readInt(u64, source[position + length ..][0..8], .little);
                        const b = std.mem.readInt(
                            u64,
                            source[position + length - 4 ..][0..8],
                            .little,
                        );
                        const difference = a ^ b;
                        if (difference != 0) {
                            length += @as(usize, @intCast(@ctz(difference))) / 8;
                            break;
                        }
                        length += 8;
                    } else {
                        while (length < maximum and source[position + length] == source[
                            position +
                                length - 4
                        ]) {
                            length += 1;
                        }
                    }
                }
                if (length >= 3) {
                    writer.runMatch(length);
                    position += length;
                } else {
                    writer.symbol(&zero_dominant_book.header.literal, source[position]);
                    position += 1;
                }
            }
            if (!fallback) {
                writer.symbol(&zero_dominant_book.header.literal, 256);
                fallback = writer.pending * 8 + writer.count >= limit_bits;
            }
            if (!fallback) {
                writer.flush();
                count = writer.pending;
                if (writer.count != 0) {
                    wire[count] = @truncate(writer.bits);
                    count += 1;
                }
            }
        }
        if (fallback) {
            wire[0] = 1;
            writeStoredBody(source, wire[1..][0 .. source.len + 4]);
            count = source.len + 5;
        }
        return wire[0..count];
    }

    test "short run oversized input leaves source and padded output unchanged" {
        var source: [max_input_bytes + 1]u8 = undefined;
        for (&source, 0..) |*byte, i| byte.* = @truncate(i *% 73 +% i / 5);
        const before = source;
        var destination: [output_capacity]u8 = @splat(0xa5);
        try std.testing.expectError(error.LimitExceeded, into(&source, &destination));
        try std.testing.expectEqual(before, source);
        try std.testing.expect(std.mem.allEqual(u8, &destination, 0xa5));
    }

    test "short run output stays inside padded caller storage" {
        const allocator = std.testing.allocator;
        const workspace = try EncoderWorkspace.create(allocator);
        defer workspace.destroy(allocator);
        var source: [max_input_bytes]u8 = undefined;
        for (0..3) |pattern| {
            for (&source, 0..) |*byte, i| byte.* = switch (pattern) {
                0 => 0,
                1 => @truncate(i *% 73 +% i / 11),
                else => @truncate(if (i % 43 < 36) i % 4 else i *% 53),
            };
            for (
                [_]usize{
                    0, 1, 35, 36, 75, 76, 127, 128, 257, 264, 511, 1023, 1024, 1025, 2047, 2048,
                },
            ) |length| {
                var expected_bytes: [max_input_bytes + 5]u8 = undefined;
                const expected = try encode(
                    source[0..length],
                    &expected_bytes,
                    workspace,
                    .{ .compression = .{ .strategy = .four_byte_runs } },
                );
                var guarded: [output_capacity + 2]u8 = @splat(0xa5);
                const before = source;
                const actual = try into(source[0..length], guarded[1..][0..output_capacity]);
                try std.testing.expectEqualSlices(u8, expected, actual);
                try std.testing.expectEqual(before, source);
                try std.testing.expectEqual(@as(u8, 0xa5), guarded[0]);
                try std.testing.expectEqual(@as(u8, 0xa5), guarded[guarded.len - 1]);
            }
        }
    }

    test "public short stream buffer refusals preserve destination" {
        var source: [max_input_bytes + 1]u8 = @splat(42);
        var output: [output_capacity]u8 = @splat(0xa5);
        try std.testing.expectError(error.LimitExceeded, into(&source, &output));
        try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
        try std.testing.expectError(
            error.OutputTooSmall,
            into(source[0..16], output[0 .. output.len - 1]),
        );
        try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
        const before = output;
        try std.testing.expectError(error.StorageOverlap, into(output[0..16], &output));
        try std.testing.expectEqualSlices(u8, &before, &output);
    }
};

test {
    _ = short;
}

fn disjoint(a: []const u8, b: []const u8) error{StorageOverlap}!void {
    if (a.len == 0 or b.len == 0) return;
    const x = @intFromPtr(a.ptr);
    const y = @intFromPtr(b.ptr);
    const overlap = if (x <= y) y - x < a.len else x - y < b.len;
    if (overlap) return error.StorageOverlap;
}

const window_bytes = 32768;

test "four-byte run strategy produces a readable stream" {
    const allocator = std.testing.allocator;
    const encoder = try EncoderWorkspace.create(allocator);
    defer encoder.destroy(allocator);
    const decoder = try test_decoding.decode.Workspace.create(allocator);
    defer decoder.destroy(allocator);
    const input = "aabb aabb aabb aabb !@#$ !@#$ !@#$ !@#$";
    var output: [256]u8 = undefined;
    var restored: [input.len]u8 = undefined;
    const wire = try encode(
        input,
        &output,
        encoder,
        .{ .compression = .{ .level = 6, .strategy = .four_byte_runs } },
    );
    const result = try test_decoding.decode.into(
        wire,
        &restored,
        .{ .workspace = decoder },
        .{ .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(input.len, result.produced);
    try std.testing.expectEqualSlices(u8, input, &restored);
}

test "four-byte run probe overflow preserves admitted work" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    var input: [8192]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = @intCast((i * 7 + i / 7) % 16);
    try encoder.reset(workspace, .{ .compression = .{ .level = 6, .strategy = .four_byte_runs } });
    @memcpy(workspace.data[0..input.len], &input);
    encoder.buffered = input.len;
    var book_work: u64 = 0;
    var book_probes: u64 = 0;
    _ = try borrows.fourByteRuns(&encoder).sampleRunBook(false, &book_work, &book_probes);
    const sample_work = 256 + book_work;
    const sample_probes = 255 + book_probes;
    try encoder.reset(workspace, .{ .compression = .{ .level = 6, .strategy = .four_byte_runs } });
    encoder.stats.match_probes = std.math.maxInt(u64) - sample_probes;
    var output: [16384]u8 = @splat(0xa5);
    try std.testing.expectError(error.CounterOverflow, encoder.step(&input, &output, .finish));
    try std.testing.expectEqual(std.math.maxInt(u64), encoder.stats.match_probes);
    try std.testing.expectEqual(sample_work + 32, encoder.stats.work_units);
    try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
    try encoder.reset(workspace, .{ .compression = .{ .level = 6, .strategy = .four_byte_runs } });
    encoder.stats.work_units = std.math.maxInt(u64) - (sample_work + 31);
    try std.testing.expectError(error.LimitExceeded, encoder.step(&input, &output, .finish));
    try std.testing.expectEqual(std.math.maxInt(u64) - 31, encoder.stats.work_units);
    try std.testing.expectEqual(sample_probes, encoder.stats.match_probes);
    try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
}

test "four-byte run preflight overflow preserves admitted work" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    var input: [8192]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = @intCast(100 + (i * 37 + i / 13) % 100);
    try encoder.reset(workspace, .{ .compression = .{ .level = 6, .strategy = .four_byte_runs } });
    @memcpy(workspace.data[0..input.len], &input);
    encoder.buffered = input.len;
    var book_work: u64 = 0;
    var book_probes: u64 = 0;
    _ = try borrows.fourByteRuns(&encoder).sampleRunBook(false, &book_work, &book_probes);
    const sample_work = 256 + book_work;
    const sample_probes = 255 + book_probes;
    try encoder.reset(workspace, .{ .compression = .{ .level = 6, .strategy = .four_byte_runs } });
    encoder.stats.match_probes = std.math.maxInt(u64) - sample_probes;
    var output: [16384]u8 = @splat(0xa5);
    try std.testing.expectError(error.CounterOverflow, encoder.step(&input, &output, .finish));
    try std.testing.expectEqual(std.math.maxInt(u64), encoder.stats.match_probes);
    try std.testing.expectEqual(sample_work + 32, encoder.stats.work_units);
    try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
    try encoder.reset(workspace, .{ .compression = .{ .level = 6, .strategy = .four_byte_runs } });
    encoder.stats.work_units = std.math.maxInt(u64) - (sample_work + 31);
    try std.testing.expectError(error.LimitExceeded, encoder.step(&input, &output, .finish));
    try std.testing.expectEqual(std.math.maxInt(u64) - 31, encoder.stats.work_units);
    try std.testing.expectEqual(sample_probes, encoder.stats.match_probes);
    try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
}

test "four-byte run stream round trips on target" {
    const allocator = std.testing.allocator;
    const encoder = try EncoderWorkspace.create(allocator);
    defer encoder.destroy(allocator);
    const decoder = try test_decoding.decode.Workspace.create(allocator);
    defer decoder.destroy(allocator);
    const input = try allocator.alloc(u8, 16384);
    defer allocator.free(input);
    const output = try allocator.alloc(u8, 32768);
    defer allocator.free(output);
    const restored = try allocator.alloc(u8, input.len);
    defer allocator.free(restored);
    for (input, 0..) |*byte, i| {
        byte.* = if (i % 67 < 20) 0 else @intCast(100 + (i * 37 + i / 13) % 100);
    }
    const wire = try encode(
        input,
        output,
        encoder,
        .{ .compression = .{ .level = 6, .strategy = .four_byte_runs } },
    );
    const result = try test_decoding.decode.into(
        wire,
        restored,
        .{ .workspace = decoder },
        .{ .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(input.len, result.produced);
    try std.testing.expectEqualSlices(u8, input, restored);
}

test "four-byte run short blocks preserve every starting bit offset" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    for (0..36) |length| {
        for (0..8) |offset| {
            for ([_]bool{ false, true }) |final| {
                try encoder.reset(
                    workspace,
                    .{ .compression = .{ .level = 6, .strategy = .four_byte_runs } },
                );
                for (workspace.data[0..length], 0..) |*byte, i| byte.* = @truncate(i * 73 + 19);
                encoder.buffered = length;
                encoder.bit_count = @intCast(offset);
                encoder.bits = (@as(u64, 1) << @intCast(offset)) - 1;
                try borrows.fourByteRuns(&encoder).encode(final);
                const prefix_len = (offset + 3 + 7) / 8;
                const prefix = ((@as(
                    u64,
                    1,
                ) << @intCast(offset)) - 1) | (@as(u64, @intFromBool(final)) << @intCast(offset));
                for (0..prefix_len) |i| {
                    try std.testing.expectEqual(
                        @as(u8, @truncate(prefix >> @intCast(8 * i))),
                        workspace.wire[i],
                    );
                }
                const body = workspace.wire[prefix_len..encoder.pending];
                try std.testing.expectEqual(length + 4, body.len);
                try std.testing.expectEqual(
                    @as(u16, @intCast(length)),
                    std.mem.readInt(u16, body[0..2], .little),
                );
                try std.testing.expectEqual(
                    ~@as(u16, @intCast(length)),
                    std.mem.readInt(u16, body[2..4], .little),
                );
                try std.testing.expectEqualSlices(u8, workspace.data[0..length], body[4..]);
                try std.testing.expectEqual(@as(u64, 0), encoder.stats.work_units);
                try std.testing.expectEqual(@as(u64, 0), encoder.stats.match_probes);
            }
        }
    }
}

test "copied run header matches independent bit serialization" {
    const Reference = struct {
        bytes: [128]u8 = @splat(0),
        count: usize = 0,
        fn append(self: *@This(), value: usize, width: usize) void {
            for (0..width) |i| {
                const bit: u8 = @intCast((value >> @as(std.math.Log2Int(usize), @intCast(i))) & 1);
                self.bytes[self.count / 8] |= bit << @as(u3, @intCast(self.count % 8));
                self.count += 1;
            }
        }
    };
    for (run_books) |book| {
        for ([_]bool{ false, true }) |final| {
            var expected: Reference = .{};
            expected.append(@intFromBool(final), 1);
            expected.append(2, 2);
            expected.append(book.header.literal_count - 257, 5);
            expected.append(book.header.distance_count - 1, 5);
            expected.append(book.header.precode_count - 4, 4);
            for (precode_order[0..book.header.precode_count]) |symbol| {
                expected.append(book.header.precode.widths[symbol], 3);
            }
            for (book.header.runs[0..book.header.run_count]) |run| {
                expected.append(
                    book.header.precode.codes[run.symbol],
                    book.header.precode.widths[run.symbol],
                );
                expected.append(run.extra, runExtra(run.symbol));
            }
            try std.testing.expectEqual(@as(usize, (3 + book.header.bits)), expected.count);
            var actual = book.header_wire;
            actual[0] |= @intFromBool(final);
            try std.testing.expectEqual(expected.count % 8, book.header_count);
            try std.testing.expectEqualSlices(
                u8,
                expected.bytes[0..book.header_bytes],
                actual[0..book.header_bytes],
            );
            try std.testing.expectEqual(
                @as(u64, expected.bytes[book.header_bytes]),
                book.header_tail,
            );
        }
    }
}

test "run header widths and accounting agree" {
    for (run_books) |book| {
        var expanded: [290]u8 = undefined;
        var position: usize = 0;
        var bits: u32 = 14 + @as(u32, @intCast(book.header.precode_count)) * 3;
        for (book.header.runs[0..book.header.run_count]) |run| {
            bits += @as(u32, book.header.precode.widths[run.symbol]) + runExtra(run.symbol);
            if (run.symbol <= 15) {
                expanded[position] = run.symbol;
                position += 1;
            } else {
                try std.testing.expectEqual(@as(u8, 16), run.symbol);
                try std.testing.expect(position > 0);
                const repeat = @as(usize, run.extra) + 3;
                @memset(expanded[position..][0..repeat], expanded[position - 1]);
                position += repeat;
            }
        }
        try std.testing.expectEqual(expanded.len, position);
        try std.testing.expectEqualSlices(u8, &book.header.literal.widths, expanded[0..286]);
        try std.testing.expectEqualSlices(
            u8,
            book.header.distance.widths[0..4],
            expanded[286..290],
        );
        try std.testing.expectEqual(book.header.bits, bits);
        var literal_kraft: u32 = 0;
        for (book.header.literal.widths) |width| {
            try std.testing.expect(width > 0 and width <= 14);
            literal_kraft += @as(u32, 1) << @as(u5, @intCast(14 - width));
        }
        try std.testing.expectEqual(@as(u32, 1 << 14), literal_kraft);
        var precode_kraft: u32 = 0;
        for (book.header.precode.widths[0..19]) |width| if (width != 0) {
            try std.testing.expect(width <= 7);
            precode_kraft += @as(u32, 1) << @as(u5, @intCast(7 - width));
        };
        try std.testing.expectEqual(@as(u32, 1 << 7), precode_kraft);
    }
}

test "prepacked run matches preserve every length and bit offset" {
    for (3..259) |length| {
        for (0..32) |initial_count| {
            var expected_wire: [16]u8 = @splat(0xa5);
            var actual_wire = expected_wire;
            const initial_bits = (@as(u64, 1) << @intCast(initial_count)) - 1;
            var expected: PackedWriter = .{
                .book = &zero_dominant_book,
                .wire = &expected_wire,
                .bits = initial_bits,
                .count = @intCast(initial_count),
                .pending = 0,
            };
            var actual: PackedWriter = .{
                .book = &zero_dominant_book,
                .wire = &actual_wire,
                .bits = initial_bits,
                .count = @intCast(initial_count),
                .pending = 0,
            };
            const slot = lengthSlot(length);
            expected.symbol(&zero_dominant_book.header.literal, 257 + @as(usize, slot));
            expected.put(length - length_base[slot], @intCast(length_extra[slot]));
            expected.symbol(&zero_dominant_book.header.distance, 3);
            const token = zero_dominant_book.match_tokens[length];
            actual.put(token & 0x00ffffff, @intCast(token >> 24));
            try std.testing.expectEqual(expected.pending, actual.pending);
            try std.testing.expectEqual(expected.bits, actual.bits);
            try std.testing.expectEqual(expected.count, actual.count);
            try std.testing.expectEqualSlices(u8, &expected_wire, &actual_wire);
        }
    }
}

test "four run literals preserve bits and staging guards" {
    const book = &zero_dominant_book.header.literal;
    // Every distinct literal width, including the shortest and longest codes.
    const representatives = [_]u8{ 0, 1, 2, 253, 3, 4, 6, 8, 11, 16, 24, 32, 43 };
    for (0..8) |count| {
        const initial = (@as(u64, 1) << @intCast(count)) - 1;
        for (0..8) |alignment| {
            for (
                representatives,
            ) |a| for (representatives) |b| for (representatives) |c| for (representatives) |d| {
                const values = [4]u8{ a, b, c, d };
                var expected_bytes: [24]u8 = @splat(0xa5);
                var actual_bytes: [24]u8 = @splat(0xa5);
                var expected: PackedWriter = .{
                    .book = &zero_dominant_book,
                    .wire = expected_bytes[alignment..],
                    .bits = initial,
                    .count = @intCast(count),
                    .pending = 0,
                };
                var actual: PackedWriter = .{
                    .book = &zero_dominant_book,
                    .wire = actual_bytes[alignment..],
                    .bits = initial,
                    .count = @intCast(count),
                    .pending = 0,
                };
                for (values) |value| expected.symbol(book, value);
                expected.flush();
                actual.symbolQuad(&values);
                try std.testing.expectEqual(expected.bits, actual.bits);
                try std.testing.expectEqual(expected.count, actual.count);
                try std.testing.expectEqual(expected.pending, actual.pending);
                try std.testing.expectEqualSlices(
                    u8,
                    expected.wire[0..expected.pending],
                    actual.wire[0..actual.pending],
                );
                for (
                    actual_bytes[0..alignment],
                ) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
                for (
                    actual_bytes[alignment + 8 ..],
                ) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
            };
        }
    }
}

test "four run literals satisfy the stored bound for every code width" {
    const book = &zero_dominant_book.header.literal;
    for (book.widths[0..256]) |width| try std.testing.expect(width <= 14);
    const representatives = [_]u8{ 0, 1, 2, 253, 3, 4, 6, 8, 11, 16, 24, 32, 43 };
    for (
        representatives,
    ) |a| for (representatives) |b| for (representatives) |c| for (representatives) |d| {
        const exact = @as(usize, book.widths[a]) + book.widths[b] + book.widths[c] + book.widths[d];
        for (0..59) |slack| {
            const shortcut = slack > 4 * 14 or exact < slack;
            try std.testing.expectEqual(exact < slack, shortcut);
        }
    };
}

test "decisive sample retains bounded decisions and logical accounting" {
    const allocator = std.testing.allocator;
    const fast_workspace = try EncoderWorkspace.create(allocator);
    defer fast_workspace.destroy(allocator);
    const checked_workspace = try EncoderWorkspace.create(allocator);
    defer checked_workspace.destroy(allocator);
    var fast: Encoder = undefined;
    var checked: Encoder = undefined;
    const targets = [_]usize{
        0, 7, 8, 31, 32, 95, 96, 111, 112, 127, 128, 159, 160, 191, 192, 223, 224, 225, 255, 256,
    };
    for ([_]usize{ 0, 1, 3, 4, 8 }) |history| for (targets) |target| for (0..3) |distribution| {
        try fast.reset(fast_workspace, .{ .compression = .{ .strategy = .four_byte_runs } });
        try checked.reset(checked_workspace, .{ .compression = .{ .strategy = .four_byte_runs } });
        fast.history = history;
        checked.history = history;
        fast.buffered = 4096;
        checked.buffered = 4096;
        for (
            fast_workspace.data[0 .. history + 4096],
            0..,
        ) |*byte, i| byte.* = @truncate(i *% 37 +% i / 13);
        const eligible = 256 - @as(usize, @intFromBool(history < 4));
        const selected = @min(target, eligible);
        var rank: usize = 0;
        for (0..256) |i| {
            const position = history + i * 4095 / 255;
            if (position < 4) continue;
            const is_match = switch (distribution) {
                0 => rank < selected,
                1 => rank >= eligible - selected,
                else => (rank * 73) % eligible < selected,
            };
            const prior = fast_workspace.data[position - 4];
            fast_workspace.data[position] = if (is_match) prior else prior +% 1;
            rank += 1;
        }
        @memcpy(
            checked_workspace.data[0 .. history + 4096],
            fast_workspace.data[0 .. history + 4096],
        );
        var fast_units: u64 = 0;
        var fast_probes: u64 = 0;
        var checked_units: u64 = 0;
        var checked_probes: u64 = 0;
        var fast_group = false;
        var fast_choice: CodebookChoice = .zero_dominant;
        var checked_group = false;
        var checked_choice: CodebookChoice = .zero_dominant;
        const fast_stored = try borrows.fourByteRuns(
            &fast,
        ).preferStoredRuns(false, &fast_units, &fast_probes, &fast_group, &fast_choice);
        const checked_stored = try borrows.fourByteRuns(
            &checked,
        ).preferStoredRuns(true, &checked_units, &checked_probes, &checked_group, &checked_choice);
        try std.testing.expectEqual(checked_stored, fast_stored);
        try std.testing.expectEqual(checked_group, fast_group);
        try std.testing.expectEqual(checked_choice, fast_choice);
        try std.testing.expectEqual(checked.stats.work_units, fast_units);
        try std.testing.expectEqual(checked.stats.match_probes, fast_probes);
    };
}

test "batched run groups match bounded parsing at offsets and boundaries" {
    const allocator = std.testing.allocator;
    const fast_workspace = try EncoderWorkspace.create(allocator);
    defer fast_workspace.destroy(allocator);
    const checked_workspace = try EncoderWorkspace.create(allocator);
    defer checked_workspace.destroy(allocator);
    var fast: Encoder = undefined;
    var checked: Encoder = undefined;
    const lengths = [_]usize{ 36, 37, 79, 80, 81, 112, 113, 114, 4095, 4096, 65535 };
    for (lengths) |length| for ([_]usize{ 0, 8 }) |history| for (0..8) |offset| {
        for (0..5) |pattern| {
            try fast.reset(fast_workspace, .{ .compression = .{ .strategy = .four_byte_runs } });
            try checked.reset(
                checked_workspace,
                .{ .compression = .{ .strategy = .four_byte_runs } },
            );
            for (fast_workspace.data[0 .. history + length], 0..) |*byte, i| {
                byte.* = switch (pattern) {
                    0 => 0,
                    1 => @intCast(i % 4),
                    2 => @truncate(i *% 73 +% i / 11),
                    3 => @intCast((i / 4 + i / 23) % 8),
                    else => @intCast(if ((i / 4) % 5 == 0) i % 4 else (i / 4) % 11),
                };
            }
            @memcpy(
                checked_workspace.data[0 .. history + length],
                fast_workspace.data[0 .. history + length],
            );
            @memset(std.mem.asBytes(&fast_workspace.huffman), 0xa5);
            @memset(std.mem.asBytes(&checked_workspace.huffman), 0xa5);
            fast.history = history;
            checked.history = history;
            fast.buffered = length;
            checked.buffered = length;
            fast.bit_count = @intCast(offset);
            checked.bit_count = @intCast(offset);
            fast.bits = (@as(u64, 1) << @intCast(offset)) - 1;
            checked.bits = fast.bits;
            var fast_units: u64 = 0;
            var fast_probes: u64 = 0;
            var checked_units: u64 = 0;
            var checked_probes: u64 = 0;
            try borrows.fourByteRuns(
                &fast,
            ).emitRuns(&zero_dominant_book, true, false, true, &fast_units, &fast_probes);
            try borrows.fourByteRuns(
                &checked,
            ).emitRuns(&zero_dominant_book, true, true, true, &checked_units, &checked_probes);
            try std.testing.expectEqual(checked.stats.work_units, fast_units);
            try std.testing.expectEqual(checked.stats.match_probes, fast_probes);
            try std.testing.expectEqual(checked.pending, fast.pending);
            try std.testing.expectEqual(checked.bits, fast.bits);
            try std.testing.expectEqual(checked.bit_count, fast.bit_count);
            try std.testing.expectEqualSlices(
                u8,
                checked_workspace.wire[0..checked.pending],
                fast_workspace.wire[0..fast.pending],
            );
            for (
                std.mem.asBytes(&fast_workspace.huffman),
            ) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        }
    };
}

test "four-byte run staging stays inside its workspace at block boundaries" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    const lengths = [_]usize{ 35, 36, 37, 8191, 8192, slab_bytes - 1, slab_bytes };
    for (lengths) |length| {
        for (0..8) |offset| {
            for (0..4) |pattern| {
                try encoder.reset(workspace, .{ .compression = .{ .strategy = .four_byte_runs } });
                for (workspace.data[0..length], 0..) |*byte, i| {
                    byte.* = switch (pattern) {
                        0 => 0,
                        1 => @intCast(i % 4),
                        2 => @truncate(i * 73 + i / 11),
                        else => @intCast(100 + (i * 37 + i / 13) % 100),
                    };
                }
                @memset(std.mem.asBytes(&workspace.huffman), 0xa5);
                encoder.buffered = length;
                encoder.bit_count = @intCast(offset);
                encoder.bits = (@as(u64, 1) << @intCast(offset)) - 1;
                try borrows.fourByteRuns(&encoder).encode(true);
                try std.testing.expect(encoder.pending <= length + 16);
                try std.testing.expectEqual(@as(u64, 1), encoder.stats.blocks);
                for (std.mem.asBytes(&workspace.huffman)) |byte| {
                    try std.testing.expectEqual(@as(u8, 0xa5), byte);
                }
            }
        }
    }
}

test "compact run workspace matches full streaming encoder" {
    const Helper = struct {
        fn run(encoder: anytype, input: []const u8, output: []u8) !usize {
            var consumed: usize = 0;
            var written: usize = 0;
            while (true) {
                const end = @min(input.len, consumed + 131);
                const action: EncodeAction = if (end == input.len) .finish else .process;
                const progress = try encoder.step(
                    input[consumed..end],
                    output[written..][0..@min(79, output.len - written)],
                    action,
                );
                consumed += progress.consumed;
                written += progress.produced;
                if (progress.status == .complete) return written;
            }
        }
    };
    const allocator = std.testing.allocator;
    const full_workspace = try allocator.create(EncoderWorkspace);
    defer allocator.destroy(full_workspace);
    const compact_workspace = try allocator.create(FourByteRunEncoderWorkspace);
    defer allocator.destroy(compact_workspace);
    const data = try allocator.alloc(u8, 65536);
    defer allocator.free(data);
    var random: std.Random.DefaultPrng = .init(0x9f77);
    random.random().bytes(data);
    const a = try allocator.alloc(u8, 140000);
    defer allocator.free(a);
    const b = try allocator.alloc(u8, 140000);
    defer allocator.free(b);
    for ([_]usize{ 0, 35, 76, 4096, 65535, 65536 }) |length| {
        for ([_]u4{ 0, 6 }) |level| {
            for ([_]bool{ false, true }) |dictionary| {
                const options: EncodeOptions = .{
                    .compression = .{ .level = level, .strategy = .four_byte_runs },
                    .dictionary = if (dictionary) "prior data history" else null,
                };
                var full: Encoder = undefined;
                var compact: FourByteRunEncoder = undefined;
                try full.reset(full_workspace, options);
                try compact.reset(
                    compact_workspace,
                    .{
                        .mode = if (level == 0) .stored else .runs,
                        .dictionary = options.dictionary,
                    },
                );
                const n = try Helper.run(&full, data[0..length], a);
                const m = try Helper.run(&compact, data[0..length], b);
                try std.testing.expectEqualSlices(u8, a[0..n], b[0..m]);
                try std.testing.expectEqualDeep(full.counts(), compact.counts());
            }
        }
    }
    var defaulted: FourByteRunEncoder = undefined;
    var full: Encoder = undefined;
    try defaulted.reset(compact_workspace, .{});
    try full.reset(full_workspace, .{ .compression = .{ .strategy = .four_byte_runs } });
    const n = try Helper.run(&full, data[0..76], a);
    const m = try Helper.run(&defaulted, data[0..76], b);
    try std.testing.expectEqualSlices(u8, a[0..n], b[0..m]);
    try std.testing.expectEqualDeep(full.counts(), defaulted.counts());
}

test "long run scan matches bounded comparison at every mismatch" {
    const allocator = std.testing.allocator;
    const fast_workspace = try allocator.create(FourByteRunEncoderWorkspace);
    defer allocator.destroy(fast_workspace);
    const checked_workspace = try allocator.create(FourByteRunEncoderWorkspace);
    defer allocator.destroy(checked_workspace);
    for (4..12) |position| for (1..259) |length| {
        for (0..length + 1) |mismatch| inline for (.{ false, true }) |long_runs| {
            for (fast_workspace.data[0 .. position + length], 0..) |*byte, index| {
                byte.* = @intCast((index % 4) * 53 + 11);
            }
            if (mismatch < length) fast_workspace.data[position + mismatch] ^= 0x80;
            @memcpy(
                checked_workspace.data[0 .. position + length],
                fast_workspace.data[0 .. position + length],
            );
            var fast: FourByteRunEncoder = undefined;
            var checked: FourByteRunEncoder = undefined;
            const options: CompactOptions = .{};
            try fast.reset(fast_workspace, options);
            try checked.reset(checked_workspace, options);
            var units: u64 = 0;
            var probes: u64 = 0;
            const actual = try borrows.fourByteRuns(
                &fast,
            ).runLength(position, position + length, false, long_runs, &units, &probes);
            var checked_units: u64 = 0;
            var checked_probes: u64 = 0;
            const expected = try borrows.fourByteRuns(
                &checked,
            ).runLength(position, position + length, true, false, &checked_units, &checked_probes);
            try std.testing.expectEqual(expected, actual);
            try std.testing.expectEqual(checked.counts().work_units, units);
            try std.testing.expectEqual(checked.counts().match_probes, probes);
        };
    };
}

test "batched decisive sampling matches bounded decisions across histories" {
    const allocator = std.testing.allocator;
    const fast_workspace = try allocator.create(FourByteRunEncoderWorkspace);
    defer allocator.destroy(fast_workspace);
    const checked_workspace = try allocator.create(FourByteRunEncoderWorkspace);
    defer allocator.destroy(checked_workspace);
    const targets = [_]usize{
        0, 7, 8, 31, 32, 63, 64, 95, 96, 127, 128, 159, 160, 191, 192, 223, 224, 225, 255, 256,
    };
    for ([_]usize{ 4096, 4097, 4128, 8192, 65535 }) |length| {
        for ([_]usize{ 0, 1, 3, 4, 8, 32768 }) |history| {
            const eligible = 256 - @as(usize, @intFromBool(history < 4));
            for (targets) |target| for (0..3) |distribution| {
                var fast: FourByteRunEncoder = undefined;
                var checked: FourByteRunEncoder = undefined;
                const options: CompactOptions = .{};
                try fast.reset(fast_workspace, options);
                try checked.reset(checked_workspace, options);
                fast.history = history;
                checked.history = history;
                fast.buffered = length;
                checked.buffered = length;
                @memset(fast_workspace.data[0 .. history + length], 0);
                const selected = @min(target, eligible);
                var rank: usize = 0;
                for (0..256) |i| {
                    const position = history + i * (length - 1) / 255;
                    if (position < 4) continue;
                    const matches = switch (distribution) {
                        0 => rank < selected,
                        1 => rank >= eligible - selected,
                        else => (rank * 73) % eligible < selected,
                    };
                    fast_workspace.data[position] = if (matches) 0 else 0x80;
                    rank += 1;
                }
                @memcpy(
                    checked_workspace.data[0 .. history + length],
                    fast_workspace.data[0 .. history + length],
                );
                var fast_units: u64 = 0;
                var fast_probes: u64 = 0;
                var checked_units: u64 = 0;
                var checked_probes: u64 = 0;
                var fast_group = false;
                var fast_choice: CodebookChoice = .zero_dominant;
                var checked_group = false;
                var checked_choice: CodebookChoice = .zero_dominant;
                const fast_stored = try borrows.fourByteRuns(
                    &fast,
                ).preferStoredRuns(false, &fast_units, &fast_probes, &fast_group, &fast_choice);
                const checked_stored = try borrows.fourByteRuns(
                    &checked,
                ).preferStoredRuns(
                    true,
                    &checked_units,
                    &checked_probes,
                    &checked_group,
                    &checked_choice,
                );
                try std.testing.expectEqual(checked_stored, fast_stored);
                try std.testing.expectEqual(checked_group, fast_group);
                try std.testing.expectEqual(checked_choice, fast_choice);
                try std.testing.expectEqual(checked.counts().work_units, fast_units);
                try std.testing.expectEqual(checked.counts().match_probes, fast_probes);
            };
        }
    }
}

test "four run literals retain every byte code and pending bit offset" {
    for (0..256) |value| {
        const values = [4]u8{
            @truncate(value),
            @truncate(value + 1),
            @truncate(value + 71),
            @truncate(value + 193),
        };
        for (0..8) |offset| {
            const initial = (@as(u64, 1) << @intCast(offset)) - 1;
            var expected_bytes: [24]u8 = @splat(0xa5);
            var actual_bytes: [24]u8 = @splat(0xa5);
            var expected: PackedWriter = .{
                .book = &zero_dominant_book,
                .wire = expected_bytes[3..],
                .bits = initial,
                .count = @intCast(offset),
                .pending = 0,
            };
            var actual: PackedWriter = .{
                .book = &zero_dominant_book,
                .wire = actual_bytes[3..],
                .bits = initial,
                .count = @intCast(offset),
                .pending = 0,
            };
            for (values) |literal| expected.symbol(&zero_dominant_book.header.literal, literal);
            expected.flush();
            actual.symbolQuad(&values);
            try std.testing.expectEqual(expected.bits, actual.bits);
            try std.testing.expectEqual(expected.count, actual.count);
            try std.testing.expectEqual(expected.pending, actual.pending);
            try std.testing.expectEqualSlices(
                u8,
                expected.wire[0..expected.pending],
                actual.wire[0..actual.pending],
            );
            for (actual_bytes[0..3]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
            for (actual_bytes[11..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        }
    }
}

test "four byte run dictionary suffix survives block and flush boundaries" {
    const allocator = std.testing.allocator;
    const full = try EncoderWorkspace.create(allocator);
    defer full.destroy(allocator);
    const compact = try allocator.create(FourByteRunEncoderWorkspace);
    defer allocator.destroy(compact);
    const source = try allocator.alloc(u8, 2 * slab_bytes + 37);
    defer allocator.free(source);
    for (
        source,
        0..,
    ) |*byte, i| byte.* = if (i % 1024 < 992) "ABCD"[i % 4] else @truncate(i *% 73 +% i / 11);
    const dictionary = try allocator.alloc(u8, 65539);
    defer allocator.free(dictionary);
    for (dictionary, 0..) |*byte, i| byte.* = @truncate(i *% 53 +% i / 7);
    @memcpy(dictionary[dictionary.len - 4 ..], "ABCD");
    const suffix = dictionary[dictionary.len - 4 ..];
    const capacity = try encodeBound(source.len) + 20;
    const expected = try allocator.alloc(u8, capacity);
    defer allocator.free(expected);
    const actual = try allocator.alloc(u8, capacity);
    defer allocator.free(actual);
    const restored = try allocator.alloc(u8, source.len);
    defer allocator.free(restored);
    const decoder = try test_decoding.decode.Workspace.create(allocator);
    defer decoder.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const Helper = struct {
        fn run(encoder: anytype, input: []const u8, output: []u8) !usize {
            const ends = [_]usize{ slab_bytes + 1, slab_bytes + 5, input.len };
            const actions = [_]EncodeAction{ .flush, .full_flush, .finish };
            var read: usize = 0;
            var written: usize = 0;
            for (ends, actions) |segment_end, boundary| while (true) {
                const end = @min(segment_end, read + 4093);
                const out_end = @min(output.len, written + 13);
                const progress = try encoder.step(
                    input[read..end],
                    output[written..out_end],
                    if (end == segment_end) boundary else .process,
                );
                read += progress.consumed;
                written += progress.produced;
                if (progress.status == .flushed or progress.status == .complete) break;
                try std.testing.expect(progress.consumed != 0 or progress.produced != 0);
            };
            try std.testing.expectEqual(input.len, read);
            return written;
        }
    };
    inline for (.{ full, compact }) |workspace| {
        for ([_]usize{ 256, 32768 }) |window| {
            var encoder: (if (@TypeOf(
                workspace.*,
            ) == FourByteRunEncoderWorkspace) FourByteRunEncoder else Encoder) = undefined;
            const compact_storage = @TypeOf(workspace.*) == FourByteRunEncoderWorkspace;
            var options: (if (compact_storage) CompactOptions else EncodeOptions) =
                if (compact_storage) .{
                    .dictionary = suffix,
                    .window_bytes = window,
                } else .{
                    .dictionary = suffix,
                    .window_bytes = window,
                    .compression = .{ .strategy = .four_byte_runs },
                };
            try encoder.reset(workspace, options);
            const n = try Helper.run(&encoder, source, expected);
            const counts = encoder.counts();
            options.dictionary = dictionary;
            try encoder.reset(workspace, options);
            const m = try Helper.run(&encoder, source, actual);
            try std.testing.expectEqualSlices(u8, expected[0..n], actual[0..m]);
            try std.testing.expectEqualDeep(counts, encoder.counts());
            const result = try test_decoding.decode.into(
                actual[0..m],
                restored,
                .{ .workspace = decoder, .history = history },
                .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
            );
            try std.testing.expectEqual(source.len, result.produced);
            try std.testing.expectEqualSlices(u8, source, restored);
        }
    }
}

test "run match byte flushing preserves pending prefixes and staging guards" {
    for (run_books) |book| {
        for (3..259) |length| for (0..32) |count| for (0..8) |alignment| {
            for ([_]usize{ 0, 3 }) |pending| {
                const initial = (@as(u64, 1) << @intCast(count)) - 1;
                var expected_bytes: [40]u8 = @splat(0xa5);
                var actual_bytes: [40]u8 = @splat(0xa5);
                var expected: PackedWriter = .{
                    .book = book,
                    .wire = expected_bytes[alignment..],
                    .bits = initial,
                    .count = @intCast(count),
                    .pending = pending,
                };
                var actual: PackedWriter = .{
                    .book = book,
                    .wire = actual_bytes[alignment..],
                    .bits = initial,
                    .count = @intCast(count),
                    .pending = pending,
                };
                const token = book.match_tokens[length];
                expected.put(token & 0x00ffffff, @intCast(token >> 24));
                expected.flush();
                actual.runMatch(length);
                try std.testing.expectEqual(expected.bits, actual.bits);
                try std.testing.expectEqual(expected.count, actual.count);
                try std.testing.expectEqual(expected.pending, actual.pending);
                try std.testing.expectEqualSlices(
                    u8,
                    expected.wire[0..expected.pending],
                    actual.wire[0..actual.pending],
                );
                try std.testing.expect(
                    std.mem.allEqual(u8, actual_bytes[0 .. alignment + pending], 0xa5),
                );
                try std.testing.expect(
                    std.mem.allEqual(u8, actual_bytes[alignment + pending + 8 ..], 0xa5),
                );
            }
        };
    }
}

test "whole-span literal packing matches scalar codes and padded guards" {
    var state: u64 = 0x2173a8f0;
    for (0..512) |pattern| {
        var values: [32]u8 = undefined;
        for (&values, 0..) |*value, i| {
            state = state *% 6364136223846793005 +% 1;
            value.* = switch (pattern % 5) {
                0 => @intCast(((i + pattern) % 14 + 250) % 256),
                1 => @intCast(((state >> 32) % 14 + 250) % 256),
                2 => @truncate(state >> 32),
                3 => 7,
                else => if (i == pattern % 32) 249 else 0,
            };
        }
        for (0..8) |count| for (0..8) |alignment| {
            var expected_bytes: [144]u8 = @splat(0xa5);
            var actual_bytes: [144]u8 = @splat(0xa5);
            var expected: PackedWriter = .{
                .book = &zero_dominant_book,
                .wire = expected_bytes[alignment..][0..128],
                .bits = (@as(u64, 1) << @intCast(count)) - 1,
                .count = @intCast(count),
                .pending = 3,
            };
            var actual = expected;
            actual.wire = actual_bytes[alignment..][0..128];
            for (values) |value| expected.symbol(&zero_dominant_book.header.literal, value);
            expected.flush();
            actual.symbolSpan32(&values, LiteralLookup.init(actual.book));
            try std.testing.expectEqual(expected.pending, actual.pending);
            try std.testing.expectEqual(expected.bits, actual.bits);
            try std.testing.expectEqual(expected.count, actual.count);
            try std.testing.expectEqualSlices(
                u8,
                expected.wire[0..expected.pending],
                actual.wire[0..actual.pending],
            );
            for (
                actual_bytes[0..alignment],
            ) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
            for (
                actual_bytes[alignment + actual.pending + 8 ..],
            ) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        };
    }
}

test "span preflight agrees with emission across cutoff and tail boundaries" {
    for (run_books) |book| {
        const allocator = std.testing.allocator;
        const fast_workspace = try EncoderWorkspace.create(allocator);
        defer fast_workspace.destroy(allocator);
        const checked_workspace = try EncoderWorkspace.create(allocator);
        defer checked_workspace.destroy(allocator);
        var fast: Encoder = undefined;
        var checked: Encoder = undefined;
        var saw_448 = false;
        var saw_449 = false;
        var saw_stored = false;
        var saw_dynamic = false;
        for (32..193) |length| for (0..8) |offset| for (0..6) |pattern| {
            try fast.reset(fast_workspace, .{ .compression = .{ .strategy = .four_byte_runs } });
            try checked.reset(
                checked_workspace,
                .{ .compression = .{ .strategy = .four_byte_runs } },
            );
            for (fast_workspace.data[0 .. length + 4], 0..) |*byte, i| {
                byte.* = switch (pattern) {
                    0 => 0,
                    1 => @truncate(i * 73 + i / 13),
                    2 => @intCast((i / 4 + i / 23) % 8),
                    3 => @intCast(if (i % 32 < 28) 0 else (i / 32) % 8),
                    4 => @intCast(if (i % 64 < 32) 7 else 100 + (i * 37) % 100),
                    else => @intCast((i / 4 + i / 5) % 14),
                };
            }
            @memcpy(checked_workspace.data[0 .. length + 4], fast_workspace.data[0 .. length + 4]);
            fast.history = 4;
            checked.history = 4;
            fast.buffered = length;
            checked.buffered = length;
            fast.bit_count = @intCast(offset);
            checked.bit_count = @intCast(offset);
            fast.bits = (@as(u64, 1) << @intCast(offset)) - 1;
            checked.bits = fast.bits;
            const padding = (8 - (offset + 3) % 8) % 8;
            const stored_bits = 3 + padding + 32 + length * 8;
            const initial_slack = stored_bits -| (3 + book.header.bits);
            saw_448 = saw_448 or initial_slack == 448;
            saw_449 = saw_449 or initial_slack == 449;
            var units: u64 = 0;
            var probes: u64 = 0;
            const predicted = try borrows.fourByteRuns(
                &fast,
            ).groupedRunsPreferStored(book, false, &units, &probes, stored_bits);
            var unused_units: u64 = 0;
            var unused_probes: u64 = 0;
            const checked_predicted = try borrows.fourByteRuns(
                &checked,
            ).groupedRunsPreferStored(book, true, &unused_units, &unused_probes, stored_bits);
            try std.testing.expectEqual(predicted, checked_predicted);
            try std.testing.expectEqual(units, checked.stats.work_units);
            try std.testing.expectEqual(probes, checked.stats.match_probes);
            fast.stats = .{};
            checked.stats = .{};
            units = 0;
            probes = 0;
            try borrows.fourByteRuns(&fast).emitRuns(book, true, false, true, &units, &probes);
            try borrows.fourByteRuns(
                &checked,
            ).emitRuns(book, true, true, true, &unused_units, &unused_probes);
            try std.testing.expectEqual(predicted, fast.stats.stored_blocks != 0);
            try std.testing.expectEqual(predicted, checked.stats.stored_blocks != 0);
            try std.testing.expectEqual(units, checked.stats.work_units);
            try std.testing.expectEqual(probes, checked.stats.match_probes);
            try std.testing.expectEqual(fast.pending, checked.pending);
            try std.testing.expectEqual(fast.bits, checked.bits);
            try std.testing.expectEqual(fast.bit_count, checked.bit_count);
            try std.testing.expectEqualSlices(
                u8,
                fast_workspace.wire[0..fast.pending],
                checked_workspace.wire[0..checked.pending],
            );
            saw_stored = saw_stored or predicted;
            saw_dynamic = saw_dynamic or !predicted;
        };
        try std.testing.expect(saw_448 and saw_449 and saw_stored and saw_dynamic);
    }
}

test "all run books pack every byte and mixed edge lanes with padded guards" {
    for (run_books) |book| {
        for (0..512) |pattern| {
            var values: [32]u8 = undefined;
            for (&values, 0..) |*value, i| {
                value.* = if (pattern < 256) @intCast(
                    pattern,
                ) else @intCast(((i * 7 + pattern) % 32 + 240) % 256);
            }
            if (pattern >= 256 and pattern % 3 == 0) values[pattern % 32] = 16;
            if (pattern >= 256 and pattern % 3 == 1) values[pattern % 32] = 239;
            for (0..8) |count| for (0..8) |alignment| {
                var expected_bytes: [144]u8 = @splat(0xa5);
                var actual_bytes: [144]u8 = @splat(0xa5);
                var expected: PackedWriter = .{
                    .book = book,
                    .wire = expected_bytes[alignment..][0..128],
                    .bits = (@as(u64, 1) << @intCast(count)) - 1,
                    .count = @intCast(count),
                    .pending = 3,
                };
                var actual = expected;
                actual.wire = actual_bytes[alignment..][0..128];
                for (values) |value| expected.symbol(&book.header.literal, value);
                expected.flush();
                actual.symbolSpan32(&values, LiteralLookup.init(actual.book));
                try std.testing.expectEqual(expected.pending, actual.pending);
                try std.testing.expectEqual(expected.bits, actual.bits);
                try std.testing.expectEqual(expected.count, actual.count);
                try std.testing.expectEqualSlices(
                    u8,
                    expected.wire[0..expected.pending],
                    actual.wire[0..actual.pending],
                );
                for (
                    actual_bytes[0..alignment],
                ) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
                for (
                    actual_bytes[alignment + actual.pending + 8 ..],
                ) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
            };
        }
    }
}

test "run book selection covers block thresholds history and both accounting paths" {
    const allocator = std.testing.allocator;
    const workspace = try allocator.create(FourByteRunEncoderWorkspace);
    defer allocator.destroy(workspace);
    var encoder: FourByteRunEncoder = undefined;
    for ([_]usize{ 0, 1, 2, 3, 4, 5, 256, 32768 }) |history| {
        for ([_]usize{ 8191, 8192, 65535 }) |length| inline for (.{ false, true }) |bounded| {
            try encoder.reset(workspace, .{ .mode = .runs });
            @memset(workspace.data[0 .. history + length], 0);
            encoder.history = history;
            encoder.buffered = length;
            var units: u64 = 0;
            var probes: u64 = 0;
            var grouped = false;
            var selected_choice: CodebookChoice = .zero_dominant;
            const stored = try borrows.fourByteRuns(
                &encoder,
            ).preferStoredRuns(bounded, &units, &probes, &grouped, &selected_choice);
            try std.testing.expect(!stored and !grouped);
            try std.testing.expectEqual(
                if (length >= 8192) CodebookChoice.balanced else .zero_dominant,
                selected_choice,
            );
            const prefix = 4 -| history;
            const book_work: u64 = if (length >= 8192) prefix + 32 * 258 else 0;
            const book_probes: u64 = if (length >= 8192) 32 else 0;
            try std.testing.expectEqual(
                256 + book_work,
                if (bounded) encoder.stats.work_units else units,
            );
            try std.testing.expectEqual(
                256 - @as(u64, @intFromBool(history < 4)) + book_probes,
                if (bounded) encoder.stats.match_probes else probes,
            );
        };
    }
}

test "run book sampling preserves ties and prefix run window refusals" {
    const allocator = std.testing.allocator;
    const workspace = try allocator.create(FourByteRunEncoderWorkspace);
    defer allocator.destroy(workspace);
    var encoder: FourByteRunEncoder = undefined;
    const length = 8192;
    const zero_dominant_header = 3 + zero_dominant_book.header.bits + zero_dominant_book.header
        .literal.widths[256];
    const balanced_header = 3 + balanced_book.header.bits + balanced_book.header.literal
        .widths[256];
    const header_delta = zero_dominant_header - balanced_header;
    try std.testing.expectEqual(@as(u32, 0), header_delta % 8);
    const tie: usize = header_delta / 8;
    try std.testing.expect(tie > 0 and tie < 32);
    try std.testing.expectEqual(
        zero_dominant_book.header.literal.widths[1],
        balanced_book.header.literal.widths[1],
    );
    try std.testing.expectEqual(
        zero_dominant_book.header.literal.widths[2],
        balanced_book.header.literal.widths[2],
    );
    try std.testing.expectEqual(
        zero_dominant_book.header.literal.widths[0] + 1,
        balanced_book.header.literal.widths[0],
    );

    // Every distance-four candidate immediately mismatches. Equal-width 1/2 literals make each
    // inserted zero add exactly eight units to the fixed-point sample-price difference.
    for ([_]usize{ tie - 1, tie, tie + 1 }) |zeros| inline for (.{ false, true }) |bounded| {
        try encoder.reset(workspace, .{ .mode = .runs });
        for (workspace.data[0 .. length + 4], 0..) |*byte, i| byte.* = @intCast((i / 4) % 2 + 1);
        for (0..zeros) |i| workspace.data[4 + i * (length - 258) / 31] = 0;
        encoder.history = 4;
        encoder.buffered = length;
        var units: u64 = 0;
        var probes: u64 = 0;
        const selected_book = try borrows.fourByteRuns(
            &encoder,
        ).sampleRunBook(bounded, &units, &probes);
        try std.testing.expectEqual(
            if (zeros < tie) CodebookChoice.balanced else .zero_dominant,
            selected_book,
        );
        try std.testing.expectEqual(
            @as(u64, 32 * 33),
            if (bounded) encoder.stats.work_units else units,
        );
        try std.testing.expectEqual(
            @as(u64, 32),
            if (bounded) encoder.stats.match_probes else probes,
        );
    };

    const Case = struct { limit: u64, work: u64, probes: u64 };
    for (
        [_]Case{
            .{ .limit = 0, .work = 0, .probes = 0 },
            .{ .limit = 1, .work = 1, .probes = 1 },
            .{ .limit = 32, .work = 1, .probes = 1 },
            .{ .limit = 33, .work = 33, .probes = 1 },
            .{ .limit = 1055, .work = 1024, .probes = 32 },
            .{ .limit = 1056, .work = 1056, .probes = 32 },
        },
    ) |case| {
        try encoder.reset(workspace, .{ .mode = .runs, .limits = .{ .work_units = case.limit } });
        encoder.history = 4;
        encoder.buffered = length;
        var units: u64 = 0;
        var probes: u64 = 0;
        if (case.limit == 1056) {
            try std.testing.expectEqual(
                CodebookChoice.zero_dominant,
                try borrows.fourByteRuns(&encoder).sampleRunBook(true, &units, &probes),
            );
        } else {
            try std.testing.expectError(
                error.LimitExceeded,
                borrows.fourByteRuns(&encoder).sampleRunBook(true, &units, &probes),
            );
        }
        try std.testing.expectEqual(case.work, encoder.stats.work_units);
        try std.testing.expectEqual(case.probes, encoder.stats.match_probes);
    }
    for (
        [_]Case{
            .{ .limit = 3, .work = 0, .probes = 0 },
            .{ .limit = 4, .work = 4, .probes = 0 },
            .{ .limit = 5, .work = 5, .probes = 1 },
        },
    ) |case| {
        try encoder.reset(workspace, .{ .mode = .runs, .limits = .{ .work_units = case.limit } });
        encoder.buffered = length;
        var units: u64 = 0;
        var probes: u64 = 0;
        try std.testing.expectError(
            error.LimitExceeded,
            borrows.fourByteRuns(&encoder).sampleRunBook(true, &units, &probes),
        );
        try std.testing.expectEqual(case.work, encoder.stats.work_units);
        try std.testing.expectEqual(case.probes, encoder.stats.match_probes);
    }
    try encoder.reset(workspace, .{ .mode = .runs });
    encoder.history = 4;
    encoder.buffered = length;
    encoder.stats.match_probes = std.math.maxInt(u64) - 31;
    var units: u64 = 0;
    var probes: u64 = 0;
    try std.testing.expectError(
        error.CounterOverflow,
        borrows.fourByteRuns(&encoder).sampleRunBook(true, &units, &probes),
    );
    try std.testing.expectEqual(@as(u64, 1024), encoder.stats.work_units);
    try std.testing.expectEqual(std.math.maxInt(u64), encoder.stats.match_probes);
}

test "run book sampling chooses zero-dominant balanced and zero/255-heavy costs" {
    const allocator = std.testing.allocator;
    const workspace = try allocator.create(FourByteRunEncoderWorkspace);
    defer allocator.destroy(workspace);
    var encoder: FourByteRunEncoder = undefined;
    try std.testing.expectEqual(@as(u8, 1), zero_255_heavy_book.header.literal.widths[0]);
    try std.testing.expectEqual(@as(u8, 2), zero_255_heavy_book.header.literal.widths[255]);
    try std.testing.expect(zero_255_heavy_book.wide_edges);
    for (
        16..240,
    ) |symbol| try std.testing.expectEqual(
        @as(u8, 12),
        zero_255_heavy_book.header.literal.widths[symbol],
    );
    for ([_]usize{ 8192, 65535 }) |length| {
        for ([_]usize{ 0, 4, 256 }) |history| {
            for ([_]u8{ 0, 1, 2, 255 }) |step| {
                var fast_units: u64 = 0;
                var fast_probes: u64 = 0;
                inline for (.{ false, true }) |bounded| {
                    try encoder.reset(workspace, .{ .mode = .runs });
                    for (workspace.data[0 .. history + length], 0..) |*byte, i| {
                        byte.* = if ((i / 4) % 2 == 0) 0 else step;
                    }
                    encoder.history = history;
                    encoder.buffered = length;
                    var units: u64 = 0;
                    var probes: u64 = 0;
                    const book = try borrows.fourByteRuns(
                        &encoder,
                    ).sampleRunBook(bounded, &units, &probes);
                    const expected: CodebookChoice = switch (step) {
                        0 => .balanced,
                        255 => .zero_255_heavy,
                        else => .zero_dominant,
                    };
                    try std.testing.expectEqual(expected, book);
                    if (bounded) {
                        try std.testing.expectEqual(fast_units, encoder.stats.work_units);
                        try std.testing.expectEqual(fast_probes, encoder.stats.match_probes);
                    } else {
                        fast_units = units;
                        fast_probes = probes;
                    }
                }
            }
        }
    }
}

test "run price deltas retain signed literal costs and individually rounded matches" {
    try std.testing.expectEqual(@as(i8, 1), run_literal_price_deltas[0].balanced);
    try std.testing.expectEqual(@as(i8, 0), run_literal_price_deltas[0].zero_255_heavy);
    try std.testing.expectEqual(@as(i8, -1), run_literal_price_deltas[255].balanced);
    try std.testing.expectEqual(@as(i8, -2), run_literal_price_deltas[255].zero_255_heavy);
    try std.testing.expectEqual(@as(i8, 2), run_literal_price_deltas[1].zero_255_heavy);
    try std.testing.expectEqual(@as(i16, -9), run_match_price_deltas[258].balanced);
    try std.testing.expectEqual(@as(i16, -7), run_match_price_deltas[258].zero_255_heavy);
    for (run_literal_price_deltas, 0..) |delta, symbol| {
        const zero_dominant: i16 = zero_dominant_book.header.literal.widths[symbol];
        try std.testing.expectEqual(
            @as(i16, balanced_book.header.literal.widths[symbol]),
            zero_dominant + delta.balanced,
        );
        try std.testing.expectEqual(
            @as(i16, zero_255_heavy_book.header.literal.widths[symbol]),
            zero_dominant + delta.zero_255_heavy,
        );
    }
    for (3..259) |length| {
        const zero_dominant: i32 = @intCast(
            ((zero_dominant_book.match_tokens[length] >> 24) * 256 + length / 2) / length,
        );
        const balanced: i32 = @intCast(
            ((balanced_book.match_tokens[length] >> 24) * 256 + length / 2) / length,
        );
        const zero_255_heavy: i32 = @intCast(
            ((zero_255_heavy_book.match_tokens[length] >> 24) * 256 + length / 2) / length,
        );
        try std.testing.expectEqual(
            balanced,
            zero_dominant + run_match_price_deltas[length].balanced,
        );
        try std.testing.expectEqual(
            zero_255_heavy,
            zero_dominant + run_match_price_deltas[length].zero_255_heavy,
        );
    }
}
