//! Compress byte streams into raw RFC 1951 DEFLATE blocks without allocating. Complete encoding
//! borrows a workspace and returns a prefix of caller output; StreamEncoder accepts fragments and
//! explicit flush/finish boundaries. The four_byte_runs family uses a smaller workspace for
//! repeated four-byte patterns, with a bounded workspace-free short operation.
//!
//! Iterative parsing and serialized cost selection were informed by libdeflate and Zopfli:
//! https://github.com/ebiggers/libdeflate/blob/v1.26/lib/deflate_compress.c
//! https://github.com/google/zopfli/blob/zopfli-1.0.3/src/zopfli/squeeze.c No reference
//! implementation is called or linked.

const std = @import("std");
const streaming = @import("encode_stream.zig");
const runs = @import("four_byte_runs.zig");
const disjoint = streaming.disjoint;
const test_decoding = @import("../deflate.zig");
const borrows = @import("block_borrows.zig");

const slab_bytes = 65535;

pub const Compression = @import("Compression.zig");
pub const Workspace = @import("EncodeWorkspace.zig");
pub const Options = @import("EncodeOptions.zig");
pub const Limits = @import("EncodeLimits.zig");
pub const Stats = @import("EncodeStats.zig");
pub const Action = streaming.Action;
pub const Status = streaming.Status;
pub const Progress = streaming.Progress;
pub const StreamEncoder = streaming.StreamEncoder;

/// Complete encoding failures return no result; output and scratch may already have changed.
pub const Error = error{
    /// Unsupported window or compression policy.
    InvalidOptions,
    /// Source, dictionary, output or scratch overlap where independent storage is required.
    StorageOverlap,
    /// The destination cannot hold the complete stream.
    OutputTooSmall,
    /// An input, output or algorithmic work allowance was exhausted.
    LimitExceeded,
    /// Required capacity or cumulative byte accounting cannot be represented.
    CounterOverflow,
};

/// Stored/four-byte-run streaming with a smaller workspace, and a bounded workspace-free operation.
pub const four_byte_runs = struct {
    pub const Options = @import("FourByteRunOptions.zig");
    pub const Workspace = @import("FourByteRunWorkspace.zig");
    pub const StreamEncoder = streaming.FourByteRunStreamEncoder;

    pub const short = runs.short;
};

/// Sufficient capacity for one stream, including final padding and a possible empty final block
/// after process fills its last slab. Accepts a complete call or process calls followed by finish.
/// Explicit flush/full_flush boundaries need additional capacity; each empty stored synchronization
/// marker occupies at most six bytes. Overflow returns CounterOverflow.
pub fn bound(source_bytes: usize) error{CounterOverflow}!usize {
    const partial = @intFromBool(source_bytes % slab_bytes != 0);
    const slabs = @max(1, source_bytes / slab_bytes + partial);
    const overhead = std.math.mul(usize, slabs, 5) catch return error.CounterOverflow;
    return std.math.add(usize, source_bytes, overhead + 7) catch error.CounterOverflow;
}

/// Encodes one independent stream into exact unpadded caller storage. The returned prefix borrows
/// output. Source/output/workspace must be disjoint; failures may change output. No state or
/// allocator survives this call.
pub fn into(source: []const u8, output: []u8, workspace: *Workspace, options: Options) Error![]u8 {
    try disjoint(source, output);
    try disjoint(source, std.mem.asBytes(workspace));
    try disjoint(output, std.mem.asBytes(workspace));
    if (options.dictionary) |dictionary| try disjoint(dictionary, output);
    var encoder: StreamEncoder = undefined;
    try encoder.reset(workspace, options);
    // Reset leaves this fresh owner usable with no pending boundary. A single finish cannot produce
    // a lifecycle error; resource and overlap failures still propagate.
    const result = encoder.step(source, output, .finish) catch |err| switch (err) {
        error.InvalidState, error.NeedReset => unreachable,
        else => |failure| return failure,
    };
    if (result.status != .complete) return error.OutputTooSmall;
    return output[0..result.produced];
}

test {
    _ = Compression;
    _ = Options;
    _ = Limits;
    _ = Stats;
    _ = four_byte_runs.Options;
    _ = streaming;

    // Ordinary block construction and its shared RFC fields.
    _ = @import("compression_effort.zig");
    _ = @import("format.zig");
    _ = @import("MatchCandidates.zig");
    _ = @import("PrefixMatchTree.zig");
    _ = @import("MatchFinder.zig");
    _ = @import("Lz77Parser.zig");
    _ = @import("HuffmanCodebook.zig");
    _ = @import("DynamicBlockHeader.zig");
    _ = @import("BlockSelector.zig");
    _ = @import("BlockWriter.zig");
    _ = @import("BlockEncoder.zig");

    // Prebuilt run codebooks, packing and the bounded short operation.
    _ = runs;
}

test into {
    const allocator = std.testing.allocator;
    const source = "shared history: a small record with a shared history";
    const dictionary = "common shared history: ";
    const encoding_workspace = try Workspace.create(allocator);
    defer encoding_workspace.destroy(allocator);
    const decoding_workspace = try test_decoding.decode.Workspace.create(allocator);
    defer decoding_workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const capacity = try bound(source.len);
    const complete_wire = try allocator.alloc(u8, capacity);
    defer allocator.free(complete_wire);
    const fragmented_wire = try allocator.alloc(u8, capacity);
    defer allocator.free(fragmented_wire);
    const restored = try allocator.alloc(u8, source.len);
    defer allocator.free(restored);

    // Omitting compression selects level 6. The returned slice borrows complete_wire; neither the
    // source nor the dictionary is retained after this complete call.
    const options: Options = .{ .dictionary = dictionary };
    const wire = try into(source, complete_wire, encoding_workspace, options);
    const storage: test_decoding.decode.Storage = .{
        .workspace = decoding_workspace,
        .history = history,
    };
    const recovered = try test_decoding.decode.into(
        wire,
        restored,
        storage,
        .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(source.len, recovered.produced);
    try std.testing.expectEqualSlices(u8, source, restored);

    // Level 9 spends more effort on offline parsing for callers that favor size. Reduced offline
    // pricing and early refinement are optional speed/size tradeoffs; their effects depend on the
    // data.
    const offline_wire = try into(
        source,
        fragmented_wire,
        encoding_workspace,
        .{
            .dictionary = dictionary,
            .compression = .{
                .level = 9,
                .offline_pricing = .reduced,
                .offline_refinement = .early,
            },
        },
    );
    const restored_offline = try test_decoding.decode.into(
        offline_wire,
        restored,
        storage,
        .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(source.len, restored_offline.produced);
    try std.testing.expectEqualSlices(u8, source, restored);

    // Reduced lazy lookahead is an opt-in tradeoff at levels 4–6. It can change output and work;
    // the default retains full lookahead.
    const reduced_wire = try into(
        source,
        fragmented_wire,
        encoding_workspace,
        .{ .dictionary = dictionary, .compression = .{ .lazy_lookahead = .reduced } },
    );
    const restored_reduced = try test_decoding.decode.into(
        reduced_wire,
        restored,
        storage,
        .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(source.len, restored_reduced.produced);
    try std.testing.expectEqualSlices(u8, source, restored);

    // Streaming keeps the workspace borrowed but lets each accepted input and returned output span
    // retire. Repeat finish while draining pending output; enclosing formats own integrity checks.
    var encoder: StreamEncoder = undefined;
    try encoder.reset(encoding_workspace, options);
    var read: usize = 0;
    var written: usize = 0;
    while (true) {
        const end = @min(source.len, read + 7);
        const action: Action = if (end == source.len) .finish else .process;
        const output_end = @min(fragmented_wire.len, written + 11);
        const progress = try encoder.step(
            source[read..end],
            fragmented_wire[written..output_end],
            action,
        );
        read += progress.consumed;
        written += progress.produced;
        if (progress.status == .complete) break;
        try std.testing.expect(progress.consumed != 0 or progress.produced != 0);
    }
    const streamed = try test_decoding.decode.into(
        fragmented_wire[0..written],
        restored,
        storage,
        .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(source.len, streamed.produced);
    try std.testing.expectEqualSlices(u8, source, restored);
}

test "stream bound admits process followed by finish at slab boundaries" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const decoder = try test_decoding.decode.Workspace.create(allocator);
    defer decoder.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const source = try allocator.alloc(u8, 2 * slab_bytes + 1);
    defer allocator.free(source);
    var random: std.Random.DefaultPrng = .init(0x7c51);
    random.random().bytes(source);
    const restored = try allocator.alloc(u8, source.len);
    defer allocator.free(restored);
    for (
        [_]usize{
            0,
            1,
            slab_bytes - 1,
            slab_bytes,
            slab_bytes + 1,
            2 * slab_bytes,
            2 * slab_bytes + 1,
        },
    ) |length| {
        const capacity = try bound(length);
        const guarded = try allocator.alloc(u8, capacity + 2);
        defer allocator.free(guarded);
        for (
            [_]Compression{
                .{ .level = 0 },
                .{ .strategy = .four_byte_runs },
                .{ .strategy = .huffman_only },
            },
        ) |compression| {
            for ([_]usize{ 257, slab_bytes }) |fragment| {
                @memset(guarded, 0xa5);
                const wire = guarded[1..][0..capacity];
                var encoder: StreamEncoder = undefined;
                try encoder.reset(workspace, .{ .compression = compression });
                var read: usize = 0;
                var written: usize = 0;
                while (read < length) {
                    const end = @min(length, read + fragment);
                    const progress = try encoder.step(source[read..end], wire[written..], .process);
                    read += progress.consumed;
                    written += progress.produced;
                    try std.testing.expect(progress.consumed != 0 or progress.produced != 0);
                }
                while (true) {
                    const progress = try encoder.step(&.{}, wire[written..], .finish);
                    written += progress.produced;
                    if (progress.status == .complete) break;
                    try std.testing.expect(progress.produced != 0);
                }
                const recovered = try test_decoding.decode.into(
                    wire[0..written],
                    restored[0..length],
                    .{ .workspace = decoder, .history = history },
                    .{ .output_size = .exact, .trailing_data = .reject },
                );
                try std.testing.expectEqual(length, recovered.produced);
                try std.testing.expectEqualSlices(u8, source[0..length], restored[0..length]);
                try std.testing.expectEqual(@as(u8, 0xa5), guarded[0]);
                try std.testing.expectEqual(@as(u8, 0xa5), guarded[guarded.len - 1]);
            }
        }
    }
}

test "native encoder profiles preserve independent RFC wires and exact recovery" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try Workspace.create(allocator);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try test_decoding.decode.Workspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    var wire: [4096]u8 = undefined;

    // RFC 1951 Sections 3.2.4 and 3.2.6, independently derived: stored A, empty fixed EOB and fixed
    // literal A followed by EOB.
    const stored_a = [_]u8{ 0x01, 0x01, 0x00, 0xfe, 0xff, 0x41 };
    const empty_fixed = [_]u8{ 0x03, 0x00 };
    const fixed_a = [_]u8{ 0x73, 0x04, 0x00 };
    const stored = try into("A", &wire, encoder_workspace, .{ .compression = .{ .level = 0 } });
    try std.testing.expectEqualSlices(u8, &stored_a, stored);
    try std.testing.expectEqualSlices(
        u8,
        &empty_fixed,
        try into("", &wire, encoder_workspace, .{}),
    );
    try std.testing.expectEqualSlices(u8, &fixed_a, try into("A", &wire, encoder_workspace, .{}));

    const data = try allocator.alloc(u8, 131073);
    defer allocator.free(data);
    const encoded = try allocator.alloc(u8, try bound(data.len));
    defer allocator.free(encoded);
    const output = try allocator.alloc(u8, data.len + 2);
    defer allocator.free(output);
    for (0..3) |pattern| {
        for (data, 0..) |*byte, i| byte.* = switch (pattern) {
            0 => @intCast(i % 19),
            1 => @truncate((i *% 123457 +% (i >> 4)) >> 5),
            else => 0,
        };
        inline for (
            [_]Compression{
                .{ .level = 0 },
                .{ .strategy = .huffman_only },
                .{ .level = 3 },
                .{ .level = 6 },
                .{ .level = 9 },
                .{ .level = 7, .offline_pricing = .reduced },
                .{ .level = 8, .offline_pricing = .reduced },
                .{ .level = 9, .offline_pricing = .reduced },
                .{ .level = 7, .offline_pricing = .maximum_lengths },
                .{ .level = 8, .offline_pricing = .maximum_lengths },
                .{ .level = 9, .offline_pricing = .maximum_lengths },
                .{ .level = 7, .offline_refinement = .early },
                .{ .level = 8, .offline_pricing = .reduced, .offline_refinement = .early },
                .{ .level = 9, .offline_pricing = .maximum_lengths, .offline_refinement = .early },
            },
        ) |compression| {
            @memset(output, 0xa5);
            const result = try into(
                data,
                encoded,
                encoder_workspace,
                .{ .compression = compression },
            );
            const recovered = try test_decoding.decode.into(
                result,
                output[1 .. data.len + 1],
                .{ .workspace = decoder_workspace },
                .{},
            );
            try std.testing.expectEqual(data.len, recovered.produced);
            try std.testing.expectEqual(result.len, recovered.consumed);
            try std.testing.expectEqualSlices(u8, data, output[1 .. data.len + 1]);
            try std.testing.expectEqual(0xa5, output[0]);
            try std.testing.expectEqual(0xa5, output[data.len + 1]);
        }
    }
}
