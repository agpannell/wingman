//! Borrowed KTX2 key/value metadata. Keys are sorted unique UTF-8 strings; values remain opaque
//! binary bytes, including any stored terminators in those values. Open the metadata section alone
//! or use Container.metadata after complete-file admission. Neither workflow allocates.
//!
//! Copies and independent iterators share immutable encoded backing. Keep admitted fields and those
//! bytes unchanged through the last query. Recognition of an animation header checks only its key
//! and twelve-byte value length; interpreting its timing fields belongs to the application.
const std = @import("std");
const ktx2 = @import("../ktx2.zig");
const layout = @import("layout.zig");
const Metadata = @This();

/// Complete borrowed metadata section, including record lengths, key terminators and padding.
data: []const u8,
/// Number of admitted key/value records.
entry_count: usize,
/// Whether KTXanimData has a twelve-byte value, enabling structural BasisLZ animation-flag checks.
has_animation_header: bool,

/// Malformed framing/key order or a metadata-byte/entry limit exceeded.
pub const OpenError = error{ InvalidKtx2, LimitExceeded };

/// One borrowed key/value pair, also used for supplied metadata in TextureInput. Both spans remain
/// immutable through queries or writing; a writer supplies framing and the key's stored terminator.
pub const Entry = struct {
    /// Nonempty UTF-8 key without its stored NUL terminator. Keys are unique and increasing in
    /// UTF-8 byte order, which agrees with Unicode scalar ordering; a leading UTF-8 BOM is
    /// forbidden.
    key: []const u8,
    /// Opaque bytes after the key terminator, excluding wire padding; embedded zero bytes are
    /// valid.
    value: []const u8,
};

/// Independent traversal of admitted entries; advancing does not invalidate earlier borrowed pairs.
pub const Iterator = struct {
    /// Remaining admitted records; advance only with next and keep the backing immutable.
    remaining: []const u8,

    /// Returns the next borrowed record, or null at the exact metadata boundary.
    pub fn next(self: *Iterator) ?Entry {
        if (self.remaining.len == 0) return null;
        const size = read(u32, self.remaining, 0);
        const data = self.remaining[4..][0..size];
        const terminator = std.mem.indexOfScalar(u8, data, 0).?;
        const padded = (4 - size % 4) % 4;
        self.remaining = self.remaining[4 + @as(usize, size) + padded ..];
        return .{ .key = data[0..terminator], .value = data[terminator + 1 ..] };
    }
};

/// Admits exact records, zero padding and sorted unique keys under the metadata-byte/entry limits.
/// The empty section is valid. Other Options limits apply to the enclosing container.
pub fn open(data: []const u8, options: ktx2.Options) OpenError!Metadata {
    if (data.len > options.limits.maximum_metadata_bytes) return error.LimitExceeded;
    var remaining = data;
    var previous: ?[]const u8 = null;
    var result: Metadata = .{ .data = data, .entry_count = 0, .has_animation_header = false };
    while (remaining.len != 0) {
        if (result.entry_count == options.limits.maximum_metadata_entries)
            return error.LimitExceeded;
        if (remaining.len < 4) return error.InvalidKtx2;
        const size: usize = read(u32, remaining, 0);
        remaining = remaining[4..];
        if (size < 2 or size > remaining.len) return error.InvalidKtx2;
        const entry_data = remaining[0..size];
        const terminator = std.mem.indexOfScalar(u8, entry_data, 0) orelse return error.InvalidKtx2;
        const entry: Entry = .{
            .key = entry_data[0..terminator],
            .value = entry_data[terminator + 1 ..],
        };
        try layout.validateMetadataKey(entry, previous);
        if (layout.isAnimationHeader(entry)) result.has_animation_header = true;
        previous = entry.key;
        const padding = (4 - size % 4) % 4;
        if (padding > remaining.len - size) return error.InvalidKtx2;
        try layout.zeroPadding(remaining, size, size + padding);
        remaining = remaining[size + padding ..];
        result.entry_count += 1;
    }
    return result;
}

/// Starts a fresh traversal of the complete admitted metadata section.
pub fn iterator(self: Metadata) Iterator {
    return .{ .remaining = self.data };
}

fn read(comptime T: type, data: []const u8, offset: usize) T {
    return std.mem.readInt(T, data[offset..][0..@divExact(@bitSizeOf(T), 8)], .little);
}

test open {
    const metadata = try Metadata.open(&entries_bytes, .{});
    try std.testing.expectEqual(2, metadata.entry_count);
    try std.testing.expect(!metadata.has_animation_header);
    var entries = metadata.iterator();
    const first = entries.next().?;
    try std.testing.expectEqualStrings("a", first.key);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0 }, first.value);
    try std.testing.expect(first.key.ptr == entries_bytes[4..].ptr);
    const second = entries.next().?;
    try std.testing.expectEqualStrings("é", second.key);
    try std.testing.expectEqual(0, second.value.len);
    try std.testing.expectEqual(null, entries.next());
    var independent = metadata.iterator();
    try std.testing.expectEqualStrings("a", independent.next().?.key);
    try std.testing.expectEqual(0, (try Metadata.open(&.{}, .{})).entry_count);
}

test "metadata admission bounds records, padding, key order and caller limits" {
    for (0..entries_bytes.len) |size| {
        if (size == 0 or size == 12) continue; // Complete record boundaries are valid sections.
        try std.testing.expectError(error.InvalidKtx2, Metadata.open(entries_bytes[0..size], .{}));
    }
    for ([_]usize{ 0, 4, 5, 9, 12, 16, 19 }) |offset| {
        var changed = entries_bytes;
        changed[offset] = 0xff;
        try std.testing.expectError(error.InvalidKtx2, Metadata.open(&changed, .{}));
    }
    for ([_]u8{ 'A', 'a' }) |second_key| {
        var unordered = entries_bytes;
        unordered[16..18].* = .{ second_key, 0 }; // Decreasing and duplicate keys.
        try std.testing.expectError(error.InvalidKtx2, Metadata.open(&unordered, .{}));
    }
    try std.testing.expectError(
        error.LimitExceeded,
        Metadata.open(&entries_bytes, .{ .limits = .{ .maximum_metadata_entries = 1 } }),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        Metadata.open(
            &entries_bytes,
            .{ .limits = .{ .maximum_metadata_bytes = entries_bytes.len - 1 } },
        ),
    );
    const animation_bytes = [_]u8{
        24, 0, 0, 0, 'K', 'T', 'X', 'a', 'n', 'i', 'm', 'D', 'a', 't', 'a', 0, 0, 0, 0, 0, 0, 0, 0,
        0,  0, 0, 0, 0,
    };
    try std.testing.expect((try Metadata.open(&animation_bytes, .{})).has_animation_header);
    var short_animation = animation_bytes;
    short_animation[0] = 23; // Eleven value bytes plus one padding byte is framed but not a header.
    try std.testing.expect(!(try Metadata.open(&short_animation, .{})).has_animation_header);
}

// Two independently framed entries: a binary value and an empty value, with zero wire padding.
const entries_bytes = [_]u8{
    0x05, 0x00, 0x00, 0x00, 0x61, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
    0xc3, 0xa9, 0x00, 0x00,
};
