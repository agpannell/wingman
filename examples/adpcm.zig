//! Decode illustrative ADPCM blocks and check their PCM16 values and prefix validation.
const std = @import("std");
const adpcm = @import("wingman").adpcm;
const pcm = @import("wingman").pcm;

pub fn main(init: std.process.Init) !void {
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    const microsoft = [_]u8{ 0, 16, 0, 100, 0, 0x9c, 0xff, 0x12 };
    const ima = [_]u8{ 0, 0, 0, 0xff, 0x11, 0x11, 0x11, 0x11 };
    const cases = [_]struct {
        bytes: []const u8,
        format: adpcm.Format,
        expected: []const i16,
    }{ .{
        .bytes = &microsoft,
        .format = .{
            .encoding = .microsoft_wave,
            .channels = 1,
            .block_bytes = 8,
            .frames_per_block = 4,
            .coefficients = &coefficients,
        },
        .expected = &.{ -100, 100, 116, 148 },
    }, .{
        .bytes = &ima,
        .format = .{
            .encoding = .ima_wave,
            .channels = 1,
            .block_bytes = 8,
            .frames_per_block = 9,
        },
        .expected = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 },
    } };
    var buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    for (cases) |case| {
        const frames = try adpcm.frameCount(case.bytes.len, case.format);
        var storage: [9]f32 = undefined;
        const samples = try adpcm.decodeInto(case.bytes, &storage, case.format);
        var pcm16: [18]u8 = undefined;
        const encoded = try pcm.encodePcm16Into(samples, &pcm16);
        for (case.expected, samples, 0..) |value, sample, i| {
            if (sample != @as(f32, @floatFromInt(value)) / 32768) return error.SampleMismatch;
            if (std.mem.readInt(
                i16,
                encoded[i * 2 ..][0..2],
                .little,
            ) != value) return error.PcmMismatch;
        }
        var prefix: [3]f32 = undefined;
        const selected = try adpcm.decodePrefixInto(case.bytes, &prefix, 3, case.format);
        if (!std.mem.eql(f32, samples[0..3], selected)) return error.PrefixMismatch;
        try output.interface.print(
            "{s}: {d} bytes -> {d} frames; prefix {d} frames validated\n",
            .{ @tagName(case.format.encoding), case.bytes.len, frames, selected.len },
        );
        try output.interface.writeAll("PCM16:");
        for (case.expected) |value| try output.interface.print(" {d}", .{value});
        try output.interface.writeAll("\nlittle-endian bytes:");
        for (encoded) |byte| try output.interface.print(" {x:0>2}", .{byte});
        try output.interface.writeByte('\n');
    }
    try output.interface.flush();
}
