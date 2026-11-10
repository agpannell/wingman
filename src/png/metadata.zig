//! Borrowed PNG metadata declarations and explicit bounded payload expansion.

const SourceImage = @import("Source.zig");
const owned_decode = @import("image_decode.zig");
const exif_module = @import("../exif.zig");
const icc_module = @import("../icc.zig");
const std = @import("std");
const png_metadata_vectors = @import("testdata/metadata.zig");
const png = @import("../png.zig");
const deflate = @import("../deflate.zig");
const zlib = @import("../zlib.zig");

/// Checked selected metadata records. Absent records are null; optional payload slices borrow the
/// original source, which must remain live and unchanged while those slices are used.
pub const Metadata = struct {
    /// Raw image gamma multiplied by 100000; nonzero when present.
    gamma: ?u32 = null,
    /// Raw white, red, green, blue xy pairs, multiplied by 100000.
    chromaticities: ?[8]u32 = null,
    /// Standard RGB rendering intent, 0–3.
    srgb_intent: ?u8 = null,
    /// Coding-independent declarations, including full/narrow range.
    cicp: ?Cicp = null,
    /// Informative mastering-display metadata.
    mastering_display: ?MasteringDisplay = null,
    /// Informative content light levels.
    content_light: ?ContentLight = null,
    /// Borrowed significant-bit counts in stored channel order; indexed color uses RGB entries.
    significant_bits: ?[]const u8 = null,
    /// Borrowed compressed ICC profile; expansion/profile validation is explicit.
    icc_profile: ?CompressedProfile = null,
    /// Borrowed TIFF bytes, excluding the JPEG Exif signature; Exif selection is explicit.
    exif_payload: ?[]const u8 = null,
    /// Physical density/aspect declaration, without resizing pixels.
    physical: ?Physical = null,
    /// Animation control declaration; no frames have been decoded or composed.
    animation: ?AnimationInfo = null,

    /// Reports declared precedence cICP > iCCP > sRGB > cHRM/gAMA. A consumer that cannot interpret
    /// a declaration chooses its own supported fallback.
    pub fn colorSource(self: Metadata) ColorSource {
        if (self.cicp != null) return .cicp;
        if (self.icc_profile != null) return .icc;
        if (self.srgb_intent != null) return .srgb;
        if (self.gamma != null or self.chromaticities != null) return .gamma_chromaticities;
        return .unspecified;
    }

    /// Selected metadata, bounded expansion and compressed-stream failures.
    pub const Error = deflate.Error || error{
        InvalidPngMetadata,
        UnsupportedPngMetadata,
        MetadataLimitExceeded,
    };

    /// Copied ancillary presence flags, without claiming that the advertised payload is valid.
    pub const Presence = struct {
        /// Embedded compressed ICC profile.
        icc_profile: bool = false,
        /// Standard RGB rendering-intent declaration.
        srgb_intent: bool = false,
        /// Image gamma declaration.
        gamma: bool = false,
        /// Primary/white-point chromaticity declaration.
        chromaticities: bool = false,
        /// Coding-independent color/transfer declaration.
        cicp: bool = false,
        /// Mastering-display color volume.
        mastering_display: bool = false,
        /// Content/frame-average light levels.
        content_light: bool = false,
        /// Original significant channel bits.
        significant_bits: bool = false,
        /// Exif TIFF payload.
        exif_payload: bool = false,
        /// Physical pixel size or aspect.
        physical: bool = false,
        /// Any text record, whether compressed or uncompressed.
        text: bool = false,
        /// APNG animation control; static decoding still selects the default IDAT image.
        animation: bool = false,
    };

    /// Independent metadata traversal/borrow limits; expanded bytes are bounded by destinations.
    pub const Limits = struct {
        /// Maximum visited PNG chunks, including image-data chunks; defaults to 4096.
        maximum_records: usize = 4096,
        /// Maximum combined payload bytes of selected metadata records; defaults to 16 MiB.
        maximum_bytes: usize = 16 * 1024 * 1024,
    };

    /// Raw cICP declarations; unknown primary/transfer codes stay visible without interpretation.
    pub const Cicp = struct {
        /// ITU-T H.273 primary chromaticity code point.
        primaries: u8,
        /// ITU-T H.273 transfer-function code point.
        transfer: u8,
        /// PNG requires the RGB identity matrix code point zero.
        matrix: u8,
        /// True selects full range; false declares narrow range, without rescaling samples.
        full_range: bool,
    };

    /// Raw mastering-display values; chromaticities use 1/50000 and luminance 1/10000 cd/m².
    pub const MasteringDisplay = struct {
        /// Three xy pairs in encoded order: largest x, largest y, remaining primary (RGB normally).
        primaries: [3][2]u16,
        /// Mastering-display white xy pair.
        white_point: [2]u16,
        /// Encoded maximum luminance; zero may declare an unknown/default value.
        maximum_luminance: u32,
        /// Encoded minimum luminance.
        minimum_luminance: u32,
    };

    /// Raw content-light values in 1/10000 cd/m²; zero means unknown/not calculable.
    pub const ContentLight = struct {
        /// Maximum content light level across the complete image/animation.
        maximum_content: u32,
        /// Maximum frame-average light level across the complete image/animation.
        maximum_frame_average: u32,
    };

    /// Pixel density or aspect declaration; zero values are retained without deriving a ratio.
    pub const Physical = struct {
        /// Pixels per declared unit along X.
        x: u32,
        /// Pixels per declared unit along Y.
        y: u32,
        /// False means aspect ratio only; true means the unit is a metre.
        metres: bool,
    };

    /// APNG control declaration; frame structure and entropy validity need animation admission.
    pub const AnimationInfo = struct {
        /// Number of frames in the animation, excluding an outside default image.
        frame_count: u32,
        /// Number of complete plays; zero means indefinite looping.
        play_count: u32,
    };

    /// Highest-precedence advertised color declaration. `Metadata.colorSource` selects it without
    /// applying a transform; the consumer interprets support and chooses any needed fallback.
    pub const ColorSource = enum { unspecified, gamma_chromaticities, srgb, icc, cicp };

    /// Borrowed metadata reader produced by `Source.metadata()` after mandatory admission.
    pub const Reader = struct {
        /// Complete admitted PNG source, retained unchanged through every payload borrow.
        source: []const u8,
        /// Admitted IHDR bit depth used to validate significant-bit records.
        bit_depth: u8,
        /// Admitted IHDR color type used to validate significant-bit channel counts.
        color_type: u8,

        /// Checks supported ancillary records without allocating pixels or expanding compressed
        /// data. Color/HDR records precede PLTE/IDAT; pHYs/Exif/acTL may follow PLTE but precede
        /// IDAT. Duplicate singleton records and malformed text framing fail only this selected
        /// operation. iCCP and sRGB may coexist: the specification recommends against it but does
        /// not forbid it. Uncompressed iTXt ignores its unused compression-method byte.
        pub fn read(self: Reader, limits: Limits) Error!Metadata {
            var iterator = ChunkIterator{ .source = self.source, .limits = limits };
            var result: Metadata = .{};
            var seen: std.EnumSet(Singleton) = .empty;
            var palette_seen = false;
            var image_seen = false;
            while (try iterator.next()) |chunk| {
                if (std.mem.eql(u8, &chunk.name, "PLTE")) palette_seen = true;
                if (std.mem.eql(u8, &chunk.name, "IDAT")) image_seen = true;
                if (isText(&chunk.name)) {
                    try iterator.selectBytes(chunk.data.len);
                    _ = try parseText(chunk);
                    continue;
                }

                const kind = singletonKind(&chunk.name) orelse continue;
                // Density, Exif and animation control may follow a palette; the other singleton
                // declarations must precede it. All must precede image data.
                const allowed_after_palette = kind == .physical or kind == .exif or kind ==
                    .animation;
                const repeated = seen.contains(kind);
                if (repeated or image_seen or (palette_seen and !allowed_after_palette))
                    return error.InvalidPngMetadata;

                seen.insert(kind);
                try iterator.selectBytes(chunk.data.len);
                const data = chunk.data;
                switch (kind) {
                    .gamma => {
                        if (data.len != 4) return error.InvalidPngMetadata;
                        const value = try readPngInteger(data, 0);
                        if (value == 0) return error.InvalidPngMetadata;
                        result.gamma = value;
                    },
                    .chromaticities => {
                        if (data.len != 32) return error.InvalidPngMetadata;
                        var values: [8]u32 = undefined;
                        for (
                            &values,
                            0..,
                        ) |*value, index| value.* = try readPngInteger(data, index * 4);
                        result.chromaticities = values;
                    },
                    .srgb => {
                        if (data.len != 1 or data[0] > 3) return error.InvalidPngMetadata;
                        result.srgb_intent = data[0];
                    },
                    .cicp => {
                        if (data.len != 4 or data[2] != 0 or data[3] > 1)
                            return error.InvalidPngMetadata;
                        result.cicp = .{
                            .primaries = data[0],
                            .transfer = data[1],
                            .matrix = data[2],
                            .full_range = data[3] == 1,
                        };
                    },
                    .mastering_display => {
                        if (data.len != 24) return error.InvalidPngMetadata;
                        var display: MasteringDisplay = .{
                            .primaries = undefined,
                            .white_point = .{ readU16(data, 12), readU16(data, 14) },
                            .maximum_luminance = try readPngInteger(data, 16),
                            .minimum_luminance = try readPngInteger(data, 20),
                        };
                        for (
                            &display.primaries,
                            0..,
                        ) |*pair, index| pair.* = .{
                            readU16(data, index * 4),
                            readU16(data, index * 4 + 2),
                        };
                        result.mastering_display = display;
                    },
                    .content_light => {
                        if (data.len != 8) return error.InvalidPngMetadata;
                        result.content_light = .{
                            .maximum_content = try readPngInteger(data, 0),
                            .maximum_frame_average = try readPngInteger(data, 4),
                        };
                    },
                    .significant_bits => {
                        try validateSignificantBits(data, self.color_type, self.bit_depth);
                        result.significant_bits = data;
                    },
                    .icc => {
                        const zero = std.mem.indexOfScalar(
                            u8,
                            data,
                            0,
                        ) orelse return error.InvalidPngMetadata;
                        try validateKeyword(data[0..zero]);
                        if (data.len - zero < 3) return error.InvalidPngMetadata;
                        if (data[zero + 1] != 0) return error.UnsupportedPngMetadata;
                        result.icc_profile = .{ .name = data[0..zero], .data = data[zero + 2 ..] };
                    },
                    .exif => result.exif_payload = data,
                    .physical => {
                        if (data.len != 9 or data[8] > 1) return error.InvalidPngMetadata;
                        result.physical = .{
                            .x = try readPngInteger(data, 0),
                            .y = try readPngInteger(data, 4),
                            .metres = data[8] == 1,
                        };
                    },
                    .animation => {
                        if (data.len != 8) return error.InvalidPngMetadata;
                        const frames = try readPngInteger(data, 0);
                        if (frames == 0) return error.InvalidPngMetadata;
                        result.animation = .{
                            .frame_count = frames,
                            .play_count = try readPngInteger(data, 4),
                        };
                    },
                }
            }
            if (result.mastering_display != null and result.cicp == null)
                return error.InvalidPngMetadata;
            return result;
        }

        /// Starts an independent traversal with its own chunk and selected-payload budgets.
        /// Returned text borrows the source. Duplicate keywords are retained because PNG permits
        /// them.
        pub fn texts(self: Reader, limits: Limits) TextIterator {
            return .{ .chunks = .{ .source = self.source, .limits = limits } };
        }

        /// Text iterator; it retains a source borrow, no allocator or expanded storage.
        pub const TextIterator = struct {
            /// Private bounded chunk traversal, initialized by `Reader.texts`.
            chunks: ChunkIterator,

            /// Selects the next text record, or null at the end; malformed selected records fail
            /// here. Selected-byte refusals repeat without traversal. A fresh `Reader.texts`
            /// iterator selects another budget; previously returned text views keep their original
            /// source lifetime.
            pub fn next(self: *TextIterator) Error!?Text {
                while (try self.chunks.next()) |chunk| {
                    if (!isText(&chunk.name)) continue;
                    try self.chunks.selectBytes(chunk.data.len);
                    return try parseText(chunk);
                }
                return null;
            }

            test next {
                const allocator = std.testing.allocator;
                const bytes = try png.encode.alloc(
                    allocator,
                    try png.ImageInput.rgba8(&.{ 0, 0, 0, 255 }, 1, 1),
                    .{
                        .metadata = .{
                            .texts = &.{.{ .keyword = "Description", .data = "snowman ☃" }},
                        },
                    },
                );
                defer allocator.free(bytes);
                const image = try png.Source.open(bytes, .{});
                var text_records = image.metadata().texts(.{});
                const text = (try text_records.next()).?;
                try std.testing.expectEqualStrings("Description", text.keyword);
                try std.testing.expectEqualStrings("snowman ☃", text.data);
                try std.testing.expect(text.utf8);
                try std.testing.expectEqual(null, try text_records.next());
            }
        };
    };

    /// Borrowed iCCP name and zlib stream; the profile is not expanded or validated implicitly.
    pub const CompressedProfile = struct {
        /// Checked Latin-1 PNG keyword identifying the profile.
        name: []const u8,
        /// Borrowed complete zlib stream; keep its source live and unchanged through expansion.
        data: []const u8,

        /// Expands into bounded disjoint storage with caller-reserved DEFLATE workspace. Requires
        /// exactly one complete stream; a successful slice borrows `destination`. An error may
        /// leave bytes in the destination modified.
        pub fn expandInto(
            self: CompressedProfile,
            destination: []u8,
            workspace: *deflate.DecoderWorkspace,
        ) Error![]u8 {
            return expandZlib(self.data, destination, workspace);
        }
    };

    /// One checked text record; compressed payload validation waits for explicit expansion.
    pub const Text = struct {
        /// Checked Latin-1 PNG keyword, 1–79 bytes.
        keyword: []const u8,
        /// True selects UTF-8 iTXt; false selects Latin-1 tEXt/zTXt.
        utf8: bool,
        /// Whether `data` is zlib-compressed rather than already decoded text.
        compressed: bool,
        /// Borrowed iTXt language tag; empty for Latin-1 records or unspecified language.
        language: []const u8,
        /// Borrowed checked UTF-8 translated keyword; empty for Latin-1 records.
        translated_keyword: []const u8,
        /// Borrowed text bytes or complete zlib stream; no terminating NUL belongs to the text.
        data: []const u8,

        /// Copies or expands into bounded disjoint storage, then checks NUL/UTF-8 rules. The
        /// successful slice borrows `destination`; failure may change its contents.
        pub fn expandInto(
            self: Text,
            destination: []u8,
            workspace: *deflate.DecoderWorkspace,
        ) Error![]u8 {
            const result = if (self.compressed) try expandZlib(
                self.data,
                destination,
                workspace,
            ) else blk: {
                if (destination.len < self.data.len) return error.OutputTooSmall;
                @memcpy(destination[0..self.data.len], self.data);
                break :blk destination[0..self.data.len];
            };
            try validateText(result, self.utf8);
            return result;
        }
    };

    /// Caller-selected ancillary records; all borrowed input stays live through encoding.
    pub const Input = struct {
        /// Encoded image gamma multiplied by 100000, nonzero and at most 2^31-1.
        gamma: ?u32 = null,
        /// White/red/green/blue xy pairs multiplied by 100000, retained without a color transform.
        chromaticities: ?[8]u32 = null,
        /// Standard RGB rendering intent 0–3; any accompanying gamma/chromaticities must match
        /// sRGB.
        srgb_intent: ?u8 = null,
        /// Raw cICP codes; PNG requires matrix zero, without rescaling narrow-range samples.
        cicp: ?Cicp = null,
        /// Raw mastering values; a cICP declaration is required when this record is selected.
        mastering_display: ?MasteringDisplay = null,
        /// Raw content/frame-average light levels.
        content_light: ?ContentLight = null,
        /// Per-channel high significant-bit counts; indexed color declares three palette channels.
        significant_bits: ?[]const u8 = null,
        /// Uncompressed ICC bytes; bounded storage and image/profile channel agreement are checked.
        icc_profile: ?Input.IccProfile = null,
        /// Borrowed classic TIFF bytes without a JPEG Exif signature; main directories are checked.
        exif_payload: ?[]const u8 = null,
        /// Physical pixel density/aspect without changing the image extent.
        physical: ?Physical = null,
        /// Ordered text records, emitted before image data; all borrowed bytes stay unchanged.
        texts: []const Input.Text = &.{},

        /// One immutable Latin-1 or UTF-8 text record; identical keywords may occur more than once.
        pub const Text = struct {
            /// PNG Latin-1 keyword, 1–79 printable bytes with checked spacing.
            keyword: []const u8,
            /// Borrowed uncompressed text without NUL bytes; UTF-8 must be valid when selected.
            data: []const u8,
            /// UTF-8 emits iTXt; Latin-1 emits tEXt or zTXt.
            encoding: enum { utf8, latin1 } = .utf8,
            /// Compress this record using the caller-selected shared method; defaults to
            /// uncompressed.
            compress: bool = false,
            /// RFC 5646 language-tag syntax for UTF-8 only; empty means unspecified. Case stays
            /// verbatim; registry membership and semantic validity remain caller concerns.
            language: []const u8 = "",
            /// UTF-8 translated keyword for UTF-8 records only; empty means unspecified.
            translated_keyword: []const u8 = "",
        };

        /// Borrowed uncompressed ICC v2/v4 profile and PNG keyword; writing compresses its exact
        /// bytes.
        pub const IccProfile = struct {
            /// Checked PNG Latin-1 profile name.
            name: []const u8,
            /// Borrowed RGB/GRAY profile bytes; `icc.Profile.open` checks storage, not full ICC
            /// validity.
            bytes: []const u8,
        };
    };
};

/// Records a checked chunk name while mandatory PNG admission visits its framing.
pub fn observeChunk(self: *Metadata.Presence, name: []const u8) void {
    if (isText(name)) {
        self.text = true;
        return;
    }
    switch (singletonKind(name) orelse return) {
        .gamma => self.gamma = true,
        .chromaticities => self.chromaticities = true,
        .srgb => self.srgb_intent = true,
        .cicp => self.cicp = true,
        .mastering_display => self.mastering_display = true,
        .content_light => self.content_light = true,
        .significant_bits => self.significant_bits = true,
        .icc => self.icc_profile = true,
        .exif => self.exif_payload = true,
        .physical => self.physical = true,
        .animation => self.animation = true,
    }
}

test {
    _ = Metadata.Reader.TextIterator;
}

const Singleton = enum {
    gamma,
    chromaticities,
    srgb,
    cicp,
    mastering_display,
    content_light,
    significant_bits,
    icc,
    exif,
    physical,
    animation,
};

const Chunk = struct { name: [4]u8, data: []const u8 };
const ChunkIterator = struct {
    source: []const u8,
    limits: Metadata.Limits,
    offset: usize = 8,
    records: usize = 0,
    selected_bytes: usize = 0,
    byte_limit_exceeded: bool = false,

    fn next(self: *ChunkIterator) Metadata.Error!?Chunk {
        if (self.byte_limit_exceeded) return error.MetadataLimitExceeded;
        if (self.offset == self.source.len) return null;
        if (self.offset > self.source.len or self.source.len - self.offset < 12)
            return error.InvalidPngMetadata;
        if (self.records == self.limits.maximum_records) return error.MetadataLimitExceeded;
        const length = readU32(self.source, self.offset);
        if (length > 0x7fff_ffff or length > self.source.len - self.offset - 12)
            return error.InvalidPngMetadata;
        const result: Chunk = .{
            .name = self.source[self.offset + 4 ..][0..4].*,
            .data = self.source[self.offset + 8 ..][0..length],
        };
        self.offset += 12 + @as(usize, length);
        self.records += 1;
        return result;
    }

    fn selectBytes(self: *ChunkIterator, count: usize) Metadata.Error!void {
        if (count > self.limits.maximum_bytes - self.selected_bytes) {
            self.byte_limit_exceeded = true;
            return error.MetadataLimitExceeded;
        }
        self.selected_bytes += count;
    }
};

fn singletonKind(name: []const u8) ?Singleton {
    const records = [_]struct {
        name: *const [4]u8,
        kind: Singleton,
    }{
        .{ .name = "gAMA", .kind = .gamma },
        .{ .name = "cHRM", .kind = .chromaticities },
        .{ .name = "sRGB", .kind = .srgb },
        .{ .name = "cICP", .kind = .cicp },
        .{ .name = "mDCV", .kind = .mastering_display },
        .{ .name = "cLLI", .kind = .content_light },
        .{ .name = "sBIT", .kind = .significant_bits },
        .{ .name = "iCCP", .kind = .icc },
        .{ .name = "eXIf", .kind = .exif },
        .{ .name = "pHYs", .kind = .physical },
        .{ .name = "acTL", .kind = .animation },
    };
    inline for (records) |record| if (std.mem.eql(u8, name, record.name)) return record.kind;
    return null;
}

fn isText(name: []const u8) bool {
    if (std.mem.eql(u8, name, "tEXt")) return true;
    if (std.mem.eql(u8, name, "zTXt")) return true;
    return std.mem.eql(u8, name, "iTXt");
}

fn parseText(chunk: Chunk) Metadata.Error!Metadata.Text {
    const zero = std.mem.indexOfScalar(u8, chunk.data, 0) orelse return error.InvalidPngMetadata;
    const keyword = chunk.data[0..zero];
    try validateKeyword(keyword);
    var remaining = chunk.data[zero + 1 ..];
    var result: Metadata.Text = .{
        .keyword = keyword,
        .utf8 = std.mem.eql(u8, &chunk.name, "iTXt"),
        .compressed = std.mem.eql(u8, &chunk.name, "zTXt"),
        .language = "",
        .translated_keyword = "",
        .data = undefined,
    };
    if (result.utf8) {
        if (remaining.len < 2 or remaining[0] > 1) return error.InvalidPngMetadata;
        result.compressed = remaining[0] == 1;
        // PNG 11.3.3.4 requires decoders to ignore the method for uncompressed text.
        if (result.compressed and remaining[1] != 0) return error.UnsupportedPngMetadata;
        remaining = remaining[2..];
        const language_end = std.mem.indexOfScalar(
            u8,
            remaining,
            0,
        ) orelse return error.InvalidPngMetadata;
        result.language = remaining[0..language_end];
        try validateLanguage(result.language);
        remaining = remaining[language_end + 1 ..];
        const translation_end = std.mem.indexOfScalar(
            u8,
            remaining,
            0,
        ) orelse return error.InvalidPngMetadata;
        result.translated_keyword = remaining[0..translation_end];
        if (!std.unicode.utf8ValidateSlice(
            result.translated_keyword,
        )) return error.InvalidPngMetadata;
        remaining = remaining[translation_end + 1 ..];
    } else if (result.compressed) {
        if (remaining.len == 0) return error.InvalidPngMetadata;
        if (remaining[0] != 0) return error.UnsupportedPngMetadata;
        remaining = remaining[1..];
    }
    result.data = remaining;
    if (!result.compressed) try validateText(result.data, result.utf8);
    return result;
}

/// Checks PNG's four-byte unsigned integer range, 0 through 2^31-1, without allocation. HDR
/// luminance uses this same representation. Individual fields may impose stricter constraints, such
/// as nonzero gamma; those remain with their readers and writers.
pub fn validateInteger(value: u32) Metadata.Error!void {
    if (value > 0x7fff_ffff) return error.InvalidPngMetadata;
}

/// Checks sBIT's channel count and significant depths without allocation or sample scaling.
/// Color/depth describe an admitted PNG layout. Indexed images declare three eight-bit palette
/// channels, independent of their index depth. Shared by readers and typed writers.
pub fn validateSignificantBits(
    values: []const u8,
    color_type: u8,
    bit_depth: u8,
) Metadata.Error!void {
    const count: usize = switch (color_type) {
        0 => 1,
        2, 3 => 3,
        4 => 2,
        6 => 4,
        else => return error.InvalidPngMetadata,
    };
    if (values.len != count) return error.InvalidPngMetadata;
    const maximum = if (color_type == 3) 8 else bit_depth;
    for (values) |value| if (value == 0 or value > maximum) return error.InvalidPngMetadata;
}

/// Checks PNG's 1–79-byte printable Latin-1 keyword and space restrictions. Shared by borrowed
/// readers and typed writers; no allocation or normalization occurs.
pub fn validateKeyword(keyword: []const u8) Metadata.Error!void {
    if (keyword.len == 0 or keyword.len > 79 or keyword[0] == ' ' or keyword[keyword.len - 1] ==
        ' ') return error.InvalidPngMetadata;
    var space = false;
    for (keyword) |character| {
        if ((character < 32 or (character > 126 and character < 161)) or (space and character ==
            ' ')) return error.InvalidPngMetadata;
        space = character == ' ';
    }
}

/// Checks text for NUL and, when selected, valid UTF-8 without altering source bytes.
pub fn validateText(text: []const u8, utf8: bool) Metadata.Error!void {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidPngMetadata;
    if (utf8 and !std.unicode.utf8ValidateSlice(text)) return error.InvalidPngMetadata;
}

/// Checks RFC 5646 language-tag syntax shared by PNG readers and writers without allocation. Empty
/// denotes unspecified. Case, grandfathered tags, extensions and private use remain verbatim;
/// registry membership, duplicate-subtag validity and canonicalization are not checked.
/// https://www.rfc-editor.org/rfc/rfc5646.html#section-2.1
pub fn validateLanguage(language: []const u8) Metadata.Error!void {
    if (language.len == 0) return;
    // These fixed irregular productions do not match the ordinary language-tag grammar.
    for (
        [_][]const u8{
            "en-GB-oed", "i-ami",     "i-bnn",     "i-default", "i-enochian", "i-hak", "i-klingon",
            "i-lux",     "i-mingo",   "i-navajo",  "i-pwn",     "i-tao",      "i-tay", "i-tsu",
            "sgn-BE-FR", "sgn-BE-NL", "sgn-CH-DE",
        },
    ) |grandfathered| if (std.ascii.eqlIgnoreCase(language, grandfathered)) return;

    var subtags = std.mem.splitScalar(u8, language, '-');
    const primary = (try nextLanguageSubtag(&subtags)) orelse return error.InvalidPngMetadata;
    if (primary.len == 1 and std.ascii.toLower(primary[0]) == 'x') {
        if (try nextLanguageSubtag(&subtags) == null) return error.InvalidPngMetadata;
        while (try nextLanguageSubtag(&subtags)) |_| {}
        return;
    }
    if (primary.len < 2 or !languageAlphabetic(primary)) return error.InvalidPngMetadata;

    // An optional extended language is followed by script, region and variants in that order.
    var next = try nextLanguageSubtag(&subtags);
    if (primary.len <= 3) {
        for (0..3) |_| {
            const extended = next orelse break;
            if (extended.len != 3 or !languageAlphabetic(extended)) break;
            next = try nextLanguageSubtag(&subtags);
        }
    }
    if (next) |script| {
        if (script.len == 4 and languageAlphabetic(script)) next = try nextLanguageSubtag(&subtags);
    }
    if (next) |region| {
        const alphabetic_region = region.len == 2 and languageAlphabetic(region);
        const numeric_region = region.len == 3 and languageNumeric(region);
        if (alphabetic_region or numeric_region) next = try nextLanguageSubtag(&subtags);
    }
    while (next) |variant| {
        if (variant.len < 5 and !(variant.len == 4 and std.ascii.isDigit(variant[0]))) break;
        next = try nextLanguageSubtag(&subtags);
    }
    // Each extension starts with a singleton and has at least one longer subtag.
    while (next) |extension| {
        if (extension.len != 1 or std.ascii.toLower(extension[0]) == 'x') break;
        const first = (try nextLanguageSubtag(&subtags)) orelse return error.InvalidPngMetadata;
        if (first.len < 2) return error.InvalidPngMetadata;
        next = try nextLanguageSubtag(&subtags);
        while (next) |extended| {
            if (extended.len == 1) break;
            next = try nextLanguageSubtag(&subtags);
        }
    }
    if (next) |private| {
        if (private.len != 1 or std.ascii.toLower(
            private[0],
        ) != 'x') return error.InvalidPngMetadata;
        if (try nextLanguageSubtag(&subtags) == null) return error.InvalidPngMetadata;
        while (try nextLanguageSubtag(&subtags)) |_| {}
    }
}

fn nextLanguageSubtag(subtags: *std.mem.SplitIterator(u8, .scalar)) Metadata.Error!?[]const u8 {
    const subtag = subtags.next() orelse return null;
    if (subtag.len == 0 or subtag.len > 8) return error.InvalidPngMetadata;
    for (
        subtag,
    ) |character| if (!std.ascii.isAlphanumeric(character)) return error.InvalidPngMetadata;
    return subtag;
}

fn languageAlphabetic(subtag: []const u8) bool {
    for (subtag) |character| if (!std.ascii.isAlphabetic(character)) return false;
    return true;
}

fn languageNumeric(subtag: []const u8) bool {
    for (subtag) |character| if (!std.ascii.isDigit(character)) return false;
    return true;
}

test "PNG language tags admit RFC syntax and reject malformed subtag sequences" {
    // RFC 5646 section 2.1 syntax, including all irregular grandfathered productions. Registry
    // membership and duplicate-subtag validity are separate from well-formedness.
    for (
        [_][]const u8{
            "",                              "en",         "ja-JP",               "zh-Hant-TW",
            "es-419",                        "de-CH-1901", "sl-rozaj-biske-1994", "zh-cmn-Hans-CN",
            "abc-def-ghi-jkl-Latn-US-abcde", "abcd",
        },
    ) |language| try validateLanguage(language);
    for (
        [_][]const u8{
            "qaa-Qaaa-QM-x-southern", "en-a-aaa-b-bbb-x-ccc", "en-u-ca-gregory", "x-private",
            "X-A-12345678",           "de-DE-1901-1901",      "en-a-aaa-A-bbb",  "en-GB-oed",
            "i-ami",                  "i-bnn",                "i-default",       "i-enochian",
            "i-hak",                  "i-klingon",            "i-lux",           "i-mingo",
            "i-navajo",               "i-pwn",                "i-tao",           "i-tay",
            "i-tsu",                  "sgn-BE-FR",            "sgn-BE-NL",       "sgn-CH-DE",
            "I-KLINGON",              "SGN-be-fr",            "art-lojban",      "cel-gaulish",
            "no-bok",                 "no-nyn",               "zh-guoyu",        "zh-hakka",
            "zh-min",                 "zh-min-nan",           "zh-xiang",
        },
    ) |language| try validateLanguage(language);
    const embedded_nul = [_]u8{ 0x65, 0x6e, 0x00, 0x55, 0x53 };
    const non_ascii = [_]u8{ 0xc3, 0xa9, 0x6e };
    const invalid_languages = [_][]const u8{
        "-en",
        "en-",
        "en--US",
        "en_US",
        "en US",
        &embedded_nul,
        &non_ascii,
        "e",
        "1a",
        "abcdefghi",
        "en-abcdefghi",
        "en-abc-def-ghi-jkl",
        "en-US-Latn",
        "en-US-US",
        "en-a",
        "en-a-a",
        "en-a-x-private",
        "en-x",
        "x",
        "x-",
        "x--a",
        "i-unknown",
        "i-klingon-x-private",
        "en-GB-oed-x-private",
        "en-1234-ab",
    };
    for (
        invalid_languages,
    ) |language| try std.testing.expectError(error.InvalidPngMetadata, validateLanguage(language));
    const long_private = "x" ++ @as(
        [9 * 4096]u8,
        @bitCast(@as([4096][9]u8, @splat("-a1234567".*))),
    );
    try validateLanguage(long_private);
}

test "PNG iTXt rejects malformed language syntax for plain and compressed records" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "en--US", "en-a", "x", "en-abcdefghi", "en-US-Latn" }) |language| {
        for (
            [_][]const u8{ &[_]u8{ 0x4b, 0x00, 0x00, 0x00 }, &[_]u8{ 0x4b, 0x00, 0x01, 0x00 } },
        ) |prefix| {
            const payload = try std.mem.concat(
                allocator,
                u8,
                &.{ prefix, language, &[_]u8{ 0x00, 0x00, 0x74, 0x65, 0x78, 0x74 } },
            );
            defer allocator.free(payload);
            try std.testing.expectError(
                error.InvalidPngMetadata,
                parseText(.{ .name = "iTXt".*, .data = payload }),
            );
        }
    }
}

fn expandZlib(
    source: []const u8,
    destination: []u8,
    workspace: *deflate.DecoderWorkspace,
) Metadata.Error![]u8 {
    const decoded = zlib.decode(
        source,
        destination,
        .{ .workspace = workspace },
        .{},
    ) catch |err| return switch (err) {
        error.OutputTooSmall => error.OutputTooSmall,
        error.StorageOverlap => error.StorageOverlap,
        // Metadata never supplies a preset dictionary or a resumable owner. Framing/dictionary
        // failures therefore remain the metadata expansion's ordinary invalid-stream diagnostic.
        else => error.InvalidStream,
    };
    if (decoded.consumed != source.len) return error.InvalidStream;
    return destination[0..decoded.produced];
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

fn readPngInteger(bytes: []const u8, offset: usize) Metadata.Error!u32 {
    const value = readU32(bytes, offset);
    try validateInteger(value);
    return value;
}

test "PNG metadata integers retain the standard 31-bit range at both boundaries" {
    // Independent network-order facts from PNG's integer representation, section 7.1.
    for (
        [_]struct {
            value: u32,
            wire: *const [4]u8,
        }{
            .{ .value = 0, .wire = &[_]u8{ 0x00, 0x00, 0x00, 0x00 } },
            .{ .value = 1, .wire = &[_]u8{ 0x00, 0x00, 0x00, 0x01 } },
            .{ .value = 0x7fff_fffe, .wire = &[_]u8{ 0x7f, 0xff, 0xff, 0xfe } },
            .{ .value = 0x7fff_ffff, .wire = &[_]u8{ 0x7f, 0xff, 0xff, 0xff } },
        },
    ) |control| {
        try validateInteger(control.value);
        try std.testing.expectEqual(control.value, try readPngInteger(control.wire, 0));
    }
    for (
        [_]struct {
            value: u32,
            wire: *const [4]u8,
        }{
            .{ .value = 0x8000_0000, .wire = &[_]u8{ 0x80, 0x00, 0x00, 0x00 } },
            .{ .value = 0x8000_0001, .wire = &[_]u8{ 0x80, 0x00, 0x00, 0x01 } },
            .{ .value = 0xffff_fffe, .wire = &[_]u8{ 0xff, 0xff, 0xff, 0xfe } },
            .{ .value = 0xffff_ffff, .wire = &[_]u8{ 0xff, 0xff, 0xff, 0xff } },
        },
    ) |control| {
        try std.testing.expectError(error.InvalidPngMetadata, validateInteger(control.value));
        try std.testing.expectError(error.InvalidPngMetadata, readPngInteger(control.wire, 0));
    }
}

test "PNG color HDR aspect and significant-bit declarations match frozen wire facts" {
    const bytes = try std.testing.allocator.dupe(u8, png_metadata_vectors.color_png);
    defer std.testing.allocator.free(bytes);
    const image = try SourceImage.open(bytes, .{ .maximum_source_extent = 2 });
    const details = try image.metadata().read(.{});
    try std.testing.expect(image.metadata_presence.cicp);
    try std.testing.expect(image.metadata_presence.mastering_display);
    try std.testing.expect(image.metadata_presence.content_light);
    try std.testing.expect(image.metadata_presence.significant_bits);
    try std.testing.expect(image.metadata_presence.physical);
    try std.testing.expectEqual(.cicp, details.colorSource());
    try std.testing.expectEqual(45455, details.gamma.?);
    try std.testing.expectEqual(
        [8]u32{ 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000 },
        details.chromaticities.?,
    );
    try std.testing.expectEqual(0, details.srgb_intent.?);
    try std.testing.expectEqual(
        Metadata.Cicp{ .primaries = 9, .transfer = 16, .matrix = 0, .full_range = true },
        details.cicp.?,
    );
    try std.testing.expectEqual(
        [3][2]u16{ .{ 35400, 14600 }, .{ 8500, 39850 }, .{ 6550, 2300 } },
        details.mastering_display.?.primaries,
    );
    try std.testing.expectEqual([2]u16{ 15635, 16450 }, details.mastering_display.?.white_point);
    try std.testing.expectEqual(40000000, details.mastering_display.?.maximum_luminance);
    try std.testing.expectEqual(5, details.mastering_display.?.minimum_luminance);
    try std.testing.expectEqual(
        Metadata.ContentLight{ .maximum_content = 10000000, .maximum_frame_average = 2500000 },
        details.content_light.?,
    );
    try std.testing.expectEqualSlices(u8, &.{ 8, 7, 6, 8 }, details.significant_bits.?);
    try std.testing.expectEqual(
        Metadata.Physical{ .x = 2000, .y = 1000, .metres = false },
        details.physical.?,
    );
    var decoded = try owned_decode.rgbaAlloc(u8, std.testing.allocator, bytes, .{});
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 4, 5, 6, 255 }, decoded.texels);
    try std.testing.expectEqual(image.metadata_presence, decoded.metadata_presence);
}

test "PNG ICC and Exif views share checked payload mechanisms and explicit expansion" {
    const fixture = png_metadata_vectors;
    const bytes = try std.testing.allocator.dupe(u8, fixture.profile_png);
    defer std.testing.allocator.free(bytes);
    const image = try SourceImage.open(bytes, .{ .maximum_source_extent = 2 });
    const details = try image.metadata().read(.{});
    try std.testing.expectEqual(.icc, details.colorSource());
    const view = try exif_module.View.open(details.exif_payload.?, .{});
    try std.testing.expectEqual(.right_top, (try view.orientation()).?);
    const workspace = try deflate.DecoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    const expected = try std.testing.allocator.dupe(u8, fixture.srgb_icc);
    defer std.testing.allocator.free(expected);
    const destination = try std.testing.allocator.alloc(u8, expected.len);
    defer std.testing.allocator.free(destination);
    const profile_bytes = try details.icc_profile.?.expandInto(destination, workspace);
    try std.testing.expectEqualSlices(u8, expected, profile_bytes);
    const profile = try icc_module.Profile.open(profile_bytes, .{ .limits = .{ .tags = 11 } });
    try std.testing.expectEqualStrings("RGB ", &profile.color_space);
    try std.testing.expectEqual(11, profile.tag_count);
    try std.testing.expectEqual(4, profile.version[0]);
    try std.testing.expectError(
        error.OutputTooSmall,
        details.icc_profile.?.expandInto(destination[0 .. expected.len - 1], workspace),
    );
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        image.metadata().read(.{ .maximum_bytes = 8 }),
    );
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        image.metadata().read(.{ .maximum_records = 1 }),
    );
}

test "PNG compressed metadata restores bounded workspace backing after reuse" {
    const allocator = std.testing.allocator;
    const fixture = png_metadata_vectors;
    const bytes = try std.testing.allocator.dupe(u8, fixture.profile_png);
    defer allocator.free(bytes);
    const expected = try std.testing.allocator.dupe(u8, fixture.srgb_icc);
    defer allocator.free(expected);
    const details = try (try SourceImage.open(
        bytes,
        .{ .maximum_source_extent = 2 },
    )).metadata().read(.{});
    const destination = try allocator.alloc(u8, expected.len + 8);
    defer allocator.free(destination);
    const backing = try allocator.alignedAlloc(u8, .@"8", @sizeOf(deflate.DecoderWorkspace) + 128);
    defer allocator.free(backing);
    for (0..2) |index| {
        @memset(backing, 0xa5);
        var fixed = std.heap.FixedBufferAllocator.init(backing[8 .. backing.len - 8]);
        @memset(try fixed.allocator().alloc(u8, 17), 0x3c);
        var failing = std.testing.FailingAllocator.init(
            fixed.allocator(),
            .{ .fail_index = index },
        );
        if (deflate.DecoderWorkspace.create(failing.allocator())) |workspace| {
            const live = fixed.end_index;
            const requests = failing.alloc_index;
            for (0..2) |_| {
                try std.testing.expectError(
                    error.OutputTooSmall,
                    details.icc_profile.?.expandInto(destination[0 .. expected.len - 1], workspace),
                );
                @memset(destination, 0xa5);
                const expanded = try details.icc_profile.?.expandInto(
                    destination[0..expected.len],
                    workspace,
                );
                try std.testing.expectEqualSlices(u8, expected, expanded);
                for (destination[expected.len..]) |byte| try std.testing.expectEqual(0xa5, byte);
            }
            try std.testing.expectEqual(live, fixed.end_index);
            try std.testing.expectEqual(requests, failing.alloc_index);
            workspace.destroy(failing.allocator());
        } else |failure| try std.testing.expectEqual(error.OutOfMemory, failure);
        try std.testing.expectEqual(17, fixed.end_index);
        for (fixed.buffer[0..17]) |byte| try std.testing.expectEqual(0x3c, byte);
        for (backing[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (backing[backing.len - 8 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "PNG Latin-1 and compressed UTF-8 text match independent expansion controls" {
    const bytes = try std.testing.allocator.dupe(u8, png_metadata_vectors.profile_png);
    defer std.testing.allocator.free(bytes);
    const reader = (try SourceImage.open(bytes, .{ .maximum_source_extent = 2 })).metadata();
    var texts = reader.texts(.{});
    const workspace = try deflate.DecoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var destination: [64]u8 = undefined;
    const first = (try texts.next()).?;
    try std.testing.expectEqualStrings("Title", first.keyword);
    try std.testing.expect(!first.utf8 and !first.compressed);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x43, 0x61, 0x66, 0xe9 },
        try first.expandInto(&destination, workspace),
    );
    const second = (try texts.next()).?;
    try std.testing.expectEqualStrings("Comment", second.keyword);
    try std.testing.expect(second.compressed and !second.utf8);
    try std.testing.expectEqualStrings(
        "bounded compressed text",
        try second.expandInto(&destination, workspace),
    );
    const third = (try texts.next()).?;
    try std.testing.expect(third.compressed and third.utf8);
    try std.testing.expectEqualStrings("en-US", third.language);
    try std.testing.expectEqualStrings("Descripción", third.translated_keyword);
    try std.testing.expectEqualStrings("snowman ☃", try third.expandInto(&destination, workspace));
    try std.testing.expectError(
        error.OutputTooSmall,
        third.expandInto(destination[0..3], workspace),
    );
    try std.testing.expectEqual(null, try texts.next());
}

fn changeFixtureByte(bytes: []u8, name: [4]u8, index: usize, value: u8) !void {
    var offset: usize = 8;
    while (offset < bytes.len) {
        const size = readU32(bytes, offset);
        if (std.mem.eql(u8, bytes[offset + 4 ..][0..4], &name)) {
            bytes[offset + 8 + index] = value;
            const crc = std.hash.Crc32.hash(bytes[offset + 4 ..][0 .. 4 + size]);
            std.mem.writeInt(u32, bytes[offset + 8 + size ..][0..4], crc, .big);
            return;
        }
        offset += 12 + @as(usize, size);
    }
    return error.TestUnexpectedResult;
}

test "PNG text byte refusal persists without traversing later chunks" {
    const allocator = std.testing.allocator;
    const base = try std.testing.allocator.dupe(u8, png_metadata_vectors.uncompressed_itxt_png);
    defer allocator.free(base);
    // Literal tEXt fields with independent Python CRC-32; retain the frozen raster chunks.
    const texts = &[_]u8{
        0x00, 0x00, 0x00, 0x07, 0x74, 0x45, 0x58, 0x74,
        0x41, 0x00, 0x41, 0x42, 0x43, 0x44, 0x45, 0xea,
        0xf2, 0xb3, 0x78, 0x00, 0x00, 0x00, 0x05, 0x74,
        0x45, 0x58, 0x74, 0x42, 0x00, 0x61, 0x62, 0x63,
        0x42, 0xe4, 0x31, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x74, 0x45, 0x58, 0x74, 0x43, 0x00, 0x7a, 0xf4,
        0xec, 0xa8, 0xe3,
    };
    const source = try std.mem.concat(allocator, u8, &.{ base[0..33], texts, base[89..] });
    defer allocator.free(source);
    const reader = (try SourceImage.open(source, .{ .maximum_source_extent = 2 })).metadata();
    var iterator = reader.texts(.{ .maximum_bytes = 10 });
    try std.testing.expectEqualStrings("ABCDE", (try iterator.next()).?.data);
    try std.testing.expectError(error.MetadataLimitExceeded, iterator.next());
    const offset = iterator.chunks.offset;
    const records = iterator.chunks.records;
    for (0..4) |_| {
        try std.testing.expectError(error.MetadataLimitExceeded, iterator.next());
        try std.testing.expectEqual(7, iterator.chunks.selected_bytes);
        try std.testing.expectEqual(offset, iterator.chunks.offset);
        try std.testing.expectEqual(records, iterator.chunks.records);
    }
    const exact: Metadata.Limits = .{ .maximum_bytes = 15, .maximum_records = 6 };
    _ = try reader.read(exact);
    iterator = reader.texts(exact);
    for (
        [_][]const u8{ "ABCDE", "abc", "z" },
    ) |expected| try std.testing.expectEqualStrings(expected, (try iterator.next()).?.data);
    try std.testing.expectEqual(null, try iterator.next());
}

test "PNG iTXt ignores every compression method when its text is uncompressed" {
    const bytes = try std.testing.allocator.dupe(u8, png_metadata_vectors.uncompressed_itxt_png);
    defer std.testing.allocator.free(bytes);
    const workspace = try deflate.DecoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    const limits: Metadata.Limits = .{ .maximum_records = 4, .maximum_bytes = 44 };
    var destination: [32]u8 = undefined;
    for (0..256) |method| {
        try changeFixtureByte(bytes, "iTXt".*, 13, @intCast(method));
        const reader = (try SourceImage.open(bytes, .{ .maximum_source_extent = 2 })).metadata();
        _ = try reader.read(limits);
        var texts = reader.texts(limits);
        const text = (try texts.next()).?;
        try std.testing.expect(text.utf8 and !text.compressed);
        try std.testing.expectEqualStrings("Description", text.keyword);
        try std.testing.expectEqualStrings("en-US", text.language);
        try std.testing.expectEqualStrings("Descripción", text.translated_keyword);
        try std.testing.expectEqualStrings("snowman ☃", text.data);
        @memset(&destination, 0xa5);
        try std.testing.expectEqualStrings(
            "snowman ☃",
            try text.expandInto(&destination, workspace),
        );
        for (destination[11..]) |byte| try std.testing.expectEqual(0xa5, byte);
        @memset(&destination, 0xa5);
        try std.testing.expectError(
            error.OutputTooSmall,
            text.expandInto(destination[0..10], workspace),
        );
        for (destination) |byte| try std.testing.expectEqual(0xa5, byte);
        try std.testing.expectEqual(null, try texts.next());
    }
    const reader = (try SourceImage.open(bytes, .{ .maximum_source_extent = 2 })).metadata();
    try std.testing.expectError(error.MetadataLimitExceeded, reader.read(.{ .maximum_bytes = 43 }));
    var limited_texts = reader.texts(.{ .maximum_bytes = 43 });
    try std.testing.expectError(error.MetadataLimitExceeded, limited_texts.next());
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        reader.read(.{ .maximum_records = 3 }),
    );
    var decoded = try owned_decode.rgbaAlloc(u8, std.testing.allocator, bytes, .{});
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 4, 5, 6, 255 }, decoded.texels);
}

test "PNG iTXt validates compression flags and selected compressed methods" {
    const bytes = try std.testing.allocator.dupe(u8, png_metadata_vectors.profile_png);
    defer std.testing.allocator.free(bytes);
    for ([_]u8{ 1, 255 }) |method| {
        try changeFixtureByte(bytes, "iTXt".*, 13, method);
        const reader = (try SourceImage.open(bytes, .{ .maximum_source_extent = 2 })).metadata();
        try std.testing.expectError(error.UnsupportedPngMetadata, reader.read(.{}));
        var texts = reader.texts(.{});
        _ = try texts.next();
        _ = try texts.next();
        try std.testing.expectError(error.UnsupportedPngMetadata, texts.next());
    }
    for ([_]u8{ 2, 255 }) |flag| {
        try std.testing.expectError(
            error.InvalidPngMetadata,
            parseText(.{ .name = "iTXt".*, .data = &.{ 'K', 0, flag, 255, 0, 0 } }),
        );
    }
    try std.testing.expectError(
        error.InvalidPngMetadata,
        parseText(
            .{ .name = "iTXt".*, .data = &[_]u8{ 0x4b, 0x00, 0x00, 0xff, 0x00, 0x00, 0xc0, 0x80 } },
        ),
    );
}

test "malformed optional PNG metadata fails selected queries while stored pixels remain valid" {
    const cases = [_]struct {
        name: [4]u8,
        index: usize,
        value: u8,
    }{
        .{ .name = "sRGB".*, .index = 0, .value = 4 },
        .{ .name = "cICP".*, .index = 2, .value = 1 },
        .{ .name = "cICP".*, .index = 3, .value = 2 },
        .{ .name = "sBIT".*, .index = 1, .value = 9 },
        .{ .name = "sBIT".*, .index = 1, .value = 0 },
        .{ .name = "pHYs".*, .index = 8, .value = 2 },
        .{ .name = "pHYs".*, .index = 0, .value = 128 },
        .{ .name = "gAMA".*, .index = 0, .value = 128 },
        .{ .name = "cHRM".*, .index = 0, .value = 128 },
        .{ .name = "mDCV".*, .index = 16, .value = 128 },
        .{ .name = "cLLI".*, .index = 0, .value = 128 },
    };
    for (cases) |case| {
        const bytes = try std.testing.allocator.dupe(u8, png_metadata_vectors.color_png);
        defer std.testing.allocator.free(bytes);
        try changeFixtureByte(bytes, case.name, case.index, case.value);
        const reader = (try SourceImage.open(bytes, .{ .maximum_source_extent = 2 })).metadata();
        try std.testing.expectError(error.InvalidPngMetadata, reader.read(.{}));
        var image = try owned_decode.rgbaAlloc(u8, std.testing.allocator, bytes, .{});
        defer image.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 4, 5, 6, 255 }, image.texels);
    }
}

test "PNG metadata permits density Exif and animation after a suggested palette" {
    // PNG Third Edition table 7 permits these records after PLTE, before IDAT. Python zlib 1.3.2
    // independently framed this 2x1 RGB8 image and one-frame APNG declaration. The TIFF payload
    // records orientation 6; neither density nor orientation changes samples.
    // https://www.w3.org/TR/2025/REC-png-3-20250624/#5ChunkOrdering
    const source: []const u8 = &[_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x7b, 0x40, 0xe8,
        0xdd, 0x00, 0x00, 0x00, 0x06, 0x50, 0x4c, 0x54,
        0x45, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x95,
        0x53, 0x6f, 0x48, 0x00, 0x00, 0x00, 0x08, 0x61,
        0x63, 0x54, 0x4c, 0x00, 0x00, 0x00, 0x01, 0x00,
        0x00, 0x00, 0x03, 0x2d, 0x24, 0xb8, 0x1a, 0x00,
        0x00, 0x00, 0x1a, 0x65, 0x58, 0x49, 0x66, 0x49,
        0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xb7, 0x48, 0x11, 0x29, 0x00, 0x00, 0x00,
        0x09, 0x70, 0x48, 0x59, 0x73, 0x00, 0x00, 0x07,
        0xd0, 0x00, 0x00, 0x03, 0xe8, 0x01, 0xa9, 0x1d,
        0xf3, 0xb8, 0x00, 0x00, 0x00, 0x1a, 0x66, 0x63,
        0x54, 0x4c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        0x00, 0x07, 0x00, 0x00, 0xb6, 0x51, 0x5f, 0xfa,
        0x00, 0x00, 0x00, 0x0f, 0x49, 0x44, 0x41, 0x54,
        0x78, 0x9c, 0x63, 0x60, 0x64, 0x62, 0x66, 0x61,
        0x65, 0x03, 0x00, 0x00, 0x3f, 0x00, 0x16, 0x21,
        0xba, 0xd4, 0x54, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
    const image = try SourceImage.open(source, .{ .maximum_source_extent = 2 });
    const exact: Metadata.Limits = .{ .maximum_bytes = 43, .maximum_records = 8 };
    const details = try image.metadata().read(exact);
    try std.testing.expectEqualDeep(
        Metadata.Physical{ .x = 2000, .y = 1000, .metres = true },
        details.physical.?,
    );
    try std.testing.expectEqualDeep(
        Metadata.AnimationInfo{ .frame_count = 1, .play_count = 3 },
        details.animation.?,
    );
    try std.testing.expectEqual(source.ptr + 79, details.exif_payload.?.ptr);
    try std.testing.expectEqual(26, details.exif_payload.?.len);
    const exif = try exif_module.View.open(details.exif_payload.?, .{});
    try std.testing.expectEqual(.right_top, (try exif.orientation()).?);
    try std.testing.expectEqual(.unspecified, details.colorSource());
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        image.metadata().read(.{ .maximum_bytes = 42, .maximum_records = 8 }),
    );
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        image.metadata().read(.{ .maximum_bytes = 43, .maximum_records = 7 }),
    );

    // Keep independently framed chunks exact while moving each beyond the IDAT sequence.
    for ([_][2]usize{ .{ 51, 71 }, .{ 71, 109 }, .{ 109, 130 } }) |range| {
        const moved = try std.mem.concat(
            std.testing.allocator,
            u8,
            &.{
                source[0..range[0]],
                source[range[1]..195],
                source[range[0]..range[1]],
                source[195..],
            },
        );
        defer std.testing.allocator.free(moved);
        const moved_image = try SourceImage.open(moved, .{ .maximum_source_extent = 2 });
        try std.testing.expectError(error.InvalidPngMetadata, moved_image.metadata().read(exact));
    }
    // Color declarations retain their stricter PLTE boundary. CRC is independently frozen.
    const srgb = &[_]u8{
        0x00, 0x00, 0x00, 0x01, 0x73, 0x52, 0x47, 0x42,
        0x00, 0xae, 0xce, 0x1c, 0xe9,
    };
    const misplaced = try std.mem.concat(
        std.testing.allocator,
        u8,
        &.{ source[0..51], srgb, source[51..] },
    );
    defer std.testing.allocator.free(misplaced);
    const misplaced_image = try SourceImage.open(misplaced, .{ .maximum_source_extent = 2 });
    try std.testing.expectError(error.InvalidPngMetadata, misplaced_image.metadata().read(.{}));
    const preceding = try std.mem.concat(
        std.testing.allocator,
        u8,
        &.{ source[0..33], srgb, source[33..] },
    );
    defer std.testing.allocator.free(preceding);
    const preceding_image = try SourceImage.open(preceding, .{ .maximum_source_extent = 2 });
    try std.testing.expectEqual(.srgb, (try preceding_image.metadata().read(.{})).colorSource());
}

test "PNG singleton placement and required HDR declarations are selected errors" {
    const bytes = try std.testing.allocator.dupe(u8, png_metadata_vectors.color_png);
    defer std.testing.allocator.free(bytes);
    // The independent control has cHRM at [33,77), gAMA at [77,93), sRGB at [93,106), cICP at
    // [106,122), and IEND in the last twelve bytes.
    const duplicate = try std.mem.concat(
        std.testing.allocator,
        u8,
        &.{ bytes[0..93], bytes[77..93], bytes[93..] },
    );
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(
        error.InvalidPngMetadata,
        (try SourceImage.open(duplicate, .{ .maximum_source_extent = 2 })).metadata().read(.{}),
    );
    const misplaced = try std.mem.concat(
        std.testing.allocator,
        u8,
        &.{ bytes[0..77], bytes[93 .. bytes.len - 12], bytes[77..93], bytes[bytes.len - 12 ..] },
    );
    defer std.testing.allocator.free(misplaced);
    try std.testing.expectError(
        error.InvalidPngMetadata,
        (try SourceImage.open(misplaced, .{ .maximum_source_extent = 2 })).metadata().read(.{}),
    );
    const missing = try std.mem.concat(
        std.testing.allocator,
        u8,
        &.{ bytes[0..106], bytes[122..] },
    );
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(
        error.InvalidPngMetadata,
        (try SourceImage.open(missing, .{ .maximum_source_extent = 2 })).metadata().read(.{}),
    );
    try std.testing.expectEqual(
        .srgb,
        (Metadata{ .srgb_intent = 0, .gamma = 45455 }).colorSource(),
    );
    try std.testing.expectEqual(
        .icc,
        (Metadata{
            .srgb_intent = 0,
            .icc_profile = .{ .name = "profile", .data = "" },
        }).colorSource(),
    );
    try std.testing.expectEqual(.unspecified, (Metadata{}).colorSource());
}

test "PNG text keywords UTF-8 framing and compressed checksums have explicit failures" {
    for ([_][]const u8{ "", " key", "key ", "two  spaces", &[_]u8{0x7f} }) |keyword| {
        try std.testing.expectError(error.InvalidPngMetadata, validateKeyword(keyword));
    }
    try std.testing.expectError(
        error.InvalidPngMetadata,
        parseText(
            .{
                .name = "iTXt".*,
                .data = &[_]u8{
                    0x6b, 0x65, 0x79, 0x00, 0x00, 0x00, 0x65, 0x6e,
                    0x00, 0xff, 0x00, 0x74, 0x65, 0x78, 0x74,
                },
            },
        ),
    );
    try std.testing.expectError(
        error.InvalidPngMetadata,
        parseText(
            .{
                .name = "iTXt".*,
                .data = &[_]u8{
                    0x6b, 0x65, 0x79, 0x00, 0x00, 0x00, 0x65, 0x6e,
                    0x00, 0x74, 0x72, 0x61, 0x6e, 0x73, 0x6c, 0x61,
                    0x74, 0x65, 0x64, 0x00, 0xc0, 0x80,
                },
            },
        ),
    );
    try std.testing.expectError(
        error.UnsupportedPngMetadata,
        parseText(
            .{
                .name = "zTXt".*,
                .data = &[_]u8{ 0x6b, 0x65, 0x79, 0x00, 0x01, 0x64, 0x61, 0x74, 0x61 },
            },
        ),
    );
    const workspace = try deflate.DecoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var destination: [4]u8 = undefined;
    // Independent stored zlib encoding of abc: header, LEN/NLEN, bytes, Adler-32.
    const valid = &[_]u8{
        0x78, 0x01, 0x01, 0x03, 0x00, 0xfc, 0xff, 0x61,
        0x62, 0x63, 0x02, 0x4d, 0x01, 0x27,
    };
    try std.testing.expectEqualStrings("abc", try expandZlib(valid, &destination, workspace));
    try std.testing.expectError(
        error.InvalidStream,
        expandZlib(valid ++ "x", &destination, workspace),
    );
    var corrupted = valid.*;
    corrupted[corrupted.len - 1] ^= 1;
    try std.testing.expectError(
        error.InvalidStream,
        expandZlib(&corrupted, &destination, workspace),
    );
}
