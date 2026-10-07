//! Vulkan pools borrow handles and retire through their queue's serial timeline.
const std = @import("std");
const vulkan = @import("vulkan");
const dispatch = @import("../vk/dispatch.zig");
const core = @import("../core/root.zig");
const api = @import("../api/api.zig");
const query = @import("query_set.zig");
const commands = @import("../command/query.zig");
const queue_mod = @import("queue.zig");

pub const Error = queue_mod.ProcError || query.Error || core.ReferenceError || std.mem.Allocator.Error || error{
    QueryPoolCreationReturnedNull,
    QueryPoolMissing,
    QueryBitmapCountMismatch,
    QueryIndexOutOfRange,
    QueryTypeMismatch,
    QueryPoolQueueMismatch,
    QueryResolveOffsetInvalid,
};

pub fn querySetVulkanType(query_type: commands.QueryType) vulkan.VkQueryType {
    return switch (query_type) {
        .occlusion => vulkan.VK_QUERY_TYPE_OCCLUSION,
        .timestamp => vulkan.VK_QUERY_TYPE_TIMESTAMP,
    };
}

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    guard: *const core.ObjectGuard,
    dev: *core.Device,
    descriptor: query.Descriptor,
    options: query.DescriptorOptions,
    queue: *queue_mod.Queue,
) (query.QuerySet.CreateError || Error)!api.objects.QuerySet {
    guard.assertOwns(dev.borrow().objectList());
    if (guard.objects.mutex != &queue.device_mutex.mutex) return error.ResourceDeviceMismatch;
    const handle = try query.QuerySet.create(allocator, io, guard, dev, descriptor, options);
    const set = try query.resolveQuerySet(dev, guard, handle);
    errdefer set.header.releaseUserLocked(guard, io) catch unreachable;
    try createPool(guard, queue, set);
    return handle;
}

fn validateHeader(guard: *const core.ObjectGuard, set: *const query.QuerySet) Error!void {
    if (set.header.tracking != guard.objects) return error.ResourceDeviceMismatch;
    guard.assertOwns(set.header.tracking);
    if (!set.header.node.linked or set.header.reference_count == 0 or set.header.state != .alive)
        return error.QuerySetDestroyed;
}

fn validateQueue(
    guard: *const core.ObjectGuard,
    queue: *queue_mod.Queue,
    set: *const query.QuerySet,
) Error!void {
    try validateHeader(guard, set);
    if (set.header.tracking.mutex != &queue.device_mutex.mutex) return error.ResourceDeviceMismatch;
    if (queue.query_sets) |registered| {
        if (registered.header.tracking != set.header.tracking) return error.ResourceDeviceMismatch;
    }
    try set.validateCanUseInSubmit(guard);
    if (set.backend_queue) |owner| {
        if (owner != queue) return error.QueryPoolQueueMismatch;
    }
}

/// Creates the native pool and registers `set` under its owning ObjectGuard.
/// The queue must share the guard's stable mutex and must not move while registered.
/// Registration owns exactly one core lease; serial-safe queue deregistration releases it.
/// Keep `queue` alive until every registered set deregisters or `Queue.deinit` detaches it.
/// Keep `set` alive at the same address until deregistration or queue teardown detaches it.
/// Destroying a set can defer deregistration until its last submission completes.
pub fn createPool(
    guard: *const core.ObjectGuard,
    queue: *queue_mod.Queue,
    set: *query.QuerySet,
) Error!void {
    try validateQueue(guard, queue, set);
    if (set.backend_queue != null) {
        if (set.pool != null) return;
        return error.QueryPoolMissing;
    }
    const procs = queue.context.dispatch.device orelse return error.DeviceProcTierMissing;
    const create_pool = procs.create_query_pool orelse return error.MissingDeviceProc;
    const destroy_pool = procs.destroy_query_pool orelse return error.MissingDeviceProc;
    const info: vulkan.VkQueryPoolCreateInfo = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
        .queryType = querySetVulkanType(set.query_type),
        .queryCount = @max(set.query_count, 1),
    };
    var pool: vulkan.VkQueryPool = null;
    try dispatch.checkVkSuccess(create_pool(queue.context.vk_device, &info, null, &pool));
    if (pool == null) return error.QueryPoolCreationReturnedNull;
    // Pool creation cannot publish the set until the registration owns its lease.
    set.header.retainLeaseLocked(guard) catch |err| {
        destroy_pool(queue.context.vk_device, pool, null);
        return err;
    };
    queue.context.handles.acquire(.query_pool);
    set.pool = pool;
    set.backend_queue = queue;
    set.backend_next = queue.query_sets;
    set.last_used_serial = 0;
    set.pending_use = false;
    queue.query_sets = set;
    queue.query_set_count += 1;
}

/// QuerySetVk.cpp:79 returns mHandle without transferring ownership.
pub fn getPool(guard: *const core.ObjectGuard, set: *const query.QuerySet) Error!vulkan.VkQueryPool {
    try validateHeader(guard, set);
    const owner = set.backend_queue orelse return error.QueryPoolMissing;
    try validateQueue(guard, owner, set);
    return set.pool orelse return error.QueryPoolMissing;
}

fn track(guard: *const core.ObjectGuard, queue: *queue_mod.Queue, set: *query.QuerySet) Error!vulkan.VkQueryPool {
    try createPool(guard, queue, set);
    try queue.trackQuerySet(guard, set);
    return getPool(guard, set);
}

pub fn resetTrackedQueries(
    allocator: std.mem.Allocator,
    guard: *const core.ObjectGuard,
    queue: *queue_mod.Queue,
    set: *query.QuerySet,
    bitmap: []const bool,
) Error!void {
    _ = allocator;
    try validateQueue(guard, queue, set);
    if (bitmap.len != set.query_count) return error.QueryBitmapCountMismatch;
    const procs = queue.context.dispatch.device orelse return error.DeviceProcTierMissing;
    const reset = procs.cmd_reset_query_pool orelse return error.MissingDeviceProc;
    const pool = try track(guard, queue, set);
    var walk = query.AvailableRangeWalk.init(bitmap, 0, set.query_count);
    while (walk.next()) |run| reset(queue.commandBuffer(), pool, run.first, run.count);
}

fn validateIndex(
    guard: *const core.ObjectGuard,
    queue: *queue_mod.Queue,
    set: *query.QuerySet,
    index: u32,
    query_type: commands.QueryType,
) Error!void {
    try validateQueue(guard, queue, set);
    if (set.query_type != query_type) return error.QueryTypeMismatch;
    if (index >= set.query_count) return error.QueryIndexOutOfRange;
}

pub fn beginQuery(
    allocator: std.mem.Allocator,
    guard: *const core.ObjectGuard,
    queue: *queue_mod.Queue,
    set: *query.QuerySet,
    index: u32,
) Error!void {
    _ = allocator;
    try validateIndex(guard, queue, set, index, .occlusion);
    const procs = queue.context.dispatch.device orelse return error.DeviceProcTierMissing;
    const begin = procs.cmd_begin_query orelse return error.MissingDeviceProc;
    begin(queue.commandBuffer(), try track(guard, queue, set), index, 0);
}

pub fn endQuery(
    allocator: std.mem.Allocator,
    guard: *const core.ObjectGuard,
    queue: *queue_mod.Queue,
    set: *query.QuerySet,
    index: u32,
) Error!void {
    _ = allocator;
    try validateIndex(guard, queue, set, index, .occlusion);
    const procs = queue.context.dispatch.device orelse return error.DeviceProcTierMissing;
    const end = procs.cmd_end_query orelse return error.MissingDeviceProc;
    end(queue.commandBuffer(), try track(guard, queue, set), index);
    set.markQueryAvailable(guard, index);
}

pub fn writeTimestamp(
    allocator: std.mem.Allocator,
    guard: *const core.ObjectGuard,
    queue: *queue_mod.Queue,
    set: *query.QuerySet,
    index: u32,
    stage: vulkan.VkPipelineStageFlagBits,
    reset: bool,
) Error!void {
    _ = allocator;
    try validateIndex(guard, queue, set, index, .timestamp);
    const procs = queue.context.dispatch.device orelse return error.DeviceProcTierMissing;
    const write = procs.cmd_write_timestamp orelse return error.MissingDeviceProc;
    const reset_query = procs.cmd_reset_query_pool orelse return error.MissingDeviceProc;
    const pool = try track(guard, queue, set);
    if (reset) reset_query(queue.commandBuffer(), pool, index, 1);
    write(queue.commandBuffer(), stage, pool, index);
    set.markQueryAvailable(guard, index);
}

pub fn resolveQueries(
    allocator: std.mem.Allocator,
    guard: *const core.ObjectGuard,
    queue: *queue_mod.Queue,
    set: *query.QuerySet,
    first: u32,
    count: u32,
    destination: vulkan.VkBuffer,
    offset: u64,
) Error!void {
    try validateQueue(guard, queue, set);
    if (first > set.query_count or count > set.query_count - first) return error.QueryIndexOutOfRange;
    if (offset % commands.query_resolve_alignment != 0 or
        offset > std.math.maxInt(u64) - commands.queryStorageSize(count))
    {
        return error.QueryResolveOffsetInvalid;
    }
    if (count == 0) return;
    const procs = queue.context.dispatch.device orelse return error.DeviceProcTierMissing;
    const fill = procs.cmd_fill_buffer orelse return error.MissingDeviceProc;
    const copy = procs.cmd_copy_query_pool_results orelse return error.MissingDeviceProc;
    const pool = try track(guard, queue, set);
    const runs = try allocator.alloc(query.CopyRun, query.maxRunCount(count));
    defer allocator.free(runs);
    const plan = try query.planResolve(set.availability, .{
        .first_query = first,
        .query_count = count,
        .destination_offset = offset,
    }, runs);
    if (plan.needs_zero_fill) {
        fill(queue.commandBuffer(), destination, offset, plan.zero_fill_size, 0);
        // Fill and query copy write overlapping slots: order the transfer writes.
        const barrier = procs.cmd_pipeline_barrier orelse return error.MissingDeviceProc;
        const memory: vulkan.VkMemoryBarrier = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask = vulkan.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vulkan.VK_ACCESS_TRANSFER_WRITE_BIT,
        };
        barrier(
            queue.commandBuffer(),
            vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vulkan.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            1,
            &memory,
            0,
            null,
            0,
            null,
        );
    }
    for (runs[0..plan.run_count]) |run| {
        copy(
            queue.commandBuffer(),
            pool,
            run.first,
            run.count,
            destination,
            run.destination_offset,
            commands.single_query_storage_size,
            vulkan.VK_QUERY_RESULT_64_BIT | vulkan.VK_QUERY_RESULT_WAIT_BIT,
        );
    }
}

test "query types map exhaustively" {
    try std.testing.expectEqual(
        @as(vulkan.VkQueryType, vulkan.VK_QUERY_TYPE_OCCLUSION),
        querySetVulkanType(.occlusion),
    );
    try std.testing.expectEqual(
        @as(vulkan.VkQueryType, vulkan.VK_QUERY_TYPE_TIMESTAMP),
        querySetVulkanType(.timestamp),
    );
}

const PoolProbe = struct {
    count: u32 = 0,
    destroyed: u32 = 0,
    reset_first: [4]u32 = @splat(0),
    reset_count: [4]u32 = @splat(0),
    reset_calls: usize = 0,

    fn create(
        device: vulkan.VkDevice,
        info: [*c]const vulkan.VkQueryPoolCreateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        result: [*c]vulkan.VkQueryPool,
    ) callconv(.c) vulkan.VkResult {
        const self: *PoolProbe = @ptrCast(@alignCast(device));
        self.count = info[0].queryCount;
        result[0] = @ptrFromInt(8);
        return vulkan.VK_SUCCESS;
    }

    fn destroy(
        device: vulkan.VkDevice,
        _: vulkan.VkQueryPool,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self: *PoolProbe = @ptrCast(@alignCast(device));
        self.destroyed += 1;
    }

    fn reset(
        command_buffer: vulkan.VkCommandBuffer,
        _: vulkan.VkQueryPool,
        first: u32,
        count: u32,
    ) callconv(.c) void {
        const self: *PoolProbe = @ptrCast(@alignCast(command_buffer));
        std.debug.assert(self.reset_calls < self.reset_first.len);
        self.reset_first[self.reset_calls] = first;
        self.reset_count[self.reset_calls] = count;
        self.reset_calls += 1;
    }
};

fn queryTestUncaptured(
    _: std.mem.Allocator,
    _: std.Io,
    _: *anyopaque,
    _: core.ErrorView,
) void {
    @panic("unexpected Vulkan query error callback");
}

test "zero count pool borrows handle and waits for retirement serial" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var device_mutex: @import("../platform/root.zig").DeviceMutex = .{};
    var callback_context: u8 = 0;
    var dev = core.Device.init(gpa, .{
        .object_mutex = &device_mutex.mutex,
        .uncaptured_context = &callback_context,
        .uncaptured_callback = queryTestUncaptured,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, dev.borrow().objectList());
    defer guard.unlock(io);
    defer dev.deinit(gpa, &guard) catch @panic("Vulkan query references leaked");
    var probe: PoolProbe = .{};
    var procs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.create_query_pool = PoolProbe.create;
    procs.destroy_query_pool = PoolProbe.destroy;
    var handles: queue_mod.HandleSet = .{};
    var memory_properties = std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties);
    var queue: queue_mod.Queue = .{
        .context = .{
            .allocator = gpa,
            .dispatch = .{ .global = null, .instance = null, .device = &procs },
            .vk_device = @ptrCast(&probe),
            .vk_queue = null,
            .queue_family_index = 0,
            .memory_properties = &memory_properties,
            .handles = &handles,
        },
        .device_mutex = &device_mutex,
        .timeline = .{},
    };
    const target = try create(gpa, io, &guard, &dev, .{ .type_ = .occlusion, .count = 0 }, .{}, &queue);
    const set = try query.resolveQuerySet(&dev, &guard, target);
    defer set.apiDestroy(&guard, io) catch @panic("Vulkan query release failed");
    try std.testing.expectEqual(@as(u32, 1), probe.count);
    try std.testing.expectEqual(@as(u32, 2), set.header.reference_count);
    try createPool(&guard, &queue, set);
    try std.testing.expectEqual(@as(u32, 2), set.header.reference_count);
    try std.testing.expectEqual(@as(usize, 1), queue.query_set_count);
    const pool = try getPool(&guard, set);
    try std.testing.expectEqual(pool, try getPool(&guard, set));
    set.last_used_serial = 2;
    set.header.retirePayloadLocked(&guard, io, .early_destroy);
    try std.testing.expectEqual(@as(u32, 0), probe.destroyed);
    queue.completed_serial = 1;
    try queue.retireQueryPool(&guard, io, set);
    try std.testing.expectEqual(@as(u32, 0), probe.destroyed);
    queue.completed_serial = 2;
    try queue.retireQueryPool(&guard, io, set);
    try std.testing.expectEqual(@as(u32, 1), probe.destroyed);
    try std.testing.expect(set.pool == null);
    try std.testing.expectEqual(@as(usize, 0), queue.query_set_count);
    try std.testing.expectEqual(@as(u32, 1), set.header.reference_count);
    try std.testing.expectError(error.QuerySetDestroyed, getPool(&guard, set));
}

test "reset uses sparse pass bitmap rather than object availability" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var device_mutex: @import("../platform/root.zig").DeviceMutex = .{};
    var callback_context: u8 = 0;
    var dev = core.Device.init(gpa, .{
        .object_mutex = &device_mutex.mutex,
        .uncaptured_context = &callback_context,
        .uncaptured_callback = queryTestUncaptured,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, dev.borrow().objectList());
    defer guard.unlock(io);
    defer dev.deinit(gpa, &guard) catch @panic("Vulkan query references leaked");
    var probe: PoolProbe = .{};
    var procs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.create_query_pool = PoolProbe.create;
    procs.destroy_query_pool = PoolProbe.destroy;
    procs.cmd_reset_query_pool = PoolProbe.reset;
    var handles: queue_mod.HandleSet = .{};
    var memory_properties = std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties);
    var queue: queue_mod.Queue = .{
        .context = .{
            .allocator = gpa,
            .dispatch = .{ .global = null, .instance = null, .device = &procs },
            .vk_device = @ptrCast(&probe),
            .vk_queue = null,
            .queue_family_index = 0,
            .memory_properties = &memory_properties,
            .handles = &handles,
        },
        .device_mutex = &device_mutex,
        .timeline = .{},
    };
    queue.contexts[0].command_buffer = @ptrCast(&probe);
    const target = try query.QuerySet.create(gpa, io, &guard, &dev, .{ .type_ = .occlusion, .count = 5 }, .{});
    const set = try query.resolveQuerySet(&dev, &guard, target);
    defer set.apiDestroy(&guard, io) catch @panic("Vulkan query release failed");
    var foreign_mutex: @import("../platform/root.zig").DeviceMutex = .{};
    queue.device_mutex = &foreign_mutex;
    set.state = .unavailable;
    try std.testing.expectError(error.ResourceDeviceMismatch, resetTrackedQueries(gpa, &guard, &queue, set, &.{}));
    try std.testing.expectEqual(@as(u32, 0), probe.count);
    set.state = .available;
    queue.device_mutex = &device_mutex;
    try resetTrackedQueries(gpa, &guard, &queue, set, &.{ true, false, true, true, false });
    try std.testing.expectEqual(@as(usize, 2), probe.reset_calls);
    try std.testing.expectEqual(@as(u32, 0), probe.reset_first[0]);
    try std.testing.expectEqual(@as(u32, 1), probe.reset_count[0]);
    try std.testing.expectEqual(@as(u32, 2), probe.reset_first[1]);
    try std.testing.expectEqual(@as(u32, 2), probe.reset_count[1]);
    try std.testing.expect(!set.isQueryAvailable(&guard, 0));
    set.pending_use = false;
    set.header.retirePayloadLocked(&guard, io, .early_destroy);
    try std.testing.expectEqual(@as(u32, 1), probe.destroyed);
    try std.testing.expectEqual(@as(u32, 1), set.header.reference_count);
    // Retired headers reject native calls without inspecting poisoned payload fields.
    set.state = undefined;
    set.query_type = undefined;
    set.query_count = undefined;
    set.availability = undefined;
    set.backend_queue = undefined;
    set.pool = undefined;
    try std.testing.expectError(error.QuerySetDestroyed, createPool(&guard, &queue, set));
    try std.testing.expectError(error.QuerySetDestroyed, getPool(&guard, set));
    try std.testing.expectError(error.QuerySetDestroyed, resetTrackedQueries(gpa, &guard, &queue, set, &.{}));
    try std.testing.expectError(error.QuerySetDestroyed, beginQuery(gpa, &guard, &queue, set, 0));
    try std.testing.expectError(error.QuerySetDestroyed, endQuery(gpa, &guard, &queue, set, 0));
    try std.testing.expectError(error.QuerySetDestroyed, writeTimestamp(
        gpa,
        &guard,
        &queue,
        set,
        0,
        vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        false,
    ));
    try std.testing.expectError(error.QuerySetDestroyed, resolveQueries(gpa, &guard, &queue, set, 0, 0, null, 0));
}
