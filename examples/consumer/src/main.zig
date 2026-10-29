//! Complete public API calls from outside the library's test composition.
const std = @import("std");
const adler32 = @import("wingman").adler32;
const crc32 = @import("wingman").crc32;

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
