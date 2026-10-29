//! Complete public API calls from outside the library's test composition.
const std = @import("std");
const adler32 = @import("wingman").adler32;
const crc32 = @import("wingman").crc32;
const xxhash32 = @import("wingman").xxhash32;
const xxhash64 = @import("wingman").xxhash64;
const riff = @import("wingman").riff;

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

test "one-shot streaming and byte order" {
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

test "retired inputs independent states and checksum combination" {
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
