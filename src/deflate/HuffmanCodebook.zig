//! A Huffman codebook assigns variable-length bitstrings to symbols. RFC 1951 uses separate
//! alphabets for literals/lengths, distances and code lengths; this bounded representation serves
//! each alphabet. Construction minimizes weighted cost within the code-width limit, with stable tie
//! choices and reversed canonical codes ready for least-significant-bit-first emission.
//!
//! Construction first tries an ordinary Huffman tree. If that tree exceeds the width limit,
//! package-merge pairs the least costly leaves/packages at successive width levels. Expanding the
//! selected final list entries counts how often each leaf participates, yielding its bounded code
//! width.

const std = @import("std");
const EncodeWorkBudget = @import("EncodeWorkBudget.zig");
const test_encoding = @import("encode.zig");
const borrows = @import("block_borrows.zig");
const Encoder = test_encoding.StreamEncoder;
const EncoderWorkspace = @import("EncodeWorkspace.zig");
const encode = test_encoding.into;

const HuffmanCodebook = @This();
const no_symbol = std.math.maxInt(u16);

/// Code width per alphabet symbol; zero marks an unused symbol.
widths: [286]u8,
/// Canonical codes reversed for RFC 1951's least-significant-bit-first wire order.
codes: [286]u16,

const ConstructionNode = struct {
    /// Leaf frequency or the sum of both children's weights.
    weight: u64,
    /// Child indices for internal tree/package nodes; unused for leaves.
    left: u16,
    right: u16,
    /// Alphabet symbol for a leaf, or no_symbol for an internal node.
    symbol: u16,
};

pub const Scratch = struct {
    /// Leaves followed by package/ordinary-tree nodes. Parents follow their children.
    nodes: [286 * 16]ConstructionNode,
    /// Alternating package-merge lists; the ordinary-tree attempt also borrows one for depths.
    lists: [2][572]u16,
    /// Nonzero-frequency leaves, ordered by weight then symbol.
    leaves: [286]u16,
    /// Merge packages in their deterministic creation order.
    packages: [286]u16,
};

/// Builds an alphabet of at most 286 symbols with a caller-admitted maximum width in 1..15 and
/// enough codes for its used symbols. Scratch is exclusive during construction. Widths and scratch
/// may change before work admission fails; codes are usable only after success. Empty/single-symbol
/// alphabets use one one-bit code without charging construction work.
// Package-merge, Larmore and Hirschberg, JACM 37 (1990), pp. 464-473.
// https://web.cs.unlv.edu/larmore/Research/larHir90.pdf
pub fn build(
    book: *HuffmanCodebook,
    frequencies: []const u32,
    maximum: u8,
    scratch: *Scratch,
    budget: EncodeWorkBudget,
) EncodeWorkBudget.Error!void {
    @memset(&book.widths, 0);
    var count: usize = 0;
    for (frequencies, 0..) |frequency, symbol| {
        if (frequency == 0) continue;
        scratch.nodes[count] = .{
            .weight = frequency,
            .left = 0,
            .right = 0,
            .symbol = @intCast(symbol),
        };
        scratch.leaves[count] = @intCast(count);
        count += 1;
    }
    if (count <= 1) {
        book.widths[if (count == 0) 0 else scratch.nodes[0].symbol] = 1;
        // A single one-bit symbol has canonical code zero; unused codes are zero too.
        @memset(&book.codes, 0);
        return;
    }
    const Context = struct {
        nodes: []const ConstructionNode,

        fn lessThan(context: @This(), left_index: u16, right_index: u16) bool {
            const left = context.nodes[left_index];
            const right = context.nodes[right_index];
            if (left.weight != right.weight) return left.weight < right.weight;
            return left.symbol < right.symbol;
        }
    };
    std.mem.sort(
        u16,
        scratch.leaves[0..count],
        Context{ .nodes = &scratch.nodes },
        Context.lessThan,
    );
    if (ordinary(scratch, count, maximum, book)) {
        // Preserve package-merge's existing logical work charge, including its exact refusal
        // boundary. The ordinary-tree attempt is bounded by the fixed alphabet size.
        var logical_nodes = count;
        var logical_list_count = count;
        for (1..maximum) |_| {
            const packages = logical_list_count / 2;
            logical_nodes += packages;
            logical_list_count = @min(count * 2 - 2, count + packages);
        }
        try budget.admit(logical_nodes + @as(usize, maximum) * count);
        book.canonical();
        return;
    }
    @memcpy(scratch.lists[0][0..count], scratch.leaves[0..count]);
    var list_count = count;
    var nodes = count;
    var previous: usize = 0;
    for (1..maximum) |_| {
        const packages = list_count / 2;
        for (0..packages) |i| {
            const left = scratch.lists[previous][2 * i];
            const right = scratch.lists[previous][2 * i + 1];
            scratch.nodes[nodes] = .{
                .weight = scratch.nodes[left].weight + scratch.nodes[right].weight,
                .left = left,
                .right = right,
                .symbol = no_symbol,
            };
            scratch.packages[i] = @intCast(nodes);
            nodes += 1;
        }
        const current = 1 - previous;
        var leaf: usize = 0;
        var package: usize = 0;
        list_count = @min(count * 2 - 2, count + packages);
        for (0..list_count) |i| {
            // Leaves precede equal-weight packages; package creation order and symbol order make
            // all construction ties deterministic.
            const take_leaf = blk: {
                if (leaf == count) break :blk false;
                if (package == packages) break :blk true;
                const leaf_weight = scratch.nodes[scratch.leaves[leaf]].weight;
                const package_weight = scratch.nodes[scratch.packages[package]].weight;
                break :blk leaf_weight <= package_weight;
            };
            if (take_leaf) {
                scratch.lists[current][i] = scratch.leaves[leaf];
                leaf += 1;
            } else {
                scratch.lists[current][i] = scratch.packages[package];
                package += 1;
            }
        }
        previous = current;
    }
    for (scratch.lists[previous][0 .. count * 2 - 2]) |node| {
        addLengths(scratch, node, &book.widths);
    }
    try budget.admit(nodes + @as(usize, maximum) * count);
    book.canonical();
}

// Try the ordinary minimum-cost tree, with the same leaf-before-package tie order as the bounded
// construction. If its lengths exceed the bound, the caller runs package-merge.
fn ordinary(scratch: *Scratch, count: usize, maximum: u8, book: *HuffmanCodebook) bool {
    const Queue = struct {
        fn take(state: *Scratch, leaf_count: usize, leaf: *usize, head: *usize, tail: usize) u16 {
            if (leaf.* < leaf_count and (head.* == tail or state.nodes[state.leaves[leaf.*]]
                .weight <= state.nodes[state.packages[head.*]].weight))
            {
                const value = state.leaves[leaf.*];
                leaf.* += 1;
                return value;
            }
            const value = state.packages[head.*];
            head.* += 1;
            return value;
        }
    };
    var leaf: usize = 0;
    var head: usize = 0;
    var tail: usize = 0;
    var nodes = count;
    while (count - leaf + tail - head > 1) {
        const left = Queue.take(scratch, count, &leaf, &head, tail);
        const right = Queue.take(scratch, count, &leaf, &head, tail);
        scratch.nodes[nodes] = .{
            .weight = scratch.nodes[left].weight + scratch.nodes[right].weight,
            .left = left,
            .right = right,
            .symbol = no_symbol,
        };
        scratch.packages[tail] = @intCast(nodes);
        nodes += 1;
        tail += 1;
    }
    // Parent indices follow child indices, so one backward pass computes every depth without
    // recursion or an additional stack. Do not publish widths until the bound is known to fit.
    @memset(scratch.lists[0][0..nodes], 0);
    var index = nodes;
    while (index > count) {
        index -= 1;
        const depth = scratch.lists[0][index] + 1;
        if (depth > maximum) return false;
        const node = scratch.nodes[index];
        scratch.lists[0][node.left] = depth;
        scratch.lists[0][node.right] = depth;
    }
    for (scratch.nodes[0..count], 0..) |node, i| {
        book.widths[node.symbol] = @intCast(scratch.lists[0][i]);
    }
    return true;
}

fn addLengths(scratch: *const Scratch, node: u16, widths: *[286]u8) void {
    const item = scratch.nodes[node];
    if (item.symbol != no_symbol) {
        widths[item.symbol] += 1;
    } else {
        addLengths(scratch, item.left, widths);
        addLengths(scratch, item.right, widths);
    }
}

pub fn canonical(book: *HuffmanCodebook) void {
    var counts: [16]u16 = @splat(0);
    for (book.widths) |width| counts[width] += 1;
    counts[0] = 0;
    var next: [16]u16 = @splat(0);
    var code: u16 = 0;
    for (1..16) |width| {
        code = (code + counts[width - 1]) << 1;
        next[width] = code;
    }
    for (&book.codes, book.widths) |*result, width| {
        if (width == 0) {
            result.* = 0;
            continue;
        }
        result.* = @bitReverse(next[width]) >> @as(u4, @intCast(16 - width));
        next[width] += 1;
    }
}

pub fn fixedWidth(symbol: usize) u8 {
    if (symbol < 144) return 8;
    if (symbol < 256) return 9;
    return if (symbol < 280) 7 else 8;
}

pub fn fixed(book: *HuffmanCodebook, distance: bool) void {
    // The reserved fixed symbols 286/287 are absent from HuffmanCodebook. Their canonical codes
    // still affect lower symbols only through the known RFC formulas.
    for (&book.widths, &book.codes, 0..) |*width, *code, symbol| {
        if (distance) {
            width.* = 5;
            code.* = @bitReverse(@as(u16, @intCast(symbol))) >> 11;
        } else {
            width.* = fixedWidth(symbol);
            const canonical_code = blk: {
                if (symbol < 144) break :blk 48 + symbol;
                if (symbol < 256) break :blk 400 + symbol - 144;
                if (symbol < 280) break :blk symbol - 256;
                break :blk 192 + symbol - 280;
            };
            const value: u16 = @intCast(canonical_code);
            code.* = @bitReverse(value) >> @as(u4, @intCast(16 - width.*));
        }
    }
}

fn testMakeBook(
    encoder: anytype,
    frequencies: []const u32,
    maximum: u8,
    book: *HuffmanCodebook,
) EncodeWorkBudget.Error!void {
    return book.build(frequencies, maximum, &encoder.workspace.huffman, borrows.work(encoder));
}

test "package merge respects Kraft bounds and independent optimal costs" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, .{});
    var book: HuffmanCodebook = undefined;
    // Exhaustively enumerate every admitted 3-bit assignment, independently of package merge.
    // Includes zero-weight symbols and skewed distributions.
    for (2..7) |symbols| {
        var frequencies: [6]u32 = @splat(0);
        for (0..symbols) |i| frequencies[i] = @as(u32, 1) << @as(u5, @intCast(i * 2));
        try testMakeBook(&encoder, frequencies[0..symbols], 3, &book);
        var best: u32 = std.math.maxInt(u32);
        var combinations: usize = 1;
        for (0..symbols) |_| combinations *= 3;
        for (0..combinations) |combination| {
            var remaining = combination;
            var mass: u32 = 0;
            var cost: u32 = 0;
            for (0..symbols) |i| {
                const width: u5 = @intCast(remaining % 3 + 1);
                remaining /= 3;
                mass += @as(u32, 1) << (3 - width);
                cost += frequencies[i] * width;
            }
            if (mass == 8) best = @min(best, cost);
        }
        var actual: u32 = 0;
        for (0..symbols) |i| actual += frequencies[i] * book.widths[i];
        try std.testing.expectEqual(best, actual);
    }
    var frequencies: [286]u32 = @splat(0);
    for (&frequencies, 0..) |*frequency, i| {
        frequency.* = if (i < 25) @as(u32, 1) << @as(u5, @intCast(i)) else 1;
    }
    try testMakeBook(&encoder, &frequencies, 15, &book);
    var mass: u32 = 0;
    for (book.widths) |width| {
        try std.testing.expect(width >= 1 and width <= 15);
        mass += @as(u32, 1) << @as(u5, @intCast(15 - width));
    }
    try std.testing.expectEqual(32768, mass);
    try std.testing.expect(@sizeOf(EncoderWorkspace) <= 8 * 1024 * 1024);
}

test "empty and single-symbol books have zero codes without work charges" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, .{ .limits = .{ .work_units = 0 } });
    var frequencies: [286]u32 = @splat(0);
    var book: HuffmanCodebook = undefined;
    for ([_]u8{ 7, 15 }) |maximum| {
        for (0..frequencies.len + 1) |selected| {
            @memset(std.mem.asBytes(&book), 0xa5);
            if (selected < frequencies.len) frequencies[selected] = 37;
            try testMakeBook(&encoder, &frequencies, maximum, &book);
            const active = if (selected == frequencies.len) 0 else selected;
            for (book.widths, book.codes, 0..) |width, code, symbol| {
                try std.testing.expectEqual(@as(u8, if (symbol == active) 1 else 0), width);
                try std.testing.expectEqual(@as(u16, 0), code);
            }
            try std.testing.expectEqual(@as(u64, 0), encoder.stats.work_units);
            if (selected < frequencies.len) frequencies[selected] = 0;
        }
    }
}

test "bounded books retain widths and work with ordinary-tree fast path" {
    // Expected widths come from an independent package-list construction. Equal weights exercise
    // deterministic symbol ties; the Fibonacci cases exceed the 7- and 15-bit bounds respectively.
    const Case = struct { frequencies: []const u32, widths: []const u8, maximum: u8 };
    const cases = [_]Case{
        .{ .frequencies = &.{ 1, 1 }, .widths = &.{ 1, 1 }, .maximum = 7 },
        .{
            .frequencies = &.{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
            .widths = &.{ 4, 4, 4, 4, 3, 3, 3, 3, 3, 3 },
            .maximum = 7,
        },
        .{
            .frequencies = &.{ 1, 1, 1, 2, 2, 3, 3, 5, 8 },
            .widths = &.{ 5, 5, 4, 4, 4, 3, 3, 2, 2 },
            .maximum = 7,
        },
        .{
            .frequencies = &.{ 0, 1, 1, 2, 0, 3, 5, 8, 13 },
            .widths = &.{ 0, 6, 6, 5, 0, 4, 3, 2, 1 },
            .maximum = 7,
        },
        .{
            .frequencies = &.{ 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610 },
            .widths = &.{ 7, 7, 7, 7, 7, 7, 6, 5, 5, 4, 4, 3, 3, 2, 2 },
            .maximum = 7,
        },
        .{
            .frequencies = &.{
                1,    1,    2,     3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610, 987, 1597, 2584,
                4181, 6765, 10946,
            },
            .widths = &.{ 15, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 6, 6, 5, 5, 4, 4, 3, 3, 2, 2 },
            .maximum = 15,
        },
    };
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    for (cases) |case| {
        try encoder.reset(workspace, .{});
        var expected: HuffmanCodebook = undefined;
        try testMakeBook(&encoder, case.frequencies, case.maximum, &expected);
        try std.testing.expectEqualSlices(u8, case.widths, expected.widths[0..case.widths.len]);
        const full_work = encoder.counts().work_units;
        try std.testing.expect(full_work > 0);
        for ([_]u64{ 0, full_work - 1, full_work }) |budget| {
            try encoder.reset(workspace, .{ .limits = .{ .work_units = budget } });
            var actual: HuffmanCodebook = undefined;
            const result = testMakeBook(&encoder, case.frequencies, case.maximum, &actual);
            if (budget == full_work) {
                try result;
                try std.testing.expectEqual(expected, actual);
                try std.testing.expectEqual(full_work, encoder.counts().work_units);
            } else {
                try std.testing.expectError(error.LimitExceeded, result);
                try std.testing.expectEqual(expected.widths, actual.widths);
                try std.testing.expect(encoder.counts().work_units <= budget);
            }
        }
    }
}

test "bounded books minimize weighted cost for small frequency sets" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, .{});
    const weights = [_]u32{ 0, 1, 2, 5 };
    for (0..1024) |set| {
        var frequencies: [5]u32 = undefined;
        var value = set;
        var active: usize = 0;
        for (&frequencies) |*frequency| {
            frequency.* = weights[value % weights.len];
            value /= weights.len;
            if (frequency.* != 0) active += 1;
        }
        var book: HuffmanCodebook = undefined;
        try testMakeBook(&encoder, &frequencies, 3, &book);
        var cost: u32 = 0;
        var mass: u32 = 0;
        for (frequencies, 0..) |frequency, i| {
            const width = book.widths[i];
            if (frequency != 0) {
                try std.testing.expect(width >= 1 and width <= 3);
                cost += frequency * width;
                mass += @as(u32, 1) << @as(u5, @intCast(3 - width));
            } else if (active != 0 or i != 0) {
                try std.testing.expectEqual(0, width);
            }
        }
        if (active <= 1) {
            if (active == 0) {
                try std.testing.expectEqual(@as(u8, 1), book.widths[0]);
                try std.testing.expectEqual(@as(u16, 0), book.codes[0]);
            }
            try std.testing.expectEqual(@as(u32, if (active == 1) 4 else 0), mass);
            continue;
        }
        try std.testing.expectEqual(@as(u32, 8), mass);
        // Enumerate legal lengths independently of either tree-building algorithm.
        var possibilities: usize = 1;
        for (0..active) |_| possibilities *= 3;
        var best: u32 = std.math.maxInt(u32);
        for (0..possibilities) |assignment| {
            var rest = assignment;
            var candidate_mass: u32 = 0;
            var candidate_cost: u32 = 0;
            for (frequencies) |frequency| {
                if (frequency == 0) continue;
                const width: u5 = @intCast(rest % 3 + 1);
                rest /= 3;
                candidate_mass += @as(u32, 1) << (3 - width);
                candidate_cost += frequency * width;
            }
            if (candidate_mass == 8) best = @min(best, candidate_cost);
        }
        try std.testing.expectEqual(best, cost);
    }
}
