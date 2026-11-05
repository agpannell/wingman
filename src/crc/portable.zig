//! Table-driven named CRCs. Parameters use the normal polynomial without its leading bit.
const std = @import("std");
const castagnoli = @import("castagnoli.zig");
const folded64 = @import("folded64.zig");

pub fn Algorithm(comptime Word: type, comptime polynomial: Word, comptime reflected: bool) type {
    return struct {
        const Self = @This();
        const bits = @bitSizeOf(Word);
        const mask = std.math.maxInt(Word);
        const recurrence = if (reflected) @bitReverse(polynomial) else polynomial;

        /// Unfinalized remainder. Initialize with `init` or copy a valid state.
        remainder: Word,

        /// Starts an empty stream. This value owns no input or allocator.
        pub fn init() Self {
            return .{ .remainder = mask };
        }

        fn byteStep(remainder: Word, byte: u8) Word {
            if (reflected) {
                const index: u8 = @truncate(remainder ^ byte);
                return (remainder >> 8) ^ tables[0][index];
            }
            const index: u8 = @truncate((remainder >> (bits - 8)) ^ byte);
            return (remainder << 8) ^ tables[0][index];
        }

        const tables = blk: {
            @setEvalBranchQuota(100000);
            var result: [8][256]Word = undefined;
            for (0..256) |value| {
                var remainder: Word = @intCast(value);
                if (!reflected) remainder <<= bits - 8;
                for (0..8) |_| {
                    const carry = if (reflected) remainder & 1 != 0 else remainder >> (bits - 1) !=
                        0;
                    remainder = if (reflected) remainder >> 1 else remainder << 1;
                    if (carry) remainder ^= recurrence;
                }
                result[0][value] = remainder;
            }
            for (1..8) |distance| {
                for (0..256) |value| {
                    const previous = result[distance - 1][value];
                    const index: u8 = if (reflected) @truncate(
                        previous,
                    ) else @truncate(previous >> (bits - 8));
                    const shifted = if (reflected) previous >> 8 else previous << 8;
                    result[distance][value] = shifted ^ result[0][index];
                }
            }
            break :blk result;
        };

        /// Appends exact bytes without retaining input. Empty and unaligned slices are accepted.
        pub fn update(self: *Self, bytes: []const u8) void {
            if (Word == u32 and polynomial == 0x1edc6f41 and reflected and castagnoli.available) {
                self.remainder = castagnoli.update(self.remainder, bytes);
                return;
            }
            if (Word == u64 and polynomial == 0x42f0e1eba9ea3693 and reflected and folded64
                .available and bytes.len >= 16)
            {
                self.remainder = folded64.update(self.remainder, bytes);
                return;
            }
            var remainder = self.remainder;
            var offset: usize = 0;
            while (bytes.len - offset >= 8) : (offset += 8) {
                var combined: Word = 0;
                // Each byte's table advances its contribution past the following bytes. The
                // incoming remainder affects only the first word-width bytes of this block.
                inline for (0..8) |position| {
                    var index = bytes[offset + position];
                    if (position < bits / 8) {
                        const shift = if (reflected) position * 8 else bits - 8 - position * 8;
                        index ^= @truncate(remainder >> shift);
                    }
                    combined ^= tables[7 - position][index];
                }
                remainder = combined;
            }
            for (bytes[offset..]) |byte| remainder = byteStep(remainder, byte);
            self.remainder = remainder;
        }

        // Internal short path for the CRC-64/XZ wrapper. Keep the ordinary update path unchanged.
        pub fn updatePortableShort(self: *Self, bytes: []const u8) void {
            var remainder = self.remainder;
            var offset: usize = 0;
            while (bytes.len - offset >= 8) : (offset += 8) {
                var combined: Word = 0;
                inline for (0..8) |position| {
                    var index = bytes[offset + position];
                    if (position < bits / 8) {
                        const shift = if (reflected) position * 8 else bits - 8 - position * 8;
                        index ^= @truncate(remainder >> shift);
                    }
                    combined ^= tables[7 - position][index];
                }
                remainder = combined;
            }
            for (bytes[offset..]) |byte| remainder = byteStep(remainder, byte);
            self.remainder = remainder;
        }

        test update {
            var state = init();
            state.update("first");
            const snapshot = state.final();
            var copy = state;
            state.update(" second");
            copy.update(" alternate");
            try std.testing.expectEqual(hash("first"), snapshot);
            try std.testing.expectEqual(hash("first second"), state.final());
            try std.testing.expectEqual(hash("first alternate"), copy.final());
        }

        /// Returns the finalized numeric checksum without changing this stream.
        pub fn final(self: Self) Word {
            return self.remainder ^ mask;
        }

        /// Checksums a complete exact byte slice without allocation or retained input.
        pub fn hash(bytes: []const u8) Word {
            var state = init();
            state.update(bytes);
            return state.final();
        }

        // Combination works in normal polynomial orientation, independent of the table direction.
        // Both initial and final XOR are all ones for these named algorithms, so their affine
        // offsets cancel: advance(first, length) XOR second combines finalized checksums.
        fn multiply(left: Word, right: Word) Word {
            var factor = left;
            var terms = right;
            var product: Word = 0;
            while (terms != 0) : (terms >>= 1) {
                if (terms & 1 != 0) product ^= factor;
                const carry = factor >> (bits - 1) != 0;
                factor <<= 1;
                if (carry) factor ^= polynomial;
            }
            return product;
        }

        /// Immutable word-sized advance operator for a fixed second sequence length.
        pub const CombineOperator = struct {
            factor: Word,

            /// Precomputes advancement for the full u64 byte-length range.
            pub fn forLength(second_length: u64) CombineOperator {
                var power: Word = 1;
                for (0..8) |_| {
                    const carry = power >> (bits - 1) != 0;
                    power <<= 1;
                    if (carry) power ^= polynomial;
                }
                var length = second_length;
                var factor: Word = 1;
                while (length != 0) : (length >>= 1) {
                    if (length & 1 != 0) factor = multiply(factor, power);
                    power = multiply(power, power);
                }
                return .{ .factor = factor };
            }

            /// Combines finalized checksums. The second checksum must have the selected length.
            pub fn apply(self: CombineOperator, first: Word, second: Word) Word {
                const normal = if (reflected) @bitReverse(first) else first;
                const advanced = multiply(normal, self.factor);
                return (if (reflected) @bitReverse(advanced) else advanced) ^ second;
            }
        };

        /// Returns the checksum of concatenated sequences without reading their original bytes.
        pub fn combine(first: Word, second: Word, second_length: u64) Word {
            return CombineOperator.forLength(second_length).apply(first, second);
        }
    };
}

test "named portable CRCs agree with independent standard implementations and splits" {
    inline for (.{ .{
        u16, 0x1021, false, std.hash.crc.@"CRC-16/GENIBUS",
    }, .{
        u32, 0x1edc6f41, true, std.hash.crc.@"CRC-32/ISCSI",
    }, .{
        u64, 0x42f0e1eba9ea3693, true, std.hash.crc.@"CRC-64/XZ",
    } }) |definition| {
        const Crc = Algorithm(definition[0], definition[1], definition[2]);
        const Reference = definition[3];
        var data: [1024]u8 = undefined;
        for (&data, 0..) |*byte, index| byte.* = @truncate(index * 73 + 19);
        for (0..data.len + 1) |length| {
            const input = data[0..length];
            try std.testing.expectEqual(Reference.hash(input), Crc.hash(input));
            for (0..@min(length + 1, 17)) |split| {
                var state = Crc.init();
                state.update(input[0..split]);
                const snapshot = state.final();
                state.update(input[split..]);
                try std.testing.expectEqual(Crc.hash(input), state.final());
                try std.testing.expectEqual(
                    state.final(),
                    Crc.combine(snapshot, Crc.hash(input[split..]), length - split),
                );
            }
        }
    }
}

fn oracleByte(
    comptime Word: type,
    comptime polynomial: Word,
    comptime reflected: bool,
    start: Word,
    byte: u8,
) Word {
    const bits = @bitSizeOf(Word);
    var remainder = start ^ (if (reflected) @as(Word, byte) else @as(Word, byte) << (bits - 8));
    for (0..8) |_| {
        if (reflected) {
            const carry = remainder & 1 != 0;
            remainder >>= 1;
            if (carry) remainder ^= @bitReverse(polynomial);
        } else {
            const carry = remainder >> (bits - 1) != 0;
            remainder <<= 1;
            if (carry) remainder ^= polynomial;
        }
    }
    return remainder;
}

fn matrixApply(comptime Word: type, columns: [@bitSizeOf(Word)]Word, input: Word) Word {
    var result: Word = 0;
    var bits = input;
    var index: usize = 0;
    while (bits != 0) : (index += 1) {
        if (bits & 1 != 0) result ^= columns[index];
        bits >>= 1;
    }
    return result;
}

test "portable CRC raw remainders alignments snapshots and full length combination" {
    inline for (.{ .{
        u16, 0x1021, false,
    }, .{
        u32, 0x1edc6f41, true,
    }, .{
        u64, 0x42f0e1eba9ea3693, true,
    } }) |definition| {
        const Word = definition[0];
        const polynomial = definition[1];
        const reflected = definition[2];
        const Crc = Algorithm(Word, polynomial, reflected);
        var data: [2048 + 64]u8 = undefined;
        for (&data, 0..) |*byte, index| byte.* = @truncate((index * 53 + 11) ^ (index >> 4));
        const mask = std.math.maxInt(Word);
        for (0..64) |offset| {
            for (0..141) |length_index| {
                const boundaries = [_]usize{
                    255, 256, 257, 767, 768, 769, 1023, 1024, 1025, 1535, 1536, 1537,
                };
                const length = if (length_index < 129) length_index else boundaries[
                    length_index -
                        129
                ];
                const input = data[offset..][0..length];
                var expected: Word = mask;
                for (
                    input,
                ) |byte| expected = oracleByte(Word, polynomial, reflected, expected, byte);
                try std.testing.expectEqual(expected ^ mask, Crc.hash(input));
                for (0..@bitSizeOf(Word)) |bit| {
                    const initial: Word = @as(Word, 1) << @intCast(bit);
                    var raw_expected = initial;
                    for (
                        input,
                    ) |byte| raw_expected = oracleByte(
                        Word,
                        polynomial,
                        reflected,
                        raw_expected,
                        byte,
                    );
                    var state: Crc = .{ .remainder = initial };
                    state.update(input);
                    try std.testing.expectEqual(raw_expected, state.remainder);
                }
            }
        }
        for (0..data.len + 1) |split| {
            var state = Crc.init();
            state.update(data[0..split]);
            const before = state.final();
            var copy = state;
            state.update("");
            try std.testing.expectEqual(before, state.final());
            state.update(data[split..]);
            copy.update("independent suffix");
            try std.testing.expectEqual(Crc.hash(&data), state.final());
            try std.testing.expectEqual(
                state.final(),
                Crc.combine(before, Crc.hash(data[split..]), data.len - split),
            );
            var reference = Crc.init();
            reference.update(data[0..split]);
            reference.update("independent suffix");
            try std.testing.expectEqual(reference.final(), copy.final());
        }
        // This oracle composes linear maps represented by basis columns. Production instead
        // multiplies scalar polynomial residues, so this independently checks every length bit.
        var powers: [64][@bitSizeOf(Word)]Word = undefined;
        for (0..@bitSizeOf(Word)) |bit| {
            const basis: Word = @as(Word, 1) << @intCast(bit);
            powers[0][bit] = oracleByte(Word, polynomial, reflected, basis, 0);
        }
        for (1..64) |distance| {
            for (
                0..@bitSizeOf(Word),
            ) |bit| powers[distance][bit] = matrixApply(
                Word,
                powers[distance - 1],
                powers[distance - 1][bit],
            );
        }
        for (0..65) |length_bit| {
            const length: u64 = if (length_bit == 64) std.math.maxInt(
                u64,
            ) else @as(u64, 1) << @intCast(length_bit);
            const operator = Crc.CombineOperator.forLength(length);
            for (0..@bitSizeOf(Word)) |bit| {
                const first: Word = @as(Word, 1) << @intCast(bit);
                const second = Crc.hash("second input");
                var expected = first;
                var remaining = length;
                var index: usize = 0;
                while (remaining != 0) : (index += 1) {
                    if (remaining & 1 != 0) expected = matrixApply(Word, powers[index], expected);
                    remaining >>= 1;
                }
                try std.testing.expectEqual(expected ^ second, operator.apply(first, second));
            }
        }
    }
}

test "named CRC reads stay inside both protected input boundaries" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const page = std.heap.pageSize();
    const mapping = try std.posix.mmap(
        null,
        4 * page,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(mapping);
    for ([_]usize{ 0, 3 * page }) |offset| {
        const result = std.os.linux.mprotect(mapping.ptr + offset, page, .{});
        try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(result));
    }
    const backing = mapping[page..][0 .. 2 * page];
    for (backing, 0..) |*value, index| value.* = @truncate(index *% 179 +% (index >> 3));
    inline for (.{ .{
        u16, 0x1021, false,
    }, .{
        u32, 0x1edc6f41, true,
    }, .{
        u64, 0x42f0e1eba9ea3693, true,
    } }) |definition| {
        const Word = definition[0];
        const Crc = Algorithm(Word, definition[1], definition[2]);
        for (0..2049) |length| {
            for ([_][]const u8{ backing[0..length], backing[backing.len - length ..] }) |input| {
                var remainder: Word = std.math.maxInt(Word);
                for (
                    input,
                ) |value| remainder = oracleByte(
                    Word,
                    definition[1],
                    definition[2],
                    remainder,
                    value,
                );
                const expected = remainder ^ std.math.maxInt(Word);
                try std.testing.expectEqual(expected, Crc.hash(input));
                for ([_]usize{ @min(7, length), @min(767, length) }) |split| {
                    var state = Crc.init();
                    state.update(input[0..split]);
                    state.update(input[split..]);
                    try std.testing.expectEqual(expected, state.final());
                }
            }
        }
    }
}

// Independently catalogued raw residues before final XOR, not universal wire byte encodings.
// https://reveng.sourceforge.io/crc-catalogue/16.htm#crc.cat.crc-16-genibus
// https://reveng.sourceforge.io/crc-catalogue/17plus.htm Each codeword appends the frozen published
// check in its conventional presentation order.
test "named CRC independent complete codewords and raw residues" {
    const Genibus = Algorithm(u16, 0x1021, false);
    const Iscsi = Algorithm(u32, 0x1edc6f41, true);
    const Xz = Algorithm(u64, 0x42f0e1eba9ea3693, true);
    var genibus = Genibus.init();
    genibus.update("123456789\xd6\x4e");
    try std.testing.expectEqual(@as(u16, 0x1d0f), genibus.remainder);
    var iscsi = Iscsi.init();
    iscsi.update("123456789\x83\x92\x06\xe3");
    try std.testing.expectEqual(@as(u32, 0xb798b438), iscsi.remainder);
    var xz = Xz.init();
    xz.update("123456789\xfa\x39\x19\xdf\xbb\xc9\x5d\x99");
    try std.testing.expectEqual(@as(u64, 0x49958c9abd7d353f), xz.remainder);
}
