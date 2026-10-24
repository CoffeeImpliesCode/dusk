//! Allocated NDK AHardwareBuffer -> real shared image -> GPU transfer -> SyncFD roundtrip.
//! Pinned Dawn 32f77c02294310054a660c393feded4bcb3f203c:
//! vulkan/SharedTextureMemoryVk.cpp:999 SharedTextureMemory::Create(AHB descriptor),
//! :1059 BeginAccessImpl, :1166 EndAccessImpl; SharedFenceVk.cpp:53 Create(SyncFD),
//! :93 ExportInfoImpl. This fixture runs inside the task-owned NativeActivity.
const std = @import("std");
const dusk = @import("dusk");
const ndk = @import("android_platform");
const api = dusk.api;
const engine = dusk.engine;
const core = dusk.core;
const vk = dusk.platform.vulkan_bindings;
const memory_mod = engine.shared_texture_memory;
const fence_mod = engine.shared_fence;
const handles = engine.native_async_handles;
const transfer = @import("external_roundtrip_helpers.zig");
const external_fd = dusk.platform.external_semaphore;

pub const Error = engine.instance.Error || engine.device.InitError ||
    engine.device.OperationError || memory_mod.ImportTextureError || memory_mod.Error ||
    fence_mod.ImportFenceError || fence_mod.SharedFenceExportError || transfer.Error ||
    core.HandleError || core.ReferenceError || error{
    NoPhysicalDevice,
    HardwareBufferAllocationFailed,
    InvalidAllocatedHardwareBuffer,
    UnexpectedImportedFormat,
    InvalidImportedExtent,
    TransferUsageUnavailable,
    UnexpectedStatus,
    InvalidEndFence,
    InvalidEndLayout,
    InvalidExportedFence,
    InvalidImportedProvenance,
    InvalidOwner,
};

fn requireSuccess(status: api.Status) error{UnexpectedStatus}!void {
    if (status != .success) return error.UnexpectedStatus;
}

test "Android fixture rejects non-success access outcomes" {
    try requireSuccess(.success);
    try std.testing.expectError(error.UnexpectedStatus, requireSuccess(.error_));
}

pub fn run(allocator: std.mem.Allocator, io: std.Io) Error!void {
    var descriptor: ndk.AHardwareBuffer_Desc = std.mem.zeroes(ndk.AHardwareBuffer_Desc);
    descriptor.width = transfer.extent;
    descriptor.height = transfer.extent;
    descriptor.layers = 1;
    descriptor.format = ndk.AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM;
    descriptor.usage = ndk.AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE |
        ndk.AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT;
    var allocated: ?*ndk.AHardwareBuffer = null;
    if (ndk.AHardwareBuffer_allocate(&descriptor, &allocated) != 0) {
        return error.HardwareBufferAllocationFailed;
    }
    const buffer = allocated orelse return error.InvalidAllocatedHardwareBuffer;
    defer ndk.AHardwareBuffer_release(buffer);
    var actual: ndk.AHardwareBuffer_Desc = undefined;
    ndk.AHardwareBuffer_describe(buffer, &actual);
    if (actual.width != transfer.extent or actual.height != transfer.extent or
        actual.layers != 1 or actual.format != descriptor.format)
    {
        return error.InvalidAllocatedHardwareBuffer;
    }
    var instance = engine.Instance.init(.{ .backend_type = .vulkan });
    defer instance.deinit(allocator, io) catch @panic("AHB instance teardown failed");
    var adapters = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(io) catch @panic("AHB adapter teardown failed");
    if (adapters.items.len == 0) return error.NoPhysicalDevice;
    var device = try adapters.items[0].createDevice(allocator, io, .{
        .adapter = &adapters.items[0],
        .feature_level = .core,
    });
    defer device.deinit(allocator, io) catch @panic("AHB device teardown failed");
    const imported = try memory_mod.importSharedTextureMemory(allocator, io, &device, &.{
        .label = "allocated NDK AHB proof",
        .shared_texture_memory_a_hardware_buffer_descriptor = .{ .handle = buffer },
    });
    const memory = try resolveMemory(io, &device, imported);
    defer device.release(allocator, io, memory) catch @panic("AHB memory release failed");
    var properties: api.descriptors.SharedTextureMemoryProperties = .{
        .usage = .{},
        .size = .{ .width = 0, .height = 0, .depth_or_array_layers = 0 },
        .format = .undefined_,
    };
    try requireSuccess(try memory.getProperties(io, &properties));
    if (properties.format != .rgba8_unorm or memory.backing.imported.format != vk.VK_FORMAT_R8G8B8A8_UNORM) {
        return error.UnexpectedImportedFormat;
    }
    if (memory.backing.imported.provenance != .android_hardware_buffer or
        memory.backing.imported.external_queue_family != vk.VK_QUEUE_FAMILY_FOREIGN_EXT)
    {
        return error.InvalidImportedProvenance;
    }
    if (properties.size.width != transfer.extent or properties.size.height != transfer.extent or
        properties.size.depth_or_array_layers != 1) return error.InvalidImportedExtent;
    if (!properties.usage.copy_src or !properties.usage.copy_dst) return error.TransferUsageUnavailable;
    const texture_api = try memory.createTexture(allocator, io, null);
    const texture = try resolveTexture(io, &device, texture_api);
    defer device.release(allocator, io, texture) catch @panic("AHB texture release failed");
    try requireSuccess(try memory.beginAccess(io, texture_api, &.{
        .concurrent_read = false,
        .initialized = false,
        .fence_count = 0,
        .shared_texture_memory_vk_image_layout_begin_state = .{
            .old_layout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .new_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
        },
    }));
    var access_active = true;
    defer if (access_active) {
        const cleanup_fd = endAndExport(allocator, io, &device, memory, texture_api) catch
            @panic("AHB active-access rollback failed");
        external_fd.closeHandle(io, cleanup_fd);
    };
    const expected = [4]u8{ 17, 63, 129, 255 };
    try transfer.writeTexture(allocator, io, &device, texture, expected);
    try transfer.readTexture(allocator, io, &device, texture, expected);
    const first_fd = try endAndExport(allocator, io, &device, memory, texture_api);
    access_active = false;
    defer external_fd.closeHandle(io, first_fd);
    const waited_api = try fence_mod.importSharedFence(allocator, io, &device, &.{
        .shared_fence_sync_fd_descriptor = .{ .handle = first_fd },
    });
    const waited = try resolveFence(io, &device, waited_api);
    defer device.release(allocator, io, waited) catch @panic("AHB imported fence release failed");
    const waits = [_]api.SharedFence{waited_api};
    const values = [_]u64{1};
    try requireSuccess(try memory.beginAccess(io, texture_api, &.{
        .concurrent_read = false,
        .initialized = true,
        .fence_count = 1,
        .fences = &waits,
        .signaled_value_count = 1,
        .signaled_values = &values,
        .shared_texture_memory_vk_image_layout_begin_state = .{
            .old_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
            .new_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
        },
    }));
    access_active = true;
    try transfer.readTexture(allocator, io, &device, texture, expected);
    const final_fd = try endAndExport(allocator, io, &device, memory, texture_api);
    access_active = false;
    defer external_fd.closeHandle(io, final_fd);
}

fn resolveMemory(io: std.Io, device: *engine.Device, value: api.SharedTextureMemory) Error!*memory_mod.SharedTextureMemory {
    const header = try handles.resourceHeader(api.SharedTextureMemory, value, .shared_texture_memory);
    var guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
    defer guard.unlock(io);
    try handles.validateResourceLocked(device, &guard, header, .shared_texture_memory);
    return @fieldParentPtr("header", header);
}

fn resolveTexture(io: std.Io, device: *engine.Device, value: api.Texture) Error!*engine.texture.Texture {
    const header = try handles.resourceHeader(api.Texture, value, .texture);
    var guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
    defer guard.unlock(io);
    try handles.validateResourceLocked(device, &guard, header, .texture);
    return @fieldParentPtr("header", header);
}

fn resolveFence(io: std.Io, device: *engine.Device, value: api.SharedFence) Error!*fence_mod.SharedFence {
    const header = try handles.resourceHeader(api.SharedFence, value, .shared_fence);
    var guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
    defer guard.unlock(io);
    try handles.validateResourceLocked(device, &guard, header, .shared_fence);
    return @fieldParentPtr("header", header);
}

fn endAndExport(allocator: std.mem.Allocator, io: std.Io, device: *engine.Device, memory: *memory_mod.SharedTextureMemory, texture: api.Texture) Error!c_int {
    var out: api.descriptors.SharedTextureMemoryEndAccessState = .{
        .initialized = false,
        .fence_count = 0,
        .shared_texture_memory_vk_image_layout_end_state = .{
            .old_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
            .new_layout = vk.VK_IMAGE_LAYOUT_GENERAL,
        },
    };
    try requireSuccess(try memory.endAccess(allocator, io, texture, &out));
    const fences = out.fences orelse return error.InvalidEndFence;
    defer allocator.free(fences);
    const values = out.signaled_values orelse return error.InvalidEndFence;
    defer allocator.free(values);
    if (fences.len != 1 or values.len != 1 or out.fence_count != 1 or
        out.signaled_value_count != 1 or values[0] != 1 or !out.initialized) return error.InvalidEndFence;
    const fence = try resolveFence(io, device, fences[0]);
    defer device.release(allocator, io, fence) catch @panic("AHB end fence release failed");
    const layout = out.shared_texture_memory_vk_image_layout_end_state orelse return error.InvalidEndLayout;
    if (layout.new_layout != vk.VK_IMAGE_LAYOUT_GENERAL) return error.InvalidEndLayout;
    var exported: api.descriptors.SharedFenceExportInfo = .{
        .type_ = .sync_fd,
        .shared_fence_sync_fd_export_info = .{ .handle = -2 },
    };
    try requireSuccess(try fence.exportInfo(io, &exported));
    const fd = exported.shared_fence_sync_fd_export_info.?.handle;
    if (exported.type_ != .sync_fd or fd < -1) return error.InvalidExportedFence;
    return fd;
}
