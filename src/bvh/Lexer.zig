//! Bounded ASCII BVH token reader. The cursor tracks physical lines and byte offsets for parse
//! diagnostics; a cached lookahead token is returned once before scanning resumes. This reader
//! borrows its source and owns no storage. Strict numeric conversion stays in common/ascii_number.
const std = @import("std");
const ascii_number = @import("../common/ascii_number.zig");
const Lexer = @This();

/// Immutable bytes borrowed for the complete parse.
source: []const u8,
/// Input and hierarchy/frame ceilings selected by the caller; scanning uses line/token bounds.
limits: ParseLimits,
/// First byte not yet scanned, after an optional initial BOM.
cursor: usize = 0,
/// Location used to diagnose the most recent read or scan failure.
offset: usize = 0,
/// One-based physical line at the scan cursor.
line: usize = 1,
/// Start of the current line, used for the byte limit.
line_start: usize = 0,
/// Lookahead already scanned but not yet returned by next.
cached: ?Token = null,

pub fn init(source: []const u8, limits: ParseLimits) Lexer {
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
    if (self.cursor - start > self.limits.token_bytes or self.cursor - self.line_start > self.limits
        .line_bytes) return error.LimitExceeded;
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

/// Independent resource limits. Callers may raise capacities for larger trusted captures.
pub const ParseLimits = struct {
    /// Maximum complete input size in bytes.
    input_bytes: usize = 256 * 1024 * 1024,
    /// Maximum bytes per physical line.
    line_bytes: usize = 1024 * 1024,
    /// Maximum bytes per token.
    token_bytes: usize = 256,
    /// Maximum total nodes, including every root and end site.
    joints: u32 = 4096,
    /// Counts each root as depth one, including the additional level of an end site.
    depth: u32 = 128,
    /// Maximum recorded frame count, including frames with no channels.
    frames: u32 = 1_000_000,
    /// Maximum total scalar values across all frames.
    values: usize = 64 * 1024 * 1024,
};

/// Invalid syntax/numbers/channel identities, incomplete frames or resource admission failure.
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
pub const Diagnostic = struct {
    /// Zero-based byte offset of the failure, bounded by the input length.
    offset: usize,
    /// One-based physical line containing the failure.
    line: usize,
    /// Parse failure reported at this location; excludes allocator failure.
    reason: ParseError,
};

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

/// One token borrowing its bytes from the lexer's source.
pub const Token = struct {
    /// Token bytes without surrounding whitespace; braces are individual tokens.
    bytes: []const u8,
    /// Zero-based byte offset into the complete input.
    offset: usize,
    /// One-based physical line containing the token.
    line: usize,
};

pub const decimal = ascii_number.decimal;
pub const integer = ascii_number.integer;
