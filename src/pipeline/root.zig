//! `pipeline`: shader modules, pipelines, layouts and the caches.
//!
//! **What this module is.** `docs/10-architecture.md` "Module boundaries" gives
//! `pipeline` the shader modules, the render and compute pipelines, the bind
//! group layouts and the caches. It holds a descriptor and the object the cache
//! returns; the identity of a cached pipeline is the bytes
//! `buildRenderPipelineKey` and `buildComputePipelineKey` write, with the
//! layout's own bytes the first state field in each.
//!
//! **What this module does not claim.** It does not claim to execute anything.
//! Creating a pipeline records state and, through the `Backend` seam, asks the
//! back end for a handle; running the pipeline is `engine`'s job and the
//! recorded commands that use it are `command`'s. Nor does it claim to hold a
//! shader: SPIR-V bytes go in, the module validates and reflects them, and the
//! caller's own words reach `vkCreateShaderModule`.
//!
//! **What it does not claim either.** It does not claim Dawn's reference
//! counting, its `WeakRef` promotion or its specialisation map. The port's
//! object lives in the device arena and the store keys on bytes, so one
//! descriptor is one specialisation.
//!
//! **How to read this file.** Every sibling is re-exported under its own file
//! name, so the whole surface of a file is reachable as `pipeline.<file_name>`
//! and nothing here has to be kept in step when a file grows. A name is also
//! re-exported flat when a consumer outside this module already reaches it that
//! way; `test/compatibility.zig` is the only one today.

// --- the descriptor, the object and the cache ------------------------------

/// `pipeline.zig`: the pipeline descriptor, the cached object, the two create
/// calls and the cache keys.
pub const pipeline = @import("pipeline.zig");
/// `pipeline_backend.zig`: the seam a create call reaches the back end through,
/// so a caller can test the front end with no device.
pub const pipeline_backend = @import("pipeline_backend.zig");
/// `cache.zig`: the two caches — the in-process object cache that decides
/// "same pipeline or a new one", and the bounded set of `VkPipelineCache`
/// handles.
pub const cache = @import("cache.zig");
/// `cache_key.zig`: the bytes a cache entry is found by.
pub const cache_key = @import("cache_key.zig");

// --- the binding counts the descriptor is checked against ------------------

/// `pipeline_binding_info.zig`: one layout's fold over its entries, the
/// per-stage counts it produces and the limits it is checked against.
pub const pipeline_binding_info = @import("pipeline_binding_info.zig");

// --- the two pipelines ------------------------------------------------------

/// `pipeline_render.zig`: the render half, with the descriptor validator, the
/// state a created pipeline keeps and the conversion to Vulkan enumerations.
pub const pipeline_render = @import("pipeline_render.zig");
/// `pipeline_compute.zig`: the compute half.
pub const pipeline_compute = @import("pipeline_compute.zig");

// --- the shader modules -----------------------------------------------------

/// `shader_module.zig`: the module object, its content hash and the two create
/// calls, one of which answers an invalid module with an error module rather
/// than with an error.
pub const shader_module = @import("shader_module.zig");
/// `shader_module_vk.zig`: the `VkShaderModule` half of that object.
pub const shader_module_vk = @import("shader_module_vk.zig");
/// `shader_reflect.zig`: the layout the reflected SPIR-V declares.
pub const shader_reflect = @import("shader_reflect.zig");
/// `shader_compilation_messages.zig`: the messages and the log a caller reads
/// back off a module.
pub const shader_compilation_messages = @import("shader_compilation_messages.zig");

// --- the layouts ------------------------------------------------------------

/// `bind_group_layout.zig`: the front end layout object and the compatibility
/// token its key carries.
pub const bind_group_layout = @import("bind_group_layout.zig");
/// `layout_internal.zig`: the packed layout the front end folds into, with no
/// Vulkan type in it.
pub const layout_internal = @import("layout_internal.zig");
/// `layout_vk.zig`: the `VkDescriptorSetLayout` and `VkPipelineLayout` half.
pub const layout_vk = @import("layout_vk.zig");
/// `bind_group_descriptor_set.zig`: pools of pre-allocated descriptor sets,
/// freed by GPU serial rather than at once.
pub const bind_group_descriptor_set = @import("bind_group_descriptor_set.zig");

// --- the flat names `test/compatibility.zig` reaches -----------------------

/// One shader stage.
pub const Stage = pipeline.Stage;
/// The counts a layout folds to, per stage and in total.
pub const BindingCounts = pipeline.BindingCounts;
/// The subset of the device limits that fold is checked against.
pub const BindingLimits = pipeline.BindingLimits;
/// Every rule a descriptor can break, one member per upstream `DAWN_INVALID_IF`
/// site.
pub const PipelineError = pipeline.PipelineError;
/// The options `validateStage` reads.
pub const StageValidationOptions = pipeline.StageValidationOptions;
/// `pipeline_binding_info.zig:184`: folds one layout and checks the result.
pub const validateBindingCounts = pipeline.validateBindingCounts;
/// `pipeline.zig:771`: checks one programmable stage against its entry point.
pub const validateStage = pipeline.validateStage;
/// `pipeline_render.zig:410`: the depth-stencil rules, which read the attachment
/// format a render pipeline names.
pub const validateDepthStencil = pipeline_render.validateDepthStencil;
/// `VK_FORMAT_D24_UNORM_S8_UINT`, the one depth-stencil format a pipeline names
/// when it must name one.
pub const depth_format = pipeline.depth_format;
/// `VK_FORMAT_UNDEFINED`, the depth-stencil format a render pipeline names
/// when it has no depth-stencil attachment.
pub const undefined_depth_format = pipeline.undefined_depth_format;
