//! An AMC motion owns recorded frame numbers, dense channel values and copied header metadata.
//! Construct through parseAlloc for a live Skeleton.View. ASF backing remains borrowed and must
//! stay immutable; release clips and evaluators before their Skeleton. AMC input may retire after
//! parsing. Copies alias ownership; release only one copy, with the construction allocator. Frames
//! borrow backing storage rather than this descriptor's address; keep managed fields and backing
//! unchanged while borrowed. No allocator is stored, and sparse omissions are already carried
//! forward without interpolation or a guessed rate.
const std = @import("std");
const Skeleton = @import("Skeleton.zig");
const Lexer = @import("Lexer.zig");
const fixtures = @import("fixtures.zig");
const AngleUnit = Skeleton.Units.AngleUnit;
const Motion = @This();

/// Immutable backing borrowed from the separately owned Skeleton; must outlive this Motion.
skeleton: Skeleton.View,
/// Owned, strictly increasing positive source frame numbers; array position is a separate index.
frame_numbers: []const u32,
/// Owned frame-major channel values; each frame has skeleton.channel_count consecutive entries.
values: []const f64,
/// Owned original AMC prefix preceding the first frame marker.
header: []const u8,
/// AMC rotation unit, overriding ASF when declared; otherwise the ASF angle unit.
angle_unit: AngleUnit,
/// Whether the AMC header requires every animated bone to appear in every frame.
fully_specified: bool,

/// One frame borrowing clip values and immutable skeleton backing. Rotations use angle_unit;
/// positions and lengths retain file units. Pose evaluation also accepts exact-width finite values
/// supplied by the caller for the same parsed skeleton, independently of the recorded number.
pub const Frame = struct {
    /// Positive original AMC frame number for parsed frames, including gaps; ignored by poses.
    number: u32,
    /// Borrowed values in bone/channel order; exactly skeleton.channel_count entries.
    values: []const f64,
    /// Immutable backing borrowed from the live Skeleton used to construct this clip.
    skeleton: Skeleton.View,
    /// Unit used by this frame's rotation channels; may override ASF units.
    angle_unit: AngleUnit,

    /// Borrows a bone's ordered values, or returns null for an invalid array index. Static bones
    /// return an empty slice. Caller-created frames must supply the complete width described by
    /// values.
    pub fn boneValues(self: Frame, bone_index: u32) ?[]const f64 {
        if (bone_index >= self.skeleton.bones.len) return null;
        const bone = self.skeleton.bones[bone_index];
        return self.values[bone.channel_offset..][0..bone.channel_count];
    }
};

/// Borrows a frame by zero-based array position, independent of its original frame number.
pub fn frame(self: *const Motion, index: usize) ?Frame {
    if (index >= self.frame_numbers.len) return null;
    const width = self.skeleton.channel_count;
    return .{
        .number = self.frame_numbers[index],
        .values = self.values[index * width ..][0..width],
        .skeleton = self.skeleton,
        .angle_unit = self.angle_unit,
    };
}

/// Releases this clip's backing using its construction allocator; leaves the skeleton alive.
pub fn deinit(self: *Motion, allocator: std.mem.Allocator) void {
    allocator.free(self.header);
    allocator.free(self.values);
    allocator.free(self.frame_numbers);
    self.* = undefined;
}

/// Materializes complete frame-major channel values for a parsed immutable skeleton. AMC bytes can
/// retire after success; skeleton backing must outlive this motion. Frame numbers are positive and
/// strictly increasing, with gaps retained. FULLY-SPECIFIED requires all animated segments; other
/// clips need a complete first frame and carry omitted segments forward. Duplicate/unknown names
/// and any channel-count mismatch fail, including in the final frame. Failure frees partial
/// allocations and publishes no owner. Success and OutOfMemory leave diagnostics unchanged. A
/// diagnostic overlapping input is refused with AliasedStorage without writing it; other parse
/// failures set it.
pub fn parseAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    skeleton: Skeleton.View,
    diagnostic: ?*Lexer.Diagnostic,
    limits: Lexer.ParseLimits,
) (std.mem.Allocator.Error || Lexer.ParseError)!Motion {
    try Lexer.admit(source, diagnostic, limits);
    if (skeleton.bones.len == 0 or skeleton.bones.len > limits.bones) {
        Lexer.report(source, 0, diagnostic, error.LimitExceeded);
        return error.LimitExceeded;
    }
    var counter: FrameCounter = .{ .source = source, .limits = limits };
    const frame_count = counter.run() catch |err| {
        Lexer.report(source, counter.offset, diagnostic, err);
        return err;
    };
    const value_count = std.math.mul(usize, frame_count, skeleton.channel_count) catch {
        Lexer.report(source, 0, diagnostic, error.LimitExceeded);
        return error.LimitExceeded;
    };
    if (value_count > limits.values) {
        Lexer.report(source, 0, diagnostic, error.LimitExceeded);
        return error.LimitExceeded;
    }
    const frames = try allocator.alloc(u32, frame_count);
    errdefer allocator.free(frames);
    const values = try allocator.alloc(f64, value_count);
    errdefer allocator.free(values);
    const seen = try allocator.alloc(bool, skeleton.bones.len);
    defer allocator.free(seen);
    @memset(seen, false);
    var names: std.StringHashMapUnmanaged(u32) = .empty;
    defer names.deinit(allocator);
    for (skeleton.bones, 0..) |bone, index|
        try names.put(allocator, bone.name, @intCast(index));
    var parser: Parser = .{
        .source = source,
        .skeleton = skeleton,
        .names = &names,
        .frames = frames,
        .values = values,
        .seen = seen,
        .limits = limits,
    };
    var motion = parser.run() catch |err| {
        Lexer.report(source, parser.offset, diagnostic, err);
        return err;
    };
    motion.header = try allocator.dupe(u8, motion.header);
    return motion;
}

test parseAlloc {
    const skeleton_source =
        \\:version 1.10
        \\:units
        \\ angle deg
        \\:root
        \\ order TX TY TZ RX RY RZ
        \\ axis XYZ
        \\ position 0 0 0
        \\ orientation 0 0 0
        \\:bonedata
        \\:hierarchy
        \\ begin
        \\ end
    ;
    const allocator = std.testing.allocator;
    var skeleton = try Skeleton.parseAlloc(allocator, skeleton_source, null, .{});
    defer skeleton.deinit(allocator);
    var motion = try parseAlloc(
        allocator,
        ":DEGREES\n1\nroot 1 2 3 10 20 30\n",
        skeleton.view(),
        null,
        .{},
    );
    defer motion.deinit(allocator);
    const recorded_frame = motion.frame(0).?;
    try std.testing.expectEqual(@as(u32, 1), recorded_frame.number);
    try std.testing.expectEqualSlices(
        f64,
        &.{ 1, 2, 3, 10, 20, 30 },
        recorded_frame.boneValues(0).?,
    );
}

const Line = struct { bytes: []const u8, offset: usize };

const LineIterator = struct {
    source: []const u8,
    cursor: usize = 0,

    fn next(self: *LineIterator) ?Line {
        if (self.cursor == self.source.len) return null;
        const start = self.cursor;
        const end = if (std.mem.indexOfScalarPos(
            u8,
            self.source,
            start,
            '\n',
        )) |index| index else self.source.len;
        self.cursor = if (end < self.source.len) end + 1 else end;
        return .{ .bytes = self.source[start..end], .offset = start };
    }
};

// Reserve exact frame storage from integer-leading lines. This pass does not validate frame numbers
// or row contents; Parser checks them before publishing the motion.
const FrameCounter = struct {
    source: []const u8,
    limits: Lexer.ParseLimits,
    offset: usize = 0,

    fn run(self: *FrameCounter) Lexer.ParseError!usize {
        var lines: LineIterator = .{ .source = self.source };
        var count: usize = 0;
        while (lines.next()) |line| {
            var lexer: Lexer = .{
                .source = line.bytes,
                .limit = self.limits.token_bytes,
                .base = line.offset,
            };
            const token = lexer.next() catch |err| {
                self.offset = lexer.offset;
                return err;
            };
            if (token) |first| {
                self.offset = first.offset;
                if (Lexer.isIntegerToken(first.text)) {
                    if (count == self.limits.frames) return error.LimitExceeded;
                    count += 1;
                }
            }
        }
        if (count == 0) return error.MissingChannels;
        return count;
    }
};

const Parser = struct {
    source: []const u8,
    skeleton: Skeleton.View,
    names: *const std.StringHashMapUnmanaged(u32),
    frames: []u32,
    values: []f64,
    seen: []bool,
    limits: Lexer.ParseLimits,
    used: usize = 0,
    offset: usize = 0,
    fully_specified: bool = false,
    angle_unit: ?AngleUnit = null,
    header_length: usize = 0,

    fn nextToken(self: *Parser, lexer: *Lexer) Lexer.ParseError!?Lexer.Token {
        const token = lexer.next() catch |err| {
            self.offset = lexer.offset;
            return err;
        };
        self.offset = lexer.offset;
        return token;
    }

    fn completeFrame(self: *const Parser) Lexer.ParseError!void {
        if (self.used == 0) return;
        if (self.used == 1 or self.fully_specified) {
            for (self.skeleton.bones, self.seen) |bone, present| {
                if (bone.channel_count != 0 and !present) return error.MissingChannels;
            }
        }
    }

    fn directive(self: *Parser, key: []const u8) Lexer.ParseError!void {
        if (self.used != 0) return error.UnsupportedDirective;
        if (std.mem.eql(u8, key, ":FULLY-SPECIFIED")) {
            if (self.fully_specified) return error.DuplicateField;
            self.fully_specified = true;
        } else if (std.mem.eql(u8, key, ":DEGREES") or std.mem.eql(u8, key, ":RADIANS")) {
            if (self.angle_unit != null) return error.DuplicateField;
            self.angle_unit = if (std.mem.eql(u8, key, ":DEGREES")) .degrees else .radians;
        } else return error.UnsupportedDirective;
    }

    fn run(self: *Parser) Lexer.ParseError!Motion {
        var lines: LineIterator = .{ .source = self.source };
        const channel_count = self.skeleton.channel_count;
        while (lines.next()) |line| {
            var lexer: Lexer = .{
                .source = line.bytes,
                .limit = self.limits.token_bytes,
                .base = line.offset,
            };
            const first = try self.nextToken(&lexer) orelse continue;
            if (first.text[0] == ':') {
                try self.directive(first.text);
                if (try self.nextToken(&lexer) != null) return error.UnexpectedToken;
            } else if (Lexer.isIntegerToken(first.text)) {
                try self.completeFrame();
                const number = Lexer.integer(first.text) catch return error.InvalidFrame;
                if (number == 0 or (self.used != 0 and number <= self.frames[self.used - 1]))
                    return error.InvalidFrame;
                if (try self.nextToken(&lexer) != null) return error.InvalidFrame;
                if (self.used >= self.frames.len) return error.LimitExceeded;
                if (self.used == 0) {
                    self.header_length = line.offset;
                } else if (!self.fully_specified) {
                    // Start from the preceding complete frame; this frame's rows overwrite only the
                    // bones they name. No interpolation is involved.
                    @memcpy(
                        self.values[self.used * channel_count ..][0..channel_count],
                        self.values[(self.used - 1) * channel_count ..][0..channel_count],
                    );
                }
                self.frames[self.used] = number;
                self.used += 1;
                @memset(self.seen, false);
            } else {
                if (self.used == 0) return error.MissingChannels;
                const bone_index = self.names.get(first.text) orelse return error.UnknownBone;
                if (self.seen[bone_index]) return error.DuplicateChannels;
                self.seen[bone_index] = true;
                const bone = self.skeleton.bones[bone_index];
                var index: usize = 0;
                while (try self.nextToken(&lexer)) |token| {
                    if (index == bone.channel_count) return error.ChannelCount;
                    const frame_start = (self.used - 1) * channel_count;
                    const channel_offset = frame_start + bone.channel_offset + index;
                    self.values[channel_offset] = try Lexer.decimal(token.text);
                    index += 1;
                }
                if (index != bone.channel_count) return error.ChannelCount;
            }
        }
        self.offset = self.source.len;
        try self.completeFrame();
        if (self.used != self.frames.len) return error.InvalidFrame;
        return .{
            .skeleton = self.skeleton,
            .frame_numbers = self.frames,
            .values = self.values,
            .header = self.source[0..self.header_length],
            .angle_unit = self.angle_unit orelse self.skeleton.units.angle,
            .fully_specified = self.fully_specified,
        };
    }
};

test "complete motion preserves all ordered values and survives source retirement" {
    const allocator = std.testing.allocator;
    var skeleton = try Skeleton.parseAlloc(allocator, fixtures.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    const source = try allocator.dupe(u8, fixtures.motion);
    defer allocator.free(source);
    var motion = try parseAlloc(allocator, source, skeleton.view(), null, .{});
    defer motion.deinit(allocator);
    @memset(source, 0xa5);
    try std.testing.expectEqualSlices(u32, &.{ 1, 3 }, motion.frame_numbers);
    try std.testing.expectEqualSlices(
        f64,
        &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 },
        motion.frame(0).?.values,
    );
    try std.testing.expectEqualSlices(f64, &.{ 17, 18 }, motion.frame(1).?.boneValues(1).?);
    try std.testing.expectEqualSlices(f64, &.{19}, motion.frame(1).?.boneValues(2).?);
    try std.testing.expectEqual(@as(?Frame, null), motion.frame(2));
    try std.testing.expect(std.mem.startsWith(u8, motion.header, "# authored"));
}

test "sparse motion requires a complete first frame then carries omitted segments" {
    const allocator = std.testing.allocator;
    var skeleton = try Skeleton.parseAlloc(allocator, fixtures.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    var motion = try parseAlloc(allocator,
        \\:RADIANS
        \\2
        \\root 1 2 3 4 5 6
        \\tip 7 8
        \\base 9
        \\4
        \\tip 10 11
    , skeleton.view(), null, .{});
    defer motion.deinit(allocator);
    try std.testing.expectEqual(AngleUnit.radians, motion.angle_unit);
    try std.testing.expectEqualSlices(
        f64,
        &.{ 1, 2, 3, 4, 5, 6, 10, 11, 9 },
        motion.frame(1).?.values,
    );
    try std.testing.expectError(
        error.MissingChannels,
        parseAlloc(allocator, "1\nroot 1 2 3 4 5 6", skeleton.view(), null, .{}),
    );
}

test "motion rejects final omissions, duplicates, wrong arity, frame and numeric failures" {
    const allocator = std.testing.allocator;
    var skeleton = try Skeleton.parseAlloc(allocator, fixtures.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    const Case = struct { before: []const u8, after: []const u8, reason: Lexer.ParseError };
    for ([_]Case{
        .{ .before = "base 19", .after = "", .reason = error.MissingChannels },
        .{ .before = "base 19", .after = "base 19\nbase 20", .reason = error.DuplicateChannels },
        .{ .before = "base 19", .after = "other 19", .reason = error.UnknownBone },
        .{ .before = "base 19", .after = "base 19 20", .reason = error.ChannelCount },
        .{ .before = "base 19", .after = "base", .reason = error.ChannelCount },
        .{ .before = "base 19", .after = "base 1e9999", .reason = error.InvalidNumber },
        .{ .before = "base 19", .after = "base 0x1p2", .reason = error.InvalidNumber },
        .{ .before = "\n3\n", .after = "\n1\n", .reason = error.InvalidFrame },
        .{ .before = "\n3\n", .after = "\n0\n", .reason = error.InvalidFrame },
        .{ .before = ":DEGREES", .after = ":UNKNOWN", .reason = error.UnsupportedDirective },
    }) |case| {
        const source = try std.mem.replaceOwned(
            u8,
            allocator,
            fixtures.motion,
            case.before,
            case.after,
        );
        defer allocator.free(source);
        try std.testing.expectError(
            case.reason,
            parseAlloc(allocator, source, skeleton.view(), null, .{}),
        );
    }
}

const AllocationTests = struct {
    pub fn run(allocator: std.mem.Allocator) !void {
        var diagnostic: Lexer.Diagnostic = .{
            .offset = 999,
            .line = 999,
            .reason = error.InvalidText,
        };
        const before = diagnostic;
        var skeleton = Skeleton.parseAlloc(
            allocator,
            fixtures.skeleton,
            &diagnostic,
            .{},
        ) catch |err| {
            try std.testing.expectEqualDeep(before, diagnostic);
            return err;
        };
        defer skeleton.deinit(allocator);
        var first = parseAlloc(
            allocator,
            fixtures.motion,
            skeleton.view(),
            &diagnostic,
            .{},
        ) catch |err| {
            try std.testing.expectEqualDeep(before, diagnostic);
            return err;
        };
        defer first.deinit(allocator);
        var second = parseAlloc(
            allocator,
            fixtures.motion,
            skeleton.view(),
            &diagnostic,
            .{},
        ) catch |err| {
            try std.testing.expectEqualDeep(before, diagnostic);
            return err;
        };
        defer second.deinit(allocator);
        try std.testing.expectEqualDeep(before, diagnostic);
        try std.testing.expectEqualSlices(f64, first.values, second.values);
    }
};

test "allocation failures preserve diagnostics and release partial skeletons and shared clips" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, AllocationTests.run, .{});
}

test "motion diagnostics, CRLF, angle fallback and count limits are explicit" {
    const allocator = std.testing.allocator;
    var skeleton = try Skeleton.parseAlloc(allocator, fixtures.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    const bad = try std.mem.replaceOwned(u8, allocator, fixtures.motion, "base 19", "base nan");
    defer allocator.free(bad);
    var diagnostic: Lexer.Diagnostic = undefined;
    try std.testing.expectError(
        error.InvalidNumber,
        parseAlloc(allocator, bad, skeleton.view(), &diagnostic, .{}),
    );
    try std.testing.expectEqual(std.mem.indexOf(u8, bad, "nan").?, diagnostic.offset);
    try std.testing.expectEqual(error.InvalidNumber, diagnostic.reason);
    const crlf = try std.mem.replaceOwned(u8, allocator, fixtures.motion, "\n", "\r\n");
    defer allocator.free(crlf);
    var motion = try parseAlloc(allocator, crlf, skeleton.view(), null, .{});
    defer motion.deinit(allocator);
    try std.testing.expectEqual(AngleUnit.degrees, motion.angle_unit);
    for ([_]Lexer.ParseLimits{ .{ .frames = 1 }, .{ .values = 17 }, .{ .bones = 3 } }) |limits|
        try std.testing.expectError(
            error.LimitExceeded,
            parseAlloc(allocator, fixtures.motion, skeleton.view(), null, limits),
        );
}

test "oversized motion tokens report their actual byte and line" {
    const allocator = std.testing.allocator;
    var skeleton = try Skeleton.parseAlloc(allocator, fixtures.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    const oversized = "111111111111111111111111111111";
    for ([_][]const u8{ "base " ++ oversized, oversized ++ "name 19" }) |replacement| {
        const source = try std.mem.replaceOwned(
            u8,
            allocator,
            fixtures.motion,
            "base 19",
            replacement,
        );
        defer allocator.free(source);
        var diagnostic: Lexer.Diagnostic = undefined;
        try std.testing.expectError(
            error.LimitExceeded,
            parseAlloc(allocator, source, skeleton.view(), &diagnostic, .{ .token_bytes = 20 }),
        );
        try std.testing.expectEqual(std.mem.indexOf(u8, source, oversized).?, diagnostic.offset);
        try std.testing.expectEqual(
            1 + std.mem.count(u8, source[0..diagnostic.offset], "\n"),
            diagnostic.line,
        );
    }
}

test "signed-prefix and keyword segment names stay paired while numeric names are refused" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "-base", "begin", "end", "name" }) |name| {
        const source = try std.mem.replaceOwned(u8, allocator, fixtures.skeleton, "base", name);
        defer allocator.free(source);
        const input = try std.mem.replaceOwned(u8, allocator, fixtures.motion, "base", name);
        defer allocator.free(input);
        var skeleton = try Skeleton.parseAlloc(allocator, source, null, .{});
        defer skeleton.deinit(allocator);
        var motion = try parseAlloc(allocator, input, skeleton.view(), null, .{});
        defer motion.deinit(allocator);
        try std.testing.expectEqual(@as(?u32, 2), skeleton.view().findBone(name));
        try std.testing.expectEqualSlices(f64, &.{19}, motion.frame(1).?.boneValues(2).?);
    }
    try std.testing.expectError(error.InvalidText, Lexer.identifier("-1"));
    try std.testing.expectError(error.InvalidText, Lexer.identifier("+1"));
}
