//! `FramebufferCache`: 32 `VkFramebuffer`s, keyed on the pass and the views.
//!
//! **What this file is.** `vulkan/FramebufferCache.{h,cpp}` upstream: 114 lines
//! and 120 lines, 7 rows (`docs/40-plan.md` §M18). The key is the render pass's
//! `unique_id` — never the `VkRenderPass`, because a handle may be reused
//! (`FramebufferCache.h:68-69`) — the pass size, and the ordered list of
//! attachment view identities.
//!
//! **What the key does not carry.** Not the `VkImageView` handles and not the
//! clear values. The header says so (`:76-77`): they are stored because the
//! framebuffer create and `VkRenderPassBeginInfo` want them, not because the
//! key wants them. Two passes over the same views with different clear colours
//! therefore share one `VkFramebuffer`, and their clear values travel with the
//! begin info instead (`CommandBufferVk.cpp:1041-1042`). That is why the key is
//! one struct and the query is another: the key holds identities and the query
//! holds handles.
//!
//! **What the eviction does.** `LRUCache.h` is M14's file and its `LruCache`
//! is the only LRU in the port (`common/LRUCache.h:88-89`). Dawn's cache
//! overrides the virtual `EvictedFromCache` (`FramebufferCache.cpp:87-89`) to
//! route through the fenced deleter; M14's cache has no hook by design and
//! `put` returns the evicted value instead (`docs/30-port-design.md` §7.3).
//! This file therefore hands the eviction to `destroy_when_unused`, which is
//! `FencedDeleter::DeleteWhenUnused` (`FencedDeleter.h:75-77`) behind a
//! function pointer, so the port has one eviction path rather than two.

const std = @import("std");
const vulkan = @import("vulkan");
const pipeline_cache = @import("../pipeline/cache.zig");
const dispatch = @import("../vk/dispatch.zig");
const render_pass_cache = @import("render_pass_cache.zig");

/// `kMaxFramebufferAttachments` (`FramebufferCache.h:59`): eight colour and
/// eight resolve plus one depth-stencil.
pub const k_max_framebuffer_attachments = render_pass_cache.k_max_attachment_count;

/// `kDefaultCapacity` (`FramebufferCache.h:100`).
pub const k_default_capacity = 32;

/// `FramebufferCacheTextureView` (`FramebufferCache.h:50-56`).
///
/// The identity is a per-device view id and a depth slice, not a handle. The
/// upstream TODO at `:51-53` records why: a weak reference costs more to
/// promote than the id costs to mint, and the arena of
/// `docs/10-architecture.md` makes the id sufficient for the port's lifetime.
pub const FramebufferCacheTextureView = struct {
    texture_view_id: u64 = 0,
    depth_slice: u32 = 0,
};

/// The identity half of a query, and the whole of the key.
///
/// Stored by value, never by slice: a slice would point into the caller's stack
/// frame, and a cache whose key outlives the frame it was built from hands back
/// a framebuffer for views nobody can name. The handles stay in the query, which
/// is the value.
pub const FramebufferCacheKey = struct {
    render_pass_id: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    texture_views: [k_max_framebuffer_attachments]FramebufferCacheTextureView = @splat(.{}),
    attachment_count: u32 = 0,

    /// `FramebufferCacheQuery::SetRenderPass` (`FramebufferCache.cpp:43-49`).
    pub fn setRenderPass(self: *FramebufferCacheKey, pass: RenderPassExtent) void {
        self.render_pass_id = pass.pass_id;
        self.width = pass.width;
        self.height = pass.height;
    }
};

/// The query as the framebuffer create and the begin info read it
/// (`FramebufferCache.h:74-81`).
pub const FramebufferCacheQuery = struct {
    key: FramebufferCacheKey = .{},
    attachments: [k_max_framebuffer_attachments]vulkan.VkImageView = @splat(null),
    // Dawn value-initialises the array (`FramebufferCache.h:79`) and defaults
    // `AddAttachment`'s clear value to `{}` (`:65`), so an unfilled slot is
    // zero bytes. A union initializer names one field; both fields here hold
    // those same zero bytes, and the field says which aspect the slot
    // describes rather than what it clears to. `addAttachment` overwrites the
    // slot with the caller's own field, and `clearValueSlice` stops at
    // `attachment_count`, so a slot nobody filled never reaches Vulkan.
    clear_values: [k_max_framebuffer_attachments]vulkan.VkClearValue = @splat(.{
        .color = std.mem.zeroes(vulkan.VkClearColorValue),
    }),

    /// `FramebufferCacheQuery::AddAttachment` (`FramebufferCache.cpp:51-72`).
    ///
    /// The one bound upstream (`:54`) is the seventeen-attachment assert, and it
    /// is the port's `error.TooManyAttachments`. A 3D view resolves to the 2D
    /// view on that depth slice upstream (`:59-62`); the replay passes the
    /// resolved handle in, so the branch is where the caller made the choice and
    /// is not repeated here.
    pub fn addAttachment(
        self: *FramebufferCacheQuery,
        attachment: FramebufferAttachment,
    ) AddAttachmentError!void {
        const index = self.key.attachment_count;
        if (index >= k_max_framebuffer_attachments) return error.TooManyAttachments;

        self.key.texture_views[index] = .{
            .texture_view_id = attachment.texture_view_id,
            .depth_slice = attachment.depth_slice,
        };
        self.attachments[index] = attachment.image_view;
        self.clear_values[index] = attachment.clear_value;
        self.key.attachment_count += 1;
    }

    /// The attachment list as the create wants it. This is the one place the
    /// fixed array becomes a slice, so no caller walks 17 entries to find one.
    pub fn attachmentSlice(self: *const FramebufferCacheQuery) []const vulkan.VkImageView {
        return self.attachments[0..self.key.attachment_count];
    }

    /// The clear values in the same order, for `VkRenderPassBeginInfo`.
    pub fn clearValueSlice(self: *const FramebufferCacheQuery) []const vulkan.VkClearValue {
        return self.clear_values[0..self.key.attachment_count];
    }
};

/// What one `setRenderPass` call declares.
pub const RenderPassExtent = struct {
    pass_id: u64,
    width: u32,
    height: u32,
};

/// What one `addAttachment` call declares.
pub const FramebufferAttachment = struct {
    texture_view_id: u64,
    depth_slice: u32 = 0,
    image_view: vulkan.VkImageView,
    // The same zero bytes as the default `AddAttachment` takes
    // (`FramebufferCache.h:65`), and named for the same reason as the query's
    // own array: a caller that means depth passes a `depthStencil` value.
    clear_value: vulkan.VkClearValue = .{
        .color = std.mem.zeroes(vulkan.VkClearColorValue),
    },
};

pub const AddAttachmentError = error{TooManyAttachments};

/// One cached framebuffer and the query that made it.
pub const Entry = struct {
    query: FramebufferCacheQuery,
    framebuffer: vulkan.VkFramebuffer,
};

// `LruCache` returns a type (`src/pipeline/cache.zig:227`), so the binding is
// a type and takes `PascalCase` under `AGENTS.md` §2. The `: type` is what
// says so: without it `zwanzig` reads the call as a constant and asks for
// `snake_case`, which would name a type with the spelling of a value.
const Lru: type = pipeline_cache.LruCache(FramebufferCacheKey, *Entry, k_default_capacity);

/// What happens to a framebuffer that leaves the cache. Dawn's
/// `EvictedFromCache` (`FramebufferCache.cpp:87-89`) routes through the fenced
/// deleter so an evicted framebuffer outlives the submit that used it. The port
/// keeps one callback rather than a virtual, because M14's `LruCache` has no
/// hook and `docs/30-port-design.md` §7.3 records that the inheritance was
/// dropped for exactly this reason.
pub const DestroyWhenUnused = *const fn (
    context: *anyopaque,
    framebuffer: vulkan.VkFramebuffer,
) void;

/// What the cache needs to create and destroy a framebuffer.
pub const Device = struct {
    procs: *const dispatch.DeviceProcs,
    vk_device: vulkan.VkDevice,
};

/// `FramebufferCache` (`FramebufferCache.h:95-110`).
pub const FramebufferCache = struct {
    allocator: std.mem.Allocator,
    device: Device,
    entries: Lru = .init(),

    /// Every entry the cache still owns. The LRU decides which one leaves and
    /// when; this list says which ones exist, so `deinit` destroys exactly the
    /// live set without reaching into the LRU's own container.
    owned: std.ArrayList(*Entry) = .empty,

    /// Both are mandatory in `InitOptions` and `init` copies them here, so
    /// there is no default and no way to build a cache without the hook that
    /// stands in for `FencedDeleter::DeleteWhenUnused`.
    destroy_context: *anyopaque,
    destroy_when_unused: DestroyWhenUnused,

    pub const InitOptions = struct {
        allocator: std.mem.Allocator,
        device: Device,
        /// The hook that stands in for `FencedDeleter::DeleteWhenUnused`.
        /// Mandatory: an eviction with no hook would destroy a framebuffer a
        /// pending submit still names.
        destroy_context: *anyopaque,
        destroy_when_unused: DestroyWhenUnused,
    };

    /// `FramebufferCache::FramebufferCache` (`FramebufferCache.cpp:76-77`).
    /// Dawn takes the capacity as a defaulted second argument
    /// (`FramebufferCache.h:101`); the port's capacity is the LRU's comptime
    /// parameter, so `k_default_capacity` is the only value and is not a
    /// runtime argument.
    pub fn init(options: InitOptions) FramebufferCache {
        return .{
            .allocator = options.allocator,
            .device = options.device,
            .destroy_context = options.destroy_context,
            .destroy_when_unused = options.destroy_when_unused,
        };
    }

    /// `FramebufferCache::~FramebufferCache` (`FramebufferCache.cpp:79-85`):
    /// every held `VkFramebuffer` destroyed directly, not through the hook,
    /// because the device is being torn down and nothing is in flight.
    pub fn deinit(self: *FramebufferCache) void {
        const destroy_framebuffer = self.device.procs.destroy_framebuffer orelse unreachable;
        for (self.owned.items) |entry| {
            destroy_framebuffer(self.device.vk_device, entry.framebuffer, null);
            self.allocator.destroy(entry);
        }
        self.owned.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        // The cache is gone and nothing reads the value again, so the receiver
        // is poisoned rather than half reset.
        self.* = undefined;
    }

    /// The body of `LRUCache::GetOrCreate` (`common/LRUCache.h:95-140`) for this
    /// key: a hit hands the framebuffer back and refreshes the entry's use
    /// order, a miss creates one and the `put` returns whatever it evicted.
    pub fn getOrCreate(
        self: *FramebufferCache,
        query: *const FramebufferCacheQuery,
        render_pass: vulkan.VkRenderPass,
    ) GetOrCreateError!vulkan.VkFramebuffer {
        if (self.entries.get(query.key)) |found| return found.framebuffer;

        const created = try self.create(query, render_pass);
        errdefer self.release(created);

        // `LRUCache.h:131` evicts only once the cache has outgrown its
        // capacity, and `get` missed above, so this is an insert: `put`
        // answers with the value that left, or null when nothing did.
        if (try self.entries.put(self.allocator, query.key, created)) |evicted| {
            self.destroy_when_unused(self.destroy_context, evicted.framebuffer);
            self.forget(evicted);
            // The hook takes the handle by value (`FencedDeleter.h:75-77`), and
            // the entry is now named by neither the LRU nor `owned`, so
            // nothing can reach its allocation again. It goes back here
            // rather than at `deinit`, which only walks what the cache still
            // holds, and an eviction per 32 keys would leak for the life of
            // the device.
            self.allocator.destroy(evicted);
        }
        try self.owned.append(self.allocator, created);
        return created.framebuffer;
    }

    /// How many framebuffers the cache holds. The test asserts it never exceeds
    /// `k_default_capacity`, which is the one observable of the eviction that
    /// needs no device.
    pub fn count(self: *const FramebufferCache) usize {
        return self.entries.queryEntryCount();
    }

    fn create(
        self: *FramebufferCache,
        query: *const FramebufferCacheQuery,
        render_pass: vulkan.VkRenderPass,
    ) CreateError!*Entry {
        const attachments = query.attachmentSlice();
        const create_info: vulkan.VkFramebufferCreateInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO),
            .pNext = null,
            .flags = 0,
            .renderPass = render_pass,
            .attachmentCount = @intCast(attachments.len),
            .pAttachments = attachments.ptr,
            .width = query.key.width,
            .height = query.key.height,
            .layers = 1,
        };

        const create_framebuffer = self.device.procs.create_framebuffer orelse unreachable;
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);

        entry.query = query.*;
        try dispatch.checkVkSuccess(create_framebuffer(
            self.device.vk_device,
            &create_info,
            null,
            &entry.framebuffer,
        ));
        return entry;
    }

    /// Destroys an entry the cache never took ownership of: the `errdefer`
    /// after a create, before the `put` that would have made it owned.
    fn release(self: *FramebufferCache, entry: *Entry) void {
        const destroy_framebuffer = self.device.procs.destroy_framebuffer orelse unreachable;
        destroy_framebuffer(self.device.vk_device, entry.framebuffer, null);
        self.allocator.destroy(entry);
    }

    /// Drops an entry from the owned list without destroying its framebuffer.
    /// The caller has already handed that to `destroy_when_unused`, and frees
    /// the entry itself once the list no longer names it.
    fn forget(self: *FramebufferCache, entry: *Entry) void {
        for (self.owned.items, 0..) |owned, index| {
            if (owned != entry) continue;
            _ = self.owned.swapRemove(index);
            return;
        }
        // An entry the list does not name was never owned, which is the caller's
        // error and not a state a correct caller can reach.
        unreachable;
    }
};

pub const CreateError = dispatch.Error || std.mem.Allocator.Error;
pub const GetOrCreateError = CreateError || std.mem.Allocator.Error;

comptime {
    // Seventeen is eight colour plus eight resolve plus one depth-stencil, and
    // it is the same bound the render-pass cache fills against. A cache that
    // accepted more attachments than its pass describes would create a
    // framebuffer Vulkan rejects.
    if (k_max_framebuffer_attachments != 17) @compileError("the attachment bound moved");
    if (k_max_framebuffer_attachments != render_pass_cache.k_max_attachment_count) {
        @compileError("the two caches disagree about the attachment bound");
    }
    // The key must hash by value: it holds no slice and no pointer, because a
    // key that pointed into a caller's frame would outlive it.
    if (@typeInfo(FramebufferCacheKey) != .@"struct") {
        @compileError("the framebuffer key stopped being a plain struct");
    }
}
