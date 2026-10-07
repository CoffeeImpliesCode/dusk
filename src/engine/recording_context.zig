//! The per-submit state the replay writes into.
//!
//! **What this file is.** `vulkan/CommandRecordingContextVk.{h,cpp}` upstream:
//! 102 lines and 58 lines, 2 rows (`docs/40-plan.md` §M18). The context is the
//! one object that outlives a single Vulkan call and is shared by every command
//! buffer in one submit, which is why upstream holds a queue, a command pool
//! and a semaphore list in it.
//!
//! **What this file does not carry.** The pool, the command-buffer list and the
//! semaphore list. `src/engine/queue.zig` is M9's and owns all three: it
//! creates the pool and the primary command buffer (`QueueVk.cpp:202-296`),
//! builds `VkSubmitInfo` from the list (`:325-338`) and submits (`:349`). The
//! port's context therefore carries only what the replay itself owns: the
//! command buffer the replay writes into, the eager-transition set, and the two
//! flags the replay reads.
//!
//! **What the two rows are.** `checkBufferNeedsEagerTransition` decides whether
//! a buffer has to move out of its mappable layout before this submit uses it
//! for anything else, and `emitBufferBarrierIfNecessary` is the one
//! `vkCmdPipelineBarrier` that carries the answer. `buffer.zig` carries its own
//! copy of this row for a buffer's own usage transition
//! (`src/engine/buffer.zig:1043-1063`).

const std = @import("std");
const vulkan = @import("vulkan");
const api = @import("../api/api.zig");
const dispatch = @import("../vk/dispatch.zig");

pub const BufferUsage = api.bitmask.BufferUsage;

/// `kMappableBufferUsages` (`native/Buffer.h:63-64`): the two usages that
/// require a host-visible, persistently mapped allocation.
pub const k_mappable_buffer_usages: BufferUsage = .{ .map_read = true, .map_write = true };

/// The stages a barrier may name. `AGENTS.md` §2 wants the unit in the name;
/// Vulkan spells the mask `VkPipelineStageFlags`, so the port names the mask
/// and not the stage.
pub const StageFlags = vulkan.VkPipelineStageFlags;

/// The accesses a barrier may name, for the same reason.
pub const AccessFlags = vulkan.VkAccessFlags;

/// `BufferBarrier` as the replay reads it. Dawn's `BufferBarrier`
/// (`native/ResourceUsage.h`) answers four questions; this is them, and
/// `isEmpty` is the one that decides whether a barrier is emitted at all.
pub const BufferBarrier = struct {
    src_stage_mask: StageFlags = 0,
    dst_stage_mask: StageFlags = 0,
    src_access_mask: AccessFlags = 0,
    dst_access_mask: AccessFlags = 0,

    /// `BufferBarrier::IsEmpty`
    pub fn isEmpty(self: BufferBarrier) bool {
        return self.src_stage_mask == 0 and self.dst_stage_mask == 0 and
            self.src_access_mask == 0 and self.dst_access_mask == 0;
    }
};

/// An object a recorded command names, as one pointer type. The tag fixes the
/// pointee; the replay casts on the tag branch. `command.Ref` is M15's and this
/// is the same `?*anyopaque`, so a `Ref` crosses the module boundary without
/// a conversion.
pub const Ref = ?*anyopaque;

/// `CommandRecordingContext` (`CommandRecordingContextVk.h:50-100`), the parts
/// the replay owns.
pub const CommandRecordingContext = struct {
    allocator: std.mem.Allocator,

    /// The command buffer every `vkCmd*` of this submit goes into
    /// (`CommandRecordingContextVk.h:55`). M9's queue creates it and owns it;
    /// the replay only writes to it.
    command_buffer: vulkan.VkCommandBuffer = null,
    active_render_pass: ?vulkan.VkRenderPass = null,

    /// `mappableBuffersForEagerTransition` (`:75`): buffers whose layout must
    /// move before the submit and back after it.
    ///
    /// A buffer lands here when the usage this submit records is not mappable
    /// and the buffer's own internal usage is. `docs/10-architecture.md` says
    /// every handle is a pointer into the device arena, so the set holds the
    /// arena pointer and never a copy.
    // Zig 0.16 dropped the load-percentage parameter from
    // `std.AutoArrayHashMapUnmanaged`, which now takes the key and the value
    // only and supplies `std.array_hash_map.AutoContext`. The key is a pointer,
    // which the auto strategy hashes and compares by value.
    mappable_buffers_for_eager_transition: std.AutoArrayHashMapUnmanaged(
        Ref,
        void,
    ) = .empty,

    /// `hasRecordedRenderPass` (`:91`). Read by the query-set reset, which must
    /// be emitted outside a pass (`CommandBufferVk.cpp:568-571`).
    has_recorded_render_pass: bool = false,

    /// `needsSubmit` (`:79`): the submit has at least one command in it.
    needs_submit: bool = false,

    pub fn init(allocator: std.mem.Allocator) CommandRecordingContext {
        return .{ .allocator = allocator };
    }

    /// Releases what the context owns. The command buffer belongs to M9's pool
    /// and is not touched.
    pub fn deinit(self: *CommandRecordingContext) void {
        self.mappable_buffers_for_eager_transition.deinit(self.allocator);
        // The context is gone and nothing reads the value again, so the receiver
        // is poisoned rather than half reset.
        self.* = undefined;
    }

    /// `CommandRecordingContext::CheckBufferNeedsEagerTransition`
    /// (`CommandRecordingContextVk.cpp:35-40`).
    ///
    /// True when the buffer's internal usage is mappable and the usage this
    /// submit records is not: the buffer must move to a non-mappable layout for
    /// the duration of the submit. The same answer inserts the buffer into the
    /// set, so a caller cannot record the transition and forget the way back.
    pub fn checkBufferNeedsEagerTransition(
        self: *CommandRecordingContext,
        buffer: Ref,
        internal_usage: BufferUsage,
        recorded_usage: BufferUsage,
    ) std.mem.Allocator.Error!bool {
        const mappable_internal =
            internal_usage.toFlags() & k_mappable_buffer_usages.toFlags() != 0;
        const mappable_recorded =
            recorded_usage.toFlags() & k_mappable_buffer_usages.toFlags() != 0;
        const needed = mappable_internal and !mappable_recorded;
        if (!needed) return false;

        try self.mappable_buffers_for_eager_transition.put(self.allocator, buffer, {});
        return true;
    }

    /// Whether a buffer is in the eager-transition set.
    pub fn isEagerTransitionQueued(self: *const CommandRecordingContext, buffer: Ref) bool {
        return self.mappable_buffers_for_eager_transition.contains(buffer);
    }
};

/// `CommandRecordingContext::EmitBufferBarrierIfNecessary`
/// (`CommandRecordingContextVk.cpp:42-56`).
///
/// One `vkCmdPipelineBarrier` with a single zero-initialised `VkMemoryBarrier`,
/// no buffer barrier and no image barrier. The empty case returns without a
/// call, which is the difference between a submit that emits zero barriers and
/// one that emits one doing nothing.
pub fn emitBufferBarrierIfNecessary(
    device: Device,
    command_buffer: vulkan.VkCommandBuffer,
    barrier: BufferBarrier,
) void {
    if (barrier.isEmpty()) return;

    const cmd_pipeline_barrier = device.procs.cmd_pipeline_barrier orelse unreachable;
    const memory_barrier: vulkan.VkMemoryBarrier = .{
        // `VkStructureType` is `c_uint` in this translation of the header
        // (`src/vulkan.zig:2420`), not an enumeration, so the constant is cast
        // rather than converted with `@enumFromInt`.
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_MEMORY_BARRIER),
        .pNext = null,
        .srcAccessMask = barrier.src_access_mask,
        .dstAccessMask = barrier.dst_access_mask,
    };
    // `vkCmdPipelineBarrier` takes no device handle (`src/vulkan.zig:5268`),
    // and it orders the three barrier kinds memory, buffer, image rather than
    // taking the barrier last. Passing one memory barrier means the count
    // goes with `pMemoryBarriers` and the buffer and image pairs stay empty.
    cmd_pipeline_barrier(
        command_buffer,
        barrier.src_stage_mask,
        barrier.dst_stage_mask,
        0,
        1,
        &memory_barrier,
        0,
        null,
        0,
        null,
    );
}

/// The device tier of the dispatch table plus the handle. `queue.Context`
/// (`src/engine/queue.zig`) carries both, and naming them separately here is
/// what lets a unit test call this function with a recording procs table and no
/// device.
pub const Device = struct {
    procs: *const dispatch.DeviceProcs,
    vk_device: vulkan.VkDevice,
};

comptime {
    // The set is a hash set of arena pointers, and `?*anyopaque` is the one
    // pointer type the port hands across a module boundary. A set of a
    // concrete backend type here would make the context unreachable from a test
    // that has no backend.
    if (@sizeOf(Ref) != @sizeOf(usize)) {
        @compileError("Ref stopped being one machine word");
    }
    // `kMappableBufferUsages` is exactly the two map usages upstream
    // (`native/Buffer.h:63-64`); a third bit would make a storage buffer
    // eagerly transition for no reason.
    if (k_mappable_buffer_usages.toFlags() !=
        (1 << 0) | (1 << 1)) @compileError("the mappable usages moved");
}
