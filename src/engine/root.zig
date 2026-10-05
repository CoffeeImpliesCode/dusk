//! `engine`: the instance, the adapter, the device, and the back end.
//!
//! `docs/10-architecture.md` "Module boundaries" fixes this module as the one
//! that owns the instance, the adapter, the device, the queue, the buffers, the
//! textures and the bind groups, and the one that never encodes a command.
//!
//! **This file is the engine's public surface.** Every name a consumer reaches
//! is re-exported here. A milestone adds its own file to the import list below
//! and its own names to the export list; it never edits another milestone's
//! line. `src/root.zig` re-exports this file as `dusk.engine`, which is the
//! path `test/null_device.zig` reaches the library through.
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

// The front end. `Instance`, `Adapter` and `Device` are M8; `queue`, `buffer`
// and `texture` arrive at M9, M10 and M11.
pub const Instance = instance_mod.Instance;
pub const Adapter = adapter_mod.Adapter;
pub const Device = device_mod.Device;
pub const PhysicalDevice = physical_device_mod.PhysicalDevice;

/// One enumeration's adapters and the physical devices behind them.
pub const AdapterList = instance_mod.AdapterList;
/// `DeviceBase::State` (`Device.h:366-372`) without `BeingCreated`, because
/// the port builds a device in one call and never has a half-built one.
pub const DeviceState = device_mod.State;

// The back ends. `null_backend` is M8; the Vulkan one arrives at M9.
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
/// `vulkan_device.zig`: the M9 Vulkan back end — the ICD search, the instance,
/// the `VkDevice`, the handle set it owns and the `Backend` the front end
/// reaches Vulkan through.
pub const vulkan_device = @import("vulkan_device.zig");
/// `vulkan_format.zig`: the `TextureFormat` to `VkFormat` table and the feature
/// query behind it.
pub const vulkan_format = @import("vulkan_format.zig");
