//! gzip headers, verified member decoding and fragmented decoding.

const std = @import("std");
const crc32 = @import("../crc32.zig");
const deflate = @import("../deflate.zig");
const overlaps = @import("../common/byte_ranges.zig").overlaps;
const format = @import("format.zig");
const signature = format.signature;
const flag_text = format.flag_text;
const flag_header_crc = format.flag_header_crc;
const flag_extra = format.flag_extra;
const flag_name = format.flag_name;
const flag_comment = format.flag_comment;
const reserved_flags = format.reserved_flags;

pub const Error = deflate.Error;
pub const Input = deflate.Input;
pub const DecodeLimits = deflate.DecodeLimits;
/// Complete selected-member counts. Byte counts exclude trailing application data.
pub const DecodeResult = struct {
    /// Encoded bytes occupied by the verified selected members.
    consumed: usize,
    /// Restored destination prefix; its remaining suffix is unchanged.
    produced: usize,
    /// Number of fully verified members.
    members: usize = 1,
};
pub const DecoderWorkspace = deflate.DecoderWorkspace;

/// Required mutable tables for complete decoding. No separate history is needed.
pub const DecodeStorage = struct {
    /// Exclusive address-stable decoding tables, reusable after success or failure.
    workspace: *DecoderWorkspace,
};
pub const OutputSize = deflate.OutputSize;
pub const TrailingData = deflate.TrailingData;

/// Complete-member selection and admission. Default header admission preserves the complete
/// decoder's unbounded optional fields; callers can select finite HeaderLimits explicitly.
pub const DecodeOptions = struct {
    /// Single/iterate decode one member; use MemberIterator for complete-input metadata iteration.
    members: MemberPolicy = .single,
    /// Exact requires the complete destination extent after all selected members.
    output_size: OutputSize = .bounded,
    /// Reject requires the selected members to consume all supplied source.
    trailing_data: TrailingData = .allow,
    /// Bounds each member header independently.
    header_limits: HeaderLimits = .{
        .field_bytes = std.math.maxInt(usize),
        .header_bytes = std.math.maxInt(usize),
    },
    /// Cumulative selected-member input/output/work admission, including framing.
    limits: DecodeLimits = .{},
};

/// Decodes and verifies the selected gzip members without allocation. Counts include verified
/// framing; unused output is preserved. Concatenation requires the entire supplied source to
/// consist of members, rejecting trailing garbage. Source, output and workspace must be disjoint.
/// Errors publish no counts and may change output and scratch.
pub fn decode(
    source: []const u8,
    output: []u8,
    storage: DecodeStorage,
    options: DecodeOptions,
) HeaderError!DecodeResult {
    const limits = options.limits;
    const state = std.mem.asBytes(storage.workspace);
    if (overlaps(source, output)) return error.StorageOverlap;
    if (overlaps(source, state)) return error.StorageOverlap;
    if (overlaps(output, state)) return error.StorageOverlap;
    const admitted: usize = @intCast(@min(source.len, limits.input_bytes, limits.work_units));
    const bytes = source[0..admitted];
    // A single member can use exact-output kernels. Admit both whole spans first so an early extent
    // refusal cannot change resource-error priority; concatenated prefixes remain bounded.
    const exact_output_limit = @min(limits.output_bytes, limits.work_units - admitted);
    const exact_member = options.members != .concatenate and options.output_size == .exact and
        admitted == source.len and output.len <= exact_output_limit;
    var result: DecodeResult = .{ .consumed = 0, .produced = 0, .members = 0 };
    while (true) {
        const member = decodeMember(
            bytes[result.consumed..],
            output[result.produced..],
            storage.workspace,
            .{
                .header_limits = options.header_limits,
                .output_size = if (exact_member) .exact else .bounded,
                .limits = .{
                    .output_bytes = limits.output_bytes -| result.produced,
                    .work_units = limits.work_units -| result.consumed -| result.produced,
                },
            },
        ) catch |err| switch (err) {
            error.InvalidStream => {
                if (admitted < source.len) return error.LimitExceeded;
                return err;
            },
            else => return err,
        };
        result.consumed += member.consumed;
        result.produced += member.produced;
        result.members += 1;
        if (result.consumed > limits.work_units or result.produced > limits.work_units - result
            .consumed) return error.LimitExceeded;
        if (options.members != .concatenate or result.consumed == source.len) break;
        if (result.consumed == bytes.len) return error.LimitExceeded;
    }
    if (options.output_size == .exact and result.produced != output.len) return error.InvalidStream;
    if (options.trailing_data == .reject and result.consumed != source.len)
        return error.InvalidStream;
    return result;
}

fn decodeMember(
    source: []const u8,
    output: []u8,
    workspace: *DecoderWorkspace,
    options: DecodeOptions,
) HeaderError!DecodeResult {
    const header = try parseHeader(source, options.header_limits);
    const raw = deflate.decode(
        source[header.consumed..],
        output,
        .{ .workspace = workspace },
        .{ .output_size = options.output_size, .limits = options.limits },
    ) catch |err| switch (err) {
        error.InvalidStream => return error.InvalidStream,
        error.InvalidOptions => return error.InvalidOptions,
        error.OutputTooSmall => return error.OutputTooSmall,
        error.StorageOverlap => return error.StorageOverlap,
        error.LimitExceeded => return error.LimitExceeded,
        // No dictionary is selected, so the direct complete-buffer path cannot produce stream-state
        // errors or cumulative-counter overflow.
        else => unreachable,
    };
    const footer = header.consumed + raw.consumed;
    if (source.len - footer < 8) return error.InvalidStream;
    const expected_crc = std.mem.readInt(u32, source[footer..][0..4], .little);
    if (expected_crc != crc32.hash(output[0..raw.produced])) return error.InvalidStream;
    const expected_size = std.mem.readInt(u32, source[footer + 4 ..][0..4], .little);
    const restored_size: u32 = @truncate(raw.produced);
    if (expected_size != restored_size) return error.InvalidStream;
    return .{ .consumed = footer + 8, .produced = raw.produced };
}

test decode {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);

    // One stored "hello" member followed by application data outside the member.
    const source = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xff, 0x01, 0x05, 0x00, 0xfa, 0xff, 0x68,
        0x65, 0x6c, 0x6c, 0x6f, 0x86, 0xa6, 0x10, 0x36,
        0x05, 0x00, 0x00, 0x00, 0x6e, 0x65, 0x78, 0x74,
    };
    var output: [32]u8 = undefined;
    const result = try decode(&source, &output, .{ .workspace = workspace }, .{});
    const member = .{ .text = output[0..result.produced], .next = source[result.consumed..] };

    try std.testing.expectEqualStrings("hello", member.text);
    try std.testing.expectEqualStrings("next", member.next);
}

/// Bounds for optional fields, excluding their terminating NUL, and the entire header including its
/// fixed portion and CRC. Bounds never authorize storage.
pub const HeaderLimits = struct {
    /// Maximum bytes in each extra, name or comment field.
    field_bytes: usize = 65535,
    /// Maximum total header bytes.
    header_bytes: usize = 262144,
};

/// Parsed header facts. Whole-buffer parsing borrows optional fields from the source. Streaming
/// parsing borrows caller capture buffers, or leaves views empty/null when capture is disabled;
/// lengths and flags remain available. Names/comments are uninterpreted bytes, never paths or UTF-8
/// assumptions.
pub const Header = struct {
    /// RFC flags, including presence bits for optional fields.
    flags: u8,
    /// Unix timestamp in seconds; zero means the header provides no timestamp.
    modification_time: u32,
    /// Compressor's extra flags.
    extra_flags: u8,
    /// Operating-system identifier as an uninterpreted byte.
    operating_system: u8,
    /// Borrowed extra-field bytes, empty when uncaptured or absent.
    extra: []const u8 = &.{},
    /// Borrowed name without NUL; null when uncaptured or absent.
    name: ?[]const u8 = null,
    /// Borrowed comment without NUL; null when uncaptured or absent.
    comment: ?[]const u8 = null,
    /// Full extra-field length, even when uncaptured.
    extra_length: usize = 0,
    /// Full name length, excluding NUL, even when uncaptured.
    name_length: usize = 0,
    /// Full comment length, excluding NUL, even when uncaptured.
    comment_length: usize = 0,
};

/// Header admission or caller capture capacity failure.
pub const HeaderError = Error || error{HeaderTooLong};

/// Parsed borrowed header and its exact byte boundary within supplied source.
pub const HeaderResult = struct { header: Header, consumed: usize };

/// Parses a bounded complete header without decoding payload. Returned views borrow source until it
/// retires. Reserved flags, wrong methods and FHCRC mismatch reject; optional fields cannot scan
/// beyond the configured bounds.
pub fn parseHeader(source: []const u8, limits: HeaderLimits) HeaderError!HeaderResult {
    if (source.len < 10) return error.InvalidStream;
    if (!std.mem.eql(u8, source[0..3], &signature)) return error.InvalidStream;
    if (source[3] & reserved_flags != 0) return error.InvalidStream;
    var header: Header = .{
        .flags = source[3],
        .modification_time = std.mem.readInt(u32, source[4..8], .little),
        .extra_flags = source[8],
        .operating_system = source[9],
    };
    var position: usize = 10;
    if (position > limits.header_bytes) return error.HeaderTooLong;
    if (header.flags & flag_extra != 0) {
        if (source.len - position < 2) return error.InvalidStream;
        const size = std.mem.readInt(u16, source[position..][0..2], .little);
        position += 2;
        if (size > limits.field_bytes or position > limits.header_bytes) return error.HeaderTooLong;
        if (size > limits.header_bytes - position) return error.HeaderTooLong;
        if (size > source.len - position) return error.InvalidStream;
        header.extra = source[position..][0..size];
        header.extra_length = size;
        position += size;
    }
    inline for (.{ "name", "comment" }, .{ flag_name, flag_comment }) |field, flag| {
        if (header.flags & flag != 0) {
            const available = @min(source.len - position, limits.header_bytes - position);
            const admitted = @min(available, limits.field_bytes +| 1);
            const length = std.mem.indexOfScalar(u8, source[position..][0..admitted], 0) orelse {
                if (available < source.len - position) return error.HeaderTooLong;
                if (admitted < available or admitted > limits.field_bytes)
                    return error.HeaderTooLong;
                return error.InvalidStream;
            };
            @field(header, field) = source[position..][0..length];
            @field(header, field ++ "_length") = length;
            position += length + 1;
        }
    }
    if (header.flags & flag_header_crc != 0) {
        if (limits.header_bytes - position < 2) return error.HeaderTooLong;
        if (source.len - position < 2) return error.InvalidStream;
        const expected: u16 = @truncate(crc32.hash(source[0..position]));
        const recorded = std.mem.readInt(u16, source[position..][0..2], .little);
        if (recorded != expected) return error.InvalidStream;
        position += 2;
    }
    return .{ .header = header, .consumed = position };
}

/// A verified member result whose metadata borrows the iterator's source.
pub const Member = struct {
    /// Borrowed header metadata for this member.
    header: Header,
    /// Byte counts relative to the member and supplied output.
    result: DecodeResult,
};

/// Iterates complete-buffer members. Set `source` to the complete encoded input and leave
/// `position` at zero. `next` advances only after full validation, returns null at the exact source
/// end, and rejects trailing garbage. Output/workspace can be reused between calls.
pub const MemberIterator = struct {
    /// Source borrow retained by this iterator and returned header views.
    source: []const u8,
    /// Next member offset; initialized to zero.
    position: usize = 0,
    /// Admission limits applied independently to each member header.
    header_limits: HeaderLimits = .{},

    /// Decodes the next member into caller storage, without allocation.
    pub fn next(
        self: *MemberIterator,
        output: []u8,
        workspace: *DecoderWorkspace,
    ) HeaderError!?Member {
        if (overlaps(std.mem.asBytes(self), self.source)) return error.StorageOverlap;
        if (overlaps(std.mem.asBytes(self), output)) return error.StorageOverlap;
        if (overlaps(
            std.mem.asBytes(self),
            std.mem.asBytes(workspace),
        )) return error.StorageOverlap;
        if (self.position == self.source.len) return null;
        if (self.position > self.source.len) return error.InvalidStream;
        const source = self.source[self.position..];
        const parsed = try parseHeader(source, self.header_limits);
        const result = try decode(source, output, .{ .workspace = workspace }, .{});
        self.position += result.consumed;
        return .{ .header = parsed.header, .result = result };
    }
};

/// Caller-owned bounded copies for fragmented headers. Enable capture by supplying all desired
/// field capacities; an admitted field must fit in its corresponding buffer. The three spans stay
/// exclusively borrowed until reset or end of use, and must be disjoint from every other
/// reservation/fragment.
pub const HeaderBuffers = struct {
    /// Capacity for the complete extra field.
    extra: []u8 = &.{},
    /// Capacity for the complete name, excluding NUL.
    name: []u8 = &.{},
    /// Capacity for the complete comment, excluding NUL.
    comment: []u8 = &.{},
};

/// Selection of first-member completion, explicit iteration, or automatic aggregation.
/// Concatenation requires EOF and refuses trailing garbage.
pub const MemberPolicy = enum {
    /// Finish after one verified member, leaving following input unconsumed.
    single,
    /// Return `DecodeStatus.member_end` after each member; call `Decoder.nextMember` to continue.
    iterate,
    /// Decode all members until explicit EOF, rejecting trailing garbage.
    concatenate,
};

/// Exclusive reservations retained by a resumable decoder until reset/end of use.
pub const StreamStorage = struct {
    /// Exclusive address-stable decoding tables.
    workspace: *DecoderWorkspace,
    /// Independent history, reset for each member.
    history: *[32768]u8,
    /// Null skips optional bytes while still exposing their lengths and flags.
    capture: ?HeaderBuffers = null,
};

/// Streaming framing policy and independent cumulative/header limits.
pub const StreamDecodeOptions = struct {
    /// Single stops after the first verified member, preserving lookahead.
    members: MemberPolicy = .single,
    /// Bounds applied to each header before optional fields are copied.
    header_limits: HeaderLimits = .{},
    /// DecodeLimits for the entire selected stream, including all members/framing.
    limits: DecodeLimits = .{},
};

/// Streaming resource or verified member/container boundary.
pub const DecodeStatus = enum {
    /// Supply more encoded input, preserving any unconsumed suffix.
    need_input,
    /// Supply output capacity and resubmit any unconsumed input.
    need_output,
    /// A member's CRC-32 and size are verified; call `Decoder.nextMember` to continue iteration.
    member_end,
    /// The selected member policy has finished successfully.
    complete,
};

/// Copied byte counts relative to the supplied fragments.
pub const DecodeProgress = struct {
    /// Accepted bytes, excluding lookahead following the selected policy.
    consumed: usize,
    /// Restored bytes in the caller's output.
    produced: usize,
    /// Resource or validated boundary reached.
    status: DecodeStatus,
};

/// Any stream failure poisons the decoder until reset.
pub const DecodeError = deflate.DecodeError || error{HeaderTooLong};

/// Resumable gzip framing over raw DEFLATE. Call reset at its final address;
/// workspace/history/capture buffers remain exclusive borrows. Fragments can retire immediately. No
/// allocator or transport is retained. Output remains private until its member's CRC and ISIZE
/// succeed. Each new member resets DEFLATE history, checksums, size and metadata independently.
pub const Decoder = struct {
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

    raw: deflate.Decoder,
    options: StreamDecodeOptions,
    capture: ?HeaderBuffers,
    phase: Phase = .fixed_header,
    field: [10]u8 = undefined,
    field_bytes: usize = 0,
    header_bytes: usize = 0,
    metadata: Header = undefined,
    header_ready: bool = false,
    extra_done: usize = 0,
    header_checksum: crc32.Hasher = .init,
    checksum: crc32.Hasher = .init,
    failed: bool = false,
    eof: bool = false,

    work_left: u64,

    /// Accepted bytes across all selected members.
    input_bytes: u64 = 0,
    /// Restored bytes across all selected members.
    output_bytes: u64 = 0,
    /// Number of members whose trailers have passed validation.
    members: u64 = 0,

    /// Starts fresh state without clearing reservations. Capture buffers must remain stable until
    /// the next reset or end of use. Invalid reservations are refused before setup; setup must
    /// succeed before any other method.
    pub fn reset(
        self: *Decoder,
        storage: StreamStorage,
        options: StreamDecodeOptions,
    ) DecodeError!void {
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
            .capture = storage.capture,
            .work_left = options.limits.work_units,
        };
        try self.raw.reset(.{ .workspace = workspace, .history = history }, .{ .limits = .{} });
    }

    /// Copied metadata with explicit borrowed views, available once the header is admitted and
    /// until the next member starts/reset. Capture bytes can be overwritten by the next member;
    /// copy them first if they must outlive it.
    pub fn header(self: *const Decoder) ?Header {
        return if (!self.failed and self.header_ready) self.metadata else null;
    }

    /// Starts looking for another member after an iterate-policy member_end. The following step
    /// returns complete on EOF, or parses the next header.
    pub fn nextMember(self: *Decoder) DecodeError!void {
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

    /// Advances through arbitrary fragments. Concatenate aggregates until EOF; iterate stops at
    /// each member_end until nextMember. Empty output permits headers, empty members and trailers.
    /// Failure requires reset.
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

    fn admit(self: *Decoder, source: []const u8, output: []u8) DecodeError!void {
        if (overlaps(source, output)) return error.StorageOverlap;
        const reservations = .{
            std.mem.asBytes(self),
            std.mem.asBytes(self.raw.workspace),
            @as([]u8, self.raw.history),
        };
        inline for (reservations) |reservation| {
            if (overlaps(source, reservation)) return error.StorageOverlap;
            if (overlaps(output, reservation)) return error.StorageOverlap;
        }
        if (self.capture) |capture| {
            inline for (.{ capture.extra, capture.name, capture.comment }) |buffer| {
                if (overlaps(source, buffer)) return error.StorageOverlap;
                if (overlaps(output, buffer)) return error.StorageOverlap;
            }
        }
    }

    fn advance(
        self: *Decoder,
        supplied_input: Input,
        supplied_output: []u8,
    ) DecodeError!DecodeProgress {
        try self.admit(supplied_input.bytes, supplied_output);
        const input_left = self.options.limits.input_bytes -| self.input_bytes;
        const output_left = self.options.limits.output_bytes -| self.output_bytes;
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
        const finished = self.phase == .complete or self.phase == .member_end;
        if (self.eof and supplied_input.bytes.len != 0 and !finished) return error.InvalidState;

        var consumed: usize = 0;
        var produced: usize = 0;
        const status: DecodeStatus = parse: while (true) switch (self.phase) {
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
                        if (self.capture) |capture| {
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
                        const restored_size: u32 = @truncate(self.raw.output_bytes);
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
                if (self.capture) |capture| {
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
                if (self.capture) |capture| {
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
            .member_end => break :parse .member_end,
            .between => {
                if (consumed == input.bytes.len) {
                    if (input.final or self.eof) {
                        self.phase = .complete;
                        continue;
                    }
                    break :parse .need_input;
                }
                try self.raw.reset(
                    .{ .workspace = self.raw.workspace, .history = self.raw.history },
                    .{ .limits = .{} },
                );
                self.checksum = .init;
                self.header_checksum = .init;
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

    fn afterText(self: *Decoder, name: bool) void {
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

    fn countHeader(self: *Decoder, bytes: []const u8, checksum: bool) DecodeError!void {
        if (bytes.len > self.options.header_limits.header_bytes -| self.header_bytes)
            return error.HeaderTooLong;
        self.header_bytes += bytes.len;
        if (checksum) self.header_checksum.update(bytes);
    }
};

// Independent Python gzip/zlib 1.3.2 wire bytes; expected data does not use this decoder.
const stored = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x01, 0x03, 0x00, 0xfc, 0xff, 0x53,
    0x56, 0x47, 0x1a, 0x67, 0xe2, 0x95, 0x03, 0x00, 0x00, 0x00,
};

const fixed = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xb3, 0x29, 0x2e, 0x4b, 0x57, 0xa8,
    0xc8, 0xcd, 0xc9, 0x2b, 0xb6, 0x55, 0xca, 0x28, 0x29, 0x29, 0xb0, 0xd2, 0xd7, 0x2f, 0x2f, 0x2f,
    0xd7, 0x2b, 0x37, 0xd6, 0xcb, 0x2f, 0x4a, 0xd7, 0x37, 0x32, 0x30, 0x30, 0xd0, 0x07, 0xaa, 0x50,
    0xb2, 0xb3, 0x49, 0x57, 0xc8, 0x4c, 0xb1, 0x55, 0x4a, 0xcf, 0xa9, 0x2c, 0xc8, 0x30, 0x07, 0x72,
    0x0b, 0x12, 0x4b, 0x32, 0x14, 0xd2, 0x32, 0x73, 0x72, 0x6c, 0x95, 0x92, 0x4b, 0x8b, 0x8a, 0x52,
    0xf3, 0x4a, 0x9c, 0xf3, 0x73, 0xf2, 0x8b, 0x94, 0x14, 0x80, 0x8a, 0x7c, 0x0d, 0x14, 0x0c, 0x3c,
    0x0c, 0x0d, 0x0c, 0xc2, 0x74, 0x81, 0x44, 0x94, 0x92, 0xbe, 0x9d, 0x8d, 0x7e, 0x3a, 0x10, 0x03,
    0xcd, 0xb1, 0x03, 0x00, 0x77, 0xc4, 0x0a, 0x5a, 0x6f, 0x00, 0x00, 0x00,
};

const dynamic = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xed, 0xc4, 0xb1, 0x09, 0x00, 0x20,
    0x0c, 0x00, 0xb0, 0x5b, 0x2b, 0x8a, 0x0e, 0x16, 0x1c, 0xfc, 0x1f, 0xaf, 0x28, 0x2e, 0x19, 0x92,
    0xd8, 0x67, 0x45, 0x48, 0x92, 0x24, 0x49, 0x92, 0x24, 0x49, 0xaa, 0xac, 0x8d, 0x0b, 0x00, 0x00,
    0x00, 0x7c, 0x36, 0x23, 0x53, 0x92, 0x24, 0x49, 0x92, 0x24, 0x49, 0x52, 0x6d, 0x7d, 0xec, 0x2b,
    0x49, 0x92, 0x24, 0x49, 0x92, 0x24, 0xa9, 0xb6, 0x07, 0x11, 0xe0, 0xe9, 0x86, 0x38, 0x4a, 0x00,
    0x00,
};

const optional_fields = [_]u8{
    0x1f, 0x8b, 0x08, 0x1f, 0x40, 0xe2, 0x01, 0x00, 0x02, 0xff, 0x04, 0x00, 0xaa, 0xbb, 0xcc, 0xdd,
    0x67, 0x6c, 0x79, 0x70, 0x68, 0x2e, 0x73, 0x76, 0x67, 0x00, 0x66, 0x6f, 0x6e, 0x74, 0x20, 0x63,
    0x6f, 0x6d, 0x6d, 0x65, 0x6e, 0x74, 0x00, 0xab, 0xb8, 0xb3, 0x29, 0x2e, 0x4b, 0x57, 0xa8, 0xc8,
    0xcd, 0xc9, 0x2b, 0xb6, 0x55, 0xca, 0x28, 0x29, 0x29, 0xb0, 0xd2, 0xd7, 0x2f, 0x2f, 0x2f, 0xd7,
    0x2b, 0x37, 0xd6, 0xcb, 0x2f, 0x4a, 0xd7, 0x37, 0x32, 0x30, 0x30, 0xd0, 0x07, 0xaa, 0x50, 0xb2,
    0xb3, 0x49, 0x57, 0xc8, 0x4c, 0xb1, 0x55, 0x4a, 0xcf, 0xa9, 0x2c, 0xc8, 0x30, 0x07, 0x72, 0x0b,
    0x12, 0x4b, 0x32, 0x14, 0xd2, 0x32, 0x73, 0x72, 0x6c, 0x95, 0x92, 0x4b, 0x8b, 0x8a, 0x52, 0xf3,
    0x4a, 0x9c, 0xf3, 0x73, 0xf2, 0x8b, 0x94, 0x14, 0x80, 0x8a, 0x7c, 0x0d, 0x14, 0x0c, 0x3c, 0x0c,
    0x0d, 0x0c, 0xc2, 0x74, 0x81, 0x44, 0x94, 0x92, 0xbe, 0x9d, 0x8d, 0x7e, 0x3a, 0x10, 0x03, 0xcd,
    0xb1, 0x03, 0x00, 0x77, 0xc4, 0x0a, 0x5a, 0x6f, 0x00, 0x00, 0x00,
};

const empty = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
};

const fixture_text =
    "<svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"glyph7\"><path fill=\"currentColor\" " ++
    "d=\"M0 0H100V-100Z\"/></g></svg>";

const dynamic_text = blk: {
    const alpha: [1000][5]u8 = @splat(.{ 'a', 'l', 'p', 'h', 'a' });
    const beta: [1000][4]u8 = @splat(.{ 'b', 'e', 't', 'a' });
    const gamma: [1000][5]u8 = @splat(.{ 'g', 'a', 'm', 'm', 'a' });
    const delta: [1000][5]u8 = @splat(.{ 'd', 'e', 'l', 't', 'a' });
    const alpha_bytes: [5000]u8 = @bitCast(alpha);
    const beta_bytes: [4000]u8 = @bitCast(beta);
    const gamma_bytes: [5000]u8 = @bitCast(gamma);
    const delta_bytes: [5000]u8 = @bitCast(delta);
    break :blk alpha_bytes ++ beta_bytes ++ gamma_bytes ++ delta_bytes;
};

test "gzip members retain exact stored fixed dynamic empty and trailing boundaries" {
    const workspace = try DecoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    const output = try std.testing.allocator.alloc(u8, dynamic_text.len + 16);
    defer std.testing.allocator.free(output);
    const cases = [_]struct {
        source: []const u8,
        expected: []const u8,
    }{
        .{ .source = &stored, .expected = "SVG" },
        .{ .source = &fixed, .expected = fixture_text },
        .{ .source = &dynamic, .expected = &dynamic_text },
        .{ .source = &empty, .expected = "" },
    };
    for (cases) |fixture| {
        @memset(output, 0xa5);
        const result = try decode(fixture.source, output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(fixture.source.len, result.consumed);
        try std.testing.expectEqual(fixture.expected.len, result.produced);
        try std.testing.expectEqualSlices(u8, fixture.expected, output[0..result.produced]);
        for (output[result.produced..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
    const combined = stored ++ fixed ++ "trailing";
    const first = try decode(combined, output, .{ .workspace = workspace }, .{});
    const second = try decode(
        combined[first.consumed..],
        output[first.produced..],
        .{ .workspace = workspace },
        .{},
    );
    try std.testing.expectEqual(stored.len, first.consumed);
    try std.testing.expectEqual(fixed.len, second.consumed);
    try std.testing.expectEqualSlices(
        u8,
        "SVG" ++ fixture_text,
        output[0 .. first.produced + second.produced],
    );
    try std.testing.expectEqual(
        0,
        (try decode(&empty, output[0..0], .{ .workspace = workspace }, .{})).produced,
    );
}

test "gzip optional fields header checksum and malformed framing have bounded refusals" {
    const workspace = try DecoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var output: [256]u8 = @splat(0xa5);
    const result = try decode(&optional_fields, &output, .{ .workspace = workspace }, .{});
    try std.testing.expectEqual(optional_fields.len, result.consumed);
    try std.testing.expectEqualSlices(u8, fixture_text, output[0..result.produced]);
    for (0..optional_fields.len) |size| {
        try std.testing.expectError(
            error.InvalidStream,
            decode(optional_fields[0..size], &output, .{ .workspace = workspace }, .{}),
        );
    }
    for ([_]usize{ 0, 1, 2, 37, optional_fields.len - 8, optional_fields.len - 4 }) |position| {
        var malformed = optional_fields;
        malformed[position] ^= 0x40;
        try std.testing.expectError(
            error.InvalidStream,
            decode(&malformed, &output, .{ .workspace = workspace }, .{}),
        );
    }
    for ([_]u8{ 0x20, 0x40, 0x80 }) |flag| {
        var malformed = stored;
        malformed[3] |= flag;
        @memset(&output, 0xa5);
        try std.testing.expectError(
            error.InvalidStream,
            decode(&malformed, &output, .{ .workspace = workspace }, .{}),
        );
        for (output) |byte| try std.testing.expectEqual(0xa5, byte);
    }
    try std.testing.expectError(
        error.OutputTooSmall,
        decode(&fixed, output[0 .. fixture_text.len - 1], .{ .workspace = workspace }, .{}),
    );
    try std.testing.expectEqual(
        fixed.len,
        (try decode(&fixed, &output, .{ .workspace = workspace }, .{})).consumed,
    );
}

test "gzip overlap admission preserves caller storage and workspace before decode" {
    const workspace = try DecoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var source = fixed;
    const original = source;
    try std.testing.expectError(
        error.StorageOverlap,
        decode(&source, source[10..], .{ .workspace = workspace }, .{}),
    );
    try std.testing.expectEqualSlices(u8, &original, &source);
    const state = std.mem.asBytes(workspace);
    @memcpy(state[0..fixed.len], &fixed);
    var output: [256]u8 = @splat(0xa5);
    try std.testing.expectError(
        error.StorageOverlap,
        decode(state[0..fixed.len], &output, .{ .workspace = workspace }, .{}),
    );
    for (output) |byte| try std.testing.expectEqual(0xa5, byte);
    try std.testing.expectError(
        error.StorageOverlap,
        decode(&fixed, state, .{ .workspace = workspace }, .{}),
    );
    try std.testing.expectEqualSlices(u8, &fixed, state[0..fixed.len]);
}

test "resumable gzip retires header fragments and validates every member boundary" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const output = try allocator.alloc(u8, dynamic_text.len + 64);
    defer allocator.free(output);
    var decoder: Decoder = undefined;
    var extra: [4]u8 = undefined;
    var name: [9]u8 = undefined;
    var comment: [12]u8 = undefined;
    const borrowed = try parseHeader(&optional_fields, .{});
    try std.testing.expectEqualStrings("glyph.svg", borrowed.header.name.?);
    try std.testing.expectEqualStrings("font comment", borrowed.header.comment.?);
    try std.testing.expectEqual(@as(u32, 123456), borrowed.header.modification_time);
    for ([_][]const u8{ &stored, &fixed, &dynamic, &optional_fields, &empty }) |wire| {
        const expected = try allocator.alloc(u8, output.len);
        defer allocator.free(expected);
        const whole = try decode(wire, expected, .{ .workspace = workspace }, .{});
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
            const parsed = try parseHeader(wire, .{});
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
        try std.testing.expectEqual(DecodeStatus.member_end, result.status);
        try std.testing.expectEqual(length, result.consumed);
        consumed += result.consumed;
        produced += result.produced;
        const stalled = try decoder.step(.{ .bytes = combined[consumed..], .final = true }, &.{});
        try std.testing.expectEqual(
            DecodeProgress{ .consumed = 0, .produced = 0, .status = .member_end },
            stalled,
        );
        try decoder.nextMember();
    }
    const done = try decoder.step(.{ .bytes = &.{}, .final = false }, &.{});
    try std.testing.expectEqual(DecodeStatus.complete, done.status);
    try std.testing.expectEqual(@as(u64, 3), decoder.members);
    try decoder.reset(
        .{ .workspace = workspace, .history = history },
        .{ .members = .concatenate },
    );
    const aggregate = try decoder.step(.{ .bytes = &combined, .final = true }, output);
    try std.testing.expectEqual(DecodeStatus.complete, aggregate.status);
    try std.testing.expectEqual(combined.len, aggregate.consumed);
    try std.testing.expectEqualStrings("SVG" ++ fixture_text, output[0..aggregate.produced]);
    var iterator: MemberIterator = .{ .source = &combined };
    var count: usize = 0;
    while (try iterator.next(output, workspace)) |_| count += 1;
    try std.testing.expectEqual(3, count);
}

test "gzip bounded metadata checksum failure and independent member history" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var decoder: Decoder = undefined;
    var output: [256]u8 = undefined;
    try std.testing.expectError(
        error.HeaderTooLong,
        parseHeader(&optional_fields, .{ .field_bytes = 8 }),
    );
    try std.testing.expectError(
        error.HeaderTooLong,
        parseHeader(&optional_fields, .{ .header_bytes = 20 }),
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
        const header = stored[0..10].*;
        const tokens = [_]u8{ 0x03, 0x02, 0x00 };
        const footer: [8]u8 = @splat(0);
        break :blk stored ++ header ++ tokens ++ footer;
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
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const wire = stored ++ empty ++ stored;
    var decoder: Decoder = undefined;
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
    try std.testing.expectEqual(DecodeStatus.complete, result.status);
    try std.testing.expectEqual(@as(u64, 0), decoder.work_left);
    try std.testing.expectEqualStrings("SVGSVG", output[0..result.produced]);
}

test "gzip total header limits bound scans even with unlimited text fields" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    var decoder: Decoder = undefined;
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

test "complete gzip member selection extent trailing data and limits remain independent" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const buffers: DecodeStorage = .{ .workspace = workspace };
    const joined = stored ++ stored;
    var output: [8]u8 = @splat(0xa5);
    const first = try decode(&joined, output[0..3], buffers, .{ .output_size = .exact });
    try std.testing.expectEqual(@as(usize, 1), first.members);
    try std.testing.expectEqual(stored.len, first.consumed);
    try std.testing.expectEqualStrings("SVG", output[0..3]);
    try std.testing.expectError(
        error.InvalidStream,
        decode(&joined, &output, buffers, .{ .trailing_data = .reject }),
    );
    const both = try decode(&joined, &output, buffers, .{ .members = .concatenate });
    try std.testing.expectEqual(@as(usize, 2), both.members);
    try std.testing.expectEqualStrings("SVGSVG", output[0..both.produced]);
    try std.testing.expect(std.mem.allEqual(u8, output[6..], 0xa5));
    _ = try decode(
        &joined,
        output[0..6],
        buffers,
        .{
            .members = .concatenate,
            .output_size = .exact,
            .trailing_data = .reject,
            .limits = .{
                .input_bytes = joined.len,
                .output_bytes = 6,
                .work_units = joined.len + 6,
            },
        },
    );
    try std.testing.expectError(
        error.InvalidStream,
        decode(&joined, &output, buffers, .{ .members = .concatenate, .output_size = .exact }),
    );
    _ = try decode(&joined, &output, buffers, .{ .limits = .{ .input_bytes = stored.len } });
    try std.testing.expectError(
        error.LimitExceeded,
        decode(
            &joined,
            &output,
            buffers,
            .{ .members = .concatenate, .limits = .{ .input_bytes = stored.len } },
        ),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        decode(
            &joined,
            &output,
            buffers,
            .{ .members = .concatenate, .limits = .{ .output_bytes = 5 } },
        ),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        decode(
            &joined,
            &output,
            buffers,
            .{ .members = .concatenate, .limits = .{ .work_units = joined.len + 5 } },
        ),
    );
    try std.testing.expectError(
        error.HeaderTooLong,
        decode(&stored, &output, buffers, .{ .header_limits = .{ .header_bytes = 9 } }),
    );
}

test "gzip exact single-member decoding preserves complete fixtures framing and guards" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const backing = try allocator.alloc(u8, dynamic_text.len + 34);
    defer allocator.free(backing);
    const cases = [_]struct {
        source: []const u8,
        expected: []const u8,
    }{
        .{ .source = &stored, .expected = "SVG" },
        .{ .source = &fixed, .expected = fixture_text },
        .{ .source = &dynamic, .expected = &dynamic_text },
        .{ .source = &optional_fields, .expected = fixture_text },
        .{ .source = &empty, .expected = "" },
    };
    for (cases) |fixture| {
        for ([_]MemberPolicy{ .single, .iterate }) |members| {
            for (0..16) |alignment| {
                @memset(backing, 0xa5);
                const output = backing[alignment + 1 ..][0..fixture.expected.len];
                const result = try decode(
                    fixture.source,
                    output,
                    .{ .workspace = workspace },
                    .{ .members = members, .output_size = .exact, .trailing_data = .reject },
                );
                try std.testing.expectEqual(fixture.source.len, result.consumed);
                try std.testing.expectEqual(fixture.expected.len, result.produced);
                try std.testing.expectEqual(1, result.members);
                try std.testing.expectEqualSlices(u8, fixture.expected, output);
                try std.testing.expect(std.mem.allEqual(u8, backing[0 .. alignment + 1], 0xa5));
                try std.testing.expect(
                    std.mem.allEqual(u8, backing[alignment + 1 + fixture.expected.len ..], 0xa5),
                );
            }
        }
        @memset(backing, 0xa5);
        try std.testing.expectError(
            error.InvalidStream,
            decode(
                fixture.source,
                backing[1..][0 .. fixture.expected.len + 1],
                .{ .workspace = workspace },
                .{ .output_size = .exact },
            ),
        );
        if (fixture.expected.len != 0) {
            try std.testing.expectError(
                error.OutputTooSmall,
                decode(
                    fixture.source,
                    backing[1..][0 .. fixture.expected.len - 1],
                    .{ .workspace = workspace },
                    .{ .output_size = .exact },
                ),
            );
        }
        for (0..fixture.source.len) |cut| {
            try std.testing.expectError(
                error.InvalidStream,
                decode(
                    fixture.source[0..cut],
                    backing[1..][0..fixture.expected.len],
                    .{ .workspace = workspace },
                    .{ .output_size = .exact },
                ),
            );
        }
        const corrupted = try allocator.dupe(u8, fixture.source);
        defer allocator.free(corrupted);
        for ([_]usize{ fixture.source.len - 8, fixture.source.len - 4 }) |position| {
            corrupted[position] ^= 1;
            try std.testing.expectError(
                error.InvalidStream,
                decode(
                    corrupted,
                    backing[1..][0..fixture.expected.len],
                    .{ .workspace = workspace },
                    .{ .output_size = .exact },
                ),
            );
            corrupted[position] ^= 1;
        }
    }
}

test "gzip exact member extents preserve finite admission and concatenated empty members" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const backing = try allocator.alloc(u8, dynamic_text.len + 34);
    defer allocator.free(backing);
    const cases = [_]struct {
        source: []const u8,
        expected: []const u8,
    }{
        .{ .source = &stored, .expected = "SVG" },
        .{ .source = &fixed, .expected = fixture_text },
        .{ .source = &dynamic, .expected = &dynamic_text },
        .{ .source = &empty, .expected = "" },
    };
    for (cases) |fixture| {
        const storage: DecodeStorage = .{ .workspace = workspace };
        const output = backing[1..][0..fixture.expected.len];
        const work = fixture.source.len + fixture.expected.len;
        @memset(backing, 0xa5);
        const result = try decode(
            fixture.source,
            output,
            storage,
            .{
                .output_size = .exact,
                .trailing_data = .reject,
                .limits = .{
                    .input_bytes = fixture.source.len,
                    .output_bytes = output.len,
                    .work_units = work,
                },
            },
        );
        try std.testing.expectEqual(fixture.source.len, result.consumed);
        try std.testing.expectEqualSlices(u8, fixture.expected, output);
        try std.testing.expectError(
            error.LimitExceeded,
            decode(
                fixture.source,
                output,
                storage,
                .{ .output_size = .exact, .limits = .{ .work_units = work - 1 } },
            ),
        );
        try std.testing.expectError(
            error.LimitExceeded,
            decode(
                fixture.source,
                output,
                storage,
                .{ .output_size = .exact, .limits = .{ .input_bytes = fixture.source.len - 1 } },
            ),
        );
        // Extra capacity is not permission to change the existing output-limit/error priority.
        @memset(backing, 0xa5);
        try std.testing.expectError(
            error.InvalidStream,
            decode(
                fixture.source,
                backing[1..][0 .. fixture.expected.len + 1],
                storage,
                .{ .output_size = .exact, .limits = .{ .output_bytes = fixture.expected.len } },
            ),
        );
        try std.testing.expect(std.mem.allEqual(u8, backing[fixture.expected.len + 1 ..], 0xa5));
        if (output.len != 0) {
            @memset(backing, 0xa5);
            try std.testing.expectError(
                error.LimitExceeded,
                decode(
                    fixture.source,
                    output,
                    storage,
                    .{ .output_size = .exact, .limits = .{ .output_bytes = output.len - 1 } },
                ),
            );
            try std.testing.expect(std.mem.allEqual(u8, backing[output.len..], 0xa5));
        }
        try std.testing.expectError(
            error.HeaderTooLong,
            decode(
                fixture.source,
                output,
                storage,
                .{
                    .output_size = .exact,
                    .header_limits = .{ .header_bytes = 9 },
                    .limits = .{ .output_bytes = 0 },
                },
            ),
        );
    }
    // The complete empty member fits this work budget even though unused capacity does not.
    @memset(backing, 0xa5);
    try std.testing.expectError(
        error.InvalidStream,
        decode(
            &empty,
            backing[1..33],
            .{ .workspace = workspace },
            .{ .output_size = .exact, .limits = .{ .work_units = empty.len } },
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, backing, 0xa5));
    try std.testing.expectError(
        error.LimitExceeded,
        decode(
            &empty,
            backing[1..33],
            .{ .workspace = workspace },
            .{ .output_size = .exact, .limits = .{ .work_units = empty.len - 1 } },
        ),
    );
    // A budget may cut only unselected trailing data. Extent mismatch is still InvalidStream.
    const following = empty ++ "tail";
    try std.testing.expectError(
        error.InvalidStream,
        decode(
            following,
            backing[1..2],
            .{ .workspace = workspace },
            .{ .output_size = .exact, .limits = .{ .input_bytes = following.len - 1 } },
        ),
    );
    // The complete member's cumulative work refusal precedes an oversized exact destination.
    try std.testing.expectError(
        error.LimitExceeded,
        decode(
            &stored,
            backing[1..5],
            .{ .workspace = workspace },
            .{ .output_size = .exact, .limits = .{ .work_units = stored.len + 2 } },
        ),
    );
    const joined = empty ++ stored ++ fixed ++ empty;
    const expected = "SVG" ++ fixture_text;
    const storage: DecodeStorage = .{ .workspace = workspace };
    @memset(backing, 0xa5);
    const output = backing[1..][0..expected.len];
    const result = try decode(
        &joined,
        output,
        storage,
        .{
            .members = .concatenate,
            .output_size = .exact,
            .trailing_data = .reject,
            .limits = .{
                .input_bytes = joined.len,
                .output_bytes = output.len,
                .work_units = joined.len + output.len,
            },
        },
    );
    try std.testing.expectEqual(4, result.members);
    try std.testing.expectEqual(joined.len, result.consumed);
    try std.testing.expectEqualSlices(u8, expected, output);
    try std.testing.expectEqual(0xa5, backing[0]);
    try std.testing.expect(std.mem.allEqual(u8, backing[expected.len + 1 ..], 0xa5));
    try std.testing.expectError(
        error.LimitExceeded,
        decode(
            &joined,
            output,
            storage,
            .{
                .members = .concatenate,
                .output_size = .exact,
                .limits = .{ .work_units = joined.len + output.len - 1 },
            },
        ),
    );
    const first = try decode(
        &joined,
        output[0..0],
        storage,
        .{ .members = .iterate, .output_size = .exact },
    );
    try std.testing.expectEqual(1, first.members);
    try std.testing.expectEqual(empty.len, first.consumed);
    try std.testing.expectEqual(0, first.produced);
}
