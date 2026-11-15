//! Complete RFC 1950 decoding and destructive stored-block reader decoding. Success verifies
//! Adler-32; failures return no accepted result and may change unpublished output and scratch.

const builtin = @import("builtin");
const std = @import("std");
const adler32 = @import("../adler32.zig");
const deflate = @import("../deflate.zig");
const byte_ranges = @import("../common/byte_ranges.zig");
const format = @import("format.zig");
const fixture_data = @import("../deflate/decode_fixtures.zig");
const fixtures = @import("decode_fixtures.zig");
pub const StreamDecoder = @import("StreamDecoder.zig");

const overlaps = byte_ranges.overlaps;
const general_pairs = fixture_data.general_pairs;
const paired_dense = fixture_data.paired_dense;
const paired_literals = fixture_data.paired_literals;
const raw_fixtures = fixture_data.frozen_fixtures;
const wide_literals = fixture_data.wide_literals;
const FragmentReader = fixtures.FragmentReader;
const testZlibFrame = fixtures.testZlibFrame;
const zlib_fixture = fixtures.zlib_fixture;
const reader_stored = fixtures.reader_stored;
const frozen_fixtures = fixtures.frozen_fixtures;

pub const Result = deflate.decode.Result;
pub const Workspace = deflate.decode.Workspace;
pub const Storage = deflate.decode.Storage;
pub const Limits = deflate.decode.Limits;
pub const OutputSize = deflate.decode.OutputSize;
pub const TrailingData = deflate.decode.TrailingData;
pub const validateDictionaryFreeHeader = format.validateDictionaryFreeHeader;

/// Complete decoding failures return no accepted result. Malformed input, extent/trailing-data
/// rejection and failed Adler-32 use InvalidStream. Dictionary decoding can also end with Truncated
/// or WrongDictionary. Output and scratch may have changed before a failure.
pub const Error = error{
    InvalidStream,
    InvalidOptions,
    LimitExceeded,
    OutputTooSmall,
    StorageOverlap,
    WrongDictionary,
    Truncated,
    CounterOverflow,
};

/// Complete RFC 1950 admission. Dictionary identity covers the full supplied dictionary; decoding
/// copies only its reachable suffix into the optional history reservation.
pub const Options = struct {
    /// Maximum match distance, additionally bounded by the stream's declared window.
    window_bytes: usize = 32768,
    /// Null rejects dictionary-requiring streams; non-null requires Storage.history.
    dictionary: ?[]const u8 = null,
    /// Exact requires the restored size to equal the complete destination length.
    output_size: OutputSize = .bounded,
    /// Allow leaves following records unconsumed.
    trailing_data: TrailingData = .allow,
    /// Admission includes zlib framing and excludes dictionary bytes.
    limits: Limits = .{},
};

/// Decodes one complete zlib stream, verifying its window and Adler-32 trailer. Extent and
/// trailing-data policy are independent. Dictionary-free calls require no history reservation and
/// retain direct-buffer kernels. Source, destination and used reservations must be disjoint. Errors
/// publish no counts and may change output; calls allocate nothing and retain no input pointers.
pub fn into(source: []const u8, output: []u8, storage: Storage, options: Options) Error!Result {
    const limits = options.limits;
    if (options.window_bytes == 0 or options.window_bytes > 32768) return error.InvalidOptions;
    const result = if (options.dictionary) |dictionary| blk: {
        const history = storage.history orelse return error.InvalidOptions;
        var decoder: StreamDecoder = undefined;
        decoder.reset(
            .{ .workspace = storage.workspace, .history = history },
            .{ .window_bytes = options.window_bytes, .limits = limits },
        ) catch |err| return completeFailure(err);
        var progress = decoder.step(
            .{ .bytes = source, .final = true },
            output,
        ) catch |err| return completeFailure(err);
        var consumed = progress.consumed;
        if (progress.status == .need_dictionary) {
            decoder.setDictionary(dictionary) catch |err| return completeFailure(err);
            progress = decoder.step(
                .{ .bytes = source[consumed..], .final = true },
                output,
            ) catch |err| return completeFailure(err);
            consumed += progress.consumed;
        }
        if (progress.status == .need_output) return error.OutputTooSmall;
        break :blk Result{ .consumed = consumed, .produced = progress.produced };
    } else blk: {
        const workspace = storage.workspace;
        if (overlaps(source, output)) return error.StorageOverlap;
        if (overlaps(source, std.mem.asBytes(workspace))) return error.StorageOverlap;
        if (overlaps(output, std.mem.asBytes(workspace))) return error.StorageOverlap;
        const admitted: usize = @intCast(@min(source.len, limits.input_bytes, limits.work_units));
        break :blk decodeBuffer(
            source[0..admitted],
            output,
            storage.workspace,
            options,
        ) catch |err| switch (err) {
            error.InvalidStream => {
                if (admitted < source.len) return error.LimitExceeded;
                return err;
            },
            else => return err,
        };
    };
    if (result.consumed > limits.input_bytes or result.produced > limits.output_bytes)
        return error.LimitExceeded;
    if (result.consumed > limits.work_units or result.produced > limits.work_units - result
        .consumed) return error.LimitExceeded;
    if (options.output_size == .exact and result.produced != output.len) return error.InvalidStream;
    if (options.trailing_data == .reject and result.consumed != source.len)
        return error.InvalidStream;
    return result;
}

test into {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);

    // A zlib header, a stored DEFLATE block containing "hello", and its Adler-32 footer.
    const source = [_]u8{
        0x78, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff, 0x68,
        0x65, 0x6c, 0x6c, 0x6f, 0x06, 0x2c, 0x02, 0x15,
    };
    var output: [32]u8 = undefined;
    const result = try into(&source, &output, .{ .workspace = workspace }, .{});
    const payload = output[0..result.produced];

    try std.testing.expectEqual(source.len, result.consumed);
    try std.testing.expectEqualStrings("hello", payload);
}

fn decodeBuffer(
    source: []const u8,
    output: []u8,
    workspace: *Workspace,
    options: Options,
) Error!Result {
    if (source.len < 2) return error.InvalidStream;
    try validateDictionaryFreeHeader(source[0..2]);
    const window = @as(usize, 1) << @intCast(8 + (source[0] >> 4));
    const raw = deflate.decode.into(
        source[2..],
        output,
        .{ .workspace = workspace },
        .{
            .window_bytes = @min(window, options.window_bytes),
            .output_size = options.output_size,
            .limits = .{
                .output_bytes = options.limits.output_bytes,
                .work_units = options.limits.work_units,
            },
        },
    ) catch |err| switch (err) {
        // A short raw extent has not verified the zlib checksum or trailer.
        error.OutputSizeMismatch => return error.InvalidStream,
        else => |other| return other,
    };
    const footer = 2 + raw.consumed;
    if (source.len - footer < 4) return error.InvalidStream;
    const expected = std.mem.readInt(u32, source[footer..][0..4], .big);
    const checksum = @call(.always_inline, adler32.hash, .{output[0..raw.produced]});
    if (expected != checksum) return error.InvalidStream;
    return .{ .consumed = footer + 4, .produced = raw.produced };
}

/// Consumes a reader while attempting one stored-only zlib stream without allocating or reserving a
/// workspace. The reader, its borrowed bytes and output are disjoint. Reader storage may be empty;
/// small headers use bounded local bytes. Success checks Adler over produced output, returns its
/// exact stream boundary and leaves the output suffix and trailing input intact. Fixed/dynamic
/// blocks return null, possibly after consuming input and writing an output prefix. Recreate or
/// rewind the reader before falling back to a general decoder. Failures may also change
/// reader/output. Premature EOF is InvalidStream; transport ReadFailed remains distinct, and a
/// stored length exceeding output is OutputTooSmall.
pub fn consumeStoredReader(
    noalias reader: *std.Io.Reader,
    noalias output: []u8,
) error{ InvalidStream, OutputTooSmall, ReadFailed }!?Result {
    var header: [2]u8 = undefined;
    try readStoredBytes(reader, &header);
    try validateDictionaryFreeHeader(&header);
    var consumed: usize = header.len;
    var written: usize = 0;
    var block: [5]u8 = undefined;
    while (true) {
        try readStoredBytes(reader, block[0..1]);
        switch (block[0] & 6) {
            0 => {},
            2, 4 => return null,
            else => return error.InvalidStream,
        }
        try readStoredBytes(reader, block[1..]);
        const length = try storedLength(block[1..]);
        if (length > output.len - written) return error.OutputTooSmall;
        consumed = std.math.add(
            usize,
            consumed,
            block.len + length,
        ) catch return error.InvalidStream;
        try readStoredBytes(reader, output[written..][0..length]);
        written += length;
        if (block[0] & 1 != 0) break;
    }
    var footer: [4]u8 = undefined;
    try readStoredBytes(reader, &footer);
    const expected = std.mem.readInt(u32, &footer, .big);
    const checksum = @call(.always_inline, adler32.hash, .{output[0..written]});
    if (expected != checksum) return error.InvalidStream;
    consumed = std.math.add(usize, consumed, footer.len) catch return error.InvalidStream;
    return .{ .consumed = consumed, .produced = written };
}

fn readStoredBytes(
    reader: *std.Io.Reader,
    destination: []u8,
) error{ InvalidStream, ReadFailed }!void {
    reader.readSliceAll(destination) catch |err| switch (err) {
        error.EndOfStream => return error.InvalidStream,
        error.ReadFailed => return error.ReadFailed,
    };
}

fn storedLength(bytes: *const [4]u8) error{InvalidStream}!usize {
    const length = std.mem.readInt(u16, bytes[0..2], .little);
    const complement = std.mem.readInt(u16, bytes[2..4], .little);
    if (length != ~complement) return error.InvalidStream;
    return length;
}

test "zlib declared windows admit their boundary and reject farther whole-buffer matches" {
    const fixture = zlib_fixture;
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    var output: [307]u8 = @splat(0xa5);

    const boundary = try into(&fixture.at_boundary, &output, .{ .workspace = workspace }, .{});
    try std.testing.expectEqual(fixture.at_boundary.len, boundary.consumed);
    try std.testing.expectEqual(303, boundary.produced);
    for (output[0..303]) |byte| try std.testing.expectEqual('A', byte);
    for (output[303..]) |byte| try std.testing.expectEqual(0xa5, byte);

    const WindowWire = @TypeOf(fixture.beyond_window);
    const refused = [_]*const WindowWire{ &fixture.beyond_boundary, &fixture.beyond_window };
    for (refused) |source| {
        @memset(&output, 0xa5);
        try std.testing.expectError(
            error.InvalidStream,
            into(source, &output, .{ .workspace = workspace }, .{}),
        );
        for (output[300..]) |byte| try std.testing.expectEqual(0xa5, byte);

        // Reuse after refusal with independently stated valid larger-window headers.
        var admitted = source.*;
        for ([_][2]u8{ .{ 0x18, 0x19 }, .{ 0x78, 0x01 } }) |header| {
            @memcpy(admitted[0..2], &header);
            @memset(&output, 0xa5);
            const result = try into(&admitted, &output, .{ .workspace = workspace }, .{});
            try std.testing.expectEqual(admitted.len, result.consumed);
            try std.testing.expectEqual(303, result.produced);
            for (output[0..303]) |byte| try std.testing.expectEqual('A', byte);
            for (output[303..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
    }
}

test "zlib small windows preserve every admitted dynamic table layout" {
    const fixture = zlib_fixture;
    const paired = paired_literals;
    const dense = paired_dense;
    const general = general_pairs;
    const wide = wide_literals;
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const cases = [_]struct {
        source: []const u8,
        expected: []const u8,
    }{
        .{ .source = &fixture.ordinary_complete, .expected = "AABA" },
        .{ .source = &fixture.incomplete_eob, .expected = "" },
        .{ .source = &fixture.ordinary_payload_literals, .expected = &.{ 0, 1, 2, 0, 1, 2 } },
        .{ .source = paired.source, .expected = paired.expected },
        .{ .source = dense.source, .expected = dense.expected },
        .{ .source = general.source, .expected = general.expected },
        .{ .source = wide.source, .expected = &wide.expected },
        .{
            .source = &raw_fixtures.payload_literal_budget_deflate,
            .expected = &fixture.wide_literal_groups,
        },
    };
    for (cases) |case| {
        const source = try testZlibFrame(allocator, case.source, case.expected, .{ 0x08, 0x1d });
        defer allocator.free(source);
        const output = try allocator.alloc(u8, case.expected.len + 8);
        defer allocator.free(output);
        @memset(output, 0xa5);
        const result = try into(source, output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(source.len, result.consumed);
        try std.testing.expectEqual(case.expected.len, result.produced);
        try std.testing.expectEqualSlices(u8, case.expected, output[0..result.produced]);
        for (output[result.produced..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }

    // These independent payload wires each contain a distance-32768 match.
    const expected = try allocator.alloc(u8, 33042);
    defer allocator.free(expected);
    @memset(expected[0..32768], 7);
    expected[32768] = 1;
    @memset(expected[32769..33026], 7);
    @memset(expected[33026..], 0);
    const output = try allocator.alloc(u8, expected.len + 8);
    defer allocator.free(output);
    for (
        [_][]const u8{ &raw_fixtures.payload_ordinary_deflate, &raw_fixtures.payload_wide_deflate },
    ) |raw| {
        const refused = try testZlibFrame(allocator, raw, expected, .{ 0x68, 0x05 });
        defer allocator.free(refused);
        @memset(output, 0xa5);
        try std.testing.expectError(
            error.InvalidStream,
            into(refused, output, .{ .workspace = workspace }, .{}),
        );
        for (output[expected.len..]) |byte| try std.testing.expectEqual(0xa5, byte);
        const admitted = try testZlibFrame(allocator, raw, expected, .{ 0x78, 0x01 });
        defer allocator.free(admitted);
        const result = try into(admitted, output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(expected.len, result.produced);
        try std.testing.expectEqualSlices(u8, expected, output[0..result.produced]);
        for (output[expected.len..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "checked zlib admits and checks header footer and exact stream boundary" {
    // Source bytes and their independently stated Adler-32 checksum.
    const vectors = [_]struct {
        source: []const u8,
        expected: u32,
    }{ .{ .source = "", .expected = 1 }, .{ .source = "123456789", .expected = 0x091e01de } };
    for (vectors) |vector| {
        try std.testing.expectEqual(vector.expected, adler32.hash(vector.source));
    }
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    // RFC 1950 wrapper around a stored 1x1 filtered RGBA row (0,1,2,3,4).
    const source = [_]u8{ 0x78, 1, 1, 5, 0, 250, 255, 0, 1, 2, 3, 4, 0, 25, 0, 11 };
    var output: [5]u8 = undefined;
    const result = try into(&source, &output, .{ .workspace = workspace }, .{});
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4 }, &output);
    try std.testing.expectEqual(source.len, result.consumed);
    try std.testing.expectEqual(output.len, result.produced);
    try std.testing.expectEqual(
        source.len,
        (try into(source ++ "unused", &output, .{ .workspace = workspace }, .{})).consumed,
    );
    for (0..source.len) |length| {
        try std.testing.expectError(
            error.InvalidStream,
            into(source[0..length], &output, .{ .workspace = workspace }, .{}),
        );
    }
    for ([_]usize{ 0, 1, 12, 13, 14, 15 }) |index| {
        var mutated = source;
        mutated[index] ^= 1;
        try std.testing.expectError(
            error.InvalidStream,
            into(&mutated, &output, .{ .workspace = workspace }, .{}),
        );
    }
}

test "stored readers preserve headers capacity suffixes and arbitrary packet boundaries" {
    const fixture = reader_stored;
    const allocator = std.testing.allocator;
    const output = try allocator.alloc(u8, fixture.expected.len + 64);
    defer allocator.free(output);
    for ([_]usize{ 1, 2, 3, 4, 7, 8, 16, 63, 256 }) |fragment| {
        for (0..fixture.expected.len + 2) |capacity| {
            @memset(output, 0xa5);
            var input: FragmentReader = undefined;
            input.init(fixture.source, fragment, null);
            const target = output[17..][0..capacity];
            if (capacity < fixture.expected.len) {
                try std.testing.expectError(
                    error.OutputTooSmall,
                    consumeStoredReader(&input.interface, target),
                );
            } else {
                const decoded = try consumeStoredReader(&input.interface, target);
                const result = decoded orelse return error.StoredFixtureDeclined;
                try std.testing.expectEqual(fixture.source.len, result.consumed);
                try std.testing.expectEqual(fixture.expected.len, result.produced);
                try std.testing.expectEqualSlices(u8, fixture.expected, target[0..result.produced]);
                for (target[result.produced..]) |byte| try std.testing.expectEqual(0xa5, byte);
            }
            for (output[0..17]) |byte| try std.testing.expectEqual(0xa5, byte);
            for (output[17 + capacity ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
        for (0..fixture.source.len) |length| {
            var input: FragmentReader = undefined;
            input.init(fixture.source[0..length], fragment, null);
            try std.testing.expectError(
                error.InvalidStream,
                consumeStoredReader(&input.interface, output),
            );
        }
        var input: FragmentReader = undefined;
        input.init(fixture.source ++ "UNUSED", fragment, null);
        const decoded = try consumeStoredReader(&input.interface, output);
        const result = decoded orelse return error.StoredFixtureDeclined;
        try std.testing.expectEqual(fixture.source.len, result.consumed);
        try std.testing.expectEqual(fixture.source.len, input.position);
    }
    for (0..32) |alignment| {
        @memset(output, 0xa5);
        var input: std.Io.Reader = .fixed(fixture.source);
        const decoded = try consumeStoredReader(
            &input,
            output[alignment..][0 .. fixture.expected.len + 1],
        );
        const result = decoded orelse return error.StoredFixtureDeclined;
        try std.testing.expectEqualSlices(
            u8,
            fixture.expected,
            output[alignment..][0..result.produced],
        );
        for (output[0..alignment]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (output[alignment + result.produced ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
    var empty: std.Io.Reader = .fixed(fixture.empty ++ "UNUSED");
    const decoded = try consumeStoredReader(&empty, &.{});
    const result = decoded orelse return error.StoredFixtureDeclined;
    try std.testing.expectEqual(fixture.empty.len, result.consumed);
    try std.testing.expectEqual(0, result.produced);
    try std.testing.expectEqualStrings("UNUSED", empty.buffered());
}

test "stored reader mixed fallback malformed blocks and transport failures stay distinct" {
    const fixture = reader_stored;
    var output: [fixture.expected.len + 1]u8 = @splat(0xa5);
    var mixed: FragmentReader = undefined;
    mixed.init(fixture.mixed, 1, null);
    try std.testing.expectEqual(null, try consumeStoredReader(&mixed.interface, &output));
    try std.testing.expectEqualSlices(u8, "ABC", output[0..3]);
    for (output[3..]) |byte| try std.testing.expectEqual(0xa5, byte);
    const workspace = try Workspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    const general = try into(fixture.mixed, &output, .{ .workspace = workspace }, .{});
    try std.testing.expectEqual(fixture.mixed.len, general.consumed);
    try std.testing.expectEqual(3, general.produced);

    for (0..fixture.source.len) |fail_after| {
        var failed: FragmentReader = undefined;
        failed.init(fixture.source, 7, fail_after);
        try std.testing.expectError(
            error.ReadFailed,
            consumeStoredReader(&failed.interface, &output),
        );
    }
    for ([_]usize{ 0, 1, 5, fixture.source.len - 1 }) |offset| {
        var source: [fixture.source.len]u8 = fixture.source.*;
        source[offset] ^= 1;
        var input: std.Io.Reader = .fixed(&source);
        try std.testing.expectError(error.InvalidStream, consumeStoredReader(&input, &output));
    }
    var reserved: std.Io.Reader = .fixed(&.{ 0x78, 1, 7 });
    try std.testing.expectError(error.InvalidStream, consumeStoredReader(&reserved, &output));
    for ([_]u8{ 3, 5 }) |block| {
        @memset(&output, 0xa5);
        var compressed: std.Io.Reader = .fixed(&.{ 0x78, 1, block });
        try std.testing.expectEqual(null, try consumeStoredReader(&compressed, &output));
        for (output) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "stored reader maximum lengths preserve exact capacity and stream boundaries" {
    const fixture = reader_stored;
    const allocator = std.testing.allocator;
    const wire_length = 2 + 5 + 65535 + 5 + 257 + 4;
    const source = try allocator.alloc(u8, wire_length + 8);
    defer allocator.free(source);
    source[0..7].* = .{ 0x78, 1, 0x80, 0xff, 0xff, 0, 0 };
    source[7 + 65535 ..][0..5].* = .{ 0xf9, 1, 1, 0xfe, 0xfe };
    for (0..fixture.maximum_output) |i| {
        const offset = if (i < 65535) 7 + i else 12 + i;
        source[offset] = @truncate(i * 29 + i / 31);
    }
    std.mem.writeInt(u32, source[wire_length - 4 ..][0..4], fixture.maximum_adler, .big);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source[0..wire_length], &digest, .{});
    var expected_digest: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_digest, fixture.maximum_sha256);
    try std.testing.expectEqualSlices(u8, &expected_digest, &digest);
    @memcpy(source[wire_length..], "UNUSED!!");
    const output = try allocator.alloc(u8, fixture.maximum_output + 32);
    defer allocator.free(output);
    for ([_]usize{ 1, 7, 64, 65534, 65535, 65536 }) |fragment| {
        for (
            [_]usize{
                0,
                1,
                65534,
                65535,
                65536,
                fixture.maximum_output - 1,
                fixture.maximum_output,
                fixture.maximum_output + 1,
            },
        ) |capacity| {
            @memset(output, 0xa5);
            var input: FragmentReader = undefined;
            input.init(source, fragment, null);
            const target = output[7..][0..capacity];
            if (capacity < fixture.maximum_output) {
                try std.testing.expectError(
                    error.OutputTooSmall,
                    consumeStoredReader(&input.interface, target),
                );
            } else {
                const decoded = try consumeStoredReader(&input.interface, target);
                const result = decoded orelse return error.StoredFixtureDeclined;
                try std.testing.expectEqual(wire_length, result.consumed);
                try std.testing.expectEqual(fixture.maximum_output, result.produced);
                for (target[0..result.produced], 0..) |actual, i| {
                    const expected: u8 = @truncate(i * 29 + i / 31);
                    try std.testing.expectEqual(expected, actual);
                }
                for (target[result.produced..]) |byte| try std.testing.expectEqual(0xa5, byte);
            }
            for (output[0..7]) |byte| try std.testing.expectEqual(0xa5, byte);
            for (output[7 + capacity ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
    }
}

test "exact-size zlib decoding checks output extent and checksum" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const framed = &frozen_fixtures.general_small_period7_zlib;
    const decoded_bytes = 4096 + 47;
    const larger = try allocator.alloc(u8, decoded_bytes + 34);
    defer allocator.free(larger);
    @memset(larger, 0xa5);
    const result = try into(
        framed,
        larger[1..][0..decoded_bytes],
        .{ .workspace = workspace },
        .{ .output_size = .exact },
    );
    try std.testing.expectEqual(framed.len, result.consumed);
    try std.testing.expectEqual(decoded_bytes, result.produced);
    for (larger[1..][0..decoded_bytes], 0..) |byte, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i % 7)), byte);
    }
    try std.testing.expectEqual(0xa5, larger[0]);
    for (larger[decoded_bytes + 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    try std.testing.expectError(
        error.InvalidStream,
        into(
            framed,
            larger[1..][0 .. decoded_bytes + 1],
            .{ .workspace = workspace },
            .{ .output_size = .exact },
        ),
    );
    try std.testing.expectError(
        error.OutputTooSmall,
        into(
            framed,
            larger[1..][0 .. decoded_bytes - 1],
            .{ .workspace = workspace },
            .{ .output_size = .exact },
        ),
    );
    const bad = try allocator.dupe(u8, framed);
    defer allocator.free(bad);
    bad[bad.len - 1] ^= 1;
    try std.testing.expectError(
        error.InvalidStream,
        into(
            bad,
            larger[1..][0..decoded_bytes],
            .{ .workspace = workspace },
            .{ .output_size = .exact },
        ),
    );
}

test "stored readers stay between inaccessible pages" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const posix = std.posix;
    const page_size = std.heap.pageSize();
    const memory = try posix.mmap(
        null,
        6 * page_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer posix.munmap(memory);
    for ([_]usize{ 0, 2, 3, 5 }) |page| {
        try std.testing.expectEqual(
            .SUCCESS,
            posix.errno(std.os.linux.mprotect(memory.ptr + page * page_size, page_size, .{})),
        );
    }
    const input_page = memory[page_size .. 2 * page_size];
    const output_page = memory[4 * page_size .. 5 * page_size];
    const stored = reader_stored;
    for ([_]usize{ 0, page_size - stored.source.len }) |input_offset| {
        const source = input_page[input_offset..][0..stored.source.len];
        @memcpy(source, stored.source);
        for (
            [_]usize{
                0,
                1,
                7,
                8,
                9,
                stored.expected.len - 1,
                stored.expected.len,
                stored.expected.len + 8,
            },
        ) |capacity| {
            for ([_]usize{ 0, page_size - capacity }) |output_offset| {
                @memset(output_page, 0xa5);
                const output = output_page[output_offset..][0..capacity];
                var input: FragmentReader = undefined;
                input.init(source, 1, null);
                if (capacity < stored.expected.len) {
                    try std.testing.expectError(
                        error.OutputTooSmall,
                        consumeStoredReader(&input.interface, output),
                    );
                } else {
                    const decoded = try consumeStoredReader(&input.interface, output);
                    const result = decoded orelse return error.StoredFixtureDeclined;
                    try std.testing.expectEqual(stored.source.len, result.consumed);
                    try std.testing.expectEqualSlices(
                        u8,
                        stored.expected,
                        output[0..result.produced],
                    );
                    for (output[result.produced..]) |byte| try std.testing.expectEqual(0xa5, byte);
                }
                for (output_page[0..output_offset]) |byte| try std.testing.expectEqual(0xa5, byte);
                for (output_page[output_offset + capacity ..]) |byte| {
                    try std.testing.expectEqual(0xa5, byte);
                }
            }
        }
        const output = output_page[page_size - stored.expected.len ..];
        for (0..source.len) |length| {
            @memset(output_page, 0xa5);
            var input: std.Io.Reader = .fixed(source[0..length]);
            try std.testing.expectError(error.InvalidStream, consumeStoredReader(&input, output));
        }
    }
}

test "zlib inline fixture bytes preserve independent source identities" {
    const identities = [_]struct {
        bytes: []const u8,
        sha256: []const u8,
    }{
        .{
            .bytes = general_pairs.maximum_tail,
            .sha256 = "25ec42a79ed7698f6961501b3e952bb88e395be037100926d5b03545a6e2bcf3",
        },
        .{
            .bytes = general_pairs.source,
            .sha256 = "0f8b0a3f82df204abd5d6e6c44c3a0d63320474702d7a509eb2a8eff47525a79",
        },
        .{
            .bytes = general_pairs.expected,
            .sha256 = "a3f64bb6ea63bf005f688259da6b3c70437f9bdb4bc90e3e3db73c8ade3e8e52",
        },
        .{
            .bytes = &frozen_fixtures.general_small_period7_zlib,
            .sha256 = "a1ef32bce88a57a52dabae2e4866f72ac89158c7c14bfe259685c2c1a42bfca9",
        },
        .{
            .bytes = paired_dense.source,
            .sha256 = "1204d8a884080ad8ace6d73a5f87eff51282c57a92c33b7479a5fafa7aac62fa",
        },
        .{
            .bytes = paired_dense.expected,
            .sha256 = "b360737d9b8470e762195e52d683d2001b3a589956e4336b0afd74aeda05d43d",
        },
        .{
            .bytes = paired_literals.source,
            .sha256 = "4257cc85a0bf6b4fd821b6c8fcd85442a1a7fb529fedc1a321084da1ea686268",
        },
        .{
            .bytes = paired_literals.expected,
            .sha256 = "aace4517d816e5385c6354460b3f2ee6f2bf876c2155540de4efc9de60f6ba88",
        },
        .{
            .bytes = &raw_fixtures.payload_literal_budget_deflate,
            .sha256 = "4f22161b51c6e27ca8013569d5cdc04a2d121fe830759a38f544f7a3cc480aaf",
        },
        .{
            .bytes = &raw_fixtures.payload_ordinary_deflate,
            .sha256 = "886a8fbb9b17015023322e5eed7f030b496feb522fac57c446ef42c49a9af2e4",
        },
        .{
            .bytes = &raw_fixtures.payload_wide_deflate,
            .sha256 = "248a35299be6be9efbebdbadf9ea26400892f66d0ce1129e5c5f2db4de4425a0",
        },
        .{
            .bytes = &frozen_fixtures.reader_empty_zlib,
            .sha256 = "5cde4521f669f961047a2a0e6fe27487a15c68a8d5bf9e40cdc5533d7dd873b2",
        },
        .{
            .bytes = &frozen_fixtures.reader_mixed_zlib,
            .sha256 = "0e14a635f91c09519f9e15baa8d9e97ed9291a7ceb1dee1f9746e12c0b3117b8",
        },
        .{
            .bytes = &frozen_fixtures.reader_stored_golden,
            .sha256 = "f612c80d616ecff12457a51f5251fc92f52b1228189f92be1eb99d7417820638",
        },
        .{
            .bytes = &frozen_fixtures.reader_stored_zlib,
            .sha256 = "bcad0394689add13dfb203f44cf75156170b8016656df9e4ee32054ea5479797",
        },
        .{
            .bytes = wide_literals.source,
            .sha256 = "a198aa8396fd51bfbfc282b4184f00db50bb6a5bf2c935366df10f68a27c7850",
        },
        .{
            .bytes = &raw_fixtures.expanded_48bit_golden,
            .sha256 = "da7864defb0fa794ae6caba07bf7be36f8ec6e08a80523cf1a8213e2cd712736",
        },
        .{
            .bytes = &frozen_fixtures.expanded_48bit_zlib,
            .sha256 = "ebb03e5a07e96a4945e0f054ef04225edbb36c81a7094a23116184db3504fdb0",
        },
        .{
            .bytes = &frozen_fixtures.general_small_period3_zlib,
            .sha256 = "4446e627fde84e3650e18eb498d089e8233dea538969cb8901cedcc85ddd72a5",
        },
        .{
            .bytes = &frozen_fixtures.general_small_period5_zlib,
            .sha256 = "c52ef548ce27c0bb45ab88bcdee4e93d434beb9519eab905bf542b6702fa4bc0",
        },
        .{
            .bytes = &frozen_fixtures.general_small_period6_zlib,
            .sha256 = "00da5b3d1638b7bfccaa1b8dc2930b1f13948f41b029c5a71f7ba9251f58d0b1",
        },
        .{
            .bytes = &raw_fixtures.minimum_wide_deflate,
            .sha256 = "647f5ca69d27a66de4f7ba990e63288a1781b397e4ad000533a2dfa444e24505",
        },
        .{
            .bytes = &frozen_fixtures.ordinary_guard_distance2_zlib,
            .sha256 = "87c5ffbeecce3a625b438b2a61b26c57060457915a1fceb3a4c137a9d9f761f7",
        },
        .{
            .bytes = &frozen_fixtures.ordinary_guard_distance4_zlib,
            .sha256 = "3e8ec7472e97a31d39f70a0e4f4df1ba7ad281ffc41f9924e0cddf1b60a9f629",
        },
        .{
            .bytes = &frozen_fixtures.ordinary_guard_distance9_zlib,
            .sha256 = "7656f6b5336da8c57fceb80a6528e769ed38907105bef8d870b01f3f7778851c",
        },
        .{
            .bytes = &frozen_fixtures.ordinary_guard_width3_period3_zlib,
            .sha256 = "5dde43e33e25b712d4107c190a155cd09c8d7dcfaaa464a5d08e1f8c92ab7b75",
        },
        .{
            .bytes = &frozen_fixtures.ordinary_guard_width7_period3_zlib,
            .sha256 = "6f4c0f99c0344f5ee97246fae157cb439695448bd55d4cfe2e83f1a6bda9402b",
        },
        .{
            .bytes = &raw_fixtures.short_wide_four_deflate,
            .sha256 = "0e3a010bf86b94a1dc1498786609d65fac049a87daec261019dd7a326c15804f",
        },
        .{
            .bytes = &raw_fixtures.short_wide_thirteen_deflate,
            .sha256 = "035bf5ef71d725feec6bc3ce7ad6479808f7b5b42e3fc652f6a61f586a3e23d2",
        },
        .{
            .bytes = &frozen_fixtures.window_period24_zlib,
            .sha256 = "f91421786da34878cdecfce1bfab15f6b2379b5939c15158f63241f2104e0f09",
        },
        .{
            .bytes = &frozen_fixtures.window_period9_zlib,
            .sha256 = "9cc64695c96dd6ed0b74e31e230e2841dbc194784b496cc332a1ee63e1bf1c8e",
        },
    };
    for (identities) |fixture| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(fixture.bytes, &digest, .{});
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, fixture.sha256);
        try std.testing.expectEqualSlices(u8, &expected, &digest);
    }
}

test "zlib framing admission rejects unsupported headers and overlapping spans" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const state = std.mem.asBytes(workspace);
    // Independently framed empty stored stream with Adler-32 one.
    var source = [_]u8{ 0x78, 1, 1, 0, 0, 255, 255, 0, 0, 0, 1 };
    const original = source;
    var output: [8]u8 = undefined;
    inline for (.{ OutputSize.bounded, OutputSize.exact }) |extent| {
        @memset(state, 0x6d);
        @memset(&output, 0xa5);
        // The raw payload is disjoint from these two bytes; wrapper admission must check the header
        // as part of the complete input span.
        try std.testing.expectError(
            error.StorageOverlap,
            into(&source, source[0..2], .{ .workspace = workspace }, .{ .output_size = extent }),
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
    }
}

test "exact-size zlib decoding enforces the declared window" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    var output: [304]u8 = @splat(0xa5);
    const result = try into(
        &zlib_fixture.at_boundary,
        output[0..303],
        .{ .workspace = workspace },
        .{ .output_size = .exact },
    );
    try std.testing.expectEqual(zlib_fixture.at_boundary.len, result.consumed);
    try std.testing.expectEqual(303, result.produced);
    try std.testing.expect(std.mem.allEqual(u8, output[0..303], 'A'));
    try std.testing.expectEqual(0xa5, output[303]);
    for ([_][]const u8{ &zlib_fixture.beyond_boundary, &zlib_fixture.beyond_window }) |source| {
        @memset(&output, 0xa5);
        try std.testing.expectError(
            error.InvalidStream,
            into(source, output[0..303], .{ .workspace = workspace }, .{ .output_size = .exact }),
        );
        try std.testing.expect(std.mem.allEqual(u8, output[300..], 0xa5));
        var admitted: [zlib_fixture.beyond_window.len]u8 = undefined;
        @memcpy(&admitted, source);
        admitted[0..2].* = .{ 0x18, 0x19 };
        try std.testing.expectEqual(
            303,
            (try into(
                &admitted,
                output[0..303],
                .{ .workspace = workspace },
                .{ .output_size = .exact },
            )).produced,
        );
        try std.testing.expect(std.mem.allEqual(u8, output[0..303], 'A'));
        try std.testing.expectEqual(0xa5, output[303]);
    }
}

test "zlib window-period streams preserve history and exact boundaries" {
    // Python zlib 1.3.2 level 6 encodes 4 MiB + 47 bytes repeating seed[i]=(31*i+7)&255. An
    // independent RFC parser confirms all matches, exact framing and the golden.
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const size = 4 * 1024 * 1024 + 47;
    const backing = try allocator.alloc(u8, size + 128);
    defer allocator.free(backing);
    const cases = [_]struct {
        wire: []const u8,
        period: usize,
    }{
        .{ .wire = &frozen_fixtures.window_period9_zlib, .period = 9 },
        .{ .wire = &frozen_fixtures.window_period24_zlib, .period = 24 },
    };
    for (cases) |fixture| {
        @memset(backing, 0xa5);
        const output = backing[64 .. backing.len - 64];
        const result = try into(fixture.wire, output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(fixture.wire.len, result.consumed);
        try std.testing.expectEqual(size, result.produced);
        for (output, 0..) |byte, index| {
            const expected: u8 = @truncate(index % fixture.period * 31 + 7);
            try std.testing.expectEqual(expected, byte);
        }
        for (backing[0..64]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (backing[backing.len - 64 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        @memset(backing, 0xa5);
        try std.testing.expectError(
            error.OutputTooSmall,
            into(fixture.wire, output[0 .. size - 1], .{ .workspace = workspace }, .{}),
        );
        for (backing[64 + size - 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "zlib ordinary small periods retain phase and exact bounds" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const output_bytes = 4096 + 47;
    const backing = try allocator.alloc(u8, output_bytes + 64);
    defer allocator.free(backing);
    // Independently assembled RFC1951 wires use a complete six-bit literal/length book: bytes
    // 0..33, EOB and all 29 length codes. Singleton distances select periods 3/5/6/7. Code 285 has
    // width 6, bypassing short-maximum admission; literal Kraft mass 34/64 excludes paired
    // admission. Python zlib 1.3.2 restores every byte i%period; early lengths 8/15/16/31/32/33
    // exercise pattern widths and phase before long runs.
    const cases = [_]struct {
        period: usize,
        source: []const u8,
    }{
        .{ .period = 3, .source = &frozen_fixtures.general_small_period3_zlib },
        .{ .period = 5, .source = &frozen_fixtures.general_small_period5_zlib },
        .{ .period = 6, .source = &frozen_fixtures.general_small_period6_zlib },
        .{ .period = 7, .source = &frozen_fixtures.general_small_period7_zlib },
    };
    for (cases) |fixture| {
        const period = fixture.period;
        const source = fixture.source;
        for (0..33) |alignment| {
            @memset(backing, 0xa5);
            const output = backing[alignment..][0 .. output_bytes + 32];
            const result = try into(source, output, .{ .workspace = workspace }, .{});
            try std.testing.expectEqual(source.len, result.consumed);
            try std.testing.expectEqual(output_bytes, result.produced);
            for (output[0..output_bytes], 0..) |byte, index| {
                try std.testing.expectEqual(@as(u8, @intCast(index % period)), byte);
            }
            for (backing[0..alignment]) |byte| try std.testing.expectEqual(0xa5, byte);
            for (backing[alignment + output_bytes ..]) |byte| {
                try std.testing.expectEqual(0xa5, byte);
            }
        }
        @memset(backing, 0xa5);
        try std.testing.expectError(
            error.OutputTooSmall,
            into(source, backing[1..][0 .. output_bytes - 1], .{ .workspace = workspace }, .{}),
        );
        try std.testing.expectEqual(0xa5, backing[0]);
        for (backing[output_bytes..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "zlib repetition admission respects length widths and distance exclusions" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const output_bytes = 4096 + 47;
    const backing = try allocator.alloc(u8, output_bytes + 64);
    defer allocator.free(backing);
    // Independently assembled complete LL/precodes isolate code 285 widths 3/7, and distance 2,
    // pure distance 4 and distance 9 exclusions. Python zlib 1.3.2 validates complete bytes
    // i%period and framing, independent of this decoder.
    const cases = [_]struct {
        period: usize,
        source: []const u8,
    }{
        .{ .period = 3, .source = &frozen_fixtures.ordinary_guard_width3_period3_zlib },
        .{ .period = 3, .source = &frozen_fixtures.ordinary_guard_width7_period3_zlib },
        .{ .period = 2, .source = &frozen_fixtures.ordinary_guard_distance2_zlib },
        .{ .period = 4, .source = &frozen_fixtures.ordinary_guard_distance4_zlib },
        .{ .period = 9, .source = &frozen_fixtures.ordinary_guard_distance9_zlib },
    };
    for (cases) |fixture| {
        const period = fixture.period;
        const source = fixture.source;
        for (0..33) |alignment| {
            @memset(backing, 0xa5);
            const output = backing[alignment..][0 .. output_bytes + 32];
            const result = try into(source, output, .{ .workspace = workspace }, .{});
            try std.testing.expectEqual(source.len, result.consumed);
            try std.testing.expectEqual(output_bytes, result.produced);
            for (output[0..output_bytes], 0..) |byte, index| {
                try std.testing.expectEqual(@as(u8, @intCast(index % period)), byte);
            }
            for (backing[0..alignment]) |byte| try std.testing.expectEqual(0xa5, byte);
            for (backing[alignment + output_bytes ..]) |byte| {
                try std.testing.expectEqual(0xa5, byte);
            }
        }
        @memset(backing, 0xa5);
        try std.testing.expectError(
            error.OutputTooSmall,
            into(source, backing[1..][0 .. output_bytes - 1], .{ .workspace = workspace }, .{}),
        );
        try std.testing.expectEqual(0xa5, backing[0]);
        for (backing[output_bytes..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "zlib small windows preserve wide short-match streams" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const seed = "ABCDEFGABCDEFGABCDEFGABCDEFGABCD";
    const cases = [_]struct {
        source: []const u8,
        size: usize,
    }{
        .{ .source = &raw_fixtures.short_wide_four_deflate, .size = 6464 },
        .{ .source = &raw_fixtures.short_wide_thirteen_deflate, .size = 7004 },
        .{ .source = &raw_fixtures.minimum_wide_deflate, .size = 6404 },
    };
    for (cases) |fixture| {
        const expected = try allocator.alloc(u8, fixture.size);
        defer allocator.free(expected);
        for (expected, 0..) |*byte, index| byte.* = seed[index % seed.len];
        const backing = try allocator.alloc(u8, fixture.size + 66);
        defer allocator.free(backing);
        const framed = try testZlibFrame(allocator, fixture.source, expected, .{ 0x08, 0x1d });
        defer allocator.free(framed);
        @memset(backing, 0xa5);
        const decoded = try into(
            framed,
            backing[1..][0 .. fixture.size + 16],
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(framed.len, decoded.consumed);
        try std.testing.expectEqual(fixture.size, decoded.produced);
        try std.testing.expectEqualSlices(u8, expected, backing[1..][0..fixture.size]);
        for (backing[fixture.size + 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "exact-size zlib wide streams preserve framing and outside guards" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const seed = "ABCDEFGABCDEFGABCDEFGABCDEFGABCD";
    const cases = [_]struct {
        source: []const u8,
        size: usize,
    }{
        .{ .source = &raw_fixtures.short_wide_four_deflate, .size = 6464 },
        .{ .source = &raw_fixtures.short_wide_thirteen_deflate, .size = 7004 },
    };
    for (cases) |fixture| {
        const expected = try allocator.alloc(u8, fixture.size);
        defer allocator.free(expected);
        for (expected, 0..) |*byte, index| byte.* = seed[index % seed.len];
        const backing = try allocator.alloc(u8, fixture.size + 96);
        defer allocator.free(backing);
        const framed = try testZlibFrame(allocator, fixture.source, expected, .{ 0x78, 0x01 });
        defer allocator.free(framed);
        @memset(backing, 0xa5);
        const result = try into(
            framed,
            backing[1..][0..fixture.size],
            .{ .workspace = workspace },
            .{ .output_size = .exact },
        );
        try std.testing.expectEqual(framed.len, result.consumed);
        try std.testing.expectEqual(fixture.size, result.produced);
        try std.testing.expectEqualSlices(u8, expected, backing[1..][0..fixture.size]);
        try std.testing.expectEqual(0xa5, backing[0]);
        for (backing[fixture.size + 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "zlib expanded-length streams preserve framing and exact-size paths" {
    // Independent RFC 1951 encoder and Python-zlib raw/checked goldens. A stored block supplies
    // full history; sparse bytes and 29 active length slots admit the ordinary match-heavy class.
    // The first aligned match consumes 20+28 bits.
    const source = &frozen_fixtures.expanded_48bit_zlib;
    const golden = &raw_fixtures.expanded_48bit_golden;
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const input = try allocator.alloc(u8, source.len + 32 + 9);
    defer allocator.free(input);
    const backing = try allocator.alloc(u8, golden.len + 128);
    defer allocator.free(backing);
    for (0..32) |alignment| {
        @memset(input, 0xa7);
        @memcpy(input[alignment..][0..source.len], source);
        @memcpy(input[alignment + source.len ..][0..9], "AFTER-END");
        for ([_]bool{ false, true }) |exact| {
            for ([_]usize{ 32768, 32769, golden.len - 1, golden.len, golden.len + 16 }) |capacity| {
                if (exact and capacity > golden.len) continue;
                @memset(backing, 0xd1);
                const start = 64 + alignment;
                const output = backing[start..][0..capacity];
                const bytes = input[alignment..][0 .. source.len + 9];
                const result = blk: {
                    if (exact) break :blk into(
                        bytes,
                        output,
                        .{ .workspace = workspace },
                        .{ .output_size = .exact },
                    );
                    break :blk into(bytes, output, .{ .workspace = workspace }, .{});
                };
                if (capacity < golden.len) {
                    try std.testing.expectError(error.OutputTooSmall, result);
                } else {
                    const value = try result;
                    try std.testing.expectEqual(source.len, value.consumed);
                    try std.testing.expectEqual(golden.len, value.produced);
                    try std.testing.expectEqualSlices(u8, golden, output[0..value.produced]);
                    for (output[value.produced..]) |byte| {
                        try std.testing.expectEqual(0xd1, byte);
                    }
                }
                for (backing[0..start]) |byte| try std.testing.expectEqual(0xd1, byte);
                for (backing[start + capacity ..]) |byte| {
                    try std.testing.expectEqual(0xd1, byte);
                }
            }
        }
    }
    // Every byte truncation of the compressed header/payload is rejected. Stored-history
    // truncations have separate raw-codec coverage.
    for (32773..source.len) |cut| {
        @memset(backing, 0xd1);
        try std.testing.expectError(
            error.InvalidStream,
            into(
                source[0..cut],
                backing[64..][0..golden.len],
                .{ .workspace = workspace },
                .{ .output_size = .exact },
            ),
        );
        for (backing[0..64]) |byte| try std.testing.expectEqual(0xd1, byte);
        for (backing[64 + golden.len ..]) |byte| try std.testing.expectEqual(0xd1, byte);
    }
}

test "narrow literal and wide expanded wires preserve framing and spare output" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const cases = [_]struct {
        raw: []const u8,
        expected: []const u8,
    }{
        .{
            .raw = &raw_fixtures.byte_dominant_narrow_deflate,
            .expected = &raw_fixtures.byte_dominant_narrow_golden,
        },
        .{
            .raw = &raw_fixtures.wide_expanded_deflate,
            .expected = &raw_fixtures.wide_expanded_golden,
        },
    };
    for (cases) |fixture| {
        const frame = try testZlibFrame(allocator, fixture.raw, fixture.expected, .{ 0x78, 0x01 });
        defer allocator.free(frame);
        const source = try allocator.alloc(u8, frame.len + 16);
        defer allocator.free(source);
        @memcpy(source[0..frame.len], frame);
        @memset(source[frame.len..], 0xd1);
        const backing = try allocator.alloc(u8, fixture.expected.len + 96);
        defer allocator.free(backing);
        for ([_]usize{ 0, 1, 7, 15, 31 }) |alignment| {
            inline for (.{ false, true }) |exact| {
                @memset(backing, 0xa5);
                const capacity = fixture.expected.len + @as(usize, if (exact) 0 else 32);
                const output = backing[alignment..][0..capacity];
                const result = blk: {
                    if (exact) break :blk try into(
                        source,
                        output,
                        .{ .workspace = workspace },
                        .{ .output_size = .exact },
                    );
                    break :blk try into(source, output, .{ .workspace = workspace }, .{});
                };
                try std.testing.expectEqual(frame.len, result.consumed);
                try std.testing.expectEqual(fixture.expected.len, result.produced);
                try std.testing.expectEqualSlices(u8, fixture.expected, output[0..result.produced]);
                for (backing[0..alignment]) |byte| try std.testing.expectEqual(0xa5, byte);
                for (backing[alignment + result.produced ..]) |byte| {
                    try std.testing.expectEqual(0xa5, byte);
                }
            }
        }
        source[frame.len - 1] ^= 1;
        try std.testing.expectError(
            error.InvalidStream,
            into(source, backing[0..fixture.expected.len], .{ .workspace = workspace }, .{}),
        );
        source[frame.len - 1] ^= 1;
        const reused = try into(
            source,
            backing[0..fixture.expected.len],
            .{ .workspace = workspace },
            .{ .output_size = .exact },
        );
        try std.testing.expectEqual(frame.len, reused.consumed);
        try std.testing.expectEqualSlices(u8, fixture.expected, backing[0..reused.produced]);
    }
}

test "packed recovery preserves checked framing with large spare output" {
    const encoded = &frozen_fixtures.expanded_48bit_zlib;
    const expected = &raw_fixtures.expanded_48bit_golden;
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const input = try allocator.alloc(u8, encoded.len + 32);
    defer allocator.free(input);
    @memcpy(input[0..encoded.len], encoded);
    @memset(input[encoded.len..], 0xd7);
    const backing = try allocator.alloc(u8, expected.len + 512 + 64);
    defer allocator.free(backing);
    for ([_]usize{ encoded.len, input.len }) |length| {
        @memset(backing, 0xa5);
        const output = backing[31..][0 .. expected.len + 512];
        const result = try into(input[0..length], output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(encoded.len, result.consumed);
        try std.testing.expectEqual(expected.len, result.produced);
        try std.testing.expectEqualSlices(u8, expected, output[0..result.produced]);
        for (backing[0..31]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (backing[31 + result.produced ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        try std.testing.expectError(
            error.InvalidStream,
            into(input[0..length], output, .{ .workspace = workspace }, .{ .output_size = .exact }),
        );
    }
}

test "exact short extent does not claim an unverified zlib trailer" {
    const workspace = try Workspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    // Independent zlib stored-block framing for "A", including Adler-32 0x00420042.
    const wire = [_]u8{ 0x78, 0x01, 0x01, 0x01, 0x00, 0xfe, 0xff, 'A', 0x00, 0x42, 0x00, 0x42 };
    var bad = wire;
    bad[bad.len - 1] ^= 1;
    var output: [4]u8 = @splat(0xa5);
    const options: Options = .{ .output_size = .exact };
    // A short raw end does not validate any trailer; keep the wrapper's general error.
    for ([_][]const u8{ &wire, &bad, wire[0 .. wire.len - 1] }) |source| {
        try std.testing.expectError(
            error.InvalidStream,
            into(source, output[1..3], .{ .workspace = workspace }, options),
        );
    }
    const result = try into(&wire, output[1..2], .{ .workspace = workspace }, options);
    try std.testing.expectEqual(@as(usize, 1), result.produced);
    try std.testing.expectEqual(@as(u8, 'A'), output[1]);
    try std.testing.expectError(
        error.InvalidStream,
        into(&bad, output[1..2], .{ .workspace = workspace }, options),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        into(
            &wire,
            output[1..2],
            .{ .workspace = workspace },
            .{ .output_size = .exact, .limits = .{ .input_bytes = wire.len - 1 } },
        ),
    );
    try std.testing.expectEqual(@as(u8, 0xa5), output[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), output[3]);
}

// A fresh worker receives final input, at most one requested dictionary, then its unconsumed
// suffix. No call reuses failed state or attaches a dictionary outside the request boundary.
fn completeFailure(failure: StreamDecoder.Error) Error {
    return switch (failure) {
        error.NeedReset, error.InvalidState => unreachable,
        else => |err| err,
    };
}

test {
    _ = StreamDecoder;
}
