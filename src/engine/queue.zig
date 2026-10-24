//! The Vulkan queue: one command pool, a bounded pool of command contexts, and
//! a bounded pool of fences.
//!
//! **What this file is.** The port of `src/dawn/native/vulkan/QueueVk.{h,cpp}`
//! (102 + 540 lines) at Dawn revision
//! `32f77c02294310054a660c393feded4bcb3f203c`.
//!
//! **What this file does not claim.** It does not claim `native/Queue.{h,cpp}`
//! (779 lines). Those are the back-end-neutral front end: `apiSubmit`,
//! `apiOnSubmittedWorkDone`, the validation rules and the tracked-callback map
//! (`Queue.cpp:172`-`:184`, `Queue.h:149`). M9 owns the Vulkan queue the front
//! end replays into; the front end lands with M8's adapter and device surface.
//! It does not claim command recording either: what a command buffer contains is
//! M18's, so `submit` takes the buffers rather than building them.
//!
//! **One difference from upstream, named.** Dawn's two pools are unbounded
//! (`mFencesInFlight` is a deque at `QueueVk.h:84`, `mUnusedFences` a list at
//! `:86`), and its fence wait is `while (1)` (`QueueVk.cpp:496`) that retries
//! forever when the caller passed an infinite timeout (`:519`-`:531`). The port
//! bounds both so an unbounded driver retry cannot hang the library.
//!
//! **No allocator parameter on `init`.** It allocates nothing: the pools are
//! fixed arrays, so there is nothing to fail and nothing to inject.
//!
//! The caller uniquely owns the queue. Do not copy it.
//! Construction may return and move the value before a native query set registers.
//! After registration, keep that exact queue storage alive and at the same address.
//! This obligation ends when every query set deregisters or `deinit` detaches all query sets.
//! A destroyed query set can remain registered until its last submission completes.
//! The low caller keeps all declared resource references owned through unlocked native work.
//! Registered query pools add one lease in the same core ledger, not a second lifetime authority.
//! Submit/wait/deinit take the canonical ObjectList and acquire its guard only for header stages.
//! Call them without an already-held ObjectGuard; blocking native waits never hold that guard.

const std = @import("std");
const vulkan = @import("vulkan");
const dispatch = @import("../vk/dispatch.zig");
const platform = @import("../platform/root.zig");
const vulkan_device = @import("vulkan_device.zig");
const query_set = @import("query_set.zig");
const buffer_module = @import("buffer.zig");
const core = @import("../core/root.zig");

/// The live-handle counter, so a queue that forgets a destroy is a number.
pub const HandleSet = vulkan_device.HandleSet;

/// The bound the acceptance names for a fence wait, in nanoseconds.
pub const fence_wait_timeout_ns: u64 = 5000 * std.time.ns_per_ms;

/// How many fences the two pools hold together. Dawn's are unbounded; a fixed
/// array keeps `submit` free of allocation and gives exhaustion its own error.
pub const max_fence_count = 16;

/// How many times `wait` may report exhaustion rather than a completed serial.
/// Dawn's retry at `QueueVk.cpp:519`-`:531` has no bound, so a fence that never
/// signals spins forever. The port stops and says so.
pub const max_fence_wait_iteration_count = 4;

/// How many command contexts the queue holds. Dawn recycles them through
/// `mUnusedCommands` (`QueueVk.h:92`) and a serial-tracked task
/// (`QueueVk.cpp:376`-`:402`); the port needs the same count, not the same
/// bookkeeping, because M9 has one submission in flight at a time.
pub const max_command_context_count = 4;

/// Everything a Vulkan call needs, as a value.
///
/// A caller that holds a queue and not a device takes this struct by value, so
/// nothing reaches back through a pointer to a device it does not own.
pub const Context = struct {
    /// Persistent owner of queue-retained resources; must outlive queue teardown.
    allocator: std.mem.Allocator,
    /// The three proc tiers. There is one device tier per device, so a queue
    /// cannot look it up from a device it was not handed.
    dispatch: dispatch.Dispatch,
    /// The device the queue belongs to.
    vk_device: vulkan.VkDevice,
    /// The one queue, fetched at index zero of `queue_family_index`.
    vk_queue: vulkan.VkQueue,
    /// The family the device was created with.
    queue_family_index: u32,
    /// The memory-type table, for the allocation that follows the queue.
    memory_properties: *const vulkan.VkPhysicalDeviceMemoryProperties,
    handles: *HandleSet,
};

/// The dispatch tier, or one entry point in it, is missing.
///
/// A null dispatch field is a typed error, never a forced unwrap, so every
/// entry point this file reaches is bound through an
/// `orelse` that reports rather than through `procs.foo.?`. Two members carry
/// that: a `Context` with no device tier, which `init` refuses
/// (`src/engine/queue.zig:231`) and which only a hand-built `Context` can reach,
/// and a device proc the loader did not resolve. `dispatch.loadDeviceProcs`
/// refuses a table with a null field itself (`src/vk/dispatch.zig:1061`), so
/// both name the hand-built case.
///
/// The rest of the set is `dispatch.Error`, the `VkResult` mapping
/// in `src/vk/dispatch.zig`.
pub const ProcError = dispatch.Error || error{
    DeviceProcTierMissing,
    /// `dispatch.LoadError`'s member of the same name, restated rather than
    /// merged. `LoadError` also names `OutOfMemory` and the global and instance
    /// halves, and a queue reaches no loader and allocates nothing: it names
    /// the half its own `Context` can leave out.
    MissingDeviceProc,
};

/// A command pool, the one buffer taken from it, and where its submission is.
pub const CommandContext = struct {
    pool: vulkan.VkCommandPool,
    command_buffer: vulkan.VkCommandBuffer,
    /// Whether a submission has not been retired yet.
    in_flight: bool = false,
    /// The serial the in-flight submission took.
    submitted_serial: platform.Serial = 0,
};

/// A fence and the serial it signals.
const InFlightFence = struct {
    fence: vulkan.VkFence,
    serial: platform.Serial,
};

/// The Vulkan queue.
pub const Queue = struct {
    context: Context,
    /// Borrowed stable mutex bound to the canonical core ObjectList. Header stages
    /// take it through ObjectGuard; timeline publication then takes its inner lock.
    /// The caller separately serializes ownership of the low queue itself.
    device_mutex: *platform.DeviceMutex,
    /// Ports `ExecutionQueueBase::mLastSubmittedSerial` and `mCompletedSerial`
    /// (`ExecutionQueue.h:192`-`:193`), which the platform module owns.
    timeline: platform.Timeline,
    /// A null `pool` is a slot with no command pool in it. Every read is
    /// bounded by `context_count` or `recording_index`, and `destroyContext`
    /// returns early on a null pool, so the zero value is what a freed slot
    /// must carry. The `@splat` shape is `unused_fences`' below.
    contexts: [max_command_context_count]CommandContext = @splat(.{
        .pool = null,
        .command_buffer = null,
    }),
    context_count: u32 = 0,
    /// Which context the caller records into next. Dawn's single
    /// `mRecordingContext` (`QueueVk.h:94`) is this index plus the array.
    recording_index: u32 = 0,
    /// Read only below `fences_in_flight_count`, which `init` leaves at zero.
    fences_in_flight: [max_fence_count]InFlightFence = @splat(.{
        .fence = null,
        .serial = 0,
    }),
    fences_in_flight_count: u32 = 0,
    unused_fences: [max_fence_count]vulkan.VkFence = @splat(null),
    unused_fence_count: u32 = 0,
    recording_poisoned: bool = false,
    query_sets: ?*query_set.QuerySet = null,
    query_set_count: usize = 0,
    completed_serial: platform.Serial = 0,
    temporary_buffers: std.ArrayList(TemporaryBuffer) = .empty,
    deferred_cleanup_error: ?ProcError = null,

    const TemporaryBuffer = struct {
        buffer: *buffer_module.Buffer,
        allocator: std.mem.Allocator,
        serial: platform.Serial = 0,
    };

    pub const InitOptions = struct {
        context: Context,
        device_mutex: *platform.DeviceMutex,
    };

    pub const RecordingError = ProcError || error{
        /// Every context is still in flight. Dawn allocates another pool
        /// (`QueueVk.cpp:255`-`:281`) with no bound; the port names the bound
        /// and reports exhaustion as its own error.
        CommandContextPoolExhausted,
        /// `vkCreateCommandPool` succeeded and returned null.
        CommandPoolCreationReturnedNull,
        /// `vkAllocateCommandBuffers` succeeded and returned a null buffer.
        CommandBufferAllocationReturnedNull,
    };

    pub const InitError = RecordingError || error{
        /// The queue handle is null. `Queue::Initialize` writes whatever
        /// `vkGetDeviceQueue` returned and asserts nothing (`QueueVk.cpp:95`),
        /// so a null queue would reach `vkQueueSubmit`. The port refuses it.
        QueueHandleIsNull,
    };

    pub const SubmitError = RecordingError || core.ReferenceError || error{
        Canceled,
        QuerySetIsError,
        QuerySetDestroyed,
        RecordingPoisoned,
        /// Pending query and temporary-buffer uses belong to the recording buffer.
        PendingRecordingNotSubmitted,
        /// `SubmitOptions.command_buffers` is empty. Dawn submits a context it
        /// built, so its list is never empty (`QueueVk.cpp:329`-`:338`); a
        /// caller that passes nothing has a bug, and the port names it instead
        /// of submitting zero work.
        NoCommandBuffer,
        /// Both fence pools are empty. `Queue::GetUnusedFence`
        /// (`QueueVk.cpp:404`-`:439`) cannot report this because it creates the
        /// fence it needs; a fixed pool can run out.
        FencePoolExhausted,
        /// `vkCreateFence` succeeded and returned null.
        FenceCreationReturnedNull,
    };

    pub const WaitError = ProcError || platform.WaitError || core.ReferenceError || error{
        SerialNotSubmitted,
        TemporaryBufferRetirementFailed,
        /// `vkWaitForFences` returned `VK_TIMEOUT` with the bound reached. Dawn
        /// returns `kWaitSerialTimeout` for the same case (`QueueVk.cpp:533`).
        FenceWaitTimedOut,
        /// The retry bound is gone. Dawn's loop is `while (1)` (`:496`), so this
        /// is the port's bound and not an upstream condition.
        WaitIterationExhausted,
        /// `vkGetFenceStatus` returned a code that is neither `VK_NOT_READY`
        /// nor a success. Dawn passes it to `CheckVkSuccess`
        /// (`QueueVk.cpp:150`), which is `dispatch.checkVkSuccess` here.
        FenceStatusFailed,
    };

    pub const CleanupError = ProcError || core.ReferenceError ||
        error{ Canceled, TemporaryBufferRetirementFailed };

    pub const WaitOptions = struct {
        /// The serial to reach. Ports `waitSerial` (`QueueVk.cpp:485`).
        serial: platform.Serial,
        /// The bound. Dawn passes the caller's timeout straight through
        /// (`QueueVk.cpp:516`); the acceptance names 5,000 ms, so that is the
        /// default rather than a required argument.
        timeout_ns: u64 = fence_wait_timeout_ns,
    };

    /// What `submit` ends and submits.
    pub const SubmitOptions = struct {
        /// The command buffers, in submission order. A caller records into
        /// `commandBuffer` and passes that; a caller that recorded into earlier
        /// contexts passes them all.
        command_buffers: []const vulkan.VkCommandBuffer,
    };

    /// What one submission is identified by afterwards.
    pub const SubmitResult = struct {
        /// The fence this submission signals.
        fence: vulkan.VkFence,
        /// The serial it took from the timeline.
        serial: platform.Serial,
    };

    /// Ports `Queue::Create` (`QueueVk.cpp:80`), `Queue::Initialize`
    /// (`:93`-`:101`), `Queue::PrepareRecordingContext` (`:202`-`:216`) and
    /// `Queue::BeginVkCommandBuffer` (`:240`-`:296`).
    ///
    /// The queue handle is the caller's, because `Device.fetchQueue` performs
    /// the `vkGetDeviceQueue` at `QueueVk.cpp:95` and the family is chosen
    /// before the queue exists.
    ///
    /// Returns a uniquely owned value with no registered query sets.
    /// The caller may move it into its final storage before native query registration.
    /// Do not copy the queue. After registration, keep its storage alive and unmoved
    /// until all query sets deregister or `deinit` detaches them.
    pub fn init(options: InitOptions) InitError!Queue {
        if (options.context.dispatch.device == null) return error.DeviceProcTierMissing;
        if (options.context.vk_queue == null) return error.QueueHandleIsNull;

        var queue: Queue = .{
            .context = options.context,
            .device_mutex = options.device_mutex,
            .timeline = .{},
        };
        try queue.createContext(0);
        queue.context_count = 1;
        queue.recording_index = 0;
        return queue;
    }

    /// The command pool behind the recording context, which is the answer to
    /// `GetPendingRecordingContext` (`QueueVk.h:53`) for a caller that has not
    /// recorded yet.
    pub fn commandPool(self: *const Queue) vulkan.VkCommandPool {
        return self.contexts[self.recording_index].pool;
    }

    /// The command buffer to record into. `init` began it, so a caller records
    /// without calling `vkBeginCommandBuffer` itself.
    pub fn commandBuffer(self: *const Queue) vulkan.VkCommandBuffer {
        return self.contexts[self.recording_index].command_buffer;
    }

    pub fn poisonRecording(self: *Queue) void {
        self.recording_poisoned = true;
    }

    pub fn trackQuerySet(
        self: *Queue,
        guard: *const core.ObjectGuard,
        set: *query_set.QuerySet,
    ) (core.ReferenceError || error{ QuerySetIsError, QuerySetDestroyed })!void {
        if (set.header.tracking != guard.objects) return error.ResourceDeviceMismatch;
        guard.assertOwns(set.header.tracking);
        if (set.header.tracking.mutex != &self.device_mutex.mutex)
            return error.ResourceDeviceMismatch;
        if (!set.header.node.linked or set.header.reference_count == 0 or set.header.state != .alive)
            return error.QuerySetDestroyed;
        try set.validateCanUseInSubmit(guard);
        if (set.backend_queue != self) return error.ResourceDeviceMismatch;
        set.pending_use = true;
    }

    pub fn retireQueryPool(
        self: *Queue,
        guard: *const core.ObjectGuard,
        io: std.Io,
        set: *query_set.QuerySet,
    ) ProcError!void {
        self.assertQueryGuard(guard, set);
        if (set.pending_use or set.last_used_serial > self.completed_serial) return;
        try self.destroyQueryPool(guard, io, set);
    }

    /// Void core retirement callbacks preserve failure for typed owner cleanup.
    pub fn recordCleanupError(
        self: *Queue,
        guard: *const core.ObjectGuard,
        err: ProcError,
    ) void {
        guard.assertOwns(guard.objects);
        std.debug.assert(guard.mutex == &self.device_mutex.mutex);
        if (self.deferred_cleanup_error == null) self.deferred_cleanup_error = err;
    }

    fn assertQueryGuard(self: *Queue, guard: *const core.ObjectGuard, set: *query_set.QuerySet) void {
        guard.assertOwns(set.header.tracking);
        std.debug.assert(set.header.tracking.mutex == &self.device_mutex.mutex);
    }

    /// Unlinks native registration before consuming its sole core-ledger lease.
    pub fn removeQuerySet(
        self: *Queue,
        guard: *const core.ObjectGuard,
        io: std.Io,
        set: *query_set.QuerySet,
    ) void {
        self.assertQueryGuard(guard, set);
        std.debug.assert(set.pool == null);
        std.debug.assert(set.backend_queue == self);
        var link = &self.query_sets;
        var visited: usize = 0;
        while (visited < self.query_set_count) : (visited += 1) {
            const entry = link.* orelse unreachable;
            self.assertQueryGuard(guard, entry);
            if (entry == set) {
                link.* = set.backend_next;
                self.query_set_count -= 1;
                set.backend_queue = null;
                set.backend_next = null;
                set.pending_use = false;
                set.header.releaseLeaseLocked(guard, io);
                return;
            }
            link = &entry.backend_next;
        }
        unreachable;
    }

    fn destroyQueryPool(
        self: *Queue,
        guard: *const core.ObjectGuard,
        io: std.Io,
        set: *query_set.QuerySet,
    ) ProcError!void {
        self.assertQueryGuard(guard, set);
        if (set.pool) |pool| {
            const destroy = (try self.deviceProcs()).destroy_query_pool orelse
                return error.MissingDeviceProc;
            destroy(self.context.vk_device, pool, null);
            self.context.handles.release(.query_pool);
            set.pool = null;
        }
        self.removeQuerySet(guard, io, set);
    }

    /// Releases completed registration leases after enclosing PendingUses roots drop.
    /// The caller already owns the canonical object guard; this never waits or relocks.
    pub fn collectQueryPools(
        self: *Queue,
        guard: *const core.ObjectGuard,
        io: std.Io,
    ) ProcError!void {
        guard.assertOwns(guard.objects);
        std.debug.assert(guard.mutex == &self.device_mutex.mutex);
        var first_error: ?ProcError = null;
        var current = self.query_sets;
        var visited: usize = 0;
        const count = self.query_set_count;
        while (visited < count) : (visited += 1) {
            const set = current orelse break;
            self.assertQueryGuard(guard, set);
            current = set.backend_next;
            // Once registration is the sole owner, completion consumes that lease
            // instead of retaining an otherwise abandoned live query indefinitely.
            if (set.state == .destroyed or set.header.reference_count == 1) {
                self.retireQueryPool(guard, io, set) catch |err| {
                    if (first_error == null) first_error = err;
                };
            }
        }
        if (first_error) |err| return err;
    }

    pub const ReserveStagingUploadError = std.mem.Allocator.Error || error{
        TemporaryBufferAllocatorMismatch,
        TemporaryBufferDeviceMismatch,
    };

    /// Reserve before unmap or native copy recording. Failure leaves the
    /// destination, staging owner, and recording commands untouched.
    pub fn reserveStagingUpload(
        self: *Queue,
        allocator: std.mem.Allocator,
        destination: *const buffer_module.Buffer,
    ) ReserveStagingUploadError!void {
        const owner = self.context.allocator;
        if (allocator.ptr != owner.ptr or allocator.vtable != owner.vtable or
            destination.device.allocator.ptr != owner.ptr or
            destination.device.allocator.vtable != owner.vtable)
        {
            return error.TemporaryBufferAllocatorMismatch;
        }
        if (destination.device.vk_device != self.context.vk_device) {
            return error.TemporaryBufferDeviceMismatch;
        }
        if (destination.staging) |upload| {
            if (upload.device.allocator.ptr != owner.ptr or upload.device.allocator.vtable != owner.vtable) {
                return error.TemporaryBufferAllocatorMismatch;
            }
            if (upload.device.vk_device != self.context.vk_device) return error.TemporaryBufferDeviceMismatch;
        }
        try self.temporary_buffers.ensureUnusedCapacity(allocator, 1);
    }

    /// Consume the upload immediately after successful unmap, with no allocation
    /// or other fallible work. Successful submit replaces serial zero with its
    /// actual serial; only completed fences or safe terminal cleanup retire it.
    pub fn adoptStagingUploadAssumeCapacity(self: *Queue, upload: *buffer_module.Buffer) void {
        const owner = self.context.allocator;
        std.debug.assert(upload.device.allocator.ptr == owner.ptr);
        std.debug.assert(upload.device.allocator.vtable == owner.vtable);
        std.debug.assert(upload.device.vk_device == self.context.vk_device);
        self.temporary_buffers.appendAssumeCapacity(.{ .buffer = upload, .allocator = owner });
    }

    /// The explicit allocator must be this queue's persistent context allocator.
    /// Recording arenas cannot own resources retained until submission completes.
    pub fn createTemporaryBuffer(
        self: *Queue,
        allocator: std.mem.Allocator,
        device: buffer_module.Device,
        descriptor: buffer_module.BufferDescriptor,
    ) buffer_module.CreateError!*buffer_module.Buffer {
        std.debug.assert(allocator.ptr == self.context.allocator.ptr);
        std.debug.assert(allocator.vtable == self.context.allocator.vtable);
        try self.temporary_buffers.ensureUnusedCapacity(allocator, 1);
        var owner_device = device;
        owner_device.allocator = allocator;
        const buffer = try buffer_module.Buffer.create(allocator, owner_device, descriptor);
        self.temporary_buffers.appendAssumeCapacity(.{ .buffer = buffer, .allocator = allocator });
        return buffer;
    }

    fn collectTemporaryBuffers(self: *Queue, all: bool) CleanupError!void {
        var first_error: ?CleanupError = null;
        var index: usize = self.temporary_buffers.items.len;
        while (index != 0) {
            index -= 1;
            const entry = self.temporary_buffers.items[index];
            if (all or (entry.serial != 0 and entry.serial <= self.completed_serial)) {
                entry.buffer.destroy(entry.allocator) catch |err| {
                    if (first_error == null) first_error = switch (err) {
                        error.MissingDeviceProc => error.MissingDeviceProc,
                        else => error.TemporaryBufferRetirementFailed,
                    };
                    continue;
                };
                _ = self.temporary_buffers.swapRemove(index);
            }
        }
        if (first_error) |err| return err;
    }

    /// Ports `Queue::DestroyImpl` (`QueueVk.cpp:441`-`:483`): every context
    /// first, then the fences, in flight before unused.
    ///
    /// It reports rather than returning `void`, because every proc it reaches
    /// is a dispatch field and a null one is a typed error.
    /// Each proc is bound before its loop runs, so a missing entry point costs
    /// the caller that one pool rather than the teardown up to that point.
    pub fn deinit(self: *Queue, io: std.Io, objects: *core.ObjectList) CleanupError!void {
        std.debug.assert(objects.mutex == &self.device_mutex.mutex);
        var first_error: ?CleanupError = null;
        const needs_quiescence = blk: {
            var guard = try core.ObjectGuard.lock(io, objects);
            defer guard.unlock(io);
            if (self.query_sets) |set| {
                if (set.header.tracking != objects) return error.ResourceDeviceMismatch;
                guard.assertOwns(set.header.tracking);
            }
            first_error = self.deferred_cleanup_error;
            break :blk self.query_set_count != 0 or
                self.temporary_buffers.items.len != 0 or self.fences_in_flight_count != 0;
        };
        // Blocking device quiescence never holds the object mutex. Device loss
        // permits native cleanup, but never manufactures completed serials.
        if (needs_quiescence) {
            const wait_idle = (try self.deviceProcs()).device_wait_idle orelse
                return error.MissingDeviceProc;
            dispatch.checkVkSuccess(wait_idle(self.context.vk_device)) catch |err| {
                if (err != error.DeviceLost) return err;
                if (first_error == null) first_error = err;
            };
        }
        {
            var guard = core.ObjectGuard.lockUncancelable(io, objects);
            defer guard.unlock(io);
            // The preserved callback failure is reported by this cleanup pass;
            // a later retry must be able to finish after the proc is restored.
            self.deferred_cleanup_error = null;
            if (self.query_set_count != 0) {
                if (self.context.dispatch.device) |procs| {
                    if (procs.destroy_query_pool == null) {
                        if (first_error == null) first_error = error.MissingDeviceProc;
                    } else {
                        const count = self.query_set_count;
                        var visited: usize = 0;
                        while (visited < count) : (visited += 1) {
                            const set = self.query_sets orelse break;
                            self.destroyQueryPool(&guard, io, set) catch |err| {
                                if (first_error == null) first_error = err;
                                break;
                            };
                        }
                    }
                } else if (first_error == null) {
                    first_error = error.DeviceProcTierMissing;
                }
            }
        }
        self.collectTemporaryBuffers(true) catch |err| {
            if (first_error == null) first_error = err;
        };
        if (self.temporary_buffers.items.len == 0) {
            self.temporary_buffers.deinit(self.context.allocator);
            self.temporary_buffers = .empty;
        }
        self.deinitNative() catch |err| {
            if (first_error == null) first_error = err;
        };
        if (first_error) |err| return err;
        self.* = undefined;
    }

    /// Constructor rollback owns only unpublished Vulkan command/fence children.
    /// It cannot inspect or reclaim a core payload and is not a guarded API bypass.
    pub fn deinitUnpublished(self: *Queue) ProcError!void {
        std.debug.assert(self.query_set_count == 0);
        std.debug.assert(self.query_sets == null);
        std.debug.assert(self.temporary_buffers.items.len == 0);
        std.debug.assert(self.timeline.lastSubmittedSerial() == 0);
        std.debug.assert(self.fences_in_flight_count == 0);
        try self.deinitNative();
        self.* = undefined;
    }

    fn deinitNative(self: *Queue) ProcError!void {
        var first_error: ?ProcError = null;
        var index: u32 = 0;
        while (index < self.context_count) : (index += 1) {
            self.destroyContext(index) catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        const procs = self.deviceProcs() catch |err| {
            if (first_error == null) first_error = err;
            return first_error.?;
        };
        if (self.fences_in_flight_count != 0 or self.unused_fence_count != 0) {
            if (procs.destroy_fence) |destroy_fence| {
                index = 0;
                while (index < self.fences_in_flight_count) : (index += 1) {
                    destroy_fence(self.context.vk_device, self.fences_in_flight[index].fence, null);
                    self.context.handles.release(.fence);
                }
                self.fences_in_flight_count = 0;
                index = 0;
                while (index < self.unused_fence_count) : (index += 1) {
                    destroy_fence(self.context.vk_device, self.unused_fences[index], null);
                    self.context.handles.release(.fence);
                }
                self.unused_fence_count = 0;
            } else if (first_error == null) {
                first_error = error.MissingDeviceProc;
            }
        }
        if (first_error) |err| return err;
    }

    /// Ports `Queue::SubmitPendingCommandsImpl` (`QueueVk.cpp:298`-`:374`).
    ///
    /// The buffers in `options` are ended here and submitted as one batch, which
    /// is what Dawn does to `mRecordingContext.commandBuffer` (`:323`) and
    /// `mRecordingContext.commandBufferList` (`:335`-`:337`). The semaphore
    /// fields of `VkSubmitInfo` are the rows M20 and M21 fill; this milestone
    /// has one queue and no swap chain, so every semaphore count is zero.
    /// Pending tracked resources require the current recording buffer in the batch.
    pub fn submit(
        self: *Queue,
        io: std.Io,
        objects: *core.ObjectList,
        options: SubmitOptions,
    ) SubmitError!SubmitResult {
        if (self.recording_poisoned) return error.RecordingPoisoned;
        std.debug.assert(objects.mutex == &self.device_mutex.mutex);
        var has_pending_resources = false;
        {
            var guard = try core.ObjectGuard.lock(io, objects);
            defer guard.unlock(io);
            var current = self.query_sets;
            var visited: usize = 0;
            while (visited < self.query_set_count) : (visited += 1) {
                const set = current orelse break;
                if (set.header.tracking != objects) return error.ResourceDeviceMismatch;
                guard.assertOwns(set.header.tracking);
                // Registration's core lease keeps this payload stable after unlock.
                current = set.backend_next;
                if (set.pending_use) {
                    if (set.header.state != .alive) return error.QuerySetDestroyed;
                    try set.validateCanUseInSubmit(&guard);
                    has_pending_resources = true;
                }
            }
        }
        if (options.command_buffers.len == 0) return error.NoCommandBuffer;
        for (self.temporary_buffers.items) |entry| {
            if (entry.serial == 0) {
                has_pending_resources = true;
                break;
            }
        }
        if (has_pending_resources) {
            const recording_buffer = self.commandBuffer();
            var submits_recording_buffer = false;
            for (options.command_buffers) |command_buffer| {
                if (command_buffer == recording_buffer) {
                    submits_recording_buffer = true;
                    break;
                }
            }
            // Reject before ending buffers or reserving a context. These uses
            // must stay pending until their recording buffer is submitted.
            if (!submits_recording_buffer) return error.PendingRecordingNotSubmitted;
        }
        errdefer self.poisonRecording();
        const procs = try self.deviceProcs();
        const end_command_buffer = procs.end_command_buffer orelse
            return error.MissingDeviceProc;
        const queue_submit = procs.queue_submit orelse
            return error.MissingDeviceProc;

        // The recording context this submission uses becomes in flight, so the
        // spare is reserved first: a submission that stands cannot afterwards be
        // reported as a failure.
        const spare = try self.reserveSpareContext();

        const submit_info: vulkan.VkSubmitInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO),
            .commandBufferCount = @intCast(options.command_buffers.len),
            .pCommandBuffers = options.command_buffers.ptr,
        };

        for (options.command_buffers) |command_buffer| {
            try dispatch.checkVkSuccess(end_command_buffer(command_buffer));
        }

        // Dawn acquires the fence after ending the command buffer
        // (`QueueVk.cpp:342`-`:343`) and returns it to the pool if the submit
        // fails (`:348`-`:355`), because a fence in neither list leaks.
        const fence = try self.acquireFence();
        dispatch.checkVkSuccess(queue_submit(
            self.context.vk_queue,
            1,
            &submit_info,
            fence,
        )) catch |err| {
            self.releaseFence(fence);
            return err;
        };

        // `IncrementLastSubmittedCommandSerial` runs after the submit
        // (`QueueVk.cpp:364`-`:367`), so a failed submit never moves the
        // timeline. Dawn then tags the fence with
        // `GetLastSubmittedCommandSerial()` read after that increment (`:366`),
        // which is the post-increment counter value: the serial this
        // submission carries. `submit` returns exactly that value, so the
        // fence, the contexts it moves and the result agree with the timeline.
        // Successful native submit has no fallible header/publication phase.
        // Re-walk the leased registration list; no naked preflight pointer survives.
        var commit_guard = core.ObjectGuard.lockUncancelable(io, objects);
        defer commit_guard.unlock(io);
        const serial = self.timeline.submit();
        for (self.temporary_buffers.items) |*entry| {
            if (entry.serial == 0) entry.serial = serial;
        }
        var current = self.query_sets;
        var visited: usize = 0;
        while (visited < self.query_set_count) : (visited += 1) {
            const set = current orelse break;
            self.assertQueryGuard(&commit_guard, set);
            current = set.backend_next;
            if (set.pending_use) {
                set.last_used_serial = serial;
                set.pending_use = false;
            }
        }
        self.fences_in_flight[self.fences_in_flight_count] = .{
            .fence = fence,
            .serial = serial,
        };
        self.fences_in_flight_count += 1;
        for (options.command_buffers) |command_buffer| {
            const slot = self.findContextByBuffer(command_buffer) orelse continue;
            self.contexts[slot].in_flight = true;
            self.contexts[slot].submitted_serial = serial;
        }
        self.recording_index = spare;
        return .{ .fence = fence, .serial = serial };
    }

    /// Ports `Queue::WaitForQueueSerialImpl` (`QueueVk.cpp:485`-`:538`), with
    /// the bound the acceptance names.
    ///
    /// It returns the serial the timeline now knows to be complete, which is what
    /// a caller passes to a reclaim pass.
    pub fn wait(
        io: std.Io,
        self: *Queue,
        objects: *core.ObjectList,
        options: WaitOptions,
    ) WaitError!platform.Serial {
        if (options.serial > self.timeline.lastSubmittedSerial()) return error.SerialNotSubmitted;
        std.debug.assert(objects.mutex == &self.device_mutex.mutex);
        {
            var guard = try core.ObjectGuard.lock(io, objects);
            defer guard.unlock(io);
            if (self.query_sets) |set| {
                if (set.header.tracking != objects) return error.ResourceDeviceMismatch;
                guard.assertOwns(set.header.tracking);
            }
        }
        // Bound: the retry bound. Dawn's `while (1)` at `QueueVk.cpp:496`
        // retries forever on `VK_TIMEOUT` when the caller passed an infinite
        // timeout; this loop has a named bound.
        var iteration: u32 = 0;
        while (iteration < max_fence_wait_iteration_count) : (iteration += 1) {
            const fence = findFenceFor(self, options.serial) orelse {
                // The fence for this serial was already retired, so the serial
                // is complete (`QueueVk.cpp:508`-`:513`).
                if (options.serial > self.completed_serial) return error.FenceStatusFailed;
                try self.complete(io, objects, options.serial);
                return options.serial;
            };

            const wait_for_fences = (try self.deviceProcs()).wait_for_fences orelse
                return error.MissingDeviceProc;
            var fence_array = [1]vulkan.VkFence{fence};
            const result = wait_for_fences(
                self.context.vk_device,
                1,
                &fence_array,
                1,
                options.timeout_ns,
            );
            // `checkVkSuccess` maps `VK_TIMEOUT` to `error.UnexpectedOutcome`
            // (`dispatch.zig:1253`), which is this wait's own
            // `FenceWaitTimedOut`.
            dispatch.checkVkSuccess(result) catch |err| switch (err) {
                error.UnexpectedOutcome => return error.FenceWaitTimedOut,
                else => |fatal| return fatal,
            };

            const completed = try retireCompleted(self);
            try self.complete(io, objects, completed);
            if (completed >= options.serial) return completed;
        }
        return error.WaitIterationExhausted;
    }

    /// The raw `vkGetFenceStatus` code.
    ///
    /// Ports the call at `QueueVk.cpp:142`, and returns the code rather than a
    /// Zig value because the acceptance asserts on `VK_SUCCESS` itself. No
    /// `VkResult` mapping is duplicated: nothing here branches on the code.
    ///
    /// It reports rather than returning the code bare, because the proc it
    /// reaches is a dispatch field and a null one is a typed error.
    pub fn fenceStatus(self: *const Queue, fence: vulkan.VkFence) ProcError!vulkan.VkResult {
        const get_fence_status = (try self.deviceProcs()).get_fence_status orelse
            return error.MissingDeviceProc;
        return get_fence_status(
            self.context.vk_device,
            fence,
        );
    }

    /// Creates one pool, takes one buffer from it, and begins recording.
    ///
    /// Ports `Queue::BeginVkCommandBuffer` (`QueueVk.cpp:240`-`:296`): a
    /// transient pool on the queue's family, one primary buffer, begun with
    /// `VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT` (`:287`).
    fn createContext(self: *Queue, slot: u32) RecordingError!void {
        const procs = try self.deviceProcs();
        const create_command_pool = procs.create_command_pool orelse
            return error.MissingDeviceProc;
        const destroy_command_pool = procs.destroy_command_pool orelse
            return error.MissingDeviceProc;
        const allocate_command_buffers = procs.allocate_command_buffers orelse
            return error.MissingDeviceProc;
        const begin_command_buffer = procs.begin_command_buffer orelse
            return error.MissingDeviceProc;
        const pool_create_info: vulkan.VkCommandPoolCreateInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO),
            .flags = vulkan.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
            .queueFamilyIndex = self.context.queue_family_index,
        };
        var pool: vulkan.VkCommandPool = null;
        try dispatch.checkVkSuccess(create_command_pool(
            self.context.vk_device,
            &pool_create_info,
            null,
            &pool,
        ));
        if (pool == null) return error.CommandPoolCreationReturnedNull;
        self.context.handles.acquire(.command_pool);
        errdefer self.context.handles.release(.command_pool);
        errdefer destroy_command_pool(self.context.vk_device, pool, null);

        const allocate_info: vulkan.VkCommandBufferAllocateInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO),
            .commandPool = pool,
            .level = @intCast(vulkan.VK_COMMAND_BUFFER_LEVEL_PRIMARY),
            .commandBufferCount = 1,
        };
        var command_buffer: vulkan.VkCommandBuffer = null;
        try dispatch.checkVkSuccess(allocate_command_buffers(
            self.context.vk_device,
            &allocate_info,
            &command_buffer,
        ));
        if (command_buffer == null) return error.CommandBufferAllocationReturnedNull;
        self.context.handles.acquire(.command_buffer);
        errdefer self.context.handles.release(.command_buffer);

        const begin_info: vulkan.VkCommandBufferBeginInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO),
            .flags = vulkan.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try dispatch.checkVkSuccess(begin_command_buffer(command_buffer, &begin_info));

        self.contexts[slot] = .{ .pool = pool, .command_buffer = command_buffer };
    }

    /// Ports `DestroyCommandPoolAndBuffer` (`QueueVk.cpp:62`-`:75`): the buffer
    /// is freed before the pool, because a driver that frees the pool first can
    /// leak the buffer's memory. Dawn's comment at `:65`-`:67` is the reason.
    ///
    /// It reports rather than returning `void`, because both procs it reaches
    /// are dispatch fields and a null one is a typed error.
    fn destroyContext(self: *Queue, slot: u32) ProcError!void {
        const entry = &self.contexts[slot];
        if (entry.pool == null) return;
        const procs = try self.deviceProcs();
        if (entry.command_buffer != null) {
            const free_command_buffers = procs.free_command_buffers orelse
                return error.MissingDeviceProc;
            free_command_buffers(
                self.context.vk_device,
                entry.pool,
                1,
                &entry.command_buffer,
            );
            self.context.handles.release(.command_buffer);
            entry.command_buffer = null;
        }
        const destroy_command_pool = procs.destroy_command_pool orelse
            return error.MissingDeviceProc;
        destroy_command_pool(self.context.vk_device, entry.pool, null);
        self.context.handles.release(.command_pool);
        // The zero value rather than `undefined`: the early return above reads
        // `pool` to decide whether this slot is already freed, and a second
        // `deinit` would read an undefined slot without it.
        entry.* = .{ .pool = null, .command_buffer = null };
    }

    /// The slot `recording_index` moves to after a submission: an existing
    /// context that is not in flight, or a new one.
    ///
    /// Ports `Queue::RecycleRecordingContext` (`QueueVk.cpp:376`-`:402`)
    /// without the serial-tracked task. Dawn resets the pool and pushes it back
    /// when the serial completes; the port clears the flag in `retireCompleted`,
    /// which is the same event seen from the other side.
    fn reserveSpareContext(self: *Queue) SubmitError!u32 {
        var index: u32 = 0;
        while (index < self.context_count) : (index += 1) {
            if (index == self.recording_index) continue;
            const entry = &self.contexts[index];
            if (entry.in_flight) continue;
            if (entry.submitted_serial != 0) {
                const procs = try self.deviceProcs();
                const reset = procs.reset_command_pool orelse return error.MissingDeviceProc;
                const begin = procs.begin_command_buffer orelse return error.MissingDeviceProc;
                try dispatch.checkVkSuccess(reset(self.context.vk_device, entry.pool, 0));
                const info: vulkan.VkCommandBufferBeginInfo = .{
                    .sType = vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                    .flags = vulkan.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
                };
                try dispatch.checkVkSuccess(begin(entry.command_buffer, &info));
                entry.submitted_serial = 0;
            }
            return index;
        }
        if (self.context_count >= max_command_context_count) {
            return error.CommandContextPoolExhausted;
        }
        try self.createContext(self.context_count);
        self.context_count += 1;
        return self.context_count - 1;
    }

    /// Ports `Queue::GetUnusedFence` (`QueueVk.cpp:404`-`:439`): reset a pooled
    /// fence if there is one, create one otherwise.
    fn acquireFence(self: *Queue) SubmitError!vulkan.VkFence {
        const procs = try self.deviceProcs();
        const reset_fences = procs.reset_fences orelse
            return error.MissingDeviceProc;
        const create_fence = procs.create_fence orelse
            return error.MissingDeviceProc;
        if (self.unused_fence_count != 0) {
            self.unused_fence_count -= 1;
            const fence = self.unused_fences[self.unused_fence_count];
            var fence_array = [1]vulkan.VkFence{fence};
            try dispatch.checkVkSuccess(reset_fences(
                self.context.vk_device,
                1,
                &fence_array,
            ));
            return fence;
        }
        if (self.fences_in_flight_count >= max_fence_count) {
            return error.FencePoolExhausted;
        }

        const create_info: vulkan.VkFenceCreateInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO),
            .flags = 0,
        };
        var fence: vulkan.VkFence = null;
        try dispatch.checkVkSuccess(create_fence(
            self.context.vk_device,
            &create_info,
            null,
            &fence,
        ));
        if (fence == null) return error.FenceCreationReturnedNull;
        self.context.handles.acquire(.fence);
        return fence;
    }

    /// Puts a fence back in the pool Dawn pushes it onto at `QueueVk.cpp:354`,
    /// which is what a failed submit does.
    fn releaseFence(self: *Queue, fence: vulkan.VkFence) void {
        std.debug.assert(self.unused_fence_count < max_fence_count);
        self.unused_fences[self.unused_fence_count] = fence;
        self.unused_fence_count += 1;
    }

    /// Moves the completed serial and wakes every waiter. Ports
    /// `ExecutionQueueBase::UpdateCompletedSerialTo`
    /// (`ExecutionQueue.cpp:267`-`:270`), which `UpdateCompletedSerial`
    /// (`:228`-`:236`) reaches right after `CheckAndUpdateCompletedSerials`.
    /// Its body `UpdateCompletedSerialToInternal` (`:272`-`:337`) moves
    /// `mCompletedSerial` at `:315`.
    ///
    /// Publication already owns the shared object/device mutex and locks only
    /// the inner timeline. It never recursively calls Timeline.updateCompletedTo.
    fn complete(
        self: *Queue,
        io: std.Io,
        objects: *core.ObjectList,
        serial: platform.Serial,
    ) WaitError!void {
        var guard = core.ObjectGuard.lockUncancelable(io, objects);
        defer guard.unlock(io);
        // The guard already owns device_mutex: lock only the inner timeline.
        self.timeline.mutex.lockUncancelable(io);
        if (serial > self.timeline.completed) {
            self.timeline.completed = serial;
            self.timeline.completed_cond.broadcast(io);
        }
        self.timeline.mutex.unlock(io);
        self.completed_serial = @max(self.completed_serial, serial);
        var first_error: ?WaitError = null;
        self.collectQueryPools(&guard, io) catch |err| {
            first_error = err;
        };
        self.collectTemporaryBuffers(false) catch |err| {
            if (first_error == null) first_error = err;
        };
        if (first_error) |err| return err;
    }

    /// The device tier, or the error that says the `Context` carries none.
    ///
    /// Every entry point in this file is reached through here rather than
    /// through a forced unwrap of `context.dispatch.device`.
    fn deviceProcs(self: *const Queue) ProcError!*const dispatch.DeviceProcs {
        return self.context.dispatch.device orelse return error.DeviceProcTierMissing;
    }

    /// The context a command buffer belongs to.
    fn findContextByBuffer(self: *const Queue, command_buffer: vulkan.VkCommandBuffer) ?u32 {
        var index: u32 = 0;
        while (index < self.context_count) : (index += 1) {
            if (self.contexts[index].command_buffer == command_buffer) return index;
        }
        return null;
    }
};

/// The first in-flight fence whose serial is at or above `serial`.
///
/// Ports the search at `QueueVk.cpp:500`-`:513`. Fences are appended in
/// submission order and their serials rise, so the first match is the submission
/// that completed `serial`.
fn findFenceFor(queue: *const Queue, serial: platform.Serial) ?vulkan.VkFence {
    var index: u32 = 0;
    while (index < queue.fences_in_flight_count) : (index += 1) {
        const entry = queue.fences_in_flight[index];
        if (entry.serial >= serial) return entry.fence;
    }
    return null;
}

/// Ports `Queue::CheckAndUpdateCompletedSerials` (`QueueVk.cpp:132`-`:161`).
///
/// The scan stops at the first fence that is not signalled, because fences are
/// added in submission order, and each signalled fence moves onto the pool Dawn
/// pushes to `mUnusedFences` (`:156`). The returned serial is the highest one
/// retired, or the serial the timeline already had when nothing retired. The
/// contexts those fences carried stop being in flight here too, which is Dawn's
/// `TrackSerialTask` at `:382` seen from the other side.
fn retireCompleted(queue: *Queue) Queue.WaitError!platform.Serial {
    const get_fence_status = (try queue.deviceProcs()).get_fence_status orelse
        return error.MissingDeviceProc;
    var retired = queue.completed_serial;
    var completed_count: u32 = 0;
    // Preflight the bounded prefix before mutating fence/context ownership.
    // A failed status leaves every fence and query use pending for safe cleanup.
    while (completed_count < queue.fences_in_flight_count) : (completed_count += 1) {
        const entry = queue.fences_in_flight[completed_count];
        switch (dispatch.classify(get_fence_status(queue.context.vk_device, entry.fence))) {
            .not_ready => break,
            .success => retired = entry.serial,
            .@"error" => |err| return err,
            else => return error.FenceStatusFailed,
        }
    }
    var index: u32 = 0;
    while (index < completed_count) : (index += 1) {
        queue.releaseFence(queue.fences_in_flight[index].fence);
    }
    queue.fences_in_flight_count -= completed_count;
    index = 0;
    while (index < queue.fences_in_flight_count) : (index += 1) {
        queue.fences_in_flight[index] = queue.fences_in_flight[index + completed_count];
    }
    var context_index: u32 = 0;
    while (context_index < queue.context_count) : (context_index += 1) {
        const entry = &queue.contexts[context_index];
        if (entry.in_flight and entry.submitted_serial <= retired) entry.in_flight = false;
    }
    return retired;
}

comptime {
    vulkan_device.assertErrorSetNamed(ProcError, &.{
        error.DeviceProcTierMissing,
        error.MissingDeviceProc,
    });
    vulkan_device.assertErrorSetNamed(Queue.RecordingError, &.{
        error.DeviceProcTierMissing,
        error.MissingDeviceProc,
        error.CommandContextPoolExhausted,
        error.CommandPoolCreationReturnedNull,
        error.CommandBufferAllocationReturnedNull,
    });
    vulkan_device.assertErrorSetNamed(Queue.InitError, &.{
        error.CommandContextPoolExhausted,
        error.CommandPoolCreationReturnedNull,
        error.CommandBufferAllocationReturnedNull,
        error.DeviceProcTierMissing,
        error.MissingDeviceProc,
        error.QueueHandleIsNull,
    });
    vulkan_device.assertErrorSetNamed(Queue.SubmitError, &.{
        error.Canceled,
        error.ResourceDestroyed,
        error.ResourceDeviceMismatch,
        error.ReferenceCountOverflow,
        error.NoOwnedReference,
        error.QuerySetIsError,
        error.QuerySetDestroyed,
        error.RecordingPoisoned,
        error.PendingRecordingNotSubmitted,
        error.DeviceProcTierMissing,
        error.MissingDeviceProc,
        error.CommandContextPoolExhausted,
        error.CommandPoolCreationReturnedNull,
        error.CommandBufferAllocationReturnedNull,
        error.NoCommandBuffer,
        error.FencePoolExhausted,
        error.FenceCreationReturnedNull,
    });
    vulkan_device.assertErrorSetNamed(Queue.WaitError, &.{
        error.ResourceDestroyed,
        error.ResourceDeviceMismatch,
        error.ReferenceCountOverflow,
        error.NoOwnedReference,
        error.SerialNotSubmitted,
        error.TemporaryBufferRetirementFailed,
        error.DeviceProcTierMissing,
        error.MissingDeviceProc,
        error.TimedOut,
        error.Canceled,
        error.FenceWaitTimedOut,
        error.WaitIterationExhausted,
        error.FenceStatusFailed,
    });
}

test "the fence pools are bounded and the wait bound is 5,000 ms" {
    try std.testing.expectEqual(@as(u64, 5_000_000_000), fence_wait_timeout_ns);
    try std.testing.expectEqual(@as(usize, 16), max_fence_count);
    try std.testing.expectEqual(@as(u32, 4), max_fence_wait_iteration_count);
    try std.testing.expectEqual(@as(u32, 4), max_command_context_count);
}

test "a fence is found by its serial, and an empty queue has none" {
    var memory_properties: vulkan.VkPhysicalDeviceMemoryProperties =
        std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties);
    var handles: HandleSet = .{};
    var device_mutex: platform.DeviceMutex = .{};
    var objects: core.ObjectList = .{ .mutex = &device_mutex.mutex };
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, &objects);
    defer guard.unlock(std.testing.io);

    var queue: Queue = .{
        .context = .{
            .allocator = std.testing.allocator,
            .dispatch = .{ .global = null, .instance = null, .device = null },
            .vk_device = null,
            .vk_queue = null,
            .queue_family_index = 0,
            .memory_properties = &memory_properties,
            .handles = &handles,
        },
        .device_mutex = &device_mutex,
        // `Queue.init` writes the same `.{}` here, and this test builds the
        // queue without dispatch procs, so it writes the field itself. A
        // field added to `Queue` later then fails here rather than making the
        // test queue differ from the initialised one.
        .timeline = .{},
    };

    // Nothing has been submitted, so there is no fence to wait on. This is
    // Dawn's "fence not found, this serial has already completed" case
    // (`QueueVk.cpp:508`-`:513`).
    try std.testing.expectEqual(@as(?vulkan.VkFence, null), findFenceFor(&queue, 0));

    const first_fence: vulkan.VkFence = @ptrFromInt(0x1000);
    const second_fence: vulkan.VkFence = @ptrFromInt(0x2000);
    queue.fences_in_flight[0] = .{ .fence = first_fence, .serial = 7 };
    queue.fences_in_flight[1] = .{ .fence = second_fence, .serial = 9 };
    queue.fences_in_flight_count = 2;

    // The first fence at or above the serial wins, because serials rise in
    // submission order.
    try std.testing.expectEqual(first_fence, findFenceFor(&queue, 7).?);
    try std.testing.expectEqual(second_fence, findFenceFor(&queue, 8).?);
    try std.testing.expectEqual(@as(?vulkan.VkFence, null), findFenceFor(&queue, 10));
}

fn queueTestContext(
    handles: *HandleSet,
    memory_properties: *const vulkan.VkPhysicalDeviceMemoryProperties,
) Context {
    return .{
        .allocator = std.testing.allocator,
        .dispatch = .{ .global = null, .instance = null, .device = null },
        .vk_device = null,
        .vk_queue = null,
        .queue_family_index = 0,
        .memory_properties = memory_properties,
        .handles = handles,
    };
}

fn queueTestQuery(
    arena: *core.ObjectArena,
    guard: *const core.ObjectGuard,
) !*query_set.QuerySet {
    const set = try arena.create(std.testing.allocator, guard, query_set.QuerySet, .{
        .kind = .query_set,
        .state = .initializing,
        .initial_reference = .user,
    });
    set.query_type = .occlusion;
    set.query_count = 0;
    set.state = .available;
    set.availability = &.{};
    set.pool = null;
    set.backend_queue = null;
    set.backend_next = null;
    set.last_used_serial = 0;
    set.pending_use = false;
    set.header.setInitializedNoError(guard);
    set.header.attach(guard, std.testing.io);
    return set;
}

fn registerQueueTestQuery(
    queue: *Queue,
    guard: *const core.ObjectGuard,
    set: *query_set.QuerySet,
) !void {
    try set.header.retainLeaseLocked(guard);
    set.backend_queue = queue;
    set.backend_next = queue.query_sets;
    queue.query_sets = set;
    queue.query_set_count += 1;
}

test "poison refuses submit before reaching Vulkan" {
    var device_mutex: platform.DeviceMutex = .{};
    var objects: core.ObjectList = .{ .mutex = &device_mutex.mutex };
    var handles: HandleSet = .{};
    var memory_properties = std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties);
    var queue: Queue = .{
        .context = queueTestContext(&handles, &memory_properties),
        .device_mutex = &device_mutex,
        .timeline = .{},
    };
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, &objects);
        defer guard.unlock(std.testing.io);
        queue.poisonRecording();
    }
    try std.testing.expectError(error.RecordingPoisoned, queue.submit(std.testing.io, &objects, .{ .command_buffers = &.{} }));
}

test "submit rejects a destroyed or error query before Vulkan" {
    var device_mutex: platform.DeviceMutex = .{};
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &device_mutex.mutex });
    const objects = arena.objectList();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        arena.deinit(std.testing.allocator, &guard) catch unreachable;
    }
    var handles: HandleSet = .{};
    var memory_properties = std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties);
    var queue: Queue = .{
        .context = queueTestContext(&handles, &memory_properties),
        .device_mutex = &device_mutex,
        .timeline = .{},
    };
    const set = blk: {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        const set = try queueTestQuery(&arena, &guard);
        try registerQueueTestQuery(&queue, &guard, set);
        set.pending_use = true;
        set.state = .destroyed;
        break :blk set;
    };
    defer {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        queue.removeQuerySet(&guard, std.testing.io, set);
        set.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    }
    try std.testing.expectError(error.QuerySetDestroyed, queue.submit(std.testing.io, objects, .{ .command_buffers = &.{} }));
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        set.state = .unavailable;
    }
    try std.testing.expectError(error.QuerySetIsError, queue.submit(std.testing.io, objects, .{ .command_buffers = &.{} }));
}

test "waiting for unsubmitted serial cannot retire query pools" {
    var device_mutex: platform.DeviceMutex = .{};
    var objects: core.ObjectList = .{ .mutex = &device_mutex.mutex };
    var handles: HandleSet = .{};
    var memory_properties = std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties);
    var queue: Queue = .{
        .context = queueTestContext(&handles, &memory_properties),
        .device_mutex = &device_mutex,
        .timeline = .{},
    };
    try std.testing.expectError(
        error.SerialNotSubmitted,
        Queue.wait(std.testing.io, &queue, &objects, .{ .serial = 1 }),
    );
}

const RetirementProbe = struct {
    ended: usize = 0,
    submitted: usize = 0,
    destroyed_pools: usize = 0,
    destroyed_buffers: usize = 0,
    object_mutex: ?*std.Io.Mutex = null,
    submit_result: vulkan.VkResult = vulkan.VK_SUCCESS,
    wait_result: vulkan.VkResult = vulkan.VK_SUCCESS,
    status_result: vulkan.VkResult = vulkan.VK_SUCCESS,
    status_calls: usize = 0,
    status_fail_at: usize = 0,
    created_fences: usize = 0,
    retire_objects: ?*core.ObjectList = null,
    retire_set: ?*query_set.QuerySet = null,
    retired_during_end: usize = 0,
    submitted_unlocked: usize = 0,
    waited_unlocked: usize = 0,

    fn probeUnlocked(self: *RetirementProbe, count: *usize) void {
        const mutex = self.object_mutex orelse return;
        if (mutex.tryLock()) {
            count.* += 1;
            mutex.unlock(std.testing.io);
        }
    }

    fn end(buffer: vulkan.VkCommandBuffer) callconv(.c) vulkan.VkResult {
        const self: *RetirementProbe = @ptrCast(@alignCast(buffer));
        self.ended += 1;
        if (self.retire_set) |set| {
            const objects = self.retire_objects.?;
            std.debug.assert(objects.mutex == self.object_mutex.?);
            if (!objects.mutex.tryLock()) @panic("ObjectGuard held during native command end");
            objects.mutex.unlock(std.testing.io);
            var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
            defer guard.unlock(std.testing.io);
            std.debug.assert(set.pending_use);
            std.debug.assert(set.backend_queue != null);
            std.debug.assert(objects.total_reference_count == 2);
            set.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
            std.debug.assert(set.pending_use);
            std.debug.assert(set.backend_queue != null);
            std.debug.assert(set.pool != null);
            std.debug.assert(objects.total_reference_count == 2);
            self.retired_during_end += 1;
            self.retire_set = null;
        }
        return vulkan.VK_SUCCESS;
    }

    fn submit(
        queue: vulkan.VkQueue,
        _: u32,
        _: [*c]const vulkan.VkSubmitInfo,
        _: vulkan.VkFence,
    ) callconv(.c) vulkan.VkResult {
        const self: *RetirementProbe = @ptrCast(@alignCast(queue));
        self.submitted += 1;
        self.probeUnlocked(&self.submitted_unlocked);
        return self.submit_result;
    }

    fn reset(_: vulkan.VkDevice, _: u32, _: [*c]const vulkan.VkFence) callconv(.c) vulkan.VkResult {
        return vulkan.VK_SUCCESS;
    }

    fn create(
        device: vulkan.VkDevice,
        _: [*c]const vulkan.VkFenceCreateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        result: [*c]vulkan.VkFence,
    ) callconv(.c) vulkan.VkResult {
        const self: *RetirementProbe = @ptrCast(@alignCast(device));
        self.created_fences += 1;
        result[0] = @ptrFromInt(8 + self.created_fences * 8);
        return vulkan.VK_SUCCESS;
    }

    fn wait(
        device: vulkan.VkDevice,
        _: u32,
        _: [*c]const vulkan.VkFence,
        _: vulkan.VkBool32,
        _: u64,
    ) callconv(.c) vulkan.VkResult {
        const self: *RetirementProbe = @ptrCast(@alignCast(device));
        self.probeUnlocked(&self.waited_unlocked);
        return self.wait_result;
    }

    fn status(device: vulkan.VkDevice, _: vulkan.VkFence) callconv(.c) vulkan.VkResult {
        const self: *RetirementProbe = @ptrCast(@alignCast(device));
        self.status_calls += 1;
        if (self.status_fail_at != 0 and self.status_calls != self.status_fail_at) return vulkan.VK_SUCCESS;
        return self.status_result;
    }

    fn destroyPool(
        device: vulkan.VkDevice,
        _: vulkan.VkQueryPool,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self: *RetirementProbe = @ptrCast(@alignCast(device));
        self.destroyed_pools += 1;
    }

    fn destroyBuffer(
        device: vulkan.VkDevice,
        _: vulkan.VkBuffer,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self: *RetirementProbe = @ptrCast(@alignCast(device));
        self.destroyed_buffers += 1;
    }
};

test "unsubmitted recording resources stay pending until their own submission completes" {
    var device_mutex: platform.DeviceMutex = .{};
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &device_mutex.mutex });
    const objects = arena.objectList();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        arena.deinit(std.testing.allocator, &guard) catch unreachable;
    }
    var probe: RetirementProbe = .{ .object_mutex = &device_mutex.mutex };
    var procs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.end_command_buffer = RetirementProbe.end;
    procs.queue_submit = RetirementProbe.submit;
    procs.reset_fences = RetirementProbe.reset;
    procs.create_fence = RetirementProbe.create;
    procs.wait_for_fences = RetirementProbe.wait;
    procs.get_fence_status = RetirementProbe.status;
    procs.destroy_query_pool = RetirementProbe.destroyPool;
    procs.destroy_buffer = RetirementProbe.destroyBuffer;
    procs.device_wait_idle = TemporaryAllocationProbe.waitIdle;
    procs.destroy_fence = TemporaryAllocationProbe.destroyFence;
    var handles: HandleSet = .{};
    defer std.debug.assert(handles.isEmpty());
    var memory_properties = std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties);
    var queue: Queue = .{
        .context = .{
            .allocator = std.testing.allocator,
            .dispatch = .{ .global = null, .instance = null, .device = &procs },
            .vk_device = @ptrCast(&probe),
            .vk_queue = @ptrCast(&probe),
            .queue_family_index = 0,
            .memory_properties = &memory_properties,
            .handles = &handles,
        },
        .device_mutex = &device_mutex,
        .timeline = .{},
        .context_count = 2,
    };
    defer queue.deinit(std.testing.io, objects) catch unreachable;
    const recording_buffer: vulkan.VkCommandBuffer = @ptrCast(&probe);
    const other_buffer: vulkan.VkCommandBuffer = @ptrFromInt(32);
    const set = blk: {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        queue.contexts[0].command_buffer = recording_buffer;
        queue.contexts[1].command_buffer = other_buffer;
        const set = try queueTestQuery(&arena, &guard);
        try registerQueueTestQuery(&queue, &guard, set);
        set.pool = @as(vulkan.VkQueryPool, @ptrFromInt(8));
        handles.acquire(.query_pool);
        try queue.trackQuerySet(&guard, set);
        break :blk set;
    };
    defer {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        set.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        try queue.temporary_buffers.ensureUnusedCapacity(std.testing.allocator, 1);
        const buffer = try std.testing.allocator.create(buffer_module.Buffer);
        buffer.* = undefined;
        buffer.staging = null;
        buffer.mapped = null;
        buffer.handle = @ptrFromInt(24);
        buffer.allocation.memory = null;
        buffer.device = undefined;
        buffer.device.dispatch = queue.context.dispatch;
        buffer.device.vk_device = queue.context.vk_device;
        buffer.device.handles = &handles;
        handles.acquire(.buffer);
        queue.temporary_buffers.appendAssumeCapacity(.{
            .buffer = buffer,
            .allocator = std.testing.allocator,
        });
    }
    try std.testing.expectError(
        error.PendingRecordingNotSubmitted,
        queue.submit(std.testing.io, objects, .{ .command_buffers = &.{other_buffer} }),
    );
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        try std.testing.expect(set.pending_use);
        try std.testing.expectEqual(@as(platform.Serial, 0), set.last_used_serial);
        try std.testing.expectEqual(@as(platform.Serial, 0), queue.temporary_buffers.items[0].serial);
        try std.testing.expectEqual(@as(platform.Serial, 0), queue.timeline.lastSubmittedSerial());
        try std.testing.expectEqual(@as(u32, 0), queue.recording_index);
        try std.testing.expect(!queue.recording_poisoned);
        try std.testing.expectEqual(@as(usize, 0), probe.ended);
        try std.testing.expectEqual(@as(usize, 0), probe.submitted);
    }
    try std.testing.expectError(
        error.SerialNotSubmitted,
        Queue.wait(std.testing.io, &queue, objects, .{ .serial = 1 }),
    );
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        try queue.retireQueryPool(&guard, std.testing.io, set);
        try queue.collectTemporaryBuffers(false);
        try std.testing.expect(set.pool != null);
        try std.testing.expectEqual(@as(usize, 1), queue.temporary_buffers.items.len);
    }
    const result = try queue.submit(std.testing.io, objects, .{ .command_buffers = &.{recording_buffer} });
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        try std.testing.expectEqual(@as(platform.Serial, 1), result.serial);
        try std.testing.expect(!set.pending_use);
        try std.testing.expectEqual(result.serial, set.last_used_serial);
        try std.testing.expectEqual(result.serial, queue.temporary_buffers.items[0].serial);
        try std.testing.expectEqual(@as(platform.Serial, 0), queue.contexts[1].submitted_serial);
        set.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
        try std.testing.expect(set.pool != null);
        try std.testing.expectEqual(@as(usize, 0), probe.destroyed_pools);
        try std.testing.expectEqual(@as(usize, 0), probe.destroyed_buffers);
    }
    try std.testing.expectEqual(
        result.serial,
        try Queue.wait(std.testing.io, &queue, objects, .{ .serial = result.serial }),
    );
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        try std.testing.expect(set.pool == null);
        try std.testing.expectEqual(@as(usize, 0), queue.query_set_count);
        try std.testing.expectEqual(@as(usize, 0), queue.temporary_buffers.items.len);
        try std.testing.expectEqual(@as(usize, 1), probe.destroyed_pools);
        try std.testing.expectEqual(@as(usize, 1), probe.destroyed_buffers);
        try std.testing.expectEqual(@as(usize, 1), probe.submitted_unlocked);
        try std.testing.expectEqual(@as(usize, 1), probe.waited_unlocked);
        try std.testing.expectEqual(@as(u64, 1), objects.total_reference_count);
        try std.testing.expectEqual(@as(u64, 1), objects.user_reference_count);
    }
}

test "a pending temporary buffer alone requires the recording buffer" {
    var device_mutex: platform.DeviceMutex = .{};
    var objects: core.ObjectList = .{ .mutex = &device_mutex.mutex };
    var handles: HandleSet = .{};
    var memory_properties = std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties);
    var queue: Queue = .{
        .context = queueTestContext(&handles, &memory_properties),
        .device_mutex = &device_mutex,
        .timeline = .{},
    };
    var entries = [_]Queue.TemporaryBuffer{
        .{ .buffer = undefined, .allocator = std.testing.allocator },
    };
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, &objects);
        defer guard.unlock(std.testing.io);
        queue.contexts[0].command_buffer = @ptrFromInt(8);
        queue.temporary_buffers = .empty;
        queue.temporary_buffers.items = &entries;
        queue.temporary_buffers.capacity = entries.len;
    }
    try std.testing.expectError(
        error.PendingRecordingNotSubmitted,
        queue.submit(std.testing.io, &objects, .{ .command_buffers = &.{@ptrFromInt(16)} }),
    );
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, &objects);
    defer guard.unlock(std.testing.io);
    try std.testing.expectEqual(@as(platform.Serial, 0), entries[0].serial);
    try std.testing.expect(!queue.recording_poisoned);
}

test "failed Vulkan submission preserves pending query serials and completion" {
    try queueGuardLifetime(.failed_submit);
}

test "timeout and device loss preserve submitted query serials and completion" {
    try queueGuardLifetime(.failed_wait);
}

test "query retirement during unlocked native submit waits for published completion" {
    try queueGuardLifetime(.retirement_during_end);
}

test "device loss after a successful fence prefix preserves every fence and query registration" {
    try queueGuardLifetime(.status_prefix);
}

const QueueGuardScenario = enum { failed_submit, failed_wait, retirement_during_end, status_prefix };

fn queueGuardLifetime(scenario: QueueGuardScenario) !void {
    var device_mutex: platform.DeviceMutex = .{};
    var arena = core.ObjectArena.init(std.testing.allocator, .{ .object_mutex = &device_mutex.mutex });
    const objects = arena.objectList();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        std.debug.assert(objects.total_reference_count == 0);
        arena.deinit(std.testing.allocator, &guard) catch unreachable;
    }
    var probe: RetirementProbe = .{
        .object_mutex = &device_mutex.mutex,
        .submit_result = if (scenario == .failed_submit) vulkan.VK_ERROR_DEVICE_LOST else vulkan.VK_SUCCESS,
    };
    var other_probe: RetirementProbe = .{ .object_mutex = &device_mutex.mutex };
    var procs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.end_command_buffer = RetirementProbe.end;
    procs.queue_submit = RetirementProbe.submit;
    procs.reset_fences = RetirementProbe.reset;
    procs.create_fence = RetirementProbe.create;
    procs.wait_for_fences = RetirementProbe.wait;
    procs.get_fence_status = RetirementProbe.status;
    procs.destroy_query_pool = RetirementProbe.destroyPool;
    procs.device_wait_idle = TemporaryAllocationProbe.waitIdle;
    procs.destroy_fence = TemporaryAllocationProbe.destroyFence;
    var handles: HandleSet = .{};
    defer std.debug.assert(handles.isEmpty());
    var memory_properties = std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties);
    var context = queueTestContext(&handles, &memory_properties);
    context.dispatch.device = &procs;
    context.vk_device = @ptrCast(&probe);
    context.vk_queue = @ptrCast(&probe);
    var queue: Queue = .{
        .context = context,
        .device_mutex = &device_mutex,
        .timeline = .{},
        .context_count = if (scenario == .status_prefix) 3 else 2,
    };
    defer queue.deinit(std.testing.io, objects) catch unreachable;
    const command_buffer: vulkan.VkCommandBuffer = @ptrCast(&probe);
    const set = blk: {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        queue.contexts[0].command_buffer = command_buffer;
        queue.contexts[1].command_buffer = @ptrCast(&other_probe);
        if (scenario == .status_prefix) queue.contexts[2].command_buffer = @ptrFromInt(48);
        const set = try queueTestQuery(&arena, &guard);
        try registerQueueTestQuery(&queue, &guard, set);
        set.pool = @as(vulkan.VkQueryPool, @ptrFromInt(8));
        handles.acquire(.query_pool);
        try queue.trackQuerySet(&guard, set);
        if (scenario == .retirement_during_end) {
            probe.retire_objects = objects;
            probe.retire_set = set;
        }
        break :blk set;
    };
    defer {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        set.header.releaseUserLocked(&guard, std.testing.io) catch unreachable;
        std.debug.assert(objects.total_reference_count == (if (queue.query_set_count == 0) @as(u64, 0) else @as(u64, 1)));
        std.debug.assert(objects.user_reference_count == 0);
    }
    if (scenario == .failed_submit) {
        try std.testing.expectError(
            error.DeviceLost,
            queue.submit(std.testing.io, objects, .{ .command_buffers = &.{command_buffer} }),
        );
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        try std.testing.expect(set.pending_use);
        try std.testing.expectEqual(@as(platform.Serial, 0), set.last_used_serial);
        try std.testing.expectEqual(@as(platform.Serial, 0), queue.timeline.lastSubmittedSerial());
        try std.testing.expectEqual(@as(platform.Serial, 0), queue.completed_serial);
        try std.testing.expectEqual(@as(u32, 0), queue.fences_in_flight_count);
        try std.testing.expectEqual(@as(usize, 1), probe.submitted_unlocked);
        try std.testing.expectEqual(@as(usize, 0), probe.destroyed_pools);
        try std.testing.expectEqual(@as(u64, 2), objects.total_reference_count);
        return;
    }
    const result = try queue.submit(std.testing.io, objects, .{ .command_buffers = &.{command_buffer} });
    if (scenario == .retirement_during_end) {
        {
            var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
            defer guard.unlock(std.testing.io);
            try std.testing.expectEqual(@as(usize, 1), probe.retired_during_end);
            try std.testing.expect(set.header.state == .destroyed);
            try std.testing.expect(!set.pending_use);
            try std.testing.expectEqual(result.serial, set.last_used_serial);
            try std.testing.expectEqual(result.serial, queue.timeline.lastSubmittedSerial());
            try std.testing.expectEqual(@as(platform.Serial, 0), queue.completed_serial);
            try std.testing.expect(set.pool != null);
            try std.testing.expectEqual(@as(u64, 2), objects.total_reference_count);
        }
        try std.testing.expectEqual(
            result.serial,
            try Queue.wait(std.testing.io, &queue, objects, .{ .serial = result.serial }),
        );
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        try std.testing.expect(set.pool == null);
        try std.testing.expect(set.backend_queue == null);
        try std.testing.expectEqual(@as(usize, 0), queue.query_set_count);
        try std.testing.expectEqual(@as(usize, 1), probe.destroyed_pools);
        try std.testing.expectEqual(@as(u64, 1), objects.total_reference_count);
        try std.testing.expectEqual(@as(usize, 1), probe.submitted_unlocked);
        try std.testing.expectEqual(@as(usize, 1), probe.waited_unlocked);
        return;
    }
    if (scenario == .status_prefix) {
        {
            var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
            defer guard.unlock(std.testing.io);
            try queue.trackQuerySet(&guard, set);
        }
        const second_buffer: vulkan.VkCommandBuffer = @ptrCast(&other_probe);
        const second = try queue.submit(std.testing.io, objects, .{ .command_buffers = &.{second_buffer} });
        {
            var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
            defer guard.unlock(std.testing.io);
            set.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
            probe.status_fail_at = 2;
            probe.status_result = vulkan.VK_ERROR_DEVICE_LOST;
        }
        try std.testing.expectError(
            error.DeviceLost,
            Queue.wait(std.testing.io, &queue, objects, .{ .serial = second.serial }),
        );
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        try std.testing.expectEqual(@as(usize, 2), probe.status_calls);
        try std.testing.expectEqual(@as(u32, 2), queue.fences_in_flight_count);
        try std.testing.expectEqual(result.serial, queue.fences_in_flight[0].serial);
        try std.testing.expectEqual(second.serial, queue.fences_in_flight[1].serial);
        try std.testing.expectEqual(@as(u32, 0), queue.unused_fence_count);
        try std.testing.expectEqual(second.serial, queue.timeline.lastSubmittedSerial());
        try std.testing.expectEqual(@as(platform.Serial, 0), queue.completed_serial);
        try std.testing.expectEqual(second.serial, set.last_used_serial);
        try std.testing.expect(set.pool != null);
        try std.testing.expect(set.backend_queue == &queue);
        try std.testing.expectEqual(@as(usize, 1), queue.query_set_count);
        try std.testing.expectEqual(@as(usize, 0), probe.destroyed_pools);
        try std.testing.expectEqual(@as(u64, 2), objects.total_reference_count);
        return;
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        set.header.retirePayloadLocked(&guard, std.testing.io, .early_destroy);
        probe.wait_result = vulkan.VK_TIMEOUT;
    }
    try std.testing.expectError(
        error.FenceWaitTimedOut,
        Queue.wait(std.testing.io, &queue, objects, .{ .serial = result.serial }),
    );
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        try std.testing.expectEqual(result.serial, queue.timeline.lastSubmittedSerial());
        try std.testing.expectEqual(@as(platform.Serial, 0), queue.completed_serial);
        try std.testing.expectEqual(result.serial, set.last_used_serial);
        try std.testing.expect(set.pool != null);
        try std.testing.expectEqual(@as(u32, 1), queue.fences_in_flight_count);
        try std.testing.expectEqual(@as(usize, 0), probe.destroyed_pools);
        probe.wait_result = vulkan.VK_ERROR_DEVICE_LOST;
    }
    try std.testing.expectError(
        error.DeviceLost,
        Queue.wait(std.testing.io, &queue, objects, .{ .serial = result.serial }),
    );
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
        defer guard.unlock(std.testing.io);
        try std.testing.expectEqual(@as(platform.Serial, 0), queue.completed_serial);
        try std.testing.expect(set.pool != null);
        probe.wait_result = vulkan.VK_SUCCESS;
        probe.status_result = vulkan.VK_ERROR_DEVICE_LOST;
    }
    try std.testing.expectError(
        error.DeviceLost,
        Queue.wait(std.testing.io, &queue, objects, .{ .serial = result.serial }),
    );
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, objects);
    defer guard.unlock(std.testing.io);
    try std.testing.expectEqual(result.serial, queue.timeline.lastSubmittedSerial());
    try std.testing.expectEqual(@as(platform.Serial, 0), queue.completed_serial);
    try std.testing.expectEqual(result.serial, set.last_used_serial);
    try std.testing.expect(set.pool != null);
    try std.testing.expectEqual(@as(u32, 1), queue.fences_in_flight_count);
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed_pools);
    try std.testing.expectEqual(@as(usize, 1), probe.submitted_unlocked);
    try std.testing.expectEqual(@as(usize, 3), probe.waited_unlocked);
    try std.testing.expectEqual(@as(u64, 2), objects.total_reference_count);
}

const TemporaryAllocationProbe = struct {
    retirement: RetirementProbe = .{},
    bytes: [16]u8 = @splat(0),
    allocated: usize = 0,
    freed: usize = 0,

    fn createBuffer(
        _: vulkan.VkDevice,
        _: [*c]const vulkan.VkBufferCreateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        result: [*c]vulkan.VkBuffer,
    ) callconv(.c) vulkan.VkResult {
        result[0] = @ptrFromInt(24);
        return vulkan.VK_SUCCESS;
    }

    fn requirements(
        _: vulkan.VkDevice,
        _: vulkan.VkBuffer,
        result: [*c]vulkan.VkMemoryRequirements,
    ) callconv(.c) void {
        result[0] = .{ .size = 16, .alignment = 4, .memoryTypeBits = 1 };
    }

    fn allocate(
        device: vulkan.VkDevice,
        _: [*c]const vulkan.VkMemoryAllocateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        result: [*c]vulkan.VkDeviceMemory,
    ) callconv(.c) vulkan.VkResult {
        const self: *TemporaryAllocationProbe = @ptrCast(@alignCast(device));
        self.allocated += 1;
        result[0] = @ptrCast(self);
        return vulkan.VK_SUCCESS;
    }

    fn bind(
        _: vulkan.VkDevice,
        _: vulkan.VkBuffer,
        _: vulkan.VkDeviceMemory,
        _: vulkan.VkDeviceSize,
    ) callconv(.c) vulkan.VkResult {
        return vulkan.VK_SUCCESS;
    }

    fn map(
        device: vulkan.VkDevice,
        _: vulkan.VkDeviceMemory,
        _: vulkan.VkDeviceSize,
        _: vulkan.VkDeviceSize,
        _: vulkan.VkMemoryMapFlags,
        result: [*c]?*anyopaque,
    ) callconv(.c) vulkan.VkResult {
        const self: *TemporaryAllocationProbe = @ptrCast(@alignCast(device));
        result[0] = &self.bytes;
        return vulkan.VK_SUCCESS;
    }

    fn unmap(_: vulkan.VkDevice, _: vulkan.VkDeviceMemory) callconv(.c) void {}

    fn free(
        device: vulkan.VkDevice,
        _: vulkan.VkDeviceMemory,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self: *TemporaryAllocationProbe = @ptrCast(@alignCast(device));
        self.freed += 1;
        @memset(&self.bytes, 0xdd);
    }

    fn destroyBuffer(
        device: vulkan.VkDevice,
        _: vulkan.VkBuffer,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self: *TemporaryAllocationProbe = @ptrCast(@alignCast(device));
        self.retirement.destroyed_buffers += 1;
    }

    fn waitIdle(_: vulkan.VkDevice) callconv(.c) vulkan.VkResult {
        return vulkan.VK_SUCCESS;
    }

    fn destroyFence(
        _: vulkan.VkDevice,
        _: vulkan.VkFence,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {}
};

test "queue temporary allocation survives recording arena retirement and drains by serial" {
    try temporaryAllocationLifetime(std.testing.allocator);
}

test "queue temporary allocation unwinds every stable owner allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, temporaryAllocationLifetime, .{});
}

fn temporaryAllocationLifetime(allocator: std.mem.Allocator) !void {
    var probe: TemporaryAllocationProbe = .{};
    var procs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.create_buffer = TemporaryAllocationProbe.createBuffer;
    procs.get_buffer_memory_requirements = TemporaryAllocationProbe.requirements;
    procs.allocate_memory = TemporaryAllocationProbe.allocate;
    procs.bind_buffer_memory = TemporaryAllocationProbe.bind;
    procs.map_memory = TemporaryAllocationProbe.map;
    procs.unmap_memory = TemporaryAllocationProbe.unmap;
    procs.free_memory = TemporaryAllocationProbe.free;
    procs.destroy_buffer = TemporaryAllocationProbe.destroyBuffer;
    procs.end_command_buffer = RetirementProbe.end;
    procs.queue_submit = RetirementProbe.submit;
    procs.reset_fences = RetirementProbe.reset;
    procs.create_fence = RetirementProbe.create;
    procs.wait_for_fences = RetirementProbe.wait;
    procs.get_fence_status = RetirementProbe.status;
    procs.device_wait_idle = TemporaryAllocationProbe.waitIdle;
    procs.destroy_fence = TemporaryAllocationProbe.destroyFence;
    var handles: HandleSet = .{};
    defer std.debug.assert(handles.isEmpty());
    var memory_properties = std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties);
    memory_properties.memoryTypeCount = 1;
    memory_properties.memoryTypes[0].propertyFlags =
        vulkan.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vulkan.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    var mutex: platform.DeviceMutex = .{};
    var objects: core.ObjectList = .{ .mutex = &mutex.mutex };
    probe.retirement.object_mutex = &mutex.mutex;
    var queue: Queue = .{
        .context = .{
            .allocator = allocator,
            .dispatch = .{ .global = null, .instance = null, .device = &procs },
            .vk_device = @ptrCast(&probe),
            .vk_queue = @ptrCast(&probe.retirement),
            .queue_family_index = 0,
            .memory_properties = &memory_properties,
            .handles = &handles,
        },
        .device_mutex = &mutex,
        .timeline = .{},
        .context_count = 2,
    };
    // Queue teardown releases the fence retained after serial completion too.
    // This defer runs before the handle-empty assertion, including OOM exits.
    defer queue.deinit(std.testing.io, &objects) catch |err| {
        std.debug.panic("Temporary allocation fixture teardown failed: {s}", .{@errorName(err)});
    };
    const command_buffer: vulkan.VkCommandBuffer = @ptrCast(&probe.retirement);
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, &objects);
        defer guard.unlock(std.testing.io);
        queue.contexts[0].command_buffer = command_buffer;
        queue.contexts[1].command_buffer = @ptrFromInt(32);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const payload = try arena.allocator().dupe(u8, &.{ 1, 2, 3, 4 });
    const buffer = blk: {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, &objects);
        defer guard.unlock(std.testing.io);
        const buffer = try queue.createTemporaryBuffer(allocator, .{
            .allocator = arena.allocator(),
            .dispatch = queue.context.dispatch,
            .vk_device = queue.context.vk_device,
            .memory_properties = &memory_properties,
            .non_coherent_atom_size = 1,
            .max_buffer_size = 1024,
            .handles = &handles,
        }, .{ .size = 4, .usage = .{ .map_write = true, .copy_src = true }, .mapped_at_creation = true });
        @memcpy(buffer.mappedSpan()[0..payload.len], payload);
        try std.testing.expect(buffer.device.allocator.ptr == allocator.ptr);
        try std.testing.expect(buffer.device.allocator.vtable == allocator.vtable);
        _ = arena.reset(.free_all);
        try queue.collectTemporaryBuffers(false);
        try std.testing.expectEqual(@as(usize, 1), queue.temporary_buffers.items.len);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, buffer.mappedSpan()[0..4]);
        try std.testing.expectEqual(@as(u32, 1), handles.countOf(.buffer));
        try std.testing.expectEqual(@as(u32, 1), handles.countOf(.memory));
        break :blk buffer;
    };
    const submitted = try queue.submit(std.testing.io, &objects, .{ .command_buffers = &.{command_buffer} });
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, &objects);
        defer guard.unlock(std.testing.io);
        try queue.collectTemporaryBuffers(false);
        try std.testing.expectEqual(@as(usize, 0), probe.freed);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, buffer.mappedSpan()[0..4]);
    }
    _ = try Queue.wait(std.testing.io, &queue, &objects, .{ .serial = submitted.serial });
    {
        var guard = core.ObjectGuard.lockUncancelable(std.testing.io, &objects);
        defer guard.unlock(std.testing.io);
        try std.testing.expectEqual(@as(usize, 0), queue.temporary_buffers.items.len);
        try std.testing.expectEqual(@as(usize, 1), probe.allocated);
        try std.testing.expectEqual(@as(usize, 1), probe.freed);
        try std.testing.expectEqual(@as(usize, 1), probe.retirement.destroyed_buffers);
        try std.testing.expectEqual(@as(u32, 0), handles.countOf(.buffer));
        try std.testing.expectEqual(@as(u32, 0), handles.countOf(.memory));
        try std.testing.expectEqual(@as(u32, 1), handles.countOf(.fence));
        try std.testing.expectEqual(@as(usize, 1), probe.retirement.submitted_unlocked);
        try std.testing.expectEqual(@as(usize, 1), probe.retirement.waited_unlocked);
    }
}

test "staging unmap keeps physical upload alive until its signaled fence retires once" {
    try stagingUploadLifetime(std.testing.allocator, .fence);
}

test "failed submission retains physical staging upload until idle cleanup" {
    try stagingUploadLifetime(std.testing.allocator, .failed_submit);
}

test "failed idle cleanup retains staging upload and destination for retry" {
    try stagingUploadLifetime(std.testing.allocator, .failed_idle);
}

test "terminal device loss cleans physical staging upload once without completed serials" {
    try stagingUploadLifetime(std.testing.allocator, .safe_loss);
}

test "record copy failure preserves buffer ownership through safe teardown" {
    try stagingUploadLifetime(std.testing.allocator, .failed_copy);
}

test "missing upload destroy proc preserves ownership for cleanup retry" {
    try stagingUploadLifetime(std.testing.allocator, .missing_destroy);
}

test "staging capacity OOM leaves state and native commands unchanged and permits retry" {
    try stagingUploadLifetime(std.testing.allocator, .reserve_oom);
}

test "staging transfer unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, stagingUploadAllocationLifetime, .{});
}

const StagingScenario = enum { fence, failed_submit, safe_loss, failed_copy, missing_destroy, reserve_oom, failed_idle };

const StagingNativeProbe = struct {
    retirement: RetirementProbe = .{},
    bytes: [2][16]u8 = @splat(@splat(0)),
    buffer_alive: [2]bool = @splat(false),
    memory_alive: [2]bool = @splat(false),
    destroyed: [2]usize = @splat(0),
    freed: [2]usize = @splat(0),
    created: usize = 0,
    allocated: usize = 0,
    copied: usize = 0,
    idle_result: vulkan.VkResult = vulkan.VK_SUCCESS,
    idle_unlocked: usize = 0,

    fn index(handle: anytype) usize {
        const value = @intFromPtr(handle);
        std.debug.assert(value == 64 or value == 72);
        return (value - 64) / 8;
    }

    fn createBuffer(
        device: vulkan.VkDevice,
        _: [*c]const vulkan.VkBufferCreateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        result: [*c]vulkan.VkBuffer,
    ) callconv(.c) vulkan.VkResult {
        const self: *StagingNativeProbe = @ptrCast(@alignCast(device));
        std.debug.assert(self.created < 2);
        self.buffer_alive[self.created] = true;
        result[0] = @ptrFromInt(64 + self.created * 8);
        self.created += 1;
        return vulkan.VK_SUCCESS;
    }

    fn allocate(
        device: vulkan.VkDevice,
        _: [*c]const vulkan.VkMemoryAllocateInfo,
        _: [*c]const vulkan.VkAllocationCallbacks,
        result: [*c]vulkan.VkDeviceMemory,
    ) callconv(.c) vulkan.VkResult {
        const self: *StagingNativeProbe = @ptrCast(@alignCast(device));
        std.debug.assert(self.allocated < 2);
        self.memory_alive[self.allocated] = true;
        result[0] = @ptrFromInt(64 + self.allocated * 8);
        self.allocated += 1;
        return vulkan.VK_SUCCESS;
    }

    fn map(
        device: vulkan.VkDevice,
        memory: vulkan.VkDeviceMemory,
        _: vulkan.VkDeviceSize,
        _: vulkan.VkDeviceSize,
        _: vulkan.VkMemoryMapFlags,
        result: [*c]?*anyopaque,
    ) callconv(.c) vulkan.VkResult {
        const self: *StagingNativeProbe = @ptrCast(@alignCast(device));
        result[0] = &self.bytes[index(memory)];
        return vulkan.VK_SUCCESS;
    }

    fn destroyBuffer(
        device: vulkan.VkDevice,
        buffer: vulkan.VkBuffer,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self: *StagingNativeProbe = @ptrCast(@alignCast(device));
        const slot = index(buffer);
        std.debug.assert(self.buffer_alive[slot]);
        self.buffer_alive[slot] = false;
        self.destroyed[slot] += 1;
    }

    fn free(
        device: vulkan.VkDevice,
        memory: vulkan.VkDeviceMemory,
        _: [*c]const vulkan.VkAllocationCallbacks,
    ) callconv(.c) void {
        const self: *StagingNativeProbe = @ptrCast(@alignCast(device));
        const slot = index(memory);
        std.debug.assert(self.memory_alive[slot]);
        self.memory_alive[slot] = false;
        self.freed[slot] += 1;
        @memset(&self.bytes[slot], 0xdd);
    }

    fn copy(
        command_buffer: vulkan.VkCommandBuffer,
        source: vulkan.VkBuffer,
        destination: vulkan.VkBuffer,
        count: u32,
        regions: [*c]const vulkan.VkBufferCopy,
    ) callconv(.c) void {
        const self: *StagingNativeProbe = @ptrCast(@alignCast(command_buffer));
        std.debug.assert(self.buffer_alive[index(source)] and self.buffer_alive[index(destination)]);
        std.debug.assert(count == 1 and regions[0].size == 4);
        self.copied += 1;
    }

    fn waitIdle(device: vulkan.VkDevice) callconv(.c) vulkan.VkResult {
        const self: *StagingNativeProbe = @ptrCast(@alignCast(device));
        self.retirement.probeUnlocked(&self.idle_unlocked);
        return self.idle_result;
    }
};

fn stagingUploadAllocationLifetime(allocator: std.mem.Allocator) !void {
    try stagingUploadLifetime(allocator, .fence);
}

fn stagingUploadLifetime(backing_allocator: std.mem.Allocator, scenario: StagingScenario) !void {
    var failing = std.testing.FailingAllocator.init(backing_allocator, .{});
    const allocator = failing.allocator();
    var probe: StagingNativeProbe = .{};
    var procs = std.mem.zeroes(dispatch.DeviceProcs);
    procs.create_buffer = StagingNativeProbe.createBuffer;
    procs.get_buffer_memory_requirements = TemporaryAllocationProbe.requirements;
    procs.allocate_memory = StagingNativeProbe.allocate;
    procs.bind_buffer_memory = TemporaryAllocationProbe.bind;
    procs.map_memory = StagingNativeProbe.map;
    procs.unmap_memory = TemporaryAllocationProbe.unmap;
    procs.free_memory = StagingNativeProbe.free;
    procs.destroy_buffer = StagingNativeProbe.destroyBuffer;
    procs.cmd_copy_buffer = StagingNativeProbe.copy;
    procs.end_command_buffer = RetirementProbe.end;
    procs.queue_submit = RetirementProbe.submit;
    procs.reset_fences = RetirementProbe.reset;
    procs.create_fence = RetirementProbe.create;
    procs.wait_for_fences = RetirementProbe.wait;
    procs.get_fence_status = RetirementProbe.status;
    procs.device_wait_idle = StagingNativeProbe.waitIdle;
    procs.destroy_fence = TemporaryAllocationProbe.destroyFence;
    var handles: HandleSet = .{};
    defer std.debug.assert(handles.isEmpty());
    var destination_owner: ?*buffer_module.Buffer = null;
    defer if (destination_owner) |owned| owned.destroy(allocator) catch |err| {
        std.debug.panic("Staging destination cleanup failed: {s}", .{@errorName(err)});
    };
    var memory_properties = std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties);
    memory_properties.memoryTypeCount = 1;
    memory_properties.memoryTypes[0].propertyFlags =
        vulkan.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vulkan.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    var mutex: platform.DeviceMutex = .{};
    var objects: core.ObjectList = .{ .mutex = &mutex.mutex };
    probe.retirement.object_mutex = &mutex.mutex;
    var queue: Queue = .{
        .context = .{
            .allocator = allocator,
            .dispatch = .{ .global = null, .instance = null, .device = &procs },
            .vk_device = @ptrCast(&probe),
            .vk_queue = @ptrCast(&probe.retirement),
            .queue_family_index = 0,
            .memory_properties = &memory_properties,
            .handles = &handles,
        },
        .device_mutex = &mutex,
        .timeline = .{},
        .context_count = 2,
    };
    var queue_live = true;
    defer if (queue_live) queue.deinit(std.testing.io, &objects) catch |err| {
        std.debug.panic("Staging fixture cleanup failed: {s}", .{@errorName(err)});
    };
    const command_buffer: vulkan.VkCommandBuffer = @ptrCast(&probe);
    queue.contexts[0].command_buffer = command_buffer;
    queue.contexts[1].command_buffer = @ptrFromInt(32);
    const device: buffer_module.Device = .{
        .allocator = allocator,
        .dispatch = queue.context.dispatch,
        .vk_device = queue.context.vk_device,
        .memory_properties = &memory_properties,
        .non_coherent_atom_size = 1,
        .max_buffer_size = 1024,
        .handles = &handles,
    };
    const destination = try buffer_module.Buffer.create(allocator, device, .{
        .size = 4,
        .usage = .{ .copy_dst = true },
    });
    // Queue cleanup below runs before this destination owner's earlier defer.
    destination_owner = destination;
    const upload = try buffer_module.Buffer.create(allocator, device, .{
        .size = 4,
        .usage = .{ .map_write = true, .copy_src = true },
        .mapped_at_creation = true,
    });
    destination.staging = upload;
    destination.state = .mapped_at_creation;
    destination.is_mapped_at_creation = true;
    @memcpy(upload.mappedSpan()[0..4], &[_]u8{ 1, 2, 3, 4 });
    const recording: buffer_module.Recording = .{ .command_buffer = command_buffer, .pending_serial = 1 };
    if (scenario == .reserve_oom) {
        const state_before = destination.state;
        const initialized_before = destination.is_data_initialized;
        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        try std.testing.expectError(error.TemporaryBufferAllocatorMismatch, queue.reserveStagingUpload(std.testing.allocator, destination));
        const original_device = destination.device.vk_device;
        destination.device.vk_device = null;
        try std.testing.expectError(error.TemporaryBufferDeviceMismatch, queue.reserveStagingUpload(allocator, destination));
        destination.device.vk_device = original_device;
        try std.testing.expectError(error.OutOfMemory, queue.reserveStagingUpload(allocator, destination));
        try std.testing.expectEqual(state_before, destination.state);
        try std.testing.expectEqual(initialized_before, destination.is_data_initialized);
        try std.testing.expect(destination.is_mapped_at_creation and destination.staging == upload);
        try std.testing.expectEqual(@as(usize, 0), probe.copied);
        try std.testing.expectEqual(@as(platform.Serial, 0), destination.last_usage_serial);
        try std.testing.expectEqual(@as(usize, 0), queue.temporary_buffers.items.len);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
    }
    try queue.reserveStagingUpload(allocator, destination);
    // Adoption and native submission must not allocate after the reservation.
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    if (scenario == .failed_copy) {
        procs.cmd_copy_buffer = null;
        try std.testing.expectError(error.MissingDeviceProc, destination.unmap(recording));
        queue.poisonRecording();
        try std.testing.expect(destination.staging == upload);
        try std.testing.expect(probe.buffer_alive[1] and probe.memory_alive[1]);
        try std.testing.expectEqual(@as(usize, 0), probe.copied);
        try std.testing.expectEqual(@as(usize, 0), queue.temporary_buffers.items.len);
        try queue.deinit(std.testing.io, &objects);
        queue_live = false;
        try destination.destroy(allocator);
        destination_owner = null;
        try std.testing.expectEqual(@as(usize, 1), probe.destroyed[0]);
        try std.testing.expectEqual(@as(usize, 1), probe.destroyed[1]);
        try std.testing.expectEqual(@as(usize, 1), probe.freed[0]);
        try std.testing.expectEqual(@as(usize, 1), probe.freed[1]);
        return;
    }
    const result = try destination.unmap(recording);
    queue.adoptStagingUploadAssumeCapacity(result.staging_upload.?);
    try std.testing.expect(destination.staging == null and destination.state == .unmapped);
    try std.testing.expect(probe.buffer_alive[1] and probe.memory_alive[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, probe.bytes[1][0..4]);
    try std.testing.expectEqual(@as(usize, 1), probe.copied);
    try queue.collectTemporaryBuffers(false);
    try std.testing.expectEqual(@as(platform.Serial, 0), queue.temporary_buffers.items[0].serial);
    if (scenario == .failed_submit) {
        probe.retirement.submit_result = vulkan.VK_ERROR_DEVICE_LOST;
        try std.testing.expectError(error.DeviceLost, queue.submit(std.testing.io, &objects, .{ .command_buffers = &.{command_buffer} }));
        try std.testing.expect(queue.recording_poisoned);
        try std.testing.expectEqual(@as(platform.Serial, 0), queue.timeline.lastSubmittedSerial());
        try queue.collectTemporaryBuffers(false);
        try std.testing.expect(probe.buffer_alive[1] and probe.memory_alive[1]);
        try queue.deinit(std.testing.io, &objects);
        queue_live = false;
    } else {
        const submitted = try queue.submit(std.testing.io, &objects, .{ .command_buffers = &.{command_buffer} });
        try std.testing.expectEqual(submitted.serial, queue.temporary_buffers.items[0].serial);
        probe.retirement.wait_result = vulkan.VK_TIMEOUT;
        try std.testing.expectError(error.FenceWaitTimedOut, Queue.wait(std.testing.io, &queue, &objects, .{ .serial = submitted.serial }));
        probe.retirement.wait_result = vulkan.VK_SUCCESS;
        probe.retirement.status_result = vulkan.VK_NOT_READY;
        try std.testing.expectError(error.WaitIterationExhausted, Queue.wait(std.testing.io, &queue, &objects, .{ .serial = submitted.serial }));
        probe.retirement.status_result = vulkan.VK_ERROR_DEVICE_LOST;
        try std.testing.expectError(error.DeviceLost, Queue.wait(std.testing.io, &queue, &objects, .{ .serial = submitted.serial }));
        try std.testing.expect(probe.buffer_alive[1] and probe.memory_alive[1]);
        try std.testing.expectEqual(@as(platform.Serial, 0), queue.completed_serial);
        try std.testing.expectEqual(@as(platform.Serial, 0), queue.timeline.completed);
        if (scenario == .failed_idle) {
            probe.idle_result = vulkan.VK_ERROR_OUT_OF_DEVICE_MEMORY;
            try std.testing.expectError(error.OutOfDeviceMemory, queue.deinit(std.testing.io, &objects));
            try std.testing.expect(probe.buffer_alive[0] and probe.memory_alive[0]);
            try std.testing.expect(probe.buffer_alive[1] and probe.memory_alive[1]);
            try std.testing.expectEqual(@as(usize, 1), queue.temporary_buffers.items.len);
            try std.testing.expectEqual(@as(u32, 1), queue.fences_in_flight_count);
            try std.testing.expectEqual(@as(platform.Serial, 0), queue.completed_serial);
            probe.idle_result = vulkan.VK_SUCCESS;
        }
        if (scenario == .safe_loss) {
            probe.idle_result = vulkan.VK_ERROR_DEVICE_LOST;
            try std.testing.expectError(error.DeviceLost, queue.deinit(std.testing.io, &objects));
            try std.testing.expectEqual(@as(platform.Serial, 0), queue.completed_serial);
            try std.testing.expectEqual(@as(platform.Serial, 0), queue.timeline.completed);
            probe.idle_result = vulkan.VK_SUCCESS;
        } else {
            probe.retirement.status_result = vulkan.VK_SUCCESS;
            if (scenario == .missing_destroy) {
                procs.destroy_buffer = null;
                try std.testing.expectError(error.MissingDeviceProc, Queue.wait(std.testing.io, &queue, &objects, .{ .serial = submitted.serial }));
                try std.testing.expectEqual(@as(usize, 1), queue.temporary_buffers.items.len);
                try std.testing.expect(probe.buffer_alive[1] and probe.memory_alive[1]);
                procs.destroy_buffer = StagingNativeProbe.destroyBuffer;
            }
            _ = try Queue.wait(std.testing.io, &queue, &objects, .{ .serial = submitted.serial });
            _ = try Queue.wait(std.testing.io, &queue, &objects, .{ .serial = submitted.serial });
        }
        try std.testing.expectEqual(@as(usize, 0), queue.temporary_buffers.items.len);
        try queue.deinit(std.testing.io, &objects);
        queue_live = false;
    }
    try std.testing.expect(!probe.buffer_alive[1] and !probe.memory_alive[1]);
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed[1]);
    try std.testing.expectEqual(@as(usize, 1), probe.freed[1]);
    try std.testing.expect(probe.buffer_alive[0] and probe.memory_alive[0]);
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed[0]);
    try std.testing.expect(probe.retirement.submitted_unlocked != 0);
    try std.testing.expect(probe.retirement.waited_unlocked != 0 or scenario == .failed_submit);
}
