//! Least-significant-bit-first DEFLATE input with exact source bounds. Refills may load whole-byte
//! lookahead; consumed() excludes those unread bytes so enclosing trailers remain untouched.

const std = @import("std");

/// The requested bits are absent from the encoded input.
pub const Error = error{InvalidStream};
const BitReader = @This();

/// Immutable encoded input borrowed while lookahead remains buffered.
source: []const u8,
/// Next source byte to load, including bytes held as lookahead.
position: usize = 0,
/// Low-order encoded bits, consumed least-significant bit first.
value: u64 = 0,
/// Number of consumable low bits in value.
count: u8 = 0,

/// Refills toward a request of at most 56 bits, stopping at the exact end of source. The caller
/// checks count before consuming a field; this operation does not report truncation.
pub fn refill(self: *BitReader, needed: u8) void {
    // Repeated reads usually consume buffered bits. Hinting this return and invalid-input guards
    // favor complete input and bounded output.
    if (self.count >= needed) {
        @branchHint(.likely);
        return;
    }
    if (self.source.len - self.position >= 8) {
        self.refillWide();
    } else {
        while (self.count < needed and self.position < self.source.len) {
            self.value |= @as(u64, self.source[self.position]) << @as(u6, @intCast(self.count));
            self.position += 1;
            self.count += 8;
        }
    }
}

/// Refills from eight in-range source bytes, even when enough bits are already buffered. Advancing
/// zero bytes preserves the unconsumed immutable lookahead.
pub fn refillWide(self: *BitReader) void {
    std.debug.assert(self.source.len - self.position >= 8);
    // Only 56..63 bits become consumable. The extra loaded bits describe the same immutable bytes
    // at the next refill and are never consumed early.
    const word = std.mem.readInt(u64, self.source[self.position..][0..8], .little);
    self.value |= word << @as(u6, @intCast(self.count));
    // The refill preserves the low three count bits and sets the upper bits to 56. Count stays in
    // 56..63 without a dependent add/multiply.
    const added = 7 - self.count / 8;
    self.position += added;
    self.count |= 56;
}

/// Reads and consumes up to sixteen bits, returning InvalidStream if the field is truncated.
pub fn take(self: *BitReader, count: u8) Error!u16 {
    self.refill(count);
    if (self.count < count) {
        @branchHint(.unlikely);
        return error.InvalidStream;
    }
    const mask = (@as(u64, 1) << @as(u6, @intCast(count))) - 1;
    const value: u16 = @truncate(self.value & mask);
    self.drop(count);
    return value;
}

/// Consumes up to sixteen already buffered bits. Paired and payload prefixes prove availability for
/// a whole token before calling this operation.
pub fn takeBuffered(self: *BitReader, count: u8) u16 {
    std.debug.assert(self.count >= count);
    const mask = (@as(u64, 1) << @as(u6, @intCast(count))) - 1;
    const value: u16 = @truncate(self.value & mask);
    self.drop(count);
    return value;
}

/// Discards count bits after the caller proves availability. The remaining count describes
/// consumable bits, including across word refills.
pub fn drop(self: *BitReader, count: u8) void {
    self.value >>= @as(u6, @intCast(count));
    self.count -= count;
}

/// Discards the partial current byte, leaving the next unread byte at the low end of value.
pub fn alignByte(self: *BitReader) void {
    self.drop(self.count & 7);
}

/// Counts bytes touched by consumed bits, excluding whole bytes of unread lookahead.
pub fn consumed(self: BitReader) usize {
    return self.position - self.count / 8;
}

test "wide bit refills preserve unaligned source bits and consumed boundaries" {
    var source: [24]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index * 37 + 11);
    for (0..8) |offset| {
        for (0..36) |remaining| {
            const count: u8 = @intCast(remaining);
            const initial_word = std.mem.readInt(u64, source[offset..][0..8], .little);
            var bits = BitReader{
                .source = source[offset..],
                .position = 7,
                .value = initial_word >> @as(u6, @intCast(56 - count)),
                .count = count,
            };
            // Wide refills may already contain the overlapping next byte. It describes immutable
            // input and must not change consumable bits.
            const before = bits.consumed();
            bits.refill(36);
            const expected_count = 56 + (remaining & 7);
            try std.testing.expectEqual(expected_count, bits.count);
            try std.testing.expectEqual(before, bits.consumed());
            for (0..expected_count) |bit| {
                const source_bit = 56 - remaining + bit;
                const bit_offset: u3 = @intCast(source_bit & 7);
                const expected = (source[offset + source_bit / 8] >> bit_offset) & 1;
                try std.testing.expectEqual(expected, (bits.value >> @as(u6, @intCast(bit))) & 1);
            }
        }
    }
}

test "scheduled wide refills preserve already buffered and unconsumed bits" {
    var backing: [63]u8 = undefined;
    for (&backing, 0..) |*byte, index| byte.* = @truncate(index * 37 + index / 3 + 11);
    for (0..32) |alignment| {
        const source = backing[alignment..][0..32];
        for (0..64) |buffered| {
            const start = 64 - buffered;
            var value: u64 = 0;
            for (0..buffered) |index| {
                const position = start + index;
                const bit = (source[position / 8] >> @as(u3, @intCast(position & 7))) & 1;
                value |= @as(u64, bit) << @as(u6, @intCast(index));
            }
            var bits = BitReader{
                .source = source,
                .position = 8,
                .count = @intCast(buffered),
                .value = value,
            };
            for (0..64) |index| {
                // Repeated refills may add no bytes. Expected bits come directly from the source,
                // independent of the buffer representation.
                bits.refillWide();
                const position = start + index;
                const expected = (source[position / 8] >> @as(u3, @intCast(position & 7))) & 1;
                try std.testing.expectEqual(expected, try bits.take(1));
                try std.testing.expectEqual((position + 1 + 7) / 8, bits.consumed());
            }
        }
    }
}
