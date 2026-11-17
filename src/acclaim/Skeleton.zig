//! An ASF skeleton owns static bone geometry, ordered channel meanings and hierarchy metadata.
//! Parse once with parseAlloc and reuse view() for several AMC Motion owners and PoseEvaluator
//! instances. Views copy slice descriptors and unit metadata; they do not borrow this descriptor's
//! address. Keep managed fields and backing immutable until those borrowers are released, then
//! deinit once with the construction allocator. Copies alias ownership; release only one copy. No
//! allocator is stored.
const std = @import("std");
const Lexer = @import("Lexer.zig");
const fixtures = @import("fixtures.zig");
const Skeleton = @This();

/// Complete copied ASF text, including opaque metadata; owns the bytes backing parsed names.
source: []const u8,
/// Owned records in declaration order; index zero is the implicit root, independently of ASF IDs.
bones: []const Bone,
/// Owned indices visiting each bone once, with every parent before its children.
traversal_order: []const u32,
/// Declared unit scalars and the angle unit for static axis orientations.
units: Units,
/// Declared skeleton name borrowing source, or an empty slice when absent.
name: []const u8,
/// Uninterpreted documentation borrowing source, or an empty slice when absent.
documentation: []const u8,
/// Total active channels across all bones; the width of each complete AMC frame.
channel_count: u32,

/// Declared unit metadata; optional scalars do not identify universal SI units.
pub const Units = struct {
    /// Positive mass scalar from ASF, if present; retained without interpreting a physical unit.
    mass: ?f64 = null,
    /// Positive length scalar from ASF, if present; callers choose any known conversion explicitly.
    length: ?f64 = null,
    /// Unit of static axis angles, and AMC rotations when no AMC override is present.
    angle: AngleUnit,

    /// Unit used by stored axis angles or frame rotation channels.
    pub const AngleUnit = enum { degrees, radians };
};

/// One named segment in file coordinates. Root has ID zero and a static position/orientation. Other
/// bones retain independent positive ASF IDs; their proximal joint lies at the parent's distal
/// endpoint. Records and their backing stay immutable while borrowed.
pub const Bone = struct {
    /// Source ASF ID; zero for the implicit root. This is independent of the array index.
    id: u32 = 0,
    /// Case-sensitive source name borrowed from ASF; the implicit root is named "root".
    name: []const u8 = "root",
    /// Parent's array index, or null for root; this is not the parent's ASF ID.
    parent: ?u32 = null,
    /// Finite segment direction in unrotated file axes; not normalized automatically.
    direction: [3]f64 = .{ 0, 0, 0 },
    /// Nonnegative finite segment length in file units; root has no segment length.
    length: f64 = 0,
    /// Root's static position in file axes and units; zero for nonroot records.
    position: [3]f64 = .{ 0, 0, 0 },
    /// Static axis angles in Units.angle; root uses its declared orientation.
    axis: [3]f64 = .{ 0, 0, 0 },
    /// Fixed-axis composition order for axis, applying the first declared rotation first.
    axis_order: AxisOrder = .xyz,
    /// Ordered channel meanings; only the first channel_count entries are active.
    channels: [7]Channel = @splat(.rx),
    /// Active channel count, at most seven; static bones have zero channels.
    channel_count: u8 = 0,
    /// First scalar for this bone in each frame's flat channel array.
    channel_offset: u32 = 0,
    /// Optional editing bounds for active channels; absent/unused entries are null. Never clamps.
    limits: [7]?Limit = @splat(null),

    /// Order of fixed-axis rotations; XYZ applies X, then Y, then Z to a column vector.
    pub const AxisOrder = enum { xyz, xzy, yxz, yzx, zxy, zyx };

    /// One motion value's meaning; l is a recorded length channel, not a rotation.
    pub const Channel = enum { tx, ty, tz, rx, ry, rz, l };

    /// ASF editing bounds retained as metadata; they do not admit, reject or clamp frame values.
    /// Rotation bounds use Units.angle; other channels use file length units, independently of any
    /// AMC angle override or pose length scale.
    pub const Limit = struct {
        /// Lower editing bound; may be infinite.
        lower: f64,
        /// Upper editing bound, at least lower; may be infinite.
        upper: f64,
    };

    /// Ordered channel meanings for this segment's AMC values.
    pub fn channelOrder(self: *const Bone) []const Channel {
        return self.channels[0..self.channel_count];
    }
};

/// Immutable backing borrowed from a live Skeleton. Views, clips and evaluators expire when their
/// source owner is released or modified. Construct through Skeleton.view.
pub const View = struct {
    /// Borrowed declaration-order records, including the implicit root.
    bones: []const Bone,
    /// Borrowed bone indices in parent-before-child traversal order.
    traversal_order: []const u32,
    /// Copied ASF unit metadata; axis angles use units.angle.
    units: Units,
    /// Required number of scalar values in each recorded frame.
    channel_count: u32,

    /// Finds an exact case-sensitive name, including the implicit `root` at index zero.
    pub fn findBone(self: View, name: []const u8) ?u32 {
        for (self.bones, 0..) |bone, index| {
            if (std.mem.eql(u8, bone.name, name)) return @intCast(index);
        }
        return null;
    }
};

/// Resource admission and preservation of uninterpreted top-level ASF metadata.
pub const ParseOptions = struct {
    /// Independent source, text and hierarchy ceilings.
    limits: Lexer.ParseLimits = .{},
    /// Whether uninterpreted top-level sections remain in copied source or cause failure.
    unknown_sections: UnknownSectionPolicy = .preserve,

    /// Admission of unknown top-level ASF sections; known-section fields are still validated.
    pub const UnknownSectionPolicy = enum {
        /// Retain unknown sections in copied source without interpreting their contents.
        preserve,
        /// Refuse an unknown top-level section with UnsupportedField.
        reject,
    };
};

/// Borrows immutable identity/channel/geometry data for one or more motion clips.
pub fn view(self: *const Skeleton) View {
    return .{
        .bones = self.bones,
        .traversal_order = self.traversal_order,
        .units = self.units,
        .channel_count = self.channel_count,
    };
}

/// Releases owned backing with the construction allocator. Release motions and evaluators first;
/// every borrowed view and name becomes invalid.
pub fn deinit(self: *Skeleton, allocator: std.mem.Allocator) void {
    allocator.free(self.traversal_order);
    allocator.free(self.bones);
    allocator.free(self.source);
    self.* = undefined;
}

/// Copies ASF and constructs a reusable skeleton with exact owned backing. Bone zero is root;
/// remaining records preserve declaration order. Validates unique identities, channel arity,
/// required geometry, limits and a single connected acyclic hierarchy. File scale and angles remain
/// declared values. Input may retire after success. Failure publishes no owner and frees partial
/// allocations. Success and OutOfMemory leave diagnostics unchanged. A diagnostic overlapping input
/// is refused with AliasedStorage without writing it; other parse failures set it.
pub fn parseAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostic: ?*Lexer.Diagnostic,
    options: ParseOptions,
) (std.mem.Allocator.Error || Lexer.ParseError)!Skeleton {
    try Lexer.admit(source, diagnostic, options.limits);
    const count = try countBones(source, options.limits.bones, diagnostic);
    const copy = try allocator.dupe(u8, source);
    errdefer allocator.free(copy);
    const bones = try allocator.alloc(Bone, count);
    errdefer allocator.free(bones);
    const traversal_order = try allocator.alloc(u32, count);
    errdefer allocator.free(traversal_order);
    const depths = try allocator.alloc(u32, count);
    defer allocator.free(depths);
    @memset(depths, 0);
    var parser: Parser = .{
        .lexer = .{ .source = copy, .limit = options.limits.token_bytes },
        .bones = bones,
        .traversal_order = traversal_order,
        .depths = depths,
        .options = options,
    };
    return parser.run() catch |err| {
        Lexer.report(source, parser.lexer.offset, diagnostic, err);
        return err;
    };
}

test parseAlloc {
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
    var skeleton = try parseAlloc(std.testing.allocator, source, null, .{});
    defer skeleton.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 0), skeleton.view().findBone("root"));
    try std.testing.expectEqual(@as(u32, 6), skeleton.channel_count);
}

fn countBones(
    source: []const u8,
    limit: u32,
    diagnostic: ?*Lexer.Diagnostic,
) Lexer.ParseError!usize {
    var count: usize = 1;
    var in_bones = false;
    if (limit == 0) {
        Lexer.report(source, 0, diagnostic, error.LimitExceeded);
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
            while (cursor < source.len and !isTokenBoundary(
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
            Lexer.report(source, start, diagnostic, error.LimitExceeded);
            return error.LimitExceeded;
        }
        count += 1;
    }
    return count;
}

fn isTokenBoundary(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == '(' or byte == ')';
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseAxisOrder(bytes: []const u8) Lexer.ParseError!Bone.AxisOrder {
    inline for (.{
        Bone.AxisOrder.xyz, Bone.AxisOrder.xzy, Bone.AxisOrder.yxz, Bone.AxisOrder.yzx,
        Bone.AxisOrder.zxy, Bone.AxisOrder.zyx,
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(bytes, @tagName(candidate))) return candidate;
    }
    return error.UnexpectedToken;
}

fn parseChannel(bytes: []const u8) ?Bone.Channel {
    inline for (.{
        Bone.Channel.tx, Bone.Channel.ty, Bone.Channel.tz, Bone.Channel.rx, Bone.Channel.ry,
        Bone.Channel.rz, Bone.Channel.l,
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(bytes, @tagName(candidate))) return candidate;
    }
    return null;
}

fn markField(bits: *u8, mask: u8) Lexer.ParseError!void {
    if (bits.* & mask != 0) return error.DuplicateField;
    bits.* |= mask;
}

const Parser = struct {
    lexer: Lexer,
    bones: []Bone,
    traversal_order: []u32,
    depths: []u32,
    options: ParseOptions,
    used: usize = 1,
    sections: u8 = 0,
    root_fields: u8 = 0,
    unit_fields: u8 = 0,
    units: Units = .{ .angle = .degrees },
    name: []const u8 = "",
    documentation: []const u8 = "",

    fn nextField(self: *Parser) Lexer.ParseError!?Lexer.Token {
        if (try self.lexer.peek()) |token| {
            if (token.line_start and token.text[0] == ':') return null;
            return try self.lexer.next();
        }
        return null;
    }

    fn skipSection(self: *Parser) Lexer.ParseError![]const u8 {
        const start = self.lexer.cursor;
        while (try self.nextField()) |_| {}
        const end = if (try self.lexer.peek()) |next| next.offset else self.lexer.source.len;
        return std.mem.trim(u8, self.lexer.source[start..end], " \t\r\n");
    }

    fn parseUnits(self: *Parser) Lexer.ParseError!void {
        while (try self.nextField()) |key| {
            if (same(key.text, "mass") or same(key.text, "length")) {
                const mask: u8 = if (same(key.text, "mass")) 1 else 2;
                try markField(&self.unit_fields, mask);
                const value = try self.lexer.number();
                if (value <= 0) return error.InvalidNumber;
                if (mask == 1) self.units.mass = value else self.units.length = value;
            } else if (same(key.text, "angle")) {
                try markField(&self.unit_fields, 4);
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

    fn parseChannels(self: *Parser, bone: *Bone, root: bool) Lexer.ParseError!void {
        var bits: u8 = 0;
        while (try self.lexer.peek()) |next| {
            const value = parseChannel(next.text) orelse break;
            _ = try self.lexer.next();
            if (root and value == .l) return error.UnsupportedField;
            const channel_index: u3 = @intCast(@backingInt(value));
            const mask = @as(u8, 1) << channel_index;
            if (bits & mask != 0) return error.DuplicateChannels;
            bits |= mask;
            if (bone.channel_count == bone.channels.len) return error.ChannelCount;
            bone.channels[bone.channel_count] = value;
            bone.channel_count += 1;
        }
    }

    fn parseRoot(self: *Parser) Lexer.ParseError!void {
        while (try self.nextField()) |key| {
            if (same(key.text, "order")) {
                try markField(&self.root_fields, 1);
                try self.parseChannels(&self.bones[0], true);
            } else if (same(key.text, "axis")) {
                try markField(&self.root_fields, 2);
                self.bones[0].axis_order = try parseAxisOrder((try self.lexer.take()).text);
            } else if (same(key.text, "position")) {
                try markField(&self.root_fields, 4);
                self.bones[0].position = try self.lexer.vector();
            } else if (same(key.text, "orientation")) {
                try markField(&self.root_fields, 8);
                self.bones[0].axis = try self.lexer.vector();
            } else return error.UnsupportedField;
        }
        if (self.root_fields != 15) return error.MissingField;
    }

    fn bound(self: *Parser) Lexer.ParseError!f64 {
        const token = (try self.lexer.take()).text;
        if (same(token, "-inf")) return -std.math.inf(f64);
        if (same(token, "inf") or same(token, "+inf")) return std.math.inf(f64);
        return Lexer.decimal(token);
    }

    fn parseBone(self: *Parser) Lexer.ParseError!void {
        if (self.used >= self.bones.len) return error.LimitExceeded;
        var bone: Bone = .{ .name = "" };
        var fields: u8 = 0;
        while (true) {
            const key = (try self.lexer.take()).text;
            if (same(key, "end")) break;
            if (same(key, "id")) {
                try markField(&fields, 1);
                bone.id = try Lexer.integer((try self.lexer.take()).text);
                if (bone.id == 0) return error.DuplicateBone;
            } else if (same(key, "name")) {
                try markField(&fields, 2);
                bone.name = (try self.lexer.take()).text;
                try Lexer.identifier(bone.name);
            } else if (same(key, "direction")) {
                try markField(&fields, 4);
                bone.direction = try self.lexer.vector();
            } else if (same(key, "length")) {
                try markField(&fields, 8);
                bone.length = try self.lexer.number();
                if (bone.length < 0) return error.InvalidNumber;
            } else if (same(key, "axis")) {
                try markField(&fields, 16);
                bone.axis = try self.lexer.vector();
                bone.axis_order = try parseAxisOrder((try self.lexer.take()).text);
            } else if (same(key, "dof")) {
                try markField(&fields, 32);
                try self.parseChannels(&bone, false);
            } else if (same(key, "limits")) {
                try markField(&fields, 64);
                if (fields & 32 == 0) return error.MissingField;
                for (0..bone.channel_count) |index| {
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

    fn findBone(self: *const Parser, name: []const u8) Lexer.ParseError!u32 {
        for (self.bones[0..self.used], 0..) |bone, index| {
            if (same(bone.name, name)) return @intCast(index);
        }
        return error.UnknownBone;
    }

    fn parseHierarchy(self: *Parser) Lexer.ParseError!void {
        try self.lexer.expect("begin");
        while (true) {
            const parent_token = try self.lexer.take();
            if (same(parent_token.text, "end")) {
                const next = try self.lexer.peek();
                if (next == null or next.?.line_start) break;
            }
            const parent = try self.findBone(parent_token.text);
            var children: usize = 0;
            while (try self.lexer.peek()) |child| {
                if (child.line_start) break;
                _ = try self.lexer.next();
                const index = try self.findBone(child.text);
                if (index == 0 or index == parent or self.bones[index].parent != null) {
                    return error.InvalidHierarchy;
                }
                self.bones[index].parent = parent;
                children += 1;
            }
            if (children == 0) return error.InvalidHierarchy;
        }
    }

    fn finish(self: *Parser) Lexer.ParseError!u32 {
        if (self.sections & 31 != 31 or self.unit_fields & 4 == 0 or self.used != self.bones.len) {
            return error.MissingField;
        }
        var channels: u32 = 0;
        for (self.bones, 0..) |*bone, index| {
            bone.channel_offset = channels;
            channels = std.math.add(
                u32,
                channels,
                bone.channel_count,
            ) catch return error.LimitExceeded;
            if (index != 0 and bone.parent == null) return error.InvalidHierarchy;
        }
        self.traversal_order[0] = 0;
        self.depths[0] = 1;
        if (self.options.limits.depth == 0) return error.LimitExceeded;
        // Declaration order does not imply hierarchy order. A nonzero depth marks a bone whose
        // parent is already reachable; each pass can then admit its children. No progress means the
        // remaining parent links form a cycle, since missing parents were rejected above.
        var count: usize = 1;
        while (count < self.used) {
            const before = count;
            for (self.bones[1..], 1..) |bone, index| {
                if (self.depths[index] != 0) continue;
                const parent_depth = self.depths[bone.parent.?];
                if (parent_depth == 0) continue;
                if (parent_depth >= self.options.limits.depth) return error.LimitExceeded;
                self.depths[index] = parent_depth + 1;
                self.traversal_order[count] = @intCast(index);
                count += 1;
            }
            if (before == count) return error.CyclicHierarchy;
        }
        return channels;
    }

    fn run(self: *Parser) Lexer.ParseError!Skeleton {
        self.bones[0] = .{};
        while (try self.lexer.next()) |section| {
            if (!section.line_start or section.text[0] != ':') return error.UnexpectedToken;
            if (same(section.text, ":version")) {
                try markField(&self.sections, 1);
                const value = (try self.lexer.take()).text;
                if (!same(value, "1.10") and !same(value, "1.1")) return error.UnsupportedVersion;
            } else if (same(section.text, ":name")) {
                try markField(&self.sections, 32);
                self.name = (try self.lexer.take()).text;
                try Lexer.identifier(self.name);
            } else if (same(section.text, ":units")) {
                try markField(&self.sections, 2);
                try self.parseUnits();
            } else if (same(section.text, ":documentation")) {
                try markField(&self.sections, 64);
                self.documentation = try self.skipSection();
            } else if (same(section.text, ":root")) {
                try markField(&self.sections, 4);
                try self.parseRoot();
            } else if (same(section.text, ":bonedata")) {
                try markField(&self.sections, 8);
                while (try self.nextField()) |begin| {
                    if (!same(begin.text, "begin")) return error.UnexpectedToken;
                    try self.parseBone();
                }
            } else if (same(section.text, ":hierarchy")) {
                try markField(&self.sections, 16);
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
            .traversal_order = self.traversal_order,
            .units = self.units,
            .name = self.name,
            .documentation = self.documentation,
            .channel_count = channels,
        };
    }
};

test "skeleton preserves IDs, declaration/traversal order, units and editing limits" {
    var skeleton = try parseAlloc(std.testing.allocator, fixtures.skeleton, null, .{});
    defer skeleton.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("authored", skeleton.name);
    try std.testing.expectEqual(@as(?f64, 2), skeleton.units.length);
    try std.testing.expectEqual(@as(u32, 9), skeleton.channel_count);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 3, 1 }, skeleton.traversal_order);
    try std.testing.expectEqual(@as(u32, 42), skeleton.bones[1].id);
    try std.testing.expectEqual(@as(?u32, 3), skeleton.bones[1].parent);
    try std.testing.expectEqual(Bone.AxisOrder.yzx, skeleton.bones[1].axis_order);
    try std.testing.expectEqualSlices(
        Bone.Channel,
        &.{ .ry, .rx },
        skeleton.bones[1].channelOrder(),
    );
    try std.testing.expectEqual(-std.math.inf(f64), skeleton.bones[1].limits[1].?.lower);
    try std.testing.expectEqual(@as(?u32, 2), skeleton.view().findBone("base"));
    try std.testing.expectEqual(@as(?u32, null), skeleton.view().findBone("BASE"));
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, &skeleton.bones[0].position);
}

test "keyword-like names stay values in bone records and hierarchy parents" {
    const allocator = std.testing.allocator;
    const first = try std.mem.replaceOwned(u8, allocator, fixtures.skeleton, "base", "begin");
    defer allocator.free(first);
    const second = try std.mem.replaceOwned(u8, allocator, first, "fixed", "end");
    defer allocator.free(second);
    const source = try std.mem.replaceOwned(u8, allocator, second, "tip", "name");
    defer allocator.free(source);
    var skeleton = try parseAlloc(allocator, source, null, .{ .limits = .{ .bones = 4 } });
    defer skeleton.deinit(allocator);
    try std.testing.expectEqual(@as(?u32, 2), skeleton.view().findBone("begin"));
    try std.testing.expectEqual(@as(?u32, 3), skeleton.view().findBone("end"));
    try std.testing.expectEqual(@as(?u32, 1), skeleton.view().findBone("name"));
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 3, 1 }, skeleton.traversal_order);
}

test "skeleton rejects duplicate identities, disconnected parents and malformed channels" {
    const allocator = std.testing.allocator;
    const Case = struct { before: []const u8, after: []const u8, reason: Lexer.ParseError };
    for ([_]Case{
        .{ .before = "id 7", .after = "id 42", .reason = error.DuplicateBone },
        .{ .before = "name base", .after = "name root", .reason = error.DuplicateBone },
        .{ .before = "base fixed", .after = "missing fixed", .reason = error.UnknownBone },
        .{ .before = "base fixed", .after = "tip fixed", .reason = error.CyclicHierarchy },
        .{ .before = "fixed tip", .after = "fixed root", .reason = error.InvalidHierarchy },
        .{ .before = "dof ry rx", .after = "dof ry ry", .reason = error.DuplicateChannels },
        .{ .before = "(-20 20)", .after = "(20 -20)", .reason = error.InvalidNumber },
        .{ .before = "length 3", .after = "length nan", .reason = error.InvalidNumber },
        .{ .before = "axis ZYX", .after = "axis XYX", .reason = error.UnexpectedToken },
    }) |case| {
        const source = try std.mem.replaceOwned(
            u8,
            allocator,
            fixtures.skeleton,
            case.before,
            case.after,
        );
        defer allocator.free(source);
        try std.testing.expectError(case.reason, parseAlloc(allocator, source, null, .{}));
    }
}

test "skeleton owns names and metadata and enforces independent resource limits" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, fixtures.skeleton);
    var skeleton = try parseAlloc(allocator, source, null, .{});
    defer skeleton.deinit(allocator);
    @memset(source, 0xa5);
    allocator.free(source);
    try std.testing.expectEqualStrings("tip", skeleton.bones[1].name);
    try std.testing.expect(std.mem.startsWith(u8, skeleton.documentation, "Declaration order"));
    for ([_]Lexer.ParseLimits{
        .{ .input_bytes = fixtures.skeleton.len - 1 },
        .{ .bones = 3 },
        .{ .depth = 3 },
        .{ .token_bytes = 5 },
        .{ .line_bytes = 5 },
    }) |limits|
        try std.testing.expectError(
            error.LimitExceeded,
            parseAlloc(allocator, fixtures.skeleton, null, .{ .limits = limits }),
        );
    const extended = fixtures.skeleton ++ "\n:extra\nopaque metadata\n";
    var preserved = try parseAlloc(allocator, extended, null, .{});
    defer preserved.deinit(allocator);
    try std.testing.expect(std.mem.endsWith(u8, preserved.source, "opaque metadata\n"));
    try std.testing.expectError(
        error.UnsupportedField,
        parseAlloc(allocator, extended, null, .{ .unknown_sections = .reject }),
    );
}

test "skeleton reservation retains compact blocks and ignores comment keywords" {
    const allocator = std.testing.allocator;
    const source = fixtures.skeleton;
    const begin = std.mem.indexOf(u8, source, ":bonedata").?;
    const end = std.mem.indexOf(u8, source, ":hierarchy").?;
    const compact = try allocator.dupe(u8, source);
    defer allocator.free(compact);
    for (compact[begin..end]) |*byte| if (byte.* == '\n') {
        byte.* = ' ';
    };
    // Keep the next section at the start of a line.
    compact[end - 1] = '\n';
    var original = try parseAlloc(allocator, source, null, .{});
    defer original.deinit(allocator);
    var parsed = try parseAlloc(allocator, compact, null, .{});
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(original.bones.len, parsed.bones.len);
    try std.testing.expectEqualSlices(u32, original.traversal_order, parsed.traversal_order);
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
    var with_comment = try parseAlloc(allocator, commented, null, .{});
    defer with_comment.deinit(allocator);
    try std.testing.expectEqual(original.bones.len, with_comment.bones.len);
}
