//! `vk`: the dispatch layer over the generated Vulkan bindings.
//!
//! **What this module is.** `docs/10-architecture.md` "Module boundaries" gives
//! `vk` three jobs: loading `libvulkan`, the three-tier dispatch table, and the
//! `VkResult` to Zig error mapping. The table is the only
//! door to a Vulkan entry point and the mapping the only place a `VkResult`
//! becomes a Zig error. `docs/30-port-design.md` §6.2 owns the shape, and
//! `tools/gen_dispatch.zig` emits the file below.
//!
//! **What this module does not claim.** It does not claim to know what a
//! texture, a pipeline or a command is. A caller that wants one of those asks
//! `engine` or `pipeline`; this module moves calls and classifies results, and
//! nothing else. It holds no state of its own: the table is data the loader
//! fills in from the library.
//!
//! **What it does not claim either.** It does not claim the bindings. The
//! generated `src/vulkan.zig` is its own module, `vulkan`, so a consumer of
//! `@import("dusk")` reaches the handle types through
//! `platform.vulkan_bindings` and not through here. Nor does it claim wire
//! compatibility with Dawn's `VulkanFunctions.h`: the tier member counts are
//! recorded in `docs/30-port-design.md` §6.1.

/// `dispatch.zig`, the whole file as one namespace: the three tiers, the three
/// load functions, the extension sets and the `VkResult` mapping.
pub const dispatch = @import("dispatch.zig");

// The three tiers. A `null` member means "not loaded", and the loader is the
// only thing that fills one in.
pub const Dispatch = dispatch.Dispatch;
pub const GlobalProcs = dispatch.GlobalProcs;
pub const InstanceProcs = dispatch.InstanceProcs;
pub const DeviceProcs = dispatch.DeviceProcs;

// The three load functions, each with the options struct it reads and the error
// set that says which tier failed.
pub const LoadError = dispatch.LoadError;
pub const ProcRow = dispatch.ProcRow;
pub const InstanceLoadOptions = dispatch.InstanceLoadOptions;
pub const DeviceLoadOptions = dispatch.DeviceLoadOptions;
pub const loadGlobalProcs = dispatch.loadGlobalProcs;
pub const loadInstanceProcs = dispatch.loadInstanceProcs;
pub const loadDeviceProcs = dispatch.loadDeviceProcs;

// The extension sets, one bit each, packed so a device extension query is a
// single integer test.
pub const InstanceExt = dispatch.InstanceExt;
pub const EnabledInstanceExts = dispatch.EnabledInstanceExts;
pub const InstanceProcGroup = dispatch.InstanceProcGroup;
pub const DeviceExt = dispatch.DeviceExt;
pub const EnabledDeviceExts = dispatch.EnabledDeviceExts;
pub const DeviceProcGroup = dispatch.DeviceProcGroup;

// The `VkResult` mapping.
pub const Outcome = dispatch.Outcome;
pub const Error = dispatch.Error;
pub const classify = dispatch.classify;
pub const vkResultName = dispatch.vkResultName;
pub const checkVkSuccess = dispatch.checkVkSuccess;
pub const checkVkOomThenSuccess = dispatch.checkVkOomThenSuccess;
pub const injected_error_result = dispatch.injected_error_result;
pub const injected_device_oom_result = dispatch.injected_device_oom_result;
