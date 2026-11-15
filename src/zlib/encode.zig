//! Encode byte streams as zlib: a header describing the history window and optional dictionary, raw
//! DEFLATE blocks, then an Adler-32 checksum of the source. Complete calls return a prefix of
//! caller output; StreamEncoder retains framing/checksum state across fragments and flushes. Both
//! borrow caller-owned workspaces and allocate nothing. Options share DEFLATE's compression,
//! history and allowance policy. Zlib identifies the entire non-null dictionary, including an empty
//! one; raw matching copies only its reachable suffix. Output limits include the header, optional
//! dictionary ID and Adler-32 trailer.

const std = @import("std");
const adler32 = @import("../adler32.zig");
const deflate = @import("../deflate.zig");
const overlaps = @import("../common/byte_ranges.zig").overlaps;
const decoding = @import("decode.zig");
const DecoderWorkspace = deflate.decode.Workspace;
const decode = decoding.into;

const raw_encoding = deflate.encode;

pub const Workspace = raw_encoding.Workspace;
pub const Compression = raw_encoding.Compression;
pub const Limits = raw_encoding.Limits;
pub const Action = raw_encoding.Action;
pub const Status = raw_encoding.Status;
pub const Progress = raw_encoding.Progress;
pub const Stats = raw_encoding.Stats;
pub const Error = raw_encoding.Error;
pub const Options = raw_encoding.Options;

/// Sufficient capacity for one stream passed whole or through process calls followed by finish,
/// without explicit flush/full_flush boundaries. A non-null options.dictionary adds the four-byte
/// dictionary ID; its contents do not affect the bound. This capacity query does not validate
/// options.
pub fn bound(source_bytes: usize, options: Options) error{CounterOverflow}!usize {
    return std.math.add(
        usize,
        try raw_encoding.bound(source_bytes),
        if (options.dictionary != null) 10 else 6,
    ) catch error.CounterOverflow;
}

/// Encodes a complete zlib stream without allocation. Returns the borrowed output prefix. Output
/// and scratch must be disjoint from each other and from source/dictionary bytes; the two immutable
/// inputs may overlap. Failure may change output and does not publish a partial result.
pub fn into(source: []const u8, output: []u8, workspace: *Workspace, options: Options) Error![]u8 {
    if (overlaps(source, output)) return error.StorageOverlap;
    if (overlaps(source, std.mem.asBytes(workspace))) return error.StorageOverlap;
    if (overlaps(output, std.mem.asBytes(workspace))) return error.StorageOverlap;
    if (options.dictionary) |dictionary| {
        if (overlaps(dictionary, output)) return error.StorageOverlap;
    }
    var encoder: StreamEncoder = undefined;
    try encoder.reset(workspace, options);
    // A fresh owner has no failed operation or latched boundary. One finish cannot fail the
    // lifecycle protocol; complete calls expose only errors callers can encounter here.
    const progress = encoder.step(source, output, .finish) catch |err| switch (err) {
        error.InvalidState, error.NeedReset => unreachable,
        else => |failure| return failure,
    };
    if (progress.status != .complete) return error.OutputTooSmall;
    return output[0..progress.produced];
}

/// Bounded workspace-free stored encoding.
pub const short_stored = struct {
    pub const max_input_bytes = 75;
    /// Sufficient capacity for every admitted input; an individual call needs source.len + 11.
    pub const output_capacity = max_input_bytes + 11;
    pub const Error = error{ LimitExceeded, OutputTooSmall, StorageOverlap };

    /// Encodes one stored zlib stream with a 32 KiB window and no dictionary. Source and output
    /// must be disjoint. Requires `source.len + 11` destination bytes and returns a borrowed
    /// prefix. Length, capacity and overlap errors precede writes; oversized input returns
    /// LimitExceeded.
    pub fn into(source: []const u8, output: []u8) @This().Error![]u8 {
        if (source.len > max_input_bytes) return error.LimitExceeded;
        if (output.len < source.len + 11) return error.OutputTooSmall;
        if (overlaps(source, output)) return error.StorageOverlap;
        output[0] = 0x78;
        output[1] = 0x01;
        output[2] = 0x01;
        const length: u16 = @intCast(source.len);
        std.mem.writeInt(u16, output[3..5], length, .little);
        std.mem.writeInt(u16, output[5..7], ~length, .little);
        @memcpy(output[7..][0..source.len], source);
        std.mem.writeInt(u32, output[7 + source.len ..][0..4], adler32.hash(source), .big);
        return output[0 .. source.len + 11];
    }
    test "short stored buffer refusals preserve destination" {
        var source: [four_byte_runs.short.max_input_bytes + 1]u8 = @splat(42);
        var output: [four_byte_runs.short.output_capacity]u8 = @splat(0xa5);
        const before = output;
        try std.testing.expectError(
            error.LimitExceeded,
            short_stored.into(source[0 .. max_input_bytes + 1], &output),
        );
        try std.testing.expectError(
            error.OutputTooSmall,
            short_stored.into(source[0..16], output[0..26]),
        );
        try std.testing.expectError(
            error.StorageOverlap,
            short_stored.into(output[0..16], &output),
        );
        try std.testing.expectEqualSlices(u8, &before, &output);
    }
};

/// Resumable zlib encoding with format-owned checksums and framing. Fragment and dictionary bytes
/// retire on return. Scratch stays exclusively borrowed until reset/end of use; no allocator is
/// retained. Move between calls by retiring the old copy and preserving the exclusive workspace
/// borrow; no owner-relative pointer is retained. Errors poison the owner until reset.
pub const StreamEncoder = EncoderImpl(raw_encoding.StreamEncoder, Workspace, Options);

/// Stored/four-byte-run streaming with a smaller workspace, and a bounded workspace-free operation.
pub const four_byte_runs = struct {
    pub const Workspace = raw_encoding.four_byte_runs.Workspace;
    pub const Options = raw_encoding.four_byte_runs.Options;
    pub const StreamEncoder = EncoderImpl(
        raw_encoding.four_byte_runs.StreamEncoder,
        @This().Workspace,
        @This().Options,
    );

    pub const short = struct {
        pub const max_input_bytes = raw_encoding.four_byte_runs.short.max_input_bytes;
        /// Required output capacity, including temporary wide-write padding.
        pub const output_capacity = raw_encoding.four_byte_runs.short.output_capacity + 6;
        pub const Error = raw_encoding.four_byte_runs.short.Error;

        /// Encodes a complete four-byte-run stream with no dictionary or work limit. Source and
        /// output must be disjoint. Output needs output_capacity bytes; padding after the borrowed
        /// result may change. Length, capacity and overlap errors precede writes.
        pub fn into(source: []const u8, output: []u8) @This().Error![]u8 {
            if (source.len > max_input_bytes) return error.LimitExceeded;
            if (output.len < output_capacity) return error.OutputTooSmall;
            if (overlaps(source, output)) return error.StorageOverlap;
            output[0] = 0x78;
            output[1] = 0x01;
            const raw = try raw_encoding.four_byte_runs.short.into(
                source,
                output[2..][0..raw_encoding.four_byte_runs.short.output_capacity],
            );
            std.mem.writeInt(u32, output[2 + raw.len ..][0..4], adler32.hash(source), .big);
            return output[0 .. 2 + raw.len + 4];
        }
        test "public short stream buffer refusals preserve destination" {
            var source: [max_input_bytes + 1]u8 = @splat(42);
            var output: [output_capacity]u8 = @splat(0xa5);
            try std.testing.expectError(
                error.LimitExceeded,
                four_byte_runs.short.into(&source, &output),
            );
            try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
            try std.testing.expectError(
                error.OutputTooSmall,
                four_byte_runs.short.into(source[0..16], output[0 .. output.len - 1]),
            );
            try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
            const before = output;
            try std.testing.expectError(
                error.StorageOverlap,
                four_byte_runs.short.into(output[0..16], &output),
            );
            try std.testing.expectEqualSlices(u8, &before, &output);
        }
    };
};

test {
    _ = Options;
    _ = four_byte_runs.Options;
    _ = four_byte_runs.short;
    _ = short_stored;
}

test "producer input staging preserves streaming bytes checksums and refusals" {
    const Helper = struct {
        fn compare(
            staged: anytype,
            ordinary: anytype,
            input: []const u8,
            a: []u8,
            b: []u8,
            action: Action,
            prepared: bool,
        ) !?Progress {
            @memset(a, 0xa5);
            @memset(b, 0xa5);
            const first = if (prepared) blk: {
                @memcpy(staged.inputBuffer().?[0..input.len], input);
                break :blk staged.commitInput(input.len, a);
            } else staged.step(input, a, action);
            const second = ordinary.step(input, b, action);
            const progress = first catch |err| {
                try std.testing.expectError(err, second);
                try std.testing.expectEqualDeep(staged.counts(), ordinary.counts());
                try std.testing.expectEqualSlices(u8, a, b);
                try std.testing.expect(staged.inputBuffer() == null);
                try std.testing.expectError(error.NeedReset, staged.step(&.{}, &.{}, .finish));
                try std.testing.expectError(error.NeedReset, ordinary.step(&.{}, &.{}, .finish));
                return null;
            };
            try std.testing.expectEqualDeep(progress, try second);
            try std.testing.expectEqualDeep(staged.counts(), ordinary.counts());
            try std.testing.expectEqualSlices(u8, a, b);
            return progress;
        }

        fn run(staged: anytype, ordinary: anytype, source: []const u8, a: []u8, b: []u8) !void {
            var read: usize = 0;
            var written: usize = 0;
            var calls: usize = 0;
            const input_lengths = [_]usize{ 1, 4096, 31, 65535, 777 };
            const output_lengths = [_]usize{ 0, 1, 17, 4096 };
            for (
                [_]usize{ 777, 65535, source.len },
                [_]Action{ .flush, .full_flush, .finish },
            ) |end, action| {
                while (read < end) {
                    const available = staged.inputBuffer();
                    const length = @min(
                        end - read,
                        @min(
                            input_lengths[calls % input_lengths.len],
                            if (available) |buffer| buffer.len else end - read,
                        ),
                    );
                    const capacity = output_lengths[calls % output_lengths.len];
                    calls += 1;
                    const progress = try compare(
                        staged,
                        ordinary,
                        source[read..][0..length],
                        a[written..][0..capacity],
                        b[written..][0..capacity],
                        .process,
                        available != null,
                    ) orelse return;
                    read += progress.consumed;
                    written += progress.produced;
                }
                while (true) {
                    const capacity = output_lengths[calls % output_lengths.len];
                    calls += 1;
                    const progress = try compare(
                        staged,
                        ordinary,
                        &.{},
                        a[written..][0..capacity],
                        b[written..][0..capacity],
                        action,
                        false,
                    ) orelse return;
                    written += progress.produced;
                    if (progress.status == .flushed or progress.status == .complete) break;
                }
            }
            try std.testing.expectEqualSlices(u8, a[0..written], b[0..written]);
            try std.testing.expect(staged.inputBuffer() == null);
        }
    };
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 2 * 65535 + 259);
    defer allocator.free(data);
    var random: std.Random.DefaultPrng = .init(0xf1192a);
    random.random().bytes(data);
    for (4..data.len) |i| if (i % 113 < 98) {
        data[i] = data[i - 4];
    };
    const a = try allocator.alloc(u8, data.len * 2);
    defer allocator.free(a);
    const b = try allocator.alloc(u8, data.len * 2);
    defer allocator.free(b);
    inline for (.{ StreamEncoder, four_byte_runs.StreamEncoder }) |E| {
        const W = if (E == StreamEncoder) Workspace else four_byte_runs.Workspace;
        const first_workspace = try allocator.create(W);
        defer allocator.destroy(first_workspace);
        const second_workspace = try allocator.create(W);
        defer allocator.destroy(second_workspace);
        const compressions: []const Compression = if (E == StreamEncoder) &.{
            .{ .level = 0 },
            .{ .level = 1 },
            .{ .level = 6 },
            .{ .strategy = .four_byte_runs },
        } else &.{ .{ .level = 0 }, .{ .strategy = .four_byte_runs } };
        for (compressions) |compression| {
            for ([_]?[]const u8{ null, "shared dictionary history" }) |dictionary| {
                for (
                    [_]Limits{
                        .{},
                        .{ .input_bytes = 65536 },
                        .{ .output_bytes = 211 },
                        .{ .work_units = 8191 },
                    },
                ) |limits| {
                    const EncodingOptions = if (E == StreamEncoder) Options else four_byte_runs
                        .Options;
                    const options: EncodingOptions = if (E == StreamEncoder) .{
                        .compression = compression,
                        .limits = limits,
                        .dictionary = dictionary,
                    } else .{
                        .mode = if (compression.level == 0) .stored else .runs,
                        .limits = limits,
                        .dictionary = dictionary,
                    };
                    var staged: E = undefined;
                    var ordinary: E = undefined;
                    try staged.reset(first_workspace, options);
                    try ordinary.reset(second_workspace, options);
                    try std.testing.expect(staged.inputBuffer() == null);
                    try Helper.run(&staged, &ordinary, data, a, b);
                }
            }
        }
    }
}

test "producer input staging refuses oversized commits and overlapping output" {
    const allocator = std.testing.allocator;
    const workspace = try allocator.create(four_byte_runs.Workspace);
    defer allocator.destroy(workspace);
    var encoder: four_byte_runs.StreamEncoder = undefined;
    var output: [16]u8 = undefined;
    for ([_]bool{ false, true }) |overlap| {
        try encoder.reset(workspace, .{});
        _ = try encoder.step(&.{}, &output, .process);
        const buffer = encoder.inputBuffer().?;
        const before = encoder.counts();
        if (overlap) {
            buffer[0] = 42;
            try std.testing.expectError(error.StorageOverlap, encoder.commitInput(1, buffer));
        } else {
            try std.testing.expectError(
                error.InvalidState,
                encoder.commitInput(buffer.len + 1, &output),
            );
        }
        try std.testing.expectEqualDeep(before, encoder.counts());
        try std.testing.expect(encoder.inputBuffer() == null);
        try std.testing.expectError(error.NeedReset, encoder.commitInput(0, &output));
    }
}

fn EncoderImpl(
    comptime RawEncoder: type,
    comptime Reservation: type,
    comptime EncodingOptions: type,
) type {
    return struct {
        const Self = @This();

        /// Invalid encoding policy, overlapping reservations or refusal of zlib framing capacity.
        pub const ResetError = error{ InvalidOptions, StorageOverlap, LimitExceeded };

        /// Invalid lifecycle, overlapping fragments or exhausted cumulative admission.
        pub const StepError = error{
            InvalidState,
            NeedReset,
            StorageOverlap,
            LimitExceeded,
            CounterOverflow,
        };
        /// Setup and streaming failures; methods return their relevant subsets.
        pub const Error = ResetError || StepError;
        /// Exclusive scratch handle retained independently of the raw worker's mechanism state.
        workspace: *Reservation,
        /// Raw block and producer-input lifecycle; callers use this wrapper's methods.
        raw: RawEncoder,
        /// Adler-32 over source bytes accepted by this wrapper, excluding dictionary history.
        checksum: adler32.Hasher,
        /// Copied zlib header, including the optional four-byte DICTID.
        header: [6]u8,
        /// Initialized prefix of header: two bytes without DICTID, six with it.
        header_bytes: usize,
        /// Bytes already returned from the active header or trailer.
        position: usize,
        /// Adler-32 trailer initialized when raw encoding completes.
        trailer: [4]u8,
        /// Current framing boundary; body delegates to the raw worker.
        phase: enum { header, body, trailer, complete },

        /// Header/trailer bytes already returned; added to copied raw output counts.
        framing_bytes: u64,
        /// An operation failed; only reset restores usable state.
        failed: bool,

        /// Borrows input storage for an immediate fill and commit, with no intervening operation.
        /// The header must first be drained through step. The borrow ends at commit; input bytes
        /// can then be reused by the encoder. Null means input cannot currently be accepted.
        pub fn inputBuffer(encoder: *Self) ?[]u8 {
            if (encoder.failed or encoder.phase != .body) return null;
            return encoder.raw.inputBuffer();
        }

        /// Commits the initialized prefix with process semantics. Output must not overlap the owner
        /// or workspace. Errors poison the encoder until reset.
        pub fn commitInput(encoder: *Self, length: usize, output: []u8) StepError!Progress {
            if (encoder.failed) return error.NeedReset;
            return encoder.commitBufferedInput(length, output) catch |err| {
                encoder.failed = true;
                return err;
            };
        }

        fn commitBufferedInput(encoder: *Self, length: usize, output: []u8) StepError!Progress {
            const available = encoder.inputBuffer() orelse return error.InvalidState;
            if (length > available.len) return error.InvalidState;
            if (overlaps(output, std.mem.asBytes(encoder))) return error.StorageOverlap;
            if (overlaps(output, std.mem.asBytes(encoder.workspace))) return error.StorageOverlap;
            // Compression may overwrite this input, so hash it before committing.
            encoder.checksum.update(available[0..length]);
            return encoder.raw.commitInput(length, output);
        }

        /// Starts a new stream, copying dictionary history and hashing its full identity. Null
        /// omits DICTID; an attached empty dictionary has an identity. The output allowance must
        /// admit the header and trailer before raw options are validated. Dictionary bytes may
        /// retire on return; no output is published here.
        pub fn reset(
            self: *Self,
            workspace: *Reservation,
            options: EncodingOptions,
        ) ResetError!void {
            if (overlaps(
                std.mem.asBytes(self),
                std.mem.asBytes(workspace),
            )) return error.StorageOverlap;
            if (options.dictionary) |dictionary| {
                if (overlaps(dictionary, std.mem.asBytes(self))) return error.StorageOverlap;
                if (overlaps(dictionary, std.mem.asBytes(workspace))) return error.StorageOverlap;
            }
            const framing: u64 = if (options.dictionary != null) 10 else 6;
            if (options.limits.output_bytes < framing) return error.LimitExceeded;
            const RawOptions = if (EncodingOptions == Options) raw_encoding
                .Options else raw_encoding.four_byte_runs.Options;
            var raw_options: RawOptions = if (EncodingOptions == Options) .{
                .compression = options.compression,
                .window_bytes = options.window_bytes,
                .limits = options.limits,
            } else .{
                .mode = options.mode,
                .window_bytes = options.window_bytes,
                .limits = options.limits,
            };
            raw_options.limits.output_bytes -= framing;
            try self.raw.reset(workspace, raw_options);
            self.workspace = workspace;
            self.checksum = .init;
            self.header_bytes = @intCast(framing - 4);
            self.position = 0;
            self.phase = .header;
            self.framing_bytes = 0;
            self.failed = false;
            const cinfo: u8 = @intCast(std.math.log2_int(usize, options.window_bytes) - 8);
            self.header[0] = cinfo << 4 | 8;
            const compression: Compression = if (EncodingOptions == Options) options
                .compression else switch (options.mode) {
                .runs => .{ .strategy = .four_byte_runs },
                .stored => .{ .level = 0 },
            };
            // FLEVEL is informational: stored and specialized strategies use zero; ordinary levels
            // group into the RFC speed/size hints.
            const level: u8 = if (compression.level == 0 or compression.strategy != .default)
                0
            else if (compression.level <= 3) 1 else if (compression.level <= 6) 2 else 3;
            const dictionary_flag: u8 = if (options.dictionary != null) 32 else 0;
            self.header[1] = level << 6 | dictionary_flag;
            const check = std.mem.readInt(u16, self.header[0..2], .big) % 31;
            self.header[1] += @intCast((31 - @as(u16, check)) % 31);
            if (options.dictionary) |dictionary| {
                std.mem.writeInt(u32, self.header[2..6], adler32.hash(dictionary), .big);
                // Both reservations were admitted before reset. The fresh raw worker is still at
                // its dictionary boundary, so attachment cannot fail here.
                self.raw.setDictionary(dictionary) catch unreachable;
            }
        }

        /// Copied cumulative counts, including framing bytes copied to output. A failed step
        /// returns no progress value, but counts can include bytes and work admitted during that
        /// step.
        pub fn counts(self: *const Self) Stats {
            var stats = self.raw.counts();
            stats.output_bytes += self.framing_bytes;
            return stats;
        }

        /// Uses the raw encoder's process/flush/finish protocol. Adler-32 covers accepted source
        /// once, across all suspensions and synchronization points.
        pub fn step(
            self: *Self,
            input: []const u8,
            output: []u8,
            action: Action,
        ) StepError!Progress {
            if (self.failed) return error.NeedReset;
            return self.advance(input, output, action) catch |err| {
                self.failed = true;
                return err;
            };
        }

        fn advance(
            self: *Self,
            input: []const u8,
            output: []u8,
            action: Action,
        ) StepError!Progress {
            if (overlaps(input, output)) return error.StorageOverlap;
            inline for (.{ std.mem.asBytes(self), std.mem.asBytes(self.workspace) }) |reservation| {
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
}

test "zlib encoding owns dictionary IDs checksums and retired fragments" {
    const allocator = std.testing.allocator;
    const encode_workspace = try Workspace.create(allocator);
    defer encode_workspace.destroy(allocator);
    const decode_workspace = try DecoderWorkspace.create(allocator);
    defer decode_workspace.destroy(allocator);
    var history: [32768]u8 = undefined;
    const source = "shared dictionary words shared dictionary words and a tail";
    const dictionary = "prefix shared dictionary words ";
    var wire: [512]u8 = undefined;
    var output: [source.len]u8 = undefined;
    const encoded = try into(source, &wire, encode_workspace, .{ .dictionary = dictionary });
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
    var encoder: StreamEncoder = undefined;
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
    const encode_workspace = try Workspace.create(std.testing.allocator);
    defer encode_workspace.destroy(std.testing.allocator);
    @memset(encode_workspace.data[0..32], 0xa5);
    try std.testing.expectError(
        error.StorageOverlap,
        into(
            "source",
            encode_workspace.data[0..32],
            encode_workspace,
            .{ .dictionary = "replacement dictionary" },
        ),
    );
    for (encode_workspace.data[0..32]) |byte| try std.testing.expectEqual(0xa5, byte);
}

test "failed zlib encoding exposes admitted raw work and framing counts" {
    const workspace = try Workspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: StreamEncoder = undefined;
    var output: [128]u8 = undefined;
    for (
        [_]Compression{
            .{ .level = 3 },
            .{ .level = 9 },
            .{ .level = 9, .offline_pricing = .maximum_lengths },
            .{ .level = 9, .offline_refinement = .early },
        },
    ) |compression| {
        try encoder.reset(
            workspace,
            .{ .compression = compression, .limits = .{ .work_units = 1 } },
        );
        _ = try encoder.step("x", &output, .process);
        const published = encoder.counts();
        try std.testing.expectEqual(1, published.input_bytes);
        try std.testing.expectEqual(2, published.output_bytes);
        try std.testing.expectError(
            error.LimitExceeded,
            encoder.step("aaaaaaaaaaaa", &output, .finish),
        );
        try std.testing.expectEqual(1, encoder.counts().work_units);
        try std.testing.expectEqual(1, encoder.counts().match_probes);
        try std.testing.expect(encoder.counts().input_bytes > published.input_bytes);
        try std.testing.expectEqual(published.output_bytes, encoder.counts().output_bytes);
        try std.testing.expectError(error.NeedReset, encoder.step("", &output, .finish));
    }
}

test "compression levels retain zlib header and dictionary contracts" {
    const allocator = std.testing.allocator;
    const encoder_workspace = try Workspace.create(allocator);
    defer encoder_workspace.destroy(allocator);
    const decoder_workspace = try DecoderWorkspace.create(allocator);
    defer decoder_workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const source = "small shared history, followed by another shared history";
    const dictionaries = [_]?[]const u8{ null, "", "small shared history" };
    const hints = [_]u8{ 0, 1, 1, 1, 2, 2, 2, 3, 3, 3 };
    var wire: [512]u8 = undefined;
    var restored: [source.len]u8 = undefined;
    for (hints, 0..) |hint, level| {
        for ([_]Compression.Strategy{ .default, .four_byte_runs }) |strategy| {
            for (dictionaries) |dictionary| {
                const encoded = try into(
                    source,
                    &wire,
                    encoder_workspace,
                    .{
                        .compression = .{ .level = @intCast(level), .strategy = strategy },
                        .dictionary = dictionary,
                    },
                );
                // FLEVEL is a hint; FCHECK covers both header bytes, and an empty dictionary still
                // has an identity distinct from no dictionary.
                try std.testing.expectEqual(if (strategy == .default) hint else 0, encoded[1] >> 6);
                try std.testing.expectEqual(
                    @as(u16, 0),
                    std.mem.readInt(u16, encoded[0..2], .big) % 31,
                );
                try std.testing.expectEqual(dictionary != null, encoded[1] & 0x20 != 0);
                if (dictionary) |bytes| {
                    try std.testing.expectEqual(
                        adler32.hash(bytes),
                        std.mem.readInt(u32, encoded[2..6], .big),
                    );
                }
                try std.testing.expectEqual(
                    adler32.hash(source),
                    std.mem.readInt(u32, encoded[encoded.len - 4 ..][0..4], .big),
                );
                const result = try decode(
                    encoded,
                    &restored,
                    .{ .workspace = decoder_workspace, .history = history },
                    .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
                );
                try std.testing.expectEqual(source.len, result.produced);
                try std.testing.expectEqualSlices(u8, source, &restored);
            }
        }
    }
    const literal_only = try into(
        source,
        &wire,
        encoder_workspace,
        .{ .compression = .{ .strategy = .huffman_only } },
    );
    try std.testing.expectEqual(@as(u8, 0), literal_only[1] >> 6);
    for ([_]u8{ 4, 5, 6 }) |level| {
        const dictionary = "small shared history";
        const encoded = try into(
            source,
            &wire,
            encoder_workspace,
            .{
                .compression = .{ .level = level, .lazy_lookahead = .reduced },
                .window_bytes = 256,
                .dictionary = dictionary,
            },
        );
        try std.testing.expectEqual(@as(u8, 2), encoded[1] >> 6);
        try std.testing.expect(encoded[1] & 0x20 != 0);
        const result = try decode(
            encoded,
            &restored,
            .{ .workspace = decoder_workspace, .history = history },
            .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
        );
        try std.testing.expectEqual(source.len, result.produced);
        try std.testing.expectEqualSlices(u8, source, &restored);
    }
    for ([_]u8{ 7, 8, 9 }) |level| {
        inline for (.{ .reduced, .maximum_lengths }) |pricing| {
            const dictionary = "small shared history";
            const encoded = try into(
                source,
                &wire,
                encoder_workspace,
                .{
                    .compression = .{ .level = level, .offline_pricing = pricing },
                    .window_bytes = 256,
                    .dictionary = dictionary,
                },
            );
            try std.testing.expectEqual(@as(u8, 3), encoded[1] >> 6);
            const result = try decode(
                encoded,
                &restored,
                .{ .workspace = decoder_workspace, .history = history },
                .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
            );
            try std.testing.expectEqual(source.len, result.produced);
            try std.testing.expectEqualSlices(u8, source, &restored);
        }
    }
    const early = try into(
        source,
        &wire,
        encoder_workspace,
        .{
            .compression = .{ .level = 9, .offline_refinement = .early },
            .dictionary = "small shared history",
        },
    );
    const early_result = try decode(
        early,
        &restored,
        .{ .workspace = decoder_workspace, .history = history },
        .{ .dictionary = "small shared history", .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(source.len, early_result.produced);
    try std.testing.expectEqualSlices(u8, source, &restored);
    var encoder: StreamEncoder = undefined;
    try encoder.reset(encoder_workspace, .{});
    const original_header = encoder.header[0..2].*;
    const original_counts = encoder.counts();
    try std.testing.expectError(
        error.InvalidOptions,
        encoder.reset(
            encoder_workspace,
            .{ .compression = .{ .level = 9, .lazy_lookahead = .reduced } },
        ),
    );
    try std.testing.expectEqualSlices(u8, &original_header, encoder.header[0..2]);
    try std.testing.expectEqualDeep(original_counts, encoder.counts());
    try std.testing.expectError(
        error.InvalidOptions,
        encoder.reset(
            encoder_workspace,
            .{ .compression = .{ .level = 6, .offline_pricing = .reduced } },
        ),
    );
    try std.testing.expectEqualSlices(u8, &original_header, encoder.header[0..2]);
    try std.testing.expectEqualDeep(original_counts, encoder.counts());
    try std.testing.expectError(
        error.InvalidOptions,
        encoder.reset(
            encoder_workspace,
            .{ .compression = .{ .level = 6, .offline_pricing = .maximum_lengths } },
        ),
    );
    try std.testing.expectEqualSlices(u8, &original_header, encoder.header[0..2]);
    try std.testing.expectEqualDeep(original_counts, encoder.counts());
    @memset(&wire, 0xa5);
    try std.testing.expectError(
        error.InvalidOptions,
        into(source, &wire, encoder_workspace, .{ .compression = .{ .level = 10 } }),
    );
    try std.testing.expect(std.mem.allEqual(u8, &wire, 0xa5));
    // Framing must fit the caller's allowance before reset attempts raw compression options.
    try std.testing.expectError(
        error.LimitExceeded,
        into(
            source,
            &wire,
            encoder_workspace,
            .{ .compression = .{ .level = 10 }, .limits = .{ .output_bytes = 0 } },
        ),
    );
    inline for (.{ .reduced, .maximum_lengths }) |pricing| {
        try std.testing.expectError(
            error.LimitExceeded,
            into(
                source,
                &wire,
                encoder_workspace,
                .{
                    .compression = .{ .level = 6, .offline_pricing = pricing },
                    .limits = .{ .output_bytes = 0 },
                },
            ),
        );
    }
}

test "short stored streams match the general zlib encoder" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    var source: [75]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @truncate(i * 73 + 19);
    for (0..76) |length| {
        for ([_]u4{ 0, 1, 6, 9 }) |level| {
            var full: [128]u8 = undefined;
            const expected = try into(
                source[0..length],
                &full,
                workspace,
                .{ .compression = .{ .level = level, .strategy = .four_byte_runs } },
            );
            var guard: [88]u8 = @splat(0xa5);
            const wire = try short_stored.into(source[0..length], guard[1..87]);
            try std.testing.expectEqualSlices(u8, expected, wire);
            try std.testing.expectEqual(@as(u8, 0xa5), guard[0]);
            try std.testing.expectEqual(@as(u8, 0xa5), guard[87]);
        }
    }
}

test "compact run workspace matches zlib streaming state" {
    const Helper = struct {
        fn run(encoder: anytype, input: []const u8, output: []u8) !usize {
            var consumed: usize = 0;
            var written: usize = 0;
            while (true) {
                const end = @min(input.len, consumed + 131);
                const action: Action = if (end == input.len) .finish else .process;
                const progress = try encoder.step(
                    input[consumed..end],
                    output[written..][0..@min(79, output.len - written)],
                    action,
                );
                consumed += progress.consumed;
                written += progress.produced;
                if (progress.status == .complete) return written;
            }
        }
    };
    const allocator = std.testing.allocator;
    const full_workspace = try allocator.create(Workspace);
    defer allocator.destroy(full_workspace);
    const compact_workspace = try allocator.create(four_byte_runs.Workspace);
    defer allocator.destroy(compact_workspace);
    const data = try allocator.alloc(u8, 65536);
    defer allocator.free(data);
    var random: std.Random.DefaultPrng = .init(0x3fc2);
    random.random().bytes(data);
    const a = try allocator.alloc(u8, 140000);
    defer allocator.free(a);
    const b = try allocator.alloc(u8, 140000);
    defer allocator.free(b);
    for ([_]usize{ 0, 35, 76, 4096, 65535, 65536 }) |length| {
        for ([_]four_byte_runs.Options.Mode{ .runs, .stored }) |mode| {
            for ([_]usize{ 256, 32768 }) |window| {
                for ([_]?[]const u8{ null, "", "prior data history" }) |dictionary| {
                    const options: Options = .{
                        .compression = if (mode == .stored) .{
                            .level = 0,
                        } else .{ .strategy = .four_byte_runs },
                        .window_bytes = window,
                        .dictionary = dictionary,
                    };
                    var full: StreamEncoder = undefined;
                    var compact: four_byte_runs.StreamEncoder = undefined;
                    try full.reset(full_workspace, options);
                    try compact.reset(
                        compact_workspace,
                        .{ .mode = mode, .window_bytes = window, .dictionary = dictionary },
                    );
                    const n = try Helper.run(&full, data[0..length], a);
                    const m = try Helper.run(&compact, data[0..length], b);
                    try std.testing.expectEqualSlices(u8, a[0..n], b[0..m]);
                    try std.testing.expectEqualDeep(full.counts(), compact.counts());
                }
            }
        }
    }
    var compact: four_byte_runs.StreamEncoder = undefined;
    var full: StreamEncoder = undefined;
    try compact.reset(compact_workspace, .{});
    try full.reset(full_workspace, .{ .compression = .{ .strategy = .four_byte_runs } });
    const n = try Helper.run(&full, data[0..76], a);
    const m = try Helper.run(&compact, data[0..76], b);
    try std.testing.expectEqualSlices(u8, a[0..n], b[0..m]);
    try std.testing.expectEqualDeep(full.counts(), compact.counts());
    try std.testing.expectError(
        error.InvalidOptions,
        compact.reset(compact_workspace, .{ .window_bytes = 257 }),
    );
}

test "short run streams match the general zlib encoder at every length" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    var source: [four_byte_runs.short.max_input_bytes]u8 = undefined;
    for (0..3) |pattern| {
        for (&source, 0..) |*byte, i| byte.* = switch (pattern) {
            0 => 0,
            1 => @truncate(i *% 73 +% i / 11),
            else => @truncate(if (i % 43 < 36) i % 4 else i *% 53),
        };
        for (0..four_byte_runs.short.max_input_bytes + 1) |length| {
            var full: [four_byte_runs.short.max_input_bytes + 11]u8 = undefined;
            const expected = try into(
                source[0..length],
                &full,
                workspace,
                .{
                    .compression = .{
                        .level = ([_]u8{ 1, 6, 9 })[pattern],
                        .strategy = .four_byte_runs,
                    },
                },
            );
            var guarded: [four_byte_runs.short.output_capacity + 2]u8 = @splat(0xa5);
            const before = source;
            const actual = try four_byte_runs.short.into(
                source[0..length],
                guarded[1 .. four_byte_runs.short.output_capacity + 1],
            );
            try std.testing.expectEqualSlices(u8, &before, &source);
            try std.testing.expectEqualSlices(u8, expected, actual);
            try std.testing.expectEqual(@as(u8, 0xa5), guarded[0]);
            try std.testing.expectEqual(
                @as(u8, 0xa5),
                guarded[four_byte_runs.short.output_capacity + 1],
            );
        }
    }
}

test "short run streams preserve every mismatch position and guards" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    var source: [four_byte_runs.short.max_input_bytes]u8 = undefined;
    var full: [four_byte_runs.short.max_input_bytes + 11]u8 = undefined;
    for (
        [_]usize{ 36, 75, 76, 80, 127, 128, 129, 257, 258, 259, 512, 1024, 1025, 2047, 2048 },
    ) |length| {
        for (4..length) |mismatch| {
            for (source[0..length], 0..) |*byte, i| byte.* = @as(u8, @intCast(i % 4)) * 73;
            source[mismatch] ^= 0x80;
            const expected = try into(
                source[0..length],
                &full,
                workspace,
                .{ .compression = .{ .strategy = .four_byte_runs } },
            );
            var guarded: [four_byte_runs.short.output_capacity + 2]u8 = @splat(0xa5);
            const actual = try four_byte_runs.short.into(
                source[0..length],
                guarded[1 .. four_byte_runs.short.output_capacity + 1],
            );
            try std.testing.expectEqualSlices(u8, expected, actual);
            try std.testing.expectEqual(@as(u8, 0xa5), guarded[0]);
            try std.testing.expectEqual(
                @as(u8, 0xa5),
                guarded[four_byte_runs.short.output_capacity + 1],
            );
        }
    }
}

test "short encoders refuse length capacity and overlap before writing" {
    var source: [four_byte_runs.short.max_input_bytes + 1]u8 = @splat(0x37);
    var output: [four_byte_runs.short.output_capacity]u8 = @splat(0xa5);
    try std.testing.expectError(
        error.LimitExceeded,
        short_stored.into(source[0 .. short_stored.max_input_bytes + 1], &output),
    );
    try std.testing.expectError(error.LimitExceeded, four_byte_runs.short.into(&source, &output));
    try std.testing.expectError(
        error.OutputTooSmall,
        short_stored.into(source[0..1], output[0..11]),
    );
    try std.testing.expectError(
        error.OutputTooSmall,
        four_byte_runs.short.into(source[0..1], output[0 .. output.len - 1]),
    );
    try std.testing.expect(std.mem.allEqual(u8, &source, 0x37));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
    try std.testing.expectError(error.StorageOverlap, short_stored.into(output[0..1], &output));
    try std.testing.expectError(
        error.StorageOverlap,
        four_byte_runs.short.into(output[0..1], &output),
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
}

test "zlib encoders transfer partial headers and trailers between calls" {
    const allocator = std.testing.allocator;
    inline for (.{ false, true }) |compact| {
        const Reservation = if (compact) four_byte_runs.Workspace else Workspace;
        const Worker = if (compact) four_byte_runs.StreamEncoder else StreamEncoder;
        const Configuration = if (compact) four_byte_runs.Options else Options;
        const options: Configuration = if (compact) .{
            .mode = .stored,
            .dictionary = "A",
        } else .{ .compression = .{ .level = 0 }, .dictionary = "A" };
        const workspace = try Reservation.create(allocator);
        defer workspace.destroy(allocator);
        const original = try allocator.create(Worker);
        defer allocator.destroy(original);
        const transferred = try allocator.create(Worker);
        defer allocator.destroy(transferred);
        const source = "AAAAAAAA";
        var expected: [64]u8 = undefined;
        try original.reset(workspace, options);
        const complete = try original.step(source, &expected, .finish);
        try std.testing.expectEqual(Status.complete, complete.status);
        const expected_counts = original.counts();
        const expected_wire = expected[0..complete.produced];

        var output: [72]u8 = @splat(0xa5);
        try original.reset(workspace, options);
        const first = try original.step(source, output[0..1], .finish);
        try std.testing.expectEqual(@as(usize, 0), first.consumed);
        try std.testing.expectEqual(Status.need_output, first.status);
        transferred.* = original.*;
        @memset(std.mem.asBytes(original), 0xa5);
        const middle = try transferred.step(source, output[1 .. complete.produced - 3], .finish);
        try std.testing.expectEqual(source.len, middle.consumed);
        try std.testing.expectEqual(Status.need_output, middle.status);
        try std.testing.expectEqual(@TypeOf(transferred.phase).trailer, transferred.phase);
        original.* = transferred.*;
        @memset(std.mem.asBytes(transferred), 0xa5);
        const final = try original.step(&.{}, output[complete.produced - 3 ..], .finish);
        try std.testing.expectEqual(Status.complete, final.status);
        try std.testing.expectEqual(@as(usize, 3), final.produced);
        try std.testing.expectEqualSlices(u8, expected_wire, output[0..complete.produced]);
        try std.testing.expectEqualDeep(expected_counts, original.counts());
        for (output[complete.produced..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}
