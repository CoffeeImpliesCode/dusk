//! The front end of a query: the rules a descriptor, a pass and a resolve each
//! break.
//!
//! **What this file is.** The half of milestone M19 that holds no Vulkan. It
//! carries the descriptor rules (`QuerySet.cpp:50-72`), the render-pass
//! occlusion rules (`RenderPassEncoder.cpp:56-64`, `:174-177`, `:437-503`) and
//! the resolve rules (`CommandEncoder.cpp:1091-1119`, `:2302-2354`). The
//! object, the Vulkan pool and the copy are `src/engine/query_set.zig` and
//! `src/engine/vulkan_query_set.zig`, which import this file; nothing here
//! imports either of those.
//!
//! **What this file does not claim.** It does not claim the Vulkan replay. It
//! does not claim the timestamp conversion of `native/QueryHelper.{h,cpp}`:
//! `CommandEncoder.cpp:2334-2336` returns before that path for an occlusion
//! set, and `docs/40-plan.md` §3.3 carries the row as a `skip` with that
//! reason.
//!
//! **Where the rules live.** Dawn puts `ValidateQuerySetDescriptor` in
//! `native/QuerySet.cpp`, which is engine-side. The port puts it here because a
//! rule is a front-end rule and `AGENTS.md` §3 asks that the whole front end be
//! drivable with no device. `docs/40-plan.md` §3.3 records the move.

const std = @import("std");
const api = @import("../api/api.zig");
const core = @import("../core/root.zig");
const constants = @import("constants.zig");
const errors = @import("errors.zig");

/// What a query set counts. `dawn.json` declares the enum once and
/// `src/api/enums.zig` emits it from that one declaration, so this is the
/// generated type rather than a second copy of it: upstream's own field is
/// the generated `wgpu::QueryType` (`QuerySet.h:75`) and its two accessors
/// return that (`QuerySet.h:50`, `:61`).
pub const QueryType = api.enums.QueryType;

/// Everything a query call can fail with.
///
/// The descriptor rules are members of `core.ValidationError` and not of this
/// set, because they are about the object the call makes and not about a
/// recorded command, and `QuerySet.create` records one of them in that
/// object's `last_error`, whose type is `core.ValidationError`. Of the three,
/// `core.RequiredFeatureMissing` was always one: the timestamp rule at
/// `QuerySet.cpp:64-66` is a missing feature and `core` owns that wording.
pub const Error = errors.Error;

pub const Descriptor = api.descriptors.QuerySetDescriptorChain;

/// One query's slot in a resolve destination. `QuerySet.h:42` writes the number
/// once and the resolve stride is the only place that reads it.
pub const single_query_storage_size: u64 = 8;

/// `kMaxQueryCount` at `src/dawn/common/Constants.h:94`. It is a rule and not a
/// device limit, so it is named here rather than read from a limits table.
pub const max_query_count: u32 = 4096;

/// The alignment a resolve destination offset obeys. M15 owns the number
/// (`constants.query_resolve_alignment`); M19 is the first reader.
pub const query_resolve_alignment: u64 = constants.query_resolve_alignment;

/// The bytes `count` queries occupy in a resolve destination
/// (`ToQueryStorageSize`, `QuerySet.cpp:77-79`).
///
/// Dawn returns a `uint32_t`. The port widens to `u64` because the caller adds
/// `destinationOffset` before comparing against the destination size
/// (`CommandEncoder.cpp:1113-1117`), and a 32-bit sum wraps on a buffer larger
/// than four gigabytes. `count` is bounded by `max_query_count` before this
/// runs, so the product itself cannot overflow.
pub fn queryStorageSize(count: u32) u64 {
    return @as(u64, count) * single_query_storage_size;
}

/// What `validateDescriptor` needs to know about the device.
pub const DescriptorOptions = struct {
    /// Dawn asks the device for `Feature::TimestampQuery` or the Chromium
    /// feature (`QuerySet.cpp:64-66`). `command` cannot read a device
    /// (`docs/10-architecture.md`, "Module boundaries"), so the caller states
    /// the answer and the rule stays the rule.
    timestamp_query_enabled: bool = false,
};

/// `ValidateQuerySetDescriptor` (`QuerySet.cpp:50-72`).
///
/// The declared set is `core.ValidationError`, which is the shape
/// `validateSamplerDescriptor` and `validateTextureDescriptor` have: every
/// rule this function raises is about the object the call makes, so the
/// caller that records one in that object's `last_error` reaches the field
/// without narrowing the caught rule first. `docs/40-plan.md` §3.3 records
/// the move of the function out of the engine side, and this is the half of
/// that move the error set shows.
///
/// One upstream rule does not become a member of any set, and the same row
/// records it: the `nextInChain` test at `QuerySet.cpp:51` cannot fire,
/// because `dawn.json` lists no chained struct for `query set descriptor` at
/// this revision and `docs/30-port-design.md` §4.2 makes the extension
/// unrepresentable.
pub fn validateDescriptor(
    descriptor: Descriptor,
    options: DescriptorOptions,
) core.ValidationError!void {
    // `std.enums.fromInt` answers with an optional, not an error union, because
    // the only failure is "the value names no tag".
    const tag = std.enums.fromInt(QueryType, @intFromEnum(descriptor.type_)) orelse
        return error.QueryTypeUnknown;
    switch (tag) {
        .occlusion => {},
        .timestamp => if (!options.timestamp_query_enabled) {
            return error.RequiredFeatureMissing;
        },
    }

    if (descriptor.count > max_query_count) return error.QueryCountAboveMaximum;
}

/// What one resolve names. The two index fields are
/// `api.CommandEncoder.ResolveQuerySetFirstQueryOptions`
/// (`src/api/objects.zig:232-234`), brought together with the destination offset
/// because the three travel together through every rule.
pub const ResolveParams = struct {
    first_query: u32,
    query_count: u32,
    destination_offset: u64,
};

/// What the destination is. `command` cannot read a buffer
/// (`docs/10-architecture.md`, "Module boundaries"), so the caller resolves
/// the two values the rules read, the same way `constants.Limits` reaches a
/// limit.
pub const DestinationParams = struct {
    size: u64,
    usage: api.bitmask.BufferUsage,
};

/// The usage a resolve destination must carry.
pub const resolve_usage: api.bitmask.BufferUsage = .{ .query_resolve = true };

/// `ValidateQuerySetResolve` (`CommandEncoder.cpp:1091-1119`) followed by the
/// usage rule of `APIResolveQuerySet` (`CommandEncoder.cpp:2320`).
///
/// The second rule is written as a subtraction because that is how upstream
/// writes it (`CommandEncoder.cpp:1100-1104`): `first_query + query_count`
/// wraps on a large `first_query` and would accept a range the set does not
/// hold.
pub fn validateResolve(
    query_count_of_set: u32,
    params: ResolveParams,
    destination: DestinationParams,
) Error!void {
    if (params.first_query >= query_count_of_set) return error.ResolveFirstQueryAboveCount;
    if (params.query_count > query_count_of_set - params.first_query) {
        return error.ResolveQueryCountAboveRemaining;
    }
    if (params.destination_offset % query_resolve_alignment != 0) {
        return error.ResolveDestinationOffsetUnaligned;
    }

    // The span is measured from the offset to the end of the buffer, which is
    // what `CommandEncoder.cpp:1113-1117` does. Testing the offset alone would
    // accept a resolve at the tail of a buffer with no room for the range.
    const span = queryStorageSize(params.query_count);
    if (params.destination_offset > destination.size) return error.ResolveDestinationTooSmall;
    if (span > destination.size - params.destination_offset) {
        return error.ResolveDestinationTooSmall;
    }

    if (!destination.usage.has(resolve_usage)) return error.ResolveDestinationUsageMissing;
}

/// What one open render pass remembers about its occlusion query.
///
/// Upstream spreads this over the render-pass encoder
/// (`RenderPassEncoder.cpp:437-503`) and a per-pass availability map
/// (`PassResourceUsageTracker.cpp:348-358`). M15 landed the map as
/// `usage.RenderPassResourceUsageTracker`; this is the other half, and it holds
/// no availability of its own so the two cannot drift.
pub const OcclusionQueryState = struct {
    /// Whether the pass carries an `occlusion_query_set`. A pass without one is
    /// a `beginOcclusionQuery` the port rejects, so the flag and not a null
    /// handle is what the rule reads.
    attached: bool,
    /// The number of queries the attached set holds.
    query_count: u32,
    /// Whether an occlusion query is open.
    active: bool,
    /// The index the open query writes. Read only while `active`, which is what
    /// makes a zero here mean nothing rather than index zero.
    index: u32,

    pub const InitOptions = struct {
        /// Whether the pass carries an `occlusion_query_set`, and its count
        /// when it does. `CommandEncoder.cpp:983-990` is where upstream rejects
        /// a timestamp set in that slot, and it runs before any pass object
        /// exists, so the port takes the answer at construction instead.
        attached: bool,
        query_type: QueryType = .occlusion,
        query_count: u32 = 0,
    };

    pub fn init(options: InitOptions) Error!OcclusionQueryState {
        if (options.attached and options.query_type != .occlusion) {
            return error.QuerySetTypeMismatch;
        }
        return .{
            .attached = options.attached,
            .query_count = options.query_count,
            .active = false,
            .index = 0,
        };
    }

    /// `APIBeginOcclusionQuery` (`RenderPassEncoder.cpp:437-477`) with
    /// `ValidateQueryIndexOverwrite` (`:56-64`).
    ///
    /// `already_tracked` is what the caller's per-pass availability map holds
    /// for this index. It is a parameter and not a field because the map is
    /// M15's, and a second copy of it here would be a second convention.
    ///
    /// The index is not marked here. Upstream marks at `EndOcclusionQuery`
    /// (`:490-492`), and a begin that is never ended must keep the index out of
    /// the reset list.
    pub fn beginOcclusionQuery(self: *OcclusionQueryState, query_index: u32, already_tracked: bool) Error!void {
        if (!self.attached) return error.OcclusionQuerySetAbsent;
        if (query_index >= self.query_count) return error.QueryIndexAboveCount;
        if (self.active) return error.OcclusionQueryAlreadyActive;
        if (already_tracked) return error.QueryIndexOverwritten;

        self.active = true;
        self.index = query_index;
    }

    /// `APIEndOcclusionQuery` (`RenderPassEncoder.cpp:479-503`). It takes no
    /// index because it replays the one `beginOcclusionQuery` remembered
    /// (`:498-500`). The caller marks the index in its availability map.
    pub fn endOcclusionQuery(self: *OcclusionQueryState) Error!u32 {
        if (!self.active) return error.OcclusionQueryNotActive;
        self.active = false;
        return self.index;
    }

    /// `RenderPassEncoder::End` (`RenderPassEncoder.cpp:157-177`). Ending a pass
    /// with an open query leaves the Vulkan pool holding a query that never
    /// closed, so the rule is on the pass and not on the end.
    pub fn end(self: *const OcclusionQueryState) Error!void {
        if (self.active) return error.OcclusionQueryUnterminated;
    }
};
