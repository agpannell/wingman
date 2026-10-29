# CRC-32

A cyclic redundancy check (CRC) summarizes a byte sequence as a small integer. Gzip stores an
IEEE CRC-32 of the uncompressed content; PNG stores one for each chunk. Readers recalculate the
value to detect accidental changes. Wingman computes this specific 32-bit variant, including
incremental input and concatenation without keeping or rereading earlier bytes.

This is the IEEE polynomial used by gzip and PNG. CRC-32C (Castagnoli) uses a different polynomial
and produces different values. In particular, x86's instruction named CRC32 computes CRC-32C.
These noncryptographic checksums cannot establish input identity or authenticate a message.

Use [the package setup](../README.md#use-it-in-a-project) with Zig 0.17.0. From the root checkout,
run `zig build crc32-example` or `zig build crc32-example -- "your text"` to try the runnable
[example](../examples/crc32.zig).

## Complete and incremental input

```zig
const std = @import("std");
const crc32 = @import("wingman").crc32;

test "continue after a snapshot" {
    var state: crc32.Hasher = .init;
    state.update("1234");
    const prefix = state.final();
    state.update("56789");
    try std.testing.expectEqual(crc32.hash("1234"), prefix);
    try std.testing.expectEqual(@as(u32, 0xcbf43926), state.final());
}
```

`hash(bytes)` returns the checksum of a complete buffer. `Hasher.update` appends exactly its input;
`final` reads a snapshot without resetting the state. Copies continue independently, and assigning
`.init` starts another stream. Empty input has checksum zero; empty updates have no effect.

The caller owns four bytes of state containing the unfinalized remainder. Initialize through
`.init` or copy a valid state. The implementation accepts unaligned slices and reads only their
supplied extent, without padding. Keep input readable during `update`; no input is retained after
return. Serialize mutation of shared state. These operations have no allocator, cleanup or
recoverable error path, and require valid readable slices.

## Format coverage and byte order

The returned `u32` is a number. The enclosing format decides which bytes to checksum and how to
encode that number:

| Format | Bytes covered | Checksum encoding |
| --- | --- | --- |
| gzip | Uncompressed content of one member | Little-endian, followed by the separate input-size field |
| PNG | Four-byte chunk type followed by the chunk data, excluding the length and CRC fields | Big-endian |

For example, PNG's final `IEND` chunk has no data, so its CRC covers just the type:

```zig
const std = @import("std");
const crc32 = @import("wingman").crc32;

test "PNG empty end chunk" {
    var field: [4]u8 = undefined;
    std.mem.writeInt(u32, &field, crc32.hash("IEND"), .big);
    try std.testing.expectEqual([4]u8{ 0xae, 0x42, 0x60, 0x82 }, field);
}
```

For a PNG chunk with data, update one state with the type and then its data. For gzip, reset at
each member and update with its uncompressed bytes. Wingman's CRC library supplies the checksum;
the caller owns container framing, parsing and validation.

## Combining separately processed chunks

`combine` calculates the checksum of the first sequence followed by the second from their finalized
checksums and the exact byte length of the second. It reads neither sequence:

```zig
const std = @import("std");
const crc32 = @import("wingman").crc32;

test "join independently processed chunks" {
    const first = crc32.hash("1234");
    const second = crc32.hash("56789");
    try std.testing.expectEqual(@as(u32, 0xcbf43926), crc32.combine(first, second, 5));
}
```

Combination preserves byte order: the first sequence always precedes the second. The caller
supplies the corresponding checksums and second length; the function cannot verify those facts
without the original bytes. Length uses the full `u64` range independently of host address width.

For equally sized second chunks, precompute the length's polynomial factor once:

```zig
const std = @import("std");
const crc32 = @import("wingman").crc32;

test "reuse a fixed chunk length" {
    const operator = crc32.CombineOperator.forLength(3);
    var result: u32 = 0;
    for ([_][]const u8{ "123", "456", "789" }) |chunk| {
        result = operator.apply(result, crc32.hash(chunk));
    }
    try std.testing.expectEqual(@as(u32, 0xcbf43926), result);
}
```

The four-byte operator is immutable, retains no input and can be copied or shared across threads.
Each application requires a second sequence of exactly the length chosen by `forLength`. An empty
second sequence uses length zero and checksum zero. No allocation or cleanup is required.

## How polynomial folding works

CRC arithmetic treats bits as coefficients of a polynomial. Adding polynomials is bitwise XOR;
there are no carries. The IEEE generator is `x^32 + 0x04c11db7`. The reflected byte recurrence
starts with all remainder bits set, processes each byte least-significant bit first using
`0xedb88320`, then complements the remainder for the returned checksum.

The portable implementation precomputes eight tables from that polynomial. Each table represents
one byte's contribution at its position in an eight-byte word. XORing those contributions removes
the serial dependency between eight individual byte updates.

Carryless multiplication instructions advance larger blocks using the same polynomial arithmetic.
Several independent vectors can be advanced in parallel, then folded together by the appropriate
power of `x`. A final polynomial reduction produces the 32-bit remainder. Multipliers, reduction
constants and tail shuffle masks are derived in the source. Tail loads stay within the caller's
slice; shuffled tails combine retained coefficients with the last valid sixteen input bytes.

The same advance operation explains checksum combination. Powers for one, two, four and successively
doubled byte counts let the operator handle all 64 length bits without overflowing a conversion
from bytes to bits.

## Target selection and validation

CPU selection happens at compile time, with no runtime dispatcher. All paths calculate the same
IEEE checksum. LLVM builds use the following features when the target enables them:

| Target features | Implementation |
| --- | --- |
| x86 SSE2 + PCLMUL | 128-bit folding; SSSE3 additionally enables shuffled tails |
| x86 PCLMUL + VPCLMUL + AVX2 | 256-bit folding |
| x86 PCLMUL + VPCLMUL + AVX-512F | 512-bit folding |
| AArch64 AES + NEON | 128-bit PMULL folding; big-endian lane bytes are normalized |
| AArch64 CRC | IEEE CRC instructions for short spans and scalar tails |
| Other targets or backends | Portable slicing |

These features must also be available on the machine running the binary. The source uses x86
carryless multiplication for IEEE CRC, and does not use x86's distinct CRC-32C instruction.

Tests cover independently known values, every short length and alignment, stream splits, snapshots,
copies, resets and reusable operators. A bitwise recurrence checks the byte calculation; a separate
matrix formulation checks combination, including every `u64` length bit and maximum length.
Linux protected-page tests check exact input boundaries and skip on other operating systems.
Those algebraic large-length tests do not claim to allocate maximum-sized buffers. There is no
throughput comparison or universal speed claim attached to this implementation.

Format references: [gzip, RFC 1952](https://www.rfc-editor.org/rfc/rfc1952) and
[PNG Third Edition](https://www.w3.org/TR/2025/REC-png-3-20250624/#5CRC-algorithm).
