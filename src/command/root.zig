//! `command`: the command stream, the encoders, the passes and pass-level
//! validation.
//!
//! **What this module is.** `docs/10-architecture.md` "Module boundaries" gives
//! `command` the stream, the encoders, the passes and the validation that runs
//! against recorded state rather than against live objects. It records intent:
//! a tag, an aligned payload and, for the six variable-length tags, a counted
//! run. `AGENTS.md` §3 requires it to hold no Vulkan at all, and it does — the
//! back end replays what this module recorded.
//!
//! **What this module does not claim.** It does not claim to execute anything.
//! A recorded stream is worth nothing until `engine` replays it into `vk`, and
//! nothing here calls a Vulkan entry point. It also does not claim to know what
//! a texture is: a payload names an arena pointer and records the format, the
//! extent and the block shape, so the copy rules and the replay both work from
//! the stream alone.
//!
//! **What it does not claim either.** It does not claim wire compatibility with
//! Dawn's `Commands.h`. Ordinary resource references are borrowed until native
//! admission; stable arena headers alone do not keep their payloads alive.
//! Render usages own canonical attachment leases and move them into Finished.
//!
//! **How to read this file.** Every sibling is re-exported under its own file
//! name, so the whole surface of a file is reachable as `command.<file_name>`
//! and nothing here has to be kept in step when a file grows. A name is also
//! re-exported flat when a consumer outside this module already reaches it that
//! way; `test/compatibility.zig` is the only one today.

// --- the framing -----------------------------------------------------------

/// `allocator.zig`: the bump arena the stream is written into, and the cursor
/// that walks it.
pub const allocator = @import("allocator.zig");
/// `constants.zig`: the limits the stream enforces itself and the ones it is
/// told, with the two stream sentinels above every real tag.
pub const constants = @import("constants.zig");

// --- the recorded values ---------------------------------------------------

/// `commands.zig`: the command tags, their payloads, and exhaustive traversal.
pub const commands = @import("commands.zig");

/// `errors.zig`: the validation rules only this module can raise, and what a
/// call can report. Both sets are declared, so a caller matches a rule and
/// never a message.
pub const errors = @import("errors.zig");

/// Every failure mode a call on this module's surface can report.
pub const Error = errors.Error;

// --- the encoders and their lifetimes --------------------------------------

/// `encoding_context.zig`: the encoder-lifetime state machine every record
/// call passes through.
pub const encoding_context = @import("encoding_context.zig");
/// `programmable_encoder.zig`: what every pass encoder can do, the debug-group
/// stack, bind groups and immediates.
pub const programmable_encoder = @import("programmable_encoder.zig");
/// `render_encoder_base.zig`: the render half of a pass encoder, with the
/// pipelines, the vertex and index buffers and the six draw forms.
pub const render_encoder_base = @import("render_encoder_base.zig");
/// Validated compute-pass producers and per-dispatch resource usage.
pub const compute_encoder = @import("compute_encoder.zig");
pub const ComputeEncoder = compute_encoder.ComputeEncoder;
/// Render-bundle producers and immutable recorded bundles.
pub const render_bundle = @import("render_bundle.zig");
pub const RenderBundleEncoder = render_bundle.RenderBundleEncoder;
pub const RenderBundle = render_bundle.RenderBundle;

// --- the top-level door into the stream -------------------------------------

/// `command_encoder.zig`: the value a caller holds to record a command
/// buffer, and the calls it makes — a render pass, the copy whose
/// compressed-format rule §M16 re-gates, and `finish`.
pub const command_encoder = @import("command_encoder.zig");
pub const CommandEncoder = command_encoder.CommandEncoder;

// --- the recorded state validation runs against ----------------------------

/// `state_tracker.zig`: the cache that answers "may this command run, given the
/// state the pass is in".
pub const state_tracker = @import("state_tracker.zig");
/// Pure render compatibility metadata and its canonical core owner.
pub const attachment_state = @import("attachment_state.zig");
pub const CanonicalAttachmentState = attachment_state.CanonicalAttachmentState;
/// `usage.zig`: which resources a pass touches and how, so a back end can raise
/// barriers without re-deriving it.
pub const usage = @import("usage.zig");
/// `validation_utils.zig`: the checks every float and colour a pass records
/// has to pass.
pub const validation_utils = @import("validation_utils.zig");

/// One texture a pass bound, as the recorded state tracker holds it.
pub const TextureBinding = state_tracker.TextureBinding;

// --- the indirect draws and the queries ------------------------------------

/// `indirect_draw.zig`: every indirect draw a pass issued, so the back end can
/// read back what it wrote.
pub const indirect_draw = @import("indirect_draw.zig");
/// `query.zig`: the rules a query descriptor, a query pass and a resolve each
/// break.
pub const query = @import("query.zig");

// --- the blits upstream emulates with a pass -------------------------------

/// `blit_texture_to_buffer.zig`: the compute-pass emulation of
/// `vkCmdCopyImageToBuffer`.
pub const blit_texture_to_buffer = @import("blit_texture_to_buffer.zig");
/// `blit_buffer_to_texture.zig`: the render-pass emulation of
/// `vkCmdCopyBufferToImage`.
pub const blit_buffer_to_texture = @import("blit_buffer_to_texture.zig");
/// `blit_depth_to_depth.zig`: the render-pass emulation of a depth copy into a
/// non-zero destination subresource.
pub const blit_depth_to_depth = @import("blit_depth_to_depth.zig");
/// `blit_color_to_color_with_draw.zig`: the colour operations upstream emulates
/// with a draw.
pub const blit_color_to_color_with_draw = @import("blit_color_to_color_with_draw.zig");
/// `blit_buffer_to_depth_stencil.zig`: the depth and stencil stages upstream
/// emulates with a draw.
pub const blit_buffer_to_depth_stencil = @import("blit_buffer_to_depth_stencil.zig");
