//! CRC-32/ISCSI (Castagnoli), used by iSCSI. Input and output are reflected. Normal polynomial
//! 0x1edc6f41 omits its leading term. Initial remainder and final XOR are 0xffffffff; the check of
//! "123456789" is 0xe3069283. This is a checksum, not authentication. The caller owns the state.
//! Copies continue independently; reset by assigning a new `init()`. Operations allocate nothing,
//! read exact unaligned slices, and retain no input. Numeric output has no serialized byte order;
//! the enclosing format defines its own fields.
const Crc32Iscsi = @This();
const Core = @import("portable.zig").Algorithm(u32, 0x1edc6f41, true);
const std = @import("std");

/// Unfinalized remainder. Initialize through `init` or copy a valid state.
remainder: u32,

/// Starts an empty stream with numeric checksum zero.
pub fn init() Crc32Iscsi {
    return .{ .remainder = 0xffffffff };
}

/// Appends exact bytes without retaining input or requesting memory. Empty fragments are accepted.
pub fn update(self: *Crc32Iscsi, bytes: []const u8) void {
    var state: Core = .{ .remainder = self.remainder };
    state.update(bytes);
    self.remainder = state.remainder;
}

test update {
    var state = init();
    state.update("1234");
    const prefix = state.final();
    var copy = state;
    state.update("56789");
    copy.update("other");
    try std.testing.expectEqual(hash("1234"), prefix);
    try std.testing.expectEqual(@as(u32, 0xe3069283), state.final());
    try std.testing.expectEqual(hash("1234other"), copy.final());
}

/// Returns a numeric snapshot without changing this stream. Later updates extend the same input.
pub fn final(self: Crc32Iscsi) u32 {
    return self.remainder ^ 0xffffffff;
}

/// Checksums one complete exact byte slice without allocation or retained input.
pub fn hash(bytes: []const u8) u32 {
    var state = init();
    state.update(bytes);
    return state.final();
}

test hash {
    try std.testing.expectEqual(@as(u32, 0xe3069283), hash("123456789"));
}

/// Immutable word-sized polynomial advance factor. Copies may be shared concurrently.
pub const CombineOperator = struct {
    /// Construct using `forLength`; the value represents one exact second byte length.
    factor: u32,

    /// Precomputes a reusable operator for any u64 second byte length without reading input.
    pub fn forLength(second_length: u64) CombineOperator {
        return .{ .factor = Core.CombineOperator.forLength(second_length).factor };
    }

    /// Combines finalized checksums in first-then-second order. The second sequence must have the
    /// length selected by `forLength`. No input is retained or reread.
    pub fn apply(self: CombineOperator, first: u32, second: u32) u32 {
        const operator: Core.CombineOperator = .{ .factor = self.factor };
        return operator.apply(first, second);
    }
};

/// Combines finalized checksums using the exact u64 second byte length, without original data.
pub fn combine(first: u32, second: u32, second_length: u64) u32 {
    return CombineOperator.forLength(second_length).apply(first, second);
}

test combine {
    const first = hash("1234");
    const second = hash("56789");
    try std.testing.expectEqual(@as(u32, 0xe3069283), combine(first, second, 5));
}
