//! Derived-root admission uses actual arena payloads and real native buffer factories.
const std = @import("std");
const dusk = @import("dusk");
const core = dusk.core;
const engine = dusk.engine;
const native = engine.native_resources;
const attachment = dusk.command.attachment_state;
const t = std.testing;
const maximum_roots = 32;

const ArenaFixture = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    device: core.Device,
    guard: core.ObjectGuard,
    states: [maximum_roots]*attachment.CanonicalAttachmentState = undefined,
    user_aliases: [maximum_roots]bool = @splat(false),
    state_count: usize = 0,

    fn init(self: *ArenaFixture, allocator: std.mem.Allocator, count: usize) !void {
        std.debug.assert(count <= maximum_roots);
        self.* = .{ .allocator = allocator, .device = undefined, .guard = undefined };
        self.device = core.Device.init(allocator, .{
            .object_mutex = &self.mutex,
            .uncaptured_context = self,
            .uncaptured_callback = unexpectedError,
        });
        self.guard = core.ObjectGuard.lockUncancelable(t.io, self.device.borrow().objects);
        self.device.bindTrackingOwner(&self.guard, self);
        errdefer self.deinit();
        const value = try attachment.AttachmentState.fromRenderPipeline(.{
            .color_formats = &.{@intFromEnum(dusk.api.TextureFormat.rgba8_unorm)},
            .depth_stencil_format = 0,
            .sample_count = 1,
            .expand_resolve = .{},
            .pls = null,
        }, .{
            .max_color_attachments = 8,
            .max_storage_attachments = 4,
            .max_pls_bytes = 16,
        });
        for (0..count) |index| {
            const state = try self.device.create(allocator, &self.guard, attachment.CanonicalAttachmentState, .{ .kind = .attachment_state, .initial_reference = .user });
            state.value = value;
            state.cache_hash = 0;
            state.cache_next = null;
            state.header.attach(&self.guard, t.io);
            self.states[index] = state;
            self.user_aliases[index] = true;
            self.state_count += 1;
        }
    }

    fn releaseUser(self: *ArenaFixture, index: usize) void {
        std.debug.assert(self.user_aliases[index]);
        self.states[index].header.releaseUserLocked(&self.guard, t.io) catch
            @panic("attachment alias release failed");
        self.user_aliases[index] = false;
    }

    fn deinit(self: *ArenaFixture) void {
        for (0..self.state_count) |index| {
            if (self.user_aliases[index]) self.releaseUser(index);
        }
        self.device.deinit(self.allocator, &self.guard) catch
            @panic("derived-root fixture leaked references");
        self.guard.unlock(t.io);
    }
};

fn unexpectedError(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
    @panic("derived-root fixture reported an uncaptured error");
}

test "derived root appends after empty declared preparation and owns the final lease" {
    var fixture: ArenaFixture = undefined;
    try fixture.init(t.allocator, 1);
    defer fixture.deinit();
    var pending = try native.PendingUses.prepareDeclaredLocked(t.allocator, &fixture.guard, &fixture.device, &.{});
    defer pending.releaseLocked(&fixture.guard, t.io);
    try t.expect(pending.leased);
    try t.expectEqual(@as(u32, 0), pending.roots.count());
    const root = &fixture.states[0].header;
    try pending.retainDerivedRootLocked(&fixture.guard, &fixture.device, root);
    try t.expect(pending.roots.contains(root));
    try t.expectEqual(@as(u32, 2), root.reference_count);
    try t.expectEqual(@as(u32, 1), root.user_reference_count);
    fixture.releaseUser(0);
    try t.expectEqual(core.ObjectState.alive, root.state);
    try t.expectEqual(@as(u32, 1), root.reference_count);
    try t.expectEqual(@as(u32, 0), root.user_reference_count);
    try t.expectEqual(@as(u64, 1), fixture.guard.objects.total_reference_count);
    try t.expectEqual(@as(u64, 0), fixture.guard.objects.user_reference_count);
    pending.releaseLocked(&fixture.guard, t.io);
    try t.expect(!pending.leased);
    try t.expectEqual(@as(u32, 0), pending.roots.count());
    try t.expectEqual(core.ObjectState.destroyed, root.state);
    try t.expectEqual(@as(u32, 0), root.reference_count);
    try t.expect(!root.node.linked);
    try t.expectEqual(@as(u64, 0), fixture.guard.objects.total_reference_count);
}

test "derived duplicate is a no-op even when reference headroom is exhausted" {
    var failing = t.FailingAllocator.init(t.allocator, .{});
    const allocator = failing.allocator();
    var fixture: ArenaFixture = undefined;
    try fixture.init(allocator, 1);
    defer fixture.deinit();
    var pending = try native.PendingUses.prepareDeclaredLocked(allocator, &fixture.guard, &fixture.device, &.{});
    defer pending.releaseLocked(&fixture.guard, t.io);
    const root = &fixture.states[0].header;
    try pending.retainDerivedRootLocked(&fixture.guard, &fixture.device, root);
    const allocations = failing.alloc_index;
    const object_references = root.reference_count;
    const total_references = fixture.guard.objects.total_reference_count;
    {
        root.reference_count = std.math.maxInt(u32);
        defer root.reference_count = object_references;
        fixture.guard.objects.total_reference_count = std.math.maxInt(u64);
        defer fixture.guard.objects.total_reference_count = total_references;
        failing.fail_index = failing.alloc_index;
        defer failing.fail_index = std.math.maxInt(usize);
        try pending.retainDerivedRootLocked(&fixture.guard, &fixture.device, root);
        try t.expectEqual(allocations, failing.alloc_index);
        try t.expectEqual(@as(u32, 1), pending.roots.count());
        try t.expectEqual(std.math.maxInt(u32), root.reference_count);
        try t.expectEqual(std.math.maxInt(u64), fixture.guard.objects.total_reference_count);
        try t.expectEqual(@as(u32, 1), root.user_reference_count);
        try t.expectEqual(@as(u64, 1), fixture.guard.objects.user_reference_count);
    }
    try t.expectEqual(@as(u32, 2), root.reference_count);
    try t.expectEqual(@as(u64, 2), fixture.guard.objects.total_reference_count);
}

test "derived earlier root survives a later object reference overflow" {
    var fixture: ArenaFixture = undefined;
    try fixture.init(t.allocator, 2);
    defer fixture.deinit();
    var pending = try native.PendingUses.prepareDeclaredLocked(t.allocator, &fixture.guard, &fixture.device, &.{});
    defer pending.releaseLocked(&fixture.guard, t.io);
    const earlier = &fixture.states[0].header;
    const later = &fixture.states[1].header;
    try pending.retainDerivedRootLocked(&fixture.guard, &fixture.device, earlier);
    const total = fixture.guard.objects.total_reference_count;
    {
        const references = later.reference_count;
        later.reference_count = std.math.maxInt(u32);
        defer later.reference_count = references;
        try t.expectError(error.ReferenceCountOverflow, pending.retainDerivedRootLocked(&fixture.guard, &fixture.device, later));
        try t.expectEqual(std.math.maxInt(u32), later.reference_count);
        try t.expectEqual(@as(u32, 1), later.user_reference_count);
        try t.expectEqual(total, fixture.guard.objects.total_reference_count);
        try t.expectEqual(@as(u32, 2), earlier.reference_count);
        try t.expect(pending.roots.contains(earlier));
        try t.expect(!pending.roots.contains(later));
        try t.expectEqual(@as(u32, 1), pending.roots.count());
    }
    try pending.retainDerivedRootLocked(&fixture.guard, &fixture.device, later);
    try t.expectEqual(@as(u32, 2), pending.roots.count());
    pending.releaseLocked(&fixture.guard, t.io);
    try t.expectEqual(@as(u32, 1), earlier.reference_count);
    try t.expectEqual(@as(u32, 1), later.reference_count);
    try t.expectEqual(@as(u64, 2), fixture.guard.objects.total_reference_count);
}

test "derived earlier root survives a later aggregate reference overflow" {
    var failing = t.FailingAllocator.init(t.allocator, .{});
    const allocator = failing.allocator();
    var fixture: ArenaFixture = undefined;
    try fixture.init(allocator, 2);
    defer fixture.deinit();
    var pending = try native.PendingUses.prepareDeclaredLocked(allocator, &fixture.guard, &fixture.device, &.{});
    defer pending.releaseLocked(&fixture.guard, t.io);
    const earlier = &fixture.states[0].header;
    const later = &fixture.states[1].header;
    try pending.retainDerivedRootLocked(&fixture.guard, &fixture.device, earlier);
    const allocations = failing.alloc_index;
    const total = fixture.guard.objects.total_reference_count;
    {
        fixture.guard.objects.total_reference_count = std.math.maxInt(u64);
        defer fixture.guard.objects.total_reference_count = total;
        try t.expectError(error.ReferenceCountOverflow, pending.retainDerivedRootLocked(&fixture.guard, &fixture.device, later));
        try t.expectEqual(allocations, failing.alloc_index);
        try t.expectEqual(std.math.maxInt(u64), fixture.guard.objects.total_reference_count);
        try t.expectEqual(@as(u64, 2), fixture.guard.objects.user_reference_count);
        try t.expectEqual(@as(u32, 2), earlier.reference_count);
        try t.expectEqual(@as(u32, 1), later.reference_count);
        try t.expect(pending.roots.contains(earlier));
        try t.expect(!pending.roots.contains(later));
        try t.expectEqual(@as(u32, 1), pending.roots.count());
    }
    try pending.retainDerivedRootLocked(&fixture.guard, &fixture.device, later);
    try t.expectEqual(total + 1, fixture.guard.objects.total_reference_count);
    pending.releaseLocked(&fixture.guard, t.io);
    try t.expectEqual(@as(u32, 1), earlier.reference_count);
    try t.expectEqual(@as(u32, 1), later.reference_count);
}

test "derived root rejects a foreign original owner without changing either device" {
    var local: ArenaFixture = undefined;
    try local.init(t.allocator, 1);
    defer local.deinit();
    var foreign: ArenaFixture = undefined;
    try foreign.init(t.allocator, 1);
    defer foreign.deinit();
    var pending = try native.PendingUses.prepareDeclaredLocked(t.allocator, &local.guard, &local.device, &.{});
    defer pending.releaseLocked(&local.guard, t.io);
    const earlier = &local.states[0].header;
    const rejected = &foreign.states[0].header;
    try pending.retainDerivedRootLocked(&local.guard, &local.device, earlier);
    try t.expectError(error.ResourceDeviceMismatch, pending.retainDerivedRootLocked(&local.guard, &local.device, rejected));
    try t.expectEqual(@as(u32, 1), pending.roots.count());
    try t.expect(pending.roots.contains(earlier));
    try t.expect(!pending.roots.contains(rejected));
    try t.expectEqual(@as(u32, 2), earlier.reference_count);
    try t.expectEqual(@as(u32, 1), rejected.reference_count);
    try t.expectEqual(@as(u64, 2), local.guard.objects.total_reference_count);
    try t.expectEqual(@as(u64, 1), foreign.guard.objects.total_reference_count);
    try t.expectEqual(@as(u64, 1), local.guard.objects.user_reference_count);
    try t.expectEqual(@as(u64, 1), foreign.guard.objects.user_reference_count);
}

test "derived root rejects an explicitly destroyed actual attachment" {
    var fixture: ArenaFixture = undefined;
    try fixture.init(t.allocator, 2);
    defer fixture.deinit();
    var pending = try native.PendingUses.prepareDeclaredLocked(t.allocator, &fixture.guard, &fixture.device, &.{});
    defer pending.releaseLocked(&fixture.guard, t.io);
    const earlier = &fixture.states[0].header;
    const rejected = &fixture.states[1].header;
    try pending.retainDerivedRootLocked(&fixture.guard, &fixture.device, earlier);
    rejected.retirePayloadLocked(&fixture.guard, t.io, .early_destroy);
    try t.expectEqual(core.ObjectState.destroyed, rejected.state);
    try t.expectError(error.ResourceDestroyed, pending.retainDerivedRootLocked(&fixture.guard, &fixture.device, rejected));
    try t.expectEqual(@as(u32, 1), pending.roots.count());
    try t.expect(pending.roots.contains(earlier));
    try t.expect(!pending.roots.contains(rejected));
    try t.expectEqual(@as(u32, 2), earlier.reference_count);
    try t.expectEqual(@as(u32, 1), rejected.reference_count);
    try t.expectEqual(@as(u64, 3), fixture.guard.objects.total_reference_count);
    try t.expectEqual(@as(u64, 2), fixture.guard.objects.user_reference_count);
}

test "derived map fail N retains earlier roots and leaks no refused lease" {
    try t.checkAllAllocationFailures(t.allocator, appendRootsFailN, .{});
}

fn appendRootsFailN(allocator: std.mem.Allocator) !void {
    var fixture: ArenaFixture = undefined;
    try fixture.init(allocator, maximum_roots);
    defer fixture.deinit();
    var pending = try native.PendingUses.prepareDeclaredLocked(allocator, &fixture.guard, &fixture.device, &.{});
    defer {
        pending.releaseLocked(&fixture.guard, t.io);
        for (fixture.states[0..fixture.state_count]) |state| {
            t.expectEqual(@as(u32, 1), state.header.reference_count) catch
                @panic("failed append leaked a root lease");
        }
        t.expectEqual(@as(u64, maximum_roots), fixture.guard.objects.total_reference_count) catch
            @panic("failed append leaked aggregate references");
    }
    for (fixture.states[0..fixture.state_count], 0..) |state, index| {
        const root = &state.header;
        pending.retainDerivedRootLocked(&fixture.guard, &fixture.device, root) catch |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(@as(u32, @intCast(index)), pending.roots.count());
            try t.expect(!pending.roots.contains(root));
            try t.expectEqual(@as(u32, 1), root.reference_count);
            try t.expectEqual(@as(u32, 1), root.user_reference_count);
            try t.expectEqual(@as(u64, maximum_roots + index), fixture.guard.objects.total_reference_count);
            for (fixture.states[0..index]) |earlier| {
                try t.expect(pending.roots.contains(&earlier.header));
                try t.expectEqual(@as(u32, 2), earlier.header.reference_count);
                try t.expectEqual(@as(u32, 1), earlier.header.user_reference_count);
            }
            return err;
        };
        try t.expectEqual(@as(u32, @intCast(index + 1)), pending.roots.count());
        try t.expectEqual(@as(u32, 2), root.reference_count);
        try t.expectEqual(@as(u64, maximum_roots + index + 1), fixture.guard.objects.total_reference_count);
    }
}

const NativeFixture = struct {
    threaded: std.Io.Threaded = undefined,
    instance: engine.Instance = undefined,
    adapters: engine.AdapterList = undefined,
    device: engine.Device = undefined,

    fn init(self: *NativeFixture) !void {
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
            .uncaptured_context = self,
            .uncaptured_callback = unexpectedError,
        });
    }

    fn deinit(self: *NativeFixture) void {
        const io = self.threaded.io();
        self.device.deinit(t.allocator, io) catch @panic("native device teardown failed");
        self.adapters.deinit(io) catch @panic("adapter teardown failed");
        self.instance.deinit(t.allocator, io) catch @panic("instance teardown failed");
        self.threaded.deinit();
    }

    fn release(self: *NativeFixture, resource: *native.Buffer) void {
        self.device.release(t.allocator, self.threaded.io(), resource) catch
            @panic("native buffer alias release failed");
    }
};

test "derived actual native buffer validates mapping and classifies one queue lease" {
    var fixture: NativeFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const resource = try fixture.device.createBuffer(t.allocator, io, .{
        .size = 16,
        .usage = .{ .copy_src = true, .copy_dst = true },
    });
    defer fixture.release(resource);
    const mapped = try fixture.device.createBuffer(t.allocator, io, .{
        .size = 16,
        .usage = .{ .map_write = true, .copy_src = true },
        .mapped_at_creation = true,
    });
    defer fixture.release(mapped);
    var queue_lease = try fixture.device.getQueue(io);
    defer queue_lease.deinit(io);
    var guard = core.ObjectGuard.lockUncancelable(io, fixture.device.core.arena.objectList());
    defer guard.unlock(io);
    var pending = try native.PendingUses.prepareDeclaredLocked(t.allocator, &guard, &fixture.device.core, &.{});
    defer pending.releaseLocked(&guard, io);
    const total = guard.objects.total_reference_count;
    try t.expectEqual(engine.buffer.State.mapped_at_creation, mapped.native.state);
    try t.expectError(error.BufferUseWhileMapped, pending.retainDerivedRootLocked(&guard, &fixture.device.core, &mapped.header));
    try t.expectEqual(@as(u32, 0), pending.roots.count());
    try t.expectEqual(@as(u32, 1), mapped.header.reference_count);
    try t.expectEqual(@as(u32, 0), mapped.queue_uses);
    try t.expectEqual(total, guard.objects.total_reference_count);
    try t.expectEqual(engine.buffer.State.unmapped, resource.native.state);
    try pending.retainDerivedRootLocked(&guard, &fixture.device.core, &resource.header);
    try t.expectEqual(@as(u32, 2), resource.header.reference_count);
    try t.expectEqual(@as(u32, 1), resource.header.user_reference_count);
    try t.expectEqual(@as(u32, 1), resource.queue_uses);
    try t.expectEqual(@as(u32, 0), resource.mapping_leases);
    try t.expectEqual(@as(engine.buffer.Serial, 0), resource.accepted_usage_serial);
    try pending.retainDerivedRootLocked(&guard, &fixture.device.core, &resource.header);
    try t.expectEqual(@as(u32, 1), pending.roots.count());
    try t.expectEqual(@as(u32, 2), resource.header.reference_count);
    try t.expectEqual(@as(u32, 1), resource.queue_uses);
    resource.header.retirePayloadLocked(&guard, io, .early_destroy);
    try t.expectEqual(core.ObjectState.destroyed, resource.header.state);
    try t.expectEqual(engine.buffer.State.destroyed, resource.native.state);
    try t.expect(resource.native_retirement_pending);
    try t.expectEqual(@as(u32, 1), resource.queue_uses);
    try t.expectError(error.ResourceDestroyed, pending.retainDerivedRootLocked(&guard, &fixture.device.core, &resource.header));
    try t.expectEqual(@as(u32, 1), pending.roots.count());
    try t.expectEqual(@as(u32, 2), resource.header.reference_count);
    try t.expectEqual(@as(u32, 1), resource.queue_uses);
    pending.releaseLocked(&guard, io);
    try t.expectEqual(@as(u32, 0), resource.queue_uses);
    try t.expectEqual(@as(u32, 1), resource.header.reference_count);
    try t.expect(!resource.native_retirement_pending);
    try t.expect(resource.cleanup_error == null);
    try t.expectEqual(@as(engine.buffer.Serial, 0), resource.accepted_usage_serial);
    try t.expectEqual(total, guard.objects.total_reference_count);
}
