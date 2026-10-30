//! Complete owned BVH ingestion, bounded hierarchy materialization and exact sample admission.
const std = @import("std");
const model = @import("model.zig");
const text = @import("text.zig");
const fixtures = @import("fixtures.zig");

/// How frame boundaries are admitted after the motion header.
pub const FrameLayout = enum {
    /// One complete frame per nonblank line; detects missing/extra columns within each row.
    lines,
    /// Whitespace separates all values; frame/channel counts alone determine sample boundaries.
    whitespace,
};

/// Resource and motion-row admission. Parsed values always retain their original meaning/order.
pub const ParseOptions = struct { limits: text.Limits = .{}, frame_layout: FrameLayout = .lines };

/// Reads a complete BVH file into an owned skeleton and frame-major binary64 samples. Supports
/// forests, branching, repeated names, end sites, zero-channel joints and zero-frame clips. Named
/// joints require OFFSET then CHANNELS before children; channel labels are the six standard
/// case-sensitive position/rotation names, each appearing at most once per joint. Rotation order is
/// preserved, including differing orders between joints and nonroot position channels.
///
/// Accepts ASCII tokens/whitespace, LF/CRLF, an optional initial UTF-8 BOM and finite decimal or
/// exponent numbers. Rejects unknown fields/channels, malformed/trailing input, nonpositive frame
/// intervals and nonfinite final sample times. Ordinary whitespace may separate hierarchy/header
/// tokens; frame boundaries follow `frame_layout`. Empty-channel frames require no data rows.
///
/// Copies only the hierarchy text and owns all materialized data; input may retire on success.
/// Retains no allocator. Release the result once with `Motion.deinit`. Failure releases partial
/// allocations and publishes no owner. Success/OutOfMemory leave diagnostics unchanged. A
/// diagnostic overlapping source is refused without writing it; other parse failures set it.
pub fn parseAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostic: ?*text.Diagnostic,
    options: ParseOptions,
) (std.mem.Allocator.Error || text.ParseError)!model.Motion {
    if (diagnostic) |out| {
        if (overlaps(source, std.mem.asBytes(out))) return error.AliasedStorage;
    }
    if (source.len > options.limits.input_bytes) {
        text.report(source, 0, diagnostic, error.LimitExceeded);
        return error.LimitExceeded;
    }
    var lexer = text.Lexer.init(source, options.limits);
    const reservation = reserveHierarchy(&lexer) catch |err| {
        text.report(source, lexer.offset, diagnostic, err);
        return err;
    };
    _ = std.math.mul(usize, reservation.joints, @sizeOf(model.Joint)) catch {
        text.report(source, lexer.offset, diagnostic, error.LimitExceeded);
        return error.LimitExceeded;
    };
    const copy = try allocator.dupe(u8, source[0..reservation.bytes]);
    errdefer allocator.free(copy);
    const joints = try allocator.alloc(model.Joint, reservation.joints);
    errdefer allocator.free(joints);
    var hierarchy: Hierarchy = .{
        .lexer = text.Lexer.init(copy, options.limits),
        .joints = joints,
    };
    const channel_count = hierarchy.read() catch |err| {
        text.report(source, hierarchy.lexer.offset, diagnostic, err);
        return err;
    };
    const header = readMotionHeader(&lexer, channel_count) catch |err| {
        text.report(source, lexer.offset, diagnostic, err);
        return err;
    };
    const values = try allocator.alloc(f64, header.values);
    errdefer allocator.free(values);
    readValues(&lexer, values, header, channel_count, options.frame_layout) catch |err| {
        text.report(source, lexer.offset, diagnostic, err);
        return err;
    };
    return .{
        .skeleton = .{ .joints = joints, .channel_count = channel_count, .source = copy },
        .values = values,
        .frame_count = header.frames,
        .frame_time = header.interval,
    };
}

test parseAlloc {
    const allocator = std.testing.allocator;
    const source =
        "HIERARCHY\n" ++
        "ROOT Hips { OFFSET 0 0 0 CHANNELS 6 Xposition Yposition Zposition Zrotation " ++
        "Xrotation Yrotation\n  End Site { OFFSET 0 2 0 }\n}\nMOTION\nFrames: 2\n" ++
        "Frame Time: 0.016667\n1 2 3 90 0 0\n4 5 6 0 0 0";
    var motion = try parseAlloc(allocator, source, null, .{});
    defer motion.deinit(allocator);
    const sample = motion.frame(1).?;
    try std.testing.expectEqual(0.016667, sample.time);
    try std.testing.expectEqualSlices(f64, &.{ 4, 5, 6, 0, 0, 0 }, sample.jointValues(0).?);
    try std.testing.expectEqual(0, sample.jointValues(1).?.len);
    try std.testing.expect(motion.frame(2) == null);
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Reservation = struct { joints: u32, bytes: usize };

fn reserveHierarchy(lexer: *text.Lexer) text.ParseError!Reservation {
    var count: u32 = 0;
    var depth: u32 = 0;
    var name = false;
    // Braces give exact node capacity on a valid hierarchy. Skip names even when they are ROOT,
    // JOINT or MOTION. The materializing parser still validates every structural field.
    while (try lexer.next()) |token| {
        const word = token.bytes;
        if (name) {
            name = false;
        } else if (same(word, "ROOT") or same(word, "JOINT")) {
            name = true;
        } else if (same(word, "{")) {
            if (count >= lexer.limits.joints or depth >= lexer.limits.depth)
                return error.LimitExceeded;
            count += 1;
            depth += 1;
        } else if (same(word, "}")) {
            if (depth == 0) return error.InvalidHierarchy;
            depth -= 1;
        } else if (depth == 0 and same(word, "MOTION")) {
            if (count == 0) return error.InvalidHierarchy;
            return .{ .joints = count, .bytes = token.offset };
        }
    }
    return error.UnexpectedEnd;
}

fn channel(bytes: []const u8) text.ParseError!model.Channel {
    const labels = .{
        "Xposition", "Yposition", "Zposition", "Xrotation", "Yrotation", "Zrotation",
    };
    inline for (labels, 0..) |name, index| {
        if (same(bytes, name)) return @fromBackingInt(@intCast(index));
    }
    return error.UnsupportedChannel;
}

const Hierarchy = struct {
    lexer: text.Lexer,
    joints: []model.Joint,
    used: u32 = 0,
    channels: u32 = 0,
    depth: u32 = 0,

    fn append(self: *Hierarchy, joint: model.Joint) text.ParseError!u32 {
        if (self.used >= self.joints.len) return error.InvalidHierarchy;
        if (self.depth >= self.lexer.limits.depth) return error.LimitExceeded;
        const index = self.used;
        self.joints[index] = joint;
        self.used += 1;
        return index;
    }

    fn named(self: *Hierarchy, parent: ?u32) text.ParseError!u32 {
        const name = (try self.lexer.take()).bytes;
        if (same(name, "{") or same(name, "}")) return error.InvalidText;
        try self.lexer.expect("{");
        try self.lexer.expect("OFFSET");
        const offset = try self.lexer.vector();
        try self.lexer.expect("CHANNELS");
        const count = try text.integer((try self.lexer.take()).bytes);
        if (count > 6) return error.ChannelCount;
        var joint: model.Joint = .{
            .name = name,
            .parent = parent,
            .offset = offset,
            .channel_count = @intCast(count),
            .channel_offset = self.channels,
        };
        var seen: u8 = 0;
        for (joint.channels[0..count]) |*out| {
            out.* = try channel((try self.lexer.take()).bytes);
            const mask = @as(u8, 1) << @intCast(@backingInt(out.*));
            if (seen & mask != 0) return error.DuplicateChannel;
            seen |= mask;
        }
        self.channels = std.math.add(u32, self.channels, count) catch return error.LimitExceeded;
        const index = try self.append(joint);
        self.depth += 1;
        return index;
    }

    fn endSite(self: *Hierarchy, parent: u32) text.ParseError!void {
        try self.lexer.expect("Site");
        try self.lexer.expect("{");
        try self.lexer.expect("OFFSET");
        const offset = try self.lexer.vector();
        try self.lexer.expect("}");
        _ = try self.append(
            .{ .name = null, .parent = parent, .offset = offset, .channel_offset = self.channels },
        );
    }

    fn read(self: *Hierarchy) text.ParseError!u32 {
        try self.lexer.expect("HIERARCHY");
        var parent: ?u32 = null;
        while (try self.lexer.next()) |token| {
            if (parent) |current| {
                if (same(token.bytes, "JOINT")) {
                    parent = try self.named(current);
                } else if (same(token.bytes, "End")) {
                    try self.endSite(current);
                } else if (same(token.bytes, "}")) {
                    parent = self.joints[current].parent;
                    self.depth -= 1;
                } else return error.UnexpectedToken;
            } else {
                if (!same(token.bytes, "ROOT")) return error.UnexpectedToken;
                parent = try self.named(null);
            }
        }
        if (parent != null) return error.UnexpectedEnd;
        if (self.used == 0 or self.used != self.joints.len) return error.InvalidHierarchy;
        return self.channels;
    }
};

const MotionHeader = struct { frames: u32, interval: f64, values: usize, line: usize };

fn label(lexer: *text.Lexer, word: []const u8) text.ParseError!void {
    const token = (try lexer.take()).bytes;
    if (std.mem.endsWith(u8, token, ":") and same(token[0 .. token.len - 1], word)) return;
    if (!same(token, word)) return error.UnexpectedToken;
    try lexer.expect(":");
}

fn readMotionHeader(lexer: *text.Lexer, width: u32) text.ParseError!MotionHeader {
    try label(lexer, "Frames");
    const frames = try text.integer((try lexer.take()).bytes);
    if (frames > lexer.limits.frames) return error.LimitExceeded;
    try lexer.expect("Frame");
    try label(lexer, "Time");
    const token = try lexer.take();
    const interval = try text.decimal(token.bytes);
    if (interval <= 0 or !std.math.isFinite(
        interval * @as(f64, @floatFromInt(frames -| 1)),
    )) return error.InvalidTiming;
    const count = std.math.mul(usize, frames, width) catch return error.LimitExceeded;
    if (count > lexer.limits.values) return error.LimitExceeded;
    _ = std.math.mul(usize, count, @sizeOf(f64)) catch return error.LimitExceeded;
    return .{ .frames = frames, .interval = interval, .values = count, .line = token.line };
}

fn readValues(
    lexer: *text.Lexer,
    values: []f64,
    header: MotionHeader,
    width: u32,
    layout: FrameLayout,
) text.ParseError!void {
    if (width != 0) {
        var previous_line = header.line;
        for (0..header.frames) |frame| {
            const first = try lexer.take();
            if (layout == .lines and first.line <= previous_line) return error.ChannelCount;
            const output = values[frame * width ..][0..width];
            output[0] = try text.decimal(first.bytes);
            for (output[1..]) |*out| {
                const token = try lexer.take();
                if (layout == .lines and token.line != first.line) return error.ChannelCount;
                out.* = try text.decimal(token.bytes);
            }
            if (layout == .lines) {
                if (try lexer.peek()) |next| {
                    if (next.line == first.line) return error.ChannelCount;
                }
            }
            previous_line = first.line;
        }
    }
    if (try lexer.next() != null) return error.UnexpectedToken;
}

test "BVH owns original names, hierarchy and every channel after source retirement" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, fixtures.simple);
    defer allocator.free(source);
    var motion = try parseAlloc(allocator, source, null, .{});
    defer motion.deinit(allocator);
    @memset(source, 0xa5);
    const skeleton = motion.skeleton.view();
    try std.testing.expectEqual(3, skeleton.joints.len);
    try std.testing.expectEqual(9, skeleton.channel_count);
    try std.testing.expectEqualStrings("Hips", skeleton.joints[0].name.?);
    try std.testing.expectEqualStrings("Knee", skeleton.joints[1].name.?);
    try std.testing.expect(skeleton.joints[2].name == null);
    try std.testing.expectEqual(@as(?u32, null), skeleton.joints[0].parent);
    try std.testing.expectEqual(@as(?u32, 0), skeleton.joints[1].parent);
    try std.testing.expectEqual(@as(?u32, 1), skeleton.joints[2].parent);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, &skeleton.joints[0].offset);
    try std.testing.expectEqualSlices(f64, &.{ 0, 4, 0 }, &skeleton.joints[1].offset);
    try std.testing.expectEqualSlices(f64, &.{ 0, 2, 0 }, &skeleton.joints[2].offset);
    try std.testing.expectEqualSlices(model.Channel, &.{
        .tx, .ty, .tz, .rz, .rx, .ry,
    }, skeleton.joints[0].channelOrder());
    try std.testing.expectEqualSlices(model.Channel, &.{
        .rx, .ry, .rz,
    }, skeleton.joints[1].channelOrder());
    try std.testing.expectEqualSlices(f64, &.{
        1, 2, 3, 90, 0, 0, 0, 90, 0, -1, -2, -3, 0, 90, 0, 45, 0, -45,
    }, motion.values);
    try std.testing.expectEqual(0.125, motion.frame_time);
    try std.testing.expectEqual(2, motion.frame_count);
    try std.testing.expectEqual(0.125, motion.frame(1).?.time);
    try std.testing.expectEqualSlices(f64, &.{ 45, 0, -45 }, motion.frame(1).?.jointValues(1).?);
    try std.testing.expectEqual(0, motion.frame(0).?.jointValues(2).?.len);
    try std.testing.expect(motion.frame(0).?.jointValues(3) == null);
    try std.testing.expect(motion.frame(std.math.maxInt(usize)) == null);
}

test "BVH forests preserve repeated and keyword names, zero channels and nonroot positions" {
    var motion = try parseAlloc(std.testing.allocator, fixtures.forest, null, .{});
    defer motion.deinit(std.testing.allocator);
    const joints = motion.skeleton.joints;
    try std.testing.expectEqual(6, joints.len);
    try std.testing.expectEqualStrings("MOTION", joints[0].name.?);
    try std.testing.expectEqualStrings("ROOT", joints[1].name.?);
    try std.testing.expectEqualStrings("ROOT", joints[4].name.?);
    try std.testing.expectEqualStrings("mixamorig:JOINT", joints[5].name.?);
    try std.testing.expectEqual(@as(?u32, null), joints[4].parent);
    try std.testing.expectEqual(@as(?u32, 4), joints[5].parent);
    try std.testing.expectEqual(7, motion.skeleton.channel_count);
    try std.testing.expectEqualSlices(model.Channel, &.{
        .rz, .tx, .ry, .tz, .rx, .ty,
    }, joints[1].channelOrder());
    try std.testing.expectEqualSlices(f64, &.{
        30, 1, 20, 2, 10, 3,
    }, motion.frame(0).?.jointValues(1).?);
    try std.testing.expectEqualSlices(f64, &.{4}, motion.frame(0).?.jointValues(5).?);
    try std.testing.expectEqual(0, motion.frame(0).?.jointValues(3).?.len);
}

test "BVH empty clips and empty-channel frames retain exact timing" {
    const cases = .{ .{ "0", "0.016667", 0 }, .{ "3", "0.5", 3 } };
    inline for (cases) |case| {
        const source = "HIERARCHY ROOT 17 {OFFSET 0 0 0 CHANNELS 0} MOTION Frames: " ++
            case[0] ++
            " Frame Time: " ++
            case[1];
        var motion = try parseAlloc(std.testing.allocator, source, null, .{});
        defer motion.deinit(std.testing.allocator);
        try std.testing.expectEqual(case[2], motion.frame_count);
        try std.testing.expectEqual(0, motion.values.len);
        try std.testing.expectEqualStrings("17", motion.skeleton.joints[0].name.?);
        if (case[2] != 0) {
            try std.testing.expectEqual(1, motion.frame(2).?.time);
            try std.testing.expectEqual(0, motion.frame(2).?.values.len);
        }
    }
}

test "BVH frame layouts distinguish row admission from compact or wrapped values" {
    const allocator = std.testing.allocator;
    const prefix =
        "HIERARCHY ROOT a { OFFSET 0 0 0 CHANNELS 2 Xposition Zrotation } MOTION Frames : 2 " ++
        "Frame Time : .25";
    for ([_][]const u8{ "\n1 2\n3 4\n", " 1 2 3 4", "\n1\n2\n3\n4" }, 0..) |rows, index| {
        const source = try std.mem.concat(allocator, u8, &.{ prefix, rows });
        defer allocator.free(source);
        var motion = try parseAlloc(allocator, source, null, .{ .frame_layout = .whitespace });
        defer motion.deinit(allocator);
        try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3, 4 }, motion.values);
        if (index != 0) try std.testing.expectError(
            error.ChannelCount,
            parseAlloc(allocator, source, null, .{}),
        );
    }
    try std.testing.expectError(
        error.ChannelCount,
        parseAlloc(allocator, prefix ++ "\n1\n2 3 4", null, .{}),
    );
    try std.testing.expectError(
        error.ChannelCount,
        parseAlloc(allocator, prefix ++ "\n1 2 3\n4", null, .{}),
    );
    var blank = try parseAlloc(allocator, prefix ++ "\n\n1 2\n \t\n3 4\n\n", null, .{});
    defer blank.deinit(allocator);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3, 4 }, blank.values);
}

test "BVH ASCII admission preserves BOM, CRLF, decimal exponents and negative zero" {
    var motion = try parseAlloc(
        std.testing.allocator,
        "\xef\xbb\xbfHIERARCHY\r\n" ++
            "ROOT x{OFFSET +.5 -2. 3e-1 CHANNELS 2 Xposition Xrotation}\r\nMOTION\r\n" ++
            "Frames: 1\r\nFrame Time: 1e-2\r\n-0 +1.25E+2\r\n",
        null,
        .{},
    );
    defer motion.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(f64, &.{ 0.5, -2, 0.3 }, &motion.skeleton.joints[0].offset);
    try std.testing.expectEqual(0.01, motion.frame_time);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(motion.values[0])));
    try std.testing.expectEqual(125, motion.values[1]);
}

test "BVH rejects malformed hierarchy, channel sets, numeric and motion framing" {
    const allocator = std.testing.allocator;
    const Case = struct { source: []const u8, reason: text.ParseError };
    const prefix =
        "HIERARCHY ROOT a { OFFSET 0 0 0 CHANNELS 1 Xposition } MOTION Frames: 1 Frame Time: .25\n";
    const cases = [_]Case{
        .{
            .source = "",
            .reason = error.UnexpectedEnd,
        },
        .{ .source = "HIERARCHY MOTION Frames: 0 Frame Time: 1", .reason = error.InvalidHierarchy },
        .{ .source = "HIERARCHY } MOTION", .reason = error.InvalidHierarchy },
        .{
            .source = "OTHER ROOT a { OFFSET 0 0 0 CHANNELS 0 } MOTION",
            .reason = error.UnexpectedToken,
        },
        .{
            .source = "HIERARCHY ROOT a { CHANNELS 0 OFFSET 0 0 0 } MOTION",
            .reason = error.UnexpectedToken,
        },
        .{
            .source = "HIERARCHY ROOT a { OFFSET 0 0 0 CHANNELS 0 OFFSET 0 0 0 } MOTION",
            .reason = error.UnexpectedToken,
        },
        .{
            .source = "HIERARCHY ROOT a { OFFSET 0 0 0 CHANNELS 1 Wrotation } MOTION",
            .reason = error.UnsupportedChannel,
        },
        .{
            .source = "HIERARCHY ROOT a { OFFSET 0 0 0 CHANNELS 2 Xposition Xposition } MOTION",
            .reason = error.DuplicateChannel,
        },
        .{
            .source = "HIERARCHY ROOT a { OFFSET 0 0 0 CHANNELS 7 } MOTION",
            .reason = error.ChannelCount,
        },
        .{
            .source = "HIERARCHY ROOT a { OFFSET nan 0 0 CHANNELS 0 } MOTION",
            .reason = error.InvalidNumber,
        },
        .{
            .source = "HIERARCHY ROOT a { OFFSET 0 0 0 CHANNELS 0 End Site { OFFSET 0 0 0 " ++
                "CHANNELS 0 } } MOTION",
            .reason = error.UnexpectedToken,
        },
        .{ .source = prefix, .reason = error.UnexpectedEnd },
        .{ .source = prefix ++
            "1\n2\n", .reason = error.UnexpectedToken },
        .{ .source = prefix ++
            "1 2\n", .reason = error.ChannelCount },
        .{ .source = prefix ++
            "1xyz\n", .reason = error.InvalidNumber },
        .{ .source = prefix ++
            "nan\n", .reason = error.InvalidNumber },
        .{ .source = prefix ++
            "inf\n", .reason = error.InvalidNumber },
        .{ .source = prefix ++
            "1e309\n", .reason = error.InvalidNumber },
        .{ .source = prefix ++
            "0x1p0\n", .reason = error.InvalidNumber },
        .{ .source = prefix ++
            "1_000\n", .reason = error.InvalidNumber },
        .{ .source = prefix ++
            "1e\n", .reason = error.InvalidNumber },
        .{ .source = prefix ++
            ".\n", .reason = error.InvalidNumber },
        .{ .source = prefix ++
            "\x001\n", .reason = error.InvalidText },
        .{ .source = prefix ++
            "1\r", .reason = error.InvalidText },
        .{ .source = prefix ++
            "1\n# tail", .reason = error.UnexpectedToken },
    };
    for (cases) |case| {
        var diagnostic: text.Diagnostic = undefined;
        try std.testing.expectError(
            case.reason,
            parseAlloc(allocator, case.source, &diagnostic, .{}),
        );
        try std.testing.expectEqual(case.reason, diagnostic.reason);
        try std.testing.expect(diagnostic.offset <= case.source.len);
        try std.testing.expectEqual(
            1 + std.mem.count(u8, case.source[0..diagnostic.offset], "\n"),
            diagnostic.line,
        );
    }
}

test "BVH frame counts and intervals admit only finite representable sample times" {
    const allocator = std.testing.allocator;
    const prefix = "HIERARCHY ROOT a { OFFSET 0 0 0 CHANNELS 0 } MOTION Frames: ";
    for ([_][]const u8{ "-1", "+1", "1.0", "4294967296" }) |count| {
        const source = try std.mem.concat(allocator, u8, &.{ prefix, count, " Frame Time: 1" });
        defer allocator.free(source);
        try std.testing.expectError(error.InvalidNumber, parseAlloc(allocator, source, null, .{}));
    }
    for ([_][]const u8{ "0", "-0", "-1", "1e-9999", "1e308" }) |interval| {
        const source = try std.mem.concat(allocator, u8, &.{ prefix, "3 Frame Time: ", interval });
        defer allocator.free(source);
        try std.testing.expectError(error.InvalidTiming, parseAlloc(allocator, source, null, .{}));
    }
    var subnormal = try parseAlloc(allocator, prefix ++ "1 Frame Time: 5e-324", null, .{});
    defer subnormal.deinit(allocator);
    try std.testing.expect(subnormal.frame_time > 0);
}

test "BVH reports exact bad-token location and leaves successful/OOM diagnostics unchanged" {
    const allocator = std.testing.allocator;
    const invalid =
        "HIERARCHY\nROOT x { OFFSET 0 0 0 CHANNELS 0 }\nMOTION\nFrames: 0\nFrame Time: nope\n";
    var diagnostic: text.Diagnostic = .{ .offset = 999, .line = 999, .reason = error.InvalidText };
    try std.testing.expectError(
        error.InvalidNumber,
        parseAlloc(allocator, invalid, &diagnostic, .{}),
    );
    try std.testing.expectEqual(std.mem.indexOf(u8, invalid, "nope").?, diagnostic.offset);
    try std.testing.expectEqual(5, diagnostic.line);
    const before = diagnostic;
    var motion = try parseAlloc(allocator, fixtures.simple, &diagnostic, .{});
    defer motion.deinit(allocator);
    try std.testing.expectEqualDeep(before, diagnostic);
    try std.testing.expectError(
        error.OutOfMemory,
        parseAlloc(std.testing.failing_allocator, fixtures.simple, &diagnostic, .{}),
    );
    try std.testing.expectEqualDeep(before, diagnostic);
    var overlapping: [
        @sizeOf(
            text.Diagnostic,
        ) + 16
    ]u8 align(@alignOf(text.Diagnostic)) = @splat('x');
    const aliased: *text.Diagnostic = @ptrCast(&overlapping);
    const old = overlapping;
    try std.testing.expectError(
        error.AliasedStorage,
        parseAlloc(allocator, &overlapping, aliased, .{}),
    );
    try std.testing.expectEqualSlices(u8, &old, &overlapping);
}

test "BVH independent source, line, token, joint, depth, frame and value limits" {
    const allocator = std.testing.allocator;
    const source = fixtures.simple;
    const limits = [_]text.Limits{
        .{ .input_bytes = source.len - 1 },
        .{ .line_bytes = 10 },
        .{ .token_bytes = 5 },
        .{ .joints = 2 },
        .{ .depth = 2 },
        .{ .frames = 1 },
        .{ .values = 17 },
    };
    for (
        limits,
    ) |limit| try std.testing.expectError(
        error.LimitExceeded,
        parseAlloc(allocator, source, null, .{ .limits = limit }),
    );
    var exact = try parseAlloc(
        allocator,
        source,
        null,
        .{
            .limits = .{
                .input_bytes = source.len,
                .joints = 3,
                .depth = 3,
                .frames = 2,
                .values = 18,
            },
        },
    );
    defer exact.deinit(allocator);
    try std.testing.expectEqual(18, exact.values.len);
}

fn allocationCase(allocator: std.mem.Allocator, source: []const u8, valid: bool) !void {
    if (valid) {
        var motion = try parseAlloc(allocator, source, null, .{});
        defer motion.deinit(allocator);
        try std.testing.expectEqual(18, motion.values.len);
    } else {
        var motion = parseAlloc(allocator, source, null, .{}) catch |err| switch (err) {
            error.InvalidNumber => return,
            else => return err,
        };
        defer motion.deinit(allocator);
        return error.ExpectedFailure;
    }
}

test "BVH frees every partial owner on allocator and late lexical failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{
        fixtures.simple, true,
    });
    const invalid = fixtures.simple[0 .. fixtures.simple.len - 3] ++ "nan";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{
        invalid, false,
    });
}

test "BVH keeps every intrinsic rotation order independently on each joint" {
    const Case = struct { labels: []const u8, expected: [3]model.Channel };
    const cases = [_]Case{ .{ .labels = "Xrotation Yrotation Zrotation", .expected = .{
        .rx, .ry, .rz,
    } }, .{ .labels = "Xrotation Zrotation Yrotation", .expected = .{
        .rx, .rz, .ry,
    } }, .{ .labels = "Yrotation Xrotation Zrotation", .expected = .{
        .ry, .rx, .rz,
    } }, .{ .labels = "Yrotation Zrotation Xrotation", .expected = .{
        .ry, .rz, .rx,
    } }, .{ .labels = "Zrotation Xrotation Yrotation", .expected = .{
        .rz, .rx, .ry,
    } }, .{ .labels = "Zrotation Yrotation Xrotation", .expected = .{ .rz, .ry, .rx } } };
    const allocator = std.testing.allocator;
    for (cases) |case| {
        const source = try std.mem.concat(
            allocator,
            u8,
            &.{
                "HIERARCHY ROOT a {OFFSET 0 0 0 CHANNELS 3 ",
                case.labels,
                " JOINT b {OFFSET 0 1 0 CHANNELS 3 Zrotation Yrotation Xrotation}} MOTION " ++
                    "Frames: 1 Frame Time: 1\n10 20 30 40 50 60",
            },
        );
        defer allocator.free(source);
        var motion = try parseAlloc(allocator, source, null, .{});
        defer motion.deinit(allocator);
        try std.testing.expectEqualSlices(
            model.Channel,
            &case.expected,
            motion.skeleton.joints[0].channelOrder(),
        );
        try std.testing.expectEqualSlices(model.Channel, &.{
            .rz, .ry, .rx,
        }, motion.skeleton.joints[1].channelOrder());
        try std.testing.expectEqualSlices(f64, &.{ 10, 20, 30, 40, 50, 60 }, motion.values);
    }
}

test "BVH nesting uses parent links rather than recursive parser stack" {
    const allocator = std.testing.allocator;
    var source: std.Io.Writer.Allocating = .init(allocator);
    defer source.deinit();
    try source.writer.writeAll("HIERARCHY ROOT a { OFFSET 0 0 0 CHANNELS 0 ");
    for (1..1024) |_| try source.writer.writeAll("JOINT a { OFFSET 0 1 0 CHANNELS 0 ");
    for (0..1024) |_| try source.writer.writeAll("}");
    try source.writer.writeAll(" MOTION Frames: 1 Frame Time: 1");
    try std.testing.expectError(
        error.LimitExceeded,
        parseAlloc(allocator, source.written(), null, .{}),
    );
    var motion = try parseAlloc(
        allocator,
        source.written(),
        null,
        .{ .limits = .{ .depth = 1024 } },
    );
    defer motion.deinit(allocator);
    try std.testing.expectEqual(1024, motion.skeleton.joints.len);
    try std.testing.expectEqual(@as(?u32, 1022), motion.skeleton.joints[1023].parent);
    try std.testing.expectEqual(0, motion.frame(0).?.values.len);
}

test "BVH structural and early sample truncations never publish a partial motion" {
    const allocator = std.testing.allocator;
    const last_value = std.mem.lastIndexOf(u8, fixtures.simple, "-45").?;
    for (0..last_value + 1) |end| {
        var motion = parseAlloc(allocator, fixtures.simple[0..end], null, .{}) catch continue;
        defer motion.deinit(allocator);
        return error.UnexpectedPartialMotion;
    }
}

test "BVH storage-byte representability is checked before sample allocation" {
    const source =
        "HIERARCHY ROOT a { OFFSET 0 0 0 CHANNELS 1 Xposition } MOTION Frames: 536870912 Frame " ++
        "Time: 1";
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var diagnostic: text.Diagnostic = undefined;
    const reason = if (@sizeOf(usize) == 4) error.LimitExceeded else error.OutOfMemory;
    try std.testing.expectError(
        reason,
        parseAlloc(
            failing.allocator(),
            source,
            &diagnostic,
            .{ .limits = .{ .frames = std.math.maxInt(u32), .values = std.math.maxInt(usize) } },
        ),
    );
    if (@sizeOf(usize) == 4) try std.testing.expectEqual(error.LimitExceeded, diagnostic.reason);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

// Address-only alias admission; empty spans are disjoint and pointer-end addition is avoided.
fn overlaps(first: []const u8, second: []const u8) bool {
    if (first.len == 0 or second.len == 0) return false;
    const first_address = @intFromPtr(first.ptr);
    const second_address = @intFromPtr(second.ptr);
    return if (first_address <= second_address) second_address - first_address < first
        .len else first_address - second_address < second.len;
}
