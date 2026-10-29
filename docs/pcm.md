# PCM sample conversion

Pulse-code modulation (PCM) stores each audio sample as an integer or floating-point value.
`wingman.pcm` converts those bytes to caller-owned `f32` samples and writes normalized samples as
little-endian PCM16. Use it between a container reader and audio processing, or to prepare sample
bytes for a writer.

A sample is one channel value. A stereo frame contains two samples; rate, channel layout and
interleaving belong to the caller. Conversion preserves input order, allocates nothing and retains
no buffer, allocator or scheduler. Container inspection is a separate operation, such as
[`wingman.riff`](riff.md).

## Decode into caller storage

Choose an `Encoding` in `Format`, count complete samples with `sampleCount`, then provide enough
`f32` storage. `decodeInto` returns its used prefix and leaves spare elements untouched. Encoded
bytes can be unaligned and need no padding; typed `f32` storage has its normal Zig alignment.

```zig
const std = @import("std");
const pcm = @import("wingman").pcm;

test "decode packed signed PCM24" {
    const bytes = [_]u8{
        0, 0, 128, 255, 255, 255, 0, 0, 0, 255, 255, 127,
    };
    const format: pcm.Format = .{ .encoding = .signed24 };
    try std.testing.expectEqual(4, try pcm.sampleCount(bytes.len, format));
    var storage: [6]f32 = @splat(123);
    const samples = try pcm.decodeInto(&bytes, &storage, format);
    try std.testing.expectEqualSlices(
        f32,
        &.{ -1, -1.0 / 8388608.0, 0, 8388607.0 / 8388608.0 },
        samples,
    );
    try std.testing.expectEqualSlices(f32, &.{ 123, 123 }, storage[4..]);
}
```

The returned slice borrows the destination, not the encoded input. Input can retire when the call
returns. Keep destination storage live while using the result; free an allocated buffer through
its original full allocation, rather than through the shortened returned slice.

## Representations and numerical policy

| Encoding | Bytes per sample | Interpretation |
| --- | --- | --- |
| `.unsigned8` | 1 | Unsigned integer with a midpoint bias |
| `.signed16` | 2 | Signed two's-complement integer |
| `.signed24` | 3 | Packed signed two's-complement integer |
| `.signed32` | 4 | Signed two's-complement integer |
| `.float32` | 4 | Finite IEEE binary32 word |

All encoded words are little-endian, independently of the host. `Format.valid_bits = null` selects
the whole container width. Integers permit 1 through that width; `.float32` permits only 32.
When precision is smaller than the container, meaningful bits occupy the high end. The converter
ignores low padding bits. A container format that requires zero padding must check that policy.

```zig
const std = @import("std");
const pcm = @import("wingman").pcm;

test "read twelve meaningful bits from sixteen-bit containers" {
    const bytes = [_]u8{ 255, 127, 15, 128 };
    var output: [2]f32 = undefined;
    const samples = try pcm.decodeInto(
        &bytes,
        &output,
        .{ .encoding = .signed16, .valid_bits = 12 },
    );
    try std.testing.expectEqualSlices(f32, &.{ 2047.0 / 2048.0, -1 }, samples);
}
```

For an integer with `b` meaningful bits, decoding subtracts the unsigned midpoint where needed,
then divides by `2^(b-1)`. The negative endpoint becomes -1. The mathematical positive endpoint
is below 1, but a full-scale 32-bit integer can round to +1 in `f32`. Conversion to `f32` cannot
preserve every 32-bit integer; retain source bytes when exact integer recovery is needed.

Finite `.float32` words preserve their bits, including negative zero, subnormals and values outside
[-1,1]. NaN and infinity produce `InvalidSamples`. This finite-only admission is the codec's
policy. A float failure can modify the used destination region; discard that unpublished result.

Full-precision PCM8 and PCM16 use target-selected SIMD bodies and exact scalar tails. Other
precisions use scalar conversion. These paths share the same numerical contract and do not read
beyond the complete supplied samples. No runtime CPU dispatcher or padding reservation is needed.

## Encode normalized PCM16

`encodePcm16Into` returns a borrowed byte prefix; `writePcm16` accepts a concrete `*std.Io.Writer`.
Both validate every input sample before writing. Samples must be finite and in [-1,1].
Quantization multiplies by 32768, rounds halfway away from zero and clamps the positive endpoint
to 32767. The negative endpoint is -32768. There is no dithering or automatic gain adjustment.

```zig
const std = @import("std");
const pcm = @import("wingman").pcm;

test "encode the same PCM16 through storage and a writer" {
    const samples = [_]f32{ -1, 0.5, 1 };
    var bytes: [8]u8 = @splat(0xa7);
    const encoded = try pcm.encodePcm16Into(&samples, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 0, 64, 255, 127 }, encoded);
    try std.testing.expectEqualSlices(u8, &.{ 0xa7, 0xa7 }, bytes[6..]);
    var writer_bytes: [6]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_bytes);
    try pcm.writePcm16(&samples, &writer);
    try std.testing.expectEqualSlices(u8, encoded, writer.buffered());
}
```

The caller owns Writer storage, allocation and flushing. A file writer supplies its `interface`
and uses the caller-selected `std.Io`. A backend failure can leave a prefix already buffered or
sent. Input must be disjoint from Writer backing storage; that is a caller precondition.

## Admission, overlap and lifetime

Decoder format, whole-sample length, capacity and overlap failures occur before writes. Finite-float
admission happens during conversion, so it can leave partial output. Decoding never modifies source.
Integer and float input outside the selected representation are not inferred from a file header.

Caller-buffer encoding checks normalized input before capacity and overlap, preserving the whole
destination on any admission failure. Both conversion directions reject source overlap with the
**used** destination. Touching spans are disjoint; source overlap confined to unused destination
capacity is allowed. Byte-range checks compare address differences instead of forming overflowing
end pointers. No view or authority is retained after the call beyond the returned destination slice.

## API and supported scope

| Operation or type | Contract |
| --- | --- |
| `Encoding.byteCount`, `Format` | Container width and optional high-aligned precision |
| `sampleCount` | Validates format and complete encoded-sample geometry |
| `decodeInto` | Converts all source into a used `f32` destination prefix |
| `validatePcm16` | Validates all normalized input without writing |
| `encodePcm16Into` | Encodes into caller bytes, preserving spare output |
| `writePcm16` | Writes through `std.Io.Writer`; caller owns flushing |

`DecodeError` distinguishes invalid format, incomplete data, insufficient output, overlap and
nonfinite samples. Caller-buffer encoding returns `EncodeError` for invalid normalized samples,
byte-count overflow, insufficient output or overlap. Validation returns only `InvalidSamples` or
`SizeOverflow`; Writer calls add `WriteFailed`. Writer aliasing remains a caller precondition.

This profile decodes little-endian PCM8/16/24/32 and finite binary32, and encodes PCM16. Callers
handle fragmented samples, container parsing, byte-order adaptation, channel policy, resampling
and playback. Generate the API reference with `zig build docs`; run `zig build pcm-example` to see
the exact PCM16 bytes and the quantized positive endpoint. No throughput claim is made.

Representation background: Microsoft's [PCM data types] and [valid-bit containers]. Numerical
normalization, finite-only float admission and output rounding are the explicit policies above.

[PCM data types]: https://learn.microsoft.com/en-us/windows/win32/multimedia/devices-and-data-types
[valid-bit containers]: https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ksmedia/ns-ksmedia-waveformatextensible
