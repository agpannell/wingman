//! Encode and verify a zlib stream with caller-owned workspaces.
const std = @import("std");
const zlib = @import("wingman").zlib;

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const source = if (arguments.len > 1)
        arguments[1]
    else
        "zlib verifies bytes. zlib verifies bytes. zlib verifies bytes.";
    const allocator = init.gpa;
    const encoder = try zlib.EncoderWorkspace.create(allocator);
    defer encoder.destroy(allocator);
    defer encoder.clear();
    const decoder = try zlib.DecoderWorkspace.create(allocator);
    defer decoder.destroy(allocator);
    const capacity = try zlib.encodeBound(source.len, .{});
    const compressed_storage = try allocator.alloc(u8, capacity);
    defer allocator.free(compressed_storage);
    const compressed = try zlib.encode(source, compressed_storage, encoder, .{});
    const restored = try allocator.alloc(u8, source.len);
    defer allocator.free(restored);
    const result = try zlib.decode(
        compressed,
        restored,
        .{ .workspace = decoder },
        .{ .output_size = .exact, .trailing_data = .reject },
    );
    if (result.consumed != compressed.len or result.produced != source.len or !std.mem.eql(
        u8,
        source,
        restored,
    )) return error.RoundTripMismatch;
    var buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "zlib: {d} source bytes, {d} encoded bytes; checksum and recovery verified\n",
        .{ source.len, compressed.len },
    );
    try output.interface.flush();
}
