//! CRC-64/XZ, the checksum used by XZ containers. Input and output are reflected. Normal polynomial
//! 0x42f0e1eba9ea3693 omits its leading term. Initial remainder and final XOR are
//! 0xffffffffffffffff; the check of "123456789" is 0x995dc9bbdf1939fa. This is a checksum, not
//! authentication. The caller owns the state. Copies continue independently; reset by assigning a
//! new `init()`. Operations allocate nothing, read exact unaligned slices, and retain no input.
//! Numeric output has no serialized byte order; the enclosing format defines its own fields.
const Crc64Xz = @This();
const Core = @import("portable.zig").Algorithm(u64, 0x42f0e1eba9ea3693, true);
const std = @import("std");

/// Unfinalized remainder. Initialize through `init` or copy a valid state.
remainder: u64,

/// Starts an empty stream with numeric checksum zero.
pub fn init() Crc64Xz {
    return .{ .remainder = 0xffffffffffffffff };
}

/// Appends exact bytes without retaining input or requesting memory. Empty fragments are accepted.
pub fn update(self: *Crc64Xz, bytes: []const u8) void {
    if (@inComptime()) {
        var comptime_state: Core = .{ .remainder = self.remainder };
        comptime_state.updatePortableShort(bytes);
        self.remainder = comptime_state.remainder;
        return;
    }
    if (bytes.len < 16) {
        self.remainder = @call(.never_inline, updateShort, .{ self.remainder, bytes });
        return;
    }
    self.remainder = @call(.never_inline, updateLarge, .{ self.remainder, bytes });
}

fn updateShort(initial: u64, bytes: []const u8) u64 {
    var state: Core = .{ .remainder = initial };
    @call(.always_inline, Core.updatePortableShort, .{ &state, bytes });
    return state.remainder;
}

fn updateLarge(initial: u64, bytes: []const u8) u64 {
    var state: Core = .{ .remainder = initial };
    state.update(bytes);
    return state.remainder;
}

test update {
    var state = init();
    state.update("1234");
    const prefix = state.final();
    var copy = state;
    state.update("56789");
    copy.update("other");
    try std.testing.expectEqual(hash("1234"), prefix);
    try std.testing.expectEqual(@as(u64, 0x995dc9bbdf1939fa), state.final());
    try std.testing.expectEqual(hash("1234other"), copy.final());
}

/// Returns a numeric snapshot without changing this stream. Later updates extend the same input.
pub fn final(self: Crc64Xz) u64 {
    return self.remainder ^ 0xffffffffffffffff;
}

/// Checksums one complete exact byte slice without allocation or retained input.
pub fn hash(bytes: []const u8) u64 {
    var state = init();
    state.update(bytes);
    return state.final();
}

test hash {
    try std.testing.expectEqual(@as(u64, 0x995dc9bbdf1939fa), hash("123456789"));
}

test "compile-time CRC64/XZ crosses the folding threshold" {
    const input = "0123456789abcdef0123456789abcdef";
    const sixteen = comptime hash(input[0..16]);
    const complete = comptime hash(input);
    const streamed = comptime blk: {
        var state = init();
        state.update(input[0..8]);
        state.update(input[8..24]);
        state.update(input[24..]);
        break :blk state.final();
    };
    try std.testing.expectEqual(@as(u64, 0x33e722fc976b006c), sixteen);
    try std.testing.expectEqual(@as(u64, 0xcfc0f04acab7e09c), complete);
    try std.testing.expectEqual(complete, streamed);
}

/// Immutable word-sized polynomial advance factor. Copies may be shared concurrently.
pub const CombineOperator = struct {
    /// Construct using `forLength`; the value represents one exact second byte length.
    factor: u64,

    /// Precomputes a reusable operator for any u64 second byte length without reading input.
    pub fn forLength(second_length: u64) CombineOperator {
        return .{ .factor = Core.CombineOperator.forLength(second_length).factor };
    }

    /// Combines finalized checksums in first-then-second order. The second sequence must have the
    /// length selected by `forLength`. No input is retained or reread.
    pub fn apply(self: CombineOperator, first: u64, second: u64) u64 {
        const operator: Core.CombineOperator = .{ .factor = self.factor };
        return operator.apply(first, second);
    }
};

/// Combines finalized checksums using the exact u64 second byte length, without original data.
pub fn combine(first: u64, second: u64, second_length: u64) u64 {
    return CombineOperator.forLength(second_length).apply(first, second);
}

test combine {
    const first = hash("1234");
    const second = hash("56789");
    try std.testing.expectEqual(@as(u64, 0x995dc9bbdf1939fa), combine(first, second, 5));
}
