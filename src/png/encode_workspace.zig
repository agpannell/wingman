//! Shared native encoder reservation and streaming bridge.

const std = @import("std");
const zlib = @import("../zlib.zig");

/// Native encoder reservation backed by caller storage or an allocation. Copies share the same
/// state and must not be used concurrently. Release an allocated reservation with its allocator.
pub const Workspace = WorkspaceImpl(zlib.Encoder, zlib.EncoderWorkspace);
pub const FourByteRunWorkspace = WorkspaceImpl(
    zlib.FourByteRunEncoder,
    zlib.FourByteRunEncoderWorkspace,
);

fn WorkspaceImpl(comptime EncoderType: type, comptime WorkspaceType: type) type {
    return struct {
        const Self = @This();
        const State = struct { encoder: EncoderType, workspace: WorkspaceType, output: [4096]u8 };

        /// Complete backing span, borrowed or allocated by initCapacity. Release only an allocated
        /// reservation through deinit.
        allocation: []u8,
        /// Opaque native state at its final address, shared by copies; do not replace or modify it.
        state: *align(@alignOf(State)) anyopaque,
        /// Extra scratch bytes reserved after native state; contents are unspecified. Keep this
        /// view unchanged while passing the workspace to an encoder.
        extra: []u8,

        /// Byte-aligned request for the native state and its worst-case alignment padding.
        pub const minimum_bytes = @sizeOf(State) + @alignOf(State) - 1;
        /// Reservation overflow or exhaustion of caller storage.
        pub const Error = std.mem.Allocator.Error || error{ SizeOverflow, WorkspaceTooSmall };

        /// Complete single-span request for encoding and extra scratch, without allocation.
        pub fn byteCount(extra_bytes: usize) error{SizeOverflow}!usize {
            return std.math.add(usize, minimum_bytes, extra_bytes) catch error.SizeOverflow;
        }

        /// Adopts caller storage without allocating or changing its contents. Keep backing at its
        /// final address and disjoint from source/output through every use. The reported byteCount
        /// capacity is required, including worst-case alignment. Release borrowed backing yourself;
        /// deinit is only for reservations obtained from initCapacity.
        pub fn initBuffer(backing: []u8, extra_bytes: usize) Error!Self {
            const required = try byteCount(extra_bytes);
            if (backing.len < required) return error.WorkspaceTooSmall;
            const address = std.mem.alignForward(usize, @intFromPtr(backing.ptr), @alignOf(State));
            const offset = address - @intFromPtr(backing.ptr);
            return .{
                .allocation = backing[0..required],
                .state = @ptrCast(@alignCast(backing[offset..].ptr)),
                .extra = backing[offset + @sizeOf(State) ..][0..extra_bytes],
            };
        }

        /// Allocates one complete final-address reservation. No allocator is retained; release it
        /// with this allocator after the last use.
        pub fn initCapacity(allocator: std.mem.Allocator, extra_bytes: usize) Error!Self {
            const allocation = try allocator.alloc(u8, try byteCount(extra_bytes));
            return initBuffer(allocation, extra_bytes) catch unreachable;
        }

        /// Releases an initCapacity reservation with its creating allocator after all uses end.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.allocation);
            self.* = undefined;
        }

        test "PNG encoding storage preserves caller prefixes with one aligned reservation" {
            const allocator = std.testing.allocator;
            const alignment = @alignOf(State);
            const backing = try allocator.alignedAlloc(
                u8,
                .fromByteUnits(alignment),
                minimum_bytes + 4096 + alignment + 32,
            );
            defer allocator.free(backing);
            for (0..alignment) |residue| {
                for ([_]usize{ 0, 1, 31, 4096 }) |extra_bytes| {
                    @memset(backing, 0xa5);
                    var fixed = std.heap.FixedBufferAllocator.init(backing[8 .. backing.len - 8]);
                    const prefix = 16 + residue;
                    @memset(try fixed.allocator().alloc(u8, prefix), 0x3c);
                    var tracked = std.testing.FailingAllocator.init(fixed.allocator(), .{});
                    var storage = try initCapacity(tracked.allocator(), extra_bytes);
                    try std.testing.expectEqual(1, tracked.alloc_index);
                    try std.testing.expectEqual(0, @intFromPtr(storage.state) % alignment);
                    try std.testing.expectEqual(extra_bytes, storage.extra.len);
                    if (extra_bytes != 0) try std.testing.expectEqual(
                        @intFromPtr(storage.state) + @sizeOf(State),
                        @intFromPtr(storage.extra.ptr),
                    );
                    try std.testing.expectEqual(prefix + storage.allocation.len, fixed.end_index);
                    @memset(storage.extra, 0x6d);
                    for (
                        fixed.buffer[fixed.end_index..],
                    ) |byte| try std.testing.expectEqual(0xa5, byte);
                    storage.deinit(tracked.allocator());
                    try std.testing.expectEqual(prefix, fixed.end_index);
                    for (fixed.buffer[0..prefix]) |byte| try std.testing.expectEqual(0x3c, byte);
                    for (backing[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
                    for (
                        backing[backing.len - 8 ..],
                    ) |byte| try std.testing.expectEqual(0xa5, byte);
                }
            }
        }

        test "PNG encoding storage refuses overflow and exhaustion before publication" {
            try std.testing.expectError(
                error.SizeOverflow,
                initCapacity(std.testing.failing_allocator, std.math.maxInt(usize)),
            );
            try std.testing.expectError(
                error.OutOfMemory,
                initCapacity(std.testing.failing_allocator, 0),
            );
        }

        test initBuffer {
            const required = try byteCount(17);
            const backing = try std.testing.allocator.alloc(u8, required + 2);
            defer std.testing.allocator.free(backing);
            @memset(backing, 0xa5);
            const storage = try initBuffer(backing[1 .. backing.len - 1], 17);
            try std.testing.expectEqual(17, storage.extra.len);
            try std.testing.expectEqual(0, @intFromPtr(storage.state) % @alignOf(State));
            try std.testing.expectError(
                error.WorkspaceTooSmall,
                initBuffer(backing[1..required], 17),
            );
            for (backing) |byte| try std.testing.expectEqual(0xa5, byte);
        }
    };
}

/// Native codec refusal or failure to deliver compressed bytes to the Writer.
pub const WriteError = zlib.EncodeError || std.Io.Writer.Error;

fn nativeState(storage: anytype) *@TypeOf(storage).State {
    return @ptrCast(storage.state);
}

/// Starts a fresh zlib stream, abandoning any previous one without writing output.
pub fn beginStream(self: anytype, compression: zlib.Compression) zlib.EncodeError!void {
    const state = nativeState(self);
    try state.encoder.reset(&state.workspace, .{ .deflate = .{ .compression = compression } });
}

/// Consumes the supplied input and drains available wire bytes to output without allocation. The
/// input and Writer are borrowed only for this call.
pub fn writeStream(self: anytype, output: *std.Io.Writer, source: []const u8) WriteError!void {
    const state = nativeState(self);
    var consumed: usize = 0;
    while (true) {
        const progress = try state.encoder.step(source[consumed..], &state.output, .process);
        try output.writeAll(state.output[0..progress.produced]);
        consumed += progress.consumed;
        if (progress.status == .need_input) return;
    }
}

/// Internal filtered-row destination. Fill only the prefix committed next, without another stream
/// operation while the slice is borrowed. Framing and pending output use ordinary writeStream.
pub fn inputBuffer(self: anytype) ?[]u8 {
    return nativeState(self).encoder.inputBuffer();
}

pub fn commitInput(self: anytype, output: *std.Io.Writer, length: usize) WriteError!void {
    const state = nativeState(self);
    var progress = try state.encoder.commitInput(length, &state.output);
    while (true) {
        try output.writeAll(state.output[0..progress.produced]);
        if (progress.status == .need_input) return;
        progress = try state.encoder.step(&.{}, &state.output, .process);
    }
}

/// Uses the first half of the existing output staging buffer for short filtered rows.
pub fn rowBatchBuffer(self: anytype) []u8 {
    return nativeState(self).output[0..2048];
}

pub fn writeRowBatch(self: anytype, output: *std.Io.Writer, length: usize) WriteError!void {
    const state = nativeState(self);
    std.debug.assert(length <= 2048);
    var consumed: usize = 0;
    while (true) {
        // Short-row batches share the out-of-line framing and checksum dispatch.
        const progress = try @call(
            .never_inline,
            @TypeOf(state.encoder).step,
            .{ &state.encoder, state.output[consumed..length], state.output[2048..], .process },
        );
        try output.writeAll(state.output[2048..][0..progress.produced]);
        consumed += progress.consumed;
        if (progress.status == .need_input) return;
    }
}

// Packed Up rows leave extra unused. The fields holding live compressor state must both end before
// the output array; any bytes after that array can only be tail padding or row extra.
fn wideRowLayout(comptime Storage: type) bool {
    const State = Storage.State;
    const output_offset = @offsetOf(State, "output");
    return @typeInfo(
        State,
    ).@"struct".field_names.len == 3 and @offsetOf(
        State,
        "encoder",
    ) + @sizeOf(
        @TypeOf(@as(State, undefined).encoder),
    ) <= output_offset and @offsetOf(
        State,
        "workspace",
    ) + @sizeOf(@TypeOf(@as(State, undefined).workspace)) <= output_offset;
}

fn wideRowStorage(self: anytype) ?[]u8 {
    if (!wideRowLayout(@TypeOf(self))) return null;
    const state = nativeState(self);
    const offset = @intFromPtr(&state.output) - @intFromPtr(self.allocation.ptr);
    std.debug.assert(offset + state.output.len <= self.allocation.len);
    const backing = self.allocation[offset..];
    if (backing.len < 4224) return null;
    return backing[0..4224];
}

pub fn wideRowBatchBuffer(self: anytype) ?[]u8 {
    const backing = wideRowStorage(self) orelse return null;
    return backing[0..4160];
}

pub fn writeWideRowBatch(self: anytype, output: *std.Io.Writer, length: usize) WriteError!void {
    const state = nativeState(self);
    const backing = wideRowStorage(self).?;
    std.debug.assert(length <= 4160);
    const staged = backing[4160..4224];
    var consumed: usize = 0;
    while (true) {
        const progress = try @call(
            .never_inline,
            @TypeOf(state.encoder).step,
            .{ &state.encoder, backing[consumed..length], staged, .process },
        );
        try output.writeAll(staged[0..progress.produced]);
        consumed += progress.consumed;
        if (progress.status == .need_input) return;
    }
}

/// Completes the zlib stream and writes its Adler-32 trailer. Flush the Writer separately.
pub fn finishStream(self: anytype, output: *std.Io.Writer) WriteError!void {
    const state = nativeState(self);
    while (true) {
        const progress = try state.encoder.step(&.{}, &state.output, .finish);
        try output.writeAll(state.output[0..progress.produced]);
        if (progress.status == .complete) return;
    }
}

test "wide row staging never overwrites native state or reservation guards" {
    const allocator = std.testing.allocator;
    const extra_bytes = 3 * 129;
    inline for (.{ Workspace, FourByteRunWorkspace }) |Storage| {
        const required = try Storage.byteCount(extra_bytes);
        const backing = try allocator.alloc(u8, required + 34);
        defer allocator.free(backing);
        for (1..33) |offset| {
            @memset(backing, 0xa5);
            const storage = try Storage.initBuffer(backing[offset..][0..required], extra_bytes);
            const batch = wideRowBatchBuffer(storage) orelse rowBatchBuffer(storage);
            if (wideRowLayout(
                Storage,
            )) try std.testing.expectEqual(
                @as(usize, 4160),
                batch.len,
            ) else try std.testing.expectEqual(@as(usize, 2048), batch.len);
            if (wideRowStorage(storage)) |wide| @memset(wide, 0x3c) else @memset(batch, 0x3c);
            const state = nativeState(storage);
            for (
                std.mem.asBytes(&state.encoder),
            ) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
            for (
                std.mem.asBytes(&state.workspace),
            ) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
            for (backing[0..offset]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
            for (
                backing[offset + required ..],
            ) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        }
    }
}

test "row staging drains disjoint output and matches streaming zlib" {
    inline for (.{ Workspace, FourByteRunWorkspace }) |Storage| try testRowStaging(Storage);
}

fn testRowStaging(comptime Storage: type) !void {
    const allocator = std.testing.allocator;
    var staged = try Storage.initCapacity(allocator, 3 * 129);
    defer staged.deinit(allocator);
    var reference = try Workspace.initCapacity(allocator, 3 * 129);
    defer reference.deinit(allocator);
    var source: [4128]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index * 73 + index / 17);
    const compression: zlib.Compression = .{ .strategy = .four_byte_runs };
    var expected_buffer: [8192]u8 = undefined;
    var expected: std.Io.Writer = .fixed(&expected_buffer);
    try beginStream(reference, compression);
    try writeStream(reference, &expected, &source);
    try finishStream(reference, &expected);
    const expected_counts = nativeState(reference).encoder.counts();
    if (wideRowBatchBuffer(staged)) |batch| {
        var short_buffer: [1]u8 = undefined;
        var short: std.Io.Writer = .fixed(&short_buffer);
        try beginStream(staged, compression);
        @memcpy(batch[0..source.len], &source);
        try std.testing.expectError(
            error.WriteFailed,
            writeWideRowBatch(staged, &short, source.len),
        );
    }
    for ([_]bool{ false, true }) |want_wide| {
        var guarded: [8224]u8 = @splat(0xa5);
        var output: std.Io.Writer = .fixed(guarded[16..8208]);
        try beginStream(staged, compression);
        const batch = if (want_wide) wideRowBatchBuffer(
            staged,
        ) orelse rowBatchBuffer(staged) else rowBatchBuffer(staged);
        var position: usize = 0;
        while (position < source.len) {
            const count = @min(batch.len, source.len - position);
            @memcpy(batch[0..count], source[position..][0..count]);
            if (batch.len == 4160) try writeWideRowBatch(
                staged,
                &output,
                count,
            ) else try writeRowBatch(staged, &output, count);
            position += count;
        }
        try finishStream(staged, &output);
        try std.testing.expectEqualDeep(expected_counts, nativeState(staged).encoder.counts());
        try std.testing.expectEqualSlices(u8, expected.buffered(), output.buffered());
        for (guarded[0..16]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        for (guarded[8208..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    }
}

test "wide row staging repeatedly drains a full deflate block" {
    inline for (.{ Workspace, FourByteRunWorkspace }) |Storage| try testWideRowDrain(Storage);
}

fn testWideRowDrain(comptime Storage: type) !void {
    const allocator = std.testing.allocator;
    var staged = try Storage.initCapacity(allocator, 3 * 129);
    defer staged.deinit(allocator);
    var reference = try Workspace.initCapacity(allocator, 3 * 129);
    defer reference.deinit(allocator);
    const batch = wideRowBatchBuffer(staged) orelse return error.SkipZigTest;
    const prefix = try allocator.alloc(u8, 65500);
    defer allocator.free(prefix);
    var random: std.Random.DefaultPrng = .init(0x7a53);
    random.random().bytes(prefix);
    var tail: [4128]u8 = undefined;
    random.random().bytes(&tail);
    const expected_buffer = try allocator.alloc(u8, 80000);
    defer allocator.free(expected_buffer);
    const guarded = try allocator.alloc(u8, 80032);
    defer allocator.free(guarded);
    @memset(guarded, 0xa5);
    const compression: zlib.Compression = .{ .strategy = .four_byte_runs };
    var expected: std.Io.Writer = .fixed(expected_buffer);
    try beginStream(reference, compression);
    try writeStream(reference, &expected, prefix);
    try writeStream(reference, &expected, &tail);
    try finishStream(reference, &expected);
    const expected_counts = nativeState(reference).encoder.counts();
    var output: std.Io.Writer = .fixed(guarded[16..80016]);
    try beginStream(staged, compression);
    try writeStream(staged, &output, prefix);
    @memcpy(batch[0..tail.len], &tail);
    try writeWideRowBatch(staged, &output, tail.len);
    try std.testing.expect(output.buffered().len > 64);
    try finishStream(staged, &output);
    try std.testing.expectEqualDeep(expected_counts, nativeState(staged).encoder.counts());
    try std.testing.expectEqualSlices(u8, expected.buffered(), output.buffered());
    for (guarded[0..16]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    for (guarded[80016..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}
