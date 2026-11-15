//! A dynamic block carries code widths so the decoder can reconstruct its payload codebooks. This
//! header describes the concatenated literal/length and distance widths using code-length literals
//! and repeat symbols. These runs repeat width entries, rather than source bytes. Four
//! deterministic pricing trials choose the cheapest serialized description.

const std = @import("std");
const protocol = @import("format.zig");
const HuffmanCodebook = @import("HuffmanCodebook.zig");
const EncodeWorkBudget = @import("EncodeWorkBudget.zig");
const precode_order = protocol.precode_order;
const test_encoding = @import("encode.zig");
const borrows = @import("block_borrows.zig");
const Encoder = test_encoding.StreamEncoder;
const EncoderWorkspace = @import("EncodeWorkspace.zig");
const EncodeStats = test_encoding.Stats;
const encode = test_encoding.into;

const DynamicBlockHeader = @This();

/// Literal/length payload codes, including end-of-block symbol 256.
literal: HuffmanCodebook,
/// Distance payload codes; only the first thirty symbols are used.
distance: HuffmanCodebook,
/// Codes for the nineteen code-length literal/repeat symbols.
precode: HuffmanCodebook,
/// Selected description of the concatenated literal/length and distance widths.
runs: [316]Run,
/// Initialized prefix of runs.
run_count: usize,
/// Literal/length widths written to the header, including required trailing entries.
literal_count: usize,
/// Distance widths written to the header, including at least one entry.
distance_count: usize,
/// Precode widths written in RFC order, including at least four entries.
precode_count: usize,
/// Serialized header cost excluding the three block-kind/final bits and payload.
bits: u32,

pub const Run = struct {
    /// Width literal 0..15 or repeat code 16..18.
    symbol: u8,
    /// Encoded repeat count after subtracting that symbol's minimum; zero for a width literal.
    extra: u8,
};

pub const RunChoice = struct {
    /// Code-length literal or repeat symbol selected at this width position.
    symbol: u8,
    /// Width entries consumed by that symbol, from one through 138.
    take: u8,
};

/// Describes the initialized literal/length and distance books in header. Trial must be a distinct
/// header reservation; scratch is shared only between sequential codebook builds. Success retains
/// the cheapest trial description. Work refusal may leave both reservations partially changed.
pub fn build(
    header: *DynamicBlockHeader,
    trial: *DynamicBlockHeader,
    scratch: *HuffmanCodebook.Scratch,
    work: EncodeWorkBudget,
) EncodeWorkBudget.Error!void {
    header.literal_count = 286;
    while (header.literal_count > 257) {
        if (header.literal.widths[header.literal_count - 1] != 0) break;
        header.literal_count -= 1;
    }
    header.distance_count = 30;
    while (header.distance_count > 1) {
        if (header.distance.widths[header.distance_count - 1] != 0) break;
        header.distance_count -= 1;
    }
    var widths: [316]u8 = undefined;
    @memcpy(widths[0..header.literal_count], header.literal.widths[0..header.literal_count]);
    @memcpy(
        widths[header.literal_count..][0..header.distance_count],
        header.distance.widths[0..header.distance_count],
    );
    const size = header.literal_count + header.distance_count;
    var prices: [19]u16 = @splat(4);
    var best_bits: u32 = std.math.maxInt(u32);
    var previous_run_count: usize = 0;
    var previous_work: u64 = 0;
    // Reprice code-length runs with each trial precode, keeping the cheapest serialized header.
    for (0..4) |pass| {
        const work_before = work.stats.work_units;
        var choices: [316]RunChoice = undefined;
        _ = priceRuns(widths[0..size], &prices, choices[0..size]);
        var frequencies: [19]u32 = @splat(0);
        var position: usize = 0;
        var unchanged = pass != 0;
        trial.run_count = 0;
        while (position < size) {
            const choice = choices[position];
            const extra: u8 = switch (choice.symbol) {
                16, 17 => choice.take - 3,
                18 => choice.take - 11,
                else => 0,
            };
            const run: Run = .{ .symbol = choice.symbol, .extra = extra };
            if (unchanged and trial.run_count < previous_run_count) {
                const previous = trial.runs[trial.run_count];
                unchanged = run.symbol == previous.symbol and run.extra == previous.extra;
            } else unchanged = false;
            trial.runs[trial.run_count] = run;
            frequencies[choice.symbol] += 1;
            trial.run_count += 1;
            position += choice.take;
        }
        // Identical runs produce the same precode and future prices. Reuse the remaining trials
        // only when their exact logical charges fit; otherwise execute them to preserve partial
        // failure counts. Each trial's work is bounded by 316 widths.
        if (unchanged and trial.run_count == previous_run_count) {
            const remaining: u64 = @intCast(4 - pass);
            const units = previous_work * remaining;
            if (units <= work.limit -| work.stats.work_units) {
                try work.admit(units);
                return;
            }
        }
        try trial.precode.build(&frequencies, 7, scratch, work);
        trial.precode_count = 19;
        while (trial.precode_count > 4) {
            const symbol = precode_order[trial.precode_count - 1];
            if (trial.precode.widths[symbol] != 0) break;
            trial.precode_count -= 1;
        }
        trial.bits = @intCast(14 + trial.precode_count * 3);
        for (trial.runs[0..trial.run_count]) |run| {
            trial.bits += @as(u32, trial.precode.widths[run.symbol]) + runExtra(run.symbol);
        }
        if (trial.bits < best_bits) {
            best_bits = trial.bits;
            header.bits = trial.bits;
            header.precode = trial.precode;
            header.precode_count = trial.precode_count;
            header.run_count = trial.run_count;
            @memcpy(header.runs[0..header.run_count], trial.runs[0..header.run_count]);
        }
        for (&prices, trial.precode.widths[0..19]) |*price, width| {
            price.* = if (width == 0) 7 else width;
        }
        // Charge the same logical edge bound even when range minima avoid visiting each edge.
        try work.admit(size * 138);
        previous_run_count = trial.run_count;
        previous_work = work.stats.work_units - work_before;
    }
}

// Minimum suffix cost for a range whose endpoints move backward one position at a time. Entries
// descend by position and increase by cost. Equal costs keep the newer, shorter repeat.
const ZeroRunSuffixMinimum = struct {
    positions: [128]u16 = undefined,
    first: usize = 0,
    count: usize = 0,

    fn add(self: *ZeroRunSuffixMinimum, costs: []const u32, first: usize, last: usize) usize {
        while (self.count != 0 and self.positions[self.first] > last) {
            self.first = (self.first + 1) % self.positions.len;
            self.count -= 1;
        }
        while (self.count != 0) {
            const tail = (self.first + self.count - 1) % self.positions.len;
            if (costs[self.positions[tail]] < costs[first]) break;
            self.count -= 1;
        }
        std.debug.assert(self.count < self.positions.len);
        self.positions[(self.first + self.count) % self.positions.len] = @intCast(first);
        self.count += 1;
        return self.positions[self.first];
    }
};

/// Finds the cheapest description of at most 316 code widths under the supplied symbol prices.
/// Widths are in 0..15 and choices has at least widths.len entries. Each choice includes the cost
/// of the remaining suffix; strict improvements preserve literal-first and shorter-repeat ties.
pub fn priceRuns(widths: []const u8, prices: *const [19]u16, choices: []RunChoice) u32 {
    var costs: [317]u32 = undefined;
    costs[widths.len] = 0;
    var zeros: ZeroRunSuffixMinimum = .{};
    var same: usize = 0;
    var position = widths.len;
    while (position != 0) {
        position -= 1;
        const value = widths[position];
        if (same != 0 and widths[position + 1] == value) {
            same = @min(same + 1, 138);
        } else {
            same = 1;
            zeros = .{};
        }
        var cost: u32 = prices[value] + costs[position + 1];
        var choice: RunChoice = .{ .symbol = value, .take = 1 };
        const repeats_previous = position != 0 and widths[position - 1] == value;
        inline for (.{ @as(u8, 16), 17 }) |symbol| {
            const allowed = if (symbol == 16) repeats_previous else value == 0;
            if (allowed) {
                const maximum = @min(same, if (symbol == 16) @as(usize, 6) else 10);
                const repeat_bits = prices[symbol] + @as(u32, runExtra(symbol));
                var take: usize = 3;
                while (take <= maximum) : (take += 1) {
                    const candidate = repeat_bits + costs[position + take];
                    if (candidate < cost) {
                        cost = candidate;
                        choice = .{ .symbol = symbol, .take = @intCast(take) };
                    }
                }
            }
        }
        if (value == 0 and same >= 11) {
            // Every repeat of 11..138 zeros has the same symbol/extra price. Query the exact
            // cheapest suffix instead of scanning all 128 edges at each position.
            const end = zeros.add(&costs, position + 11, position + same);
            const candidate = prices[18] + @as(u32, runExtra(18)) + costs[end];
            if (candidate < cost) {
                cost = candidate;
                choice = .{ .symbol = 18, .take = @intCast(end - position) };
            }
        }
        costs[position] = cost;
        choices[position] = choice;
    }
    return costs[0];
}

pub fn runExtra(symbol: u8) u6 {
    return switch (symbol) {
        16 => 2,
        17 => 3,
        18 => 7,
        else => 0,
    };
}

fn testMakeBook(
    encoder: anytype,
    frequencies: []const u32,
    maximum: u8,
    book: *HuffmanCodebook,
) EncodeWorkBudget.Error!void {
    return book.build(frequencies, maximum, &encoder.workspace.huffman, borrows.work(encoder));
}
fn testMakeHeader(encoder: anytype) EncodeWorkBudget.Error!void {
    return encoder.workspace.header.build(
        &encoder.workspace.header_trial,
        &encoder.workspace.huffman,
        borrows.work(encoder),
    );
}

test "header run minima preserve exhaustive prices repeat bounds and tie choices" {
    const Reference = struct {
        fn check(widths: []const u8, prices: *const [19]u16) !void {
            var actual: [316]RunChoice = undefined;
            const actual_cost = priceRuns(widths, prices, actual[0..widths.len]);
            var costs: [317]u32 = undefined;
            costs[widths.len] = 0;
            var position = widths.len;
            while (position != 0) {
                position -= 1;
                const value = widths[position];
                var cost: u32 = prices[value] + costs[position + 1];
                var choice: RunChoice = .{ .symbol = value, .take = 1 };
                var same: usize = 1;
                while (same < 138 and position + same < widths.len) : (same += 1) {
                    if (widths[position + same] != value) break;
                }
                for (16..19) |symbol| {
                    if (symbol == 16) {
                        if (position == 0 or widths[position - 1] != value) continue;
                    } else if (value != 0) continue;
                    const minimum: usize = if (symbol == 18) 11 else 3;
                    const maximum = @min(same, switch (symbol) {
                        16 => @as(usize, 6),
                        17 => 10,
                        else => 138,
                    });
                    var take = minimum;
                    while (take <= maximum) : (take += 1) {
                        const candidate = prices[symbol] + @as(
                            u32,
                            runExtra(@intCast(symbol)),
                        ) + costs[position + take];
                        if (candidate < cost) {
                            cost = candidate;
                            choice = .{ .symbol = @intCast(symbol), .take = @intCast(take) };
                        }
                    }
                }
                costs[position] = cost;
                try std.testing.expectEqual(choice, actual[position]);
            }
            try std.testing.expectEqual(costs[0], actual_cost);
        }
    };
    var widths: [316]u8 = undefined;
    for (0..6) |pricing| {
        var prices: [19]u16 = @splat(if (pricing == 0) 1 else 7);
        if (pricing >= 2) prices[pricing + 13] = 1;
        if (pricing == 5) prices[0] = 1;
        // Every short sequence over zero, the narrowest width and the widest width. Equal prices
        // exercise literal/earlier-symbol/shorter-repeat tie order independently.
        var combinations: usize = 1;
        for (0..9) |size| {
            for (0..combinations) |combination| {
                var remaining = combination;
                for (widths[0..size]) |*width| {
                    width.* = ([_]u8{ 0, 1, 15 })[remaining % 3];
                    remaining /= 3;
                }
                try Reference.check(widths[0..size], &prices);
            }
            combinations *= 3;
        }
        // Visit both sides of every repeat boundary, including runs longer than 138 and width
        // changes that retire the previous run's minimum queue.
        for (0..317) |size| {
            @memset(&widths, 0);
            try Reference.check(widths[0..size], &prices);
            @memset(&widths, 15);
            try Reference.check(widths[0..size], &prices);
            for (&widths, 0..) |*width, i| {
                width.* = if (i % 149 < 139) 0 else @intCast(i % 16);
            }
            try Reference.check(widths[0..size], &prices);
        }
    }
    // Arbitrary suffix costs also force a full 128-entry queue, expiry, wrap and equal minima.
    var costs: [317]u32 = undefined;
    for (0..4) |pattern| {
        for (&costs, 0..) |*cost, i| {
            cost.* = switch (pattern) {
                0 => @intCast(i),
                1 => @intCast(costs.len - i),
                2 => 7,
                else => @intCast((i * 123457 + i / 13) % 31),
            };
        }
        var queue: ZeroRunSuffixMinimum = .{};
        var position: usize = 306;
        while (position != 0) {
            position -= 1;
            const first = position + 11;
            const last = @min(position + 138, costs.len - 1);
            var expected = first;
            for (first + 1..last + 1) |i| {
                if (costs[i] < costs[expected]) expected = i;
            }
            try std.testing.expectEqual(expected, queue.add(&costs, first, last));
        }
    }
}

test "header repricing preserves exact finite work admission" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, .{});
    var frequencies: [286]u32 = @splat(0);
    frequencies['a'] = 23;
    frequencies['b'] = 7;
    frequencies[256] = 1;
    try testMakeBook(&encoder, &frequencies, 15, &workspace.header.literal);
    try testMakeBook(&encoder, &.{1}, 15, &workspace.header.distance);
    const literal = workspace.header.literal;
    const distance = workspace.header.distance;
    encoder.stats = .{};
    try testMakeHeader(&encoder);
    const expected = workspace.header;
    const counts = encoder.counts();
    try std.testing.expect(counts.work_units >= 4 * 258 * 138);
    for ([_]u64{ counts.work_units, counts.work_units - 1 }) |budget| {
        try encoder.reset(workspace, .{ .limits = .{ .work_units = budget } });
        workspace.header.literal = literal;
        workspace.header.distance = distance;
        if (budget == counts.work_units) {
            try testMakeHeader(&encoder);
            try std.testing.expectEqual(counts, encoder.counts());
            try std.testing.expectEqual(expected.bits, workspace.header.bits);
            try std.testing.expectEqual(expected.run_count, workspace.header.run_count);
            try std.testing.expectEqualSlices(
                Run,
                expected.runs[0..expected.run_count],
                workspace.header.runs[0..workspace.header.run_count],
            );
        } else {
            try std.testing.expectError(error.LimitExceeded, testMakeHeader(&encoder));
            try std.testing.expect(encoder.counts().work_units < budget);
        }
    }
}

test "header trial reuse preserves exhaustive runs serialized ties and every work boundary" {
    const Reference = struct {
        // Enumerate every legal repeat edge, independently of priceRuns and trial convergence. The
        // unchanged package-merge builder supplies the precode; always execute all four trials.
        fn build(encoder: *Encoder, charges: *[8]u64, same: *u4) !void {
            const header = &encoder.workspace.header;
            header.literal_count = 257;
            for (header.literal.widths, 0..) |width, i| {
                if (width != 0) header.literal_count = @max(header.literal_count, i + 1);
            }
            header.distance_count = 1;
            for (header.distance.widths[0..30], 0..) |width, i| {
                if (width != 0) header.distance_count = i + 1;
            }
            var widths: [316]u8 = undefined;
            @memcpy(
                widths[0..header.literal_count],
                header.literal.widths[0..header.literal_count],
            );
            @memcpy(
                widths[header.literal_count..][0..header.distance_count],
                header.distance.widths[0..header.distance_count],
            );
            const size = header.literal_count + header.distance_count;
            var prices: [19]u16 = @splat(4);
            var best: u32 = std.math.maxInt(u32);
            var previous: [316]Run = undefined;
            var previous_count: usize = 0;
            for (0..4) |pass| {
                var costs: [317]u32 = undefined;
                var choices: [316]RunChoice = undefined;
                costs[size] = 0;
                var position = size;
                while (position != 0) {
                    position -= 1;
                    const value = widths[position];
                    costs[position] = prices[value] + costs[position + 1];
                    choices[position] = .{ .symbol = value, .take = 1 };
                    for (16..19) |symbol| {
                        if (symbol == 16) {
                            if (position == 0 or widths[position - 1] != value) continue;
                        } else if (value != 0) continue;
                        const first: usize = if (symbol == 18) 11 else 3;
                        const last: usize = switch (symbol) {
                            16 => 6,
                            17 => 10,
                            else => 138,
                        };
                        var take: usize = 1;
                        while (take <= last and position + take <= size) : (take += 1) {
                            if (widths[position + take - 1] != value) break;
                            if (take < first) continue;
                            const extra: u32 = switch (symbol) {
                                16 => 2,
                                17 => 3,
                                else => 7,
                            };
                            const cost = prices[symbol] + extra + costs[position + take];
                            if (cost < costs[position]) {
                                costs[position] = cost;
                                choices[position] = .{
                                    .symbol = @intCast(symbol),
                                    .take = @intCast(take),
                                };
                            }
                        }
                    }
                }
                var runs: [316]Run = undefined;
                var count: usize = 0;
                var frequencies: [19]u32 = @splat(0);
                position = 0;
                while (position < size) {
                    const choice = choices[position];
                    const extra: u8 = switch (choice.symbol) {
                        16, 17 => choice.take - 3,
                        18 => choice.take - 11,
                        else => 0,
                    };
                    runs[count] = .{ .symbol = choice.symbol, .extra = extra };
                    frequencies[choice.symbol] += 1;
                    count += 1;
                    position += choice.take;
                }
                if (pass != 0 and count == previous_count) {
                    var identical = true;
                    for (runs[0..count], previous[0..count]) |run, old| {
                        if (run.symbol != old.symbol or run.extra != old.extra) identical = false;
                    }
                    if (identical) same.* |= @as(u4, 1) << @intCast(pass);
                }
                @memcpy(previous[0..count], runs[0..count]);
                previous_count = count;
                var precode: HuffmanCodebook = undefined;
                try testMakeBook(encoder, &frequencies, 7, &precode);
                charges[pass * 2] = encoder.counts().work_units;
                const order = [_]u8{
                    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
                };
                var precode_count: usize = 4;
                for (order, 0..) |symbol, i| {
                    if (precode.widths[symbol] != 0) precode_count = @max(precode_count, i + 1);
                }
                var bits: u32 = @intCast(14 + precode_count * 3);
                for (runs[0..count]) |run| {
                    const extra: u32 = switch (run.symbol) {
                        16 => 2,
                        17 => 3,
                        18 => 7,
                        else => 0,
                    };
                    bits += precode.widths[run.symbol] + extra;
                }
                if (bits < best) {
                    best = bits;
                    header.bits = bits;
                    header.precode = precode;
                    header.precode_count = precode_count;
                    header.run_count = count;
                    @memcpy(header.runs[0..count], runs[0..count]);
                }
                for (&prices, precode.widths[0..19]) |*price, width| {
                    price.* = if (width == 0) 7 else width;
                }
                try borrows.work(encoder).admit(size * 138);
                charges[pass * 2 + 1] = encoder.counts().work_units;
            }
        }

        // RFC 1951 fields written one bit at a time, without Encoder.put/emit or runExtra.
        const Wire = struct {
            bytes: [512]u8 = @splat(0),
            bits: usize,

            fn put(self: *@This(), value: usize, width: usize) void {
                for (0..width) |bit| {
                    const shift: std.math.Log2Int(usize) = @intCast(bit);
                    const output_shift: u3 = @intCast(self.bits % 8);
                    const value_bit: u8 = @intCast((value >> shift) & 1);
                    self.bytes[self.bits / 8] |= value_bit << output_shift;
                    self.bits += 1;
                }
            }

            fn header(self: *@This(), expected: *const DynamicBlockHeader) void {
                self.put(1, 1);
                self.put(2, 2);
                self.put(expected.literal_count - 257, 5);
                self.put(expected.distance_count - 1, 5);
                self.put(expected.precode_count - 4, 4);
                const order = [_]u8{
                    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
                };
                for (
                    order[0..expected.precode_count],
                ) |symbol| self.put(expected.precode.widths[symbol], 3);
                for (expected.runs[0..expected.run_count]) |run| {
                    self.put(
                        expected.precode.codes[run.symbol],
                        expected.precode.widths[run.symbol],
                    );
                    self.put(run.extra, switch (run.symbol) {
                        16 => 2,
                        17 => 3,
                        18 => 7,
                        else => 0,
                    });
                }
                self.put(expected.literal.codes[256], expected.literal.widths[256]);
            }
        };
    };
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var state: u32 = 0x1951ca5e;
    var converged: u4 = 0;
    var changed_after_first: bool = false;
    for (0..80) |sample| {
        try encoder.reset(workspace, .{});
        var frequencies: [286]u32 = @splat(0);
        for (&frequencies, 0..) |*frequency, i| {
            state = state *% 1664525 +% 1013904223;
            const active = switch (sample % 4) {
                0 => i < sample,
                1 => i % (sample + 1) == 0,
                2 => i < 257,
                else => state % 7 < 3,
            };
            if (active) frequency.* = if (sample % 3 == 0) 1 else state % 1000 + 1;
        }
        frequencies[256] = 1;
        try testMakeBook(&encoder, &frequencies, 15, &workspace.header.literal);
        @memset(&frequencies, 0);
        for (frequencies[0..30], 0..) |*frequency, i| {
            if (sample % 4 != 0 and i <= sample % 30) frequency.* = @intCast(i + 1);
        }
        try testMakeBook(&encoder, frequencies[0..30], 15, &workspace.header.distance);
        const literal = workspace.header.literal;
        const distance = workspace.header.distance;
        encoder.stats = .{};
        var charges: [8]u64 = undefined;
        var same: u4 = 0;
        try Reference.build(&encoder, &charges, &same);
        converged |= same;
        changed_after_first = changed_after_first or same & 2 == 0;
        const expected = workspace.header;
        const total = charges[7];
        // Every charge boundary, one below and one above it, plus a counter near u64 overflow. The
        // expected refusal counter is the last wholly admitted reference charge.
        for ([_]u64{ 0, std.math.maxInt(u64) - total }) |initial| {
            for (charges) |boundary| {
                for ([_]u64{ boundary -| 1, boundary, @min(total, boundary + 1) }) |budget| {
                    try encoder.reset(
                        workspace,
                        .{ .limits = .{ .work_units = initial + budget } },
                    );
                    workspace.header.literal = literal;
                    workspace.header.distance = distance;
                    // Prior calls' scratch must not become a cross-call header cache.
                    @memset(std.mem.asBytes(&workspace.header_trial), 0xa5);
                    encoder.stats.work_units = initial;
                    var admitted: u64 = 0;
                    for (charges) |charge| {
                        if (charge > budget) break;
                        admitted = charge;
                    }
                    if (budget < total) {
                        try std.testing.expectError(error.LimitExceeded, testMakeHeader(&encoder));
                    } else {
                        try testMakeHeader(&encoder);
                        const actual = &workspace.header;
                        try std.testing.expectEqual(expected.bits, actual.bits);
                        try std.testing.expectEqual(expected.precode_count, actual.precode_count);
                        try std.testing.expectEqual(expected.run_count, actual.run_count);
                        try std.testing.expectEqual(expected.precode, actual.precode);
                        try std.testing.expectEqualSlices(
                            Run,
                            expected.runs[0..expected.run_count],
                            actual.runs[0..actual.run_count],
                        );
                    }
                    try std.testing.expectEqual(
                        EncodeStats{ .work_units = initial + admitted },
                        encoder.counts(),
                    );
                }
            }
        }
        for (0..8) |offset| {
            try encoder.reset(workspace, .{});
            workspace.header.literal = literal;
            workspace.header.distance = distance;
            try testMakeHeader(&encoder);
            encoder.bit_count = @intCast(offset);
            var wire: Reference.Wire = .{ .bits = offset };
            wire.header(&expected);
            try borrows.writer(
                &encoder,
            ).emit(
                &encoder.workspace.header,
                &.{},
                .{ .first = 0, .end = 0, .start = 0, .bytes = 0 },
                .dynamic,
                true,
            );
            borrows.writer(&encoder).alignBits();
            try std.testing.expectEqual((wire.bits + 7) / 8, encoder.pending);
            try std.testing.expectEqualSlices(
                u8,
                wire.bytes[0..encoder.pending],
                workspace.wire[0..encoder.pending],
            );
        }
    }
    try std.testing.expect(changed_after_first);
    try std.testing.expectEqual(@as(u4, 0b1110), converged);
}
