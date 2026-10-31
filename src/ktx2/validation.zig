//! KTX2 topology, stored/expanded level extents, metadata and section alignment.

const std = @import("std");
const types = @import("format.zig");
const dfd = @import("dfd.zig");

pub const identifier = [_]u8{
    0xab, 0x4b, 0x54, 0x58, 0x20, 0x32, 0x30, 0xbb,
    0x0d, 0x0a, 0x1a, 0x0a,
};

pub fn header(
    value: types.Header,
    descriptor: dfd.DataFormatDescriptor,
    options: types.Options,
) types.Error!void {
    const limits = options.limits;
    if (value.width == 0 or (value.height == 0 and value.depth != 0)) return error.InvalidKtx2;
    const dimensions = [_]u32{ value.width, value.height, value.depth };
    for (dimensions) |extent| if (extent > limits.maximum_extent) return error.LimitExceeded;
    if (value.layers > limits.maximum_layers or value.levelCount() > limits.maximum_levels) {
        return error.LimitExceeded;
    }
    if (value.faces != 1 and value.faces != 6) return error.InvalidKtx2;
    if (value.faces == 6 and (value.height != value.width or value.depth != 0))
        return error.InvalidKtx2;
    const available = 32 - @clz(@max(value.width, value.height, value.depth));
    if (value.levelCount() > available) return error.InvalidKtx2;
    switch (value.type_size) {
        1, 2, 4, 8 => {},
        else => return error.InvalidKtx2,
    }
    if (value.vk_format == 0 and value.type_size != 1) return error.InvalidKtx2;
    const compressed = descriptor.color_model >= 128;
    if (compressed and (value.height == 0 or value.levels == 0 or value.type_size != 1))
        return error.InvalidKtx2;
    if (descriptor.block_extent[2] > 1 and value.depth == 0) return error.InvalidKtx2;
    if (descriptor.block_extent[3] != 1) return error.UnsupportedFormat;
    // ETC1S describes RGB and optional alpha as two separate planes, carried as paired slices.
    const paired_planes = value.supercompression == .basis_lz and descriptor.color_model == 163;
    const first_unused_plane: usize = if (paired_planes) 2 else 1;
    for (
        descriptor.bytes_plane[first_unused_plane..],
    ) |bytes| if (bytes != 0) return error.UnsupportedFormat;

    const scheme = value.supercompression;
    if (scheme == .basis_lz and (descriptor.color_model != 163 or value.vk_format != 0))
        return error.InvalidKtx2;
    if (scheme == .none and descriptor.bytes_plane[0] == 0) return error.UnsupportedFormat;
}

pub fn level(
    value: types.Header,
    descriptor: dfd.DataFormatDescriptor,
    index: u32,
    encoded: usize,
    expanded: u64,
) types.Error!void {
    if (encoded == 0) return error.InvalidKtx2;
    switch (value.supercompression) {
        .basis_lz => {
            if (expanded != 0) return error.InvalidKtx2;
            return;
        },
        .none => if (encoded != expanded) return error.InvalidKtx2,
        .zstandard, .zlib => if (expanded == 0) return error.InvalidKtx2,
    }
    const images = @as(u64, @max(1, value.layers)) * value.faces;
    if (expanded % images != 0) return error.InvalidKtx2;
    const block_bytes = descriptor.bytes_plane[0];
    if (block_bytes == 0) return; // Variable-size/unknown decoded layout remains opaque.
    const shift: u5 = @intCast(index);
    const dimensions = [_]u32{ value.width, value.height, value.depth };
    var expected = images;
    for (dimensions, descriptor.block_extent[0..3], 0..) |dimension, extent, axis| {
        const pixels = @max(1, dimension >> shift);
        const logical_blocks = (@as(u64, pixels) - 1) / extent + 1;
        // PVRTC1 reconstruction needs a 2x2 neighborhood even for tiny mip levels.
        const stored_blocks = if (descriptor.color_model == 164 and axis < 2) @max(
            2,
            logical_blocks,
        ) else logical_blocks;
        expected = std.math.mul(u64, expected, stored_blocks) catch return error.SizeOverflow;
    }
    expected = std.math.mul(u64, expected, block_bytes) catch return error.SizeOverflow;
    if (expanded != expected) return error.InvalidKtx2;
}

pub fn levelAlignment(value: types.Header, descriptor: dfd.DataFormatDescriptor) usize {
    if (value.supercompression != .none) return 1;
    const bytes: usize = descriptor.bytes_plane[0];
    // lcm(bytes, 4), including non-power-of-two RGB block sizes such as three bytes.
    if (bytes % 4 == 0) return bytes;
    return bytes * (if (bytes % 2 == 0) @as(usize, 2) else 4);
}

pub fn alignForward(position: usize, alignment: usize) types.Error!usize {
    const padding = (alignment - position % alignment) % alignment;
    return std.math.add(usize, position, padding) catch error.SizeOverflow;
}

pub fn key(entry: types.KeyValue, previous: ?[]const u8) types.Error!void {
    if (entry.key.len == 0 or std.mem.indexOfScalar(
        u8,
        entry.key,
        0,
    ) != null or !std.unicode.utf8ValidateSlice(
        entry.key,
    ) or std.mem.startsWith(u8, entry.key, "\xef\xbb\xbf")) {
        return error.InvalidKtx2;
    }
    if (previous) |before| if (std.mem.order(
        u8,
        before,
        entry.key,
    ) != .lt) return error.InvalidKtx2;
}

// PVRTC1 requires at least two blocks along each image axis, unlike PVRTC2.
test "PVRTC1 minimum block grid and PVRTC2 ordinary grid" {
    var descriptor: dfd.DataFormatDescriptor = .{
        .data = &.{},
        .color_model = 164,
        .color_primaries = 0,
        .transfer_function = 0,
        .flags = 0,
        .block_extent = .{ 4, 4, 1, 1 },
        .bytes_plane = .{ 8, 0, 0, 0, 0, 0, 0, 0 },
        .sample_count = 0,
    };
    var texture_header: types.Header = .{ .vk_format = 0, .width = 1, .height = 1 };
    try level(texture_header, descriptor, 0, 32, 32);
    try std.testing.expectError(error.InvalidKtx2, level(texture_header, descriptor, 0, 8, 8));
    texture_header.width = 9;
    texture_header.height = 5;
    try level(texture_header, descriptor, 0, 48, 48);
    texture_header.width = 1;
    texture_header.height = 1;
    texture_header.supercompression = .zstandard;
    try level(texture_header, descriptor, 0, 4, 32);
    try std.testing.expectError(error.InvalidKtx2, level(texture_header, descriptor, 0, 4, 8));
    descriptor.color_model = 165;
    texture_header.supercompression = .none;
    try level(texture_header, descriptor, 0, 8, 8);
    try std.testing.expectError(error.InvalidKtx2, level(texture_header, descriptor, 0, 32, 32));
}
