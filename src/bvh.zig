//! BVH skeletons and recorded movement for motion analysis and animation. A skeleton locates joints
//! through parent links and offsets; a motion supplies position and rotation channels over time.
//! End sites retain the endpoints of joint chains without adding animated channels.
//!
//! `parseAlloc` owns the hierarchy and every sample, so input bytes may retire after parsing.
//! Samples preserve source coordinates and units, rotation degrees, channel order and the encoded
//! interval in seconds. BVH identifies neither a universal length unit nor a complete rotational
//! bind pose. World conversion, interpolation, retargeting and dataset trimming belong to callers.
//! See the declaration-linked example at `parseAlloc` for ownership and frame access.
//! `localPoseInto` and `globalPoseInto` convert a sample into caller-owned `wingman.RigidTransform`
//! values without allocating. BVH's intrinsic rotation order and explicit position/scale options
//! preserve the distinction between recorded channels and their interpretation.

const model = @import("bvh/model.zig");
const text = @import("bvh/text.zig");
const parse = @import("bvh/parse.zig");
const pose = @import("bvh/pose.zig");

pub const Channel = model.Channel;
pub const Joint = model.Joint;
pub const SkeletonView = model.SkeletonView;
pub const Skeleton = model.Skeleton;
pub const Sample = model.Sample;
pub const Motion = model.Motion;
pub const Limits = text.Limits;
pub const ParseError = text.ParseError;
pub const Diagnostic = text.Diagnostic;
pub const FrameLayout = parse.FrameLayout;
pub const ParseOptions = parse.ParseOptions;
pub const parseAlloc = parse.parseAlloc;
pub const PositionChannels = pose.PositionChannels;
pub const PoseOptions = pose.PoseOptions;
pub const PoseError = pose.PoseError;
pub const localPoseInto = pose.localPoseInto;
pub const globalPoseInto = pose.globalPoseInto;

test {
    _ = model;
    _ = text;
    _ = parse;
    _ = pose;
}
