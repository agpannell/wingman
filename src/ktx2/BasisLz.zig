//! Borrowed ETC1S/BasisLZ image slices and compressed codebooks from an admitted KTX2 container.
//! Construct with Container.basisLz. One RGB slice and optional alpha slice describe each image;
//! compressed codebooks are shared by the texture. Directory order is mip, layer, face and depth,
//! independent of the file's reversed mip storage. Queries allocate nothing and do not decode.
//!
//! ETC1S slices refer to shared color/intensity and selector codebooks. They need BasisLZ decoding
//! to recover texture blocks; these slice bytes cannot be passed directly to etc.decodeBlock.
//!
//! Fields and backing remain immutable through queries. Copies borrow the complete file rather than
//! the originating Container object. Framing, ranges and animation flags have been admitted;
//! compressed contents, codebook values and actual temporal dependencies still need a codec.
const std = @import("std");
const ktx2 = @import("../ktx2.zig");
const layout = @import("layout.zig");
const fixtures = @import("fixtures.zig");
const BasisLz = @This();
const testing = std.testing;

/// Copied admitted topology used to address mip, layer, face and depth coordinates.
header: ktx2.Header,
/// Complete immutable file backing the level index and encoded image bytes.
container_data: []const u8,
/// Admitted global section containing the image directory and compressed shared tables.
data: []const u8,

/// One image's paired encoded slices. Both borrow file bytes; copying this record retains no codec
/// state. The application must decode before using pixels or actual prior-frame references.
pub const Image = struct {
    /// Compressed RGB slice for the addressed image.
    color: []const u8,
    /// Compressed alpha slice, empty when the descriptor declares no alpha.
    alpha: []const u8 = &.{},
    /// Bit 1 marks a frame referring to the previous animation layer; other bits are reserved.
    flags: u32 = 0,
};

/// Compressed ETC1S codebooks and Huffman tables shared by the texture. Counts describe decoded
/// entries; byte spans remain compressed. All spans borrow the original file's immutable backing.
pub const Codebooks = struct {
    /// Number of decoded endpoint entries, rather than bytes in the compressed endpoint span.
    endpoint_count: u16,
    /// Number of decoded selector entries, rather than bytes in the compressed selector span.
    selector_count: u16,
    /// Compressed endpoint-codebook bytes.
    endpoints: []const u8,
    /// Compressed selector-codebook bytes.
    selectors: []const u8,
    /// Compressed Huffman-table bytes used by image slices.
    tables: []const u8,
};

/// Borrows one image's encoded slices, or null for an absent coordinate. Coordinates are mip, array
/// layer, cube face and depth plane; each absent axis has index zero. Mip zero is largest.
pub fn image(self: BasisLz, mip: u32, layer: u32, face: u32, depth: u32) ?Image {
    const header = self.header;
    if (mip >= header.levelCount()) return null;
    const depth_count = layout.levelDepth(header, mip);
    if (layer >= @max(
        1,
        header.layers,
    ) or face >= header.faces or depth >= depth_count) return null;
    const first_index = layout.firstBasisLzImageIndex(header, mip);
    const level_image_index = (@as(usize, layer) * header.faces + face) * depth_count + depth;
    const index = first_index + level_image_index;
    // A 20-byte global header precedes the 20-byte image records. Their slice offsets address
    // encoded bytes within the selected mip; the level index supplies its absolute file range.
    const record = self.data[20 + index * 20 ..][0..20];
    const level_record = self.container_data[80 + @as(usize, mip) * 24 ..][0..24];
    const level_offset: usize = @intCast(read(u64, level_record, 0));
    const level_size: usize = @intCast(read(u64, level_record, 8));
    const level = self.container_data[level_offset..][0..level_size];
    const color_offset = read(u32, record, 4);
    const color_size = read(u32, record, 8);
    const alpha_offset = read(u32, record, 12);
    const alpha_size = read(u32, record, 16);
    return .{
        .color = level[color_offset..][0..color_size],
        .alpha = level[alpha_offset..][0..alpha_size],
        .flags = read(u32, record, 0),
    };
}

test image {
    const texture = try ktx2.Container.open(&fixtures.etc1s, .{});
    const slices = texture.basisLz().?.image(0, 0, 0, 0).?;
    try testing.expectEqualSlices(u8, texture.level(0).?.data, slices.color);
    try testing.expectEqual(0, slices.alpha.len);
    try testing.expectEqual(0, slices.flags);
    try testing.expectEqual(null, texture.basisLz().?.image(1, 0, 0, 0));
}

/// Borrows the admitted compressed endpoint/selector codebooks and Huffman tables.
pub fn codebooks(self: BasisLz) Codebooks {
    // Shared tables follow the fixed header and every mip's layer/face/depth records.
    var count: usize = 0;
    for (0..self.header.levelCount()) |mip| {
        count += @intCast(layout.basisLzImageCount(self.header, @intCast(mip)) catch unreachable);
    }
    const position = 20 + count * 20;
    const endpoint_end = position + read(u32, self.data, 4);
    const selector_end = endpoint_end + read(u32, self.data, 8);
    const table_end = selector_end + read(u32, self.data, 12);
    return .{
        .endpoint_count = read(u16, self.data, 0),
        .selector_count = read(u16, self.data, 2),
        .endpoints = self.data[position..endpoint_end],
        .selectors = self.data[endpoint_end..selector_end],
        .tables = self.data[selector_end..table_end],
    };
}

test codebooks {
    const texture = try ktx2.Container.open(&fixtures.etc1s, .{});
    const tables = texture.basisLz().?.codebooks();
    try testing.expect(tables.endpoint_count > 0);
    try testing.expect(tables.selector_count > 0);
    try testing.expect(tables.endpoints.len > 0);
    try testing.expect(tables.selectors.len > 0);
    try testing.expect(tables.tables.len > 0);
    // These bytes are still compressed; inspecting their ranges does not prepare a codec.
    const ordinary = try ktx2.Container.open(&fixtures.r8_mips, .{});
    try testing.expectEqual(null, ordinary.basisLz());
}

fn read(comptime T: type, data: []const u8, offset: usize) T {
    return std.mem.readInt(T, data[offset..][0..@divExact(@bitSizeOf(T), 8)], .little);
}
