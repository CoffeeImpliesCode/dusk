//! `engine`: the instance, the adapter, the device, and the back end.
//!
//! `docs/10-architecture.md` "Module boundaries" fixes this module as the one
//! that owns the instance, the adapter, the device, the queue, the buffers, the
//! textures and the bind groups, and the one that never encodes a command.
//!
//! **This file is the engine's public surface.** Every name a consumer reaches
//! is re-exported here. File namespaces expose each owner's typed descriptors
//! and operations without a second runtime facade. `src/root.zig` publishes
//! this file as `dusk.engine`.
//!
//! **What this file does not claim.** The names a milestone below has not
//! landed are absent rather than declared and empty.

const adapter_mod = @import("adapter.zig");
const api = @import("../api/api.zig");
const device_mod = @import("device.zig");
const features_mod = @import("features.zig");
const instance_mod = @import("instance.zig");
const limits_mod = @import("limits.zig");
const null_backend_mod = @import("null_backend.zig");
const physical_device_mod = @import("physical_device.zig");

// The front-end owners. Native Vulkan state lives at stable addresses behind
// Instance and Device; the null backend is an explicit test choice.
pub const Instance = instance_mod.Instance;
pub const Adapter = adapter_mod.Adapter;
pub const Device = device_mod.Device;
pub const PhysicalDevice = physical_device_mod.PhysicalDevice;

/// One enumeration's adapters and the physical devices behind them.
pub const AdapterList = instance_mod.AdapterList;
/// A counted physical-device enumeration that retains its Instance owner.
pub const PhysicalDeviceList = instance_mod.PhysicalDeviceList;
/// `DeviceBase::State` (`Device.h:366-372`) without `BeingCreated`, because
/// the port builds a device in one call and never has a half-built one.
pub const DeviceState = device_mod.State;

// The deterministic null back end. Native Vulkan ownership is published below.
pub const null_backend = null_backend_mod;

// The names more than one of those files answers through.
pub const FeatureLevel = api.FeatureLevel;
pub const BackendType = api.BackendType;
pub const AdapterType = api.AdapterType;
pub const PowerPreference = api.PowerPreference;
pub const DeviceLostReason = api.DeviceLostReason;
pub const Limits = api.Limits;
pub const CompatibilityModeLimits = api.CompatibilityModeLimits;

// The error sets, one per boundary. A reader enumerates every failure mode of a
// call from its signature.
pub const InstanceError = instance_mod.Error;
pub const AdapterError = adapter_mod.Error;
pub const DeviceError = device_mod.InitError;

// The comptime tables M7 owns. `limits.CombinedLimits` is what every limit is
// read through, and `features.FeaturesSet` is what every feature is read
// through.
pub const limits = limits_mod;
pub const features = features_mod;

// The two rules that produce a device's features and limits, because a caller
// reading them needs to know what made them.
pub const applyFeatures = device_mod.applyFeatures;
pub const enforceLimitSpecInvariants = device_mod.enforceLimitSpecInvariants;

// --- the file namespaces ---------------------------------------------------
//
// One `pub const` per sibling, keyed by file name, so a consumer reaches a
// whole file as `engine.<file_name>` and this list never has to be kept in
// step when a file grows. `adapter`, `device` and `instance` are added here
// beside the flat names above rather than in place of them: the flat name is
// what a caller writes most, and the namespace is what reaches the rest of a
// file.
//
// `limits`, `features` and `null_backend` are absent because the flat exports
// above already publish those three files whole.

/// `adapter.zig`: the adapters behind one enumeration.
pub const adapter = adapter_mod;
/// `async_registry.zig`: typed asynchronous completion cells and future waits.
pub const async_registry = @import("async_registry.zig");
pub const async_root_requests = @import("async_root_requests.zig");
pub const native_async_device = @import("native_async_device.zig");
pub const native_async_descriptors = @import("native_async_descriptors.zig");
pub const native_async_pipeline = @import("native_async_pipeline.zig");
pub const native_async_map_queue = @import("native_async_map_queue.zig");
pub const native_async_scope_info = @import("native_async_scope_info.zig");
pub const native_async_handles = @import("native_async_handles.zig");
pub const RootKind = async_root_requests.RootKind;
pub const RootRecord = async_root_requests.RootRecord;
pub const OwnedAdapterSelection = async_root_requests.OwnedAdapterSelection;
pub const OwnedDevice = async_root_requests.OwnedDevice;
pub const OwnedDeviceInput = async_root_requests.OwnedDeviceInput;
pub const RootOutcome = async_root_requests.RootOutcome;
pub const RootWorkError = async_root_requests.RootWorkError;
pub const RootDescriptorError = async_root_requests.RootDescriptorError;
pub const RootCreateError = async_root_requests.RootCreateError;
pub const OwnedRootReleaseError = async_root_requests.OwnedRootReleaseError;
pub const RootReleaseResult = async_root_requests.RootReleaseResult;
pub const RootDisposalError = async_root_requests.RootDisposalError;
/// `buffer.zig`: the buffer object, its usage rules, the upload ring and the
/// barriers its writes raise.
pub const buffer = @import("buffer.zig");
/// `device.zig`: the front-end device, the feature and limit rules it applies
/// at creation, and `DeviceLostReason`.
pub const device = device_mod;
/// `framebuffer_cache.zig`: the render pass framebuffers, keyed by attachment
/// state.
pub const framebuffer_cache = @import("framebuffer_cache.zig");
/// `instance.zig`: the instance, the enumeration it drives and its error set.
pub const instance = instance_mod;
/// `query_set.zig`: the query set object and the rules a descriptor breaks.
pub const query_set = @import("query_set.zig");
/// `queue.zig`: the queue, the submission contexts and the fence wait.
pub const queue = @import("queue.zig");
/// `recording_context.zig`: the per-command-buffer recording state.
pub const recording_context = @import("recording_context.zig");
/// `render_pass_cache.zig`: the render pass objects, keyed by what they
/// render into.
pub const render_pass_cache = @import("render_pass_cache.zig");
/// `sampler.zig`: the sampler object and its descriptor rules.
pub const sampler = @import("sampler.zig");
/// `stage.zig`: the per-stage state a pipeline shares with the encoders.
pub const stage = @import("stage.zig");
/// `stream.zig`: the host stream the queue reads work from.
pub const stream = @import("stream.zig");
/// `texture.zig`: the texture and texture-view objects, the format table and
/// the copy rules.
pub const texture = @import("texture.zig");
/// `toggles.zig`: the toggle names and the per-feature defaults.
pub const toggles = @import("toggles.zig");
/// `vulkan_device.zig`: Vulkan discovery and logical-device creation, including
/// the handle set and queried physical capabilities.
pub const vulkan_device = @import("vulkan_device.zig");
/// `vulkan_format.zig`: the `TextureFormat` to `VkFormat` table and the feature
/// query behind it.
pub const vulkan_format = @import("vulkan_format.zig");

/// Canonical format capabilities and aspect/block metadata for a feature set.
pub const format = @import("format.zig");
/// Distinct texel/block units and checked copy-geometry conversions.
pub const block_info = @import("block_info.zig");
/// Native descriptor-set objects used by recorded programmable passes.
pub const bind_group = @import("bind_group.zig");
/// Replay of finished front-end commands into the queue's Vulkan recording.
pub const command_buffer = @import("command_buffer.zig");
/// Query-pool creation, reset, resolution, and serial-safe retirement.
pub const vulkan_query_set = @import("vulkan_query_set.zig");

/// Stable Vulkan instance ownership shared by adapter lists and devices.
pub const native_instance_context = @import("native_instance_context.zig");
/// Stable device dispatch, queue, pipeline and replay ownership.
pub const native_device_context = @import("native_device_context.zig");
/// Physical Vulkan capabilities mapped into front-end features and limits.
pub const native_capabilities = @import("native_capabilities.zig");
/// Typed resources and descriptors used by the native Device methods.
pub const native_resources = @import("native_resources.zig");
/// Original-guard weak indices owned by the stable native device context.
pub const native_resource_store = @import("native_resource_store.zig");
pub const native_weak_index = @import("native_weak_index.zig");
pub const native_attachment_store = @import("native_attachment_store.zig");
pub const native_render_state = @import("native_render_state.zig");
/// Bounded canonical utility pipeline leases and native recording.
pub const native_kernels = @import("native_kernels.zig");
/// Committed shader words and fixed native utility binding definitions.
pub const native_kernel_definitions = @import("native_kernel_definitions.zig");
/// GPU validation of indirect draw and dispatch arguments.
pub const native_indirect = @import("native_indirect.zig");
/// GPU conversion of native timestamp ticks into nanoseconds.
pub const native_timestamps = @import("native_timestamps.zig");
/// Native clears, copies, and shader-based texture conversions.
pub const native_blit = @import("native_blit.zig");
/// External texture owners, metadata, and native GPU sampling.
pub const external_texture = @import("external_texture.zig");

test "native public owners and Device method declarations are referenced" {
    const std = @import("std");
    inline for (.{
        native_instance_context,
        native_device_context,
        native_capabilities,
        native_resources,
        native_resource_store,
        native_weak_index,
        native_attachment_store,
        native_render_state,
        native_kernels,
        native_kernel_definitions,
        native_indirect,
        native_timestamps,
        native_blit,
        external_texture,
        native_instance_context.NativeInstanceContext,
        native_device_context.NativeDeviceContext,
        Device,
        PhysicalDeviceList,
    }) |owner| std.testing.refAllDecls(owner);
}
