//! The instance: the object that owns the back ends and answers "which adapters
//! exist".
//!
//! Ports `src/dawn/native/Instance.{h,cpp}`. `docs/40-plan.md` §3.3 `#### M8`
//! holds the row table.
//!
//! **What this file does not claim.** It does not claim WGSL language features,
//! X11 functions, surfaces, an event manager or a process-event loop. Each of
//! those rows in the table names the milestone that owns it.

const std = @import("std");
const adapter_mod = @import("adapter.zig");
const api = @import("../api/api.zig");
const null_backend = @import("null_backend.zig");
const physical_device = @import("physical_device.zig");

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
pub const Error = std.mem.Allocator.Error || ConnectError || adapter_mod.Error || error{
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

/// Where a back end is reached from. Upstream has one `BackendConnection`
/// subclass per back end and an `ityp_bitset` of live connections
/// (`Instance.h:230`-`:231`, `Instance.cpp:468-537`).
/// `docs/30-port-design.md` §10.3 refuses the virtual layer, so the port has
/// one module per back end and this switch.
fn connect(backend: BackendType) ConnectError!BackendConnection {
    return switch (backend) {
        .null_ => .{ .null_ = {} },
        // `Instance.cpp:483`-`:485` connects the null back end. Every other name
        // is a back end this build does not have, which is what `dusk` means by
        // "Vulkan as its only back end" before M9 lands.
        else => error.BackendNotCompiledIn,
    };
}

/// The one back end a connection can be. It is a union and not a class because
/// upstream's `BackendConnection` is 45 lines and three trivial members
/// (`BackendConnection.cpp:34-43`), which a struct literal is.
///
/// The tag is `BackendType`, which names nine back ends and carries an
/// `Undefined` (`src/api/enums.zig:41`-`:51`), so the union carries a member for
/// every one of the nine: a tagged union has to be able to hold every name its
/// tag can carry, and a tag with no field is a value the union cannot express.
/// `connect` never builds one but the null back end — it refuses the rest
/// (`Instance.cpp:531`-`:536` returns null upstream, and the port reports that
/// `BackendNotCompiledIn` instead), so the eight unnamed members keep the union
/// exhaustive rather than being states a caller can reach.
///
/// `webgpu` is one of the eight. `Instance.cpp:562`-`:564` clears it from the
/// default set because a WebGPU-on-WebGPU request is not a default, and this
/// build has no WebGPU back end at all, so it carries the same empty shape as
/// the `undefined_` member: a tag the union can hold and nothing more.
pub const BackendConnection = union(BackendType) {
    undefined_: void,
    null_: void,
    webgpu: void,
    d3d11: void,
    d3d12: void,
    metal: void,
    vulkan: void,
    opengl: void,
    opengles: void,
};

/// The adapters one enumeration produced, and the physical devices they point
/// at. Both slices are owned here so that an `Adapter` a caller keeps, and the
/// `Device` it builds from one, never point at freed memory. Dawn gets the same
/// guarantee from `Ref` counting a shared `PhysicalDeviceBase`; the port gets
/// it from the allocator.
///
/// The `Instance` that produced a list must outlive it: every adapter in the
/// list points back at that instance.
pub const AdapterList = struct {
    items: []Adapter,
    physical_devices: []physical_device.PhysicalDevice,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AdapterList) void {
        self.allocator.free(self.items);
        self.allocator.free(self.physical_devices);
        self.* = undefined;
    }
};

/// One handle onto the back ends.
///
/// Dawn's `InstanceBase` is refcounted and outlives its adapters
/// (`Instance.cpp:265-271`). The port makes the caller the owner: an instance is
/// a value that allocates nothing, and everything it hands out says who owns it.
pub const Instance = struct {
    backend_type: BackendType = .null_,
    enabled_instance_features: InstanceFeatureSet = .{},
    /// `mDevicesList` (`Instance.h:252`). Dawn keeps the list so a device can be
    /// refused while the instance is being torn down; the port keeps the count
    /// so `Device.deinit` can answer honestly.
    device_count: u64 = 0,

    pub const InitOptions = struct {
        /// `InstanceBase` defaults to every back end except `webgpu`
        /// (`Instance.cpp:562`-`:564`). At M8 exactly one back end exists.
        backend_type: BackendType = .null_,
        required_features: []const api.InstanceFeatureName = &.{},
    };

    /// `InstanceBase::InstanceBase` (`Instance.cpp:265-271`) with the toggles,
    /// the event manager and the platform connection dropped: each is a row
    /// whose milestone has not landed. Allocates nothing.
    pub fn init(options: InitOptions) Instance {
        var created: Instance = .{ .backend_type = options.backend_type };
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
        options: api.RequestAdapterOptions,
    ) Error!AdapterList {
        const devices = try self.enumeratePhysicalDevices(allocator, options);
        errdefer allocator.free(devices);
        if (devices.len == 0) {
            return .{ .items = &.{}, .physical_devices = &.{}, .allocator = allocator };
        }

        const built = try allocator.alloc(Adapter, devices.len);
        errdefer allocator.free(built);
        // Bound: the slice just allocated, one adapter per physical device.
        for (built, devices) |*slot, *device| {
            slot.* = try Adapter.init(self, device, .{
                .feature_level = options.feature_level,
                .power_preference = options.power_preference,
            });
        }
        sortAdapters(built, options.power_preference);
        return .{ .items = built, .physical_devices = devices, .allocator = allocator };
    }

    /// `InstanceBase::EnumeratePhysicalDevices` (`Instance.cpp:539-579`). The
    /// slice belongs to the caller, through the `AdapterList` that wraps it.
    pub fn enumeratePhysicalDevices(
        self: *const Instance,
        allocator: std.mem.Allocator,
        options: api.RequestAdapterOptions,
    ) Error![]physical_device.PhysicalDevice {
        const connection = try connect(backendOf(options, self.backend_type));
        var found = switch (connection) {
            .null_ => try null_backend.discoverPhysicalDevices(allocator, options),
            // `connect` builds only the null back end and refuses the rest, so
            // the eight connections the union can carry are not states the
            // enumeration can be in. They are listed rather than folded into
            // an `else` so a tenth `BackendType` name
            // (`src/api/enums.zig:41`-`:51`) fails to compile here rather than
            // silently becoming unreachable.
            .undefined_,
            .webgpu,
            .d3d11,
            .d3d12,
            .metal,
            .vulkan,
            .opengl,
            .opengles,
            => unreachable,
        };
        if (found.items.len > max_physical_device_count) {
            found.deinit(allocator);
            return error.TooManyPhysicalDevices;
        }
        return found.toOwnedSlice(allocator);
    }

    /// `InstanceBase::AddDevice` (`Instance.cpp:636-638`).
    pub fn addDevice(self: *Instance) void {
        self.device_count += 1;
    }

    /// `InstanceBase::RemoveDevice` (`Instance.cpp:640-642`).
    pub fn removeDevice(self: *Instance) void {
        std.debug.assert(self.device_count > 0);
        self.device_count -= 1;
    }

    /// `InstanceBase::GetDeviceCountForTesting` (`Instance.cpp:632-634`).
    pub fn queryDeviceCount(self: *const Instance) u64 {
        return self.device_count;
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
