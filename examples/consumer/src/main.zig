//! Complete public API calls from outside the library's test composition.
const std = @import("std");
const adler32 = @import("wingman").adler32;
const crc32 = @import("wingman").crc32;
const xxhash32 = @import("wingman").xxhash32;
const xxhash64 = @import("wingman").xxhash64;
const blake3 = @import("wingman").blake3;
const lz4 = @import("wingman").lz4;
const riff = @import("wingman").riff;
const pcm = @import("wingman").pcm;
const g711 = @import("wingman").g711;
const adpcm = @import("wingman").adpcm;
const exif = @import("wingman").exif;

test "Adler-32 one-shot streaming and byte order" {
    const result = adler32.hash("Wikipedia");
    try std.testing.expectEqual(@as(u32, 0x11e60398), result);
    var state: adler32.Hasher = .init;
    state.update("Wiki");
    const snapshot = state.final();
    state.update("pedia");
    try std.testing.expectEqual(result, state.final());
    try std.testing.expectEqual(snapshot, adler32.hash("Wiki"));
    var footer: [4]u8 = undefined;
    std.mem.writeInt(u32, &footer, result, .big);
    try std.testing.expectEqual([4]u8{ 0x11, 0xe6, 0x03, 0x98 }, footer);
}

test "Adler-32 retired inputs independent states and combination" {
    var input = "123456789".*;
    var state: adler32.Hasher = .init;
    state.update(&input);
    @memset(&input, 0xff);
    try std.testing.expectEqual(@as(u32, 0x091e01de), state.final());
    var copy = state;
    state = .init;
    state.update("");
    try std.testing.expectEqual(@as(u32, 1), state.final());
    copy.update("0");
    try std.testing.expectEqual(std.hash.Adler32.hash("1234567890"), copy.final());

    const chunks = [_][]const u8{ "123", "456", "789" };
    const operator = adler32.CombineOperator.forLength(3);
    var combined: u32 = 1;
    for (chunks) |chunk| combined = operator.apply(combined, adler32.hash(chunk));
    try std.testing.expectEqual(@as(u32, 0x091e01de), combined);
    try std.testing.expectEqual(
        @as(u32, 0x11e60398),
        adler32.combine(adler32.hash("Wiki"), adler32.hash("pedia"), 5),
    );
}

test "IEEE CRC streaming snapshots copies and retired input" {
    try std.testing.expectEqual(@as(u32, 0xcbf43926), crc32.hash("123456789"));
    var input = "1234".*;
    var state: crc32.Hasher = .init;
    state.update(&input);
    const prefix = state.final();
    var copy = state;
    @memset(&input, 0xff);
    state.update("");
    state.update("56789");
    copy.update("abcd");
    try std.testing.expectEqual(crc32.hash("1234"), prefix);
    try std.testing.expectEqual(@as(u32, 0xcbf43926), state.final());
    try std.testing.expectEqual(std.hash.Crc32.hash("1234abcd"), copy.final());
    state = .init;
    try std.testing.expectEqual(@as(u32, 0), state.final());
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(crc32.Hasher));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(crc32.CombineOperator));
}

test "PNG type plus data coverage and format byte orders" {
    // A one-pixel, 8-bit RGBA IHDR payload; dimensions and format bytes are constructed here.
    const header = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0 };
    var state: crc32.Hasher = .init;
    state.update("IHDR");
    state.update(&header);
    try std.testing.expectEqual(@as(u32, 0x1f15c489), state.final());
    try std.testing.expectEqual(
        state.final(),
        crc32.combine(crc32.hash("IHDR"), crc32.hash(&header), header.len),
    );
    var field: [4]u8 = undefined;
    std.mem.writeInt(u32, &field, state.final(), .big);
    try std.testing.expectEqual([4]u8{ 0x1f, 0x15, 0xc4, 0x89 }, field);
    std.mem.writeInt(u32, &field, crc32.hash("123456789"), .little);
    try std.testing.expectEqual([4]u8{ 0x26, 0x39, 0xf4, 0xcb }, field);
    try std.testing.expectEqual(@as(u32, 0xae426082), crc32.hash("IEND"));
}

test "IEEE CRC reusable combination operators" {
    const operator = crc32.CombineOperator.forLength(3);
    var result: u32 = 0;
    for ([_][]const u8{ "123", "456", "789" }) |chunk| {
        result = operator.apply(result, crc32.hash(chunk));
    }
    try std.testing.expectEqual(@as(u32, 0xcbf43926), result);
    try std.testing.expectEqual(crc32.hash("prefix"), crc32.combine(crc32.hash("prefix"), 0, 0));
    // This length is an algebraic advance; it does not allocate an equally large buffer.
    const wide_length = @as(u64, 1) << 63;
    const wide = crc32.CombineOperator.forLength(wide_length);
    try std.testing.expectEqual(crc32.combine(1, 2, wide_length), wide.apply(1, 2));
}

test "classic xxHash fixed facts and seeded streaming" {
    try std.testing.expectEqual(@as(u32, 0x32d153ff), xxhash32.hash("abc"));
    try std.testing.expectEqual(@as(u64, 0x44bc2cf5ad770999), xxhash64.hash("abc"));
    try std.testing.expectEqual(@as(u32, 0xaa3da8ff), xxhash32.hashSeeded(1, "abc"));
    try std.testing.expectEqual(@as(u64, 0x13c1d910702770e6), xxhash64.hashSeeded(42, "abc"));
    var state32: xxhash32.Hasher = undefined;
    var state64: xxhash64.Hasher = undefined;
    state32.reset(0xffffffff);
    state64.reset(0x8000000000000001);
    state32.update("a");
    state64.update("a");
    const prefix32 = state32.final();
    const prefix64 = state64.final();
    var copy32 = state32;
    var copy64 = state64;
    state32.update("bc");
    state64.update("bc");
    copy32.update("d");
    copy64.update("d");
    try std.testing.expectEqual(std.hash.XxHash32.hash(0xffffffff, "a"), prefix32);
    try std.testing.expectEqual(std.hash.XxHash64.hash(0x8000000000000001, "a"), prefix64);
    try std.testing.expectEqual(std.hash.XxHash32.hash(0xffffffff, "abc"), state32.final());
    try std.testing.expectEqual(std.hash.XxHash64.hash(0x8000000000000001, "abc"), state64.final());
    try std.testing.expectEqual(std.hash.XxHash32.hash(0xffffffff, "ad"), copy32.final());
    try std.testing.expectEqual(std.hash.XxHash64.hash(0x8000000000000001, "ad"), copy64.final());
}

test "classic xxHash numeric encoding and zero-seed reset" {
    var canonical32: [4]u8 = undefined;
    var canonical64: [8]u8 = undefined;
    std.mem.writeInt(u32, &canonical32, xxhash32.hash("abc"), .big);
    std.mem.writeInt(u64, &canonical64, xxhash64.hash("abc"), .big);
    try std.testing.expectEqual([4]u8{ 0x32, 0xd1, 0x53, 0xff }, canonical32);
    try std.testing.expectEqual([8]u8{
        0x44, 0xbc, 0x2c, 0xf5, 0xad, 0x77, 0x09, 0x99,
    }, canonical64);
    var state32: xxhash32.Hasher = .init;
    var state64: xxhash64.Hasher = .init;
    state32.update("discard");
    state64.update("discard");
    state32 = .init;
    state64 = .init;
    state32.update("");
    state64.update("");
    try std.testing.expectEqual(@as(u32, 0x02cc5d05), state32.final());
    try std.testing.expectEqual(@as(u64, 0xef46db3751d8e999), state64.final());
}

test "WAVE owned and caller samples retain rate and independent storage" {
    const wav = @import("wingman").wav;
    var bytes: [48]u8 = undefined;
    const encoded = try wav.encodePcm16Into(
        .{ .sample_rate = 8000, .channels = .mono, .samples = &.{ -1, 0.5 } },
        &bytes,
    );
    try std.testing.expectEqual(
        48,
        try wav.encodePcm16Requirements(.{ .sample_rate = 8000, .channels = .mono, .samples = &.{
            -1, 0.5,
        } }),
    );
    const required = try wav.decodeRequirements(encoded, &.{});
    try std.testing.expectEqual(2, required.frames);
    var samples: [3]f32 = @splat(42);
    const view = try wav.decodeInto(encoded, &samples, &.{});
    try std.testing.expectEqual(8000, view.sample_rate);
    try std.testing.expectEqual(wav.Channels.mono, view.channels);
    try std.testing.expectEqualSlices(f32, &.{ -1, 0.5 }, view.samples);
    try std.testing.expectEqual(42, samples[2]);
    var owned = try wav.decodeAlloc(std.testing.allocator, encoded);
    defer owned.deinit(std.testing.allocator);
    @memset(&bytes, 0xa5);
    try std.testing.expectEqualSlices(f32, &.{ -1, 0.5 }, owned.view().samples);
}

test "WAVE chunk inspection and inline std.Io conversion use the public namespace" {
    const wav = @import("wingman").wav;
    var bytes: [56]u8 = undefined;
    const encoded = try wav.encodePcm16Into(
        .{ .sample_rate = 48000, .channels = .stereo, .samples = &.{ -1, 1, -0.5, 0.5, 0, 0.25 } },
        &bytes,
    );
    const container = try wav.parse(encoded);
    var chunks = try container.iterator(&.{});
    const format_chunk = (try chunks.next()).?;
    try std.testing.expectEqualStrings("fmt ", format_chunk.id);
    const format = try wav.parseFormat(format_chunk.data);
    const data = (try chunks.next()).?;
    try std.testing.expectEqual(3, try wav.frameCount(format, data.data.len));
    try std.testing.expectEqual(null, try chunks.next());
    var samples: [6]f32 = undefined;
    var workers: [2]wav.Worker = undefined;
    const view = try wav.decodeParallelInto(
        std.Io.failing,
        encoded,
        &samples,
        &.{},
        &workers,
        .{ .minimum_bytes = 0, .minimum_job_bytes = 1 },
    );
    try std.testing.expectEqualSlices(
        f32,
        &.{ -1, 32767.0 / 32768.0, -0.5, 0.5, 0, 0.25 },
        view.samples,
    );
    for (workers) |worker| try std.testing.expectEqual(0, worker.source.len);
}

test "RIFF borrowed chunks and externally resolved geometry" {
    const bytes = "RIFF\x0e\x00\x00\x00TESTdata\x01\x00\x00\x00x\xa5tail";
    const form = try riff.parse(bytes);
    try std.testing.expectEqualStrings("TEST", &form.form_type);
    try std.testing.expectEqual(22, form.source.len);
    var chunks = form.iterator();
    const chunk = (try chunks.next()).?;
    try std.testing.expectEqualStrings("data", chunk.id);
    try std.testing.expectEqualStrings("x", chunk.data);
    try std.testing.expectEqual(0xa5, chunk.padding.?);
    try std.testing.expectEqual(null, try chunks.next());
    var resolved: riff.ChunkIterator = .{ .source = "data\xff\xff\xff\xffx\x00" };
    try std.testing.expectError(error.InvalidRiff, resolved.nextResolved(3));
    try std.testing.expectEqual(0, resolved.offset);
    try std.testing.expectEqualStrings("x", (try resolved.nextResolved(1)).?.data);
}

test "RIFF writer literal bytes and lazy nested lists" {
    var bytes: [22]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try riff.writeHeader("DEMO".*, try riff.chunkSize(1), &writer);
    try riff.writeChunk("note".*, "x", &writer);
    try std.testing.expectEqualStrings("RIFF\x0e\x00\x00\x00DEMOnote\x01\x00\x00\x00x\x00", &bytes);
    var outer: riff.ChunkIterator = .{ .source = "LIST\x05\x00\x00\x00INFOx\x00" };
    const list = try (try outer.next()).?.list();
    try std.testing.expectEqualStrings("INFO", &list.list_type);
    var children = list.iterator();
    try std.testing.expectError(error.InvalidRiff, children.next());
}

test "PCM packed precision and finite float words from outside the module" {
    const bytes = [_]u8{ 0, 0, 128, 255, 255, 255, 0, 0, 0, 255, 255, 127 };
    var destination: [6]f32 = @splat(123);
    const result = try pcm.decodeInto(&bytes, &destination, .{ .encoding = .signed24 });
    try std.testing.expectEqualSlices(
        f32,
        &.{ -1, -1.0 / 8388608.0, 0, 8388607.0 / 8388608.0 },
        result,
    );
    try std.testing.expectEqualSlices(f32, &.{ 123, 123 }, destination[4..]);
    try std.testing.expectEqual(3, pcm.Encoding.signed24.byteCount());
    try std.testing.expectError(error.InvalidData, pcm.sampleCount(5, .{ .encoding = .signed24 }));
    const float_bytes = [_]u8{ 0, 0, 0, 128, 0, 0, 0, 64 };
    const floats = try pcm.decodeInto(&float_bytes, &destination, .{ .encoding = .float32 });
    try std.testing.expectEqual(0x80000000, @as(u32, @bitCast(floats[0])));
    try std.testing.expectEqual(2, floats[1]);
}

test "PCM16 caller storage and Writer validate before output" {
    const samples = [_]f32{ -1, -0.5, 0, 0.5, 1 };
    var bytes: [12]u8 = @splat(0xa7);
    const encoded = try pcm.encodePcm16Into(&samples, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 0, 192, 0, 0, 0, 64, 255, 127 }, encoded);
    try std.testing.expectEqualSlices(u8, &.{ 0xa7, 0xa7 }, bytes[10..]);
    var writer_bytes: [10]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_bytes);
    try pcm.writePcm16(&samples, &writer);
    try std.testing.expectEqualSlices(u8, encoded, writer.buffered());
    try std.testing.expectError(error.InvalidSamples, pcm.validatePcm16(&.{1.5}));
    const before = bytes;
    try std.testing.expectError(
        error.InvalidSamples,
        pcm.encodePcm16Into(&.{std.math.nan(f32)}, &bytes),
    );
    try std.testing.expectEqualSlices(u8, &before, &bytes);
}

test "G.711 scalar facts normalized output and PCM16 composition" {
    try std.testing.expectEqual(-8, g711.decodeAlaw(0x55));
    try std.testing.expectEqual(8, g711.decodeAlaw(0xd5));
    try std.testing.expectEqual(0, g711.decodeMulaw(0x7f));
    try std.testing.expectEqual(0, g711.decodeMulaw(0xff));
    const source = [_]u8{ 0, 128, 127, 255 };
    var output: [6]f32 = @splat(42);
    const samples = try g711.decodeInto(&source, &output, .mulaw);
    try std.testing.expectEqualSlices(
        f32,
        &.{ -32124.0 / 32768.0, 32124.0 / 32768.0, 0, 0 },
        samples,
    );
    try std.testing.expectEqualSlices(f32, &.{ 42, 42 }, output[4..]);
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{
        0x84, 0x82, 0x7c, 0x7d, 0, 0, 0, 0,
    }, try pcm.encodePcm16Into(samples, &bytes));
}

test "G.711 refusal ordering preserves caller storage" {
    var shared: [4]f32 = @splat(0.25);
    const before = shared;
    const bytes = std.mem.sliceAsBytes(&shared);
    try std.testing.expectError(
        error.DestinationTooSmall,
        g711.decodeInto(bytes[0..4], shared[0..3], .alaw),
    );
    try std.testing.expectError(error.Aliasing, g711.decodeInto(bytes[0..4], &shared, .alaw));
    try std.testing.expectEqualSlices(f32, &before, &shared);
}

test "ADPCM Microsoft literal samples from caller-owned coefficients" {
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    const source = [_]u8{ 0, 16, 0, 100, 0, 0x9c, 0xff, 0x12 };
    const format: adpcm.Format = .{
        .encoding = .microsoft_wave,
        .channels = 1,
        .block_bytes = 8,
        .frames_per_block = 4,
        .coefficients = &coefficients,
    };
    try std.testing.expectEqual(4, try adpcm.frameCount(source.len, format));
    var output: [6]f32 = @splat(42);
    const decoded = try adpcm.decodeInto(&source, &output, format);
    try std.testing.expectEqualSlices(
        f32,
        &.{ -100.0 / 32768.0, 100.0 / 32768.0, 116.0 / 32768.0, 148.0 / 32768.0 },
        decoded,
    );
    try std.testing.expectEqualSlices(f32, &.{ 42, 42 }, output[4..]);
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{
        0x9c, 0xff, 100, 0, 116, 0, 148, 0,
    }, try pcm.encodePcm16Into(decoded, &bytes));
}

test "ADPCM prefix still rejects omitted invalid IMA blocks" {
    const format: adpcm.Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 4,
        .frames_per_block = 1,
    };
    const source = [_]u8{ 0, 128, 0, 0, 0, 0, 89, 0 };
    var output: [2]f32 = @splat(42);
    try std.testing.expectError(
        error.DestinationTooSmall,
        adpcm.decodePrefixInto(&source, &.{}, 1, format),
    );
    try std.testing.expectError(
        error.InvalidData,
        adpcm.decodePrefixInto(&source, &output, 1, format),
    );
    try std.testing.expectEqual(-1, output[0]);
    try std.testing.expectEqual(42, output[1]);
    try std.testing.expectError(
        error.InvalidData,
        adpcm.decodePrefixInto(&source, &output, 0, format),
    );
}

test "Exif metadata borrows either TIFF byte order" {
    for ([_][]const u8{ &.{
        0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0,
    }, &.{
        0x4d, 0x4d, 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0,
    } }) |bytes| {
        const view = try exif.View.open(bytes, .{});
        try std.testing.expectEqual(exif.Orientation.right_top, (try view.orientation()).?);
        try std.testing.expectEqual(2, view.record_count);
        const entry = (try (try view.primary()).find(0x0112)).?;
        try std.testing.expectEqual(6, try entry.unsignedScalar());
        try std.testing.expectEqual(
            @intFromPtr(bytes.ptr) + 18,
            @intFromPtr((try entry.data()).ptr),
        );
        try std.testing.expectEqual(null, try view.thumbnail());
    }
}

test "Exif admission and field interpretation have separate boundaries" {
    const short = [_]u8{ 0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0 };
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        exif.View.open(&short, .{ .limits = .{ .records = 1 } }),
    );
    try std.testing.expectError(error.InvalidExif, exif.View.open(&short, .{}));
    const unknown_type = [_]u8{
        0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 129, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0,
    };
    const view = try exif.View.open(&unknown_type, .{ .limits = .{ .records = 2 } });
    const primary = try view.primary();
    const entry = primary.entry(0).?;
    try std.testing.expectEqual(129, entry.field_type);
    try std.testing.expectError(error.UnsupportedExif, entry.data());
    try std.testing.expectEqual(1, (try view.directoryAt(view.first_ifd)).count);
}

test "BLAKE3 complete input retired bytes snapshots and selected output" {
    const state = try std.testing.allocator.create(blake3.Hasher);
    defer std.testing.allocator.destroy(state);
    defer state.clear();
    const digest = try state.hash("abc");
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(
        "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85",
        &hex,
    );
    var input = "abc".*;
    state.reset();
    try state.update(input[0..1]);
    const prefix = state.final();
    try state.update(input[1..]);
    @memset(&input, 0xff);
    try std.testing.expectEqual(digest, state.final());
    try std.testing.expect(!std.mem.eql(u8, &prefix, &digest));
    var extended: [96]u8 = undefined;
    try state.finalizeSeek(0, &extended);
    var selected: [40]u8 = undefined;
    try state.finalizeSeek(31, &selected);
    try std.testing.expectEqualSlices(u8, &digest, extended[0..32]);
    try std.testing.expectEqualSlices(u8, extended[31..71], &selected);
    try state.update("d");
    var expected: blake3.Digest = undefined;
    std.crypto.hash.Blake3.hash("abcd", &expected, .{});
    try std.testing.expectEqual(expected, state.final());
    @memset(&selected, 0xa5);
    try std.testing.expectError(
        error.SizeOverflow,
        state.finalizeSeek(std.math.maxInt(u64), &selected),
    );
    try std.testing.expect(std.mem.allEqual(u8, &selected, 0xa5));
}

test "BLAKE3 keyed and derived modes own retained state" {
    const state = try std.testing.allocator.create(blake3.Hasher);
    defer std.testing.allocator.destroy(state);
    defer state.clear();
    const key = "whats the Elvish word for friend".*;
    state.resetKeyed(key);
    try state.update("");
    const keyed_hex = std.fmt.bytesToHex(state.final(), .lower);
    try std.testing.expectEqualStrings(
        "92b2b75604ed3c761f9d6f62392c8a9227ad0ea3f09573e783f1498a4ed60d26",
        &keyed_hex,
    );
    try state.resetDerive("BLAKE3 2019-12-27 16:29:52 test vectors context");
    try state.update("");
    const derived_hex = std.fmt.bytesToHex(state.final(), .lower);
    try std.testing.expectEqualStrings(
        "2cc39783c223154fea8dfb7c1b1660f2ac2dcbd1c1de8277b0b0dd39b7e50d7d",
        &derived_hex,
    );
    state.clear();
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(state), 0));
    _ = try state.hash("abc");
}

test "BLAKE3 public parallel API permits inline provider and retires workers" {
    const input = try std.testing.allocator.alloc(u8, 262144);
    defer std.testing.allocator.free(input);
    for (input, 0..) |*byte, index| byte.* = @intCast(index % 251);
    const state = try std.testing.allocator.create(blake3.Hasher);
    defer std.testing.allocator.destroy(state);
    defer state.clear();
    const workers = try std.testing.allocator.alloc(blake3.Worker, 4);
    defer std.testing.allocator.free(workers);
    defer for (workers) |*worker| worker.clear();
    state.reset();
    try state.updateParallel(std.Io.failing, input, workers, .{});
    var expected: blake3.Digest = undefined;
    std.crypto.hash.Blake3.hash(input, &expected, .{});
    try std.testing.expectEqual(expected, state.final());
    for (workers) |worker| try std.testing.expectEqual(0, worker.input.len);
}

test "LZ4 literal wire fixed counts exact extent and spare capacity" {
    var encoded = [_]u8{ 0x50, 'h', 'e', 'l', 'l', 'o' };
    var output: [8]u8 = @splat(0xa5);
    const bounded = try lz4.decodeBlock(&encoded, &output, .{ .output_size = .bounded });
    try std.testing.expectEqual(6, bounded.consumed);
    try std.testing.expectEqual(5, bounded.produced);
    try std.testing.expectEqualStrings("hello", output[0..5]);
    try std.testing.expect(std.mem.allEqual(u8, output[5..], 0xa5));
    try std.testing.expectError(error.OutputSizeMismatch, lz4.decodeBlock(&encoded, &output, .{}));
    const exact = try lz4.decodeBlock(&encoded, output[0..5], .{});
    @memset(&encoded, 0xff);
    try std.testing.expectEqual(5, exact.produced);
    try std.testing.expectEqualStrings("hello", output[0..5]);
}

test "LZ4 dictionary blocks greedy HC and finite work refusal" {
    const allocator = std.testing.allocator;
    const dictionary = "dictionary words dictionary words";
    const source = "dictionary words dictionary words plus a final literal tail";
    const workspace = try lz4.EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const hc = try lz4.HcEncoderWorkspace.create(allocator);
    defer hc.destroy(allocator);
    defer hc.clear();
    const storage = try allocator.alloc(u8, try lz4.blockEncodeBound(source.len));
    defer allocator.free(storage);
    var output: [source.len]u8 = undefined;
    const fast_block = try lz4.encodeBlock(
        source,
        storage,
        workspace,
        .{ .dictionary = dictionary },
    );
    const history: lz4.HistoryView = .{ .older = dictionary[0..10], .newer = dictionary[10..] };
    _ = try lz4.decodeBlock(fast_block, &output, .{ .dictionary = history });
    try std.testing.expectEqualStrings(source, &output);
    const hc_block = try lz4.encodeBlockHc(source, storage, hc, .{ .dictionary = dictionary });
    _ = try lz4.decodeBlock(hc_block, &output, .{ .dictionary = history });
    try std.testing.expectEqualStrings(source, &output);
    try std.testing.expect(hc.stats.work_units > 0);
    try std.testing.expectError(
        error.LimitExceeded,
        lz4.encodeBlockHc(source, storage, hc, .{ .limits = .{ .work_units = 0 } }),
    );
    _ = try lz4.encodeBlockHc(source, storage, hc, .{});
}

test "LZ4 raw decoder retires one-byte fragments and requires reset after failure" {
    const wire = [_]u8{ 0x50, 'h', 'e', 'l', 'l', 'o' };
    const allocator = std.testing.allocator;
    const history = try allocator.create([65536]u8);
    defer allocator.destroy(history);
    var decoder: lz4.Decoder = undefined;
    try decoder.reset(history, .{});
    var read: usize = 0;
    var written: usize = 0;
    var restored: [5]u8 = undefined;
    while (true) {
        var input = [_]u8{if (read < wire.len) wire[read] else 0};
        const available: usize = @intFromBool(read < wire.len);
        var output: [1]u8 = undefined;
        const progress = try decoder.step(
            .{ .bytes = input[0..available], .final = read + available == wire.len },
            &output,
        );
        read += progress.consumed;
        @memcpy(restored[written..][0..progress.produced], output[0..progress.produced]);
        written += progress.produced;
        @memset(&input, 0xff);
        @memset(&output, 0xff);
        if (progress.status == .complete) break;
        try std.testing.expect(progress.consumed != 0 or progress.produced != 0);
    }
    try std.testing.expectEqual(wire.len, read);
    try std.testing.expectEqualStrings("hello", &restored);
    const complete = try decoder.step(.{ .bytes = &.{}, .final = true }, &.{});
    try std.testing.expectEqual(lz4.DecodeStatus.complete, complete.status);
    try std.testing.expectEqual(0, complete.produced);
    try decoder.reset(history, .{});
    try std.testing.expectError(
        error.Truncated,
        decoder.step(.{ .bytes = &.{}, .final = true }, &.{}),
    );
    try std.testing.expectError(
        error.NeedReset,
        decoder.step(.{ .bytes = &.{}, .final = true }, &.{}),
    );
}

test "LZ4 standard frames checksums concatenation and skippable boundaries" {
    const allocator = std.testing.allocator;
    const source = "a repeated phrase: a repeated phrase: a repeated phrase";
    const options: lz4.FrameEncodeOptions = .{
        .block_checksum = true,
        .content_size = source.len,
        .independent = false,
    };
    const workspace = try lz4.FrameEncoderWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    const storage = try allocator.alloc(u8, try lz4.frameEncodeBound(source.len, options));
    defer allocator.free(storage);
    const frame = try lz4.encodeFrame(source, storage, .{ .workspace = workspace }, options);
    try std.testing.expectEqualSlices(u8, &.{ 4, 0x22, 0x4d, 0x18 }, frame[0..4]);
    var skip_storage: [12]u8 = undefined;
    const skip = try lz4.encodeSkippableFrame("note", &skip_storage, 15);
    const sequence = try allocator.alloc(u8, skip.len + frame.len * 2);
    defer allocator.free(sequence);
    @memcpy(sequence[0..skip.len], skip);
    @memcpy(sequence[skip.len..][0..frame.len], frame);
    @memcpy(sequence[skip.len + frame.len ..], frame);
    const first = try lz4.decodeFrame(sequence, &.{}, .{});
    try std.testing.expectEqual(skip.len, first.consumed);
    try std.testing.expectEqual(0, first.produced);
    var output: [source.len * 2 + 7]u8 = @splat(0xa5);
    const complete = try lz4.decodeFrame(
        sequence,
        &output,
        .{ .frames = .concatenate, .trailing_data = .reject },
    );
    try std.testing.expectEqual(sequence.len, complete.consumed);
    try std.testing.expectEqual(3, complete.frames);
    try std.testing.expectEqual(1, complete.skippable_frames);
    try std.testing.expectEqualStrings(source, output[0..source.len]);
    try std.testing.expectEqualStrings(source, output[source.len..][0..source.len]);
    try std.testing.expect(std.mem.allEqual(u8, output[complete.produced..], 0xa5));
    frame[frame.len - 1] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, lz4.decodeFrame(frame, &output, .{}));
}
