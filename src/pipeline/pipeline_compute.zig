//! The compute pipeline: one descriptor rule and one `VkComputePipelineCreateInfo`.
//!
//! **What this file is.** Dawn's `ComputePipelineBase`
//! (`src/dawn/native/ComputePipeline.cpp:56`) and `ComputePipeline::InitializeImpl`
//! (`src/dawn/native/vulkan/ComputePipelineVk.cpp:54`).
//!
//! Effective workgroup sizes are resolved from the module before cache lookup.
//! Selected device limits are supplied by the caller, not inferred here.

const std = @import("std");
const vulkan = @import("vulkan");

const vk = @import("../vk/dispatch.zig");

const pipeline = @import("pipeline.zig");
const pipeline_backend = @import("pipeline_backend.zig");

pub const Backend = pipeline_backend.Backend;
pub const BackendError = pipeline_backend.BackendError;
pub const PipelineError = pipeline.PipelineError;

/// Dawn's `ValidateComputePipelineDescriptor` (`ComputePipeline.cpp:37`). A
/// compute descriptor has one stage, so one rule is the whole of it.
pub fn validateComputePipelineDescriptor(
    descriptor: pipeline.ComputePipelineDescriptor,
) PipelineError!void {
    if (descriptor.compute.stage != .compute) return error.StageMismatch;
}

/// Rejects zero dimensions, axis excess, arithmetic overflow and invocation excess.
/// The product uses u64 so three u32 axes cannot wrap into a valid small workgroup.
pub fn validateWorkgroupSize(
    size: [3]u32,
    limits: pipeline.ComputeLimits,
) PipelineError!void {
    var invocations: u64 = 1;
    for (size, limits.max_workgroup_size) |axis, maximum| {
        if (axis == 0) return error.WorkgroupAxisZero;
        if (axis > maximum) return error.WorkgroupAxisAboveLimit;
        invocations = std.math.mul(u64, invocations, axis) catch
            return error.WorkgroupProductOverflow;
    }
    if (invocations > limits.max_invocations) return error.WorkgroupInvocationsAboveLimit;
}

/// The create info, filled. Dawn builds the same struct at
/// `vulkan/ComputePipelineVk.cpp:128-139`.
fn makeCreateInfo(
    descriptor: pipeline.ComputePipelineDescriptor,
    entry_point: [:0]const u8,
    constants: ?*const vulkan.VkSpecializationInfo,
) vulkan.VkComputePipelineCreateInfo {
    return .{
        .sType = vulkan.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vulkan.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = descriptor.compute.module,
            .pName = entry_point.ptr,
            .pSpecializationInfo = constants,
        },
        .layout = descriptor.layout.handle,
    };
}

/// Creates the `VkPipeline`; `constants` and its map/data storage are borrowed
/// through the driver call. Null requests the module's encoded defaults.
/// `entry_point` is the validated stage name with its native terminator.
pub fn createComputePipeline(
    backend: *const Backend,
    constants: ?*const vulkan.VkSpecializationInfo,
    descriptor: pipeline.ComputePipelineDescriptor,
    entry_point: [:0]const u8,
    pipeline_cache: vulkan.VkPipelineCache,
) BackendError!vulkan.VkPipeline {
    const create = backend.create_compute_pipelines orelse
        return error.CreateComputePipelinesNotLoaded;
    var create_info = makeCreateInfo(descriptor, entry_point, constants);
    var handle: vulkan.VkPipeline = null;
    try vk.checkVkSuccess(create(
        backend.device,
        pipeline_cache,
        1,
        &create_info,
        null,
        &handle,
    ));
    return handle;
}
