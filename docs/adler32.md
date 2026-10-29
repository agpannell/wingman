# Adler-32

Adler-32 summarizes a byte sequence as a 32-bit integer. Zlib stores it after the compressed content
so a decoder can compare the checksum of the recovered bytes. The calculation is simple enough to
update as data arrives, without keeping those earlier bytes.

Use it for zlib-compatible checksums and accidental corruption detection. It is a noncryptographic
checksum with a small output; matching values do not establish that two inputs are identical.

## Complete and incremental input

```zig
const std = @import("std");
const adler32 = @import("wingman").adler32;

test "continue after a snapshot" {
    var state: adler32.Hasher = .init;
    state.update("1234");
    const prefix = state.final();
    state.update("56789");
    try std.testing.expectEqual(adler32.hash("1234"), prefix);
    try std.testing.expectEqual(@as(u32, 0x091e01de), state.final());
}
```

`final` reads a snapshot. It does not reset or finish the state, so further updates extend the same
sequence. Copies of `Hasher` continue independently; assign `.init` to start over. Empty input has
checksum one, and empty updates have no effect.

The state occupies eight bytes and owns two reduced sums. It retains no allocator or input and
needs no cleanup. Any input alignment is accepted. The implementation reads exactly the supplied
slice, with no padding requirement. Keep input readable during `update`; it can retire afterward.
Serialize mutation when several threads share one state. Manually constructed state must keep both
sums below 65521, as documented by its fields and `update`.

`hash`, `update` and `final` have no allocation or recoverable error path. Their contract assumes
valid readable input slices and a valid initialized state.

## Numeric result and byte order

The low half of the returned integer contains the byte sum; the high half contains its accumulated
prefix sum. The number itself has no serialized byte order. Zlib writes it most-significant byte
first:

```zig
const std = @import("std");
const adler32 = @import("wingman").adler32;

test "zlib footer bytes" {
    var footer: [4]u8 = undefined;
    std.mem.writeInt(u32, &footer, adler32.hash("123456789"), .big);
    try std.testing.expectEqual([4]u8{ 0x09, 0x1e, 0x01, 0xde }, footer);
}
```

The runnable [Adler-32 example](../examples/adler32.zig) shows complete, incremental and combined
input and writes the footer bytes.

## Combining separately processed chunks

`combine` uses two checksums and the exact length of the second sequence to compute the checksum
of their concatenation. It does not read either original input:

```zig
const std = @import("std");
const adler32 = @import("wingman").adler32;

test "join checksums without original bytes" {
    const first = adler32.hash("Wiki");
    const second = adler32.hash("pedia");
    const whole = adler32.combine(first, second, 5);
    try std.testing.expectEqual(@as(u32, 0x11e60398), whole);
}
```

Lengths use the full `u64` range, independently of the host's address width. The caller supplies
valid finalized checksums and the matching second length. For many equally sized second chunks,
`CombineOperator.forLength(length)` reduces that length once; `apply(first, second)` reuses it.
Copies of the operator are immutable and can be shared. No allocation or cleanup is required.

## How the vector calculation works

The scalar definition maintains two sums modulo the prime 65521. For each byte, add it to the
first sum, then add the first sum to the second. Starting from `(1, 0)` gives the empty checksum one.

A block of `n` bytes can express the same work as two independent reductions:

- Add the sum of the bytes to the first sum.
- Add `n` times the incoming first sum, plus bytes weighted `n, n-1, …, 1`, to the second sum.

The weights count how many later prefix sums contain each byte. This removes the serial per-byte
dependency from the inner loop. Portable vector columns accumulate equal positions across blocks;
x86 SSE2 and AVX2 use byte sums and paired multiplies; VNNI paths use byte dot products. Four
independent dot-product chains provide parallel work before their ordered contributions are joined.
Masked tails are enabled only with the required byte-mask and vector-length features. Other tails
use bounded column or scalar processing.

Reduction is delayed only while intermediate sums fit. With reduced incoming sums and bytes at
most 255, 5,552 bytes is the `u32` reduction bound. Column routes impose a tighter bound where
signed 16-bit multiply lanes require it. Generated positional weights follow the actual lane order,
including AVX2's 128-bit unpack lanes. These bounds and input extents are tested near each boundary.

The source's architecture gates select kernels from the target's declared CPU features. This does
not probe the running machine. Portable code handles targets without the x86 instructions.

## Validation scope

The tests retain independently calculated checksum values, compare against the standard library's
scalar implementation, exercise each short length and alignment, stress maximal reduced state and
check chunk splits and concatenation. Linux protected-page tests place input next to unreadable
memory to exercise exact tails; that particular test skips on other operating systems.

The full-`u64` combination test uses a separate closed form for repeated-byte sequences. It checks
length arithmetic without claiming to allocate or read a maximum-sized buffer. There is no
throughput comparison or universal speed claim attached to this implementation.

See [RFC 1950](https://www.rfc-editor.org/rfc/rfc1950.html) for the checksum and zlib format.
