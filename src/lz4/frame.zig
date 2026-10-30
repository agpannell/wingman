//! Standard LZ4 frames: bounded recovery, resumable decoding and encoding. The container owns
//! descriptors, dictionary IDs, XXHash32 checksums and frame boundaries; the raw codec owns LZ4
//! sequences. Version-1 frames and all sixteen skippable magic values are supported. The obsolete
//! legacy format is rejected.
//!
//! `decodeFrame` uses complete input and a bounded output reservation, returning exact
//! consumed/produced counts. Its default stops at one frame, leaving following bytes to the caller.
//! `.concatenate` verifies the entire supplied sequence. Skippable frames produce no output. Each
//! frame resets content history and checksum state; independent blocks reuse the initial
//! dictionary.
//!
//! The decoder's `reset` method borrows an address-stable `FrameDecoderWorkspace` value. Its `step`
//! method copies progress counts and retains no input/output fragment. A final input flag
//! identifies EOF; resubmit an unconsumed suffix with that flag. Dictionary IDs are application
//! identifiers, not hashes: resolve a `need_dictionary` status with a `setDictionary` call.
//! Dictionary bytes are copied and may then retire.
//!
//! The encoder's `reset` method borrows a reusable `FrameEncoderWorkspace` value. Its `step` method
//! accepts arbitrary fragments and copies pending data into that workspace. A `.flush` request
//! emits a short block and returns a `.flushed` status; a `.finish` request also emits the footer
//! and returns a `.complete` status. Resubmit unconsumed input with the same action. Flush does not
//! end a frame. The one-shot `encodeFrame` function uses the same deterministic block policy.
//! Allocation occurs only in explicit workspace create/destroy calls, which receive their
//! allocator. No owner retains an allocator.
//!
//! Use disjoint owners, workspaces, input and output. No padding or alignment is required for byte
//! spans. A step error requires reset. Failure can change private output; streamed output is
//! unverified until its block/content checks and declared content size succeed. Checksums detect
//! accidental corruption, not malicious substitution. Full-buffer recovery checks a block checksum
//! before decoding; streaming recovery checks it after producing private bytes.
//!
//! Format and reference APIs: https://github.com/lz4/lz4/blob/v1.10.0/doc/lz4_Frame_format.md
//! https://github.com/lz4/lz4/blob/v1.10.0/lib/lz4frame.h

const std = @import("std");

const xxhash32 = @import("../xxhash32.zig");
const lz4 = @import("block.zig");
const high_compression = @import("hc.zig");

const Input = lz4.Input;
const magic: u32 = 0x184d2204;
const skip_magic: u32 = 0x184d2a50;
const max_history = lz4.maximum_distance;

/// Supported decoded block reservations. Streaming recovery requires only its history workspace,
/// regardless of the maximum advertised block size.
pub const FrameBlockSize = enum(u3) {
    k64 = 4,
    k256 = 5,
    m1 = 6,
    m4 = 7,

    /// Maximum encoded or decoded data bytes in a frame block.
    pub fn bytes(self: FrameBlockSize) usize {
        const descriptor_id: std.math.Log2Int(usize) = @backingInt(self);
        const size_exponent = descriptor_id * 2 + 8;
        return @as(usize, 1) << size_exponent;
    }
};

/// External dictionary and optional application identifier. Dictionaries have no embedded
/// validation; supply identical bytes at encoding and decoding. Only the final 65,535 bytes can be
/// referenced.
pub const FrameDictionary = struct { bytes: []const u8, id: ?u32 = null };

/// A validated frame descriptor. A present zero content size or dictionary ID remains distinct from
/// an absent field.
pub const FrameInfo = struct {
    /// Maximum stored or decoded bytes in an ordinary frame block.
    block_size: FrameBlockSize,
    /// True when every block starts from the initial dictionary rather than earlier blocks.
    independent: bool,
    /// A checksum follows each encoded block.
    block_checksum: bool,
    /// A checksum of all decoded content follows the final block.
    content_checksum: bool,
    /// Declared decoded byte count; null means the frame omits it.
    content_size: ?u64,
    /// Application-selected dictionary ID; null means the frame omits it.
    dictionary_id: ?u32,
};

/// Single stops at the first frame, including a skippable frame. Iterate returns frame_end and
/// waits for nextFrame; concatenate proceeds until explicit EOF.
pub const FramePolicy = enum {
    /// Stop after the first ordinary or skippable frame, preserving following input.
    single,
    /// Streaming returns `FrameDecodeStatus.frame_end`; call `FrameDecoder.nextFrame` to continue.
    /// Complete-buffer decoding stops after one frame and returns its byte counts.
    iterate,
    /// Decode all frames until explicit EOF; complete-buffer decoding uses the exact input end.
    concatenate,
};

/// Cumulative admission across ordinary/skippable frames. Work charges accepted encoded bytes plus
/// produced decoded bytes once, including skippable payload; dictionary setup is excluded.
pub const FrameDecodeLimits = struct {
    input_bytes: u64 = std.math.maxInt(u64),
    output_bytes: u64 = std.math.maxInt(u64),
    work_units: u64 = std.math.maxInt(u64),
    frames: u64 = std.math.maxInt(u64),
    /// Reject a descriptor advertising a larger decoded block, even if its actual block is smaller.
    block_bytes: usize = 4 * 1024 * 1024,
};

/// Cumulative accepted source plus produced wire bytes, including headers and checksums. HC search
/// has its own independently measured effort allowance; dictionary setup is excluded from byte
/// work.
pub const FrameEncodeLimits = struct {
    input_bytes: u64 = std.math.maxInt(u64),
    output_bytes: u64 = std.math.maxInt(u64),
    work_units: u64 = std.math.maxInt(u64),
    frames: u64 = std.math.maxInt(u64),
};

const CounterLimits = struct {
    input_bytes: u64 = std.math.maxInt(u64),
    output_bytes: u64 = std.math.maxInt(u64),
    work_units: u64 = std.math.maxInt(u64),
    frames: u64 = std.math.maxInt(u64),
};

/// Complete frame policy; dictionaries without IDs apply out of band to descriptors without IDs.
pub const FrameDecodeOptions = struct {
    frames: FramePolicy = .single,
    dictionary: ?FrameDictionary = null,
    output_size: lz4.OutputSize = .bounded,
    trailing_data: TrailingData = .allow,
    limits: FrameDecodeLimits = .{},
};

/// Whether bytes following the selected frames may remain unconsumed.
pub const TrailingData = enum { allow, reject };

/// Resumable policy. Dictionary bytes are copied at reset; extent and trailing data are
/// complete-call selections and do not constrain the capacity or finality of an individual
/// fragment.
pub const FrameStreamDecodeOptions = struct {
    frames: FramePolicy = .single,
    dictionary: ?FrameDictionary = null,
    limits: FrameDecodeLimits = .{},
};

/// Selects the frame block encoder independently of its mutable scratch reservation. Frame
/// dictionaries belong to FrameEncodeOptions; a nonempty nested HC dictionary is InvalidOptions.
pub const FrameCompression = union(enum) { fast, hc: high_compression.HcEncodeOptions };

/// Mutable reservations for one encoding operation/owner. Unused HC capacity may be supplied with
/// fast policy; only the selected encoder's reservations are borrowed and checked.
pub const FrameEncodeStorage = struct {
    workspace: *FrameEncoderWorkspace,
    hc_workspace: ?*high_compression.HcEncoderWorkspace = null,
};

/// Encoding defaults to independent 64 KiB blocks with a content checksum. A supplied content size
/// is enforced, including an explicitly supplied zero.
pub const FrameEncodeOptions = struct {
    /// Maximum decoded bytes per block; workspace buffers must support this size.
    block_size: FrameBlockSize = .k64,
    /// Reset history to the initial dictionary for every block; false permits linked blocks.
    independent: bool = true,
    /// Emit a checksum after every encoded block.
    block_checksum: bool = false,
    /// Emit a checksum of all original content in the frame footer.
    content_checksum: bool = true,
    /// Optional original size. When supplied, finish requires exactly this many input bytes.
    content_size: ?u64 = null,
    /// Initial history and optional application dictionary ID, copied at reset.
    dictionary: ?FrameDictionary = null,
    /// Cumulative input/output, work and frame-count bounds.
    limits: FrameEncodeLimits = .{},

    /// Fast uses the greedy block encoder; HC search effort accumulates across the frame, including
    /// dictionary priming on every block.
    compression: FrameCompression = .fast,
};

/// Format, storage, dictionary and bounded-progress failures. Errors from step poison that owner
/// until reset. Wrong setDictionary attempts may be retried.
pub const FrameError = lz4.DecodeError || high_compression.HcError || error{
    InvalidOptions,
    InvalidFrame,
    ChecksumMismatch,
    ContentSizeMismatch,
    NeedDictionary,
    WrongDictionary,
};

/// Decoder backpressure, dictionary negotiation, frame boundary or completion.
pub const FrameDecodeStatus = enum {
    /// Supply more encoded input.
    need_input,
    /// Supply output capacity and resubmit any unconsumed input with the same final flag.
    need_output,
    /// Inspect `FrameDecoder.frame_info`, then call `FrameDecoder.setDictionary` with matching
    /// bytes.
    need_dictionary,
    /// One frame is verified; call `FrameDecoder.nextFrame` to continue explicit iteration.
    frame_end,
    /// The selected frame policy has completed.
    complete,
};

/// Exact counts for this call; fragments are not retained.
pub const FrameDecodeProgress = struct {
    consumed: usize,
    produced: usize,
    status: FrameDecodeStatus,
};

/// Encoder backpressure or action completion; decoder dictionary/frame events are not possible.
pub const FrameEncodeStatus = enum { need_input, need_output, flushed, complete };

/// Copied progress for one encode step; accepted fragments may retire on return.
pub const FrameEncodeProgress = struct {
    consumed: usize,
    produced: usize,
    status: FrameEncodeStatus,
};

/// Complete-buffer counts. Frames includes skippable frames; skippable_frames counts that subset.
/// Bytes after a single/iterated frame remain unconsumed.
pub const FrameDecodeResult = struct {
    consumed: usize,
    produced: usize,
    frames: u64,
    skippable_frames: u64,
};

/// Streaming totals remain representable after more than usize.max bytes pass through a smaller
/// address space.
pub const FrameDecodeCounts = struct {
    input_bytes: u64,
    output_bytes: u64,
    frames: u64,
    skippable_frames: u64,
};

/// Builds the eight-byte header of a skippable frame. Emit this copied value followed by exactly
/// payload_size application bytes when writing fragments.
pub fn skippableFrameHeader(payload_size: u32, tag: u4) [8]u8 {
    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], skip_magic + @as(u32, tag), .little);
    std.mem.writeInt(u32, header[4..8], payload_size, .little);
    return header;
}

/// Encodes application metadata as a skippable frame. Requires payload.len + 8 disjoint output
/// bytes and leaves spare capacity untouched. The wire size is limited to u32 payload bytes; no
/// checksum or allocation is added.
pub fn encodeSkippableFrame(payload: []const u8, output: []u8, tag: u4) FrameError![]u8 {
    if (payload.len > std.math.maxInt(u32)) return error.InputTooLarge;
    const size = std.math.add(usize, payload.len, 8) catch return error.SizeOverflow;
    if (try overlaps(payload, output)) return error.Aliasing;
    if (output.len < size) return error.OutputTooSmall;
    const header = skippableFrameHeader(@intCast(payload.len), tag);
    @memcpy(output[0..8], &header);
    @memcpy(output[8..size], payload);
    return output[0..size];
}

/// Recovers complete frames directly into bounded output without a workspace or allocation. The
/// used output prefix is result.produced bytes. Exact input ends and output capacity are enforced;
/// trailing capacity remains untouched. Iterate has the same single-frame behavior here; use
/// consumed to advance.
pub fn decodeFrame(
    source: []const u8,
    output: []u8,
    options: FrameDecodeOptions,
) FrameError!FrameDecodeResult {
    if (try overlaps(source, output)) return error.Aliasing;
    if (options.dictionary) |dict| {
        if (try overlaps(dictSuffix(dict.bytes), output)) return error.Aliasing;
    }

    var counter: Counter = .init(options.limits);
    var read: usize = 0;
    var written: usize = 0;
    var skipped: u64 = 0;
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
            const size = try descriptorSize(prefix);
            _ = try take(source, &read, size - 2, &counter);
            const info = try descriptor(source[read - size .. read]);
            if (info.block_size.bytes() > options.limits.block_bytes) return error.LimitExceeded;
            const dict = try dictionaryFor(info, options.dictionary);
            const begin = written;
            while (true) {
                const block_header = try take(source, &read, 4, &counter);
                const field = std.mem.readInt(u32, block_header[0..4], .little);
                if (field == 0) break;
                const count: usize = field & 0x7fffffff;
                if (count > info.block_size.bytes()) return error.InvalidFrame;
                const block = try take(source, &read, count, &counter);
                if (info.block_checksum) {
                    const checksum = try take(source, &read, 4, &counter);
                    const expected = std.mem.readInt(u32, checksum[0..4], .little);
                    if (xxhash32.hash(block) != expected) return error.ChecksumMismatch;
                }
                const capacity = @min(output.len - written, info.block_size.bytes());
                const allowed = counter.outputCapacity(capacity);
                const produced = blk: {
                    if (field & 0x80000000 != 0) {
                        if (count > allowed) {
                            if (allowed < capacity) return error.LimitExceeded;
                            return error.OutputTooSmall;
                        }
                        @memcpy(output[written..][0..count], block);
                        break :blk count;
                    }

                    const history: lz4.HistoryView = .{
                        .older = if (info.independent) &.{} else dict,
                        .newer = if (info.independent) dict else output[begin..written],
                    };
                    break :blk (lz4.decodeBlock(
                        block,
                        output[written..][0..allowed],
                        .{ .dictionary = history, .output_size = .bounded },
                    ) catch |err| {
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
                const actual = xxhash32.hash(output[begin..written]);
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

/// Address-stable streaming history and copied dictionary. Recovery requires 128 KiB regardless of
/// block size; no compressed block is buffered.
pub const FrameDecoderWorkspace = struct {
    history: [65536]u8,
    dictionary: [65536]u8,

    /// Allocates uninitialized storage at its final address.
    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*FrameDecoderWorkspace {
        return allocator.create(FrameDecoderWorkspace);
    }

    /// Releases this allocation using the allocator supplied to create.
    pub fn destroy(self: *FrameDecoderWorkspace, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

/// Resumable frame parser. Initialize at the final address with reset. Copied frame_info and
/// cumulative counts remain available after completion. Only its workspace is borrowed across
/// calls; dictionary setup copies its input.
pub const FrameDecoder = struct {
    workspace: *FrameDecoderWorkspace,
    raw: lz4.Decoder,
    phase: Phase,
    policy: FramePolicy,
    maximum_block_bytes: usize,
    counter: Counter,
    frame_info: ?FrameInfo,
    skipped: u64,
    dictionary_size: usize,
    dictionary_id: ?u32,
    dictionary_supplied: bool,
    field_bytes: [15]u8,
    field_used: usize,
    field_needed: usize,
    remaining: usize,
    raw_block: bool,
    block_produced: usize,
    frame_produced: u64,
    block_hash: xxhash32.Hasher,
    content_hash: xxhash32.Hasher,
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

    /// Starts a stream, copying any configured dictionary. Setup allocates nothing; owners,
    /// workspace and dictionary must be disjoint.
    pub fn reset(
        self: *FrameDecoder,
        workspace: *FrameDecoderWorkspace,
        options: FrameStreamDecodeOptions,
    ) FrameError!void {
        const state = std.mem.asBytes(self);
        const storage = std.mem.asBytes(workspace);
        if (try overlaps(state, storage)) return error.Aliasing;
        if (options.dictionary) |dict| {
            const bytes = dictSuffix(dict.bytes);
            if (try overlaps(bytes, state) or try overlaps(bytes, storage)) return error.Aliasing;
        }

        self.* = .{
            .workspace = workspace,
            .raw = undefined,
            .phase = .magic,
            .policy = options.frames,
            .maximum_block_bytes = options.limits.block_bytes,
            .counter = .init(options.limits),
            .frame_info = null,
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
            .block_hash = .init,
            .content_hash = .init,
            .final_input = false,
        };
        try self.raw.reset(&workspace.history, .{});
        if (options.dictionary) |dict| self.copyDictionary(dict);
    }

    /// Resolves a validated descriptor's dictionary request. IDs are compared exactly, including
    /// zero. A wrong attempt leaves the request available.
    pub fn setDictionary(self: *FrameDecoder, id: u32, bytes: []const u8) FrameError!void {
        if (self.phase == .failed) return error.NeedReset;
        if (self.phase != .dictionary) return error.InvalidState;
        if (self.frame_info.?.dictionary_id.? != id) return error.WrongDictionary;
        const suffix = dictSuffix(bytes);
        if (try overlaps(suffix, std.mem.asBytes(self))) return error.Aliasing;
        if (try overlaps(suffix, std.mem.asBytes(self.workspace))) return error.Aliasing;
        self.copyDictionary(.{ .bytes = bytes, .id = id });
        try self.beginContent();
    }

    /// Releases an iterate-policy frame_end event. EOF is still remembered; a following step at
    /// final EOF completes without inventing another frame.
    pub fn nextFrame(self: *FrameDecoder) FrameError!void {
        if (self.phase == .failed) return error.NeedReset;
        if (self.phase != .frame_end) return error.InvalidState;
        self.phase = .magic;
    }

    /// Copied cumulative accepted input and produced output counts.
    pub fn counts(self: *const FrameDecoder) FrameDecodeCounts {
        return .{
            .input_bytes = self.counter.input,
            .output_bytes = self.counter.output,
            .frames = self.counter.frames,
            .skippable_frames = self.skipped,
        };
    }

    /// Advances a stream. A frame_end consumes exactly its own footer; no following magic is lost
    /// to lookahead. A complete owner is idempotent.
    pub fn step(self: *FrameDecoder, input: Input, output: []u8) FrameError!FrameDecodeProgress {
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
                self.frame_info = null;
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
                self.field_needed = try descriptorSize(self.field_bytes[0..2]);
                self.phase = .descriptor;
            },
            .descriptor => {
                if (!try self.field(input.bytes, &read, self.field_needed)) {
                    return self.blocked(input, read, written, .need_input);
                }
                const info = try descriptor(self.field_bytes[0..self.field_needed]);
                self.field_used = 0;
                if (info.block_size.bytes() > self.maximum_block_bytes) return error.LimitExceeded;
                self.frame_info = info;
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
                    if (self.frame_info.?.content_size) |expected| {
                        if (self.frame_produced != expected) return error.ContentSizeMismatch;
                    }
                    if (self.frame_info.?.content_checksum) {
                        self.phase = .content_checksum;
                    } else {
                        self.endFrame();
                    }
                    continue;
                }
                self.remaining = value & 0x7fffffff;
                self.raw_block = value & 0x80000000 != 0;
                if (self.remaining > self.frame_info.?.block_size.bytes())
                    return error.InvalidFrame;
                try self.raw.nextBlock(!self.frame_info.?.independent);
                if (self.frame_info.?.independent) {
                    try self.raw.setDictionary(self.workspace.dictionary[0..self.dictionary_size]);
                }
                self.block_produced = 0;
                self.block_hash = .init;
                self.phase = .block;
            },
            .block => {
                const info = self.frame_info.?;
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
                    const half_work = (self.counter.limits.work_units - self.counter.work_units) /
                        2;
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
                    self.raw.limits = .{
                        .input_bytes = self.raw.input_bytes +| remaining_input,
                        .output_bytes = @min(
                            info.block_size.bytes(),
                            self.raw.output_bytes +| remaining_output,
                            self.raw.output_bytes +| content_left,
                        ),
                        .work_units = self.raw.work_units +| remaining_work,
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
                    if (part.status == .need_output and produced == allowed_output and
                        allowed_output == 0 and self.block_produced == info.block_size.bytes())
                        return error.InvalidFrame;
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
                const count = @min(self.remaining, input.bytes.len - read);
                try self.counter.add(count, 0);
                read += count;
                self.remaining -= count;
                if (self.remaining != 0) return self.blocked(input, read, written, .need_input);
                self.skipped = std.math.add(
                    u64,
                    self.skipped,
                    1,
                ) catch return error.CounterOverflow;
                self.endFrame();
            },
            .frame_end => return self.blocked(input, read, written, .frame_end),
            .done => return self.blocked(input, read, written, .complete),
            .failed => unreachable,
        };
    }

    fn beginContent(self: *FrameDecoder) FrameError!void {
        try self.raw.reset(&self.workspace.history, .{});
        try self.raw.setDictionary(self.workspace.dictionary[0..self.dictionary_size]);
        self.frame_produced = 0;
        self.content_hash = .init;
        self.phase = .block_size;
    }

    fn copyDictionary(self: *FrameDecoder, dict: FrameDictionary) void {
        const bytes = dictSuffix(dict.bytes);
        @memcpy(self.workspace.dictionary[0..bytes.len], bytes);
        self.dictionary_size = bytes.len;
        self.dictionary_id = dict.id;
        self.dictionary_supplied = true;
    }

    fn endFrame(self: *FrameDecoder) void {
        self.phase = switch (self.policy) {
            .single => .done,
            .iterate => .frame_end,
            .concatenate => .magic,
        };
    }

    fn field(self: *FrameDecoder, bytes: []const u8, read: *usize, needed: usize) FrameError!bool {
        const count = @min(needed - self.field_used, bytes.len - read.*);
        try self.counter.add(count, 0);
        @memcpy(self.field_bytes[self.field_used..][0..count], bytes[read.*..][0..count]);
        read.* += count;
        self.field_used += count;
        return self.field_used == needed;
    }

    fn blocked(
        self: *FrameDecoder,
        input: Input,
        read: usize,
        written: usize,
        status: FrameDecodeStatus,
    ) FrameError!FrameDecodeProgress {
        if (input.final and read == input.bytes.len) self.final_input = true;
        if (status == .need_input and self.final_input) return error.Truncated;
        return .{ .consumed = read, .produced = written, .status = status };
    }
};

/// Address-stable encoder storage. Reserve input and encoded block buffers for the selected block
/// size; history/dictionary/codec tables stay in this value. Construct with create rather than
/// copying a large temporary owner.
pub const FrameEncoderWorkspace = struct {
    input: []u8,
    encoded: []u8,
    history: [65536]u8,
    dictionary: [65536]u8,
    codec: lz4.EncoderWorkspace,

    /// Allocates the owner and both block buffers, cleaning up on failure.
    pub fn create(
        allocator: std.mem.Allocator,
        block_size: FrameBlockSize,
    ) std.mem.Allocator.Error!*FrameEncoderWorkspace {
        const self = try allocator.create(FrameEncoderWorkspace);
        errdefer allocator.destroy(self);
        self.input = try allocator.alloc(u8, block_size.bytes());
        errdefer allocator.free(self.input);
        const encoded_capacity = lz4.blockEncodeBound(block_size.bytes()) catch unreachable;
        self.encoded = try allocator.alloc(u8, encoded_capacity);
        return self;
    }

    /// Releases both full buffers and this owner with the construction allocator.
    pub fn destroy(self: *FrameEncoderWorkspace, allocator: std.mem.Allocator) void {
        allocator.free(self.encoded);
        allocator.free(self.input);
        allocator.destroy(self);
    }
};

/// Bounds one complete frame with the selected maximum block size. Streaming flushes may add
/// blocks; reserve/emit output incrementally in that case.
pub fn frameEncodeBound(input_bytes: usize, options: FrameEncodeOptions) FrameError!usize {
    const block_bytes = options.block_size.bytes();
    const whole_blocks = input_bytes / block_bytes;
    const partial_block: usize = @intFromBool(input_bytes % block_bytes != 0);
    const blocks = whole_blocks + partial_block;
    const block_overhead: usize = if (options.block_checksum) 8 else 4;
    const overhead = std.math.mul(usize, blocks, block_overhead) catch return error.SizeOverflow;
    const framing = std.math.add(usize, overhead, 27) catch return error.SizeOverflow;
    return std.math.add(usize, input_bytes, framing) catch error.SizeOverflow;
}

/// Encodes one complete frame with no allocation after workspace construction. Requires
/// `frameEncodeBound` capacity and returns the used output prefix. Size fields are optional; supply
/// source.len explicitly to serialize that field.
pub fn encodeFrame(
    source: []const u8,
    output: []u8,
    storage: FrameEncodeStorage,
    options: FrameEncodeOptions,
) FrameError![]u8 {
    if (output.len < try frameEncodeBound(source.len, options)) return error.OutputTooSmall;
    var encoder: FrameEncoder = undefined;
    try encoder.reset(storage, options);
    const result = try encoder.step(source, output, .finish);
    std.debug.assert(result.status == .complete and result.consumed == source.len);
    return output[0..result.produced];
}

/// Distinct streaming requests. Flush emits pending bytes without ending the frame. Finish enforces
/// the declared content size and emits its footer.
pub const FrameEncodeAction = enum {
    /// Accept source bytes and emit complete blocks while keeping the frame open.
    process,
    /// Emit a pending partial block and return `FrameEncodeStatus.flushed` without ending the
    /// frame.
    flush,
    /// Accept the final source bytes, enforce any declared size and emit the frame footer.
    finish,
};

/// Bounded greedy or HC frame encoder. Workspaces are borrowed between calls. Pending input and
/// dictionaries are copied; processed caller fragments may retire immediately. Reset at the final
/// address before use.
pub const FrameEncoder = struct {
    workspace: *FrameEncoderWorkspace,
    options: FrameEncodeOptions,
    hc_workspace: ?*high_compression.HcEncoderWorkspace,
    counter: Counter,
    input_used: usize,
    dictionary_size: usize,
    history_size: usize,
    pending: []const u8,
    small: [19]u8,
    prefix: [4]u8,
    suffix: [4]u8,
    body: []const u8,
    after_pending: Phase,
    phase: Phase,
    content_hash: xxhash32.Hasher,
    finish_requested: bool,
    hc_work: u64,

    const Phase = enum { pending, prefix, body, suffix, input, footer, done, failed };

    /// Begins a frame and copies the dictionary suffix. Existing buffer reservations may be reused
    /// for any block size that fits their capacity.
    pub fn reset(
        self: *FrameEncoder,
        storage: FrameEncodeStorage,
        options: FrameEncodeOptions,
    ) FrameError!void {
        const workspace = storage.workspace;
        const hc_workspace = switch (options.compression) {
            .fast => null,
            .hc => |policy| blk: {
                if (policy.dictionary.len != 0) return error.InvalidOptions;
                break :blk storage.hc_workspace orelse return error.InvalidOptions;
            },
        };
        const block_capacity = options.block_size.bytes();
        if (workspace.input.len < block_capacity) return error.OutputTooSmall;
        if (workspace.encoded.len < try lz4.blockEncodeBound(
            block_capacity,
        )) return error.OutputTooSmall;
        try checkEncoderStorage(self, workspace, hc_workspace, &.{});
        if (options.dictionary) |dict| {
            try checkEncoderStorage(self, workspace, hc_workspace, dictSuffix(dict.bytes));
        }

        self.* = .{
            .workspace = workspace,
            .options = options,
            .hc_workspace = hc_workspace,
            .counter = .init(options.limits),
            .input_used = 0,
            .dictionary_size = 0,
            .history_size = 0,
            .pending = &.{},
            .small = undefined,
            .prefix = undefined,
            .suffix = undefined,
            .body = &.{},
            .after_pending = .input,
            .phase = .pending,
            .content_hash = .init,
            .finish_requested = false,
            .hc_work = 0,
        };
        // End the options' caller dictionary borrow before reset returns.
        self.options.dictionary = null;
        if (options.dictionary) |dict| {
            const bytes = dictSuffix(dict.bytes);
            @memcpy(workspace.dictionary[0..bytes.len], bytes);
            @memcpy(workspace.history[0..bytes.len], bytes);
            self.dictionary_size = bytes.len;
            self.history_size = bytes.len;
        }
        try self.counter.frame();
        const size = writeHeader(&self.small, options);
        self.pending = self.small[0..size];
    }

    /// Advances framing and compression without allocation. Finish is latched only after all
    /// supplied input is accepted; subsequent calls drain with empty input. An explicit flush
    /// returns flushed exactly when drained.
    pub fn step(
        self: *FrameEncoder,
        input: []const u8,
        output: []u8,
        action: FrameEncodeAction,
    ) FrameError!FrameEncodeProgress {
        if (self.phase == .failed) return error.NeedReset;
        errdefer self.phase = .failed;
        if (try overlaps(input, output)) return error.Aliasing;
        try checkEncoderStorage(self, self.workspace, self.hc_workspace, input);
        try checkEncoderStorage(self, self.workspace, self.hc_workspace, output);
        if (self.finish_requested and input.len != 0) return error.InvalidState;

        var read: usize = 0;
        var written: usize = 0;
        while (true) switch (self.phase) {
            .pending => {
                const count = @min(self.pending.len, output.len - written);
                try self.counter.add(0, count);
                @memcpy(output[written..][0..count], self.pending[0..count]);
                self.pending = self.pending[count..];
                written += count;
                if (self.pending.len != 0) return .{
                    .consumed = read,
                    .produced = written,
                    .status = .need_output,
                };
                self.phase = self.after_pending;
            },
            .prefix => {
                self.pending = &self.prefix;
                self.after_pending = .body;
                self.phase = .pending;
            },
            .body => {
                self.pending = self.body;
                self.after_pending = if (self.options.block_checksum) .suffix else .input;
                self.phase = .pending;
            },
            .suffix => {
                self.pending = &self.suffix;
                self.after_pending = .input;
                self.phase = .pending;
            },
            .input => {
                const block_capacity = self.options.block_size.bytes();
                const count = @min(input.len - read, block_capacity - self.input_used);
                try self.counter.add(count, 0);
                if (self.options.content_size) |size| {
                    if (self.counter.input > size) return error.ContentSizeMismatch;
                }
                @memcpy(self.workspace.input[self.input_used..][0..count], input[read..][0..count]);
                if (self.options.content_checksum) {
                    self.content_hash.update(input[read..][0..count]);
                }
                self.input_used += count;
                read += count;
                const input_accepted = read == input.len;
                if (input_accepted and action == .finish) self.finish_requested = true;
                const flush_pending = blk: {
                    if (!input_accepted or self.input_used == 0) break :blk false;
                    break :blk action != .process or self.finish_requested;
                };
                if (self.input_used == block_capacity or flush_pending) {
                    try self.block();
                    continue;
                }
                if (self.finish_requested) {
                    self.phase = .footer;
                    continue;
                }
                return .{
                    .consumed = read,
                    .produced = written,
                    .status = if (action == .flush) .flushed else .need_input,
                };
            },
            .footer => {
                if (self.options.content_size) |size| {
                    if (self.counter.input != size) return error.ContentSizeMismatch;
                }
                @memset(self.small[0..4], 0);
                var size: usize = 4;
                if (self.options.content_checksum) {
                    std.mem.writeInt(u32, self.small[4..8], self.content_hash.final(), .little);
                    size += 4;
                }
                self.pending = self.small[0..size];
                self.after_pending = .done;
                self.phase = .pending;
            },
            .done => return .{ .consumed = read, .produced = written, .status = .complete },
            .failed => unreachable,
        };
    }

    fn block(self: *FrameEncoder) FrameError!void {
        const source = self.workspace.input[0..self.input_used];
        const dictionary = blk: {
            if (self.options.independent) {
                break :blk self.workspace.dictionary[0..self.dictionary_size];
            }
            break :blk self.workspace.history[0..self.history_size];
        };
        const encoded = blk: {
            if (self.hc_workspace) |hc| {
                var options = self.options.compression.hc;
                options.limits.work_units -= self.hc_work;
                options.dictionary = dictionary;
                const bytes = try high_compression.encodeBlockHc(
                    source,
                    self.workspace.encoded,
                    hc,
                    options,
                );
                self.hc_work += hc.stats.work_units;
                break :blk bytes;
            }
            break :blk try lz4.encodeBlock(
                source,
                self.workspace.encoded,
                &self.workspace.codec,
                .{ .dictionary = dictionary },
            );
        };

        const compressed = encoded.len < source.len;
        self.body = if (compressed) encoded else source;
        const size: u32 = @intCast(self.body.len);
        const stored_flag: u32 = if (compressed) 0 else 0x80000000;
        std.mem.writeInt(u32, &self.prefix, size | stored_flag, .little);
        if (self.options.block_checksum) {
            std.mem.writeInt(u32, &self.suffix, xxhash32.hash(self.body), .little);
        }

        if (!self.options.independent) {
            const kept = dictSuffix(source);
            const old = @min(self.history_size, max_history - kept.len);
            std.mem.copyForwards(
                u8,
                self.workspace.history[0..old],
                self.workspace.history[self.history_size - old .. self.history_size],
            );
            @memcpy(self.workspace.history[old..][0..kept.len], kept);
            self.history_size = old + kept.len;
        }

        self.input_used = 0;
        self.phase = .prefix;
    }
};

fn dictSuffix(bytes: []const u8) []const u8 {
    return bytes[bytes.len - @min(bytes.len, max_history) ..];
}

fn overlaps(a: []const u8, b: []const u8) FrameError!bool {
    if (a.len == 0 or b.len == 0) return false;
    const start_a = @intFromPtr(a.ptr);
    const start_b = @intFromPtr(b.ptr);
    const end_a = std.math.add(usize, start_a, a.len) catch return error.SizeOverflow;
    const end_b = std.math.add(usize, start_b, b.len) catch return error.SizeOverflow;
    return start_a < end_b and start_b < end_a;
}

const Counter = struct {
    input: u64 = 0,
    output: u64 = 0,
    work_units: u64 = 0,
    frames: u64 = 0,
    limits: CounterLimits,

    fn init(limits: anytype) Counter {
        return .{
            .limits = .{
                .input_bytes = limits.input_bytes,
                .output_bytes = limits.output_bytes,
                .work_units = limits.work_units,
                .frames = limits.frames,
            },
        };
    }

    fn add(self: *Counter, input: usize, output: usize) FrameError!void {
        const total_input = std.math.add(u64, self.input, input) catch return error.CounterOverflow;
        const total_output = std.math.add(
            u64,
            self.output,
            output,
        ) catch return error.CounterOverflow;
        const amount = std.math.add(u64, input, output) catch return error.CounterOverflow;
        const total_work = std.math.add(
            u64,
            self.work_units,
            amount,
        ) catch return error.CounterOverflow;
        if (total_input > self.limits.input_bytes) return error.LimitExceeded;
        if (total_output > self.limits.output_bytes or total_work > self.limits.work_units)
            return error.LimitExceeded;

        self.input = total_input;
        self.output = total_output;
        self.work_units = total_work;
    }

    fn frame(self: *Counter) FrameError!void {
        const frames = std.math.add(u64, self.frames, 1) catch return error.CounterOverflow;
        if (frames > self.limits.frames) return error.LimitExceeded;
        self.frames = frames;
    }

    fn outputCapacity(self: *const Counter, capacity: usize) usize {
        const remaining_output_bytes = self.limits.output_bytes - self.output;
        const remaining_work_units = self.limits.work_units - self.work_units;
        const admitted_bytes = @min(capacity, remaining_output_bytes, remaining_work_units);
        return @intCast(admitted_bytes);
    }
};

fn descriptorSize(prefix: []const u8) FrameError!usize {
    const flags = prefix[0];
    const block_descriptor = prefix[1];
    const version = flags >> 6;
    const reserved_flags = flags & 2;
    const reserved_block_bits = block_descriptor & 0x8f;
    const block_size_id = block_descriptor >> 4;
    if (version != 1 or reserved_flags != 0) return error.InvalidFrame;
    if (reserved_block_bits != 0 or block_size_id < 4) return error.InvalidFrame;
    const content_bytes: usize = if (flags & 8 != 0) 8 else 0;
    const dictionary_bytes: usize = if (flags & 1 != 0) 4 else 0;
    return 3 + content_bytes + dictionary_bytes;
}

fn descriptor(bytes: []const u8) FrameError!FrameInfo {
    const size = try descriptorSize(bytes[0..2]);
    std.debug.assert(bytes.len == size);
    const checksum: u8 = @truncate(xxhash32.hash(bytes[0 .. size - 1]) >> 8);
    if (checksum != bytes[size - 1]) return error.ChecksumMismatch;
    const flags = bytes[0];
    var cursor: usize = 2;
    const content_size: ?u64 = blk: {
        if (flags & 8 == 0) break :blk null;
        const value = std.mem.readInt(u64, bytes[cursor..][0..8], .little);
        cursor += 8;
        break :blk value;
    };
    const dictionary_id: ?u32 = blk: {
        if (flags & 1 == 0) break :blk null;
        break :blk std.mem.readInt(u32, bytes[cursor..][0..4], .little);
    };
    return .{
        .block_size = @fromBackingInt(@as(u3, @intCast(bytes[1] >> 4))),
        .independent = flags & 32 != 0,
        .block_checksum = flags & 16 != 0,
        .content_checksum = flags & 4 != 0,
        .content_size = content_size,
        .dictionary_id = dictionary_id,
    };
}

fn dictionaryFor(info: FrameInfo, supplied: ?FrameDictionary) FrameError![]const u8 {
    if (info.dictionary_id) |id| {
        const dict = supplied orelse return error.NeedDictionary;
        if (dict.id == null or dict.id.? != id) return error.WrongDictionary;
    }
    return if (supplied) |dict| dictSuffix(dict.bytes) else &.{};
}

fn take(source: []const u8, cursor: *usize, count: usize, counter: *Counter) FrameError![]const u8 {
    if (count > source.len - cursor.*) return error.Truncated;
    try counter.add(count, 0);
    const result = source[cursor.*..][0..count];
    cursor.* += count;
    return result;
}

fn checkEncoderStorage(
    owner: *FrameEncoder,
    workspace: *FrameEncoderWorkspace,
    hc: ?*high_compression.HcEncoderWorkspace,
    bytes: []const u8,
) FrameError!void {
    const state = std.mem.asBytes(owner);
    const storage = std.mem.asBytes(workspace);
    if (hc) |scratch| {
        const memory = std.mem.asBytes(scratch);
        if (try overlaps(memory, state) or try overlaps(memory, storage)) return error.Aliasing;
        if (try overlaps(
            memory,
            workspace.input,
        ) or try overlaps(memory, workspace.encoded)) return error.Aliasing;
        if (try overlaps(memory, bytes)) return error.Aliasing;
    }
    if (try overlaps(state, storage)) return error.Aliasing;
    if (try overlaps(
        state,
        workspace.input,
    ) or try overlaps(state, workspace.encoded)) return error.Aliasing;
    if (try overlaps(
        storage,
        workspace.input,
    ) or try overlaps(storage, workspace.encoded)) return error.Aliasing;
    if (try overlaps(workspace.input, workspace.encoded)) return error.Aliasing;
    if (try overlaps(bytes, state) or try overlaps(bytes, storage)) return error.Aliasing;
    if (try overlaps(
        bytes,
        workspace.input,
    ) or try overlaps(bytes, workspace.encoded)) return error.Aliasing;
}

fn writeHeader(output: *[19]u8, options: FrameEncodeOptions) usize {
    std.mem.writeInt(u32, output[0..4], magic, .little);
    const id: ?u32 = if (options.dictionary) |dict| dict.id else null;
    var flags: u8 = 0x40;
    flags |= if (options.independent) @as(u8, 32) else 0;
    flags |= if (options.block_checksum) @as(u8, 16) else 0;
    flags |= if (options.content_size != null) @as(u8, 8) else 0;
    flags |= if (options.content_checksum) @as(u8, 4) else 0;
    flags |= if (id != null) @as(u8, 1) else 0;
    output[4] = flags;
    output[5] = @as(u8, @backingInt(options.block_size)) << 4;
    var size: usize = 6;
    if (options.content_size) |value| {
        std.mem.writeInt(u64, output[size..][0..8], value, .little);
        size += 8;
    }
    if (id) |value| {
        std.mem.writeInt(u32, output[size..][0..4], value, .little);
        size += 4;
    }
    output[size] = @truncate(xxhash32.hash(output[4..size]) >> 8);
    return size + 1;
}

fn allocationCheck(allocator: std.mem.Allocator) !void {
    const workspace = try FrameEncoderWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    const decoder = try FrameDecoderWorkspace.create(allocator);
    defer decoder.destroy(allocator);
}

test "LZ4 skippable encoding matches fixed wire fields and preserves capacity" {
    const expected = [_]u8{ 0x5f, 0x2a, 0x4d, 0x18, 0x03, 0x00, 0x00, 0x00, 0x61, 0x62, 0x63 };
    var output: [32]u8 = @splat(0xa7);
    const bytes = try encodeSkippableFrame("abc", &output, 15);
    try std.testing.expectEqualSlices(u8, &expected, bytes);
    try std.testing.expectEqualSlices(u8, expected[0..8], &skippableFrameHeader(3, 15));
    try std.testing.expect(std.mem.allEqual(u8, output[bytes.len..], 0xa7));
    const result = try decodeFrame(bytes, &.{}, .{});
    try std.testing.expectEqual(1, result.skippable_frames);
    try std.testing.expectError(
        error.OutputTooSmall,
        encodeSkippableFrame("abc", output[0..10], 0),
    );
    try std.testing.expectError(error.Aliasing, encodeSkippableFrame(output[0..3], &output, 0));
}

test "LZ4 frames frozen empty bytes and optional zero fields" {
    // Produced by LZ4F_compressFrame in LZ4 1.10.0, with independent blocks and no optional fields.
    // Reference implementation: BSD-2-Clause. https://github.com/lz4/lz4/blob/v1.10.0/lib/LICENSE
    const empty = [_]u8{ 0x04, 0x22, 0x4d, 0x18, 0x60, 0x40, 0x82, 0x00, 0x00, 0x00, 0x00 };
    const result = try decodeFrame(&empty, &.{}, .{});
    try std.testing.expectEqual(empty.len, result.consumed);
    try std.testing.expectEqual(0, result.produced);
    const allocator = std.testing.allocator;
    const workspace = try FrameEncoderWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    var output: [64]u8 = @splat(0xa7);
    const encoded = try encodeFrame(
        &.{},
        &output,
        .{ .workspace = workspace },
        .{ .content_checksum = false },
    );
    try std.testing.expectEqualSlices(u8, &empty, encoded);
    const with_zero = try encodeFrame(
        &.{},
        &output,
        .{ .workspace = workspace },
        .{ .content_size = 0, .dictionary = .{ .bytes = &.{}, .id = 0 } },
    );
    try std.testing.expectError(error.NeedDictionary, decodeFrame(with_zero, &.{}, .{}));
    _ = try decodeFrame(with_zero, &.{}, .{ .dictionary = .{ .bytes = &.{}, .id = 0 } });
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
        const workspace = try FrameEncoderWorkspace.create(allocator, block_size);
        defer workspace.destroy(allocator);
        inline for (.{ false, true }) |independent| {
            const options: FrameEncodeOptions = .{
                .block_size = block_size,
                .independent = independent,
                .block_checksum = true,
                .content_size = source.len,
                .dictionary = .{ .bytes = source[0..50000], .id = 77 },
            };
            const storage = try allocator.alloc(u8, try frameEncodeBound(source.len, options));
            defer allocator.free(storage);
            const wire = try encodeFrame(source, storage, .{ .workspace = workspace }, options);
            @memset(output, 0xa7);
            const result = try decodeFrame(wire, output, .{ .dictionary = options.dictionary });
            try std.testing.expectEqual(wire.len, result.consumed);
            try std.testing.expectEqual(source.len, result.produced);
            try std.testing.expectEqualSlices(u8, source, output[0..source.len]);
            try std.testing.expect(std.mem.allEqual(u8, output[source.len..], 0xa7));
            try std.testing.expectError(
                error.OutputTooSmall,
                decodeFrame(
                    wire,
                    output[0 .. source.len - 1],
                    .{ .dictionary = options.dictionary },
                ),
            );
        }
    }
}

test "LZ4 frame streaming every short split and retired one byte buffers" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try FrameEncoderWorkspace.create(allocator, .k64);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try FrameDecoderWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    var wire: [1024]u8 = undefined;
    const source = "one dictionary phrase; one dictionary phrase; TAIL!";
    const dictionary = "one dictionary phrase; ";
    const encoded = try encodeFrame(
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
        var decoder: FrameDecoder = undefined;
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
                try std.testing.expectEqual(@as(?u32, 91), decoder.frame_info.?.dictionary_id);
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
    var decoder: FrameDecoder = undefined;
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
    try std.testing.expectEqual(encoded.len + source.len, decoder.counter.work_units);
}

test "LZ4 frame encoder flush finish and copied dictionaries" {
    const allocator = std.testing.allocator;
    const workspace = try FrameEncoderWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    var encoder: FrameEncoder = undefined;
    var dict: [12]u8 = "hello world!".*;
    try encoder.reset(
        .{ .workspace = workspace },
        .{
            .independent = false,
            .block_checksum = true,
            .dictionary = .{ .bytes = &dict, .id = 7 },
        },
    );
    @memset(&dict, 0xa7);
    var wire: [1024]u8 = undefined;
    var written: usize = 0;
    for ([_][]const u8{ "hello world!", "hello world!", "hello world!" }, 0..) |source, i| {
        var read: usize = 0;
        const action: FrameEncodeAction = if (i == 2) .finish else .flush;
        while (true) {
            var byte: [1]u8 = undefined;
            const result = try encoder.step(source[read..], &byte, action);
            @memcpy(wire[written..][0..result.produced], byte[0..result.produced]);
            read += result.consumed;
            written += result.produced;
            if (result.status == .complete or result.status == .flushed) break;
        }
        try std.testing.expectEqual(source.len, read);
    }
    var output: [36]u8 = undefined;
    _ = try decodeFrame(
        wire[0..written],
        &output,
        .{ .dictionary = .{ .bytes = "hello world!", .id = 7 } },
    );
    try std.testing.expectEqualStrings("hello world!hello world!hello world!", &output);
    try std.testing.expectEqual(
        FrameEncodeStatus.complete,
        (try encoder.step(&.{}, &.{}, .finish)).status,
    );
}

test "LZ4 frame concatenation skippable values iteration and lookahead" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try FrameEncoderWorkspace.create(allocator, .k64);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try FrameDecoderWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    var wire: [256]u8 = undefined;
    const first = try encodeFrame("first", &wire, .{ .workspace = encoder_workspace }, .{});
    const first_size = first.len;
    var cursor = first_size;
    for (0..16) |i| {
        std.mem.writeInt(u32, wire[cursor..][0..4], skip_magic + @as(u32, @intCast(i)), .little);
        std.mem.writeInt(u32, wire[cursor + 4 ..][0..4], 1, .little);
        wire[cursor + 8] = @intCast(i);
        cursor += 9;
    }
    const second = try encodeFrame(
        "second",
        wire[cursor..],
        .{ .workspace = encoder_workspace },
        .{},
    );
    const end = cursor + second.len;
    var output: [11]u8 = undefined;
    try std.testing.expectEqual(first_size, (try decodeFrame(wire[0..end], &output, .{})).consumed);
    const joined = try decodeFrame(wire[0..end], &output, .{ .frames = .concatenate });
    try std.testing.expectEqual(18, joined.frames);
    try std.testing.expectEqual(16, joined.skippable_frames);
    try std.testing.expectEqualStrings("firstsecond", &output);
    for ([_]FramePolicy{ .iterate, .concatenate }) |policy| {
        var decoder: FrameDecoder = undefined;
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
            try std.testing.expectEqual(FrameDecodeStatus.frame_end, part.status);
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
    const encoder_workspace = try FrameEncoderWorkspace.create(allocator, .k64);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try FrameDecoderWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    var wire: [256]u8 = undefined;
    const source = "abcdefabcdefabcdefabcdefabcdefabcdefTAIL!";
    const frame = try encodeFrame(
        source,
        &wire,
        .{ .workspace = encoder_workspace },
        .{ .block_checksum = true },
    );
    var output: [source.len]u8 = undefined;
    for (0..frame.len) |cut| {
        if (decodeFrame(frame[0..cut], &output, .{})) |_| {
            return error.TruncationAccepted;
        } else |_| {}
        var decoder: FrameDecoder = undefined;
        try decoder.reset(decoder_workspace, .{});
        if (decoder.step(.{ .bytes = frame[0..cut], .final = true }, &output)) |_| {
            return error.TruncationAccepted;
        } else |_| {}
        try std.testing.expectError(error.NeedReset, decoder.step(.{ .bytes = &.{} }, &output));
    }
    for (0..frame.len) |i| {
        wire[i] ^= 1;
        if (decodeFrame(frame, &output, .{})) |_| {
            return error.MutationAccepted;
        } else |_| {}
        wire[i] ^= 1;
    }
    const limits: FrameDecodeLimits = .{
        .input_bytes = frame.len,
        .output_bytes = source.len,
        .work_units = frame.len + source.len,
        .frames = 1,
    };
    _ = try decodeFrame(frame, &output, .{ .limits = limits });
    var decoder: FrameDecoder = undefined;
    try decoder.reset(decoder_workspace, .{ .limits = limits });
    try std.testing.expectEqual(
        FrameDecodeStatus.complete,
        (try decoder.step(.{ .bytes = frame, .final = true }, &output)).status,
    );
    var short = limits;
    short.work_units -= 1;
    try std.testing.expectError(
        error.LimitExceeded,
        decodeFrame(frame, &output, .{ .limits = short }),
    );
    try decoder.reset(decoder_workspace, .{ .limits = short });
    try std.testing.expectError(
        error.LimitExceeded,
        decoder.step(.{ .bytes = frame, .final = true }, &output),
    );
    try std.testing.expectError(error.SizeOverflow, frameEncodeBound(std.math.maxInt(usize), .{}));
    try std.testing.expectError(
        error.ContentSizeMismatch,
        encodeFrame(
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
    const encoder_workspace = try FrameEncoderWorkspace.create(allocator, .k64);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try FrameDecoderWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    var encoder: FrameEncoder = undefined;
    try encoder.reset(.{ .workspace = encoder_workspace }, .{});
    var output: [64]u8 = undefined;
    try std.testing.expectError(
        error.Aliasing,
        encoder.step(std.mem.asBytes(&encoder)[0..1], &output, .finish),
    );
    try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
    var decoder: FrameDecoder = undefined;
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

test "LZ4 frame workspace construction cleans partial allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCheck, .{});
}

test "LZ4 HC frames reuse dictionaries linked blocks and fragmented finish" {
    const allocator = std.testing.allocator;
    const workspace = try FrameEncoderWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    const hc = try high_compression.HcEncoderWorkspace.create(allocator);
    defer hc.destroy(allocator);
    const source = try allocator.alloc(u8, 150000);
    defer allocator.free(source);
    for (source, 0..) |*byte, i| byte.* = @intCast((i * 31 + i / 29) % 251);
    const bound_options: FrameEncodeOptions = .{
        .block_checksum = true,
        .content_size = source.len,
        .dictionary = .{ .bytes = &.{}, .id = 717 },
    };
    const capacity = try frameEncodeBound(source.len, bound_options);
    const output = try allocator.alloc(u8, capacity);
    defer allocator.free(output);
    const streamed = try allocator.alloc(u8, output.len);
    defer allocator.free(streamed);
    const recovered = try allocator.alloc(u8, source.len);
    defer allocator.free(recovered);
    for ([_]bool{ true, false }) |independent| {
        const options: FrameEncodeOptions = .{
            .independent = independent,
            .block_checksum = true,
            .content_size = source.len,
            .dictionary = .{ .bytes = source[1000..7000], .id = 717 },
            .compression = .{ .hc = .{} },
        };
        const wire = try encodeFrame(
            source,
            output,
            .{ .workspace = workspace, .hc_workspace = hc },
            options,
        );
        const result = try decodeFrame(wire, recovered, .{ .dictionary = options.dictionary });
        try std.testing.expectEqual(source.len, result.produced);
        try std.testing.expectEqualSlices(u8, source, recovered);
        var state: FrameEncoder = undefined;
        try state.reset(.{ .workspace = workspace, .hc_workspace = hc }, options);
        var read: usize = 0;
        var written: usize = 0;
        while (true) {
            const end = @min(read + 127, source.len);
            const progress = try state.step(
                source[read..end],
                streamed[written..][0..@min(113, streamed.len - written)],
                if (end == source.len) .finish else .process,
            );
            read += progress.consumed;
            written += progress.produced;
            if (progress.status == .complete) break;
        }
        try std.testing.expectEqualSlices(u8, wire, streamed[0..written]);
        const work_units = state.hc_work;
        var limited = options;
        limited.compression.hc.limits.work_units = work_units;
        _ = try encodeFrame(
            source,
            streamed,
            .{ .workspace = workspace, .hc_workspace = hc },
            limited,
        );
        limited.compression.hc.limits.work_units -= 1;
        try std.testing.expectError(
            error.LimitExceeded,
            encodeFrame(source, streamed, .{ .workspace = workspace, .hc_workspace = hc }, limited),
        );
    }
}

test "LZ4 frame complete extent trailing and descriptor admission are independent" {
    const allocator = std.testing.allocator;
    const workspace = try FrameEncoderWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    var wire: [128]u8 = undefined;
    const frame = try encodeFrame("hello", &wire, .{ .workspace = workspace }, .{});
    var joined: [256]u8 = undefined;
    const skip = try encodeSkippableFrame("meta", &joined, 15);
    @memcpy(joined[skip.len..][0..frame.len], frame);
    const sequence = joined[0 .. skip.len + frame.len];
    var output: [8]u8 = @splat(0xa7);
    const single = try decodeFrame(sequence, &output, .{});
    try std.testing.expectEqual(skip.len, single.consumed);
    try std.testing.expectEqual(@as(u64, 1), single.skippable_frames);
    try std.testing.expectEqual(0, single.produced);
    try std.testing.expectError(
        error.InvalidFrame,
        decodeFrame(sequence, &output, .{ .trailing_data = .reject }),
    );
    const both = try decodeFrame(
        sequence,
        &output,
        .{ .frames = .concatenate, .trailing_data = .reject },
    );
    try std.testing.expectEqual(@as(u64, 2), both.frames);
    try std.testing.expectEqualStrings("hello", output[0..both.produced]);
    try std.testing.expect(std.mem.allEqual(u8, output[5..], 0xa7));
    try std.testing.expectError(
        error.OutputSizeMismatch,
        decodeFrame(frame, &output, .{ .output_size = .exact }),
    );
    _ = try decodeFrame(frame, output[0..5], .{ .output_size = .exact, .trailing_data = .reject });
    try std.testing.expectError(
        error.LimitExceeded,
        decodeFrame(
            frame,
            &output,
            .{ .limits = .{ .block_bytes = FrameBlockSize.k64.bytes() - 1 } },
        ),
    );
}

test "LZ4 frame HC storage refusals preserve the active encoder and allow retry" {
    const allocator = std.testing.allocator;
    const workspace = try FrameEncoderWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    const hc = try high_compression.HcEncoderWorkspace.create(allocator);
    defer hc.destroy(allocator);
    const source = "an active frame survives refused replacement storage";
    var expected_bytes: [256]u8 = undefined;
    const expected = try encodeFrame(source, &expected_bytes, .{ .workspace = workspace }, .{});
    var encoder: FrameEncoder = undefined;
    try encoder.reset(.{ .workspace = workspace }, .{});
    try std.testing.expectError(
        error.InvalidOptions,
        encoder.reset(.{ .workspace = workspace }, .{ .compression = .{ .hc = .{} } }),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        encoder.reset(
            .{ .workspace = workspace, .hc_workspace = hc },
            .{ .compression = .{ .hc = .{ .dictionary = "wrong owner" } } },
        ),
    );
    var actual: [256]u8 = undefined;
    const progress = try encoder.step(source, &actual, .finish);
    try std.testing.expectEqual(FrameEncodeStatus.complete, progress.status);
    try std.testing.expectEqualSlices(u8, expected, actual[0..progress.produced]);
    // The HC allocation is large and aligned enough to hold an encoder at the same address.
    const aliased: *FrameEncoder = @ptrCast(hc);
    try aliased.reset(.{ .workspace = workspace }, .{});
    try std.testing.expectError(
        error.Aliasing,
        aliased.reset(
            .{ .workspace = workspace, .hc_workspace = hc },
            .{ .compression = .{ .hc = .{} } },
        ),
    );
    const retained = try aliased.step(source, &actual, .finish);
    try std.testing.expectEqualSlices(u8, expected, actual[0..retained.produced]);
    // Fast policy does not borrow unused HC capacity, even when it aliases the owner.
    try aliased.reset(.{ .workspace = workspace, .hc_workspace = hc }, .{});
    _ = try aliased.step(source, &actual, .finish);
    try encoder.reset(
        .{ .workspace = workspace, .hc_workspace = hc },
        .{ .compression = .{ .hc = .{} } },
    );
    const retried = try encoder.step(source, &actual, .finish);
    var restored: [source.len]u8 = undefined;
    _ = try decodeFrame(actual[0..retried.produced], &restored, .{ .output_size = .exact });
    try std.testing.expectEqualStrings(source, &restored);
}
