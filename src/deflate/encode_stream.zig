//! Incremental raw DEFLATE encoding accepts source fragments, accumulates bounded slabs and drains
//! wire bytes across output suspensions. The stream owns retained history, action boundaries,
//! counters and failure state; block workers borrow the active source and scratch phases.

const std = @import("std");
const Compression = @import("Compression.zig");
const EncoderWorkspace = @import("EncodeWorkspace.zig");
const FourByteRunEncoderWorkspace = @import("FourByteRunWorkspace.zig");
const EncodeOptions = @import("EncodeOptions.zig");
const FourByteRunOptions = @import("FourByteRunOptions.zig");
const EncodeLimits = @import("EncodeLimits.zig");
const borrows = @import("block_borrows.zig");
const BlockWriter = @import("BlockWriter.zig");
const EncodeWorkBudget = @import("EncodeWorkBudget.zig");
const addCount = EncodeWorkBudget.addCount;
const writeStoredBody = BlockWriter.writeStoredBody;
const compression_effort = @import("compression_effort.zig");
const Profile = compression_effort.Profile;
const effort = compression_effort.resolve;
const test_decoding = @import("../deflate.zig");
const test_encoding = @import("encode.zig");
const encode = test_encoding.into;
const encodeBound = test_encoding.bound;

const slab_bytes = 65535;
const window_bytes = 32768;

/// End-of-fragment operation. Repeat an action with any unconsumed suffix. Flush/finish latch when
/// that fragment has been accepted. While draining a latched action, supply empty input and the
/// same action until its boundary.
pub const Action = enum {
    /// Accumulate input until a bounded slab can be encoded.
    process,
    /// Emit a byte-aligned synchronization point, retaining match history.
    flush,
    /// Emit a synchronization point and forget history for subsequent input.
    full_flush,
    /// Close the final block and pad the last byte; no further input is legal.
    finish,
};

/// Blocking or terminal encoder boundary.
pub const Status = enum {
    /// The encoder can accept more source bytes.
    need_input,
    /// Drain pending encoded bytes into another output span using the same action.
    need_output,
    /// The requested flush/full-flush boundary is fully emitted; a new action may begin.
    flushed,
    /// The final block and padding are fully emitted; no more source bytes may be added.
    complete,
};

/// Copied per-call progress. Accepted input and returned output may retire.
pub const Progress = struct {
    /// Accepted bytes from this fragment.
    consumed: usize,
    /// Initialized bytes in this output span; its suffix is untouched.
    produced: usize,
    /// Required resource or completed action.
    status: Status,
};

const EncodeStats = @import("EncodeStats.zig");

/// Persistent bounded encoder. Accepted input and returned output may retire after every step; no
/// caller input/output pointer or allocator is retained. The worker may move between calls by
/// exclusive transfer: retire the old state and keep its workspace stable. Do not continue two
/// copies sharing that reservation. Errors require reset; reset abandons unpublished pending wire
/// bytes.
pub const StreamEncoder = EncoderImpl(EncoderWorkspace, EncodeOptions);
const Encoder = StreamEncoder;
/// Streaming encoder using the smaller workspace and a valid stored/four-byte-run policy.
pub const FourByteRunStreamEncoder = EncoderImpl(FourByteRunEncoderWorkspace, FourByteRunOptions);

fn EncoderImpl(comptime Workspace: type, comptime Options: type) type {
    return struct {
        const Self = @This();

        /// Setup failures leave the incoming owner and reservations unchanged.
        pub const ResetError = error{
            /// Unsupported window/profile configuration or another invalid encoding option.
            InvalidOptions,
            /// Source, output, dictionary or scratch overlap where independent storage is required.
            StorageOverlap,
        };

        /// Framing-loan and stream-boundary failures.
        pub const StateError = error{
            /// The action or dictionary attachment is not valid at this stream boundary.
            InvalidState,
            /// A previous step failed; reset the encoder before continuing.
            NeedReset,
        };

        /// Preset-history attachment can also refuse overlapping storage.
        pub const DictionaryError = StateError || error{StorageOverlap};

        /// Processing failures include lifecycle, storage and cumulative admission errors.
        pub const StepError = DictionaryError || error{
            /// An input, output or algorithmic work allowance was exhausted.
            LimitExceeded,
            /// Required capacity or cumulative byte accounting cannot be represented.
            CounterOverflow,
        };

        /// Setup and streaming failures. Refused reset preserves the current owner; other failed
        /// calls poison it until reset. Counters may include admitted bytes and effort; published
        /// output remains a partial stream. No operation allocates.
        pub const Error = ResetError || StepError;
        /// Capacity available for an enclosing format's initial header staging loan.
        pub const framing_output_capacity = @sizeOf(@TypeOf(@as(Workspace, undefined).wire));
        /// Exclusive reservation retained until reset/end of use. All other fields are mechanism
        /// state; callers observe copied progress/counts through the public methods.
        workspace: *Workspace,
        /// Validated policy resolved once per reset, shared by successive block operations.
        options: struct {
            /// Selected block construction and parsing family.
            profile: Profile,
            /// Maximum prior candidates examined at each ordinary search position.
            depth: u16,
            /// Halve depth while checking a pending lazy match's next position.
            reduced_lookahead: bool,
            /// Retained match lengths/distances eligible for offline pricing.
            offline_pricing: Compression.OfflinePricing,
            /// Stopping rule for repeated offline price construction.
            offline_refinement: Compression.OfflineRefinement,
            /// Admitted maximum backward match distance in bytes.
            window_bytes: usize,
            /// Cumulative source, wire-output and algorithmic work allowances.
            limits: EncodeLimits,
        },
        /// Cumulative counters, including admitted work from an operation that later fails.
        stats: EncodeStats,

        /// Initialized history prefix in workspace.data.
        history: usize,
        /// Accepted but not yet encoded source bytes immediately following history.
        buffered: usize,

        /// Complete staged wire bytes, including any prefix already sent.
        pending: usize,
        /// Staged bytes already copied to caller output.
        sent: usize,
        /// Low pending bits retained across block boundaries.
        bits: u64,
        /// Number of bits in bits; fewer than eight outside bit-writing operations.
        bit_count: u6,

        /// Latched flush/finish action after its entire input fragment was accepted.
        boundary: ?Action,
        /// The final block and padding have been fully returned; no staged output remains.
        finished: bool,
        /// A previous operation failed; only reset can restore usable state.
        failed: bool,
        /// Input processing has begun, closing the dictionary-attachment boundary.
        started: bool,
        /// An enclosing format exclusively holds the initial staged-output storage.
        framing_output_borrowed: bool,

        /// Borrows otherwise unused staged-output storage for an enclosing format's initial header.
        /// Call only after reset and before processing input. Drain all copied framing bytes, then
        /// release the loan before using inputBuffer, commitInput, step or setDictionary. Framing
        /// bytes are not raw output and do not affect these counts. Misuse poisons the owner until
        /// reset; a successful reset invalidates the loan.
        pub fn borrowFramingOutput(self: *Self) StateError![]u8 {
            if (self.failed) return error.NeedReset;
            if (self.started or self.framing_output_borrowed) {
                self.failed = true;
                return error.InvalidState;
            }
            self.framing_output_borrowed = true;
            return &self.workspace.wire;
        }

        /// Ends the initial framing loan without changing raw output or counters. The borrowed
        /// slice must no longer be used; subsequent encoding may overwrite it immediately.
        pub fn releaseFramingOutput(self: *Self) StateError!void {
            if (self.failed) return error.NeedReset;
            if (!self.framing_output_borrowed) {
                self.failed = true;
                return error.InvalidState;
            }
            self.framing_output_borrowed = false;
        }

        /// Direct producer input. A producer may fill the returned prefix and immediately commit
        /// it, without another encoder operation in between. The borrow ends at commit; block
        /// construction can reuse these bytes. Ordinary step still requires input disjoint from the
        /// workspace.
        pub fn inputBuffer(encoder: *Self) ?[]u8 {
            if (encoder.failed or encoder.finished or encoder.framing_output_borrowed or encoder
                .boundary != null or encoder.pending != 0 or encoder.sent != 0) return null;
            const input_left = encoder.options.limits.input_bytes -| encoder.stats.input_bytes;
            const room: usize = @intCast(@min(slab_bytes - encoder.buffered, input_left));
            if (room == 0) return null;
            return encoder.workspace.data[encoder.history + encoder.buffered ..][0..room];
        }

        /// Commits the initialized prefix with process semantics. Output must not overlap the owner
        /// or workspace. Errors poison the encoder until reset.
        pub fn commitInput(encoder: *Self, length: usize, output: []u8) StepError!Progress {
            if (encoder.failed) return error.NeedReset;
            return encoder.commitBufferedInput(length, output) catch |err| {
                encoder.failed = true;
                return err;
            };
        }

        fn commitBufferedInput(encoder: *Self, length: usize, output: []u8) StepError!Progress {
            const available = encoder.inputBuffer() orelse return error.InvalidState;
            if (length > available.len) return error.InvalidState;
            try disjoint(output, std.mem.asBytes(encoder));
            try disjoint(output, std.mem.asBytes(encoder.workspace));
            encoder.started = true;
            encoder.buffered += length;
            encoder.stats.input_bytes = try addCount(encoder.stats.input_bytes, length);
            const progress = try encoder.advance(&.{}, output, .process);
            return .{
                .consumed = length,
                .produced = progress.produced,
                .status = progress.status,
            };
        }

        /// Initializes existing storage, copying optional dictionary history. Invalid options and
        /// overlaps among the incoming dictionary, owner and workspace are refused before mutation.
        pub fn reset(self: *Self, workspace: *Workspace, options: Options) ResetError!void {
            try disjoint(std.mem.asBytes(self), std.mem.asBytes(workspace));
            if (options.window_bytes < 256 or options.window_bytes > window_bytes)
                return error.InvalidOptions;
            if (!std.math.isPowerOfTwo(options.window_bytes)) return error.InvalidOptions;
            const compression: Compression = if (comptime Options == EncodeOptions) options
                .compression else switch (options.mode) {
                .runs => .{ .strategy = .four_byte_runs },
                .stored => .{ .level = 0 },
            };
            const selected = try effort(compression);
            if (options.dictionary) |dictionary| {
                // The dictionary may point into the old owner. Admit it before replacing self so a
                // refused reset cannot corrupt the bytes the caller supplied.
                try disjoint(dictionary, std.mem.asBytes(self));
                try disjoint(dictionary, std.mem.asBytes(workspace));
            }
            self.* = .{
                .workspace = workspace,
                .options = .{
                    .profile = selected.profile,
                    .depth = selected.depth,
                    .reduced_lookahead = switch (compression.lazy_lookahead) {
                        .full => false,
                        .reduced => true,
                        .automatic => compression.level == 6 and compression.strategy == .default,
                    },
                    .offline_pricing = compression.offline_pricing,
                    .offline_refinement = compression
                        .offline_refinement,
                    .window_bytes = options.window_bytes,
                    .limits = options
                        .limits,
                },
                .stats = .{},
                .history = 0,
                .buffered = 0,
                .pending = 0,
                .sent = 0,
                .bits = 0,
                .bit_count = 0,
                .boundary = null,
                .finished = false,
                .failed = false,
                .started = false,
                .framing_output_borrowed = false,
            };
            if (options.dictionary) |dictionary| self.copyDictionary(dictionary);
        }

        /// Copies only the reachable dictionary suffix before the first step. Dictionary bytes may
        /// retire on return. Multiple attachments replace the previous history; invalid
        /// state/overlap poisons the owner.
        pub fn setDictionary(self: *Self, dictionary: []const u8) DictionaryError!void {
            if (self.failed) return error.NeedReset;
            self.attach(dictionary) catch |err| {
                self.failed = true;
                return err;
            };
        }

        /// Returns copied byte/effort counters without exposing internal scratch. After failure,
        /// counts may include bytes and effort admitted during the failed step even though it
        /// returned no progress. Reset starts counts anew.
        pub fn counts(self: *const Self) EncodeStats {
            return self.stats;
        }

        /// Processes one fragment. An empty output span may still accept input into scratch. A
        /// flush boundary is returned once; resume with a new operation. Complete is idempotent
        /// only with empty input and finish. Failure may change output, returns no progress value
        /// and requires reset. Counts may still include work or bytes admitted during the failed
        /// call.
        pub fn step(
            self: *Self,
            input: []const u8,
            output: []u8,
            action: Action,
        ) StepError!Progress {
            if (self.failed) {
                @branchHint(.unlikely);
                return error.NeedReset;
            }
            return self.advance(input, output, action) catch |err| {
                @branchHint(.cold);
                self.failed = true;
                return err;
            };
        }

        fn attach(self: *Self, dictionary: []const u8) error{ InvalidState, StorageOverlap }!void {
            if (self.started or self.framing_output_borrowed) return error.InvalidState;
            try disjoint(dictionary, std.mem.asBytes(self));
            try disjoint(dictionary, std.mem.asBytes(self.workspace));
            self.copyDictionary(dictionary);
        }

        fn copyDictionary(self: *Self, dictionary: []const u8) void {
            self.history = @min(dictionary.len, self.historyLimit());
            @memcpy(
                self.workspace.data[0..self.history],
                dictionary[dictionary.len - self.history ..],
            );
        }

        fn advance(
            self: *Self,
            input: []const u8,
            output: []u8,
            action: Action,
        ) StepError!Progress {
            if (self.framing_output_borrowed) return error.InvalidState;
            try disjoint(input, output);
            inline for (.{ std.mem.asBytes(self), std.mem.asBytes(self.workspace) }) |reservation| {
                try disjoint(input, reservation);
                try disjoint(output, reservation);
            }
            if (self.finished) {
                if (input.len != 0 or action != .finish) return error.InvalidState;
                return .{ .consumed = 0, .produced = 0, .status = .complete };
            }
            if (self.boundary) |latched| {
                if (input.len != 0 or latched != action) return error.InvalidState;
            }
            self.started = true;
            if (self.options.profile == .stored and action == .finish) {
                if (try self.finishStored(
                    input,
                    output,
                )) |written| return .{
                    .consumed = input.len,
                    .produced = written,
                    .status = .complete,
                };
            }

            var read: usize = 0;
            var written: usize = 0;
            while (true) {
                const output_left = self.options.limits.output_bytes -| self.stats.output_bytes;
                const available: usize = @intCast(@min(output.len - written, output_left));
                const amount = @min(available, self.pending - self.sent);
                @memcpy(output[written..][0..amount], self.workspace.wire[self.sent..][0..amount]);
                self.sent += amount;
                written += amount;
                self.stats.output_bytes = try addCount(self.stats.output_bytes, amount);
                if (self.sent != self.pending) {
                    if (self.stats.output_bytes == self.options.limits.output_bytes)
                        return error.LimitExceeded;
                    return .{ .consumed = read, .produced = written, .status = .need_output };
                }
                self.pending = 0;
                self.sent = 0;
                if (self.boundary) |latched| {
                    self.boundary = null;
                    if (latched == .finish) self.finished = true;
                    if (latched == .full_flush) self.history = 0;
                    return .{
                        .consumed = read,
                        .produced = written,
                        .status = if (latched == .finish) .complete else .flushed,
                    };
                }
                const input_left = self.options.limits.input_bytes -| self.stats.input_bytes;
                const room: usize = @intCast(@min(slab_bytes - self.buffered, input_left));
                const take = @min(room, input.len - read);
                @memcpy(
                    self.workspace.data[self.history + self.buffered ..][0..take],
                    input[read..][0..take],
                );
                self.buffered += take;
                read += take;
                self.stats.input_bytes = try addCount(self.stats.input_bytes, take);
                if (read < input.len and self.stats.input_bytes == self.options.limits.input_bytes)
                    return error.LimitExceeded;
                const at_end = read == input.len;
                if (self.buffered == slab_bytes or (at_end and action != .process)) {
                    const closing = at_end and action != .process;
                    try self.buildBlock(closing and action == .finish);
                    if (closing) {
                        if (action != .finish) {
                            try borrows.writer(self).stored(&.{}, false);
                        } else {
                            borrows.writer(self).alignBits();
                        }
                        self.boundary = action;
                    }
                    continue;
                }
                return .{ .consumed = read, .produced = written, .status = .need_input };
            }
        }

        // A complete stored finish needs neither staged input nor a retained match history. Use the
        // ordinary path when buffering, pending output or a limit can suspend/refuse this
        // operation.
        fn finishStored(
            self: *Self,
            input: []const u8,
            output: []u8,
        ) error{CounterOverflow}!?usize {
            if (self.buffered != 0 or self.pending != 0 or self.boundary != null) return null;
            if (self.bit_count != 0) return null;
            const blocks = @max(
                1,
                input.len / slab_bytes + @intFromBool(input.len % slab_bytes != 0),
            );
            const overhead = std.math.mul(usize, blocks, 5) catch return null;
            const bytes = std.math.add(usize, input.len, overhead) catch return null;
            const input_left = self.options.limits.input_bytes -| self.stats.input_bytes;
            const output_left = self.options.limits.output_bytes -| self.stats.output_bytes;
            if (bytes > output.len or input.len > input_left or bytes > output_left) return null;

            var next_stats = self.stats;
            next_stats.input_bytes = try addCount(next_stats.input_bytes, input.len);
            next_stats.output_bytes = try addCount(next_stats.output_bytes, bytes);
            next_stats.blocks = try addCount(next_stats.blocks, blocks);
            next_stats.stored_blocks = try addCount(next_stats.stored_blocks, blocks);

            var read: usize = 0;
            var written: usize = 0;
            for (0..blocks) |index| {
                const take: usize = @min(slab_bytes, input.len - read);
                output[written] = @intFromBool(index + 1 == blocks);
                writeStoredBody(input[read..][0..take], output[written + 1 ..][0 .. take + 4]);
                read += take;
                written += take + 5;
            }
            self.stats = next_stats;
            self.history = 0;
            self.finished = true;
            return written;
        }

        fn historyLimit(self: *const Self) usize {
            // This profile only refers to the previous four bytes. Retaining a full window would
            // copy unused history after each nonfinal block.
            return if (self.options.profile == .four_byte_runs) 4 else self.options.window_bytes;
        }

        fn buildBlock(self: *Self, final: bool) EncodeWorkBudget.Error!void {
            const workspace = self.workspace;
            if (self.options.profile == .stored) {
                try borrows.writer(
                    self,
                ).stored(workspace.data[self.history..][0..self.buffered], final);
            } else {
                if (self.options.profile == .four_byte_runs) {
                    try borrows.fourByteRuns(self).encode(final);
                } else if (comptime Workspace == FourByteRunEncoderWorkspace) {
                    unreachable;
                } else {
                    const block = borrows.ordinary(self);
                    try block.encode(final);
                }
            }
            if (!final) {
                const total = self.history + self.buffered;
                self.history = @min(total, self.historyLimit());
                // When the retained suffix starts at zero it is already in place.
                if (total > self.history) {
                    std.mem.copyForwards(
                        u8,
                        workspace.data[0..self.history],
                        workspace.data[total - self.history .. total],
                    );
                }
            }
            self.buffered = 0;
        }
    };
}

pub fn disjoint(a: []const u8, b: []const u8) error{StorageOverlap}!void {
    if (a.len == 0 or b.len == 0) return;
    const x = @intFromPtr(a.ptr);
    const y = @intFromPtr(b.ptr);
    const overlap = if (x <= y) y - x < a.len else x - y < b.len;
    if (overlap) return error.StorageOverlap;
}

test "encoder state transfers while a latched finish drains pending output" {
    const allocator = std.testing.allocator;
    inline for (.{ StreamEncoder, FourByteRunStreamEncoder }) |E| {
        const W = if (E == StreamEncoder) EncoderWorkspace else FourByteRunEncoderWorkspace;
        const workspace = try W.create(allocator);
        defer workspace.destroy(allocator);
        const source = "a transferred encoder retains its pending bytes and finish boundary";
        var expected: [256]u8 = undefined;
        var actual: [256]u8 = undefined;
        var original: E = undefined;
        try original.reset(workspace, .{});
        const reference = try original.step(source, &expected, .finish);
        try std.testing.expectEqual(Status.complete, reference.status);
        const expected_counts = original.counts();

        try original.reset(workspace, .{});
        const first = try original.step(source, actual[0..1], .finish);
        try std.testing.expectEqual(source.len, first.consumed);
        try std.testing.expectEqual(Status.need_output, first.status);
        var written = first.produced;
        var transferred = original;
        // Retire the former owner. The active copy must refer only to the external workspace.
        @memset(std.mem.asBytes(&original), 0xa5);
        while (true) {
            const progress = try transferred.step(
                &.{},
                actual[written..][0..@min(3, actual.len - written)],
                .finish,
            );
            try std.testing.expectEqual(0, progress.consumed);
            written += progress.produced;
            if (progress.status == .complete) break;
            try std.testing.expectEqual(Status.need_output, progress.status);
            try std.testing.expect(progress.produced != 0);
        }
        try std.testing.expectEqualSlices(u8, expected[0..reference.produced], actual[0..written]);
        try std.testing.expectEqualDeep(expected_counts, transferred.counts());
    }
}

test "initial framing output loans preserve raw bytes counts and reset admission" {
    const allocator = std.testing.allocator;
    inline for (.{ StreamEncoder, FourByteRunStreamEncoder }) |E| {
        const W = if (E == StreamEncoder) EncoderWorkspace else FourByteRunEncoderWorkspace;
        const workspace = try W.create(allocator);
        defer workspace.destroy(allocator);
        var encoder: E = undefined;
        const source = "ABCDABCDABCDABCDABCDABCDABCDABCDABCDABCD";
        var expected: [256]u8 = undefined;
        var actual: [256]u8 = undefined;
        try encoder.reset(workspace, .{ .dictionary = "ABCD" });
        const reference = try encoder.step(source, &expected, .finish);
        const reference_counts = encoder.counts();

        try encoder.reset(workspace, .{ .dictionary = "ABCD" });
        const before = encoder.counts();
        const loan = try encoder.borrowFramingOutput();
        try std.testing.expectEqual(E.framing_output_capacity, loan.len);
        @memset(loan, 0xa5);
        try std.testing.expect(encoder.inputBuffer() == null);
        try std.testing.expectEqualDeep(before, encoder.counts());
        try std.testing.expectError(
            error.InvalidOptions,
            encoder.reset(workspace, .{ .window_bytes = 257 }),
        );
        try std.testing.expect(encoder.inputBuffer() == null);
        try std.testing.expectEqualDeep(before, encoder.counts());
        try std.testing.expect(std.mem.allEqual(u8, loan, 0xa5));
        try encoder.releaseFramingOutput();
        const progress = try encoder.step(source, &actual, .finish);
        try std.testing.expectEqualDeep(reference, progress);
        try std.testing.expectEqualSlices(
            u8,
            expected[0..reference.produced],
            actual[0..progress.produced],
        );
        try std.testing.expectEqualDeep(reference_counts, encoder.counts());

        try encoder.reset(workspace, .{});
        _ = try encoder.borrowFramingOutput();
        try encoder.reset(workspace, .{});
        try std.testing.expect(encoder.inputBuffer() != null);
        _ = try encoder.borrowFramingOutput();
        try encoder.releaseFramingOutput();
    }
}

test "initial framing output loan refuses conflicting operations until reset" {
    const allocator = std.testing.allocator;
    inline for (.{ StreamEncoder, FourByteRunStreamEncoder }) |E| {
        const W = if (E == StreamEncoder) EncoderWorkspace else FourByteRunEncoderWorkspace;
        const workspace = try W.create(allocator);
        defer workspace.destroy(allocator);
        var encoder: E = undefined;
        var output: [64]u8 = @splat(0xa5);
        for (0..4) |operation| {
            try encoder.reset(workspace, .{});
            _ = try encoder.borrowFramingOutput();
            const before = encoder.counts();
            switch (operation) {
                0 => try std.testing.expectError(
                    error.InvalidState,
                    encoder.step("source", &output, .finish),
                ),
                1 => try std.testing.expectError(
                    error.InvalidState,
                    encoder.commitInput(0, &output),
                ),
                2 => try std.testing.expectError(
                    error.InvalidState,
                    encoder.setDictionary("history"),
                ),
                3 => try std.testing.expectError(error.InvalidState, encoder.borrowFramingOutput()),
                else => unreachable,
            }
            try std.testing.expectEqualDeep(before, encoder.counts());
            try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
            try std.testing.expect(encoder.inputBuffer() == null);
            try std.testing.expectError(error.NeedReset, encoder.releaseFramingOutput());
            try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
        }
        try encoder.reset(workspace, .{});
        try std.testing.expectError(error.InvalidState, encoder.releaseFramingOutput());
        try encoder.reset(workspace, .{});
        _ = try encoder.step(&.{}, &output, .process);
        try std.testing.expectError(error.InvalidState, encoder.borrowFramingOutput());
    }
}

test "automatic lookahead matches explicit policy for each level and strategy" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const input = "small repeated data: ababacabababacababababacabababac";
    var expected_storage: [1024]u8 = undefined;
    var actual_storage: [1024]u8 = undefined;
    for (0..10) |level| {
        for ([_]Compression.Strategy{ .default, .huffman_only, .four_byte_runs }) |strategy| {
            const automatic: Compression = .{
                .level = @intCast(level),
                .strategy = strategy,
                .lazy_lookahead = .automatic,
            };
            try automatic.validate();
            var explicit = automatic;
            explicit.lazy_lookahead = if (level == 6 and strategy == .default) .reduced else .full;
            const expected = try encode(
                input,
                &expected_storage,
                workspace,
                .{ .compression = explicit },
            );
            const actual = try encode(
                input,
                &actual_storage,
                workspace,
                .{ .compression = automatic },
            );
            try std.testing.expectEqualSlices(u8, expected, actual);
        }
    }
}

test "automatic lookahead keeps explicit policy work and failure boundaries" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const input = "ababacabababacababababacabababac";
    var auto_storage: [1024]u8 = undefined;
    var explicit_storage: [1024]u8 = undefined;
    for (0..10) |level| {
        for ([_]Compression.Strategy{ .default, .huffman_only, .four_byte_runs }) |strategy| {
            for ([_]u64{ 0, 1, 100, 1000, std.math.maxInt(u64) }) |budget| {
                const automatic: Compression = .{
                    .level = @intCast(level),
                    .strategy = strategy,
                    .lazy_lookahead = .automatic,
                };
                var explicit = automatic;
                explicit.lazy_lookahead = if (level == 6 and strategy == .default)
                    .reduced
                else
                    .full;
                var first: Encoder = undefined;
                try first.reset(
                    workspace,
                    .{ .compression = automatic, .limits = .{ .work_units = budget } },
                );
                const actual = first.step(input, &auto_storage, .finish);
                const actual_counts = first.counts();
                var second: Encoder = undefined;
                try second.reset(
                    workspace,
                    .{ .compression = explicit, .limits = .{ .work_units = budget } },
                );
                const expected = second.step(input, &explicit_storage, .finish);
                if (actual) |progress| {
                    const reference = try expected;
                    try std.testing.expectEqualDeep(reference, progress);
                    try std.testing.expectEqualSlices(
                        u8,
                        explicit_storage[0..reference.produced],
                        auto_storage[0..progress.produced],
                    );
                } else |err| {
                    try std.testing.expectError(err, expected);
                }
                try std.testing.expectEqualDeep(second.counts(), actual_counts);
            }
        }
    }
}

test "chain refusal reports admitted probes and requires reset" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var output: [128]u8 = undefined;
    for ([_]u8{ 3, 6 }) |level| {
        try encoder.reset(
            workspace,
            .{ .compression = .{ .level = level }, .limits = .{ .work_units = 1 } },
        );
        try std.testing.expectError(
            error.LimitExceeded,
            encoder.step("aaaaaaaaaaaa", &output, .finish),
        );
        try std.testing.expectEqual(1, encoder.counts().work_units);
        try std.testing.expectEqual(1, encoder.counts().match_probes);
        try std.testing.expectError(error.NeedReset, encoder.step("", &output, .finish));
        try encoder.reset(workspace, .{ .compression = .{ .level = level } });
        const progress = try encoder.step("aaaaaaaaaaaa", &output, .finish);
        try std.testing.expectEqual(.complete, progress.status);
    }
}

test "work limits retain exact boundaries with and without history" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var output: [512]u8 = undefined;
    const source = "aaaaaaaaaaaa";
    for (
        [_]Compression{
            .{ .level = 3 },
            .{ .level = 4, .lazy_lookahead = .reduced },
            .{ .level = 5, .lazy_lookahead = .reduced },
            .{ .level = 6, .lazy_lookahead = .reduced },
            .{ .level = 6 },
            .{ .level = 9 },
            .{ .level = 9, .offline_refinement = .early },
        },
    ) |compression| {
        for ([_]?[]const u8{ null, "aaaaaaaaaaaa" }) |dictionary| {
            var options: EncodeOptions = .{ .compression = compression, .dictionary = dictionary };
            try encoder.reset(workspace, options);
            const complete = try encoder.step(source, &output, .finish);
            try std.testing.expectEqual(.complete, complete.status);
            const full = encoder.counts();
            try std.testing.expect(full.work_units > 1);
            for ([_]u64{ 0, 1, full.work_units - 1, full.work_units }) |budget| {
                options.limits.work_units = budget;
                try encoder.reset(workspace, options);
                const result = encoder.step(source, &output, .finish);
                if (budget == full.work_units) {
                    const progress = try result;
                    try std.testing.expectEqual(.complete, progress.status);
                    try std.testing.expectEqual(full, encoder.counts());
                } else {
                    try std.testing.expectError(error.LimitExceeded, result);
                    try std.testing.expect(encoder.counts().work_units <= budget);
                    try std.testing.expectError(
                        error.NeedReset,
                        encoder.step("", &output, .finish),
                    );
                }
            }
        }
    }
}

test "offline refusal reports admitted probes and requires reset" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var output: [128]u8 = undefined;
    try encoder.reset(
        workspace,
        .{ .compression = .{ .level = 9 }, .limits = .{ .work_units = 1 } },
    );
    try std.testing.expectError(error.LimitExceeded, encoder.step("aaaaa", &output, .finish));
    try std.testing.expectEqual(1, encoder.counts().work_units);
    try std.testing.expectEqual(1, encoder.counts().match_probes);
    try std.testing.expectError(error.NeedReset, encoder.step("", &output, .finish));
    try encoder.reset(workspace, .{ .compression = .{ .level = 9 } });
    const progress = try encoder.step("aaaaa", &output, .finish);
    try std.testing.expectEqual(.complete, progress.status);
}

test "default and stored compression selections retain their exact contracts" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    const source = "a small repeated payload, a small repeated payload";
    var default_wire: [512]u8 = undefined;
    var explicit_wire: [512]u8 = undefined;
    var encoder: Encoder = undefined;

    // The common default must be the documented level, including its copied work counters.
    try encoder.reset(workspace, .{});
    const first = try encoder.step(source, &default_wire, .finish);
    const counts = encoder.counts();
    try encoder.reset(workspace, .{ .compression = .{ .level = 6 } });
    const second = try encoder.step(source, &explicit_wire, .finish);
    try std.testing.expectEqual(Status.complete, first.status);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqualDeep(counts, encoder.counts());
    try std.testing.expectEqualSlices(
        u8,
        default_wire[0..first.produced],
        explicit_wire[0..second.produced],
    );

    for ([_]u8{ 4, 5, 6 }) |level| {
        try encoder.reset(workspace, .{ .compression = .{ .level = level } });
        const implicit = try encoder.step(source, &default_wire, .finish);
        const implicit_counts = encoder.counts();
        try encoder.reset(
            workspace,
            .{ .compression = .{ .level = level, .lazy_lookahead = .full } },
        );
        const explicit = try encoder.step(source, &explicit_wire, .finish);
        try std.testing.expectEqual(implicit, explicit);
        try std.testing.expectEqualDeep(implicit_counts, encoder.counts());
        try std.testing.expectEqualSlices(
            u8,
            default_wire[0..implicit.produced],
            explicit_wire[0..explicit.produced],
        );
    }

    // Level zero takes precedence over the optional strategy and still emits the same stored wire.
    const stored = try encode(
        source,
        &default_wire,
        workspace,
        .{ .compression = .{ .level = 0 } },
    );
    const stored_with_strategy = try encode(
        source,
        &explicit_wire,
        workspace,
        .{ .compression = .{ .level = 0, .strategy = .huffman_only } },
    );
    try std.testing.expectEqualSlices(u8, stored, stored_with_strategy);
}

test "reduced lazy lookahead changes search work on a collision-heavy input" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var source: [8192]u8 = undefined;
    var state: u32 = 0x12a654cd;
    for (&source) |*byte| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = @truncate(state & 3);
    }
    var output: [16384]u8 = undefined;
    var encoder: Encoder = undefined;
    for ([_]u8{ 4, 5, 6 }) |level| {
        try encoder.reset(workspace, .{ .compression = .{ .level = level } });
        try std.testing.expectEqual(
            Status.complete,
            (try encoder.step(&source, &output, .finish)).status,
        );
        const full = encoder.counts();
        try encoder.reset(
            workspace,
            .{ .compression = .{ .level = level, .lazy_lookahead = .reduced } },
        );
        try std.testing.expectEqual(
            Status.complete,
            (try encoder.step(&source, &output, .finish)).status,
        );
        try std.testing.expect(encoder.counts().match_probes < full.match_probes);
    }
}

test "automatic lookahead matches reduced work and failures on collisions" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var source: [8192]u8 = undefined;
    var state: u32 = 0x12a654cd;
    for (&source) |*byte| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = @truncate(state & 3);
    }
    var encoder: Encoder = undefined;
    var full_output: [16384]u8 = undefined;
    try encoder.reset(workspace, .{ .compression = .{ .level = 6, .lazy_lookahead = .full } });
    _ = try encoder.step(&source, &full_output, .finish);
    const full = encoder.counts();
    var reduced_output: [16384]u8 = undefined;
    try encoder.reset(workspace, .{ .compression = .{ .level = 6, .lazy_lookahead = .reduced } });
    const reduced_progress = try encoder.step(&source, &reduced_output, .finish);
    const reduced = encoder.counts();
    try std.testing.expect(reduced.match_probes < full.match_probes);
    var automatic_output: [16384]u8 = undefined;
    try encoder.reset(workspace, .{ .compression = .{ .level = 6, .lazy_lookahead = .automatic } });
    const automatic_progress = try encoder.step(&source, &automatic_output, .finish);
    try std.testing.expectEqualDeep(reduced_progress, automatic_progress);
    try std.testing.expectEqualDeep(reduced, encoder.counts());
    try std.testing.expectEqualSlices(
        u8,
        reduced_output[0..reduced_progress.produced],
        automatic_output[0..automatic_progress.produced],
    );
    for ([_]u64{ 0, 1, reduced.work_units - 1, reduced.work_units }) |budget| {
        @memset(&automatic_output, 0xa5);
        @memset(&reduced_output, 0xa5);
        try encoder.reset(
            workspace,
            .{
                .compression = .{ .level = 6, .lazy_lookahead = .automatic },
                .limits = .{ .work_units = budget },
            },
        );
        const actual = encoder.step(&source, &automatic_output, .finish);
        const actual_counts = encoder.counts();
        try encoder.reset(
            workspace,
            .{
                .compression = .{ .level = 6, .lazy_lookahead = .reduced },
                .limits = .{ .work_units = budget },
            },
        );
        const expected = encoder.step(&source, &reduced_output, .finish);
        if (actual) |progress| {
            try std.testing.expectEqualDeep(try expected, progress);
        } else |err| {
            try std.testing.expectError(err, expected);
        }
        try std.testing.expectEqualDeep(encoder.counts(), actual_counts);
        try std.testing.expectEqualSlices(u8, &reduced_output, &automatic_output);
    }
}

test "reduced lazy lookahead preserves fragmented encoding and dictionary recovery" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const decoder = try test_decoding.decode.Workspace.create(allocator);
    defer decoder.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const dictionary = "a dictionary with recurring fragments and repeated fragments";
    var source: [4096]u8 = undefined;
    for (&source, 0..) |*byte, i| {
        byte.* = "recurring fragments with variations"[(i + i / 113) % 35];
    }
    var complete_wire: [8192]u8 = undefined;
    var fragmented_wire: [8192]u8 = undefined;
    var restored: [source.len]u8 = undefined;
    var encoder: Encoder = undefined;
    for ([_]u8{ 4, 5, 6 }) |level| {
        const options: EncodeOptions = .{
            .compression = .{ .level = level, .lazy_lookahead = .reduced },
            .dictionary = dictionary,
            .window_bytes = 256,
        };
        try encoder.reset(workspace, options);
        const complete = try encoder.step(&source, &complete_wire, .finish);
        try std.testing.expectEqual(Status.complete, complete.status);
        const counts = encoder.counts();
        try encoder.reset(workspace, options);
        var read: usize = 0;
        var written: usize = 0;
        while (true) {
            const end = @min(source.len, read + 71);
            const action: Action = if (end == source.len) .finish else .process;
            const output_end = @min(fragmented_wire.len, written + 13);
            const progress = try encoder.step(
                source[read..end],
                fragmented_wire[written..output_end],
                action,
            );
            read += progress.consumed;
            written += progress.produced;
            if (progress.status == .complete) break;
            try std.testing.expect(progress.consumed != 0 or progress.produced != 0);
        }
        try std.testing.expectEqual(source.len, read);
        try std.testing.expectEqualSlices(
            u8,
            complete_wire[0..complete.produced],
            fragmented_wire[0..written],
        );
        try std.testing.expectEqualDeep(counts, encoder.counts());
        const result = try test_decoding.decode.into(
            fragmented_wire[0..written],
            &restored,
            .{ .workspace = decoder, .history = history },
            .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
        );
        try std.testing.expectEqual(source.len, result.produced);
        try std.testing.expectEqualSlices(u8, &source, &restored);
    }
}

test "encoder reset admits dictionary before replacing the owner" {
    const allocator = std.testing.allocator;
    const old_workspace = try EncoderWorkspace.create(allocator);
    defer old_workspace.destroy(allocator);
    const new_workspace = try EncoderWorkspace.create(allocator);
    defer new_workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(old_workspace, .{});
    _ = try encoder.step("ABCDEFGH", &.{}, .process);

    // A rejected dictionary may be a view of the previous owner's live counters. The source must
    // retain its bytes even though reset was asked to replace that owner.
    const owner_bytes = std.mem.asBytes(&encoder.stats.input_bytes);
    const before = owner_bytes[0..@sizeOf(u64)].*;
    try std.testing.expectError(
        error.StorageOverlap,
        encoder.reset(new_workspace, .{ .dictionary = owner_bytes }),
    );
    try std.testing.expectEqualSlices(u8, &before, owner_bytes);

    // The incoming workspace is still protected, but the retired workspace may supply a copied
    // dictionary because it does not overlap the new reservations.
    @memset(new_workspace.data[0..8], 0xa5);
    try std.testing.expectError(
        error.StorageOverlap,
        encoder.reset(new_workspace, .{ .dictionary = new_workspace.data[0..8] }),
    );
    try std.testing.expect(std.mem.allEqual(u8, new_workspace.data[0..8], 0xa5));
    @memcpy(old_workspace.data[0..8], "history!");
    try encoder.reset(new_workspace, .{ .dictionary = old_workspace.data[0..8] });
    try std.testing.expectEqualSlices(u8, "history!", new_workspace.data[0..encoder.history]);
}

test "stored finishes preserve independent RFC slab headers payloads and counters" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const source = try allocator.alloc(u8, 131071);
    defer allocator.free(source);
    for (source, 0..) |*byte, index| byte.* = @truncate(index * 37 + 11);
    const storage = try allocator.alloc(u8, source.len + 3 * 5 + 32);
    defer allocator.free(storage);
    // RFC 1951 section 3.2.4: BFINAL/BTYPE and little-endian LEN/complement. These boundary headers
    // are authored independently of the encoder and its capacity helper.
    const cases = [_]struct {
        bytes: usize,
        full_prefixes: usize,
        final_header: [5]u8,
    }{
        .{ .bytes = 0, .full_prefixes = 0, .final_header = .{ 1, 0, 0, 255, 255 } },
        .{ .bytes = 1, .full_prefixes = 0, .final_header = .{ 1, 1, 0, 254, 255 } },
        .{ .bytes = 65534, .full_prefixes = 0, .final_header = .{ 1, 254, 255, 1, 0 } },
        .{ .bytes = 65535, .full_prefixes = 0, .final_header = .{ 1, 255, 255, 0, 0 } },
        .{ .bytes = 65536, .full_prefixes = 1, .final_header = .{ 1, 1, 0, 254, 255 } },
        .{ .bytes = 131070, .full_prefixes = 1, .final_header = .{ 1, 255, 255, 0, 0 } },
        .{ .bytes = 131071, .full_prefixes = 2, .final_header = .{ 1, 1, 0, 254, 255 } },
    };
    for (cases) |case| {
        const wire_bytes = case.bytes + (case.full_prefixes + 1) * 5;
        for ([_]usize{ 256, 32768 }) |window| {
            var encoder: Encoder = undefined;
            try encoder.reset(
                workspace,
                .{
                    .compression = .{ .level = 0 },
                    .window_bytes = window,
                    .dictionary = "copied preset history",
                    .limits = .{
                        .input_bytes = case.bytes,
                        .output_bytes = wire_bytes,
                        .work_units = 0,
                    },
                },
            );
            @memset(storage, 0xa7);
            const output = storage[1 .. wire_bytes + 9];
            const progress = try encoder.step(source[0..case.bytes], output, .finish);
            try std.testing.expectEqual(.complete, progress.status);
            try std.testing.expectEqual(case.bytes, progress.consumed);
            try std.testing.expectEqual(wire_bytes, progress.produced);
            var read: usize = 0;
            var written: usize = 0;
            for (0..case.full_prefixes) |_| {
                try std.testing.expectEqualSlices(
                    u8,
                    &.{ 0, 255, 255, 0, 0 },
                    output[written..][0..5],
                );
                try std.testing.expectEqualSlices(
                    u8,
                    source[read..][0..65535],
                    output[written + 5 ..][0..65535],
                );
                read += 65535;
                written += 65540;
            }
            try std.testing.expectEqualSlices(u8, &case.final_header, output[written..][0..5]);
            try std.testing.expectEqualSlices(
                u8,
                source[read..case.bytes],
                output[written + 5 .. wire_bytes],
            );
            try std.testing.expectEqual(0xa7, storage[0]);
            try std.testing.expect(std.mem.allEqual(u8, storage[wire_bytes + 1 ..], 0xa7));
            try std.testing.expectEqual(
                EncodeStats{
                    .input_bytes = case.bytes,
                    .output_bytes = wire_bytes,
                    .blocks = case.full_prefixes + 1,
                    .stored_blocks = case.full_prefixes + 1,
                },
                encoder.counts(),
            );
            const repeated = try encoder.step(&.{}, &.{}, .finish);
            try std.testing.expectEqual(
                Progress{ .consumed = 0, .produced = 0, .status = .complete },
                repeated,
            );
        }
    }
    for (
        source,
        0..,
    ) |byte, index| try std.testing.expectEqual(@as(u8, @truncate(index * 37 + 11)), byte);
}

test "stored finishes retain buffered input retired spans and output suspensions" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const source = try allocator.alloc(u8, 65536);
    defer allocator.free(source);
    const output = try allocator.alloc(u8, 65547);
    defer allocator.free(output);
    const expected = try allocator.alloc(u8, 65546);
    defer allocator.free(expected);
    @memcpy(expected[0..5], &[_]u8{ 0, 255, 255, 0, 0 });
    @memset(expected[5..65540], 'c');
    @memcpy(expected[65540..], &[_]u8{ 1, 1, 0, 254, 255, 'c' });
    const expected_stats: EncodeStats = .{
        .input_bytes = 65536,
        .output_bytes = 65546,
        .blocks = 2,
        .stored_blocks = 2,
    };
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, .{ .compression = .{ .level = 0 } });
    @memset(source, 'c');
    const buffered = try encoder.step(source[0..13], &.{}, .process);
    try std.testing.expectEqual(
        Progress{ .consumed = 13, .produced = 0, .status = .need_input },
        buffered,
    );
    @memset(source[0..13], 'Z'); // Accepted bytes may retire before the finish.
    @memset(output, 0xa7);
    const complete = try encoder.step(source[13..], output[0..65546], .finish);
    try std.testing.expectEqual(.complete, complete.status);
    try std.testing.expectEqual(65523, complete.consumed);
    try std.testing.expectEqual(65546, complete.produced);
    try std.testing.expectEqualSlices(u8, expected, output[0..65546]);
    try std.testing.expectEqual(0xa7, output[65546]);
    try std.testing.expectEqual(expected_stats, encoder.counts());

    try encoder.reset(workspace, .{ .compression = .{ .level = 0 } });
    @memset(source, 'c');
    const suspended = try encoder.step(source, &.{}, .finish);
    try std.testing.expectEqual(
        Progress{ .consumed = 65535, .produced = 0, .status = .need_output },
        suspended,
    );
    @memset(source[0..suspended.consumed], 'Z');
    @memset(output, 0xa7);
    var read = suspended.consumed;
    var written: usize = 0;
    while (true) {
        const span = output[written..@min(written + 13, expected.len)];
        const progress = try encoder.step(source[read..], span, .finish);
        read += progress.consumed;
        written += progress.produced;
        if (progress.status == .complete) break;
        try std.testing.expectEqual(.need_output, progress.status);
        try std.testing.expect(progress.consumed + progress.produced != 0);
    }
    try std.testing.expectEqual(source.len, read);
    try std.testing.expectEqual(expected.len, written);
    try std.testing.expectEqualSlices(u8, expected, output[0..written]);
    try std.testing.expectEqual(0xa7, output[written]);
    try std.testing.expectEqual(expected_stats, encoder.counts());
}

test "stored finishes preserve flush accounting limit failures and overlap refusal" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    var output: [32]u8 = undefined;
    const expected = [_]u8{ 0, 1, 0, 254, 255, 'A', 0, 0, 0, 255, 255, 1, 1, 0, 254, 255, 'B' };
    for ([_]Action{ .flush, .full_flush }) |action| {
        try encoder.reset(
            workspace,
            .{
                .compression = .{ .level = 0 },
                .limits = .{ .input_bytes = 2, .output_bytes = expected.len, .work_units = 0 },
            },
        );
        const prefix = try encoder.step("A", &output, action);
        try std.testing.expectEqual(.flushed, prefix.status);
        const finish = try encoder.step("B", output[prefix.produced..], .finish);
        try std.testing.expectEqual(.complete, finish.status);
        try std.testing.expectEqualSlices(
            u8,
            &expected,
            output[0 .. prefix.produced + finish.produced],
        );
        try std.testing.expectEqual(
            EncodeStats{
                .input_bytes = 2,
                .output_bytes = expected.len,
                .blocks = 3,
                .stored_blocks = 3,
            },
            encoder.counts(),
        );
    }
    for ([_]EncodeLimits{ .{ .input_bytes = 0 }, .{ .output_bytes = 5 } }) |limits| {
        try encoder.reset(workspace, .{ .compression = .{ .level = 0 }, .limits = limits });
        try std.testing.expectError(error.LimitExceeded, encoder.step("A", &output, .finish));
        try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
    }
    try encoder.reset(workspace, .{ .compression = .{ .level = 0 } });
    output[0] = 'A';
    try std.testing.expectError(error.StorageOverlap, encoder.step(output[0..1], &output, .finish));
    try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
}

test "empty flush before the first data block preserves dictionary behavior" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const decoder = try test_decoding.decode.Workspace.create(allocator);
    defer decoder.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const dictionary = "dictionary payload: repeated content for retained tree matching ";
    const input = try allocator.alloc(u8, 90000);
    defer allocator.free(input);
    for (input, 0..) |*byte, i| byte.* = dictionary[i % dictionary.len];
    const output = try allocator.alloc(u8, try encodeBound(input.len) + 128);
    defer allocator.free(output);
    const restored = try allocator.alloc(u8, input.len);
    defer allocator.free(restored);
    for ([_]Action{ .flush, .full_flush }) |action| {
        var encoder: Encoder = undefined;
        try encoder.reset(workspace, .{ .dictionary = dictionary, .compression = .{ .level = 9 } });
        const initial = try encoder.step(&.{}, output, action);
        try std.testing.expectEqual(.flushed, initial.status);
        var read: usize = 0;
        var written = initial.produced;
        while (true) {
            const part = try encoder.step(input[read..], output[written..], .finish);
            read += part.consumed;
            written += part.produced;
            if (part.status == .complete) break;
            try std.testing.expect(part.consumed + part.produced > 0);
        }
        try std.testing.expectEqual(input.len, read);
        const decoded = try test_decoding.decode.into(
            output[0..written],
            restored,
            .{ .workspace = decoder, .history = history },
            .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
        );
        try std.testing.expectEqual(input.len, decoded.produced);
        try std.testing.expectEqualSlices(u8, input, restored);
    }
}

test "sparse shortcut preserves work overflow and reset behavior" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    const bytes = [_]u8{
        232, 131, 200, 214, 52, 246, 4, 0, 0, 117, 183, 123, 191, 180, 100, 18, 50,
    };
    var output: [128]u8 = undefined;
    try encoder.reset(workspace, .{ .compression = .{ .strategy = .huffman_only } });
    encoder.stats.work_units = std.math.maxInt(u64) - @as(u64, bytes.len);
    try std.testing.expectError(error.LimitExceeded, encoder.step(&bytes, &output, .finish));
    try std.testing.expectEqual(
        std.math.maxInt(u64) - @as(u64, bytes.len),
        encoder.stats.work_units,
    );
    try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
    try encoder.reset(workspace, .{ .compression = .{ .strategy = .huffman_only } });
    encoder.stats.work_units = std.math.maxInt(u64) - @as(u64, bytes.len) - 1;
    const result = try encoder.step(&bytes, &output, .finish);
    try std.testing.expectEqual(Status.complete, result.status);
    try std.testing.expectEqual(std.math.maxInt(u64), encoder.stats.work_units);
}

test "final blocks survive fragmented input and output with retained history" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const input = try allocator.alloc(u8, 65537);
    defer allocator.free(input);
    for (input, 0..) |*byte, i| byte.* = @truncate((i *% 73 +% i / 11) ^ (i / 17));
    const capacity = try encodeBound(input.len);
    const expected = try allocator.alloc(u8, capacity);
    defer allocator.free(expected);
    const actual = try allocator.alloc(u8, capacity);
    defer allocator.free(actual);
    const dictionary = "retained history across a compressed stream boundary";
    const profiles = [_]Compression{
        .{ .level = 0 },
        .{ .level = 1 },
        .{ .level = 6 },
        .{ .level = 9 },
        .{ .strategy = .four_byte_runs },
    };
    for (profiles) |compression| {
        for ([_]usize{ 256, 32768 }) |window| {
            var encoder: Encoder = undefined;
            const options: EncodeOptions = .{
                .dictionary = dictionary,
                .window_bytes = window,
                .compression = compression,
            };
            try encoder.reset(workspace, options);
            const whole = try encoder.step(input, expected, .finish);
            try std.testing.expectEqual(Status.complete, whole.status);
            try std.testing.expectEqual(input.len, whole.consumed);
            const expected_counts = encoder.counts();
            try encoder.reset(workspace, options);
            var read: usize = 0;
            var written: usize = 0;
            while (true) {
                const end = @min(input.len, read + 4093);
                const out_end = @min(actual.len, written + 7);
                const action: Action = if (end == input.len) .finish else .process;
                const progress = try encoder.step(
                    input[read..end],
                    actual[written..out_end],
                    action,
                );
                read += progress.consumed;
                written += progress.produced;
                if (progress.status == .complete) break;
                try std.testing.expect(progress.consumed + progress.produced != 0);
            }
            try std.testing.expectEqual(input.len, read);
            try std.testing.expectEqualSlices(u8, expected[0..whole.produced], actual[0..written]);
            try std.testing.expectEqualDeep(expected_counts, encoder.counts());
        }
    }
}

test "encoder retires byte fragments retains dictionaries and distinguishes flush actions" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try test_encoding.Workspace.create(allocator);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try test_decoding.decode.Workspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    const source =
        "shared history words shared history words!shared history words shared history words!";
    const dictionary = "a dictionary of shared history words ";
    var history: [32768]u8 = undefined;
    var encoder: test_encoding.StreamEncoder = undefined;
    var wire: [512]u8 = undefined;
    var output: [source.len]u8 = undefined;
    inline for (.{ test_encoding.Action.flush, test_encoding.Action.full_flush }) |flush| {
        inline for (
            [_]test_encoding.Compression{
                .{ .level = 0 },
                .{ .strategy = .huffman_only },
                .{ .level = 3 },
                .{ .level = 6 },
                .{ .level = 4, .lazy_lookahead = .reduced },
                .{ .level = 5, .lazy_lookahead = .reduced },
                .{ .level = 6, .lazy_lookahead = .reduced },
                .{ .level = 9 },
                .{ .level = 7, .offline_pricing = .reduced },
                .{ .level = 8, .offline_pricing = .reduced },
                .{ .level = 9, .offline_pricing = .reduced },
                .{ .level = 7, .offline_pricing = .maximum_lengths },
                .{ .level = 8, .offline_pricing = .maximum_lengths },
                .{ .level = 9, .offline_pricing = .maximum_lengths },
                .{ .level = 7, .offline_refinement = .early },
                .{ .level = 8, .offline_pricing = .reduced, .offline_refinement = .early },
                .{ .level = 9, .offline_pricing = .maximum_lengths, .offline_refinement = .early },
            },
        ) |compression| {
            try encoder.reset(encoder_workspace, .{ .compression = compression });
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
                const action: test_encoding.Action = blk: {
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
            const recovered = try test_decoding.decode.into(
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
    const encoder_workspace = try test_encoding.Workspace.create(allocator);
    defer encoder_workspace.destroy(allocator);
    var encoder: test_encoding.StreamEncoder = undefined;
    var wire: [128]u8 = @splat(0xa5);
    try std.testing.expectError(error.CounterOverflow, test_encoding.bound(std.math.maxInt(usize)));
    try std.testing.expectError(
        error.InvalidOptions,
        encoder.reset(encoder_workspace, .{ .window_bytes = 1000 }),
    );
    try encoder.reset(encoder_workspace, .{ .limits = .{ .input_bytes = 2 } });
    try std.testing.expectError(error.LimitExceeded, encoder.step("abc", &wire, .finish));
    try std.testing.expectError(error.NeedReset, encoder.step("", &wire, .finish));
    try encoder.reset(encoder_workspace, .{ .limits = .{ .work_units = 0 } });
    try std.testing.expectError(error.LimitExceeded, encoder.step("abcabc", &wire, .finish));
    try encoder.reset(
        encoder_workspace,
        .{ .compression = .{ .level = 0 }, .limits = .{ .output_bytes = 6 } },
    );
    try std.testing.expectEqual(.complete, (try encoder.step("A", wire[1..7], .finish)).status);
    try std.testing.expectEqual(0xa5, wire[0]);
    try std.testing.expectEqual(0xa5, wire[7]);
    try encoder.reset(
        encoder_workspace,
        .{ .compression = .{ .level = 0 }, .limits = .{ .output_bytes = 5 } },
    );
    try std.testing.expectError(error.LimitExceeded, encoder.step("A", &wire, .finish));
    try encoder.reset(encoder_workspace, .{});
    try std.testing.expectError(error.StorageOverlap, encoder.step(wire[0..3], &wire, .finish));
    try encoder.reset(encoder_workspace, .{});
    try std.testing.expectEqual(.need_input, (try encoder.step("abc", &.{}, .process)).status);
    try std.testing.expectError(error.InvalidState, encoder.setDictionary("dictionary"));
    encoder_workspace.clear();
    for (std.mem.asBytes(encoder_workspace)) |byte| try std.testing.expectEqual(0, byte);
}
