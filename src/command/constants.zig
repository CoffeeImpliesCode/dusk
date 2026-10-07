//! The limits the command stream enforces itself, and the ones it is told.
//!
//! **What this file is.** Two kinds of number, kept apart on purpose.
//!
//! `spec_*` is what the WebGPU specification fixes, so it is the same on every
//! device and the port can reject a call before it reads a device. Dawn holds
//! these in `src/dawn/common/Constants.h`; the row in `docs/40-plan.md` §M15
//! gives the line for each.
//!
//! `Limits` is what the device reports. Dawn reaches the device through
//! `GetDevice()->GetLimits()`
//! (`src/dawn/native/ComputePassEncoder.cpp:240-241`) at the call site. The
//! port cannot: `command` does not import `engine`
//! (`docs/10-architecture.md`, "Module boundaries"). So the device limit set
//! is a value the caller passes in and the encoders hold. That is the house
//! rule "state is a parameter, not a capture" applied to a limit.

/// Bind groups a pipeline layout may name at most
/// (`src/dawn/common/Constants.h:36`).
pub const max_bind_groups: u32 = 4;

/// Vertex buffers a pass may name at most
/// (`src/dawn/common/Constants.h:39`).
pub const max_vertex_buffers: u32 = 8;

/// Colour attachments a render pass may name at most
/// (`src/dawn/common/Constants.h:43`).
pub const max_color_attachments: u32 = 8;

/// The row alignment every buffer copy to or from a texture obeys
/// (`src/dawn/common/Constants.h:44`).
pub const texture_bytes_per_row_alignment: u32 = 256;

/// The offset alignment a query resolve obeys
/// (`src/dawn/common/Constants.h:45`).
pub const query_resolve_alignment: u32 = 256;

/// One `u32` tag plus the padding that puts the payload on an eight-byte
/// boundary. Dawn's `kEndOfBlock`
/// (`src/dawn/native/CommandAllocator.h:91`) closes a block; a tag equal to it
/// can never be a command.
pub const end_of_block: u32 = 0xFFFF_FFFF;

/// Introduces the counted run that follows a payload. Dawn's
/// `kAdditionalData` (`src/dawn/native/CommandAllocator.h:92`), one below the
/// end-of-block sentinel so the two cannot collide with a tag.
pub const additional_data: u32 = 0xFFFF_FFFE;

/// Every allocation in the stream is aligned to this. Dawn's
/// `kMaxAllocatedCommandAlignment` (`CommandAllocator.h:97`) is `sizeof(u64)`
/// and is constant so the allocator has no variable-alignment path.
pub const max_alignment: usize = 8;

/// The bytes a command costs beyond its payload, worst case: the tag slot, the
/// padding that follows the payload, and the end-of-block tag. Dawn computes
/// the same bound at `CommandAllocator.h:253-256` and uses it so the fast path
/// never has to test for an overflow mid-computation.
pub const worst_case_additional_size: usize = 20;

/// The granularity one immediate is stored at
/// (`src/dawn/common/Constants.h:51`).
pub const immediate_element_byte_size: u32 = 4;

/// The full user immediate range. Native admission applies the effective device limit.
pub const max_immediate_data_bytes: u32 = 256;

/// The bytes one `DrawIndirect` reads: four `u32`
/// (`src/dawn/common/Constants.h:77`).
pub const draw_indirect_size: u64 = 16;

/// The bytes one `DrawIndexedIndirect` reads: five `u32`
/// (`src/dawn/common/Constants.h:78`).
pub const draw_indexed_indirect_size: u64 = 20;

/// The bytes one `DispatchIndirect` reads: three `u32`
/// (`src/dawn/common/Constants.h:76`), read back at
/// `ComputePassEncoder.cpp:431-436` as the dispatch size.
pub const dispatch_indirect_size: u64 = 12;

/// The bytes one pixel-local-storage slot occupies
/// (`src/dawn/common/Constants.h:103`).
pub const pls_slot_byte_size: u32 = 4;

/// The fixed pixel-local-storage capacity (`src/dawn/common/Constants.h:102-104`).
pub const max_pls_slots: u32 = 4;
pub const max_pls_size: u32 = max_pls_slots * pls_slot_byte_size;

/// Shared bounds for frontend and native render-bundle traversal.
pub const max_bundle_depth: usize = 16;
pub const max_bundle_command_count: usize = 1 << 24;

/// The draws one pass may issue when its descriptor does not say otherwise
/// (`src/dawn/native/RenderPassEncoder.h:121`). Dawn's `RenderPassMaxDrawCount`
/// chained struct overrides it; the port takes it as a field on the descriptor
/// instead, because there is no chain below `command`.
pub const default_max_draw_count: u64 = 50_000_000;

/// What the device reports. `engine` fills this once at device creation and
/// every encoder holds a copy, so a rule reads a number and never the device.
pub const Limits = struct {
    /// `maxComputeWorkgroupsPerDimension`, from
    /// `Limits.cpp`; Dawn reads it at
    /// `src/dawn/native/ComputePassEncoder.cpp:240-241`.
    max_compute_workgroups_per_dimension: u32 = 65_535,
    /// `maxComputeInvocationsPerWorkgroup`. A dispatch names workgroups, not
    /// invocations, so this only bounds the linear index the port computes.
    max_compute_invocations_per_workgroup: u32 = 256,
    /// `maxStorageBuffersPerShaderStage`. A render pass may hold at most this
    /// many storage attachments
    /// (`src/dawn/common/Constants.h:71`).
    max_storage_attachments_per_render_pass: u32 = 8,
};
