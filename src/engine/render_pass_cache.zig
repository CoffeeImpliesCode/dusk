//! `RenderPassCache`: one `VkRenderPass` per attachment shape.
//!
//! **What this file is.** `vulkan/RenderPassCache.{h,cpp}` upstream: 132 lines
//! and 561 lines, 12 rows (`docs/40-plan.md` §M18). The key is sparse: only
//! the attachments a pass declares carry data, and everything else is
//! `undefined_`. The value is a `VkRenderPass`, the index of the subpass that
//! writes, and a monotonic `unique_id` that stands in for the handle as a key
//! the framebuffer cache can hold.
//!
//! **What this file does not claim.** It does not claim
//! `LoadOp::ExpandResolveTexture`. Upstream simulates that with two subpasses
//! and an input attachment (`RenderPassCache.cpp:248-284`); that is the blit
//! path M17 owns, and a query that asks for it is
//! `error.ExpandResolveNotSupported` rather than a pass that renders the wrong
//! thing. It does not claim framebuffer fetch (`:291-324`), which changes the
//! colour attachment reference layout to `VK_IMAGE_LAYOUT_GENERAL` and is M17's
//! as well.
//!
//! **The ordering rule.** Attachments are always built in
//! colour, depth-stencil, resolve order (the header comment at
//! `RenderPassCache.h:91-94`). The framebuffer and the pipeline both read the
//! same order, and an attachment list in a different order is a different pass.

const std = @import("std");
const vulkan = @import("vulkan");
const api = @import("../api/api.zig");
const stream = @import("stream.zig");
const vk_format = @import("vulkan_format.zig");
const vk = @import("../vk/dispatch.zig");

pub const CacheKey = stream.CacheKey;
pub const WriteError = stream.WriteError;

/// `kMaxColorAttachments` (`src/dawn/common/Constants.h:43`).
pub const k_max_color_attachments = 8;
/// `kMaxAttachmentCount` (`RenderPassCache.cpp:50`): eight colour and eight
/// resolve plus one depth-stencil.
pub const k_max_attachment_count = k_max_color_attachments * 2 + 1;
/// The subpass count with `ExpandResolveTexture` excluded, which is the whole
/// of what this file claims.
pub const k_max_subpass_count = 1;
/// The dependency count with `ExpandResolveTexture` and framebuffer fetch
/// excluded: upstream adds none at all in that case (`RenderPassCache.cpp:247-284`,
/// `:308-324`).
pub const k_max_dependency_count = 1;
/// `VK_ATTACHMENT_UNUSED` (`vulkan_core.h`): the fill for every hole of the
/// sparse arrays.
pub const attachment_unused: u32 = 0xFFFFFFFF;

/// The colour attachment a setter or a reader names.
pub const ColorAttachmentIndex = u8;

/// What one `setColor` call declares. Seven fields upstream become one struct
/// because `AGENTS.md` §2 makes two parameters of the same type one struct,
/// and five of them share two types.
pub const ColorAttachment = struct {
    index: ColorAttachmentIndex,
    format: vk_format.TextureFormat,
    load_op: vk_format.LoadOp,
    store_op: vk_format.StoreOp,
    has_resolve_target: bool,
    render_to_single_sampled: bool,
};

/// What one `setDepthStencil` call declares, for the same reason.
pub const DepthStencilAttachment = struct {
    format: vk_format.TextureFormat,
    depth_load_op: vk_format.LoadOp,
    depth_store_op: vk_format.StoreOp,
    depth_read_only: bool,
    stencil_load_op: vk_format.LoadOp,
    stencil_store_op: vk_format.StoreOp,
    stencil_read_only: bool,
};

/// The sparse key (`RenderPassCache.h:53-89`).
///
/// A slot no setter touched holds `undefined_` and is never read: `color_mask`,
/// `resolve_target_mask` and `has_depth_stencil` are the only gates, and the
/// hash and the equality test gate the rest on them (`RenderPassCache.cpp:507`,
/// `:546`, `:550-556`).
pub const RenderPassCacheQuery = struct {
    color_mask: u8 = 0,
    resolve_target_mask: u8 = 0,
    color_formats: [k_max_color_attachments]vk_format.TextureFormat = @splat(.undefined_),
    color_load_op: [k_max_color_attachments]vk_format.LoadOp = @splat(.undefined_),
    color_store_op: [k_max_color_attachments]vk_format.StoreOp = @splat(.undefined_),
    expand_resolve_mask: u8 = 0,
    render_to_single_sample_mask: u8 = 0,

    has_depth_stencil: bool = false,
    depth_stencil_format: vk_format.TextureFormat = .undefined_,
    depth_load_op: vk_format.LoadOp = .undefined_,
    depth_store_op: vk_format.StoreOp = .undefined_,
    depth_read_only: bool = false,
    stencil_load_op: vk_format.LoadOp = .undefined_,
    stencil_store_op: vk_format.StoreOp = .undefined_,
    stencil_read_only: bool = false,

    sample_count: u32 = 0,

    /// `RenderPassCacheQuery::SetColor` (`RenderPassCache.cpp:359-372`).
    ///
    /// `expand_resolve_mask` is set from `load_op == ExpandResolveTexture`
    /// (`:370`) and `render_to_single_sample_mask` from the last argument. A
    /// sparse key is only readable if both masks stay in step with
    /// `color_mask`, which is why the three writes are one function and not
    /// three public fields.
    pub fn setColor(self: *RenderPassCacheQuery, attachment: ColorAttachment) void {
        const index: usize = attachment.index;
        std.debug.assert(index < k_max_color_attachments);
        self.color_mask |= @as(u8, 1) << @intCast(index);
        self.color_formats[index] = attachment.format;
        self.color_load_op[index] = attachment.load_op;
        self.color_store_op[index] = attachment.store_op;
        if (attachment.has_resolve_target) {
            self.resolve_target_mask |= @as(u8, 1) << @intCast(index);
        }
        if (attachment.load_op == .expand_resolve_texture) {
            self.expand_resolve_mask |= @as(u8, 1) << @intCast(index);
        }
        if (attachment.render_to_single_sampled) {
            self.render_to_single_sample_mask |= @as(u8, 1) << @intCast(index);
        }
    }

    /// `RenderPassCacheQuery::SetDepthStencil` (`:374-389`).
    ///
    /// The one flag it sets is `has_depth_stencil`, and that flag is what gates
    /// every other depth field in both the hash and the equality test.
    pub fn setDepthStencil(self: *RenderPassCacheQuery, attachment: DepthStencilAttachment) void {
        self.has_depth_stencil = true;
        self.depth_stencil_format = attachment.format;
        self.depth_load_op = attachment.depth_load_op;
        self.depth_store_op = attachment.depth_store_op;
        self.depth_read_only = attachment.depth_read_only;
        self.stencil_load_op = attachment.stencil_load_op;
        self.stencil_store_op = attachment.stencil_store_op;
        self.stencil_read_only = attachment.stencil_read_only;
    }

    /// `RenderPassCacheQuery::SetSampleCount` (`:391-393`).
    pub fn setSampleCount(self: *RenderPassCacheQuery, sample_count: u32) void {
        self.sample_count = sample_count;
    }

    /// `RenderPassCache::CacheFuncs::operator()(query)` (`:496-513`).
    ///
    /// The field order is the contract for reproducibility, not for
    /// correctness: a hash only has to agree with `eql`. It is kept because a
    /// cache file written from one process and read from another has to hash
    /// the same way twice.
    pub fn hash(self: RenderPassCacheQuery) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.color_mask));
        hasher.update(std.mem.asBytes(&self.resolve_target_mask));
        hasher.update(std.mem.asBytes(&self.sample_count));

        var index: usize = 0;
        while (index < k_max_color_attachments) : (index += 1) {
            if (self.colorMaskBitSet(index)) {
                hasher.update(std.mem.asBytes(&self.color_formats[index]));
                hasher.update(std.mem.asBytes(&self.color_load_op[index]));
                hasher.update(std.mem.asBytes(&self.color_store_op[index]));
            }
        }
        hasher.update(std.mem.asBytes(&self.has_depth_stencil));
        if (self.has_depth_stencil) {
            hasher.update(std.mem.asBytes(&self.depth_stencil_format));
            hasher.update(std.mem.asBytes(&self.depth_load_op));
            hasher.update(std.mem.asBytes(&self.depth_store_op));
            hasher.update(std.mem.asBytes(&self.depth_read_only));
            hasher.update(std.mem.asBytes(&self.stencil_load_op));
            hasher.update(std.mem.asBytes(&self.stencil_store_op));
            hasher.update(std.mem.asBytes(&self.stencil_read_only));
        }
        return hasher.final();
    }

    /// `RenderPassCache::CacheFuncs::operator()(a, b)` (`:517-556`).
    ///
    /// The two masks come first because they decide which of the rest is
    /// meaningful. A shorter test would let two different colour sets share a
    /// `VkRenderPass`, and the second pass would render into the first pass's
    /// attachments.
    pub fn eql(left: RenderPassCacheQuery, right: RenderPassCacheQuery) bool {
        if (left.color_mask != right.color_mask) return false;
        if (left.resolve_target_mask != right.resolve_target_mask) return false;
        if (left.sample_count != right.sample_count) return false;

        var index: usize = 0;
        while (index < k_max_color_attachments) : (index += 1) {
            if (!left.colorMaskBitSet(index)) continue;
            if (left.color_formats[index] != right.color_formats[index]) return false;
            if (left.color_load_op[index] != right.color_load_op[index]) return false;
            if (left.color_store_op[index] != right.color_store_op[index]) return false;
        }
        if (left.expand_resolve_mask != right.expand_resolve_mask) return false;
        if (left.render_to_single_sample_mask != right.render_to_single_sample_mask) return false;
        if (left.has_depth_stencil != right.has_depth_stencil) return false;
        if (left.has_depth_stencil) {
            if (left.depth_stencil_format != right.depth_stencil_format) return false;
            if (left.depth_load_op != right.depth_load_op) return false;
            if (left.stencil_load_op != right.stencil_load_op) return false;
            if (left.depth_store_op != right.depth_store_op) return false;
            if (left.depth_read_only != right.depth_read_only) return false;
            if (left.stencil_store_op != right.stencil_store_op) return false;
            if (left.stencil_read_only != right.stencil_read_only) return false;
        }
        return true;
    }

    /// `Stream<vulkan::RenderPassCacheQuery>::Write`
    /// (`StreamImplVk.cpp:384-401`).
    ///
    /// The sparse walk is the reason this writer is not a `Step` list: the
    /// arrays hold `undefined_` in every slot no setter touched, and
    /// serialising them all would put uninitialised data in a key. Only the
    /// set bits go in, after `color_mask` has said which they are.
    pub fn writeTo(
        self: RenderPassCacheQuery,
        allocator: std.mem.Allocator,
        key: *CacheKey,
    ) WriteError!void {
        try key.appendWord(allocator, self.color_mask);
        try key.appendWord(allocator, self.resolve_target_mask);
        try key.appendWord(allocator, self.sample_count);

        var index: usize = 0;
        while (index < k_max_color_attachments) : (index += 1) {
            if (!self.colorMaskBitSet(index)) continue;
            try key.appendEnum(allocator, self.color_formats[index]);
            try key.appendEnum(allocator, self.color_load_op[index]);
            try key.appendEnum(allocator, self.color_store_op[index]);
        }

        try key.appendWord(allocator, @intFromBool(self.has_depth_stencil));
        if (!self.has_depth_stencil) return;

        try key.appendEnum(allocator, self.depth_stencil_format);
        try key.appendEnum(allocator, self.depth_load_op);
        try key.appendEnum(allocator, self.depth_store_op);
        try key.appendWord(allocator, @intFromBool(self.depth_read_only));
        try key.appendEnum(allocator, self.stencil_load_op);
        try key.appendEnum(allocator, self.stencil_store_op);
        try key.appendWord(allocator, @intFromBool(self.stencil_read_only));
    }

    fn colorMaskBitSet(self: RenderPassCacheQuery, index: usize) bool {
        const mask: u8 = @as(u8, 1) << @intCast(index);
        return self.color_mask & mask != 0;
    }
};

/// `RenderPassCache::RenderPassInfo` (`RenderPassCache.h:102-106`).
///
/// `unique_id` is the field that makes the cache holdable: the framebuffer key
/// stores a `u64` rather than a handle, so a cached framebuffer stays valid
/// when the `VkRenderPass` handle is reused by a later create.
pub const RenderPassInfo = struct {
    render_pass: vulkan.VkRenderPass = null,
    main_subpass: u32 = 0,
    unique_id: u64 = 0,
};

/// The create-info holder and the sparse arrays it points at
/// (`RenderPassCache.cpp:52-85`).
pub const RenderPassCreateInfo = struct {
    create_info: vulkan.VkRenderPassCreateInfo,
    attachment_descs: [k_max_attachment_count]vulkan.VkAttachmentDescription,
    color_attachment_refs: [k_max_color_attachments]vulkan.VkAttachmentReference,
    depth_stencil_attachment_ref: vulkan.VkAttachmentReference,
    resolve_attachment_refs: [k_max_color_attachments]vulkan.VkAttachmentReference,
    subpass_descs: [k_max_subpass_count]vulkan.VkSubpassDescription,
    subpass_dependencies: [k_max_dependency_count]vulkan.VkSubpassDependency,

    /// `RenderPassCreateInfo::RenderPassCreateInfo` (`RenderPassCache.cpp:54`).
    ///
    /// Every array is zeroed and every hole is `VK_ATTACHMENT_UNUSED`, because
    /// an unset attachment layout is what the validation layer rejects (the
    /// comment at `:55-58`). `subpass_descs` and `subpass_dependencies` keep
    /// their zeros: a dependency index of zero is the external subpass, and a
    /// subpass index of zero is the only subpass.
    pub fn init() RenderPassCreateInfo {
        const unused_ref: vulkan.VkAttachmentReference = .{
            .attachment = attachment_unused,
            .layout = @intCast(vulkan.VK_IMAGE_LAYOUT_UNDEFINED),
        };
        return .{
            .create_info = std.mem.zeroes(vulkan.VkRenderPassCreateInfo),
            .attachment_descs = @splat(.{
                .flags = 0,
                .format = @intCast(vulkan.VK_FORMAT_UNDEFINED),
                .samples = @intCast(vulkan.VK_SAMPLE_COUNT_1_BIT),
                .loadOp = @intCast(vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE),
                .storeOp = @intCast(vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE),
                .stencilLoadOp = @intCast(vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE),
                .stencilStoreOp = @intCast(vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE),
                .initialLayout = @intCast(vulkan.VK_IMAGE_LAYOUT_UNDEFINED),
                .finalLayout = @intCast(vulkan.VK_IMAGE_LAYOUT_UNDEFINED),
            }),
            .color_attachment_refs = @splat(unused_ref),
            .depth_stencil_attachment_ref = unused_ref,
            .resolve_attachment_refs = @splat(unused_ref),
            // The array type, not the element type: these two fields are
            // arrays, and `std.mem.zeroes` of the element would not fit.
            .subpass_descs = std.mem.zeroes(
                [k_max_subpass_count]vulkan.VkSubpassDescription,
            ),
            .subpass_dependencies = std.mem.zeroes(
                [k_max_dependency_count]vulkan.VkSubpassDependency,
            ),
        };
    }
};

/// `InitializePassInfo<InfoType>` (`RenderPassCache.cpp:147-354`), the parts
/// this milestone claims: colour, depth-stencil and resolve, one subpass, no
/// dependency, no input attachment.
pub fn initializePassInfo(
    holder: *RenderPassCreateInfo,
    query: RenderPassCacheQuery,
) PassBuildError!void {
    if (query.expand_resolve_mask != 0) return error.ExpandResolveNotSupported;

    const sample_count = try vk_format.vkSampleCount(query.sample_count);
    const color_attachment_layout: vulkan.VkImageLayout =
        @intCast(vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);

    var attachment_count: u32 = 0;
    var color_attachment_count: u8 = 0;

    var index: usize = 0;
    while (index < k_max_color_attachments) : (index += 1) {
        if (!query.colorMaskBitSet(index)) continue;
        // `:171-172`: a render-to-single-sampled attachment takes one sample
        // and everything else takes the pass's count.
        holder.attachment_descs[attachment_count] = .{
            .flags = 0,
            .format = vk_format.vkFormat(query.color_formats[index]),
            .samples = if (query.render_to_single_sample_mask & (@as(u8, 1) << @intCast(index)) != 0)
                @intCast(vulkan.VK_SAMPLE_COUNT_1_BIT)
            else
                sample_count,
            .loadOp = vk_format.attachmentLoadOp(query.color_load_op[index]),
            .storeOp = vk_format.attachmentStoreOp(query.color_store_op[index]),
            .stencilLoadOp = @intCast(vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE),
            .stencilStoreOp = @intCast(vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE),
            .initialLayout = color_attachment_layout,
            .finalLayout = color_attachment_layout,
        };
        holder.color_attachment_refs[index] = .{
            .attachment = attachment_count,
            .layout = color_attachment_layout,
        };
        color_attachment_count = @intCast(index + 1);
        attachment_count += 1;
    }

    if (query.has_depth_stencil) {
        const native_format = vk_format.vkFormat(query.depth_stencil_format);
        const aspects: struct { has_depth: bool, has_stencil: bool } = switch (native_format) {
            vulkan.VK_FORMAT_D16_UNORM,
            vulkan.VK_FORMAT_X8_D24_UNORM_PACK32,
            vulkan.VK_FORMAT_D32_SFLOAT,
            => .{ .has_depth = true, .has_stencil = false },
            vulkan.VK_FORMAT_S8_UINT => .{ .has_depth = false, .has_stencil = true },
            vulkan.VK_FORMAT_D16_UNORM_S8_UINT,
            vulkan.VK_FORMAT_D24_UNORM_S8_UINT,
            vulkan.VK_FORMAT_D32_SFLOAT_S8_UINT,
            => .{ .has_depth = true, .has_stencil = true },
            // The validated query must name a depth-stencil attachment format.
            else => unreachable,
        };
        const layout = vk_format.vkImageLayoutForDepthStencilAttachment(.{
            .has_depth = aspects.has_depth,
            .has_stencil = aspects.has_stencil,
            .depth_read_only = query.depth_read_only,
            .stencil_read_only = query.stencil_read_only,
        });
        holder.attachment_descs[attachment_count] = .{
            .flags = 0,
            .format = native_format,
            .samples = sample_count,
            .loadOp = vk_format.attachmentLoadOp(query.depth_load_op),
            .storeOp = vk_format.attachmentStoreOp(query.depth_store_op),
            .stencilLoadOp = vk_format.attachmentLoadOp(query.stencil_load_op),
            .stencilStoreOp = vk_format.attachmentStoreOp(query.stencil_store_op),
            // `:202-205`: one subpass, so the initial and final layouts are the
            // subpass's own layout.
            .initialLayout = layout,
            .finalLayout = layout,
        };
        holder.depth_stencil_attachment_ref = .{
            .attachment = attachment_count,
            .layout = layout,
        };
        attachment_count += 1;
    }

    var resolve_attachment_count: u32 = 0;
    index = 0;
    while (index < k_max_color_attachments) : (index += 1) {
        if (query.resolve_target_mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
        holder.attachment_descs[attachment_count] = .{
            .flags = 0,
            .format = vk_format.vkFormat(query.color_formats[index]),
            .samples = @intCast(vulkan.VK_SAMPLE_COUNT_1_BIT),
            .loadOp = @intCast(vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE),
            // `:223`: a resolve target is always stored.
            .storeOp = @intCast(vulkan.VK_ATTACHMENT_STORE_OP_STORE),
            .stencilLoadOp = @intCast(vulkan.VK_ATTACHMENT_LOAD_OP_DONT_CARE),
            .stencilStoreOp = @intCast(vulkan.VK_ATTACHMENT_STORE_OP_DONT_CARE),
            .initialLayout = color_attachment_layout,
            .finalLayout = color_attachment_layout,
        };
        holder.resolve_attachment_refs[index] = .{
            .attachment = attachment_count,
            .layout = color_attachment_layout,
        };
        attachment_count += 1;
        resolve_attachment_count += 1;
    }

    holder.subpass_descs[0] = .{
        .flags = 0,
        .pipelineBindPoint = @intCast(vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS),
        .inputAttachmentCount = 0,
        .pInputAttachments = null,
        .colorAttachmentCount = color_attachment_count,
        .pColorAttachments = &holder.color_attachment_refs,
        // `:332-337`: some Qualcomm drivers answer a zero-length resolve array
        // with `VK_ERROR_OUT_OF_HOST_MEMORY`, so the null is required.
        .pResolveAttachments = if (resolve_attachment_count == 0)
            null
        else
            &holder.resolve_attachment_refs,
        .pDepthStencilAttachment = if (query.has_depth_stencil)
            &holder.depth_stencil_attachment_ref
        else
            null,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = null,
    };

    holder.create_info = .{
        // `VkStructureType` is `c_uint` in this translation of the header
        // (`src/vulkan.zig:2420`), not an enumeration, so the constant is cast
        // rather than converted with `@enumFromInt`.
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO),
        .pNext = null,
        .flags = 0,
        .attachmentCount = attachment_count,
        .pAttachments = &holder.attachment_descs,
        .subpassCount = 1,
        .pSubpasses = &holder.subpass_descs,
        // No dependency: with neither framebuffer fetch nor
        // `ExpandResolveTexture` upstream adds none (`RenderPassCache.cpp:247-284`,
        // `:308-324`).
        .dependencyCount = 0,
        .pDependencies = &holder.subpass_dependencies,
    };
}

pub const PassBuildError = vk_format.SampleCountError || error{
    ExpandResolveNotSupported,
};

/// The hash-map context, so `RenderPassCacheQuery` carries `hash` and `eql`
/// rather than a `std.hash.autoHashStrat`.
pub const CacheContext = struct {
    pub fn hash(_: CacheContext, key: RenderPassCacheQuery) u64 {
        return key.hash();
    }

    pub fn eql(_: CacheContext, left: RenderPassCacheQuery, right: RenderPassCacheQuery) bool {
        return left.eql(right);
    }
};

/// What the cache needs to create a pass: the device tier of the dispatch
/// table and the handle. `queue.Context` (`src/engine/queue.zig`) carries both
/// plus the allocator, and it is the only argument this file takes, so a test
/// can hand one in and destroy every pass it created.
pub const Device = struct {
    procs: *const vk.DeviceProcs,
    vk_device: vulkan.VkDevice,
};

/// `RenderPassCache` (`RenderPassCache.h:97-128`).
///
/// Every operation is guarded by `mutex` (`RenderPassCache.cpp:410`, `:400`)
/// because pipeline creation runs on the worker pool and calls
/// `getRenderPass` from there while a pass records on the device thread. That
/// is Dawn's `std::lock_guard<std::mutex>` at `RenderPassCache.cpp:400` and
/// `:410`.
///
/// The lock is `std.Io.Mutex`, which is where Zig 0.16 moved the mutex out of
/// `std.Thread`. It takes an `Io` to block on, so every locked method takes
/// `io` as a parameter rather than reaching for a global (`AGENTS.md` §3), and
/// the cancellation `Io.Mutex.lock` can report becomes `error.Canceled`, the
/// same member `src/platform/threads.zig:52` and `src/memory/size_tracker.zig:62`
/// raise for it.
///
/// `self` is the first parameter and `io` the second, which is the reverse of
/// `src/memory/size_tracker.zig:90`. Zig 0.16 resolves `a.f(x)` by binding the
/// receiver to the *first* parameter, so a receiver in any other position
/// stops being a member function and the call has to be written out in full.
/// The receiver leads here because a caller reaching this cache says
/// `passes.getRenderPass(io, query)`.
pub const RenderPassCache = struct {
    allocator: std.mem.Allocator,
    device: Device,
    mutex: std.Io.Mutex = .init,
    // `std.HashMapUnmanaged` and not `std.AutoHashMapUnmanaged`: the key is a
    // struct the auto strategy cannot hash, so the context is named. Zig 0.16
    // dropped the context and load-percentage parameters from the `Auto*`
    // constructors, which now take the key and the value only.
    entries: std.HashMapUnmanaged(
        RenderPassCacheQuery,
        RenderPassInfo,
        CacheContext,
        std.hash_map.default_max_load_percentage,
    ) = .empty,
    next_render_pass_id: u64 = 1,

    pub const InitOptions = struct {
        allocator: std.mem.Allocator,
        device: Device,
    };

    /// `RenderPassCache::RenderPassCache` (`RenderPassCache.cpp:397`).
    pub fn init(options: InitOptions) RenderPassCache {
        return .{
            .allocator = options.allocator,
            .device = options.device,
        };
    }

    /// `RenderPassCache::~RenderPassCache` (`:399-406`): every `VkRenderPass`
    /// destroyed under the mutex, then the map cleared.
    ///
    /// The lock `destroyEveryPass` takes is `lockUncancelable`, not `lock`,
    /// and that is the whole reason `deinit` does not return an error. A
    /// cancelled teardown would return with every cached `VkRenderPass` still
    /// live, and a destructor that leaks is not a destructor. Dawn's
    /// `lock_guard` at `RenderPassCache.cpp:400` cannot be cancelled for the
    /// same reason.
    pub fn deinit(self: *RenderPassCache, io: std.Io) void {
        self.destroyEveryPass(io);
        // The cache is gone and nothing reads the value again, so the receiver
        // is poisoned rather than half reset. That comes after the unlock,
        // because poisoning the mutex would make the unlock a use of poison.
        self.* = undefined;
    }

    /// The locked half of `deinit`.
    fn destroyEveryPass(self: *RenderPassCache, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // Bound before the loop so the null check names the missing proc once
        // and not once per cached pass. A null field is "the extension was not
        // loaded", and `destroy_render_pass` is core 1.0
        // (`VulkanFunctions.h:214`-`:333`), so the absence is a loader defect.
        const destroy_render_pass = self.device.procs.destroy_render_pass orelse
            unreachable;

        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            destroy_render_pass(self.device.vk_device, entry.value_ptr.render_pass, null);
        }
        self.entries.deinit(self.allocator);
    }

    /// `RenderPassCache::GetRenderPass` (`:408-420`): lock, look up, and on a
    /// miss create then insert.
    /// Returned native passes belong to the cache. Failed insertion destroys
    /// the unpublished pass before releasing the lock.
    ///
    /// The `unique_id` is stamped inside the create (`:425`), so a create that
    /// fails never consumes one and two failures never collide.
    pub fn getRenderPass(
        self: *RenderPassCache,
        io: std.Io,
        query: RenderPassCacheQuery,
    ) GetRenderPassError!RenderPassInfo {
        self.mutex.lock(io) catch return error.Canceled;
        defer self.mutex.unlock(io);

        if (self.entries.get(query)) |found| return found;

        const destroy_render_pass = self.device.procs.destroy_render_pass orelse unreachable;
        const created = try self.createRenderPassForQuery(query);
        errdefer destroy_render_pass(self.device.vk_device, created.render_pass, null);
        try self.entries.put(self.allocator, query, created);
        return created;
    }

    /// `RenderPassCache::CreateRenderPassForQuery` (`:422-490`).
    ///
    /// Only the `CreateRenderPass` arm (`:468-483`) is claimed. The
    /// `CreateRenderPass2` arm and the `DynamicRendering` arm are `unreachable`
    /// with the reason named: the second needs `VK_KHR_create_renderpass2` and
    /// the third is `DAWN_UNREACHABLE` upstream (`:484-486`) because this cache
    /// is not reached under it.
    fn createRenderPassForQuery(
        self: *RenderPassCache,
        query: RenderPassCacheQuery,
    ) GetRenderPassError!RenderPassInfo {
        var holder: RenderPassCreateInfo = .init();
        try initializePassInfo(&holder, query);

        var info: RenderPassInfo = .{};
        info.unique_id = self.next_render_pass_id;
        self.next_render_pass_id += 1;
        // One subpass, so the subpass that writes is subpass zero (`:477`).
        info.main_subpass = holder.create_info.subpassCount - 1;

        const create_render_pass = self.device.procs.create_render_pass orelse unreachable;
        const check_vk_success = vk.checkVkSuccess;
        try check_vk_success(create_render_pass(
            self.device.vk_device,
            &holder.create_info,
            null,
            &info.render_pass,
        ));
        return info;
    }
};

/// `error.Canceled` is the cancellation `std.Io.Mutex.lock` reports, which
/// `src/platform/threads.zig:52` and `src/memory/size_tracker.zig:62` raise
/// for the same call. `createRenderPassForQuery` returns this set too, and adds
/// nothing: it runs under the lock `getRenderPass` already took, so it has no
/// lock of its own to cancel on.
pub const GetRenderPassError = PassBuildError ||
    vk.Error ||
    std.mem.Allocator.Error ||
    error{Canceled};

comptime {
    // The claimed subpass and dependency counts are the ones the build writes.
    // A second subpass with no dependency would be a pass Vulkan cannot run,
    // and a second dependency with no producer is a self-dependency upstream
    // builds only for framebuffer fetch.
    if (k_max_subpass_count != 1) @compileError("this milestone builds one subpass");
    if (k_max_dependency_count != 1) @compileError("this milestone builds no dependency");
    // Eight colour plus eight resolve plus one depth-stencil, which is the only
    // reason `k_max_attachment_count` is 17 rather than 16.
    if (k_max_attachment_count != 17) @compileError("the attachment bound moved");
    // The `TextureFormat` type is reachable through the re-export, which is
    // what a caller names instead of `api.enums.TextureFormat`.
    if (@typeInfo(api.enums.TextureFormat) != .@"enum") {
        @compileError("TextureFormat stopped being an enumeration");
    }
}

test "render pass depth stencil layouts use present format aspects and both read-only flags" {
    const attachment = vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    const read_only = vulkan.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
    const depth_read_only = vulkan.VK_IMAGE_LAYOUT_DEPTH_READ_ONLY_STENCIL_ATTACHMENT_OPTIMAL;
    const stencil_read_only = vulkan.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_STENCIL_READ_ONLY_OPTIMAL;
    const cases = [_]struct {
        format: vk_format.TextureFormat,
        layouts: [4]c_int,
    }{
        .{ .format = .depth16_unorm, .layouts = .{ attachment, attachment, read_only, read_only } },
        .{ .format = .depth24_plus, .layouts = .{ attachment, attachment, read_only, read_only } },
        .{ .format = .depth32_float, .layouts = .{ attachment, attachment, read_only, read_only } },
        .{ .format = .stencil8, .layouts = .{ attachment, read_only, attachment, read_only } },
        .{
            .format = .depth24_plus_stencil8,
            .layouts = .{ attachment, stencil_read_only, depth_read_only, read_only },
        },
        .{
            .format = .depth32_float_stencil8,
            .layouts = .{ attachment, stencil_read_only, depth_read_only, read_only },
        },
    };
    for (cases) |case| {
        for (case.layouts, 0..) |expected_layout, index| {
            var query: RenderPassCacheQuery = .{};
            query.setSampleCount(1);
            query.setDepthStencil(.{
                .format = case.format,
                .depth_load_op = .load,
                .depth_store_op = .store,
                .depth_read_only = index & 2 != 0,
                .stencil_load_op = .load,
                .stencil_store_op = .store,
                .stencil_read_only = index & 1 != 0,
            });
            var holder = RenderPassCreateInfo.init();
            try initializePassInfo(&holder, query);
            const expected: vulkan.VkImageLayout = @intCast(expected_layout);
            try std.testing.expectEqual(expected, holder.attachment_descs[0].initialLayout);
            try std.testing.expectEqual(expected, holder.attachment_descs[0].finalLayout);
            try std.testing.expectEqual(expected, holder.depth_stencil_attachment_ref.layout);
            try std.testing.expectEqual(index & 2 != 0, query.depth_read_only);
            try std.testing.expectEqual(index & 1 != 0, query.stencil_read_only);
        }
    }
}
