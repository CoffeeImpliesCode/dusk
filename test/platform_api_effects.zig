//! Consumer contracts for the generated native platform API.

const std = @import("std");
const api = @import("dusk").api;
const objects = api.objects;
const descriptors = api.descriptors;

test "allocating platform object and procedure signatures take self allocator then Io" {
    const contracts = .{
        .{ objects.Instance.createSurface, "instance_create_surface", fn (objects.Instance, std.mem.Allocator, std.Io, *const descriptors.SurfaceDescriptorChain) api.errors.NativeIoError!objects.Surface },
        .{ objects.Surface.configure, "surface_configure", fn (objects.Surface, std.mem.Allocator, std.Io, *const descriptors.SurfaceConfigurationChain) api.errors.NativeIoError!void },
        .{ objects.Surface.getCapabilities, "surface_get_capabilities", fn (objects.Surface, std.mem.Allocator, std.Io, objects.Adapter, *descriptors.SurfaceCapabilities) api.errors.NativeIoError!api.enums.Status },
        .{ objects.Surface.getCurrentTexture, "surface_get_current_texture", fn (objects.Surface, std.mem.Allocator, std.Io, *descriptors.SurfaceTexture) api.errors.NativeIoError!void },
        .{ objects.Device.importSharedTextureMemory, "device_import_shared_texture_memory", fn (objects.Device, std.mem.Allocator, std.Io, *const descriptors.SharedTextureMemoryDescriptorChain) api.errors.NativeIoError!objects.SharedTextureMemory },
        .{ objects.Device.importSharedFence, "device_import_shared_fence", fn (objects.Device, std.mem.Allocator, std.Io, *const descriptors.SharedFenceDescriptorChain) api.errors.NativeIoError!objects.SharedFence },
        .{ objects.SharedTextureMemory.createTexture, "shared_texture_memory_create_texture", fn (objects.SharedTextureMemory, std.mem.Allocator, std.Io, ?*const descriptors.TextureDescriptorChain) api.errors.NativeIoError!objects.Texture },
        .{ objects.SharedTextureMemory.endAccess, "shared_texture_memory_end_access", fn (objects.SharedTextureMemory, std.mem.Allocator, std.Io, objects.Texture, *descriptors.SharedTextureMemoryEndAccessState) api.errors.NativeIoError!api.enums.Status },
    };
    inline for (contracts) |contract| {
        try std.testing.expect(contract[0] == contract[2]);
        try std.testing.expect(@FieldType(api.proc.ProcTable, contract[1]) == *const contract[2]);
    }
}

test "nonallocating platform object and procedure signatures take self then Io only" {
    const contracts = .{
        .{ objects.Surface.present, "surface_present", fn (objects.Surface, std.Io) api.errors.NativeIoError!api.enums.Status },
        .{ objects.Surface.unconfigure, "surface_unconfigure", fn (objects.Surface, std.Io) api.errors.NativeIoError!void },
        .{ objects.Surface.release, "surface_release", fn (objects.Surface, std.Io) api.errors.NativeIoError!void },
        .{ objects.SharedTextureMemory.getProperties, "shared_texture_memory_get_properties", fn (objects.SharedTextureMemory, std.Io, *descriptors.SharedTextureMemoryProperties) api.errors.NativeIoError!api.enums.Status },
        .{ objects.SharedTextureMemory.beginAccess, "shared_texture_memory_begin_access", fn (objects.SharedTextureMemory, std.Io, objects.Texture, *const descriptors.SharedTextureMemoryBeginAccessDescriptorChain) api.errors.NativeIoError!api.enums.Status },
        .{ objects.SharedFence.exportInfo, "shared_fence_export_info", fn (objects.SharedFence, std.Io, *descriptors.SharedFenceExportInfo) api.errors.NativeIoError!void },
    };
    inline for (contracts) |contract| {
        try std.testing.expect(contract[0] == contract[2]);
        try std.testing.expect(@FieldType(api.proc.ProcTable, contract[1]) == *const contract[2]);
    }
    try std.testing.expect(@typeInfo(api.errors.NativeIoError).error_set != null);
}

test "shared buffer contracts remain outside the native texture and fence effect" {
    const contracts = .{
        .{ objects.Device.importSharedBufferMemory, "device_import_shared_buffer_memory", fn (objects.Device, *const descriptors.SharedBufferMemoryDescriptorChain) api.errors.Error!objects.SharedBufferMemory },
        .{ objects.SharedBufferMemory.createBuffer, "shared_buffer_memory_create_buffer", fn (objects.SharedBufferMemory, ?*const descriptors.BufferDescriptorChain) api.errors.Error!objects.Buffer },
        .{ objects.SharedBufferMemory.beginAccess, "shared_buffer_memory_begin_access", fn (objects.SharedBufferMemory, objects.Buffer, *const descriptors.SharedBufferMemoryBeginAccessDescriptorChain) api.errors.Error!api.enums.Status },
        .{ objects.SharedBufferMemory.endAccess, "shared_buffer_memory_end_access", fn (objects.SharedBufferMemory, objects.Buffer, *descriptors.SharedBufferMemoryEndAccessState) api.errors.Error!api.enums.Status },
    };
    inline for (contracts) |contract| {
        try std.testing.expect(contract[0] == contract[2]);
        try std.testing.expect(@FieldType(api.proc.ProcTable, contract[1]) == *const contract[2]);
    }
}

test "end access exposes an optional mutable Vulkan layout output arm" {
    try std.testing.expect(@FieldType(descriptors.SharedTextureMemoryEndAccessState, "shared_texture_memory_vk_image_layout_end_state") ==
        ?*descriptors.SharedTextureMemoryVkImageLayoutEndState);

    var layout: descriptors.SharedTextureMemoryVkImageLayoutEndState = .{
        .old_layout = 0,
        .new_layout = 0,
    };
    var out: descriptors.SharedTextureMemoryEndAccessState = .{
        .initialized = false,
        .fence_count = 0,
    };
    try std.testing.expect(out.shared_texture_memory_vk_image_layout_end_state == null);
    out.shared_texture_memory_vk_image_layout_end_state = &layout;
    const arm = out.shared_texture_memory_vk_image_layout_end_state.?;
    arm.old_layout = 1;
    arm.new_layout = 7;
    try std.testing.expect(arm == &layout);
    try std.testing.expectEqual(@as(i32, 1), layout.old_layout);
    try std.testing.expectEqual(@as(i32, 7), layout.new_layout);
    out.shared_texture_memory_vk_image_layout_end_state = null;
    try std.testing.expect(out.shared_texture_memory_vk_image_layout_end_state == null);
}

test "fence export exposes optional mutable opaque and sync FD output arms" {
    try std.testing.expect(@FieldType(descriptors.SharedFenceExportInfo, "shared_fence_vk_semaphore_opaque_fd_export_info") ==
        ?*descriptors.SharedFenceVkSemaphoreOpaqueFDExportInfo);
    try std.testing.expect(@FieldType(descriptors.SharedFenceExportInfo, "shared_fence_sync_fd_export_info") ==
        ?*descriptors.SharedFenceSyncFDExportInfo);

    var opaque_fd: descriptors.SharedFenceVkSemaphoreOpaqueFDExportInfo = .{ .handle = -1 };
    var sync_fd: descriptors.SharedFenceSyncFDExportInfo = .{ .handle = -1 };
    var out: descriptors.SharedFenceExportInfo = .{ .type_ = .vk_semaphore_opaque_fd };
    try std.testing.expect(out.shared_fence_vk_semaphore_opaque_fd_export_info == null);
    try std.testing.expect(out.shared_fence_sync_fd_export_info == null);

    out.shared_fence_vk_semaphore_opaque_fd_export_info = &opaque_fd;
    out.shared_fence_vk_semaphore_opaque_fd_export_info.?.handle = 11;
    try std.testing.expect(out.shared_fence_vk_semaphore_opaque_fd_export_info.? == &opaque_fd);
    try std.testing.expectEqual(@as(c_int, 11), opaque_fd.handle);
    try std.testing.expect(out.shared_fence_sync_fd_export_info == null);

    out.shared_fence_vk_semaphore_opaque_fd_export_info = null;
    out.type_ = .sync_fd;
    out.shared_fence_sync_fd_export_info = &sync_fd;
    out.shared_fence_sync_fd_export_info.?.handle = 13;
    try std.testing.expect(out.shared_fence_sync_fd_export_info.? == &sync_fd);
    try std.testing.expectEqual(@as(c_int, 13), sync_fd.handle);
    try std.testing.expect(out.shared_fence_vk_semaphore_opaque_fd_export_info == null);
    out.shared_fence_sync_fd_export_info = null;
    try std.testing.expect(out.shared_fence_sync_fd_export_info == null);
}
