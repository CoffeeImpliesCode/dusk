//! The descriptor-set allocator: pools of pre-allocated sets, freed by GPU
//! serial.
//!
//! **What this file is.** The port of `vulkan/DescriptorSetAllocator.{h,cpp}`
//! and `vulkan/DescriptorSetAllocation.h` at Dawn
//! `32f77c02294310054a660c393feded4bcb3f203c`.
//!
//! **Why pools of sets, and not a pool per set.** The Vulkan specification
//! guarantees only bump-plus-rollback for a descriptor pool, and freeing one
//! set from a pool resets the whole pool. Dawn therefore allocates a batch of
//! sets from one pool and sub-allocates them itself
//! (`DescriptorSetAllocator.h:48`-`:64`). Every set in one allocator was
//! allocated against the single `VkDescriptorSetLayout` the allocator was built
//! with, which is why the allocator belongs to one layout and is never shared
//! across two.
//!
//! **Why a set is not reusable at once.** `vkCmdBindDescriptorSets` lets a
//! driver consume the set any time between the host execution of the command
//! and the end of the draw (`DescriptorSetAllocator.cpp:125`-`:129`), so a
//! freed set may still be read by the GPU. The port therefore queues a
//! deallocation against the queue's pending serial and returns the set only
//! when the timeline reports that serial completed — Dawn's
//! `FinishDeallocation` (`:150`-`:163`), driven from `Device::TickImpl`
//! (`vulkan/DeviceVk.cpp:373`).
//!
//! **What this file does not claim.** It does not claim the descriptor write,
//! which is `bind_group_vk.zig`, or the
//! `VK_DESCRIPTOR_SET_LAYOUT_UPDATE_AFTER_BIND` bindless pool, which is the
//! resource table.

const std = @import("std");
const vulkan = @import("vulkan");
const vk = @import("../vk/dispatch.zig");
const errors = @import("../core/errors.zig");
const serial = @import("../platform/serial.zig");

/// `kMaxDescriptorsPerPool` (`DescriptorSetAllocator.cpp:45`). The target a
/// pool is sized to, and the divisor in the `mMaxSets` computation at `:73`.
pub const max_descriptors_per_pool: u32 = 512;

/// The three fields Dawn keeps. `DescriptorSetAllocation`
/// (`DescriptorSetAllocation.h:36`-`:40`), and the whole ownership token a bind
/// group needs to give a set back.
pub const DescriptorSetAllocation = struct {
    set: vulkan.VkDescriptorSet = null,
    pool_index: u32 = 0,
    set_index: u16 = 0,
};

/// One `VkDescriptorPool` and the sets cut from it. `DescriptorPool`
/// (`DescriptorSetAllocator.h:93`-`:97`).
const Pool = struct {
    pool: vulkan.VkDescriptorPool = null,
    sets: std.ArrayList(vulkan.VkDescriptorSet) = .empty,
    /// A LIFO free list, which is why `allocate` reads the back
    /// (`DescriptorSetAllocator.cpp:106`-`:107`).
    free_set_indices: std.ArrayList(u16) = .empty,
    /// Dawn's `std::vector<VkDescriptorSetLayout> layouts(mMaxSets, dsLayout)`
    /// (`DescriptorSetAllocator.cpp:179`), which the allocate call reads as
    /// `descriptorSetCount` consecutive pointers (`:185`-`:186`). Handing it the
    /// address of ONE layout instead makes the driver read past it, so the
    /// array is owned here rather than borrowed.
    layouts: std.ArrayList(vulkan.VkDescriptorSetLayout) = .empty,
};

/// One queued deallocation. `Deallocation`
/// (`DescriptorSetAllocator.h:102`-`:105`).
const Deallocation = struct {
    pool_index: u32,
    set_index: u16,
};

/// What `deallocate` can return, and nothing else.
///
/// The queue's own set leads because `enqueueMonotonic`
/// (`src/platform/serial.zig:109`) refuses a serial below the last one
/// enqueued, and it already carries the allocation failure. The two members
/// under it are this port's replacements for Dawn's asserts.
pub const DeallocateError = serial.SerialQueue(Deallocation).EnqueueError || error{
    /// The caller gave a set back twice, so `allocation.set` is already
    /// null. Dawn asserts the same at `DescriptorSetAllocator.cpp:123`.
    InternalInvariantViolated,

    /// A deallocation names a pool this allocator does not own. Dawn
    /// asserts the same at `DescriptorSetAllocator.cpp:154`; the port
    /// checks it when the set goes back rather than when it comes back.
    DeallocationOutOfRange,
};

/// What the allocator's surface can report. `deallocate` brings its own set
/// in whole, so a caller that merges this file rather than listing its calls
/// still sees the queue's order check.
pub const Error = errors.UnrecoverableError || std.mem.Allocator.Error ||
    vk.Error || vk.LoadError || DeallocateError || error{
    /// The allocator was built with no per-type descriptor count, or with a
    /// count of zero. Dawn asserts the second at
    /// `DescriptorSetAllocator.cpp:62` before it divides.
    PoolSizeCountZero,
};

pub const DescriptorSetAllocator = struct {
    allocator: std.mem.Allocator,
    procs: *const vk.DeviceProcs,
    device: vulkan.VkDevice,
    /// Every set this allocator hands out was allocated against this layout.
    /// `DescriptorSetAllocator.h:70`-`:74` forbids sharing an allocator across
    /// layouts that differ.
    set_layout: vulkan.VkDescriptorSetLayout,
    /// The per-type counts of a whole pool, so already multiplied by
    /// `max_sets_per_pool`.
    pool_sizes: []vulkan.VkDescriptorPoolSize,
    /// `mMaxSets` (`DescriptorSetAllocator.cpp:73`): how many sets one pool
    /// holds.
    max_sets_per_pool: u32,
    pools: std.ArrayList(Pool) = .empty,
    /// `mAvailableDescriptorPoolIndices`. A pool is listed only while it has
    /// a free set (`DescriptorSetAllocator.cpp:109`-`:111`).
    available_pool_indices: std.ArrayList(u32) = .empty,
    /// `mPendingDeallocations` (`DescriptorSetAllocator.h:106`).
    pending_deallocations: serial.SerialQueue(Deallocation),

    /// Builds one allocator. Ports
    /// `DescriptorSetAllocator::DescriptorSetAllocator`
    /// (`DescriptorSetAllocator.cpp:54`-`:80`).
    ///
    /// `descriptor_count_per_type` is Dawn's `descriptorCountPerType` from
    /// `ComputeVulkanStaticBindings` (`BindGroupLayoutVk.cpp:56`), one entry per
    /// `VkDescriptorType` the layout uses. Every count must be above zero,
    /// which is Dawn's `DAWN_CHECK(count > 0)` at `DescriptorSetAllocator.cpp:62`.
    pub fn init(
        allocator: std.mem.Allocator,
        procs: *const vk.DeviceProcs,
        device: vulkan.VkDevice,
        set_layout: vulkan.VkDescriptorSetLayout,
        descriptor_count_per_type: []const vulkan.VkDescriptorPoolSize,
    ) Error!DescriptorSetAllocator {
        if (descriptor_count_per_type.len == 0) return error.PoolSizeCountZero;

        // Bound: one entry per descriptor type the caller named.
        const pool_sizes = try allocator.alloc(
            vulkan.VkDescriptorPoolSize,
            descriptor_count_per_type.len,
        );
        errdefer allocator.free(pool_sizes);

        var total_descriptor_count: u32 = 0;
        for (descriptor_count_per_type, pool_sizes) |source, *target| {
            if (source.descriptorCount == 0) return error.PoolSizeCountZero;
            total_descriptor_count += source.descriptorCount;
            target.* = source;
        }

        // Dawn floors the total at one so the division below cannot be by zero
        // (`DescriptorSetAllocator.cpp:67`-`:68`).
        total_descriptor_count = @max(1, total_descriptor_count);

        // A binding no visible stage can use can ask for a huge set, so Dawn
        // floors the result at one set per pool (`DescriptorSetAllocator.cpp:72`-`:73`).
        const max_sets_per_pool = @max(
            max_descriptors_per_pool / total_descriptor_count,
            1,
        );

        // Every pool is sized for a whole batch, which is what makes one pool
        // worth creating (`DescriptorSetAllocator.cpp:77`-`:79`).
        for (pool_sizes) |*pool_size| {
            pool_size.descriptorCount *= max_sets_per_pool;
        }

        return .{
            .allocator = allocator,
            .procs = procs,
            .device = device,
            .set_layout = set_layout,
            .pool_sizes = pool_sizes,
            .max_sets_per_pool = max_sets_per_pool,
            .pending_deallocations = .{},
        };
    }

    /// Releases every pool. Dawn hands the pools to a fenced deleter
    /// (`DescriptorSetAllocator.cpp:82`-`:89`) because a pool may still be read
    /// by the GPU; the port destroys them here and leaves the fence to the
    /// caller that owns the device, because this allocator has no path to it.
    ///
    /// The destroy proc is resolved before the first pool is released, so a
    /// loader that missed it still frees the host memory and then reports,
    /// instead of leaving the pools half torn down. The refusal is typed.
    pub fn deinit(self: *DescriptorSetAllocator) Error!void {
        const destroy_pool = self.procs.destroy_descriptor_pool orelse null;
        const pool_count = self.pools.items.len;
        var pool_index: usize = 0;
        while (pool_index < pool_count) : (pool_index += 1) {
            var pool = &self.pools.items[pool_index];
            pool.sets.deinit(self.allocator);
            pool.free_set_indices.deinit(self.allocator);
            pool.layouts.deinit(self.allocator);
            if (pool.pool != null) {
                if (destroy_pool) |destroy| destroy(self.device, pool.pool, null);
            }
            pool.* = undefined;
        }
        self.pools.deinit(self.allocator);
        self.available_pool_indices.deinit(self.allocator);
        self.pending_deallocations.deinit(self.allocator);
        self.allocator.free(self.pool_sizes);
        self.* = undefined;
        if (destroy_pool == null) return error.MissingDeviceProc;
    }

    /// Takes one set. Ports `DescriptorSetAllocator::Allocate`
    /// (`DescriptorSetAllocator.cpp:91`-`:114`) with
    /// `AllocateDescriptorPool` (`:165`-`:221`).
    pub fn allocate(self: *DescriptorSetAllocator) Error!DescriptorSetAllocation {
        if (self.available_pool_indices.items.len == 0) {
            try self.allocateDescriptorPool();
        }
        // The pool list holds at least the pool just cut:
        // `allocateDescriptorPool` ends in the `append` that publishes it
        // (`DescriptorSetAllocator.cpp:216`), so an empty list here means the
        // allocator was handed over half-built. Refusing names the defect; the
        // read below would underflow and trap with no word about which half is
        // missing.
        if (self.available_pool_indices.items.len == 0) return error.InternalInvariantViolated;
        const pool_index = self.available_pool_indices.items[
            self.available_pool_indices.items.len - 1
        ];
        const pool = &self.pools.items[pool_index];
        if (pool.free_set_indices.items.len == 0) return error.InternalInvariantViolated;

        const set_index = pool.free_set_indices.items[pool.free_set_indices.items.len - 1];
        _ = pool.free_set_indices.pop();
        if (pool.free_set_indices.items.len == 0) {
            _ = self.available_pool_indices.pop();
        }
        return .{
            .set = pool.sets.items[set_index],
            .pool_index = pool_index,
            .set_index = set_index,
        };
    }

    /// Gives one set back at the serial the queue is submitting at. Ports
    /// `DescriptorSetAllocator::Deallocate` (`:116`-`:148`).
    ///
    /// `allocation` is cleared, so a bind group that outlives its deallocation
    /// reads a null set rather than a recycled one
    /// (`DescriptorSetAllocator.cpp:140`).
    pub fn deallocate(
        self: *DescriptorSetAllocator,
        allocation: *DescriptorSetAllocation,
        pending_serial: serial.Serial,
    ) DeallocateError!void {
        if (allocation.set == null) return error.InternalInvariantViolated;
        if (allocation.pool_index >= self.pools.items.len) return error.DeallocationOutOfRange;

        try self.pending_deallocations.enqueueMonotonic(self.allocator, .{
            .serial = pending_serial,
            .value = .{
                .pool_index = allocation.pool_index,
                .set_index = allocation.set_index,
            },
        });
        allocation.* = .{};
    }

    /// Returns every set the GPU has finished with. Ports
    /// `FinishDeallocation` (`DescriptorSetAllocator.cpp:150`-`:163`), which the
    /// device's tick calls with the completed serial
    /// (`vulkan/DeviceVk.cpp:373`).
    pub fn finishDeallocation(
        self: *DescriptorSetAllocator,
        completed_serial: serial.Serial,
    ) std.mem.Allocator.Error!void {
        var drained = std.ArrayList(serial.SerialQueue(Deallocation).Entry).empty;
        defer drained.deinit(self.allocator);

        try self.pending_deallocations.drainUpToInSubmissionOrder(
            self.allocator,
            completed_serial,
            &drained,
        );

        // Bound: the entries the queue handed back.
        const drained_count = drained.items.len;
        var drained_index: usize = 0;
        while (drained_index < drained_count) : (drained_index += 1) {
            const deallocation = drained.items[drained_index].value;
            if (deallocation.pool_index >= self.pools.items.len) continue;
            const pool = &self.pools.items[deallocation.pool_index];
            if (pool.free_set_indices.items.len == 0) {
                try self.available_pool_indices.append(self.allocator, deallocation.pool_index);
            }
            try pool.free_set_indices.append(self.allocator, deallocation.set_index);
        }
    }

    /// How many pools the allocator holds, which is what a test asserts after a
    /// round of allocations.
    pub fn queryPoolCount(self: *const DescriptorSetAllocator) u32 {
        return @intCast(self.pools.items.len);
    }

    /// How many sets a fresh pool holds.
    pub fn queryMaxSetsPerPool(self: *const DescriptorSetAllocator) u32 {
        return self.max_sets_per_pool;
    }

    /// Cuts one pool holding a whole batch of sets.
    /// `AllocateDescriptorPool` (`DescriptorSetAllocator.cpp:165`-`:221`).
    fn allocateDescriptorPool(self: *DescriptorSetAllocator) Error!void {
        const create_info: vulkan.VkDescriptorPoolCreateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = self.max_sets_per_pool,
            .poolSizeCount = @intCast(self.pool_sizes.len),
            .pPoolSizes = self.pool_sizes.ptr,
        };
        // Both procs are resolved before the pool is created, so a loader that
        // missed either one leaves no half-built pool behind.
        const create_pool = self.procs.create_descriptor_pool orelse
            return error.MissingDeviceProc;
        const destroy_pool = self.procs.destroy_descriptor_pool orelse
            return error.MissingDeviceProc;
        var pool_handle: vulkan.VkDescriptorPool = null;
        try vk.checkVkOomThenSuccess(create_pool(
            self.device,
            &create_info,
            null,
            &pool_handle,
        ));
        errdefer destroy_pool(self.device, pool_handle, null);

        // Dawn allocates every set of the pool up front
        // (`DescriptorSetAllocator.cpp:188`-`:192`), because the specification
        // offers no way to grow a pool afterwards.
        const set_count = self.max_sets_per_pool;
        var pool: Pool = .{ .pool = pool_handle };
        errdefer pool.sets.deinit(self.allocator);
        errdefer pool.free_set_indices.deinit(self.allocator);
        errdefer pool.layouts.deinit(self.allocator);

        // `DescriptorSetAllocator.cpp:179` builds this array before the
        // allocate call, and `:186` points at it. The allocate call reads
        // `descriptorSetCount` consecutive pointers from it, so handing over
        // the address of one layout reads past the end.
        try pool.layouts.ensureTotalCapacity(self.allocator, set_count);
        pool.layouts.appendNTimesAssumeCapacity(self.set_layout, set_count);

        try pool.sets.ensureTotalCapacity(self.allocator, set_count);
        const allocate_info: vulkan.VkDescriptorSetAllocateInfo = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = pool_handle,
            .descriptorSetCount = set_count,
            .pSetLayouts = pool.layouts.items.ptr,
        };
        // `std.ArrayList` is the unmanaged list in Zig 0.16
        // (`lib/std/std.zig:49`), so a method that cannot allocate takes no
        // allocator: the capacity was ensured above, so this one takes
        // `(value, n)` and returns nothing.
        pool.sets.appendNTimesAssumeCapacity(null, set_count);
        const allocate_sets = self.procs.allocate_descriptor_sets orelse
            return error.MissingDeviceProc;
        try vk.checkVkOomThenSuccess(allocate_sets(
            self.device,
            &allocate_info,
            pool.sets.items.ptr,
        ));

        // Dawn pushes the free indices in ascending order
        // (`DescriptorSetAllocator.cpp:212`-`:214`), so its first `Allocate`
        // takes the highest set. This port fills from the top, so the first
        // `Allocate` takes set zero.
        try pool.free_set_indices.ensureTotalCapacity(self.allocator, set_count);
        var set_index: u32 = set_count;
        while (set_index > 0) : (set_index -= 1) {
            pool.free_set_indices.appendAssumeCapacity(@intCast(set_index - 1));
        }

        const pool_index: u32 = @intCast(self.pools.items.len);
        try self.pools.append(self.allocator, pool);
        errdefer _ = self.pools.pop();
        try self.available_pool_indices.append(self.allocator, pool_index);
    }
};
