//! Bounded prefix-aware offline match search over one slab and its copied history. The tree
//! organization and short-match table are informed by libdeflate 1.26's `lib/bt_matchfinder.h`; no
//! upstream implementation is linked or copied.

const std = @import("std");

pub const alternatives = 16;
const child_slots = 32768 + 1;
const sparse_reset_limit = 4096;
const none = std.math.maxInt(u32);

pub const Match = struct { length: u16, distance: u16 };
pub const Matches = struct { items: [alternatives]Match, count: u8 };
pub const Stats = struct { units: u32 = 0, probes: u32 = 0 };
pub const Error = error{LimitExceeded};

pub const Workspace = struct {
    short_heads: [65536]u32,
    long_heads: [65536]u32,
    // An extra slot keeps the current insertion distinct from the oldest in-window candidate.
    children: [child_slots][2]u16,

    pub fn resetAll(self: *Workspace) void {
        @memset(&self.short_heads, none);
        @memset(&self.long_heads, none);
    }

    pub fn reset(self: *Workspace, data: []const u8) void {
        if (data.len <= sparse_reset_limit) {
            // Only keys present in this slab can be read, even after another search phase.
            for (0..data.len -| 2) |position| {
                const source = data[position..];
                const first3 = @as(
                    u32,
                    source[0],
                ) | (@as(u32, source[1]) << 8) | (@as(u32, source[2]) << 16);
                self.short_heads[hash(first3)] = none;
                if (source.len >= 4) {
                    self.long_heads[hash(std.mem.readInt(u32, source[0..4], .little))] = none;
                }
            }
        } else {
            @memset(&self.short_heads, none);
            @memset(&self.long_heads, none);
        }
    }
};

fn hash(value: u32) u16 {
    return @truncate((value *% 0x1e35a7bd) >> 16);
}

// Child links are backward distances from their parent; zero represents an empty link.
fn childPosition(parent: u32, distance: u16) u32 {
    if (distance == 0) return none;
    return parent - distance;
}

fn setChild(link: *u16, parent: u32, child: u32, earliest: usize) void {
    if (child == none or child < earliest) {
        link.* = 0;
        return;
    }
    std.debug.assert(child < parent and parent - child <= 32768);
    link.* = @intCast(parent - child);
}

fn work(comptime bounded: bool, stats: *Stats, budget: u64) Error!void {
    if (bounded and stats.units >= budget) return error.LimitExceeded;
    stats.units += 1;
}

fn append(matches: ?*Matches, length: usize, distance: usize) void {
    const row = matches orelse return;
    if (row.count != 0) {
        const previous = &row.items[row.count - 1];
        if (previous.distance == distance) {
            // A longer match at the same distance covers every length of the earlier match.
            previous.length = @intCast(length);
            return;
        }
    }
    const slot = @min(row.count, alternatives - 1);
    row.items[slot] = .{ .length = @intCast(length), .distance = @intCast(distance) };
    row.count = @min(alternatives, row.count + 1);
}

test "longer matches replace dominated alternatives at the same distance" {
    var row: Matches = .{ .items = undefined, .count = 0 };
    append(&row, 3, 8);
    append(&row, 12, 8);
    try std.testing.expectEqual(1, row.count);
    try std.testing.expectEqual(Match{ .length = 12, .distance = 8 }, row.items[0]);
    append(&row, 24, 16);
    try std.testing.expectEqual(2, row.count);
    try std.testing.expectEqual(Match{ .length = 24, .distance = 16 }, row.items[1]);
}

test "coalescing preserves capped usable distances and extends full rows" {
    const Reference = struct {
        fn append(row: *Matches, length: usize, distance: usize) void {
            const slot = @min(row.count, alternatives - 1);
            row.items[slot] = .{ .length = @intCast(length), .distance = @intCast(distance) };
            row.count = @min(alternatives, row.count + 1);
        }
    };
    var before: Matches = .{ .items = undefined, .count = 0 };
    var after: Matches = .{ .items = undefined, .count = 0 };
    // All distances and lengths below are legal against this repeated history and source.
    const data: [128]u8 = @splat('a');
    const position = 64;
    for (0..20) |i| {
        const length = 3 + i;
        const distance = if (i < 2) 8 else 8 + i;
        try std.testing.expectEqualSlices(
            u8,
            data[position..][0..length],
            data[position - distance ..][0..length],
        );
        Reference.append(&before, length, distance);
        append(&after, length, distance);
        for (3..length + 1) |usable_length| {
            for (before.items[0..before.count]) |old| {
                if (old.length < usable_length) continue;
                var found = false;
                for (after.items[0..after.count]) |new| {
                    if (new.length >= usable_length and new.distance == old.distance) found = true;
                }
                try std.testing.expect(found);
            }
        }
    }
    try std.testing.expectEqual(alternatives, after.count);
    try std.testing.expect(after.items[14].length > before.items[14].length);
    const prior = after.items[alternatives - 1];
    append(&after, prior.length + 1, prior.distance);
    try std.testing.expectEqual(alternatives, after.count);
    try std.testing.expectEqual(prior.length + 1, after.items[alternatives - 1].length);
    try std.testing.expectEqual(prior.distance, after.items[alternatives - 1].distance);
}

/// Inserts the current position and records increasing match lengths when requested. Each examined
/// prior candidate and each eight-byte comparison consumes one unit.
pub fn insertAndFind(
    comptime bounded: bool,
    workspace: *Workspace,
    data: []const u8,
    position: usize,
    window: usize,
    depth: usize,
    nice: usize,
    matches: ?*Matches,
    budget: u64,
    partial: *Stats,
) Error!Stats {
    return findImpl(
        false,
        bounded,
        workspace,
        data,
        position,
        0,
        window,
        depth,
        nice,
        matches,
        budget,
        partial,
    );
}

// Retained coordinates survive slab moves; data begins at origin.
pub inline fn insertAndFindAt(
    comptime bounded: bool,
    workspace: *Workspace,
    data: []const u8,
    position: usize,
    origin: usize,
    window: usize,
    depth: usize,
    nice: usize,
    matches: ?*Matches,
    budget: u64,
    partial: *Stats,
) Error!Stats {
    return findImpl(
        true,
        bounded,
        workspace,
        data,
        position,
        origin,
        window,
        depth,
        nice,
        matches,
        budget,
        partial,
    );
}

inline fn findImpl(
    comptime shifted: bool,
    comptime bounded: bool,
    workspace: *Workspace,
    data: []const u8,
    position: usize,
    origin: usize,
    window: usize,
    depth: usize,
    nice: usize,
    matches: ?*Matches,
    budget: u64,
    partial: *Stats,
) Error!Stats {
    var stats: Stats = .{};
    defer partial.* = stats;
    if (matches) |row| row.count = 0;
    const maximum = @min(258, data.len - position);
    if (maximum < 3) return stats;
    const absolute = if (shifted) origin + position else position;
    const earliest = if (shifted) @max(origin, absolute -| window) else position -| window;
    const base = if (shifted) origin else 0;
    const source = data[position..];
    const first3 = @as(u32, source[0]) | (@as(u32, source[1]) << 8) | (@as(u32, source[2]) << 16);
    const short_key = hash(first3);
    const short = workspace.short_heads[short_key];
    workspace.short_heads[short_key] = @intCast(absolute);
    var best: usize = 2;
    if (short != none and short >= earliest) {
        try work(bounded, &stats, budget);
        stats.probes += 1;
        if (std.mem.eql(u8, data[@as(usize, short) - base ..][0..3], source[0..3])) {
            best = 3;
            append(matches, best, absolute - short);
        }
    }
    if (maximum < 4) return stats;

    const long_key = hash(std.mem.readInt(u32, source[0..4], .little));
    var current = workspace.long_heads[long_key];
    workspace.long_heads[long_key] = @intCast(absolute);
    workspace.children[absolute % child_slots] = .{ 0, 0 };
    var less = &workspace.children[absolute % child_slots][0];
    var greater = &workspace.children[absolute % child_slots][1];
    var less_parent: u32 = @intCast(absolute);
    var greater_parent: u32 = @intCast(absolute);
    var less_prefix: usize = 0;
    var greater_prefix: usize = 0;
    var left = depth;
    while (current != none and current >= earliest and left != 0) : (left -= 1) {
        try work(bounded, &stats, budget);
        stats.probes += 1;
        const prior = data[@as(usize, current) - base ..];
        var length = @min(less_prefix, greater_prefix);
        while (length + 8 <= maximum) : (length += 8) {
            try work(bounded, &stats, budget);
            const difference = std.mem.readInt(
                u64,
                prior[length..][0..8],
                .little,
            ) ^ std.mem.readInt(u64, source[length..][0..8], .little);
            if (difference != 0) {
                length += @as(usize, @intCast(@ctz(difference))) / 8;
                break;
            }
        }
        while (length < maximum and prior[length] == source[length]) : (length += 1) {}
        if (length > best) {
            best = length;
            append(matches, length, absolute - current);
        }
        if (length >= @min(nice, maximum)) {
            setChild(
                less,
                less_parent,
                childPosition(current, workspace.children[current % child_slots][0]),
                earliest,
            );
            setChild(
                greater,
                greater_parent,
                childPosition(current, workspace.children[current % child_slots][1]),
                earliest,
            );
            return stats;
        }
        if (prior[length] < source[length]) {
            setChild(less, less_parent, current, earliest);
            less = &workspace.children[current % child_slots][1];
            less_parent = current;
            current = childPosition(current, less.*);
            less_prefix = length;
        } else {
            setChild(greater, greater_parent, current, earliest);
            greater = &workspace.children[current % child_slots][0];
            greater_parent = current;
            current = childPosition(current, greater.*);
            greater_prefix = length;
        }
    }
    less.* = 0;
    greater.* = 0;
    return stats;
}

test "unbounded tree records valid matches and finds four-byte maxima" {
    const allocator = std.testing.allocator;
    const workspace = try allocator.create(Workspace);
    defer allocator.destroy(workspace);
    var data: [512]u8 = undefined;
    for (0..4) |pattern| {
        for (&data, 0..) |*byte, i| {
            byte.* = switch (pattern) {
                0 => 'a',
                1 => "abcXabcYabcz"[i % 12],
                2 => @truncate((i *% 73 +% i / 7) >> 2),
                else => if (i % 13 < 4) 'a' else @truncate(i *% 47),
            };
        }
        for ([_]usize{ 32, 256, 32768 }) |window| {
            workspace.reset(&data);
            for (0..data.len) |position| {
                var matches: Matches = .{ .items = undefined, .count = 0 };
                var partial: Stats = undefined;
                const stats = try insertAndFind(
                    false,
                    workspace,
                    &data,
                    position,
                    window,
                    1024,
                    258,
                    &matches,
                    std.math.maxInt(u64),
                    &partial,
                );
                try std.testing.expectEqual(stats, partial);
                try std.testing.expect(stats.units >= stats.probes);
                var previous: usize = 2;
                for (matches.items[0..matches.count]) |match| {
                    try std.testing.expect(match.length > previous);
                    try std.testing.expect(match.distance > 0 and match.distance <= window);
                    try std.testing.expect(match.distance <= position);
                    try std.testing.expect(match.length <= @min(258, data.len - position));
                    try std.testing.expectEqualSlices(
                        u8,
                        data[position..][0..match.length],
                        data[position - match.distance ..][0..match.length],
                    );
                    previous = match.length;
                }
                var longest: usize = 0;
                const earliest = position -| window;
                for (earliest..position) |prior| {
                    var length: usize = 0;
                    const maximum = @min(258, data.len - position);
                    while (length < maximum and data[prior + length] == data[position + length]) {
                        length += 1;
                    }
                    longest = @max(longest, length);
                }
                if (longest >= 4) try std.testing.expectEqual(longest, previous);
            }
        }
    }
}

test "finite tree search refuses each smaller allowance" {
    const allocator = std.testing.allocator;
    const workspace = try allocator.create(Workspace);
    defer allocator.destroy(workspace);
    var data: [512]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = "abcXabcYabcz"[i % 12];
    const position = 255;
    const Helper = struct {
        fn prepare(tree: *Workspace, bytes: []const u8, end: usize) !void {
            tree.reset(bytes);
            for (0..end) |i| {
                var partial: Stats = undefined;
                _ = try insertAndFind(false, tree, bytes, i, 256, 300, 258, null, 0, &partial);
            }
        }
    };
    try Helper.prepare(workspace, &data, position);
    var expected: Matches = .{ .items = undefined, .count = 0 };
    var partial: Stats = undefined;
    const full = try insertAndFind(
        false,
        workspace,
        &data,
        position,
        256,
        300,
        258,
        &expected,
        0,
        &partial,
    );
    try std.testing.expect(full.units > 0);
    for (0..@as(usize, full.units) + 1) |budget| {
        try Helper.prepare(workspace, &data, position);
        var actual: Matches = .{ .items = undefined, .count = 0 };
        const result = insertAndFind(
            true,
            workspace,
            &data,
            position,
            256,
            300,
            258,
            &actual,
            budget,
            &partial,
        );
        if (budget < full.units) {
            try std.testing.expectError(error.LimitExceeded, result);
            try std.testing.expectEqual(budget, partial.units);
            try std.testing.expect(partial.probes <= partial.units);
        } else {
            const measured = try result;
            try std.testing.expectEqual(full.units, measured.units);
            try std.testing.expectEqual(full.probes, measured.probes);
            try std.testing.expectEqual(expected.count, actual.count);
            try std.testing.expectEqualSlices(
                Match,
                expected.items[0..expected.count],
                actual.items[0..actual.count],
            );
        }
    }
}

test "bounded and early-terminated trees emit valid matches after later insertions" {
    const workspace = try std.testing.allocator.create(Workspace);
    defer std.testing.allocator.destroy(workspace);
    var data: [1024]u8 = undefined;
    for (0..3) |pattern| {
        for (&data, 0..) |*byte, i| {
            byte.* = switch (pattern) {
                0 => "aaaaaaaabaaaaaaacaaaaaaadaaaaaaae"[i % 33],
                1 => @truncate((i *% 37 +% (i / 97) *% 13) ^ (i / 17)),
                else => if (i % 271 < 260) 'x' else @truncate(i),
            };
        }
        for ([_]usize{ 32, 256, 32768 }) |window| {
            for ([_]usize{ 1, 8, 35 }) |depth| {
                for ([_]usize{ 16, 75, 150, 258 }) |nice| {
                    workspace.reset(&data);
                    for (0..data.len) |position| {
                        var row: Matches = .{ .items = undefined, .count = 0 };
                        var partial: Stats = undefined;
                        _ = try insertAndFind(
                            false,
                            workspace,
                            &data,
                            position,
                            window,
                            depth,
                            nice,
                            &row,
                            0,
                            &partial,
                        );
                        var previous: usize = 2;
                        for (row.items[0..row.count]) |match| {
                            try std.testing.expect(match.length > previous);
                            try std.testing.expect(match.length <= @min(258, data.len - position));
                            try std.testing.expect(match.distance > 0 and match.distance <= window);
                            try std.testing.expect(match.distance <= position);
                            try std.testing.expectEqualSlices(
                                u8,
                                data[position..][0..match.length],
                                data[position - match.distance ..][0..match.length],
                            );
                            previous = match.length;
                        }
                    }
                }
            }
        }
    }
}

test "nice-length splice retains both ordered subtrees" {
    const workspace = try std.testing.allocator.create(Workspace);
    defer std.testing.allocator.destroy(workspace);
    var data: [512]u8 = @splat('z');
    for ([_]usize{ 0, 128, 256, 384 }, "BCDC") |position, next| {
        @memcpy(data[position..][0..4], "aaaa");
        data[position + 4] = next;
    }
    workspace.reset(&data);
    for ([_]usize{ 0, 128, 256 }) |position| {
        var partial: Stats = undefined;
        _ = try insertAndFind(false, workspace, &data, position, 512, 35, 75, null, 0, &partial);
    }
    try std.testing.expectEqual(@as(u32, 0), childPosition(128, workspace.children[128][0]));
    try std.testing.expectEqual(@as(u32, 128), childPosition(256, workspace.children[256][0]));
    var row: Matches = .{ .items = undefined, .count = 0 };
    var partial: Stats = undefined;
    _ = try insertAndFind(false, workspace, &data, 384, 512, 35, 75, &row, 0, &partial);
    try std.testing.expect(row.count > 0);
    try std.testing.expect(row.items[row.count - 1].length >= 75);
    try std.testing.expectEqual(@as(u32, 0), childPosition(384, workspace.children[384][0]));
    try std.testing.expectEqual(@as(u32, 256), childPosition(384, workspace.children[384][1]));
}

test "circular children retain exactly-window matches across slot reuse" {
    const allocator = std.testing.allocator;
    const workspace = try allocator.create(Workspace);
    defer allocator.destroy(workspace);
    const data = try allocator.alloc(u8, 65540);
    defer allocator.free(data);
    for ([_]usize{ 256, 32768 }) |window| {
        @memset(data, 'z');
        for ([_]usize{ 0, window, window * 2 }) |position| {
            @memcpy(data[position..][0..4], "abcd");
        }
        const active = data[0 .. window * 2 + 4];
        workspace.reset(active);
        for (0..active.len) |position| {
            var row: Matches = .{ .items = undefined, .count = 0 };
            var partial: Stats = undefined;
            _ = try insertAndFind(
                false,
                workspace,
                active,
                position,
                window,
                64,
                258,
                &row,
                0,
                &partial,
            );
            if (position == window or position == window * 2) {
                var found = false;
                for (row.items[0..row.count]) |match| {
                    if (match.distance == window and match.length >= 4) found = true;
                }
                try std.testing.expect(found);
            }
        }
    }
}

test "sparse reset ignores poisoned heads and agrees with full clearing" {
    const allocator = std.testing.allocator;
    const candidate = try allocator.create(Workspace);
    defer allocator.destroy(candidate);
    const reference = try allocator.create(Workspace);
    defer allocator.destroy(reference);
    var bytes: [4097]u8 = undefined;
    for (0..2) |pattern| {
        for (&bytes, 0..) |*byte, i| {
            byte.* = if (pattern == 0) "short-repeating-pattern"[i % 23] else @truncate(
                (i *% 73 +% i / 11) ^ (i / 17),
            );
        }
        for ([_]usize{ 0, 1, 2, 3, 4, 255, 256, 257, 4095, 4096, 4097 }) |size| {
            const input = bytes[0..size];
            @memset(std.mem.asBytes(candidate), 0xa5);
            candidate.reset(input);
            @memset(&reference.short_heads, none);
            @memset(&reference.long_heads, none);
            for (0..size) |position| {
                var a: Matches = .{ .items = undefined, .count = 0 };
                var b: Matches = .{ .items = undefined, .count = 0 };
                var partial_a: Stats = undefined;
                var partial_b: Stats = undefined;
                const stats_a = try insertAndFind(
                    false,
                    candidate,
                    input,
                    position,
                    256,
                    35,
                    75,
                    &a,
                    0,
                    &partial_a,
                );
                const stats_b = try insertAndFind(
                    false,
                    reference,
                    input,
                    position,
                    256,
                    35,
                    75,
                    &b,
                    0,
                    &partial_b,
                );
                try std.testing.expectEqual(stats_b, stats_a);
                try std.testing.expectEqual(b.count, a.count);
                try std.testing.expectEqualSlices(Match, b.items[0..b.count], a.items[0..a.count]);
            }
        }
    }
}

test "word mismatch locates the first different byte with bounded work" {
    const allocator = std.testing.allocator;
    const workspace = try allocator.create(Workspace);
    defer allocator.destroy(workspace);
    var data: [558]u8 = undefined;
    const position = 300;
    for (4..259) |mismatch| {
        for (&data, 0..) |*byte, i| byte.* = @truncate(i *% 73 +% i / 7);
        @memcpy(data[position..][0..258], data[0..258]);
        if (mismatch < 258) data[position + mismatch] ^= 1;

        workspace.reset(&data);
        var partial: Stats = undefined;
        _ = try insertAndFind(false, workspace, &data, 0, 512, 35, 258, null, 0, &partial);
        var row: Matches = undefined;
        const complete = try insertAndFind(
            false,
            workspace,
            &data,
            position,
            512,
            35,
            258,
            &row,
            0,
            &partial,
        );
        try std.testing.expectEqual(1, row.count);
        try std.testing.expectEqual(
            Match{ .length = @intCast(mismatch), .distance = position },
            row.items[0],
        );
        try std.testing.expect(complete.units > 0);

        for ([_]u64{ complete.units - 1, complete.units }) |budget| {
            workspace.reset(&data);
            _ = try insertAndFind(false, workspace, &data, 0, 512, 35, 258, null, 0, &partial);
            const bounded = insertAndFind(
                true,
                workspace,
                &data,
                position,
                512,
                35,
                258,
                &row,
                budget,
                &partial,
            );
            if (budget == complete.units) {
                try std.testing.expectEqual(complete, try bounded);
                try std.testing.expectEqual(
                    Match{ .length = @intCast(mismatch), .distance = position },
                    row.items[0],
                );
            } else {
                try std.testing.expectError(error.LimitExceeded, bounded);
                try std.testing.expectEqual(budget, partial.units);
            }
        }
    }
}

test "relative links preserve the window boundary and expire stale children" {
    var link: u16 = 0;
    setChild(&link, 40000, 7232, 7232);
    try std.testing.expectEqual(@as(u16, 32768), link);
    try std.testing.expectEqual(@as(u32, 7232), childPosition(40000, link));
    setChild(&link, 40000, 7232, 7233);
    try std.testing.expectEqual(@as(u16, 0), link);
    try std.testing.expectEqual(none, childPosition(40000, link));
    setChild(&link, 40000, none, 0);
    try std.testing.expectEqual(@as(u16, 0), link);
}

test "derived coordinates preserve rows and work across supported windows" {
    const allocator = std.testing.allocator;
    const baseline = try allocator.create(Workspace);
    defer allocator.destroy(baseline);
    const shifted = try allocator.create(Workspace);
    defer allocator.destroy(shifted);
    const data = try allocator.alloc(u8, 4096);
    defer allocator.free(data);
    var state: u32 = 0x74a521;
    for (data, 0..) |*byte, i| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = if (i < 256) @truncate(state) else data[i - 256];
    }
    var positions: usize = 0;
    for ([_]usize{ 32768, (1 << 31) - 32768 }) |origin| {
        for ([_]usize{ 256, 512, 1024, 2048, 4096, 8192, 16384, 32768 }) |window| {
            baseline.resetAll();
            shifted.resetAll();
            for (0..data.len) |position| {
                var x: Matches = .{ .items = undefined, .count = 0 };
                var y: Matches = .{ .items = undefined, .count = 0 };
                var px: Stats = undefined;
                var py: Stats = undefined;
                const sx = try insertAndFind(
                    false,
                    baseline,
                    data,
                    position,
                    window,
                    300,
                    258,
                    &x,
                    0,
                    &px,
                );
                const sy = try insertAndFindAt(
                    false,
                    shifted,
                    data,
                    position,
                    origin,
                    window,
                    300,
                    258,
                    &y,
                    0,
                    &py,
                );
                try std.testing.expectEqual(sx, sy);
                try std.testing.expectEqual(px, py);
                try std.testing.expectEqual(x.count, y.count);
                try std.testing.expectEqualSlices(Match, x.items[0..x.count], y.items[0..y.count]);
                positions += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 4096 * 16), positions);
}
