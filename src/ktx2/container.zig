//! Exact KTX2 framing with bounded borrowed levels, format descriptors and key/value metadata.

const std = @import("std");
const types = @import("format.zig");
const dfd = @import("dfd.zig");
const validate = @import("validation.zig");
const global = @import("global_data.zig");
const fixture = @import("fixtures.zig");
const testing = std.testing;

/// An independent traversal of admitted UTF-8 keys and opaque binary values.
pub const KeyValueIterator = struct {
    remaining: []const u8,

    /// Returns the next borrowed record, or null at the exact metadata boundary.
    pub fn next(self: *KeyValueIterator) ?types.KeyValue {
        if (self.remaining.len == 0) return null;
        const size = read(u32, self.remaining, 0);
        const data = self.remaining[4..][0..size];
        const terminator = std.mem.indexOfScalar(u8, data, 0).?;
        const padded = (4 - size % 4) % 4;
        self.remaining = self.remaining[4 + @as(usize, size) + padded ..];
        return .{ .key = data[0..terminator], .value = data[terminator + 1 ..] };
    }
};

/// Complete KTX2 file borrowing immutable source. Construct with `open`, preserve its admitted
/// fields and keep its backing alive through all views. Source admission checks framing and the
/// declared block layout; it does not validate compressed contents or the DFD-to-VkFormat mapping.
pub const Source = struct {
    data: []const u8,
    header: types.Header,
    descriptor: dfd.DataFormatDescriptor,
    metadata: []const u8,
    global_data: []const u8,
    metadata_count: usize,

    /// Checks exact section/level order, bounds, zero padding, topology, DFD framing and sorted
    /// unique UTF-8 metadata keys. Checks global image directories, slice ranges and animation
    /// flags; compressed contents remain opaque. Expanded lengths are checked against the declared
    /// DFD when its block size is available. No allocation or decompression occurs.
    pub fn open(data: []const u8, options: types.Options) types.Error!Source {
        if (data.len > options.limits.maximum_encoded_bytes) return error.LimitExceeded;
        if (data.len < 80 or !std.mem.eql(
            u8,
            data[0..12],
            &validate.identifier,
        )) return error.InvalidKtx2;
        const scheme = std.enums.fromInt(
            types.Supercompression,
            read(u32, data, 44),
        ) orelse return error.UnsupportedFormat;
        const header: types.Header = .{
            .vk_format = read(u32, data, 12),
            .type_size = read(u32, data, 16),
            .width = read(u32, data, 20),
            .height = read(u32, data, 24),
            .depth = read(u32, data, 28),
            .layers = read(u32, data, 32),
            .faces = read(u32, data, 36),
            .levels = read(u32, data, 40),
            .supercompression = scheme,
        };
        const levels = header.levelCount();
        if (levels > options.limits.maximum_levels or levels > 32) return error.LimitExceeded;
        const index_end: usize = 80 + @as(usize, levels) * 24;
        if (index_end > data.len or read(u32, data, 48) != index_end) return error.InvalidKtx2;
        const descriptor_size = read(u32, data, 52);
        if (descriptor_size > options.limits.maximum_descriptor_bytes) return error.LimitExceeded;
        const descriptor_data = try span(data, index_end, descriptor_size);
        const descriptor = try dfd.DataFormatDescriptor.open(descriptor_data);
        try validate.header(header, descriptor, options);
        var position = index_end + descriptor_data.len;

        const metadata_offset = read(u32, data, 56);
        const metadata_size = read(u32, data, 60);
        if (metadata_size > options.limits.maximum_metadata_bytes) return error.LimitExceeded;
        var metadata: []const u8 = &.{};
        if (metadata_size == 0) {
            if (metadata_offset != 0) return error.InvalidKtx2;
        } else {
            if (metadata_offset != position) return error.InvalidKtx2;
            metadata = try span(data, position, metadata_size);
            position += metadata_size;
        }
        const metadata_info = try validateMetadata(
            metadata,
            options.limits.maximum_metadata_entries,
        );

        const global_offset = read(u64, data, 64);
        const global_size = read(u64, data, 72);
        var global_data: []const u8 = &.{};
        const needs_global = scheme == .basis_lz;
        if (needs_global != (global_size != 0)) return error.InvalidKtx2;
        if (global_size == 0) {
            if (global_offset != 0) return error.InvalidKtx2;
        } else {
            const aligned = try validate.alignForward(position, 8);
            try zeroPadding(data, position, aligned);
            if (global_offset != aligned) return error.InvalidKtx2;
            global_data = try span(data, global_offset, global_size);
            position = aligned + global_data.len;
        }

        const directory = try global.Directory.open(
            header,
            descriptor,
            global_data,
            metadata_info.has_animation,
            options.limits.maximum_image_slices,
        );
        const alignment = validate.levelAlignment(header, descriptor);
        var expanded_total: u64 = 0;
        var mip = levels;
        while (mip != 0) {
            mip -= 1;
            const record = data[80 + @as(usize, mip) * 24 ..][0..24];
            const offset = read(u64, record, 0);
            const size = read(u64, record, 8);
            const expanded = read(u64, record, 16);
            const aligned = try validate.alignForward(position, alignment);
            try zeroPadding(data, position, aligned);
            if (offset != aligned) return error.InvalidKtx2;
            const payload = try span(data, offset, size);
            try validate.level(header, descriptor, mip, payload.len, expanded);
            try directory.validateLevel(mip, payload);
            expanded_total = std.math.add(
                u64,
                expanded_total,
                expanded,
            ) catch return error.SizeOverflow;
            if (expanded_total > options.limits.maximum_uncompressed_bytes)
                return error.LimitExceeded;
            position = aligned + payload.len;
        }
        if (position != data.len) return error.InvalidKtx2;
        return .{
            .data = data,
            .header = header,
            .descriptor = descriptor,
            .metadata = metadata,
            .global_data = global_data,
            .metadata_count = metadata_info.count,
        };
    }

    test open {
        const texture = try Source.open(&fixture.r8_mips, .{});
        try testing.expectEqual(2, texture.header.width);
        try testing.expectEqual(2, texture.header.levelCount());
        try testing.expectEqualSlices(u8, &.{ 23, 42 }, texture.level(0).?.data);
        try testing.expectEqualSlices(u8, &.{17}, texture.level(1).?.data);
        try testing.expectEqual(null, texture.level(2));
        try testing.expectEqual(1, texture.descriptor.bytes_plane[0]);
        try testing.expectEqual(8, texture.descriptor.sample(0).?.bit_length);
        var metadata = texture.keyValues();
        try testing.expectEqual(null, metadata.next());
    }

    /// Borrows one complete encoded mip, or null when absent. Index zero is the largest mip,
    /// although the file stores levels in reverse order for progressive loading.
    ///
    /// Standard Zstandard/zlib levels contain the complete layer/face/depth layout after
    /// decompression. Decode into private storage using this level's `uncompressed_size`, exact
    /// output and complete-input policies, then select an image or pass its blocks to a codec.
    /// Compression checksums must succeed before using the restored bytes; errors can change
    /// private decompression storage. The declaration-linked example inspects encoded bytes.
    pub fn level(self: Source, index: u32) ?types.Level {
        if (index >= self.header.levelCount()) return null;
        const record = self.data[80 + @as(usize, index) * 24 ..][0..24];
        const offset: usize = @intCast(read(u64, record, 0));
        const size: usize = @intCast(read(u64, record, 8));
        return .{
            .data = self.data[offset..][0..size],
            .uncompressed_size = read(u64, record, 16),
        };
    }

    test level {
        const texture = try Source.open(&fixture.astc_levels_zstandard, .{});
        const mip = texture.level(0).?;
        try testing.expectEqual(32, mip.uncompressed_size);
        try testing.expect(mip.data.len > 0);
        try testing.expectEqual(.zstandard, texture.header.supercompression);
        try testing.expectEqual(null, texture.level(2));
    }

    /// Borrows one image's encoded slice(s) from the BasisLZ image directory. Coordinates are mip,
    /// array layer, cube face and depth plane; each absent axis has index zero. Returns null for an
    /// absent coordinate or a layout without an image directory, including ordinary raw, Zstandard
    /// and zlib levels. Compressed slices need codec checks.
    pub fn imageSlice(
        self: Source,
        mip: u32,
        layer: u32,
        face: u32,
        depth: u32,
    ) ?global.ImageSlice {
        if (mip >= self.header.levelCount()) return null;
        const layer_count = @max(1, self.header.layers);
        const depth_count = global.levelDepth(self.header, mip);
        if (layer >= layer_count or face >= self.header.faces or depth >= depth_count) return null;
        return global.imageSlice(
            self.header,
            self.descriptor,
            self.global_data,
            self.level(mip).?.data,
            mip,
            layer,
            face,
            depth,
        );
    }

    test imageSlice {
        const texture = try Source.open(&fixture.etc1s, .{});
        const image = texture.imageSlice(0, 0, 0, 0).?;
        try testing.expectEqualSlices(u8, texture.level(0).?.data, image.data);
        try testing.expectEqual(0, image.alpha.len);
        try testing.expectEqual(0, image.flags);
        try testing.expectEqual(null, texture.imageSlice(1, 0, 0, 0));
    }

    /// Borrows compressed ETC1S codebooks and Huffman tables, or null for another representation.
    /// These ranges have been admitted; entropy decoding and codebook validation have not occurred.
    pub fn basisLz(self: Source) ?global.BasisLzGlobalData {
        if (self.header.supercompression != .basis_lz or self.descriptor.color_model != 163)
            return null;
        return global.codebooks(self.header, self.global_data);
    }

    test basisLz {
        const texture = try Source.open(&fixture.etc1s, .{});
        const tables = texture.basisLz().?;
        try testing.expect(tables.endpoint_count > 0);
        try testing.expect(tables.selector_count > 0);
        try testing.expect(tables.endpoints.len > 0);
        try testing.expect(tables.selectors.len > 0);
        try testing.expect(tables.tables.len > 0);
        // These bytes are still compressed; inspecting their ranges does not prepare a codec.
        const ordinary = try Source.open(&fixture.r8_mips, .{});
        try testing.expectEqual(null, ordinary.basisLz());
    }

    /// Starts a fresh metadata traversal, preserving opaque values and keys unknown to this reader.
    pub fn keyValues(self: Source) KeyValueIterator {
        return .{ .remaining = self.metadata };
    }
};

const MetadataInfo = struct { count: usize = 0, has_animation: bool = false };

fn validateMetadata(data: []const u8, maximum: usize) types.Error!MetadataInfo {
    var remaining = data;
    var previous: ?[]const u8 = null;
    var result: MetadataInfo = .{};
    while (remaining.len != 0) {
        if (result.count == maximum) return error.LimitExceeded;
        if (remaining.len < 4) return error.InvalidKtx2;
        const size: usize = read(u32, remaining, 0);
        remaining = remaining[4..];
        if (size < 2 or size > remaining.len) return error.InvalidKtx2;
        const entry = remaining[0..size];
        const terminator = std.mem.indexOfScalar(u8, entry, 0) orelse return error.InvalidKtx2;
        const key = entry[0..terminator];
        const value = entry[terminator + 1 ..];
        try validate.key(.{ .key = key, .value = value }, previous);
        if (std.mem.eql(u8, key, "KTXanimData") and value.len == 12) result.has_animation = true;
        previous = key;
        const padding = (4 - size % 4) % 4;
        if (padding > remaining.len - size) return error.InvalidKtx2;
        try zeroPadding(remaining, size, size + padding);
        remaining = remaining[size + padding ..];
        result.count += 1;
    }
    return result;
}

fn zeroPadding(data: []const u8, start: usize, end: usize) types.Error!void {
    if (end > data.len) return error.InvalidKtx2;
    for (data[start..end]) |byte| if (byte != 0) return error.InvalidKtx2;
}

fn span(data: []const u8, offset: u64, size: u64) types.Error![]const u8 {
    if (offset > data.len or size > data.len - @as(
        usize,
        @intCast(offset),
    )) return error.InvalidKtx2;
    const start: usize = @intCast(offset);
    return data[start..][0..@as(usize, @intCast(size))];
}

fn read(comptime T: type, data: []const u8, offset: usize) T {
    return std.mem.readInt(T, data[offset..][0..@divExact(@bitSizeOf(T), 8)], .little);
}

test "KTX2 complete framing rejects truncation, trailing bytes and displaced records" {
    for (0..fixture.r8_mips.len) |size| {
        try testing.expectError(error.InvalidKtx2, Source.open(fixture.r8_mips[0..size], .{}));
    }
    const trailing = fixture.r8_mips ++ [_]u8{0};
    try testing.expectError(error.InvalidKtx2, Source.open(&trailing, .{}));
    for (
        [_]usize{ 0, 20, 36, 40, 48, 52, 56, 60, 64, 72, 80, 88, 96, 104, 112, 120, 128, 172 + 1 },
    ) |offset| {
        var changed = fixture.r8_mips;
        changed[offset] ^= 1;
        try testing.expectError(error.InvalidKtx2, Source.open(&changed, .{}));
    }
}

test "KTX2 malformed field mutations are bounded, including oversized level offsets" {
    for (0..fixture.r8_mips.len) |offset| {
        var changed = fixture.r8_mips;
        changed[offset] ^= 0xff;
        _ = Source.open(&changed, .{}) catch continue;
    }
    const options = [_]types.Options{
        .{ .limits = .{ .maximum_encoded_bytes = fixture.r8_mips.len - 1 } },
        .{ .limits = .{ .maximum_extent = 1 } },
        .{ .limits = .{ .maximum_levels = 1 } },
        .{ .limits = .{ .maximum_descriptor_bytes = 43 } },
        .{ .limits = .{ .maximum_uncompressed_bytes = 2 } },
    };
    for (
        options,
    ) |option| try testing.expectError(error.LimitExceeded, Source.open(&fixture.r8_mips, option));
}
