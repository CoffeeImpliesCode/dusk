//! Stable native owners and submission leases in the high device's core arena.
//! ObjectGuard protects identity, payload admission, dependencies and retirement.
//! Recording roots stay leased until the actual submitted serial completes.
const std = @import("std");
const vulkan = @import("vulkan");
const core = @import("../core/root.zig");
const descriptors = @import("../api/descriptors.zig");
const dispatch = @import("../vk/dispatch.zig");
const commands = @import("../command/commands.zig");
const encoding_context = @import("../command/encoding_context.zig");
const command_allocator = @import("../command/allocator.zig");
const command_errors = @import("../command/errors.zig");
const buffer = @import("buffer.zig");
const texture = @import("texture.zig");
const groups = @import("bind_group.zig");
const shader = @import("../pipeline/shader_module.zig");
const shader_vk = @import("../pipeline/shader_module_vk.zig");
const layout = @import("../pipeline/layout_internal.zig");
const layout_vk = @import("../pipeline/layout_vk.zig");
const descriptor = @import("../pipeline/bind_group_descriptor_set.zig");
const pipeline = @import("../pipeline/pipeline.zig");
const resource_store = @import("native_resource_store.zig");
const sampler = @import("sampler.zig");
const attachments = @import("../command/attachment_state.zig");
const render_state = @import("native_render_state.zig");
const render_bundle = @import("../command/render_bundle.zig");
const tracker = @import("../command/state_tracker.zig");
const command_constants = @import("../command/constants.zig");
const tokens = @import("../pipeline/bind_group_layout.zig");
const api = @import("../api/api.zig");
const low_render = @import("../pipeline/pipeline_render.zig");
const render_encoder = @import("../command/render_encoder_base.zig");
const query_set = @import("query_set.zig");
const replay = @import("command_buffer.zig");
const usage = @import("../command/usage.zig");
const external_texture = @import("external_texture.zig");
const browser_copy = @import("../command/browser_copy.zig");
const shader_reflect = @import("../pipeline/shader_reflect.zig");

/// Construction, recorded-command validation and terminal native cleanup failures.
pub const Error = core.Error || core.ReferenceError || core.CreateError || core.LifetimeError ||
    std.mem.Allocator.Error || std.Io.ConcurrentError || buffer.Error ||
    groups.Error || shader.CreateError || layout.Error || layout_vk.Error ||
    command_errors.Error || sampler.NativeCreateError || attachments.AttachmentError || texture.NativeError ||
    external_texture.ValidationError || browser_copy.Error || shader_reflect.ShaderBindingError ||
    pipeline.PipelineError || tokens.TokenCounter.MintError || error{
    ResourceDestroyed,
    ResourceDeviceMismatch,
    BindGroupIndexInvalid,
    PipelineCompatibilityTokenMismatch,
    PipelineTypeMismatch,
    ImmediateSizeInvalid,
    TooManyBindGroups,
    InvalidCommandStream,
    CommandCountExhausted,
    BundleDepthExhausted,
    BundleCycle,
    InvalidBundle,
    InvalidResourceRef,
    InvalidAttachment,
    UnsupportedResolveExpansion,
    InvalidClearValue,
    ImmediateUnaligned,
    ImmediateOutOfRange,
    DepthStencilFormatNotRenderable,
};

/// Dispatch and allocation seams borrow the stable native device context.
pub const NativeDevice = struct {
    procs: *const dispatch.DeviceProcs,
    handle: vulkan.VkDevice,
    api_version: u32,
    buffer_limits: groups.BufferLimits,
    buffer_device: buffer.Device,
    resource_store: ?*resource_store.ResourceStore = null,
    sampler_backend: ?*const sampler.NativeBackend = null,
    cleanup_context: ?*anyopaque = null,
    record_cleanup_error: ?*const fn (*anyopaque, Error) void = null,

    fn recordCleanup(self: NativeDevice, err: Error) void {
        if (self.record_cleanup_error) |callback| callback(self.cleanup_context.?, err);
    }
};

fn checkDependencyOwner(guard: *const core.ObjectGuard, header: *const core.Object) Error!void {
    if (header.tracking != guard.objects) return error.ResourceDeviceMismatch;
    guard.assertOwns(header.tracking);
    if (!header.node.linked or header.state != .alive or header.reference_count == 0)
        return error.ResourceDestroyed;
}

fn checkDependency(arena: *core.ObjectArena, guard: *const core.ObjectGuard, header: *const core.Object) Error!void {
    guard.assertOwns(arena.objectList());
    if (header.tracking != arena.objectList()) return error.ResourceDeviceMismatch;
    if (!header.node.linked or header.state != .alive or header.reference_count == 0)
        return error.ResourceDestroyed;
}

fn checkFactory(allocator: std.mem.Allocator, guard: *const core.ObjectGuard, arena: *core.ObjectArena) Error!void {
    try arena.checkAllocator(guard, allocator);
    if (arena.objectList().marked_destroyed) return error.ResourceDestroyed;
}

fn checkStore(
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
    device: NativeDevice,
) Error!void {
    if (device.resource_store) |store| {
        if (store.objects != arena.objectList()) return error.ResourceDeviceMismatch;
        guard.assertOwns(store.objects);
    }
}

/// Owns an existing native buffer. Its host payload stays in the core arena;
/// release frees its Vulkan memory. Copies are aliases, not independent owners.
pub const Buffer = struct {
    header: core.Object,
    native: *buffer.Buffer,
    allocator: std.mem.Allocator,
    device: NativeDevice,
    cleanup_error: ?Error = null,
    /// Real accepted GPU serial; pending recording marks are not completion targets.
    accepted_usage_serial: buffer.Serial = 0,
    /// Derived classifications of actual header leases, not another Rc authority.
    mapping_leases: u32 = 0,
    queue_uses: u32 = 0,
    native_retirement_pending: bool = false,

    /// Borrows a replay pointer only while this owner's payload is admitted.
    pub fn ref(self: *Buffer, guard: *const core.ObjectGuard) Error!commands.Ref {
        try checkDependencyOwner(guard, &self.header);
        return self.native;
    }
    /// Invalidates API mapping immediately; real queue/mapping leases defer native free.
    pub fn destroy(self: *Buffer, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        _ = io;
        _ = reason;
        self.native.state = .destroyed;
        self.native_retirement_pending = true;
        self.finishNativeRetirementLocked(guard);
    }

    fn finishNativeRetirementLocked(self: *Buffer, guard: *const core.ObjectGuard) void {
        guard.assertOwns(self.header.tracking);
        if (!self.native_retirement_pending or self.mapping_leases != 0 or self.queue_uses != 0) return;
        self.native_retirement_pending = false;
        self.native.destroy(self.allocator) catch |err| {
            self.cleanup_error = err;
            self.device.recordCleanup(err);
        };
    }

    /// Classifies the caller's already-owned header lease; it adds no reference.
    pub fn adoptMappingLeaseLocked(self: *Buffer, guard: *const core.ObjectGuard) void {
        guard.assertOwns(self.header.tracking);
        std.debug.assert(self.header.state == .alive);
        std.debug.assert(self.mapping_leases < std.math.maxInt(u32));
        self.mapping_leases += 1;
    }
    /// Consumes that exact mapping classification and actual header lease.
    pub fn releaseMappingLeaseLocked(self: *Buffer, guard: *const core.ObjectGuard, io: std.Io) void {
        guard.assertOwns(self.header.tracking);
        std.debug.assert(self.mapping_leases != 0);
        self.mapping_leases -= 1;
        self.finishNativeRetirementLocked(guard);
        self.header.releaseLeaseLocked(guard, io);
    }
    fn adoptQueueUseLocked(self: *Buffer, guard: *const core.ObjectGuard) void {
        guard.assertOwns(self.header.tracking);
        std.debug.assert(self.queue_uses < std.math.maxInt(u32));
        self.queue_uses += 1;
    }
    fn releaseQueueUseLocked(self: *Buffer, guard: *const core.ObjectGuard) void {
        guard.assertOwns(self.header.tracking);
        std.debug.assert(self.queue_uses != 0);
        self.queue_uses -= 1;
        self.finishNativeRetirementLocked(guard);
    }
};

/// Creates native storage with stable host addresses in the supplied core arena.
/// Staging owners use the original allocator; retired replay identities stay arena-stable.
pub fn createBuffer(
    allocator: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
    device: NativeDevice,
    options: buffer.BufferDescriptor,
) Error!*Buffer {
    return createBufferOwner(allocator, io, guard, arena, device, options, false);
}

/// Creates an ordinary arena Buffer with private native usage and one user alias.
pub fn createInternalBufferLocked(
    allocator: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
    device: NativeDevice,
    options: buffer.InternalBufferDescriptor,
) Error!*Buffer {
    return createBufferOwner(allocator, io, guard, arena, device, options, true);
}

fn createBufferOwner(
    allocator: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
    device: NativeDevice,
    options: anytype,
    comptime internal: bool,
) Error!*Buffer {
    try checkFactory(allocator, guard, arena);
    const self = try arena.create(allocator, guard, Buffer, .{ .kind = .native_buffer, .initial_reference = .user });
    errdefer self.header.discardUnpublishedLocked(guard) catch unreachable;
    const native_allocator = arena.allocator(guard);
    var buffer_device = device.buffer_device;
    buffer_device.allocator = allocator;
    const native = if (internal)
        try buffer.Buffer.createInternal(native_allocator, buffer_device, options)
    else
        try buffer.Buffer.create(native_allocator, buffer_device, options);
    self.native = native;
    self.allocator = native_allocator;
    self.device = device;
    self.cleanup_error = null;
    self.accepted_usage_serial = 0;
    self.mapping_leases = 0;
    self.queue_uses = 0;
    self.native_retirement_pending = false;
    self.header.attach(guard, io);
    return self;
}

/// Returns a canonical native Sampler user alias under the original guard.
pub fn createSamplerLocked(
    allocator: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
    device: NativeDevice,
    options: descriptors.SamplerDescriptorChain,
) Error!*sampler.Sampler {
    try checkFactory(allocator, guard, arena);
    try checkStore(guard, arena, device);
    const backend = device.sampler_backend orelse return error.MissingDeviceProc;
    if (backend.handle != device.handle) return error.ResourceDeviceMismatch;
    const key = try sampler.semanticKey(options);
    try backend.validate(key);
    const hash = key.hash();
    if (device.resource_store) |store| {
        if (store.samplers.find(guard, hash, key, resource_store.samplerMatches)) |existing| {
            try existing.header.acquireUserLocked(guard);
            return existing;
        }
    }
    const result = try sampler.Sampler.createNative(
        allocator,
        io,
        guard,
        arena,
        backend.*,
        options,
    );
    errdefer result.header.releaseUserLocked(guard, io) catch unreachable;
    if (device.resource_store) |store| try store.samplers.insert(guard, result, hash);
    return result;
}

/// Caller SPIR-V is copied unchanged. The empty label names no debug label.
pub const ShaderModuleOptions = struct { label: []const u8 = "", words: []const u32 };
/// Owns reflection metadata, unchanged shader words and the Vulkan shader module.
/// The allocator and dispatch are borrowed until release; copies alias ownership.
pub const ShaderModule = struct {
    header: core.Object,
    native: shader.ShaderModule,
    device: shader_vk.Device,
    words: []u32,
    owner_device: NativeDevice,
    allocator: std.mem.Allocator,
    cleanup_error: ?Error = null,
    cache_hash: u64 = 0,
    cache_next: ?*ShaderModule = null,

    /// Core callback; saves native errors and frees reflection/word storage.
    pub fn destroy(self: *ShaderModule, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        _ = io;
        _ = reason;
        // Error shaders own diagnostics but have no Vulkan module to destroy.
        const native_device = if (self.native.vk_module != null) &self.device else null;
        self.native.destroy(native_device) catch |err| {
            self.cleanup_error = err;
            self.owner_device.recordCleanup(err);
        };
        self.allocator.free(self.words);
        self.words = &.{};
    }
};

/// Blocks for concurrent validation/reflection before native shader creation.
/// Failure attaches no owner; arena-reserved host storage remains until teardown.
pub fn createShaderModule(
    allocator: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
    device: NativeDevice,
    options: ShaderModuleOptions,
) Error!*ShaderModule {
    try checkFactory(allocator, guard, arena);
    try checkStore(guard, arena, device);
    if (device.procs.destroy_shader_module == null) return error.MissingDeviceProc;
    const hash = resource_store.shaderHash(options.words);
    if (device.resource_store) |store| {
        if (store.shader_modules.find(guard, hash, options.words, resource_store.shaderMatches)) |existing| {
            try existing.header.acquireUserLocked(guard);
            return existing;
        }
    }
    const self = try arena.create(allocator, guard, ShaderModule, .{
        .kind = .shader_module,
        .label = options.label,
        .initial_reference = .user,
    });
    var published = false;
    errdefer if (!published) self.header.discardUnpublishedLocked(guard) catch unreachable;
    const words = try allocator.dupe(u32, options.words);
    errdefer if (!published) allocator.free(words);
    self.device = shader_vk.Device.init(device.procs, device.handle, device.api_version);
    var future = try shader.createShaderModule(allocator, io, &self.device, .{
        .label = self.header.label,
        .words = words,
    });
    self.native = try future.await(io);
    self.words = words;
    self.allocator = allocator;
    self.owner_device = device;
    self.cleanup_error = null;
    self.cache_hash = 0;
    self.cache_next = null;
    self.header.attach(guard, io);
    published = true;
    errdefer self.header.releaseUserLocked(guard, io) catch unreachable;
    if (!self.native.failed) {
        if (device.resource_store) |store| try store.shader_modules.insert(guard, self, hash);
    }
    return self;
}

/// Descriptor entries are borrowed only through validated layout construction.
pub const ImmutableSamplerBinding = struct {
    binding: u32,
    sampler: *sampler.Sampler,
};

pub const BindGroupLayoutOptions = struct {
    descriptor: layout.Descriptor,
    validation: layout.ValidateOptions,
    compatibility_token: u64 = 0,
    allow_internal_bindings: bool = false,
    immutable_samplers: []const ImmutableSamplerBinding = &.{},
};
/// Owns packed metadata and its native descriptor-set layout.
/// Retains the explicit allocator and native-device borrow until release.
pub const BindGroupLayout = struct {
    header: core.Object,
    internal: layout.Layout,
    native: pipeline.GroupLayout,
    device: NativeDevice,
    allocator: std.mem.Allocator,
    cleanup_error: ?Error = null,
    compatibility_token: u64,
    immutable_samplers: []const ImmutableSamplerBinding,
    cache_hash: u64 = 0,
    cache_next: ?*BindGroupLayout = null,

    /// Returns the actual canonical external expansion under its original owner guard.
    pub fn queryExternalBindingNumbers(
        self: *const BindGroupLayout,
        guard: *const core.ObjectGuard,
        binding_number: u32,
    ) Error!layout.ExternalBindingNumbers {
        try checkDependencyOwner(guard, &self.header);
        if (self.header.kind != .bind_group_layout) return error.BindingResourceInvalid;
        if (binding_number >= layout.max_bindings_per_bind_group)
            return error.BindingNumberAboveLimit;
        return self.internal.queryExternalBindingNumbers(binding_number) orelse
            error.BindingResourceInvalid;
    }

    /// Core callback; captures cleanup failure and releases metadata.
    pub fn destroy(self: *BindGroupLayout, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        // Native layout users retire before their actual immutable sampler edges.
        _ = reason;
        layout_vk.destroyDescriptorSetLayout(
            self.device.procs,
            self.device.handle,
            self.native.handle,
        ) catch |err| {
            self.cleanup_error = err;
            self.device.recordCleanup(err);
        };
        self.native.deinit(self.allocator);
        self.internal.deinit(self.allocator);
        for (self.immutable_samplers) |binding|
            binding.sampler.header.releaseLeaseLocked(guard, io);
        self.allocator.free(self.immutable_samplers);
    }
};

/// Validates and packs public binding numbers before creating the native layout.
pub fn createBindGroupLayout(
    allocator: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
    device: NativeDevice,
    options: BindGroupLayoutOptions,
) Error!*BindGroupLayout {
    try checkFactory(allocator, guard, arena);
    try checkStore(guard, arena, device);
    if (device.procs.destroy_descriptor_set_layout == null) return error.MissingDeviceProc;
    for (options.descriptor.entries) |entry| {
        if (entry.array_size > 1) return error.BindingLayoutUnsupported;
        switch (entry.kind) {
            .texel_buffer, .input_attachment => return error.BindingLayoutUnsupported,
            .external_texture => {
                if (options.validation.needs_static_sampler_for_external_texture)
                    return error.BindingLayoutUnsupported;
            },
            .static_sampler => |binding| {
                if (!options.allow_internal_bindings) return error.BindingLayoutUnsupported;
                if ((binding orelse return error.BindingLayoutUnsupported).use !=
                    .single_texture_ycbcr) return error.BindingLayoutUnsupported;
            },
            .buffer => |binding| if (binding) |value| {
                if (!options.allow_internal_bindings and
                    (value.binding_type == .internal_storage or
                        value.binding_type == .internal_read_only_storage))
                    return error.BindingLayoutUnsupported;
            },
            .sampled_texture => |binding| if (binding) |value| {
                if (!options.allow_internal_bindings and (value.internal or value.depth_view))
                    return error.BindingLayoutUnsupported;
            },
            .storage_texture => |binding| if (binding) |value| {
                if (!options.allow_internal_bindings and value.internal)
                    return error.BindingLayoutUnsupported;
            },
            else => {},
        }
    }
    const normalized = if (options.immutable_samplers.len != 0)
        try allocator.dupe(layout.Entry, options.descriptor.entries)
    else
        null;
    defer if (normalized) |entries| allocator.free(entries);
    var static_count: usize = 0;
    for (options.descriptor.entries) |entry| {
        if (entry.kind == .static_sampler) static_count += 1;
    }
    if (static_count != options.immutable_samplers.len) return error.BindingLayoutUnsupported;
    for (options.immutable_samplers, 0..) |binding, index| {
        for (options.immutable_samplers[0..index]) |previous| {
            if (previous.binding == binding.binding) return error.DuplicateBindingNumber;
        }
        try checkDependency(arena, guard, &binding.sampler.header);
        if (binding.sampler.header.kind != .sampler) return error.BindingResourceInvalid;
        const payload = binding.sampler.native orelse return error.BindingResourceInvalid;
        if (payload.backend.handle != device.handle) return error.ResourceDeviceMismatch;
        if (payload.sampler == null or payload.conversion == null)
            return error.BindingResourceInvalid;
        const conversion = binding.sampler.key.y_cb_cr orelse return error.BindingResourceInvalid;
        try payload.backend.validateForTiling(binding.sampler.key, vulkan.VK_IMAGE_TILING_OPTIMAL);
        const image_info: vulkan.VkPhysicalDeviceImageFormatInfo2 = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
            .format = @intCast(conversion.vk_format),
            .type = vulkan.VK_IMAGE_TYPE_2D,
            .tiling = vulkan.VK_IMAGE_TILING_OPTIMAL,
            .usage = vulkan.VK_IMAGE_USAGE_SAMPLED_BIT | vulkan.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .flags = 0,
        };
        const count = try payload.backend.combinedImageSamplerDescriptorCount(&image_info);
        var found = false;
        for (normalized.?) |*entry| {
            if (entry.binding_number != binding.binding) continue;
            if (entry.kind != .static_sampler) return error.BindGroupLayoutInvalid;
            var value = entry.kind.static_sampler orelse return error.BindGroupLayoutInvalid;
            const identity = @intFromPtr(&binding.sampler.header);
            if (value.sampler_identity != 0 and value.sampler_identity != identity)
                return error.BindingResourceInvalid;
            value.sampler_identity = identity;
            value.combined_image_sampler_descriptor_count = count;
            entry.kind = .{ .static_sampler = value };
            found = true;
        }
        if (!found) return error.BindGroupLayoutInvalid;
    }
    var validation = options.validation;
    validation.allow_internal_bindings = options.allow_internal_bindings;
    var description = options.descriptor;
    if (normalized) |entries| description.entries = entries;
    var internal = try layout.Layout.init(allocator, description, validation);
    var transferred = false;
    defer if (!transferred) internal.deinit(allocator);
    const query: resource_store.BindGroupLayoutQuery = .{
        .internal = &internal,
        .compatibility_token = options.compatibility_token,
    };
    const hash = resource_store.bindGroupLayoutHash(query);
    if (device.resource_store) |store| {
        if (store.bind_group_layouts.find(guard, hash, query, resource_store.bindGroupLayoutMatches)) |existing| {
            try existing.header.acquireUserLocked(guard);
            return existing;
        }
    }
    const immutable = try allocator.alloc(
        layout_vk.ImmutableSamplerBinding,
        options.immutable_samplers.len,
    );
    defer allocator.free(immutable);
    for (options.immutable_samplers, immutable) |binding, *physical| {
        physical.* = .{ .binding = binding.binding, .sampler = binding.sampler.native.?.sampler };
    }
    const self = try arena.create(allocator, guard, BindGroupLayout, .{
        .kind = .bind_group_layout,
        .label = options.descriptor.label,
        .initial_reference = .user,
    });
    errdefer if (!transferred) self.header.discardUnpublishedLocked(guard) catch unreachable;
    const owned_immutable = try allocator.dupe(ImmutableSamplerBinding, options.immutable_samplers);
    errdefer if (!transferred) allocator.free(owned_immutable);
    var held: usize = 0;
    errdefer if (!transferred) {
        for (owned_immutable[0..held]) |binding|
            binding.sampler.header.releaseLeaseLocked(guard, io);
    };
    for (owned_immutable) |binding| {
        try binding.sampler.header.retainLeaseLocked(guard);
        held += 1;
    }
    var native = try pipeline.GroupLayout.fromInternal(allocator, null, &internal, immutable);
    errdefer if (!transferred) native.deinit(allocator);
    native.compatibility_token = options.compatibility_token;
    native.handle = try layout_vk.createDescriptorSetLayoutFromBindings(
        device.procs,
        device.handle,
        native.bindings,
    );
    self.internal = internal;
    self.native = native;
    self.device = device;
    self.allocator = allocator;
    self.cleanup_error = null;
    self.compatibility_token = options.compatibility_token;
    self.immutable_samplers = owned_immutable;
    self.cache_hash = 0;
    self.cache_next = null;
    self.internal.label = self.header.label;
    self.header.attach(guard, io);
    transferred = true;
    errdefer self.header.releaseUserLocked(guard, io) catch unreachable;
    if (device.resource_store) |store| try store.bind_group_layouts.insert(guard, self, hash);
    return self;
}

/// Copies the group-owner slice and retains each group. Zero immediate_size
/// disables the all-stage push-constant range; nonzero sizes are bytes.
pub const PipelineLayoutOptions = struct {
    label: []const u8 = "",
    groups: []const *BindGroupLayout,
    immediate_size: u32 = 0,
    compatibility_token: u64 = 0,
};
/// Owns a native pipeline layout and retains every group used by its native input.
pub const PipelineLayout = struct {
    header: core.Object,
    native: pipeline.LayoutInput,
    groups: []*BindGroupLayout,
    native_groups: []pipeline.GroupLayout,
    device: NativeDevice,
    allocator: std.mem.Allocator,
    cleanup_error: ?Error = null,
    cache_hash: u64 = 0,
    cache_next: ?*PipelineLayout = null,

    /// Returns a borrowed conversion under the owning guard.
    pub fn input(self: *const PipelineLayout, guard: *const core.ObjectGuard) Error!pipeline.LayoutInput {
        try checkDependencyOwner(guard, &self.header);
        return self.native;
    }
    pub fn destroy(self: *PipelineLayout, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        _ = reason;
        layout_vk.destroyPipelineLayout(
            self.device.procs,
            self.device.handle,
            self.native.handle,
        ) catch |err| {
            self.cleanup_error = err;
            self.device.recordCleanup(err);
        };
        for (self.groups) |group| group.header.releaseLeaseLocked(guard, io);
        self.allocator.free(self.groups);
        self.allocator.free(self.native_groups);
    }
};

/// Finite helper ABI, checked against the actual Vulkan capability, not public limits.
pub fn createInternalPipelineLayout(
    allocator: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
    device: NativeDevice,
    options: PipelineLayoutOptions,
    max_push_constants_size: u32,
) Error!*PipelineLayout {
    try checkFactory(allocator, guard, arena);
    if (options.immediate_size != 0 and options.immediate_size != 8)
        return error.ImmediateSizeInvalid;
    if (options.immediate_size > max_push_constants_size)
        return error.ImmediateSizeInvalid;
    return createPipelineLayout(allocator, io, guard, arena, device, options);
}

/// Creates and retains the exact ordered native group layouts in the supplied arena.
pub fn createPipelineLayout(
    allocator: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
    device: NativeDevice,
    options: PipelineLayoutOptions,
) Error!*PipelineLayout {
    try checkFactory(allocator, guard, arena);
    try checkStore(guard, arena, device);
    if (options.groups.len > layout.max_bind_groups) return error.TooManyBindGroups;
    if (options.immediate_size > 256 or options.immediate_size % 4 != 0)
        return error.ImmediateSizeInvalid;
    for (options.groups) |group| {
        try checkDependency(arena, guard, &group.header);
        if (group.header.kind != .bind_group_layout) return error.ResourceDeviceMismatch;
        if (group.compatibility_token != options.compatibility_token)
            return error.PipelineCompatibilityTokenMismatch;
    }
    if (device.procs.destroy_pipeline_layout == null) return error.MissingDeviceProc;
    const query: resource_store.PipelineLayoutQuery = .{
        .groups = options.groups,
        .immediate_size = options.immediate_size,
        .compatibility_token = options.compatibility_token,
    };
    const hash = resource_store.pipelineLayoutHash(query);
    if (device.resource_store) |store| {
        if (store.pipeline_layouts.find(guard, hash, query, resource_store.pipelineLayoutMatches)) |existing| {
            try existing.header.acquireUserLocked(guard);
            return existing;
        }
    }
    const self = try arena.create(allocator, guard, PipelineLayout, .{
        .kind = .pipeline_layout,
        .label = options.label,
        .initial_reference = .user,
    });
    var transferred = false;
    errdefer if (!transferred) self.header.discardUnpublishedLocked(guard) catch unreachable;
    const owned = try allocator.dupe(*BindGroupLayout, options.groups);
    errdefer if (!transferred) allocator.free(owned);
    const native_groups = try allocator.alloc(pipeline.GroupLayout, owned.len);
    errdefer if (!transferred) allocator.free(native_groups);
    var held: usize = 0;
    errdefer if (!transferred) {
        for (owned[0..held]) |group| group.header.releaseLeaseLocked(guard, io);
    };
    for (owned) |group| {
        try group.header.retainLeaseLocked(guard);
        held += 1;
    }
    for (owned, native_groups) |group, *native| native.* = group.native;
    const native = try pipeline.LayoutInput.create(
        device.procs,
        device.handle,
        native_groups,
        options.immediate_size,
    );
    self.groups = owned;
    self.native_groups = native_groups;
    self.native = native;
    self.native.canonical_layout_header = &self.header;
    self.native.compatibility_token = options.compatibility_token;
    self.device = device;
    self.allocator = allocator;
    self.cleanup_error = null;
    self.cache_hash = 0;
    self.cache_next = null;
    self.header.attach(guard, io);
    transferred = true;
    errdefer self.header.releaseUserLocked(guard, io) catch unreachable;
    if (device.resource_store) |store| try store.pipeline_layouts.insert(guard, self, hash);
    return self;
}

/// Bindings name actual owners. The bind group leases each owner through native use.
pub const Binding = union(enum) {
    buffer: struct {
        binding: u32,
        buffer: *Buffer,
        offset: u64,
        size: u64,
        kind: enum { uniform, storage, read_only_storage, internal_storage, internal_read_only_storage },
        dynamic: bool = false,
        alignment: u32 = 256,
        stages: buffer.ShaderStage,
    },
    texture: struct {
        binding: u32,
        view: *texture.TextureView,
        storage: bool = false,
        internal: bool = false,
        depth_view: bool = false,
        stages: buffer.ShaderStage,
    },
    sampler: struct { binding: u32, sampler: *sampler.Sampler },
    combined_y_cb_cr_view: struct {
        binding: u32,
        view: *texture.TextureView,
        sampler: *sampler.Sampler,
        stages: buffer.ShaderStage,
    },
    external_texture: struct {
        binding: u32,
        texture: *external_texture.ExternalTexture,
        stages: buffer.ShaderStage,
    },
};
/// Borrows bindings through creation and retains the selected pipeline layout.
pub const BindGroupOptions = struct {
    label: []const u8 = "",
    layout: *PipelineLayout,
    group_index: u32,
    bindings: []const Binding,
};
/// Owns its native descriptor pool/set and retained buffer/view/texture dependencies.
/// Native host payloads remain allocated in the core arena until device teardown.
pub const BindGroup = struct {
    header: core.Object,
    native: *groups.BindGroup,
    descriptor_allocator: descriptor.DescriptorSetAllocator,
    layout: *PipelineLayout,
    buffers: []*Buffer,
    samplers: []*sampler.Sampler,
    external_textures: []*external_texture.ExternalTexture,
    allocator: std.mem.Allocator,
    native_allocator: std.mem.Allocator,
    device: NativeDevice,
    cleanup_error: ?Error = null,

    /// Borrows a replay pointer under the owning guard.
    pub fn ref(self: *BindGroup, guard: *const core.ObjectGuard) Error!commands.Ref {
        try checkDependencyOwner(guard, &self.header);
        return self.native;
    }
    pub fn destroy(self: *BindGroup, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        _ = reason;
        // Descriptor users retire before any of their actual resource dependencies.
        self.descriptor_allocator.deinit() catch |err| {
            self.cleanup_error = err;
            self.device.recordCleanup(err);
        };
        for (self.native.bindings) |binding| switch (binding) {
            .texture => |resource| resource.view.header.releaseLeaseLocked(guard, io),
            .combined_y_cb_cr_view => |resource| resource.view.header.releaseLeaseLocked(guard, io),
            else => {},
        };
        self.native_allocator.free(self.native.bindings);
        self.native.group_layout.deinit(self.native_allocator);
        self.native_allocator.destroy(self.native);
        for (self.buffers) |resource| resource.header.releaseLeaseLocked(guard, io);
        self.allocator.free(self.buffers);
        for (self.samplers) |resource| resource.header.releaseLeaseLocked(guard, io);
        self.allocator.free(self.samplers);
        for (self.external_textures) |resource| resource.header.releaseLeaseLocked(guard, io);
        self.allocator.free(self.external_textures);
        self.layout.header.releaseLeaseLocked(guard, io);
    }
};

/// Packs/sorts public bindings and retains layout, buffer, view and texture owners.
/// On failure no owner is attached and no live native descriptor pool escapes.
pub fn createBindGroup(
    allocator: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
    device: NativeDevice,
    options: BindGroupOptions,
) Error!*BindGroup {
    try checkFactory(allocator, guard, arena);
    try checkDependency(arena, guard, &options.layout.header);
    if (options.layout.header.kind != .pipeline_layout or options.layout.device.handle != device.handle)
        return error.ResourceDeviceMismatch;
    if (options.group_index >= options.layout.groups.len) return error.BindGroupIndexInvalid;
    const group = options.layout.groups[options.group_index];
    try checkDependency(arena, guard, &group.header);
    if (group.header.kind != .bind_group_layout or group.device.handle != device.handle)
        return error.ResourceDeviceMismatch;
    const self = try arena.create(allocator, guard, BindGroup, .{ .kind = .bind_group, .label = options.label, .initial_reference = .user });
    errdefer self.header.discardUnpublishedLocked(guard) catch unreachable;
    var physical_count = options.bindings.len;
    var buffer_count: usize = 0;
    var sampler_count: usize = 0;
    var external_count: usize = 0;
    for (options.bindings, 0..) |binding, index| {
        for (options.bindings[0..index]) |previous| {
            if (bindingNumber(binding) == bindingNumber(previous))
                return error.DuplicateBindingNumber;
        }
        try validateLogicalBindingLocked(guard, group, binding);
        switch (binding) {
            .buffer => buffer_count += 1,
            .sampler, .combined_y_cb_cr_view => sampler_count += 1,
            .external_texture => {
                physical_count = std.math.add(usize, physical_count, 2) catch
                    return error.BindGroupLayoutInvalid;
                external_count += 1;
                buffer_count += 1;
            },
            .texture => {},
        }
    }
    const bindings = try allocator.alloc(groups.Binding, physical_count);
    defer allocator.free(bindings);
    const buffers = try allocator.alloc(*Buffer, buffer_count);
    errdefer allocator.free(buffers);
    const samplers = try allocator.alloc(*sampler.Sampler, sampler_count);
    errdefer allocator.free(samplers);
    const external_textures = try allocator.alloc(*external_texture.ExternalTexture, external_count);
    errdefer allocator.free(external_textures);
    var sampler_index: usize = 0;
    var buffer_index: usize = 0;
    var external_index: usize = 0;
    var physical_index: usize = 0;
    for (options.bindings) |binding| {
        const native = &bindings[physical_index];
        physical_index += 1;
        switch (binding) {
            .buffer => |resource| {
                try checkDependency(arena, guard, &resource.buffer.header);
                buffers[buffer_index] = resource.buffer;
                buffer_index += 1;
                native.* = .{ .buffer = .{
                    .binding = resource.binding,
                    .buffer = resource.buffer.native,
                    .offset = resource.offset,
                    .size = resource.size,
                    .kind = switch (resource.kind) {
                        .uniform => .uniform,
                        .storage => .storage,
                        .read_only_storage => .read_only_storage,
                        .internal_storage => .internal_storage,
                        .internal_read_only_storage => .internal_read_only_storage,
                    },
                    .dynamic = resource.dynamic,
                    .alignment = resource.alignment,
                    .stages = resource.stages,
                } };
            },
            .texture => |resource| {
                try checkDependency(arena, guard, &resource.view.header);
                try checkDependency(arena, guard, &resource.view.texture.header);
                native.* = .{ .texture = .{
                    .binding = resource.binding,
                    .view = resource.view,
                    .storage = resource.storage,
                    .internal = resource.internal,
                    .depth_view = resource.depth_view,
                    .stages = resource.stages,
                } };
            },
            .sampler => |resource| {
                try checkDependency(arena, guard, &resource.sampler.header);
                const payload = resource.sampler.native orelse return error.BindingResourceInvalid;
                if (payload.backend.handle != device.handle) return error.ResourceDeviceMismatch;
                samplers[sampler_index] = resource.sampler;
                sampler_index += 1;
                native.* = .{ .sampler = .{
                    .binding = resource.binding,
                    .handle = payload.sampler,
                } };
            },
            .combined_y_cb_cr_view => |resource| {
                try checkDependency(arena, guard, &resource.view.header);
                try checkDependency(arena, guard, &resource.view.texture.header);
                try checkDependency(arena, guard, &resource.sampler.header);
                const payload = resource.sampler.native orelse return error.BindingResourceInvalid;
                if (payload.backend.handle != device.handle) return error.ResourceDeviceMismatch;
                samplers[sampler_index] = resource.sampler;
                sampler_index += 1;
                native.* = .{ .combined_y_cb_cr_view = .{
                    .binding = resource.binding,
                    .view = resource.view,
                    .sampler = resource.sampler,
                    .stages = resource.stages,
                } };
            },
            .external_texture => |resource| {
                try checkDependency(arena, guard, &resource.texture.header);
                try resource.texture.validateSubmitLocked(guard);
                const expansion = group.internal.binding(
                    group.internal.api_binding_map.get(resource.binding).?,
                ).layout.external_texture;
                if (resource.texture.conversion_sampler != null or expansion.static_sampler != null)
                    return error.BindingLayoutUnsupported;
                external_textures[external_index] = resource.texture;
                external_index += 1;
                buffers[buffer_index] = resource.texture.params_buffer;
                buffer_index += 1;
                native.* = .{ .texture = .{
                    .binding = group.internal.binding(expansion.plane0).binding_number,
                    .view = resource.texture.planes[0],
                    .stages = resource.stages,
                } };
                bindings[physical_index] = .{ .texture = .{
                    .binding = group.internal.binding(expansion.plane1).binding_number,
                    .view = resource.texture.planes[1],
                    .stages = resource.stages,
                } };
                physical_index += 1;
                bindings[physical_index] = .{ .buffer = .{
                    .binding = group.internal.binding(expansion.metadata).binding_number,
                    .buffer = resource.texture.params_buffer.native,
                    .offset = 0,
                    .size = external_texture.parameter_size,
                    .kind = .uniform,
                    .alignment = 256,
                    .stages = resource.stages,
                } };
                physical_index += 1;
            },
        }
    }
    std.debug.assert(physical_index == bindings.len);
    try options.layout.header.retainLeaseLocked(guard);
    errdefer options.layout.header.releaseLeaseLocked(guard, io);
    var held_buffers: usize = 0;
    errdefer for (buffers[0..held_buffers]) |resource| resource.header.releaseLeaseLocked(guard, io);
    for (buffers) |resource| {
        try resource.header.retainLeaseLocked(guard);
        held_buffers += 1;
    }
    var held_samplers: usize = 0;
    errdefer for (samplers[0..held_samplers]) |resource|
        resource.header.releaseLeaseLocked(guard, io);
    for (samplers) |resource| {
        try resource.header.retainLeaseLocked(guard);
        held_samplers += 1;
    }
    var held_external: usize = 0;
    errdefer for (external_textures[0..held_external]) |resource|
        resource.header.releaseLeaseLocked(guard, io);
    for (external_textures) |resource| {
        try resource.header.retainLeaseLocked(guard);
        held_external += 1;
    }
    std.mem.sort(groups.Binding, bindings, {}, bindingLessThan);
    const counts = try layout_vk.descriptorCountsPerType(allocator, &group.internal);
    defer allocator.free(counts);
    if (device.procs.destroy_descriptor_pool == null) return error.MissingDeviceProc;
    // Vulkan allows empty sets. A dummy pool capacity is unused by that layout.
    const empty_counts = [_]vulkan.VkDescriptorPoolSize{.{
        .type = vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
    }};
    const native_allocator = arena.allocator(guard);
    self.descriptor_allocator = try descriptor.DescriptorSetAllocator.init(
        native_allocator,
        device.procs,
        device.handle,
        group.native.handle,
        if (counts.len == 0) &empty_counts else counts,
    );
    const native = groups.BindGroup.create(native_allocator, io, guard, .{
        .objects = arena.objectList(),
        .descriptor_allocator = &self.descriptor_allocator,
        .pipeline_layout = options.layout.native.handle,
        .canonical_layout_header = options.layout.native.canonical_layout_header,
        .group_index = options.group_index,
        .group_layout = group.native,
        .buffer_limits = device.buffer_limits,
        .bindings = bindings,
    }) catch |create_error| {
        self.descriptor_allocator.deinit() catch |cleanup_error| {
            device.recordCleanup(cleanup_error);
            return cleanup_error;
        };
        return create_error;
    };
    self.native = native;
    self.layout = options.layout;
    self.buffers = buffers;
    self.samplers = samplers;
    self.external_textures = external_textures;
    self.allocator = allocator;
    self.native_allocator = native_allocator;
    self.cleanup_error = null;
    self.device = device;
    self.header.attach(guard, io);
    return self;
}

fn bindingNumber(binding: Binding) u32 {
    return switch (binding) {
        inline else => |resource| resource.binding,
    };
}

fn bindingStages(stages: buffer.ShaderStage) layout.ShaderStages {
    return .{ .vertex = stages.vertex, .fragment = stages.fragment, .compute = stages.compute };
}

fn validateLogicalBindingLocked(
    guard: *const core.ObjectGuard,
    group: *BindGroupLayout,
    binding: Binding,
) Error!void {
    const index = group.internal.api_binding_map.get(bindingNumber(binding)) orelse
        return error.BindGroupLayoutInvalid;
    const required = group.internal.binding(index);
    switch (binding) {
        .buffer => |resource| {
            try checkDependencyOwner(guard, &resource.buffer.header);
            if (resource.buffer.header.kind != .native_buffer) return error.BindingResourceInvalid;
            if (required.layout != .buffer) return error.BindGroupLayoutInvalid;
            const kind: layout.BufferBindingType = switch (resource.kind) {
                .uniform => .uniform,
                .storage => .storage,
                .read_only_storage => .read_only_storage,
                .internal_storage => .internal_storage,
                .internal_read_only_storage => .internal_read_only_storage,
            };
            if (required.layout.buffer.binding_type != kind or
                required.layout.buffer.has_dynamic_offset != resource.dynamic or
                resource.size < required.layout.buffer.min_binding_size or
                !required.visibility.contains(bindingStages(resource.stages)))
                return error.BindGroupLayoutInvalid;
        },
        .texture => |resource| {
            try checkDependencyOwner(guard, &resource.view.header);
            if (resource.view.header.kind != .texture_view) return error.BindingResourceInvalid;
            try checkDependencyOwner(guard, &resource.view.texture.header);
            if (resource.view.texture.header.kind != .texture) return error.BindingResourceInvalid;
            if (!required.visibility.contains(bindingStages(resource.stages)))
                return error.BindGroupLayoutInvalid;
            const dimension: layout.TextureViewDimension = switch (resource.view.dimension) {
                ._1d => .one_d,
                ._2d => .two_d,
                ._2d_array => .two_d_array,
                .cube => .cube,
                .cube_array => .cube_array,
                ._3d => .three_d,
                .undefined_ => return error.BindingResourceInvalid,
            };
            if (resource.storage) {
                if (required.layout != .storage_texture or
                    required.layout.storage_texture.internal != resource.internal or
                    required.layout.storage_texture.view_dimension != dimension or resource.depth_view)
                    return error.BindGroupLayoutInvalid;
            } else {
                if (required.layout != .sampled_texture) return error.BindGroupLayoutInvalid;
                const expected = required.layout.sampled_texture;
                if (expected.internal != resource.internal or expected.depth_view != resource.depth_view or
                    expected.view_dimension != dimension or
                    expected.multisampled != (resource.view.texture.sample_count > 1))
                    return error.BindGroupLayoutInvalid;
                if (resource.depth_view) {
                    if (!resource.internal or expected.sample_type != .float_unfilterable or
                        resource.view.aspects.depth == 0 or resource.view.aspects.stencil != 0)
                        return error.BindingResourceInvalid;
                } else if (resource.view.aspects.depth != 0 and expected.sample_type != .depth) {
                    return error.BindingResourceInvalid;
                }
                const aspect: usize = if (resource.view.aspects.stencil != 0 and
                    resource.view.aspects.depth == 0) 1 else 0;
                const samples = resource.view.format_info.aspect_info[aspect].supported_sample_types;
                const compatible = switch (expected.sample_type) {
                    .float_filterable => samples.float,
                    .float_unfilterable => samples.unfilterable_float,
                    .sint => samples.sint,
                    .uint => samples.uint,
                    .depth => samples.depth,
                };
                if (!compatible) return error.BindingResourceInvalid;
            }
        },
        .sampler => |resource| {
            try checkDependencyOwner(guard, &resource.sampler.header);
            if (resource.sampler.header.kind != .sampler) return error.BindingResourceInvalid;
            const payload = resource.sampler.native orelse return error.BindingResourceInvalid;
            if (payload.sampler == null or payload.conversion != null) return error.BindingLayoutUnsupported;
            if (required.layout != .sampler) return error.BindGroupLayoutInvalid;
            const actual = resource.sampler.bindingType(guard);
            const compatible = switch (required.layout.sampler.binding_type) {
                .filtering => actual != .comparison,
                .non_filtering => actual == .non_filtering,
                .comparison => actual == .comparison,
            };
            if (!compatible) return error.BindingResourceInvalid;
        },
        .combined_y_cb_cr_view => |resource| {
            try checkDependencyOwner(guard, &resource.view.header);
            try checkDependencyOwner(guard, &resource.view.texture.header);
            try checkDependencyOwner(guard, &resource.sampler.header);
            if (resource.view.header.kind != .texture_view or
                resource.view.texture.header.kind != .texture or
                resource.sampler.header.kind != .sampler) return error.BindingResourceInvalid;
            if (required.layout != .static_sampler or
                required.layout.static_sampler.use != .single_texture_ycbcr or
                !required.visibility.contains(bindingStages(resource.stages)))
                return error.BindGroupLayoutInvalid;
            try resource.view.validateYCbCr(guard, resource.sampler);
            if (required.layout.static_sampler.sampler_identity != @intFromPtr(&resource.sampler.header) or
                required.layout.static_sampler.combined_image_sampler_descriptor_count !=
                    try resource.view.texture.getCombinedImageSamplerDescriptorCount(guard))
                return error.BindingResourceInvalid;
        },
        .external_texture => |resource| {
            if (required.layout != .external_texture or
                !required.visibility.contains(bindingStages(resource.stages)))
                return error.BindGroupLayoutInvalid;
            try resource.texture.validateSubmitLocked(guard);
        },
    }
}

fn bindingLessThan(_: void, a: groups.Binding, b: groups.Binding) bool {
    const left = switch (a) {
        inline else => |resource| resource.binding,
    };
    const right = switch (b) {
        inline else => |resource| resource.binding,
    };
    return left < right;
}

/// Borrows a typed module, entry-point name and specialization overrides through
/// pipeline creation; empty constants request the module's reflected defaults.
pub const StageOptions = struct {
    module: *ShaderModule,
    entry_point: []const u8,
    stage: pipeline.Stage,
    constants: []const descriptors.ConstantEntry = &.{},
    usage: pipeline.StageUsage = .{},

    /// Checks a module before automatic layout derivation without producing native input.
    pub fn validateModuleLocked(self: StageOptions, guard: *const core.ObjectGuard) Error!void {
        _ = try self.checkedEntryPointLocked(guard);
    }

    fn checkedEntryPointLocked(
        self: StageOptions,
        guard: *const core.ObjectGuard,
    ) Error!shader.EntryPoint {
        try checkDependencyOwner(guard, &self.module.header);
        if (self.module.header.kind != .shader_module or self.module.native.failed or
            self.module.native.vk_module == null) return error.ResourceDestroyed;
        const entry = self.module.native.findEntryPoint(self.entry_point) orelse
            return error.StageMissingForEntryPoint;
        const correct = switch (self.stage) {
            .vertex => entry.execution_model == .vertex,
            .fragment => entry.execution_model == .fragment,
            .compute => entry.execution_model == .gl_compute,
        };
        if (!correct) return error.StageMismatch;
        return entry;
    }

    /// Validates actual canonical layout semantics and borrows unchanged shader words.
    pub fn input(
        self: StageOptions,
        guard: *const core.ObjectGuard,
        layout_owner: *PipelineLayout,
    ) Error!pipeline.StageInput {
        const entry = try self.checkedEntryPointLocked(guard);
        try checkDependencyOwner(guard, &layout_owner.header);
        if (layout_owner.header.kind != .pipeline_layout) return error.ResourceDeviceMismatch;
        const stages: layout.ShaderStages = switch (self.stage) {
            .vertex => .{ .vertex = true },
            .fragment => .{ .fragment = true },
            .compute => .{ .compute = true },
        };
        for (entry.layout.bindings) |resource| {
            if (resource.set >= layout_owner.groups.len) return error.ShaderBindingMismatch;
            const group = layout_owner.groups[resource.set];
            try checkDependencyOwner(guard, &group.header);
            var found = false;
            for (group.internal.entries) |logical| {
                if (logical.binding_number != resource.binding or
                    logical.layout == .external_texture) continue;
                if (!logical.visibility.contains(stages)) return error.ShaderBindingMismatch;
                try shader_reflect.validateBinding(resource, logical, stages);
                found = true;
                break;
            }
            if (!found) return error.ShaderBindingMismatch;
        }
        return .{
            .module = self.module.native.vk_module,
            .entry_point = self.entry_point,
            .stage = self.stage,
            .content_bytes = std.mem.sliceAsBytes(self.module.words),
            .constants = self.constants,
            .usage = self.usage,
        };
    }
};

/// Typed compute input; effective limits and enabled features come from the device.
pub const ComputePipelineDescriptor = struct {
    label: []const u8 = "",
    layout: *PipelineLayout,
    compute: StageOptions,

    /// Converts borrowed typed inputs using the high device's selected limits.
    pub fn toNative(
        self: ComputePipelineDescriptor,
        guard: *const core.ObjectGuard,
        limits: pipeline.ComputeLimits,
        local_size_id_supported: bool,
    ) Error!pipeline.ComputePipelineDescriptor {
        return .{
            .label = self.label,
            .layout = try self.layout.input(guard),
            .compute = try self.compute.input(guard, self.layout),
            .limits = limits,
            .local_size_id_supported = local_size_id_supported,
        };
    }
};

pub const ColorTargetState = render_state.ColorTargetState;
pub const DepthStencilState = render_state.DepthStencilState;
pub const RenderBundleEncoderOptions = struct {
    color_formats: []const api.TextureFormat,
    sample_count: u32,
    depth_stencil_format: api.TextureFormat = .undefined_,
    command_options: render_bundle.InitOptions = .{},
};

/// Typed graphics input; the high device derives its compatible native render pass.
pub const RenderPipelineDescriptor = struct {
    label: []const u8 = "",
    layout: *PipelineLayout,
    vertex: StageOptions,
    fragment: ?StageOptions = null,
    vertex_buffers: []const pipeline.VertexBufferLayout = &.{},
    vertex_attributes: []const pipeline.VertexAttributeLayout = &.{},
    primitive: pipeline.PrimitiveState = .{},
    depth_stencil: ?DepthStencilState = null,
    multisample: pipeline.MultisampleState = .{},
    color_targets: []const ColorTargetState = &.{},

    /// Converts typed borrows using a device-derived compatible render pass.
    pub fn toNative(
        self: RenderPipelineDescriptor,
        guard: *const core.ObjectGuard,
        render_pass: vulkan.VkRenderPass,
        native_colors: []const pipeline.ColorTargetState,
    ) Error!pipeline.RenderPipelineDescriptor {
        return .{
            .compatible_render_pass = render_pass,
            .label = self.label,
            .layout = try self.layout.input(guard),
            .vertex = try self.vertex.input(guard, self.layout),
            .fragment = if (self.fragment) |fragment|
                try fragment.input(guard, self.layout)
            else
                null,
            .vertex_buffers = self.vertex_buffers,
            .vertex_attributes = self.vertex_attributes,
            .primitive = self.primitive,
            .depth_stencil = if (self.depth_stencil) |depth| depth.toNative() else null,
            .multisample = self.multisample,
            .color_targets = native_colors,
        };
    }
};

/// Owns a pipeline-store reference and its typed creation dependencies.
pub const Pipeline = struct {
    header: core.Object,
    native: *pipeline.Pipeline,
    layout: *PipelineLayout,
    shaders: []*ShaderModule,
    attachment: Attachment,

    allocator: std.mem.Allocator,
    cleanup_error: ?Error = null,
    pub const Attachment = union(enum) {
        compute,
        render: *attachments.CanonicalAttachmentState,
    };

    /// Borrows a replay pointer under the owning guard.
    pub fn ref(self: *Pipeline, guard: *const core.ObjectGuard) Error!commands.Ref {
        try checkDependencyOwner(guard, &self.header);
        return &self.header;
    }

    /// Derives frontend requirements from the actual retained native pipeline.
    pub fn renderOptions(self: *Pipeline, guard: *const core.ObjectGuard) Error!render_encoder.SetRenderPipelineOptions {
        try checkDependencyOwner(guard, &self.header);
        const attachment_state = switch (self.attachment) {
            .compute => return error.PipelineTypeMismatch,
            .render => |state| state,
        };
        try checkDependencyOwner(guard, &attachment_state.header);
        const state = switch (self.native.state) {
            .compute => return error.PipelineTypeMismatch,
            .render => |state| state,
        };
        var requirements: tracker.PipelineRequirements = .{
            .bind_group_layout_mask = self.native.bind_group_mask,
            .immediate_slot_mask = self.native.immediate_mask,
            .strip_index_format = if (state.primitive.strip_index_format) |value| switch (value) {
                .uint16 => .uint16,
                .uint32 => .uint32,
            } else .undefined_,
        };
        for (self.layout.groups, 0..) |group, index| {
            requirements.bind_group_layout_ids[index] = @intFromPtr(&group.header);
        }
        for (state.vertex_attributes.items) |attribute| {
            const slot = attribute.input_slot;
            if (slot >= command_constants.max_vertex_buffers or slot >= state.vertex_buffers.items.len)
                return error.InvalidCommandStream;
            const buffer_layout = state.vertex_buffers.items[slot];
            const end = @as(u64, attribute.offset) + low_render.vertexFormatByteSize(attribute.format);
            if (end > std.math.maxInt(u32)) return error.InvalidCommandStream;
            requirements.vertex_buffer_mask |= @as(u32, 1) << @intCast(slot);
            const vertex = &requirements.vertex_buffer_layouts[slot];
            vertex.array_stride = buffer_layout.array_stride;
            vertex.last_stride = @max(vertex.last_stride, @as(u32, @intCast(end)));
            vertex.used_bytes_in_stride = vertex.last_stride;
        }
        return .{
            .pipeline = &self.header,
            .requirements = requirements,
            .attachment_state = attachment_state,
        };
    }
    pub fn destroy(self: *Pipeline, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        _ = reason;
        self.native.header.releaseLeaseLocked(guard, io);
        for (self.shaders) |module| module.header.releaseLeaseLocked(guard, io);
        switch (self.attachment) {
            .compute => {},
            .render => |state| state.header.releaseLeaseLocked(guard, io),
        }
        self.allocator.free(self.shaders);
    }
};

/// On failure the caller still owns the pipeline-store reference.
pub fn createPipelineWrapper(
    allocator: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    arena: *core.ObjectArena,
    native: *pipeline.Pipeline,
    attachment: Pipeline.Attachment,
    shaders: []const *ShaderModule,
) Error!*Pipeline {
    try checkFactory(allocator, guard, arena);
    try checkDependency(arena, guard, &native.header);
    if (native.header.reference_count == native.header.user_reference_count) return error.NoOwnedReference;
    const layout_header = native.canonical_layout_header orelse return error.ResourceDeviceMismatch;
    try checkDependency(arena, guard, layout_header);
    if (layout_header.kind != .pipeline_layout) return error.ResourceDeviceMismatch;
    const actual_layout: *PipelineLayout = @fieldParentPtr("header", layout_header);
    for (shaders) |module| try checkDependency(arena, guard, &module.header);
    switch (attachment) {
        .compute => if (native.state != .compute) return error.PipelineTypeMismatch,
        .render => |state| {
            if (native.state != .render) return error.PipelineTypeMismatch;
            try checkDependency(arena, guard, &state.header);
            if (state.header.kind != .attachment_state) return error.ResourceDeviceMismatch;
        },
    }
    const self = try arena.create(allocator, guard, Pipeline, .{ .kind = .native_pipeline, .initial_reference = .user });
    errdefer self.header.discardUnpublishedLocked(guard) catch unreachable;
    const owned = try allocator.dupe(*ShaderModule, shaders);
    errdefer allocator.free(owned);
    switch (attachment) {
        .compute => {},
        .render => |state| try state.header.retainLeaseLocked(guard),
    }
    errdefer switch (attachment) {
        .compute => {},
        .render => |state| state.header.releaseLeaseLocked(guard, io),
    };
    var held: usize = 0;
    errdefer for (owned[0..held]) |module| module.header.releaseLeaseLocked(guard, io);
    for (owned) |module| {
        try module.header.retainLeaseLocked(guard);
        held += 1;
    }
    self.native = native;
    self.layout = actual_layout;
    self.shaders = owned;
    self.attachment = attachment;
    self.allocator = allocator;
    self.cleanup_error = null;
    self.header.attach(guard, io);
    return self;
}

/// Retires payloads without consuming any user alias or pending lease.
/// Weak cache backing must remain alive throughout this guarded sweep.
pub fn destroyAll(device: *core.Device, guard: *const core.ObjectGuard, io: std.Io) Error!void {
    const objects = device.arena.objectList();
    guard.assertOwns(objects);
    device.retirePayloadsLocked(guard, io, .early_destroy);
    var first_error: ?Error = null;
    var current = objects.head;
    for (0..objects.tracked_count) |_| {
        const header = current orelse break;
        const cleanup_error: ?Error = switch (header.kind) {
            .native_buffer => (@as(*Buffer, @ptrCast(@alignCast(header)))).cleanup_error,
            .shader_module => (@as(*ShaderModule, @ptrCast(@alignCast(header)))).cleanup_error,
            .bind_group_layout => (@as(*BindGroupLayout, @ptrCast(@alignCast(header)))).cleanup_error,
            .pipeline_layout => (@as(*PipelineLayout, @ptrCast(@alignCast(header)))).cleanup_error,
            .bind_group => (@as(*BindGroup, @ptrCast(@alignCast(header)))).cleanup_error,
            .native_pipeline => (@as(*Pipeline, @ptrCast(@alignCast(header)))).cleanup_error,
            .sampler => (@as(*sampler.Sampler, @fieldParentPtr("header", header))).cleanup_error,
            else => null,
        };
        if (first_error == null) first_error = cleanup_error;
        current = header.node.next;
    }
    if (first_error) |err| return err;
}

const RefKind = enum { buffer, pipeline, bind_group, texture, texture_view, external_texture, query_set, attachment_state, render_bundle, unsupported };

fn fieldRefKind(comptime name: []const u8, inherited: ?RefKind) ?RefKind {
    if (comptime std.mem.eql(u8, name, "buffer") or std.mem.eql(u8, name, "buffers") or
        std.mem.eql(u8, name, "referenced_buffers") or std.mem.eql(u8, name, "indirect_buffer") or
        std.mem.eql(u8, name, "index_buffer") or
        std.mem.eql(u8, name, "draw_count_buffer") or std.mem.eql(u8, name, "source") or
        std.mem.eql(u8, name, "destination")) return .buffer;
    if (comptime std.mem.eql(u8, name, "texture") or std.mem.eql(u8, name, "textures") or
        std.mem.eql(u8, name, "referenced_textures")) return .texture;
    if (comptime std.mem.eql(u8, name, "view") or
        std.mem.eql(u8, name, "resolve_target")) return .texture_view;
    if (comptime std.mem.eql(u8, name, "query_set") or std.mem.eql(u8, name, "query_sets") or
        std.mem.eql(u8, name, "occlusion_query_set")) return .query_set;
    if (comptime std.mem.eql(u8, name, "pipeline")) return .pipeline;
    if (comptime std.mem.eql(u8, name, "group")) return .bind_group;
    if (comptime std.mem.eql(u8, name, "external_textures") or
        std.mem.eql(u8, name, "referenced_external_textures")) return .external_texture;
    if (comptime std.mem.eql(u8, name, "table") or std.mem.eql(u8, name, "resource_table") or
        std.mem.eql(u8, name, "referenced_resource_tables")) return .unsupported;
    return inherited;
}

fn findReferenceLocked(
    guard: *const core.ObjectGuard,
    device: *core.Device,
    pointer: *anyopaque,
    expected: ?RefKind,
) Error!*core.Object {
    const objects = device.arena.objectList();
    guard.assertOwns(objects);
    if (expected == .unsupported) return error.ResourceDestroyed;
    var current = objects.head;
    for (0..objects.tracked_count) |_| {
        const header = current orelse break;
        current = header.node.next;
        // A retired/failed wrapper's native fields must never be inspected.
        if (header.state != .alive) continue;
        const matches = switch (header.kind) {
            .native_buffer => (expected == null or expected == .buffer) and
                @as(*anyopaque, @ptrCast((@as(*Buffer, @fieldParentPtr("header", header))).native)) == pointer,
            .native_pipeline => (expected == null or expected == .pipeline) and
                @as(*anyopaque, @ptrCast(header)) == pointer,
            .bind_group => (expected == null or expected == .bind_group) and
                @as(*anyopaque, @ptrCast((@as(*BindGroup, @fieldParentPtr("header", header))).native)) == pointer,
            .texture => (expected == null or expected == .texture) and
                @as(*anyopaque, @ptrCast(@as(*texture.Texture, @fieldParentPtr("header", header)))) == pointer,
            .texture_view => (expected == null or expected == .texture_view) and
                @as(*anyopaque, @ptrCast(@as(*texture.TextureView, @fieldParentPtr("header", header)))) == pointer,
            .query_set => (expected == null or expected == .query_set) and
                @as(*anyopaque, @ptrCast(@as(*query_set.QuerySet, @fieldParentPtr("header", header)))) == pointer,
            .attachment_state => (expected == null or expected == .attachment_state) and
                @as(*anyopaque, @ptrCast(@as(*attachments.CanonicalAttachmentState, @fieldParentPtr("header", header)))) == pointer,
            .render_bundle => (expected == null or expected == .render_bundle) and
                @as(*anyopaque, @ptrCast(header)) == pointer,
            .external_texture => (expected == null or expected == .external_texture) and
                @as(*anyopaque, @ptrCast(header)) == pointer,
            else => false,
        };
        if (matches) {
            try validateRootLocked(guard, device, header);
            return header;
        }
    }
    // No pointer from a recording is dereferenced before a canonical match.
    return error.ResourceDestroyed;
}

/// Guarded admission of registered replay payloads, without taking a reference.
pub fn validateRefLocked(guard: *const core.ObjectGuard, device: *core.Device, reference: commands.Ref) Error!void {
    if (reference) |pointer| _ = try findReferenceLocked(guard, device, pointer, null);
}

pub fn resolveBufferRefLocked(guard: *const core.ObjectGuard, device: *core.Device, reference: commands.Ref) Error!*Buffer {
    const header = try findReferenceLocked(guard, device, reference orelse return error.InvalidResourceRef, .buffer);
    return @fieldParentPtr("header", header);
}

pub fn resolveBindGroupRefLocked(guard: *const core.ObjectGuard, device: *core.Device, reference: commands.Ref) Error!*BindGroup {
    const header = try findReferenceLocked(guard, device, reference orelse return error.InvalidResourceRef, .bind_group);
    return @fieldParentPtr("header", header);
}

pub fn resolveExternalTextureRefLocked(guard: *const core.ObjectGuard, device: *core.Device, reference: commands.Ref) Error!*external_texture.ExternalTexture {
    const header = try findReferenceLocked(guard, device, reference orelse return error.InvalidResourceRef, .external_texture);
    return @fieldParentPtr("header", header);
}

pub fn resolvePipelineRefLocked(guard: *const core.ObjectGuard, device: *core.Device, reference: commands.Ref) Error!*Pipeline {
    const header = try findReferenceLocked(guard, device, reference orelse return error.InvalidResourceRef, .pipeline);
    return @fieldParentPtr("header", header);
}

pub fn resolveRenderBundleRefLocked(guard: *const core.ObjectGuard, device: *core.Device, reference: commands.Ref) Error!*render_bundle.RenderBundle {
    const header = try findReferenceLocked(guard, device, reference orelse return error.InvalidResourceRef, .render_bundle);
    return @fieldParentPtr("header", header);
}

pub fn resolveAttachmentRefLocked(guard: *const core.ObjectGuard, device: *core.Device, state: *attachments.CanonicalAttachmentState) Error!*attachments.CanonicalAttachmentState {
    const header = try findReferenceLocked(guard, device, @ptrCast(state), .attachment_state);
    return @fieldParentPtr("header", header);
}

pub fn resolveTextureViewRefLocked(guard: *const core.ObjectGuard, device: *core.Device, reference: commands.Ref) Error!*texture.TextureView {
    const header = try findReferenceLocked(guard, device, reference orelse return error.NoAttachmentInRenderPass, .texture_view);
    return @fieldParentPtr("header", header);
}

pub fn resolveQuerySetRefLocked(guard: *const core.ObjectGuard, device: *core.Device, reference: commands.Ref) Error!*query_set.QuerySet {
    const header = try findReferenceLocked(guard, device, reference orelse return error.InvalidResourceRef, .query_set);
    return @fieldParentPtr("header", header);
}

fn validateRootLocked(guard: *const core.ObjectGuard, device: *core.Device, header: *core.Object) Error!void {
    try checkDependency(&device.arena, guard, header);
    switch (header.kind) {
        .native_pipeline => {
            const owner: *Pipeline = @fieldParentPtr("header", header);
            try checkDependency(&device.arena, guard, &owner.native.header);
            try validateRootLocked(guard, device, &owner.layout.header);
            for (owner.shaders) |module| try checkDependency(&device.arena, guard, &module.header);
            switch (owner.attachment) {
                .compute => if (owner.native.state != .compute) return error.PipelineTypeMismatch,
                .render => |state| {
                    if (owner.native.state != .render) return error.PipelineTypeMismatch;
                    _ = try resolveAttachmentRefLocked(guard, device, state);
                },
            }
        },
        .pipeline_layout => {
            const owner: *PipelineLayout = @fieldParentPtr("header", header);
            if (owner.native.handle == null) return error.InvalidResourceRef;
            for (owner.groups) |group| try validateRootLocked(guard, device, &group.header);
        },
        .bind_group => {
            const owner: *BindGroup = @fieldParentPtr("header", header);
            try validateRootLocked(guard, device, &owner.layout.header);
            for (owner.buffers) |resource| try validateRootLocked(guard, device, &resource.header);
            for (owner.samplers) |resource| try validateRootLocked(guard, device, &resource.header);
            for (owner.external_textures) |resource| try validateRootLocked(guard, device, &resource.header);
            for (owner.native.bindings) |binding| switch (binding) {
                .texture => |resource| try validateRootLocked(guard, device, &resource.view.header),
                .combined_y_cb_cr_view => |resource| {
                    try validateRootLocked(guard, device, &resource.view.header);
                    try validateRootLocked(guard, device, &resource.sampler.header);
                    try resource.view.validateYCbCr(guard, resource.sampler);
                },
                else => {},
            };
        },
        .texture_view => {
            const view: *texture.TextureView = @fieldParentPtr("header", header);
            try validateRootLocked(guard, device, &view.texture.header);
            if (try view.getHandle(guard) == null) return error.TextureNativeNotInitialized;
        },
        .native_buffer => {
            const owner: *Buffer = @fieldParentPtr("header", header);
            switch (owner.native.state) {
                .unmapped => {},
                .mapped, .mapped_at_creation => return error.BufferUseWhileMapped,
                .pending_map => return error.BufferUseWhilePendingMap,
                .in_use => return error.BufferUseWhileInUse,
                .shared_memory_no_access => return error.BufferUseWithoutSharedMemoryAccess,
                .destroyed => return error.BufferUseWhileDestroyed,
            }
            if (owner.native.getHandle() == null) return error.InvalidResourceRef;
        },
        .attachment_state => {
            const state: *attachments.CanonicalAttachmentState = @fieldParentPtr("header", header);
            try state.value.validateCanonical();
        },
        .render_bundle => {
            const bundle: *render_bundle.RenderBundle = @fieldParentPtr("header", header);
            const state = bundle.resource_usage.attachment_state orelse return error.InvalidBundle;
            _ = try resolveAttachmentRefLocked(guard, device, state);
        },
        .sampler => {
            const owner: *sampler.Sampler = @fieldParentPtr("header", header);
            const native = owner.native orelse return error.InvalidResourceRef;
            if (native.sampler == null) return error.InvalidResourceRef;
        },
        .texture => {
            const owner: *texture.Texture = @fieldParentPtr("header", header);
            if (try owner.getHandle(guard) == null) return error.TextureNativeNotInitialized;
        },
        .external_texture => {
            const owner: *external_texture.ExternalTexture = @fieldParentPtr("header", header);
            try owner.validateSubmitLocked(guard);
            for (owner.planes) |plane| try validateRootLocked(guard, device, &plane.header);
            try validateRootLocked(guard, device, &owner.params_buffer.header);
            if (owner.conversion_sampler) |conversion|
                try validateRootLocked(guard, device, &conversion.header);
        },
        .bind_group_layout => {
            const owner: *BindGroupLayout = @fieldParentPtr("header", header);
            if (owner.native.handle == null) return error.InvalidResourceRef;
            for (owner.immutable_samplers) |binding|
                try validateRootLocked(guard, device, &binding.sampler.header);
        },
        .shader_module => {
            const owner: *ShaderModule = @fieldParentPtr("header", header);
            if (owner.native.failed or owner.native.vk_module == null) return error.InvalidResourceRef;
        },
        .query_set, .pipeline => {},
        else => return error.ResourceDestroyed,
    }
}

/// Move-only set of strong root leases for one actual pending submission.
pub const PendingUses = struct {
    allocator: std.mem.Allocator,
    objects: *core.ObjectList,
    roots: std.AutoHashMapUnmanaged(*core.Object, void) = .empty,
    leased: bool = false,

    pub fn prepareDeclaredLocked(
        gpa: std.mem.Allocator,
        guard: *const core.ObjectGuard,
        device: *core.Device,
        roots: []const *core.Object,
    ) Error!PendingUses {
        try device.arena.checkAllocator(guard, gpa);
        var self: PendingUses = .{ .allocator = gpa, .objects = device.arena.objectList() };
        errdefer self.roots.deinit(gpa);
        for (roots) |root| try self.addRootLocked(guard, device, root);
        try self.acquireLocked(guard);
        return self;
    }

    pub fn prepareFinishedLocked(
        gpa: std.mem.Allocator,
        guard: *const core.ObjectGuard,
        device: *core.Device,
        finished: *const encoding_context.Finished,
        max_immediate_size: u32,
    ) Error!PendingUses {
        try device.arena.checkAllocator(guard, gpa);
        var self: PendingUses = .{ .allocator = gpa, .objects = device.arena.objectList() };
        errdefer self.roots.deinit(gpa);
        try collectFinishedLocked(&self, guard, device, finished, max_immediate_size);
        try self.acquireLocked(guard);
        return self;
    }

    fn addRootLocked(self: *PendingUses, guard: *const core.ObjectGuard, device: *core.Device, root: *core.Object) Error!void {
        try validateRootLocked(guard, device, root);
        const inserted = try self.roots.getOrPut(self.allocator, root);
        if (inserted.found_existing) return;
        switch (root.kind) {
            .bind_group => {
                const group: *BindGroup = @fieldParentPtr("header", root);
                try self.addRootLocked(guard, device, &group.layout.header);
                for (group.buffers) |resource| try self.addRootLocked(guard, device, &resource.header);
                for (group.samplers) |resource| try self.addRootLocked(guard, device, &resource.header);
                for (group.external_textures) |resource| try self.addRootLocked(guard, device, &resource.header);
                for (group.native.bindings) |binding| switch (binding) {
                    inline .texture, .combined_y_cb_cr_view => |resource| try self.addRootLocked(guard, device, &resource.view.header),
                    else => {},
                };
            },
            .texture_view => {
                const view: *texture.TextureView = @fieldParentPtr("header", root);
                try self.addRootLocked(guard, device, &view.texture.header);
                if (view.conversion_sampler) |conversion|
                    try self.addRootLocked(guard, device, &conversion.header);
            },
            .external_texture => {
                const owner: *external_texture.ExternalTexture = @fieldParentPtr("header", root);
                for (owner.planes) |plane| try self.addRootLocked(guard, device, &plane.header);
                try self.addRootLocked(guard, device, &owner.params_buffer.header);
                if (owner.conversion_sampler) |conversion|
                    try self.addRootLocked(guard, device, &conversion.header);
            },
            .bind_group_layout => {
                const owner: *BindGroupLayout = @fieldParentPtr("header", root);
                for (owner.immutable_samplers) |binding|
                    try self.addRootLocked(guard, device, &binding.sampler.header);
            },
            .pipeline_layout => {
                const owner: *PipelineLayout = @fieldParentPtr("header", root);
                for (owner.groups) |group| try self.addRootLocked(guard, device, &group.header);
            },
            .native_pipeline => {
                const owner: *Pipeline = @fieldParentPtr("header", root);
                try self.addRootLocked(guard, device, &owner.native.header);
                try self.addRootLocked(guard, device, &owner.layout.header);
                for (owner.shaders) |module| try self.addRootLocked(guard, device, &module.header);
                switch (owner.attachment) {
                    .compute => {},
                    .render => |state| try self.addRootLocked(guard, device, &state.header),
                }
            },
            .render_bundle => {
                const bundle: *render_bundle.RenderBundle = @fieldParentPtr("header", root);
                try self.addRootLocked(guard, device, &bundle.attachmentState().header);
            },
            else => {},
        }
    }

    fn acquireLocked(self: *PendingUses, guard: *const core.ObjectGuard) Error!void {
        guard.assertOwns(self.objects);
        const required: u64 = self.roots.count();
        if (required > std.math.maxInt(u64) - self.objects.total_reference_count)
            return error.ReferenceCountOverflow;
        var keys = self.roots.keyIterator();
        while (keys.next()) |key| {
            if (key.*.reference_count == std.math.maxInt(u32)) return error.ReferenceCountOverflow;
            if (key.*.kind == .native_buffer) {
                const owner: *Buffer = @fieldParentPtr("header", key.*);
                if (owner.queue_uses == std.math.maxInt(u32)) return error.ReferenceCountOverflow;
            }
        }
        // No allocation, validation or fallible mutation remains after this
        // preflight; the held guard prevents reference/liveness changes.
        keys = self.roots.keyIterator();
        while (keys.next()) |key| {
            key.*.retainLeaseLocked(guard) catch unreachable;
            if (key.*.kind == .native_buffer) {
                const owner: *Buffer = @fieldParentPtr("header", key.*);
                owner.adoptQueueUseLocked(guard);
            }
        }
        self.leased = true;
    }

    /// Appends one genuine GPU-live root. Earlier successful leases survive later failure.
    pub fn retainDerivedRootLocked(
        self: *PendingUses,
        guard: *const core.ObjectGuard,
        device: *core.Device,
        root: *core.Object,
    ) Error!void {
        if (guard.objects != self.objects or device.arena.objectList() != self.objects)
            return error.ResourceDeviceMismatch;
        try device.arena.checkAllocator(guard, self.allocator);
        if (!self.leased) return error.NoOwnedReference;
        try validateRootLocked(guard, device, root);
        if (self.roots.contains(root)) return;
        if (root.reference_count == std.math.maxInt(u32) or
            self.objects.total_reference_count == std.math.maxInt(u64))
            return error.ReferenceCountOverflow;
        if (root.kind == .native_buffer) {
            const owner: *Buffer = @fieldParentPtr("header", root);
            if (owner.queue_uses == std.math.maxInt(u32)) return error.ReferenceCountOverflow;
        }
        try self.roots.put(self.allocator, root, {});
        root.retainLeaseLocked(guard) catch unreachable;
        if (root.kind == .native_buffer) {
            const owner: *Buffer = @fieldParentPtr("header", root);
            owner.adoptQueueUseLocked(guard);
        }
    }

    /// Adds the existing staged-unmap root without GPU-state validation before unmap.
    /// The caller owns the queue gate, validates provenance, and immediately unmaps it.
    pub fn retainRecordingRootLocked(
        self: *PendingUses,
        guard: *const core.ObjectGuard,
        device: *core.Device,
        root: *core.Object,
    ) Error!void {
        guard.assertOwns(self.objects);
        std.debug.assert(self.leased);
        try checkDependency(&device.arena, guard, root);
        if (self.roots.contains(root)) return;
        if (root.reference_count == std.math.maxInt(u32)) return error.ReferenceCountOverflow;
        if (self.objects.total_reference_count == std.math.maxInt(u64))
            return error.ReferenceCountOverflow;
        if (root.kind == .native_buffer) {
            const owner: *Buffer = @fieldParentPtr("header", root);
            if (owner.queue_uses == std.math.maxInt(u32)) return error.ReferenceCountOverflow;
        }
        try self.roots.put(self.allocator, root, {});
        root.retainLeaseLocked(guard) catch unreachable;
        if (root.kind == .native_buffer) {
            const owner: *Buffer = @fieldParentPtr("header", root);
            owner.adoptQueueUseLocked(guard);
        }
    }

    /// Rechecks recorded roots at submission, after staged unmap made them unmapped.
    pub fn validateGpuRootsLocked(
        self: *const PendingUses,
        guard: *const core.ObjectGuard,
        device: *core.Device,
    ) Error!void {
        guard.assertOwns(self.objects);
        var keys = self.roots.keyIterator();
        while (keys.next()) |key| try validateRootLocked(guard, device, key.*);
    }

    /// Stamps only the actually accepted submission serial, with no allocation.
    pub fn markSubmittedLocked(
        self: *PendingUses,
        guard: *const core.ObjectGuard,
        serial: buffer.Serial,
    ) void {
        guard.assertOwns(self.objects);
        std.debug.assert(self.leased);
        var keys = self.roots.keyIterator();
        while (keys.next()) |key| {
            if (key.*.kind == .native_buffer) {
                const owner: *Buffer = @fieldParentPtr("header", key.*);
                // Explicit destruction can invalidate the header after Vulkan acceptance.
                // Its real queue lease still keeps native storage through this stamp.
                std.debug.assert(owner.queue_uses != 0);
                owner.accepted_usage_serial = serial;
                owner.native.markUsedInPendingCommands(serial);
            }
        }
    }

    fn releaseRootLocked(guard: *const core.ObjectGuard, io: std.Io, root: *core.Object) void {
        if (root.kind == .native_buffer) {
            const owner: *Buffer = @fieldParentPtr("header", root);
            owner.releaseQueueUseLocked(guard);
        }
        root.releaseLeaseLocked(guard, io);
    }

    /// Removes one duplicate prepared root and consumes its exact real lease.
    pub fn removeRootLocked(
        self: *PendingUses,
        guard: *const core.ObjectGuard,
        io: std.Io,
        root: *core.Object,
    ) void {
        guard.assertOwns(self.objects);
        std.debug.assert(self.leased);
        if (self.roots.remove(root)) releaseRootLocked(guard, io, root);
    }

    pub fn releaseLocked(self: *PendingUses, guard: *const core.ObjectGuard, io: std.Io) void {
        guard.assertOwns(self.objects);
        if (!self.leased) return;
        self.leased = false;
        var keys = self.roots.keyIterator();
        while (keys.next()) |key| releaseRootLocked(guard, io, key.*);
        self.roots.deinit(self.allocator);
        self.roots = .empty;
    }
};

fn containsRefs(comptime T: type) bool {
    if (T == commands.Ref or T == *attachments.CanonicalAttachmentState) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (containsRefs(field.type)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            if (info.tag_type == null) break :blk false;
            inline for (info.fields) |field| if (containsRefs(field.type)) break :blk true;
            break :blk false;
        },
        .optional => |info| containsRefs(info.child),
        .array => |info| containsRefs(info.child),
        .pointer => |info| if (info.size == .slice) containsRefs(info.child) else false,
        else => false,
    };
}

fn collectValueLocked(pending: *PendingUses, guard: *const core.ObjectGuard, device: *core.Device, value: anytype, expected: ?RefKind) Error!void {
    const T = @TypeOf(value);
    if (comptime !containsRefs(T)) return;
    if (comptime T == *attachments.CanonicalAttachmentState) {
        const state = try resolveAttachmentRefLocked(guard, device, value);
        return pending.addRootLocked(guard, device, &state.header);
    }
    if (comptime T == commands.Ref) {
        const pointer = value orelse return;
        const kind = expected orelse return error.ResourceDestroyed;
        const root = try findReferenceLocked(guard, device, pointer, kind);
        return pending.addRootLocked(guard, device, root);
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            if (comptime containsRefs(field.type)) {
                try collectValueLocked(
                    pending,
                    guard,
                    device,
                    @field(value, field.name),
                    fieldRefKind(field.name, expected),
                );
            }
        },
        .@"union" => switch (value) {
            inline else => |payload| try collectValueLocked(pending, guard, device, payload, expected),
        },
        .optional => if (value) |payload| try collectValueLocked(pending, guard, device, payload, expected),
        .array, .pointer => for (value) |item| try collectValueLocked(pending, guard, device, item, expected),
        else => {},
    }
}

/// Collects canonical roots and validates bounded streams before any lease changes.
fn collectFinishedLocked(
    pending: *PendingUses,
    guard: *const core.ObjectGuard,
    device: *core.Device,
    finished: *const encoding_context.Finished,
    max_immediate_size: u32,
) Error!void {
    if (finished.status != .finished) return error.ResourceDestroyed;
    if (finished.device.objectList() != device.arena.objectList())
        return error.ResourceDeviceMismatch;
    try collectValueLocked(pending, guard, device, finished.render_pass_usages.items, null);
    try collectValueLocked(pending, guard, device, finished.compute_pass_usages.items, null);
    try collectValueLocked(pending, guard, device, finished.indirect_draws.items, null);
    var collector: AdmissionCollector = .{
        .pending = pending,
        .guard = guard,
        .device = device,
        .max_immediate_size = @min(max_immediate_size, command_constants.max_immediate_data_bytes),
    };
    var borrowed = finished.iterator(pending.allocator);
    defer borrowed.deinit();
    try collector.walk(&borrowed.iterator, finished.render_pass_usages.items, null);
}

const AdmissionCollector = struct {
    pending: *PendingUses,
    guard: *const core.ObjectGuard,
    device: *core.Device,
    max_immediate_size: u32,
    command_count: usize = 0,
    bundle_depth: usize = 0,
    bundle_stack: [command_constants.max_bundle_depth]*render_bundle.RenderBundle = undefined,

    fn walk(
        self: *AdmissionCollector,
        iterator: *command_allocator.Iterator,
        pass_usages: []const usage.RenderPassResourceUsage,
        initial_attachment: ?*attachments.CanonicalAttachmentState,
    ) Error!void {
        var active = initial_attachment;
        var pass_index: usize = 0;
        while (try iterator.nextTag()) |tag| {
            if (self.command_count == command_constants.max_bundle_command_count)
                return error.CommandCountExhausted;
            self.command_count += 1;
            if (self.bundle_depth != 0) switch (tag) {
                .draw, .draw_indexed, .draw_indirect, .draw_indexed_indirect, .multi_draw_indirect, .multi_draw_indexed_indirect, .set_index_buffer, .set_vertex_buffer, .set_bind_group, .set_immediates, .set_resource_table, .set_stencil_reference, .push_debug_group, .pop_debug_group, .insert_debug_marker, .set_render_pipeline, .execute_bundles => {},
                else => return error.InvalidBundle,
            };
            switch (tag) {
                inline else => |known| {
                    const command = try iterator.nextCommand(commands.Payload(known));
                    if (comptime known == .begin_render_pass) {
                        if (active != null or pass_index >= pass_usages.len)
                            return error.InvalidCommandStream;
                        const state = try resolveAttachmentRefLocked(self.guard, self.device, command.attachment_state);
                        const usage_state = pass_usages[pass_index].attachment_state orelse
                            return error.InvalidCommandStream;
                        if (try resolveAttachmentRefLocked(self.guard, self.device, usage_state) != state)
                            return error.InvalidCommandStream;
                        const value = try replay.buildAttachmentStateLocked(
                            self.guard,
                            self.device,
                            &command.color_attachments,
                            command.depth_stencil_attachment,
                            command.width,
                            command.height,
                        );
                        if (!attachments.AttachmentState.eql(&state.value, &value))
                            return error.InvalidAttachment;
                        active = state;
                        pass_index += 1;
                    }
                    if (comptime known == .end_render_pass) {
                        if (active == null) return error.InvalidCommandStream;
                        active = null;
                    }
                    if (comptime known == .set_render_pipeline or known == .set_compute_pipeline) {
                        const owner = try resolvePipelineRefLocked(self.guard, self.device, command.pipeline);
                        if (owner.native.immediate_size > self.max_immediate_size)
                            return error.ImmediateOutOfRange;
                        if (comptime known == .set_render_pipeline) {
                            const state = try resolveAttachmentRefLocked(self.guard, self.device, command.attachment_state);
                            const required = switch (owner.attachment) {
                                .compute => return error.PipelineTypeMismatch,
                                .render => |value| value,
                            };
                            if (active != state or required != state)
                                return error.InvalidAttachment;
                        } else if (owner.attachment != .compute) return error.PipelineTypeMismatch;
                    }
                    if (comptime known == .set_immediates) {
                        if (command.offset % 4 != 0 or command.size % 4 != 0)
                            return error.ImmediateUnaligned;
                        if (command.offset > self.max_immediate_size or
                            command.size > self.max_immediate_size - command.offset)
                            return error.ImmediateOutOfRange;
                    }
                    if (comptime known == .multi_draw_indirect or known == .multi_draw_indexed_indirect) {
                        if (command.max_draw_count > command_constants.max_bundle_command_count)
                            return error.CommandCountExhausted;
                    }
                    if (comptime known == .copy_texture_for_browser or
                        known == .copy_external_texture_for_browser)
                    {
                        if (comptime known == .copy_texture_for_browser) {
                            const source = try resolveTextureViewRefLocked(
                                self.guard,
                                self.device,
                                command.source,
                            );
                            try self.pending.addRootLocked(self.guard, self.device, &source.header);
                        } else {
                            const source = try resolveExternalTextureRefLocked(
                                self.guard,
                                self.device,
                                command.source,
                            );
                            try self.pending.addRootLocked(self.guard, self.device, &source.header);
                        }
                        const destination = try resolveTextureViewRefLocked(
                            self.guard,
                            self.device,
                            command.destination,
                        );
                        try self.pending.addRootLocked(self.guard, self.device, &destination.header);
                    } else {
                        try collectValueLocked(self.pending, self.guard, self.device, command.*, null);
                    }
                    const Element = commands.DataElement(known);
                    if (comptime Element != void) {
                        const count: usize = switch (known) {
                            .begin_compute_pass => command.label_length,
                            .insert_debug_marker, .push_debug_group => command.length,
                            .set_immediates, .write_buffer => command.size,
                            .set_bind_group => command.dynamic_offset_count,
                            .execute_bundles => command.count,
                            else => unreachable,
                        };
                        if ((known == .begin_compute_pass or known == .set_bind_group) and count == 0) continue;
                        if (comptime known == .begin_compute_pass or known == .insert_debug_marker or known == .push_debug_group) {
                            _ = try commands.nextNullTerminatedString(iterator, @intCast(count));
                        } else if (comptime known == .execute_bundles) {
                            const state = active orelse return error.InvalidCommandStream;
                            for (try iterator.nextData(Element, count)) |reference| {
                                const bundle = try resolveRenderBundleRefLocked(self.guard, self.device, reference);
                                if (bundle.attachmentState() != state) return error.InvalidBundle;
                                if (self.bundle_depth == self.bundle_stack.len) return error.BundleDepthExhausted;
                                for (self.bundle_stack[0..self.bundle_depth]) |ancestor|
                                    if (ancestor == bundle) return error.BundleCycle;
                                try self.pending.addRootLocked(self.guard, self.device, &bundle.header);
                                try collectValueLocked(self.pending, self.guard, self.device, bundle.resource_usage, null);
                                try collectValueLocked(self.pending, self.guard, self.device, bundle.indirect, null);
                                self.bundle_stack[self.bundle_depth] = bundle;
                                self.bundle_depth += 1;
                                defer self.bundle_depth -= 1;
                                var cursor = bundle.iterator(self.guard);
                                defer cursor.deinit();
                                try self.walk(&cursor.iterator, &.{}, state);
                            }
                        } else {
                            try collectValueLocked(self.pending, self.guard, self.device, try iterator.nextData(Element, count), null);
                        }
                    }
                },
            }
        }
        if (self.bundle_depth == 0 and (active != null or pass_index != pass_usages.len))
            return error.InvalidCommandStream;
    }
};

const PendingTestRoot = struct {
    header: core.Object,
    destroyed: *usize,

    pub fn destroy(self: *PendingTestRoot, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        _ = io;
        _ = reason;
        self.destroyed.* += 1;
    }
};

fn pendingTestError(gpa: std.mem.Allocator, io: std.Io, context: *anyopaque, view: core.ErrorView) void {
    _ = gpa;
    _ = io;
    _ = context;
    _ = view;
}

test "pending declared roots deduplicate and outlive final user release" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var destroyed: usize = 0;
    var device = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = &destroyed,
        .uncaptured_callback = pendingTestError,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.arena.objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("pending fixture references escaped");
    const root = try device.create(gpa, &guard, PendingTestRoot, .{ .kind = .query_set, .initial_reference = .user });
    root.destroyed = &destroyed;
    root.header.attach(&guard, io);
    var pending = try PendingUses.prepareDeclaredLocked(gpa, &guard, &device, &.{ &root.header, &root.header });
    try std.testing.expectEqual(@as(u32, 2), root.header.reference_count);
    try root.header.releaseUserLocked(&guard, io);
    try std.testing.expectEqual(@as(usize, 0), destroyed);
    pending.releaseLocked(&guard, io);
    pending.releaseLocked(&guard, io);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}

test "pending declared overflow leaves every earlier root unleased" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var destroyed: usize = 0;
    var device = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = &destroyed,
        .uncaptured_callback = pendingTestError,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.arena.objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("pending fixture references escaped");
    const first = try device.create(gpa, &guard, PendingTestRoot, .{ .kind = .query_set, .initial_reference = .user });
    first.destroyed = &destroyed;
    first.header.attach(&guard, io);
    const last = try device.create(gpa, &guard, PendingTestRoot, .{ .kind = .query_set, .initial_reference = .user });
    last.destroyed = &destroyed;
    last.header.attach(&guard, io);
    last.header.reference_count = std.math.maxInt(u32);
    device.arena.objectList().total_reference_count += std.math.maxInt(u32) - 1;
    try std.testing.expectError(error.ReferenceCountOverflow, PendingUses.prepareDeclaredLocked(gpa, &guard, &device, &.{ &first.header, &last.header }));
    try std.testing.expectEqual(@as(u32, 1), first.header.reference_count);
    last.header.reference_count = 1;
    device.arena.objectList().total_reference_count -= std.math.maxInt(u32) - 1;
    try first.header.releaseUserLocked(&guard, io);
    try last.header.releaseUserLocked(&guard, io);
}

test "pending malformed late command leaves recording and earlier root untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var destroyed: usize = 0;
    var device = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = &destroyed,
        .uncaptured_callback = pendingTestError,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.arena.objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("pending fixture references escaped");
    const root = try device.create(gpa, &guard, PendingTestRoot, .{ .kind = .query_set, .initial_reference = .user });
    root.destroyed = &destroyed;
    root.header.attach(&guard, io);
    defer root.header.releaseUserLocked(&guard, io) catch unreachable;
    var writer = try command_allocator.Allocator.init(gpa, 4096);
    defer writer.deinit();
    const timestamp = try writer.allocateCommand(commands.WriteTimestampCmd, @intFromEnum(commands.Tag.write_timestamp));
    timestamp.* = .{
        .query_set = @ptrCast(@as(*query_set.QuerySet, @fieldParentPtr("header", &root.header))),
        .query_index = 0,
    };
    _ = try writer.allocate(999999, 0);
    var finished: encoding_context.Finished = .{
        .device = device.borrow(),
        .blocks = writer.acquireBlocks(),
        .render_pass_usages = .empty,
        .compute_pass_usages = .empty,
        .indirect_draws = .empty,
        .status = .finished,
    };
    defer finished.deinit(gpa, io, &guard);
    const storage = finished.blocks.items.ptr;
    try std.testing.expectError(error.InvalidCommandTag, PendingUses.prepareFinishedLocked(gpa, &guard, &device, &finished, 0));
    try std.testing.expectEqual(@as(u32, 1), root.header.reference_count);
    try std.testing.expectEqual(encoding_context.Status.finished, finished.status);
    try std.testing.expectEqual(storage, finished.blocks.items.ptr);
}

test "pending root allocation failures never leak a lease" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, pendingAllocationRoundTrip, .{});
}

fn pendingAllocationRoundTrip(gpa: std.mem.Allocator) !void {
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var destroyed: usize = 0;
    var device = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = &destroyed,
        .uncaptured_callback = pendingTestError,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.arena.objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("pending allocation rollback leaked references");
    const root = try device.create(gpa, &guard, PendingTestRoot, .{ .kind = .query_set, .initial_reference = .user });
    root.destroyed = &destroyed;
    root.header.attach(&guard, io);
    defer root.header.releaseUserLocked(&guard, io) catch unreachable;
    var pending = try PendingUses.prepareDeclaredLocked(gpa, &guard, &device, &.{ &root.header, &root.header });
    defer pending.releaseLocked(&guard, io);
    try std.testing.expectEqual(@as(u32, 2), root.header.reference_count);
}

test "pending rejects foreign failed and retired roots before payload access" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var other_mutex: std.Io.Mutex = .init;
    var destroyed: usize = 0;
    var device = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = &destroyed,
        .uncaptured_callback = pendingTestError,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, device.arena.objectList());
    defer guard.unlock(io);
    defer device.deinit(gpa, &guard) catch @panic("pending admission fixture references escaped");
    var other_objects: core.ObjectList = .{ .mutex = &other_mutex };
    // The immutable locator is the only initialized field. A wrong-device
    // admission must reject it without reading state, kind or payload.
    var foreign: core.Object = undefined;
    foreign.tracking = &other_objects;
    try std.testing.expectError(error.ResourceDeviceMismatch, PendingUses.prepareDeclaredLocked(gpa, &guard, &device, &.{&foreign}));
    const root = try device.create(gpa, &guard, PendingTestRoot, .{ .kind = .query_set, .state = .initializing, .initial_reference = .user });
    root.destroyed = &destroyed;
    root.header.setInitializedError(&guard, error.StaleHandle);
    root.header.attach(&guard, io);
    try std.testing.expectError(error.ResourceDestroyed, PendingUses.prepareDeclaredLocked(gpa, &guard, &device, &.{&root.header}));
    root.header.retirePayloadLocked(&guard, io, .early_destroy);
    try std.testing.expectError(error.ResourceDestroyed, PendingUses.prepareDeclaredLocked(gpa, &guard, &device, &.{&root.header}));
    try root.header.releaseUserLocked(&guard, io);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}
