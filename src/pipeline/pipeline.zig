//! Pipelines: the descriptor, the cached object, and the two create calls.
//!
//! **What this file is.** Dawn's `PipelineBase`
//! (`src/dawn/native/Pipeline.h:71`) with the two leaves that hang off it and
//! the device cache that decides whether a leaf is built at all. Keys identify
//! the actual canonical layout owner, or the raw layout's definition bytes.
//! The two ownership domains never share a cached pipeline.
//!
//! Every successful guarded create returns one reference of the caller's
//! required user/lease class, including cache hits. The weak index borrows
//! arena objects and evicts before payload retirement. All cache and payload
//! access uses the canonical ObjectList guard.
//!
//! **What it does not claim either.** Attachment formats are `VkFormat`, not
//! the WebGPU `TextureFormat`. M7 owns the WebGPU format table and the
//! conversion, and a Vulkan pipeline needs the Vulkan value for attachment
//! compatibility with its traditional render pass.
//! Naming the Vulkan value here keeps one table instead of two.

const std = @import("std");
const vulkan = @import("vulkan");

const api = @import("../api/root.zig");
const core = @import("../core/root.zig");
const command_constants = @import("../command/constants.zig");
const dispatch = @import("../vk/dispatch.zig");
const spirv = @import("../spirv/root.zig");
const specialization = @import("specialization.zig");

const cache = @import("cache.zig");
const pipeline_backend = @import("pipeline_backend.zig");
const pipeline_binding_info = @import("pipeline_binding_info.zig");
const pipeline_compute = @import("pipeline_compute.zig");
const pipeline_render = @import("pipeline_render.zig");
const layout_internal = @import("layout_internal.zig");
const layout_vk = @import("layout_vk.zig");

pub const Backend = pipeline_backend.Backend;
pub const Cache = cache.Cache;
pub const LruCache = cache.LruCache;

/// The attachment-format type, re-exported so a consumer that holds no Vulkan
/// import can still name one. `VkFormat` is a `c_uint` at this pin
/// (`src/vulkan.zig:2867` names it `enum_VkFormat`), not an enumeration, so
/// its members are the `VK_FORMAT_*` constants.
pub const VkFormat = vulkan.VkFormat;

/// A depth-stencil attachment format, for a caller with no Vulkan import.
pub const depth_format: VkFormat = vulkan.VK_FORMAT_D24_UNORM_S8_UINT;

/// The format a render pipeline names when it has no depth-stencil attachment.
/// `validateDepthStencil` reads the pair, and a real format beside a null state
/// is its own error (`pipeline_render.zig:414-417`), so a caller asking
/// whether a pipeline has no depth-stencil needs this value and not a second
/// rule.
pub const undefined_depth_format: VkFormat = vulkan.VK_FORMAT_UNDEFINED;
pub const BindingCounts = pipeline_binding_info.BindingCounts;
pub const BindingLimits = pipeline_binding_info.BindingLimits;
pub const validateBindingCounts = pipeline_binding_info.validateBindingCounts;
pub const CacheKey = cache.CacheKey;
pub const ColorTargetState = pipeline_render.ColorTargetState;
pub const DepthStencilState = pipeline_render.DepthStencilState;
pub const MultisampleState = pipeline_render.MultisampleState;
pub const PrimitiveState = pipeline_render.PrimitiveState;
pub const VertexAttributeLayout = pipeline_render.VertexAttributeLayout;
pub const VertexBufferLayout = pipeline_render.VertexBufferLayout;
pub const VertexFormat = pipeline_render.VertexFormat;

/// One shader stage. Dawn's `SingleShaderStage`
/// (`src/dawn/native/PerStage.h:41`) has these same three members. A
/// `ProgrammableStage` (`src/dawn/native/Pipeline.h:59`) does not carry the
/// stage; `ValidateProgrammableStage` takes it beside the stage record
/// (`src/dawn/native/Pipeline.h:57`), and `StageInput` below does the same.
pub const Stage = enum {
    vertex,
    fragment,
    compute,
};

/// The bit in `StageInput`'s mask. `0` is not a member: a stage mask with no
/// stage set is a descriptor error, so the count starts at one.
pub const stage_count = @typeInfo(Stage).@"enum".fields.len;

/// What the reflected entry point uses, as Dawn's `EntryPointMetadata`
/// (`src/dawn/native/Pipeline.cpp:120`) carries it.
///
/// Every field is a plain value with a default. The port reads no shader and
/// holds no module to read one from, so the caller reports what reflection
/// found; M13 fills this from the SPIR-V it already validated.
pub const StageUsage = struct {
    /// `Pipeline.cpp:138`.
    texture_load_with_depth_texture: bool = false,
    /// `Pipeline.cpp:144`.
    depth_texture_with_non_comparison_sampler: bool = false,
    /// `Pipeline.cpp:149`.
    fine_derivative_builtin: bool = false,
    /// `Pipeline.cpp:157` counts the combinations and `:159` compares them
    /// with `min(maxSampledTexturesPerShaderStage, maxSamplersPerShaderStage)`.
    texture_sampler_combination_count: u32 = 0,
    frag_depth: bool = false,
    sample_index: bool = false,
    vertex_index: bool = false,
    instance_index: bool = false,
};

/// One programmable stage: the module, the entry point inside it, and what that
/// entry point uses.
pub const StageInput = struct {
    /// Handed to `vkCreate*Pipelines` unexamined, so `null` is legal here and
    /// only a driver rejects it.
    module: vulkan.VkShaderModule = null,
    entry_point: []const u8 = "",
    stage: Stage = .vertex,
    /// Authoritative SPIR-V bytes for this native module. They must match
    /// `module`; compute creation always validates and reflects these bytes.
    content_bytes: []const u8 = &.{},
    /// Borrowed overrides; an empty slice requests the module's defaults.
    /// Keys are canonical decimal SpecIds or unambiguous OpName aliases.
    /// Values are finite f64 scalars converted to the declaration's type.
    /// Keep the entries and their key bytes alive and unchanged during creation
    /// and cache-key construction.
    constants: []const api.descriptors.ConstantEntry = &.{},
    usage: StageUsage = .{},
};

/// Cache-key preparation failures. Invalid overrides never reach a cache lookup.
pub const KeyError = spirv.ErrorOrOutOfMemory || specialization.Error;

/// Compute preparation includes authoritative entry-point and device-limit validation.
pub const ComputeError = KeyError || PipelineError || spirv.Module.WorkgroupError;

fn prepareCompute(
    allocator: std.mem.Allocator,
    descriptor: ComputePipelineDescriptor,
) ComputeError!specialization.Specialization {
    try pipeline_compute.validateComputePipelineDescriptor(descriptor);
    if (descriptor.compute.content_bytes.len == 0) return error.ComputeStageMissing;
    const words = try spirv.wordsFromBytes(allocator, descriptor.compute.content_bytes);
    defer allocator.free(words);
    try spirv.validate(words);
    const reflected = try spirv.reflect(allocator, words);
    defer reflected.deinit();
    var selected: ?spirv.EntryPoint = null;
    var named_wrong_model = false;
    for (reflected.entry_points) |entry| {
        if (!std.mem.eql(u8, entry.name, descriptor.compute.entry_point)) continue;
        if (entry.execution_model != .gl_compute) {
            named_wrong_model = true;
            continue;
        }
        if (selected != null) return error.EntryPointCountAboveLimit;
        selected = entry;
    }
    const entry = selected orelse {
        if (named_wrong_model) return error.StageMismatch;
        return error.StageMissingForEntryPoint;
    };
    if (entry.has_local_size_id and !descriptor.local_size_id_supported) {
        return error.LocalSizeIdUnsupported;
    }
    var constants = try specialization.Specialization.init(
        allocator,
        reflected.specialization_constants,
        descriptor.compute.constants,
    );
    errdefer constants.deinit(allocator);
    const size = try reflected.resolveWorkgroupSizeCanonical(entry.id, constants.canonical_bytes);
    try pipeline_compute.validateWorkgroupSize(size, descriptor.limits);
    return constants;
}

fn prepareSpecialization(
    allocator: std.mem.Allocator,
    stage: StageInput,
) KeyError!specialization.Specialization {
    if (stage.constants.len == 0) return specialization.Specialization.init(allocator, &.{}, &.{});
    const words = try spirv.wordsFromBytes(allocator, stage.content_bytes);
    defer allocator.free(words);
    try spirv.validate(words);
    const reflected = try spirv.reflect(allocator, words);
    defer reflected.deinit();
    return specialization.Specialization.init(
        allocator,
        reflected.specialization_constants,
        stage.constants,
    );
}

/// Descriptor set layout contents. Handles may differ for identical definitions.
/// `fromInternal` and `clone` return owned arrays released with `deinit`.
pub const GroupLayout = struct {
    handle: vulkan.VkDescriptorSetLayout,
    bindings: []const vulkan.VkDescriptorSetLayoutBinding,
    has_external_texture: bool = false,
    /// Zero identifies ordinary layouts. Automatic layouts share one nonzero token.
    compatibility_token: u64 = 0,
    /// Sum of physical combined-image-sampler descriptors needed for one set.
    combined_image_sampler_descriptor_count: u32 = 0,

    /// Builds public-number native definitions with owned immutable sampler arrays.
    pub fn fromInternal(
        allocator: std.mem.Allocator,
        handle: vulkan.VkDescriptorSetLayout,
        internal: *const layout_internal.Layout,
        immutable_samplers: []const layout_vk.ImmutableSamplerBinding,
    ) layout_vk.Error!GroupLayout {
        var external = false;
        for (internal.entries) |entry| {
            if (entry.layout == .external_texture) external = true;
        }
        const combined_count = try layout_vk.combinedImageSamplerDescriptorCount(internal);
        return .{
            .handle = handle,
            .bindings = try layout_vk.descriptorBindings(allocator, internal, immutable_samplers),
            .has_external_texture = external,
            .combined_image_sampler_descriptor_count = combined_count,
        };
    }

    /// Copies all descriptor definitions, including immutable sampler arrays.
    pub fn clone(self: GroupLayout, allocator: std.mem.Allocator) std.mem.Allocator.Error!GroupLayout {
        const bindings = try allocator.dupe(vulkan.VkDescriptorSetLayoutBinding, self.bindings);
        var copied: usize = 0;
        errdefer {
            for (bindings[0..copied]) |binding| {
                if (binding.pImmutableSamplers != null) {
                    allocator.free(binding.pImmutableSamplers[0..binding.descriptorCount]);
                }
            }
            allocator.free(bindings);
        }
        for (bindings) |*binding| {
            if (binding.pImmutableSamplers != null) {
                const samplers = try allocator.dupe(
                    vulkan.VkSampler,
                    binding.pImmutableSamplers[0..binding.descriptorCount],
                );
                binding.pImmutableSamplers = samplers.ptr;
            }
            copied += 1;
        }
        return .{
            .handle = self.handle,
            .bindings = bindings,
            .has_external_texture = self.has_external_texture,
            .compatibility_token = self.compatibility_token,
            .combined_image_sampler_descriptor_count = self.combined_image_sampler_descriptor_count,
        };
    }

    /// Releases owned definitions and invalidates self, without destroying the Vulkan handle.
    pub fn deinit(self: *GroupLayout, allocator: std.mem.Allocator) void {
        layout_vk.freeDescriptorBindings(allocator, self.bindings);
        self.* = undefined;
    }

    /// Compares descriptor definitions without relying on Vulkan handle identity.
    pub fn compatible(self: GroupLayout, other: GroupLayout) bool {
        if (self.compatibility_token != other.compatibility_token) return false;
        if (self.combined_image_sampler_descriptor_count != other.combined_image_sampler_descriptor_count)
            return false;
        if (self.has_external_texture != other.has_external_texture) return false;
        if (self.bindings.len != other.bindings.len) return false;
        for (self.bindings, other.bindings) |left, right| {
            if (left.binding != right.binding or left.descriptorType != right.descriptorType or
                left.descriptorCount != right.descriptorCount or left.stageFlags != right.stageFlags)
                return false;
            if ((left.pImmutableSamplers == null) != (right.pImmutableSamplers == null)) return false;
            if (left.pImmutableSamplers != null) {
                if (!std.mem.eql(
                    vulkan.VkSampler,
                    left.pImmutableSamplers[0..left.descriptorCount],
                    right.pImmutableSamplers[0..right.descriptorCount],
                )) return false;
            }
        }
        return true;
    }
};

/// Native layout input and its replay definitions.
///
/// Canonical inputs must describe their owner's exact immutable native layout.
/// Standalone inputs borrow a caller-owned native handle through pipeline retirement.
pub const LayoutInput = struct {
    handle: vulkan.VkPipelineLayout = null,
    content_bytes: []const u8 = &.{},
    /// Null selects standalone raw ownership. Otherwise the factory retains this actual owner.
    canonical_layout_header: ?*core.Object = null,
    /// Zero identifies ordinary layouts. Every group must use this same token.
    compatibility_token: u64 = 0,
    /// Canonical groups stay immutable under the retained layout lease.
    /// Raw groups are borrowed only during creation. At most `command.constants.max_bind_groups`.
    groups: []const GroupLayout = &.{},
    /// Offset-zero, all-stage native push constant range; zero means no range.
    immediate_size: u32 = 0,

    /// Creates a native layout from these exact groups and immediate range.
    /// The returned input borrows `groups`; the caller destroys its native handle.
    pub fn create(
        procs: *const dispatch.DeviceProcs,
        device: vulkan.VkDevice,
        groups: []const GroupLayout,
        immediate_size: u32,
    ) layout_vk.Error!LayoutInput {
        const input: LayoutInput = .{ .groups = groups, .immediate_size = immediate_size };
        _ = input.immediateMask() catch return error.ImmediateSizeInvalid;
        if (groups.len > command_constants.max_bind_groups) return error.TooManyBindGroups;
        var handles: [command_constants.max_bind_groups]vulkan.VkDescriptorSetLayout = @splat(null);
        for (groups, 0..) |group, index| handles[index] = group.handle;
        return .{
            .handle = try layout_vk.createPipelineLayout(
                procs,
                device,
                handles[0..groups.len],
                immediate_size,
            ),
            .groups = groups,
            .immediate_size = immediate_size,
        };
    }

    /// One bit per covered four-byte word. Replay supports at most 64 words.
    pub fn immediateMask(self: LayoutInput) error{ImmediateSizeInvalid}!u64 {
        if (self.immediate_size > 256 or self.immediate_size % 4 != 0)
            return error.ImmediateSizeInvalid;
        const words = self.immediate_size / 4;
        return if (words == 64) std.math.maxInt(u64) else (@as(u64, 1) << @as(u6, @intCast(words))) - 1;
    }

    /// Empty descriptor sets do not require a bound group at draw or dispatch.
    pub fn bindGroupMask(self: LayoutInput) error{BindGroupCountAboveLimit}!u8 {
        if (self.groups.len > command_constants.max_bind_groups) return error.BindGroupCountAboveLimit;
        var mask: u8 = 0;
        for (self.groups, 0..) |group, index| {
            if (group.bindings.len != 0) mask |= @as(u8, 1) << @as(u3, @intCast(index));
        }
        return mask;
    }
};

/// Every rule a descriptor can break. One member per `DAWN_INVALID_IF` site, so
/// a caller matches on the rule instead of on the message text
/// (`AGENTS.md` §2).
pub const PipelineError = error{
    CompatibleRenderPassMissing,
    ImmediateSizeInvalid,
    BindGroupCountAboveLimit,
    ExternalTexturePipelineUnsupported,
    // `native/Pipeline.cpp` — `ValidateProgrammableStage` (`:92`).
    StageMissingForEntryPoint,
    StageMismatch,
    EntryPointCountAboveLimit,
    CompatibilityTextureLoadWithDepthTexture,
    CompatibilityDepthTextureWithNonComparisonSampler,
    CompatibilityFineDerivativeBuiltin,
    CompatibilityTextureSamplerCombinationsAboveLimit,
    // `native/RenderPipeline.cpp` — the descriptor validators (`:112`-`:863`).
    FragmentStageMissing,
    VertexAttributeSlotAboveLimit,
    VertexAttributeFormatUnsupported,
    VertexBufferSlotAboveLimit,
    VertexBufferStrideTooSmall,
    PrimitiveTopologyUndefined,
    StripIndexFormatNotSetForStripTopology,
    StripIndexFormatSetForNonStripTopology,
    DepthStencilFormatUndefinedWithDepthStencilState,
    DepthStencilFormatSetWithoutState,
    DepthStencilCompareUndefined,
    DepthCompareUndefinedWithDepthWrite,
    StencilStateWithoutStencilAspect,
    MultisampleCountUnsupported,
    MultisampleCountNotOne,
    SampleMaskNotOne,
    AlphaToCoverageWithSampleCountNotOne,
    ColorTargetCountAboveLimit,
    ColorTargetFormatNotRenderable,
    ColorWriteMaskInvalid,
    BlendFactorUndefined,
    BlendOperationUndefined,
    CompatibilityDepthBiasClampNonZero,
    // `native/ComputePipeline.cpp:37`.
    ComputeStageMissing,
    LocalSizeIdUnsupported,
    WorkgroupAxisZero,
    WorkgroupAxisAboveLimit,
    WorkgroupProductOverflow,
    WorkgroupInvocationsAboveLimit,
    // `native/BindingInfo.cpp:174`.
    StaticSamplerAndExternalTextureInSamePipeline,
    DynamicUniformBuffersAboveLimit,
    DynamicStorageBuffersAboveLimit,
    UniformBuffersPerPipelineLayoutAboveLimit,
    StorageBuffersPerPipelineLayoutAboveLimit,
    SampledTexturesPerShaderStageAboveLimit,
    SamplersPerShaderStageAboveLimit,
    UniformBuffersPerShaderStageAboveLimit,
    StorageBuffersPerShaderStageAboveLimit,
    StorageTexturesPerShaderStageAboveLimit,
    StorageBuffersInVertexStageAboveLimit,
    StorageBuffersInFragmentStageAboveLimit,
    StorageTexturesInVertexStageAboveLimit,
    StorageTexturesInFragmentStageAboveLimit,
};

/// Finite validation, ownership, allocation and native creation failures.
/// A failed factory publishes no handle and transfers no reference.
pub const CreateError = PipelineError || core.ValidationError || core.UnrecoverableError ||
    core.CreateError || core.ReferenceError || ComputeError ||
    pipeline_backend.BackendError;

/// Which pipeline a handle names.
pub const Kind = enum {
    render,
    compute,
};

pub const RenderPipelineDescriptor = struct {
    /// Borrowed through native creation; compatible attachment formats and
    /// sample count at subpass zero. The handle is not part of cache identity.
    compatible_render_pass: vulkan.VkRenderPass,
    label: []const u8 = "",
    layout: LayoutInput = .{},
    vertex: StageInput = .{ .stage = .vertex },
    fragment: ?StageInput = null,
    vertex_buffers: []const VertexBufferLayout = &.{},
    vertex_attributes: []const VertexAttributeLayout = &.{},
    primitive: PrimitiveState = .{},
    depth_stencil: ?DepthStencilState = null,
    multisample: MultisampleState = .{},
    color_targets: []const ColorTargetState = &.{},
};

/// Selected device limits, in invocations per axis and per workgroup.
/// Callers supply negotiated limits, not a pipeline module default.
pub const ComputeLimits = struct {
    max_workgroup_size: [3]u32,
    max_invocations: u32,
};

pub const ComputePipelineDescriptor = struct {
    label: []const u8 = "",
    layout: LayoutInput = .{},
    compute: StageInput = .{ .stage = .compute },
    limits: ComputeLimits,
    /// True only when the Vulkan device enables LocalSizeId execution support.
    /// False rejects that execution mode without rewriting shader words.
    local_size_id_supported: bool = false,
};

/// What the pipeline replay and the cache key need, kept after creation.
pub const RenderState = struct {
    vertex_buffers: std.ArrayList(VertexBufferLayout) = .empty,
    vertex_attributes: std.ArrayList(VertexAttributeLayout) = .empty,
    primitive: PrimitiveState = .{},
    depth_stencil: ?DepthStencilState = null,
    multisample: MultisampleState = .{},
    color_formats: std.ArrayList(vulkan.VkFormat) = .empty,
    color_write_masks: std.ArrayList(u32) = .empty,
    blend_enabled: std.ArrayList(bool) = .empty,
    fragment_stage_present: bool = false,
};

pub const ComputeState = struct {
    /// Owned, terminated native name. Null is unpublished or retired state.
    entry_point: ?[:0]const u8 = null,
};

pub const State = union(enum) {
    render: RenderState,
    compute: ComputeState,
};

/// A loaded `vkDestroyPipeline`.
///
/// `Backend.destroy_pipeline` is `vulkan.PFN_vkDestroyPipeline`, and the
/// generated bindings already make every `PFN_vk*` an optional pointer
/// (`src/vulkan.zig:5152`), so the field adds no second optional and the one
/// `orelse` below reaches the pointer.
/// The `: type` says what the binding is, because the spelling alone does not:
/// `zwanzig` reads the bare call as a constant and asks for `snake_case`, and
/// `AGENTS.md` §2 makes a type `PascalCase`. The two agree once the type is
/// written down.
pub const DestroyPipelineFn: type = std.meta.Child(vulkan.PFN_vkDestroyPipeline);

/// The destroy entry point the seam carries, or the error naming the one it
/// did not. `AGENTS.md` §3.1 makes a missing proc a value and not a panic, and
/// the arena's teardown has no channel to carry one
/// (`DestroyFn` returns `void`, `src/core/object.zig:55`), so the create paths
/// ask here and store what they get.
fn destroyEntryPoint(backend: *const Backend) CreateError!DestroyPipelineFn {
    return backend.destroy_pipeline orelse return error.DestroyPipelineNotLoaded;
}

/// One pipeline. Dawn has two classes and a base
/// (`src/dawn/native/RenderPipeline.h:88`, `ComputePipeline.h:46`,
/// `Pipeline.h:71`); the port has one arena object with a tag, because the
/// two differ in what they are asked and not in how they live.
pub const Pipeline = struct {
    header: core.Object,
    /// The seam `destroy` reaches. The device owns the value, so it outlives
    /// every pipeline the arena holds.
    // Both create paths initialize all payload fields before fallible work;
    // publication follows native creation and successful weak insertion.
    backend: *const Backend = undefined,
    /// The seam's `vkDestroyPipeline`, read once by the create paths. The
    /// teardown below calls this pointer and never unwraps it, so a seam that
    /// cannot destroy is refused at creation with
    /// `error.DestroyPipelineNotLoaded` and not at teardown.
    // SAFETY: assigned by both create paths before `header.attach()`, as the
    // `backend` field above states.
    destroy_pipeline: DestroyPipelineFn = undefined,
    /// Allocator used for owned payload state; outlives its final cleanup.
    // SAFETY: assigned by both create paths before `header.attach()`, as the
    // `backend` field above states.
    allocator: std.mem.Allocator = undefined,
    vk_pipeline: vulkan.VkPipeline = null,
    vk_layout: vulkan.VkPipelineLayout = null,
    /// Owns one actual layout lease. Null means the native layout remains caller-owned.
    canonical_layout_header: ?*core.Object = null,
    compatibility_token: u64 = 0,
    key: CacheKey = CacheKey.init(),
    state: State = .{ .compute = .{} },
    immediate_mask: u64 = 0,
    immediate_size: u32 = 0,
    immediate_stages: vulkan.VkShaderStageFlags = 0,
    bind_group_mask: u8 = 0,
    /// Borrows canonical immutable definitions, or owns a standalone raw snapshot.
    group_layouts: []const GroupLayout = &.{},

    /// Vulkan compatibility for set N requires identical definitions through N
    /// and identical push constant ranges.
    pub fn compatibleForGroup(
        self: *const Pipeline,
        guard: *const core.ObjectGuard,
        other: *const Pipeline,
        index: u32,
    ) bool {
        guard.assertOwns(self.header.tracking);
        guard.assertOwns(other.header.tracking);
        if (self.compatibility_token != other.compatibility_token) return false;
        if (self.immediate_size != other.immediate_size or
            self.immediate_stages != other.immediate_stages) return false;
        if (index >= self.group_layouts.len or index >= other.group_layouts.len) return false;
        for (self.group_layouts[0 .. index + 1], other.group_layouts[0 .. index + 1]) |left, right| {
            if (!left.compatible(right)) return false;
        }
        return true;
    }

    /// Retains a canonical layout and borrows its immutable replay definitions.
    /// Raw input owns no native handle here and copies its replay definitions.
    /// Requires initialized allocator state and no existing layout edge or snapshot.
    pub fn initLayout(
        self: *Pipeline,
        guard: *const core.ObjectGuard,
        input: LayoutInput,
    ) (PipelineError || core.ValidationError || core.ReferenceError ||
        std.mem.Allocator.Error)!void {
        guard.assertOwns(self.header.tracking);
        std.debug.assert(self.group_layouts.len == 0);
        std.debug.assert(self.canonical_layout_header == null);
        try validateCanonicalLayoutLocked(guard, input);
        try validateLayout(input);
        const immediate_mask = try input.immediateMask();
        const bind_group_mask = try input.bindGroupMask();
        if (input.canonical_layout_header) |header| {
            try header.retainLeaseLocked(guard);
            self.canonical_layout_header = header;
            self.group_layouts = input.groups;
        } else {
            const groups = try self.allocator.alloc(GroupLayout, input.groups.len);
            var copied: usize = 0;
            errdefer {
                for (groups[0..copied]) |*group| group.deinit(self.allocator);
                self.allocator.free(groups);
            }
            for (input.groups, groups) |source, *target| {
                target.* = try source.clone(self.allocator);
                copied += 1;
            }
            self.group_layouts = groups;
        }
        self.compatibility_token = input.compatibility_token;
        self.immediate_mask = immediate_mask;
        self.immediate_size = input.immediate_size;
        self.immediate_stages = if (input.immediate_size == 0) 0 else vulkan.VK_SHADER_STAGE_ALL;
        self.bind_group_mask = bind_group_mask;
    }

    /// Reports core payload liveness under its owner guard.
    pub fn isAlive(self: *const Pipeline, guard: *const core.ObjectGuard) bool {
        return self.header.isAlive(guard);
    }

    /// Reads the kind of a borrowed live payload.
    pub fn queryKind(self: *const Pipeline, guard: *const core.ObjectGuard) Kind {
        guard.assertOwns(self.header.tracking);
        return switch (self.state) {
            .render => .render,
            .compute => .compute,
        };
    }

    /// Releases payload state once; the core header retains late alias counts.
    /// The core invokes weak eviction before this callback.
    pub fn destroy(
        self: *Pipeline,
        guard: *const core.ObjectGuard,
        io: std.Io,
        reason: core.DestroyReason,
    ) void {
        _ = reason;
        self.deinitPayloadLocked(guard, io);
    }

    /// Cleans only fields initialized by the factory, including rollback.
    fn deinitPayloadLocked(
        self: *Pipeline,
        guard: *const core.ObjectGuard,
        io: std.Io,
    ) void {
        guard.assertOwns(self.header.tracking);
        if (self.vk_pipeline) |handle| {
            self.destroy_pipeline(self.backend.device, handle, null);
            self.vk_pipeline = null;
        }
        const allocator = self.allocator;
        switch (self.state) {
            // Captured by pointer, not by value: `deinit` frees the buffer the
            // list owns and poisons the list itself
            // (`std/array_list.zig:623`), so a copy would free the bytes and
            // leave the live list pointing at freed memory.
            .render => |*render| {
                render.vertex_buffers.deinit(allocator);
                render.vertex_attributes.deinit(allocator);
                render.color_formats.deinit(allocator);
                render.color_write_masks.deinit(allocator);
                render.blend_enabled.deinit(allocator);
            },
            .compute => |*compute| {
                if (compute.entry_point) |name| allocator.free(name);
                compute.entry_point = null;
            },
        }
        self.key.deinit(allocator);
        const canonical_layout = self.canonical_layout_header;
        if (canonical_layout == null) {
            for (self.group_layouts) |group| {
                var owned = group;
                owned.deinit(allocator);
            }
            allocator.free(self.group_layouts);
        }
        self.group_layouts = &.{};
        self.canonical_layout_header = null;
        self.header.label = "";
        if (canonical_layout) |header| header.releaseLeaseLocked(guard, io);
    }
};

/// Weak pipeline index and bounded native driver-cache ownership.
/// Init borrows the external stable list, never its own address. The store
/// must stay stable from first pipeline publication through eager eviction.
/// Retire/release every indexed payload before deinit; maps outlive callbacks.
pub const PipelineStore = struct {
    /// How many `VkPipelineCache` handles the device keeps before one is
    /// evicted. Dawn creates one per pipeline key and never bounds the set
    /// (`vulkan/DeviceVk.cpp:294`); the port bounds it, because each entry is a
    /// driver allocation and not an arena object.
    pub const pipeline_cache_capacity = 32;

    allocator: std.mem.Allocator,
    objects: *core.ObjectList,
    pipelines: cache.GuardedCache(Pipeline),
    pipeline_caches: cache.LruCache([]const u8, cache.PipelineCache, pipeline_cache_capacity) =
        .init(),

    /// Creates empty caches bound to the caller's allocator and stable list.
    pub fn init(gpa: std.mem.Allocator, objects: *core.ObjectList) PipelineStore {
        return .{
            .allocator = gpa,
            .objects = objects,
            .pipelines = cache.GuardedCache(Pipeline).init(gpa, objects),
        };
    }

    /// Frees cache backing after all payload hooks have evicted. A live weak
    /// entry refuses teardown unchanged. Missing native destroy dispatch keeps
    /// remaining entries valid for retry; successfully destroyed keys are freed.
    pub fn deinit(
        self: *PipelineStore,
        guard: *const core.ObjectGuard,
    ) (cache.PipelineCache.DestroyError || error{ResourceInUse})!void {
        guard.assertOwns(self.objects);
        if (!self.pipelines.isEmpty(guard)) return error.ResourceInUse;
        while (self.pipeline_caches.entries.items.len != 0) {
            const entry = self.pipeline_caches.entries.items[
                self.pipeline_caches.entries.items.len - 1
            ];
            try entry.value.destroy();
            const removed = self.pipeline_caches.remove(self.allocator, entry.key);
            std.debug.assert(removed != null);
            self.allocator.free(entry.key);
        }
        self.pipeline_caches.deinit(self.allocator);
        self.pipelines.deinit(guard);
        self.* = undefined;
    }

    /// Counts live weak entries, excluding retained retired headers.
    pub fn queryPipelineCount(
        self: *const PipelineStore,
        guard: *const core.ObjectGuard,
    ) usize {
        guard.assertOwns(self.objects);
        return self.pipelines.queryEntryCount(guard);
    }

    fn removePipelineLocked(
        context: *anyopaque,
        guard: *const core.ObjectGuard,
        header: *core.Object,
    ) void {
        const self: *PipelineStore = @ptrCast(@alignCast(context));
        guard.assertOwns(self.objects);
        const object: *Pipeline = @fieldParentPtr("header", header);
        self.pipelines.remove(guard, object);
    }
};

/// Creates or acquires one render pipeline reference of the required class.
/// Caller holds the device's guard through lookup, native creation and publish.
/// Store and backend outlive payload retirement; returned handles do not own
/// copies. Balance the class via resolveReference, including after retirement.
/// Failure transfers no reference and leaves existing cached consumers intact.
pub fn createRenderPipelineLocked(
    gpa: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    dev: *core.Device,
    store: *PipelineStore,
    backend: *const Backend,
    descriptor: RenderPipelineDescriptor,
    result_reference_class: core.ReferenceClass,
) CreateError!core.Handle {
    try checkFactoryLocked(gpa, guard, dev, store);
    try validateCanonicalLayoutLocked(guard, descriptor.layout);
    if (descriptor.compatible_render_pass == null) return error.CompatibleRenderPassMissing;
    try pipeline_render.validateRenderPipelineDescriptor(descriptor);
    try validateLayout(descriptor.layout);

    var vertex = try prepareSpecialization(gpa, descriptor.vertex);
    defer vertex.deinit(gpa);
    var fragment = try prepareSpecialization(gpa, descriptor.fragment orelse .{});
    defer fragment.deinit(gpa);
    var key = try buildPreparedRenderKey(gpa, descriptor, &vertex, &fragment);
    defer key.deinit(gpa);

    if (store.pipelines.find(guard, &key)) |found| {
        try acquireCachedReferenceLocked(guard, found, result_reference_class);
        return dev.handleFor(guard, Pipeline, found, .pipeline);
    }

    // A seam that cannot destroy must not create: `Pipeline.destroy` returns
    // `void` and has no way to report the miss, so the entry point is read
    // here, where `CreateError` carries it.
    const destroy_pipeline = try destroyEntryPoint(backend);

    const object = try dev.create(gpa, guard, Pipeline, .{
        .kind = .pipeline,
        .label = descriptor.label,
        .initial_reference = result_reference_class,
    });
    errdefer object.header.discardUnpublishedLocked(guard) catch unreachable;
    object.* = .{
        .header = object.header,
        .backend = backend,
        .destroy_pipeline = destroy_pipeline,
        .allocator = gpa,
        .vk_layout = descriptor.layout.handle,
    };
    errdefer object.deinitPayloadLocked(guard, io);
    try object.initLayout(guard, descriptor.layout);

    var scratch: pipeline_render.Scratch = .{};
    defer scratch.deinit(gpa);
    try pipeline_render.buildRenderState(
        gpa,
        descriptor,
        &object.state,
        &scratch,
    );

    var vertex_info = vertex.info();
    var fragment_info = fragment.info();
    if (vertex.map_entries.len != 0) scratch.stages[0].pSpecializationInfo = &vertex_info;
    if (fragment.map_entries.len != 0) scratch.stages[1].pSpecializationInfo = &fragment_info;

    object.vk_pipeline = try pipeline_render.createGraphicsPipeline(
        backend,
        &scratch,
    );

    // No fallible work follows insertion. Hooks only capture the stable store
    // after successful construction, never an unpublished partial payload.
    try store.pipelines.insert(guard, &key, object);
    object.header.attach(guard, io);
    object.header.setCacheRemovalLocked(guard, store, PipelineStore.removePipelineLocked);
    return dev.handleFor(guard, Pipeline, object, .pipeline);
}

/// Creates or acquires one compute pipeline reference of the required class.
/// Ownership, guard, backend lifetime and failure rules match the render factory.
pub fn createComputePipelineLocked(
    gpa: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    dev: *core.Device,
    store: *PipelineStore,
    backend: *const Backend,
    descriptor: ComputePipelineDescriptor,
    result_reference_class: core.ReferenceClass,
) CreateError!core.Handle {
    try checkFactoryLocked(gpa, guard, dev, store);
    try validateCanonicalLayoutLocked(guard, descriptor.layout);
    try pipeline_compute.validateComputePipelineDescriptor(descriptor);
    try validateLayout(descriptor.layout);

    var constants = try prepareCompute(gpa, descriptor);
    defer constants.deinit(gpa);
    var key = try buildPreparedComputeKey(gpa, descriptor, &constants);
    defer key.deinit(gpa);

    if (store.pipelines.find(guard, &key)) |found| {
        try acquireCachedReferenceLocked(guard, found, result_reference_class);
        return dev.handleFor(guard, Pipeline, found, .pipeline);
    }

    // The same entry point and the same reason as the render path above.
    const destroy_pipeline = try destroyEntryPoint(backend);

    const object = try dev.create(gpa, guard, Pipeline, .{
        .kind = .pipeline,
        .label = descriptor.label,
        .initial_reference = result_reference_class,
    });
    errdefer object.header.discardUnpublishedLocked(guard) catch unreachable;
    object.* = .{
        .header = object.header,
        .backend = backend,
        .destroy_pipeline = destroy_pipeline,
        .allocator = gpa,
        .vk_layout = descriptor.layout.handle,
    };
    errdefer object.deinitPayloadLocked(guard, io);
    try object.initLayout(guard, descriptor.layout);
    object.state.compute.entry_point = try gpa.dupeZ(u8, descriptor.compute.entry_point);

    // Upstream asks the device for a pipeline cache
    // (`GetOrCreatePipelineCacheImpl`, `vulkan/DeviceVk.cpp:275`) and passes its
    // handle (`vulkan/ComputePipelineVk.cpp:207`); the store's map holds none
    // until a create path asks for one, so the port passes `null`, which Vulkan
    // defines as "no cache", as the render path does (`pipeline_render.zig:970`).
    var constants_info = constants.info();
    object.vk_pipeline = try pipeline_compute.createComputePipeline(
        backend,
        if (constants.map_entries.len == 0) null else &constants_info,
        descriptor,
        object.state.compute.entry_point.?,
        null,
    );

    try store.pipelines.insert(guard, &key, object);
    object.header.attach(guard, io);
    object.header.setCacheRemovalLocked(guard, store, PipelineStore.removePipelineLocked);
    return dev.handleFor(guard, Pipeline, object, .pipeline);
}

fn validateCanonicalLayoutLocked(
    guard: *const core.ObjectGuard,
    input: LayoutInput,
) (core.ValidationError || core.ReferenceError)!void {
    const header = input.canonical_layout_header orelse return;
    if (header.tracking != guard.objects) return error.ResourceDeviceMismatch;
    guard.assertOwns(header.tracking);
    if (header.kind != .pipeline_layout) return error.HandleKindMismatch;
    if (header.state != .alive or !header.isAlive(guard)) return error.ResourceDestroyed;
}

fn validateLayout(input: LayoutInput) (PipelineError || core.ValidationError)!void {
    _ = try input.immediateMask();
    _ = try input.bindGroupMask();
    for (input.groups) |group| {
        if (group.compatibility_token != input.compatibility_token)
            return error.BindGroupLayoutMismatch;
        // Canonical high factories check unchanged shader bindings against real owners.
        if (group.has_external_texture and input.canonical_layout_header == null)
            return error.ExternalTexturePipelineUnsupported;
    }
}

fn checkFactoryLocked(
    gpa: std.mem.Allocator,
    guard: *const core.ObjectGuard,
    dev: *core.Device,
    store: *PipelineStore,
) (core.CreateError || core.ReferenceError)!void {
    guard.assertOwns(dev.borrow().objectList());
    guard.assertOwns(store.objects);
    if (store.objects != dev.borrow().objectList()) return error.ResourceDeviceMismatch;
    try dev.arena.checkAllocator(guard, gpa);
    if (store.allocator.ptr != gpa.ptr or store.allocator.vtable != gpa.vtable) {
        return error.AllocatorMismatch;
    }
    if (store.objects.marked_destroyed) return error.ResourceDestroyed;
}

fn acquireCachedReferenceLocked(
    guard: *const core.ObjectGuard,
    object: *Pipeline,
    class: core.ReferenceClass,
) core.ReferenceError!void {
    switch (class) {
        .user => try object.header.acquireUserLocked(guard),
        .lease => try object.header.retainLeaseLocked(guard),
    }
}

/// The `VkPipeline` behind a handle. Dawn's `GetHandle`
/// (`vulkan/RenderPipelineVk.cpp:1111`).
pub fn vkPipeline(
    guard: *const core.ObjectGuard,
    dev: *core.Device,
    target: core.Handle,
) CreateError!vulkan.VkPipeline {
    const resolved = try dev.resolve(guard, Pipeline, target);
    return resolved.vk_pipeline;
}

/// The `VkPipelineLayout` the pipeline was created with. Dawn's `GetVkLayout`
/// (`vulkan/RenderPipelineVk.cpp:1116`, `vulkan/ComputePipelineVk.cpp:252`).
pub fn vkLayout(
    guard: *const core.ObjectGuard,
    dev: *core.Device,
    target: core.Handle,
) CreateError!vulkan.VkPipelineLayout {
    const resolved = try dev.resolve(guard, Pipeline, target);
    return resolved.vk_layout;
}

/// Which of the two a handle names. Dawn's `GetType`
/// (`src/dawn/native/ComputePipeline.cpp:119`).
pub fn queryKind(
    guard: *const core.ObjectGuard,
    dev: *core.Device,
    target: core.Handle,
) CreateError!Kind {
    const resolved = try dev.resolve(guard, Pipeline, target);
    return resolved.queryKind(guard);
}

/// Borrows render state only while the guard is held and payload remains live.
pub fn renderState(
    guard: *const core.ObjectGuard,
    dev: *core.Device,
    target: core.Handle,
) CreateError!*const RenderState {
    const resolved = try dev.resolve(guard, Pipeline, target);
    return switch (resolved.state) {
        .render => |*render| render,
        .compute => error.StaleHandle,
    };
}

/// Borrows compute state only while the guard is held and payload remains live.
pub fn computeState(
    guard: *const core.ObjectGuard,
    dev: *core.Device,
    target: core.Handle,
) CreateError!*const ComputeState {
    const resolved = try dev.resolve(guard, Pipeline, target);
    return switch (resolved.state) {
        .compute => |*compute| compute,
        .render => error.StaleHandle,
    };
}

/// Borrows key storage only while the guard is held and payload remains live.
pub fn cacheKeyOf(
    guard: *const core.ObjectGuard,
    dev: *core.Device,
    target: core.Handle,
) CreateError!*const CacheKey {
    const resolved = try dev.resolve(guard, Pipeline, target);
    return &resolved.key;
}

/// The bytes that decide whether a render descriptor is a new pipeline.
///
/// Dawn's `RenderPipelineBase::ComputeContentHash`
/// (`src/dawn/native/RenderPipeline.cpp:1329`) records, in order: the base
/// hash — layout, stage mask, per stage module and entry point
/// (`Pipeline.cpp:383`) — then the attachment state, per target write mask and
/// blend, depth-stencil, vertex attributes and buffers, the primitive tuple and
/// multisample. The port writes exactly that order, so a key that differs
/// anywhere differs in the bytes too.
/// Nonempty overrides validate the authoritative SPIR-V bytes before encoding
/// sorted SpecIds, scalar types and converted bits. Release the returned key
/// with the same allocator. No partial key survives an error.
pub fn buildRenderPipelineKey(
    allocator: std.mem.Allocator,
    descriptor: RenderPipelineDescriptor,
) KeyError!CacheKey {
    var vertex = try prepareSpecialization(allocator, descriptor.vertex);
    defer vertex.deinit(allocator);
    var fragment = try prepareSpecialization(allocator, descriptor.fragment orelse .{});
    defer fragment.deinit(allocator);
    return buildPreparedRenderKey(allocator, descriptor, &vertex, &fragment);
}

fn buildPreparedRenderKey(
    allocator: std.mem.Allocator,
    descriptor: RenderPipelineDescriptor,
    vertex: *const specialization.Specialization,
    fragment: *const specialization.Specialization,
) std.mem.Allocator.Error!CacheKey {
    var key = CacheKey.init();
    errdefer key.deinit(allocator);

    try key.appendKind(allocator, .render_pipeline);
    try appendBaseKey(
        allocator,
        &key,
        descriptor.layout,
        descriptor.vertex,
        descriptor.fragment,
        vertex,
        fragment,
    );

    for (descriptor.vertex_buffers) |buffer| {
        try key.appendEnum(allocator, buffer.step_mode);
        try key.appendWord(allocator, buffer.array_stride);
    }
    for (descriptor.vertex_attributes) |attribute| {
        try key.appendWord(allocator, attribute.shader_location);
        try key.appendWord(allocator, attribute.input_slot);
        try key.appendWord(allocator, attribute.offset);
        try key.appendEnum(allocator, attribute.format);
    }
    try key.appendEnum(allocator, descriptor.primitive.topology);
    // Dawn records `mPrimitive.stripIndexFormat` beside the topology
    // (`RenderPipeline.cpp:1376`), and the descriptor types it as an optional
    // because a non-strip topology carries no value. The absent case gets its
    // own word so an absent format and a present `uint16` cannot collide,
    // which is the same shape the blend and the depth-stencil blocks use.
    if (descriptor.primitive.strip_index_format) |strip_index_format| {
        try key.appendWord(allocator, 1);
        try key.appendEnum(allocator, strip_index_format);
    } else {
        try key.appendWord(allocator, 0);
    }
    try key.appendEnum(allocator, descriptor.primitive.front_face);
    try key.appendEnum(allocator, descriptor.primitive.cull_mode);
    try key.appendWord(allocator, @intFromBool(descriptor.primitive.unclipped_depth));
    try key.appendWord(allocator, descriptor.multisample.count);
    try key.appendWord(allocator, descriptor.multisample.mask);
    try key.appendWord(allocator, @intFromBool(descriptor.multisample.alpha_to_coverage));

    for (descriptor.color_targets) |target| {
        // `VkFormat` is a `c_uint` at this pin (`src/vulkan.zig:2866`), not an
        // enumeration, so the number itself is what the key records.
        try key.appendWord(allocator, target.format);
        if (target.format == vulkan.VK_FORMAT_UNDEFINED) {
            try key.appendWord(allocator, 0);
            try key.appendWord(allocator, 0);
            continue;
        }
        try key.appendWord(allocator, target.write_mask);
        if (target.blend) |blend| {
            try key.appendWord(allocator, 1);
            try appendBlendKey(allocator, &key, blend);
        } else {
            try key.appendWord(allocator, 0);
        }
    }
    if (descriptor.depth_stencil) |depth_stencil| {
        try key.appendWord(allocator, 1);
        try pipeline_render.appendDepthStencilKey(allocator, &key, depth_stencil);
    } else {
        try key.appendWord(allocator, 0);
    }
    return key;
}

/// The bytes that decide whether a compute descriptor is a new pipeline.
///
/// Dawn's compute equality is `PipelineBase::EqualForCache`
/// (`src/dawn/native/Pipeline.cpp:398`) — layout, stage mask, and per
/// stage the module, the entry point and the override constants. A compute
/// pipeline has no other state, so the base key is the whole key.
/// Validates compute metadata, effective workgroup size and selected limits before key creation.
pub fn buildComputePipelineKey(
    allocator: std.mem.Allocator,
    descriptor: ComputePipelineDescriptor,
) ComputeError!CacheKey {
    var constants = try prepareCompute(allocator, descriptor);
    defer constants.deinit(allocator);
    return buildPreparedComputeKey(allocator, descriptor, &constants);
}

fn buildPreparedComputeKey(
    allocator: std.mem.Allocator,
    descriptor: ComputePipelineDescriptor,
    constants: *const specialization.Specialization,
) std.mem.Allocator.Error!CacheKey {
    var key = CacheKey.init();
    errdefer key.deinit(allocator);
    try key.appendKind(allocator, .compute_pipeline);
    try appendBaseKey(
        allocator,
        &key,
        descriptor.layout,
        descriptor.compute,
        null,
        constants,
        null,
    );
    return key;
}

/// Appends actual canonical owner identity or complete standalone raw definitions.
fn appendBaseKey(
    allocator: std.mem.Allocator,
    key: *CacheKey,
    layout: LayoutInput,
    first: StageInput,
    second: ?StageInput,
    first_constants: *const specialization.Specialization,
    second_constants: ?*const specialization.Specialization,
) std.mem.Allocator.Error!void {
    if (layout.canonical_layout_header) |header| {
        try key.appendWord(allocator, 1);
        try key.appendWord(allocator, @intFromPtr(header));
    } else {
        try key.appendWord(allocator, 0);
        try key.appendBytes(allocator, layout.content_bytes);
        try key.appendWord(allocator, layout.immediate_size);
        try key.appendWord(allocator, layout.compatibility_token);
        try key.appendWord(allocator, layout.groups.len);
        for (layout.groups) |group| {
            try key.appendWord(allocator, group.compatibility_token);
            try key.appendWord(allocator, group.combined_image_sampler_descriptor_count);
            try key.appendWord(allocator, @intFromBool(group.has_external_texture));
            try key.appendWord(allocator, group.bindings.len);
            for (group.bindings) |binding| {
                try key.appendWord(allocator, binding.binding);
                try key.appendWord(allocator, binding.descriptorType);
                try key.appendWord(allocator, binding.descriptorCount);
                try key.appendWord(allocator, binding.stageFlags);
                try key.appendWord(allocator, @intFromBool(binding.pImmutableSamplers != null));
                if (binding.pImmutableSamplers != null) {
                    for (binding.pImmutableSamplers[0..binding.descriptorCount]) |sampler| {
                        try key.appendWord(
                            allocator,
                            if (sampler) |handle| @intFromPtr(handle) else 0,
                        );
                    }
                }
            }
        }
    }
    try key.appendWord(allocator, stageMask(first, second));
    try appendStageKey(allocator, key, first, first_constants);
    if (second) |stage| try appendStageKey(allocator, key, stage, second_constants.?);
}

fn appendStageKey(
    allocator: std.mem.Allocator,
    key: *CacheKey,
    stage: StageInput,
    constants: *const specialization.Specialization,
) std.mem.Allocator.Error!void {
    try key.appendEnum(allocator, stage.stage);
    try key.appendBytes(allocator, stage.entry_point);
    try key.appendBytes(allocator, stage.content_bytes);
    try key.appendBytes(allocator, constants.canonical_bytes);
}

fn appendBlendKey(
    allocator: std.mem.Allocator,
    key: *CacheKey,
    blend: pipeline_render.BlendState,
) std.mem.Allocator.Error!void {
    try key.appendEnum(allocator, blend.color.src_factor);
    try key.appendEnum(allocator, blend.color.dst_factor);
    try key.appendEnum(allocator, blend.color.operation);
    try key.appendEnum(allocator, blend.alpha.src_factor);
    try key.appendEnum(allocator, blend.alpha.dst_factor);
    try key.appendEnum(allocator, blend.alpha.operation);
}

/// The stage mask as a bit field. Dawn ORs one bit per stage present
/// (`src/dawn/native/Pipeline.cpp:278`) and `GetStageMask`
/// (`src/dawn/native/Pipeline.cpp:339`) reads the mask back, so it is the
/// second thing the content hash records.
fn stageMask(first: StageInput, second: ?StageInput) u32 {
    // The left operand is spelled `u32` and not left to be a comptime `1`: the
    // shift amount is only known at runtime, and a shift needs a fixed-width
    // left operand. The mask is what the second thing the content hash records
    // holds (`Pipeline.cpp:387`), so its width is the key's width.
    var mask: u32 = @as(u32, 1) << @intFromEnum(first.stage);
    if (second) |stage| mask |= @as(u32, 1) << @intFromEnum(stage.stage);
    return mask;
}

comptime {
    // Every stage is reachable through the mask, so a member added to `Stage`
    // without a mask bit is a compile error here and not a silent collision.
    for (std.enums.values(Stage), 0..) |stage, index| {
        std.debug.assert((1 << index) != 0);
        _ = stage;
    }
}

/// What `validateStage` needs beyond the stage itself.
///
/// The three booleans need nothing. The fourth rule needs a limit, and Dawn
/// reads it off the device (`Pipeline.cpp:154`), which is why it is a value
/// here: the rule then runs with no device at all.
pub const StageValidationOptions = struct {
    compatibility: bool = false,
    /// `min(maxSampledTexturesPerShaderStage, maxSamplersPerShaderStage)`, the
    /// cap Dawn computes at `Pipeline.cpp:153-156`.
    max_texture_sampler_combinations: u32 = std.math.maxInt(u32),
};

/// Checks one programmable stage. Ports
/// `ValidateProgrammableStage` (`src/dawn/native/Pipeline.cpp:92`).
///
/// The port has no `EntryPointMetadata` to read, because it has no Tint to
/// produce one: `StageUsage` is what reflection reported. Every rule here
/// therefore reads a field and not a shader, which is also what makes the
/// compatibility rules testable without a device.
pub fn validateStage(
    input: StageInput,
    options: StageValidationOptions,
) PipelineError!void {
    if (input.stage != .vertex and input.entry_point.len == 0) {
        return error.StageMissingForEntryPoint;
    }
    if (!options.compatibility) return;
    if (input.usage.texture_load_with_depth_texture) {
        return error.CompatibilityTextureLoadWithDepthTexture;
    }
    if (input.usage.depth_texture_with_non_comparison_sampler) {
        return error.CompatibilityDepthTextureWithNonComparisonSampler;
    }
    if (input.usage.fine_derivative_builtin) {
        return error.CompatibilityFineDerivativeBuiltin;
    }
    if (input.usage.texture_sampler_combination_count > options.max_texture_sampler_combinations) {
        return error.CompatibilityTextureSamplerCombinationsAboveLimit;
    }
}
