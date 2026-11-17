//! BVH skeletons and recorded movement for motion analysis and animation. A skeleton locates joints
//! through parent links and offsets; a motion supplies position and rotation channels over time.
//! End sites retain the endpoints of joint chains without adding animated channels.
//!
//! `Motion.parseAlloc` returns an owner of the hierarchy and every frame; input bytes may retire.
//! Frames preserve source coordinates and units, rotation degrees, channel order and the encoded
//! interval in seconds. BVH identifies neither a universal length unit nor a complete rotational
//! bind pose. World conversion, interpolation, retargeting and dataset trimming belong to callers.
//! See the declaration-linked example at `Motion.parseAlloc` for ownership and frame access.
//! `localPoseInto` and `globalPoseInto` convert a frame into caller-owned `wingman.RigidTransform`
//! values without allocating. BVH's intrinsic rotation order and explicit position/scale options
//! preserve the distinction between recorded channels and their interpretation.

const Lexer = @import("bvh/Lexer.zig");
const pose = @import("bvh/pose.zig");

pub const Motion = @import("bvh/Motion.zig");
pub const Skeleton = @import("bvh/Skeleton.zig");
pub const Channel = Skeleton.Channel;
pub const ParseLimits = Lexer.ParseLimits;
pub const ParseError = Lexer.ParseError;
pub const Diagnostic = Lexer.Diagnostic;
pub const PoseOptions = pose.PoseOptions;
pub const PoseError = pose.PoseError;
pub const localPoseInto = pose.localPoseInto;
pub const globalPoseInto = pose.globalPoseInto;

test {
    _ = @import("common/ascii_number.zig");
    _ = Motion;
    _ = Skeleton;
    _ = Lexer;
    _ = pose;
}
