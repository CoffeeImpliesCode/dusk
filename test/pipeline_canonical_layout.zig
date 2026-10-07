//! Real Vulkan low pipelines retain canonical layout owners across cache aliases and rollback.
const std = @import("std");
const dusk = @import("dusk");
const compute_fixture = @import("fixtures/specialization_compute.zig");
const graphics_fixture = @import("fixtures/specialization_graphics.zig");
const core = dusk.core;
const engine = dusk.engine;
const resources = engine.native_resources;
const pipeline = dusk.pipeline.pipeline;
const vk = dusk.platform.vulkan_bindings;
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
        self.device = try self.adapters.items[0].createDevice(allocator, io, .{
            .adapter = &self.adapters.items[0],
            .feature_level = .core,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
    }

    fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
        @panic("canonical layout fixture reported an uncaptured error");
    }

    fn deinit(self: *Fixture) void {
        const io = self.threaded.io();
        self.device.deinit(self.allocator, io) catch @panic("device teardown failed");
        self.adapters.deinit(io) catch @panic("adapter teardown failed");
        self.instance.deinit(self.allocator, io) catch @panic("instance teardown failed");
        self.threaded.deinit();
    }
};

// C callbacks have no context argument. Only this fixture's real dispatch uses this slot.
var installed_render_pass_probe: ?*RenderPassProbe = null;

const RenderPassProbe = struct {
    const max_live_render_passes = 8;

    device: vk.VkDevice,
    original_create: vk.PFN_vkCreateRenderPass,
    original_destroy: vk.PFN_vkDestroyRenderPass,
    original_destroy_device: vk.PFN_vkDestroyDevice,
    live_handles: [max_live_render_passes]u64 = @splat(0),
    created_count: usize = 0,
    destroyed_count: usize = 0,
    outstanding_at_device_destroy: ?usize = null,

    fn attach(self: *RenderPassProbe, f: *Fixture) void {
        const device = &f.device.native.?.native_device;
        std.debug.assert(installed_render_pass_probe == null);
        std.debug.assert(device.procs.create_render_pass != null);
        std.debug.assert(device.procs.destroy_render_pass != null);
        std.debug.assert(device.instance.procs.destroy_device != null);
        std.debug.assert(f.device.native.?.render_pass_cache.device.procs == device.procs);
        self.* = .{
            .device = device.vk_device,
            .original_create = device.procs.create_render_pass,
            .original_destroy = device.procs.destroy_render_pass,
            .original_destroy_device = device.instance.procs.destroy_device,
        };
        installed_render_pass_probe = self;
        // Mutate the shared table, not its pointer: the cache already borrowed this table.
        device.procs.create_render_pass = create;
        device.procs.destroy_render_pass = destroy;
        // Native Device.deinit reaches the instance tier, not the device tier.
        device.instance.procs.destroy_device = destroyDevice;
    }

    fn detach(self: *RenderPassProbe) void {
        // Fixture.deinit has already freed both dispatch tables.
        std.debug.assert(installed_render_pass_probe == self);
        installed_render_pass_probe = null;
    }

    fn get(device: vk.VkDevice) *RenderPassProbe {
        const self = installed_render_pass_probe orelse @panic("missing render pass probe");
        std.debug.assert(self.device == device);
        return self;
    }

    fn handleBits(handle: vk.VkRenderPass) u64 {
        return switch (@typeInfo(vk.VkRenderPass)) {
            .pointer, .optional => @intFromPtr(handle),
            .int => @intCast(handle),
            else => @compileError("unexpected Vulkan render pass handle type"),
        };
    }

    fn outstandingCount(self: *const RenderPassProbe) usize {
        var count: usize = 0;
        for (self.live_handles) |handle| {
            if (handle != 0) count += 1;
        }
        return count;
    }

    fn expectEmpty(self: *const RenderPassProbe) !void {
        try t.expectEqual(@as(usize, 0), self.outstandingCount());
        try t.expectEqual(self.created_count, self.destroyed_count);
        for (self.live_handles) |handle| try t.expectEqual(@as(u64, 0), handle);
    }

    fn create(
        device: vk.VkDevice,
        info: [*c]const vk.VkRenderPassCreateInfo,
        callbacks: [*c]const vk.VkAllocationCallbacks,
        output: [*c]vk.VkRenderPass,
    ) callconv(.c) vk.VkResult {
        const self = get(device);
        const result = self.original_create.?(device, info, callbacks, output);
        if (result != vk.VK_SUCCESS) return result;
        const value = handleBits(output[0]);
        std.debug.assert(value != 0);
        for (self.live_handles) |handle| std.debug.assert(handle != value);
        for (&self.live_handles) |*slot| {
            if (slot.* == 0) {
                slot.* = value;
                self.created_count += 1;
                return result;
            }
        }
        @panic("render pass probe exhausted");
    }

    fn destroy(
        device: vk.VkDevice,
        handle: vk.VkRenderPass,
        callbacks: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self = get(device);
        self.original_destroy.?(device, handle, callbacks);
        const value = handleBits(handle);
        if (value == 0) return;
        for (&self.live_handles) |*slot| {
            if (slot.* == value) {
                slot.* = 0;
                self.destroyed_count += 1;
                return;
            }
        }
        @panic("render pass probe saw an unowned or already destroyed handle");
    }

    fn destroyDevice(
        device: vk.VkDevice,
        callbacks: [*c]const vk.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self = get(device);
        std.debug.assert(self.outstanding_at_device_destroy == null);
        // Record before native destruction can reclaim leaked children. Always forward cleanup.
        self.outstanding_at_device_destroy = self.outstandingCount();
        self.original_destroy_device.?(device, callbacks);
    }
};

const Shaders = struct {
    compute: *resources.ShaderModule,
    vertex: *resources.ShaderModule,
    fragment: *resources.ShaderModule,

    fn create(f: *Fixture) !Shaders {
        const io = f.threaded.io();
        const compute = try f.device.createShaderModule(f.allocator, io, .{
            .words = &compute_fixture.words,
        });
        errdefer f.device.release(f.allocator, io, compute) catch @panic("shader rollback failed");
        const vertex = try f.device.createShaderModule(f.allocator, io, .{
            .words = &graphics_fixture.vertex_words,
        });
        errdefer f.device.release(f.allocator, io, vertex) catch @panic("shader rollback failed");
        const fragment = try f.device.createShaderModule(f.allocator, io, .{
            .words = &graphics_fixture.fragment_words,
        });
        return .{ .compute = compute, .vertex = vertex, .fragment = fragment };
    }

    fn deinit(self: Shaders, f: *Fixture) void {
        const io = f.threaded.io();
        f.device.release(f.allocator, io, self.fragment) catch @panic("shader release failed");
        f.device.release(f.allocator, io, self.vertex) catch @panic("shader release failed");
        f.device.release(f.allocator, io, self.compute) catch @panic("shader release failed");
    }
};

fn makeLayout(f: *Fixture, guard: *const core.ObjectGuard, token: u64) !*resources.PipelineLayout {
    const context = f.device.native.?;
    const compatibility_limits = &f.device.limits.compatibility.?;
    const group = try resources.createBindGroupLayout(
        f.allocator,
        f.threaded.io(),
        guard,
        &f.device.core.arena,
        context.resourceDevice(),
        .{
            .descriptor = .{ .entries = &.{.{
                .binding_number = 0,
                .visibility = .{ .compute = true },
                .kind = .{ .buffer = .{
                    .binding_type = .storage,
                    .has_dynamic_offset = false,
                    .min_binding_size = 0,
                } },
            }} },
            .validation = .{
                .max_storage_buffers_in_vertex_stage = compatibility_limits.max_storage_buffers_in_vertex_stage,
                .max_storage_buffers_in_fragment_stage = compatibility_limits.max_storage_buffers_in_fragment_stage,
            },
            .compatibility_token = token,
        },
    );
    defer group.header.releaseUserLocked(guard, f.threaded.io()) catch
        @panic("group release failed");
    return resources.createPipelineLayout(
        f.allocator,
        f.threaded.io(),
        guard,
        &f.device.core.arena,
        context.resourceDevice(),
        .{ .groups = &.{group}, .compatibility_token = token },
    );
}

fn createLow(
    f: *Fixture,
    guard: *const core.ObjectGuard,
    shaders: Shaders,
    kind: pipeline.Kind,
    layout: pipeline.LayoutInput,
    backend: *const pipeline.Backend,
) !core.Handle {
    const context = f.device.native.?;
    const store = &context.pipeline_store.?;
    switch (kind) {
        .compute => return pipeline.createComputePipelineLocked(
            f.allocator,
            f.threaded.io(),
            guard,
            &f.device.core,
            store,
            backend,
            .{
                .layout = layout,
                .compute = .{
                    .module = shaders.compute.native.vk_module,
                    .entry_point = compute_fixture.entry_point,
                    .stage = .compute,
                    .content_bytes = std.mem.sliceAsBytes(shaders.compute.words),
                },
                .limits = .{ .max_workgroup_size = .{ 256, 256, 64 }, .max_invocations = 256 },
            },
            .user,
        ),
        .render => {
            var query: engine.render_pass_cache.RenderPassCacheQuery = .{};
            query.setSampleCount(1);
            query.setColor(.{
                .index = 0,
                .format = .rgba8_unorm,
                .load_op = .clear,
                .store_op = .store,
                .has_resolve_target = false,
                .render_to_single_sampled = false,
            });
            const pass = try context.render_pass_cache.getRenderPass(f.threaded.io(), query);
            return pipeline.createRenderPipelineLocked(
                f.allocator,
                f.threaded.io(),
                guard,
                &f.device.core,
                store,
                backend,
                .{
                    .compatible_render_pass = pass.render_pass,
                    .layout = layout,
                    .vertex = .{
                        .module = shaders.vertex.native.vk_module,
                        .entry_point = graphics_fixture.entry_point,
                        .stage = .vertex,
                        .content_bytes = std.mem.sliceAsBytes(shaders.vertex.words),
                    },
                    .fragment = .{
                        .module = shaders.fragment.native.vk_module,
                        .entry_point = graphics_fixture.entry_point,
                        .stage = .fragment,
                        .content_bytes = std.mem.sliceAsBytes(shaders.fragment.words),
                    },
                    .color_targets = &.{.{ .format = vk.VK_FORMAT_R8G8B8A8_UNORM }},
                },
                .user,
            );
        },
    }
}

fn releaseLow(f: *Fixture, guard: *const core.ObjectGuard, handle: core.Handle) void {
    const header = f.device.core.resolveReference(guard, handle) catch
        @panic("low pipeline reference resolution failed");
    header.releaseUserLocked(guard, f.threaded.io()) catch @panic("pipeline release failed");
}

fn expectLowError(
    f: *Fixture,
    guard: *const core.ObjectGuard,
    expected: anyerror,
    result: anyerror!core.Handle,
) !void {
    if (result) |handle| {
        releaseLow(f, guard, handle);
        return error.TestExpectedError;
    } else |err| {
        try t.expectEqual(expected, err);
    }
}

test "canonical compute and graphics layouts survive user release and weak pipeline retirement" {
    inline for (.{ pipeline.Kind.compute, pipeline.Kind.render }) |kind| {
        var f: Fixture = .{};
        try f.init(t.allocator);
        defer f.deinit();
        const shaders = try Shaders.create(&f);
        defer shaders.deinit(&f);
        // The public factory binds the actual context to the original arena/list.
        const initial = try f.device.createPipelineLayout(f.allocator, f.threaded.io(), .{
            .groups = &.{},
        });
        defer f.device.release(f.allocator, f.threaded.io(), initial) catch
            @panic("initial layout release failed");
        var guard = core.ObjectGuard.lockUncancelable(f.threaded.io(), f.device.core.arena.objectList());
        defer guard.unlock(f.threaded.io());
        const layout = try makeLayout(&f, &guard, 11);
        var layout_owned = true;
        defer if (layout_owned) layout.header.releaseUserLocked(&guard, f.threaded.io()) catch
            @panic("layout release failed");
        const input = try layout.input(&guard);
        const backend = &f.device.native.?.pipeline_backend;
        const first = try createLow(&f, &guard, shaders, kind, input, backend);
        var first_owned = true;
        defer if (first_owned) releaseLow(&f, &guard, first);
        const low = try f.device.core.resolve(&guard, pipeline.Pipeline, first);
        try t.expectEqual(&layout.header, low.canonical_layout_header.?);
        try t.expectEqual(@as(u32, 2), layout.header.reference_count);
        try layout.header.releaseUserLocked(&guard, f.threaded.io());
        layout_owned = false;
        try t.expect(layout.header.isAlive(&guard));
        try t.expectEqual(
            @as(vk.VkDescriptorType, vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER),
            low.group_layouts[0].bindings[0].descriptorType,
        );
        try t.expect(low.compatibleForGroup(&guard, low, 0));
        const hit = try createLow(&f, &guard, shaders, kind, input, backend);
        var hit_owned = true;
        defer if (hit_owned) releaseLow(&f, &guard, hit);
        try t.expectEqual(first.ptr, hit.ptr);
        try t.expectEqual(@as(u32, 1), layout.header.reference_count);
        releaseLow(&f, &guard, first);
        first_owned = false;
        try t.expect(layout.header.isAlive(&guard));
        low.header.retirePayloadLocked(&guard, f.threaded.io(), .early_destroy);
        try t.expectEqual(@as(@TypeOf(layout.header.state), .destroyed), layout.header.state);
        try t.expectEqual(@as(u32, 0), layout.header.reference_count);
        try t.expectEqual(@as(usize, 0), f.device.native.?.pipeline_store.?.queryPipelineCount(&guard));
        try expectLowError(&f, &guard, error.ResourceDestroyed, createLow(&f, &guard, shaders, kind, input, backend));
        releaseLow(&f, &guard, hit);
        hit_owned = false;
        try t.expectEqual(@as(u32, 0), layout.header.reference_count);
        const fresh_layout = try makeLayout(&f, &guard, 11);
        defer fresh_layout.header.releaseUserLocked(&guard, f.threaded.io()) catch
            @panic("fresh layout release failed");
        try t.expect(fresh_layout != layout);
        const fresh = try createLow(
            &f,
            &guard,
            shaders,
            kind,
            try fresh_layout.input(&guard),
            backend,
        );
        defer releaseLow(&f, &guard, fresh);
        try t.expect(fresh.ptr != first.ptr);
        try t.expect(fresh_layout.header.isAlive(&guard));
    }
}

test "equal physical definitions with distinct canonical tokens do not share low pipelines" {
    inline for (.{ pipeline.Kind.compute, pipeline.Kind.render }) |kind| {
        var f: Fixture = .{};
        try f.init(t.allocator);
        defer f.deinit();
        const shaders = try Shaders.create(&f);
        defer shaders.deinit(&f);
        const initial = try f.device.createPipelineLayout(f.allocator, f.threaded.io(), .{ .groups = &.{} });
        defer f.device.release(f.allocator, f.threaded.io(), initial) catch @panic("layout release failed");
        var guard = core.ObjectGuard.lockUncancelable(f.threaded.io(), f.device.core.arena.objectList());
        defer guard.unlock(f.threaded.io());
        const left = try makeLayout(&f, &guard, 11);
        defer left.header.releaseUserLocked(&guard, f.threaded.io()) catch @panic("layout release failed");
        const right = try makeLayout(&f, &guard, 12);
        defer right.header.releaseUserLocked(&guard, f.threaded.io()) catch @panic("layout release failed");
        const left_input = try left.input(&guard);
        const right_input = try right.input(&guard);
        var physical_left = left_input.groups[0];
        var physical_right = right_input.groups[0];
        physical_left.compatibility_token = 0;
        physical_right.compatibility_token = 0;
        try t.expect(physical_left.compatible(physical_right));
        try t.expect(!left_input.groups[0].compatible(right_input.groups[0]));
        const backend = &f.device.native.?.pipeline_backend;
        const first = try createLow(&f, &guard, shaders, kind, left_input, backend);
        defer releaseLow(&f, &guard, first);
        const second = try createLow(&f, &guard, shaders, kind, right_input, backend);
        defer releaseLow(&f, &guard, second);
        try t.expect(first.ptr != second.ptr);
        const left_low = try f.device.core.resolve(&guard, pipeline.Pipeline, first);
        const right_low = try f.device.core.resolve(&guard, pipeline.Pipeline, second);
        try t.expect(!left_low.compatibleForGroup(&guard, right_low, 0));
        const hit = try createLow(&f, &guard, shaders, kind, left_input, backend);
        defer releaseLow(&f, &guard, hit);
        try t.expectEqual(first.ptr, hit.ptr);
        // Genuine standalone mode uses the same physical input, not the canonical cache domain.
        var raw = left_input;
        raw.canonical_layout_header = null;
        var raw_groups = [_]pipeline.GroupLayout{
            try left_input.groups[0].clone(f.allocator),
        };
        var source_groups_owned = true;
        defer if (source_groups_owned) raw_groups[0].deinit(f.allocator);
        raw.groups = &raw_groups;
        const standalone = try createLow(&f, &guard, shaders, kind, raw, backend);
        defer releaseLow(&f, &guard, standalone);
        try t.expect(standalone.ptr != first.ptr);
        const low = try f.device.core.resolve(&guard, pipeline.Pipeline, standalone);
        try t.expectEqual(@as(?*core.Object, null), low.canonical_layout_header);
        // Standalone definitions are caller-owned only through creation.
        raw_groups[0].deinit(f.allocator);
        source_groups_owned = false;
        try t.expectEqual(
            @as(vk.VkDescriptorType, vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER),
            low.group_layouts[0].bindings[0].descriptorType,
        );
        try t.expect(low.compatibleForGroup(&guard, low, 0));
    }
}

test "canonical layout validation precedes cached hits and misses" {
    var f: Fixture = .{};
    try f.init(t.allocator);
    defer f.deinit();
    var foreign: Fixture = .{};
    try foreign.init(t.allocator);
    defer foreign.deinit();
    const shaders = try Shaders.create(&f);
    defer shaders.deinit(&f);
    const layout = try f.device.createPipelineLayout(f.allocator, f.threaded.io(), .{ .groups = &.{} });
    defer f.device.release(f.allocator, f.threaded.io(), layout) catch @panic("layout release failed");
    const foreign_layout = try foreign.device.createPipelineLayout(foreign.allocator, foreign.threaded.io(), .{ .groups = &.{} });
    defer foreign.device.release(foreign.allocator, foreign.threaded.io(), foreign_layout) catch @panic("layout release failed");
    var guard = core.ObjectGuard.lockUncancelable(f.threaded.io(), f.device.core.arena.objectList());
    defer guard.unlock(f.threaded.io());
    const storage_layout = try makeLayout(&f, &guard, 11);
    defer storage_layout.header.releaseUserLocked(&guard, f.threaded.io()) catch @panic("layout release failed");
    const input = try storage_layout.input(&guard);
    const backend = &f.device.native.?.pipeline_backend;
    inline for (.{ pipeline.Kind.compute, pipeline.Kind.render }) |kind| {
        const first = try createLow(&f, &guard, shaders, kind, input, backend);
        defer releaseLow(&f, &guard, first);
        var invalid = input;
        invalid.canonical_layout_header = &foreign_layout.header;
        try expectLowError(
            &f,
            &guard,
            error.ResourceDeviceMismatch,
            createLow(&f, &guard, shaders, kind, invalid, backend),
        );
        invalid.canonical_layout_header = &shaders.compute.header;
        try expectLowError(
            &f,
            &guard,
            error.HandleKindMismatch,
            createLow(&f, &guard, shaders, kind, invalid, backend),
        );
        const before = storage_layout.header.reference_count;
        storage_layout.header.state = .failed;
        defer storage_layout.header.state = .alive;
        try expectLowError(
            &f,
            &guard,
            error.ResourceDestroyed,
            createLow(&f, &guard, shaders, kind, input, backend),
        );
        try t.expectEqual(before, storage_layout.header.reference_count);
    }
}

test "native creation refusal and refcount exhaustion roll back the canonical lease" {
    inline for (.{ pipeline.Kind.compute, pipeline.Kind.render }) |kind| {
        var f: Fixture = .{};
        try f.init(t.allocator);
        defer f.deinit();
        const shaders = try Shaders.create(&f);
        defer shaders.deinit(&f);
        const initial = try f.device.createPipelineLayout(f.allocator, f.threaded.io(), .{ .groups = &.{} });
        defer f.device.release(f.allocator, f.threaded.io(), initial) catch @panic("layout release failed");
        var guard = core.ObjectGuard.lockUncancelable(f.threaded.io(), f.device.core.arena.objectList());
        defer guard.unlock(f.threaded.io());
        const layout = try makeLayout(&f, &guard, 11);
        defer layout.header.releaseUserLocked(&guard, f.threaded.io()) catch @panic("layout release failed");
        const input = try layout.input(&guard);
        var backend = f.device.native.?.pipeline_backend;
        if (kind == .compute) backend.create_compute_pipelines = null else backend.create_graphics_pipelines = null;
        const references = guard.objects.total_reference_count;
        const result = createLow(&f, &guard, shaders, kind, input, &backend);
        if (result) |handle| {
            releaseLow(&f, &guard, handle);
            return error.MissingProcUnexpectedlySucceeded;
        } else |err| {
            try t.expect(err == error.CreateComputePipelinesNotLoaded or err == error.CreateGraphicsPipelinesNotLoaded);
        }
        try t.expectEqual(@as(u32, 1), layout.header.reference_count);
        try t.expectEqual(references, guard.objects.total_reference_count);
        const actual_count = layout.header.reference_count;
        const extra_leases = std.math.maxInt(u32) - actual_count;
        layout.header.reference_count = std.math.maxInt(u32);
        guard.objects.total_reference_count += extra_leases;
        defer {
            layout.header.reference_count = actual_count;
            guard.objects.total_reference_count -= extra_leases;
        }
        try expectLowError(&f, &guard, error.ReferenceCountOverflow, createLow(&f, &guard, shaders, kind, input, &f.device.native.?.pipeline_backend));
        try t.expectEqual(references + extra_leases, guard.objects.total_reference_count);
    }
}

test "fail N host allocations leave no canonical lease or weak pipeline entry" {
    inline for (.{ pipeline.Kind.compute, pipeline.Kind.render }) |kind| {
        var reached_success = false;
        for (0..128) |offset| {
            // Fresh native/cache/arena state gives every offset the same allocation trace.
            var failing = t.FailingAllocator.init(t.allocator, .{});
            var probe: RenderPassProbe = undefined;
            {
                var f: Fixture = .{};
                try f.init(failing.allocator());
                probe.attach(&f);
                defer probe.detach();
                defer f.deinit();
                try probe.expectEmpty();
                const shaders = try Shaders.create(&f);
                defer shaders.deinit(&f);
                const initial = try f.device.createPipelineLayout(
                    f.allocator,
                    f.threaded.io(),
                    .{ .groups = &.{} },
                );
                defer f.device.release(f.allocator, f.threaded.io(), initial) catch
                    @panic("layout release failed");
                var guard = core.ObjectGuard.lockUncancelable(
                    f.threaded.io(),
                    f.device.core.arena.objectList(),
                );
                defer guard.unlock(f.threaded.io());
                const layout = try makeLayout(&f, &guard, 11);
                defer layout.header.releaseUserLocked(&guard, f.threaded.io()) catch
                    @panic("layout release failed");
                const input = try layout.input(&guard);
                const references = guard.objects.total_reference_count;
                failing.fail_index = failing.alloc_index + offset;
                const result = createLow(&f, &guard, shaders, kind, input, &f.device.native.?.pipeline_backend);
                failing.fail_index = std.math.maxInt(usize);
                if (result) |handle| {
                    releaseLow(&f, &guard, handle);
                    reached_success = true;
                } else |err| {
                    try t.expectEqual(error.OutOfMemory, err);
                }
                try t.expectEqual(@as(u32, 1), layout.header.reference_count);
                try t.expectEqual(references, guard.objects.total_reference_count);
                try t.expectEqual(@as(usize, 0), f.device.native.?.pipeline_store.?.queryPipelineCount(&guard));
            }
            try t.expectEqual(@as(?usize, 0), probe.outstanding_at_device_destroy);
            try probe.expectEmpty();
            if (kind == .compute) {
                try t.expectEqual(@as(usize, 0), probe.created_count);
            } else if (reached_success) {
                try t.expect(probe.created_count > 0);
            }
            if (reached_success) break;
        }
        try t.expect(reached_success);
    }
}

test "low graphics pipelines preserve genuine absent color slots" {
    var f: Fixture = .{};
    try f.init(t.allocator);
    defer f.deinit();
    const shaders = try Shaders.create(&f);
    defer shaders.deinit(&f);
    const layout = try f.device.createPipelineLayout(f.allocator, f.threaded.io(), .{
        .groups = &.{},
    });
    defer f.device.release(f.allocator, f.threaded.io(), layout) catch
        @panic("layout release failed");
    const context = f.device.native.?;
    var query: engine.render_pass_cache.RenderPassCacheQuery = .{};
    query.setSampleCount(1);
    query.setColor(.{
        .index = 1,
        .format = .rgba8_unorm,
        .load_op = .clear,
        .store_op = .store,
        .has_resolve_target = false,
        .render_to_single_sampled = false,
    });
    const pass = try context.render_pass_cache.getRenderPass(f.threaded.io(), query);
    var guard = core.ObjectGuard.lockUncancelable(
        f.threaded.io(),
        f.device.core.arena.objectList(),
    );
    defer guard.unlock(f.threaded.io());
    const targets = [_]pipeline.ColorTargetState{
        .{ .format = vk.VK_FORMAT_UNDEFINED },
        .{ .format = vk.VK_FORMAT_R8G8B8A8_UNORM },
    };
    var descriptor: pipeline.RenderPipelineDescriptor = .{
        .compatible_render_pass = pass.render_pass,
        .layout = try layout.input(&guard),
        .vertex = .{
            .module = shaders.vertex.native.vk_module,
            .entry_point = graphics_fixture.entry_point,
            .stage = .vertex,
            .content_bytes = std.mem.sliceAsBytes(shaders.vertex.words),
        },
        .fragment = .{
            .module = shaders.fragment.native.vk_module,
            .entry_point = graphics_fixture.entry_point,
            .stage = .fragment,
            .content_bytes = std.mem.sliceAsBytes(shaders.fragment.words),
        },
        .color_targets = &targets,
    };
    const first = try pipeline.createRenderPipelineLocked(
        f.allocator,
        f.threaded.io(),
        &guard,
        &f.device.core,
        &context.pipeline_store.?,
        &context.pipeline_backend,
        descriptor,
        .user,
    );
    defer releaseLow(&f, &guard, first);
    const low = try f.device.core.resolve(&guard, pipeline.Pipeline, first);
    try t.expect(low.vk_pipeline != null);
    try t.expectEqual(@as(usize, 2), low.state.render.color_formats.items.len);
    try t.expectEqual(@as(vk.VkFormat, vk.VK_FORMAT_UNDEFINED), low.state.render.color_formats.items[0]);
    try t.expectEqual(@as(u32, 0), low.state.render.color_write_masks.items[0]);
    try t.expect(!low.state.render.blend_enabled.items[0]);
    var ignored_hole_state = targets;
    ignored_hole_state[0].write_mask = 0;
    ignored_hole_state[0].blend = .{
        .color = .{ .src_factor = .one, .dst_factor = .zero, .operation = .add },
        .alpha = .{ .src_factor = .one, .dst_factor = .zero, .operation = .add },
    };
    descriptor.color_targets = &ignored_hole_state;
    const hit = try pipeline.createRenderPipelineLocked(
        f.allocator,
        f.threaded.io(),
        &guard,
        &f.device.core,
        &context.pipeline_store.?,
        &context.pipeline_backend,
        descriptor,
        .user,
    );
    defer releaseLow(&f, &guard, hit);
    try t.expectEqual(first.ptr, hit.ptr);
}

test "physically compatible canonical owners with the same token remain distinct cache identities" {
    inline for (.{ pipeline.Kind.compute, pipeline.Kind.render }) |kind| {
        var f: Fixture = .{};
        try f.init(t.allocator);
        defer f.deinit();
        const shaders = try Shaders.create(&f);
        defer shaders.deinit(&f);
        const initial = try f.device.createPipelineLayout(
            f.allocator,
            f.threaded.io(),
            .{ .groups = &.{} },
        );
        defer f.device.release(f.allocator, f.threaded.io(), initial) catch
            @panic("initial layout release failed");
        var guard = core.ObjectGuard.lockUncancelable(
            f.threaded.io(),
            f.device.core.arena.objectList(),
        );
        defer guard.unlock(f.threaded.io());
        const left = try makeLayout(&f, &guard, 11);
        defer left.header.releaseUserLocked(&guard, f.threaded.io()) catch
            @panic("left layout release failed");
        // The genuine uncached resource factory creates another actual owner,
        // while using the same arena, native device, groups and compatibility token.
        var uncached_device = f.device.native.?.resourceDevice();
        uncached_device.resource_store = null;
        const right = try resources.createPipelineLayout(
            f.allocator,
            f.threaded.io(),
            &guard,
            &f.device.core.arena,
            uncached_device,
            .{ .groups = left.groups, .compatibility_token = 11 },
        );
        defer right.header.releaseUserLocked(&guard, f.threaded.io()) catch
            @panic("right layout release failed");
        try t.expect(left != right);
        const backend = &f.device.native.?.pipeline_backend;
        const left_input = try left.input(&guard);
        const right_input = try right.input(&guard);
        const first = try createLow(&f, &guard, shaders, kind, left_input, backend);
        defer releaseLow(&f, &guard, first);
        const second = try createLow(&f, &guard, shaders, kind, right_input, backend);
        defer releaseLow(&f, &guard, second);
        try t.expect(first.ptr != second.ptr);
        const left_low = try f.device.core.resolve(&guard, pipeline.Pipeline, first);
        const right_low = try f.device.core.resolve(&guard, pipeline.Pipeline, second);
        try t.expect(left_low.compatibleForGroup(&guard, right_low, 0));
        try t.expectEqual(&left.header, left_low.canonical_layout_header.?);
        try t.expectEqual(&right.header, right_low.canonical_layout_header.?);
        const hit = try createLow(&f, &guard, shaders, kind, left_input, backend);
        defer releaseLow(&f, &guard, hit);
        try t.expectEqual(first.ptr, hit.ptr);
        try t.expectEqual(@as(u32, 2), left.header.reference_count);
        try t.expectEqual(@as(u32, 2), right.header.reference_count);
    }
}
