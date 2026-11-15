//! A DEFLATE token emits one literal byte or copies bytes from a backward match. This parser
//! chooses a sequence covering the source slab from the discovered match candidates. Reference
//! parsing follows greedy/lazy choices; priced parsing finds a cheapest path under supplied code
//! prices. It works backward: each literal or match adds its own price to the already computed cost
//! of the remaining suffix. A forward walk then emits the chosen tokens. Source and pricing/output
//! arrays remain borrowed for this block.

const std = @import("std");
const protocol = @import("format.zig");
const Compression = @import("Compression.zig");
const MatchCandidates = @import("MatchCandidates.zig");
const Match = MatchCandidates.Candidate;
const alternatives = MatchCandidates.capacity;
const HuffmanCodebook = @import("HuffmanCodebook.zig");
const EncodeWorkBudget = @import("EncodeWorkBudget.zig");
const addCount = EncodeWorkBudget.addCount;
const lengthSlot = protocol.lengthSlot;
const distanceSlot = protocol.distanceSlot;
const length_base = protocol.length_base;
const length_extra = protocol.length_extra;
const distance_extra = protocol.distance_extra;
const test_encoding = @import("encode.zig");
const borrows = @import("block_borrows.zig");
const Encoder = test_encoding.StreamEncoder;
const EncoderWorkspace = @import("EncodeWorkspace.zig");
const EncodeStats = test_encoding.Stats;
const encode = test_encoding.into;
const fixedBook = HuffmanCodebook.fixed;
const Lz77Parser = @This();

pub const Token = struct {
    /// Zero identifies one literal; a match covers three through 258 source bytes.
    length: u16,
    /// Literal byte when length is zero, otherwise the backward match distance.
    value: u16,
};

/// Active source bytes for this block, excluding copied dictionary/previous-slab history. Parsing
/// reads literal values here; discovered candidates already carry backward distances.
source: []const u8,
/// Reference parsing emits literals without consulting match rows.
literal_only: bool,
/// Reference parsing reads only rows initialized by its matching policy; priced parsing requires
/// every active-slab row. Literal-only reference parsing ignores these rows.
matches: []const MatchCandidates,
/// Writable suffix costs, including one additional end-of-slab entry.
costs: []u32,
/// Writable per-position decisions used to reconstruct the token sequence.
choices: []Token,
/// Output token reservation, at least source.len entries.
tokens: []Token,
/// Shared cumulative allowance; skipped equivalent rows retain their logical charges.
work: EncodeWorkBudget,

pub fn referenceParse(self: *const Lz77Parser, lazy: bool) usize {
    var count: usize = 0;
    var position: usize = 0;
    while (position < self.source.len) {
        const matches = &self.matches[position];
        var length: usize = 0;
        var distance: u16 = 0;
        if (!self.literal_only and matches.count != 0) {
            const match = matches.items[matches.count - 1];
            length = match.length;
            distance = match.distance;
            if (lazy and position + 1 < self.source.len) {
                const next = &self.matches[position + 1];
                if (next.count != 0 and next.items[next.count - 1].length > length) length = 0;
            }
        }
        const value: u16 = if (length == 0) self.source[position] else distance;
        self.tokens[count] = .{ .length = @intCast(length), .value = value };
        position += @max(1, length);
        count += 1;
    }
    return count;
}

pub noinline fn priceParse(
    borrowed: *const Lz77Parser,
    comptime reuse: bool,
    comptime policy: Compression.OfflinePricing,
    literal: *const HuffmanCodebook,
    distance: *const HuffmanCodebook,
) EncodeWorkBudget.Error!usize {
    // Snapshot immutable phase metadata once; backing storage and counters remain live borrows.
    const self = borrowed.*;
    // Copy prices: header construction after this parse may replace books. Unused symbols receive
    // finite provisional prices so a later parse can introduce them rather than treating them as
    // free or impossible.
    var literal_prices: [286]u32 = undefined;
    var distance_prices: [30]u32 = undefined;
    for (&literal_prices, literal.widths) |*cost, width| cost.* = if (width == 0) 13 else width;
    for (&distance_prices, distance.widths[0..30], 0..) |*cost, width, i| {
        const code_price: u32 = if (width == 0) 10 else width;
        cost.* = code_price + distance_extra[i];
    }
    var length_prices: [259]u32 = undefined;
    for (3..259) |length| {
        const slot = lengthSlot(length);
        length_prices[length] = literal_prices[257 + @as(usize, slot)] + length_extra[slot];
    }
    self.costs[self.source.len] = 0;
    var run: RepeatedCostState = .{ .first = self.source.len };
    var position = self.source.len;
    while (position != 0) {
        position -= 1;
        if (reuse and position < run.first) run = RepeatedCostState.find(
            &self,
            position,
            &literal_prices,
        );
        const value = self.source[position];
        var cost = literal_prices[value] + self.costs[position + 1];
        var choice: Token = .{ .length = 0, .value = value };
        const matches = &self.matches[position];
        if (matches.count != 0) {
            const maximum = matches.items[matches.count - 1].length;
            // Charge the full logical length range even when a pricing choice skips lengths.
            try self.work.admit(maximum - 2);
            self.work.stats.parse_edges = try addCount(self.work.stats.parse_edges, maximum - 2);
            if (policy == .maximum_lengths) {
                // Only retained maximum lengths participate in this pruned parse.
                for (matches.items[0..matches.count]) |match| {
                    const length: usize = match.length;
                    const distance_price = distance_prices[distanceSlot(match.distance)];
                    const candidate = distance_price + length_prices[length] + self.costs[
                        position +
                            length
                    ];
                    if (candidate < cost) {
                        cost = candidate;
                        choice = .{ .length = match.length, .value = match.distance };
                    }
                }
            } else if (reuse and matches.count == 1) {
                const match = matches.items[0];
                self.priceSingleMatch(
                    position,
                    match,
                    &length_prices,
                    distance_prices[distanceSlot(match.distance)],
                    &cost,
                    &choice,
                );
            } else if (policy == .reduced) {
                var length: usize = 3;
                for (matches.items[0..matches.count]) |match| {
                    const distance_price = distance_prices[distanceSlot(match.distance)];
                    while (length <= match.length) : (length += 1) {
                        const candidate = distance_price + length_prices[length] + self
                            .costs[position + length];
                        if (candidate < cost) {
                            cost = candidate;
                            choice = .{ .length = @intCast(length), .value = match.distance };
                        }
                    }
                }
            } else {
                var suffix: [alternatives]u8 = undefined;
                var match_prices: [alternatives]u32 = undefined;
                for (matches.items[0..matches.count], 0..) |match, i| {
                    match_prices[i] = distance_prices[distanceSlot(match.distance)];
                }
                var i: usize = matches.count;
                var cheapest: usize = i - 1;
                while (i != 0) {
                    i -= 1;
                    if (match_prices[i] < match_prices[cheapest] or (match_prices[i] ==
                        match_prices[cheapest] and matches.items[i].distance < matches
                        .items[cheapest].distance))
                    {
                        cheapest = i;
                    }
                    suffix[i] = @intCast(cheapest);
                }
                var index: usize = 0;
                // The first sixteen price bands contain at most four lengths each. Direct scans
                // avoid range/reduction overhead for short matches.
                if (maximum < 35) {
                    var length: usize = 3;
                    while (length <= maximum) {
                        while (matches.items[index].length < length) index += 1;
                        const selected = suffix[index];
                        // The cheapest usable distance stays cheapest until its match ends.
                        const match = matches.items[selected];
                        const distance_price = match_prices[selected];
                        while (length <= match.length) : (length += 1) {
                            const match_price = length_prices[length] + distance_price;
                            const candidate = match_price + self.costs[position + length];
                            if (candidate < cost) {
                                cost = candidate;
                                choice = .{ .length = @intCast(length), .value = match.distance };
                            }
                        }
                    }
                } else {
                    // Lengths 3..10 each have their own RFC code, so no suffix range is reduced.
                    var length: usize = 3;
                    while (length <= 10) : (length += 1) {
                        while (matches.items[index].length < length) index += 1;
                        const selected = suffix[index];
                        const match_price = length_prices[length] + match_prices[selected];
                        const candidate = match_price + self.costs[position + length];
                        if (candidate < cost) {
                            cost = candidate;
                            choice = .{
                                .length = @intCast(length),
                                .value = matches.items[selected].distance,
                            };
                        }
                    }
                    var slot: usize = 8;
                    while (length <= maximum) {
                        while (matches.items[index].length < length) index += 1;
                        const selected = suffix[index];
                        const match = matches.items[selected];
                        // Length-code prices are constant within an RFC band. The cheapest usable
                        // retained distance stays selected until that match ends, including nearest
                        // ties among retained alternatives.
                        const band_end = if (slot == 28) 258 else length_base[slot + 1] - 1;
                        const end = @min(band_end, match.length);
                        const first_cost = position + length;
                        const suffix_costs = self.costs[first_cost .. position + end + 1];
                        const take = if (end == length) length else length + minimumCostIndex(
                            suffix_costs,
                        );
                        const match_price = length_prices[length] + match_prices[selected];
                        const candidate = match_price + self.costs[position + take];
                        if (candidate < cost) {
                            cost = candidate;
                            choice = .{ .length = @intCast(take), .value = match.distance };
                        }
                        length = end + 1;
                        if (end == band_end) slot += 1;
                    }
                }
            }
        }
        self.costs[position] = cost;
        self.choices[position] = choice;
        if (reuse) position = try run.reuse(&self, position);
    }
    position = 0;
    var count: usize = 0;
    while (position < self.source.len) {
        const token = self.choices[position];
        self.tokens[count] = token;
        position += @max(1, token.length);
        count += 1;
    }
    return count;
}

// A single retained distance needs neither suffix-price selection nor frontier-boundary checks.
// Keep this concrete path inline so each range shares that distance's price and choice.
pub inline fn priceSingleMatch(
    self: *const Lz77Parser,
    position: usize,
    match: Match,
    length_prices: *const [259]u32,
    distance_price: u32,
    cost: *u32,
    choice: *Token,
) void {
    const costs = self.costs;
    if (match.length < 35) {
        for (3..@as(usize, match.length) + 1) |length| {
            const candidate = distance_price + length_prices[length] + costs[position + length];
            if (candidate < cost.*) {
                cost.* = candidate;
                choice.* = .{ .length = @intCast(length), .value = match.distance };
            }
        }
        return;
    }
    var slot: usize = 0;
    var length: usize = 3;
    while (length <= match.length) {
        const band_end = if (slot == 28) 258 else length_base[slot + 1] - 1;
        const end = @min(band_end, match.length);
        const suffix = costs[position + length .. position + end + 1];
        const take = if (end == length) length else length + minimumCostIndex(suffix);
        const candidate = distance_price + length_prices[length] + costs[position + take];
        if (candidate < cost.*) {
            cost.* = candidate;
            choice.* = .{ .length = @intCast(take), .value = match.distance };
        }
        length = end + 1;
        slot += 1;
    }
}

// Any reusable price run must contain more than twice its match length in consecutive rows with the
// same single match. Ignoring literal prices may admit extra rows, but cannot miss a real run.
pub fn mayReusePricing(matches: []const MatchCandidates) bool {
    var run: usize = 0;
    var previous_length: u16 = 0;
    var previous_distance: u16 = 0;
    for (matches) |*row| {
        if (row.count != 1 or row.items[0].length < 35) {
            run = 0;
            continue;
        }
        const match = row.items[0];
        if (run != 0 and match.length == previous_length and match.distance == previous_distance) {
            run += 1;
        } else {
            run = 1;
            previous_length = match.length;
            previous_distance = match.distance;
        }
        if (run > 2 * @as(usize, match.length)) return true;
    }
    return false;
}

// When a run has identical match choices and literal prices, equality of the complete future-cost
// state up to a constant proves that earlier choices repeat. Copy completed rows while retaining
// their logical work charges and the actual literal byte at each source position.
const RepeatedCostState = struct {
    /// Earliest row with this single-match metadata and literal price.
    first: usize,
    /// Later row used as the reference when comparing complete suffix-cost states.
    anchor: usize = 0,
    /// Match length whose future-cost extent must agree; zero disables further reuse attempts.
    maximum: usize = 0,
    /// Failed full-period comparisons, bounding discovery before ordinary parsing resumes.
    attempts: u8 = 0,

    fn find(parser: *const Lz77Parser, position: usize, prices: *const [286]u32) RepeatedCostState {
        const matches = &parser.matches[position];
        if (matches.count != 1 or matches.items[0].length < 35) return .{ .first = position };
        const maximum = matches.items[0].length;
        const distance = matches.items[0].distance;
        const price = prices[parser.source[position]];
        var first = position;
        while (first != 0) {
            const prior = &parser.matches[first - 1];
            if (prior.count != 1 or prior.items[0].length != maximum or prior.items[0].distance !=
                distance or prices[parser.source[first - 1]] != price) break;
            first -= 1;
        }
        return .{
            .first = first,
            .anchor = position,
            .maximum = if (position - first + 1 > 2 * maximum) maximum else 0,
        };
    }

    fn reuse(
        self: *RepeatedCostState,
        parser: *const Lz77Parser,
        position: usize,
    ) EncodeWorkBudget.Error!usize {
        const maximum = self.maximum;
        if (maximum == 0 or position == self.anchor) return position;
        const period = self.anchor - position;
        std.debug.assert(period <= maximum);
        const costs = parser.costs;
        var same = costs[position] > costs[self.anchor];
        const delta = costs[position] -| costs[self.anchor];
        if (same) {
            for (0..maximum) |offset| {
                if (costs[position + offset] != costs[self.anchor + offset] + delta) {
                    same = false;
                    break;
                }
            }
        }
        if (!same) {
            // Bound discovery even when constant transitions never acquire a short cycle.
            if (period == maximum) {
                self.attempts += 1;
                if (self.attempts == 5 or position - self.first <= maximum) {
                    self.maximum = 0;
                } else self.anchor = position;
            }
            return position;
        }
        self.maximum = 0;
        const per_row: u64 = @intCast(maximum - 2);
        const capacity = @min(
            (parser.work.limit - parser.work.stats.work_units) / per_row,
            (std.math.maxInt(u64) - parser.work.stats.parse_edges) / per_row,
        );
        const rows: usize = @intCast(@min(@as(u64, @intCast(position - self.first)), capacity));
        if (rows == 0) return position;
        // Admit only complete rows. The ordinary path preserves the next refusal and its counter
        // publication order when either work or edge accounting reaches its limit.
        const units = @as(u64, @intCast(rows)) * per_row;
        try parser.work.admit(units);
        parser.work.stats.parse_edges = try addCount(parser.work.stats.parse_edges, units);
        const first = position - rows;
        var next = position;
        while (next != first) {
            next -= 1;
            costs[next] = costs[next + period] + delta;
            const choice = parser.choices[next + period];
            parser.choices[next] = if (choice.length == 0) .{
                .length = 0,
                .value = parser.source[next],
            } else choice;
        }
        return first;
    }
};

// Exact first minimum in one length-price band (at most 32 suffixes). Vector loads stay inside the
// initialized cost range; equal minima retain the shorter match on every target.
fn minimumCostIndex(costs: []const u32) usize {
    var best: usize = 0;
    var position: usize = 0;
    while (position + 8 <= costs.len) : (position += 8) {
        const values: @Vector(8, u32) = costs[position..][0..8].*;
        const minimum = @reduce(.Min, values);
        if (minimum < costs[best]) {
            best = position + std.simd.firstIndexOfValue(values, minimum).?;
        }
    }
    while (position < costs.len) : (position += 1) {
        if (costs[position] < costs[best]) best = position;
    }
    return best;
}

const window_bytes = 32768;

test "offline price ranges preserve exhaustive paths ties and logical edge budgets" {
    const Reference = struct {
        fn check(
            comptime policy: Compression.OfflinePricing,
            encoder: *Encoder,
            literal: *const HuffmanCodebook,
            distance: *const HuffmanCodebook,
        ) !void {
            const allocator = std.testing.allocator;
            const workspace = encoder.workspace;
            const size = encoder.buffered;
            const costs = try allocator.alloc(u32, size + 1);
            defer allocator.free(costs);
            const choices = try allocator.alloc(Token, size);
            defer allocator.free(choices);
            costs[size] = 0;
            var edges: u64 = 0;
            var position = size;
            while (position != 0) {
                position -= 1;
                const value = workspace.data[encoder.history + position];
                const width = literal.widths[value];
                var cost = @as(u32, if (width == 0) 13 else width) + costs[position + 1];
                var choice: Token = .{ .length = 0, .value = value };
                const matches = &workspace.matches[position];
                if (matches.count != 0) {
                    const maximum = matches.items[matches.count - 1].length;
                    edges += maximum - 2;
                    // Enumerate every length and usable cached distance, independently of range
                    // grouping, suffix-price selection and vector minima.
                    for (3..@as(usize, maximum) + 1) |length| {
                        var price: u32 = std.math.maxInt(u32);
                        var nearest: u16 = std.math.maxInt(u16);
                        for (matches.items[0..matches.count]) |match| {
                            if (match.length < length or (policy == .maximum_lengths and match
                                .length != length)) continue;
                            const slot = distanceSlot(match.distance);
                            const bits = distance.widths[slot];
                            const candidate = @as(
                                u32,
                                if (bits == 0) 10 else bits,
                            ) + distance_extra[slot];
                            if (policy == .reduced) {
                                price = candidate;
                                nearest = match.distance;
                                break;
                            }
                            if (policy == .maximum_lengths) {
                                if (candidate < price) {
                                    price = candidate;
                                    nearest = match.distance;
                                }
                                continue;
                            }
                            if (candidate < price or (candidate == price and match.distance <
                                nearest))
                            {
                                price = candidate;
                                nearest = match.distance;
                            }
                        }
                        if (price == std.math.maxInt(u32)) continue;
                        const slot = lengthSlot(length);
                        const bits = literal.widths[257 + @as(usize, slot)];
                        const candidate = @as(
                            u32,
                            if (bits == 0) 13 else bits,
                        ) + length_extra[slot] + price + costs[position + length];
                        if (candidate < cost) {
                            cost = candidate;
                            choice = .{ .length = @intCast(length), .value = nearest };
                        }
                    }
                }
                costs[position] = cost;
                choices[position] = choice;
            }
            // Both compiled paths must independently match the exhaustive price and tie oracle.
            inline for (.{ false, true }) |reuse| {
                encoder.stats = .{};
                const count = try borrows.parser(
                    encoder,
                ).priceParse(reuse, policy, literal, distance);
                try std.testing.expectEqual(edges, encoder.counts().work_units);
                try std.testing.expectEqual(edges, encoder.counts().parse_edges);
                try std.testing.expectEqualSlices(u32, costs, workspace.costs[0 .. size + 1]);
                try std.testing.expectEqualSlices(Token, choices, workspace.choices[0..size]);
                position = 0;
                var token: usize = 0;
                while (position < size) {
                    try std.testing.expectEqual(choices[position], workspace.tokens[token]);
                    position += @max(1, choices[position].length);
                    token += 1;
                }
                try std.testing.expectEqual(token, count);
            }
        }
    };
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var literal: HuffmanCodebook = undefined;
    var distance: HuffmanCodebook = undefined;
    const full_choices = try std.testing.allocator.alloc(Token, 65535);
    defer std.testing.allocator.free(full_choices);
    const reduced_choices = try std.testing.allocator.alloc(Token, 65535);
    defer std.testing.allocator.free(reduced_choices);
    var differences: [3]bool = @splat(false);
    for (
        [_]usize{
            0, 1, 2, 3, 4, 8, 10, 11, 19, 33, 34, 35, 36, 67, 131, 257, 258, 259, 768, 65535,
        },
    ) |size| {
        const patterns: usize = if (size == 65535) 1 else 8;
        const pricings: usize = if (size == 65535) 1 else 5;
        for (0..patterns) |pattern| {
            for (0..pricings) |pricing| {
                try encoder.reset(workspace, .{});
                encoder.history = window_bytes;
                encoder.buffered = size;
                @memset(workspace.data[0 .. window_bytes + size], 'A');
                fixedBook(&literal, false);
                fixedBook(&distance, true);
                if (pricing != 0) {
                    for (&literal.widths, 0..) |*width, i| {
                        width.* = switch (pricing) {
                            1 => 0,
                            2 => @intCast((i * 3 + 7) % 16),
                            4 => 1,
                            else => if (i == 'A') 1 else 3,
                        };
                    }
                    for (&distance.widths, 0..) |*width, i| {
                        width.* = switch (pricing) {
                            1 => 0,
                            2 => @intCast((i * 11 + 3) % 16),
                            4 => 2,
                            else => 3,
                        };
                    }
                }
                for (workspace.matches[0..size], 0..) |*matches, position| {
                    matches.count = 0;
                    const available = @min(258, size - position);
                    if (available < 3 or (pattern == 0 and size != 65535)) continue;
                    if (pattern == 3 and position % 4 == 0) continue;
                    const maximum = if (pattern == 2) 3 else if (pattern == 5) 3 + (position * 17 +
                        11) % (available - 2) else available;
                    const count = if (pattern < 3) 1 else if (pattern == 5) 1 + position * 7919 %
                        @min(
                            alternatives,
                            maximum - 2,
                        ) else @min(alternatives, maximum - 2);
                    for (matches.items[0..count], 0..) |*match, i| {
                        const length = if (count == 1) maximum else if (pattern >= 6 and i + 1 <
                            count) 3 + (maximum - 3) * (i / 2) / (count / 2) else 3 + (maximum -
                            3) * i / (count - 1);
                        match.* = .{
                            .length = @intCast(length),
                            .distance = if (pattern == 4) @intCast(
                                1 + i * 100,
                            ) else if (pattern >= 6) @intCast(
                                if (pattern % 2 == 0) 1 + i else count - i,
                            ) else @as(u16, 1) << @intCast(if (pattern == 5) count - 1 - i else i),
                        };
                    }
                    matches.count = @intCast(count);
                }
                try Reference.check(.full, &encoder, &literal, &distance);
                @memcpy(full_choices[0..size], workspace.choices[0..size]);
                try Reference.check(.reduced, &encoder, &literal, &distance);
                @memcpy(reduced_choices[0..size], workspace.choices[0..size]);
                try Reference.check(.maximum_lengths, &encoder, &literal, &distance);
                for (workspace.choices[0..size], 0..) |choice, index| {
                    const pairs = .{
                        .{ full_choices[index], reduced_choices[index] },
                        .{ full_choices[index], choice },
                        .{ reduced_choices[index], choice },
                    };
                    inline for (pairs, 0..) |pair, pair_index| {
                        if (!differences[pair_index] and !std.meta.eql(pair[0], pair[1])) {
                            differences[pair_index] = true;
                        }
                    }
                }
                if (pattern == 2 and pricing == 4) {
                    for (workspace.choices[0..size]) |choice| {
                        try std.testing.expectEqual(@as(u16, 0), choice.length);
                    }
                }
                if (size == 259 and pattern == 5 and pricing == 2) {
                    const units = encoder.counts().work_units;
                    for ([_]u64{ units, units - 1 }) |budget| {
                        try encoder.reset(workspace, .{ .limits = .{ .work_units = budget } });
                        encoder.history = window_bytes;
                        encoder.buffered = size;
                        if (budget == units) {
                            try Reference.check(.full, &encoder, &literal, &distance);
                        } else {
                            try std.testing.expectError(
                                error.LimitExceeded,
                                borrows.parser(
                                    &encoder,
                                ).priceParse(true, .full, &literal, &distance),
                            );
                            try std.testing.expect(encoder.counts().work_units < units);
                        }
                    }
                }
            }
        }
    }
    try std.testing.expect(differences[0] and differences[1] and differences[2]);
    // Period-256 data makes both distances real matches. Uniform and changing literal prices,
    // distance boundaries, and multiple alternatives exercise both reuse and fallback.
    for (0..4) |pattern| {
        try encoder.reset(workspace, .{});
        encoder.history = window_bytes;
        encoder.buffered = 4096;
        for (workspace.data[0 .. window_bytes + encoder.buffered], 0..) |*byte, position| {
            byte.* = @truncate(position);
        }
        literal.widths = @splat(13);
        literal.widths[285] = 1;
        if (pattern == 1) literal.widths[0] = 12;
        distance.widths = @splat(1);
        for (workspace.matches[0..encoder.buffered], 0..) |*matches, position| {
            const maximum = @min(258, encoder.buffered - position);
            matches.count = if (maximum < 3) 0 else 1;
            matches.items[0] = .{
                .length = @intCast(maximum),
                .distance = if (pattern == 2 and position / 1024 % 2 == 0) 512 else 256,
            };
            if (pattern == 3 and position == 2048) {
                matches.count = 2;
                matches.items[0] = .{ .length = 3, .distance = 256 };
                matches.items[1] = .{ .length = @intCast(maximum), .distance = 512 };
            }
        }
        try Reference.check(.full, &encoder, &literal, &distance);
        const full = encoder.counts().work_units;
        if (pattern == 0) {
            // Prove that the chosen input enters reuse and that every copied row agrees with the
            // independently computed parse, including literal values and equal-price ties.
            const costs = try std.testing.allocator.dupe(u32, workspace.costs[0..4097]);
            defer std.testing.allocator.free(costs);
            const choices = try std.testing.allocator.dupe(Token, workspace.choices[0..4096]);
            defer std.testing.allocator.free(choices);
            var prices: [286]u32 = undefined;
            for (&prices, literal.widths) |*price, width| price.* = if (width == 0) 13 else width;
            var run = RepeatedCostState.find(&borrows.parser(&encoder), 3500, &prices);
            var position: usize = 3500;
            var copied = false;
            while (position > run.first and run.maximum != 0) {
                position -= 1;
                encoder.stats = .{};
                const prior = run;
                const first = try run.reuse(&borrows.parser(&encoder), position);
                if (first < position) {
                    @memset(std.mem.sliceAsBytes(workspace.costs[first..position]), 0xa5);
                    @memset(std.mem.sliceAsBytes(workspace.choices[first..position]), 0xa5);
                    run = prior;
                    encoder.stats = .{};
                    try std.testing.expectEqual(
                        first,
                        try run.reuse(&borrows.parser(&encoder), position),
                    );
                    try std.testing.expectEqualSlices(
                        u32,
                        costs[first..position],
                        workspace.costs[first..position],
                    );
                    try std.testing.expectEqualSlices(
                        Token,
                        choices[first..position],
                        workspace.choices[first..position],
                    );
                    copied = true;
                    break;
                }
            }
            try std.testing.expect(copied);
        }
        for ([_]u64{ 0, 98943, 98944, 98945, full / 2, full - 1, full }) |budget| {
            var admitted: u64 = 0;
            var position = encoder.buffered;
            while (position != 0) {
                position -= 1;
                const matches = &workspace.matches[position];
                const edges = if (matches.count == 0) 0 else matches.items[matches.count - 1]
                    .length - 2;
                if (edges > budget - admitted) break;
                admitted += edges;
            }
            encoder.stats = .{};
            encoder.options.limits.work_units = budget;
            @memset(std.mem.sliceAsBytes(workspace.costs[0 .. encoder.buffered + 1]), 0xa5);
            @memset(std.mem.sliceAsBytes(workspace.choices[0..encoder.buffered]), 0xa5);
            const result = borrows.parser(&encoder).priceParse(true, .full, &literal, &distance);
            if (budget < full) {
                try std.testing.expectError(error.LimitExceeded, result);
            } else _ = try result;
            try std.testing.expectEqual(admitted, encoder.counts().work_units);
            try std.testing.expectEqual(admitted, encoder.counts().parse_edges);
        }
        // Scalar accounting of the failing row verifies work-limit priority and the publication
        // order when the edge counter, rather than the work budget, is exhausted.
        for ([_]bool{ false, true }) |edge_overflow| {
            const initial: EncodeStats = if (edge_overflow) .{
                .parse_edges = std.math.maxInt(u64) - full / 2,
            } else .{ .work_units = std.math.maxInt(u64) - full / 2 };
            var expected = initial;
            var position = encoder.buffered;
            while (position != 0) {
                position -= 1;
                const matches = &workspace.matches[position];
                const edges: u64 = if (matches.count == 0) 0 else matches.items[matches.count - 1]
                    .length - 2;
                if (edges > std.math.maxInt(u64) - expected.work_units) break;
                expected.work_units += edges;
                if (edges > std.math.maxInt(u64) - expected.parse_edges) break;
                expected.parse_edges += edges;
            }
            encoder.stats = initial;
            encoder.options.limits.work_units = std.math.maxInt(u64);
            try std.testing.expectError(
                if (edge_overflow) error.CounterOverflow else error.LimitExceeded,
                borrows.parser(&encoder).priceParse(true, .full, &literal, &distance),
            );
            try std.testing.expectEqualDeep(expected, encoder.counts());
        }
    }
    // Real repeated input produces a coalesced one-match row, entering the single-match path. Check
    // its parse against the independent exhaustive oracle, including finite boundaries.
    try encoder.reset(workspace, .{ .compression = .{ .level = 9 } });
    encoder.buffered = 512;
    for (workspace.data[0..encoder.buffered], 0..) |*byte, i| byte.* = "abcdefgh"[i % 8];
    try borrows.search(&encoder).findOfflineTreeMatchesStandalone();
    try std.testing.expectEqual(1, workspace.matches[8].count);
    try std.testing.expectEqual(
        Match{ .length = 258, .distance = 8 },
        workspace.matches[8].items[0],
    );
    fixedBook(&literal, false);
    fixedBook(&distance, true);
    for ([_]u8{ 0, 1, 7 }) |width| {
        @memset(&distance.widths, width);
        try Reference.check(.full, &encoder, &literal, &distance);
    }
    const repeated_work = encoder.counts().work_units;
    encoder.stats = .{};
    encoder.options.limits.work_units = repeated_work - 1;
    try std.testing.expectError(
        error.LimitExceeded,
        borrows.parser(&encoder).priceParse(true, .full, &literal, &distance),
    );
    encoder.options.limits.work_units = repeated_work;
    try Reference.check(.full, &encoder, &literal, &distance);

    var costs: [40]u32 = undefined;
    for (0..4) |pattern| {
        for (&costs, 0..) |*cost, i| {
            cost.* = switch (pattern) {
                0 => @intCast(i),
                1 => @intCast(costs.len - i),
                2 => std.math.maxInt(u32),
                else => @intCast((i * 123457 + i / 13) % 7),
            };
        }
        for (0..8) |offset| {
            for (1..33) |length| {
                const values = costs[offset..][0..length];
                var expected: usize = 0;
                for (values, 0..) |cost, i| {
                    if (cost < values[expected]) expected = i;
                }
                try std.testing.expectEqual(expected, minimumCostIndex(values));
            }
        }
    }
}

test "offline pricing selects among retained distance prices" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, .{});
    encoder.history = window_bytes;
    encoder.buffered = 4;
    @memset(workspace.data[0 .. window_bytes + 4], 'A');
    for (workspace.matches[0..4]) |*matches| matches.count = 0;
    workspace.matches[0].count = 2;
    workspace.matches[0].items[0] = .{ .length = 3, .distance = 1 };
    workspace.matches[0].items[1] = .{ .length = 4, .distance = 32768 };
    var literal: HuffmanCodebook = undefined;
    var distance: HuffmanCodebook = undefined;
    literal.widths = @splat(10);
    literal.widths[257] = 1;
    literal.widths[258] = 15;
    distance.widths = @splat(15);
    distance.widths[29] = 1;

    _ = try borrows.parser(&encoder).priceParse(false, .full, &literal, &distance);
    try std.testing.expectEqual(Token{ .length = 3, .value = 32768 }, workspace.choices[0]);
    const full_cost = workspace.costs[0];
    encoder.stats = .{};
    _ = try borrows.parser(&encoder).priceParse(false, .reduced, &literal, &distance);
    try std.testing.expectEqual(Token{ .length = 3, .value = 1 }, workspace.choices[0]);
    try std.testing.expect(full_cost < workspace.costs[0]);
}

test "pricing reuse prefilter preserves strict run boundaries" {
    var rows: [522]MatchCandidates = undefined;
    for ([_]usize{ 35, 258 }) |length| {
        for ([_]usize{ 0, 3 }) |prefix| {
            for ([_]usize{ 2 * length - 1, 2 * length, 2 * length + 1 }) |count| {
                for (&rows) |*row| row.count = 0;
                for (rows[prefix..][0..count]) |*row| {
                    row.count = 1;
                    row.items[0] = .{ .length = @intCast(length), .distance = 7 };
                }
                // Price equality can split a metadata run but cannot produce one. Strictly more
                // than twice the maximum length is necessary regardless of run position.
                try std.testing.expectEqual(count > 2 * length, mayReusePricing(&rows));
                if (count <= 2 * length) continue;
                const middle = prefix + count / 2;
                rows[middle].items[0].distance = 8;
                try std.testing.expect(!mayReusePricing(&rows));
                rows[middle].items[0].distance = 7;
                rows[middle].items[0].length -= 1;
                try std.testing.expect(!mayReusePricing(&rows));
                rows[middle].items[0].length += 1;
                rows[middle].count = 2;
                try std.testing.expect(!mayReusePricing(&rows));
                rows[middle].count = 0;
                try std.testing.expect(!mayReusePricing(&rows));
            }
        }
    }
}

test "pricing prefilter admits real runs and permits price false positives" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, .{});
    encoder.history = 0;
    encoder.buffered = 71;
    for (workspace.matches[0..encoder.buffered], 0..) |*row, position| {
        row.count = 1;
        row.items[0] = .{ .length = 35, .distance = 7 };
        workspace.data[position] = if (position % 2 == 0) 'A' else 'B';
    }
    var prices: [286]u32 = @splat(3);
    const matches = workspace.matches[0..encoder.buffered];
    try std.testing.expect(mayReusePricing(matches));
    // A long run with equal literal prices can trigger actual reuse; changing literal prices can
    // split the same metadata run. The prefilter deliberately keeps this safe false positive.
    try std.testing.expect(
        RepeatedCostState.find(&borrows.parser(&encoder), 70, &prices).maximum != 0,
    );
    prices['B'] = 4;
    try std.testing.expectEqual(
        @as(usize, 0),
        RepeatedCostState.find(&borrows.parser(&encoder), 70, &prices).maximum,
    );
    try std.testing.expect(mayReusePricing(matches));
}
