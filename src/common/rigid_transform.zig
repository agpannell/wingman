//! Binary64 rigid transforms for skeletal poses and spatial coordinates. A transform rotates a
//! point and then translates it; composing a parent and child carries child coordinates into parent
//! space.
const std = @import("std");
const Matrix = [3][3]f64;

/// A column-vector transform `rotation * point + translation`, with rotation rows stored first.
/// Length units and coordinate axes belong to the caller. This value owns no storage. Its fields
/// are not automatically checked for a finite, orthonormal rotation; motion evaluators construct
/// checked rigid results, while caller-created values retain the caller's numeric responsibility.
pub const RigidTransform = struct {
    rotation: Matrix,
    translation: [3]f64,

    /// Leaves points unchanged.
    pub const identity: RigidTransform = .{ .rotation = .{ .{
        1, 0, 0,
    }, .{
        0, 1, 0,
    }, .{
        0, 0, 1,
    } }, .translation = .{
        0, 0, 0,
    } };

    /// Rotates and translates a point without allocating or checking numeric bounds.
    pub fn transformPoint(self: RigidTransform, point: [3]f64) [3]f64 {
        return applyPoint(&self.rotation, self.translation, point);
    }

    /// Returns `self(child(point))`: a child's transform carried through its parent. Allocates
    /// nothing; arithmetic may overflow, so callers needing finite results check `isFinite`.
    pub fn compose(self: RigidTransform, child: RigidTransform) RigidTransform {
        var result: RigidTransform = undefined;
        composeInto(&result, &self, &child);
        return result;
    }

    /// Checks every component for NaN/infinity, without asserting orthogonality or handedness.
    pub fn isFinite(self: RigidTransform) bool {
        // Check independent components together. Explicit groups avoid assuming a struct layout or
        // reading padding, and the target chooses how these vectors are lowered.
        return finite(
            .{ self.rotation[0][0], self.rotation[0][1], self.rotation[0][2], self.rotation[1][0] },
        ) and finite(
            .{ self.rotation[1][1], self.rotation[1][2], self.rotation[2][0], self.rotation[2][1] },
        ) and finite(
            .{ self.rotation[2][2], self.translation[0], self.translation[1], self.translation[2] },
        );
    }
};

fn finite(values: @Vector(4, f64)) bool {
    const bits: @Vector(4, u64) = @bitCast(values);
    const magnitude_mask: @Vector(4, u64) = @splat(std.math.maxInt(u64) >> 1);
    const infinity_bits: @Vector(4, u64) = @splat(@bitCast(std.math.inf(f64)));
    const magnitude_bits = bits & magnitude_mask;
    const finite_components = magnitude_bits < infinity_bits;
    return @reduce(.And, finite_components);
}

/// Row-major binary64 matrix product; `left * right` applies right to a column vector first. Used
/// internally by rigid composition and format-specific static-axis interpretation.
pub fn multiply(left: Matrix, right: Matrix) Matrix {
    var result: Matrix = undefined;
    multiplyInto(&result, &left, &right);
    return result;
}

/// Internal borrowed composition into distinct storage. Destination must not overlap either source.
/// Keeps the public value method's arithmetic; the caller checks numeric bounds.
pub inline fn composeInto(
    destination: *RigidTransform,
    parent: *const RigidTransform,
    child: *const RigidTransform,
) void {
    multiplyInto(&destination.rotation, &parent.rotation, &child.rotation);
    destination.translation = applyPoint(&parent.rotation, parent.translation, child.translation);
}

inline fn applyPoint(rotation: *const Matrix, translation: [3]f64, point: [3]f64) [3]f64 {
    var result: @Vector(3, f64) = translation;
    inline for (0..3) |column| {
        const basis_column: @Vector(
            3,
            f64,
        ) = .{ rotation[0][column], rotation[1][column], rotation[2][column] };
        const point_component: @Vector(3, f64) = @splat(point[column]);
        result += basis_column * point_component;
    }
    return result;
}

inline fn multiplyInto(destination: *Matrix, left: *const Matrix, right: *const Matrix) void {
    inline for (0..3) |row| {
        // Each lane is one independent column. Keep the scalar product/addition order so this
        // changes neither the arithmetic contract nor the target's required CPU features.
        var columns: @Vector(3, f64) = @splat(0);
        inline for (0..3) |inner| {
            const factor: @Vector(3, f64) = @splat(left[row][inner]);
            const right_row: @Vector(3, f64) = right[inner];
            columns += factor * right_row;
        }
        destination[row] = columns;
    }
}

test "rigid finiteness covers every component and admits finite extremes" {
    for (0..12) |index| {
        for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |value| {
            var invalid = RigidTransform.identity;
            if (index < 9) {
                invalid.rotation[index / 3][index % 3] = value;
            } else {
                invalid.translation[index - 9] = value;
            }
            try std.testing.expect(!invalid.isFinite());
        }
        var finite_value = RigidTransform.identity;
        if (index < 9) {
            finite_value.rotation[index / 3][index % 3] = std.math.floatMax(f64);
        } else {
            finite_value.translation[index - 9] = -std.math.floatMax(f64);
        }
        try std.testing.expect(finite_value.isFinite());
    }
}

test "rigid composition carries local coordinates through a translated rotated parent" {
    const parent: RigidTransform = .{ .rotation = .{ .{
        0, -1, 0,
    }, .{
        1, 0, 0,
    }, .{
        0, 0, 1,
    } }, .translation = .{
        1, 2, 3,
    } };
    const child: RigidTransform = .{ .rotation = .{ .{
        1, 0, 0,
    }, .{
        0, 0, -1,
    }, .{
        0, 1, 0,
    } }, .translation = .{
        4, 5, 6,
    } };
    const result = parent.compose(child);
    try std.testing.expectEqualDeep(@as(Matrix, .{ .{
        0, 0, 1,
    }, .{
        1, 0, 0,
    }, .{
        0, 1, 0,
    } }), result.rotation);
    try std.testing.expectEqualSlices(f64, &.{ -4, 6, 9 }, &result.translation);
    try std.testing.expectEqualSlices(f64, &.{ -1, 7, 11 }, &result.transformPoint(.{ 1, 2, 3 }));
    try std.testing.expect(result.isFinite());
    var invalid = RigidTransform.identity;
    invalid.rotation[1][2] = std.math.nan(f64);
    try std.testing.expect(!invalid.isFinite());
    invalid = RigidTransform.identity;
    invalid.translation[2] = std.math.inf(f64);
    try std.testing.expect(!invalid.isFinite());
}

test "rigid composition evaluates every caller-supplied component without normalization" {
    const parent: RigidTransform = .{ .rotation = .{ .{
        1, 2, 3,
    }, .{
        4, 5, 6,
    }, .{
        7, 8, 9,
    } }, .translation = .{
        10, 20, 30,
    } };
    const child: RigidTransform = .{ .rotation = .{ .{
        9, 8, 7,
    }, .{
        6, 5, 4,
    }, .{
        3, 2, 1,
    } }, .translation = .{
        3, 5, 7,
    } };
    const expected: RigidTransform = .{ .rotation = .{ .{
        30, 24, 18,
    }, .{
        84, 69, 54,
    }, .{
        138, 114, 90,
    } }, .translation = .{
        44, 99, 154,
    } };
    try std.testing.expectEqualDeep(expected, parent.compose(child));
    var assigned = parent;
    assigned = assigned.compose(child);
    try std.testing.expectEqualDeep(expected, assigned);
}
