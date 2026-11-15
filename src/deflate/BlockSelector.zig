//! A token sequence can be stored directly or encoded with fixed or dynamic Huffman codes. Compare
//! their complete wire costs, including headers and stored-block alignment. Bounded lower-cost
//! proofs can establish small-block winners without constructing dynamic codebooks.
//!
//! Selection constructs dynamic price books even when stored/fixed wins, supplying the next offline
//! parse prices. Callers snapshot those prices before reusing header storage.

const std = @import("std");
const protocol = @import("format.zig");
const Token = @import("Lz77Parser.zig").Token;
const HuffmanCodebook = @import("HuffmanCodebook.zig");
const DynamicBlockHeader = @import("DynamicBlockHeader.zig");
const EncodeWorkBudget = @import("EncodeWorkBudget.zig");
const length_extra = protocol.length_extra;
const distance_extra = protocol.distance_extra;
const lengthSlot = protocol.lengthSlot;
const distanceSlot = protocol.distanceSlot;
const fixedWidth = HuffmanCodebook.fixedWidth;
const test_encoding = @import("encode.zig");
const borrows = @import("block_borrows.zig");
const Encoder = test_encoding.StreamEncoder;
const EncoderWorkspace = @import("EncodeWorkspace.zig");
const EncodeStatus = test_encoding.Status;
const encode = test_encoding.into;
const distance_base = protocol.distance_base;
const BlockSelector = @This();

pub const Kind = enum { stored, fixed, dynamic };

pub const Selection = struct {
    /// Wire bits for this block, including any stored-block alignment padding.
    bits: u32,
    /// Winning representation; equal costs retain stored before fixed before dynamic.
    kind: Kind,
    /// Constructed dynamic candidate cost even when another kind wins, used for refinement
    /// stopping. Zero when a proof skips dynamic construction.
    dynamic_bits: u32 = 0,
};

pub const Segment = struct {
    /// First token index, inclusive.
    first: usize,
    /// End token index, exclusive.
    end: usize,
    /// Source-byte offset from the slab's beginning.
    start: usize,
    /// Source bytes covered by these tokens.
    bytes: usize,
};

/// Candidate payload books and dynamic header; selection leaves these ready for reuse.
header: *DynamicBlockHeader,
/// Separate code-length repricing trial.
header_trial: *DynamicBlockHeader,
/// Shared codebook-construction scratch, dead between sequential book builds.
huffman: *HuffmanCodebook.Scratch,
/// Best token sequence retained by the block orchestrator; splitting only reads it.
best: []Token,
/// Writable bounded partition list; at least sixteen entries for the four-level split tree.
segments: []Segment,
/// Shared work counter. Proofs can skip book/header charges only when they establish the winner.
work: EncodeWorkBudget,
pub fn split(
    self: BlockSelector,
    first: usize,
    end: usize,
    start: usize,
    bytes: usize,
    offset: u6,
    depth: usize,
    slot: usize,
) EncodeWorkBudget.Error!usize {
    self.segments[slot] = .{ .first = first, .end = end, .start = start, .bytes = bytes };
    if (depth == 4 or bytes < 4096 or end - first < 2) return slot + 1;
    const whole = try self.select(self.best[first..end], bytes, offset);
    var middle = first;
    var left_bytes: usize = 0;
    while (middle + 1 < end and left_bytes < bytes / 2) : (middle += 1) {
        left_bytes += @max(1, self.best[middle].length);
    }
    if (middle == first or middle == end) return slot + 1;
    const left = try self.select(self.best[first..middle], left_bytes, offset);
    const right_offset: u6 = @intCast((offset + @as(u32, left.bits)) % 8);
    const right = try self.select(self.best[middle..end], bytes - left_bytes, right_offset);
    if (left.bits + right.bits >= whole.bits) return slot + 1;
    const next = try self.split(first, middle, start, left_bytes, offset, depth + 1, slot);
    // Child splits may alter alignment; recompute their exact cost.
    var next_offset = offset;
    for (self.segments[slot..next]) |segment| {
        const choice = try self.select(
            self.best[segment.first..segment.end],
            segment.bytes,
            next_offset,
        );
        next_offset = @intCast((next_offset + @as(u32, choice.bits)) % 8);
    }
    return self.split(
        middle,
        end,
        start + left_bytes,
        bytes - left_bytes,
        next_offset,
        depth + 1,
        next,
    );
}

// A dynamic header needs at least 44 bits: 29 for block/count/precode lengths and at least 15 to
// describe 258 code widths, even if every eight-bit run covers 138 widths.
/// Proves a stored/fixed choice for at most eight tokens, or returns null when full selection is
/// needed. A proved winner charges token/end-symbol work without constructing dynamic books.
pub fn selectProvablySmall(
    self: BlockSelector,
    tokens: []const Token,
    bytes: usize,
    offset: u6,
) EncodeWorkBudget.Error!?Selection {
    var fixed_bits: u32 = 3 + fixedWidth(256);
    var dynamic_lower: u32 = 44 + 1;
    var symbols: [9]u16 = undefined;
    var frequencies: [9]u8 = @splat(0);
    symbols[0] = 256;
    frequencies[0] = 1;
    var distinct: usize = 1;
    var maximum: u8 = 1;
    for (tokens) |token| {
        dynamic_lower += 1;
        const symbol: u16 = if (token.length == 0) token.value else blk: {
            const length = lengthSlot(token.length);
            const distance = distanceSlot(token.value);
            const extra: u32 = @as(u32, length_extra[length]) + distance_extra[distance];
            fixed_bits += 5 + extra;
            dynamic_lower += 1 + extra;
            break :blk 257 + @as(u16, length);
        };
        fixed_bits += fixedWidth(symbol);
        var index: usize = 0;
        while (index < distinct and symbols[index] != symbol) : (index += 1) {}
        if (index == distinct) {
            symbols[index] = symbol;
            distinct += 1;
        }
        frequencies[index] += 1;
        maximum = @max(maximum, frequencies[index]);
    }
    // With at least three used symbols, only one can have a one-bit code.
    if (distinct >= 3) dynamic_lower += @intCast(tokens.len + 1 - maximum);
    const padding = (8 - (@as(u32, offset) + 3) % 8) % 8;
    const stored_bits: u32 = @intCast(3 + padding + 32 + bytes * 8);
    var best: Selection = .{ .bits = stored_bits, .kind = .stored };
    if (fixed_bits < best.bits) best = .{ .bits = fixed_bits, .kind = .fixed };
    if (best.bits > dynamic_lower) return null;
    try self.work.admit(tokens.len + 1);
    return best;
}

pub fn select(
    self: BlockSelector,
    tokens: []const Token,
    bytes: usize,
    offset: u6,
) EncodeWorkBudget.Error!Selection {
    var literal_frequencies: [286]u32 = @splat(0);
    var distance_frequencies: [30]u32 = @splat(0);
    literal_frequencies[256] = 1;
    var extra_bits: u32 = 0;
    for (tokens) |token| {
        if (token.length == 0) {
            literal_frequencies[token.value] += 1;
        } else {
            const length_slot = lengthSlot(token.length);
            const distance_slot = distanceSlot(token.value);
            literal_frequencies[257 + @as(usize, length_slot)] += 1;
            distance_frequencies[distance_slot] += 1;
            extra_bits += @as(u32, length_extra[length_slot]) + distance_extra[distance_slot];
        }
    }
    const header = self.header;
    try header.literal.build(&literal_frequencies, 15, self.huffman, self.work);
    try header.distance.build(&distance_frequencies, 15, self.huffman, self.work);
    try header.build(self.header_trial, self.huffman, self.work);
    var dynamic_bits: u32 = 3 + header.bits + extra_bits;
    var fixed_bits: u32 = 3 + extra_bits;
    for (literal_frequencies, 0..) |frequency, symbol| {
        dynamic_bits += frequency * header.literal.widths[symbol];
        fixed_bits += frequency * fixedWidth(symbol);
    }
    for (distance_frequencies, 0..) |frequency, symbol| {
        dynamic_bits += frequency * header.distance.widths[symbol];
        fixed_bits += frequency * 5;
    }
    const padding = (8 - (@as(u32, offset) + 3) % 8) % 8;
    const stored_bits: u32 = @intCast(3 + padding + 32 + bytes * 8);
    var best: Selection = .{ .bits = stored_bits, .kind = .stored };
    if (fixed_bits < best.bits) best = .{ .bits = fixed_bits, .kind = .fixed };
    if (dynamic_bits < best.bits) best = .{ .bits = dynamic_bits, .kind = .dynamic };
    best.dynamic_bits = dynamic_bits;
    try self.work.admit(tokens.len + 1);
    return best;
}

// The header must contain the block and counts plus at least four precode widths: 29 bits. Each
// nonzero-width run needs at least one precode symbol, with repeats covering at most six entries.
// The zero-run table gives an optimistic cost even at the literal/distance boundary. Unrestricted
// Huffman merging also bounds the length-limited literal payload from below.
const SmallHuffmanBound = struct {
    /// Cheaper stored/fixed choice, retaining stored on equal cost.
    best: Selection,
    /// Lower bound on any dynamic representation, in wire bits.
    lower: u32,
};

/// Compares stored/fixed costs with an optimistic dynamic lower bound for at most 64 tokens. A null
/// result requests ordinary selection. This proof does not charge work; its caller admits the
/// selected token/end-symbol work when the bound establishes a winner.
// Keep this bounded proof out of the common large-block path.
pub noinline fn smallHuffmanBound(
    tokens: []const Token,
    bytes: usize,
    offset: u6,
) ?SmallHuffmanBound {
    if (tokens.len > 32) {
        var present: [5]u64 = @splat(0);
        present[4] = 1; // End-of-block symbol.
        for (tokens) |token| {
            const symbol: u16 = if (token.length == 0) token.value else blk: {
                const length = lengthSlot(token.length);
                break :blk 257 + @as(u16, length);
            };
            present[symbol / 64] |= @as(u64, 1) << @as(u6, @intCast(symbol % 64));
        }
        var distinct: usize = 0;
        for (present) |bits| distinct += @popCount(bits);
        // A small alphabet is unlikely to repay this proof; ordinary selection remains exact.
        if (distinct <= 17) return null;
    }
    var fixed_bits: u32 = 3 + fixedWidth(256);
    var dynamic_lower: u32 = 29;
    var symbols: [65]u16 = undefined;
    var frequencies: [65]u32 = @splat(0);
    symbols[0] = 256;
    frequencies[0] = 1;
    var distinct: usize = 1;
    for (tokens) |token| {
        const symbol: u16 = if (token.length == 0) token.value else blk: {
            const length = lengthSlot(token.length);
            const distance = distanceSlot(token.value);
            const extra: u32 = @as(u32, length_extra[length]) + distance_extra[distance];
            fixed_bits += 5 + extra;
            dynamic_lower += 1 + extra;
            break :blk 257 + @as(u16, length);
        };
        fixed_bits += fixedWidth(symbol);
        var index: usize = 0;
        while (index < distinct and symbols[index] != symbol) : (index += 1) {}
        if (index == distinct) {
            symbols[index] = symbol;
            distinct += 1;
        }
        frequencies[index] += 1;
    }
    const padding = (8 - (@as(u32, offset) + 3) % 8) % 8;
    const stored_bits: u32 = @intCast(3 + padding + 32 + bytes * 8);
    var best: Selection = .{ .bits = stored_bits, .kind = .stored };
    if (fixed_bits < best.bits) best = .{ .bits = fixed_bits, .kind = .fixed };
    // Optimistic costs for zero-width runs, allowing each repeat to cover fewer entries than its
    // actual minimum and assigning every precode a one-bit code.
    const zero_cost = comptime blk: {
        var costs: [287]u16 = @splat(0);
        for (1..costs.len) |n| {
            costs[n] = @min(
                costs[n - 1] + 1,
                @min(costs[n -| 6] + 3, @min(costs[n -| 10] + 4, costs[n -| 138] + 8)),
            );
        }
        break :blk costs;
    };
    for (1..distinct) |i| {
        const symbol = symbols[i];
        var j = i;
        while (j != 0 and symbols[j - 1] > symbol) : (j -= 1) {
            symbols[j] = symbols[j - 1];
        }
        symbols[j] = symbol;
    }
    var previous: usize = 0;
    var run: usize = 0;
    for (symbols[0..distinct]) |symbol| {
        const gap = @as(usize, symbol) - previous;
        if (gap != 0) {
            if (run != 0) {
                const remaining = run - 1;
                dynamic_lower += @intCast(1 + 3 * (remaining / 6) + @min(remaining % 6, 3));
                run = 0;
            }
            dynamic_lower += zero_cost[gap];
        }
        run += 1;
        previous = @as(usize, symbol) + 1;
    }
    if (run != 0) {
        const remaining = run - 1;
        dynamic_lower += @intCast(1 + 3 * (remaining / 6) + @min(remaining % 6, 3));
    }
    dynamic_lower += smallHuffmanCost(frequencies[0..distinct]);
    if (dynamic_lower < best.bits) {
        // The first bound assumes every distance symbol costs one bit. If that is inconclusive,
        // unrestricted merging gives a stronger distance cost.
        var distance_freq: [30]u32 = @splat(0);
        var matches: u32 = 0;
        for (tokens) |token| if (token.length != 0) {
            distance_freq[distanceSlot(token.value)] += 1;
            matches += 1;
        };
        dynamic_lower += smallHuffmanCost(&distance_freq) - matches;
    }
    return .{ .best = best, .lower = dynamic_lower };
}

// Frequencies sum to at most 65, including the end symbol. A bounded histogram can therefore merge
// the two smallest weights without a general-purpose heap.
pub fn smallHuffmanCost(frequencies: []const u32) u32 {
    var buckets: [66]u8 = @splat(0);
    var count: usize = 0;
    var total: u32 = 0;
    for (frequencies) |frequency| if (frequency != 0) {
        buckets[frequency] += 1;
        total += frequency;
        count += 1;
    };
    if (count <= 1) return total;
    var least: usize = 1;
    var cost: u32 = 0;
    while (count > 1) : (count -= 1) {
        while (buckets[least] == 0) : (least += 1) {}
        buckets[least] -= 1;
        const first = least;
        while (buckets[least] == 0) : (least += 1) {}
        buckets[least] -= 1;
        const merged = first + least;
        buckets[merged] += 1;
        cost += @intCast(merged);
    }
    return cost;
}

test "serialized choices include every header run padding and token bit" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var tokens: [512]Token = undefined;
    @memset(workspace.data[0..512], 65);
    inline for (.{ Kind.stored, Kind.fixed, Kind.dynamic }) |kind| {
        const count: usize = if (kind == .fixed) 1 else tokens.len;
        for (tokens[0..count], 0..) |*token, i| {
            token.* = .{ .length = 0, .value = if (kind == .stored) @intCast(i % 256) else 65 };
        }
        for (0..8) |offset| {
            try encoder.reset(workspace, .{});
            encoder.bit_count = @intCast(offset);
            const chosen = try borrows.selector(
                &encoder,
            ).select(tokens[0..count], count, @intCast(offset));
            try std.testing.expectEqual(kind, chosen.kind);
            try borrows.writer(
                &encoder,
            ).emit(
                &encoder.workspace.header,
                tokens[0..count],
                .{ .first = 0, .end = count, .start = 0, .bytes = count },
                chosen.kind,
                true,
            );
            const actual = encoder.pending * 8 + encoder.bit_count - offset;
            try std.testing.expectEqual(chosen.bits, actual);
        }
    }
}

test "frequency selection equals direct token bit accounting" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var tokens: [512]Token = undefined;
    for (0..6) |pattern| {
        for (&tokens, 0..) |*token, i| {
            if ((i + pattern) % 4 == 0) {
                token.* = .{ .length = 0, .value = @intCast((i * 13 + pattern * 29) % 256) };
            } else {
                token.* = .{
                    .length = @intCast(3 + (i * 67 + pattern * 43) % 256),
                    .value = @intCast(1 + (i * 1877 + pattern * 6571) % 32768),
                };
            }
        }
        for ([_]usize{ 0, 1, 7, 64, 257, 512 }) |size| {
            const selected = tokens[0..size];
            var bytes: usize = 0;
            for (selected) |token| bytes += @max(1, token.length);
            try std.testing.expect(bytes <= 65535);
            for (0..8) |bit_offset| {
                try encoder.reset(workspace, .{});
                const actual = try borrows.selector(
                    &encoder,
                ).select(selected, bytes, @intCast(bit_offset));
                const full_work = encoder.counts().work_units;
                const header = &workspace.header;
                var dynamic: u32 = 3 + header.bits + header.literal.widths[256];
                var fixed: u32 = 3 + 7;
                // Calculate directly from every token instead of multiplying frequencies.
                for (selected) |token| {
                    if (token.length == 0) {
                        dynamic += header.literal.widths[token.value];
                        fixed += fixedWidth(token.value);
                    } else {
                        const l = lengthSlot(token.length);
                        const d = distanceSlot(token.value);
                        const symbol = 257 + @as(usize, l);
                        const extras = @as(u32, length_extra[l]) + distance_extra[d];
                        dynamic += header.literal.widths[symbol] + @as(
                            u32,
                            header.distance.widths[d],
                        ) + extras;
                        fixed += fixedWidth(symbol) + @as(u32, 5) + extras;
                    }
                }
                const padding = (8 - (@as(u32, @intCast(bit_offset)) + 3) % 8) % 8;
                const stored: u32 = @intCast(3 + padding + 32 + bytes * 8);
                var expected: Selection = .{
                    .bits = stored,
                    .kind = .stored,
                    .dynamic_bits = dynamic,
                };
                if (fixed < expected.bits) expected = .{
                    .bits = fixed,
                    .kind = .fixed,
                    .dynamic_bits = dynamic,
                };
                if (dynamic < expected.bits) expected = .{
                    .bits = dynamic,
                    .kind = .dynamic,
                    .dynamic_bits = dynamic,
                };
                try std.testing.expectEqual(expected, actual);
                try std.testing.expect(full_work > 0);
                for ([_]u64{ full_work - 1, full_work }) |budget| {
                    try encoder.reset(workspace, .{ .limits = .{ .work_units = budget } });
                    const limited = borrows.selector(
                        &encoder,
                    ).select(selected, bytes, @intCast(bit_offset));
                    if (budget == full_work) {
                        try std.testing.expectEqual(expected, try limited);
                        try std.testing.expectEqual(full_work, encoder.counts().work_units);
                    } else {
                        try std.testing.expectError(error.LimitExceeded, limited);
                        try std.testing.expect(encoder.counts().work_units <= budget);
                    }
                }
            }
        }
    }
}

test "proven small block selection agrees with complete dynamic pricing" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    const alphabet = [_]Token{
        .{ .length = 0, .value = 0 },
        .{ .length = 0, .value = 127 },
        .{ .length = 0, .value = 255 },
        .{ .length = 3, .value = 1 },
        .{ .length = 258, .value = 32768 },
    };
    var checked: usize = 0;
    var skipped: usize = 0;
    for (0..6) |len| {
        var combinations: usize = 1;
        for (0..len) |_| combinations *= alphabet.len;
        for (0..combinations) |encoded| {
            var digits = encoded;
            var tokens: [8]Token = undefined;
            var bytes: usize = 0;
            for (tokens[0..len]) |*token| {
                token.* = alphabet[digits % alphabet.len];
                digits /= alphabet.len;
                bytes += @max(1, token.length);
            }
            for (0..8) |offset| {
                try encoder.reset(workspace, .{});
                const proposed = try borrows.selector(
                    &encoder,
                ).selectProvablySmall(tokens[0..len], bytes, @intCast(offset));
                if (proposed) |choice| {
                    skipped += 1;
                    try std.testing.expectEqual(
                        @as(u64, @intCast(len + 1)),
                        encoder.stats.work_units,
                    );
                    try encoder.reset(workspace, .{});
                    const complete = try borrows.selector(
                        &encoder,
                    ).select(tokens[0..len], bytes, @intCast(offset));
                    try std.testing.expectEqual(complete.kind, choice.kind);
                    try std.testing.expectEqual(complete.bits, choice.bits);
                    try encoder.reset(workspace, .{ .limits = .{ .work_units = len } });
                    try std.testing.expectError(
                        error.LimitExceeded,
                        borrows.selector(
                            &encoder,
                        ).selectProvablySmall(tokens[0..len], bytes, @intCast(offset)),
                    );
                    try std.testing.expectEqual(@as(u64, 0), encoder.stats.work_units);
                    try encoder.reset(workspace, .{ .limits = .{ .work_units = len + 1 } });
                    const exact = (try borrows.selector(
                        &encoder,
                    ).selectProvablySmall(tokens[0..len], bytes, @intCast(offset))).?;
                    try std.testing.expectEqual(choice.kind, exact.kind);
                    try std.testing.expectEqual(choice.bits, exact.bits);
                }
                checked += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 31248), checked);
    try std.testing.expect(skipped > 1000);
}

test "small block bound falls back for six through eight tokens" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    const alphabet = [_]Token{
        .{ .length = 0, .value = 0 },
        .{ .length = 0, .value = 127 },
        .{ .length = 0, .value = 144 },
        .{ .length = 0, .value = 255 },
        .{ .length = 3, .value = 1 },
        .{ .length = 10, .value = 4 },
        .{ .length = 11, .value = 5 },
        .{ .length = 258, .value = 32768 },
    };
    var random: std.Random.DefaultPrng = .init(0xd3f1a7e);
    for (6..9) |len| {
        for (0..3000) |case| {
            var tokens: [8]Token = undefined;
            var bytes: usize = 0;
            for (tokens[0..len]) |*token| {
                token.* = alphabet[
                    if (case < alphabet.len) case else random.random().uintLessThan(
                        usize,
                        alphabet.len,
                    )
                ];
                bytes += @max(1, token.length);
            }
            for (0..8) |offset| {
                try encoder.reset(workspace, .{});
                try std.testing.expectEqual(
                    null,
                    try borrows.selector(
                        &encoder,
                    ).selectProvablySmall(tokens[0..len], bytes, @intCast(offset)),
                );
            }
        }
    }
}

test "small block bound accepts equality without changing fixed selection" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    const tokens = [_]Token{
        .{ .length = 0, .value = 0 },
        .{ .length = 3, .value = 1 },
        .{ .length = 3, .value = 1 },
        .{ .length = 3, .value = 1 },
    };
    for (0..8) |offset| {
        try encoder.reset(workspace, .{});
        const chosen = (try borrows.selector(
            &encoder,
        ).selectProvablySmall(&tokens, 10, @intCast(offset))).?;
        try std.testing.expectEqual(Kind.fixed, chosen.kind);
        // Independent bound: 44 header + (2*5-3) literal/length + 3 distance bits.
        try std.testing.expectEqual(@as(u32, 54), chosen.bits);
        try encoder.reset(workspace, .{});
        const complete = try borrows.selector(&encoder).select(&tokens, 10, @intCast(offset));
        try std.testing.expectEqual(complete.kind, chosen.kind);
        try std.testing.expectEqual(complete.bits, chosen.bits);
    }
}

test "small block proof preserves bounded work and overflow state" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    const tokens = [_]Token{.{ .length = 0, .value = 42 }};
    try encoder.reset(workspace, .{});
    encoder.stats.work_units = std.math.maxInt(u64) - 1;
    try std.testing.expectError(
        error.LimitExceeded,
        borrows.selector(&encoder).selectProvablySmall(&tokens, 1, 0),
    );
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, encoder.stats.work_units);
    try encoder.reset(workspace, .{});
    encoder.stats.work_units = std.math.maxInt(u64) - 2;
    const selected = (try borrows.selector(&encoder).selectProvablySmall(&tokens, 1, 0)).?;
    try std.testing.expectEqual(Kind.fixed, selected.kind);
    try std.testing.expectEqual(std.math.maxInt(u64), encoder.stats.work_units);

    try encoder.reset(workspace, .{ .compression = .{ .strategy = .huffman_only } });
    encoder.stats.fixed_blocks = std.math.maxInt(u64);
    var output: [32]u8 = @splat(0xa5);
    try std.testing.expectError(error.CounterOverflow, encoder.step(&.{42}, &output, .finish));
    try std.testing.expectEqual(std.math.maxInt(u64), encoder.stats.fixed_blocks);
    try std.testing.expectEqual(@as(u64, 0), encoder.stats.blocks);
    try std.testing.expectEqual(@as(usize, 0), encoder.pending);
    try std.testing.expectEqual(@as(u6, 3), encoder.bit_count);
    try std.testing.expectEqual(@as(u64, 3), encoder.bits);
    for (output) |value| try std.testing.expectEqual(@as(u8, 0xa5), value);
    try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
}

test "sparse small-block bound agrees with full dynamic selection" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    var random: std.Random.DefaultPrng = .init(0xa195e42);
    const alphabet = [_]Token{
        .{ .length = 0, .value = 0 },
        .{ .length = 0, .value = 43 },
        .{ .length = 0, .value = 90 },
        .{ .length = 0, .value = 137 },
        .{ .length = 0, .value = 184 },
        .{ .length = 0, .value = 255 },
        .{ .length = 3, .value = 1 },
        .{ .length = 10, .value = 4 },
        .{ .length = 11, .value = 5 },
        .{ .length = 258, .value = 32768 },
    };
    var shortcuts: usize = 0;
    for (6..33) |len| {
        for (0..120) |case| {
            var tokens: [32]Token = undefined;
            var bytes: usize = 0;
            for (tokens[0..len]) |*token| {
                token.* = if (case % 3 == 0) .{
                    .length = 0,
                    .value = random.random().int(u8),
                } else alphabet[random.random().uintLessThan(usize, alphabet.len)];
                bytes += @max(1, token.length);
            }
            for (0..8) |offset| {
                const proof = smallHuffmanBound(
                    tokens[0..len],
                    bytes,
                    @intCast(offset),
                ) orelse continue;
                try encoder.reset(workspace, .{});
                const complete = try borrows.selector(
                    &encoder,
                ).select(tokens[0..len], bytes, @intCast(offset));
                try std.testing.expect(proof.lower <= complete.dynamic_bits);
                if (proof.best.bits <= proof.lower) {
                    shortcuts += 1;
                    try std.testing.expectEqual(complete.kind, proof.best.kind);
                    try std.testing.expectEqual(complete.bits, proof.best.bits);
                }
            }
        }
    }
    try std.testing.expect(shortcuts > 100);
}

test "sparse bound covers run boundaries and repeated symbols" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    const values = [_]u8{ 0, 1, 5, 6, 9, 10, 11, 137, 138, 139, 143, 144, 254, 255 };
    for (values) |value| {
        for (6..33) |len| {
            var tokens: [32]Token = undefined;
            for (tokens[0..len]) |*token| token.* = .{ .length = 0, .value = value };
            for (0..8) |offset| {
                const proof = smallHuffmanBound(
                    tokens[0..len],
                    len,
                    @intCast(offset),
                ) orelse continue;
                try encoder.reset(workspace, .{});
                const full = try borrows.selector(
                    &encoder,
                ).select(tokens[0..len], len, @intCast(offset));
                try std.testing.expect(proof.lower <= full.dynamic_bits);
                if (proof.best.bits <= proof.lower) {
                    try std.testing.expectEqual(full.kind, proof.best.kind);
                    try std.testing.expectEqual(full.bits, proof.best.bits);
                }
            }
        }
    }
}

test "sparse bound handles strict, equal and rejected selection" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    const cases = [_]struct {
        bytes: []const u8,
        relation: std.math.Order,
    }{
        .{
            .bytes = &.{
                232, 131, 200, 214, 52, 246, 4, 0, 0, 117, 183, 123, 191, 180, 100, 18, 50,
            },
            .relation = .lt,
        },
        .{
            .bytes = &.{
                0, 0,   0,   22, 6,   0,   229, 76,  0, 96, 146, 194, 100, 247, 101, 103, 198, 248,
                0, 158, 248, 30, 203, 198, 198, 193, 0,
            },
            .relation = .eq,
        },
        .{
            .bytes = &.{ 129, 116, 0, 0, 56, 0, 146, 0, 0, 0, 0, 20, 202, 113, 106, 129, 0 },
            .relation = .gt,
        },
    };
    for (cases) |case| {
        var tokens: [32]Token = undefined;
        for (case.bytes, 0..) |byte, i| tokens[i] = .{ .length = 0, .value = byte };
        for (0..8) |offset| {
            const proof = smallHuffmanBound(
                tokens[0..case.bytes.len],
                case.bytes.len,
                @intCast(offset),
            ).?;
            try std.testing.expectEqual(
                case.relation,
                std.math.order(proof.best.bits, proof.lower),
            );
            try encoder.reset(workspace, .{});
            const full = try borrows.selector(
                &encoder,
            ).select(tokens[0..case.bytes.len], case.bytes.len, @intCast(offset));
            try std.testing.expect(proof.lower <= full.dynamic_bits);
            if (case.relation != .gt) {
                try std.testing.expectEqual(full.kind, proof.best.kind);
                try std.testing.expectEqual(full.bits, proof.best.bits);
            }
        }
    }
}

test "sparse bound covers a repeat crossing the book boundary" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    const tokens = [_]Token{
        .{ .length = 0, .value = 166 },
        .{ .length = 241, .value = 6 },
        .{ .length = 0, .value = 65 },
        .{ .length = 59, .value = 3 },
        .{ .length = 251, .value = 22 },
        .{ .length = 0, .value = 99 },
        .{ .length = 0, .value = 56 },
        .{ .length = 207, .value = 28 },
        .{ .length = 0, .value = 19 },
        .{ .length = 0, .value = 119 },
        .{ .length = 250, .value = 22 },
        .{ .length = 136, .value = 28 },
        .{ .length = 62, .value = 7 },
        .{ .length = 0, .value = 165 },
        .{ .length = 121, .value = 1 },
        .{ .length = 86, .value = 22 },
        .{ .length = 0, .value = 124 },
        .{ .length = 161, .value = 30 },
        .{ .length = 0, .value = 44 },
        .{ .length = 130, .value = 15 },
        .{ .length = 0, .value = 98 },
        .{ .length = 215, .value = 3 },
        .{ .length = 82, .value = 29 },
        .{ .length = 188, .value = 25 },
        .{ .length = 0, .value = 163 },
        .{ .length = 181, .value = 26 },
        .{ .length = 0, .value = 239 },
        .{ .length = 0, .value = 61 },
        .{ .length = 0, .value = 200 },
        .{ .length = 0, .value = 103 },
        .{ .length = 149, .value = 7 },
        .{ .length = 91, .value = 17 },
    };
    var bytes: usize = 0;
    for (tokens) |token| bytes += @max(1, token.length);
    try encoder.reset(workspace, .{});
    const full = try borrows.selector(&encoder).select(&tokens, bytes, 0);
    const proof = smallHuffmanBound(&tokens, bytes, 0).?;
    try std.testing.expect(proof.lower <= full.dynamic_bits);
    var position: usize = 0;
    var crossing = false;
    for (workspace.header.runs[0..workspace.header.run_count]) |run| {
        const count: usize = switch (run.symbol) {
            16, 17 => 3 + @as(usize, run.extra),
            18 => 11 + @as(usize, run.extra),
            else => 1,
        };
        crossing = crossing or (run.symbol == 16 and position < workspace.header.literal_count and
            position + count > workspace.header.literal_count);
        position += count;
    }
    try std.testing.expect(crossing);
}

test "small Huffman histogram agrees with independent merging" {
    const Oracle = struct {
        fn cost(input: []const u32) u32 {
            var weights: [65]u32 = undefined;
            var n: usize = 0;
            var total: u32 = 0;
            for (input) |weight| if (weight != 0) {
                weights[n] = weight;
                n += 1;
                total += weight;
            };
            if (n <= 1) return total;
            var result: u32 = 0;
            while (n > 1) : (n -= 1) {
                var low: usize = 0;
                for (1..n) |i| if (weights[i] < weights[low]) {
                    low = i;
                };
                const first = weights[low];
                weights[low] = weights[n - 1];
                low = 0;
                for (1..n - 1) |i| if (weights[i] < weights[low]) {
                    low = i;
                };
                weights[low] += first;
                result += weights[low];
            }
            return result;
        }
    };
    var random: std.Random.DefaultPrng = .init(0x6c51e);
    var weights: [65]u32 = @splat(0);
    try std.testing.expectEqual(@as(u32, 0), smallHuffmanCost(&weights));
    for (1..66) |total| {
        for (1..66) |symbols| {
            for (0..10) |_| {
                @memset(&weights, 0);
                for (0..total) |_| weights[random.random().uintLessThan(usize, symbols)] += 1;
                try std.testing.expectEqual(Oracle.cost(&weights), smallHuffmanCost(&weights));
            }
        }
    }
    @memset(&weights, 1);
    try std.testing.expectEqual(Oracle.cost(&weights), smallHuffmanCost(&weights));
    @memset(&weights, 0);
    weights[0] = 65;
    try std.testing.expectEqual(@as(u32, 65), smallHuffmanCost(&weights));
}

test "sparse bound covers 33 through 64 tokens" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var random: std.Random.DefaultPrng = .init(0x6d15ca);
    var shortcuts: usize = 0;
    for (33..65) |len| {
        for (0..100) |_| {
            var tokens: [64]Token = undefined;
            var bytes: usize = 0;
            for (tokens[0..len]) |*token| {
                token.* = if (random.random().boolean()) .{
                    .length = 0,
                    .value = random.random().int(u8),
                } else .{
                    .length = random.random().intRangeAtMost(u16, 3, 258),
                    .value = random.random().intRangeAtMost(u16, 1, 32768),
                };
                bytes += @max(1, token.length);
            }
            for (0..8) |offset| {
                const proof = smallHuffmanBound(
                    tokens[0..len],
                    bytes,
                    @intCast(offset),
                ) orelse continue;
                try encoder.reset(workspace, .{});
                const full = try borrows.selector(
                    &encoder,
                ).select(tokens[0..len], bytes, @intCast(offset));
                try std.testing.expect(proof.lower <= full.dynamic_bits);
                if (proof.best.bits <= proof.lower) {
                    shortcuts += 1;
                    try std.testing.expectEqual(full.kind, proof.best.kind);
                    try std.testing.expectEqual(full.bits, proof.best.bits);
                }
            }
        }
    }
    try std.testing.expect(shortcuts > 100);
}

test "distance bound proves the 8 by 8 fixed block" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    const tokens = [_]Token{
        .{ .length = 0, .value = 1 },
        .{ .length = 0, .value = 43 },
        .{ .length = 0, .value = 90 },
        .{ .length = 0, .value = 137 },
        .{ .length = 0, .value = 184 },
        .{ .length = 0, .value = 23 },
        .{ .length = 27, .value = 1 },
        .{ .length = 0, .value = 4 },
        .{ .length = 0, .value = 49 },
        .{ .length = 3, .value = 1 },
        .{ .length = 15, .value = 20 },
        .{ .length = 0, .value = 49 },
        .{ .length = 12, .value = 7 },
        .{ .length = 0, .value = 1 },
        .{ .length = 0, .value = 141 },
        .{ .length = 0, .value = 188 },
        .{ .length = 0, .value = 235 },
        .{ .length = 0, .value = 26 },
        .{ .length = 28, .value = 66 },
        .{ .length = 0, .value = 1 },
        .{ .length = 0, .value = 190 },
        .{ .length = 0, .value = 237 },
        .{ .length = 0, .value = 28 },
        .{ .length = 0, .value = 75 },
        .{ .length = 29, .value = 33 },
        .{ .length = 0, .value = 239 },
        .{ .length = 0, .value = 30 },
        .{ .length = 0, .value = 77 },
        .{ .length = 0, .value = 124 },
        .{ .length = 33, .value = 132 },
        .{ .length = 0, .value = 49 },
        .{ .length = 22, .value = 28 },
        .{ .length = 0, .value = 49 },
        .{ .length = 38, .value = 165 },
        .{ .length = 0, .value = 130 },
        .{ .length = 0, .value = 177 },
        .{ .length = 0, .value = 224 },
        .{ .length = 0, .value = 15 },
        .{ .length = 28, .value = 99 },
    };
    const proof = smallHuffmanBound(&tokens, 264, 0).?;
    try std.testing.expectEqual(Kind.fixed, proof.best.kind);
    try std.testing.expectEqual(@as(u32, 420), proof.best.bits);
    try std.testing.expect(proof.lower >= proof.best.bits);
    try encoder.reset(workspace, .{});
    const full = try borrows.selector(&encoder).select(&tokens, 264, 0);
    try std.testing.expect(proof.lower <= full.dynamic_bits);
    try std.testing.expectEqual(proof.best.kind, full.kind);
    try std.testing.expectEqual(proof.best.bits, full.bits);
}

test "wide sparse shortcut respects work overflow and reset" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var bytes: [40]u8 = undefined;
    var tokens: [40]Token = undefined;
    for (&bytes, 0..) |*byte, i| {
        byte.* = @intCast(i * 6);
        tokens[i] = .{ .length = 0, .value = byte.* };
    }
    const proof = smallHuffmanBound(&tokens, bytes.len, 0).?;
    try std.testing.expect(proof.best.bits <= proof.lower);
    var output: [512]u8 = undefined;
    try encoder.reset(workspace, .{ .compression = .{ .strategy = .huffman_only } });
    encoder.stats.work_units = std.math.maxInt(u64) - @as(u64, bytes.len);
    try std.testing.expectError(error.LimitExceeded, encoder.step(&bytes, &output, .finish));
    try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
    try encoder.reset(workspace, .{ .compression = .{ .strategy = .huffman_only } });
    encoder.stats.work_units = std.math.maxInt(u64) - @as(u64, bytes.len) - 1;
    const result = try encoder.step(&bytes, &output, .finish);
    try std.testing.expectEqual(EncodeStatus.complete, result.status);
    try std.testing.expectEqual(std.math.maxInt(u64), encoder.stats.work_units);
}

test "wide bound covers all distance slots and 65 literal symbols" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var tokens: [64]Token = undefined;
    for (0..2) |mode| {
        var bytes: usize = 0;
        for (&tokens, 0..) |*token, i| {
            token.* = if (mode == 0 and i < 30) .{
                .length = 3,
                .value = distance_base[i],
            } else .{ .length = 0, .value = @intCast(i * 3) };
            bytes += @max(1, token.length);
        }
        for (0..8) |offset| {
            const proof = smallHuffmanBound(&tokens, bytes, @intCast(offset)).?;
            try encoder.reset(workspace, .{});
            const full = try borrows.selector(&encoder).select(&tokens, bytes, @intCast(offset));
            try std.testing.expect(proof.lower <= full.dynamic_bits);
            if (proof.best.bits <= proof.lower) {
                try std.testing.expectEqual(full.kind, proof.best.kind);
                try std.testing.expectEqual(full.bits, proof.best.bits);
            }
        }
    }
}

test "wide proof preflight leaves concentrated blocks to ordinary selection" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var tokens: [64]Token = undefined;
    for ([_]usize{ 32, 33, 64 }) |len| {
        for ([_]usize{ 15, 16, 17 }) |literal_symbols| {
            for (
                tokens[0..len],
                0..,
            ) |*token, i| token.* = .{ .length = 0, .value = @intCast(i % literal_symbols) };
            const proof = smallHuffmanBound(tokens[0..len], len, 0);
            if (len > 32 and literal_symbols <= 16) {
                try std.testing.expect(proof == null);
            } else {
                const bound = proof.?;
                try encoder.reset(workspace, .{});
                const full = try borrows.selector(&encoder).select(tokens[0..len], len, 0);
                try std.testing.expect(bound.lower <= full.dynamic_bits);
            }
        }
    }
}

test "wide preflight counts symbol extremes" {
    var tokens: [64]Token = @splat(.{ .length = 0, .value = 0 });
    for ([_]usize{ 32, 33, 64 }) |len| {
        for ([_]usize{ 12, 13 }) |interior| {
            @memset(&tokens, .{ .length = 0, .value = 0 });
            tokens[1] = .{ .length = 0, .value = 255 };
            tokens[2] = .{ .length = 3, .value = 1 };
            tokens[3] = .{ .length = 258, .value = 1 };
            for (0..interior) |i| tokens[i + 4] = .{ .length = 0, .value = @intCast(i + 1) };
            var bytes: usize = 0;
            for (tokens[0..len]) |token| bytes += @max(1, token.length);
            // With EOB, 0, 255, length codes 257/285, and 12 or 13 interior literals, the alphabet
            // has 17 or 18 symbols.
            const proof = smallHuffmanBound(tokens[0..len], bytes, 0);
            try std.testing.expectEqual(len <= 32 or interior == 13, proof != null);
        }
    }
}

test "wide preflight fallback keeps complete selection work limits" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var bytes: [40]u8 = undefined;
    var tokens: [40]Token = undefined;
    for (&bytes, 0..) |*byte, i| {
        byte.* = @intCast(i % 4);
        tokens[i] = .{ .length = 0, .value = byte.* };
    }
    try std.testing.expect(smallHuffmanBound(&tokens, bytes.len, 0) == null);
    try encoder.reset(workspace, .{});
    _ = try borrows.selector(&encoder).select(&tokens, bytes.len, 0);
    const work = encoder.stats.work_units;
    try std.testing.expect(work > 0);
    var output: [512]u8 = undefined;
    try encoder.reset(
        workspace,
        .{ .compression = .{ .strategy = .huffman_only }, .limits = .{ .work_units = work - 1 } },
    );
    try std.testing.expectError(error.LimitExceeded, encoder.step(&bytes, &output, .finish));
    try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
    try encoder.reset(
        workspace,
        .{ .compression = .{ .strategy = .huffman_only }, .limits = .{ .work_units = work } },
    );
    const result = try encoder.step(&bytes, &output, .finish);
    try std.testing.expectEqual(EncodeStatus.complete, result.status);
    try std.testing.expectEqual(work, encoder.stats.work_units);
}
