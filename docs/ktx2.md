# KTX2 texture containers

KTX2 packages texture mip levels, array layers, cube faces or volume slices with a data format
descriptor and optional key/value metadata. Mip levels form successively smaller versions of the
texture; mip zero is the largest. `wingman.ktx2` inspects complete containers and writes
caller-supplied encoded levels. It does not decode compressed textures, apply color conversions or
upload data to a graphics API.

Use [Zig 0.17.0 and the package setup](../README.md#use-it-in-a-project). Run `zig build
ktx2-example` for a [complete example](../examples/ktx2.zig) that writes and reads an uncompressed
R8 level.

Level bytes may already use a GPU block-compressed format. Supercompression reduces these bytes
further for storage: Zstandard and zlib work on each level, while BasisLZ represents ETC1S blocks
through shared codebooks. The container identifies this representation and its ranges; the
appropriate codec recovers the blocks or samples.

## Inspect a container

```zig
const ktx2 = @import("wingman").ktx2;

pub fn largestLevel(bytes: []const u8) ktx2.Error!?ktx2.Level {
    const container = try ktx2.Container.open(bytes, .{});
    return container.level(0);
}
```

`Container.open` checks complete section and level ranges, topology, required zero padding,
descriptor framing and sorted unique UTF-8 metadata keys. It also checks the BasisLZ global-data
directory, slice ranges and animation flags. Supply `Options.limits` to bound input bytes,
dimensions, layers, levels, descriptor and metadata sizes, image records and declared expanded
bytes. The allocation-free view and returned level, metadata and descriptor slices borrow the
complete immutable file through their last use. Copies retain the same borrow; keep admitted fields
intact.

`container.level(index)` returns an encoded whole mip, or `null` if absent. Levels are indexed
largest first although they are stored in reverse order. `Level.uncompressed_size` is the complete
expanded level size; BasisLZ uses zero. `Header` copies topology declarations: zero height/depth
omits an axis, zero layers denotes a non-array texture, and zero levels stores one mip while
requesting generation of smaller levels. Block-compressed formats require an explicit level count.

`container.metadata` is an admitted `Metadata` view. Its `iterator()` returns `Metadata.Entry`
values whose keys and opaque values borrow the file independently. `entry_count` records the number
of admitted pairs. `Metadata.open(bytes, options)` also admits a raw metadata section on its own,
using the metadata-byte and entry limits. Keys omit their wire NUL terminator; values omit padding
and may contain zero bytes. `has_animation_header` recognizes `KTXanimData` with a twelve-byte value
without interpreting its timing fields. Descriptor block/sample queries use the independent
descriptor type.

## Inspect BasisLZ images and codebooks

For ETC1S/BasisLZ containers, `container.basisLz()` returns a borrowed `BasisLz` view. It returns
null for other representations, including ordinary raw, Zstandard and zlib levels. The view's
`image(mip, layer, face, depth)` returns `BasisLz.Image` with encoded `color`, optional `alpha` and
raw animation `flags`; coordinates outside the admitted layout return null. `codebooks()` returns
`BasisLz.Codebooks` with compressed endpoint, selector and Huffman-table spans. Its entry counts
describe decoded codebook entries, rather than compressed byte lengths.

Codebooks are shared tables of color/intensity values and selector patterns referenced by many ETC1S
blocks. Image slices encode references to those tables, so neither their bytes nor the compressed
codebook spans can be passed directly to `etc.decodeBlock`.

```zig
const ktx2 = @import("wingman").ktx2;

pub fn firstBasisImage(bytes: []const u8) ktx2.Error!?ktx2.BasisLz.Image {
    const container = try ktx2.Container.open(bytes, .{});
    const basis = container.basisLz() orelse return null;
    return basis.image(0, 0, 0, 0);
}
```

All these views borrow immutable file bytes and can outlive the original Container object.

The reader recognizes none, BasisLZ, Zstandard and zlib supercompression declarations. It does not
verify compressed streams, decompress a level, reconstruct pixels or validate actual animation
references. Apply the appropriate codec's exact-input, exact-output and checksum policies before
using restored bytes. Unsupported schemes and general multiplane layouts return `UnsupportedFormat`;
BasisLZ's paired ETC1S color/alpha slices are supported.

## Write supplied levels

Construct `TextureInput` with a header, complete data format descriptor, encoded levels and optional
sorted `Metadata.Entry` values or raw BasisLZ `supercompression_data`. Supply levels largest first;
the writer stores smaller levels first. `wingman.KhronosDataFormatDescriptor.BasicInput` can encode
one basic descriptor, while raw descriptor bytes can retain additional vendor records.
Caller-provided level bytes must already match their declared encoding: writing does not compress or
convert them.

`input.encodedSize(options)` validates input and returns the exact output size.
`input.encodeInto(output, options)` validates, checks capacity and rejects overlaps between the used
output prefix and every admitted input span before writing. It returns the used prefix and leaves
spare capacity, and the entire destination on failure, unchanged. `input.encode(allocator, options)`
allocates a complete result; free the result with the same allocator. It validates before requesting
the exact output size. Both writers initialize required wire padding to zero, and inputs remain
immutable through either call.

| Error | Meaning |
| --- | --- |
| `InvalidKtx2` | Malformed container, descriptor, metadata or declared layout |
| `UnsupportedFormat` | A scheme or layout is outside the supported profile |
| `LimitExceeded` | A caller-selected limit is exceeded |
| `SizeOverflow` | Checked size arithmetic is unrepresentable |
| `DestinationTooSmall` | Caller output cannot hold the complete result |
| `OverlappingStorage` | A protected input overlaps the used output prefix |
| `OutOfMemory` | The allocating writer could not obtain its complete output storage |

The public sets follow the operation: `TextureInput.SizeError` contains admission/arithmetic errors;
`TextureInput.EncodeIntoError` adds capacity/overlap failures. `TextureInput.EncodeError` adds
allocator exhaustion and overlap to the admission errors, with no capacity failure. `Container.open`
uses the shared `ktx2.Error`; `Metadata.open` uses `Metadata.OpenError`, containing only
`InvalidKtx2` and `LimitExceeded`. Failures publish no partial container view.

## Inspect or construct a format descriptor

`wingman.KhronosDataFormatDescriptor` describes texel blocks independently of their container. A
texel is one texture pixel; a texel block is a repeating region encoded together, such as one
uncompressed texel or a 4×4 compressed tile. Its sample declarations identify channel bit ranges,
positions and numeric endpoints, rather than storing the image's actual component values.
`open(bytes)` borrows complete immutable descriptor bytes; `sample(index)` returns a copied
`Sample`, while `blocks()` returns a `Block.Iterator` whose records borrow those bytes. The profile
starts with a Khronos basic-format version 2 block and preserves following opaque blocks.

Use `BasicInput` to write a complete descriptor containing one basic block:

```zig
const Descriptor = @import("wingman").KhronosDataFormatDescriptor;

pub fn describeR8(output: []u8) Descriptor.BasicInput.EncodeError![]u8 {
    const samples = [_]Descriptor.Sample{
        .{ .bit_offset = 0, .bit_length = 8, .channel_type = 0, .lower = 0, .upper = 255 },
    };
    const input: Descriptor.BasicInput = .{
        .color_model = 1,
        .bytes_plane = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
        .samples = &samples,
    };
    return input.encodeInto(output);
}
```

Sizing validates representable sample counts, bit lengths and block extents. Writing also checks
capacity and overlap with the actual input record and sample array before changing output; spare
capacity stays untouched. The result is independent of those inputs and borrows the output buffer.
Color-model interpretation and agreement with a Vulkan format remain separate checks.

Direct descriptor opening reports `InvalidDescriptor` or `UnsupportedDescriptor`. Basic writing can
report `InvalidDescriptor`, `DestinationTooSmall` or `OverlappingStorage`. KTX2 admission maps the
descriptor failures to `InvalidKtx2` and `UnsupportedFormat`, respectively. The descriptor's public
error types live with the operations: `OpenError`, `BasicInput.SizeError` and
`BasicInput.EncodeError`.

## Interpretation and limits

The descriptor exposes its basic block, samples and additional opaque vendor records. Admission
checks framing and declared sizes, not every color-model-specific sample rule or the full mapping
between the descriptor and Vulkan format. The caller chooses transfer functions, orientation,
swizzles, sampling and GPU policy. For PVRTC1, level-size validation accounts for the minimum 2×2
stored block grid even for tiny mips; PVRTC2 uses its ordinary block grid. This does not decode
either format or validate all format-specific restrictions.

The [library entry](../src/ktx2.zig), independent [Khronos
descriptor](../src/KhronosDataFormatDescriptor.zig) and shallow container owners keep framing and
format description separate. [Container](../src/ktx2/Container.zig),
[TextureInput](../src/ktx2/TextureInput.zig), [Metadata](../src/ktx2/Metadata.zig),
[BasisLz](../src/ktx2/BasisLz.zig) and [Header](../src/ktx2/Header.zig) own the corresponding
workflows and their defining contracts. The [shared byte-range overlap
check](../src/common/byte_ranges.zig) is also used by other libraries; each operation selects its
own checked spans and error policy. The format is specified by the [KTX 2
specification](https://github.khronos.org/KTX-Specification/ktxspec.v2.html) and the [Khronos PVRTC
data format](https://github.com/KhronosGroup/DataFormat/blob/main/pvrtc.txt).
