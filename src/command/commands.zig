//! The 38-value command tag enum, the payload of each tag, and the two
//! exhaustive switches over them.
//!
//! **What this file is.** The port of `src/dawn/native/Commands.h` and the two
//! exhaustive switches of `src/dawn/native/Commands.cpp`. Dawn's stream is a
//! flat `(u32 tag, POD struct)` byte arena with eight-byte alignment and no
//! per-type size table (`docs/02-dawn-design.md` §4.3); the framing lives in
//! `allocator.zig` and this file holds what goes into it.
//!
//! **What this file does not claim.** It does not claim wire compatibility with
//! Dawn. Dawn's payloads are C++ structs with a compiler-chosen layout
//! (`DrawCmd` is `four uint32_t`, `SetViewportCmd` is `six float`), and a
//! WebGPU wire format is not a promise here — `docs/30-port-design.md` §4.3
//! says so for the descriptors, and the same holds for the command stream.
//! What the port does keep is the *framing*: tag, aligned payload, and a
//! counted run behind `additional_data` for the six variable-length tags.
//!
//! It does not claim `Ref<T>`'s reference counting. Dawn's `Ref<T>` keeps an
//! object alive while a command buffer names it
//! (`src/dawn/native/CommandAllocator.h:82-83` records the problem). The port's
//! arena owns every object until the device is destroyed
//! (`docs/10-architecture.md`, "Object model"), so a payload holds a pointer
//! into the arena and nothing else. The queue ordering that keeps a command
//! buffer from outliving its device is M18's rule.

const std = @import("std");
const allocator_mod = @import("allocator.zig");
const constants = @import("constants.zig");
const errors = @import("errors.zig");

// --- the recorded value types ------------------------------------------------
//
// `docs/10-architecture.md` fixes the dependency direction as
// `command -> core, memory`, so `command` does not import `api`. The wire
// values below are the ones `src/dawn/dawn.json` fixes and
// `src/api/enums.zig` already emits; `engine` converts between the two enums
// with an exhaustive switch, which is where a value change becomes a compile
// error.

/// What happens to an attachment before the pass. `dawn.json` "load op".
pub const LoadOp = enum(u32) { undefined_ = 0, load = 1, clear = 2, expand_resolve_texture = 3 };

/// What happens to an attachment after the pass. `dawn.json` "store op".
pub const StoreOp = enum(u32) { undefined_ = 0, store = 1, discard = 2 };

/// The width of one index. `dawn.json` "index format".
pub const IndexFormat = enum(u32) { undefined_ = 0, uint16 = 1, uint32 = 2 };

/// Which part of a depth-stencil texture an operation touches. `dawn.json`
/// "texture aspect".
pub const TextureAspect = enum(u32) { undefined_ = 0, all = 1, stencil_only = 2, depth_only = 3 };

/// How many samples a texture holds. `dawn.json` "texture dimension".
pub const TextureDimension = enum(u32) { undefined_ = 0, _1d = 1, _2d = 2, _3d = 3 };

/// The index meaning "this pass wrote no timestamp here". Dawn writes
/// `kQuerySetIndexUndefinedTyped` (`src/dawn/native/Commands.h:101-102`).
pub const undefined_query_index: u32 = 0xFFFF_FFFF;

/// A pointer into the device arena. One type for every object a command
/// names: the tag fixes the pointee, so the payload cannot be read as the
/// wrong kind of object. See the file header for why there is no refcount.
pub const Ref = ?*anyopaque;

/// An RGBA clear or blend value. `dawn.json` "color".
pub const Color = struct { r: f32, g: f32, b: f32, a: f32 };

/// A size in texels, blocks or rows. `dawn.json` "texel extent 3d".
pub const Extent3D = struct { width: u32, height: u32, depth_or_array_layers: u32 };

/// A position in texels or array layers. `dawn.json` "origin 3d".
pub const Origin3D = struct { x: u32, y: u32, z: u32 };

// --- the tag enum ------------------------------------------------------------

/// The command tags, in Dawn's order (`src/dawn/native/Commands.h:55-94`).
///
/// The order is by kind, not by stream position. A pass's commands land in
/// whatever order the encoder emitted them, so nothing may depend on a tag's
/// value being near its neighbours.
///
/// The wire values *are* Dawn's, because the enum is written in the same
/// order and the stream stores the number. That is a convenience, not the
/// compatibility claim the file header rules out: a version of Dawn that
/// inserted a tag would renumber this enum, and `docs/50-verification.md` owns
/// any fixture that would catch it.
pub const Tag = enum(u32) {
    begin_compute_pass,
    begin_occlusion_query,
    begin_render_pass,
    clear_buffer,
    copy_buffer_to_buffer,
    copy_buffer_to_texture,
    copy_texture_to_buffer,
    copy_texture_to_texture,
    dispatch,
    dispatch_indirect,
    draw,
    draw_indexed,
    draw_indirect,
    draw_indexed_indirect,
    multi_draw_indirect,
    multi_draw_indexed_indirect,
    end_compute_pass,
    end_occlusion_query,
    end_render_pass,
    execute_bundles,
    insert_debug_marker,
    pixel_local_storage_barrier,
    pop_debug_group,
    push_debug_group,
    resolve_query_set,
    set_compute_pipeline,
    set_render_pipeline,
    set_stencil_reference,
    set_viewport,
    set_scissor_rect,
    set_blend_constant,
    set_bind_group,
    set_immediates,
    set_index_buffer,
    set_vertex_buffer,
    set_resource_table,
    write_buffer,
    write_timestamp,
};

/// How many tags the enum has. Dawn has 38 (`Commands.h:55-94`); the count is a
/// number in the file so `test/command_stream.zig` can assert it and a tag
/// added upstream cannot pass unnoticed.
pub const tag_count: usize = @typeInfo(Tag).@"enum".fields.len;

comptime {
    if (tag_count != 38) @compileError("the command tag count moved from Dawn's 38");
    // The two sentinels live above every real tag, so a raw id can tell them
    // apart without a second domain (`CommandAllocator.h:91-92`).
    if (constants.end_of_block <= tag_count - 1) @compileError("the sentinels must outrank every tag");
}

// --- helper structs ----------------------------------------------------------

/// The query set a pass writes its two timestamps into
/// (`src/dawn/native/Commands.h:96-103`).
pub const TimestampWrites = struct {
    query_set: Ref = null,
    beginning_of_pass_write_index: u32 = undefined_query_index,
    end_of_pass_write_index: u32 = undefined_query_index,

    pub fn isEmpty(self: TimestampWrites) bool {
        return self.query_set == null;
    }
};

/// One colour attachment of a render pass (`Commands.h:121-131`).
pub const RenderPassColorAttachmentInfo = struct {
    view: Ref = null,
    depth_slice: u32 = 0,
    resolve_target: Ref = null,
    load_op: LoadOp = .undefined_,
    store_op: StoreOp = .undefined_,
    clear_color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },

    /// Dawn's `AttachmentState` counts a colour attachment as present when the
    /// view is set, and the port's hash and equality must agree with it.
    pub fn isPresent(self: RenderPassColorAttachmentInfo) bool {
        return self.view != null;
    }
};

/// The depth-stencil attachment (`Commands.h:143-156`). The two aspects carry
/// their own load and store ops and their own read-only flags, which is why
/// this is one struct and not two.
pub const RenderPassDepthStencilAttachmentInfo = struct {
    view: Ref = null,
    depth_load_op: LoadOp = .undefined_,
    depth_store_op: StoreOp = .undefined_,
    stencil_load_op: LoadOp = .undefined_,
    stencil_store_op: StoreOp = .undefined_,
    clear_depth: f32 = 0,
    clear_stencil: u32 = 0,
    depth_read_only: bool = false,
    stencil_read_only: bool = false,
};

/// The sub-rectangle a partial resolve updates (`Commands.h:158-169`).
pub const ResolveRect = struct {
    color_offset_x: u32 = 0,
    color_offset_y: u32 = 0,
    resolve_offset_x: u32 = 0,
    resolve_offset_y: u32 = 0,
    update_width: u32 = 0,
    update_height: u32 = 0,

    /// Dawn's `ResolveRect::HasValue` (`Commands.h:168`): a partial resolve is
    /// valid only when both extents are non-zero, so a caller that left the
    /// rect at its default asks for the whole attachment.
    pub fn hasValue(self: ResolveRect) bool {
        return self.update_width != 0 and self.update_height != 0;
    }
};

/// The rectangle a render pass scissored to (`Commands.h:171-177`).
pub const RenderAreaRect = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// The buffer half of a copy to or from a texture (`Commands.h:208-218`).
/// Dawn reads the block count from the texture; the port records it, because
/// `command` cannot reach the texture object.
pub const BufferCopy = struct {
    buffer: Ref = null,
    offset: u64 = 0,
    blocks_per_row: u64 = 0,
    rows_per_image: u64 = 0,
};

/// The texture half of a copy (`Commands.h:220-232`). The format, the
/// dimension, the full extent and the block shape are all recorded rather than
/// read back later, so both the copy rules and the replay work from the
/// stream alone.
pub const TextureCopy = struct {
    texture: Ref = null,
    mip_level: u32 = 0,
    origin: Origin3D = .{ .x = 0, .y = 0, .z = 0 },
    aspect: TextureAspect = .undefined_,
    format: u32 = 0,
    dimension: TextureDimension = .undefined_,
    /// The texture's size at `mip_level`, which is the bound the copy extent
    /// is checked against.
    extent: Extent3D = .{ .width = 0, .height = 0, .depth_or_array_layers = 0 },
    /// The compressed block's size in texels, 1 for an uncompressed format.
    block_width: u32 = 1,
    block_height: u32 = 1,
};

// --- the payloads ------------------------------------------------------------

pub const BeginComputePassCmd = struct {
    timestamp_writes: TimestampWrites = .{},
    label_length: u32 = 0,
};

pub const BeginOcclusionQueryCmd = struct {
    query_set: Ref = null,
    query_index: u32 = undefined_query_index,
};

pub const BeginRenderPassCmd = struct {
    attachment_state: Ref = null,
    // The element type is spelled out because an inferred array literal leaves
    // the repeat's operand untyped, and an untyped `.{}` is an anonymous empty
    // struct that does not coerce to the attachment. Naming the element type
    // keeps `{}` the struct's own default value, so the field defaults above are
    // written once (`RenderPassColorAttachmentInfo`).
    color_attachments: [constants.max_color_attachments]RenderPassColorAttachmentInfo =
        [_]RenderPassColorAttachmentInfo{.{}} ** constants.max_color_attachments,
    depth_stencil_attachment: RenderPassDepthStencilAttachmentInfo = .{},
    width: u32 = 0,
    height: u32 = 0,
    force_full_render_area: bool = false,
    render_area: RenderAreaRect = .{},
    resolve_rect: ResolveRect = .{},
    msaa_render_to_single_sampled: bool = false,
    occlusion_query_set: Ref = null,
    timestamp_writes: TimestampWrites = .{},
    label_length: u32 = 0,
};

pub const ClearBufferCmd = struct {
    buffer: Ref = null,
    offset: u64 = 0,
    size: u64 = 0,
};

pub const CopyBufferToBufferCmd = struct {
    source: Ref = null,
    source_offset: u64 = 0,
    destination: Ref = null,
    destination_offset: u64 = 0,
    size: u64 = 0,
};

pub const CopyBufferToTextureCmd = struct {
    source: BufferCopy = .{},
    destination: TextureCopy = .{},
    copy_size: Extent3D = .{ .width = 0, .height = 0, .depth_or_array_layers = 0 },
};

pub const CopyTextureToBufferCmd = struct {
    source: TextureCopy = .{},
    destination: BufferCopy = .{},
    copy_size: Extent3D = .{ .width = 0, .height = 0, .depth_or_array_layers = 0 },
};

pub const CopyTextureToTextureCmd = struct {
    source: TextureCopy = .{},
    destination: TextureCopy = .{},
    copy_size: Extent3D = .{ .width = 0, .height = 0, .depth_or_array_layers = 0 },
};

pub const DispatchCmd = struct { x: u32 = 0, y: u32 = 0, z: u32 = 0 };

pub const DispatchIndirectCmd = struct { indirect_buffer: Ref = null, indirect_offset: u64 = 0 };

pub const DrawCmd = struct {
    vertex_count: u32 = 0,
    instance_count: u32 = 0,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
};

pub const DrawIndexedCmd = struct {
    index_count: u32 = 0,
    instance_count: u32 = 0,
    first_index: u32 = 0,
    base_vertex: i32 = 0,
    first_instance: u32 = 0,
};

pub const DrawIndirectCmd = struct { indirect_buffer: Ref = null, indirect_offset: u64 = 0 };

/// Dawn's `DrawIndexedIndirectCmd` inherits `DrawIndirectCmd`
/// (`Commands.h:306`); the port reuses the struct and keeps two tags.
pub const DrawIndexedIndirectCmd = DrawIndirectCmd;

pub const MultiDrawIndirectCmd = struct {
    indirect_buffer: Ref = null,
    indirect_offset: u64 = 0,
    max_draw_count: u32 = 0,
    draw_count_buffer: Ref = null,
    draw_count_offset: u64 = 0,
};

/// Dawn's `MultiDrawIndexedIndirectCmd` inherits `MultiDrawIndirectCmd`
/// (`Commands.h:319`); the port reuses the struct and keeps two tags.
pub const MultiDrawIndexedIndirectCmd = MultiDrawIndirectCmd;

pub const EndComputePassCmd = struct {};

pub const EndOcclusionQueryCmd = struct {
    query_set: Ref = null,
    query_index: u32 = undefined_query_index,
};

pub const EndRenderPassCmd = struct {};

pub const ExecuteBundlesCmd = struct { count: u32 = 0 };

pub const InsertDebugMarkerCmd = struct { length: u32 = 0 };

pub const PixelLocalStorageBarrierCmd = struct {};

pub const PopDebugGroupCmd = struct {};

pub const PushDebugGroupCmd = struct { length: u32 = 0 };

pub const ResolveQuerySetCmd = struct {
    query_set: Ref = null,
    first_query: u32 = undefined_query_index,
    query_count: u32 = 0,
    destination: Ref = null,
    destination_offset: u64 = 0,
};

pub const SetComputePipelineCmd = struct { pipeline: Ref = null };

/// Dawn records the pipeline at
/// `src/dawn/native/CommandBufferStateTracker.cpp:846-849` and reads its
/// attachment state back off that pointer at
/// `src/dawn/native/RenderEncoderBase.cpp:551-556`. The port records the
/// interned attachment state too, so the replay never has to read a pipeline
/// object back out of the arena.
pub const SetRenderPipelineCmd = struct { pipeline: Ref = null, attachment_state: Ref = null };

pub const SetStencilReferenceCmd = struct { reference: u32 = 0 };

pub const SetViewportCmd = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    min_depth: f32 = 0,
    max_depth: f32 = 0,
};

pub const SetScissorRectCmd = struct { x: u32 = 0, y: u32 = 0, width: u32 = 0, height: u32 = 0 };

pub const SetBlendConstantCmd = struct { color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } };

/// The dynamic offsets follow the payload as a `u32` run of
/// `dynamic_offset_count`. Dawn writes the run only when the count is above
/// zero (`src/dawn/native/ProgrammableEncoder.cpp:236-238`), so a count of
/// zero means no run and `nextData` must not be called.
pub const SetBindGroupCmd = struct {
    index: u32 = 0,
    group: Ref = null,
    dynamic_offset_count: u32 = 0,
};

pub const SetImmediatesCmd = struct { offset: u32 = 0, size: u32 = 0 };

/// `buffer_size` is the whole buffer, and `size` is the bound the pass reads.
/// Dawn resolves `kWholeSize` inside the record lambda
/// (`src/dawn/native/RenderEncoderBase.cpp:682-684`) and reads
/// `buffer->GetSize()` in the validator (`:664`). The port records both
/// numbers, so the range rule and the replay both work without the engine.
pub const SetVertexBufferCmd = struct {
    slot: u32 = 0,
    buffer: Ref = null,
    buffer_size: u64 = 0,
    offset: u64 = 0,
    size: u64 = 0,
};

pub const SetIndexBufferCmd = struct {
    buffer: Ref = null,
    buffer_size: u64 = 0,
    format: IndexFormat = .undefined_,
    offset: u64 = 0,
    size: u64 = 0,
};

pub const SetResourceTableCmd = struct { table: Ref = null };

/// The bytes follow the payload as a `u8` run of `size`.
pub const WriteBufferCmd = struct {
    buffer: Ref = null,
    offset: u64 = 0,
    size: u32 = 0,
};

pub const WriteTimestampCmd = struct {
    query_set: Ref = null,
    query_index: u32 = undefined_query_index,
};

// --- the two exhaustive switches ---------------------------------------------

/// The payload type of a tag. One function, one switch, 38 arms: a tag added
/// to the enum without a payload is a compile error.
///
/// Dawn has no equivalent, because its C++ switch in `Commands.cpp` names the
/// type in each arm. Hoisting the name into one function is what lets
/// `allocator.zig` size a payload from its tag.
pub fn Payload(comptime tag: Tag) type {
    return switch (tag) {
        .begin_compute_pass => BeginComputePassCmd,
        .begin_occlusion_query => BeginOcclusionQueryCmd,
        .begin_render_pass => BeginRenderPassCmd,
        .clear_buffer => ClearBufferCmd,
        .copy_buffer_to_buffer => CopyBufferToBufferCmd,
        .copy_buffer_to_texture => CopyBufferToTextureCmd,
        .copy_texture_to_buffer => CopyTextureToBufferCmd,
        .copy_texture_to_texture => CopyTextureToTextureCmd,
        .dispatch => DispatchCmd,
        .dispatch_indirect => DispatchIndirectCmd,
        .draw => DrawCmd,
        .draw_indexed => DrawIndexedCmd,
        .draw_indirect => DrawIndirectCmd,
        .draw_indexed_indirect => DrawIndexedIndirectCmd,
        .multi_draw_indirect => MultiDrawIndirectCmd,
        .multi_draw_indexed_indirect => MultiDrawIndexedIndirectCmd,
        .end_compute_pass => EndComputePassCmd,
        .end_occlusion_query => EndOcclusionQueryCmd,
        .end_render_pass => EndRenderPassCmd,
        .execute_bundles => ExecuteBundlesCmd,
        .insert_debug_marker => InsertDebugMarkerCmd,
        .pixel_local_storage_barrier => PixelLocalStorageBarrierCmd,
        .pop_debug_group => PopDebugGroupCmd,
        .push_debug_group => PushDebugGroupCmd,
        .resolve_query_set => ResolveQuerySetCmd,
        .set_compute_pipeline => SetComputePipelineCmd,
        .set_render_pipeline => SetRenderPipelineCmd,
        .set_stencil_reference => SetStencilReferenceCmd,
        .set_viewport => SetViewportCmd,
        .set_scissor_rect => SetScissorRectCmd,
        .set_blend_constant => SetBlendConstantCmd,
        .set_bind_group => SetBindGroupCmd,
        .set_immediates => SetImmediatesCmd,
        .set_index_buffer => SetIndexBufferCmd,
        .set_vertex_buffer => SetVertexBufferCmd,
        .set_resource_table => SetResourceTableCmd,
        .write_buffer => WriteBufferCmd,
        .write_timestamp => WriteTimestampCmd,
    };
}

/// The element type of the counted run that follows a tag's payload, or `void`
/// when the tag carries none.
///
/// Dawn decides this in the body of `FreeCommands` and again in the body of
/// `SkipCommand`, in six places each. The port decides it in one switch, so
/// the allocator, the skipper and the free path cannot disagree about which
/// tags have trailing data.
pub fn DataElement(comptime tag: Tag) type {
    return switch (tag) {
        // A string is copied with its terminator, so the run is bytes
        // (`Commands.cpp:433-448`).
        .insert_debug_marker, .push_debug_group, .set_immediates, .write_buffer => u8,
        // Only above zero: Dawn writes no run for an empty dynamic-offset list.
        .set_bind_group => u32,
        .execute_bundles => Ref,
        else => void,
    };
}

/// Dawn's `SkipCommand` (`Commands.cpp:259-431`): advance past one command,
/// including its run, without interpreting it.
///
/// The port returns an error instead of asserting. Dawn asserts because only
/// Dawn writes the stream; the port's stream is input at M18, and a walk that
/// runs off the end is a refused input rather than a crash.
pub fn skip(iterator: *allocator_mod.Iterator, tag: Tag) errors.Error!void {
    const payload = Payload(tag);
    const cmd = try iterator.nextCommand(payload);
    const element = DataElement(tag);
    if (element == void) return;

    // `set_bind_group` writes its run only above a zero count
    // (`programmable_encoder.zig:155-158`), so the count in the payload decides
    // whether there is anything to skip. Every other tag wrote a run.
    const count: usize = switch (tag) {
        .insert_debug_marker, .push_debug_group => cmd.label_length + 1,
        .set_immediates, .write_buffer => cmd.size,
        .set_bind_group => cmd.dynamic_offset_count,
        .execute_bundles => cmd.count,
        else => unreachable,
    };
    // Dawn's skipper guards the same way (`Commands.cpp:392-397`): `nextData`
    // consumes a tag before it reads a byte, so a bind group with no dynamic
    // offsets would eat the next command's tag and report a truncation the
    // stream does not hold. Only this tag guards, because it is the only one
    // whose run is conditional.
    if (tag == .set_bind_group and count == 0) return;
    _ = try iterator.nextData(element, count);
}

/// Dawn's `AddNullTerminatedString` (`Commands.cpp:433-448`): copy `text` into
/// the stream with a terminator, and write the length including that
/// terminator into `length`.
///
/// The count in the payload is the byte count *including* the terminator, so a
/// reader never has to search for one.
pub fn addNullTerminatedString(
    arena: *allocator_mod.Allocator,
    text: []const u8,
    length: *u32,
) errors.Error!void {
    const count = text.len + 1;
    if (count > std.math.maxInt(u32)) return error.CopyExtentOutOfRange;
    length.* = @intCast(count);
    const out = try arena.allocateData(u8, count);
    @memcpy(out[0..text.len], text);
    out[text.len] = 0;
}

/// Dawn's `NextNullTerminatedString` (`Commands.cpp:450-454`): read back the
/// bytes a push or a marker wrote, without the terminator.
///
/// Public because `docs/40-plan.md` carries this as a port row: the replay
/// that reads a pushed label back is M18's, and the row records the shape
/// rather than a reachable path today.
pub fn nextNullTerminatedString(
    iterator: *allocator_mod.Iterator,
    length: u32,
) errors.Error![]const u8 {
    if (length == 0) return error.CommandStreamTruncated;
    const bytes = try iterator.nextData(u8, length);
    // Dawn asserts the terminator is where it wrote it (`Commands.cpp:452`).
    // The port refuses a stream that does not hold one, because a length that
    // does not match its bytes is the one corruption this framing cannot
    // otherwise detect.
    //
    // The subscript counts from `length`, not from `bytes.len`, so the `length
    // == 0` refusal above is the guard this read needs: `length` is at least
    // one here, so `length - 1` names the last byte and never underflows.
    if (bytes[length - 1] != 0) return error.CommandStreamTruncated;
    return bytes[0 .. length - 1];
}
