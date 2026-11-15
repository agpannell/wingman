//! Resumable gzip framing over raw DEFLATE. Workspace/history/capture buffers remain exclusive
//! external borrows. The worker may move between calls, retiring the old copy and keeping those
//! reservations disjoint from its new address and all fragments. Fragments can retire immediately.
//! No allocator or transport is retained. Output remains private until its member's CRC and ISIZE
//! succeed. Each new member resets DEFLATE history, checksums, size and metadata independently.

const std = @import("std");
const Crc32IsoHdlc = @import("../crc.zig").Crc32IsoHdlc;
const format = @import("format.zig");
const deflate = @import("../deflate.zig");
const byte_ranges = @import("../common/byte_ranges.zig");
const Header = @import("Header.zig");
const Member = @import("Member.zig");
const fixtures = @import("decode_fixtures.zig");
const test_complete = @import("decode.zig"); // Used only by inline stream/container comparisons.

const signature = format.signature;
const flag_header_crc = format.flag_header_crc;
const flag_extra = format.flag_extra;
const flag_name = format.flag_name;
const flag_comment = format.flag_comment;
const reserved_flags = format.reserved_flags;

const StreamDecoder = @This();
const Workspace = deflate.decode.Workspace;
const Limits = deflate.decode.Limits;
const overlaps = byte_ranges.overlaps;
const stored = fixtures.stored;
const fixed = fixtures.fixed;
const dynamic = fixtures.dynamic;
const optional_fields = fixtures.optional_fields;
const empty = fixtures.empty;
const fixture_text = fixtures.fixture_text;
const dynamic_text = fixtures.dynamic_text;

/// Exclusive reservations retained by a resumable decoder until reset/end of use.
pub const Storage = struct {
    /// Exclusive address-stable decoding tables.
    workspace: *Workspace,
    /// Independent history, reset for each member.
    history: *[32768]u8,
    /// Null skips optional bytes while still exposing their lengths and flags.
    capture: ?Header.CaptureBuffers = null,
};

/// Streaming framing policy and independent cumulative/header limits.
pub const Options = struct {
    /// Single stops after the first verified member, preserving lookahead.
    members: Member.Selection = .single,
    /// Bounds applied to each header before optional fields are copied.
    header_limits: Header.Limits = .{},
    /// Limits for the entire selected stream, including all members/framing.
    limits: Limits = .{},
};

/// Streaming resource or verified member/container boundary.
pub const Status = enum {
    /// Supply more encoded input, preserving any unconsumed suffix.
    need_input,
    /// Supply output capacity and resubmit any unconsumed input.
    need_output,
    /// A member's CRC-32 and size are verified; call `StreamDecoder.nextMember` to continue
    /// iteration.
    member_end,
    /// The selected member policy has finished successfully.
    complete,
};

/// Copied byte counts relative to the supplied fragments.
pub const Progress = struct {
    /// Accepted bytes, excluding lookahead following the selected policy.
    consumed: usize,
    /// Restored bytes in the caller's output.
    produced: usize,
    /// Resource or validated boundary reached.
    status: Status,
};

/// Failed step/nextMember calls poison the decoder until reset.
pub const Error = error{
    InvalidStream,
    LimitExceeded,
    StorageOverlap,
    HeaderTooLong,
    Truncated,
    NeedReset,
    InvalidState,
    CounterOverflow,
};

pub const Input = deflate.decode.StreamDecoder.Input;

/// Cumulative byte accounting and the number of fully verified members.
pub const Counts = struct {
    /// Accepted encoded bytes across all selected members.
    input_bytes: u64,
    /// Restored bytes across all selected members.
    output_bytes: u64,
    /// Members whose CRC-32 and size trailers have passed validation.
    members: u64,
};

const Phase = enum {
    fixed_header,
    extra_size,
    extra,
    name,
    comment,
    header_crc,
    body,
    footer,
    member_end,
    between,
    complete,
};

/// Raw payload state borrowing the external tables and independent member history.
raw: deflate.decode.StreamDecoder,
/// Copied member selection and cumulative/header admission policy.
options: Options,
/// Exclusive external tables, history and optional capture spans.
storage: Storage,
/// Framing operation or member boundary to resume.
phase: Phase = .fixed_header,
/// Bounded partial fixed header, extra-field length, header CRC or trailer bytes.
field: [10]u8 = undefined,
/// Initialized prefix of field for the current framing operation.
field_bytes: usize = 0,
/// Accepted bytes in this member header, including its optional CRC.
header_bytes: usize = 0,
/// Current header facts; views refer to external capture spans.
metadata: Header = undefined,
/// The complete header has passed admission and any requested CRC check.
header_ready: bool = false,
/// Extra-field bytes already consumed or captured for the current member.
extra_done: usize = 0,
/// CRC-32 over header bytes preceding the optional header CRC.
header_checksum: Crc32IsoHdlc = Crc32IsoHdlc.init(),
/// CRC-32 over restored payload bytes for this member.
checksum: Crc32IsoHdlc = Crc32IsoHdlc.init(),
/// A failed operation requires reset before further work.
failed: bool = false,
/// Final input was accepted; output or explicit member iteration can still drain.
eof: bool = false,

/// Remaining combined accepted-input and restored-output allowance.
work_left: u64,

/// Accepted bytes across all selected members.
input_bytes: u64 = 0,
/// Restored bytes across all selected members.
output_bytes: u64 = 0,
/// Number of members whose trailers have passed validation.
members: u64 = 0,

/// Starts fresh state without clearing reservations. Capture buffers must remain stable until the
/// next reset or end of use. Invalid reservations are refused before setup; setup must succeed
/// before any other method.
pub fn reset(self: *StreamDecoder, storage: Storage, options: Options) error{StorageOverlap}!void {
    const workspace = storage.workspace;
    const history = storage.history;
    const reservations = [_][]const u8{
        std.mem.asBytes(self),
        std.mem.asBytes(workspace),
        history,
    };
    inline for (reservations, 0..) |a, i| {
        inline for (reservations[i + 1 ..]) |b| {
            if (overlaps(a, b)) return error.StorageOverlap;
        }
    }
    if (storage.capture) |capture| {
        const buffers = [_][]u8{ capture.extra, capture.name, capture.comment };
        inline for (buffers, 0..) |a, i| {
            inline for (reservations) |b| {
                if (overlaps(a, b)) return error.StorageOverlap;
            }
            inline for (buffers[i + 1 ..]) |b| {
                if (overlaps(a, b)) return error.StorageOverlap;
            }
        }
    }
    self.* = .{
        .raw = undefined,
        .options = options,
        .storage = storage,
        .work_left = options.limits.work_units,
    };
    self.raw.reset(
        .{ .workspace = workspace, .history = history },
        .{ .limits = .{} },
    ) catch |failure| switch (failure) {
        // The default full window is valid and no dictionary is requested.
        error.InvalidOptions => unreachable,
        error.StorageOverlap => return error.StorageOverlap,
    };
}

/// Returns cumulative byte accounting and fully verified member count. A failed step publishes no
/// accepted progress; these observations do not validate provisional output.
pub fn counts(self: *const StreamDecoder) Counts {
    return .{
        .input_bytes = self.input_bytes,
        .output_bytes = self.output_bytes,
        .members = self.members,
    };
}

/// Copied metadata with explicit borrowed views, available once the header is admitted and until
/// the next member starts/reset. Capture bytes can be overwritten by the next member; copy them
/// first if they must outlive it.
pub fn header(self: *const StreamDecoder) ?Header {
    return if (!self.failed and self.header_ready) self.metadata else null;
}

/// Starts looking for another member after an iterate-policy member_end. The following step returns
/// complete on EOF, or parses the next header.
pub fn nextMember(self: *StreamDecoder) error{ NeedReset, InvalidState }!void {
    if (self.failed) {
        @branchHint(.unlikely);
        return error.NeedReset;
    }
    if (self.phase != .member_end) {
        self.failed = true;
        return error.InvalidState;
    }
    self.phase = .between;
}

/// Advances through arbitrary fragments. Concatenate aggregates until EOF; iterate stops at each
/// member_end until nextMember. Empty output permits headers, empty members and trailers. Failure
/// requires reset.
pub fn step(self: *StreamDecoder, input: Input, output: []u8) Error!Progress {
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

fn admit(self: *StreamDecoder, source: []const u8, output: []u8) error{StorageOverlap}!void {
    if (overlaps(source, output)) return error.StorageOverlap;
    const reservations = .{
        std.mem.asBytes(self),
        std.mem.asBytes(self.storage.workspace),
        @as([]u8, self.storage.history),
    };
    inline for (reservations) |reservation| {
        if (overlaps(source, reservation)) return error.StorageOverlap;
        if (overlaps(output, reservation)) return error.StorageOverlap;
    }
    if (self.storage.capture) |capture| {
        inline for (.{ capture.extra, capture.name, capture.comment }) |buffer| {
            if (overlaps(source, buffer)) return error.StorageOverlap;
            if (overlaps(output, buffer)) return error.StorageOverlap;
        }
    }
}

fn advance(self: *StreamDecoder, supplied_input: Input, supplied_output: []u8) Error!Progress {
    try self.admit(supplied_input.bytes, supplied_output);
    const input_left = self.options.limits.input_bytes -| self.input_bytes;
    const output_left = self.options.limits.output_bytes -| self.output_bytes;
    const admitted_input: usize = @intCast(
        @min(supplied_input.bytes.len, input_left, self.work_left),
    );
    const admitted_output: usize = @intCast(@min(supplied_output.len, output_left, self.work_left));
    const input: Input = .{
        .bytes = supplied_input.bytes[0..admitted_input],
        .final = supplied_input.final and admitted_input == supplied_input.bytes.len,
    };
    const output = supplied_output[0..admitted_output];
    const finished = self.phase == .complete or self.phase == .member_end;
    if (self.eof and supplied_input.bytes.len != 0 and !finished) return error.InvalidState;

    var consumed: usize = 0;
    var produced: usize = 0;
    const status: Status = parse: while (true) switch (self.phase) {
        .fixed_header, .extra_size, .header_crc, .footer => {
            const needed: usize = switch (self.phase) {
                .fixed_header => 10,
                .footer => 8,
                else => 2,
            };
            const count = @min(needed - self.field_bytes, input.bytes.len - consumed);
            const header_left = self.options.header_limits.header_bytes -| self.header_bytes;
            if (self.phase != .footer and needed - self.field_bytes > header_left)
                return error.HeaderTooLong;
            if (count > self.work_left - consumed - produced) return error.LimitExceeded;
            const bytes = input.bytes[consumed..][0..count];
            if (self.phase != .footer) try self.countHeader(bytes, self.phase != .header_crc);
            @memcpy(self.field[self.field_bytes..][0..count], bytes);
            consumed += count;
            self.field_bytes += count;
            if (self.field_bytes != needed) break :parse .need_input;
            self.field_bytes = 0;
            switch (self.phase) {
                .fixed_header => {
                    const prefix = self.field[0..3];
                    if (!std.mem.eql(u8, prefix, &signature)) return error.InvalidStream;
                    if (self.field[3] & reserved_flags != 0) return error.InvalidStream;
                    self.metadata = .{
                        .flags = self.field[3],
                        .modification_time = std.mem.readInt(u32, self.field[4..8], .little),
                        .extra_flags = self.field[8],
                        .operating_system = self.field[9],
                    };
                    const extra_present = self.metadata.flags & flag_extra != 0;
                    self.phase = if (extra_present) .extra_size else .name;
                },
                .extra_size => {
                    const length = std.mem.readInt(u16, self.field[0..2], .little);
                    const field_limit = self.options.header_limits.field_bytes;
                    const header_limit = self.options.header_limits.header_bytes;
                    const header_remaining = header_limit -| self.header_bytes;
                    if (length > field_limit or length > header_remaining)
                        return error.HeaderTooLong;
                    if (self.storage.capture) |capture| {
                        if (length > capture.extra.len) return error.HeaderTooLong;
                        self.metadata.extra = capture.extra[0..length];
                    }
                    self.metadata.extra_length = length;
                    self.phase = .extra;
                },
                .header_crc => {
                    const expected = std.mem.readInt(u16, self.field[0..2], .little);
                    const checksum: u16 = @truncate(self.header_checksum.final());
                    if (expected != checksum) return error.InvalidStream;
                    self.header_ready = true;
                    self.phase = .body;
                },
                .footer => {
                    const expected_crc = std.mem.readInt(u32, self.field[0..4], .little);
                    if (expected_crc != self.checksum.final()) return error.InvalidStream;
                    const expected_size = std.mem.readInt(u32, self.field[4..8], .little);
                    const restored_size: u32 = @truncate(self.raw.counts().output_bytes);
                    if (expected_size != restored_size) return error.InvalidStream;
                    self.members = std.math.add(
                        u64,
                        self.members,
                        1,
                    ) catch return error.CounterOverflow;
                    self.phase = switch (self.options.members) {
                        .single => .complete,
                        .iterate => .member_end,
                        .concatenate => .between,
                    };
                },
                else => unreachable,
            }
        },
        .extra => {
            const count = @min(
                self.metadata.extra_length - self.extra_done,
                input.bytes.len - consumed,
            );
            if (count > self.work_left - consumed - produced) return error.LimitExceeded;
            const bytes = input.bytes[consumed..][0..count];
            try self.countHeader(bytes, true);
            if (self.storage.capture) |capture| {
                @memcpy(capture.extra[self.extra_done..][0..count], bytes);
            }
            consumed += count;
            self.extra_done += count;
            if (self.extra_done != self.metadata.extra_length) break :parse .need_input;
            self.phase = .name;
        },
        .name, .comment => {
            const is_name = self.phase == .name;
            const flag: u8 = if (is_name) flag_name else flag_comment;
            if (self.metadata.flags & flag == 0) {
                self.afterText(is_name);
                continue;
            }
            const current = blk: {
                if (is_name) break :blk self.metadata.name_length;
                break :blk self.metadata.comment_length;
            };
            const remaining = self.options.header_limits.field_bytes - current;
            const available = input.bytes[consumed..];
            const header_limit = self.options.header_limits.header_bytes;
            const header_remaining = header_limit -| self.header_bytes;
            const bounded = available[0..@min(available.len, remaining +| 1, header_remaining)];
            const end = std.mem.indexOfScalar(u8, bounded, 0);
            const count = end orelse bounded.len;
            if (count > remaining or (end == null and bounded.len == header_remaining))
                return error.HeaderTooLong;
            const accepted = count + @intFromBool(end != null);
            if (accepted > self.work_left - consumed - produced) return error.LimitExceeded;
            try self.countHeader(bounded[0..accepted], true);
            if (self.storage.capture) |capture| {
                const buffer = if (is_name) capture.name else capture.comment;
                if (count > buffer.len -| current) return error.HeaderTooLong;
                @memcpy(buffer[current..][0..count], bounded[0..count]);
                if (is_name) {
                    self.metadata.name = buffer[0 .. current + count];
                } else {
                    self.metadata.comment = buffer[0 .. current + count];
                }
            }
            consumed += accepted;
            if (is_name) {
                self.metadata.name_length += count;
            } else {
                self.metadata.comment_length += count;
            }
            if (end == null) break :parse .need_input;
            self.afterText(is_name);
        },
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
        .member_end => break :parse .member_end,
        .between => {
            if (consumed == input.bytes.len) {
                if (input.final or self.eof) {
                    self.phase = .complete;
                    continue;
                }
                break :parse .need_input;
            }
            self.raw.reset(
                .{ .workspace = self.storage.workspace, .history = self.storage.history },
                .{ .limits = .{} },
            ) catch |failure| switch (failure) {
                // Each independent member uses the default full window without a dictionary.
                error.InvalidOptions => unreachable,
                error.StorageOverlap => return error.StorageOverlap,
            };
            self.checksum = Crc32IsoHdlc.init();
            self.header_checksum = Crc32IsoHdlc.init();
            self.header_ready = false;
            self.header_bytes = 0;
            self.extra_done = 0;
            self.phase = .fixed_header;
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
    const limits = self.options.limits;
    if (self.input_bytes > limits.input_bytes or self.output_bytes > limits.output_bytes)
        return error.LimitExceeded;
    if (work > self.work_left) return error.LimitExceeded;
    self.work_left -= work;
    return .{ .consumed = consumed, .produced = produced, .status = status };
}

fn afterText(self: *StreamDecoder, name: bool) void {
    if (name) {
        self.phase = .comment;
        return;
    }
    if (self.metadata.flags & flag_header_crc != 0) {
        self.phase = .header_crc;
    } else {
        self.header_ready = true;
        self.phase = .body;
    }
}

fn countHeader(self: *StreamDecoder, bytes: []const u8, checksum: bool) error{HeaderTooLong}!void {
    if (bytes.len > self.options.header_limits.header_bytes -| self.header_bytes)
        return error.HeaderTooLong;
    self.header_bytes += bytes.len;
    if (checksum) self.header_checksum.update(bytes);
}

test "resumable gzip retires header fragments and validates every member boundary" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const output = try allocator.alloc(u8, dynamic_text.len + 64);
    defer allocator.free(output);
    var decoder: StreamDecoder = undefined;
    var extra: [4]u8 = undefined;
    var name: [9]u8 = undefined;
    var comment: [12]u8 = undefined;
    const borrowed = try Header.parse(&optional_fields, .{});
    try std.testing.expectEqualStrings("glyph.svg", borrowed.header.name.?);
    try std.testing.expectEqualStrings("font comment", borrowed.header.comment.?);
    try std.testing.expectEqual(@as(u32, 123456), borrowed.header.modification_time);
    for ([_][]const u8{ &stored, &fixed, &dynamic, &optional_fields, &empty }) |wire| {
        const expected = try allocator.alloc(u8, output.len);
        defer allocator.free(expected);
        const whole = try test_complete.into(wire, expected, .{ .workspace = workspace }, .{});
        for (0..wire.len + 1) |split| {
            try decoder.reset(
                .{
                    .workspace = workspace,
                    .history = history,
                    .capture = .{ .extra = &extra, .name = &name, .comment = &comment },
                },
                .{},
            );
            var step_result = try decoder.step(.{ .bytes = wire[0..split] }, output[0..0]);
            var consumed = step_result.consumed;
            var produced = step_result.produced;
            while (step_result.status != .complete) {
                step_result = try decoder.step(
                    .{ .bytes = wire[consumed..], .final = true },
                    output[produced..][0..@min(7, output.len - produced)],
                );
                consumed += step_result.consumed;
                produced += step_result.produced;
            }
            try std.testing.expectEqual(wire.len, consumed);
            try std.testing.expectEqualSlices(u8, expected[0..whole.produced], output[0..produced]);
            const metadata = decoder.header().?;
            const parsed = try Header.parse(wire, .{});
            try std.testing.expectEqual(parsed.header.flags, metadata.flags);
            try std.testing.expectEqualSlices(u8, parsed.header.extra, metadata.extra);
            if (parsed.header.name) |text| {
                try std.testing.expectEqualStrings(text, metadata.name.?);
            }
            if (parsed.header.comment) |text| {
                try std.testing.expectEqualStrings(text, metadata.comment.?);
            }
        }
        for (0..wire.len) |end| {
            try decoder.reset(.{ .workspace = workspace, .history = history }, .{});
            try std.testing.expectError(
                error.Truncated,
                decoder.step(.{ .bytes = wire[0..end], .final = true }, output),
            );
            try std.testing.expectError(error.NeedReset, decoder.step(.{ .bytes = wire }, output));
        }
    }
    const combined = stored ++ empty ++ fixed;
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{ .members = .iterate });
    var consumed: usize = 0;
    var produced: usize = 0;
    for ([_]usize{ stored.len, empty.len, fixed.len }) |length| {
        const result = try decoder.step(
            .{ .bytes = combined[consumed..], .final = true },
            output[produced..],
        );
        try std.testing.expectEqual(Status.member_end, result.status);
        try std.testing.expectEqual(length, result.consumed);
        consumed += result.consumed;
        produced += result.produced;
        const stalled = try decoder.step(.{ .bytes = combined[consumed..], .final = true }, &.{});
        try std.testing.expectEqual(
            Progress{ .consumed = 0, .produced = 0, .status = .member_end },
            stalled,
        );
        try decoder.nextMember();
    }
    const done = try decoder.step(.{ .bytes = &.{}, .final = false }, &.{});
    try std.testing.expectEqual(Status.complete, done.status);
    try std.testing.expectEqual(@as(u64, 3), decoder.members);
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .members = .concatenate },
    );
    const aggregate = try decoder.step(.{ .bytes = &combined, .final = true }, output);
    try std.testing.expectEqual(Status.complete, aggregate.status);
    try std.testing.expectEqual(combined.len, aggregate.consumed);
    try std.testing.expectEqualStrings("SVG" ++ fixture_text, output[0..aggregate.produced]);
}

test "gzip bounded metadata checksum failure and independent member history" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var decoder: StreamDecoder = undefined;
    var output: [256]u8 = undefined;
    try std.testing.expectError(
        error.HeaderTooLong,
        Header.parse(&optional_fields, .{ .field_bytes = 8 }),
    );
    try std.testing.expectError(
        error.HeaderTooLong,
        Header.parse(&optional_fields, .{ .header_bytes = 20 }),
    );
    try decoder.reset(.{ .workspace = workspace, .history = history, .capture = .{} }, .{});
    try std.testing.expectError(
        error.HeaderTooLong,
        decoder.step(.{ .bytes = &optional_fields }, &output),
    );
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .header_limits = .{ .header_bytes = 20 } },
    );
    try std.testing.expectError(
        error.HeaderTooLong,
        decoder.step(.{ .bytes = &optional_fields }, &output),
    );
    for ([_]usize{ optional_fields.len - 8, optional_fields.len - 4, 39 }) |corrupt| {
        var wire = optional_fields;
        wire[corrupt] ^= 1;
        try decoder.reset(.{ .workspace = workspace, .history = history }, .{});
        try std.testing.expectError(
            error.InvalidStream,
            decoder.step(.{ .bytes = &wire, .final = true }, &output),
        );
    }
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .members = .concatenate },
    );
    try std.testing.expectError(
        error.InvalidStream,
        decoder.step(.{ .bytes = stored ++ "garbage garbage", .final = true }, &output),
    );
    // A member cannot reach preceding member history. Fixed length 3/distance 1 is invalid at the
    // start of this second member, regardless of its footer.
    const invalid = blk: {
        const fixed_header = stored[0..10].*;
        const tokens = [_]u8{ 0x03, 0x02, 0x00 };
        const footer: [8]u8 = @splat(0);
        break :blk stored ++ fixed_header ++ tokens ++ footer;
    };
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .members = .concatenate },
    );
    try std.testing.expectError(
        error.InvalidStream,
        decoder.step(.{ .bytes = &invalid, .final = true }, &output),
    );
    try decoder.reset(.{ .workspace = workspace, .history = history }, .{});
    const reused = try decoder.step(.{ .bytes = &stored, .final = true }, &output);
    try std.testing.expectEqualStrings("SVG", output[0..reused.produced]);
}

test "gzip work limits include aggregated headers and trailers" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const wire = stored ++ empty ++ stored;
    var decoder: StreamDecoder = undefined;
    var output: [16]u8 = undefined;
    for (0..wire.len + 6) |work| {
        try decoder.reset(
            .{ .workspace = workspace, .history = history },
            .{ .members = .concatenate, .limits = .{ .work_units = work } },
        );
        try std.testing.expectError(
            error.LimitExceeded,
            decoder.step(.{ .bytes = &wire, .final = true }, &output),
        );
    }
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{
            .members = .concatenate,
            .limits = .{ .work_units = wire.len + 6, .output_bytes = 6, .input_bytes = wire.len },
        },
    );
    const result = try decoder.step(.{ .bytes = &wire, .final = true }, &output);
    try std.testing.expectEqual(Status.complete, result.status);
    try std.testing.expectEqual(@as(u64, 0), decoder.work_left);
    try std.testing.expectEqualStrings("SVGSVG", output[0..result.produced]);
}

test "gzip total header limits bound scans even with unlimited text fields" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var decoder: StreamDecoder = undefined;
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .header_limits = .{ .header_bytes = 10, .field_bytes = std.math.maxInt(usize) } },
    );
    // An admitted fixed header declares a name. No following byte can fit, so no unbounded field
    // scan or transport read is needed to refuse it.
    const header_bytes = [_]u8{ 31, 139, 8, 8, 0, 0, 0, 0, 0, 255 };
    try std.testing.expectError(
        error.HeaderTooLong,
        decoder.step(.{ .bytes = &header_bytes }, &.{}),
    );
}

test "gzip decoder transfers partial headers and captured metadata between calls" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const original = try allocator.create(StreamDecoder);
    defer allocator.destroy(original);
    const transferred = try allocator.create(StreamDecoder);
    defer allocator.destroy(transferred);
    var extra: [4]u8 = undefined;
    var name: [9]u8 = undefined;
    var comment: [12]u8 = undefined;
    var output: [fixture_text.len + 8]u8 = undefined;
    const wire = optional_fields ++ "next";
    // Transfer both an unfinished name capture and fully admitted metadata with pending output.
    for ([_]usize{ 21, optional_fields.len }) |cut| {
        @memset(&output, 0xa5);
        try original.reset(
            .{
                .workspace = workspace,
                .history = history,
                .capture = .{ .extra = &extra, .name = &name, .comment = &comment },
            },
            .{},
        );
        const first = try original.step(.{ .bytes = wire[0..cut] }, output[0..1]);
        try std.testing.expect(first.status != .complete);
        transferred.* = original.*;
        @memset(std.mem.asBytes(original), 0xa5);
        var consumed = first.consumed;
        var produced = first.produced;
        while (true) {
            const progress = try transferred.step(
                .{ .bytes = wire[consumed..], .final = true },
                output[produced..],
            );
            consumed += progress.consumed;
            produced += progress.produced;
            if (progress.status == .complete) break;
            try std.testing.expect(progress.consumed != 0 or progress.produced != 0);
        }
        try std.testing.expectEqual(optional_fields.len, consumed);
        try std.testing.expectEqual(fixture_text.len, produced);
        try std.testing.expectEqualStrings(fixture_text, output[0..produced]);
        for (output[produced..]) |byte| try std.testing.expectEqual(0xa5, byte);
        const metadata = transferred.header().?;
        try std.testing.expectEqual(extra[0..].ptr, metadata.extra.ptr);
        try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc, 0xdd }, metadata.extra);
        try std.testing.expectEqual(name[0..].ptr, metadata.name.?.ptr);
        try std.testing.expectEqualStrings("glyph.svg", metadata.name.?);
        try std.testing.expectEqual(comment[0..].ptr, metadata.comment.?.ptr);
        try std.testing.expectEqualStrings("font comment", metadata.comment.?);
        try std.testing.expectEqual(@as(u64, 1), transferred.counts().members);
        try std.testing.expectEqualStrings("next", wire[consumed..]);
    }
}
