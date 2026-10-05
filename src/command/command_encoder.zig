//! The top-level command encoder: the one door a caller opens to record a
//! command buffer.
//!
//! **What this file is.** The port of `src/dawn/native/CommandEncoder.{h,cpp}`:
//! `encoding_context.Context` is the stream it records into,
//! `render_encoder_base.RenderEncoderBase` is the render half of a pass, and
//! this is the value a caller holds to open both. It records intent and holds
//! no Vulkan (`AGENTS.md` §3).
//!
//! **Why `init` is infallible.** `Context.init` is `AllocatorError!Context`
//! (`encoding_context.zig:88`), and an encoder is a value the caller keeps on
//! its own stack frame, so `init` has no error to hand back that the caller
//! could act on. `ensureContext` builds the context on the first record call
//! instead, where an allocation failure is returned to the caller that asked to
//! record something. Waiting costs nothing: the only `try` in `Context.init` is
//! `Allocator.init` (`allocator.zig:63`), and that returns a struct literal — the
//! first block comes from `appendNewBlock` (`allocator.zig:178`) on the first
//! `allocate`.
//!
//! **What this file does not claim.** It does not claim to be Dawn's
//! `CommandEncoder`. Dawn's is a refcounted object with an error sink and a
//! label; this is a value the caller owns with a declared error set, which is
//! the departure `render_encoder_base.zig:19-23` makes for the pass encoder. It
//! carries a render pass, the texture-to-buffer copy whose compressed-format
//! rule §M16 re-gates, and `finish`; a copy family with no rule behind it yet is
//! not spelled as a no-op here.

const std = @import("std");
const api = @import("../api/api.zig");
const allocator_mod = @import("allocator.zig");
const attachment_state = @import("attachment_state.zig");
const commands = @import("commands.zig");
const constants = @import("constants.zig");
const encoding_context = @import("encoding_context.zig");
const errors = @import("errors.zig");
const render_encoder_base = @import("render_encoder_base.zig");

/// Everything a call on this type can fail with: the arena's error set, which
/// is every rule this module owns plus the one allocation failure every record
/// call carries (`allocator.zig:234`), and the two descriptor-shape rules
/// `attachment_state` owns (`attachment_state.zig:234-235`).
pub const Error = allocator_mod.AllocatorError || attachment_state.AttachmentError;

/// The wire value the compressed run starts at. `dawn.json` numbers the three
/// compressed families — BC, ETC2/EAC and ASTC — contiguously after every
/// uncompressed one (`src/api/enums.zig:931-982`), so naming the run's two
/// ends names every member of it.
const first_compressed_format: u32 = @intFromEnum(api.TextureFormat.bc1_rgba_unorm);

/// The wire value it ends at, and its length in wire values.
const last_compressed_format: u32 = @intFromEnum(api.TextureFormat.astc_12x12_unorm_srgb);
const compressed_format_count: u32 = last_compressed_format - first_compressed_format + 1;

comptime {
    // The two checks are what make the run a claim and not a hope. The member
    // under it is the last uncompressed format (`src/api/enums.zig:930`), and
    // the domain holds the member count `src/api/enums.zig:986` records, so a
    // format added anywhere upstream stops the build here instead of being read
    // as uncompressed.
    if (first_compressed_format != @intFromEnum(api.TextureFormat.depth32_float_stencil8) + 1) {
        @compileError("a texture format appeared below the compressed run");
    }
    // 102, not upstream's 110: sixteen of Dawn's entries share a tag with an
    // earlier one and the generator drops the later of each pair, so the enum
    // has 110 - 8 = 102 fields over tags 0 to 101. Asserting the entry count
    // would fire on a correct regeneration.
    if (@typeInfo(api.TextureFormat).@"enum".fields.len != 102) {
        @compileError("a texture format appeared; classify it before the build passes");
    }
}

/// Whether a wire format names a compressed format.
///
/// Dawn reads the format object (`CommandEncoder.cpp:415`); the port cannot
/// reach the texture, so it reads the number it recorded, which is the same
/// fact for a replay and the same field the copy rule is keyed off.
fn isCompressed(format: u32) bool {
    // Wrapping on purpose: a value below the run subtracts into a number larger
    // than the run's length, which is the answer a value above it gets too.
    return format -% first_compressed_format < compressed_format_count;
}

/// What `beginRenderPass` takes.
///
/// The colour attachments are the recorded payload's own half
/// (`commands.zig:155-168`), so a caller fills a struct the stream already
/// names and the descriptor carries no second shape to keep in step.
pub const BeginRenderPassOptions = struct {
    color_attachments: []const commands.RenderPassColorAttachmentInfo = &.{},
    depth_stencil_attachment: commands.RenderPassDepthStencilAttachmentInfo = .{},
    /// The pass's size, which Dawn reads off the attachment views
    /// (`CommandEncoder.cpp:172`).
    width: u32 = 0,
    height: u32 = 0,
    /// Dawn's `RenderPassMaxDrawCount` (`RenderPassEncoder.h:121`), which the
    /// pass checks at `end` rather than at each draw.
    max_draw_count: u64 = constants.default_max_draw_count,
};

/// What `copyTextureToBuffer` takes.
///
/// Both halves are the recorded payload's own halves (`commands.zig:293-294`),
/// so the copy is recorded as it was described and the mapping is one assignment.
pub const CopyTextureToBufferOptions = struct {
    source: commands.TextureCopy,
    destination: commands.BufferCopy,
    copy_size: commands.Extent3D,
};

/// The top-level encoder: owns the context and hands out passes.
pub const CommandEncoder = struct {
    /// The allocator the context is built from. The context holds its own copy
    /// and frees with it; this one is what builds it on the first record call.
    allocator: std.mem.Allocator,
    /// The bytes one block of the stream starts at. `Allocator.init` raises it
    /// to whatever the widest payload needs (`allocator.zig:63-71`), so this is
    /// a granularity and not a bound. A page is the one size every allocator
    /// below `command` hands back whole.
    block_size: usize,
    compatibility_mode: bool,
    /// The context, once a record call has created it. See the file header for
    /// why `init` does not build it.
    context: ?encoding_context.Context = null,
    /// Which encoder records the top-level commands. Zero until the context
    /// exists.
    top_level: encoding_context.EncoderId = encoding_context.no_encoder,

    pub const Options = struct {
        /// Dawn derives the profile from the absence of a feature
        /// (`Device.cpp:1840-1842`), and `command` cannot reach a device, so
        /// the caller passes the fact.
        compatibility_mode: bool = false,
        block_size: usize = 4096,
    };

    /// Dawn's `CommandEncoder::Create` (`CommandEncoder.cpp:1339`), minus the
    /// device and minus the error.
    pub fn init(allocator: std.mem.Allocator, options: Options) CommandEncoder {
        return .{
            .allocator = allocator,
            .block_size = options.block_size,
            .compatibility_mode = options.compatibility_mode,
        };
    }

    /// Dawn's `CommandEncoder::DestroyImpl` (`CommandEncoder.cpp:1372`): drain
    /// the context and release every list it owns.
    ///
    /// `allocator` is the one `init` took, and the context frees the blocks
    /// with the copy it holds. The parameter says which allocator those blocks
    /// came from, which is the pairing a caller gets wrong silently. The check
    /// is on the vtable rather than on the whole value because `ptr` may be
    /// `undefined` for an allocator that has no state
    /// (`lib/std/mem/Allocator.zig:16-19`), so an implementation swap is caught
    /// here and an instance swap is not.
    pub fn deinit(self: *CommandEncoder, allocator: std.mem.Allocator) void {
        std.debug.assert(allocator.vtable == self.allocator.vtable);
        if (self.context) |*context| context.deinit();
        self.* = undefined;
    }

    /// Dawn's `APIBeginRenderPass` (`CommandEncoder.cpp:1460`) then `BeginRenderPass`
    /// (`:1467`): commit what came before the pass, record the pass's own
    /// descriptor on the top-level encoder, then enter the pass. This is the
    /// call both acceptance shards record through.
    ///
    /// The set is `errors.Error || attachment_state.AttachmentError`, and not
    /// the module's `Error`: `encodeTopLevel` is declared `errors.Error`
    /// (`encoding_context.zig:192-197`), so a `try` on it inherits the lifecycle
    /// rules `core.Error` owns and `Error` cannot name — `EncoderAlreadyFinished`
    /// is the one only `core` has (`core/errors.zig:24`). `ensureContext` is
    /// declared `Error`, and the body raises `TooManyAttachments` of its own
    /// (`attachment_state.zig:234-235`).
    pub fn beginRenderPass(
        self: *CommandEncoder,
        options: BeginRenderPassOptions,
    ) (errors.Error || attachment_state.AttachmentError)!render_encoder_base.RenderEncoderBase {
        // `max_color_attachments` is the bound (`Constants.h:43`) and the
        // descriptor rule for naming more than it is the error, so the loop is
        // bounded rather than the caller.
        var recorded =
            [_]commands.RenderPassColorAttachmentInfo{.{}} ** constants.max_color_attachments;
        var count: usize = 0;
        for (options.color_attachments) |attachment| {
            if (count == recorded.len) return error.TooManyAttachments;
            recorded[count] = attachment;
            count += 1;
        }

        const context = try self.ensureContext();
        try context.willBeginRenderPass();

        const begin = try context.encodeTopLevel(
            commands.BeginRenderPassCmd,
            self.top_level,
            .begin_render_pass,
        );
        begin.* = .{
            .color_attachments = recorded,
            .depth_stencil_attachment = options.depth_stencil_attachment,
            .width = options.width,
            .height = options.height,
        };

        var pass = try render_encoder_base.RenderEncoderBase.init(
            self.allocator,
            context,
            self.compatibility_mode,
        );
        pass.max_draw_count = options.max_draw_count;
        return pass;
    }

    /// Dawn's `APICopyTextureToBuffer` (`CommandEncoder.cpp:1956`) with the
    /// compatibility-mode format rule in front of it (`CommandEncoder.cpp:413`).
    ///
    /// The rule is keyed off the recorded wire format because that is the field
    /// a replay reads, and `command` cannot reach the texture object.
    ///
    /// The set is the one `beginRenderPass` declares above, for the same two
    /// reasons: `encodeTopLevel` brings in the half of `errors.Error` that
    /// `core.Error` owns, and `ensureContext` brings in `AttachmentError`, which
    /// this body cannot raise and inherits anyway. `CompressedTextureCopy` is
    /// already in `errors.Error` (`errors.zig:97`).
    pub fn copyTextureToBuffer(
        self: *CommandEncoder,
        options: CopyTextureToBufferOptions,
    ) (errors.Error || attachment_state.AttachmentError)!void {
        if (self.compatibility_mode and isCompressed(options.source.format)) {
            return error.CompressedTextureCopy;
        }
        const context = try self.ensureContext();
        const cmd = try context.encodeTopLevel(
            commands.CopyTextureToBufferCmd,
            self.top_level,
            .copy_texture_to_buffer,
        );
        cmd.* = .{
            .source = options.source,
            .destination = options.destination,
            .copy_size = options.copy_size,
        };
    }

    /// Dawn's `APIFinish` (`CommandEncoder.cpp:2406`): the blocks, the usages
    /// and the status leave together, so one door is enough. `engine` turns what
    /// comes back into a command buffer at M18.
    pub fn finish(self: *CommandEncoder) Error!encoding_context.Finished {
        const context = try self.ensureContext();
        return context.finish();
    }

    /// The context, built on the first record call. A record after `finish` is
    /// refused by the context's own status machine (`encoding_context.zig:151-155`),
    /// which is why this holds no finished flag of its own.
    fn ensureContext(self: *CommandEncoder) Error!*encoding_context.Context {
        if (self.context == null) {
            self.context = try encoding_context.Context.init(
                self.allocator,
                self.block_size,
                self.compatibility_mode,
            );
            self.top_level = self.context.?.open();
        }
        return &self.context.?;
    }
};
