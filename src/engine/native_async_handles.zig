//! Allocation-free generated handles for actual high owners and core resources.
//!
//! Root and queue exports borrow the embedded RootRecord without a retain.
//! Resource handles borrow the existing core header and the one reference ledger.
//! The caller keeps root storage or an owned resource alias alive through resolution.
//! Resource owner lookup grants no operation pin or payload access. Pin the actual
//! Device before locking its original ObjectGuard and validating a resource.
//! Forged pointers and pointers used after final host release are outside this contract.

const std = @import("std");
const api = @import("../api/root.zig");
const core = @import("../core/root.zig");
const instance_mod = @import("instance.zig");
const adapter_mod = @import("adapter.zig");
const device_mod = @import("device.zig");
const roots = @import("async_root_requests.zig");

/// Borrows this Instance's embedded record at its final stable address.
pub fn exportInstance(instance: *instance_mod.Instance) api.Instance {
    std.debug.assert(instance.root_record.kind == .instance);
    return .{ .handle = @ptrCast(&instance.root_record) };
}

/// Borrows the actual Adapter row, without copying its parent-owned metadata.
pub fn exportAdapter(adapter: *adapter_mod.Adapter) api.Adapter {
    std.debug.assert(adapter.root_record.kind == .adapter);
    return .{ .handle = @ptrCast(&adapter.root_record) };
}

/// Borrows the actual high Device, without acquiring another result owner.
pub fn exportDevice(device: *device_mod.Device) api.Device {
    std.debug.assert(device.root_record.kind == .device);
    return .{ .handle = @ptrCast(&device.root_record) };
}

/// Rejects null or a different root kind. The returned owner remains borrowed.
pub fn resolveInstance(target: api.Instance) error{InvalidOwner}!*instance_mod.Instance {
    const record = try rootRecord(target.handle, .instance);
    return @fieldParentPtr("root_record", record);
}

/// Rejects null or a different root kind. The returned Adapter is the actual row.
pub fn resolveAdapter(target: api.Adapter) error{InvalidOwner}!*adapter_mod.Adapter {
    const record = try rootRecord(target.handle, .adapter);
    return @fieldParentPtr("root_record", record);
}

/// Rejects null or a different root kind. Resolution does not pin the Device.
pub fn resolveDevice(target: api.Device) error{InvalidOwner}!*device_mod.Device {
    const record = try rootRecord(target.handle, .device);
    return @fieldParentPtr("root_record", record);
}

/// Borrows the same Device record. No separate queue host object is created.
pub fn exportQueue(device: *device_mod.Device) api.Queue {
    std.debug.assert(device.root_record.kind == .device);
    return .{ .handle = @ptrCast(&device.root_record) };
}

/// Locates the actual Device whose existing queue this generated handle names.
pub fn resolveQueue(target: api.Queue) error{InvalidOwner}!*device_mod.Device {
    const record = try rootRecord(target.handle, .device);
    return @fieldParentPtr("root_record", record);
}

/// Publishes an existing live user alias through its real header, without a retain.
/// The caller holds this Device's guard and has completed all fallible construction.
/// `kind` must match the actual header, including native wrapper kinds.
pub fn exportResource(
    comptime ApiType: type,
    device: *device_mod.Device,
    guard: *const core.ObjectGuard,
    target: anytype,
    kind: core.Handle.Kind,
) ApiType {
    const header: *core.Object = &target.header;
    validateResourceLocked(device, guard, header, kind) catch unreachable;
    std.debug.assert(header.user_reference_count != 0);
    const published = device.coreDevice().handleFor(guard, @TypeOf(target.*), target, kind);
    std.debug.assert(header.reference_escaped);
    return .{ .handle = @ptrCast(published.ptr) };
}

/// Rejects null, misalignment, or an exact kind mismatch before owner lookup.
/// Only immutable identity may be read before the actual host pin and ObjectGuard.
pub fn resourceHeader(
    comptime ApiType: type,
    target: ApiType,
    kind: core.Handle.Kind,
) error{InvalidOwner}!*core.Object {
    const raw = target.handle orelse return error.InvalidOwner;
    if (@intFromPtr(raw) % @alignOf(core.Object) != 0) return error.InvalidOwner;
    const header: *core.Object = @ptrCast(@alignCast(raw));
    if (header.kind != kind) return error.InvalidOwner;
    return header;
}

/// Follows the immutable canonical locator without acquiring a host operation pin.
/// The caller owns an alias or lease that keeps this header and its Device alive.
pub fn resourceOwner(header: *core.Object) error{InvalidOwner}!*device_mod.Device {
    const raw = header.tracking.high_owner orelse return error.InvalidOwner;
    if (@intFromPtr(raw) % @alignOf(device_mod.Device) != 0) return error.InvalidOwner;
    const device: *device_mod.Device = @ptrCast(@alignCast(raw));
    if (device.coreDevice().borrow().objectList() != header.tracking) {
        return error.InvalidOwner;
    }
    return device;
}

/// Validates exact kind, canonical high ownership, the original guard, and live payload.
/// A failed core object is not a live native payload.
pub fn validateResourceLocked(
    device: *device_mod.Device,
    guard: *const core.ObjectGuard,
    header: *core.Object,
    kind: core.Handle.Kind,
) core.HandleError!void {
    try validateResourceHostLocked(device, guard, header, kind);
    if (header.state != .alive) return error.StaleHandle;
}

/// Validates retained host identity for late reference operations, not payload access.
/// Failed and destroyed headers remain valid only while linked with a nonzero ledger.
pub fn validateResourceHostLocked(
    device: *device_mod.Device,
    guard: *const core.ObjectGuard,
    header: *core.Object,
    kind: core.Handle.Kind,
) core.HandleError!void {
    const objects = device.coreDevice().borrow().objectList();
    if (!guard.held) return error.StaleHandle;
    if (guard.objects != objects) return error.StaleHandle;
    if (guard.mutex != objects.mutex) return error.StaleHandle;
    if (objects.high_owner != @as(*anyopaque, @ptrCast(device))) return error.StaleHandle;
    const validated = try device.coreDevice().resolveReference(guard, .{
        .ptr = @as(core.ObjectPtr, header),
        .kind = kind,
    });
    std.debug.assert(validated == header);
}

fn rootRecord(
    pointer: ?*anyopaque,
    kind: roots.RootKind,
) error{InvalidOwner}!*roots.RootRecord {
    const raw = pointer orelse return error.InvalidOwner;
    if (@intFromPtr(raw) % @alignOf(roots.RootRecord) != 0) return error.InvalidOwner;
    const record: *roots.RootRecord = @ptrCast(@alignCast(raw));
    if (record.kind != kind) return error.InvalidOwner;
    return record;
}
