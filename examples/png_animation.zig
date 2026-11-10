//! Encode two APNG frames, then inspect and compose them without a display or clock.
const std = @import("std");
const png = @import("wingman").png;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const first_pixels = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 };
    const second_pixels = [_]u8{ 0, 255, 0, 255 };
    const frames = [_]png.AnimationInput.Frame{
        .{
            .width = 2,
            .height = 1,
            .samples = .{ .packed_bytes = .{ .bytes = &first_pixels } },
            .delay = .{ .numerator = 1, .denominator = 10 },
        },
        .{
            .width = 1,
            .height = 1,
            .x = 1,
            .samples = .{ .packed_bytes = .{ .bytes = &second_pixels } },
            .delay = .{ .numerator = 2, .denominator = 10 },
            .dispose = .background,
            .blend = .over,
        },
    };
    const encoded = try png.encode.animation.alloc(
        allocator,
        .{
            .width = 2,
            .height = 1,
            .color_type = .rgba,
            .bit_depth = 8,
            .frames = &frames,
            .play_count = 1,
        },
        .{},
    );
    defer allocator.free(encoded);

    const source = try png.AnimationSource.open(encoded, .{});
    if (source.frame_count != 2 or source.play_count != 1) return error.UnexpectedAnimation;
    var controls = source.frames();
    _ = controls.next() orelse return error.UnexpectedAnimation;
    const second_control = (controls.next() orelse return error.UnexpectedAnimation).control;
    if (second_control.x != 1 or second_control.width != 1) return error.UnexpectedAnimation;
    if (second_control.dispose != .background) return error.UnexpectedAnimation;
    if (controls.next() != null) return error.UnexpectedAnimation;

    // Player borrows the animation at this address; defer order releases the player first.
    var animation = try png.decode.animation.alloc(u8, allocator, encoded, .{});
    defer animation.deinit(allocator);
    var player = try png.Animation(u8).Player.initCapacity(allocator, &animation, .{});
    defer player.deinit(allocator);
    const first = player.next() orelse return error.UnexpectedAnimation;
    if (!std.mem.eql(u8, first.pixels, &first_pixels)) return error.UnexpectedAnimation;
    if (first.delay.numerator != 1) return error.UnexpectedAnimation;
    // Advancing reuses the canvas, so inspect or copy the first frame before this call.
    const second = player.next() orelse return error.UnexpectedAnimation;
    const expected = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    if (!std.mem.eql(u8, second.pixels, &expected)) return error.UnexpectedAnimation;
    if (second.delay.numerator != 2) return error.UnexpectedAnimation;
    if (second.delay.effectiveDenominator() != 10) return error.UnexpectedAnimation;
    if (player.next() != null) return error.UnexpectedAnimation;

    var buffer: [128]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "APNG: {d} frames, {d} play; canvases verified\n",
        .{ source.frame_count, source.play_count },
    );
    try output.interface.flush();
}
