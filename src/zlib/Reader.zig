//! Pull reader for an RFC 1950 zlib stream. Initialize this native state at its final address and
//! keep it disjoint from the borrowed input reader and history until reading ends. Drain reader to
//! EndOfStream to verify the trailer; an exact payload read alone may leave it unchecked. Malformed
//! streams, dictionary requests and input failures become ReadFailed. Following compressed input
//! stays in the input reader. Call init again after failure or reuse.

const std = @import("std");
const deflate = @import("../deflate.zig");
const zlib = @import("../zlib.zig");

const Reader = @This();

/// Independent caller-owned LZ history required for this reader, in bytes.
pub const history_bytes = 32768;

/// Decompressed byte interface, bound to this object's inline buffer.
reader: std.Io.Reader,
/// Borrowed compressed input reader, kept live and at its address throughout use.
input: *std.Io.Reader,
/// Native DEFLATE tables and progress, initialized in place by init.
workspace: deflate.DecoderWorkspace,
/// zlib framing and checksum state, borrowing workspace and caller history.
decoder: zlib.Decoder,
/// Decompressed lookahead owned by reader.
buffer: [4096]u8,
/// Whether the complete zlib stream has been validated.
complete: bool,

/// Binds the native decoder without copying its large state. Supply at least history_bytes of
/// caller storage and keep input, history and this owner disjoint and fixed throughout reading.
pub fn init(self: *Reader, input: *std.Io.Reader, history: []u8) void {
    self.input = input;
    self.complete = false;
    self.reader = .{
        .vtable = &.{ .stream = stream },
        .buffer = &self.buffer,
        .seek = 0,
        .end = 0,
    };
    self.decoder.reset(
        .{ .workspace = &self.workspace, .history = history[0..history_bytes] },
        .{ .limits = .{} },
    ) catch unreachable;
}

fn stream(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    limit: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
    const self: *Reader = @alignCast(@fieldParentPtr("reader", reader));
    if (self.complete) return error.EndOfStream;
    // Keep output separate from filtered LZ history and the Reader's buffered prefix.
    var output: [4096]u8 = undefined;
    const progress = zlib.decodeReader(
        self.input,
        output[0..limit.minInt(output.len)],
        &self.decoder,
    ) catch return error.ReadFailed;
    if (progress.status == .need_dictionary) return error.ReadFailed;
    self.complete = progress.status == .complete;
    try writer.writeAll(output[0..progress.produced]);
    if (progress.produced == 0 and self.complete) return error.EndOfStream;
    return progress.produced;
}

test init {
    // Python's zlib.compress produced this stream independently of the native codec.
    const encoded = [_]u8{
        120, 156, 171, 202, 201, 76, 82,  40, 40, 205, 201, 81, 40, 74,  77,  76, 73, 45, 82, 72,
        206, 72,  77,  206, 46,  86, 200, 44, 41, 86,  40,  41, 74, 204, 204, 73, 45, 2,  0,  236,
        68,  13,  54,
    };
    const expected = "zlib pull reader checks its trailer";
    const with_suffix = encoded ++ "END";
    var input: std.Io.Reader = .fixed(with_suffix);
    const owner = try std.testing.allocator.create(Reader);
    defer std.testing.allocator.destroy(owner);
    var history: [history_bytes]u8 = undefined;
    owner.init(&input, &history);
    var output: [expected.len]u8 = undefined;
    try owner.reader.readSliceAll(output[0..7]);
    for (output[7..]) |*byte| byte.* = try owner.reader.takeByte();
    try std.testing.expectEqualStrings(expected, &output);
    try std.testing.expectError(error.EndOfStream, owner.reader.takeByte());
    try std.testing.expect(owner.complete);
    try std.testing.expectEqualStrings("END", try input.take(3));

    var corrupted = encoded;
    corrupted[corrupted.len - 1] ^= 1;
    input = .fixed(&corrupted);
    owner.init(&input, &history);
    var discarded: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.ReadFailed, owner.reader.streamRemaining(&discarded.writer));
    try std.testing.expect(!owner.complete);
}
