//! Inspect SFNT font tables and TTC/OTC collections without allocating or interpreting glyphs.
//!
//! An SFNT directory names each table with a four-byte tag and an absolute byte range. Use
//! `Directory.open` for a standalone file or `Collection.open` to select a collection member.
//! Opening a directory admits every table range; its payloads remain opaque. No character map,
//! outline or metric table is required. Unknown tags, duplicate records and shared payloads remain
//! inspectable. Tag lookup reports ambiguity instead of choosing between duplicate records.
//!
//! Views borrow complete immutable source bytes and need no cleanup. Keep that backing alive and
//! unchanged through the last table borrow. Collection table offsets remain relative to the
//! complete collection, even when the selected directory starts at a nonzero offset. Opening checks
//! structure, with checksum verification available separately; it does not sanitize or authenticate
//! a font.
//!
//! Reference: https://learn.microsoft.com/en-us/typography/opentype/spec/otff

const std = @import("std");
const binary = @import("common/font_binary.zig");

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

/// Invalid/truncated framing, an unsupported signature/version, an out-of-range face selection or a
/// tag lookup with more than one matching record. Missing tags return null.
pub const Error = error{ InvalidFont, UnsupportedFormat, InvalidFace, AmbiguousTag };

/// Required wrapping sum of all padded big-endian words in a complete standalone SFNT file,
/// including its stored head.checkSumAdjustment. This rule does not apply to TTC/OTC collections.
pub const checksum_target = 0xb1b0afba;

const header_size = 12;
const record_size = 16;
const collection_tag = 0x74746366;
const signature_tag = 0x44534947;

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
        if (!std.mem.eql(u8, &self.tag, "head")) return checksumWords(self.data);
        const adjustment_start = @min(8, self.data.len);
        const adjustment_end = @min(12, self.data.len);
        const prefix = self.data[0..adjustment_start];
        const suffix = self.data[adjustment_end..];
        return checksumWords(prefix) +% checksumWords(suffix);
    }

    /// Compares the directory's declared checksum with the computed table checksum. This scans the
    /// table's bytes and provides accidental-corruption detection, not authentication.
    pub fn checksumMatches(self: Table) bool {
        return self.checksum == self.computedChecksum();
    }
};

/// Range-admitted directory borrowing complete source bytes. Construct with open/openAt and retain
/// the returned fields unchanged. Table interpretation, tag syntax, padding/alignment requirements
/// and required-table/duplicate policy belong to the complete-font or table consumer.
pub const Directory = struct {
    /// Complete immutable source, shared by all payload borrows.
    source: []const u8,
    /// Absolute position of this directory within source.
    offset: usize,
    /// Recognized container signature, copied independently of source storage.
    flavor: Flavor,
    /// Number of complete range-admitted table records.
    table_count: u16,
    /// Borrowed sixteen-byte records in encoded order; preserve this admitted span.
    records: []const u8,
    /// Whether tags are nondecreasing, selecting binary search instead of a linear scan.
    ordered: bool,

    /// Opens a standalone directory at byte zero, checking its signature and every table range.
    /// Empty directories are valid for raw inspection. Encoded search accelerator fields are
    /// ignored; record order is observed directly. This scans records without scanning payloads.
    pub fn open(source: []const u8) Error!Directory {
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

    /// Opens a directory at an absolute position within complete SFNT/TTC/OTC bytes. Table offsets
    /// stay absolute in source. Caller-supplied enclosing storage defines the allowed ranges. A
    /// failure publishes no view and leaves source unchanged.
    pub fn openAt(source: []const u8, offset: usize) Error!Directory {
        const records_end = try directoryEnd(source, offset);
        const signature = try binary.read(u32, source, offset);
        const flavor = std.enums.fromInt(Flavor, signature) orelse return error.UnsupportedFormat;
        const table_count = try binary.read(u16, source, offset + 4);
        const records = source[offset + header_size .. records_end];
        var ordered_records = true;
        var previous_tag: u32 = 0;

        for (0..table_count) |index| {
            const record = records[index * record_size ..][0..record_size];
            const record_tag = std.mem.readInt(u32, record[0..4], .big);
            if (index != 0 and record_tag < previous_tag) ordered_records = false;
            previous_tag = record_tag;
            const table_offset = std.mem.readInt(u32, record[8..12], .big);
            const table_bytes = std.mem.readInt(u32, record[12..16], .big);
            _ = try tableSlice(source, table_offset, table_bytes);
        }

        return .{
            .source = source,
            .offset = offset,
            .flavor = flavor,
            .table_count = table_count,
            .records = records,
            .ordered = ordered_records,
        };
    }

    /// Copies one directory record and borrows its prechecked payload. Null means index is outside
    /// table_count. Enumeration preserves file order, including repeated tags.
    pub fn table(self: Directory, index: usize) ?Table {
        if (index >= self.table_count) return null;
        const record_offset = index * record_size;
        const record = self.records[record_offset..][0..record_size];
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
    /// Ordered directories use lower-bound binary search; unordered directories use a bounded scan.
    /// No encoded accelerator fields, allocations or mutable lookup caches are used.
    pub fn find(self: Directory, tag: Tag) Error!?Table {
        const wanted = std.mem.readInt(u32, &tag, .big);
        if (self.ordered) {
            var low: usize = 0;
            var high: usize = self.table_count;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (self.tagAt(middle) < wanted) {
                    low = middle + 1;
                } else {
                    high = middle;
                }
            }

            if (low == self.table_count or self.tagAt(low) != wanted) return null;
            const duplicate = low + 1 < self.table_count and self.tagAt(low + 1) == wanted;
            if (duplicate) return error.AmbiguousTag;
            return self.table(low);
        }

        var selected: ?usize = null;
        for (0..self.table_count) |index| {
            if (self.tagAt(index) != wanted) continue;
            if (selected != null) return error.AmbiguousTag;
            selected = index;
        }
        return if (selected) |index| self.table(index) else null;
    }

    fn tagAt(self: Directory, index: usize) u32 {
        return std.mem.readInt(u32, self.records[index * record_size ..][0..4], .big);
    }
};

/// Borrowed TTC/OTC framing. Opening checks every directory extent and optional digital-signature
/// range; selecting a member admits its table ranges. Unsupported or malformed selected payloads do
/// not change this view or prevent another structurally valid member from being selected.
pub const Collection = struct {
    /// Complete immutable collection bytes, also borrowed by selected directories.
    source: []const u8,
    /// Borrowed array of big-endian absolute directory offsets; preserve its admitted extent.
    face_offsets: []const u8,
    /// Nonzero directory count; recorded aliases remain separate face selections.
    face_count: u32,
    /// Copied framing version; version two carries a digital-signature descriptor.
    version: Version,
    /// Optional borrowed DSIG bytes, range-checked without interpreting or authenticating them.
    signature: ?[]const u8,

    /// TTC/OTC header version; version two adds a digital-signature descriptor.
    pub const Version = enum(u32) { v1 = 0x00010000, v2 = 0x00020000 };

    /// Opens version 1/2 framing without interpreting any member's tables. Every directory must
    /// fit, even if the caller will select only one face. Signature bytes are range-checked without
    /// cryptographic authentication. Work is linear in the face count, including aliased offsets.
    pub fn open(source: []const u8) Error!Collection {
        if (source.len < header_size) return error.InvalidFont;
        if (try binary.read(u32, source, 0) != collection_tag) return error.UnsupportedFormat;
        const version = std.enums.fromInt(
            Version,
            try binary.read(u32, source, 4),
        ) orelse return error.UnsupportedFormat;
        const face_count = try binary.read(u32, source, 8);
        if (face_count == 0) return error.InvalidFont;
        const face_count_usize = std.math.cast(usize, face_count) orelse return error.InvalidFont;
        const face_offsets_end = try binary.arrayOffset(header_size, face_count_usize, 4);
        const signature_descriptor_count: usize = @intFromBool(version == .v2);
        const header_end = try binary.arrayOffset(face_offsets_end, signature_descriptor_count, 12);
        if (header_end > source.len) return error.InvalidFont;

        const signature_bytes: ?[]const u8 = blk: {
            if (version == .v1) break :blk null;
            const signature_kind = try binary.read(u32, source, face_offsets_end);
            const signature_length = try binary.read(u32, source, face_offsets_end + 4);
            const signature_offset = try binary.read(u32, source, face_offsets_end + 8);
            if (signature_kind == 0) {
                if (signature_length != 0 or signature_offset != 0) return error.InvalidFont;
                break :blk null;
            }
            if (signature_kind != signature_tag or signature_length == 0) return error.InvalidFont;
            break :blk try tableSlice(source, signature_offset, signature_length);
        };
        const face_offsets = source[header_size..face_offsets_end];
        for (0..face_count_usize) |index| {
            const directory_offset = std.mem.readInt(u32, face_offsets[index * 4 ..][0..4], .big);
            const directory_position = std.math.cast(
                usize,
                directory_offset,
            ) orelse return error.InvalidFont;
            _ = try directoryEnd(source, directory_position);
        }
        return .{
            .source = source,
            .face_offsets = face_offsets,
            .face_count = face_count,
            .version = version,
            .signature = signature_bytes,
        };
    }

    test open {
        // Authored collection framing with two directories and absolute table offsets.
        const source = storage: {
            var bytes: [104]u8 = @splat(0);
            @memcpy(bytes[0..4], "ttcf");
            std.mem.writeInt(u32, bytes[4..8], 0x00020000, .big);
            std.mem.writeInt(u32, bytes[8..12], 2, .big);
            std.mem.writeInt(u32, bytes[12..16], 36, .big);
            std.mem.writeInt(u32, bytes[16..20], 64, .big);
            inline for ([_]usize{
                36, 64,
            }, [_]u32{
                0x00010000, 0x4f54544f,
            }, [_]u32{
                92, 96,
            }) |directory_offset, signature, table_offset| {
                std.mem.writeInt(u32, bytes[directory_offset..][0..4], signature, .big);
                std.mem.writeInt(u16, bytes[directory_offset + 4 ..][0..2], 1, .big);
                @memcpy(bytes[directory_offset + 12 ..][0..4], "DATA");
                std.mem.writeInt(u32, bytes[directory_offset + 20 ..][0..4], table_offset, .big);
                std.mem.writeInt(u32, bytes[directory_offset + 24 ..][0..4], 3, .big);
            }
            @memcpy(bytes[92..95], &[_]u8{ 1, 2, 3 });
            @memcpy(bytes[96..99], &[_]u8{ 4, 5, 6 });
            break :storage bytes;
        };
        const collection = try Collection.open(&source);
        const second = try collection.face(1);
        try std.testing.expectEqual(2, collection.face_count);
        try std.testing.expectEqual(.opentype_cff, second.flavor);
        const data = (try second.find("DATA".*)).?.data;
        try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, data);
    }

    /// Admits one member directory and its opaque table ranges. Indices follow recorded order; an
    /// index outside face_count returns InvalidFace. The result borrows complete collection bytes,
    /// keeping its table offsets absolute. No font semantics or glyph data are decoded.
    pub fn face(self: Collection, index: u32) Error!Directory {
        if (index >= self.face_count) return error.InvalidFace;
        const offset_record_start = @as(usize, index) * 4;
        const directory_offset = std.mem.readInt(
            u32,
            self.face_offsets[offset_record_start..][0..4],
            .big,
        );
        return Directory.openAt(self.source, directory_offset);
    }
};

/// Adds big-endian words with unsigned wrap, virtually padding a final partial word with zero. Use
/// Table.computedChecksum for the head-table adjustment exception. This scans bytes without
/// allocation, mutation, alignment assumptions or validation of their contents.
pub fn checksum(source: []const u8) u32 {
    return checksumWords(source);
}

test checksum {
    try std.testing.expectEqual(0x06020304, checksum(&.{ 1, 2, 3, 4, 5 }));
    try std.testing.expectEqual(0, checksum(&.{}));
}

fn checksumWords(source: []const u8) u32 {
    var word_sum: u32 = 0;
    var word_offset: usize = 0;
    while (source.len - word_offset >= 4) : (word_offset += 4) {
        const word = std.mem.readInt(u32, source[word_offset..][0..4], .big);
        word_sum +%= word;
    }

    var partial_word: u32 = 0;
    for (source[word_offset..]) |byte| partial_word = (partial_word << 8) | byte;
    if (word_offset != source.len) {
        const partial_bytes = source.len - word_offset;
        const zero_padding_bytes = 4 - partial_bytes;
        const padding_bits: u5 = @intCast(zero_padding_bytes * 8);
        word_sum +%= partial_word << padding_bits;
    }
    return word_sum;
}

fn directoryEnd(source: []const u8, offset: usize) Error!usize {
    const header_end = try binary.arrayOffset(offset, 1, header_size);
    if (header_end > source.len) return error.InvalidFont;
    const table_count = try binary.read(u16, source, offset + 4);
    const records_end = try binary.arrayOffset(header_end, table_count, record_size);
    if (records_end > source.len) return error.InvalidFont;
    return records_end;
}

fn tableSlice(source: []const u8, offset: u32, length: u32) Error![]const u8 {
    const table_start = std.math.cast(usize, offset) orelse return error.InvalidFont;
    const table_bytes = std.math.cast(usize, length) orelse return error.InvalidFont;
    const table_end = try binary.arrayOffset(table_start, table_bytes, 1);
    if (table_end > source.len) return error.InvalidFont;
    return source[table_start..table_end];
}

test "SFNT checksums use big-endian padded words and exclude only head adjustment" {
    const bytes = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 };
    try std.testing.expectEqual(0x1c121518, checksum(&bytes));
    const head: Table = .{ .tag = "head".*, .checksum = 0x13080a0c, .offset = 0, .data = &bytes };
    try std.testing.expectEqual(0x13080a0c, head.computedChecksum());
    try std.testing.expect(head.checksumMatches());
    try std.testing.expectEqual(0, checksum(&.{}));
    try std.testing.expectEqual(0x01020300, checksum(&.{ 1, 2, 3 }));
    try std.testing.expectEqual(0xfffffffe, checksum(&.{ 255, 255, 255, 255, 255, 255, 255, 255 }));
    for (0..bytes.len) |length| {
        const short: Table = .{
            .tag = "head".*,
            .checksum = 0,
            .offset = 0,
            .data = bytes[0..length],
        };
        var cleared = bytes;
        @memset(cleared[8..12], 0);
        try std.testing.expectEqual(checksum(cleared[0..length]), short.computedChecksum());
    }
}

test "face directories and absolute ranges admit empty extents and reject truncation" {
    var bytes: [28]u8 = @splat(0);
    try std.testing.expectEqual(12, try directoryEnd(&bytes, 0));
    testing_sfnt.write(u16, &bytes, 4, 1);
    try std.testing.expectEqual(28, try directoryEnd(&bytes, 0));
    try std.testing.expectError(error.InvalidFont, directoryEnd(bytes[0..27], 0));
    try std.testing.expectError(error.InvalidFont, directoryEnd(&bytes, 17));
    try std.testing.expectError(error.InvalidFont, directoryEnd(&bytes, std.math.maxInt(usize)));
    try std.testing.expectEqualSlices(u8, bytes[8..12], try tableSlice(&bytes, 8, 4));
    try std.testing.expectEqual(0, (try tableSlice(&bytes, 28, 0)).len);
    try std.testing.expectError(error.InvalidFont, tableSlice(&bytes, 28, 1));
    try std.testing.expectError(error.InvalidFont, tableSlice(&bytes, 0xffffffff, 1));
}

test "SFNT directories borrow opaque unaligned tables without requiring font semantics" {
    const source = testing_sfnt.twoTables();
    const original = source;
    const directory = try Directory.open(&source);
    try std.testing.expect(directory.ordered);
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
    const source = testing_sfnt.twoTables();
    for (0..52) |length| {
        try std.testing.expectError(error.InvalidFont, Directory.open(source[0..length]));
    }
    for ([_]Flavor{ .truetype, .apple_truetype, .opentype_cff, .apple_type1 }) |flavor| {
        var empty: [12]u8 = @splat(255);
        testing_sfnt.write(u32, &empty, 0, @backingInt(flavor));
        testing_sfnt.write(u16, &empty, 4, 0);
        const directory = try Directory.open(&empty);
        try std.testing.expectEqual(flavor, directory.flavor);
        try std.testing.expectEqual(null, try directory.find("head".*));
    }
    var invalid = source;
    testing_sfnt.write(u32, &invalid, 0, 0);
    try std.testing.expectError(error.UnsupportedFormat, Directory.open(&invalid));
    invalid = source;
    testing_sfnt.write(u32, &invalid, 20, 0xffffffff);
    try std.testing.expectError(error.InvalidFont, Directory.open(&invalid));
    invalid = source;
    testing_sfnt.write(u32, &invalid, 24, 0xffffffff);
    try std.testing.expectError(error.InvalidFont, Directory.open(&invalid));
    try std.testing.expectError(
        error.InvalidFont,
        Directory.openAt(&source, std.math.maxInt(usize)),
    );
}

test "SFNT lookup detects duplicate tags in ordered and unordered directories" {
    var source = testing_sfnt.twoTables();
    @memcpy(source[28..32], "DATA");
    const ordered = try Directory.open(&source);
    try std.testing.expect(ordered.ordered);
    try std.testing.expectError(error.AmbiguousTag, ordered.find("DATA".*));
    try std.testing.expectEqual(2, ordered.table_count);

    @memcpy(source[12..16], "ZZZZ");
    @memcpy(source[28..32], "AAAA");
    const unordered = try Directory.open(&source);
    try std.testing.expect(!unordered.ordered);
    try std.testing.expectEqualStrings("AAAA", &(try unordered.find("AAAA".*)).?.tag);
    try std.testing.expectEqual(null, try unordered.find("ZZZY".*));

    var three: [80]u8 = @splat(0);
    testing_sfnt.write(u32, &three, 0, 0x00010000);
    testing_sfnt.write(u16, &three, 4, 3);
    inline for (.{ "DATA", "AAAA", "DATA" }, 0..) |tag, index| {
        @memcpy(three[12 + index * 16 ..][0..4], tag);
        testing_sfnt.write(u32, &three, 20 + index * 16, three.len);
    }
    const ambiguous = try Directory.open(&three);
    try std.testing.expect(!ambiguous.ordered);
    try std.testing.expectError(error.AmbiguousTag, ambiguous.find("DATA".*));
    try std.testing.expectEqual(0, (try ambiguous.find("AAAA".*)).?.data.len);
}

test "SFNT raw tags and empty end extents remain enumerable" {
    var source = testing_sfnt.twoTables();
    @memset(source[12..16], 0);
    testing_sfnt.write(u32, &source, 20, source.len);
    testing_sfnt.write(u32, &source, 24, 0);
    const directory = try Directory.open(&source);
    const empty = (try directory.find(.{ 0, 0, 0, 0 })).?;
    try std.testing.expectEqual(0, empty.data.len);
    try std.testing.expectEqual(@intFromPtr(&source) + source.len, @intFromPtr(empty.data.ptr));
}

test "SFNT collections select absolute shared table ranges and retain unsupported siblings" {
    var source = testing_sfnt.collection();
    const collection = try Collection.open(&source);
    try std.testing.expectEqual(.v2, collection.version);
    try std.testing.expectEqual(null, collection.signature);
    try std.testing.expectEqual(36, (try collection.face(0)).offset);
    try std.testing.expectEqual(64, (try collection.face(1)).offset);
    try std.testing.expectEqualSlices(u8, &.{
        1, 2, 3,
    }, (try (try collection.face(0)).find("DATA".*)).?.data);
    try std.testing.expectError(error.InvalidFace, collection.face(2));
    try std.testing.expectError(error.InvalidFace, collection.face(std.math.maxInt(u32)));
    try std.testing.expectError(error.UnsupportedFormat, Directory.open(&source));
    try std.testing.expectError(
        error.UnsupportedFormat,
        Collection.open(&testing_sfnt.twoTables()),
    );

    testing_sfnt.write(u32, &source, 64, 0xabcdef01);
    const mixed = try Collection.open(&source);
    try std.testing.expectEqual(.truetype, (try mixed.face(0)).flavor);
    try std.testing.expectError(error.UnsupportedFormat, mixed.face(1));

    testing_sfnt.write(u32, &source, 64, 0x4f54544f);
    testing_sfnt.write(u32, &source, 84, 0xffffffff);
    const malformed_payload = try Collection.open(&source);
    _ = try malformed_payload.face(0);
    try std.testing.expectError(error.InvalidFont, malformed_payload.face(1));
}

test "SFNT collection framing checks offsets versions signatures and every truncation" {
    const source = testing_sfnt.collection();
    for (0..92) |length| {
        try std.testing.expectError(error.InvalidFont, Collection.open(source[0..length]));
    }
    var signed = source;
    testing_sfnt.write(u32, &signed, 20, signature_tag);
    testing_sfnt.write(u32, &signed, 24, 4);
    testing_sfnt.write(u32, &signed, 28, 100);
    const signature = (try Collection.open(&signed)).signature.?;
    try std.testing.expectEqualSlices(u8, signed[100..104], signature);
    for (
        [_]struct {
            field: usize,
            value: u32,
            expected: Error,
        }{
            .{ .field = 4, .value = 0x00030000, .expected = error.UnsupportedFormat },
            .{ .field = 8, .value = 0, .expected = error.InvalidFont },
            .{ .field = 8, .value = 0xffffffff, .expected = error.InvalidFont },
            .{ .field = 12, .value = 0xfffffff0, .expected = error.InvalidFont },
            .{ .field = 20, .value = 1, .expected = error.InvalidFont },
            .{ .field = 24, .value = 0, .expected = error.InvalidFont },
            .{ .field = 28, .value = 0xffffffff, .expected = error.InvalidFont },
        },
    ) |case| {
        var invalid = signed;
        testing_sfnt.write(u32, &invalid, case.field, case.value);
        try std.testing.expectError(case.expected, Collection.open(&invalid));
    }
    var orphan = source;
    testing_sfnt.write(u32, &orphan, 24, 1);
    try std.testing.expectError(error.InvalidFont, Collection.open(&orphan));
    var version_one = source;
    testing_sfnt.write(u32, &version_one, 4, 0x00010000);
    try std.testing.expectEqual(.v1, (try Collection.open(&version_one)).version);
}

test "SFNT extracts opaque CFF table bytes without interpreting glyphs" {
    // Independently framed single-glyph CFF1: move (0, 0), line (+10, 0), endchar.
    const cff_bytes = [_]u8{
        1, 0, 4,   1,   0,  1,   1,   1, 2,  'A', 0, 1, 1, 1, 5, 28, 0, 23, 17, 0, 0, 0, 0, 0, 1, 1,
        1, 8, 139, 139, 21, 149, 139, 5, 14,
    };
    var source: [80]u8 = @splat(0);
    testing_sfnt.write(u32, &source, 0, 0x4f54544f);
    testing_sfnt.write(u16, &source, 4, 1);
    @memcpy(source[12..16], "CFF ");
    testing_sfnt.write(u32, &source, 20, 40);
    testing_sfnt.write(u32, &source, 24, cff_bytes.len);
    @memcpy(source[40..][0..cff_bytes.len], &cff_bytes);
    const directory = try Directory.open(&source);
    const table = (try directory.find("CFF ".*)).?;
    try std.testing.expectEqual(.opentype_cff, directory.flavor);
    try std.testing.expectEqualSlices(u8, &cff_bytes, table.data);
    try std.testing.expectEqual(@intFromPtr(&source) + 40, @intFromPtr(table.data.ptr));
    try std.testing.expectEqual(40, table.offset);
    try std.testing.expectEqualSlices(u8, "CFF ", &table.tag);
    try std.testing.expectEqual(0, table.checksum);
    try std.testing.expectEqual(null, try directory.find("CFF2".*));
}

const testing_sfnt = struct {
    fn write(comptime T: type, bytes: []u8, offset: usize, value: T) void {
        std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .big);
    }

    fn twoTables() [64]u8 {
        var bytes: [64]u8 = @splat(0);
        write(u32, &bytes, 0, 0x00010000);
        write(u16, &bytes, 4, 2);
        @memset(bytes[6..12], 255); // Ignore deliberately incorrect search accelerator fields.
        @memcpy(bytes[12..16], "DATA");
        @memcpy(bytes[28..32], "ZZZZ");
        for ([_]usize{ 12, 28 }) |offset| {
            write(u32, &bytes, offset + 4, 0x01020300);
            write(u32, &bytes, offset + 8, 49);
            write(u32, &bytes, offset + 12, 3);
        }
        @memcpy(bytes[49..52], &[_]u8{ 1, 2, 3 });
        return bytes;
    }

    fn collection() [104]u8 {
        var bytes: [104]u8 = @splat(0);
        @memcpy(bytes[0..4], "ttcf");
        write(u32, &bytes, 4, 0x00020000);
        write(u32, &bytes, 8, 2);
        write(u32, &bytes, 12, 36);
        write(u32, &bytes, 16, 64);
        inline for (.{ .{ 36, 0x00010000, 92 }, .{ 64, 0x4f54544f, 96 } }) |face| {
            write(u32, &bytes, face[0], face[1]);
            write(u16, &bytes, face[0] + 4, 1);
            @memcpy(bytes[face[0] + 12 ..][0..4], "DATA");
            write(u32, &bytes, face[0] + 20, face[2]);
            write(u32, &bytes, face[0] + 24, 3);
        }
        @memcpy(bytes[92..95], &[_]u8{ 1, 2, 3 });
        @memcpy(bytes[96..99], &[_]u8{ 4, 5, 6 });
        return bytes;
    }
};

// Discover the shared readers' own arithmetic and signed-value assertions with this library.
test {
    _ = binary;
}
