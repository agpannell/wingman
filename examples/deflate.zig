//! Encode and recover raw DEFLATE using complete calls and fragmented input.
const std = @import("std");
const deflate = @import("wingman").deflate;

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const source = if (arguments.len > 1)
        arguments[1]
    else
        "DEFLATE repeats bytes. DEFLATE repeats bytes. DEFLATE repeats bytes.";
    const allocator = init.gpa;

    // Workspaces are caller-owned and must stay at stable addresses. Clearing the encoder erases
    // retained input and scratch before the same allocator releases it.
    const encoder_workspace = try deflate.EncoderWorkspace.create(allocator);
    defer encoder_workspace.destroy(allocator);
    defer encoder_workspace.clear();
    const decoder_workspace = try deflate.DecoderWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);

    // encodeBound reserves enough space for a complete stream. The returned encoded slice borrows
    // that reservation, so retain the full allocation to free it later. Level 6 is the default;
    // level 9 spends more work on offline parsing and can be useful when size matters more.
    const capacity = try deflate.encodeBound(source.len);
    const encoded_storage = try allocator.alloc(u8, capacity);
    defer allocator.free(encoded_storage);
    const options: deflate.EncodeOptions = .{ .compression = .{ .level = 6 } };
    const encoded = try deflate.encode(source, encoded_storage, encoder_workspace, options);

    // This application knows the original size, so require both that exact output extent and
    // consumption of the entire encoded slice. Raw DEFLATE itself carries neither size nor
    // checksum.
    const restored = try allocator.alloc(u8, source.len);
    defer allocator.free(restored);
    const decode_options: deflate.DecodeOptions = .{
        .output_size = .exact,
        .trailing_data = .reject,
    };
    const decoded = try deflate.decode(
        encoded,
        restored,
        .{ .workspace = decoder_workspace },
        decode_options,
    );
    if (decoded.consumed != encoded.len or decoded.produced != source.len or !std.mem.eql(
        u8,
        source,
        restored,
    )) return error.RoundTripMismatch;

    // A streaming encoder borrows its workspace until reset or the end of use. It accepts small
    // input fragments and returns output fragments; both may retire after each step. Repeat finish
    // with any unconsumed suffix, then with empty input while pending output drains.
    const fragment_storage = try allocator.alloc(u8, capacity);
    defer allocator.free(fragment_storage);
    var encoder: deflate.Encoder = undefined;
    try encoder.reset(encoder_workspace, options);
    var consumed: usize = 0;
    var produced: usize = 0;
    while (true) {
        const input_count = @min(source.len - consumed, 7);
        const input_end = consumed + input_count;
        const output_count = @min(fragment_storage.len - produced, 11);
        const output_end = produced + output_count;
        const action: deflate.EncodeAction = if (input_end == source.len) .finish else .process;
        const progress = try encoder.step(
            source[consumed..input_end],
            fragment_storage[produced..output_end],
            action,
        );
        consumed += progress.consumed;
        produced += progress.produced;
        if (progress.status == .complete) break;
        if (progress.consumed == 0 and progress.produced == 0) return error.NoProgress;
    }
    const streamed = fragment_storage[0..produced];
    const streamed_result = try deflate.decode(
        streamed,
        restored,
        .{ .workspace = decoder_workspace },
        decode_options,
    );
    if (streamed_result.consumed != streamed.len or streamed_result.produced != source.len or !std
        .mem.eql(
        u8,
        source,
        restored,
    )) return error.RoundTripMismatch;

    var buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "raw DEFLATE: {d} source bytes, {d} complete bytes, {d} streamed bytes; recovery matches\n",
        .{ source.len, encoded.len, streamed.len },
    );
    try output.interface.flush();
}
