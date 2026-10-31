//! Borrowed Khronos data format descriptors carried by KTX2.
//!
//! The leading basic descriptor names the color model, transfer function, block geometry and sample
//! fields. Additional descriptor blocks can carry vendor information. This module checks their wire
//! framing and exposes the declarations without interpreting color or sample values. It does not
//! establish that a descriptor agrees with a Vulkan format or that samples are valid.

const std = @import("std");
const ktx2 = @import("../ktx2.zig");
const types = @import("format.zig");
const memory = @import("../common/byte_ranges.zig");
const fixture = @import("fixtures.zig");
const testing = std.testing;

/// A copied sample declaration. Bit length and positions describe encoded data, not host types.
pub const Sample = struct {
    bit_offset: u16,
    bit_length: u16,
    /// Low four bits select the model's channel; high bits are the KHR_DF sample qualifiers.
    channel_type: u8,
    position: [4]u8 = .{ 0, 0, 0, 0 },
    lower: u32,
    upper: u32,
};

/// One range-admitted descriptor block, including its eight-byte wire header.
pub const DescriptorBlock = struct {
    vendor_id: u17,
    descriptor_type: u15,
    version: u16,
    data: []const u8,
};

/// A traversal of already admitted descriptor blocks. Prior views remain valid after advancing.
pub const DescriptorIterator = struct {
    remaining: []const u8,

    /// Returns the next block, or null at the exact descriptor boundary.
    pub fn next(self: *DescriptorIterator) ?DescriptorBlock {
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

/// Complete range-admitted descriptor with a Khronos basic-format version 2 leading block. Keep the
/// returned fields and borrowed source unchanged through all sample/block queries.
pub const DataFormatDescriptor = struct {
    data: []const u8,
    color_model: u8,
    color_primaries: u8,
    transfer_function: u8,
    flags: u8,
    /// Actual texel counts, after adding one to each encoded dimension byte.
    block_extent: [4]u16,
    bytes_plane: [8]u8,
    sample_count: usize,

    /// Checks exact size, block headers and the leading basic descriptor's sample-record framing.
    /// Additional blocks remain opaque. No allocation or color/layout interpretation occurs.
    pub fn open(data: []const u8) types.Error!DataFormatDescriptor {
        if (data.len < 44 or data.len % 4 != 0 or read(u32, data, 0) != data.len) {
            return error.InvalidKtx2;
        }
        var remaining = data[4..];
        while (remaining.len != 0) {
            if (remaining.len < 8) return error.InvalidKtx2;
            const size = read(u16, remaining, 6);
            if (size < 8 or size % 4 != 0 or size > remaining.len) return error.InvalidKtx2;
            remaining = remaining[size..];
        }
        if (read(u32, data, 4) != 0 or read(u16, data, 8) != 2) return error.UnsupportedFormat;
        const basic_size = read(u16, data, 10);
        if (basic_size < 40 or (basic_size - 24) % 16 != 0) return error.InvalidKtx2;
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

    /// Returns one copied basic-format sample, or null when the index is absent.
    pub fn sample(self: DataFormatDescriptor, index: usize) ?Sample {
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
    pub fn blocks(self: DataFormatDescriptor) DescriptorIterator {
        return .{ .remaining = self.data[4..] };
    }
};

/// Description for writing a single basic-format version 2 descriptor. The container writer also
/// accepts a complete raw descriptor when vendor blocks or unsupported semantics must be preserved.
pub const BasicDescriptor = struct {
    color_model: u8,
    color_primaries: u8 = 0,
    transfer_function: u8 = 0,
    flags: u8 = 0,
    block_extent: [4]u16 = .{ 1, 1, 1, 1 },
    bytes_plane: [8]u8,
    samples: []const Sample,

    /// Validates representable field widths and returns exact descriptor bytes without allocating.
    /// Color-model-specific sample/bit-layout rules remain with the codec or pixel format owner.
    pub fn encodedSize(self: *const BasicDescriptor) types.Error!usize {
        if (self.samples.len == 0 or self.samples.len > (65535 - 24) / 16) return error.InvalidKtx2;
        for (self.block_extent) |extent| if (extent == 0 or extent > 256) return error.InvalidKtx2;
        for (
            self.samples,
        ) |item| if (item.bit_length == 0 or item.bit_length > 256) return error.InvalidKtx2;
        return 28 + self.samples.len * 16;
    }

    /// Writes the used prefix after validating capacity and overlap. Spare output and all output on
    /// failure remain unchanged. Descriptor and sample-array storage may not overlap the prefix.
    pub fn encodeInto(
        self: *const BasicDescriptor,
        output: []u8,
    ) (types.Error || error{ DestinationTooSmall, OverlappingStorage })![]u8 {
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
        const descriptor: BasicDescriptor = .{
            .color_model = 1,
            .color_primaries = 1,
            .transfer_function = 1,
            .bytes_plane = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
            .samples = &samples,
        };
        var output: [64]u8 = @splat(0xa5);
        const bytes = try descriptor.encodeInto(&output);
        try testing.expectEqualSlices(u8, fixture.r8_mips[128..172], bytes);
        try testing.expectEqual(@as(u8, 0xa5), output[bytes.len]);
    }
};

test "KTX2 descriptor blocks retain unknown vendor records and reject truncated framing" {
    var data: [52]u8 = @splat(0);
    @memcpy(data[0..44], fixture.r8_mips[128..172]);
    put(u32, &data, 0, 52);
    put(u32, &data, 44, 41);
    put(u16, &data, 48, 7);
    put(u16, &data, 50, 8);
    const descriptor = try DataFormatDescriptor.open(&data);
    var blocks = descriptor.blocks();
    try testing.expectEqual(0, blocks.next().?.vendor_id);
    const extra = blocks.next().?;
    try testing.expectEqual(41, extra.vendor_id);
    try testing.expectEqual(7, extra.version);
    try testing.expectEqual(null, blocks.next());
    data[50] = 12;
    try testing.expectError(error.InvalidKtx2, DataFormatDescriptor.open(&data));
}

fn read(comptime T: type, data: []const u8, offset: usize) T {
    return std.mem.readInt(T, data[offset..][0..@divExact(@bitSizeOf(T), 8)], .little);
}

fn put(comptime T: type, data: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, data[offset..][0..@divExact(@bitSizeOf(T), 8)], value, .little);
}

test {
    _ = BasicDescriptor;
}

test "KTX2 basic descriptor protects its root and sample records" {
    const sample: ktx2.Sample = .{
        .bit_offset = 0,
        .bit_length = 8,
        .channel_type = 0,
        .lower = 0,
        .upper = 255,
    };
    for ([_]bool{ false, true }) |alias_root| {
        var arena: [256]u8 align(16) = @splat(0xa5);
        var descriptor: ktx2.BasicDescriptor = .{ .color_model = 1, .bytes_plane = .{
            1, 0, 0, 0, 0, 0, 0, 0,
        }, .samples = &.{sample} };
        var input = &descriptor;
        if (alias_root) {
            input = @ptrCast(&arena);
            input.* = descriptor;
        } else {
            const samples: *[1]ktx2.Sample = @ptrCast(&arena);
            samples.* = .{sample};
            descriptor.samples = samples;
        }
        const before = arena;
        try testing.expectError(error.OverlappingStorage, input.encodeInto(&arena));
        try testing.expectEqualSlices(u8, &before, &arena);
    }
}

test "KTX2 basic descriptor refuses invalid declarations and short capacity without writing" {
    var samples = [_]ktx2.Sample{
        .{ .bit_offset = 0, .bit_length = 8, .channel_type = 0, .lower = 0, .upper = 255 },
    };
    var descriptor: ktx2.BasicDescriptor = .{ .color_model = 1, .bytes_plane = .{
        1, 0, 0, 0, 0, 0, 0, 0,
    }, .samples = &samples };
    var output: [64]u8 = @splat(0xa5);
    const before = output;
    for ([_]u16{ 0, 257 }) |invalid| {
        descriptor.block_extent[0] = invalid;
        try testing.expectError(error.InvalidKtx2, descriptor.encodeInto(&output));
        descriptor.block_extent[0] = 1;
        samples[0].bit_length = invalid;
        try testing.expectError(error.InvalidKtx2, descriptor.encodeInto(&output));
        samples[0].bit_length = 8;
    }
    descriptor.samples = &.{};
    try testing.expectError(error.InvalidKtx2, descriptor.encodeInto(output[0..1]));
    descriptor.samples = &samples;
    try testing.expectError(error.DestinationTooSmall, descriptor.encodeInto(output[0..43]));
    try testing.expectEqualSlices(u8, &before, &output);

    // Both endpoints of the stored length/extent ranges are representable, independent of a model's
    // sample semantics. Such meanings are deliberately outside this descriptor builder's contract.
    descriptor.block_extent[0] = 256;
    samples[0].bit_length = 256;
    const bytes = try descriptor.encodeInto(&output);
    const parsed = try ktx2.DataFormatDescriptor.open(bytes);
    try testing.expectEqual(256, parsed.block_extent[0]);
    try testing.expectEqual(256, parsed.sample(0).?.bit_length);
    try testing.expectEqualSlices(u8, before[bytes.len..], output[bytes.len..]);
}
