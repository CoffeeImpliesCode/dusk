//! Render-bundle recording and immutable core-arena bundle payloads.
//! Finish returns one user alias. Release its header under the original guard.
//! Bundle cursors borrow storage. They do not retain the bundle or attachment.

const std = @import("std");
const commands = @import("commands.zig");
const allocator_mod = @import("allocator.zig");
const encoding_context = @import("encoding_context.zig");
const render = @import("render_encoder_base.zig");
const programmable = @import("programmable_encoder.zig");
const constants = @import("constants.zig");
const errors = @import("errors.zig");
const usage = @import("usage.zig");
const indirect_draw = @import("indirect_draw.zig");
const state_tracker = @import("state_tracker.zig");
const core = @import("../core/root.zig");
const attachment = @import("attachment_state.zig");

const BundleFixture = struct {
    const Pipeline = struct {
        header: core.Object,

        pub fn destroy(
            self: *@This(),
            guard: *const core.ObjectGuard,
            io: std.Io,
            reason: core.DestroyReason,
        ) void {
            guard.assertOwns(self.header.tracking);
            _ = io;
            _ = reason;
        }
    };

    fn uncaptured(
        allocator: std.mem.Allocator,
        io: std.Io,
        context: *anyopaque,
        data: core.ErrorView,
    ) void {
        _ = allocator;
        _ = io;
        _ = context;
        _ = data;
        @panic("unexpected fixture error");
    }

    fn init(allocator: std.mem.Allocator, mutex: *std.Io.Mutex) core.Device {
        return core.Device.init(allocator, .{
            .object_mutex = mutex,
            .uncaptured_context = mutex,
            .uncaptured_callback = uncaptured,
        });
    }

    fn state(
        allocator: std.mem.Allocator,
        device: *core.Device,
        guard: *const core.ObjectGuard,
    ) !*attachment.CanonicalAttachmentState {
        const result = try device.create(
            allocator,
            guard,
            attachment.CanonicalAttachmentState,
            .{ .kind = .attachment_state, .initial_reference = .user },
        );
        result.value = .{};
        result.cache_hash = 0;
        result.cache_next = null;
        result.header.attach(guard, std.testing.io);
        return result;
    }

    fn pipeline(
        allocator: std.mem.Allocator,
        device: *core.Device,
        guard: *const core.ObjectGuard,
    ) !*Pipeline {
        const result = try device.create(allocator, guard, Pipeline, .{
            .kind = .pipeline,
            .initial_reference = .user,
        });
        result.header.attach(guard, std.testing.io);
        return result;
    }
};

test "arena bundle moves one lease and independent cursors survive encoder cleanup" {
    var mutex: std.Io.Mutex = .init;
    var device = BundleFixture.init(std.testing.allocator, &mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    const state = try BundleFixture.state(std.testing.allocator, &device, &guard);
    const pipeline = try BundleFixture.pipeline(std.testing.allocator, &device, &guard);
    defer pipeline.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    var encoder = try RenderBundleEncoder.init(
        std.testing.allocator,
        std.testing.io,
        &guard,
        &device,
        state,
        .{},
    );
    defer encoder.deinit(std.testing.io, &guard);
    try std.testing.expectEqual(@as(u32, 2), state.header.reference_count);
    try encoder.setPipeline(&guard, .{
        .pipeline = &pipeline.header,
        .requirements = .{},
        .attachment_state = state,
    });
    try encoder.draw(.{
        .vertex_count = 3,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
    const bundle = try encoder.finish(std.testing.io, &guard);
    defer bundle.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    try std.testing.expectEqual(core.Handle.Kind.render_bundle, bundle.header.kind);
    try std.testing.expectEqual(@as(commands.Ref, &bundle.header), try bundle.ref(&guard));
    try std.testing.expectEqual(state, bundle.attachmentState());
    try std.testing.expectEqual(@as(u32, 2), state.header.reference_count);
    try state.header.releaseUserLocked(&guard, std.testing.io);
    encoder.deinit(std.testing.io, &guard);
    encoder.deinit(std.testing.io, &guard);
    try std.testing.expect(state.header.isAlive(&guard));
    try std.testing.expectEqual(@as(u32, 1), state.header.reference_count);
    var first = bundle.iterator(&guard);
    var second = bundle.iterator(&guard);
    defer second.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, .set_render_pipeline), try first.nextTag());
    try std.testing.expectEqual(@as(commands.Ref, &pipeline.header), (try first.nextCommand(commands.SetRenderPipelineCmd)).pipeline);
    first.deinit();
    first.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, null), try first.nextTag());
    try std.testing.expectEqual(@as(?commands.Tag, .set_render_pipeline), try second.nextTag());
    _ = try second.nextCommand(commands.SetRenderPipelineCmd);
    try std.testing.expectEqual(@as(?commands.Tag, .draw), try second.nextTag());
    try std.testing.expectEqual(@as(u32, 3), (try second.nextCommand(commands.DrawCmd)).vertex_count);
    try std.testing.expectEqual(@as(?commands.Tag, null), try second.nextTag());
}

test "bundle closure failure keeps ownership and successful finish rejects a second move" {
    var mutex: std.Io.Mutex = .init;
    var device = BundleFixture.init(std.testing.allocator, &mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    const state = try BundleFixture.state(std.testing.allocator, &device, &guard);
    defer state.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    var encoder = try RenderBundleEncoder.init(
        std.testing.allocator,
        std.testing.io,
        &guard,
        &device,
        state,
        .{},
    );
    defer encoder.deinit(std.testing.io, &guard);
    try std.testing.expectError(error.MissingPipeline, encoder.draw(.{
        .vertex_count = 3,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    }));
    try encoder.pushDebugGroup("bundle");
    try std.testing.expectError(error.DebugGroupUnbalanced, encoder.finish(std.testing.io, &guard));
    try std.testing.expectEqual(@as(u32, 2), state.header.reference_count);
    try encoder.popDebugGroup();
    const bundle = try encoder.finish(std.testing.io, &guard);
    defer bundle.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    try std.testing.expectError(error.EncoderAlreadyFinished, encoder.finish(std.testing.io, &guard));
    try std.testing.expectError(error.EncoderAlreadyFinished, encoder.insertDebugMarker("late"));
}

test "final bundle alias destroys command storage and its attachment lease once" {
    var mutex: std.Io.Mutex = .init;
    var device = BundleFixture.init(std.testing.allocator, &mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    const state = try BundleFixture.state(std.testing.allocator, &device, &guard);
    var encoder = try RenderBundleEncoder.init(
        std.testing.allocator,
        std.testing.io,
        &guard,
        &device,
        state,
        .{},
    );
    defer encoder.deinit(std.testing.io, &guard);
    try encoder.insertDebugMarker("owned");
    const bundle = try encoder.finish(std.testing.io, &guard);
    try state.header.releaseUserLocked(&guard, std.testing.io);
    try bundle.header.retainUserLocked(&guard);
    try bundle.header.releaseUserLocked(&guard, std.testing.io);
    try std.testing.expect(bundle.header.isAlive(&guard));
    try std.testing.expectError(error.ResourceInUse, device.deinit(std.testing.allocator, &guard));
    try bundle.header.releaseUserLocked(&guard, std.testing.io);
    try std.testing.expect(!bundle.header.isAlive(&guard));
    try std.testing.expect(!state.header.isAlive(&guard));
    try std.testing.expectEqual(@as(usize, 0), bundle.blocks.items.len);
    try std.testing.expect(bundle.resource_usage.attachment_state == null);
    try std.testing.expectError(error.BundleDestroyed, bundle.ref(&guard));
    try std.testing.expectError(error.NoOwnedReference, bundle.header.releaseUserLocked(&guard, std.testing.io));
}

fn testBundleAllocations(allocator: std.mem.Allocator) !void {
    var mutex: std.Io.Mutex = .init;
    var device = BundleFixture.init(allocator, &mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(allocator, &guard) catch @panic("references leaked");
    const state = try BundleFixture.state(allocator, &device, &guard);
    defer state.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    const resource = try BundleFixture.pipeline(allocator, &device, &guard);
    defer resource.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    var encoder = try RenderBundleEncoder.init(
        allocator,
        std.testing.io,
        &guard,
        &device,
        state,
        .{},
    );
    defer encoder.deinit(std.testing.io, &guard);
    try encoder.setPipeline(&guard, .{
        .pipeline = &resource.header,
        .requirements = .{},
        .attachment_state = state,
    });
    try encoder.setBindGroup(.{
        .index = 0,
        .group = &resource.header,
        .dynamic_offset_count = 2,
        .dynamic_offsets = &.{ 0, 4 },
        .buffers = &.{.{ .buffer = &resource.header, .usage = 64 }},
    });
    try encoder.drawIndirect(.{
        .indirect_buffer = &resource.header,
        .indirect_buffer_size = 16,
        .indirect_offset = 0,
    });
    const bundle = try encoder.finish(std.testing.io, &guard);
    defer bundle.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    try std.testing.expectEqual(@as(usize, 1), bundle.indirect.draws.items.len);
    try std.testing.expectEqual(@as(usize, 1), bundle.resource_usage.scope.buffers.items.len);
    var cursor = bundle.iterator(&guard);
    defer cursor.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, .set_render_pipeline), try cursor.nextTag());
    _ = try cursor.nextCommand(commands.SetRenderPipelineCmd);
    try std.testing.expectEqual(@as(?commands.Tag, .set_bind_group), try cursor.nextTag());
    const group = try cursor.nextCommand(commands.SetBindGroupCmd);
    try std.testing.expectEqualSlices(u32, &.{ 0, 4 }, try cursor.nextData(u32, group.dynamic_offset_count));
    try std.testing.expectEqual(@as(?commands.Tag, .draw_indirect), try cursor.nextTag());
    _ = try cursor.nextCommand(commands.DrawIndirectCmd);
    try std.testing.expectEqual(@as(?commands.Tag, null), try cursor.nextTag());
}

test "bundle allocation failures preserve exactly one owner for every field" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testBundleAllocations, .{});
}

test "bundle producer refuses another device before acquiring its attachment lease" {
    var mutex: std.Io.Mutex = .init;
    var other_mutex: std.Io.Mutex = .init;
    var device = BundleFixture.init(std.testing.allocator, &mutex);
    var other = BundleFixture.init(std.testing.allocator, &other_mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var other_guard = core.ObjectGuard.lockUncancelable(std.testing.io, other.arena.objectList());
    defer other_guard.unlock(std.testing.io);
    defer other.deinit(std.testing.allocator, &other_guard) catch @panic("references leaked");
    const state = try BundleFixture.state(std.testing.allocator, &other, &other_guard);
    defer state.header.releaseUserLocked(&other_guard, std.testing.io) catch @panic("bad alias");
    try std.testing.expectError(error.ResourceDeviceMismatch, RenderBundleEncoder.init(
        std.testing.allocator,
        std.testing.io,
        &guard,
        &device,
        state,
        .{},
    ));
    try std.testing.expectEqual(@as(u32, 1), state.header.reference_count);
}

test "bundle finish reference refusal leaves command blocks and attachment ownership intact" {
    var mutex: std.Io.Mutex = .init;
    var device = BundleFixture.init(std.testing.allocator, &mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    const state = try BundleFixture.state(std.testing.allocator, &device, &guard);
    defer state.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    var encoder = try RenderBundleEncoder.init(
        std.testing.allocator,
        std.testing.io,
        &guard,
        &device,
        state,
        .{},
    );
    defer encoder.deinit(std.testing.io, &guard);
    try encoder.insertDebugMarker("preserved");
    const blocks_pointer = encoder.context.?.pending.blocks.items.ptr;
    const references = device.arena.objects.total_reference_count;
    device.arena.objects.total_reference_count = std.math.maxInt(u64);
    const result = encoder.finish(std.testing.io, &guard);
    device.arena.objects.total_reference_count = references;
    try std.testing.expectError(error.ReferenceCountOverflow, result);
    try std.testing.expectEqual(blocks_pointer, encoder.context.?.pending.blocks.items.ptr);
    try std.testing.expectEqual(@as(u32, 2), state.header.reference_count);
    const bundle = try encoder.finish(std.testing.io, &guard);
    defer bundle.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    try std.testing.expectEqual(state, bundle.attachmentState());
}

test "bundle finish rejects excessive draws without moving its usage" {
    var mutex: std.Io.Mutex = .init;
    var device = BundleFixture.init(std.testing.allocator, &mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    const state = try BundleFixture.state(std.testing.allocator, &device, &guard);
    defer state.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    const pipeline = try BundleFixture.pipeline(std.testing.allocator, &device, &guard);
    defer pipeline.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    var encoder = try RenderBundleEncoder.init(
        std.testing.allocator,
        std.testing.io,
        &guard,
        &device,
        state,
        .{ .max_draw_count = 0 },
    );
    defer encoder.deinit(std.testing.io, &guard);
    try encoder.setPipeline(&guard, .{
        .pipeline = &pipeline.header,
        .requirements = .{},
        .attachment_state = state,
    });
    try encoder.draw(.{
        .vertex_count = 0,
        .instance_count = 0,
        .first_vertex = 0,
        .first_instance = 0,
    });
    try std.testing.expectError(error.DrawCountExceeded, encoder.finish(std.testing.io, &guard));
    try std.testing.expectEqual(state, encoder.base.usage.usage.attachment_state.?);
}

test "bundle retains owned texture validation snapshots" {
    var mutex: std.Io.Mutex = .init;
    var device = BundleFixture.init(std.testing.allocator, &mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    const state = try BundleFixture.state(std.testing.allocator, &device, &guard);
    defer state.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    const resource = try BundleFixture.pipeline(std.testing.allocator, &device, &guard);
    defer resource.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    var encoder = try RenderBundleEncoder.init(
        std.testing.allocator,
        std.testing.io,
        &guard,
        &device,
        state,
        .{ .compatibility_mode = true },
    );
    defer encoder.deinit(std.testing.io, &guard);
    var bindings = [_]state_tracker.TextureBinding{
        .{ .texture = &resource.header, .view = &resource.header, .slot = 0 },
        .{ .texture = &resource.header, .view = &resource.header, .slot = 1 },
    };
    try encoder.setPipeline(&guard, .{
        .pipeline = &resource.header,
        .requirements = .{},
        .attachment_state = state,
    });
    try encoder.setBindGroup(.{
        .index = 0,
        .group = &resource.header,
        .texture_bindings = &bindings,
    });
    bindings[1].view = &state.header;
    try encoder.draw(.{
        .vertex_count = 0,
        .instance_count = 0,
        .first_vertex = 0,
        .first_instance = 0,
    });
    const bundle = try encoder.finish(std.testing.io, &guard);
    defer bundle.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    try std.testing.expectEqual(@as(u64, 1), bundle.draw_count);
}

test "bundle preserves allocation failure when a callback destroys its encoder" {
    const DestroyOnAllocation = struct {
        encoder: *RenderBundleEncoder = undefined,
        guard: *const core.ObjectGuard = undefined,
        armed: bool = false,
        fired: bool = false,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = alloc,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = free,
            } };
        }

        fn alloc(pointer: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            if (self.armed) {
                self.armed = false;
                self.fired = true;
                self.encoder.deinit(std.testing.io, self.guard);
                return null;
            }
            return std.testing.allocator.rawAlloc(len, alignment, ret);
        }

        fn free(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
            _ = pointer;
            std.testing.allocator.rawFree(memory, alignment, ret);
        }
    };
    var callback: DestroyOnAllocation = .{};
    const allocator = callback.allocator();
    var mutex: std.Io.Mutex = .init;
    var device = BundleFixture.init(allocator, &mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(allocator, &guard) catch @panic("references leaked");
    const state = try BundleFixture.state(allocator, &device, &guard);
    defer state.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    const resource = try BundleFixture.pipeline(allocator, &device, &guard);
    defer resource.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    var encoder = try RenderBundleEncoder.init(
        allocator,
        std.testing.io,
        &guard,
        &device,
        state,
        .{},
    );
    defer encoder.deinit(std.testing.io, &guard);
    callback.encoder = &encoder;
    callback.guard = &guard;
    try encoder.setPipeline(&guard, .{
        .pipeline = &resource.header,
        .requirements = .{},
        .attachment_state = state,
    });
    callback.armed = true;
    try std.testing.expectError(error.OutOfMemory, encoder.setBindGroup(.{
        .index = 0,
        .group = &resource.header,
        .texture_bindings = &.{.{
            .texture = &resource.header,
            .view = &resource.header,
            .slot = 0,
        }},
    }));
    try std.testing.expect(callback.fired);
    try std.testing.expect(encoder.context == null);
    try std.testing.expect(encoder.finished);
    try std.testing.expectEqual(@as(u32, 1), state.header.reference_count);
    try std.testing.expectError(error.EncoderDestroyed, encoder.finish(std.testing.io, &guard));
}

test "bundle finish rejects a retired canonical payload without moving recorded storage" {
    var mutex: std.Io.Mutex = .init;
    var device = BundleFixture.init(std.testing.allocator, &mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    const state = try BundleFixture.state(std.testing.allocator, &device, &guard);
    defer state.header.releaseUserLocked(&guard, std.testing.io) catch @panic("bad alias");
    var encoder = try RenderBundleEncoder.init(
        std.testing.allocator,
        std.testing.io,
        &guard,
        &device,
        state,
        .{},
    );
    defer encoder.deinit(std.testing.io, &guard);
    try encoder.insertDebugMarker("retired");
    const blocks_pointer = encoder.context.?.pending.blocks.items.ptr;
    state.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
    try std.testing.expectError(error.ResourceDestroyed, encoder.finish(std.testing.io, &guard));
    try std.testing.expectEqual(blocks_pointer, encoder.context.?.pending.blocks.items.ptr);
    try std.testing.expectEqual(@as(u32, 2), state.header.reference_count);
}

/// Immutable arena payload. Pointer copies borrow, and do not acquire user aliases.
/// Its allocator and core device must outlive all references and borrowed cursors.
pub const RenderBundle = struct {
    header: core.Object,
    allocator: std.mem.Allocator,
    blocks: allocator_mod.Blocks,
    draw_count: u64,
    resource_usage: usage.RenderPassResourceUsage,
    indirect: indirect_draw.IndirectDrawMetadata,

    /// Borrows the attachment lease carried by this bundle's resource usage.
    pub fn attachmentState(self: *const RenderBundle) *attachment.CanonicalAttachmentState {
        return self.resource_usage.attachment_state.?;
    }

    /// Borrows the real core header. The caller retains its existing alias or lease.
    pub fn ref(
        self: *const RenderBundle,
        guard: *const core.ObjectGuard,
    ) errors.Error!commands.Ref {
        if (self.header.tracking != guard.objects) return error.ResourceDeviceMismatch;
        guard.assertOwns(self.header.tracking);
        if (self.header.kind != .render_bundle) return error.HandleKindMismatch;
        if (self.header.state != .alive or !self.header.node.linked) return error.BundleDestroyed;
        return @constCast(&self.header);
    }

    /// Borrows immutable blocks. A live bundle owner must outlive every cursor read.
    pub fn iterator(
        self: *const RenderBundle,
        guard: *const core.ObjectGuard,
    ) allocator_mod.BorrowedIterator {
        guard.assertOwns(self.header.tracking);
        std.debug.assert(self.header.kind == .render_bundle);
        std.debug.assert(self.header.state == .alive);
        std.debug.assert(self.header.node.linked);
        return .{ .iterator = allocator_mod.Iterator.init(self.allocator, self.blocks) };
    }

    /// Core invokes this once at payload retirement, under the original guard.
    pub fn destroy(
        self: *RenderBundle,
        guard: *const core.ObjectGuard,
        io: std.Io,
        reason: core.DestroyReason,
    ) void {
        guard.assertOwns(self.header.tracking);
        std.debug.assert(self.header.kind == .render_bundle);
        _ = reason;
        for (self.blocks.items) |block| self.allocator.free(block.bytes);
        self.blocks.deinit(self.allocator);
        self.blocks = .empty;
        self.resource_usage.deinit(io, guard);
        self.indirect.deinit();
    }
};

pub const InitOptions = struct {
    block_size: usize = 4096,
    compatibility_mode: bool = false,
    max_draw_count: u64 = constants.default_max_draw_count,
};

/// A bundle uses the render tracker, but never emits pass boundaries.
pub const RenderBundleEncoder = struct {
    allocator: std.mem.Allocator,
    /// Non-owning final-address locator for publication into the original arena.
    device: *core.Device,
    context: ?*encoding_context.Context,
    base: render.RenderEncoderBase,
    finished: bool = false,
    texture_bindings: [constants.max_bind_groups][]const state_tracker.TextureBinding =
        @splat(&.{}),

    /// Retains one attachment lease. Io and guard are borrowed only for this call.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        guard: *const core.ObjectGuard,
        device: *core.Device,
        state: *attachment.CanonicalAttachmentState,
        options: InitOptions,
    ) errors.Error!RenderBundleEncoder {
        const borrow = device.borrow();
        if (guard.objects != borrow.objects) return error.ResourceDeviceMismatch;
        guard.assertOwns(borrow.objects);
        try device.arena.checkAllocator(guard, allocator);
        if (state.header.tracking != borrow.objects) return error.ResourceDeviceMismatch;
        var prepared_usage = usage.RenderPassResourceUsageTracker.init(allocator);
        errdefer prepared_usage.deinit(io, guard);
        try prepared_usage.usage.retainAttachmentLocked(guard, state);
        const context = try allocator.create(encoding_context.Context);
        errdefer allocator.destroy(context);
        context.* = try encoding_context.Context.init(
            allocator,
            borrow,
            options.block_size,
            options.compatibility_mode,
        );
        errdefer context.deinit(io, guard);
        _ = context.open();
        var base = render.RenderEncoderBase.initOwned(
            allocator,
            context,
            options.compatibility_mode,
            prepared_usage,
        );
        base.max_draw_count = options.max_draw_count;
        return .{
            .allocator = allocator,
            .device = device,
            .context = context,
            .base = base,
        };
    }

    /// Releases only fields not moved by finish. Repeated cleanup is harmless.
    pub fn deinit(
        self: *RenderBundleEncoder,
        io: std.Io,
        guard: *const core.ObjectGuard,
    ) void {
        guard.assertOwns(self.device.borrow().objects);
        if (self.context) |context| {
            self.base.deinit(io, guard);
            for (self.texture_bindings) |bindings| self.allocator.free(bindings);
            context.deinit(io, guard);
            self.allocator.destroy(context);
            self.texture_bindings = @splat(&.{});
            self.finished = true;
            self.context = null;
        }
    }

    fn validateOpen(self: *const RenderBundleEncoder) errors.Error!*encoding_context.Context {
        const context = self.context orelse return error.EncoderDestroyed;
        if (self.finished) return error.EncoderAlreadyFinished;
        try context.validateCanEncodeOn(self.base.programmable.id, false);
        return context;
    }

    fn recordFailure(self: *RenderBundleEncoder, err: errors.Error) errors.Error {
        // A caller's allocation callback can release the context before allocation fails.
        if (err == error.OutOfMemory) {
            if (self.context) |context| context.status = .error_in_recording;
        }
        return err;
    }

    /// Publishes one owned user alias. Validation errors leave the encoder open.
    /// Allocation failure marks recording failed and preserves all owned fields.
    pub fn finish(
        self: *RenderBundleEncoder,
        io: std.Io,
        guard: *const core.ObjectGuard,
    ) errors.Error!*RenderBundle {
        if (guard.objects != self.device.borrow().objects) return error.ResourceDeviceMismatch;
        guard.assertOwns(self.device.borrow().objects);
        const context = try self.validateOpen();
        const state = self.base.attachmentState();
        if (state.header.tracking != guard.objects) return error.ResourceDeviceMismatch;
        guard.assertOwns(state.header.tracking);
        if (state.header.kind != .attachment_state) return error.HandleKindMismatch;
        if (state.header.state != .alive or !state.header.node.linked) {
            return error.ResourceDestroyed;
        }
        try self.base.programmable.validateProgrammableEncoderEnd();
        try self.base.occlusion_state.end();
        if (self.base.draw_count > self.base.max_draw_count) return error.DrawCountExceeded;
        const bundle = self.device.create(self.allocator, guard, RenderBundle, .{
            .kind = .render_bundle,
            .initial_reference = .user,
        }) catch |err| return self.recordFailure(err);
        bundle.allocator = self.allocator;
        bundle.blocks = context.pending.acquireBlocks();
        bundle.draw_count = self.base.draw_count;
        bundle.resource_usage = self.base.usage.acquireResourceUsage();
        bundle.indirect = self.base.indirect;
        self.base.indirect = indirect_draw.IndirectDrawMetadata.init(self.allocator);
        self.base.tracker.end();
        self.finished = true;
        context.status = .finished;
        bundle.header.attach(guard, io);
        return bundle;
    }

    pub fn setPipeline(
        self: *RenderBundleEncoder,
        guard: *const core.ObjectGuard,
        options: render.SetRenderPipelineOptions,
    ) errors.Error!void {
        _ = try self.validateOpen();
        self.base.setPipeline(guard, options) catch |err| return self.recordFailure(err);
    }

    pub fn setBindGroup(
        self: *RenderBundleEncoder,
        options: programmable.SetBindGroupOptions,
    ) errors.Error!void {
        _ = try self.validateOpen();
        try self.base.programmable.validateSetBindGroup(options);
        const bindings = self.allocator.dupe(
            state_tracker.TextureBinding,
            options.texture_bindings,
        ) catch |err| return self.recordFailure(err);
        errdefer self.allocator.free(bindings);
        var owned_options = options;
        owned_options.texture_bindings = bindings;
        self.base.setBindGroup(owned_options) catch |err| return self.recordFailure(err);
        self.allocator.free(self.texture_bindings[options.index]);
        self.texture_bindings[options.index] = bindings;
    }

    pub fn setImmediates(
        self: *RenderBundleEncoder,
        options: programmable.SetImmediatesOptions,
    ) errors.Error!void {
        _ = try self.validateOpen();
        self.base.setImmediates(options) catch |err| return self.recordFailure(err);
    }

    pub fn setVertexBuffer(self: *RenderBundleEncoder, options: render.SetVertexBufferOptions) errors.Error!void {
        _ = try self.validateOpen();
        if (options.offset > options.buffer_size) return error.DrawVertexCount;
        if (options.size) |size| {
            if (size > options.buffer_size - options.offset) return error.DrawVertexCount;
        }
        self.base.setVertexBuffer(options) catch |err| return self.recordFailure(err);
    }

    pub fn setIndexBuffer(self: *RenderBundleEncoder, options: render.SetIndexBufferOptions) errors.Error!void {
        _ = try self.validateOpen();
        if (options.offset > options.buffer_size) return error.DrawIndexCount;
        if (options.size) |size| {
            if (size > options.buffer_size - options.offset) return error.DrawIndexCount;
        }
        self.base.setIndexBuffer(options) catch |err| return self.recordFailure(err);
    }

    pub fn setResourceTable(self: *RenderBundleEncoder, table: commands.Ref) errors.Error!void {
        _ = try self.validateOpen();
        self.base.setResourceTable(table) catch |err| return self.recordFailure(err);
    }

    pub fn draw(self: *RenderBundleEncoder, options: render.DrawVertexCountOptions) errors.Error!void {
        _ = try self.validateOpen();
        self.base.draw(options) catch |err| return self.recordFailure(err);
    }

    pub fn drawIndexed(
        self: *RenderBundleEncoder,
        options: render.DrawIndexedIndexCountOptions,
        base_vertex: i32,
    ) errors.Error!void {
        _ = try self.validateOpen();
        self.base.drawIndexed(options, base_vertex) catch |err| return self.recordFailure(err);
    }

    pub fn drawIndirect(
        self: *RenderBundleEncoder,
        options: render.DrawIndirectOptions,
    ) errors.Error!void {
        _ = try self.validateOpen();
        self.base.drawIndirect(options) catch |err| return self.recordFailure(err);
    }

    pub fn drawIndexedIndirect(
        self: *RenderBundleEncoder,
        options: render.DrawIndirectOptions,
    ) errors.Error!void {
        _ = try self.validateOpen();
        self.base.drawIndexedIndirect(options) catch |err| return self.recordFailure(err);
    }

    pub fn multiDrawIndirect(
        self: *RenderBundleEncoder,
        options: render.MultiDrawIndirectOptions,
    ) errors.Error!void {
        _ = try self.validateOpen();
        self.base.multiDrawIndirect(options) catch |err| return self.recordFailure(err);
    }

    pub fn multiDrawIndexedIndirect(
        self: *RenderBundleEncoder,
        options: render.MultiDrawIndirectOptions,
    ) errors.Error!void {
        _ = try self.validateOpen();
        self.base.multiDrawIndexedIndirect(options) catch |err| return self.recordFailure(err);
    }

    pub fn pushDebugGroup(self: *RenderBundleEncoder, label: []const u8) errors.Error!void {
        _ = try self.validateOpen();
        self.base.pushDebugGroup(label) catch |err| return self.recordFailure(err);
    }

    pub fn popDebugGroup(self: *RenderBundleEncoder) errors.Error!void {
        const context = try self.validateOpen();
        if (context.debugGroupDepth() == 0) return error.DebugGroupUnbalanced;
        self.base.popDebugGroup() catch |err| return self.recordFailure(err);
    }

    pub fn insertDebugMarker(self: *RenderBundleEncoder, label: []const u8) errors.Error!void {
        _ = try self.validateOpen();
        self.base.insertDebugMarker(label) catch |err| return self.recordFailure(err);
    }
};
