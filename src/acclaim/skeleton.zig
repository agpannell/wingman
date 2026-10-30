//! ASF materialization, named hierarchy admission and owned skeleton lifetimes.
const std = @import("std");
const model = @import("model.zig");
const text = @import("text.zig");

/// Skeleton admission and preservation of uninterpreted top-level metadata.
pub const SkeletonParseOptions = struct {
    limits: text.Limits = .{},
    unknown_sections: enum { preserve, reject } = .preserve,
};

/// Copies ASF and constructs a reusable skeleton with exact owned backing. Bone zero is root;
/// remaining records preserve declaration order. Validates unique identities, channel arity,
/// required geometry, limits and a single connected acyclic hierarchy. File scale and angles remain
/// declared values. No output owner escapes failure; partial allocations are released.
pub fn parseSkeletonAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostic: ?*text.Diagnostic,
    options: SkeletonParseOptions,
) (std.mem.Allocator.Error || text.ParseError)!model.Skeleton {
    try text.admit(source, diagnostic, options.limits);
    const count = try countBones(source, options.limits.bones, diagnostic);
    const copy = try allocator.dupe(u8, source);
    errdefer allocator.free(copy);
    const bones = try allocator.alloc(model.Bone, count);
    errdefer allocator.free(bones);
    const topology = try allocator.alloc(u32, count);
    errdefer allocator.free(topology);
    const depths = try allocator.alloc(u32, count);
    defer allocator.free(depths);
    @memset(depths, 0);
    var parser: Parser = .{
        .lexer = .{ .source = copy, .limit = options.limits.token_bytes },
        .bones = bones,
        .topology = topology,
        .depths = depths,
        .options = options,
    };
    return parser.run() catch |err| {
        text.report(source, parser.lexer.offset, diagnostic, err);
        return err;
    };
}

test parseSkeletonAlloc {
    const source =
        \\:version 1.10
        \\:name stationary_root
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
    var skeleton = try parseSkeletonAlloc(std.testing.allocator, source, null, .{});
    defer skeleton.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 0), skeleton.view().findBone("root"));
    try std.testing.expectEqual(@as(u32, 6), skeleton.channel_count);
}

fn countBones(source: []const u8, limit: u32, diagnostic: ?*text.Diagnostic) text.ParseError!usize {
    var count: usize = 1;
    var in_bones = false;
    if (limit == 0) {
        text.report(source, 0, diagnostic, error.LimitExceeded);
        return error.LimitExceeded;
    }
    // This reservation pass needs only section boundaries and exact `begin` tokens. The owning
    // parse still checks every token and its length before publishing a skeleton. Compact blocks
    // may contain several bones per line.
    var cursor: usize = 0;
    var first = true;
    var name_value = false;
    while (cursor < source.len) {
        const byte = source[cursor];
        if (byte == '#') {
            while (cursor < source.len and source[cursor] != '\n') cursor += 1;
            continue;
        }
        if (std.ascii.isWhitespace(byte)) {
            if (byte == '\n') first = true;
            cursor += 1;
            continue;
        }
        const start = cursor;
        cursor += 1;
        if (byte != '(' and byte != ')') {
            while (cursor < source.len and !boundary(
                source[cursor],
            ) and source[cursor] != '#') cursor += 1;
        }
        const token = source[start..cursor];
        if (first and byte == ':') in_bones = std.mem.eql(u8, token, ":bonedata");
        first = false;
        if (!in_bones) continue;
        if (name_value) {
            name_value = false;
            continue;
        }
        if (std.mem.eql(u8, token, "name")) {
            name_value = true;
            continue;
        }
        if (!std.mem.eql(u8, token, "begin")) continue;
        if (count >= limit) {
            text.report(source, start, diagnostic, error.LimitExceeded);
            return error.LimitExceeded;
        }
        count += 1;
    }
    return count;
}

fn boundary(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == '(' or byte == ')';
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn order(bytes: []const u8) text.ParseError!model.RotationOrder {
    inline for (.{
        model.RotationOrder.xyz, model.RotationOrder.xzy, model.RotationOrder.yxz,
        model.RotationOrder.yzx, model.RotationOrder.zxy, model.RotationOrder.zyx,
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(bytes, @tagName(candidate))) return candidate;
    }
    return error.UnexpectedToken;
}

fn channel(bytes: []const u8) ?model.Channel {
    inline for (.{
        model.Channel.tx, model.Channel.ty, model.Channel.tz, model.Channel.rx, model.Channel.ry,
        model.Channel.rz, model.Channel.l,
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(bytes, @tagName(candidate))) return candidate;
    }
    return null;
}

fn mark(bits: *u8, mask: u8) text.ParseError!void {
    if (bits.* & mask != 0) return error.DuplicateField;
    bits.* |= mask;
}

const Parser = struct {
    lexer: text.Lexer,
    bones: []model.Bone,
    topology: []u32,
    depths: []u32,
    options: SkeletonParseOptions,
    used: usize = 1,
    sections: u8 = 0,
    root_fields: u8 = 0,
    unit_fields: u8 = 0,
    units: model.Units = .{ .angle = .degrees },
    name: []const u8 = "",
    documentation: []const u8 = "",

    fn nextField(self: *Parser) text.ParseError!?text.Token {
        if (try self.lexer.peek()) |token| {
            if (token.line_start and token.text[0] == ':') return null;
            return try self.lexer.next();
        }
        return null;
    }

    fn skipSection(self: *Parser) text.ParseError![]const u8 {
        const start = self.lexer.cursor;
        while (try self.nextField()) |_| {}
        const end = if (try self.lexer.peek()) |next| next.offset else self.lexer.source.len;
        return std.mem.trim(u8, self.lexer.source[start..end], " \t\r\n");
    }

    fn parseUnits(self: *Parser) text.ParseError!void {
        while (try self.nextField()) |key| {
            if (same(key.text, "mass") or same(key.text, "length")) {
                const mask: u8 = if (same(key.text, "mass")) 1 else 2;
                try mark(&self.unit_fields, mask);
                const value = try self.lexer.number();
                if (value <= 0) return error.InvalidNumber;
                if (mask == 1) self.units.mass = value else self.units.length = value;
            } else if (same(key.text, "angle")) {
                try mark(&self.unit_fields, 4);
                const value = (try self.lexer.take()).text;
                self.units.angle = if (std.ascii.eqlIgnoreCase(
                    value,
                    "deg",
                )) .degrees else if (std.ascii.eqlIgnoreCase(
                    value,
                    "rad",
                )) .radians else return error.UnexpectedToken;
            } else {
                // Additional unit labels are opaque metadata, preserved in the copied source.
                while (try self.lexer.peek()) |next| {
                    if (next.line_start) break;
                    _ = try self.lexer.next();
                }
            }
        }
    }

    fn parseChannels(self: *Parser, bone: *model.Bone, root: bool) text.ParseError!void {
        var bits: u8 = 0;
        while (try self.lexer.peek()) |next| {
            const value = channel(next.text) orelse break;
            _ = try self.lexer.next();
            if (root and value == .l) return error.UnsupportedField;
            const channel_index: u3 = @intCast(@backingInt(value));
            const mask = @as(u8, 1) << channel_index;
            if (bits & mask != 0) return error.DuplicateChannels;
            bits |= mask;
            if (bone.dof_count == bone.dofs.len) return error.ChannelCount;
            bone.dofs[bone.dof_count] = value;
            bone.dof_count += 1;
        }
    }

    fn parseRoot(self: *Parser) text.ParseError!void {
        while (try self.nextField()) |key| {
            if (same(key.text, "order")) {
                try mark(&self.root_fields, 1);
                try self.parseChannels(&self.bones[0], true);
            } else if (same(key.text, "axis")) {
                try mark(&self.root_fields, 2);
                self.bones[0].axis_order = try order((try self.lexer.take()).text);
            } else if (same(key.text, "position")) {
                try mark(&self.root_fields, 4);
                self.bones[0].position = try self.lexer.vector();
            } else if (same(key.text, "orientation")) {
                try mark(&self.root_fields, 8);
                self.bones[0].axis = try self.lexer.vector();
            } else return error.UnsupportedField;
        }
        if (self.root_fields != 15) return error.MissingField;
    }

    fn bound(self: *Parser) text.ParseError!f64 {
        const token = (try self.lexer.take()).text;
        if (same(token, "-inf")) return -std.math.inf(f64);
        if (same(token, "inf") or same(token, "+inf")) return std.math.inf(f64);
        return text.decimal(token);
    }

    fn parseBone(self: *Parser) text.ParseError!void {
        if (self.used >= self.bones.len) return error.LimitExceeded;
        var bone: model.Bone = .{ .name = "" };
        var fields: u8 = 0;
        while (true) {
            const key = (try self.lexer.take()).text;
            if (same(key, "end")) break;
            if (same(key, "id")) {
                try mark(&fields, 1);
                bone.id = try text.integer((try self.lexer.take()).text);
                if (bone.id == 0) return error.DuplicateBone;
            } else if (same(key, "name")) {
                try mark(&fields, 2);
                bone.name = (try self.lexer.take()).text;
                try text.identifier(bone.name);
            } else if (same(key, "direction")) {
                try mark(&fields, 4);
                bone.direction = try self.lexer.vector();
            } else if (same(key, "length")) {
                try mark(&fields, 8);
                bone.length = try self.lexer.number();
                if (bone.length < 0) return error.InvalidNumber;
            } else if (same(key, "axis")) {
                try mark(&fields, 16);
                bone.axis = try self.lexer.vector();
                bone.axis_order = try order((try self.lexer.take()).text);
            } else if (same(key, "dof")) {
                try mark(&fields, 32);
                try self.parseChannels(&bone, false);
            } else if (same(key, "limits")) {
                try mark(&fields, 64);
                if (fields & 32 == 0) return error.MissingField;
                for (0..bone.dof_count) |index| {
                    try self.lexer.expect("(");
                    const lower = try self.bound();
                    const upper = try self.bound();
                    if (lower > upper) return error.InvalidNumber;
                    try self.lexer.expect(")");
                    bone.limits[index] = .{ .lower = lower, .upper = upper };
                }
            } else return error.UnsupportedField;
        }
        if (fields & 31 != 31) return error.MissingField;
        for (self.bones[0..self.used]) |previous| {
            if (previous.id == bone.id or same(
                previous.name,
                bone.name,
            )) return error.DuplicateBone;
        }
        self.bones[self.used] = bone;
        self.used += 1;
    }

    fn find(self: *const Parser, name: []const u8) text.ParseError!u32 {
        for (self.bones[0..self.used], 0..) |bone, index| {
            if (same(bone.name, name)) return @intCast(index);
        }
        return error.UnknownBone;
    }

    fn parseHierarchy(self: *Parser) text.ParseError!void {
        try self.lexer.expect("begin");
        while (true) {
            const parent_token = try self.lexer.take();
            if (same(parent_token.text, "end")) {
                const next = try self.lexer.peek();
                if (next == null or next.?.line_start) break;
            }
            const parent = try self.find(parent_token.text);
            var children: usize = 0;
            while (try self.lexer.peek()) |child| {
                if (child.line_start) break;
                _ = try self.lexer.next();
                const index = try self.find(child.text);
                if (index == 0 or index == parent or self.bones[index].parent != null) {
                    return error.InvalidHierarchy;
                }
                self.bones[index].parent = parent;
                children += 1;
            }
            if (children == 0) return error.InvalidHierarchy;
        }
    }

    fn finish(self: *Parser) text.ParseError!u32 {
        if (self.sections & 31 != 31 or self.unit_fields & 4 == 0 or self.used != self.bones.len) {
            return error.MissingField;
        }
        var channels: u32 = 0;
        for (self.bones, 0..) |*bone, index| {
            bone.channel_offset = channels;
            channels = std.math.add(u32, channels, bone.dof_count) catch return error.LimitExceeded;
            if (index != 0 and bone.parent == null) return error.InvalidHierarchy;
        }
        self.topology[0] = 0;
        self.depths[0] = 1;
        if (self.options.limits.depth == 0) return error.LimitExceeded;
        var count: usize = 1;
        while (count < self.used) {
            const before = count;
            for (self.bones[1..], 1..) |bone, index| {
                if (self.depths[index] != 0) continue;
                const parent_depth = self.depths[bone.parent.?];
                if (parent_depth == 0) continue;
                if (parent_depth >= self.options.limits.depth) return error.LimitExceeded;
                self.depths[index] = parent_depth + 1;
                self.topology[count] = @intCast(index);
                count += 1;
            }
            if (before == count) return error.CyclicHierarchy;
        }
        return channels;
    }

    fn run(self: *Parser) text.ParseError!model.Skeleton {
        self.bones[0] = .{};
        while (try self.lexer.next()) |section| {
            if (!section.line_start or section.text[0] != ':') return error.UnexpectedToken;
            if (same(section.text, ":version")) {
                try mark(&self.sections, 1);
                const value = (try self.lexer.take()).text;
                if (!same(value, "1.10") and !same(value, "1.1")) return error.UnsupportedVersion;
            } else if (same(section.text, ":name")) {
                try mark(&self.sections, 32);
                self.name = (try self.lexer.take()).text;
                try text.identifier(self.name);
            } else if (same(section.text, ":units")) {
                try mark(&self.sections, 2);
                try self.parseUnits();
            } else if (same(section.text, ":documentation")) {
                try mark(&self.sections, 64);
                self.documentation = try self.skipSection();
            } else if (same(section.text, ":root")) {
                try mark(&self.sections, 4);
                try self.parseRoot();
            } else if (same(section.text, ":bonedata")) {
                try mark(&self.sections, 8);
                while (try self.nextField()) |begin| {
                    if (!same(begin.text, "begin")) return error.UnexpectedToken;
                    try self.parseBone();
                }
            } else if (same(section.text, ":hierarchy")) {
                try mark(&self.sections, 16);
                if (self.sections & 8 == 0) return error.MissingField;
                try self.parseHierarchy();
            } else {
                if (self.options.unknown_sections == .reject) return error.UnsupportedField;
                _ = try self.skipSection();
            }
        }
        const channels = try self.finish();
        return .{
            .source = self.lexer.source,
            .bones = self.bones,
            .topology = self.topology,
            .units = self.units,
            .name = self.name,
            .documentation = self.documentation,
            .channel_count = channels,
        };
    }
};

test "skeleton preserves independent IDs, file order, topology, units and editing limits" {
    const f = @import("fixtures.zig");
    var skeleton = try parseSkeletonAlloc(std.testing.allocator, f.skeleton, null, .{});
    defer skeleton.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("authored", skeleton.name);
    try std.testing.expectEqual(@as(?f64, 2), skeleton.units.length);
    try std.testing.expectEqual(@as(u32, 9), skeleton.channel_count);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 3, 1 }, skeleton.topology);
    try std.testing.expectEqual(@as(u32, 42), skeleton.bones[1].id);
    try std.testing.expectEqual(@as(?u32, 3), skeleton.bones[1].parent);
    try std.testing.expectEqual(model.RotationOrder.yzx, skeleton.bones[1].axis_order);
    try std.testing.expectEqualSlices(model.Channel, &.{
        .ry, .rx,
    }, skeleton.bones[1].channelOrder());
    try std.testing.expectEqual(-std.math.inf(f64), skeleton.bones[1].limits[1].?.lower);
    try std.testing.expectEqual(@as(?u32, 2), skeleton.view().findBone("base"));
    try std.testing.expectEqual(@as(?u32, null), skeleton.view().findBone("BASE"));
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, &skeleton.bones[0].position);
}

test "keyword-like names stay values in bone records and hierarchy parents" {
    const allocator = std.testing.allocator;
    const f = @import("fixtures.zig");
    const first = try std.mem.replaceOwned(u8, allocator, f.skeleton, "base", "begin");
    defer allocator.free(first);
    const second = try std.mem.replaceOwned(u8, allocator, first, "fixed", "end");
    defer allocator.free(second);
    const source = try std.mem.replaceOwned(u8, allocator, second, "tip", "name");
    defer allocator.free(source);
    var skeleton = try parseSkeletonAlloc(allocator, source, null, .{ .limits = .{ .bones = 4 } });
    defer skeleton.deinit(allocator);
    try std.testing.expectEqual(@as(?u32, 2), skeleton.view().findBone("begin"));
    try std.testing.expectEqual(@as(?u32, 3), skeleton.view().findBone("end"));
    try std.testing.expectEqual(@as(?u32, 1), skeleton.view().findBone("name"));
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 3, 1 }, skeleton.topology);
}

test "skeleton rejects duplicate identities, disconnected parents and malformed channels" {
    const f = @import("fixtures.zig");
    const allocator = std.testing.allocator;
    const Case = struct { before: []const u8, after: []const u8, reason: text.ParseError };
    for (
        [_]Case{
            .{ .before = "id 7", .after = "id 42", .reason = error.DuplicateBone },
            .{ .before = "name base", .after = "name root", .reason = error.DuplicateBone },
            .{ .before = "base fixed", .after = "missing fixed", .reason = error.UnknownBone },
            .{ .before = "base fixed", .after = "tip fixed", .reason = error.CyclicHierarchy },
            .{ .before = "fixed tip", .after = "fixed root", .reason = error.InvalidHierarchy },
            .{ .before = "dof ry rx", .after = "dof ry ry", .reason = error.DuplicateChannels },
            .{ .before = "(-20 20)", .after = "(20 -20)", .reason = error.InvalidNumber },
            .{ .before = "length 3", .after = "length nan", .reason = error.InvalidNumber },
            .{ .before = "axis ZYX", .after = "axis XYX", .reason = error.UnexpectedToken },
        },
    ) |case| {
        const source = try std.mem.replaceOwned(u8, allocator, f.skeleton, case.before, case.after);
        defer allocator.free(source);
        try std.testing.expectError(case.reason, parseSkeletonAlloc(allocator, source, null, .{}));
    }
}

test "skeleton owns names and metadata and enforces independent resource limits" {
    const allocator = std.testing.allocator;
    const f = @import("fixtures.zig");
    const source = try allocator.dupe(u8, f.skeleton);
    var skeleton = try parseSkeletonAlloc(allocator, source, null, .{});
    defer skeleton.deinit(allocator);
    @memset(source, 0xa5);
    allocator.free(source);
    try std.testing.expectEqualStrings("tip", skeleton.bones[1].name);
    try std.testing.expect(std.mem.startsWith(u8, skeleton.documentation, "Declaration order"));
    for (
        [_]text.Limits{
            .{ .input_bytes = f.skeleton.len - 1 },
            .{ .bones = 3 },
            .{ .depth = 3 },
            .{ .token_bytes = 5 },
            .{ .line_bytes = 5 },
        },
    ) |limits| {
        try std.testing.expectError(
            error.LimitExceeded,
            parseSkeletonAlloc(allocator, f.skeleton, null, .{ .limits = limits }),
        );
    }
    const extended = f.skeleton ++ "\n:extra\nopaque metadata\n";
    var preserved = try parseSkeletonAlloc(allocator, extended, null, .{});
    defer preserved.deinit(allocator);
    try std.testing.expect(std.mem.endsWith(u8, preserved.source, "opaque metadata\n"));
    try std.testing.expectError(
        error.UnsupportedField,
        parseSkeletonAlloc(allocator, extended, null, .{ .unknown_sections = .reject }),
    );
}

test "skeleton reservation retains compact blocks and ignores comment keywords" {
    const allocator = std.testing.allocator;
    const source = @import("fixtures.zig").skeleton;
    const begin = std.mem.indexOf(u8, source, ":bonedata").?;
    const end = std.mem.indexOf(u8, source, ":hierarchy").?;
    const compact = try allocator.dupe(u8, source);
    defer allocator.free(compact);
    for (compact[begin..end]) |*byte| if (byte.* == '\n') {
        byte.* = ' ';
    };
    // Keep the next section at the start of a line.
    compact[end - 1] = '\n';
    var original = try parseSkeletonAlloc(allocator, source, null, .{});
    defer original.deinit(allocator);
    var parsed = try parseSkeletonAlloc(allocator, compact, null, .{});
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(original.bones.len, parsed.bones.len);
    try std.testing.expectEqualSlices(u32, original.topology, parsed.topology);
    for (original.bones, parsed.bones) |a, b| {
        try std.testing.expectEqual(a.id, b.id);
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqualSlices(f64, &a.direction, &b.direction);
        try std.testing.expectEqual(a.length, b.length);
    }
    const commented = try std.mem.replaceOwned(
        u8,
        allocator,
        source,
        ":bonedata",
        ":bonedata # begin begin\n# begin",
    );
    defer allocator.free(commented);
    var with_comment = try parseSkeletonAlloc(allocator, commented, null, .{});
    defer with_comment.deinit(allocator);
    try std.testing.expectEqual(original.bones.len, with_comment.bones.len);
}
