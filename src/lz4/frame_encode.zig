//! Complete LZ4 frame encoding. Reserve bound bytes and explicit workspace storage, then call into.
//! The returned slice borrows the used output prefix. Streaming uses the same options and storage
//! but may emit extra blocks when explicitly flushed.

const std = @import("std");
const Xxh32 = @import("../xxhash.zig").Xxh32;
const test_decode = @import("frame_decode.zig"); // Inline complete-frame comparisons only.
const FrameStreamEncoder = @import("FrameStreamEncoder.zig");
const FrameEncodeWorkspace = @import("FrameEncodeWorkspace.zig");
const greedy = @import("greedy_encode.zig");
const framing = @import("frame.zig");
const blocks = @import("block.zig");
const hc_encoder = blocks.encode.hc;
const FrameCounter = @import("FrameCounter.zig");
const format = @import("frame_format.zig");
const storage_checks = @import("frame_storage.zig");
const byte_ranges = @import("../common/byte_ranges.zig");
const overlaps = byte_ranges.overlapsChecked;
const skip_magic = format.skip_magic;

pub const Workspace = FrameEncodeWorkspace;
pub const StreamEncoder = FrameStreamEncoder;
pub const Limits = FrameCounter.Limits;
/// Complete encoding failures; output may contain an unpublished prefix.
pub const Error = hc_encoder.Error || FrameCounter.Error || error{
    InvalidOptions,
    ContentSizeMismatch,
};

test {
    _ = StreamEncoder;
    _ = Workspace;
    _ = skippable;
}

/// Greedy encoding or bounded HC search. The policy contains no dictionary; frame Options own
/// dictionary bytes and their application ID.
pub const Compression = union(enum) { fast, hc: hc_encoder.Policy };

/// Mutable reservations for one encoding operation/owner. Unused HC capacity may be supplied with
/// fast policy; only the selected encoder's reservations are borrowed and checked.
pub const Storage = struct {
    /// Required block buffers, history and greedy table reservation.
    workspace: *FrameEncodeWorkspace,
    /// Required only for HC policy; ignored and unborrowed for fast policy.
    hc_workspace: ?*hc_encoder.Workspace = null,
};

/// Encoding defaults to independent 64 KiB blocks with a content checksum. A supplied content size
/// is enforced, including an explicitly supplied zero.
pub const Options = struct {
    /// Maximum decoded bytes per block; workspace buffers must support this size.
    block_size: framing.BlockSize = .k64,
    /// Reset history to the initial dictionary for every block; false permits linked blocks.
    independent: bool = true,
    /// Emit a checksum after every encoded block.
    block_checksum: bool = false,
    /// Emit a checksum of all original content in the frame footer.
    content_checksum: bool = true,
    /// Optional original size. When supplied, finish requires exactly this many input bytes.
    content_size: ?u64 = null,
    /// Initial history and optional application dictionary ID, copied at reset.
    dictionary: ?framing.Dictionary = null,
    /// Cumulative input/output, work and frame-count bounds.
    limits: Limits = .{},

    /// Fast uses the greedy block encoder; HC search effort accumulates across the frame, including
    /// dictionary priming on every block.
    compression: Compression = .fast,
};

/// Bounds one complete frame with the selected maximum block size. Streaming flushes may add
/// blocks; reserve/emit output incrementally in that case.
pub fn bound(input_bytes: usize, options: Options) error{SizeOverflow}!usize {
    const block_bytes = options.block_size.bytes();
    const whole_blocks = input_bytes / block_bytes;
    const partial_block: usize = @intFromBool(input_bytes % block_bytes != 0);
    const block_count = whole_blocks + partial_block;
    const block_overhead: usize = if (options.block_checksum) 8 else 4;
    const overhead = std.math.mul(
        usize,
        block_count,
        block_overhead,
    ) catch return error.SizeOverflow;
    const framing_bytes = std.math.add(usize, overhead, 27) catch return error.SizeOverflow;
    return std.math.add(usize, input_bytes, framing_bytes) catch error.SizeOverflow;
}

/// Encodes one complete frame with no allocation after workspace construction. Requires `bound`
/// capacity and returns the used output prefix. Size fields are optional; supply source.len
/// explicitly to serialize that field.
pub fn into(source: []const u8, output: []u8, storage: Storage, options: Options) Error![]u8 {
    if (output.len < try bound(source.len, options)) return error.OutputTooSmall;
    if (options.dictionary == null and options.compression == .fast) {
        return encodeFastFrame(source, output, storage, options);
    }
    var encoder: FrameStreamEncoder = undefined;
    try encoder.reset(storage, options);
    const result = encoder.step(source, output, .finish) catch |err| switch (err) {
        error.NeedReset, error.InvalidState => unreachable,
        else => |failure| return failure,
    };
    std.debug.assert(result.status == .complete and result.consumed == source.len);
    return output[0..result.produced];
}

// A complete caller slice remains available for this entire call. Read full blocks directly,
// leaving the copying/resumption rules of FrameStreamEncoder.step for fragmented callers.
fn encodeFastFrame(
    source: []const u8,
    output: []u8,
    storage: Storage,
    options: Options,
) Error![]u8 {
    var encoder: FrameStreamEncoder = undefined;
    try encoder.reset(storage, options);
    if (try overlaps(source, output)) return error.Aliasing;
    try storage_checks.checkEncoder(std.mem.asBytes(&encoder), storage.workspace, null, source);
    try storage_checks.checkEncoder(std.mem.asBytes(&encoder), storage.workspace, null, output);

    var written: usize = 0;
    try encoder.counter.add(0, encoder.pending.len);
    @memcpy(output[written..][0..encoder.pending.len], encoder.pending);
    written += encoder.pending.len;

    var read: usize = 0;
    while (read < source.len) {
        const count = @min(options.block_size.bytes(), source.len - read);
        const block = source[read..][0..count];
        try encoder.counter.add(count, 0);
        if (options.content_size) |size| {
            if (encoder.counter.input > size) return error.ContentSizeMismatch;
        }
        if (options.content_checksum) encoder.content_hash.update(block);

        const encoded = if (options.independent) blk: {
            if (block.len == 65536) break :blk (try greedy.encodeWithInitialProbe(
                block,
                storage.workspace.encoded,
                &storage.workspace.codec,
            )) orelse block;
            break :blk try blocks.encode.into(
                block,
                storage.workspace.encoded,
                &storage.workspace.codec,
                .{},
            );
        } else blk: {
            // Linked blocks may reference the reachable suffix of earlier input.
            const history_size = @min(read, blocks.maximum_distance);
            const history = source[read - history_size .. read];
            break :blk try greedy.encodeRolling(
                block,
                storage.workspace.encoded,
                &storage.workspace.codec,
                history,
                true,
                &encoder.linked_hash,
            );
        };

        // Store a block verbatim when compression does not make it smaller.
        const compressed = encoded.len < block.len;
        const body = if (compressed) encoded else block;
        const checksum_bytes: usize = if (options.block_checksum) 4 else 0;
        const block_bytes = 4 + body.len + checksum_bytes;
        try encoder.counter.add(0, block_bytes);

        const stored_flag: u32 = if (compressed) 0 else 0x80000000;
        const block_header = @as(u32, @intCast(body.len)) | stored_flag;
        std.mem.writeInt(u32, output[written..][0..4], block_header, .little);
        written += 4;
        @memcpy(output[written..][0..body.len], body);
        written += body.len;

        if (options.block_checksum) {
            std.mem.writeInt(u32, output[written..][0..4], Xxh32.hash(body), .little);
            written += 4;
        }
        read += count;
    }

    if (options.content_size) |size| {
        if (encoder.counter.input != size) return error.ContentSizeMismatch;
    }
    const footer_bytes: usize = if (options.content_checksum) 8 else 4;
    try encoder.counter.add(0, footer_bytes);
    @memset(output[written..][0..4], 0);
    written += 4;
    if (options.content_checksum) {
        std.mem.writeInt(u32, output[written..][0..4], encoder.content_hash.final(), .little);
        written += 4;
    }
    return output[0..written];
}

/// Application metadata carried in standard skippable frames; decoding counts and skips it.
pub const skippable = struct {
    pub const Error = error{ InputTooLarge, SizeOverflow, Aliasing, OutputTooSmall };

    /// Builds the eight-byte header of a skippable frame. Emit this copied value followed by
    /// exactly payload_size application bytes when writing fragments.
    pub fn header(payload_size: u32, tag: u4) [8]u8 {
        var wire_header: [8]u8 = undefined;
        std.mem.writeInt(u32, wire_header[0..4], skip_magic + @as(u32, tag), .little);
        std.mem.writeInt(u32, wire_header[4..8], payload_size, .little);
        return wire_header;
    }

    /// Encodes application metadata as a skippable frame. Requires payload.len + 8 disjoint output
    /// bytes and leaves spare capacity untouched. The wire size is limited to u32 payload bytes; no
    /// checksum or allocation is added.
    pub fn into(payload: []const u8, output: []u8, tag: u4) skippable.Error![]u8 {
        if (payload.len > std.math.maxInt(u32)) return error.InputTooLarge;
        const size = std.math.add(usize, payload.len, 8) catch return error.SizeOverflow;
        if (try overlaps(payload, output)) return error.Aliasing;
        if (output.len < size) return error.OutputTooSmall;
        const wire_header = header(@intCast(payload.len), tag);
        @memcpy(output[0..8], &wire_header);
        @memcpy(output[8..size], payload);
        return output[0..size];
    }

    test "LZ4 skippable encoding matches fixed wire fields and preserves capacity" {
        const expected = [_]u8{ 0x5f, 0x2a, 0x4d, 0x18, 0x03, 0x00, 0x00, 0x00, 0x61, 0x62, 0x63 };
        var output: [32]u8 = @splat(0xa7);
        const bytes = try skippable.into("abc", &output, 15);
        try std.testing.expectEqualSlices(u8, &expected, bytes);
        try std.testing.expectEqualSlices(u8, expected[0..8], &skippable.header(3, 15));
        try std.testing.expect(std.mem.allEqual(u8, output[bytes.len..], 0xa7));
        const result = try test_decode.into(bytes, &.{}, .{});
        try std.testing.expectEqual(1, result.skippable_frames);
        try std.testing.expectError(error.OutputTooSmall, skippable.into("abc", output[0..10], 0));
        try std.testing.expectError(error.Aliasing, skippable.into(output[0..3], &output, 0));
    }
};

test "LZ4 complete fast frames match the resumable encoder" {
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 131089);
    defer allocator.free(source);
    var random: std.Random.DefaultPrng = .init(0x46e81a);
    random.random().bytes(source[0..65536]);
    @memcpy(source[65536..131072], source[0..65536]);
    @memcpy(source[131072..], source[0..17]);
    for ([_]framing.BlockSize{ .k64, .k256 }) |block_size| {
        const direct_workspace = try FrameEncodeWorkspace.create(allocator, block_size);
        defer direct_workspace.destroy(allocator);
        const stream_workspace = try FrameEncodeWorkspace.create(allocator, block_size);
        defer stream_workspace.destroy(allocator);
        for ([_]bool{ false, true }) |independent| {
            const options: Options = .{
                .block_size = block_size,
                .independent = independent,
                .block_checksum = true,
                .content_checksum = true,
                .content_size = source.len,
            };
            const capacity = try bound(source.len, options);
            const direct_storage = try allocator.alloc(u8, capacity + 1);
            defer allocator.free(direct_storage);
            const stream_storage = try allocator.alloc(u8, capacity);
            defer allocator.free(stream_storage);
            @memset(direct_storage, 0xa7);
            const direct = try into(
                source,
                direct_storage[0..capacity],
                .{ .workspace = direct_workspace },
                options,
            );

            var encoder: FrameStreamEncoder = undefined;
            try encoder.reset(.{ .workspace = stream_workspace }, options);
            const progress = try encoder.step(source, stream_storage, .finish);
            try std.testing.expectEqual(FrameStreamEncoder.Status.complete, progress.status);
            try std.testing.expectEqual(source.len, progress.consumed);
            try std.testing.expectEqualSlices(u8, direct, stream_storage[0..progress.produced]);
            try std.testing.expectEqual(@as(u8, 0xa7), direct_storage[capacity]);

            const recovered = try allocator.alloc(u8, source.len);
            defer allocator.free(recovered);
            _ = try test_decode.into(direct, recovered, .{ .trailing_data = .reject });
            try std.testing.expectEqualSlices(u8, source, recovered);

            var limited = options;
            limited.limits.input_bytes = source.len - 1;
            try std.testing.expectError(
                error.LimitExceeded,
                into(
                    source,
                    direct_storage[0..capacity],
                    .{ .workspace = direct_workspace },
                    limited,
                ),
            );
        }
    }
}
