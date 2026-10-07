const std = @import("std");
const dusk = @import("dusk");
const t = std.testing;

fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: dusk.core.ErrorView) void {
    @panic("unexpected utility device error");
}

test "timestamp quantization preserves the requested device policy" {
    const allocator = t.allocator;
    const io = t.io;
    var instance = dusk.engine.Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var adapters = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .null_,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(io) catch @panic("adapter teardown failed");
    try t.expect(adapters.items.len != 0);
    var user_context: u8 = 0;
    var mutex: std.Io.Mutex = .init;
    var options: dusk.engine.Device.CreateDeviceOptions = .{
        .adapter = &adapters.items[0],
        .consume_adapter = false,
        .feature_level = .core,
        .uncaptured_context = &user_context,
        .uncaptured_callback = uncaptured,
        .object_mutex = &mutex,
    };
    try t.expect(options.timestamp_quantization);
    var default_device = try adapters.items[0].createDevice(allocator, io, options);
    defer default_device.deinit(allocator, io) catch @panic("device teardown failed");
    try t.expect(default_device.timestamp_quantization);
    try default_device.deinit(allocator, io);
    options.timestamp_quantization = false;
    var exact_device = try adapters.items[0].createDevice(allocator, io, options);
    defer exact_device.deinit(allocator, io) catch @panic("device teardown failed");
    try t.expect(!exact_device.timestamp_quantization);
}

test "final native utility context submits pending owned scratch and permits teardown" {
    const allocator = t.allocator;
    const io = t.io;
    var instance = dusk.engine.Instance.init(.{ .backend_type = .vulkan });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");
    var adapters = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(io) catch @panic("adapter teardown failed");
    try t.expect(adapters.items.len != 0);
    var user_context: u8 = 0;
    var device = try adapters.items[0].createDevice(allocator, io, .{
        .adapter = &adapters.items[0],
        .feature_level = .core,
        .uncaptured_context = &user_context,
        .uncaptured_callback = uncaptured,
    });
    defer device.deinit(allocator, io) catch @panic("device teardown failed");
    const destination = try device.createBuffer(allocator, io, .{
        .size = 16,
        .usage = .{ .copy_dst = true, .map_read = true },
    });
    defer device.release(allocator, io, destination) catch @panic("buffer release failed");
    const expected: [16]u8 = .{ 0, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 7, 11, 19 };
    var lease = try device.getQueue(io);
    defer lease.deinit(io);
    var recording = dusk.engine.recording_context.CommandRecordingContext.init(allocator);
    defer recording.deinit();
    recording.command_buffer = lease.commandBuffer();
    {
        const native = device.native.?;
        var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
        defer guard.unlock(io);
        if (native.recording_uses == null) {
            native.recording_uses = try dusk.engine.native_resources.PendingUses.prepareDeclaredLocked(
                allocator,
                &guard,
                &device.core,
                &.{},
            );
        }
        const context: dusk.engine.native_kernels.Context = .{
            .io = io,
            .guard = &guard,
            .device = &device.core,
            .queue = &native.queue,
            .recording = &recording,
            .pending_uses = &native.recording_uses.?,
            .cache = &native.kernel_cache.?,
        };
        const scratch = try dusk.engine.native_kernels.scratchBuffer(context, .{
            .size = expected.len,
            .native_usage = (dusk.api.BufferUsage{ .copy_src = true, .copy_dst = true }).toFlags(),
        });
        try dusk.engine.native_kernels.uploadParameters(context, scratch, &expected);
        try dusk.engine.native_kernels.copyBuffer(context, scratch, .{
            .owner = destination,
            .offset = 0,
            .size = expected.len,
        });
    }
    const submitted = try lease.submit(
        allocator,
        io,
        .{ .command_buffers = &.{lease.commandBuffer()} },
        &.{},
    );
    lease.deinit(io);
    try device.wait(io, submitted.serial);
    try device.mapBuffer(io, destination, .{
        .mode = .{ .read = true },
        .offset = 0,
        .size = expected.len,
    });
    defer device.unmapBuffer(io, destination) catch @panic("buffer unmap failed");
    var guard = dusk.core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    const actual = try destination.native.getConstMappedRange(0, expected.len);
    try t.expectEqualSlices(u8, &expected, actual);
}
