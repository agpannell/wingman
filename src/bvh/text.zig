//! Bounded ASCII BVH tokens, finite decimal admission and byte/line diagnostics.
const std = @import("std");

/// Independent resource limits. Callers may raise capacities for larger trusted captures.
pub const Limits = struct {
    input_bytes: usize = 256 * 1024 * 1024,
    line_bytes: usize = 1024 * 1024,
    token_bytes: usize = 256,
    joints: u32 = 4096,
    /// Counts each root as depth one, including the additional level of an end site.
    depth: u32 = 128,
    frames: u32 = 1_000_000,
    values: usize = 64 * 1024 * 1024,
};

/// Invalid syntax/numbers/channel identities, incomplete samples or resource admission failure.
pub const ParseError = error{
    InvalidText,
    InvalidNumber,
    InvalidTiming,
    UnexpectedEnd,
    UnexpectedToken,
    UnsupportedChannel,
    DuplicateChannel,
    ChannelCount,
    InvalidHierarchy,
    LimitExceeded,
    AliasedStorage,
};

/// Byte offset and one-based line of failure. Success and allocation failure leave it unchanged.
/// The record must not overlap input bytes, even when parsing fails.
pub const Diagnostic = struct { offset: usize, line: usize, reason: ParseError };

pub fn report(
    source: []const u8,
    offset: usize,
    diagnostic: ?*Diagnostic,
    reason: ParseError,
) void {
    if (diagnostic) |out| {
        const end = @min(offset, source.len);
        out.* = .{
            .offset = end,
            .line = 1 + std.mem.count(u8, source[0..end], "\n"),
            .reason = reason,
        };
    }
}

pub const Token = struct { bytes: []const u8, offset: usize, line: usize };

pub const Lexer = struct {
    source: []const u8,
    limits: Limits,
    cursor: usize = 0,
    offset: usize = 0,
    line: usize = 1,
    line_start: usize = 0,
    cached: ?Token = null,

    pub fn init(source: []const u8, limits: Limits) Lexer {
        return .{
            .source = source,
            .limits = limits,
            .cursor = if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) 3 else 0,
        };
    }

    pub fn next(self: *Lexer) ParseError!?Token {
        if (self.cached) |token| {
            self.cached = null;
            self.offset = token.offset;
            return token;
        }
        while (self.cursor < self.source.len) {
            const byte = self.source[self.cursor];
            if (!std.ascii.isWhitespace(byte)) break;
            self.offset = self.cursor;
            if (byte == '\r') {
                if (self.cursor + 1 == self.source.len or self.source[self.cursor + 1] != '\n')
                    return error.InvalidText;
            } else if (byte == '\n') {
                self.line += 1;
                self.line_start = self.cursor + 1;
            } else if (self.cursor - self.line_start >= self.limits.line_bytes)
                return error.LimitExceeded;
            self.cursor += 1;
        }
        const start = self.cursor;
        self.offset = start;
        if (start == self.source.len) return null;
        if (self.source[start] == '{' or self.source[start] == '}') {
            self.cursor += 1;
        } else {
            while (self.cursor < self.source.len) : (self.cursor += 1) {
                const byte = self.source[self.cursor];
                if (std.ascii.isWhitespace(byte) or byte == '{' or byte == '}') break;
                if (byte < 33 or byte > 126) return error.InvalidText;
                if (self.cursor - start >= self.limits.token_bytes) return error.LimitExceeded;
            }
        }
        if (self.cursor - start > self.limits.token_bytes or self.cursor - self.line_start > self
            .limits.line_bytes) return error.LimitExceeded;
        return .{ .bytes = self.source[start..self.cursor], .offset = start, .line = self.line };
    }

    pub fn peek(self: *Lexer) ParseError!?Token {
        if (self.cached == null) self.cached = try self.next();
        return self.cached;
    }

    pub fn take(self: *Lexer) ParseError!Token {
        return try self.next() orelse error.UnexpectedEnd;
    }

    pub fn expect(self: *Lexer, word: []const u8) ParseError!void {
        if (!std.mem.eql(u8, (try self.take()).bytes, word)) return error.UnexpectedToken;
    }

    pub fn number(self: *Lexer) ParseError!f64 {
        return decimal((try self.take()).bytes);
    }

    pub fn vector(self: *Lexer) ParseError![3]f64 {
        return .{ try self.number(), try self.number(), try self.number() };
    }
};

const NumberError = error{InvalidNumber};

/// Parses a signed decimal with optional fraction/exponent into finite binary64. Underflow rounds
/// normally, including signed zero; overflow and malformed or unsupported spellings fail.
pub fn decimal(bytes: []const u8) NumberError!f64 {
    if (shortDecimal(bytes)) |value| return value;
    // The standard parser validates the complete decimal grammar. Exclude its Zig-literal
    // extensions here instead of scanning every decimal digit a second time.
    if (std.mem.indexOfScalar(u8, bytes, '_') != null) return error.InvalidNumber;
    const start: usize = if (bytes.len != 0 and (bytes[0] == '+' or bytes[0] == '-')) 1 else 0;
    if (bytes.len - start >= 2 and bytes[start] == '0') {
        const prefix = bytes[start + 1];
        if (prefix == 'x' or prefix == 'X') return error.InvalidNumber;
    }
    const value = std.fmt.parseFloat(f64, bytes) catch return error.InvalidNumber;
    if (!std.math.isFinite(value)) return error.InvalidNumber;
    return value;
}

fn shortDecimal(bytes: []const u8) ?f64 {
    // Fifteen decimal digits fit exactly in binary64, as do powers of ten through 10^15. A single
    // division therefore rounds the exact decimal, with no intermediate rounding. This is the
    // exact-operands condition used by Zig 0.17's MIT-licensed
    // std/fmt/parse_float/convert_fast.zig, restricted to non-exponent short spellings.
    if (bytes.len == 0 or bytes.len > 17) return null;
    const negative = bytes[0] == '-';
    const start: usize = if (negative or bytes[0] == '+') 1 else 0;
    var integer_significand: u64 = 0;
    var digits: usize = 0;
    var fractional_digits: usize = 0;
    var point = false;
    for (bytes[start..]) |byte| {
        if (byte == '.' and !point) {
            point = true;
        } else if (std.ascii.isDigit(byte)) {
            if (digits == 15) return null;
            integer_significand = integer_significand * 10 + (byte - '0');
            digits += 1;
            if (point) fractional_digits += 1;
        } else return null;
    }
    if (digits == 0) return null;
    const powers = [_]f64{
        1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15,
    };
    const significand: f64 = @floatFromInt(integer_significand);
    const divisor = powers[fractional_digits];
    const value = significand / divisor;
    return if (negative) -value else value;
}

/// Parses only decimal digits into a representable u32, including zero and leading zeroes.
pub fn integer(bytes: []const u8) NumberError!u32 {
    if (bytes.len == 0) return error.InvalidNumber;
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidNumber;
    return std.fmt.parseInt(u32, bytes, 10) catch error.InvalidNumber;
}

test "strict decimal rejects literal extensions, malformed text and nonfinite values" {
    for ([_][]const u8{
        "",          "+",    "-",     ".",      ".e1",     "e1",   "1e",    "1e+",      "1e-",
        "++1",       "--1",  "+-1",   "1.2.3",  "1e2e3",   "1p2",  "0x1p1", "+0X.8P+2", "-0x1.8p-2",
        "0b10",      "0o7",  "1_2",   "0_0.1",  "1.0e1_0", "1e_2", "1__2",  "NaN",      "inf",
        "+infinity", "-INF", "1e309", "-1e309", " 1",      "1 ",   "\t1",   "1\x00",    "1,0",
    }) |text| try std.testing.expectError(error.InvalidNumber, decimal(text));
}

test "strict decimal preserves binary64 boundaries and signed underflow" {
    const Case = struct { text: []const u8, bits: u64 };
    for (
        [_]Case{
            .{ .text = ".5e+1", .bits = 0x4014000000000000 },
            .{ .text = "-.125", .bits = 0xbfc0000000000000 },
            .{ .text = "+1.", .bits = 0x3ff0000000000000 },
            .{ .text = "0.1", .bits = 0x3fb999999999999a },
            .{ .text = "-0.000", .bits = 0x8000000000000000 },
            .{ .text = "1.7976931348623157e308", .bits = 0x7fefffffffffffff },
            .{ .text = "2.2250738585072014e-308", .bits = 0x0010000000000000 },
            .{ .text = "4.9406564584124654e-324", .bits = 1 },
            .{ .text = "-1e-9999", .bits = 0x8000000000000000 },
        },
    ) |case| try std.testing.expectEqual(case.bits, @as(u64, @bitCast(try decimal(case.text))));
}

test "short decimals agree bit for bit with independent standard conversion" {
    const testing = std.testing;
    var buffer: [64]u8 = undefined;
    var random_state = std.Random.DefaultPrng.init(0xa5c119);
    const random = random_state.random();
    for (0..4096) |index| {
        const text = try std.fmt.bufPrint(
            &buffer,
            "{s}{d}.{d:0>9}",
            .{
                if (index % 2 == 0) "-" else "+",
                random.intRangeLessThan(u32, 0, 1_000_000),
                random.intRangeLessThan(u32, 0, 1_000_000_000),
            },
        );
        try testing.expectEqual(
            @as(u64, @bitCast(try std.fmt.parseFloat(f64, text))),
            @as(u64, @bitCast(try decimal(text))),
        );
    }
    for ([_][]const u8{
        "0",                 "-0",                   "+1.",               ".1",
        "-.123456789012345", "999999999999999.",     "0.000000000000001", "9007199254740992",
        "9007199254740993",  "1.234567890123456789",
    }) |text| {
        try testing.expectEqual(
            @as(u64, @bitCast(try std.fmt.parseFloat(f64, text))),
            @as(u64, @bitCast(try decimal(text))),
        );
    }
}
