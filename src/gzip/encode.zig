//! gzip member encoding and fragmented output.

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

const decoding = @import("decode.zig");
const DecoderWorkspace = deflate.DecoderWorkspace;
const MemberIterator = decoding.MemberIterator;
const decode = decoding.decode;
const parseHeader = decoding.parseHeader;

pub const EncoderWorkspace = deflate.EncoderWorkspace;
pub const EncodeProfile = deflate.EncodeProfile;
pub const EncodeAction = deflate.EncodeAction;
pub const EncodeStatus = deflate.EncodeStatus;
pub const EncodeProgress = deflate.EncodeProgress;
pub const EncodeStats = deflate.EncodeStats;

/// Raw encoding failures plus an invalid or over-capacity metadata header.
pub const EncodeError = deflate.EncodeError || error{HeaderTooLong};

/// Caller-supplied member metadata. Reset copies these bytes, so their backing can retire on
/// return.
pub const EncodeOptions = struct {
    /// Encoder effort/window/limits. Output limits cover this complete member.
    deflate: deflate.EncodeOptions = .{},
    /// Explicit Unix timestamp; zero represents no timestamp.
    modification_time: u32 = 0,
    /// Uninterpreted RFC operating-system byte; 255 means unspecified.
    operating_system: u8 = 255,
    /// Set FTEXT without interpreting the payload.
    text: bool = false,
    /// Optional extra data, at most 65535 bytes. Null omits FEXTRA.
    extra: ?[]const u8 = null,
    /// Optional bytes without embedded NUL; reset adds the terminating NUL.
    name: ?[]const u8 = null,
    /// Optional bytes without embedded NUL; reset adds the terminating NUL.
    comment: ?[]const u8 = null,
    /// Emit the low 16 bits of the header CRC-32 as FHCRC.
    header_crc: bool = false,
};

/// Bound for a complete member, including selected metadata. Invalid metadata and checked size
/// overflow return errors before any output is changed.
pub fn encodeBound(source_bytes: usize, options: EncodeOptions) EncodeError!usize {
    return std.math.add(
        usize,
        try deflate.encodeBound(source_bytes),
        try encodeHeaderBytes(options) + 8,
    ) catch error.CounterOverflow;
}

/// Encodes one independent gzip member. Returns a borrowed output prefix. Source/output/scratch
/// must be disjoint. Metadata is copied before encoding; failure may change output and publishes no
/// partial result.
pub fn encode(
    source: []const u8,
    output: []u8,
    workspace: *EncoderWorkspace,
    options: EncodeOptions,
) EncodeError![]u8 {
    if (overlaps(source, output)) return error.StorageOverlap;
    if (overlaps(source, std.mem.asBytes(workspace))) return error.StorageOverlap;
    if (overlaps(output, std.mem.asBytes(workspace))) return error.StorageOverlap;
    // Metadata may not alias output, even though it retires after reset.
    inline for (.{ options.extra, options.name, options.comment }) |field| {
        if (field) |bytes| {
            if (overlaps(bytes, output)) return error.StorageOverlap;
        }
    }
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, options);
    const progress = try encoder.step(source, output, .finish);
    if (progress.status != .complete) return error.OutputTooSmall;
    return output[0..progress.produced];
}

/// Resumable gzip encoder with copied metadata and incremental CRC/ISIZE. Scratch is borrowed
/// exclusively; accepted input and returned output retire after every step. No allocator is
/// retained. Explicit nextMember starts a fresh member/history while preserving cumulative
/// statistics.
pub const Encoder = struct {
    raw: deflate.Encoder,
    checksum: crc32.Hasher,
    size: u32,
    header_bytes: usize,
    position: usize,
    trailer: [8]u8,
    phase: enum { header, body, trailer, complete },

    framing_bytes: u64,
    prior: EncodeStats,
    last: EncodeStats,
    completed_members: u64,
    failed: bool,

    /// Copies a bounded metadata header into scratch, without retaining any metadata pointers. The
    /// complete header must fit the raw wire reservation (65535 + 128 bytes). Metadata, scratch and
    /// owner must be disjoint.
    pub fn reset(
        self: *Encoder,
        workspace: *EncoderWorkspace,
        options: EncodeOptions,
    ) EncodeError!void {
        if (options.deflate.dictionary != null) return error.InvalidOptions;
        if (overlaps(
            std.mem.asBytes(self),
            std.mem.asBytes(workspace),
        )) return error.StorageOverlap;
        inline for (.{ options.extra, options.name, options.comment }) |field| {
            if (field) |bytes| {
                if (overlaps(bytes, std.mem.asBytes(self))) return error.StorageOverlap;
                if (overlaps(bytes, std.mem.asBytes(workspace))) return error.StorageOverlap;
            }
        }
        const header_bytes = try encodeHeaderBytes(options);
        if (header_bytes > workspace.wire.len) return error.HeaderTooLong;
        const framing = header_bytes + 8;
        if (options.deflate.limits.output_bytes < framing) return error.LimitExceeded;
        var raw_options = options.deflate;
        raw_options.limits.output_bytes -= framing;
        try self.raw.reset(workspace, raw_options);
        self.checksum = .init;
        self.size = 0;
        self.header_bytes = header_bytes;
        self.position = 0;
        self.phase = .header;
        self.framing_bytes = 0;
        self.prior = .{};
        self.last = .{};
        self.completed_members = 0;
        self.failed = false;
        var flags: u8 = if (options.text) flag_text else 0;
        if (options.extra != null) flags |= flag_extra;
        if (options.name != null) flags |= flag_name;
        if (options.comment != null) flags |= flag_comment;
        if (options.header_crc) flags |= flag_header_crc;

        const bytes = &workspace.wire;
        bytes[0..3].* = signature;
        bytes[3] = flags;
        std.mem.writeInt(u32, bytes[4..8], options.modification_time, .little);
        bytes[8] = switch (options.deflate.profile) {
            .offline => 2,
            .greedy => 4,
            else => 0,
        };
        bytes[9] = options.operating_system;
        var position: usize = 10;
        if (options.extra) |extra| {
            std.mem.writeInt(u16, bytes[position..][0..2], @intCast(extra.len), .little);
            position += 2;
            @memcpy(bytes[position..][0..extra.len], extra);
            position += extra.len;
        }
        inline for (.{ options.name, options.comment }) |field| {
            if (field) |text| {
                @memcpy(bytes[position..][0..text.len], text);
                position += text.len;
                bytes[position] = 0;
                position += 1;
            }
        }
        if (options.header_crc) {
            const checksum: u16 = @truncate(crc32.hash(bytes[0..position]));
            std.mem.writeInt(u16, bytes[position..][0..2], checksum, .little);
        }
    }

    /// Starts another independent member after complete; no history crosses a member boundary.
    /// Encoding limits apply independently to each member. Statistics remain cumulative, with
    /// checked overflow across arbitrarily many members.
    pub fn nextMember(self: *Encoder, options: EncodeOptions) EncodeError!void {
        if (self.failed) return error.NeedReset;
        self.beginMember(options) catch |err| {
            self.failed = true;
            return err;
        };
    }

    /// Copied totals through the last successful step, across all members begun with nextMember.
    /// Failed operations publish neither progress nor counts.
    pub fn counts(self: *const Encoder) EncodeStats {
        return self.last;
    }

    /// Number of fully returned independent members.
    pub fn members(self: *const Encoder) u64 {
        return self.completed_members;
    }

    /// Uses process/flush/finish actions; finish closes exactly one member. CRC-32 and ISIZE cover
    /// accepted source exactly once across suspension. Any failure poisons this owner until reset.
    pub fn step(
        self: *Encoder,
        input: []const u8,
        output: []u8,
        action: EncodeAction,
    ) EncodeError!EncodeProgress {
        if (self.failed) return error.NeedReset;
        const was_complete = self.phase == .complete;
        const progress = self.advance(input, output, action) catch |err| {
            self.failed = true;
            return err;
        };
        const completed = blk: {
            if (was_complete or self.phase != .complete) break :blk self.completed_members;
            break :blk std.math.add(u64, self.completed_members, 1) catch {
                self.failed = true;
                return error.CounterOverflow;
            };
        };
        // Publish counts and completion only after both checked calculations succeed.
        self.last = self.checkedCounts() catch |err| {
            self.failed = true;
            return err;
        };
        self.completed_members = completed;
        return progress;
    }

    fn beginMember(self: *Encoder, options: EncodeOptions) EncodeError!void {
        if (self.phase != .complete) return error.InvalidState;
        const prior = try self.checkedCounts();
        const members_done = self.completed_members;
        try self.reset(self.raw.workspace, options);
        self.prior = prior;
        self.last = prior;
        self.completed_members = members_done;
    }

    fn checkedCounts(self: *const Encoder) EncodeError!EncodeStats {
        var stats = self.raw.counts();
        stats.output_bytes = std.math.add(
            u64,
            stats.output_bytes,
            self.framing_bytes,
        ) catch return error.CounterOverflow;
        inline for (@typeInfo(EncodeStats).@"struct".field_names) |field| {
            const current = @field(stats, field);
            const prior = @field(self.prior, field);
            const total = std.math.add(u64, current, prior) catch return error.CounterOverflow;
            @field(stats, field) = total;
        }
        return stats;
    }

    fn advance(
        self: *Encoder,
        input: []const u8,
        output: []u8,
        action: EncodeAction,
    ) EncodeError!EncodeProgress {
        if (overlaps(input, output)) return error.StorageOverlap;
        inline for (.{ std.mem.asBytes(self), std.mem.asBytes(self.raw.workspace) }) |reservation| {
            if (overlaps(input, reservation)) return error.StorageOverlap;
            if (overlaps(output, reservation)) return error.StorageOverlap;
        }
        var written: usize = 0;
        var read: usize = 0;
        while (true) switch (self.phase) {
            .header, .trailer => {
                const bytes: []const u8 = blk: {
                    if (self.phase == .header) {
                        break :blk self.raw.workspace.wire[0..self.header_bytes];
                    }
                    break :blk &self.trailer;
                };
                const amount = @min(bytes.len - self.position, output.len - written);
                @memcpy(output[written..][0..amount], bytes[self.position..][0..amount]);
                self.position += amount;
                written += amount;
                self.framing_bytes += amount;
                if (self.position < bytes.len) return .{
                    .consumed = read,
                    .produced = written,
                    .status = .need_output,
                };
                self.position = 0;
                self.phase = if (self.phase == .header) .body else .complete;
            },
            .body => {
                const progress = try self.raw.step(input, output[written..], action);
                self.checksum.update(input[0..progress.consumed]);
                self.size +%= @truncate(progress.consumed);
                read = progress.consumed;
                written += progress.produced;
                if (progress.status != .complete) {
                    _ = try self.checkedCounts();
                    return .{ .consumed = read, .produced = written, .status = progress.status };
                }
                std.mem.writeInt(u32, self.trailer[0..4], self.checksum.final(), .little);
                std.mem.writeInt(u32, self.trailer[4..8], self.size, .little);
                self.phase = .trailer;
            },
            .complete => {
                if (read != input.len or action != .finish) return error.InvalidState;
                _ = try self.checkedCounts();
                return .{ .consumed = read, .produced = written, .status = .complete };
            },
        };
    }
};

fn encodeHeaderBytes(options: EncodeOptions) EncodeError!usize {
    var size: usize = if (options.header_crc) 12 else 10;
    if (options.extra) |extra| {
        if (extra.len > 65535) return error.HeaderTooLong;
        size += 2 + extra.len;
    }
    inline for (.{ options.name, options.comment }) |field| {
        if (field) |bytes| {
            size = std.math.add(usize, size, bytes.len) catch return error.CounterOverflow;
            size = std.math.add(usize, size, 1) catch return error.CounterOverflow;
            if (size > 65535 + 128) return error.HeaderTooLong;
            if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidOptions;
        }
    }
    if (size > 65535 + 128) return error.HeaderTooLong;
    return size;
}

test "gzip encoding copies metadata emits deterministic members and resets history" {
    const allocator = std.testing.allocator;
    const encode_workspace = try EncoderWorkspace.create(allocator);
    defer encode_workspace.destroy(allocator);
    const decode_workspace = try DecoderWorkspace.create(allocator);
    defer decode_workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    var metadata = [_]u8{ 'n', 'a', 'm', 'e' };
    try encoder.reset(encode_workspace, .{ .name = &metadata, .comment = "comment", .extra = &.{
        1, 2, 3,
    }, .header_crc = true, .modification_time = 123 });
    @memset(&metadata, 0xa5);
    var wire: [512]u8 = undefined;
    const first = try encoder.step("member data", &wire, .finish);
    try std.testing.expectEqual(.complete, first.status);
    const header = try parseHeader(wire[0..first.produced], .{});
    try std.testing.expectEqualStrings("name", header.header.name.?);
    try std.testing.expectEqualStrings("comment", header.header.comment.?);
    try std.testing.expectEqual(123, header.header.modification_time);
    try std.testing.expectEqual(255, header.header.operating_system);
    try encoder.nextMember(.{});
    const second = try encoder.step("second", wire[first.produced..], .finish);
    try std.testing.expectEqual(.complete, second.status);
    try std.testing.expectEqual(2, encoder.members());
    try std.testing.expectEqual(17, encoder.counts().input_bytes);
    try std.testing.expectEqual(first.produced + second.produced, encoder.counts().output_bytes);
    var iterator: MemberIterator = .{ .source = wire[0 .. first.produced + second.produced] };
    var output: [32]u8 = undefined;
    const one = (try iterator.next(&output, decode_workspace)).?;
    try std.testing.expectEqualStrings("member data", output[0..one.result.produced]);
    const two = (try iterator.next(&output, decode_workspace)).?;
    try std.testing.expectEqualStrings("second", output[0..two.result.produced]);
    try std.testing.expect(try iterator.next(&output, decode_workspace) == null);
    try std.testing.expectError(error.InvalidOptions, encoder.nextMember(.{ .name = "a\x00b" }));
    try std.testing.expectError(error.NeedReset, encoder.step("", &wire, .finish));
}

test "gzip encoding byte fragments survive retired metadata and output" {
    const encode_workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer encode_workspace.destroy(std.testing.allocator);
    const decode_workspace = try DecoderWorkspace.create(std.testing.allocator);
    defer decode_workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(encode_workspace, .{ .header_crc = true, .name = "asset", .extra = &.{} });
    const source = "small fragmented gzip payload payload payload";
    var wire: [256]u8 = undefined;
    var read: usize = 0;
    var written: usize = 0;
    while (true) {
        const length = @min(1, source.len - read);
        var fragment: [1]u8 = undefined;
        if (length != 0) fragment[0] = source[read];
        var target: [1]u8 = undefined;
        const progress = try encoder.step(
            fragment[0..length],
            &target,
            if (read + length == source.len) .finish else .process,
        );
        read += progress.consumed;
        @memset(&fragment, 0xa5);
        @memcpy(wire[written..][0..progress.produced], target[0..progress.produced]);
        written += progress.produced;
        @memset(&target, 0xa5);
        if (progress.status == .complete) break;
    }
    var output: [source.len]u8 = undefined;
    const result = try decode(wire[0..written], &output, .{ .workspace = decode_workspace }, .{});
    try std.testing.expectEqual(written, result.consumed);
    try std.testing.expectEqualStrings(source, &output);
    try std.testing.expectEqual(written, encoder.counts().output_bytes);
}

test "gzip encoding bounds full metadata and cumulative counter failures" {
    const allocator = std.testing.allocator;
    const encode_workspace = try EncoderWorkspace.create(allocator);
    defer encode_workspace.destroy(allocator);
    const extra = try allocator.alloc(u8, 65535);
    defer allocator.free(extra);
    @memset(extra, 0x5a);
    const capacity = try encodeBound(0, .{ .extra = extra, .header_crc = true });
    const wire = try allocator.alloc(u8, capacity);
    defer allocator.free(wire);
    const encoded = try encode("", wire, encode_workspace, .{ .extra = extra, .header_crc = true });
    const parsed = try parseHeader(encoded, .{});
    try std.testing.expectEqualSlices(u8, extra, parsed.header.extra);
    var encoder: Encoder = undefined;
    try encoder.reset(encode_workspace, .{});
    encoder.prior.output_bytes = std.math.maxInt(u64) - 1;
    try std.testing.expectError(error.CounterOverflow, encoder.step("", wire[0..2], .finish));
    try std.testing.expectEqual(0, encoder.counts().output_bytes);
    try std.testing.expectError(error.NeedReset, encoder.step("", wire, .finish));
    try encoder.reset(encode_workspace, .{});
    encoder.prior.output_bytes = std.math.maxInt(u64) - 19;
    try std.testing.expectError(error.CounterOverflow, encoder.step("", wire, .finish));
    try std.testing.expectEqual(0, encoder.counts().output_bytes);
    try std.testing.expectEqual(0, encoder.members());
    try encoder.reset(encode_workspace, .{});
    const partial = try encoder.step("", wire[0..19], .finish);
    try std.testing.expectEqual(.need_output, partial.status);
    try std.testing.expectEqual(0, encoder.members());
    try std.testing.expectError(error.InvalidState, encoder.step("", wire[0..1], .process));
    try std.testing.expectEqual(19, encoder.counts().output_bytes);
    try std.testing.expectEqual(0, encoder.members());
    try encoder.reset(encode_workspace, .{ .deflate = .{ .limits = .{ .output_bytes = 20 } } });
    try std.testing.expectEqual(.complete, (try encoder.step("", wire, .finish)).status);
    try std.testing.expectEqual(20, encoder.counts().output_bytes);
}

test "gzip encoding refuses complete-buffer overlap before writing metadata" {
    const encode_workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer encode_workspace.destroy(std.testing.allocator);
    @memset(encode_workspace.wire[0..32], 0xa5);
    var output: [128]u8 = @splat(0xa5);
    try std.testing.expectError(
        error.StorageOverlap,
        encode(encode_workspace.wire[0..3], &output, encode_workspace, .{}),
    );
    for (encode_workspace.wire[0..32]) |byte| try std.testing.expectEqual(0xa5, byte);
    for (output) |byte| try std.testing.expectEqual(0xa5, byte);
}
