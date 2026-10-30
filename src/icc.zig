//! ICC color profiles describe how device color values relate to standard color spaces. Inspect
//! their v2/v4 headers and opaque tag storage without allocating memory or applying a transform.
//!
//! Pass the complete uncompressed profile's used byte prefix to `Profile.open`, with a tag-count
//! limit. Opening checks declared size, file signature, major version, rendering intent, tag bounds
//! and alignment. It admits shared tag bodies; selecting a duplicate tag signature is an error. V4
//! requires zero tag padding, while v2 permits an unpadded final body.
//!
//! Header fields are copied values. `Profile`, `Tag` and tag payloads borrow the original bytes;
//! keep them live and unchanged through their last use. No cleanup is needed. The `Profile.open`
//! example demonstrates inspection and tag selection.
//!
//! Each body range is checked independently. Admission does not require contiguous or disjoint
//! bodies, validate other header encodings or establish complete ICC conformance. Tag bodies remain
//! opaque: transform mathematics, required-tag completeness and agreement with an enclosing image's
//! channels are not checked. Applications select and apply color transforms. PNG profile expansion
//! and JPEG profile assembly are container work.
//!
//! References: https://www.color.org/specification/ICC.1-2001-04.pdf and
//! https://www.color.org/specification/ICC.1-2022-05.pdf

const std = @import("std");

/// Selected malformed, unsupported or over-budget ICC metadata.
pub const Error = error{ InvalidIcc, UnsupportedIcc, MetadataLimitExceeded };

/// Structural tag-table admission, independent of profile backing allocation.
pub const Limits = struct {
    /// Required maximum tag count; no implicit allowance is selected.
    tags: usize,
};

/// Admission for one borrowed profile; tag bodies remain opaque.
pub const InspectOptions = struct { limits: Limits };

/// Borrowed ICC v2/v4 storage with checked header fields and body ranges; no allocation occurs.
/// Construct with `open` and preserve `source` and `tag_count` for checked tag access. Copies
/// borrow the same backing, which must stay live and unchanged through the last use.
pub const Profile = struct {
    /// Complete declared profile bytes, live and unchanged through the last tag borrow.
    source: []const u8,
    /// Four encoded version bytes; the first names major version 2 or 4.
    version: [4]u8,
    /// Encoded device/profile class signature, such as `mntr`.
    device_class: [4]u8,
    /// Encoded input color-space signature, such as `RGB ` or `CMYK`.
    color_space: [4]u8,
    /// Encoded profile connection-space signature, typically `XYZ ` or `Lab `.
    connection_space: [4]u8,
    /// Header rendering-intent declaration, 0–3; no transform is selected or applied.
    rendering_intent: u32,
    /// Number of checked tag records.
    tag_count: u32,

    /// Checks the bounded header/tag structure, including every tag's payload range. V4 length
    /// includes final alignment padding; every tag's pad bytes must be zero. V2 requires aligned
    /// starts without imposing those v4 padding rules. `limits.tags` is independent of the profile
    /// byte allocation limit imposed by its owner.
    pub fn open(source: []const u8, options: InspectOptions) Error!Profile {
        const maximum_tags = options.limits.tags;
        if (source.len < 132) return error.InvalidIcc;
        const declared_size = readU32(source, 0);
        if (declared_size != source.len or !std.mem.eql(
            u8,
            source[36..40],
            "acsp",
        )) return error.InvalidIcc;
        const major_version = source[8];
        if (major_version != 2 and major_version != 4) return error.UnsupportedIcc;
        if (major_version == 4 and source.len % 4 != 0) return error.InvalidIcc;
        const rendering_intent = readU32(source, 64);
        if (rendering_intent > 3) return error.InvalidIcc;
        const tag_count = readU32(source, 128);
        if (tag_count > maximum_tags) return error.MetadataLimitExceeded;
        const tag_table_bytes = std.math.mul(usize, tag_count, 12) catch return error.InvalidIcc;
        if (tag_table_bytes > source.len - 132) return error.InvalidIcc;
        const table_end = 132 + tag_table_bytes;
        const profile: Profile = .{
            .source = source,
            .version = source[8..12].*,
            .device_class = source[12..16].*,
            .color_space = source[16..20].*,
            .connection_space = source[20..24].*,
            .rendering_intent = rendering_intent,
            .tag_count = tag_count,
        };
        for (0..tag_count) |index| {
            const record = profile.tagRecord(index);
            const body_offset = readU32(record, 4);
            const body_bytes = readU32(record, 8);
            if (body_offset % 4 != 0 or body_offset < table_end or body_offset > source.len or
                body_bytes < 8 or body_bytes > source.len - body_offset) return error.InvalidIcc;
            if (major_version == 4) {
                // ICC.1 7.1.2 and 7.2.2 include the last element's zero padding in profile length,
                // while 7.3.5 excludes it from the tag body. The aligned offset/profile end and
                // checked body guarantee this suffix fits.
                const body_end = @as(usize, body_offset) + body_bytes;
                const padding_bytes = (4 - body_bytes % 4) % 4;
                if (!std.mem.allEqual(
                    u8,
                    source[body_end..][0..padding_bytes],
                    0,
                )) return error.InvalidIcc;
            }
        }
        return profile;
    }

    test open {
        // Authored storage control; not a complete color-management profile.
        const bytes = storage: {
            var input: [156]u8 = @splat(0);
            input[3] = 156;
            input[8] = 4;
            @memcpy(input[12..24], "mntrRGB XYZ ");
            @memcpy(input[36..40], "acsp");
            input[131] = 1;
            @memcpy(input[132..136], "desc");
            input[139] = 144;
            input[143] = 12;
            @memcpy(input[144..148], "text");
            @memcpy(input[152..156], "abc\x00");
            break :storage input;
        };
        const profile = try Profile.open(&bytes, .{ .limits = .{ .tags = 1 } });
        try std.testing.expectEqualStrings("RGB ", &profile.color_space);
        try std.testing.expectEqualStrings("XYZ ", &profile.connection_space);
        try std.testing.expectEqualStrings("mntr", &profile.device_class);
        try std.testing.expectEqual(4, profile.version[0]);
        const description = (try profile.find("desc".*)).?;
        try std.testing.expectEqualSlices(u8, "text\x00\x00\x00\x00abc\x00", description.data);
        try std.testing.expectEqual(@intFromPtr(&bytes) + 144, @intFromPtr(description.data.ptr));
        try std.testing.expectEqual(null, profile.tag(1));
        try std.testing.expectEqual(null, try profile.find("rXYZ".*));
    }

    /// Borrows one tag record and its prechecked opaque body; null means out of range. Different
    /// tags may legally share the same payload storage.
    pub fn tag(self: Profile, index: usize) ?Tag {
        if (index >= self.tag_count) return null;
        const record = self.tagRecord(index);
        const body_offset = readU32(record, 4);
        const body_bytes = readU32(record, 8);
        return .{ .signature = record[0..4].*, .data = self.source[body_offset..][0..body_bytes] };
    }

    /// Selects a unique tag by its raw signature; duplicate selected signatures are malformed.
    pub fn find(self: Profile, signature: [4]u8) Error!?Tag {
        var found: ?usize = null;
        for (0..self.tag_count) |index| {
            const record = self.tagRecord(index);
            if (!std.mem.eql(u8, record[0..4], &signature)) continue;
            if (found != null) return error.InvalidIcc;
            found = index;
        }
        return self.tag(found orelse return null);
    }

    fn tagRecord(self: Profile, index: usize) *const [12]u8 {
        // Callers bound the index by the complete table admitted by open.
        const record_offset = 132 + index * 12;
        return self.source[record_offset..][0..12];
    }
};

/// One checked ICC tag storage range; body semantics remain the caller's responsibility.
pub const Tag = struct {
    /// Encoded tag signature; this is separate from the body's type signature.
    signature: [4]u8,
    /// Complete tag body excluding profile alignment padding, borrowed from the profile.
    data: []const u8,
};

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

// Independent ICC container facts: one desc tag at 144, size 12, type text.
const testing_icc = struct {
    /// Constructs the complete small frozen profile, without consulting the reader.
    fn minimalProfile() [156]u8 {
        var bytes: [156]u8 = @splat(0);
        bytes[3] = 156;
        bytes[8] = 4;
        @memcpy(bytes[12..24], "mntrRGB XYZ ");
        @memcpy(bytes[36..40], "acsp");
        bytes[131] = 1;
        @memcpy(bytes[132..136], "desc");
        bytes[139] = 144;
        bytes[143] = 12;
        @memcpy(bytes[144..148], "text");
        @memcpy(bytes[152..156], "abc\x00");
        return bytes;
    }
};

// Independent ICC storage facts: three unsorted signatures share a 14-byte curve at 168. The final
// two padding bytes belong to the profile, not the tag body (ICC.1 7.3–7.4). This checks container
// storage, without constructing a complete color-management profile.
fn sharedCurvesProfile() [184]u8 {
    var bytes: [184]u8 = @splat(0);
    bytes[3] = 184;
    bytes[8] = 4;
    @memcpy(bytes[12..24], "mntrRGB XYZ ");
    @memcpy(bytes[36..40], "acsp");
    bytes[131] = 3;
    @memcpy(
        bytes[132..168],
        "bTRC\x00\x00\x00\xa8\x00\x00\x00\x0erTRC\x00\x00\x00\xa8\x00\x00\x00\x0egTRC\x00\x00" ++
            "\x00\xa8\x00\x00\x00\x0e",
    );
    @memcpy(bytes[168..184], "curv\x00\x00\x00\x00\x00\x00\x00\x01\x01\x00\x00\x00");
    return bytes;
}

test "ICC malformed table alignment lengths version and limits fail independently" {
    const valid = testing_icc.minimalProfile();
    for (0..valid.len) |end| {
        try std.testing.expectError(
            error.InvalidIcc,
            Profile.open(valid[0..end], .{ .limits = .{ .tags = 1 } }),
        );
    }
    for (
        [_]struct {
            offset: usize,
            value: u8,
        }{
            .{ .offset = 3, .value = 155 },
            .{ .offset = 36, .value = 'x' },
            .{ .offset = 67, .value = 4 },
            .{ .offset = 131, .value = 2 },
            .{ .offset = 139, .value = 145 },
            .{ .offset = 139, .value = 140 },
            .{ .offset = 143, .value = 13 },
            .{ .offset = 143, .value = 7 },
        },
    ) |change| {
        var invalid = valid;
        invalid[change.offset] = change.value;
        try std.testing.expectError(
            error.InvalidIcc,
            Profile.open(&invalid, .{ .limits = .{ .tags = 2 } }),
        );
    }
    var version = valid;
    version[8] = 5;
    try std.testing.expectError(
        error.UnsupportedIcc,
        Profile.open(&version, .{ .limits = .{ .tags = 1 } }),
    );
    version[8] = 2;
    _ = try Profile.open(&version, .{ .limits = .{ .tags = 1 } });
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        Profile.open(&valid, .{ .limits = .{ .tags = 0 } }),
    );
}

test "ICC unsorted tags borrow shared payloads without their alignment padding" {
    for ([_]u8{ 2, 4 }) |major| {
        var bytes = sharedCurvesProfile();
        bytes[8] = major;
        const profile = try Profile.open(&bytes, .{ .limits = .{ .tags = 3 } });
        try std.testing.expectEqual(3, profile.tag_count);
        for ([_][4]u8{ "bTRC".*, "rTRC".*, "gTRC".* }, 0..) |signature, index| {
            const indexed = profile.tag(index).?;
            const selected = (try profile.find(signature)).?;
            try std.testing.expectEqual(signature, indexed.signature);
            try std.testing.expectEqualSlices(
                u8,
                "curv\x00\x00\x00\x00\x00\x00\x00\x01\x01\x00",
                selected.data,
            );
            try std.testing.expectEqual(@intFromPtr(&bytes) + 168, @intFromPtr(selected.data.ptr));
            try std.testing.expectEqual(
                @intFromPtr(indexed.data.ptr),
                @intFromPtr(selected.data.ptr),
            );
        }
        try std.testing.expectEqual(null, profile.tag(3));
        try std.testing.expectEqual(null, try profile.find("wtpt".*));
        try std.testing.expectError(
            error.MetadataLimitExceeded,
            Profile.open(&bytes, .{ .limits = .{ .tags = 2 } }),
        );
    }
}

test "ICC duplicate selection fails even when both records share identical storage" {
    var bytes = sharedCurvesProfile();
    @memcpy(bytes[156..160], "bTRC");
    const profile = try Profile.open(&bytes, .{ .limits = .{ .tags = 3 } });
    try std.testing.expectError(error.InvalidIcc, profile.find("bTRC".*));
    const unique = (try profile.find("rTRC".*)).?;
    try std.testing.expectEqual(@intFromPtr(&bytes) + 168, @intFromPtr(unique.data.ptr));
    try std.testing.expectEqual(null, try profile.find("gTRC".*));
    try std.testing.expectEqual("bTRC".*, profile.tag(2).?.signature);
}

test "ICC v4 declared length includes final padding while v2 retains unpadded bodies" {
    for (8..13) |body_bytes| {
        var bytes = testing_icc.minimalProfile();
        const body_end = 144 + body_bytes;
        const padded_end = (body_end + 3) / 4 * 4;
        std.mem.writeInt(u32, bytes[140..144], @intCast(body_bytes), .big);
        @memset(bytes[body_end..padded_end], 0);
        for ([_]u8{ 2, 4 }) |version| {
            bytes[8] = version;
            for (body_end..padded_end + 1) |length| {
                std.mem.writeInt(u32, bytes[0..4], @intCast(length), .big);
                const source = bytes[0..length];
                if (version == 4 and length != padded_end) {
                    try std.testing.expectError(
                        error.InvalidIcc,
                        Profile.open(source, .{ .limits = .{ .tags = 1 } }),
                    );
                } else {
                    const profile = try Profile.open(source, .{ .limits = .{ .tags = 1 } });
                    const tag = profile.tag(0).?;
                    try std.testing.expectEqual(body_bytes, tag.data.len);
                    try std.testing.expectEqual(
                        @intFromPtr(&bytes) + 144,
                        @intFromPtr(tag.data.ptr),
                    );
                    try std.testing.expectEqual(length, profile.source.len);
                }
            }
        }
    }
}

test "ICC v4 shared tag padding is zero while v2 preserves opaque trailing bytes" {
    for (182..184) |offset| for (1..256) |value| {
        var bytes = sharedCurvesProfile();
        bytes[offset] = @intCast(value);
        try std.testing.expectError(
            error.InvalidIcc,
            Profile.open(&bytes, .{ .limits = .{ .tags = 3 } }),
        );
        bytes[8] = 2;
        const profile = try Profile.open(&bytes, .{ .limits = .{ .tags = 3 } });
        for (0..3) |index| {
            const tag = profile.tag(index).?;
            try std.testing.expectEqual(14, tag.data.len);
            try std.testing.expectEqual(@intFromPtr(&bytes) + 168, @intFromPtr(tag.data.ptr));
        }
    };
}

test "ICC v4 checks padding after nonfinal tags independently of opaque body bytes" {
    // Independent container facts: table ends at 156; a nine-byte text body and its three zero pads
    // precede an eight-byte opaque body at 168. Signatures are unsorted.
    var bytes: [176]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], bytes.len, .big);
    bytes[8] = 4;
    @memcpy(bytes[36..40], "acsp");
    std.mem.writeInt(u32, bytes[128..132], 2, .big);
    @memcpy(
        bytes[132..156],
        "zzzz\x00\x00\x00\x9c\x00\x00\x00\x09aaaa\x00\x00\x00\xa8\x00\x00\x00\x08",
    );
    @memcpy(bytes[156..164], "text\x00\x00\x00\x00");
    @memset(bytes[168..176], 0xa5); // Tag semantics remain outside storage admission.
    const profile = try Profile.open(&bytes, .{ .limits = .{ .tags = 2 } });
    try std.testing.expectEqual(9, profile.tag(0).?.data.len);
    try std.testing.expectEqualSlices(u8, &(@as([8]u8, @splat(0xa5))), profile.tag(1).?.data);
    for (165..168) |offset| {
        bytes[offset] = 1;
        try std.testing.expectError(
            error.InvalidIcc,
            Profile.open(&bytes, .{ .limits = .{ .tags = 2 } }),
        );
        bytes[offset] = 0;
    }
}

test "ICC admission checks the final payload even when earlier tags share valid storage" {
    const valid = sharedCurvesProfile();
    for ([_]struct { offset: u32, size: u32 }{
        .{ .offset = 164, .size = 14 }, // Inside the tag table.
        .{ .offset = 169, .size = 14 }, // Unaligned payload.
        .{ .offset = 184, .size = 8 }, // Starts at the profile end.
        .{ .offset = 168, .size = 17 }, // Extends beyond the profile.
        .{ .offset = 168, .size = 7 }, // Omits part of the type/reserved header.
    }) |range| {
        var invalid = valid;
        std.mem.writeInt(u32, invalid[160..164], range.offset, .big);
        std.mem.writeInt(u32, invalid[164..168], range.size, .big);
        try std.testing.expectError(
            error.InvalidIcc,
            Profile.open(&invalid, .{ .limits = .{ .tags = 3 } }),
        );
    }
}
