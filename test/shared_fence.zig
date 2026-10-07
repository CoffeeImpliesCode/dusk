const std = @import("std");
const vulkan = @import("vulkan");
const core = @import("../src/core/root.zig");
const Device = @import("../src/engine/device.zig").Device;
const external = @import("../src/platform/external_semaphore.zig");
const dispatch = @import("../src/vk/dispatch.zig");
const fences = @import("../src/engine/shared_fence.zig");

var destroyed: usize = 0;
var exported: usize = 0;
var export_fd: c_int = -1;
fn create(_: vulkan.VkDevice, _: [*c]const vulkan.VkSemaphoreCreateInfo, _: [*c]const vulkan.VkAllocationCallbacks, out: [*c]vulkan.VkSemaphore) callconv(.c) vulkan.VkResult {
    out.* = @ptrFromInt(0x1000);
    return vulkan.VK_SUCCESS;
}
fn destroy(_: vulkan.VkDevice, _: vulkan.VkSemaphore, _: [*c]const vulkan.VkAllocationCallbacks) callconv(.c) void { destroyed += 1; }
fn importFd(_: vulkan.VkDevice, info: [*c]const vulkan.VkImportSemaphoreFdInfoKHR) callconv(.c) vulkan.VkResult {
    std.debug.assert(info.*.fd == -1);
    return vulkan.VK_SUCCESS;
}
fn exportFd(_: vulkan.VkDevice, _: [*c]const vulkan.VkSemaphoreGetFdInfoKHR, out: [*c]c_int) callconv(.c) vulkan.VkResult {
    exported += 1;
    out.* = export_fd;
    return vulkan.VK_SUCCESS;
}
fn procs() dispatch.DeviceProcs {
    var result = std.mem.zeroes(dispatch.DeviceProcs);
    result.create_semaphore = create;
    result.destroy_semaphore = destroy;
    result.import_semaphore_fd_khr = importFd;
    result.get_semaphore_fd_khr = exportFd;
    return result;
}
fn service(table: *const dispatch.DeviceProcs) external.Service {
    return .{ .device = null, .procs = table, .handle_type = .sync_fd, .supported = true };
}
fn unexpectedError(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
    @panic("unexpected core error");
}

test "export needs actual accepted queue signal and SyncFD payload exports once" {
    destroyed = 0;
    exported = 0;
    var mutex: std.Io.Mutex = .init;
    var owner: Device = undefined;
    owner.core = core.Device.init(std.testing.allocator, .{ .object_mutex = &mutex, .uncaptured_context = &destroyed, .uncaptured_callback = unexpectedError });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, owner.core.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer owner.core.deinit(std.testing.allocator, &guard) catch @panic("leaked references");
    const table = procs();
    const fence = try fences.SharedFence.createExportable(std.testing.allocator, std.testing.io, &guard, &owner.core.arena, &owner, service(&table));
    defer fence.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    try std.testing.expectError(error.SemaphoreNotSubmitted, fence.ensureExportedLocked(std.testing.io, &guard));
    try std.testing.expectEqual(@as(usize, 0), exported);
    try std.testing.expectEqual(@as(vulkan.VkSemaphore, @ptrFromInt(0x1000)), try fence.signalSemaphoreLocked(&guard, &owner));
    fence.acceptSignalLocked(&guard, 7);
    try fence.ensureExportedLocked(std.testing.io, &guard);
    try fence.ensureExportedLocked(std.testing.io, &guard);
    try std.testing.expectEqual(@as(usize, 1), exported);
    try std.testing.expectEqual(@as(c_int, -1), try fence.takeExportedHandleLocked(&guard));
    try std.testing.expectError(error.UnsupportedFenceExport, fence.ensureExportedLocked(std.testing.io, &guard));
}

test "imported binary fence rejects wrong device and wrong value before consumption" {
    var mutex: std.Io.Mutex = .init;
    var owner: Device = undefined;
    var other: Device = undefined;
    owner.core = core.Device.init(std.testing.allocator, .{ .object_mutex = &mutex, .uncaptured_context = &destroyed, .uncaptured_callback = unexpectedError });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, owner.core.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer owner.core.deinit(std.testing.allocator, &guard) catch @panic("leaked references");
    const table = procs();
    const fence = try fences.SharedFence.importNative(std.testing.allocator, std.testing.io, &guard, &owner.core.arena, &owner, service(&table), -1, "signaled");
    defer fence.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    try std.testing.expectError(error.DeviceMismatch, fence.waitSemaphoreLocked(&guard, &other, 1));
    try std.testing.expectError(error.InvalidFenceValue, fence.waitSemaphoreLocked(&guard, &owner, 2));
    _ = try fence.waitSemaphoreLocked(&guard, &owner, 1);
    _ = try fence.waitSemaphoreLocked(&guard, &owner, 1);
    fence.acceptWaitLocked(&guard);
    try std.testing.expectError(error.InvalidFenceValue, fence.waitSemaphoreLocked(&guard, &owner, 1));
}

test "flattened descriptor rejects absent multiple and unsupported handle arms" {
    try std.testing.expectError(error.DescriptorChainEmpty, fences.validateDescriptor(.{}));
    try std.testing.expectError(error.MultipleFenceHandleArms, fences.validateDescriptor(.{
        .shared_fence_vk_semaphore_opaque_fd_descriptor = .{ .handle = 3 },
        .shared_fence_sync_fd_descriptor = .{ .handle = 4 },
    }));
    try std.testing.expectError(error.UnsupportedFenceHandleType, fences.validateDescriptor(.{ .shared_fence_egl_sync_descriptor = .{} }));
    try std.testing.expectError(error.InvalidFenceFd, fences.validateDescriptor(.{ .shared_fence_vk_semaphore_opaque_fd_descriptor = .{ .handle = -1 } }));
    const valid = try fences.validateDescriptor(.{ .shared_fence_sync_fd_descriptor = .{ .handle = -1 } });
    try std.testing.expectEqual(external.HandleType.sync_fd, valid.handle_type);
}

test "imported export follows queried imported handle property" {
    exported = 0;
    var mutex: std.Io.Mutex = .init;
    var owner: Device = undefined;
    owner.core = core.Device.init(std.testing.allocator, .{ .object_mutex = &mutex, .uncaptured_context = &destroyed, .uncaptured_callback = unexpectedError });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, owner.core.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer owner.core.deinit(std.testing.allocator, &guard) catch @panic("leaked references");
    const table = procs();
    var authorized = service(&table);
    const denied = try fences.SharedFence.importNative(std.testing.allocator, std.testing.io, &guard, &owner.core.arena, &owner, authorized, -1, "");
    defer denied.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    try std.testing.expectError(error.UnsupportedFenceExport, denied.ensureExportedLocked(std.testing.io, &guard));
    authorized.export_from_imported = true;
    const allowed = try fences.SharedFence.importNative(std.testing.allocator, std.testing.io, &guard, &owner.core.arena, &owner, authorized, -1, "");
    defer allowed.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    try allowed.ensureExportedLocked(std.testing.io, &guard);
    try std.testing.expectEqual(@as(usize, 1), exported);
    try std.testing.expectEqual(@as(c_int, -1), try allowed.takeExportedHandleLocked(&guard));
    try std.testing.expectError(error.UnsupportedFenceExport, allowed.ensureExportedLocked(std.testing.io, &guard));
}

test "queue lease owns semaphore beyond final user alias and destroys exactly once" {
    destroyed = 0;
    var mutex: std.Io.Mutex = .init;
    var owner: Device = undefined;
    owner.core = core.Device.init(std.testing.allocator, .{ .object_mutex = &mutex, .uncaptured_context = &destroyed, .uncaptured_callback = unexpectedError });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, owner.core.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer owner.core.deinit(std.testing.allocator, &guard) catch @panic("leaked references");
    const table = procs();
    const fence = try fences.SharedFence.createExportable(std.testing.allocator, std.testing.io, &guard, &owner.core.arena, &owner, service(&table));
    try fence.header.retainLeaseLocked(&guard);
    try fence.header.releaseUserLocked(&guard, std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), destroyed);
    _ = try fence.signalSemaphoreLocked(&guard, &owner);
    fence.acceptSignalLocked(&guard, 3);
    fence.header.releaseLeaseLocked(&guard, std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}

test "successful output transfers actual cached FD and final fence release does not close it" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(std.testing.io, "actual-export", .{});
    defer file.close(std.testing.io);
    export_fd = try external.duplicateHandle(file.handle);
    defer export_fd = -1;
    var mutex: std.Io.Mutex = .init;
    var owner: Device = undefined;
    owner.core = core.Device.init(std.testing.allocator, .{ .object_mutex = &mutex, .uncaptured_context = &destroyed, .uncaptured_callback = unexpectedError });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, owner.core.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer owner.core.deinit(std.testing.allocator, &guard) catch @panic("leaked references");
    const table = procs();
    const fence = try fences.SharedFence.createExportable(std.testing.allocator, std.testing.io, &guard, &owner.core.arena, &owner, service(&table));
    fence.acceptSignalLocked(&guard, 1);
    try fence.ensureExportedLocked(std.testing.io, &guard);
    const actual = try fence.takeExportedHandleLocked(&guard);
    defer external.closeHandle(std.testing.io, actual);
    try fence.header.releaseUserLocked(&guard, std.testing.io);
    try std.testing.expectEqual(export_fd, actual);
    _ = try external.fileFromDescriptor(actual).stat(std.testing.io);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    const destroys_before = destroyed;
    defer std.debug.assert(destroyed == destroys_before + 1);
    var mutex: std.Io.Mutex = .init;
    var owner: Device = undefined;
    owner.core = core.Device.init(allocator, .{ .object_mutex = &mutex, .uncaptured_context = &destroyed, .uncaptured_callback = unexpectedError });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, owner.core.arena.objectList());
    defer guard.unlock(std.testing.io);
    defer owner.core.deinit(allocator, &guard) catch @panic("failed allocation retained a reference");
    const table = procs();
    const fence = try fences.SharedFence.createExportable(allocator, std.testing.io, &guard, &owner.core.arena, &owner, service(&table));
    defer fence.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
}

test "arena allocation failures roll back native semaphore and publish no reference" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
