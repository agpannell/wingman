//! Resumable raw LZ4 block recovery with an external 64 KiB history ring. Fragments may retire
//! after step. State may transfer between calls; retire the old copy so only one owner mutates the
//! ring. Keep the ring stable and disjoint from the active owner. Every step error requires reset
//! before reuse. Internal fields are modified only by methods.
const std = @import("std");
const recovery = @import("block_recovery.zig");
const match_copy = @import("match_copy.zig");
const TestWriter = @import("BlockWriter.zig"); // Inline field/guard fixtures only.
// Inline fragmentation/round-trip fixtures only.
const test_encoding = @import("greedy_encode.zig");
const bulkSequence = recovery.bulkSequence;
const copyMatch = match_copy.expand;
const byte_ranges = @import("../common/byte_ranges.zig");
const overlaps = byte_ranges.overlapsChecked;
const maximum_distance = @import("block.zig").maximum_distance;
const InputFragment = @import("../lz4.zig").InputFragment;
const Limits = @import("BlockDecodeLimits.zig");
const BlockStreamDecoder = @This();

/// Raw format, storage, admission and stream lifecycle failures. Output capacity is reported by
/// Status.need_output.
pub const Error = error{
    Truncated,
    InvalidOffset,
    InvalidTermination,
    SizeOverflow,
    Aliasing,
    LimitExceeded,
    NeedReset,
    InvalidState,
    CounterOverflow,
};

/// A blocking status or successful end of a raw block.
pub const Status = enum {
    /// Supply more block bytes, preserving any unconsumed suffix and its final flag.
    need_input,
    /// Supply output capacity and resubmit any unconsumed input.
    need_output,
    /// The complete raw block was validated; any enclosing integrity check is still separate.
    complete,
};

/// Copied fragment counts. No source or output borrow is retained.
pub const Progress = struct {
    /// Encoded fragment bytes accepted by this call.
    consumed: usize,
    /// Restored bytes written to this call's output prefix.
    produced: usize,
    /// Additional capacity/input needed, or completion of this block.
    status: Status,
};

/// Resumable raw policy; dictionary history is copied during reset or setDictionary.
pub const Options = struct {
    /// Initial history copied into the ring; only its last 65,535 bytes are reachable.
    dictionary: []const u8 = &.{},
    /// Ceilings for the first block; nextBlock can preserve or replace them.
    limits: Limits = .{},
};

/// Policy for the next raw block. Omitted limits reuse the previous block's ceilings; containers
/// can replace them with their remaining cumulative allowance at each block boundary.
pub const BlockOptions = struct {
    /// Keep the copied history ring for a linked block; false discards available history.
    retain_history: bool,
    /// Replacement ceilings for the new block; null preserves the configured limits.
    limits: ?Limits = null,
};

/// Copied charges for this block. A failed step preserves its admitted prefix, which can depend on
/// fragmentation. nextBlock restarts all three; appended container history is excluded.
pub const Counts = struct {
    /// Encoded bytes accepted in this block.
    input_bytes: u64,
    /// Restored bytes charged in this block.
    output_bytes: u64,
    /// Accepted encoded plus restored bytes.
    work_units: u64,
};

/// Caller-owned ring; only its initialized history is readable.
history: *[65536]u8,
/// Next ring position to receive restored bytes.
write_position: usize,
/// Reachable initialized suffix, capped at maximum_distance.
available: usize,
/// Sequence field or match operation resumed by the next step.
phase: Phase,
/// Current sequence's literal/match length nibbles.
token: u8,
/// Literal bytes, match bytes or an extended length still to finish.
remaining: usize,
/// Current sequence's complete literal length for final-literal validation.
literals: usize,
/// Current match's backward distance.
distance: usize,
/// Output position of the latest match, for final-literal validation.
last_match: ?u64,
/// All encoded bytes of a final fragment were accepted.
final_input: bool,
/// Per-block ceilings preserved or replaced at nextBlock.
limits: Limits,
/// Charged encoded bytes in this block.
input_bytes: u64,
/// Charged restored bytes in this block.
output_bytes: u64,
/// Charged encoded plus restored bytes in this block.
work_units: u64,

const Phase = enum {
    token,
    literal_length,
    literals,
    after_literals,
    offset_high,
    match_length,
    match,
    done,
    failed,
};

/// Starts a block, optionally copying initial dictionary bytes. History is initialized as
/// dictionary/output bytes arrive; the options and dictionary may retire on return. A refused setup
/// leaves the active decoder and its history unchanged.
pub fn reset(
    self: *BlockStreamDecoder,
    history: *[65536]u8,
    options: Options,
) error{ Aliasing, SizeOverflow }!void {
    const limits = options.limits;
    if (try overlaps(std.mem.asBytes(self), history)) return error.Aliasing;
    const dictionary = recovery.historySuffix(options.dictionary);
    if (try overlaps(
        dictionary,
        history,
    ) or try overlaps(dictionary, std.mem.asBytes(self))) return error.Aliasing;
    self.* = .{
        .history = history,
        .write_position = 0,
        .available = 0,
        .phase = .token,
        .token = 0,
        .remaining = 0,
        .literals = 0,
        .distance = 0,
        .last_match = null,
        .final_input = false,
        .limits = limits,
        .input_bytes = 0,
        .output_bytes = 0,
        .work_units = 0,
    };
    if (dictionary.len != 0) self.remember(dictionary);
}

/// Snapshots admitted per-block work without changing lifecycle or history.
pub fn counts(self: *const BlockStreamDecoder) Counts {
    return .{
        .input_bytes = self.input_bytes,
        .output_bytes = self.output_bytes,
        .work_units = self.work_units,
    };
}

/// Copies an initial dictionary suffix before accepting block input. Replaces existing history. Its
/// source may retire on return.
pub fn setDictionary(
    self: *BlockStreamDecoder,
    dictionary: []const u8,
) error{ NeedReset, InvalidState, Aliasing, SizeOverflow }!void {
    if (self.phase == .failed) return error.NeedReset;
    if (self.phase != .token or self.input_bytes != 0) return error.InvalidState;
    const bytes = recovery.historySuffix(dictionary);
    if (try overlaps(bytes, self.history)) return error.Aliasing;
    if (try overlaps(bytes, std.mem.asBytes(self))) return error.Aliasing;
    self.write_position = 0;
    self.available = 0;
    self.remember(bytes);
}

/// Starts another block after completion or before any block input. Keep history for linked blocks;
/// otherwise clear it and optionally set another dictionary. Per-block counts/limits restart; no
/// allocation occurs.
pub fn nextBlock(
    self: *BlockStreamDecoder,
    options: BlockOptions,
) error{ NeedReset, InvalidState }!void {
    if (self.phase == .failed) return error.NeedReset;
    if (self.phase != .done and !(self.phase == .token and self.input_bytes == 0))
        return error.InvalidState;
    const retain_history = options.retain_history;
    const limits = options.limits orelse self.limits;
    self.phase = .token;
    self.limits = limits;
    self.remaining = 0;
    self.literals = 0;
    self.last_match = null;
    self.final_input = false;
    self.input_bytes = 0;
    self.output_bytes = 0;
    self.work_units = 0;
    if (!retain_history) {
        self.write_position = 0;
        self.available = 0;
    }
}

/// Adds already decoded bytes between compressed blocks, for a container's uncompressed blocks.
/// Updates history only, without charging raw-block counts. The container owns those bytes' bounds
/// and resource accounting.
pub fn appendHistory(
    self: *BlockStreamDecoder,
    bytes: []const u8,
) error{ NeedReset, InvalidState, Aliasing, SizeOverflow }!void {
    if (self.phase == .failed) return error.NeedReset;
    if (self.phase != .done and !(self.phase == .token and self.input_bytes == 0))
        return error.InvalidState;
    if (try overlaps(bytes, self.history)) return error.Aliasing;
    if (try overlaps(bytes, std.mem.asBytes(self))) return error.Aliasing;
    self.remember(bytes);
}

/// Advances one block. No read/write exceeds the supplied exact spans. Empty steps after completion
/// return zero progress; every step error requires reset.
pub fn step(self: *BlockStreamDecoder, input: InputFragment, output: []u8) Error!Progress {
    if (self.phase == .failed) return error.NeedReset;
    errdefer self.phase = .failed;
    const state = std.mem.asBytes(self);
    if (try overlaps(input.bytes, output)) return error.Aliasing;
    if (try overlaps(input.bytes, self.history) or try overlaps(output, self.history)) {
        return error.Aliasing;
    }
    if (try overlaps(input.bytes, state) or try overlaps(output, state)) return error.Aliasing;
    if (self.final_input and input.bytes.len != 0) return error.InvalidState;

    // A container can admit a complete bounded block here. Keep ring maintenance and suspension out
    // of its token loop, then retain only the final history suffix. Smaller fragments use the state
    // machine.
    const complete_block = blk: {
        if (self.phase != .token or self.input_bytes != 0 or !input.final) break :blk false;
        if (output.len < self.limits.output_bytes) break :blk false;
        if (input.bytes.len > self.limits.input_bytes) break :blk false;
        if (self.limits.work_units < input.bytes.len) break :blk false;
        break :blk self.limits.output_bytes <= self.limits.work_units - input.bytes.len;
    };
    if (complete_block) {
        const start = (self.write_position + 65536 - self.available) & 65535;
        const first = @min(self.available, 65536 - start);
        const recovered = recovery.into(
            input.bytes,
            output[0..@intCast(self.limits.output_bytes)],
            .{
                .history = .{
                    .older = self.history[start..][0..first],
                    .newer = self.history[0 .. self.available - first],
                },
                .output_size = .bounded,
            },
        ) catch |err| {
            @branchHint(.unlikely);
            return switch (err) {
                // This complete shortcut always uses bounded output. Capacity refusal is a resource
                // ceiling here; an exact-extent mismatch is therefore impossible.
                error.OutputTooSmall => error.LimitExceeded,
                error.OutputSizeMismatch => unreachable,
                else => |failure| failure,
            };
        };
        const count = recovered.produced;
        try self.charge(input.bytes.len, count);
        self.remember(output[0..count]);
        self.final_input = true;
        self.phase = .done;
        return .{ .consumed = input.bytes.len, .produced = count, .status = .complete };
    }

    // Each phase consumes only the bytes it can finish with the current fragment. The decoder keeps
    // parsed token state between calls, but copies produced bytes into the 64 KiB ring so later
    // matches remain valid after the caller retires an output fragment.
    var read: usize = 0;
    var written: usize = 0;
    while (true) switch (self.phase) {
        .token => {
            // Batch complete sequences, including retained ring history. Splitting the remaining
            // work admission between input and output makes the batch safe before touching any
            // bytes; exact accounting and one ring update follow the batch.
            const half_work = (self.limits.work_units - self.work_units) / 2;
            const input_budget = self.limits.input_bytes - self.input_bytes;
            const output_budget = self.limits.output_bytes - self.output_bytes;
            const admitted_input: usize = @intCast(
                @min(input.bytes.len - read, input_budget, half_work),
            );
            const admitted_output: usize = @intCast(
                @min(output.len - written, output_budget, half_work),
            );
            const input_end = read + admitted_input;
            const output_end = written + admitted_output;
            const old_read = read;
            const old_written = written;
            var sequence_start: usize = 0;
            const ring: recovery.RingHistory = .{
                .history = self.history,
                .write_position = self.write_position,
                .available = self.available,
            };
            while (@call(
                .always_inline,
                bulkSequence,
                .{
                    true,
                    input.bytes[0..input_end],
                    output[0..output_end],
                    &read,
                    &written,
                    &sequence_start,
                    ring,
                    old_written,
                },
            )) {}
            if (read != old_read) {
                self.last_match = self.output_bytes + sequence_start - old_written;
                try self.charge(read - old_read, written - old_written);
                self.remember(output[old_written..written]);
                continue;
            }
            if (read == input.bytes.len) return self.blocked(input, read, written, .need_input);
            self.token = try self.take(input.bytes, &read);
            self.literals = self.token >> 4;
            self.remaining = self.literals;
            self.phase = if (self.remaining == 15) .literal_length else .literals;
        },
        .literal_length, .match_length => {
            if (read == input.bytes.len) return self.blocked(input, read, written, .need_input);
            const byte = try self.take(input.bytes, &read);
            self.remaining = std.math.add(
                usize,
                self.remaining,
                byte,
            ) catch return error.SizeOverflow;
            if (self.phase == .literal_length) self.literals = self.remaining;
            if (byte != 255) {
                self.phase = if (self.phase == .literal_length) .literals else .match;
            }
        },
        .literals => {
            if (self.remaining == 0) {
                self.phase = .after_literals;
                continue;
            }
            if (read == input.bytes.len) return self.blocked(input, read, written, .need_input);
            if (written == output.len) return self.blocked(input, read, written, .need_output);
            const count = @min(self.remaining, input.bytes.len - read, output.len - written);
            try self.charge(count, count);
            @memcpy(output[written..][0..count], input.bytes[read..][0..count]);
            self.remember(output[written..][0..count]);
            read += count;
            written += count;
            self.remaining -= count;
        },
        .after_literals => {
            if (read == input.bytes.len) {
                if (!self.final_input and !input.final) {
                    return self.blocked(input, read, written, .need_input);
                }
                if (self.last_match) |start| {
                    if (self.literals < 5 or self.output_bytes - start < 12)
                        return error.InvalidTermination;
                }
                self.phase = .done;
                return self.blocked(input, read, written, .complete);
            }
            self.distance = try self.take(input.bytes, &read);
            self.phase = .offset_high;
        },
        .offset_high => {
            if (read == input.bytes.len) return self.blocked(input, read, written, .need_input);
            self.distance |= @as(usize, try self.take(input.bytes, &read)) << 8;
            if (self.distance == 0 or self.distance > self.available) return error.InvalidOffset;
            self.remaining = @as(usize, self.token & 15) + 4;
            self.last_match = self.output_bytes;
            self.phase = if ((self.token & 15) == 15) .match_length else .match;
        },
        .match => {
            if (self.remaining == 0) {
                self.phase = .token;
                continue;
            }
            if (written == output.len) return self.blocked(input, read, written, .need_output);
            var count = @min(self.remaining, output.len - written);
            if (self.distance <= written) {
                try self.charge(0, count);
                @call(.always_inline, copyMatch, .{ output, written, self.distance, count });
            } else {
                const start = (self.write_position + 65536 - self.distance) & 65535;
                count = @min(count, self.distance, 65536 - start);
                try self.charge(0, count);
                @memcpy(output[written..][0..count], self.history[start..][0..count]);
            }
            self.remember(output[written..][0..count]);
            written += count;
            self.remaining -= count;
        },
        .done => return self.blocked(input, read, written, .complete),
        .failed => unreachable,
    };
}

fn take(self: *BlockStreamDecoder, bytes: []const u8, read: *usize) Error!u8 {
    try self.charge(1, 0);
    const byte = bytes[read.*];
    read.* += 1;
    return byte;
}

fn charge(self: *BlockStreamDecoder, consumed: usize, produced: usize) Error!void {
    const input_bytes = std.math.add(
        u64,
        self.input_bytes,
        consumed,
    ) catch return error.CounterOverflow;
    const output_bytes = std.math.add(
        u64,
        self.output_bytes,
        produced,
    ) catch return error.CounterOverflow;
    const amount = std.math.add(u64, consumed, produced) catch return error.CounterOverflow;
    const work_units = std.math.add(
        u64,
        self.work_units,
        amount,
    ) catch return error.CounterOverflow;
    if (input_bytes > self.limits.input_bytes) return error.LimitExceeded;
    if (output_bytes > self.limits.output_bytes or work_units > self.limits.work_units)
        return error.LimitExceeded;

    self.input_bytes = input_bytes;
    self.output_bytes = output_bytes;
    self.work_units = work_units;
}

fn remember(self: *BlockStreamDecoder, bytes: []const u8) void {
    const kept = bytes[bytes.len - @min(bytes.len, 65536) ..];
    const end = (self.write_position + (bytes.len & 65535)) & 65535;
    const start = (end + 65536 - kept.len) & 65535;
    const first = @min(kept.len, 65536 - start);
    @memcpy(self.history[start..][0..first], kept[0..first]);
    @memcpy(self.history[0 .. kept.len - first], kept[first..]);
    self.write_position = end;
    self.available = @min(maximum_distance, self.available +| bytes.len);
}

fn blocked(
    self: *BlockStreamDecoder,
    input: InputFragment,
    read: usize,
    written: usize,
    status: Status,
) Error!Progress {
    if (input.final and read == input.bytes.len) self.final_input = true;
    if (status == .need_input and self.final_input) return error.Truncated;
    return .{ .consumed = read, .produced = written, .status = status };
}

test "LZ4 short sequences match field oracles and preserve unused bounded output" {
    var wire: [512]u8 = undefined;
    var expected: [256]u8 = undefined;
    var output: [256]u8 = undefined;
    var history: [65536]u8 = undefined;
    var prefix: [64]u8 = undefined;
    for (&prefix, 0..) |*byte, i| byte.* = @intCast(i);
    for (0..15) |literals| {
        for (4..19) |match| {
            for ([_]usize{ 1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 32 }) |distance| {
                var writer: TestWriter = .{ .bytes = &wire };
                writer.sequence(&prefix, 1, 7);
                @memcpy(expected[0..64], &prefix);
                @memset(expected[64..71], 63);
                var count: usize = 71;
                for (0..4) |_| {
                    writer.sequence(prefix[0..literals], @intCast(distance), match);
                    @memcpy(expected[count..][0..literals], prefix[0..literals]);
                    count += literals;
                    for (0..match) |_| {
                        expected[count] = expected[count - distance];
                        count += 1;
                    }
                }
                writer.sequence(&.{}, 1, 7);
                @memset(expected[count..][0..7], expected[count - 1]);
                count += 7;
                writer.final("TAIL!");
                @memcpy(expected[count..][0..5], "TAIL!");
                count += 5;
                const block = wire[0..writer.cursor];
                _ = try recovery.into(block, output[0..count], .{});
                try std.testing.expectEqualSlices(u8, expected[0..count], output[0..count]);
                @memset(&output, 0xa7);
                try std.testing.expectEqual(
                    count,
                    (try recovery.into(
                        block,
                        &output,
                        .{ .history = .{}, .output_size = .bounded },
                    )).produced,
                );
                try std.testing.expectEqualSlices(u8, expected[0..count], output[0..count]);
                try std.testing.expect(std.mem.allEqual(u8, output[count..], 0xa7));
                var decoder: BlockStreamDecoder = undefined;
                try decoder.reset(&history, .{ .limits = .{} });
                var read: usize = 0;
                var written: usize = 0;
                while (true) {
                    const end = @min(block.len, read + 47);
                    const part = try decoder.step(
                        .{ .bytes = block[read..end], .final = end == block.len },
                        output[written..@min(count, written + 63)],
                    );
                    read += part.consumed;
                    written += part.produced;
                    if (part.status == .complete) break;
                    try std.testing.expect(part.consumed != 0 or part.produced != 0);
                }
                try std.testing.expectEqualSlices(u8, expected[0..count], output[0..count]);
            }
        }
    }
}

test "LZ4 streaming retires fragments through extension and history wrap boundaries" {
    const allocator = std.testing.allocator;
    const workspace = try test_encoding.Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([65536]u8);
    defer allocator.destroy(history);
    const source = try allocator.alloc(u8, 140003);
    defer allocator.free(source);
    for (source, 0..) |*byte, i| byte.* = @intCast((i / 17) % 251);
    const encoded = try allocator.alloc(u8, try test_encoding.bound(source.len));
    defer allocator.free(encoded);
    const block = try test_encoding.into(source, encoded, workspace, .{});
    const recovered = try allocator.alloc(u8, source.len);
    defer allocator.free(recovered);
    for ([_]usize{ 1, 2, 7, 63, 65535, 65536, 65537, 200000 }) |chunk| {
        var decoder: BlockStreamDecoder = undefined;
        try decoder.reset(history, .{ .limits = .{} });
        var read: usize = 0;
        var written: usize = 0;
        var fragment: [257]u8 = undefined;
        var temporary: [257]u8 = undefined;
        while (true) {
            const in_count = @min(chunk, block.len - read, fragment.len);
            @memcpy(fragment[0..in_count], block[read..][0..in_count]);
            const part = try decoder.step(
                .{ .bytes = fragment[0..in_count], .final = read + in_count == block.len },
                temporary[0..@min(chunk, temporary.len, source.len - written)],
            );
            @memcpy(recovered[written..][0..part.produced], temporary[0..part.produced]);
            @memset(&fragment, 0xa7);
            @memset(&temporary, 0xa7);
            read += part.consumed;
            written += part.produced;
            if (part.status == .complete) break;
            try std.testing.expect(part.consumed != 0 or part.produced != 0);
        }
        try std.testing.expectEqual(block.len, read);
        try std.testing.expectEqualSlices(u8, source, recovered);
        try std.testing.expectEqual(block.len + source.len, decoder.work_units);
        try decoder.nextBlock(.{ .retain_history = true });
        const linked = [_]u8{ 0x03, 0x01, 0x00, 0x50, 1, 2, 3, 4, 5 };
        var tail: [12]u8 = undefined;
        const part = try decoder.step(.{ .bytes = &linked, .final = true }, &tail);
        try std.testing.expectEqual(Status.complete, part.status);
        try std.testing.expect(std.mem.allEqual(u8, tail[0..7], source[source.len - 1]));
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, tail[7..]);
    }
}

test "LZ4 streaming finality limits poisoning aliasing and counter overflow" {
    var history: [65536]u8 = undefined;
    var decoder: BlockStreamDecoder = undefined;
    var output: [12]u8 = undefined;
    const block = [_]u8{ 0x03, 0x01, 0x00, 0x50, 1, 2, 3, 4, 5 };
    try decoder.reset(
        &history,
        .{
            .limits = .{
                .input_bytes = block.len,
                .output_bytes = output.len,
                .work_units = block.len + output.len,
            },
        },
    );
    try decoder.setDictionary("x");
    _ = try decoder.step(.{ .bytes = &block, .final = true }, &output);
    try decoder.reset(&history, .{ .limits = .{ .output_bytes = output.len - 1 } });
    try decoder.setDictionary("x");
    try std.testing.expectError(
        error.LimitExceeded,
        decoder.step(.{ .bytes = &block, .final = true }, &output),
    );
    try std.testing.expectError(
        error.NeedReset,
        decoder.step(.{ .bytes = &.{}, .final = true }, &output),
    );
    try decoder.reset(&history, .{ .limits = .{} });
    try std.testing.expectError(
        error.Truncated,
        decoder.step(.{ .bytes = &.{0xf0}, .final = true }, &output),
    );
    try decoder.reset(&history, .{ .limits = .{} });
    try std.testing.expectError(error.Aliasing, decoder.step(.{ .bytes = history[0..1] }, &output));
    try decoder.reset(&history, .{ .limits = .{} });
    decoder.input_bytes = std.math.maxInt(u64);
    try std.testing.expectError(error.CounterOverflow, decoder.step(.{ .bytes = &.{0} }, &output));
    try decoder.reset(&history, .{ .limits = .{} });
    try std.testing.expectEqual(
        Status.need_input,
        (try decoder.step(.{ .bytes = &.{} }, &.{})).status,
    );
    try std.testing.expectEqual(
        Status.complete,
        (try decoder.step(.{ .bytes = &.{0}, .final = true }, &.{})).status,
    );
}

test "LZ4 complete options separate extent history and byte admission" {
    const wire = [_]u8{ 0x50, 'h', 'e', 'l', 'l', 'o' };
    var output: [8]u8 = @splat(0xa7);
    const result = try recovery.into(&wire, &output, .{ .output_size = .bounded });
    try std.testing.expectEqual(wire.len, result.consumed);
    try std.testing.expectEqual(5, result.produced);
    try std.testing.expectEqualStrings("hello", output[0..result.produced]);
    try std.testing.expect(std.mem.allEqual(u8, output[5..], 0xa7));
    try std.testing.expectError(error.OutputSizeMismatch, recovery.into(&wire, &output, .{}));
    _ = try recovery.into(
        &wire,
        output[0..5],
        .{ .limits = .{ .input_bytes = wire.len, .output_bytes = 5, .work_units = wire.len + 5 } },
    );
    try std.testing.expectError(
        error.LimitExceeded,
        recovery.into(
            &wire,
            &output,
            .{ .output_size = .bounded, .limits = .{ .work_units = wire.len + 4 } },
        ),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        recovery.into(&wire, output[0..5], .{ .limits = .{ .input_bytes = wire.len - 1 } }),
    );
    // A reachable dictionary overlapping even unused destination capacity is still an alias.
    try std.testing.expectError(
        error.Aliasing,
        recovery.into(
            &wire,
            &output,
            .{
                .output_size = .bounded,
                .history = .{ .older = output[6..] },
                .limits = .{ .output_bytes = 5 },
            },
        ),
    );
    const allocator = std.testing.allocator;
    const history = try allocator.create([65536]u8);
    defer allocator.destroy(history);
    var dictionary = [_]u8{ 'a', 'b', 'c', 'd' };
    var decoder: BlockStreamDecoder = undefined;
    try decoder.reset(history, .{ .dictionary = &dictionary });
    @memset(&dictionary, 0);
    // Match four dictionary bytes, then eight independent final literals.
    const external = [_]u8{ 0, 4, 0, 0x80, '1', '2', '3', '4', '5', '6', '7', '8' };
    var restored: [12]u8 = undefined;
    const progress = try decoder.step(.{ .bytes = &external, .final = true }, &restored);
    try std.testing.expectEqual(Status.complete, progress.status);
    try std.testing.expectEqualStrings("abcd12345678", &restored);
}

test "LZ4 raw block boundaries reset counts and replace or reuse ceilings" {
    const literal = [_]u8{ 0x10, 'x' };
    // Seven bytes copied at distance one, followed by the required five final literals.
    const linked = [_]u8{ 0x03, 0x01, 0x00, 0x50, 1, 2, 3, 4, 5 };
    const literal_counts: Counts = .{ .input_bytes = 2, .output_bytes = 1, .work_units = 3 };
    const linked_counts: Counts = .{ .input_bytes = 9, .output_bytes = 12, .work_units = 21 };
    const zero: Counts = .{ .input_bytes = 0, .output_bytes = 0, .work_units = 0 };
    var history: [65536]u8 = undefined;
    var decoder: BlockStreamDecoder = undefined;
    var output: [12]u8 = undefined;
    try decoder.reset(
        &history,
        .{ .limits = .{ .input_bytes = 2, .output_bytes = 1, .work_units = 3 } },
    );
    try std.testing.expectEqual(
        Status.complete,
        (try decoder.step(.{ .bytes = &literal, .final = true }, output[0..1])).status,
    );
    try std.testing.expectEqualDeep(literal_counts, decoder.counts());
    try std.testing.expectEqual(@as(u8, 'x'), output[0]);

    // Omitted limits retain per-block ceilings, while the previous block's charges retire.
    try decoder.nextBlock(.{ .retain_history = false });
    try std.testing.expectEqualDeep(zero, decoder.counts());
    _ = try decoder.step(.{ .bytes = &literal, .final = true }, output[0..1]);
    try std.testing.expectEqualDeep(literal_counts, decoder.counts());

    // A container may replace a previous finite allowance with a larger block allowance.
    try decoder.nextBlock(
        .{
            .retain_history = true,
            .limits = .{ .input_bytes = 9, .output_bytes = 12, .work_units = 21 },
        },
    );
    try std.testing.expectEqualDeep(zero, decoder.counts());
    try std.testing.expectEqual(
        Status.complete,
        (try decoder.step(.{ .bytes = &linked, .final = true }, &output)).status,
    );
    try std.testing.expectEqualDeep(linked_counts, decoder.counts());
    try std.testing.expect(std.mem.allEqual(u8, output[0..7], 'x'));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, output[7..]);

    // Stored container output advances history but belongs to the container's accounting.
    try decoder.appendHistory("q");
    try std.testing.expectEqualDeep(linked_counts, decoder.counts());
    try decoder.nextBlock(.{ .retain_history = true });
    try std.testing.expectEqualDeep(zero, decoder.counts());
    _ = try decoder.step(.{ .bytes = &linked, .final = true }, &output);
    try std.testing.expectEqualDeep(linked_counts, decoder.counts());
    try std.testing.expect(std.mem.allEqual(u8, output[0..7], 'q'));

    // Clearing history prevents that same linked block from referring to retired bytes.
    try decoder.nextBlock(.{ .retain_history = false });
    try std.testing.expectError(
        error.InvalidOffset,
        decoder.step(.{ .bytes = &linked, .final = true }, output[0..1]),
    );
    try std.testing.expectEqualDeep(
        Counts{ .input_bytes = 3, .output_bytes = 0, .work_units = 3 },
        decoder.counts(),
    );
    try std.testing.expectError(error.NeedReset, decoder.nextBlock(.{ .retain_history = true }));
}

test "LZ4 raw replacement ceilings refuse the next charge and reset recovers" {
    const literal = [_]u8{ 0x10, 'x' };
    var history: [65536]u8 = undefined;
    var decoder: BlockStreamDecoder = undefined;
    var output: [1]u8 = undefined;
    try decoder.reset(&history, .{});
    _ = try decoder.step(.{ .bytes = &literal, .final = true }, &output);
    try decoder.nextBlock(
        .{
            .retain_history = false,
            .limits = .{ .input_bytes = 1, .output_bytes = 1, .work_units = 3 },
        },
    );
    try std.testing.expectError(
        error.LimitExceeded,
        decoder.step(.{ .bytes = &literal, .final = true }, &output),
    );
    try std.testing.expectEqualDeep(
        Counts{ .input_bytes = 1, .output_bytes = 0, .work_units = 1 },
        decoder.counts(),
    );
    try std.testing.expectError(
        error.NeedReset,
        decoder.step(.{ .bytes = &literal, .final = true }, &output),
    );
    try decoder.reset(
        &history,
        .{ .limits = .{ .input_bytes = 2, .output_bytes = 1, .work_units = 3 } },
    );
    try std.testing.expectEqual(
        Status.need_input,
        (try decoder.step(.{ .bytes = literal[0..1] }, &output)).status,
    );
    // A refused boundary transition must not replace the active block's allowance.
    try std.testing.expectError(
        error.InvalidState,
        decoder.nextBlock(.{ .retain_history = false, .limits = .{ .input_bytes = 0 } }),
    );
    try std.testing.expectEqual(
        Status.complete,
        (try decoder.step(.{ .bytes = literal[1..], .final = true }, &output)).status,
    );
    try std.testing.expectEqual(@as(u8, 'x'), output[0]);
}

test "LZ4 streaming transfer retains a partial match-length field" {
    // One literal, a distance-one match of 275 bytes, then five final literals. The first fragment
    // ends after the 255 extension byte, before the match's terminating length byte.
    const wire = [_]u8{ 0x1f, 'x', 1, 0, 255, 1, 0x50, 'T', 'A', 'I', 'L', '!' };
    var history: [65536]u8 = undefined;
    var original: BlockStreamDecoder = undefined;
    try original.reset(&history, .{});
    var first_fragment: [5]u8 = undefined;
    @memcpy(&first_fragment, wire[0..5]);
    var temporary: [7]u8 = undefined;
    const first = try original.step(.{ .bytes = &first_fragment }, &temporary);
    try std.testing.expectEqual(Status.need_input, first.status);
    try std.testing.expectEqual(5, first.consumed);
    try std.testing.expectEqual(1, first.produced);
    var restored: [281]u8 = undefined;
    @memcpy(restored[0..first.produced], temporary[0..first.produced]);

    var transferred = original;
    @memset(std.mem.asBytes(&original), 0xa7);
    @memset(&first_fragment, 0xa7);
    @memset(&temporary, 0xa7);
    var read = first.consumed;
    var written = first.produced;
    while (true) {
        var fragment: [1]u8 = undefined;
        const count = @min(fragment.len, wire.len - read);
        @memcpy(fragment[0..count], wire[read..][0..count]);
        const part = try transferred.step(
            .{ .bytes = fragment[0..count], .final = read + count == wire.len },
            &temporary,
        );
        @memcpy(restored[written..][0..part.produced], temporary[0..part.produced]);
        @memset(&fragment, 0xa7);
        @memset(&temporary, 0xa7);
        read += part.consumed;
        written += part.produced;
        if (part.status == .complete) break;
        try std.testing.expect(part.consumed != 0 or part.produced != 0);
    }
    try std.testing.expectEqual(wire.len, read);
    try std.testing.expectEqual(restored.len, written);
    try std.testing.expect(std.mem.allEqual(u8, restored[0..276], 'x'));
    try std.testing.expectEqualStrings("TAIL!", restored[276..]);
    try std.testing.expectEqual(wire.len, transferred.counts().input_bytes);
    try std.testing.expectEqual(restored.len, transferred.counts().output_bytes);
}
