//! Borrowed classic TIFF directories, field values and bounded Exif metadata selection.
const std = @import("std");
const testing_exif = @import("fixtures.zig").testing_exif;

/// Selected malformed, unsupported or over-budget Exif metadata.
pub const Error = error{ InvalidExif, UnsupportedExif, MetadataLimitExceeded };

/// Limits apply to structural directories, independently of image decoding.
pub const Limits = struct {
    /// Maximum directory visits in the main next-IFD chain, including IFD0. Admission may stop
    /// traversal before a cycle is established.
    directories: usize = 16,
    /// Maximum entries across that chain, and in an explicitly selected child directory.
    entries: usize = 4096,
    /// Maximum combined directory headers and entries across the main chain. A separately selected
    /// directory admits its own header/entries under the same ceiling; repeated selections are not
    /// accumulated. The default preserves separate-limit admission.
    records: usize = std.math.maxInt(usize),
};

/// Structural admission for a borrowed TIFF metadata view.
pub const InspectOptions = struct { limits: Limits = .{} };

/// Stored raster orientation; no transform is applied by this reader or pixel decoding.
pub const Orientation = enum(u16) {
    top_left = 1,
    top_right = 2,
    bottom_right = 3,
    bottom_left = 4,
    left_top = 5,
    right_top = 6,
    right_bottom = 7,
    left_bottom = 8,
};

/// Borrowed classic TIFF source with a checked, bounded main directory chain.
pub const View = struct {
    /// Complete TIFF bytes; the source must stay live and unchanged through the last view use.
    source: []const u8,
    /// Byte order used by directory entries, offsets and numeric values.
    endian: std.builtin.Endian,
    /// Byte offset of IFD0 relative to the TIFF header.
    first_ifd: u32,
    /// The admission policy also used when selecting a child directory.
    limits: Limits,
    /// Checked directory headers and entries in the complete admitted main chain.
    record_count: usize = 0,

    /// Checks the TIFF header, complete main directory bounds, record budgets and cycles. Limits
    /// precede reading another directory or an over-budget directory's entry body. Pixel/field
    /// payloads are checked when selected; unknown tags and maker notes stay opaque.
    /// Unrepresentable or out-of-source directory extents return InvalidExif after limit admission.
    pub fn open(source: []const u8, options: InspectOptions) Error!View {
        const limits = options.limits;
        if (source.len < 8) return error.InvalidExif;
        const endian: std.builtin.Endian = if (std.mem.eql(
            u8,
            source[0..2],
            "II",
        )) .little else if (std.mem.eql(u8, source[0..2], "MM")) .big else return error.InvalidExif;
        if (std.mem.readInt(u16, source[2..4], endian) != 42) return error.UnsupportedExif;
        var view: View = .{
            .source = source,
            .endian = endian,
            .first_ifd = std.mem.readInt(u32, source[4..8], endian),
            .limits = limits,
        };
        if (view.first_ifd == 0) return error.InvalidExif;
        var offset = view.first_ifd;
        var checkpoint_offset = offset;
        var checkpoint_distance: usize = 0;
        var checkpoint_span: usize = 1;
        var directory_count: usize = 0;
        var entry_count: usize = 0;
        while (offset != 0) {
            if (directory_count == limits.directories or view.record_count == limits.records)
                return error.MetadataLimitExceeded;
            const remaining_entries = @min(
                limits.entries - entry_count,
                limits.records - view.record_count - 1,
            );
            const directory = try view.readDirectory(offset, remaining_entries);
            entry_count += directory.count;
            directory_count += 1;
            // Header and entries were admitted against the remaining total before body access.
            view.record_count += 1 + @as(usize, directory.count);
            offset = directory.next_offset;

            // Brent's checkpoints detect cycles within this admitted traversal. Looking ahead would
            // read unadmitted directories and could override the caller's budget refusal.
            if (offset == checkpoint_offset) return error.InvalidExif;
            checkpoint_distance += 1;
            if (checkpoint_distance == checkpoint_span) {
                checkpoint_offset = offset;
                checkpoint_distance = 0;
                checkpoint_span *|= 2;
            }
        }
        return view;
    }

    test open {
        const little = [_]u8{
            0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x12, 0x01, 0x03, 0x00, 0x01, 0x00,
            0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        };
        const big = [_]u8{
            0x4d, 0x4d, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08,
            0x00, 0x01, 0x01, 0x12, 0x00, 0x03, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        };
        for ([_][]const u8{ little[0..], big[0..] }) |bytes| {
            const view = try View.open(bytes, .{});
            try std.testing.expectEqual(.right_top, (try view.orientation()).?);
            try std.testing.expectEqual(0x0112, (try view.primary()).entry(0).?.tag);
            try std.testing.expectEqual(null, try view.thumbnail());
        }
        var invalid = little[0..].*;
        invalid[18] = 9;
        try std.testing.expectError(
            error.InvalidExif,
            (try View.open(&invalid, .{})).orientation(),
        );
        invalid[18] = 0;
        try std.testing.expectError(
            error.InvalidExif,
            (try View.open(&invalid, .{})).orientation(),
        );
        invalid[12] = 4;
        try std.testing.expectError(
            error.InvalidExif,
            (try View.open(&invalid, .{})).orientation(),
        );
    }

    /// Borrows the primary image's checked attribute directory.
    pub fn primary(self: View) Error!Directory {
        return self.directoryAt(self.first_ifd);
    }

    /// Reads one optional unsigned orientation tag, rejecting duplicates and values outside 1–8.
    pub fn orientation(self: View) Error!?Orientation {
        const entry = (try (try self.primary()).find(0x0112)) orelse return null;
        const value = try entry.unsignedScalar();
        if (value < 1 or value > 8) return error.InvalidExif;
        return @fromBackingInt(@intCast(value));
    }

    /// Returns IFD1 and its checked JPEG slice when compression is 6. Other thumbnail layouts
    /// retain their directory for explicit strip/field inspection. This checks storage bounds
    /// rather than the embedded image's entropy validity.
    pub fn thumbnail(self: View) Error!?Thumbnail {
        const offset = (try self.primary()).next_offset;
        if (offset == 0) return null;
        const directory = try self.directoryAt(offset);
        const compression = (try directory.find(0x0103)) orelse return error.InvalidExif;
        if (try compression.unsignedScalar() != 6) return .{ .directory = directory, .jpeg = null };
        const start = (try directory.find(0x0201)) orelse return error.InvalidExif;
        const size = (try directory.find(0x0202)) orelse return error.InvalidExif;
        const byte_count = try size.unsignedScalar();
        if (byte_count == 0) return error.InvalidExif;
        return .{
            .directory = directory,
            .jpeg = try self.range(try start.unsignedScalar(), byte_count),
        };
    }

    /// Selects one directory at a TIFF-relative offset, checking entry/record limits and bounds.
    /// Its header and entries use an independent ceiling; main-chain visits are not subtracted.
    /// Unrepresentable extents and out-of-source storage return InvalidExif after limit admission.
    /// This does not recursively follow its pointers or claim that its tag semantics are valid.
    pub fn directoryAt(self: View, offset: u32) Error!Directory {
        if (self.limits.records == 0) return error.MetadataLimitExceeded;
        return self.readDirectory(offset, @min(self.limits.entries, self.limits.records - 1));
    }

    fn readDirectory(self: View, offset: u32, maximum_entries: usize) Error!Directory {
        const count_bytes = try self.range(offset, 2);
        const count = std.mem.readInt(u16, count_bytes[0..2], self.endian);
        if (count > maximum_entries) return error.MetadataLimitExceeded;
        const extent = try directoryExtent(usize, count);
        const body_offset = std.math.add(u32, offset, 2) catch return error.InvalidExif;
        const body = try self.range(body_offset, extent.total);
        return .{
            .view = self,
            .offset = offset,
            .count = count,
            .entries = body[0..extent.entries],
            .next_offset = std.mem.readInt(u32, body[extent.entries..][0..4], self.endian),
        };
    }

    fn range(self: View, offset: u32, count: usize) Error![]const u8 {
        if (offset < 8 or offset > self.source.len or count > self.source.len - offset)
            return error.InvalidExif;
        return self.source[offset..][0..count];
    }
};

// The size parameter lets narrow-width tests exercise the parser's exact extent calculation.
fn directoryExtent(
    comptime Size: type,
    count: u16,
) error{InvalidExif}!struct { entries: Size, total: Size } {
    const entries = std.math.mul(Size, @as(Size, count), 12) catch return error.InvalidExif;
    const total = std.math.add(Size, entries, 4) catch return error.InvalidExif;
    return .{ .entries = entries, .total = total };
}

test "Exif directory extents reject narrow arithmetic overflow before slicing" {
    var count: u32 = 0;
    while (count <= std.math.maxInt(u16)) : (count += 1) {
        const full = count * 12 + 4;
        const extent = directoryExtent(u16, @intCast(count));
        if (full > std.math.maxInt(u16)) {
            try std.testing.expectError(error.InvalidExif, extent);
        } else {
            const admitted = try extent;
            try std.testing.expectEqual(full, admitted.total);
            try std.testing.expectEqual(count * 12, admitted.entries);
        }
    }
    // At 5461 only the trailer addition overflows; 5462 also overflows the entry body.
    try std.testing.expectEqual(65524, (try directoryExtent(u16, 5460)).total);
    try std.testing.expectError(error.InvalidExif, directoryExtent(u16, 5461));
    try std.testing.expectError(error.InvalidExif, directoryExtent(u16, 5462));
    try std.testing.expectEqual(786424, (try directoryExtent(u32, 65535)).total);
}

test "Exif full directory extents preserve valid high counts and limit precedence" {
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        for ([_]u16{ 0, 1, 4096, 5460, 5461, 5462, 65535 }) |count| {
            const size = 14 + @as(usize, count) * 12;
            const bytes = try std.testing.allocator.alloc(u8, size);
            defer std.testing.allocator.free(bytes);
            @memset(bytes, 0);
            @memcpy(bytes[0..2], if (endian == .little) "II" else "MM");
            std.mem.writeInt(u16, bytes[2..4], 42, endian);
            std.mem.writeInt(u32, bytes[4..8], 8, endian);
            std.mem.writeInt(u16, bytes[8..10], count, endian);
            const options: InspectOptions = .{
                .limits = .{ .entries = count, .records = 1 + @as(usize, count) },
            };
            const view = try View.open(bytes, options);
            const directory = try view.directoryAt(8);
            try std.testing.expectEqual(count, directory.count);
            try std.testing.expectEqual(0, directory.next_offset);
            try std.testing.expectEqual(size - 14, directory.entries.len);
            try std.testing.expectEqual(bytes.ptr + 10, directory.entries.ptr);
            try std.testing.expectError(
                error.InvalidExif,
                View.open(bytes[0 .. size - 1], options),
            );
            try std.testing.expectError(error.InvalidExif, View.open(bytes[0..9], options));
            if (count > 4096) {
                try std.testing.expectError(error.MetadataLimitExceeded, View.open(bytes, .{}));
            }
            if (count != 0) {
                var refused = options;
                refused.limits.entries -= 1;
                try std.testing.expectError(
                    error.MetadataLimitExceeded,
                    View.open(bytes[0..10], refused),
                );
                refused = options;
                refused.limits.records -= 1;
                try std.testing.expectError(
                    error.MetadataLimitExceeded,
                    View.open(bytes[0..10], refused),
                );
            }
        }
    }
}

test "Exif child selection checks its own complete high-count extent" {
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        const count = 5461;
        const bytes = try std.testing.allocator.alloc(u8, 32 + count * 12);
        defer std.testing.allocator.free(bytes);
        @memset(bytes, 0);
        @memcpy(bytes[0..2], if (endian == .little) "II" else "MM");
        std.mem.writeInt(u16, bytes[2..4], 42, endian);
        std.mem.writeInt(u32, bytes[4..8], 8, endian);
        std.mem.writeInt(u16, bytes[8..10], 1, endian);
        std.mem.writeInt(u16, bytes[10..12], 0x8769, endian);
        std.mem.writeInt(u16, bytes[12..14], 4, endian);
        std.mem.writeInt(u32, bytes[14..18], 1, endian);
        std.mem.writeInt(u32, bytes[18..22], 26, endian);
        std.mem.writeInt(u16, bytes[26..28], count, endian);
        const options: InspectOptions = .{ .limits = .{ .entries = count, .records = count + 1 } };
        const view = try View.open(bytes, options);
        const child = (try (try view.primary()).child(0x8769)).?;
        try std.testing.expectEqual(count, child.count);
        try std.testing.expectEqual(bytes.ptr + 28, child.entries.ptr);

        const truncated = try View.open(bytes[0 .. bytes.len - 1], options);
        try std.testing.expectError(error.InvalidExif, (try truncated.primary()).child(0x8769));
        var refused = options;
        refused.limits.records -= 1;
        const limited = try View.open(bytes[0..28], refused);
        try std.testing.expectError(
            error.MetadataLimitExceeded,
            (try limited.primary()).child(0x8769),
        );
    }
}

/// Checked directory storage; entry payload interpretation is an explicit selection. Obtain through
/// a `View` directory method or `Directory.child` and preserve the returned source, byte order and
/// checked directory fields. Copies borrow the same TIFF backing; keep it live and unchanged
/// through the last directory or selected-entry use.
pub const Directory = struct {
    /// TIFF owner borrowed by the directory and every selected field.
    view: View,
    /// TIFF-relative byte offset of the directory's count field.
    offset: u32,
    /// Number of twelve-byte directory records.
    count: u16,
    /// Borrowed directory records, excluding count and next-directory offset.
    entries: []const u8,
    /// Zero ends the main chain; otherwise names its next directory.
    next_offset: u32,

    /// Selects one record by index; null means the index is outside this directory.
    pub fn entry(self: Directory, index: usize) ?Entry {
        if (index >= self.count) return null;
        const bytes = self.entryRecord(index);
        return .{
            .view = self.view,
            .tag = std.mem.readInt(u16, bytes[0..2], self.view.endian),
            .field_type = std.mem.readInt(u16, bytes[2..4], self.view.endian),
            .count = std.mem.readInt(u32, bytes[4..8], self.view.endian),
            .value_field = bytes[8..12],
        };
    }

    /// Selects a unique tag without requiring producer records to be sorted.
    pub fn find(self: Directory, tag: u16) Error!?Entry {
        var found: ?usize = null;
        for (0..self.count) |index| {
            const record = self.entryRecord(index);
            if (std.mem.readInt(u16, record[0..2], self.view.endian) != tag) continue;
            if (found != null) return error.InvalidExif;
            found = index;
        }
        return self.entry(found orelse return null);
    }

    fn entryRecord(self: Directory, index: usize) *const [12]u8 {
        // Callers bound the index by the complete directory admitted by View.
        return self.entries[index * 12 ..][0..12];
    }

    /// Borrows a child IFD named by one unsigned offset; direct self-cycles are malformed. No
    /// recursive traversal occurs. Callers bound their own repeated child selections.
    pub fn child(self: Directory, tag: u16) Error!?Directory {
        const pointer = (try self.find(tag)) orelse return null;
        const offset = try pointer.unsignedScalar();
        if (offset == self.offset) return error.InvalidExif;
        return try self.view.directoryAt(offset);
    }

    /// Checks all StripOffsets/StripByteCounts pairs before publishing an iterator.
    pub fn strips(self: Directory) Error!Strips {
        const offsets = (try self.find(0x0111)) orelse return error.InvalidExif;
        const counts = (try self.find(0x0117)) orelse return error.InvalidExif;
        if (offsets.count == 0 or offsets.count != counts.count) return error.InvalidExif;
        if (offsets.count > self.view.limits.entries) return error.MetadataLimitExceeded;
        for (0..offsets.count) |index| {
            _ = try self.view.range(try offsets.unsigned(index), try counts.unsigned(index));
        }
        return .{ .view = self.view, .offsets = offsets, .counts = counts };
    }
};

/// One borrowed raw field. Unknown tags/types may be retained without interpreting their value.
pub const Entry = struct {
    /// TIFF source and byte order used when selecting field data.
    view: View,
    /// Encoded TIFF tag number.
    tag: u16,
    /// Encoded field type; classic types 1–12 are readable. Other types stay opaque.
    field_type: u16,
    /// Encoded element count, checked against payload bounds when data is selected.
    count: u32,
    /// Borrowed inline bytes or TIFF-relative offset field.
    value_field: *const [4]u8,

    /// Returns checked encoded field bytes without converting them or retaining new storage.
    pub fn data(self: Entry) Error![]const u8 {
        const width: usize = switch (self.field_type) {
            1, 2, 6, 7 => 1,
            3, 8 => 2,
            4, 9, 11 => 4,
            5, 10, 12 => 8,
            else => return error.UnsupportedExif,
        };
        const size = std.math.mul(usize, self.count, width) catch return error.InvalidExif;
        if (size <= 4) return self.value_field[0..size];
        const offset = std.mem.readInt(u32, self.value_field, self.view.endian);
        return self.view.range(offset, size);
    }

    /// Identifies a supported unsigned TIFF representation without checking count or storage. TIFF
    /// 6.0 section 2 recommends accepting BYTE, SHORT and LONG for unsigned fields.
    pub fn isUnsigned(self: Entry) bool {
        return self.field_type == 1 or self.field_type == 3 or self.field_type == 4;
    }

    /// Reads one unsigned scalar; other field types or counts are malformed selections. Stored
    /// bytes remain borrowed and are checked by the same value reader as arrays.
    pub fn unsignedScalar(self: Entry) Error!u32 {
        if (self.count != 1 or !self.isUnsigned()) return error.InvalidExif;
        return self.unsigned(0);
    }

    /// Reads one BYTE/SHORT/LONG value, rejecting other interpretations and invalid indices.
    pub fn unsigned(self: Entry, index: usize) Error!u32 {
        if (index >= self.count) return error.InvalidExif;
        const bytes = try self.data();
        return switch (self.field_type) {
            1 => bytes[index],
            3 => std.mem.readInt(u16, bytes[index * 2 ..][0..2], self.view.endian),
            4 => std.mem.readInt(u32, bytes[index * 4 ..][0..4], self.view.endian),
            else => error.UnsupportedExif,
        };
    }
};

/// Checked IFD1 storage and, for a JPEG-compressed thumbnail, its borrowed encoded bytes.
pub const Thumbnail = struct {
    /// Thumbnail attributes; uncompressed layouts may select `directory.strips()`.
    directory: Directory,
    /// Non-null only for compression 6; decoding remains an explicit image operation.
    jpeg: ?[]const u8,
};

/// Iterator over prechecked TIFF strip storage; each result borrows the original Exif source.
pub const Strips = struct {
    /// TIFF owner of the selected strip arrays and payloads.
    view: View,
    /// Checked unsigned strip offsets.
    offsets: Entry,
    /// Checked corresponding strip byte counts.
    counts: Entry,
    /// Next strip index; initialized by `Directory.strips`.
    index: usize = 0,

    /// Borrows a checked strip by index without advancing iteration; null means absent. The
    /// underlying TIFF source must remain live and unchanged through its use.
    pub fn strip(self: Strips, strip_index: usize) Error!?[]const u8 {
        if (strip_index >= self.offsets.count) return null;
        return try self.view.range(
            try self.offsets.unsigned(strip_index),
            try self.counts.unsigned(strip_index),
        );
    }

    /// Returns the next checked strip or null at the end. Source must remain unchanged.
    pub fn next(self: *Strips) Error!?[]const u8 {
        const result = (try self.strip(self.index)) orelse return null;
        self.index += 1;
        return result;
    }
};

test "Exif main directories reject bounds cycles and resource excess" {
    for (0..testing_exif.little_orientation[0..].len) |end| {
        try std.testing.expectError(
            error.InvalidExif,
            View.open(testing_exif.little_orientation[0..end], .{}),
        );
    }
    var cycle = testing_exif.little_orientation[0..].*;
    cycle[22] = 8;
    try std.testing.expectError(error.InvalidExif, View.open(&cycle, .{}));
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        View.open(testing_exif.little_orientation[0..], .{ .limits = .{ .directories = 0 } }),
    );
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        View.open(testing_exif.little_orientation[0..], .{ .limits = .{ .entries = 0 } }),
    );
}

test "Exif chain limits precede unadmitted directory payloads" {
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        // IFD0 has orientation 6; IFD1 declares one record but omits its body.
        var bytes: [28]u8 = @splat(0);
        @memcpy(bytes[0..2], if (endian == .little) "II" else "MM");
        std.mem.writeInt(u16, bytes[2..4], 42, endian);
        std.mem.writeInt(u32, bytes[4..8], 8, endian);
        std.mem.writeInt(u16, bytes[8..10], 1, endian);
        std.mem.writeInt(u16, bytes[10..12], 0x0112, endian);
        std.mem.writeInt(u16, bytes[12..14], 3, endian);
        std.mem.writeInt(u32, bytes[14..18], 1, endian);
        std.mem.writeInt(u16, bytes[18..20], 6, endian);
        std.mem.writeInt(u32, bytes[22..26], 26, endian);
        std.mem.writeInt(u16, bytes[26..28], 1, endian);

        try std.testing.expectError(
            error.MetadataLimitExceeded,
            View.open(&bytes, .{ .limits = .{ .directories = 1, .entries = 2 } }),
        );
        try std.testing.expectError(
            error.MetadataLimitExceeded,
            View.open(&bytes, .{ .limits = .{ .directories = 2, .entries = 1 } }),
        );
        try std.testing.expectError(
            error.InvalidExif,
            View.open(&bytes, .{ .limits = .{ .directories = 2, .entries = 2 } }),
        );

        std.mem.writeInt(u32, bytes[22..26], 1, endian);
        try std.testing.expectError(
            error.MetadataLimitExceeded,
            View.open(&bytes, .{ .limits = .{ .directories = 1 } }),
        );
        try std.testing.expectError(
            error.InvalidExif,
            View.open(&bytes, .{ .limits = .{ .directories = 2 } }),
        );

        std.mem.writeInt(u32, bytes[22..26], 0, endian);
        const view = try View.open(
            bytes[0..26],
            .{ .limits = .{ .directories = 1, .entries = 1 } },
        );
        try std.testing.expectEqual(2, view.record_count);
        try std.testing.expectEqual(.right_top, (try view.orientation()).?);
    }
}

test "Exif main chain matches independent five-directory graph reachability" {
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        var bytes: [38]u8 = @splat(0);
        @memcpy(bytes[0..2], if (endian == .little) "II" else "MM");
        std.mem.writeInt(u16, bytes[2..4], 42, endian);
        std.mem.writeInt(u32, bytes[4..8], 8, endian);
        // Each empty directory points to EOF or any of five directories: all 6^5 graphs.
        for (0..6 * 6 * 6 * 6 * 6) |graph| {
            var encoded = graph;
            var successors: [5]u8 = undefined;
            for (&successors, 0..) |*successor, index| {
                successor.* = @intCast(encoded % 6);
                encoded /= 6;
                const offset: u32 = if (successor.* == 0) 0 else 8 + 6 * @as(u32, successor.* - 1);
                std.mem.writeInt(u32, bytes[10 + index * 6 ..][0..4], offset, endian);
            }

            // A visited-node reference classifies reachability without using cycle checkpoints.
            var seen: [5]bool = @splat(false);
            var node: u8 = 1;
            var count: usize = 0;
            while (node != 0 and !seen[node - 1]) {
                seen[node - 1] = true;
                count += 1;
                node = successors[node - 1];
            }
            const limits: Limits = .{ .directories = 15, .entries = 0 };
            if (node != 0) {
                try std.testing.expectError(
                    error.InvalidExif,
                    View.open(&bytes, .{ .limits = limits }),
                );
            } else {
                try std.testing.expectEqual(
                    count,
                    (try View.open(&bytes, .{ .limits = limits })).record_count,
                );
                try std.testing.expectEqual(
                    count,
                    (try View.open(
                        &bytes,
                        .{ .limits = .{ .directories = count, .entries = 0 } },
                    )).record_count,
                );
                try std.testing.expectError(
                    error.MetadataLimitExceeded,
                    View.open(&bytes, .{ .limits = .{ .directories = count - 1, .entries = 0 } }),
                );
                try std.testing.expectEqual(
                    count,
                    (try View.open(
                        &bytes,
                        .{ .limits = .{ .records = count, .entries = 0 } },
                    )).record_count,
                );
                try std.testing.expectError(
                    error.MetadataLimitExceeded,
                    View.open(&bytes, .{ .limits = .{ .records = count - 1, .entries = 0 } }),
                );
            }
        }
    }
}

test "Exif IFD1 JPEG and uncompressed strip payloads stay inside the TIFF source" {
    // IFD0 at 8 is empty and points to IFD1 at 14. Three IFD1 records point to the four
    // independently specified encoded thumbnail bytes at offset 56.
    const bytes = testing_exif.jpeg_thumbnail[0..];
    const thumbnail = (try (try View.open(bytes, .{})).thumbnail()).?;
    try std.testing.expectEqualSlices(u8, "\xff\xd8\xff\xd9", thumbnail.jpeg.?);
    try std.testing.expectEqual(@intFromPtr(bytes.ptr) + 56, @intFromPtr(thumbnail.jpeg.?.ptr));
    var invalid = bytes.*;
    invalid[36] = 57;
    try std.testing.expectError(error.InvalidExif, (try View.open(&invalid, .{})).thumbnail());
    invalid = bytes.*;
    invalid[24] = 1;
    invalid[28] = 0x11;
    invalid[29] = 0x01;
    invalid[40] = 0x17;
    invalid[41] = 0x01;
    var strips = try (try (try View.open(&invalid, .{})).thumbnail()).?.directory.strips();
    try std.testing.expectEqualSlices(u8, "\xff\xd8\xff\xd9", (try strips.strip(0)).?);
    try std.testing.expectEqual(0, strips.index);
    try std.testing.expectEqual(null, try strips.strip(1));
    try std.testing.expectEqualSlices(u8, "\xff\xd8\xff\xd9", (try strips.next()).?);
    try std.testing.expectEqual(null, try strips.next());
}

test "Exif unknown fields remain opaque and duplicate selected tags are invalid" {
    var unknown = testing_exif.little_orientation[0..].*;
    unknown[12] = 0x80;
    const directory = try (try View.open(&unknown, .{})).primary();
    try std.testing.expectEqual(0x80, directory.entry(0).?.field_type);
    try std.testing.expectError(error.UnsupportedExif, directory.entry(0).?.data());
    const duplicate = testing_exif.duplicate_orientation[0..];
    try std.testing.expectError(error.InvalidExif, (try View.open(duplicate, .{})).orientation());
}

test "unsigned TIFF fields preserve scalar metadata aliases and checked offsets" {
    // Independent TIFF structure: IFD0 at 8 has orientation and a child pointer; child IFD at 38 is
    // empty; IFD1 at 44 points to four opaque JPEG bytes at 86.
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        for ([_]u16{ 1, 3, 4 }) |field_type| {
            var bytes: [90]u8 = @splat(0);
            @memcpy(bytes[0..2], if (endian == .little) "II" else "MM");
            std.mem.writeInt(u16, bytes[2..4], 42, endian);
            std.mem.writeInt(u32, bytes[4..8], 8, endian);
            std.mem.writeInt(u16, bytes[8..10], 2, endian);
            std.mem.writeInt(u32, bytes[34..38], 44, endian);
            std.mem.writeInt(u16, bytes[44..46], 3, endian);
            @memcpy(bytes[86..90], "\xff\xd8\xff\xd9");
            const fields = [_]struct {
                offset: usize,
                tag: u16,
                value: u32,
            }{
                .{ .offset = 10, .tag = 0x0112, .value = 6 },
                .{ .offset = 22, .tag = 0x8769, .value = 38 },
                .{ .offset = 46, .tag = 0x0103, .value = 6 },
                .{ .offset = 58, .tag = 0x0201, .value = 86 },
                .{ .offset = 70, .tag = 0x0202, .value = 4 },
            };
            for (fields) |field| {
                const entry = bytes[field.offset..][0..12];
                std.mem.writeInt(u16, entry[0..2], field.tag, endian);
                std.mem.writeInt(u16, entry[2..4], field_type, endian);
                std.mem.writeInt(u32, entry[4..8], 1, endian);
                switch (field_type) {
                    1 => entry[8] = @intCast(field.value),
                    3 => std.mem.writeInt(u16, entry[8..10], @intCast(field.value), endian),
                    4 => std.mem.writeInt(u32, entry[8..12], field.value, endian),
                    else => unreachable,
                }
            }
            const view = try View.open(&bytes, .{});
            try std.testing.expectEqual(.right_top, (try view.orientation()).?);
            const child_directory = (try (try view.primary()).child(0x8769)).?;
            try std.testing.expectEqual(38, child_directory.offset);
            try std.testing.expectEqual(0, child_directory.count);
            const thumbnail = (try view.thumbnail()).?;
            try std.testing.expectEqualSlices(u8, "\xff\xd8\xff\xd9", thumbnail.jpeg.?);
            try std.testing.expectEqual(
                @intFromPtr(&bytes) + 86,
                @intFromPtr(thumbnail.jpeg.?.ptr),
            );

            const original = bytes;
            std.mem.writeInt(u32, bytes[14..18], 2, endian);
            try std.testing.expectError(
                error.InvalidExif,
                (try View.open(&bytes, .{})).orientation(),
            );
            bytes = original;
            std.mem.writeInt(u16, bytes[12..14], 9, endian);
            try std.testing.expectError(
                error.InvalidExif,
                (try View.open(&bytes, .{})).orientation(),
            );
            bytes = original;
            @memset(bytes[78..82], 0);
            try std.testing.expectError(
                error.InvalidExif,
                (try View.open(&bytes, .{})).thumbnail(),
            );
            bytes = original;
            switch (field_type) {
                1 => bytes[78] = 5,
                3 => std.mem.writeInt(u16, bytes[78..80], 5, endian),
                4 => std.mem.writeInt(u32, bytes[78..82], 5, endian),
                else => unreachable,
            }
            try std.testing.expectError(
                error.InvalidExif,
                (try View.open(&bytes, .{})).thumbnail(),
            );
        }
    }
}

test "Exif combined record admission bounds main chains and selected directories" {
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        // Two main IFDs: IFD0 is empty; IFD1 has one orientation entry, three total records.
        var bytes: [32]u8 = @splat(0);
        @memcpy(bytes[0..2], if (endian == .little) "II" else "MM");
        std.mem.writeInt(u16, bytes[2..4], 42, endian);
        std.mem.writeInt(u32, bytes[4..8], 8, endian);
        std.mem.writeInt(u32, bytes[10..14], 14, endian);
        std.mem.writeInt(u16, bytes[14..16], 1, endian);
        std.mem.writeInt(u16, bytes[16..18], 0x0112, endian);
        std.mem.writeInt(u16, bytes[18..20], 3, endian);
        std.mem.writeInt(u32, bytes[20..24], 1, endian);
        std.mem.writeInt(u16, bytes[24..26], 6, endian);
        for (
            0..3,
        ) |maximum| try std.testing.expectError(
            error.MetadataLimitExceeded,
            View.open(&bytes, .{ .limits = .{ .records = maximum } }),
        );
        const view = try View.open(&bytes, .{ .limits = .{ .records = 3 } });
        try std.testing.expectEqual(3, view.record_count);
        const selected = try view.directoryAt(14);
        try std.testing.expectEqual(1, selected.count);
        try std.testing.expectEqual(6, try (try selected.find(0x0112)).?.unsignedScalar());

        // The first header is admitted before its next offset is selected. Under a two-record
        // policy, the later directory's count is read but its short body is not.
        try std.testing.expectError(
            error.MetadataLimitExceeded,
            View.open(bytes[0..16], .{ .limits = .{ .records = 2 } }),
        );
        try std.testing.expectError(
            error.InvalidExif,
            View.open(bytes[0..16], .{ .limits = .{ .records = 3 } }),
        );
        std.mem.writeInt(u32, bytes[10..14], 1, endian);
        try std.testing.expectError(
            error.MetadataLimitExceeded,
            View.open(&bytes, .{ .limits = .{ .records = 1 } }),
        );
        try std.testing.expectError(
            error.InvalidExif,
            View.open(&bytes, .{ .limits = .{ .records = 2 } }),
        );

        // Child selection is independent of the main-chain total. Its own header and entries still
        // must fit the same ceiling, before checking the entry body.
        std.mem.writeInt(u32, bytes[10..14], 0, endian);
        const primary_only = try View.open(&bytes, .{ .limits = .{ .records = 1 } });
        try std.testing.expectEqual(1, primary_only.record_count);
        try std.testing.expectError(error.MetadataLimitExceeded, primary_only.directoryAt(14));
        const child_allowed = try View.open(&bytes, .{ .limits = .{ .records = 2 } });
        try std.testing.expectEqual(1, (try child_allowed.directoryAt(14)).count);
    }
}
