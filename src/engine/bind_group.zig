//! Owning native bind groups, using the existing serial-retired set allocator.
//! Descriptor writes follow pinned Dawn BindGroupVk.cpp:76-244.
//! Texture views have guarded lifetime leases. Buffers, ordinary samplers, and
//! the allocator must remain alive through GPU completion. Conversion views own
//! their actual sampler; combined descriptors require that immutable sampler.
//! Creation requires the owning physical device's uniform/storage range limits.
//! Sampled depth/stencil descriptors select one aspect; attachment views may keep both.
//! Creation and destruction hold the actual owning ObjectList guard throughout.
const std = @import("std");

const vulkan = @import("vulkan");

const descriptor = @import("../pipeline/bind_group_descriptor_set.zig");
const pipeline = @import("../pipeline/pipeline.zig");
const serial = @import("../platform/serial.zig");
const dispatch = @import("../vk/dispatch.zig");
const buffer_mod = @import("buffer.zig");
const format = @import("format.zig");
const texture_mod = @import("texture.zig");
const sampler_mod = @import("sampler.zig");
const core = @import("../core/root.zig");

const DescriptorInfo = extern union {
    buffer: vulkan.VkDescriptorBufferInfo,
    image: vulkan.VkDescriptorImageInfo,
};

pub const Error = descriptor.Error || texture_mod.NativeError || core.ReferenceError ||
    core.CreateError || core.LifetimeError || error{
    BindGroupLayoutInvalid,
    BindGroupDestroyed,
    BindingOrderInvalid,
    BindingRangeOutsideBuffer,
    BindingRangeExceedsLimit,
    BindingUsageInvalid,
    BindingResourceInvalid,
    BindingTextureAspectInvalid,
    DynamicOffsetUnaligned,
    DynamicOffsetCountMismatch,
    BindingLayoutUnsupported,
};

pub const BufferBinding = struct {
    binding: u32,
    buffer: *buffer_mod.Buffer,
    offset: u64,
    size: u64,
    kind: enum { uniform, storage, read_only_storage, internal_storage, internal_read_only_storage },
    dynamic: bool = false,
    alignment: u32 = 256,
    stages: buffer_mod.ShaderStage,
};

pub const Binding = union(enum) {
    buffer: BufferBinding,
    texture: struct {
        binding: u32,
        view: *texture_mod.TextureView,
        storage: bool = false,
        internal: bool = false,
        depth_view: bool = false,
        stages: buffer_mod.ShaderStage,
    },
    sampler: struct { binding: u32, handle: vulkan.VkSampler },
    combined_y_cb_cr_view: struct {
        binding: u32,
        view: *texture_mod.TextureView,
        sampler: *sampler_mod.Sampler,
        stages: buffer_mod.ShaderStage,
    },

    fn index(self: Binding) u32 {
        return switch (self) {
            inline else => |resource| resource.binding,
        };
    }
};

/// Actual range limits from the physical device that owns the descriptor set.
pub const BufferLimits = struct {
    max_uniform_buffer_range: u32,
    max_storage_buffer_range: u32,

    pub fn fromPhysicalDeviceLimits(limits: *const vulkan.VkPhysicalDeviceLimits) BufferLimits {
        return .{
            .max_uniform_buffer_range = limits.maxUniformBufferRange,
            .max_storage_buffer_range = limits.maxStorageBufferRange,
        };
    }
};

pub const Options = struct {
    objects: *core.ObjectList,
    descriptor_allocator: *descriptor.DescriptorSetAllocator,
    pipeline_layout: vulkan.VkPipelineLayout,
    group_index: u32,
    group_layout: pipeline.GroupLayout,
    canonical_layout_header: ?*const core.Object = null,
    buffer_limits: BufferLimits,
    /// Packed Vulkan binding numbers, ascending, from the owning layout.
    bindings: []const Binding,
};

/// The set token belongs to this object, but its allocator and buffer/sampler
/// resources belong to the caller and must outlive GPU execution.
pub const BindGroup = struct {
    objects: *core.ObjectList,
    allocator: std.mem.Allocator,
    descriptor_allocator: *descriptor.DescriptorSetAllocator,
    descriptor_allocation: descriptor.DescriptorSetAllocation,
    pipeline_layout: vulkan.VkPipelineLayout,
    group_index: u32,
    group_layout: pipeline.GroupLayout,
    bindings: []Binding,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        guard: *const core.ObjectGuard,
        options: Options,
    ) Error!*BindGroup {
        guard.assertOwns(options.objects);
        if (options.objects.marked_destroyed) return error.ResourceDestroyed;
        if (options.pipeline_layout == null or options.descriptor_allocator.set_layout == null)
            return error.BindGroupLayoutInvalid;
        if (options.group_layout.handle != options.descriptor_allocator.set_layout or
            options.group_layout.bindings.len != options.bindings.len)
            return error.BindGroupLayoutInvalid;
        if (options.group_layout.has_external_texture)
            try validateExternalLayout(guard, options.objects, options.canonical_layout_header);
        // Native descriptor restrictions precede every host and Vulkan allocation.
        for (options.bindings, 0..) |binding, index| switch (binding) {
            .buffer => |resource| {
                const limit = if (resource.kind == .uniform)
                    options.buffer_limits.max_uniform_buffer_range
                else
                    options.buffer_limits.max_storage_buffer_range;
                if (resource.size > limit) return error.BindingRangeExceedsLimit;
            },
            .texture => |resource| {
                try validateTextureView(guard, options.objects, resource.view);
                try validateDepthView(resource);
                if (resource.storage and !resource.view.isSwizzleIdentity(guard))
                    return error.TextureNativeUsageUnsupported;
                if (!resource.storage and resource.view.aspects.depth != 0 and resource.view.aspects.stencil != 0)
                    return error.BindingTextureAspectInvalid;
            },
            .combined_y_cb_cr_view => |resource| try validateCombinedView(
                guard,
                options.objects,
                options.descriptor_allocator.device,
                resource,
                options.group_layout.bindings[index],
            ),
            .sampler => {},
        };
        var retained_count: usize = 0;
        errdefer for (options.bindings[0..retained_count]) |binding| switch (binding) {
            .texture => |resource| resource.view.header.releaseLeaseLocked(guard, io),
            .combined_y_cb_cr_view => |resource| resource.view.header.releaseLeaseLocked(guard, io),
            else => {},
        };
        for (options.bindings) |binding| {
            switch (binding) {
                .texture => |resource| try resource.view.header.retainLeaseLocked(guard),
                .combined_y_cb_cr_view => |resource| try resource.view.header.retainLeaseLocked(guard),
                else => {},
            }
            retained_count += 1;
        }
        const group_layout = try options.group_layout.clone(allocator);
        errdefer {
            var owned = group_layout;
            owned.deinit(allocator);
        }
        const update = options.descriptor_allocator.procs.update_descriptor_sets orelse
            return error.MissingDeviceProc;
        const self = try allocator.create(BindGroup);
        errdefer allocator.destroy(self);
        const bindings = try allocator.dupe(Binding, options.bindings);
        errdefer allocator.free(bindings);
        const writes = try allocator.alloc(vulkan.VkWriteDescriptorSet, bindings.len);
        defer allocator.free(writes);
        const infos = try allocator.alloc(DescriptorInfo, bindings.len);
        defer allocator.free(infos);
        for (bindings, 0..) |binding, index| {
            if (index != 0 and binding.index() <= bindings[index - 1].index())
                return error.BindingOrderInvalid;
            writes[index] = .{
                .sType = vulkan.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstBinding = binding.index(),
                .descriptorCount = 1,
            };
            switch (binding) {
                .buffer => |resource| {
                    try validateBufferBinding(resource, 0);
                    if (resource.buffer.handle == null or resource.buffer.state == .destroyed)
                        return error.BindingResourceInvalid;
                    const uniform = resource.kind == .uniform;
                    try validateBufferUsage(resource);
                    infos[index].buffer = .{
                        .buffer = resource.buffer.getHandle(),
                        .offset = resource.offset,
                        .range = resource.size,
                    };
                    writes[index].descriptorType = if (uniform)
                        (if (resource.dynamic) @as(
                            u32,
                            vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
                        ) else @as(u32, vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER))
                    else
                        (if (resource.dynamic) @as(
                            u32,
                            vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC,
                        ) else @as(u32, vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER));
                    writes[index].pBufferInfo = &infos[index].buffer;
                },
                .texture => |resource| {
                    try validateTextureUsage(resource);
                    infos[index].image = .{
                        .imageView = try resource.view.getHandle(guard),
                        .imageLayout = if (resource.storage)
                            @as(u32, vulkan.VK_IMAGE_LAYOUT_GENERAL)
                        else
                            resource.view.texture.sampledLayout(guard),
                    };
                    writes[index].descriptorType = if (resource.storage)
                        @as(u32, vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE)
                    else
                        @as(u32, vulkan.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
                    writes[index].pImageInfo = &infos[index].image;
                },
                .combined_y_cb_cr_view => |resource| {
                    infos[index].image = .{
                        .sampler = resource.sampler.native.?.sampler,
                        .imageView = try resource.view.getHandle(guard),
                        .imageLayout = resource.view.texture.sampledLayout(guard),
                    };
                    writes[index].descriptorType = vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                    writes[index].pImageInfo = &infos[index].image;
                },
                .sampler => |resource| {
                    if (resource.handle == null) return error.BindingResourceInvalid;
                    infos[index].image = .{ .sampler = resource.handle };
                    writes[index].descriptorType = vulkan.VK_DESCRIPTOR_TYPE_SAMPLER;
                    writes[index].pImageInfo = &infos[index].image;
                },
            }
            const expected = group_layout.bindings[index];
            if (expected.binding != binding.index() or expected.descriptorCount != 1 or
                expected.descriptorType != writes[index].descriptorType)
                return error.BindGroupLayoutInvalid;
            if (binding != .combined_y_cb_cr_view and expected.pImmutableSamplers != null)
                return error.BindingLayoutUnsupported;
            const stages = switch (binding) {
                .buffer => |resource| resource.stages,
                .texture => |resource| resource.stages,
                .combined_y_cb_cr_view => |resource| resource.stages,
                .sampler => continue,
            };
            var flags: vulkan.VkShaderStageFlags = 0;
            if (stages.vertex) flags |= vulkan.VK_SHADER_STAGE_VERTEX_BIT;
            if (stages.fragment) flags |= vulkan.VK_SHADER_STAGE_FRAGMENT_BIT;
            if (stages.compute) flags |= vulkan.VK_SHADER_STAGE_COMPUTE_BIT;
            if (flags != expected.stageFlags) return error.BindGroupLayoutInvalid;
        }
        // All fallible host work precedes set allocation, so no rollback needs
        // to enqueue a descriptor deallocation that could itself allocate.
        const allocation = try options.descriptor_allocator.allocate();
        for (writes) |*write| write.dstSet = allocation.set;
        update(options.descriptor_allocator.device, @intCast(writes.len), writes.ptr, 0, null);
        self.* = .{
            .objects = options.objects,
            .allocator = allocator,
            .descriptor_allocator = options.descriptor_allocator,
            .descriptor_allocation = allocation,
            .pipeline_layout = options.pipeline_layout,
            .group_index = options.group_index,
            .group_layout = group_layout,
            .bindings = bindings,
        };
        return self;
    }

    pub fn getHandle(
        self: *const BindGroup,
        guard: *const core.ObjectGuard,
    ) Error!vulkan.VkDescriptorSet {
        guard.assertOwns(self.objects);
        return self.descriptor_allocation.set orelse return error.BindGroupDestroyed;
    }

    pub fn validateDynamicOffsets(
        self: *const BindGroup,
        guard: *const core.ObjectGuard,
        offsets: []const u32,
    ) Error!void {
        guard.assertOwns(self.objects);
        var index: usize = 0;
        for (self.bindings) |binding| {
            if (binding != .buffer or !binding.buffer.dynamic) continue;
            if (index >= offsets.len) return error.DynamicOffsetCountMismatch;
            try validateBufferBinding(binding.buffer, offsets[index]);
            index += 1;
        }
        if (index != offsets.len) return error.DynamicOffsetCountMismatch;
    }

    /// Only the completed serial permits reuse; the owning descriptor allocator
    /// processes it through finishDeallocation.
    pub fn destroy(
        self: *BindGroup,
        allocator: std.mem.Allocator,
        io: std.Io,
        guard: *const core.ObjectGuard,
        pending_serial: serial.Serial,
    ) Error!void {
        guard.assertOwns(self.objects);
        if (self.allocator.ptr != allocator.ptr or self.allocator.vtable != allocator.vtable)
            return error.AllocatorMismatch;
        try self.descriptor_allocator.deallocate(&self.descriptor_allocation, pending_serial);
        for (self.bindings) |binding| switch (binding) {
            .texture => |resource| resource.view.header.releaseLeaseLocked(guard, io),
            .combined_y_cb_cr_view => |resource| resource.view.header.releaseLeaseLocked(guard, io),
            else => {},
        };
        allocator.free(self.bindings);
        self.group_layout.deinit(allocator);
        allocator.destroy(self);
    }
};

fn validateTextureView(
    guard: *const core.ObjectGuard,
    objects: *core.ObjectList,
    view: *const texture_mod.TextureView,
) core.ReferenceError!void {
    guard.assertOwns(objects);
    if (view.header.tracking != objects) return error.ResourceDeviceMismatch;
    if (!view.header.node.linked or view.header.state != .alive or
        view.header.reference_count == 0) return error.ResourceDestroyed;
    const texture = view.texture;
    if (texture.header.tracking != objects) return error.ResourceDeviceMismatch;
    if (!texture.header.node.linked or texture.header.state != .alive or
        texture.header.reference_count == 0) return error.ResourceDestroyed;
}

fn validateExternalLayout(
    guard: *const core.ObjectGuard,
    objects: *core.ObjectList,
    canonical_layout_header: ?*const core.Object,
) Error!void {
    guard.assertOwns(objects);
    const header = canonical_layout_header orelse return error.BindingLayoutUnsupported;
    if (header.tracking != objects) return error.ResourceDeviceMismatch;
    if (!header.node.linked or header.state != .alive or header.reference_count == 0)
        return error.ResourceDestroyed;
    if (header.kind != .pipeline_layout) return error.BindingLayoutUnsupported;
}

fn validateBufferUsage(resource: BufferBinding) Error!void {
    const public_storage = (buffer_mod.BufferUsage{ .storage = true }).toFlags();
    const allowed = switch (resource.kind) {
        .uniform => resource.buffer.usage.uniform,
        .storage, .read_only_storage => resource.buffer.usage.storage,
        .internal_storage => resource.buffer.internal_usage &
            (buffer_mod.internal_storage_buffer | public_storage) != 0,
        .internal_read_only_storage => resource.buffer.internal_usage &
            (buffer_mod.read_only_storage_buffer |
                buffer_mod.internal_storage_buffer | public_storage) != 0,
    };
    if (!allowed) return error.BindingUsageInvalid;
}

fn validateTextureUsage(resource: @FieldType(Binding, "texture")) Error!void {
    const usage = if (resource.internal) resource.view.internal_usage else resource.view.usage;
    if ((resource.storage and !usage.storage_binding) or
        (!resource.storage and !usage.texture_binding))
        return error.BindingUsageInvalid;
}

fn validateDepthView(resource: @FieldType(Binding, "texture")) Error!void {
    if (!resource.depth_view) return;
    if (!resource.internal or resource.storage) return error.BindingUsageInvalid;
    if (!resource.view.format_info.hasDepth() or
        resource.view.aspects.toFlags() != (texture_mod.AspectMask{ .depth = 1 }).toFlags())
        return error.BindingTextureAspectInvalid;
}

fn validateCombinedView(
    guard: *const core.ObjectGuard,
    objects: *core.ObjectList,
    device: vulkan.VkDevice,
    resource: @FieldType(Binding, "combined_y_cb_cr_view"),
    expected: vulkan.VkDescriptorSetLayoutBinding,
) Error!void {
    try validateTextureView(guard, objects, resource.view);
    const owner = resource.sampler;
    if (owner.header.tracking != objects) return error.ResourceDeviceMismatch;
    if (!owner.header.node.linked or owner.header.state != .alive or
        owner.header.reference_count == 0)
        return error.ResourceDestroyed;
    if (owner.header.kind != .sampler or resource.view.conversion_sampler != owner)
        return error.BindingResourceInvalid;
    const conversion = owner.key.y_cb_cr orelse return error.BindingResourceInvalid;
    if (conversion.external_format != 0) return error.BindingLayoutUnsupported;
    const native = owner.native orelse return error.BindingResourceInvalid;
    if (native.backend.handle != device) return error.ResourceDeviceMismatch;
    if (native.sampler == null or native.conversion == null) return error.BindingResourceInvalid;
    if (!resource.view.internal_usage.texture_binding) return error.BindingUsageInvalid;
    try resource.view.validateYCbCr(guard, owner);
    const view_handle = try resource.view.getHandle(guard);
    if (view_handle == null) return error.BindingResourceInvalid;
    if (expected.binding != resource.binding or expected.descriptorCount != 1 or
        expected.descriptorType != vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER or
        expected.pImmutableSamplers == null or expected.pImmutableSamplers[0] != native.sampler)
        return error.BindGroupLayoutInvalid;
}

fn validateBufferBinding(resource: BufferBinding, dynamic_offset: u32) Error!void {
    if (resource.alignment == 0 or resource.offset % resource.alignment != 0 or
        dynamic_offset % resource.alignment != 0)
        return error.DynamicOffsetUnaligned;
    if (resource.size == 0 or resource.offset > resource.buffer.size or
        dynamic_offset > resource.buffer.size - resource.offset or
        resource.size > resource.buffer.size - resource.offset - dynamic_offset)
        return error.BindingRangeOutsideBuffer;
}
test "dynamic binding validates alignment and buffer bounds without Vulkan" {
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var objects: core.ObjectList = .{ .mutex = &mutex };
    var guard = core.ObjectGuard.lockUncancelable(io, &objects);
    defer guard.unlock(io);
    var buffer: buffer_mod.Buffer = undefined;
    buffer.size = 1024;
    const bindings = [_]Binding{.{ .buffer = .{
        .binding = 0,
        .buffer = &buffer,
        .offset = 0,
        .size = 256,
        .kind = .uniform,
        .dynamic = true,
        .alignment = 256,
        .stages = .none,
    } }};
    const group: BindGroup = .{
        .objects = &objects,
        .allocator = undefined,
        .descriptor_allocator = undefined,
        .descriptor_allocation = .{},
        .pipeline_layout = null,
        .group_index = 0,
        .bindings = @constCast(&bindings),
        .group_layout = .{ .handle = null, .bindings = &.{} },
    };
    try group.validateDynamicOffsets(&guard, &.{768});
    try std.testing.expectError(
        error.DynamicOffsetUnaligned,
        group.validateDynamicOffsets(&guard, &.{1}),
    );
    try std.testing.expectError(
        error.BindingRangeOutsideBuffer,
        group.validateDynamicOffsets(&guard, &.{1024}),
    );
    try std.testing.expectError(
        error.DynamicOffsetCountMismatch,
        group.validateDynamicOffsets(&guard, &.{}),
    );
}

test "bind group host allocation failures cannot orphan descriptor sets" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, groupAllocationRoundTrip, .{});
}

test "bind group rejects descriptor schema mismatch before allocating a set" {
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var objects: core.ObjectList = .{ .mutex = &mutex };
    var guard = core.ObjectGuard.lockUncancelable(io, &objects);
    defer guard.unlock(io);
    var fixture: DescriptorFixture = .{};
    var procs = descriptorFixtureProcs();
    var sets = try descriptor.DescriptorSetAllocator.init(
        std.testing.allocator,
        &procs,
        @ptrCast(&fixture),
        @ptrFromInt(1),
        &.{.{ .type = vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1 }},
    );
    defer sets.deinit() catch @panic("descriptor fixture teardown failed");
    var resource = fixtureBuffer();
    const bindings = [_]Binding{.{ .buffer = .{
        .binding = 0,
        .buffer = &resource,
        .offset = 0,
        .size = 16,
        .kind = .uniform,
        .stages = .{ .fragment = true },
    } }};
    const schema = [_]vulkan.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
    }};
    try std.testing.expectError(error.BindGroupLayoutInvalid, BindGroup.create(
        std.testing.allocator,
        io,
        &guard,
        .{
            .objects = &objects,
            .descriptor_allocator = &sets,
            .pipeline_layout = @ptrFromInt(2),
            .group_index = 0,
            .group_layout = .{ .handle = sets.set_layout, .bindings = &schema },
            .bindings = &bindings,
            .buffer_limits = .{ .max_uniform_buffer_range = 65536, .max_storage_buffer_range = 131072 },
        },
    ));
    try std.testing.expectEqual(@as(u32, 0), fixture.pools_created);
    try std.testing.expectEqual(@as(u32, 0), fixture.updates);
}

test "buffer descriptor limits preserve actual physical device properties" {
    var physical_limits = std.mem.zeroes(vulkan.VkPhysicalDeviceLimits);
    physical_limits.maxUniformBufferRange = 98304;
    physical_limits.maxStorageBufferRange = 393216;
    const limits = BufferLimits.fromPhysicalDeviceLimits(&physical_limits);
    try std.testing.expectEqual(@as(u32, 98304), limits.max_uniform_buffer_range);
    try std.testing.expectEqual(@as(u32, 393216), limits.max_storage_buffer_range);
}

test "storage texture descriptors require identity swizzles while sampled descriptors allow swizzles" {
    inline for (.{ false, true }) |storage| {
        inline for (.{ false, true }) |identity| {
            try textureDescriptorRoundTrip(std.testing.allocator, storage, identity, .{ .color = 1 });
        }
    }
}

test "sampled depth stencil descriptors accept one aspect and reject combined attachment views before allocation" {
    const aspects = [_]texture_mod.AspectMask{
        .{ .depth = 1 },
        .{ .stencil = 1 },
        .{ .depth = 1, .stencil = 1 },
    };
    for (aspects) |aspect| {
        try textureDescriptorRoundTrip(std.testing.allocator, false, true, aspect);
    }
}

test "bind group host allocation failure rolls back texture view leases" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        textureAllocationRoundTrip,
        .{},
    );
}

fn textureAllocationRoundTrip(allocator: std.mem.Allocator) !void {
    try textureDescriptorRoundTrip(allocator, false, true, .{ .color = 1 });
}

fn textureDescriptorRoundTrip(
    group_allocator: std.mem.Allocator,
    storage: bool,
    identity: bool,
    aspects: texture_mod.AspectMask,
) !void {
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var objects: core.ObjectList = .{ .mutex = &mutex };
    var guard = core.ObjectGuard.lockUncancelable(io, &objects);
    defer guard.unlock(io);
    var fixture: DescriptorFixture = .{};
    var procs = descriptorFixtureProcs();
    const descriptor_type: u32 = if (storage)
        vulkan.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
    else
        vulkan.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
    var sets = try descriptor.DescriptorSetAllocator.init(
        std.testing.allocator,
        &procs,
        @ptrCast(&fixture),
        @ptrFromInt(1),
        &.{.{ .type = descriptor_type, .descriptorCount = 1 }},
    );
    defer sets.deinit() catch @panic("descriptor fixture teardown failed");
    // SAFETY: buildFormatTable writes all 109 canonical rows before this fixture selects a row.
    var table: format.FormatTable = undefined;
    format.buildFormatTable(.{}, &table);
    // Only descriptor payload fields are needed; headers use the full linked Rc ledger.
    var texture: texture_mod.Texture = undefined;
    initFixtureHeader(&texture.header, &objects, &guard, io, .texture, &texture, &fixtureDestroy);
    defer texture.header.releaseUserLocked(&guard, io) catch @panic("texture release failed");
    texture.format_info = &table[
        format.computeFormatIndex(
            if (aspects.color != 0) .rgba8_unorm else .depth24_plus_stencil8,
        ).?
    ];
    texture.internal_usage = .{ .texture_binding = true, .storage_binding = true };
    var native_texture: @TypeOf(texture.native.?.*) = .{
        .allocator = std.testing.allocator,
        .context = undefined,
        .procs = &procs,
        .image = @ptrFromInt(7),
        .memory = null,
        .states = &.{},
    };
    texture.native = &native_texture;
    texture.native_y_cb_cr = null;
    // The view owns its parent lease, independently of the group's view lease.
    var view: texture_mod.TextureView = undefined;
    try texture.header.retainLeaseLocked(&guard);
    initFixtureHeader(&view.header, &objects, &guard, io, .texture_view, &view, &fixtureViewDestroy);
    defer view.header.releaseUserLocked(&guard, io) catch @panic("view release failed");
    view.texture = &texture;
    view.aspects = aspects;
    view.usage = .{ .texture_binding = true, .storage_binding = true, .render_attachment = aspects.color == 0 };
    view.swizzle = if (identity) texture_mod.identitySwizzle() else .{ .r = .b, .g = .g, .b = .r, .a = .a };
    view.native_view = @ptrFromInt(8);
    const bindings = [_]Binding{.{ .texture = .{
        .binding = 0,
        .view = &view,
        .storage = storage,
        .stages = .{ .fragment = true },
    } }};
    const schema = [_]vulkan.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = descriptor_type,
        .descriptorCount = 1,
        .stageFlags = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
    }};
    const options: Options = .{
        .objects = &objects,
        .descriptor_allocator = &sets,
        .pipeline_layout = @ptrFromInt(2),
        .group_index = 0,
        .group_layout = .{ .handle = sets.set_layout, .bindings = &schema },
        .bindings = &bindings,
        .buffer_limits = .{ .max_uniform_buffer_range = 65536, .max_storage_buffer_range = 131072 },
    };
    const invalid_aspects = !storage and aspects.depth != 0 and aspects.stencil != 0;
    if ((storage and !identity) or invalid_aspects) {
        var no_memory: [0]u8 = .{};
        var allocator = std.heap.FixedBufferAllocator.init(&no_memory);
        try std.testing.expectError(
            if (invalid_aspects) error.BindingTextureAspectInvalid else error.TextureNativeUsageUnsupported,
            BindGroup.create(allocator.allocator(), io, &guard, options),
        );
        try std.testing.expectEqual(@as(u32, 0), fixture.pools_created);
        try std.testing.expectEqual(@as(u32, 0), fixture.updates);
        try std.testing.expectEqual(@as(u32, 1), view.header.reference_count);
    } else {
        const group = try BindGroup.create(group_allocator, io, &guard, options);
        try std.testing.expectEqual(@as(u32, 1), fixture.updates);
        try std.testing.expectEqual(view.native_view, fixture.image_view);
        try std.testing.expectEqual(descriptor_type, fixture.descriptor_type);
        try std.testing.expectEqual(@as(u32, 2), view.header.reference_count);
        try std.testing.expectEqual(@as(u32, 1), view.header.user_reference_count);
        try std.testing.expectEqual(@as(u32, 2), texture.header.reference_count);
        try std.testing.expectEqual(@as(u64, 4), objects.total_reference_count);
        try group.destroy(group_allocator, io, &guard, 1);
        try sets.finishDeallocation(1);
        try std.testing.expectEqual(@as(u32, 1), view.header.reference_count);
        try std.testing.expectEqual(@as(u64, 3), objects.total_reference_count);
    }
}

test "bind group accepts valid buffer range limit by descriptor type" {
    const kinds = .{
        .uniform, .storage, .read_only_storage, .internal_storage, .internal_read_only_storage,
    };
    inline for (kinds) |kind| {
        inline for (.{ false, true }) |dynamic| {
            try bufferRangeRoundTrip(kind, dynamic, if (kind == .uniform) 65536 else 131072, false);
        }
    }
}

test "bind group rejects buffer range exceeding limit by descriptor type before host allocation" {
    const kinds = .{
        .uniform, .storage, .read_only_storage, .internal_storage, .internal_read_only_storage,
    };
    inline for (kinds) |kind| {
        inline for (.{ false, true }) |dynamic| {
            try bufferRangeRoundTrip(kind, dynamic, if (kind == .uniform) 65537 else 131073, true);
        }
    }
}

fn bufferRangeRoundTrip(
    kind: @FieldType(BufferBinding, "kind"),
    dynamic: bool,
    size: u64,
    exceeds_limit: bool,
) !void {
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var objects: core.ObjectList = .{ .mutex = &mutex };
    var guard = core.ObjectGuard.lockUncancelable(io, &objects);
    defer guard.unlock(io);
    var fixture: DescriptorFixture = .{};
    var procs = descriptorFixtureProcs();
    const descriptor_type: u32 = if (kind == .uniform)
        (if (dynamic)
            vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC
        else
            vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER)
    else
        (if (dynamic)
            vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC
        else
            vulkan.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER);
    var sets = try descriptor.DescriptorSetAllocator.init(
        std.testing.allocator,
        &procs,
        @ptrCast(&fixture),
        @ptrFromInt(1),
        &.{.{ .type = descriptor_type, .descriptorCount = 1 }},
    );
    defer sets.deinit() catch @panic("descriptor fixture teardown failed");
    var resource = fixtureBuffer();
    resource.size = 262144;
    resource.usage = .{ .uniform = true, .storage = true };
    resource.internal_usage = buffer_mod.computeInternalBufferUsages(resource.usage);
    const bindings = [_]Binding{.{ .buffer = .{
        .binding = 0,
        .buffer = &resource,
        .offset = 0,
        .size = size,
        .kind = kind,
        .dynamic = dynamic,
        .stages = .{ .fragment = true },
    } }};
    const schema = [_]vulkan.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = descriptor_type,
        .descriptorCount = 1,
        .stageFlags = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
    }};
    const options: Options = .{
        .objects = &objects,
        .descriptor_allocator = &sets,
        .pipeline_layout = @ptrFromInt(2),
        .group_index = 0,
        .group_layout = .{ .handle = sets.set_layout, .bindings = &schema },
        .bindings = &bindings,
        .buffer_limits = .{ .max_uniform_buffer_range = 65536, .max_storage_buffer_range = 131072 },
    };
    if (exceeds_limit) {
        var no_memory: [0]u8 = .{};
        var allocator = std.heap.FixedBufferAllocator.init(&no_memory);
        try std.testing.expectError(
            error.BindingRangeExceedsLimit,
            BindGroup.create(allocator.allocator(), io, &guard, options),
        );
        try std.testing.expectEqual(@as(u32, 0), fixture.pools_created);
        try std.testing.expectEqual(@as(u32, 0), fixture.updates);
    } else {
        const group = try BindGroup.create(std.testing.allocator, io, &guard, options);
        try std.testing.expectEqual(@as(u32, 1), fixture.updates);
        try std.testing.expectEqual(size, fixture.buffer_range);
        try std.testing.expectEqual(descriptor_type, fixture.descriptor_type);
        try group.destroy(std.testing.allocator, io, &guard, 1);
        try sets.finishDeallocation(1);
    }
}

fn fixtureBuffer() buffer_mod.Buffer {
    // SAFETY: all buffer descriptor fields, including internal usage, are set below.
    // BindGroup borrows the buffer and never calls its owner teardown.
    var resource: buffer_mod.Buffer = undefined;
    resource.handle = @ptrFromInt(3);
    resource.state = .unmapped;
    resource.size = 256;
    resource.usage = .{ .uniform = true };
    resource.internal_usage = buffer_mod.computeInternalBufferUsages(resource.usage);
    return resource;
}

fn groupAllocationRoundTrip(allocator: std.mem.Allocator) !void {
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var objects: core.ObjectList = .{ .mutex = &mutex };
    var guard = core.ObjectGuard.lockUncancelable(io, &objects);
    defer guard.unlock(io);
    var fixture: DescriptorFixture = .{};
    var procs = descriptorFixtureProcs();
    var sets = try descriptor.DescriptorSetAllocator.init(
        std.testing.allocator,
        &procs,
        @ptrCast(&fixture),
        @ptrFromInt(1),
        &.{.{ .type = vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1 }},
    );
    defer sets.deinit() catch @panic("descriptor fixture teardown failed");
    var resource = fixtureBuffer();
    const bindings = [_]Binding{.{ .buffer = .{
        .binding = 0,
        .buffer = &resource,
        .offset = 0,
        .size = 16,
        .kind = .uniform,
        .stages = .{ .fragment = true },
    } }};
    const schema = [_]vulkan.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
    }};
    const group = try BindGroup.create(allocator, io, &guard, .{
        .objects = &objects,
        .descriptor_allocator = &sets,
        .pipeline_layout = @ptrFromInt(2),
        .group_index = 0,
        .group_layout = .{ .handle = sets.set_layout, .bindings = &schema },
        .bindings = &bindings,
        .buffer_limits = .{ .max_uniform_buffer_range = 65536, .max_storage_buffer_range = 131072 },
    });
    try std.testing.expectEqual(@as(u32, 1), fixture.updates);
    try std.testing.expect(group.group_layout.bindings.ptr != schema[0..].ptr);
    try group.destroy(allocator, io, &guard, 1);
    try sets.finishDeallocation(1);
    const allocation = try sets.allocate();
    try std.testing.expect(allocation.set != null);
}

test "bind group view lease failure rolls back only successful retains before allocation" {
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var objects: core.ObjectList = .{ .mutex = &mutex };
    var guard = core.ObjectGuard.lockUncancelable(io, &objects);
    defer guard.unlock(io);
    var texture: texture_mod.Texture = undefined;
    initFixtureHeader(&texture.header, &objects, &guard, io, .texture, &texture, &fixtureDestroy);
    defer texture.header.releaseUserLocked(&guard, io) catch @panic("texture release failed");
    var first: texture_mod.TextureView = undefined;
    first.texture = &texture;
    first.aspects = .{ .color = 1 };
    try texture.header.retainLeaseLocked(&guard);
    initFixtureHeader(&first.header, &objects, &guard, io, .texture_view, &first, &fixtureViewDestroy);
    defer first.header.releaseUserLocked(&guard, io) catch @panic("first view release failed");
    var second: texture_mod.TextureView = undefined;
    second.texture = &texture;
    second.aspects = .{ .color = 1 };
    try texture.header.retainLeaseLocked(&guard);
    initFixtureHeader(&second.header, &objects, &guard, io, .texture_view, &second, &fixtureViewDestroy);
    defer second.header.releaseUserLocked(&guard, io) catch @panic("second view release failed");
    // Model existing leases at the ledger limit; rollback must not consume them.
    const extra_leases = std.math.maxInt(u32) - 1;
    second.header.reference_count = std.math.maxInt(u32);
    second.header.reference_escaped = true;
    objects.total_reference_count += extra_leases;
    defer {
        second.header.reference_count = 1;
        objects.total_reference_count -= extra_leases;
    }
    const total_before = objects.total_reference_count;
    const users_before = objects.user_reference_count;
    var fixture: DescriptorFixture = .{};
    var procs = descriptorFixtureProcs();
    var sets = try descriptor.DescriptorSetAllocator.init(
        std.testing.allocator,
        &procs,
        @ptrCast(&fixture),
        @ptrFromInt(1),
        &.{.{ .type = vulkan.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 2 }},
    );
    defer sets.deinit() catch @panic("descriptor fixture teardown failed");
    const bindings = [_]Binding{
        .{ .texture = .{ .binding = 0, .view = &first, .stages = .{ .fragment = true } } },
        .{ .texture = .{ .binding = 1, .view = &second, .stages = .{ .fragment = true } } },
    };
    const schema = [_]vulkan.VkDescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .descriptorCount = 1,
            .stageFlags = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
        },
        .{
            .binding = 1,
            .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .descriptorCount = 1,
            .stageFlags = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
        },
    };
    var no_memory: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&no_memory);
    try std.testing.expectError(error.ReferenceCountOverflow, BindGroup.create(
        allocator.allocator(),
        io,
        &guard,
        .{
            .objects = &objects,
            .descriptor_allocator = &sets,
            .pipeline_layout = @ptrFromInt(2),
            .group_index = 0,
            .group_layout = .{ .handle = sets.set_layout, .bindings = &schema },
            .bindings = &bindings,
            .buffer_limits = .{
                .max_uniform_buffer_range = 65536,
                .max_storage_buffer_range = 131072,
            },
        },
    ));
    try std.testing.expectEqual(@as(u32, 1), first.header.reference_count);
    try std.testing.expectEqual(std.math.maxInt(u32), second.header.reference_count);
    try std.testing.expectEqual(total_before, objects.total_reference_count);
    try std.testing.expectEqual(users_before, objects.user_reference_count);
    try std.testing.expectEqual(@as(u32, 0), fixture.pools_created);
    try std.testing.expectEqual(@as(u32, 0), fixture.updates);
}

test "bind group rejects foreign and failed view or parent headers before reading payload" {
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var objects: core.ObjectList = .{ .mutex = &mutex };
    var guard = core.ObjectGuard.lockUncancelable(io, &objects);
    defer guard.unlock(io);
    var foreign_mutex: std.Io.Mutex = .init;
    var foreign_objects: core.ObjectList = .{ .mutex = &foreign_mutex };
    var foreign_guard = core.ObjectGuard.lockUncancelable(io, &foreign_objects);
    defer foreign_guard.unlock(io);
    var failed: texture_mod.TextureView = undefined;
    initFixtureHeader(&failed.header, &objects, &guard, io, .texture_view, &failed, &fixtureDestroy);
    failed.header.state = .failed;
    failed.header.last_error = error.TextureFormatNotRenderable;
    defer failed.header.releaseUserLocked(&guard, io) catch @panic("failed view release failed");
    var foreign: texture_mod.TextureView = undefined;
    initFixtureHeader(
        &foreign.header,
        &foreign_objects,
        &foreign_guard,
        io,
        .texture_view,
        &foreign,
        &fixtureDestroy,
    );
    defer foreign.header.releaseUserLocked(&foreign_guard, io) catch @panic("foreign view release failed");
    var failed_texture: texture_mod.Texture = undefined;
    initFixtureHeader(
        &failed_texture.header,
        &objects,
        &guard,
        io,
        .texture,
        &failed_texture,
        &fixtureDestroy,
    );
    failed_texture.header.state = .failed;
    failed_texture.header.last_error = error.TextureFormatNotRenderable;
    defer failed_texture.header.releaseUserLocked(&guard, io) catch @panic("failed texture release failed");
    var failed_parent_view: texture_mod.TextureView = undefined;
    failed_parent_view.texture = &failed_texture;
    try failed_texture.header.retainLeaseLocked(&guard);
    initFixtureHeader(
        &failed_parent_view.header,
        &objects,
        &guard,
        io,
        .texture_view,
        &failed_parent_view,
        &fixtureViewDestroy,
    );
    defer failed_parent_view.header.releaseUserLocked(&guard, io) catch @panic("parent view release failed");
    var fixture: DescriptorFixture = .{};
    var procs = descriptorFixtureProcs();
    var sets = try descriptor.DescriptorSetAllocator.init(
        std.testing.allocator,
        &procs,
        @ptrCast(&fixture),
        @ptrFromInt(1),
        &.{.{ .type = vulkan.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1 }},
    );
    defer sets.deinit() catch @panic("descriptor fixture teardown failed");
    const schema = [_]vulkan.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .descriptorCount = 1,
        .stageFlags = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
    }};
    var no_memory: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&no_memory);
    for ([_]*texture_mod.TextureView{ &failed, &foreign, &failed_parent_view }) |view| {
        const bindings = [_]Binding{.{ .texture = .{
            .binding = 0,
            .view = view,
            .stages = .{ .fragment = true },
        } }};
        try std.testing.expectError(
            if (view == &foreign) error.ResourceDeviceMismatch else error.ResourceDestroyed,
            BindGroup.create(allocator.allocator(), io, &guard, .{
                .objects = &objects,
                .descriptor_allocator = &sets,
                .pipeline_layout = @ptrFromInt(2),
                .group_index = 0,
                .group_layout = .{ .handle = sets.set_layout, .bindings = &schema },
                .bindings = &bindings,
                .buffer_limits = .{
                    .max_uniform_buffer_range = 65536,
                    .max_storage_buffer_range = 131072,
                },
            }),
        );
        try std.testing.expectEqual(@as(u32, 1), view.header.reference_count);
    }
    try std.testing.expectEqual(@as(u32, 0), fixture.pools_created);
    try std.testing.expectEqual(@as(u32, 0), fixture.updates);
}

fn initFixtureHeader(
    header: *core.Object,
    objects: *core.ObjectList,
    guard: *const core.ObjectGuard,
    io: std.Io,
    kind: core.Handle.Kind,
    context: *anyopaque,
    destroy_callback: core.DestroyFn,
) void {
    guard.assertOwns(objects);
    header.* = .{
        .kind = kind,
        .state = .alive,
        .reference_count = 1,
        .user_reference_count = 1,
        .last_error = null,
        .label = "",
        .tracking = objects,
        .destroy_callback = destroy_callback,
        .context = context,
    };
    objects.total_reference_count += 1;
    objects.user_reference_count += 1;
    header.attach(guard, io);
}

fn fixtureDestroy(
    _: *anyopaque,
    _: *const core.ObjectGuard,
    _: std.Io,
    _: core.DestroyReason,
) void {}

fn fixtureViewDestroy(
    context: *anyopaque,
    guard: *const core.ObjectGuard,
    io: std.Io,
    _: core.DestroyReason,
) void {
    const view: *texture_mod.TextureView = @ptrCast(@alignCast(context));
    view.texture.header.releaseLeaseLocked(guard, io);
}

const DescriptorFixture = struct {
    pools_created: u32 = 0,
    updates: u32 = 0,
    buffer_range: u64 = 0,
    descriptor_type: u32 = 0,
    image_view: vulkan.VkImageView = null,
    image_sampler: vulkan.VkSampler = null,

    fn fromDevice(target: vulkan.VkDevice) *DescriptorFixture {
        return @ptrCast(@alignCast(target.?));
    }

    fn createPool(
        target: vulkan.VkDevice,
        _: [*c]const vulkan.VkDescriptorPoolCreateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        out: [*c]vulkan.VkDescriptorPool,
    ) callconv(.c) vulkan.VkResult {
        fromDevice(target).pools_created += 1;
        out.* = @ptrFromInt(4);
        return vulkan.VK_SUCCESS;
    }

    fn destroyPool(
        _: vulkan.VkDevice,
        _: vulkan.VkDescriptorPool,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {}

    fn allocateSets(
        _: vulkan.VkDevice,
        info: [*c]const vulkan.VkDescriptorSetAllocateInfo,
        out: [*c]vulkan.VkDescriptorSet,
    ) callconv(.c) vulkan.VkResult {
        for (0..info.*.descriptorSetCount) |index| out[index] = @ptrFromInt(index + 5);
        return vulkan.VK_SUCCESS;
    }

    fn updateSets(
        target: vulkan.VkDevice,
        count: u32,
        writes: [*c]const vulkan.VkWriteDescriptorSet,
        _: u32,
        _: [*c]const vulkan.VkCopyDescriptorSet,
    ) callconv(.c) void {
        std.debug.assert(count == 1);
        const fixture = fromDevice(target);
        if (writes[0].pBufferInfo != null)
            fixture.buffer_range = writes[0].pBufferInfo[0].range;
        if (writes[0].pImageInfo != null) {
            fixture.image_view = writes[0].pImageInfo[0].imageView;
            fixture.image_sampler = writes[0].pImageInfo[0].sampler;
        }
        fixture.descriptor_type = writes[0].descriptorType;
        fixture.updates += 1;
    }
};

fn descriptorFixtureProcs() dispatch.DeviceProcs {
    var procs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.create_descriptor_pool = &DescriptorFixture.createPool;
    procs.destroy_descriptor_pool = &DescriptorFixture.destroyPool;
    procs.allocate_descriptor_sets = &DescriptorFixture.allocateSets;
    procs.update_descriptor_sets = &DescriptorFixture.updateSets;
    return procs;
}

test "private storage binding permissions do not grant public storage usage" {
    var resource = fixtureBuffer();
    const public_storage = (buffer_mod.BufferUsage{ .storage = true }).toFlags();
    const usages = [_]u32{
        0,
        buffer_mod.read_only_storage_buffer,
        buffer_mod.internal_storage_buffer,
        public_storage,
    };
    const kinds = .{ .storage, .read_only_storage, .internal_storage, .internal_read_only_storage };
    inline for (kinds) |kind| {
        for (usages) |usage| {
            resource.internal_usage = usage;
            resource.usage = .{};
            const binding: BufferBinding = .{
                .binding = 0,
                .buffer = &resource,
                .offset = 0,
                .size = 16,
                .kind = kind,
                .stages = .{ .compute = true },
            };
            const allowed = switch (kind) {
                .storage, .read_only_storage => false,
                .internal_storage => usage & (buffer_mod.internal_storage_buffer | public_storage) != 0,
                .internal_read_only_storage => usage != 0,
                else => unreachable,
            };
            if (allowed) {
                try validateBufferUsage(binding);
            } else {
                try std.testing.expectError(error.BindingUsageInvalid, validateBufferUsage(binding));
            }
            try std.testing.expect(!resource.usage.storage);
        }
    }
}

test "private texture binding uses internal permission without changing public usage" {
    var view: texture_mod.TextureView = undefined;
    view.usage = .{};
    view.internal_usage = .{ .texture_binding = true, .storage_binding = true };
    inline for (.{ false, true }) |storage| {
        const binding: @FieldType(Binding, "texture") = .{
            .binding = 0,
            .view = &view,
            .storage = storage,
            .internal = true,
            .stages = .{ .fragment = true },
        };
        try validateTextureUsage(binding);
        var public_binding = binding;
        public_binding.internal = false;
        try std.testing.expectError(error.BindingUsageInvalid, validateTextureUsage(public_binding));
    }
    try std.testing.expect(!view.usage.texture_binding);
    try std.testing.expect(!view.usage.storage_binding);
    view.usage = .{ .texture_binding = true, .storage_binding = true };
    view.internal_usage = .{};
    try std.testing.expectError(error.BindingUsageInvalid, validateTextureUsage(.{
        .binding = 0,
        .view = &view,
        .internal = true,
        .stages = .{ .fragment = true },
    }));
}

test "private depth view binding requires actual sampled depth only" {
    var table: format.FormatTable = undefined;
    format.buildFormatTable(.{}, &table);
    var view: texture_mod.TextureView = undefined;
    view.format_info = &table[format.computeFormatIndex(.depth24_plus_stencil8).?];
    view.aspects = .{ .depth = 1 };
    var binding: @FieldType(Binding, "texture") = .{
        .binding = 0,
        .view = &view,
        .internal = true,
        .depth_view = true,
        .stages = .{ .fragment = true },
    };
    try validateDepthView(binding);
    binding.internal = false;
    try std.testing.expectError(error.BindingUsageInvalid, validateDepthView(binding));
    binding.internal = true;
    binding.storage = true;
    try std.testing.expectError(error.BindingUsageInvalid, validateDepthView(binding));
    binding.storage = false;
    const invalid_aspects = [_]texture_mod.AspectMask{
        .{ .stencil = 1 }, .{ .depth = 1, .stencil = 1 }, .{ .color = 1 },
    };
    for (invalid_aspects) |aspects| {
        view.aspects = aspects;
        try std.testing.expectError(error.BindingTextureAspectInvalid, validateDepthView(binding));
    }
    view.aspects = .{ .depth = 1 };
    view.format_info = &table[format.computeFormatIndex(.rgba8_unorm).?];
    try std.testing.expectError(error.BindingTextureAspectInvalid, validateDepthView(binding));
}

test "expanded external layouts require the actual live canonical layout header" {
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var objects: core.ObjectList = .{ .mutex = &mutex };
    var guard = core.ObjectGuard.lockUncancelable(io, &objects);
    defer guard.unlock(io);
    var header: core.Object = undefined;
    var context: u8 = 0;
    initFixtureHeader(&header, &objects, &guard, io, .pipeline_layout, &context, &fixtureDestroy);
    defer header.releaseUserLocked(&guard, io) catch @panic("layout release failed");
    try std.testing.expectError(
        error.BindingLayoutUnsupported,
        validateExternalLayout(&guard, &objects, null),
    );
    try validateExternalLayout(&guard, &objects, &header);
    var fixture: DescriptorFixture = .{};
    var procs = descriptorFixtureProcs();
    var sets = try descriptor.DescriptorSetAllocator.init(
        std.testing.allocator,
        &procs,
        @ptrCast(&fixture),
        @ptrFromInt(1),
        &.{.{ .type = vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1 }},
    );
    defer sets.deinit() catch @panic("descriptor fixture teardown failed");
    var resource = fixtureBuffer();
    const bindings = [_]Binding{.{ .buffer = .{
        .binding = 0,
        .buffer = &resource,
        .offset = 0,
        .size = 16,
        .kind = .uniform,
        .stages = .{ .fragment = true },
    } }};
    const schema = [_]vulkan.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
    }};
    var options: Options = .{
        .objects = &objects,
        .descriptor_allocator = &sets,
        .pipeline_layout = @ptrFromInt(2),
        .group_index = 0,
        .group_layout = .{
            .handle = sets.set_layout,
            .bindings = &schema,
            .has_external_texture = true,
        },
        .bindings = &bindings,
        .buffer_limits = .{ .max_uniform_buffer_range = 65536, .max_storage_buffer_range = 131072 },
    };
    var no_memory: [0]u8 = .{};
    var no_memory_allocator = std.heap.FixedBufferAllocator.init(&no_memory);
    try std.testing.expectError(
        error.BindingLayoutUnsupported,
        BindGroup.create(no_memory_allocator.allocator(), io, &guard, options),
    );
    try std.testing.expectEqual(@as(u32, 0), fixture.pools_created);
    options.canonical_layout_header = &header;
    const group = try BindGroup.create(std.testing.allocator, io, &guard, options);
    try std.testing.expect(group.group_layout.has_external_texture);
    try group.destroy(std.testing.allocator, io, &guard, 1);
    try sets.finishDeallocation(1);
    header.kind = .sampler;
    try std.testing.expectError(
        error.BindingLayoutUnsupported,
        validateExternalLayout(&guard, &objects, &header),
    );
    header.kind = .pipeline_layout;
    header.state = .failed;
    header.last_error = error.TextureFormatNotRenderable;
    try std.testing.expectError(
        error.ResourceDestroyed,
        validateExternalLayout(&guard, &objects, &header),
    );
    header.state = .alive;
    header.last_error = null;
    var foreign_mutex: std.Io.Mutex = .init;
    var foreign_objects: core.ObjectList = .{ .mutex = &foreign_mutex };
    var foreign_guard = core.ObjectGuard.lockUncancelable(io, &foreign_objects);
    defer foreign_guard.unlock(io);
    var foreign: core.Object = undefined;
    initFixtureHeader(
        &foreign,
        &foreign_objects,
        &foreign_guard,
        io,
        .pipeline_layout,
        &context,
        &fixtureDestroy,
    );
    defer foreign.releaseUserLocked(&foreign_guard, io) catch @panic("foreign layout release failed");
    try std.testing.expectError(
        error.ResourceDeviceMismatch,
        validateExternalLayout(&guard, &objects, &foreign),
    );
}

test "combined descriptor writes the actual view and retains its conversion owner through the view" {
    try combinedDescriptorRoundTrip(std.testing.allocator, .none);
}

test "combined descriptor fail N rolls back view leases and immutable sampler copies" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        combinedDescriptorRoundTrip,
        .{CombinedFixtureFailure.none},
    );
}

test "combined descriptor rejects invalid owner and immutable schema before allocating a set" {
    inline for (@typeInfo(CombinedFixtureFailure).@"enum".field_values) |field_value| {
        const failure: CombinedFixtureFailure = @fromBackingInt(@intCast(field_value));
        if (failure != .none) try combinedDescriptorRoundTrip(std.testing.allocator, failure);
    }
}

const CombinedFixtureFailure = enum {
    none,
    missing_immutable,
    wrong_immutable,
    wrong_descriptor,
    wrong_sampler,
    failed_sampler,
    foreign_sampler,
    missing_conversion,
    unsampled_view,
    ordinary_parent,
    view_reference_overflow,
};

fn combinedDescriptorRoundTrip(
    allocator: std.mem.Allocator,
    failure: CombinedFixtureFailure,
) !void {
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var objects: core.ObjectList = .{ .mutex = &mutex };
    var guard = core.ObjectGuard.lockUncancelable(io, &objects);
    defer guard.unlock(io);
    var fixture: DescriptorFixture = .{};
    var procs = descriptorFixtureProcs();
    var instance_procs = std.mem.zeroes(dispatch.InstanceProcs);
    var handles: @import("vulkan_device.zig").HandleSet = .{};
    var memory_properties = std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties);
    const native_device: vulkan.VkDevice = @ptrCast(&fixture);
    const physical_device: vulkan.VkPhysicalDevice = @ptrFromInt(10);
    const context: buffer_mod.Device = .{
        .allocator = std.testing.allocator,
        .dispatch = .{ .global = null, .instance = &instance_procs, .device = &procs },
        .vk_device = native_device,
        .physical_device = physical_device,
        .memory_properties = &memory_properties,
        .non_coherent_atom_size = 1,
        .max_buffer_size = 65536,
        .handles = &handles,
    };
    var sampler_count: u32 = 1;
    var owner: sampler_mod.Sampler = undefined;
    initFixtureHeader(&owner.header, &objects, &guard, io, .sampler, &owner, &fixtureDestroy);
    defer owner.header.releaseUserLocked(&guard, io) catch @panic("sampler release failed");
    owner.key = try sampler_mod.semanticKey(.{
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .compare = .undefined_,
        .y_cb_cr_vk_descriptor = .{
            .vk_format = @intCast(vulkan.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM),
        },
    });
    owner.native = .{
        .backend = .{
            .procs = &procs,
            .handle = native_device,
            .api_version = vulkan.VK_API_VERSION_1_1,
            .instance_procs = &instance_procs,
            .physical = physical_device,
            .anisotropy_enabled = false,
            .max_anisotropy = 1,
            .y_cb_cr_enabled = true,
            .handles = &handles,
            .sampler_allocation_count = &sampler_count,
            .max_sampler_allocation_count = 16,
        },
        .sampler = @ptrFromInt(11),
        .conversion = @ptrFromInt(12),
    };
    var other_owner: sampler_mod.Sampler = undefined;
    initFixtureHeader(
        &other_owner.header,
        &objects,
        &guard,
        io,
        .sampler,
        &other_owner,
        &fixtureDestroy,
    );
    defer other_owner.header.releaseUserLocked(&guard, io) catch @panic("other sampler release failed");
    var texture: texture_mod.Texture = undefined;
    initFixtureHeader(&texture.header, &objects, &guard, io, .texture, &texture, &fixtureDestroy);
    defer texture.header.releaseUserLocked(&guard, io) catch @panic("texture release failed");
    texture.dimension = ._2d;
    texture.sample_count = 1;
    texture.mip_level_count = 1;
    texture.base_size = .{ .width = 4, .height = 4, .depth_or_array_layers = 1 };
    texture.internal_usage = .{ .texture_binding = true };
    texture.native_y_cb_cr = .{
        .traits = try @import("native_y_cb_cr_format.zig").traitsFor(
            vulkan.VK_FORMAT_G8_B8R8_2PLANE_420_UNORM,
        ),
        .combined_image_sampler_descriptor_count = 2,
        .image_properties = .{
            .maxExtent = .{ .width = 4, .height = 4, .depth = 1 },
            .maxMipLevels = 1,
            .maxArrayLayers = 1,
            .sampleCounts = vulkan.VK_SAMPLE_COUNT_1_BIT,
            .maxResourceSize = 4096,
        },
    };
    texture.format_info = &texture.native_y_cb_cr.?.converted_format_info;
    var ordinary_format_info = texture.native_y_cb_cr.?.converted_format_info;
    // The descriptor seam borrows mock driver handles with genuine frozen conversion metadata.
    var native_texture: @TypeOf(texture.native.?.*) = .{
        .allocator = std.testing.allocator,
        .context = context,
        .procs = &procs,
        .image = @ptrFromInt(13),
        .memory = @ptrFromInt(14),
        .states = &.{},
        .view_count = 1,
    };
    texture.native = &native_texture;
    var view: texture_mod.TextureView = undefined;
    try texture.header.retainLeaseLocked(&guard);
    try owner.header.retainLeaseLocked(&guard);
    initFixtureHeader(
        &view.header,
        &objects,
        &guard,
        io,
        .texture_view,
        &view,
        &fixtureCombinedViewDestroy,
    );
    defer view.header.releaseUserLocked(&guard, io) catch @panic("view release failed");
    view.texture = &texture;
    view.conversion_sampler = &owner;
    view.format_info = texture.format_info;
    view.format = .undefined_;
    view.dimension = ._2d;
    view.aspects = .{ .color = 1 };
    view.range = .{
        .aspects = view.aspects,
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
    view.usage = .{};
    view.internal_usage = .{ .texture_binding = true };
    view.swizzle = texture_mod.identitySwizzle();
    view.native_view = @ptrFromInt(15);
    var sets = try descriptor.DescriptorSetAllocator.init(
        std.testing.allocator,
        &procs,
        native_device,
        @ptrFromInt(1),
        &.{.{ .type = vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 2 }},
    );
    defer sets.deinit() catch @panic("descriptor fixture teardown failed");
    var immutable = [_]vulkan.VkSampler{owner.native.?.sampler};
    var schema = [_]vulkan.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = &immutable,
    }};
    var bindings = [_]Binding{.{ .combined_y_cb_cr_view = .{
        .binding = 0,
        .view = &view,
        .sampler = &owner,
        .stages = .{ .fragment = true },
    } }};
    var foreign_mutex: std.Io.Mutex = .init;
    var foreign_objects: core.ObjectList = .{ .mutex = &foreign_mutex };
    const extra_leases = std.math.maxInt(u32) - 1;
    switch (failure) {
        .none => {},
        .missing_immutable => schema[0].pImmutableSamplers = null,
        .wrong_immutable => immutable[0] = @ptrFromInt(16),
        .wrong_descriptor => schema[0].descriptorType = vulkan.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .wrong_sampler => bindings[0].combined_y_cb_cr_view.sampler = &other_owner,
        .failed_sampler => {
            owner.header.state = .failed;
            owner.header.last_error = error.TextureFormatNotRenderable;
        },
        .foreign_sampler => owner.header.tracking = &foreign_objects,
        .missing_conversion => owner.native.?.conversion = null,
        .unsampled_view => view.internal_usage = .{},
        .ordinary_parent => {
            texture.native_y_cb_cr = null;
            texture.format_info = &ordinary_format_info;
            view.format_info = &ordinary_format_info;
        },
        .view_reference_overflow => {
            view.header.reference_count = std.math.maxInt(u32);
            view.header.reference_escaped = true;
            objects.total_reference_count += extra_leases;
        },
    }
    defer {
        owner.header.tracking = &objects;
        owner.header.state = .alive;
        owner.header.last_error = null;
        if (failure == .view_reference_overflow) {
            view.header.reference_count = 1;
            objects.total_reference_count -= extra_leases;
        }
    }
    const total_before = objects.total_reference_count;
    defer std.debug.assert(objects.total_reference_count == total_before);
    const options: Options = .{
        .objects = &objects,
        .descriptor_allocator = &sets,
        .pipeline_layout = @ptrFromInt(2),
        .group_index = 0,
        .group_layout = .{ .handle = sets.set_layout, .bindings = &schema },
        .bindings = &bindings,
        .buffer_limits = .{ .max_uniform_buffer_range = 65536, .max_storage_buffer_range = 131072 },
    };
    if (failure != .none) {
        const expected_error: Error = switch (failure) {
            .none => unreachable,
            .missing_immutable, .wrong_immutable, .wrong_descriptor => error.BindGroupLayoutInvalid,
            .wrong_sampler, .missing_conversion => error.BindingResourceInvalid,
            .failed_sampler => error.ResourceDestroyed,
            .foreign_sampler => error.ResourceDeviceMismatch,
            .unsampled_view => error.BindingUsageInvalid,
            .ordinary_parent => error.TextureYCbCrSamplerMismatch,
            .view_reference_overflow => error.ReferenceCountOverflow,
        };
        var no_memory: [0]u8 = .{};
        var no_memory_allocator = std.heap.FixedBufferAllocator.init(&no_memory);
        try std.testing.expectError(
            expected_error,
            BindGroup.create(no_memory_allocator.allocator(), io, &guard, options),
        );
        try std.testing.expectEqual(@as(u32, 0), fixture.pools_created);
        try std.testing.expectEqual(@as(u32, 0), fixture.updates);
        return;
    }
    const group = try BindGroup.create(allocator, io, &guard, options);
    try std.testing.expectEqual(@as(u32, 2), view.header.reference_count);
    try std.testing.expectEqual(@as(u32, 2), owner.header.reference_count);
    try std.testing.expectEqual(view.native_view, fixture.image_view);
    try std.testing.expectEqual(owner.native.?.sampler, fixture.image_sampler);
    try std.testing.expectEqual(
        @as(u32, vulkan.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER),
        fixture.descriptor_type,
    );
    try std.testing.expect(group.group_layout.bindings[0].pImmutableSamplers != @as([*c]const vulkan.VkSampler, &immutable));
    try std.testing.expectEqual(
        owner.native.?.sampler,
        group.group_layout.bindings[0].pImmutableSamplers[0],
    );
    try group.validateDynamicOffsets(&guard, &.{});
    try group.destroy(allocator, io, &guard, 1);
    try sets.finishDeallocation(1);
    try std.testing.expectEqual(@as(u32, 1), view.header.reference_count);
    try std.testing.expectEqual(@as(u32, 2), owner.header.reference_count);
}

fn fixtureCombinedViewDestroy(
    context: *anyopaque,
    guard: *const core.ObjectGuard,
    io: std.Io,
    _: core.DestroyReason,
) void {
    const view: *texture_mod.TextureView = @ptrCast(@alignCast(context));
    view.conversion_sampler.?.header.releaseLeaseLocked(guard, io);
    view.texture.header.releaseLeaseLocked(guard, io);
}
