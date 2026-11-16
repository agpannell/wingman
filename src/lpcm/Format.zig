//! Encoded representation of one uncompressed audio sample: its numerical container, meaningful bit
//! count and byte order. A sample is one channel value; rate and channel layout belong to the
//! caller. Construct a value directly, then use validBitCount or sampleCount to validate it. These
//! queries inspect representation and extent, without reading samples or retaining storage.

const std = @import("std");
const Format = @This();
const testing = std.testing;

/// Encoded numerical container. The int32 operations accept integer encodings only.
encoding: Encoding,
/// Meaningful high bits of an integer container; low bits are padding. Null uses the full width.
/// Integer precision is one through the container width; float formats require their full width.
valid_bits: ?u7 = null,
/// Byte order of the numerical container. Ignored for one-byte samples.
endian: std.lang.Endian = .little,

/// Encoded sample containers. Unsigned integers use a midpoint bias; signed integers use two's
/// complement. Meaningful integer bits occupy the high end of the container.
pub const Encoding = enum {
    unsigned8,
    signed16,
    signed24,
    signed32,
    float32,
    float64,
    signed8,
    unsigned16,
    unsigned24,
    unsigned32,

    /// Byte width of one encoded sample, independent of its meaningful precision.
    pub fn byteCount(self: Encoding) usize {
        return switch (self) {
            .unsigned8, .signed8 => 1,
            .unsigned16, .signed16 => 2,
            .unsigned24, .signed24 => 3,
            .unsigned32, .signed32, .float32 => 4,
            .float64 => 8,
        };
    }
};

/// The selected container cannot use the requested count of valid encoded bits.
pub const Error = error{InvalidFormat};

/// Counting also rejects byte extents that end inside an encoded sample.
pub const CountError = Error || error{InvalidData};

/// Returns the valid encoded bit count, using the full container width when valid_bits is null.
/// Zero, excessive counts and reduced floating-point widths return InvalidFormat.
pub fn validBitCount(self: Format) Error!u16 {
    const width: u16 = @intCast(self.encoding.byteCount() * 8);
    const bits: u16 = self.valid_bits orelse @intCast(width);
    if (bits == 0 or bits > width) return error.InvalidFormat;
    switch (self.encoding) {
        .float32, .float64 => if (bits != width) return error.InvalidFormat,
        else => {},
    }
    return bits;
}

test validBitCount {
    const full: Format = .{ .encoding = .signed24 };
    const padded: Format = .{ .encoding = .signed24, .valid_bits = 20 };
    const excessive: Format = .{ .encoding = .signed24, .valid_bits = 25 };
    try testing.expectEqual(24, try full.validBitCount());
    try testing.expectEqual(20, try padded.validBitCount());
    const binary64: Format = .{ .encoding = .float64 };
    try testing.expectEqual(64, try binary64.validBitCount());
    try testing.expectError(error.InvalidFormat, excessive.validBitCount());
}

/// Counts complete encoded samples after validating the representation. Invalid format takes
/// precedence over an incomplete byte extent. This does not inspect sample content or allocate.
pub fn sampleCount(self: Format, byte_count: usize) CountError!usize {
    _ = try self.validBitCount();
    const width = self.encoding.byteCount();
    if (byte_count % width != 0) return error.InvalidData;
    return byte_count / width;
}

test sampleCount {
    const pcm24: Format = .{ .encoding = .signed24 };
    const pcm8: Format = .{ .encoding = .unsigned8 };
    const zero_precision: Format = .{ .encoding = .unsigned8, .valid_bits = 0 };
    const reduced_binary32: Format = .{ .encoding = .float32, .valid_bits = 24 };
    const binary64: Format = .{ .encoding = .float64, .valid_bits = 64 };
    const reduced_binary64: Format = .{ .encoding = .float64, .valid_bits = 32 };
    try testing.expectEqual(2, try pcm24.sampleCount(6));
    try testing.expectEqual(0, try pcm8.sampleCount(0));
    try testing.expectError(error.InvalidData, pcm24.sampleCount(5));
    try testing.expectError(error.InvalidFormat, zero_precision.sampleCount(0));
    try testing.expectError(error.InvalidFormat, reduced_binary32.sampleCount(0));
    try testing.expectError(error.InvalidFormat, reduced_binary32.sampleCount(1));
    try testing.expectEqual(1, try binary64.sampleCount(8));
    try testing.expectError(error.InvalidFormat, reduced_binary64.sampleCount(0));

    // Counting only inspects geometry; even the largest complete container needs no allocation.
    const pcm32: Format = .{ .encoding = .signed32 };
    const largest_complete = std.math.maxInt(usize) - 3;
    try testing.expectEqual(largest_complete / 4, try pcm32.sampleCount(largest_complete));
}
