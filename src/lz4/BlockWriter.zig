//! Bounded raw LZ4 sequence emission. The caller reserves the complete block encoding bound; exact
//! and specialized literal writes preserve their documented copy margins.

const BlockWriter = @This();
/// Borrowed output reservation admitted by the complete block encoding bound.
bytes: []u8,
/// Length of the initialized wire prefix, in bytes.
cursor: usize = 0,

fn byte(self: *BlockWriter, value: u8) void {
    self.bytes[self.cursor] = value;
    self.cursor += 1;
}

fn extension(self: *BlockWriter, value: usize) void {
    var remaining = value;
    while (remaining >= 255) : (remaining -= 255) self.byte(255);
    self.byte(@intCast(remaining));
}

fn literal(self: *BlockWriter, bytes: []const u8) void {
    @memcpy(self.bytes[self.cursor..][0..bytes.len], bytes);
    self.cursor += bytes.len;
}

pub fn sequence(self: *BlockWriter, literals: []const u8, distance: u16, match: usize) void {
    self.writeSequence(false, literals, literals.len, distance, match);
}

pub fn sequenceWild(
    self: *BlockWriter,
    source: []const u8,
    literal_count: usize,
    distance: u16,
    match: usize,
) void {
    // Search leaves twelve input bytes. Even a zero-literal match is followed by its offset and a
    // final token with five literals, so later writes replace the speculative suffix.
    self.writeSequence(true, source, literal_count, distance, match);
}

pub fn sequenceNoLiterals(self: *BlockWriter, distance: u16, match: usize) void {
    const field = match - 4;
    self.byte(@intCast(@min(field, 15)));
    self.byte(@truncate(distance));
    self.byte(@intCast(distance >> 8));
    if (field >= 15) self.extension(field - 15);
}

fn writeSequence(
    self: *BlockWriter,
    comptime wild: bool,
    source: []const u8,
    literal_count: usize,
    distance: u16,
    match: usize,
) void {
    const field = match - 4;
    const literal_bits: u8 = @as(u8, @intCast(@min(literal_count, 15))) << 4;
    const match_bits: u8 = @intCast(@min(field, 15));
    self.byte(literal_bits | match_bits);
    if (literal_count >= 15) self.extension(literal_count - 15);
    if (wild) {
        var copied: usize = 0;
        while (true) : (copied += 8) {
            @memcpy(self.bytes[self.cursor + copied ..][0..8], source[copied..][0..8]);
            if (copied + 8 >= literal_count) break;
        }
        self.cursor += literal_count;
    } else self.literal(source[0..literal_count]);
    self.byte(@truncate(distance));
    self.byte(@intCast(distance >> 8));
    if (field >= 15) self.extension(field - 15);
}

pub fn final(self: *BlockWriter, literals: []const u8) void {
    self.byte(@as(u8, @intCast(@min(literals.len, 15))) << 4);
    if (literals.len >= 15) self.extension(literals.len - 15);
    self.literal(literals);
}
