//! Canonical DEFLATE tables, payload leaves and bounded continuation storage.

const std = @import("std");

const bit_io = @import("bits.zig");
const fixture_data = @import("fixtures.zig");
const protocol = @import("format.zig");

const Bits = bit_io.Bits;
const Error = protocol.Error;
const IndexShift = std.math.Log2Int(usize);

const distance_base = protocol.distance_base;
const distance_extra = protocol.distance_extra;
const length_base = protocol.length_base;
const length_extra = protocol.length_extra;
const paired_dense = fixture_data.paired_dense;

/// Four-byte canonical lookup entry. Ordinary leaves carry a code width and base value; prepared
/// and expanded forms reinterpret widths and tags for their matching decode workers.
pub const Entry = packed struct(u32) {
    // Literal leaves hold bytes, 256 (EOB), or 256 + a length base. Distance leaves hold a distance
    // base. Node values index children; extra is zero. Reserved lengths use 65535 and reserved
    // distances use zero, so the token checks reject them alongside impossible distances without
    // another array read. Lengths remain 0..15, but a whole low byte lets consumption use the
    // loaded entry directly without extracting a shifted sub-byte field on x86.
    bits: u8 = 0,
    extra: u4 = 0,
    node: bool = false,
    // Paired-table literals mirror a byte or pack two little-endian bytes. Count 1/2 selects exact
    // stores; ordinary tables keep scalar values and count zero. A paired root's extra field
    // retains its first code length for short tails.
    literals: u2 = 0,
    unused: u1 = 0,
    value: u16 = 0,
};

/// Resolved leaf and its original low bits, retained until extra payload extraction completes.
pub const PayloadLeaf = struct { entry: Entry, saved_value: u64 };

/// Whether canonical symbols remain ordinals or become literal/length and distance bases.
pub const TableKind = enum { symbols, literal_length, distance };

const DecodeMode = enum {
    // Complete codebooks whose longest code fits in the root need no continuation lookup.
    root,
    complete,
    paired,
    distance,
    // pairedPrefix admits a whole token before these modes access the buffer.
    buffered_paired,
    buffered_distance,
};

/// Nine-bit literal/length root with binary continuations for longer codes.
pub const LiteralTable = Huffman(9, 288, .literal_length);

/// Nine-bit root with length payloads folded into exact-length leaves. Replication across unused
/// lookahead bits permits checked decoding at EOF. The bounded table fits the paired backing.
pub const ExpandedLiteralTable = ExpandedLiteral(9);

/// Eleven-bit variant of ExpandedLiteralTable using the same 4,608-entry total reservation.
pub const ExpandedWideLiteralTable = ExpandedLiteral(11);

fn ExpandedLiteral(comptime root_bits: u5) type {
    return extern struct {
        const Self = @This();
        root: [1 << root_bits]Entry,
        children: [4608 - (1 << root_bits)]Entry,
        nodes: usize,

        /// Reads one checked leaf through at most one flat continuation. Every consumed bit must
        /// exist, even when zero-filled lookahead selects a replicated leaf near EOF.
        pub fn decode(self: *const Self, bits: *Bits, comptime mode: DecodeMode) Error!Entry {
            _ = mode;
            bits.refill(root_bits);
            var entry = self.root[@as(usize, @truncate(bits.value)) & (self.root.len - 1)];
            if (entry.bits == 0 or bits.count < entry.bits) return error.InvalidStream;
            bits.drop(entry.bits);
            if (entry.node) {
                bits.refill(entry.extra);
                const mask = (@as(usize, 1) << entry.extra) - 1;
                entry = self.children[entry.value + (@as(usize, @truncate(bits.value)) & mask)];
                if (entry.bits == 0 or bits.count < entry.bits) return error.InvalidStream;
                bits.drop(entry.bits);
            }
            return entry;
        }
    };
}

/// Eleven-bit literal/length root with binary continuations for longer codes.
pub const WideLiteralTable = Huffman(11, 288, .literal_length);

/// Twelve-bit root that can return one or two literals per lookup.
pub const PairedLiteralTable = Huffman(12, 288, .literal_length);

/// Eight-bit distance root with binary continuations for longer codes. This avoids a separate
/// widening pass and permits a low-byte root index.
pub const DistanceTable = Huffman(8, 32, .distance);

/// Maps a canonical symbol to its ordinary leaf. Reserved lengths/distances use invalid sentinels
/// so token admission can reject them without another symbol-table lookup.
pub fn leaf(comptime kind: TableKind, symbol: usize, bits: u5) Entry {
    return switch (kind) {
        .symbols => .{ .value = @intCast(symbol), .bits = bits },
        .literal_length => blk: {
            if (symbol <= 256) break :blk .{ .value = @intCast(symbol), .bits = bits };
            if (symbol > 285) break :blk .{ .value = 65535, .bits = bits };
            const index = symbol - 257;
            break :blk .{
                .value = 256 + length_base[index],
                .bits = bits,
                .extra = @intCast(length_extra[index]),
            };
        },
        .distance => blk: {
            if (symbol > 29) break :blk .{ .bits = bits };
            break :blk .{
                .value = distance_base[symbol],
                .bits = bits,
                .extra = @intCast(distance_extra[symbol]),
            };
        },
    };
}

/// Bounded canonical table type for a selected root width, alphabet size and leaf interpretation.
/// Root lookups collapse early code bits; each remaining binary node stores both children.
pub fn Huffman(comptime root_bits: u5, comptime symbols: usize, comptime kind: TableKind) type {
    if (root_bits == 0) @compileError("Huffman primary tables need at least one bit");
    // Explicit layout permits the tag-free workspace union; codebook admission owns each table's
    // construction and active lifetime.
    return extern struct {
        const Self = @This();
        root: [1 << root_bits]Entry,
        // A complete binary code with N leaves has N - 1 internal nodes. Root lookups collapse some
        // of those nodes; admitted empty/single-bit codes fit in the primary table. Each slot
        // already contains both children.
        children: [symbols - 1][2]Entry,
        nodes: usize,

        fn newNode(self: *Self) Error!u16 {
            if (self.nodes == self.children.len) return error.InvalidStream;
            const index = self.nodes;
            self.nodes += 1;
            self.children[index] = .{ .{}, .{} };
            return @intCast(index);
        }

        const CodeCounts = struct { counts: [16]u16, complete: bool };

        fn countCodes(lengths: []const u8, allow_empty: bool, allow_single: bool) Error!CodeCounts {
            std.debug.assert(lengths.len <= symbols);
            var counts: [16]u16 = @splat(0);
            var used: usize = 0;
            for (lengths) |length| {
                if (length > 15) return error.InvalidStream;
                // Sparse alphabets contain long runs of absent symbols. Count their complement in a
                // register instead of serializing increments through the same histogram slot.
                if (length == 0) continue;
                used += 1;
                counts[length] += 1;
            }
            counts[0] = @intCast(lengths.len - used);
            var space: i32 = 1;
            for (1..16) |length| {
                space = space * 2 - counts[length];
                if (space < 0) return error.InvalidStream;
            }
            if (space != 0) {
                const incomplete_allowed = blk: {
                    if (allow_empty and used == 0) break :blk true;
                    break :blk allow_single and used == 1 and counts[1] == 1;
                };
                if (!incomplete_allowed) return error.InvalidStream;
            }

            return .{ .counts = counts, .complete = space == 0 };
        }

        fn canonicalStarts(counts: *const [16]u16) [16]u16 {
            var next: [16]u16 = @splat(0);
            var code: u16 = 0;
            for (1..16) |length| {
                code = (code + if (length == 1) 0 else counts[length - 1]) << 1;
                next[length] = code;
            }
            return next;
        }

        // Both constructors collapse root_bits levels under the N-1-node bound.
        fn insertContinuation(self: *Self, reversed: u16, length: u8, entry: Entry) Error!void {
            const prefix = reversed & (self.root.len - 1);
            const root = &self.root[prefix];
            if (root.bits == 0) root.* = .{
                .value = try self.newNode(),
                .bits = root_bits,
                .node = true,
            };
            if (!root.node) return error.InvalidStream;
            var node = root.value;
            var position: u8 = root_bits;
            while (position < length) : (position += 1) {
                const side = (reversed >> @as(u4, @intCast(position))) & 1;
                const child = &self.children[node][side];
                if (position + 1 == length) {
                    if (child.bits != 0) return error.InvalidStream;
                    child.* = entry;
                } else {
                    if (child.bits == 0) child.* = .{
                        .value = try self.newNode(),
                        .bits = 1,
                        .node = true,
                    };
                    if (!child.node) return error.InvalidStream;
                    node = child.value;
                }
            }
        }

        /// Builds this bounded canonical alphabet in place, without retaining lengths or requesting
        /// allocation. Empty/single-bit exceptions are explicit format policy; malformed,
        /// oversubscribed or otherwise incomplete alphabets reject. Returned true means complete
        /// Kraft coverage. Preserve the initialized table until its last lookup.
        pub fn build(
            self: *Self,
            lengths: []const u8,
            allow_empty: bool,
            allow_single: bool,
        ) Error!bool {
            if (lengths.len > symbols) return error.InvalidStream;
            const admitted = try countCodes(lengths, allow_empty, allow_single);
            if (kind == .literal_length and root_bits == 11) {
                // Sorted symbols temporarily occupy continuation backing. Complete short-code
                // levels grow by copying the preceding level, including any invalid singleton half.
                // No full-root clear is necessary.
                const counts = &admitted.counts;
                var offsets: [16]u16 = @splat(0);
                for (1..15) |length| offsets[length + 1] = offsets[length] + counts[length];
                var ends = offsets;
                const sorted = std.mem.bytesAsSlice(
                    u16,
                    std.mem.asBytes(&self.children),
                )[0..symbols];
                for (lengths, 0..) |length, symbol| {
                    if (length == 0) continue;
                    sorted[ends[length]] = @intCast(symbol);
                    ends[length] += 1;
                }
                var next = canonicalStarts(counts);
                @memset(self.root[0..2], .{});
                for (1..root_bits + 1) |length| {
                    const end = @as(usize, 1) << @as(u4, @intCast(length));
                    for (sorted[offsets[length]..ends[length]]) |symbol| {
                        const shift: u4 = @intCast(16 - length);
                        const reversed = @bitReverse(next[length]) >> shift;
                        next[length] += 1;
                        self.root[reversed] = leaf(kind, symbol, @intCast(length));
                    }
                    if (length < root_bits) @memcpy(self.root[end..][0..end], self.root[0..end]);
                }
                // Construction no longer reads sorted; continuation nodes can initialize and
                // overwrite that same storage now.
                self.nodes = 0;
                for (lengths, 0..) |length, symbol| {
                    if (length <= root_bits) continue;
                    const reversed = @bitReverse(next[length]) >> @as(u4, @intCast(16 - length));
                    next[length] += 1;
                    try self.insertContinuation(reversed, length, leaf(kind, symbol, 1));
                }
            } else {
                @memset(&self.root, .{});
                self.nodes = 0;
                var next = canonicalStarts(&admitted.counts);
                for (lengths, 0..) |length, symbol| {
                    if (length == 0) continue;
                    const reversed = @bitReverse(next[length]) >> @as(u4, @intCast(16 - length));
                    next[length] += 1;
                    if (length <= root_bits) {
                        var index: usize = reversed;
                        const stride = @as(usize, 1) << @as(u4, @intCast(length));
                        while (index < self.root.len) : (index += stride) {
                            self.root[index] = leaf(kind, symbol, @intCast(length));
                        }
                    } else {
                        try self.insertContinuation(reversed, length, leaf(kind, symbol, 1));
                    }
                }
            }
            return admitted.complete;
        }

        /// Builds complete literal pairs while growing the primary table, so short-code copies also
        /// replicate completed pairs. Continuation backing temporarily holds sorted symbols and
        /// codes; it is reused only after primary construction ends.
        pub fn buildPaired(self: *Self, lengths: []const u8) Error!void {
            if (kind != .literal_length) @compileError("paired construction needs literals");
            const admitted = try countCodes(lengths, false, false);
            const counts = &admitted.counts;
            var offsets: [16]u16 = @splat(0);
            for (1..15) |length| offsets[length + 1] = offsets[length] + counts[length];
            var ends = offsets;
            const construction = std.mem.bytesAsSlice(u16, std.mem.asBytes(&self.children));
            const sorted = construction[0..symbols];
            const codes = construction[symbols..][0..symbols];
            for (lengths, 0..) |length, symbol| {
                if (length == 0) continue;
                sorted[ends[length]] = @intCast(symbol);
                ends[length] += 1;
            }
            var next = canonicalStarts(counts);
            @memset(self.root[0..2], .{});
            for (1..root_bits + 1) |length| {
                const end = @as(usize, 1) << @as(u4, @intCast(length));
                for (sorted[offsets[length]..ends[length]]) |symbol| {
                    const reversed = @bitReverse(next[length]) >> @as(u4, @intCast(16 - length));
                    next[length] += 1;
                    codes[symbol] = reversed;
                    self.root[reversed] = single(leaf(kind, symbol, @intCast(length)));
                }
                for (1..length) |first_length| {
                    const second_length = length - first_length;
                    for (sorted[offsets[first_length]..ends[first_length]]) |first| {
                        if (first >= 256) continue;
                        for (sorted[offsets[second_length]..ends[second_length]]) |second| {
                            if (second >= 256) continue;
                            const shift: u4 = @intCast(first_length);
                            const index = codes[first] | (codes[second] << shift);
                            self.root[index] = .{
                                .bits = @intCast(length),
                                .extra = @intCast(first_length),
                                .literals = 2,
                                .value = first | (second << 8),
                            };
                        }
                    }
                }
                if (length < root_bits) @memcpy(self.root[end..][0..end], self.root[0..end]);
            }

            // Primary construction no longer reads sorted/codes. New continuation nodes can
            // overwrite their temporary storage in the same owner.
            self.nodes = 0;
            for (lengths, 0..) |length, symbol| {
                if (length <= root_bits) continue;
                const reversed = @bitReverse(next[length]) >> @as(u4, @intCast(16 - length));
                next[length] += 1;
                try self.insertContinuation(reversed, length, single(leaf(kind, symbol, 1)));
            }
        }

        // Mirror scalar literals for exact stores, or recover a pair's first code/value when a
        // short input tail cannot supply both complete codes.
        fn single(entry: Entry) Entry {
            if (entry.literals == 2) return .{
                .bits = entry.extra,
                .literals = 1,
                .value = (entry.value & 255) * 257,
            };
            if (entry.literals == 1 or entry.node or entry.bits == 0 or entry.value >= 256)
                return entry;
            return .{ .bits = entry.bits, .literals = 1, .value = entry.value * 257 };
        }

        /// Resolves an ordinary leaf and consumes its code plus payload. The caller proves at least
        /// 56 buffered bits before a token of at most 48. Table metadata stays unchanged; the
        /// returned copy stores total/code widths for deferred extraction from saved_value.
        // Keep the packed result: separate scalar widths change LLVM scheduling without reducing
        // complete-token or complete-buffer decoding costs.
        pub fn decodePayloadBuffered(self: *const Self, bits: *Bits, first: Entry) PayloadLeaf {
            if (kind == .symbols) @compileError("payload lookup needs base-valued entries");
            var entry = first;
            while (entry.node) {
                bits.drop(entry.bits);
                entry = self.children[entry.value][@as(usize, @truncate(bits.value)) & 1];
            }
            const saved = bits.value;
            const code = entry.bits;
            entry.bits += entry.extra;
            entry.extra = @intCast(code);
            bits.drop(entry.bits);
            return .{ .entry = entry, .saved_value = saved };
        }

        /// Reads one symbol or base-valued leaf. Buffered modes require the caller's whole-token
        /// admission; other modes check input availability. Distance holes return a zero base for
        /// the caller's invalid-distance check. A short paired tail consumes only its first
        /// literal.
        pub fn decode(
            self: *const Self,
            bits: *Bits,
            comptime mode: DecodeMode,
        ) Error!(if (kind == .symbols) u16 else Entry) {
            const buffered = mode == .buffered_paired or mode == .buffered_distance;
            if ((mode == .distance or mode == .buffered_distance) and kind != .distance)
                @compileError(
                    "distance decoding requires zero-valued invalid leaves",
                );
            if (!buffered) bits.refill(root_bits);
            var entry = self.root[@as(usize, @truncate(bits.value)) & (self.root.len - 1)];
            // Complete trees have no holes; root-only tables have no continuation nodes. Distance
            // holes and reserved symbols both return zero for the caller's existing invalid-base
            // check. Input availability remains checked here. A short tail can contain the first
            // code without the second. Consume that first literal normally; the next lookup keeps
            // EOF/error priority.
            if (mode == .paired and bits.count < entry.bits and entry.literals == 2) {
                entry = single(entry);
            }
            if (!buffered and bits.count < entry.bits) {
                @branchHint(.unlikely);
                return error.InvalidStream;
            }
            bits.drop(entry.bits);
            if (mode != .root) {
                while (entry.node) {
                    const side = if (buffered) bits.takeBuffered(1) else try bits.take(1);
                    entry = self.children[entry.value][side];
                }
            }
            return if (kind == .symbols) entry.value else entry;
        }
    };
}

/// Packed canonical tables and bounded construction scratch for complete books. The decoder admits
/// this representation only for whole-buffer, full-window calls. Primary and secondary entries
/// cache bases and consumed/code widths.
pub const CommonTables = extern struct {
    const Self = @This();

    /// Direct literal leaf; bits 16..23 contain its byte value.
    pub const literal_flag: u32 = 0x80000000;
    /// Entry carries a continuation or end-of-block marker rather than a match base.
    pub const exceptional: u32 = 0x8000;
    /// Continuation entry; its high halfword indexes a flat secondary table.
    pub const subtable: u32 = 0x4000;
    /// End-of-block marker, combined with exceptional.
    pub const end_flag: u32 = 0x2000;

    const Built = struct { bits: u8, used: u16 };

    literal: [2342]u32,
    distance: [402]u32,
    sorted: [288]u16,
    offsets: [16]u16,
    literal_used: u16,
    distance_used: u16,
    literal_bits: u8,

    /// Resolved packed leaf with the original low bits available for payload extraction.
    pub const Decoded = struct {
        entry: u32,
        saved: u64,

        /// Adds the extra payload to a resolved length/distance base. Literal, continuation and
        /// end-of-block entries must be handled before calling.
        pub fn matchValue(self: Decoded) usize {
            std.debug.assert(self.entry & (literal_flag | exceptional) == 0);
            const total: u8 = @truncate(self.entry);
            const code: u8 = @truncate(self.entry >> 8);
            const mask = (@as(u64, 1) << @as(u6, @intCast(total))) - 1;
            const payload: usize = @intCast((self.saved & mask) >> @as(u6, @intCast(code)));
            const base: usize = self.entry >> 16;
            return base + payload;
        }
    };

    /// Reads one checked leaf, retaining its original bits for extra payload. Zero-filled lookahead
    /// may select a replicated leaf near EOF; every consumed code and payload bit must be present
    /// in the supplied input.
    pub fn read(self: *const Self, comptime distances: bool, bits: *Bits) Error!Decoded {
        const table: []const u32 = if (distances) &self.distance else &self.literal;
        const root_bits: u8 = if (distances) 8 else self.literal_bits;
        bits.refill(root_bits);
        const root_mask = (@as(usize, 1) << @as(IndexShift, @intCast(root_bits))) - 1;
        var value = table[@as(usize, @truncate(bits.value)) & root_mask];
        if (value & subtable != 0) {
            if (bits.count < root_bits) return error.InvalidStream;
            bits.drop(root_bits);
            const suffix: u8 = @intCast((value >> 8) & 63);
            bits.refill(suffix);
            const mask = (@as(usize, 1) << @as(IndexShift, @intCast(suffix))) - 1;
            value = table[(value >> 16) + (@as(usize, @truncate(bits.value)) & mask)];
        }
        const consumed: u8 = @truncate(value);
        bits.refill(consumed);
        if (bits.count < consumed) return error.InvalidStream;
        const saved = bits.value;
        bits.drop(consumed);
        return .{ .entry = value, .saved = saved };
    }

    /// Builds both tables without allocation. False declines a valid book that needs another
    /// representation; invalid code lengths return InvalidStream. A refusal may change scratch, so
    /// read only after successful construction.
    pub fn build(self: *Self, lengths: []const u8, distances: []const u8) Error!bool {
        if (lengths.len < 257 or lengths.len > 286 or distances.len == 0 or distances.len > 32)
            return error.InvalidStream;
        if (lengths[256] == 0) return error.InvalidStream;
        const literal_counts = try LiteralTable.countCodes(lengths, false, true);
        const distance_counts = try DistanceTable.countCodes(distances, true, true);
        if (!literal_counts.complete or !distance_counts.complete) return false;
        if (distances.len > 30 and distances[30] != 0) return false;
        if (distances.len > 31 and distances[31] != 0) return false;

        const built_distance = self.buildFlat(
            &self.distance,
            distances,
            distance_counts.counts,
            .distance,
            8,
            false,
        ) orelse return false;
        const built_literal = self.buildFlat(
            &self.literal,
            lengths,
            literal_counts.counts,
            .literal_length,
            11,
            true,
        ) orelse return false;
        self.literal_bits = built_literal.bits;
        self.literal_used = built_literal.used;
        self.distance_used = built_distance.used;
        return true;
    }

    fn entry(comptime kind: TableKind, symbol: usize, width: u8) u32 {
        if (kind == .distance) {
            std.debug.assert(symbol < 30);
            const base = @as(u32, distance_base[symbol]) << 16;
            const code = @as(u32, width) << 8;
            const total = @as(u32, width) + distance_extra[symbol];
            return base | code | total;
        }
        if (symbol < 256) return literal_flag | (@as(u32, @intCast(symbol)) << 16) | width;
        if (symbol == 256) return exceptional | end_flag | width;
        std.debug.assert(symbol < 286);
        const index = symbol - 257;
        const base = @as(u32, length_base[index]) << 16;
        const code = @as(u32, width) << 8;
        const total = @as(u32, width) + length_extra[index];
        return base | code | total;
    }

    // The caller has already excluded the all-ones final codeword.
    fn advance(word: usize, width: u8) usize {
        const mask = (@as(usize, 1) << @as(IndexShift, @intCast(width))) - 1;
        const flipped = word ^ mask;
        std.debug.assert(flipped != 0);
        const shift: IndexShift = @intCast(@bitSizeOf(usize) - 1 - @clz(flipped));
        const bit = @as(usize, 1) << shift;
        return (word & (bit - 1)) | bit;
    }

    fn buildFlat(
        self: *Self,
        table: []u32,
        lengths: []const u8,
        counts: [16]u16,
        comptime kind: TableKind,
        comptime root_max: u8,
        comptime shrink: bool,
    ) ?Built {
        var maximum: u8 = 15;
        while (maximum > 1 and counts[maximum] == 0) maximum -= 1;
        const root_bits = if (shrink) @min(root_max, maximum) else root_max;
        const root_size = @as(usize, 1) << @as(IndexShift, @intCast(root_bits));
        if (root_size > table.len) return null;
        self.offsets[0] = 0;
        for (1..16) |i| self.offsets[i] = self.offsets[i - 1] + counts[i - 1];
        for (lengths, 0..) |width, symbol| {
            self.sorted[self.offsets[width]] = @intCast(symbol);
            self.offsets[width] += 1;
        }
        var sorted: usize = self.offsets[0];
        var width: u8 = 1;
        while (counts[width] == 0) width += 1;
        var remaining: usize = counts[width];
        var word: usize = 0;
        var table_end = @as(usize, 1) << @as(IndexShift, @intCast(width));
        while (width <= root_bits) {
            while (remaining != 0) : (remaining -= 1) {
                table[word] = entry(kind, self.sorted[sorted], width);
                sorted += 1;
                if (word == table_end - 1) {
                    while (width < root_bits) : (width += 1) {
                        @memcpy(table[table_end..][0..table_end], table[0..table_end]);
                        table_end *= 2;
                    }
                    return .{ .bits = root_bits, .used = @intCast(table_end) };
                }
                word = advance(word, width);
            }
            while (true) {
                width += 1;
                if (width <= root_bits) {
                    // As-yet-unfilled words may be transported by this byte copy. Complete Kraft
                    // coverage fills every reachable word before use.
                    @memcpy(table[table_end..][0..table_end], table[0..table_end]);
                    table_end *= 2;
                }
                remaining = counts[width];
                if (remaining != 0) break;
            }
        }
        table_end = root_size;
        var prefix: usize = std.math.maxInt(usize);
        var start: usize = 0;
        while (true) {
            const next_prefix = word & (root_size - 1);
            if (next_prefix != prefix) {
                prefix = next_prefix;
                start = table_end;
                var suffix_bits = width - root_bits;
                var space = remaining;
                while (space < (@as(usize, 1) << @as(IndexShift, @intCast(suffix_bits)))) {
                    suffix_bits += 1;
                    space = space * 2 + counts[root_bits + suffix_bits];
                }
                const slots = @as(usize, 1) << @as(IndexShift, @intCast(suffix_bits));
                if (slots > table.len - start) return null;
                table_end = start + slots;
                const child_index = @as(u32, @intCast(start)) << 16;
                const child_width = @as(u32, suffix_bits) << 8;
                table[prefix] = child_index | exceptional | subtable | child_width | root_bits;
            }
            const suffix = width - root_bits;
            const value = entry(kind, self.sorted[sorted], suffix);
            sorted += 1;
            var index = start + (word >> @as(IndexShift, @intCast(root_bits)));
            const stride = @as(usize, 1) << @as(IndexShift, @intCast(suffix));
            while (index < table_end) : (index += stride) table[index] = value;
            const last_word = (@as(usize, 1) << @as(IndexShift, @intCast(width))) - 1;
            if (word == last_word) return .{ .bits = root_bits, .used = @intCast(table_end) };
            word = advance(word, width);
            remaining -= 1;
            while (remaining == 0) {
                width += 1;
                remaining = counts[width];
            }
        }
    }
};

/// Appends each length payload to its canonical code, mapping to exact lengths. A valid book can
/// exceed secondary capacity: returns false without allocating, then the caller reconstructs its
/// ordinary representation in the same union. Read table only after successful construction.
pub fn buildExpandedLiteral(table: anytype, lengths: []const u8) Error!bool {
    const root_bits: u5 = if (@TypeOf(table.*) == ExpandedLiteralTable) 9 else 11;
    if (lengths.len > 286) return error.InvalidStream;
    const admitted = try LiteralTable.countCodes(lengths, false, false);
    var next = LiteralTable.canonicalStarts(&admitted.counts);
    @memset(&table.root, .{});
    table.nodes = 0;
    // Determine each actual prefix's secondary width. Short leaves stay direct.
    for (lengths, 0..) |width, symbol| {
        if (width == 0) continue;
        const reversed: u32 = @bitReverse(next[width]) >> @as(u4, @intCast(16 - width));
        next[width] += 1;
        const extra: u8 = if (symbol >= 257) length_extra[symbol - 257] else 0;
        const total = width + extra;
        for (0..@as(usize, 1) << @as(u5, @intCast(extra))) |payload| {
            const word = reversed | (@as(u32, @intCast(payload)) << @as(u5, @intCast(width)));
            if (total <= root_bits) {
                var index: usize = word;
                const stride = @as(usize, 1) << @as(u5, @intCast(total));
                const expanded_leaf = expandedLeaf(symbol, payload, total);
                while (index < table.root.len) : (index += stride) {
                    table.root[index] = expanded_leaf;
                }
            } else {
                const first = &table.root[word & (table.root.len - 1)];
                if (first.bits != 0 and !first.node) return error.InvalidStream;
                first.* = .{
                    .bits = root_bits,
                    .node = true,
                    .extra = @intCast(@max(first.extra, total - root_bits)),
                };
            }
        }
    }
    for (&table.root) |*entry| {
        if (!entry.node) continue;
        const count = @as(usize, 1) << entry.extra;
        if (count > table.children.len - table.nodes) return false;
        entry.value = @intCast(table.nodes);
        @memset(table.children[table.nodes..][0..count], .{});
        table.nodes += count;
    }
    next = LiteralTable.canonicalStarts(&admitted.counts);
    // Replicate every exact length or byte leaf across its unused lookahead bits.
    for (lengths, 0..) |width, symbol| {
        if (width == 0) continue;
        const reversed: u32 = @bitReverse(next[width]) >> @as(u4, @intCast(16 - width));
        next[width] += 1;
        const extra: u8 = if (symbol >= 257) length_extra[symbol - 257] else 0;
        const total = width + extra;
        if (total <= root_bits) continue;
        for (0..@as(usize, 1) << @as(u5, @intCast(extra))) |payload| {
            const word = reversed | (@as(u32, @intCast(payload)) << @as(u5, @intCast(width)));
            const first = table.root[word & (table.root.len - 1)];
            const suffix = total - root_bits;
            var index: usize = first.value + (word >> root_bits);
            const end = first.value + (@as(usize, 1) << first.extra);
            const stride = @as(usize, 1) << @as(u5, @intCast(suffix));
            const expanded_leaf = expandedLeaf(symbol, payload, suffix);
            while (index < end) : (index += stride) table.children[index] = expanded_leaf;
        }
    }
    return true;
}

// Complete expanded books cache exact match lengths and literal/EOB tags.
fn expandedLeaf(symbol: usize, payload: usize, bits: u8) Entry {
    std.debug.assert(symbol < 286);
    const value: u16 = blk: {
        if (symbol < 256) break :blk @intCast(symbol);
        if (symbol == 256) break :blk 0;
        break :blk length_base[symbol - 257] + @as(u16, @intCast(payload));
    };
    return .{
        .bits = bits,
        .literals = @intFromBool(symbol < 256),
        .unused = @intFromBool(symbol == 256),
        .value = value,
    };
}

/// Fixed nine-bit literal/length lookup returning raw RFC symbol ordinals.
pub const FixedLiteralTable = Huffman(9, 288, .symbols);

/// Fixed six-bit distance lookup returning raw RFC symbol ordinals.
pub const FixedDistanceTable = Huffman(6, 32, .symbols);

/// Immutable RFC 1951 fixed codebooks; no runtime table construction is needed.
pub const fixed: struct { literal: FixedLiteralTable, distance: FixedDistanceTable } = blk: {
    @setEvalBranchQuota(200000);
    var literal: FixedLiteralTable = undefined;
    var distance: FixedDistanceTable = undefined;
    var lengths: [288]u8 = undefined;
    @memset(lengths[0..144], 8);
    @memset(lengths[144..256], 9);
    @memset(lengths[256..280], 7);
    @memset(lengths[280..], 8);
    _ = literal.build(&lengths, false, false) catch unreachable;
    const distance_lengths: [32]u8 = @splat(5);
    _ = distance.build(&distance_lengths, false, false) catch unreachable;
    break :blk .{ .literal = literal, .distance = distance };
};

/// Immutable fixed leaves with direct bases and total/code widths for the bounded token prefix.
pub const fixed_payload = blk: {
    @setEvalBranchQuota(10000);
    var result: struct { literal: [512]Entry, distance: [32]Entry } = undefined;
    for (fixed.literal.root, &result.literal) |symbol, *entry| {
        const ordinary = leaf(.literal_length, symbol.value, @intCast(symbol.bits));
        entry.* = .{
            .bits = ordinary.bits + ordinary.extra,
            .extra = @intCast(ordinary.bits),
            .value = ordinary.value,
        };
        if (ordinary.value < 256) {
            entry.literals = 1;
        } else if (ordinary.value == 256) {
            entry.value = 0;
            entry.unused = 1;
        } else if (ordinary.value <= 514) {
            entry.value -= 256;
            entry.unused = @intFromBool(symbol.value == 285);
        }
    }
    for (fixed.distance.root[0..32], &result.distance) |symbol, *entry| {
        const ordinary = leaf(.distance, symbol.value, @intCast(symbol.bits));
        entry.* = .{
            .bits = ordinary.bits + ordinary.extra,
            .extra = @intCast(ordinary.bits),
            .value = ordinary.value,
        };
    }
    break :blk result;
};

/// Selects width-only preparation or tagged literal/length preparation. Width-only preparation
/// preserves bases and token tags; tagged preparation also removes length bias and marks literals
/// and EOB. Only an admitted payload prefix uses these forms; restore before ordinary checked use.
pub const PayloadFormat = enum { tagged, widths };

/// Prepares or restores a table's root and active continuation nodes in place. Alphabet admission
/// selects the matching format; the next stream reconstructs tables after success or failure.
pub fn transformPayloadTable(
    comptime format: PayloadFormat,
    comptime prepare: bool,
    table: anytype,
) void {
    transformPayloadSpan(format, prepare, &table.root);
    const children: []Entry = @ptrCast(table.children[0..table.nodes]);
    transformPayloadSpan(format, prepare, children);
}

/// Prepares or restores leaves in one span. Continuations and zero-width unused entries stay exact.
pub fn transformPayloadSpan(
    comptime format: PayloadFormat,
    comptime prepare: bool,
    entries: []Entry,
) void {
    var index: usize = 0;
    while (entries.len - index >= 8) : (index += 8) {
        const words: @Vector(8, u32) = @bitCast(entries[index..][0..8].*);
        entries[index..][0..8].* = @bitCast(payloadWords(format, prepare, 8, words));
    }
    for (entries[index..]) |*entry| {
        const words: @Vector(1, u32) = @splat(@bitCast(entry.*));
        entry.* = @bitCast(payloadWords(format, prepare, 1, words)[0]);
    }
}

/// Converts packed entry lanes without changing continuation nodes or unused backing.
pub fn payloadWords(
    comptime format: PayloadFormat,
    comptime prepare: bool,
    comptime lanes: usize,
    words: @Vector(lanes, u32),
) @Vector(lanes, u32) {
    const Vector = @Vector(lanes, u32);
    // Entry's low byte is the code width, bits 8..11 the payload width and bit 12 a continuation.
    // Prepared leaves replace those widths with total/code widths, use literal-count bit 13 and
    // spare bit 15 as literal/EOB tags, and remove the length base's 256 bias. Continuations and
    // unused backing retain their format.
    const zero: Vector = @splat(0);
    const bias: Vector = @splat(256);
    const width = words & @as(Vector, @splat(255));
    const populated = width != zero;
    const continuation = (words & @as(Vector, @splat(0x1000))) != zero;
    const leaf_mask = populated & !continuation;
    var value = words >> @as(Vector, @splat(16));
    var encoded: Vector = undefined;
    if (prepare) {
        const payload = (words >> @as(Vector, @splat(8))) & @as(Vector, @splat(15));
        var flags: Vector = @splat(0);
        if (format == .tagged) {
            const literal_mask = value < bias;
            const end_mask = value == bias;
            const length_mask = (value > bias) & (value <= @as(Vector, @splat(514)));
            flags = @select(u32, literal_mask, @as(Vector, @splat(0x2000)), flags);
            flags = @select(u32, end_mask, @as(Vector, @splat(0x8000)), flags);
            value = @select(u32, length_mask, value -% bias, value);
            value = @select(u32, end_mask, zero, value);
        }
        const bases = value << @as(Vector, @splat(16));
        const codes = width << @as(Vector, @splat(8));
        encoded = bases | flags | codes | (width + payload);
    } else {
        const code = (words >> @as(Vector, @splat(8))) & @as(Vector, @splat(15));
        const payload = width -% code;
        if (format == .tagged) {
            const end_mask = (words & @as(Vector, @splat(0x8000))) != zero;
            const literal_mask = (words & @as(Vector, @splat(0x2000))) != zero;
            const length_mask = !end_mask & !literal_mask & (value != @as(Vector, @splat(65535)));
            value = @select(u32, length_mask, value + bias, value);
            value = @select(u32, end_mask, bias, value);
        }
        const bases = value << @as(Vector, @splat(16));
        const payloads = payload << @as(Vector, @splat(8));
        encoded = bases | payloads | code;
    }
    return @select(u32, leaf_mask, encoded, words);
}

/// Consumes one prepared leaf while retaining its original bits for payload extraction. The caller
/// proves whole-token availability. Continuations keep ordinary widths and precede the leaf.
pub fn decodeCombinedPayloadBuffered(table: anytype, bits: *Bits, first: Entry) PayloadLeaf {
    var entry = first;
    const Table = @TypeOf(table.*);
    const expanded = Table == ExpandedLiteralTable or Table == ExpandedWideLiteralTable;
    if (comptime expanded) {
        if (entry.node) {
            bits.drop(entry.bits);
            const mask = (@as(usize, 1) << entry.extra) - 1;
            entry = table.children[entry.value + (@as(usize, @truncate(bits.value)) & mask)];
        }
    } else {
        while (entry.node) {
            bits.drop(entry.bits);
            entry = table.children[entry.value][@as(usize, @truncate(bits.value)) & 1];
        }
    }
    const saved = bits.value;
    bits.drop(entry.bits);
    return .{ .entry = entry, .saved_value = saved };
}

/// Extracts extra payload using a prepared leaf's four-bit code width. Its stored total and code
/// widths bound the saved bits before the code prefix is removed.
pub fn payloadValue(decoded: PayloadLeaf) u16 {
    const mask = (@as(u64, 1) << @as(u6, @intCast(decoded.entry.bits))) - 1;
    return @truncate((decoded.saved_value & mask) >> decoded.entry.extra);
}

/// Extracts a prepared distance payload using its full second-byte code width. Distance leaves
/// carry no literal/EOB tags; tagged literal leaves use the narrower extraction in payloadValue.
pub inline fn distancePayloadValue(decoded: PayloadLeaf) u16 {
    std.debug.assert(
        !decoded.entry.node and decoded.entry.literals == 0 and decoded.entry.unused == 0,
    );
    const word: u32 = @bitCast(decoded.entry);
    const code: u8 = @truncate(word >> 8);
    const mask = (@as(u64, 1) << @as(u6, @intCast(decoded.entry.bits))) - 1;
    return @truncate((decoded.saved_value & mask) >> @as(u6, @intCast(code)));
}

test "complete root lookups preserve every short code and real input boundary" {
    var table: Huffman(7, 19, .symbols) = undefined;
    // A complete canonical chain: 0, 10, 110, ... 1111110, 1111111. Remaining symbols are absent.
    const lengths = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const codes = [_]u8{ 0, 1, 3, 7, 15, 31, 63, 127 };
    try std.testing.expect(try table.build(&lengths, false, false));
    for (0..128) |prefix| {
        for (codes, lengths[0..codes.len], 0..) |code, width, symbol| {
            const mask = (@as(u8, 1) << @as(u3, @intCast(width))) - 1;
            if (prefix & mask != code) continue;
            for (0..8) |available| {
                // No refill bytes exist. High lookahead may select a leaf, but cannot authorize
                // consuming bits beyond the real buffered prefix.
                var bits = Bits{ .source = &.{}, .value = prefix, .count = @intCast(available) };
                const result = table.decode(&bits, .root);
                if (available < width) {
                    try std.testing.expectError(error.InvalidStream, result);
                    try std.testing.expectEqual(available, bits.count);
                } else {
                    try std.testing.expectEqual(symbol, try result);
                    try std.testing.expectEqual(available - width, bits.count);
                    try std.testing.expectEqual(prefix >> @as(u3, @intCast(width)), bits.value);
                }
            }
            break;
        } else unreachable;
    }
}

test "private payload leaf conversion matches independent flags and restores ordinary entries" {
    var entries = [_]Entry{
        .{},
        .{ .bits = 5, .value = 65 },
        .{ .bits = 7, .value = 256 },
        .{ .bits = 6, .extra = 1, .value = 271 },
        .{ .bits = 9, .value = 65535 },
        .{ .bits = 9, .node = true, .value = 3 },
        .{ .bits = 10, .extra = 5, .value = 483 },
        .{ .bits = 1, .value = 0 },
        .{ .bits = 1, .extra = 0, .value = 514 },
    };
    const original = entries;
    transformPayloadSpan(.tagged, true, &entries);
    const expected = [_]Entry{
        .{},
        .{ .bits = 5, .extra = 5, .literals = 1, .value = 65 },
        .{ .bits = 7, .extra = 7, .unused = 1, .value = 0 },
        .{ .bits = 7, .extra = 6, .value = 15 },
        .{ .bits = 9, .extra = 9, .value = 65535 },
        .{ .bits = 9, .node = true, .value = 3 },
        .{ .bits = 15, .extra = 10, .value = 227 },
        .{ .bits = 1, .extra = 1, .literals = 1, .value = 0 },
        .{ .bits = 1, .extra = 1, .value = 258 },
    };
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected), std.mem.asBytes(&entries));
    transformPayloadSpan(.tagged, false, &entries);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&original), std.mem.asBytes(&entries));
    var distances = [_]Entry{
        .{},
        .{ .bits = 10, .extra = 13, .value = 24577 },
        .{ .bits = 9, .value = 0 },
        .{ .bits = 6, .node = true, .value = 2 },
    };
    const ordinary_distances = distances;
    transformPayloadSpan(.widths, true, &distances);
    try std.testing.expectEqual(Entry{ .bits = 23, .extra = 10, .value = 24577 }, distances[1]);
    try std.testing.expectEqual(Entry{ .bits = 9, .extra = 9, .value = 0 }, distances[2]);
    transformPayloadSpan(.widths, false, &distances);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&ordinary_distances),
        std.mem.asBytes(&distances),
    );
}

test "prepared fixed payload leaves match independent RFC1951 canonical values and widths" {
    for (fixed_payload.literal, 0..) |entry, prefix| {
        const code7: u7 = @bitReverse(@as(u7, @truncate(prefix)));
        const code8: u8 = @bitReverse(@as(u8, @truncate(prefix)));
        const code9: u9 = @bitReverse(@as(u9, @intCast(prefix)));
        const symbol: u16 = blk: {
            if (code7 <= 23) break :blk 256 + @as(u16, code7);
            if (code8 >= 0x30 and code8 <= 0xbf) break :blk code8 - 0x30;
            if (code8 >= 0xc0 and code8 <= 0xc7) break :blk 280 + @as(u16, code8 - 0xc0);
            break :blk 144 + @as(u16, code9 - 0x190);
        };
        const width: u8 = blk: {
            if (symbol >= 256 and symbol <= 279) break :blk 7;
            if (symbol >= 144 and symbol <= 255) break :blk 9;
            break :blk 8;
        };
        var extra: u8 = 0;
        var base: u16 = symbol;
        if (symbol >= 257 and symbol <= 285) {
            const index = symbol - 257;
            extra = if (index < 8 or index == 28) 0 else @intCast((index - 4) / 4);
            base = blk: {
                if (index < 8) break :blk 3 + index;
                if (index == 28) break :blk 258;
                const shift: u4 = @intCast(extra);
                break :blk 3 + ((4 + index % 4) << shift);
            };
        } else if (symbol == 256) {
            base = 0;
        } else if (symbol >= 286) {
            base = 65535;
        }
        try std.testing.expectEqual(base, entry.value);
        try std.testing.expectEqual(width + extra, entry.bits);
        try std.testing.expectEqual(@as(u4, @intCast(width)), entry.extra);
        try std.testing.expectEqual(@as(u2, @intFromBool(symbol < 256)), entry.literals);
        try std.testing.expectEqual(
            @as(u1, @intFromBool(symbol == 256 or symbol == 285)),
            entry.unused,
        );
        try std.testing.expect(!entry.node);
    }
    for (fixed_payload.distance, 0..) |entry, prefix| {
        const symbol: u5 = @bitReverse(@as(u5, @intCast(prefix)));
        const extra: u8 = if (symbol < 4 or symbol >= 30) 0 else @as(u8, symbol) / 2 - 1;
        const base: u16 = blk: {
            if (symbol >= 30) break :blk 0;
            if (symbol < 4) break :blk @as(u16, symbol) + 1;
            const shift: u4 = @intCast(extra);
            break :blk 1 + ((2 + @as(u16, symbol & 1)) << shift);
        };
        try std.testing.expectEqual(base, entry.value);
        try std.testing.expectEqual(5 + extra, entry.bits);
        try std.testing.expectEqual(@as(u4, 5), entry.extra);
        try std.testing.expect(!entry.node);
    }
}

test "paired construction reuses scratch for dense fifteen-bit continuations" {
    const fixture = paired_dense;
    const tables = try std.testing.allocator.create(PairedLiteralTable);
    defer std.testing.allocator.destroy(tables);
    try tables.buildPaired(&fixture.literal_lengths);
    try std.testing.expectEqual(fixture.twelve_bit_continuation_nodes, tables.nodes);
}

test "canonical continuation trees reach all fifteen code bits" {
    const tables = try std.testing.allocator.create(LiteralTable);
    defer std.testing.allocator.destroy(tables);
    // Complete canonical tree: lengths 1..14,15,15. Codes are successive leading ones followed by
    // zero; the final symbol has fifteen ones.
    _ = try tables.build(&.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 15 }, false, false);
    for (0..16) |symbol| {
        const length: u4 = @intCast(@min(symbol + 1, 15));
        const wire = if (symbol == 15) 0x7fff else (@as(u16, 1) << (length - 1)) - 1;
        var source: [2]u8 = undefined;
        std.mem.writeInt(u16, &source, wire, .little);
        var bits = Bits{ .source = &source };
        const entry = try tables.decode(&bits, .complete);
        try std.testing.expectEqual(symbol, entry.value);
        try std.testing.expectEqual(16 - @as(u8, length), bits.count);
    }
}

test "maximum-leaf canonical tree fits its bounded continuation storage" {
    // One collapsed primary level leaves fourteen nodes for sixteen leaves. These RFC canonical
    // four-bit codes enumerate symbols 0..15 on the wire.
    const FullTree = Huffman(1, 16, .symbols);
    const allocator = std.testing.allocator;
    const table = try allocator.create(FullTree);
    defer allocator.destroy(table);
    try std.testing.expect(try table.build(&@as([16]u8, @splat(4)), false, false));
    try std.testing.expectEqual(14, table.nodes);
    var bits = Bits{ .source = &.{ 0x80, 0xc4, 0xa2, 0xe6, 0x91, 0xd5, 0xb3, 0xf7 } };
    for (0..16) |symbol| try std.testing.expectEqual(symbol, try table.decode(&bits, .complete));
    try std.testing.expectEqual(8, bits.consumed());
}

test "canonical tables reject oversubscription and invalid incomplete trees" {
    const tables = try std.testing.allocator.create(
        struct { literal: LiteralTable, distance: DistanceTable },
    );
    defer std.testing.allocator.destroy(tables);
    try std.testing.expectError(error.InvalidStream, tables.literal.build(&.{
        1, 1, 1,
    }, false, true));
    try std.testing.expectError(error.InvalidStream, tables.literal.build(&.{ 2, 2 }, false, true));
    try std.testing.expectError(error.InvalidStream, tables.literal.build(&.{16}, false, true));
    _ = try tables.literal.build(&.{1}, false, true);
    _ = try tables.distance.build(&.{0}, true, true);
    var bits = Bits{ .source = &.{0} };
    const invalid = try tables.distance.decode(&bits, .distance);
    try std.testing.expectEqual(0, invalid.value);
    try std.testing.expectEqual(8, bits.count);
}

test "canonical fifteen-bit literal and distance chains retain every prefix and prepared payload" {
    const tables = try std.testing.allocator.create(
        struct { literal: WideLiteralTable, distance: DistanceTable },
    );
    defer std.testing.allocator.destroy(tables);
    // Independent complete canonical chain: lengths 1..14, then two length-15 codes. In wire order,
    // each code is N one bits followed by zero; the last code is fifteen one bits. This tests every
    // replicated primary prefix and each continuation depth without using the constructor's
    // canonical helpers.
    const bases = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97 };
    const extras = [_]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5 };
    inline for (.{ TableKind.literal_length, TableKind.distance }) |kind| {
        const table = if (kind == .literal_length) &tables.literal else &tables.distance;
        var lengths: [if (kind == .literal_length) 286 else 32]u8 = @splat(0);
        for (0..14) |symbol| lengths[symbol] = @intCast(symbol + 1);
        lengths[if (kind == .literal_length) 256 else 29] = 15;
        lengths[if (kind == .literal_length) 284 else 31] = 15;
        try std.testing.expect(try table.build(&lengths, false, false));
        for (0..32768) |prefix| {
            const ordinal: usize = @ctz(~@as(u16, @intCast(prefix)));
            const width: u8 = @intCast(@min(ordinal + 1, 15));
            const value: u16 = blk: {
                if (kind == .literal_length) {
                    if (ordinal < 14) break :blk @intCast(ordinal);
                    break :blk if (ordinal == 14) 256 else 483;
                }
                if (ordinal < 14) break :blk bases[ordinal];
                break :blk if (ordinal == 14) 24577 else 0;
            };
            const extra: u8 = blk: {
                if (kind == .literal_length) break :blk if (ordinal == 15) 5 else 0;
                if (ordinal < 14) break :blk extras[ordinal];
                break :blk if (ordinal == 14) 13 else 0;
            };
            var bits = Bits{ .source = &.{}, .value = prefix, .count = 15 };
            const entry = try table.decode(
                &bits,
                if (kind == .literal_length) .complete else .distance,
            );
            try std.testing.expectEqual(value, entry.value);
            try std.testing.expectEqual(extra, entry.extra);
            try std.testing.expectEqual(15 - width, bits.count);
            try std.testing.expectEqual(@as(u64, prefix) >> @as(u6, @intCast(width)), bits.value);
        }
        const format: PayloadFormat = if (kind == .literal_length) .tagged else .widths;
        transformPayloadTable(format, true, table);
        for (0..32768) |prefix| {
            const ordinal: usize = @ctz(~@as(u16, @intCast(prefix)));
            const width: u8 = @intCast(@min(ordinal + 1, 15));
            const extra: u8 = blk: {
                if (kind == .literal_length) break :blk if (ordinal == 15) 5 else 0;
                if (ordinal < 14) break :blk extras[ordinal];
                break :blk if (ordinal == 14) 13 else 0;
            };
            const wire = @as(u64, prefix) | (@as(u64, 0x1234) << 15) | (@as(u64, 0xa5) << 28);
            var bits = Bits{ .source = &.{}, .value = wire, .count = 63 };
            const decoded = decodeCombinedPayloadBuffered(
                table,
                &bits,
                table.root[prefix & (table.root.len - 1)],
            );
            const value: u16 = blk: {
                if (kind == .literal_length) {
                    if (ordinal < 14) break :blk @intCast(ordinal);
                    break :blk if (ordinal == 14) 0 else 227;
                }
                if (ordinal < 14) break :blk bases[ordinal];
                break :blk if (ordinal == 14) 24577 else 0;
            };
            try std.testing.expectEqual(value, decoded.entry.value);
            if (kind == .literal_length) {
                try std.testing.expectEqual(@intFromBool(ordinal < 14), decoded.entry.literals);
                try std.testing.expectEqual(@intFromBool(ordinal == 14), decoded.entry.unused);
            }
            const mask = (@as(u64, 1) << @as(u6, @intCast(extra))) - 1;
            const expected_payload: u16 = @intCast((wire >> @as(u6, @intCast(width))) & mask);
            try std.testing.expectEqual(expected_payload, payloadValue(decoded));
            if (kind == .distance) {
                try std.testing.expectEqual(expected_payload, distancePayloadValue(decoded));
            }
            try std.testing.expectEqual(63 - width - extra, bits.count);
            try std.testing.expectEqual(wire >> @as(u6, @intCast(width + extra)), bits.value);
        }
        transformPayloadTable(format, false, table);
    }
}

fn checkCommonTable(
    table: []const u32,
    root_bits: u8,
    lengths: []const u8,
    comptime distances: bool,
) !void {
    var counts: [16]u32 = @splat(0);
    for (lengths) |width| counts[width] += 1;
    var code: u32 = 0;
    for (1..16) |width| {
        code = (code + if (width == 1) 0 else counts[width - 1]) * 2;
        for (lengths, 0..) |actual_width, symbol| {
            if (actual_width != width) continue;
            const reversed = @bitReverse(@as(u16, @intCast(code))) >> @as(u4, @intCast(16 - width));
            code += 1;
            const extra: u8 = blk: {
                if (distances) break :blk if (symbol < 4) 0 else @intCast(symbol / 2 - 1);
                if (symbol < 265 or symbol == 285) break :blk 0;
                break :blk @intCast((symbol - 265) / 4 + 1);
            };
            const base: u32 = blk: {
                if (distances) {
                    if (symbol < 4) break :blk @intCast(symbol + 1);
                    const group = @as(u32, 1) << @as(u5, @intCast(extra + 1));
                    const side = @as(u32, @intCast(symbol & 1)) << @as(u5, @intCast(extra));
                    break :blk group + 1 + side;
                }
                if (symbol < 257) break :blk @intCast(symbol);
                if (symbol < 265) break :blk @intCast(symbol - 254);
                if (symbol == 285) break :blk 258;
                const group = @as(u32, 1) << @as(u5, @intCast(extra + 2));
                const offset = @as(u32, @intCast((symbol - 265) % 4)) << @as(u5, @intCast(extra));
                break :blk group + 3 + offset;
            };
            for (0..@as(usize, 1) << @as(IndexShift, @intCast(extra))) |payload| {
                const payload_bits = @as(u64, @intCast(payload)) << @as(u6, @intCast(width));
                const following = @as(u64, 0xd7a9) << @as(u6, @intCast(width + extra));
                const lookahead: u64 = reversed | payload_bits | following;
                const root_mask = (@as(usize, 1) << @as(IndexShift, @intCast(root_bits))) - 1;
                var value = table[@as(usize, @truncate(lookahead)) & root_mask];
                var consumed: u8 = 0;
                if (value & 0x4000 != 0) {
                    try std.testing.expect(value & 0x8000 != 0);
                    consumed = @truncate(value);
                    try std.testing.expectEqual(root_bits, consumed);
                    const suffix_bits: u8 = @intCast((value >> 8) & 63);
                    const suffix_mask = (@as(
                        usize,
                        1,
                    ) << @as(IndexShift, @intCast(suffix_bits))) - 1;
                    const suffix: usize = @truncate(lookahead >> @as(u6, @intCast(root_bits)));
                    const index = (value >> 16) + (suffix & suffix_mask);
                    try std.testing.expect(index < table.len);
                    value = table[index];
                }
                consumed += @as(u8, @truncate(value));
                try std.testing.expectEqual(@as(u8, @intCast(width)) + extra, consumed);
                if (!distances and symbol < 256) {
                    try std.testing.expectEqual(
                        @as(u32, 0x80000000),
                        value & 0xffff0000 & 0x80000000,
                    );
                    try std.testing.expectEqual(base, (value >> 16) & 255);
                } else if (!distances and symbol == 256) {
                    try std.testing.expectEqual(@as(u32, 0xa000), value & 0xe000);
                } else {
                    try std.testing.expectEqual(@as(u32, 0), value & 0xe000);
                    try std.testing.expectEqual(base, value >> 16);
                    const code_bits: u8 = @intCast((value >> 8) & 255);
                    try std.testing.expectEqual(
                        @as(u8, @intCast(width)),
                        code_bits + consumed - @as(u8, @truncate(value)),
                    );
                    const mask = (@as(u64, 1) << @as(u6, @intCast(extra))) - 1;
                    const extracted = (lookahead >> @as(u6, @intCast(width))) & mask;
                    try std.testing.expectEqual(
                        base + @as(u32, @intCast(payload)),
                        (value >> 16) + @as(u32, @intCast(extracted)),
                    );
                }
            }
        }
        // The next length starts after all codes of this width, not after a second count addition:
        // code already includes the symbols above.
        if (width < 15) code -= counts[width];
    }
}

fn completeCommonLengths(lengths: []u8, seed: u32) void {
    @memset(lengths, 0);
    lengths[0] = 1;
    lengths[1] = 1;
    var state = seed;
    var used: usize = 2;
    while (used < lengths.len) : (used += 1) {
        var choice: usize = 0;
        if (seed == 0) {
            for (lengths[0..used], 0..) |width, index| {
                if (width < lengths[choice]) choice = index;
            }
        } else if (used < 16) {
            choice = used - 1;
        } else {
            state = state *% 1664525 +% 1013904223;
            choice = state % used;
            while (lengths[choice] == 15) choice = (choice + 1) % used;
        }
        const child = lengths[choice] + 1;
        lengths[choice] = child;
        lengths[used] = child;
    }
}

fn commonPackedAt(table: []const u32, root_bits: u8, lookahead: u64) !u64 {
    const mask = (@as(usize, 1) << @as(IndexShift, @intCast(root_bits))) - 1;
    var value = table[@as(usize, @truncate(lookahead)) & mask];
    var consumed: u8 = 0;
    if (value & 0x4000 != 0) {
        consumed = @truncate(value);
        try std.testing.expectEqual(root_bits, consumed);
        const suffix: u8 = @intCast((value >> 8) & 63);
        const suffix_mask = (@as(usize, 1) << @as(IndexShift, @intCast(suffix))) - 1;
        const following: usize = @truncate(lookahead >> @as(u6, @intCast(root_bits)));
        const index = (value >> 16) + (following & suffix_mask);
        try std.testing.expect(index < table.len);
        value = table[index];
    }
    return (@as(u64, consumed) << 32) | value;
}

fn checkCommonCoverage(
    expected: []u64,
    table: []const u32,
    root_bits: u8,
    lengths: []const u8,
    comptime distances: bool,
) !void {
    @memset(expected, std.math.maxInt(u64));
    var counts: [16]u32 = @splat(0);
    for (lengths) |width| counts[width] += 1;
    var start: u32 = 0;
    var previous: u32 = 0;
    for (1..16) |width| {
        start = (start + previous) * 2;
        var code = start;
        for (lengths, 0..) |actual, symbol| {
            if (actual != width) continue;
            const reversed = @bitReverse(@as(u16, @intCast(code))) >> @as(u4, @intCast(16 - width));
            code += 1;
            const extra: u8 = blk: {
                if (distances) break :blk if (symbol < 4) 0 else @intCast(symbol / 2 - 1);
                if (symbol < 265 or symbol == 285) break :blk 0;
                break :blk @intCast((symbol - 265) / 4 + 1);
            };
            const anchor = try commonPackedAt(
                table,
                root_bits,
                reversed | (@as(u64, 0xd7a9) << @as(u6, @intCast(width + extra))),
            );
            const stride = @as(usize, 1) << @as(IndexShift, @intCast(width));
            var index: usize = reversed;
            while (index < expected.len) : (index += stride) {
                try std.testing.expectEqual(std.math.maxInt(u64), expected[index]);
                expected[index] = anchor;
            }
        }
        previous = counts[width];
    }
    for (expected, 0..) |value, lookahead| {
        try std.testing.expect(value != std.math.maxInt(u64));
        try std.testing.expectEqual(
            value,
            try commonPackedAt(table, root_bits, lookahead | (@as(u64, 0xc3) << 15)),
        );
    }
}

test "common packed tables preserve canonical symbols payloads and storage bounds" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(CommonTables);
    defer allocator.destroy(tables);
    var lengths: [286]u8 = undefined;
    var distances: [32]u8 = @splat(0);
    for (0..17) |seed| {
        completeCommonLengths(&lengths, @intCast(seed));
        completeCommonLengths(distances[0..30], @intCast(seed));
        try std.testing.expect(try tables.build(&lengths, &distances));
        try std.testing.expect(tables.literal_used <= tables.literal.len);
        try std.testing.expect(tables.distance_used <= tables.distance.len);
        try checkCommonTable(
            tables.literal[0..tables.literal_used],
            tables.literal_bits,
            &lengths,
            false,
        );
        try checkCommonTable(tables.distance[0..tables.distance_used], 8, &distances, true);
    }
    @memset(&lengths, 0);
    lengths[0] = 1;
    lengths[256] = 2;
    lengths[257] = 2;
    distances = @splat(0);
    distances[0] = 1;
    distances[1] = 1;
    try std.testing.expect(try tables.build(&lengths, &distances));
    try std.testing.expectEqual(@as(u8, 2), tables.literal_bits);
    try checkCommonTable(
        tables.literal[0..tables.literal_used],
        tables.literal_bits,
        &lengths,
        false,
    );
    try checkCommonTable(tables.distance[0..tables.distance_used], 8, &distances, true);
}

test "common packed admission preserves strict incomplete and reserved fallbacks" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(CommonTables);
    defer allocator.destroy(tables);
    @memset(std.mem.asBytes(tables), 0x5a);
    const untouched = std.hash.Wyhash.hash(0, std.mem.asBytes(tables));
    var lengths: [286]u8 = @splat(0);
    lengths[0] = 1;
    lengths[256] = 2;
    lengths[257] = 2;
    try std.testing.expect(!try tables.build(&lengths, &.{ 0, 0 }));
    try std.testing.expect(!try tables.build(&lengths, &.{ 1, 0 }));
    var reserved: [32]u8 = @splat(5);
    try std.testing.expect(!try tables.build(&lengths, &reserved));
    reserved[0] = 16;
    try std.testing.expectError(error.InvalidStream, tables.build(&lengths, &reserved));
    try std.testing.expectError(error.InvalidStream, tables.build(&lengths, &.{ 1, 1, 1 }));
    try std.testing.expectError(error.InvalidStream, tables.build(&lengths, &.{ 2, 2 }));
    @memset(&lengths, 0);
    lengths[256] = 1;
    try std.testing.expect(!try tables.build(&lengths, &.{ 1, 1 }));
    lengths[256] = 0;
    try std.testing.expectError(error.InvalidStream, tables.build(&lengths, &.{ 1, 1 }));
    try std.testing.expectEqual(untouched, std.hash.Wyhash.hash(0, std.mem.asBytes(tables)));
}

test "common packed secondary capacity refusal stays inside supplied backing" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(CommonTables);
    defer allocator.destroy(tables);
    var lengths: [286]u8 = undefined;
    completeCommonLengths(&lengths, 1);
    const counts = try LiteralTable.countCodes(&lengths, false, false);
    const backing = try allocator.alloc(u32, 2048 + 16);
    defer allocator.free(backing);
    @memset(backing, 0xfaceb00c);
    try std.testing.expect(
        tables.buildFlat(
            backing[8..][0..2048],
            &lengths,
            counts.counts,
            .literal_length,
            11,
            true,
        ) == null,
    );
    for (backing[0..8]) |word| try std.testing.expectEqual(@as(u32, 0xfaceb00c), word);
    for (backing[2056..]) |word| try std.testing.expectEqual(@as(u32, 0xfaceb00c), word);
    // Reusing the same constructor scratch after a refusal reconstructs a full book.
    try std.testing.expect(try tables.build(&lengths, &.{ 1, 1 }));
    try checkCommonTable(
        tables.literal[0..tables.literal_used],
        tables.literal_bits,
        &lengths,
        false,
    );
}

test "common packed exhaustive lookahead covers every replicated leaf" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(CommonTables);
    defer allocator.destroy(tables);
    const expected = try allocator.alloc(u64, 32768);
    defer allocator.free(expected);
    var lengths: [286]u8 = undefined;
    var distances: [30]u8 = undefined;
    for (0..17) |seed| {
        completeCommonLengths(&lengths, @intCast(seed));
        completeCommonLengths(&distances, @intCast(seed));
        try std.testing.expect(try tables.build(&lengths, &distances));
        try checkCommonCoverage(
            expected,
            tables.literal[0..tables.literal_used],
            tables.literal_bits,
            &lengths,
            false,
        );
        try checkCommonCoverage(
            expected,
            tables.distance[0..tables.distance_used],
            8,
            &distances,
            true,
        );
    }
}
