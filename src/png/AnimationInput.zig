//! Borrowed frames and canvas description supplied to the APNG encoder. Every frame uses this
//! single stored color/depth layout.

const format = @import("format.zig");
const FrameControl = @import("FrameControl.zig");

const ColorType = format.ColorType;
const Samples = format.Samples;
const Transparency = format.Transparency;
const Delay = FrameControl.Delay;
const Disposal = FrameControl.Disposal;
const Blend = FrameControl.Blend;

/// Positive 31-bit canvas width.
width: u32,
/// Positive 31-bit canvas height.
height: u32,
/// PNG stored channel layout, without color conversion.
color_type: ColorType,
/// One of the fifteen standard PNG color/depth combinations.
bit_depth: u8,
/// Borrowed RGB table, empty by default. Required for indexed color and optional as a suggested
/// palette for truecolor/RGBA; keep it unchanged through encoding.
palette: []const [3]u8 = &.{},
/// Explicit tRNS codes or palette alpha; inherited by every raster.
transparency: Transparency = .none,
/// Ordered nonempty frame rectangles. Keep the array and all sample storage live and unchanged
/// through encoding.
frames: []const Frame,
/// Optional full-canvas static IDAT raster excluded from the animation. With null, frame zero must
/// occupy the complete canvas at (0,0) and supplies the IDAT image.
poster: ?Samples = null,
/// Zero loops indefinitely; finite values are PNG 31-bit integers and are copied exactly.
play_count: u32 = 0,

/// One immutable native raster and its exact caller-selected APNG control.
pub const Frame = struct {
    /// Positive local raster width within the canvas.
    width: u32,
    /// Positive local raster height within the canvas.
    height: u32,
    /// Left canvas position in stored pixels, without pHYs mapping; defaults to zero.
    x: u32 = 0,
    /// Top canvas position in stored pixels, without pHYs mapping; defaults to zero.
    y: u32 = 0,
    /// Borrowed packed bytes or complete native words with optional row padding.
    samples: Samples,
    /// Exact encoded fraction; denominator zero remains zero and means hundredths on reading.
    delay: Delay,
    /// Disposal after display; defaults to none. First previous is preserved and readers treat it
    /// as background.
    dispose: Disposal = .none,
    /// Replacement or source-over; defaults to source. No precomposition or alpha association is
    /// performed.
    blend: Blend = .source,
};
