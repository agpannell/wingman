//! SFNT wrapping checksums over opaque byte storage. Table-specific head adjustment belongs to
//! Directory.Table; this operation sums arbitrary storage without interpreting its contents.

const std = @import("std");

/// Required sum of a complete standalone SFNT file, including head.checkSumAdjustment. Collections
/// do not have this whole-file checksum rule.
pub const target = 0xb1b0afba;

/// Adds big-endian words with unsigned wrap, virtually padding a final partial word with zero. Use
/// Directory.Table.computedChecksum for the head-table adjustment exception. Reads without
/// allocation, mutation, alignment assumptions or validation of the byte contents.
pub fn checksum(source: []const u8) u32 {
    var word_sum: u32 = 0;
    var word_offset: usize = 0;
    while (source.len - word_offset >= 4) : (word_offset += 4) {
        const word = std.mem.readInt(u32, source[word_offset..][0..4], .big);
        word_sum +%= word;
    }

    var partial_word: u32 = 0;
    for (source[word_offset..]) |byte| partial_word = (partial_word << 8) | byte;
    if (word_offset != source.len) {
        const partial_bytes = source.len - word_offset;
        const zero_padding_bytes = 4 - partial_bytes;
        const padding_bits: u5 = @intCast(zero_padding_bytes * 8);
        word_sum +%= partial_word << padding_bits;
    }
    return word_sum;
}

test checksum {
    try std.testing.expectEqual(0x06020304, checksum(&.{ 1, 2, 3, 4, 5 }));
    try std.testing.expectEqual(0, checksum(&.{}));
}
