//! Floating-point rounding shared by normalized sample encoders.

const testing = @import("std").testing;

/// Rounds a finite normalized sample multiplied by an exact power-of-two scale, halfway away from
/// zero. The scaled value must fit in i64, and its integer part must be exactly representable in
/// f64.
pub fn halfAwayScaled(sample: f64, scale: f64) i64 {
    const scaled = sample * scale;
    // Some @round lowerings depend on the caller's rounding mode. The exact residual makes the
    // halfway decision explicit after truncation.
    const whole: i64 = @trunc(scaled);
    const fraction = @abs(scaled - @as(f64, @floatFromInt(whole)));
    if (fraction < 0.5) return whole;
    return whole + if (scaled < 0) @as(i64, -1) else 1;
}

test "scaled half-away rounding covers both signs" {
    try testing.expectEqual(@as(i64, 1), halfAwayScaled(0.5, 1));
    try testing.expectEqual(@as(i64, -1), halfAwayScaled(-0.5, 1));
    try testing.expectEqual(@as(i64, 0), halfAwayScaled(0.25, 1));
    try testing.expectEqual(@as(i64, 0), halfAwayScaled(-0.25, 1));
}
