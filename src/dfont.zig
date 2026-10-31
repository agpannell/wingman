//! Borrowed SFNT fonts from Macintosh data-fork resource containers (`.dfont` files).
//!
//! A DFONT file stores complete fonts as `sfnt` resources. Container.open admits the resource map;
//! Container.faceBytes selects a payload without copying it or changing its resource-relative table
//! offsets. Face indices follow the reference list, rather than numeric resource IDs. Keep the
//! complete source immutable and alive while using the container or any selected font bytes.
//!
//! Opening checks disjoint data/map extents and bounded type/reference lists. For SFNT resources,
//! it also checks Pascal resource names, payload bounds and uncompressed directory extents. It does
//! not interpret font tables. Admit selected bytes with a font reader separately, so an invalid
//! sibling's table contents do not hide a usable face. Compressed SFNT resources can be enumerated
//! but selecting one returns UnsupportedFormat. Other resource types do not contribute faces.
//! NFNT/POST fonts, AppleDouble, MacBinary and filesystem resource-fork discovery are outside this
//! format reader.
//!
//! All operations are allocation-free. Admission is linear in type and SFNT reference counts. The
//! leading word is a data offset and can equal a SFNT signature; hasHeader provides a bounded
//! framing check, not format identification. See Container.open for an executable selection
//! example. Format:
//! https://developer.apple.com/library/archive/documentation/mac/MoreToolbox/MoreToolbox-99.html

const std = @import("std");
const binary = @import("common/font_binary.zig");
const sfnt = @import("sfnt.zig");

/// Malformed resource framing, an unavailable face index, or unsupported resource content.
pub const Error = error{ InvalidFont, InvalidFace, UnsupportedFormat };

/// Admitted resource framing over immutable complete source bytes. Keep the source alive and
/// unchanged while using this container or a selected face. The descriptor can be copied; its
/// fields must remain unchanged.
pub const Container = struct {
    /// Complete source, including framing and uninterpreted resource types.
    bytes: []const u8,
    /// Resource-data region, including each payload's four-byte length prefix.
    data: []const u8,
    /// Twelve-byte SFNT reference records in selectable face order.
    references: []const u8,

    /// Admits the data-fork resource map and each uncompressed SFNT directory extent. Other
    /// resource payloads and font table contents remain uninterpreted. Redundant zero or copied map
    /// headers are accepted. No SFNT resources returns UnsupportedFormat; failures leave source
    /// unchanged.
    pub fn open(bytes: []const u8) Error!Container {
        const header = try readHeader(bytes);
        const data = header.data;
        const map = header.map;

        const types_offset = try binary.read(u16, map, 24);
        const names_offset = try binary.read(u16, map, 26);
        if (types_offset < 28 or names_offset > map.len) return error.InvalidFont;
        const type_count = count(try binary.read(u16, map, types_offset));
        const types_start = try binary.arrayOffset(types_offset, 1, 2);
        const types_end = try binary.arrayOffset(types_start, type_count, 8);
        if (types_end > names_offset) return error.InvalidFont;

        var references: ?[]const u8 = null;
        for (0..type_count) |index| {
            const record = types_start + index * 8;
            const reference_count = count(try binary.read(u16, map, record + 4));
            // Reference-list offsets are relative to the type list, not the resource map.
            const relative = try binary.read(u16, map, record + 6);
            const start = try binary.arrayOffset(types_offset, 1, relative);
            const end = try binary.arrayOffset(start, reference_count, 12);
            if (start < types_end or end > names_offset) return error.InvalidFont;
            if (try binary.read(u32, map, record) != 0x73666e74) continue; // sfnt
            if (references != null) return error.InvalidFont;
            references = map[start..end];

            for (0..reference_count) |face_index| {
                const reference = map[start + face_index * 12 ..][0..12];
                const name_offset = try binary.read(u16, reference, 2);
                if (name_offset != 0xffff) {
                    const name = try binary.arrayOffset(names_offset, 1, name_offset);
                    if (name >= map.len or map[name] > map.len - name - 1) return error.InvalidFont;
                }

                const payload = try resource(data, reference);
                if (reference[4] & 1 != 0) continue; // Compressed resources need separate decoding.
                if (payload.len < 12) return error.InvalidFont;
                const tables = try binary.read(u16, payload, 4);
                const directory_end = try binary.arrayOffset(12, tables, 16);
                if (directory_end > payload.len) return error.InvalidFont;
            }
        }

        const selected = references orelse return error.UnsupportedFormat;
        if (selected.len == 0) return error.UnsupportedFormat;
        return .{ .bytes = bytes, .data = data, .references = selected };
    }

    test open {
        // One resource contains an empty SFNT directory; its offsets are resource-relative.
        const source = storage: {
            var bytes: [82]u8 = @splat(0);
            std.mem.writeInt(u32, bytes[0..4], 16, .big);
            std.mem.writeInt(u32, bytes[4..8], 32, .big);
            std.mem.writeInt(u32, bytes[8..12], 16, .big);
            std.mem.writeInt(u32, bytes[12..16], 50, .big);
            std.mem.writeInt(u32, bytes[16..20], 12, .big);
            std.mem.writeInt(u32, bytes[20..24], 0x00010000, .big);
            std.mem.writeInt(u16, bytes[56..58], 28, .big);
            std.mem.writeInt(u16, bytes[58..60], 50, .big);
            @memcpy(bytes[62..66], "sfnt");
            std.mem.writeInt(u16, bytes[68..70], 10, .big);
            std.mem.writeInt(u16, bytes[72..74], 0xffff, .big);
            break :storage bytes;
        };
        const container = try Container.open(&source);
        const font_bytes = try container.faceBytes(0);
        const directory = try sfnt.Directory.open(font_bytes);
        try std.testing.expectEqual(1, container.faceCount());
        try std.testing.expectEqual(0, directory.table_count);
        try std.testing.expectEqual(.truetype, directory.flavor);
    }

    /// Number of selectable SFNT resources, including compressed resources; always nonzero.
    pub fn faceCount(self: Container) u32 {
        return @intCast(self.references.len / 12);
    }

    /// Borrows one complete SFNT payload, preserving resource-relative table offsets. An index
    /// outside faceCount returns InvalidFace; a compressed resource returns UnsupportedFormat. This
    /// checks no table contents and changes neither the container nor its other faces. The returned
    /// slice borrows only the source bytes and can outlive the Container value.
    pub fn faceBytes(self: Container, face_index: u32) Error![]const u8 {
        if (face_index >= self.faceCount()) return error.InvalidFace;
        const reference = self.references[@as(usize, face_index) * 12 ..][0..12];
        if (reference[4] & 1 != 0) return error.UnsupportedFormat;
        return resource(self.data, reference);
    }
};

/// Checks the fixed header and disjoint data/map extents without visiting resources. A successful
/// result does not admit type/reference lists or identify the payload format; call Container.open
/// afterward. A failed check does not prove that the same bytes are a different font format.
pub fn hasHeader(bytes: []const u8) bool {
    _ = readHeader(bytes) catch return false;
    return true;
}

const Header = struct { data: []const u8, map: []const u8 };

fn readHeader(bytes: []const u8) Error!Header {
    const data_offset = try binary.read(u32, bytes, 0);
    const map_offset = try binary.read(u32, bytes, 4);
    const data_length = try binary.read(u32, bytes, 8);
    const map_length = try binary.read(u32, bytes, 12);
    if (data_offset < 16 or map_offset < 16 or map_length < 30) return error.InvalidFont;
    const data = try slice(bytes, data_offset, data_length);
    const map = try slice(bytes, map_offset, map_length);
    binary.admitDisjoint(data, map) catch return error.InvalidFont;
    const zero_header = std.mem.allEqual(u8, map[0..16], 0);
    const copied_header = std.mem.eql(u8, map[0..16], bytes[0..16]);
    if (!zero_header and !copied_header) return error.InvalidFont;
    return .{ .data = data, .map = map };
}

fn slice(bytes: []const u8, offset: u32, length: u32) Error![]const u8 {
    const start = std.math.cast(usize, offset) orelse return error.InvalidFont;
    const size = std.math.cast(usize, length) orelse return error.InvalidFont;
    const end = try binary.arrayOffset(start, size, 1);
    if (end > bytes.len) return error.InvalidFont;
    return bytes[start..end];
}

fn count(minus_one: u16) usize {
    return if (minus_one == 0xffff) 0 else @as(usize, minus_one) + 1;
}

fn resource(data: []const u8, reference: []const u8) Error![]const u8 {
    const offset = (try binary.read(u32, reference, 4)) & 0x00ffffff;
    const length = try binary.read(u32, data, offset);
    const start = std.math.add(u32, offset, 4) catch return error.InvalidFont;
    return slice(data, start, length);
}

test {
    _ = Container;
}

test "DFONT selects resource order and admits sibling directories independently of font contents" {
    var bytes = testing_dfont.container();
    var container = try Container.open(&bytes);
    try std.testing.expect(hasHeader(&bytes));
    try std.testing.expectEqual(2, container.faceCount());
    try std.testing.expectEqualSlices(u8, bytes[68..344], try container.faceBytes(0));
    try std.testing.expectEqual(bytes[348..624].ptr, (try container.faceBytes(1)).ptr);
    try std.testing.expectError(error.InvalidFace, container.faceBytes(2));

    const second = try sfnt.Directory.open(try container.faceBytes(1));
    try std.testing.expectEqual(2048, try binary.read(u16, (try second.find("head".*)).?.data, 18));

    // A copied map header is valid. A sibling's table-content error stays deferred.
    @memcpy(bytes[624..640], bytes[0..16]);
    testing_dfont.write(u32, &bytes, 348 + 12 + 8, 0xffffff00);
    container = try Container.open(&bytes);
    try std.testing.expectError(error.InvalidFont, sfnt.Directory.open(try container.faceBytes(1)));
    const first = try sfnt.Directory.open(try container.faceBytes(0));
    try std.testing.expectEqual(1000, try binary.read(u16, (try first.find("head".*)).?.data, 18));
    try std.testing.expectEqual(500, try binary.read(u16, (try first.find("hmtx".*)).?.data, 0));
}

test "DFONT header preflight leaves reference admission to open" {
    var bytes = testing_dfont.container();
    testing_dfont.write(u16, &bytes, 624 + 26, 97);
    try std.testing.expect(hasHeader(&bytes));
    try std.testing.expectError(error.InvalidFont, Container.open(&bytes));
}

test "DFONT admits relocated data whose offset equals a SFNT signature" {
    const original = testing_dfont.container();
    const data_offset = 0x00010000;
    const data_length = 560;
    const map_offset = data_offset + data_length;
    const bytes = try std.testing.allocator.alloc(u8, map_offset + 96);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    testing_dfont.write(u32, bytes, 0, data_offset);
    testing_dfont.write(u32, bytes, 4, map_offset);
    testing_dfont.write(u32, bytes, 8, data_length);
    testing_dfont.write(u32, bytes, 12, 96);
    @memcpy(bytes[data_offset..map_offset], original[64..624]);
    @memcpy(bytes[map_offset..], original[624..]);

    for ([_]bool{ false, true }) |copied_header| {
        if (copied_header) @memcpy(bytes[map_offset..][0..16], bytes[0..16]);
        try std.testing.expect(hasHeader(bytes));
        const container = try Container.open(bytes);
        const first = try container.faceBytes(0);
        try std.testing.expectEqual(bytes[data_offset + 4 ..].ptr, first.ptr);
        try std.testing.expectEqualSlices(u8, original[68..344], first);
        try std.testing.expectEqualSlices(u8, original[348..624], try container.faceBytes(1));
    }
}

test "DFONT rejects truncated aliased compressed and invalid resource records" {
    const fixture = testing_dfont.container();
    for ([_]usize{ 0, 15, 16, 63, 64, 623, 624, 653, 719 }) |end| {
        try std.testing.expectError(error.InvalidFont, Container.open(fixture[0..end]));
    }
    for ([_]struct { offset: usize, value: u32 }{
        // Map aliases resource data.
        .{ .offset = 0, .value = 0xffffffff },            .{ .offset = 4, .value = 65 },
        // Neither zero nor copied map header. Resource payload length.
        .{ .offset = 8, .value = 0xffffffff },            .{ .offset = 12, .value = 29 },
        .{ .offset = 624, .value = 1 },                   .{ .offset = 64, .value = 0xffffffff },
        .{ .offset = 624 + 38 + 4, .value = 0x00ffffff },
    }) |case| {
        var bytes = fixture;
        testing_dfont.write(u32, &bytes, case.offset, case.value);
        try std.testing.expectError(error.InvalidFont, Container.open(&bytes));
    }
    for ([_]struct { offset: usize, value: u16 }{
        // References alias type entries.
        .{
            .offset = 624 + 24,
            .value = 27,
        },
        .{ .offset = 624 + 26, .value = 97 },
        .{ .offset = 624 + 36, .value = 0 },
        // Named resource beyond map. Unselected directory is truncated.
        .{
            .offset = 624 + 36,
            .value = 90,
        },
        .{ .offset = 624 + 40, .value = 96 },
        .{ .offset = 348 + 4, .value = 0xffff },
    }) |case| {
        var bytes = fixture;
        testing_dfont.write(u16, &bytes, case.offset, case.value);
        try std.testing.expectError(error.InvalidFont, Container.open(&bytes));
    }

    var bytes = fixture;
    bytes[624 + 42] = 1;
    const compressed = try Container.open(&bytes);
    try std.testing.expectError(error.UnsupportedFormat, compressed.faceBytes(0));
    try std.testing.expectEqualSlices(u8, bytes[348..624], try compressed.faceBytes(1));
    bytes = fixture;
    bytes[624 + 62] = 255;
    try std.testing.expectError(error.InvalidFont, Container.open(&bytes));
    bytes = fixture;
    testing_dfont.write(u32, &bytes, 624 + 30, 0x4e464e54); // NFNT without SFNT faces.
    try std.testing.expectError(error.UnsupportedFormat, Container.open(&bytes));
}

// Independent fixed SFNT/resource-map fields. These fixtures do not use the reader to frame bytes.
const testing_dfont = struct {
    fn write(comptime T: type, bytes: []u8, offset: usize, value: T) void {
        std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .big);
    }

    fn container() [720]u8 {
        var bytes: [720]u8 = @splat(0);
        write(u32, &bytes, 0, 64);
        write(u32, &bytes, 4, 624);
        write(u32, &bytes, 8, 560);
        write(u32, &bytes, 12, 96);
        write(u32, &bytes, 64, 276);
        face(bytes[68..344], 1000, 500, 1);
        write(u32, &bytes, 344, 276);
        face(bytes[348..624], 2048, 700, 0);
        write(u16, &bytes, 624 + 24, 28);
        write(u16, &bytes, 624 + 26, 62);
        write(u16, &bytes, 624 + 28, 0); // One resource type.
        write(u32, &bytes, 624 + 30, 0x73666e74);
        write(u16, &bytes, 624 + 34, 1); // Two SFNT resources.
        write(u16, &bytes, 624 + 36, 10);
        write(u16, &bytes, 624 + 38, 42);
        write(u16, &bytes, 624 + 40, 0);
        write(u16, &bytes, 624 + 50, @bitCast(@as(i16, -7)));
        write(u16, &bytes, 624 + 52, 2);
        write(u32, &bytes, 624 + 54, 280);
        bytes[624 + 62 ..][0..4].* = .{ 1, 'A', 1, 'B' };
        return bytes;
    }

    fn face(bytes: []u8, units_per_em: u16, advance: u16, glyph_for_a: u16) void {
        write(u32, bytes, 0, 0x00010000);
        write(u16, bytes, 4, 7);
        const records = [_]struct {
            tag: [4]u8,
            offset: u32,
            length: u32,
        }{
            .{ .tag = "head".*, .offset = 124, .length = 54 },
            .{ .tag = "maxp".*, .offset = 178, .length = 6 },
            .{ .tag = "hhea".*, .offset = 184, .length = 36 },
            .{ .tag = "hmtx".*, .offset = 220, .length = 6 },
            .{ .tag = "loca".*, .offset = 226, .length = 6 },
            .{ .tag = "cmap".*, .offset = 232, .length = 44 },
            .{ .tag = "glyf".*, .offset = 276, .length = 0 },
        };
        for (records, 0..) |record, index| {
            const position = 12 + index * 16;
            @memcpy(bytes[position..][0..4], &record.tag);
            write(u32, bytes, position + 8, record.offset);
            write(u32, bytes, position + 12, record.length);
        }

        write(u16, bytes, 142, units_per_em);
        write(u32, bytes, 178, 0x00010000);
        write(u16, bytes, 182, 2);
        write(u32, bytes, 184, 0x00010000);
        write(u16, bytes, 218, 1);
        write(u16, bytes, 220, advance);
        const cmap = bytes[232..];
        write(u16, cmap, 2, 1);
        write(u16, cmap, 4, 3);
        write(u16, cmap, 6, 1);
        write(u32, cmap, 8, 12);
        const mapping = cmap[12..];
        write(u16, mapping, 0, 4);
        write(u16, mapping, 2, 32);
        write(u16, mapping, 6, 4);
        write(u16, mapping, 8, 4);
        write(u16, mapping, 10, 1);
        write(u16, mapping, 14, 'A');
        write(u16, mapping, 16, 0xffff);
        write(u16, mapping, 20, 'A');
        write(u16, mapping, 22, 0xffff);
        write(u16, mapping, 24, @truncate(@as(u32, glyph_for_a) -% @as(u32, 'A')));
        write(u16, mapping, 26, 1);
    }
};
