//! The query set: the object a resolve reads from, and when it may be read.
//!
//! **What this file is.** The port of `src/dawn/native/QuerySet.{h,cpp}` at
//! Dawn revision `32f77c02294310054a660c393feded4bcb3f203c`. It holds the lifetime state, the
//! per-query availability bitmap, the range walk the reset hoist and the
//! resolve share, and the plan one resolve turns into. The Vulkan pool is
//! `src/engine/vulkan_query_set.zig`; the rules are `src/command/query.zig`.
//!
//! **What this file does not claim.** It does not claim the timestamp
//! conversion of `native/QueryHelper.{h,cpp}`, whose only path is behind the
//! `TimestampQuery` feature: `CommandEncoder.cpp:2334-2336` returns before it
//! for an occlusion set. The plan records the conversion rows as skipped.
//! `getPool` borrows the backend handle. The queue owns serial-safe retirement.

const std = @import("std");

const vulkan = @import("vulkan");

const api = @import("../api/api.zig");
const command_query = @import("../command/query.zig");
pub const Descriptor = command_query.Descriptor;
pub const DescriptorOptions = command_query.DescriptorOptions;
pub const Error = command_query.Error;
const core_errors = @import("../core/errors.zig");
const core = @import("../core/root.zig");
const platform = @import("../platform/root.zig");
const queue_module = @import("queue.zig");

/// Where a query set is in its life (`QuerySet.h:78`).
///
/// Submit-time semantic state, protected by the owning core ObjectGuard.
/// `ValidateCanUseInSubmitNow` reads it at submit time (`QuerySet.cpp:150`).
pub const State = enum {
    /// An initialized error set has no available queries.
    unavailable,
    /// A real set. Every availability flag is false.
    available,
    /// `DestroyImpl` ran (`QuerySet.cpp:110`).
    destroyed,
};

/// `QuerySetBase` (`QuerySet.cpp:44-83`).
///
/// Availability is monotonic: `markQueryAvailable` sets a flag and never clears
/// it (`QuerySet.cpp:144-146`), so a set that has been resolved once keeps every
/// query it has ever written. That is why the clipped-away case and the
/// never-written case are two different paths: the first has its flag set and
/// reads the pool's own zero, the second has its flag clear and reads the fill.
pub const QuerySet = struct {
    header: core.Object,

    /// The type the descriptor named (`QuerySet.cpp:83`).
    query_type: command_query.QueryType,
    /// The number of queries the descriptor named (`QuerySet.cpp:84`). Zero is
    /// legal: Dawn compares the count against a maximum and not against a
    /// minimum (`QuerySet.cpp:55-57`).
    query_count: u32,
    /// Where the object is in its life (`QuerySet.cpp:85`).
    state: State,
    /// One flag per query, all false on a fresh set (`QuerySet.cpp:86`).
    availability: []bool,
    /// The Vulkan pool, or null once `destroy` ran or before
    /// `src/engine/vulkan_query_set.zig` has created it. The front end never
    /// reads it; that file is the only reader, which is the port's answer to
    /// `QuerySetVk` inheriting from `QuerySetBase`.
    pool: ?vulkan.VkQueryPool = null,
    /// Borrows the exact queue storage that registered the native pool.
    /// Keep that queue alive and unmoved until deregistration or `Queue.deinit` detaches this set.
    /// `destroy` can defer deregistration until the last submission completes.
    /// `null` means this set has no registered queue.
    backend_queue: ?*queue_module.Queue = null,
    backend_next: ?*QuerySet = null,
    last_used_serial: platform.Serial = 0,
    pending_use: bool = false,

    /// Descriptor refusal, allocator mismatch, retirement, or allocation failure.
    pub const CreateError = core.ValidationError || core.CreateError;

    /// Creates one owned user reference after guarded allocator and descriptor checks.
    /// On failure no object or reference is published. Release the result under its guard.
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        guard: *const core.ObjectGuard,
        dev: *core.Device,
        descriptor: Descriptor,
        options: DescriptorOptions,
    ) CreateError!api.objects.QuerySet {
        try dev.arena.checkAllocator(guard, gpa);
        try command_query.validateDescriptor(descriptor, options);
        const set = try dev.create(gpa, guard, QuerySet, .{
            .kind = .query_set,
            .state = .initializing,
            .initial_reference = .user,
            .label = descriptor.label orelse "",
        });
        errdefer set.header.discardUnpublishedLocked(guard) catch unreachable;

        // No destructor runs if this allocation fails: only the creator ledger is discarded.
        const availability = try dev.arena.allocator(guard).alloc(bool, descriptor.count);
        @memset(availability, false);

        set.query_type = descriptor.type_;
        set.query_count = descriptor.count;
        set.state = .available;
        set.availability = availability;
        set.pool = null;
        set.backend_queue = null;
        set.backend_next = null;
        set.last_used_serial = 0;
        set.pending_use = false;
        set.header.setInitializedNoError(guard);
        set.header.attach(guard, io);
        return .{ .handle = @ptrCast(dev.handleFor(guard, QuerySet, set, .query_set).ptr) };
    }

    /// Consumes one owned user reference; dependent leases may keep the payload alive.
    pub fn apiDestroy(
        self: *QuerySet,
        guard: *const core.ObjectGuard,
        io: std.Io,
    ) core.ReferenceError!void {
        try self.header.releaseUserLocked(guard, io);
    }

    /// Marks the payload destroyed and asks the queue for serial-safe pool retirement.
    /// Keep `backend_queue` alive and unmoved while it remains non-null.
    /// A native retirement failure stays in the queue's typed cleanup error slot.
    pub fn destroy(
        self: *QuerySet,
        guard: *const core.ObjectGuard,
        io: std.Io,
        reason: core.DestroyReason,
    ) void {
        guard.assertOwns(self.header.tracking);
        _ = reason;
        self.state = .destroyed;
        if (self.backend_queue) |queue| {
            queue.retireQueryPool(guard, io, self) catch |err| {
                queue.recordCleanupError(guard, err);
            };
        }
    }

    /// `QuerySetBase::GetType` (`QuerySet.cpp:119-121`). The port names the
    /// object by the handle's kind byte, so the answer is the kind itself.
    pub fn getObjectType(self: *const QuerySet, guard: *const core.ObjectGuard) core.Handle.Kind {
        guard.assertOwns(self.header.tracking);
        return .query_set;
    }

    /// `QuerySetBase::APIGetType` (`QuerySet.cpp:158-160`) and
    /// `GetQueryType` (`:122-124`), which are one read.
    pub fn apiGetType(self: *const QuerySet, guard: *const core.ObjectGuard) command_query.QueryType {
        guard.assertOwns(self.header.tracking);
        return self.query_type;
    }

    /// `QuerySetBase::APIGetCount` (`QuerySet.cpp:162-164`) and
    /// `GetQueryCount` (`:126-128`), which are one read.
    pub fn apiGetCount(self: *const QuerySet, guard: *const core.ObjectGuard) u32 {
        guard.assertOwns(self.header.tracking);
        return self.query_count;
    }

    /// `QuerySetBase::IsQueryAvailable` (`QuerySet.cpp:131-133`).
    pub fn isQueryAvailable(
        self: *const QuerySet,
        guard: *const core.ObjectGuard,
        index: u32,
    ) bool {
        guard.assertOwns(self.header.tracking);
        // The index is bounded by the caller: `validateResolve` runs before a
        // resolve and `beginOcclusionQuery` before a write, so an index past the
        // vector is a defect in that caller and not a rule here.
        std.debug.assert(index < self.availability.len);
        return self.availability[index];
    }

    /// `QuerySetBase::AreAllQueriesAvailable` (`QuerySet.cpp:135-142`). It
    /// short-circuits on the first unavailable index, which is the answer the
    /// walk gives and one pass cheaper.
    pub fn areAllQueriesAvailable(
        self: *const QuerySet,
        guard: *const core.ObjectGuard,
        first: u32,
        count: u32,
    ) bool {
        guard.assertOwns(self.header.tracking);
        const end = first + count;
        std.debug.assert(end <= self.availability.len);
        var index = first;
        while (index < end) : (index += 1) {
            if (!self.availability[index]) return false;
        }
        return true;
    }

    /// `QuerySetBase::MarkQueryAvailable` (`QuerySet.cpp:144-146`).
    ///
    /// Monotonic, and that is the whole point: the replay calls it at the end
    /// of an occlusion query (`CommandBufferVk.cpp:2141`) whatever the query
    /// counted. A query that closed with zero passing samples is available; a
    /// query that never closed is not, and the two zeros reach the destination
    /// by different routes.
    pub fn markQueryAvailable(self: *QuerySet, guard: *const core.ObjectGuard, index: u32) void {
        guard.assertOwns(self.header.tracking);
        std.debug.assert(index < self.availability.len);
        self.availability[index] = true;
    }

    /// `QuerySetBase::ValidateCanUseInSubmitNow` (`QuerySet.cpp:148-152`).
    /// `Queue::ValidateCanUseInSubmitNow` runs it for every set in
    /// `usages.usedQuerySets` (`Queue.cpp:543-545`), so this is a submit-time
    /// check and not a record-time one.
    pub fn validateCanUseInSubmit(
        self: *const QuerySet,
        guard: *const core.ObjectGuard,
    ) error{ QuerySetIsError, QuerySetDestroyed }!void {
        guard.assertOwns(self.header.tracking);
        switch (self.state) {
            .unavailable => return error.QuerySetIsError,
            .destroyed => return error.QuerySetDestroyed,
            .available => {},
        }
    }
};

/// The query set the handle names, or the rule that rejects the handle. The
/// shape M11's `resolveTexture` and `resolveSampler` already have.
///
/// **This is where the alignment comes back.** `src/api/objects.zig` is
/// generated and types every `handle` field `?*anyopaque`, so the guarantee
/// `core.Handle.ptr` carries is lost at the API boundary. It is asserted once
/// here, where the loss happens, rather than at every read of the handle. The
/// only writer of that field is a `create` that returned `@ptrCast` of an arena
/// object, so the assertion cannot fail for a handle this module produced.
pub fn resolveQuerySet(
    dev: *core.Device,
    guard: *const core.ObjectGuard,
    target: api.objects.QuerySet,
) core.HandleError!*QuerySet {
    const wrapped: core.Handle = .{
        .ptr = @alignCast(target.handle orelse return error.HandleKindMismatch),
        .kind = .query_set,
    };
    return dev.resolve(guard, QuerySet, wrapped);
}

/// A half-open range of query indices.
pub const QueryRange = struct {
    first: u32,
    count: u32,
};

/// The walk both Vulkan consumers share, from `ForEachAvailableQueryRange`
/// (`QuerySet.h:88-109`).
///
/// Upstream is a template that takes two callables. Zig has no generic function
/// value, so the template becomes a cursor and each caller keeps its own loop
/// body: `planResolve` below is the resolve body and `resetTrackedQueries` in
/// `src/engine/vulkan_query_set.zig` is the reset body. The two maps this walk
/// is pointed at are different maps, and conflating them is the mistake the
/// naming is here to prevent: the per-pass map is written while the pass is
/// recorded (`PassResourceUsageTracker.cpp:349-358`) and this one is written
/// while the command buffer is replayed (`CommandBuffer.cpp:390-405`).
pub const AvailableRangeWalk = struct {
    availability: []const bool,
    current: u32,
    end: u32,

    pub fn init(availability: []const bool, start: u32, count: u32) AvailableRangeWalk {
        // Every caller bounds the range before it walks: a resolve through
        // `command_query.validateResolve`, a reset through the same set's count.
        // An end past the vector would index past it, so the claim is stated
        // here rather than assumed of the caller.
        std.debug.assert(start + count <= availability.len);
        return .{ .availability = availability, .current = start, .end = start + count };
    }

    /// The next maximal run of available queries, or null once the range is
    /// exhausted. An unavailable index is skipped, so a caller that reads every
    /// run has walked exactly the available queries and nothing else.
    pub fn next(self: *AvailableRangeWalk) ?QueryRange {
        while (self.current < self.end) : (self.current += 1) {
            if (!self.availability[self.current]) continue;
            const first = self.current;
            while (self.current < self.end and self.availability[self.current]) {
                self.current += 1;
            }
            return .{ .first = first, .count = self.current - first };
        }
        return null;
    }
};

/// The largest number of maximal available runs a range of `count` indices can
/// produce. A run is at least one index and is separated from the next by at
/// least one unavailable index, so `n` indices yield at most `ceil(n / 2)`.
pub fn maxRunCount(count: u32) usize {
    // `count + 1` wrapped to zero at `maxInt(u32)`, and the caller sizes its
    // `runs` slice with what this returns, so the wrap handed back an empty
    // buffer and every later resolve died on `error.RunsSliceTooSmall`. The
    // ceiling is the half plus the remainder: the addend is at most one and
    // the half is below `count`, so the sum cannot overflow for any `u32` on
    // any target width. `ceil(n / 2)` for n = 1, 2, 3, 4 is 1, 1, 2, 2.
    const whole_count: usize = @divFloor(count, 2);
    const odd_count: usize = @intFromBool(count % 2 != 0);
    return whole_count + odd_count;
}

/// One `vkCmdCopyQueryPoolResults` call: pool indices
/// `[first, first + count)` written at `destination_offset + 8 *
/// (first - resolve_first_query)`.
pub const CopyRun = struct {
    first: u32,
    count: u32,
    destination_offset: u64,
};

/// What one resolve asks the replay to do.
pub const ResolvePlan = struct {
    /// How many entries of the caller's `runs` slice were written.
    run_count: usize,
    /// True when at least one requested query was never written, which is the
    /// only reason to zero the destination first
    /// (`CommandBufferVk.cpp:1437-1450`). Upstream ORs this with the
    /// `ClearBufferBeforeResolveQueries` toggle, which is off by default and
    /// has no port.
    needs_zero_fill: bool,
    /// The bytes the fill covers, counted from `destination_offset`.
    zero_fill_size: u64,
};

/// Plans the copy for one resolve, from the availability the replay has already
/// marked (`RecordResolveQuerySetCmd`, `CommandBufferVk.cpp:577-597`, with
/// `Command::ResolveQuerySet`, `:1422-1458`).
///
/// A run's destination offset is reindexed: pool index `first` belongs at slot
/// `first - params.first_query`, so the second slot of a resolve that starts at
/// pool index one receives the run at pool index two. That reindexing is why a
/// sparse range is worth a test of its own, because with every query available
/// it never moves anything.
///
/// `runs` is the caller's, sized `maxRunCount(params.query_count)`. A slice too
/// small is an error and not a truncation, because a truncated plan would leave
/// the destination holding whatever the caller last put in it.
pub fn planResolve(
    availability: []const bool,
    params: command_query.ResolveParams,
    runs: []CopyRun,
) Error!ResolvePlan {
    var walk = AvailableRangeWalk.init(availability, params.first_query, params.query_count);
    var plan: ResolvePlan = .{
        .run_count = 0,
        .needs_zero_fill = false,
        .zero_fill_size = command_query.queryStorageSize(params.query_count),
    };

    // `CommandBufferVk.cpp:1424-1426` skips a zero-count resolve outright, so a
    // plan for one is an empty plan and not a fill of zero bytes.
    while (walk.next()) |run| {
        if (plan.run_count == runs.len) return error.ResolveRunBufferTooSmall;
        runs[plan.run_count] = .{
            .first = run.first,
            .count = run.count,
            .destination_offset = params.destination_offset +
                command_query.queryStorageSize(run.first - params.first_query),
        };
        plan.run_count += 1;
    }

    // Every index the walk skipped is a query the pool never wrote. Those slots
    // keep the caller's bytes until the fill puts a zero there, which is the
    // whole difference between the two routes a zero can arrive by.
    plan.needs_zero_fill = !allAvailable(availability, params);
    return plan;
}

fn allAvailable(availability: []const bool, params: command_query.ResolveParams) bool {
    const end = params.first_query + params.query_count;
    var index = params.first_query;
    while (index < end) : (index += 1) {
        if (!availability[index]) return false;
    }
    return true;
}

fn queryTestUncaptured(
    gpa: std.mem.Allocator,
    io: std.Io,
    context: *anyopaque,
    view: core_errors.ErrorView,
) void {
    _ = gpa;
    _ = io;
    _ = context;
    _ = view;
    @panic("unexpected query error callback");
}

fn queryFactoryAllocationTest(gpa: std.mem.Allocator) !void {
    // Every allocation failure must consume unpublished ownership without a payload callback.
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var callback_context: u8 = 0;
    var dev = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = &callback_context,
        .uncaptured_callback = queryTestUncaptured,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, dev.borrow().objectList());
    defer guard.unlock(io);
    defer dev.deinit(gpa, &guard) catch @panic("query references leaked");
    defer {
        std.debug.assert(dev.arena.objects.total_reference_count == 0);
        std.debug.assert(dev.arena.objects.user_reference_count == 0);
        std.debug.assert(dev.arena.queryTrackedCount(&guard) == 0);
    }
    const target = try QuerySet.create(gpa, io, &guard, &dev, .{
        .label = "allocation failure coverage",
        .type_ = .occlusion,
        .count = command_query.max_query_count,
    }, .{});
    const set = try resolveQuerySet(&dev, &guard, target);
    defer set.apiDestroy(&guard, io) catch @panic("query release failed");
    try std.testing.expectEqual(@as(u32, 1), set.header.reference_count);
    try std.testing.expectEqual(@as(u32, 1), set.header.user_reference_count);
    try std.testing.expect(set.header.reference_escaped);
    try std.testing.expect(!set.isQueryAvailable(&guard, 0));
    set.markQueryAvailable(&guard, 0);
    try std.testing.expect(set.isQueryAvailable(&guard, 0));
}

test "query factory allocation failures do not abandon unpublished creator references" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        queryFactoryAllocationTest,
        .{},
    );
}

test "query validation and allocator refusal leave no creator reference" {
    // A rejected descriptor must not allocate an error object with an inaccessible user ref.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mutex: std.Io.Mutex = .init;
    var callback_context: u8 = 0;
    var dev = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = &callback_context,
        .uncaptured_callback = queryTestUncaptured,
    });
    var guard = core.ObjectGuard.lockUncancelable(io, dev.borrow().objectList());
    defer guard.unlock(io);
    defer dev.deinit(gpa, &guard) catch @panic("query references leaked");
    const descriptor: Descriptor = .{ .type_ = .timestamp, .count = 1 };
    var foreign_storage: [64]u8 = undefined;
    var foreign = std.heap.FixedBufferAllocator.init(&foreign_storage);
    try std.testing.expectError(error.AllocatorMismatch, QuerySet.create(
        foreign.allocator(),
        io,
        &guard,
        &dev,
        descriptor,
        .{},
    ));
    try std.testing.expectError(error.RequiredFeatureMissing, QuerySet.create(
        gpa,
        io,
        &guard,
        &dev,
        descriptor,
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 0), dev.arena.queryCapacity(&guard));
    try std.testing.expectEqual(@as(u64, 0), dev.arena.objects.total_reference_count);
    try std.testing.expectEqual(@as(u64, 0), dev.arena.objects.user_reference_count);
    try std.testing.expectEqual(@as(usize, 0), dev.arena.queryTrackedCount(&guard));
}
