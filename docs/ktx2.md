# KTX2 texture containers

KTX2 packages texture mip levels, array layers, cube faces or volume slices with a data format
descriptor and optional key/value metadata. Mip zero is the largest level. `wingman.ktx2` inspects
complete containers and writes caller-supplied encoded levels. It does not decode compressed
textures, apply color conversions or upload data to a graphics API.

Use [Zig 0.17.0 and the package setup](../README.md#use-it-in-a-project). Run
`zig build ktx2-example` for a [complete example](../examples/ktx2.zig) that writes and reads an
uncompressed R8 level.

## Inspect a container

```zig
const ktx2 = @import("wingman").ktx2;

pub fn largestLevel(bytes: []const u8) ktx2.Error!?ktx2.Level {
    const source = try ktx2.Source.open(bytes, .{});
    return source.level(0);
}
```

`Source.open` checks complete section and level ranges, topology, required zero padding, descriptor
framing and sorted unique UTF-8 metadata keys. It also checks the BasisLZ global-data directory,
slice ranges and animation flags. Supply `Options.limits` to bound input bytes, dimensions,
layers, levels, descriptor and metadata sizes, image records and declared expanded bytes. The
allocation-free view and returned level, metadata and descriptor slices borrow the complete
immutable file through their last use. Copies retain the same borrow; keep admitted fields intact.

`source.level(index)` returns an encoded whole mip, or `null` if absent. Levels are indexed largest
first although they are stored in reverse order. `Level.uncompressed_size` is the complete expanded
level size; BasisLZ uses zero. For BasisLZ, `source.imageSlice` locates encoded color and optional
alpha slices and `source.basisLz` exposes shared compressed tables. Coordinates outside the admitted
layout return null. Key/value and descriptor iterators borrow records independently.

The reader recognizes none, BasisLZ, Zstandard and zlib supercompression declarations. It does not
verify compressed streams, decompress a level, reconstruct pixels or validate actual animation
references. Apply the appropriate codec's exact-input, exact-output and checksum policies before
using restored bytes. Unsupported schemes and general multiplane layouts return `UnsupportedFormat`;
BasisLZ's paired ETC1S color/alpha slices are supported.

## Write supplied levels

Construct `EncodeTexture` with a header, complete data format descriptor, encoded levels and optional
sorted `KeyValue` entries or BasisLZ global data. Supply levels largest first; the writer stores
smaller levels first. `BasicDescriptor` can encode one basic descriptor, while raw descriptor bytes
can retain additional vendor records. Caller-provided level bytes must already match their declared
encoding: writing does not compress or convert them.

`encodedSize` validates input and returns the exact output size. `encodeInto` validates, checks
capacity and rejects overlaps between the used output prefix and every admitted input span before
writing. It returns the used prefix and leaves spare capacity, and the entire destination on failure,
unchanged. `encode` allocates a complete result using its per-call allocator; free the result with
the same allocator. Inputs remain immutable through either call.

| Error | Meaning |
| --- | --- |
| `InvalidKtx2` | Malformed container, descriptor, metadata or declared layout |
| `UnsupportedFormat` | A scheme or layout is outside the supported profile |
| `LimitExceeded` | A caller-selected limit is exceeded |
| `SizeOverflow` | Checked size arithmetic is unrepresentable |
| `DestinationTooSmall` | Caller output cannot hold the complete result |
| `OverlappingStorage` | A protected input overlaps the used output prefix |

Allocating writes can also report allocator exhaustion. Failures publish no partial container view.

## Interpretation and limits

The descriptor exposes its basic block, samples and additional opaque vendor records. Admission
checks framing and declared sizes, not every color-model-specific sample rule or the full mapping
between the descriptor and Vulkan format. The caller chooses transfer functions, orientation,
swizzles, sampling and GPU policy. For PVRTC1, level-size validation accounts for the minimum 2×2
stored block grid even for tiny mips; PVRTC2 uses its ordinary block grid. This does not decode either
format or validate all format-specific restrictions.

The [library entry](../src/ktx2.zig) and its shallow owners keep container framing, descriptor,
global-data and writing contracts separate. The [shared byte-range overlap check](../src/common/byte_ranges.zig)
is also used by other libraries; each operation selects its own checked spans and error policy.
The format is specified by the
[KTX 2 specification](https://github.khronos.org/KTX-Specification/ktxspec.v2.html) and the
[Khronos PVRTC data format](https://github.com/KhronosGroup/DataFormat/blob/main/pvrtc.txt).
