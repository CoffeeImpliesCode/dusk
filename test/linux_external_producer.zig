//! DMA import analogue: src/dawn/native/vulkan/SharedTextureMemoryVk.cpp:385-452
//! validates modifier and plane count. :502-529 creates and queries DRM-modifier images.
//! Producer modifier-list creation and memory-FD export remain fixture-only.
//! Native producer fixture. Dawn pin: 32f77c02294310054a660c393feded4bcb3f203c.
//! Semaphore mapping: src/dawn/native/vulkan/external_semaphore/
//! SemaphoreServiceImplementationFD.cpp:140-174 creates and exports the signal semaphore.
//! TextureVk.cpp:1832-1864 signals it and exports only after successful submission.
//! DeviceVk.cpp:920-941 returns the semaphore and released layout metadata.
//! The dedicated memory-FD producer is fixture code, not a claimed Dawn memory-export port.
//! The caller serializes all submissions on the borrowed device queue.
//!
const std = @import("std");
const dusk = @import("dusk");
const engine = dusk.engine;
const vk = @import("vulkan");
const dispatch = dusk.vk.dispatch;
const semaphore = dusk.platform;

test "producer descriptor is a chain-free 4x4 RGBA8 external import description" {
    const info = imageInfo();
    try std.testing.expect(info.pNext == null);
    try std.testing.expectEqual(vk.VK_FORMAT_R8G8B8A8_UNORM, info.format);
    try std.testing.expectEqual(@as(u32, 4), info.extent.width);
    try std.testing.expectEqual(@as(u32, 4), info.extent.height);
    try std.testing.expectEqual(@as(u32, 1), info.extent.depth);
}

test "external image requires both import and export support for opaque fd" {
    try std.testing.expectError(error.UnsupportedExternalImage, checkExternalImage(.{}));
    try std.testing.expectError(error.UnsupportedExternalImage, checkExternalImage(.{
        .externalMemoryFeatures = vk.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT,
        .compatibleHandleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
    }));
    try std.testing.expectError(error.UnsupportedExternalImage, checkExternalImage(.{
        .externalMemoryFeatures = vk.VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT,
        .compatibleHandleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
    }));
    try checkExternalImage(.{
        .externalMemoryFeatures = vk.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT |
            vk.VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT,
        .compatibleHandleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
    });
}

test "DMA export requires matching import and export handle support" {
    try std.testing.expect(!dmaExportSupported(.{}));
    try std.testing.expect(!dmaExportSupported(.{
        .externalMemoryFeatures = vk.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT |
            vk.VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT,
        .compatibleHandleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
    }));
    try std.testing.expect(dmaExportSupported(.{
        .externalMemoryFeatures = vk.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT |
            vk.VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT,
        .compatibleHandleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    }));
}

pub const Error = dispatch.Error || dispatch.LoadError || semaphore.SemaphoreError ||
    engine.vulkan_device.MemoryTypeError || std.mem.Allocator.Error || error{
    UnsupportedExternalImage,
    InvalidMemoryHandle,
    QueueHandleIsNull,
    UnsupportedDmaBuf,
    ModifierPropertiesUnstable,
};

pub const Producer = struct {
    native: *engine.vulkan_device.Device,
    image_info: vk.VkImageCreateInfo,
    allocation_size: u64,
    memory_type_index: u32,
    memory_fd: c_int,
    signal_fd: c_int,
    image: vk.VkImage,
    memory: vk.VkDeviceMemory,
    signal: vk.VkSemaphore,
    pool: vk.VkCommandPool,
    command_buffer: vk.VkCommandBuffer,
    queue: vk.VkQueue,
    semaphore_service: semaphore.Semaphore,
    drm_modifier: u64 = 0,
    plane_count: usize = 0,
    planes: [4]dusk.api.descriptors.SharedTextureMemoryDmaBufPlane = @splat(.{
        .fd = -1,
        .offset = 0,
        .stride = 0,
    }),
    drm_format: u32 = 0x34324241,

    pub fn init(native: *engine.vulkan_device.Device) Error!Producer {
        return initImage(native, null);
    }

    pub fn initDmaBuf(
        allocator: std.mem.Allocator,
        native: *engine.vulkan_device.Device,
    ) Error!Producer {
        if (!native.capabilities.external_memory_dma_buf) return error.UnsupportedDmaBuf;
        const modifier = try selectDmaModifier(allocator, native);
        return initImage(native, modifier);
    }

    fn initImage(
        native: *engine.vulkan_device.Device,
        modifier: ?vk.VkDrmFormatModifierPropertiesEXT,
    ) Error!Producer {
        if (native.instance.procs.get_physical_device_external_semaphore_properties == null)
            return error.MissingDeviceProc;
        if (!native.capabilities.enabled_device.has(.external_memory_fd))
            return error.UnsupportedExternalImage;
        const procs = native.procs;
        const create_image = procs.create_image orelse return error.MissingDeviceProc;
        const destroy_image = procs.destroy_image orelse return error.MissingDeviceProc;
        const requirements_proc = procs.get_image_memory_requirements orelse
            return error.MissingDeviceProc;
        const allocate = procs.allocate_memory orelse return error.MissingDeviceProc;
        const free = procs.free_memory orelse return error.MissingDeviceProc;
        const bind = procs.bind_image_memory orelse return error.MissingDeviceProc;
        const get_fd = procs.get_memory_fd_khr orelse return error.MissingDeviceProc;
        const destroy_semaphore = procs.destroy_semaphore orelse return error.MissingDeviceProc;
        const destroy_pool = procs.destroy_command_pool orelse return error.MissingDeviceProc;
        var base = imageInfo();
        if (modifier != null) {
            base.tiling = vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
        } else {
            try queryExternalImage(native, base);
        }
        const handle_type: vk.VkExternalMemoryHandleTypeFlagBits = if (modifier != null)
            vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT
        else
            vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
        const service = semaphore.Semaphore.init(.{
            .device = native.vk_device,
            .device_procs = procs,
            .support = .{
                .physical_device = native.physical.handle,
                .instance_procs = native.instance.procs,
                .enabled_extensions = native.capabilities.enabled_device,
                .handle_type = .opaque_fd,
            },
        });
        if (!service.isSupported()) return error.UnsupportedHandleType;
        const queue = try native.fetchQueue();
        if (queue == null) return error.QueueHandleIsNull;
        var external_info: vk.VkExternalMemoryImageCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .handleTypes = @intCast(handle_type),
        };
        const modifier_values = [1]u64{if (modifier) |value| value.drmFormatModifier else 0};
        var modifier_list: vk.VkImageDrmFormatModifierListCreateInfoEXT = .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
            .drmFormatModifierCount = 1,
            .pDrmFormatModifiers = &modifier_values,
        };
        if (modifier != null) external_info.pNext = &modifier_list;
        var create_info = base;
        create_info.pNext = &external_info;
        var image: vk.VkImage = null;
        try dispatch.checkVkSuccess(create_image(native.vk_device, &create_info, null, &image));
        errdefer if (image != null) destroy_image(native.vk_device, image, null);
        var requirements: vk.VkMemoryRequirements = undefined;
        requirements_proc(native.vk_device, image, &requirements);
        const type_index = try engine.vulkan_device.findMemoryTypeIndex(
            &native.physical.memory_properties,
            requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            0,
        );
        var dedicated: vk.VkMemoryDedicatedAllocateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
            .image = image,
        };
        var export_info: vk.VkExportMemoryAllocateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
            .pNext = &dedicated,
            .handleTypes = @intCast(handle_type),
        };
        const allocation: vk.VkMemoryAllocateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = &export_info,
            .allocationSize = requirements.size,
            .memoryTypeIndex = type_index,
        };
        var memory: vk.VkDeviceMemory = null;
        try dispatch.checkVkSuccess(allocate(native.vk_device, &allocation, null, &memory));
        errdefer {
            destroy_image(native.vk_device, image, null);
            image = null;
            free(native.vk_device, memory, null);
        }
        try dispatch.checkVkSuccess(bind(native.vk_device, image, memory, 0));
        const fd_info: vk.VkMemoryGetFdInfoKHR = .{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
            .memory = memory,
            .handleType = handle_type,
        };
        var memory_fd: c_int = -2;
        try dispatch.checkVkSuccess(get_fd(native.vk_device, &fd_info, &memory_fd));
        if (memory_fd < 0) return error.InvalidMemoryHandle;
        errdefer closeOnInitError(memory_fd);
        const signal = try service.createExportableSemaphore();
        errdefer destroy_semaphore(native.vk_device, signal, null);
        const commands = try createPool(native);
        errdefer destroy_pool(native.vk_device, commands.pool, null);
        var self: Producer = .{
            .native = native,
            .image_info = base,
            .allocation_size = requirements.size,
            .memory_type_index = type_index,
            .memory_fd = memory_fd,
            .signal_fd = -2,
            .image = image,
            .memory = memory,
            .signal = signal,
            .pool = commands.pool,
            .command_buffer = commands.command_buffer,
            .queue = queue,
            .semaphore_service = service,
        };
        if (modifier) |value| try self.readDmaLayout(value);
        try self.recordRelease();
        try self.submitAndWait(null, signal);
        self.signal_fd = try service.exportSemaphore(signal);
        native.handles.acquire(.image);
        native.handles.acquire(.memory);
        native.handles.acquire(.command_pool);
        native.handles.acquire(.command_buffer);
        return self;
    }

    fn readDmaLayout(
        self: *Producer,
        expected: vk.VkDrmFormatModifierPropertiesEXT,
    ) Error!void {
        const query = self.native.procs.get_image_drm_format_modifier_properties_ext orelse
            return error.MissingDeviceProc;
        const layout_query = self.native.procs.get_image_subresource_layout orelse
            return error.MissingDeviceProc;
        var actual: vk.VkImageDrmFormatModifierPropertiesEXT = .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT,
        };
        try dispatch.checkVkSuccess(query(self.native.vk_device, self.image, &actual));
        if (actual.drmFormatModifier != expected.drmFormatModifier)
            return error.UnsupportedDmaBuf;
        self.drm_modifier = actual.drmFormatModifier;
        self.plane_count = expected.drmFormatModifierPlaneCount;
        if (self.plane_count == 0 or self.plane_count > self.planes.len)
            return error.UnsupportedDmaBuf;
        for (self.planes[0..self.plane_count], 0..) |*plane, index| {
            const subresource: vk.VkImageSubresource = .{
                .aspectMask = @as(vk.VkImageAspectFlags, vk.VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT) << @intCast(index),
                .mipLevel = 0,
                .arrayLayer = 0,
            };
            var layout: vk.VkSubresourceLayout = undefined;
            layout_query(self.native.vk_device, self.image, &subresource, &layout);
            if (layout.rowPitch == 0 or layout.rowPitch > std.math.maxInt(u32))
                return error.UnsupportedDmaBuf;
            if (layout.offset >= self.allocation_size) return error.UnsupportedDmaBuf;
            plane.* = .{
                .fd = self.memory_fd,
                .offset = layout.offset,
                .stride = @intCast(layout.rowPitch),
            };
        }
    }

    pub fn deinit(self: *Producer, io: std.Io) void {
        semaphore.closeSemaphoreHandle(io, self.signal_fd);
        semaphore.closeSemaphoreHandle(io, self.memory_fd);
        const native = self.native;
        native.procs.destroy_command_pool.?(native.vk_device, self.pool, null);
        native.procs.destroy_semaphore.?(native.vk_device, self.signal, null);
        native.procs.destroy_image.?(native.vk_device, self.image, null);
        native.procs.free_memory.?(native.vk_device, self.memory, null);
        native.handles.release(.command_buffer);
        native.handles.release(.command_pool);
        native.handles.release(.image);
        native.handles.release(.memory);
        self.* = undefined;
    }

    pub fn waitReturnedFence(self: *Producer, io: std.Io, fd: c_int) Error!void {
        const procs = self.native.procs;
        const destroy = procs.destroy_semaphore orelse return error.MissingDeviceProc;
        const reset = procs.reset_command_pool orelse return error.MissingDeviceProc;
        const begin = procs.begin_command_buffer orelse return error.MissingDeviceProc;
        const barrier = procs.cmd_pipeline_barrier orelse return error.MissingDeviceProc;
        const end = procs.end_command_buffer orelse return error.MissingDeviceProc;
        const returned = try self.semaphore_service.importSemaphore(io, fd);
        defer destroy(self.native.vk_device, returned, null);
        try dispatch.checkVkSuccess(reset(self.native.vk_device, self.pool, 0));
        const begin_info: vk.VkCommandBufferBeginInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try dispatch.checkVkSuccess(begin(self.command_buffer, &begin_info));
        const acquire: vk.VkImageMemoryBarrier = .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_MEMORY_READ_BIT | vk.VK_ACCESS_MEMORY_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_GENERAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_GENERAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_EXTERNAL,
            .dstQueueFamilyIndex = self.native.queue_family_index,
            .image = self.image,
            .subresourceRange = colorRange(),
        };
        barrier(self.command_buffer, vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, null, 0, null, 1, &acquire);
        try dispatch.checkVkSuccess(end(self.command_buffer));
        try self.submitAndWait(returned, null);
    }

    fn recordRelease(self: *Producer) Error!void {
        const procs = self.native.procs;
        const begin = procs.begin_command_buffer orelse return error.MissingDeviceProc;
        const barrier = procs.cmd_pipeline_barrier orelse return error.MissingDeviceProc;
        const clear = procs.cmd_clear_color_image orelse return error.MissingDeviceProc;
        const end = procs.end_command_buffer orelse return error.MissingDeviceProc;
        const begin_info: vk.VkCommandBufferBeginInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try dispatch.checkVkSuccess(begin(self.command_buffer, &begin_info));
        var transition: vk.VkImageMemoryBarrier = .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_GENERAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresourceRange = colorRange(),
        };
        barrier(self.command_buffer, vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &transition);
        const magenta: vk.VkClearColorValue = .{ .float32 = .{ 1, 0, 1, 1 } };
        const range = colorRange();
        clear(self.command_buffer, self.image, vk.VK_IMAGE_LAYOUT_GENERAL, &magenta, 1, &range);
        transition.srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
        transition.dstAccessMask = 0;
        transition.oldLayout = vk.VK_IMAGE_LAYOUT_GENERAL;
        transition.srcQueueFamilyIndex = self.native.queue_family_index;
        transition.dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_EXTERNAL;
        barrier(self.command_buffer, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 1, &transition);
        try dispatch.checkVkSuccess(end(self.command_buffer));
    }

    fn submitAndWait(self: *Producer, wait: vk.VkSemaphore, signal: vk.VkSemaphore) Error!void {
        const procs = self.native.procs;
        const create = procs.create_fence orelse return error.MissingDeviceProc;
        const destroy = procs.destroy_fence orelse return error.MissingDeviceProc;
        const submit = procs.queue_submit orelse return error.MissingDeviceProc;
        const wait_fence = procs.wait_for_fences orelse return error.MissingDeviceProc;
        const idle = procs.queue_wait_idle orelse return error.MissingDeviceProc;
        const fence_info: vk.VkFenceCreateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
        var fence: vk.VkFence = null;
        try dispatch.checkVkSuccess(create(self.native.vk_device, &fence_info, null, &fence));
        defer destroy(self.native.vk_device, fence, null);
        const commands = [1]vk.VkCommandBuffer{self.command_buffer};
        const waits = [1]vk.VkSemaphore{wait};
        const signals = [1]vk.VkSemaphore{signal};
        const stages = [1]vk.VkPipelineStageFlags{vk.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT};
        const submit_info: vk.VkSubmitInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = if (wait == null) 0 else 1,
            .pWaitSemaphores = if (wait == null) null else &waits,
            .pWaitDstStageMask = if (wait == null) null else &stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &commands,
            .signalSemaphoreCount = if (signal == null) 0 else 1,
            .pSignalSemaphores = if (signal == null) null else &signals,
        };
        try dispatch.checkVkSuccess(submit(self.queue, 1, &submit_info, fence));
        // A failed bounded wait must not free resources still referenced by the GPU.
        errdefer dispatch.checkVkSuccess(idle(self.queue)) catch @panic("producer queue wait failed");
        const fences = [1]vk.VkFence{fence};
        try dispatch.checkVkSuccess(wait_fence(
            self.native.vk_device,
            1,
            &fences,
            vk.VK_TRUE,
            30 * std.time.ns_per_s,
        ));
    }
};

fn imageInfo() vk.VkImageCreateInfo {
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_IMAGE_CREATE_ALIAS_BIT,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
        .extent = .{ .width = 4, .height = 4, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT |
            vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };
}

fn checkExternalImage(properties: vk.VkExternalMemoryProperties) Error!void {
    const required = vk.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT |
        vk.VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT;
    if ((properties.externalMemoryFeatures & required) != required)
        return error.UnsupportedExternalImage;
    if ((properties.compatibleHandleTypes & vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT) == 0)
        return error.UnsupportedExternalImage;
}

fn queryExternalImage(native: *engine.vulkan_device.Device, info: vk.VkImageCreateInfo) Error!void {
    const query = native.instance.procs.get_physical_device_image_format_properties2 orelse
        return error.MissingDeviceProc;
    var external: vk.VkPhysicalDeviceExternalImageFormatInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
        .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
    };
    const input: vk.VkPhysicalDeviceImageFormatInfo2 = .{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
        .pNext = &external,
        .format = info.format,
        .type = info.imageType,
        .tiling = info.tiling,
        .usage = info.usage,
        .flags = info.flags,
    };
    var external_properties: vk.VkExternalImageFormatProperties = .{
        .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
    };
    var output: vk.VkImageFormatProperties2 = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
        .pNext = &external_properties,
    };
    try dispatch.checkVkSuccess(query(native.physical.handle, &input, &output));
    try checkExternalImage(external_properties.externalMemoryProperties);
}

fn colorRange() vk.VkImageSubresourceRange {
    return .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
}

fn createPool(native: *engine.vulkan_device.Device) Error!struct {
    pool: vk.VkCommandPool,
    command_buffer: vk.VkCommandBuffer,
} {
    const create = native.procs.create_command_pool orelse return error.MissingDeviceProc;
    const destroy = native.procs.destroy_command_pool orelse return error.MissingDeviceProc;
    const allocate = native.procs.allocate_command_buffers orelse return error.MissingDeviceProc;
    const info: vk.VkCommandPoolCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = vk.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = native.queue_family_index,
    };
    var pool: vk.VkCommandPool = null;
    try dispatch.checkVkSuccess(create(native.vk_device, &info, null, &pool));
    errdefer destroy(native.vk_device, pool, null);
    const allocation: vk.VkCommandBufferAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    var command_buffer: vk.VkCommandBuffer = null;
    try dispatch.checkVkSuccess(allocate(native.vk_device, &allocation, &command_buffer));
    return .{ .pool = pool, .command_buffer = command_buffer };
}

fn closeOnInitError(fd: c_int) void {
    // init has no Io parameter. Its failure path still owns the exported descriptor.
    const result = std.os.linux.close(fd);
    std.debug.assert(std.os.linux.errno(result) == .SUCCESS);
}

fn dmaExportSupported(properties: vk.VkExternalMemoryProperties) bool {
    const required = vk.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT |
        vk.VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT;
    return properties.externalMemoryFeatures & required == required and
        properties.compatibleHandleTypes & vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT != 0;
}

fn selectDmaModifier(
    allocator: std.mem.Allocator,
    native: *engine.vulkan_device.Device,
) Error!vk.VkDrmFormatModifierPropertiesEXT {
    const query = native.instance.procs.get_physical_device_format_properties2 orelse
        return error.MissingDeviceProc;
    const required_features = vk.VK_FORMAT_FEATURE_TRANSFER_SRC_BIT |
        vk.VK_FORMAT_FEATURE_TRANSFER_DST_BIT | vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
        vk.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT;
    for (0..3) |_| {
        var list: vk.VkDrmFormatModifierPropertiesListEXT = .{
            .sType = vk.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
        };
        var properties: vk.VkFormatProperties2 = .{
            .sType = vk.VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
            .pNext = &list,
        };
        query(native.physical.handle, vk.VK_FORMAT_R8G8B8A8_UNORM, &properties);
        const count = list.drmFormatModifierCount;
        if (count == 0 or count > 4096) return error.UnsupportedDmaBuf;
        const modifiers = try allocator.alloc(vk.VkDrmFormatModifierPropertiesEXT, count);
        defer allocator.free(modifiers);
        list.pDrmFormatModifierProperties = modifiers.ptr;
        query(native.physical.handle, vk.VK_FORMAT_R8G8B8A8_UNORM, &properties);
        if (list.drmFormatModifierCount != count) continue;
        var recount: vk.VkDrmFormatModifierPropertiesListEXT = .{
            .sType = vk.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
        };
        properties.pNext = &recount;
        query(native.physical.handle, vk.VK_FORMAT_R8G8B8A8_UNORM, &properties);
        if (recount.drmFormatModifierCount != count) continue;
        for (modifiers) |modifier| {
            if (modifier.drmFormatModifierPlaneCount == 0 or
                modifier.drmFormatModifierPlaneCount > 4) continue;
            if (modifier.drmFormatModifierTilingFeatures & required_features != required_features)
                continue;
            if (try queryDmaModifier(native, modifier.drmFormatModifier)) return modifier;
        }
        return error.UnsupportedDmaBuf;
    }
    return error.ModifierPropertiesUnstable;
}

fn queryDmaModifier(native: *engine.vulkan_device.Device, modifier_value: u64) Error!bool {
    const query = native.instance.procs.get_physical_device_image_format_properties2 orelse
        return error.MissingDeviceProc;
    var modifier: vk.VkPhysicalDeviceImageDrmFormatModifierInfoEXT = .{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
        .drmFormatModifier = modifier_value,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
    };
    var external: vk.VkPhysicalDeviceExternalImageFormatInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
        .pNext = &modifier,
        .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    const base = imageInfo();
    const input: vk.VkPhysicalDeviceImageFormatInfo2 = .{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
        .pNext = &external,
        .format = base.format,
        .type = base.imageType,
        .tiling = vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = base.usage,
        .flags = base.flags,
    };
    var external_properties: vk.VkExternalImageFormatProperties = .{
        .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
    };
    var output: vk.VkImageFormatProperties2 = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
        .pNext = &external_properties,
    };
    const result = query(native.physical.handle, &input, &output);
    if (result == vk.VK_ERROR_FORMAT_NOT_SUPPORTED) return false;
    try dispatch.checkVkSuccess(result);
    if (output.imageFormatProperties.maxExtent.width < 4 or
        output.imageFormatProperties.maxExtent.height < 4 or
        output.imageFormatProperties.maxExtent.depth < 1) return false;
    return dmaExportSupported(external_properties.externalMemoryProperties);
}
