//! Generator for `src/vk/dispatch.zig`.
//!
//! **Reads.** Nothing at run time. The tables below are the transcription of
//! `src/dawn/native/vulkan/VulkanFunctions.h` at the Dawn revision
//! `docs/40-plan.md` pins, and of the load sites in
//! `src/dawn/native/vulkan/VulkanFunctions.cpp`. `docs/40-plan.md` §3.2 is the
//! transcription of record: one row per field, with the header line and the
//! load site. The Vulkan names come from the pinned Vulkan-Headers commit in
//! `build.zig.zon`, which `build.zig` translates into `src/vulkan.zig`
//! separately; this generator never reads a header.
//!
//! **Emits.** `src/vk/dispatch.zig`, the shape
//! `docs/30-port-design.md` §6.2 owns: `Dispatch`, the three tiers, the three
//! loaders, and the `VkResult` to Zig error mapping that `AGENTS.md` §3.1
//! keeps in this file.
//!
//! **Skipped, with the reason.** `docs/40-plan.md` §3.2 ports six fields that
//! cannot exist here. `vkCreateImagePipeSurfaceFUCHSIA` and
//! `vkCreateMetalSurfaceEXT` (`VulkanFunctions.h:161`, `:166`) need no Fuchsia
//! or Metal back end, and `AGENTS.md` §1 builds neither.
//! `vkGetMemoryZirconHandleFUCHSIA`,
//! `vkGetMemoryZirconHandlePropertiesFUCHSIA`,
//! `vkImportSemaphoreZirconHandleFUCHSIA` and
//! `vkGetSemaphoreZirconHandleFUCHSIA` (`VulkanFunctions.h:403`-`:409`) are the
//! Fuchsia external memory and semaphore service.
//!
//! Eleven more rows in that table cannot exist either, which is why the counts
//! differ from it. The pinned `vulkan_core.h` defines no `PFN_vk*` typedef for
//! a platform surface creator. `PFN_vkCreateWaylandSurfaceKHR`,
//! `PFN_vkGetPhysicalDeviceWaylandPresentationSupportKHR`,
//! `PFN_vkCreateWin32SurfaceKHR`,
//! `PFN_vkGetPhysicalDeviceWin32PresentationSupportKHR`,
//! `PFN_vkCreateAndroidSurfaceKHR`,
//! `PFN_vkGetAndroidHardwareBufferPropertiesANDROID`,
//! `PFN_vkGetMemoryAndroidHardwareBufferANDROID`, `PFN_vkCreateXlibSurfaceKHR`,
//! `PFN_vkGetPhysicalDeviceXlibPresentationSupportKHR`,
//! `PFN_vkCreateXcbSurfaceKHR` and
//! `PFN_vkGetPhysicalDeviceXcbPresentationSupportKHR` live in
//! `vulkan_wayland.h`, `vulkan_win32.h`, `vulkan_android.h`, `vulkan_xlib.h`
//! and `vulkan_xcb.h`, which `vulkan_core.h` reaches only behind
//! `VK_USE_PLATFORM_*` and which then need a platform SDK this project does
//! not vendor. `AGENTS.md` §6 takes a binding from `translate-c` or from a
//! hand-written shim with the reason named, and a hand-written function pointer
//! type is a second source of truth for a Vulkan ABI, so these rows wait for
//! the milestone that adds surfaces. `AGENTS.md` §5 already says the host is
//! headless and no test may require a surface.

const std = @import("std");

/// Writes the file to standard output. `build.zig` captures the bytes, and
/// `test/gen_dispatch_drift.zig` renders them a second time to compare them
/// with the checked-in file.
pub fn main(init: std.process.Init) std.Io.Writer.Error!void {
    var buffer: [4096]u8 = undefined;
    var stdout_buffer = std.Io.File.stdout().writer(init.io, &buffer);
    try render(&stdout_buffer.interface);
    try stdout_buffer.interface.flush();
}

/// Writes the whole file. The only entry point the drift test needs.
pub fn render(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try emitPreamble(writer);
    try emitDispatch(writer);
    try emitTier(writer, global_tier);
    try emitTier(writer, instance_tier);
    try emitTier(writer, device_tier);
    try emitLoadError(writer);
    try emitProcRow(writer);
    try emitExtension(writer, instance_ext);
    try emitExtension(writer, device_ext);
    try emitGlobalRows(writer);
    try emitInstanceRows(writer);
    try emitDeviceRows(writer);
    try emitInstanceGroups(writer);
    try emitDeviceGroups(writer);
    try emitAllRows(writer);
    try emitGlobalLoader(writer);
    try emitInstanceLoader(writer);
    try emitDeviceLoader(writer);
    try emitCasts(writer);
    try emitResult(writer);
    try emitComptimeChecks(writer);
    try emitTests(writer);
}

// ---------------------------------------------------------------------------
// The transcription
// ---------------------------------------------------------------------------

/// One Vulkan entry point: the dispatch field the loader fills, and the symbol
/// it looks up. The field name is the symbol without its `vk` prefix in
/// snake_case, which is the spelling `docs/40-plan.md` §3.2 uses for every one
/// of them and which the emitted file checks at comptime.
const ProcRow = struct {
    field: []const u8,
    symbol: [:0]const u8,
};

/// One `if (info.HasExt(...))` block. Dawn writes one per extension it gates a
/// proc on; the port keeps the gate as data so the loader can ask about it.
/// `doc` is the comment the block carries in the emitted file, and the emitted
/// struct run and the emitted group table both use it, so it is written once.
const Gate = struct {
    /// The `*Ext` member the loader tests.
    member: []const u8,
    /// The name the emitted row list carries.
    rows_name: []const u8,
    doc: []const []const u8,
    /// The rows inside the block.
    fields: []const ProcRow,
};

/// Dawn reads `vkGetInstanceProcAddr` out of the shared library itself
/// (`VulkanFunctions.cpp:92`); every other global proc goes through it with a
/// null instance (`GET_GLOBAL_PROC`, `:83`).
const global_lib_fields = [_]ProcRow{
    .{ .field = "get_instance_proc_addr", .symbol = "vkGetInstanceProcAddr" },
};

/// The three global procs Dawn makes a hard error over
/// (`VulkanFunctions.cpp:96`-`:98`).
const global_fields = [_]ProcRow{
    .{ .field = "create_instance", .symbol = "vkCreateInstance" },
    .{
        .field = "enumerate_instance_extension_properties",
        .symbol = "vkEnumerateInstanceExtensionProperties",
    },
    .{
        .field = "enumerate_instance_layer_properties",
        .symbol = "vkEnumerateInstanceLayerProperties",
    },
};

/// `vkEnumerateInstanceVersion` does not exist on Vulkan 1.0, so Dawn allows it
/// to be null (`VulkanFunctions.cpp:100`-`:102`).
const global_optional_fields = [_]ProcRow{
    .{ .field = "enumerate_instance_version", .symbol = "vkEnumerateInstanceVersion" },
};

/// `vkDestroyInstance` is loaded by `loadInstanceProcs` and first of all
/// (`VulkanFunctions.cpp:127`), yet lives in `GlobalProcs`
/// (`VulkanFunctions.h:89`-`:91`): the loader needs it to destroy an instance
/// whose other procs turned out to be missing.
const global_instance_fields = [_]ProcRow{
    .{ .field = "destroy_instance", .symbol = "vkDestroyInstance" },
};

/// The instance procs Dawn loads unconditionally
/// (`VulkanFunctions.cpp:129`-`:154`).
const instance_fields = [_]ProcRow{
    .{ .field = "create_device", .symbol = "vkCreateDevice" },
    .{
        .field = "enumerate_device_extension_properties",
        .symbol = "vkEnumerateDeviceExtensionProperties",
    },
    .{
        .field = "enumerate_device_layer_properties",
        .symbol = "vkEnumerateDeviceLayerProperties",
    },
    .{
        .field = "enumerate_physical_devices",
        .symbol = "vkEnumeratePhysicalDevices",
    },
    .{ .field = "get_device_proc_addr", .symbol = "vkGetDeviceProcAddr" },
    .{
        .field = "get_physical_device_features",
        .symbol = "vkGetPhysicalDeviceFeatures",
    },
    .{
        .field = "get_physical_device_format_properties",
        .symbol = "vkGetPhysicalDeviceFormatProperties",
    },
    .{
        .field = "get_physical_device_image_format_properties",
        .symbol = "vkGetPhysicalDeviceImageFormatProperties",
    },
    .{
        .field = "get_physical_device_memory_properties",
        .symbol = "vkGetPhysicalDeviceMemoryProperties",
    },
    .{
        .field = "get_physical_device_properties",
        .symbol = "vkGetPhysicalDeviceProperties",
    },
    .{
        .field = "get_physical_device_queue_family_properties",
        .symbol = "vkGetPhysicalDeviceQueueFamilyProperties",
    },
    .{
        .field = "get_physical_device_sparse_image_format_properties",
        .symbol = "vkGetPhysicalDeviceSparseImageFormatProperties",
    },
    .{ .field = "destroy_device", .symbol = "vkDestroyDevice" },
    .{
        .field = "enumerate_physical_device_groups",
        .symbol = "vkEnumeratePhysicalDeviceGroups",
    },
    .{
        .field = "get_physical_device_external_buffer_properties",
        .symbol = "vkGetPhysicalDeviceExternalBufferProperties",
    },
    .{
        .field = "get_physical_device_external_fence_properties",
        .symbol = "vkGetPhysicalDeviceExternalFenceProperties",
    },
    .{
        .field = "get_physical_device_external_semaphore_properties",
        .symbol = "vkGetPhysicalDeviceExternalSemaphoreProperties",
    },
    // Native capability discovery queries a Features2 chain. This is required
    // by the Vulkan 1.1 admission floor, not an optional extension proc.
    .{
        .field = "get_physical_device_features2",
        .symbol = "vkGetPhysicalDeviceFeatures2",
    },
    .{
        .field = "get_physical_device_format_properties2",
        .symbol = "vkGetPhysicalDeviceFormatProperties2",
    },
    .{
        .field = "get_physical_device_image_format_properties2",
        .symbol = "vkGetPhysicalDeviceImageFormatProperties2",
    },
    .{
        .field = "get_physical_device_memory_properties2",
        .symbol = "vkGetPhysicalDeviceMemoryProperties2",
    },
    .{
        .field = "get_physical_device_properties2",
        .symbol = "vkGetPhysicalDeviceProperties2",
    },
    .{
        .field = "get_physical_device_queue_family_properties2",
        .symbol = "vkGetPhysicalDeviceQueueFamilyProperties2",
    },
    .{
        .field = "get_physical_device_sparse_image_format_properties2",
        .symbol = "vkGetPhysicalDeviceSparseImageFormatProperties2",
    },
};

/// `VK_KHR_surface`, behind `if (globalInfo.HasExt(InstanceExt::Surface))`
/// (`VulkanFunctions.cpp:156`).
const instance_surface_fields = [_]ProcRow{
    .{ .field = "destroy_surface_khr", .symbol = "vkDestroySurfaceKHR" },
    .{
        .field = "get_physical_device_surface_support_khr",
        .symbol = "vkGetPhysicalDeviceSurfaceSupportKHR",
    },
    .{
        .field = "get_physical_device_surface_capabilities_khr",
        .symbol = "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
    },
    .{
        .field = "get_physical_device_surface_formats_khr",
        .symbol = "vkGetPhysicalDeviceSurfaceFormatsKHR",
    },
    .{
        .field = "get_physical_device_surface_present_modes_khr",
        .symbol = "vkGetPhysicalDeviceSurfacePresentModesKHR",
    },
};

/// `VK_EXT_debug_utils`. `TryLoadEXTDebugUtils` (`VulkanFunctions.cpp:219`)
/// tolerates a missing one and then zeroes all eleven, so a caller never sees
/// half a debug-utils table from a driver that advertises the extension and
/// does not expose it.
const instance_debug_utils_fields = [_]ProcRow{
    .{
        .field = "cmd_begin_debug_utils_label_ext",
        .symbol = "vkCmdBeginDebugUtilsLabelEXT",
    },
    .{
        .field = "cmd_end_debug_utils_label_ext",
        .symbol = "vkCmdEndDebugUtilsLabelEXT",
    },
    .{
        .field = "cmd_insert_debug_utils_label_ext",
        .symbol = "vkCmdInsertDebugUtilsLabelEXT",
    },
    .{
        .field = "create_debug_utils_messenger_ext",
        .symbol = "vkCreateDebugUtilsMessengerEXT",
    },
    .{
        .field = "destroy_debug_utils_messenger_ext",
        .symbol = "vkDestroyDebugUtilsMessengerEXT",
    },
    .{
        .field = "queue_begin_debug_utils_label_ext",
        .symbol = "vkQueueBeginDebugUtilsLabelEXT",
    },
    .{
        .field = "queue_end_debug_utils_label_ext",
        .symbol = "vkQueueEndDebugUtilsLabelEXT",
    },
    .{
        .field = "queue_insert_debug_utils_label_ext",
        .symbol = "vkQueueInsertDebugUtilsLabelEXT",
    },
    .{
        .field = "set_debug_utils_object_name_ext",
        .symbol = "vkSetDebugUtilsObjectNameEXT",
    },
    .{
        .field = "set_debug_utils_object_tag_ext",
        .symbol = "vkSetDebugUtilsObjectTagEXT",
    },
    .{
        .field = "submit_debug_utils_message_ext",
        .symbol = "vkSubmitDebugUtilsMessageEXT",
    },
};

/// `VK_KHR_cooperative_matrix` (`VulkanFunctions.cpp:207`-`:214`): a device
/// that exposes an instance proc, so it is loaded with the tolerated-missing
/// rule because the device is not known yet.
const instance_optional_fields = [_]ProcRow{
    .{
        .field = "get_physical_device_cooperative_matrix_properties_khr",
        .symbol = "vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR",
    },
};

/// The device procs Dawn loads unconditionally
/// (`VulkanFunctions.cpp:266`-`:402`).
const device_fields = [_]ProcRow{
    .{ .field = "allocate_command_buffers", .symbol = "vkAllocateCommandBuffers" },
    .{ .field = "allocate_descriptor_sets", .symbol = "vkAllocateDescriptorSets" },
    .{ .field = "allocate_memory", .symbol = "vkAllocateMemory" },
    .{ .field = "begin_command_buffer", .symbol = "vkBeginCommandBuffer" },
    .{ .field = "bind_buffer_memory", .symbol = "vkBindBufferMemory" },
    .{ .field = "bind_image_memory", .symbol = "vkBindImageMemory" },
    .{ .field = "cmd_begin_query", .symbol = "vkCmdBeginQuery" },
    .{ .field = "cmd_begin_render_pass", .symbol = "vkCmdBeginRenderPass" },
    .{ .field = "cmd_bind_descriptor_sets", .symbol = "vkCmdBindDescriptorSets" },
    .{ .field = "cmd_bind_index_buffer", .symbol = "vkCmdBindIndexBuffer" },
    .{ .field = "cmd_bind_pipeline", .symbol = "vkCmdBindPipeline" },
    .{ .field = "cmd_bind_vertex_buffers", .symbol = "vkCmdBindVertexBuffers" },
    .{ .field = "cmd_blit_image", .symbol = "vkCmdBlitImage" },
    .{ .field = "cmd_clear_attachments", .symbol = "vkCmdClearAttachments" },
    .{ .field = "cmd_clear_color_image", .symbol = "vkCmdClearColorImage" },
    .{
        .field = "cmd_clear_depth_stencil_image",
        .symbol = "vkCmdClearDepthStencilImage",
    },
    .{ .field = "cmd_copy_buffer", .symbol = "vkCmdCopyBuffer" },
    .{ .field = "cmd_copy_buffer_to_image", .symbol = "vkCmdCopyBufferToImage" },
    .{ .field = "cmd_copy_image", .symbol = "vkCmdCopyImage" },
    .{ .field = "cmd_copy_image_to_buffer", .symbol = "vkCmdCopyImageToBuffer" },
    .{
        .field = "cmd_copy_query_pool_results",
        .symbol = "vkCmdCopyQueryPoolResults",
    },
    .{ .field = "cmd_dispatch", .symbol = "vkCmdDispatch" },
    .{ .field = "cmd_dispatch_indirect", .symbol = "vkCmdDispatchIndirect" },
    .{ .field = "cmd_draw", .symbol = "vkCmdDraw" },
    .{ .field = "cmd_draw_indexed", .symbol = "vkCmdDrawIndexed" },
    .{ .field = "cmd_draw_indexed_indirect", .symbol = "vkCmdDrawIndexedIndirect" },
    .{ .field = "cmd_draw_indirect", .symbol = "vkCmdDrawIndirect" },
    .{ .field = "cmd_end_query", .symbol = "vkCmdEndQuery" },
    .{ .field = "cmd_end_render_pass", .symbol = "vkCmdEndRenderPass" },
    .{ .field = "cmd_execute_commands", .symbol = "vkCmdExecuteCommands" },
    .{ .field = "cmd_fill_buffer", .symbol = "vkCmdFillBuffer" },
    .{ .field = "cmd_next_subpass", .symbol = "vkCmdNextSubpass" },
    .{ .field = "cmd_pipeline_barrier", .symbol = "vkCmdPipelineBarrier" },
    .{ .field = "cmd_push_constants", .symbol = "vkCmdPushConstants" },
    .{ .field = "cmd_reset_event", .symbol = "vkCmdResetEvent" },
    .{ .field = "cmd_reset_query_pool", .symbol = "vkCmdResetQueryPool" },
    .{ .field = "cmd_resolve_image", .symbol = "vkCmdResolveImage" },
    .{ .field = "cmd_set_blend_constants", .symbol = "vkCmdSetBlendConstants" },
    .{ .field = "cmd_set_depth_bias", .symbol = "vkCmdSetDepthBias" },
    .{ .field = "cmd_set_depth_bounds", .symbol = "vkCmdSetDepthBounds" },
    .{ .field = "cmd_set_event", .symbol = "vkCmdSetEvent" },
    .{ .field = "cmd_set_line_width", .symbol = "vkCmdSetLineWidth" },
    .{ .field = "cmd_set_scissor", .symbol = "vkCmdSetScissor" },
    .{
        .field = "cmd_set_stencil_compare_mask",
        .symbol = "vkCmdSetStencilCompareMask",
    },
    .{ .field = "cmd_set_stencil_reference", .symbol = "vkCmdSetStencilReference" },
    .{ .field = "cmd_set_stencil_write_mask", .symbol = "vkCmdSetStencilWriteMask" },
    .{ .field = "cmd_set_viewport", .symbol = "vkCmdSetViewport" },
    .{ .field = "cmd_update_buffer", .symbol = "vkCmdUpdateBuffer" },
    .{ .field = "cmd_wait_events", .symbol = "vkCmdWaitEvents" },
    .{ .field = "cmd_write_timestamp", .symbol = "vkCmdWriteTimestamp" },
    .{ .field = "create_buffer", .symbol = "vkCreateBuffer" },
    .{ .field = "create_buffer_view", .symbol = "vkCreateBufferView" },
    .{ .field = "create_command_pool", .symbol = "vkCreateCommandPool" },
    .{ .field = "create_compute_pipelines", .symbol = "vkCreateComputePipelines" },
    .{ .field = "create_descriptor_pool", .symbol = "vkCreateDescriptorPool" },
    .{
        .field = "create_descriptor_set_layout",
        .symbol = "vkCreateDescriptorSetLayout",
    },
    .{ .field = "create_event", .symbol = "vkCreateEvent" },
    .{ .field = "create_fence", .symbol = "vkCreateFence" },
    .{ .field = "create_framebuffer", .symbol = "vkCreateFramebuffer" },
    .{ .field = "create_graphics_pipelines", .symbol = "vkCreateGraphicsPipelines" },
    .{ .field = "create_image", .symbol = "vkCreateImage" },
    .{ .field = "create_image_view", .symbol = "vkCreateImageView" },
    .{ .field = "create_pipeline_cache", .symbol = "vkCreatePipelineCache" },
    .{ .field = "create_pipeline_layout", .symbol = "vkCreatePipelineLayout" },
    .{ .field = "create_query_pool", .symbol = "vkCreateQueryPool" },
    .{ .field = "create_render_pass", .symbol = "vkCreateRenderPass" },
    .{ .field = "create_sampler", .symbol = "vkCreateSampler" },
    .{ .field = "create_semaphore", .symbol = "vkCreateSemaphore" },
    .{ .field = "create_shader_module", .symbol = "vkCreateShaderModule" },
    .{ .field = "destroy_buffer", .symbol = "vkDestroyBuffer" },
    .{ .field = "destroy_buffer_view", .symbol = "vkDestroyBufferView" },
    .{ .field = "destroy_command_pool", .symbol = "vkDestroyCommandPool" },
    .{ .field = "destroy_descriptor_pool", .symbol = "vkDestroyDescriptorPool" },
    .{
        .field = "destroy_descriptor_set_layout",
        .symbol = "vkDestroyDescriptorSetLayout",
    },
    .{ .field = "destroy_event", .symbol = "vkDestroyEvent" },
    .{ .field = "destroy_fence", .symbol = "vkDestroyFence" },
    .{ .field = "destroy_framebuffer", .symbol = "vkDestroyFramebuffer" },
    .{ .field = "destroy_image", .symbol = "vkDestroyImage" },
    .{ .field = "destroy_image_view", .symbol = "vkDestroyImageView" },
    .{ .field = "destroy_pipeline", .symbol = "vkDestroyPipeline" },
    .{ .field = "destroy_pipeline_cache", .symbol = "vkDestroyPipelineCache" },
    .{ .field = "destroy_pipeline_layout", .symbol = "vkDestroyPipelineLayout" },
    .{ .field = "destroy_query_pool", .symbol = "vkDestroyQueryPool" },
    .{ .field = "destroy_render_pass", .symbol = "vkDestroyRenderPass" },
    .{ .field = "destroy_sampler", .symbol = "vkDestroySampler" },
    .{ .field = "destroy_semaphore", .symbol = "vkDestroySemaphore" },
    .{ .field = "destroy_shader_module", .symbol = "vkDestroyShaderModule" },
    .{ .field = "device_wait_idle", .symbol = "vkDeviceWaitIdle" },
    .{ .field = "end_command_buffer", .symbol = "vkEndCommandBuffer" },
    .{ .field = "flush_mapped_memory_ranges", .symbol = "vkFlushMappedMemoryRanges" },
    .{ .field = "free_command_buffers", .symbol = "vkFreeCommandBuffers" },
    .{ .field = "free_descriptor_sets", .symbol = "vkFreeDescriptorSets" },
    .{ .field = "free_memory", .symbol = "vkFreeMemory" },
    .{
        .field = "get_buffer_memory_requirements",
        .symbol = "vkGetBufferMemoryRequirements",
    },
    .{
        .field = "get_device_memory_commitment",
        .symbol = "vkGetDeviceMemoryCommitment",
    },
    .{ .field = "get_device_queue", .symbol = "vkGetDeviceQueue" },
    .{ .field = "get_event_status", .symbol = "vkGetEventStatus" },
    .{ .field = "get_fence_status", .symbol = "vkGetFenceStatus" },
    .{
        .field = "get_image_memory_requirements",
        .symbol = "vkGetImageMemoryRequirements",
    },
    .{
        .field = "get_image_sparse_memory_requirements",
        .symbol = "vkGetImageSparseMemoryRequirements",
    },
    .{
        .field = "get_image_subresource_layout",
        .symbol = "vkGetImageSubresourceLayout",
    },
    .{ .field = "get_pipeline_cache_data", .symbol = "vkGetPipelineCacheData" },
    .{ .field = "get_query_pool_results", .symbol = "vkGetQueryPoolResults" },
    .{
        .field = "get_render_area_granularity",
        .symbol = "vkGetRenderAreaGranularity",
    },
    .{
        .field = "invalidate_mapped_memory_ranges",
        .symbol = "vkInvalidateMappedMemoryRanges",
    },
    .{ .field = "map_memory", .symbol = "vkMapMemory" },
    .{ .field = "merge_pipeline_caches", .symbol = "vkMergePipelineCaches" },
    .{ .field = "queue_bind_sparse", .symbol = "vkQueueBindSparse" },
    .{ .field = "queue_submit", .symbol = "vkQueueSubmit" },
    .{ .field = "queue_wait_idle", .symbol = "vkQueueWaitIdle" },
    .{ .field = "reset_command_buffer", .symbol = "vkResetCommandBuffer" },
    .{ .field = "reset_command_pool", .symbol = "vkResetCommandPool" },
    .{ .field = "reset_descriptor_pool", .symbol = "vkResetDescriptorPool" },
    .{ .field = "reset_event", .symbol = "vkResetEvent" },
    .{ .field = "reset_fences", .symbol = "vkResetFences" },
    .{ .field = "set_event", .symbol = "vkSetEvent" },
    .{ .field = "unmap_memory", .symbol = "vkUnmapMemory" },
    .{ .field = "update_descriptor_sets", .symbol = "vkUpdateDescriptorSets" },
    .{ .field = "wait_for_fences", .symbol = "vkWaitForFences" },
    .{ .field = "bind_buffer_memory2", .symbol = "vkBindBufferMemory2" },
    .{ .field = "bind_image_memory2", .symbol = "vkBindImageMemory2" },
    .{ .field = "cmd_dispatch_base", .symbol = "vkCmdDispatchBase" },
    .{ .field = "cmd_set_device_mask", .symbol = "vkCmdSetDeviceMask" },
    .{
        .field = "create_descriptor_update_template",
        .symbol = "vkCreateDescriptorUpdateTemplate",
    },
    .{
        .field = "create_sampler_ycbcr_conversion",
        .symbol = "vkCreateSamplerYcbcrConversion",
    },
    .{
        .field = "destroy_descriptor_update_template",
        .symbol = "vkDestroyDescriptorUpdateTemplate",
    },
    .{
        .field = "destroy_sampler_ycbcr_conversion",
        .symbol = "vkDestroySamplerYcbcrConversion",
    },
    .{
        .field = "get_buffer_memory_requirements2",
        .symbol = "vkGetBufferMemoryRequirements2",
    },
    .{
        .field = "get_descriptor_set_layout_support",
        .symbol = "vkGetDescriptorSetLayoutSupport",
    },
    .{
        .field = "get_device_group_peer_memory_features",
        .symbol = "vkGetDeviceGroupPeerMemoryFeatures",
    },
    .{ .field = "get_device_queue2", .symbol = "vkGetDeviceQueue2" },
    .{
        .field = "get_image_memory_requirements2",
        .symbol = "vkGetImageMemoryRequirements2",
    },
    .{
        .field = "get_image_sparse_memory_requirements2",
        .symbol = "vkGetImageSparseMemoryRequirements2",
    },
    .{ .field = "trim_command_pool", .symbol = "vkTrimCommandPool" },
    .{
        .field = "update_descriptor_set_with_template",
        .symbol = "vkUpdateDescriptorSetWithTemplate",
    },
};

/// `VK_KHR_draw_indirect_count`, behind `if (deviceInfo.HasExt(DeviceExt.draw_indirect_count))`
/// (`VulkanFunctions.cpp:405`).
const device_draw_indirect_count_fields = [_]ProcRow{
    .{
        .field = "cmd_draw_indirect_count_khr",
        .symbol = "vkCmdDrawIndirectCountKHR",
    },
    .{
        .field = "cmd_draw_indexed_indirect_count_khr",
        .symbol = "vkCmdDrawIndexedIndirectCountKHR",
    },
};

/// `VK_KHR_create_renderpass2`, behind `if (deviceInfo.HasExt(DeviceExt.create_renderpass2))`
/// (`VulkanFunctions.cpp:410`).
const device_create_renderpass2_fields = [_]ProcRow{
    .{ .field = "create_render_pass2_khr", .symbol = "vkCreateRenderPass2KHR" },
};

/// `VK_KHR_dynamic_rendering`, behind `if (deviceInfo.HasExt(DeviceExt.dynamic_rendering))`
/// (`VulkanFunctions.cpp:415`).
const device_dynamic_rendering_fields = [_]ProcRow{
    .{ .field = "cmd_begin_rendering_khr", .symbol = "vkCmdBeginRenderingKHR" },
    .{ .field = "cmd_end_rendering_khr", .symbol = "vkCmdEndRenderingKHR" },
};

/// `VK_EXT_extended_dynamic_state`, behind `if (deviceInfo.HasExt(DeviceExt.extended_dynamic_state))`
/// (`VulkanFunctions.cpp:420`).
const device_extended_dynamic_state_fields = [_]ProcRow{
    .{ .field = "cmd_set_cull_mode_ext", .symbol = "vkCmdSetCullModeEXT" },
    .{
        .field = "cmd_set_depth_compare_op_ext",
        .symbol = "vkCmdSetDepthCompareOpEXT",
    },
    .{
        .field = "cmd_set_depth_test_enable_ext",
        .symbol = "vkCmdSetDepthTestEnableEXT",
    },
    .{
        .field = "cmd_set_depth_write_enable_ext",
        .symbol = "vkCmdSetDepthWriteEnableEXT",
    },
    .{ .field = "cmd_set_front_face_ext", .symbol = "vkCmdSetFrontFaceEXT" },
    .{
        .field = "cmd_set_primitive_topology_ext",
        .symbol = "vkCmdSetPrimitiveTopologyEXT",
    },
    .{ .field = "cmd_set_stencil_op_ext", .symbol = "vkCmdSetStencilOpEXT" },
    .{
        .field = "cmd_set_stencil_test_enable_ext",
        .symbol = "vkCmdSetStencilTestEnableEXT",
    },
};

/// `VK_KHR_external_memory_fd`, behind `if (deviceInfo.HasExt(DeviceExt.external_memory_fd))`
/// (`VulkanFunctions.cpp:432`).
const device_external_memory_fd_fields = [_]ProcRow{
    .{ .field = "get_memory_fd_khr", .symbol = "vkGetMemoryFdKHR" },
    .{
        .field = "get_memory_fd_properties_khr",
        .symbol = "vkGetMemoryFdPropertiesKHR",
    },
};

/// `VK_EXT_external_memory_host`, behind `if (deviceInfo.HasExt(DeviceExt.external_memory_host))`
/// (`VulkanFunctions.cpp:437`).
const device_external_memory_host_fields = [_]ProcRow{
    .{
        .field = "get_memory_host_pointer_properties_ext",
        .symbol = "vkGetMemoryHostPointerPropertiesEXT",
    },
};

/// `VK_KHR_external_semaphore_fd`, behind `if (deviceInfo.HasExt(DeviceExt.external_semaphore_fd))`
/// (`VulkanFunctions.cpp:441`).
const device_external_semaphore_fd_fields = [_]ProcRow{
    .{ .field = "import_semaphore_fd_khr", .symbol = "vkImportSemaphoreFdKHR" },
    .{ .field = "get_semaphore_fd_khr", .symbol = "vkGetSemaphoreFdKHR" },
};

/// `VK_KHR_swapchain`, behind `if (deviceInfo.HasExt(DeviceExt.swapchain))`
/// (`VulkanFunctions.cpp:446`).
const device_swapchain_fields = [_]ProcRow{
    .{ .field = "create_swapchain_khr", .symbol = "vkCreateSwapchainKHR" },
    .{ .field = "destroy_swapchain_khr", .symbol = "vkDestroySwapchainKHR" },
    .{ .field = "get_swapchain_images_khr", .symbol = "vkGetSwapchainImagesKHR" },
    .{ .field = "acquire_next_image_khr", .symbol = "vkAcquireNextImageKHR" },
    .{ .field = "queue_present_khr", .symbol = "vkQueuePresentKHR" },
};

/// One `if (deviceInfo.HasExt(...))` block per device extension Dawn gates a
/// proc on. Transcribed from `DeviceExt` at `VulkanExtensions.h:79`.
const device_gates = [_]Gate{
    .{
        .member = "draw_indirect_count",
        .rows_name = "device_draw_indirect_count_fields",
        .doc = &.{
            "`VK_KHR_draw_indirect_count` (`VulkanFunctions.h:356`-`:360`), filled",
            "only when the extension is in the caller's set. Dawn opens the",
            "block at `VulkanFunctions.cpp:405`.",
        },
        .fields = &device_draw_indirect_count_fields,
    },
    .{
        .member = "create_renderpass2",
        .rows_name = "device_create_renderpass2_fields",
        .doc = &.{
            "`VK_KHR_create_renderpass2` (`VulkanFunctions.h:362`-`:363`), filled",
            "only when the extension is in the caller's set. Dawn opens the",
            "block at `VulkanFunctions.cpp:410`.",
        },
        .fields = &device_create_renderpass2_fields,
    },
    .{
        .member = "dynamic_rendering",
        .rows_name = "device_dynamic_rendering_fields",
        .doc = &.{
            "`VK_KHR_dynamic_rendering` (`VulkanFunctions.h:367`-`:369`), filled",
            "only when the extension is in the caller's set. Dawn opens the",
            "block at `VulkanFunctions.cpp:415`.",
        },
        .fields = &device_dynamic_rendering_fields,
    },
    .{
        .member = "extended_dynamic_state",
        .rows_name = "device_extended_dynamic_state_fields",
        .doc = &.{
            "`VK_EXT_extended_dynamic_state` (`VulkanFunctions.h:371`-`:379`),",
            "filled only when the extension is in the caller's set. Dawn opens",
            "the block at `VulkanFunctions.cpp:420`.",
        },
        .fields = &device_extended_dynamic_state_fields,
    },
    .{
        .member = "external_memory_fd",
        .rows_name = "device_external_memory_fd_fields",
        .doc = &.{
            "`VK_KHR_external_memory_fd` (`VulkanFunctions.h:383`-`:385`), filled",
            "only when the extension is in the caller's set. Dawn opens the",
            "block at `VulkanFunctions.cpp:432`.",
        },
        .fields = &device_external_memory_fd_fields,
    },
    .{
        .member = "external_memory_host",
        .rows_name = "device_external_memory_host_fields",
        .doc = &.{
            "`VK_EXT_external_memory_host` (`VulkanFunctions.h:387`-`:388`), filled",
            "only when the extension is in the caller's set. Dawn opens the",
            "block at `VulkanFunctions.cpp:437`.",
        },
        .fields = &device_external_memory_host_fields,
    },
    .{
        .member = "external_semaphore_fd",
        .rows_name = "device_external_semaphore_fd_fields",
        .doc = &.{
            "`VK_KHR_external_semaphore_fd` (`VulkanFunctions.h:390`-`:392`), filled",
            "only when the extension is in the caller's set. Dawn opens the",
            "block at `VulkanFunctions.cpp:441`.",
        },
        .fields = &device_external_semaphore_fd_fields,
    },
    .{
        .member = "swapchain",
        .rows_name = "device_swapchain_fields",
        .doc = &.{
            "`VK_KHR_swapchain` (`VulkanFunctions.h:394`-`:399`), filled only when",
            "the extension is in the caller's set. Dawn opens the block at",
            "`VulkanFunctions.cpp:446`.",
        },
        .fields = &device_swapchain_fields,
    },
};

/// The one `if (globalInfo.HasExt(...))` block in `LoadInstanceProcs`. Dawn has
/// one instance gate; the eleven platform surface creators behind the same kind
/// of gate are skipped, because the pinned header declares no type for them.
const instance_gates = [_]Gate{
    .{
        .member = "surface",
        .rows_name = "instance_surface_fields",
        .doc = &.{
            "`VK_KHR_surface` (`VulkanFunctions.h:150`-`:157`), filled only when",
            "the extension is in the caller's set. Dawn opens the block at",
            "`VulkanFunctions.cpp:156`.",
        },
        .fields = &instance_surface_fields,
    },
};

/// One contiguous run of fields in an emitted struct, with the upstream lines
/// it comes from.
const FieldRun = struct {
    doc: []const []const u8,
    fields: []const ProcRow,
};

/// One emitted tier struct.
const Tier = struct {
    name: []const u8,
    doc: []const []const u8,
    runs: []const FieldRun,
};

const global_tier: Tier = .{
    .name = "GlobalProcs",
    .doc = &.{
        "The procs the loader needs before an instance exists",
        "(`VulkanFunctions.h:81`-`:94`).",
        "",
        "`destroy_instance` lives here rather than in `InstanceProcs` because a",
        "failed instance creation still has to be undone, and `loadInstanceProcs`",
        "is where the instance handle first exists.",
    },
    .runs = &.{
        .{
            .doc = &.{
                "The proc every other proc is reached through, and the three the",
                "loader makes a hard error over (`VulkanFunctions.h:83`-`:88`,",
                "`VulkanFunctions.cpp:92`-`:98`).",
            },
            .fields = &(global_lib_fields ++ global_fields),
        },
        .{
            .doc = &.{
                "Loaded first by `loadInstanceProcs`",
                "(`VulkanFunctions.cpp:125`-`:127`).",
            },
            .fields = &global_instance_fields,
        },
        .{
            .doc = &.{
                "Vulkan 1.1 only (`VulkanFunctions.h:93`-`:94`), so a null field",
                "here is not a loader failure.",
            },
            .fields = &global_optional_fields,
        },
    },
};

const instance_tier: Tier = .{
    .name = "InstanceProcs",
    .doc = &.{
        "The procs reached with a `VkInstance` (`VulkanFunctions.h:96`-`:210`).",
        "",
        "Every field is filled by `loadInstanceProcs`. The two Android",
        "hardware-buffer fields, which Dawn groups with the instance tier and",
        "loads with the device tier, are skipped: the pinned `vulkan_core.h`",
        "declares no `PFN_vk*` typedef for either.",
    },
    .runs = &.{
        .{
            .doc = &.{
                "Core Vulkan 1.0, and what Vulkan 1.1 promoted",
                "(`VulkanFunctions.h:98`-`:135`, `VulkanFunctions.cpp:129`-`:154`).",
            },
            .fields = &instance_fields,
        },
        .{
            .doc = &.{
                "`VK_EXT_debug_utils` (`VulkanFunctions.h:137`-`:148`). All",
                "eleven are filled, or all eleven stay null.",
            },
            .fields = &instance_debug_utils_fields,
        },
        .{
            .doc = &.{
                "`VK_KHR_surface` (`VulkanFunctions.h:150`-`:157`). Filled only",
                "when the extension is in the caller's set.",
            },
            .fields = &instance_surface_fields,
        },
        .{
            .doc = &.{
                "`VK_KHR_cooperative_matrix` (`VulkanFunctions.h:206`-`:210`), a",
                "device extension reached with an instance proc, so a null field",
                "here is not a loader failure.",
            },
            .fields = &instance_optional_fields,
        },
    },
};

/// `DeviceProcs` has one run per gated block, and each takes its comment from
/// the gate so the block is described once.
const device_tier: Tier = .{
    .name = "DeviceProcs",
    .doc = &.{
        "The procs reached with a `VkDevice` (`VulkanFunctions.h:212`-`:409`).",
        "",
        "`loadDeviceProcs` fills a field whose extension the caller enabled, and",
        "a field whose extension it did not stays null.",
    },
    .runs = &.{
        .{
            .doc = &.{
                "Core Vulkan 1.0, and what Vulkan 1.1 promoted",
                "(`VulkanFunctions.h:214`-`:351`, `VulkanFunctions.cpp:266`-`:402`).",
            },
            .fields = &device_fields,
        },
        .{ .doc = device_gates[0].doc, .fields = device_gates[0].fields },
        .{ .doc = device_gates[1].doc, .fields = device_gates[1].fields },
        .{ .doc = device_gates[2].doc, .fields = device_gates[2].fields },
        .{ .doc = device_gates[3].doc, .fields = device_gates[3].fields },
        .{ .doc = device_gates[4].doc, .fields = device_gates[4].fields },
        .{ .doc = device_gates[5].doc, .fields = device_gates[5].fields },
        .{ .doc = device_gates[6].doc, .fields = device_gates[6].fields },
        .{ .doc = device_gates[7].doc, .fields = device_gates[7].fields },
    },
};

/// One `VkResult` code and what `classify` makes of it. A code is either a
/// value the caller must branch on (`value`) or a failure (`error_member`);
/// which one is the point of `docs/30-port-design.md` §5.2.
const ResultRow = struct {
    code: []const u8,
    name: []const u8,
    value: ?[]const u8 = null,
    /// Not named `error`: `error` is a keyword where a field name goes in Zig
    /// 0.16, so a field of that name cannot be declared at all. The emitted
    /// `Outcome` field carries the name the document uses, escaped:
    /// `@"error"`.
    error_member: ?[]const u8 = null,
};

const result_rows = [_]ResultRow{
    .{ .code = "vulkan.VK_SUCCESS", .value = "success", .name = "VK_SUCCESS" },
    .{
        .code = "vulkan.VK_NOT_READY",
        .value = "not_ready",
        .name = "VK_NOT_READY",
    },
    .{ .code = "vulkan.VK_TIMEOUT", .value = "timeout", .name = "VK_TIMEOUT" },
    .{
        .code = "vulkan.VK_EVENT_SET",
        .value = "event_set",
        .name = "VK_EVENT_SET",
    },
    .{
        .code = "vulkan.VK_EVENT_RESET",
        .value = "event_reset",
        .name = "VK_EVENT_RESET",
    },
    .{
        .code = "vulkan.VK_INCOMPLETE",
        .value = "incomplete",
        .name = "VK_INCOMPLETE",
    },
    .{
        .code = "vulkan.VK_SUBOPTIMAL_KHR",
        .value = "suboptimal",
        .name = "VK_SUBOPTIMAL_KHR",
    },
    .{
        .code = "vulkan.VK_PIPELINE_COMPILE_REQUIRED",
        .value = "pipeline_compile_required",
        .name = "VK_PIPELINE_COMPILE_REQUIRED",
    },
    .{
        .code = "vulkan.VK_ERROR_OUT_OF_HOST_MEMORY",
        .error_member = "OutOfHostMemory",
        .name = "VK_ERROR_OUT_OF_HOST_MEMORY",
    },
    .{
        .code = "vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY",
        .error_member = "OutOfDeviceMemory",
        .name = "VK_ERROR_OUT_OF_DEVICE_MEMORY",
    },
    .{
        .code = "vulkan.VK_ERROR_INITIALIZATION_FAILED",
        .error_member = "InitializationFailed",
        .name = "VK_ERROR_INITIALIZATION_FAILED",
    },
    .{
        .code = "vulkan.VK_ERROR_DEVICE_LOST",
        .error_member = "DeviceLost",
        .name = "VK_ERROR_DEVICE_LOST",
    },
    .{
        .code = "vulkan.VK_ERROR_MEMORY_MAP_FAILED",
        .error_member = "MemoryMapFailed",
        .name = "VK_ERROR_MEMORY_MAP_FAILED",
    },
    .{
        .code = "vulkan.VK_ERROR_LAYER_NOT_PRESENT",
        .error_member = "LayerNotPresent",
        .name = "VK_ERROR_LAYER_NOT_PRESENT",
    },
    .{
        .code = "vulkan.VK_ERROR_EXTENSION_NOT_PRESENT",
        .error_member = "ExtensionNotPresent",
        .name = "VK_ERROR_EXTENSION_NOT_PRESENT",
    },
    .{
        .code = "vulkan.VK_ERROR_FEATURE_NOT_PRESENT",
        .error_member = "FeatureNotPresent",
        .name = "VK_ERROR_FEATURE_NOT_PRESENT",
    },
    .{
        .code = "vulkan.VK_ERROR_INCOMPATIBLE_DRIVER",
        .error_member = "IncompatibleDriver",
        .name = "VK_ERROR_INCOMPATIBLE_DRIVER",
    },
    .{
        .code = "vulkan.VK_ERROR_TOO_MANY_OBJECTS",
        .error_member = "TooManyObjects",
        .name = "VK_ERROR_TOO_MANY_OBJECTS",
    },
    .{
        .code = "vulkan.VK_ERROR_FORMAT_NOT_SUPPORTED",
        .error_member = "FormatNotSupported",
        .name = "VK_ERROR_FORMAT_NOT_SUPPORTED",
    },
    .{
        .code = "vulkan.VK_ERROR_FRAGMENTED_POOL",
        .error_member = "FragmentedPool",
        .name = "VK_ERROR_FRAGMENTED_POOL",
    },
    .{
        .code = "vulkan.VK_ERROR_UNKNOWN",
        .error_member = "Unknown",
        .name = "VK_ERROR_UNKNOWN",
    },
    .{
        .code = "vulkan.VK_ERROR_SURFACE_LOST_KHR",
        .error_member = "SurfaceLost",
        .name = "VK_ERROR_SURFACE_LOST_KHR",
    },
    .{
        .code = "vulkan.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR",
        .error_member = "NativeWindowInUse",
        .name = "VK_ERROR_NATIVE_WINDOW_IN_USE_KHR",
    },
    .{
        .code = "vulkan.VK_ERROR_OUT_OF_DATE_KHR",
        .error_member = "OutOfDate",
        .name = "VK_ERROR_OUT_OF_DATE_KHR",
    },
    .{
        .code = "vulkan.VK_ERROR_VALIDATION_FAILED",
        .error_member = "ValidationFailed",
        .name = "VK_ERROR_VALIDATION_FAILED",
    },
    .{
        .code = "vulkan.VK_ERROR_FRAGMENTATION",
        .error_member = "Unknown",
        .name = "VK_ERROR_FRAGMENTATION",
    },
    .{
        .code = "vulkan.VK_ERROR_NOT_PERMITTED",
        .error_member = "Unknown",
        .name = "VK_ERROR_NOT_PERMITTED",
    },
    .{
        .code = "vulkan.VK_ERROR_COMPRESSION_EXHAUSTED_EXT",
        .error_member = "Unknown",
        .name = "VK_ERROR_COMPRESSION_EXHAUSTED_EXT",
    },
    .{
        .code = "vulkan.VK_ERROR_INVALID_EXTERNAL_HANDLE",
        .error_member = "Unknown",
        .name = "VK_ERROR_INVALID_EXTERNAL_HANDLE",
    },
    .{
        .code = "vulkan.VK_ERROR_OUT_OF_POOL_MEMORY",
        .error_member = "Unknown",
        .name = "VK_ERROR_OUT_OF_POOL_MEMORY",
    },
    .{
        .code = "vulkan.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS",
        .error_member = "Unknown",
        .name = "VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS",
    },
    .{
        .code = "vulkan.VK_ERROR_PRESENT_TIMING_QUEUE_FULL_EXT",
        .error_member = "Unknown",
        .name = "VK_ERROR_PRESENT_TIMING_QUEUE_FULL_EXT",
    },
};

/// One extension the loader gates a proc on.
const ExtMember = struct { name: []const u8, extension_name: []const u8 };

const Extension = struct {
    /// Emitted enum type name.
    name: []const u8,
    /// Emitted enabled-set type name.
    set_name: []const u8,
    /// Emitted group type name.
    group_name: []const u8,
    /// Doc comment for the emitted enum.
    doc: []const []const u8,
    /// Members, with the extension name each one reports.
    members: []const ExtMember,
};

const instance_ext: Extension = .{
    .name = "InstanceExt",
    .set_name = "EnabledInstanceExts",
    .group_name = "InstanceProcGroup",
    .doc = &.{
        "Vulkan instance extensions that gate a field in `InstanceProcs`.",
        "",
        "One member per `HasExt` test in `LoadInstanceProcs`",
        "(`VulkanFunctions.cpp:156`-`:204`), transcribed from `InstanceExt` at",
        "`src/dawn/native/vulkan/VulkanExtensions.h:40`. A member is a bit, so",
        "the set a caller passes is one word.",
    },
    .members = &.{
        .{ .name = "surface", .extension_name = "VK_KHR_surface" },
    },
};

const device_ext: Extension = .{
    .name = "DeviceExt",
    .set_name = "EnabledDeviceExts",
    .group_name = "DeviceProcGroup",
    .doc = &.{
        "Vulkan device extensions that gate a field in `DeviceProcs`.",
        "",
        "One member per `HasExt` test in `LoadDeviceProcs`",
        "(`VulkanFunctions.cpp:405`-`:469`), transcribed from `DeviceExt` at",
        "`src/dawn/native/vulkan/VulkanExtensions.h:79`. A member is a bit, so",
        "the set a caller passes is one word.",
    },
    .members = &.{
        .{ .name = "draw_indirect_count", .extension_name = "VK_KHR_draw_indirect_count" },
        .{ .name = "create_renderpass2", .extension_name = "VK_KHR_create_renderpass2" },
        .{ .name = "dynamic_rendering", .extension_name = "VK_KHR_dynamic_rendering" },
        .{ .name = "extended_dynamic_state", .extension_name = "VK_EXT_extended_dynamic_state" },
        .{ .name = "external_memory_fd", .extension_name = "VK_KHR_external_memory_fd" },
        .{ .name = "external_memory_host", .extension_name = "VK_EXT_external_memory_host" },
        .{ .name = "external_semaphore_fd", .extension_name = "VK_KHR_external_semaphore_fd" },
        .{ .name = "swapchain", .extension_name = "VK_KHR_swapchain" },
    },
};

// ---------------------------------------------------------------------------
// Emitting
// ---------------------------------------------------------------------------

/// The `Error` members, in the order `docs/30-port-design.md` §5.2 lists them,
/// plus `UnexpectedOutcome`. `UnexpectedOutcome` has no result code: it is what
/// a check function returns for a code `classify` calls a value, because a
/// check function has no way to hand a value back.
const error_members = [_][]const u8{
    "OutOfHostMemory",
    "OutOfDeviceMemory",
    "InitializationFailed",
    "DeviceLost",
    "MemoryMapFailed",
    "LayerNotPresent",
    "ExtensionNotPresent",
    "FeatureNotPresent",
    "IncompatibleDriver",
    "TooManyObjects",
    "FormatNotSupported",
    "FragmentedPool",
    "Unknown",
    "SurfaceLost",
    "NativeWindowInUse",
    "OutOfDate",
    "ValidationFailed",
    "UnknownResult",
    "UnexpectedOutcome",
};

/// Dawn's field count: 221 `VkFn` members plus the `GetInstanceProcAddr` it
/// types directly (`VulkanFunctions.h:84`).
const dawn_field_count = 222;

fn tierFieldCount(tier: Tier) usize {
    var total: usize = 0;
    for (tier.runs) |run| total += run.fields.len;
    return total;
}

fn emitPreamble(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\//! The Vulkan dispatch table.
        \\//!
        \\//! **Generated.** `zig build generate` rewrites this file from
        \\//! `tools/gen_dispatch.zig` and the pinned Vulkan-Headers commit in
        \\//! `build.zig.zon`. Do not hand-edit it, and do not hand-write the
        \\//! type it loads from: `test/gen_dispatch_drift.zig` fails when the
        \\//! two disagree.
        \\//!
        \\//! **What this is.** Dawn's three-tier function-pointer table
        \\//! (`src/dawn/native/vulkan/VulkanFunctions.h:70`) in Zig.
        \\//!
        \\
    );
    try writer.print(
        \\//! **The set.** Dawn holds {d} entry points, and this file declares
        \\//! {d} of them: {d} global, {d} instance, {d} device.
        \\//!
        \\//! `AGENTS.md` §3.1 makes this table the only door to Vulkan, so an
        \\//! entry point that is not a field here cannot be called.
        \\//! `tools/gen_dispatch.zig` names every row it left out and why.
        \\//!
        \\//! **What it is not.** It calls nothing. A field holds a
        \\//! `vulkan.PFN_vk*`, which the generated bindings already make
        \\//! optional, so a null field means "not loaded" and nothing else.
        \\//!
        \\const std = @import("std");
        \\const vulkan = @import("vulkan");
        \\
    , .{
        dawn_field_count,
        tierFieldCount(global_tier) + tierFieldCount(instance_tier) + tierFieldCount(device_tier),
        tierFieldCount(global_tier),
        tierFieldCount(instance_tier),
        tierFieldCount(device_tier),
    });
}

fn emitDispatch(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeDoc(writer, 0, &.{
        "The three tiers. A tier is a pointer because its loader allocates it",
        "and the device tier is one set per device",
        "(`docs/30-port-design.md` §6.2 and §6.3). A call site unwraps the pointer",
        "and then the function pointer, so the call reads",
        "`dispatch.device.?.create_buffer.?`.",
    });
    try writer.writeAll(
        \\pub const Dispatch = struct {
        \\    global: ?*GlobalProcs,
        \\    instance: ?*InstanceProcs,
        \\    device: ?*DeviceProcs,
        \\};
        \\
    );
}

fn emitTier(writer: *std.Io.Writer, tier: Tier) std.Io.Writer.Error!void {
    try writeDoc(writer, 0, tier.doc);
    try writer.print("pub const {s} = struct {{\n", .{tier.name});
    for (tier.runs) |run| {
        try writeDoc(writer, 4, run.doc);
        for (run.fields) |row| {
            try writer.print("    {s}: vulkan.PFN_{s},\n", .{ row.field, row.symbol });
        }
    }
    try writer.writeAll("};\n\n");
}

fn emitLoadError(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeDoc(writer, 0, &.{
        "Why a proc is not there.",
        "",
        "Three members, not one, because a call site reacts differently to each.",
        "A missing global proc means the loader is broken and the process should",
        "stop. A missing instance proc means the instance does not expose",
        "something the specification says it must. A missing device proc means an",
        "enabled extension does not deliver what it promises, so the caller asked",
        "for something wrong.",
        "",
        "Dawn folds all three into one `DAWN_UNRECOVERABLE_ERROR`",
        "(`VulkanFunctions.cpp:87`, `:113`, `:258`) and loses the distinction in the",
        "returned error.",
    });
    try writer.writeAll(
        \\pub const LoadError = error{
        \\    OutOfMemory,
        \\    MissingGlobalProc,
        \\    MissingInstanceProc,
        \\    MissingDeviceProc,
        \\};
        \\
    );
}

fn emitProcRow(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeDoc(writer, 0, &.{
        "One entry point: the dispatch field the loader fills, and the Vulkan",
        "symbol it looks up.",
        "",
        "A row is the whole contract between the generator and the loader. The",
        "field name is the symbol without its `vk` prefix in snake_case, which is",
        "the spelling `docs/40-plan.md` §3.2 uses for every row, and the comptime",
        "block at the end of this file checks it.",
    });
    try writer.writeAll(
        \\pub const ProcRow = struct {
        \\    field: []const u8,
        \\    symbol: [:0]const u8,
        \\};
        \\
        \\/// A block of fields the loader asks for only when the caller enabled
        \\/// the extension the block names.
        \\fn ProcGroup(comptime Ext: type) type {
        \\    return struct {
        \\        ext: Ext,
        \\        fields: []const ProcRow,
        \\    };
        \\}
        \\
    );
}

fn emitExtension(writer: *std.Io.Writer, extension: Extension) std.Io.Writer.Error!void {
    try writeDoc(writer, 0, extension.doc);
    try writer.print("pub const {s} = enum(u64) {{\n", .{extension.name});
    for (extension.members, 0..) |member, index| {
        try writer.print(
            "    /// `{s}`\n    {s} = 1 << {d},\n",
            .{ member.extension_name, member.name, index },
        );
    }
    try writer.writeAll("\n");
    try writeDoc(writer, 4, &.{
        "The name `vkEnumerate*ExtensionProperties` reports, which is what a",
        "caller matches on.",
    });
    try writer.print("    pub fn vkName(ext: {s}) [:0]const u8 {{\n", .{extension.name});
    try writer.writeAll("        return switch (ext) {\n");
    for (extension.members) |member| {
        try writer.print(
            "            .{s} => \"{s}\",\n",
            .{ member.name, member.extension_name },
        );
    }
    try writer.writeAll("        };\n    }\n};\n\n");

    try writeDoc(writer, 0, &.{
        "The set of extensions a caller enabled. `{}` enables none.",
    });
    try writer.print("pub const {s} = packed struct(u64) {{\n", .{extension.set_name});
    try writer.writeAll("    bits: u64 = 0,\n\n");
    try writer.print(
        \\    pub fn has(self: {s}, ext: {s}) bool {{
        \\        return self.bits & @intFromEnum(ext) != 0;
        \\    }}
        \\
        \\    pub fn with(self: {s}, ext: {s}) {s} {{
        \\        return .{{ .bits = self.bits | @intFromEnum(ext) }};
        \\    }}
        \\}};
        \\
    , .{ extension.set_name, extension.name, extension.set_name, extension.name, extension.set_name });
    try writer.print("pub const {s} = ProcGroup({s});\n\n", .{
        extension.group_name,
        extension.name,
    });
}

fn emitRows(
    writer: *std.Io.Writer,
    name: []const u8,
    doc: []const []const u8,
    rows: []const ProcRow,
) std.Io.Writer.Error!void {
    try writeDoc(writer, 0, doc);
    try writer.print("const {s} = [_]ProcRow{{\n", .{name});
    for (rows) |row| {
        if (row_fixed_columns + row.field.len + row.symbol.len <= max_line_columns) {
            try writer.print(
                "    .{{ .field = \"{s}\", .symbol = \"{s}\" }},\n",
                .{ row.field, row.symbol },
            );
        } else {
            try writer.print(
                "    .{{\n        .field = \"{s}\",\n        .symbol = \"{s}\",\n    }},\n",
                .{ row.field, row.symbol },
            );
        }
    }
    try writer.writeAll("};\n\n");
}

fn emitGlobalRows(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try emitRows(writer, "global_lib_fields", &.{
        "Dawn reads `vkGetInstanceProcAddr` out of the shared library itself",
        "(`VulkanFunctions.cpp:92`); every other global proc goes through it with",
        "a null instance (`GET_GLOBAL_PROC`, `:83`).",
    }, &global_lib_fields);
    try emitRows(writer, "global_fields", &.{
        "The three global procs Dawn makes a hard error over",
        "(`VulkanFunctions.cpp:96`-`:98`).",
    }, &global_fields);
    try emitRows(writer, "global_optional_fields", &.{
        "`vkEnumerateInstanceVersion` does not exist on Vulkan 1.0, so Dawn allows",
        "it to be null (`VulkanFunctions.cpp:100`-`:102`).",
    }, &global_optional_fields);
    try emitRows(writer, "global_instance_fields", &.{
        "`vkDestroyInstance` is loaded by `loadInstanceProcs` and first of all",
        "(`VulkanFunctions.cpp:127`), yet lives in `GlobalProcs`",
        "(`VulkanFunctions.h:89`-`:91`): the loader needs it to destroy an",
        "instance whose other procs turned out to be missing.",
    }, &global_instance_fields);
}

fn emitInstanceRows(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try emitRows(writer, "instance_fields", &.{
        "The instance procs Dawn loads unconditionally",
        "(`VulkanFunctions.cpp:129`-`:154`).",
    }, &instance_fields);
    try emitRows(writer, "instance_surface_fields", &.{
        "`VK_KHR_surface`, behind `if (globalInfo.HasExt(InstanceExt::Surface))`",
        "(`VulkanFunctions.cpp:156`).",
    }, &instance_surface_fields);
    try emitRows(writer, "instance_debug_utils_fields", &.{
        "`VK_EXT_debug_utils`. `TryLoadEXTDebugUtils` (`VulkanFunctions.cpp:219`)",
        "tolerates a missing one and then zeroes all eleven, so a caller never",
        "sees half a debug-utils table from a driver that advertises the",
        "extension and does not expose it.",
    }, &instance_debug_utils_fields);
    try emitRows(writer, "instance_optional_fields", &.{
        "`VK_KHR_cooperative_matrix` (`VulkanFunctions.cpp:207`-`:214`): a device",
        "extension that exposes an instance proc, so it is loaded with the",
        "tolerated-missing rule because the device is not known yet.",
    }, &instance_optional_fields);
}

fn emitDeviceRows(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try emitRows(writer, "device_fields", &.{
        "The device procs Dawn loads unconditionally",
        "(`VulkanFunctions.cpp:266`-`:402`).",
    }, &device_fields);
    for (device_gates) |gate| {
        try emitRows(writer, gate.rows_name, gate.doc, gate.fields);
    }
}

/// Emits one group table. The literal carries `[_]` so the elements are
/// `ProcGroup` values: a bare `[]` infers a pointer to the array, and `.ext`
/// then has no place to live. Each element takes its rows by address, which
/// coerces that array to the `[]const ProcRow` field.
fn emitGroups(
    writer: *std.Io.Writer,
    name: []const u8,
    group_name: []const u8,
    gates: []const Gate,
) std.Io.Writer.Error!void {
    try writer.print("const {s} = [_]{s}{{\n", .{ name, group_name });
    for (gates) |gate| {
        try writeNote(writer, 4, gate.doc);
        try writer.print(
            "    .{{ .ext = .{s}, .fields = &{s} }},\n",
            .{ gate.member, gate.rows_name },
        );
    }
    try writer.writeAll("};\n\n");
}

fn emitInstanceGroups(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try emitGroups(writer, "instance_groups", "InstanceProcGroup", &instance_gates);
}

fn emitDeviceGroups(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try emitGroups(writer, "device_groups", "DeviceProcGroup", &device_gates);
}

fn emitAllRows(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeDoc(writer, 0, &.{
        "Every row in this file, for the two comptime checks at the end.",
    });
    try writer.writeAll("const all_rows = [_][]const ProcRow{\n");
    try writer.writeAll("    &global_lib_fields,\n    &global_fields,\n" ++
        "    &global_optional_fields,\n    &global_instance_fields,\n" ++
        "    &instance_fields,\n    &instance_surface_fields,\n" ++
        "    &instance_debug_utils_fields,\n    &instance_optional_fields,\n" ++
        "    &device_fields,\n");
    for (device_gates) |gate| {
        try writer.print("    &{s},\n", .{gate.rows_name});
    }
    try writer.writeAll("};\n\n");
    try writeDoc(writer, 0, &.{
        "The length of the `vk` prefix every row's symbol carries. `snakeCase`",
        "slices past it, and the constant is what the slice is measured against",
        "rather than a bare `2`.",
    });
    try writer.writeAll(
        \\const vk_prefix_len = 2;
        \\
    );
    try writeDoc(writer, 0, &.{
        "Twice the longest symbol in `all_rows`. `snakeCase` writes at most one",
        "`_` per character, so a buffer this size cannot run out, and the check",
        "that would report it becomes a compile error rather than a runtime",
        "branch.",
    });
    try writer.writeAll(
        \\const longest_symbol_len = blk: {
        \\    var longest: usize = 0;
        \\    for (all_rows) |rows| {
        \\        for (rows) |row| longest = @max(longest, row.symbol.len);
        \\    }
        \\    break :blk longest * 2;
        \\};
        \\
    );
}

fn emitGlobalLoader(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeDoc(writer, 0, &.{
        "Loads the procs the loader needs before an instance exists.",
        "",
        "`lib` is an opened `std.DynLib` for the Vulkan loader; the caller owns it",
        "and closes it. The returned tier is the caller's to destroy with `gpa`.",
    });
    try writer.writeAll(
        \\pub fn loadGlobalProcs(gpa: std.mem.Allocator, lib: *std.DynLib) LoadError!*GlobalProcs {
        \\    const procs = try gpa.create(GlobalProcs);
        \\    errdefer gpa.destroy(procs);
        \\    // A field no loader fills stays null, which is what a null field
        \\    // means.
        \\    procs.* = std.mem.zeroes(GlobalProcs);
        \\
    );
    try writer.writeAll(
        \\    inline for (global_lib_fields) |row| {
        \\        const Proc = @FieldType(GlobalProcs, row.field);
        \\        const address = lib.lookup(ProcPointer(Proc), row.symbol);
        \\        if (address == null) return error.MissingGlobalProc;
        \\        @field(procs, row.field) = address;
        \\    }
        \\
        \\    const get_instance_proc_addr = procs.get_instance_proc_addr orelse
        \\        return error.MissingGlobalProc;
        \\
        \\    inline for (global_fields) |row| {
        \\        const Proc = @FieldType(GlobalProcs, row.field);
        \\        const address = get_instance_proc_addr(null, row.symbol);
        \\        if (address == null) return error.MissingGlobalProc;
        \\        @field(procs, row.field) = asProc(Proc, address);
        \\    }
        \\
        \\    inline for (global_optional_fields) |row| {
        \\        const Proc = @FieldType(GlobalProcs, row.field);
        \\        @field(procs, row.field) = asProc(
        \\            Proc,
        \\            get_instance_proc_addr(null, row.symbol),
        \\        );
        \\    }
        \\
        \\    return procs;
        \\}
        \\
    );
}

fn emitInstanceLoader(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeDoc(writer, 0, &.{
        "What `loadInstanceProcs` needs. The caller owns the returned tier and",
        "destroys it with the same `gpa`.",
    });
    try writer.writeAll(
        \\pub const InstanceLoadOptions = struct {
        \\    /// `GlobalProcs.get_instance_proc_addr`, the loader's own door.
        \\    get_instance_proc_addr: vulkan.PFN_vkGetInstanceProcAddr,
        \\    /// The instance the procs belong to.
        \\    instance: vulkan.VkInstance,
        \\    /// The instance extensions the caller enabled. An extension group
        \\    /// is asked for only when its extension is in this set, so a caller
        \\    /// that did not enable `VK_KHR_surface` never sees a loader error
        \\    /// for it.
        \\    enabled_extensions: EnabledInstanceExts,
        \\    /// The global tier, which owns `destroy_instance`.
        \\    global: *GlobalProcs,
        \\};
        \\
    );
    try writeDoc(writer, 0, &.{
        "Loads the procs reached with `options.instance`.",
    });
    try writer.writeAll(
        \\pub fn loadInstanceProcs(
        \\    gpa: std.mem.Allocator,
        \\    options: InstanceLoadOptions,
        \\) LoadError!*InstanceProcs {
        \\    const procs = try gpa.create(InstanceProcs);
        \\    errdefer gpa.destroy(procs);
        \\    procs.* = std.mem.zeroes(InstanceProcs);
        \\
        \\    const get_instance_proc_addr = options.get_instance_proc_addr orelse
        \\        return error.MissingInstanceProc;
        \\    const instance = options.instance;
        \\
        \\    // First, so a caller can destroy an instance whose other procs
        \\    // turned out to be missing (`VulkanFunctions.cpp:125`-`:127`).
        \\    inline for (global_instance_fields) |row| {
        \\        const Proc = @FieldType(GlobalProcs, row.field);
        \\        const address = get_instance_proc_addr(instance, row.symbol);
        \\        if (address == null) return error.MissingInstanceProc;
        \\        @field(options.global, row.field) = asProc(Proc, address);
        \\    }
        \\
        \\    inline for (instance_fields) |row| {
        \\        const Proc = @FieldType(InstanceProcs, row.field);
        \\        const address = get_instance_proc_addr(instance, row.symbol);
        \\        if (address == null) return error.MissingInstanceProc;
        \\        @field(procs, row.field) = asProc(Proc, address);
        \\    }
        \\
    );
    try writer.writeAll(
        \\    // `inline`, because the inner loop unrolls over `group.fields` and both
        \\    // `@FieldType` and `@field` need a comptime-known field name. A group
        \\    // whose extension the caller did not enable is still skipped at run
        \\    // time, so the guard costs nothing.
        \\    inline for (instance_groups) |group| {
        \\        if (options.enabled_extensions.has(group.ext)) {
        \\            inline for (group.fields) |row| {
        \\                const Proc = @FieldType(InstanceProcs, row.field);
        \\                const address = get_instance_proc_addr(instance, row.symbol);
        \\                if (address == null) return error.MissingInstanceProc;
        \\                @field(procs, row.field) = asProc(Proc, address);
        \\            }
        \\        }
        \\    }
        \\
        \\    inline for (instance_debug_utils_fields) |row| {
        \\        const Proc = @FieldType(InstanceProcs, row.field);
        \\        @field(procs, row.field) = asProc(
        \\            Proc,
        \\            get_instance_proc_addr(instance, row.symbol),
        \\        );
        \\    }
        \\
        \\    // Dawn zeroes all eleven when any one is missing
        \\    // (`VulkanFunctions.cpp:232`-`:250`), so a caller never sees half a
        \\    // debug-utils table.
        \\    if (anyMissing(InstanceProcs, &instance_debug_utils_fields, procs.*)) {
        \\        inline for (instance_debug_utils_fields) |row| {
        \\            @field(procs, row.field) = null;
        \\        }
        \\    }
        \\
        \\    inline for (instance_optional_fields) |row| {
        \\        const Proc = @FieldType(InstanceProcs, row.field);
        \\        @field(procs, row.field) = asProc(
        \\            Proc,
        \\            get_instance_proc_addr(instance, row.symbol),
        \\        );
        \\    }
        \\
        \\    return procs;
        \\}
        \\
        \\/// Whether any row of `rows` is still null, which is how
        \\/// `TryLoadEXTDebugUtils` decides to zero its whole group.
        \\fn anyMissing(comptime Procs: type, comptime rows: []const ProcRow, procs: Procs) bool {
        \\    inline for (rows) |row| {
        \\        if (@field(procs, row.field) == null) return true;
        \\    }
        \\    return false;
        \\}
        \\
    );
}

fn emitDeviceLoader(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeDoc(writer, 0, &.{
        "What `loadDeviceProcs` needs. The caller owns the returned tier and",
        "destroys it with the same `gpa`.",
    });
    try writer.writeAll(
        \\pub const DeviceLoadOptions = struct {
        \\    /// `InstanceProcs.get_device_proc_addr`. Unlike the other two
        \\    /// tiers, nothing is read from the shared library: the device tier
        \\    /// is reached through the instance that created it.
        \\    get_device_proc_addr: vulkan.PFN_vkGetDeviceProcAddr,
        \\    /// The device the procs belong to.
        \\    device: vulkan.VkDevice,
        \\    /// The device extensions the caller enabled. Dawn guards each block
        \\    /// of device procs with `if (deviceInfo.HasExt(...))`
        \\    /// (`VulkanFunctions.cpp:405`-`:469`), so an extension the caller
        \\    /// did not enable is never asked for and a missing one is always a
        \\    /// real failure.
        \\    enabled_extensions: EnabledDeviceExts,
        \\};
        \\
    );
    try writeDoc(writer, 0, &.{
        "Loads the procs reached with `options.device`.",
    });
    try writer.writeAll(
        \\pub fn loadDeviceProcs(
        \\    gpa: std.mem.Allocator,
        \\    options: DeviceLoadOptions,
        \\) LoadError!*DeviceProcs {
        \\    const procs = try gpa.create(DeviceProcs);
        \\    errdefer gpa.destroy(procs);
        \\    procs.* = std.mem.zeroes(DeviceProcs);
        \\
        \\    const get_device_proc_addr = options.get_device_proc_addr orelse
        \\        return error.MissingDeviceProc;
        \\    const device = options.device;
        \\
        \\    inline for (device_fields) |row| {
        \\        const Proc = @FieldType(DeviceProcs, row.field);
        \\        const address = get_device_proc_addr(device, row.symbol);
        \\        if (address == null) return error.MissingDeviceProc;
        \\        @field(procs, row.field) = asProc(Proc, address);
        \\    }
        \\
        \\    // `inline`, for the same reason as the instance loop: the inner loop
        \\    // unrolls over `group.fields`, and both `@FieldType` and `@field` need a
        \\    // comptime-known field name.
        \\    inline for (device_groups) |group| {
        \\        if (options.enabled_extensions.has(group.ext)) {
        \\            inline for (group.fields) |row| {
        \\                const Proc = @FieldType(DeviceProcs, row.field);
        \\                const address = get_device_proc_addr(device, row.symbol);
        \\                if (address == null) return error.MissingDeviceProc;
        \\                @field(procs, row.field) = asProc(Proc, address);
        \\            }
        \\        }
        \\    }
        \\
        \\    return procs;
        \\}
        \\
    );
}

fn emitCasts(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeDoc(writer, 0, &.{
        "Dawn's `AsVkFn` (`VulkanFunctions.cpp:68` and `:75`) in one function. A",
        "loader hands back `PFN_vkVoidFunction`, which is `?*const fn ()`, and a",
        "dispatch field holds a `PFN_vk*`: the same pointer with its signature",
        "attached. Taking the signature from the field type is what makes a row",
        "that names the wrong field a compile error rather than a wrong call.",
    });
    try writer.writeAll(
        \\fn asProc(comptime Proc: type, address: vulkan.PFN_vkVoidFunction) Proc {
        \\    return @ptrCast(address);
        \\}
        \\
    );
    try writeDoc(writer, 0, &.{
        "The pointer a `PFN_vk*` holds. `std.DynLib.lookup` returns `?T`, so it",
        "takes the pointer rather than the optional around it.",
    });
    try writer.writeAll(
        \\fn ProcPointer(comptime Proc: type) type {
        \\    return switch (@typeInfo(Proc)) {
        \\        .optional => |optional| optional.child,
        \\        else => Proc,
        \\    };
        \\}
        \\
    );
}

fn emitResult(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeDoc(writer, 0, &.{
        "Dawn's injected codes (`src/dawn/native/vulkan/VulkanError.h:36`-`:37`).",
        "",
        "`docs/30-port-design.md` §5.3 puts the injector in `core`, and `core`",
        "must not be reachable from `vk`, so the values are named here: the",
        "result table has no row for a code that is not a Vulkan value, and",
        "`checkVkOomThenSuccess` is the one check that reads them.",
    });
    try writer.writeAll(
        \\pub const injected_error_result: vulkan.VkResult = vulkan.VK_RESULT_MAX_ENUM;
        \\pub const injected_device_oom_result: vulkan.VkResult =
        \\    vulkan.VK_RESULT_MAX_ENUM - 1;
        \\
    );
    try writeDoc(writer, 0, &.{
        "How a `VkResult` classifies.",
        "",
        "`zig translate-c` gives `VkResult` as `c_int`",
        "(`docs/30-port-design.md` §5.1), so this union and `Error` are the only",
        "place a driver code becomes a Zig value (`AGENTS.md` §3.1). The tags",
        "other than `success` and `error` are outcomes the caller must branch",
        "on: `VK_INCOMPLETE` says call again, `VK_SUBOPTIMAL_KHR` says recreate",
        "the swapchain, and none of them is a failure.",
    });
    try writer.writeAll(
        \\pub const Outcome = union(enum) {
        \\    success,
        \\    incomplete,
        \\    not_ready,
        \\    timeout,
        \\    event_set,
        \\    event_reset,
        \\    suboptimal,
        \\    pipeline_compile_required,
        \\    @"error": Error,
        \\};
        \\
    );
    try writeDoc(writer, 0, &.{
        "A failed Vulkan call. Dawn has one unrecoverable error here",
        "(`VulkanError.cpp:103`-`:106`) and a device-lost error; the port keeps the",
        "specific codes because a consumer that retries allocation has to tell",
        "host memory from device memory (`docs/30-port-design.md` §5.4).",
        "",
        "`UnexpectedOutcome` has no result code. It is what a check function",
        "returns for a code that classifies to a value, because a check function",
        "returns `Error!void` and has no way to hand a value back.",
    });
    try writer.writeAll("pub const Error = error{\n");
    for (error_members) |member| {
        try writer.print("    {s},\n", .{member});
    }
    try writer.writeAll("};\n\n");

    try writeDoc(writer, 0, &.{
        "Classifies one result code. The `else` arm is not laziness: a driver may",
        "return a code from an extension this port does not know, and rejecting",
        "it would be a lie, so the code becomes `UnknownResult` and stays",
        "available as the number it was (`docs/30-port-design.md` §5.2).",
    });
    try writer.writeAll(
        \\pub fn classify(code: vulkan.VkResult) Outcome {
        \\    return switch (code) {
        \\
    );
    for (result_rows) |row| {
        try writer.print("        {s} => ", .{row.code});
        try writeOutcome(writer, row);
        try writer.writeAll(",\n");
    }
    try writer.writeAll(
        \\        else => .{ .@"error" = error.UnknownResult },
        \\    };
        \\}
        \\
    );

    try writeDoc(writer, 0, &.{
        "The Vulkan name of a result code, or `VkResult(unmapped)` for a code",
        "this port does not name. The caller formats the number itself, which is",
        "the case where the number matters and the name does not exist",
        "(`docs/30-port-design.md` §5.3). This replaces the switch at",
        "`VulkanError.cpp:39`.",
    });
    try writer.writeAll(
        \\pub fn vkResultName(code: vulkan.VkResult) []const u8 {
        \\    return switch (code) {
        \\
    );
    for (result_rows) |row| {
        try writer.print("        {s} => \"{s}\",\n", .{ row.code, row.name });
    }
    try writer.writeAll(
        \\        else => "VkResult(unmapped)",
        \\    };
        \\}
        \\
    );

    try writeDoc(writer, 0, &.{
        "Fails unless `code` is `VK_SUCCESS`, with the error the code classifies",
        "to.",
        "",
        "Dawn's `CheckVkSuccess` (`VulkanError.cpp:96`-`:108`) maps",
        "`VK_ERROR_DEVICE_LOST` to the device-lost error and everything else to",
        "one unrecoverable error; this returns the specific one. There is no",
        "`context` parameter: `Error` carries no payload, so the caller logs the",
        "call it made next to `vkResultName` and the number",
        "(`docs/30-port-design.md` §5.3).",
    });
    try writer.writeAll(
        \\pub fn checkVkSuccess(code: vulkan.VkResult) Error!void {
        \\    return switch (classify(code)) {
        \\        .success => {},
        \\        .@"error" => |err| return err,
        \\        .incomplete => error.UnexpectedOutcome,
        \\        .not_ready => error.UnexpectedOutcome,
        \\        .timeout => error.UnexpectedOutcome,
        \\        .event_set => error.UnexpectedOutcome,
        \\        .event_reset => error.UnexpectedOutcome,
        \\        .suboptimal => error.UnexpectedOutcome,
        \\        .pipeline_compile_required => error.UnexpectedOutcome,
        \\    };
        \\}
        \\
    );

    try writeDoc(writer, 0, &.{
        "Fails unless `code` is `VK_SUCCESS`, with the error the code classifies",
        "to, and with `injected_device_oom_result` treated as an allocation",
        "failure.",
        "",
        "Dawn's `CheckVkOOMThenSuccess` (`VulkanError.cpp:110`-`:125`) folds",
        "the two memory codes and the injected code into one out-of-memory error.",
        "`classify` has already separated the two memory codes, so the only thing",
        "left to add is the injected code, which is not a Vulkan value and so has",
        "no row in the result table.",
    });
    try writer.writeAll(
        \\pub fn checkVkOomThenSuccess(code: vulkan.VkResult) Error!void {
        \\    if (code == injected_device_oom_result) return error.OutOfDeviceMemory;
        \\    return checkVkSuccess(code);
        \\}
        \\
    );
}

/// Writes the `classify` arm body for one row: a bare tag for a value, and a
/// wrapped `Error` member for a failure.
fn writeOutcome(writer: *std.Io.Writer, row: ResultRow) std.Io.Writer.Error!void {
    if (row.value) |value| {
        try writer.print(".{s}", .{value});
        return;
    }
    // Cannot be null: the comptime block on `result_rows` below rejects a row
    // that carries a value and an error or neither.
    const error_member = row.error_member orelse unreachable;
    try writer.print(".{{ .@\"error\" = error.{s} }}", .{error_member});
}

comptime {
    for (result_rows) |row| {
        if ((row.value == null) == (row.error_member == null)) {
            @compileError("result row " ++ row.code ++ " needs a value or an error");
        }
    }
}

fn emitComptimeChecks(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print(
        \\/// The comptime branch quota the checks below need: each walks every row
        \\/// of a tier against every field of that tier, which is a few hundred
        \\/// thousand comparisons, well past the default of 1000.
        \\const coverage_branch_quota = {d};
        \\
        \\
    , .{pinned_rows_branch_quota});
    try writer.writeAll("comptime {\n");
    try writer.print("    @setEvalBranchQuota({d});\n", .{pinned_rows_branch_quota});
    try writeNote(writer, 4, &.{
        "Every field of every tier is named by exactly one row, and every row",
        "names a field of the tier it belongs to. A field with no row would stay",
        "null for ever and read as \"extension not enabled\"; a row with no field",
        "would make the loader fill a symbol nothing holds.",
    });
    try writer.writeAll("    assertFieldsCovered(GlobalProcs, &[_][]const ProcRow{\n");
    try writer.writeAll(
        "        &global_lib_fields,\n        &global_fields,\n" ++
            "        &global_optional_fields,\n        &global_instance_fields,\n" ++
            "    });\n",
    );
    try writer.writeAll("    assertFieldsCovered(InstanceProcs, &[_][]const ProcRow{\n");
    try writer.writeAll(
        "        &instance_fields,\n        &instance_surface_fields,\n" ++
            "        &instance_debug_utils_fields,\n        &instance_optional_fields,\n" ++
            "    });\n",
    );
    try writer.writeAll("    assertFieldsCovered(DeviceProcs, &[_][]const ProcRow{\n        &device_fields,\n");
    for (device_gates) |gate| {
        try writer.print("        &{s},\n", .{gate.rows_name});
    }
    try writer.writeAll("    });\n\n");

    try writeNote(writer, 4, &.{
        "Every field name is the snake_case of its symbol, which is the spelling",
        "`docs/40-plan.md` §3.2 uses for every row.",
    });
    try writer.writeAll(
        \\    var buffer: [longest_symbol_len]u8 = undefined;
        \\    for (all_rows) |rows| {
        \\        for (rows) |row| {
        \\            const want = snakeCase(buffer[0..], row.symbol);
        \\            if (!std.mem.eql(u8, row.field, want)) {
        \\                @compileError(std.fmt.comptimePrint(
        \\                    "{s} is spelled {s}, not {s}",
        \\                    .{ row.symbol, row.field, want },
        \\                ));
        \\            }
        \\        }
        \\    }
        \\
    );

    try writeNote(writer, 4, &.{
        "Every member of `Error` a result code can produce is reachable, so no",
        "member is dead. Two are the exception, and neither is a result code:",
        "`UnknownResult` is what `classify` returns for a code no row names,",
        "and `UnexpectedOutcome` is what a check function returns for a code",
        "that classifies to a value.",
    });
    try writer.writeAll("    const produced = [_]Error{\n");
    for (result_rows) |row| {
        const error_member = row.error_member orelse continue;
        try writer.print("        error.{s},\n", .{error_member});
    }
    try writer.writeAll(
        \\    };
        \\    for (@typeInfo(Error).error_set.?) |member| {
        \\        var reachable = false;
        \\        for (produced) |err| {
        \\            reachable = reachable or std.mem.eql(u8, @errorName(err), member.name);
        \\        }
        \\        const from_else = std.mem.eql(u8, member.name, "UnexpectedOutcome") or
        \\            std.mem.eql(u8, member.name, "UnknownResult");
        \\        if (!reachable and !from_else) {
        \\            @compileError(std.fmt.comptimePrint(
        \\                "Error.{s} has no result code",
        \\                .{member.name},
        \\            ));
        \\        }
        \\    }
        \\}
        \\
    );

    try writeDoc(writer, 0, &.{
        "Checks that every field of `Procs` is named by exactly one row, and",
        "that every row names a field of `Procs`.",
    });
    try writer.writeAll(
        \\fn assertFieldsCovered(
        \\    comptime Procs: type,
        \\    comptime rows: []const []const ProcRow,
        \\) void {
        \\    @setEvalBranchQuota(coverage_branch_quota);
        \\    const fields = @typeInfo(Procs).@"struct".fields;
        \\    for (fields) |field| {
        \\        var found: usize = 0;
        \\        for (rows) |row_list| {
        \\            for (row_list) |row| {
        \\                if (std.mem.eql(u8, row.field, field.name)) found += 1;
        \\            }
        \\        }
        \\        if (found != 1) {
        \\            @compileError(std.fmt.comptimePrint(
        \\                "{s}.{s} is named by {d} rows",
        \\                .{ @typeName(Procs), field.name, found },
        \\            ));
        \\        }
        \\    }
        \\    for (rows) |row_list| {
        \\        for (row_list) |row| {
        \\            var named = false;
        \\            for (fields) |field| {
        \\                named = named or std.mem.eql(u8, row.field, field.name);
        \\            }
        \\            if (!named) {
        \\                @compileError(std.fmt.comptimePrint(
        \\                    "{s} names no field of {s}",
        \\                    .{ row.symbol, @typeName(Procs) },
        \\                ));
        \\            }
        \\        }
        \\    }
        \\}
        \\
        \\/// The dispatch field name of a Vulkan symbol: the symbol without its
        \\/// `vk` prefix, in snake_case. A lower-case letter or digit before an
        \\/// upper-case one starts a word, and so does an upper-case run that is
        \\/// followed by a lower-case letter, which is what puts the `_ext` in
        \\/// `cmd_set_device_mask_ext` rather than `_e_x_t`.
        \\fn snakeCase(buffer: []u8, symbol: []const u8) []const u8 {
        \\    // `all_rows` is the only caller and every row names a `vk` symbol,
        \\    // so the slice below cannot be short. The guard states that rather
        \\    // than leaving it to the reader, and it is a compile error because a
        \\    // row without the prefix is a defect in this file, not an input.
        \\    if (symbol.len < vk_prefix_len) {
        \\        @compileError("a Vulkan symbol row must carry the vk prefix");
        \\    }
        \\    const name = symbol[vk_prefix_len..];
        \\    // The only caller sizes the buffer from `all_rows`, so this cannot
        \\    // fire: the assertion states the relationship rather than reporting
        \\    // a failure.
        \\    std.debug.assert(name.len * 2 <= buffer.len);
        \\    var index: usize = 0;
        \\    for (name, 0..) |character, position| {
        \\        if (std.ascii.isUpper(character) and position != 0) {
        \\            const previous = name[position - 1];
        \\            const next = if (position + 1 < name.len) name[position + 1] else ' ';
        \\            if (std.ascii.isLower(previous) or std.ascii.isDigit(previous) or
        \\                std.ascii.isLower(next))
        \\            {
        \\                buffer[index] = '_';
        \\                index += 1;
        \\            }
        \\        }
        \\        buffer[index] = std.ascii.toLower(character);
        \\        index += 1;
        \\    }
        \\    return buffer[0..index];
        \\}
        \\
    );
}

fn emitTests(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\test "a result code keeps its Vulkan name" {
        \\    try std.testing.expectEqualStrings(
        \\        "VK_SUCCESS",
        \\        vkResultName(vulkan.VK_SUCCESS),
        \\    );
        \\    try std.testing.expectEqualStrings(
        \\        "VK_ERROR_DEVICE_LOST",
        \\        vkResultName(vulkan.VK_ERROR_DEVICE_LOST),
        \\    );
        \\    // A code no port names. The number is the caller's to format
        \\    // (`docs/30-port-design.md` §5.3).
        \\    try std.testing.expectEqualStrings(
        \\        "VkResult(unmapped)",
        \\        vkResultName(-2_000_000_000),
        \\    );
        \\}
        \\
        \\test "checkVkSuccess fails with the error the code classifies to" {
        \\    try checkVkSuccess(vulkan.VK_SUCCESS);
        \\    try std.testing.expectError(
        \\        error.DeviceLost,
        \\        checkVkSuccess(vulkan.VK_ERROR_DEVICE_LOST),
        \\    );
        \\    try std.testing.expectError(
        \\        error.OutOfHostMemory,
        \\        checkVkSuccess(vulkan.VK_ERROR_OUT_OF_HOST_MEMORY),
        \\    );
        \\    try std.testing.expectError(
        \\        error.UnknownResult,
        \\        checkVkSuccess(-2_000_000_000),
        \\    );
        \\    // `VK_INCOMPLETE` is a value to `classify` and a failure to a check
        \\    // function, which cannot hand a value back.
        \\    try std.testing.expectError(
        \\        error.UnexpectedOutcome,
        \\        checkVkSuccess(vulkan.VK_INCOMPLETE),
        \\    );
        \\}
        \\
        \\test "checkVkOomThenSuccess turns the injected code into an allocation failure" {
        \\    try checkVkOomThenSuccess(vulkan.VK_SUCCESS);
        \\    try std.testing.expectError(
        \\        error.OutOfDeviceMemory,
        \\        checkVkOomThenSuccess(injected_device_oom_result),
        \\    );
        \\    try std.testing.expectError(
        \\        error.DeviceLost,
        \\        checkVkOomThenSuccess(vulkan.VK_ERROR_DEVICE_LOST),
        \\    );
        \\}
        \\
        \\test "an enabled-extension set holds only what was put in it" {
        \\    const none: EnabledDeviceExts = .{};
        \\    try std.testing.expect(!none.has(.swapchain));
        \\    try std.testing.expect(none.with(.swapchain).has(.swapchain));
        \\    try std.testing.expect(!none.with(.swapchain).has(.dynamic_rendering));
        \\}
        \\
    );
}

/// The widest line the emitted file may hold. The house limit is 100 columns.
const max_line_columns = 100;

/// The columns a one-line row spends on everything but the two names: four of
/// indent, and `.field = "", .symbol = ""` inside the braces.
const row_fixed_columns = 4 + ".{ .field = \"\", .symbol = \"\" },".len;

/// The comptime branch quota the emitted file needs. Its coverage check walks
/// every row of every tier against every field of that tier, which is a few
/// hundred thousand comparisons, well past the default 1000.
const pinned_rows_branch_quota = 4_000_000;

/// Writes a plain comment, one `//` line per element. Used inside an array
/// literal, where a doc comment has nothing to document: a doc comment is not
/// an expression, so the element after it would not parse.
fn writeNote(
    writer: *std.Io.Writer,
    indent: usize,
    lines: []const []const u8,
) std.Io.Writer.Error!void {
    for (lines) |line| {
        try writer.splatByteAll(' ', indent);
        if (line.len == 0) {
            try writer.writeAll("//\n");
        } else {
            try writer.print("// {s}\n", .{line});
        }
    }
}

/// Writes a doc comment, one `///` line per element. An empty element is the
/// blank `///` line between paragraphs.
fn writeDoc(
    writer: *std.Io.Writer,
    indent: usize,
    lines: []const []const u8,
) std.Io.Writer.Error!void {
    for (lines) |line| {
        try writer.splatByteAll(' ', indent);
        if (line.len == 0) {
            try writer.writeAll("///\n");
        } else {
            try writer.print("/// {s}\n", .{line});
        }
    }
}
