//! Bounded offline LZ4 parsing with exact token/extension prices. The wire format is the ordinary
//! LZ4 block format; no special decoder is needed. This implementation uses a 2 KiB parsing
//! horizon, one path per position, and a long-match shortcut. It does not claim global optimality.
//! Algorithm references: LZ4 1.10.0 lib/lz4hc.c (BSD-2-Clause), especially LZ4HC_literalsPrice,
//! LZ4HC_sequencePrice and its bounded optimal parser.

const std = @import("std");
const overlaps = @import("../common/byte_ranges.zig").overlaps;

const lz4 = @import("block.zig");

/// Search budgets, independent of upstream compression level numbers.
pub const HcProfile = enum {
    /// Shallower search, with at most 128 chain probes per position.
    balanced,
    /// Deeper search for smaller output, with at most 4096 probes per position.
    offline,
};

/// Size prices only serialized bytes; throughput also prices each match and short overlapping
/// copies. This is a heuristic, not a latency guarantee.
pub const HcDecoderCost = enum {
    /// Minimize serialized byte cost.
    size,
    /// Also penalize match dispatch and short overlapping copies during decoding.
    throughput,
};

/// Per-block search/parser admission. Work counts insertions, chain probes, compared words/bytes
/// and parser edges, including dictionary priming.
pub const HcEncodeLimits = struct { work_units: u64 = std.math.maxInt(u64) };

/// Dictionary and bounded search policy for a complete high-compression block.
pub const HcEncodeOptions = struct {
    /// Immutable history for this complete call, trimmed to the last 65,535 bytes.
    dictionary: []const u8 = &.{},
    profile: HcProfile = .offline,
    decoder_cost: HcDecoderCost = .size,
    limits: HcEncodeLimits = .{},
};

/// Copied effort and format statistics, reset on each admitted operation.
pub const HcStats = struct { work_units: u64 = 0, probes: u64 = 0, sequences: u64 = 0 };

/// HC resource failures in addition to the ordinary block contract.
pub const HcError = lz4.Error || error{LimitExceeded};

const horizon = 2048;
const hashes = 32768;
const Node = struct { price: u32, literals: u32, previous: u16, match: u16, distance: u16 };

/// Fixed, address-stable HC scratch. No input or allocator is retained. The greedy encoder's 16 KiB
/// `EncoderWorkspace` is separate from this scratch.
pub const HcEncoderWorkspace = struct {
    heads: [hashes]u32,
    chains: [65536]u32,
    nodes: [horizon + 1]Node,
    path: [horizon]u16,
    stats: HcStats,

    /// Allocates scratch at its final address; `encodeBlockHc` initializes it.
    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*HcEncoderWorkspace {
        return allocator.create(HcEncoderWorkspace);
    }

    /// Releases scratch through its construction authority.
    pub fn destroy(self: *HcEncoderWorkspace, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    /// Erases retained source-derived tables and statistics after final use.
    pub fn clear(self: *HcEncoderWorkspace) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }

    fn charge(self: *HcEncoderWorkspace, amount: u64, limit: u64) HcError!void {
        if (amount > limit - self.stats.work_units) return error.LimitExceeded;
        self.stats.work_units += amount;
    }
};

/// Encodes an ordinary raw block using bounded HC parsing. Requires the full blockEncodeBound
/// capacity, exact disjoint spans and no padding. Dictionary bytes are borrowed for this call; only
/// their last 65,535 bytes are used. Failure leaves output unpublished; reuse is valid after any
/// result.
pub fn encodeBlockHc(
    source: []const u8,
    output: []u8,
    workspace: *HcEncoderWorkspace,
    options: HcEncodeOptions,
) HcError![]u8 {
    const dictionary = options.dictionary;
    const bound = try lz4.blockEncodeBound(source.len);
    const dict = dictionary[dictionary.len - @min(dictionary.len, lz4.maximum_distance) ..];
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
        try insert(&data, workspace, inserted, options.limits.work_units);
    }

    var writer: Writer = .{ .bytes = output };
    var cursor: usize = 0;
    var anchor: usize = 0;
    const nice: usize = switch (options.profile) {
        .balanced => 64,
        .offline => 256,
    };
    const depth: usize = switch (options.profile) {
        .balanced => 128,
        .offline => 4096,
    };
    while (source.len >= 12 and cursor <= source.len - 12) {
        // Price one path to each byte within this horizon, starting with pending literals.
        const count: usize = @min(horizon, source.len - 5 - cursor);
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
            .price = @intCast(literalPrice(cursor - anchor)),
            .literals = @intCast(cursor - anchor),
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
                try insert(&data, workspace, inserted, options.limits.work_units);
            }
            const match: Match = blk: {
                if (position > source.len - 12) break :blk .{};
                const maximum = source.len - 5 - position;
                break :blk try find(&data, workspace, absolute, maximum, depth, options);
            };
            if (match.length >= nice) {
                terminal = i;
                shortcut = match;
                break;
            }
            const node = workspace.nodes[i];
            try workspace.charge(1, options.limits.work_units);
            const added_extension = extension(node.literals + 1, 15) - extension(node.literals, 15);
            const next_price = node.price + 1 + @as(u32, @intCast(added_extension));
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
                try workspace.charge(1, options.limits.work_units);
                const penalty: u32 = blk: {
                    if (options.decoder_cost != .throughput) break :blk 0;
                    const short_overlap: u32 = @intFromBool(match.distance < 8);
                    break :blk 2 + short_overlap * 2;
                };
                const match_extension: u32 = @intCast(extension(length - 4, 15));
                const price = node.price + 3 + match_extension + penalty;
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

        // Walk predecessors backward, then emit their match edges in source order.
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

        var result: u32 = 0;
        inline for (0..4) |i| result |= @as(u32, self.byte(position + i)) << (i * 8);
        return result;
    }
};

fn insert(
    data: *const Data,
    workspace: *HcEncoderWorkspace,
    position: usize,
    limit: u64,
) HcError!void {
    try workspace.charge(1, limit);
    const slot = (data.word(position) *% 0x9e3779b1) >> 17;
    workspace.chains[position & 65535] = workspace.heads[slot];
    workspace.heads[slot] = @intCast(position + 1);
}

fn find(
    data: *const Data,
    workspace: *HcEncoderWorkspace,
    position: usize,
    maximum: usize,
    depth: usize,
    options: HcEncodeOptions,
) HcError!Match {
    // Admit an upper bound, then accumulate exact effort in registers. The checked specialization
    // retains exact exhaustion at a smaller budget.
    const bound: u64 = @as(u64, depth) * (maximum + 2);
    if (bound <= options.limits.work_units - workspace.stats.work_units) {
        return findCounted(false, data, workspace, position, maximum, depth, options);
    }
    return findCounted(true, data, workspace, position, maximum, depth, options);
}

fn findCounted(
    comptime bounded: bool,
    data: *const Data,
    workspace: *HcEncoderWorkspace,
    position: usize,
    maximum: usize,
    depth: usize,
    options: HcEncodeOptions,
) HcError!Match {
    const word = data.word(position);
    const slot = (word *% 0x9e3779b1) >> 17;
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
        const candidate: usize = link - 1;
        if (candidate >= position or position - candidate > lz4.maximum_distance) break;
        if (bounded) {
            try workspace.charge(1, options.limits.work_units);
        } else {
            work_units += 1;
        }
        visited += 1;

        // A strict improvement must match through the current best endpoint. Reject it before
        // rescanning a potentially very long shared prefix.
        if (result.length >= 4 and result.length < maximum) {
            if (bounded) {
                try workspace.charge(1, options.limits.work_units);
            } else {
                work_units += 1;
            }
            const endpoint = result.length - 3;
            if (data.word(position + endpoint) != data.word(candidate + endpoint)) {
                link = workspace.chains[candidate & 65535];
                continue;
            }
        }

        if (data.word(candidate) == word) {
            var length: usize = 4;
            while (length + 8 <= maximum and candidate + length >= data.dictionary.len) {
                if (bounded) {
                    try workspace.charge(1, options.limits.work_units);
                } else {
                    work_units += 1;
                }
                const current_bytes = data.source[position + length - data.dictionary.len ..][0..8];
                const prior_bytes = data.source[candidate + length - data.dictionary.len ..][0..8];
                const current_word = std.mem.readInt(u64, current_bytes, .little);
                const prior_word = std.mem.readInt(u64, prior_bytes, .little);
                const unequal = current_word ^ prior_word;
                if (unequal != 0) {
                    length += @ctz(unequal) / 8;
                    break;
                }
                length += 8;
            }
            while (length < maximum) : (length += 1) {
                if (data.byte(position + length) != data.byte(candidate + length)) break;
                if (bounded) {
                    try workspace.charge(1, options.limits.work_units);
                } else {
                    work_units += 1;
                }
            }
            if (length > result.length) result = .{
                .length = length,
                .distance = @intCast(position - candidate),
            };
            if (length == maximum) break;
        }
        link = workspace.chains[candidate & 65535];
    }
    return result;
}

fn extension(length: usize, threshold: usize) usize {
    return if (length < threshold) 0 else 1 + (length - threshold) / 255;
}

fn literalPrice(length: usize) usize {
    return 1 + length + extension(length, 15);
}

// Full blockEncodeBound admission proves all writes, including worst-case match splits. Every match
// replaces at least four bytes with at most three bytes.
const Writer = struct {
    bytes: []u8,
    cursor: usize = 0,

    fn byte(self: *Writer, value: u8) void {
        self.bytes[self.cursor] = value;
        self.cursor += 1;
    }

    fn extended(self: *Writer, count: usize) void {
        var remaining = count;
        while (remaining >= 255) : (remaining -= 255) self.byte(255);
        self.byte(@intCast(remaining));
    }

    fn literals(self: *Writer, bytes: []const u8) void {
        if (bytes.len >= 15) self.extended(bytes.len - 15);
        @memcpy(self.bytes[self.cursor..][0..bytes.len], bytes);
        self.cursor += bytes.len;
    }

    fn sequence(self: *Writer, bytes: []const u8, distance: u16, length: usize) void {
        const literal_bits: u8 = @as(u8, @intCast(@min(bytes.len, 15))) << 4;
        const match_bits: u8 = @intCast(@min(length - 4, 15));
        self.byte(literal_bits | match_bits);
        self.literals(bytes);
        std.mem.writeInt(u16, self.bytes[self.cursor..][0..2], distance, .little);
        self.cursor += 2;
        if (length >= 19) self.extended(length - 19);
    }

    fn final(self: *Writer, bytes: []const u8) void {
        self.byte(@as(u8, @intCast(@min(bytes.len, 15))) << 4);
        self.literals(bytes);
    }
};

test "LZ4 HC bounded parsing dictionaries budgets and clearing" {
    const last: [*]const u8 = @ptrFromInt(std.math.maxInt(usize));
    try std.testing.expect(overlaps(last[0..1], last[0..1]));
    const allocator = std.testing.allocator;
    const workspace = try HcEncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var source: [12000]u8 = undefined;
    for (&source, 0..) |*b, i| b.* = @intCast((i *% 137 + i / 19) % 251);
    @memcpy(source[6000..], source[0..6000]);
    const output = try allocator.alloc(u8, try lz4.blockEncodeBound(source.len));
    defer allocator.free(output);
    var decoded: [source.len]u8 = undefined;
    for ([_]HcProfile{ .balanced, .offline }) |profile| {
        @memset(output, 0xa7);
        const wire = try encodeBlockHc(
            &source,
            output,
            workspace,
            .{ .profile = profile, .dictionary = source[0..4096] },
        );
        _ = try lz4.decodeBlock(wire, &decoded, .{ .dictionary = .{ .newer = source[0..4096] } });
        try std.testing.expectEqualSlices(u8, &source, &decoded);
        try std.testing.expect(std.mem.allEqual(u8, output[wire.len..], 0xa7));
        const work_units = workspace.stats.work_units;
        _ = try encodeBlockHc(
            &source,
            output,
            workspace,
            .{
                .profile = profile,
                .limits = .{ .work_units = work_units },
                .dictionary = source[0..4096],
            },
        );
        try std.testing.expectError(
            error.LimitExceeded,
            encodeBlockHc(
                &source,
                output,
                workspace,
                .{
                    .profile = profile,
                    .limits = .{ .work_units = work_units - 1 },
                    .dictionary = source[0..4096],
                },
            ),
        );
    }
    try std.testing.expectError(
        error.Aliasing,
        encodeBlockHc(source[0..20], &source, workspace, .{ .dictionary = &.{} }),
    );
    workspace.clear();
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(workspace), 0));
}
