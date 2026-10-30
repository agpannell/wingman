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

pub const decimal = @import("../common/ascii_number.zig").decimal;
pub const integer = @import("../common/ascii_number.zig").integer;
