//! Encode normalized channel samples as PCM16 and inspect the recovered values.
const std = @import("std");
const pcm = @import("wingman").pcm;

pub fn main(init: std.process.Init) !void {
    const input = [_]f32{ -1, -0.5, 0, 0.5, 1 };
    var bytes: [input.len * 2]u8 = undefined;
    const encoded = try pcm.encodePcm16Into(&input, &bytes);
    const expected = [_]u8{ 0, 128, 0, 192, 0, 0, 0, 64, 255, 127 };
    if (!std.mem.eql(u8, &expected, encoded)) return error.EncodedSampleMismatch;
    var decoded: [input.len]f32 = undefined;
    _ = try pcm.decodeInto(encoded, &decoded, .{ .encoding = .signed16 });

    var writer_bytes: [bytes.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_bytes);
    try pcm.writePcm16(&input, &writer);
    if (!std.mem.eql(u8, encoded, writer.buffered())) return error.WriterMismatch;

    var buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print("PCM16: {d} samples, {d} bytes\n", .{ input.len, encoded.len });
    for (input, decoded) |before, after| {
        try output.interface.print("{d:.6} -> {d:.6}\n", .{ before, after });
    }
    try output.interface.writeAll("little-endian bytes:");
    for (encoded) |byte| try output.interface.print(" {x:0>2}", .{byte});
    try output.interface.writeByte('\n');
    try output.interface.flush();
}
