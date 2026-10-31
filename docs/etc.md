# ETC1 and EAC blocks

`wingman.etc` converts individual 4×4 GPU texture blocks. ETC1 packs RGB color into eight bytes;
unsigned EAC packs alpha8 or an eleven-bit R11 component into eight bytes. Use it when the image
layout and block boundaries are already known, for example after inspecting texture levels with
[`ktx2`](ktx2.md). It does not parse a texture container or upload a texture.

```sh
zig build etc-example
```

## Decode a tile

`decodeBlock` reads the first eight bytes and writes 16 row-major RGBA8 texels into 64 bytes. ETC1
has no alpha, so each output alpha is 255. `decodeAlphaBlock` writes 16 alpha bytes, while
`decodeR11Block` writes 16 `u16` values in the full 0–2047 range. R11 is not an alpha8 block;
convert or normalize its samples explicitly when a different representation is needed. EAC RG11
uses two R11 blocks in red/green order.

Decoding performs no allocation. Short input, short output, overlapping used spans and invalid
ETC1 differential endpoints are errors; the destination remains untouched on every error. Spare
source and destination capacity is ignored, and extra destination bytes are preserved. The caller
clips edge tiles to image dimensions and chooses channel assembly, color-space conversion and GPU
format policy.

ETC2 RGBA stores alpha8 before its color block. ETC1-compatible color modes can use `decodeBlock`,
but ETC2 T, H and planar color modes and signed EAC are not supported by this library.

## Encode a tile

`encodeBlock` fits a complete `[16][4]u8` tile into eight bytes, ignoring the input alpha channel.
`encodeAlphaBlock` and `encodeR11Block` fit 16 unsigned bytes each. R11 maps each normalized input
byte to the nearest eleven-bit value before measuring error. Encoding is lossy; supply the padded
texels to use at partial image edges, because all 16 samples participate in fitting.

`EncodeOptions.effort` chooses `.fast`, `.balanced` or `.refined`. Each wider search retains earlier
candidates, so squared error over the whole stored component tile cannot increase. This is not a
perceptual quality or global-optimality guarantee. `colorWorkUnits` and `scalarWorkUnits` report
conservative per-block admission costs; set `maximum_work_units` to bound one call. The default
admits every effort. A work refusal, short destination or overlap leaves the entire output intact.
The calls retain no input, output or allocator. Alpha8 encoding emits a nonzero multiplier as the
format requires; decoding also accepts stored zero multipliers. R11 has its own zero-multiplier rule.

The [complete example](../examples/etc.zig) fits and reconstructs both a color block and an alpha
block. The byte and word layouts follow the [ETC1 extension](https://registry.khronos.org/OpenGL/extensions/OES/OES_compressed_ETC1_RGB8_texture.txt)
and [OpenGL ES 3.0 specification](https://registry.khronos.org/OpenGL/specs/es/3.0/es_spec_3.0.pdf),
appendix C.
