//! Resumable DEFLATE decoding with retired fragments and caller-owned history.

const builtin = @import("builtin");
const std = @import("std");

const bit_io = @import("bits.zig");
const copying = @import("match.zig");
const decoding = @import("decode.zig");
const fixtures = @import("fixtures.zig");
const huffman = @import("huffman.zig");
const protocol = @import("format.zig");

const Bits = bit_io.Bits;

const Entry = huffman.Entry;
const fixed = huffman.fixed;
const leaf = huffman.leaf;

const Error = protocol.Error;
const StreamDecodeOptions = protocol.StreamDecodeOptions;
const DecodeResult = protocol.DecodeResult;
const precode_order = protocol.precode_order;

const DecoderWorkspace = decoding.DecoderWorkspace;
const decode = decoding.decode;
const disjoint = decoding.disjoint;

const copyMatch = copying.copyMatch;

const frozen_fixtures = fixtures.frozen_fixtures;
const general_pairs = fixtures.general_pairs;

/// Borrowed input for one step. `final` marks the end of this fragment as EOF; preserve it with an
/// unconsumed suffix. Once consumed, EOF stays latched while pending output drains. Accepted
/// fragments can retire immediately on return.
pub const Input = struct {
    /// Bytes available now; no input pointer is retained.
    bytes: []const u8,
    /// No source bytes follow this fragment.
    final: bool = false,
};

/// Resource or terminal boundary reached by a raw decoder step.
pub const DecodeStatus = enum {
    /// Supply more encoded input, preserving any unconsumed suffix.
    need_input,
    /// Supply output capacity and resubmit any unconsumed input.
    need_output,
    /// The raw stream ended; following container or application bytes remain unconsumed.
    complete,
};

/// Copied progress relative to one step's supplied slices.
pub const DecodeProgress = struct {
    /// Accepted source bytes, excluding following framing or lookahead.
    consumed: usize,
    /// Initialized output bytes; the remaining suffix is unchanged.
    produced: usize,
    /// Resource needed next, or successful raw-stream completion.
    status: DecodeStatus,
};

/// Cumulative limits shared by complete and resumable raw decoding.
pub const DecodeLimits = protocol.DecodeLimits;

/// Exclusive mutable reservations borrowed until the next reset or end of decoder use.
pub const StreamStorage = struct {
    /// Address-stable table reservation.
    workspace: *DecoderWorkspace,
    /// Independent 32 KiB ring history; its contents need no initialization.
    history: *[32768]u8,
};

/// Streaming errors poison the context until reset. Truncated means EOF before the raw boundary;
/// NeedReset refuses further work after any failure.
pub const DecodeError = Error || error{
    /// Final input ended before the raw stream's end marker.
    Truncated,
    /// A previous step failed; call `Decoder.reset` before continuing.
    NeedReset,
    /// The requested setup/step operation is not valid at this stream boundary.
    InvalidState,
    /// A configured cumulative input/output/work allowance was exhausted.
    LimitExceeded,
    /// Cumulative byte accounting cannot fit its u64 counters.
    CounterOverflow,
};

/// Resumable RFC 1951 decoding with caller-owned tables and 32 KiB history. Call reset before use
/// and keep workspace and history exclusively borrowed until the next reset or end of use. The
/// small context may move between calls: it retains only pointers to those external reservations,
/// never into itself, and retains neither an allocator nor source/output fragments. A transfer
/// retires the old context; never continue two copies sharing the workspace or history. The
/// context, workspace, history and each input/output span must remain mutually disjoint.
///
/// Output stays private until its owning container/checksum succeeds. Failure returns no progress
/// and requires reset. Empty output still admits headers, empty blocks and end-of-block symbols.
/// Complete leaves enclosing trailers unconsumed.
pub const Decoder = struct {
    const Phase = enum {
        block,
        stored_length,
        stored_complement,
        stored_copy,
        counts,
        precode,
        lengths,
        repeat,
        codes,
        literal,
        length_extra,
        distance,
        distance_extra,
        match,
        complete,
    };

    workspace: *DecoderWorkspace,
    history: *[32768]u8,
    window_bytes: usize,
    limits: DecodeLimits,

    phase: Phase = .block,
    hold: u64 = 0,
    held: u8 = 0,
    last: bool = false,
    fixed_codes: bool = false,
    eof: bool = false,
    failed: bool = false,
    started: bool = false,

    history_position: usize = 0,
    history_length: usize = 0,

    // Dynamic-header construction resumes at index; token phases reuse pending and extra.
    literal_count: usize = 0,
    distance_count: usize = 0,
    precode_count: usize = 0,
    index: usize = 0,
    pending: usize = 0,
    distance_value: usize = 0,
    extra: u8 = 0,
    symbol: u16 = 0,

    /// Total accepted encoded bytes in this stream.
    input_bytes: u64 = 0,
    /// Total restored bytes, excluding a supplied dictionary.
    output_bytes: u64 = 0,
    work_left: u64 = 0,

    /// Starts a new independent stream, ending all previous borrows and failure state. History
    /// contents need no initialization; no bytes are cleared. Invalid windows and overlapping
    /// reservations fail before setup.
    pub fn reset(
        self: *Decoder,
        storage: StreamStorage,
        options: StreamDecodeOptions,
    ) DecodeError!void {
        const workspace = storage.workspace;
        const history = storage.history;
        const limits = options.limits;
        try disjoint(std.mem.asBytes(self), std.mem.asBytes(workspace));
        try disjoint(std.mem.asBytes(self), history);
        try disjoint(std.mem.asBytes(workspace), history);
        if (options.window_bytes == 0 or options.window_bytes > 32768) return error.InvalidOptions;
        self.* = .{
            .workspace = workspace,
            .history = history,
            .window_bytes = options.window_bytes,
            .limits = limits,
            .work_left = limits.work_units,
        };
        if (options.dictionary) |dictionary| try self.setDictionary(dictionary);
    }

    /// Seeds a fresh stream from only the reachable suffix. The dictionary is copied, can retire on
    /// return, and is not included in output or counters. Call before the first step; wrappers own
    /// dictionary identity checks.
    pub fn setDictionary(self: *Decoder, dictionary: []const u8) DecodeError!void {
        if (self.failed) {
            @branchHint(.unlikely);
            return error.NeedReset;
        }
        self.seed(dictionary) catch |err| {
            @branchHint(.cold);
            self.failed = true;
            return err;
        };
    }

    /// Advances until input/output is needed or the raw stream ends. Repeated blocked empty calls
    /// do no work. EOF turns need_input into Truncated, including when final bytes were consumed
    /// during an earlier output stall.
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

    fn seed(self: *Decoder, dictionary: []const u8) DecodeError!void {
        if (self.started) return error.InvalidState;
        try self.admit(dictionary, &.{});
        const count = @min(dictionary.len, self.window_bytes);
        @memcpy(self.history[0..count], dictionary[dictionary.len - count ..]);
        self.history_length = count;
        self.history_position = count & 32767;
    }

    fn admit(self: *Decoder, source: []const u8, output: []u8) DecodeError!void {
        try disjoint(source, output);
        const reservations = .{
            std.mem.asBytes(self),
            std.mem.asBytes(self.workspace),
            @as([]u8, self.history),
        };
        inline for (reservations) |reservation| {
            try disjoint(source, reservation);
            try disjoint(output, reservation);
        }
    }

    fn advance(
        self: *Decoder,
        supplied_input: Input,
        supplied_output: []u8,
    ) DecodeError!DecodeProgress {
        try self.admit(supplied_input.bytes, supplied_output);
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
        self.started = true;

        var bits: Bits = .{ .source = input.bytes, .value = self.hold, .count = self.held };
        var written: usize = 0;
        const status: DecodeStatus = parse: while (true) {
            const remaining: usize = @intCast(@min(input.bytes.len, self.work_left - written));
            bits.source = input.bytes[0..remaining];
            switch (self.phase) {
                .block => {
                    const header = streamTake(&bits, 3) orelse break :parse .need_input;
                    self.last = header & 1 != 0;
                    switch (header >> 1) {
                        0 => {
                            bits.alignByte();
                            self.phase = .stored_length;
                        },
                        1 => {
                            self.fixed_codes = true;
                            self.phase = .codes;
                        },
                        2 => {
                            self.fixed_codes = false;
                            self.phase = .counts;
                        },
                        else => return error.InvalidStream,
                    }
                },
                .stored_length => {
                    self.pending = streamTake(&bits, 16) orelse break :parse .need_input;
                    self.phase = .stored_complement;
                },
                .stored_complement => {
                    const complement = streamTake(&bits, 16) orelse break :parse .need_input;
                    if (self.pending != @as(u16, ~complement)) return error.InvalidStream;
                    self.phase = .stored_copy;
                },
                .stored_copy => {
                    if (self.pending == 0) {
                        self.endBlock(&bits);
                        continue;
                    }
                    if (written == output.len) break :parse .need_output;
                    const count = @min(
                        self.pending,
                        output.len - written,
                        bits.source.len - bits.position,
                    );
                    if (count == 0) break :parse .need_input;
                    try self.checkWork(bits.position + count, written, count);
                    @memcpy(output[written..][0..count], input.bytes[bits.position..][0..count]);
                    bits.position += count;
                    written += count;
                    self.pending -= count;
                },
                .counts => {
                    const counts = streamTake(&bits, 14) orelse break :parse .need_input;
                    self.literal_count = 257 + (counts & 31);
                    self.distance_count = 1 + ((counts >> 5) & 31);
                    self.precode_count = 4 + (counts >> 10);
                    if (self.literal_count > 286) return error.InvalidStream;
                    @memset(self.workspace.lengths[0..19], 0);
                    self.index = 0;
                    self.phase = .precode;
                },
                .precode => {
                    while (self.index < self.precode_count) : (self.index += 1) {
                        const width = streamTake(&bits, 3) orelse break :parse .need_input;
                        const symbol = precode_order[self.index];
                        self.workspace.lengths[symbol] = @intCast(width);
                    }
                    _ = try self.workspace.precode.build(
                        self.workspace.lengths[0..19],
                        false,
                        false,
                    );
                    self.index = 0;
                    self.phase = .lengths;
                },
                .lengths => {
                    const total = self.literal_count + self.distance_count;
                    if (self.index == total) {
                        if (self.workspace.lengths[256] == 0) return error.InvalidStream;
                        const literal_lengths = self.workspace.lengths[0..self.literal_count];
                        const distance_lengths = self.workspace.lengths[self.literal_count..total];
                        _ = try self.workspace.literal.ordinary.build(literal_lengths, false, true);
                        _ = try self.workspace.distance.build(distance_lengths, true, true);
                        self.phase = .codes;
                        continue;
                    }
                    const decoded = try streamEntry(&self.workspace.precode, &bits);
                    const entry = decoded orelse break :parse .need_input;
                    if (entry.value < 16) {
                        self.workspace.lengths[self.index] = @intCast(entry.value);
                        self.index += 1;
                    } else {
                        if (entry.value == 16 and self.index == 0) return error.InvalidStream;
                        self.symbol = entry.value;
                        self.phase = .repeat;
                    }
                },
                .repeat => {
                    const width: u8 = switch (self.symbol) {
                        16 => 2,
                        17 => 3,
                        18 => 7,
                        else => return error.InvalidStream,
                    };
                    const extra = streamTake(&bits, width) orelse break :parse .need_input;
                    const count: usize = extra + @as(usize, if (self.symbol == 18) 11 else 3);
                    const total = self.literal_count + self.distance_count;
                    if (count > total - self.index) return error.InvalidStream;
                    const value: u8 = blk: {
                        if (self.symbol != 16) break :blk 0;
                        break :blk self.workspace.lengths[self.index - 1];
                    };
                    @memset(self.workspace.lengths[self.index..][0..count], value);
                    self.index += count;
                    self.phase = .lengths;
                },
                .codes => {
                    // Small output fragments cannot enter the bulk loop. Keep its state and budget
                    // admission out of their token path.
                    if (output.len - written >= 258 and bits.source.len - bits.position >= 8) {
                        if (self.fixed_codes) {
                            try self.fastCodes(true, &bits, output, &written);
                        } else {
                            try self.fastCodes(false, &bits, output, &written);
                        }
                    }
                    if (self.phase != .codes) continue;
                    const entry = blk: {
                        if (self.fixed_codes) {
                            const decoded = try streamEntry(&fixed.literal, &bits);
                            const raw = decoded orelse break :parse .need_input;
                            break :blk leaf(.literal_length, raw.value, @intCast(raw.bits));
                        }
                        const decoded = try streamEntry(&self.workspace.literal.ordinary, &bits);
                        break :blk decoded orelse break :parse .need_input;
                    };
                    if (entry.value < 256) {
                        self.symbol = entry.value;
                        self.phase = .literal;
                    } else if (entry.value == 256) {
                        self.endBlock(&bits);
                    } else {
                        if (entry.value == 65535) return error.InvalidStream;
                        self.pending = entry.value - 256;
                        self.extra = entry.extra;
                        self.phase = .length_extra;
                    }
                },
                .literal => {
                    if (written == output.len) break :parse .need_output;
                    try self.checkWork(bits.position, written, 1);
                    output[written] = @intCast(self.symbol);
                    written += 1;
                    self.phase = .codes;
                },
                .length_extra => {
                    self.pending += streamTake(&bits, self.extra) orelse break :parse .need_input;
                    self.phase = .distance;
                },
                .distance => {
                    const entry = blk: {
                        if (self.fixed_codes) {
                            const decoded = try streamEntry(&fixed.distance, &bits);
                            const raw = decoded orelse break :parse .need_input;
                            break :blk leaf(.distance, raw.value, @intCast(raw.bits));
                        }
                        const decoded = try streamEntry(&self.workspace.distance, &bits);
                        break :blk decoded orelse break :parse .need_input;
                    };
                    if (entry.value == 0) return error.InvalidStream;
                    self.distance_value = entry.value;
                    self.extra = entry.extra;
                    self.phase = .distance_extra;
                },
                .distance_extra => {
                    const extra = streamTake(&bits, self.extra) orelse break :parse .need_input;
                    self.distance_value += extra;
                    try self.checkDistance(self.distance_value, written);
                    self.phase = .match;
                },
                .match => {
                    if (written == output.len) break :parse .need_output;
                    const count = @min(self.pending, output.len - written);
                    try self.checkWork(bits.position, written, count);
                    self.copyHistory(output, &written, self.distance_value, count);
                    self.pending -= count;
                    if (self.pending == 0) self.phase = .codes;
                },
                .complete => break :parse .complete,
            }
        };

        if (status == .need_input and bits.source.len < input.bytes.len) return error.LimitExceeded;
        self.hold = bits.value;
        self.held = bits.count;
        if (status == .need_input and admitted_input < supplied_input.bytes.len)
            return error.LimitExceeded;
        if (status == .need_output and admitted_output < supplied_output.len)
            return error.LimitExceeded;
        if (input.final and bits.position == input.bytes.len) self.eof = true;
        if (status == .need_input and (input.final or self.eof)) return error.Truncated;
        self.input_bytes = std.math.add(
            u64,
            self.input_bytes,
            bits.position,
        ) catch return error.CounterOverflow;
        self.output_bytes = std.math.add(
            u64,
            self.output_bytes,
            written,
        ) catch return error.CounterOverflow;
        if (self.input_bytes > self.limits.input_bytes or self.output_bytes > self.limits
            .output_bytes) return error.LimitExceeded;
        const work = std.math.add(u64, bits.position, written) catch return error.CounterOverflow;
        if (work > self.work_left) return error.LimitExceeded;
        self.work_left -= work;
        self.saveHistory(output[0..written]);
        return .{ .consumed = bits.position, .produced = written, .status = status };
    }

    fn endBlock(self: *Decoder, bits: *Bits) void {
        self.phase = if (self.last) .complete else .block;
        if (self.last) bits.alignByte();
    }

    fn checkWork(
        self: *const Decoder,
        consumed: usize,
        produced: usize,
        count: usize,
    ) DecodeError!void {
        if (consumed > self.work_left) return error.LimitExceeded;
        const remaining = self.work_left - consumed;
        if (produced > remaining or count > remaining - produced) return error.LimitExceeded;
    }

    fn checkDistance(self: *const Decoder, distance: usize, written: usize) DecodeError!void {
        if (distance == 0 or distance > self.window_bytes) return error.InvalidStream;
        if (distance > written and distance - written > self.history_length)
            return error.InvalidStream;
    }

    // Bounded complete-token loop: at most 48 encoded bits and 258 restored bytes per token. Word
    // lookahead is reclaimed before returning to the checked state machine, so it never accepts an
    // enclosing trailer.
    fn fastCodes(
        self: *Decoder,
        comptime fixed_codes: bool,
        bits: *Bits,
        output: []u8,
        written: *usize,
    ) DecodeError!void {
        if (bits.count > 7 or bits.source.len > self.work_left) return;
        if (output.len > self.work_left - bits.source.len) return;
        while (bits.source.len - bits.position >= 8 and output.len - written.* >= 258) {
            const entry = if (fixed_codes) blk: {
                const symbol = try fixed.literal.decode(bits, .root);
                break :blk leaf(.literal_length, symbol, 0);
            } else try self.workspace.literal.ordinary.decode(bits, .complete);
            if (!fixed_codes and entry.bits == 0) {
                @branchHint(.unlikely);
                return error.InvalidStream;
            }
            if (entry.value < 256) {
                output[written.*] = @intCast(entry.value);
                written.* += 1;
                continue;
            }
            if (entry.value == 256) {
                @branchHint(.unlikely);
                self.endBlock(bits);
                break;
            }
            if (entry.value == 65535) return error.InvalidStream;
            const length = entry.value - 256 + @as(usize, try bits.take(entry.extra));
            const distance_entry = if (fixed_codes) blk: {
                const symbol = try fixed.distance.decode(bits, .root);
                break :blk leaf(.distance, symbol, 0);
            } else try self.workspace.distance.decode(bits, .distance);
            if (distance_entry.value == 0) return error.InvalidStream;
            const distance = distance_entry.value + @as(usize, try bits.take(distance_entry.extra));
            try self.checkDistance(distance, written.*);
            self.copyHistory(output, written, distance, length);
        }
        // Every whole unread byte belongs to the caller, even at EOB. Keep only the remaining bits
        // of the last actually accepted byte.
        bits.position -= bits.count / 8;
        bits.count &= 7;
        bits.value &= (@as(u64, 1) << @as(u6, @intCast(bits.count))) - 1;
    }

    fn copyHistory(
        self: *const Decoder,
        output: []u8,
        written: *usize,
        distance: usize,
        length: usize,
    ) void {
        var left = length;
        while (left != 0 and distance > written.*) {
            const back = distance - written.*;
            const start = (self.history_position + 32768 - back) & 32767;
            const count = @min(left, back, 32768 - start);
            @memcpy(output[written.*..][0..count], self.history[start..][0..count]);
            written.* += count;
            left -= count;
        }
        if (left >= 3) {
            copyMatch(output, written.*, distance, left);
        } else {
            for (0..left) |i| output[written.* + i] = output[written.* + i - distance];
        }
        written.* += left;
    }

    fn saveHistory(self: *Decoder, bytes: []const u8) void {
        if (bytes.len >= 32768) {
            @memcpy(self.history, bytes[bytes.len - 32768 ..]);
            self.history_position = 0;
            self.history_length = 32768;
        } else {
            const first = @min(bytes.len, 32768 - self.history_position);
            @memcpy(self.history[self.history_position..][0..first], bytes[0..first]);
            @memcpy(self.history[0 .. bytes.len - first], bytes[first..]);
            self.history_position = (self.history_position + bytes.len) & 32767;
            self.history_length = @min(32768, self.history_length + bytes.len);
        }
    }
};

fn streamFill(bits: *Bits, needed: u8) bool {
    while (bits.count < needed and bits.position < bits.source.len) {
        bits.value |= @as(u64, bits.source[bits.position]) << @as(u6, @intCast(bits.count));
        bits.position += 1;
        bits.count += 8;
    }
    return bits.count >= needed;
}

fn streamTake(bits: *Bits, count: u8) ?u16 {
    if (!streamFill(bits, count)) return null;
    return bits.takeBuffered(count);
}

// Probe without retiring any code bits until the complete leaf is present. Replicated short leaves
// work with fewer bits than the root width, including an EOB in the last byte. Continuations and
// partial fields can span fragments.
fn streamEntry(table: anytype, bits: *Bits) Error!?Entry {
    const root_bits: u8 = @intCast(@ctz(table.root.len));
    while (true) {
        const root_index = @as(usize, @truncate(bits.value)) & (table.root.len - 1);
        var entry = table.root[root_index];
        if (entry.bits == 0) {
            if (bits.count >= root_bits) return error.InvalidStream;
            if (!streamFill(bits, bits.count + 1)) return null;
            continue;
        }
        var used = entry.bits;
        if (bits.count < used) {
            if (!streamFill(bits, used)) return null;
            continue;
        }
        while (entry.node) {
            if (!streamFill(bits, used + 1)) return null;
            const shift: u6 = @intCast(used);
            const side: usize = @intCast((bits.value >> shift) & 1);
            entry = table.children[entry.value][side];
            used += 1;
            if (entry.bits == 0) return error.InvalidStream;
        }
        bits.drop(used);
        return entry;
    }
}

test "resumable DEFLATE retires fragments through tables matches and history wraps" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const expected = try allocator.alloc(u8, 200000);
    defer allocator.free(expected);
    const stored_abc = [_]u8{ 1, 3, 0, 252, 255, 'a', 'b', 'c' };
    const empty_fixed = [_]u8{ 3, 0 };
    const wires = [_][]const u8{
        &stored_abc,
        &empty_fixed,
        &frozen_fixtures.hello_deflate,
        &frozen_fixtures.runs_deflate,
        &frozen_fixtures.blocks_deflate,
        &frozen_fixtures.skew_deflate,
    };
    for (wires) |wire| {
        const whole = try decode(wire, expected, .{ .workspace = workspace }, .{});
        for ([_]usize{ 1, 2, 7, 8, 31, 65536 }) |in_width| {
            for ([_]usize{ 1, 2, 3, 7, 257, 258, 32767, 32768, 65536 }) |out_width| {
                var decoder: Decoder = undefined;
                try decoder.reset(
                    .{ .workspace = workspace, .history = history },
                    .{ .limits = .{} },
                );
                var consumed: usize = 0;
                var produced: usize = 0;
                var source: [65536]u8 = undefined;
                var target: [65554]u8 = undefined;
                @memset(&target, 0xa5);
                while (true) {
                    const n = @min(in_width, wire.len - consumed);
                    @memcpy(source[0..n], wire[consumed..][0..n]);
                    @memset(target[0 .. out_width + 17], 0xa5);
                    const result = try decoder.step(
                        .{ .bytes = source[0..n], .final = consumed + n == wire.len },
                        target[1..][0..out_width],
                    );
                    @memset(source[0..n], 0xcc);
                    consumed += result.consumed;
                    try std.testing.expectEqualSlices(
                        u8,
                        expected[produced..][0..result.produced],
                        target[1..][0..result.produced],
                    );
                    for (target[1 + result.produced .. out_width + 17]) |byte| {
                        try std.testing.expectEqual(0xa5, byte);
                    }
                    produced += result.produced;
                    if (result.status == .complete) break;
                    try std.testing.expect(result.consumed != 0 or result.produced != 0);
                }
                for (target[out_width + 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
                try std.testing.expectEqual(wire.len, consumed);
                try std.testing.expectEqual(whole.produced, produced);
                try std.testing.expectEqual(consumed, decoder.input_bytes);
                try std.testing.expectEqual(produced, decoder.output_bytes);
            }
        }
    }
}

test "resumable DEFLATE checks every split finality limits poisoning and dictionary suffix" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var decoder: Decoder = undefined;
    var output: [64]u8 = undefined;
    const wire = &frozen_fixtures.hello_deflate;
    for (0..wire.len + 1) |split| {
        for (0..19) |capacity| {
            try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
            var first = try decoder.step(.{ .bytes = wire[0..split] }, output[0..capacity]);
            var consumed = first.consumed;
            var produced = first.produced;
            while (first.status != .complete) {
                first = try decoder.step(
                    .{ .bytes = wire[consumed..], .final = true },
                    output[produced..],
                );
                consumed += first.consumed;
                produced += first.produced;
            }
            try std.testing.expectEqual(wire.len, consumed);
            try std.testing.expectEqualStrings("hello hello hello\n", output[0..produced]);
        }
    }
    for (0..wire.len) |end| {
        try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
        try std.testing.expectError(
            error.Truncated,
            decoder.step(.{ .bytes = wire[0..end], .final = true }, &output),
        );
        try std.testing.expectError(error.NeedReset, decoder.step(.{ .bytes = wire }, &output));
    }
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    const blocked = try decoder.step(.{ .bytes = wire, .final = true }, &.{});
    try std.testing.expectEqual(DecodeStatus.need_output, blocked.status);
    _ = try decoder.step(.{ .bytes = wire[blocked.consumed..], .final = true }, &output);
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .limits = .{ .output_bytes = 17 } },
    );
    try std.testing.expectError(
        error.LimitExceeded,
        decoder.step(.{ .bytes = wire, .final = true }, &output),
    );
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .limits = .{ .work_units = 0 } },
    );
    const empty = try decoder.step(.{ .bytes = &.{} }, &.{});
    try std.testing.expectEqual(
        DecodeProgress{ .consumed = 0, .produced = 0, .status = .need_input },
        empty,
    );
    try std.testing.expectError(error.LimitExceeded, decoder.step(.{ .bytes = wire }, &output));
    // Fixed final length-three/distance-one/EOB, accepted by zlib 1.3.2 with raw initial history
    // "A". No encoder/table produces these bytes here.
    const match_wire = [_]u8{ 0x03, 0x02, 0x00 };
    const dictionary = try allocator.alloc(u8, 40000);
    defer allocator.free(dictionary);
    @memset(dictionary, 'A');
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    try decoder.setDictionary(dictionary);
    @memset(dictionary, 0xcc);
    const matched = try decoder.step(.{ .bytes = &match_wire, .final = true }, &output);
    try std.testing.expectEqualStrings("AAA", output[0..matched.produced]);
    const one_shot = try decode(
        &match_wire,
        &output,
        .{ .workspace = workspace, .history = history },
        .{ .dictionary = "A" },
    );
    try std.testing.expectEqualStrings("AAA", output[0..one_shot.produced]);
    try std.testing.expectEqual(32768, decoder.history_length);
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    try std.testing.expectError(
        error.InvalidStream,
        decoder.step(.{ .bytes = &match_wire, .final = true }, &output),
    );
}

test "stream limits bound work and writes before publication across suspensions" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var decoder: Decoder = undefined;
    var output: [32]u8 = undefined;
    const wire = &frozen_fixtures.hello_deflate;
    for (0..wire.len + 18) |work| {
        try decoder.reset(
            .{ .workspace = workspace, .history = history },
            .{ .limits = .{ .work_units = work } },
        );
        @memset(&output, 0xa5);
        try std.testing.expectError(
            error.LimitExceeded,
            decoder.step(.{ .bytes = wire, .final = true }, &output),
        );
        // Even an unpublished failing step never restores more bytes than its complete work budget,
        // or writes beyond caller output.
        for (output[@min(work, output.len)..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{
            .limits = .{ .work_units = wire.len + 18, .input_bytes = wire.len, .output_bytes = 18 },
        },
    );
    const exact = try decoder.step(.{ .bytes = wire, .final = true }, &output);
    try std.testing.expectEqual(DecodeStatus.complete, exact.status);
    try std.testing.expectEqual(@as(u64, 0), decoder.work_left);
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .limits = .{ .input_bytes = wire.len - 1 } },
    );
    try std.testing.expectError(
        error.LimitExceeded,
        decoder.step(.{ .bytes = wire, .final = true }, &output),
    );
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .limits = .{ .output_bytes = 18, .work_units = wire.len + 18 } },
    );
    var consumed: usize = 0;
    var produced: usize = 0;
    while (true) {
        const end = @min(consumed + 1, wire.len);
        const result = try decoder.step(
            .{ .bytes = wire[consumed..end], .final = end == wire.len },
            output[produced..][0..1],
        );
        consumed += result.consumed;
        produced += result.produced;
        if (result.status == .complete) break;
    }
    try std.testing.expectEqual(@as(u64, 0), decoder.work_left);
}

test "resumable malformed input stays bounded and agrees with whole-buffer acceptance" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var decoder: Decoder = undefined;
    var bytes: [128]u8 = undefined;
    var whole_output: [4096]u8 = undefined;
    var output: [4098]u8 = undefined;
    var random: std.Random.DefaultPrng = .init(0x6d326465666c6174);
    for (0..4096) |iteration| {
        random.random().bytes(&bytes);
        const source = bytes[0 .. iteration % (bytes.len + 1)];
        const whole = decode(source, &whole_output, .{ .workspace = workspace }, .{}) catch null;
        try decoder.reset(
            .{ .workspace = workspace, .history = history },
            .{ .limits = .{ .output_bytes = 4096 } },
        );
        @memset(&output, 0xa5);
        var consumed: usize = 0;
        var produced: usize = 0;
        while (true) {
            const end = @min(source.len, consumed + 1 + iteration % 9);
            const result = decoder.step(
                .{ .bytes = source[consumed..end], .final = end == source.len },
                output[1 + produced ..][0..@min(17, 4097 - produced)],
            ) catch {
                try std.testing.expect(whole == null);
                break;
            };
            consumed += result.consumed;
            produced += result.produced;
            if (result.status == .complete) {
                const expected = whole orelse return error.TestUnexpectedResult;
                try std.testing.expectEqual(
                    expected,
                    DecodeResult{ .consumed = consumed, .produced = produced },
                );
                try std.testing.expectEqualSlices(
                    u8,
                    whole_output[0..produced],
                    output[1..][0..produced],
                );
                break;
            }
            try std.testing.expect(result.consumed != 0 or result.produced != 0);
        }
        try std.testing.expectEqual(0xa5, output[0]);
        try std.testing.expectEqual(0xa5, output[output.len - 1]);
    }
}

test "resumable word refills and suspended copies respect inaccessible pages" {
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
        const address = memory.ptr + page * page_size;
        const result = std.os.linux.mprotect(address, page_size, .{});
        try std.testing.expectEqual(.SUCCESS, posix.errno(result));
    }
    const input_page = memory[page_size .. 2 * page_size];
    const output_page = memory[4 * page_size .. 5 * page_size];
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const fixture = general_pairs;
    for ([_]usize{ 1, 7, 8, fixture.source.len }) |input_width| {
        for ([_]usize{ 0, 1, 7, 8, 257, 258, 1024 }) |output_width| {
            var decoder: Decoder = undefined;
            try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
            var consumed: usize = 0;
            var produced: usize = 0;
            var calls: usize = 0;
            while (true) {
                const n = @min(input_width, fixture.source.len - consumed);
                const source = input_page[page_size - n ..];
                @memcpy(source, fixture.source[consumed..][0..n]);
                const capacity = if (calls == 0) output_width else @max(1, output_width);
                const output = output_page[page_size - capacity ..];
                @memset(output_page, 0xa5);
                const result = try decoder.step(
                    .{ .bytes = source, .final = consumed + n == fixture.source.len },
                    output,
                );
                try std.testing.expectEqualSlices(
                    u8,
                    fixture.expected[produced..][0..result.produced],
                    output[0..result.produced],
                );
                for (output_page[0 .. page_size - capacity]) |byte| {
                    try std.testing.expectEqual(0xa5, byte);
                }
                for (output[result.produced..]) |byte| try std.testing.expectEqual(0xa5, byte);
                @memset(source, 0xcc);
                consumed += result.consumed;
                produced += result.produced;
                if (result.status == .complete) break;
                calls += 1;
                try std.testing.expect(calls <= fixture.source.len + fixture.expected.len + 1);
            }
            try std.testing.expectEqual(fixture.source.len, consumed);
            try std.testing.expectEqual(fixture.expected.len, produced);
        }
    }
}

test "preset history reaches maximum RFC distance across output suspensions" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const dictionary = try allocator.alloc(u8, 40000);
    defer allocator.free(dictionary);
    for (dictionary, 0..) |*byte, i| byte.* = @truncate(i * 31 + i / 17);
    // Independent fixed length 258/distance 32768/EOB facts, also used by the complete-buffer RFC
    // test. Trailing bytes force word-refill lookahead.
    const wire = [_]u8{ 0x1b, 0xbd, 0xff, 0x1f, 0 };
    const trailing = [_]u8{ 0x6c, 0x6f, 0x6f, 0x6b, 0x61, 0x68, 0x65, 0x61, 0x64 };
    const source = wire ++ trailing;
    var decoder: Decoder = undefined;
    var output: [258]u8 = undefined;
    for ([_]usize{ 1, 2, 3, 257, 258 }) |width| {
        try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
        try decoder.setDictionary(dictionary);
        var consumed: usize = 0;
        var produced: usize = 0;
        while (true) {
            const result = try decoder.step(
                .{ .bytes = source[consumed..], .final = true },
                output[produced..][0..@min(width, output.len - produced)],
            );
            consumed += result.consumed;
            produced += result.produced;
            if (result.status == .complete) break;
        }
        try std.testing.expectEqual(wire.len, consumed);
        try std.testing.expectEqualSlices(
            u8,
            dictionary[dictionary.len - 32768 ..][0..258],
            &output,
        );
    }
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .window_bytes = 32767, .limits = .{} },
    );
    try decoder.setDictionary(dictionary);
    try std.testing.expectError(
        error.InvalidStream,
        decoder.step(.{ .bytes = &source, .final = true }, &output),
    );
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    try decoder.setDictionary(dictionary[0..32767]);
    try std.testing.expectError(
        error.InvalidStream,
        decoder.step(.{ .bytes = &source, .final = true }, &output),
    );
}

test "resumable decoding keeps all forty-eight token bits through byte fragments" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const wire = &frozen_fixtures.expanded_48bit_deflate;
    const expected = &frozen_fixtures.expanded_48bit_golden;
    var decoder: Decoder = undefined;
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    var consumed: usize = 0;
    var produced: usize = 0;
    var output: [259]u8 = undefined;
    while (true) {
        const end = @min(consumed + 1, wire.len);
        @memset(&output, 0xa5);
        const result = try decoder.step(
            .{ .bytes = wire[consumed..end], .final = end == wire.len },
            &output,
        );
        try std.testing.expectEqualSlices(
            u8,
            expected[produced..][0..result.produced],
            output[0..result.produced],
        );
        for (output[result.produced..]) |byte| try std.testing.expectEqual(0xa5, byte);
        consumed += result.consumed;
        produced += result.produced;
        if (result.status == .complete) break;
        try std.testing.expect(result.consumed != 0 or result.produced != 0);
    }
    try std.testing.expectEqual(wire.len, consumed);
    try std.testing.expectEqual(expected.len, produced);
}

test "streaming bulk lookup rejects singleton holes before producing bytes" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var decoder: Decoder = undefined;
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    // Independent malformed singleton-EOB wire from the canonical-table tests. Padding admits the
    // word-refill loop; an invalid zero-width leaf must not turn into a literal or spend the
    // caller's output reservation.
    const invalid = [_]u8{ 0x05, 0xc0, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00, 0xa0, 0xff, 0xaf, 0x13 };
    const padding: [64]u8 = @splat(0);
    const source = invalid ++ padding;
    var output: [1024]u8 = @splat(0xa5);
    try std.testing.expectError(
        error.InvalidStream,
        decoder.step(.{ .bytes = &source, .final = true }, &output),
    );
    for (output) |byte| try std.testing.expectEqual(0xa5, byte);
}

test "new canonical wires retain exact fragmented recovery after direct workspace reuse" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const decoder = try allocator.create(Decoder);
    defer allocator.destroy(decoder);
    const cases = [_]struct {
        wire: []const u8,
        expected: []const u8,
    }{
        .{
            .wire = &frozen_fixtures.byte_dominant_narrow_deflate,
            .expected = &frozen_fixtures.byte_dominant_narrow_golden,
        },
        .{
            .wire = &frozen_fixtures.wide_expanded_deflate,
            .expected = &frozen_fixtures.wide_expanded_golden,
        },
    };
    for (cases) |fixture| {
        const backing = try allocator.alloc(u8, fixture.expected.len + 64);
        defer allocator.free(backing);
        inline for (.{ 1, 7, 64 }, .{ 1, 3, 257 }) |input_chunk, output_chunk| {
            // The direct decoder leaves its selected table representation in the union. Streaming
            // reset rebuilds the ordinary tables it owns.
            _ = try decode(
                fixture.wire,
                backing[32..][0..fixture.expected.len],
                .{ .workspace = workspace },
                .{},
            );
            try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
            @memset(backing, 0xa5);
            const output = backing[32..][0..fixture.expected.len];
            var consumed: usize = 0;
            var produced: usize = 0;
            var calls: usize = 0;
            while (true) {
                calls += 1;
                try std.testing.expect(calls < 5000);
                const end = @min(fixture.wire.len, consumed + input_chunk);
                const step = try decoder.step(
                    .{ .bytes = fixture.wire[consumed..end], .final = end == fixture.wire.len },
                    output[produced..@min(output.len, produced + output_chunk)],
                );
                consumed += step.consumed;
                produced += step.produced;
                if (step.status == .complete) break;
            }
            try std.testing.expectEqual(fixture.wire.len, consumed);
            try std.testing.expectEqual(fixture.expected.len, produced);
            try std.testing.expectEqualSlices(u8, fixture.expected, output);
            for (backing[0..32]) |byte| try std.testing.expectEqual(0xa5, byte);
            for (backing[32 + produced ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
    }
}
