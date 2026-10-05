//! The compute pipeline: one descriptor rule and one `VkComputePipelineCreateInfo`.
//!
//! **What this file is.** Dawn's `ComputePipelineBase`
//! (`src/dawn/native/ComputePipeline.cpp:56`) and `ComputePipeline::InitializeImpl`
//! (`src/dawn/native/vulkan/ComputePipelineVk.cpp:54`).
//!
//! **What this file does not claim.** `GetWorkgroupSize`
//! (`ComputePipeline.cpp:90`) returns an `Extent3D` that Dawn reads out of the
//! Tint program. M5's reflector reads no `OpExecutionMode LocalSize`, so the
//! port has nothing to return and does not pretend otherwise; the workgroup
//! size is M5's table, not this module's. Nothing on the pipeline-creation path
//! needs it — `VkComputePipelineCreateInfo` (`src/vulkan.zig:4649-4658`) carries no
//! workgroup size field.

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

/// The create info, filled. Dawn builds the same struct at
/// `vulkan/ComputePipelineVk.cpp:128-139`.
fn makeCreateInfo(
    descriptor: pipeline.ComputePipelineDescriptor,
) vulkan.VkComputePipelineCreateInfo {
    return .{
        .sType = vulkan.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vulkan.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = descriptor.compute.module,
            .pName = descriptor.compute.entry_point.ptr,
        },
        .layout = descriptor.layout.handle,
    };
}

/// Creates the `VkPipeline` and nothing else.
pub fn createComputePipeline(
    backend: *const Backend,
    layout: vulkan.VkPipelineLayout,
    descriptor: pipeline.ComputePipelineDescriptor,
    pipeline_cache: vulkan.VkPipelineCache,
) BackendError!vulkan.VkPipeline {
    _ = layout;
    const create = backend.create_compute_pipelines orelse
        return error.CreateComputePipelinesNotLoaded;
    var create_info = makeCreateInfo(descriptor);
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
