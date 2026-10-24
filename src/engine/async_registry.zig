//! Owned completion cells with numeric Instance-local Future IDs.
//!
//! Create one stable registry, prepare an owned typed context, accept its
//! runner, claim/publish its terminal state, then release each cell reference.
//! Callbacks run on publishing/API threads outside registry and owner locks.
//! Execution, typed outcomes and native Io observer tasks belong to adapters.
//! `close` frees the registry once all external users have quiesced; the caller
//! must protect API entry with its Instance lifetime pin. Never copy a live
//! registry/cell or mutate their metadata fields. Allocator/Io backing state
//! remains caller-owned; every effect receives Io explicitly.

const std = @import("std");
const api = @import("../api/root.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const namespace_issue_attempts = 64;
pub const max_live_async_operations = 4096;
pub const AsyncStartError = api.errors.AsyncStartError;
/// Creation shares the finite admission vocabulary; errors own no cell or ID.
pub const RegistryCreateError = AsyncStartError;
pub const FutureWaitError = api.errors.FutureWaitError;
pub const RegistryCloseError = error{InstanceInUse};
pub const ProcessEventsError = api.errors.ProcessEventsError;
pub const ReferenceError = error{ ReferenceCountOverflow, InvalidReference, InvalidRequest };
pub const ObserverWaitError = error{ Canceled, InvalidRequest, ReentrantWait, WaitIterationExhausted, ReferenceCountOverflow };

/// One caller-owned authority for all registries whose IDs can be exchanged.
/// Do not copy or reset it while those registries or IDs remain in use.
pub const FutureNamespaceSource = struct {
    next: std.atomic.Value(u32) = .init(0),
    /// Starts an unused authority. Its address must stay stable after first use.
    pub fn init() FutureNamespaceSource {
        return .{};
    }
    /// Issues once, or reports namespace exhaustion/bounded CAS contention.
    pub fn issue(self: *FutureNamespaceSource) error{ FutureNamespaceExhausted, FutureNamespaceContention }!u32 {
        var previous = self.next.load(.monotonic);
        for (0..namespace_issue_attempts) |_| {
            if (previous == std.math.maxInt(u32)) return error.FutureNamespaceExhausted;
            if (self.next.cmpxchgWeak(previous, previous + 1, .monotonic, .monotonic)) |observed| {
                previous = observed;
            } else return previous + 1;
        }
        return error.FutureNamespaceContention;
    }
};

/// Operation callbacks and the source classes that can delay device loss.
pub const CallbackClass = enum { operation, device_lost, logging, uncaptured_error };
/// Only terminal is ready; the exclusive completing claim is not ready.
pub const Execution = enum { staging, pending, completing, terminal };
/// Delivery is separate from execution and can consume one result only.
pub const Delivery = enum { unclaimed, claimed, delivered, disposed };
/// Each actor balances its own reference; copies of a pointer add no reference.
pub const ReferenceKind = enum { runner, observer, candidate };

/// These hooks use the existing high owner's lifetime lock, not a second lock.
/// lock pins the owner and locks its lifecycle metadata; unlock releases the
/// metadata lock, but a successful claim keeps a pin until end_claim/unlock.
/// claim/end_claim run with owner -> registry locks held. They MUST NOT access
/// object/cache guards, invoke callbacks, allocate, or acquire another lock.
/// A stopped owner may allow detached host events; adapters decide this in claim.
pub const OwnerBinding = struct {
    identity: u64,
    context: *anyopaque,
    lock: *const fn (*anyopaque, Io) void,
    unlock: *const fn (*anyopaque, Io) void,
    claim: *const fn (*anyopaque, CallbackClass) bool,
    end_claim: *const fn (*anyopaque, CallbackClass) void,

    pub fn bind(comptime T: type, identity: u64, owner: *T, comptime hooks: struct {
        lock: *const fn (*T, Io) void,
        unlock: *const fn (*T, Io) void,
        claim: *const fn (*T, CallbackClass) bool,
        end_claim: *const fn (*T, CallbackClass) void,
    }) OwnerBinding {
        const Adapter = struct {
            fn lock(p: *anyopaque, io: Io) void {
                hooks.lock(@ptrCast(@alignCast(p)), io);
            }
            fn unlock(p: *anyopaque, io: Io) void {
                hooks.unlock(@ptrCast(@alignCast(p)), io);
            }
            fn claim(p: *anyopaque, class: CallbackClass) bool {
                return hooks.claim(@ptrCast(@alignCast(p)), class);
            }
            fn end(p: *anyopaque, class: CallbackClass) void {
                hooks.end_claim(@ptrCast(@alignCast(p)), class);
            }
        };
        return .{ .identity = identity, .context = owner, .lock = Adapter.lock, .unlock = Adapter.unlock, .claim = Adapter.claim, .end_claim = Adapter.end };
    }
};

/// Chooses dispatch scheduling and an optional real high-owner lifecycle gate.
/// `owner = null` is detached/host-only; numeric identity survives detachment.
pub const CellOptions = struct {
    mode: api.CallbackMode,
    callback: bool,
    owner: ?OwnerBinding = null,
    owner_identity: u64 = 0,
    callback_class: CallbackClass = .operation,
};

/// Callback, dispose, shutdown settlement, and final destruction all run with
/// explicit Io outside registry/owner locks. The typed wrapper owns the context.
const VTable = struct {
    invoke: *const fn (*Header, Io) void,
    dispose: *const fn (*Header, Io) void,
    shut_down: *const fn (*Header, Io) void,
    destroy: *const fn (*Header, Allocator, Io) void,
};

/// Registry-owned hot metadata. Consumers keep a reference, not an index-slot
/// address, and may write only their typed context under the finisher protocol.
pub const Header = struct {
    registry: *CompletionRegistry,
    vtable: *const VTable,
    future: api.Future = .{ .id = 0 },
    previous: ?*Header = null,
    next: ?*Header = null,
    owner: ?OwnerBinding,
    owner_identity: u64,
    callback_class: CallbackClass,
    mode: api.CallbackMode,
    callback: bool,
    execution: Execution = .staging,
    delivery: Delivery = .unclaimed,
    references: u32 = 1,
    runners: u32 = 0,
    observers: u32 = 0,
    candidates: u32 = 0,
    tracked: bool = false,
    abandoned: bool = false,
    resource_success: bool = false,
    owner_detaching: bool = false,
};

/// Two distinct prepared cells. Each primary reference becomes its own runner.
/// The request context borrows the loss cell through that runner right.
pub const HeaderPair = struct {
    request: *Header,
    loss: *Header,
};

/// Adjacent committed IDs. Copies carry no reference or result ownership.
pub const FuturePair = struct {
    request: api.Future,
    loss: api.Future,
};

/// Stable owned request storage. The context moves on successful prepare;
/// operations are static typed hooks, and no operation payload union is erased.
pub fn Cell(comptime T: type) type {
    return struct {
        header: Header,
        context: T,
        const Self = @This();
        pub const Operations = struct {
            invoke: *const fn (*T, Io) void,
            dispose: *const fn (*T, Io) void,
            shut_down: *const fn (*T, Io) void,
            deinit: *const fn (*T, Allocator, Io) void,
        };
        /// Requires a live header reference. Check before recovering typed context.
        /// Exact static operations identity excludes other cell types and hooks.
        pub fn matchesOperations(h: *const Header, comptime operations: Operations) bool {
            return h.vtable == table(operations);
        }
        fn from(h: *Header) *Self {
            return @fieldParentPtr("header", h);
        }
        fn table(comptime operations: Operations) *const VTable {
            const Adapter = struct {
                fn invoke(h: *Header, io: Io) void {
                    operations.invoke(&from(h).context, io);
                }
                fn dispose(h: *Header, io: Io) void {
                    operations.dispose(&from(h).context, io);
                }
                fn shutdown(h: *Header, io: Io) void {
                    operations.shut_down(&from(h).context, io);
                }
                fn destroy(h: *Header, allocator: Allocator, io: Io) void {
                    const c = from(h);
                    operations.deinit(&c.context, allocator, io);
                    allocator.destroy(c);
                }
                const vtable: VTable = .{ .invoke = invoke, .dispose = dispose, .shut_down = shutdown, .destroy = destroy };
            };
            return &Adapter.vtable;
        }
    };
}

/// Stack-lived, explicitly entered frames also cover owner log/error callbacks
/// without Future IDs. No TLS, global state, ambient Io, or stored userdata.
pub const DispatchFrame = struct {
    previous: ?*DispatchFrame = null,
    owner_identity: u64 = 0,
    future: api.Future = .{ .id = 0 },
    callback_class: CallbackClass = .operation,
    thread: std.Thread.Id = undefined,
    binding: ?OwnerBinding = null,
    active: bool = false,
};

/// Injectable monotonic capability. A sleep must return only at its deadline,
/// or with Canceled; both functions use the same clock and Io backing state.
/// The explicit capability context is caller-owned and must outlive all waits.
pub const Time = struct {
    context: ?*anyopaque = null,
    now: *const fn (?*anyopaque, Io) i96 = nowNative,
    sleep_until: *const fn (?*anyopaque, Io, i96) error{Canceled}!void = sleepNative,
    fn nowNative(_: ?*anyopaque, io: Io) i96 {
        return Io.Timestamp.now(io, .awake).nanoseconds;
    }
    fn sleepNative(_: ?*anyopaque, io: Io, deadline: i96) error{Canceled}!void {
        try Io.sleep(io, .{ .nanoseconds = @max(deadline - nowNative(null, io), 0) }, .awake);
    }
};
/// Explicit bounds for admission, wait input and condition wake iterations.
pub const Options = struct {
    /// Includes delivered cells still held by actors; 1..4096 is supported.
    max_live_operations: u32 = max_live_async_operations,
    /// Exact advertised Instance wait-info limit, including duplicate entries.
    max_wait_count: usize = max_live_async_operations,
    /// Reports WaitIterationExhausted rather than an unbounded wake loop.
    max_wait_iterations: u32 = 1_000_000,
    /// Defaults to Io's awake monotonic clock; replace for another live provider.
    time: Time = .{},
};
/// Non-inline failure-atomic task posting; failure leaves no queued cell borrow.
pub const Post = *const fn (*Header, Io) AsyncStartError!void;

/// One heap-stable Instance registry owns its active index and cell allocations.
/// The allocator must remain unchanged/live and support concurrent publishers.
/// Metadata is mutex-protected; callbacks may reenter independent operations.
pub const CompletionRegistry = struct {
    allocator: Allocator,
    namespace: u32,
    issued: u32 = 0,
    options: Options,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    index: std.AutoHashMapUnmanaged(u32, *Header) = .empty,
    first: ?*Header = null,
    last: ?*Header = null,
    frames: ?*DispatchFrame = null,
    live_cells: u32 = 0,
    prepared_cells: u32 = 0,
    reclaiming_cells: u32 = 0,
    active_callbacks: u32 = 0,
    dispatch_exits: u32 = 0,
    waiters: u32 = 0,
    processors: u32 = 0,
    epoch: u64 = 0,
    epoch_exhausted: bool = false,
    closing: bool = false,

    /// All storage is reserved BEFORE namespace issue. Neither allocator nor Io
    /// backing state is owned. The allocator must be safe on publisher threads.
    pub fn create(allocator: Allocator, _: Io, source: ?*FutureNamespaceSource, options: Options) RegistryCreateError!*CompletionRegistry {
        const authority = source orelse return error.MissingFutureNamespaceSource;
        if (options.max_live_operations == 0 or options.max_live_operations > max_live_async_operations or options.max_wait_iterations == 0) return error.InvalidAsyncCapacity;
        const r = try allocator.create(CompletionRegistry);
        errdefer allocator.destroy(r);
        r.* = .{ .allocator = allocator, .namespace = 0, .options = options };
        errdefer r.index.deinit(allocator);
        try r.index.ensureTotalCapacity(allocator, max_live_async_operations);
        r.namespace = try authority.issue();
        return r;
    }

    /// Success transfers context ownership to the prepared cell. On failure the
    /// caller still owns context. Call rollback after ANY failed accept.
    pub fn prepare(self: *CompletionRegistry, comptime T: type, io: Io, context: T, comptime operations: Cell(T).Operations, options: CellOptions) AsyncStartError!*Cell(T) {
        if (!validMode(options.mode)) return error.InvalidCallbackMode;
        if (options.owner) |owner| if (owner.identity == 0) return error.InvalidOwner;
        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);
        if (self.closing) return error.InstanceShutDown;
        if (self.prepared_cells == std.math.maxInt(u32)) return error.AsyncCapacityExceeded;
        const c = try self.allocator.create(Cell(T));
        self.prepared_cells += 1;
        c.* = .{ .header = .{
            .registry = self,
            .vtable = Cell(T).table(operations),
            .owner = options.owner,
            .owner_identity = if (options.owner) |o| o.identity else options.owner_identity,
            .callback_class = options.callback_class,
            .mode = options.mode,
            .callback = options.callback,
        }, .context = context };
        return c;
    }

    pub fn rollback(self: *CompletionRegistry, io: Io, h: *Header) void {
        self.mutex.lockUncancelable(io);
        std.debug.assert(h.registry == self and h.execution == .staging and h.references == 1);
        self.mutex.unlock(io);
        h.vtable.destroy(h, self.allocator, io);
        self.mutex.lockUncancelable(io);
        self.prepared_cells -= 1;
        self.mutex.unlock(io);
    }

    /// Caller holds its real owner acceptance lock/pin. Post only reserves/posts
    /// a task; it MUST NOT execute it inline or invoke user/owner hooks. A posted
    /// runner cannot enter beginFinish until this lock commits pending. Post
    /// failure MUST mean no queued task retains the pointer. No fallible step
    /// follows successful post, and sequence numbers are consumed only here.
    pub fn accept(self: *CompletionRegistry, io: Io, h: *Header, post: ?Post) AsyncStartError!api.Future {
        return self.acceptSingle(io, h, post, .preserve);
    }

    /// Admits one actual-owner cell and uses its committed Future as owner identity.
    /// Caller holds that owner's lifecycle gate through infallible state binding.
    /// Requires an attached nonzero matching binding. Errors preserve it and ID zero.
    /// Prepared observers survive. The primary becomes the sole runner right.
    pub fn acceptIdentityFromFuture(
        self: *CompletionRegistry,
        io: Io,
        h: *Header,
        post: ?Post,
    ) AsyncStartError!api.Future {
        return self.acceptSingle(io, h, post, .future);
    }

    const AdmissionIdentity = enum { preserve, future };

    fn acceptSingle(
        self: *CompletionRegistry,
        io: Io,
        h: *Header,
        post: ?Post,
        comptime identity: AdmissionIdentity,
    ) AsyncStartError!api.Future {
        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);
        if (h.registry != self or h.execution != .staging or h.future.id != 0) return error.InvalidRequest;
        if (identity == .future) {
            const owner = h.owner orelse return error.InvalidOwner;
            if (owner.identity == 0 or owner.identity != h.owner_identity)
                return error.InvalidOwner;
            if (h.references >= std.math.maxInt(u32) - (2 * max_live_async_operations + 8))
                return error.ReferenceCountOverflow;
            if (self.prepared_cells == 0 or h.delivery != .unclaimed or h.tracked or
                h.owner_detaching or h.previous != null or h.next != null or
                h.runners != 0 or h.candidates != 0 or
                @as(u64, h.references) != @as(u64, h.observers) + 1)
                return error.InvalidRequest;
        }
        if (self.closing) return error.InstanceShutDown;
        if (self.live_cells >= self.options.max_live_operations) return error.AsyncCapacityExceeded;
        if (self.issued == std.math.maxInt(u32)) return error.FutureIdExhausted;
        if (h.references == std.math.maxInt(u32)) return error.ReferenceCountOverflow;
        if (post) |submit| try submit(h, io);
        self.issued += 1;
        h.future = .{ .id = (@as(u64, self.namespace) << 32) | self.issued };
        if (identity == .future) {
            h.owner_identity = h.future.id;
            h.owner.?.identity = h.future.id;
        }
        h.execution = .pending;
        h.references += 1; // tracking; prepared primary becomes runner, observers survive
        h.runners = 1;
        h.tracked = true;
        h.previous = self.last;
        if (self.last) |tail| tail.next = h else self.first = h;
        self.last = h;
        self.index.putAssumeCapacityNoClobber(self.issued, h);
        self.live_cells += 1;
        self.prepared_cells -= 1;
        self.wakeLocked(io);
        return h.future;
    }

    /// Admits both cells with one non-inline post of the request header.
    /// Caller holds both prepared owner pins and the owner acceptance gate.
    /// Any error leaves IDs, references, staging and registry accounting unchanged.
    /// Success transfers both primary references to separate runner rights.
    /// Prepared observers survive. No fallible work follows successful post.
    pub fn acceptPair(
        self: *CompletionRegistry,
        io: Io,
        pair: HeaderPair,
        post: Post,
    ) AsyncStartError!FuturePair {
        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);
        if (pair.request == pair.loss) return error.InvalidRequest;
        if (self.prepared_cells < 2) return error.InvalidRequest;
        for ([_]*Header{ pair.request, pair.loss }) |h| {
            if (h.registry != self or h.execution != .staging or h.future.id != 0 or
                h.delivery != .unclaimed or h.tracked or h.owner_detaching or
                h.previous != null or h.next != null or h.runners != 0 or
                h.candidates != 0) return error.InvalidRequest;
            // Keep the same internal dispatch reserve as prepared observer retains.
            if (h.references >= std.math.maxInt(u32) - (2 * max_live_async_operations + 8))
                return error.ReferenceCountOverflow;
            if (@as(u64, h.references) != @as(u64, h.observers) + 1)
                return error.InvalidRequest;
            if (h.owner) |owner| {
                if (owner.identity == 0 or owner.identity != h.owner_identity)
                    return error.InvalidOwner;
            }
        }
        if (self.closing) return error.InstanceShutDown;
        if (self.live_cells > self.options.max_live_operations or
            self.options.max_live_operations - self.live_cells < 2)
            return error.AsyncCapacityExceeded;
        if (self.issued > std.math.maxInt(u32) - 2) return error.FutureIdExhausted;
        try post(pair.request, io);
        for ([_]*Header{ pair.request, pair.loss }, 1..) |h, offset| {
            const sequence = self.issued + @as(u32, @intCast(offset));
            h.future = .{ .id = (@as(u64, self.namespace) << 32) | sequence };
            h.execution = .pending;
            h.references += 1;
            h.runners = 1;
            h.tracked = true;
            h.previous = self.last;
            if (self.last) |tail| tail.next = h else self.first = h;
            self.last = h;
            self.index.putAssumeCapacityNoClobber(sequence, h);
        }
        self.issued += 2;
        self.live_cells += 2;
        self.prepared_cells -= 2;
        self.wakeLocked(io);
        return .{ .request = pair.request.future, .loss = pair.loss.future };
    }

    /// Caller owns both runners and holds old Instance, then actual Device gates.
    /// Required high pins are already installed. Replacement identity is nonzero.
    /// Only a pending, unclaimed, attached pair can move. False changes nothing.
    /// This uncancelable transaction allocates nothing and preserves both IDs.
    pub fn retargetPendingPair(
        self: *CompletionRegistry,
        io: Io,
        pair: HeaderPair,
        expected_identity: u64,
        replacement: OwnerBinding,
    ) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(pair.request != pair.loss);
        std.debug.assert(pair.request.registry == self);
        std.debug.assert(pair.loss.registry == self);
        std.debug.assert(pair.request.runners > 0);
        std.debug.assert(pair.loss.runners > 0);
        std.debug.assert(replacement.identity != 0);
        if (self.closing) return false;
        for ([_]*Header{ pair.request, pair.loss }) |h| {
            if (h.execution != .pending or h.delivery != .unclaimed or h.owner_detaching or
                h.owner_identity != expected_identity) return false;
            const owner = h.owner orelse return false;
            if (owner.identity != expected_identity) return false;
        }
        for ([_]*Header{ pair.request, pair.loss }) |h| {
            h.owner = replacement;
            h.owner_identity = replacement.identity;
        }
        self.wakeLocked(io);
        return true;
    }

    /// Adds one checked actor reference. Staging supports observers only.
    pub fn retain(self: *CompletionRegistry, io: Io, h: *Header, kind: ReferenceKind) ReferenceError!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (h.registry != self or h.owner_detaching or (h.execution == .staging and kind != .observer)) return error.InvalidRequest;
        // Reserve for bounded concurrent pollers, waiters and one invocation.
        if (h.references >= std.math.maxInt(u32) - (2 * max_live_async_operations + 8)) return error.ReferenceCountOverflow;
        const count = refCounter(h, kind);
        if (count.* == std.math.maxInt(u32)) return error.ReferenceCountOverflow;
        count.* += 1;
        h.references += 1;
    }

    /// Consumes one actor reference; final typed cleanup runs outside all locks.
    pub fn release(self: *CompletionRegistry, io: Io, h: *Header, kind: ReferenceKind) ReferenceError!void {
        self.mutex.lockUncancelable(io);
        if (h.registry != self or (h.execution == .staging and kind != .observer)) {
            self.mutex.unlock(io);
            return error.InvalidRequest;
        }
        const counter = refCounter(h, kind);
        if (counter.* == 0) {
            self.mutex.unlock(io);
            return error.InvalidReference;
        }
        counter.* -= 1;
        const destroy = self.dropLocked(h);
        self.mutex.unlock(io);
        if (destroy) self.finishFree(io, h);
    }

    /// A referenced actor exclusively wins terminal settlement. Payload writes
    /// happen after this claim and before publish; no reader can yet see them.
    pub fn beginFinish(self: *CompletionRegistry, io: Io, h: *Header) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(h.registry == self and h.references > 0);
        if (h.execution != .pending) return false;
        h.execution = .completing;
        return true;
    }

    /// No allocation, cancellation point, or fallible result. A winning actor
    /// retains its runner/reference through return, including spontaneous calls.
    pub fn publish(self: *CompletionRegistry, io: Io, h: *Header, resource_success: bool) void {
        self.mutex.lockUncancelable(io);
        std.debug.assert(h.registry == self and h.execution == .completing);
        self.pinCandidateLocked(h) catch unreachable; // publication owns a private pin
        h.resource_success = resource_success;
        h.execution = .terminal;
        self.wakeLocked(io);
        const abandon = h.abandoned;
        const no_consumer = !h.callback and h.observers == 0;
        const spontaneous = h.mode == .allow_spontaneous;
        self.mutex.unlock(io);
        if (abandon or no_consumer) self.dispose(io, h) else if (spontaneous) {
            _ = self.dispatch(io, h, false) catch unreachable; // reserved internal slots
        }
        self.release(io, h, .candidate) catch unreachable;
    }

    /// Takes ONE observer reference. Cancellation abandons the native consumer,
    /// never withdraws accepted execution. Do not use on a callback route.
    pub fn cancelObserver(self: *CompletionRegistry, io: Io, h: *Header) void {
        self.mutex.lockUncancelable(io);
        std.debug.assert(!h.callback and h.observers > 0);
        if (h.delivery == .unclaimed) h.abandoned = true;
        const dispose_now = h.execution == .terminal and h.delivery == .unclaimed;
        self.mutex.unlock(io);
        if (dispose_now) self.dispose(io, h);
        self.release(io, h, .observer) catch unreachable;
    }

    /// The native Io adapter owns an observer ref (also valid while staging).
    /// This observes readiness only; resource ownership still requires the one
    /// consumer claim. Cancellation leaves the accepted runner and ID intact.
    pub fn waitReady(self: *CompletionRegistry, io: Io, h: *Header) ObserverWaitError!void {
        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);
        if (h.registry != self or h.observers == 0) return error.InvalidRequest;
        if (self.waiters >= max_live_async_operations) return error.ReferenceCountOverflow;
        self.waiters += 1;
        defer self.waiters -= 1;
        for (0..self.options.max_wait_iterations) |_| {
            if (h.execution == .terminal) return;
            if (self.reentrantLocked(h, std.Thread.getCurrentId())) return error.ReentrantWait;
            self.condition.wait(io, &self.mutex) catch return error.Canceled;
        }
        return error.WaitIterationExhausted;
    }

    /// Native observer already owns a reference. Its result read/move is valid
    /// only after this succeeds; finishConsumer ends that exclusive claim.
    pub fn claimConsumer(self: *CompletionRegistry, io: Io, h: *Header) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(h.registry == self and h.observers > 0);
        if (h.callback or h.abandoned or h.owner_detaching or h.execution != .terminal or h.delivery != .unclaimed) return false;
        h.delivery = .claimed;
        return true;
    }
    /// Commits the native consumer's completed transfer and removes tracking.
    pub fn finishConsumer(self: *CompletionRegistry, io: Io, h: *Header) void {
        self.mutex.lockUncancelable(io);
        std.debug.assert(!h.callback and h.delivery == .claimed and h.observers > 0);
        h.delivery = .delivered;
        h.resource_success = false;
        const destroy = self.untrackLocked(h);
        self.wakeLocked(io);
        self.mutex.unlock(io);
        if (destroy) self.finishFree(io, h);
    }

    /// Pins the first tracked, attached owner cell in numeric ID order, or null.
    /// Caller holds the actual owner lifecycle pin/gate. This grants no detach
    /// or delivery right. Release the returned candidate after use.
    /// Overflow changes nothing. The uncancelable scan allocates no storage.
    pub fn retainOwnerCandidate(
        self: *CompletionRegistry,
        io: Io,
        identity: u64,
    ) ReferenceError!?*Header {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var cursor = self.first;
        for (0..self.index.count()) |_| {
            const h = cursor orelse break;
            if (h.tracked and h.owner != null and !h.owner_detaching and
                h.owner_identity == identity)
            {
                try self.pinCandidateLocked(h);
                return h;
            }
            cursor = h.next;
        }
        return null;
    }

    /// The caller owns ONE candidate ref and holds the real owner lifecycle
    /// lock. Reserve before clearing any typed owner/native pointer. Dispatch
    /// and native consumers cannot claim until the infallible commit below.
    pub fn beginOwnerDetach(self: *CompletionRegistry, io: Io, h: *Header) error{ResourceInUse}!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (h.registry != self or h.owner == null or h.owner_detaching or h.execution != .terminal or h.delivery == .claimed or h.runners != 0 or h.observers != 0 or h.candidates != 1 or h.resource_success) return error.ResourceInUse;
        h.owner_detaching = true;
    }
    /// Caller still owns its candidate ref and owner lifecycle lock, and has
    /// now cleared every typed native/owner pointer using the reserved state.
    pub fn detachOwner(self: *CompletionRegistry, io: Io, h: *Header) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(h.owner_detaching and h.candidates > 0);
        h.owner = null;
        h.owner_detaching = false;
        self.wakeLocked(io);
    }

    /// Call under the real owner gate before destructive teardown admission.
    pub fn ownerPreflight(self: *CompletionRegistry, io: Io, identity: u64) error{ResourceInUse}!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var frame = self.frames;
        for (0..self.active_callbacks) |_| {
            const f = frame orelse break;
            if (f.owner_identity == identity) return error.ResourceInUse;
            frame = f.previous;
        }
        var cell = self.first;
        for (0..self.index.count()) |_| {
            const h = cell orelse break;
            if (h.owner_identity == identity and h.resource_success and h.delivery != .delivered and h.delivery != .disposed) return error.ResourceInUse;
            cell = h.next;
        }
    }

    /// Claims a stack frame for a real owner callback; invoke only after return.
    pub fn enterExternalDispatch(self: *CompletionRegistry, io: Io, frame: *DispatchFrame, owner: OwnerBinding, class: CallbackClass) error{ InstanceShutDown, CallbackCapacityExceeded, OwnerStopped, InvalidOwner, InvalidRequest }!void {
        if (owner.identity == 0) return error.InvalidOwner;
        if (frame.active) return error.InvalidRequest;
        owner.lock(owner.context, io);
        defer owner.unlock(owner.context, io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closing) return error.InstanceShutDown;
        if (@as(u64, self.active_callbacks) + self.dispatch_exits >= max_live_async_operations) return error.CallbackCapacityExceeded;
        if (!owner.claim(owner.context, class)) return error.OwnerStopped;
        frame.* = .{ .owner_identity = owner.identity, .callback_class = class, .thread = std.Thread.getCurrentId(), .binding = owner };
        self.linkFrameLocked(frame);
    }
    /// Ends the source claim before polling loss and pins registry through exit.
    pub fn leaveExternalDispatch(self: *CompletionRegistry, io: Io, frame: *DispatchFrame) ProcessEventsError!void {
        self.mutex.lockUncancelable(io);
        std.debug.assert(frame.active);
        self.dispatch_exits += 1; // bounded by frame admission, including exits
        self.mutex.unlock(io);
        defer {
            self.mutex.lockUncancelable(io);
            self.dispatch_exits -= 1;
            self.mutex.unlock(io);
        }
        self.endFrame(io, frame);
        try self.processEligible(io, true);
    }

    /// Polls ready process/spontaneous callbacks up to entry's issued high-water.
    pub fn processEvents(self: *CompletionRegistry, io: Io) ProcessEventsError!void {
        try self.processEligible(io, false);
    }

    /// Validates nullable slice/count agreement before dispatch; zero succeeds.
    pub fn waitAnyCount(self: *CompletionRegistry, io: Io, count: usize, infos: ?[]api.FutureWaitInfo, timeout_ns: u64) FutureWaitError!api.WaitStatus {
        if (infos) |slice| {
            if (slice.len != count) return error.FutureCountMismatch;
            return self.waitAny(io, slice, timeout_ns);
        }
        if (count != 0) return error.FutureCountMismatch;
        return .success;
    }

    /// Validates all IDs first, dispatches once, and marks every duplicate alike.
    /// Completion means delivery ended, not merely a terminal result exists.
    /// Timeout/cancellation leave accepted work intact. Zero timeout is a poll.
    pub fn waitAny(self: *CompletionRegistry, io: Io, infos: []api.FutureWaitInfo, timeout_ns: u64) FutureWaitError!api.WaitStatus {
        if (infos.len == 0) return .success;
        if (infos.len > self.options.max_wait_count) return error.WaitCountExceeded;
        self.mutex.lock(io) catch return error.Canceled;
        if (self.closing) {
            self.mutex.unlock(io);
            return error.InstanceShutDown;
        }
        for (infos) |info| self.validateLocked(info.future) catch |err| {
            self.mutex.unlock(io);
            return err;
        };
        if (self.waiters >= max_live_async_operations) {
            self.mutex.unlock(io);
            return error.ReferenceCountOverflow;
        }
        self.waiters += 1;
        self.mutex.unlock(io);
        defer {
            self.mutex.lockUncancelable(io);
            self.waiters -= 1;
            self.mutex.unlock(io);
        }
        var timer: Timer = .{ .registry = self, .deadline = 0 };
        var group: Io.Group = .init;
        defer group.cancel(io);
        var timer_started = false;
        const deadline: i96 = if (timeout_ns == 0) 0 else std.math.add(i96, self.options.time.now(self.options.time.context, io), @as(i96, timeout_ns)) catch std.math.maxInt(i96);
        for (0..self.options.max_wait_iterations) |_| {
            self.mutex.lock(io) catch return error.Canceled;
            const epoch = self.epoch;
            self.mutex.unlock(io);
            var reentrant = false;
            for (infos) |info| {
                self.mutex.lockUncancelable(io);
                const h = self.index.get(@truncate(info.future.id));
                if (h) |cell| {
                    if (self.reentrantLocked(cell, std.Thread.getCurrentId())) {
                        reentrant = true;
                        self.mutex.unlock(io);
                        continue;
                    }
                    if (cell.execution == .terminal and cell.delivery == .unclaimed and cell.callback and !cell.owner_detaching) {
                        self.pinCandidateLocked(cell) catch |err| {
                            self.mutex.unlock(io);
                            return err;
                        };
                        self.mutex.unlock(io);
                        const dispatched = self.dispatch(io, cell, true);
                        self.release(io, cell, .candidate) catch unreachable;
                        _ = try dispatched;
                    } else self.mutex.unlock(io);
                } else self.mutex.unlock(io);
            }
            self.mutex.lock(io) catch return error.Canceled;
            var completed = false;
            for (infos) |*info| {
                const h = self.index.get(@truncate(info.future.id));
                info.completed = if (h) |cell| cell.delivery == .delivered or cell.delivery == .disposed else true;
                completed = completed or info.completed;
            }
            if (completed) {
                self.mutex.unlock(io);
                return .success;
            }
            if (reentrant) {
                self.mutex.unlock(io);
                return error.ReentrantWait;
            }
            if (self.closing) {
                self.mutex.unlock(io);
                return error.InstanceShutDown;
            }
            if (self.epoch_exhausted) {
                self.mutex.unlock(io);
                return error.WaitEpochExhausted;
            }
            if (timer.canceled) {
                self.mutex.unlock(io);
                return error.Canceled;
            }
            if (timeout_ns == 0 or self.options.time.now(self.options.time.context, io) >= deadline) {
                self.mutex.unlock(io);
                return .timed_out;
            }
            if (!timer_started) {
                self.mutex.unlock(io);
                timer.deadline = deadline;
                group.concurrent(io, Timer.run, .{ io, &timer }) catch return error.TimedWaitUnavailable;
                timer_started = true;
                continue;
            }
            if (self.epoch != epoch) {
                self.mutex.unlock(io);
                continue;
            }
            self.condition.wait(io, &self.mutex) catch {
                self.mutex.unlock(io);
                return error.Canceled;
            };
            self.mutex.unlock(io);
        }
        return error.WaitIterationExhausted;
    }

    /// Final host boundary. Refusal changes no acceptance/lifecycle state.
    /// Runner/observer/candidate owners, attached native owners, resources,
    /// active callbacks and waiters must quiesce BEFORE close. Pending host-only
    /// cells with no runner can be settled here. Mode is ignored only here.
    pub fn close(self: *CompletionRegistry, io: Io) RegistryCloseError!void {
        self.mutex.lockUncancelable(io);
        if (self.closing or self.prepared_cells != 0 or self.reclaiming_cells != 0 or self.active_callbacks != 0 or self.dispatch_exits != 0 or self.waiters != 0 or self.processors != 0 or self.live_cells != self.index.count()) {
            self.mutex.unlock(io);
            return error.InstanceInUse;
        }
        var cursor = self.first;
        for (0..self.index.count()) |_| {
            const h = cursor orelse unreachable;
            if (h.references != 1 or h.owner != null or h.resource_success or h.execution == .completing or h.delivery == .claimed) {
                self.mutex.unlock(io);
                return error.InstanceInUse;
            }
            cursor = h.next;
        }
        self.closing = true;
        self.wakeLocked(io);
        self.mutex.unlock(io);
        for (0..self.options.max_live_operations) |_| {
            self.mutex.lockUncancelable(io);
            const h = self.first orelse {
                self.mutex.unlock(io);
                break;
            };
            self.pinCandidateLocked(h) catch unreachable; // preflight proved references == 1
            const pending = h.execution == .pending;
            if (pending) h.execution = .completing;
            self.mutex.unlock(io);
            if (pending) {
                h.vtable.shut_down(h, io);
                self.publish(io, h, false);
            }
            if (h.callback) {
                _ = self.dispatch(io, h, true) catch unreachable;
            } else self.dispose(io, h);
            self.release(io, h, .candidate) catch unreachable;
        }
        std.debug.assert(self.live_cells == 0 and self.index.count() == 0);
        self.index.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    const Timer = struct {
        registry: *CompletionRegistry,
        deadline: i96,
        canceled: bool = false, // protected by registry mutex
        fn run(io: Io, timer: *Timer) void {
            const r = timer.registry;
            const result = r.options.time.sleep_until(r.options.time.context, io, timer.deadline);
            r.mutex.lockUncancelable(io);
            if (result) |_| {} else |_| {
                timer.canceled = true;
            }
            r.wakeLocked(io);
            r.mutex.unlock(io);
        }
    };

    fn processEligible(self: *CompletionRegistry, io: Io, spontaneous_only: bool) ProcessEventsError!void {
        self.mutex.lockUncancelable(io);
        if (self.closing) {
            self.mutex.unlock(io);
            return error.InstanceShutDown;
        }
        if (self.processors >= max_live_async_operations) {
            self.mutex.unlock(io);
            return error.ReferenceCountOverflow;
        }
        self.processors += 1;
        const high_water = self.issued;
        self.mutex.unlock(io);
        defer {
            self.mutex.lockUncancelable(io);
            self.processors -= 1;
            self.mutex.unlock(io);
        }
        var after: u32 = 0;
        for (0..self.options.max_live_operations) |_| {
            self.mutex.lockUncancelable(io);
            var cursor = self.first;
            var candidate: ?*Header = null;
            for (0..self.index.count()) |_| {
                const h = cursor orelse break;
                const sequence: u32 = @truncate(h.future.id);
                if (sequence > after and sequence <= high_water) {
                    candidate = h;
                    break;
                }
                cursor = h.next;
            }
            const h = candidate orelse {
                self.mutex.unlock(io);
                return;
            };
            after = @truncate(h.future.id);
            const eligible = h.execution == .terminal and h.delivery == .unclaimed and h.callback and !h.owner_detaching and h.mode != .wait_any_only and (!spontaneous_only or h.mode == .allow_spontaneous);
            if (eligible) self.pinCandidateLocked(h) catch |err| {
                self.mutex.unlock(io);
                return err;
            };
            self.mutex.unlock(io);
            if (eligible) {
                const dispatched = self.dispatch(io, h, false);
                self.release(io, h, .candidate) catch unreachable;
                _ = try dispatched;
            }
        }
    }

    // Every caller owns a runner/candidate reference before entering this path.
    fn dispatch(self: *CompletionRegistry, io: Io, h: *Header, wait_authority: bool) error{ReferenceCountOverflow}!bool {
        self.mutex.lockUncancelable(io);
        if (h.execution != .terminal or h.owner_detaching) {
            self.mutex.unlock(io);
            return false;
        }
        const owner = h.owner;
        self.mutex.unlock(io);
        if (owner) |o| o.lock(o.context, io);
        self.mutex.lockUncancelable(io);
        const eligible = h.execution == .terminal and h.delivery == .unclaimed and h.callback and !h.owner_detaching and (wait_authority or h.mode != .wait_any_only) and !self.lossBlockedLocked(h.owner_identity, h.callback_class) and self.active_callbacks < max_live_async_operations;
        if (!eligible) {
            self.mutex.unlock(io);
            if (owner) |o| o.unlock(o.context, io);
            return false;
        }
        self.pinCandidateLocked(h) catch |err| {
            self.mutex.unlock(io);
            if (owner) |o| o.unlock(o.context, io);
            return err;
        };
        if (owner) |o| if (!o.claim(o.context, h.callback_class)) {
            h.candidates -= 1;
            _ = self.dropLocked(h);
            self.mutex.unlock(io);
            o.unlock(o.context, io);
            return false;
        };
        var frame: DispatchFrame = .{ .owner_identity = h.owner_identity, .future = h.future, .callback_class = h.callback_class, .thread = std.Thread.getCurrentId(), .binding = owner };
        self.linkFrameLocked(&frame);
        h.delivery = .claimed;
        self.mutex.unlock(io);
        if (owner) |o| o.unlock(o.context, io);
        h.vtable.invoke(h, io);
        // endFrame reacquires owner first. User code has returned before either
        // lock is acquired; no resource handle is dereferenced after invocation.
        if (owner) |o| o.lock(o.context, io);
        self.mutex.lockUncancelable(io);
        h.delivery = .delivered;
        h.resource_success = false;
        _ = self.untrackLocked(h); // invocation reference prevents final free
        self.unlinkFrameLocked(&frame);
        if (owner) |o| o.end_claim(o.context, h.callback_class);
        h.candidates -= 1;
        const destroy = self.dropLocked(h);
        self.wakeLocked(io);
        self.mutex.unlock(io);
        if (owner) |o| o.unlock(o.context, io);
        if (destroy) self.finishFree(io, h);
        return true;
    }

    fn dispose(self: *CompletionRegistry, io: Io, h: *Header) void {
        self.mutex.lockUncancelable(io);
        if (h.execution != .terminal or h.delivery != .unclaimed) {
            self.mutex.unlock(io);
            return;
        }
        self.pinCandidateLocked(h) catch unreachable; // reserved internal slots
        h.delivery = .claimed;
        self.mutex.unlock(io);
        h.vtable.dispose(h, io);
        self.mutex.lockUncancelable(io);
        h.delivery = .disposed;
        h.resource_success = false;
        _ = self.untrackLocked(h);
        h.candidates -= 1;
        const destroy = self.dropLocked(h);
        self.wakeLocked(io);
        self.mutex.unlock(io);
        if (destroy) self.finishFree(io, h);
    }

    fn endFrame(self: *CompletionRegistry, io: Io, frame: *DispatchFrame) void {
        const owner = frame.binding;
        if (owner) |o| o.lock(o.context, io);
        self.mutex.lockUncancelable(io);
        self.unlinkFrameLocked(frame);
        if (owner) |o| o.end_claim(o.context, frame.callback_class);
        self.wakeLocked(io);
        self.mutex.unlock(io);
        if (owner) |o| o.unlock(o.context, io);
    }
    fn linkFrameLocked(self: *CompletionRegistry, frame: *DispatchFrame) void {
        std.debug.assert(!frame.active);
        frame.previous = self.frames;
        frame.active = true;
        self.frames = frame;
        self.active_callbacks += 1;
    }
    fn unlinkFrameLocked(self: *CompletionRegistry, frame: *DispatchFrame) void {
        std.debug.assert(frame.active);
        var link = &self.frames;
        for (0..self.active_callbacks) |_| {
            const current = link.* orelse unreachable;
            if (current == frame) {
                link.* = frame.previous;
                frame.active = false;
                self.active_callbacks -= 1;
                return;
            }
            link = &current.previous;
        }
        unreachable;
    }
    fn reentrantLocked(self: *CompletionRegistry, h: *Header, thread: std.Thread.Id) bool {
        var frame = self.frames;
        for (0..self.active_callbacks) |_| {
            const f = frame orelse break;
            if (f.thread == thread and (f.future.id == h.future.id or (h.callback_class == .device_lost and f.owner_identity == h.owner_identity and sourceClass(f.callback_class)))) return true;
            frame = f.previous;
        }
        return false;
    }
    fn lossBlockedLocked(self: *CompletionRegistry, identity: u64, class: CallbackClass) bool {
        if (class != .device_lost) return false;
        var frame = self.frames;
        for (0..self.active_callbacks) |_| {
            const f = frame orelse break;
            if (f.owner_identity == identity and sourceClass(f.callback_class)) return true;
            frame = f.previous;
        }
        return false;
    }
    fn validateLocked(self: *CompletionRegistry, future: api.Future) FutureWaitError!void {
        if (future.id == 0) return error.InvalidFutureId;
        if (@as(u32, @truncate(future.id >> 32)) != self.namespace) return error.FutureInstanceMismatch;
        const sequence: u32 = @truncate(future.id);
        if (sequence == 0 or sequence > self.issued) return error.InvalidFutureId;
    }
    fn pinCandidateLocked(_: *CompletionRegistry, h: *Header) error{ReferenceCountOverflow}!void {
        if (h.references == std.math.maxInt(u32) or h.candidates == std.math.maxInt(u32)) return error.ReferenceCountOverflow;
        h.references += 1;
        h.candidates += 1;
    }
    fn untrackLocked(self: *CompletionRegistry, h: *Header) bool {
        std.debug.assert(h.tracked);
        const removed = self.index.remove(@truncate(h.future.id));
        std.debug.assert(removed);
        if (h.previous) |p| p.next = h.next else self.first = h.next;
        if (h.next) |n| n.previous = h.previous else self.last = h.previous;
        h.next = null;
        h.previous = null;
        h.tracked = false;
        return self.dropLocked(h);
    }
    fn dropLocked(self: *CompletionRegistry, h: *Header) bool {
        std.debug.assert(h.references > 0);
        h.references -= 1;
        if (h.references != 0) return false;
        std.debug.assert(!h.tracked and (h.delivery == .delivered or h.delivery == .disposed));
        self.live_cells -= 1;
        self.reclaiming_cells += 1;
        return true;
    }
    fn finishFree(self: *CompletionRegistry, io: Io, h: *Header) void {
        h.vtable.destroy(h, self.allocator, io);
        self.mutex.lockUncancelable(io);
        self.reclaiming_cells -= 1;
        self.mutex.unlock(io);
    }
    fn wakeLocked(self: *CompletionRegistry, io: Io) void {
        if (self.epoch == std.math.maxInt(u64)) self.epoch_exhausted = true else self.epoch += 1;
        self.condition.broadcast(io);
    }
};
fn validMode(mode: api.CallbackMode) bool {
    return switch (@backingInt(mode)) {
        1, 2, 3 => true,
        else => false,
    };
}
fn sourceClass(class: CallbackClass) bool {
    return class == .logging or class == .uncaptured_error;
}
fn refCounter(h: *Header, kind: ReferenceKind) *u32 {
    return switch (kind) {
        .runner => &h.runners,
        .observer => &h.observers,
        .candidate => &h.candidates,
    };
}
