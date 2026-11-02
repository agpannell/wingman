//! Convert uncompressed audio sample values to and from byte representations.
//!
//! Run `zig build lpcm-example` from the repository root. LPCM converts individual samples; it does
//! not assign a sample rate, arrange channels or read a WAVE container. The integer and IEEE float
//! representations have explicit widths and byte order, and all storage belongs to the caller.
const std = @import("std");
const lpcm = @import("wingman").lpcm;

pub fn main(init: std.process.Init) !void {
    // Encode normalized samples as signed, little-endian PCM16. The format describes each stored
    // sample, rather than a whole audio frame; a caller arranges multiple channels if needed.
    const format: lpcm.Format = .{ .encoding = .signed16, .endian = .little };
    const input_samples = [_]f32{ -1, -0.5, 0, 0.5, 1 };
    const bytes_per_sample = format.encoding.byteCount();
    const required_bytes = input_samples.len * bytes_per_sample;

    var encoded_storage: [input_samples.len * @sizeOf(i16)]u8 = undefined;
    if (encoded_storage.len < required_bytes) return error.DestinationTooSmall;
    const encoded_bytes = try lpcm.encodeInto(&input_samples, &encoded_storage, format);

    // Integer encoding rounds halfway away from zero. Signed PCM16 represents -1 exactly, but its
    // largest positive value is 32767/32768, so +1 is clamped to 32767 rather than wrapping.
    const expected_bytes = [_]u8{ 0, 128, 0, 192, 0, 0, 0, 64, 255, 127 };
    if (!std.mem.eql(u8, &expected_bytes, encoded_bytes)) return error.EncodedSampleMismatch;

    // A complete sample occupies bytes_per_sample bytes. Counting validates the byte extent before
    // we size the f32 destination; the returned slice identifies the samples actually written.
    const sample_count = try lpcm.sampleCount(encoded_bytes.len, format);
    var decoded_storage: [input_samples.len]f32 = undefined;
    if (decoded_storage.len < sample_count) return error.DestinationTooSmall;
    const decoded_samples = try lpcm.decodeInto(encoded_bytes, &decoded_storage, format);

    // writeAll can send the same conversion to a caller-provided Writer. This fixed writer keeps
    // the bytes in memory. A backend writer can fail after publishing a prefix of its output.
    var writer_storage: [input_samples.len * @sizeOf(i16)]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_storage);
    try lpcm.writeAll(&input_samples, &writer, format);
    if (!std.mem.eql(u8, encoded_bytes, writer.buffered())) return error.WriterMismatch;

    // Exact integer conversion keeps all meaningful integer bits while changing byte order. Here
    // the two signed 24-bit endpoints are read big-endian and written little-endian. The int32
    // interface uses left-aligned signed values; a reduced-precision format may discard wire
    // padding.
    const source_24 = [_]u8{ 0x80, 0, 0, 0x7f, 0xff, 0xff };
    const source_format: lpcm.Format = .{ .encoding = .signed24, .endian = .big };
    const target_format: lpcm.Format = .{ .encoding = .signed24, .endian = .little };
    var exact_storage: [2]i32 = undefined;
    const exact_samples = try lpcm.int32.decodeInto(&source_24, &exact_storage, source_format);
    var little_24_storage: [source_24.len]u8 = undefined;
    const little_24 = try lpcm.int32.encodeInto(
        exact_samples,
        &little_24_storage,
        .{ .format = target_format },
    );
    const expected_24 = [_]u8{ 0, 0, 0x80, 0xff, 0xff, 0x7f };
    if (!std.mem.eql(u8, &expected_24, little_24)) return error.EncodedSampleMismatch;

    // The same library also supports finite IEEE float wire samples. Float values need not fit the
    // normalized integer range; using the f64 interface preserves binary64 values and signed zero.
    const float_format: lpcm.Format = .{ .encoding = .float64, .endian = .little };
    const float_samples = [_]f64{ -0.0, 1.5 };
    var float_storage: [float_samples.len * @sizeOf(f64)]u8 = undefined;
    const float_bytes = try lpcm.float64.encodeInto(
        &float_samples,
        &float_storage,
        .{ .format = float_format },
    );
    var float_decoded_storage: [float_samples.len]f64 = undefined;
    const float_decoded = try lpcm.float64.decodeInto(
        float_bytes,
        &float_decoded_storage,
        float_format,
    );
    for (float_samples, float_decoded) |expected, actual| {
        const expected_bits: u64 = @bitCast(expected);
        const actual_bits: u64 = @bitCast(actual);
        if (expected_bits != actual_bits) return error.FloatSampleMismatch;
    }

    // The stdout writer has its own buffer; flush it after printing so the output reaches the sink.
    var output_storage: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &output_storage);
    try output.interface.print("PCM16: {d} samples, {d} bytes\n", .{
        decoded_samples.len, encoded_bytes.len,
    });
    for (input_samples, decoded_samples) |before, after| {
        try output.interface.print("{d:.6} -> {d:.6}\n", .{ before, after });
    }
    try output.interface.writeAll("little-endian PCM16 bytes:");
    for (encoded_bytes) |byte| try output.interface.print(" {x:0>2}", .{byte});
    try output.interface.writeByte('\n');
    try output.interface.writeAll("exact PCM24 rewritten little-endian:");
    for (little_24) |byte| try output.interface.print(" {x:0>2}", .{byte});
    try output.interface.print("\nfinite float64 samples: {d}\n", .{float_decoded.len});
    try output.interface.flush();
}
