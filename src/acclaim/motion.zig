//! Skeleton-bound AMC frame materialization with complete channel admission.
const std = @import("std");
const model = @import("model.zig");
const text = @import("text.zig");

/// Limits for materialized motion. Missing AMC angle declarations use the skeleton's declared angle
/// unit. No sample rate, coordinate conversion or limit clamping is inferred.
pub const MotionParseOptions = struct { limits: text.Limits = .{} };

/// Materializes complete frame-major samples for a borrowed immutable skeleton. AMC bytes can
/// retire after return; the skeleton must outlive this motion. Frame IDs are positive and strictly
/// increasing, with gaps retained. FULLY-SPECIFIED requires all animated segments; other clips need
/// a complete first frame and carry omitted segments forward. Duplicate/unknown names and any
/// channel-count mismatch fail, including in the final frame. Partial allocations are released.
pub fn parseMotionAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    skeleton: model.SkeletonView,
    diagnostic: ?*text.Diagnostic,
    options: MotionParseOptions,
) (std.mem.Allocator.Error || text.ParseError)!model.Motion {
    try text.admit(source, diagnostic, options.limits);
    if (skeleton.bones.len == 0 or skeleton.bones.len > options.limits.bones) {
        text.report(source, 0, diagnostic, error.LimitExceeded);
        return error.LimitExceeded;
    }
    var counter: Counter = .{ .source = source, .limits = options.limits };
    const frame_count = counter.run() catch |err| {
        text.report(source, counter.offset, diagnostic, err);
        return err;
    };
    const value_count = std.math.mul(usize, frame_count, skeleton.channel_count) catch {
        text.report(source, 0, diagnostic, error.LimitExceeded);
        return error.LimitExceeded;
    };
    if (value_count > options.limits.values) {
        text.report(source, 0, diagnostic, error.LimitExceeded);
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
    for (skeleton.bones, 0..) |bone, index| try names.put(allocator, bone.name, @intCast(index));
    var parser: Parser = .{
        .source = source,
        .skeleton = skeleton,
        .names = &names,
        .frames = frames,
        .values = values,
        .seen = seen,
        .limits = options.limits,
    };
    var motion = parser.run() catch |err| {
        text.report(source, parser.offset, diagnostic, err);
        return err;
    };
    motion.header = try allocator.dupe(u8, motion.header);
    return motion;
}

test parseMotionAlloc {
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
    var skeleton = try @import(
        "skeleton.zig",
    ).parseSkeletonAlloc(allocator, skeleton_source, null, .{});
    defer skeleton.deinit(allocator);
    var motion = try parseMotionAlloc(
        allocator,
        ":DEGREES\n1\nroot 1 2 3 10 20 30\n",
        skeleton.view(),
        null,
        .{},
    );
    defer motion.deinit(allocator);
    const sample = motion.frame(0).?;
    try std.testing.expectEqual(@as(u32, 1), sample.number);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3, 10, 20, 30 }, sample.boneValues(0).?);
}

const Line = struct { bytes: []const u8, offset: usize };

const Lines = struct {
    source: []const u8,
    cursor: usize = 0,

    fn next(self: *Lines) ?Line {
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

const Counter = struct {
    source: []const u8,
    limits: text.Limits,
    offset: usize = 0,

    fn run(self: *Counter) text.ParseError!usize {
        var lines: Lines = .{ .source = self.source };
        var count: usize = 0;
        while (lines.next()) |line| {
            var lexer: text.Lexer = .{
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
                if (text.isIntegerToken(first.text)) {
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
    skeleton: model.SkeletonView,
    names: *const std.StringHashMapUnmanaged(u32),
    frames: []u32,
    values: []f64,
    seen: []bool,
    limits: text.Limits,
    used: usize = 0,
    offset: usize = 0,
    fully_specified: bool = false,
    angle_unit: ?model.AngleUnit = null,
    header_length: usize = 0,

    fn nextToken(self: *Parser, lexer: *text.Lexer) text.ParseError!?text.Token {
        const token = lexer.next() catch |err| {
            self.offset = lexer.offset;
            return err;
        };
        self.offset = lexer.offset;
        return token;
    }

    fn completeFrame(self: *const Parser) text.ParseError!void {
        if (self.used == 0) return;
        if (self.used == 1 or self.fully_specified) {
            for (self.skeleton.bones, self.seen) |bone, present| {
                if (bone.dof_count != 0 and !present) return error.MissingChannels;
            }
        }
    }

    fn directive(self: *Parser, key: []const u8) text.ParseError!void {
        if (self.used != 0) return error.UnsupportedDirective;
        if (std.mem.eql(u8, key, ":FULLY-SPECIFIED")) {
            if (self.fully_specified) return error.DuplicateField;
            self.fully_specified = true;
        } else if (std.mem.eql(u8, key, ":DEGREES") or std.mem.eql(u8, key, ":RADIANS")) {
            if (self.angle_unit != null) return error.DuplicateField;
            self.angle_unit = if (std.mem.eql(u8, key, ":DEGREES")) .degrees else .radians;
        } else return error.UnsupportedDirective;
    }

    fn run(self: *Parser) text.ParseError!model.Motion {
        var lines: Lines = .{ .source = self.source };
        const channel_count = self.skeleton.channel_count;
        while (lines.next()) |line| {
            var lexer: text.Lexer = .{
                .source = line.bytes,
                .limit = self.limits.token_bytes,
                .base = line.offset,
            };
            const first = try self.nextToken(&lexer) orelse continue;
            if (first.text[0] == ':') {
                try self.directive(first.text);
                if (try self.nextToken(&lexer) != null) return error.UnexpectedToken;
            } else if (text.isIntegerToken(first.text)) {
                try self.completeFrame();
                const number = text.integer(first.text) catch return error.InvalidFrame;
                if (number == 0 or (self.used != 0 and number <= self.frames[self.used - 1]))
                    return error.InvalidFrame;
                if (try self.nextToken(&lexer) != null) return error.InvalidFrame;
                if (self.used >= self.frames.len) return error.LimitExceeded;
                if (self.used == 0) {
                    self.header_length = line.offset;
                } else if (!self.fully_specified) {
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
                    if (index == bone.dof_count) return error.ChannelCount;
                    const frame_start = (self.used - 1) * channel_count;
                    const channel_offset = frame_start + bone.channel_offset + index;
                    self.values[channel_offset] = try text.decimal(token.text);
                    index += 1;
                }
                if (index != bone.dof_count) return error.ChannelCount;
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
    const f = @import("fixtures.zig");
    const allocator = std.testing.allocator;
    var skeleton = try @import("skeleton.zig").parseSkeletonAlloc(allocator, f.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    const source = try allocator.dupe(u8, f.motion);
    defer allocator.free(source);
    var motion = try parseMotionAlloc(allocator, source, skeleton.view(), null, .{});
    defer motion.deinit(allocator);
    @memset(source, 0xa5);
    try std.testing.expectEqualSlices(u32, &.{ 1, 3 }, motion.frame_numbers);
    try std.testing.expectEqualSlices(f64, &.{
        1, 2, 3, 4, 5, 6, 7, 8, 9,
    }, motion.frame(0).?.values);
    try std.testing.expectEqualSlices(f64, &.{ 17, 18 }, motion.frame(1).?.boneValues(1).?);
    try std.testing.expectEqualSlices(f64, &.{19}, motion.frame(1).?.boneValues(2).?);
    try std.testing.expectEqual(@as(?model.Sample, null), motion.frame(2));
    try std.testing.expect(std.mem.startsWith(u8, motion.header, "# authored"));
}

test "sparse motion requires a complete first frame then carries omitted segments" {
    const f = @import("fixtures.zig");
    const allocator = std.testing.allocator;
    var skeleton = try @import("skeleton.zig").parseSkeletonAlloc(allocator, f.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    var motion = try parseMotionAlloc(allocator,
        \\:RADIANS
        \\2
        \\root 1 2 3 4 5 6
        \\tip 7 8
        \\base 9
        \\4
        \\tip 10 11
    , skeleton.view(), null, .{});
    defer motion.deinit(allocator);
    try std.testing.expectEqual(model.AngleUnit.radians, motion.angle_unit);
    try std.testing.expectEqualSlices(f64, &.{
        1, 2, 3, 4, 5, 6, 10, 11, 9,
    }, motion.frame(1).?.values);
    try std.testing.expectError(
        error.MissingChannels,
        parseMotionAlloc(allocator, "1\nroot 1 2 3 4 5 6", skeleton.view(), null, .{}),
    );
}

test "motion rejects final omissions, duplicates, wrong arity, frame and numeric failures" {
    const f = @import("fixtures.zig");
    const allocator = std.testing.allocator;
    var skeleton = try @import("skeleton.zig").parseSkeletonAlloc(allocator, f.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    const Case = struct { before: []const u8, after: []const u8, reason: text.ParseError };
    for (
        [_]Case{
            .{ .before = "base 19", .after = "", .reason = error.MissingChannels },
            .{
                .before = "base 19",
                .after = "base 19\nbase 20",
                .reason = error.DuplicateChannels,
            },
            .{ .before = "base 19", .after = "other 19", .reason = error.UnknownBone },
            .{ .before = "base 19", .after = "base 19 20", .reason = error.ChannelCount },
            .{ .before = "base 19", .after = "base", .reason = error.ChannelCount },
            .{ .before = "base 19", .after = "base 1e9999", .reason = error.InvalidNumber },
            .{ .before = "base 19", .after = "base 0x1p2", .reason = error.InvalidNumber },
            .{ .before = "\n3\n", .after = "\n1\n", .reason = error.InvalidFrame },
            .{ .before = "\n3\n", .after = "\n0\n", .reason = error.InvalidFrame },
            .{ .before = ":DEGREES", .after = ":UNKNOWN", .reason = error.UnsupportedDirective },
        },
    ) |case| {
        const source = try std.mem.replaceOwned(u8, allocator, f.motion, case.before, case.after);
        defer allocator.free(source);
        try std.testing.expectError(
            case.reason,
            parseMotionAlloc(allocator, source, skeleton.view(), null, .{}),
        );
    }
}

const AllocationTests = struct {
    pub fn run(allocator: std.mem.Allocator) !void {
        const f = @import("fixtures.zig");
        var skeleton = try @import(
            "skeleton.zig",
        ).parseSkeletonAlloc(allocator, f.skeleton, null, .{});
        defer skeleton.deinit(allocator);
        var first = try parseMotionAlloc(allocator, f.motion, skeleton.view(), null, .{});
        defer first.deinit(allocator);
        var second = try parseMotionAlloc(allocator, f.motion, skeleton.view(), null, .{});
        defer second.deinit(allocator);
        try std.testing.expectEqualSlices(f64, first.values, second.values);
    }
};

test "all allocation failures release partial owners and two clips share one skeleton" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, AllocationTests.run, .{});
}

test "motion diagnostics, CRLF, angle fallback and count limits are explicit" {
    const f = @import("fixtures.zig");
    const allocator = std.testing.allocator;
    var skeleton = try @import("skeleton.zig").parseSkeletonAlloc(allocator, f.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    const bad = try std.mem.replaceOwned(u8, allocator, f.motion, "base 19", "base nan");
    defer allocator.free(bad);
    var diagnostic: text.Diagnostic = undefined;
    try std.testing.expectError(
        error.InvalidNumber,
        parseMotionAlloc(allocator, bad, skeleton.view(), &diagnostic, .{}),
    );
    try std.testing.expectEqual(std.mem.indexOf(u8, bad, "nan").?, diagnostic.offset);
    try std.testing.expectEqual(error.InvalidNumber, diagnostic.reason);
    const crlf = try std.mem.replaceOwned(u8, allocator, f.motion, "\n", "\r\n");
    defer allocator.free(crlf);
    var motion = try parseMotionAlloc(allocator, crlf, skeleton.view(), null, .{});
    defer motion.deinit(allocator);
    try std.testing.expectEqual(model.AngleUnit.degrees, motion.angle_unit);
    for ([_]text.Limits{ .{ .frames = 1 }, .{ .values = 17 }, .{ .bones = 3 } }) |limits| {
        try std.testing.expectError(
            error.LimitExceeded,
            parseMotionAlloc(allocator, f.motion, skeleton.view(), null, .{ .limits = limits }),
        );
    }
}

test "oversized motion tokens report their actual byte and line" {
    const f = @import("fixtures.zig");
    const allocator = std.testing.allocator;
    var skeleton = try @import("skeleton.zig").parseSkeletonAlloc(allocator, f.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    const oversized = "111111111111111111111111111111";
    for ([_][]const u8{ "base " ++ oversized, oversized ++ "name 19" }) |replacement| {
        const source = try std.mem.replaceOwned(u8, allocator, f.motion, "base 19", replacement);
        defer allocator.free(source);
        var diagnostic: text.Diagnostic = undefined;
        try std.testing.expectError(
            error.LimitExceeded,
            parseMotionAlloc(
                allocator,
                source,
                skeleton.view(),
                &diagnostic,
                .{ .limits = .{ .token_bytes = 20 } },
            ),
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
    const f = @import("fixtures.zig");
    for ([_][]const u8{ "-base", "begin", "end", "name" }) |name| {
        const source = try std.mem.replaceOwned(u8, allocator, f.skeleton, "base", name);
        defer allocator.free(source);
        const input = try std.mem.replaceOwned(u8, allocator, f.motion, "base", name);
        defer allocator.free(input);
        var skeleton = try @import("skeleton.zig").parseSkeletonAlloc(allocator, source, null, .{});
        defer skeleton.deinit(allocator);
        var motion = try parseMotionAlloc(allocator, input, skeleton.view(), null, .{});
        defer motion.deinit(allocator);
        try std.testing.expectEqual(@as(?u32, 2), skeleton.view().findBone(name));
        try std.testing.expectEqualSlices(f64, &.{19}, motion.frame(1).?.boneValues(2).?);
    }
    try std.testing.expectError(error.InvalidText, text.identifier("-1"));
    try std.testing.expectError(error.InvalidText, text.identifier("+1"));
}
