//! The high device owns one core arena and an optional stable native context.
//! Keep the device at its final address after its first resource is attached.
//! Async starts use the same cells as the generated callback operators.
//! Keep their allocator and Io providers alive through accepted work and result disposal.

const std = @import("std");
const adapter_mod = @import("adapter.zig");
const buffer = @import("buffer.zig");
const descriptors = @import("../api/descriptors.zig");
const device_mod = @import("device.zig");
const encoding = @import("../command/encoding_context.zig");
const api = @import("../api/api.zig");
const core = @import("../core/root.zig");
const error_scope = @import("../core/error_scope.zig");
const features = @import("features.zig");
const format = @import("format.zig");
const instance_mod = @import("instance.zig");
const limits = @import("limits.zig");
const physical_device = @import("physical_device.zig");
const native_context = @import("native_device_context.zig");
const native_resources = @import("native_resources.zig");
const pipeline = @import("../pipeline/pipeline.zig");
const layout_internal = @import("../pipeline/layout_internal.zig");
const platform = @import("../platform/root.zig");
const queues = @import("queue.zig");
const serial_mod = @import("../platform/serial.zig");
const texture = @import("texture.zig");
const native_async = @import("native_async_device.zig");
const native_pipeline = @import("native_async_pipeline.zig");
const native_map_queue = @import("native_async_map_queue.zig");
const native_scope_info = @import("native_async_scope_info.zig");
const root_requests = @import("async_root_requests.zig");
const resource_store = @import("native_resource_store.zig");
const sampler = @import("sampler.zig");
const attachment = @import("../command/attachment_state.zig");
const attachment_store = @import("native_attachment_store.zig");
const command_encoder = @import("../command/command_encoder.zig");
const command_bundle = @import("../command/render_bundle.zig");
const command_render = @import("../command/render_encoder_base.zig");
const commands = @import("../command/commands.zig");
const replay = @import("command_buffer.zig");
const kernels = @import("native_kernels.zig");
const external_texture = @import("external_texture.zig");
const browser_copy = @import("../command/browser_copy.zig");
pub const CleanupError = native_context.CleanupError || native_resources.Error ||
    core.LifetimeError || native_async.DispatchError || error{ResourceInUse};

pub const Adapter = adapter_mod.Adapter;
pub const FeatureLevel = api.FeatureLevel;
pub const DeviceLostReason = api.DeviceLostReason;
pub const ErrorFilter = api.ErrorFilter;

pub const OperationError = native_context.Error || native_resources.Error ||
    texture.CreateError || texture.NativeCreateError || pipeline.CreateError ||
    error_scope.ScopeAllocationError || external_texture.ResourceError ||
    native_async.DispatchError ||
    queues.Queue.ReserveStagingUploadError || error{
    DeviceNotAlive,
    NativeBackendRequired,
    ResourceInUse,
    ResourceDeviceMismatch,
    TextureFormatUnsupported,
    DepthClipControlNotEnabled,
    Canceled,
    DeviceDeinitialized,
};

/// The wire enum and `core`'s filter are different types with different tag
/// values (`src/core/error_scope.zig:17-23`), so the boundary converts one
/// member at a time. No `else`, so a fourth upstream member is a compile error
/// here rather than a scope that silently selects the wrong set.
fn coreFilterFromApi(filter: ErrorFilter) core.ErrorFilter {
    return switch (filter) {
        .validation => .validation,
        .out_of_memory => .out_of_memory,
        .internal => .internal,
    };
}

/// The order of the three passes is the order `DeviceBase::Destroy`
/// (`Device.cpp:550-613`) runs them in.
///
/// `DeviceBase::State` (`Device.h:366-372`) names five values and the port
/// keeps four. `BeingCreated` (`Device.h:367`) is the one it drops: upstream
/// starts a device in that state (`Device.h:707`) and moves it to `Alive` at
/// the end of `Initialize` (`Device.cpp:419`), and the port's `init` is that
/// constructor and that call in one (`Device.cpp:401-452`), so no caller ever
/// holds a device that has a state but no arena.
pub const State = enum {
    alive,
    /// The device is no longer usable because the GPU timeline is draining.
    disconnecting,
    /// Nothing is on the GPU timeline and the CPU data is safe to reclaim.
    disconnected,
    destroyed,
};

/// Everything `Device.init` can refuse, plus the allocation failures the port
/// adds where Dawn's reference counting does not.
pub const InitError = std.mem.Allocator.Error || native_context.CreateError || limits.ReifyError || error{
    /// A device must have the compat block its limits are read through
    /// (`Limits.cpp:475-481`). Dawn can leave it null because
    /// `FillLimits` only writes a chained block the caller's chain names; the
    /// port has no chain, so a device without one cannot exist.
    LimitsCompatibilityBlockMissing,
    /// `Adapter.cpp:64` checks `SupportsFeatureLevel` in a `DAWN_CHECK`; the
    /// port reports it rather than aborting.
    FeatureLevelUnsupported,
    MissingObjectMutex,
    InvalidOwner,
};

/// Owns one core arena and, for Vulkan, one stable heap native context.
/// Keep the adapter list, instance and allocating storage alive through deinit.
/// Moving the device after its first object attachment or borrowed format row
/// invalidates references; copying it does not create a second owner.
/// Keep this storage alive until every concurrent call returns, including refused calls.
pub const Device = struct {
    pub const InitError = device_mod.InitError;
    /// The M3 device: the arena every handle names and the error-scope stack
    /// every error passes through. M11, M12 and M14 take this pointer.
    core: core.Device,
    adapter: *Adapter,
    feature_level: FeatureLevel,
    /// `mEnabledFeatures`, filled by `ApplyFeatures` (`Device.cpp:1723-1762`).
    enabled_features: features.FeaturesSet,
    /// Immutable conversion policy supplied at device creation.
    timestamp_quantization: bool,
    /// Rows specialized once from `enabled_features`. Keep this device at a
    /// stable address after borrowing a row, until all arena objects are released.
    format_table: format.FormatTable,
    /// Effective limits reified from offered physical capabilities and requests.
    limits: limits.CombinedLimits,
    label: []const u8,
    state: State = .alive,
    lost_reason: ?DeviceLostReason = null,
    lost_message: []const u8 = "",
    native: ?*native_context.NativeDeviceContext = null,
    pending_serial: ?serial_mod.Serial = null,
    submitting: bool = false,
    /// This high gate outlives native storage. Never borrow native before admission.
    /// Release it before DeviceMutex, queue waits, work, joins or callbacks.
    lifecycle_mutex: std.Io.Mutex = .init,
    active_operations: usize = 0,
    /// Accepted work is a drainable subset of the actual host operation count.
    active_async_operations: usize = 0,
    active_callbacks: u32 = 0,
    async_condition: std.Io.Condition = .init,
    async_state: native_async.State = .{},
    root_record: root_requests.RootRecord = .{ .kind = .device },
    default_queue_label: []const u8 = "",
    destroying: bool = false,
    host_deinitialized: bool = false,
    native_payloads_retired: bool = false,

    /// One `RequestDevice` call: what the caller asks for plus the two facts
    /// the adapter already knows. `Adapter.createDevice` checks the request
    /// against the adapter and hands what survives to `init`, so both
    /// boundaries take this one type.
    pub const CreateDeviceOptions = struct {
        adapter: *Adapter,
        label: ?[]const u8 = null,
        default_queue_label: ?[]const u8 = null,
        /// Null selects the Instance's multiple-device feature policy.
        consume_adapter: ?bool = null,
        required_features: []const api.FeatureName = &.{},
        timestamp_quantization: bool = true,
        /// `DeviceDescriptor.requiredLimits` (`src/api/descriptors.zig:76`).
        /// Accepted fields are reified into the effective device limits.
        required_limits: ?*const api.Limits = null,
        feature_level: FeatureLevel,
        uncaptured_context: *anyopaque,
        uncaptured_callback: error_scope.UncapturedErrorCallback,
        /// Required for a null backend; native devices use their stable context mutex.
        object_mutex: ?*std.Io.Mutex = null,
    };

    /// Creates the native context at its final address, but attaches no objects
    /// to the value-returned core arena. Successful construction retains the
    /// adapter, physical device and instance until destroy. Failure retains none.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: CreateDeviceOptions,
        permit: *instance_mod.Instance.DeviceCreationPermit,
    ) Device.InitError!Device {
        if (!permit.active or permit.committed or permit.adapter != options.adapter or
            permit.instance != options.adapter.instance) return error.InvalidOwner;
        const source = options.adapter.physical_device;
        if (!source.supportsFeatureLevel(options.feature_level)) {
            return error.FeatureLevelUnsupported;
        }

        // The compat block is read by every compatibility check
        // (`docs/10-architecture.md` "Compatibility mode"), so a device without
        // one cannot exist and this is where that is said out loud. It is the
        // ADAPTER's block that is refused: the device's own block is rebuilt
        // from the table below (`Device.cpp:339-341`), and `defaultLimits`
        // (`src/engine/limits.zig:558`) always writes one.
        if (options.adapter.limits.compatibility == null) {
            return error.LimitsCompatibilityBlockMissing;
        }

        // `Device.cpp:292-296`: the features are applied first and the
        // effective level is then read off them, because a caller that
        // requires `core_features_and_limits` on a compatibility adapter
        // turns the core feature on for a compatibility-level device
        // (`Device.cpp:1730-1732`). The level the caller cannot see is not
        // the level the limits are fixed up for.
        const enabled = applyFeatures(
            options.feature_level,
            options.required_features,
        );
        const effective_feature_level: FeatureLevel =
            if (enabled.isEnabled(.core_features_and_limits)) .core else .compatibility;

        // Resolve defaults within physical capabilities, then preserve accepted requests.
        var resolved = try limits.reify(
            options.adapter.limits,
            effective_feature_level,
            if (options.required_limits) |required| .{
                .v1 = required.*,
                .compatibility = null,
            } else null,
        );
        enforceLimitSpecInvariants(&resolved, effective_feature_level);

        const object_mutex = if (source.native_adapter == null)
            options.object_mutex orelse return error.MissingObjectMutex
        else
            null;
        var native_features: [features.feature_count]api.FeatureName = undefined;
        const native = if (source.native_adapter) |selected|
            try native_context.NativeDeviceContext.create(allocator, io, .{
                .adapter = selected,
                .handles = &options.adapter.instance.native_context.?.handles,
                .required_features = enabled.toSupportedFeatures(&native_features),
            })
        else
            null;

        var created: Device = .{
            .core = core.Device.init(allocator, .{
                .uncaptured_context = options.uncaptured_context,
                .uncaptured_callback = options.uncaptured_callback,
                .object_mutex = if (native) |context| &context.device_mutex.mutex else object_mutex.?,
            }),
            .adapter = options.adapter,
            .feature_level = options.feature_level,
            .enabled_features = enabled,
            .timestamp_quantization = options.timestamp_quantization,
            // SAFETY: buildFormatTable writes all 109 canonical rows below
            // before any Device reader or return.
            .format_table = undefined,
            .limits = resolved,
            .label = options.label orelse "",
            .default_queue_label = options.default_queue_label orelse "",
            .state = .alive,
            .native = native,
        };
        format.buildFormatTable(enabled, &created.format_table);
        // Write then read back: the three values a caller reads first.
        std.debug.assert(created.getFeatureLevel() == created.feature_level);
        std.debug.assert(created.limits.compatibility != null);
        // `Device.cpp:1755-1759` turns the core feature on for every core
        // device, so a core device is never in compatibility mode. The
        // converse is not an invariant and no adapter-side rule covers it: a
        // compatibility-level device whose caller required the core feature
        // is out of compatibility mode (`Device.cpp:294-296`), and the adapter
        // never saw the request.
        std.debug.assert(options.feature_level != .core or !created.isCompatibilityMode());
        permit.commit(io);
        return created;
    }

    /// Refuses live aliases before shutdown. Successful final teardown is idempotent.
    pub fn deinit(self: *Device, allocator: std.mem.Allocator, io: std.Io) CleanupError!void {
        if (!try self.reserveTeardown(io)) return;
        defer self.finishTeardown(io);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, self.core.arena.objectList());
            defer guard.unlock(io);
            try self.core.arena.checkAllocator(&guard, allocator);
            // Internal dependencies and pending GPU uses may drain during retirement.
            // User ownership must refuse before any logical or native shutdown.
            if (self.core.arena.objectList().user_reference_count != 0) return error.ResourceInUse;
            try self.core.error_scopes.preflightDeinit(&guard);
            try self.bindObjectsLocked(&guard, allocator);
        }
        try native_async.closeAndDrain(self, io);
        native_async.finishLoss(self, allocator, io, .destroyed, "Device destroyed.");
        try native_async.prepareHostDetach(self, io);
        var first: ?CleanupError = null;
        self.retireNativePayloads(allocator, io) catch |err| {
            if (!self.native_payloads_retired) return err;
            first = err;
        };
        var guard = core.ObjectGuard.lockUncancelable(io, self.core.arena.objectList());
        self.core.deinit(allocator, &guard) catch |err| {
            guard.unlock(io);
            return first orelse err;
        };
        // The guard captures the original mutex. Unlock before freeing its context.
        guard.unlock(io);
        if (self.native) |context| allocator.destroy(context);
        native_async.releaseHostState(self, allocator, io);
        self.lifecycle_mutex.lockUncancelable(io);
        self.native = null;
        self.host_deinitialized = true;
        self.lifecycle_mutex.unlock(io);
        self.adapter.getInstance().releaseDeviceParents(io, self.adapter);
        if (first) |err| return err;
        if (native_async.takeDispatchError(self, io)) |err| return err;
    }

    /// Retires GPU payloads but keeps aliases, the arena, original mutex and parents.
    /// A nonterminal wait failure keeps every native owner stopped and retryable.
    pub fn destroy(self: *Device, allocator: std.mem.Allocator, io: std.Io) CleanupError!void {
        if (!try self.reserveTeardown(io)) return;
        defer self.finishTeardown(io);
        {
            var guard = core.ObjectGuard.lockUncancelable(io, self.core.arena.objectList());
            defer guard.unlock(io);
            try self.core.arena.checkAllocator(&guard, allocator);
            try self.bindObjectsLocked(&guard, allocator);
        }
        try native_async.closeAndDrain(self, io);
        native_async.finishLoss(self, allocator, io, .destroyed, "Device destroyed.");
        try self.retireNativePayloads(allocator, io);
        if (native_async.takeDispatchError(self, io)) |err| return err;
    }

    fn reserveTeardown(self: *Device, io: std.Io) CleanupError!bool {
        self.lifecycle_mutex.lockUncancelable(io);
        defer self.lifecycle_mutex.unlock(io);
        if (self.host_deinitialized) return false;
        std.debug.assert(self.active_operations >= self.active_async_operations);
        if (self.destroying or self.active_callbacks != 0 or
            self.active_operations != self.active_async_operations) return error.ResourceInUse;
        if (self.async_state.registry) |registry| {
            try registry.ownerPreflight(io, self.async_state.owner_identity);
        }
        self.destroying = true;
        return true;
    }

    fn finishTeardown(self: *Device, io: std.Io) void {
        self.lifecycle_mutex.lockUncancelable(io);
        self.destroying = false;
        self.lifecycle_mutex.unlock(io);
    }

    fn retireNativePayloads(self: *Device, allocator: std.mem.Allocator, io: std.Io) CleanupError!void {
        if (self.native_payloads_retired) return;
        self.lifecycle_mutex.lockUncancelable(io);
        self.setDisconnectingIfAlive();
        self.lifecycle_mutex.unlock(io);
        var first: ?CleanupError = null;
        if (self.native) |context| {
            context.retirePayloads(allocator, io, &self.core) catch |err| {
                if (!context.native_payloads_retired) return err;
                first = err;
            };
            if (context.terminal_loss) self.recordNativeLoss(io);
        } else {
            var guard = core.ObjectGuard.lockUncancelable(io, self.core.arena.objectList());
            defer guard.unlock(io);
            try native_resources.destroyAll(&self.core, &guard, io);
        }
        self.lifecycle_mutex.lockUncancelable(io);
        self.native_payloads_retired = true;
        self.state = .destroyed;
        self.pending_serial = null;
        self.lifecycle_mutex.unlock(io);
        if (first) |err| return err;
    }

    /// `DeviceBase::SetDisconnectingIfAlive` (`:921-924`). The exchange is a
    /// compare-and-swap upstream and a guard here, because M8 has no device
    /// mutex; M9 takes the lock (`Device.cpp:2652`).
    pub fn setDisconnectingIfAlive(self: *Device) void {
        if (self.state == .alive) self.state = .disconnecting;
    }

    /// `DeviceBase::Disconnect` (`:926-951`). The queue wait and the tick at
    /// `:942-948` land at M9 with the queue; what remains is the transition.
    pub fn disconnect(self: *Device) void {
        switch (self.state) {
            .disconnected, .destroyed => return,
            // `Device.cpp:931` calls this unreachable, and so does the port:
            // a destroyed device is already disconnected.
            .alive, .disconnecting => self.state = .disconnected,
        }
    }

    /// `DeviceBase::GetState` (`:909-912`).
    pub fn getState(self: *const Device) State {
        return self.state;
    }

    /// `DeviceBase::IsLost` (`:914-919`), which upstream answers from the state
    /// and which the port answers from the recorded reason, because a device
    /// can be lost while still alive.
    pub fn isLost(self: *const Device) bool {
        return self.lost_reason != null;
    }

    /// Copies and publishes the first loss through the actual high owner arbiter.
    pub fn handleDeviceLost(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        reason: DeviceLostReason,
        message: []const u8,
    ) void {
        native_async.finishLoss(self, allocator, io, reason, message);
    }

    pub fn getInstance(self: *const Device) *const instance_mod.Instance {
        return self.adapter.getInstance();
    }

    /// `DeviceBase::GetAdapter` (`:965-967`) and `APIGetAdapter` (`:1628-1631`).
    pub fn getAdapter(self: *const Device) *const Adapter {
        return self.adapter;
    }

    /// `DeviceBase::GetPhysicalDevice` (`:969-971`).
    pub fn getPhysicalDevice(self: *const Device) *const physical_device.PhysicalDevice {
        return self.adapter.getPhysicalDevice();
    }

    pub fn getFeatureLevel(self: *const Device) FeatureLevel {
        return self.feature_level;
    }

    /// Borrows the only arena. Do not move the device after attaching an object.
    pub fn coreDevice(self: *Device) *core.Device {
        return &self.core;
    }

    /// Pins this stable device before native access or accepted work.
    /// Pair each successful admission with releaseOperation after its final access.
    pub fn acquireOperation(self: *Device, io: std.Io) OperationError!void {
        try self.lifecycle_mutex.lock(io);
        defer self.lifecycle_mutex.unlock(io);
        if (self.host_deinitialized) return error.DeviceDeinitialized;
        if (self.state != .alive or self.destroying) return error.DeviceNotAlive;
        if (self.active_operations == std.math.maxInt(usize)) return error.ResourceInUse;
        self.active_operations += 1;
        std.debug.assert(self.active_operations != 0);
    }

    /// Pins host identity, including stopped devices and retired resource aliases.
    pub fn acquireHostOperation(self: *Device, io: std.Io) OperationError!void {
        try self.lifecycle_mutex.lock(io);
        defer self.lifecycle_mutex.unlock(io);
        if (self.host_deinitialized) return error.DeviceDeinitialized;
        if (self.destroying) return error.ResourceInUse;
        if (self.active_operations == std.math.maxInt(usize)) return error.ResourceInUse;
        self.active_operations += 1;
    }

    /// Caller holds an authoritative pin (or exclusive teardown admission) and guard.
    pub fn bindObjectsLocked(
        self: *Device,
        guard: *const core.ObjectGuard,
        allocator: std.mem.Allocator,
    ) error{AllocatorMismatch}!void {
        try self.core.arena.checkAllocator(guard, allocator);
        self.core.bindTrackingOwner(guard, self);
        if (self.native) |context| {
            std.debug.assert(self.core.arena.objectList().mutex == &context.device_mutex.mutex);
            if (context.objects == null) context.objects = self.core.arena.objectList();
            std.debug.assert(context.objects.? == self.core.arena.objectList());
            if (context.pipeline_store == null and !context.native_payloads_retired)
                context.pipeline_store = pipeline.PipelineStore.init(allocator, self.core.arena.objectList());
            if (context.resource_store == null and !context.native_payloads_retired)
                context.resource_store = resource_store.ResourceStore.init(allocator, self.core.arena.objectList());
            if (context.kernel_cache == null and !context.native_payloads_retired) {
                context.kernel_cache = kernels.KernelCache.init(.{
                    .objects = self.core.arena.objectList(),
                    .native_device = &context.native_device,
                    .enabled_features = &self.enabled_features,
                    .limits = &self.limits,
                    .formats = &self.format_table,
                    .resource_device = context.resourceDevice(),
                    .pipeline_store = &context.pipeline_store.?,
                    .pipeline_backend = &context.pipeline_backend,
                });
            }
        }
    }

    /// Ends one admitted operation. Do not hold any native or registry lock here.
    pub fn releaseOperation(self: *Device, io: std.Io) void {
        self.lifecycle_mutex.lockUncancelable(io);
        defer self.lifecycle_mutex.unlock(io);
        std.debug.assert(self.active_operations != 0);
        self.active_operations -= 1;
    }

    // A successful operation pin protects this pointer, even before DeviceMutex.
    fn nativeContext(self: *Device) OperationError!*native_context.NativeDeviceContext {
        return self.native orelse error.NativeBackendRequired;
    }

    fn recordNativeLoss(self: *Device, io: std.Io) void {
        native_async.finishLoss(self, self.core.arena.memory.child_allocator, io, .unknown, "Vulkan device lost.");
    }

    fn checkResource(self: *Device, guard: *const core.ObjectGuard, resource: anytype) OperationError!void {
        guard.assertOwns(self.core.arena.objectList());
        if (resource.header.tracking != self.core.arena.objectList()) return error.ResourceDeviceMismatch;
        if (!resource.header.node.linked or resource.header.state != .alive)
            return error.ResourceDestroyed;
    }

    /// A scoped queue-operation borrow with an authoritative device pin.
    /// No raw queue escapes; submit declares the strong roots of its native commands.
    pub const QueueLease = struct {
        device: ?*Device,

        pub fn commandBuffer(self: *const QueueLease) @import("vulkan").VkCommandBuffer {
            const device = self.device orelse @panic("closed queue lease");
            return device.native.?.queue.commandBuffer();
        }

        pub fn lastSubmittedSerial(self: *const QueueLease) serial_mod.Serial {
            const device = self.device orelse @panic("closed queue lease");
            return device.native.?.queue.timeline.lastSubmittedSerial();
        }

        pub fn submit(
            self: *QueueLease,
            allocator: std.mem.Allocator,
            io: std.Io,
            options: queues.Queue.SubmitOptions,
            roots: []const *core.Object,
        ) OperationError!queues.Queue.SubmitResult {
            const device = self.device orelse return error.DeviceNotAlive;
            const context = device.native.?;
            const submitted = context.submitDeclaredLocked(
                allocator,
                io,
                &device.core,
                options,
                roots,
            ) catch |err| {
                if (err == error.DeviceLost) device.recordNativeLoss(io);
                return err;
            };
            var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
            defer guard.unlock(io);
            device.pending_serial = submitted.serial;
            return submitted;
        }

        /// Releases this exact borrow once. Submitted roots remain serial-owned.
        pub fn deinit(self: *QueueLease, io: std.Io) void {
            const device = self.device orelse return;
            const context = device.native.?;
            {
                var guard = core.ObjectGuard.lockUncancelable(io, device.core.arena.objectList());
                defer guard.unlock(io);
                device.submitting = false;
            }
            self.device = null;
            context.queue_operation_mutex.unlock(io);
            device.releaseOperation(io);
        }
    };

    /// I/O is borrowed only for this call; the lease stores no I/O capability.
    pub fn getQueue(self: *Device, io: std.Io) OperationError!QueueLease {
        try self.acquireOperation(io);
        errdefer self.releaseOperation(io);
        const context = try self.nativeContext();
        try context.queue_operation_mutex.lock(io);
        errdefer context.queue_operation_mutex.unlock(io);
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, context.queue.context.allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        if (self.submitting) return error.ResourceInUse;
        self.submitting = true;
        return .{ .device = self };
    }

    /// Allocates native memory from the selected device's memory properties.
    /// Release through this device; host payload storage remains arena-owned.
    pub fn createBuffer(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        descriptor: buffer.BufferDescriptor,
    ) OperationError!*native_resources.Buffer {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        return native_resources.createBuffer(
            allocator,
            io,
            &guard,
            &self.core.arena,
            context.resourceDevice(),
            descriptor,
        );
    }

    /// Copies and reflects the caller's unchanged SPIR-V words.
    /// The returned owner and its allocator remain live until release or teardown.
    pub fn createShaderModule(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: native_resources.ShaderModuleOptions,
    ) OperationError!*native_resources.ShaderModule {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        return native_resources.createShaderModule(
            allocator,
            io,
            &guard,
            &self.core.arena,
            context.resourceDevice(),
            options,
        );
    }

    /// Copies shader diagnostics into an owned result. Cancellation abandons only observation.
    /// Consume the await or cancel result once with its deinit method.
    pub fn getCompilationInfoAsync(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        module: *native_resources.ShaderModule,
    ) api.AsyncStartError!std.Io.Future(native_scope_info.NativeInfoResult) {
        return native_scope_info.getCompilationInfoAsync(self, module, allocator, io);
    }

    /// Creates a descriptor layout validated against effective device limits.
    pub fn createBindGroupLayout(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        descriptor: layout_internal.Descriptor,
    ) OperationError!*native_resources.BindGroupLayout {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        const compat = &self.limits.compatibility.?;
        const validation: layout_internal.ValidateOptions = .{
            .max_storage_buffers_in_vertex_stage = compat.max_storage_buffers_in_vertex_stage,
            .max_storage_buffers_in_fragment_stage = compat.max_storage_buffers_in_fragment_stage,
        };
        return native_resources.createBindGroupLayout(
            allocator,
            io,
            &guard,
            &self.core.arena,
            context.resourceDevice(),
            .{
                .descriptor = descriptor,
                .validation = validation,
            },
        );
    }

    /// Creates a pipeline layout and retains each supplied group layout.
    pub fn createPipelineLayout(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: native_resources.PipelineLayoutOptions,
    ) OperationError!*native_resources.PipelineLayout {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        if (options.immediate_size > self.limits.v1.max_immediate_size)
            return error.ImmediateSizeInvalid;
        return native_resources.createPipelineLayout(
            allocator,
            io,
            &guard,
            &self.core.arena,
            context.resourceDevice(),
            options,
        );
    }

    /// Creates descriptor storage and retains its layout and bound resources.
    pub fn createBindGroup(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: native_resources.BindGroupOptions,
    ) OperationError!*native_resources.BindGroup {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        return native_resources.createBindGroup(
            allocator,
            io,
            &guard,
            &self.core.arena,
            context.resourceDevice(),
            options,
        );
    }

    /// Creates a compute pipeline under effective device workgroup limits.
    /// Retains its shader and pipeline layout through the typed owner.
    pub fn createComputePipeline(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: native_resources.ComputePipelineDescriptor,
    ) OperationError!*native_resources.Pipeline {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        try self.checkResource(&guard, options.layout);
        if (options.layout.native.immediate_size > self.limits.v1.max_immediate_size)
            return error.ImmediateSizeInvalid;
        try self.checkResource(&guard, options.compute.module);
        const descriptor = try options.toNative(&guard, .{
            .max_workgroup_size = .{
                self.limits.v1.max_compute_workgroup_size_x,
                self.limits.v1.max_compute_workgroup_size_y,
                self.limits.v1.max_compute_workgroup_size_z,
            },
            .max_invocations = self.limits.v1.max_compute_invocations_per_workgroup,
        }, context.native_device.maintenance4_enabled);
        const handle = try pipeline.createComputePipelineLocked(
            allocator,
            io,
            &guard,
            &self.core,
            &context.pipeline_store.?,
            &context.pipeline_backend,
            descriptor,
            .lease,
        );
        const native = try self.core.resolve(&guard, pipeline.Pipeline, handle);
        errdefer native.header.releaseLeaseLocked(&guard, io);
        return native_resources.createPipelineWrapper(
            allocator,
            io,
            &guard,
            &self.core.arena,
            native,
            .compute,
            &.{options.compute.module},
        );
    }

    /// Copies the descriptor before acceptance. Cancellation abandons only observation.
    /// Consume the await or cancel result once: release its pipeline or owned error reference.
    /// Release a successful pipeline with this device, allocator, and Io.
    pub fn createComputePipelineAsync(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        descriptor: *const api.descriptors.ComputePipelineDescriptorChain,
    ) api.AsyncStartError!std.Io.Future(native_pipeline.NativePipelineResult) {
        return native_pipeline.createComputePipelineFuture(self, allocator, io, descriptor);
    }

    /// Compatibility is derived from this device's render-pass cache.
    pub fn createRenderPipeline(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: native_resources.RenderPipelineDescriptor,
    ) OperationError!*native_resources.Pipeline {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        try self.checkResource(&guard, options.layout);
        if (options.layout.native.immediate_size > self.limits.v1.max_immediate_size)
            return error.ImmediateSizeInvalid;
        try self.checkResource(&guard, options.vertex.module);
        if (options.fragment) |fragment| try self.checkResource(&guard, fragment.module);
        if (options.primitive.unclipped_depth and !self.hasFeature(.depth_clip_control))
            return error.DepthClipControlNotEnabled;
        var color_formats: [8]u32 = @splat(0);
        if (options.color_targets.len > color_formats.len) return error.TooManyAttachments;
        for (options.color_targets, 0..) |target, index| color_formats[index] = @backingInt(target.format);
        const value = try self.renderAttachmentLayout(.{
            .color_formats = color_formats[0..options.color_targets.len],
            .depth_stencil_format = if (options.depth_stencil) |depth| @backingInt(depth.format) else 0,
            .sample_count = options.multisample.count,
            .expand_resolve = .{},
            .pls = null,
        });
        const state = try attachment_store.create(
            allocator,
            io,
            &guard,
            &self.core.arena,
            &context.resource_store.?,
            value,
        );
        defer state.header.releaseUserLocked(&guard, io) catch unreachable;
        var color_count = options.color_targets.len;
        while (color_count != 0 and options.color_targets[color_count - 1].format == .undefined_)
            color_count -= 1;
        var native_colors: [8]pipeline.ColorTargetState = undefined;
        for (options.color_targets[0..color_count], native_colors[0..color_count]) |target, *native| {
            native.* = if (target.format == .undefined_) .{
                .format = 0,
                .write_mask = 0,
                .blend = null,
            } else target.toNative();
        }
        const descriptor = try options.toNative(
            &guard,
            try context.compatibleRenderPass(io, options),
            native_colors[0..color_count],
        );
        const handle = try pipeline.createRenderPipelineLocked(
            allocator,
            io,
            &guard,
            &self.core,
            &context.pipeline_store.?,
            &context.pipeline_backend,
            descriptor,
            .lease,
        );
        const native = try self.core.resolve(&guard, pipeline.Pipeline, handle);
        errdefer native.header.releaseLeaseLocked(&guard, io);
        var shaders: [2]*native_resources.ShaderModule = .{
            options.vertex.module, options.vertex.module,
        };
        const shader_count: usize = if (options.fragment) |fragment| count: {
            shaders[1] = fragment.module;
            break :count 2;
        } else 1;
        return native_resources.createPipelineWrapper(
            allocator,
            io,
            &guard,
            &self.core.arena,
            native,
            .{ .render = state },
            shaders[0..shader_count],
        );
    }

    /// Interns a real Vulkan sampler and returns one user alias.
    pub fn createSampler(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: descriptors.SamplerDescriptorChain,
    ) OperationError!*sampler.Sampler {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        return native_resources.createSamplerLocked(
            allocator,
            io,
            &guard,
            &self.core.arena,
            context.resourceDevice(),
            options,
        );
    }

    /// Creates one external owner from the actual device capabilities.
    pub fn createExternalTexture(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        supplied: external_texture.Options,
    ) OperationError!*external_texture.ExternalTexture {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        var options = supplied;
        options.enabled_features = &self.enabled_features;
        options.limits = &self.limits;
        return external_texture.create(
            allocator,
            io,
            &guard,
            &self.core.arena,
            context.resourceDevice(),
            options,
        );
    }

    pub fn expireExternalTexture(
        self: *Device,
        io: std.Io,
        resource: *external_texture.ExternalTexture,
    ) OperationError!void {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, self.core.arena.memory.child_allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        try resource.expireLocked(&guard);
    }

    pub fn refreshExternalTexture(
        self: *Device,
        io: std.Io,
        resource: *external_texture.ExternalTexture,
    ) OperationError!void {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, self.core.arena.memory.child_allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        try resource.refreshLocked(&guard);
    }

    /// Logical destruction leaves every user alias available for its final release.
    pub fn destroyExternalTexture(
        self: *Device,
        io: std.Io,
        resource: *external_texture.ExternalTexture,
    ) OperationError!void {
        try self.acquireHostOperation(io);
        defer self.releaseOperation(io);
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, self.core.arena.memory.child_allocator);
        if (resource.header.tracking != self.core.arena.objectList())
            return error.ResourceDeviceMismatch;
        if (resource.header.kind != .external_texture) return error.InvalidResourceRef;
        resource.header.retirePayloadLocked(&guard, io, .early_destroy);
        if (self.native) |context| {
            if (context.cleanup_error) |err| return err;
        }
    }

    /// Engine-only native format creation. Public texture descriptors stay unchanged.
    pub fn createInternalYCbCrTexture(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: texture.InternalYCbCrDescriptor,
    ) OperationError!*texture.Texture {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        try self.checkResource(&guard, options.conversion_sampler);
        const maximum = @min(self.limits.v1.max_texture_dimension_2d, context.textureLimits().max_texture_dimension_2d);
        if (options.size.width > maximum or options.size.height > maximum)
            return error.TextureSizeAboveLimit;
        return texture.Texture.createInternalYCbCr(
            allocator,
            io,
            &guard,
            &self.core.arena,
            context.bufferDevice(),
            options,
        );
    }

    pub fn createInternalYCbCrTextureView(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: struct { texture: *texture.Texture, conversion_sampler: *sampler.Sampler },
    ) OperationError!*texture.TextureView {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        try self.checkResource(&guard, options.texture);
        try self.checkResource(&guard, options.conversion_sampler);
        return texture.TextureView.createInternalYCbCr(
            allocator,
            io,
            &guard,
            &self.core.arena,
            options.texture,
            options.conversion_sampler,
        );
    }

    pub const CopyTextureForBrowserOptions = struct {
        source: *texture.TextureView,
        destination: *texture.TextureView,
        source_origin: api.Origin2D = .{},
        destination_origin: api.Origin2D = .{},
        copy_size: api.Extent2D,
        browser: api.CopyTextureForBrowserOptions = .{},
    };

    /// Records copied browser metadata. Pixel conversion occurs during native replay.
    pub fn copyTextureForBrowser(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        encoder: *command_encoder.CommandEncoder,
        supplied: CopyTextureForBrowserOptions,
    ) OperationError!void {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        if (encoder.device.objectList() != self.core.arena.objectList())
            return error.ResourceDeviceMismatch;
        const options = try browserOptions(supplied.browser);
        try self.validateBrowserView(&guard, supplied.source, .{
            .origin = supplied.source_origin,
            .size = supplied.copy_size,
            .destination = false,
        });
        try self.validateBrowserView(&guard, supplied.destination, .{
            .origin = supplied.destination_origin,
            .size = supplied.copy_size,
            .destination = true,
        });
        if (supplied.source.format_info.aspect_info[0].base_type !=
            supplied.destination.format_info.aspect_info[0].base_type)
            return error.TextureFormatUnsupported;
        try encoder.copyTextureForBrowser(.{
            .source = @ptrCast(supplied.source),
            .destination = @ptrCast(supplied.destination),
            .source_origin = .{ .x = supplied.source_origin.x, .y = supplied.source_origin.y },
            .destination_origin = .{
                .x = supplied.destination_origin.x,
                .y = supplied.destination_origin.y,
            },
            .copy_size = .{ .width = supplied.copy_size.width, .height = supplied.copy_size.height },
            .options = options,
        });
    }

    pub const CopyExternalTextureForBrowserOptions = struct {
        source: *external_texture.ExternalTexture,
        destination: *texture.TextureView,
        source_origin: api.Origin2D = .{},
        source_natural_size: api.Extent2D,
        destination_origin: api.Origin2D = .{},
        copy_size: api.Extent2D,
        browser: api.CopyTextureForBrowserOptions = .{},
    };

    pub fn copyExternalTextureForBrowser(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        encoder: *command_encoder.CommandEncoder,
        supplied: CopyExternalTextureForBrowserOptions,
    ) OperationError!void {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        if (encoder.device.objectList() != self.core.arena.objectList())
            return error.ResourceDeviceMismatch;
        const options = try browserOptions(supplied.browser);
        const source = try supplied.source.ref(&guard);
        const natural = supplied.source_natural_size;
        if (natural.width == 0 or natural.height == 0 or
            natural.width > self.limits.v1.max_texture_dimension_2d or
            natural.height > self.limits.v1.max_texture_dimension_2d or
            supplied.copy_size.width > natural.width or supplied.copy_size.height > natural.height)
            return error.ExternalTextureInvalidBrowserCopy;
        if (supplied.source_origin.x > natural.width - supplied.copy_size.width or
            supplied.source_origin.y > natural.height - supplied.copy_size.height)
            return error.ExternalTextureInvalidBrowserCopy;
        try self.validateBrowserView(&guard, supplied.destination, .{
            .origin = supplied.destination_origin,
            .size = supplied.copy_size,
            .destination = true,
        });
        if (supplied.destination.format_info.aspect_info[0].base_type != .float)
            return error.TextureFormatUnsupported;
        try encoder.copyExternalTextureForBrowser(.{
            .source = source,
            .destination = @ptrCast(supplied.destination),
            .source_origin = .{ .x = supplied.source_origin.x, .y = supplied.source_origin.y },
            .destination_origin = .{
                .x = supplied.destination_origin.x,
                .y = supplied.destination_origin.y,
            },
            .copy_size = .{ .width = supplied.copy_size.width, .height = supplied.copy_size.height },
            .natural_size = .{ .width = natural.width, .height = natural.height },
            .options = options,
        });
    }

    fn browserOptions(supplied: api.CopyTextureForBrowserOptions) browser_copy.Error!browser_copy.Options {
        return browser_copy.Options.fromInput(.{
            .flip_y = supplied.flip_y,
            .needs_color_space_conversion = supplied.needs_color_space_conversion,
            .src_alpha_mode = browserAlphaMode(supplied.src_alpha_mode),
            .dst_alpha_mode = browserAlphaMode(supplied.dst_alpha_mode),
            .src_transfer_function_parameters = supplied.src_transfer_function_parameters,
            .conversion_matrix = supplied.conversion_matrix,
            .dst_transfer_function_parameters = supplied.dst_transfer_function_parameters,
            .internal_usage = supplied.internal_usage,
        });
    }

    fn browserAlphaMode(mode: api.AlphaMode) browser_copy.AlphaMode {
        return switch (mode) {
            .opaque_ => .opaque_,
            .premultiplied => .premultiplied,
            .unpremultiplied => .unpremultiplied,
        };
    }

    fn validateBrowserView(
        self: *Device,
        guard: *const core.ObjectGuard,
        view: *texture.TextureView,
        region: struct { origin: api.Origin2D, size: api.Extent2D, destination: bool },
    ) OperationError!void {
        try self.checkResource(guard, view);
        try self.checkResource(guard, view.texture);
        if (view.texture.native_y_cb_cr != null) return error.TextureFormatUnsupported;
        if (view.dimension != ._2d and view.dimension != ._2d_array) return error.InvalidCopy;
        if (view.range.level_count != 1 or view.range.layer_count != 1 or
            view.texture.dimension != ._2d or view.texture.sample_count != 1 or
            view.aspects.color == 0 or view.aspects.depth != 0 or view.aspects.stencil != 0)
            return error.InvalidCopy;
        if (!view.format_info.isSupported() or !view.format_info.isColor() or
            view.format_info.is_compressed) return error.TextureFormatUnsupported;
        if (view.native_view == null or view.texture.native == null)
            return error.TextureNativeNotInitialized;
        if (region.destination) {
            if (!view.usage.copy_dst or !view.internal_usage.render_attachment)
                return error.InvalidCopy;
        } else if (!view.usage.copy_src or !view.internal_usage.texture_binding) {
            return error.InvalidCopy;
        }
        const size = view.texture.getMipLevelSingleSubresourceVirtualSize(guard, view.range.base_mip_level);
        if (region.size.width > size.width or region.size.height > size.height)
            return error.InvalidCopy;
        if (region.origin.x > size.width - region.size.width or
            region.origin.y > size.height - region.size.height)
            return error.InvalidCopy;
    }

    /// Produces canonical metadata from actual registered view owners.
    pub fn beginRenderPass(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        encoder: *command_encoder.CommandEncoder,
        supplied: command_encoder.BeginRenderPassOptions,
    ) OperationError!command_render.RenderEncoderBase {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        if (encoder.device.objectList() != self.core.arena.objectList())
            return error.ResourceDeviceMismatch;
        if (supplied.color_attachments.len > self.limits.v1.max_color_attachments)
            return error.TooManyAttachments;
        var options = supplied;
        var first_view: commands.Ref = supplied.depth_stencil_attachment.view;
        for (supplied.color_attachments) |color| {
            if (color.view != null) {
                first_view = color.view;
                break;
            }
        }
        const view = try native_resources.resolveTextureViewRefLocked(&guard, &self.core, first_view);
        const extent = view.texture.getMipLevelSingleSubresourceVirtualSize(&guard, view.range.base_mip_level);
        if (options.width == 0) options.width = extent.width;
        if (options.height == 0) options.height = extent.height;
        if (options.occlusion_query_set != null) {
            const set = try native_resources.resolveQuerySetRefLocked(&guard, &self.core, options.occlusion_query_set);
            options.occlusion_query_type = set.query_type;
            options.occlusion_query_count = set.query_count;
        }
        if (options.timestamp_writes.query_set != null) {
            const set = try native_resources.resolveQuerySetRefLocked(&guard, &self.core, options.timestamp_writes.query_set);
            options.timestamp_query_type = set.query_type;
            options.timestamp_query_count = set.query_count;
        }
        const value = try replay.buildAttachmentStateLocked(
            &guard,
            &self.core,
            options.color_attachments,
            options.depth_stencil_attachment,
            options.width,
            options.height,
        );
        const state = try attachment_store.create(
            allocator,
            io,
            &guard,
            &self.core.arena,
            &context.resource_store.?,
            value,
        );
        defer state.header.releaseUserLocked(&guard, io) catch unreachable;
        return encoder.beginRenderPass(io, &guard, state, options);
    }

    /// Creates a real arena bundle encoder with the same canonical render tuple.
    pub fn createRenderBundleEncoder(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: native_resources.RenderBundleEncoderOptions,
    ) OperationError!command_bundle.RenderBundleEncoder {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        var color_formats: [8]u32 = @splat(0);
        if (options.color_formats.len > color_formats.len) return error.TooManyAttachments;
        for (options.color_formats, 0..) |value, index| color_formats[index] = @backingInt(value);
        const value = try self.renderAttachmentLayout(.{
            .color_formats = color_formats[0..options.color_formats.len],
            .depth_stencil_format = @backingInt(options.depth_stencil_format),
            .sample_count = options.sample_count,
            .expand_resolve = .{},
            .pls = null,
        });
        const state = try attachment_store.create(
            allocator,
            io,
            &guard,
            &self.core.arena,
            &context.resource_store.?,
            value,
        );
        defer state.header.releaseUserLocked(&guard, io) catch unreachable;
        return command_bundle.RenderBundleEncoder.init(
            allocator,
            io,
            &guard,
            &self.core,
            state,
            options.command_options,
        );
    }

    fn renderAttachmentLayout(self: *const Device, input: attachment.LayoutShape) OperationError!attachment.AttachmentState {
        if (input.color_formats.len > self.limits.v1.max_color_attachments)
            return error.TooManyAttachments;
        for (input.color_formats) |wire| {
            if (wire == 0) continue;
            const info = self.formatInfo(@fromBackingInt(@intCast(wire))) orelse return error.ColorTargetFormatNotRenderable;
            if (!info.isSupported() or !info.caps.renderable or !info.isColor())
                return error.ColorTargetFormatNotRenderable;
            if (input.sample_count > 1 and !info.caps.multisample)
                return error.AttachmentSampleCountUnsupported;
        }
        if (input.depth_stencil_format != 0) {
            const info = self.formatInfo(@fromBackingInt(@intCast(input.depth_stencil_format))) orelse
                return error.DepthStencilFormatNotRenderable;
            if (!info.isSupported() or !info.caps.renderable or info.isColor())
                return error.DepthStencilFormatNotRenderable;
            if (input.sample_count > 1 and !info.caps.multisample)
                return error.AttachmentSampleCountUnsupported;
        }
        return attachment.AttachmentState.fromRenderPipeline(input, .{
            .max_color_attachments = self.limits.v1.max_color_attachments,
            .max_storage_attachments = 0,
            .max_pls_bytes = 0,
        });
    }

    /// Copies the descriptor before acceptance. Cancellation abandons only observation.
    /// Consume the await or cancel result once: release its pipeline or owned error reference.
    /// Release a successful pipeline with this device, allocator, and Io.
    pub fn createRenderPipelineAsync(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        descriptor: *const api.descriptors.RenderPipelineDescriptorChain,
    ) api.AsyncStartError!std.Io.Future(native_pipeline.NativePipelineResult) {
        return native_pipeline.createRenderPipelineFuture(self, allocator, io, descriptor);
    }

    /// Creates native image storage using actual format capabilities.
    /// The descriptor is borrowed only during creation.
    pub fn createTexture(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        descriptor: descriptors.TextureDescriptorChain,
    ) OperationError!*texture.Texture {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        const info = self.formatInfo(descriptor.format) orelse
            return error.TextureFormatUnsupported;
        if (!info.isSupported()) return error.TextureFormatUnsupported;
        const native_limits = context.textureLimits();
        const handle = try texture.Texture.create(allocator, io, &guard, &self.core, .{
            .descriptor = descriptor,
            .format_info = info,
            .limits = .{
                .max_texture_dimension_1d = @min(
                    self.limits.v1.max_texture_dimension_1d,
                    native_limits.max_texture_dimension_1d,
                ),
                .max_texture_dimension_2d = @min(
                    self.limits.v1.max_texture_dimension_2d,
                    native_limits.max_texture_dimension_2d,
                ),
                .max_texture_dimension_3d = @min(
                    self.limits.v1.max_texture_dimension_3d,
                    native_limits.max_texture_dimension_3d,
                ),
                .max_texture_array_layers = @min(
                    self.limits.v1.max_texture_array_layers,
                    native_limits.max_texture_array_layers,
                ),
            },
            .compatibility_mode = self.isCompatibilityMode(),
        });
        const object = try texture.resolveTexture(&self.core, &guard, handle);
        errdefer object.header.releaseUserLocked(&guard, io) catch unreachable;
        try context.initializeTexture(allocator, &guard, object);
        return object;
    }

    /// Creates a native view and retains its parent texture until release.
    pub fn createTextureView(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: struct {
            texture: *texture.Texture,
            descriptor: descriptors.TextureViewDescriptorChain,
        },
    ) OperationError!*texture.TextureView {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const parent = options.texture;
        const descriptor = options.descriptor;
        const context = try self.nativeContext();
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        try self.checkResource(&guard, parent);
        if (parent.native_y_cb_cr != null) return error.TextureFormatUnsupported;
        const info = if (descriptor.format == .undefined_)
            parent.format_info
        else
            self.formatInfo(descriptor.format) orelse return error.TextureFormatUnsupported;
        if (!info.isSupported()) return error.TextureFormatUnsupported;
        const handle = try texture.Texture.createView(
            allocator,
            io,
            &guard,
            &self.core,
            .{ .handle = @ptrCast(parent) },
            .{
                .descriptor = descriptor,
                .format_info = info,
                .compatibility_mode = self.isCompatibilityMode(),
            },
        );
        const object = try texture.resolveTextureView(&self.core, &guard, handle);
        errdefer object.header.releaseUserLocked(&guard, io) catch unreachable;
        try context.initializeTextureView(&guard, object);
        return object;
    }

    /// Maps after the buffer's actual submitted GPU uses finish, without holding object locks.
    /// Mapping failure cancels this pending generation. Device loss enters first-loss arbitration.
    /// The caller retains its buffer alias and ends a successful mapping with unmapBuffer.
    pub fn mapBuffer(
        self: *Device,
        io: std.Io,
        resource: *native_resources.Buffer,
        options: buffer.Buffer.MapBeginOptions,
    ) OperationError!void {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        {
            var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
            defer guard.unlock(io);
            try self.bindObjectsLocked(&guard, context.queue.context.allocator);
            try self.checkResource(&guard, resource);
        }
        context.mapBuffer(io, resource, options) catch |err| {
            if (err == error.DeviceLost) self.recordNativeLoss(io);
            return err;
        };
    }

    /// Uses the canonical map cell. Cancellation abandons only observation.
    /// Consume the await or cancel result once: deinit a mapped span or release its error reference.
    pub fn mapBufferAsync(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        resource: *native_resources.Buffer,
        mode: api.MapMode,
        offsets: api.Buffer.MapAsyncOffsetOptions,
    ) api.AsyncStartError!std.Io.Future(native_map_queue.NativeMapOutcome) {
        return native_map_queue.mapAsyncNative(self, allocator, io, resource, mode, offsets);
    }

    /// Ends a buffer mapping using this device's recording context.
    pub fn unmapBuffer(
        self: *Device,
        io: std.Io,
        resource: *native_resources.Buffer,
    ) OperationError!void {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        // A busy queue refuses before taking ObjectGuard, including end-buffer reentry.
        if (!context.queue_operation_mutex.tryLock()) return error.ResourceInUse;
        defer context.queue_operation_mutex.unlock(io);
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, context.queue.context.allocator);
        if (!context.accepting_operations) return error.NativeDeviceStopped;
        if (self.submitting) return error.ResourceInUse;
        try self.checkResource(&guard, resource);
        if (resource.native.staging != null) {
            try context.queue.reserveStagingUpload(context.queue.context.allocator, resource.native);
            try context.prepareRecordingRootLocked(
                context.queue.context.allocator,
                &guard,
                &self.core,
                &resource.header,
            );
        }
        const result = try resource.native.unmap(.{
            .command_buffer = context.queue.commandBuffer(),
            .pending_serial = context.queue.timeline.nextSerial(),
        });
        if (result.staging_upload) |upload|
            context.queue.adoptStagingUploadAssumeCapacity(upload);
    }

    /// Replay consumes Finished once recording begins.
    pub fn submit(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        finished: *encoding.Finished,
    ) OperationError!serial_mod.Serial {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        {
            var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
            defer guard.unlock(io);
            try self.bindObjectsLocked(&guard, allocator);
            if (!context.accepting_operations) return error.NativeDeviceStopped;
            if (self.submitting) return error.ResourceInUse;
            self.submitting = true;
        }
        errdefer {
            var guard = core.ObjectGuard.lockUncancelable(io, self.core.arena.objectList());
            defer guard.unlock(io);
            self.submitting = false;
        }
        const serial = context.submit(
            allocator,
            io,
            &self.core,
            finished,
            self.limits.v1.max_immediate_size,
            self.timestamp_quantization,
        ) catch |err| {
            if (err == error.DeviceLost) self.recordNativeLoss(io);
            return err;
        };
        var guard = core.ObjectGuard.lockUncancelable(io, self.core.arena.objectList());
        defer guard.unlock(io);
        self.pending_serial = serial;
        self.submitting = false;
        return serial;
    }

    /// Blocks for the requested queue serial. I/O is borrowed only for this call.
    pub fn wait(
        self: *Device,
        io: std.Io,
        serial: serial_mod.Serial,
    ) OperationError!void {
        try self.acquireOperation(io);
        defer self.releaseOperation(io);
        const context = try self.nativeContext();
        {
            var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
            defer guard.unlock(io);
            try self.bindObjectsLocked(&guard, context.queue.context.allocator);
        }
        const completed = context.waitSerial(io, serial) catch |err| {
            if (err == error.DeviceLost) self.recordNativeLoss(io);
            return err;
        };
        var guard = core.ObjectGuard.lockUncancelable(io, self.core.arena.objectList());
        defer guard.unlock(io);
        if (self.pending_serial) |pending| {
            if (completed >= pending) self.pending_serial = null;
        }
    }

    /// Observes the accepted queue snapshot. Cancellation does not discard submitted GPU roots.
    /// Consume the await or cancel result once, and release any owned failure reference.
    pub fn onSubmittedWorkDoneAsync(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) api.AsyncStartError!std.Io.Future(native_map_queue.NativeQueueOutcome) {
        return native_map_queue.onSubmittedWorkDoneNative(self, allocator, io);
    }

    /// Adds one owned user alias, including after explicit payload retirement.
    pub fn retain(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        resource: anytype,
    ) OperationError!void {
        try self.acquireHostOperation(io);
        defer self.releaseOperation(io);
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (resource.header.tracking != self.core.arena.objectList())
            return error.ResourceDeviceMismatch;
        try resource.header.retainUserLocked(&guard);
    }

    /// Consumes one user alias. Strong dependencies and GPU leases retain payloads.
    /// Late release touches host identity only, never retired native payload fields.
    pub fn release(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        resource: anytype,
    ) OperationError!void {
        try self.acquireHostOperation(io);
        defer self.releaseOperation(io);
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        if (resource.header.tracking != self.core.arena.objectList())
            return error.ResourceDeviceMismatch;
        try resource.header.releaseUserLocked(&guard, io);
        if (self.native) |context| {
            if (context.cleanup_error) |err| return err;
        }
    }

    /// Borrows a canonical row, including its unsupported reason. `null` means
    /// the API format has no row. The device must not move or change its table
    /// while the row is borrowed. `deinit` invalidates the pointer.
    pub fn formatInfo(self: *const Device, texture_format: api.TextureFormat) ?*const format.Format {
        const index = format.computeFormatIndex(texture_format) orelse return null;
        return &self.format_table[index];
    }

    /// `DeviceBase::GetLimits` (`:2506-2508`) and `APIGetLimits` (`:1920-1925`).
    pub fn getLimits(self: *const Device) limits.CombinedLimits {
        return self.limits;
    }

    /// `DeviceBase::HasFeature` (`:1764-1766`) and `APIHasFeature`
    /// (`:1927-1929`).
    pub fn hasFeature(self: *const Device, name: api.FeatureName) bool {
        return self.enabled_features.isEnabled(features.fromApiName(name));
    }

    /// `DeviceBase::APIGetFeatures` (`:1931-1937`).
    pub fn getFeatures(
        self: *const Device,
        out: *[features.feature_count]api.FeatureName,
    ) []const api.FeatureName {
        return self.enabled_features.toSupportedFeatures(out);
    }

    /// `DeviceBase::IsCompatibilityMode` (`Device.cpp:1840-1842`): a device is in
    /// compatibility mode when the core feature is absent from the ENABLED set.
    /// That is not a question about the adapter. `Device.cpp:1730-1732` enables
    /// the same feature for any caller that requires it, whatever level the
    /// adapter was enumerated at, and `Device.cpp:294-296` reads the effective
    /// level back off this feature rather than off the adapter. The one rule
    /// drives limit selection (`docs/10-architecture.md` "Compatibility mode"),
    /// and `init` fixes the limits up under the level this returns.
    pub fn isCompatibilityMode(self: *const Device) bool {
        return !self.hasFeature(.core_features_and_limits);
    }

    /// `DeviceBase::APISetLabel` (`:2534-2539`) and `SetLabelImpl` (`:2539`),
    /// which has an empty body upstream because the arena owns the string.
    pub fn setLabel(self: *Device, label: []const u8) void {
        self.label = label;
    }

    /// `DeviceBase::GetLabel` (`:2530-2532`).
    pub fn getLabel(self: *const Device) []const u8 {
        return self.label;
    }

    /// Pushes a scope under the same host admission and object guard as resources.
    pub fn pushErrorScope(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        filter: ErrorFilter,
    ) OperationError!void {
        try self.acquireHostOperation(io);
        defer self.releaseOperation(io);
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        try self.bindObjectsLocked(&guard, allocator);
        try self.core.pushErrorScope(allocator, &guard, coreFilterFromApi(filter));
    }

    /// The ticket owns the detached scope until taken or abandoned under its guard.
    pub fn popErrorScope(
        self: *Device,
        io: std.Io,
    ) (OperationError || error_scope.PopError)!error_scope.ScopeTicket {
        try self.acquireHostOperation(io);
        defer self.releaseOperation(io);
        var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
        defer guard.unlock(io);
        return self.core.popErrorScope(&guard);
    }

    /// Pops through the canonical scope cell. Cancellation abandons only observation.
    /// Consume the await or cancel result once with its deinit method.
    pub fn popErrorScopeAsync(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) api.AsyncStartError!std.Io.Future(native_scope_info.NativePopResult) {
        return native_scope_info.popErrorScopeAsync(self, allocator, io);
    }

    /// Consumes one owned error after successful admission and allocator preflight.
    /// Uncaptured delivery executes outside ObjectGuard and keeps this host pinned.
    pub fn handleError(
        self: *Device,
        allocator: std.mem.Allocator,
        io: std.Io,
        owned_error: core.ErrorRef,
    ) OperationError!void {
        try self.acquireHostOperation(io);
        defer self.releaseOperation(io);
        const delivery = blk: {
            var guard = try core.ObjectGuard.lock(io, self.core.arena.objectList());
            defer guard.unlock(io);
            try self.bindObjectsLocked(&guard, allocator);
            break :blk self.core.handleError(&guard, owned_error);
        };
        if (delivery) |value| {
            var uncaptured = value;
            uncaptured.dispatch(io);
        }
        if (native_async.takeDispatchError(self, io)) |err| return err;
    }

    /// `null::Device::GetOptimalBytesPerRowAlignment`
    /// (`DeviceNull.cpp:594-596`). M17 is the first reader.
    pub fn getOptimalBytesPerRowAlignment(_: *const Device) u32 {
        return 1;
    }

    /// `null::Device::GetOptimalBufferToTextureCopyOffsetAlignment`
    /// (`DeviceNull.cpp:598-600`).
    pub fn getOptimalBufferToTextureCopyOffsetAlignment(_: *const Device) u64 {
        return 1;
    }

    /// `null::Device::GetTimestampPeriodInNS` (`DeviceNull.cpp:602-604`). M19 is
    /// the first reader.
    pub fn getTimestampPeriodInNanoseconds(_: *const Device) f32 {
        return 1.0;
    }

    /// `null::Device::CanTextureLoadResolveTargetInTheSameRenderpass`
    /// (`DeviceNull.cpp:606-608`).
    pub fn canLoadAndResolveInSameRenderPass(_: *const Device) bool {
        return true;
    }
};

/// `DeviceBase::ApplyFeatures` (`Device.cpp:1723-1762`).
///
/// Three rules in order: the caller's required features, the implicit closure
/// `WGPUHelpers.cpp:454-460` publishes, then the core feature when the level is
/// core. The closure is a fixed point, so it is bounded by the edge list.
pub fn applyFeatures(
    level: FeatureLevel,
    required: []const api.FeatureName,
) features.FeaturesSet {
    var enabled: features.FeaturesSet = .{};
    // Bound: the slice the caller passed.
    for (required) |name| {
        enabled.enable(features.fromApiName(name));
    }

    // `max_pass_count` is one more than the number of edges, because the
    // upstream list is acyclic: one pass per edge suffices to reach the fixed
    // point and the extra pass is the one that finds nothing left to do.
    const max_pass_count = features.implicitly_enabled.len + 1;
    var pass_count: usize = 0;
    var changed = true;
    while (changed and pass_count < max_pass_count) : (pass_count += 1) {
        changed = false;
        inline for (features.implicitly_enabled) |edge| {
            if (enabled.isEnabled(edge[0]) and !enabled.isEnabled(edge[1])) {
                enabled.enable(edge[1]);
                changed = true;
            }
        }
    }
    // Leaving the loop with `changed` still set would mean the edge list gained
    // a cycle. Upstream makes no such check; `WGPUHelpers.cpp:462` only marks
    // where more rules go.
    std.debug.assert(!changed);

    // `Device.cpp:1755-1759`: a core adapter always supports the core feature
    // and the device enables it without the caller asking.
    if (level == .core) enabled.enable(.core_features_and_limits);

    return enabled;
}

/// `EnforceLimitSpecInvariants` (`Limits.cpp:426-459`), which `DeviceBase`'s
/// constructor calls. Two rules: the per-stage value is raised to the larger of
/// the two in-stage compat values, and outside compatibility mode the four
/// in-stage values become the per-stage values.
///
/// **The level is the effective one, not the adapter's.** `Device.cpp:294-296`
/// derives it from the enabled features and `Device.cpp:351` passes that
/// result here, so a compatibility-level device whose caller required the core
/// feature is fixed up as a core device.
///
/// **Why the core value is not the compat value.** In core, the compat columns
/// are still what the table carries — zero storage buffers in the vertex stage
/// (`Limits.cpp:96`) and four in the fragment stage (`:95`) — and this function
/// is what replaces them with the per-stage value of eight. That difference is
/// what `test/null_device.zig` asserts.
pub fn enforceLimitSpecInvariants(
    combined: *limits.CombinedLimits,
    level: FeatureLevel,
) void {
    // The caller has already refused a null block (`Device.init`), so this is a
    // statement about a value that exists.
    var compat = combined.compatibility orelse return;

    const storage_buffer_per_stage = @max(
        combined.v1.max_storage_buffers_per_shader_stage,
        @max(
            compat.max_storage_buffers_in_vertex_stage,
            compat.max_storage_buffers_in_fragment_stage,
        ),
    );
    const storage_texture_per_stage = @max(
        combined.v1.max_storage_textures_per_shader_stage,
        @max(
            compat.max_storage_textures_in_vertex_stage,
            compat.max_storage_textures_in_fragment_stage,
        ),
    );
    combined.v1.max_storage_buffers_per_shader_stage = storage_buffer_per_stage;
    combined.v1.max_storage_textures_per_shader_stage = storage_texture_per_stage;

    if (level != .compatibility) {
        compat.max_storage_buffers_in_fragment_stage = storage_buffer_per_stage;
        compat.max_storage_textures_in_fragment_stage = storage_texture_per_stage;
        compat.max_storage_buffers_in_vertex_stage = storage_buffer_per_stage;
        compat.max_storage_textures_in_vertex_stage = storage_texture_per_stage;
    }
    combined.compatibility = compat;
}
