//! The three error sets, the payload an error carries, and the message table.
//!
//! **What this file is.** `docs/30-port-design.md` §2.1 replaces Dawn's
//! `InternalErrorType` bitmask with three error sets. §2.2 fixes what an error
//! carries. §2.3 turns `DAWN_INVALID_IF` into a typed error plus a message
//! table. This file is all three.
//!
//! **What this file does not claim.** It does not claim Dawn's message text.
//! Dawn has no message id at this revision. `src/dawn/native/ErrorData.h:102`
//! holds a `std::string`, so the wording below is the port's own.

const std = @import("std");

/// A rule the caller broke. The call is a no-op and the caller can fix the call.
///
/// Dawn folds these into `InternalErrorType::Validation`
/// (`src/dawn/native/Error.h:45`). One member per rule, so a caller can match
/// on the rule instead of on the message text.
pub const ValidationError = error{
    BufferSizeTooSmall,
    BufferUsageMissingCopyDst,
    TextureFormatNotRenderable,
    BindGroupLayoutMismatch,
    EncoderAlreadyFinished,
    StaleHandle,
    HandleKindMismatch,
    RequiredFeatureMissing,
    SliceLengthMismatch,
    LimitExceeded,
    // M11: `native/Texture.cpp`, `native/Sampler.cpp` and
    // `native/TexelBufferView.cpp`. Each member names one `DAWN_INVALID_IF`
    // site; the line it came from is in the M11 table of `docs/40-plan.md`.
    TextureUsageMissing,
    TextureSizeEmpty,
    TextureUsageCompressedFormat,
    TextureUsageRenderAttachmentOn1D,
    TextureUsageStorageBindingUnsupported,
    TextureUsageStorageAttachmentUnsupported,
    TextureUsageTransientAttachmentAlone,
    TextureUsageTransientAttachmentMixed,
    TextureUsageTransientAttachmentNot2D,
    TextureUsageMissingCopyDst,
    TextureUsageMissingCopySrc,
    TextureSampleCountUnsupported,
    MultisampledMipLevelCountNotOne,
    MultisampledDimensionNot2D,
    MultisampledDepthNotOne,
    MultisampledFormatUnsupported,
    MultisampledStorageBinding,
    MultisampledStorageAttachment,
    MultisampledUsageMissingRenderAttachment,
    TextureSizeAboveLimit,
    MipLevelCountAboveLimit,
    TextureCompressedBlockAlignment,
    DepthStencilDimensionNot2D,
    CompressedFormatNot1D,
    CompressedFormatNot3D,
    TextureViewFormatIncompatible,
    TextureViewFormatNotInList,
    TextureViewDimensionUndefined,
    TextureViewFormatUndefined,
    TextureViewAspectUndefined,
    TextureViewAspectMissing,
    TextureViewAspectFormatMismatch,
    TextureViewLayerCountZero,
    TextureViewLayerRangeExceeds,
    TextureViewMipRangeExceeds,
    TextureViewDimensionNotCompatible,
    TextureViewLayerCountNotValid,
    TextureViewCubeNotSquare,
    TextureViewCubeArrayCompatibility,
    TextureViewUsageNotSubset,
    ComponentSwizzleUndefined,
    CopyStrideUndefined,
    CopyBytesPerRowNotAligned,
    CopyBytesPerRowBelowRowSize,
    CopyRowsPerImageBelowHeight,
    CopyDataTooSmall,
    CopyExtentExceedsLevel,
    SamplerLodClampNotFinite,
    SamplerLodClampNegative,
    SamplerLodMinAboveMax,
    SamplerAnisotropyBelowOne,
    SamplerAnisotropyRequiresLinear,
    SamplerFieldUndefined,
    TexelBufferFormatUndefined,
    TexelBufferFormatUnsupported,
    // M19: `native/QuerySet.cpp`. Both rules belong to the object the call
    // makes and not to a recorded command: upstream reaches them through
    // `DeviceBase::CreateQuerySet` (`Device.cpp:2172`-`:2178`), and the error
    // object that a rejected descriptor leaves behind records the rule in
    // `last_error`, which is a field of this set's type. `QueryTypeUnknown`
    // is Dawn's `ValidateQueryType` (`QuerySet.cpp:53`) and
    // `QueryCountAboveMaximum` is `QuerySet.cpp:55`-`:57` against
    // `kMaxQueryCount` (`src/dawn/common/Constants.h:94`).
    QueryTypeUnknown,
    QueryCountAboveMaximum,
};

/// The device is gone. Everything the caller submitted is lost.
///
/// Dawn's `InternalErrorType::BackendDeviceLost`
/// (`src/dawn/native/Error.h:46`).
pub const DeviceLostError = error{
    DeviceLost,
    DeviceDestroyed,
};

/// The port cannot continue. Dawn's `Unrecoverable`,
/// `PipelineUncategorized` and `OutOfMemory`
/// (`src/dawn/native/Error.h:47-49`).
///
/// Dawn folds both Vulkan memory codes into one bit at
/// `src/dawn/native/vulkan/VulkanError.cpp:117`. The port keeps them apart,
/// because a caller that can retry host memory must not be told to free device
/// memory.
pub const UnrecoverableError = error{
    OutOfDeviceMemory,
    OutOfHostMemory,
    PipelineUncategorized,
    InternalInvariantViolated,
    Unimplemented,
};

/// Every error the port can raise. A sweep in `test/error_sets.zig` walks this
/// set, so a member added to any of the three sets above lands in the sweep
/// without a second edit.
pub const Error = ValidationError || DeviceLostError || UnrecoverableError;

/// Which of the three sets a code belongs to.
///
/// Dawn's error scopes match on a type, not on a member:
/// `src/dawn/native/ErrorScope.cpp:106` compares `mMatchedErrorType`. The port
/// needs the same distinction, because a scope matches a filter and not a
/// single rule.
pub const ErrorClass = enum {
    validation,
    device_lost,
    unrecoverable,
};

/// The machine-readable id of an error. `docs/30-port-design.md` §2.2 fixes this
/// as a tagged union so that a `switch` over it names every set.
pub const ErrorCode = union(enum) {
    validation: ValidationError,
    device_lost: DeviceLostError,
    unrecoverable: UnrecoverableError,
};

/// The code that carries `err`.
///
/// **Why every member is named and no set is walked.** Zig will not narrow an
/// `Error` value into the payload of one of its own sets: `.{ .validation =
/// err }` is a compile error naming every member that set does not carry.
/// Neither an `inline else` capture nor a capture of prongs that name more than
/// one set narrows the value the switch was handed, so the only capture narrow
/// enough to build a payload from is one that names exactly the members of a
/// single set. That is what the three groups below are. Reflection cannot
/// supply the names: `@typeInfo` hands back a member's name and no error value,
/// and Zig has no builtin that turns a name back into one
/// (`src/engine/buffer.zig:1854-1856` records the same fact for `Rule`).
///
/// The walk this replaced also cost the file its budget. `codeFromName` took a
/// `comptime` name and ran one `inline for` per set, so all 71 members of
/// `Error` each compared 71 names while the compiler ran, and one comptime
/// evaluation carries one backwards-branch budget of 1000 for the whole file,
/// not one per block. This switch compares no names at all.
///
/// There is no `else` prong, so the three groups are the membership claim: a
/// member added to a set and not to the group for that set is a compile error
/// naming the member, not a rule that quietly reports the wrong class.
pub fn codeFromError(err: Error) ErrorCode {
    return switch (err) {
        error.BufferSizeTooSmall => |member| .{ .validation = member },
        error.BufferUsageMissingCopyDst => |member| .{ .validation = member },
        error.TextureFormatNotRenderable => |member| .{ .validation = member },
        error.BindGroupLayoutMismatch => |member| .{ .validation = member },
        error.EncoderAlreadyFinished => |member| .{ .validation = member },
        error.StaleHandle => |member| .{ .validation = member },
        error.HandleKindMismatch => |member| .{ .validation = member },
        error.RequiredFeatureMissing => |member| .{ .validation = member },
        error.SliceLengthMismatch => |member| .{ .validation = member },
        error.LimitExceeded => |member| .{ .validation = member },
        error.TextureUsageMissing => |member| .{ .validation = member },
        error.TextureSizeEmpty => |member| .{ .validation = member },
        error.TextureUsageCompressedFormat => |member| .{ .validation = member },
        error.TextureUsageRenderAttachmentOn1D => |member| .{ .validation = member },
        error.TextureUsageStorageBindingUnsupported => |member| .{ .validation = member },
        error.TextureUsageStorageAttachmentUnsupported => |member| .{ .validation = member },
        error.TextureUsageTransientAttachmentAlone => |member| .{ .validation = member },
        error.TextureUsageTransientAttachmentMixed => |member| .{ .validation = member },
        error.TextureUsageTransientAttachmentNot2D => |member| .{ .validation = member },
        error.TextureUsageMissingCopyDst => |member| .{ .validation = member },
        error.TextureUsageMissingCopySrc => |member| .{ .validation = member },
        error.TextureSampleCountUnsupported => |member| .{ .validation = member },
        error.MultisampledMipLevelCountNotOne => |member| .{ .validation = member },
        error.MultisampledDimensionNot2D => |member| .{ .validation = member },
        error.MultisampledDepthNotOne => |member| .{ .validation = member },
        error.MultisampledFormatUnsupported => |member| .{ .validation = member },
        error.MultisampledStorageBinding => |member| .{ .validation = member },
        error.MultisampledStorageAttachment => |member| .{ .validation = member },
        error.MultisampledUsageMissingRenderAttachment => |member| .{ .validation = member },
        error.TextureSizeAboveLimit => |member| .{ .validation = member },
        error.MipLevelCountAboveLimit => |member| .{ .validation = member },
        error.TextureCompressedBlockAlignment => |member| .{ .validation = member },
        error.DepthStencilDimensionNot2D => |member| .{ .validation = member },
        error.CompressedFormatNot1D => |member| .{ .validation = member },
        error.CompressedFormatNot3D => |member| .{ .validation = member },
        error.TextureViewFormatIncompatible => |member| .{ .validation = member },
        error.TextureViewFormatNotInList => |member| .{ .validation = member },
        error.TextureViewDimensionUndefined => |member| .{ .validation = member },
        error.TextureViewFormatUndefined => |member| .{ .validation = member },
        error.TextureViewAspectUndefined => |member| .{ .validation = member },
        error.TextureViewAspectMissing => |member| .{ .validation = member },
        error.TextureViewAspectFormatMismatch => |member| .{ .validation = member },
        error.TextureViewLayerCountZero => |member| .{ .validation = member },
        error.TextureViewLayerRangeExceeds => |member| .{ .validation = member },
        error.TextureViewMipRangeExceeds => |member| .{ .validation = member },
        error.TextureViewDimensionNotCompatible => |member| .{ .validation = member },
        error.TextureViewLayerCountNotValid => |member| .{ .validation = member },
        error.TextureViewCubeNotSquare => |member| .{ .validation = member },
        error.TextureViewCubeArrayCompatibility => |member| .{ .validation = member },
        error.TextureViewUsageNotSubset => |member| .{ .validation = member },
        error.ComponentSwizzleUndefined => |member| .{ .validation = member },
        error.CopyStrideUndefined => |member| .{ .validation = member },
        error.CopyBytesPerRowNotAligned => |member| .{ .validation = member },
        error.CopyBytesPerRowBelowRowSize => |member| .{ .validation = member },
        error.CopyRowsPerImageBelowHeight => |member| .{ .validation = member },
        error.CopyDataTooSmall => |member| .{ .validation = member },
        error.CopyExtentExceedsLevel => |member| .{ .validation = member },
        error.SamplerLodClampNotFinite => |member| .{ .validation = member },
        error.SamplerLodClampNegative => |member| .{ .validation = member },
        error.SamplerLodMinAboveMax => |member| .{ .validation = member },
        error.SamplerAnisotropyBelowOne => |member| .{ .validation = member },
        error.SamplerAnisotropyRequiresLinear => |member| .{ .validation = member },
        error.SamplerFieldUndefined => |member| .{ .validation = member },
        error.TexelBufferFormatUndefined => |member| .{ .validation = member },
        error.TexelBufferFormatUnsupported => |member| .{ .validation = member },
        error.QueryTypeUnknown => |member| .{ .validation = member },
        error.QueryCountAboveMaximum => |member| .{ .validation = member },
        error.DeviceLost => |member| .{ .device_lost = member },
        error.DeviceDestroyed => |member| .{ .device_lost = member },
        error.OutOfDeviceMemory => |member| .{ .unrecoverable = member },
        error.OutOfHostMemory => |member| .{ .unrecoverable = member },
        error.PipelineUncategorized => |member| .{ .unrecoverable = member },
        error.InternalInvariantViolated => |member| .{ .unrecoverable = member },
        error.Unimplemented => |member| .{ .unrecoverable = member },
    };
}

/// The set the code belongs to.
pub fn classOf(code: ErrorCode) ErrorClass {
    return switch (code) {
        .validation => .validation,
        .device_lost => .device_lost,
        .unrecoverable => .unrecoverable,
    };
}

/// The stable id of the code. This is the key into `message_table`.
pub fn nameOf(code: ErrorCode) []const u8 {
    return switch (code) {
        .validation => |member| @errorName(member),
        .device_lost => |member| @errorName(member),
        .unrecoverable => |member| @errorName(member),
    };
}

/// The text of every rule, keyed by `nameOf`.
///
/// Dawn has no table. Its 876 `DAWN_INVALID_IF` call sites
/// (`src/dawn/native/Error.h:277`) each carry their own text and no id, so a
/// consumer can only match on the text. A key here is a Zig error name, so the
/// set of keys and the set of rules cannot drift apart at compile time.
///
/// A `{s}` placeholder takes the next context's `text` and a `{d}` placeholder
/// takes the next context's `offset`. The placeholders are read in order. A
/// rule that needs a value the raiser did not supply is a defect, so it is an
/// error and not a message with a hole in it.
pub const message_table = std.StaticStringMap([]const u8).initComptime(.{
    .{ "BufferSizeTooSmall", "buffer size {d} is smaller than the four bytes a u32 needs" },
    .{
        "BufferUsageMissingCopyDst",
        "buffer usage {d} is missing the usage a copy destination needs",
    },
    .{
        "TextureFormatNotRenderable",
        "texture format {s} cannot be a render attachment",
    },
    .{
        "BindGroupLayoutMismatch",
        "bind group layout {s} does not match the pipeline layout",
    },
    .{ "EncoderAlreadyFinished", "the command encoder has already finished" },
    .{ "StaleHandle", "the handle names an object that has been destroyed" },
    .{
        "HandleKindMismatch",
        "the handle names a {s} where a different kind of object belongs",
    },
    .{ "RequiredFeatureMissing", "the feature {s} was not requested" },
    .{
        "SliceLengthMismatch",
        "slice length {d} does not match the extent the copy names",
    },
    .{ "LimitExceeded", "the request is above the device limit {s}" },
    .{ "TextureUsageMissing", "the texture usage is empty" },
    .{ "TextureSizeEmpty", "the texture size or the mip level count is zero" },
    .{
        "TextureUsageCompressedFormat",
        "the texture usage {d} is incompatible with the compressed format {s}",
    },
    .{
        "TextureUsageRenderAttachmentOn1D",
        "the texture usage {d} is incompatible with a one-dimensional texture",
    },
    .{
        "TextureUsageStorageBindingUnsupported",
        "the texture usage {d} is incompatible with the storage format {s}",
    },
    .{
        "TextureUsageStorageAttachmentUnsupported",
        "the texture usage {d} is incompatible with the storage attachment format {s}",
    },
    .{
        "TextureUsageTransientAttachmentAlone",
        "the texture usage {d} is transient attachment alone and needs another attachment usage",
    },
    .{
        "TextureUsageTransientAttachmentMixed",
        "the texture usage {d} mixes transient attachment with a non-attachment usage",
    },
    .{
        "TextureUsageTransientAttachmentNot2D",
        "the texture usage {d} includes transient attachment on a texture that is not two-dimensional",
    },
    .{
        "TextureUsageMissingCopyDst",
        "the texture usage {d} is missing the usage a copy destination needs",
    },
    .{
        "TextureUsageMissingCopySrc",
        "the texture usage {d} is missing the usage a copy source needs",
    },
    .{ "TextureSampleCountUnsupported", "the texture sample count {d} is not supported" },
    .{
        "MultisampledMipLevelCountNotOne",
        "the mip level count {d} of a multisampled texture is not one",
    },
    .{
        "MultisampledDimensionNot2D",
        "the dimension {s} of a multisampled texture is not two-dimensional",
    },
    .{
        "MultisampledDepthNotOne",
        "the depth {d} of a multisampled texture is not one",
    },
    .{
        "MultisampledFormatUnsupported",
        "the texture format {s} does not support multisampling",
    },
    .{ "MultisampledStorageBinding", "a storage texture cannot be multisampled" },
    .{ "MultisampledStorageAttachment", "a storage attachment cannot be multisampled" },
    .{
        "MultisampledUsageMissingRenderAttachment",
        "the texture usage {d} of a multisampled texture is missing render attachment",
    },
    .{ "TextureSizeAboveLimit", "the texture size {d} is above the device limit {s}" },
    .{
        "MipLevelCountAboveLimit",
        "the mip level count {d} exceeds the maximum for the texture size",
    },
    .{
        "TextureCompressedBlockAlignment",
        "the texture size {d} is not a multiple of the block width and height of {s}",
    },
    .{
        "DepthStencilDimensionNot2D",
        "the dimension {s} of a depth or stencil texture is not two-dimensional",
    },
    .{
        "CompressedFormatNot1D",
        "a texture with the compressed format {s} is not one-dimensional",
    },
    .{
        "CompressedFormatNot3D",
        "a texture with the compressed format {s} is not three-dimensional",
    },
    .{
        "TextureViewFormatIncompatible",
        "the texture view format {s} is not view compatible with the texture format {s}",
    },
    .{
        "TextureViewFormatNotInList",
        "the texture was not created with the texture view format {s} in its view format list",
    },
    .{ "TextureViewDimensionUndefined", "the texture view dimension is undefined" },
    .{ "TextureViewFormatUndefined", "the texture view format is undefined" },
    .{ "TextureViewAspectUndefined", "the texture view aspect is undefined" },
    .{
        "TextureViewAspectMissing",
        "the texture format {s} does not have the aspect the texture view selected",
    },
    .{
        "TextureViewAspectFormatMismatch",
        "the texture view format {s} does not match the format of the aspect it selected",
    },
    .{
        "TextureViewLayerCountZero",
        "the texture view array layer count or mip level count is zero",
    },
    .{
        "TextureViewLayerRangeExceeds",
        "the texture view array layer range {d} exceeds the texture array layer count {d}",
    },
    .{
        "TextureViewMipRangeExceeds",
        "the texture view mip level range {d} exceeds the texture mip level count {d}",
    },
    .{
        "TextureViewDimensionNotCompatible",
        "the texture view dimension {s} is not compatible with the texture dimension {s}",
    },
    .{
        "TextureViewLayerCountNotValid",
        "the array layer count {d} is not valid for the texture view dimension {s}",
    },
    .{
        "TextureViewCubeNotSquare",
        "the width {d} and the height {d} of the texture are not equal, so it has no cube view",
    },
    .{
        "TextureViewCubeArrayCompatibility",
        "a {s} texture view is not supported in compatibility mode",
    },
    .{
        "TextureViewUsageNotSubset",
        "the texture view usage {d} is not a subset of the texture usage {d}",
    },
    .{ "ComponentSwizzleUndefined", "the component swizzle field {s} is undefined" },
    .{
        "CopyStrideUndefined",
        "the copy depth {d} is above one but the row pitch or the rows per image is unset",
    },
    .{ "CopyBytesPerRowNotAligned", "the bytes per row {d} is not a multiple of {d}" },
    .{
        "CopyBytesPerRowBelowRowSize",
        "the row is {d} bytes wide, which is above the bytes per row {d}",
    },
    .{
        "CopyRowsPerImageBelowHeight",
        "the image is {d} rows tall, which is above the rows per image {d}",
    },
    .{ "CopyDataTooSmall", "the copy needs {d} bytes but the data holds {d}" },
    .{ "CopyExtentExceedsLevel", "the copy extent runs past the edge of the level" },
    .{ "SamplerLodClampNotFinite", "the sampler {s} clamp is not a finite number" },
    .{
        "SamplerLodClampNegative",
        "the sampler LOD clamp bounds hold a negative number",
    },
    .{ "SamplerLodMinAboveMax", "the sampler LOD min clamp is above the max clamp" },
    .{ "SamplerAnisotropyBelowOne", "the sampler max anisotropy {d} is below one" },
    .{
        "SamplerAnisotropyRequiresLinear",
        "the sampler max anisotropy {d} is above one and a filter is not linear",
    },
    .{ "SamplerFieldUndefined", "the sampler field {s} is undefined" },
    .{ "TexelBufferFormatUndefined", "the texel buffer format is undefined" },
    .{
        "TexelBufferFormatUnsupported",
        "the texel buffer format {s} is not one a texel buffer may name",
    },
    .{
        "QueryTypeUnknown",
        "the query type is not a tag the query type enum names",
    },
    .{ "QueryCountAboveMaximum", "the query count is above the maximum" },
    .{ "DeviceLost", "the device was lost and every submitted command is gone" },
    .{ "DeviceDestroyed", "the device was destroyed before the call finished" },
    .{ "OutOfDeviceMemory", "the device ran out of memory" },
    .{ "OutOfHostMemory", "the host ran out of memory" },
    .{
        "PipelineUncategorized",
        "pipeline creation failed for a reason the port does not classify",
    },
    .{ "InternalInvariantViolated", "an internal invariant was violated" },
    .{ "Unimplemented", "the port does not implement this call: {s}" },
});

/// One line of context. `text` says what the caller was doing. `offset` is a
/// byte offset in a buffer when the context names a range. A context that names
/// no range carries 0 and is read only through a `{s}` placeholder.
pub const ErrorContext = struct {
    text: []const u8,
    offset: u64 = 0,
};

/// Every way rendering a message can fail.
///
/// `MissingMessageTableEntry` and `UnknownPlaceholder` are defects in this file:
/// they name a rule or a placeholder that does not exist. `MissingContext` is a
/// defect in the rule that raised the error.
pub const FormatError = std.mem.Allocator.Error || error{
    MissingMessageTableEntry,
    MissingContext,
    UnknownPlaceholder,
};

/// What an error carries. `docs/30-port-design.md` §2.2 fixes these four
/// fields.
///
/// The payload owns `message` and every `context[i].text`. Both come from the
/// allocator that built the payload. Dawn keeps the same strings in an
/// `ErrorData` (`src/dawn/native/ErrorData.h:101-106`).
pub const ErrorData = struct {
    code: ErrorCode,
    message: []u8,
    context: std.ArrayList(ErrorContext) = .empty,
    backtrace: ?*std.builtin.StackTrace,

    /// Builds a payload. `message` is rendered from `message_table` and filled
    /// from `initial_context`; `context` keeps a copy of `initial_context` so
    /// that `report` can print it.
    ///
    /// Dawn's `ErrorData::Create` (`src/dawn/native/ErrorData.cpp:41`) takes
    /// `__FILE__`, `__func__` and `__LINE__` and appends one backtrace record.
    /// Zig has no `__LINE__`, so the backtrace is a value the raiser holds and
    /// passes here. A caller that has none passes null.
    pub fn init(
        allocator: std.mem.Allocator,
        code: ErrorCode,
        backtrace: ?*std.builtin.StackTrace,
        initial_context: []const ErrorContext,
    ) FormatError!ErrorData {
        const message = try render(allocator, code, initial_context);
        errdefer allocator.free(message);

        var context: std.ArrayList(ErrorContext) = .empty;
        errdefer context.deinit(allocator);
        const initial_context_count = initial_context.len;
        for (initial_context[0..initial_context_count]) |item| {
            try appendOwnedContext(allocator, &context, item);
        }

        return .{
            .code = code,
            .message = message,
            .context = context,
            .backtrace = backtrace,
        };
    }

    /// Adds one context line. `DAWN_TRY_CONTEXT`
    /// (`src/dawn/native/Error.h:363`) is this call.
    pub fn appendContext(
        self: *ErrorData,
        allocator: std.mem.Allocator,
        item: ErrorContext,
    ) std.mem.Allocator.Error!void {
        return appendOwnedContext(allocator, &self.context, item);
    }

    /// Frees every allocation the payload owns and poisons the payload.
    ///
    /// `self.* = undefined` is the terminal state, not a reset of the three
    /// slots. A slot that still reads `message` or `context` after the free is
    /// a payload whose storage is gone, and no caller could tell it from a live
    /// one, so a reset is a lie the type does not carry. Every caller already
    /// treats the payload as dead once the call returns:
    /// `ErrorScopeStack.handleError` (`src/core/error_scope.zig:209-221`) frees
    /// the payload itself and hands back only a bool,
    /// `ErrorScope.capture` (`src/core/error_scope.zig:104-114`) drops the
    /// reference to an error it will not keep, and every raiser reads the
    /// fields before its `defer` runs (`test/error_sets.zig:40-63`,
    /// `test/error_scope.zig:34-56`).
    ///
    /// The rule that leaves is one `deinit` per payload: a second call reads
    /// undefined memory, which is a caller defect rather than a double free,
    /// and it is the same trade every other `deinit` in the tree makes
    /// (`src/core/error_scope.zig:120`, `src/memory/size_tracker.zig:85`).
    pub fn deinit(self: *ErrorData, allocator: std.mem.Allocator) void {
        const context_count = self.context.items.len;
        for (self.context.items[0..context_count]) |item| allocator.free(item.text);
        self.context.deinit(allocator);
        allocator.free(self.message);
        self.* = undefined;
    }

    /// The message plus one line per context.
    ///
    /// This is Dawn's `GetFormattedMessage`
    /// (`src/dawn/native/ErrorData.cpp:105`) with three parts removed. The
    /// port drops the debug-group stack and the back-end messages, for the
    /// reason `docs/30-port-design.md` §2.2 gives. It also drops the stack
    /// trace, because `std.debug.writeStackTrace` needs an `Io.Terminal`
    /// (`lib/std/debug.zig:824`) and rendering a trace is a logging task, not
    /// part of the error value.
    pub fn report(
        self: *const ErrorData,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, self.message);
        const context_count = self.context.items.len;
        for (self.context.items[0..context_count]) |item| {
            try out.appendSlice(allocator, "\n - While ");
            try out.appendSlice(allocator, item.text);
        }
        return out.toOwnedSlice(allocator);
    }
};

/// Raises a validation rule. The rule returns its error name; this is the one
/// place the name becomes text.
pub fn initValidation(
    allocator: std.mem.Allocator,
    rule: ValidationError,
    initial_context: []const ErrorContext,
) FormatError!ErrorData {
    return ErrorData.init(allocator, .{ .validation = rule }, null, initial_context);
}

fn render(
    allocator: std.mem.Allocator,
    code: ErrorCode,
    context: []const ErrorContext,
) FormatError![]u8 {
    const template = message_table.get(nameOf(code)) orelse
        return error.MissingMessageTableEntry;
    return renderTemplate(allocator, template, context);
}

fn renderTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
    context: []const ErrorContext,
) FormatError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const context_count = context.len;
    var context_index: usize = 0;
    var cursor: usize = 0;
    // The bound is `template.len`. One pass consumes the three bytes of a
    // placeholder, so the loop runs at most `template.len / 3` times.
    while (findFrom(template, '{', cursor)) |open| {
        const close = findFrom(template, '}', open) orelse break;
        try out.appendSlice(allocator, template[cursor..open]);

        if (context_index >= context_count) return error.MissingContext;
        const item = context[context_index];
        context_index += 1;

        const placeholder = template[open + 1 .. close];
        if (std.mem.eql(u8, placeholder, "s")) {
            try out.appendSlice(allocator, item.text);
        } else if (std.mem.eql(u8, placeholder, "d")) {
            try out.print(allocator, "{d}", .{item.offset});
        } else {
            return error.UnknownPlaceholder;
        }
        cursor = close + 1;
    }
    try out.appendSlice(allocator, template[cursor..]);
    return out.toOwnedSlice(allocator);
}

fn appendOwnedContext(
    allocator: std.mem.Allocator,
    context: *std.ArrayList(ErrorContext),
    item: ErrorContext,
) std.mem.Allocator.Error!void {
    const text = try allocator.dupe(u8, item.text);
    errdefer allocator.free(text);
    try context.append(allocator, .{ .text = text, .offset = item.offset });
}

fn findFrom(haystack: []const u8, needle: u8, start: usize) ?usize {
    const bound = haystack.len;
    var index = start;
    while (index < bound) : (index += 1) {
        if (haystack[index] == needle) return index;
    }
    return null;
}

/// Whether the table carries text for the rule `name` names.
fn hasMessage(name: []const u8) bool {
    return message_table.get(name) != null;
}

test "every rule of every set has a message" {
    // `docs/30-port-design.md` §2.3 keeps this test next to the table, because
    // a rule without text is a defect the table must report.
    //
    // A `for`, not an `inline for`, and one line of body. Reflection hands back
    // a member's name and no error value (`src/engine/buffer.zig:1854-1856`
    // records the same fact for `Rule`), so there is nothing per member to
    // inline. And comptime counts the backwards branches of one whole
    // evaluation, not of one block, so a body repeated per member spends the
    // budget every other comptime claim in this file shares. A plain `for`
    // compiles the loop once and still visits every one of the members the set
    // declares.
    for (@typeInfo(Error).error_set.?) |member| {
        try std.testing.expect(hasMessage(member.name));
    }
}

test "a code comes back from its name and reports its set" {
    const cases = [_]struct { member: Error, class: ErrorClass }{
        .{ .member = error.BufferSizeTooSmall, .class = .validation },
        .{ .member = error.DeviceLost, .class = .device_lost },
        .{ .member = error.OutOfHostMemory, .class = .unrecoverable },
    };
    const case_count = cases.len;
    for (cases[0..case_count]) |case| {
        const code = codeFromError(case.member);
        try std.testing.expectEqualStrings(@errorName(case.member), nameOf(code));
        try std.testing.expectEqual(case.class, classOf(code));
    }
}

test "a rule renders its table entry and a context becomes a While line" {
    const context = [_]ErrorContext{.{ .text = "2", .offset = 2 }};
    var data = try initValidation(std.testing.allocator, error.BufferSizeTooSmall, &context);
    defer data.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "buffer size 2 is smaller than the four bytes a u32 needs",
        data.message,
    );
    try std.testing.expect(data.backtrace == null);

    try data.appendContext(std.testing.allocator, .{ .text = "createBuffer" });
    const report = try data.report(std.testing.allocator);
    defer std.testing.allocator.free(report);

    // The line for `2` is the initial context `initValidation` was handed, and
    // `ErrorData.init` keeps a copy of it so `report` can print it, not only the
    // line `appendContext` added after the payload was built.
    try std.testing.expectEqualStrings(
        "buffer size 2 is smaller than the four bytes a u32 needs\n" ++
            " - While 2\n" ++
            " - While createBuffer",
        report,
    );
}

test "a rule that needs a value the raiser did not supply is its own error" {
    const no_context: [0]ErrorContext = .{};
    try std.testing.expectError(
        error.MissingContext,
        initValidation(std.testing.allocator, error.TextureFormatNotRenderable, &no_context),
    );
}

test "a template with no closing brace renders what it has" {
    // The scan stops at an unclosed brace instead of reading past the end of the
    // table entry.
    const one = [_]ErrorContext{.{ .text = "here" }};
    const rendered = try renderTemplate(std.testing.allocator, "open {s", &one);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("open {s", rendered);
}

test "a placeholder the table does not define is its own error" {
    const one = [_]ErrorContext{.{ .text = "here" }};
    try std.testing.expectError(
        error.UnknownPlaceholder,
        renderTemplate(std.testing.allocator, "value {x}", &one),
    );
}
