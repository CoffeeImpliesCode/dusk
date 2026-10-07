//! Validated compute-pass recording. Vulkan execution belongs to `engine`.
//! The caller records the begin payload, then constructs and ends one encoder.
const std = @import("std");
const commands = @import("commands.zig");
const constants = @import("constants.zig");
const encoding_context = @import("encoding_context.zig");
const errors = @import("errors.zig");
const programmable = @import("programmable_encoder.zig");
const state_tracker = @import("state_tracker.zig");
const usage = @import("usage.zig");
const query = @import("query.zig");
const core = @import("../core/root.zig");

fn computeTestDevice(mutex: *std.Io.Mutex) core.Device {
    return core.Device.init(std.testing.allocator, .{
        .object_mutex = mutex,
        .uncaptured_context = mutex,
        .uncaptured_callback = unexpectedComputeError,
    });
}

fn unexpectedComputeError(
    _: std.mem.Allocator,
    _: std.Io,
    _: *anyopaque,
    _: core.ErrorView,
) void {
    @panic("unexpected uncaptured error");
}

test "compute dispatch requires pipeline and obeys each axis limit" {
    var mutex: std.Io.Mutex = .init;
    var device = computeTestDevice(&mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(std.testing.allocator, device.borrow(), 4096, false);
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var encoder = ComputeEncoder.init(std.testing.allocator, &context, .{
        .max_workgroups_per_dimension = 4,
    });
    defer encoder.deinit();
    try std.testing.expectError(error.MissingPipeline, encoder.dispatch(.{ .x = 1 }));
    var pipeline: u8 = 0;
    try encoder.setPipeline(.{ .pipeline = &pipeline });
    try std.testing.expectError(error.DispatchWorkgroupCount, encoder.dispatch(.{ .x = 5 }));
    try std.testing.expectError(error.DispatchWorkgroupCount, encoder.dispatch(.{ .y = 5 }));
    try std.testing.expectError(error.DispatchWorkgroupCount, encoder.dispatch(.{ .z = 5 }));
    try encoder.dispatch(.{ .x = 0 });
    try encoder.end();
    try std.testing.expectEqual(@as(usize, 1), context.compute_pass_usages.items.len);
    try std.testing.expectEqual(@as(usize, 1), context.compute_pass_usages.items[0].dispatch_usages.items.len);
    try std.testing.expectError(error.PassEnded, encoder.setImmediates(.{ .offset = 0, .data = &.{} }));
}

test "compute usages keep unused references and isolate dispatch scopes" {
    var mutex: std.Io.Mutex = .init;
    var device = computeTestDevice(&mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(std.testing.allocator, device.borrow(), 4096, false);
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var encoder = ComputeEncoder.init(std.testing.allocator, &context, .{});
    defer encoder.deinit();
    var pipeline: u8 = 0;
    var group: u8 = 0;
    var buffer: u8 = 0;
    var unused_buffer: u8 = 0;
    try encoder.setPipeline(.{ .pipeline = &pipeline, .requirements = .{
        .bind_group_layout_mask = 1,
    } });
    var bindings = [_]usage.BindGroupBuffer{.{ .buffer = &buffer, .usage = 64 }};
    try encoder.setBindGroup(.{ .index = 0, .group = &group, .buffers = &bindings });
    bindings[0].usage = 128;
    try encoder.setBindGroup(.{
        .index = 1,
        .group = &group,
        .buffers = &.{.{ .buffer = &unused_buffer, .usage = 128 }},
    });
    try encoder.dispatch(.{});
    try encoder.setBindGroup(.{ .index = 0, .group = &group, .buffers = &bindings });
    try encoder.dispatch(.{});
    try encoder.end();
    const pass = &context.compute_pass_usages.items[0];
    try std.testing.expectEqual(@as(usize, 2), pass.referenced_buffers.items.len);
    try std.testing.expectEqual(@as(usize, 1), pass.dispatch_usages.items[0].buffers.items.len);
    try std.testing.expectEqual(@as(u32, 64), pass.dispatch_usages.items[0].buffer_sync_infos.items[0].usage);
    try std.testing.expectEqual(@as(u32, 128), pass.dispatch_usages.items[1].buffer_sync_infos.items[0].usage);
}

test "compute indirect bounds debug balance and timestamps reject invalid inputs" {
    var mutex: std.Io.Mutex = .init;
    var device = computeTestDevice(&mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(std.testing.allocator, device.borrow(), 4096, false);
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var encoder = ComputeEncoder.init(std.testing.allocator, &context, .{
        .timestamp_query_enabled = true,
    });
    defer encoder.deinit();
    var resource: u8 = 0;
    try encoder.setPipeline(.{ .pipeline = &resource });
    try std.testing.expectError(error.IndirectOffsetUnaligned, encoder.dispatchIndirect(.{
        .buffer = &resource,
        .buffer_size = 16,
        .offset = 1,
        .usage = 256,
    }));
    try std.testing.expectError(error.IndirectBufferTooSmall, encoder.dispatchIndirect(.{
        .buffer = &resource,
        .buffer_size = 16,
        .offset = 8,
        .usage = 256,
    }));
    try encoder.dispatchIndirect(.{
        .buffer = &resource,
        .buffer_size = 16,
        .offset = 4,
        .usage = 256,
    });
    try std.testing.expectError(error.TimestampIndexOutOfRange, encoder.writeTimestamp(.{
        .query_set = &resource,
        .query_count = 1,
        .query_index = 1,
    }));
    try encoder.writeTimestamp(.{ .query_set = &resource, .query_count = 1, .query_index = 0 });
    try std.testing.expectError(error.DebugGroupUnbalanced, encoder.popDebugGroup());
    try encoder.pushDebugGroup("compute");
    try std.testing.expectError(error.DebugGroupUnbalanced, encoder.end());
    try encoder.popDebugGroup();
    try encoder.end();
    try std.testing.expectError(error.PassEnded, encoder.end());
}

/// Compute-specific failures supplement the shared command rules.
pub const Error = errors.Error || error{
    InvalidResource,
    IndirectOffsetUnaligned,
    IndirectUsageMissing,
};

/// Device limits and features, resolved before the pass starts.
pub const InitOptions = struct {
    /// Defaults to the WebGPU baseline. Supply the actual device limit when larger.
    max_workgroups_per_dimension: u32 = 65535,
    /// Defaults to disabled. Enable only when the device exposes timestamp queries.
    timestamp_query_enabled: bool = false,
};

/// Pipeline requirements are resolved by the engine, not by the command stream.
pub const PipelineOptions = struct {
    pipeline: commands.Ref,
    requirements: state_tracker.PipelineRequirements = .{},
};

/// Workgroup counts. Zero on any axis records a zero-work dispatch.
pub const DispatchOptions = struct { x: u32 = 1, y: u32 = 1, z: u32 = 1 };

/// An indirect dispatch reads three consecutive u32 counts at `offset`.
pub const IndirectOptions = struct {
    buffer: commands.Ref,
    buffer_size: u64,
    offset: u64 = 0,
    /// The resolved WebGPU buffer usage bits.
    usage: u32,
};

/// Query metadata comes from the validated engine query object.
pub const TimestampOptions = struct {
    query_set: commands.Ref,
    query_index: u32,
    query_count: u32,
    query_type: query.QueryType = .timestamp,
};

const GroupResources = struct {
    buffers: []const usage.BindGroupBuffer = &.{},
    textures: []const usage.BindGroupTexture = &.{},
    external_textures: []const commands.Ref = &.{},
    texture_bindings: []const state_tracker.TextureBinding = &.{},
    resource_table: commands.Ref = null,

    fn deinit(self: *GroupResources, allocator: std.mem.Allocator) void {
        allocator.free(self.buffers);
        allocator.free(self.textures);
        allocator.free(self.external_textures);
        allocator.free(self.texture_bindings);
        self.* = .{};
    }

    fn copy(
        allocator: std.mem.Allocator,
        options: programmable.SetBindGroupOptions,
    ) std.mem.Allocator.Error!GroupResources {
        var out: GroupResources = .{};
        errdefer out.deinit(allocator);
        out.buffers = try allocator.dupe(usage.BindGroupBuffer, options.buffers);
        out.textures = try allocator.dupe(usage.BindGroupTexture, options.textures);
        out.external_textures = try allocator.dupe(commands.Ref, options.external_textures);
        out.texture_bindings = try allocator.dupe(
            state_tracker.TextureBinding,
            options.texture_bindings,
        );
        out.resource_table = options.resource_table;
        return out;
    }
};

/// A single-owner encoder. Keep its context and allocator alive through `deinit`.
/// Bind-group metadata is copied. Object references borrow the device arena.
/// End transfers usage to the context. Allocation failure invalidates the context.
pub const ComputeEncoder = struct {
    programmable: programmable.ProgrammableEncoder,
    state: state_tracker.Tracker,
    resource_usage: usage.ComputePassResourceUsageTracker,
    groups: [constants.max_bind_groups]GroupResources = @splat(.{}),
    options: InitOptions,
    initial_debug_depth: usize,

    /// Enter a pass after the parent records its validated BeginComputePassCmd.
    /// Its timestamp indices use the undefined sentinel when absent.
    /// A nonempty label follows as null-terminated data. Empty labels have no run.
    pub fn init(
        allocator: std.mem.Allocator,
        context: *encoding_context.Context,
        options: InitOptions,
    ) ComputeEncoder {
        return .{
            .programmable = programmable.ProgrammableEncoder.init(allocator, context),
            .state = state_tracker.Tracker.init(allocator, context.compatibility_mode),
            .resource_usage = usage.ComputePassResourceUsageTracker.init(allocator),
            .options = options,
            .initial_debug_depth = context.debugGroupDepth(),
        };
    }

    /// Release metadata once. This does not end an open pass.
    pub fn deinit(self: *ComputeEncoder) void {
        for (&self.groups) |*group| group.deinit(self.programmable.allocator);
        self.resource_usage.deinit();
        self.* = undefined;
    }

    fn validateOpen(self: *const ComputeEncoder) Error!void {
        if (self.programmable.ended) return error.PassEnded;
        try self.programmable.context.validateCanEncodeOn(self.programmable.id, false);
    }

    fn invalidate(self: *ComputeEncoder) void {
        self.programmable.context.status = .error_in_recording;
        self.programmable.context.current_id = encoding_context.no_encoder;
    }

    /// Set the compute pipeline and invalidate the lazy state checks.
    pub fn setPipeline(self: *ComputeEncoder, options: PipelineOptions) Error!void {
        try self.validateOpen();
        if (options.pipeline == null) return error.InvalidResource;
        errdefer self.invalidate();
        const payload = try self.programmable.context.encode(
            commands.SetComputePipelineCmd,
            self.programmable.id,
            .set_compute_pipeline,
        );
        payload.* = .{ .pipeline = options.pipeline };
        self.state.setComputePipeline(options.pipeline, options.requirements);
    }

    /// Copy group metadata and dynamic offsets. Null unsets the slot.
    pub fn setBindGroup(
        self: *ComputeEncoder,
        options: programmable.SetBindGroupOptions,
    ) Error!void {
        try self.validateOpen();
        try self.programmable.validateSetBindGroup(options);
        var owned = try GroupResources.copy(self.programmable.allocator, options);
        errdefer owned.deinit(self.programmable.allocator);
        var copied_options = options;
        copied_options.texture_bindings = owned.texture_bindings;
        errdefer self.invalidate();
        try self.programmable.setBindGroup(&self.state, .{
            .compute = &self.resource_usage,
        }, copied_options);
        self.groups[options.index].deinit(self.programmable.allocator);
        self.groups[options.index] = owned;
    }

    /// Write immediate bytes after validating their offset and size.
    pub fn setImmediates(
        self: *ComputeEncoder,
        options: programmable.SetImmediatesOptions,
    ) Error!void {
        try self.validateOpen();
        try self.programmable.validateSetImmediates(options);
        if (options.data.len % constants.immediate_element_byte_size != 0) {
            return error.ImmediateDataUnaligned;
        }
        errdefer self.invalidate();
        try self.programmable.setImmediates(&self.state, options);
    }

    /// Record a nested debug group owned by this pass.
    pub fn pushDebugGroup(self: *ComputeEncoder, label: []const u8) Error!void {
        try self.validateOpen();
        errdefer self.invalidate();
        try self.programmable.pushDebugGroup(label);
    }

    /// Pop only a group opened inside this pass.
    pub fn popDebugGroup(self: *ComputeEncoder) Error!void {
        try self.validateOpen();
        if (self.programmable.context.debugGroupDepth() <= self.initial_debug_depth) {
            return error.DebugGroupUnbalanced;
        }
        errdefer self.invalidate();
        try self.programmable.popDebugGroup();
    }

    /// Copy a marker label into the stream.
    pub fn insertDebugMarker(self: *ComputeEncoder, label: []const u8) Error!void {
        try self.validateOpen();
        errdefer self.invalidate();
        try self.programmable.insertDebugMarker(label);
    }

    /// Set the validated resource table and retain its pass reference.
    pub fn setResourceTable(self: *ComputeEncoder, table: commands.Ref) Error!void {
        try self.validateOpen();
        if (table == null) return error.InvalidResource;
        errdefer self.invalidate();
        try self.resource_usage.addReferencedResourceTable(table);
        const payload = try self.programmable.context.encode(
            commands.SetResourceTableCmd,
            self.programmable.id,
            .set_resource_table,
        );
        payload.* = .{ .table = table };
        self.state.setResourceTable(table);
    }

    /// Record one dispatch and its own synchronization scope.
    pub fn dispatch(self: *ComputeEncoder, options: DispatchOptions) Error!void {
        try self.validateOpen();
        try self.state.validateOperation(state_tracker.dispatch_aspects);
        const limit = self.options.max_workgroups_per_dimension;
        if (options.x > limit) return error.DispatchWorkgroupCount;
        if (options.y > limit) return error.DispatchWorkgroupCount;
        if (options.z > limit) return error.DispatchWorkgroupCount;
        errdefer self.invalidate();
        try self.recordDispatchUsage(null);
        const payload = try self.programmable.context.encode(
            commands.DispatchCmd,
            self.programmable.id,
            .dispatch,
        );
        payload.* = .{ .x = options.x, .y = options.y, .z = options.z };
    }

    /// Validate and record a twelve-byte indirect count range.
    pub fn dispatchIndirect(self: *ComputeEncoder, options: IndirectOptions) Error!void {
        try self.validateOpen();
        try self.state.validateOperation(state_tracker.dispatch_aspects);
        if (options.buffer == null) return error.InvalidResource;
        if (options.usage & indirect_usage_bit == 0) return error.IndirectUsageMissing;
        if (options.offset % 4 != 0) return error.IndirectOffsetUnaligned;
        if (options.offset > options.buffer_size) return error.IndirectBufferTooSmall;
        if (options.buffer_size - options.offset < 12) return error.IndirectBufferTooSmall;
        errdefer self.invalidate();
        try self.resource_usage.addReferencedBuffer(options.buffer);
        try self.recordDispatchUsage(options.buffer);
        const payload = try self.programmable.context.encode(
            commands.DispatchIndirectCmd,
            self.programmable.id,
            .dispatch_indirect,
        );
        payload.* = .{
            .indirect_buffer = options.buffer,
            .indirect_offset = options.offset,
        };
    }

    /// Record a timestamp only for a timestamp query set and an in-range index.
    pub fn writeTimestamp(self: *ComputeEncoder, options: TimestampOptions) Error!void {
        try self.validateOpen();
        if (!self.options.timestamp_query_enabled) return error.RequiredFeatureMissing;
        if (options.query_set == null) return error.InvalidResource;
        if (options.query_type != .timestamp) return error.QuerySetTypeMismatch;
        if (options.query_index >= options.query_count) return error.TimestampIndexOutOfRange;
        errdefer self.invalidate();
        const payload = try self.programmable.context.encode(
            commands.WriteTimestampCmd,
            self.programmable.id,
            .write_timestamp,
        );
        payload.* = .{ .query_set = options.query_set, .query_index = options.query_index };
    }

    /// End a balanced pass and transfer every usage list to its parent context.
    pub fn end(self: *ComputeEncoder) Error!void {
        try self.validateOpen();
        if (self.programmable.context.debugGroupDepth() != self.initial_debug_depth) {
            return error.DebugGroupUnbalanced;
        }
        errdefer self.invalidate();
        _ = try self.programmable.context.encode(
            commands.EndComputePassCmd,
            self.programmable.id,
            .end_compute_pass,
        );
        const owned_usage = self.resource_usage.usage;
        self.resource_usage.usage = usage.ComputePassResourceUsage.init(self.programmable.allocator);
        self.programmable.ended = true;
        try self.programmable.context.exitComputePass(self.programmable.id, owned_usage);
    }

    fn recordDispatchUsage(self: *ComputeEncoder, indirect_buffer: commands.Ref) Error!void {
        var scope = usage.SyncScopeUsageTracker.init(self.programmable.allocator);
        defer scope.deinit();
        const mask = self.state.pipeline_requirements.bind_group_layout_mask;
        for (&self.groups, 0..) |*group, index| {
            if (mask & (@as(u32, 1) << @intCast(index)) == 0) continue;
            for (group.buffers) |entry| {
                const slot = try scope.bufferUsedAs(entry.buffer, entry.usage);
                scope.scope.buffer_sync_infos.items[slot].shader_stages |= compute_stage_bit;
            }
            for (group.textures) |entry| {
                try scope.textureRangeUsedAs(
                    entry.texture,
                    entry.mip_level,
                    entry.array_layer,
                    entry.aspect,
                    .{
                        .usage = entry.usage,
                        .shader_stages = entry.shader_stages & compute_stage_bit,
                    },
                );
            }
            for (group.external_textures) |texture| {
                try scope.scope.external_textures.append(self.programmable.allocator, texture);
            }
        }
        if (self.state.pipeline_requirements.uses_resource_table) {
            scope.setUsedResourceTable(self.state.resource_table);
        }
        if (indirect_buffer != null) {
            _ = try scope.bufferUsedAs(indirect_buffer, indirect_usage_bit);
        }
        try self.resource_usage.addDispatch(scope.scope);
        scope.scope = usage.SyncScopeResourceUsage.init(self.programmable.allocator);
    }
};

const indirect_usage_bit: u32 = 1 << 8;
const compute_stage_bit: u32 = 1 << 2;

test "compute dispatch validates bind groups immediates and resource tables" {
    var mutex: std.Io.Mutex = .init;
    var device = computeTestDevice(&mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(std.testing.allocator, device.borrow(), 4096, false);
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var encoder = ComputeEncoder.init(std.testing.allocator, &context, .{});
    defer encoder.deinit();
    var resource: u8 = 0;
    try encoder.setPipeline(.{ .pipeline = &resource, .requirements = .{
        .bind_group_layout_mask = 1,
        .immediate_slot_mask = 1,
        .uses_resource_table = true,
    } });
    try std.testing.expectError(error.MissingBindGroup, encoder.dispatch(.{}));
    try encoder.setBindGroup(.{ .index = 0, .group = &resource });
    try std.testing.expectError(error.MissingResourceTable, encoder.dispatch(.{}));
    try encoder.setResourceTable(&resource);
    try std.testing.expectError(error.MissingImmediateData, encoder.dispatch(.{}));
    try encoder.setImmediates(.{ .offset = 0, .data = &.{ 1, 2, 3, 4 } });
    try encoder.insertDebugMarker("ready");
    try encoder.dispatch(.{});
    try encoder.end();
    try std.testing.expectEqual(
        @as(usize, 1),
        context.compute_pass_usages.items[0].referenced_resource_tables.items.len,
    );
    try std.testing.expectEqual(
        @as(commands.Ref, &resource),
        context.compute_pass_usages.items[0].dispatch_usages.items[0].resource_table,
    );
}

test "compute recording allocation failures release every metadata allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCase, .{});
}

fn allocationFailureCase(allocator: std.mem.Allocator) !void {
    var mutex: std.Io.Mutex = .init;
    var device = computeTestDevice(&mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(allocator, device.borrow(), 4096, false);
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var encoder = ComputeEncoder.init(allocator, &context, .{});
    defer encoder.deinit();
    var resource: u8 = 0;
    try encoder.setPipeline(.{ .pipeline = &resource, .requirements = .{
        .bind_group_layout_mask = 1,
    } });
    try encoder.setBindGroup(.{
        .index = 0,
        .group = &resource,
        .dynamic_offset_count = 1,
        .dynamic_offsets = &.{0},
        .buffers = &.{.{ .buffer = &resource, .usage = 64 }},
        .textures = &.{.{
            .texture = &resource,
            .mip_level = 0,
            .array_layer = 0,
            .aspect = .all,
            .usage = 4,
            .shader_stages = compute_stage_bit,
        }},
        .external_textures = &.{&resource},
    });
    try encoder.dispatch(.{});
    try encoder.end();
}

test "compute producers record typed dispatch payloads in order" {
    var mutex: std.Io.Mutex = .init;
    var device = computeTestDevice(&mutex);
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try encoding_context.Context.init(std.testing.allocator, device.borrow(), 4096, false);
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    var encoder = ComputeEncoder.init(std.testing.allocator, &context, .{});
    defer encoder.deinit();
    var resource: u8 = 0;
    try std.testing.expectError(error.InvalidResource, encoder.setPipeline(.{ .pipeline = null }));
    try encoder.setPipeline(.{ .pipeline = &resource });
    try std.testing.expectError(error.IndirectUsageMissing, encoder.dispatchIndirect(.{
        .buffer = &resource,
        .buffer_size = 12,
        .usage = 0,
    }));
    try std.testing.expectError(error.RequiredFeatureMissing, encoder.writeTimestamp(.{
        .query_set = &resource,
        .query_count = 1,
        .query_index = 0,
    }));
    try encoder.dispatch(.{ .x = 2, .y = 3, .z = 4 });
    try encoder.dispatchIndirect(.{ .buffer = &resource, .buffer_size = 12, .usage = 256 });
    try encoder.end();
    var finished = try context.finish();
    defer finished.deinit(std.testing.allocator, std.testing.io, &guard);
    var iterator = finished.iterator(std.testing.allocator);
    defer iterator.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, .set_compute_pipeline), try iterator.nextTag());
    const pipeline = try iterator.nextCommand(commands.SetComputePipelineCmd);
    try std.testing.expectEqual(@as(commands.Ref, &resource), pipeline.pipeline);
    try std.testing.expectEqual(@as(?commands.Tag, .dispatch), try iterator.nextTag());
    const dispatch_payload = try iterator.nextCommand(commands.DispatchCmd);
    try std.testing.expectEqual(@as(u32, 2), dispatch_payload.x);
    try std.testing.expectEqual(@as(u32, 3), dispatch_payload.y);
    try std.testing.expectEqual(@as(u32, 4), dispatch_payload.z);
    try std.testing.expectEqual(@as(?commands.Tag, .dispatch_indirect), try iterator.nextTag());
    const indirect = try iterator.nextCommand(commands.DispatchIndirectCmd);
    try std.testing.expectEqual(@as(commands.Ref, &resource), indirect.indirect_buffer);
    try std.testing.expectEqual(@as(u64, 0), indirect.indirect_offset);
    try std.testing.expectEqual(@as(?commands.Tag, .end_compute_pass), try iterator.nextTag());
    _ = try iterator.nextCommand(commands.EndComputePassCmd);
    try std.testing.expectEqual(@as(?commands.Tag, null), try iterator.nextTag());
}
