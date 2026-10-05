//! The Vulkan queue: one command pool, a bounded pool of command contexts, and
//! a bounded pool of fences.
//!
//! **What this file is.** The port of `src/dawn/native/vulkan/QueueVk.{h,cpp}`
//! (102 + 540 lines) at Dawn revision
//! `32f77c02294310054a660c393feded4bcb3f203c`, read-only at
//! `/tmp/scratch/research/dawn`. `docs/40-plan.md` §3.6 carries
//! its rows.
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
//! bounds both, because `AGENTS.md` §2 requires a named bound on every loop and
//! an unbounded loop in a library is a hang, not a wait.
//!
//! **No allocator parameter on `init`.** It allocates nothing: the pools are
//! fixed arrays, so there is nothing to fail and nothing to inject.
//! `AGENTS.md` §3 makes the allocator a parameter of every *allocating* function,
//! and this is not one.

const std = @import("std");
const vulkan = @import("vulkan");
const dispatch = @import("../vk/dispatch.zig");
const platform = @import("../platform/root.zig");
const vulkan_device = @import("vulkan_device.zig");

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
/// nothing reaches back through a pointer to a device it does not own
/// (`AGENTS.md` §3, "State is a parameter, not a capture").
pub const Context = struct {
    /// The allocator the caller's own allocations take.
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
/// `AGENTS.md` §3.1 makes a null dispatch field a typed error and never a
/// forced unwrap, so every entry point this file reaches is bound through an
/// `orelse` that reports rather than through `procs.foo.?`. Two members carry
/// that: a `Context` with no device tier, which `init` refuses
/// (`src/engine/queue.zig:231`) and which only a hand-built `Context` can reach,
/// and a device proc the loader did not resolve. `dispatch.loadDeviceProcs`
/// refuses a table with a null field itself (`src/vk/dispatch.zig:1061`), so
/// both name the hand-built case.
///
/// The rest of the set is `dispatch.Error`, the `VkResult` mapping
/// `AGENTS.md` §3.1 puts in `src/vk/dispatch.zig` and nowhere else.
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
    /// The device lock every public entry point takes
    /// (`docs/30-port-design.md` §9.1). Borrowed: the device owns it, and a
    /// queue that outlived its device lock would outlive its device.
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

    pub const InitOptions = struct {
        context: Context,
        device_mutex: *platform.DeviceMutex,
    };

    pub const RecordingError = ProcError || error{
        /// Every context is still in flight. Dawn allocates another pool
        /// (`QueueVk.cpp:255`-`:281`) with no bound; the port names the bound
        /// and reports exhaustion as its own error, per `AGENTS.md` §2.
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

    pub const SubmitError = RecordingError || error{
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

    pub const WaitError = ProcError || platform.WaitError || error{
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

    /// Ports `Queue::DestroyImpl` (`QueueVk.cpp:441`-`:483`): every context
    /// first, then the fences, in flight before unused.
    ///
    /// It reports rather than returning `void`, because every proc it reaches
    /// is a dispatch field and `AGENTS.md` §3.1 makes a null one a typed error.
    /// Each proc is bound before its loop runs, so a missing entry point costs
    /// the caller that one pool rather than the teardown up to that point.
    pub fn deinit(self: *Queue) ProcError!void {
        var index: u32 = 0;
        while (index < self.context_count) : (index += 1) {
            try self.destroyContext(index);
        }
        // A device loss can leave a fence in flight (`QueueVk.cpp:466`-`:467`),
        // so both pools are swept, in flight first. The entry point is bound
        // once because both loops destroy through it.
        const destroy_fence = (try self.deviceProcs()).destroy_fence orelse
            return error.MissingDeviceProc;
        index = 0;
        while (index < self.fences_in_flight_count) : (index += 1) {
            destroy_fence(
                self.context.vk_device,
                self.fences_in_flight[index].fence,
                null,
            );
            self.context.handles.release(.fence);
        }
        self.fences_in_flight_count = 0;
        index = 0;
        while (index < self.unused_fence_count) : (index += 1) {
            destroy_fence(self.context.vk_device, self.unused_fences[index], null);
            self.context.handles.release(.fence);
        }
        self.unused_fence_count = 0;
        // The queue is gone and nothing reads the value again, so the receiver
        // is poisoned rather than half reset.
        self.* = undefined;
    }

    /// Ports `Queue::SubmitPendingCommandsImpl` (`QueueVk.cpp:298`-`:374`).
    ///
    /// The buffers in `options` are ended here and submitted as one batch, which
    /// is what Dawn does to `mRecordingContext.commandBuffer` (`:323`) and
    /// `mRecordingContext.commandBufferList` (`:335`-`:337`). The semaphore
    /// fields of `VkSubmitInfo` are the rows M20 and M21 fill; this milestone
    /// has one queue and no swap chain, so every semaphore count is zero.
    pub fn submit(self: *Queue, options: SubmitOptions) SubmitError!SubmitResult {
        if (options.command_buffers.len == 0) return error.NoCommandBuffer;
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
        const serial = self.timeline.submit();
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
    pub fn wait(io: std.Io, self: *Queue, options: WaitOptions) WaitError!platform.Serial {
        // Bound: the retry bound. Dawn's `while (1)` at `QueueVk.cpp:496`
        // retries forever on `VK_TIMEOUT` when the caller passed an infinite
        // timeout, and `AGENTS.md` §2 requires a named bound.
        var iteration: u32 = 0;
        while (iteration < max_fence_wait_iteration_count) : (iteration += 1) {
            const fence = findFenceFor(self, options.serial) orelse {
                // The fence for this serial was already retired, so the serial
                // is complete (`QueueVk.cpp:508`-`:513`).
                try self.complete(io, options.serial);
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

            const completed = try retireCompleted(io, self);
            try self.complete(io, completed);
            return completed;
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
    /// reaches is a dispatch field and `AGENTS.md` §3.1 makes a null one a
    /// typed error.
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
    /// are dispatch fields and `AGENTS.md` §3.1 makes a null one a typed error.
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
            if (!self.contexts[index].in_flight) return index;
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
    /// `Timeline.updateCompletedTo` threads `io` and `device_mutex` before
    /// `self` (`src/platform/serial.zig:271`-`:276`), so Zig does not treat it
    /// as a member function. The qualified call is what puts each argument in
    /// the parameter the signature names.
    fn complete(self: *Queue, io: std.Io, serial: platform.Serial) WaitError!void {
        try platform.Timeline.updateCompletedTo(io, self.device_mutex, &self.timeline, serial);
    }

    /// The device tier, or the error that says the `Context` carries none.
    ///
    /// Every entry point in this file is reached through here rather than
    /// through a forced unwrap of `context.dispatch.device`, because
    /// `AGENTS.md` §3.1 makes a missing dispatch field a typed error.
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
fn retireCompleted(io: std.Io, queue: *Queue) Queue.WaitError!platform.Serial {
    const get_fence_status = (try queue.deviceProcs()).get_fence_status orelse
        return error.MissingDeviceProc;
    // `Timeline.completedSerial` threads `io` before `self`
    // (`src/platform/serial.zig:251`-`:253`), so the same qualified call.
    var retired: platform.Serial = platform.Timeline.completedSerial(io, &queue.timeline);
    while (queue.fences_in_flight_count != 0) {
        const entry = queue.fences_in_flight[0];
        switch (dispatch.classify(get_fence_status(
            queue.context.vk_device,
            entry.fence,
        ))) {
            .not_ready => return retired,
            .success => {},
            .@"error" => |err| return err,
            else => return error.FenceStatusFailed,
        }
        retired = entry.serial;
        queue.releaseFence(entry.fence);
        queue.fences_in_flight_count -= 1;
        var slot: u32 = 0;
        while (slot < queue.fences_in_flight_count) : (slot += 1) {
            queue.fences_in_flight[slot] = queue.fences_in_flight[slot + 1];
        }
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
