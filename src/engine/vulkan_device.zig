//! The Vulkan instance, the physical devices, the device, and the live-handle
//! accounting that makes a leak observable.
//!
//! **What this file is.** The port of `src/dawn/native/vulkan/BackendVk.{h,cpp}`
//! (128 + 646 lines), the admission half of
//! `src/dawn/native/vulkan/PhysicalDeviceVk.{h,cpp}`, and the device-creation
//! half of `src/dawn/native/vulkan/DeviceVk.{h,cpp}` at Dawn revision
//! `32f77c02294310054a660c393feded4bcb3f203c`, read-only at
//! `/tmp/scratch/research/dawn`. `docs/40-plan.md` §3.6 carries
//! its rows.
//!
//! **What this file does not claim.** It does not claim device memory
//! allocation: `ResourceMemoryAllocatorVk.cpp` is not a milestone-9 upstream
//! file, so `vkAllocateMemory` reaches Vulkan only from a test. It does not
//! claim the debug-utils messenger (`VulkanInstance::RegisterDebugUtils`,
//! `BackendVk.cpp:537`): `docs/50-verification.md` §4.4 makes the child's
//! stderr the primary mechanism for reading a layer's output, and the
//! no-layer path this milestone tests under
//! (`VK_LOADER_LAYERS_DISABLE=*`, §4.2) has no messenger to read.
//!
//! **One difference from upstream, named.** Dawn keeps three per-ICD side
//! tables (`BackendVk.h:121`-`:123`) and a `Ref<VulkanInstance>` per entry, so
//! a live adapter keeps its instance alive and an unused one can be released
//! (`BackendVk.h:63`-`:70`). The port has no reference counting: a `Backend`
//! owns its instances outright, which is `docs/30-port-design.md` §1.1's
//! arena-per-device model rather than a second lifetime scheme.

const std = @import("std");
const vulkan = @import("vulkan");
const dispatch = @import("../vk/dispatch.zig");
const platform = @import("../platform/root.zig");

/// The minimum Vulkan the driver must report.
///
/// Ports `kRequiredVulkanVersion` (`BackendVk.h:53`). Dawn's comment at
/// `:50`-`:52` records why 1.1 rather than 1.0: some Vulkan 1.0 drivers are
/// poor enough to be unusable. The same value reaches `VkApplicationInfo`
/// (`BackendVk.cpp:486`) and the loader gate (`BackendVk.cpp:404`).
pub const required_vulkan_version: u32 = vulkan.VK_API_VERSION_1_1;

/// One installable driver, and the library that reaches it.
///
/// Ports `enum class ICD` (`BackendVk.h:55`-`:58`). Dawn orders the enum with
/// `None` first and searches `kICDs` instead, so the order that matters is
/// `icd_search_order`.
pub const Icd = enum(u8) {
    /// Dawn's `ICD::SwiftShader`, the software fallback.
    swiftshader,
    /// Dawn's `ICD::None`, the system loader and whatever it finds.
    system,
};

/// Dawn's `kICDCount` (`BackendVk.h:59`).
pub const icd_count = 2;

/// The search order, fallback first.
///
/// Ports `kICDs` (`BackendVk.cpp:194`-`:204`). Dawn's comment at `:192`-`:193`
/// is the rule: fallback ICDs are searched first so a caller that asked for a
/// forced fallback adapter is answered by the fallback. Dawn keeps the two
/// entries behind `#if defined(DAWN_ENABLE_SWIFTSHADER)` and
/// `#if !defined(MEMORY_SANITIZER)`; this repository has no build flag to
/// mirror, so a library that is not installed is a candidate that fails to
/// open and the search moves on, which is what `Backend::cacheIcd` does.
pub const icd_search_order = [_]Icd{ .swiftshader, .system };

/// The Google vendor id, from `src/dawn/gpu_info.json:169`-`:170`.
const swiftshader_vendor_id: u32 = 0x1AE0;

/// The one SwiftShader device id, from `src/dawn/gpu_info.json:172`-`:175`.
const swiftshader_device_id: u32 = 0xC0DE;

/// The library an ICD is reached through.
///
/// Ports `kSwiftshaderLibName` (`BackendVk.cpp:50`) and `kVulkanLibName`
/// (`BackendVk.cpp:64`) for Linux, the platform both configurations run on
/// (`docs/50-verification.md` §5.1 and §5.2). The name selection at
/// `BackendVk.cpp:48`-`:74` has no row: a build flag chooses the name there
/// and there is no flag here.
pub fn icdLibraryName(icd: Icd) [:0]const u8 {
    return switch (icd) {
        .swiftshader => "libvk_swiftshader.so",
        .system => "libvulkan.so.1",
    };
}

/// The index an ICD owns in the per-ICD tables, which is Dawn's
/// `mVulkanInstances[icd]` subscript (`BackendVk.cpp:607`).
fn icdIndex(icd: Icd) usize {
    return @intFromEnum(icd);
}

/// One Vulkan handle type `dusk` creates at this milestone.
///
/// Dawn's `FENCED_DELETER_TYPES` (`FencedDeleter.h:49`-`:66`) lists 17 types in
/// deletion order. This milestone creates 7 of them, plus the two parent
/// objects Dawn destroys outside the list. `VkPhysicalDevice` is absent on
/// purpose: Dawn's destructor comment at `BackendVk.cpp:325` states that the
/// physical devices die with the instance, so there is nothing to destroy and
/// nothing to count.
pub const HandleKind = enum(u8) {
    instance,
    device,
    command_pool,
    command_buffer,
    buffer,
    memory,
    fence,
};

/// How many handle kinds there are, which is the width of `HandleSet.counts`.
///
/// `HandleKind` deliberately declares no `count` member. `acquire`, `release`
/// and `firstLeakedKind` all walk `std.enums.values(HandleKind)`, so a member
/// standing for a total would read as a handle type: acquirable, releasable,
/// and reportable as a leak.
pub const handle_kind_count: usize = @typeInfo(HandleKind).@"enum".fields.len;

/// One counter per live handle, so a teardown that misses a destroy is a
/// number and not a silent leak.
///
/// Dawn has no equivalent. `FencedDeleter` holds a deletion queue per type
/// (`FencedDeleter.h:92`-`:97`) and reports the last serial a deletion is
/// pending at (`FencedDeleter.h:85`), which answers "has it gone out yet" but
/// not "is anything still live". The acceptance needs the second question,
/// so this is a count that rises on every create and falls on every destroy.
pub const HandleSet = struct {
    counts: [handle_kind_count]u32 = @splat(0),

    /// Records one create. `AGENTS.md` §5 makes a no-leak claim meaningless
    /// without a leak-detecting allocator, and the counter is what turns that
    /// allocator's report into a named type.
    pub fn acquire(set: *HandleSet, kind: HandleKind) void {
        set.counts[@intFromEnum(kind)] += 1;
    }

    /// Records one destroy. A destroy with no create is the defect this set
    /// exists to find, so it is refused rather than allowed to wrap: the
    /// arithmetic is unsigned, and a wrapped counter would report a huge live
    /// count that names nothing.
    pub fn release(set: *HandleSet, kind: HandleKind) void {
        const slot = &set.counts[@intFromEnum(kind)];
        std.debug.assert(slot.* > 0);
        slot.* -= 1;
    }

    /// How many handles of one kind are live.
    pub fn countOf(set: *const HandleSet, kind: HandleKind) u32 {
        return set.counts[@intFromEnum(kind)];
    }

    /// How many handles are live over every kind.
    pub fn totalCount(set: *const HandleSet) u32 {
        var total: u32 = 0;
        for (set.counts) |count| total += count;
        return total;
    }

    /// Whether the teardown released everything it created.
    pub fn isEmpty(set: *const HandleSet) bool {
        return set.totalCount() == 0;
    }

    /// The first kind still live, in enumeration order, so a failure names one
    /// type instead of a total.
    pub fn firstLeakedKind(set: *const HandleSet) ?HandleKind {
        for (std.enums.values(HandleKind)) |kind| {
            if (set.countOf(kind) != 0) return kind;
        }
        return null;
    }
};

/// How many backwards branches the `assertErrorSetNamed` walk may take.
///
/// The walk is a product, not a sum: each member of the set under test against
/// each name `named` declares and each name the two merged sets declare. For
/// the widest set here that product is several thousand, the count is fixed by
/// the error sets the caller passes rather than by anything the loop decides,
/// and the default budget stops at a thousand. So the budget is raised to a
/// number the widest walk needs, which leaves it able to catch a walk that
/// grows without bound instead of silencing one that is merely large.
const error_set_walk_branch_budget: u32 = 100_000;

/// Whether one member of the set under test is accounted for, by `named` or by
/// one of the merged sets this file does not raise itself.
///
/// One member in, one answer out. The scans live here rather than in the
/// walk's body so a fifth merged set is one more loop in one place instead of
/// a fifth scan per member.
fn errorIsAccountedFor(
    comptime ErrorSet: type,
    comptime member_name: [:0]const u8,
    comptime named: []const ErrorSet,
) bool {
    for (named) |err| {
        if (std.mem.eql(u8, @errorName(err), member_name)) return true;
    }
    for (@typeInfo(platform.Loader.OpenError).error_set.?) |merged| {
        if (std.mem.eql(u8, merged.name, member_name)) return true;
    }
    for (@typeInfo(dispatch.Error).error_set.?) |merged| {
        if (std.mem.eql(u8, merged.name, member_name)) return true;
    }
    for (@typeInfo(dispatch.LoadError).error_set.?) |merged| {
        if (std.mem.eql(u8, merged.name, member_name)) return true;
    }
    return false;
}

/// Why an entry point this file reaches is not there, or what a `VkResult`
/// code means.
///
/// `dispatch.LoadError` is `src/vk/dispatch.zig`'s own answer to "a proc is not
/// there" (`:307`-`:324`), and `AGENTS.md` §3.1 makes that file the only place
/// the question is answered. It is the half of the set a call site returns
/// after binding a dispatch field, so a null field and a loader that refused
/// to fill one report the same member instead of the second being a forced
/// unwrap. `dispatch.Error` is the `VkResult` mapping the same section names.
pub const ProcError = dispatch.LoadError || dispatch.Error;

/// Asserts that every member of `ErrorSet` is either named in `named`, or comes
/// from a merged set this file does not raise itself.
///
/// The merged members are enumerated from the merged sets rather than listed,
/// so this stays correct when a dependency's set changes. `dispatch.Error` is
/// exempt because `AGENTS.md` §3.1 makes `src/vk/dispatch.zig` the only place a
/// driver code becomes a Zig value, and that file's own comptime check
/// (`src/vk/dispatch.zig:1322`-`:1366`) names every member. `dispatch.LoadError`
/// is exempt for the same reason and one more: its doc comment
/// (`dispatch.zig:307`-`:324`) is what says which tier a missing proc belongs
/// to, and a call site that binds a dispatch field has to report the same
/// answer.
pub fn assertErrorSetNamed(comptime ErrorSet: type, comptime named: []const ErrorSet) void {
    @setEvalBranchQuota(error_set_walk_branch_budget);
    comptime {
        for (@typeInfo(ErrorSet).error_set.?) |member| {
            if (!errorIsAccountedFor(ErrorSet, member.name, named)) {
                @compileError("error." ++ member.name ++ " is in no table row");
            }
        }
    }
}

/// Destroys an instance the loader created, reporting rather than unwrapping.
///
/// `destroy_instance` is filled by `loadInstanceProcs`
/// (`src/vk/dispatch.zig:462`-`:465`) and not by `loadGlobalProcs`, which is why
/// this reads the field where the loader has written it rather than taking a
/// binding at the top of `VulkanInstance.create`. A loader that created an
/// instance and cannot destroy it has failed in a way nothing here can undo, and
/// that is the error the caller reads.
fn destroyInstance(global: *const dispatch.GlobalProcs, handle: vulkan.VkInstance) ProcError!void {
    const destroy_instance = global.destroy_instance orelse
        return error.MissingGlobalProc;
    destroy_instance(handle, null);
}

/// One opened Vulkan library, one `VkInstance`, and the two proc tiers that
/// hang off it.
///
/// Ports `VulkanInstance` (`BackendVk.h:71`-`:108`) with its four out-of-line
/// accessors (`BackendVk.cpp:332`-`:346`) and `Initialize`
/// (`:355`-`:433`). It is one per ICD, not one per device, which is the whole
/// point of the fallback-first search: each ICD gets its own instance so its
/// devices stay bound to its driver (`BackendVk.h:63`-`:66`).
pub const VulkanInstance = struct {
    /// Which driver this instance belongs to.
    icd: Icd,
    /// The open library. It outlives every proc in `global`, so it is closed
    /// last (`BackendVk.cpp:400` loads through it, `:317` destroys through it).
    lib: platform.Loader,
    /// The global tier, which owns `destroy_instance` because a failed instance
    /// creation still has to be undone (`VulkanFunctions.h:89`-`:91`).
    global: *dispatch.GlobalProcs,
    /// The instance handle. Null after `deinit`.
    vk_instance: vulkan.VkInstance,
    /// The instance tier, loaded with the instance
    /// (`VulkanFunctions.cpp:125`-`:127`).
    procs: *dispatch.InstanceProcs,
    /// What `vkEnumerateInstanceVersion` reported, or the loader's default of
    /// 1.0 when it does not export the call.
    loader_api_version: u32,

    pub const InitOptions = struct {
        /// Which driver's library to open (`BackendVk.cpp:371`-`:385`).
        icd: Icd,
        /// Where the live-handle count goes.
        handles: *HandleSet,
    };

    pub const CreateError = std.mem.Allocator.Error || platform.Loader.OpenError ||
        dispatch.LoadError || dispatch.Error ||
        error{
            /// The loader reported less than `required_vulkan_version`.
            /// `VulkanInstance::Initialize` returns
            /// `DAWN_UNRECOVERABLE_ERROR` here (`BackendVk.cpp:404`-`:410`).
            VulkanVersionUnsupported,
            /// `vkCreateInstance` succeeded and returned null, which
            /// `BackendVk.cpp:532` asserts against.
            InstanceCreationReturnedNull,
        };

    pub const EnumerateError = ProcError || std.mem.Allocator.Error ||
        error{
            /// `GatherPhysicalDevices` (`VulkanInfo.cpp:140`-`:162`) counts the
            /// devices; an ICD that counts zero has nothing to offer.
            NoPhysicalDevice,
            /// The driver reported a different count on the second call and
            /// did not settle within `max_enumeration_retry_count`.
            EnumerationCountUnstable,
        };

    /// How many times enumeration is retried after `VK_INCOMPLETE`. Dawn calls
    /// once and asserts (`VulkanInfo.cpp:147`-`:158`); a device set that moves
    /// between the two calls is a driver defect, and the port reports it
    /// instead of retrying forever.
    pub const max_enumeration_retry_count = 2;

    /// Ports `VulkanInstance::Create` (`BackendVk.cpp:349`) with
    /// `Initialize` (`:355`) and `CreateVkInstance` (`:435`).
    pub fn create(gpa: std.mem.Allocator, options: InitOptions) CreateError!VulkanInstance {
        var lib: platform.Loader = .closed();
        try lib.open(gpa, .{ .path = icdLibraryName(options.icd) });
        errdefer lib.deinit();

        // `LoadGlobalProcs` (`BackendVk.cpp:400`).
        const global = try dispatch.loadGlobalProcs(gpa, &lib.lib);
        errdefer gpa.destroy(global);

        // The gate at `BackendVk.cpp:404`, before the instance exists, because
        // a 1.0 loader cannot create a 1.1 instance.
        const api_version = try queryLoaderApiVersion(global);

        const app_info: vulkan.VkApplicationInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_APPLICATION_INFO),
            // Dawn writes "Dawn" (`BackendVk.cpp:484`). This is not Dawn, so the
            // string names this engine; a driver that logs it must not be told
            // it is talking to Dawn.
            .pEngineName = "dusk",
            // `appInfo.apiVersion = kRequiredVulkanVersion` (`BackendVk.cpp:486`).
            .apiVersion = required_vulkan_version,
        };
        const create_info: vulkan.VkInstanceCreateInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO),
            .pApplicationInfo = &app_info,
            // No layer, and no instance extension, is requested here. The
            // acceptance runs with `VK_LOADER_LAYERS_DISABLE=*`
            // (`docs/50-verification.md` §4.2), and the extensions that gate a
            // proc land with the milestone that uses them: `VK_KHR_surface` is
            // M20, and `VK_EXT_debug_utils` is the row this file skips.
            .enabledLayerCount = 0,
            .enabledExtensionCount = 0,
        };

        // `create_instance` and `get_instance_proc_addr` are the two global
        // entry points `loadGlobalProcs` has already filled, so they are bound
        // here. `destroy_instance` is the third and is NOT: the loader fills it
        // from `loadInstanceProcs` (`src/vk/dispatch.zig:462`-`:465`), so it is
        // read by the undo path after that call rather than bound now.
        const create_instance = global.create_instance orelse
            return error.MissingGlobalProc;
        const get_instance_proc_addr = global.get_instance_proc_addr orelse
            return error.MissingGlobalProc;

        var handle: vulkan.VkInstance = null;
        try dispatch.checkVkSuccess(create_instance(&create_info, null, &handle));
        if (handle == null) return error.InstanceCreationReturnedNull;

        options.handles.acquire(.instance);
        errdefer options.handles.release(.instance);

        // `LoadInstanceProcs` (`BackendVk.cpp:415`). This is the last fallible
        // step: everything after it is a struct literal, so the instance lives
        // until `deinit` and the only undo this call needs is for itself.
        const procs = dispatch.loadInstanceProcs(gpa, .{
            .get_instance_proc_addr = get_instance_proc_addr,
            .instance = handle,
            .enabled_extensions = .{},
            .global = global,
        }) catch |err| {
            // The loader owns the undo for an instance it created, so the
            // instance goes before the error this block was entered on does.
            // `errdefer` cannot carry that second failure, which is why the
            // undo is an ordinary statement in the handler.
            try destroyInstance(global, handle);
            return err;
        };

        return .{
            .icd = options.icd,
            .lib = lib,
            .global = global,
            .vk_instance = handle,
            .procs = procs,
            .loader_api_version = api_version,
        };
    }

    /// Ports `VulkanInstance::~VulkanInstance` (`BackendVk.cpp:317`-`:330`),
    /// which destroys the messenger and then the instance. This file creates no
    /// messenger, so the instance is the whole teardown.
    ///
    /// `VkPhysicalDevice` handles are not destroyed: Dawn's comment at
    /// `BackendVk.cpp:325` says they die with the instance, and nothing here
    /// created one.
    ///
    /// It reports rather than returning `void`, because the proc it reaches is a
    /// dispatch field and `AGENTS.md` §3.1 makes a null one a typed error. The
    /// field is read through `destroyInstance`, which binds it and reports, so
    /// a missing entry point costs the caller the teardown rather than a
    /// half-finished one.
    pub fn deinit(
        self: *VulkanInstance,
        gpa: std.mem.Allocator,
        handles: *HandleSet,
    ) ProcError!void {
        try destroyInstance(self.global, self.vk_instance);
        gpa.destroy(self.procs);
        handles.release(.instance);
        gpa.destroy(self.global);
        self.lib.deinit();
        self.vk_instance = null;
        // The instance is gone and nothing reads the value again, so the
        // receiver is poisoned rather than half reset.
        self.* = undefined;
    }

    /// Ports `GatherPhysicalDevices` (`VulkanInfo.cpp:140`-`:162`).
    ///
    /// The caller owns the slice and frees it with `gpa`. Zero devices is
    /// `error.NoPhysicalDevice`, not an empty slice, because
    /// `docs/50-verification.md` §5.3 makes a run that enumerated nothing a
    /// failed run.
    pub fn enumeratePhysicalDevices(
        self: *const VulkanInstance,
        gpa: std.mem.Allocator,
    ) EnumerateError![]vulkan.VkPhysicalDevice {
        // The count query and the fetch below are the same entry point, so one
        // binding serves both the retry loop and the first call.
        const enumerate_physical_devices = self.procs.enumerate_physical_devices orelse
            return error.MissingInstanceProc;
        var count: u32 = 0;
        try dispatch.checkVkSuccess(enumerate_physical_devices(
            self.vk_instance,
            &count,
            null,
        ));
        if (count == 0) return error.NoPhysicalDevice;

        const devices = try gpa.alloc(vulkan.VkPhysicalDevice, count);
        errdefer gpa.free(devices);

        var attempt: usize = 0;
        while (attempt < max_enumeration_retry_count) : (attempt += 1) {
            // The count is the array capacity ON INPUT and the written count on
            // output, so it must carry `count` in, not zero: a zero capacity says
            // "my array holds no devices", and a spec-conforming driver answers
            // VK_INCOMPLETE with nothing written, which no retry can fix.
            var written: u32 = count;
            const result = enumerate_physical_devices(
                self.vk_instance,
                &written,
                devices.ptr,
            );
            // `checkVkSuccess` turns `VK_INCOMPLETE` into
            // `error.UnexpectedOutcome`, which is the only outcome a retry can
            // fix. Reading the raw code here would put a second `VkResult`
            // mapping outside `src/vk/dispatch.zig`, which `AGENTS.md` §3.1
            // forbids.
            dispatch.checkVkSuccess(result) catch |err| switch (err) {
                error.UnexpectedOutcome => continue,
                else => |fatal| return fatal,
            };
            if (written > count) return error.EnumerationCountUnstable;
            return devices[0..written];
        }
        return error.EnumerationCountUnstable;
    }
};

/// Reads what the loader reports, and refuses one below the floor.
///
/// The check is `mGlobalInfo.apiVersion < kRequiredVulkanVersion` at
/// `BackendVk.cpp:404`. `GatherGlobalInfo` (`VulkanInfo.cpp:81`-`:94`) fills
/// the field from `vkEnumerateInstanceVersion`, which is Vulkan 1.1
/// (`VulkanFunctions.h:93`-`:94`), so a loader that does not export it reports
/// 1.0 and fails here.
fn queryLoaderApiVersion(global: *const dispatch.GlobalProcs) VulkanInstance.CreateError!u32 {
    const enumerate_version = global.enumerate_instance_version orelse
        return error.VulkanVersionUnsupported;
    var api_version: u32 = 0;
    try dispatch.checkVkSuccess(enumerate_version(&api_version));
    if (api_version < required_vulkan_version) return error.VulkanVersionUnsupported;
    return api_version;
}

/// One physical device and the property tables this milestone reads.
///
/// Ports the caching half of `PhysicalDevice` (`PhysicalDeviceVk.h:133`-`:136`).
/// It owns no Vulkan handle of its own: the `VkPhysicalDevice` belongs to the
/// instance that reported it, and the tables are copies taken once so the
/// admission rules and the queue-family scan do not re-query the driver.
pub const PhysicalDevice = struct {
    /// The handle the owning instance reported.
    handle: vulkan.VkPhysicalDevice,
    properties: vulkan.VkPhysicalDeviceProperties,
    features: vulkan.VkPhysicalDeviceFeatures,
    memory_properties: vulkan.VkPhysicalDeviceMemoryProperties,
    /// The largest `VkBuffer` the device accepts, which no
    /// `VkPhysicalDeviceLimits` field carries.
    ///
    /// Ports `PhysicalDeviceVk.cpp:940`-`:945`, and it is the reason the port
    /// reads a properties chain at all. Vulkan carries the limit in two
    /// promoted structs, `VkPhysicalDeviceMaintenance4Properties` and
    /// `VkPhysicalDeviceVulkan13Properties`, and upstream reads the first and
    /// falls back to `maxMemoryAllocationSize` in
    /// `VkPhysicalDeviceMaintenance3Properties`, so the port takes those two
    /// and not the 1.3 block.
    max_buffer_size: vulkan.VkDeviceSize,
    /// The queue families, in the driver's own order. The caller frees this.
    queue_families: []vulkan.VkQueueFamilyProperties,

    pub const GatherError = std.mem.Allocator.Error || ProcError || error{
        /// The family count grew between the two calls, which the second call
        /// cannot serve because the array was sized by the first.
        QueueFamilyCountUnstable,
    };

    /// Ports the `GatherDeviceInfo` passes this milestone uses
    /// (`VulkanInfo.cpp:164`-`:439`): properties first, then the properties
    /// chain, then memory, then queue families.
    pub fn gather(
        gpa: std.mem.Allocator,
        procs: *const dispatch.InstanceProcs,
        handle: vulkan.VkPhysicalDevice,
    ) GatherError!PhysicalDevice {
        // Every entry point below is bound before its first call, because
        // `AGENTS.md` §3.1 makes a null dispatch field a typed error. The queue
        // family one is bound once for the count query and the fetch.
        const get_properties = procs.get_physical_device_properties orelse
            return error.MissingInstanceProc;
        const get_features = procs.get_physical_device_features orelse
            return error.MissingInstanceProc;
        const get_memory_properties = procs.get_physical_device_memory_properties orelse
            return error.MissingInstanceProc;
        const get_queue_family_properties =
            procs.get_physical_device_queue_family_properties orelse
            return error.MissingInstanceProc;

        // `VulkanInfo.cpp:171`. The chain below does not carry this block:
        // Dawn fills `info.properties` from the plain call and keeps the two
        // apart, so the port makes two calls too.
        // SAFETY: `vkGetPhysicalDeviceProperties` is an out-parameter call:
        // the driver writes every field of the struct before the statement
        // returns, and the next read is the literal below.
        var properties: vulkan.VkPhysicalDeviceProperties = undefined;
        get_properties(handle, &properties);

        const max_buffer_size = try queryMaxBufferSize(gpa, procs, handle);

        // SAFETY: `vkGetPhysicalDeviceFeatures`, same out-parameter shape as
        // the properties above.
        var features: vulkan.VkPhysicalDeviceFeatures = undefined;
        get_features(handle, &features);

        // SAFETY: `vkGetPhysicalDeviceMemoryProperties`, same out-parameter
        // shape as the properties above.
        var memory_properties: vulkan.VkPhysicalDeviceMemoryProperties = undefined;
        get_memory_properties(handle, &memory_properties);

        var family_count: u32 = 0;
        get_queue_family_properties(handle, &family_count, null);
        const families = try gpa.alloc(vulkan.VkQueueFamilyProperties, family_count);
        errdefer gpa.free(families);
        get_queue_family_properties(handle, &family_count, families.ptr);
        if (family_count > families.len) return error.QueueFamilyCountUnstable;

        return .{
            .handle = handle,
            .properties = properties,
            .features = features,
            .memory_properties = memory_properties,
            .max_buffer_size = max_buffer_size,
            .queue_families = families[0..family_count],
        };
    }

    /// Ports the per-device `DAWN_ASSERT(info.properties.apiVersion >=
    /// kRequiredVulkanVersion)` at `VulkanInfo.cpp:247`, as a filter rather
    /// than an assertion. A 1.0 device must never reach `vkCreateDevice`, and
    /// the acceptance names the filter: it selects the first device that
    /// reports 1.1 or later.
    pub fn supportsRequiredVersion(self: *const PhysicalDevice) bool {
        return self.properties.apiVersion >= required_vulkan_version;
    }

    /// Whether this is the fallback adapter, which is what
    /// `forceFallbackAdapter` filters on.
    ///
    /// Ports the `IsFallbackAdapter` lambda at `BackendVk.cpp:581`-`:588`,
    /// which calls `gpu_info::IsGoogleSwiftshader(vendorId, deviceId)`. The ids
    /// come from `src/dawn/gpu_info.json:169`-`:177`.
    pub fn isFallback(self: *const PhysicalDevice) bool {
        return self.properties.vendorID == swiftshader_vendor_id and
            self.properties.deviceID == swiftshader_device_id;
    }

    /// The lowest family carrying every flag in `required_flags`, or null.
    ///
    /// Ports the universal-family scan at `DeviceVk.cpp:737`-`:755`: Dawn takes
    /// the first family whose flags contain `GRAPHICS | COMPUTE`, and its
    /// comment at `:739` records why `TRANSFER` is not checked. The first match
    /// is Dawn's rule, not a preference; a port that chose a discrete family
    /// would answer a different question.
    pub fn findQueueFamilyIndex(
        self: *const PhysicalDevice,
        required_flags: vulkan.VkQueueFlags,
    ) ?u32 {
        // Bound: the family count the driver reported.
        var index: u32 = 0;
        while (index < self.queue_families.len) : (index += 1) {
            const family = self.queue_families[index];
            if ((family.queueFlags & required_flags) == required_flags) return index;
        }
        return null;
    }

    /// The device name without its terminator, for a log line.
    pub fn deviceName(self: *const PhysicalDevice) []const u8 {
        const name = &self.properties.deviceName;
        const length = std.mem.indexOfScalar(u8, name, 0) orelse name.len;
        return name[0..length];
    }
};

/// The index a memory type has to carry for an allocation to be legal.
pub const MemoryTypeError = error{
    /// No type in the table satisfies the request. Dawn's selector returns
    /// `kInvalidMemoryTypeIndex` (`MemoryTypeSelector.h:51`) and its caller
    /// turns that into an unrecoverable error
    /// (`ResourceMemoryAllocatorVk.cpp:185`-`:193`).
    NoMemoryType,
};

/// The lowest memory type that satisfies the request.
///
/// Ports the two hard requirements of `MemoryTypeSelector::FindBestTypeIndex`
/// (`MemoryTypeSelector.cpp:161`-`:181`, `GetRequiredMemoryPropertyFlags`)
/// without its five ordered tie-breaks (`:72`-`:155`). M9 needs exactly one
/// answer, for the buffer the acceptance fills, and the tie-breaks choose
/// between types that are all legal for it. The port records the rule it does
/// keep: a type must be inside the allocation's `memoryTypeBits`, must carry
/// every required flag, and must carry no forbidden one.
///
/// `VK_MEMORY_PROPERTY_DEVICE_LOCAL` is the forbidden flag here because
/// `vkCmdFillBuffer` on device-local memory is legal and a driver may satisfy
/// it by doing nothing, and a test that cannot tell a fill from a no-op is not
/// evidence (`docs/50-verification.md` §3.2).
pub fn findMemoryTypeIndex(
    memory_properties: *const vulkan.VkPhysicalDeviceMemoryProperties,
    memory_type_bits: u32,
    required_flags: vulkan.VkMemoryPropertyFlags,
    forbidden_flags: vulkan.VkMemoryPropertyFlags,
) MemoryTypeError!u32 {
    // Bound: `VK_MAX_MEMORY_TYPES`, which the driver never exceeds.
    var index: u32 = 0;
    while (index < memory_properties.memoryTypeCount) : (index += 1) {
        const type_bit: u32 = @as(u32, 1) << @intCast(index);
        if ((memory_type_bits & type_bit) == 0) continue;
        const flags = memory_properties.memoryTypes[index].propertyFlags;
        if ((flags & required_flags) != required_flags) continue;
        if ((flags & forbidden_flags) != 0) continue;
        return index;
    }
    return error.NoMemoryType;
}

/// The device extensions this milestone turns on at `vkCreateDevice`.
///
/// `VK_KHR_dynamic_rendering` is the only one, and the render path does not
/// work without it: `src/pipeline/pipeline_render.zig` chains
/// `VkPipelineRenderingCreateInfo` with `renderPass = null` (`:751`-`:772`),
/// and on a Vulkan 1.1 device the extension is the only thing that makes that
/// legal. Dawn names it at `VulkanExtensions.cpp:141`, under the
/// `// Promoted in 1.3` comment at `:135`, asserts it at `DeviceVk.cpp:714`,
/// and then selects `VulkanRenderPassType::DynamicRendering` (`:711`-`:717`).
///
/// Raising `required_vulkan_version` instead would be wrong twice over. Dawn's
/// own floor is 1.1 (`BackendVk.h:53`) and the loader gate
/// (`VulkanInfo.cpp:86`-`:94`) reads what `vkEnumerateInstanceVersion` wrote
/// (`:87`-`:88`), the loader's own version: a 1.1 loader cannot create a 1.2
/// instance even when the driver is newer. And 1.2 would not have supplied
/// this either, because the promotion above is to 1.3.
const required_device_ext: dispatch.DeviceExt = .dynamic_rendering;

/// Whether `handle` advertises `ext_name` in the list `vkCreateDevice` would
/// read.
///
/// Ports the device-extension pass of `GatherDeviceInfo`
/// (`VulkanInfo.cpp:212`-`:238`), reduced to the one name asked about. Dawn
/// reduces it to a bitset (`info.extensions.set(it->second, true)`, `:232`)
/// and gates everything else on it.
///
/// The parameter is a name and not a `dispatch.DeviceExt` because that enum
/// is one member per extension that gates a `DeviceProcs` field
/// (`src/vk/dispatch.zig:378`-`:383`), and `VK_KHR_maintenance4` gates none.
/// Its gate is a property in a chain, which is why it is not there.
fn deviceAdvertisesExtension(
    gpa: std.mem.Allocator,
    procs: *const dispatch.InstanceProcs,
    handle: vulkan.VkPhysicalDevice,
    ext_name: [:0]const u8,
) (std.mem.Allocator.Error || ProcError)!bool {
    // The count query and the fetch below are the same entry point, so one
    // binding serves the pair.
    const enumerate_extensions =
        procs.enumerate_device_extension_properties orelse
        return error.MissingInstanceProc;
    // A null `pLayerName` asks for the device's own list, which is the list
    // `vkCreateDevice` is about to be handed.
    var count: u32 = 0;
    try dispatch.checkVkSuccess(enumerate_extensions(
        handle,
        null,
        &count,
        null,
    ));
    if (count == 0) return false;

    const properties = try gpa.alloc(vulkan.VkExtensionProperties, count);
    defer gpa.free(properties);
    try dispatch.checkVkSuccess(enumerate_extensions(
        handle,
        null,
        &count,
        properties.ptr,
    ));

    for (properties[0..count]) |property| {
        // `VkExtensionProperties::extensionName` is `[256]u8`
        // (`src/vulkan.zig:4287`), a fixed array with no sentinel, so
        // `std.mem.span` cannot read it. The name is truncated at the first
        // zero, which is the same shape `deviceName` uses at `:630`-`:633`.
        const name = &property.extensionName;
        const length = std.mem.indexOfScalar(u8, name, 0) orelse name.len;
        if (std.mem.eql(u8, name[0..length], ext_name)) return true;
    }
    return false;
}

/// Reads the largest buffer the driver accepts, which no
/// `VkPhysicalDeviceLimits` member carries.
///
/// Ports the `VkPhysicalDeviceProperties2` chain Dawn builds at
/// `VulkanInfo.cpp:254`-`:260` and sends at `:410`, its Maintenance4 append at
/// `:306`-`:309`, and the assignment at `PhysicalDeviceVk.cpp:940`-`:945`.
fn queryMaxBufferSize(
    gpa: std.mem.Allocator,
    procs: *const dispatch.InstanceProcs,
    handle: vulkan.VkPhysicalDevice,
) (std.mem.Allocator.Error || ProcError)!vulkan.VkDeviceSize {
    // Bound before the chain is built, because `AGENTS.md` §3.1 makes a null
    // dispatch field a typed error and the chain is the out-parameter it fills.
    const get_properties2 = procs.get_physical_device_properties2 orelse
        return error.MissingInstanceProc;
    // `VulkanInfo.cpp:259`-`:260` chains Maintenance3 with no `HasExt` test in
    // front of it, because the struct is core in Vulkan 1.1 and the floor at
    // `vulkan_device.zig:39` is 1.1.
    var maintenance3: vulkan.VkPhysicalDeviceMaintenance3Properties = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_3_PROPERTIES),
        .pNext = null,
        .maxPerSetDescriptors = 0,
        .maxMemoryAllocationSize = 0,
    };
    // `VulkanInfo.cpp:306`-`:309` chains Maintenance4 only where
    // `HasExt(DeviceExt::Maintenance4)` holds, and so does this. The gate is
    // the same shape as the one `Device.create` puts on `dynamic_rendering`
    // (`vulkan_device.zig:937`-`:942`): the device's own extension list, read by
    // `deviceAdvertisesExtension`. A chain that names a struct the device
    // cannot take is refused by the validation layer, and `AGENTS.md` §3.1
    // makes the library run with no layer.
    var maintenance4: vulkan.VkPhysicalDeviceMaintenance4Properties = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_4_PROPERTIES),
        .pNext = null,
        .maxBufferSize = 0,
    };
    const has_maintenance4 = try deviceAdvertisesExtension(
        gpa,
        procs,
        handle,
        vulkan.VK_KHR_MAINTENANCE_4_EXTENSION_NAME,
    );
    // `pNext` is a plain pointer, so the driver writes straight into both
    // blocks. The block behind the link is zeroed by its own literal.
    maintenance3.pNext = if (has_maintenance4) @ptrCast(&maintenance4) else null;
    var properties2: vulkan.VkPhysicalDeviceProperties2 = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2),
        .pNext = @ptrCast(&maintenance3),
        // Zeroed because the driver fills the core block too, which is what
        // `queryDynamicRendering` does with the features block at `:841`-`:845`.
        .properties = std.mem.zeroes(vulkan.VkPhysicalDeviceProperties),
    };
    get_properties2(handle, &properties2);
    // `PhysicalDeviceVk.cpp:941`-`:945`: Maintenance4's own limit where the
    // extension answered, and Maintenance3's allocation ceiling where it did
    // not. Dawn seeds the field with `kAssumedMaxBufferSize` first (`:940`),
    // which matters only if neither branch runs, and one of the two always
    // does here. The fallback is the conservative one: no allocation, and so
    // no buffer, can be larger than the ceiling.
    return if (has_maintenance4)
        maintenance4.maxBufferSize
    else
        maintenance3.maxMemoryAllocationSize;
}

/// What the driver reports for `VkPhysicalDeviceDynamicRenderingFeatures`.
///
/// Ports the chain Dawn builds at `VulkanInfo.cpp:391`-`:394` and copies into
/// the create info at `DeviceVk.cpp:715`. The bit is read rather than
/// asserted: a pipeline carrying `VkPipelineRenderingCreateInfo` is legal only
/// where `dynamicRendering` is enabled, and the driver is the only authority
/// on that.
fn queryDynamicRendering(
    procs: *const dispatch.InstanceProcs,
    handle: vulkan.VkPhysicalDevice,
) ProcError!vulkan.VkPhysicalDeviceDynamicRenderingFeatures {
    // Bound before the chain is built, for the reason the properties chain
    // above gives: it is the out-parameter this call fills.
    const get_features2 = procs.get_physical_device_features2 orelse
        return error.MissingInstanceProc;
    const s_type: vulkan.VkStructureType =
        @intCast(vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR);
    var dynamic: vulkan.VkPhysicalDeviceDynamicRenderingFeatures = .{
        .sType = s_type,
        .pNext = null,
        .dynamicRendering = 0,
    };
    // `pNext` is a plain pointer, so the driver writes straight into `dynamic`.
    // `features` is zeroed because the driver fills the core block too.
    var features: vulkan.VkPhysicalDeviceFeatures2 = .{
        .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2),
        .pNext = @ptrCast(&dynamic),
        .features = std.mem.zeroes(vulkan.VkPhysicalDeviceFeatures),
    };
    get_features2(handle, &features);
    return dynamic;
}

/// One `VkDevice` and the device-tier procs behind it.
///
/// Ports the creation half of `Device::CreateDevice`
/// (`DeviceVk.cpp:443`-`:790`) and its accessors. It does not port the
/// feature and limits negotiation (`PhysicalDeviceVk.cpp:285`-`:990`), which
/// lands with `VulkanExtensions`. The one exception is
/// `required_device_ext` and the feature it needs, because
/// `pipeline_render.zig` cannot create a pipeline without them and the file
/// that would negotiate them is M7's.
pub const Device = struct {
    /// The device handle. Null after `deinit`.
    vk_device: vulkan.VkDevice,
    /// The device tier, one set per device
    /// (`docs/30-port-design.md` §6.3).
    procs: *dispatch.DeviceProcs,
    /// The instance that created it. A device cannot outlive its instance, so
    /// the borrowed pointer is the lifetime rule as well as a convenience.
    instance: *VulkanInstance,
    /// The physical device it was created from, by value: the tables were
    /// copied at `PhysicalDevice.gather` and the caller may free them first.
    physical: PhysicalDevice,
    /// The one family the device was created with.
    queue_family_index: u32,
    /// Where the live-handle count goes. A caller that creates a buffer or a
    /// memory allocation on this device has to record it here or the teardown
    /// assertion cannot see it.
    handles: *HandleSet,

    pub const CreateOptions = struct {
        instance: *VulkanInstance,
        physical: *const PhysicalDevice,
        handles: *HandleSet,
    };

    pub const CreateError = std.mem.Allocator.Error || dispatch.LoadError || dispatch.Error ||
        error{
            /// No family carries `GRAPHICS | COMPUTE`. Dawn returns
            /// `DAWN_UNRECOVERABLE_ERROR("No universal queue family")` at
            /// `DeviceVk.cpp:752`.
            NoUniversalQueueFamily,
            /// `vkCreateDevice` succeeded and returned null, which
            /// `DeviceVk.cpp:786` passes straight on as a success.
            DeviceCreationReturnedNull,
        };

    /// Ports `Device::CreateDevice` (`DeviceVk.cpp:443`): the queue-family scan
    /// (`:737`-`:755`), the single queue request (`:757`-`:770`), and
    /// `vkCreateDevice` (`:786`).
    pub fn create(gpa: std.mem.Allocator, options: CreateOptions) CreateError!Device {
        // `kUniversalFlags` at `DeviceVk.cpp:740`.
        const universal_flags: vulkan.VkQueueFlags =
            vulkan.VK_QUEUE_GRAPHICS_BIT | vulkan.VK_QUEUE_COMPUTE_BIT;
        const queue_family_index = options.physical.findQueueFamilyIndex(universal_flags) orelse
            return error.NoUniversalQueueFamily;

        // One queue at priority zero, which is what Dawn requests
        // (`DeviceVk.cpp:757`-`:770`). One queue is what makes per-submit
        // serial tracking correct at all; `QueueVk.h:80`-`:83` says so.
        const priority: f32 = 0.0;
        const queue_create_info: vulkan.VkDeviceQueueCreateInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO),
            .flags = 0,
            .queueFamilyIndex = queue_family_index,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };

        // Every instance entry point below is bound before its first call, and
        // the two that outlive the call are bound together so the `errdefer`
        // destroys through the same binding the create did. `AGENTS.md` §3.1
        // makes a null dispatch field a typed error.
        const instance_procs = options.instance.procs;
        const create_device = instance_procs.create_device orelse
            return error.MissingDeviceProc;
        const destroy_device = instance_procs.destroy_device orelse
            return error.MissingDeviceProc;
        const get_device_proc_addr = instance_procs.get_device_proc_addr orelse
            return error.MissingDeviceProc;

        // Dawn asserts `required_device_ext` at `DeviceVk.cpp:714` and then
        // selects `VulkanRenderPassType::DynamicRendering` (`:711`-`:717`),
        // which is what lets `pipeline_render.zig` build a pipeline with no
        // render pass. The gate is the device's own extension list, the one
        // `GatherDeviceInfo` reads (`VulkanInfo.cpp:212`-`:238`). A device
        // that does not advertise it is still created, because refusing it is
        // an admission rule and admission is M9's row; upstream the same
        // refusal is the `DAWN_CHECK` at `DeviceVk.cpp:714`.
        const render_ext_enabled = try deviceAdvertisesExtension(
            gpa,
            instance_procs,
            options.physical.handle,
            required_device_ext.vkName(),
        );

        var enabled_exts: dispatch.EnabledDeviceExts = .{};
        // One slot, because there is one extension. A fixed array keeps the
        // name pointer alive across the `vkCreateDevice` call without a heap
        // slice the caller would have to free.
        //
        // SAFETY: `extension_names[0]` is written inside the `if` below
        // whenever `extension_count` becomes 1, and `enabled_names` below is
        // null unless that count is nonzero, so the array is read only when
        // the write happened.
        var extension_names: [1][*:0]const u8 = undefined;
        var extension_count: u32 = 0;
        // SAFETY: `dynamic_rendering` is assigned inside the `if` below
        // whenever `render_ext_enabled` is true, and `dynamic_rendering_chain`
        // below is non-null only under that same condition, so the value is
        // read only when the assignment happened.
        var dynamic_rendering: vulkan.VkPhysicalDeviceDynamicRenderingFeatures = undefined;
        if (render_ext_enabled) {
            // The extension without the feature is unusable and the feature
            // without the extension is unreachable, so one decision drives
            // both.
            dynamic_rendering = try queryDynamicRendering(
                instance_procs,
                options.physical.handle,
            );
            extension_names[0] = required_device_ext.vkName();
            extension_count = 1;
            enabled_exts = enabled_exts.with(required_device_ext);
        }
        // The array, or nothing: `pNext` and the extension list are two views
        // of one decision, so both are null when the gate is closed.
        const enabled_names: [*c]const [*c]const u8 = if (extension_count == 0)
            null
        else
            @ptrCast(&extension_names);
        const dynamic_rendering_chain: ?*const anyopaque = if (render_ext_enabled)
            @ptrCast(&dynamic_rendering)
        else
            null;
        const create_info: vulkan.VkDeviceCreateInfo = .{
            .sType = @intCast(vulkan.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO),
            .pQueueCreateInfos = &queue_create_info,
            .queueCreateInfoCount = 1,
            // Dawn enables no layer on the device (`DeviceVk.cpp:780`), and it
            // enables every extension the device advertised
            // (`usedKnobs.extensions = mDeviceInfo.extensions`, `:447`),
            // naming that set at `:450`-`:452`. This milestone turns on one,
            // the render path's, so the name array has a single slot.
            .enabledLayerCount = 0,
            .enabledExtensionCount = extension_count,
            .ppEnabledExtensionNames = enabled_names,
            // `VulkanInfo.cpp:391`-`:394` reads the feature and `DeviceVk.cpp:715`
            // chains it here. Without it `pipeline_render.zig` builds a
            // pipeline the device is not allowed to create.
            .pNext = dynamic_rendering_chain,
            .pEnabledFeatures = null,
        };

        var handle: vulkan.VkDevice = null;
        try dispatch.checkVkSuccess(create_device(
            options.physical.handle,
            &create_info,
            null,
            &handle,
        ));
        if (handle == null) return error.DeviceCreationReturnedNull;

        options.handles.acquire(.device);
        errdefer options.handles.release(.device);
        errdefer destroy_device(handle, null);

        // `LoadDeviceProcs` (`DeviceVk.cpp:135` in `Initialize`).
        const procs = try dispatch.loadDeviceProcs(gpa, .{
            .get_device_proc_addr = get_device_proc_addr,
            .device = handle,
            // The same set the create info carried. The loader resolves a
            // device proc by the extension that carries it
            // (`src/vk/dispatch.zig:761`-`:767`), so a set that disagreed with
            // `ppEnabledExtensionNames` would leave `cmd_begin_rendering_khr`
            // null on a device that has it.
            .enabled_extensions = enabled_exts,
        });

        return .{
            .vk_device = handle,
            .procs = procs,
            .instance = options.instance,
            .physical = options.physical.*,
            .queue_family_index = queue_family_index,
            .handles = options.handles,
        };
    }

    /// Ports the device half of `Device::DestroyImpl` (`DeviceVk.cpp:1146`-`:1148`).
    /// Every queue, command buffer and resource must already be gone; the
    /// `HandleSet` is what proves it.
    ///
    /// It reports rather than returning `void`, because the proc it reaches is a
    /// dispatch field and `AGENTS.md` §3.1 makes a null one a typed error. The
    /// binding comes before the first release, so a missing entry point costs
    /// the caller the teardown rather than a half-finished one.
    pub fn deinit(self: *Device, gpa: std.mem.Allocator) ProcError!void {
        const destroy_device = self.instance.procs.destroy_device orelse
            return error.MissingDeviceProc;
        destroy_device(self.vk_device, null);
        self.handles.release(.device);
        gpa.destroy(self.procs);
        self.vk_device = null;
        // The device is gone and nothing reads the value again, so the receiver
        // is poisoned rather than half reset.
        self.* = undefined;
    }

    /// The handle every device-tier entry point takes first
    /// (`docs/30-port-design.md` §6.3). A caller that already holds the device
    /// gets the handle here rather than reading the field, so a caller that
    /// only wants the handle does not have to name the struct.
    pub fn vkDevice(self: *const Device) vulkan.VkDevice {
        return self.vk_device;
    }

    /// The device tier alone, for a caller that has the handle and wants entry
    /// points rather than the whole `Dispatch`. `dispatchTable` is the other
    /// answer and this is not an alias for it: it does not reach up to the
    /// instance, which is what makes the call site unable to reach an
    /// instance-tier or global-tier entry point by accident.
    ///
    /// The table is borrowed and outlives nothing: `deinit` frees it and sets
    /// the handle to null, so a pointer taken here is valid only until then.
    pub fn deviceProcs(self: *const Device) *const dispatch.DeviceProcs {
        return self.procs;
    }

    /// The three tiers together, for a call site that holds a queue rather than
    /// a device.
    pub fn dispatchTable(self: *const Device) dispatch.Dispatch {
        return .{
            .global = self.instance.global,
            .instance = self.instance.procs,
            .device = self.procs,
        };
    }

    /// The properties the device was created from, including
    /// `pipelineCacheUUID`. The tables were copied at `PhysicalDevice.gather`,
    /// so this stays valid after the adapter list is freed.
    pub fn physicalProperties(self: *const Device) *const vulkan.VkPhysicalDeviceProperties {
        return &self.physical.properties;
    }

    /// The memory-type table the device was created from.
    pub fn memoryProperties(self: *const Device) *const vulkan.VkPhysicalDeviceMemoryProperties {
        return &self.physical.memory_properties;
    }

    /// The largest `VkBuffer` this device accepts.
    ///
    /// `physicalProperties().limits` cannot answer this: the limit is not a
    /// `VkPhysicalDeviceLimits` member, so a caller that reads it there reads
    /// a field that does not exist. The value was resolved once at
    /// `PhysicalDevice.gather` and copied with the rest of the tables, so this
    /// stays valid after the adapter list is freed.
    ///
    /// Ports `limits->v1.maxBufferSize` at `PhysicalDeviceVk.cpp:940`-`:945`.
    pub fn maxBufferSize(self: *const Device) vulkan.VkDeviceSize {
        return self.physical.max_buffer_size;
    }

    /// The one queue of the family the device was created with.
    ///
    /// Ports the `GetDeviceQueue` at `QueueVk.cpp:95`, which runs in
    /// `Queue::Initialize`. The port takes the call on the device because the
    /// queue is a property of the family, and the family is chosen before the
    /// queue exists.
    ///
    /// It reports rather than returning the handle bare, because the proc it
    /// reaches is a dispatch field and `AGENTS.md` §3.1 makes a null one a
    /// typed error. A null handle is still what `Queue.init` refuses with
    /// `error.QueueHandleIsNull`: a driver that reports no queue for a family it
    /// just claimed is a different failure from a loader that has no entry
    /// point for the call.
    pub fn fetchQueue(self: *const Device) ProcError!vulkan.VkQueue {
        const get_device_queue = self.procs.get_device_queue orelse
            return error.MissingDeviceProc;
        var queue: vulkan.VkQueue = null;
        get_device_queue(self.vk_device, self.queue_family_index, 0, &queue);
        return queue;
    }
};

/// One adapter: the device, the physical device behind it, and the instance
/// that keeps that driver alive.
pub const Adapter = struct {
    icd: Icd,
    physical: PhysicalDevice,
    instance: *VulkanInstance,
};

/// The adapters one call to `Backend::discoverPhysicalDevices` answered with.
pub const AdapterList = struct {
    allocator: std.mem.Allocator,
    items: []Adapter,

    pub const FirstError = error{
        /// Zero adapters survived the filters. `docs/50-verification.md` §5.3:
        /// a green run that enumerated nothing has proved nothing.
        NoPhysicalDevice,
    };

    pub fn deinit(self: *AdapterList) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn first(self: AdapterList) FirstError!Adapter {
        if (self.items.len == 0) return error.NoPhysicalDevice;
        return self.items[0];
    }
};

/// The Vulkan back end's per-ICD tables.
///
/// Ports `Backend` (`BackendVk.h:110`-`:124`) with
/// `DiscoverPhysicalDevices` (`BackendVk.cpp:576`-`:640`). The three per-ICD
/// side tables at `BackendVk.h:121`-`:123` are `instances` and
/// `physical_devices`; Dawn's `mVulkanInstancesCreated` bitset is not a row
/// because a null entry already says the instance was not created.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    handles: *HandleSet,
    instances: [icd_count]?*VulkanInstance = @splat(null),
    physical_devices: [icd_count][]PhysicalDevice = @splat(&.{}),

    pub const InitOptions = struct {
        handles: *HandleSet,
    };

    pub const DiscoverOptions = struct {
        /// Dawn's `options->forceFallbackAdapter` (`BackendVk.cpp:599`,
        /// `:625`). Dawn only skips an ICD once it has found something
        /// (`:599`-`:601`), so this stops the search after the first fallback
        /// adapter rather than collecting every one.
        force_fallback_adapter: bool = false,
    };

    /// `cacheIcd` calls `enumeratePhysicalDevices`, so the enumeration set
    /// crosses this boundary whole: `NoPhysicalDevice` means this ICD has
    /// nothing to offer and the search moves on, but `EnumerationCountUnstable`
    /// is a driver that will not settle and it is fatal for the search.
    pub const DiscoverError = std.mem.Allocator.Error || VulkanInstance.CreateError ||
        VulkanInstance.EnumerateError || PhysicalDevice.GatherError ||
        error{
            /// No ICD produced an adapter.
            NoPhysicalDevice,
        };

    pub fn init(gpa: std.mem.Allocator, options: InitOptions) Backend {
        return .{ .allocator = gpa, .handles = options.handles };
    }

    /// Ports `Backend::~Backend` (`BackendVk.cpp:574`), which is defaulted.
    /// The instances own the libraries, so they close last.
    ///
    /// It reports rather than returning `void`, because each instance teardown
    /// reaches a global proc and `AGENTS.md` §3.1 makes a null one a typed
    /// error. The loop does not stop at the first failure: an instance that
    /// cannot close must not strand the block behind it or the ICD after it,
    /// so each one is freed whatever it reported and the caller reads the first
    /// error the loop saw.
    pub fn deinit(self: *Backend) ProcError!void {
        for (self.physical_devices) |cached| {
            for (cached) |physical| self.allocator.free(physical.queue_families);
            self.allocator.free(cached);
        }
        // A second pass: an ICD whose instance loaded but which enumerated no
        // device leaves an empty physical-device list, so the loop above never
        // reached its instance and never closed it.
        // The first error is the caller's answer and a later one does not
        // displace it. It is read with `err` rather than caught, because the
        // loop has to reach its end whatever any one instance reports: the
        // block behind it and the ICD after it are this loop's to free.
        var first_failure: ?ProcError = null;
        for (self.instances) |maybe_instance| {
            if (maybe_instance) |instance| {
                const outcome = instance.deinit(self.allocator, self.handles);
                if (outcome) |_| {
                    // Nothing to record.
                } else |err| {
                    if (first_failure == null) first_failure = err;
                }
                self.allocator.destroy(instance);
            }
        }
        // The back end is gone and nothing reads the value again, so the
        // receiver is poisoned rather than half reset.
        self.* = undefined;
        if (first_failure) |err| return err;
    }

    /// Ports `Backend::DiscoverPhysicalDevices` (`BackendVk.cpp:576`-`:640`).
    ///
    /// The caller owns the returned list and frees it with `deinit`. The
    /// per-ICD physical devices are cached, so a second call re-filters instead
    /// of re-enumerating, which is the point Dawn's comment at
    /// `BackendVk.cpp:628`-`:629` makes.
    pub fn discoverPhysicalDevices(
        self: *Backend,
        options: DiscoverOptions,
    ) DiscoverError!AdapterList {
        var adapters: std.ArrayList(Adapter) = .empty;
        errdefer adapters.deinit(self.allocator);

        // `for (ICD icd : kICDs)` at `BackendVk.cpp:590`.
        for (icd_search_order) |icd| {
            try self.cacheIcd(icd);

            // `BackendVk.cpp:599`-`:601`.
            if (options.force_fallback_adapter and adapters.items.len != 0) continue;

            const icd_slot = icdIndex(icd);
            const cached = self.physical_devices[icd_slot];
            // `cacheIcd` returns with the slot null when the ICD did not load,
            // and Dawn warns once and moves on (`BackendVk.cpp:606`-`:615`), so
            // the loop must not unwrap it: on a host with no SwiftShader the
            // first entry is skipped and the `.system` ICD is never reached.
            const instance = self.instances[icd_slot] orelse continue;

            // `BackendVk.cpp:633`-`:637`. Dawn calls `SupportsFeatureLevel`
            // here, after the cache; the version floor is the same shape of
            // filter and `PhysicalDevice::supportsRequiredVersion` is its M9
            // form.
            for (cached) |physical| {
                if (!physical.supportsRequiredVersion()) continue;
                if (options.force_fallback_adapter and !physical.isFallback()) continue;
                try adapters.append(self.allocator, .{
                    .icd = icd,
                    .physical = physical,
                    .instance = instance,
                });
            }
        }

        if (adapters.items.len == 0) return error.NoPhysicalDevice;
        return .{
            .allocator = self.allocator,
            .items = try adapters.toOwnedSlice(self.allocator),
        };
    }

    /// Ports the caching half of `DiscoverPhysicalDevices`
    /// (`BackendVk.cpp:602`-`:632`): create this ICD's instance once, then cache
    /// what it reports.
    ///
    /// A library that will not open, or a loader below the floor, is not a
    /// failure of the search. Dawn warns once and moves to the next ICD
    /// (`BackendVk.cpp:606`-`:615`); the port skips it, because the caller
    /// asked for a device and the next ICD may have one.
    fn cacheIcd(self: *Backend, icd: Icd) DiscoverError!void {
        const icd_slot = icdIndex(icd);
        if (self.physical_devices[icd_slot].len != 0) return;

        if (self.instances[icd_slot] == null) {
            const instance = try self.allocator.create(VulkanInstance);
            errdefer self.allocator.destroy(instance);
            instance.* = VulkanInstance.create(self.allocator, .{
                .icd = icd,
                .handles = self.handles,
            }) catch |err| switch (err) {
                // A success return, so the `errdefer` above never fires. This
                // arm has to release the instance itself or every skipped ICD
                // leaks one.
                error.OpenFailed, error.VulkanVersionUnsupported => {
                    self.allocator.destroy(instance);
                    return;
                },
                else => |fatal| return fatal,
            };
            self.instances[icd_slot] = instance;
        }
        const instance = self.instances[icd_slot] orelse return;

        const discovered = instance.enumeratePhysicalDevices(self.allocator) catch |err|
            switch (err) {
                error.NoPhysicalDevice => return,
                else => |fatal| return fatal,
            };
        defer self.allocator.free(discovered);

        const cached = try self.allocator.alloc(PhysicalDevice, discovered.len);
        errdefer self.allocator.free(cached);
        var index: usize = 0;
        errdefer {
            for (cached[0..index]) |physical| self.allocator.free(physical.queue_families);
        }
        while (index < discovered.len) : (index += 1) {
            cached[index] = try PhysicalDevice.gather(
                self.allocator,
                instance.procs,
                discovered[index],
            );
        }
        self.physical_devices[icd_slot] = cached;
    }
};

comptime {
    assertErrorSetNamed(VulkanInstance.CreateError, &.{
        error.OutOfMemory,
        error.LibraryAlreadyOpen,
        error.OpenFailed,
        error.MissingGlobalProc,
        error.MissingInstanceProc,
        error.MissingDeviceProc,
        error.VulkanVersionUnsupported,
        error.InstanceCreationReturnedNull,
    });
    assertErrorSetNamed(VulkanInstance.EnumerateError, &.{
        error.OutOfMemory,
        error.EnumerationCountUnstable,
        error.NoPhysicalDevice,
    });
    assertErrorSetNamed(PhysicalDevice.GatherError, &.{
        error.OutOfMemory,
        error.QueueFamilyCountUnstable,
    });
    assertErrorSetNamed(Device.CreateError, &.{
        error.OutOfMemory,
        error.MissingGlobalProc,
        error.MissingInstanceProc,
        error.MissingDeviceProc,
        error.NoUniversalQueueFamily,
        error.DeviceCreationReturnedNull,
    });
    assertErrorSetNamed(Backend.DiscoverError, &.{
        error.OutOfMemory,
        error.LibraryAlreadyOpen,
        error.OpenFailed,
        error.MissingGlobalProc,
        error.MissingInstanceProc,
        error.MissingDeviceProc,
        error.QueueFamilyCountUnstable,
        error.EnumerationCountUnstable,
        error.VulkanVersionUnsupported,
        error.InstanceCreationReturnedNull,
        error.NoPhysicalDevice,
    });
    assertErrorSetNamed(MemoryTypeError, &.{error.NoMemoryType});

    // `icd_search_order` is the fallback-first rule, and the fallback is first.
    {
        if (icd_search_order[0] != .swiftshader) {
            @compileError("the fallback ICD must be searched first");
        }
    }
}

test "the memory-type rule refuses a device-local type and accepts a linear one" {
    // A two-type table: index 0 is device-local, index 1 is host-visible.
    var properties: vulkan.VkPhysicalDeviceMemoryProperties =
        std.mem.zeroes(vulkan.VkPhysicalDeviceMemoryProperties);
    properties.memoryTypeCount = 2;
    properties.memoryTypes[0].propertyFlags = vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    properties.memoryTypes[1].propertyFlags =
        vulkan.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vulkan.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

    // Only type 1 is host-visible, so a fill that must not be a no-op picks it.
    try std.testing.expectEqual(
        @as(u32, 1),
        try findMemoryTypeIndex(
            &properties,
            0b11,
            vulkan.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
            vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        ),
    );

    // The same request with device-local forbidden picks nothing, because type 0
    // is device-local and type 1 is out of the allocation's type bits.
    try std.testing.expectError(
        error.NoMemoryType,
        findMemoryTypeIndex(&properties, 0b01, 0, vulkan.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
    );

    // An allocation whose type bits name nothing legal is refused, not zero.
    try std.testing.expectError(
        error.NoMemoryType,
        findMemoryTypeIndex(&properties, 0, 0, 0),
    );
}

test "the live-handle set counts one kind and comes back empty" {
    var set: HandleSet = .{};

    try std.testing.expect(set.isEmpty());
    try std.testing.expectEqual(@as(u32, 0), set.totalCount());

    set.acquire(.buffer);
    set.acquire(.buffer);
    set.acquire(.fence);
    try std.testing.expectEqual(@as(u32, 2), set.countOf(.buffer));
    try std.testing.expectEqual(@as(u32, 1), set.countOf(.fence));
    try std.testing.expectEqual(@as(u32, 3), set.totalCount());
    try std.testing.expectEqual(HandleKind.buffer, set.firstLeakedKind().?);

    set.release(.buffer);
    set.release(.buffer);
    set.release(.fence);
    try std.testing.expect(set.isEmpty());
    try std.testing.expectEqual(@as(?HandleKind, null), set.firstLeakedKind());
}

test "the ICD order is the fallback first and each name is a library" {
    try std.testing.expectEqual(@as(usize, 2), icd_search_order.len);
    try std.testing.expectEqual(Icd.swiftshader, icd_search_order[0]);
    try std.testing.expectEqual(Icd.system, icd_search_order[1]);

    try std.testing.expectEqualStrings("libvk_swiftshader.so", icdLibraryName(.swiftshader));
    try std.testing.expectEqualStrings("libvulkan.so.1", icdLibraryName(.system));

    // Every ICD owns exactly one slot, so the per-ICD tables cannot overlap.
    try std.testing.expectEqual(@as(usize, 0), icdIndex(.swiftshader));
    try std.testing.expectEqual(@as(usize, 1), icdIndex(.system));
    try std.testing.expectEqual(icd_count, @typeInfo(Icd).@"enum".fields.len);
}

test "the floor is Vulkan 1.1" {
    try std.testing.expectEqual(vulkan.VK_API_VERSION_1_1, required_vulkan_version);
}

test "the render extension is the one the bindings spell" {
    // A wrong name fails silently at every other layer: the driver is only
    // ever asked whether it advertises the name this file holds, so a typo
    // makes the answer "no", the device is created without the extension,
    // and the first evidence is a failed `vkCreateGraphicsPipelines`.
    try std.testing.expectEqualStrings(
        vulkan.VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
        required_device_ext.vkName(),
    );
}
