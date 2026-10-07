//! Real Vulkan factory aliases, weak retirement, rollback, and cached compute execution.
const std = @import("std");
const dusk = @import("dusk");
const core = dusk.core;
const engine = dusk.engine;
const native = engine.native_resources;
const internal = dusk.pipeline.layout_internal;
const shader_fixture = @import("fixtures/specialization_compute.zig");
const t = std.testing;

const Fixture = struct {
    threaded: std.Io.Threaded = undefined,
    instance: engine.Instance = undefined,
    adapters: engine.AdapterList = undefined,
    device: engine.Device = undefined,
    allocator: std.mem.Allocator = t.allocator,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.* = .{ .allocator = allocator };
        self.threaded = .init(t.allocator, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.instance = engine.Instance.init(.{ .backend_type = .vulkan });
        errdefer self.instance.deinit(allocator, io) catch @panic("instance rollback failed");
        self.adapters = try self.instance.enumerateAdapters(allocator, io, .{
            .backend_type = .vulkan,
            .feature_level = .core,
            .power_preference = .undefined_,
        });
        errdefer self.adapters.deinit(io) catch @panic("adapter rollback failed");
        if (self.adapters.items.len == 0) return error.NoPhysicalDevice;
        const adapter = suitable: {
            for (self.adapters.items) |*candidate| {
                if (candidate.limits.v1.max_immediate_size >= 4) break :suitable candidate;
            }
            return error.NativeImmediateLimitRequired;
        };
        const required: dusk.api.Limits = .{ .max_immediate_size = 4 };
        self.device = try adapter.createDevice(allocator, io, .{
            .adapter = adapter,
            .feature_level = .core,
            .required_limits = &required,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
    }

    fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
        @panic("native resource cache reported an uncaptured error");
    }

    fn deinit(self: *Fixture) void {
        const io = self.threaded.io();
        self.device.deinit(self.allocator, io) catch @panic("device teardown failed");
        self.adapters.deinit(io) catch @panic("adapter teardown failed");
        self.instance.deinit(self.allocator, io) catch @panic("instance teardown failed");
        self.threaded.deinit();
    }

    fn release(self: *Fixture, resource: anytype) void {
        self.device.release(self.allocator, self.threaded.io(), resource) catch
            @panic("resource release failed");
    }

    fn tokenGroup(self: *Fixture, token: u64) !*native.BindGroupLayout {
        const io = self.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.core.arena.objectList());
        defer guard.unlock(io);
        try self.device.bindObjectsLocked(&guard, self.allocator);
        return native.createBindGroupLayout(
            self.allocator,
            io,
            &guard,
            &self.device.core.arena,
            self.device.native.?.resourceDevice(),
            .{
                .descriptor = .{ .entries = &storage_entries },
                .validation = .{
                    .max_storage_buffers_in_vertex_stage = self.device.limits.compatibility.?.max_storage_buffers_in_vertex_stage,
                    .max_storage_buffers_in_fragment_stage = self.device.limits.compatibility.?.max_storage_buffers_in_fragment_stage,
                },
                .compatibility_token = token,
            },
        );
    }
};

const storage_entries = [_]internal.Entry{.{
    .binding_number = 0,
    .visibility = .{ .compute = true },
    .kind = .{ .buffer = .{
        .binding_type = .storage,
        .has_dynamic_offset = false,
        .min_binding_size = 4,
    } },
}};

// Each returned pointer owns an independent user alias, including a cache hit.
test "native BGL aliases normalize entry order and preserve binding semantics" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    var entries = [_]internal.Entry{ storage_entries[0], storage_entries[0] };
    entries[1].binding_number = 3;
    const original = try f.device.createBindGroupLayout(f.allocator, io, .{
        .entries = &entries,
        .label = "original",
    });
    defer f.release(original);
    const reversed = [_]internal.Entry{ entries[1], entries[0] };
    const alias = try f.device.createBindGroupLayout(f.allocator, io, .{
        .entries = &reversed,
        .label = "different label",
    });
    defer f.release(alias);
    try t.expect(original == alias);
    const changes = enum { binding, visibility, kind, dynamic, minimum, count };
    inline for (std.meta.tags(changes)) |change| {
        var changed = entries;
        switch (change) {
            .binding => changed[1].binding_number = 4,
            .visibility => changed[1].visibility = .{ .fragment = true },
            .kind => changed[1].kind.buffer.?.binding_type = .read_only_storage,
            .dynamic => changed[1].kind.buffer.?.has_dynamic_offset = true,
            .minimum => changed[1].kind.buffer.?.min_binding_size = 8,
            .count => {},
        }
        const distinct = try f.device.createBindGroupLayout(f.allocator, io, .{
            .entries = if (change == .count) changed[0..1] else &changed,
        });
        defer f.release(distinct);
        try t.expect(original != distinct);
        const consumer = try f.device.createPipelineLayout(f.allocator, io, .{
            .groups = &.{distinct},
        });
        defer f.release(consumer);
        try t.expect(consumer.groups[0] == distinct);
    }
    var normalized = reversed;
    normalized[0].array_size = 0;
    normalized[1].array_size = 0;
    const zero_array = try f.device.createBindGroupLayout(f.allocator, io, .{
        .entries = &normalized,
    });
    defer f.release(zero_array);
    try t.expect(original == zero_array);
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
    defer guard.unlock(io);
    try t.expect(original.header.isAlive(&guard));
    try t.expectEqual(@as(u32, 3), original.header.user_reference_count);
    try t.expect(original.native.handle != null);
}

test "native layouts preserve explicit zero and nonzero compatibility domains" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const explicit = try f.device.createBindGroupLayout(f.allocator, io, .{
        .entries = &storage_entries,
    });
    defer f.release(explicit);
    const zero = try f.tokenGroup(0);
    defer f.release(zero);
    const eleven = try f.tokenGroup(11);
    defer f.release(eleven);
    const eleven_alias = try f.tokenGroup(11);
    defer f.release(eleven_alias);
    const twelve = try f.tokenGroup(12);
    defer f.release(twelve);
    try t.expect(explicit == zero);
    try t.expect(eleven == eleven_alias);
    try t.expect(eleven != explicit);
    try t.expect(twelve != eleven);
    const ordinary = try f.device.createPipelineLayout(f.allocator, io, .{ .groups = &.{zero} });
    defer f.release(ordinary);
    const automatic = try f.device.createPipelineLayout(f.allocator, io, .{
        .groups = &.{eleven},
        .compatibility_token = 11,
    });
    defer f.release(automatic);
    const other = try f.device.createPipelineLayout(f.allocator, io, .{
        .groups = &.{twelve},
        .compatibility_token = 12,
    });
    defer f.release(other);
    try t.expect(ordinary != automatic);
    try t.expect(other != automatic);
    try t.expectError(error.PipelineCompatibilityTokenMismatch, f.device.createPipelineLayout(f.allocator, io, .{
        .groups = &.{eleven},
        .compatibility_token = 12,
    }));
}

test "native PL aliases distinguish group order trailing empty groups and immediates" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const storage = try f.device.createBindGroupLayout(f.allocator, io, .{
        .entries = &storage_entries,
    });
    defer f.release(storage);
    const empty = try f.device.createBindGroupLayout(f.allocator, io, .{ .entries = &.{} });
    defer f.release(empty);
    const first = try f.device.createPipelineLayout(f.allocator, io, .{
        .label = "first",
        .groups = &.{ storage, empty },
    });
    defer f.release(first);
    const alias = try f.device.createPipelineLayout(f.allocator, io, .{
        .label = "alias",
        .groups = &.{ storage, empty },
        .compatibility_token = 0,
    });
    defer f.release(alias);
    const reversed = try f.device.createPipelineLayout(f.allocator, io, .{
        .groups = &.{ empty, storage },
    });
    defer f.release(reversed);
    const trimmed = try f.device.createPipelineLayout(f.allocator, io, .{
        .groups = &.{storage},
    });
    defer f.release(trimmed);
    const immediate = try f.device.createPipelineLayout(f.allocator, io, .{
        .groups = &.{ storage, empty },
        .immediate_size = 4,
    });
    defer f.release(immediate);
    try t.expect(first == alias);
    try t.expect(first != reversed);
    try t.expect(first != trimmed);
    try t.expect(first != immediate);
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
    defer guard.unlock(io);
    const input = try alias.input(&guard);
    try t.expect(input.canonical_layout_header.? == &first.header);
    try t.expectEqual(@as(usize, 2), input.groups.len);
    try t.expect(alias.groups[0] == storage);
    try t.expect(reversed.groups[0] == empty);
}

test "native shader aliases compare unchanged words and ignore labels" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const first = try f.device.createShaderModule(f.allocator, io, .{
        .words = &shader_fixture.words,
        .label = "first",
    });
    defer f.release(first);
    var copied = shader_fixture.words;
    const alias = try f.device.createShaderModule(f.allocator, io, .{
        .words = &copied,
        .label = "other label",
    });
    defer f.release(alias);
    const changed = try f.device.createShaderModule(f.allocator, io, .{
        .words = &shader_fixture.shared_id_words,
    });
    defer f.release(changed);
    try t.expect(first == alias);
    try t.expect(first != changed);
    @memset(&copied, 0);
    try t.expectEqualSlices(u32, &shader_fixture.words, alias.words);
    try t.expectEqualSlices(u32, &shader_fixture.shared_id_words, changed.words);
    try t.expect(alias.native.findEntryPoint("main") != null);
}

const Kind = enum { group_layout, pipeline_layout, shader };

fn Resource(comptime kind: Kind) type {
    return switch (kind) {
        .group_layout => native.BindGroupLayout,
        .pipeline_layout => native.PipelineLayout,
        .shader => native.ShaderModule,
    };
}

fn create(comptime kind: Kind, f: *Fixture, allocator: std.mem.Allocator) !*Resource(kind) {
    const io = f.threaded.io();
    return switch (kind) {
        .group_layout => f.device.createBindGroupLayout(allocator, io, .{
            .entries = &storage_entries,
        }),
        .pipeline_layout => f.device.createPipelineLayout(allocator, io, .{
            .groups = &.{},
            .immediate_size = 4,
        }),
        .shader => f.device.createShaderModule(allocator, io, .{
            .words = &shader_fixture.words,
        }),
    };
}

fn expectUsable(comptime kind: Kind, f: *Fixture, resource: *Resource(kind)) !void {
    const io = f.threaded.io();
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
    defer guard.unlock(io);
    try t.expect(resource.header.isAlive(&guard));
    switch (kind) {
        .group_layout => try t.expect(resource.native.handle != null),
        .pipeline_layout => {
            const input = try resource.input(&guard);
            try t.expect(input.handle != null);
            try t.expect(input.canonical_layout_header.? == &resource.header);
        },
        .shader => {
            try t.expectEqualSlices(u32, &shader_fixture.words, resource.words);
            try t.expect(resource.native.findEntryPoint("main") != null);
        },
    }
}

test "native factory hits acquire aliases from alive lease-only cache members" {
    inline for (comptime std.meta.tags(Kind)) |kind| {
        var f: Fixture = undefined;
        try f.init(t.allocator);
        defer f.deinit();
        const io = f.threaded.io();
        const first = try create(kind, &f, f.allocator);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            try first.header.retainLeaseLocked(&guard);
        }
        defer {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            first.header.releaseLeaseLocked(&guard, io);
        }
        try f.device.release(f.allocator, io, first);
        const alias = try create(kind, &f, f.allocator);
        defer f.release(alias);
        try t.expect(first == alias);
        try expectUsable(kind, &f, alias);
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        try t.expectEqual(@as(u32, 1), alias.header.user_reference_count);
        try t.expectEqual(@as(u32, 2), alias.header.reference_count);
    }
}

test "native weak members prune on last release and explicit payload destruction" {
    inline for (comptime std.meta.tags(Kind)) |kind| {
        var f: Fixture = undefined;
        try f.init(t.allocator);
        defer f.deinit();
        const io = f.threaded.io();
        const retired = try create(kind, &f, f.allocator);
        try f.device.release(f.allocator, io, retired);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            try t.expectEqual(core.ObjectState.destroyed, retired.header.state);
            try t.expect(retired.header.remove_from_cache == null);
        }
        const rebuilt = try create(kind, &f, f.allocator);
        defer f.release(rebuilt);
        const old_alias = try create(kind, &f, f.allocator);
        defer f.release(old_alias);
        try t.expect(rebuilt != retired);
        try t.expect(old_alias == rebuilt);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            rebuilt.header.retirePayloadLocked(&guard, io, .early_destroy);
            try t.expect(rebuilt.header.remove_from_cache == null);
        }
        const fresh = try create(kind, &f, f.allocator);
        defer f.release(fresh);
        try t.expect(fresh != rebuilt);
        try expectUsable(kind, &f, fresh);
    }
}

test "native factory allocator mismatch and alias count overflow preserve live members" {
    inline for (comptime std.meta.tags(Kind)) |kind| {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        var f: Fixture = undefined;
        try f.init(failing.allocator());
        defer f.deinit();
        const io = f.threaded.io();
        const first = try create(kind, &f, f.allocator);
        defer f.release(first);
        try t.expectError(error.AllocatorMismatch, create(kind, &f, t.allocator));
        const saved = first.header.reference_count;
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            first.header.reference_count = std.math.maxInt(u32);
            guard.objects.total_reference_count += std.math.maxInt(u32) - saved;
        }
        defer {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            guard.objects.total_reference_count -= std.math.maxInt(u32) - saved;
            first.header.reference_count = saved;
        }
        try t.expectError(error.ReferenceCountOverflow, create(kind, &f, f.allocator));
        try expectUsable(kind, &f, first);
    }
}

test "native automatic layout token exhaustion is finite and leaves explicit layout usable" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const module = try create(.shader, &f, f.allocator);
    defer f.release(module);
    var exported: dusk.api.ShaderModule = undefined;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        exported = engine.native_async_handles.exportResource(
            dusk.api.ShaderModule,
            &f.device,
            &guard,
            module,
            .shader_module,
        );
        f.device.native.?.resource_store.?.compatibility_tokens.next_token = std.math.maxInt(u64);
    }
    const descriptor: dusk.api.descriptors.ComputePipelineDescriptorChain = .{
        .compute = .{ .module = exported, .entry_point = "main" },
    };
    var prepared = try engine.native_async_descriptors.OwnedCompute.prepare(
        f.allocator,
        io,
        &f.device,
        &descriptor,
    );
    defer prepared.deinit(io);
    try t.expectError(error.TokenCounterExhausted, prepared.options(f.allocator, io, &f.device));
    const explicit = try f.device.createBindGroupLayout(f.allocator, io, .{
        .entries = &storage_entries,
    });
    defer f.release(explicit);
    const layout = try f.device.createPipelineLayout(f.allocator, io, .{ .groups = &.{explicit} });
    defer f.release(layout);
    const compute = try f.device.createComputePipeline(f.allocator, io, .{
        .layout = layout,
        .compute = .{ .module = module, .entry_point = "main", .stage = .compute },
    });
    defer f.release(compute);
    try t.expect(compute.layout == layout);
}

fn Race(comptime kind: Kind) type {
    return struct {
        fixture: *Fixture,
        entered: std.Io.Event = .unset,
        result: ?*Resource(kind) = null,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            const io = self.fixture.threaded.io();
            self.fixture.device.acquireOperation(io) catch |err| {
                self.failure = err;
                self.entered.set(io);
                return;
            };
            defer self.fixture.device.releaseOperation(io);
            self.entered.set(io);
            self.result = create(kind, self.fixture, self.fixture.allocator) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
}

test "native concurrent identical factory misses return one pointer with two owned aliases" {
    inline for (comptime std.meta.tags(Kind)) |kind| {
        var f: Fixture = undefined;
        try f.init(t.allocator);
        defer f.deinit();
        const io = f.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        var locked = true;
        defer if (locked) guard.unlock(io);
        try f.device.bindObjectsLocked(&guard, f.allocator);
        var first: Race(kind) = .{ .fixture = &f };
        var second: Race(kind) = .{ .fixture = &f };
        const first_thread = try std.Thread.spawn(.{}, Race(kind).run, .{&first});
        var first_joined = false;
        defer {
            if (locked) {
                guard.unlock(io);
                locked = false;
            }
            if (!first_joined) first_thread.join();
            if (first.result) |resource| f.release(resource);
        }
        const second_thread = try std.Thread.spawn(.{}, Race(kind).run, .{&second});
        var second_joined = false;
        defer {
            if (locked) {
                guard.unlock(io);
                locked = false;
            }
            if (!second_joined) second_thread.join();
            if (second.result) |resource| f.release(resource);
        }
        first.entered.waitUncancelable(io);
        second.entered.waitUncancelable(io);
        guard.unlock(io);
        locked = false;
        first_thread.join();
        first_joined = true;
        second_thread.join();
        second_joined = true;
        if (first.failure) |err| return err;
        if (second.failure) |err| return err;
        const original = first.result orelse return error.TestUnexpectedResult;
        const alias = second.result orelse return error.TestUnexpectedResult;
        try t.expect(original == alias);
        try expectUsable(kind, &f, alias);
        var inspect = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer inspect.unlock(io);
        try t.expectEqual(@as(u32, 2), original.header.user_reference_count);
    }
}

const vk = dusk.platform.vulkan_bindings;
const DeviceProcs = dusk.vk.dispatch.DeviceProcs;

// Only this test's copied dispatch table uses this slot. Every call reaches the driver.
var installed_probe: ?*DriverProbe = null;

const DriverProbe = struct {
    device: vk.VkDevice,
    original_pointer: *DeviceProcs,
    original: DeviceProcs,
    wrapped: DeviceProcs,
    created: [3]usize = .{ 0, 0, 0 },
    destroyed: [3]usize = .{ 0, 0, 0 },

    fn attach(self: *DriverProbe, f: *Fixture) void {
        const device = &f.device.native.?.native_device;
        std.debug.assert(installed_probe == null);
        self.* = .{
            .device = device.vk_device,
            .original_pointer = device.procs,
            .original = device.procs.*,
            .wrapped = device.procs.*,
        };
        self.wrapped.create_descriptor_set_layout = createGroup;
        self.wrapped.destroy_descriptor_set_layout = destroyGroup;
        self.wrapped.create_pipeline_layout = createPipeline;
        self.wrapped.destroy_pipeline_layout = destroyPipeline;
        self.wrapped.create_shader_module = createShader;
        self.wrapped.destroy_shader_module = destroyShader;
        installed_probe = self;
        device.procs = &self.wrapped;
    }

    fn detach(self: *DriverProbe, f: *Fixture) void {
        f.device.native.?.native_device.procs = self.original_pointer;
        std.debug.assert(installed_probe == self);
        installed_probe = null;
    }

    fn get(device: vk.VkDevice) *DriverProbe {
        const self = installed_probe orelse @panic("missing driver probe");
        std.debug.assert(self.device == device);
        return self;
    }

    fn createGroup(
        device: vk.VkDevice,
        info: [*c]const vk.VkDescriptorSetLayoutCreateInfo,
        allocator: [*c]const vk.VkAllocationCallbacks,
        output: [*c]vk.VkDescriptorSetLayout,
    ) callconv(.c) vk.VkResult {
        const self = get(device);
        const result = self.original.create_descriptor_set_layout.?(device, info, allocator, output);
        if (result == vk.VK_SUCCESS) self.created[0] += 1;
        return result;
    }

    fn destroyGroup(
        device: vk.VkDevice,
        handle: vk.VkDescriptorSetLayout,
        allocator: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self = get(device);
        self.original.destroy_descriptor_set_layout.?(device, handle, allocator);
        self.destroyed[0] += 1;
    }

    fn createPipeline(
        device: vk.VkDevice,
        info: [*c]const vk.VkPipelineLayoutCreateInfo,
        allocator: [*c]const vk.VkAllocationCallbacks,
        output: [*c]vk.VkPipelineLayout,
    ) callconv(.c) vk.VkResult {
        const self = get(device);
        const result = self.original.create_pipeline_layout.?(device, info, allocator, output);
        if (result == vk.VK_SUCCESS) self.created[1] += 1;
        return result;
    }

    fn destroyPipeline(
        device: vk.VkDevice,
        handle: vk.VkPipelineLayout,
        allocator: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self = get(device);
        self.original.destroy_pipeline_layout.?(device, handle, allocator);
        self.destroyed[1] += 1;
    }

    fn createShader(
        device: vk.VkDevice,
        info: [*c]const vk.VkShaderModuleCreateInfo,
        allocator: [*c]const vk.VkAllocationCallbacks,
        output: [*c]vk.VkShaderModule,
    ) callconv(.c) vk.VkResult {
        const self = get(device);
        const result = self.original.create_shader_module.?(device, info, allocator, output);
        if (result == vk.VK_SUCCESS) self.created[2] += 1;
        return result;
    }

    fn destroyShader(
        device: vk.VkDevice,
        handle: vk.VkShaderModule,
        allocator: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self = get(device);
        self.original.destroy_shader_module.?(device, handle, allocator);
        self.destroyed[2] += 1;
    }
};

fn rollbackCreate(
    comptime kind: Kind,
    f: *Fixture,
    group: ?*native.BindGroupLayout,
) !*Resource(kind) {
    if (kind == .pipeline_layout) {
        return f.device.createPipelineLayout(f.allocator, f.threaded.io(), .{
            .groups = &.{ group.?, group.? },
            .immediate_size = 4,
        });
    }
    return create(kind, f, f.allocator);
}

test "native resource fail-N rolls back every real factory and post-driver insertion" {
    inline for (comptime std.meta.tags(Kind)) |kind| {
        var reached_success = false;
        var saw_failure = false;
        var saw_native_rollback = false;
        for (0..128) |offset| {
            var failing = t.FailingAllocator.init(t.allocator, .{});
            var f: Fixture = undefined;
            try f.init(failing.allocator());
            defer f.deinit();
            const io = f.threaded.io();
            const group: ?*native.BindGroupLayout = if (kind == .pipeline_layout)
                try f.device.createBindGroupLayout(f.allocator, io, .{
                    .entries = &storage_entries,
                })
            else
                null;
            defer if (group) |resource| f.release(resource);
            var probe: DriverProbe = undefined;
            probe.attach(&f);
            defer probe.detach(&f);
            var baseline_references: u64 = undefined;
            var baseline_group_references: u32 = undefined;
            {
                var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
                defer guard.unlock(io);
                baseline_references = guard.objects.total_reference_count;
                baseline_group_references = if (group) |resource|
                    resource.header.reference_count
                else
                    0;
            }
            failing.fail_index = failing.alloc_index + offset;
            const result = rollbackCreate(kind, &f, group);
            failing.fail_index = std.math.maxInt(usize);
            if (result) |resource| {
                defer f.release(resource);
                try expectUsable(kind, &f, resource);
                reached_success = true;
            } else |err| {
                try t.expectEqual(error.OutOfMemory, err);
                saw_failure = true;
                if (probe.created[@intFromEnum(kind)] != 0) saw_native_rollback = true;
            }
            try t.expectEqualSlices(usize, &probe.created, &probe.destroyed);
            {
                var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
                defer guard.unlock(io);
                try t.expectEqual(baseline_references, guard.objects.total_reference_count);
                if (group) |resource| {
                    try t.expectEqual(baseline_group_references, resource.header.reference_count);
                }
                const store = &f.device.native.?.resource_store.?;
                switch (kind) {
                    .group_layout => try t.expectEqual(@as(usize, 0), store.bind_group_layouts.member_count),
                    .pipeline_layout => try t.expect(store.pipeline_layouts.isEmpty(&guard)),
                    .shader => try t.expect(store.shader_modules.isEmpty(&guard)),
                }
            }
            const before_retry = probe.created[@intFromEnum(kind)];
            const retried = try rollbackCreate(kind, &f, group);
            var retried_owned = true;
            defer if (retried_owned) f.release(retried);
            const alias = try rollbackCreate(kind, &f, group);
            var alias_owned = true;
            defer if (alias_owned) f.release(alias);
            try t.expect(retried == alias);
            try t.expectEqual(before_retry + 1, probe.created[@intFromEnum(kind)]);
            try expectUsable(kind, &f, alias);
            f.release(retried);
            retried_owned = false;
            f.release(alias);
            alias_owned = false;
            try t.expectEqualSlices(usize, &probe.created, &probe.destroyed);
            if (reached_success) break;
        }
        try t.expect(reached_success);
        try t.expect(saw_failure);
        try t.expect(saw_native_rollback);
    }
}

test "cached native shaders and layouts execute after all source users release" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    const group_layout = try f.device.createBindGroupLayout(f.allocator, io, .{
        .entries = &storage_entries,
    });
    var group_layout_owned = true;
    defer if (group_layout_owned) f.release(group_layout);
    const group_alias = try f.device.createBindGroupLayout(f.allocator, io, .{
        .entries = &storage_entries,
        .label = "cached group layout",
    });
    var group_alias_owned = true;
    defer if (group_alias_owned) f.release(group_alias);
    try t.expect(group_layout == group_alias);
    const layout = try f.device.createPipelineLayout(f.allocator, io, .{
        .groups = &.{group_layout},
    });
    var layout_owned = true;
    defer if (layout_owned) f.release(layout);
    const layout_alias = try f.device.createPipelineLayout(f.allocator, io, .{
        .groups = &.{group_alias},
        .label = "cached pipeline layout",
    });
    var layout_alias_owned = true;
    defer if (layout_alias_owned) f.release(layout_alias);
    try t.expect(layout == layout_alias);
    const shader = try create(.shader, &f, f.allocator);
    var shader_owned = true;
    defer if (shader_owned) f.release(shader);
    const shader_alias = try create(.shader, &f, f.allocator);
    var shader_alias_owned = true;
    defer if (shader_alias_owned) f.release(shader_alias);
    try t.expect(shader == shader_alias);
    const compute = try f.device.createComputePipeline(f.allocator, io, .{
        .layout = layout_alias,
        .compute = .{ .module = shader_alias, .entry_point = "main", .stage = .compute },
    });
    var compute_owned = true;
    defer if (compute_owned) f.release(compute);
    try t.expect(compute.layout == layout);
    const output = try f.device.createBuffer(f.allocator, io, .{
        .size = 4,
        .usage = .{ .storage = true, .copy_src = true },
    });
    defer f.release(output);
    const readback = try f.device.createBuffer(f.allocator, io, .{
        .size = 4,
        .usage = .{ .copy_dst = true, .map_read = true },
    });
    defer f.release(readback);
    const group = try f.device.createBindGroup(f.allocator, io, .{
        .layout = layout_alias,
        .group_index = 0,
        .bindings = &.{.{ .buffer = .{
            .binding = 0,
            .buffer = output,
            .offset = 0,
            .size = 4,
            .kind = .storage,
            .stages = .{ .compute = true },
        } }},
    });
    var group_owned = true;
    defer if (group_owned) f.release(group);
    f.release(group_layout);
    group_layout_owned = false;
    f.release(group_alias);
    group_alias_owned = false;
    f.release(layout);
    layout_owned = false;
    f.release(layout_alias);
    layout_alias_owned = false;
    f.release(shader);
    shader_owned = false;
    f.release(shader_alias);
    shader_alias_owned = false;
    try expectUsable(.group_layout, &f, group_layout);
    try expectUsable(.pipeline_layout, &f, layout);
    try expectUsable(.shader, &f, shader);
    var encoder = dusk.command.command_encoder.CommandEncoder.init(
        f.allocator,
        f.device.core.borrow(),
        .{},
    );
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(f.allocator, io, &guard);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        var pass = try encoder.beginComputePass(.{});
        defer pass.deinit();
        try pass.setPipeline(.{
            .pipeline = try compute.ref(&guard),
            .requirements = .{
                .bind_group_layout_mask = 1,
                .bind_group_layout_ids = .{ @intFromPtr(&group_layout.header), 0, 0, 0 },
            },
        });
        try pass.setBindGroup(.{
            .index = 0,
            .group = try group.ref(&guard),
            .layout_id = @intFromPtr(&group_layout.header),
            .min_binding_buffer_size = 4,
            .buffers = &.{.{
                .buffer = try output.ref(&guard),
                .usage = (dusk.api.BufferUsage{ .storage = true }).toFlags(),
            }},
        });
        try pass.dispatch(.{ .x = 1, .y = 1, .z = 1 });
        try pass.end();
        try encoder.copyBufferToBuffer(.{
            .source = try output.ref(&guard),
            .destination = try readback.ref(&guard),
            .size = 4,
        });
    }
    var finished = try encoder.finish();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(f.allocator, io, &guard);
    }
    const serial = try f.device.submit(f.allocator, io, &finished);
    f.release(compute);
    compute_owned = false;
    f.release(group);
    group_owned = false;
    try f.device.wait(io, serial);
    {
        var queue = try f.device.getQueue(io);
        defer queue.deinit(io);
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        const generation = try readback.native.beginMap(.{ .mode = .{ .read = true }, .size = 4 });
        try t.expectEqual(engine.buffer.Buffer.MapCompletion.mapped, try readback.native.completeMap(generation, serial));
        const bytes = try readback.native.getConstMappedRange(0, 4);
        try t.expectEqual(shader_fixture.default_output, std.mem.readInt(u32, bytes[0..4], .little));
    }
    try f.device.unmapBuffer(io, readback);
}

test "native cache hit fail-N preserves existing user aliases and owned shader words" {
    inline for (comptime std.meta.tags(Kind)) |kind| {
        var reached_success = false;
        for (0..64) |offset| {
            var failing = t.FailingAllocator.init(t.allocator, .{});
            var f: Fixture = undefined;
            try f.init(failing.allocator());
            defer f.deinit();
            const io = f.threaded.io();
            const first = try create(kind, &f, f.allocator);
            defer f.release(first);
            failing.fail_index = failing.alloc_index + offset;
            const result = create(kind, &f, f.allocator);
            failing.fail_index = std.math.maxInt(usize);
            if (result) |alias| {
                defer f.release(alias);
                try t.expect(first == alias);
                try expectUsable(kind, &f, alias);
                reached_success = true;
            } else |err| {
                try t.expectEqual(error.OutOfMemory, err);
                try expectUsable(kind, &f, first);
                var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
                defer guard.unlock(io);
                try t.expectEqual(@as(u32, 1), first.header.user_reference_count);
            }
            if (kind == .shader) try t.expectEqual(@as(usize, 0), offset);
            if (reached_success) break;
        }
        try t.expect(reached_success);
    }
}

test "native automatic layouts mint once per preparation and preserve empty group gaps" {
    var f: Fixture = undefined;
    try f.init(t.allocator);
    defer f.deinit();
    const io = f.threaded.io();
    var words = shader_fixture.words;
    var offset: usize = 5;
    var changed = false;
    for (0..words.len) |_| {
        if (offset == words.len) break;
        const count = words[offset] >> 16;
        if (count == 0 or offset + count > words.len) return error.BadFixture;
        if (words[offset] & 0xffff == 71 and count == 4 and
            words[offset + 1] == 7 and words[offset + 2] == 34)
        {
            words[offset + 3] = 2;
            changed = true;
        }
        offset += count;
    }
    try t.expect(changed);
    try t.expectEqual(words.len, offset);
    const module = try f.device.createShaderModule(f.allocator, io, .{ .words = &words });
    defer f.release(module);
    var exported: dusk.api.ShaderModule = undefined;
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        exported = engine.native_async_handles.exportResource(
            dusk.api.ShaderModule,
            &f.device,
            &guard,
            module,
            .shader_module,
        );
    }
    const descriptor: dusk.api.descriptors.ComputePipelineDescriptorChain = .{
        .compute = .{ .module = exported, .entry_point = "main" },
    };
    var first = try engine.native_async_descriptors.OwnedCompute.prepare(
        f.allocator,
        io,
        &f.device,
        &descriptor,
    );
    defer first.deinit(io);
    var second = try engine.native_async_descriptors.OwnedCompute.prepare(
        f.allocator,
        io,
        &f.device,
        &descriptor,
    );
    defer second.deinit(io);
    const first_options = try first.options(f.allocator, io, &f.device);
    const repeated = try first.options(f.allocator, io, &f.device);
    const second_options = try second.options(f.allocator, io, &f.device);
    try t.expect(first_options.layout == repeated.layout);
    try t.expect(first_options.layout != second_options.layout);
    try t.expectEqual(@as(usize, 3), first_options.layout.groups.len);
    try t.expect(first_options.layout.groups[0] == first_options.layout.groups[1]);
    try t.expect(first_options.layout.groups[1] != first_options.layout.groups[2]);
    const token = first_options.layout.native.compatibility_token;
    try t.expect(token != 0);
    try t.expect(token != second_options.layout.native.compatibility_token);
    for (first_options.layout.groups) |group| {
        try t.expectEqual(token, group.compatibility_token);
    }
    const compute = try f.device.createComputePipeline(f.allocator, io, first_options);
    defer f.release(compute);
    const other = try f.device.createComputePipeline(f.allocator, io, second_options);
    defer f.release(other);
    try t.expect(compute.layout == first_options.layout);
    try t.expect(other.layout == second_options.layout);
    try t.expect(compute != other);
}

test "native cache misses refuse missing cleanup procedures before real native creation" {
    inline for (comptime std.meta.tags(Kind)) |kind| {
        var f: Fixture = undefined;
        try f.init(t.allocator);
        defer f.deinit();
        const io = f.threaded.io();
        var baseline_references: u64 = undefined;
        var baseline_users: u64 = undefined;
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            try f.device.bindObjectsLocked(&guard, f.allocator);
            baseline_references = guard.objects.total_reference_count;
            baseline_users = guard.objects.user_reference_count;
        }
        var probe: DriverProbe = undefined;
        probe.attach(&f);
        defer probe.detach(&f);
        switch (kind) {
            .group_layout => probe.wrapped.destroy_descriptor_set_layout = null,
            .pipeline_layout => probe.wrapped.destroy_pipeline_layout = null,
            .shader => probe.wrapped.destroy_shader_module = null,
        }
        const result = create(kind, &f, f.allocator);
        // Restore cleanup before inspecting the result, including an unexpected success.
        switch (kind) {
            .group_layout => probe.wrapped.destroy_descriptor_set_layout =
                probe.original.destroy_descriptor_set_layout,
            .pipeline_layout => probe.wrapped.destroy_pipeline_layout =
                probe.original.destroy_pipeline_layout,
            .shader => probe.wrapped.destroy_shader_module = probe.original.destroy_shader_module,
        }
        if (result) |resource| {
            f.release(resource);
            return error.TestUnexpectedResult;
        } else |err| {
            try t.expectEqual(error.MissingDeviceProc, err);
        }
        try t.expectEqualSlices(usize, &.{ 0, 0, 0 }, &probe.created);
        try t.expectEqualSlices(usize, &.{ 0, 0, 0 }, &probe.destroyed);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
            defer guard.unlock(io);
            try t.expectEqual(baseline_references, guard.objects.total_reference_count);
            try t.expectEqual(baseline_users, guard.objects.user_reference_count);
            const store = &f.device.native.?.resource_store.?;
            try t.expect(store.bind_group_layouts.isEmpty(&guard));
            try t.expect(store.pipeline_layouts.isEmpty(&guard));
            try t.expect(store.shader_modules.isEmpty(&guard));
        }
        const created = try create(kind, &f, f.allocator);
        defer f.release(created);
        const alias = try create(kind, &f, f.allocator);
        defer f.release(alias);
        try t.expect(created == alias);
        try t.expectEqual(@as(usize, 1), probe.created[@intFromEnum(kind)]);
        try expectUsable(kind, &f, alias);
    }
}
