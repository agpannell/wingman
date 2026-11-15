//! Exclusive native encoder scratch, initialized on demand and borrowed until reset/end of use.
//! Construct at its final address. Allocation uses the exact typed size; no allocator is retained.
//! This smaller reservation supports stored/four-byte-run streaming without ordinary search,
//! parsing or codebook-construction arrays. Contents are private to the active encoder except its
//! explicit input/framing loans.

const std = @import("std");

const FourByteRunWorkspace = @This();
const slab_bytes = 65535;
const window_bytes = 32768;

/// Encoder-owned input and history; callers must not modify these bytes while borrowed.
data: [window_bytes + slab_bytes]u8,
/// Encoder-owned staged output, also available through the initial framing loan. Callers modify
/// these bytes only during that explicit loan.
wire: [slab_bytes + 128]u8,

/// Reserves undefined scratch without creating a large temporary.
pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*FourByteRunWorkspace {
    return allocator.create(FourByteRunWorkspace);
}

/// Releases scratch through its construction allocator after all borrows.
pub fn destroy(self: *FourByteRunWorkspace, allocator: std.mem.Allocator) void {
    allocator.destroy(self);
}

/// Erases retained input, history and staged output after ending its use.
pub fn clear(self: *FourByteRunWorkspace) void {
    std.crypto.secureZero(u8, std.mem.asBytes(self));
}
