//! Copied APNG frame control, independent of the encoded source lifetime.

const FrameControl = @This();

/// Encoded 31-bit fcTL sequence number, distinct from the frame's ordinal.
sequence: u32,
/// Nonzero frame raster width in stored pixels.
width: u32,
/// Nonzero frame raster height in stored pixels.
height: u32,
/// Left edge in stored pixels within the complete canvas.
x: u32,
/// Top edge in stored pixels within the complete canvas.
y: u32,
/// Exact declared display interval.
delay: Delay,
/// Disposal applied before advancing beyond this displayed frame.
dispose: Disposal,
/// Composition of this frame onto the current output buffer.
blend: Blend,

/// Exact encoded frame delay; zero denominator denotes hundredths of a second.
pub const Delay = struct {
    /// Encoded numerator; zero requests the next frame as soon as the caller can show it.
    numerator: u16,
    /// Encoded denominator; preserved even when zero has the effective value 100.
    denominator: u16,

    /// Effective rational denominator; timing/clamping and clocks remain caller decisions.
    pub fn effectiveDenominator(self: Delay) u16 {
        return if (self.denominator == 0) 100 else self.denominator;
    }
};

/// Frame-area disposal after its displayed delay; the first previous acts as background.
pub const Disposal = enum(u8) { none, background, previous };

/// Replacement or unassociated-alpha source-over composition within the frame rectangle.
pub const Blend = enum(u8) { source, over };
