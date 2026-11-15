//! Resumable LZ4 frame parsing and checksum verification. Call reset before use. State may transfer
//! between calls; retire the old copy so only one owner mutates the external workspace. Keep that
//! workspace stable and disjoint from the active owner. Dictionary setup copies its input; caller
//! fragments may retire after step. Copied descriptor and cumulative counts remain available after
//! completion. Internal fields are modified only by methods.

const std = @import("std");
const Xxh32 = @import("../xxhash.zig").Xxh32;
const InputFragment = @import("../lz4.zig").InputFragment;
const FrameDecodeWorkspace = @import("FrameDecodeWorkspace.zig");
const FrameStreamEncoder = @import("FrameStreamEncoder.zig"); // Inline framing comparisons only.
const FrameEncodeWorkspace = @import("FrameEncodeWorkspace.zig"); // Inline framing fixtures only.
const test_encode = @import("frame_encode.zig"); // Inline framing fixtures only.
const decode = @import("frame_decode.zig");
const framing = @import("frame.zig");
const blocks = @import("block.zig");
const FrameCounter = @import("FrameCounter.zig");
const format = @import("frame_format.zig");
const byte_ranges = @import("../common/byte_ranges.zig");
const overlaps = byte_ranges.overlapsChecked;
const magic = format.magic;
const skip_magic = format.skip_magic;
const FrameStreamDecoder = @This();

/// Streaming format, storage, resource and lifecycle failures. Missing dictionaries are reported by
/// Status.need_dictionary; output capacity is reported by Status.need_output.
pub const Error = blocks.decode.StreamDecoder.Error || error{
    InvalidFrame,
    ChecksumMismatch,
    ContentSizeMismatch,
    WrongDictionary,
};

/// Resumable policy. Dictionary bytes are copied at reset; extent and trailing data are
/// complete-call selections and do not constrain the capacity or finality of an individual
/// fragment.
pub const Options = struct {
    /// How to stop or advance at verified frame boundaries.
    frames: Selection = .single,
    /// Initial dictionary copied at reset; may also be supplied on a matching request.
    dictionary: ?framing.Dictionary = null,
    /// Cumulative frame byte/work/count and descriptor admission.
    limits: decode.Limits = .{},
};

/// Single stops at the first frame, including a skippable frame. Iterate returns frame_end and
/// waits for nextFrame; concatenate proceeds until explicit EOF.
pub const Selection = enum {
    /// Stop after the first ordinary or skippable frame, preserving following input.
    single,
    /// Streaming returns `Status.frame_end`; call `FrameStreamDecoder.nextFrame` to continue.
    iterate,
    /// Decode all frames until explicit EOF.
    concatenate,
};

/// Decoder backpressure, dictionary negotiation, frame boundary or completion.
pub const Status = enum {
    /// Supply more encoded input.
    need_input,
    /// Supply output capacity and resubmit any unconsumed input with the same final flag.
    need_output,
    /// Inspect `FrameStreamDecoder.descriptor`, then call `FrameStreamDecoder.setDictionary` with
    /// matching bytes.
    need_dictionary,
    /// One frame is verified; call `FrameStreamDecoder.nextFrame` to continue explicit iteration.
    frame_end,
    /// The selected frame policy has completed.
    complete,
};

/// Exact counts for this call; fragments are not retained.
pub const Progress = struct {
    /// Input prefix accepted by this call, in bytes.
    consumed: usize,
    /// Output prefix produced by this call, in bytes.
    produced: usize,
    /// Next caller action or completion condition.
    status: Status,
};

/// Streaming totals remain representable after more than usize.max bytes pass through a smaller
/// address space.
pub const Counts = struct {
    /// Encoded bytes admitted across ordinary and skippable frames.
    input_bytes: u64,
    /// Decoded bytes produced across ordinary frames.
    output_bytes: u64,
    /// Encoded input plus produced decoded bytes, excluding dictionary setup.
    work_units: u64,
    /// Ordinary and skippable frame headers admitted.
    frames: u64,
    /// Completely consumed skippable frames.
    skippable_frames: u64,
};

/// Borrowed history and copied-dictionary reservation; stable until reset or retirement.
workspace: *FrameDecodeWorkspace,
/// Raw sequence worker borrowing the history ring in workspace.
raw: blocks.decode.StreamDecoder,
/// Framing field or content operation resumed by the next step.
phase: Phase,
/// How a verified frame boundary advances the enclosing sequence.
policy: Selection,
/// Largest decoded block extent admitted from a descriptor, in bytes.
maximum_block_bytes: usize,
/// Admitted input, output, byte-work and frame totals with their enclosing ceilings.
counter: FrameCounter,
/// Read-only validated ordinary-frame metadata; null before admission or for a skippable frame.
descriptor: ?framing.Descriptor,
/// Number of completely consumed skippable frames.
skipped: u64,
/// Initialized suffix length in workspace.dictionary, in bytes.
dictionary_size: usize,
/// Copied application ID; present zero differs from absence.
dictionary_id: ?u32,
/// Distinguishes an explicitly supplied empty dictionary from no dictionary.
dictionary_supplied: bool,
/// Private staging for a fragmented descriptor or checksum/size field.
field_bytes: [15]u8,
/// Initialized prefix length of field_bytes, in bytes.
field_used: usize,
/// Validated descriptor length expected by the descriptor phase, in bytes.
field_needed: usize,
/// Encoded bytes left in the current ordinary block or skippable payload.
remaining: usize,
/// True when the current block is stored verbatim rather than compressed.
raw_block: bool,
/// Decoded bytes produced in the current block.
block_produced: usize,
/// Decoded bytes produced in the current ordinary frame.
frame_produced: u64,
/// Checksum of encoded bytes in the current block.
block_hash: Xxh32,
/// Checksum of all decoded content in the current ordinary frame.
content_hash: Xxh32,
/// EOF latched after all bytes of a final fragment have been consumed.
final_input: bool,

const Phase = enum {
    magic,
    descriptor_prefix,
    descriptor,
    dictionary,
    block_size,
    block,
    block_checksum,
    content_checksum,
    skip_size,
    skip,
    frame_end,
    done,
    failed,
};

/// Starts a stream, copying any configured dictionary. Setup allocates nothing; owners, workspace
/// and dictionary must be disjoint. A refused setup leaves the active decoder and its workspace
/// unchanged.
pub fn reset(
    self: *FrameStreamDecoder,
    workspace: *FrameDecodeWorkspace,
    options: Options,
) error{ Aliasing, SizeOverflow }!void {
    const state = std.mem.asBytes(self);
    const storage = std.mem.asBytes(workspace);
    if (try overlaps(state, storage)) return error.Aliasing;
    if (options.dictionary) |dict| {
        const bytes = format.dictionarySuffix(dict.bytes);
        if (try overlaps(bytes, state) or try overlaps(bytes, storage)) return error.Aliasing;
    }

    self.* = .{
        .workspace = workspace,
        .raw = undefined,
        .phase = .magic,
        .policy = options.frames,
        .maximum_block_bytes = options.limits.block_bytes,
        .counter = .init(options.limits),
        .descriptor = null,
        .skipped = 0,
        .dictionary_size = 0,
        .dictionary_id = null,
        .dictionary_supplied = false,
        .field_bytes = undefined,
        .field_used = 0,
        .field_needed = 0,
        .remaining = 0,
        .raw_block = false,
        .block_produced = 0,
        .frame_produced = 0,
        .block_hash = Xxh32.init(0),
        .content_hash = Xxh32.init(0),
        .final_input = false,
    };
    try self.raw.reset(&workspace.history, .{});
    if (options.dictionary) |dict| self.copyDictionary(dict);
}

/// Resolves a validated descriptor's dictionary request. IDs are compared exactly, including zero.
/// A wrong attempt leaves the request available.
pub fn setDictionary(
    self: *FrameStreamDecoder,
    id: u32,
    bytes: []const u8,
) error{ NeedReset, InvalidState, WrongDictionary, Aliasing, SizeOverflow }!void {
    if (self.phase == .failed) return error.NeedReset;
    if (self.phase != .dictionary) return error.InvalidState;
    if (self.descriptor.?.dictionary_id.? != id) return error.WrongDictionary;
    const suffix = format.dictionarySuffix(bytes);
    if (try overlaps(suffix, std.mem.asBytes(self))) return error.Aliasing;
    if (try overlaps(suffix, std.mem.asBytes(self.workspace))) return error.Aliasing;
    self.copyDictionary(.{ .bytes = bytes, .id = id });
    try self.beginContent();
}

/// Releases an iterate-policy frame_end event. EOF is still remembered; a following step at final
/// EOF completes without inventing another frame.
pub fn nextFrame(self: *FrameStreamDecoder) error{ NeedReset, InvalidState }!void {
    if (self.phase == .failed) return error.NeedReset;
    if (self.phase != .frame_end) return error.InvalidState;
    self.phase = .magic;
}

/// Returns framing totals after admitted fields and successful raw steps. A failing raw step
/// publishes no progress here; its private partial charges are excluded.
pub fn counts(self: *const FrameStreamDecoder) Counts {
    return .{
        .input_bytes = self.counter.input,
        .output_bytes = self.counter.output,
        .work_units = self.counter.work_units,
        .frames = self.counter.frames,
        .skippable_frames = self.skipped,
    };
}

/// Advances a stream. A frame_end consumes exactly its own footer; no following magic is lost to
/// lookahead. Empty steps after completion return zero progress. Every step error requires reset
/// before reuse.
pub fn step(self: *FrameStreamDecoder, input: InputFragment, output: []u8) Error!Progress {
    if (self.phase == .failed) return error.NeedReset;
    errdefer self.phase = .failed;
    const state = std.mem.asBytes(self);
    const storage = std.mem.asBytes(self.workspace);
    if (try overlaps(input.bytes, output)) return error.Aliasing;
    if (try overlaps(input.bytes, state) or try overlaps(output, state)) return error.Aliasing;
    if (try overlaps(input.bytes, storage) or try overlaps(output, storage)) {
        return error.Aliasing;
    }
    if (self.final_input and input.bytes.len != 0) return error.InvalidState;

    // The phase machine reads each field across fragments, negotiates dictionaries before content,
    // and stops exactly after a frame footer. Encoded input and decoded output are never retained
    // as caller slices between these transitions.
    var read: usize = 0;
    var written: usize = 0;
    while (true) switch (self.phase) {
        .magic => {
            const at_end = read == input.bytes.len and (input.final or self.final_input);
            if (self.field_used == 0 and at_end and self.counter.frames != 0) {
                self.phase = .done;
                continue;
            }
            if (!try self.field(input.bytes, &read, 4)) {
                return self.blocked(input, read, written, .need_input);
            }
            const tag = std.mem.readInt(u32, self.field_bytes[0..4], .little);
            self.field_used = 0;
            try self.counter.frame();
            self.descriptor = null;
            if (tag & 0xfffffff0 == skip_magic) {
                self.phase = .skip_size;
            } else {
                if (tag != magic) return error.InvalidFrame;
                self.phase = .descriptor_prefix;
            }
        },
        .descriptor_prefix => {
            if (!try self.field(input.bytes, &read, 2)) {
                return self.blocked(input, read, written, .need_input);
            }
            self.field_needed = try format.descriptorSize(self.field_bytes[0..2]);
            self.phase = .descriptor;
        },
        .descriptor => {
            if (!try self.field(input.bytes, &read, self.field_needed)) {
                return self.blocked(input, read, written, .need_input);
            }
            const info = try format.parseDescriptor(self.field_bytes[0..self.field_needed]);
            self.field_used = 0;
            if (info.block_size.bytes() > self.maximum_block_bytes) return error.LimitExceeded;
            self.descriptor = info;
            if (info.dictionary_id) |id| {
                const resolved = self.dictionary_supplied and self.dictionary_id == id;
                if (!resolved) {
                    self.phase = .dictionary;
                    continue;
                }
            }
            try self.beginContent();
        },
        .dictionary => return self.blocked(input, read, written, .need_dictionary),
        .block_size => {
            if (!try self.field(input.bytes, &read, 4)) {
                return self.blocked(input, read, written, .need_input);
            }
            const value = std.mem.readInt(u32, self.field_bytes[0..4], .little);
            self.field_used = 0;
            if (value == 0) {
                if (self.descriptor.?.content_size) |expected| {
                    if (self.frame_produced != expected) return error.ContentSizeMismatch;
                }
                if (self.descriptor.?.content_checksum) {
                    self.phase = .content_checksum;
                } else {
                    self.endFrame();
                }
                continue;
            }
            self.remaining = value & 0x7fffffff;
            self.raw_block = value & 0x80000000 != 0;
            if (self.remaining > self.descriptor.?.block_size.bytes()) return error.InvalidFrame;
            const info = self.descriptor.?;
            const content_left = if (info.content_size) |size| size - self.frame_produced else std
                .math.maxInt(
                u64,
            );
            try self.raw.nextBlock(
                .{
                    .retain_history = !info.independent,
                    .limits = .{
                        .input_bytes = self.counter.limits.input_bytes - self.counter.input,
                        .output_bytes = @min(
                            info.block_size.bytes(),
                            self.counter.limits.output_bytes - self.counter.output,
                            content_left,
                        ),
                        .work_units = self.counter.limits.work_units - self.counter.work_units,
                    },
                },
            );
            if (self.descriptor.?.independent) {
                try self.raw.setDictionary(self.workspace.dictionary[0..self.dictionary_size]);
            }
            self.block_produced = 0;
            self.block_hash = Xxh32.init(0);
            self.phase = .block;
        },
        .block => {
            // A stored block copies one byte in for each byte out. A compressed block delegates
            // sequence parsing to the raw decoder. Both paths update the container counters below,
            // while block and content checksums cover different byte streams.
            const info = self.descriptor.?;
            const available_input = @min(self.remaining, input.bytes.len - read);
            const available_output = @min(
                output.len - written,
                info.block_size.bytes() - self.block_produced,
            );
            const allowed_output = self.counter.outputCapacity(available_output);
            var consumed: usize = 0;
            var produced: usize = 0;
            var complete = false;
            if (self.raw_block) {
                const remaining_input = self.counter.limits.input_bytes - self.counter.input;
                const half_work = (self.counter.limits.work_units - self.counter.work_units) / 2;
                const count: usize = @intCast(
                    @min(available_input, allowed_output, remaining_input, half_work),
                );
                if (count == 0 and available_input != 0 and available_output != 0)
                    return error.LimitExceeded;
                try self.counter.add(count, count);
                if (count != 0) {
                    @memcpy(output[written..][0..count], input.bytes[read..][0..count]);
                    try self.raw.appendHistory(output[written..][0..count]);
                }
                consumed = count;
                produced = count;
                complete = count == self.remaining;
            } else {
                // Charge parsing and output before work, using the exact remainder of the
                // container's cumulative byte budgets.
                const remaining_input = self.counter.limits.input_bytes - self.counter.input;
                const remaining_output = self.counter.limits.output_bytes - self.counter.output;
                const remaining_work = self.counter.limits.work_units - self.counter.work_units;
                const content_left: u64 = blk: {
                    const size = info.content_size orelse break :blk std.math.maxInt(u64);
                    break :blk size - self.frame_produced;
                };
                const content_limited = blk: {
                    const block_left = info.block_size.bytes() - self.block_produced;
                    if (content_left >= block_left or content_left > remaining_output)
                        break :blk false;
                    if (available_input > remaining_input) break :blk false;
                    if (remaining_work < available_input) break :blk false;
                    break :blk content_left <= remaining_work - available_input;
                };
                const part = self.raw.step(
                    .{
                        .bytes = input.bytes[read..][0..available_input],
                        .final = available_input == self.remaining,
                    },
                    output[written..][0..allowed_output],
                ) catch |err| {
                    @branchHint(.unlikely);
                    if (err == error.LimitExceeded and content_limited)
                        return error.ContentSizeMismatch;
                    return err;
                };
                consumed = part.consumed;
                produced = part.produced;
                try self.counter.add(consumed, produced);
                complete = part.status == .complete;
                if (part.status == .need_output and produced == allowed_output and allowed_output ==
                    0 and self.block_produced == info.block_size.bytes()) return error.InvalidFrame;
            }
            if (info.block_checksum) self.block_hash.update(input.bytes[read..][0..consumed]);
            if (info.content_checksum) self.content_hash.update(output[written..][0..produced]);
            self.frame_produced = std.math.add(
                u64,
                self.frame_produced,
                produced,
            ) catch return error.CounterOverflow;
            self.block_produced += produced;
            read += consumed;
            written += produced;
            self.remaining -= consumed;
            if (info.content_size) |expected| {
                if (self.frame_produced > expected) return error.ContentSizeMismatch;
            }
            if (complete) {
                std.debug.assert(self.remaining == 0);
                self.phase = if (info.block_checksum) .block_checksum else .block_size;
                continue;
            }
            if (allowed_output < available_output and produced == allowed_output)
                return error.LimitExceeded;
            if (written == output.len) return self.blocked(input, read, written, .need_output);
            if (read == input.bytes.len) return self.blocked(input, read, written, .need_input);
        },
        .block_checksum, .content_checksum => {
            // Block checksums cover encoded block bytes; content checksums cover recovered frame
            // bytes. Their phase selects the matching accumulator.
            if (!try self.field(input.bytes, &read, 4)) {
                return self.blocked(input, read, written, .need_input);
            }
            const expected = std.mem.readInt(u32, self.field_bytes[0..4], .little);
            self.field_used = 0;
            const actual = blk: {
                if (self.phase == .block_checksum) break :blk self.block_hash.final();
                break :blk self.content_hash.final();
            };
            if (expected != actual) return error.ChecksumMismatch;
            if (self.phase == .block_checksum) {
                self.phase = .block_size;
            } else {
                self.endFrame();
            }
        },
        .skip_size => {
            if (!try self.field(input.bytes, &read, 4)) {
                return self.blocked(input, read, written, .need_input);
            }
            self.remaining = std.mem.readInt(u32, self.field_bytes[0..4], .little);
            self.field_used = 0;
            self.phase = .skip;
        },
        .skip => {
            // Skippable payload contributes to input/work limits but never to decoded output.
            const count = @min(self.remaining, input.bytes.len - read);
            try self.counter.add(count, 0);
            read += count;
            self.remaining -= count;
            if (self.remaining != 0) return self.blocked(input, read, written, .need_input);
            self.skipped = std.math.add(u64, self.skipped, 1) catch return error.CounterOverflow;
            self.endFrame();
        },
        .frame_end => return self.blocked(input, read, written, .frame_end),
        .done => return self.blocked(input, read, written, .complete),
        .failed => unreachable,
    };
}

fn beginContent(
    self: *FrameStreamDecoder,
) error{ NeedReset, InvalidState, Aliasing, SizeOverflow }!void {
    try self.raw.reset(&self.workspace.history, .{});
    try self.raw.setDictionary(self.workspace.dictionary[0..self.dictionary_size]);
    self.frame_produced = 0;
    self.content_hash = Xxh32.init(0);
    self.phase = .block_size;
}

fn copyDictionary(self: *FrameStreamDecoder, dict: framing.Dictionary) void {
    const bytes = format.dictionarySuffix(dict.bytes);
    @memcpy(self.workspace.dictionary[0..bytes.len], bytes);
    self.dictionary_size = bytes.len;
    self.dictionary_id = dict.id;
    self.dictionary_supplied = true;
}

fn endFrame(self: *FrameStreamDecoder) void {
    self.phase = switch (self.policy) {
        .single => .done,
        .iterate => .frame_end,
        .concatenate => .magic,
    };
}

fn field(self: *FrameStreamDecoder, bytes: []const u8, read: *usize, needed: usize) Error!bool {
    const count = @min(needed - self.field_used, bytes.len - read.*);
    try self.counter.add(count, 0);
    @memcpy(self.field_bytes[self.field_used..][0..count], bytes[read.*..][0..count]);
    read.* += count;
    self.field_used += count;
    return self.field_used == needed;
}

fn blocked(
    self: *FrameStreamDecoder,
    input: InputFragment,
    read: usize,
    written: usize,
    status: Status,
) Error!Progress {
    if (input.final and read == input.bytes.len) self.final_input = true;
    if (status == .need_input and self.final_input) return error.Truncated;
    return .{ .consumed = read, .produced = written, .status = status };
}

test "LZ4 frame streaming every short split and retired one byte buffers" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try FrameDecodeWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    var wire: [1024]u8 = undefined;
    const source = "one dictionary phrase; one dictionary phrase; TAIL!";
    const dictionary = "one dictionary phrase; ";
    const encoded = try test_encode.into(
        source,
        &wire,
        .{ .workspace = encoder_workspace },
        .{
            .independent = false,
            .block_checksum = true,
            .content_size = source.len,
            .dictionary = .{ .bytes = dictionary, .id = 91 },
        },
    );
    for (0..encoded.len + 1) |split| {
        var decoder: FrameStreamDecoder = undefined;
        try decoder.reset(decoder_workspace, .{});
        var output: [source.len]u8 = undefined;
        var read: usize = 0;
        var written: usize = 0;
        while (true) {
            const end = if (read < split) split else encoded.len;
            const part = try decoder.step(
                .{ .bytes = encoded[read..end], .final = end == encoded.len },
                output[written..],
            );
            read += part.consumed;
            written += part.produced;
            if (part.status == .need_dictionary) {
                try std.testing.expectEqual(@as(?u32, 91), decoder.descriptor.?.dictionary_id);
                try std.testing.expectError(
                    error.WrongDictionary,
                    decoder.setDictionary(92, dictionary),
                );
                try decoder.setDictionary(91, dictionary);
            } else if (part.status == .complete) break;
        }
        try std.testing.expectEqual(encoded.len, read);
        try std.testing.expectEqualStrings(source, &output);
    }
    var decoder: FrameStreamDecoder = undefined;
    try decoder.reset(decoder_workspace, .{ .dictionary = .{ .bytes = dictionary, .id = 91 } });
    var output: [source.len]u8 = undefined;
    var read: usize = 0;
    var written: usize = 0;
    while (true) {
        var fragment: [1]u8 = undefined;
        const size: usize = @intFromBool(read < encoded.len);
        if (size != 0) fragment[0] = encoded[read];
        var temporary: [1]u8 = undefined;
        const part = try decoder.step(
            .{ .bytes = fragment[0..size], .final = read + size == encoded.len },
            &temporary,
        );
        @memcpy(output[written..][0..part.produced], temporary[0..part.produced]);
        @memset(&fragment, 0xa7);
        @memset(&temporary, 0xa7);
        read += part.consumed;
        written += part.produced;
        if (part.status == .complete) break;
        try std.testing.expect(part.consumed != 0 or part.produced != 0);
    }
    try std.testing.expectEqualStrings(source, &output);
    try std.testing.expectEqual(encoded.len + source.len, decoder.counts().work_units);
}

test "LZ4 frame concatenation skippable values iteration and lookahead" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try FrameDecodeWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    var wire: [256]u8 = undefined;
    const first = try test_encode.into("first", &wire, .{ .workspace = encoder_workspace }, .{});
    const first_size = first.len;
    var cursor = first_size;
    for (0..16) |i| {
        std.mem.writeInt(u32, wire[cursor..][0..4], skip_magic + @as(u32, @intCast(i)), .little);
        std.mem.writeInt(u32, wire[cursor + 4 ..][0..4], 1, .little);
        wire[cursor + 8] = @intCast(i);
        cursor += 9;
    }
    const second = try test_encode.into(
        "second",
        wire[cursor..],
        .{ .workspace = encoder_workspace },
        .{},
    );
    const end = cursor + second.len;
    var output: [11]u8 = undefined;
    try std.testing.expectEqual(first_size, (try decode.into(wire[0..end], &output, .{})).consumed);
    const joined = try decode.into(wire[0..end], &output, .{ .frames = .concatenate });
    try std.testing.expectEqual(18, joined.frames);
    try std.testing.expectEqual(16, joined.skippable_frames);
    try std.testing.expectEqualStrings("firstsecond", &output);
    for ([_]FrameStreamDecoder.Selection{ .iterate, .concatenate }) |policy| {
        var decoder: FrameStreamDecoder = undefined;
        try decoder.reset(decoder_workspace, .{ .frames = policy });
        var read: usize = 0;
        var written: usize = 0;
        var events: usize = 0;
        while (true) {
            const part = try decoder.step(
                .{ .bytes = wire[read..end], .final = true },
                output[written..],
            );
            read += part.consumed;
            written += part.produced;
            if (part.status == .complete) break;
            try std.testing.expectEqual(FrameStreamDecoder.Status.frame_end, part.status);
            if (events == 0) try std.testing.expectEqual(first_size, read);
            events += 1;
            try decoder.nextFrame();
        }
        try std.testing.expectEqual(end, read);
        try std.testing.expectEqualStrings("firstsecond", &output);
        try std.testing.expectEqual(@as(usize, if (policy == .iterate) 18 else 0), events);
    }
}

test "LZ4 frame truncation checksums resource limits poisoning and overflow" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try FrameDecodeWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    var wire: [256]u8 = undefined;
    const source = "abcdefabcdefabcdefabcdefabcdefabcdefTAIL!";
    const frame = try test_encode.into(
        source,
        &wire,
        .{ .workspace = encoder_workspace },
        .{ .block_checksum = true },
    );
    var output: [source.len]u8 = undefined;
    for (0..frame.len) |cut| {
        if (decode.into(frame[0..cut], &output, .{})) |_| {
            return error.TruncationAccepted;
        } else |_| {}
        var decoder: FrameStreamDecoder = undefined;
        try decoder.reset(decoder_workspace, .{});
        if (decoder.step(.{ .bytes = frame[0..cut], .final = true }, &output)) |_| {
            return error.TruncationAccepted;
        } else |_| {}
        try std.testing.expectError(error.NeedReset, decoder.step(.{ .bytes = &.{} }, &output));
    }
    for (0..frame.len) |i| {
        wire[i] ^= 1;
        if (decode.into(frame, &output, .{})) |_| {
            return error.MutationAccepted;
        } else |_| {}
        wire[i] ^= 1;
    }
    const limits: decode.Limits = .{
        .input_bytes = frame.len,
        .output_bytes = source.len,
        .work_units = frame.len + source.len,
        .frames = 1,
    };
    _ = try decode.into(frame, &output, .{ .limits = limits });
    var decoder: FrameStreamDecoder = undefined;
    try decoder.reset(decoder_workspace, .{ .limits = limits });
    try std.testing.expectEqual(
        FrameStreamDecoder.Status.complete,
        (try decoder.step(.{ .bytes = frame, .final = true }, &output)).status,
    );
    var short = limits;
    short.work_units -= 1;
    try std.testing.expectError(
        error.LimitExceeded,
        decode.into(frame, &output, .{ .limits = short }),
    );
    try decoder.reset(decoder_workspace, .{ .limits = short });
    try std.testing.expectError(
        error.LimitExceeded,
        decoder.step(.{ .bytes = frame, .final = true }, &output),
    );
    try std.testing.expectError(error.SizeOverflow, test_encode.bound(std.math.maxInt(usize), .{}));
    try std.testing.expectError(
        error.ContentSizeMismatch,
        test_encode.into(
            source,
            &wire,
            .{ .workspace = encoder_workspace },
            .{ .content_size = source.len - 1 },
        ),
    );
    try decoder.reset(decoder_workspace, .{});
    decoder.counter.input = std.math.maxInt(u64);
    try std.testing.expectError(error.CounterOverflow, decoder.step(.{ .bytes = frame }, &output));
}

test "LZ4 frame owners reject aliases and preserve full width counts" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try FrameDecodeWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    var encoder: FrameStreamEncoder = undefined;
    try encoder.reset(.{ .workspace = encoder_workspace }, .{});
    var output: [64]u8 = undefined;
    try std.testing.expectError(
        error.Aliasing,
        encoder.step(std.mem.asBytes(&encoder)[0..1], &output, .finish),
    );
    try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
    var decoder: FrameStreamDecoder = undefined;
    try decoder.reset(decoder_workspace, .{});
    try std.testing.expectError(
        error.Aliasing,
        decoder.step(.{ .bytes = decoder_workspace.dictionary[0..1] }, &output),
    );
    try decoder.reset(decoder_workspace, .{});
    decoder.counter.input = 0x1_0000_0001;
    decoder.counter.output = 0x1_0000_0002;
    try std.testing.expectEqual(@as(u64, 0x1_0000_0001), decoder.counts().input_bytes);
    try std.testing.expectEqual(@as(u64, 0x1_0000_0002), decoder.counts().output_bytes);
}

// Raw block ceilings must be refreshed at a boundary while frame limits remain cumulative.
test "LZ4 frame block ceilings survive fragments and distinguish content size" {
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 65553);
    defer allocator.free(source);
    @memset(source, 'A');
    const encoder_workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try FrameDecodeWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    const options: test_encode.Options = .{
        .independent = false,
        .block_checksum = true,
        .content_size = source.len,
    };
    const wire_storage = try allocator.alloc(u8, try test_encode.bound(source.len, options));
    defer allocator.free(wire_storage);
    const wire = try test_encode.into(
        source,
        wire_storage,
        .{ .workspace = encoder_workspace },
        options,
    );
    const output = try allocator.alloc(u8, source.len + 17);
    defer allocator.free(output);
    @memset(output, 0xa7);
    const limits: decode.Limits = .{
        .input_bytes = wire.len,
        .output_bytes = source.len,
        .work_units = wire.len + source.len,
        .frames = 1,
    };
    var decoder: FrameStreamDecoder = undefined;
    try decoder.reset(decoder_workspace, .{ .limits = limits });
    var read: usize = 0;
    var written: usize = 0;
    while (true) {
        const end = @min(read + 23, wire.len);
        const part = try decoder.step(
            .{ .bytes = wire[read..end], .final = end == wire.len },
            output[written..][0..@min(31, output.len - written)],
        );
        read += part.consumed;
        written += part.produced;
        if (part.status == .complete) break;
        try std.testing.expect(part.consumed != 0 or part.produced != 0);
    }
    try std.testing.expectEqual(wire.len, read);
    try std.testing.expectEqualSlices(u8, source, output[0..written]);
    try std.testing.expect(std.mem.allEqual(u8, output[written..], 0xa7));
    try std.testing.expectEqual(wire.len + source.len, decoder.counts().work_units);
    inline for (.{ "input_bytes", "output_bytes", "work_units" }) |limit_field| {
        var short = limits;
        @field(short, limit_field) -= 1;
        try decoder.reset(decoder_workspace, .{ .limits = short });
        try std.testing.expectError(
            error.LimitExceeded,
            decoder.step(.{ .bytes = wire, .final = true }, output),
        );
        try std.testing.expectError(error.NeedReset, decoder.step(.{ .bytes = &.{} }, output));
    }

    // A valid smaller declaration is a content error; a tighter resource ceiling wins instead.
    const declared: framing.Descriptor = .{
        .block_size = options.block_size,
        .independent = options.independent,
        .block_checksum = options.block_checksum,
        .content_checksum = options.content_checksum,
        .content_size = source.len - 1,
        .dictionary_id = if (options.dictionary) |dict| dict.id else null,
    };
    var header: [19]u8 = undefined;
    const header_size = format.writeHeader(&header, declared);
    @memcpy(wire[0..header_size], header[0..header_size]);
    try decoder.reset(decoder_workspace, .{});
    try std.testing.expectError(
        error.ContentSizeMismatch,
        decoder.step(.{ .bytes = wire, .final = true }, output),
    );
    try decoder.reset(decoder_workspace, .{ .limits = .{ .output_bytes = source.len - 2 } });
    try std.testing.expectError(
        error.LimitExceeded,
        decoder.step(.{ .bytes = wire, .final = true }, output),
    );
}

test "LZ4 frame decoder transfer retains a partial descriptor" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try FrameDecodeWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    const source = "transfer history; transfer history; TAIL!";
    var dictionary = "transfer history; ".*;
    var encoded: [256]u8 = undefined;
    const wire = try test_encode.into(
        source,
        &encoded,
        .{ .workspace = encoder_workspace },
        .{
            .independent = false,
            .block_checksum = true,
            .content_size = source.len,
            .dictionary = .{ .bytes = &dictionary, .id = 23 },
        },
    );
    var original: FrameStreamDecoder = undefined;
    try original.reset(decoder_workspace, .{ .dictionary = .{ .bytes = &dictionary, .id = 23 } });
    @memset(&dictionary, 0xa7);
    // Magic is complete, but only the first descriptor byte has arrived.
    var first_fragment: [5]u8 = undefined;
    @memcpy(&first_fragment, wire[0..5]);
    const first = try original.step(.{ .bytes = &first_fragment }, &.{});
    try std.testing.expectEqual(Status.need_input, first.status);
    try std.testing.expectEqual(5, first.consumed);
    try std.testing.expectEqual(0, first.produced);

    var transferred = original;
    @memset(std.mem.asBytes(&original), 0xa7);
    @memset(&first_fragment, 0xa7);
    var restored: [source.len]u8 = undefined;
    var read = first.consumed;
    var written: usize = 0;
    while (true) {
        var fragment: [1]u8 = undefined;
        const count = @min(fragment.len, wire.len - read);
        @memcpy(fragment[0..count], wire[read..][0..count]);
        var temporary: [3]u8 = undefined;
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
        try std.testing.expect(part.status != .need_dictionary);
        try std.testing.expect(part.consumed != 0 or part.produced != 0);
    }
    try std.testing.expectEqual(wire.len, read);
    try std.testing.expectEqual(source.len, written);
    try std.testing.expectEqualStrings(source, &restored);
    try std.testing.expectEqual(@as(?u32, 23), transferred.descriptor.?.dictionary_id);
    try std.testing.expectEqual(wire.len + source.len, transferred.counts().work_units);
}
