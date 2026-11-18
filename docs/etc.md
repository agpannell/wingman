# ETC1 and EAC blocks

`wingman.etc` converts individual 4×4 GPU texture blocks. A texel is one texture pixel; these
formats encode sixteen texels together. ETC1 packs RGB color into eight bytes; unsigned EAC packs
alpha8 or an eleven-bit R11 component into eight bytes. Use it when the image layout and block
boundaries are already known, for example after inspecting texture levels with [`ktx2`](ktx2.md). It
does not parse a texture container or upload a texture. BasisLZ/ETC1S slices need their own codec
before they can supply ordinary ETC blocks.

The base value and modifier table define a palette of reconstructed values; each texel's selector
chooses one palette entry. Fitting searches for bases, tables and selectors that approximate the
supplied samples.

Use [Zig 0.17.0 and the package setup](../README.md#use-it-in-a-project). From this checkout:

```sh
zig build etc-example
```

## Decode a tile

`decodeBlock` reads the first eight bytes and writes 16 row-major RGBA8 texels into 64 bytes. ETC1
has no alpha, so each output alpha is 255. `decodeAlphaBlock` writes 16 alpha bytes, while
`decodeR11Block` writes 16 `u16` values in the full 0–2047 range. R11 is not an alpha8 block;
convert or normalize its samples explicitly when a different representation is needed. EAC RG11 uses
two R11 blocks in red/green order.

Decoding performs no allocation. Short input, short output, overlapping used spans and invalid ETC1
differential endpoints are errors; the destination remains untouched on every error. `decodeBlock`
uses public `DecodeError`; the two EAC decoders use the narrower `EacDecodeError`, which omits
`InvalidBlock`. Spare source and destination capacity is ignored, and extra destination bytes are
preserved. The caller clips edge tiles to image dimensions and chooses channel assembly, color-space
conversion and GPU format policy.

ETC2 RGBA stores alpha8 before its color block. ETC1-compatible color modes can use `decodeBlock`,
but ETC2 T, H and planar color modes and signed EAC are not supported by this library.

Compose separately decoded color and alpha8 explicitly when an RGBA8 tile is needed. This helper
returns independent caller-owned bytes; it borrows the encoded blocks only during the call:

```zig
const etc = @import("wingman").etc;

pub fn decodeRgba(color_block: []const u8, alpha_block: []const u8) etc.DecodeError![64]u8 {
    var rgba: [64]u8 = undefined;
    var alpha: [16]u8 = undefined;
    try etc.decodeBlock(color_block, &rgba);
    try etc.decodeAlphaBlock(alpha_block, &alpha);
    for (alpha, 0..) |value, index| rgba[index * 4 + 3] = value;
    return rgba;
}
```

## Encode a tile

`encodeBlock` fits a complete `[16][4]u8` tile into eight bytes, ignoring the input alpha channel.
`encodeAlphaBlock` and `encodeR11Block` fit 16 unsigned bytes each. R11 maps each normalized input
byte to the nearest eleven-bit value before measuring error. Encoding is lossy; supply the padded
texels to use at partial image edges, because all 16 samples participate in fitting.

`EncodeOptions.effort` chooses `.fast`, `.balanced` or `.refined`. For varying RGB tiles, balanced
refits base colors after choosing selectors and refined also tests neighboring base codes. EAC
expands from four modifier tables to sixteen, then tests neighboring base/multiplier pairs. Each
wider search retains earlier complete-block candidates, so squared component error cannot increase.
This is not a perceptual quality or global-optimality guarantee.

`colorWorkUnits` and `scalarWorkUnits` report conservative per-block admission costs; set
`maximum_work_units` to bound one call. These units describe a search reservation, not elapsed time.
The default effort is fast, and the default reservation admits every effort. A work refusal, short
destination or overlap leaves the entire output intact. The calls retain no input, output or
allocator. Alpha8 encoding emits a nonzero multiplier as the format requires; decoding also accepts
stored zero multipliers. R11 has its own zero-multiplier rule.

The [complete example](../examples/etc.zig) fits a varying color gradient, alpha ramp and red
component at all three efforts, reconstructs them and assembles RGBA8. It checks that wider efforts
do not increase error and prints the first reconstructed samples plus squared error sums. RGB sums
cover 48 byte components, alpha8 sums cover 16 bytes, and R11 sums cover 16 eleven-bit values. Their
units differ, so compare efforts within a component rather than comparing the raw RGB/alpha8/R11
totals. R11 is rounded from normalized input bytes before measuring error.

The byte and word layouts follow the [ETC1
extension](https://registry.khronos.org/OpenGL/extensions/OES/OES_compressed_ETC1_RGB8_texture.txt)
and [OpenGL ES 3.0 specification](https://registry.khronos.org/OpenGL/specs/es/3.0/es_spec_3.0.pdf),
appendix C.

The [library entry](../src/etc.zig) owns public options, errors and output/work admission. The
private [ETC1 owner](../src/etc/etc1.zig) keeps RGB wire fields, palettes and fitting together; the
[EAC owner](../src/etc/eac.zig) keeps alpha8/R11 reconstruction, fitting and derived constant
mappings together. Related tests live with those contracts.
