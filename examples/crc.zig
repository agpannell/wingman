//! Compare complete, fragmented and combined checksums for the named CRC family.
const std = @import("std");
const crc = @import("wingman").crc;

fn demonstrate(
    comptime Crc: type,
    name: []const u8,
    input: []const u8,
    output: *std.Io.Writer,
) !void {
    const split = input.len / 2;
    const complete = Crc.hash(input);
    var stream = Crc.init();
    stream.update(input[0..split]);
    stream.update(input[split..]);
    const first = Crc.hash(input[0..split]);
    const second = Crc.hash(input[split..]);
    const second_length = input.len - split;
    const operator = Crc.CombineOperator.forLength(second_length);
    if (stream.final() != complete or Crc.combine(
        first,
        second,
        second_length,
    ) != complete or operator.apply(first, second) != complete) return error.ChecksumMismatch;
    try output.print("{s}: {x}\n", .{ name, complete });
}

/// The optional argument is the exact text to checksum; the default is nine standard check digits.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const input = if (args.len > 1) args[1] else "123456789";
    var buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try demonstrate(crc.Crc32IsoHdlc, "CRC-32/ISO-HDLC", input, &output.interface);
    try demonstrate(crc.Crc32Iscsi, "CRC-32/ISCSI", input, &output.interface);
    try demonstrate(crc.Crc16Genibus, "CRC-16/GENIBUS", input, &output.interface);
    try demonstrate(crc.Crc64Xz, "CRC-64/XZ", input, &output.interface);
    const ieee = crc.Crc32IsoHdlc.hash(input);
    var field: [4]u8 = undefined;
    std.mem.writeInt(u32, &field, ieee, .little);
    try output.interface.print(
        "IEEE gzip bytes: {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n",
        .{ field[0], field[1], field[2], field[3] },
    );
    std.mem.writeInt(u32, &field, ieee, .big);
    try output.interface.print(
        "IEEE PNG bytes: {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n",
        .{ field[0], field[1], field[2], field[3] },
    );
    try output.interface.flush();
}
