//! Exact bounded DEFLATE bit input with wide and scalar tail refills.

const std = @import("std");

const protocol = @import("format.zig");

const Error = protocol.Error;

/// Least-significant-bit-first input. Source bytes stay immutable while buffered lookahead exists;
/// position includes loaded bytes, while count describes the low consumable bits in value.
pub const Bits = struct {
    source: []const u8,
    position: usize = 0,
    value: u64 = 0,
    count: u8 = 0,

    /// Refills toward a request of at most 56 bits, stopping at the exact end of source. The caller
    /// checks count before consuming a field; this operation does not report truncation.
    pub fn refill(self: *Bits, needed: u8) void {
        // Repeated reads usually consume buffered bits. Hinting this return and invalid-input
        // guards favor complete input and bounded output.
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

    /// Refills from eight in-range source bytes, even when enough bits are already buffered.
    /// Advancing zero bytes preserves the unconsumed immutable lookahead.
    pub fn refillWide(self: *Bits) void {
        std.debug.assert(self.source.len - self.position >= 8);
        // Only 56..63 bits become consumable. The extra loaded bits describe the same immutable
        // bytes at the next refill and are never consumed early.
        const word = std.mem.readInt(u64, self.source[self.position..][0..8], .little);
        self.value |= word << @as(u6, @intCast(self.count));
        // The refill preserves the low three count bits and sets the upper bits to 56. Count stays
        // in 56..63 without a dependent add/multiply.
        const added = 7 - self.count / 8;
        self.position += added;
        self.count |= 56;
    }

    /// Reads and consumes up to sixteen bits, returning InvalidStream if the field is truncated.
    pub fn take(self: *Bits, count: u8) Error!u16 {
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

    /// Consumes up to sixteen already buffered bits. Paired and payload prefixes prove availability
    /// for a whole token before calling this operation.
    pub fn takeBuffered(self: *Bits, count: u8) u16 {
        std.debug.assert(self.count >= count);
        const mask = (@as(u64, 1) << @as(u6, @intCast(count))) - 1;
        const value: u16 = @truncate(self.value & mask);
        self.drop(count);
        return value;
    }

    /// Discards count bits after the caller proves availability. The remaining count describes
    /// consumable bits, including across word refills.
    pub fn drop(self: *Bits, count: u8) void {
        self.value >>= @as(u6, @intCast(count));
        self.count -= count;
    }

    /// Discards the partial current byte, leaving the next unread byte at the low end of value.
    pub fn alignByte(self: *Bits) void {
        self.drop(self.count & 7);
    }

    /// Counts bytes touched by consumed bits, excluding whole bytes of unread lookahead.
    pub fn consumed(self: Bits) usize {
        return self.position - self.count / 8;
    }
};

/// Bit input specialized for whole-buffer packed entries. The low byte of count holds available
/// bits; upper bits may contain wrapped entry flags. Subtracting an entire entry consumes its
/// low-byte width without masking. Refills and publication use only the actual bit count.
pub const CommonFastBits = struct {
    source: []const u8,
    value: u64,
    count: u32,
    position: usize,

    /// Refills from eight in-range source bytes. The caller proves that margin before entering.
    pub fn refill(self: *CommonFastBits) void {
        std.debug.assert(self.source.len - self.position >= 8);
        std.debug.assert(@as(u8, @truncate(self.count)) <= 63);
        const word = std.mem.readInt(u64, self.source[self.position..][0..8], .little);
        self.value |= word << @as(u6, @truncate(self.count));
        self.position += 7 - ((self.count >> 3) & 7);
        self.count |= 56;
    }

    /// Consumes entry's low-byte width by subtracting the complete packed entry.
    pub fn drop(self: *CommonFastBits, entry: u32) void {
        std.debug.assert(@as(u8, @truncate(self.count)) >= @as(u8, @truncate(entry)));
        self.value >>= @as(u6, @truncate(entry));
        self.count -%= entry;
    }

    /// Restores ordinary bit state for a reader borrowing the same source bytes.
    pub fn publish(self: *const CommonFastBits, bits: *Bits) void {
        bits.value = self.value;
        bits.position = self.position;
        bits.count = @truncate(self.count);
    }
};

test "wide bit refills preserve unaligned source bits and consumed boundaries" {
    var source: [24]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index * 37 + 11);
    for (0..8) |offset| {
        for (0..36) |remaining| {
            const count: u8 = @intCast(remaining);
            const initial_word = std.mem.readInt(u64, source[offset..][0..8], .little);
            var bits = Bits{
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
            var bits = Bits{
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

test "common packed wide counter agrees with checked bit state after full entry subtraction" {
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 256);
    defer allocator.free(source);
    for (source, 0..) |*byte, index| byte.* = @truncate(index * 37 + 11);
    var ordinary = Bits{ .source = source };
    var fast = CommonFastBits{ .source = source, .value = 0, .count = 0, .position = 0 };
    for (0..96) |index| {
        ordinary.refillWide();
        fast.refill();
        try std.testing.expectEqual(ordinary.value, fast.value);
        try std.testing.expectEqual(ordinary.position, fast.position);
        try std.testing.expectEqual(ordinary.count, @as(u8, @truncate(fast.count)));
        const width: u8 = @intCast(1 + index % 28);
        const flags: u32 = if (index % 2 == 0) 0x80000000 else 0xc000;
        const entry = flags | (@as(u32, @intCast(index)) << 16) | 0x300 | width;
        ordinary.drop(width);
        fast.drop(entry);
        try std.testing.expectEqual(ordinary.value, fast.value);
        try std.testing.expectEqual(ordinary.count, @as(u8, @truncate(fast.count)));
    }
    var published = Bits{ .source = source };
    fast.publish(&published);
    try std.testing.expectEqual(ordinary.value, published.value);
    try std.testing.expectEqual(ordinary.position, published.position);
    try std.testing.expectEqual(ordinary.count, published.count);
}
