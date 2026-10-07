//! Real native resource factories preserve public permissions and private layout admission.
//! These fixtures create Vulkan resources. They do not dispatch shaders.

const std = @import("std");
const dusk = @import("dusk");
const core = dusk.core;
const engine = dusk.engine;
const native = engine.native_resources;
const buffer = engine.buffer;
const internal = dusk.pipeline.layout_internal;
const t = std.testing;

const Fixture = struct {
    threaded: std.Io.Threaded = undefined,
    instance: engine.Instance = undefined,
    adapters: engine.AdapterList = undefined,
    device: engine.Device = undefined,

    fn init(self: *Fixture) !void {
        try self.initWithLimits(null);
    }

    fn initWithLimits(self: *Fixture, required_limits: ?*const dusk.api.Limits) !void {
        self.* = .{};
        self.threaded = .init(t.allocator, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.instance = engine.Instance.init(.{ .backend_type = .vulkan });
        errdefer self.instance.deinit(t.allocator, io) catch @panic("instance rollback failed");
        self.adapters = try self.instance.enumerateAdapters(t.allocator, io, .{
            .backend_type = .vulkan,
            .feature_level = .core,
            .power_preference = .undefined_,
        });
        errdefer self.adapters.deinit(io) catch @panic("adapter rollback failed");
        if (self.adapters.items.len == 0) return error.NoPhysicalDevice;
        self.device = try self.adapters.items[0].createDevice(t.allocator, io, .{
            .adapter = &self.adapters.items[0],
            .feature_level = .core,
            .required_limits = required_limits,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
    }

    fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
        @panic("native internal resource reported an uncaptured error");
    }

    fn deinit(self: *Fixture) void {
        const io = self.threaded.io();
        self.device.deinit(t.allocator, io) catch @panic("device teardown failed");
        self.adapters.deinit(io) catch @panic("adapter teardown failed");
        self.instance.deinit(t.allocator, io) catch @panic("instance teardown failed");
        self.threaded.deinit();
    }

    fn release(self: *Fixture, resource: anytype) void {
        self.device.release(t.allocator, self.threaded.io(), resource) catch
            @panic("resource release failed");
    }

    fn scratch(self: *Fixture, options: buffer.InternalBufferDescriptor) !*native.Buffer {
        const io = self.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
        defer guard.unlock(io);
        try self.device.bindObjectsLocked(&guard, t.allocator);
        return native.createInternalBufferLocked(
            t.allocator,
            io,
            &guard,
            &self.device.core.arena,
            self.device.native.?.resourceDevice(),
            options,
        );
    }

    fn groupLayout(
        self: *Fixture,
        entries: []const internal.Entry,
        allow_internal_bindings: bool,
    ) !*native.BindGroupLayout {
        const io = self.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
        defer guard.unlock(io);
        try self.device.bindObjectsLocked(&guard, t.allocator);
        return native.createBindGroupLayout(
            t.allocator,
            io,
            &guard,
            &self.device.core.arena,
            self.device.native.?.resourceDevice(),
            .{
                .descriptor = .{ .entries = entries },
                .allow_internal_bindings = allow_internal_bindings,
                .validation = .{
                    .max_storage_buffers_in_vertex_stage = self.device.limits.compatibility.?.max_storage_buffers_in_vertex_stage,
                    .max_storage_buffers_in_fragment_stage = self.device.limits.compatibility.?.max_storage_buffers_in_fragment_stage,
                    // The high admission flag must override this lower-level request.
                    .allow_internal_bindings = true,
                },
            },
        );
    }

    fn privateLayout(
        self: *Fixture,
        options: native.PipelineLayoutOptions,
        max_push_constants_size: u32,
    ) !*native.PipelineLayout {
        const io = self.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
        defer guard.unlock(io);
        try self.device.bindObjectsLocked(&guard, t.allocator);
        return native.createInternalPipelineLayout(
            t.allocator,
            io,
            &guard,
            &self.device.core.arena,
            self.device.native.?.resourceDevice(),
            options,
            max_push_constants_size,
        );
    }
};

fn entry(kind: internal.BufferBindingType) internal.Entry {
    return .{
        .binding_number = 0,
        .visibility = .{ .compute = true },
        .kind = .{ .buffer = .{
            .binding_type = kind,
            .has_dynamic_offset = false,
            .min_binding_size = 16,
        } },
    };
}

fn createGroup(
    fixture: *Fixture,
    layout: *native.PipelineLayout,
    resource: *native.Buffer,
    comptime kind: internal.BufferBindingType,
) !*native.BindGroup {
    return fixture.device.createBindGroup(t.allocator, fixture.threaded.io(), .{
        .layout = layout,
        .group_index = 0,
        .bindings = &.{.{ .buffer = .{
            .binding = 0,
            .buffer = resource,
            .offset = 0,
            .size = 16,
            .kind = switch (kind) {
                .uniform => .uniform,
                .storage => .storage,
                .read_only_storage => .read_only_storage,
                .internal_storage => .internal_storage,
                .internal_read_only_storage => .internal_read_only_storage,
            },
            .stages = .{ .compute = true },
        } }},
    });
}

test "native internal buffer factory returns an unmapped original-arena creator alias" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const usage = buffer.internal_storage_buffer | buffer.read_only_storage_buffer;
    const scratch = try f.scratch(.{ .size = 64, .native_usage = usage });
    var owned = true;
    defer if (owned) f.release(scratch);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expect(scratch.header.tracking == f.device.core.arena.objectList());
        try t.expectEqual(core.Handle.Kind.native_buffer, scratch.header.kind);
        try t.expect(scratch.header.node.linked);
        try t.expect(scratch.header.isAlive(&guard));
        try t.expectEqual(@as(u32, 1), scratch.header.reference_count);
        try t.expectEqual(@as(u32, 1), scratch.header.user_reference_count);
        try t.expect(scratch.device.procs == f.device.native.?.native_device.procs);
        try t.expect(scratch.native.device.vk_device == f.device.native.?.native_device.vk_device);
        try t.expect(scratch.native.handle != null);
        try t.expect(scratch.native.allocation.memory != null);
        try t.expectEqual(@as(u64, 64), scratch.native.size);
        try t.expectEqual(usage, scratch.native.internal_usage);
        try t.expect(!scratch.native.usage.storage);
        try t.expectEqual(buffer.State.unmapped, scratch.native.state);
        try t.expect(!scratch.native.is_mapped_at_creation);
        try t.expectEqual(buffer.MapMode.none, scratch.native.map_mode);
        try t.expectEqual(@as(u32, 0), scratch.mapping_leases);
        try t.expectEqual(@as(u32, 0), scratch.queue_uses);
        try t.expectEqual(@as(buffer.Serial, 0), scratch.accepted_usage_serial);
    }
    f.release(scratch);
    owned = false;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expect(!scratch.header.isAlive(&guard));
        try t.expect(!scratch.header.node.linked);
        try t.expectEqual(@as(u32, 0), scratch.header.reference_count);
        try t.expectEqual(@as(u32, 0), scratch.header.user_reference_count);
        try t.expect(scratch.cleanup_error == null);
        try t.expect(!scratch.native_retirement_pending);
    }
}

test "native private storage layouts require high admission and retain logical identities" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    inline for (.{
        .{ internal.BufferBindingType.storage, internal.BufferBindingType.internal_storage },
        .{
            internal.BufferBindingType.read_only_storage,
            internal.BufferBindingType.internal_read_only_storage,
        },
    }) |kinds| {
        const public_entries = [_]internal.Entry{entry(kinds[0])};
        const private_entries = [_]internal.Entry{entry(kinds[1])};
        try t.expectError(error.BindingLayoutUnsupported, f.groupLayout(&private_entries, false));
        const public = try f.device.createBindGroupLayout(t.allocator, io, .{
            .entries = &public_entries,
        });
        defer f.release(public);
        const private = try f.groupLayout(&private_entries, true);
        defer f.release(private);
        const alias = try f.groupLayout(&private_entries, true);
        defer f.release(alias);
        try t.expect(private == alias);
        try t.expect(public != private);
        // A private cache hit cannot bypass admission on a later public request.
        try t.expectError(error.BindingLayoutUnsupported, f.groupLayout(&private_entries, false));
        try t.expectError(error.BindingLayoutUnsupported, f.device.createBindGroupLayout(t.allocator, io, .{ .entries = &private_entries }));
        const public_pipeline = try f.device.createPipelineLayout(t.allocator, io, .{
            .groups = &.{public},
        });
        defer f.release(public_pipeline);
        const private_pipeline = try f.privateLayout(.{ .groups = &.{private} }, f.device.native.?.native_device.physical.properties.limits.maxPushConstantsSize);
        defer f.release(private_pipeline);
        try t.expect(public_pipeline != private_pipeline);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            try t.expect(public.native.handle != null);
            try t.expect(private.native.handle != null);
            const public_index = public.internal.api_binding_map.get(0).?;
            const private_index = private.internal.api_binding_map.get(0).?;
            try t.expectEqual(kinds[0], public.internal.binding(public_index).layout.buffer.binding_type);
            try t.expectEqual(kinds[1], private.internal.binding(private_index).layout.buffer.binding_type);
            try t.expect(private_pipeline.groups[0] == private);
        }
    }
}

test "native public storage rejects Indirect-only buffers while private scratch binds" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const indirect = try f.device.createBuffer(t.allocator, io, .{
        .size = 16,
        .usage = .{ .indirect = true },
    });
    defer f.release(indirect);
    inline for (.{
        .{ internal.BufferBindingType.storage, internal.BufferBindingType.internal_storage },
        .{
            internal.BufferBindingType.read_only_storage,
            internal.BufferBindingType.internal_read_only_storage,
        },
    }) |kinds| {
        const public_entries = [_]internal.Entry{entry(kinds[0])};
        const public_group = try f.device.createBindGroupLayout(t.allocator, io, .{
            .entries = &public_entries,
        });
        defer f.release(public_group);
        const public_layout = try f.device.createPipelineLayout(t.allocator, io, .{
            .groups = &.{public_group},
        });
        defer f.release(public_layout);
        try t.expectError(error.BindingUsageInvalid, createGroup(&f, public_layout, indirect, kinds[0]));
        const private_entries = [_]internal.Entry{entry(kinds[1])};
        const private_group = try f.groupLayout(&private_entries, true);
        defer f.release(private_group);
        const private_layout = try f.privateLayout(.{ .groups = &.{private_group} }, f.device.native.?.native_device.physical.properties.limits.maxPushConstantsSize);
        defer f.release(private_layout);
        const native_usage = if (kinds[1] == .internal_storage)
            buffer.internal_storage_buffer
        else
            buffer.read_only_storage_buffer;
        const scratch = try f.scratch(.{ .size = 16, .native_usage = native_usage });
        var scratch_owned = true;
        defer if (scratch_owned) f.release(scratch);
        try t.expectError(error.BindingUsageInvalid, createGroup(&f, public_layout, scratch, kinds[0]));
        try t.expectError(error.BindGroupLayoutInvalid, createGroup(&f, public_layout, scratch, kinds[1]));
        try t.expectError(error.BindGroupLayoutInvalid, createGroup(&f, private_layout, scratch, kinds[0]));
        const bound = try createGroup(&f, private_layout, scratch, kinds[1]);
        var bound_owned = true;
        defer if (bound_owned) f.release(bound);
        f.release(scratch);
        scratch_owned = false;
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            try t.expect(!indirect.native.usage.storage);
            try t.expect(indirect.native.internal_usage & buffer.read_only_storage_buffer != 0);
            try t.expect(!scratch.native.usage.storage);
            try t.expectEqual(@as(u32, 0), scratch.header.user_reference_count);
            try t.expect(scratch.header.isAlive(&guard));
            try t.expect(bound.native.descriptor_allocation.set != null);
            try t.expect(bound.layout == private_layout);
            try t.expect(bound.buffers[0] == scratch);
        }
        f.release(bound);
        bound_owned = false;
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            try t.expect(!scratch.header.isAlive(&guard));
            try t.expectEqual(@as(u32, 0), scratch.header.reference_count);
            try t.expect(scratch.cleanup_error == null);
            try t.expect(bound.cleanup_error == null);
        }
    }
}

test "native internal pipeline layouts admit only zero or eight physical push constant bytes" {
    var f: Fixture = undefined;
    // Negotiate zero public immediate bytes without changing the device's physical offer.
    const required_limits: dusk.api.Limits = .{ .max_immediate_size = 0 };
    try f.initWithLimits(&required_limits);
    defer f.deinit();
    const io = f.threaded.io();
    const physical_cap = f.device.native.?.native_device.physical.properties.limits.maxPushConstantsSize;
    try t.expect(physical_cap >= 8);
    try t.expectEqual(@as(u32, 0), f.device.limits.v1.max_immediate_size);
    try t.expectError(error.ImmediateSizeInvalid, f.device.createPipelineLayout(t.allocator, io, .{
        .groups = &.{},
        .immediate_size = 8,
    }));
    const zero = try f.privateLayout(.{ .groups = &.{}, .immediate_size = 0 }, physical_cap);
    defer f.release(zero);
    // Zero is a supplied test cap, not this device's physical maxPushConstantsSize.
    const zero_cap = try f.privateLayout(.{ .groups = &.{}, .immediate_size = 0 }, 0);
    defer f.release(zero_cap);
    try t.expect(zero == zero_cap);
    const eight = try f.privateLayout(.{ .groups = &.{}, .immediate_size = 8 }, physical_cap);
    defer f.release(eight);
    const eight_alias = try f.privateLayout(.{ .groups = &.{}, .immediate_size = 8 }, physical_cap);
    defer f.release(eight_alias);
    try t.expect(eight == eight_alias);
    try t.expect(zero != eight);
    inline for (.{ @as(u32, 4), @as(u32, 12) }) |size| {
        try t.expectError(error.ImmediateSizeInvalid, f.privateLayout(.{ .groups = &.{}, .immediate_size = size }, physical_cap));
    }
    // Four is a supplied test cap. A live cache entry cannot override that admission input.
    try t.expectError(error.ImmediateSizeInvalid, f.privateLayout(.{ .groups = &.{}, .immediate_size = 8 }, 4));
    try t.expectError(error.ImmediateSizeInvalid, f.device.createPipelineLayout(t.allocator, io, .{
        .groups = &.{},
        .immediate_size = 8,
    }));
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        const zero_input = try zero.input(&guard);
        const eight_input = try eight.input(&guard);
        try t.expect(zero_input.handle != null);
        try t.expect(eight_input.handle != null);
        try t.expectEqual(@as(u32, 0), zero_input.immediate_size);
        try t.expectEqual(@as(u32, 8), eight_input.immediate_size);
        try t.expect(eight_input.canonical_layout_header.? == &eight.header);
        try t.expectEqual(@as(u32, 0), f.device.limits.v1.max_immediate_size);
    }
}

fn externalQueryEntries() [4]internal.Entry {
    return .{
        .{
            .binding_number = 999,
            .visibility = .{ .compute = true },
            .kind = .{ .external_texture = true },
        },
        .{
            .binding_number = 503,
            .visibility = .{ .compute = true },
            .kind = .{ .buffer = .{
                .binding_type = .storage,
                .has_dynamic_offset = false,
                .min_binding_size = 16,
            } },
        },
        .{
            .binding_number = 7,
            .visibility = .{ .compute = true },
            .kind = .{ .external_texture = true },
        },
        .{
            .binding_number = 101,
            .visibility = .{ .compute = true },
            .kind = .{ .sampler = .{ .binding_type = .filtering } },
        },
    };
}

fn expectStoredExternalQuery(
    group: *native.BindGroupLayout,
    guard: *const core.ObjectGuard,
    binding_number: u32,
    expected: internal.ExternalBindingNumbers,
) !void {
    const queried = try group.queryExternalBindingNumbers(guard, binding_number);
    try t.expectEqualDeep(expected, queried);
    try t.expectEqualDeep(expected, group.internal.queryExternalBindingNumbers(binding_number).?);
    const logical_index = group.internal.api_binding_map.get(binding_number).?;
    const logical = group.internal.binding(logical_index);
    try t.expectEqual(binding_number, logical.binding_number);
    try t.expect(logical.isUserFacing());
    try t.expect(logical.layout == .external_texture);
    const stored = logical.layout.external_texture;
    const plane0 = group.internal.binding(stored.plane0);
    const plane1 = group.internal.binding(stored.plane1);
    const metadata = group.internal.binding(stored.metadata);
    try t.expectEqual(queried.plane0, plane0.binding_number);
    try t.expectEqual(queried.plane1, plane1.binding_number);
    try t.expectEqual(queried.metadata, metadata.binding_number);
    try t.expect(plane0.layout == .sampled_texture);
    try t.expect(plane1.layout == .sampled_texture);
    try t.expect(metadata.layout == .buffer);
    try t.expectEqual(internal.BufferBindingType.uniform, metadata.layout.buffer.binding_type);
    try t.expect(stored.static_sampler == null);
    try t.expect(queried.static_sampler == null);
    try t.expect(!plane0.isUserFacing());
    try t.expect(!plane1.isUserFacing());
    try t.expect(!metadata.isUserFacing());
}

test "native external queries preserve canonical aliases and bounded sparse binding identities" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const entries = externalQueryEntries();
    const reordered = [_]internal.Entry{ entries[3], entries[2], entries[1], entries[0] };
    const group = try f.groupLayout(&entries, false);
    var group_owned = true;
    defer if (group_owned) f.release(group);
    const alias = try f.groupLayout(&reordered, false);
    var alias_owned = true;
    defer if (alias_owned) f.release(alias);
    try t.expect(group == alias);
    const first: internal.ExternalBindingNumbers = .{
        .plane0 = 1028,
        .plane1 = 1029,
        .metadata = 1030,
        .static_sampler = null,
    };
    const last: internal.ExternalBindingNumbers = .{
        .plane0 = 4996,
        .plane1 = 4997,
        .metadata = 4998,
        .static_sampler = null,
    };
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expect(group.header.tracking == f.device.core.arena.objectList());
        try t.expectEqual(core.Handle.Kind.bind_group_layout, group.header.kind);
        try t.expect(group.header.node.linked);
        try t.expect(group.header.isAlive(&guard));
        try t.expectEqual(@as(u32, 2), group.header.reference_count);
        try t.expectEqual(@as(u32, 2), group.header.user_reference_count);
        try t.expect(group.native.handle != null);
        try t.expect(group.native.has_external_texture);
        try t.expect(group.device.handle == f.device.native.?.native_device.vk_device);
        try t.expectEqual(group.internal.content_hash, alias.internal.content_hash);
        try t.expectEqual(group.cache_hash, alias.cache_hash);
        try expectStoredExternalQuery(group, &guard, 7, first);
        try expectStoredExternalQuery(group, &guard, 999, last);
        try expectStoredExternalQuery(alias, &guard, 7, first);
        try expectStoredExternalQuery(alias, &guard, 999, last);
        const native_numbers = [_]u32{ 101, 503, 1028, 1029, 1030, 4996, 4997, 4998 };
        try t.expectEqual(native_numbers.len, group.native.bindings.len);
        for (group.native.bindings, native_numbers) |binding, expected_number| {
            try t.expectEqual(expected_number, binding.binding);
            try t.expectEqual(@as(u32, 1), binding.descriptorCount);
            if (binding.binding >= internal.max_bindings_per_bind_group) {
                try t.expect(binding.binding <= 4999);
            } else {
                const public_index = group.internal.api_binding_map.get(binding.binding).?;
                const public = group.internal.binding(public_index);
                try t.expect(public.isUserFacing());
                try t.expectEqual(binding.binding, public.binding_number);
                if (binding.binding == 101) {
                    try t.expect(public.layout == .sampler);
                } else {
                    try t.expectEqual(@as(u32, 503), binding.binding);
                    try t.expect(public.layout == .buffer);
                    try t.expectEqual(
                        internal.BufferBindingType.storage,
                        public.layout.buffer.binding_type,
                    );
                }
            }
        }
    }
    f.release(group);
    group_owned = false;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expect(alias.header.isAlive(&guard));
        try t.expectEqual(@as(u32, 1), alias.header.reference_count);
        try t.expectEqual(@as(u32, 1), alias.header.user_reference_count);
        try expectStoredExternalQuery(alias, &guard, 7, first);
        try expectStoredExternalQuery(alias, &guard, 999, last);
    }
    f.release(alias);
    alias_owned = false;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expect(!group.header.isAlive(&guard));
        try t.expect(!group.header.node.linked);
        try t.expectEqual(@as(u32, 0), group.header.reference_count);
        try t.expectEqual(@as(u32, 0), group.header.user_reference_count);
        try t.expect(group.cleanup_error == null);
        try t.expectError(error.ResourceDestroyed, group.queryExternalBindingNumbers(&guard, 7));
        try t.expectError(error.ResourceDestroyed, alias.queryExternalBindingNumbers(&guard, 999));
        try t.expectError(
            error.ResourceDestroyed,
            group.queryExternalBindingNumbers(&guard, internal.max_bindings_per_bind_group),
        );
    }
}

test "native external queries reject missing ordinary out-of-domain and foreign-arena inputs" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var foreign: Fixture = undefined;
    try foreign.init();
    defer foreign.deinit();
    const entries = externalQueryEntries();
    const group = try f.groupLayout(&entries, false);
    defer f.release(group);
    const io = f.threaded.io();
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expectError(error.BindingResourceInvalid, group.queryExternalBindingNumbers(&guard, 8));
        try t.expectError(error.BindingResourceInvalid, group.queryExternalBindingNumbers(&guard, 101));
        try t.expectError(error.BindingResourceInvalid, group.queryExternalBindingNumbers(&guard, 503));
        inline for (.{
            internal.max_bindings_per_bind_group,
            @as(u32, 1028),
            @as(u32, 4996),
            std.math.maxInt(u32),
        }) |binding_number| {
            try t.expectError(
                error.BindingNumberAboveLimit,
                group.queryExternalBindingNumbers(&guard, binding_number),
            );
        }
    }
    {
        const foreign_io = foreign.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(
            foreign_io,
            foreign.device.core.arena.objectList(),
        );
        defer guard.unlock(foreign_io);
        try t.expect(group.header.tracking != guard.objects);
        inline for (.{ @as(u32, 7), @as(u32, 8), internal.max_bindings_per_bind_group }) |number| {
            try t.expectError(
                error.ResourceDeviceMismatch,
                group.queryExternalBindingNumbers(&guard, number),
            );
        }
    }
}
