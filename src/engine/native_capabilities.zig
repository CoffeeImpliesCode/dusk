//! Native capabilities derive from queried physical records, never null defaults.
const command_constants = @import("../command/constants.zig");
const layout_internal = @import("../pipeline/layout_internal.zig");
const vulkan = @import("vulkan");
const native = @import("vulkan_device.zig");
const physical = @import("physical_device.zig");
const features = @import("features.zig");
const limits = @import("limits.zig");

pub fn offeredLimits(device: *const native.PhysicalDevice) limits.CombinedLimits {
    const l = device.properties.limits;
    const stage_count: u32 = @intCast(layout_internal.ShaderStages.stage_count);
    // A layout can contain distinct bindings for all three visibility stages.
    var sampled = @min(l.maxPerStageDescriptorSampledImages, @divFloor(l.maxDescriptorSetSampledImages, stage_count));
    const samplers = @min(l.maxPerStageDescriptorSamplers, @divFloor(l.maxDescriptorSetSamplers, stage_count));
    var uniform = @min(l.maxPerStageDescriptorUniformBuffers, @divFloor(l.maxDescriptorSetUniformBuffers, stage_count));
    var storage = @min(l.maxPerStageDescriptorStorageBuffers, @divFloor(l.maxDescriptorSetStorageBuffers, stage_count));
    var images = @min(l.maxPerStageDescriptorStorageImages, @divFloor(l.maxDescriptorSetStorageImages, stage_count));
    // Fragment color attachments count toward maxPerStageResources. Samplers do not.
    const color_attachments = @min(
        @min(l.maxPerStageResources, l.maxFragmentCombinedOutputResources),
        @min(l.maxColorAttachments, l.maxFragmentOutputAttachments),
    );
    const resource_budget = l.maxPerStageResources - color_attachments;
    const resource_count = @as(u64, sampled) + uniform + storage + images;
    if (resource_count > resource_budget) {
        sampled = @min(sampled, resourceShare(.max_sampled_textures_per_shader_stage, resource_budget));
        uniform = @min(uniform, resourceShare(.max_uniform_buffers_per_shader_stage, resource_budget));
        storage = @min(storage, resourceShare(.max_storage_buffers_per_shader_stage, resource_budget));
        images = @min(images, resourceShare(.max_storage_textures_per_shader_stage, resource_budget));
    }
    // PhysicalDeviceVk.cpp:834-863 shares this fragment output budget.
    // Do not ignore queried values below the WebGPU baseline.
    const fragment_budget = l.maxFragmentCombinedOutputResources - color_attachments;
    if (@as(u64, storage) + images > fragment_budget) {
        const storage_weight = comptime limits.defaultValue(.max_storage_buffers_per_shader_stage, .core);
        const image_weight = comptime limits.defaultValue(.max_storage_textures_per_shader_stage, .core);
        const baseline_count = storage_weight + image_weight;
        storage = @min(storage, @as(u32, @intCast(@divFloor(
            @as(u64, fragment_budget) * storage_weight,
            baseline_count,
        ))));
        images = @min(images, @as(u32, @intCast(@divFloor(
            @as(u64, fragment_budget) * image_weight,
            baseline_count,
        ))));
    }
    const bind_groups = @min(l.maxBoundDescriptorSets, command_constants.max_bind_groups);
    // LayoutInput.immediateMask has one bit for each four-byte immediate word.
    const immediate_capacity = @bitSizeOf(u64) * command_constants.immediate_element_byte_size;
    const inter_stage_components = @min(l.maxVertexOutputComponents, l.maxFragmentInputComponents);
    // Reserve the position output before advertising user varyings.
    const user_inter_stage_components = inter_stage_components -| 4;
    const fragment_stores_enabled = device.features.fragmentStoresAndAtomics == vulkan.VK_TRUE;
    const vertex_stores_enabled = device.features.vertexPipelineStoresAndAtomics == vulkan.VK_TRUE;
    return .{
        .v1 = .{
            .max_compute_workgroup_storage_size = l.maxComputeSharedMemorySize,
            .max_compute_invocations_per_workgroup = l.maxComputeWorkGroupInvocations,
            .max_compute_workgroup_size_x = l.maxComputeWorkGroupSize[0],
            .max_compute_workgroup_size_y = l.maxComputeWorkGroupSize[1],
            .max_compute_workgroup_size_z = l.maxComputeWorkGroupSize[2],
            .max_compute_workgroups_per_dimension = @min(
                l.maxComputeWorkGroupCount[0],
                @min(l.maxComputeWorkGroupCount[1], l.maxComputeWorkGroupCount[2]),
            ),
            .max_storage_buffer_binding_size = @min(device.max_buffer_size, l.maxStorageBufferRange),
            .max_buffer_size = device.max_buffer_size,
            .max_dynamic_uniform_buffers_per_pipeline_layout = l.maxDescriptorSetUniformBuffersDynamic,
            .max_dynamic_storage_buffers_per_pipeline_layout = l.maxDescriptorSetStorageBuffersDynamic,
            .max_sampled_textures_per_shader_stage = sampled,
            .max_samplers_per_shader_stage = samplers,
            .max_storage_textures_per_shader_stage = images,
            .max_uniform_buffers_per_shader_stage = uniform,
            .max_storage_buffers_per_shader_stage = storage,
            // Every supported color format occupies at most sixteen bytes per sample.
            .max_color_attachment_bytes_per_sample = color_attachments *| 16,
            .max_inter_stage_shader_variables = @divFloor(user_inter_stage_components, 4),
            .max_texture_dimension_1d = l.maxImageDimension1D,
            .max_texture_dimension_2d = @min(
                l.maxImageDimension2D,
                @min(l.maxFramebufferWidth, l.maxFramebufferHeight),
            ),
            .max_texture_dimension_3d = l.maxImageDimension3D,
            .max_texture_array_layers = l.maxImageArrayLayers,
            .max_immediate_size = @min(l.maxPushConstantsSize, immediate_capacity),
            .max_bind_groups = bind_groups,
            .max_bind_groups_plus_vertex_buffers = bind_groups +| l.maxVertexInputBindings,
            .max_bindings_per_bind_group = @min(
                device.max_per_set_descriptors,
                layout_internal.max_bindings_per_bind_group,
            ),
            .max_uniform_buffer_binding_size = @min(device.max_buffer_size, l.maxUniformBufferRange),
            .min_uniform_buffer_offset_alignment = @intCast(@max(1, l.minUniformBufferOffsetAlignment)),
            .min_storage_buffer_offset_alignment = @intCast(@max(1, l.minStorageBufferOffsetAlignment)),
            .max_vertex_buffers = l.maxVertexInputBindings,
            .max_vertex_attributes = l.maxVertexInputAttributes,
            .max_vertex_buffer_array_stride = l.maxVertexInputBindingStride,
            .max_color_attachments = color_attachments,
        },
        .compatibility = .{
            .max_storage_textures_in_fragment_stage = if (fragment_stores_enabled) images else 0,
            .max_storage_textures_in_vertex_stage = if (vertex_stores_enabled) images else 0,
            .max_storage_buffers_in_fragment_stage = if (fragment_stores_enabled) storage else 0,
            .max_storage_buffers_in_vertex_stage = if (vertex_stores_enabled) storage else 0,
        },
    };
}

/// Divide the combined budget in the core baseline's resource proportions.
/// Floors keep the sum bounded and preserve the baseline when its budget fits.
/// Dawn reserves baseline resources before sharing excess at
/// PhysicalDeviceVk.cpp:834-863, pinned by tools/dawn_pin.zon. This map also
/// accounts for maxPerStageResources and whole-layout descriptor budgets.
fn resourceShare(comptime field: limits.Field, resource_budget: u32) u32 {
    const baseline_count = comptime limits.defaultValue(.max_sampled_textures_per_shader_stage, .core) +
        limits.defaultValue(.max_uniform_buffers_per_shader_stage, .core) +
        limits.defaultValue(.max_storage_buffers_per_shader_stage, .core) +
        limits.defaultValue(.max_storage_textures_per_shader_stage, .core);
    const weight = comptime limits.defaultValue(field, .core);
    return @intCast(@divFloor(
        @as(u64, resource_budget) * weight,
        baseline_count,
    ));
}

fn supportsLevel(offered: limits.CombinedLimits, level: limits.FeatureLevel) bool {
    const required = limits.defaultLimits(level);
    inline for (limits.rows) |row| {
        const name = @tagName(row.field);
        const value: u64 = switch (row.scope) {
            .v1 => @field(required.v1, name),
            .compat => @field(required.compatibility.?, name),
        };
        const supported: u64 = switch (row.scope) {
            .v1 => @field(offered.v1, name),
            .compat => @field(offered.compatibility.?, name),
        };
        limits.checkLimit(row.class, supported, value) catch return false;
    }
    return true;
}

/// Hardware admission follows PhysicalDeviceVk.cpp:234-284 at tools/dawn_pin.zon.
/// Compression satisfies this hardware baseline, not optional public feature support.
/// The exposed feature subset below does not claim full Dawn Core parity.
fn supportsCoreFeatures(queried: *const vulkan.VkPhysicalDeviceFeatures) bool {
    const compression = queried.textureCompressionBC == vulkan.VK_TRUE or
        (queried.textureCompressionETC2 == vulkan.VK_TRUE and
            queried.textureCompressionASTC_LDR == vulkan.VK_TRUE);
    return compression and queried.independentBlend == vulkan.VK_TRUE and
        queried.depthBiasClamp == vulkan.VK_TRUE and
        queried.fullDrawIndexUint32 == vulkan.VK_TRUE and
        queried.imageCubeArray == vulkan.VK_TRUE and
        queried.sampleRateShading == vulkan.VK_TRUE and
        queried.fragmentStoresAndAtomics == vulkan.VK_TRUE and
        queried.shaderUniformBufferArrayDynamicIndexing == vulkan.VK_TRUE and
        queried.shaderStorageBufferArrayDynamicIndexing == vulkan.VK_TRUE and
        queried.shaderSampledImageArrayDynamicIndexing == vulkan.VK_TRUE and
        queried.shaderStorageImageArrayDynamicIndexing == vulkan.VK_TRUE;
}

/// The name borrows device storage. Call with the final stable native record.
pub fn fromNative(device: *const native.PhysicalDevice) physical.PhysicalDevice {
    const offered = offeredLimits(device);
    const robust = device.features.robustBufferAccess == vulkan.VK_TRUE;
    const core = robust and supportsLevel(offered, .core) and supportsCoreFeatures(&device.features);
    var supported: features.FeaturesSet = .{};
    if (core) supported.enable(.core_features_and_limits);
    if (device.features.depthClamp == vulkan.VK_TRUE) supported.enable(.depth_clip_control);
    if (device.features.drawIndirectFirstInstance == vulkan.VK_TRUE)
        supported.enable(.indirect_first_instance);
    if (device.supportsTimestampQueries()) supported.enable(.timestamp_query);
    return .{
        .backend_type = .vulkan,
        .feature_levels = .{ .core = core, .compatibility = robust and supportsLevel(offered, .compatibility) },
        .vendor_id = device.properties.vendorID,
        .device_id = device.properties.deviceID,
        .name = device.deviceName(),
        .vendor_name = "",
        .architecture_name = "",
        .adapter_type = switch (device.properties.deviceType) {
            vulkan.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => .discrete_gpu,
            vulkan.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => .integrated_gpu,
            vulkan.VK_PHYSICAL_DEVICE_TYPE_CPU => .cpu,
            else => .unknown,
        },
        .subgroup_min_size = 0,
        .subgroup_max_size = 0,
        .supports_external_images = false,
        .supported_features = supported,
        .limits = offered,
        .maintenance4_supported = device.maintenance4_supported,
        .maintenance4_extension = device.maintenance4_extension,
    };
}
