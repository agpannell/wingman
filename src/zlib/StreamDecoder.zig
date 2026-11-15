//! Resumable zlib decoding with Adler-32 verification. Call reset before use; retain tables/history
//! until reset or end of use. The small state may move between calls because all retained pointers
//! refer to those external reservations. A transfer retires the old state; do not continue two
//! copies sharing its reservations. Input/output fragments can retire after each step. No allocator
//! is retained and no operation allocates. Output remains private until checksum success.

const std = @import("std");
const adler32 = @import("../adler32.zig");
const deflate = @import("../deflate.zig");
const byte_ranges = @import("../common/byte_ranges.zig");
const format = @import("format.zig");
const test_complete = @import("decode.zig"); // Used only by inline comparison/adapter tests.
const fixtures = @import("decode_fixtures.zig");

const StreamDecoder = @This();
const Limits = deflate.decode.Limits;
const Workspace = deflate.decode.Workspace;
const overlaps = byte_ranges.overlaps;
const FragmentReader = fixtures.FragmentReader;
const frozen_fixtures = fixtures.frozen_fixtures;

// Python zlib 1.3.2, ordinary RFC 1950 framing; the repeated payload requires LZ history.
const transferred_wire = [_]u8{
    0x78, 0x9c, 0x4b, 0x4e, 0xcc, 0xc9, 0x49, 0x2d, 0xd2, 0xcd, 0x2f, 0xcf, 0x4b, 0x4d, 0x51, 0xc8,
    0xc8, 0x2c, 0x2e, 0xc9, 0x2f, 0xaa, 0x54, 0x48, 0x1e, 0x15, 0x1c, 0x15, 0x1c, 0x15, 0x1c, 0x15,
    0x1c, 0x15, 0x24, 0x24, 0x08, 0x00, 0x6e, 0x45, 0x03, 0xdf,
};

/// Resumable admission; dictionary negotiation remains `dictionaryId`/`setDictionary`.
pub const Options = struct {
    /// Maximum match distance, additionally bounded by the declared window.
    window_bytes: usize = 32768,
    /// Cumulative framing, payload and restored-byte admission.
    limits: Limits = .{},
};

/// A zlib step can suspend for a verified preset dictionary as well as I/O.
pub const Status = enum {
    /// Supply more encoded input, preserving any unconsumed suffix.
    need_input,
    /// Supply output capacity and resubmit any unconsumed input.
    need_output,
    /// Read `StreamDecoder.dictionaryId`, then attach matching bytes with
    /// `StreamDecoder.setDictionary`.
    need_dictionary,
    /// The stream and Adler-32 trailer are verified; following input remains unconsumed.
    complete,
};

/// Per-call copied counts; complete includes the verified Adler-32 trailer.
pub const Progress = struct {
    /// Accepted bytes, leaving following streams or application data untouched.
    consumed: usize,
    /// Restored bytes in the supplied output span.
    produced: usize,
    /// Resource needed next, or successful stream completion.
    status: Status,
};

/// Codec failures across reset, dictionary attachment and decoding steps. Individual methods return
/// their relevant subsets. WrongDictionary compares DICTID with the complete dictionary's Adler-32
/// before admitting matches. Failed steps and dictionary attachment require reset.
pub const Error = StepError || error{ InvalidOptions, WrongDictionary };

/// Failures while advancing a zlib stream, including its header, DEFLATE payload and checksum.
pub const StepError = error{
    InvalidStream,
    LimitExceeded,
    StorageOverlap,
    Truncated,
    NeedReset,
    InvalidState,
    CounterOverflow,
};

pub const Input = deflate.decode.StreamDecoder.Input;
pub const Storage = deflate.decode.StreamDecoder.Storage;
pub const Counts = deflate.decode.StreamDecoder.Counts;

const Phase = enum { header, dictionary_id, dictionary, body, footer, complete };

/// Raw payload state borrowing the same external reservations.
raw: deflate.decode.StreamDecoder,
/// External tables and history retained directly for framing transitions and overlap checks.
storage: Storage,
/// Framing operation to resume on the next step.
phase: Phase = .header,
/// Bounded partial header, dictionary identifier or trailer bytes.
field: [4]u8 = undefined,
/// Initialized prefix of field for the current framing operation.
field_bytes: usize = 0,
/// Requested full-dictionary Adler-32, meaningful only during dictionary negotiation.
id: u32 = 0,
/// Adler-32 over restored payload bytes only.
checksum: adler32.Hasher = .init,
/// Final input was accepted; pending output or dictionary negotiation can still drain.
eof: bool = false,
/// A failed operation requires reset before further work.
failed: bool = false,

/// Copied cumulative framing, payload and restored-byte allowances.
limits: Limits,
/// Caller match-distance cap, additionally bounded by the admitted zlib header.
window_bytes: usize,
/// Remaining combined accepted-input and restored-output allowance.
work_left: u64,

/// Accepted bytes including header, DICTID and trailer.
input_bytes: u64 = 0,
/// Restored bytes, excluding preset dictionary bytes.
output_bytes: u64 = 0,

/// Ends old stream state and starts a fresh header. Cumulative limits also include wrapper bytes.
/// No reservation contents need initialization.
pub fn reset(
    self: *StreamDecoder,
    storage: Storage,
    options: Options,
) error{ InvalidOptions, StorageOverlap }!void {
    const workspace = storage.workspace;
    const history = storage.history;
    const limits = options.limits;
    if (options.window_bytes == 0 or options.window_bytes > 32768) return error.InvalidOptions;
    if (overlaps(std.mem.asBytes(self), std.mem.asBytes(workspace))) return error.StorageOverlap;
    if (overlaps(std.mem.asBytes(self), history)) return error.StorageOverlap;
    // Initialize only the small owner; construct raw state at its address.
    self.* = .{
        .raw = undefined,
        .storage = storage,
        .limits = limits,
        .window_bytes = options.window_bytes,
        .work_left = limits.work_units,
    };
    try self.raw.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
}

/// Returns cumulative framing and payload byte accounting. A failure publishes no accepted progress
/// and does not validate provisional output.
pub fn counts(self: *const StreamDecoder) Counts {
    return .{ .input_bytes = self.input_bytes, .output_bytes = self.output_bytes };
}

/// Requested full-dictionary checksum, available only at need_dictionary.
pub fn dictionaryId(self: *const StreamDecoder) ?u32 {
    return if (!self.failed and self.phase == .dictionary) self.id else null;
}

/// Verifies the full dictionary and copies its reachable suffix into raw history. The caller can
/// retire dictionary storage immediately on return. Wrong IDs and attachment outside a request
/// poison the decoder.
pub fn setDictionary(
    self: *StreamDecoder,
    dictionary: []const u8,
) error{ NeedReset, InvalidState, WrongDictionary, StorageOverlap }!void {
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

/// Accepts arbitrary input/output fragments, including empty output while parsing headers/trailers.
/// Final input remains latched while output or a dictionary is pending. Any failure requires reset
/// before reuse.
pub fn step(self: *StreamDecoder, input: Input, output: []u8) StepError!Progress {
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

fn attach(
    self: *StreamDecoder,
    dictionary: []const u8,
) error{ NeedReset, InvalidState, WrongDictionary, StorageOverlap }!void {
    if (overlaps(dictionary, std.mem.asBytes(self))) return error.StorageOverlap;
    if (self.phase != .dictionary) return error.InvalidState;
    if (adler32.hash(dictionary) != self.id) return error.WrongDictionary;
    try self.raw.setDictionary(dictionary);
    self.phase = .body;
}

fn advance(self: *StreamDecoder, supplied_input: Input, supplied_output: []u8) StepError!Progress {
    if (overlaps(supplied_input.bytes, supplied_output)) return error.StorageOverlap;
    const reservations = .{
        std.mem.asBytes(self),
        std.mem.asBytes(self.storage.workspace),
        @as([]u8, self.storage.history),
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
    const admitted_output: usize = @intCast(@min(supplied_output.len, output_left, self.work_left));
    const input: Input = .{
        .bytes = supplied_input.bytes[0..admitted_input],
        .final = supplied_input.final and admitted_input == supplied_input.bytes.len,
    };
    const output = supplied_output[0..admitted_output];
    if (self.eof and supplied_input.bytes.len != 0 and self.phase != .complete)
        return error.InvalidState;

    var consumed: usize = 0;
    var produced: usize = 0;
    const status: Status = parse: while (true) switch (self.phase) {
        .header, .dictionary_id, .footer => {
            const needed: usize = if (self.phase == .header) 2 else 4;
            const count = @min(needed - self.field_bytes, input.bytes.len - consumed);
            if (count > self.work_left - consumed - produced) return error.LimitExceeded;
            @memcpy(self.field[self.field_bytes..][0..count], input.bytes[consumed..][0..count]);
            self.field_bytes += count;
            consumed += count;
            if (self.field_bytes != needed) break :parse .need_input;
            self.field_bytes = 0;
            switch (self.phase) {
                .header => {
                    try format.admitHeader(self.field[0..2]);
                    const window = @as(usize, 1) << @intCast(8 + (self.field[0] >> 4));
                    self.raw.reset(
                        .{ .workspace = self.storage.workspace, .history = self.storage.history },
                        .{ .window_bytes = @min(window, self.window_bytes), .limits = .{} },
                    ) catch |failure| switch (failure) {
                        // Header admission and reset each proved a nonzero window <= 32768.
                        error.InvalidOptions => unreachable,
                        error.StorageOverlap => return error.StorageOverlap,
                    };
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
            self.raw.limitWork(self.work_left - consumed - produced);
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
    if (self.input_bytes > self.limits.input_bytes or self.output_bytes > self.limits.output_bytes)
        return error.LimitExceeded;
    if (work > self.work_left) return error.LimitExceeded;
    self.work_left -= work;
    return .{ .consumed = consumed, .produced = produced, .status = status };
}

/// Drives this initialized decoder from a caller-owned Reader until output, dictionary negotiation
/// or completion. Resume with the same worker and reader; after need_dictionary attach the
/// dictionary before calling again. Buffered lookahead stays in the Reader, including following
/// application bytes. Use a buffered Reader for bulk throughput; zero-capacity Readers also work.
/// ReadFailed remains a transport error and poisons the decoder until reset.
pub fn readInto(
    self: *StreamDecoder,
    reader: *std.Io.Reader,
    output: []u8,
) (StepError || error{ReadFailed})!Progress {
    if (self.failed) return error.NeedReset;
    return readImpl(reader, output, self) catch |err| {
        self.failed = true;
        return err;
    };
}

fn readImpl(
    reader: *std.Io.Reader,
    output: []u8,
    decoder: *StreamDecoder,
) (StepError || error{ReadFailed})!Progress {
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

test "resumable zlib and Reader decode stored fixed dynamic and every short split" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var decoder: StreamDecoder = undefined;
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
        const result = try test_complete.into(wire, expected, .{ .workspace = workspace }, .{});
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
            const read = try decoder.readInto(&reader.interface, output);
            try std.testing.expectEqual(Status.complete, read.status);
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
    try std.testing.expectError(error.ReadFailed, decoder.readInto(&reader.interface, output));
    try std.testing.expectError(error.NeedReset, decoder.readInto(&reader.interface, output));
}

test "zlib dictionary negotiation verifies the complete dictionary before suffix copying" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var decoder: StreamDecoder = undefined;
    var output: [8]u8 = undefined;
    // RFC header with FDICT, Adler-32("A"), fixed length3/distance1, then Adler-32("AAA").
    // Independently accepted by zlib 1.3.2.
    const wire = [_]u8{
        0x78, 0x20, 0x00, 0x42, 0x00, 0x42, 0x03, 0x02,
        0x00, 0x01, 0x89, 0x00, 0xc4,
    };
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    const request = try decoder.step(.{ .bytes = &wire, .final = true }, &output);
    try std.testing.expectEqual(Status.need_dictionary, request.status);
    try std.testing.expectEqual(6, request.consumed);
    try std.testing.expectEqual(@as(?u32, 0x00420042), decoder.dictionaryId());
    try decoder.setDictionary("A");
    const result = try decoder.step(.{ .bytes = wire[request.consumed..], .final = true }, &output);
    try std.testing.expectEqual(Status.complete, result.status);
    try std.testing.expectEqualStrings("AAA", output[0..result.produced]);
    const whole = try test_complete.into(
        &wire,
        &output,
        .{ .workspace = workspace, .history = history },
        .{ .dictionary = "A" },
    );
    try std.testing.expectEqual(wire.len, whole.consumed);
    try std.testing.expectEqualStrings("AAA", output[0..whole.produced]);
    const buffers: test_complete.Storage = .{ .workspace = workspace, .history = history };
    _ = try test_complete.into(
        &wire,
        output[0..3],
        buffers,
        .{ .dictionary = "A", .output_size = .exact, .trailing_data = .reject },
    );
    const followed = wire ++ [_]u8{0x00};
    _ = try test_complete.into(
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
        test_complete.into(
            &followed,
            output[0..3],
            buffers,
            .{ .dictionary = "A", .trailing_data = .reject },
        ),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        test_complete.into(
            &wire,
            &output,
            buffers,
            .{ .dictionary = "A", .limits = .{ .input_bytes = wire.len - 1 } },
        ),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        test_complete.into(
            &wire,
            &output,
            buffers,
            .{ .dictionary = "A", .limits = .{ .work_units = wire.len + 2 } },
        ),
    );
    try std.testing.expectError(
        error.WrongDictionary,
        test_complete.into(&wire, &output, buffers, .{ .dictionary = "B" }),
    );
    @memset(&output, 0xa5);
    try std.testing.expectError(
        error.InvalidOptions,
        test_complete.into(&wire, &output, .{ .workspace = workspace }, .{ .dictionary = "A" }),
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
    const requested = try decoder.readInto(&lookahead, &output);
    try std.testing.expectEqual(Status.need_dictionary, requested.status);
    try decoder.setDictionary("A");
    _ = try decoder.readInto(&lookahead, &output);
    try std.testing.expectEqualStrings("next", lookahead.buffered());
}

test "zlib cumulative limits include framing and Reader resumes output stalls" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const wire = &frozen_fixtures.reader_mixed_zlib;
    var output: [64]u8 = undefined;
    const whole = try test_complete.into(wire, &output, .{ .workspace = workspace }, .{});
    var decoder: StreamDecoder = undefined;
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
        const result = try decoder.readInto(&reader, output[produced..][0..1]);
        produced += result.produced;
        consumed += result.consumed;
        if (result.status == .complete) break;
        try std.testing.expectEqual(Status.need_output, result.status);
    }
    try std.testing.expectEqual(whole.produced, produced);
    try std.testing.expectEqual(wire.len, consumed);
    try std.testing.expectEqualStrings("lookahead", reader.buffered());
    try std.testing.expectEqual(@as(u64, 0), decoder.work_left);
}

test "zlib decoder transfers exclusive state between calls" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const original = try allocator.create(StreamDecoder);
    defer allocator.destroy(original);
    const transferred = try allocator.create(StreamDecoder);
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
