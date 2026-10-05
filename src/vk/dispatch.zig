//! The Vulkan dispatch table.
//!
//! **Generated.** `zig build generate` rewrites this file from
//! `tools/gen_dispatch.zig` and the pinned Vulkan-Headers commit in
//! `build.zig.zon`. Do not hand-edit it, and do not hand-write the
//! type it loads from: `test/gen_dispatch_drift.zig` fails when the
//! two disagree.
//!
//! **What this is.** Dawn's three-tier function-pointer table
//! (`src/dawn/native/vulkan/VulkanFunctions.h:70`) in Zig.
//!
//! **The set.** Dawn holds 222 entry points, and this file declares
//! 205 of them: 6 global, 41 instance, 158 device.
//!
//! `AGENTS.md` §3.1 makes this table the only door to Vulkan, so an
//! entry point that is not a field here cannot be called.
//! `tools/gen_dispatch.zig` names every row it left out and why.
//!
//! **What it is not.** It calls nothing. A field holds a
//! `vulkan.PFN_vk*`, which the generated bindings already make
//! optional, so a null field means "not loaded" and nothing else.
//!
const std = @import("std");
const vulkan = @import("vulkan");
/// The three tiers. A tier is a pointer because its loader allocates it
/// and the device tier is one set per device
/// (`docs/30-port-design.md` §6.2 and §6.3). A call site unwraps the pointer
/// and then the function pointer, so the call reads
/// `dispatch.device.?.create_buffer.?`.
pub const Dispatch = struct {
    global: ?*GlobalProcs,
    instance: ?*InstanceProcs,
    device: ?*DeviceProcs,
};
/// The procs the loader needs before an instance exists
/// (`VulkanFunctions.h:81`-`:94`).
///
/// `destroy_instance` lives here rather than in `InstanceProcs` because a
/// failed instance creation still has to be undone, and `loadInstanceProcs`
/// is where the instance handle first exists.
pub const GlobalProcs = struct {
    /// The proc every other proc is reached through, and the three the
    /// loader makes a hard error over (`VulkanFunctions.h:83`-`:88`,
    /// `VulkanFunctions.cpp:92`-`:98`).
    get_instance_proc_addr: vulkan.PFN_vkGetInstanceProcAddr,
    create_instance: vulkan.PFN_vkCreateInstance,
    enumerate_instance_extension_properties: vulkan.PFN_vkEnumerateInstanceExtensionProperties,
    enumerate_instance_layer_properties: vulkan.PFN_vkEnumerateInstanceLayerProperties,
    /// Loaded first by `loadInstanceProcs`
    /// (`VulkanFunctions.cpp:125`-`:127`).
    destroy_instance: vulkan.PFN_vkDestroyInstance,
    /// Vulkan 1.1 only (`VulkanFunctions.h:93`-`:94`), so a null field
    /// here is not a loader failure.
    enumerate_instance_version: vulkan.PFN_vkEnumerateInstanceVersion,
};

/// The procs reached with a `VkInstance` (`VulkanFunctions.h:96`-`:210`).
///
/// Every field is filled by `loadInstanceProcs`. The two Android
/// hardware-buffer fields, which Dawn groups with the instance tier and
/// loads with the device tier, are skipped: the pinned `vulkan_core.h`
/// declares no `PFN_vk*` typedef for either.
pub const InstanceProcs = struct {
    /// Core Vulkan 1.0, and what Vulkan 1.1 promoted
    /// (`VulkanFunctions.h:98`-`:135`, `VulkanFunctions.cpp:129`-`:154`).
    create_device: vulkan.PFN_vkCreateDevice,
    enumerate_device_extension_properties: vulkan.PFN_vkEnumerateDeviceExtensionProperties,
    enumerate_device_layer_properties: vulkan.PFN_vkEnumerateDeviceLayerProperties,
    enumerate_physical_devices: vulkan.PFN_vkEnumeratePhysicalDevices,
    get_device_proc_addr: vulkan.PFN_vkGetDeviceProcAddr,
    get_physical_device_features: vulkan.PFN_vkGetPhysicalDeviceFeatures,
    get_physical_device_format_properties: vulkan.PFN_vkGetPhysicalDeviceFormatProperties,
    get_physical_device_image_format_properties: vulkan.PFN_vkGetPhysicalDeviceImageFormatProperties,
    get_physical_device_memory_properties: vulkan.PFN_vkGetPhysicalDeviceMemoryProperties,
    get_physical_device_properties: vulkan.PFN_vkGetPhysicalDeviceProperties,
    get_physical_device_queue_family_properties: vulkan.PFN_vkGetPhysicalDeviceQueueFamilyProperties,
    get_physical_device_sparse_image_format_properties: vulkan.PFN_vkGetPhysicalDeviceSparseImageFormatProperties,
    destroy_device: vulkan.PFN_vkDestroyDevice,
    enumerate_physical_device_groups: vulkan.PFN_vkEnumeratePhysicalDeviceGroups,
    get_physical_device_external_buffer_properties: vulkan.PFN_vkGetPhysicalDeviceExternalBufferProperties,
    get_physical_device_external_fence_properties: vulkan.PFN_vkGetPhysicalDeviceExternalFenceProperties,
    get_physical_device_external_semaphore_properties: vulkan.PFN_vkGetPhysicalDeviceExternalSemaphoreProperties,
    get_physical_device_features2: vulkan.PFN_vkGetPhysicalDeviceFeatures2,
    get_physical_device_format_properties2: vulkan.PFN_vkGetPhysicalDeviceFormatProperties2,
    get_physical_device_image_format_properties2: vulkan.PFN_vkGetPhysicalDeviceImageFormatProperties2,
    get_physical_device_memory_properties2: vulkan.PFN_vkGetPhysicalDeviceMemoryProperties2,
    get_physical_device_properties2: vulkan.PFN_vkGetPhysicalDeviceProperties2,
    get_physical_device_queue_family_properties2: vulkan.PFN_vkGetPhysicalDeviceQueueFamilyProperties2,
    get_physical_device_sparse_image_format_properties2: vulkan.PFN_vkGetPhysicalDeviceSparseImageFormatProperties2,
    /// `VK_EXT_debug_utils` (`VulkanFunctions.h:137`-`:148`). All
    /// eleven are filled, or all eleven stay null.
    cmd_begin_debug_utils_label_ext: vulkan.PFN_vkCmdBeginDebugUtilsLabelEXT,
    cmd_end_debug_utils_label_ext: vulkan.PFN_vkCmdEndDebugUtilsLabelEXT,
    cmd_insert_debug_utils_label_ext: vulkan.PFN_vkCmdInsertDebugUtilsLabelEXT,
    create_debug_utils_messenger_ext: vulkan.PFN_vkCreateDebugUtilsMessengerEXT,
    destroy_debug_utils_messenger_ext: vulkan.PFN_vkDestroyDebugUtilsMessengerEXT,
    queue_begin_debug_utils_label_ext: vulkan.PFN_vkQueueBeginDebugUtilsLabelEXT,
    queue_end_debug_utils_label_ext: vulkan.PFN_vkQueueEndDebugUtilsLabelEXT,
    queue_insert_debug_utils_label_ext: vulkan.PFN_vkQueueInsertDebugUtilsLabelEXT,
    set_debug_utils_object_name_ext: vulkan.PFN_vkSetDebugUtilsObjectNameEXT,
    set_debug_utils_object_tag_ext: vulkan.PFN_vkSetDebugUtilsObjectTagEXT,
    submit_debug_utils_message_ext: vulkan.PFN_vkSubmitDebugUtilsMessageEXT,
    /// `VK_KHR_surface` (`VulkanFunctions.h:150`-`:157`). Filled only
    /// when the extension is in the caller's set.
    destroy_surface_khr: vulkan.PFN_vkDestroySurfaceKHR,
    get_physical_device_surface_support_khr: vulkan.PFN_vkGetPhysicalDeviceSurfaceSupportKHR,
    get_physical_device_surface_capabilities_khr: vulkan.PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR,
    get_physical_device_surface_formats_khr: vulkan.PFN_vkGetPhysicalDeviceSurfaceFormatsKHR,
    get_physical_device_surface_present_modes_khr: vulkan.PFN_vkGetPhysicalDeviceSurfacePresentModesKHR,
    /// `VK_KHR_cooperative_matrix` (`VulkanFunctions.h:206`-`:210`), a
    /// device extension reached with an instance proc, so a null field
    /// here is not a loader failure.
    get_physical_device_cooperative_matrix_properties_khr: vulkan.PFN_vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR,
};

/// The procs reached with a `VkDevice` (`VulkanFunctions.h:212`-`:409`).
///
/// `loadDeviceProcs` fills a field whose extension the caller enabled, and
/// a field whose extension it did not stays null.
pub const DeviceProcs = struct {
    /// Core Vulkan 1.0, and what Vulkan 1.1 promoted
    /// (`VulkanFunctions.h:214`-`:351`, `VulkanFunctions.cpp:266`-`:402`).
    allocate_command_buffers: vulkan.PFN_vkAllocateCommandBuffers,
    allocate_descriptor_sets: vulkan.PFN_vkAllocateDescriptorSets,
    allocate_memory: vulkan.PFN_vkAllocateMemory,
    begin_command_buffer: vulkan.PFN_vkBeginCommandBuffer,
    bind_buffer_memory: vulkan.PFN_vkBindBufferMemory,
    bind_image_memory: vulkan.PFN_vkBindImageMemory,
    cmd_begin_query: vulkan.PFN_vkCmdBeginQuery,
    cmd_begin_render_pass: vulkan.PFN_vkCmdBeginRenderPass,
    cmd_bind_descriptor_sets: vulkan.PFN_vkCmdBindDescriptorSets,
    cmd_bind_index_buffer: vulkan.PFN_vkCmdBindIndexBuffer,
    cmd_bind_pipeline: vulkan.PFN_vkCmdBindPipeline,
    cmd_bind_vertex_buffers: vulkan.PFN_vkCmdBindVertexBuffers,
    cmd_blit_image: vulkan.PFN_vkCmdBlitImage,
    cmd_clear_attachments: vulkan.PFN_vkCmdClearAttachments,
    cmd_clear_color_image: vulkan.PFN_vkCmdClearColorImage,
    cmd_clear_depth_stencil_image: vulkan.PFN_vkCmdClearDepthStencilImage,
    cmd_copy_buffer: vulkan.PFN_vkCmdCopyBuffer,
    cmd_copy_buffer_to_image: vulkan.PFN_vkCmdCopyBufferToImage,
    cmd_copy_image: vulkan.PFN_vkCmdCopyImage,
    cmd_copy_image_to_buffer: vulkan.PFN_vkCmdCopyImageToBuffer,
    cmd_copy_query_pool_results: vulkan.PFN_vkCmdCopyQueryPoolResults,
    cmd_dispatch: vulkan.PFN_vkCmdDispatch,
    cmd_dispatch_indirect: vulkan.PFN_vkCmdDispatchIndirect,
    cmd_draw: vulkan.PFN_vkCmdDraw,
    cmd_draw_indexed: vulkan.PFN_vkCmdDrawIndexed,
    cmd_draw_indexed_indirect: vulkan.PFN_vkCmdDrawIndexedIndirect,
    cmd_draw_indirect: vulkan.PFN_vkCmdDrawIndirect,
    cmd_end_query: vulkan.PFN_vkCmdEndQuery,
    cmd_end_render_pass: vulkan.PFN_vkCmdEndRenderPass,
    cmd_execute_commands: vulkan.PFN_vkCmdExecuteCommands,
    cmd_fill_buffer: vulkan.PFN_vkCmdFillBuffer,
    cmd_next_subpass: vulkan.PFN_vkCmdNextSubpass,
    cmd_pipeline_barrier: vulkan.PFN_vkCmdPipelineBarrier,
    cmd_push_constants: vulkan.PFN_vkCmdPushConstants,
    cmd_reset_event: vulkan.PFN_vkCmdResetEvent,
    cmd_reset_query_pool: vulkan.PFN_vkCmdResetQueryPool,
    cmd_resolve_image: vulkan.PFN_vkCmdResolveImage,
    cmd_set_blend_constants: vulkan.PFN_vkCmdSetBlendConstants,
    cmd_set_depth_bias: vulkan.PFN_vkCmdSetDepthBias,
    cmd_set_depth_bounds: vulkan.PFN_vkCmdSetDepthBounds,
    cmd_set_event: vulkan.PFN_vkCmdSetEvent,
    cmd_set_line_width: vulkan.PFN_vkCmdSetLineWidth,
    cmd_set_scissor: vulkan.PFN_vkCmdSetScissor,
    cmd_set_stencil_compare_mask: vulkan.PFN_vkCmdSetStencilCompareMask,
    cmd_set_stencil_reference: vulkan.PFN_vkCmdSetStencilReference,
    cmd_set_stencil_write_mask: vulkan.PFN_vkCmdSetStencilWriteMask,
    cmd_set_viewport: vulkan.PFN_vkCmdSetViewport,
    cmd_update_buffer: vulkan.PFN_vkCmdUpdateBuffer,
    cmd_wait_events: vulkan.PFN_vkCmdWaitEvents,
    cmd_write_timestamp: vulkan.PFN_vkCmdWriteTimestamp,
    create_buffer: vulkan.PFN_vkCreateBuffer,
    create_buffer_view: vulkan.PFN_vkCreateBufferView,
    create_command_pool: vulkan.PFN_vkCreateCommandPool,
    create_compute_pipelines: vulkan.PFN_vkCreateComputePipelines,
    create_descriptor_pool: vulkan.PFN_vkCreateDescriptorPool,
    create_descriptor_set_layout: vulkan.PFN_vkCreateDescriptorSetLayout,
    create_event: vulkan.PFN_vkCreateEvent,
    create_fence: vulkan.PFN_vkCreateFence,
    create_framebuffer: vulkan.PFN_vkCreateFramebuffer,
    create_graphics_pipelines: vulkan.PFN_vkCreateGraphicsPipelines,
    create_image: vulkan.PFN_vkCreateImage,
    create_image_view: vulkan.PFN_vkCreateImageView,
    create_pipeline_cache: vulkan.PFN_vkCreatePipelineCache,
    create_pipeline_layout: vulkan.PFN_vkCreatePipelineLayout,
    create_query_pool: vulkan.PFN_vkCreateQueryPool,
    create_render_pass: vulkan.PFN_vkCreateRenderPass,
    create_sampler: vulkan.PFN_vkCreateSampler,
    create_semaphore: vulkan.PFN_vkCreateSemaphore,
    create_shader_module: vulkan.PFN_vkCreateShaderModule,
    destroy_buffer: vulkan.PFN_vkDestroyBuffer,
    destroy_buffer_view: vulkan.PFN_vkDestroyBufferView,
    destroy_command_pool: vulkan.PFN_vkDestroyCommandPool,
    destroy_descriptor_pool: vulkan.PFN_vkDestroyDescriptorPool,
    destroy_descriptor_set_layout: vulkan.PFN_vkDestroyDescriptorSetLayout,
    destroy_event: vulkan.PFN_vkDestroyEvent,
    destroy_fence: vulkan.PFN_vkDestroyFence,
    destroy_framebuffer: vulkan.PFN_vkDestroyFramebuffer,
    destroy_image: vulkan.PFN_vkDestroyImage,
    destroy_image_view: vulkan.PFN_vkDestroyImageView,
    destroy_pipeline: vulkan.PFN_vkDestroyPipeline,
    destroy_pipeline_cache: vulkan.PFN_vkDestroyPipelineCache,
    destroy_pipeline_layout: vulkan.PFN_vkDestroyPipelineLayout,
    destroy_query_pool: vulkan.PFN_vkDestroyQueryPool,
    destroy_render_pass: vulkan.PFN_vkDestroyRenderPass,
    destroy_sampler: vulkan.PFN_vkDestroySampler,
    destroy_semaphore: vulkan.PFN_vkDestroySemaphore,
    destroy_shader_module: vulkan.PFN_vkDestroyShaderModule,
    device_wait_idle: vulkan.PFN_vkDeviceWaitIdle,
    end_command_buffer: vulkan.PFN_vkEndCommandBuffer,
    flush_mapped_memory_ranges: vulkan.PFN_vkFlushMappedMemoryRanges,
    free_command_buffers: vulkan.PFN_vkFreeCommandBuffers,
    free_descriptor_sets: vulkan.PFN_vkFreeDescriptorSets,
    free_memory: vulkan.PFN_vkFreeMemory,
    get_buffer_memory_requirements: vulkan.PFN_vkGetBufferMemoryRequirements,
    get_device_memory_commitment: vulkan.PFN_vkGetDeviceMemoryCommitment,
    get_device_queue: vulkan.PFN_vkGetDeviceQueue,
    get_event_status: vulkan.PFN_vkGetEventStatus,
    get_fence_status: vulkan.PFN_vkGetFenceStatus,
    get_image_memory_requirements: vulkan.PFN_vkGetImageMemoryRequirements,
    get_image_sparse_memory_requirements: vulkan.PFN_vkGetImageSparseMemoryRequirements,
    get_image_subresource_layout: vulkan.PFN_vkGetImageSubresourceLayout,
    get_pipeline_cache_data: vulkan.PFN_vkGetPipelineCacheData,
    get_query_pool_results: vulkan.PFN_vkGetQueryPoolResults,
    get_render_area_granularity: vulkan.PFN_vkGetRenderAreaGranularity,
    invalidate_mapped_memory_ranges: vulkan.PFN_vkInvalidateMappedMemoryRanges,
    map_memory: vulkan.PFN_vkMapMemory,
    merge_pipeline_caches: vulkan.PFN_vkMergePipelineCaches,
    queue_bind_sparse: vulkan.PFN_vkQueueBindSparse,
    queue_submit: vulkan.PFN_vkQueueSubmit,
    queue_wait_idle: vulkan.PFN_vkQueueWaitIdle,
    reset_command_buffer: vulkan.PFN_vkResetCommandBuffer,
    reset_command_pool: vulkan.PFN_vkResetCommandPool,
    reset_descriptor_pool: vulkan.PFN_vkResetDescriptorPool,
    reset_event: vulkan.PFN_vkResetEvent,
    reset_fences: vulkan.PFN_vkResetFences,
    set_event: vulkan.PFN_vkSetEvent,
    unmap_memory: vulkan.PFN_vkUnmapMemory,
    update_descriptor_sets: vulkan.PFN_vkUpdateDescriptorSets,
    wait_for_fences: vulkan.PFN_vkWaitForFences,
    bind_buffer_memory2: vulkan.PFN_vkBindBufferMemory2,
    bind_image_memory2: vulkan.PFN_vkBindImageMemory2,
    cmd_dispatch_base: vulkan.PFN_vkCmdDispatchBase,
    cmd_set_device_mask: vulkan.PFN_vkCmdSetDeviceMask,
    create_descriptor_update_template: vulkan.PFN_vkCreateDescriptorUpdateTemplate,
    create_sampler_ycbcr_conversion: vulkan.PFN_vkCreateSamplerYcbcrConversion,
    destroy_descriptor_update_template: vulkan.PFN_vkDestroyDescriptorUpdateTemplate,
    destroy_sampler_ycbcr_conversion: vulkan.PFN_vkDestroySamplerYcbcrConversion,
    get_buffer_memory_requirements2: vulkan.PFN_vkGetBufferMemoryRequirements2,
    get_descriptor_set_layout_support: vulkan.PFN_vkGetDescriptorSetLayoutSupport,
    get_device_group_peer_memory_features: vulkan.PFN_vkGetDeviceGroupPeerMemoryFeatures,
    get_device_queue2: vulkan.PFN_vkGetDeviceQueue2,
    get_image_memory_requirements2: vulkan.PFN_vkGetImageMemoryRequirements2,
    get_image_sparse_memory_requirements2: vulkan.PFN_vkGetImageSparseMemoryRequirements2,
    trim_command_pool: vulkan.PFN_vkTrimCommandPool,
    update_descriptor_set_with_template: vulkan.PFN_vkUpdateDescriptorSetWithTemplate,
    /// `VK_KHR_draw_indirect_count` (`VulkanFunctions.h:356`-`:360`), filled
    /// only when the extension is in the caller's set. Dawn opens the
    /// block at `VulkanFunctions.cpp:405`.
    cmd_draw_indirect_count_khr: vulkan.PFN_vkCmdDrawIndirectCountKHR,
    cmd_draw_indexed_indirect_count_khr: vulkan.PFN_vkCmdDrawIndexedIndirectCountKHR,
    /// `VK_KHR_create_renderpass2` (`VulkanFunctions.h:362`-`:363`), filled
    /// only when the extension is in the caller's set. Dawn opens the
    /// block at `VulkanFunctions.cpp:410`.
    create_render_pass2_khr: vulkan.PFN_vkCreateRenderPass2KHR,
    /// `VK_KHR_dynamic_rendering` (`VulkanFunctions.h:367`-`:369`), filled
    /// only when the extension is in the caller's set. Dawn opens the
    /// block at `VulkanFunctions.cpp:415`.
    cmd_begin_rendering_khr: vulkan.PFN_vkCmdBeginRenderingKHR,
    cmd_end_rendering_khr: vulkan.PFN_vkCmdEndRenderingKHR,
    /// `VK_EXT_extended_dynamic_state` (`VulkanFunctions.h:371`-`:379`),
    /// filled only when the extension is in the caller's set. Dawn opens
    /// the block at `VulkanFunctions.cpp:420`.
    cmd_set_cull_mode_ext: vulkan.PFN_vkCmdSetCullModeEXT,
    cmd_set_depth_compare_op_ext: vulkan.PFN_vkCmdSetDepthCompareOpEXT,
    cmd_set_depth_test_enable_ext: vulkan.PFN_vkCmdSetDepthTestEnableEXT,
    cmd_set_depth_write_enable_ext: vulkan.PFN_vkCmdSetDepthWriteEnableEXT,
    cmd_set_front_face_ext: vulkan.PFN_vkCmdSetFrontFaceEXT,
    cmd_set_primitive_topology_ext: vulkan.PFN_vkCmdSetPrimitiveTopologyEXT,
    cmd_set_stencil_op_ext: vulkan.PFN_vkCmdSetStencilOpEXT,
    cmd_set_stencil_test_enable_ext: vulkan.PFN_vkCmdSetStencilTestEnableEXT,
    /// `VK_KHR_external_memory_fd` (`VulkanFunctions.h:383`-`:385`), filled
    /// only when the extension is in the caller's set. Dawn opens the
    /// block at `VulkanFunctions.cpp:432`.
    get_memory_fd_khr: vulkan.PFN_vkGetMemoryFdKHR,
    get_memory_fd_properties_khr: vulkan.PFN_vkGetMemoryFdPropertiesKHR,
    /// `VK_EXT_external_memory_host` (`VulkanFunctions.h:387`-`:388`), filled
    /// only when the extension is in the caller's set. Dawn opens the
    /// block at `VulkanFunctions.cpp:437`.
    get_memory_host_pointer_properties_ext: vulkan.PFN_vkGetMemoryHostPointerPropertiesEXT,
    /// `VK_KHR_external_semaphore_fd` (`VulkanFunctions.h:390`-`:392`), filled
    /// only when the extension is in the caller's set. Dawn opens the
    /// block at `VulkanFunctions.cpp:441`.
    import_semaphore_fd_khr: vulkan.PFN_vkImportSemaphoreFdKHR,
    get_semaphore_fd_khr: vulkan.PFN_vkGetSemaphoreFdKHR,
    /// `VK_KHR_swapchain` (`VulkanFunctions.h:394`-`:399`), filled only when
    /// the extension is in the caller's set. Dawn opens the block at
    /// `VulkanFunctions.cpp:446`.
    create_swapchain_khr: vulkan.PFN_vkCreateSwapchainKHR,
    destroy_swapchain_khr: vulkan.PFN_vkDestroySwapchainKHR,
    get_swapchain_images_khr: vulkan.PFN_vkGetSwapchainImagesKHR,
    acquire_next_image_khr: vulkan.PFN_vkAcquireNextImageKHR,
    queue_present_khr: vulkan.PFN_vkQueuePresentKHR,
};

/// Why a proc is not there.
///
/// Three members, not one, because a call site reacts differently to each.
/// A missing global proc means the loader is broken and the process should
/// stop. A missing instance proc means the instance does not expose
/// something the specification says it must. A missing device proc means an
/// enabled extension does not deliver what it promises, so the caller asked
/// for something wrong.
///
/// Dawn folds all three into one `DAWN_UNRECOVERABLE_ERROR`
/// (`VulkanFunctions.cpp:87`, `:113`, `:258`) and loses the distinction in the
/// returned error.
pub const LoadError = error{
    OutOfMemory,
    MissingGlobalProc,
    MissingInstanceProc,
    MissingDeviceProc,
};
/// One entry point: the dispatch field the loader fills, and the Vulkan
/// symbol it looks up.
///
/// A row is the whole contract between the generator and the loader. The
/// field name is the symbol without its `vk` prefix in snake_case, which is
/// the spelling `docs/40-plan.md` §3.2 uses for every row, and the comptime
/// block at the end of this file checks it.
pub const ProcRow = struct {
    field: []const u8,
    symbol: [:0]const u8,
};

/// A block of fields the loader asks for only when the caller enabled
/// the extension the block names.
fn ProcGroup(comptime Ext: type) type {
    return struct {
        ext: Ext,
        fields: []const ProcRow,
    };
}
/// Vulkan instance extensions that gate a field in `InstanceProcs`.
///
/// One member per `HasExt` test in `LoadInstanceProcs`
/// (`VulkanFunctions.cpp:156`-`:204`), transcribed from `InstanceExt` at
/// `src/dawn/native/vulkan/VulkanExtensions.h:40`. A member is a bit, so
/// the set a caller passes is one word.
pub const InstanceExt = enum(u64) {
    /// `VK_KHR_surface`
    surface = 1 << 0,

    /// The name `vkEnumerate*ExtensionProperties` reports, which is what a
    /// caller matches on.
    pub fn vkName(ext: InstanceExt) [:0]const u8 {
        return switch (ext) {
            .surface => "VK_KHR_surface",
        };
    }
};

/// The set of extensions a caller enabled. `{}` enables none.
pub const EnabledInstanceExts = packed struct(u64) {
    bits: u64 = 0,

    pub fn has(self: EnabledInstanceExts, ext: InstanceExt) bool {
        return self.bits & @intFromEnum(ext) != 0;
    }

    pub fn with(self: EnabledInstanceExts, ext: InstanceExt) EnabledInstanceExts {
        return .{ .bits = self.bits | @intFromEnum(ext) };
    }
};
pub const InstanceProcGroup = ProcGroup(InstanceExt);

/// Vulkan device extensions that gate a field in `DeviceProcs`.
///
/// One member per `HasExt` test in `LoadDeviceProcs`
/// (`VulkanFunctions.cpp:405`-`:469`), transcribed from `DeviceExt` at
/// `src/dawn/native/vulkan/VulkanExtensions.h:79`. A member is a bit, so
/// the set a caller passes is one word.
pub const DeviceExt = enum(u64) {
    /// `VK_KHR_draw_indirect_count`
    draw_indirect_count = 1 << 0,
    /// `VK_KHR_create_renderpass2`
    create_renderpass2 = 1 << 1,
    /// `VK_KHR_dynamic_rendering`
    dynamic_rendering = 1 << 2,
    /// `VK_EXT_extended_dynamic_state`
    extended_dynamic_state = 1 << 3,
    /// `VK_KHR_external_memory_fd`
    external_memory_fd = 1 << 4,
    /// `VK_EXT_external_memory_host`
    external_memory_host = 1 << 5,
    /// `VK_KHR_external_semaphore_fd`
    external_semaphore_fd = 1 << 6,
    /// `VK_KHR_swapchain`
    swapchain = 1 << 7,

    /// The name `vkEnumerate*ExtensionProperties` reports, which is what a
    /// caller matches on.
    pub fn vkName(ext: DeviceExt) [:0]const u8 {
        return switch (ext) {
            .draw_indirect_count => "VK_KHR_draw_indirect_count",
            .create_renderpass2 => "VK_KHR_create_renderpass2",
            .dynamic_rendering => "VK_KHR_dynamic_rendering",
            .extended_dynamic_state => "VK_EXT_extended_dynamic_state",
            .external_memory_fd => "VK_KHR_external_memory_fd",
            .external_memory_host => "VK_EXT_external_memory_host",
            .external_semaphore_fd => "VK_KHR_external_semaphore_fd",
            .swapchain => "VK_KHR_swapchain",
        };
    }
};

/// The set of extensions a caller enabled. `{}` enables none.
pub const EnabledDeviceExts = packed struct(u64) {
    bits: u64 = 0,

    pub fn has(self: EnabledDeviceExts, ext: DeviceExt) bool {
        return self.bits & @intFromEnum(ext) != 0;
    }

    pub fn with(self: EnabledDeviceExts, ext: DeviceExt) EnabledDeviceExts {
        return .{ .bits = self.bits | @intFromEnum(ext) };
    }
};
pub const DeviceProcGroup = ProcGroup(DeviceExt);

/// Dawn reads `vkGetInstanceProcAddr` out of the shared library itself
/// (`VulkanFunctions.cpp:92`); every other global proc goes through it with
/// a null instance (`GET_GLOBAL_PROC`, `:83`).
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

/// `vkEnumerateInstanceVersion` does not exist on Vulkan 1.0, so Dawn allows
/// it to be null (`VulkanFunctions.cpp:100`-`:102`).
const global_optional_fields = [_]ProcRow{
    .{ .field = "enumerate_instance_version", .symbol = "vkEnumerateInstanceVersion" },
};

/// `vkDestroyInstance` is loaded by `loadInstanceProcs` and first of all
/// (`VulkanFunctions.cpp:127`), yet lives in `GlobalProcs`
/// (`VulkanFunctions.h:89`-`:91`): the loader needs it to destroy an
/// instance whose other procs turned out to be missing.
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
    .{ .field = "enumerate_device_layer_properties", .symbol = "vkEnumerateDeviceLayerProperties" },
    .{ .field = "enumerate_physical_devices", .symbol = "vkEnumeratePhysicalDevices" },
    .{ .field = "get_device_proc_addr", .symbol = "vkGetDeviceProcAddr" },
    .{ .field = "get_physical_device_features", .symbol = "vkGetPhysicalDeviceFeatures" },
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
    .{ .field = "get_physical_device_properties", .symbol = "vkGetPhysicalDeviceProperties" },
    .{
        .field = "get_physical_device_queue_family_properties",
        .symbol = "vkGetPhysicalDeviceQueueFamilyProperties",
    },
    .{
        .field = "get_physical_device_sparse_image_format_properties",
        .symbol = "vkGetPhysicalDeviceSparseImageFormatProperties",
    },
    .{ .field = "destroy_device", .symbol = "vkDestroyDevice" },
    .{ .field = "enumerate_physical_device_groups", .symbol = "vkEnumeratePhysicalDeviceGroups" },
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
    .{ .field = "get_physical_device_features2", .symbol = "vkGetPhysicalDeviceFeatures2" },
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
    .{ .field = "get_physical_device_properties2", .symbol = "vkGetPhysicalDeviceProperties2" },
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
/// tolerates a missing one and then zeroes all eleven, so a caller never
/// sees half a debug-utils table from a driver that advertises the
/// extension and does not expose it.
const instance_debug_utils_fields = [_]ProcRow{
    .{ .field = "cmd_begin_debug_utils_label_ext", .symbol = "vkCmdBeginDebugUtilsLabelEXT" },
    .{ .field = "cmd_end_debug_utils_label_ext", .symbol = "vkCmdEndDebugUtilsLabelEXT" },
    .{ .field = "cmd_insert_debug_utils_label_ext", .symbol = "vkCmdInsertDebugUtilsLabelEXT" },
    .{ .field = "create_debug_utils_messenger_ext", .symbol = "vkCreateDebugUtilsMessengerEXT" },
    .{ .field = "destroy_debug_utils_messenger_ext", .symbol = "vkDestroyDebugUtilsMessengerEXT" },
    .{ .field = "queue_begin_debug_utils_label_ext", .symbol = "vkQueueBeginDebugUtilsLabelEXT" },
    .{ .field = "queue_end_debug_utils_label_ext", .symbol = "vkQueueEndDebugUtilsLabelEXT" },
    .{ .field = "queue_insert_debug_utils_label_ext", .symbol = "vkQueueInsertDebugUtilsLabelEXT" },
    .{ .field = "set_debug_utils_object_name_ext", .symbol = "vkSetDebugUtilsObjectNameEXT" },
    .{ .field = "set_debug_utils_object_tag_ext", .symbol = "vkSetDebugUtilsObjectTagEXT" },
    .{ .field = "submit_debug_utils_message_ext", .symbol = "vkSubmitDebugUtilsMessageEXT" },
};

/// `VK_KHR_cooperative_matrix` (`VulkanFunctions.cpp:207`-`:214`): a device
/// extension that exposes an instance proc, so it is loaded with the
/// tolerated-missing rule because the device is not known yet.
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
    .{ .field = "cmd_clear_depth_stencil_image", .symbol = "vkCmdClearDepthStencilImage" },
    .{ .field = "cmd_copy_buffer", .symbol = "vkCmdCopyBuffer" },
    .{ .field = "cmd_copy_buffer_to_image", .symbol = "vkCmdCopyBufferToImage" },
    .{ .field = "cmd_copy_image", .symbol = "vkCmdCopyImage" },
    .{ .field = "cmd_copy_image_to_buffer", .symbol = "vkCmdCopyImageToBuffer" },
    .{ .field = "cmd_copy_query_pool_results", .symbol = "vkCmdCopyQueryPoolResults" },
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
    .{ .field = "cmd_set_stencil_compare_mask", .symbol = "vkCmdSetStencilCompareMask" },
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
    .{ .field = "create_descriptor_set_layout", .symbol = "vkCreateDescriptorSetLayout" },
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
    .{ .field = "destroy_descriptor_set_layout", .symbol = "vkDestroyDescriptorSetLayout" },
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
    .{ .field = "get_buffer_memory_requirements", .symbol = "vkGetBufferMemoryRequirements" },
    .{ .field = "get_device_memory_commitment", .symbol = "vkGetDeviceMemoryCommitment" },
    .{ .field = "get_device_queue", .symbol = "vkGetDeviceQueue" },
    .{ .field = "get_event_status", .symbol = "vkGetEventStatus" },
    .{ .field = "get_fence_status", .symbol = "vkGetFenceStatus" },
    .{ .field = "get_image_memory_requirements", .symbol = "vkGetImageMemoryRequirements" },
    .{
        .field = "get_image_sparse_memory_requirements",
        .symbol = "vkGetImageSparseMemoryRequirements",
    },
    .{ .field = "get_image_subresource_layout", .symbol = "vkGetImageSubresourceLayout" },
    .{ .field = "get_pipeline_cache_data", .symbol = "vkGetPipelineCacheData" },
    .{ .field = "get_query_pool_results", .symbol = "vkGetQueryPoolResults" },
    .{ .field = "get_render_area_granularity", .symbol = "vkGetRenderAreaGranularity" },
    .{ .field = "invalidate_mapped_memory_ranges", .symbol = "vkInvalidateMappedMemoryRanges" },
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
    .{ .field = "create_descriptor_update_template", .symbol = "vkCreateDescriptorUpdateTemplate" },
    .{ .field = "create_sampler_ycbcr_conversion", .symbol = "vkCreateSamplerYcbcrConversion" },
    .{
        .field = "destroy_descriptor_update_template",
        .symbol = "vkDestroyDescriptorUpdateTemplate",
    },
    .{ .field = "destroy_sampler_ycbcr_conversion", .symbol = "vkDestroySamplerYcbcrConversion" },
    .{ .field = "get_buffer_memory_requirements2", .symbol = "vkGetBufferMemoryRequirements2" },
    .{ .field = "get_descriptor_set_layout_support", .symbol = "vkGetDescriptorSetLayoutSupport" },
    .{
        .field = "get_device_group_peer_memory_features",
        .symbol = "vkGetDeviceGroupPeerMemoryFeatures",
    },
    .{ .field = "get_device_queue2", .symbol = "vkGetDeviceQueue2" },
    .{ .field = "get_image_memory_requirements2", .symbol = "vkGetImageMemoryRequirements2" },
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

/// `VK_KHR_draw_indirect_count` (`VulkanFunctions.h:356`-`:360`), filled
/// only when the extension is in the caller's set. Dawn opens the
/// block at `VulkanFunctions.cpp:405`.
const device_draw_indirect_count_fields = [_]ProcRow{
    .{ .field = "cmd_draw_indirect_count_khr", .symbol = "vkCmdDrawIndirectCountKHR" },
    .{
        .field = "cmd_draw_indexed_indirect_count_khr",
        .symbol = "vkCmdDrawIndexedIndirectCountKHR",
    },
};

/// `VK_KHR_create_renderpass2` (`VulkanFunctions.h:362`-`:363`), filled
/// only when the extension is in the caller's set. Dawn opens the
/// block at `VulkanFunctions.cpp:410`.
const device_create_renderpass2_fields = [_]ProcRow{
    .{ .field = "create_render_pass2_khr", .symbol = "vkCreateRenderPass2KHR" },
};

/// `VK_KHR_dynamic_rendering` (`VulkanFunctions.h:367`-`:369`), filled
/// only when the extension is in the caller's set. Dawn opens the
/// block at `VulkanFunctions.cpp:415`.
const device_dynamic_rendering_fields = [_]ProcRow{
    .{ .field = "cmd_begin_rendering_khr", .symbol = "vkCmdBeginRenderingKHR" },
    .{ .field = "cmd_end_rendering_khr", .symbol = "vkCmdEndRenderingKHR" },
};

/// `VK_EXT_extended_dynamic_state` (`VulkanFunctions.h:371`-`:379`),
/// filled only when the extension is in the caller's set. Dawn opens
/// the block at `VulkanFunctions.cpp:420`.
const device_extended_dynamic_state_fields = [_]ProcRow{
    .{ .field = "cmd_set_cull_mode_ext", .symbol = "vkCmdSetCullModeEXT" },
    .{ .field = "cmd_set_depth_compare_op_ext", .symbol = "vkCmdSetDepthCompareOpEXT" },
    .{ .field = "cmd_set_depth_test_enable_ext", .symbol = "vkCmdSetDepthTestEnableEXT" },
    .{ .field = "cmd_set_depth_write_enable_ext", .symbol = "vkCmdSetDepthWriteEnableEXT" },
    .{ .field = "cmd_set_front_face_ext", .symbol = "vkCmdSetFrontFaceEXT" },
    .{ .field = "cmd_set_primitive_topology_ext", .symbol = "vkCmdSetPrimitiveTopologyEXT" },
    .{ .field = "cmd_set_stencil_op_ext", .symbol = "vkCmdSetStencilOpEXT" },
    .{ .field = "cmd_set_stencil_test_enable_ext", .symbol = "vkCmdSetStencilTestEnableEXT" },
};

/// `VK_KHR_external_memory_fd` (`VulkanFunctions.h:383`-`:385`), filled
/// only when the extension is in the caller's set. Dawn opens the
/// block at `VulkanFunctions.cpp:432`.
const device_external_memory_fd_fields = [_]ProcRow{
    .{ .field = "get_memory_fd_khr", .symbol = "vkGetMemoryFdKHR" },
    .{ .field = "get_memory_fd_properties_khr", .symbol = "vkGetMemoryFdPropertiesKHR" },
};

/// `VK_EXT_external_memory_host` (`VulkanFunctions.h:387`-`:388`), filled
/// only when the extension is in the caller's set. Dawn opens the
/// block at `VulkanFunctions.cpp:437`.
const device_external_memory_host_fields = [_]ProcRow{
    .{
        .field = "get_memory_host_pointer_properties_ext",
        .symbol = "vkGetMemoryHostPointerPropertiesEXT",
    },
};

/// `VK_KHR_external_semaphore_fd` (`VulkanFunctions.h:390`-`:392`), filled
/// only when the extension is in the caller's set. Dawn opens the
/// block at `VulkanFunctions.cpp:441`.
const device_external_semaphore_fd_fields = [_]ProcRow{
    .{ .field = "import_semaphore_fd_khr", .symbol = "vkImportSemaphoreFdKHR" },
    .{ .field = "get_semaphore_fd_khr", .symbol = "vkGetSemaphoreFdKHR" },
};

/// `VK_KHR_swapchain` (`VulkanFunctions.h:394`-`:399`), filled only when
/// the extension is in the caller's set. Dawn opens the block at
/// `VulkanFunctions.cpp:446`.
const device_swapchain_fields = [_]ProcRow{
    .{ .field = "create_swapchain_khr", .symbol = "vkCreateSwapchainKHR" },
    .{ .field = "destroy_swapchain_khr", .symbol = "vkDestroySwapchainKHR" },
    .{ .field = "get_swapchain_images_khr", .symbol = "vkGetSwapchainImagesKHR" },
    .{ .field = "acquire_next_image_khr", .symbol = "vkAcquireNextImageKHR" },
    .{ .field = "queue_present_khr", .symbol = "vkQueuePresentKHR" },
};

const instance_groups = [_]InstanceProcGroup{
    // `VK_KHR_surface` (`VulkanFunctions.h:150`-`:157`), filled only when
    // the extension is in the caller's set. Dawn opens the block at
    // `VulkanFunctions.cpp:156`.
    .{ .ext = .surface, .fields = &instance_surface_fields },
};

const device_groups = [_]DeviceProcGroup{
    // `VK_KHR_draw_indirect_count` (`VulkanFunctions.h:356`-`:360`), filled
    // only when the extension is in the caller's set. Dawn opens the
    // block at `VulkanFunctions.cpp:405`.
    .{ .ext = .draw_indirect_count, .fields = &device_draw_indirect_count_fields },
    // `VK_KHR_create_renderpass2` (`VulkanFunctions.h:362`-`:363`), filled
    // only when the extension is in the caller's set. Dawn opens the
    // block at `VulkanFunctions.cpp:410`.
    .{ .ext = .create_renderpass2, .fields = &device_create_renderpass2_fields },
    // `VK_KHR_dynamic_rendering` (`VulkanFunctions.h:367`-`:369`), filled
    // only when the extension is in the caller's set. Dawn opens the
    // block at `VulkanFunctions.cpp:415`.
    .{ .ext = .dynamic_rendering, .fields = &device_dynamic_rendering_fields },
    // `VK_EXT_extended_dynamic_state` (`VulkanFunctions.h:371`-`:379`),
    // filled only when the extension is in the caller's set. Dawn opens
    // the block at `VulkanFunctions.cpp:420`.
    .{ .ext = .extended_dynamic_state, .fields = &device_extended_dynamic_state_fields },
    // `VK_KHR_external_memory_fd` (`VulkanFunctions.h:383`-`:385`), filled
    // only when the extension is in the caller's set. Dawn opens the
    // block at `VulkanFunctions.cpp:432`.
    .{ .ext = .external_memory_fd, .fields = &device_external_memory_fd_fields },
    // `VK_EXT_external_memory_host` (`VulkanFunctions.h:387`-`:388`), filled
    // only when the extension is in the caller's set. Dawn opens the
    // block at `VulkanFunctions.cpp:437`.
    .{ .ext = .external_memory_host, .fields = &device_external_memory_host_fields },
    // `VK_KHR_external_semaphore_fd` (`VulkanFunctions.h:390`-`:392`), filled
    // only when the extension is in the caller's set. Dawn opens the
    // block at `VulkanFunctions.cpp:441`.
    .{ .ext = .external_semaphore_fd, .fields = &device_external_semaphore_fd_fields },
    // `VK_KHR_swapchain` (`VulkanFunctions.h:394`-`:399`), filled only when
    // the extension is in the caller's set. Dawn opens the block at
    // `VulkanFunctions.cpp:446`.
    .{ .ext = .swapchain, .fields = &device_swapchain_fields },
};

/// Every row in this file, for the two comptime checks at the end.
const all_rows = [_][]const ProcRow{
    &global_lib_fields,
    &global_fields,
    &global_optional_fields,
    &global_instance_fields,
    &instance_fields,
    &instance_surface_fields,
    &instance_debug_utils_fields,
    &instance_optional_fields,
    &device_fields,
    &device_draw_indirect_count_fields,
    &device_create_renderpass2_fields,
    &device_dynamic_rendering_fields,
    &device_extended_dynamic_state_fields,
    &device_external_memory_fd_fields,
    &device_external_memory_host_fields,
    &device_external_semaphore_fd_fields,
    &device_swapchain_fields,
};

/// The length of the `vk` prefix every row's symbol carries. `snakeCase`
/// slices past it, and the constant is what the slice is measured against
/// rather than a bare `2`.
const vk_prefix_len = 2;
/// Twice the longest symbol in `all_rows`. `snakeCase` writes at most one
/// `_` per character, so a buffer this size cannot run out, and the check
/// that would report it becomes a compile error rather than a runtime
/// branch.
const longest_symbol_len = blk: {
    var longest: usize = 0;
    for (all_rows) |rows| {
        for (rows) |row| longest = @max(longest, row.symbol.len);
    }
    break :blk longest * 2;
};
/// Loads the procs the loader needs before an instance exists.
///
/// `lib` is an opened `std.DynLib` for the Vulkan loader; the caller owns it
/// and closes it. The returned tier is the caller's to destroy with `gpa`.
pub fn loadGlobalProcs(gpa: std.mem.Allocator, lib: *std.DynLib) LoadError!*GlobalProcs {
    const procs = try gpa.create(GlobalProcs);
    errdefer gpa.destroy(procs);
    // A field no loader fills stays null, which is what a null field
    // means.
    procs.* = std.mem.zeroes(GlobalProcs);
    inline for (global_lib_fields) |row| {
        const Proc = @FieldType(GlobalProcs, row.field);
        const address = lib.lookup(ProcPointer(Proc), row.symbol);
        if (address == null) return error.MissingGlobalProc;
        @field(procs, row.field) = address;
    }

    const get_instance_proc_addr = procs.get_instance_proc_addr orelse
        return error.MissingGlobalProc;

    inline for (global_fields) |row| {
        const Proc = @FieldType(GlobalProcs, row.field);
        const address = get_instance_proc_addr(null, row.symbol);
        if (address == null) return error.MissingGlobalProc;
        @field(procs, row.field) = asProc(Proc, address);
    }

    inline for (global_optional_fields) |row| {
        const Proc = @FieldType(GlobalProcs, row.field);
        @field(procs, row.field) = asProc(
            Proc,
            get_instance_proc_addr(null, row.symbol),
        );
    }

    return procs;
}
/// What `loadInstanceProcs` needs. The caller owns the returned tier and
/// destroys it with the same `gpa`.
pub const InstanceLoadOptions = struct {
    /// `GlobalProcs.get_instance_proc_addr`, the loader's own door.
    get_instance_proc_addr: vulkan.PFN_vkGetInstanceProcAddr,
    /// The instance the procs belong to.
    instance: vulkan.VkInstance,
    /// The instance extensions the caller enabled. An extension group
    /// is asked for only when its extension is in this set, so a caller
    /// that did not enable `VK_KHR_surface` never sees a loader error
    /// for it.
    enabled_extensions: EnabledInstanceExts,
    /// The global tier, which owns `destroy_instance`.
    global: *GlobalProcs,
};
/// Loads the procs reached with `options.instance`.
pub fn loadInstanceProcs(
    gpa: std.mem.Allocator,
    options: InstanceLoadOptions,
) LoadError!*InstanceProcs {
    const procs = try gpa.create(InstanceProcs);
    errdefer gpa.destroy(procs);
    procs.* = std.mem.zeroes(InstanceProcs);

    const get_instance_proc_addr = options.get_instance_proc_addr orelse
        return error.MissingInstanceProc;
    const instance = options.instance;

    // First, so a caller can destroy an instance whose other procs
    // turned out to be missing (`VulkanFunctions.cpp:125`-`:127`).
    inline for (global_instance_fields) |row| {
        const Proc = @FieldType(GlobalProcs, row.field);
        const address = get_instance_proc_addr(instance, row.symbol);
        if (address == null) return error.MissingInstanceProc;
        @field(options.global, row.field) = asProc(Proc, address);
    }

    inline for (instance_fields) |row| {
        const Proc = @FieldType(InstanceProcs, row.field);
        const address = get_instance_proc_addr(instance, row.symbol);
        if (address == null) return error.MissingInstanceProc;
        @field(procs, row.field) = asProc(Proc, address);
    }
    // `inline`, because the inner loop unrolls over `group.fields` and both
    // `@FieldType` and `@field` need a comptime-known field name. A group
    // whose extension the caller did not enable is still skipped at run
    // time, so the guard costs nothing.
    inline for (instance_groups) |group| {
        if (options.enabled_extensions.has(group.ext)) {
            inline for (group.fields) |row| {
                const Proc = @FieldType(InstanceProcs, row.field);
                const address = get_instance_proc_addr(instance, row.symbol);
                if (address == null) return error.MissingInstanceProc;
                @field(procs, row.field) = asProc(Proc, address);
            }
        }
    }

    inline for (instance_debug_utils_fields) |row| {
        const Proc = @FieldType(InstanceProcs, row.field);
        @field(procs, row.field) = asProc(
            Proc,
            get_instance_proc_addr(instance, row.symbol),
        );
    }

    // Dawn zeroes all eleven when any one is missing
    // (`VulkanFunctions.cpp:232`-`:250`), so a caller never sees half a
    // debug-utils table.
    if (anyMissing(InstanceProcs, &instance_debug_utils_fields, procs.*)) {
        inline for (instance_debug_utils_fields) |row| {
            @field(procs, row.field) = null;
        }
    }

    inline for (instance_optional_fields) |row| {
        const Proc = @FieldType(InstanceProcs, row.field);
        @field(procs, row.field) = asProc(
            Proc,
            get_instance_proc_addr(instance, row.symbol),
        );
    }

    return procs;
}

/// Whether any row of `rows` is still null, which is how
/// `TryLoadEXTDebugUtils` decides to zero its whole group.
fn anyMissing(comptime Procs: type, comptime rows: []const ProcRow, procs: Procs) bool {
    inline for (rows) |row| {
        if (@field(procs, row.field) == null) return true;
    }
    return false;
}
/// What `loadDeviceProcs` needs. The caller owns the returned tier and
/// destroys it with the same `gpa`.
pub const DeviceLoadOptions = struct {
    /// `InstanceProcs.get_device_proc_addr`. Unlike the other two
    /// tiers, nothing is read from the shared library: the device tier
    /// is reached through the instance that created it.
    get_device_proc_addr: vulkan.PFN_vkGetDeviceProcAddr,
    /// The device the procs belong to.
    device: vulkan.VkDevice,
    /// The device extensions the caller enabled. Dawn guards each block
    /// of device procs with `if (deviceInfo.HasExt(...))`
    /// (`VulkanFunctions.cpp:405`-`:469`), so an extension the caller
    /// did not enable is never asked for and a missing one is always a
    /// real failure.
    enabled_extensions: EnabledDeviceExts,
};
/// Loads the procs reached with `options.device`.
pub fn loadDeviceProcs(
    gpa: std.mem.Allocator,
    options: DeviceLoadOptions,
) LoadError!*DeviceProcs {
    const procs = try gpa.create(DeviceProcs);
    errdefer gpa.destroy(procs);
    procs.* = std.mem.zeroes(DeviceProcs);

    const get_device_proc_addr = options.get_device_proc_addr orelse
        return error.MissingDeviceProc;
    const device = options.device;

    inline for (device_fields) |row| {
        const Proc = @FieldType(DeviceProcs, row.field);
        const address = get_device_proc_addr(device, row.symbol);
        if (address == null) return error.MissingDeviceProc;
        @field(procs, row.field) = asProc(Proc, address);
    }

    // `inline`, for the same reason as the instance loop: the inner loop
    // unrolls over `group.fields`, and both `@FieldType` and `@field` need a
    // comptime-known field name.
    inline for (device_groups) |group| {
        if (options.enabled_extensions.has(group.ext)) {
            inline for (group.fields) |row| {
                const Proc = @FieldType(DeviceProcs, row.field);
                const address = get_device_proc_addr(device, row.symbol);
                if (address == null) return error.MissingDeviceProc;
                @field(procs, row.field) = asProc(Proc, address);
            }
        }
    }

    return procs;
}
/// Dawn's `AsVkFn` (`VulkanFunctions.cpp:68` and `:75`) in one function. A
/// loader hands back `PFN_vkVoidFunction`, which is `?*const fn ()`, and a
/// dispatch field holds a `PFN_vk*`: the same pointer with its signature
/// attached. Taking the signature from the field type is what makes a row
/// that names the wrong field a compile error rather than a wrong call.
fn asProc(comptime Proc: type, address: vulkan.PFN_vkVoidFunction) Proc {
    return @ptrCast(address);
}
/// The pointer a `PFN_vk*` holds. `std.DynLib.lookup` returns `?T`, so it
/// takes the pointer rather than the optional around it.
fn ProcPointer(comptime Proc: type) type {
    return switch (@typeInfo(Proc)) {
        .optional => |optional| optional.child,
        else => Proc,
    };
}
/// Dawn's injected codes (`src/dawn/native/vulkan/VulkanError.h:36`-`:37`).
///
/// `docs/30-port-design.md` §5.3 puts the injector in `core`, and `core`
/// must not be reachable from `vk`, so the values are named here: the
/// result table has no row for a code that is not a Vulkan value, and
/// `checkVkOomThenSuccess` is the one check that reads them.
pub const injected_error_result: vulkan.VkResult = vulkan.VK_RESULT_MAX_ENUM;
pub const injected_device_oom_result: vulkan.VkResult =
    vulkan.VK_RESULT_MAX_ENUM - 1;
/// How a `VkResult` classifies.
///
/// `zig translate-c` gives `VkResult` as `c_int`
/// (`docs/30-port-design.md` §5.1), so this union and `Error` are the only
/// place a driver code becomes a Zig value (`AGENTS.md` §3.1). The tags
/// other than `success` and `error` are outcomes the caller must branch
/// on: `VK_INCOMPLETE` says call again, `VK_SUBOPTIMAL_KHR` says recreate
/// the swapchain, and none of them is a failure.
pub const Outcome = union(enum) {
    success,
    incomplete,
    not_ready,
    timeout,
    event_set,
    event_reset,
    suboptimal,
    pipeline_compile_required,
    @"error": Error,
};
/// A failed Vulkan call. Dawn has one unrecoverable error here
/// (`VulkanError.cpp:103`-`:106`) and a device-lost error; the port keeps the
/// specific codes because a consumer that retries allocation has to tell
/// host memory from device memory (`docs/30-port-design.md` §5.4).
///
/// `UnexpectedOutcome` has no result code. It is what a check function
/// returns for a code that classifies to a value, because a check function
/// returns `Error!void` and has no way to hand a value back.
pub const Error = error{
    OutOfHostMemory,
    OutOfDeviceMemory,
    InitializationFailed,
    DeviceLost,
    MemoryMapFailed,
    LayerNotPresent,
    ExtensionNotPresent,
    FeatureNotPresent,
    IncompatibleDriver,
    TooManyObjects,
    FormatNotSupported,
    FragmentedPool,
    Unknown,
    SurfaceLost,
    NativeWindowInUse,
    OutOfDate,
    ValidationFailed,
    UnknownResult,
    UnexpectedOutcome,
};

/// Classifies one result code. The `else` arm is not laziness: a driver may
/// return a code from an extension this port does not know, and rejecting
/// it would be a lie, so the code becomes `UnknownResult` and stays
/// available as the number it was (`docs/30-port-design.md` §5.2).
pub fn classify(code: vulkan.VkResult) Outcome {
    return switch (code) {
        vulkan.VK_SUCCESS => .success,
        vulkan.VK_NOT_READY => .not_ready,
        vulkan.VK_TIMEOUT => .timeout,
        vulkan.VK_EVENT_SET => .event_set,
        vulkan.VK_EVENT_RESET => .event_reset,
        vulkan.VK_INCOMPLETE => .incomplete,
        vulkan.VK_SUBOPTIMAL_KHR => .suboptimal,
        vulkan.VK_PIPELINE_COMPILE_REQUIRED => .pipeline_compile_required,
        vulkan.VK_ERROR_OUT_OF_HOST_MEMORY => .{ .@"error" = error.OutOfHostMemory },
        vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY => .{ .@"error" = error.OutOfDeviceMemory },
        vulkan.VK_ERROR_INITIALIZATION_FAILED => .{ .@"error" = error.InitializationFailed },
        vulkan.VK_ERROR_DEVICE_LOST => .{ .@"error" = error.DeviceLost },
        vulkan.VK_ERROR_MEMORY_MAP_FAILED => .{ .@"error" = error.MemoryMapFailed },
        vulkan.VK_ERROR_LAYER_NOT_PRESENT => .{ .@"error" = error.LayerNotPresent },
        vulkan.VK_ERROR_EXTENSION_NOT_PRESENT => .{ .@"error" = error.ExtensionNotPresent },
        vulkan.VK_ERROR_FEATURE_NOT_PRESENT => .{ .@"error" = error.FeatureNotPresent },
        vulkan.VK_ERROR_INCOMPATIBLE_DRIVER => .{ .@"error" = error.IncompatibleDriver },
        vulkan.VK_ERROR_TOO_MANY_OBJECTS => .{ .@"error" = error.TooManyObjects },
        vulkan.VK_ERROR_FORMAT_NOT_SUPPORTED => .{ .@"error" = error.FormatNotSupported },
        vulkan.VK_ERROR_FRAGMENTED_POOL => .{ .@"error" = error.FragmentedPool },
        vulkan.VK_ERROR_UNKNOWN => .{ .@"error" = error.Unknown },
        vulkan.VK_ERROR_SURFACE_LOST_KHR => .{ .@"error" = error.SurfaceLost },
        vulkan.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => .{ .@"error" = error.NativeWindowInUse },
        vulkan.VK_ERROR_OUT_OF_DATE_KHR => .{ .@"error" = error.OutOfDate },
        vulkan.VK_ERROR_VALIDATION_FAILED => .{ .@"error" = error.ValidationFailed },
        vulkan.VK_ERROR_FRAGMENTATION => .{ .@"error" = error.Unknown },
        vulkan.VK_ERROR_NOT_PERMITTED => .{ .@"error" = error.Unknown },
        vulkan.VK_ERROR_COMPRESSION_EXHAUSTED_EXT => .{ .@"error" = error.Unknown },
        vulkan.VK_ERROR_INVALID_EXTERNAL_HANDLE => .{ .@"error" = error.Unknown },
        vulkan.VK_ERROR_OUT_OF_POOL_MEMORY => .{ .@"error" = error.Unknown },
        vulkan.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => .{ .@"error" = error.Unknown },
        vulkan.VK_ERROR_PRESENT_TIMING_QUEUE_FULL_EXT => .{ .@"error" = error.Unknown },
        else => .{ .@"error" = error.UnknownResult },
    };
}
/// The Vulkan name of a result code, or `VkResult(unmapped)` for a code
/// this port does not name. The caller formats the number itself, which is
/// the case where the number matters and the name does not exist
/// (`docs/30-port-design.md` §5.3). This replaces the switch at
/// `VulkanError.cpp:39`.
pub fn vkResultName(code: vulkan.VkResult) []const u8 {
    return switch (code) {
        vulkan.VK_SUCCESS => "VK_SUCCESS",
        vulkan.VK_NOT_READY => "VK_NOT_READY",
        vulkan.VK_TIMEOUT => "VK_TIMEOUT",
        vulkan.VK_EVENT_SET => "VK_EVENT_SET",
        vulkan.VK_EVENT_RESET => "VK_EVENT_RESET",
        vulkan.VK_INCOMPLETE => "VK_INCOMPLETE",
        vulkan.VK_SUBOPTIMAL_KHR => "VK_SUBOPTIMAL_KHR",
        vulkan.VK_PIPELINE_COMPILE_REQUIRED => "VK_PIPELINE_COMPILE_REQUIRED",
        vulkan.VK_ERROR_OUT_OF_HOST_MEMORY => "VK_ERROR_OUT_OF_HOST_MEMORY",
        vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY => "VK_ERROR_OUT_OF_DEVICE_MEMORY",
        vulkan.VK_ERROR_INITIALIZATION_FAILED => "VK_ERROR_INITIALIZATION_FAILED",
        vulkan.VK_ERROR_DEVICE_LOST => "VK_ERROR_DEVICE_LOST",
        vulkan.VK_ERROR_MEMORY_MAP_FAILED => "VK_ERROR_MEMORY_MAP_FAILED",
        vulkan.VK_ERROR_LAYER_NOT_PRESENT => "VK_ERROR_LAYER_NOT_PRESENT",
        vulkan.VK_ERROR_EXTENSION_NOT_PRESENT => "VK_ERROR_EXTENSION_NOT_PRESENT",
        vulkan.VK_ERROR_FEATURE_NOT_PRESENT => "VK_ERROR_FEATURE_NOT_PRESENT",
        vulkan.VK_ERROR_INCOMPATIBLE_DRIVER => "VK_ERROR_INCOMPATIBLE_DRIVER",
        vulkan.VK_ERROR_TOO_MANY_OBJECTS => "VK_ERROR_TOO_MANY_OBJECTS",
        vulkan.VK_ERROR_FORMAT_NOT_SUPPORTED => "VK_ERROR_FORMAT_NOT_SUPPORTED",
        vulkan.VK_ERROR_FRAGMENTED_POOL => "VK_ERROR_FRAGMENTED_POOL",
        vulkan.VK_ERROR_UNKNOWN => "VK_ERROR_UNKNOWN",
        vulkan.VK_ERROR_SURFACE_LOST_KHR => "VK_ERROR_SURFACE_LOST_KHR",
        vulkan.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => "VK_ERROR_NATIVE_WINDOW_IN_USE_KHR",
        vulkan.VK_ERROR_OUT_OF_DATE_KHR => "VK_ERROR_OUT_OF_DATE_KHR",
        vulkan.VK_ERROR_VALIDATION_FAILED => "VK_ERROR_VALIDATION_FAILED",
        vulkan.VK_ERROR_FRAGMENTATION => "VK_ERROR_FRAGMENTATION",
        vulkan.VK_ERROR_NOT_PERMITTED => "VK_ERROR_NOT_PERMITTED",
        vulkan.VK_ERROR_COMPRESSION_EXHAUSTED_EXT => "VK_ERROR_COMPRESSION_EXHAUSTED_EXT",
        vulkan.VK_ERROR_INVALID_EXTERNAL_HANDLE => "VK_ERROR_INVALID_EXTERNAL_HANDLE",
        vulkan.VK_ERROR_OUT_OF_POOL_MEMORY => "VK_ERROR_OUT_OF_POOL_MEMORY",
        vulkan.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => "VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS",
        vulkan.VK_ERROR_PRESENT_TIMING_QUEUE_FULL_EXT => "VK_ERROR_PRESENT_TIMING_QUEUE_FULL_EXT",
        else => "VkResult(unmapped)",
    };
}
/// Fails unless `code` is `VK_SUCCESS`, with the error the code classifies
/// to.
///
/// Dawn's `CheckVkSuccess` (`VulkanError.cpp:96`-`:108`) maps
/// `VK_ERROR_DEVICE_LOST` to the device-lost error and everything else to
/// one unrecoverable error; this returns the specific one. There is no
/// `context` parameter: `Error` carries no payload, so the caller logs the
/// call it made next to `vkResultName` and the number
/// (`docs/30-port-design.md` §5.3).
pub fn checkVkSuccess(code: vulkan.VkResult) Error!void {
    return switch (classify(code)) {
        .success => {},
        .@"error" => |err| return err,
        .incomplete => error.UnexpectedOutcome,
        .not_ready => error.UnexpectedOutcome,
        .timeout => error.UnexpectedOutcome,
        .event_set => error.UnexpectedOutcome,
        .event_reset => error.UnexpectedOutcome,
        .suboptimal => error.UnexpectedOutcome,
        .pipeline_compile_required => error.UnexpectedOutcome,
    };
}
/// Fails unless `code` is `VK_SUCCESS`, with the error the code classifies
/// to, and with `injected_device_oom_result` treated as an allocation
/// failure.
///
/// Dawn's `CheckVkOOMThenSuccess` (`VulkanError.cpp:110`-`:125`) folds
/// the two memory codes and the injected code into one out-of-memory error.
/// `classify` has already separated the two memory codes, so the only thing
/// left to add is the injected code, which is not a Vulkan value and so has
/// no row in the result table.
pub fn checkVkOomThenSuccess(code: vulkan.VkResult) Error!void {
    if (code == injected_device_oom_result) return error.OutOfDeviceMemory;
    return checkVkSuccess(code);
}
/// The comptime branch quota the checks below need: each walks every row
/// of a tier against every field of that tier, which is a few hundred
/// thousand comparisons, well past the default of 1000.
const coverage_branch_quota = 4000000;

comptime {
    @setEvalBranchQuota(4000000);
    // Every field of every tier is named by exactly one row, and every row
    // names a field of the tier it belongs to. A field with no row would stay
    // null for ever and read as "extension not enabled"; a row with no field
    // would make the loader fill a symbol nothing holds.
    assertFieldsCovered(GlobalProcs, &[_][]const ProcRow{
        &global_lib_fields,
        &global_fields,
        &global_optional_fields,
        &global_instance_fields,
    });
    assertFieldsCovered(InstanceProcs, &[_][]const ProcRow{
        &instance_fields,
        &instance_surface_fields,
        &instance_debug_utils_fields,
        &instance_optional_fields,
    });
    assertFieldsCovered(DeviceProcs, &[_][]const ProcRow{
        &device_fields,
        &device_draw_indirect_count_fields,
        &device_create_renderpass2_fields,
        &device_dynamic_rendering_fields,
        &device_extended_dynamic_state_fields,
        &device_external_memory_fd_fields,
        &device_external_memory_host_fields,
        &device_external_semaphore_fd_fields,
        &device_swapchain_fields,
    });

    // Every field name is the snake_case of its symbol, which is the spelling
    // `docs/40-plan.md` §3.2 uses for every row.
    var buffer: [longest_symbol_len]u8 = undefined;
    for (all_rows) |rows| {
        for (rows) |row| {
            const want = snakeCase(buffer[0..], row.symbol);
            if (!std.mem.eql(u8, row.field, want)) {
                @compileError(std.fmt.comptimePrint(
                    "{s} is spelled {s}, not {s}",
                    .{ row.symbol, row.field, want },
                ));
            }
        }
    }
    // Every member of `Error` a result code can produce is reachable, so no
    // member is dead. Two are the exception, and neither is a result code:
    // `UnknownResult` is what `classify` returns for a code no row names,
    // and `UnexpectedOutcome` is what a check function returns for a code
    // that classifies to a value.
    const produced = [_]Error{
        error.OutOfHostMemory,
        error.OutOfDeviceMemory,
        error.InitializationFailed,
        error.DeviceLost,
        error.MemoryMapFailed,
        error.LayerNotPresent,
        error.ExtensionNotPresent,
        error.FeatureNotPresent,
        error.IncompatibleDriver,
        error.TooManyObjects,
        error.FormatNotSupported,
        error.FragmentedPool,
        error.Unknown,
        error.SurfaceLost,
        error.NativeWindowInUse,
        error.OutOfDate,
        error.ValidationFailed,
        error.Unknown,
        error.Unknown,
        error.Unknown,
        error.Unknown,
        error.Unknown,
        error.Unknown,
        error.Unknown,
    };
    for (@typeInfo(Error).error_set.?) |member| {
        var reachable = false;
        for (produced) |err| {
            reachable = reachable or std.mem.eql(u8, @errorName(err), member.name);
        }
        const from_else = std.mem.eql(u8, member.name, "UnexpectedOutcome") or
            std.mem.eql(u8, member.name, "UnknownResult");
        if (!reachable and !from_else) {
            @compileError(std.fmt.comptimePrint(
                "Error.{s} has no result code",
                .{member.name},
            ));
        }
    }
}
/// Checks that every field of `Procs` is named by exactly one row, and
/// that every row names a field of `Procs`.
fn assertFieldsCovered(
    comptime Procs: type,
    comptime rows: []const []const ProcRow,
) void {
    @setEvalBranchQuota(coverage_branch_quota);
    const fields = @typeInfo(Procs).@"struct".fields;
    for (fields) |field| {
        var found: usize = 0;
        for (rows) |row_list| {
            for (row_list) |row| {
                if (std.mem.eql(u8, row.field, field.name)) found += 1;
            }
        }
        if (found != 1) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} is named by {d} rows",
                .{ @typeName(Procs), field.name, found },
            ));
        }
    }
    for (rows) |row_list| {
        for (row_list) |row| {
            var named = false;
            for (fields) |field| {
                named = named or std.mem.eql(u8, row.field, field.name);
            }
            if (!named) {
                @compileError(std.fmt.comptimePrint(
                    "{s} names no field of {s}",
                    .{ row.symbol, @typeName(Procs) },
                ));
            }
        }
    }
}

/// The dispatch field name of a Vulkan symbol: the symbol without its
/// `vk` prefix, in snake_case. A lower-case letter or digit before an
/// upper-case one starts a word, and so does an upper-case run that is
/// followed by a lower-case letter, which is what puts the `_ext` in
/// `cmd_set_device_mask_ext` rather than `_e_x_t`.
fn snakeCase(buffer: []u8, symbol: []const u8) []const u8 {
    // `all_rows` is the only caller and every row names a `vk` symbol,
    // so the slice below cannot be short. The guard states that rather
    // than leaving it to the reader, and it is a compile error because a
    // row without the prefix is a defect in this file, not an input.
    if (symbol.len < vk_prefix_len) {
        @compileError("a Vulkan symbol row must carry the vk prefix");
    }
    const name = symbol[vk_prefix_len..];
    // The only caller sizes the buffer from `all_rows`, so this cannot
    // fire: the assertion states the relationship rather than reporting
    // a failure.
    std.debug.assert(name.len * 2 <= buffer.len);
    var index: usize = 0;
    for (name, 0..) |character, position| {
        if (std.ascii.isUpper(character) and position != 0) {
            const previous = name[position - 1];
            const next = if (position + 1 < name.len) name[position + 1] else ' ';
            if (std.ascii.isLower(previous) or std.ascii.isDigit(previous) or
                std.ascii.isLower(next))
            {
                buffer[index] = '_';
                index += 1;
            }
        }
        buffer[index] = std.ascii.toLower(character);
        index += 1;
    }
    return buffer[0..index];
}
test "a result code keeps its Vulkan name" {
    try std.testing.expectEqualStrings(
        "VK_SUCCESS",
        vkResultName(vulkan.VK_SUCCESS),
    );
    try std.testing.expectEqualStrings(
        "VK_ERROR_DEVICE_LOST",
        vkResultName(vulkan.VK_ERROR_DEVICE_LOST),
    );
    // A code no port names. The number is the caller's to format
    // (`docs/30-port-design.md` §5.3).
    try std.testing.expectEqualStrings(
        "VkResult(unmapped)",
        vkResultName(-2_000_000_000),
    );
}

test "checkVkSuccess fails with the error the code classifies to" {
    try checkVkSuccess(vulkan.VK_SUCCESS);
    try std.testing.expectError(
        error.DeviceLost,
        checkVkSuccess(vulkan.VK_ERROR_DEVICE_LOST),
    );
    try std.testing.expectError(
        error.OutOfHostMemory,
        checkVkSuccess(vulkan.VK_ERROR_OUT_OF_HOST_MEMORY),
    );
    try std.testing.expectError(
        error.UnknownResult,
        checkVkSuccess(-2_000_000_000),
    );
    // `VK_INCOMPLETE` is a value to `classify` and a failure to a check
    // function, which cannot hand a value back.
    try std.testing.expectError(
        error.UnexpectedOutcome,
        checkVkSuccess(vulkan.VK_INCOMPLETE),
    );
}

test "checkVkOomThenSuccess turns the injected code into an allocation failure" {
    try checkVkOomThenSuccess(vulkan.VK_SUCCESS);
    try std.testing.expectError(
        error.OutOfDeviceMemory,
        checkVkOomThenSuccess(injected_device_oom_result),
    );
    try std.testing.expectError(
        error.DeviceLost,
        checkVkOomThenSuccess(vulkan.VK_ERROR_DEVICE_LOST),
    );
}

test "an enabled-extension set holds only what was put in it" {
    const none: EnabledDeviceExts = .{};
    try std.testing.expect(!none.has(.swapchain));
    try std.testing.expect(none.with(.swapchain).has(.swapchain));
    try std.testing.expect(!none.with(.swapchain).has(.dynamic_rendering));
}
