# PCM sample conversion

Pulse-code modulation (PCM) stores audio as integer or floating-point channel samples.
`wingman.pcm` converts between encoded bytes and caller-owned samples without parsing a container,
assigning a sample rate or allocating memory. Use it when a file reader or protocol has already
identified the sample representation. For a WAVE or RF64 file, [`wingman.wav`](wav.md) handles
container framing and chooses the appropriate codec.

A sample is one channel value. A stereo frame contains two samples. Conversion preserves their
order; the caller supplies the channel layout and controls any resampling, gain, dither or playback.

## Choose the representation

`Format` chooses an `Encoding`, an optional `valid_bits` count and an `endian` byte order. The
default byte order is little-endian. Byte order has no effect on one-byte samples.

| Encoding | Container | Interpretation |
| --- | --- | --- |
| `.unsigned8`, `.unsigned16`, `.unsigned24`, `.unsigned32` | 1, 2, 3 or 4 bytes | Unsigned integer with a midpoint bias |
| `.signed8`, `.signed16`, `.signed24`, `.signed32` | 1, 2, 3 or 4 bytes | Signed two's-complement integer |
| `.float32`, `.float64` | 4 or 8 bytes | Finite IEEE binary32 or binary64 |

`valid_bits = null` selects the full container width. Integer formats accept one through the
container width; floating-point formats require their full width. Integer significant bits occupy
the high end of the numerical container. Decoding ignores low padding bits; encoding writes zero
padding. A format that requires zero padding in its input must check that separately.

## Decode normalized samples

`sampleCount` validates format and complete-sample geometry; it does not inspect sample values.
Provide that many `f32` elements to `decodeInto`. Its result borrows the used destination prefix;
the source can retire after the call and spare destination elements remain untouched. Encoded bytes
can be unaligned. Integer samples are normalized by their precision's power-of-two midpoint. The
negative endpoint becomes -1. A full-scale signed32 value can round to +1 because not every 32-bit
integer is representable in `f32`.

Integer samples with more than 25 meaningful bits can round to `f32`; the result can depend on the
executing thread's floating-point environment and the target. In parallel WAVE decoding, a job uses
its executing worker's environment, which can differ from the calling thread's.

```zig
const std = @import("std");
const pcm = @import("wingman").pcm;

test "decode big-endian signed PCM24" {
    const format: pcm.Format = .{ .encoding = .signed24, .endian = .big };
    const bytes = [_]u8{ 0x80, 0, 0, 0, 0, 0, 0x7f, 0xff, 0xff };
    try std.testing.expectEqual(3, try pcm.sampleCount(bytes.len, format));
    var storage: [4]f32 = @splat(42);
    const samples = try pcm.decodeInto(&bytes, &storage, format);
    try std.testing.expectEqualSlices(f32, &.{ -1, 0, 8388607.0 / 8388608.0 }, samples);
    try std.testing.expectEqual(42, storage[3]);
}
```

Finite binary32 input retains its bits, including negative zero, subnormals and values outside
[-1, 1]. Binary64 input narrows to binary32 with nearest-even rounding, including signed underflow.
Nonfinite input or a narrowed nonfinite result produces `InvalidSamples`. Float conversion can
write earlier samples before a content error; discard the unpublished result on error.

## Encode and write normalized samples

`encodeInto` writes a chosen representation to caller storage; `writeAll` uses `*std.Io.Writer`.
Both validate the format, encoded extent and every sample before writing. For integer output,
inputs must be finite and in [-1, 1]. They are scaled by the precision midpoint, rounded halfway
away from zero and clamped to the signed range before any unsigned bias is applied. There is no
implicit dither or gain. Float output accepts finite values outside that range; binary32 preserves
`f32` bits and widening to binary64 is exact.

```zig
const std = @import("std");
const pcm = @import("wingman").pcm;

test "write normalized PCM16" {
    const format: pcm.Format = .{ .encoding = .signed16 };
    const samples = [_]f32{ -1, 0.5, 1 };
    var bytes: [8]u8 = @splat(0xa7);
    const encoded = try pcm.encodeInto(&samples, &bytes, format);
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 0, 64, 255, 127 }, encoded);
    try std.testing.expectEqualSlices(u8, &.{ 0xa7, 0xa7 }, bytes[6..]);
    var writer_bytes: [6]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_bytes);
    try pcm.writeAll(&samples, &writer, format);
    try std.testing.expectEqualSlices(u8, encoded, writer.buffered());
}
```

## Exact integer and binary64 samples

`pcm.int32` converts integer wire formats to and from left-aligned signed `i32` samples. A sample
represents its integer value divided by 2^31; unsigned midpoint bias is removed. Encoding rejects
`PrecisionLoss` if the requested representation would discard nonzero low sample bits. It does not
accept float wire formats. Decoding ignores low wire padding, so original nonzero padding cannot be
recovered from the sample values alone.

`pcm.float64` converts through `f64` samples. All supported integer and finite binary32 inputs are
represented exactly; finite binary64 input retains its bits. Encoding to integer uses the same
half-away rule as `f32` conversion. Binary32 output narrows nearest-even and rejects a result that
would be nonfinite. Both namespaces offer `decodeInto`, `validate`, `encodeInto` and `writeAll`;
their encoding operations take `.{ .format = format }` options.

```zig
const std = @import("std");
const pcm = @import("wingman").pcm;

test "rewrite unsigned PCM24 with exact integer samples" {
    const source_format: pcm.Format = .{
        .encoding = .unsigned24,
        .valid_bits = 20,
        .endian = .big,
    };
    const source = [_]u8{ 0x80, 0, 0x0f, 0xff, 0xff, 0xff };
    var samples: [2]i32 = undefined;
    const decoded = try pcm.int32.decodeInto(&source, &samples, source_format);
    try std.testing.expectEqualSlices(i32, &.{ 0, 0x7fff_f000 }, decoded);

    var storage: [6]u8 = undefined;
    const canonical = try pcm.int32.encodeInto(decoded, &storage, .{ .format = source_format });
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0, 0, 0xff, 0xff, 0xf0 }, canonical);
}
```

For binary64 samples, select binary32 wire output when its precision is sufficient:

```zig
const std = @import("std");
const pcm = @import("wingman").pcm;

test "encode binary64 samples as binary32" {
    const samples = [_]f64{ 1.5, -0.0 };
    var bytes: [8]u8 = undefined;
    const encoded = try pcm.float64.encodeInto(
        &samples,
        &bytes,
        .{ .format = .{ .encoding = .float32 } },
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0xc0, 0x3f, 0, 0, 0, 0x80 }, encoded);
}
```

## Storage and failure

Decoding validates format and complete sample extent, then capacity and overlap with the used
output before writing. Encoding validates format, checked extent and all samples before checking
capacity and overlap. Buffer admission failures preserve the complete destination, and spare
capacity is left untouched on success. Touching spans are disjoint; source overlap confined to
unused destination capacity is permitted.

`sampleCount` reports `InvalidFormat` for an unsupported format or precision and `InvalidData`
for an incomplete sample. Decoders also report `DestinationTooSmall` or `Aliasing` before
writing; the `f32` and `f64` decoders report `InvalidSamples` for invalid float content.
`pcm.int32` rejects float wire formats as `InvalidFormat`.

Encoding validation reports `InvalidFormat` or `SizeOverflow`; it also reports `InvalidSamples`
for rejected `f32` or `f64` samples, or `PrecisionLoss` for an inexact `i32` sample. Buffer
encoding adds `DestinationTooSmall` and `Aliasing`. Writer operations report validation and
`std.Io.Writer` errors; they do not perform the buffer overlap check.

Writer storage must be disjoint from input. A backend failure can leave a byte prefix buffered or
sent, and the caller owns flushing. Returned slices borrow their destination; release an allocation
using its original full slice. No operation retains the source, destination, writer or allocator.

`pcm` does not parse containers, retain fragmented samples between calls, change channel layout,
resample, dither or play audio. Generate the API reference with `zig build docs` and run
`zig build pcm-example` for a complete PCM conversion.
