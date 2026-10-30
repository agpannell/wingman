//! Inspect a small authored Exif payload and sample its uncompressed thumbnail without allocation.
const std = @import("std");
const exif = @import("wingman").exif;

pub fn main(init: std.process.Init) !void {
    const bytes = sampleExif();
    const view = try exif.View.open(&bytes, .{});
    const orientation = (try view.orientation()) orelse return error.MissingOrientation;
    if (orientation != .right_top) return error.WrongOrientation;
    if (view.record_count != 12) return error.WrongRecordCount;
    const thumbnail = (try view.thumbnail()) orelse return error.MissingThumbnail;
    if (thumbnail.jpeg != null) return error.UnexpectedCompression;
    const raster = try exif.ThumbnailRaster.open(thumbnail.directory, .{});
    if (raster.width != 2 or raster.height != 1) return error.WrongExtent;
    if (!std.mem.eql(u8, &.{ 255, 0, 0 }, &raster.rgb(0, 0))) return error.WrongRedPixel;
    if (!std.mem.eql(u8, &.{ 0, 255, 0 }, &raster.rgb(1, 0))) return error.WrongGreenPixel;
    var strips = try thumbnail.directory.strips();
    const strip = (try strips.next()) orelse return error.MissingStrip;
    if (!std.mem.eql(u8, strip, bytes[146..])) return error.WrongStrip;
    if (try strips.next() != null) return error.ExtraStrip;

    var buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "Exif: {d} bytes, {d} structural records, stored orientation {s}\n",
        .{ bytes.len, view.record_count, @tagName(orientation) },
    );
    try output.interface.print("thumbnail: {d}x{d}, RGB8 strips, {d} encoded bytes\n", .{
        raster.width, raster.height, strip.len,
    });
    for (0..raster.width) |x| {
        const rgb = raster.rgb(x, 0);
        try output.interface.print("  pixel {d}: {d} {d} {d}\n", .{ x, rgb[0], rgb[1], rgb[2] });
    }
    try output.interface.writeAll("views borrow TIFF bytes; orientation has not been applied\n");
    try output.interface.flush();
}

// Authored classic TIFF: IFD0 records orientation 6 and points to a two-pixel RGB thumbnail. Its
// nine fields end at byte 140, followed by six BitsPerSample bytes and six sample bytes.
fn sampleExif() [152]u8 {
    var bytes: [152]u8 = @splat(0);
    bytes[0..8].* = .{ 0x49, 0x49, 42, 0, 8, 0, 0, 0 };
    std.mem.writeInt(u16, bytes[8..10], 1, .little);
    std.mem.writeInt(u16, bytes[10..12], 0x0112, .little);
    std.mem.writeInt(u16, bytes[12..14], 3, .little);
    std.mem.writeInt(u32, bytes[14..18], 1, .little);
    std.mem.writeInt(u16, bytes[18..20], 6, .little);
    std.mem.writeInt(u32, bytes[22..26], 26, .little);
    const fields = [_]struct {
        tag: u16,
        kind: u16 = 4,
        count: u32 = 1,
        value: u32,
    }{
        .{ .tag = 0x0100, .value = 2 },
        .{ .tag = 0x0101, .value = 1 },
        .{ .tag = 0x0102, .kind = 3, .count = 3, .value = 140 },
        .{ .tag = 0x0103, .value = 1 },
        .{ .tag = 0x0106, .value = 2 },
        .{ .tag = 0x0111, .value = 146 },
        .{ .tag = 0x0115, .value = 3 },
        .{ .tag = 0x0116, .value = 1 },
        .{ .tag = 0x0117, .value = 6 },
    };
    std.mem.writeInt(u16, bytes[26..28], fields.len, .little);
    for (fields, 0..) |field, index| {
        const entry = bytes[28 + index * 12 ..][0..12];
        std.mem.writeInt(u16, entry[0..2], field.tag, .little);
        std.mem.writeInt(u16, entry[2..4], field.kind, .little);
        std.mem.writeInt(u32, entry[4..8], field.count, .little);
        std.mem.writeInt(u32, entry[8..12], field.value, .little);
    }
    for (0..3) |index| std.mem.writeInt(u16, bytes[140 + index * 2 ..][0..2], 8, .little);
    bytes[146..152].* = .{ 255, 0, 0, 0, 255, 0 };
    return bytes;
}
