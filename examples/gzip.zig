//! Write and verify a gzip member with explicit metadata.
const std = @import("std");
const gzip = @import("wingman").gzip;

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const source = if (arguments.len > 1)
        arguments[1]
    else
        "gzip verifies bytes. gzip verifies bytes. gzip verifies bytes.";
    const allocator = init.gpa;
    const encoder = try gzip.EncoderWorkspace.create(allocator);
    defer encoder.destroy(allocator);
    defer encoder.clear();
    const decoder = try gzip.DecoderWorkspace.create(allocator);
    defer decoder.destroy(allocator);
    const options: gzip.EncodeOptions = .{ .name = "sample.txt", .header_crc = true };
    const capacity = try gzip.encodeBound(source.len, options);
    const compressed_storage = try allocator.alloc(u8, capacity);
    defer allocator.free(compressed_storage);
    const compressed = try gzip.encode(source, compressed_storage, encoder, options);
    const parsed = try gzip.parseHeader(compressed, .{});
    const name = parsed.header.name orelse return error.MissingName;
    const restored = try allocator.alloc(u8, source.len);
    defer allocator.free(restored);
    const result = try gzip.decode(
        compressed,
        restored,
        .{ .workspace = decoder },
        .{ .output_size = .exact, .trailing_data = .reject },
    );
    if (result.consumed != compressed.len or result.produced != source.len or !std.mem.eql(
        u8,
        source,
        restored,
    ) or !std.mem.eql(u8, name, "sample.txt")) {
        return error.RoundTripMismatch;
    }
    var buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "gzip: {d} source bytes, {d} encoded bytes, name {s}; member verified\n",
        .{ source.len, compressed.len, name },
    );
    try output.interface.flush();
}
