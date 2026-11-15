//! Bounded greedy or HC frame encoder. Workspaces are borrowed between calls. Pending input and
//! dictionaries are copied; processed caller fragments may retire immediately. Reset at the final
//! address before use.

const std = @import("std");
const Xxh32 = @import("../xxhash.zig").Xxh32;
const encode = @import("frame_encode.zig");
const test_decode = @import("frame_decode.zig"); // Inline frame-recovery comparisons only.
const FrameEncodeWorkspace = @import("FrameEncodeWorkspace.zig");
const greedy = @import("greedy_encode.zig");
const blocks = @import("block.zig");
const framing = @import("frame.zig");
const hc_encoder = blocks.encode.hc;
const FrameCounter = @import("FrameCounter.zig");
const format = @import("frame_format.zig");
const storage_checks = @import("frame_storage.zig");
const byte_ranges = @import("../common/byte_ranges.zig");
const overlaps = byte_ranges.overlapsChecked;
const FrameStreamEncoder = @This();

/// Streaming compression, storage, admission and lifecycle failures.
pub const Error = StepError || error{ InvalidOptions, OutputTooSmall };

/// Failures while accepting source, emitting blocks or completing a frame.
pub const StepError = error{
    Aliasing,
    SizeOverflow,
    LimitExceeded,
    NeedReset,
    InvalidState,
    CounterOverflow,
    ContentSizeMismatch,
};

/// Distinct streaming requests. Flush emits pending bytes without ending the frame. Finish enforces
/// the declared content size and emits its footer.
pub const Action = enum {
    /// Accept source bytes and emit complete blocks while keeping the frame open.
    process,
    /// Emit a pending partial block and return `Status.flushed` without ending the frame.
    flush,
    /// Accept the final source bytes, enforce any declared size and emit the frame footer.
    finish,
};

/// The resource needed by the next step, or completion of a flush or frame.
pub const Status = enum {
    /// Supply more source bytes, or request flush/finish for the accepted bytes.
    need_input,
    /// Supply output capacity and resubmit any unconsumed source with its action.
    need_output,
    /// The flush request finished; the frame remains open.
    flushed,
    /// The complete frame and its footer were emitted.
    complete,
};

/// Copied progress for one encode step; accepted fragments may retire on return.
pub const Progress = struct {
    /// Input prefix accepted by this call, in bytes.
    consumed: usize,
    /// Output prefix produced by this call, in bytes.
    produced: usize,
    /// Next caller action or completion condition.
    status: Status,
};

/// Borrowed input/output block buffers, history and greedy table reservation.
workspace: *FrameEncodeWorkspace,
/// Copied encoding policy; the caller dictionary borrow ends when reset returns.
options: encode.Options,
/// Selected HC scratch, or null for greedy encoding; unused HC storage is not borrowed.
hc_workspace: ?*hc_encoder.Workspace,
/// Admitted source, wire, byte-work and frame totals with their ceilings.
counter: FrameCounter,
/// Initialized source-byte prefix in workspace.input awaiting compression.
input_used: usize,
/// Copied initial dictionary suffix length, in bytes.
dictionary_size: usize,
/// Initialized linked-history prefix in workspace.history, in bytes.
history_size: usize,
/// Greedy table continuation, including its cell representation and absolute origin.
linked_hash: greedy.Continuation,
/// Wire bytes still to drain; borrows this worker or its workspace until consumed.
pending: []const u8,
/// Private frame-header/footer staging; pending may borrow this stable address.
small: [19]u8,
/// Queued block length and stored flag, in little-endian wire order.
prefix: [4]u8,
/// Queued encoded-block checksum, in little-endian wire order.
suffix: [4]u8,
/// Queued compressed bytes or stored input; borrows workspace until drained.
body: []const u8,
/// Framing operation entered once pending is empty.
after_pending: Phase,
/// Framing or input operation resumed by the next step.
phase: Phase,
/// Checksum of admitted original input for the frame footer.
content_hash: Xxh32,
/// Finish latched after all input supplied with that request has been accepted.
finish_requested: bool,
/// HC effort of successfully compressed blocks, including blocks later stored verbatim.
hc_work: u64,

const Phase = enum { pending, prefix, body, suffix, input, footer, done, failed };

/// Copied cumulative observations. Byte totals include admitted work before a later failure. HC
/// effort includes completed blocks; a failing block's partial effort remains in
/// hc_workspace.stats.
pub const Counts = struct {
    /// Source bytes admitted by framing.
    input_bytes: u64,
    /// Wire bytes admitted for output, including framing fields.
    output_bytes: u64,
    /// Input plus output byte work; dictionary copying and HC effort are separate.
    work_units: u64,
    /// Frame headers admitted by this worker.
    frames: u64,
    /// Cumulative successful HC block effort, including dictionary priming and stored fallbacks.
    hc_work_units: u64,
};

/// Returns copied totals without transferring any reservation or changing the worker.
pub fn counts(self: *const FrameStreamEncoder) Counts {
    return .{
        .input_bytes = self.counter.input,
        .output_bytes = self.counter.output,
        .work_units = self.counter.work_units,
        .frames = self.counter.frames,
        .hc_work_units = self.hc_work,
    };
}

/// Begins a frame and copies the dictionary suffix. Existing buffer reservations may be reused for
/// any block size that fits their capacity. A refused setup leaves the active encoder and its
/// reservations unchanged.
pub fn reset(
    self: *FrameStreamEncoder,
    storage: encode.Storage,
    options: encode.Options,
) error{ InvalidOptions, OutputTooSmall, Aliasing, SizeOverflow, LimitExceeded }!void {
    const workspace = storage.workspace;
    const hc_workspace = switch (options.compression) {
        .fast => null,
        .hc => storage.hc_workspace orelse return error.InvalidOptions,
    };
    const block_capacity = options.block_size.bytes();
    if (workspace.input.len < block_capacity) return error.OutputTooSmall;
    // Every supported frame block fits the raw encoder's input limit.
    const encoded_capacity = blocks.encode.bound(block_capacity) catch |err| switch (err) {
        error.InputTooLarge => unreachable,
        error.SizeOverflow => return error.SizeOverflow,
    };
    if (workspace.encoded.len < encoded_capacity) return error.OutputTooSmall;
    try storage_checks.checkEncoder(std.mem.asBytes(self), workspace, hc_workspace, &.{});
    if (options.dictionary) |dict| {
        try storage_checks.checkEncoder(
            std.mem.asBytes(self),
            workspace,
            hc_workspace,
            format.dictionarySuffix(dict.bytes),
        );
    }

    // Admit this frame before replacing a usable owner or copying its dictionary. A fresh counter
    // starts at zero, so only the configured frame allowance can refuse its first header.
    var counter: FrameCounter = .init(options.limits);
    counter.frame() catch |err| switch (err) {
        error.CounterOverflow => unreachable,
        error.LimitExceeded => return error.LimitExceeded,
    };

    self.* = .{
        .workspace = workspace,
        .options = options,
        .hc_workspace = hc_workspace,
        .counter = counter,
        .input_used = 0,
        .dictionary_size = 0,
        .history_size = 0,
        .linked_hash = .{},
        .pending = &.{},
        .small = undefined,
        .prefix = undefined,
        .suffix = undefined,
        .body = &.{},
        .after_pending = .input,
        .phase = .pending,
        .content_hash = Xxh32.init(0),
        .finish_requested = false,
        .hc_work = 0,
    };
    // End the options' caller dictionary borrow before reset returns.
    self.options.dictionary = null;
    if (options.dictionary) |dict| {
        const bytes = format.dictionarySuffix(dict.bytes);
        @memcpy(workspace.dictionary[0..bytes.len], bytes);
        @memcpy(workspace.history[0..bytes.len], bytes);
        self.dictionary_size = bytes.len;
        self.history_size = bytes.len;
    }
    const descriptor: framing.Descriptor = .{
        .block_size = options.block_size,
        .independent = options.independent,
        .block_checksum = options.block_checksum,
        .content_checksum = options.content_checksum,
        .content_size = options.content_size,
        .dictionary_id = if (options.dictionary) |dict| dict.id else null,
    };
    const size = format.writeHeader(&self.small, descriptor);
    self.pending = self.small[0..size];
}

/// Advances framing and compression without allocation. Finish is latched only after all supplied
/// input is accepted; subsequent calls drain with empty input. An explicit flush returns flushed
/// exactly when drained. Every step error requires reset before reuse.
pub fn step(
    self: *FrameStreamEncoder,
    input: []const u8,
    output: []u8,
    action: Action,
) StepError!Progress {
    if (self.phase == .failed) return error.NeedReset;
    errdefer self.phase = .failed;
    if (try overlaps(input, output)) return error.Aliasing;
    try storage_checks.checkEncoder(
        std.mem.asBytes(self),
        self.workspace,
        self.hc_workspace,
        input,
    );
    try storage_checks.checkEncoder(
        std.mem.asBytes(self),
        self.workspace,
        self.hc_workspace,
        output,
    );
    if (self.finish_requested and input.len != 0) return error.InvalidState;

    // Pending header/block/footer bytes drain before more input is accepted. Once staged input
    // reaches a block boundary, block() prepares its prefix, body and optional checksum for these
    // same drain phases.
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
            // A block may be emitted only after this call's input is accepted. Process keeps a
            // short block pending; flush and finish publish it at the caller's request.
            const action_requests_flush = action != .process or self.finish_requested;
            const flush_pending = input_accepted and self.input_used != 0 and action_requests_flush;
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

// Compress the staged input using the selected history mode, then queue the block fields for the
// step loop to drain. Updating linked history only after compression keeps the current block from
// referring to itself through the external dictionary.
fn block(self: *FrameStreamEncoder) error{ Aliasing, SizeOverflow, LimitExceeded }!void {
    const source = self.workspace.input[0..self.input_used];
    const history = blk: {
        if (self.options.independent) {
            break :blk self.workspace.dictionary[0..self.dictionary_size];
        }
        break :blk self.workspace.history[0..self.history_size];
    };
    const encoded_result: hc_encoder.Error![]u8 = blk: {
        if (self.hc_workspace) |hc| {
            var policy = self.options.compression.hc;
            policy.limits.work_units -= self.hc_work;
            const bytes = hc_encoder.into(
                source,
                self.workspace.encoded,
                hc,
                .{ .dictionary = history, .policy = policy },
            ) catch |err| break :blk err;
            self.hc_work += hc.stats.work_units;
            break :blk bytes;
        }
        if (!self.options.independent) {
            break :blk greedy.encodeRolling(
                source,
                self.workspace.encoded,
                &self.workspace.codec,
                history,
                false,
                &self.linked_hash,
            );
        }
        break :blk blocks.encode.into(
            source,
            self.workspace.encoded,
            &self.workspace.codec,
            .{ .dictionary = history },
        );
    };
    const encoded = encoded_result catch |err| switch (err) {
        // reset reserves the raw encoding bound for block_size, and input_used never exceeds that
        // size (at most 4 MiB). The monotone bound and raw input cap admit every staged block;
        // caller output capacity only affects the drain phases in step.
        error.InputTooLarge, error.OutputTooSmall => unreachable,
        else => |failure| return failure,
    };

    // The frame format allows a stored block; use it whenever compression fails to save bytes.
    const compressed = encoded.len < source.len;
    self.body = if (compressed) encoded else source;
    const size: u32 = @intCast(self.body.len);
    const stored_flag: u32 = if (compressed) 0 else 0x80000000;
    std.mem.writeInt(u32, &self.prefix, size | stored_flag, .little);
    if (self.options.block_checksum) {
        std.mem.writeInt(u32, &self.suffix, Xxh32.hash(self.body), .little);
    }

    if (!self.options.independent) {
        // Keep the newest 65,535 history bytes. Older history fills any space left before the
        // current block's suffix.
        const kept = format.dictionarySuffix(source);
        const retained_old = @min(self.history_size, blocks.maximum_distance - kept.len);
        std.mem.copyForwards(
            u8,
            self.workspace.history[0..retained_old],
            self.workspace.history[self.history_size - retained_old .. self.history_size],
        );
        @memcpy(self.workspace.history[retained_old..][0..kept.len], kept);
        self.history_size = retained_old + kept.len;
    }

    self.input_used = 0;
    self.phase = .prefix;
}

test "LZ4 frame encoder flush finish and copied dictionaries" {
    const allocator = std.testing.allocator;
    const workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    var encoder: FrameStreamEncoder = undefined;
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
        const action: FrameStreamEncoder.Action = if (i == 2) .finish else .flush;
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
    _ = try test_decode.into(
        wire[0..written],
        &output,
        .{ .dictionary = .{ .bytes = "hello world!", .id = 7 } },
    );
    try std.testing.expectEqualStrings("hello world!hello world!hello world!", &output);
    try std.testing.expectEqual(
        FrameStreamEncoder.Status.complete,
        (try encoder.step(&.{}, &.{}, .finish)).status,
    );
}

test "LZ4 HC frames reuse dictionaries linked blocks and fragmented finish" {
    const allocator = std.testing.allocator;
    const workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    const hc = try hc_encoder.Workspace.create(allocator);
    defer hc.destroy(allocator);
    const source = try allocator.alloc(u8, 150000);
    defer allocator.free(source);
    for (source, 0..) |*byte, i| byte.* = @intCast((i * 31 + i / 29) % 251);
    const bound_options: encode.Options = .{
        .block_checksum = true,
        .content_size = source.len,
        .dictionary = .{ .bytes = &.{}, .id = 717 },
    };
    const capacity = try encode.bound(source.len, bound_options);
    const output = try allocator.alloc(u8, capacity);
    defer allocator.free(output);
    const streamed = try allocator.alloc(u8, output.len);
    defer allocator.free(streamed);
    const recovered = try allocator.alloc(u8, source.len);
    defer allocator.free(recovered);
    for ([_]bool{ true, false }) |independent| {
        const options: encode.Options = .{
            .independent = independent,
            .block_checksum = true,
            .content_size = source.len,
            .dictionary = .{ .bytes = source[1000..7000], .id = 717 },
            .compression = .{ .hc = .{} },
        };
        const wire = try encode.into(
            source,
            output,
            .{ .workspace = workspace, .hc_workspace = hc },
            options,
        );
        const result = try test_decode.into(wire, recovered, .{ .dictionary = options.dictionary });
        try std.testing.expectEqual(source.len, result.produced);
        try std.testing.expectEqualSlices(u8, source, recovered);
        var state: FrameStreamEncoder = undefined;
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
        const work_units = state.counts().hc_work_units;
        var limited = options;
        limited.compression.hc.limits.work_units = work_units;
        _ = try encode.into(
            source,
            streamed,
            .{ .workspace = workspace, .hc_workspace = hc },
            limited,
        );
        limited.compression.hc.limits.work_units -= 1;
        try std.testing.expectError(
            error.LimitExceeded,
            encode.into(source, streamed, .{ .workspace = workspace, .hc_workspace = hc }, limited),
        );
    }
}

test "LZ4 HC independent frame costs include a stored fallback block" {
    const allocator = std.testing.allocator;
    const workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    const hc = try hc_encoder.Workspace.create(allocator);
    defer hc.destroy(allocator);
    const block_bytes = 65536;
    const tail = "ABCDxABCDy1234567";
    const source = try allocator.alloc(u8, block_bytes + tail.len);
    defer allocator.free(source);
    @memset(source[0..block_bytes], 'A');
    @memcpy(source[block_bytes..], tail);

    // The first block takes the long-match shortcut after one literal edge, insertion and probe.
    // Extending its 65,530-byte match compares 8,190 words and six tail bytes. The second block
    // spends 26 units even though its 17-byte HC result is stored verbatim, without a size win.
    const first_work = 1 + 1 + 1 + 8190 + 6;
    const second_work = 11 + 12 + 1 + 1 + 1;
    const expected_work = first_work + second_work;
    const options: encode.Options = .{
        .independent = true,
        .block_checksum = true,
        .content_size = source.len,
        .compression = .{ .hc = .{} },
    };
    const capacity = try encode.bound(source.len, options);
    const output = try allocator.alloc(u8, capacity);
    defer allocator.free(output);
    const streamed = try allocator.alloc(u8, capacity);
    defer allocator.free(streamed);
    const restored = try allocator.alloc(u8, source.len);
    defer allocator.free(restored);
    const storage: encode.Storage = .{ .workspace = workspace, .hc_workspace = hc };
    const wire = try encode.into(source, output, storage, options);
    _ = try test_decode.into(wire, restored, .{});
    try std.testing.expectEqualSlices(u8, source, restored);

    var exact = options;
    exact.compression.hc.limits.work_units = expected_work;
    const exact_wire = try encode.into(source, streamed, storage, exact);
    try std.testing.expectEqualSlices(u8, wire, exact_wire);
    var encoder: FrameStreamEncoder = undefined;
    try encoder.reset(storage, exact);
    var read: usize = 0;
    var written: usize = 0;
    while (true) {
        const end = @min(read + 127, source.len);
        const progress = try encoder.step(
            source[read..end],
            streamed[written..][0..113],
            if (end == source.len) .finish else .process,
        );
        read += progress.consumed;
        written += progress.produced;
        try std.testing.expect(
            progress.consumed != 0 or progress.produced != 0 or progress.status == .complete,
        );
        if (progress.status == .complete) break;
    }
    try std.testing.expectEqual(source.len, read);
    try std.testing.expectEqualSlices(u8, wire, streamed[0..written]);
    try std.testing.expectEqual(@as(u64, expected_work), encoder.counts().hc_work_units);

    var short = exact;
    short.compression.hc.limits.work_units -= 1;
    try encoder.reset(storage, short);
    try std.testing.expectError(error.LimitExceeded, encoder.step(source, streamed, .finish));
    try std.testing.expectEqual(@as(u64, first_work), encoder.counts().hc_work_units);
    try std.testing.expectEqual(@as(u64, second_work - 1), hc.stats.work_units);
    try std.testing.expectError(error.NeedReset, encoder.step(&.{}, streamed, .finish));
    try encoder.reset(storage, exact);
    const reused = try encoder.step(source, streamed, .finish);
    try std.testing.expectEqual(FrameStreamEncoder.Status.complete, reused.status);
    try std.testing.expectEqualSlices(u8, wire, streamed[0..reused.produced]);
    try std.testing.expectEqual(@as(u64, expected_work), encoder.counts().hc_work_units);
}

test "LZ4 frame HC storage refusals preserve the active encoder and allow retry" {
    const allocator = std.testing.allocator;
    const workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    const hc = try hc_encoder.Workspace.create(allocator);
    defer hc.destroy(allocator);
    const source = "an active frame survives refused replacement storage";
    var expected_bytes: [256]u8 = undefined;
    const expected = try encode.into(source, &expected_bytes, .{ .workspace = workspace }, .{});
    var encoder: FrameStreamEncoder = undefined;
    try encoder.reset(.{ .workspace = workspace }, .{});
    try std.testing.expectError(
        error.InvalidOptions,
        encoder.reset(.{ .workspace = workspace }, .{ .compression = .{ .hc = .{} } }),
    );
    var actual: [256]u8 = undefined;
    const progress = try encoder.step(source, &actual, .finish);
    try std.testing.expectEqual(FrameStreamEncoder.Status.complete, progress.status);
    try std.testing.expectEqualSlices(u8, expected, actual[0..progress.produced]);
    // The HC allocation is large and aligned enough to hold an encoder at the same address.
    const aliased: *FrameStreamEncoder = @ptrCast(hc);
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
    _ = try test_decode.into(actual[0..retried.produced], &restored, .{ .output_size = .exact });
    try std.testing.expectEqualStrings(source, &restored);
}

test "LZ4 frame allowance refusals preserve staged input and copied dictionaries" {
    const allocator = std.testing.allocator;
    const workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    const source = "active state keeps copied dictionary and staged input available";
    const options: encode.Options = .{
        .independent = false,
        .content_size = source.len,
        .dictionary = .{ .bytes = "active state ", .id = 17 },
    };
    var expected_bytes: [256]u8 = undefined;
    const expected = try encode.into(source, &expected_bytes, .{ .workspace = workspace }, options);

    // Initialize every reservation before taking snapshots; reset will replace only dictionary
    // prefixes, while process stages the first seven source bytes without emitting a block.
    @memset(workspace.input, 0x31);
    @memset(workspace.encoded, 0x52);
    @memset(&workspace.history, 0x73);
    @memset(&workspace.dictionary, 0x94);
    @memset(&workspace.codec.positions, 0xb5b5b5b5);
    var encoder: FrameStreamEncoder = undefined;
    try encoder.reset(.{ .workspace = workspace }, options);
    var actual: [256]u8 = undefined;
    const staged = try encoder.step(source[0..7], &actual, .process);
    try std.testing.expectEqual(Status.need_input, staged.status);
    try std.testing.expectEqual(7, staged.consumed);
    const admitted = encoder.counts();
    const reservations = [_][]const u8{
        workspace.input,
        workspace.encoded,
        &workspace.history,
        &workspace.dictionary,
        std.mem.asBytes(&workspace.codec),
    };
    var snapshots: [reservations.len][]u8 = @splat(&.{});
    defer for (snapshots) |snapshot| allocator.free(snapshot);
    for (reservations, &snapshots) |bytes, *snapshot| snapshot.* = try allocator.dupe(u8, bytes);

    try std.testing.expectError(
        error.LimitExceeded,
        encoder.reset(
            .{ .workspace = workspace },
            .{
                .dictionary = .{ .bytes = "replacement dictionary", .id = 29 },
                .limits = .{ .frames = 0 },
            },
        ),
    );
    try std.testing.expectEqualDeep(admitted, encoder.counts());
    for (reservations, snapshots) |bytes, snapshot| {
        try std.testing.expectEqualSlices(u8, snapshot, bytes);
    }
    const finished = try encoder.step(
        source[staged.consumed..],
        actual[staged.produced..],
        .finish,
    );
    try std.testing.expectEqual(Status.complete, finished.status);
    try std.testing.expectEqual(source.len - staged.consumed, finished.consumed);
    try std.testing.expectEqualSlices(
        u8,
        expected,
        actual[0 .. staged.produced + finished.produced],
    );
}
