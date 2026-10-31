//! RFC 1950 framing, checked decoding and Reader adapters.

const builtin = @import("builtin");
const std = @import("std");
const overlaps = @import("../common/byte_ranges.zig").overlaps;

const adler32 = @import("../adler32.zig");
const deflate = @import("../deflate.zig");
const fixture_data = @import("../deflate/fixtures.zig");

const general_pairs = fixture_data.general_pairs;
const paired_dense = fixture_data.paired_dense;
const paired_literals = fixture_data.paired_literals;
const raw_fixtures = fixture_data.frozen_fixtures;
const wide_literals = fixture_data.wide_literals;

pub const Error = deflate.Error;
pub const DecodeResult = deflate.DecodeResult;
pub const DecoderWorkspace = deflate.DecoderWorkspace;

pub const Input = deflate.Input;
pub const DecodeLimits = deflate.DecodeLimits;

pub const DecodeStorage = deflate.DecodeStorage;
pub const StreamStorage = deflate.StreamStorage;
pub const OutputSize = deflate.OutputSize;
pub const TrailingData = deflate.TrailingData;

/// Complete RFC 1950 admission. Dictionary identity covers the full supplied dictionary; decoding
/// copies only its reachable suffix into the optional history reservation.
pub const DecodeOptions = struct {
    /// Maximum match distance, additionally bounded by the stream's declared window.
    window_bytes: usize = 32768,
    /// Null rejects dictionary-requiring streams; non-null requires DecodeStorage.history.
    dictionary: ?[]const u8 = null,
    /// Exact requires the restored size to equal the complete destination length.
    output_size: OutputSize = .bounded,
    /// Allow leaves following records unconsumed.
    trailing_data: TrailingData = .allow,
    /// Admission includes zlib framing and excludes dictionary bytes.
    limits: DecodeLimits = .{},
};

/// Resumable admission; dictionary negotiation remains `dictionaryId`/`setDictionary`.
pub const StreamDecodeOptions = struct {
    /// Maximum match distance, additionally bounded by the declared window.
    window_bytes: usize = 32768,
    /// Cumulative framing, payload and restored-byte admission.
    limits: DecodeLimits = .{},
};

/// A zlib step can suspend for a verified preset dictionary as well as I/O.
pub const DecodeStatus = enum {
    /// Supply more encoded input, preserving any unconsumed suffix.
    need_input,
    /// Supply output capacity and resubmit any unconsumed input.
    need_output,
    /// Read `Decoder.dictionaryId`, then attach matching bytes with `Decoder.setDictionary`.
    need_dictionary,
    /// The stream and Adler-32 trailer are verified; following input remains unconsumed.
    complete,
};

/// Per-call copied counts; complete includes the verified Adler-32 trailer.
pub const DecodeProgress = struct {
    /// Accepted bytes, leaving following streams or application data untouched.
    consumed: usize,
    /// Restored bytes in the supplied output span.
    produced: usize,
    /// Resource needed next, or successful stream completion.
    status: DecodeStatus,
};

/// Streaming failures require reset. WrongDictionary compares DICTID with the Adler-32 of the
/// complete supplied dictionary, before admitting any matches.
pub const DecodeError = deflate.DecodeError || error{WrongDictionary};

/// Validates exactly the two-byte header without changing caller storage. Requires DEFLATE method
/// 8, CINFO 0..7, valid FCHECK and no preset dictionary. This checks only framing admission; decode
/// also checks payload and checksum.
pub fn validateHeader(header: *const [2]u8) Error!void {
    if (header[1] & 32 != 0) return error.InvalidStream;
    return admitHeader(header);
}

/// Decodes one complete zlib stream, verifying its window and Adler-32 trailer. Extent and
/// trailing-data policy are independent. Dictionary-free calls require no history reservation and
/// retain direct-buffer kernels. Source, destination and used reservations must be disjoint. Errors
/// publish no counts and may change output; calls allocate nothing and retain no input pointers.
pub fn decode(
    source: []const u8,
    output: []u8,
    storage: DecodeStorage,
    options: DecodeOptions,
) DecodeError!DecodeResult {
    const limits = options.limits;
    if (options.window_bytes == 0 or options.window_bytes > 32768) return error.InvalidOptions;
    const result = if (options.dictionary) |dictionary| blk: {
        const history = storage.history orelse return error.InvalidOptions;
        var decoder: Decoder = undefined;
        try decoder.reset(
            .{ .workspace = storage.workspace, .history = history },
            .{ .window_bytes = options.window_bytes, .limits = limits },
        );
        var progress = try decoder.step(.{ .bytes = source, .final = true }, output);
        var consumed = progress.consumed;
        if (progress.status == .need_dictionary) {
            try decoder.setDictionary(dictionary);
            progress = try decoder.step(.{ .bytes = source[consumed..], .final = true }, output);
            consumed += progress.consumed;
        }
        if (progress.status == .need_output) return error.OutputTooSmall;
        break :blk DecodeResult{ .consumed = consumed, .produced = progress.produced };
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

test decode {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);

    // A zlib header, a stored DEFLATE block containing "hello", and its Adler-32 footer.
    const source = [_]u8{
        0x78, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff, 0x68,
        0x65, 0x6c, 0x6c, 0x6f, 0x06, 0x2c, 0x02, 0x15,
    };
    var output: [32]u8 = undefined;
    const result = try decode(&source, &output, .{ .workspace = workspace }, .{});
    const payload = output[0..result.produced];

    try std.testing.expectEqual(source.len, result.consumed);
    try std.testing.expectEqualStrings("hello", payload);
}

fn admitHeader(header: *const [2]u8) Error!void {
    if (header[0] & 15 != 8 or header[0] >> 4 > 7) return error.InvalidStream;
    const encoded = std.mem.readInt(u16, header, .big);
    if (encoded % 31 != 0) return error.InvalidStream;
}

fn decodeBuffer(
    source: []const u8,
    output: []u8,
    workspace: *DecoderWorkspace,
    options: DecodeOptions,
) DecodeError!DecodeResult {
    if (source.len < 2) return error.InvalidStream;
    try validateHeader(source[0..2]);
    const window = @as(usize, 1) << @intCast(8 + (source[0] >> 4));
    const raw = try deflate.decode(
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
    );
    const footer = 2 + raw.consumed;
    if (source.len - footer < 4) return error.InvalidStream;
    const expected = std.mem.readInt(u32, source[footer..][0..4], .big);
    const checksum = @call(.always_inline, adler32.hash, .{output[0..raw.produced]});
    if (expected != checksum) return error.InvalidStream;
    return .{ .consumed = footer + 4, .produced = raw.produced };
}

/// Resumable RFC 1950 owner. Call reset before use; retain exclusive workspace and history until
/// reset or end of use. The small state may move between calls because all retained pointers refer
/// to those external reservations. A transfer retires the old state; do not continue two copies
/// sharing its reservations. Input/output fragments can retire after each step. No allocator is
/// retained and no operation allocates. Output remains private until checksum success.
pub const Decoder = struct {
    const Phase = enum { header, dictionary_id, dictionary, body, footer, complete };

    raw: deflate.Decoder,
    phase: Phase = .header,
    field: [4]u8 = undefined,
    field_bytes: usize = 0,
    id: u32 = 0,
    checksum: adler32.Hasher = .init,
    eof: bool = false,
    failed: bool = false,

    limits: DecodeLimits,
    window_bytes: usize,
    work_left: u64,

    /// Accepted bytes including header, DICTID and trailer.
    input_bytes: u64 = 0,
    /// Restored bytes, excluding preset dictionary bytes.
    output_bytes: u64 = 0,

    /// Ends old stream state and starts a fresh header. Cumulative limits also include wrapper
    /// bytes. No reservation contents need initialization.
    pub fn reset(
        self: *Decoder,
        storage: StreamStorage,
        options: StreamDecodeOptions,
    ) DecodeError!void {
        const workspace = storage.workspace;
        const history = storage.history;
        const limits = options.limits;
        if (options.window_bytes == 0 or options.window_bytes > 32768) return error.InvalidOptions;
        if (overlaps(
            std.mem.asBytes(self),
            std.mem.asBytes(workspace),
        )) return error.StorageOverlap;
        if (overlaps(std.mem.asBytes(self), history)) return error.StorageOverlap;
        // Initialize only the small owner; construct raw state at its address.
        self.* = .{
            .raw = undefined,
            .limits = limits,
            .window_bytes = options.window_bytes,
            .work_left = limits.work_units,
        };
        try self.raw.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    }

    /// Requested full-dictionary checksum, available only at need_dictionary.
    pub fn dictionaryId(self: *const Decoder) ?u32 {
        return if (!self.failed and self.phase == .dictionary) self.id else null;
    }

    /// Verifies the full dictionary and copies its reachable suffix into raw history. The caller
    /// can retire dictionary storage immediately on return. Wrong IDs and attachment outside a
    /// request poison the decoder.
    pub fn setDictionary(self: *Decoder, dictionary: []const u8) DecodeError!void {
        if (self.failed) {
            @branchHint(.unlikely);
            return error.NeedReset;
        }
        self.attach(dictionary) catch |err| {
            @branchHint(.cold);
            self.failed = true;
            return err;
        };
    }

    /// Accepts arbitrary input/output fragments, including empty output while parsing
    /// headers/trailers. Final input remains latched while output or a dictionary is pending. Any
    /// failure requires reset before reuse.
    pub fn step(self: *Decoder, input: Input, output: []u8) DecodeError!DecodeProgress {
        if (self.failed) {
            @branchHint(.unlikely);
            return error.NeedReset;
        }
        return self.advance(input, output) catch |err| {
            @branchHint(.cold);
            self.failed = true;
            return err;
        };
    }

    fn attach(self: *Decoder, dictionary: []const u8) DecodeError!void {
        if (overlaps(dictionary, std.mem.asBytes(self))) return error.StorageOverlap;
        if (self.phase != .dictionary) return error.InvalidState;
        if (adler32.hash(dictionary) != self.id) return error.WrongDictionary;
        try self.raw.setDictionary(dictionary);
        self.phase = .body;
    }

    fn advance(
        self: *Decoder,
        supplied_input: Input,
        supplied_output: []u8,
    ) DecodeError!DecodeProgress {
        if (overlaps(supplied_input.bytes, supplied_output)) return error.StorageOverlap;
        const reservations = .{
            std.mem.asBytes(self),
            std.mem.asBytes(self.raw.workspace),
            @as([]u8, self.raw.history),
        };
        inline for (reservations) |reservation| {
            if (overlaps(supplied_input.bytes, reservation)) return error.StorageOverlap;
            if (overlaps(supplied_output, reservation)) return error.StorageOverlap;
        }
        const input_left = self.limits.input_bytes -| self.input_bytes;
        const output_left = self.limits.output_bytes -| self.output_bytes;
        const admitted_input: usize = @intCast(
            @min(supplied_input.bytes.len, input_left, self.work_left),
        );
        const admitted_output: usize = @intCast(
            @min(supplied_output.len, output_left, self.work_left),
        );
        const input: Input = .{
            .bytes = supplied_input.bytes[0..admitted_input],
            .final = supplied_input.final and admitted_input == supplied_input.bytes.len,
        };
        const output = supplied_output[0..admitted_output];
        if (self.eof and supplied_input.bytes.len != 0 and self.phase != .complete)
            return error.InvalidState;

        var consumed: usize = 0;
        var produced: usize = 0;
        const status: DecodeStatus = parse: while (true) switch (self.phase) {
            .header, .dictionary_id, .footer => {
                const needed: usize = if (self.phase == .header) 2 else 4;
                const count = @min(needed - self.field_bytes, input.bytes.len - consumed);
                if (count > self.work_left - consumed - produced) return error.LimitExceeded;
                @memcpy(
                    self.field[self.field_bytes..][0..count],
                    input.bytes[consumed..][0..count],
                );
                self.field_bytes += count;
                consumed += count;
                if (self.field_bytes != needed) break :parse .need_input;
                self.field_bytes = 0;
                switch (self.phase) {
                    .header => {
                        try admitHeader(self.field[0..2]);
                        const window = @as(usize, 1) << @intCast(8 + (self.field[0] >> 4));
                        try self.raw.reset(
                            .{ .workspace = self.raw.workspace, .history = self.raw.history },
                            .{ .window_bytes = @min(window, self.window_bytes), .limits = .{} },
                        );
                        self.phase = if (self.field[1] & 32 != 0) .dictionary_id else .body;
                    },
                    .dictionary_id => {
                        self.id = std.mem.readInt(u32, &self.field, .big);
                        self.phase = .dictionary;
                    },
                    .footer => {
                        const expected = std.mem.readInt(u32, &self.field, .big);
                        if (expected != self.checksum.final()) return error.InvalidStream;
                        self.phase = .complete;
                    },
                    else => unreachable,
                }
            },
            .dictionary => break :parse .need_dictionary,
            .body => {
                self.raw.work_left = self.work_left - consumed - produced;
                const result = try self.raw.step(
                    .{ .bytes = input.bytes[consumed..], .final = input.final or self.eof },
                    output[produced..],
                );
                self.checksum.update(output[produced..][0..result.produced]);
                consumed += result.consumed;
                produced += result.produced;
                switch (result.status) {
                    .need_input => break :parse .need_input,
                    .need_output => break :parse .need_output,
                    .complete => self.phase = .footer,
                }
            },
            .complete => break :parse .complete,
        };

        if (status == .need_input and admitted_input < supplied_input.bytes.len)
            return error.LimitExceeded;
        if (status == .need_output and admitted_output < supplied_output.len)
            return error.LimitExceeded;
        if (input.final and consumed == input.bytes.len) self.eof = true;
        if (status == .need_input and (input.final or self.eof)) return error.Truncated;
        self.input_bytes = std.math.add(
            u64,
            self.input_bytes,
            consumed,
        ) catch return error.CounterOverflow;
        self.output_bytes = std.math.add(
            u64,
            self.output_bytes,
            produced,
        ) catch return error.CounterOverflow;
        const work = std.math.add(u64, consumed, produced) catch return error.CounterOverflow;
        if (self.input_bytes > self.limits.input_bytes or self.output_bytes > self.limits
            .output_bytes) return error.LimitExceeded;
        if (work > self.work_left) return error.LimitExceeded;
        self.work_left -= work;
        return .{ .consumed = consumed, .produced = produced, .status = status };
    }
};

/// Drives an initialized decoder from a caller-owned Reader until output, dictionary negotiation or
/// completion. Resume with the same decoder/Reader; after need_dictionary attach the dictionary
/// before calling again. Buffered lookahead stays in the Reader, including following application
/// bytes. Use a buffered Reader for bulk throughput; zero-capacity Readers also work. ReadFailed
/// remains a transport error and poisons the decoder until reset.
pub fn decodeReader(
    reader: *std.Io.Reader,
    output: []u8,
    decoder: *Decoder,
) (DecodeError || error{ReadFailed})!DecodeProgress {
    if (decoder.failed) return error.NeedReset;
    return readImpl(reader, output, decoder) catch |err| {
        decoder.failed = true;
        return err;
    };
}

fn readImpl(
    reader: *std.Io.Reader,
    output: []u8,
    decoder: *Decoder,
) (DecodeError || error{ReadFailed})!DecodeProgress {
    var consumed: usize = 0;
    var produced: usize = 0;
    while (true) {
        const buffered = reader.buffered();
        const result = try decoder.step(.{ .bytes = buffered }, output[produced..]);
        reader.toss(result.consumed);
        consumed = std.math.add(
            usize,
            consumed,
            result.consumed,
        ) catch return error.CounterOverflow;
        produced += result.produced;
        if (result.status != .need_input) return .{
            .consumed = consumed,
            .produced = produced,
            .status = result.status,
        };
        // An empty blocked step has proved another byte necessary. This also supports Readers whose
        // vtable only streams and has no peek storage.
        if (reader.bufferedLen() != 0) continue;
        var byte: [1]u8 = undefined;
        reader.readSliceAll(&byte) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return try decoder.step(
                .{ .bytes = &.{}, .final = true },
                output[produced..],
            ),
        };
        const next = try decoder.step(.{ .bytes = &byte }, output[produced..]);
        std.debug.assert(next.consumed == 1);
        consumed = std.math.add(usize, consumed, next.consumed) catch return error.CounterOverflow;
        produced += next.produced;
        if (next.status != .need_input) return .{
            .consumed = consumed,
            .produced = produced,
            .status = next.status,
        };
    }
}

/// Attempts one stored-only zlib stream without allocating or reserving a workspace. The reader,
/// its borrowed bytes and output are disjoint. Reader storage may be empty; small headers use
/// bounded local bytes. Success checks Adler over produced output, returns its exact stream
/// boundary and leaves the output suffix and trailing input intact. Fixed/dynamic blocks return
/// null, possibly after consuming input and writing an output prefix. Recreate or rewind the reader
/// before falling back to a general decoder. Failures may also change reader/output. Premature EOF
/// is InvalidStream; transport ReadFailed remains distinct, and a stored length exceeding output is
/// OutputTooSmall.
pub fn decodeStoredReader(
    noalias reader: *std.Io.Reader,
    noalias output: []u8,
) (Error || error{ReadFailed})!?DecodeResult {
    var header: [2]u8 = undefined;
    try readStoredBytes(reader, &header);
    try validateHeader(&header);
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

fn readStoredBytes(reader: *std.Io.Reader, destination: []u8) (Error || error{ReadFailed})!void {
    reader.readSliceAll(destination) catch |err| switch (err) {
        error.EndOfStream => return error.InvalidStream,
        error.ReadFailed => return error.ReadFailed,
    };
}

fn storedLength(bytes: *const [4]u8) Error!usize {
    const length = std.mem.readInt(u16, bytes[0..2], .little);
    const complement = std.mem.readInt(u16, bytes[2..4], .little);
    if (length != ~complement) return error.InvalidStream;
    return length;
}

const FragmentReader = struct {
    interface: std.Io.Reader,
    source: []const u8,
    position: usize = 0,
    fragment: usize,
    fail_after: ?usize,

    fn init(self: *FragmentReader, source: []const u8, fragment: usize, fail_after: ?usize) void {
        std.debug.assert(fragment != 0);
        self.* = .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
            .source = source,
            .fragment = fragment,
            .fail_after = fail_after,
        };
    }

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *FragmentReader = @alignCast(@fieldParentPtr("interface", reader));
        if (self.fail_after) |end| {
            if (self.position == end) return error.ReadFailed;
        }
        if (self.position == self.source.len) return error.EndOfStream;
        const available = @min(
            self.fragment,
            self.source.len - self.position,
            if (self.fail_after) |end| end - self.position else self.source.len,
        );
        const count = limit.minInt(available);
        const written = try writer.write(self.source[self.position..][0..count]);
        self.position += written;
        return written;
    }
};

fn testZlibFrame(
    allocator: std.mem.Allocator,
    raw: []const u8,
    expected: []const u8,
    header: [2]u8,
) ![]u8 {
    const frame = try allocator.alloc(u8, raw.len + 6);
    @memcpy(frame[0..2], &header);
    @memcpy(frame[2..][0..raw.len], raw);
    var low: u32 = 1;
    var high: u32 = 0;
    for (expected) |byte| {
        low = (low + byte) % 65521;
        high = (high + low) % 65521;
    }
    std.mem.writeInt(u32, frame[frame.len - 4 ..][0..4], (high << 16) | low, .big);
    return frame;
}

// Independent RFC 1950/1951 facts: 300 literal A bytes precede a length-three match at distance
// 256, 257 or 300. The 303-byte A output has Adler-32 0xb1ba4cf0. Headers 08/1d, 18/19 and 78/01
// declare 256, 512 and 32768 bytes. No production encoder, table or checksum contributes these wire
// bytes.
const zlib_fixture = struct {
    const prefix = blk: {
        const header = [_]u8{ 0x08, 0x1d, 0x73 };
        const literals: [299]u8 = @splat(0x74);
        break :blk header ++ literals;
    };
    const footer = [_]u8{ 0xb1, 0xba, 0x4c, 0xf0 };

    /// A length-three match at the exact declared 256-byte window boundary.
    const at_boundary = blk: {
        const match = [_]u8{ 0x04, 0xfa, 0x1f, 0x00 };
        break :blk prefix ++ match ++ footer;
    };
    /// The same output with a match one byte beyond the declared window.
    const beyond_boundary = blk: {
        const match = [_]u8{ 0x04, 0x06, 0x00, 0x00 };
        break :blk prefix ++ match ++ footer;
    };
    /// The same output with a 300-byte match distance, admitted by 512-byte/full-window headers.
    const beyond_window = blk: {
        const match = [_]u8{ 0x04, 0x86, 0x15, 0x00 };
        break :blk prefix ++ match ++ footer;
    };

    /// Final ordinary dynamic block: lengths 65/66/256 are 1/2/2, distance is empty; a four-symbol
    /// two-bit precode encodes zero runs 65/138/51. Output is "AABA".
    const ordinary_complete = [_]u8{
        0x05, 0xc0, 0x01, 0x09, 0x00, 0x00, 0x00, 0x80,
        0xa0, 0x6d, 0xf6, 0x7f, 0x54, 0x90, 0x01,
    };
    /// Final dynamic block containing only length-one EOB and an empty distance tree. Precode
    /// 0/1/18 has lengths 1/2/2; zero runs are 138/118. Output is empty.
    const incomplete_eob = [_]u8{
        0x05, 0xc0, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00,
        0xa0, 0xff, 0xaf, 0x03,
    };
    /// Final dynamic block: bytes 0..14, EOB and lengths 257..272 each have five bits. Distance
    /// three uses singleton distance-code symbol 2. Output is {0,1,2,0,1,2}.
    const ordinary_payload_literals = [_]u8{
        0x85, 0xc2, 0x01, 0x09, 0x00, 0x20, 0x00, 0x00,
        0xa0, 0xaa, 0xaa, 0xaa, 0xea, 0xff, 0xdc, 0xaa,
        0xaa, 0xaa, 0xaa, 0x40, 0x00, 0x51, 0xe0, 0x01,
    };
    /// Independent expected bytes for the existing 37-bit wide-literal-group wire.
    const wide_literal_groups = blk: {
        var bytes: [70]u8 = undefined;
        bytes[0..3].* = .{ 0, 1, 2 };
        @memset(bytes[3..22], 2);
        for (22..70) |i| bytes[i] = @intCast((i - 22) % 3);
        break :blk bytes;
    };
};

const reader_stored = struct {
    // Independently authored RFC 1950/1951 stored and mixed-block wire facts. Python zlib 1.3.2
    // admits each complete wire, exact output and unused suffix. Padding bits deliberately vary.
    // The maximum wire is constructed in the owning test from these fixed headers and payload
    // formula, then checked against its independently recorded SHA-256 before decoding; no
    // production encoder is used.

    /// Four stored blocks, including empty blocks and all byte values.
    const source = &frozen_fixtures.reader_stored_zlib;
    /// Independently stated literal output of the stored blocks.
    const expected = &frozen_fixtures.reader_stored_golden;
    /// A stored ABC prefix followed by a final fixed empty block.
    const mixed = &frozen_fixtures.reader_mixed_zlib;
    /// A final empty stored block with nonzero discarded padding bits.
    const empty = &frozen_fixtures.reader_empty_zlib;
    /// Complete uncompressed size across maximum 65535-byte and final 257-byte blocks.
    const maximum_output = 65535 + 257;
    /// Independent Python zlib Adler value over (i*29+i/31)&255 for every output byte.
    const maximum_adler = 0x3a03f7e9;
    /// Independent complete-wire SHA-256; the owning test reconstructs this exact source.
    const maximum_sha256 = "802d12b0427b2b520670af9e5c719679a8b95b3cdf2fc04bcc0b9b952debd2ed";
};

// Independent RFC 1950 framing and Reader fixtures, verified with Python zlib 1.3.2. Raw-codec
// facts stay with deflate/fixtures.zig. Repetition expands frozen bytes; no production encoder or
// checksum supplies the source or expected output. The identity test checks each full byte
// sequence.
const frozen_fixtures = struct {
    // expanded_48bit.zlib: frozen Python-zlib-verified bytes, SHA-256
    // ebb03e5a07e96a4945e0f054ef04225edbb36c81a7094a23116184db3504fdb0.
    const expanded_48bit_zlib = blk: {
        const prefix = [_]u8{ 0x78, 0x01, 0x00, 0x00, 0x80, 0xff, 0x7f };
        const fill: [32768]u8 = @splat(0x07);
        const middle = [_]u8{
            0xed, 0xfd, 0xdb, 0x92, 0x24, 0x49, 0x92, 0x2c,
            0xcb, 0xaa, 0x9a, 0x47, 0x56, 0xcf, 0xda, 0x07,
        };
        const zeros_2: [121]u8 = @splat(0x00);
        const suffix = [_]u8{
            0x40, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
            0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0xf5, 0x28,
            0x12, 0x8b, 0x9a, 0x47, 0x56, 0xcf, 0xda, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe7, 0x40,
            0x08, 0x21, 0x84, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xff, 0x0f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x40, 0x8e, 0x23, 0x8e,
            0x50,
        };
        break :blk prefix ++ fill ++ middle ++ zeros_2 ++ suffix;
    };

    // general_small_period3.zlib: frozen Python-zlib-verified bytes, SHA-256
    // 4446e627fde84e3650e18eb498d089e8233dea538969cb8901cedcc85ddd72a5.
    const general_small_period3_zlib = [_]u8{
        0x78, 0x9c, 0xed, 0xc2, 0x01, 0x09, 0x80, 0x00,
        0x00, 0x00, 0xa0, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xfa, 0x7f, 0xb2, 0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0x40, 0x00, 0x84,
        0x0a, 0x2d, 0x6d, 0x13, 0xa6, 0x4c, 0xfa, 0xfd,
        0x7e, 0xbf, 0xdf, 0xef, 0xf7, 0xfb, 0xfd, 0x7e,
        0xbf, 0xdf, 0xef, 0x77, 0x13, 0x11, 0x09, 0x7a,
        0x10, 0x30,
    };

    // general_small_period5.zlib: frozen Python-zlib-verified bytes, SHA-256
    // c52ef548ce27c0bb45ab88bcdee4e93d434beb9519eab905bf542b6702fa4bc0.
    const general_small_period5_zlib = [_]u8{
        0x78, 0x9c, 0xed, 0xc4, 0x01, 0x09, 0x80, 0x00,
        0x00, 0x00, 0xa0, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xfa, 0x7f, 0xb2, 0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0x00, 0x04, 0x40,
        0x08, 0x46, 0x0a, 0x5a, 0xb4, 0x99, 0x60, 0x8a,
        0x49, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e,
        0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e,
        0x6e, 0x41, 0x04, 0xf7, 0xea, 0x20, 0x5c,
    };

    // general_small_period6.zlib: frozen Python-zlib-verified bytes, SHA-256
    // 00da5b3d1638b7bfccaa1b8dc2930b1f13948f41b029c5a71f7ba9251f58d0b1.
    const general_small_period6_zlib = [_]u8{
        0x78, 0x9c, 0xed, 0xc4, 0x01, 0x09, 0x80, 0x00,
        0x00, 0x00, 0xa0, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xfa, 0x7f, 0xb2, 0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0x00, 0x04, 0x40,
        0x08, 0x46, 0xd0, 0xc2, 0x96, 0x6d, 0x27, 0x9c,
        0x72, 0xd2, 0xdf, 0xdf, 0xdf, 0xdf, 0xdf, 0xdf,
        0xdf, 0xdf, 0xdf, 0xdf, 0xdf, 0xdf, 0xdf, 0xdf,
        0xdf, 0x3b, 0x18, 0x01, 0x6b, 0x26, 0x28, 0x72,
    };

    // general_small_period7.zlib: 65 bytes, SHA-256
    // a1ef32bce88a57a52dabae2e4866f72ac89158c7c14bfe259685c2c1a42bfca9.
    const general_small_period7_zlib = [_]u8{
        0x78, 0x9c, 0xed, 0xc5, 0x01, 0x09, 0x80, 0x00,
        0x00, 0x00, 0xa0, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xfa, 0x7f, 0xb2, 0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0x00, 0x10, 0x00,
        0x21, 0x18, 0x41, 0xb1, 0x82, 0x16, 0x6d, 0x26,
        0x98, 0x62, 0x92, 0x9f, 0x9f, 0x9f, 0x9f, 0x9f,
        0x9f, 0x9f, 0x9f, 0x9f, 0x9f, 0x9f, 0x9f, 0x9f,
        0x9f, 0x9f, 0x1b, 0x10, 0x01, 0xdb, 0x9f, 0x30,
        0x8b,
    };

    // ordinary_guard_distance2.zlib: frozen Python-zlib-verified bytes, SHA-256
    // 87c5ffbeecce3a625b438b2a61b26c57060457915a1fceb3a4c137a9d9f761f7.
    const ordinary_guard_distance2_zlib = [_]u8{
        0x78, 0x9c, 0xed, 0xc1, 0xb7, 0x0d, 0xc3, 0x00,
        0x00, 0x03, 0x30, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6,
        0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6, 0x6d, 0xfb,
        0xff, 0x27, 0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6,
        0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0x06, 0x01, 0xb0,
        0xd0, 0xd2, 0x36, 0x61, 0xca, 0xa4, 0xdf, 0xef,
        0xf7, 0xfb, 0xfd, 0x7e, 0xbf, 0xdf, 0xef, 0xf7,
        0xfb, 0xfd, 0x7e, 0x77, 0x11, 0x01, 0x8e, 0x26,
        0x08, 0x18,
    };

    // ordinary_guard_distance4.zlib: frozen Python-zlib-verified bytes, SHA-256
    // 3e8ec7472e97a31d39f70a0e4f4df1ba7ad281ffc41f9924e0cddf1b60a9f629.
    const ordinary_guard_distance4_zlib = [_]u8{
        0x78, 0x9c, 0xed, 0xc3, 0xb7, 0x0d, 0xc3, 0x00,
        0x00, 0x03, 0x30, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6,
        0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6, 0x6d, 0xfb,
        0xff, 0x27, 0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6,
        0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0x06, 0x40, 0x00,
        0x84, 0xe0, 0x42, 0x4b, 0xdb, 0x84, 0x29, 0x93,
        0x7e, 0xbf, 0xdf, 0xef, 0xf7, 0xfb, 0xfd, 0x7e,
        0xbf, 0xdf, 0xef, 0xf7, 0xfb, 0xdd, 0x43, 0x04,
        0x82, 0x0b, 0x18, 0x46,
    };

    // ordinary_guard_distance9.zlib: frozen Python-zlib-verified bytes, SHA-256
    // 7656f6b5336da8c57fceb80a6528e769ed38907105bef8d870b01f3f7778851c.
    const ordinary_guard_distance9_zlib = [_]u8{
        0x78, 0x9c, 0xed, 0xc6, 0xb7, 0x0d, 0xc3, 0x00,
        0x00, 0x03, 0x30, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6,
        0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6, 0x6d, 0xfb,
        0xff, 0x27, 0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6,
        0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0x06, 0x00, 0x80,
        0x00, 0x08, 0xc1, 0x08, 0x8a, 0xe1, 0x44, 0x81,
        0x16, 0xda, 0x98, 0xc0, 0x14, 0x26, 0xf1, 0xe3,
        0xc7, 0x8f, 0x1f, 0x3f, 0x7e, 0xfc, 0xf8, 0xf1,
        0xe3, 0xc7, 0x8f, 0x1f, 0x3f, 0x7e, 0xfc, 0xb8,
        0x1c, 0x11, 0xb4, 0x90, 0x40, 0xb4,
    };

    // ordinary_guard_width3_period3.zlib: frozen Python-zlib-verified bytes, SHA-256
    // 5dde43e33e25b712d4107c190a155cd09c8d7dcfaaa464a5d08e1f8c92ab7b75.
    const ordinary_guard_width3_period3_zlib = [_]u8{
        0x78, 0x9c, 0xed, 0xc2, 0xb7, 0x0d, 0xc3, 0x00,
        0x00, 0x03, 0xb0, 0x24, 0x49, 0x92, 0x24, 0x49,
        0x6c, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6, 0x6d, 0xfb,
        0xff, 0x27, 0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6,
        0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0x02, 0x78, 0x3a,
        0x5f, 0x22, 0x39, 0x79, 0x0d, 0x9a, 0x34, 0x02,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x95,
        0x70, 0x00, 0x09, 0x7a, 0x10, 0x30,
    };

    // ordinary_guard_width7_period3.zlib: frozen Python-zlib-verified bytes, SHA-256
    // 6f4c0f99c0344f5ee97246fae157cb439695448bd55d4cfe2e83f1a6bda9402b.
    const ordinary_guard_width7_period3_zlib = [_]u8{
        0x78, 0x9c, 0xed, 0xc2, 0xb7, 0x0d, 0xc3, 0x00,
        0x00, 0x03, 0x30, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6,
        0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6, 0x6d, 0x3b,
        0xff, 0x1f, 0x69, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6,
        0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0x0e, 0x40, 0x00,
        0x84, 0x0a, 0x2d, 0x6d, 0x13, 0xa6, 0x4c, 0xfa,
        0xfb, 0xfb, 0xfb, 0xfb, 0xfb, 0xfb, 0xfb, 0xfb,
        0xfb, 0xfb, 0xfb, 0xfb, 0xfb, 0xfb, 0xbb, 0x89,
        0x08, 0x09, 0x7a, 0x10, 0x30,
    };

    // reader_empty.zlib: 11 bytes, SHA-256
    // 5cde4521f669f961047a2a0e6fe27487a15c68a8d5bf9e40cdc5533d7dd873b2.
    const reader_empty_zlib = [_]u8{
        0x78, 0x01, 0xf9, 0x00, 0x00, 0xff, 0xff, 0x00,
        0x00, 0x00, 0x01,
    };

    // reader_mixed.zlib: 16 bytes, SHA-256
    // 0e14a635f91c09519f9e15baa8d9e97ed9291a7ceb1dee1f9746e12c0b3117b8.
    const reader_mixed_zlib = [_]u8{
        0x78, 0x01, 0x90, 0x03, 0x00, 0xfc, 0xff, 0x41,
        0x42, 0x43, 0x03, 0x00, 0x01, 0x8d, 0x00, 0xc7,
    };

    // reader_stored.golden: 279 bytes, SHA-256
    // f612c80d616ecff12457a51f5251fc92f52b1228189f92be1eb99d7417820638.
    const reader_stored_golden = [_]u8{
        0x66, 0x72, 0x61, 0x67, 0x6d, 0x65, 0x6e, 0x74,
        0x65, 0x64, 0x20, 0x73, 0x74, 0x6f, 0x72, 0x65,
        0x64, 0x20, 0x64, 0x61, 0x74, 0x61, 0x00, 0x00,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30,
        0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
        0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40,
        0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50,
        0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
        0x59, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x60,
        0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70,
        0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
        0x79, 0x7a, 0x7b, 0x7c, 0x7d, 0x7e, 0x7f, 0x80,
        0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88,
        0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f, 0x90,
        0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
        0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f, 0xa0,
        0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8,
        0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf, 0xb0,
        0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8,
        0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xc0,
        0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8,
        0xc9, 0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf, 0xd0,
        0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8,
        0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf, 0xe0,
        0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8,
        0xe9, 0xea, 0xeb, 0xec, 0xed, 0xee, 0xef, 0xf0,
        0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff,
    };

    // reader_stored.zlib: 305 bytes, SHA-256
    // bcad0394689add13dfb203f44cf75156170b8016656df9e4ee32054ea5479797.
    const reader_stored_zlib = [_]u8{
        0x78, 0x01, 0xa0, 0x00, 0x00, 0xff, 0xff, 0x20,
        0x16, 0x00, 0xe9, 0xff, 0x66, 0x72, 0x61, 0x67,
        0x6d, 0x65, 0x6e, 0x74, 0x65, 0x64, 0x20, 0x73,
        0x74, 0x6f, 0x72, 0x65, 0x64, 0x20, 0x64, 0x61,
        0x74, 0x61, 0xd8, 0x00, 0x00, 0xff, 0xff, 0xf9,
        0x01, 0x01, 0xfe, 0xfe, 0x00, 0x00, 0x01, 0x02,
        0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
        0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12,
        0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a,
        0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x22,
        0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a,
        0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32,
        0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a,
        0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40, 0x41, 0x42,
        0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a,
        0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x51, 0x52,
        0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a,
        0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62,
        0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a,
        0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72,
        0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a,
        0x7b, 0x7c, 0x7d, 0x7e, 0x7f, 0x80, 0x81, 0x82,
        0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a,
        0x8b, 0x8c, 0x8d, 0x8e, 0x8f, 0x90, 0x91, 0x92,
        0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a,
        0x9b, 0x9c, 0x9d, 0x9e, 0x9f, 0xa0, 0xa1, 0xa2,
        0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa,
        0xab, 0xac, 0xad, 0xae, 0xaf, 0xb0, 0xb1, 0xb2,
        0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba,
        0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xc0, 0xc1, 0xc2,
        0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca,
        0xcb, 0xcc, 0xcd, 0xce, 0xcf, 0xd0, 0xd1, 0xd2,
        0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
        0xdb, 0xdc, 0xdd, 0xde, 0xdf, 0xe0, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
        0xeb, 0xec, 0xed, 0xee, 0xef, 0xf0, 0xf1, 0xf2,
        0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
        0xfb, 0xfc, 0xfd, 0xfe, 0xff, 0xa3, 0x3f, 0x88,
        0x09,
    };

    // window_period9.zlib: frozen Python-zlib-verified bytes, SHA-256
    // 9cc64695c96dd6ed0b74e31e230e2841dbc194784b496cc332a1ee63e1bf1c8e.
    const window_period9_zlib = blk: {
        const prefix = [_]u8{
            0x78, 0x9c, 0xed, 0xc6, 0x31, 0x01, 0x00, 0x20,
            0x08, 0x00, 0xb0, 0x93, 0x26, 0x34, 0xb1, 0x89,
            0x4d, 0x68, 0x62, 0x13, 0x9b, 0xd0, 0x04, 0x2b,
            0x18, 0x60, 0xbb, 0x16, 0xb9, 0x76, 0x9d, 0xdb,
            0x13,
        };
        const fill: [8128]u8 = @splat(0x22);
        const suffix = [_]u8{ 0xf2, 0x91, 0x07, 0xe7, 0x23, 0x03, 0x6c };
        break :blk prefix ++ fill ++ suffix;
    };

    // window_period24.zlib: frozen Python-zlib-verified bytes, SHA-256
    // f91421786da34878cdecfce1bfab15f6b2379b5939c15158f63241f2104e0f09.
    const window_period24_zlib = blk: {
        const prefix = [_]u8{
            0x78, 0x9c, 0xed, 0xc8, 0xa1, 0x01, 0x40, 0x40,
            0x00, 0x00, 0xc0, 0xf8, 0x1b, 0x7c, 0x14, 0x7f,
            0x03, 0x51, 0xb4, 0x81, 0x28, 0xda, 0x40, 0x14,
            0x6d, 0x20, 0x8a, 0xbf, 0x81, 0x28, 0xda, 0xe0,
            0xe3, 0x47, 0x5b, 0x88, 0x2c, 0x60, 0x84, 0xbb,
            0x78, 0x21, 0xf5, 0xd3, 0x9a, 0xaf, 0xfb, 0x6d,
            0xba, 0x71, 0xd9, 0xcf, 0xfa, 0xc4, 0x76, 0x98,
            0xb7, 0xa3, 0x04,
        };
        const pattern = [_]u8{ 0xef, 0xbd, 0xf7, 0xde, 0x7b };
        const copies: [2032][pattern.len]u8 = @splat(pattern);
        const repeated: [2032 * pattern.len]u8 = @bitCast(copies);
        const suffix = [_]u8{ 0xff, 0xf7, 0x1f, 0xf1, 0x64, 0x4f, 0xca };
        break :blk prefix ++ repeated ++ suffix;
    };
};

test "zlib declared windows admit their boundary and reject farther whole-buffer matches" {
    const fixture = zlib_fixture;
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var output: [307]u8 = @splat(0xa5);

    const boundary = try decode(&fixture.at_boundary, &output, .{ .workspace = workspace }, .{});
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
            decode(source, &output, .{ .workspace = workspace }, .{}),
        );
        for (output[300..]) |byte| try std.testing.expectEqual(0xa5, byte);

        // Reuse after refusal with independently stated valid larger-window headers.
        var admitted = source.*;
        for ([_][2]u8{ .{ 0x18, 0x19 }, .{ 0x78, 0x01 } }) |header| {
            @memcpy(admitted[0..2], &header);
            @memset(&output, 0xa5);
            const result = try decode(&admitted, &output, .{ .workspace = workspace }, .{});
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
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const cases = [_]struct {
        source: []const u8,
        expected: []const u8,
    }{
        .{
            .source = &fixture.ordinary_complete,
            .expected = "AABA",
        },
        .{ .source = &fixture.incomplete_eob, .expected = "" },
        .{ .source = &fixture.ordinary_payload_literals, .expected = &.{ 0, 1, 2, 0, 1, 2 } },
        .{
            .source = paired.source,
            .expected = paired.expected,
        },
        .{
            .source = dense.source,
            .expected = dense.expected,
        },
        .{
            .source = general.source,
            .expected = general.expected,
        },
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
        const result = try decode(source, output, .{ .workspace = workspace }, .{});
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
            decode(refused, output, .{ .workspace = workspace }, .{}),
        );
        for (output[expected.len..]) |byte| try std.testing.expectEqual(0xa5, byte);
        const admitted = try testZlibFrame(allocator, raw, expected, .{ 0x78, 0x01 });
        defer allocator.free(admitted);
        const result = try decode(admitted, output, .{ .workspace = workspace }, .{});
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
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // RFC 1950 wrapper around a stored 1x1 filtered RGBA row (0,1,2,3,4).
    const source = [_]u8{ 0x78, 1, 1, 5, 0, 250, 255, 0, 1, 2, 3, 4, 0, 25, 0, 11 };
    var output: [5]u8 = undefined;
    const result = try decode(&source, &output, .{ .workspace = workspace }, .{});
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4 }, &output);
    try std.testing.expectEqual(source.len, result.consumed);
    try std.testing.expectEqual(output.len, result.produced);
    try std.testing.expectEqual(
        source.len,
        (try decode(source ++ "unused", &output, .{ .workspace = workspace }, .{})).consumed,
    );
    for (0..source.len) |length| {
        try std.testing.expectError(
            error.InvalidStream,
            decode(source[0..length], &output, .{ .workspace = workspace }, .{}),
        );
    }
    for ([_]usize{ 0, 1, 12, 13, 14, 15 }) |index| {
        var mutated = source;
        mutated[index] ^= 1;
        try std.testing.expectError(
            error.InvalidStream,
            decode(&mutated, &output, .{ .workspace = workspace }, .{}),
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
                    decodeStoredReader(&input.interface, target),
                );
            } else {
                const decoded = try decodeStoredReader(&input.interface, target);
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
                decodeStoredReader(&input.interface, output),
            );
        }
        var input: FragmentReader = undefined;
        input.init(fixture.source ++ "UNUSED", fragment, null);
        const decoded = try decodeStoredReader(&input.interface, output);
        const result = decoded orelse return error.StoredFixtureDeclined;
        try std.testing.expectEqual(fixture.source.len, result.consumed);
        try std.testing.expectEqual(fixture.source.len, input.position);
    }
    for (0..32) |alignment| {
        @memset(output, 0xa5);
        var input: std.Io.Reader = .fixed(fixture.source);
        const decoded = try decodeStoredReader(
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
    const decoded = try decodeStoredReader(&empty, &.{});
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
    try std.testing.expectEqual(null, try decodeStoredReader(&mixed.interface, &output));
    try std.testing.expectEqualSlices(u8, "ABC", output[0..3]);
    for (output[3..]) |byte| try std.testing.expectEqual(0xa5, byte);
    const workspace = try DecoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    const general = try decode(fixture.mixed, &output, .{ .workspace = workspace }, .{});
    try std.testing.expectEqual(fixture.mixed.len, general.consumed);
    try std.testing.expectEqual(3, general.produced);

    for (0..fixture.source.len) |fail_after| {
        var failed: FragmentReader = undefined;
        failed.init(fixture.source, 7, fail_after);
        try std.testing.expectError(
            error.ReadFailed,
            decodeStoredReader(&failed.interface, &output),
        );
    }
    for ([_]usize{ 0, 1, 5, fixture.source.len - 1 }) |offset| {
        var source: [fixture.source.len]u8 = fixture.source.*;
        source[offset] ^= 1;
        var input: std.Io.Reader = .fixed(&source);
        try std.testing.expectError(error.InvalidStream, decodeStoredReader(&input, &output));
    }
    var reserved: std.Io.Reader = .fixed(&.{ 0x78, 1, 7 });
    try std.testing.expectError(error.InvalidStream, decodeStoredReader(&reserved, &output));
    for ([_]u8{ 3, 5 }) |block| {
        @memset(&output, 0xa5);
        var compressed: std.Io.Reader = .fixed(&.{ 0x78, 1, block });
        try std.testing.expectEqual(null, try decodeStoredReader(&compressed, &output));
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
                    decodeStoredReader(&input.interface, target),
                );
            } else {
                const decoded = try decodeStoredReader(&input.interface, target);
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
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const framed = &frozen_fixtures.general_small_period7_zlib;
    const decoded_bytes = 4096 + 47;
    const larger = try allocator.alloc(u8, decoded_bytes + 34);
    defer allocator.free(larger);
    @memset(larger, 0xa5);
    const result = try decode(
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
        decode(
            framed,
            larger[1..][0 .. decoded_bytes + 1],
            .{ .workspace = workspace },
            .{ .output_size = .exact },
        ),
    );
    try std.testing.expectError(
        error.OutputTooSmall,
        decode(
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
        decode(
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
                        decodeStoredReader(&input.interface, output),
                    );
                } else {
                    const decoded = try decodeStoredReader(&input.interface, output);
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
            try std.testing.expectError(error.InvalidStream, decodeStoredReader(&input, output));
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
    const valid_headers = [_][2]u8{ .{ 0x08, 0x1d }, .{ 0x18, 0x19 }, .{ 0x78, 0x01 } };
    for (valid_headers) |header| try validateHeader(&header);
    for ([_][2]u8{
        .{ 0x00, 0x00 }, // Unsupported compression method.
        .{ 0x88, 0x00 }, // Declared window exceeds 32 KiB.
        .{ 0x78, 0x20 }, // Valid FCHECK with a preset dictionary.
        .{ 0x78, 0x00 }, // Invalid FCHECK.
    }) |header| try std.testing.expectError(error.InvalidStream, validateHeader(&header));

    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
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
            decode(&source, source[0..2], .{ .workspace = workspace }, .{ .output_size = extent }),
        );
        try std.testing.expectError(
            error.StorageOverlap,
            decode(&source, state, .{ .workspace = workspace }, .{ .output_size = extent }),
        );
        try std.testing.expectEqualSlices(u8, &original, &source);
        try std.testing.expect(std.mem.allEqual(u8, state, 0x6d));
        @memcpy(state[0..source.len], &source);
        try std.testing.expectError(
            error.StorageOverlap,
            decode(
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
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var output: [304]u8 = @splat(0xa5);
    const result = try decode(
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
            decode(source, output[0..303], .{ .workspace = workspace }, .{ .output_size = .exact }),
        );
        try std.testing.expect(std.mem.allEqual(u8, output[300..], 0xa5));
        var admitted: [zlib_fixture.beyond_window.len]u8 = undefined;
        @memcpy(&admitted, source);
        admitted[0..2].* = .{ 0x18, 0x19 };
        try std.testing.expectEqual(
            303,
            (try decode(
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
    const workspace = try DecoderWorkspace.create(allocator);
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
        const result = try decode(fixture.wire, output, .{ .workspace = workspace }, .{});
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
            decode(fixture.wire, output[0 .. size - 1], .{ .workspace = workspace }, .{}),
        );
        for (backing[64 + size - 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "zlib ordinary small periods retain phase and exact bounds" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
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
            const result = try decode(source, output, .{ .workspace = workspace }, .{});
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
            decode(source, backing[1..][0 .. output_bytes - 1], .{ .workspace = workspace }, .{}),
        );
        try std.testing.expectEqual(0xa5, backing[0]);
        for (backing[output_bytes..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "zlib repetition admission respects length widths and distance exclusions" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
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
            const result = try decode(source, output, .{ .workspace = workspace }, .{});
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
            decode(source, backing[1..][0 .. output_bytes - 1], .{ .workspace = workspace }, .{}),
        );
        try std.testing.expectEqual(0xa5, backing[0]);
        for (backing[output_bytes..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "zlib small windows preserve wide short-match streams" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
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
        const decoded = try decode(
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
    const workspace = try DecoderWorkspace.create(allocator);
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
        const result = try decode(
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
    const workspace = try DecoderWorkspace.create(allocator);
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
                    if (exact) break :blk decode(
                        bytes,
                        output,
                        .{ .workspace = workspace },
                        .{ .output_size = .exact },
                    );
                    break :blk decode(bytes, output, .{ .workspace = workspace }, .{});
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
            decode(
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

test "resumable zlib and Reader decode stored fixed dynamic and every short split" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var decoder: Decoder = undefined;
    const expected = try allocator.alloc(u8, 40000);
    defer allocator.free(expected);
    const output = try allocator.alloc(u8, 40008);
    defer allocator.free(output);
    const wires = [_][]const u8{
        &frozen_fixtures.reader_stored_zlib,
        &frozen_fixtures.reader_mixed_zlib,
        &frozen_fixtures.reader_empty_zlib,
    };
    for (wires) |wire| {
        const result = try decode(wire, expected, .{ .workspace = workspace }, .{});
        for (0..wire.len + 1) |split| {
            try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
            var first = try decoder.step(.{ .bytes = wire[0..split] }, output[0..0]);
            var consumed = first.consumed;
            var produced = first.produced;
            while (first.status != .complete) {
                first = try decoder.step(
                    .{ .bytes = wire[consumed..], .final = true },
                    output[produced..][0..@min(3, output.len - produced)],
                );
                consumed += first.consumed;
                produced += first.produced;
            }
            try std.testing.expectEqual(wire.len, consumed);
            try std.testing.expectEqualSlices(
                u8,
                expected[0..result.produced],
                output[0..produced],
            );
        }
        for ([_]usize{ 1, 2, 7, 65536 }) |fragment| {
            var reader: FragmentReader = undefined;
            reader.init(wire, fragment, null);
            try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
            const read = try decodeReader(&reader.interface, output, &decoder);
            try std.testing.expectEqual(DecodeStatus.complete, read.status);
            try std.testing.expectEqual(wire.len, read.consumed);
            try std.testing.expectEqualSlices(
                u8,
                expected[0..result.produced],
                output[0..read.produced],
            );
        }
        for (0..wire.len) |end| {
            try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
            try std.testing.expectError(
                error.Truncated,
                decoder.step(.{ .bytes = wire[0..end], .final = true }, output),
            );
        }
    }
    var reader: FragmentReader = undefined;
    reader.init(wires[0], 1, 2);
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    try std.testing.expectError(
        error.ReadFailed,
        decodeReader(&reader.interface, output, &decoder),
    );
    try std.testing.expectError(error.NeedReset, decodeReader(&reader.interface, output, &decoder));
}

test "zlib dictionary negotiation verifies the complete dictionary before suffix copying" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var decoder: Decoder = undefined;
    var output: [8]u8 = undefined;
    // RFC header with FDICT, Adler-32("A"), fixed length3/distance1, then Adler-32("AAA").
    // Independently accepted by zlib 1.3.2.
    const wire = [_]u8{
        0x78, 0x20, 0x00, 0x42, 0x00, 0x42, 0x03, 0x02,
        0x00, 0x01, 0x89, 0x00, 0xc4,
    };
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    const request = try decoder.step(.{ .bytes = &wire, .final = true }, &output);
    try std.testing.expectEqual(DecodeStatus.need_dictionary, request.status);
    try std.testing.expectEqual(6, request.consumed);
    try std.testing.expectEqual(@as(?u32, 0x00420042), decoder.dictionaryId());
    try decoder.setDictionary("A");
    const result = try decoder.step(.{ .bytes = wire[request.consumed..], .final = true }, &output);
    try std.testing.expectEqual(DecodeStatus.complete, result.status);
    try std.testing.expectEqualStrings("AAA", output[0..result.produced]);
    const whole = try decode(
        &wire,
        &output,
        .{ .workspace = workspace, .history = history },
        .{ .dictionary = "A" },
    );
    try std.testing.expectEqual(wire.len, whole.consumed);
    try std.testing.expectEqualStrings("AAA", output[0..whole.produced]);
    const buffers: DecodeStorage = .{ .workspace = workspace, .history = history };
    _ = try decode(
        &wire,
        output[0..3],
        buffers,
        .{ .dictionary = "A", .output_size = .exact, .trailing_data = .reject },
    );
    const followed = wire ++ [_]u8{0x00};
    _ = try decode(
        &followed,
        output[0..3],
        buffers,
        .{
            .dictionary = "A",
            .output_size = .exact,
            .limits = .{ .input_bytes = wire.len, .output_bytes = 3, .work_units = wire.len + 3 },
        },
    );
    try std.testing.expectError(
        error.InvalidStream,
        decode(&followed, output[0..3], buffers, .{ .dictionary = "A", .trailing_data = .reject }),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        decode(
            &wire,
            &output,
            buffers,
            .{ .dictionary = "A", .limits = .{ .input_bytes = wire.len - 1 } },
        ),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        decode(
            &wire,
            &output,
            buffers,
            .{ .dictionary = "A", .limits = .{ .work_units = wire.len + 2 } },
        ),
    );
    try std.testing.expectError(
        error.WrongDictionary,
        decode(&wire, &output, buffers, .{ .dictionary = "B" }),
    );
    @memset(&output, 0xa5);
    try std.testing.expectError(
        error.InvalidOptions,
        decode(&wire, &output, .{ .workspace = workspace }, .{ .dictionary = "A" }),
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    _ = try decoder.step(.{ .bytes = wire[0..6], .final = true }, &output);
    try std.testing.expectError(error.WrongDictionary, decoder.setDictionary("B"));
    try std.testing.expectError(error.NeedReset, decoder.step(.{ .bytes = &wire }, &output));
    // EOF at a dictionary request is a resource request until attachment.
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    _ = try decoder.step(.{ .bytes = wire[0..6], .final = true }, &output);
    try decoder.setDictionary("A");
    try std.testing.expectError(error.Truncated, decoder.step(.{ .bytes = &.{} }, &output));
    var lookahead = std.Io.Reader.fixed(wire ++ "next");
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    const requested = try decodeReader(&lookahead, &output, &decoder);
    try std.testing.expectEqual(DecodeStatus.need_dictionary, requested.status);
    try decoder.setDictionary("A");
    _ = try decodeReader(&lookahead, &output, &decoder);
    try std.testing.expectEqualStrings("next", lookahead.buffered());
}

test "zlib cumulative limits include framing and Reader resumes output stalls" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const wire = &frozen_fixtures.reader_mixed_zlib;
    var output: [64]u8 = undefined;
    const whole = try decode(wire, &output, .{ .workspace = workspace }, .{});
    var decoder: Decoder = undefined;
    for (0..wire.len + whole.produced) |work| {
        try decoder.reset(
            .{ .workspace = workspace, .history = history },
            .{ .limits = .{ .work_units = work } },
        );
        try std.testing.expectError(
            error.LimitExceeded,
            decoder.step(.{ .bytes = wire, .final = true }, &output),
        );
    }
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .limits = .{ .work_units = wire.len + whole.produced } },
    );
    var reader = std.Io.Reader.fixed(wire ++ "lookahead");
    var produced: usize = 0;
    var consumed: usize = 0;
    while (true) {
        const result = try decodeReader(&reader, output[produced..][0..1], &decoder);
        produced += result.produced;
        consumed += result.consumed;
        if (result.status == .complete) break;
        try std.testing.expectEqual(DecodeStatus.need_output, result.status);
    }
    try std.testing.expectEqual(whole.produced, produced);
    try std.testing.expectEqual(wire.len, consumed);
    try std.testing.expectEqualStrings("lookahead", reader.buffered());
    try std.testing.expectEqual(@as(u64, 0), decoder.work_left);
}

test "narrow literal and wide expanded wires preserve framing and spare output" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
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
                    if (exact) break :blk try decode(
                        source,
                        output,
                        .{ .workspace = workspace },
                        .{ .output_size = .exact },
                    );
                    break :blk try decode(source, output, .{ .workspace = workspace }, .{});
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
            decode(source, backing[0..fixture.expected.len], .{ .workspace = workspace }, .{}),
        );
        source[frame.len - 1] ^= 1;
        const reused = try decode(
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
    const workspace = try DecoderWorkspace.create(allocator);
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
        const result = try decode(input[0..length], output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(encoded.len, result.consumed);
        try std.testing.expectEqual(expected.len, result.produced);
        try std.testing.expectEqualSlices(u8, expected, output[0..result.produced]);
        for (backing[0..31]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (backing[31 + result.produced ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        try std.testing.expectError(
            error.InvalidStream,
            decode(
                input[0..length],
                output,
                .{ .workspace = workspace },
                .{ .output_size = .exact },
            ),
        );
    }
}

// Python zlib 1.3.2, ordinary RFC 1950 framing; the repeated payload requires LZ history.
const transferred_wire =
    "\x78\x9c\x4b\x4e\xcc\xc9\x49\x2d\xd2\xcd\x2f\xcf\x4b\x4d\x51\xc8\xc8\x2c\x2e\xc9\x2f\xaa" ++
    "\x54\x48\x1e\x15\x1c\x15\x1c\x15\x1c\x15\x1c\x15\x24\x24\x08\x00\x6e\x45\x03\xdf";

test "zlib decoder transfers exclusive state between calls" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const original = try allocator.create(Decoder);
    defer allocator.destroy(original);
    const transferred = try allocator.create(Decoder);
    defer allocator.destroy(transferred);
    const expected = "caller-owned history ";
    const output = try allocator.alloc(u8, expected.len * 64);
    defer allocator.free(output);

    try original.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    const first = try original.step(
        .{ .bytes = transferred_wire[0 .. transferred_wire.len / 2] },
        output[0..17],
    );
    try std.testing.expect(first.status != .complete);
    transferred.* = original.*;
    @memset(std.mem.asBytes(original), 0xa5);

    var consumed = first.consumed;
    var produced = first.produced;
    while (true) {
        const progress = try transferred.step(
            .{ .bytes = transferred_wire[consumed..], .final = true },
            output[produced..],
        );
        consumed += progress.consumed;
        produced += progress.produced;
        if (progress.status == .complete) break;
        try std.testing.expect(progress.consumed != 0 or progress.produced != 0);
    }
    try std.testing.expectEqual(transferred_wire.len, consumed);
    try std.testing.expectEqual(expected.len * 64, produced);
    for (0..64) |i| {
        const restored = output[i * expected.len ..][0..expected.len];
        try std.testing.expectEqualSlices(u8, expected, restored);
    }
}
