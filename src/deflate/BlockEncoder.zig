//! Construct an ordinary DEFLATE block by finding matches, selecting tokens and comparing wire
//! representations. Offline profiles refine token prices, retain the best parse and consider
//! bounded block splits before emission.
//!
//! The borrowed workers run in successive phases. Search must finish before parser/selector scratch
//! becomes live, because its checkpoint temporarily occupies that same backing.

const std = @import("std");
const Compression = @import("Compression.zig");
const compression_effort = @import("compression_effort.zig");
const MatchFinder = @import("MatchFinder.zig");
const Lz77Parser = @import("Lz77Parser.zig");
const BlockSelector = @import("BlockSelector.zig");
const BlockWriter = @import("BlockWriter.zig");
const HuffmanCodebook = @import("HuffmanCodebook.zig");
const EncodeWorkBudget = @import("EncodeWorkBudget.zig");
const fixedBook = HuffmanCodebook.fixed;
const smallHuffmanBound = BlockSelector.smallHuffmanBound;
const mayReusePricing = Lz77Parser.mayReusePricing;
const BlockEncoder = @This();

/// Active source bytes in this slab.
buffered: usize,
/// Resolved ordinary policy; stored and four-byte-run blocks bypass this operation.
profile: compression_effort.Profile,
/// Which retained lengths/distances participate in priced parsing.
pricing: Compression.OfflinePricing,
/// When repeated price construction may stop.
refinement: Compression.OfflineRefinement,
/// Candidate discovery and persistent-search backing.
search: MatchFinder,
/// Per-position pricing and current token output.
parser: Lz77Parser,
/// Candidate/trial headers, best tokens and partitions.
selector: BlockSelector,
/// Shared stream cursor and staged output.
writer: BlockWriter,
/// Shared cumulative work admission, also used for equivalent skipped passes.
work: EncodeWorkBudget,

pub fn encode(self: *const BlockEncoder, final: bool) EncodeWorkBudget.Error!void {
    if (self.profile == .offline) {
        try self.search.findOfflineTreeMatches(final);
    } else if (self.profile != .huffman) {
        try self.search.findMatches();
    }
    var count = self.parser.referenceParse(self.profile == .lazy or self.profile == .offline);
    if (self.profile != .offline and count <= 64) {
        if (count <= 5) {
            if (try self.selector.selectProvablySmall(
                self.parser.tokens[0..count],
                self.buffered,
                self.writer.bit_count.*,
            )) |small| {
                return self.writer.emit(
                    self.selector.header,
                    self.parser.tokens[0..count],
                    .{ .first = 0, .end = count, .start = 0, .bytes = self.buffered },
                    small.kind,
                    final,
                );
            }
        } else {
            @branchHint(.unlikely);
            if (smallHuffmanBound(
                self.parser.tokens[0..count],
                self.buffered,
                self.writer.bit_count.*,
            )) |proof| {
                if (proof.best.bits <= proof.lower) {
                    try self.work.admit(count + 1);
                    return self.writer.emit(
                        self.selector.header,
                        self.parser.tokens[0..count],
                        .{ .first = 0, .end = count, .start = 0, .bytes = self.buffered },
                        proof.best.kind,
                        final,
                    );
                }
            }
        }
    }
    var selection = try self.selector.select(
        self.parser.tokens[0..count],
        self.buffered,
        self.writer.bit_count.*,
    );
    if (self.profile != .offline) {
        // Selection leaves the dynamic candidate books/header ready. Fixed emission installs the
        // RFC books; stored emission does not use them. Only offline parsing can still replace
        // these tokens or split them into separately priced blocks.
        return self.writer.emit(
            self.selector.header,
            self.parser.tokens[0..count],
            .{ .first = 0, .end = count, .start = 0, .bytes = self.buffered },
            selection.kind,
            final,
        );
    }

    // The reusable state needs a long run of identical match metadata. Prices can split such runs
    // but cannot create one, so this scan may conservatively select the reuse path.
    const reuse_possible = mayReusePricing(self.parser.matches[0..self.buffered]);
    var best_count = count;
    var best_bits = selection.bits;
    @memcpy(self.selector.best[0..count], self.parser.tokens[0..count]);
    fixedBook(&self.selector.header.literal, false);
    fixedBook(&self.selector.header.distance, true);
    var previous_dynamic_best: ?u32 = null;
    for (0..8) |pass| {
        const literal_widths = self.selector.header.literal.widths;
        const distance_widths = self.selector.header.distance.widths[0..30].*;
        const work_before = self.work.stats.work_units;
        const edges_before = self.work.stats.parse_edges;
        count = switch (self.pricing) {
            .maximum_lengths => if (reuse_possible) try self.parser.priceParse(
                true,
                .maximum_lengths,
                &self.selector.header.literal,
                &self.selector.header.distance,
            ) else try self.parser.priceParse(
                false,
                .maximum_lengths,
                &self.selector.header.literal,
                &self.selector.header.distance,
            ),
            .reduced => if (reuse_possible) try self.parser.priceParse(
                true,
                .reduced,
                &self.selector.header.literal,
                &self.selector.header.distance,
            ) else try self.parser.priceParse(
                false,
                .reduced,
                &self.selector.header.literal,
                &self.selector.header.distance,
            ),
            .full => if (reuse_possible) try self.parser.priceParse(
                true,
                .full,
                &self.selector.header.literal,
                &self.selector.header.distance,
            ) else try self.parser.priceParse(
                false,
                .full,
                &self.selector.header.literal,
                &self.selector.header.distance,
            ),
        };
        selection = try self.selector.select(
            self.parser.tokens[0..count],
            self.buffered,
            self.writer.bit_count.*,
        );
        if (selection.bits < best_bits) {
            best_bits = selection.bits;
            best_count = count;
            @memcpy(self.selector.best[0..count], self.parser.tokens[0..count]);
        }
        // Both stopping rules consider the triggering pass before returning the best parse.
        if (self.refinement == .early and earlyStop(
            pass,
            previous_dynamic_best,
            selection.dynamic_bits,
        )) break;
        // Standard refinement stops on equal or worse dynamic cost; a one-bit gain continues.
        if (adaptiveStop(previous_dynamic_best, selection.dynamic_bits)) break;
        previous_dynamic_best = selection.dynamic_bits;
        // select constructs the next dynamic price books, including when a fixed/stored candidate
        // won the serialized choice.
        if (!std.mem.eql(
            u8,
            &literal_widths,
            &self.selector.header.literal.widths,
        ) or !std.mem.eql(
            u8,
            &distance_widths,
            self.selector.header.distance.widths[0..30],
        )) continue;
        // Stable books guarantee that the next pass has the same dynamic price and stops. Reserve
        // that one logical pass only when it fits. Otherwise execute it normally so refusal still
        // reports the actual admission point and partial counters.
        const remaining: u64 = if (pass < 7) 1 else 0;
        const units = std.math.mul(
            u64,
            self.work.stats.work_units - work_before,
            remaining,
        ) catch continue;
        const edges = std.math.mul(
            u64,
            self.work.stats.parse_edges - edges_before,
            remaining,
        ) catch continue;
        const work_left = self.work.limit -| self.work.stats.work_units;
        const edges_left = std.math.maxInt(u64) - self.work.stats.parse_edges;
        if (units > work_left or edges > edges_left) continue;
        try self.work.admit(units);
        self.work.stats.parse_edges += edges;
        break;
    }
    self.selector.segments[0] = .{
        .first = 0,
        .end = best_count,
        .start = 0,
        .bytes = self.buffered,
    };
    var segments: usize = 1;
    if (self.buffered >= 4096) {
        segments = try self.selector.split(
            0,
            best_count,
            0,
            self.buffered,
            self.writer.bit_count.*,
            0,
            0,
        );
    }
    for (self.selector.segments[0..segments], 0..) |segment, index| {
        const tokens = self.selector.best[segment.first..segment.end];
        const chosen = try self.selector.select(tokens, segment.bytes, self.writer.bit_count.*);
        try self.writer.emit(
            self.selector.header,
            tokens,
            segment,
            chosen.kind,
            final and index + 1 == segments,
        );
    }
}

// A missing prior pass never stops. Equal or worse dynamic cost stops without overflow.
fn adaptiveStop(previous: ?u32, current: u32) bool {
    return if (previous) |best| current >= best else false;
}

fn earlyStop(pass: usize, previous: ?u32, current: u32) bool {
    if (pass != 1) return false;
    const prior = previous orelse return false;
    return current >= prior - prior / 100;
}

test "early refinement stops at the second-pass percentage boundary" {
    try std.testing.expect(!earlyStop(1, null, 0));
    try std.testing.expect(!earlyStop(0, 1000, 1000));
    try std.testing.expect(!earlyStop(2, 1000, 1000));
    try std.testing.expect(earlyStop(1, 1000, 990));
    try std.testing.expect(!earlyStop(1, 1000, 989));
    try std.testing.expect(earlyStop(1, 99, 99));
    try std.testing.expect(!earlyStop(1, 99, 98));
    try std.testing.expect(earlyStop(1, std.math.maxInt(u32), std.math.maxInt(u32)));
}

test "adaptive dynamic price stop preserves triggering pass order" {
    try std.testing.expect(!adaptiveStop(null, std.math.maxInt(u32)));
    try std.testing.expect(adaptiveStop(100, 100));
    try std.testing.expect(adaptiveStop(100, 101));
    try std.testing.expect(!adaptiveStop(100, 99));
    try std.testing.expect(adaptiveStop(std.math.maxInt(u32), std.math.maxInt(u32)));
    // A triggering candidate is considered before stopping, while a later improvement is not.
    const prices = [_]u32{ 100, 100, 80 };
    const selected = [_]u32{ 110, 90, 70 };
    var previous: ?u32 = null;
    var best: u32 = 120;
    var executed: usize = 0;
    for (prices, selected) |price, bits| {
        best = @min(best, bits);
        executed += 1;
        if (adaptiveStop(previous, price)) break;
        previous = price;
    }
    try std.testing.expectEqual(2, executed);
    try std.testing.expectEqual(90, best);
}
