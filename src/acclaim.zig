//! Read paired Acclaim skeletons and recorded motion for animation and motion analysis.
//!
//! An ASF defines named bones, their hierarchy and ordered motion channels. An AMC provides
//! numbered frames for that skeleton. Use `Skeleton.parseAlloc` once, then `Motion.parseAlloc` with
//! its view for each recording. Bone zero is the implicit root; other bones retain ASF declaration
//! order and numeric IDs.
//!
//! Parsing preserves file values and coordinate axes. Length scales are metadata, not automatic
//! conversions to metres. AMC angle declarations override the ASF angle unit. Frame numbers are
//! retained without guessing a sampling rate, interpolating gaps or changing root motion.
//!
//! Skeleton owners copy source so names and metadata survive input release. Motion owners copy
//! header metadata and materialize binary64 channels; AMC source may retire. Motions borrow their
//! skeleton's immutable backing. Release motions and evaluators before their skeleton, using each
//! construction allocator. No owner retains an allocator. Failure returns no owner and releases
//! partial storage.
//!
//! `PoseEvaluator` prepares a skeleton's axis bases once, then writes local or global transforms
//! into caller storage. Select length conversion and nonzero root orientation explicitly through
//! `PoseEvaluator.Options`; the default preserves file units and applies root orientation as a rest
//! rotation. Length channels and nonroot translations remain available as raw data but cannot
//! prepare a pose.

const Lexer = @import("acclaim/Lexer.zig");

pub const Skeleton = @import("acclaim/Skeleton.zig");
pub const Motion = @import("acclaim/Motion.zig");
pub const PoseEvaluator = @import("acclaim/PoseEvaluator.zig");
pub const Channel = Skeleton.Bone.Channel;
pub const AngleUnit = Skeleton.Units.AngleUnit;
pub const ParseLimits = Lexer.ParseLimits;
pub const ParseError = Lexer.ParseError;
pub const Diagnostic = Lexer.Diagnostic;

test {
    _ = @import("common/ascii_number.zig");
    _ = Skeleton;
    _ = Motion;
    _ = PoseEvaluator;
    _ = Lexer;
}
