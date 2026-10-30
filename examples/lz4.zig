//! Encode the same bytes as greedy/HC raw blocks and a checksummed standard frame.
const std = @import("std");
const lz4 = @import("wingman").lz4;

/// The optional argument is the exact text to compress.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const source = if (args.len > 1)
        args[1]
    else
        "LZ4 repeats bytes. LZ4 repeats bytes. LZ4 repeats bytes.";
    const allocator = init.gpa;
    const fast_workspace = try lz4.EncoderWorkspace.create(allocator);
    defer fast_workspace.destroy(allocator);
    const hc_workspace = try lz4.HcEncoderWorkspace.create(allocator);
    defer hc_workspace.destroy(allocator);
    defer hc_workspace.clear();
    const block_capacity = try lz4.blockEncodeBound(source.len);
    const block_storage = try allocator.alloc(u8, block_capacity);
    defer allocator.free(block_storage);
    const restored = try allocator.alloc(u8, source.len + 8);
    defer allocator.free(restored);
    @memset(restored, 0xa5);

    const greedy_block = try lz4.encodeBlock(source, block_storage, fast_workspace, .{});
    const greedy_size = greedy_block.len;
    const greedy_result = try lz4.decodeBlock(greedy_block, restored[0..source.len], .{});
    if (greedy_result.consumed != greedy_size or !std.mem.eql(
        u8,
        source,
        restored[0..greedy_result.produced],
    )) return error.BlockMismatch;

    // Reuse the complete allocation, after the prior encoded prefix has retired.
    const hc_block = try lz4.encodeBlockHc(source, block_storage, hc_workspace, .{});
    const hc_result = try lz4.decodeBlock(hc_block, restored[0..source.len], .{});
    if (!std.mem.eql(u8, source, restored[0..hc_result.produced])) return error.HcMismatch;

    const frame_options: lz4.FrameEncodeOptions = .{
        .content_size = source.len,
        .block_checksum = true,
    };
    const frame_workspace = try lz4.FrameEncoderWorkspace.create(allocator, .k64);
    defer frame_workspace.destroy(allocator);
    const frame_capacity = try lz4.frameEncodeBound(source.len, frame_options);
    const frame_storage = try allocator.alloc(u8, frame_capacity);
    defer allocator.free(frame_storage);
    const frame = try lz4.encodeFrame(
        source,
        frame_storage,
        .{ .workspace = frame_workspace },
        frame_options,
    );
    const frame_result = try lz4.decodeFrame(frame, restored, .{ .trailing_data = .reject });
    if (frame_result.consumed != frame.len or frame_result.frames != 1 or !std.mem.eql(
        u8,
        source,
        restored[0..frame_result.produced],
    )) return error.FrameMismatch;
    if (!std.mem.allEqual(u8, restored[source.len..], 0xa5)) return error.SpareOutputChanged;

    var buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "source: {d} bytes; raw: {d}; HC raw: {d}; checksummed frame: {d}\n",
        .{ source.len, greedy_size, hc_block.len, frame.len },
    );
    try output.interface.print(
        "all three recover the exact bytes; spare output is unchanged\n",
        .{},
    );
    try output.interface.flush();
}
