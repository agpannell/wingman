//! High-compression (HC) LZ4 encoding searches prior matches and prices sequences by their exact
//! serialized byte cost. It produces ordinary LZ4 blocks; no special decoder is needed. This
//! implementation uses a 2 KiB parsing horizon, one path per position, and a long-match shortcut.
//! It does not claim global optimality. Algorithm references: LZ4 1.10.0 lib/lz4hc.c
//! (BSD-2-Clause), especially LZ4HC_literalsPrice, LZ4HC_sequencePrice and its bounded optimal
//! parser.

const std = @import("std");
const overlaps = @import("../common/byte_ranges.zig").overlaps;

const encoding = @import("block_encode.zig");
const test_decoding = @import("block_recovery.zig"); // Inline recovery comparisons only.
const Writer = @import("BlockWriter.zig");
const maximum_distance = @import("block.zig").maximum_distance;

/// Dictionary-free search policy. Its allowance covers the enclosing raw call or every HC block in
/// one frame, including repeated dictionary priming and stored fallbacks.
pub const Policy = struct {
    /// Search budgets, independent of upstream compression level numbers.
    pub const Profile = enum {
        /// Shallower search, with at most 128 chain probes per position.
        balanced,
        /// Deeper search for smaller output, with at most 4096 probes per position.
        offline,
    };

    /// Size prices only serialized bytes; throughput also prices each match and short overlapping
    /// copies. This is a heuristic, not a latency guarantee.
    pub const DecoderCost = enum {
        /// Minimize serialized byte cost.
        size,
        /// Also penalize match dispatch and short overlapping copies during decoding.
        throughput,
    };

    /// Per-operation search/parser admission, including dictionary priming. Each insertion,
    /// eligible chain probe and parser edge costs one unit. A probe includes its initial four-byte
    /// prefix check; each additional endpoint-word, extension-word or byte comparison costs one,
    /// even on a mismatch. Hashing, table clearing, path reconstruction and wire writing are
    /// outside this unit model.
    pub const Limits = struct {
        /// Maximum admitted units; exhaustion returns LimitExceeded before the next charged
        /// operation.
        work_units: u64 = std.math.maxInt(u64),
    };

    /// Search depth/long-match policy, independent of upstream numeric compression levels.
    profile: Profile = .offline,
    /// Serialized-size pricing alone or a heuristic penalty for costly decoded matches.
    decoder_cost: DecoderCost = .size,
    /// Operation-wide search/parser allowance.
    limits: Limits = .{},
};

/// Dictionary and search policy for one complete high-compression block.
pub const Options = struct {
    /// Immutable initial history, trimmed to its reachable 65,535-byte suffix.
    dictionary: []const u8 = &.{},
    /// Dictionary-free search choices and allowance for this complete call.
    policy: Policy = .{},
};

/// Copied effort and format statistics, reset on each admitted operation.
pub const Stats = struct {
    /// Admitted search and parser units under Policy.Limits.
    work_units: u64 = 0,
    /// Eligible chain candidates examined, including their initial prefix checks.
    probes: u64 = 0,
    /// Match sequences emitted before the final literal sequence.
    sequences: u64 = 0,
};

/// HC resource failures in addition to the ordinary block contract.
pub const Error = encoding.Error || error{LimitExceeded};

const horizon = 2048;
const hashes = 32768;
// Cheapest path to a byte position in the active parsing horizon. A literal edge has match zero; a
// match edge records its decoded length and backward distance. Previous indexes the predecessor
// within this horizon; literals counts that path's pending run after its preceding match edge.
const Node = struct { price: u32, literals: u32, previous: u16, match: u16, distance: u16 };

/// Fixed, address-stable HC scratch. No input or allocator is retained. The greedy encoder's 16 KiB
/// `block.encode.Workspace` is separate from this scratch.
pub const Workspace = struct {
    /// Internal one-based latest position for each four-byte hash.
    heads: [hashes]u32,
    /// Internal predecessor links indexed by the low sixteen position bits.
    chains: [65536]u32,
    /// Internal cheapest parser state for each byte of the active horizon.
    nodes: [horizon + 1]Node,
    /// Internal reverse predecessor walk, reused while emitting the selected parse.
    path: [horizon]u16,
    /// Read-only statistics for the last admitted operation, including partial work on failure.
    stats: Stats,

    /// Allocates scratch at its final address; `into` initializes it.
    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*Workspace {
        return allocator.create(Workspace);
    }

    /// Releases scratch through its construction authority.
    pub fn destroy(self: *Workspace, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    /// Erases retained source-derived tables and statistics after final use.
    pub fn clear(self: *Workspace) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }

    fn charge(self: *Workspace, amount: u64, limit: u64) Error!void {
        if (amount > limit - self.stats.work_units) return error.LimitExceeded;
        self.stats.work_units += amount;
    }
};

/// Encodes an ordinary raw block using bounded HC parsing. Requires full
/// `block.encode.bound(source.len)` capacity, exact disjoint spans and no padding. Dictionary bytes
/// are borrowed for this call; only their last 65,535 bytes are used. Failure leaves output
/// unpublished; reuse is valid after any result.
pub fn into(source: []const u8, output: []u8, workspace: *Workspace, options: Options) Error![]u8 {
    const dictionary = options.dictionary;
    const bound = try encoding.bound(source.len);
    const dict = dictionary[dictionary.len - @min(dictionary.len, maximum_distance) ..];
    const scratch = std.mem.asBytes(workspace);
    if (overlaps(source, output)) return error.Aliasing;
    if (overlaps(source, scratch) or overlaps(output, scratch)) return error.Aliasing;
    if (overlaps(dict, output) or overlaps(dict, scratch)) return error.Aliasing;
    if (output.len < bound) return error.OutputTooSmall;

    workspace.stats = .{};
    @memset(&workspace.heads, 0);
    const data: Data = .{ .dictionary = dict, .source = source };
    var inserted: usize = 0;
    while (inserted < dict.len and inserted + 4 <= data.len()) : (inserted += 1) {
        try insert(&data, workspace, inserted, options.policy.limits.work_units);
    }

    // Full block encoding-bound admission covers every exact sequence write, including worst-case
    // match splits and extension bytes. Wire emission is shared with greedy encoding; parser prices
    // and the independent expected-wire fixtures do not depend on that writer.
    var writer: Writer = .{ .bytes = output };
    var cursor: usize = 0;
    var anchor: usize = 0;
    const nice: usize = switch (options.policy.profile) {
        .balanced => 64,
        .offline => 256,
    };
    const depth: usize = switch (options.policy.profile) {
        .balanced => 128,
        .offline => 4096,
    };

    // For each bounded horizon, dynamic programming keeps the cheapest path to each byte position.
    // A path can add one literal or take a match edge of any discovered length. The five-byte
    // suffix stays outside the search so emitted matches obey LZ4's final-literal rule; long
    // matches use the shortcut below to cap parser work.
    while (source.len >= 12 and cursor <= source.len - 12) {
        // Price one path to each byte within this horizon, starting with pending literals.
        const count: usize = @min(horizon, source.len - 5 - cursor);
        const pending_literals = cursor - anchor;
        const initial_price: u32 = @intCast(literalPrice(pending_literals));
        @memset(
            workspace.nodes[0 .. count + 1],
            .{
                .price = std.math.maxInt(u32),
                .literals = 0,
                .previous = 0,
                .match = 0,
                .distance = 0,
            },
        );
        workspace.nodes[0] = .{
            .price = initial_price,
            .literals = @intCast(pending_literals),
            .previous = 0,
            .match = 0,
            .distance = 0,
        };
        var terminal = count;
        var shortcut: Match = .{};
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const position = cursor + i;
            const absolute = dict.len + position;
            while (inserted < absolute) : (inserted += 1) {
                try insert(&data, workspace, inserted, options.policy.limits.work_units);
            }
            const match: Match = blk: {
                if (position > source.len - 12) break :blk .{};
                const maximum = source.len - 5 - position;
                break :blk try find(
                    &data,
                    workspace,
                    absolute,
                    maximum,
                    depth,
                    options.policy.limits.work_units,
                );
            };
            if (match.length >= nice) {
                terminal = i;
                shortcut = match;
                break;
            }
            // A literal edge adds one byte and pays only when it crosses an extension boundary.
            const node = workspace.nodes[i];
            try workspace.charge(1, options.policy.limits.work_units);
            const added_extension = extension(node.literals + 1, 15) - extension(node.literals, 15);
            const literal_byte_price: u32 = 1;
            const literal_extension_price: u32 = @intCast(added_extension);
            const next_price = node.price + literal_byte_price + literal_extension_price;
            if (next_price < workspace.nodes[i + 1].price) {
                workspace.nodes[i + 1] = .{
                    .price = next_price,
                    .literals = node.literals + 1,
                    .previous = @intCast(i),
                    .match = 0,
                    .distance = 0,
                };
            }

            var length: usize = 4;
            while (length <= @min(match.length, count - i)) : (length += 1) {
                try workspace.charge(1, options.policy.limits.work_units);
                // Decoder-cost mode penalizes short, overlapping copies heuristically.
                const penalty: u32 = blk: {
                    if (options.policy.decoder_cost != .throughput) break :blk 0;
                    const short_overlap: u32 = @intFromBool(match.distance < 8);
                    break :blk 2 + short_overlap * 2;
                };
                const match_extension: u32 = @intCast(extension(length - 4, 15));
                const sequence_header_price: u32 = 3;
                const price = node.price + sequence_header_price + match_extension + penalty;
                if (price < workspace.nodes[i + length].price) {
                    workspace.nodes[i + length] = .{
                        .price = price,
                        .literals = 0,
                        .previous = @intCast(i),
                        .match = @intCast(length),
                        .distance = match.distance,
                    };
                }
            }
        }

        // Predecessors are byte offsets relative to `cursor`. Walk the chosen path backward, then
        // emit match edges in source order; literal-only edges need no direct write because the
        // next match sequence includes every pending byte since the previous anchor.
        var path_count: usize = 0;
        var end = terminal;
        while (end != 0) {
            workspace.path[path_count] = @intCast(end);
            path_count += 1;
            end = workspace.nodes[end].previous;
        }
        while (path_count != 0) {
            path_count -= 1;
            const node = workspace.nodes[workspace.path[path_count]];
            if (node.match == 0) continue;
            const start = cursor + node.previous;
            writer.sequence(source[anchor..start], node.distance, node.match);
            workspace.stats.sequences += 1;
            anchor = start + node.match;
        }
        cursor += terminal;
        if (shortcut.length != 0) {
            writer.sequence(source[anchor..cursor], shortcut.distance, shortcut.length);
            workspace.stats.sequences += 1;
            cursor += shortcut.length;
            anchor = cursor;
        }
    }

    writer.final(source[anchor..]);
    return output[0..writer.cursor];
}

test "LZ4 HC independent block costs include comparisons and dictionary priming" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);

    // These totals count the operations in each tiny parse, independently of reported statistics.
    // Only the repeated ABCD prefix shares a searched hash slot in the mismatch case.
    const cases = [_]struct {
        source: []const u8,
        dictionary: []const u8 = &.{},
        wire: []const u8,
        work: u64,
        probes: u64 = 0,
        sequences: u64 = 0,
    }{
        .{ .source = "", .wire = "\x00", .work = 0 },
        // Six insertions and seven literal edges; only position zero is eligible for search.
        .{ .source = "ABCDEFGHIJKL", .wire = "\xc0ABCDEFGHIJKL", .work = 6 + 7 },
        // Seven insertions, eight literal edges, one probe, three compared bytes and four match
        // edges.
        .{
            .source = "AAAAAAAAAAAAA",
            .wire = "\x13A\x01\x00\x50AAAAA",
            .work = 7 + 8 + 1 + 3 + 4,
            .probes = 1,
            .sequences = 1,
        },
        // Eleven insertions, twelve literal edges, one probe, one mismatch and one match edge.
        .{
            .source = "ABCDxABCDy1234567",
            .wire = "\x50ABCDx\x05\x00\x80y1234567",
            .work = 11 + 12 + 1 + 1 + 1,
            .probes = 1,
            .sequences = 1,
        },
        // Only one complete dictionary word can be inserted without source bytes.
        .{ .source = "", .dictionary = "abcd", .wire = "\x00", .work = 1 },
        // Three source bytes permit all four dictionary starts, including boundary words.
        .{ .source = "xyz", .dictionary = "abcd", .wire = "\x30xyz", .work = 4 },
    };
    var output: [66]u8 = undefined;
    var restored: [32]u8 = undefined;
    for (cases) |case| {
        for ([_]Policy.Profile{ .balanced, .offline }) |profile| {
            var budget: u64 = 0;
            while (budget <= case.work) : (budget += 1) {
                @memset(&output, 0xa7);
                const encoded = into(
                    case.source,
                    output[1 .. output.len - 1],
                    workspace,
                    .{
                        .dictionary = case.dictionary,
                        .policy = .{ .profile = profile, .limits = .{ .work_units = budget } },
                    },
                );
                if (budget < case.work) {
                    try std.testing.expectError(error.LimitExceeded, encoded);
                    try std.testing.expectEqual(budget, workspace.stats.work_units);
                } else {
                    const wire = try encoded;
                    try std.testing.expectEqualSlices(u8, case.wire, wire);
                    try std.testing.expectEqualDeep(
                        Stats{
                            .work_units = case.work,
                            .probes = case.probes,
                            .sequences = case.sequences,
                        },
                        workspace.stats,
                    );
                    try std.testing.expect(std.mem.allEqual(u8, output[1 + wire.len ..], 0xa7));
                    _ = try test_decoding.into(
                        wire,
                        restored[0..case.source.len],
                        .{ .history = .{ .newer = case.dictionary } },
                    );
                    try std.testing.expectEqualSlices(
                        u8,
                        case.source,
                        restored[0..case.source.len],
                    );
                }
                try std.testing.expectEqual(@as(u8, 0xa7), output[0]);
                try std.testing.expectEqual(@as(u8, 0xa7), output[output.len - 1]);
            }
            // An ample allowance also exercises locally aggregated search charges.
            const wire = try into(
                case.source,
                &output,
                workspace,
                .{ .dictionary = case.dictionary, .policy = .{ .profile = profile } },
            );
            try std.testing.expectEqualSlices(u8, case.wire, wire);
            try std.testing.expectEqualDeep(
                Stats{
                    .work_units = case.work,
                    .probes = case.probes,
                    .sequences = case.sequences,
                },
                workspace.stats,
            );
        }
    }
}

const Match = struct { length: usize = 0, distance: u16 = 0 };

// Read the dictionary and source as one chronological history without copying either span.
const Data = struct {
    dictionary: []const u8,
    source: []const u8,

    fn len(self: Data) usize {
        return self.dictionary.len + self.source.len;
    }

    fn byte(self: Data, position: usize) u8 {
        if (position < self.dictionary.len) return self.dictionary[position];
        return self.source[position - self.dictionary.len];
    }

    fn word(self: Data, position: usize) u32 {
        if (position >= self.dictionary.len) {
            const bytes = self.source[position - self.dictionary.len ..][0..4];
            return std.mem.readInt(u32, bytes, .little);
        }
        if (self.dictionary.len - position >= 4) {
            return std.mem.readInt(u32, self.dictionary[position..][0..4], .little);
        }

        // This word straddles the dictionary/source boundary, so assemble it byte by byte.
        var assembled_word: u32 = 0;
        inline for (0..4) |i| {
            assembled_word |= @as(u32, self.byte(position + i)) << (i * 8);
        }
        return assembled_word;
    }
};

fn insert(data: *const Data, workspace: *Workspace, position: usize, limit: u64) Error!void {
    try workspace.charge(1, limit);
    const hash_word = data.word(position);
    const slot = (hash_word *% 0x9e3779b1) >> 17;
    workspace.chains[position & 65535] = workspace.heads[slot];
    workspace.heads[slot] = @intCast(position + 1);
}

fn find(
    data: *const Data,
    workspace: *Workspace,
    position: usize,
    maximum: usize,
    depth: usize,
    work_limit: u64,
) Error!Match {
    // A chain probe can cost at most one visit, one endpoint check and `maximum` byte comparisons.
    // When that upper bound fits, findCounted(false) accumulates exact work locally and charges it
    // once; near the budget boundary, findCounted(true) checks each unit so exhaustion is exact.
    const bound: u64 = @as(u64, depth) * (maximum + 2);
    if (bound <= work_limit - workspace.stats.work_units) {
        return findCounted(false, data, workspace, position, maximum, depth, work_limit);
    }
    return findCounted(true, data, workspace, position, maximum, depth, work_limit);
}

fn findCounted(
    comptime bounded: bool,
    data: *const Data,
    workspace: *Workspace,
    position: usize,
    maximum: usize,
    depth: usize,
    work_limit: u64,
) Error!Match {
    const current_word = data.word(position);
    const slot = (current_word *% 0x9e3779b1) >> 17;
    var link = workspace.heads[slot];
    var result: Match = .{};
    var work_units: u64 = 0;
    var visited: u64 = 0;
    defer {
        if (!bounded) workspace.stats.work_units += work_units;
        workspace.stats.probes += visited;
    }
    var probes: usize = 0;
    while (link != 0 and probes < depth) : (probes += 1) {
        // Links store position + 1 so zero remains the empty-table sentinel.
        const candidate_position: usize = link - 1;
        if (candidate_position >= position or position - candidate_position > maximum_distance)
            // Newer chain links point only to older positions, so the distance limit excludes every
            // remaining candidate as well.
            break;
        if (bounded) {
            try workspace.charge(1, work_limit);
        } else {
            work_units += 1;
        }
        visited += 1;

        // A strict improvement must match through the current best endpoint. Reject it before
        // rescanning a potentially very long shared prefix.
        if (result.length >= 4 and result.length < maximum) {
            if (bounded) {
                try workspace.charge(1, work_limit);
            } else {
                work_units += 1;
            }
            const endpoint = result.length - 3;
            if (data.word(position + endpoint) != data.word(candidate_position + endpoint)) {
                link = workspace.chains[candidate_position & 65535];
                continue;
            }
        }

        if (data.word(candidate_position) == current_word) {
            const length = extend: {
                const dictionary_end = data.dictionary.len;
                var matched: usize = 4;
                // Extensions already in source history use whole words. Dictionary-spanning
                // extensions use Data.byte below.
                while (matched + 8 <= maximum and candidate_position + matched >= dictionary_end) {
                    if (bounded) {
                        try workspace.charge(1, work_limit);
                    } else {
                        work_units += 1;
                    }
                    const current_source_position = position + matched - dictionary_end;
                    const candidate_source_position = candidate_position + matched - dictionary_end;
                    const current_bytes = data.source[current_source_position..][0..8];
                    const prior_bytes = data.source[candidate_source_position..][0..8];
                    const current_chunk = std.mem.readInt(u64, current_bytes, .little);
                    const candidate_chunk = std.mem.readInt(u64, prior_bytes, .little);
                    const unequal = current_chunk ^ candidate_chunk;
                    if (unequal != 0) {
                        // This comparison already found the first mismatch; do not read it again in
                        // the scalar tail. Little-endian XOR puts it in the low set bits.
                        break :extend matched + @ctz(unequal) / 8;
                    }
                    matched += 8;
                }
                while (matched < maximum) : (matched += 1) {
                    if (bounded) {
                        try workspace.charge(1, work_limit);
                    } else {
                        work_units += 1;
                    }
                    const current_byte = data.byte(position + matched);
                    const candidate_byte = data.byte(candidate_position + matched);
                    if (current_byte != candidate_byte) break;
                }
                break :extend matched;
            };
            if (length > result.length) {
                result = .{ .length = length, .distance = @intCast(position - candidate_position) };
            }
            if (length == maximum) break;
        }
        link = workspace.chains[candidate_position & 65535];
    }
    return result;
}

test "LZ4 HC independent search costs cover tails words and endpoint rejection" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const cases = [_]struct {
        source: []const u8,
        dictionary: []const u8 = &.{},
        position: usize,
        maximum: usize,
        candidates: []const usize = &.{0},
        match: Match,
        work: u64,
    }{
        // A probe includes the first four bytes; the failed fifth-byte check is another unit.
        .{
            .source = "ABCDx---ABCDy",
            .position = 8,
            .maximum = 5,
            .match = .{ .length = 4, .distance = 8 },
            .work = 1 + 1,
        },
        .{
            .source = "ABCDEFG-ABCDEFG",
            .position = 8,
            .maximum = 7,
            .match = .{ .length = 7, .distance = 8 },
            .work = 1 + 3,
        },
        // A failed eight-byte comparison already identifies the mismatch; no scalar recheck.
        .{
            .source = "ABCDabcdEfgh----ABCDabcdXfgh",
            .position = 16,
            .maximum = 12,
            .match = .{ .length = 8, .distance = 16 },
            .work = 1 + 1,
        },
        .{
            .source = "ABCDabcdefghx---ABCDabcdefghy",
            .position = 16,
            .maximum = 13,
            .match = .{ .length = 12, .distance = 16 },
            .work = 1 + 1 + 1,
        },
        // The prefix straddles the dictionary boundary, then two bytes match before failure.
        .{
            .dictionary = "ABC",
            .source = "ABCABCx",
            .position = 3,
            .maximum = 7,
            .match = .{ .length = 6, .distance = 3 },
            .work = 1 + 3,
        },
        // The second probe fails its endpoint word check without rescanning the prefix.
        .{
            .source = "ABCDx---ABCDy---ABCDz",
            .position = 16,
            .maximum = 5,
            .candidates = &.{ 8, 0 },
            .match = .{ .length = 4, .distance = 8 },
            .work = (1 + 1) + (1 + 1),
        },
        // The second endpoint passes and one more byte comparison improves the match.
        .{
            .source = "ABCDz---ABCDy---ABCDz",
            .position = 16,
            .maximum = 5,
            .candidates = &.{ 8, 0 },
            .match = .{ .length = 5, .distance = 16 },
            .work = (1 + 1) + (1 + 1 + 1),
        },
    };
    for (cases) |case| {
        const data: Data = .{ .dictionary = case.dictionary, .source = case.source };
        @memset(&workspace.heads, 0);
        const slot = (data.word(case.position) *% 0x9e3779b1) >> 17;
        workspace.heads[slot] = @intCast(case.candidates[0] + 1);
        for (case.candidates, 0..) |position, index| {
            workspace.chains[position & 65535] = if (index + 1 < case.candidates.len) @intCast(
                case.candidates[index + 1] + 1,
            ) else 0;
        }
        var budget: u64 = 0;
        while (budget <= case.work) : (budget += 1) {
            workspace.stats = .{};
            const result = find(
                &data,
                workspace,
                case.position,
                case.maximum,
                case.candidates.len,
                budget,
            );
            if (budget < case.work) {
                try std.testing.expectError(error.LimitExceeded, result);
                try std.testing.expectEqual(budget, workspace.stats.work_units);
            } else {
                try std.testing.expectEqualDeep(case.match, try result);
                try std.testing.expectEqual(case.work, workspace.stats.work_units);
                try std.testing.expectEqual(case.candidates.len, workspace.stats.probes);
            }
        }
        workspace.stats = .{};
        const aggregate = try find(
            &data,
            workspace,
            case.position,
            case.maximum,
            case.candidates.len,
            std.math.maxInt(u64),
        );
        try std.testing.expectEqualDeep(case.match, aggregate);
        try std.testing.expectEqual(case.work, workspace.stats.work_units);
        try std.testing.expectEqual(case.candidates.len, workspace.stats.probes);
    }
}

fn extension(length: usize, threshold: usize) usize {
    return if (length < threshold) 0 else 1 + (length - threshold) / 255;
}

fn literalPrice(length: usize) usize {
    return 1 + length + extension(length, 15);
}

test "LZ4 HC bounded parsing dictionaries budgets and clearing" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    var source: [12000]u8 = undefined;
    for (&source, 0..) |*b, i| b.* = @intCast((i *% 137 + i / 19) % 251);
    @memcpy(source[6000..], source[0..6000]);
    const output = try allocator.alloc(u8, try encoding.bound(source.len));
    defer allocator.free(output);
    var decoded: [source.len]u8 = undefined;
    for ([_]Policy.Profile{ .balanced, .offline }) |profile| {
        @memset(output, 0xa7);
        const wire = try into(
            &source,
            output,
            workspace,
            .{ .dictionary = source[0..4096], .policy = .{ .profile = profile } },
        );
        _ = try test_decoding.into(wire, &decoded, .{ .history = .{ .newer = source[0..4096] } });
        try std.testing.expectEqualSlices(u8, &source, &decoded);
        try std.testing.expect(std.mem.allEqual(u8, output[wire.len..], 0xa7));
        const work_units = workspace.stats.work_units;
        _ = try into(
            &source,
            output,
            workspace,
            .{
                .dictionary = source[0..4096],
                .policy = .{ .profile = profile, .limits = .{ .work_units = work_units } },
            },
        );
        try std.testing.expectError(
            error.LimitExceeded,
            into(
                &source,
                output,
                workspace,
                .{
                    .dictionary = source[0..4096],
                    .policy = .{ .profile = profile, .limits = .{ .work_units = work_units - 1 } },
                },
            ),
        );
    }
    try std.testing.expectError(
        error.Aliasing,
        into(source[0..20], &source, workspace, .{ .dictionary = &.{} }),
    );
    workspace.clear();
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(workspace), 0));
}
