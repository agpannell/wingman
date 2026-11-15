//! Find earlier byte sequences that can replace source bytes with backward matches. Hash chains
//! supply greedy/lazy parsing, while a prefix-aware tree retains alternatives for offline pricing.
//! Both borrow one slab and its copied history, and share one search arena.
//!
//! Tree checkpoints temporarily occupy dead pricing/token arrays. Successful search restores the
//! tree before those arrays become live; refusal leaves partial state requiring stream reset.

const std = @import("std");
const PrefixMatchTree = @import("PrefixMatchTree.zig");
const MatchCandidates = @import("MatchCandidates.zig");
const Token = @import("Lz77Parser.zig").Token;
const EncodeWorkBudget = @import("EncodeWorkBudget.zig");
const addCount = EncodeWorkBudget.addCount;
const alternatives = MatchCandidates.capacity;
const test_decoding = @import("../deflate.zig");
const test_encoding = @import("encode.zig");
const borrows = @import("block_borrows.zig");
const Encoder = test_encoding.StreamEncoder;
const EncoderWorkspace = @import("EncodeWorkspace.zig");
const EncodeOptions = test_encoding.Options;
const EncodeStatus = test_encoding.Status;
const EncodeStats = test_encoding.Stats;
const Compression = @import("Compression.zig");
const Match = @import("MatchCandidates.zig").Candidate;
const Profile = @import("compression_effort.zig").Profile;
const encode = test_encoding.into;
const encodeBound = test_encoding.bound;
const MatchFinder = @This();

const slab_bytes = 65535;
const window_bytes = 32768;
const no_position = std.math.maxInt(u32);

pub const ChainScratch = struct {
    /// Most recent slab-relative position for each three-byte hash, or no_position.
    heads: [65536]u32,
    /// Previous same-hash position for every copied-history/slab position.
    previous: [window_bytes + slab_bytes]u32,
};

pub const SearchStats = struct {
    /// Admitted candidate probes and eight-byte comparisons for one source position.
    units: u32,
    /// Examined prior candidates, including those ending without a usable match.
    probes: u32,
};

pub const storage_bytes = @max(@sizeOf(ChainScratch), @sizeOf(PrefixMatchTree));
pub const storage_alignment = @max(@alignOf(ChainScratch), @alignOf(PrefixMatchTree));
pub const Storage = [storage_bytes]u8;
pub const StoragePointer = *align(storage_alignment) Storage;

pub fn chain(storage: StoragePointer) *ChainScratch {
    return @ptrCast(storage);
}
pub fn tree(storage: StoragePointer) *PrefixMatchTree {
    return @ptrCast(storage);
}

/// Copied history followed by the active slab; only history + buffered bytes are initialized.
data: []const u8,
/// Initialized history bytes preceding the slab.
history: usize,
/// Source bytes in the active slab.
buffered: usize,
/// Cumulative accepted bytes, used to derive retained-tree coordinates.
input_bytes: u64,
/// Maximum candidate probes per position for the selected compression level.
depth: u16,
/// Admitted backward-distance bound.
window: usize,
/// Reference parser will compare a pending match with its next position.
lazy: bool,
/// Halve the selected depth for that pending match's lookahead search.
reduced_lookahead: bool,
/// Exclusive arena, interpreted as chain or tree state for this reset.
search: StoragePointer,
/// Writable candidates, one row per source position.
matches: []MatchCandidates,
/// Dead costs/choices/tokens/best backing, in that order. Tree search temporarily writes its
/// checkpoint here; successful restoration precedes any parser/selector use of these spans.
checkpoint: [4][]u8,
/// Shared cumulative work admission, including copied-dictionary search preparation.
work: EncodeWorkBudget,
// A checkpoint excludes the final 257 positions whose comparisons may need later bytes. Coordinates
// are derived from accepted input counts, so no additional owner state is kept.
pub noinline fn findOfflineTreeMatches(
    borrowed: *const MatchFinder,
    final: bool,
) EncodeWorkBudget.Error!void {
    // Snapshot immutable phase metadata once; backing storage and counters remain live borrows.
    const self = borrowed.*;
    const processed = self.input_bytes - self.buffered;
    const cycle: u64 = 1 << 31;
    const phase: usize = @intCast(processed & (cycle - 1));
    // Rebuild near each coordinate rollover. The margin exceeds a slab plus any history, covering
    // the block that crossed the boundary even after a short flush.
    const near_rollover = processed >= cycle and phase < slab_bytes + window_bytes;
    const rebuild = processed == 0 or self.history == 0 or near_rollover;
    if (final and rebuild) return self.findOfflineTreeMatchesStandalone();
    const total = self.history + self.buffered;
    const data = self.data[0..total];
    const depth: usize = self.depth;
    const nice: usize = if (depth <= 35) 75 else if (depth <= 100) 150 else 258;
    const origin = self.window + phase - self.history;
    if (rebuild) tree(self.search).resetAll();
    const pending = if (final) 0 else @min(total, self.window, 257);
    const checkpoint = total - pending;
    const first = if (rebuild) @as(usize, 0) else self.history - @min(self.history, 257);
    std.debug.assert(first <= checkpoint);
    for (first..total) |position| {
        if (pending != 0 and position == checkpoint) copyTreeCheckpoint(
            self.search,
            self.checkpoint,
            false,
        );
        const remaining = self.work.limit - self.work.stats.work_units;
        const matches = if (position < self.history) null else &self.matches[
            position - self
                .history
        ];
        var partial: PrefixMatchTree.Stats = undefined;
        const result = if (remaining >= depth * 34 + 1) PrefixMatchTree.insertAndFindAt(
            false,
            tree(self.search),
            data,
            position,
            origin,
            self.window,
            depth,
            nice,
            matches,
            remaining,
            &partial,
        ) else PrefixMatchTree.insertAndFindAt(
            true,
            tree(self.search),
            data,
            position,
            origin,
            self.window,
            depth,
            nice,
            matches,
            remaining,
            &partial,
        );
        const stats = result catch |err| {
            try self.work.admit(partial.units);
            self.work.stats.match_probes = try addCount(
                self.work.stats.match_probes,
                partial.probes,
            );
            return err;
        };
        try self.work.admit(stats.units);
        self.work.stats.match_probes = try addCount(self.work.stats.match_probes, stats.probes);
    }
    if (pending != 0) copyTreeCheckpoint(self.search, self.checkpoint, true);
}

// Rebuild the bounded tree for a standalone slab, including copied dictionary history.
pub noinline fn findOfflineTreeMatchesStandalone(
    borrowed: *const MatchFinder,
) EncodeWorkBudget.Error!void {
    // Snapshot immutable phase metadata once; backing storage and counters remain live borrows.
    const self = borrowed.*;
    const total = self.history + self.buffered;
    const depth: usize = self.depth;
    const nice: usize = if (depth <= 35) 75 else if (depth <= 100) 150 else 258;
    tree(self.search).reset(self.data[0..total]);
    for (0..total) |position| {
        const remaining = self.work.limit - self.work.stats.work_units;
        const matches = if (position < self.history) null else &self.matches[
            position - self
                .history
        ];
        var partial: PrefixMatchTree.Stats = undefined;
        const result = if (remaining >= depth * 34 + 1) PrefixMatchTree.insertAndFind(
            false,
            tree(self.search),
            self.data[0..total],
            position,
            self.window,
            depth,
            nice,
            matches,
            remaining,
            &partial,
        ) else PrefixMatchTree.insertAndFind(
            true,
            tree(self.search),
            self.data[0..total],
            position,
            self.window,
            depth,
            nice,
            matches,
            remaining,
            &partial,
        );
        const stats = result catch |err| {
            try self.work.admit(partial.units);
            self.work.stats.match_probes = try addCount(
                self.work.stats.match_probes,
                partial.probes,
            );
            return err;
        };
        try self.work.admit(stats.units);
        self.work.stats.match_probes = try addCount(self.work.stats.match_probes, stats.probes);
    }
}

pub fn findMatches(self: *const MatchFinder) EncodeWorkBudget.Error!void {
    if (self.reduced_lookahead) return self.findMatchesMode(true);
    return self.findMatchesMode(false);
}

// Select the lookahead policy once per block, keeping it out of the full-search loop.
pub noinline fn findMatchesMode(
    borrowed: *const MatchFinder,
    comptime reduced: bool,
) EncodeWorkBudget.Error!void {
    // Snapshot immutable phase metadata once; backing storage and counters remain live borrows.
    const self = borrowed.*;
    const total = self.history + self.buffered;
    if (total <= 256) {
        // Only hashes present in this slab can be read below. Clear those heads first so short
        // inputs avoid clearing the whole table, even when keys collide or scratch was reused.
        for (0..total -| 2) |position| {
            chain(self.search).heads[hash3(self.data[position..][0..3])] = no_position;
        }
    } else {
        @memset(&chain(self.search).heads, no_position);
    }
    const depth: usize = self.depth;
    const lazy = self.lazy;
    var next_search = self.history;
    var pending_length: usize = 0;
    for (0..total) |position| {
        if (total - position < 3) {
            if (position >= self.history) self.matches[position - self.history].count = 0;
            continue;
        }
        const hash = hash3(self.data[position..][0..3]);
        const candidate = chain(self.search).heads[hash];
        chain(self.search).previous[position] = candidate;
        chain(self.search).heads[hash] = @intCast(position);
        if (position < self.history) continue;
        // Every position enters the chain, including bytes covered by an earlier match. Greedy/lazy
        // parsing only needs matches at the next token and its lazy lookahead.
        if (position < next_search) continue;
        const matches = &self.matches[position - self.history];
        matches.count = 0;
        const remaining = self.work.limit - self.work.stats.work_units;
        const search_depth = if (reduced and pending_length != 0) depth / 2 else depth;
        // One candidate plus at most 31 word comparisons fits this bound. Admit the whole position
        // when possible, otherwise check each charged operation. Both paths publish identical exact
        // counters.
        var partial: SearchStats = undefined;
        const result = if (remaining >= search_depth * 34) self.scanMatches(
            false,
            position,
            total,
            candidate,
            search_depth,
            remaining,
            &partial,
        ) else self.scanMatches(
            true,
            position,
            total,
            candidate,
            search_depth,
            remaining,
            &partial,
        );
        const measured = result catch |err| {
            try self.work.admit(partial.units);
            self.work.stats.match_probes = try addCount(
                self.work.stats.match_probes,
                partial.probes,
            );
            return err;
        };
        try self.work.admit(measured.units);
        self.work.stats.match_probes = try addCount(self.work.stats.match_probes, measured.probes);
        var length: usize = 0;
        if (matches.count != 0) length = matches.items[matches.count - 1].length;
        if (lazy and pending_length != 0 and length <= pending_length) {
            // The previous position's match wins; this position was its lookahead.
            next_search = position + pending_length - 1;
            pending_length = 0;
        } else {
            // A longer lookahead makes the previous byte a literal. It is now the next token.
            pending_length = if (lazy) length else 0;
            next_search = position + if (lazy) 1 else @max(1, length);
        }
    }
}

pub fn scanMatches(
    self: *const MatchFinder,
    comptime bounded: bool,
    position: usize,
    total: usize,
    first: u32,
    depth: usize,
    budget: u64,
    partial: *SearchStats,
) EncodeWorkBudget.Error!SearchStats {
    const matches = &self.matches[position - self.history];
    const maximum = @min(258, total - position);
    const earliest = position -| self.window;
    const source = self.data[position..];
    var candidate = first;
    var longest: usize = 2;
    var measured: SearchStats = .{ .units = 0, .probes = 0 };
    defer partial.* = measured;
    while (candidate != no_position and candidate >= earliest and measured.probes < depth) {
        const candidate_position: usize = candidate;
        try searchWork(bounded, &measured.units, budget);
        measured.probes += 1;
        const prior = self.data[candidate_position..];
        if (prior[longest] == source[longest] and std.mem.eql(u8, prior[0..3], source[0..3])) {
            var length: usize = 3;
            while (length + 8 <= maximum) : (length += 8) {
                try searchWork(bounded, &measured.units, budget);
                const prior_word = std.mem.readInt(u64, prior[length..][0..8], .little);
                const source_word = std.mem.readInt(u64, source[length..][0..8], .little);
                if (prior_word != source_word) break;
            }
            while (length < maximum and prior[length] == source[length]) : (length += 1) {}
            if (length > longest) {
                const slot = @min(matches.count, alternatives - 1);
                matches.items[slot] = .{
                    .length = @intCast(length),
                    .distance = @intCast(position - candidate_position),
                };
                matches.count = @min(alternatives, matches.count + 1);
                longest = length;
                if (length == maximum) break;
            }
        }
        candidate = chain(self.search).previous[candidate_position];
    }
    return measured;
}

pub inline fn searchWork(
    comptime bounded: bool,
    units: *u32,
    budget: u64,
) EncodeWorkBudget.Error!void {
    if (bounded and units.* >= budget) return error.LimitExceeded;
    units.* += 1;
}

// Pricing and token arrays are dead during match search. Borrow their bytes for the tree
// checkpoint, restoring the tree before pricing and token selection overwrite those arrays.
fn copyTreeCheckpoint(storage: StoragePointer, segments: [4][]u8, comptime restore: bool) void {
    const pricing_bytes = (slab_bytes + 1) * @sizeOf(u32) + slab_bytes * @sizeOf(Token);
    const token_bytes = 2 * slab_bytes * @sizeOf(Token);
    comptime std.debug.assert(pricing_bytes + token_bytes >= @sizeOf(PrefixMatchTree));
    const tree_bytes = std.mem.asBytes(tree(storage));
    var offset: usize = 0;
    inline for (segments) |segment| {
        const count = @min(segment.len, tree_bytes.len - offset);
        if (restore) {
            @memcpy(tree_bytes[offset..][0..count], segment[0..count]);
        } else {
            @memcpy(segment[0..count], tree_bytes[offset..][0..count]);
        }
        offset += count;
    }
    std.debug.assert(offset == tree_bytes.len);
}

fn hash3(bytes: *const [3]u8) u16 {
    const value = @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
    return @truncate((value *% 0x1e35a7bd) >> 16);
}

test "compression levels select distinct bounded search effort" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    const position = 20000;
    const total = position + 258;
    for (0..position / 4) |i| workspace.data[i * 4 ..][0..4].* = "AAAx".*;
    @memset(workspace.data[position..total], 'q');
    workspace.data[position..][0..4].* = "AAAz".*;
    @memset(&MatchFinder.chain(&workspace.search).heads, no_position);
    for (0..position) |i| {
        const hash = hash3(workspace.data[i..][0..3]);
        MatchFinder.chain(
            &workspace.search,
        ).previous[i] = MatchFinder.chain(&workspace.search).heads[hash];
        MatchFinder.chain(&workspace.search).heads[hash] = @intCast(i);
    }
    const candidate = MatchFinder.chain(
        &workspace.search,
    ).heads[hash3(workspace.data[position..][0..3])];
    const depths = [_]u16{ 4, 8, 32, 64, 128, 256, 35, 100, 300 };
    for (depths[0..6], 1..) |depth, level| {
        try encoder.reset(workspace, .{ .compression = .{ .level = @intCast(level) } });
        encoder.buffered = total;
        workspace.matches[position].count = 0;
        // Thousands of equal three-byte prefixes force each selected level to visit its own maximum
        // candidate count; no earlier candidate can match the differing fourth byte.
        var partial: SearchStats = undefined;
        const measured = try borrows.search(
            &encoder,
        ).scanMatches(
            false,
            position,
            total,
            candidate,
            encoder.options.depth,
            std.math.maxInt(u64),
            &partial,
        );
        try std.testing.expectEqual(measured, partial);
        try std.testing.expectEqual(depth, encoder.options.depth);
        try std.testing.expectEqual(depth, measured.probes);
    }

    for (depths[6..], 7..) |depth, level| {
        try encoder.reset(workspace, .{ .compression = .{ .level = @intCast(level) } });
        try std.testing.expectEqual(Profile.offline, encoder.options.profile);
        try std.testing.expectEqual(depth, encoder.options.depth);
    }

    // Invalid levels must refuse reset before replacing an existing owner or workspace. Level zero
    // remains store-only even when a literal-only strategy was also selected.
    try encoder.reset(workspace, .{ .compression = .{ .level = 0, .strategy = .huffman_only } });
    try std.testing.expectEqual(Profile.stored, encoder.options.profile);
    encoder.stats.input_bytes = 42;
    workspace.data[0] = 0xa5;
    for (
        [_]Compression{
            .{ .level = 10 },
            .{ .level = 255 },
            .{ .level = 3, .lazy_lookahead = .reduced },
            .{ .level = 6, .strategy = .huffman_only, .lazy_lookahead = .reduced },
            .{ .level = 6, .offline_refinement = .early },
            .{ .level = 9, .strategy = .huffman_only, .offline_refinement = .early },
        },
    ) |invalid| {
        try std.testing.expectError(
            error.InvalidOptions,
            encoder.reset(workspace, .{ .compression = invalid }),
        );
        try std.testing.expectEqual(42, encoder.stats.input_bytes);
        try std.testing.expectEqual(0xa5, workspace.data[0]);
    }
    try encoder.reset(workspace, .{ .compression = .{ .strategy = .huffman_only } });
    try std.testing.expectEqual(Profile.huffman, encoder.options.profile);
}

test "search storage switches profiles after refusal and clears completely" {
    const allocator = std.testing.allocator;
    const reused = try EncoderWorkspace.create(allocator);
    defer reused.destroy(allocator);
    const fresh = try EncoderWorkspace.create(allocator);
    defer fresh.destroy(allocator);
    var source: [1024]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = "phase-switch-pattern"[i % 20];
    var expected: [2048]u8 = undefined;
    var actual: [2048]u8 = undefined;
    var encoder: Encoder = undefined;
    try encoder.reset(reused, .{ .compression = .{ .level = 9 }, .limits = .{ .work_units = 1 } });
    try std.testing.expectError(error.LimitExceeded, encoder.step("aaaaa", &actual, .finish));
    try std.testing.expectError(error.NeedReset, encoder.step("", &actual, .finish));
    for ([_]usize{ 3, 17, 255, 256, 257, 1024 }) |size| {
        for ([_]u8{ 9, 3, 6, 9 }) |level| {
            const options: EncodeOptions = .{ .compression = .{ .level = level } };
            const reference = try encode(source[0..size], &expected, fresh, options);
            const observed = try encode(source[0..size], &actual, reused, options);
            try std.testing.expectEqualSlices(u8, reference, observed);
        }
    }
    reused.clear();
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(reused), 0));
}

test "search admission preserves exact caches counters and per-operation limits" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const expected = try allocator.alloc(MatchCandidates, 2048);
    defer allocator.free(expected);
    var encoder: Encoder = undefined;
    for (0..2) |pattern| {
        for (workspace.data[0..expected.len], 0..) |*byte, i| {
            byte.* = if (pattern == 0) 65 else @truncate((i *% 123457 +% i / 13) >> 4);
        }
        try encoder.reset(workspace, .{ .compression = .{ .level = 9 } });
        encoder.buffered = expected.len;
        try borrows.search(&encoder).findOfflineTreeMatchesStandalone();
        const counters = encoder.counts();
        for (expected, workspace.matches[0..expected.len]) |*saved, matches| {
            saved.count = matches.count;
            @memcpy(saved.items[0..saved.count], matches.items[0..matches.count]);
        }
        try std.testing.expect(counters.work_units < 100000);
        try encoder.reset(
            workspace,
            .{ .compression = .{ .level = 9 }, .limits = .{ .work_units = 100000 } },
        );
        encoder.buffered = expected.len;
        try borrows.search(&encoder).findOfflineTreeMatchesStandalone();
        try std.testing.expectEqual(counters, encoder.counts());
        for (expected, workspace.matches[0..expected.len]) |saved, matches| {
            try std.testing.expectEqual(saved.count, matches.count);
            for (saved.items[0..saved.count], matches.items[0..matches.count]) |a, b| {
                try std.testing.expectEqual(a.length, b.length);
                try std.testing.expectEqual(a.distance, b.distance);
            }
        }
        try encoder.reset(
            workspace,
            .{
                .compression = .{ .level = 9 },
                .limits = .{ .work_units = counters.work_units - 1 },
            },
        );
        encoder.buffered = expected.len;
        try std.testing.expectError(
            error.LimitExceeded,
            borrows.search(&encoder).findOfflineTreeMatchesStandalone(),
        );
        try std.testing.expect(encoder.counts().work_units < counters.work_units);
    }
}

test "greedy and lazy caches preserve token choices while skipping covered positions" {
    const Reference = struct {
        // Walk prior bytes directly, independently of the encoder's hash-chain construction and
        // sparse-search schedule. Equal lengths keep the nearest candidate.
        fn longest(data: []const u8, position: usize, window: usize, depth: usize) Match {
            const maximum = @min(258, data.len - position);
            if (maximum < 3) return .{ .length = 0, .distance = 0 };
            const hash = hash3(data[position..][0..3]);
            const first = position -| window;
            var candidate = position;
            var probes: usize = 0;
            var best: Match = .{ .length = 0, .distance = 0 };
            while (candidate > first and probes < depth) {
                candidate -= 1;
                if (hash3(data[candidate..][0..3]) != hash) continue;
                probes += 1;
                var length: usize = 0;
                while (length < maximum and data[candidate + length] == data[position + length])
                    length += 1;
                if (length >= 3 and length > best.length) {
                    best = .{
                        .length = @intCast(length),
                        .distance = @intCast(position - candidate),
                    };
                    if (length == maximum) break;
                }
            }
            return best;
        }
    };
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var expected: [768]Token = undefined;
    var encoder: Encoder = undefined;
    for (0..4) |pattern| {
        for ([_]usize{ 0, 256 }) |history| {
            const total = history + expected.len;
            const data = workspace.data[0..total];
            for (data, 0..) |*byte, i| {
                byte.* = switch (pattern) {
                    0 => 'A',
                    1 => @intCast(i % 7),
                    2 => @truncate((i *% 123457 +% i / 13) >> 4),
                    else => "abcxabcabcabcabcdabcxabcd"[(i + i / 127) % 24],
                };
            }
            for ([_]usize{ 256, 32768 }) |window| {
                inline for (
                    .{
                        Compression{ .level = 3 },
                        Compression{ .level = 4, .lazy_lookahead = .reduced },
                        Compression{ .level = 5, .lazy_lookahead = .reduced },
                        Compression{ .level = 6, .lazy_lookahead = .reduced },
                        Compression{ .level = 6 },
                    },
                ) |compression| {
                    const lazy = compression.level >= 4;
                    const depth: usize = switch (compression.level) {
                        3 => 32,
                        4 => 64,
                        5 => 128,
                        6 => 256,
                        else => unreachable,
                    };
                    var count: usize = 0;
                    var position = history;
                    var pending: ?Match = null;
                    while (position < total) {
                        var match = pending orelse Reference.longest(data, position, window, depth);
                        pending = null;
                        if (lazy and match.length != 0 and position + 1 < total) {
                            const next_depth = if (compression.lazy_lookahead == .reduced) depth /
                                2 else depth;
                            const next = Reference.longest(data, position + 1, window, next_depth);
                            if (next.length > match.length) {
                                pending = next;
                                match.length = 0;
                            }
                        }
                        expected[count] = .{
                            .length = match.length,
                            .value = if (match.length == 0) data[position] else match.distance,
                        };
                        count += 1;
                        position += @max(1, match.length);
                    }
                    // Covered rows may retain unrelated bytes. Every token/lookahead read must use
                    // a row initialized by this search, including the final short tail.
                    @memset(std.mem.sliceAsBytes(workspace.matches[0..expected.len]), 0xa5);
                    try encoder.reset(
                        workspace,
                        .{ .compression = compression, .window_bytes = window },
                    );
                    encoder.history = history;
                    encoder.buffered = expected.len;
                    try borrows.search(&encoder).findMatches();
                    const actual = borrows.parser(&encoder).referenceParse(lazy);
                    try std.testing.expectEqual(count, actual);
                    try std.testing.expectEqualSlices(
                        Token,
                        expected[0..count],
                        workspace.tokens[0..actual],
                    );
                    if (pattern == 0) try std.testing.expect(encoder.counts().match_probes < 20);

                    const counters = encoder.counts();
                    try encoder.reset(
                        workspace,
                        .{
                            .compression = compression,
                            .window_bytes = window,
                            .limits = .{ .work_units = counters.work_units },
                        },
                    );
                    encoder.history = history;
                    encoder.buffered = expected.len;
                    try borrows.search(&encoder).findMatches();
                    try std.testing.expectEqual(counters, encoder.counts());
                    try std.testing.expectEqual(
                        count,
                        borrows.parser(&encoder).referenceParse(lazy),
                    );
                    try std.testing.expectEqualSlices(
                        Token,
                        expected[0..count],
                        workspace.tokens[0..count],
                    );
                    if (counters.work_units != 0) {
                        try encoder.reset(
                            workspace,
                            .{
                                .compression = compression,
                                .window_bytes = window,
                                .limits = .{ .work_units = counters.work_units - 1 },
                            },
                        );
                        encoder.history = history;
                        encoder.buffered = expected.len;
                        try std.testing.expectError(
                            error.LimitExceeded,
                            borrows.search(&encoder).findMatches(),
                        );
                        try std.testing.expect(encoder.counts().work_units < counters.work_units);
                    }
                }
            }
        }
    }
}

test "match cache initializes dictionary starts and every short tail before parsing" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    const sizes = [_]usize{
        0,   1,   2,   3,   4,   5,   6,   7,   8,   9,   10,  11,  15,  16,  17,  255, 256, 257,
        258, 259, 260, 261, 262, 511, 512, 513, 514, 515, 516, 517, 518, 519, 520, 767, 768, 769,
        770, 771, 772, 773, 774, 775, 776,
    };
    for (sizes) |size| {
        for ([_]usize{ 256, 32768 }) |window| {
            for ([_]usize{ 0, 1, 2, 255, 256, 32768 }) |history| {
                if (history > window) continue;
                for ([_]Compression{ .{ .level = 3 }, .{ .level = 6 } }) |compression| {
                    const lazy = compression.level == 6;
                    var expected: [8]Token = undefined;
                    var count: usize = 0;
                    var position: usize = 0;
                    // For an all-A source, the nearest preceding byte supplies the longest legal
                    // match, including overlap. The first byte without history and an uncovered
                    // one/two-byte remainder need literals. This expectation uses no hash or cached
                    // row.
                    while (position < size) {
                        const remaining = size - position;
                        const can_match = history + position != 0 and remaining >= 3;
                        const length: usize = if (can_match) @min(258, remaining) else 0;
                        expected[count] = .{
                            .length = @intCast(length),
                            .value = if (length == 0) 'A' else 1,
                        };
                        count += 1;
                        position += @max(1, length);
                    }
                    var full: EncodeStats = undefined;
                    for (0..2) |pass| {
                        const budget = if (pass == 0) std.math.maxInt(u64) else full.work_units;
                        try encoder.reset(
                            workspace,
                            .{
                                .compression = compression,
                                .window_bytes = window,
                                .limits = .{ .work_units = budget },
                            },
                        );
                        encoder.history = history;
                        encoder.buffered = size;
                        @memset(workspace.data[0 .. history + size], 'A');
                        @memset(std.mem.sliceAsBytes(workspace.matches[0..size]), 0xa5);
                        try borrows.search(&encoder).findMatches();
                        if (pass == 0) {
                            full = encoder.counts();
                        } else {
                            try std.testing.expectEqual(full, encoder.counts());
                        }
                        try std.testing.expectEqual(
                            count,
                            borrows.parser(&encoder).referenceParse(lazy),
                        );
                        try std.testing.expectEqualSlices(
                            Token,
                            expected[0..count],
                            workspace.tokens[0..count],
                        );
                        // The final short rows must be safe even when they lie inside a match: a
                        // lazy lookahead can visit either one before choosing that match.
                        for (workspace.matches[size - @min(2, size) .. size]) |row| {
                            try std.testing.expectEqual(0, row.count);
                        }
                        if (size >= 8) {
                            const first_match: usize = if (history == 0) 1 else 0;
                            const skipped_offset: usize = if (lazy) 2 else 1;
                            const covered = first_match + skipped_offset;
                            // A covered non-tail row stays poisoned. This proves the selected
                            // initializer avoids that row while every actual parse read succeeds.
                            try std.testing.expectEqual(0xa5, workspace.matches[covered].count);
                        }
                    }
                }
            }
        }
    }
}

test "short hash initialization ignores retired workspace contents" {
    const allocator = std.testing.allocator;
    const left = try EncoderWorkspace.create(allocator);
    defer left.destroy(allocator);
    const right = try EncoderWorkspace.create(allocator);
    defer right.destroy(allocator);
    const decoder = try test_decoding.decode.Workspace.create(allocator);
    defer decoder.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const cases = [_]struct {
        dictionary: usize,
        input: usize,
    }{
        .{ .dictionary = 0, .input = 0 },
        .{ .dictionary = 0, .input = 1 },
        .{ .dictionary = 0, .input = 2 },
        .{ .dictionary = 0, .input = 3 },
        .{ .dictionary = 0, .input = 64 },
        .{ .dictionary = 0, .input = 255 },
        .{ .dictionary = 0, .input = 256 },
        .{ .dictionary = 0, .input = 257 },
        .{ .dictionary = 1, .input = 255 },
        .{ .dictionary = 2, .input = 254 },
        .{ .dictionary = 255, .input = 1 },
        .{ .dictionary = 256, .input = 0 },
        .{ .dictionary = 256, .input = 1 },
    };
    var source: [257]u8 = undefined;
    var dictionary: [256]u8 = undefined;
    var first_wire: [1024]u8 = undefined;
    var second_wire: [1024]u8 = undefined;
    var restored: [257]u8 = undefined;
    for (0..2) |pattern| {
        for (
            &source,
            0..,
        ) |*byte, i| byte.* = if (pattern == 0) @truncate(
            (i *% 29 +% i / 7) >> 2,
        ) else @as(u8, @intCast(i % 3)) + 'A';
        for (&dictionary, 0..) |*byte, i| byte.* = source[i];
        for (cases) |case| {
            const preset: ?[]const u8 = if (case.dictionary == 0) null else dictionary[0..case
                .dictionary];
            for ([_]u8{ 3, 6, 9 }) |level| {
                // The two workspaces retain incompatible arbitrary heads from earlier operations.
                // Identical wire and counts show that only keys in this operation influence it.
                @memset(&MatchFinder.chain(&left.search).heads, 0x3fff_ffff);
                @memset(&MatchFinder.chain(&right.search).heads, no_position);
                var encoder: Encoder = undefined;
                try encoder.reset(
                    left,
                    .{ .dictionary = preset, .compression = .{ .level = level } },
                );
                const a = try encoder.step(source[0..case.input], &first_wire, .finish);
                const counts = encoder.counts();
                try encoder.reset(
                    right,
                    .{ .dictionary = preset, .compression = .{ .level = level } },
                );
                const b = try encoder.step(source[0..case.input], &second_wire, .finish);
                try std.testing.expectEqual(EncodeStatus.complete, a.status);
                try std.testing.expectEqual(a, b);
                try std.testing.expectEqual(counts, encoder.counts());
                try std.testing.expectEqualSlices(
                    u8,
                    first_wire[0..a.produced],
                    second_wire[0..b.produced],
                );
                const result = try test_decoding.decode.into(
                    first_wire[0..a.produced],
                    restored[0..case.input],
                    .{ .workspace = decoder, .history = history },
                    .{ .dictionary = preset, .output_size = .exact, .trailing_data = .reject },
                );
                try std.testing.expectEqual(case.input, result.produced);
                try std.testing.expectEqualSlices(
                    u8,
                    source[0..case.input],
                    restored[0..case.input],
                );
            }
        }
    }
}

test "offline tree retains correct matches across slab tails" {
    // A truncated tail once broke tree prefix reuse and produced an invalid match for this input.
    const Xorshift = struct {
        state: u32 = 10,

        fn next(self: *@This()) u32 {
            self.state ^= self.state << 13;
            self.state ^= self.state >> 17;
            self.state ^= self.state << 5;
            return self.state;
        }
    };
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 131073);
    defer allocator.free(source);
    var random: Xorshift = .{};
    var phrase: [257]u8 = undefined;
    for (&phrase) |*byte| byte.* = @truncate(random.next() >> 24);
    for (source, 0..) |*byte, i| {
        const roll = random.next();
        byte.* = if (roll & 31 == 0) @truncate(random.next() >> 24) else phrase[i % phrase.len];
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    try std.testing.expectEqualSlices(
        u8,
        &.{
            0x76, 0x0b, 0xda, 0xae, 0x3d, 0x16, 0x6b, 0xeb,
            0x0f, 0x64, 0xd9, 0x52, 0x30, 0xe5, 0x36, 0x19,
            0x36, 0x5c, 0xf7, 0x23, 0xe7, 0xba, 0x9f, 0x07,
            0x8e, 0x1c, 0x03, 0x1a, 0x7c, 0x84, 0xaf, 0xed,
        },
        &digest,
    );

    const encoding = try EncoderWorkspace.create(allocator);
    defer encoding.destroy(allocator);
    const wire = try allocator.alloc(u8, try encodeBound(source.len));
    defer allocator.free(wire);
    const decoder = try test_decoding.decode.Workspace.create(allocator);
    defer decoder.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const restored = try allocator.alloc(u8, source.len);
    defer allocator.free(restored);

    var encoder: Encoder = undefined;
    try encoder.reset(encoding, .{ .compression = .{ .level = 9 } });
    const complete = try encoder.step(source, wire, .finish);
    try std.testing.expectEqual(.complete, complete.status);
    const full_work = encoder.counts().work_units;
    try std.testing.expect(full_work > 1);
    const result = try test_decoding.decode.into(
        wire[0..complete.produced],
        restored,
        .{ .workspace = decoder, .history = history },
        .{ .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(source.len, result.produced);
    try std.testing.expect(std.mem.eql(u8, source, restored));

    // Refusal may leave a partially used checkpoint. The same owner and workspace must require
    // reset and then produce a valid stream again at every selected work boundary.
    for ([_]u64{ 0, full_work / 2, full_work - 1 }) |limit| {
        try encoder.reset(
            encoding,
            .{ .compression = .{ .level = 9 }, .limits = .{ .work_units = limit } },
        );
        try std.testing.expectError(error.LimitExceeded, encoder.step(source, wire, .finish));
        try std.testing.expect(encoder.counts().work_units <= limit);
        try std.testing.expectError(error.NeedReset, encoder.step("", &.{}, .finish));
        try encoder.reset(encoding, .{ .compression = .{ .level = 9 } });
        const reused = try encoder.step(source, wire, .finish);
        try std.testing.expectEqual(.complete, reused.status);
        try std.testing.expectEqual(full_work, encoder.counts().work_units);
        _ = try test_decoding.decode.into(
            wire[0..reused.produced],
            restored,
            .{ .workspace = decoder, .history = history },
            .{ .output_size = .exact, .trailing_data = .reject },
        );
        try std.testing.expect(std.mem.eql(u8, source, restored));
    }
}

test "retained coordinates rebuild at an artificial epoch rollover" {
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(u8, 131073);
    defer allocator.free(input);
    for (input, 0..) |*byte, i| byte.* = @truncate((i *% 73 +% i / 11) ^ (i / 17));
    const output = try allocator.alloc(u8, try encodeBound(input.len) + 64);
    defer allocator.free(output);
    const restored = try allocator.alloc(u8, input.len);
    defer allocator.free(restored);
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const decoder = try test_decoding.decode.Workspace.create(allocator);
    defer decoder.destroy(allocator);
    const cycle: u64 = 1 << 31;
    for ([_]u64{ cycle - 65535, cycle - 32768, cycle - 100, cycle + 98303 }) |initial| {
        var encoder: Encoder = undefined;
        try encoder.reset(
            workspace,
            .{ .compression = .{ .level = 9, .offline_pricing = .maximum_lengths } },
        );
        // The initial history is empty; the synthetic count moves only the coordinate epoch.
        encoder.stats.input_bytes = initial;
        const first = try encoder.step(input[0..65535], output, .process);
        try std.testing.expectEqual(@as(usize, 65535), first.consumed);
        var read = first.consumed;
        var written = first.produced;
        while (true) {
            const part = try encoder.step(input[read..], output[written..], .finish);
            read += part.consumed;
            written += part.produced;
            if (part.status == .complete) break;
            try std.testing.expect(part.consumed + part.produced > 0);
        }
        try std.testing.expectEqual(input.len, read);
        try std.testing.expectEqual(initial + input.len, encoder.counts().input_bytes);
        const decoded = try test_decoding.decode.into(
            output[0..written],
            restored,
            .{ .workspace = decoder },
            .{ .output_size = .exact, .trailing_data = .reject },
        );
        try std.testing.expectEqual(input.len, decoded.produced);
        try std.testing.expectEqualSlices(u8, input, restored);
    }
}

test "retained search protects guarded poisoned workspace across failure and reuse" {
    const allocator = std.testing.allocator;
    const alignment = std.mem.Alignment.of(EncoderWorkspace);
    const margin = @max(64, @alignOf(EncoderWorkspace));
    const size = @sizeOf(EncoderWorkspace);
    const bytes = try allocator.alignedAlloc(u8, alignment, size + 2 * margin);
    defer allocator.free(bytes);
    const workspace: *EncoderWorkspace = @ptrCast(@alignCast(bytes[margin..].ptr));
    const guards: [margin]u8 = @splat(0xa5);
    const decoder = try test_decoding.decode.Workspace.create(allocator);
    defer decoder.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const input = try allocator.alloc(u8, 131073);
    defer allocator.free(input);
    for (input, 0..) |*byte, i| byte.* = @truncate((i *% 73 +% i / 11) ^ (i / 17));
    const output = try allocator.alloc(u8, try encodeBound(input.len) + 128);
    defer allocator.free(output);
    const restored = try allocator.alloc(u8, input.len);
    defer allocator.free(restored);
    const dictionary = "a copied dictionary for exercising guarded history";
    for ([_]usize{ 256, 32768 }) |window| {
        @memset(bytes, 0xa5);
        var encoder: Encoder = undefined;
        const options: EncodeOptions = .{
            .dictionary = dictionary,
            .window_bytes = window,
            .compression = .{ .level = 9 },
        };
        try encoder.reset(workspace, options);
        const result = try encoder.step(input, output, .finish);
        try std.testing.expectEqual(.complete, result.status);
        const decoded = try test_decoding.decode.into(
            output[0..result.produced],
            restored,
            .{ .workspace = decoder, .history = history },
            .{
                .dictionary = dictionary,
                .window_bytes = window,
                .output_size = .exact,
                .trailing_data = .reject,
            },
        );
        try std.testing.expectEqual(input.len, decoded.produced);
        try std.testing.expectEqualSlices(u8, input, restored);
        try std.testing.expectEqualSlices(u8, &guards, bytes[0..margin]);
        try std.testing.expectEqualSlices(u8, &guards, bytes[margin + size ..]);
        var limited = options;
        limited.limits.work_units = 0;
        try encoder.reset(workspace, limited);
        try std.testing.expectError(error.LimitExceeded, encoder.step(input, output, .finish));
        try std.testing.expectError(error.NeedReset, encoder.step(&.{}, output, .finish));
        try std.testing.expectEqualSlices(u8, &guards, bytes[0..margin]);
        try std.testing.expectEqualSlices(u8, &guards, bytes[margin + size ..]);
        try encoder.reset(workspace, options);
        const reused = try encoder.step(input, output, .finish);
        try std.testing.expectEqual(.complete, reused.status);
        _ = try test_decoding.decode.into(
            output[0..reused.produced],
            restored,
            .{ .workspace = decoder, .history = history },
            .{
                .dictionary = dictionary,
                .window_bytes = window,
                .output_size = .exact,
                .trailing_data = .reject,
            },
        );
        try std.testing.expectEqualSlices(u8, input, restored);
        try std.testing.expectEqualSlices(u8, &guards, bytes[0..margin]);
        try std.testing.expectEqualSlices(u8, &guards, bytes[margin + size ..]);
    }
}
