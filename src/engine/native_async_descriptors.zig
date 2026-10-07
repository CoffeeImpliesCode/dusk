//! Owned generated pipeline inputs. Native construction is deferred to options.
//! Each descriptor has one checked backing allocation and canonical header leases.
const std = @import("std");
const api = @import("../api/root.zig");
const core = @import("../core/root.zig");
const device_module = @import("device.zig");
const Device = device_module.Device;
const native = @import("native_resources.zig");
const handles = @import("native_async_handles.zig");
const pipeline = @import("../pipeline/pipeline.zig");
const render = @import("../pipeline/pipeline_render.zig");
const layout = @import("../pipeline/layout_internal.zig");
const spirv = @import("../spirv/root.zig");

pub const PreparationError = api.AsyncStartError;
pub const DescriptorError = device_module.OperationError || error{
    InvalidEnum,
    UnsupportedExtension,
    EntryPointMissing,
    EntryPointAmbiguous,
    EntryPointStageMismatch,
    VertexStrideOutOfRange,
    VertexOffsetOutOfRange,
    AutoLayoutBindingConflict,
    AutoLayoutBindingUnsupported,
    NativeDeviceRequired,
    DualSourceBlendingNotEnabled,
};

const Storage = struct {
    allocator: std.mem.Allocator,
    bytes: []align(16) u8,
    cursor: usize = 0,

    fn take(self: *Storage, comptime T: type, count: usize) []T {
        const begin = std.mem.alignForward(usize, self.cursor, @alignOf(T));
        const end = begin + count * @sizeOf(T);
        std.debug.assert(end <= self.bytes.len);
        self.cursor = end;
        return @as([*]T, @ptrCast(@alignCast(self.bytes.ptr + begin)))[0..count];
    }
    fn copy(self: *Storage, bytes: []const u8) []const u8 {
        const result = self.take(u8, bytes.len);
        @memcpy(result, bytes);
        return result;
    }
    fn copyZ(self: *Storage, bytes: []const u8) [:0]const u8 {
        // Size.add preflights the payload and its sentinel as separate checked
        // additions. All native stage names share this owned C-string boundary.
        const result = self.take(u8, bytes.len + 1);
        @memcpy(result[0..bytes.len], bytes);
        result[bytes.len] = 0;
        return result[0..bytes.len :0];
    }
};

const Size = struct {
    bytes: usize = 0,
    fn add(self: *Size, comptime T: type, count: usize) PreparationError!void {
        const padding = (@alignOf(T) - self.bytes % @alignOf(T)) % @alignOf(T);
        self.bytes = std.math.add(usize, self.bytes, padding) catch return error.InvalidRequest;
        const amount = std.math.mul(usize, count, @sizeOf(T)) catch return error.InvalidRequest;
        self.bytes = std.math.add(usize, self.bytes, amount) catch return error.InvalidRequest;
    }
    fn allocate(self: Size, allocator: std.mem.Allocator) PreparationError!Storage {
        return .{ .allocator = allocator, .bytes = try allocator.alignedAlloc(u8, .@"16", self.bytes) };
    }
};

fn checkedSlice(comptime T: type, count: usize, optional: ?[]const T) PreparationError![]const T {
    _ = std.math.mul(usize, count, @sizeOf(T)) catch return error.InvalidRequest;
    const values = optional orelse {
        if (count != 0) return error.InvalidRequest;
        return &.{};
    };
    if (count > values.len) return error.InvalidRequest;
    return values[0..count];
}

fn startError(err: anyerror) PreparationError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.ReferenceCountOverflow => error.ReferenceCountOverflow,
        error.AllocatorMismatch => error.InvalidRequest,
        error.DeviceNotAlive, error.DeviceDeinitialized, error.NativeDeviceStopped => error.OwnerStopped,
        else => error.InvalidOwner,
    };
}

const Dependencies = struct {
    device: *Device,
    layout_owner: ?*native.PipelineLayout = null,
    temporary_layout: bool = false,
    modules: [2]?*native.ShaderModule = .{ null, null },
    module_count: usize = 0,

    fn retainModule(self: *Dependencies, guard: *const core.ObjectGuard, value: api.ShaderModule) PreparationError!*native.ShaderModule {
        const header = try handles.resourceHeader(api.ShaderModule, value, .shader_module);
        handles.validateResourceLocked(self.device, guard, header, .shader_module) catch |err| return startError(err);
        header.retainLeaseLocked(guard) catch |err| return startError(err);
        const module: *native.ShaderModule = @fieldParentPtr("header", header);
        self.modules[self.module_count] = module;
        self.module_count += 1;
        return module;
    }
    fn retainLayout(self: *Dependencies, guard: *const core.ObjectGuard, value: ?api.PipelineLayout) PreparationError!void {
        const handle = value orelse return;
        const header = try handles.resourceHeader(api.PipelineLayout, handle, .pipeline_layout);
        handles.validateResourceLocked(self.device, guard, header, .pipeline_layout) catch |err| return startError(err);
        header.retainLeaseLocked(guard) catch |err| return startError(err);
        self.layout_owner = @fieldParentPtr("header", header);
    }
    fn releaseLocked(self: *Dependencies, guard: *const core.ObjectGuard, io: std.Io) void {
        if (self.layout_owner) |owner| {
            if (self.temporary_layout) owner.header.releaseUserLocked(guard, io) catch unreachable else owner.header.releaseLeaseLocked(guard, io);
        }
        for (self.modules[0..self.module_count]) |module| module.?.header.releaseLeaseLocked(guard, io);
        self.layout_owner = null;
        self.modules = .{ null, null };
        self.module_count = 0;
    }
    fn resolveLayout(self: *Dependencies, allocator: std.mem.Allocator, io: std.Io, device: *Device, stages: []const native.StageOptions) DescriptorError!*native.PipelineLayout {
        if (device != self.device) return error.ResourceDeviceMismatch;
        {
            var guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
            defer guard.unlock(io);
            try device.core.arena.checkAllocator(&guard, allocator);
        }
        if (self.layout_owner) |owner| return owner;
        const owner = try autoLayout(allocator, io, device, stages);
        self.layout_owner = owner;
        self.temporary_layout = true;
        return owner;
    }
};

const StagePlan = struct {
    module: *native.ShaderModule,
    entry: []const u8,
    constants: []const api.descriptors.ConstantEntryChain,
    stage: pipeline.Stage,

    fn prepare(dependencies: *Dependencies, guard: *const core.ObjectGuard, module_handle: api.ShaderModule, entry: ?[]const u8, count: usize, constants: ?[]const api.descriptors.ConstantEntryChain, stage: pipeline.Stage, semantic: *?DescriptorError) PreparationError!StagePlan {
        const values = try checkedSlice(api.descriptors.ConstantEntryChain, count, constants);
        const module = try dependencies.retainModule(guard, module_handle);
        const resolved = resolveEntry(module, entry, stage) catch |err| blk: {
            semantic.* = semantic.* orelse err;
            break :blk entry orelse "";
        };
        return .{ .module = module, .entry = resolved, .constants = values, .stage = stage };
    }
    fn size(self: StagePlan, total: *Size) PreparationError!void {
        try total.add(u8, self.entry.len);
        try total.add(u8, 1);
        try total.add(api.ConstantEntry, self.constants.len);
        for (self.constants) |constant| try total.add(u8, constant.key.len);
    }
    fn copy(self: StagePlan, storage: *Storage) native.StageOptions {
        const entry = storage.copyZ(self.entry);
        const constants = storage.take(api.ConstantEntry, self.constants.len);
        for (self.constants, constants) |source, *target| target.* = .{ .key = storage.copy(source.key), .value = source.value };
        return .{ .module = self.module, .entry_point = entry, .stage = self.stage, .constants = constants };
    }
};

fn resolveEntry(module: *const native.ShaderModule, requested: ?[]const u8, stage: pipeline.Stage) DescriptorError![]const u8 {
    const model: spirv.ExecutionModel = switch (stage) {
        .compute => .gl_compute,
        .vertex => .vertex,
        .fragment => .fragment,
    };
    if (requested) |name| {
        const entry = module.native.findEntryPoint(name) orelse return error.EntryPointMissing;
        if (entry.execution_model != model) return error.EntryPointStageMismatch;
        return name;
    }
    var found: ?[]const u8 = null;
    for (module.native.entry_points) |entry| {
        if (entry.execution_model != model) continue;
        if (found != null) return error.EntryPointAmbiguous;
        found = entry.name;
    }
    return found orelse error.EntryPointMissing;
}

pub const OwnedCompute = struct {
    dependencies: Dependencies,
    storage: Storage,
    label: []const u8,
    compute: native.StageOptions,
    semantic_descriptor_error: ?DescriptorError,

    pub fn prepare(allocator: std.mem.Allocator, io: std.Io, device: *Device, chain: *const api.descriptors.ComputePipelineDescriptorChain) PreparationError!OwnedCompute {
        device.acquireOperation(io) catch |err| return startError(err);
        defer device.releaseOperation(io);
        var guard = core.ObjectGuard.lock(io, device.core.arena.objectList()) catch |err| return startError(err);
        defer guard.unlock(io);
        device.core.arena.checkAllocator(&guard, allocator) catch |err| return startError(err);
        var dependencies: Dependencies = .{ .device = device };
        errdefer dependencies.releaseLocked(&guard, io);
        try dependencies.retainLayout(&guard, chain.layout);
        var semantic: ?DescriptorError = null;
        const plan = try StagePlan.prepare(&dependencies, &guard, chain.compute.module, chain.compute.entry_point, chain.compute.constant_count, chain.compute.constants, .compute, &semantic);
        var size: Size = .{};
        const label = chain.label orelse "";
        try size.add(u8, label.len);
        try plan.size(&size);
        var storage = try size.allocate(allocator);
        const copied_label = storage.copy(label);
        const compute = plan.copy(&storage);
        return .{ .dependencies = dependencies, .storage = storage, .label = copied_label, .compute = compute, .semantic_descriptor_error = semantic };
    }
    pub fn options(self: *OwnedCompute, allocator: std.mem.Allocator, io: std.Io, device: *Device) DescriptorError!native.ComputePipelineDescriptor {
        if (self.semantic_descriptor_error) |err| return err;
        return .{ .label = self.label, .layout = try self.dependencies.resolveLayout(allocator, io, device, &.{self.compute}), .compute = self.compute };
    }
    pub fn deinit(self: *OwnedCompute, io: std.Io) void {
        var guard = core.ObjectGuard.lockUncancelable(io, self.dependencies.device.core.arena.objectList());
        self.dependencies.releaseLocked(&guard, io);
        guard.unlock(io);
        self.storage.allocator.free(self.storage.bytes);
        self.* = undefined;
    }
};

pub const OwnedRender = struct {
    dependencies: Dependencies,
    storage: Storage,
    label: []const u8,
    vertex: native.StageOptions,
    fragment: ?native.StageOptions,
    vertex_buffers: []const pipeline.VertexBufferLayout,
    vertex_attributes: []const pipeline.VertexAttributeLayout,
    primitive: pipeline.PrimitiveState,
    depth_stencil: ?native.DepthStencilState,
    multisample: pipeline.MultisampleState,
    color_targets: []const native.ColorTargetState,
    semantic_descriptor_error: ?DescriptorError,

    pub fn prepare(allocator: std.mem.Allocator, io: std.Io, device: *Device, chain: *const api.descriptors.RenderPipelineDescriptorChain) PreparationError!OwnedRender {
        // Count/provenance failures are startup refusals, not asynchronous validation.
        const buffers = try checkedSlice(api.descriptors.VertexBufferLayoutChain, chain.vertex.buffer_count, chain.vertex.buffers);
        var attribute_count: usize = 0;
        for (buffers) |buffer| {
            const attributes = try checkedSlice(api.descriptors.VertexAttributeChain, buffer.attribute_count, buffer.attributes);
            attribute_count = std.math.add(usize, attribute_count, attributes.len) catch return error.InvalidRequest;
        }
        const targets = if (chain.fragment) |fragment| try checkedSlice(api.descriptors.ColorTargetStateChain, fragment.target_count, fragment.targets) else &.{};
        device.acquireOperation(io) catch |err| return startError(err);
        defer device.releaseOperation(io);
        var guard = core.ObjectGuard.lock(io, device.core.arena.objectList()) catch |err| return startError(err);
        defer guard.unlock(io);
        device.core.arena.checkAllocator(&guard, allocator) catch |err| return startError(err);
        var dependencies: Dependencies = .{ .device = device };
        errdefer dependencies.releaseLocked(&guard, io);
        try dependencies.retainLayout(&guard, chain.layout);
        var semantic: ?DescriptorError = null;
        const vertex_plan = try StagePlan.prepare(&dependencies, &guard, chain.vertex.module, chain.vertex.entry_point, chain.vertex.constant_count, chain.vertex.constants, .vertex, &semantic);
        const fragment_plan: ?StagePlan = if (chain.fragment) |fragment| try StagePlan.prepare(&dependencies, &guard, fragment.module, fragment.entry_point, fragment.constant_count, fragment.constants, .fragment, &semantic) else null;
        var size: Size = .{};
        const label = chain.label orelse "";
        try size.add(u8, label.len);
        try vertex_plan.size(&size);
        if (fragment_plan) |plan| try plan.size(&size);
        try size.add(pipeline.VertexBufferLayout, buffers.len);
        try size.add(pipeline.VertexAttributeLayout, attribute_count);
        try size.add(native.ColorTargetState, targets.len);
        var storage = try size.allocate(allocator);
        errdefer allocator.free(storage.bytes);
        const copied_label = storage.copy(label);
        const vertex = vertex_plan.copy(&storage);
        const fragment: ?native.StageOptions = if (fragment_plan) |plan| plan.copy(&storage) else null;
        const copied_buffers = storage.take(pipeline.VertexBufferLayout, buffers.len);
        const copied_attributes = storage.take(pipeline.VertexAttributeLayout, attribute_count);
        const copied_targets = storage.take(native.ColorTargetState, targets.len);
        var attribute_index: usize = 0;
        for (buffers, copied_buffers, 0..) |source, *target, slot| {
            target.* = .{
                .array_stride = std.math.cast(u32, source.array_stride) orelse blk: {
                    semantic = semantic orelse error.VertexStrideOutOfRange;
                    break :blk 0;
                },
                .step_mode = stepMode(source.step_mode) catch |err| blk: {
                    semantic = semantic orelse err;
                    break :blk .vertex;
                },
            };
            for ((try checkedSlice(api.descriptors.VertexAttributeChain, source.attribute_count, source.attributes))) |attribute| {
                copied_attributes[attribute_index] = .{
                    .shader_location = attribute.shader_location,
                    .input_slot = std.math.cast(u32, slot) orelse blk: {
                        semantic = semantic orelse error.VertexStrideOutOfRange;
                        break :blk 0;
                    },
                    .offset = std.math.cast(u32, attribute.offset) orelse blk: {
                        semantic = semantic orelse error.VertexOffsetOutOfRange;
                        break :blk 0;
                    },
                    .format = vertexFormat(attribute.format),
                };
                attribute_index += 1;
            }
        }
        for (targets, copied_targets) |source, *target| {
            if (source.color_target_state_expand_resolve_texture_dawn != null) semantic = semantic orelse error.UnsupportedExtension;
            target.* = colorTarget(source) catch |err| blk: {
                semantic = semantic orelse err;
                break :blk .{ .format = .undefined_ };
            };
            if (target.blend) |blend| {
                if (usesDualSource(blend)) {
                    const native_enabled = if (device.native) |context|
                        context.native_device.enabled_features.dualSrcBlend != 0
                    else
                        false;
                    if (!device.hasFeature(.dual_source_blending) or !native_enabled) {
                        semantic = semantic orelse error.DualSourceBlendingNotEnabled;
                    }
                }
            }
        }
        const primitive = primitiveState(chain.primitive) catch |err| blk: {
            semantic = semantic orelse err;
            break :blk pipeline.PrimitiveState{};
        };
        const depth_stencil: ?native.DepthStencilState = if (chain.depth_stencil) |source| depthStencil(source.*) catch |err| blk: {
            semantic = semantic orelse err;
            break :blk null;
        } else null;
        return .{
            .dependencies = dependencies,
            .storage = storage,
            .label = copied_label,
            .vertex = vertex,
            .fragment = fragment,
            .vertex_buffers = copied_buffers,
            .vertex_attributes = copied_attributes,
            .primitive = primitive,
            .depth_stencil = depth_stencil,
            .multisample = .{ .count = chain.multisample.count, .mask = chain.multisample.mask, .alpha_to_coverage = chain.multisample.alpha_to_coverage_enabled },
            .color_targets = copied_targets,
            .semantic_descriptor_error = semantic,
        };
    }
    pub fn options(self: *OwnedRender, allocator: std.mem.Allocator, io: std.Io, device: *Device) DescriptorError!native.RenderPipelineDescriptor {
        if (self.semantic_descriptor_error) |err| return err;
        const stages = [_]native.StageOptions{ self.vertex, self.fragment orelse self.vertex };
        return .{
            .label = self.label,
            .layout = try self.dependencies.resolveLayout(allocator, io, device, stages[0..if (self.fragment == null) @as(usize, 1) else 2]),
            .vertex = self.vertex,
            .fragment = self.fragment,
            .vertex_buffers = self.vertex_buffers,
            .vertex_attributes = self.vertex_attributes,
            .primitive = self.primitive,
            .depth_stencil = self.depth_stencil,
            .multisample = self.multisample,
            .color_targets = self.color_targets,
        };
    }
    pub fn deinit(self: *OwnedRender, io: std.Io) void {
        var guard = core.ObjectGuard.lockUncancelable(io, self.dependencies.device.core.arena.objectList());
        self.dependencies.releaseLocked(&guard, io);
        guard.unlock(io);
        self.storage.allocator.free(self.storage.bytes);
        self.* = undefined;
    }
};

fn stepMode(value: api.VertexStepMode) DescriptorError!render.StepMode {
    return switch (value) {
        .vertex => .vertex,
        .instance => .instance,
        .undefined_ => error.InvalidEnum,
    };
}

fn vertexFormat(value: api.VertexFormat) render.VertexFormat {
    return switch (value) {
        .uint8 => .uint8,
        .uint8x2 => .uint8x2,
        .uint8x4 => .uint8x4,
        .sint8 => .sint8,
        .sint8x2 => .sint8x2,
        .sint8x4 => .sint8x4,
        .unorm8 => .unorm8,
        .unorm8x2 => .unorm8x2,
        .unorm8x4 => .unorm8x4,
        .snorm8 => .snorm8,
        .snorm8x2 => .snorm8x2,
        .snorm8x4 => .snorm8x4,
        .uint16 => .uint16,
        .uint16x2 => .uint16x2,
        .uint16x4 => .uint16x4,
        .sint16 => .sint16,
        .sint16x2 => .sint16x2,
        .sint16x4 => .sint16x4,
        .unorm16 => .unorm16,
        .unorm16x2 => .unorm16x2,
        .unorm16x4 => .unorm16x4,
        .snorm16 => .snorm16,
        .snorm16x2 => .snorm16x2,
        .snorm16x4 => .snorm16x4,
        .float16 => .float16,
        .float16x2 => .float16x2,
        .float16x4 => .float16x4,
        .float32 => .float32,
        .float32x2 => .float32x2,
        .float32x3 => .float32x3,
        .float32x4 => .float32x4,
        .uint32 => .uint32,
        .uint32x2 => .uint32x2,
        .uint32x3 => .uint32x3,
        .uint32x4 => .uint32x4,
        .sint32 => .sint32,
        .sint32x2 => .sint32x2,
        .sint32x3 => .sint32x3,
        .sint32x4 => .sint32x4,
        .unorm_10_10_10_2 => .unorm10_10_10_2,
        .unorm8x4_bgra => .unorm8x4_bgra,
        .snorm_10_10_10_2 => .snorm10_10_10_2,
    };
}

fn primitiveState(value: api.descriptors.PrimitiveStateChain) DescriptorError!pipeline.PrimitiveState {
    return .{
        .topology = switch (value.topology) {
            .point_list => .point_list,
            .line_list => .line_list,
            .line_strip => .line_strip,
            .triangle_list => .triangle_list,
            .triangle_strip => .triangle_strip,
            .undefined_ => return error.InvalidEnum,
        },
        .strip_index_format = switch (value.strip_index_format) {
            .undefined_ => null,
            .uint16 => .uint16,
            .uint32 => .uint32,
        },
        .front_face = switch (value.front_face) {
            .ccw => .counter_clockwise,
            .cw => .clockwise,
            .undefined_ => return error.InvalidEnum,
        },
        .cull_mode = switch (value.cull_mode) {
            .none => .none,
            .front => .front,
            .back => .back,
            .undefined_ => return error.InvalidEnum,
        },
        .unclipped_depth = value.unclipped_depth,
    };
}

fn compare(value: api.CompareFunction) DescriptorError!render.CompareFunction {
    return switch (value) {
        .undefined_ => error.InvalidEnum,
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_equal => .less_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_equal => .greater_equal,
        .always => .always,
    };
}

fn stencilOperation(value: api.StencilOperation) DescriptorError!render.StencilOperation {
    return switch (value) {
        .undefined_ => error.InvalidEnum,
        .keep => .keep,
        .zero => .zero,
        .replace => .replace,
        .invert => .invert,
        .increment_clamp => .increment_and_clamp,
        .decrement_clamp => .decrement_and_clamp,
        .increment_wrap => .increment_and_wrap,
        .decrement_wrap => .decrement_and_wrap,
    };
}

fn stencilFace(value: api.StencilFaceState) DescriptorError!render.StencilFaceState {
    return .{ .compare = try compare(value.compare), .fail_op = try stencilOperation(value.fail_op), .depth_fail_op = try stencilOperation(value.depth_fail_op), .pass_op = try stencilOperation(value.pass_op) };
}

fn depthStencil(value: api.descriptors.DepthStencilStateChain) DescriptorError!native.DepthStencilState {
    const has_depth = switch (value.format) {
        .depth16_unorm, .depth24_plus, .depth24_plus_stencil8, .depth32_float, .depth32_float_stencil8 => true,
        else => false,
    };
    const depth_write = switch (value.depth_write_enabled) {
        .false_ => false,
        .true_ => if (has_depth) true else return error.InvalidEnum,
        .undefined_ => if (!has_depth) false else return error.InvalidEnum,
    };
    const depth_compare: render.CompareFunction = if (value.depth_compare == .undefined_)
        (if (depth_write) return error.DepthCompareUndefinedWithDepthWrite else .always)
    else
        try compare(value.depth_compare);
    if (!has_depth and depth_compare != .always) return error.InvalidEnum;
    return .{
        .format = value.format,
        .depth_write_enabled = depth_write,
        .depth_compare = depth_compare,
        .stencil_front = try stencilFace(value.stencil_front),
        .stencil_back = try stencilFace(value.stencil_back),
        .stencil_read_mask = value.stencil_read_mask,
        .stencil_write_mask = value.stencil_write_mask,
        .depth_bias = value.depth_bias,
        .depth_bias_slope_scale = value.depth_bias_slope_scale,
        .depth_bias_clamp = value.depth_bias_clamp,
    };
}

fn blendFactor(value: api.BlendFactor) DescriptorError!render.BlendFactor {
    return switch (value) {
        .undefined_ => error.InvalidEnum,
        .zero => .zero,
        .one => .one,
        .src => .src,
        .one_minus_src => .one_minus_src,
        .src_alpha => .src_alpha,
        .one_minus_src_alpha => .one_minus_src_alpha,
        .dst => .dst,
        .one_minus_dst => .one_minus_dst,
        .dst_alpha => .dst_alpha,
        .one_minus_dst_alpha => .one_minus_dst_alpha,
        .src_alpha_saturated => .src_alpha_saturate,
        .constant => .constant,
        .one_minus_constant => .one_minus_constant,
        .src1 => .src1,
        .one_minus_src1 => .one_minus_src1,
        .src1_alpha => .src1_alpha,
        .one_minus_src1_alpha => .one_minus_src1_alpha,
    };
}

fn blendComponent(value: api.BlendComponent) DescriptorError!render.BlendComponent {
    return .{ .src_factor = try blendFactor(value.src_factor), .dst_factor = try blendFactor(value.dst_factor), .operation = switch (value.operation) {
        .undefined_ => return error.InvalidEnum,
        .add => .add,
        .subtract => .subtract,
        .reverse_subtract => .reverse_subtract,
        .min => .min,
        .max => .max,
    } };
}

fn colorTarget(value: api.descriptors.ColorTargetStateChain) DescriptorError!native.ColorTargetState {
    return .{ .format = value.format, .write_mask = value.write_mask.toFlags(), .blend = if (value.blend) |blend| .{ .color = try blendComponent(blend.color), .alpha = try blendComponent(blend.alpha) } else null };
}

const AutoEntry = struct { set: u32, entry: layout.Entry };

fn autoLayout(allocator: std.mem.Allocator, io: std.Io, device: *Device, stages: []const native.StageOptions) DescriptorError!*native.PipelineLayout {
    var entries: std.ArrayList(AutoEntry) = .empty;
    defer entries.deinit(allocator);
    var group_count: usize = 0;
    {
        var guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
        defer guard.unlock(io);
        try device.core.arena.checkAllocator(&guard, allocator);
        for (stages) |stage| {
            try stage.validateModuleLocked(&guard);
            const entry_point = stage.module.native.findEntryPoint(stage.entry_point) orelse return error.EntryPointMissing;
            const visibility: layout.ShaderStages = switch (stage.stage) {
                .compute => .{ .compute = true },
                .vertex => .{ .vertex = true },
                .fragment => .{ .fragment = true },
            };
            for (entry_point.layout.bindings) |binding| {
                if (binding.set >= layout.max_bind_groups) return error.BindGroupCountAboveLimit;
                group_count = @max(group_count, @as(usize, binding.set) + 1);
                const derived = try deriveBinding(binding);
                var merged = false;
                for (entries.items) |*existing| {
                    if (existing.set != binding.set or existing.entry.binding_number != binding.binding) continue;
                    if (existing.entry.array_size != binding.array_size or
                        !std.meta.eql(existing.entry.kind, derived))
                        return error.AutoLayoutBindingConflict;
                    existing.entry.visibility = @bitCast(existing.entry.visibility.bits() | visibility.bits());
                    merged = true;
                    break;
                }
                if (!merged) try entries.append(allocator, .{ .set = binding.set, .entry = .{
                    .binding_number = binding.binding,
                    .visibility = visibility,
                    .array_size = binding.array_size,
                    .kind = derived,
                } });
            }
        }
    }
    // A single token separates this actual auto graph from explicit layouts and
    // every other auto graph, including its empty groups and final layout.
    try device.acquireOperation(io);
    defer device.releaseOperation(io);
    var guard = try core.ObjectGuard.lock(io, device.core.arena.objectList());
    defer guard.unlock(io);
    try device.bindObjectsLocked(&guard, allocator);
    const context = device.native orelse return error.NativeDeviceRequired;
    if (!context.accepting_operations) return error.NativeDeviceStopped;
    const token = try context.resource_store.?.mintCompatibilityToken(&guard);
    const compat = &device.limits.compatibility.?;
    const validation: layout.ValidateOptions = .{
        .max_storage_buffers_in_vertex_stage = compat.max_storage_buffers_in_vertex_stage,
        .max_storage_buffers_in_fragment_stage = compat.max_storage_buffers_in_fragment_stage,
    };
    var groups: [layout.max_bind_groups]*native.BindGroupLayout = undefined;
    var created: usize = 0;
    defer for (groups[0..created]) |group|
        group.header.releaseUserLocked(&guard, io) catch unreachable;
    var group_entries: std.ArrayList(layout.Entry) = .empty;
    defer group_entries.deinit(allocator);
    for (0..group_count) |set| {
        group_entries.clearRetainingCapacity();
        for (entries.items) |entry| if (entry.set == set) {
            try group_entries.append(allocator, entry.entry);
        };
        groups[created] = try native.createBindGroupLayout(
            allocator,
            io,
            &guard,
            &device.core.arena,
            context.resourceDevice(),
            .{ .descriptor = .{ .entries = group_entries.items }, .validation = validation, .compatibility_token = token },
        );
        created += 1;
    }
    const owner = try native.createPipelineLayout(
        allocator,
        io,
        &guard,
        &device.core.arena,
        context.resourceDevice(),
        .{ .groups = groups[0..created], .compatibility_token = token },
    );
    errdefer owner.header.releaseUserLocked(&guard, io) catch unreachable;
    for (stages) |stage| {
        _ = try stage.input(&guard, owner);
    }
    return owner;
}

fn deriveBinding(binding: spirv.Resource) DescriptorError!layout.EntryKind {
    if (binding.combined_image_sampler) return error.AutoLayoutBindingUnsupported;
    switch (binding.kind) {
        .uniform_buffer => return .{ .buffer = .{
            .binding_type = .uniform,
            .has_dynamic_offset = false,
            .min_binding_size = 0,
        } },
        .storage_buffer => return .{ .buffer = .{
            .binding_type = if (binding.buffer_read_only) .read_only_storage else .storage,
            .has_dynamic_offset = false,
            .min_binding_size = 0,
        } },
        .sampler => return .{ .sampler = .{ .binding_type = .filtering } },
        .sampled_buffer, .storage_texture_buffer, .input_attachment => return error.AutoLayoutBindingUnsupported,
        .sampled_texture, .storage_texture => {},
    }
    if (binding.kind == .sampled_texture and binding.image_sampled == 0)
        return error.AutoLayoutBindingUnsupported;
    const dimension: layout.TextureViewDimension = switch (binding.image_dimension orelse return error.AutoLayoutBindingUnsupported) {
        .one_dimensional => if (!binding.image_arrayed) .one_d else return error.AutoLayoutBindingUnsupported,
        .two_dimensional => if (binding.image_arrayed) .two_d_array else .two_d,
        .three_dimensional => if (!binding.image_arrayed) .three_d else return error.AutoLayoutBindingUnsupported,
        .cube => if (binding.image_arrayed) .cube_array else .cube,
        .rectangle, .buffer, .subpass_data, .tile_image_data_ext => return error.AutoLayoutBindingUnsupported,
    };
    if (binding.kind == .storage_texture) {
        if (binding.storage_read_only and binding.storage_write_only)
            return error.AutoLayoutBindingConflict;
        if (binding.image_format == null or binding.image_format.? == 0)
            return error.AutoLayoutBindingUnsupported;
        return .{ .storage_texture = .{
            .access = if (binding.storage_read_only) .read_only else if (binding.storage_write_only) .write_only else .read_write,
            .view_dimension = dimension,
        } };
    }
    if (binding.image_depth_mode == 2) return error.AutoLayoutBindingUnsupported;
    const sample_type: layout.TextureSampleType = if (binding.image_depth) .depth else switch (binding.sampled_scalar orelse return error.AutoLayoutBindingUnsupported) {
        .float => if (binding.image_multisampled) .float_unfilterable else .float_filterable,
        .signed_integer => .sint,
        .unsigned_integer => .uint,
        .boolean => return error.AutoLayoutBindingUnsupported,
    };
    return .{ .sampled_texture = .{
        .sample_type = sample_type,
        .view_dimension = dimension,
        .multisampled = binding.image_multisampled,
    } };
}

fn dualSourceFactor(value: render.BlendFactor) bool {
    return switch (value) {
        .src1, .one_minus_src1, .src1_alpha, .one_minus_src1_alpha => true,
        .zero, .one, .src, .one_minus_src, .src_alpha, .one_minus_src_alpha, .dst, .one_minus_dst, .dst_alpha, .one_minus_dst_alpha, .constant, .one_minus_constant, .src_alpha_saturate => false,
    };
}

fn usesDualSource(value: render.BlendState) bool {
    return dualSourceFactor(value.color.src_factor) or
        dualSourceFactor(value.color.dst_factor) or
        dualSourceFactor(value.alpha.src_factor) or
        dualSourceFactor(value.alpha.dst_factor);
}

test "public auto layout rejects an actual combined image sampler before derivation" {
    const definitions = @import("native_kernel_definitions.zig");
    const stage = definitions.external_ycbcr_fragment;
    const reflected = try spirv.reflect(std.testing.allocator, stage.words);
    defer reflected.deinit();
    const entry = reflected.findEntryPoint(stage.entry_point) orelse return error.EntryPointMissing;
    var combined_count: usize = 0;
    for (entry.resources) |binding| {
        if (!binding.combined_image_sampler) continue;
        combined_count += 1;
        try std.testing.expectError(error.AutoLayoutBindingUnsupported, deriveBinding(binding));
    }
    try std.testing.expectEqual(@as(usize, 1), combined_count);
}

test "public auto layout derives only public storage permissions" {
    inline for (.{ false, true }) |read_only| {
        const derived = try deriveBinding(.{
            .kind = .storage_buffer,
            .set = 0,
            .binding = 0,
            .buffer_read_only = read_only,
        });
        try std.testing.expectEqual(
            if (read_only) layout.BufferBindingType.read_only_storage else .storage,
            derived.buffer.binding_type,
        );
    }
}

test "public auto layout keeps declared float and depth sampled types distinct" {
    var binding: spirv.Resource = .{
        .kind = .sampled_texture,
        .set = 0,
        .binding = 0,
        .image_dimension = .two_dimensional,
        .sampled_scalar = .{ .float = 32 },
        .image_depth_mode = 0,
        .image_sampled = 1,
    };
    const ordinary = try deriveBinding(binding);
    try std.testing.expectEqual(layout.TextureSampleType.float_filterable, ordinary.sampled_texture.sample_type);
    binding.image_depth = true;
    binding.image_depth_mode = 1;
    const depth = try deriveBinding(binding);
    try std.testing.expectEqual(layout.TextureSampleType.depth, depth.sampled_texture.sample_type);
}
