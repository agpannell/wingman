# WAVE and RF64 audio

WAVE stores audio samples and their rate, channel count and representation in a RIFF container.
RF64 extends its size fields for larger files. `wingman.wav` connects these containers to Wingman's
PCM, G.711 and ADPCM decoders, returning interleaved `f32` samples. It also writes complete
mono/stereo PCM16 RIFF files. Use the raw [sample codecs](pcm.md) when another format or protocol
already provides the sample layout; use [RIFF](riff.md) for generic chunk framing.

The API accepts a complete immutable byte slice. Reading that slice from a file or network, audio
playback, resampling and speaker placement belong to the caller. A **frame** contains one sample
per channel at the same instant; stereo samples alternate left/right in source order.

Use [Zig 0.17.0 and the package setup](../README.md#use-it-in-a-project). The complete
[WAVE example](../examples/wav.zig) writes a small stereo file, inspects its chunks, then compares
allocating, caller-buffer and `std.Io` decoding.

## Choose storage explicitly

| Operation | Storage and result |
| --- | --- |
| `parse`, `Container.iterator` | Borrow source; the caller supplies RF64 directory scratch |
| `parseFormat`, `frameCount` | Describe format and frame geometry; Microsoft coefficients borrow `fmt\x20` bytes |
| `decodeRequirements` | Inspect complete file geometry and the decoded sample count; sample contents remain unchecked |
| `decodeInto` | Use caller sample and directory storage; return an `AudioView` borrowing the used sample prefix |
| `decodeAlloc` | Allocate an independent `Audio`; release it with the original allocator |
| `decodeParallelInto`, `decodeParallelAlloc` | The same results with explicit `std.Io`, bounded workers and `ParallelOptions` |
| `encodePcm16Requirements`, `encodePcm16Into`, `writePcm16` | Size, fill caller bytes or write a complete PCM16 RIFF file |

Serial calls need no scheduler. Allocating calls take a per-call allocator and retain none. An
`Audio` owns its complete byte allocation, including alignment padding; its `samples` borrow that
allocation. Copies share ownership: call `deinit(allocator)` exactly once after every sample borrow
retires. `Audio.view()` borrows samples and copies rate, channel count and optional speaker mask.

```zig
const std = @import("std");
const wav = @import("wingman").wav;

test "write a complete file and decode with caller storage" {
    const source: wav.AudioView = .{
        .sample_rate = 8000, .channels = .mono, .samples = &.{ -1, 0.5 },
    };
    var bytes: [48]u8 = undefined;
    const encoded = try wav.encodePcm16Into(source, &bytes);
    const layout = try wav.decodeRequirements(encoded, &.{});
    try std.testing.expectEqual(2, layout.frames);
    var destination: [3]f32 = @splat(42);
    const audio = try wav.decodeInto(encoded, &destination, &.{});
    try std.testing.expectEqualSlices(f32, source.samples, audio.samples);
    try std.testing.expectEqual(42, destination[2]);
}
```

Ordinary RIFF needs no directory entries, so `&.{}` is sufficient in this example. For arbitrary
input, first obtain `parse(source).scratchCount()`, reserve that many `ChunkIndexEntry` values,
then call `decodeRequirements` or `decodeInto`. Each active pass needs exclusive scratch; extra
entries are untouched. Requirements can size output but do not certify floating-point values or
ADPCM predictor state.

```zig
const std = @import("std");
const wav = @import("wingman").wav;

test "owned decoding outlives encoded storage" {
    var bytes: [48]u8 = undefined;
    const encoded = try wav.encodePcm16Into(.{
        .sample_rate = 8000, .channels = .mono, .samples = &.{ -1, 0.5 },
    }, &bytes);
    var audio = try wav.decodeAlloc(std.testing.allocator, encoded);
    defer audio.deinit(std.testing.allocator);
    @memset(&bytes, 0xa5);
    try std.testing.expectEqualSlices(f32, &.{ -1, 0.5 }, audio.view().samples);
}
```

Owned decoding releases inspection scratch before allocating samples, then reacquires conversion
scratch above them. It frees every partial owner on failure and preserves reclamation with
tail-based allocators. Empty audio allocates no sample storage. The internal sample owner requests
exact bytes first; if byte-backed storage is misaligned, it grows that reservation or releases it
before requesting a padded replacement.

## Supported reading profile

| Representation | Current behavior |
| --- | --- |
| Integer PCM | Unsigned8, signed little-endian16/24/32; extensible meaningful precision is high-aligned, with low padding ignored |
| IEEE binary32 | Finite values, including signed zero and values outside `[-1, 1]`; NaN/infinity fail conversion |
| G.711 | A-law and mu-law, including their supported extensible subformat identifiers |
| ADPCM | Four-bit Microsoft and IMA/DVI WAVE blocks, mono/stereo; inherited numerical limits apply |
| Channels | Ordinary mono/stereo; supported extensible formats allow nonzero multichannel counts in source order |

All normalized integer/companded/ADPCM samples use the raw codecs' PCM16 or precision-specific
power-of-two scaling. Writing a decoded positive endpoint back to PCM16 does not stretch it to
one. See [PCM](pcm.md), [G.711](g711.md) and [ADPCM](adpcm.md) for their numerical contracts.

`Channels` is a non-exhaustive enum: use `@backingInt(channels)` for its count. `channel_mask` is
copied metadata: null for ordinary formats, zero for unspecified assignments. Masks do not cause
reordering or validate a speaker arrangement. `Format` values come from `parseFormat`; copying
one copies the Microsoft coefficient slice, not its bytes. Keep those bytes alive through use.

The loader accepts reordered `fmt\x20` and `data`, unknown padded chunks and multiple top-level data
chunks. Each data chunk must independently contain whole frames or ADPCM blocks. Duplicate format
chunks and trailing bytes are refused. A global ADPCM `fact` count selects an initial frame prefix
across chunks; every omitted block and adaptive update still validates, including zero output.

## Inspect chunks and RF64 sizes

`parse` admits the outer WAVE/RF64 header and required RF64 `ds64` directory. Later chunk extents
remain fallible during iteration. Returned chunks borrow source even after the iterator advances.
A failed `next` ends that pass; start a fresh iterator to retry. Copying an active iterator shares
its scratch and does not create an independent traversal.

RF64 uses a dedicated 64-bit size for its single sentinel-sized `data` chunk and a directory for
other sentinel-sized chunks. Explicit 32-bit sizes take precedence over unused replacements.
Repeated IDs consume directory entries in authored order. Up to32 records use direct scans;
larger directories sort caller scratch lazily by ID and ordinal, then use indexed lookup.
`tableEntryUsed(ordinal)` observes consumption without advancing the iterator.

```zig
const std = @import("std");
const wav = @import("wingman").wav;

test "borrow ordinary WAVE chunks" {
    var bytes: [48]u8 = undefined;
    const encoded = try wav.encodePcm16Into(.{
        .sample_rate = 8000, .channels = .mono, .samples = &.{ -1, 0.5 },
    }, &bytes);
    const container = try wav.parse(encoded);
    try std.testing.expectEqual(0, container.scratchCount());
    var chunks = try container.iterator(&.{});
    const format_chunk = (try chunks.next()).?;
    try std.testing.expectEqualStrings("fmt ", format_chunk.id);
    const format = try wav.parseFormat(format_chunk.data);
    const data = (try chunks.next()).?;
    try std.testing.expectEqualStrings("data", data.id);
    try std.testing.expectEqual(2, try wav.frameCount(format, data.data.len));
    try std.testing.expectEqual(null, try chunks.next());
}
```

Scratch entries are byte-aligned and eight bytes each. Their fields are iterator-managed state;
do not mutate them during a pass. Directory capacity/overlap refusals occur before clearing the
used scratch; extra capacity stays unchanged.

## Parallel conversion through std.Io

Pass a `std.Io` provider, address-stable caller `Worker` storage and `ParallelOptions`. The provider
may execute inline and controls its own scheduling allocations; Wingman creates no thread pool.
Defaults use serial conversion below256KiB and target at least64KiB of encoded data per job.
Whole frames or ADPCM blocks form disjoint partitions. Thresholds or too few workers can select
serial conversion. Worker capacity bounds participants, including the calling thread.

```zig
const std = @import("std");
const wav = @import("wingman").wav;

test "parallel API permits an inline std.Io provider" {
    var bytes: [56]u8 = undefined;
    const encoded = try wav.encodePcm16Into(.{
        .sample_rate = 48000, .channels = .stereo,
        .samples = &.{ -1, 1, -0.5, 0.5, 0, 0.25 },
    }, &bytes);
    var samples: [6]f32 = undefined;
    var workers: [2]wav.Worker = undefined;
    const audio = try wav.decodeParallelInto(
        std.Io.failing, encoded, &samples, &.{}, &workers,
        .{ .minimum_bytes = 0, .minimum_job_bytes = 1 },
    );
    try std.testing.expectEqualSlices(
        f32, &.{ -1, 32767.0 / 32768.0, -0.5, 0.5, 0, 0.25 }, audio.samples,
    );
    for (workers) |worker| try std.testing.expectEqual(0, worker.source.len);
}
```

Every submitted job finishes before return on success, content error or `Canceled`. Used workers
clear source, output and coefficient borrows; inactive slots need not be initialized or touched.
The first content failure in input order is reported after joining, regardless of completion
order. Error/cancellation leaves caller output unpublished; owned operations free partial samples.

## Admission, failure and writing

Caller decoding requires the **entire destination reservation**, all worker storage and used
directory scratch to be pairwise disjoint and disjoint from source. This admission happens before
output writes; unlike the raw codecs, unused destination capacity participates in WAVE's alias
check. Insufficient or aliased directory storage is refused before clearing it. Later sizing can
modify directory scratch even when sample capacity is insufficient. Successful conversion and
content failure leave unused sample capacity unchanged; a content failure can change the used
region, which must be discarded unless the call succeeds.

`InvalidWave` covers malformed framing, metadata or blocks. `UnsupportedWave` identifies an
unsupported representation/profile choice. `InvalidSamples` covers invalid floating-point or
normalized writer samples. `SizeOverflow`, `InsufficientScratch`, `DestinationTooSmall` and
`Aliasing` identify storage/count admission. Allocating variants add `OutOfMemory`; parallel
variants add `Canceled`. Exact error unions are listed in the API reference.

PCM16 writing accepts finite normalized mono/stereo samples in `[-1, 1]`, a valid nonzero sample
rate and output fitting RIFF's32-bit extent. It validates all input before writer mutation, rounds
nearest with ties away from zero and clamps endpoints to -32768/32767 without dithering. Speaker
masks are not written. Caller-buffer encoding checks only its used output span; invalid input and
capacity/alias refusals preserve all destination bytes. `writePcm16` uses a concrete
`*std.Io.Writer`: input samples must be disjoint from its storage, backend failure may leave a
prefix, and the caller flushes it. No encoded RF64 or compressed output is provided.

The supported RF64 profile follows [EBU Tech3306 v1.1](https://tech.ebu.ch/docs/tech/tech3306v1_1.pdf).
[Microsoft's format descriptors](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ksmedia/ns-ksmedia-waveformatextensible)
describe channel/precision metadata. Reader tolerance for missing `fact`, short ordinary float or
G.711 records, advisory byte rates and nonzero pad bytes does not certify those files against
every writer requirement. RIFX, Wave64, BW64, binary64, `LIST/wavl`/`slnt`, fragmented input,
metadata editing, seeking, resampling and playback are outside the current surface.
