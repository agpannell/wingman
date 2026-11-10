//! Copied PNG source geometry and sample layout, independent of encoded bytes and palettes.
//! Construct with fromIhdr or copy Source.header; keep admitted fields unchanged when planning and
//! decoding.

const std = @import("std");
const format = @import("format.zig");
const raster = @import("region_decode.zig");
const Limits = @import("Limits.zig");
const ImageRegion = @import("../common/ImageRegion.zig");
const metadata = @import("metadata.zig");

const Header = @This();
const Error = format.Error;

/// Nonzero stored width within PNG's 31-bit bound and the selected source limit.
width: u32,
/// Nonzero stored height within PNG's 31-bit bound and the selected source limit.
height: u32,
/// Admitted per-channel depth; indexed samples instead name palette entries.
bit_depth: u8,
/// Admitted PNG color type: 0, 2, 3, 4 or 6.
color_type: u8,
/// Stored samples per pixel: 1 for grayscale/indexed, 2 for gray-alpha, 3 for RGB, 4 for RGBA.
channel_count: usize,
/// Zero is sequential; one is Adam7 with separate pass-local filter histories.
interlace_method: u8,
/// Packed bits across all stored channels of one pixel.
bits_per_pixel: usize,
/// Packed bytes of a complete full-width row, excluding its filter byte.
packed_row_bytes: usize,
/// Exact complete inflated length, including every nonempty pass row's filter byte.
filtered_byte_count: usize,
/// Copied declarations observed by the container owner; IHDR alone leaves these empty.
metadata_presence: metadata.Metadata.Presence = .{},

/// Source-byte context and independent output/work admission for copied-geometry planning.
pub const RegionOptions = struct {
    /// Complete framing bytes, or zero for an owner charging suspended input separately.
    encoded_bytes: usize,
    /// Selected output and traversal-work budgets; source admission checks structural limits.
    limits: Limits = .{},
};

/// Reports selected output/backing and fixed/minimum work from admitted copied geometry. This reads
/// no encoded source, validates no pixels and allocates nothing. Structural record and metadata
/// limits require source admission; copied geometry does not retain those counts.
pub fn regionRequirements(
    self: Header,
    comptime Sample: type,
    rectangle: ImageRegion,
    options: RegionOptions,
) raster.Error!raster.Requirements {
    return raster.headerRequirements(
        Sample,
        self,
        rectangle,
        options.encoded_bytes,
        options.limits,
    );
}

/// Checks one IHDR payload without retaining bytes or implying chunk/CRC admission. Unsupported
/// layout/methods remain distinct from malformed/oversized dimensions.
pub fn fromIhdr(data: []const u8, maximum_source_extent: u32) Error!Header {
    if (data.len != 13) return error.InvalidPng;
    const width = readU32Big(data, 0);
    const height = readU32Big(data, 4);
    if (width == 0 or height == 0 or width > 0x7fff_ffff or height > 0x7fff_ffff or width >
        maximum_source_extent or height > maximum_source_extent)
    {
        return error.InvalidPng;
    }
    const depth = data[8];
    const color = data[9];
    const supported = switch (color) {
        0 => switch (depth) {
            1, 2, 4, 8, 16 => true,
            else => false,
        },
        2, 4, 6 => depth == 8 or depth == 16,
        3 => switch (depth) {
            1, 2, 4, 8 => true,
            else => false,
        },
        else => false,
    };
    if (!supported or data[10] != 0 or data[11] != 0 or data[12] > 1) return error.UnsupportedPng;
    const channels: usize = switch (color) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => unreachable,
    };
    const bits = channels * depth;
    const layout = try format.packedLayout(width, height, bits, data[12]);
    return .{
        .width = width,
        .height = height,
        .bit_depth = depth,
        .color_type = color,
        .channel_count = channels,
        .interlace_method = data[12],
        .bits_per_pixel = bits,
        .packed_row_bytes = layout.row_bytes,
        .filtered_byte_count = layout.filtered_bytes,
    };
}

fn readU32Big(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

test "PNG header admits packed rows whose bytes fit beyond intermediate bit arithmetic" {
    // Independent one-row IHDR records at the 31-bit PNG dimension boundary. Header admission
    // computes packed/filtered storage without decoding or allocating it.
    const cases = .{
        .{
            &[_]u8{ 0x3f, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00 },
            536870912,
            536870913,
        },
        .{
            &[_]u8{ 0x7f, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00 },
            536870912,
            536870913,
        },
        .{
            &[_]u8{ 0x7f, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00 },
            1073741824,
            1073741825,
        },
        .{
            &[_]u8{ 0x7f, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01, 0x08, 0x00, 0x00, 0x00, 0x00 },
            2147483647,
            2147483648,
        },
        .{
            &[_]u8{ 0x7f, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01, 0x10, 0x00, 0x00, 0x00, 0x00 },
            4294967294,
            4294967295,
        },
        .{
            &[_]u8{ 0x7f, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x00, 0x01 },
            1073741824,
            1073741828,
        },
        .{
            &[_]u8{ 0x7f, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01, 0x08, 0x00, 0x00, 0x00, 0x01 },
            2147483647,
            2147483651,
        },
    };
    inline for (cases) |case| {
        const header = try Header.fromIhdr(case[0], 0x7fff_ffff);
        try std.testing.expectEqual(case[1], header.packed_row_bytes);
        try std.testing.expectEqual(case[2], header.filtered_byte_count);
    }
    const wide_adam7 = &[_]u8{
        0x7f, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01,
        0x10, 0x00, 0x00, 0x00, 0x01,
    };
    if (@sizeOf(usize) == 4) {
        // Four nonempty passes need two bytes per sample and four filter bytes.
        try std.testing.expectError(error.InvalidPng, Header.fromIhdr(wide_adam7, 0x7fff_ffff));
    } else {
        const header = try Header.fromIhdr(wide_adam7, 0x7fff_ffff);
        try std.testing.expectEqual(4294967294, header.packed_row_bytes);
        try std.testing.expectEqual(4294967298, header.filtered_byte_count);
    }
}
