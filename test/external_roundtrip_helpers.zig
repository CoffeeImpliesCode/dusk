//! Native shared-image transfer oracle. Dawn 32f77c02294310054a660c393feded4bcb3f203c:
//! vulkan/SharedTextureMemoryVk.cpp:1059 SharedTextureMemory::BeginAccessImpl,
//! :1093/:1166 EndAccessImpl. Submission uses the existing high Device queue.
const std = @import("std");
const dusk = @import("dusk");
const engine = dusk.engine;
const core = dusk.core;
const Encoder = dusk.command.command_encoder.CommandEncoder;
const Finished = dusk.command.encoding_context.Finished;
pub const extent = 4;
const pitch = 256;
const byte_count = pitch * extent;
pub const Error = engine.device.OperationError || engine.device.CleanupError ||
    engine.buffer.MapError || dusk.command.command_encoder.Error || dusk.command.Error ||
    core.HandleError || core.ReferenceError || error{PixelMismatch, InvalidReadbackLength};

pub fn checkPixels(bytes: []const u8, expected: [4]u8) error{PixelMismatch, InvalidReadbackLength}!void {
    if (bytes.len != byte_count) return error.InvalidReadbackLength;
    for (0..extent) |row| {
        for (0..extent) |column| {
            for (0..4) |channel| {
                if (bytes[row * pitch + column * 4 + channel] != expected[channel]) {
                    return error.PixelMismatch;
                }
            }
        }
    }
}

test "roundtrip oracle checks each channel and every row, not row padding" {
    var bytes: [byte_count]u8 = @splat(0xa5);
    const expected = [4]u8{ 17, 63, 129, 255 };
    for (0..extent) |row| {
        for (0..extent) |column| @memcpy(bytes[row * pitch + column * 4 ..][0..4], &expected);
    }
    try checkPixels(&bytes, expected);
    bytes[3 * pitch + 3 * 4 + 2] = 0;
    try std.testing.expectError(error.PixelMismatch, checkPixels(&bytes, expected));
    try std.testing.expectError(error.InvalidReadbackLength, checkPixels(bytes[0..4], expected));
}

fn releaseBuffer(allocator: std.mem.Allocator, io: std.Io, device: *engine.Device,
    buffer: *engine.native_resources.Buffer) void {
    device.release(allocator, io, buffer) catch @panic("roundtrip buffer release failed");
}

fn deinitEncoder(allocator: std.mem.Allocator, io: std.Io,
    device: *engine.Device, encoder: *Encoder) void {
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    encoder.deinit(allocator, io, &guard);
}

fn deinitFinished(allocator: std.mem.Allocator, io: std.Io,
    device: *engine.Device, finished: *Finished) void {
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    finished.deinit(allocator, io, &guard);
}

pub fn writeTexture(allocator: std.mem.Allocator, io: std.Io,
    device: *engine.Device, texture: *engine.texture.Texture, expected: [4]u8) Error!void {
    const upload = try device.createBuffer(allocator, io, .{
        .size = byte_count, .usage = .{ .copy_src = true }, .mapped_at_creation = true,
    });
    defer releaseBuffer(allocator, io, device, upload);
    {
        var guard = try core.ObjectGuard.lock(io, upload.header.tracking);
        defer guard.unlock(io);
        const bytes = try upload.native.getMappedRange(0, byte_count);
        @memset(bytes, 0xa5);
        for (0..extent) |row| {
            for (0..extent) |column| @memcpy(bytes[row * pitch + column * 4 ..][0..4], &expected);
        }
    }
    try device.unmapBuffer(io, upload);
    var encoder = Encoder.init(allocator, device.core.borrow(), .{});
    defer deinitEncoder(allocator, io, device, &encoder);
    {
        var guard = try core.ObjectGuard.lock(io, texture.header.tracking);
        defer guard.unlock(io);
        try encoder.copyBufferToTexture(.{
            .source = .{ .buffer = try upload.ref(&guard),
                .blocks_per_row = pitch / 4, .rows_per_image = extent },
            .destination = .{ .texture = texture,
                .format = @intFromEnum(dusk.api.TextureFormat.rgba8_unorm),
                .dimension = ._2d, .aspect = .all,
                .extent = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 } },
            .copy_size = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 },
        });
    }
    var finished = try encoder.finish();
    defer deinitFinished(allocator, io, device, &finished);
    const serial = try device.submit(allocator, io, &finished);
    try device.wait(io, serial);
}

pub fn readTexture(allocator: std.mem.Allocator, io: std.Io,
    device: *engine.Device, texture: *engine.texture.Texture, expected: [4]u8) Error!void {
    const readback = try device.createBuffer(allocator, io, .{
        .size = byte_count, .usage = .{ .copy_dst = true, .map_read = true },
    });
    defer releaseBuffer(allocator, io, device, readback);
    var encoder = Encoder.init(allocator, device.core.borrow(), .{});
    defer deinitEncoder(allocator, io, device, &encoder);
    {
        var guard = try core.ObjectGuard.lock(io, texture.header.tracking);
        defer guard.unlock(io);
        try encoder.copyTextureToBuffer(.{
            .source = .{ .texture = texture,
                .format = @intFromEnum(dusk.api.TextureFormat.rgba8_unorm),
                .dimension = ._2d, .aspect = .all,
                .extent = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 } },
            .destination = .{ .buffer = try readback.ref(&guard),
                .blocks_per_row = pitch / 4, .rows_per_image = extent },
            .copy_size = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 },
        });
    }
    var finished = try encoder.finish();
    defer deinitFinished(allocator, io, device, &finished);
    const serial = try device.submit(allocator, io, &finished);
    try device.wait(io, serial);
    try device.mapBuffer(io, readback, .{ .mode = .{ .read = true }, .size = byte_count });
    defer device.unmapBuffer(io, readback) catch @panic("roundtrip readback unmap failed");
    var guard = try core.ObjectGuard.lock(io, readback.header.tracking);
    defer guard.unlock(io);
    const bytes = try readback.native.getConstMappedRange(0, byte_count);
    try checkPixels(bytes, expected);
}
