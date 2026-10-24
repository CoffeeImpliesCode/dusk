//! Binary external semaphores with one genuine Device-arena reference ledger.
//! Dawn revision 32f77c02294310054a660c393feded4bcb3f203c mappings:
//! `native/vulkan/DeviceVk.cpp:334-364`, `Device::ImportSharedFenceImpl`;
//! `native/vulkan/SharedFenceVk.cpp:53-65,68-78`, both `SharedFence::Create` arms;
//! `native/vulkan/SharedFenceVk.cpp:93-129`, `SharedFence::ExportInfoImpl`.
//! `native/vulkan/TextureVk.cpp:1832-1866`, `ImportedTextureBase::OnBeforeSubmit`
//! and `OnAfterSubmit`, map export preparation and accepted-signal publication;
//! `SharedTexture::OnBeforeSubmit` (:2060-2079) maps binary-value-one waits.
//! Unlike Dawn's stored SystemHandle export, this owner holds a real semaphore
//! and transfers a fresh actual native FD, never a borrowed or fabricated FD.
//! FD mechanics map to `ServiceImplementationFD::ImportSemaphore` (:92-137)
//! and `ExportSemaphore` (:160-174) in `vulkan/external_semaphore/`.
const std = @import("std");
const vulkan = @import("vulkan");
const api = @import("../api/api.zig");
const core = @import("../core/root.zig");
const external = @import("../platform/external_semaphore.zig");
const device_mod = @import("device.zig");
const Device = device_mod.Device;

pub const DescriptorError = error{ DescriptorChainEmpty, MultipleFenceHandleArms, UnsupportedFenceHandleType, InvalidFenceFd };
pub const ImportFenceError = core.ReferenceError || core.CreateError || std.mem.Allocator.Error || external.Error || DescriptorError || device_mod.AdmissionError || error{NativeBackendUnavailable};
pub const WaitError = core.ReferenceError || error{ DeviceMismatch, InvalidFenceValue, SemaphoreNotSubmitted };
pub const Error = ImportFenceError || WaitError || SharedFenceExportError || core.HandleError;
pub const SharedFenceExportError = core.ReferenceError || external.Error || device_mod.AdmissionError || error{ InvalidExportInfo, UnsupportedFenceExport, SemaphoreNotSubmitted, DeviceLost, NativeBackendUnavailable };
pub const Descriptor = struct { handle_type: external.HandleType, fd: external.ExternalSemaphoreHandle, label: []const u8 };

/// Snapshots one supported FD arm without retaining caller descriptor pointers.
pub fn validateDescriptor(descriptor: api.descriptors.SharedFenceDescriptorChain) DescriptorError!Descriptor {
    var count: usize = 0;
    inline for (@typeInfo(api.descriptors.SharedFenceDescriptorChain).@"struct".field_names) |field_name| {
        if (comptime !std.mem.eql(u8, field_name, "label")) {
            if (@field(descriptor, field_name) != null) count += 1;
        }
    }
    if (count == 0) return error.DescriptorChainEmpty;
    if (count != 1) return error.MultipleFenceHandleArms;
    const result: Descriptor = if (descriptor.shared_fence_vk_semaphore_opaque_fd_descriptor) |arm|
        .{ .handle_type = .opaque_fd, .fd = arm.handle, .label = descriptor.label orelse "" }
    else if (descriptor.shared_fence_sync_fd_descriptor) |arm|
        .{ .handle_type = .sync_fd, .fd = arm.handle, .label = descriptor.label orelse "" }
    else
        return error.UnsupportedFenceHandleType;
    if (result.fd < 0 and !(result.handle_type == .sync_fd and result.fd == -1)) return error.InvalidFenceFd;
    return result;
}

/// Publishes one genuine user alias from the central Device import transaction.
pub fn importSharedFence(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: *Device,
    descriptor: *const api.descriptors.SharedFenceDescriptorChain,
) ImportFenceError!api.objects.SharedFence {
    const fence = try device.importSharedFence(allocator, io, descriptor);
    errdefer {
        var cleanup_guard = core.ObjectGuard.lockUncancelable(io, fence.header.tracking);
        defer cleanup_guard.unlock(io);
        fence.header.releaseUserLocked(&cleanup_guard, io) catch unreachable;
    }
    var guard = try core.ObjectGuard.lock(io, fence.header.tracking);
    defer guard.unlock(io);
    return fence.toApi(&guard);
}

/// Owns one actual binary VkSemaphore and optional exported FD at a stable arena address.
/// The Device and its borrowed native dispatch survive final header retirement.
/// Copying this payload is invalid; acquire/release aliases through its core header.
/// Queue consumers hold genuine header leases until accepted serial completion.
pub const SharedFence = struct {
    header: core.Object,
    owner: *Device,
    semaphore: vulkan.VkSemaphore,
    service: external.Service,
    provenance: Provenance,
    binary: BinaryState,
    /// An actual exported FD, owned here until successful output publication.
    exported_fd: ?external.ExternalSemaphoreHandle = null,

    pub const Provenance = enum { imported, exportable };
    pub const BinaryState = union(enum) {
        imported,
        unsubmitted,
        accepted: u64,
        consumed,
    };

    /// Caller holds Device admission and its original ObjectGuard. No second arena.
    /// The caller FD survives success and failure; only its duplicate is consumed.
    /// The returned user reference must be released under the original arena guard.
    pub fn importNative(
        allocator: std.mem.Allocator,
        io: std.Io,
        guard: *const core.ObjectGuard,
        arena: *core.ObjectArena,
        owner: *Device,
        service: external.Service,
        fd: external.ExternalSemaphoreHandle,
        label: []const u8,
    ) ImportFenceError!*SharedFence {
        try arena.checkAllocator(guard, allocator);
        if (arena != &owner.core.arena) return error.ResourceDeviceMismatch;
        if (arena.objectList().marked_destroyed) return error.ResourceDestroyed;
        const destroy_semaphore = service.procs.destroy_semaphore orelse return error.MissingDeviceProc;
        const semaphore = try external.Service.importSemaphore(io, service, fd);
        errdefer destroy_semaphore(service.device, semaphore, null);
        return attach(allocator, io, guard, arena, owner, service, semaphore, .imported, .imported, label);
    }

    /// Creates an unsignaled exportable binary semaphore and one user reference.
    /// No signal state is published until Queue accepts the exact native signal.
    /// Failure publishes no header and destroys any partially created semaphore.
    pub fn createExportable(
        allocator: std.mem.Allocator,
        io: std.Io,
        guard: *const core.ObjectGuard,
        arena: *core.ObjectArena,
        owner: *Device,
        service: external.Service,
    ) ImportFenceError!*SharedFence {
        try arena.checkAllocator(guard, allocator);
        if (arena != &owner.core.arena) return error.ResourceDeviceMismatch;
        if (arena.objectList().marked_destroyed) return error.ResourceDestroyed;
        const destroy_semaphore = service.procs.destroy_semaphore orelse return error.MissingDeviceProc;
        const semaphore = try service.createExportableSemaphore();
        errdefer destroy_semaphore(service.device, semaphore, null);
        return attach(allocator, io, guard, arena, owner, service, semaphore, .exportable, .unsubmitted, "");
    }

    fn attach(
        allocator: std.mem.Allocator,
        io: std.Io,
        guard: *const core.ObjectGuard,
        arena: *core.ObjectArena,
        owner: *Device,
        service: external.Service,
        semaphore: vulkan.VkSemaphore,
        provenance: Provenance,
        binary: BinaryState,
        label: []const u8,
    ) core.CreateError!*SharedFence {
        const self = try arena.create(allocator, guard, SharedFence, .{
            .kind = .shared_fence,
            .state = .initializing,
            .initial_reference = .user,
            .label = label,
        });
        self.owner = owner;
        self.semaphore = semaphore;
        self.service = service;
        self.provenance = provenance;
        self.binary = binary;
        self.exported_fd = null;
        self.header.setInitializedNoError(guard);
        self.header.attach(guard, io);
        return self;
    }

    /// Publishes the existing user reference; this does not acquire another alias.
    pub fn toApi(self: *SharedFence, guard: *const core.ObjectGuard) api.objects.SharedFence {
        const target = self.owner.core.handleFor(guard, SharedFence, self, .shared_fence);
        return .{ .handle = @ptrCast(target.ptr) };
    }

    /// Borrows a live payload after kind, exact Device list, and owner checks.
    pub fn fromHeader(header: *core.Object, guard: *const core.ObjectGuard, owner: *Device) (core.HandleError || WaitError)!*SharedFence {
        guard.assertOwns(owner.core.arena.objectList());
        if (header.kind != .shared_fence) return error.HandleKindMismatch;
        if (header.tracking != owner.core.arena.objectList()) return error.DeviceMismatch;
        if (!header.isAlive(guard) or header.state != .alive) return error.ResourceDestroyed;
        const self: *SharedFence = @fieldParentPtr("header", header);
        if (self.owner != owner) return error.DeviceMismatch;
        return self;
    }

    /// Nonmutating preflight. Queue must lease the header through actual completion.
    pub fn waitSemaphoreLocked(self: *SharedFence, guard: *const core.ObjectGuard, owner: *Device, value: u64) WaitError!vulkan.VkSemaphore {
        if (self.owner != owner) return error.DeviceMismatch;
        try self.checkLive(guard);
        if (value != 1) return error.InvalidFenceValue;
        switch (self.binary) {
            .imported, .accepted => return self.semaphore,
            .unsubmitted => return error.SemaphoreNotSubmitted,
            .consumed => return error.InvalidFenceValue,
        }
    }

    /// Called only after vkQueueSubmit accepted a wait on this actual semaphore.
    pub fn acceptWaitLocked(self: *SharedFence, guard: *const core.ObjectGuard) void {
        guard.assertOwns(self.header.tracking);
        std.debug.assert(self.binary == .imported or self.binary == .accepted);
        self.binary = .consumed;
    }

    /// Nonmutating signal preflight for one not-yet-submitted exportable semaphore.
    pub fn signalSemaphoreLocked(self: *SharedFence, guard: *const core.ObjectGuard, owner: *Device) WaitError!vulkan.VkSemaphore {
        if (self.owner != owner) return error.DeviceMismatch;
        try self.checkLive(guard);
        if (self.binary != .unsubmitted) return error.InvalidFenceValue;
        return self.semaphore;
    }

    /// Serial must be the actual Queue serial accepted with this signal.
    pub fn acceptSignalLocked(self: *SharedFence, guard: *const core.ObjectGuard, serial: u64) void {
        guard.assertOwns(self.header.tracking);
        std.debug.assert(self.binary == .unsubmitted);
        std.debug.assert(serial != 0);
        self.binary = .{ .accepted = serial };
    }

    /// Retries reuse the same cached actual FD and never issue a second SyncFD export.
    pub fn ensureExportedLocked(self: *SharedFence, io: std.Io, guard: *const core.ObjectGuard) SharedFenceExportError!void {
        _ = io;
        try self.checkLive(guard);
        if (self.exported_fd != null) return;
        switch (self.binary) {
            .unsubmitted => return error.SemaphoreNotSubmitted,
            .consumed => return error.UnsupportedFenceExport,
            .imported => {
                // This is queried for the exact imported handle type, not inferred
                // from an extension or a locally fabricated signaled state.
                if (!self.service.export_from_imported) return error.UnsupportedFenceExport;
            },
            .accepted => {},
        }
        const fd = try self.service.exportSemaphore(self.semaphore);
        self.exported_fd = fd;
        if (self.service.handle_type == .sync_fd) self.binary = .consumed;
    }

    /// Transfers a cached real FD to the caller, who closes it with the FD service.
    /// A later SyncFD export is refused; no previously returned FD is reused.
    pub fn takeExportedHandleLocked(self: *SharedFence, guard: *const core.ObjectGuard) SharedFenceExportError!external.ExternalSemaphoreHandle {
        try self.checkLive(guard);
        const fd = self.exported_fd orelse return error.UnsupportedFenceExport;
        self.exported_fd = null;
        return fd;
    }

    /// Takes Device admission, queue gate, and object guard; caches one native export.
    /// Lock cancellation leaves state unchanged; native export is synchronous.
    pub fn ensureExported(self: *SharedFence, io: std.Io) SharedFenceExportError!void {
        try self.owner.acquireOperation(io);
        defer self.owner.releaseOperation(io);
        const context = self.owner.native orelse return error.NativeBackendUnavailable;
        try context.queue_operation_mutex.lock(io);
        defer context.queue_operation_mutex.unlock(io);
        var guard = try core.ObjectGuard.lock(io, self.header.tracking);
        defer guard.unlock(io);
        if (context.terminal_loss) return error.DeviceLost;
        try self.ensureExportedLocked(io, &guard);
    }

    /// Output arms are generated from pinned Dawn metadata. On error out is unchanged.
    pub fn exportInfo(self: *SharedFence, io: std.Io, out: *api.descriptors.SharedFenceExportInfo) SharedFenceExportError!api.enums.Status {
        try self.owner.acquireOperation(io);
        defer self.owner.releaseOperation(io);
        const context = self.owner.native orelse return error.NativeBackendUnavailable;
        try context.queue_operation_mutex.lock(io);
        defer context.queue_operation_mutex.unlock(io);
        var guard = try core.ObjectGuard.lock(io, self.header.tracking);
        defer guard.unlock(io);
        if (context.terminal_loss) return error.DeviceLost;
        try self.checkLive(&guard);
        const opaque_fd = out.shared_fence_vk_semaphore_opaque_fd_export_info != null;
        const sync = out.shared_fence_sync_fd_export_info != null;
        if (opaque_fd == sync) return error.InvalidExportInfo;
        if (opaque_fd != (self.service.handle_type == .opaque_fd)) return error.InvalidExportInfo;
        try self.ensureExportedLocked(io, &guard);
        const fd = try self.takeExportedHandleLocked(&guard);
        var result = out.*;
        if (opaque_fd) {
            result.type_ = .vk_semaphore_opaque_fd;
            result.shared_fence_vk_semaphore_opaque_fd_export_info.?.handle = fd;
        } else {
            result.type_ = .sync_fd;
            result.shared_fence_sync_fd_export_info.?.handle = fd;
        }
        out.* = result;
        return .success;
    }

    fn checkLive(self: *SharedFence, guard: *const core.ObjectGuard) core.ReferenceError!void {
        guard.assertOwns(self.header.tracking);
        if (!self.header.isAlive(guard) or self.header.state != .alive) return error.ResourceDestroyed;
    }

    /// Arena retirement callback. Queue drain/leases must already protect native use.
    /// Releases the native semaphore and any FD not yet transferred to the caller.
    pub fn destroy(self: *SharedFence, guard: *const core.ObjectGuard, io: std.Io, reason: core.DestroyReason) void {
        guard.assertOwns(self.header.tracking);
        _ = reason;
        if (self.exported_fd) |fd| {
            external.closeHandle(io, fd);
            self.exported_fd = null;
        }
        if (self.semaphore != null) {
            self.service.procs.destroy_semaphore.?(self.service.device, self.semaphore, null);
            self.semaphore = null;
        }
        self.binary = .consumed;
    }
};
