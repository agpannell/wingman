//! A Khronos data format descriptor describes how texture pixels, called texels, are represented. A
//! texel block is a repeating region encoded together: often one uncompressed texel or a small
//! compressed tile. Sample declarations describe channel bit ranges, positions and numeric
//! endpoints within that block; they do not contain the image's actual channel values. Storage
//! planes contribute separate byte spans to a block; sample bit offsets address their logical
//! concatenation, without requiring those spans to be adjacent in memory.
//!
//! Descriptors can accompany image data independently or be embedded in a texture container. Open
//! complete descriptor bytes with open, or write a basic descriptor from BasicInput. Integer wire
//! fields are little-endian; copied declarations expose those fields as native Zig integers.
//!
//! This view borrows immutable bytes and retains no allocator. Copies share that backing. Samples
//! are copied records; Block and its Iterator borrow bytes. Keep the admitted fields and backing
//! unchanged through all queries. BasicInput writes independent bytes into caller storage.
//!
//! The supported profile begins with a Khronos basic-format version 2 block, followed by optional
//! opaque blocks. Admission checks framing and field widths, without interpreting sample values,
//! validating color-model rules or matching a graphics API's format enumeration.
//!
//! Reference: https://registry.khronos.org/DataFormat/specs/1.4/dataformat.1.4.html
const std = @import("std");
const memory = @import("byte_ranges.zig");
const KhronosDataFormatDescriptor = @This();
const testing = std.testing;

/// Complete borrowed descriptor bytes, including the total-size field and all blocks.
data: []const u8,
/// Raw Khronos color-model identifier from the leading basic block.
color_model: u8,
/// Raw Khronos color-primaries identifier; zero declares unspecified primaries.
color_primaries: u8,
/// Raw Khronos transfer-function identifier; no transfer conversion is performed.
transfer_function: u8,
/// Encoded basic-block flags, including alpha association; no bits are interpreted here.
flags: u8,
/// Actual texel counts in four block dimensions, each in 1..256 rather than wire count-minus-one.
block_extent: [4]u16,
/// Declared bytes per block for each storage plane; zero can denote an unknown/variable size.
bytes_plane: [8]u8,
/// Number of sample records in the leading basic block, independent of following vendor blocks.
sample_count: usize,

/// Malformed framing, or a descriptor without the supported leading basic-format version 2 block.
pub const OpenError = error{ InvalidDescriptor, UnsupportedDescriptor };

/// One copied basic sample declaration, independent of descriptor lifetime. Numeric endpoints and
/// positions retain their encoded representation; this type performs no sample interpretation.
pub const Sample = struct {
    /// Bit offset in the logical concatenation of this texel block's storage planes.
    bit_offset: u16,
    /// Actual number of bits, in 1..256; the wire stores one less.
    bit_length: u16,
    /// Low four bits identify a model-specific channel; high bits are Khronos sample qualifiers.
    channel_type: u8,
    /// Four raw fractional sample-position bytes, interpreted using the block dimensions.
    position: [4]u8 = .{ 0, 0, 0, 0 },
    /// Raw 32-bit lower endpoint; integer signedness/float meaning follows channel qualifiers.
    lower: u32,
    /// Raw 32-bit upper endpoint; numeric interpretation follows the channel qualifiers.
    upper: u32,
};

/// One admitted block. Header values are copied; data borrows the descriptor's immutable backing.
pub const Block = struct {
    /// Seventeen-bit vendor identifier; zero denotes Khronos.
    vendor_id: u17,
    /// Fifteen-bit descriptor type, retained without interpreting vendor-specific semantics.
    descriptor_type: u15,
    /// Encoded block version.
    version: u16,
    /// Complete borrowed block bytes, including its eight-byte header.
    data: []const u8,

    /// Independent traversal of admitted blocks. Advancing does not invalidate earlier views.
    pub const Iterator = struct {
        /// Remaining admitted blocks; read-only except through next. Backing must remain immutable.
        remaining: []const u8,

        /// Returns the next block, or null at the exact descriptor boundary.
        pub fn next(self: *Iterator) ?Block {
            if (self.remaining.len == 0) return null;
            const word = read(u32, self.remaining, 0);
            const size = read(u16, self.remaining, 6);
            const data = self.remaining[0..size];
            self.remaining = self.remaining[size..];
            return .{
                .vendor_id = @truncate(word),
                .descriptor_type = @intCast(word >> 17),
                .version = read(u16, data, 4),
                .data = data,
            };
        }
    };
};

/// Checks exact size, block headers and the leading basic descriptor's sample-record framing.
/// Additional blocks remain opaque. No allocation or color/layout interpretation occurs.
pub fn open(data: []const u8) OpenError!KhronosDataFormatDescriptor {
    if (data.len < 44 or data.len % 4 != 0 or read(u32, data, 0) != data.len) {
        return error.InvalidDescriptor;
    }
    var remaining = data[4..];
    while (remaining.len != 0) {
        if (remaining.len < 8) return error.InvalidDescriptor;
        const size = read(u16, remaining, 6);
        if (size < 8 or size % 4 != 0 or size > remaining.len) return error.InvalidDescriptor;
        remaining = remaining[size..];
    }
    if (read(u32, data, 4) != 0 or read(u16, data, 8) != 2) return error.UnsupportedDescriptor;
    const basic_size = read(u16, data, 10);
    if (basic_size < 40 or (basic_size - 24) % 16 != 0) return error.InvalidDescriptor;
    var extent: [4]u16 = undefined;
    for (&extent, data[16..20]) |*value, byte| value.* = @as(u16, byte) + 1;
    return .{
        .data = data,
        .color_model = data[12],
        .color_primaries = data[13],
        .transfer_function = data[14],
        .flags = data[15],
        .block_extent = extent,
        .bytes_plane = data[20..28].*,
        .sample_count = (basic_size - 24) / 16,
    };
}

test open {
    var data: [52]u8 = @splat(0);
    @memcpy(data[0..44], r8_descriptor_bytes[0..]);
    put(u32, &data, 0, 52);
    put(u32, &data, 44, 41);
    put(u16, &data, 48, 7);
    put(u16, &data, 50, 8);
    const descriptor = try KhronosDataFormatDescriptor.open(&data);
    var block_iterator = descriptor.blocks();
    try testing.expectEqual(0, block_iterator.next().?.vendor_id);
    const extra = block_iterator.next().?;
    try testing.expectEqual(41, extra.vendor_id);
    try testing.expectEqual(7, extra.version);
    try testing.expectEqual(null, block_iterator.next());
    data[50] = 12;
    try testing.expectError(error.InvalidDescriptor, KhronosDataFormatDescriptor.open(&data));
}

/// Returns one copied basic-format sample, or null when the index is absent.
pub fn sample(self: KhronosDataFormatDescriptor, index: usize) ?Sample {
    if (index >= self.sample_count) return null;
    const record = self.data[28 + index * 16 ..][0..16];
    return .{
        .bit_offset = read(u16, record, 0),
        .bit_length = @as(u16, record[2]) + 1,
        .channel_type = record[3],
        .position = record[4..8].*,
        .lower = read(u32, record, 8),
        .upper = read(u32, record, 12),
    };
}

/// Starts an independent traversal including the basic block and any following vendor blocks.
pub fn blocks(self: KhronosDataFormatDescriptor) Block.Iterator {
    return .{ .remaining = self.data[4..] };
}

/// Caller description for writing one basic-format version 2 descriptor. Samples are borrowed only
/// through sizing/writing calls. Output contains one complete descriptor with no additional blocks;
/// callers can retain raw descriptor bytes when other blocks or semantics are needed.
pub const BasicInput = struct {
    /// Khronos color-model identifier to write unchanged.
    color_model: u8,
    /// Khronos color-primaries identifier; zero leaves primaries unspecified.
    color_primaries: u8 = 0,
    /// Khronos transfer-function identifier; zero leaves the transfer unspecified.
    transfer_function: u8 = 0,
    /// Basic-block flag bits, written without semantic validation.
    flags: u8 = 0,
    /// Actual texel counts in each dimension; every count must be in 1..256.
    block_extent: [4]u16 = .{ 1, 1, 1, 1 },
    /// Declared bytes per block for eight storage planes; color-model rules belong to the caller.
    bytes_plane: [8]u8,
    /// Borrowed declarations, with 1..4094 records and each bit_length in 1..256.
    samples: []const Sample,

    /// A sample count, bit length or block extent is outside the representable basic profile.
    pub const SizeError = error{InvalidDescriptor};
    /// Sizing failure, insufficient destination capacity or protected input/output overlap.
    pub const EncodeError = SizeError || error{ DestinationTooSmall, OverlappingStorage };

    /// Validates representable field widths and returns exact descriptor bytes without allocating.
    /// Color-model-specific sample/bit-layout rules remain with the codec or pixel format owner.
    pub fn encodedSize(self: *const BasicInput) SizeError!usize {
        if (self.samples.len == 0 or self.samples.len > (65535 - 24) / 16)
            return error.InvalidDescriptor;
        for (
            self.block_extent,
        ) |extent| if (extent == 0 or extent > 256) return error.InvalidDescriptor;
        for (
            self.samples,
        ) |item| if (item.bit_length == 0 or item.bit_length > 256) return error.InvalidDescriptor;
        return 28 + self.samples.len * 16;
    }

    /// Writes the used prefix after validating capacity and overlap. Spare output and all output on
    /// failure remain unchanged. Descriptor and sample-array storage may not overlap the prefix.
    pub fn encodeInto(self: *const BasicInput, output: []u8) EncodeError![]u8 {
        const size = try self.encodedSize();
        if (size > output.len) return error.DestinationTooSmall;
        const result = output[0..size];
        if (memory.overlaps(
            std.mem.asBytes(self),
            result,
        ) or memory.overlaps(
            std.mem.sliceAsBytes(self.samples),
            result,
        )) return error.OverlappingStorage;
        @memset(result, 0);
        put(u32, result, 0, @intCast(size));
        put(u16, result, 8, 2);
        put(u16, result, 10, @intCast(size - 4));
        result[12] = self.color_model;
        result[13] = self.color_primaries;
        result[14] = self.transfer_function;
        result[15] = self.flags;
        for (self.block_extent, result[16..20]) |extent, *byte| byte.* = @intCast(extent - 1);
        @memcpy(result[20..28], &self.bytes_plane);
        for (self.samples, 0..) |item, index| {
            const record = result[28 + index * 16 ..][0..16];
            put(u16, record, 0, item.bit_offset);
            record[2] = @intCast(item.bit_length - 1);
            record[3] = item.channel_type;
            @memcpy(record[4..8], &item.position);
            put(u32, record, 8, item.lower);
            put(u32, record, 12, item.upper);
        }
        return result;
    }

    test encodeInto {
        const samples = [_]Sample{
            .{ .bit_offset = 0, .bit_length = 8, .channel_type = 0, .lower = 0, .upper = 255 },
        };
        const descriptor: BasicInput = .{
            .color_model = 1,
            .color_primaries = 1,
            .transfer_function = 1,
            .bytes_plane = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
            .samples = &samples,
        };
        var output: [64]u8 = @splat(0xa5);
        const bytes = try descriptor.encodeInto(&output);
        try testing.expectEqualSlices(u8, r8_descriptor_bytes[0..], bytes);
        try testing.expectEqual(@as(u8, 0xa5), output[bytes.len]);
    }
};

fn read(comptime T: type, data: []const u8, offset: usize) T {
    return std.mem.readInt(T, data[offset..][0..@divExact(@bitSizeOf(T), 8)], .little);
}

fn put(comptime T: type, data: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, data[offset..][0..@divExact(@bitSizeOf(T), 8)], value, .little);
}

test {
    _ = BasicInput;
}

test "Khronos basic input protects its root and sample records" {
    const sample_input: Sample = .{
        .bit_offset = 0,
        .bit_length = 8,
        .channel_type = 0,
        .lower = 0,
        .upper = 255,
    };
    for ([_]bool{ false, true }) |alias_root| {
        var arena: [256]u8 align(16) = @splat(0xa5);
        var descriptor: BasicInput = .{
            .color_model = 1,
            .bytes_plane = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
            .samples = &.{sample_input},
        };
        var input = &descriptor;
        if (alias_root) {
            input = @ptrCast(&arena);
            input.* = descriptor;
        } else {
            const samples: *[1]Sample = @ptrCast(&arena);
            samples.* = .{sample_input};
            descriptor.samples = samples;
        }
        const before = arena;
        try testing.expectError(error.OverlappingStorage, input.encodeInto(&arena));
        try testing.expectEqualSlices(u8, &before, &arena);
    }
}

test "Khronos basic input refuses invalid declarations and short capacity without writing" {
    var samples = [_]Sample{
        .{ .bit_offset = 0, .bit_length = 8, .channel_type = 0, .lower = 0, .upper = 255 },
    };
    var descriptor: BasicInput = .{
        .color_model = 1,
        .bytes_plane = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
        .samples = &samples,
    };
    var output: [64]u8 = @splat(0xa5);
    const before = output;
    for ([_]u16{ 0, 257 }) |invalid| {
        descriptor.block_extent[0] = invalid;
        try testing.expectError(error.InvalidDescriptor, descriptor.encodeInto(&output));
        descriptor.block_extent[0] = 1;
        samples[0].bit_length = invalid;
        try testing.expectError(error.InvalidDescriptor, descriptor.encodeInto(&output));
        samples[0].bit_length = 8;
    }
    descriptor.samples = &.{};
    try testing.expectError(error.InvalidDescriptor, descriptor.encodeInto(output[0..1]));
    descriptor.samples = &samples;
    try testing.expectError(error.DestinationTooSmall, descriptor.encodeInto(output[0..43]));
    try testing.expectEqualSlices(u8, &before, &output);

    // Both endpoints of the stored length/extent ranges are representable, independent of a model's
    // sample semantics. Such meanings are deliberately outside this descriptor builder's contract.
    descriptor.block_extent[0] = 256;
    samples[0].bit_length = 256;
    const bytes = try descriptor.encodeInto(&output);
    const parsed = try KhronosDataFormatDescriptor.open(bytes);
    try testing.expectEqual(256, parsed.block_extent[0]);
    try testing.expectEqual(256, parsed.sample(0).?.bit_length);
    try testing.expectEqualSlices(u8, before[bytes.len..], output[bytes.len..]);
}

// Literal R8_UNORM descriptor: linear transfer, BT.709 primaries and one eight-bit red sample. This
// independent wire input also supplies the expected basic-writer bytes.
const r8_descriptor_bytes = [_]u8{
    0x2c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x28, 0x00, 0x01, 0x01, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00,
};
