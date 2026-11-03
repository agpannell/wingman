//! Inspect authored ICC storage, including unsorted tags sharing one opaque body.
const std = @import("std");
const icc = @import("wingman").icc;

pub fn main(init: std.process.Init) !void {
    // Profile and tag views borrow the complete declared profile; keep these bytes unchanged.
    const bytes = sampleProfile();
    const maximum_tags = 3;
    const profile = try icc.Profile.open(&bytes, .{ .limits = .{ .tags = maximum_tags } });
    // These distinct record signatures identify channels, while their common body has type curv.
    const red = (try profile.find("rTRC".*)) orelse return error.MissingTag;
    const green = (try profile.find("gTRC".*)) orelse return error.MissingTag;
    const blue = (try profile.find("bTRC".*)) orelse return error.MissingTag;
    if (red.data.ptr != green.data.ptr or red.data.ptr != blue.data.ptr)
        return error.LostSharedStorage;
    // The fourteen-byte body excludes the two zero padding bytes included in the profile length.
    if (red.data.len != 14 or profile.source.len != 184) return error.WrongExtent;
    if (profile.tag(3) != null or try profile.find("wtpt".*) != null) return error.UnexpectedTag;

    var buffer: [1024]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "ICC v{d}: class {s}, input {s}, connection space {s}\n",
        .{
            profile.version[0],
            &profile.device_class,
            &profile.color_space,
            &profile.connection_space,
        },
    );
    for (0..profile.tag_count) |index| {
        const tag = profile.tag(index) orelse return error.MissingTag;
        // Opening checked that the body is inside source, so this offset is within the profile.
        const offset = @intFromPtr(tag.data.ptr) - @intFromPtr(profile.source.ptr);
        try output.interface.print(
            "  {s}: type bytes {s}, {d} body bytes at {d}\n",
            .{ &tag.signature, tag.data[0..4], tag.data.len, offset },
        );
    }
    try output.interface.writeAll(
        "three tags share one body; two alignment bytes stay outside it\n",
    );
    try output.interface.writeAll(
        "storage inspected; no complete-profile validation or color conversion\n",
    );
    try output.interface.flush();
}

// Independent authored storage control, not a complete color-management profile.
fn sampleProfile() [184]u8 {
    var bytes: [184]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], bytes.len, .big);
    bytes[8] = 4;
    @memcpy(bytes[12..24], "mntrRGB XYZ ");
    @memcpy(bytes[36..40], "acsp");
    std.mem.writeInt(u32, bytes[128..132], 3, .big);
    for ([_][4]u8{ "bTRC".*, "rTRC".*, "gTRC".* }, 0..) |signature, index| {
        const record = bytes[132 + index * 12 ..][0..12];
        @memcpy(record[0..4], &signature);
        std.mem.writeInt(u32, record[4..8], 168, .big);
        std.mem.writeInt(u32, record[8..12], 14, .big);
    }
    @memcpy(bytes[168..172], "curv");
    std.mem.writeInt(u32, bytes[176..180], 1, .big);
    bytes[180..182].* = .{ 1, 0 };
    return bytes;
}
