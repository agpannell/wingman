//! XXH3 stripe accumulation and merging for inputs longer than 240 bytes. Algorithm reference:
//! xxHash v0.8.4, designed by Yann Collet and contributors.

const std = @import("std");
const testing = std.testing;

const prime32_1: u64 = 0x9e3779b1;
const prime64_1: u64 = 0x9e3779b185ebca87;
const prime64_2: u64 = 0xc2b2ae3d27d4eb4f;
const prime64_3: u64 = 0x165667b19e3779f9;
const prime64_4: u64 = 0x85ebca77c2b2ae63;
const prime64_5: u64 = 0x27d4eb2f165667c5;
const avalanche_prime: u64 = 0x165667919e3779f9;

fn read64Le(bytes: []const u8, index: usize) u64 {
    return std.mem.readInt(u64, bytes[index..][0..8], .little);
}

// One accumulator owns all eight lanes for both digest widths. Its caller tracks the position in
// the secret, so one-shot and streaming operations use the same stripe rule.
pub const StripeAccumulator = struct {
    values: [8]u64 = .{
        0xc2b2ae3d, prime64_1, prime64_2, prime64_3, prime64_4, 0x85ebca77, prime64_5, prime32_1,
    },

    pub fn addStripe(self: *StripeAccumulator, stripe: *const [64]u8, secret: *const [64]u8) void {
        var input_words: [8]u64 = undefined;
        var secret_words: [8]u64 = undefined;
        inline for (0..8) |lane| {
            input_words[lane] = read64Le(stripe, lane * 8);
            secret_words[lane] = read64Le(secret, lane * 8);
        }
        // Adjacent lanes exchange their data contribution; keyed products remain in their own lane.
        const values: @Vector(8, u64) = input_words;
        const keys: @Vector(8, u64) = secret_words;
        const adjacent = @shuffle(
            u64,
            values,
            undefined,
            @Vector(8, i32){ 1, 0, 3, 2, 5, 4, 7, 6 },
        );
        const keyed = values ^ keys;
        const mask: @Vector(8, u64) = @splat(0xffffffff);
        const shift: @Vector(8, u6) = @splat(32);
        const products = (keyed & mask) *% (keyed >> shift);
        const previous: @Vector(8, u64) = self.values;
        self.values = previous +% adjacent +% products;
    }

    pub fn scrambleBlock(self: *StripeAccumulator, secret: *const [64]u8) void {
        inline for (0..8) |lane| {
            const mixed = self.values[lane] ^ (self.values[lane] >> 47) ^ read64Le(
                secret,
                lane * 8,
            );
            self.values[lane] = mixed *% prime32_1;
        }
    }

    pub fn finish(self: StripeAccumulator, secret: *const [64]u8, initial: u64) u64 {
        var sum = initial;
        inline for (0..4) |pair| {
            const first = self.values[2 * pair] ^ read64Le(secret, 16 * pair);
            const second = self.values[2 * pair + 1] ^ read64Le(secret, 16 * pair + 8);
            const product: u128 = @as(u128, first) * second;
            const low: u64 = @truncate(product);
            const high: u64 = @truncate(product >> 64);
            sum +%= low ^ high;
        }
        const mixed = (sum ^ (sum >> 37)) *% avalanche_prime;
        return mixed ^ (mixed >> 32);
    }
};

test "stripe lanes mix neighbors and scrambleBlock independently" {
    var input: [64]u8 = undefined;
    var secret: [64]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index * 3 + 1);
    for (&secret, 0..) |*byte, index| byte.* = @truncate(index * 11 + 5);
    var lanes: StripeAccumulator = .{};
    lanes.addStripe(&input, &secret);
    const mixed = [8]u64{
        0x39f11e4cb0272b46, 0xe433b6111e02dc38, 0x60a87967149f0908, 0x5e951f86d4a9aada,
        0xca01342336998ecc, 0xa666a8efa98e6188, 0x6b7661c84f6ae5de, 0xa7990e1127190ff2,
    };
    try testing.expectEqual(mixed, lanes.values);
    lanes.scrambleBlock(&secret);
    const scrambled = [8]u64{
        0x7aefb09e56995051, 0x3ba015a3b8d0af62, 0x7da6b196453d30dd, 0xc33736af105ea2ed,
        0xb88775d93f64933b, 0x9596a9c7e8353878, 0x9fd5ad29c76cacf7, 0x0570bdfb9546f49d,
    };
    try testing.expectEqual(scrambled, lanes.values);
}

const HashWords = struct { low: u64, high: u64 };

// Reserving the final stripe is essential even when the input ends at a block boundary.
pub fn hash(comptime result_bits: u8, input: []const u8, secret: []const u8) HashWords {
    if (result_bits != 64 and result_bits != 128) @compileError(
        "XXH3 result width must be 64 or 128",
    );
    std.debug.assert(input.len > 240 and secret.len >= 136);
    var lanes: StripeAccumulator = .{};
    const stripes_per_block = (secret.len - 64) / 8;
    const ordinary_stripes = (input.len - 1) / 64;
    var remaining = ordinary_stripes;
    var offset: usize = 0;
    while (remaining >= stripes_per_block) {
        for (0..stripes_per_block) |stripe| {
            lanes.addStripe(input[offset..][0..64], secret[stripe * 8 ..][0..64]);
            offset += 64;
        }
        lanes.scrambleBlock(secret[secret.len - 64 ..][0..64]);
        remaining -= stripes_per_block;
    }
    for (0..remaining) |stripe| {
        lanes.addStripe(input[offset..][0..64], secret[stripe * 8 ..][0..64]);
        offset += 64;
    }
    lanes.addStripe(input[input.len - 64 ..][0..64], secret[secret.len - 71 ..][0..64]);
    const length: u64 = @intCast(input.len);
    const low = lanes.finish(secret[11..][0..64], length *% prime64_1);
    const high = if (result_bits == 128) lanes.finish(
        secret[secret.len - 75 ..][0..64],
        ~(length *% prime64_2),
    ) else 0;
    return .{ .low = low, .high = high };
}

test "long digest reserves the last stripe across buffer and secret blocks" {
    var input: [2049]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index * 53 + 7);
    var secret: [137]u8 = undefined;
    for (&secret, 0..) |*byte, index| byte.* = @truncate(index * 71 + 13);
    // Independently obtained from the xxHash v0.8.4 custom-secret API.
    const cases = [_]struct {
        length: usize,
        low: u64,
        high: u64,
    }{
        .{ .length = 241, .low = 0x5841ba9953e69424, .high = 0x5756cc20a9d588bc },
        .{ .length = 256, .low = 0xb9df17fb0358a462, .high = 0xe3917dc165c4117d },
        .{ .length = 257, .low = 0x9b3337c50a73b0d6, .high = 0x81bc53143755d337 },
        .{ .length = 575, .low = 0x7c50c9f790679e79, .high = 0x988b63cbff4e858a },
        .{ .length = 576, .low = 0x88ed2254452811cb, .high = 0xccc15d90f5e68d91 },
        .{ .length = 577, .low = 0x479c32ce574a98f9, .high = 0xbb0fe77a83e1e238 },
        .{ .length = 1024, .low = 0x590ee5bb3e743726, .high = 0xd6d9e92a94cf01ba },
        .{ .length = 1025, .low = 0xb69a3187d23ef0f4, .high = 0x797fc31a6d6ccc17 },
        .{ .length = 1151, .low = 0x19262b2870ef6a4e, .high = 0x406165f4593d1551 },
        .{ .length = 1152, .low = 0xc41989eaa239d162, .high = 0xdb27575b35e081a3 },
        .{ .length = 1153, .low = 0x1e8a266aef31cbdc, .high = 0xf32b50f1404677ba },
        .{ .length = 2049, .low = 0x2d82f9e4e0d17dc5, .high = 0x1ea4d1e1ac87f1d2 },
    };
    for (cases) |case| {
        const actual = hash(128, input[0..case.length], &secret);
        try testing.expectEqual(case.low, actual.low);
        try testing.expectEqual(case.high, actual.high);
    }
}
