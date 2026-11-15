//! Complete gzip member selection, admission and aggregate result publication. Each selected member
//! is verified before success. Header parsing and verified metadata iteration have their own
//! owners; fragmented input uses StreamDecoder.

const std = @import("std");
const deflate = @import("../deflate.zig");
const Header = @import("Header.zig");
const Member = @import("Member.zig");
const member_decoding = @import("member_decode.zig");
const byte_ranges = @import("../common/byte_ranges.zig");
const fixtures = @import("decode_fixtures.zig");
pub const StreamDecoder = @import("StreamDecoder.zig");

const overlaps = byte_ranges.overlaps;
const stored = fixtures.stored;
const fixed = fixtures.fixed;
const dynamic = fixtures.dynamic;
const optional_fields = fixtures.optional_fields;
const empty = fixtures.empty;
const fixture_text = fixtures.fixture_text;
const dynamic_text = fixtures.dynamic_text;

pub const Workspace = deflate.decode.Workspace;
pub const Limits = deflate.decode.Limits;
pub const OutputSize = deflate.decode.OutputSize;
pub const TrailingData = deflate.decode.TrailingData;
pub const Error = Header.Error || member_decoding.Error;

/// Complete selected-member counts. Byte counts exclude trailing application data.
pub const Result = struct {
    /// Encoded bytes occupied by the verified selected members.
    consumed: usize,
    /// Restored destination prefix; its remaining suffix is unchanged.
    produced: usize,
    /// Number of fully verified members.
    members: usize = 1,
};
/// Required mutable tables for complete decoding. No separate history is needed.
pub const Storage = struct {
    /// Exclusive address-stable decoding tables, reusable after success or failure.
    workspace: *Workspace,
};
/// Complete-member selection and admission. Default header admission preserves the complete
/// decoder's unbounded optional fields; callers can select finite Header.Limits explicitly.
pub const Options = struct {
    /// Single decodes one member; use Member.Iterator for complete-input metadata iteration.
    members: enum { single, concatenate } = .single,
    /// Exact requires the complete destination extent after all selected members.
    output_size: OutputSize = .bounded,
    /// Reject requires the selected members to consume all supplied source.
    trailing_data: TrailingData = .allow,
    /// Bounds each member header independently.
    header_limits: Header.Limits = .{
        .field_bytes = std.math.maxInt(usize),
        .header_bytes = std.math.maxInt(usize),
    },
    /// Cumulative selected-member input/output/work admission, including framing.
    limits: Limits = .{},
};

/// Decodes and verifies the selected gzip members without allocation. Counts include verified
/// framing; unused output is preserved. Concatenation requires the entire supplied source to
/// consist of members, rejecting trailing garbage. Source, output and workspace must be disjoint.
/// Errors publish no counts and may change output and scratch.
pub fn into(source: []const u8, output: []u8, storage: Storage, options: Options) Error!Result {
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
    var result: Result = .{ .consumed = 0, .produced = 0, .members = 0 };
    while (true) {
        const source_member = bytes[result.consumed..];
        const header = Header.parse(
            source_member,
            options.header_limits,
        ) catch |failure| switch (failure) {
            error.InvalidStream => {
                if (admitted < source.len) return error.LimitExceeded;
                return error.InvalidStream;
            },
            error.HeaderTooLong => return error.HeaderTooLong,
        };
        const member = member_decoding.verify(
            source_member,
            output[result.produced..],
            storage.workspace,
            header,
            .{
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

test into {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);

    // One stored "hello" member followed by application data outside the member.
    const source = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xff, 0x01, 0x05, 0x00, 0xfa, 0xff, 0x68,
        0x65, 0x6c, 0x6c, 0x6f, 0x86, 0xa6, 0x10, 0x36,
        0x05, 0x00, 0x00, 0x00, 0x6e, 0x65, 0x78, 0x74,
    };
    var output: [32]u8 = undefined;
    const result = try into(&source, &output, .{ .workspace = workspace }, .{});
    const member = .{ .text = output[0..result.produced], .next = source[result.consumed..] };

    try std.testing.expectEqualStrings("hello", member.text);
    try std.testing.expectEqualStrings("next", member.next);
}

test "gzip members retain exact stored fixed dynamic empty and trailing boundaries" {
    const workspace = try Workspace.create(std.testing.allocator);
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
        const result = try into(fixture.source, output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(fixture.source.len, result.consumed);
        try std.testing.expectEqual(fixture.expected.len, result.produced);
        try std.testing.expectEqualSlices(u8, fixture.expected, output[0..result.produced]);
        for (output[result.produced..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
    const combined = stored ++ fixed ++ "trailing";
    const first = try into(combined, output, .{ .workspace = workspace }, .{});
    const second = try into(
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
        (try into(&empty, output[0..0], .{ .workspace = workspace }, .{})).produced,
    );
}

test "gzip optional fields header checksum and malformed framing have bounded refusals" {
    const workspace = try Workspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var output: [256]u8 = @splat(0xa5);
    const result = try into(&optional_fields, &output, .{ .workspace = workspace }, .{});
    try std.testing.expectEqual(optional_fields.len, result.consumed);
    try std.testing.expectEqualSlices(u8, fixture_text, output[0..result.produced]);
    for (0..optional_fields.len) |size| {
        try std.testing.expectError(
            error.InvalidStream,
            into(optional_fields[0..size], &output, .{ .workspace = workspace }, .{}),
        );
    }
    for ([_]usize{ 0, 1, 2, 37, optional_fields.len - 8, optional_fields.len - 4 }) |position| {
        var malformed = optional_fields;
        malformed[position] ^= 0x40;
        try std.testing.expectError(
            error.InvalidStream,
            into(&malformed, &output, .{ .workspace = workspace }, .{}),
        );
    }
    for ([_]u8{ 0x20, 0x40, 0x80 }) |flag| {
        var malformed = stored;
        malformed[3] |= flag;
        @memset(&output, 0xa5);
        try std.testing.expectError(
            error.InvalidStream,
            into(&malformed, &output, .{ .workspace = workspace }, .{}),
        );
        for (output) |byte| try std.testing.expectEqual(0xa5, byte);
    }
    try std.testing.expectError(
        error.OutputTooSmall,
        into(&fixed, output[0 .. fixture_text.len - 1], .{ .workspace = workspace }, .{}),
    );
    try std.testing.expectEqual(
        fixed.len,
        (try into(&fixed, &output, .{ .workspace = workspace }, .{})).consumed,
    );
}

test "gzip overlap admission preserves caller storage and workspace before decode" {
    const workspace = try Workspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var source = fixed;
    const original = source;
    try std.testing.expectError(
        error.StorageOverlap,
        into(&source, source[10..], .{ .workspace = workspace }, .{}),
    );
    try std.testing.expectEqualSlices(u8, &original, &source);
    const state = std.mem.asBytes(workspace);
    @memcpy(state[0..fixed.len], &fixed);
    var output: [256]u8 = @splat(0xa5);
    try std.testing.expectError(
        error.StorageOverlap,
        into(state[0..fixed.len], &output, .{ .workspace = workspace }, .{}),
    );
    for (output) |byte| try std.testing.expectEqual(0xa5, byte);
    try std.testing.expectError(
        error.StorageOverlap,
        into(&fixed, state, .{ .workspace = workspace }, .{}),
    );
    try std.testing.expectEqualSlices(u8, &fixed, state[0..fixed.len]);
}

test "complete gzip member selection extent trailing data and limits remain independent" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const buffers: Storage = .{ .workspace = workspace };
    const joined = stored ++ stored;
    var output: [8]u8 = @splat(0xa5);
    const first = try into(&joined, output[0..3], buffers, .{ .output_size = .exact });
    try std.testing.expectEqual(@as(usize, 1), first.members);
    try std.testing.expectEqual(stored.len, first.consumed);
    try std.testing.expectEqualStrings("SVG", output[0..3]);
    try std.testing.expectError(
        error.InvalidStream,
        into(&joined, &output, buffers, .{ .trailing_data = .reject }),
    );
    const both = try into(&joined, &output, buffers, .{ .members = .concatenate });
    try std.testing.expectEqual(@as(usize, 2), both.members);
    try std.testing.expectEqualStrings("SVGSVG", output[0..both.produced]);
    try std.testing.expect(std.mem.allEqual(u8, output[6..], 0xa5));
    _ = try into(
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
        into(&joined, &output, buffers, .{ .members = .concatenate, .output_size = .exact }),
    );
    _ = try into(&joined, &output, buffers, .{ .limits = .{ .input_bytes = stored.len } });
    try std.testing.expectError(
        error.LimitExceeded,
        into(
            &joined,
            &output,
            buffers,
            .{ .members = .concatenate, .limits = .{ .input_bytes = stored.len } },
        ),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        into(
            &joined,
            &output,
            buffers,
            .{ .members = .concatenate, .limits = .{ .output_bytes = 5 } },
        ),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        into(
            &joined,
            &output,
            buffers,
            .{ .members = .concatenate, .limits = .{ .work_units = joined.len + 5 } },
        ),
    );
    try std.testing.expectError(
        error.HeaderTooLong,
        into(&stored, &output, buffers, .{ .header_limits = .{ .header_bytes = 9 } }),
    );
}

test "gzip exact single-member decoding preserves complete fixtures framing and guards" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
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
        for (0..16) |alignment| {
            @memset(backing, 0xa5);
            const output = backing[alignment + 1 ..][0..fixture.expected.len];
            const result = try into(
                fixture.source,
                output,
                .{ .workspace = workspace },
                .{ .members = .single, .output_size = .exact, .trailing_data = .reject },
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

        @memset(backing, 0xa5);
        try std.testing.expectError(
            error.InvalidStream,
            into(
                fixture.source,
                backing[1..][0 .. fixture.expected.len + 1],
                .{ .workspace = workspace },
                .{ .output_size = .exact },
            ),
        );
        if (fixture.expected.len != 0) {
            try std.testing.expectError(
                error.OutputTooSmall,
                into(
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
                into(
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
                into(
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
    const workspace = try Workspace.create(allocator);
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
        const storage: Storage = .{ .workspace = workspace };
        const output = backing[1..][0..fixture.expected.len];
        const work = fixture.source.len + fixture.expected.len;
        @memset(backing, 0xa5);
        const result = try into(
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
            into(
                fixture.source,
                output,
                storage,
                .{ .output_size = .exact, .limits = .{ .work_units = work - 1 } },
            ),
        );
        try std.testing.expectError(
            error.LimitExceeded,
            into(
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
            into(
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
                into(
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
            into(
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
        into(
            &empty,
            backing[1..33],
            .{ .workspace = workspace },
            .{ .output_size = .exact, .limits = .{ .work_units = empty.len } },
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, backing, 0xa5));
    try std.testing.expectError(
        error.LimitExceeded,
        into(
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
        into(
            following,
            backing[1..2],
            .{ .workspace = workspace },
            .{ .output_size = .exact, .limits = .{ .input_bytes = following.len - 1 } },
        ),
    );
    // The complete member's cumulative work refusal precedes an oversized exact destination.
    try std.testing.expectError(
        error.LimitExceeded,
        into(
            &stored,
            backing[1..5],
            .{ .workspace = workspace },
            .{ .output_size = .exact, .limits = .{ .work_units = stored.len + 2 } },
        ),
    );
    const joined = empty ++ stored ++ fixed ++ empty;
    const expected = "SVG" ++ fixture_text;
    const storage: Storage = .{ .workspace = workspace };
    @memset(backing, 0xa5);
    const output = backing[1..][0..expected.len];
    const result = try into(
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
        into(
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
    const first = try into(
        &joined,
        output[0..0],
        storage,
        .{ .members = .single, .output_size = .exact },
    );
    try std.testing.expectEqual(1, first.members);
    try std.testing.expectEqual(empty.len, first.consumed);
    try std.testing.expectEqual(0, first.produced);
}

test "exact short extent does not claim an unverified gzip trailer" {
    const workspace = try Workspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    // Independent gzip stored-block framing for "A", including CRC-32 0xd3d99e8b and size 1.
    const wire = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x01, 0x01, 0x00, 0xfe, 0xff,
        'A',  0x8b, 0x9e, 0xd9, 0xd3, 0x01, 0x00, 0x00, 0x00,
    };
    var bad = wire;
    bad[bad.len - 8] ^= 1;
    var output: [4]u8 = @splat(0xa5);
    const options: Options = .{ .output_size = .exact };
    // A short raw end does not validate the member's CRC or size.
    for ([_][]const u8{ &wire, &bad, wire[0 .. wire.len - 1] }) |source| {
        try std.testing.expectError(
            error.InvalidStream,
            into(source, output[1..3], .{ .workspace = workspace }, options),
        );
    }
    const result = try into(&wire, output[1..2], .{ .workspace = workspace }, options);
    try std.testing.expectEqual(@as(usize, 1), result.produced);
    try std.testing.expectEqual(@as(u8, 'A'), output[1]);
    try std.testing.expectError(
        error.InvalidStream,
        into(&bad, output[1..2], .{ .workspace = workspace }, options),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        into(
            &wire,
            output[1..2],
            .{ .workspace = workspace },
            .{ .output_size = .exact, .limits = .{ .input_bytes = wire.len - 1 } },
        ),
    );
    try std.testing.expectEqual(@as(u8, 0xa5), output[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), output[3]);
}

test {
    _ = Header;
    _ = Member;
    _ = StreamDecoder;
}
