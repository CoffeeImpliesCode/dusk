//! What a render pass renders into, as a value that two pipelines can be
//! compared against.
//!
//! **What this file is.** The port of `src/dawn/native/AttachmentState.{h,cpp}`:
//! the flattened description of a render pass's colour, depth-stencil and
//! pixel-local-storage attachments, plus the content hash and the equality
//! that must agree with it field for field.
//!
//! **What this file does not claim.** It does not intern the state. Dawn's
//! `AttachmentState` is a `CachedObject`
//! (`src/dawn/native/AttachmentState.h:48-50`) triple-inherited so the device
//! holds one instance per distinct state and compares pointers. The port
//! computes the hash and leaves the interning to the cache that owns it: the
//! identity `BeginRenderPassCmd.attachment_state` and
//! `SetRenderPipelineCmd.attachment_state` hold is the interned pointer, and
//! which allocator produced it is M14's decision, not this file's.
//!
//! It does not claim to read a texture. Dawn's render-pass constructor is the
//! one that reads sample counts off the textures
//! (`src/dawn/native/AttachmentState.cpp:109`); the port takes the sample count
//! and the formats as arguments, because `command` does not import `engine`.

const std = @import("std");
const commands = @import("commands.zig");
const constants = @import("constants.zig");

/// The colour attachments that use `expand_resolve_texture` as their load op,
/// and the ones among them that have a resolve target
/// (`src/dawn/native/AttachmentState.h:54-61`).
pub const ExpandResolveInfo = struct {
    attachments_to_expand_resolve: u8 = 0,
    resolve_targets_mask: u8 = 0,
};

/// One attachment slot's shape. A pipeline and a pass both reduce to this, and
/// the two are comparable field for field, which is what makes
/// `AttachmentState` unnecessary for a pipeline-side check.
pub const SlotShape = struct {
    /// The `dawn.json` "texture format" wire value; zero is `Undefined` and
    /// means the slot is absent, which is how Dawn spells "no depth-stencil
    /// attachment" (`AttachmentState.h:90-91`).
    format: u32 = 0,
    /// The samples per pixel the attachment holds. Dawn compares this on its
    /// own (`AttachmentState.h:92`).
    sample_count: u32 = 1,
    /// True when the slot must be cleared before the pass runs. A pipeline does
    /// not have one, so this is false on every pipeline-side state.
    has_resolve_target: bool = false,
    /// True when the slot's load op is `expand_resolve_texture`.
    expands_resolve: bool = false,
};

/// What a render pass renders into.
pub const AttachmentState = struct {
    /// One bit per colour attachment, `kMaxColorAttachments` of them
    /// (`AttachmentState.h:88`). Dawn's `ColorAttachmentMask` is a bitset over
    /// an 8-wide index type (`native/IntegerTypes.h:84-88`), so a byte carries
    /// the whole mask.
    color_attachments_set: u8 = 0,
    color_formats: [constants.max_color_attachments]u32 = @splat(0),
    depth_stencil_format: u32 = 0,
    sample_count: u32 = 1,
    expand_resolve: ExpandResolveInfo = .{},
    has_pls: bool = false,
    /// The pixel-local-storage slots, in slot order, up to
    /// `storage_attachment_slot_count`. Dawn keeps a `std::vector`
    /// (`AttachmentState.h:97`); a fixed array keeps the hash deterministic
    /// without a seed and without an allocation.
    storage_attachment_slots: [constants.max_storage_attachments_per_render_pass]u32 = @splat(0),
    storage_attachment_slot_count: u32 = 0,

    /// Dawn's render-pass constructor
    /// (`AttachmentState.cpp:109`). The descriptor has already been validated,
    /// so this only flattens it.
    ///
    /// `formats` and `sample_counts` are the caller's per-slot answers: Dawn
    /// reads both off the texture view, and the port takes them because it
    /// cannot. They must be the same length as `color_attachments`.
    pub fn fromRenderPass(
        attachments: []const commands.RenderPassColorAttachmentInfo,
        depth_stencil: commands.RenderPassDepthStencilAttachmentInfo,
        formats: []const u32,
        sample_counts: []const u32,
        depth_stencil_format: u32,
    ) AttachmentError!AttachmentState {
        if (attachments.len > constants.max_color_attachments) return error.TooManyAttachments;
        if (attachments.len != formats.len or attachments.len != sample_counts.len) {
            return error.PerSlotAnswersMissing;
        }
        var self: AttachmentState = .{};
        for (attachments, 0..) |attachment, index| {
            if (!attachment.isPresent()) continue;
            self.color_attachments_set |= @as(u8, 1) << @intCast(index);
            self.color_formats[index] = formats[index];
            if (attachment.resolve_target != null) {
                self.expand_resolve.resolve_targets_mask |= @as(u8, 1) << @intCast(index);
            }
            if (attachment.load_op == .expand_resolve_texture) {
                self.expand_resolve.attachments_to_expand_resolve |= @as(u8, 1) << @intCast(index);
            }
        }
        self.sample_count = if (sample_counts.len == 0) 1 else sample_counts[0];
        if (depth_stencil.view != null) self.depth_stencil_format = depth_stencil_format;
        return self;
    }

    /// Dawn's bundle constructor (`AttachmentState.cpp:45`). A bundle records
    /// no attachments of its own; it is built against the pass that will
    /// execute it, so the shape arrives whole.
    pub fn fromRenderBundle(slots: []const SlotShape) AttachmentState {
        return fromSlots(slots);
    }

    /// Dawn's pipeline constructor (`AttachmentState.cpp:64`). A pipeline has no
    /// resolve target and no load op, so `has_resolve_target` and `expands_resolve`
    /// are false on every slot.
    pub fn fromRenderPipeline(slots: []const SlotShape) AttachmentState {
        return fromSlots(slots);
    }

    /// The copy constructor (`AttachmentState.cpp:186`). Dawn copies a
    /// blueprint so the cache key and the state do not parse the descriptor
    /// twice; the port's value type copies with `@memcpy`, so there is nothing
    /// to write.
    pub fn hasColorAttachment(self: AttachmentState, index: u32) bool {
        if (index >= constants.max_color_attachments) return false;
        return self.color_attachments_set & (@as(u8, 1) << @intCast(index)) != 0;
    }

    pub fn colorAttachmentFormat(self: AttachmentState, index: u32) u32 {
        if (!self.hasColorAttachment(index)) return 0;
        return self.color_formats[index];
    }

    /// Dawn's `HasDepthStencilAttachment` (`AttachmentState.h:71`): the
    /// format is `Undefined` exactly when there is none.
    pub fn hasDepthStencilAttachment(self: AttachmentState) bool {
        return self.depth_stencil_format != 0;
    }

    pub fn hasPixelLocalStorage(self: AttachmentState) bool {
        return self.has_pls;
    }

    /// Dawn's `ComputeStorageAttachmentPackingInColorAttachments`
    /// (`AttachmentState.cpp`): the colour slots a storage attachment is
    /// emulated through when there are not enough colour slots. The port does
    /// not emulate: `workarounds.zig` expands a resolve instead, and the
    /// packing belongs to that milestone. This returns the empty case so the
    /// caller has one answer rather than a missing function.
    pub fn storageAttachmentPacking(self: AttachmentState) []const u32 {
        return self.storage_attachment_slots[0..self.storage_attachment_slot_count];
    }

    /// Dawn's `AttachmentState::EqualityFunc::operator()`
    /// (`AttachmentState.cpp:204-252`).
    pub fn eql(left: AttachmentState, right: AttachmentState) bool {
        if (left.color_attachments_set != right.color_attachments_set) return false;
        if (left.depth_stencil_format != right.depth_stencil_format) return false;
        if (left.sample_count != right.sample_count) return false;
        if (left.has_pls != right.has_pls) return false;
        if (left.storage_attachment_slot_count != right.storage_attachment_slot_count) return false;
        if (left.color_formats != right.color_formats) return false;
        if (left.storage_attachment_slots != right.storage_attachment_slots) return false;
        const left_expand = left.expand_resolve;
        const right_expand = right.expand_resolve;
        return left_expand.attachments_to_expand_resolve ==
            right_expand.attachments_to_expand_resolve and
            left_expand.resolve_targets_mask == right_expand.resolve_targets_mask;
    }

    /// Dawn's `ComputeContentHash` (`AttachmentState.cpp:254-280`).
    ///
    /// The hash covers exactly the fields `eql` compares. That is the whole
    /// contract: two states that compare equal must hash equal, so a cache
    /// keyed on the hash cannot hand back a state with a different shape. The
    /// hash is seeded with a constant because the port has no per-process
    /// randomness to inject and the cache is not persisted.
    pub fn computeContentHash(self: AttachmentState) u64 {
        var hasher: std.hash.Wyhash = .init(attachment_state_hash_seed);
        hasher.update(std.mem.asBytes(&self.color_attachments_set));
        hasher.update(std.mem.asBytes(&self.color_formats));
        hasher.update(std.mem.asBytes(&self.depth_stencil_format));
        hasher.update(std.mem.asBytes(&self.sample_count));
        hasher.update(std.mem.asBytes(&self.expand_resolve));
        hasher.update(std.mem.asBytes(&self.has_pls));
        hasher.update(std.mem.asBytes(&self.storage_attachment_slot_count));
        hasher.update(std.mem.asBytes(&self.storage_attachment_slots));
        return hasher.final();
    }

    /// The hash seed. Dawn has no equivalent — it hashes with the process's
    /// default — and the port fixes it so two runs of the same stream produce
    /// the same cache key, which is the determinism rule
    /// (`AGENTS.md` §3).
    const attachment_state_hash_seed: u64 = 0x6465_7363_0E15_0001;

    fn fromSlots(slots: []const SlotShape) AttachmentState {
        var self: AttachmentState = .{};
        for (slots, 0..) |slot, index| {
            if (index < constants.max_color_attachments) {
                if (slot.format != 0) {
                    self.color_attachments_set |= @as(u8, 1) << @intCast(index);
                    self.color_formats[index] = slot.format;
                    self.sample_count = slot.sample_count;
                }
                continue;
            }
            if (self.storage_attachment_slot_count >= constants.max_storage_attachments_per_render_pass) {
                // The caller named more storage slots than the device limit
                // allows. `AttachmentState::fromRenderBundle` has no error in
                // Dawn because the descriptor was validated first; the port's
                // validation of that bound is M14's, and a slot past the limit
                // is dropped rather than recorded, so the state cannot claim
                // storage it does not have.
                break;
            }
            self.storage_attachment_slots[self.storage_attachment_slot_count] = slot.format;
            self.storage_attachment_slot_count += 1;
            self.has_pls = true;
        }
        return self;
    }
};

/// What a render-pass descriptor and its per-slot answers did not agree
/// about.
///
/// This is not a `command` validation rule: a caller builds the per-slot
/// formats and sample counts from its own textures, and the lists must be the
/// same length before anything else is meaningful. Dawn has no counterpart,
/// because its constructor reads both off the views
/// (`src/dawn/native/AttachmentState.cpp:109`).
pub const AttachmentError = error{
    TooManyAttachments,
    PerSlotAnswersMissing,
};
