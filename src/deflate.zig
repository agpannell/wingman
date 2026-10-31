//! Encode and decode raw RFC 1951 DEFLATE streams, including stored, fixed-Huffman and
//! dynamic-Huffman blocks. Raw streams carry neither an integrity checksum nor a decoded-size
//! field. A zlib or gzip stream adds its own framing and integrity check; this library handles only
//! the enclosed raw DEFLATE stream.
//!
//! ## Decoding
//!
//! `decode` accepts `DecodeStorage` and `DecodeOptions`. Output is bounded by default; select
//! `.output_size = .exact` to require the destination's full extent. Trailing bytes remain
//! unconsumed unless `.trailing_data = .reject`. Optional dictionaries use `options.dictionary` and
//! require an additional history reservation. Ordinary calls need only `DecoderWorkspace`.
//!
//! `Decoder.reset` borrows `StreamStorage` with decoding tables and 32 KiB of history, plus
//! `StreamDecodeOptions`. Its `step` method reports input/output progress and the next resource.
//! Raw streams carry no dictionary identity; the enclosing format must select matching bytes.
//!
//! ## Encoding
//!
//! Reserve `encodeBound(source.len)` output capacity and an `EncoderWorkspace`, then call `encode`.
//! Optional dictionary bytes are copied from `EncodeOptions.dictionary` during setup. `Encoder`
//! supports fragmented input with `process`, `flush`, `full_flush` and `finish` actions. The
//! default `EncodeProfile.offline` spends more work on compressed size; other profiles reduce
//! search effort. Stored encoding adds framing without compressing the payload. Complete stored
//! finishes write directly to the destination when it fits; fragmented calls use the same bounded
//! workspace. Every profile still requires an `EncoderWorkspace`.
//!
//! Compressed profiles compare exact stored, fixed and dynamic block sizes. Dynamic headers
//! describe code widths with literals and repeat codes; each trial price table selects a cheapest
//! legal sequence with deterministic ties. Work allowances retain their algorithmic charges when
//! range minima accelerate the repeat search. Identical consecutive trials reuse the remaining
//! trials within that header computation, charging their full work. A smaller allowance executes
//! the trials to preserve partial counters and refusal.
//!
//! Offline parsing prices paths through literals and matches, trying up to eight codebook updates.
//! Equal-price length ranges share an exact suffix minimum, retaining the shortest match on ties.
//! When code widths stabilize, later passes reuse the same parse. Their logical work is still
//! charged; a smaller allowance executes the passes to preserve partial counters and refusal.
//!
//! ## Storage and failure
//!
//! Construct large workspaces directly at their final addresses with `create(allocator)` or
//! retained typed storage. Destroy allocated workspaces with the same allocator. Decoding and
//! encoding use separate workspace types. Complete-buffer calls retain no buffer pointers and allow
//! workspace reuse after success or failure. Streaming owners keep their reservations exclusively
//! borrowed until reset or end of use; reset after any step error.
//!
//! Source, output and workspace must be disjoint. Exact, unaligned byte slices need no padding.
//! Codec calls allocate nothing and perform no I/O. Failures may change output and scratch; use
//! decoded bytes only after completion and any required integrity check.
//!
//! Format: https://www.rfc-editor.org/rfc/rfc1951

const std = @import("std");

const decoding = @import("deflate/decode.zig");
const encoding = @import("deflate/encode.zig");
const format = @import("deflate/format.zig");
const stream = @import("deflate/stream.zig");

// Decoding mechanisms studied in libdeflate and zlib-ng:
// https://github.com/ebiggers/libdeflate/blob/92e6a0db9fa848d742f9eb286c92afc60f2c3dda/lib/decompress_template.h
// https://github.com/zlib-ng/zlib-ng/blob/12731092979c6d07f42da27da673a9f6c7b13586/chunkset_tpl.h

pub const Error = format.Error;
pub const DecodeResult = format.DecodeResult;
pub const DecoderWorkspace = decoding.DecoderWorkspace;
pub const DecodeOptions = format.DecodeOptions;
pub const StreamDecodeOptions = format.StreamDecodeOptions;
pub const DecodeStorage = decoding.DecodeStorage;
pub const StreamStorage = stream.StreamStorage;
pub const OutputSize = format.OutputSize;
pub const TrailingData = format.TrailingData;
pub const decode = decoding.decode;
pub const Input = stream.Input;
pub const DecodeStatus = stream.DecodeStatus;
pub const DecodeProgress = stream.DecodeProgress;
pub const DecodeLimits = stream.DecodeLimits;
pub const DecodeError = stream.DecodeError;
pub const Decoder = stream.Decoder;

pub const EncodeError = encoding.EncodeError;
pub const EncodeProfile = encoding.EncodeProfile;
pub const EncodeLimits = encoding.EncodeLimits;
pub const EncodeOptions = encoding.EncodeOptions;
pub const EncodeAction = encoding.EncodeAction;
pub const EncodeStatus = encoding.EncodeStatus;
pub const EncodeProgress = encoding.EncodeProgress;
pub const EncodeStats = encoding.EncodeStats;
pub const EncoderWorkspace = encoding.EncoderWorkspace;
pub const Encoder = encoding.Encoder;
pub const encodeBound = encoding.encodeBound;
pub const encode = encoding.encode;

test "native encoder profiles preserve independent RFC wires and exact recovery" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try EncoderWorkspace.create(allocator);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try DecoderWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    var wire: [4096]u8 = undefined;

    // RFC 1951 Sections 3.2.4 and 3.2.6, independently derived: stored A, empty fixed EOB and fixed
    // literal A followed by EOB.
    const stored_a = [_]u8{ 0x01, 0x01, 0x00, 0xfe, 0xff, 0x41 };
    const empty_fixed = [_]u8{ 0x03, 0x00 };
    const fixed_a = [_]u8{ 0x73, 0x04, 0x00 };
    const stored = try encode("A", &wire, encoder_workspace, .{ .profile = .stored });
    try std.testing.expectEqualSlices(u8, &stored_a, stored);
    try std.testing.expectEqualSlices(
        u8,
        &empty_fixed,
        try encode("", &wire, encoder_workspace, .{}),
    );
    try std.testing.expectEqualSlices(u8, &fixed_a, try encode("A", &wire, encoder_workspace, .{}));

    const data = try allocator.alloc(u8, 131073);
    defer allocator.free(data);
    const encoded = try allocator.alloc(u8, try encodeBound(data.len));
    defer allocator.free(encoded);
    const output = try allocator.alloc(u8, data.len + 2);
    defer allocator.free(output);
    for (0..3) |pattern| {
        for (data, 0..) |*byte, i| byte.* = switch (pattern) {
            0 => @intCast(i % 19),
            1 => @truncate((i *% 123457 +% (i >> 4)) >> 5),
            else => 0,
        };
        inline for (std.meta.tags(EncodeProfile)) |profile| {
            @memset(output, 0xa5);
            const result = try encode(data, encoded, encoder_workspace, .{ .profile = profile });
            const recovered = try decode(
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

test "encoder retires byte fragments retains dictionaries and distinguishes flush actions" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try EncoderWorkspace.create(allocator);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try DecoderWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    const source =
        "shared history words shared history words!shared history words shared history words!";
    const dictionary = "a dictionary of shared history words ";
    var history: [32768]u8 = undefined;
    var encoder: Encoder = undefined;
    var wire: [512]u8 = undefined;
    var output: [source.len]u8 = undefined;
    inline for (.{ EncodeAction.flush, EncodeAction.full_flush }) |flush| {
        inline for (std.meta.tags(EncodeProfile)) |profile| {
            try encoder.reset(encoder_workspace, .{ .profile = profile });
            try encoder.setDictionary(dictionary);
            var read: usize = 0;
            var written: usize = 0;
            var flushed = false;
            while (true) {
                const end = if (flushed) source.len else source.len / 2;
                const length = @min(1, end - read);
                var fragment: [1]u8 = undefined;
                if (length != 0) fragment[0] = source[read];
                var result: [1]u8 = undefined;
                const action: EncodeAction = blk: {
                    if (read + length < end) break :blk .process;
                    if (flushed) break :blk .finish;
                    break :blk flush;
                };
                const progress = try encoder.step(fragment[0..length], &result, action);
                read += progress.consumed;
                @memset(&fragment, 0xa5);
                @memcpy(wire[written..][0..progress.produced], result[0..progress.produced]);
                written += progress.produced;
                @memset(&result, 0xa5);
                if (progress.status == .flushed) flushed = true;
                if (progress.status == .complete) break;
            }
            const recovered = try decode(
                wire[0..written],
                &output,
                .{ .workspace = decoder_workspace, .history = &history },
                .{ .dictionary = dictionary },
            );
            try std.testing.expectEqual(written, recovered.consumed);
            try std.testing.expectEqualStrings(source, &output);
            try std.testing.expectEqual(source.len, encoder.counts().input_bytes);
            try std.testing.expectEqual(written, encoder.counts().output_bytes);
            try std.testing.expectEqual(.complete, (try encoder.step("", &.{}, .finish)).status);
            try std.testing.expectError(error.InvalidState, encoder.step("x", &.{}, .finish));
            try std.testing.expectError(error.NeedReset, encoder.step("", &.{}, .finish));
        }
    }
}

test "encoder bounds limits overlap failure reset and clearing are explicit" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try EncoderWorkspace.create(allocator);
    defer encoder_workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    var wire: [128]u8 = @splat(0xa5);
    try std.testing.expectError(error.CounterOverflow, encodeBound(std.math.maxInt(usize)));
    try std.testing.expectError(
        error.InvalidOptions,
        encoder.reset(encoder_workspace, .{ .window_bytes = 1000 }),
    );
    try encoder.reset(encoder_workspace, .{ .limits = .{ .input_bytes = 2 } });
    try std.testing.expectError(error.LimitExceeded, encoder.step("abc", &wire, .finish));
    try std.testing.expectError(error.NeedReset, encoder.step("", &wire, .finish));
    try encoder.reset(encoder_workspace, .{ .limits = .{ .work_units = 0 } });
    try std.testing.expectError(error.LimitExceeded, encoder.step("abcabc", &wire, .finish));
    try encoder.reset(encoder_workspace, .{ .profile = .stored, .limits = .{ .output_bytes = 6 } });
    try std.testing.expectEqual(.complete, (try encoder.step("A", wire[1..7], .finish)).status);
    try std.testing.expectEqual(0xa5, wire[0]);
    try std.testing.expectEqual(0xa5, wire[7]);
    try encoder.reset(encoder_workspace, .{ .profile = .stored, .limits = .{ .output_bytes = 5 } });
    try std.testing.expectError(error.LimitExceeded, encoder.step("A", &wire, .finish));
    try encoder.reset(encoder_workspace, .{});
    try std.testing.expectError(error.StorageOverlap, encoder.step(wire[0..3], &wire, .finish));
    try encoder.reset(encoder_workspace, .{});
    try std.testing.expectEqual(.need_input, (try encoder.step("abc", &.{}, .process)).status);
    try std.testing.expectError(error.InvalidState, encoder.setDictionary("dictionary"));
    encoder_workspace.clear();
    for (std.mem.asBytes(encoder_workspace)) |byte| try std.testing.expectEqual(0, byte);
}

test {
    _ = @import("deflate/bits.zig");
    _ = encoding;
    _ = @import("deflate/fixtures.zig");
    _ = @import("deflate/huffman.zig");
    _ = @import("deflate/match.zig");
    _ = decoding;
    _ = stream;
}

test "complete decode separates extent trailing data limits and dictionary storage" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // Independent RFC stored hello, then a following application record.
    const wire = [_]u8{ 1, 5, 0, 250, 255, 'h', 'e', 'l', 'l', 'o', 'n', 'e', 'x', 't' };
    const buffers: DecodeStorage = .{ .workspace = workspace };
    var output: [8]u8 = @splat(0xa5);
    const result = try decode(&wire, &output, buffers, .{});
    try std.testing.expectEqual(@as(usize, 10), result.consumed);
    try std.testing.expectEqualStrings("hello", output[0..result.produced]);
    try std.testing.expect(std.mem.allEqual(u8, output[5..], 0xa5));
    try std.testing.expectError(
        error.InvalidStream,
        decode(&wire, &output, buffers, .{ .output_size = .exact }),
    );
    _ = try decode(&wire, output[0..5], buffers, .{ .output_size = .exact });
    try std.testing.expectError(
        error.InvalidStream,
        decode(&wire, output[0..5], buffers, .{ .trailing_data = .reject }),
    );
    _ = try decode(
        wire[0..10],
        output[0..5],
        buffers,
        .{ .output_size = .exact, .trailing_data = .reject },
    );
    _ = try decode(
        &wire,
        &output,
        buffers,
        .{ .limits = .{ .input_bytes = 10, .output_bytes = 5, .work_units = 15 } },
    );
    try std.testing.expectError(
        error.LimitExceeded,
        decode(&wire, &output, buffers, .{ .limits = .{ .input_bytes = 9 } }),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        decode(&wire, &output, buffers, .{ .limits = .{ .output_bytes = 4 } }),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        decode(&wire, &output, buffers, .{ .limits = .{ .work_units = 14 } }),
    );
    @memset(&output, 0xa5);
    try std.testing.expectError(
        error.InvalidOptions,
        decode(&wire, &output, buffers, .{ .dictionary = "preset" }),
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
    var decoder: Decoder = undefined;
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var dictionary = [_]u8{'A'};
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .dictionary = &dictionary },
    );
    dictionary[0] = 'Z';
    // Independent fixed block: a length-three/distance-one match using the copied preset A.
    const restored = try decoder.step(.{ .bytes = &.{
        0x03, 0x02,
        0x00,
    }, .final = true }, output[0..3]);
    try std.testing.expectEqual(.complete, restored.status);
    try std.testing.expectEqualStrings("AAA", output[0..3]);
}
