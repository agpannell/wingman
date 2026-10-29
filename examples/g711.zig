//! Expand G.711 amplitudes and use the PCM writer to produce little-endian PCM16.
const std = @import("std");
const g711 = @import("wingman").g711;
const pcm = @import("wingman").pcm;

pub fn main(init: std.process.Init) !void {
    const codes = [_]u8{ 0, 128, 85, 213, 127, 255 };
    var samples: [codes.len]f32 = undefined;
    var pcm16: [codes.len * 2]u8 = undefined;
    var buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    for ([_]g711.Law{ .alaw, .mulaw }) |law| {
        const decoded = try g711.decodeInto(&codes, &samples, law);
        const bytes = try pcm.encodePcm16Into(decoded, &pcm16);
        try output.interface.print(
            "{s}: {d} bytes -> {d} samples\n",
            .{ @tagName(law), codes.len, decoded.len },
        );
        for (codes, decoded, 0..) |code, sample, i| {
            const exact = switch (law) {
                .alaw => g711.decodeAlaw(code),
                .mulaw => g711.decodeMulaw(code),
            };
            if (sample != @as(f32, @floatFromInt(exact)) / 32768) return error.SampleMismatch;
            const written = std.mem.readInt(i16, bytes[i * 2 ..][0..2], .little);
            if (written != exact) return error.PcmMismatch;
            try output.interface.print("  {x:0>2} -> {d:6} -> {d:.6}\n", .{ code, exact, sample });
        }
        try output.interface.writeAll("PCM16 little-endian:");
        for (bytes) |byte| try output.interface.print(" {x:0>2}", .{byte});
        try output.interface.writeByte('\n');
    }
    try output.interface.flush();
}
