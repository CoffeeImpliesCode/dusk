//! The instance: the object that owns the back ends and answers "which adapters
//! exist".
//!
//! Ports `src/dawn/native/Instance.{h,cpp}`.
//!
//! This module does not implement surfaces or WGSL language features.
//! Root request execution and event delivery belong to `async_root_requests.zig`.

const std = @import("std");
const adapter_mod = @import("adapter.zig");
const api = @import("../api/api.zig");
const null_backend = @import("null_backend.zig");
const physical_device = @import("physical_device.zig");
const native = @import("vulkan_device.zig");
const NativeInstanceContext = @import("native_instance_context.zig").NativeInstanceContext;
const native_capabilities = @import("native_capabilities.zig");
const root = @import("async_root_requests.zig");
const async_registry = @import("async_registry.zig");
const device_mod = @import("device.zig");
const platform = @import("../platform/threads.zig");

pub const Adapter = adapter_mod.Adapter;
pub const AdapterType = api.AdapterType;
pub const BackendType = api.BackendType;
pub const PowerPreference = api.PowerPreference;

/// The bound on one enumeration. Dawn returns a vector and cannot run away
/// (`Instance.cpp:539-578`); the port builds a list, so the bound is named and
/// exhaustion is its own error.
pub const max_physical_device_count = 64;

/// What `connect` can refuse.
pub const ConnectError = error{
    /// `Instance.cpp:468-537` connects one back end per `BackendType` and
    /// returns null for a back end this build does not have. The port reports
    /// the difference instead of dropping the request.
    BackendNotCompiledIn,
};

/// Everything `enumerateAdapters` can refuse.
///
/// `Adapter.init` (`Adapter.cpp:54-72`) raises `FeatureLevelUnsupported` for a
/// level the physical device does not serve, and `Adapter.createDevice` raises
/// the other three. `enumerateAdapters` calls the constructor, so the whole
/// adapter set crosses this boundary and the set is the union rather than the
/// one member the constructor itself raises.
pub const Error = native.Backend.DiscoverError || ConnectError || adapter_mod.Error ||
    root.RootWorkError || error{
    /// A back end reported more physical devices than `max_physical_device_count`.
    TooManyPhysicalDevices,
};

/// The set of instance features the caller required. Dawn keeps a `FeaturesSet`
/// (`Instance.h:238`) and one member of it is read by the adapter path.
pub const InstanceFeatureSet = struct {
    bits: std.EnumSet(api.InstanceFeatureName) = .{},

    pub fn enable(self: *InstanceFeatureSet, name: api.InstanceFeatureName) void {
        self.bits.insert(name);
    }

    pub fn isEnabled(self: InstanceFeatureSet, name: api.InstanceFeatureName) bool {
        return self.bits.contains(name);
    }
};

/// Owned adapter and physical storage. Copies are not independent owners.
/// Instance must remain at its final address until this list is released.
/// Adapter pointers remain valid until successful `deinit`; do not move/copy
/// an adapter after creating a device that borrows it.
pub const AdapterList = struct {
    items: []Adapter,
    physical_devices: []physical_device.PhysicalDevice,
    allocator: std.mem.Allocator,
    instance: *Instance,

    pub const DeinitError = error{AdapterListInUse};

    /// Refuses device and request borrows unchanged. Success invalidates all list pointers.
    pub fn deinit(self: *AdapterList, io: std.Io) DeinitError!void {
        const instance = self.instance;
        instance.lifecycle_mutex.lockUncancelable(io);
        defer instance.lifecycle_mutex.unlock(io);
        for (self.items) |item| {
            if (item.active_root_requests != 0) return error.AdapterListInUse;
            if (item.live_device_count != 0) return error.AdapterListInUse;
        }
        for (self.physical_devices) |physical| {
            if (physical.live_device_count != 0) return error.AdapterListInUse;
        }
        self.allocator.free(self.items);
        self.allocator.free(self.physical_devices);
        instance.releaseListLocked();
        self.* = undefined;
    }
};

/// Raw physical enumeration owns a counted Instance lease, including empty lists.
/// Release once; copying the wrapper does not create another lease.
pub const PhysicalDeviceList = struct {
    items: []physical_device.PhysicalDevice,
    allocator: std.mem.Allocator,
    instance: *Instance,

    pub const DeinitError = error{PhysicalDeviceListInUse};

    /// Refuses live devices unchanged; success invalidates all physical pointers.
    pub fn deinit(self: *PhysicalDeviceList, io: std.Io) DeinitError!void {
        const instance = self.instance;
        instance.lifecycle_mutex.lockUncancelable(io);
        defer instance.lifecycle_mutex.unlock(io);
        for (self.items) |item| {
            if (item.live_device_count != 0) return error.PhysicalDeviceListInUse;
        }
        self.allocator.free(self.items);
        instance.releaseListLocked();
        self.* = undefined;
    }
};

/// One handle onto the back ends.
///
/// Dawn's InstanceBase outlives its adapters (`Instance.cpp:265-271`). This
/// owner must stay at its final address after discovery. Lists and devices
/// retain counted borrows; copying Instance does not create an independent owner.
pub const Instance = struct {
    backend_type: BackendType = .vulkan,
    enabled_instance_features: InstanceFeatureSet = .{},
    /// `mDevicesList` (`Instance.h:252`). Dawn keeps the list so a device can be
    /// refused while the instance is being torn down; the port keeps the count
    /// so `Device.deinit` can answer honestly.
    device_count: u64 = 0,
    list_count: u64 = 0,
    /// Heap owner allocated lazily. Its allocator is retained by the backend.
    native_context: ?*NativeInstanceContext = null,
    /// Metadata gates never span native work, worker joins, or callback delivery.
    lifecycle_mutex: std.Io.Mutex = .init,
    root_work_mutex: std.Io.Mutex = .init,
    root_state: enum { open, closing, closed } = .open,
    active_operations: usize = 0,
    accepted_root_operations: usize = 0,
    active_callbacks: u32 = 0,
    future_namespace_source: ?*async_registry.FutureNamespaceSource = null,
    async_options: async_registry.Options = .{},
    root_worker_count: usize = platform.WorkerPool.default_worker_count,
    completions: ?*async_registry.CompletionRegistry = null,
    root_executor: ?*root.RootExecutor = null,
    root_record: root.RootRecord = .{ .kind = .instance },
    root_disposals: ?*root.OwnedDevice = null,
    root_disposal_count: u32 = 0,
    root_disposal_slots: u32 = 0,
    /// The lifecycle gate reserves one explicit disposal collection at a time.
    root_disposal_collecting: bool = false,
    root_disposal_error: ?device_mod.CleanupError = null,

    pub const InitOptions = struct {
        /// Vulkan is the production default. Null must be selected explicitly.
        backend_type: BackendType = .vulkan,
        required_features: []const api.InstanceFeatureName = &.{},
        /// Caller-owned authority remains stable through final registry close.
        /// Null preserves synchronous-only use without allocation.
        future_namespace_source: ?*async_registry.FutureNamespaceSource = null,
        async_options: async_registry.Options = .{},
        root_worker_count: usize = platform.WorkerPool.default_worker_count,
    };

    /// Creates allocation-free synchronous state. Async setup remains lazy.
    /// Move the value to its final address before discovery or root export.
    pub fn init(options: InitOptions) Instance {
        var created: Instance = .{
            .backend_type = options.backend_type,
            .future_namespace_source = options.future_namespace_source,
            .async_options = options.async_options,
            .root_worker_count = options.root_worker_count,
        };
        // `Instance.cpp:644-647`. `multiple_devices_per_adapter` is the one
        // instance feature the adapter creation path reads
        // (`Adapter.cpp:314-316`).
        // Bound: the slice the caller passed.
        for (options.required_features) |name| {
            created.enabled_instance_features.enable(name);
        }
        std.debug.assert(created.hasFeature(.multiple_devices_per_adapter) ==
            contains(options.required_features, .multiple_devices_per_adapter));
        return created;
    }

    /// `InstanceBase::HasFeature` (`Instance.cpp:644-647`).
    pub fn hasFeature(self: *const Instance, name: api.InstanceFeatureName) bool {
        return self.enabled_instance_features.isEnabled(name);
    }

    /// `InstanceBase::EnumerateAdapters` (`Instance.cpp:433-467`).
    ///
    /// The order is Dawn's: discover the physical devices, build one adapter per
    /// device, then `SortAdapters`. Calling it twice gives two independent
    /// lists, which is how one instance yields a core adapter and a
    /// compatibility adapter at the same time.
    pub fn enumerateAdapters(
        self: *Instance,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: api.RequestAdapterOptions,
    ) Error!AdapterList {
        try self.acquireRootOperation(io);
        defer self.releaseRootOperation(io);
        try self.root_work_mutex.lock(io);
        defer self.root_work_mutex.unlock(io);
        return self.enumerateAdaptersSerialized(allocator, io, options);
    }

    /// Caller holds a root pin and `root_work_mutex`. Does not acquire that mutex again.
    pub fn enumerateAdaptersSerialized(
        self: *Instance,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: api.RequestAdapterOptions,
    ) Error!AdapterList {
        var devices = try self.enumeratePhysicalDevicesSerialized(allocator, io, options);
        // The list is unpublished until return; Adapter.init creates no device children.
        errdefer devices.deinit(io) catch |err| {
            std.debug.panic(
                "adapter enumeration rollback failed for an unpublished physical list with no device children: {s}",
                .{@errorName(err)},
            );
        };
        const built = try allocator.alloc(Adapter, devices.items.len);
        errdefer allocator.free(built);
        for (built, devices.items) |*slot, *device| {
            slot.* = try Adapter.init(self, device, .{
                .feature_level = options.feature_level,
                .power_preference = options.power_preference,
            });
        }
        sortAdapters(built, options.power_preference);
        return .{
            .items = built,
            .physical_devices = devices.items,
            .allocator = allocator,
            .instance = self,
        };
    }

    /// Owned physical rows; release with `PhysicalDeviceList.deinit`.
    /// Native names borrow final row storage, never temporary discovery values.
    pub fn enumeratePhysicalDevices(
        self: *Instance,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: api.RequestAdapterOptions,
    ) Error!PhysicalDeviceList {
        try self.acquireRootOperation(io);
        defer self.releaseRootOperation(io);
        try self.root_work_mutex.lock(io);
        defer self.root_work_mutex.unlock(io);
        return self.enumeratePhysicalDevicesSerialized(allocator, io, options);
    }

    fn enumeratePhysicalDevicesSerialized(
        self: *Instance,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: api.RequestAdapterOptions,
    ) Error!PhysicalDeviceList {
        self.lifecycle_mutex.lockUncancelable(io);
        const count_available = self.list_count < std.math.maxInt(u64);
        self.lifecycle_mutex.unlock(io);
        if (!count_available) return error.ReferenceCountOverflow;
        const rows = switch (backendOf(options, self.backend_type)) {
            .null_ => blk: {
                var found = try null_backend.discoverPhysicalDevices(allocator, options);
                errdefer found.deinit(allocator);
                if (found.items.len > max_physical_device_count) {
                    return error.TooManyPhysicalDevices;
                }
                break :blk try found.toOwnedSlice(allocator);
            },
            .vulkan => try self.discoverNative(allocator, io, options),
            else => return error.BackendNotCompiledIn,
        };
        self.lifecycle_mutex.lockUncancelable(io);
        std.debug.assert(self.list_count < std.math.maxInt(u64));
        self.list_count += 1;
        self.lifecycle_mutex.unlock(io);
        return .{ .items = rows, .allocator = allocator, .instance = self };
    }

    fn discoverNative(
        self: *Instance,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: api.RequestAdapterOptions,
    ) Error![]physical_device.PhysicalDevice {
        if (self.native_context == null) {
            const context = try allocator.create(NativeInstanceContext);
            context.init(allocator);
            self.lifecycle_mutex.lockUncancelable(io);
            self.native_context = context;
            self.lifecycle_mutex.unlock(io);
        }
        var found = try self.native_context.?.backend.discoverPhysicalDevices(.{
            .force_fallback_adapter = options.force_fallback_adapter,
        });
        defer found.deinit();
        if (found.items.len > max_physical_device_count) return error.TooManyPhysicalDevices;
        var count: usize = 0;
        for (found.items) |*item| {
            const mapped = native_capabilities.fromNative(&item.physical);
            if (mapped.supportsFeatureLevel(options.feature_level)) count += 1;
        }
        const rows = try allocator.alloc(physical_device.PhysicalDevice, count);
        var index: usize = 0;
        for (found.items) |item| {
            const mapped = native_capabilities.fromNative(&item.physical);
            if (!mapped.supportsFeatureLevel(options.feature_level)) continue;
            rows[index] = mapped;
            rows[index].native_adapter = item;
            rows[index].name = rows[index].native_adapter.?.physical.deviceName();
            index += 1;
        }
        return rows;
    }

    pub const DeinitError = native.ProcError || error{InstanceInUse};

    /// Refuses live children unchanged. Native cleanup errors still consume the
    /// context; cleanup must not be retried through an already released backend.
    pub fn deinit(
        self: *Instance,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) DeinitError!void {
        return root.close(self, allocator, io);
    }

    /// Number of physical/adapter lists retaining this instance.
    pub fn queryAdapterListCount(self: *Instance, io: std.Io) u64 {
        self.lifecycle_mutex.lockUncancelable(io);
        defer self.lifecycle_mutex.unlock(io);
        return self.list_count;
    }

    fn releaseListLocked(self: *Instance) void {
        std.debug.assert(self.list_count > 0);
        self.list_count -= 1;
    }

    /// Checked ordinary pin. Closing and closed instances reject new work.
    pub fn acquireRootOperation(self: *Instance, io: std.Io) root.RootWorkError!void {
        try self.lifecycle_mutex.lock(io);
        defer self.lifecycle_mutex.unlock(io);
        if (self.root_state != .open) return error.InstanceShutDown;
        if (self.active_operations == std.math.maxInt(usize)) {
            return error.ReferenceCountOverflow;
        }
        self.active_operations += 1;
        std.debug.assert(self.active_operations > self.accepted_root_operations);
    }

    /// Releases one ordinary pin without a cancellation point.
    pub fn releaseRootOperation(self: *Instance, io: std.Io) void {
        self.lifecycle_mutex.lockUncancelable(io);
        defer self.lifecycle_mutex.unlock(io);
        std.debug.assert(self.active_operations > self.accepted_root_operations);
        self.active_operations -= 1;
        std.debug.assert(self.accepted_root_operations <= self.active_operations);
    }

    /// Caller holds lifecycle. Promote already held ordinary pins after admission.
    pub fn promoteRootOperationsLocked(
        self: *Instance,
        count: usize,
    ) root.RootWorkError!void {
        std.debug.assert(self.accepted_root_operations <= self.active_operations);
        std.debug.assert(count <= self.active_operations - self.accepted_root_operations);
        if (count > std.math.maxInt(usize) - self.accepted_root_operations) {
            return error.ReferenceCountOverflow;
        }
        self.accepted_root_operations += count;
        std.debug.assert(self.accepted_root_operations <= self.active_operations);
    }

    /// Releases an accepted pin from both the subset and the ordinary authority.
    pub fn releaseAcceptedRootOperation(self: *Instance, io: std.Io) void {
        self.lifecycle_mutex.lockUncancelable(io);
        defer self.lifecycle_mutex.unlock(io);
        std.debug.assert(self.accepted_root_operations > 0);
        std.debug.assert(self.active_operations >= self.accepted_root_operations);
        self.accepted_root_operations -= 1;
        self.active_operations -= 1;
    }

    /// One serialized creation transaction. Copies are not additional owners.
    /// Deinit releases pins and serialization, even after commit.
    pub const DeviceCreationPermit = struct {
        instance: *Instance,
        adapter: *Adapter,
        consume_on_success: bool,
        active: bool = true,
        committed: bool = false,

        /// Called once after high construction succeeds. Allocates nothing.
        pub fn commit(self: *DeviceCreationPermit, io: std.Io) void {
            std.debug.assert(self.active);
            std.debug.assert(!self.committed);
            self.instance.lifecycle_mutex.lockUncancelable(io);
            defer self.instance.lifecycle_mutex.unlock(io);
            std.debug.assert(self.adapter.instance == self.instance);
            std.debug.assert(!self.adapter.is_consumed);
            std.debug.assert(self.instance.device_count < std.math.maxInt(u64));
            std.debug.assert(self.adapter.live_device_count < std.math.maxInt(u64));
            std.debug.assert(self.adapter.physical_device.live_device_count < std.math.maxInt(u64));
            self.instance.device_count += 1;
            self.adapter.live_device_count += 1;
            self.adapter.physical_device.live_device_count += 1;
            if (self.consume_on_success) self.adapter.is_consumed = true;
            self.committed = true;
            std.debug.assert(self.instance.device_count > 0);
            std.debug.assert(self.adapter.live_device_count > 0);
            std.debug.assert(self.adapter.physical_device.live_device_count > 0);
            if (self.consume_on_success) std.debug.assert(self.adapter.is_consumed);
        }

        /// Releases this transaction once without changing successful parent counts.
        pub fn deinit(self: *DeviceCreationPermit, io: std.Io) void {
            std.debug.assert(self.active);
            self.instance.root_work_mutex.unlock(io);
            self.instance.releaseCreationPins(io, self.adapter);
            self.active = false;
            std.debug.assert(!self.active);
        }
    };

    /// Pins metadata before waiting for work. Failure leaves the latch and counts unchanged.
    /// Null consume policy inherits the immutable Instance feature policy.
    pub fn beginDeviceCreation(
        self: *Instance,
        io: std.Io,
        adapter: *Adapter,
        consume_adapter: ?bool,
    ) (root.RootWorkError || error{AdapterConsumed})!DeviceCreationPermit {
        {
            try self.lifecycle_mutex.lock(io);
            defer self.lifecycle_mutex.unlock(io);
            std.debug.assert(adapter.instance == self);
            if (self.root_state != .open) return error.InstanceShutDown;
            if (self.active_operations == std.math.maxInt(usize)) {
                return error.ReferenceCountOverflow;
            }
            if (adapter.active_root_requests == std.math.maxInt(usize)) {
                return error.ReferenceCountOverflow;
            }
            self.active_operations += 1;
            adapter.active_root_requests += 1;
        }
        errdefer self.releaseCreationPins(io, adapter);
        try self.root_work_mutex.lock(io);
        errdefer self.root_work_mutex.unlock(io);
        self.lifecycle_mutex.lockUncancelable(io);
        defer self.lifecycle_mutex.unlock(io);
        if (self.root_state != .open) return error.InstanceShutDown;
        if (adapter.is_consumed) return error.AdapterConsumed;
        if (self.device_count == std.math.maxInt(u64) or
            adapter.live_device_count == std.math.maxInt(u64) or
            adapter.physical_device.live_device_count == std.math.maxInt(u64))
        {
            return error.ReferenceCountOverflow;
        }
        return .{
            .instance = self,
            .adapter = adapter,
            .consume_on_success = consume_adapter orelse
                !self.hasFeature(.multiple_devices_per_adapter),
        };
    }

    fn releaseCreationPins(self: *Instance, io: std.Io, adapter: *Adapter) void {
        self.lifecycle_mutex.lockUncancelable(io);
        defer self.lifecycle_mutex.unlock(io);
        std.debug.assert(self.active_operations > self.accepted_root_operations);
        std.debug.assert(adapter.active_root_requests > 0);
        adapter.active_root_requests -= 1;
        self.active_operations -= 1;
    }

    /// Sole successful-device parent release, after high host teardown commits.
    pub fn releaseDeviceParents(self: *Instance, io: std.Io, adapter: *Adapter) void {
        self.lifecycle_mutex.lockUncancelable(io);
        defer self.lifecycle_mutex.unlock(io);
        std.debug.assert(adapter.instance == self);
        std.debug.assert(self.device_count > 0);
        std.debug.assert(adapter.live_device_count > 0);
        std.debug.assert(adapter.physical_device.live_device_count > 0);
        self.device_count -= 1;
        adapter.live_device_count -= 1;
        adapter.physical_device.live_device_count -= 1;
    }

    /// Snapshot of the actual successful high device parent count.
    pub fn queryDeviceCount(self: *Instance, io: std.Io) u64 {
        self.lifecycle_mutex.lockUncancelable(io);
        defer self.lifecycle_mutex.unlock(io);
        return self.device_count;
    }

    /// Lazily creates registry authority with this allocator and explicit Io.
    pub fn ensureRootAsync(
        self: *Instance,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) api.AsyncStartError!*async_registry.CompletionRegistry {
        return root.ensureRootAsync(self, allocator, io);
    }

    /// Native observation of the same owned selection used by generated requests.
    /// Consume a successful result once. Cancellation abandons only observation.
    pub fn requestAdapterAsync(
        self: *Instance,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: ?*const api.descriptors.RequestAdapterOptionsChain,
    ) api.AsyncStartError!std.Io.Future(root.RootOutcome(*root.OwnedAdapterSelection)) {
        return root.requestAdapterAsync(self, allocator, io, options);
    }
};

/// `Instance.cpp:562`-`:564` clears `webgpu` from the default set and leaves the
/// rest, so an unset `backend_type` means "every back end this build has", which
/// at M8 is the one the instance was built with.
fn backendOf(options: api.RequestAdapterOptions, fallback: BackendType) BackendType {
    return switch (options.backend_type) {
        .undefined_ => fallback,
        else => |named| named,
    };
}

/// The key `sortAdapters` orders by: the pair `(adapter type rank, backend type
/// rank)`. An undefined power preference leaves both GPU ranks equal, which is
/// what preserves the back end's own order (`Adapter.cpp:465-468`).
const SortOrder = struct {
    discrete_rank: u8,
    integrated_rank: u8,

    fn adapterTypeRank(self: SortOrder, one: Adapter) u8 {
        return switch (one.getPhysicalDevice().getAdapterType()) {
            .discrete_gpu => self.discrete_rank,
            .integrated_gpu => self.integrated_rank,
            .cpu => 2,
            .unknown => 3,
        };
    }

    fn backendTypeRank(one: Adapter) u8 {
        return switch (one.getPhysicalDevice().getBackendType()) {
            .metal, .d3d12 => 0,
            .vulkan => 1,
            .d3d11 => 2,
            .opengles => 3,
            .opengl => 4,
            .webgpu => 5,
            .null_ => 6,
            // `Adapter.cpp:504-506` breaks out of the switch and then calls
            // `DAWN_UNREACHABLE`, so an undefined backend has no rank. The port
            // cannot reach it: `connect` refuses that name.
            .undefined_ => unreachable,
        };
    }

    fn lessThan(self: SortOrder, left: Adapter, right: Adapter) bool {
        const left_type = self.adapterTypeRank(left);
        const right_type = self.adapterTypeRank(right);
        if (left_type != right_type) return left_type < right_type;
        return backendTypeRank(left) < backendTypeRank(right);
    }
};

/// `SortAdapters` (`Adapter.cpp:452-517`). The sort is stable, so adapters that
/// compare equal keep the order the back end produced.
pub fn sortAdapters(adapters: []Adapter, power_preference: PowerPreference) void {
    const order: SortOrder = switch (power_preference) {
        .high_performance => .{ .discrete_rank = 0, .integrated_rank = 1 },
        .low_power => .{ .discrete_rank = 1, .integrated_rank = 0 },
        .undefined_ => .{ .discrete_rank = 1, .integrated_rank = 1 },
    };
    std.sort.insertion(Adapter, adapters, order, SortOrder.lessThan);
}

fn contains(names: []const api.InstanceFeatureName, wanted: api.InstanceFeatureName) bool {
    // Bound: the slice the caller passed.
    for (names) |name| {
        if (name == wanted) return true;
    }
    return false;
}

test "empty adapter lists retain instance ownership" {
    var instance = Instance.init(.{ .backend_type = .null_ });
    var list = try instance.enumerateAdapters(std.testing.allocator, std.testing.io, .{
        .power_preference = .undefined_,
        .backend_type = .null_,
        .force_fallback_adapter = true,
    });
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqual(@as(u64, 1), instance.queryAdapterListCount(std.testing.io));
    try std.testing.expectError(
        error.InstanceInUse,
        instance.deinit(std.testing.allocator, std.testing.io),
    );
    try list.deinit(std.testing.io);
    try instance.deinit(std.testing.allocator, std.testing.io);
}

test "raw physical lists retain instance ownership" {
    var instance = Instance.init(.{ .backend_type = .null_ });
    var list = try instance.enumeratePhysicalDevices(std.testing.allocator, std.testing.io, .{
        .power_preference = .undefined_,
        .backend_type = .null_,
    });
    try std.testing.expectEqual(@as(u64, 1), instance.queryAdapterListCount(std.testing.io));
    try std.testing.expectError(
        error.InstanceInUse,
        instance.deinit(std.testing.allocator, std.testing.io),
    );
    try list.deinit(std.testing.io);
    try instance.deinit(std.testing.allocator, std.testing.io);
}

test "null discovery allocation failures release every list lease" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        nullDiscoveryAllocationFailure,
        .{},
    );
}

fn nullDiscoveryAllocationFailure(allocator: std.mem.Allocator) !void {
    var instance = Instance.init(.{ .backend_type = .null_ });
    defer instance.deinit(allocator, std.testing.io) catch |err| {
        std.debug.panic(
            "null discovery test instance cleanup failed after list cleanup with no device children: {s}",
            .{@errorName(err)},
        );
    };
    var list = try instance.enumerateAdapters(allocator, std.testing.io, .{
        .power_preference = .undefined_,
        .backend_type = .null_,
    });
    defer list.deinit(std.testing.io) catch |err| {
        std.debug.panic(
            "null discovery test adapter list cleanup failed with no device children: {s}",
            .{@errorName(err)},
        );
    };
    try std.testing.expectEqual(@as(u64, 1), instance.queryAdapterListCount(std.testing.io));
}

test "creation permit retains adapter until release and commits parents once" {
    var instance = Instance.init(.{ .backend_type = .null_ });
    var list = try instance.enumerateAdapters(std.testing.allocator, std.testing.io, .{
        .power_preference = .undefined_,
        .backend_type = .null_,
    });
    var permit = try instance.beginDeviceCreation(std.testing.io, &list.items[0], true);
    try std.testing.expectError(error.AdapterListInUse, list.deinit(std.testing.io));
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(std.testing.io));
    permit.commit(std.testing.io);
    try std.testing.expectEqual(@as(u64, 1), instance.queryDeviceCount(std.testing.io));
    try std.testing.expectEqual(@as(u64, 1), list.items[0].live_device_count);
    try std.testing.expectEqual(@as(u64, 1), list.physical_devices[0].live_device_count);
    permit.deinit(std.testing.io);
    instance.releaseDeviceParents(std.testing.io, &list.items[0]);
    try std.testing.expectError(
        error.AdapterConsumed,
        instance.beginDeviceCreation(std.testing.io, &list.items[0], false),
    );
    try std.testing.expectEqual(@as(usize, 0), list.items[0].active_root_requests);
    try list.deinit(std.testing.io);
    try instance.deinit(std.testing.allocator, std.testing.io);
}

test "failed creation transaction does not consume adapter or retain pins" {
    var instance = Instance.init(.{ .backend_type = .null_ });
    var list = try instance.enumerateAdapters(std.testing.allocator, std.testing.io, .{
        .power_preference = .undefined_,
        .backend_type = .null_,
    });
    var permit = try instance.beginDeviceCreation(std.testing.io, &list.items[0], true);
    permit.deinit(std.testing.io);
    try std.testing.expect(!list.items[0].is_consumed);
    try std.testing.expectEqual(@as(usize, 0), instance.active_operations);
    try std.testing.expectEqual(@as(usize, 0), list.items[0].active_root_requests);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(std.testing.io));
    try list.deinit(std.testing.io);
    try instance.deinit(std.testing.allocator, std.testing.io);
}

test "root pins preserve the accepted subset without a second parent ledger" {
    var instance = Instance.init(.{ .backend_type = .null_ });
    try instance.acquireRootOperation(std.testing.io);
    try instance.acquireRootOperation(std.testing.io);
    instance.lifecycle_mutex.lockUncancelable(std.testing.io);
    const promoted = instance.promoteRootOperationsLocked(1);
    instance.lifecycle_mutex.unlock(std.testing.io);
    try promoted;
    try std.testing.expectEqual(@as(usize, 2), instance.active_operations);
    try std.testing.expectEqual(@as(usize, 1), instance.accepted_root_operations);
    instance.releaseRootOperation(std.testing.io);
    instance.releaseAcceptedRootOperation(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), instance.active_operations);
    try std.testing.expectEqual(@as(usize, 0), instance.accepted_root_operations);
    try std.testing.expectEqual(@as(u64, 0), instance.queryDeviceCount(std.testing.io));
    try instance.deinit(std.testing.allocator, std.testing.io);
    try std.testing.expectError(
        error.InstanceShutDown,
        instance.acquireRootOperation(std.testing.io),
    );
}

test "creation preflights every authoritative parent count before commit" {
    var instance = Instance.init(.{ .backend_type = .null_ });
    var list = try instance.enumerateAdapters(std.testing.allocator, std.testing.io, .{
        .power_preference = .undefined_,
        .backend_type = .null_,
    });
    const counters = [_]*u64{
        &instance.device_count,
        &list.items[0].live_device_count,
        &list.physical_devices[0].live_device_count,
    };
    for (counters) |counter| {
        instance.lifecycle_mutex.lockUncancelable(std.testing.io);
        counter.* = std.math.maxInt(u64);
        instance.lifecycle_mutex.unlock(std.testing.io);
        try std.testing.expectError(
            error.ReferenceCountOverflow,
            instance.beginDeviceCreation(std.testing.io, &list.items[0], true),
        );
        try std.testing.expect(!list.items[0].is_consumed);
        try std.testing.expectEqual(@as(usize, 0), list.items[0].active_root_requests);
        try std.testing.expectEqual(@as(usize, 0), instance.active_operations);
        instance.lifecycle_mutex.lockUncancelable(std.testing.io);
        counter.* = 0;
        instance.lifecycle_mutex.unlock(std.testing.io);
    }
    try list.deinit(std.testing.io);
    try instance.deinit(std.testing.allocator, std.testing.io);
}

test "explicit false consume policy keeps the latch open across successful creation" {
    var instance = Instance.init(.{ .backend_type = .null_ });
    var list = try instance.enumerateAdapters(std.testing.allocator, std.testing.io, .{
        .power_preference = .undefined_,
        .backend_type = .null_,
    });
    var first = try instance.beginDeviceCreation(std.testing.io, &list.items[0], false);
    first.commit(std.testing.io);
    first.deinit(std.testing.io);
    try std.testing.expect(!list.items[0].is_consumed);
    var second = try instance.beginDeviceCreation(std.testing.io, &list.items[0], null);
    second.commit(std.testing.io);
    second.deinit(std.testing.io);
    try std.testing.expect(list.items[0].is_consumed);
    try std.testing.expectEqual(@as(u64, 2), instance.queryDeviceCount(std.testing.io));
    instance.releaseDeviceParents(std.testing.io, &list.items[0]);
    instance.releaseDeviceParents(std.testing.io, &list.items[0]);
    try list.deinit(std.testing.io);
    try instance.deinit(std.testing.allocator, std.testing.io);
}
