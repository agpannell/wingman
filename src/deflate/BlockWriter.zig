//! Emit RFC 1951 stored, fixed-Huffman and dynamic-Huffman blocks into pending output storage. The
//! borrowed cursor retains partial bytes between blocks, and counters publish as construction
//! proceeds. Ordinary coded emission receives its writable header explicitly. Callers admit the
//! token range and reserve enough wire storage before writing; these primitives do not suspend or
//! grow their destination.

const std = @import("std");
const EncodeStats = @import("EncodeStats.zig");
const protocol = @import("format.zig");
const HuffmanCodebook = @import("HuffmanCodebook.zig");
const DynamicBlockHeader = @import("DynamicBlockHeader.zig");
const BlockSelector = @import("BlockSelector.zig");
const Token = @import("Lz77Parser.zig").Token;
const Segment = BlockSelector.Segment;
const Kind = BlockSelector.Kind;
const EncodeWorkBudget = @import("EncodeWorkBudget.zig");
const addCount = EncodeWorkBudget.addCount;
const precode_order = protocol.precode_order;
const length_base = protocol.length_base;
const length_extra = protocol.length_extra;
const distance_base = protocol.distance_base;
const distance_extra = protocol.distance_extra;
const lengthSlot = protocol.lengthSlot;
const distanceSlot = protocol.distanceSlot;
const fixedBook = HuffmanCodebook.fixed;
const runExtra = DynamicBlockHeader.runExtra;

const BlockWriter = @This();

/// Copied history and active slab; stored segments select their bytes from this span.
data: []const u8,
/// Byte offset of the active slab after copied history.
history: usize,
/// Borrowed output staging; pending identifies its initialized prefix.
wire: []u8,
/// Stream-owned low pending bits, shared across consecutive blocks.
bits: *u64,
/// Number of low bits in bits; fewer than eight between operations.
bit_count: *u6,
/// Complete staged wire bytes, before the stream drains them to caller output.
pending: *usize,
/// Borrowed live stream counters. Block construction updates their distinct fields before pending
/// output is drained to the caller.
stats: *EncodeStats,

/// Emits an admitted token range. Dynamic headers must already be constructed; fixed emission
/// replaces the header's payload books with the RFC fixed codes. Counter failure may leave staged
/// bytes and the shared cursor changed, preserving the stream's partial-failure state.
pub fn emit(
    self: BlockWriter,
    header: *DynamicBlockHeader,
    tokens: []const Token,
    segment: Segment,
    kind: Kind,
    final: bool,
) error{CounterOverflow}!void {
    if (kind == .stored) {
        const start = self.history + segment.start;
        const bytes = self.data[start..][0..segment.bytes];
        return self.stored(bytes, final);
    }
    self.put(@intFromBool(final), 1);
    self.put(if (kind == .fixed) 1 else 2, 2);
    if (kind == .fixed) {
        fixedBook(&header.literal, false);
        fixedBook(&header.distance, true);
        self.stats.fixed_blocks = try addCount(self.stats.fixed_blocks, 1);
    } else {
        self.put(header.literal_count - 257, 5);
        self.put(header.distance_count - 1, 5);
        self.put(header.precode_count - 4, 4);
        for (
            precode_order[0..header.precode_count],
        ) |symbol| self.put(header.precode.widths[symbol], 3);
        for (header.runs[0..header.run_count]) |run| {
            self.putSymbol(&header.precode, run.symbol);
            self.put(run.extra, runExtra(run.symbol));
        }
        self.stats.dynamic_blocks = try addCount(self.stats.dynamic_blocks, 1);
    }
    for (tokens) |token| {
        if (token.length == 0) {
            self.putSymbol(&header.literal, token.value);
        } else {
            const length = lengthSlot(token.length);
            const distance = distanceSlot(token.value);
            self.putSymbol(&header.literal, 257 + @as(usize, length));
            self.put(token.length - length_base[length], @intCast(length_extra[length]));
            self.putSymbol(&header.distance, distance);
            self.put(token.value - distance_base[distance], @intCast(distance_extra[distance]));
        }
    }
    self.putSymbol(&header.literal, 256);
    self.stats.blocks = try addCount(self.stats.blocks, 1);
}

/// Emits one admitted stored block of at most 65,535 bytes, aligning the shared bit cursor first.
/// Wire storage must cover the header, alignment and body. Counter failure can follow wire writes.
pub fn stored(self: BlockWriter, bytes: []const u8, final: bool) error{CounterOverflow}!void {
    self.put(@intFromBool(final), 1);
    self.put(0, 2);
    self.alignBits();
    writeStoredBody(bytes, self.wire[self.pending.*..][0 .. bytes.len + 4]);
    self.pending.* += bytes.len + 4;
    self.stats.blocks = try addCount(self.stats.blocks, 1);
    self.stats.stored_blocks = try addCount(self.stats.stored_blocks, 1);
}

/// Emits an initialized symbol whose nonzero code width is admitted by the selected codebook.
pub fn putSymbol(self: BlockWriter, book: *const HuffmanCodebook, value: usize) void {
    self.put(book.codes[value], @intCast(book.widths[value]));
}

/// Appends a value fitting width bits. The pending count plus width must fit both u6 and the u64
/// cursor; callers provide room for every complete byte. Fewer than eight pending bits remain.
pub fn put(self: BlockWriter, value: usize, width: u6) void {
    self.bits.* |= @as(u64, @intCast(value)) << self.bit_count.*;
    self.bit_count.* += width;
    while (self.bit_count.* >= 8) {
        self.wire[self.pending.*] = @truncate(self.bits.*);
        self.pending.* += 1;
        self.bits.* >>= 8;
        self.bit_count.* -= 8;
    }
}

pub fn alignBits(self: BlockWriter) void {
    if (self.bit_count.* != 0) self.put(0, 8 - self.bit_count.*);
}

/// Writes a byte-aligned LEN/NLEN pair and at most 65,535 source bytes. Source and output are
/// disjoint, and output must have exactly source.len + 4 bytes. Block-kind/final bits are separate.
pub fn writeStoredBody(source: []const u8, output: []u8) void {
    const length: u16 = @intCast(source.len);
    std.mem.writeInt(u16, output[0..2], length, .little);
    std.mem.writeInt(u16, output[2..4], length ^ 65535, .little);
    @memcpy(output[4..], source);
}
