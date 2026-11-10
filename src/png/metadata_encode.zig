//! Typed PNG metadata validation, compression and chunk emission.

const AnimationInput = @import("AnimationInput.zig");
const SourceImage = @import("Source.zig");
const ImageInput = @import("ImageInput.zig");
const MetadataInput = @import("metadata.zig").Metadata.Input;
const owned_decode = @import("image_decode.zig");
const std = @import("std");
const png_format = @import("format.zig");
const test_encoding = @import("image_encode.zig");
const zlib = @import("../zlib.zig");
const deflate = @import("../deflate.zig");
const encoding_workspace = @import("encode_workspace.zig");
const Limits = @import("Limits.zig");
const icc = @import("../icc.zig");
const exif = @import("../exif.zig");
const metadata = @import("metadata.zig");
const chunks = @import("ChunkWriter.zig");
const apng = @import("animation_encode.zig");
const png_encoding_vectors = @import("testdata/encoding.zig");

const EncodingStorage = encoding_workspace.Workspace;
const encoding_fixtures = png_encoding_vectors;

/// Checked metadata, profile, TIFF, resource, allocation and backing-writer errors.
pub const Error = metadata.Metadata.Error || icc.Error || exif.Error || chunks.Error || Limits
    .Error || EncodingStorage.Error || encoding_workspace.WriteError || std.mem.Allocator.Error ||
    error{
        SizeOverflow,
    };

/// Checks selected records and creates a small immutable borrow, allocating no storage. Color/depth
/// must describe a valid PNG layout. Source metadata and later encoded payloads are both bounded;
/// structural counts include ICC tags and Exif main entries/directories.
pub fn prepare(self: MetadataInput, color_type: u8, depth: u8, limits: Limits) Error!Prepared {
    comptime {
        if (@typeInfo(
            MetadataInput,
        ).@"struct".field_names.len != 11) @compileError(
            "update the empty metadata fast path for changed fields",
        );
    }
    if (self.gamma == null and self.chromaticities == null and self.srgb_intent == null and self
        .cicp == null and self.mastering_display == null and self.content_light == null and self
        .significant_bits == null and self.icc_profile == null and self.exif_payload == null and
        self.physical == null and self.texts.len == 0)
    {
        return .{
            .value = self,
            .record_count = 0,
            .source_bytes = 0,
            .work_units = 0,
            .maximum_payload_bytes = limits.maximum_metadata_bytes,
        };
    }
    var records: usize = 0;
    var source_bytes: usize = 0;
    if (self.gamma) |value| {
        try metadata.validateInteger(value);
        if (value == 0) return error.InvalidPngMetadata;
        records += 1;
        source_bytes += 4;
    }
    if (self.chromaticities) |values| {
        for (values) |value| try metadata.validateInteger(value);
        records += 1;
        source_bytes += 32;
    }
    if (self.srgb_intent) |intent| {
        if (intent > 3) return error.InvalidPngMetadata;
        if (self.gamma) |gamma| if (gamma != 45455) return error.InvalidPngMetadata;
        if (self.chromaticities) |values| {
            if (!std.mem.eql(u32, &values, &srgb_chromaticities)) return error.InvalidPngMetadata;
        }
        records += 1;
        source_bytes += 1;
    }
    if (self.cicp) |value| {
        if (value.matrix != 0) return error.InvalidPngMetadata;
        records += 1;
        source_bytes += 4;
    }
    if (self.mastering_display) |value| {
        if (self.cicp == null) return error.InvalidPngMetadata;
        try metadata.validateInteger(value.maximum_luminance);
        try metadata.validateInteger(value.minimum_luminance);
        records += 1;
        source_bytes += 24;
    }
    if (self.content_light) |value| {
        try metadata.validateInteger(value.maximum_content);
        try metadata.validateInteger(value.maximum_frame_average);
        records += 1;
        source_bytes += 8;
    }
    if (self.significant_bits) |values| {
        try metadata.validateSignificantBits(values, color_type, depth);
        records += 1;
        source_bytes += values.len;
    }
    if (self.physical) |value| {
        try metadata.validateInteger(value.x);
        try metadata.validateInteger(value.y);
        records += 1;
        source_bytes += 9;
    }
    // Bound bytes before traversing arbitrary profile/TIFF records or text data.
    if (self.icc_profile) |profile| {
        try metadata.validateKeyword(profile.name);
        source_bytes = try add(source_bytes, try add(profile.name.len + 2, profile.bytes.len));
        records = try add(records, 1);
    }
    if (self.exif_payload) |bytes| {
        source_bytes = try add(source_bytes, bytes.len);
        records = try add(records, 1);
    }
    for (self.texts) |text| {
        try metadata.validateKeyword(text.keyword);
        var count = try add(text.keyword.len, text.data.len);
        count = try add(
            count,
            if (text.encoding == .utf8) try add(
                try add(text.language.len, text.translated_keyword.len),
                5,
            ) else if (text.compress) 2 else 1,
        );
        source_bytes = try add(source_bytes, count);
        records = try add(records, 1);
        if (source_bytes > limits.maximum_metadata_bytes or records > limits.maximum_records)
            return error.MetadataLimitExceeded;
    }
    if (source_bytes > limits.maximum_metadata_bytes or records > limits.maximum_records)
        return error.MetadataLimitExceeded;
    // Three possible compression passes plus validation; generic match search is method-owned.
    const work = std.math.mul(usize, source_bytes, 4) catch return error.SizeOverflow;
    try png_format.admitWork(limits, work);
    if (self.icc_profile) |profile| {
        const checked = try icc.Profile.open(
            profile.bytes,
            .{ .limits = .{ .tags = limits.maximum_records - records } },
        );
        const expected = if (color_type == 0 or color_type == 4) "GRAY" else "RGB ";
        if (!std.mem.eql(u8, &checked.color_space, expected)) return error.InvalidPngMetadata;
        records = try add(records, checked.tag_count);
    }
    if (self.exif_payload) |bytes| {
        const checked = try exif.View.open(
            bytes,
            .{
                .limits = .{
                    .directories = limits.maximum_records - records,
                    .entries = limits.maximum_records - records,
                    .records = limits.maximum_records - records,
                },
            },
        );
        records = try add(records, checked.record_count);
    }
    if (records > limits.maximum_records) return error.MetadataLimitExceeded;
    for (self.texts) |text| {
        try metadata.validateText(text.data, text.encoding == .utf8);
        if (text.encoding == .utf8) {
            try metadata.validateLanguage(text.language);
            try metadata.validateText(text.translated_keyword, true);
        } else if (text.language.len != 0 or text.translated_keyword.len != 0)
            return error.InvalidPngMetadata;
    }
    if (requiresCompression(
        self,
    ) and compressor_bytes > limits.maximum_scratch_bytes) return error.ScratchBudgetExceeded;
    return .{
        .value = self,
        .record_count = records,
        .source_bytes = source_bytes,
        .work_units = work,
        .maximum_payload_bytes = limits.maximum_metadata_bytes,
    };
}

/// Checked metadata descriptor created only by prepare; preserve its validated value and counters.
/// Source bytes must remain unchanged from prepare through the final count or write. These
/// operations validate compression options even when no selected record uses compression.
pub const Prepared = struct {
    /// Metadata borrowed from prepare; its slices remain caller-owned and immutable.
    value: MetadataInput,
    /// PNG chunks plus selected ICC/TIFF structural records.
    record_count: usize,
    /// Uncompressed selected metadata payload/keyword bytes.
    source_bytes: usize,
    /// Conservative validation/compression input-byte work reservation.
    work_units: usize,
    /// Current combined encoded metadata payload limit; APNG emission can tighten the prepared
    /// limit after counting actual frame-data sequence bytes.
    maximum_payload_bytes: usize,

    /// Counts exact framed bytes, releasing every compression temporary before return. Neither the
    /// compression options nor allocator are retained.
    pub fn encodedSizeWithScratch(
        self: Prepared,
        allocator: std.mem.Allocator,
        compression: zlib.Compression,
    ) Error!usize {
        return self.emit(null, .{ .allocator = allocator }, compression);
    }

    /// Writes complete metadata chunks into caller storage and returns bytes used. Source must
    /// remain unchanged since preparation and any earlier count. Failure may leave a chunk prefix;
    /// each temporary workspace is released. A compressed record that fits the local counting
    /// buffer is reused, while a larger one is compressed again for emission.
    pub fn writeIntoWithScratch(
        self: Prepared,
        allocator: std.mem.Allocator,
        destination: []u8,
        compression: zlib.Compression,
    ) Error!usize {
        return self.emit(destination, .{ .allocator = allocator }, compression);
    }

    /// Reports framed capacity without compression or allocation. Compressed records use the native
    /// zlib bound; this is capacity, not actual metadata size or resource consumption.
    pub fn capacityBound(self: Prepared) Error!usize {
        return self.emit(null, .bound, .{ .level = 0 });
    }

    /// Compresses selected records once into reserved capacity, reusing the caller's state. Source,
    /// workspace and destination stay disjoint. Success preserves unused capacity; failure may
    /// leave an unpublished prefix. No allocation or retained borrow occurs.
    pub fn writeInto(
        self: Prepared,
        destination: []u8,
        workspace: EncodingStorage,
        compression: zlib.Compression,
    ) Error!usize {
        return self.emit(destination, .{ .workspace = workspace }, compression);
    }

    fn emit(
        self: Prepared,
        destination: ?[]u8,
        mode: EmissionMode,
        compression: zlib.Compression,
    ) Error!usize {
        try compression.validate();
        const value = self.value;
        var output: Encoder = .{
            .destination = destination,
            .mode = mode,
            .compression = compression,
            .maximum_payload_bytes = self.maximum_payload_bytes,
        };
        if (value.gamma) |gamma| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, gamma, .big);
            try output.encodeChunk("gAMA", &.{&bytes}, null);
        }
        if (value.chromaticities) |values| {
            var bytes: [32]u8 = undefined;
            for (values, 0..) |number, index| {
                std.mem.writeInt(u32, bytes[index * 4 ..][0..4], number, .big);
            }
            try output.encodeChunk("cHRM", &.{&bytes}, null);
        }
        if (value.srgb_intent) |intent| try output.encodeChunk("sRGB", &.{&.{intent}}, null);
        if (value.cicp) |color| {
            const bytes = [_]u8{
                color.primaries,
                color.transfer,
                color.matrix,
                @intFromBool(color.full_range),
            };
            try output.encodeChunk("cICP", &.{&bytes}, null);
        }
        if (value.mastering_display) |display| {
            var bytes: [24]u8 = undefined;
            for (display.primaries, 0..) |pair, index| {
                std.mem.writeInt(u16, bytes[index * 4 ..][0..2], pair[0], .big);
                std.mem.writeInt(u16, bytes[index * 4 + 2 ..][0..2], pair[1], .big);
            }
            std.mem.writeInt(u16, bytes[12..14], display.white_point[0], .big);
            std.mem.writeInt(u16, bytes[14..16], display.white_point[1], .big);
            std.mem.writeInt(u32, bytes[16..20], display.maximum_luminance, .big);
            std.mem.writeInt(u32, bytes[20..24], display.minimum_luminance, .big);
            try output.encodeChunk("mDCV", &.{&bytes}, null);
        }
        if (value.content_light) |light| {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u32, bytes[0..4], light.maximum_content, .big);
            std.mem.writeInt(u32, bytes[4..8], light.maximum_frame_average, .big);
            try output.encodeChunk("cLLI", &.{&bytes}, null);
        }
        if (value.significant_bits) |bits| try output.encodeChunk("sBIT", &.{bits}, null);
        if (value.icc_profile) |profile| try output.encodeChunk(
            "iCCP",
            &.{ profile.name, &[_]u8{ 0x00, 0x00 } },
            profile.bytes,
        );
        if (value.exif_payload) |bytes| try output.encodeChunk("eXIf", &.{bytes}, null);
        if (value.physical) |physical| {
            var bytes: [9]u8 = undefined;
            std.mem.writeInt(u32, bytes[0..4], physical.x, .big);
            std.mem.writeInt(u32, bytes[4..8], physical.y, .big);
            bytes[8] = @intFromBool(physical.metres);
            try output.encodeChunk("pHYs", &.{&bytes}, null);
        }
        for (value.texts) |text| {
            if (text.encoding == .utf8) {
                const flag = [_]u8{ 0, @intFromBool(text.compress), 0 };
                if (text.compress) {
                    try output.encodeChunk(
                        "iTXt",
                        &.{
                            text.keyword,
                            &flag,
                            text.language,
                            &[_]u8{0x00},
                            text.translated_keyword,
                            &[_]u8{0x00},
                        },
                        text.data,
                    );
                } else try output.encodeChunk(
                    "iTXt",
                    &.{
                        text.keyword,
                        &flag,
                        text.language,
                        &[_]u8{0x00},
                        text.translated_keyword,
                        &[_]u8{0x00},
                        text.data,
                    },
                    null,
                );
            } else if (text.compress) {
                try output.encodeChunk("zTXt", &.{ text.keyword, &[_]u8{ 0x00, 0x00 } }, text.data);
            } else try output.encodeChunk(
                "tEXt",
                &.{ text.keyword, &[_]u8{0x00}, text.data },
                null,
            );
        }
        return output.offset;
    }
};

// Each selected writer uses either call-local authority, prepared state or pure bound arithmetic.
const EmissionMode = union(enum) {
    allocator: std.mem.Allocator,
    workspace: EncodingStorage,
    bound,
};

pub const Encoder = struct {
    destination: ?[]u8,
    mode: EmissionMode,
    compression: zlib.Compression,
    maximum_payload_bytes: usize,
    offset: usize = 0,
    payload_bytes: usize = 0,

    fn encodeChunk(
        self: *Encoder,
        name: *const [4]u8,
        parts: []const []const u8,
        uncompressed: ?[]const u8,
    ) Error!void {
        var count: usize = 0;
        for (parts) |part| count = try add(count, part.len);
        if (uncompressed) |source| {
            if (self.mode != .allocator) {
                const capacity = try add(count, try zlib.encodeBound(source.len, .{}));
                const framed = try chunks.byteCount(capacity);
                if (self.mode == .bound) {
                    self.offset = try add(self.offset, framed);
                    return;
                }
                const destination = self.destination.?;
                if (self.offset > destination.len) return error.OutputTooSmall;
                var chunk_writer: chunks = undefined;
                try chunk_writer.init(destination[self.offset..], name, capacity);
                for (parts) |part| try chunk_writer.writer.writeAll(part);
                try compress(source, &chunk_writer.writer, self.mode, self.compression);
                const used = try chunk_writer.finishPrefix();
                self.payload_bytes = try add(self.payload_bytes, used - 12);
                if (self.payload_bytes > self.maximum_payload_bytes)
                    return error.MetadataLimitExceeded;
                self.offset = try add(self.offset, used);
                return;
            }
        }
        var buffer: [64]u8 = undefined;
        var counter: std.Io.Writer.Discarding = .init(&buffer);
        if (uncompressed) |source| {
            try compress(source, &counter.writer, self.mode, self.compression);
            const compressed_count = std.math.cast(
                usize,
                counter.fullCount(),
            ) orelse return error.SizeOverflow;
            count = try add(count, compressed_count);
        }
        const framed_count = try chunks.byteCount(count);
        self.payload_bytes = try add(self.payload_bytes, count);
        if (self.payload_bytes > self.maximum_payload_bytes) return error.MetadataLimitExceeded;
        if (self.destination) |destination| {
            if (self.offset > destination.len) return error.OutputTooSmall;
            var chunk_writer: chunks = undefined;
            try chunk_writer.init(destination[self.offset..], name, count);
            for (parts) |part| try chunk_writer.writer.writeAll(part);
            if (uncompressed) |source| {
                if (counter.count == 0) try chunk_writer.writer.writeAll(
                    counter.writer.buffered(),
                ) else try compress(source, &chunk_writer.writer, self.mode, self.compression);
            }
            const written = try chunk_writer.finish();
            std.debug.assert(written == framed_count);
        }
        self.offset = try add(self.offset, framed_count);
    }
};

const compressor_bytes = EncodingStorage.minimum_bytes;
const srgb_chromaticities = [_]u32{ 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000 };

fn compress(
    source: []const u8,
    output: *std.Io.Writer,
    mode: EmissionMode,
    compression: zlib.Compression,
) Error!void {
    switch (mode) {
        .allocator => |allocator| {
            var storage = try EncodingStorage.initCapacity(allocator, 0);
            defer storage.deinit(allocator);
            try encoding_workspace.beginStream(storage, compression);
            try encoding_workspace.writeStream(storage, output, source);
            try encoding_workspace.finishStream(storage, output);
        },
        .workspace => |storage| {
            try encoding_workspace.beginStream(storage, compression);
            try encoding_workspace.writeStream(storage, output, source);
            try encoding_workspace.finishStream(storage, output);
        },
        .bound => unreachable,
    }
}

fn add(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.SizeOverflow;
}

fn requiresCompression(value: MetadataInput) bool {
    if (value.icc_profile != null) return true;
    for (value.texts) |text| if (text.compress) return true;
    return false;
}

test "PNG metadata writes retained streams once and replays drained streams" {
    // Independent final stored-block framing with zlib Adler-32/CRC-32 values. The complete
    // compressed streams are 63, 64 and 65 bytes, covering both sides of the counter boundary.
    const controls = .{
        .{
            .source = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            .chunk = &[_]u8{
                0x00, 0x00, 0x00, 0x42, 0x7a, 0x54, 0x58, 0x74,
                0x4b, 0x00, 0x00, 0x78, 0x01, 0x01, 0x34, 0x00,
                0xcb, 0xff, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x5e, 0x25,
                0x0d, 0x35, 0x8e, 0x4b, 0xaf, 0x88,
            },
            .reservations = 1,
        },
        .{
            .source = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            .chunk = &[_]u8{
                0x00, 0x00, 0x00, 0x43, 0x7a, 0x54, 0x58, 0x74,
                0x4b, 0x00, 0x00, 0x78, 0x01, 0x01, 0x35, 0x00,
                0xca, 0xff, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x6b,
                0x9b, 0x0d, 0x76, 0xeb, 0x72, 0x64, 0x13,
            },
            .reservations = 1,
        },
        .{
            .source = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            .chunk = &[_]u8{
                0x00, 0x00, 0x00, 0x44, 0x7a, 0x54, 0x58, 0x74,
                0x4b, 0x00, 0x00, 0x78, 0x01, 0x01, 0x36, 0x00,
                0xc9, 0xff, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
                0x79, 0x52, 0x0d, 0xb7, 0xda, 0x26, 0x3e, 0xbf,
            },
            .reservations = 2,
        },
    };
    var workspace = try EncodingStorage.initCapacity(std.testing.allocator, 0);
    defer workspace.deinit(std.testing.allocator);
    inline for (controls) |control| {
        const prepared = try prepare(
            MetadataInput{
                .texts = &.{
                    .{
                        .keyword = "K",
                        .encoding = .latin1,
                        .compress = true,
                        .data = control.source,
                    },
                },
            },
            2,
            8,
            .{},
        );
        var guarded: [96]u8 = @splat(0xa5);
        var scratch = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = control.reservations },
        );
        const used = try prepared.writeIntoWithScratch(
            scratch.allocator(),
            guarded[3..],
            .{ .level = 0 },
        );
        try std.testing.expectEqual(control.chunk.len, used);
        try std.testing.expectEqualSlices(u8, control.chunk, guarded[3..][0..used]);
        try std.testing.expectEqual(control.reservations, scratch.allocations);
        try std.testing.expectEqual(scratch.allocated_bytes, scratch.freed_bytes);
        for (guarded[0..3]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (guarded[3 + used ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        const bound = try prepared.capacityBound();
        try std.testing.expect(bound >= used);
        const output = try std.testing.allocator.alloc(u8, bound + 2);
        defer std.testing.allocator.free(output);
        @memset(output, 0xa5);
        const prepared_used = try prepared.writeInto(output[1..], workspace, .{ .level = 0 });
        try std.testing.expectEqualSlices(u8, control.chunk, output[1..][0..prepared_used]);
        try std.testing.expectEqual(0xa5, output[0]);
        for (output[1 + prepared_used ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "prepared compressed text bounds a stream ending at a complete slab" {
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 65535);
    defer allocator.free(source);
    for (source, 0..) |*byte, i| byte.* = @intCast(32 + i % 95);
    const prepared = try prepare(
        MetadataInput{
            .texts = &.{.{ .keyword = "K", .encoding = .latin1, .compress = true, .data = source }},
        },
        0,
        8,
        .{},
    );
    const capacity = try prepared.capacityBound();
    const buffer = try allocator.alloc(u8, capacity + 2);
    defer allocator.free(buffer);
    @memset(buffer, 0xa5);
    var workspace = try EncodingStorage.initCapacity(allocator, 0);
    defer workspace.deinit(allocator);
    const used = try prepared.writeInto(buffer[1..][0..capacity], workspace, .{ .level = 0 });
    try std.testing.expect(used <= capacity);
    try std.testing.expectEqual(@as(u8, 0xa5), buffer[0]);
    for (buffer[1 + used ..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    const chunk = buffer[1..][0..used];
    const payload_len = std.mem.readInt(u32, chunk[0..4], .big);
    try std.testing.expectEqualStrings("zTXt", chunk[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 'K', 0, 0 }, chunk[8..11]);
    const wire = chunk[11 .. 8 + payload_len];
    const restored = try allocator.alloc(u8, source.len);
    defer allocator.free(restored);
    const decoder = try zlib.DecoderWorkspace.create(allocator);
    defer decoder.destroy(allocator);
    const result = try zlib.decode(wire, restored, .{ .workspace = decoder }, .{});
    try std.testing.expectEqual(wire.len, result.consumed);
    try std.testing.expectEqual(source.len, result.produced);
    try std.testing.expectEqualSlices(u8, source, restored);

    const metadata_value: MetadataInput = .{
        .texts = &.{.{ .keyword = "K", .encoding = .latin1, .compress = true, .data = source }},
    };
    const pixels = [_]u8{ 1, 2, 3, 255 };
    const image = try ImageInput.rgba8(&pixels, 1, 1);
    const options: test_encoding.Options = .{
        .compression = .{ .level = 0 },
        .metadata = metadata_value,
    };
    const requirements = try test_encoding.requirements(image, options);
    var image_workspace = try EncodingStorage.initCapacity(
        allocator,
        requirements.workspace_extra_bytes,
    );
    defer image_workspace.deinit(allocator);
    const png_buffer = try allocator.alloc(u8, requirements.output_bytes);
    defer allocator.free(png_buffer);
    const png = try test_encoding.into(image, png_buffer, image_workspace, options);

    const frames = [_]AnimationInput.Frame{
        .{
            .width = 1,
            .height = 1,
            .samples = .{ .packed_bytes = .{ .bytes = &pixels } },
            .delay = .{ .numerator = 1, .denominator = 10 },
        },
    };
    const animation_image: AnimationInput = .{
        .width = 1,
        .height = 1,
        .color_type = .rgba,
        .bit_depth = 8,
        .frames = &frames,
    };
    const animation_options: apng.Options = .{
        .compression = .{ .level = 0 },
        .metadata = metadata_value,
    };
    const animation_requirements = try apng.requirements(animation_image, animation_options);
    var animation_workspace = try EncodingStorage.initCapacity(
        allocator,
        animation_requirements.workspace_extra_bytes,
    );
    defer animation_workspace.deinit(allocator);
    const animation_buffer = try allocator.alloc(u8, animation_requirements.output_bytes);
    defer allocator.free(animation_buffer);
    const animation_wire = try apng.into(
        animation_image,
        animation_buffer,
        animation_workspace,
        animation_options,
    );
    for ([_][]const u8{ png, animation_wire }) |image_wire| {
        const admitted = try SourceImage.open(image_wire, .{});
        var texts = admitted.metadata().texts(.{});
        const text = (try texts.next()).?;
        try std.testing.expectEqualSlices(u8, source, try text.expandInto(restored, decoder));
        try std.testing.expect((try texts.next()) == null);
    }
}

test "PNG text writing shares language syntax admission before serialization" {
    for ([_][]const u8{ "en--US", "en-a", "x", "en-abcdefghi", "en-US-Latn" }) |language| {
        for ([_]bool{ false, true }) |compress_text| {
            const source: MetadataInput = .{
                .texts = &.{
                    .{
                        .keyword = "K",
                        .data = "text",
                        .language = language,
                        .compress = compress_text,
                    },
                },
            };
            try std.testing.expectError(error.InvalidPngMetadata, prepare(source, 2, 8, .{}));
        }
    }
    for ([_][]const u8{ "", "en-US", "i-klingon", "x-private", "en-u-ca-gregory" }) |language| {
        const source: MetadataInput = .{
            .texts = &.{.{ .keyword = "K", .data = "text", .language = language }},
        };
        _ = try prepare(source, 2, 8, .{});
    }
}

test "PNG metadata encoding preserves typed color HDR density Exif profile and text" {
    const allocator = std.testing.allocator;
    const facts = encoding_fixtures;
    const latin_text: [40][36]u8 = @splat("independent compression of metadata ".*);
    const utf8_text: [40][16]u8 = @splat("圧縮 metadata ".*);
    const source: MetadataInput = .{
        .gamma = 45455,
        .chromaticities = srgb_chromaticities,
        .srgb_intent = 2,
        .cicp = .{ .primaries = 9, .transfer = 16, .matrix = 0, .full_range = false },
        .mastering_display = .{
            .primaries = .{ .{ 34000, 16000 }, .{ 13250, 34500 }, .{ 7500, 3000 } },
            .white_point = .{ 15635, 16450 },
            .maximum_luminance = 10000000,
            .minimum_luminance = 5,
        },
        .content_light = .{ .maximum_content = 10000000, .maximum_frame_average = 4000000 },
        .significant_bits = &.{ 8, 7, 6, 5 },
        .icc_profile = .{ .name = "sRGB profile", .bytes = facts.srgb_icc },
        .exif_payload = facts.exif_little,
        .physical = .{ .x = 3780, .y = 7560, .metres = true },
        .texts = &.{
            .{
                .keyword = "Title",
                .encoding = .latin1,
                .data = &[_]u8{ 0x50, 0x4e, 0x47, 0x20, 0xe9 },
            },
            .{
                .keyword = "Comment",
                .encoding = .latin1,
                .compress = true,
                .data = std.mem.sliceAsBytes(&latin_text),
            },
            .{ .keyword = "Title", .data = "図像", .language = "ja", .translated_keyword = "題名" },
            .{
                .keyword = "Description",
                .data = std.mem.sliceAsBytes(&utf8_text),
                .compress = true,
                .language = "ja-JP",
                .translated_keyword = "説明",
            },
        },
    };
    const encoded = try test_encoding.allocWithScratch(
        allocator,
        allocator,
        try ImageInput.rgba16(&.{ 0x0123, 0xabcd, 0xffff, 0x8080 }, 1, 1),
        .{
            .metadata = source,
            .compression = .{ .level = 6 },
            .interlace = .adam7,
            .filter = .adaptive,
        },
    );
    defer allocator.free(encoded);
    const admitted = try SourceImage.open(encoded, .{ .maximum_source_extent = 1 });
    const reader = admitted.metadata();
    const details = try reader.read(.{});
    try std.testing.expectEqual(source.gamma, details.gamma);
    try std.testing.expectEqual(source.chromaticities, details.chromaticities);
    try std.testing.expectEqual(source.srgb_intent, details.srgb_intent);
    try std.testing.expectEqual(source.cicp, details.cicp);
    try std.testing.expectEqual(source.mastering_display, details.mastering_display);
    try std.testing.expectEqual(source.content_light, details.content_light);
    try std.testing.expectEqual(source.physical, details.physical);
    try std.testing.expectEqualSlices(u8, source.significant_bits.?, details.significant_bits.?);
    try std.testing.expectEqualSlices(u8, facts.exif_little, details.exif_payload.?);
    const orientation = try (try exif.View.open(details.exif_payload.?, .{})).orientation();
    try std.testing.expectEqual(exif.Orientation.right_top, orientation);
    const workspace = try deflate.DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const expanded = try allocator.alloc(u8, 4096);
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings("sRGB profile", details.icc_profile.?.name);
    try std.testing.expectEqualSlices(
        u8,
        facts.srgb_icc,
        try details.icc_profile.?.expandInto(expanded, workspace),
    );
    var texts = reader.texts(.{});
    for (source.texts) |expected| {
        const text = (try texts.next()).?;
        try std.testing.expectEqualStrings(expected.keyword, text.keyword);
        try std.testing.expectEqual(expected.encoding == .utf8, text.utf8);
        try std.testing.expectEqual(expected.compress, text.compressed);
        try std.testing.expectEqualStrings(expected.language, text.language);
        try std.testing.expectEqualStrings(expected.translated_keyword, text.translated_keyword);
        try std.testing.expectEqualStrings(expected.data, try text.expandInto(expanded, workspace));
    }
    try std.testing.expect((try texts.next()) == null);
    var decoded = try owned_decode.rgbaAlloc(u16, allocator, encoded, .{});
    defer decoded.deinit(allocator);
    try std.testing.expectEqualSlices(u16, &.{ 0x0123, 0xabcd, 0xffff, 0x8080 }, decoded.texels);
}

test "PNG metadata encoding applies the shared integer boundary to every scalar field" {
    for (
        [_]struct {
            value: u32,
            failure: ?Error,
        }{
            .{ .value = 0x7fff_ffff, .failure = null },
            .{ .value = 0x8000_0000, .failure = error.InvalidPngMetadata },
        },
    ) |control| {
        for (
            [_]MetadataInput{
                .{ .gamma = control.value },
                .{ .chromaticities = .{ control.value, 0, 0, 0, 0, 0, 0, 0 } },
                .{
                    .cicp = .{ .primaries = 9, .transfer = 16, .matrix = 0, .full_range = true },
                    .mastering_display = .{
                        .primaries = @splat(.{ 0, 0 }),
                        .white_point = .{ 0, 0 },
                        .maximum_luminance = control.value,
                        .minimum_luminance = 0,
                    },
                },
                .{
                    .cicp = .{ .primaries = 9, .transfer = 16, .matrix = 0, .full_range = true },
                    .mastering_display = .{
                        .primaries = @splat(.{ 0, 0 }),
                        .white_point = .{ 0, 0 },
                        .maximum_luminance = 0,
                        .minimum_luminance = control.value,
                    },
                },
                .{
                    .content_light = .{
                        .maximum_content = control.value,
                        .maximum_frame_average = 0,
                    },
                },
                .{
                    .content_light = .{
                        .maximum_content = 0,
                        .maximum_frame_average = control.value,
                    },
                },
                .{ .physical = .{ .x = control.value, .y = 0, .metres = false } },
                .{ .physical = .{ .x = 0, .y = control.value, .metres = false } },
            },
        ) |value| {
            if (control.failure) |failure| try std.testing.expectError(
                failure,
                prepare(value, 6, 8, .{}),
            ) else _ = try prepare(value, 6, 8, .{});
        }
    }
}

test "PNG metadata encoding rejects invalid declarations before allocating" {
    const limits: Limits = .{};
    const invalid = [_]MetadataInput{
        .{ .gamma = 0 },
        .{ .gamma = 0x80000000 },
        .{ .srgb_intent = 4 },
        .{ .gamma = 100000, .srgb_intent = 0 },
        .{ .chromaticities = @splat(0), .srgb_intent = 0 },
        .{ .cicp = .{ .primaries = 1, .transfer = 1, .matrix = 1, .full_range = true } },
        .{
            .mastering_display = .{
                .primaries = @splat(.{ 0, 0 }),
                .white_point = .{ 0, 0 },
                .maximum_luminance = 0,
                .minimum_luminance = 0,
            },
        },
    };
    for (
        invalid,
    ) |value| try std.testing.expectError(error.InvalidPngMetadata, prepare(value, 6, 8, limits));
    for (
        [_][]const u8{ &.{ 8, 8, 8 }, &.{ 8, 8, 8, 0 }, &.{ 8, 8, 8, 9 } },
    ) |bits| try std.testing.expectError(
        error.InvalidPngMetadata,
        prepare(MetadataInput{ .significant_bits = bits }, 6, 8, limits),
    );
    for (
        [_]MetadataInput.Text{
            .{ .keyword = "", .data = "text" },
            .{ .keyword = " leading", .data = "text" },
            .{ .keyword = "two  spaces", .data = "text" },
            .{
                .keyword = "Comment",
                .data = &[_]u8{ 0x62, 0x61, 0x64, 0x00, 0x74, 0x65, 0x78, 0x74 },
            },
            .{ .keyword = "Comment", .data = &[_]u8{ 0x62, 0x61, 0x64, 0xff } },
            .{ .keyword = "Comment", .data = "text", .language = "en_US" },
            .{
                .keyword = "Comment",
                .data = "text",
                .translated_keyword = &[_]u8{ 0x62, 0x61, 0x64, 0xff },
            },
            .{ .keyword = "Comment", .data = "text", .encoding = .latin1, .language = "en" },
        },
    ) |text| try std.testing.expectError(
        error.InvalidPngMetadata,
        prepare(MetadataInput{ .texts = &.{text} }, 6, 8, limits),
    );
    try std.testing.expectError(
        error.InvalidIcc,
        prepare(
            MetadataInput{ .icc_profile = .{ .name = "ICC", .bytes = "invalid" } },
            6,
            8,
            limits,
        ),
    );
    try std.testing.expectError(
        error.InvalidPngMetadata,
        prepare(
            MetadataInput{ .icc_profile = .{ .name = "ICC", .bytes = encoding_fixtures.srgb_icc } },
            0,
            8,
            limits,
        ),
    );
    try std.testing.expectError(
        error.InvalidExif,
        prepare(MetadataInput{ .exif_payload = "invalid" }, 6, 8, limits),
    );
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        prepare(MetadataInput{ .gamma = 45455 }, 6, 8, .{ .maximum_records = 0 }),
    );
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        prepare(MetadataInput{ .gamma = 45455 }, 6, 8, .{ .maximum_metadata_bytes = 3 }),
    );
    try std.testing.expectError(
        error.WorkBudgetExceeded,
        prepare(MetadataInput{ .gamma = 45455 }, 6, 8, .{ .maximum_work_units = 15 }),
    );
    try std.testing.expectError(
        error.ScratchBudgetExceeded,
        prepare(
            MetadataInput{
                .texts = &.{.{ .keyword = "Comment", .data = "text", .compress = true }},
            },
            6,
            8,
            .{ .maximum_scratch_bytes = compressor_bytes - 1 },
        ),
    );
    const prepared = try prepare(MetadataInput{ .gamma = 45455 }, 6, 8, limits);
    var short: [15]u8 = @splat(0xa5);
    try std.testing.expectError(
        error.OutputTooSmall,
        prepared.writeIntoWithScratch(std.testing.failing_allocator, &short, .{ .level = 0 }),
    );
    for (short) |byte| try std.testing.expectEqual(0xa5, byte);
    // A tiny source is admitted, but stored compression expands its encoded metadata payload.
    const expanded_metadata = try prepare(
        MetadataInput{
            .texts = &.{.{ .keyword = "A", .data = "d", .encoding = .latin1, .compress = true }},
        },
        6,
        8,
        .{ .maximum_metadata_bytes = 4 },
    );
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        expanded_metadata.encodedSizeWithScratch(std.testing.allocator, .{ .level = 0 }),
    );
}

test "PNG Exif aggregate records precede an unadmitted directory body" {
    // IFD0 is empty and points to IFD1. IFD1 declares one omitted entry/body.
    const tiff = &[_]u8{
        0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x0e, 0x00, 0x00, 0x00, 0x01, 0x00,
    };
    const value: MetadataInput = .{ .exif_payload = tiff };
    // One PNG chunk plus IFD0 leaves only the IFD1 header, not its entry.
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        prepare(value, 6, 8, .{ .maximum_records = 3 }),
    );
    try std.testing.expectError(error.InvalidExif, prepare(value, 6, 8, .{ .maximum_records = 4 }));
    const valid: MetadataInput = .{
        .exif_payload = &[_]u8{
            0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        },
    };
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        prepare(valid, 6, 8, .{ .maximum_records = 1 }),
    );
    try std.testing.expectEqual(
        2,
        (try prepare(valid, 6, 8, .{ .maximum_records = 2 })).record_count,
    );
}

test "prepared metadata rejects invalid compression before allocation or writes" {
    const allocator = std.testing.allocator;
    const texts = [_]MetadataInput.Text{
        .{ .keyword = "Comment", .data = "text", .compress = true },
    };
    const values = [_]MetadataInput{ .{}, .{ .gamma = 45455 }, .{ .texts = &texts } };
    var workspace = try EncodingStorage.initCapacity(allocator, 16);
    defer workspace.deinit(allocator);
    var output: [512]u8 = undefined;
    for (values) |value| {
        const prepared = try prepare(value, 6, 8, .{});
        for ([_]u8{ 10, 255 }) |level| {
            const method: zlib.Compression = .{ .level = level };
            try std.testing.expectError(
                error.InvalidOptions,
                prepared.encodedSizeWithScratch(std.testing.failing_allocator, method),
            );
            @memset(&output, 0xa5);
            try std.testing.expectError(
                error.InvalidOptions,
                prepared.writeIntoWithScratch(std.testing.failing_allocator, &output, method),
            );
            try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
            @memset(workspace.allocation, 0x5a);
            try std.testing.expectError(
                error.InvalidOptions,
                prepared.writeInto(&output, workspace, method),
            );
            try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
            try std.testing.expect(std.mem.allEqual(u8, workspace.allocation, 0x5a));
        }
    }
}

test "zero metadata records emit no bytes and empty text still emits" {
    const empty = try prepare(MetadataInput{}, 6, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), empty.record_count);
    var output: [128]u8 = @splat(0xa5);
    const method: zlib.Compression = .{ .level = 6 };
    const length = try empty.encodedSizeWithScratch(std.testing.failing_allocator, method);
    try std.testing.expectEqual(@as(usize, 0), length);
    const written = try empty.writeIntoWithScratch(std.testing.failing_allocator, &output, method);
    try std.testing.expectEqual(@as(usize, 0), written);
    for (output) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    const with_text = try prepare(
        MetadataInput{ .texts = &.{.{ .keyword = "k", .data = "" }} },
        6,
        8,
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), with_text.record_count);
    const text_length = try with_text.encodedSizeWithScratch(std.testing.failing_allocator, method);
    try std.testing.expect(text_length > 0);
    const text_written = try with_text.writeIntoWithScratch(
        std.testing.failing_allocator,
        &output,
        method,
    );
    try std.testing.expectEqual(text_length, text_written);
}

test "empty metadata preparation preserves zero budgets and present empty records" {
    const limits: Limits = .{
        .maximum_records = 0,
        .maximum_metadata_bytes = 0,
        .maximum_work_units = 0,
        .maximum_scratch_bytes = 0,
    };
    const empty = try prepare(MetadataInput{}, 6, 8, limits);
    try std.testing.expectEqual(@as(usize, 0), empty.record_count);
    try std.testing.expectEqual(@as(usize, 0), empty.source_bytes);
    try std.testing.expectEqual(@as(usize, 0), empty.work_units);
    try std.testing.expectEqual(@as(usize, 0), empty.maximum_payload_bytes);
    try std.testing.expectError(
        error.InvalidPngMetadata,
        prepare(MetadataInput{ .gamma = 0 }, 6, 8, limits),
    );
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        prepare(MetadataInput{ .texts = &.{.{ .keyword = "k", .data = "" }} }, 6, 8, limits),
    );
}
