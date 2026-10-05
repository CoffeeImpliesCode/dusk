//! The query set: the object a resolve reads from, and when it may be read.
//!
//! **What this file is.** The port of `src/dawn/native/QuerySet.{h,cpp}` at
//! Dawn revision `32f77c02294310054a660c393feded4bcb3f203c`, read-only at
//! `/tmp/scratch/research/dawn`. It holds the lifetime state, the
//! per-query availability bitmap, the range walk the reset hoist and the
//! resolve share, and the plan one resolve turns into. The Vulkan pool is
//! `src/engine/vulkan_query_set.zig`; the rules are `src/command/query.zig`.
//! `docs/40-plan.md` §3.3 carries its twenty rows.
//!
//! **What this file does not claim.** It does not claim the timestamp
//! conversion of `native/QueryHelper.{h,cpp}`, whose only path is behind the
//! `TimestampQuery` feature: `CommandEncoder.cpp:2334-2336` returns before it
//! for an occlusion set, and `docs/40-plan.md` §3.3 records the row as a
//! `skip`. It does not claim when a pool may be freed either; `takePool` hands
//! that to the caller, and the serial timeline that decides it belongs to the
//! queue.

const std = @import("std");
const api = @import("../api/api.zig");
const command_query = @import("../command/query.zig");
const core = @import("../core/root.zig");
const core_errors = @import("../core/errors.zig");
const object = @import("../core/object.zig");
const vulkan = @import("vulkan");

pub const Descriptor = command_query.Descriptor;
pub const DescriptorOptions = command_query.DescriptorOptions;
pub const Error = command_query.Error;

/// Where a query set is in its life (`QuerySet.h:78`).
///
/// The state is the only lifetime guard. `ValidateCanUseInSubmitNow` reads it at
/// submit time (`QuerySet.cpp:150`), which is what catches a set destroyed
/// between `finish` and `submit` (`QueryValidationTests.cpp:167-187`).
pub const State = enum {
    /// The error object a failed `createQuerySet` left behind, and the "no
    /// query here" answer. Only that object starts here.
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

    /// Everything `create` can refuse: the descriptor rules and one arena
    /// allocation. The handle rules left with `dev.resolve`; the object this
    /// call makes is the one it attaches, so it never has to resolve one.
    pub const CreateError = Error || std.mem.Allocator.Error;

    /// `QuerySetBase`'s normal constructor (`QuerySet.cpp:81-88`) with
    /// `DeviceBase::CreateQuerySet` (`Device.cpp:2172-2178`) and
    /// `QuerySetBase::MakeError` (`:114-117`).
    ///
    /// A rejected descriptor leaves an object behind, exactly as upstream does:
    /// the caller gets the rule, and the handle it would have got names an
    /// object in the `unavailable` state. A later use of that handle is refused
    /// with `QuerySetIsError` rather than reading uninitialised bytes. This is
    /// the shape M11's `Sampler.create` already has.
    pub fn create(
        dev: *core.Device,
        descriptor: Descriptor,
        options: DescriptorOptions,
    ) CreateError!api.objects.QuerySet {
        const set = try dev.create(QuerySet, .{
            .kind = .query_set,
            .state = .initializing,
            .label = descriptor.label orelse "",
        });

        command_query.validateDescriptor(descriptor, options) catch |rule| {
            initError(set, descriptor);
            // `validateDescriptor` raises `QueryTypeUnknown`,
            // `core.RequiredFeatureMissing` and `QueryCountAboveMaximum`, and
            // all three are members of `core.ValidationError`, which is the
            // type of the field they are recorded in. `codeFromError` is what
            // carries a rule into the port's `ErrorCode`, and the two
            // `unreachable` arms are the claim that a rule about an object is
            // a validation rule: the declared set of the call above names no
            // device-lost or unrecoverable member, so it cannot raise one.
            switch (core_errors.codeFromError(rule)) {
                .validation => |code| set.header.setInitializedError(code),
                .device_lost, .unrecoverable => unreachable,
            }
            // The rejected set is tracked: `Device.deinit` is what runs its
            // teardown, and `attach` is the only call that puts it in that list.
            set.header.attach();
            return rule;
        };

        // One byte per query, bounded by `max_query_count`, and taken from the
        // device arena: there is no per-object free, so the lifetime rule is the
        // state and not a destructor (`docs/30-port-design.md` §1.1).
        const availability = try dev.arena.allocator().alloc(bool, descriptor.count);
        @memset(availability, false);

        set.query_type = descriptor.type_;
        set.query_count = descriptor.count;
        set.state = .available;
        set.availability = availability;
        set.header.setInitializedNoError();
        set.header.attach();
        return .{ .handle = @ptrCast(set) };
    }

    /// `QuerySetBase`'s error constructor (`QuerySet.cpp:90-95`): the type and
    /// the count are the only fields it writes and the availability vector stays
    /// empty, which is what makes a zero-count error set and a zero-count real
    /// set read the same way.
    fn initError(set: *QuerySet, descriptor: Descriptor) void {
        set.query_type = descriptor.type_;
        set.query_count = descriptor.count;
        set.state = .unavailable;
        set.availability = &.{};
    }

    /// `QuerySetBase::APIDestroy` (`QuerySet.cpp:154-156`).
    pub fn apiDestroy(self: *QuerySet) void {
        self.header.release();
    }

    /// The arena teardown, which is the same transition from the other side:
    /// the state is set and the pool is dropped. Upstream hands the pool to
    /// `FencedDeleter` (`QuerySetVk.cpp:95`); the port splits the step, because
    /// the timeline that decides when a pool is unused belongs to the queue.
    ///
    /// **There is nothing left to drop, because the arena owns the block.**
    /// `create` took the object from the device arena through `Device.create`
    /// (`src/core/device.zig:70`), and the one call that gives that block back
    /// is `ObjectArena.deinit` (`src/core/object.zig:405`). An
    /// `ArenaAllocator` has no per-allocation free: `ArenaAllocator.free`
    /// rewinds only when the block ends at the arena's newest byte
    /// (`lib/std/heap/ArenaAllocator.zig:620`-`:623`), and `create` allocates
    /// the availability vector after the object block, so the object block is
    /// never that byte. A `destroy(self)` here would be a no-op that reads as
    /// a release.
    //
    // `heap-leak` asks this destructor for a `destroy(self)` that cannot
    // release anything here, so the finding is suppressed on the declaration
    // below instead of answered with a call that would read as a release and
    // release nothing. The evidence that the finding is wrong:
    //
    // `create` takes the object from the device arena through `Device.create`
    // (`src/core/device.zig:70`) and `ObjectArena.create`
    // (`src/core/object.zig:354`), and the one call that gives the block back
    // is `reset(.free_all)` (`src/core/object.zig:405`). Sixty-four query sets
    // through that path, each torn down, then `Device.deinit`:
    // `std.testing.allocator`, the leak detector, reports nothing, with the
    // arena capacity above zero before the deinit so the blocks were really
    // held. An `ArenaAllocator` has no per-allocation free, and `create`
    // allocates the availability vector after the object block, so the block is
    // never the newest one and a `destroy(self)` could not rewind even if it
    // were called.
    //
    // zbc-disable-next-line: heap-leak
    pub fn destroy(self: *QuerySet, reason: object.DestroyReason) void {
        _ = reason;
        self.state = .destroyed;
        self.pool = null;
    }

    /// `QuerySetBase::GetType` (`QuerySet.cpp:119-121`). The port names the
    /// object by the handle's kind byte, so the answer is the kind itself.
    pub fn getObjectType(_: *const QuerySet) core.Handle.Kind {
        return .query_set;
    }

    /// `QuerySetBase::APIGetType` (`QuerySet.cpp:158-160`) and
    /// `GetQueryType` (`:122-124`), which are one read.
    pub fn apiGetType(self: *const QuerySet) command_query.QueryType {
        return self.query_type;
    }

    /// `QuerySetBase::APIGetCount` (`QuerySet.cpp:162-164`) and
    /// `GetQueryCount` (`:126-128`), which are one read.
    pub fn apiGetCount(self: *const QuerySet) u32 {
        return self.query_count;
    }

    /// `QuerySetBase::IsQueryAvailable` (`QuerySet.cpp:131-133`).
    pub fn isQueryAvailable(self: *const QuerySet, index: u32) bool {
        // The index is bounded by the caller: `validateResolve` runs before a
        // resolve and `beginOcclusionQuery` before a write, so an index past the
        // vector is a defect in that caller and not a rule here.
        std.debug.assert(index < self.availability.len);
        return self.availability[index];
    }

    /// `QuerySetBase::AreAllQueriesAvailable` (`QuerySet.cpp:135-142`). It
    /// short-circuits on the first unavailable index, which is the answer the
    /// walk gives and one pass cheaper.
    pub fn areAllQueriesAvailable(self: *const QuerySet, first: u32, count: u32) bool {
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
    pub fn markQueryAvailable(self: *QuerySet, index: u32) void {
        std.debug.assert(index < self.availability.len);
        self.availability[index] = true;
    }

    /// `QuerySetBase::ValidateCanUseInSubmitNow` (`QuerySet.cpp:148-152`).
    /// `Queue::ValidateCanUseInSubmitNow` runs it for every set in
    /// `usages.usedQuerySets` (`Queue.cpp:543-545`), so this is a submit-time
    /// check and not a record-time one.
    pub fn validateCanUseInSubmit(self: *const QuerySet) Error!void {
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
    target: api.objects.QuerySet,
) core.ValidationError!*QuerySet {
    const wrapped: core.Handle = .{
        .ptr = @alignCast(target.handle orelse return error.HandleKindMismatch),
        .kind = .query_set,
    };
    return dev.resolve(QuerySet, wrapped);
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
    /// has no port: `AGENTS.md` §2 deletes what nothing sets.
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
