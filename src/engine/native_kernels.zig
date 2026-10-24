//! Canonical utility pipelines and commands borrowed from one pending submission.
const std = @import("std");
const vulkan = @import("vulkan");
const api = @import("../api/api.zig");
const core = @import("../core/root.zig");
const dispatch = @import("../vk/dispatch.zig");
const attachment_state = @import("../command/attachment_state.zig");
const pipeline = @import("../pipeline/pipeline.zig");
const layout = @import("../pipeline/layout_internal.zig");
const definitions = @import("native_kernel_definitions.zig");
const resources = @import("native_resources.zig");
const buffer = @import("buffer.zig");
const texture = @import("texture.zig");
const sampler_mod = @import("sampler.zig");
const queue = @import("queue.zig");
const recording_context = @import("recording_context.zig");
const vulkan_device = @import("vulkan_device.zig");
const features = @import("features.zig");
const limits = @import("limits.zig");
const format = @import("format.zig");
const vulkan_format = @import("vulkan_format.zig");

pub const KernelId = definitions.KernelId;
pub const KernelKey = definitions.KernelKey;
pub const Slot = definitions.Slot;
pub const Definition = definitions.Definition;
pub const BufferAccess = definitions.BufferAccess;
pub const Stage = definitions.Stage;
pub const Error = resources.Error || pipeline.CreateError || buffer.CreateError ||
    texture.InitializationError || error{
    InvalidKernelKey,
    KernelBindingCountMismatch,
    KernelBindingTypeMismatch,
    KernelParameterSizeMismatch,
    KernelParameterUploadTooLarge,
    InternalBufferUsageInvalid,
    KernelRangeOverflow,
    KernelDispatchLimitExceeded,
    KernelRequiresOutsideRenderPass,
    KernelAttachmentMismatch,
    UnsupportedPixelLocalStorage,
    RecordingPoisoned,
    NativeDeviceStopped,
};

pub const InitOptions = struct {
    objects: *core.ObjectList,
    native_device: *const vulkan_device.Device,
    enabled_features: *const features.FeaturesSet,
    limits: *const limits.CombinedLimits,
    formats: *const format.FormatTable,
    resource_device: resources.NativeDevice,
    pipeline_store: *pipeline.PipelineStore,
    pipeline_backend: *const pipeline.Backend,
};

pub const KernelCache = struct {
    pub const capacity = 32;
    objects: *core.ObjectList,
    native_device: *const vulkan_device.Device,
    enabled_features: *const features.FeaturesSet,
    limits: *const limits.CombinedLimits,
    formats: *const format.FormatTable,
    resource_device: resources.NativeDevice,
    pipeline_store: *pipeline.PipelineStore,
    pipeline_backend: *const pipeline.Backend,
    entries: [capacity]?Entry = @splat(null),
    next_victim: u8 = 0,

    pub const Entry = struct { key: KernelKey, pipeline: *resources.Pipeline };

    pub fn init(options: InitOptions) KernelCache {
        return .{
            .objects = options.objects,
            .native_device = options.native_device,
            .enabled_features = options.enabled_features,
            .limits = options.limits,
            .formats = options.formats,
            .resource_device = options.resource_device,
            .pipeline_store = options.pipeline_store,
            .pipeline_backend = options.pipeline_backend,
        };
    }

    pub fn releaseRootsLocked(self: *KernelCache, guard: *const core.ObjectGuard, io: std.Io) void {
        guard.assertOwns(self.objects);
        for (&self.entries) |*slot| {
            const entry = slot.* orelse continue;
            slot.* = null;
            entry.pipeline.header.releaseLeaseLocked(guard, io);
        }
        self.next_victim = 0;
    }
};

pub const Context = struct {
    io: std.Io,
    guard: *const core.ObjectGuard,
    device: *core.Device,
    queue: *queue.Queue,
    recording: *recording_context.CommandRecordingContext,
    pending_uses: *resources.PendingUses,
    cache: *KernelCache,
};
pub const BufferRange = struct { owner: *resources.Buffer, offset: u64, size: u64 };
pub const Binding = union(enum) {
    buffer: BufferRange,
    view: *texture.TextureView,
    sampler: *sampler_mod.Sampler,
};
pub const ScratchBuffer = buffer.InternalBufferDescriptor;
pub const Compute = struct {
    key: KernelKey,
    bindings: []const Binding,
    parameters: []const u8,
    workgroups: [3]u32,
};
pub const DrawPreparation = struct {
    key: KernelKey,
    bindings: []const Binding,
    parameters: []const u8,
    compatible_render_pass: vulkan.VkRenderPass,
};
pub const PreparedDraw = struct {
    command_buffer: vulkan.VkCommandBuffer,
    pending_uses: *resources.PendingUses,
    pipeline: *resources.Pipeline,
    bind_group: ?*resources.BindGroup,
};
pub const DrawBindingsReuse = struct {
    key: KernelKey,
    prepared: PreparedDraw,
    compatible_render_pass: vulkan.VkRenderPass,
};
pub const Draw = struct {
    prepared: PreparedDraw,
    render_pass: vulkan.VkRenderPass,
    attachments: *attachment_state.CanonicalAttachmentState,
    viewport: vulkan.VkViewport,
    scissor: vulkan.VkRect2D,
    stencil_reference: u32 = 0,
};

pub const max_parameter_upload_bytes: usize = 8192;

const max_kernel_bindings = 16;
const copy_src: u32 = (api.BufferUsage{ .copy_src = true }).toFlags();
const copy_dst: u32 = (api.BufferUsage{ .copy_dst = true }).toFlags();
const uniform_usage: u32 = (api.BufferUsage{ .uniform = true }).toFlags();

fn sameAllocator(left: std.mem.Allocator, right: std.mem.Allocator) bool {
    return left.ptr == right.ptr and left.vtable == right.vtable;
}

pub fn validateContext(context: Context) Error!void {
    const objects = context.device.arena.objectList();
    if (context.guard.objects != objects or context.cache.objects != objects or
        context.pending_uses.objects != objects or context.cache.pipeline_store.objects != objects)
        return error.ResourceDeviceMismatch;
    context.guard.assertOwns(objects);
    if (objects.marked_destroyed) return error.NativeDeviceStopped;
    if (!context.pending_uses.leased) return error.NoOwnedReference;
    if (context.queue.recording_poisoned) return error.RecordingPoisoned;
    if (objects.mutex != &context.queue.device_mutex.mutex or
        context.queue.context.vk_device != context.cache.native_device.vk_device or
        context.cache.resource_device.handle != context.cache.native_device.vk_device or
        context.queue.context.dispatch.device != context.cache.resource_device.procs or
        context.cache.resource_device.procs != context.cache.native_device.procs)
        return error.ResourceDeviceMismatch;
    const resource_store = context.cache.resource_device.resource_store orelse
        return error.ResourceDeviceMismatch;
    if (resource_store.objects != objects or
        context.cache.resource_device.buffer_device.vk_device != context.cache.native_device.vk_device or
        context.cache.resource_device.buffer_device.dispatch.device != context.cache.resource_device.procs or
        context.cache.resource_device.buffer_device.handles != context.cache.native_device.handles)
        return error.ResourceDeviceMismatch;
    const allocator = context.device.arena.memory.child_allocator;
    try context.device.arena.checkAllocator(context.guard, context.queue.context.allocator);
    if (!sameAllocator(allocator, context.pending_uses.allocator) or
        !sameAllocator(allocator, context.cache.pipeline_store.allocator))
        return error.AllocatorMismatch;
    if (context.recording.command_buffer == null or
        context.recording.command_buffer != context.queue.commandBuffer())
        return error.InvalidCommandStream;
}

fn outsidePass(context: Context) Error!void {
    try validateContext(context);
    if (context.recording.active_render_pass != null) return error.KernelRequiresOutsideRenderPass;
}

fn validateOwner(context: Context, header: *const core.Object, kind: core.Handle.Kind) Error!void {
    if (header.tracking != context.cache.objects) return error.ResourceDeviceMismatch;
    if (header.kind != kind) return error.HandleKindMismatch;
    if (!header.node.linked or header.state != .alive) return error.ResourceDestroyed;
}

fn retainRoot(context: Context, root: *core.Object) Error!void {
    try context.pending_uses.retainDerivedRootLocked(context.guard, context.device, root);
}

fn nativeRecording(context: Context) Error!buffer.Recording {
    const serial = std.math.add(u64, context.queue.timeline.lastSubmittedSerial(), 1) catch
        return error.KernelRangeOverflow;
    return .{ .command_buffer = context.recording.command_buffer, .pending_serial = serial };
}

fn requireProcs(procs: *const dispatch.DeviceProcs, comptime names: anytype) Error!void {
    inline for (names) |name| if (@field(procs, name) == null) return error.MissingDeviceProc;
}

fn preflightBufferProcs(context: Context) Error!void {
    try requireProcs(context.cache.resource_device.procs, .{
        "create_buffer", "destroy_buffer",     "get_buffer_memory_requirements", "allocate_memory",
        "free_memory",   "bind_buffer_memory", "cmd_pipeline_barrier",           "cmd_fill_buffer",
    });
}

pub fn scratchBuffer(context: Context, options: ScratchBuffer) Error!BufferRange {
    try outsidePass(context);
    if (options.size > context.cache.limits.v1.max_buffer_size) return error.BufferSizeAboveLimit;
    try preflightBufferProcs(context);
    const owner = try resources.createInternalBufferLocked(
        context.device.arena.memory.child_allocator,
        context.io,
        context.guard,
        &context.device.arena,
        context.cache.resource_device,
        options,
    );
    defer owner.header.releaseUserLocked(context.guard, context.io) catch unreachable;
    try retainRoot(context, &owner.header);
    return .{ .owner = owner, .offset = 0, .size = options.size };
}

fn parameterBuffer(context: Context, size: u64) Error!BufferRange {
    const owner = try resources.createBuffer(
        context.device.arena.memory.child_allocator,
        context.io,
        context.guard,
        &context.device.arena,
        context.cache.resource_device,
        .{ .size = size, .usage = .{ .uniform = true, .copy_dst = true } },
    );
    defer owner.header.releaseUserLocked(context.guard, context.io) catch unreachable;
    try retainRoot(context, &owner.header);
    return .{ .owner = owner, .offset = 0, .size = size };
}

pub fn sampler(context: Context, options: api.descriptors.SamplerDescriptorChain) Error!*sampler_mod.Sampler {
    try outsidePass(context);
    try requireProcs(context.cache.resource_device.procs, .{ "create_sampler", "destroy_sampler" });
    const owner = try resources.createSamplerLocked(
        context.device.arena.memory.child_allocator,
        context.io,
        context.guard,
        &context.device.arena,
        context.cache.resource_device,
        options,
    );
    defer owner.header.releaseUserLocked(context.guard, context.io) catch unreachable;
    try retainRoot(context, &owner.header);
    return owner;
}

fn validateRange(context: Context, range: BufferRange) Error!void {
    try validateOwner(context, &range.owner.header, .native_buffer);
    if (range.owner.device.handle != context.cache.resource_device.handle)
        return error.ResourceDeviceMismatch;
    if (range.offset > range.owner.native.size or
        range.size > range.owner.native.size - range.offset)
        return error.BindingRangeOutsideBuffer;
    switch (range.owner.native.state) {
        .unmapped => {},
        .mapped, .mapped_at_creation => return error.BufferUseWhileMapped,
        .pending_map => return error.BufferUseWhilePendingMap,
        .in_use => return error.BufferUseWhileInUse,
        .shared_memory_no_access => return error.BufferUseWithoutSharedMemoryAccess,
        .destroyed => return error.BufferUseWhileDestroyed,
    }
    if (range.owner.native.handle == null) return error.BindingResourceInvalid;
}

pub fn transitionBuffer(context: Context, range: BufferRange, usage: u32) Error!void {
    try outsidePass(context);
    try validateRange(context, range);
    const native_usage = range.owner.native.internal_usage;
    const storage = native_usage & (buffer.internal_storage_buffer |
        (api.BufferUsage{ .storage = true }).toFlags()) != 0;
    const supported = native_usage | if (storage) buffer.read_only_storage_buffer else @as(u32, 0);
    if (usage == 0 or usage & ~supported != 0)
        return error.InternalBufferUsageInvalid;
    try requireProcs(context.cache.resource_device.procs, .{"cmd_pipeline_barrier"});
    const recording = try nativeRecording(context);
    try retainRoot(context, &range.owner.header);
    const stages: buffer.ShaderStage = if (usage & buffer.shader_buffer_usages != 0)
        .{ .compute = true, .fragment = true }
    else
        .none;
    errdefer context.queue.poisonRecording();
    context.recording.needs_submit = true;
    try range.owner.native.transitionUsageNow(recording, usage, stages);
}

pub fn uploadParameters(context: Context, range: BufferRange, bytes: []const u8) Error!void {
    if (bytes.len > max_parameter_upload_bytes) return error.KernelParameterUploadTooLarge;
    try outsidePass(context);
    try validateRange(context, range);
    if (range.size != bytes.len) return error.KernelParameterSizeMismatch;
    if (range.offset % 4 != 0) return error.BufferWriteOffsetNotAligned;
    if (bytes.len % 4 != 0) return error.BufferWriteSizeNotAligned;
    if (bytes.len == 0) return;
    const recording = try nativeRecording(context);
    try preflightBufferProcs(context);
    const procs = context.cache.resource_device.procs;
    try requireProcs(procs, .{"cmd_update_buffer"});
    try retainRoot(context, &range.owner.header);
    errdefer context.queue.poisonRecording();
    context.recording.needs_submit = true;
    try range.owner.native.ensureDataInitializedAsDestination(recording, range.offset, range.size);
    try range.owner.native.transitionUsageNow(recording, copy_dst, .none);
    procs.cmd_update_buffer.?(recording.command_buffer, range.owner.native.handle, range.offset, range.size, bytes.ptr);
}

pub fn copyBuffer(context: Context, source: BufferRange, destination: BufferRange) Error!void {
    try outsidePass(context);
    try validateRange(context, source);
    try validateRange(context, destination);
    if (source.size != destination.size) return error.SliceLengthMismatch;
    if (source.size == 0) return error.ZeroSizedCopy;
    if (source.offset % 4 != 0 or destination.offset % 4 != 0)
        return error.BufferWriteOffsetNotAligned;
    if (source.size % 4 != 0) return error.BufferWriteSizeNotAligned;
    if (source.owner.native.internal_usage &
        (copy_src | buffer.internal_copy_src_buffer) == 0)
        return error.BufferUsageMissingCopySrc;
    if (destination.owner.native.internal_usage & copy_dst == 0)
        return error.BufferUsageMissingCopyDst;
    if (source.owner.native.handle == destination.owner.native.handle and
        source.offset < destination.offset + destination.size and
        destination.offset < source.offset + source.size)
        return error.BindingRangeOutsideBuffer;
    try requireProcs(context.cache.resource_device.procs, .{
        "cmd_copy_buffer", "cmd_pipeline_barrier", "cmd_fill_buffer",
    });
    const recording = try nativeRecording(context);
    try retainRoot(context, &source.owner.header);
    try retainRoot(context, &destination.owner.header);
    errdefer context.queue.poisonRecording();
    context.recording.needs_submit = true;
    try source.owner.native.ensureDataInitializedAsDestination(recording, 0, 0);
    try destination.owner.native.recordCopyBufferInternal(recording, source.owner.native, source.offset, destination.offset, source.size);
}

fn validateKeyOwner(context: Context, key: KernelKey, definition: *const Definition) Error!void {
    switch (definition.stages) {
        .compute => if (key.attachments != null) return error.InvalidKernelKey,
        .render => |render| {
            const state = key.attachments orelse return error.InvalidKernelKey;
            try validateOwner(context, &state.header, .attachment_state);
            try state.value.validateCanonical();
            if (state.value.has_pls) return error.UnsupportedPixelLocalStorage;
            if (state.value.expand_resolve.attachments_to_expand_resolve != 0)
                return error.UnsupportedResolveExpansion;
            if (definition.depth_range_push_constants != render.fixed_state.depth_output)
                return error.InvalidKernelKey;
            if (state.value.color_attachments_set & key.color_write_slots != key.color_write_slots)
                return error.InvalidKernelKey;
            const color_limit = @min(context.cache.limits.v1.max_color_attachments, 8);
            const allowed_colors: u16 = (@as(u16, 1) << @as(u4, @intCast(color_limit))) - 1;
            if (@as(u16, state.value.color_attachments_set) & ~allowed_colors != 0)
                return error.TooManyAttachments;
            for (state.value.color_formats, 0..) |wire_format, index| {
                const bit = @as(u8, 1) << @as(u3, @intCast(index));
                if (state.value.color_attachments_set & bit == 0) continue;
                const format_index = format.computeFormatIndex(@fromBackingInt(@intCast(wire_format))) orelse
                    return error.InvalidKernelKey;
                const info = &context.cache.formats[format_index];
                if (!info.isSupported() or !info.caps.renderable or
                    (state.value.sample_count > 1 and !info.caps.multisample))
                    return error.TextureNativeUsageUnsupported;
                const expected_type: format.TextureComponentType =
                    switch (render.fixed_state.color_scalar_kinds[index]) {
                        .float => .float,
                        .sint => .sint,
                        .uint => .uint,
                    };
                if (key.color_write_slots & bit != 0 and
                    info.aspect_info[0].base_type != expected_type)
                    return error.InvalidKernelKey;
            }
            if (render.fixed_state.depth_output or render.fixed_state.stencil_replace) {
                if (state.value.depth_stencil_format == 0) return error.InvalidKernelKey;
                const format_index = format.computeFormatIndex(
                    @fromBackingInt(@intCast(state.value.depth_stencil_format)),
                ) orelse return error.InvalidKernelKey;
                const info = &context.cache.formats[format_index];
                if ((render.fixed_state.depth_output and !info.hasDepth()) or
                    (render.fixed_state.stencil_replace and !info.hasStencil()))
                    return error.InvalidKernelKey;
            }
        },
    }
    if (key.conversion_sampler) |owner| {
        try validateOwner(context, &owner.header, .sampler);
        const native = owner.native orelse return error.BindingResourceInvalid;
        if (native.backend.handle != context.cache.resource_device.handle)
            return error.ResourceDeviceMismatch;
        if (native.conversion == null) return error.BindingResourceInvalid;
    }
}

fn slotUsage(slot: Slot) u32 {
    return switch (slot.buffer.access) {
        .uniform => uniform_usage,
        .storage_read => buffer.read_only_storage_buffer,
        .storage_write => buffer.internal_storage_buffer,
    };
}

fn bindingStages(definition: *const Definition) buffer.ShaderStage {
    return switch (definition.stages) {
        .compute => .{ .compute = true },
        .render => .{ .fragment = true },
    };
}

fn validateView(context: Context, view: *texture.TextureView) Error!void {
    try validateOwner(context, &view.header, .texture_view);
    try validateOwner(context, &view.texture.header, .texture);
    const native = view.texture.native orelse return error.TextureNativeNotInitialized;
    if (native.context.vk_device != context.cache.resource_device.handle)
        return error.ResourceDeviceMismatch;
    _ = try view.getHandle(context.guard);
}

fn validateBindings(context: Context, key: KernelKey, definition: *const Definition, bindings: []const Binding, parameters: []const u8) Error!void {
    if (definition.slots.len != bindings.len) return error.KernelBindingCountMismatch;
    if (definition.parameter_size != parameters.len or parameters.len % 4 != 0)
        return error.KernelParameterSizeMismatch;
    if (bindings.len + @intFromBool(parameters.len != 0) > max_kernel_bindings)
        return error.InvalidKernelKey;
    if (parameters.len > @min(context.cache.resource_device.buffer_limits.max_uniform_buffer_range, context.cache.limits.v1.max_uniform_buffer_binding_size))
        return error.BindingRangeExceedsLimit;
    for (definition.slots, bindings, 0..) |slot, binding, index| switch (slot) {
        .buffer => |schema| {
            if (binding != .buffer) return error.KernelBindingTypeMismatch;
            const range = binding.buffer;
            try validateRange(context, range);
            if (range.size == 0 or range.size < schema.min_size) return error.BindingRangeOutsideBuffer;
            const uniform = schema.access == .uniform;
            const alignment = if (uniform) context.cache.limits.v1.min_uniform_buffer_offset_alignment else context.cache.limits.v1.min_storage_buffer_offset_alignment;
            const physical = &context.cache.native_device.physical.properties.limits;
            const physical_alignment = if (uniform) physical.minUniformBufferOffsetAlignment else physical.minStorageBufferOffsetAlignment;
            const selected_alignment = @max(@as(u64, alignment), physical_alignment);
            if (selected_alignment == 0 or range.offset % selected_alignment != 0)
                return error.DynamicOffsetUnaligned;
            const maximum = if (uniform)
                @min(@as(u64, context.cache.resource_device.buffer_limits.max_uniform_buffer_range), context.cache.limits.v1.max_uniform_buffer_binding_size)
            else
                @min(@as(u64, context.cache.resource_device.buffer_limits.max_storage_buffer_range), context.cache.limits.v1.max_storage_buffer_binding_size);
            if (range.size > maximum) return error.BindingRangeExceedsLimit;
            const storage = range.owner.native.internal_usage &
                (buffer.internal_storage_buffer | (api.BufferUsage{ .storage = true }).toFlags()) != 0;
            const allowed = switch (schema.access) {
                .uniform => range.owner.native.internal_usage & uniform_usage != 0,
                .storage_read => storage or
                    range.owner.native.internal_usage & buffer.read_only_storage_buffer != 0,
                .storage_write => storage,
            };
            if (!allowed) return error.InternalBufferUsageInvalid;
        },
        .sampled_view => |schema| {
            if (binding != .view) return error.KernelBindingTypeMismatch;
            const view = binding.view;
            try validateView(context, view);
            if (index == 0 and key.source_format != .undefined_ and view.format != key.source_format)
                return error.KernelBindingTypeMismatch;
            if (view.dimension != schema.dimension or
                (view.texture.sample_count > 1) != schema.multisampled)
                return error.KernelBindingTypeMismatch;
            if (!view.internal_usage.texture_binding) return error.BindingUsageInvalid;
            if (schema.depth_view and
                (schema.sample_type != .unfilterable_float or view.aspects.depth == 0 or
                    view.aspects.stencil != 0 or view.aspects.color != 0))
                return error.BindingTextureAspectInvalid;
            if (!schema.depth_view and view.aspects.depth != 0 and schema.sample_type != .depth)
                return error.KernelBindingTypeMismatch;
            const aspect: format.Aspect = @fromBackingInt(@intCast(view.aspects.toFlags()));
            const info = view.format_info.getAspectInfoForAspect(aspect) catch
                return error.BindingTextureAspectInvalid;
            const matches = if (schema.depth_view) info.supported_sample_types.depth else switch (schema.sample_type) {
                .float => info.supported_sample_types.float,
                .unfilterable_float => info.supported_sample_types.unfilterable_float,
                .sint => info.supported_sample_types.sint,
                .uint => info.supported_sample_types.uint,
                .depth => info.supported_sample_types.depth,
                else => false,
            };
            if (!matches) return error.KernelBindingTypeMismatch;
        },
        .storage_view => |schema| {
            if (binding != .view) return error.KernelBindingTypeMismatch;
            try validateView(context, binding.view);
            if (binding.view.format != schema.format or
                !binding.view.internal_usage.storage_binding or
                binding.view.texture.sample_count != 1 or binding.view.dimension != ._2d or
                !binding.view.format_info.caps.storage_write_only)
                return error.KernelBindingTypeMismatch;
        },
        .sampler => |schema| {
            if (binding != .sampler) return error.KernelBindingTypeMismatch;
            try validateOwner(context, &binding.sampler.header, .sampler);
            const native = binding.sampler.native orelse return error.BindingResourceInvalid;
            if (native.backend.handle != context.cache.resource_device.handle)
                return error.ResourceDeviceMismatch;
            if (native.conversion != null or binding.sampler.isComparison(context.guard) != schema.comparison)
                return error.KernelBindingTypeMismatch;
        },
        .combined_y_cb_cr_view => {
            if (binding != .view) return error.KernelBindingTypeMismatch;
            try validateView(context, binding.view);
            if (binding.view.dimension != ._2d or binding.view.texture.sample_count != 1)
                return error.KernelBindingTypeMismatch;
            if (binding.view.conversion_sampler != key.conversion_sampler or
                key.conversion_sampler == null or !binding.view.internal_usage.texture_binding)
                return error.KernelBindingTypeMismatch;
        },
    };
}

fn rootBindings(context: Context, key: KernelKey, bindings: []const Binding) Error!void {
    if (key.attachments) |state| try retainRoot(context, &state.header);
    if (key.conversion_sampler) |owner| try retainRoot(context, &owner.header);
    for (bindings) |binding| switch (binding) {
        .buffer => |range| try retainRoot(context, &range.owner.header),
        .sampler => |owner| try retainRoot(context, &owner.header),
        .view => |view| {
            try retainRoot(context, &view.header);
            try retainRoot(context, &view.texture.header);
            if (view.conversion_sampler) |owner| try retainRoot(context, &owner.header);
        },
    };
}

fn dimension(value: api.TextureViewDimension) Error!layout.TextureViewDimension {
    return switch (value) {
        ._1d => .one_d,
        ._2d => .two_d,
        ._2d_array => .two_d_array,
        ._3d => .three_d,
        .cube => .cube,
        .cube_array => .cube_array,
        .undefined_ => error.InvalidKernelKey,
    };
}

fn sampleType(value: api.TextureSampleType) Error!layout.TextureSampleType {
    return switch (value) {
        .float => .float_filterable,
        .unfilterable_float => .float_unfilterable,
        .sint => .sint,
        .uint => .uint,
        .depth => .depth,
        else => error.InvalidKernelKey,
    };
}

fn layoutEntry(slot: Slot, index: u32, stages: layout.ShaderStages) Error!layout.Entry {
    return .{ .binding_number = index, .visibility = stages, .kind = switch (slot) {
        .buffer => |schema| .{ .buffer = .{
            .binding_type = switch (schema.access) {
                .uniform => .uniform,
                .storage_read => .internal_read_only_storage,
                .storage_write => .internal_storage,
            },
            .has_dynamic_offset = false,
            .min_binding_size = schema.min_size,
        } },
        .sampled_view => |schema| .{ .sampled_texture = .{
            .sample_type = try sampleType(schema.sample_type),
            .view_dimension = try dimension(schema.dimension),
            .multisampled = schema.multisampled,
            .internal = true,
            .depth_view = schema.depth_view,
        } },
        .storage_view => .{ .storage_texture = .{
            .access = .write_only,
            .view_dimension = .two_d,
            .internal = true,
        } },
        .sampler => |schema| .{ .sampler = .{
            .binding_type = if (schema.comparison) .comparison else .filtering,
        } },
        .combined_y_cb_cr_view => .{ .static_sampler = .{
            .use = .single_texture_ycbcr,
            .sampled_texture_binding = null,
        } },
    } };
}

fn preflightPipelineProcs(context: Context, definition: *const Definition) Error!void {
    try preflightBufferProcs(context);
    const procs = context.cache.resource_device.procs;
    try requireProcs(procs, .{
        "create_shader_module",          "destroy_shader_module",   "create_descriptor_set_layout",
        "destroy_descriptor_set_layout", "create_pipeline_layout",  "destroy_pipeline_layout",
        "create_descriptor_pool",        "destroy_descriptor_pool", "allocate_descriptor_sets",
        "update_descriptor_sets",        "destroy_pipeline",        "cmd_bind_pipeline",
        "cmd_bind_descriptor_sets",
    });
    if (definition.parameter_size != 0) try requireProcs(procs, .{"cmd_update_buffer"});
    switch (definition.stages) {
        .compute => try requireProcs(procs, .{ "create_compute_pipelines", "cmd_dispatch" }),
        .render => {
            try requireProcs(procs, .{
                "create_graphics_pipelines", "cmd_draw", "cmd_set_viewport", "cmd_set_scissor",
                "cmd_set_stencil_reference",
            });
            if (definition.depth_range_push_constants) try requireProcs(procs, .{"cmd_push_constants"});
        },
    }
}

fn preflightOperation(context: Context, definition: *const Definition, bindings: []const Binding) Error!void {
    try preflightPipelineProcs(context, definition);
    const procs = context.cache.resource_device.procs;
    for (definition.slots, bindings) |slot, binding| switch (slot) {
        .sampled_view, .storage_view, .combined_y_cb_cr_view => {
            try requireProcs(procs, .{ "cmd_clear_color_image", "cmd_clear_depth_stencil_image" });
            if (binding.view.texture.format_info.is_compressed and
                !binding.view.texture.isSubresourceContentInitialized(context.guard, binding.view.range))
            {
                try requireProcs(procs, .{
                    "cmd_copy_buffer_to_image",   "map_memory", "unmap_memory",
                    "flush_mapped_memory_ranges",
                });
            }
        },
        else => {},
    };
}

fn createPipeline(context: Context, key: KernelKey, definition: *const Definition, render_pass: vulkan.VkRenderPass) Error!*resources.Pipeline {
    const allocator = context.device.arena.memory.child_allocator;
    const stages = bindingStages(definition);
    const visibility: layout.ShaderStages = .{ .compute = stages.compute, .fragment = stages.fragment };
    var entries: [max_kernel_bindings]layout.Entry = undefined;
    for (definition.slots, 0..) |slot, index| entries[index] = try layoutEntry(slot, @intCast(index), visibility);
    var entry_count = definition.slots.len;
    if (definition.parameter_size != 0) {
        entries[entry_count] = try layoutEntry(.{ .buffer = .{
            .access = .uniform,
            .min_size = definition.parameter_size,
        } }, @intCast(entry_count), visibility);
        entry_count += 1;
    }
    var immutable: [1]resources.ImmutableSamplerBinding = undefined;
    var immutable_count: usize = 0;
    for (definition.slots, 0..) |slot, index| if (slot == .combined_y_cb_cr_view) {
        if (immutable_count != 0) return error.InvalidKernelKey;
        immutable[0] = .{ .binding = @intCast(index), .sampler = key.conversion_sampler orelse return error.InvalidKernelKey };
        entries[index].kind.static_sampler.?.sampler_identity =
            @intFromPtr(&immutable[0].sampler.header);
        immutable_count = 1;
    };
    const compatibility = context.cache.limits.compatibility orelse return error.InvalidKernelKey;
    const group = try resources.createBindGroupLayout(allocator, context.io, context.guard, &context.device.arena, context.cache.resource_device, .{
        .descriptor = .{ .entries = entries[0..entry_count] },
        .validation = .{
            .max_storage_buffers_in_vertex_stage = compatibility.max_storage_buffers_in_vertex_stage,
            .max_storage_buffers_in_fragment_stage = compatibility.max_storage_buffers_in_fragment_stage,
            .allow_internal_bindings = true,
        },
        .allow_internal_bindings = true,
        .immutable_samplers = immutable[0..immutable_count],
    });
    defer group.header.releaseUserLocked(context.guard, context.io) catch unreachable;
    const immediate_size: u32 = if (definition.depth_range_push_constants) 8 else 0;
    const pipeline_layout = try resources.createInternalPipelineLayout(allocator, context.io, context.guard, &context.device.arena, context.cache.resource_device, .{ .groups = &.{group}, .immediate_size = immediate_size }, context.cache.native_device.physical.properties.limits.maxPushConstantsSize);
    defer pipeline_layout.header.releaseUserLocked(context.guard, context.io) catch unreachable;
    var shaders: [2]*resources.ShaderModule = undefined;
    var shader_count: usize = 0;
    defer for (shaders[0..shader_count]) |module|
        module.header.releaseUserLocked(context.guard, context.io) catch unreachable;
    const handle = switch (definition.stages) {
        .compute => |compute| blk: {
            shaders[0] = try resources.createShaderModule(allocator, context.io, context.guard, &context.device.arena, context.cache.resource_device, .{ .words = compute.stage.words });
            shader_count = 1;
            const descriptor = try (resources.ComputePipelineDescriptor{
                .layout = pipeline_layout,
                .compute = .{
                    .module = shaders[0],
                    .stage = .compute,
                    .entry_point = compute.stage.entry_point,
                },
            }).toNative(context.guard, .{
                .max_workgroup_size = .{
                    context.cache.limits.v1.max_compute_workgroup_size_x,
                    context.cache.limits.v1.max_compute_workgroup_size_y,
                    context.cache.limits.v1.max_compute_workgroup_size_z,
                },
                .max_invocations = context.cache.limits.v1.max_compute_invocations_per_workgroup,
            }, context.cache.native_device.maintenance4_enabled);
            break :blk try pipeline.createComputePipelineLocked(allocator, context.io, context.guard, context.device, context.cache.pipeline_store, context.cache.pipeline_backend, descriptor, .lease);
        },
        .render => |render| blk: {
            shaders[0] = try resources.createShaderModule(allocator, context.io, context.guard, &context.device.arena, context.cache.resource_device, .{ .words = render.vertex.words });
            shader_count = 1;
            shaders[1] = try resources.createShaderModule(allocator, context.io, context.guard, &context.device.arena, context.cache.resource_device, .{ .words = render.fragment.words });
            shader_count = 2;
            const state = &key.attachments.?.value;
            var colors: [8]pipeline.ColorTargetState = undefined;
            var color_count: usize = 0;
            for (0..8) |index| {
                const mask = @as(u8, 1) << @as(u3, @intCast(index));
                const present = state.color_attachments_set & mask != 0;
                colors[index] = .{
                    .format = if (present) vulkan_format.vkFormat(@fromBackingInt(@intCast(state.color_formats[index]))) else 0,
                    .write_mask = if (key.color_write_slots & mask != 0) 0xF else 0,
                    .blend = null,
                };
                if (present) color_count = index + 1;
            }
            var depth: ?pipeline.DepthStencilState = null;
            if (state.depth_stencil_format != 0) {
                depth = .{
                    .format = vulkan_format.vkFormat(@fromBackingInt(@intCast(state.depth_stencil_format))),
                    .depth_write_enabled = render.fixed_state.depth_output,
                    .depth_compare = .always,
                    .stencil_write_mask = if (render.fixed_state.stencil_replace)
                        @as(u32, 1) << key.stencil_write_bit.?
                    else
                        0,
                    .stencil_front = .{ .compare = .always, .pass_op = if (render.fixed_state.stencil_replace) .replace else .keep },
                    .stencil_back = .{ .compare = .always, .pass_op = if (render.fixed_state.stencil_replace) .replace else .keep },
                };
            }
            const descriptor: pipeline.RenderPipelineDescriptor = .{
                .compatible_render_pass = render_pass,
                .layout = try pipeline_layout.input(context.guard),
                .vertex = try (resources.StageOptions{ .module = shaders[0], .stage = .vertex, .entry_point = render.vertex.entry_point }).input(context.guard, pipeline_layout),
                .fragment = try (resources.StageOptions{ .module = shaders[1], .stage = .fragment, .entry_point = render.fragment.entry_point, .usage = .{ .frag_depth = render.fixed_state.depth_output } }).input(context.guard, pipeline_layout),
                .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
                .depth_stencil = depth,
                .multisample = .{ .count = state.sample_count },
                .color_targets = colors[0..color_count],
            };
            break :blk try pipeline.createRenderPipelineLocked(allocator, context.io, context.guard, context.device, context.cache.pipeline_store, context.cache.pipeline_backend, descriptor, .lease);
        },
    };
    const native = try context.device.resolve(context.guard, pipeline.Pipeline, handle);
    errdefer native.header.releaseLeaseLocked(context.guard, context.io);
    return resources.createPipelineWrapper(allocator, context.io, context.guard, &context.device.arena, native, if (definition.stages == .compute) .compute else .{ .render = key.attachments.? }, shaders[0..shader_count]);
}

fn resolvePipeline(context: Context, key: KernelKey, definition: *const Definition, render_pass: vulkan.VkRenderPass) Error!*resources.Pipeline {
    var first_empty: ?usize = null;
    for (context.cache.entries, 0..) |maybe_entry, index| {
        if (maybe_entry) |entry| {
            if (definitions.eql(entry.key, key)) {
                try retainRoot(context, &entry.pipeline.header);
                return entry.pipeline;
            }
        } else if (first_empty == null) first_empty = index;
    }
    const owner = try createPipeline(context, key, definition, render_pass);
    var creator_owned = true;
    defer if (creator_owned) owner.header.releaseUserLocked(context.guard, context.io) catch unreachable;
    try owner.header.retainLeaseLocked(context.guard);
    errdefer owner.header.releaseLeaseLocked(context.guard, context.io);
    // A failure here leaves every cache entry and the FIFO cursor unchanged.
    try retainRoot(context, &owner.header);
    owner.header.releaseUserLocked(context.guard, context.io) catch unreachable;
    creator_owned = false;
    const index = first_empty orelse context.cache.next_victim;
    const evicted = context.cache.entries[index];
    context.cache.entries[index] = .{ .key = key, .pipeline = owner };
    if (first_empty == null) context.cache.next_victim = @intCast((index + 1) % KernelCache.capacity);
    if (evicted) |entry| entry.pipeline.header.releaseLeaseLocked(context.guard, context.io);
    return owner;
}

fn prepareBindings(context: Context, key: KernelKey, definition: *const Definition, owner: *resources.Pipeline, bindings: []const Binding, parameters: []const u8) Error!?*resources.BindGroup {
    const stages = bindingStages(definition);
    var packed_bindings: [max_kernel_bindings]resources.Binding = undefined;
    for (definition.slots, bindings, 0..) |slot, binding, index| packed_bindings[index] = switch (slot) {
        .buffer => |schema| .{ .buffer = .{
            .binding = @intCast(index),
            .buffer = binding.buffer.owner,
            .offset = binding.buffer.offset,
            .size = binding.buffer.size,
            .kind = switch (schema.access) {
                .uniform => .uniform,
                .storage_read => .internal_read_only_storage,
                .storage_write => .internal_storage,
            },
            .alignment = if (schema.access == .uniform)
                context.cache.limits.v1.min_uniform_buffer_offset_alignment
            else
                context.cache.limits.v1.min_storage_buffer_offset_alignment,
            .stages = stages,
        } },
        .sampled_view => |schema| .{ .texture = .{
            .binding = @intCast(index),
            .view = binding.view,
            .internal = true,
            .depth_view = schema.depth_view,
            .stages = stages,
        } },
        .storage_view => .{ .texture = .{ .binding = @intCast(index), .view = binding.view, .storage = true, .internal = true, .stages = stages } },
        .sampler => .{ .sampler = .{ .binding = @intCast(index), .sampler = binding.sampler } },
        .combined_y_cb_cr_view => .{ .combined_y_cb_cr_view = .{
            .binding = @intCast(index),
            .view = binding.view,
            .sampler = key.conversion_sampler.?,
            .stages = stages,
        } },
    };
    var count = bindings.len;
    var parameter_range: ?BufferRange = null;
    if (parameters.len != 0) {
        parameter_range = try parameterBuffer(context, parameters.len);
        packed_bindings[count] = .{ .buffer = .{
            .binding = @intCast(count),
            .buffer = parameter_range.?.owner,
            .offset = 0,
            .size = parameters.len,
            .kind = .uniform,
            .alignment = context.cache.limits.v1.min_uniform_buffer_offset_alignment,
            .stages = stages,
        } };
        count += 1;
    }
    const group = if (count == 0) null else try resources.createBindGroup(
        context.device.arena.memory.child_allocator,
        context.io,
        context.guard,
        &context.device.arena,
        context.cache.resource_device,
        .{ .layout = owner.layout, .group_index = 0, .bindings = packed_bindings[0..count] },
    );
    defer if (group) |value| value.header.releaseUserLocked(context.guard, context.io) catch unreachable;
    if (group) |value| try retainRoot(context, &value.header);
    const recording = try nativeRecording(context);
    var emitted = false;
    errdefer if (emitted) context.queue.poisonRecording();
    if (parameter_range) |range| {
        try uploadParameters(context, range, parameters);
        emitted = true;
        try range.owner.native.transitionUsageNow(recording, uniform_usage, stages);
    }
    for (definition.slots, bindings) |slot, binding| switch (slot) {
        .buffer => {
            emitted = true;
            context.recording.needs_submit = true;
            try binding.buffer.owner.native.ensureDataInitializedAsDestination(recording, 0, 0);
            try binding.buffer.owner.native.transitionUsageNow(recording, slotUsage(slot), stages);
        },
        .sampled_view, .storage_view, .combined_y_cb_cr_view => {
            emitted = true;
            context.recording.needs_submit = true;
            const view = binding.view;
            try view.texture.ensureSubresourceContentInitialized(context.guard, context.queue, recording, view.range);
            try view.texture.transition(context.guard, recording, view.range, if (slot == .storage_view) .{ .storage_binding = true } else .{ .texture_binding = true }, stages);
        },
        .sampler => {},
    };
    return group;
}

pub fn recordCompute(context: Context, command: Compute) Error!void {
    try outsidePass(context);
    const definition = try definitions.definition(command.key);
    if (definition.stages != .compute) return error.InvalidKernelKey;
    try validateKeyOwner(context, command.key, definition);
    try validateBindings(context, command.key, definition, command.bindings, command.parameters);
    const physical = &context.cache.native_device.physical.properties.limits;
    for (command.workgroups, 0..) |count, axis|
        if (count > context.cache.limits.v1.max_compute_workgroups_per_dimension or
            count > physical.maxComputeWorkGroupCount[axis]) return error.KernelDispatchLimitExceeded;
    try preflightOperation(context, definition, command.bindings);
    try rootBindings(context, command.key, command.bindings);
    const owner = try resolvePipeline(context, command.key, definition, null);
    const group = try prepareBindings(context, command.key, definition, owner, command.bindings, command.parameters);
    const procs = context.cache.resource_device.procs;
    context.recording.needs_submit = true;
    procs.cmd_bind_pipeline.?(context.recording.command_buffer, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE, owner.native.vk_pipeline);
    if (group) |value| {
        const set = value.native.descriptor_allocation.set;
        procs.cmd_bind_descriptor_sets.?(context.recording.command_buffer, vulkan.VK_PIPELINE_BIND_POINT_COMPUTE, owner.native.vk_layout, 0, 1, &set, 0, null);
    }
    procs.cmd_dispatch.?(context.recording.command_buffer, command.workgroups[0], command.workgroups[1], command.workgroups[2]);
}

pub fn prepareDraw(context: Context, command: DrawPreparation) Error!PreparedDraw {
    try outsidePass(context);
    const definition = try definitions.definition(command.key);
    if (definition.stages != .render) return error.InvalidKernelKey;
    if (command.compatible_render_pass == null) return error.CompatibleRenderPassMissing;
    try validateKeyOwner(context, command.key, definition);
    try validateBindings(context, command.key, definition, command.bindings, command.parameters);
    try preflightOperation(context, definition, command.bindings);
    try rootBindings(context, command.key, command.bindings);
    const owner = try resolvePipeline(context, command.key, definition, command.compatible_render_pass);
    const group = try prepareBindings(context, command.key, definition, owner, command.bindings, command.parameters);
    return .{ .command_buffer = context.recording.command_buffer, .pending_uses = context.pending_uses, .pipeline = owner, .bind_group = group };
}

fn validateReusedBindings(key: KernelKey, definition: *const Definition, group: ?*resources.BindGroup) Error!void {
    const expected_count = definition.slots.len + @intFromBool(definition.parameter_size != 0);
    if (group == null) {
        if (expected_count != 0) return error.KernelBindingCountMismatch;
        return;
    }
    const bindings = group.?.native.bindings;
    if (bindings.len != expected_count) return error.KernelBindingCountMismatch;
    for (definition.slots, bindings[0..definition.slots.len], 0..) |slot, binding, index| {
        switch (slot) {
            .buffer => |schema| {
                if (binding != .buffer) return error.KernelBindingTypeMismatch;
                if (binding.buffer.size < schema.min_size) return error.BindingRangeOutsideBuffer;
            },
            .sampled_view => |schema| {
                if (binding != .texture) return error.KernelBindingTypeMismatch;
                if (binding.texture.depth_view != schema.depth_view)
                    return error.KernelBindingTypeMismatch;
                if (schema.depth_view and
                    (binding.texture.view.aspects.depth == 0 or
                        binding.texture.view.aspects.stencil != 0 or
                        binding.texture.view.aspects.color != 0))
                    return error.BindingTextureAspectInvalid;
                if (index == 0 and key.source_format != .undefined_ and
                    binding.texture.view.format != key.source_format)
                    return error.KernelBindingTypeMismatch;
            },
            .storage_view => |schema| {
                if (binding != .texture or binding.texture.view.format != schema.format)
                    return error.KernelBindingTypeMismatch;
            },
            .sampler => if (binding != .sampler) return error.KernelBindingTypeMismatch,
            .combined_y_cb_cr_view => {
                if (binding != .combined_y_cb_cr_view or
                    binding.combined_y_cb_cr_view.sampler != key.conversion_sampler)
                    return error.KernelBindingTypeMismatch;
            },
        }
    }
    if (definition.parameter_size != 0) {
        const binding = bindings[definition.slots.len];
        if (binding != .buffer or binding.buffer.kind != .uniform)
            return error.KernelBindingTypeMismatch;
        if (binding.buffer.size != definition.parameter_size)
            return error.KernelParameterSizeMismatch;
    }
}

pub fn prepareDrawReuseBindings(context: Context, options: DrawBindingsReuse) Error!PreparedDraw {
    try outsidePass(context);
    const first = options.prepared;
    if (first.command_buffer != context.recording.command_buffer or
        first.pending_uses != context.pending_uses)
        return error.KernelAttachmentMismatch;
    try validateOwner(context, &first.pipeline.header, .native_pipeline);
    if (first.pipeline.attachment != .render or
        !context.pending_uses.roots.contains(&first.pipeline.header))
        return error.KernelAttachmentMismatch;
    if (first.bind_group) |group| {
        try validateOwner(context, &group.header, .bind_group);
        if (group.layout != first.pipeline.layout or
            !context.pending_uses.roots.contains(&group.header))
            return error.KernelAttachmentMismatch;
    }
    try context.pending_uses.validateGpuRootsLocked(context.guard, context.device);
    const definition = try definitions.definition(options.key);
    if (definition.stages != .render) return error.InvalidKernelKey;
    if (options.compatible_render_pass == null) return error.CompatibleRenderPassMissing;
    try validateKeyOwner(context, options.key, definition);
    try validateReusedBindings(options.key, definition, first.bind_group);
    try preflightPipelineProcs(context, definition);
    try rootBindings(context, options.key, &.{});
    const owner = try resolvePipeline(context, options.key, definition, options.compatible_render_pass);
    if (owner.layout != first.pipeline.layout) return error.BindGroupLayoutMismatch;
    return .{
        .command_buffer = first.command_buffer,
        .pending_uses = first.pending_uses,
        .pipeline = owner,
        .bind_group = first.bind_group,
    };
}

pub fn recordDraw(context: Context, command: Draw) Error!void {
    try validateContext(context);
    errdefer if (context.recording.active_render_pass != null) context.queue.poisonRecording();
    const owner = command.prepared.pipeline;
    if (command.render_pass == null or context.recording.active_render_pass != command.render_pass or
        command.prepared.command_buffer != context.recording.command_buffer or
        command.prepared.pending_uses != context.pending_uses)
        return error.KernelAttachmentMismatch;
    try validateOwner(context, &owner.header, .native_pipeline);
    try validateOwner(context, &command.attachments.header, .attachment_state);
    if (!context.pending_uses.roots.contains(&owner.header) or
        !context.pending_uses.roots.contains(&command.attachments.header)) return error.NoOwnedReference;
    if (owner.attachment != .render or owner.attachment.render != command.attachments)
        return error.KernelAttachmentMismatch;
    if (command.prepared.bind_group) |group| {
        try validateOwner(context, &group.header, .bind_group);
        if (group.layout != owner.layout or !context.pending_uses.roots.contains(&group.header))
            return error.KernelAttachmentMismatch;
    }
    const viewport = command.viewport;
    const physical = &context.cache.native_device.physical.properties.limits;
    if (!std.math.isFinite(viewport.x) or !std.math.isFinite(viewport.y) or
        !std.math.isFinite(viewport.width) or !std.math.isFinite(viewport.height) or
        !std.math.isFinite(viewport.minDepth) or !std.math.isFinite(viewport.maxDepth) or
        viewport.width <= 0 or viewport.height <= 0 or viewport.minDepth < 0 or
        viewport.maxDepth > 1 or viewport.minDepth > viewport.maxDepth or
        viewport.width > @as(f32, @floatFromInt(physical.maxViewportDimensions[0])) or
        viewport.height > @as(f32, @floatFromInt(physical.maxViewportDimensions[1])) or
        viewport.x < physical.viewportBoundsRange[0] or viewport.y < physical.viewportBoundsRange[0] or
        viewport.x + viewport.width > physical.viewportBoundsRange[1] or
        viewport.y + viewport.height > physical.viewportBoundsRange[1])
        return error.KernelAttachmentMismatch;
    if (command.scissor.offset.x < 0 or command.scissor.offset.y < 0 or
        command.scissor.extent.width > std.math.maxInt(i32) - @as(u32, @intCast(command.scissor.offset.x)) or
        command.scissor.extent.height > std.math.maxInt(i32) - @as(u32, @intCast(command.scissor.offset.y)))
        return error.KernelAttachmentMismatch;
    const private_depth = owner.native.immediate_size == 8;
    if (owner.native.immediate_size != 0 and !private_depth) return error.InvalidKernelKey;
    if (private_depth and (viewport.minDepth != 0 or viewport.maxDepth != 1 or
        owner.native.immediate_mask != 3 or
        owner.native.immediate_stages & vulkan.VK_SHADER_STAGE_FRAGMENT_BIT == 0))
        return error.KernelAttachmentMismatch;
    const procs = context.cache.resource_device.procs;
    try requireProcs(procs, .{
        "cmd_bind_pipeline",         "cmd_bind_descriptor_sets", "cmd_set_viewport", "cmd_set_scissor",
        "cmd_set_stencil_reference", "cmd_draw",
    });
    if (private_depth) try requireProcs(procs, .{"cmd_push_constants"});
    // No fallible operation follows the first native bind.
    context.recording.needs_submit = true;
    procs.cmd_bind_pipeline.?(context.recording.command_buffer, vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS, owner.native.vk_pipeline);
    if (command.prepared.bind_group) |group| {
        const set = group.native.descriptor_allocation.set;
        procs.cmd_bind_descriptor_sets.?(context.recording.command_buffer, vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS, owner.native.vk_layout, 0, 1, &set, 0, null);
    }
    if (private_depth) {
        const depth_range: [2]f32 = .{ 0, 1 };
        procs.cmd_push_constants.?(context.recording.command_buffer, owner.native.vk_layout, vulkan.VK_SHADER_STAGE_ALL, 0, 8, &depth_range);
    }
    procs.cmd_set_viewport.?(context.recording.command_buffer, 0, 1, &command.viewport);
    procs.cmd_set_scissor.?(context.recording.command_buffer, 0, 1, &command.scissor);
    procs.cmd_set_stencil_reference.?(context.recording.command_buffer, vulkan.VK_STENCIL_FACE_FRONT_AND_BACK, command.stencil_reference);
    procs.cmd_draw.?(context.recording.command_buffer, 3, 1, 0, 0);
}
