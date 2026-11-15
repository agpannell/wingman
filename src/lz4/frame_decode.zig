//! Complete LZ4 frame recovery without an allocation or history workspace. The selected frames are
//! verified before a result is returned. Bounded output is the default; spare bytes survive.

const std = @import("std");
const Xxh32 = @import("../xxhash.zig").Xxh32;
const copy = @import("copy.zig");
const OutputSize = @import("../lz4.zig").OutputSize;
const recovery = @import("block_recovery.zig");
const test_encode = @import("frame_encode.zig"); // Inline complete-frame comparisons only.
const FrameEncodeWorkspace = @import("FrameEncodeWorkspace.zig"); // Inline frame fixtures only.
const FrameStreamDecoder = @import("FrameStreamDecoder.zig");
const framing = @import("frame.zig");
const blocks = @import("block.zig");
const FrameCounter = @import("FrameCounter.zig");
const format = @import("frame_format.zig");
const byte_ranges = @import("../common/byte_ranges.zig");
const overlaps = byte_ranges.overlapsChecked;
const magic = format.magic;
const skip_magic = format.skip_magic;

pub const StreamDecoder = FrameStreamDecoder;
pub const Workspace = @import("FrameDecodeWorkspace.zig");
/// Complete frame admission, storage, integrity and resource failures.
pub const Error = blocks.decode.Error || FrameCounter.Error || error{
    InvalidFrame,
    ChecksumMismatch,
    ContentSizeMismatch,
    NeedDictionary,
    WrongDictionary,
};

test {
    _ = StreamDecoder;
    _ = Workspace;
}

/// Cumulative admission across ordinary/skippable frames. Work charges accepted encoded bytes plus
/// produced decoded bytes once, including skippable payload; dictionary setup is excluded.
pub const Limits = struct {
    /// Maximum accepted encoded bytes, including frame fields and skippable payload.
    input_bytes: u64 = std.math.maxInt(u64),
    /// Maximum decoded bytes across the selected frames.
    output_bytes: u64 = std.math.maxInt(u64),
    /// Maximum encoded input plus decoded output byte work.
    work_units: u64 = std.math.maxInt(u64),
    /// Maximum ordinary and skippable frames combined.
    frames: u64 = std.math.maxInt(u64),
    /// Reject a descriptor advertising a larger decoded block, even if its actual block is smaller.
    block_bytes: usize = 4 * 1024 * 1024,
};

/// Complete frame policy; dictionaries without IDs apply out of band to descriptors without IDs.
pub const Options = struct {
    /// Which complete frames to verify before returning.
    frames: Selection = .single,
    /// Borrowed initial history and optional application ID; absent IDs use out-of-band agreement.
    dictionary: ?framing.Dictionary = null,
    /// Bounded accepts spare capacity; exact requires the full destination length.
    output_size: OutputSize = .bounded,
    /// Whether bytes following the selected complete frame may remain.
    trailing_data: TrailingData = .allow,
    /// Cumulative byte/work/frame and advertised block admission.
    limits: Limits = .{},
};

/// Whether bytes following the selected frames may remain unconsumed.
pub const TrailingData = enum { allow, reject };

/// Complete-buffer counts. Frames includes skippable frames; skippable_frames counts that subset.
/// Bytes following a selected single frame remain unconsumed.
pub const Result = struct {
    /// Encoded prefix occupied by the selected verified frames.
    consumed: usize,
    /// Decoded output prefix ready for publication.
    produced: usize,
    /// Verified ordinary and skippable frames combined.
    frames: u64,
    /// Verified frames that carried only application metadata.
    skippable_frames: u64,
};

/// Which complete frames to verify; explicit boundary events belong to StreamDecoder.Selection.
pub const Selection = enum {
    /// Verify the first ordinary or skippable frame and return its consumed length.
    single,
    /// Verify every frame through the complete supplied input end.
    concatenate,
};

/// Recovers complete frames directly into bounded output without a workspace or allocation. The
/// used output prefix is result.produced bytes. Exact input ends and output capacity are enforced;
/// trailing capacity remains untouched. Use result.consumed to advance after selecting one frame.
pub fn into(source: []const u8, output: []u8, options: Options) Error!Result {
    if (try overlaps(source, output)) return error.Aliasing;
    if (options.dictionary) |dict| {
        if (try overlaps(format.dictionarySuffix(dict.bytes), output)) return error.Aliasing;
    }

    var counter: FrameCounter = .init(options.limits);
    var read: usize = 0;
    var written: usize = 0;
    var skipped: u64 = 0;

    // Parse whole frame members in order. Skippable members only advance input; ordinary members
    // decode bounded blocks and keep a per-frame output start for linked history and size checks.
    while (true) {
        const tag = std.mem.readInt(u32, (try take(source, &read, 4, &counter))[0..4], .little);
        try counter.frame();
        if (tag & 0xfffffff0 == skip_magic) {
            const field = try take(source, &read, 4, &counter);
            const size = std.mem.readInt(u32, field[0..4], .little);
            _ = try take(source, &read, size, &counter);
            skipped += 1;
        } else {
            if (tag != magic) return error.InvalidFrame;
            const prefix = try take(source, &read, 2, &counter);
            const size = try format.descriptorSize(prefix);
            _ = try take(source, &read, size - 2, &counter);
            const info = try format.parseDescriptor(source[read - size .. read]);
            if (info.block_size.bytes() > options.limits.block_bytes) return error.LimitExceeded;
            const dict = try dictionaryFor(info, options.dictionary);
            const begin = written;

            // A zero header ends this member's data blocks; the footer then validates total content
            // size and, when present, the checksum over all decoded bytes in this frame.
            while (true) {
                const block_header = try take(source, &read, 4, &counter);
                const field = std.mem.readInt(u32, block_header[0..4], .little);
                if (field == 0) break;
                const count: usize = field & 0x7fffffff;
                if (count > info.block_size.bytes()) return error.InvalidFrame;
                const block = try take(source, &read, count, &counter);

                // Verify compressed bytes before decoding them. Stored blocks have no sequence
                // work, while compressed blocks use only the output extent admitted by the caller.
                if (info.block_checksum) {
                    const checksum = try take(source, &read, 4, &counter);
                    const expected = std.mem.readInt(u32, checksum[0..4], .little);
                    if (Xxh32.hash(block) != expected) return error.ChecksumMismatch;
                }

                const capacity = @min(output.len - written, info.block_size.bytes());
                const allowed = counter.outputCapacity(capacity);
                const produced = blk: {
                    if (field & 0x80000000 != 0) {
                        if (count > allowed) {
                            if (allowed < capacity) return error.LimitExceeded;
                            return error.OutputTooSmall;
                        }
                        copy.nonOverlapping(output[written..][0..count], block);
                        break :blk count;
                    }

                    const history: blocks.decode.History = .{
                        .older = if (info.independent) &.{} else dict,
                        .newer = if (info.independent) dict else output[begin..written],
                    };
                    // Linked frame blocks can refer to the initial dictionary and every decoded
                    // block since this frame began. Independent blocks always reset to the initial
                    // dictionary.
                    const decoded: blocks.decode.Error!blocks.decode.Result = if (!info
                        .independent and dict.len == 0 and written > begin) recovery.intoWithPrefix(
                        block,
                        output[begin .. written + allowed],
                        written - begin,
                    ) else blocks.decode.into(
                        block,
                        output[written..][0..allowed],
                        .{ .history = history, .output_size = .bounded },
                    );
                    break :blk (decoded catch |err| {
                        @branchHint(.unlikely);
                        if (err == error.OutputTooSmall) {
                            if (allowed < capacity) return error.LimitExceeded;
                            if (capacity == info.block_size.bytes()) return error.InvalidFrame;
                        }
                        return err;
                    }).produced;
                };
                try counter.add(0, produced);
                written += produced;
                if (info.content_size) |expected| {
                    if (written - begin > expected) return error.ContentSizeMismatch;
                }
            }
            if (info.content_size) |expected| {
                if (written - begin != expected) return error.ContentSizeMismatch;
            }
            if (info.content_checksum) {
                const checksum = try take(source, &read, 4, &counter);
                const expected = std.mem.readInt(u32, checksum[0..4], .little);
                const actual = Xxh32.hash(output[begin..written]);
                if (actual != expected) return error.ChecksumMismatch;
            }
        }
        if (options.frames != .concatenate or read == source.len) {
            if (options.output_size == .exact and written != output.len)
                return error.OutputSizeMismatch;
            if (options.trailing_data == .reject and read != source.len) return error.InvalidFrame;
            return .{
                .consumed = read,
                .produced = written,
                .frames = counter.frames,
                .skippable_frames = skipped,
            };
        }
    }
}

fn dictionaryFor(info: framing.Descriptor, supplied: ?framing.Dictionary) Error![]const u8 {
    if (info.dictionary_id) |id| {
        const dict = supplied orelse return error.NeedDictionary;
        if (dict.id == null or dict.id.? != id) return error.WrongDictionary;
    }
    return if (supplied) |dict| format.dictionarySuffix(dict.bytes) else &.{};
}

fn take(source: []const u8, cursor: *usize, count: usize, counter: *FrameCounter) Error![]const u8 {
    if (count > source.len - cursor.*) return error.Truncated;
    try counter.add(count, 0);
    const result = source[cursor.*..][0..count];
    cursor.* += count;
    return result;
}

test "LZ4 frames frozen empty bytes and optional zero fields" {
    // Produced by LZ4F_compressFrame in LZ4 1.10.0, with independent blocks and no optional fields.
    // Reference implementation: BSD-2-Clause. https://github.com/lz4/lz4/blob/v1.10.0/lib/LICENSE
    const empty = [_]u8{ 0x04, 0x22, 0x4d, 0x18, 0x60, 0x40, 0x82, 0x00, 0x00, 0x00, 0x00 };
    const result = try into(&empty, &.{}, .{});
    try std.testing.expectEqual(empty.len, result.consumed);
    try std.testing.expectEqual(0, result.produced);
    const allocator = std.testing.allocator;
    const workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    var output: [64]u8 = @splat(0xa7);
    const encoded = try test_encode.into(
        &.{},
        &output,
        .{ .workspace = workspace },
        .{ .content_checksum = false },
    );
    try std.testing.expectEqualSlices(u8, &empty, encoded);
    const with_zero = try test_encode.into(
        &.{},
        &output,
        .{ .workspace = workspace },
        .{ .content_size = 0, .dictionary = .{ .bytes = &.{}, .id = 0 } },
    );
    try std.testing.expectError(error.NeedDictionary, into(with_zero, &.{}, .{}));
    _ = try into(with_zero, &.{}, .{ .dictionary = .{ .bytes = &.{}, .id = 0 } });
    try std.testing.expect(std.mem.allEqual(u8, output[with_zero.len..], 0xa7));
}

test "LZ4 frames all block sizes dictionaries checksums and linked history" {
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 131089);
    defer allocator.free(source);
    var random: std.Random.DefaultPrng = .init(4242);
    random.random().bytes(source[0..65536]);
    @memcpy(source[65536..131072], source[0..65536]);
    @memcpy(source[131072..], source[0..17]);
    const output = try allocator.alloc(u8, source.len + 17);
    defer allocator.free(output);
    inline for (.{ .k64, .k256, .m1, .m4 }) |block_size| {
        const workspace = try FrameEncodeWorkspace.create(allocator, block_size);
        defer workspace.destroy(allocator);
        inline for (.{ false, true }) |independent| {
            const options: test_encode.Options = .{
                .block_size = block_size,
                .independent = independent,
                .block_checksum = true,
                .content_size = source.len,
                .dictionary = .{ .bytes = source[0..50000], .id = 77 },
            };
            const storage = try allocator.alloc(u8, try test_encode.bound(source.len, options));
            defer allocator.free(storage);
            const wire = try test_encode.into(
                source,
                storage,
                .{ .workspace = workspace },
                options,
            );
            @memset(output, 0xa7);
            const result = try into(wire, output, .{ .dictionary = options.dictionary });
            try std.testing.expectEqual(wire.len, result.consumed);
            try std.testing.expectEqual(source.len, result.produced);
            try std.testing.expectEqualSlices(u8, source, output[0..source.len]);
            try std.testing.expect(std.mem.allEqual(u8, output[source.len..], 0xa7));
            try std.testing.expectError(
                error.OutputTooSmall,
                into(wire, output[0 .. source.len - 1], .{ .dictionary = options.dictionary }),
            );
        }
    }
}

test "LZ4 frame complete extent trailing and descriptor admission are independent" {
    const allocator = std.testing.allocator;
    const workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    var wire: [128]u8 = undefined;
    const frame = try test_encode.into("hello", &wire, .{ .workspace = workspace }, .{});
    var joined: [256]u8 = undefined;
    const skip = try test_encode.skippable.into("meta", &joined, 15);
    @memcpy(joined[skip.len..][0..frame.len], frame);
    const sequence = joined[0 .. skip.len + frame.len];
    var output: [8]u8 = @splat(0xa7);
    const single = try into(sequence, &output, .{});
    try std.testing.expectEqual(skip.len, single.consumed);
    try std.testing.expectEqual(@as(u64, 1), single.skippable_frames);
    try std.testing.expectEqual(0, single.produced);
    try std.testing.expectError(
        error.InvalidFrame,
        into(sequence, &output, .{ .trailing_data = .reject }),
    );
    const both = try into(sequence, &output, .{ .frames = .concatenate, .trailing_data = .reject });
    try std.testing.expectEqual(@as(u64, 2), both.frames);
    try std.testing.expectEqualStrings("hello", output[0..both.produced]);
    try std.testing.expect(std.mem.allEqual(u8, output[5..], 0xa7));
    try std.testing.expectError(
        error.OutputSizeMismatch,
        into(frame, &output, .{ .output_size = .exact }),
    );
    _ = try into(frame, output[0..5], .{ .output_size = .exact, .trailing_data = .reject });
    try std.testing.expectError(
        error.LimitExceeded,
        into(frame, &output, .{ .limits = .{ .block_bytes = framing.BlockSize.k64.bytes() - 1 } }),
    );
}
