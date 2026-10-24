//! The Vulkan seam the pipeline path reaches.
//!
//! **What this file is.** The six Vulkan entry points the pipeline path calls. The shape is
//! M13's `shader_module_vk.Device`: injected function pointers and a device
//! handle, so a test supplies its own and a caller never reaches past it.
//!
//! **What this file does not claim.** It does not claim the device. A Dawn
//! pipeline holds its device in `ObjectBase`
//! (`src/dawn/native/ObjectBase.h:106`); the port holds a pointer to this
//! value, and the device owns it, so a pipeline can never outlive the backend
//! that destroys it.

const std = @import("std");
const vulkan = @import("vulkan");

const vk = @import("../vk/dispatch.zig");

/// One entry point the loader did not fill, named rather than left as a bare
/// `.?`. The call site reports which entry point was not loaded.
pub const MissingEntryPoint = error{
    CreateGraphicsPipelinesNotLoaded,
    CreateComputePipelinesNotLoaded,
    CreatePipelineCacheNotLoaded,
    GetPipelineCacheDataNotLoaded,
    DestroyPipelineNotLoaded,
    DestroyPipelineCacheNotLoaded,
};

/// A call the seam could not make: an entry point the loader did not fill, or a
/// `VkResult` the port's one result table classifies
/// (`src/vk/dispatch.zig:1159`), so this union declares no Vulkan code.
pub const BackendError = MissingEntryPoint || vk.Error;

/// The Vulkan device a pipeline is created against, and the six calls M14 makes.
///
/// The six proc fields carry no `?` of their own. The generated bindings
/// already make every `PFN_vk*` an optional pointer (`src/vulkan.zig:5147`,
/// `:5151`), so a `?` here is a second optional: the field would hold two and
/// every call site would have to unwrap twice to reach the pointer. One
/// `orelse` over a bare `PFN_vk*` is the whole unwrap, and `MissingEntryPoint`
/// is what the call site returns when the one it does is null.
pub const Backend = struct {
    device: vulkan.VkDevice,
    create_graphics_pipelines: vulkan.PFN_vkCreateGraphicsPipelines,
    create_compute_pipelines: vulkan.PFN_vkCreateComputePipelines,
    create_pipeline_cache: vulkan.PFN_vkCreatePipelineCache,
    get_pipeline_cache_data: vulkan.PFN_vkGetPipelineCacheData,
    destroy_pipeline: vulkan.PFN_vkDestroyPipeline,
    destroy_pipeline_cache: vulkan.PFN_vkDestroyPipelineCache,

    /// Reads the six fields out of a loaded device tier. The device tier is one
    /// set per device (`src/vk/dispatch.zig:33`), so the procs and the handle
    /// come from the same place and cannot disagree.
    pub fn fromDeviceProcs(device: vulkan.VkDevice, procs: *const vk.DeviceProcs) Backend {
        return .{
            .device = device,
            .create_graphics_pipelines = procs.create_graphics_pipelines,
            .create_compute_pipelines = procs.create_compute_pipelines,
            .create_pipeline_cache = procs.create_pipeline_cache,
            .get_pipeline_cache_data = procs.get_pipeline_cache_data,
            .destroy_pipeline = procs.destroy_pipeline,
            .destroy_pipeline_cache = procs.destroy_pipeline_cache,
        };
    }
};

test "a backend built from a loader tier carries the handle it was given" {
    var device_procs: vk.DeviceProcs = std.mem.zeroes(vk.DeviceProcs);

    const backend = Backend.fromDeviceProcs(null, &device_procs);

    try std.testing.expect(backend.device == null);
    try std.testing.expect(backend.create_graphics_pipelines == null);
    try std.testing.expect(backend.destroy_pipeline == null);
}
