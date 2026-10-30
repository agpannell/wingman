//! Bounded Acclaim tokens, decimal admission and diagnostics shared by the paired readers.
const std = @import("std");

/// Independent admission limits; callers may raise capacities for larger trusted captures.
pub const Limits = struct {
    input_bytes: usize = 128 * 1024 * 1024,
    line_bytes: usize = 65536,
    token_bytes: usize = 256,
    bones: u32 = 4096,
    depth: u32 = 128,
    frames: u32 = 1_000_000,
    values: usize = 64 * 1024 * 1024,
};

/// Syntax, unsupported semantics, identity/hierarchy failures or explicit admission limits.
pub const ParseError = error{
    InvalidText,
    InvalidNumber,
    UnexpectedEnd,
    UnexpectedToken,
    UnsupportedVersion,
    UnsupportedField,
    UnsupportedDirective,
    MissingField,
    DuplicateField,
    DuplicateBone,
    UnknownBone,
    InvalidHierarchy,
    CyclicHierarchy,
    InvalidFrame,
    MissingChannels,
    DuplicateChannels,
    ChannelCount,
    LimitExceeded,
    AliasedStorage,
};

/// Byte offset and one-based line of a parse failure. Success leaves this record unchanged.
/// Allocation failure need not provide a diagnostic. The record must not overlap immutable input.
pub const Diagnostic = struct { offset: usize, line: usize, reason: ParseError };

pub const Token = struct { text: []const u8, offset: usize, line_start: bool };

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

pub fn admit(source: []const u8, diagnostic: ?*Diagnostic, limits: Limits) ParseError!void {
    if (diagnostic) |out| {
        const source_address = @intFromPtr(source.ptr);
        const diagnostic_address = @intFromPtr(out);
        if (source.len != 0 and (if (source_address <= diagnostic_address) diagnostic_address -
            source_address < source.len else source_address - diagnostic_address < @sizeOf(
            Diagnostic,
        ))) {
            return error.AliasedStorage;
        }
    }
    if (source.len > limits.input_bytes) {
        report(source, 0, diagnostic, error.LimitExceeded);
        return error.LimitExceeded;
    }
    var start: usize = 0;
    for (source, 0..) |byte, index| {
        const invalid = byte == 0 or (byte == '\r' and missing_line_feed: {
            const next_index = index + 1;
            break :missing_line_feed next_index == source.len or source[next_index] != '\n';
        });
        const too_long = byte != '\n' and byte != '\r' and index - start >= limits.line_bytes;
        if (invalid or too_long) {
            const reason: ParseError = if (invalid) error.InvalidText else error.LimitExceeded;
            report(source, index, diagnostic, reason);
            return reason;
        }
        if (byte == '\n') start = index + 1;
    }
}

pub const Lexer = struct {
    source: []const u8,
    limit: usize,
    base: usize = 0,
    cursor: usize = 0,
    offset: usize = 0,
    at_line_start: bool = true,
    cached: ?Token = null,

    pub fn next(self: *Lexer) ParseError!?Token {
        if (self.cached) |token| {
            self.cached = null;
            self.offset = token.offset;
            return token;
        }
        while (self.cursor < self.source.len) {
            const byte = self.source[self.cursor];
            if (byte == '#') {
                while (self.cursor < self.source.len and self.source[self.cursor] != '\n') self
                    .cursor += 1;
            } else if (std.ascii.isWhitespace(byte)) {
                self.cursor += 1;
                if (byte == '\n') self.at_line_start = true;
            } else break;
        }
        const start = self.cursor;
        self.offset = self.base + start;
        if (start == self.source.len) return null;
        const first = self.at_line_start;
        self.at_line_start = false;
        if (self.source[start] == '(' or self.source[start] == ')') {
            self.cursor += 1;
        } else {
            while (self.cursor < self.source.len) : (self.cursor += 1) {
                const byte = self.source[self.cursor];
                if (std.ascii.isWhitespace(
                    byte,
                ) or byte == '#' or byte == '(' or byte == ')') break;
            }
        }
        if (self.cursor - start > self.limit) return error.LimitExceeded;
        return .{
            .text = self.source[start..self.cursor],
            .offset = self.offset,
            .line_start = first,
        };
    }

    pub fn peek(self: *Lexer) ParseError!?Token {
        if (self.cached == null) self.cached = try self.next();
        return self.cached;
    }

    pub fn take(self: *Lexer) ParseError!Token {
        return try self.next() orelse error.UnexpectedEnd;
    }

    pub fn expect(self: *Lexer, word: []const u8) ParseError!void {
        if (!std.mem.eql(u8, (try self.take()).text, word)) return error.UnexpectedToken;
    }

    pub fn number(self: *Lexer) ParseError!f64 {
        return decimal((try self.take()).text);
    }

    pub fn vector(self: *Lexer) ParseError![3]f64 {
        return .{ try self.number(), try self.number(), try self.number() };
    }
};

pub const decimal = @import("../common/ascii_number.zig").decimal;
pub const integer = @import("../common/ascii_number.zig").integer;

pub fn isIntegerToken(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    const start: usize = if (bytes[0] == '+' or bytes[0] == '-') 1 else 0;
    if (start == bytes.len) return false;
    for (bytes[start..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

pub fn identifier(bytes: []const u8) ParseError!void {
    if (bytes.len == 0 or std.ascii.isDigit(
        bytes[0],
    ) or isIntegerToken(bytes)) return error.InvalidText;
    for (bytes) |byte| {
        if (byte < 33 or byte > 126 or byte == ':' or byte == '(' or byte == ')' or byte == '#') {
            return error.InvalidText;
        }
    }
}

test "decimal grammar and input limits do not admit extensions or overlong lines" {
    const testing = std.testing;
    try testing.expectEqual(@as(f64, 0.125), try decimal("+.125e0"));
    try testing.expectEqual(@as(f64, -5), try decimal("-5."));
    for ([_][]const u8{ "nan", "inf", "0x1p0", "1_000", ".", "1e+", "1.2.3" }) |bytes| {
        try testing.expectError(error.InvalidNumber, decimal(bytes));
    }
    try admit("abc\r\n", null, .{ .line_bytes = 3 });
    try testing.expectError(error.LimitExceeded, admit("abcd", null, .{ .line_bytes = 3 }));
    try testing.expectError(error.InvalidText, admit("a\x00b", null, .{}));
    try testing.expectError(error.InvalidText, admit("a\rb", null, .{}));
    var bytes: [128]u8 align(@alignOf(Diagnostic)) = @splat(0xa5);
    const before = bytes;
    const diagnostic: *Diagnostic = @ptrCast(&bytes);
    try testing.expectError(error.AliasedStorage, admit(&bytes, diagnostic, .{}));
    try testing.expectEqualSlices(u8, &before, &bytes);
}
