//! RFC 1950 encoding and resumable framing.

const std = @import("std");
const adler32 = @import("../adler32.zig");
const deflate = @import("../deflate.zig");
const overlaps = @import("../common/byte_ranges.zig").overlaps;
const decoding = @import("decode.zig");
const DecoderWorkspace = deflate.DecoderWorkspace;
const decode = decoding.decode;

pub const EncoderWorkspace = deflate.EncoderWorkspace;
pub const EncodeProfile = deflate.EncodeProfile;
pub const EncodeAction = deflate.EncodeAction;
pub const EncodeStatus = deflate.EncodeStatus;
pub const EncodeProgress = deflate.EncodeProgress;
pub const EncodeStats = deflate.EncodeStats;
pub const EncodeError = deflate.EncodeError;

/// RFC 1950 encoding. Dictionary backing is needed only during reset/encode; DICTID hashes the
/// entire dictionary while history copies its window suffix.
pub const EncodeOptions = struct {
    /// Native raw encoder effort, window and cumulative limits. Select the dictionary in this
    /// wrapper's dictionary field; a nested raw dictionary is InvalidOptions. Output limits include
    /// the header, optional DICTID and Adler trailer.
    deflate: deflate.EncodeOptions = .{},
    /// Null omits FDICT; even an empty attached dictionary has an identity.
    dictionary: ?[]const u8 = null,
};

/// Sufficient capacity for one complete stream. A non-null options.dictionary adds the four-byte
/// dictionary ID; its contents do not affect the bound.
pub fn encodeBound(source_bytes: usize, options: EncodeOptions) EncodeError!usize {
    return std.math.add(
        usize,
        try deflate.encodeBound(source_bytes),
        if (options.dictionary != null) 10 else 6,
    ) catch error.CounterOverflow;
}

/// Encodes a complete zlib stream without allocation. Returns the borrowed output prefix; source,
/// dictionary, output and scratch must be disjoint. Failure may change output and does not publish
/// a partial result.
pub fn encode(
    source: []const u8,
    output: []u8,
    workspace: *EncoderWorkspace,
    options: EncodeOptions,
) EncodeError![]u8 {
    if (overlaps(source, output)) return error.StorageOverlap;
    if (overlaps(source, std.mem.asBytes(workspace))) return error.StorageOverlap;
    if (overlaps(output, std.mem.asBytes(workspace))) return error.StorageOverlap;
    if (options.dictionary) |dictionary| {
        if (overlaps(dictionary, output)) return error.StorageOverlap;
    }
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, options);
    const progress = try encoder.step(source, output, .finish);
    if (progress.status != .complete) return error.OutputTooSmall;
    return output[0..progress.produced];
}

/// Resumable zlib encoder over the raw codec. All fragment and dictionary bytes retire on return.
/// Borrowed scratch is exclusive until reset/end of use; no allocator is retained. Errors poison
/// the owner until reset.
pub const Encoder = struct {
    raw: deflate.Encoder,
    checksum: adler32.Hasher,
    header: [6]u8,
    header_bytes: usize,
    position: usize,
    trailer: [4]u8,
    phase: enum { header, body, trailer, complete },

    framing_bytes: u64,
    failed: bool,

    /// Starts a new stream at the owner's final address, copying dictionary history and hashing its
    /// full identity. No output is published here.
    pub fn reset(
        self: *Encoder,
        workspace: *EncoderWorkspace,
        options: EncodeOptions,
    ) EncodeError!void {
        if (options.deflate.dictionary != null) return error.InvalidOptions;
        if (overlaps(
            std.mem.asBytes(self),
            std.mem.asBytes(workspace),
        )) return error.StorageOverlap;
        if (options.dictionary) |dictionary| {
            if (overlaps(dictionary, std.mem.asBytes(self))) return error.StorageOverlap;
            if (overlaps(dictionary, std.mem.asBytes(workspace))) return error.StorageOverlap;
        }
        const framing: u64 = if (options.dictionary != null) 10 else 6;
        if (options.deflate.limits.output_bytes < framing) return error.LimitExceeded;
        var raw_options = options.deflate;
        raw_options.limits.output_bytes -= framing;
        try self.raw.reset(workspace, raw_options);
        self.checksum = .init;
        self.header_bytes = @intCast(framing - 4);
        self.position = 0;
        self.phase = .header;
        self.framing_bytes = 0;
        self.failed = false;
        const cinfo: u8 = @intCast(std.math.log2_int(usize, options.deflate.window_bytes) - 8);
        self.header[0] = cinfo << 4 | 8;
        const level: u8 = switch (options.deflate.profile) {
            .stored, .huffman => 0,
            .greedy => 1,
            .lazy => 2,
            .offline => 3,
        };
        const dictionary_flag: u8 = if (options.dictionary != null) 32 else 0;
        self.header[1] = level << 6 | dictionary_flag;
        const check = std.mem.readInt(u16, self.header[0..2], .big) % 31;
        self.header[1] += @intCast((31 - @as(u16, check)) % 31);
        if (options.dictionary) |dictionary| {
            std.mem.writeInt(u32, self.header[2..6], adler32.hash(dictionary), .big);
            try self.raw.setDictionary(dictionary);
        }
    }

    /// Copied cumulative counts; output includes returned framing bytes.
    pub fn counts(self: *const Encoder) EncodeStats {
        var stats = self.raw.counts();
        stats.output_bytes += self.framing_bytes;
        return stats;
    }

    /// Uses the raw encoder's process/flush/finish protocol. Adler-32 covers accepted source once,
    /// across all suspensions and synchronization points.
    pub fn step(
        self: *Encoder,
        input: []const u8,
        output: []u8,
        action: EncodeAction,
    ) EncodeError!EncodeProgress {
        if (self.failed) return error.NeedReset;
        return self.advance(input, output, action) catch |err| {
            self.failed = true;
            return err;
        };
    }

    fn advance(
        self: *Encoder,
        input: []const u8,
        output: []u8,
        action: EncodeAction,
    ) EncodeError!EncodeProgress {
        if (overlaps(input, output)) return error.StorageOverlap;
        inline for (.{ std.mem.asBytes(self), std.mem.asBytes(self.raw.workspace) }) |reservation| {
            if (overlaps(input, reservation)) return error.StorageOverlap;
            if (overlaps(output, reservation)) return error.StorageOverlap;
        }
        var written: usize = 0;
        var read: usize = 0;
        while (true) switch (self.phase) {
            .header, .trailer => {
                const bytes: []const u8 = blk: {
                    if (self.phase == .header) break :blk self.header[0..self.header_bytes];
                    break :blk &self.trailer;
                };
                const amount = @min(bytes.len - self.position, output.len - written);
                @memcpy(output[written..][0..amount], bytes[self.position..][0..amount]);
                self.position += amount;
                written += amount;
                self.framing_bytes += amount;
                if (self.position < bytes.len) return .{
                    .consumed = read,
                    .produced = written,
                    .status = .need_output,
                };
                self.position = 0;
                self.phase = if (self.phase == .header) .body else .complete;
            },
            .body => {
                const progress = try self.raw.step(input, output[written..], action);
                self.checksum.update(input[0..progress.consumed]);
                read = progress.consumed;
                written += progress.produced;
                if (progress.status != .complete) return .{
                    .consumed = read,
                    .produced = written,
                    .status = progress.status,
                };
                std.mem.writeInt(u32, &self.trailer, self.checksum.final(), .big);
                self.phase = .trailer;
            },
            .complete => {
                if (read != input.len or action != .finish) return error.InvalidState;
                return .{ .consumed = read, .produced = written, .status = .complete };
            },
        };
    }
};

test "zlib encoding owns dictionary IDs checksums and retired fragments" {
    const allocator = std.testing.allocator;
    const encode_workspace = try EncoderWorkspace.create(allocator);
    defer encode_workspace.destroy(allocator);
    const decode_workspace = try DecoderWorkspace.create(allocator);
    defer decode_workspace.destroy(allocator);
    var history: [32768]u8 = undefined;
    const source = "shared dictionary words shared dictionary words and a tail";
    const dictionary = "prefix shared dictionary words ";
    var wire: [512]u8 = undefined;
    var output: [source.len]u8 = undefined;
    const encoded = try encode(source, &wire, encode_workspace, .{ .dictionary = dictionary });
    try std.testing.expectEqual(
        adler32.hash(dictionary),
        std.mem.readInt(u32, encoded[2..6], .big),
    );
    const recovered = try decode(
        encoded,
        &output,
        .{ .workspace = decode_workspace, .history = &history },
        .{ .dictionary = dictionary },
    );
    try std.testing.expectEqual(encoded.len, recovered.consumed);
    try std.testing.expectEqualStrings(source, &output);
    var encoder: Encoder = undefined;
    try encoder.reset(encode_workspace, .{ .dictionary = dictionary });
    var read: usize = 0;
    var written: usize = 0;
    while (true) {
        var fragment: [1]u8 = undefined;
        const length: usize = @intFromBool(read < source.len);
        if (length != 0) fragment[0] = source[read];
        var result: [1]u8 = undefined;
        const progress = try encoder.step(
            fragment[0..length],
            &result,
            if (read + length == source.len) .finish else .process,
        );
        read += progress.consumed;
        @memset(&fragment, 0xa5);
        @memcpy(wire[written..][0..progress.produced], result[0..progress.produced]);
        written += progress.produced;
        @memset(&result, 0xa5);
        if (progress.status == .complete) break;
    }
    _ = try decode(
        wire[0..written],
        &output,
        .{ .workspace = decode_workspace, .history = &history },
        .{ .dictionary = dictionary },
    );
    try std.testing.expectEqualStrings(source, &output);
    try std.testing.expectEqual(source.len, encoder.counts().input_bytes);
    try std.testing.expectEqual(written, encoder.counts().output_bytes);
}

test "zlib encoding refuses complete-buffer overlap before dictionary copying" {
    const encode_workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer encode_workspace.destroy(std.testing.allocator);
    @memset(encode_workspace.data[0..32], 0xa5);
    try std.testing.expectError(
        error.StorageOverlap,
        encode(
            "source",
            encode_workspace.data[0..32],
            encode_workspace,
            .{ .dictionary = "replacement dictionary" },
        ),
    );
    for (encode_workspace.data[0..32]) |byte| try std.testing.expectEqual(0xa5, byte);
}
