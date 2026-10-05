//! The validation rules only the command path can raise.
//!
//! **What this file is.** `docs/30-port-design.md` §2.1 puts every rule in a
//! Zig error set so a caller matches a rule and not a message.
//! `core.ValidationError` holds the rules that are about an object, a
//! descriptor among them. The rules here are about a *recorded command* — a
//! draw that reads past a buffer, a pass whose attachments disagree with its
//! pipeline — and no module above `command` can raise them, because no
//! module above `command` records.
//!
//! **What this file does not claim.** It does not claim these names exist
//! upstream. Dawn has no message-id mechanism at this revision
//! (`docs/02-dawn-design.md` §4.8): its 772 `DAWN_INVALID_IF` sites each carry
//! their own text, and `grep -rn DrawVertexCount src/` over the pinned tree
//! returns nothing. `DrawVertexCount` is the port's own id, and the
//! `docs/40-plan.md` §M15 acceptance names it for that reason.
//!
//! It does not claim `core.message_table` renders these. That table is keyed
//! by `core.nameOf`, and a rule outside `core` has no key there. `describe`
//! is this module's own renderer, exhaustive over the set below, so a caller
//! still gets text and the set of rules and the set of sentences cannot drift.

const std = @import("std");
const core = @import("../core/root.zig");

/// A rule about a command. Each member is raised by exactly one function; the
/// row in `docs/40-plan.md` §M15 names it.
pub const CommandValidationError = error{
    /// A draw reads past the end of the vertex or instance buffer it names.
    /// Dawn's `ValidateBufferInRangeForVertexBuffer`
    /// (`src/dawn/native/CommandBufferStateTracker.cpp:405-446`).
    DrawVertexCount,
    /// An indexed draw reads past the end of the index buffer.
    /// Dawn's `ValidateIndexBufferInRange`
    /// (`src/dawn/native/CommandBufferStateTracker.cpp:498`).
    DrawIndexCount,
    /// A dispatch names more workgroups than the device limit allows. Dawn has
    /// no `ValidateDispatchWorkgroups`; the rule is the three per-axis
    /// `DAWN_INVALID_IF`s against `maxComputeWorkgroupsPerDimension` inside
    /// `ComputePassEncoder::APIDispatchWorkgroups`
    /// (`src/dawn/native/ComputePassEncoder.cpp:243-265`).
    DispatchWorkgroupCount,
    /// A pass issued more draws than the descriptor allows. Dawn has no
    /// `RenderPassEncoder::ValidateEnd`; the rule is the `mDrawCount >
    /// mMaxDrawCount` check inside `RenderPassEncoder::End`
    /// (`src/dawn/native/RenderPassEncoder.cpp:179-181`).
    DrawCountExceeded,
    /// The command needs a render or compute pipeline and none is set.
    /// Dawn reaches this through the aspect cache
    /// (`src/dawn/native/CommandBufferStateTracker.cpp:513`).
    MissingPipeline,
    /// The command needs a bind group at its index and none is set.
    MissingBindGroup,
    /// The command reads indices and no index buffer is set.
    MissingIndexBuffer,
    /// The command reads vertices and no vertex buffer covers its slot.
    MissingVertexBuffer,
    /// The pipeline uses bindless resources and no resource table is set.
    MissingResourceTable,
    /// The command reads an immediate slot the pipeline declares and nothing
    /// has written it. Dawn reaches this through the aspect cache
    /// (`src/dawn/native/CommandBufferStateTracker.cpp:593-597`).
    MissingImmediateData,
    /// A vertex buffer slot is above `max_vertex_buffers`. Dawn has no
    /// `ValidateSetVertexBuffer`; the rule is the `slot >= kMaxVertexBuffers`
    /// check inside `RenderEncoderBase::APISetVertexBuffer`
    /// (`src/dawn/native/RenderEncoderBase.cpp:649-651`) against
    /// `kMaxVertexBuffers` (`src/dawn/common/Constants.h:39`).
    VertexBufferSlotOutOfRange,
    /// A bind group index is above `max_bind_groups`.
    BindGroupIndexOutOfRange,
    /// Immediate data is above `max_immediate_data_bytes`.
    /// Dawn's `ValidateSetImmediates`
    /// (`src/dawn/native/ProgrammableEncoder.cpp:130`).
    ImmediateDataTooLarge,
    /// Immediate data does not start on a four-byte boundary.
    ImmediateDataUnaligned,
    /// Two views of one texture are used in one render pass. Dawn's
    /// `ValidateNoDifferentTextureViewsOnSameTexture`
    /// (`src/dawn/native/CommandBufferStateTracker.cpp:370`).
    ConflictingTextureViews,
    /// A pipeline's attachment format disagrees with the pass's. Dawn's
    /// `RenderEncoderBase::APISetPipeline` compares the pass's interned
    /// attachment state against the pipeline's (`src/dawn/native/RenderEncoderBase.cpp:551`).
    AttachmentFormatMismatch,
    /// A pipeline's sample count disagrees with the pass's.
    AttachmentSampleCountMismatch,
    /// A render pass was begun with no attachment at all.
    NoAttachmentInRenderPass,
    /// A resolve names an attachment slot the pass does not resolve.
    ResolveWithoutAttachment,
    /// A copy names a compressed format, which a copy can neither read nor
    /// write. Dawn has no `ValidateCopyTextureToTexture`; the rule is the
    /// `format.isCompressed` branch of `ValidateTextureCopyRange`
    /// (`src/dawn/native/CommandValidation.cpp:507-528`), which requires the
    /// origin and the extent to be whole compressed blocks.
    CompressedTextureCopy,
    /// A copy extent leaves the texture it names.
    CopyExtentOutOfRange,
    /// A viewport, a blend constant or a clear value carries a NaN or an
    /// infinity. Dawn's `ValidateFloat` (`src/dawn/native/ValidationUtils.cpp:34`).
    NonFiniteFloat,
    /// A debug group was popped that was never pushed, or an encoder ended
    /// with one open. Dawn's `ValidateProgrammableEncoderEnd`
    /// (`src/dawn/native/ProgrammableEncoder.cpp:74`).
    DebugGroupUnbalanced,
    /// The encoder has no open pass and the command needs one, or the pass it
    /// has is not the one the command names. Dawn's `ValidateCanEncodeOn`
    /// (`src/dawn/native/EncodingContext.h:150-186`).
    PassNotOpen,
    /// The pass this call belongs to has already ended. Dawn's same rule: the
    /// `mCurrentEncoder == passEncoder` identity check inside
    /// `EncodingContext::ExitRenderPass`
    /// (`src/dawn/native/EncodingContext.cpp:175-180`).
    PassEnded,
    /// The encoder has finished. `core.EncoderAlreadyFinished` covers a
    /// finished *command* encoder; this covers a finished *bundle* encoder,
    /// which `core` cannot name because it holds no core object.
    BundleEncoderFinished,
    /// An indirect buffer is smaller than the draw or dispatch it feeds.
    /// Dawn's `ComputePassEncoder::APIDispatchWorkgroupsIndirect`
    /// (`src/dawn/native/ComputePassEncoder.cpp:431-436`).
    IndirectBufferTooSmall,
    /// A timestamp write names an index outside its query set.
    TimestampIndexOutOfRange,
    /// The walk reached the end of the stream in the middle of a command.
    /// Dawn asserts this instead (`src/dawn/native/CommandAllocator.h:179`);
    /// the port reports it, because a stream the port did not write is input,
    /// and a decoder boundary is where input is refused.
    CommandStreamTruncated,
    /// A record was attempted on an encoder a previous failure already
    /// invalidated. Dawn's `ErrorInRecording` case
    /// (`src/dawn/native/EncodingContext.h:150-186`).
    EncoderInvalidated,
    /// A record was attempted on an encoder whose owner is gone. Dawn's
    /// `Destroyed` case at the same switch.
    EncoderDestroyed,
    /// A pass encoder recorded after the encoder that owns it finished. Dawn's
    /// `Finished` case for a non-top-level encoder
    /// (`src/dawn/native/EncodingContext.h:161-167`).
    ParentEncoderFinished,
    /// The command encoder was used while one of its passes is open. Dawn's
    /// `Open` case (`src/dawn/native/EncodingContext.h:176-178`).
    PassLocked,
    /// The object is the error query set a failed `createQuerySet` left behind.
    /// Dawn's `ErrorQuerySet` (`QuerySet.cpp:39-46`), whose only override is a
    /// `DestroyImpl` that is `DAWN_UNREACHABLE`. No accessor guards on
    /// `IsError`; the one test of it is `QuerySet.cpp:149`.
    QuerySetIsError,
    /// A query set is used after `destroy`. Dawn's `ValidateCanUseInSubmitNow`
    /// (`QuerySet.cpp:148-152`), which is a submit-time check and not a
    /// record-time one.
    QuerySetDestroyed,
    /// `beginOcclusionQuery` on a pass with no `occlusion_query_set`. Dawn's
    /// `RenderPassEncoder::APIBeginOcclusionQuery`
    /// (`RenderPassEncoder.cpp:444-445`).
    OcclusionQuerySetAbsent,
    /// `beginOcclusionQuery` names an index at or above the set's count. Dawn's
    /// same function (`RenderPassEncoder.cpp:449-452`).
    QueryIndexAboveCount,
    /// `beginOcclusionQuery` while one is open. Dawn's same function
    /// (`RenderPassEncoder.cpp:454-456`).
    OcclusionQueryAlreadyActive,
    /// `endOcclusionQuery` with none open. Dawn's `APIEndOcclusionQuery`
    /// (`RenderPassEncoder.cpp:479-503`).
    OcclusionQueryNotActive,
    /// A render pass ended with an occlusion query open. Dawn's
    /// `RenderPassEncoder::End` (`RenderPassEncoder.cpp:174-177`).
    OcclusionQueryUnterminated,
    /// The same query index written twice in one pass. Dawn's
    /// `ValidateQueryIndexOverwrite` (`RenderPassEncoder.cpp:56-64`).
    QueryIndexOverwritten,
    /// A timestamp query set is in the `occlusion_query_set` slot. Dawn's
    /// `ValidateRenderPassDescriptor` (`CommandEncoder.cpp:983-990`), which
    /// `BeginRenderPass` calls (`:1500`).
    QuerySetTypeMismatch,
    /// A resolve names a first query at or above the set's count. Dawn's
    /// `ValidateQuerySetResolve` (`CommandEncoder.cpp:1096`).
    ResolveFirstQueryAboveCount,
    /// A resolve names more queries than remain from its first query. Dawn's
    /// same function (`CommandEncoder.cpp:1101`).
    ResolveQueryCountAboveRemaining,
    /// A resolve destination offset is not a multiple of 256. Dawn's same
    /// function (`CommandEncoder.cpp:1106`) against `kQueryResolveAlignment`
    /// (`src/dawn/common/Constants.h:45`).
    ResolveDestinationOffsetUnaligned,
    /// A resolve destination is smaller than the range it must hold. Dawn's
    /// same function (`CommandEncoder.cpp:1113-1117`).
    ResolveDestinationTooSmall,
    /// A resolve destination was created without the query-resolve usage.
    /// Dawn's `APIResolveQuerySet` (`CommandEncoder.cpp:2320`).
    ResolveDestinationUsageMissing,
    /// The caller's run buffer is smaller than the resolve range needs. The
    /// port's own rule: a truncated plan would leave the destination holding
    /// whatever was in it before, so it is reported rather than applied.
    ResolveRunBufferTooSmall,
};

/// Everything a record call can fail with. A caller of `command` matches on
/// this set and never on a message.
///
/// `core.Error` names no allocation failure (`core/errors.zig:117`), but a
/// record call allocates: the payload and its trailing run come from the
/// pending allocator, a bind group appends to the pass's usage trackers, and
/// an indirect draw appends to the pass's metadata. `std.mem.Allocator.Error`
/// is here for the methods that `try` one of those: `setBindGroup`,
/// `setImmediates`, `pushDebugGroup`, `popDebugGroup` and `insertDebugMarker`
/// (`programmable_encoder.zig:185`, `:229`, `:234`, `:247`, `:253`), and
/// `setVertexBuffer`, `setIndexBuffer`, `setPipeline`, `draw`, `drawIndexed`,
/// the four indirect draws, `recordIndirect` and `recordMultiDrawIndirect`
/// (`render_encoder_base.zig:206`, `:228`, `:255`, `:298`, `:321`, `:344`,
/// `:355`, `:366`, `:378`, `:400`, `:423`).
pub const Error = core.Error || CommandValidationError || std.mem.Allocator.Error;

/// The sentence for each rule. Exhaustive by construction: the switch names
/// every member of `CommandValidationError`, so a rule added there without a
/// sentence here does not compile. A prong reads `error.Name` and not
/// `.Name`, because the operand is an error set and not an enum: 0.16 accepts
/// only the qualified form, and the bare form is an `@EnumLiteral()` the
/// error-set switch rejects.
pub fn describe(rule: CommandValidationError) []const u8 {
    return switch (rule) {
        error.DrawVertexCount => "the draw reads past the end of a vertex buffer it names",
        error.DrawIndexCount => "the draw reads past the end of the index buffer it names",
        error.DispatchWorkgroupCount => "the dispatch is above the device workgroup limit",
        error.DrawCountExceeded => "the pass issued more draws than its descriptor allows",
        error.MissingPipeline => "no pipeline is set for this command",
        error.MissingBindGroup => "no bind group is set at the index this command names",
        error.MissingIndexBuffer => "no index buffer is set for an indexed draw",
        error.MissingVertexBuffer => "no vertex buffer is set for the slot this draw reads",
        error.MissingResourceTable => "no resource table is set for a pipeline that needs one",
        error.MissingImmediateData => "no immediate data was written for a slot the pipeline reads",
        error.VertexBufferSlotOutOfRange => "the vertex buffer slot is above the maximum",
        error.BindGroupIndexOutOfRange => "the bind group index is above the maximum",
        error.ImmediateDataTooLarge => "the immediate data is larger than the maximum",
        error.ImmediateDataUnaligned => "the immediate data does not start on a four-byte boundary",
        error.ConflictingTextureViews => "two views of one texture are used in one render pass",
        error.AttachmentFormatMismatch => "the pipeline and the pass disagree on an attachment format",
        error.AttachmentSampleCountMismatch => "the pipeline and the pass disagree on a sample count",
        error.NoAttachmentInRenderPass => "the render pass has no attachment",
        error.ResolveWithoutAttachment => "the resolve names an attachment the pass does not resolve",
        error.CompressedTextureCopy => "a compressed format cannot be a copy source or destination",
        error.CopyExtentOutOfRange => "the copy extent leaves the texture it names",
        error.NonFiniteFloat => "a value the pass records is not a finite number",
        error.DebugGroupUnbalanced => "a debug group was popped that was never pushed",
        error.PassNotOpen => "no pass of this encoder is open",
        error.PassEnded => "the pass this call belongs to has already ended",
        error.BundleEncoderFinished => "the render bundle encoder has already finished",
        error.IndirectBufferTooSmall => "the indirect buffer is smaller than the command it feeds",
        error.TimestampIndexOutOfRange => "the timestamp write names an index outside its query set",
        error.CommandStreamTruncated => "the command stream ends in the middle of a command",
        error.EncoderInvalidated => "a previous failure already invalidated this encoder",
        error.EncoderDestroyed => "the owner of this encoder is gone",
        error.ParentEncoderFinished => "the encoder that owns this pass has already finished",
        error.PassLocked => "the command encoder is locked while a pass is open",
        error.QuerySetIsError => "the query set is the error query set a failed creation left",
        error.QuerySetDestroyed => "the query set has been destroyed",
        error.OcclusionQuerySetAbsent => "the render pass has no occlusion query set",
        error.QueryIndexAboveCount => "the query index is at or above the query set's count",
        error.OcclusionQueryAlreadyActive => "an occlusion query is already open in this pass",
        error.OcclusionQueryNotActive => "no occlusion query is open in this pass",
        error.OcclusionQueryUnterminated => "the render pass ended with an occlusion query open",
        error.QueryIndexOverwritten => "this pass already wrote that query index",
        error.QuerySetTypeMismatch => "the query set is of the wrong type for this slot",
        error.ResolveFirstQueryAboveCount => "the resolve names a first query the set does not hold",
        error.ResolveQueryCountAboveRemaining => "the resolve names more queries than remain",
        error.ResolveDestinationOffsetUnaligned => "the resolve offset is not a multiple of 256",
        error.ResolveDestinationTooSmall => "the resolve destination is too small for the range",
        error.ResolveDestinationUsageMissing => "the resolve destination lacks the query resolve usage",
        error.ResolveRunBufferTooSmall => "the run buffer is smaller than the resolve range needs",
    };
}
