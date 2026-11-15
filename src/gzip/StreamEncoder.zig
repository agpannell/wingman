//! Encode gzip members across input/output suspensions. Reset copies metadata into a bounded
//! framing-output loan, then releases it before DEFLATE reuses the reservation. The checksum and
//! member counters advance only as source is accepted and framing is returned. The worker may move
//! between calls with its old copy retired and its external workspace kept exclusively borrowed;
//! even a pending header refers to that workspace, rather than the worker's own fields.

const std = @import("std");
const Crc32IsoHdlc = @import("../crc.zig").Crc32IsoHdlc;
const deflate = @import("../deflate.zig");
const overlaps = @import("../common/byte_ranges.zig").overlaps;
const header_encode = @import("header_encode.zig");
const Options = @import("EncodeOptions.zig");
const operation = @import("encode.zig"); // Tests of complete-buffer and worker composition.
const into = operation.into;
const bound = operation.bound;
const decoding = @import("decode.zig");
const Header = @import("Header.zig");
const Member = @import("Member.zig");
const Workspace = deflate.encode.Workspace;
const DecoderWorkspace = deflate.decode.Workspace;
const Compression = deflate.encode.Compression;
const Action = deflate.encode.Action;
const Progress = deflate.encode.Progress;
const Stats = deflate.encode.Stats;
const StreamEncoder = @This();

/// Encoding and member framing failures. Failed step/nextMember calls poison the worker until
/// reset.
pub const Error = ResetError || StepError;

/// Header admission, raw setup or refusal of the complete member framing reservation.
pub const ResetError = header_encode.Error || error{
    /// Owner, dictionary or reservations overlap.
    StorageOverlap,
    /// The output allowance cannot admit the gzip header and trailer.
    LimitExceeded,
};
/// Invalid lifecycle, overlapping fragments or exhausted cumulative admission.
pub const StepError = error{
    InvalidState,
    NeedReset,
    StorageOverlap,
    LimitExceeded,
    CounterOverflow,
};

/// Raw stream with an exclusive framing-output loan while the header is pending.
raw: deflate.encode.StreamEncoder,
/// CRC-32 of source bytes accepted for the current member.
checksum: Crc32IsoHdlc,
/// Accepted current-member source size modulo 2^32, for ISIZE.
size: u32,
/// Retained exclusive reservation used for overlap admission and the next member.
workspace: *Workspace,
/// Copied metadata borrowed from raw framing output; empty after releasing that loan.
header: []const u8,
/// Returned prefix of the active header or trailer.
position: usize,
/// CRC-32 and ISIZE trailer, initialized when the raw body finishes.
trailer: [8]u8,
/// Framing stage to resume after an output stall.
phase: enum { header, body, trailer, complete },

/// Current-member header/trailer bytes already returned to callers.
framing_bytes: u64,
/// Checked totals for previous completed members.
prior: Stats,
/// Last successfully published aggregate; failures leave this snapshot unchanged.
last: Stats,
/// Fully returned members since reset, including nextMember transitions.
completed_members: u64,
/// A failed operation requires reset before continuing.
failed: bool,

/// Copies a bounded metadata header into scratch, without retaining any metadata pointers. The
/// complete header must fit the raw wire reservation (65535 + 128 bytes). Metadata, scratch and
/// owner must be disjoint.
pub fn reset(self: *StreamEncoder, workspace: *Workspace, options: Options) ResetError!void {
    if (overlaps(std.mem.asBytes(self), std.mem.asBytes(workspace))) return error.StorageOverlap;
    inline for (.{ options.extra, options.name, options.comment }) |field| {
        if (field) |bytes| {
            if (overlaps(bytes, std.mem.asBytes(self))) return error.StorageOverlap;
            if (overlaps(bytes, std.mem.asBytes(workspace))) return error.StorageOverlap;
        }
    }
    const header_bytes = try header_encode.size(options);
    const framing = header_bytes + 8;
    if (options.limits.output_bytes < framing) return error.LimitExceeded;
    var raw_options: deflate.encode.Options = .{
        .compression = options.compression,
        .window_bytes = options.window_bytes,
        .limits = options.limits,
    };
    raw_options.limits.output_bytes -= framing;
    try self.raw.reset(workspace, raw_options);
    self.workspace = workspace;
    const header = self.raw.borrowFramingOutput() catch unreachable;
    self.header = header[0..header_bytes];
    self.checksum = Crc32IsoHdlc.init();
    self.size = 0;
    self.position = 0;
    self.phase = .header;
    self.framing_bytes = 0;
    self.prior = .{};
    self.last = .{};
    self.completed_members = 0;
    self.failed = false;
    header_encode.write(header[0..header_bytes], options);
}

/// Starts another independent member after complete; no history crosses a member boundary. Encoding
/// limits apply independently to each member. Statistics remain cumulative, with checked overflow
/// across arbitrarily many members.
pub fn nextMember(self: *StreamEncoder, options: Options) Error!void {
    if (self.failed) return error.NeedReset;
    self.beginMember(options) catch |err| {
        self.failed = true;
        return err;
    };
}

/// Copied totals through the last successful step, across all members begun with nextMember. Failed
/// operations publish neither progress nor counts.
pub fn counts(self: *const StreamEncoder) Stats {
    return self.last;
}

/// Number of fully returned independent members.
pub fn members(self: *const StreamEncoder) u64 {
    return self.completed_members;
}

/// Uses process/flush/finish actions; finish closes exactly one member. CRC-32 and ISIZE cover
/// accepted source exactly once across suspension. Any failure poisons this owner until reset.
pub fn step(
    self: *StreamEncoder,
    input: []const u8,
    output: []u8,
    action: Action,
) StepError!Progress {
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

fn beginMember(self: *StreamEncoder, options: Options) (ResetError || error{InvalidState})!void {
    if (self.phase != .complete) return error.InvalidState;
    const prior = try self.checkedCounts();
    const members_done = self.completed_members;
    try self.reset(self.workspace, options);
    self.prior = prior;
    self.last = prior;
    self.completed_members = members_done;
}

fn checkedCounts(self: *const StreamEncoder) error{CounterOverflow}!Stats {
    var stats = self.raw.counts();
    stats.output_bytes = std.math.add(
        u64,
        stats.output_bytes,
        self.framing_bytes,
    ) catch return error.CounterOverflow;
    inline for (@typeInfo(Stats).@"struct".field_names) |field| {
        const current = @field(stats, field);
        const prior = @field(self.prior, field);
        const total = std.math.add(u64, current, prior) catch return error.CounterOverflow;
        @field(stats, field) = total;
    }
    return stats;
}

fn advance(
    self: *StreamEncoder,
    input: []const u8,
    output: []u8,
    action: Action,
) StepError!Progress {
    if (overlaps(input, output)) return error.StorageOverlap;
    inline for (.{ std.mem.asBytes(self), std.mem.asBytes(self.workspace) }) |reservation| {
        if (overlaps(input, reservation)) return error.StorageOverlap;
        if (overlaps(output, reservation)) return error.StorageOverlap;
    }
    var written: usize = 0;
    var read: usize = 0;
    while (true) switch (self.phase) {
        .header, .trailer => {
            const bytes: []const u8 = blk: {
                if (self.phase == .header) {
                    break :blk self.header;
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
            if (self.phase == .header) {
                try self.raw.releaseFramingOutput();
                self.header = &.{};
                self.phase = .body;
            } else self.phase = .complete;
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

test "gzip encoding copies metadata emits deterministic members and resets history" {
    const allocator = std.testing.allocator;
    const encode_workspace = try Workspace.create(allocator);
    defer encode_workspace.destroy(allocator);
    const decode_workspace = try DecoderWorkspace.create(allocator);
    defer decode_workspace.destroy(allocator);
    var encoder: StreamEncoder = undefined;
    var metadata = [_]u8{ 'n', 'a', 'm', 'e' };
    try encoder.reset(
        encode_workspace,
        .{
            .name = &metadata,
            .comment = "comment",
            .extra = &.{ 1, 2, 3 },
            .header_crc = true,
            .modification_time = 123,
        },
    );
    @memset(&metadata, 0xa5);
    var wire: [512]u8 = undefined;
    const first = try encoder.step("member data", &wire, .finish);
    try std.testing.expectEqual(.complete, first.status);
    const header = try Header.parse(wire[0..first.produced], .{});
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
    var iterator: Member.Iterator = .{ .source = wire[0 .. first.produced + second.produced] };
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
    const encode_workspace = try Workspace.create(std.testing.allocator);
    defer encode_workspace.destroy(std.testing.allocator);
    const decode_workspace = try DecoderWorkspace.create(std.testing.allocator);
    defer decode_workspace.destroy(std.testing.allocator);
    var encoder: StreamEncoder = undefined;
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
    const result = try decoding.into(
        wire[0..written],
        &output,
        .{ .workspace = decode_workspace },
        .{},
    );
    try std.testing.expectEqual(written, result.consumed);
    try std.testing.expectEqualStrings(source, &output);
    try std.testing.expectEqual(written, encoder.counts().output_bytes);
}

test "gzip encoding bounds full metadata and cumulative counter failures" {
    const allocator = std.testing.allocator;
    const encode_workspace = try Workspace.create(allocator);
    defer encode_workspace.destroy(allocator);
    const extra = try allocator.alloc(u8, 65535);
    defer allocator.free(extra);
    @memset(extra, 0x5a);
    const capacity = try bound(0, .{ .extra = extra, .header_crc = true });
    const wire = try allocator.alloc(u8, capacity);
    defer allocator.free(wire);
    const encoded = try into("", wire, encode_workspace, .{ .extra = extra, .header_crc = true });
    const parsed = try Header.parse(encoded, .{});
    try std.testing.expectEqualSlices(u8, extra, parsed.header.extra);
    var encoder: StreamEncoder = undefined;
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
    try encoder.reset(encode_workspace, .{ .limits = .{ .output_bytes = 20 } });
    try std.testing.expectEqual(.complete, (try encoder.step("", wire, .finish)).status);
    try std.testing.expectEqual(20, encoder.counts().output_bytes);
}

test "gzip encoding refuses complete-buffer overlap before writing metadata" {
    const encode_workspace = try Workspace.create(std.testing.allocator);
    defer encode_workspace.destroy(std.testing.allocator);
    var owner: StreamEncoder = undefined;
    try owner.reset(encode_workspace, .{});
    const header = owner.header;
    const before = header[0..10].*;
    var output: [128]u8 = @splat(0xa5);
    try std.testing.expectError(
        error.StorageOverlap,
        into(header[0..3], &output, encode_workspace, .{}),
    );
    try std.testing.expectEqualSlices(u8, &before, header[0..10]);
    for (output) |byte| try std.testing.expectEqual(0xa5, byte);
}

test "failed gzip encoding retains last successfully published counts" {
    const workspace = try Workspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: StreamEncoder = undefined;
    var output: [128]u8 = undefined;
    for (
        [_]Compression{
            .{ .level = 3 },
            .{ .level = 9 },
            .{ .level = 9, .offline_pricing = .maximum_lengths },
            .{ .level = 9, .offline_refinement = .early },
        },
    ) |compression| {
        try encoder.reset(
            workspace,
            .{ .compression = compression, .limits = .{ .work_units = 1 } },
        );
        _ = try encoder.step("x", &output, .process);
        const published = encoder.counts();
        try std.testing.expectEqual(1, published.input_bytes);
        try std.testing.expectEqual(10, published.output_bytes);
        try std.testing.expectError(
            error.LimitExceeded,
            encoder.step("aaaaaaaaaaaa", &output, .finish),
        );
        try std.testing.expectEqual(published, encoder.counts());
        try std.testing.expectError(error.NeedReset, encoder.step("", &output, .finish));
    }
}

test "compression levels write gzip hints and verified trailers" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try Workspace.create(allocator);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try DecoderWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    const source = "a small payload with a repeated small payload";
    var wire: [512]u8 = undefined;
    var restored: [source.len]u8 = undefined;
    for (0..10) |level| {
        for ([_]deflate.encode.Compression.Strategy{ .default, .four_byte_runs }) |strategy| {
            const encoded = try into(
                source,
                &wire,
                encoder_workspace,
                .{ .compression = .{ .level = @intCast(level), .strategy = strategy } },
            );
            // RFC 1952 reserves these hints for the slowest and fastest compressor choices. The
            // trailer still covers the decoded payload, independently of that informational byte.
            const hint: u8 = if (strategy != .default) 0 else if (level == 1) 4 else if (level == 9)
                2
            else
                0;
            try std.testing.expectEqual(hint, encoded[8]);
            try std.testing.expectEqual(
                Crc32IsoHdlc.hash(source),
                std.mem.readInt(u32, encoded[encoded.len - 8 ..][0..4], .little),
            );
            try std.testing.expectEqual(
                @as(u32, source.len),
                std.mem.readInt(u32, encoded[encoded.len - 4 ..][0..4], .little),
            );
            const result = try decoding.into(
                encoded,
                &restored,
                .{ .workspace = decoder_workspace },
                .{ .output_size = .exact, .trailing_data = .reject },
            );
            try std.testing.expectEqual(source.len, result.produced);
            try std.testing.expectEqualSlices(u8, source, &restored);
        }
    }
    const literal_only = try into(
        source,
        &wire,
        encoder_workspace,
        .{ .compression = .{ .strategy = .huffman_only } },
    );
    try std.testing.expectEqual(@as(u8, 0), literal_only[8]);
    for ([_]u8{ 4, 5, 6 }) |level| {
        const encoded = try into(
            source,
            &wire,
            encoder_workspace,
            .{ .compression = .{ .level = level, .lazy_lookahead = .reduced } },
        );
        try std.testing.expectEqual(@as(u8, 0), encoded[8]);
        const result = try decoding.into(
            encoded,
            &restored,
            .{ .workspace = decoder_workspace },
            .{ .output_size = .exact, .trailing_data = .reject },
        );
        try std.testing.expectEqual(source.len, result.produced);
        try std.testing.expectEqualSlices(u8, source, &restored);
    }
    for ([_]u8{ 7, 8, 9 }) |level| {
        inline for (.{ .reduced, .maximum_lengths }) |pricing| {
            const encoded = try into(
                source,
                &wire,
                encoder_workspace,
                .{ .compression = .{ .level = level, .offline_pricing = pricing } },
            );
            try std.testing.expectEqual(@as(u8, if (level == 9) 2 else 0), encoded[8]);
            const result = try decoding.into(
                encoded,
                &restored,
                .{ .workspace = decoder_workspace },
                .{ .output_size = .exact, .trailing_data = .reject },
            );
            try std.testing.expectEqual(source.len, result.produced);
            try std.testing.expectEqualSlices(u8, source, &restored);
        }
    }
    const early = try into(
        source,
        &wire,
        encoder_workspace,
        .{ .compression = .{ .level = 9, .offline_refinement = .early } },
    );
    const early_result = try decoding.into(
        early,
        &restored,
        .{ .workspace = decoder_workspace },
        .{ .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(source.len, early_result.produced);
    try std.testing.expectEqualSlices(u8, source, &restored);
    var encoder: StreamEncoder = undefined;
    try encoder.reset(encoder_workspace, .{});
    const original_header = encoder.header[0..10].*;
    const original_counts = encoder.counts();
    try std.testing.expectError(
        error.InvalidOptions,
        encoder.reset(
            encoder_workspace,
            .{ .compression = .{ .level = 9, .lazy_lookahead = .reduced } },
        ),
    );
    try std.testing.expectEqualSlices(u8, &original_header, encoder.header[0..10]);
    try std.testing.expectEqualDeep(original_counts, encoder.counts());
    try std.testing.expectError(
        error.InvalidOptions,
        encoder.reset(
            encoder_workspace,
            .{ .compression = .{ .level = 6, .offline_pricing = .reduced } },
        ),
    );
    try std.testing.expectEqualSlices(u8, &original_header, encoder.header[0..10]);
    try std.testing.expectEqualDeep(original_counts, encoder.counts());
    try std.testing.expectError(
        error.InvalidOptions,
        encoder.reset(
            encoder_workspace,
            .{ .compression = .{ .level = 6, .offline_pricing = .maximum_lengths } },
        ),
    );
    try std.testing.expectEqualSlices(u8, &original_header, encoder.header[0..10]);
    try std.testing.expectEqualDeep(original_counts, encoder.counts());
    @memset(&wire, 0xa5);
    try std.testing.expectError(
        error.InvalidOptions,
        into(source, &wire, encoder_workspace, .{ .compression = .{ .level = 10 } }),
    );
    try std.testing.expect(std.mem.allEqual(u8, &wire, 0xa5));
    // Header/trailer admission occurs before the raw encoder validates the requested level.
    try std.testing.expectError(
        error.LimitExceeded,
        into(
            source,
            &wire,
            encoder_workspace,
            .{ .compression = .{ .level = 10 }, .limits = .{ .output_bytes = 0 } },
        ),
    );
    inline for (.{ .reduced, .maximum_lengths }) |pricing| {
        try std.testing.expectError(
            error.LimitExceeded,
            into(
                source,
                &wire,
                encoder_workspace,
                .{
                    .compression = .{ .level = 6, .offline_pricing = pricing },
                    .limits = .{ .output_bytes = 0 },
                },
            ),
        );
    }
}

test "gzip encoding transfers pending header loans and trailers between calls" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const original = try allocator.create(StreamEncoder);
    defer allocator.destroy(original);
    const transferred = try allocator.create(StreamEncoder);
    defer allocator.destroy(transferred);
    const source = "member bytes";
    const options: Options = .{
        .compression = .{ .level = 0 },
        .name = "entry",
        .comment = "captured",
        .header_crc = true,
    };
    var expected: [128]u8 = undefined;
    const expected_wire = try into(source, &expected, workspace, options);
    var output: [136]u8 = @splat(0xa5);
    try original.reset(workspace, options);
    const first = try original.step(source, output[0..1], .finish);
    try std.testing.expectEqual(@as(usize, 0), first.consumed);
    try std.testing.expectEqual(deflate.encode.Status.need_output, first.status);
    transferred.* = original.*;
    @memset(std.mem.asBytes(original), 0xa5);
    const middle = try transferred.step(source, output[1 .. expected_wire.len - 7], .finish);
    try std.testing.expectEqual(source.len, middle.consumed);
    try std.testing.expectEqual(deflate.encode.Status.need_output, middle.status);
    try std.testing.expectEqual(@TypeOf(transferred.phase).trailer, transferred.phase);
    original.* = transferred.*;
    @memset(std.mem.asBytes(transferred), 0xa5);
    const final = try original.step(&.{}, output[expected_wire.len - 7 ..], .finish);
    try std.testing.expectEqual(deflate.encode.Status.complete, final.status);
    try std.testing.expectEqual(@as(usize, 7), final.produced);
    try std.testing.expectEqualSlices(u8, expected_wire, output[0..expected_wire.len]);
    try std.testing.expectEqual(@as(u64, 1), original.members());
    try std.testing.expectEqual(@as(u64, source.len), original.counts().input_bytes);
    try std.testing.expectEqual(@as(u64, expected_wire.len), original.counts().output_bytes);
    for (output[expected_wire.len..]) |byte| try std.testing.expectEqual(0xa5, byte);
}
