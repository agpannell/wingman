//! Complete public API calls from outside the library's test composition.
const std = @import("std");
const adler32 = @import("wingman").adler32;

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
