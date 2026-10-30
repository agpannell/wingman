# ICC profile storage inspection

An ICC profile records how device color values relate to a profile connection space. Use
`wingman.icc` to inspect its selected header declarations and locate raw tag bodies before handing
them to a color-management system or another format-specific consumer.

This library inspects complete uncompressed ICC v2/v4 storage without allocation. It does not
apply a color transform, interpret curves/LUTs or establish complete profile conformance.
Applications extract a profile from its container, bound its backing storage and choose color policy.

Use [Zig 0.17.0 and the package setup](../README.md#use-it-in-a-project). Run
`zig build icc-example` for a complete [authored storage example](../examples/icc.zig). It checks
unsorted tags that share one body, preserves the borrow and excludes alignment padding.

## Open a borrowed profile

```zig
const icc = @import("wingman").icc;

pub fn inspect(bytes: []const u8) icc.Error!icc.Profile {
    return icc.Profile.open(bytes, .{ .limits = .{ .tags = 64 } });
}
```

Pass exactly the declared profile byte prefix, excluding any enclosing file header, chunk framing
or spare buffer capacity. `InspectOptions.limits.tags` is required; no implicit tag allowance is
selected. This structural ceiling is independent of the allocation/decompression limit chosen by
the profile's owner. Opening and lookup retain no allocator and need no cleanup.

`Profile`, `Tag` and returned body slices borrow the complete unchanged source through their last
use. Keep the admitted `source` and `tag_count` invariants intact. Copied version, device class,
input color space, connection space, rendering intent and count fields are independent scalar/array
values. A copied view still borrows the same input.

Signatures are raw four-byte arrays. For example, `"RGB "` includes its trailing space. The stored
rendering intent is a checked value from zero through three; inspection selects no transform.

## Enumerate and select opaque tags

```zig
const icc = @import("wingman").icc;

pub fn selectedBody(profile: icc.Profile, signature: [4]u8) icc.Error!?[]const u8 {
    const tag = try profile.find(signature) orelse return null;
    return tag.data;
}
```

`profile.tag(index)` returns a checked tag in table order, or `null` out of range.
`profile.find(signature)` returns a unique selected tag, `null` if missing, or `InvalidIcc` if
that signature occurs more than once. Even identical shared payloads do not make a duplicate
selected signature unique. Other duplicates remain available through indexed inspection.

Tag records need not be sorted. Distinct records may share the same body bytes. `Tag.signature`
identifies the record's purpose; the body's first four bytes encode its separate type. The reader
requires at least the eight-byte type/reserved prefix but leaves those bytes and all body semantics
opaque. `Tag.data` excludes alignment padding and refers directly to the original source.

## Admission and compatibility

Opening checks, in order, the minimum header/table-count extent, exact declared length and `acsp`
signature, supported major version, v4 profile alignment, rendering intent, explicit tag allowance,
checked complete table extent and every tag's independent body range.

Each twelve-byte record must reference a four-byte-aligned body at or after the table, entirely
within the source, with at least eight body bytes. ICC v4 also requires an aligned declared profile
length and zero padding after every tag body. ICC v2 permits an unpadded final body and retains
opaque suffix bytes. These version differences are deliberate.

| Error | Meaning |
| --- | --- |
| `InvalidIcc` | A checked header, table, body, selected-duplicate or padding rule failed |
| `UnsupportedIcc` | The declared major version is neither two nor four |
| `MetadataLimitExceeded` | The declared tag count exceeds the caller's allowance |

Admission does not mutate input or publish a view on failure. Count admission precedes table-size
arithmetic and body traversal; an over-budget table returns `MetadataLimitExceeded` before its
unadmitted records are read. Indexing first checks `tag_count`, including maximum-size indices.

## Validation limits and caller policy

The checked ranges are independent. The reader permits gaps, unreferenced suffixes, partial body
overlap and different lengths sharing an offset. It checks duplicate signatures only when selected.
Those tolerances do not establish conformance to ICC's complete storage rules.

Other header encodings, calendar values, reserved/minor version bytes, device-class/color-space
signatures, profile IDs, tag reserved fields, required-tag completeness and tag-type semantics are
not validated. A successfully opened profile can still be unusable for color management. Preserve
that distinction when reporting an admission result or forwarding data to another library.

Container integration remains separate: callers assemble JPEG profile pieces or expand PNG profile
data, then check container/channel compatibility and their own byte limits. Applying a profile,
choosing a rendering intent, converting pixels and handling unknown tags belong to the consumer.

## Implementation and references

The [ICC source](../src/icc.zig) keeps its small storage contract, inline tests and authored controls
together. Opening scans the bounded table once, with checked arithmetic and subtraction-based body
bounds. Indexed access is constant-time; signature lookup is a linear scan that detects selected
duplicates. There is no hidden tag index, allocation, sorting or retained mutable cache.

The format references are [ICC v2](https://www.color.org/specification/ICC.1-2001-04.pdf) and
[ICC.1:2022 v4](https://www.color.org/specification/ICC.1-2022-05.pdf). The ICC's
[added-bytes guidance](https://www.color.org/security/malformed/added-bytes/) distinguishes tolerant
consumption from full storage conformance. Package examples are authored storage controls rather
than bundled third-party profiles or claims of complete color-transform validity.
