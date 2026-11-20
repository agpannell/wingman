//! A complete admitted KTX2 file. Open immutable bytes to inspect copied declarations and borrowed
//! levels, metadata, descriptors and BasisLZ data without allocating or decompressing anything.
//! Admission checks framing and declared layout; codec bitstreams and full descriptor-to-Vulkan
//! agreement remain separate. Copies share file backing and need no cleanup. Keep admitted fields
//! and the backing unchanged until all derived views are retired.
const std = @import("std");
const ktx2 = @import("../ktx2.zig");
const layout = @import("layout.zig");
const fixtures = @import("fixtures.zig");
const KhronosDataFormatDescriptor = @import("../common/KhronosDataFormatDescriptor.zig");
const Container = @This();
const testing = std.testing;

/// Complete borrowed file, including framing, padding and every stored level.
data: []const u8,
/// Copied format and topology declarations; mip zero is the largest.
header: ktx2.Header,
/// Admitted independent descriptor borrowing its complete bytes from data.
descriptor: KhronosDataFormatDescriptor,
/// Admitted key/value section; entries and iterators borrow the same immutable file.
metadata: ktx2.Metadata,
/// Raw global supercompression section, empty without BasisLZ; table payloads remain compressed.
supercompression_data: []const u8,

/// Checks exact section/level order, bounds, zero padding, topology, descriptor framing and sorted
/// unique UTF-8 metadata keys. Checks global image directories, slice ranges and animation flags;
/// compressed contents remain opaque. Expanded lengths are checked against the descriptor when its
/// block size is available. No allocation or decompression occurs.
pub fn open(data: []const u8, options: ktx2.Options) ktx2.Error!Container {
    if (data.len > options.limits.maximum_encoded_bytes) return error.LimitExceeded;
    if (data.len < 80 or !std.mem.eql(
        u8,
        data[0..12],
        &layout.identifier,
    )) return error.InvalidKtx2;
    const scheme = std.enums.fromInt(
        ktx2.Supercompression,
        read(u32, data, 44),
    ) orelse return error.UnsupportedFormat;
    const header: ktx2.Header = .{
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
    const descriptor = try layout.openDescriptor(descriptor_data);
    try layout.validateHeader(header, descriptor, options);
    var position = index_end + descriptor_data.len;

    const metadata_offset = read(u32, data, 56);
    const metadata_size = read(u32, data, 60);
    if (metadata_size > options.limits.maximum_metadata_bytes) return error.LimitExceeded;
    var metadata_data: []const u8 = &.{};
    if (metadata_size == 0) {
        if (metadata_offset != 0) return error.InvalidKtx2;
    } else {
        if (metadata_offset != position) return error.InvalidKtx2;
        metadata_data = try span(data, position, metadata_size);
        position += metadata_size;
    }
    const metadata = try ktx2.Metadata.open(metadata_data, options);

    const global_offset = read(u64, data, 64);
    const global_size = read(u64, data, 72);
    var supercompression_data: []const u8 = &.{};
    const needs_global = scheme == .basis_lz;
    if (needs_global != (global_size != 0)) return error.InvalidKtx2;
    if (global_size == 0) {
        if (global_offset != 0) return error.InvalidKtx2;
    } else {
        const aligned = try layout.alignForward(position, 8);
        try layout.zeroPadding(data, position, aligned);
        if (global_offset != aligned) return error.InvalidKtx2;
        supercompression_data = try span(data, global_offset, global_size);
        position = aligned + supercompression_data.len;
    }

    const directory = try layout.BasisLzDirectory.open(
        header,
        descriptor,
        supercompression_data,
        metadata.has_animation_header,
        options.limits.maximum_image_slices,
    );
    const alignment = layout.levelAlignment(header, descriptor);
    var expanded_total: u64 = 0;
    var mip = levels;
    // Index records address logical mips largest first; physical payloads must be contiguous in the
    // opposite order, apart from each level's required alignment padding.
    while (mip != 0) {
        mip -= 1;
        const record = data[80 + @as(usize, mip) * 24 ..][0..24];
        const offset = read(u64, record, 0);
        const size = read(u64, record, 8);
        const expanded = read(u64, record, 16);
        const aligned = try layout.alignForward(position, alignment);
        try layout.zeroPadding(data, position, aligned);
        if (offset != aligned) return error.InvalidKtx2;
        const payload = try span(data, offset, size);
        try layout.validateLevel(header, descriptor, mip, payload.len, expanded);
        try directory.validateLevel(mip, payload);
        expanded_total = std.math.add(
            u64,
            expanded_total,
            expanded,
        ) catch return error.SizeOverflow;
        if (expanded_total > options.limits.maximum_uncompressed_bytes) return error.LimitExceeded;
        position = aligned + payload.len;
    }
    if (position != data.len) return error.InvalidKtx2;
    return .{
        .data = data,
        .header = header,
        .descriptor = descriptor,
        .metadata = metadata,
        .supercompression_data = supercompression_data,
    };
}

test open {
    const texture = try Container.open(&fixtures.r8_mips, .{});
    try testing.expectEqual(2, texture.header.width);
    try testing.expectEqual(2, texture.header.levelCount());
    try testing.expectEqualSlices(u8, &.{ 23, 42 }, texture.level(0).?.data);
    try testing.expectEqualSlices(u8, &.{17}, texture.level(1).?.data);
    try testing.expectEqual(null, texture.level(2));
    try testing.expectEqual(1, texture.descriptor.bytes_plane[0]);
    try testing.expectEqual(8, texture.descriptor.sample(0).?.bit_length);
    var metadata = texture.metadata.iterator();
    try testing.expectEqual(null, metadata.next());
}

/// Borrows one complete encoded mip, or null when absent. Index zero is the largest mip, although
/// the file stores levels in reverse order for progressive loading.
///
/// Standard Zstandard/zlib levels contain the complete layer/face/depth layout after decompression.
/// Decode into private storage using this level's `uncompressed_size`, exact output and
/// complete-input policies, then select an image or pass its blocks to a codec. Compression
/// checksums must succeed before using the restored bytes; errors can change private decompression
/// storage. The declaration-linked example inspects encoded bytes.
pub fn level(self: Container, index: u32) ?ktx2.Level {
    if (index >= self.header.levelCount()) return null;
    const record = self.data[80 + @as(usize, index) * 24 ..][0..24];
    const offset: usize = @intCast(read(u64, record, 0));
    const size: usize = @intCast(read(u64, record, 8));
    return .{ .data = self.data[offset..][0..size], .uncompressed_size = read(u64, record, 16) };
}

test level {
    const texture = try Container.open(&fixtures.astc_levels_zstandard, .{});
    const mip = texture.level(0).?;
    try testing.expectEqual(32, mip.uncompressed_size);
    try testing.expect(mip.data.len > 0);
    try testing.expectEqual(.zstandard, texture.header.supercompression);
    try testing.expectEqual(null, texture.level(2));
}

/// Returns an admitted ETC1S/BasisLZ view, or null for another stored representation. The view
/// borrows the file independently of this Container object; its queries do not run the codec.
pub fn basisLz(self: Container) ?ktx2.BasisLz {
    if (self.header.supercompression != .basis_lz or self.descriptor.color_model != 163)
        return null;
    return .{
        .header = self.header,
        .container_data = self.data,
        .data = self.supercompression_data,
    };
}

test basisLz {
    var container = try Container.open(&fixtures.etc1s, .{});
    const basis = container.basisLz().?;
    const metadata = container.metadata;
    const encoded_image = container.level(0).?.data;
    const endpoint_bytes = basis.codebooks().endpoints;
    @memset(std.mem.asBytes(&container), 0);

    // Derived views retain file bytes, rather than borrowing fields in the Container object.
    try testing.expectEqualSlices(u8, encoded_image, basis.image(0, 0, 0, 0).?.color);
    try testing.expectEqualSlices(u8, endpoint_bytes, basis.codebooks().endpoints);
    try testing.expectEqual(1, metadata.entry_count);
    var entries = metadata.iterator();
    try testing.expectEqualStrings("KTXwriter", entries.next().?.key);
    try testing.expectEqual(null, entries.next());
}

fn span(data: []const u8, offset: u64, size: u64) ktx2.Error![]const u8 {
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
    for (0..fixtures.r8_mips.len) |size|
        try testing.expectError(error.InvalidKtx2, Container.open(fixtures.r8_mips[0..size], .{}));
    const trailing = fixtures.r8_mips ++ [_]u8{0};
    try testing.expectError(error.InvalidKtx2, Container.open(&trailing, .{}));
    for ([_]usize{
        0,
        20,
        36,
        40,
        48,
        52,
        56,
        60,
        64,
        72,
        80,
        88,
        96,
        104,
        112,
        120,
        128,
        172 + 1,
    }) |offset| {
        var changed = fixtures.r8_mips;
        changed[offset] ^= 1;
        try testing.expectError(error.InvalidKtx2, Container.open(&changed, .{}));
    }
}

test "KTX2 malformed field mutations are bounded, including oversized level offsets" {
    for (0..fixtures.r8_mips.len) |offset| {
        var changed = fixtures.r8_mips;
        changed[offset] ^= 0xff;
        _ = Container.open(&changed, .{}) catch continue;
    }
    const options = [_]ktx2.Options{
        .{ .limits = .{ .maximum_encoded_bytes = fixtures.r8_mips.len - 1 } },
        .{ .limits = .{ .maximum_extent = 1 } },
        .{ .limits = .{ .maximum_levels = 1 } },
        .{ .limits = .{ .maximum_descriptor_bytes = 43 } },
        .{ .limits = .{ .maximum_uncompressed_bytes = 2 } },
    };
    for (options) |option|
        try testing.expectError(error.LimitExceeded, Container.open(&fixtures.r8_mips, option));
}
