//! Select an authored SFNT resource and inspect its table without copying the payload.
const std = @import("std");
const wingman = @import("wingman");

pub fn main(init: std.process.Init) !void {
    const source = sampleContainer();
    const container = try wingman.dfont.Container.open(&source);
    const font_bytes = try container.faceBytes(0);
    const directory = try wingman.sfnt.Directory.open(font_bytes);
    const table = (try directory.find("DATA".*)) orelse return error.MissingTable;
    if (container.faceCount() != 1 or table.offset != 28) return error.WrongExtent;
    if (!table.checksumMatches() or !std.mem.eql(u8, table.data, &.{ 1, 2, 3, 4 })) {
        return error.WrongTable;
    }
    if (@intFromPtr(table.data.ptr) != @intFromPtr(&source) + 48) return error.WrongBorrow;

    var buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "DFONT: {d} face; {s} table, {d} bytes, checksum {x:0>8}\n",
        .{ container.faceCount(), &table.tag, table.data.len, table.computedChecksum() },
    );
    try output.interface.writeAll("This authored storage is not a complete renderable font.\n");
    try output.interface.flush();
}

// The resource payload starts at byte 20; the SFNT table offset is relative to that payload.
fn sampleContainer() [102]u8 {
    var bytes: [102]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 16, .big);
    std.mem.writeInt(u32, bytes[4..8], 52, .big);
    std.mem.writeInt(u32, bytes[8..12], 36, .big);
    std.mem.writeInt(u32, bytes[12..16], 50, .big);
    std.mem.writeInt(u32, bytes[16..20], 32, .big);
    std.mem.writeInt(u32, bytes[20..24], 0x00010000, .big);
    std.mem.writeInt(u16, bytes[24..26], 1, .big);
    @memcpy(bytes[32..36], "DATA");
    std.mem.writeInt(u32, bytes[36..40], 0x01020304, .big);
    std.mem.writeInt(u32, bytes[40..44], 28, .big);
    std.mem.writeInt(u32, bytes[44..48], 4, .big);
    @memcpy(bytes[48..52], &[_]u8{ 1, 2, 3, 4 });
    std.mem.writeInt(u16, bytes[76..78], 28, .big);
    std.mem.writeInt(u16, bytes[78..80], 50, .big);
    @memcpy(bytes[82..86], "sfnt");
    std.mem.writeInt(u16, bytes[88..90], 10, .big);
    std.mem.writeInt(u16, bytes[92..94], 0xffff, .big);
    return bytes;
}
