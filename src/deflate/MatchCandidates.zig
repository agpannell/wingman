//! Match candidates describe how many source bytes can be copied from each backward distance. Each
//! bounded row retains increasing match lengths for both chain and prefix-tree discovery; parsing
//! chooses which alternatives become output tokens.

const std = @import("std");

const MatchCandidates = @This();
pub const capacity = 16;
const alternatives = capacity;

/// Initialized entries increase in supported match length. The final slot retains the longest
/// candidate when the bounded row is full; consecutive same-distance candidates coalesce.
items: [capacity]Candidate,
/// Initialized prefix of items, at most capacity.
count: u8,

pub const Candidate = struct {
    /// Source bytes covered, from three through 258.
    length: u16,
    /// Backward byte distance within the admitted history window.
    distance: u16,
};

pub fn append(matches: ?*MatchCandidates, length: usize, distance: usize) void {
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
    var row: MatchCandidates = .{ .items = undefined, .count = 0 };
    append(&row, 3, 8);
    append(&row, 12, 8);
    try std.testing.expectEqual(1, row.count);
    try std.testing.expectEqual(Candidate{ .length = 12, .distance = 8 }, row.items[0]);
    append(&row, 24, 16);
    try std.testing.expectEqual(2, row.count);
    try std.testing.expectEqual(Candidate{ .length = 24, .distance = 16 }, row.items[1]);
}

test "coalescing preserves capped usable distances and extends full rows" {
    const Reference = struct {
        fn append(row: *MatchCandidates, length: usize, distance: usize) void {
            const slot = @min(row.count, alternatives - 1);
            row.items[slot] = .{ .length = @intCast(length), .distance = @intCast(distance) };
            row.count = @min(alternatives, row.count + 1);
        }
    };
    var before: MatchCandidates = .{ .items = undefined, .count = 0 };
    var after: MatchCandidates = .{ .items = undefined, .count = 0 };
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
