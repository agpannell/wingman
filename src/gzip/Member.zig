//! A verified gzip member returned by Iterator. Iteration restores and checks each member before
//! publishing its header and byte counts. Metadata views borrow the iterator's encoded source;
//! restored bytes remain in the caller's output span.

const std = @import("std");
const deflate = @import("../deflate.zig");
const Header = @import("Header.zig");
const member_decoding = @import("member_decode.zig");
const byte_ranges = @import("../common/byte_ranges.zig");
const fixtures = @import("decode_fixtures.zig");

const Member = @This();
const overlaps = byte_ranges.overlaps;

/// Borrowed header metadata for this member.
header: Header,
/// Byte counts relative to the member and supplied output.
result: deflate.decode.Result,

/// Selection of first-member completion, explicit iteration, or automatic aggregation.
/// Concatenation requires EOF and refuses trailing garbage.
pub const Selection = enum {
    /// Finish after one verified member, leaving following input unconsumed.
    single,
    /// Return a verified member_end boundary after each member until nextMember is called.
    iterate,
    /// Decode all members until explicit EOF, rejecting trailing garbage.
    concatenate,
};

/// Iterates complete-buffer members. Set `source` to the complete encoded input and leave
/// `position` at zero. `next` advances only after full validation, returns null at the exact source
/// end, and rejects trailing garbage. Output/workspace can be reused between calls.
pub const Iterator = struct {
    /// Header admission, payload recovery and output storage failures for one member.
    pub const Error = Header.Error || member_decoding.Error;

    /// Source borrow retained by this iterator and returned header views.
    source: []const u8,
    /// Next member offset; initialized to zero.
    position: usize = 0,
    /// Admission limits applied independently to each member header.
    header_limits: Header.Limits = .{},

    /// Decodes the next member into caller storage, without allocation.
    pub fn next(self: *Iterator, output: []u8, workspace: *deflate.decode.Workspace) Error!?Member {
        if (overlaps(std.mem.asBytes(self), self.source)) return error.StorageOverlap;
        if (overlaps(std.mem.asBytes(self), output)) return error.StorageOverlap;
        if (overlaps(
            std.mem.asBytes(self),
            std.mem.asBytes(workspace),
        )) return error.StorageOverlap;
        if (self.position == self.source.len) return null;
        if (self.position > self.source.len) return error.InvalidStream;
        const source = self.source[self.position..];
        const parsed = try Header.parse(source, self.header_limits);
        // Header parsing has the same priority as metadata iteration's admission. Refuse overlap
        // across the complete encoded span before raw payload decoding changes output or tables.
        if (overlaps(source, output)) return error.StorageOverlap;
        if (overlaps(source, std.mem.asBytes(workspace))) return error.StorageOverlap;
        if (overlaps(output, std.mem.asBytes(workspace))) return error.StorageOverlap;
        const result = try member_decoding.verify(source, output, workspace, parsed, .{});
        // Include header/trailer bytes in the complete member's default u64 work allowance.
        if (result.consumed > std.math.maxInt(
            u64,
        ) or result.produced > std.math.maxInt(u64) - result.consumed) return error.LimitExceeded;
        self.position += result.consumed;
        return .{ .header = parsed.header, .result = result };
    }
};

test Iterator {
    const workspace = try deflate.decode.Workspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    const combined = fixtures.stored ++ fixtures.empty ++ fixtures.fixed;
    var output: [256]u8 = undefined;
    var iterator: Iterator = .{ .source = &combined };
    var count: usize = 0;
    while (try iterator.next(&output, workspace)) |_| count += 1;
    try std.testing.expectEqual(3, count);
    try std.testing.expectEqual(combined.len, iterator.position);

    // Failed verification cannot publish a member or advance the retained source boundary.
    const with_garbage = fixtures.stored ++ "trailing";
    iterator = .{ .source = with_garbage };
    const first = (try iterator.next(&output, workspace)).?;
    try std.testing.expectEqual(fixtures.stored.len, first.result.consumed);
    try std.testing.expectEqualStrings("SVG", output[0..first.result.produced]);
    try std.testing.expectError(error.InvalidStream, iterator.next(&output, workspace));
    try std.testing.expectEqual(fixtures.stored.len, iterator.position);
}

test "gzip iteration admits headers before overlapping payload storage" {
    const workspace = try deflate.decode.Workspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var source = fixtures.optional_fields;
    // Both header CRC failure and header bounds precede payload/output overlap admission.
    source[39] ^= 1;
    const corrupted = source;
    var iterator: Iterator = .{ .source = &source };
    try std.testing.expectError(error.InvalidStream, iterator.next(source[41..], workspace));
    try std.testing.expectEqual(0, iterator.position);
    try std.testing.expectEqualSlices(u8, &corrupted, &source);
    source = fixtures.optional_fields;
    iterator.header_limits = .{ .field_bytes = 8 };
    try std.testing.expectError(error.HeaderTooLong, iterator.next(source[41..], workspace));
    try std.testing.expectEqual(0, iterator.position);
    iterator.header_limits = .{};
    try std.testing.expectError(error.StorageOverlap, iterator.next(source[41..], workspace));
    try std.testing.expectEqual(0, iterator.position);
    try std.testing.expectEqualSlices(u8, &fixtures.optional_fields, &source);

    // Successful iteration publishes the original source views only after payload verification.
    var output: [fixtures.fixture_text.len]u8 = undefined;
    const member = (try iterator.next(&output, workspace)).?;
    try std.testing.expectEqualStrings(fixtures.fixture_text, &output);
    try std.testing.expectEqual(source[16..25].ptr, member.header.name.?.ptr);
    try std.testing.expectEqual(source[26..38].ptr, member.header.comment.?.ptr);
    try std.testing.expectEqual(source.len, member.result.consumed);
    try std.testing.expectEqual(source.len, iterator.position);
    try std.testing.expectEqual(null, try iterator.next(&output, workspace));
}
