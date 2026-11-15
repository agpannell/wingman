//! Complete-buffer DEFLATE admission and result publication. Ordinary calls use output as history;
//! dictionary calls delegate to a fresh streaming worker with independent caller-owned history.
//! Block execution owns optimized decoding, while this owner enforces output extent and limits.

const std = @import("std");
const BitReader = @import("BitReader.zig");
const fixture_data = @import("decode_fixtures.zig");
const huffman = @import("huffman.zig");
const DecodeWorkspace = @import("DecodeWorkspace.zig");
pub const StreamDecoder = @import("StreamDecoder.zig");
const block_decoding = @import("block_decode.zig");
const header_decoding = @import("dynamic_header_decode.zig");
const test_packed_huffman = @import("packed_huffman.zig");
const test_match_copy = @import("match_copy.zig");
const byte_ranges = @import("../common/byte_ranges.zig");
pub const Limits = @import("DecodeLimits.zig");

pub const Workspace = DecodeWorkspace;
pub const Result = block_decoding.Result;

/// Required restored extent for one complete decode; independent of trailing input policy.
pub const OutputSize = enum { bounded, exact };

/// Whether bytes beyond the selected stream may remain unconsumed.
pub const TrailingData = enum { allow, reject };

/// Policy for one complete raw stream. Optional dictionary bytes are borrowed until return;
/// dictionary decoding also requires a history reservation in `Storage`.
pub const Options = struct {
    /// Maximum backward match distance in 1..32768. Stored bytes/literals require no history.
    window_bytes: usize = 32768,
    /// Preset history selected by the enclosing format; raw streams carry no dictionary identity.
    dictionary: ?[]const u8 = null,
    /// Bounded preserves the unused output suffix. Exact requires the entire destination and
    /// reserves that extent against output and work limits even if the stream ends short.
    output_size: OutputSize = .bounded,
    /// Allow preserves following application bytes; reject requires complete source consumption.
    trailing_data: TrailingData = .allow,
    /// Input/output/work admission for this call.
    limits: Limits = .{},
};

const fixed = huffman.fixed;

const frozen_fixtures = fixture_data.frozen_fixtures;
const raw_window_boundary = fixture_data.raw_window_boundary;

/// Mutable storage for a complete decode. Ordinary streams use only the table reservation;
/// supplying a dictionary additionally requires independent history. No allocator is retained.
pub const Storage = struct {
    /// Address-stable decoding tables, reusable after either success or failure.
    workspace: *DecodeWorkspace,
    /// Required only when `Options.dictionary` is non-null.
    history: ?*[32768]u8 = null,
};

/// Failures return no accepted result. Direct incomplete input can be InvalidStream; dictionary
/// decoding can report Truncated. OutputSizeMismatch means the final block ended before an exact
/// destination was filled, before trailing-data acceptance or any enclosing integrity check.
pub const Error = error{
    InvalidStream,
    InvalidOptions,
    LimitExceeded,
    OutputTooSmall,
    StorageOverlap,
    Truncated,
    CounterOverflow,
    OutputSizeMismatch,
};

/// Decodes one complete raw stream without allocating or retaining buffer pointers. Output extent,
/// trailing input and cumulative admission are independent selections. Dictionary-free calls retain
/// direct-buffer kernels and require no separate history. Missing dictionary history or an invalid
/// window returns `InvalidOptions`. Exact output reserves the entire destination against output and
/// work limits even if the stream ends short. Work admission precedes `OutputSizeMismatch`, which
/// precedes rejected trailing data. A short exact result is an error and may change any part of the
/// unpublished output. If input ends before EOB, direct decoding can report `InvalidStream` and
/// dictionary decoding can report `Truncated`; an earlier admission failure takes precedence.
pub fn into(source: []const u8, output: []u8, storage: Storage, options: Options) Error!Result {
    const limits = options.limits;
    if (options.window_bytes == 0 or options.window_bytes > 32768) return error.InvalidOptions;
    const result = if (options.dictionary) |dictionary| blk: {
        const history = storage.history orelse return error.InvalidOptions;
        // Reset copies dictionary history. Admit caller buffers first so an overlap refusal
        // preserves source, output and both reservations.
        const state = std.mem.asBytes(storage.workspace);
        try disjoint(source, output);
        try disjoint(source, state);
        try disjoint(output, state);
        try disjoint(source, history);
        try disjoint(output, history);
        var decoder: StreamDecoder = undefined;
        // Reset checks these incoming overlaps before it changes the owner or history. Preserve
        // that priority before testing the exact extent, without rejecting dictionary/input
        // aliases.
        const owner = std.mem.asBytes(&decoder);
        try disjoint(owner, state);
        try disjoint(owner, history);
        try disjoint(state, history);
        try disjoint(dictionary, owner);
        try disjoint(dictionary, state);
        try disjoint(dictionary, history);
        // Exact admits the requested extent without charging it as additional work.
        if (options.output_size == .exact and output.len > @min(
            limits.output_bytes,
            limits.work_units,
        )) return error.LimitExceeded;
        decoder.reset(
            .{ .workspace = storage.workspace, .history = history },
            .{ .window_bytes = options.window_bytes, .dictionary = dictionary, .limits = limits },
        ) catch |err| return completeFailure(err);
        const progress = decoder.step(
            .{ .bytes = source, .final = true },
            output,
        ) catch |err| return completeFailure(err);
        if (progress.status == .need_output) return error.OutputTooSmall;
        break :blk Result{ .consumed = progress.consumed, .produced = progress.produced };
    } else blk: {
        const workspace = storage.workspace;
        try disjoint(source, output);
        try disjoint(source, std.mem.asBytes(workspace));
        try disjoint(output, std.mem.asBytes(workspace));
        // Cap each axis before decoding. Work counts are checked before result publication; errors
        // expose no accepted counts and may have modified only the admitted output prefix.
        const input_count: usize = @intCast(
            @min(source.len, limits.input_bytes, limits.work_units),
        );
        const output_count: usize = @intCast(
            @min(output.len, limits.output_bytes, limits.work_units),
        );
        if (options.output_size == .exact and output_count < output.len) return error.LimitExceeded;
        const decoded = if (options.output_size == .exact) block_decoding.decode(
            true,
            source[0..input_count],
            output[0..output_count],
            storage.workspace,
            options.window_bytes,
        ) else block_decoding.decode(
            false,
            source[0..input_count],
            output[0..output_count],
            storage.workspace,
            options.window_bytes,
        );
        break :blk decoded catch |err| switch (err) {
            error.InvalidStream => {
                if (input_count < source.len) return error.LimitExceeded;
                return err;
            },
            error.OutputTooSmall => {
                if (output_count < output.len) return error.LimitExceeded;
                return err;
            },
            else => return err,
        };
    };
    if (result.consumed > limits.input_bytes or result.produced > limits.output_bytes)
        return error.LimitExceeded;
    if (result.consumed > limits.work_units or result.produced > limits.work_units - result
        .consumed) return error.LimitExceeded;
    if (options.output_size == .exact and result.produced != output.len)
        return error.OutputSizeMismatch;
    if (options.trailing_data == .reject and result.consumed != source.len)
        return error.InvalidStream;
    return result;
}

test into {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);

    // A stored raw stream containing "hello", followed by the next application record.
    const source = [_]u8{
        0x01, 0x05, 0x00, 0xfa, 0xff, 0x68, 0x65, 0x6c,
        0x6c, 0x6f, 0x6e, 0x65, 0x78, 0x74,
    };
    var output: [32]u8 = undefined;
    const result = try into(&source, &output, .{ .workspace = workspace }, .{});
    const payload = .{ .decoded = output[0..result.produced], .next = source[result.consumed..] };

    try std.testing.expectEqualStrings("hello", payload.decoded);
    try std.testing.expectEqualStrings("next", payload.next);
}

test "exact-size decoding verifies full extent before raw success" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const source = &frozen_fixtures.literal_length_prefixes_deflate;
    const expected = &frozen_fixtures.literal_length_prefixes_golden;
    const input = try allocator.alloc(u8, source.len + 32);
    defer allocator.free(input);
    @memcpy(input[0..source.len], source);
    @memset(input[source.len..], 0x5a);
    const backing = try allocator.alloc(u8, expected.len + 96);
    defer allocator.free(backing);
    // Independent 197-byte RFC wire and 606-byte golden contain short/long matches at distance 32;
    // this unbatched route retains precise copies. Existing Python zlib 1.3.2 facts validate bytes,
    // not this decoder's copying choices.
    var bits = BitReader{ .source = source };
    try std.testing.expectEqual(1, try bits.take(1));
    try std.testing.expectEqual(2, try bits.take(2));
    try std.testing.expectEqual(
        header_decoding.DecodePlan.match_payload,
        try header_decoding.read(false, false, &bits, workspace),
    );
    for (0..33) |alignment| {
        for (0..expected.len + 33) |capacity| {
            @memset(backing, 0xa5);
            const output = backing[alignment..][0..capacity];
            if (capacity < expected.len) {
                try std.testing.expectError(
                    error.OutputTooSmall,
                    into(input, output, .{ .workspace = workspace }, .{ .output_size = .exact }),
                );
            } else if (capacity > expected.len) {
                try std.testing.expectError(
                    error.OutputSizeMismatch,
                    into(input, output, .{ .workspace = workspace }, .{ .output_size = .exact }),
                );
            } else {
                const result = try into(
                    input,
                    output,
                    .{ .workspace = workspace },
                    .{ .output_size = .exact },
                );
                try std.testing.expectEqual(source.len, result.consumed);
                try std.testing.expectEqual(expected.len, result.produced);
                try std.testing.expectEqualSlices(u8, expected, output);
            }
            for (backing[0..alignment]) |byte| try std.testing.expectEqual(0xa5, byte);
            for (backing[alignment + capacity ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
    }
    for (0..source.len) |cut| {
        @memset(backing, 0xa5);
        try std.testing.expectError(
            error.InvalidStream,
            into(
                source[0..cut],
                backing[0..expected.len],
                .{ .workspace = workspace },
                .{ .output_size = .exact },
            ),
        );
        for (backing[expected.len..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
    const empty = [_]u8{ 0x03, 0x00 };
    try std.testing.expectEqual(
        @as(usize, 0),
        (try into(&empty, &.{}, .{ .workspace = workspace }, .{ .output_size = .exact })).produced,
    );
    try std.testing.expectError(
        error.OutputSizeMismatch,
        into(&empty, backing[0..1], .{ .workspace = workspace }, .{ .output_size = .exact }),
    );
}

test "raw admission checks storage and window limits before decoding" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const state = std.mem.asBytes(workspace);
    var source = [_]u8{ 1, 0, 0, 255, 255 };
    const original = source;
    var output: [304]u8 = undefined;
    inline for (.{ OutputSize.bounded, OutputSize.exact }) |extent| {
        @memset(state, 0x6d);
        @memset(&output, 0xa5);
        for ([_]usize{ 0, 32769, std.math.maxInt(usize) }) |window| {
            try std.testing.expectError(
                error.InvalidOptions,
                into(
                    &source,
                    &output,
                    .{ .workspace = workspace },
                    .{ .window_bytes = window, .output_size = extent },
                ),
            );
        }
        try std.testing.expect(std.mem.allEqual(u8, state, 0x6d));
        try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
        try std.testing.expectError(
            error.StorageOverlap,
            into(&source, source[0..1], .{ .workspace = workspace }, .{ .output_size = extent }),
        );
        try std.testing.expectError(
            error.StorageOverlap,
            into(&source, state, .{ .workspace = workspace }, .{ .output_size = extent }),
        );
        try std.testing.expectEqualSlices(u8, &original, &source);
        try std.testing.expect(std.mem.allEqual(u8, state, 0x6d));
        @memcpy(state[0..source.len], &source);
        try std.testing.expectError(
            error.StorageOverlap,
            into(
                state[0..source.len],
                &output,
                .{ .workspace = workspace },
                .{ .output_size = extent },
            ),
        );
        try std.testing.expectEqualSlices(u8, &source, state[0..source.len]);
        try std.testing.expect(std.mem.allEqual(u8, state[source.len..], 0x6d));
        try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));

        // Independent RFC fixed wire: A, length-three/distance-one, then EOB. Python zlib 1.3.2
        // verifies the complete four-byte result.
        const result = try into(
            &[_]u8{ 0x73, 0x04, 0x02, 0x00 },
            output[0..4],
            .{ .workspace = workspace },
            .{ .window_bytes = 1, .output_size = extent },
        );
        try std.testing.expectEqual(4, result.consumed);
        try std.testing.expectEqual(4, result.produced);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x41, 0x41, 0x41 }, output[0..4]);
        try std.testing.expect(std.mem.allEqual(u8, output[4..], 0xa5));

        // The independently authored window wire supplies 300 literals before a length-three match
        // at distance 256. Test both API size policies.
        const bytes = &raw_window_boundary;
        @memset(&output, 0xa5);
        try std.testing.expectEqual(
            303,
            (try into(
                bytes,
                output[0..303],
                .{ .workspace = workspace },
                .{ .window_bytes = 256, .output_size = extent },
            )).produced,
        );
        try std.testing.expect(std.mem.allEqual(u8, output[0..303], 'A'));
        try std.testing.expectEqual(0xa5, output[303]);
        @memset(&output, 0xa5);
        try std.testing.expectError(
            error.InvalidStream,
            into(
                bytes,
                output[0..303],
                .{ .workspace = workspace },
                .{ .window_bytes = 255, .output_size = extent },
            ),
        );
        try std.testing.expect(std.mem.allEqual(u8, output[300..], 0xa5));
    }
}

test "dictionary decode admission preserves buffers before any history copy" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const state = std.mem.asBytes(workspace);
    // Independent RFC fixed block: length 3, distance 1 and EOB, using preset history A.
    const original = [_]u8{ 0x03, 0x02, 0x00 };
    var output: [3]u8 = undefined;
    inline for (.{ OutputSize.bounded, OutputSize.exact }) |extent| {
        for (0..5) |overlap| {
            @memset(state, 0x6d);
            @memset(history, 0xa5);
            @memset(&output, 0xc7);
            var input = original;
            const source: []const u8 = switch (overlap) {
                1 => blk: {
                    @memcpy(state[0..original.len], &original);
                    break :blk state[0..original.len];
                },
                3 => blk: {
                    @memcpy(history[0..original.len], &original);
                    break :blk history[0..original.len];
                },
                else => &input,
            };
            const target: []u8 = switch (overlap) {
                0 => &input,
                2 => state[0..original.len],
                4 => history[0..original.len],
                else => &output,
            };
            try std.testing.expectError(
                error.StorageOverlap,
                into(
                    source,
                    target,
                    .{ .workspace = workspace, .history = history },
                    .{ .dictionary = "A", .output_size = extent },
                ),
            );
            try std.testing.expectEqualSlices(u8, &original, &input);
            try std.testing.expect(std.mem.allEqual(u8, &output, 0xc7));
            if (overlap == 1) {
                try std.testing.expectEqualSlices(u8, &original, state[0..original.len]);
                try std.testing.expect(std.mem.allEqual(u8, state[original.len..], 0x6d));
            } else try std.testing.expect(std.mem.allEqual(u8, state, 0x6d));
            if (overlap == 3) {
                try std.testing.expectEqualSlices(u8, &original, history[0..original.len]);
                try std.testing.expect(std.mem.allEqual(u8, history[original.len..], 0xa5));
            } else try std.testing.expect(std.mem.allEqual(u8, history, 0xa5));
        }
    }
}

test "exact short output admits limits before reporting raw extent" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    // Independent RFC wires for one literal and a separate application byte after the stream.
    const fixed_wire = [_]u8{ 0x73, 0x04, 0x00, 0xee };
    const stored = [_]u8{ 0x01, 0x01, 0x00, 0xfe, 0xff, 'A', 0xee };
    const dictionaries = [_]?[]const u8{ null, "", "dictionary history" };
    for ([_][]const u8{ &fixed_wire, &stored }) |source| {
        const end = source.len - 1;
        for (dictionaries) |dictionary| {
            const storage: Storage = .{ .workspace = workspace, .history = history };
            var backing: [4]u8 = @splat(0xa5);
            var options: Options = .{ .dictionary = dictionary, .output_size = .exact };
            // Exact reserves both destination bytes even though this stream restores only one.
            for ([_]u64{ 0, 1, 2, 3 }) |limit| {
                options.limits = .{ .output_bytes = limit };
                @memset(&backing, 0xa5);
                const result = into(source[0..end], backing[1..3], storage, options);
                try std.testing.expectError(
                    if (limit < 2) error.LimitExceeded else error.OutputSizeMismatch,
                    result,
                );
                try std.testing.expectEqual(@as(u8, 0xa5), backing[0]);
                try std.testing.expectEqual(@as(u8, 0xa5), backing[3]);
            }
            // Work counts encoded and restored bytes, not trailing application bytes.
            for ([_]u64{ 2, end, end + 1, end + 2 }) |limit| {
                options.limits = .{ .work_units = limit };
                const result = into(source[0..end], backing[1..3], storage, options);
                try std.testing.expectError(
                    if (limit < end + 1) error.LimitExceeded else error.OutputSizeMismatch,
                    result,
                );
            }
            options.limits = .{ .input_bytes = end - 1 };
            try std.testing.expectError(
                error.LimitExceeded,
                into(source, backing[1..3], storage, options),
            );
            options.limits = .{ .input_bytes = end };
            options.trailing_data = .allow;
            try std.testing.expectError(
                error.OutputSizeMismatch,
                into(source, backing[1..3], storage, options),
            );
            options.trailing_data = .reject;
            try std.testing.expectError(
                error.OutputSizeMismatch,
                into(source, backing[1..3], storage, options),
            );
            // Once exact output is filled, rejected following input remains an InvalidStream.
            try std.testing.expectError(
                error.InvalidStream,
                into(source, backing[1..2], storage, options),
            );
            options.trailing_data = .allow;
            const result = try into(source, backing[1..2], storage, options);
            try std.testing.expectEqual(end, result.consumed);
            try std.testing.expectEqual(@as(u8, 'A'), backing[1]);
        }
    }
}

test "exact dictionary admission preserves overlap priority and borrowed input" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const source = [_]u8{ 0x73, 0x04, 0x00 };
    var output: [4]u8 = @splat(0xa5);
    const options: Options = .{
        .dictionary = history[0..2],
        .output_size = .exact,
        .limits = .{ .output_bytes = 0 },
    };
    @memset(history, 0x4b);
    // A dictionary overlapping incoming history is refused before extent admission or reset copy.
    try std.testing.expectError(
        error.StorageOverlap,
        into(&source, output[0..2], .{ .workspace = workspace, .history = history }, options),
    );
    try std.testing.expect(std.mem.allEqual(u8, history, 0x4b));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
    const workspace_bytes = std.mem.asBytes(workspace);
    workspace_bytes[0] = 0x5a;
    var workspace_alias = options;
    workspace_alias.dictionary = workspace_bytes[0..1];
    try std.testing.expectError(
        error.StorageOverlap,
        into(
            &source,
            output[0..2],
            .{ .workspace = workspace, .history = history },
            workspace_alias,
        ),
    );
    try std.testing.expectEqual(@as(u8, 0x5a), workspace_bytes[0]);
    const shared = try allocator.alignedAlloc(
        u8,
        .of(DecodeWorkspace),
        @sizeOf(DecodeWorkspace) + 32768,
    );
    defer allocator.free(shared);
    const overlapping_workspace: *DecodeWorkspace = @ptrCast(@alignCast(shared.ptr));
    const overlapping_history: *[32768]u8 = @ptrCast(shared.ptr);
    var reservation_alias = options;
    reservation_alias.dictionary = "";
    try std.testing.expectError(
        error.StorageOverlap,
        into(
            &source,
            output[0..2],
            .{ .workspace = overlapping_workspace, .history = overlapping_history },
            reservation_alias,
        ),
    );

    // Dictionary bytes can still borrow either the source or the destination: reset copies them
    // before the encoded input or output is used, with independent mutable reservations.
    for ([_][]const u8{ source[0..1], output[0..1] }) |dictionary| {
        const selection: Options = .{ .dictionary = dictionary, .output_size = .exact };
        try std.testing.expectError(
            error.OutputSizeMismatch,
            into(&source, output[0..2], .{ .workspace = workspace, .history = history }, selection),
        );
    }
    // Bounded decoding needs only the actual restored byte; exact reserves both requested bytes.
    const bounded: Options = .{ .dictionary = "", .limits = .{ .output_bytes = 1 } };
    const result = try into(
        &source,
        output[0..2],
        .{ .workspace = workspace, .history = history },
        bounded,
    );
    try std.testing.expectEqual(@as(usize, 1), result.produced);
    try std.testing.expectEqual(@as(u8, 'A'), output[0]);
    for ([_]?[]const u8{ null, "" }) |dictionary| {
        try std.testing.expectError(
            if (dictionary == null) error.InvalidStream else error.Truncated,
            into(
                source[0..1],
                output[0..2],
                .{ .workspace = workspace, .history = history },
                .{ .dictionary = dictionary, .output_size = .exact },
            ),
        );
        try std.testing.expectError(
            error.OutputTooSmall,
            into(
                &source,
                output[0..0],
                .{ .workspace = workspace, .history = history },
                .{ .dictionary = dictionary, .output_size = .exact },
            ),
        );
    }
}

/// Reject overlapping source/output/reservation spans using the shared address-only predicate.
fn disjoint(first: []const u8, second: []const u8) error{StorageOverlap}!void {
    if (byte_ranges.overlaps(first, second)) return error.StorageOverlap;
}

// The dictionary adapter resets a fresh worker, attaches history during reset and steps exactly
// once with final input. It cannot encounter a poisoned worker or a second setup/EOF operation.
fn completeFailure(failure: StreamDecoder.Error) Error {
    return switch (failure) {
        error.NeedReset, error.InvalidState => unreachable,
        else => |err| err,
    };
}

test "complete decode separates extent trailing data limits and dictionary storage" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    // Independent RFC stored hello, then a following application record.
    const wire = [_]u8{ 1, 5, 0, 250, 255, 'h', 'e', 'l', 'l', 'o', 'n', 'e', 'x', 't' };
    const buffers: Storage = .{ .workspace = workspace };
    var output: [8]u8 = @splat(0xa5);
    const result = try into(&wire, &output, buffers, .{});
    try std.testing.expectEqual(@as(usize, 10), result.consumed);
    try std.testing.expectEqualStrings("hello", output[0..result.produced]);
    try std.testing.expect(std.mem.allEqual(u8, output[5..], 0xa5));
    try std.testing.expectError(
        error.OutputSizeMismatch,
        into(&wire, &output, buffers, .{ .output_size = .exact }),
    );
    _ = try into(&wire, output[0..5], buffers, .{ .output_size = .exact });
    try std.testing.expectError(
        error.InvalidStream,
        into(&wire, output[0..5], buffers, .{ .trailing_data = .reject }),
    );
    _ = try into(
        wire[0..10],
        output[0..5],
        buffers,
        .{ .output_size = .exact, .trailing_data = .reject },
    );
    _ = try into(
        &wire,
        &output,
        buffers,
        .{ .limits = .{ .input_bytes = 10, .output_bytes = 5, .work_units = 15 } },
    );
    try std.testing.expectError(
        error.LimitExceeded,
        into(&wire, &output, buffers, .{ .limits = .{ .input_bytes = 9 } }),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        into(&wire, &output, buffers, .{ .limits = .{ .output_bytes = 4 } }),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        into(&wire, &output, buffers, .{ .limits = .{ .work_units = 14 } }),
    );
    @memset(&output, 0xa5);
    try std.testing.expectError(
        error.InvalidOptions,
        into(&wire, &output, buffers, .{ .dictionary = "preset" }),
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
    var decoder: StreamDecoder = undefined;
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var dictionary = [_]u8{'A'};
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .dictionary = &dictionary },
    );
    dictionary[0] = 'Z';
    // Independent fixed block: a length-three/distance-one match using the copied preset A.
    const restored = try decoder.step(
        .{ .bytes = &.{ 0x03, 0x02, 0x00 }, .final = true },
        output[0..3],
    );
    try std.testing.expectEqual(.complete, restored.status);
    try std.testing.expectEqualStrings("AAA", output[0..3]);
}

test {
    _ = BitReader;
    _ = Workspace;
    _ = StreamDecoder;
    _ = block_decoding;
    _ = header_decoding;
    _ = test_packed_huffman;
    _ = huffman;
    _ = test_match_copy;
    _ = fixture_data;
}
