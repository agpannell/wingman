//! Inspect authored TTC storage with two directory flavors sharing one opaque table.
const std = @import("std");
const sfnt = @import("wingman").sfnt;

pub fn main(init: std.process.Init) !void {
    const bytes = sampleCollection();
    const collection = try sfnt.Collection.open(&bytes);
    const first = try collection.face(0);
    const second = try collection.face(1);
    const first_table = (try first.find("DATA".*)) orelse return error.MissingTable;
    const second_table = (try second.find("DATA".*)) orelse return error.MissingTable;
    if (first_table.data.ptr != second_table.data.ptr) return error.LostSharedStorage;
    if (first_table.offset != 96 or first_table.data.len != 5) return error.WrongExtent;
    if (!first_table.checksumMatches() or !second_table.checksumMatches())
        return error.WrongChecksum;
    if (try first.find("name".*) != null or first.table(1) != null) return error.UnexpectedTable;
    const direct = try sfnt.Directory.openAt(&bytes, second.offset);
    if (direct.table(0).?.offset != 96) return error.RebasedTable;

    var buffer: [1024]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "TTC {s}: {d} faces\n",
        .{ @tagName(collection.version), collection.face_count },
    );
    for (0..collection.face_count) |index| {
        const directory = try collection.face(@intCast(index));
        const table = directory.table(0) orelse return error.MissingTable;
        try output.interface.print(
            "  face {d}: {s}, {s} at absolute byte {d}, {d} bytes, checksum {x:0>8}\n",
            .{
                index,
                @tagName(directory.flavor),
                &table.tag,
                table.offset,
                table.data.len,
                table.computedChecksum(),
            },
        );
    }
    try output.interface.writeAll("The shared payload is opaque storage, not a renderable font.\n");
    try output.interface.flush();
}

// Authored version-two framing. Two one-table directories point at the same five payload bytes.
fn sampleCollection() [104]u8 {
    var bytes: [104]u8 = @splat(0);
    @memcpy(bytes[0..4], "ttcf");
    std.mem.writeInt(u32, bytes[4..8], 0x00020000, .big);
    std.mem.writeInt(u32, bytes[8..12], 2, .big);
    std.mem.writeInt(u32, bytes[12..16], 32, .big);
    std.mem.writeInt(u32, bytes[16..20], 60, .big);
    for ([_]usize{ 32, 60 }, [_]u32{ 0x00010000, 0x4f54544f }) |directory_offset, signature| {
        std.mem.writeInt(u32, bytes[directory_offset..][0..4], signature, .big);
        std.mem.writeInt(u16, bytes[directory_offset + 4 ..][0..2], 1, .big);
        @memcpy(bytes[directory_offset + 12 ..][0..4], "DATA");
        std.mem.writeInt(u32, bytes[directory_offset + 16 ..][0..4], 0x06020304, .big);
        std.mem.writeInt(u32, bytes[directory_offset + 20 ..][0..4], 96, .big);
        std.mem.writeInt(u32, bytes[directory_offset + 24 ..][0..4], 5, .big);
    }
    @memcpy(bytes[96..101], &[_]u8{ 1, 2, 3, 4, 5 });
    return bytes;
}
