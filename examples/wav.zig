//! Write a complete WAVE file, inspect its chunks and decode with explicit storage and std.Io.
const std = @import("std");
const wav = @import("wingman").wav;

pub fn main(init: std.process.Init) !void {
    const input: wav.Audio.View = .{
        .sample_rate = 48000,
        .channels = .stereo,
        .samples = &.{ -1, 1, -0.5, 0.5, 0, 0.25 },
    };
    var file: [56]u8 = undefined;
    if (try wav.encodePcm16Requirements(input) != file.len) return error.SizeMismatch;
    const encoded = try wav.encodePcm16Into(input, &file);
    const container = try wav.Container.parse(encoded);
    if (container.scratchCount() != 0) return error.UnexpectedDirectory;
    const required = try wav.decodeRequirements(encoded, &.{});
    var samples: [8]f32 = @splat(42);
    const audio = try wav.decodeInto(encoded, &samples, &.{});
    const expected = [_]f32{ -1, 32767.0 / 32768.0, -0.5, 0.5, 0, 0.25 };
    if (!std.mem.eql(f32, &expected, audio.samples)) return error.SampleMismatch;
    if (!std.mem.eql(f32, &.{ 42, 42 }, samples[6..])) return error.SpareOutputChanged;

    var owned = try wav.decodeAlloc(init.gpa, encoded);
    defer owned.deinit(init.gpa);
    if (!std.mem.eql(f32, &expected, owned.view().samples)) return error.OwnedMismatch;

    var workers: [2]wav.DecodeWorker = undefined;
    var parallel_samples: [6]f32 = undefined;
    const parallel = try wav.decodeParallelInto(
        init.io,
        encoded,
        &parallel_samples,
        &.{},
        &workers,
        .{ .minimum_bytes = 0, .minimum_job_bytes = 1 },
    );
    if (!std.mem.eql(f32, &expected, parallel.samples)) return error.ParallelMismatch;
    // Every job has joined before return. Reuse the output and workers without a reset.
    @memset(&parallel_samples, 42);
    const repeated = try wav.decodeParallelInto(
        init.io,
        encoded,
        &parallel_samples,
        &.{},
        &workers,
        .{ .minimum_bytes = 0, .minimum_job_bytes = 1 },
    );
    if (!std.mem.eql(f32, &expected, repeated.samples)) return error.WorkerReuseMismatch;

    var buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "WAVE: {d} bytes, {d} Hz, {d} channels, {d} frames\n",
        .{ encoded.len, audio.sample_rate, @backingInt(audio.channels), required.frames },
    );
    var chunks = try container.iterator(&.{});
    while (try chunks.next()) |chunk| {
        try output.interface.print("  {s}: {d} payload bytes\n", .{ chunk.id, chunk.data.len });
    }
    try output.interface.writeAll("decoded samples:");
    for (audio.samples) |sample| try output.interface.print(" {d:.6}", .{sample});
    try output.interface.writeAll(
        "\nowned, caller-buffer and std.Io results agree; workers retired\n",
    );
    try output.interface.flush();
}
