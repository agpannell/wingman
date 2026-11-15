//! Resolve validated public compression choices into one private algorithm/search budget.

const Compression = @import("Compression.zig");

pub const Profile = enum { stored, huffman, four_byte_runs, greedy, lazy, offline };

pub const Effort = struct {
    /// Resolved block construction and parser family.
    profile: Profile,
    /// Candidate-probe bound at each position; zero for profiles without ordinary match search.
    depth: u16,
};

pub fn resolve(compression: Compression) error{InvalidOptions}!Effort {
    try compression.validate();
    if (compression.level == 0) return .{ .profile = .stored, .depth = 0 };
    if (compression.strategy == .huffman_only) return .{ .profile = .huffman, .depth = 0 };
    if (compression.strategy == .four_byte_runs) return .{ .profile = .four_byte_runs, .depth = 0 };
    // Greedy and lazy levels use hash chains; offline levels use a prefix-aware tree. Increasing
    // the level spends different bounded search effort without promising monotonic output size.
    return switch (compression.level) {
        1 => .{ .profile = .greedy, .depth = 4 },
        2 => .{ .profile = .greedy, .depth = 8 },
        3 => .{ .profile = .greedy, .depth = 32 },
        4 => .{ .profile = .lazy, .depth = 64 },
        5 => .{ .profile = .lazy, .depth = 128 },
        6 => .{ .profile = .lazy, .depth = 256 },
        7 => .{ .profile = .offline, .depth = 35 },
        8 => .{ .profile = .offline, .depth = 100 },
        9 => .{ .profile = .offline, .depth = 300 },
        else => unreachable,
    };
}
