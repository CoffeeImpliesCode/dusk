//! Stable owned error scopes and acceptance-time asynchronous capture.
//!
//! All ledger mutations share the device's original ObjectGuard. Pop detaches
//! matching immediately, but accepted work owns stable record pins and blocks
//! every outer pop. User callbacks and readiness notifications run only from
//! explicit post-unlock dispatch. No worker-frame ErrorData pointer escapes.

const std = @import("std");
const errors = @import("errors.zig");
const object = @import("object.zig");

pub const ErrorFilter = enum { validation, out_of_memory, internal };

pub fn matchesFilter(filter: ErrorFilter, code: errors.ErrorCode) bool {
    return filter == filterForCode(code);
}

fn filterForCode(code: errors.ErrorCode) ErrorFilter {
    return switch (code) {
        .validation => .validation,
        .device_lost => .internal,
        .unrecoverable => |member| switch (member) {
            error.OutOfDeviceMemory, error.OutOfHostMemory => .out_of_memory,
            error.PipelineUncategorized, error.InternalInvariantViolated, error.Unimplemented => .internal,
        },
    };
}

pub const ScopeCaptureMask = packed struct {
    validation: bool = false,
    out_of_memory: bool = false,
    internal: bool = false,

    pub const all: ScopeCaptureMask = .{ .validation = true, .out_of_memory = true, .internal = true };

    fn contains(self: ScopeCaptureMask, filter: ErrorFilter) bool {
        return switch (filter) {
            .validation => self.validation,
            .out_of_memory => self.out_of_memory,
            .internal => self.internal,
        };
    }

    fn set(self: *ScopeCaptureMask, filter: ErrorFilter, enabled: bool) void {
        switch (filter) {
            .validation => self.validation = enabled,
            .out_of_memory => self.out_of_memory = enabled,
            .internal => self.internal = enabled,
        }
    }
};

pub const UncapturedErrorCallback = *const fn (std.mem.Allocator, std.Io, *anyopaque, errors.ErrorView) void;
pub const ScopeNotifyFn = *const fn (std.Io, *anyopaque) void;
/// Runs once after owned binding reclamation, outside all locks, on the
/// dispatching thread. The context remains live through notification return;
/// the callback may reenter Core or release its external owner.
pub const ScopeReleaseContextFn = *const fn (std.Io, *anyopaque) void;
pub const ScopeAllocationError = std.mem.Allocator.Error || error{ AllocatorMismatch, ScopeReferenceCountOverflow, ScopeBindingExists };
pub const PopError = error{ErrorScopeStackEmpty};
pub const PopBoundError = PopError || error{
    AllocatorMismatch,
    ScopeReferenceCountOverflow,
    ScopeBindingExists,
};
pub const ScopeTakeError = error{ ScopePending, ScopeTicketConsumed };
pub const ScopeWaitError = error{ Canceled, WaitIterationExhausted, ScopeTicketConsumed };

/// One heap allocation per push. Only refs/pending/captured/binding mutate;
/// each mutation requires the stack's final-address bound ObjectGuard.
pub const ScopeRecord = struct {
    stack: *ErrorScopeStack,
    filter: ErrorFilter,
    references: u64 = 1,
    pending: u64 = 0,
    captured: ?errors.ErrorRef = null,
    condition: std.Io.Condition = .init,
    binding: ?*BindingNode = null,

    fn release(self: *ScopeRecord, guard: *const object.ObjectGuard) void {
        const stack = self.stack;
        stack.bind(guard);
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return;
        std.debug.assert(self.pending == 0 and self.binding == null);
        if (self.captured) |ref| ref.release();
        stack.live_records -= 1;
        stack.allocator.destroy(self);
    }

    fn capture(self: *ScopeRecord, ref: errors.ErrorRef) void {
        if (self.captured != null) ref.release() else self.captured = ref;
    }
};

pub const ScopeResult = struct {
    error_ref: ?errors.ErrorRef = null,

    pub fn deinit(self: *ScopeResult) void {
        if (self.error_ref) |ref| ref.release();
        self.error_ref = null;
    }
};

/// Linear owner of a detached record; copying does not create a ticket owner.
pub const ScopeTicket = struct {
    record: ?*ScopeRecord,

    pub fn isReady(self: *const ScopeTicket, guard: *const object.ObjectGuard) bool {
        const record = self.record orelse return false;
        record.stack.bind(guard);
        return record.pending == 0;
    }

    pub fn take(self: *ScopeTicket, guard: *const object.ObjectGuard) ScopeTakeError!ScopeResult {
        const record = self.record orelse return error.ScopeTicketConsumed;
        record.stack.bind(guard);
        if (record.pending != 0) return error.ScopePending;
        const result: ScopeResult = .{ .error_ref = record.captured };
        record.captured = null;
        record.stack.tickets -= 1;
        self.record = null;
        record.release(guard);
        return result;
    }

    /// Condition wait atomically releases/reacquires the ORIGINAL object mutex.
    /// The caller retains its ticket; cancellation never withdraws accepted work.
    pub fn wait(self: *const ScopeTicket, io: std.Io, guard: *object.ObjectGuard, max_wakes: usize) ScopeWaitError!void {
        const record = self.record orelse return error.ScopeTicketConsumed;
        record.stack.bind(guard);
        var wakes: usize = 0;
        while (record.pending != 0) {
            if (wakes == max_wakes) return error.WaitIterationExhausted;
            wakes += 1;
            try record.condition.wait(io, guard.mutex);
        }
    }

    pub fn bind(self: *const ScopeTicket, gpa: std.mem.Allocator, guard: *const object.ObjectGuard, context: *anyopaque, notify: ScopeNotifyFn) ScopeAllocationError!ScopeBinding {
        const record = self.record orelse @panic("ScopeTicket already consumed");
        const stack = record.stack;
        try stack.checkAllocator(gpa, guard);
        try BindingNode.preflightAttach(record);
        const node = try gpa.create(BindingNode);
        node.* = .{
            .allocator = gpa,
            .context = context,
            .notify = notify,
            .activated = true,
        };
        node.attach(record);
        return .{ .node = node };
    }

    pub fn deinit(self: *ScopeTicket, guard: *const object.ObjectGuard) void {
        if (self.record) |record| {
            record.stack.bind(guard);
            record.stack.tickets -= 1;
            self.record = null;
            record.release(guard);
        }
    }
};

const BindingNode = struct {
    allocator: std.mem.Allocator,
    record: ?*ScopeRecord = null,
    context: *anyopaque,
    notify: ScopeNotifyFn,
    release_context: ?ScopeReleaseContextFn = null,
    release_next: ?*BindingNode = null,
    references: u2 = 1,
    activated: bool = false,
    canceled: bool = false,
    notified: bool = false,

    fn preflightAttach(record: *ScopeRecord) error{ ScopeBindingExists, ScopeReferenceCountOverflow }!void {
        if (record.binding != null) return error.ScopeBindingExists;
        if (record.references == std.math.maxInt(u64)) return error.ScopeReferenceCountOverflow;
    }

    fn attach(self: *BindingNode, record: *ScopeRecord) void {
        std.debug.assert(self.record == null);
        std.debug.assert(self.references == 1);
        std.debug.assert(record.binding == null);
        std.debug.assert(record.references < std.math.maxInt(u64));
        self.record = record;
        record.references += 1;
        record.binding = self;
    }

    fn claim(self: *BindingNode) bool {
        if (!self.activated or self.canceled or self.notified) return false;
        if (self.record.?.pending != 0) return false;
        std.debug.assert(self.references == 1);
        self.notified = true;
        self.references += 1;
        return true;
    }

    fn release(self: *BindingNode, guard: *const object.ObjectGuard) ScopeBindingRelease {
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return .{};
        const record = self.record.?;
        if (record.binding == self) record.binding = null;
        self.record = null;
        record.release(guard);
        if (self.release_context != null) return .{ .node = self };
        self.allocator.destroy(self);
        return .{};
    }

    fn cancel(self: *BindingNode, guard: *const object.ObjectGuard) ScopeBindingRelease {
        const record = self.record.?;
        record.stack.bind(guard);
        self.canceled = true;
        if (record.binding == self) record.binding = null;
        return self.release(guard);
    }

    fn invokeClaimed(self: *BindingNode, io: std.Io) ScopeBindingRelease {
        const stack = self.record.?.stack;
        self.notify(io, self.context);
        var guard = object.ObjectGuard.lockUncancelable(io, stack.objects.?);
        const cleanup = self.release(&guard);
        guard.unlock(io);
        return cleanup;
    }

    fn notifyReady(self: *BindingNode, io: std.Io) void {
        const stack = self.record.?.stack;
        var guard = object.ObjectGuard.lockUncancelable(io, stack.objects.?);
        // First activation and its possible claim are atomic. Before this,
        // settlement cannot invoke a callback that cancels the initial handle.
        self.activated = true;
        const claimed = self.claim();
        guard.unlock(io);
        if (claimed) {
            var cleanup = self.invokeClaimed(io);
            cleanup.dispatch(io);
        }
    }
};

/// Required callbacks for a prepared, externally owned context. A successful
/// prepare transfers one context owner; allocation failure transfers nothing.
pub const ScopeBindingOptions = struct {
    context: *anyopaque,
    /// Called at most once after readiness and explicit activation, outside
    /// all locks, on the dispatching thread. May cancel and reenter Core.
    notify_callback: ScopeNotifyFn,
    release_context_callback: ScopeReleaseContextFn,
};

/// Allocates a record-independent binding before admission. Borrows `gpa`
/// through cleanup; does not access or change any stack. Owns `options.context`
/// only on success, until its one release callback.
pub fn prepareBinding(gpa: std.mem.Allocator, options: ScopeBindingOptions) ScopeAllocationError!PreparedScopeBinding {
    const node = try gpa.create(BindingNode);
    node.* = .{
        .allocator = gpa,
        .context = options.context,
        .notify = options.notify_callback,
        .release_context = options.release_context_callback,
    };
    return .{ .node = node };
}

/// Linear owner of one unbound node and its context. Copies are not additional
/// owners. `popBound` consumes it only on success; no stack must remain live.
pub const PreparedScopeBinding = struct {
    /// `null` means consumed by popBound or deinit.
    node: ?*BindingNode,

    /// Aborts an unused reservation outside ALL locks. Frees its node before
    /// invoking the release callback. Repeating on this consumed handle is inert.
    pub fn deinit(self: *PreparedScopeBinding, io: std.Io) void {
        const node = self.node orelse return;
        std.debug.assert(node.record == null);
        std.debug.assert(node.references == 1);
        self.node = null;
        node.references = 0;
        var cleanup: ScopeBindingRelease = .{ .node = node };
        cleanup.dispatch(io);
    }
};

/// Linear cleanup owner returned by cancellation. Its final nodes have no Core
/// record references. Dispatch after ALL locks are released; copies do not own
/// another cleanup. An empty handle, including repeat dispatch, is inert.
pub const ScopeBindingRelease = struct {
    node: ?*BindingNode = null,

    fn prepend(self: *ScopeBindingRelease, cleanup: ScopeBindingRelease) void {
        if (cleanup.node) |node| {
            std.debug.assert(node.release_next == null);
            node.release_next = self.node;
            self.node = node;
        }
    }

    /// Frees each final node before calling its context release hook. May
    /// reenter or destroy the former stack owner; no stack is accessed afterward.
    pub fn dispatch(self: *ScopeBindingRelease, io: std.Io) void {
        var next = self.node;
        self.node = null;
        while (next) |node| {
            std.debug.assert(node.references == 0);
            std.debug.assert(node.record == null);
            next = node.release_next;
            const context = node.context;
            const callback = node.release_context.?;
            const allocator = node.allocator;
            allocator.destroy(node);
            callback(io, context);
        }
    }
};

/// Linear binding owner with an owned external context. The node pins its
/// record through any claimed notification. Cancellation releases the context
/// only after that claim returns. Copies do not retain another owner.
pub const OwnedScopeBinding = struct {
    node: ?*BindingNode,

    /// Activates notification under the original guard and claims readiness
    /// before unlocking. Call outside ALL locks after storing the binding in
    /// its callback host. A claimed callback may consume this handle.
    pub fn notifyReady(self: *const OwnedScopeBinding, io: std.Io) void {
        const node = self.node orelse return;
        node.notifyReady(io);
    }

    /// Cancels future notification under the original guard. Dispatch the
    /// returned cleanup after unlocking. An active claim instead owns cleanup
    /// until its notification returns. Repeat cancellation is inert.
    pub fn deinit(self: *OwnedScopeBinding, guard: *const object.ObjectGuard) ScopeBindingRelease {
        const node = self.node orelse return .{};
        self.node = null;
        return node.cancel(guard);
    }
};

/// Owns the detached record ticket and its separately cancellable binding.
pub const PopBoundResult = struct {
    ticket: ScopeTicket,
    binding: OwnedScopeBinding,
};

/// Explicit real-future seam. A binding owns a record pin until cancellation;
/// callbacks may cancel/reenter because an active invocation owns another pin.
/// Context is borrowed: its owner must keep it alive through binding lifetime
/// AND any already-claimed notification return. The native future owner supplies
/// its actual cell/owner pin; this core seam owns no registry or engine state.
pub const ScopeBinding = struct {
    node: ?*BindingNode,

    pub fn notifyReady(self: *const ScopeBinding, io: std.Io) void {
        const node = self.node orelse return;
        node.notifyReady(io);
    }

    pub fn deinit(self: *ScopeBinding, guard: *const object.ObjectGuard) void {
        const node = self.node orelse return;
        self.node = null;
        std.debug.assert(node.release_context == null);
        const cleanup = node.cancel(guard);
        std.debug.assert(cleanup.node == null);
    }
};

/// Owns exactly one sealed diagnostic and one callback-host pin. Move-only.
pub const UncapturedDelivery = struct {
    stack: *ErrorScopeStack,
    error_ref: ?errors.ErrorRef,
    allocator: std.mem.Allocator,

    /// Caller must have released ALL locks before entry, not merely ObjectGuard.
    pub fn dispatch(self: *UncapturedDelivery, io: std.Io) void {
        const ref = self.error_ref orelse return;
        self.error_ref = null;
        const stack = self.stack;
        stack.uncaptured_callback(self.allocator, io, stack.uncaptured_context, ref.view());
        ref.release();
        var guard = object.ObjectGuard.lockUncancelable(io, stack.objects.?);
        defer guard.unlock(io);
        std.debug.assert(stack.deliveries > 0);
        stack.deliveries -= 1;
    }
};

const LeaseEntry = struct { record: *ScopeRecord, captures: ScopeCaptureMask };

pub const ScopeLeaseSet = struct {
    stack: *ErrorScopeStack,
    entries: ?[]LeaseEntry,

    /// One routing owner coexists with the operation owner, including when
    /// no scope matches and the reference becomes an uncaptured delivery.
    pub fn errorQuota(self: *const ScopeLeaseSet) u32 {
        std.debug.assert(self.entries != null);
        return 1;
    }

    /// ErrorRef consumes one PREPAID routing slot, not the operation-result slot.
    /// Call only for the winning terminal claim. Duplicate settlement leaves
    /// the supplied reference owned by its caller and changes no ledger.
    pub fn settle(self: *ScopeLeaseSet, guard: *const object.ObjectGuard, error_ref: ?errors.ErrorRef) error{ScopeLeaseAlreadySettled}!ScopeSettlement {
        const entries = self.entries orelse return error.ScopeLeaseAlreadySettled;
        self.stack.bind(guard);
        var delivery: ?UncapturedDelivery = null;
        if (error_ref) |ref| {
            const filter = filterForCode(ref.view().code);
            var target: ?*ScopeRecord = null;
            for (entries) |entry| {
                if (entry.captures.contains(filter)) {
                    target = entry.record;
                    break;
                }
            }
            if (target) |record| record.capture(ref) else delivery = self.stack.delivery(ref);
        }
        // Routing precedes readiness. Retain the lease record pins until the
        // post-unlock wake batch has broadcast and notified all ready records.
        for (entries) |entry| {
            std.debug.assert(entry.record.pending > 0);
            entry.record.pending -= 1;
        }
        self.entries = null;
        return .{ .stack = self.stack, .entries = entries, .delivery = delivery };
    }

    /// Preaccept rollback; accepted tasks must settle, not abandon their lease.
    pub fn deinit(self: *ScopeLeaseSet, guard: *const object.ObjectGuard) ScopeSettlement {
        return self.settle(guard, null) catch @panic("ScopeLeaseSet already settled");
    }
};

/// Owns the original lease array and every record pin until dispatch completes.
pub const ScopeSettlement = struct {
    stack: *ErrorScopeStack,
    entries: ?[]LeaseEntry,
    delivery: ?UncapturedDelivery,

    pub fn dispatch(self: *ScopeSettlement, io: std.Io) void {
        const entries = self.entries orelse return;
        self.entries = null;
        const stack = self.stack;
        var cleanup: ScopeBindingRelease = .{};
        for (entries) |entry| {
            var guard = object.ObjectGuard.lockUncancelable(io, stack.objects.?);
            const ready = entry.record.pending == 0;
            const binding = if (ready) entry.record.binding else null;
            const claimed = if (binding) |node| node.claim() else false;
            guard.unlock(io);
            if (ready) entry.record.condition.broadcast(io);
            if (claimed) cleanup.prepend(binding.?.invokeClaimed(io));
            guard = object.ObjectGuard.lockUncancelable(io, stack.objects.?);
            entry.record.release(&guard);
            guard.unlock(io);
        }
        stack.allocator.free(entries);
        if (self.delivery) |*delivery| delivery.dispatch(io);
        self.delivery = null;
        var guard = object.ObjectGuard.lockUncancelable(io, stack.objects.?);
        std.debug.assert(stack.lease_sets > 0);
        stack.lease_sets -= 1;
        guard.unlock(io);
        // Release hooks may drop the final external device pin. All settlement
        // arrays, record pins and ledger owners must be gone before that point.
        cleanup.dispatch(io);
    }
};

pub const ErrorScopeStack = struct {
    allocator: std.mem.Allocator,
    objects: ?*object.ObjectList = null,
    scopes: std.ArrayList(*ScopeRecord) = .empty,
    live_records: u64 = 0,
    lease_sets: u64 = 0,
    tickets: u64 = 0,
    deliveries: u64 = 0,
    uncaptured_context: *anyopaque,
    uncaptured_callback: UncapturedErrorCallback,

    pub const InitOptions = struct {
        allocator: std.mem.Allocator,
        uncaptured_context: *anyopaque,
        uncaptured_callback: UncapturedErrorCallback,
    };

    pub fn init(options: InitOptions) ErrorScopeStack {
        return .{
            .allocator = options.allocator,
            .uncaptured_context = options.uncaptured_context,
            .uncaptured_callback = options.uncaptured_callback,
        };
    }

    /// First operation binds only the final stable device/list address.
    pub fn bind(self: *ErrorScopeStack, guard: *const object.ObjectGuard) void {
        if (self.objects) |objects| guard.assertOwns(objects) else {
            guard.assertOwns(guard.objects);
            self.objects = guard.objects;
        }
    }

    fn checkAllocator(self: *ErrorScopeStack, gpa: std.mem.Allocator, guard: *const object.ObjectGuard) error{AllocatorMismatch}!void {
        self.bind(guard);
        if (gpa.ptr != self.allocator.ptr or gpa.vtable != self.allocator.vtable) return error.AllocatorMismatch;
    }

    pub fn preflightDeinit(self: *ErrorScopeStack, guard: *const object.ObjectGuard) error{ResourceInUse}!void {
        self.bind(guard);
        if (self.lease_sets != 0 or self.tickets != 0 or self.deliveries != 0 or self.live_records != self.scopes.items.len) return error.ResourceInUse;
        for (self.scopes.items) |record| {
            if (record.references != 1 or record.pending != 0 or record.binding != null) return error.ResourceInUse;
        }
    }

    pub fn deinit(self: *ErrorScopeStack, gpa: std.mem.Allocator, guard: *const object.ObjectGuard) error{ AllocatorMismatch, ResourceInUse }!void {
        try self.checkAllocator(gpa, guard);
        try self.preflightDeinit(guard);
        for (self.scopes.items) |record| record.release(guard);
        self.scopes.deinit(gpa);
        self.* = undefined;
    }

    pub fn empty(self: *ErrorScopeStack, guard: *const object.ObjectGuard) bool {
        self.bind(guard);
        return self.scopes.items.len == 0;
    }

    pub fn push(self: *ErrorScopeStack, gpa: std.mem.Allocator, guard: *const object.ObjectGuard, filter: ErrorFilter) ScopeAllocationError!void {
        try self.checkAllocator(gpa, guard);
        if (self.live_records == std.math.maxInt(u64)) return error.ScopeReferenceCountOverflow;
        const record = try gpa.create(ScopeRecord);
        errdefer gpa.destroy(record);
        try self.scopes.ensureUnusedCapacity(gpa, 1);
        record.* = .{ .stack = self, .filter = filter };
        self.scopes.appendAssumeCapacity(record);
        self.live_records += 1;
    }

    pub fn beginPop(self: *ErrorScopeStack, guard: *const object.ObjectGuard) PopError!ScopeTicket {
        self.bind(guard);
        const record = self.scopes.pop() orelse return error.ErrorScopeStackEmpty;
        // Each ticket is backed by one existing open-record reference. Their
        // count cannot exceed live_records, already checked at push.
        self.tickets += 1;
        return .{ .record = record };
    }

    /// Atomically detaches the current innermost record and attaches an already
    /// allocated owned binding. No allocation or callback occurs here. Checks
    /// allocator identity and all counters before mutation; every error leaves
    /// the open stack and prepared owner unchanged. Activate after unlocking.
    pub fn popBound(
        self: *ErrorScopeStack,
        guard: *const object.ObjectGuard,
        prepared: *PreparedScopeBinding,
    ) PopBoundError!PopBoundResult {
        const node = prepared.node orelse @panic("PreparedScopeBinding already consumed");
        try self.checkAllocator(node.allocator, guard);
        std.debug.assert(node.record == null);
        std.debug.assert(node.references == 1);
        if (self.scopes.items.len == 0) return error.ErrorScopeStackEmpty;
        const record = self.scopes.items[self.scopes.items.len - 1];
        try BindingNode.preflightAttach(record);
        if (self.tickets == std.math.maxInt(u64)) return error.ScopeReferenceCountOverflow;
        const popped = self.scopes.pop().?;
        std.debug.assert(popped == record);
        self.tickets += 1;
        node.attach(record);
        prepared.node = null;
        return .{ .ticket = .{ .record = record }, .binding = .{ .node = node } };
    }

    pub fn captureLeaseSet(self: *ErrorScopeStack, gpa: std.mem.Allocator, guard: *const object.ObjectGuard, possible: ScopeCaptureMask) ScopeAllocationError!ScopeLeaseSet {
        try self.checkAllocator(gpa, guard);
        if (self.lease_sets == std.math.maxInt(u64)) return error.ScopeReferenceCountOverflow;
        for (self.scopes.items) |record| {
            if (record.references == std.math.maxInt(u64) or record.pending == std.math.maxInt(u64)) return error.ScopeReferenceCountOverflow;
        }
        const entries = try gpa.alloc(LeaseEntry, self.scopes.items.len);
        var remaining = possible;
        var index = entries.len;
        while (index != 0) {
            index -= 1;
            const record = self.scopes.items[index];
            var captures: ScopeCaptureMask = .{};
            if (remaining.contains(record.filter)) {
                captures.set(record.filter, true);
                remaining.set(record.filter, false);
            }
            entries[index] = .{ .record = record, .captures = captures };
        }
        for (entries) |entry| {
            entry.record.references += 1;
            entry.record.pending += 1;
        }
        self.lease_sets += 1;
        return .{ .stack = self, .entries = entries };
    }

    pub fn handleError(self: *ErrorScopeStack, guard: *const object.ObjectGuard, ref: errors.ErrorRef) ?UncapturedDelivery {
        self.bind(guard);
        const filter = filterForCode(ref.view().code);
        var index = self.scopes.items.len;
        while (index != 0) {
            index -= 1;
            const record = self.scopes.items[index];
            if (record.filter == filter) {
                record.capture(ref);
                return null;
            }
        }
        return self.delivery(ref);
    }

    fn delivery(self: *ErrorScopeStack, ref: errors.ErrorRef) UncapturedDelivery {
        // A finite amount of live owned error storage bounds delivery owners;
        // overflowing the ledger is an always-on ownership-contract failure.
        std.debug.assert(self.deliveries < std.math.maxInt(u64));
        self.deliveries += 1;
        return .{ .stack = self, .error_ref = ref, .allocator = self.allocator };
    }
};

/// Borrows only a final-address owner. The held guard and owned ref are explicit;
/// routing returns a delivery so this interface cannot call user code inline.
pub const ErrorSink = struct {
    context: *anyopaque,
    consume_error_callback: *const fn (*const object.ObjectGuard, *anyopaque, errors.ErrorRef) ?UncapturedDelivery,

    pub fn init(context: *anyopaque, consume: *const fn (*const object.ObjectGuard, *anyopaque, errors.ErrorRef) ?UncapturedDelivery) ErrorSink {
        return .{ .context = context, .consume_error_callback = consume };
    }

    pub fn consumeError(self: *const ErrorSink, guard: *const object.ObjectGuard, ref: errors.ErrorRef) ?UncapturedDelivery {
        return self.consume_error_callback(guard, self.context, ref);
    }
};
