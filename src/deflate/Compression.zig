//! Compression effort and strategy for native RFC 1951 encoding.

const std = @import("std");

const Compression = @This();

/// Level 0 stores bytes; 1–3 use greedy matching, 4–6 use lazy matching and 7–9 use offline
/// parsing. Levels select different search budgets and usually trade speed for size, but neither
/// size nor latency is guaranteed to be monotonic. Values above 9 return InvalidOptions. The
/// default 6 uses lazy matching. Levels are not equivalent to another library's numbers.
level: u8 = 6,
/// Level 0 always stores bytes; other levels select ordinary, literal-only or four-byte runs.
strategy: Strategy = .default,
/// Search effort for the next position when a lazy match is pending. Reduced lookahead is available
/// only with ordinary matching at levels 4–6. It can change the wire, work consumed and whether a
/// finite work limit is reached; neither size nor speed is guaranteed to improve. Full lookahead is
/// the default and has no effect on levels without lazy matching. Automatic chooses reduced for
/// ordinary level 6 and full for other valid levels and strategies.
lazy_lookahead: LazyLookahead = .full,
/// Effort spent pricing retained match lengths and distances during offline parsing. Choices other
/// than full are available only with ordinary matching at levels 7–9. They can change output and
/// work; neither size nor speed is guaranteed to improve. Full is the default.
offline_pricing: OfflinePricing = .full,
/// When to stop refining offline prices. Early stopping is available only with ordinary matching at
/// levels 7–9. It can change output and work; neither size nor speed is guaranteed to improve.
/// Standard refinement is the default.
offline_refinement: OfflineRefinement = .standard,

/// Rejects unsupported level and strategy combinations without changing encoder state.
pub fn validate(self: Compression) error{InvalidOptions}!void {
    if (self.level > 9) return error.InvalidOptions;
    if (self.lazy_lookahead == .reduced and (self.level < 4 or self.level > 6 or self.strategy !=
        .default)) return error.InvalidOptions;
    if (self.offline_pricing != .full and (self.level < 7 or self.level > 9 or self.strategy !=
        .default)) return error.InvalidOptions;
    if (self.offline_refinement != .standard and (self.level < 7 or self.level > 9 or self
        .strategy != .default)) return error.InvalidOptions;
}

test validate {
    for (0..10) |level| {
        for ([_]Strategy{ .default, .huffman_only, .four_byte_runs }) |strategy| {
            const full: Compression = .{ .level = @intCast(level), .strategy = strategy };
            try full.validate();
            var automatic = full;
            automatic.lazy_lookahead = .automatic;
            try automatic.validate();
            var reduced = full;
            reduced.lazy_lookahead = .reduced;
            if (level >= 4 and level <= 6 and strategy == .default) {
                try reduced.validate();
            } else {
                try std.testing.expectError(error.InvalidOptions, reduced.validate());
            }
            inline for (.{ .reduced, .maximum_lengths }) |policy| {
                var pruned_offline = full;
                pruned_offline.offline_pricing = policy;
                if (level >= 7 and strategy == .default) {
                    try pruned_offline.validate();
                } else {
                    try std.testing.expectError(error.InvalidOptions, pruned_offline.validate());
                }
            }
            var early = full;
            early.offline_refinement = .early;
            if (level >= 7 and strategy == .default) {
                try early.validate();
            } else {
                try std.testing.expectError(error.InvalidOptions, early.validate());
            }
        }
    }
    try std.testing.expectError(error.InvalidOptions, (Compression{ .level = 10 }).validate());
    try std.testing.expectError(error.InvalidOptions, (Compression{ .level = 255 }).validate());
}

/// Optional restriction on how the encoder represents source bytes.
pub const Strategy = enum {
    /// Select the matching and parsing work described by the level.
    default,
    /// Emit literals without match search, while still selecting stored or Huffman blocks.
    huffman_only,
    /// Match only repeated four-byte patterns, using prebuilt dynamic codebooks or stored blocks.
    /// Levels 1–9 use the same fast policy; level 0 stores. Useful for four-byte residuals, but
    /// output may be much larger on other data. This is a byte-stream policy: matches may cross
    /// input fragments and image rows. It does not select a PNG filter.
    four_byte_runs,
};

/// Effort spent pricing retained lengths and distances for offline matches.
pub const OfflinePricing = enum {
    /// Consider every retained match that supports each length and use the least costly, choosing
    /// the nearer distance on a tie.
    full,
    /// Consider the first retained match that supports each length. It need not be the nearest.
    reduced,
    /// Consider only the maximum length of each retained match. This skips shorter lengths and
    /// distances that are useful only at those lengths. For equal prices, retain the earlier
    /// candidate; the resulting distance need not be the nearest.
    maximum_lengths,
};

/// Controls the number of price-refinement passes for offline parsing.
pub const OfflineRefinement = enum {
    /// Continue until dynamic cost stops improving or the eight-pass bound is reached.
    standard,
    /// After the second pass, stop if its dynamic cost improved by at most 1% over the first.
    /// Otherwise continue with standard refinement. The reference parse and both passes remain
    /// eligible. This stopping threshold does not bound the change in final compressed size.
    early,
};

/// Effort spent checking whether the position after a lazy match is preferable.
pub const LazyLookahead = enum {
    /// Use the level's ordinary search effort.
    full,
    /// Spend less effort on the lookahead search while retaining the initial search effort.
    reduced,
    /// Use reduced lookahead for ordinary level 6 and full lookahead for other combinations.
    automatic,
};
