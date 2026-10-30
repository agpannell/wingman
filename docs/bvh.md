# BVH skeletons and recorded motion

BVH (Biovision Hierarchical Data) describes a skeleton and movement recorded over time. Each
joint has a parent, a static offset and an ordered set of position or rotation channels. Each
frame supplies the values for those channels. An end site marks a chain's endpoint without adding
animated channels.

Use `wingman.bvh` to load motion for animation tools, dataset analysis or joint-position extraction.
It owns the hierarchy and samples, and evaluates local or global joint transforms into caller
storage. It does not provide playback, interpolation, skinning, retargeting or BVH writing.

Use [Zig 0.17.0 and the package setup](../README.md#use-it-in-a-project).
Run `zig build bvh-example` for a complete [authored clip and runnable example](../examples/bvh.zig).
The example retires the input after parsing, checks local/global joint origins and preserves an
unused output tail.

## Load and retain a motion

```zig
const std = @import("std");
const bvh = @import("wingman").bvh;

pub fn readMotion(allocator: std.mem.Allocator, bytes: []const u8) !bvh.Motion {
    return bvh.parseAlloc(allocator, bytes, null, .{});
}
```

`parseAlloc` copies the hierarchy text, materializes joints and reads every sample as binary64.
Input bytes can retire after success. The result retains no allocator. Release it exactly once
with `motion.deinit(allocator)`, using the original allocator; copying `Motion` or its nested
`Skeleton` aliases ownership. Release the complete motion rather than its nested skeleton.

`motion.frame(index)` returns a borrowed `Sample`, or `null` beyond the recorded frames.
`sample.jointValues(joint_index)` returns that joint's values in source channel order, or `null`
for an invalid joint index. End sites and static joints return empty values. Names, skeleton
views and samples borrow the immutable motion and expire when it is modified or released.

The joint array is in source preorder, with parents before children. Array indices identify
joints; names need not be unique, and end sites have `name = null`. A joint's `channelOrder()`
maps `tx`, `ty`, `tz`, `rx`, `ry`, `rz` to X/Y/Z position and rotation. Motion values remain
frame-major and retain the exact per-joint channel order.

The frame interval is the positive finite value encoded in seconds. Rotations remain degrees;
positions and offsets retain file coordinates and units. No assumed 60 Hz rate, unit conversion,
dataset trimming or bind-pose rotation is substituted.

## Evaluate local or global poses

```zig
const wingman = @import("wingman");

pub fn jointOrigins(
    motion: *const wingman.bvh.Motion,
    frame_index: usize,
    storage: []wingman.RigidTransform,
) !?[]wingman.RigidTransform {
    const sample = motion.frame(frame_index) orelse return null;
    return try wingman.bvh.globalPoseInto(sample, storage, .{});
}
```

| Operation | Result |
| --- | --- |
| `localPoseInto(sample, destination, options)` | One transform relative to each joint's parent |
| `globalPoseInto(sample, destination, options)` | One transform in the file's coordinate system |
| `RigidTransform.transformPoint(point)` | A local point rotated and translated into the next space |
| `parent.compose(child)` | A transform applying the child, then its parent |

There is one result per joint, including roots and end sites. The returned slice is the used
prefix of caller storage; its remaining tail stays unchanged. No allocation or scheduler is
needed. Joint origins are the transforms' `translation` values. Local end-site rotation is identity;
the global result inherits the parent's rotation. No additional bone-alignment rotation is inferred.

`PoseOptions.length_scale` is a positive finite multiplier for offsets and position channels.
It defaults to one, preserving file units. `position_channels = .add_offset` adds each encoded
position coordinate to its static offset. Choose `.replace_offset` to replace only the axes
having position channels, as some producers/importers expect. Parsing is unaffected by either
interpretation. Coordinate-system conversion remains the caller's choice.

Rotation channels compose intrinsically in their declared order: Z, X, Y means `Rz * Rx * Ry`
for column vectors. Position channels operate in parent axes even when interleaved with rotations.
`RigidTransform` stores a row-major binary64 matrix and translation, applying
`rotation * point + translation`. Its public fields and `identity` value own no storage.
`isFinite()` checks all components without asserting orthonormality, handedness or a valid rotation.
Caller-created transforms are not normalized; composition and point conversion can overflow.

Pose admission checks scale, exact channel width, output capacity, aliasing and finite samples
before writing. The entire offered destination must be disjoint from joint records, copied names
and sample values, including unused capacity. Admission failures leave output unchanged.
Arithmetic overflow returns `NonFiniteResult` after any completed prefix; the failing joint and
remaining output stay unchanged. Do not use the partial result as a complete pose.

## Syntax, limits and diagnostics

The reader supports forests, branching, repeated names, end sites, zero-channel joints,
nonroot position channels, different rotation orders and zero-frame motions. Named joints
require `OFFSET` then `CHANNELS` before children. Only the six standard case-sensitive channels
are accepted, without duplicates in a joint. Hierarchy traversal uses parent links rather than
recursive calls that grow with nesting.

ASCII tokens, LF/CRLF, an initial UTF-8 BOM and finite decimal/exponent numbers are accepted.
Unknown fields, unknown channels, malformed numbers, incomplete frames and trailing tokens fail.
By default, each nonempty frame occupies one nonblank line with exactly the channel count.
Choose `frame_layout = .whitespace` when declared counts should delimit wrapped or compact
frames instead. Empty-channel frames need no value rows. Nonfinite final sample times fail.

`ParseOptions.limits` independently bounds input bytes, line bytes, token bytes, joints, nesting,
frames and values. Defaults allow 256 MiB of input, 1 MiB lines, 256-byte tokens, 4,096 joints,
depth 128, one million frames and 64 million values. A root counts as depth one; an end site adds
a level. Allocation-size arithmetic is checked. Callers can adjust limits for their captures;
these ceilings do not promise that enough backing memory is available.

Pass an optional `Diagnostic` to receive the failure's byte offset, one-based line and reason.
Success and `OutOfMemory` leave it unchanged. A diagnostic overlapping the source is refused
with `AliasedStorage` without changing that memory. Other parse failures release all partial
allocations and publish no owner.

## Implementation and references

The [public entry](../src/bvh.zig) presents the API. Under `src/bvh/`, `model.zig` owns retained
data and views, `text.zig` owns bounded lexical/numeric admission, `parse.zig` materializes complete
motions, and `pose.zig` interprets channels and composes parents. Authored controls live in
`fixtures.zig`; tests remain beside their implementations. Shared
[`RigidTransform` support](../src/common/rigid_transform.zig) owns geometric arithmetic and its inline
tests. Callers use the exported `wingman.RigidTransform` type. BVH and Acclaim also share the strict
numeric reader in [`common/ascii_number.zig`](../src/common/ascii_number.zig); its assertions stay
with that implementation.

Short plain decimals use exactly represented significands and powers of ten with one binary64
division; other spellings use the selected standard parser. Pose evaluation constructs full
intrinsic rotations directly, preserves partial-channel paths and avoids redundant identity
products for static children. Vector lanes evaluate independent matrix components while keeping
the product/addition order. These mechanisms preserve the numeric contract rather than selecting
a different precision mode.

The historical [Biovision format description](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)
explains hierarchy, channel ordering and motion framing. BVH supplies translational offsets but
no complete rotational bind pose. Applications must resolve producer conventions explicitly.
The package embeds authored controls, not external motion-capture datasets or reference software.
