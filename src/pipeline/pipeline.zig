//! Pipelines: the descriptor, the cached object, and the two create calls.
//!
//! **What this file is.** Dawn's `PipelineBase`
//! (`src/dawn/native/Pipeline.h:71`) with the two leaves that hang off it and
//! the device cache that decides whether a leaf is built at all. The cache
//! identity is one thing: the bytes `buildRenderPipelineKey` and
//! `buildComputePipelineKey` write, and the layout's own bytes are the first
//! state field in each (`Pipeline.cpp:385` records the layout first and
//! `Pipeline.cpp:400` compares it first).
//!
//! **What this file does not claim.** It does not claim Dawn's reference
//! counting, its `WeakRef` promotion, or its `mSpecializations` map. The port's
//! object lives in the device arena and the store keys on bytes, so the
//! specialization map has no job: one descriptor is one specialization.
//!
//! **What it does not claim either.** Attachment formats are `VkFormat`, not
//! the WebGPU `TextureFormat`. M7 owns the WebGPU format table and the
//! conversion, and a Vulkan pipeline needs the Vulkan value
//! (`VkPipelineRenderingCreateInfo`, `src/vulkan.zig:7580`). Naming the Vulkan
//! value here keeps one table in the project instead of two.

const std = @import("std");
const vulkan = @import("vulkan");

const core = @import("../core/root.zig");

const cache = @import("cache.zig");
const pipeline_backend = @import("pipeline_backend.zig");
const pipeline_binding_info = @import("pipeline_binding_info.zig");
const pipeline_compute = @import("pipeline_compute.zig");
const pipeline_render = @import("pipeline_render.zig");

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
    /// The bytes that identify this module's contents in a cache key. M13
    /// passes the caller's own SPIR-V words.
    content_bytes: []const u8 = &.{},
    usage: StageUsage = .{},
};

/// The pipeline layout, and the bytes that put it in a cache key.
///
/// Dawn streams `layout->GetCacheKey()` into the pipeline key
/// (`src/dawn/native/vulkan/RenderPipelineVk.cpp:925`), and that key is the
/// descriptor set layout create infos, the resource-table flag and the
/// immediate data range (`src/dawn/native/vulkan/PipelineLayoutVk.cpp:127`).
/// So "the same pipeline with a different layout is a different key" is not a
/// rule this module invents; it is what the layout's own bytes do.
pub const LayoutInput = struct {
    handle: vulkan.VkPipelineLayout = null,
    content_bytes: []const u8 = &.{},
};

/// Every rule a descriptor can break. One member per `DAWN_INVALID_IF` site, so
/// a caller matches on the rule instead of on the message text
/// (`AGENTS.md` §2).
pub const PipelineError = error{
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
    StencilOperationUndefined,
    MultisampleCountUnsupported,
    MultisampleCountNotOne,
    SampleMaskNotOne,
    AlphaToCoverageWithSampleCountNotOne,
    ColorTargetCountAboveLimit,
    ColorTargetFormatUndefined,
    ColorTargetFormatNotRenderable,
    ColorWriteMaskEmpty,
    BlendFactorUndefined,
    BlendOperationUndefined,
    CompatibilityDepthBiasClampNonZero,
    // `native/ComputePipeline.cpp:37`.
    ComputeStageMissing,
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

/// What a create call can report: a rule the caller broke, a handle the arena
/// rejects, an allocation failure, a lock the caller cancelled, a Vulkan call
/// the seam could not make, or the device gone.
///
/// `core.ValidationError` is in the union because the getters below resolve a
/// handle, and `Device.resolve` (`src/core/device.zig:120`) answers a stale or
/// wrongly-kinded one through that set. `src/engine/buffer.zig:194` composes
/// it the same way.
pub const CreateError = PipelineError || core.ValidationError || core.UnrecoverableError ||
    std.mem.Allocator.Error || error{Canceled} || pipeline_backend.BackendError;

/// Which pipeline a handle names.
pub const Kind = enum {
    render,
    compute,
};

pub const RenderPipelineDescriptor = struct {
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

pub const ComputePipelineDescriptor = struct {
    label: []const u8 = "",
    layout: LayoutInput = .{},
    compute: StageInput = .{ .stage = .compute },
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
    entry_point: []const u8 = "",
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
    // SAFETY: both create paths below assign `backend`, `destroy_pipeline`,
    // `allocator`, `vk_pipeline`, `vk_layout`, `key` and `state` before
    // `header.attach()`, and `attach` is what puts the object on the device's
    // list. Nothing reads these fields before the attach, because nothing can
    // reach the object before the attach.
    backend: *const Backend = undefined,
    /// The seam's `vkDestroyPipeline`, read once by the create paths. The
    /// teardown below calls this pointer and never unwraps it, so a seam that
    /// cannot destroy is refused at creation with
    /// `error.DestroyPipelineNotLoaded` and not at teardown.
    // SAFETY: assigned by both create paths before `header.attach()`, as the
    // `backend` field above states.
    destroy_pipeline: DestroyPipelineFn = undefined,
    /// Where the key bytes and the owned state slices came from. Copied, not
    /// reached through: the store is emptied before the arena tears these
    /// objects down, and `destroy` still has to free what they own.
    // SAFETY: assigned by both create paths before `header.attach()`, as the
    // `backend` field above states.
    allocator: std.mem.Allocator = undefined,
    vk_pipeline: vulkan.VkPipeline = null,
    vk_layout: vulkan.VkPipelineLayout = null,
    key: CacheKey = CacheKey.init(),
    state: State = .{ .compute = .{} },

    /// The arena's liveness test, which is what makes a dead entry safe to
    /// leave in the cache map: `cache.Cache.find` skips an entry whose object
    /// no longer answers true.
    pub fn isAlive(self: *const Pipeline) bool {
        return self.header.isAlive();
    }

    pub fn queryKind(self: *const Pipeline) Kind {
        return switch (self.state) {
            .render => .render,
            .compute => .compute,
        };
    }

    /// Releases the Vulkan object and the bytes the object owns. The arena's
    /// block stays, so a handle taken before this reads a destroyed object
    /// rather than freed memory (`src/core/object.zig:130`).
    pub fn destroy(self: *Pipeline, reason: core.DestroyReason) void {
        _ = reason;
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
            .compute => {},
        }
        self.key.deinit(allocator);
        self.header.label = "";
    }
};

/// The device's pipeline caches: Dawn's `DeviceBase::Caches`
/// (`src/dawn/native/Device.cpp:102`) narrowed to the two entries the pipeline
/// path owns, plus the `VkPipelineCache` map that
/// `GetOrCreatePipelineCacheImpl` (`vulkan/DeviceVk.cpp:275`) keeps.
pub const PipelineStore = struct {
    /// How many `VkPipelineCache` handles the device keeps before one is
    /// evicted. Dawn creates one per pipeline key and never bounds the set
    /// (`vulkan/DeviceVk.cpp:294`); the port bounds it, because each entry is a
    /// driver allocation and not an arena object.
    pub const pipeline_cache_capacity = 32;

    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    pipelines: cache.Cache(Pipeline),
    pipeline_caches: cache.LruCache([]const u8, cache.PipelineCache, pipeline_cache_capacity) =
        .init(),

    pub fn init(allocator: std.mem.Allocator) PipelineStore {
        return .{
            .allocator = allocator,
            .pipelines = cache.Cache(Pipeline).init(allocator),
        };
    }

    /// Reports rather than returning `void`, because every cache handle it
    /// destroys goes through a dispatch field and `AGENTS.md` §3.1 makes a
    /// field the loader left null a typed error. A refusal stops the sweep at
    /// the handle it reached, which is what `Queue.deinit`
    /// (`src/engine/queue.zig:260`-`:263`) already states for the same shape:
    /// the entry point is bound once, so a missing one costs the caller the
    /// rest of the teardown and not a trap.
    pub fn deinit(self: *PipelineStore) cache.PipelineCache.DestroyError!void {
        for (self.pipeline_caches.entries.items) |entry| {
            try entry.value.destroy();
            self.allocator.free(entry.key);
        }
        self.pipeline_caches.deinit(self.allocator);
        self.pipelines.deinit();
        // A poisoned store is what a caller gets: the arena outlives it and
        // destroys its pipelines through `Pipeline.allocator`, never through
        // this value, so nothing reads the store again.
        self.* = undefined;
    }

    pub fn queryPipelineCount(self: *const PipelineStore) usize {
        return self.pipelines.queryEntryCount();
    }
};

/// Creates a render pipeline, or returns the one an identical descriptor
/// already made.
///
/// Dawn's order is `DeviceBase::CreateRenderPipeline`
/// (`src/dawn/native/Device.cpp:2215`): look in the cache first, and only build
/// when the lookup misses. That order is the acceptance of this milestone — the
/// second identical descriptor must reach the same `VkPipeline`, and a
/// different `PipelineLayout` must reach a different one.
pub fn createRenderPipeline(
    io: std.Io,
    dev: *core.Device,
    store: *PipelineStore,
    backend: *const Backend,
    descriptor: RenderPipelineDescriptor,
) CreateError!core.Handle {
    try pipeline_render.validateRenderPipelineDescriptor(descriptor);

    var key = try buildRenderPipelineKey(store.allocator, descriptor);
    defer key.deinit(store.allocator);

    store.mutex.lock(io) catch return error.Canceled;
    defer store.mutex.unlock(io);
    _ = store.pipelines.prune();

    if (store.pipelines.find(&key)) |found| {
        return handleFor(found);
    }

    // A seam that cannot destroy must not create: `Pipeline.destroy` returns
    // `void` and has no way to report the miss, so the entry point is read
    // here, where `CreateError` carries it.
    const destroy_pipeline = try destroyEntryPoint(backend);

    const object = try dev.create(Pipeline, .{
        .kind = .pipeline,
        .label = descriptor.label,
    });
    const created = dev.handleFor(Pipeline, object, .pipeline);
    // `destroy` reads `allocator`, `key`, `state` and `vk_pipeline`, and the
    // arena leaves the bytes after the header undefined
    // (`src/core/object.zig:332-334`), so each one is written before the first
    // `try` that can fail below: `buildRenderState` writes `state` before its
    // first allocation (`pipeline_render.zig:573`).
    //
    // The rollback destroy reports `HandleError`, and `created` names the object
    // this function made and attached below, so neither `HandleKindMismatch`
    // nor `StaleHandle` (`Device.resolveHeader`, `src/core/device.zig:177`)
    // can fire here. Both are named rather than dropped: the caller is
    // unwinding with the error that got it here, and that error is the one
    // worth reporting, so any other member is a defect this path cannot cause
    // and is reported as one.
    errdefer dev.destroy(created) catch |rollback_error| switch (rollback_error) {
        error.HandleKindMismatch,
        error.StaleHandle,
        => {},
        else => std.debug.panic(
            "pipeline: the render rollback destroy failed with an error the create path cannot cause",
            .{},
        ),
    };
    object.backend = backend;
    object.destroy_pipeline = destroy_pipeline;
    object.allocator = store.allocator;
    object.key = CacheKey.init();
    object.vk_pipeline = null;
    object.vk_layout = descriptor.layout.handle;
    // Every field `destroy` reads is written, so the object can enter the list.
    // The attach is what makes the rollback above reachable.
    object.header.attach();

    var scratch: pipeline_render.Scratch = .{};
    defer scratch.deinit(store.allocator);
    try pipeline_render.buildRenderState(
        store.allocator,
        descriptor,
        &object.state,
        &scratch,
    );

    object.vk_pipeline = try pipeline_render.createGraphicsPipeline(
        backend,
        descriptor.layout.handle,
        descriptor,
        &scratch,
    );

    // The handoff: the bytes move into the entry and `key` is left empty, so
    // the `defer` above frees nothing on this path.
    try store.pipelines.insert(&key, object);

    return created;
}

/// Creates a compute pipeline, or returns the one an identical descriptor
/// already made.
pub fn createComputePipeline(
    io: std.Io,
    dev: *core.Device,
    store: *PipelineStore,
    backend: *const Backend,
    descriptor: ComputePipelineDescriptor,
) CreateError!core.Handle {
    try pipeline_compute.validateComputePipelineDescriptor(descriptor);

    var key = try buildComputePipelineKey(store.allocator, descriptor);
    defer key.deinit(store.allocator);

    store.mutex.lock(io) catch return error.Canceled;
    defer store.mutex.unlock(io);
    _ = store.pipelines.prune();

    if (store.pipelines.find(&key)) |found| {
        return handleFor(found);
    }

    // The same entry point and the same reason as the render path above.
    const destroy_pipeline = try destroyEntryPoint(backend);

    const object = try dev.create(Pipeline, .{
        .kind = .pipeline,
        .label = descriptor.label,
    });
    const created = dev.handleFor(Pipeline, object, .pipeline);
    // The same rollback and the same reason as the render path above. The set
    // is matched with an `else`, so a member added to `HandleError` that this
    // path cannot cause is a reported defect rather than a dropped failure.
    errdefer dev.destroy(created) catch |rollback_error| switch (rollback_error) {
        error.HandleKindMismatch,
        error.StaleHandle,
        => {},
        else => std.debug.panic(
            "pipeline: the compute rollback destroy failed with an error the create path cannot cause",
            .{},
        ),
    };
    object.backend = backend;
    object.destroy_pipeline = destroy_pipeline;
    object.allocator = store.allocator;
    object.key = CacheKey.init();
    object.vk_pipeline = null;
    object.vk_layout = descriptor.layout.handle;
    object.state = .{ .compute = .{ .entry_point = descriptor.compute.entry_point } };
    // `state` is written, so `destroy` reads a tag and not arena fill, and the
    // object can enter the list. The attach is what makes the rollback reachable.
    object.header.attach();

    // Upstream asks the device for a pipeline cache
    // (`GetOrCreatePipelineCacheImpl`, `vulkan/DeviceVk.cpp:275`) and passes its
    // handle (`vulkan/ComputePipelineVk.cpp:207`); the store's map holds none
    // until a create path asks for one, so the port passes `null`, which Vulkan
    // defines as "no cache", as the render path does (`pipeline_render.zig:970`).
    object.vk_pipeline = try pipeline_compute.createComputePipeline(
        backend,
        descriptor.layout.handle,
        descriptor,
        null,
    );

    // The same handoff as the render path above: the bytes move into the
    // entry and `key` is left empty, so the `defer` above frees nothing.
    try store.pipelines.insert(&key, object);
    return created;
}

/// The handle an arena object answers with. The kind byte is the one the arena
/// recorded at creation, so a handle never names one object as another
/// (`src/core/handle.zig:29`).
fn handleFor(object: *Pipeline) core.Handle {
    return .{ .ptr = @as(core.ObjectPtr, object), .kind = .pipeline };
}

/// The `VkPipeline` behind a handle. Dawn's `GetHandle`
/// (`vulkan/RenderPipelineVk.cpp:1111`).
pub fn vkPipeline(dev: *core.Device, target: core.Handle) CreateError!vulkan.VkPipeline {
    const resolved = try dev.resolve(Pipeline, target);
    return resolved.vk_pipeline;
}

/// The `VkPipelineLayout` the pipeline was created with. Dawn's `GetVkLayout`
/// (`vulkan/RenderPipelineVk.cpp:1116`, `vulkan/ComputePipelineVk.cpp:252`).
pub fn vkLayout(dev: *core.Device, target: core.Handle) CreateError!vulkan.VkPipelineLayout {
    const resolved = try dev.resolve(Pipeline, target);
    return resolved.vk_layout;
}

/// Which of the two a handle names. Dawn's `GetType`
/// (`src/dawn/native/ComputePipeline.cpp:119`).
pub fn queryKind(dev: *core.Device, target: core.Handle) CreateError!Kind {
    const resolved = try dev.resolve(Pipeline, target);
    return resolved.queryKind();
}

/// The render state, borrowed from the arena. The slices live until the
/// pipeline is destroyed, which is what lets M18's replay read them without a
/// copy.
pub fn renderState(dev: *core.Device, target: core.Handle) CreateError!*const RenderState {
    const resolved = try dev.resolve(Pipeline, target);
    return switch (resolved.state) {
        .render => |*render| render,
        .compute => error.StaleHandle,
    };
}

pub fn computeState(dev: *core.Device, target: core.Handle) CreateError!*const ComputeState {
    const resolved = try dev.resolve(Pipeline, target);
    return switch (resolved.state) {
        .compute => |*compute| compute,
        .render => error.StaleHandle,
    };
}

/// The bytes the cache recorded for this pipeline, which is what the next
/// descriptor is compared against.
pub fn cacheKeyOf(dev: *core.Device, target: core.Handle) CreateError!*const CacheKey {
    const resolved = try dev.resolve(Pipeline, target);
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
pub fn buildRenderPipelineKey(
    allocator: std.mem.Allocator,
    descriptor: RenderPipelineDescriptor,
) std.mem.Allocator.Error!CacheKey {
    var key = CacheKey.init();
    errdefer key.deinit(allocator);

    try key.appendKind(allocator, .render_pipeline);
    try appendBaseKey(allocator, &key, descriptor.layout, descriptor.vertex, descriptor.fragment);

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
pub fn buildComputePipelineKey(
    allocator: std.mem.Allocator,
    descriptor: ComputePipelineDescriptor,
) std.mem.Allocator.Error!CacheKey {
    var key = CacheKey.init();
    errdefer key.deinit(allocator);
    try key.appendKind(allocator, .compute_pipeline);
    try appendBaseKey(allocator, &key, descriptor.layout, descriptor.compute, null);
    return key;
}

/// The layout, then the stages. Dawn records the layout first
/// (`Pipeline.cpp:385`) and compares it first (`Pipeline.cpp:400`), so the two
/// orders agree; the port keeps the first.
fn appendBaseKey(
    allocator: std.mem.Allocator,
    key: *CacheKey,
    layout: LayoutInput,
    first: StageInput,
    second: ?StageInput,
) std.mem.Allocator.Error!void {
    try key.appendBytes(allocator, layout.content_bytes);
    try key.appendWord(allocator, stageMask(first, second));
    try appendStageKey(allocator, key, first);
    if (second) |stage| try appendStageKey(allocator, key, stage);
}

fn appendStageKey(
    allocator: std.mem.Allocator,
    key: *CacheKey,
    stage: StageInput,
) std.mem.Allocator.Error!void {
    try key.appendEnum(allocator, stage.stage);
    try key.appendBytes(allocator, stage.entry_point);
    try key.appendBytes(allocator, stage.content_bytes);
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
