# Microsoft and IMA/DVI ADPCM block decoding

ADPCM stores small corrections to predicted audio amplitudes and changes their scale as decoding
proceeds. This uses fewer payload bits than PCM16 while losing some amplitude precision. Decoding
recovers the represented samples; it cannot recover information discarded by the encoder.

`wingman.adpcm` decodes the **four-bit Microsoft and IMA/DVI WAVE block layouts** into caller-owned
normalized floats. Supply the layout and complete encoded blocks from a container parser or
protocol. This library handles sample reconstruction independently of WAVE parsing, sampling rate,
playback and allocation policy. A **frame** contains one sample per channel at the same instant.
Mono and stereo are supported; stereo output alternates left/right samples in frame order.

Use [Zig 0.17.0 and the package setup](../README.md#use-it-in-a-project). From a checkout, run
`zig build adpcm-example` to decode both layouts, inspect their PCM16 values and validate prefix
output. [The complete example](../examples/adpcm.zig) also composes with the PCM library.

## Describe the blocks

`Format` is a value passed to each operation. It retains no resource:

| Field | Meaning |
| --- | --- |
| `encoding` | `.microsoft_wave` or `.ima_wave`; there is no implicit detection |
| `channels` | One or two |
| `block_bytes` | Complete encoded bytes per block, including seed headers |
| `frames_per_block` | Exact decoded frames per block, including seed samples |
| `coefficients` | Borrowed little-endian signed `i16` pairs for Microsoft prediction; four bytes per pair |

For IMA, let `C` be the channel count and `P = block_bytes - 4*C`. `P` must be a multiple of `4*C`,
and `frames_per_block` must equal `1 + 2*P/C`. For Microsoft, use `P = block_bytes - 7*C` and
`frames_per_block = 2 + 2*P/C`. Seed-only blocks are valid in both layouts. Every operation checks
these relations and uses checked count arithmetic. The source must contain whole blocks.

Microsoft requires a nonempty coefficient slice whose length is a multiple of four. Each block's
predictor index selects one available pair. The raw API accepts custom pairs; it does not enforce
a container's standard-table policy or supply a default table. Coefficients are immutable for the
call. IMA does not read them, but any supplied coefficient span still participates in alias checks.
Use the empty default for ordinary IMA input.

## Count and decode

| API | Result |
| --- | --- |
| `frameCount(byte_count, format)` | Whole decoded frame count after geometry/extent checks |
| `decodeInto(source, destination, format)` | All frames, returned as the used `[]f32` prefix |
| `decodePrefixInto(source, destination, frames, format)` | Requested whole-frame prefix, after validating all input |
| `DecodeError` | `InvalidFormat`, `InvalidData`, `SizeOverflow`, `DestinationTooSmall` or `Aliasing` |

`frameCount` does not read source or predictor headers. A successful count is useful for sizing
output, but does not prove that the blocks decode. Its errors are `InvalidFormat`, `InvalidData`
and `SizeOverflow`. An empty source still requires a valid `Format` and produces no samples.

```zig
const std = @import("std");
const adpcm = @import("wingman").adpcm;

test "count complete IMA blocks" {
    const format: adpcm.Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 8,
        .frames_per_block = 9,
    };
    try std.testing.expectEqual(18, try adpcm.frameCount(16, format));
    try std.testing.expectError(error.InvalidData, adpcm.frameCount(15, format));
}
```

Each decoded sample is a signed PCM16 integer divided by **32768**, exactly representable in
`f32`. Output therefore lies in `[-1, 32767/32768]`, with no additional normalization rounding.
The following illustrative Microsoft block uses a single custom pair `(256, 0)`: predict the
previous sample, then apply corrections of 16 and 32. Seed samples appear in time order in output.

```zig
const std = @import("std");
const adpcm = @import("wingman").adpcm;

test "decode a raw Microsoft block" {
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    const block = [_]u8{ 0, 16, 0, 100, 0, 0x9c, 0xff, 0x12 };
    var output: [6]f32 = @splat(42);
    const samples = try adpcm.decodeInto(&block, &output, .{
        .encoding = .microsoft_wave,
        .channels = 1,
        .block_bytes = block.len,
        .frames_per_block = 4,
        .coefficients = &coefficients,
    });
    try std.testing.expectEqualSlices(
        f32,
        &.{ -100.0 / 32768.0, 100.0 / 32768.0, 116.0 / 32768.0, 148.0 / 32768.0 },
        samples,
    );
    try std.testing.expectEqualSlices(f32, &.{ 42, 42 }, output[4..]);
}
```

The [PCM library](pcm.md#encode-normalized-pcm16) can write these samples as little-endian PCM16.
They already lie on its exact PCM16 grid, so that composition adds no quantization change.

## Prefix output validates the complete input

Use `decodePrefixInto` when the output should omit block padding frames or when only an initial
section is needed. It saves output storage while still processing every block's predictor headers
and adaptive updates. A zero-frame request validates nonempty input too. It is not a way to skip
invalid data or to promise decoding work proportional to the returned prefix.

```zig
const std = @import("std");
const adpcm = @import("wingman").adpcm;

test "omitted IMA blocks still validate" {
    const format: adpcm.Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 4,
        .frames_per_block = 1,
    };
    const source = [_]u8{ 0, 128, 0, 0, 255, 127, 0, 0 };
    var output: [1]f32 = undefined;
    const samples = try adpcm.decodePrefixInto(&source, &output, 1, format);
    try std.testing.expectEqualSlices(f32, &.{-1}, samples);
    try std.testing.expectError(
        error.InvalidData,
        adpcm.decodePrefixInto(&.{ 0, 0, 89, 0 }, &.{}, 0, format),
    );
}
```

## Ownership and failure

Operations allocate nothing and retain no input, coefficient table, output or scheduler. Keep
source and coefficients immutable through the call. The result borrows caller-owned destination
and contains `frames * channels` samples; input storage can be released when the call returns.
Successful conversion and every error preserve unused destination capacity.

Admission and content checks occur in this order:

1. Validate format and complete-block geometry; reject counts that overflow `usize`.
2. Reject `InvalidData` if the requested prefix exceeds the full frame count.
3. Check sample-count arithmetic, then reject insufficient destination capacity.
4. Reject `Aliasing` if source or coefficients overlap the **used output's byte span**.
5. Validate and decode every block, returning the prefix only on success.

Capacity and alias refusals leave the entire destination unchanged. Touching spans are disjoint;
input may occupy unused destination capacity. Later content failures can leave partially changed
used output: disregard that region unless the call succeeds. There is no successful partial result
or retained decoder state to resume. Blocks reset independently from their seed headers.

## Supported numerical profile

Microsoft reconstructs a prediction from two preceding samples and the selected coefficient pair.
Signed fractional predictions divide toward zero before the correction and feedback. This differs
from an arithmetic shift for negative fractions. Initial delta words are **unsigned 16-bit**.
Decoders interpreting high-bit delta words as signed can produce different samples; bit-exact
Windows ACM compatibility is not claimed.

Microsoft adaptive delta exceeding signed 32-bit range returns **`InvalidData`**, including an
omitted or final update. This is a deliberate decoder limit rather than a format-wide validity
rule. The decoder clips sample amplitudes to PCM16; it does not silently clamp delta to hide that
limit. IMA checks indices in `0..88`, ignores its reserved header byte, clips predictor amplitudes
and bounds adaptive indices. Nibble order and stereo grouping follow the selected WAVE layout.

The [Microsoft block description](https://www.mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/Docs/RIFFNEW.pdf)
and [IMA arithmetic](https://www.cs.columbia.edu/~hgs/audio/dvi/IMA_ADPCM.pdf) describe the formats.
Inline tests cover literal mono/stereo results, signed prediction, unsigned delta, source residues,
all tested prefix boundaries, omitted failures, storage admission and empty-input count limits.

Three-bit DVI, other ADPCM block layouts, more than two channels, encoding, containers, resampling,
playback and packet handling are outside this library's current surface. No throughput claim is
made by the examples or contract tests.
