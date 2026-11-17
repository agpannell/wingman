//! Internal row-major binary64 3×3 matrix arithmetic shared by rigid composition and Acclaim's
//! static-axis interpretation. Products apply the right operand to a column vector first.

/// Three rows of three binary64 components.
pub const Matrix = [3][3]f64;

/// Returns `left * right` without checking numeric bounds or normalizing either operand.
pub fn multiply(left: Matrix, right: Matrix) Matrix {
    var result: Matrix = undefined;
    multiplyInto(&result, &left, &right);
    return result;
}

/// Writes `left * right`; destination must not overlap either source. Callers check numeric bounds.
pub inline fn multiplyInto(destination: *Matrix, left: *const Matrix, right: *const Matrix) void {
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
