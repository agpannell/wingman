//! Exact integer PCM conversion using left-aligned signed i32 samples. Each sample represents
//! `sample / 2^31`; unsigned formats' midpoint bias is removed. The positive endpoint is less than
//! 1, which is not representable as an i32 sample. Decoding ignores low container padding. Encoding
//! requires every discarded low sample bit to be zero, including for negative values, and emits
//! zero padding. Float wire formats are invalid. Operations allocate nothing and retain no borrowed
//! storage.

const std = @import("std");
const pcm = @import("../pcm.zig");
const memory = @import("../common/byte_ranges.zig");
const testing = std.testing;
const Format = pcm.Format;

/// Invalid representation or extent, insufficient output, or overlapping used storage.
pub const DecodeError = error{ InvalidFormat, InvalidData, DestinationTooSmall, Aliasing };

/// Invalid representation, unrepresentable encoded extent, or nonzero discarded sample bits.
pub const ValidateError = error{ InvalidFormat, SizeOverflow, PrecisionLoss };

/// Encoding also rejects insufficient or aliased caller output.
pub const EncodeError = ValidateError || error{ DestinationTooSmall, Aliasing };

/// The integer wire representation used for exact encoding.
pub const EncodeOptions = struct { format: Format };

/// Decodes complete integer containers into a borrowed i32 prefix. Low padding bits are ignored.
/// Format, extent, capacity and used-prefix overlap failures occur before any output is written.
pub fn decodeInto(source: []const u8, destination: []i32, format: Format) DecodeError![]i32 {
    const bits = try integerPrecision(format);
    const width = format.encoding.byteCount();
    if (source.len % width != 0) return error.InvalidData;
    const count = source.len / width;
    if (destination.len < count) return error.DestinationTooSmall;

    const output = destination[0..count];
    if (memory.overlaps(source, std.mem.sliceAsBytes(output))) return error.Aliasing;

    const padding: u5 = @intCast(32 - bits);
    const mask = @as(u32, std.math.maxInt(u32)) << padding;
    if (format.encoding == .unsigned8) {
        decodeWords(source, output, mask, 1, .little, true);
    } else if (switch (format.encoding) {
        .unsigned16, .unsigned24, .unsigned32 => true,
        else => false,
    }) switch (format.endian) {
        .little => decodeInteger(source, output, width, mask, .little, true),
        .big => decodeInteger(source, output, width, mask, .big, true),
    } else switch (format.endian) {
        .little => decodeInteger(source, output, width, mask, .little, false),
        .big => decodeInteger(source, output, width, mask, .big, false),
    }
    return output;
}

test decodeInto {
    var samples: [3]i32 = undefined;
    const result = try decodeInto(&.{ 0, 128, 255 }, &samples, .{ .encoding = .unsigned8 });
    try testing.expectEqualSlices(i32, &.{ std.math.minInt(i32), 0, 0x7f00_0000 }, result);
}

fn decodeInteger(
    source: []const u8,
    output: []i32,
    width: usize,
    mask: u32,
    comptime endian: std.lang.Endian,
    comptime unsigned: bool,
) void {
    switch (width) {
        1 => decodeWords(source, output, mask, 1, endian, unsigned),
        2 => decodeWords(source, output, mask, 2, endian, unsigned),
        3 => decodeWords(source, output, mask, 3, endian, unsigned),
        4 => decodeWords(source, output, mask, 4, endian, unsigned),
        else => unreachable,
    }
}

fn decodeWords(
    source: []const u8,
    output: []i32,
    mask: u32,
    comptime width: usize,
    comptime endian: std.lang.Endian,
    comptime unsigned: bool,
) void {
    // Assemble wire bytes explicitly for unaligned input and either byte order. In the left-aligned
    // word, XOR with the sign bit removes unsigned bias; the mask drops padding.
    const lanes = std.simd.suggestVectorLength(i32) orelse 1;
    const Block = @Vector(lanes * width, u8);
    const Bytes = @Vector(lanes, u8);
    const Words = @Vector(lanes, u32);
    const Samples = @Vector(lanes, i32);
    var index: usize = 0;
    while (index + lanes <= output.len) : (index += lanes) {
        const bytes: Block = source[index * width ..][0 .. lanes * width].*;
        var words: Words = @splat(if (unsigned) 0x8000_0000 else 0);
        inline for (0..width) |byte| {
            const indices: [lanes]i32 = comptime indices: {
                var values: [lanes]i32 = undefined;
                for (&values, 0..) |*value, lane| value.* = @intCast(lane * width + byte);
                break :indices values;
            };
            const selected: Bytes = @shuffle(u8, bytes, undefined, indices);
            const wide: Words = @intCast(selected);
            const position = if (endian == .little) byte else width - 1 - byte;
            words ^= wide << @splat(32 - width * 8 + position * 8);
        }
        const samples: Samples = @bitCast(words & @as(Words, @splat(mask)));
        output[index..][0..lanes].* = samples;
    }
    while (index < output.len) : (index += 1) {
        var word: u32 = if (unsigned) 0x8000_0000 else 0;
        inline for (0..width) |byte| {
            const position = if (endian == .little) byte else width - 1 - byte;
            word ^= @as(u32, source[index * width + byte]) << (32 - width * 8 + position * 8);
        }
        output[index] = @bitCast(word & mask);
    }
}

/// Checks format, output extent and every sample before writing. A sample is refused if the
/// selected precision would discard any nonzero low bit. No input or allocator is retained.
pub fn validate(source: []const i32, options: EncodeOptions) ValidateError!void {
    const bits = try integerPrecision(options.format);
    const width = options.format.encoding.byteCount();
    if (source.len > std.math.maxInt(usize) / width) return error.SizeOverflow;
    const shift: u5 = @intCast(32 - bits);
    const discarded = ~(@as(u32, std.math.maxInt(u32)) << shift);
    for (source) |sample| {
        const word: u32 = @bitCast(sample);
        if (word & discarded != 0) return error.PrecisionLoss;
    }
}

test validate {
    const options: EncodeOptions = .{ .format = .{ .encoding = .signed24 } };
    try validate(&.{ std.math.minInt(i32), 0, 0x7fff_ff00 }, options);
    try testing.expectError(error.PrecisionLoss, validate(&.{1}, options));
}

test "unsigned precision refusal precedes output and writer mutation" {
    for ([_]pcm.Encoding{ .unsigned16, .unsigned24, .unsigned32 }) |encoding| {
        const options: EncodeOptions = .{ .format = .{ .encoding = encoding, .valid_bits = 7 } };
        var bytes: [4]u8 = @splat(0xa5);
        try testing.expectError(error.PrecisionLoss, encodeInto(&.{1}, &.{}, options));
        var writer: std.Io.Writer = .fixed(&bytes);
        try writer.writeByte(0x42);
        try testing.expectError(error.PrecisionLoss, writeAll(&.{1}, &writer, options));
        try testing.expectEqualSlices(u8, &.{0x42}, writer.buffered());
        try testing.expect(std.mem.allEqual(u8, bytes[1..], 0xa5));
    }
}

/// Encodes a borrowed byte prefix. Format, size, precision, capacity and used-prefix overlap are
/// checked in that order; any admission failure preserves the whole destination.
pub fn encodeInto(source: []const i32, destination: []u8, options: EncodeOptions) EncodeError![]u8 {
    try validate(source, options);
    const bytes = source.len * options.format.encoding.byteCount();
    if (destination.len < bytes) return error.DestinationTooSmall;
    const output = destination[0..bytes];
    if (memory.overlaps(std.mem.sliceAsBytes(source), output)) return error.Aliasing;
    encodeSamples(source, output, options.format);
    return output;
}

test encodeInto {
    var storage: [6]u8 = undefined;
    const bytes = try encodeInto(
        &.{ std.math.minInt(i32), 0x7fff_ff00 },
        &storage,
        .{ .format = .{ .encoding = .signed24, .endian = .big } },
    );
    try testing.expectEqualSlices(u8, &.{ 0x80, 0, 0, 0x7f, 0xff, 0xff }, bytes);
}

/// Writes exact integer PCM after validating the entire source. Writer failure may leave a byte
/// prefix. The caller owns flushing and must keep source disjoint from Writer storage.
pub fn writeAll(
    source: []const i32,
    writer: *std.Io.Writer,
    options: EncodeOptions,
) (ValidateError || std.Io.Writer.Error)!void {
    try validate(source, options);
    const width = options.format.encoding.byteCount();
    var index: usize = 0;
    while (index < source.len) {
        const available = writer.unusedCapacitySlice();
        const count = @min(available.len / width, source.len - index);
        if (count == 0) {
            var bytes: [4]u8 = undefined;
            encodeSamples(source[index..][0..1], bytes[0..width], options.format);
            try writer.writeAll(bytes[0..width]);
            index += 1;
            continue;
        }
        encodeSamples(source[index..][0..count], available[0 .. count * width], options.format);
        writer.advance(count * width);
        index += count;
    }
}

test writeAll {
    var storage: [3]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try writeAll(
        &.{std.math.minInt(i32)},
        &writer,
        .{ .format = .{ .encoding = .signed24, .endian = .big } },
    );
    try testing.expectEqualSlices(u8, &.{ 0x80, 0, 0 }, writer.buffered());
}

test "Writer exhaustion publishes only the encoded byte prefix" {
    const source = [_]i32{ std.math.minInt(i32), 0, 0x7fff_ff00 };
    const expected = [_]u8{ 0, 0, 0x80, 0, 0, 0, 0xff, 0xff, 0x7f };
    for (0..expected.len + 1) |capacity| {
        var storage: [expected.len + 1]u8 = @splat(0xa5);
        var writer: std.Io.Writer = .fixed(storage[0..capacity]);
        if (capacity == expected.len) {
            try writeAll(&source, &writer, .{ .format = .{ .encoding = .signed24 } });
        } else {
            try testing.expectError(
                error.WriteFailed,
                writeAll(&source, &writer, .{ .format = .{ .encoding = .signed24 } }),
            );
        }
        try testing.expectEqualSlices(u8, expected[0..capacity], writer.buffered());
        try testing.expect(std.mem.allEqual(u8, storage[capacity..], 0xa5));
    }
}

fn integerPrecision(format: Format) error{InvalidFormat}!u16 {
    if (format.encoding == .float32 or format.encoding == .float64) return error.InvalidFormat;
    const width: u16 = @intCast(format.encoding.byteCount() * 8);
    const bits: u16 = format.valid_bits orelse @intCast(width);
    if (bits == 0 or bits > width) return error.InvalidFormat;
    return bits;
}

fn encodeSamples(source: []const i32, output: []u8, format: Format) void {
    const width = format.encoding.byteCount();
    const alignment: u5 = @intCast(32 - width * 8);
    const bias: u32 = switch (format.encoding) {
        .unsigned8, .unsigned16, .unsigned24, .unsigned32 => 0x8000_0000,
        else => 0,
    };
    for (source, 0..) |sample, index| {
        var word: u32 = @as(u32, @bitCast(sample)) ^ bias;
        word >>= alignment;
        const bytes = output[index * width ..][0..width];
        switch (width) {
            1 => bytes[0] = @intCast(word),
            2 => std.mem.writeInt(u16, bytes[0..2], @intCast(word), format.endian),
            3 => if (format.endian == .little) {
                bytes[0..3].* = .{ @truncate(word), @truncate(word >> 8), @truncate(word >> 16) };
            } else {
                bytes[0..3].* = .{ @truncate(word >> 16), @truncate(word >> 8), @truncate(word) };
            },
            4 => std.mem.writeInt(u32, bytes[0..4], word, format.endian),
            else => unreachable,
        }
    }
}

test "dirty padding is ignored on decode and cleared on encode" {
    const format: Format = .{ .encoding = .signed24, .valid_bits = 20, .endian = .big };
    const source = [_]u8{ 0x80, 0, 0x0f, 0x7f, 0xff, 0xff };
    var samples: [2]i32 = undefined;
    _ = try decodeInto(&source, &samples, format);
    try testing.expectEqualSlices(i32, &.{ std.math.minInt(i32), 0x7fff_f000 }, &samples);
    var bytes: [6]u8 = undefined;
    _ = try encodeInto(&samples, &bytes, .{ .format = format });
    try testing.expectEqualSlices(u8, &.{ 0x80, 0, 0, 0x7f, 0xff, 0xf0 }, &bytes);
}

test "signed 8-bit decoding covers vector batches and tails" {
    const bytes = [_]u8{ 0x80, 0xff, 0, 0x7f };
    const expected = [_]i32{ std.math.minInt(i32), -0x0100_0000, 0, 0x7f00_0000 };
    var source: [37]u8 = undefined;
    var wanted: [37]i32 = undefined;
    for (&source, &wanted, 0..) |*byte, *sample, index| {
        byte.* = bytes[index % bytes.len];
        sample.* = expected[index % expected.len];
    }
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        const format: Format = .{ .encoding = .signed8, .endian = endian };
        var samples: [37]i32 = undefined;
        try testing.expectEqualSlices(i32, &wanted, try decodeInto(&source, &samples, format));
        var encoded: [37]u8 = undefined;
        try testing.expectEqualSlices(
            u8,
            &source,
            try encodeInto(&samples, &encoded, .{ .format = format }),
        );
    }
}

test "admission errors precede output and Writer mutation" {
    var destination: [8]u8 = @splat(0xa5);
    const bad: EncodeOptions = .{ .format = .{ .encoding = .signed24 } };
    try testing.expectError(error.PrecisionLoss, encodeInto(&.{1}, destination[0..1], bad));
    try testing.expect(std.mem.allEqual(u8, &destination, 0xa5));
    try testing.expectError(
        error.InvalidFormat,
        encodeInto(&.{}, &destination, .{ .format = .{ .encoding = .float32 } }),
    );
    try testing.expectError(error.InvalidFormat, decodeInto(&.{}, &.{}, .{ .encoding = .float64 }));
    try testing.expectError(
        error.InvalidFormat,
        encodeInto(&.{}, &destination, .{ .format = .{ .encoding = .float64 } }),
    );
    var writer: std.Io.Writer = .fixed(&destination);
    try writer.writeByte(0x3c);
    const before = destination;
    try testing.expectError(error.PrecisionLoss, writeAll(&.{1}, &writer, bad));
    try testing.expectEqual(@as(usize, 1), writer.buffered().len);
    try testing.expectEqualSlices(u8, &before, &destination);
}

test "overlap is checked against used output only" {
    var storage: [4]i32 = @splat(0);
    const all = std.mem.sliceAsBytes(&storage);
    // The input lies in unused destination capacity; only the first output slot is written.
    std.mem.writeInt(u32, all[8..12], 0x1234_0000, .little);
    const decoded = try decodeInto(all[8..12], storage[0..3], .{ .encoding = .signed32 });
    try testing.expectEqualSlices(i32, &.{0x1234_0000}, decoded);

    const before = storage;
    try testing.expectError(
        error.Aliasing,
        decodeInto(all[0..4], storage[0..1], .{ .encoding = .signed32 }),
    );
    try testing.expectEqualSlices(i32, &before, &storage);

    storage[2] = 0x1234_0000;
    const encoded = try encodeInto(storage[2..3], all, .{ .format = .{ .encoding = .signed16 } });
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, encoded);
    const current = storage;
    try testing.expectError(
        error.Aliasing,
        encodeInto(storage[2..3], all[8..], .{ .format = .{ .encoding = .signed16 } }),
    );
    try testing.expectEqualSlices(i32, &current, &storage);
}
