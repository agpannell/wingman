# Acclaim skeletons and motion clips

Acclaim separates a reusable skeleton in an ASF file from its recorded movement in AMC files.
An ASF supplies named bones, geometry, axis calibration and ordered channels; each AMC sample
supplies the channel values for that skeleton. Use `wingman.acclaim` for motion analysis, animation
tools or joint/segment extraction when one skeleton serves several clips.

The library owns parsed data and prepares a skeleton once for repeated local/global poses.
Callers provide pose storage and choose length conversion and root-orientation policy explicitly.
It retains original IDs, frame numbers and units without adding playback, interpolation, skinning,
retargeting or file writing.

Use [Zig 0.17.0 and the package setup](../README.md#use-it-in-a-project). Run
`zig build acclaim-example` for a complete [paired input and runnable example](../examples/acclaim.zig).
It poisons the original inputs, checks sparse-channel carry, separates array indices from ASF IDs
and obtains a segment endpoint from a prepared pose.

## Parse a skeleton and one or more clips

```zig
const std = @import("std");
const acclaim = @import("wingman").acclaim;

pub fn readClip(
    allocator: std.mem.Allocator,
    skeleton: acclaim.SkeletonView,
    bytes: []const u8,
) !acclaim.Motion {
    return acclaim.parseMotionAlloc(allocator, bytes, skeleton, null, .{});
}
```

First call `parseSkeletonAlloc(allocator, asf_bytes, diagnostic, options)`. The result owns the
complete copied ASF, bone records and parent-before-child topology. Names, documentation and opaque
metadata survive the original input. Its `view()` borrows immutable backing for any number of clips.

Call `parseMotionAlloc(allocator, amc_bytes, skeleton.view(), diagnostic, options)` for each clip.
The motion owns original frame numbers, dense frame-major binary64 values and copied header
metadata; AMC input can retire after success. It borrows the skeleton rather than duplicating it.
No owner retains an allocator. Release every motion and evaluator before its skeleton, exactly once
with each construction allocator. Copies of an owner alias storage; do not release both copies.

`motion.frame(index)` uses a zero-based array position and returns a borrowed `Sample`, or `null`
beyond the stored samples. `sample.number` remains the positive original AMC frame number, including
gaps. `sample.boneValues(bone_index)` borrows one bone's values in declared channel order. Frame
numbers supply no sample interval; a timestamp, capture rate or interpolation policy is caller data.

Bone zero is the implicit root with ASF ID zero. Other records retain declaration order and their
independent numeric IDs. Parent links, topology entries, `findBone(name)` and `boneValues(index)`
use array indices, not ASF IDs. Names are unique and case-sensitive. `Bone.channelOrder()` identifies
the stored `tx`, `ty`, `tz`, `rx`, `ry`, `rz` and optional length `l` values. Static bones still
participate in hierarchy and poses.

## Preserve sparse samples and unit declarations

AMC frame numbers must increase strictly; numbered samples may contain bone rows in any order.
`:FULLY-SPECIFIED` requires every animated bone in every sample. Without it, the first sample must
be complete; later samples carry omitted bones forward. Duplicate/unknown bones and wrong channel
counts fail, including in the final frame. This materializes complete samples, not interpolation.

`:DEGREES` or `:RADIANS` before the first sample sets its motion angle unit. Without an AMC
declaration, the ASF angle unit supplies the fallback. Static axis angles always use ASF units;
each sample's rotations use its own `angle_unit`. Raw stored values are never rewritten to another
unit. ASF mass/length declarations are metadata rather than a universal SI conversion.

## Prepare and evaluate poses

```zig
const wingman = @import("wingman");

pub fn boneOrigins(
    evaluator: *const wingman.acclaim.PoseEvaluator,
    sample: wingman.acclaim.Sample,
    storage: []wingman.RigidTransform,
) ![]wingman.RigidTransform {
    return evaluator.globalPoseInto(sample, storage);
}
```

`PoseEvaluator.initAlloc(allocator, skeleton.view(), options)` caches static axis bases and
parent-segment offsets. It borrows that exact immutable skeleton and owns its preparation array.
Reuse it across samples and clips sharing the same backing. A separately parsed identical ASF
is a different skeleton and returns `WrongSkeleton` during evaluation. Release preparation with
`evaluator.deinit(allocator)` before releasing the skeleton. Distinct destinations permit concurrent
evaluation of immutable samples; no scheduler or allocation is needed per pose.

`localPoseInto` returns one parent-relative `wingman.RigidTransform` per bone. `globalPoseInto`
composes them into file coordinates, using topology even when a parent was declared after its child.
Both return the used prefix of caller storage in declaration order and leave the unused tail
unchanged. Root is included. A transform's translation is the bone's proximal joint, not its distal
endpoint. Transform `bone.direction * bone.length * length_scale` as a point to obtain that endpoint.

Acclaim rotations apply the first declared rotation first. For column vectors, X then Y then Z
therefore gives `Rz * Ry * Rx`, unlike BVH's intrinsic order. Nonroot local rotation is
`C * M * transpose(C)`, where C is the static ASF basis and M the sample rotation. Its translation
comes from the parent's direction and length. Root translation adds channels to static position
in file axes, independently of their placement among rotation channels.

`PoseOptions.length_scale` must be positive and finite; one preserves file units. Choose a conversion
only when the producer's units are known. `root_orientation = .rest` uses `C * M` for a nonzero
root orientation. Choose `.basis` for `C * M * transpose(C)`. Both agree for zero root orientation;
neither modifies the parsed values. The shared rigid type uses row-major binary64 rotation matrices,
column vectors and no automatic normalization, bone alignment or coordinate conversion.

Length channels and nonroot translation channels remain available through raw samples, but this
pose profile rejects their undefined interpretation with `UnsupportedChannel` at preparation.
Parsed editing limits remain metadata and do not clamp samples.

## Failure, storage and admission

Preparation failure returns no evaluator and frees partial preparation. Skeleton and motion parsing
likewise release partial allocations and publish no owner on failure. Borrowed names, views and
samples expire when their owner is released or modified; evaluators and motions also require the
original skeleton to remain unchanged.

Pose admission verifies skeleton identity, exact channel width, destination capacity, relevant
aliasing and finite values before writing. Keep the evaluator, all skeleton backing and sample values
immutable and disjoint from written output. Checked regions are the evaluator descriptor, prepared
array, bone/topology arrays and sample values; the used output prefix participates in those checks.
Metadata/name immutability remains a caller obligation. Admission errors preserve output.
Arithmetic overflow returns `NonFiniteResult`: local evaluation may leave a completed prefix;
global evaluation may leave a completed subset in topology order. The failing bone and unused tail
stay unchanged. Treat neither partial result as a complete pose.

`SkeletonParseOptions` and `MotionParseOptions` independently bound input bytes, line/token size,
bones, depth, frames and values. Defaults are 128 MiB input, 65,536-byte lines, 256-byte tokens,
4,096 bones including root, depth 128, one million samples and 64 million values. Allocation-size
arithmetic is checked; a limit is not a guarantee of backing memory. Raise capacities explicitly
for larger captures.

Pass an optional `Diagnostic` for a source byte offset, one-based line and reason. Success leaves
it unchanged; allocation failure need not provide a location. A record overlapping immutable input
is refused without writing that memory. LF/CRLF and `#` comments are supported; NUL, lone CR,
malformed numbers, incomplete records, duplicate identities and invalid/disconnected/cyclic
hierarchies fail. Names resembling keywords or having signed prefixes retain their identity;
integer names are refused because AMC uses integer tokens for frame markers.

ASF version 1.10 is supported. `SkeletonParseOptions.unknown_sections = .preserve` retains unknown
top-level sections in the copied source without interpreting them; choose `.reject` to refuse those
sections. Extra unit labels remain opaque metadata. Unsupported fields inside known bone/root
records and unknown AMC directives are refused. Editing bounds may include infinity; geometry,
motion values and prepared results must remain finite.

## Implementation and references

The [public entry](../src/acclaim.zig) groups the paired format API. Under `src/acclaim/`, `model.zig`
owns retained data/views, `text.zig` lexical admission, `skeleton.zig` ASF materialization,
`motion.zig` AMC completion and `pose.zig` prepared interpretation. Authored controls live in
`fixtures.zig`, with tests beside their implementations. BVH and Acclaim share strict numeric
admission in [`common/ascii_number.zig`](../src/common/ascii_number.zig) and geometric arithmetic in
[`common/rigid_transform.zig`](../src/common/rigid_transform.zig); the common namespace stays internal.

The skeleton reservation pass scans boundaries and names before materialization without imposing
a fixed bone count or repeatedly splitting whole lines. Motion loading counts frames and reserves
dense storage, using a name index for rows. Static calibration is computed once, while prepared
evaluation keeps declared arithmetic and rotation order. These mechanisms preserve full ownership
and binary64 values rather than trading precision or completed work for speed.

The historical [Acclaim 1.10 description](https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/ASF-AMC.html)
explains the paired formats and axis interpretation. The package embeds authored controls, not CMU
captures or third-party parsing/animation code.
