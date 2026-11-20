//! A borrowed SFNT font-table directory. Opening admits the complete record array and each opaque
//! table range. Tags, table bodies and checksums remain available for explicit inspection; glyph
//! interpretation and complete-font policy belong to the caller.
//!
//! Keep complete immutable source alive through the last directory or table borrow, including the
//! whole collection when offsets are collection-absolute. Construct with open/openAt and preserve
//! the admitted fields.

const std = @import("std");
const binary = @import("../common/font_binary.zig");
const directory_layout = @import("directory_layout.zig");
const checksums = @import("checksums.zig");
const fixtures = @import("fixtures.zig");

const Directory = @This();

/// Complete immutable source, shared by all payload borrows.
source: []const u8,
/// Absolute position of this directory within source.
offset: usize,
/// Recognized container signature, copied independently of source storage.
flavor: Flavor,
/// Number of complete range-admitted table records.
table_count: u16,
/// Borrowed sixteen-byte records in encoded order; preserve this admitted span.
table_records: []const u8,
/// Whether tags are nondecreasing, selecting binary search instead of a linear scan.
tags_ordered: bool,

/// Truncated or malformed directory/table bounds, or an unsupported directory signature.
pub const OpenError = binary.Error || error{UnsupportedFormat};

/// More than one directory record has the requested tag. Missing tags return null.
pub const LookupError = error{AmbiguousTag};

/// Four exact tag bytes, including significant spaces and case. Payload interpretation belongs to
/// the table's reader; raw inspection also preserves tags outside the standard printable range.
pub const Tag = [4]u8;

/// Recognized directory signatures. The signature describes the container's declared outline
/// technology; opening a directory does not establish that such outlines exist or can be decoded.
pub const Flavor = enum(u32) {
    truetype = 0x00010000,
    apple_truetype = 0x74727565,
    opentype_cff = 0x4f54544f,
    apple_type1 = 0x74797031,
};

/// A copied directory record and its borrowed, range-checked table bytes. Different records may
/// borrow overlapping or identical storage. The declared checksum is not checked during opening.
pub const Table = struct {
    /// Exact case-sensitive table identifier, copied from its record.
    tag: Tag,
    /// Stored checksum declaration; opening does not verify it.
    checksum: u32,
    /// Payload position relative to the complete source, including a collection's header.
    offset: u32,
    /// Exact table bytes borrowed from immutable source, excluding any external padding.
    data: []const u8,

    /// Computes this table's padded wrapping checksum, treating head.checkSumAdjustment as zero.
    /// Contents remain opaque; a short head payload is not admitted as a usable font header.
    pub fn computedChecksum(self: Table) u32 {
        if (!std.mem.eql(u8, &self.tag, "head")) return checksums.checksum(self.data);
        // The adjustment is the four-byte checksum word at logical offset 8. Excluding it leaves
        // the borrowed bytes intact; a short opaque head may end inside that word.
        const adjustment_start = @min(8, self.data.len);
        const adjustment_end = @min(12, self.data.len);
        const prefix = self.data[0..adjustment_start];
        const suffix = self.data[adjustment_end..];
        return checksums.checksum(prefix) +% checksums.checksum(suffix);
    }

    /// Compares the directory's declared checksum with the computed table checksum. This scans the
    /// table's bytes and provides accidental-corruption detection, not authentication.
    pub fn checksumMatches(self: Table) bool {
        return self.checksum == self.computedChecksum();
    }

    test "SFNT checksums use big-endian padded words and exclude only head adjustment" {
        const bytes = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 };
        try std.testing.expectEqual(0x1c121518, checksums.checksum(&bytes));
        const head: Table = .{
            .tag = "head".*,
            .checksum = 0x13080a0c,
            .offset = 0,
            .data = &bytes,
        };
        try std.testing.expectEqual(0x13080a0c, head.computedChecksum());
        try std.testing.expect(head.checksumMatches());
        try std.testing.expectEqual(0, checksums.checksum(&.{}));
        try std.testing.expectEqual(0x01020300, checksums.checksum(&.{ 1, 2, 3 }));
        try std.testing.expectEqual(
            0xfffffffe,
            checksums.checksum(&.{ 255, 255, 255, 255, 255, 255, 255, 255 }),
        );
        // Include payloads that end within the adjustment word, not just complete head tables.
        for (0..bytes.len) |length| {
            const short: Table = .{
                .tag = "head".*,
                .checksum = 0,
                .offset = 0,
                .data = bytes[0..length],
            };
            var cleared = bytes;
            @memset(cleared[8..12], 0);
            try std.testing.expectEqual(
                checksums.checksum(cleared[0..length]),
                short.computedChecksum(),
            );
        }
    }
};

/// Opens a standalone directory at byte zero, checking its signature and every table range. Empty
/// directories are valid for raw inspection. Encoded search accelerator fields are ignored; record
/// order is observed directly. This scans records without scanning payloads.
pub fn open(source: []const u8) OpenError!Directory {
    return openAt(source, 0);
}

test open {
    // Authored table storage; not a complete renderable font.
    const source = storage: {
        var bytes: [64]u8 = @splat(0);
        std.mem.writeInt(u32, bytes[0..4], 0x00010000, .big);
        std.mem.writeInt(u16, bytes[4..6], 2, .big);
        @memset(bytes[6..12], 255); // Search accelerators are ignored.
        @memcpy(bytes[12..16], "DATA");
        @memcpy(bytes[28..32], "ZZZZ");
        for ([_]usize{ 12, 28 }) |record_offset| {
            std.mem.writeInt(u32, bytes[record_offset + 4 ..][0..4], 0x01020300, .big);
            std.mem.writeInt(u32, bytes[record_offset + 8 ..][0..4], 49, .big);
            std.mem.writeInt(u32, bytes[record_offset + 12 ..][0..4], 3, .big);
        }
        @memcpy(bytes[49..52], &[_]u8{ 1, 2, 3 });
        break :storage bytes;
    };
    const directory = try Directory.open(&source);
    const entry = (try directory.find("DATA".*)).?;
    try std.testing.expectEqual(2, directory.table_count);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, entry.data);
    try std.testing.expect(entry.checksumMatches());
    try std.testing.expectEqual(null, try directory.find("name".*));
}

/// Opens a directory at an absolute position within complete SFNT/TTC/OTC bytes. Table offsets stay
/// absolute in source. Caller-supplied enclosing storage defines the allowed ranges. A failure
/// publishes no view and leaves source unchanged.
pub fn openAt(source: []const u8, offset: usize) OpenError!Directory {
    const records_end = try directory_layout.endOffset(source, offset);
    const signature = try binary.read(u32, source, offset);
    const flavor = std.enums.fromInt(Flavor, signature) orelse return error.UnsupportedFormat;
    const table_count = try binary.read(u16, source, offset + 4);
    const records = source[offset + directory_layout.header_size .. records_end];
    var ordered_records = true;
    var previous_tag: u32 = 0;

    // Inspect the actual tag order because the stored search accelerators are not trusted. Admit
    // every payload range here so indexed access can borrow it without rescanning.
    for (0..table_count) |index| {
        const record_start = index * directory_layout.record_size;
        const record = records[record_start..][0..directory_layout.record_size];
        const record_tag = std.mem.readInt(u32, record[0..4], .big);
        if (index != 0 and record_tag < previous_tag) ordered_records = false;
        previous_tag = record_tag;
        const table_offset = std.mem.readInt(u32, record[8..12], .big);
        const table_bytes = std.mem.readInt(u32, record[12..16], .big);
        _ = try binary.slice(source, table_offset, table_bytes);
    }

    return .{
        .source = source,
        .offset = offset,
        .flavor = flavor,
        .table_count = table_count,
        .table_records = records,
        .tags_ordered = ordered_records,
    };
}

/// Copies one directory record and borrows its prechecked payload. Null means index is outside
/// table_count. Enumeration preserves file order, including repeated tags.
pub fn table(self: Directory, index: usize) ?Table {
    if (index >= self.table_count) return null;
    const record_offset = index * directory_layout.record_size;
    const record = self.table_records[record_offset..][0..directory_layout.record_size];
    const table_offset = std.mem.readInt(u32, record[8..12], .big);
    const table_bytes = std.mem.readInt(u32, record[12..16], .big);
    return .{
        .tag = record[0..4].*,
        .checksum = std.mem.readInt(u32, record[4..8], .big),
        .offset = table_offset,
        .data = self.source[table_offset..][0..table_bytes],
    };
}

/// Selects the sole matching table, returning null for absence or AmbiguousTag for duplicates.
/// Ordered directories use lower-bound binary search; unordered directories use a bounded scan. No
/// encoded accelerator fields, allocations or mutable lookup caches are used.
pub fn find(self: Directory, tag: Tag) LookupError!?Table {
    const wanted = std.mem.readInt(u32, &tag, .big);
    if (self.tags_ordered) {
        var low: usize = 0;
        var high: usize = self.table_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.tagWordAt(middle) < wanted) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }

        if (low == self.table_count or self.tagWordAt(low) != wanted) return null;
        // Equal tags are adjacent in an ordered directory, so the next record settles ambiguity.
        const duplicate = low + 1 < self.table_count and self.tagWordAt(low + 1) == wanted;
        if (duplicate) return error.AmbiguousTag;
        return self.table(low);
    }

    var selected: ?usize = null;
    for (0..self.table_count) |index| {
        if (self.tagWordAt(index) != wanted) continue;
        if (selected != null) return error.AmbiguousTag;
        selected = index;
    }
    return if (selected) |index| self.table(index) else null;
}

fn tagWordAt(self: Directory, index: usize) u32 {
    return std.mem.readInt(
        u32,
        self.table_records[index * directory_layout.record_size ..][0..4],
        .big,
    );
}

test "SFNT directories borrow opaque unaligned tables without requiring font semantics" {
    const source = fixtures.twoTables();
    const original = source;
    const directory = try Directory.open(&source);
    try std.testing.expect(directory.tags_ordered);
    // Both records borrow the same unaligned payload instead of copying it.
    const first = directory.table(0).?;
    try std.testing.expectEqualStrings("DATA", &first.tag);
    try std.testing.expectEqual(49, first.offset);
    try std.testing.expectEqual(@intFromPtr(&source) + 49, @intFromPtr(first.data.ptr));
    try std.testing.expectEqual(null, directory.table(2));
    try std.testing.expectEqual(null, directory.table(std.math.maxInt(usize)));
    const shared = directory.table(1).?;
    try std.testing.expectEqual(first.data.ptr, shared.data.ptr);
    try std.testing.expectEqualSlices(u8, &original, &source);
}

test "SFNT signature and table range admission handles every truncation and zero tables" {
    const source = fixtures.twoTables();
    for (0..52) |length|
        try std.testing.expectError(error.InvalidFont, Directory.open(source[0..length]));
    for ([_]Flavor{ .truetype, .apple_truetype, .opentype_cff, .apple_type1 }) |flavor| {
        var empty: [12]u8 = @splat(255);
        fixtures.write(u32, &empty, 0, @backingInt(flavor));
        fixtures.write(u16, &empty, 4, 0);
        const directory = try Directory.open(&empty);
        try std.testing.expectEqual(flavor, directory.flavor);
        try std.testing.expectEqual(null, try directory.find("head".*));
    }
    var invalid = source;
    fixtures.write(u32, &invalid, 0, 0);
    try std.testing.expectError(error.UnsupportedFormat, Directory.open(&invalid));
    invalid = source;
    fixtures.write(u32, &invalid, 20, 0xffffffff);
    try std.testing.expectError(error.InvalidFont, Directory.open(&invalid));
    invalid = source;
    fixtures.write(u32, &invalid, 24, 0xffffffff);
    try std.testing.expectError(error.InvalidFont, Directory.open(&invalid));
    try std.testing.expectError(
        error.InvalidFont,
        Directory.openAt(&source, std.math.maxInt(usize)),
    );
}

test "SFNT lookup detects duplicate tags in ordered and unordered directories" {
    var source = fixtures.twoTables();
    @memcpy(source[28..32], "DATA");
    const ordered = try Directory.open(&source);
    try std.testing.expect(ordered.tags_ordered);
    try std.testing.expectError(error.AmbiguousTag, ordered.find("DATA".*));
    try std.testing.expectEqual(2, ordered.table_count);

    @memcpy(source[12..16], "ZZZZ");
    @memcpy(source[28..32], "AAAA");
    const unordered = try Directory.open(&source);
    try std.testing.expect(!unordered.tags_ordered);
    try std.testing.expectEqualStrings("AAAA", &(try unordered.find("AAAA".*)).?.tag);
    try std.testing.expectEqual(null, try unordered.find("ZZZY".*));

    // Unordered duplicates can be separated by another tag and still make lookup ambiguous.
    var three: [80]u8 = @splat(0);
    fixtures.write(u32, &three, 0, 0x00010000);
    fixtures.write(u16, &three, 4, 3);
    inline for (.{ "DATA", "AAAA", "DATA" }, 0..) |tag, index| {
        @memcpy(three[12 + index * 16 ..][0..4], tag);
        fixtures.write(u32, &three, 20 + index * 16, three.len);
    }
    const ambiguous = try Directory.open(&three);
    try std.testing.expect(!ambiguous.tags_ordered);
    try std.testing.expectError(error.AmbiguousTag, ambiguous.find("DATA".*));
    try std.testing.expectEqual(0, (try ambiguous.find("AAAA".*)).?.data.len);
}

test "SFNT raw tags and empty end extents remain enumerable" {
    var source = fixtures.twoTables();
    @memset(source[12..16], 0);
    fixtures.write(u32, &source, 20, source.len);
    fixtures.write(u32, &source, 24, 0);
    const directory = try Directory.open(&source);
    const empty = (try directory.find(.{ 0, 0, 0, 0 })).?;
    try std.testing.expectEqual(0, empty.data.len);
    try std.testing.expectEqual(@intFromPtr(&source) + source.len, @intFromPtr(empty.data.ptr));
}

test "SFNT extracts opaque CFF table bytes without interpreting glyphs" {
    // Independently framed single-glyph CFF1: move (0, 0), line (+10, 0), endchar.
    const cff_bytes = [_]u8{
        1, 0, 4,   1,   0,  1,   1,   1, 2,  'A', 0, 1, 1, 1, 5, 28, 0, 23, 17, 0, 0, 0, 0, 0, 1, 1,
        1, 8, 139, 139, 21, 149, 139, 5, 14,
    };
    var source: [80]u8 = @splat(0);
    fixtures.write(u32, &source, 0, 0x4f54544f);
    fixtures.write(u16, &source, 4, 1);
    @memcpy(source[12..16], "CFF ");
    fixtures.write(u32, &source, 20, 40);
    fixtures.write(u32, &source, 24, cff_bytes.len);
    @memcpy(source[40..][0..cff_bytes.len], &cff_bytes);
    const directory = try Directory.open(&source);
    const cff_table = (try directory.find("CFF ".*)).?;
    try std.testing.expectEqual(.opentype_cff, directory.flavor);
    try std.testing.expectEqualSlices(u8, &cff_bytes, cff_table.data);
    try std.testing.expectEqual(@intFromPtr(&source) + 40, @intFromPtr(cff_table.data.ptr));
    try std.testing.expectEqual(40, cff_table.offset);
    try std.testing.expectEqualSlices(u8, "CFF ", &cff_table.tag);
    try std.testing.expectEqual(0, cff_table.checksum);
    try std.testing.expectEqual(null, try directory.find("CFF2".*));
}

test {
    _ = Table;
    _ = binary;
    _ = directory_layout;
}
