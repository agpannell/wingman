# Acclaim skeletons and motion clips

Acclaim separates a reusable skeleton in an ASF file from its recorded movement in AMC files. An ASF
supplies named bones, geometry, axis calibration and ordered channels; each AMC frame supplies the
channel values for that skeleton. Use `wingman.acclaim` for motion analysis, animation tools or
joint/segment extraction when one skeleton serves several clips.

Channels hold recorded positions, angles or lengths. A pose interprets those raw values and the
skeleton's static geometry as one transform per bone. Local transforms locate each bone relative
to its parent; global transforms locate it in the file's coordinate system. Parsing and pose
interpretation have separate owners so several clips can reuse the same geometry and calibration.

The library owns parsed data and prepares a skeleton once for repeated local/global poses. Callers
provide pose storage and choose length conversion and root-orientation policy explicitly. It retains
original IDs, frame numbers and units without adding playback, interpolation, skinning, retargeting
or file writing.

Use [Zig 0.17.0 and the package setup](../README.md#use-it-in-a-project). Run
`zig build acclaim-example` for a complete
[paired input and runnable example](../examples/acclaim.zig). It poisons the original inputs, checks
sparse-channel carry, separates array indices from ASF IDs and obtains a segment endpoint from a
prepared pose.

## Parse a skeleton and one or more clips

```zig
const std = @import("std");
const acclaim = @import("wingman").acclaim;

pub fn readClip(
    allocator: std.mem.Allocator,
    skeleton: acclaim.Skeleton.View,
    bytes: []const u8,
) !acclaim.Motion {
    return acclaim.Motion.parseAlloc(allocator, bytes, skeleton, null, .{});
}
```

First call `Skeleton.parseAlloc(allocator, asf_bytes, diagnostic, options)`. The result owns the
complete copied ASF, bone records and parent-before-child traversal order. Names, documentation and
opaque metadata survive the original input. Its `view()` borrows immutable backing for any number
of clips.

Call `Motion.parseAlloc(allocator, amc_bytes, skeleton.view(), diagnostic, limits)` for each clip.
The motion owns original frame numbers, dense frame-major binary64 values and copied header
metadata; AMC input can retire after success. It borrows the skeleton rather than duplicating it. No
owner retains an allocator. Release every motion and evaluator before its skeleton, exactly once
with each construction allocator. Copies of an owner alias storage; do not release both copies.
Borrowers retain slices into backing allocations rather than the owner's address. Keep managed
fields and backing unchanged while borrowed.

`motion.frame(index)` uses a zero-based array position and returns a borrowed `Motion.Frame`, or
`null` beyond the stored frames. `frame.number` remains the positive original AMC frame number,
including gaps. `frame.boneValues(bone_index)` borrows one bone's values in declared channel order.
Static bones return an empty slice; an invalid bone index returns `null`. Frame numbers supply no
sample interval; a timestamp, capture rate or interpolation policy is caller data.

Bone zero is the implicit root with ASF ID zero. Other records retain declaration order and their
independent numeric IDs. Parent links, `traversal_order` entries, `findBone(name)` and
`boneValues(index)` use array indices, not ASF IDs. These records live under `Skeleton.Bone`.
Its `AxisOrder` describes static axis composition and its `Limit` retains editing bounds for each
active channel.
`bone.channels[0..bone.channel_count]` is the ordered active prefix. Names are unique and
case-sensitive. `Skeleton.Bone.channelOrder()` identifies the stored `tx`, `ty`, `tz`, `rx`, `ry`,
`rz` and optional length `l` values. Static bones still participate in hierarchy and poses.

## Preserve sparse frames and unit declarations

AMC frame numbers must increase strictly; numbered frames may contain bone rows in any order.
`:FULLY-SPECIFIED` requires every animated bone in every frame. Without it, the first frame must be
complete; later frames carry omitted bones forward. Duplicate/unknown bones and wrong channel counts
fail, including in the final frame. This materializes complete frames, not interpolation.

`:DEGREES` or `:RADIANS` before the first frame sets its motion angle unit. Without an AMC
declaration, the ASF angle unit supplies the fallback. Static axis angles always use ASF units; each
frame's rotations use its own `angle_unit`. Raw stored values are never rewritten to another unit.
ASF mass/length declarations are metadata rather than a universal SI conversion.

## Prepare and evaluate poses

```zig
const wingman = @import("wingman");

pub fn boneOrigins(
    evaluator: *const wingman.acclaim.PoseEvaluator,
    frame: wingman.acclaim.Motion.Frame,
    storage: []wingman.RigidTransform,
) ![]wingman.RigidTransform {
    return evaluator.globalPoseInto(frame, storage);
}
```

`PoseEvaluator.initAlloc(allocator, skeleton.view(), options)` caches static axis bases and
parent-segment offsets. It borrows that exact immutable skeleton and owns its preparation array.
Reuse it across frames and clips sharing the same backing. A separately parsed identical ASF is a
different skeleton and returns `WrongSkeleton` during evaluation. Identity requires the same
`bones` and `traversal_order` slice addresses/lengths, copied unit metadata and channel width. Release
preparation with `evaluator.deinit(allocator)` before releasing the skeleton. Disjoint output
storage permits concurrent evaluation of immutable frames; no scheduler or allocation is needed
per pose.

`localPoseInto` returns one parent-relative `wingman.RigidTransform` per bone. `globalPoseInto`
composes them into file coordinates, using `traversal_order` even when a parent was declared after
its child. Both return the used prefix of caller storage in declaration order and leave the unused
tail unchanged. Root is included. A transform's translation is the bone's proximal joint, not its
distal endpoint. Transform `bone.direction * bone.length * length_scale` as a point to obtain that
endpoint.

Acclaim rotations apply the first declared rotation first. For column vectors, X then Y then Z
therefore gives `Rz * Ry * Rx`, unlike BVH's intrinsic order. Nonroot local rotation is
`C * M * transpose(C)`, where C is the static ASF basis and M the frame rotation. Its translation
comes from the parent's direction and length. Root translation adds channels to static position in
file axes, independently of their placement among rotation channels.

`PoseEvaluator.Options.length_scale` must be positive and finite; one preserves file units. Choose a
conversion only when the producer's units are known. `root_orientation_policy = .rest` uses `C * M`
for a nonzero root orientation. Its selector type is `PoseEvaluator.Options.RootOrientationPolicy`.
Choose `.basis` for `C * M * transpose(C)`. Both agree for zero root orientation; neither modifies
the parsed values. The shared rigid type uses row-major binary64 rotation matrices, column vectors
and no automatic normalization, bone alignment or coordinate conversion.

Length channels and nonroot translation channels remain available through raw frames, but this pose
profile rejects their undefined interpretation with `UnsupportedChannel` at preparation. Parsed
editing limits remain metadata and do not clamp frames.

## Failure, storage and admission

`PoseEvaluator.InitError` includes allocation failure, InvalidScale, UnsupportedChannel and
NonFiniteResult. Preparation failure returns no evaluator and frees partial preparation.
`PoseEvaluator.EvaluateError` contains WrongSkeleton, InvalidFrame, OutputTooSmall, AliasedStorage
and NonFiniteResult; pose evaluation allocates nothing. Skeleton and motion parsing likewise release
partial allocations and publish no owner on failure. Borrowed names, views and frames expire when
their owner is released or modified; evaluators and motions also require the original skeleton to
remain unchanged.

`InvalidFrame` means the frame has the wrong channel width or a nonfinite channel value. A
caller-created `Motion.Frame` may supply finite values for the same parsed skeleton; its number
does not affect pose evaluation. Its `angle_unit` still determines the rotation units.

Pose admission verifies skeleton identity, exact channel width, destination capacity, relevant
aliasing and finite values before writing. Keep evaluator fields and skeleton backing immutable
while borrowed. The used output prefix is checked against the evaluator descriptor, prepared array,
bone and `traversal_order` arrays and frame values. Unused output capacity is outside these checks.
Names and other metadata remain immutable by caller obligation. Admission errors preserve output.
Arithmetic overflow returns `NonFiniteResult`: local evaluation may leave a completed prefix;
global evaluation may leave a completed subset in traversal order. The failing bone and unused tail
stay unchanged.
Treat neither partial result as a complete pose.

`ParseLimits` independently bounds input bytes, line/token size, bones, depth, frames and values.
Pass it through `Skeleton.ParseOptions.limits` for ASF, or directly as the final argument to
`Motion.parseAlloc` for AMC. Defaults are 128 MiB input, 65,536-byte lines, 256-byte tokens, 4,096
bones including root, depth 128, one million frames and 67,108,864 scalar values. Allocation-size
arithmetic is checked; a limit is not a guarantee of backing memory. Raise capacities explicitly for
larger captures.

Pass an optional `Diagnostic` for a source byte offset, one-based line and reason. Success and
`OutOfMemory` leave it unchanged. A record overlapping input is refused with `AliasedStorage`
without writing that memory; other parse failures set it. LF/CRLF and `#` comments are supported;
NUL, lone CR, malformed numbers, incomplete records, duplicate identities and
invalid/disconnected/cyclic hierarchies fail. Names resembling keywords or having signed prefixes
retain their identity; integer names are refused because AMC uses integer tokens for frame markers.

ASF version 1.10 is supported. `Skeleton.ParseOptions.unknown_sections = .preserve` retains unknown
top-level sections in the copied source without interpreting them; choose `.reject` to refuse those
sections. Extra unit labels remain opaque metadata. Unsupported fields inside known bone/root
records and unknown AMC directives are refused. Editing bounds may include infinity; geometry,
motion values and prepared results must remain finite.

## Implementation and references

The [public entry](../src/acclaim.zig) presents the paired format API.
[Skeleton](../src/acclaim/Skeleton.zig) owns ASF construction, static metadata and borrowed views;
[Motion](../src/acclaim/Motion.zig) owns AMC construction, frames and clip cleanup;
[PoseEvaluator](../src/acclaim/PoseEvaluator.zig) owns calibration and allocation-free
interpretation. The internal [Lexer](../src/acclaim/Lexer.zig) bounds text admission. Authored
controls live in `fixtures.zig`, with tests beside their implementations. BVH and Acclaim share
strict numeric admission in [`common/ascii_number.zig`](../src/common/ascii_number.zig) and the
[`RigidTransform` value](../src/common/RigidTransform.zig). Callers use `wingman.RigidTransform`;
its shared [3×3 matrix arithmetic](../src/common/matrix3.zig) stays internal.

The skeleton reservation pass scans boundaries and names before materialization without imposing a
fixed bone count or repeatedly splitting whole lines. Motion loading counts frames and reserves
dense storage, using a name index for rows. Static calibration is computed once, while prepared
evaluation keeps declared arithmetic and rotation order. These mechanisms preserve full ownership
and binary64 values rather than trading precision or completed work for speed.

The historical
[Acclaim 1.10 description](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/ASF-AMC.html)
explains the paired formats and axis interpretation. The package embeds authored controls, not CMU
captures or third-party parsing/animation code.
