//! `memory`: the allocator stack, from the VMA binding to one allocation
//! record.
//!
//! **What this module is.** `docs/10-architecture.md` "Module boundaries" gives
//! `memory` the VMA wrapper, the size tracker and the per-resource
//! allocations. The stack below is the shape of that: the VMA binding and the
//! alignment arithmetic at the bottom, the buddy allocator and the heap
//! allocator above them, and the allocation record at the top that names what
//! was handed out.
//!
//! **What this module does not claim.** It does not claim to know which
//! resource it is allocating for, except as an allocation record: a buffer and
//! a texture are both a size, an alignment, a memory type index and a handle,
//! and the WebGPU rule that says which one gets a dedicated allocation lives in
//! `engine` and `vk`. It holds no Vulkan handle of its own beyond what an
//! allocation carries, and it calls no Vulkan entry point directly — `vma.zig`
//! declares the VMA entry points and the loader resolves them.
//!
//! **What it does not claim either.** It does not claim the serial timeline
//! itself. `docs/10-architecture.md` gives `memory` serial reclamation, and
//! `size_tracker.zig` is how that is reached: a byte count is held until the
//! GPU reaches the serial that used it. The counter and the queue it waits on
//! are `platform`'s, and this module reads them as a parameter.
//!
//! **How to read this file.** Every sibling is re-exported under its own file
//! name, so the whole surface of a file is reachable as `memory.<file_name>`
//! and nothing here has to be kept in step when a file grows.

// --- the alignment arithmetic every allocator below needs ------------------

/// `align.zig`: the power-of-two and alignment helpers, each with its own
/// declared error set rather than a clamped value. The key is `alignment` and
/// not `align`, because `align` names a Zig primitive type and so cannot name
/// a declaration.
pub const alignment = @import("align.zig");

// --- the VMA binding --------------------------------------------------------

/// `vma.zig`: VMA's declaration half, in Zig — the pinned `vk_mem_alloc.h` types
/// and the `extern` entry points behind them.
pub const vma = @import("vma.zig");

// --- the allocators above it ------------------------------------------------

/// `buddy_allocator.zig`: a power-of-two offset tree over one region of bytes.
pub const buddy_allocator = @import("buddy_allocator.zig");
/// `resource_heap.zig`: one memory heap and the size it holds.
pub const resource_heap = @import("resource_heap.zig");
/// `resource_heap_allocator.zig`: the allocator that sub-allocates out of
/// heaps through a vtable, so a test can drive it with heaps of its own.
pub const resource_heap_allocator = @import("resource_heap_allocator.zig");

// --- what was handed out ----------------------------------------------------

/// `resource_memory_allocation.zig`: one allocation record, its info and the
/// method it was made by.
pub const resource_memory_allocation = @import("resource_memory_allocation.zig");
/// `size_tracker.zig`: a byte count that is only released when the GPU reaches
/// the serial that used it, which is the serial reclamation this module owns.
pub const size_tracker = @import("size_tracker.zig");
