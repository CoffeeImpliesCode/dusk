//! Actual Linux two-device external image and semaphore acceptance.
//! This fixture is not a Dawn implementation port. API descriptors map to
//! Dawn 32f77c02294310054a660c393feded4bcb3f203c dawn.json:2198,2253,2266.
const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const vulkan = dusk.platform.vulkan_bindings;
const platform = dusk.platform;
const t = std.testing;
const helpers = @import("external_roundtrip_helpers.zig");
const producer_module = @import("linux_external_producer.zig");

test "Linux OpaqueFD producer GPU pixels cross a second high Device and return a fence" {
    try runRoundtrip(.opaque_fd);
}

test "Linux DMA-BUF modifier image pixels cross a second high Device and return a fence" {
    try runRoundtrip(.dma_buf);
}

test "Linux DMA-BUF unsupported modifier is established by actual properties" {
    try rejectUnsupportedModifier();
}

const Fixture = struct {
    threaded: std.Io.Threaded,
    instance: engine.Instance,
    adapters: engine.AdapterList,
    producer_device: engine.Device,
    consumer_device: engine.Device,

    fn init(self: *Fixture) !void {
        self.threaded = .init(t.allocator, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.instance = engine.Instance.init(.{ .backend_type = .vulkan });
        errdefer self.instance.deinit(t.allocator, io) catch @panic("instance rollback");
        self.adapters = try self.instance.enumerateAdapters(t.allocator, io, .{
            .backend_type = .vulkan,
            .feature_level = .core,
            .power_preference = .undefined_,
        });
        errdefer self.adapters.deinit(io) catch @panic("adapter rollback");
        if (self.adapters.items.len == 0) return error.NoPhysicalDevice;
        const adapter = &self.adapters.items[0];
        self.producer_device = try adapter.createDevice(t.allocator, io, .{
            .adapter = adapter,
            .feature_level = .core,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
        errdefer self.producer_device.deinit(t.allocator, io) catch
            @panic("producer rollback");
        self.consumer_device = try adapter.createDevice(t.allocator, io, .{
            .adapter = adapter,
            .feature_level = .core,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
    }

    fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
        @panic("Linux external roundtrip uncaptured error");
    }

    fn deinit(self: *Fixture) void {
        const io = self.threaded.io();
        self.consumer_device.deinit(t.allocator, io) catch @panic("consumer teardown");
        self.producer_device.deinit(t.allocator, io) catch @panic("producer teardown");
        self.adapters.deinit(io) catch @panic("adapters teardown");
        self.instance.deinit(t.allocator, io) catch @panic("instance teardown");
        self.threaded.deinit();
    }
};

fn expectFdOpen(io: std.Io, fd: c_int) !void {
    const duplicate = try platform.external_semaphore.duplicateHandle(io, fd);
    platform.external_semaphore.closeHandle(io, duplicate);
}

fn releaseApi(device: *engine.Device, io: std.Io, comptime Payload: type, alias: anytype, kind: core.Handle.Kind) void {
    var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
    defer guard.unlock(io);
    const payload = device.core.resolve(&guard, Payload, .{
        .ptr = @ptrCast(@alignCast(alias.handle orelse @panic("null fixture alias"))),
        .kind = kind,
    }) catch @panic("fixture canonical alias resolution");
    payload.header.releaseUserLocked(&guard, io) catch @panic("fixture alias release");
}

fn resolveApi(device: *engine.Device, io: std.Io, comptime Payload: type, alias: anytype, kind: core.Handle.Kind) !*Payload {
    var guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
    defer guard.unlock(io);
    return device.core.resolve(&guard, Payload, .{
        .ptr = @ptrCast(@alignCast(alias.handle orelse return error.NullFixtureAlias)),
        .kind = kind,
    });
}

const MemoryHandle = enum { opaque_fd, dma_buf };

fn runRoundtrip(handle_type: MemoryHandle) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const consumer = &fixture.consumer_device;
    const producer_native = &fixture.producer_device.native_context.?.native_device;
    const consumer_native = &consumer.native_context.?.native_device;
    try t.expectEqual(producer_native.physical.handle, consumer_native.physical.handle);
    try t.expect(producer_native.vk_device != consumer_native.vk_device);
    const producer_queue_gate = &fixture.producer_device.native_context.?.queue_operation_mutex;
    try producer_queue_gate.lock(io);
    defer producer_queue_gate.unlock(io);
    var producer = switch (handle_type) {
        .opaque_fd => try producer_module.Producer.init(producer_native),
        .dma_buf => try producer_module.Producer.initDmaBuf(t.allocator, producer_native),
    };
    defer producer.deinit(io);
    const memory_module = engine.shared_texture_memory;
    const fence_module = engine.shared_fence;
    const descriptor: api.descriptors.SharedTextureMemoryDescriptorChain = switch (handle_type) {
        .opaque_fd => .{
            .shared_texture_memory_opaque_fd_descriptor = .{
                .vk_image_create_info = &producer.image_info,
                .memory_fd = producer.memory_fd,
                .memory_type_index = producer.memory_type_index,
                .allocation_size = producer.allocation_size,
                .dedicated_allocation = true,
            },
        },
        .dma_buf => .{
            .shared_texture_memory_dma_buf_descriptor = .{
                .size = .{ .width = 4, .height = 4 },
                .drm_format = producer.drm_format,
                .drm_modifier = producer.drm_modifier,
                .plane_count = producer.plane_count,
                .planes = producer.planes[0..producer.plane_count],
            },
        },
    };
    const memory_alias = try memory_module.importSharedTextureMemory(t.allocator, io, consumer, &descriptor);
    defer releaseApi(consumer, io, memory_module.SharedTextureMemory, memory_alias, .shared_texture_memory);
    // Successful imports consume only a duplicate, not either caller descriptor.
    try expectFdOpen(io, producer.memory_fd);
    const memory = try resolveApi(consumer, io, memory_module.SharedTextureMemory, memory_alias, .shared_texture_memory);
    var properties: api.descriptors.SharedTextureMemoryProperties = undefined;
    try t.expectEqual(api.Status.success, try memory.getProperties(io, &properties));
    try t.expectEqual(api.TextureFormat.rgba8_unorm, properties.format);
    try t.expectEqual(@as(u32, 4), properties.size.width);
    try t.expectEqual(@as(u32, 4), properties.size.height);
    try t.expect(properties.usage.copy_src);
    const texture_alias = try memory.createTexture(t.allocator, io, &.{
        .format = .rgba8_unorm,
        .size = .{ .width = 4, .height = 4 },
        .usage = .{ .copy_src = true, .copy_dst = true },
    });
    defer releaseApi(consumer, io, engine.texture.Texture, texture_alias, .texture);
    const texture = try resolveApi(consumer, io, engine.texture.Texture, texture_alias, .texture);
    const input_fence = try fence_module.importSharedFence(t.allocator, io, consumer, &.{
        .shared_fence_vk_semaphore_opaque_fd_descriptor = .{ .handle = producer.signal_fd },
    });
    defer releaseApi(consumer, io, fence_module.SharedFence, input_fence, .shared_fence);
    try expectFdOpen(io, producer.signal_fd);
    try t.expectError(error.InvalidFenceValue, memory.beginAccess(io, texture_alias, &.{
        .concurrent_read = false,
        .initialized = true,
        .fence_count = 1,
        .fences = &.{input_fence},
        .signaled_value_count = 1,
        .signaled_values = &.{0},
        .shared_texture_memory_vk_image_layout_begin_state = .{
            .old_layout = vulkan.VK_IMAGE_LAYOUT_GENERAL,
            .new_layout = vulkan.VK_IMAGE_LAYOUT_GENERAL,
        },
    }));
    try expectFdOpen(io, producer.signal_fd);
    const waits = [_]api.SharedFence{input_fence};
    const values = [_]u64{1};
    try t.expectEqual(api.Status.success, try memory.beginAccess(io, texture_alias, &.{
        .concurrent_read = false,
        .initialized = true,
        .fence_count = 1,
        .fences = &waits,
        .signaled_value_count = 1,
        .signaled_values = &values,
        .shared_texture_memory_vk_image_layout_begin_state = .{
            .old_layout = vulkan.VK_IMAGE_LAYOUT_GENERAL,
            .new_layout = vulkan.VK_IMAGE_LAYOUT_GENERAL,
        },
    }));
    try helpers.readTexture(t.allocator, io, consumer, texture, .{ 255, 0, 255, 255 });
    var end: api.descriptors.SharedTextureMemoryEndAccessState = .{
        .initialized = false,
        .fence_count = 0,
        .shared_texture_memory_vk_image_layout_end_state = .{
            .old_layout = vulkan.VK_IMAGE_LAYOUT_GENERAL,
            .new_layout = vulkan.VK_IMAGE_LAYOUT_GENERAL,
        },
    };
    try t.expectEqual(api.Status.success, try memory.endAccess(t.allocator, io, texture_alias, &end));
    defer t.allocator.free(end.fences.?);
    defer t.allocator.free(end.signaled_values.?);
    try t.expect(end.initialized);
    try t.expectEqual(@as(usize, 1), end.fence_count);
    try t.expectEqual(@as(usize, 1), end.signaled_value_count);
    try t.expectEqual(@as(u64, 1), end.signaled_values.?[0]);
    const output_fence_alias = end.fences.?[0];
    defer releaseApi(consumer, io, fence_module.SharedFence, output_fence_alias, .shared_fence);
    const output_fence = try resolveApi(consumer, io, fence_module.SharedFence, output_fence_alias, .shared_fence);
    var export_info: api.descriptors.SharedFenceExportInfo = .{
        .type_ = .vk_semaphore_opaque_fd,
        .shared_fence_vk_semaphore_opaque_fd_export_info = .{ .handle = -2 },
    };
    try t.expectEqual(api.Status.success, try output_fence.exportInfo(io, &export_info));
    const returned_fd = export_info.shared_fence_vk_semaphore_opaque_fd_export_info.?.handle;
    defer platform.external_semaphore.closeHandle(io, returned_fd);
    try t.expect(returned_fd >= 0);
    try producer.waitReturnedFence(io, returned_fd);
    try expectFdOpen(io, returned_fd);
    // A descriptor refusal cannot consume the caller-owned memory handle either.
    switch (handle_type) {
        .opaque_fd => try t.expectError(error.InvalidImageCreateInfo, memory_module.importSharedTextureMemory(t.allocator, io, consumer, &.{
            .shared_texture_memory_opaque_fd_descriptor = .{
                .vk_image_create_info = null,
                .memory_fd = producer.memory_fd,
                .memory_type_index = producer.memory_type_index,
                .allocation_size = producer.allocation_size,
                .dedicated_allocation = true,
            },
        })),
        .dma_buf => try t.expectError(error.InvalidDmaBufPlaneCount, memory_module.importSharedTextureMemory(t.allocator, io, consumer, &.{
            .shared_texture_memory_dma_buf_descriptor = .{
                .size = .{ .width = 4, .height = 4 },
                .drm_format = producer.drm_format,
                .drm_modifier = producer.drm_modifier,
                .plane_count = 0,
                .planes = null,
            },
        })),
    }
    try expectFdOpen(io, producer.memory_fd);
}

fn rejectUnsupportedModifier() !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const device = &fixture.consumer_device;
    const native = &device.native_context.?.native_device;
    // Absence is an explicit failure, not proof of a queried modifier result.
    if (!native.capabilities.external_memory_dma_buf)
        return error.DmaBufCapabilityUnavailable;
    const dma_buf = platform.external_memory_import.dma_buf;
    const options: platform.external_memory.DeviceOptions = .{
        .physical_device = native.physical.handle,
        .device = native.vk_device,
        .instance_procs = native.instance.procs,
        .device_procs = native.procs,
        .enabled_extensions = native.capabilities.enabled_device,
        .capabilities = &native.capabilities,
    };
    const invalid_modifier = std.math.maxInt(u64);
    try t.expect(!try dma_buf.supportsDmaBuf(t.allocator, options, .{
        .format = vulkan.VK_FORMAT_R8G8B8A8_UNORM,
        .drm_format = dma_buf.drmFourcc('A', 'B', '2', '4'),
        .modifier = invalid_modifier,
        .plane_count = 1,
        .usage = vulkan.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
    }));
    // This descriptor is only an unsupported-format preflight probe. The FD is
    // not DMA-BUF, and no OpaqueFD export is substituted for one.
    const probe = try std.Io.Dir.cwd().openFile(io, "/dev/null", .{});
    defer probe.close(io);
    const planes = [_]api.descriptors.SharedTextureMemoryDmaBufPlane{.{
        .fd = probe.handle,
        .offset = 0,
        .stride = 16,
    }};
    try t.expectError(error.UnsupportedDmaBufModifier, engine.shared_texture_memory.importSharedTextureMemory(t.allocator, io, device, &.{
        .shared_texture_memory_dma_buf_descriptor = .{
            .size = .{ .width = 4, .height = 4 },
            .drm_format = dma_buf.drmFourcc('A', 'B', '2', '4'),
            .drm_modifier = invalid_modifier,
            .plane_count = planes.len,
            .planes = &planes,
        },
    }));
    try expectFdOpen(io, probe.handle);
}
