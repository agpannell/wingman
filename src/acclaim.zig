//! Read paired Acclaim skeletons and sampled motion for animation and motion analysis.
//!
//! An ASF defines named bones, their hierarchy and ordered motion channels. An AMC provides
//! numbered samples for that skeleton. Parse one skeleton and reuse its view for multiple motions.
//! Bone zero is the implicit root; other bones retain ASF declaration order and numeric IDs.
//!
//! Parsing preserves file values and coordinate axes. Length scales are metadata, not automatic
//! conversions to metres. AMC angle declarations override the ASF angle unit. Frame numbers are
//! retained without guessing a sampling rate, interpolating gaps or changing root motion.
//!
//! Skeleton owners copy source so names and metadata survive input release. Motion owners copy
//! header metadata and materialize binary64 channels; AMC source may retire. Motions borrow their
//! skeleton's immutable backing. Release motions before their skeleton, using each construction
//! allocator. No owner retains an allocator. Failure returns no owner and releases partial storage.
//!
//! `PoseEvaluator` prepares a skeleton's axis bases once, then writes local or global transforms
//! into caller storage. Select length conversion and nonzero root orientation explicitly through
//! `PoseOptions`; the default preserves file units and applies root orientation as a rest rotation.
//! Length channels and nonroot translations remain available as raw data but cannot prepare a pose.

const model = @import("acclaim/model.zig");
const text = @import("acclaim/text.zig");
const skeleton = @import("acclaim/skeleton.zig");
const motion = @import("acclaim/motion.zig");
const pose = @import("acclaim/pose.zig");

pub const AngleUnit = model.AngleUnit;
pub const RotationOrder = model.RotationOrder;
pub const Channel = model.Channel;
pub const Range = model.Range;
pub const Units = model.Units;
pub const Bone = model.Bone;
pub const SkeletonView = model.SkeletonView;
pub const Skeleton = model.Skeleton;
pub const Motion = model.Motion;
pub const Sample = model.Sample;
pub const Limits = text.Limits;
pub const ParseError = text.ParseError;
pub const Diagnostic = text.Diagnostic;
pub const SkeletonParseOptions = skeleton.SkeletonParseOptions;
pub const MotionParseOptions = motion.MotionParseOptions;
pub const parseSkeletonAlloc = skeleton.parseSkeletonAlloc;
pub const parseMotionAlloc = motion.parseMotionAlloc;
pub const RootOrientation = pose.RootOrientation;
pub const PoseOptions = pose.PoseOptions;
pub const PoseError = pose.PoseError;
pub const PoseEvaluator = pose.PoseEvaluator;

test {
    _ = @import("common/ascii_number.zig");
    _ = model;
    _ = text;
    _ = skeleton;
    _ = motion;
    _ = pose;
}
