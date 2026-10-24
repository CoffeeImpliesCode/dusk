//! Actual GPU consumers of sanitized indirect commands. No device-dependent skip.
const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const native = engine.native_resources;
const command = dusk.command;
const Encoder = command.command_encoder.CommandEncoder;
const gpa = std.testing.allocator;
const t = std.testing;
const sentinel: u8 = 0xa5;
const vertex_words = decodeWords(@embedFile("fixtures/indirect_consumer.vert.spv"));
const fragment_words = decodeWords(@embedFile("fixtures/indirect_consumer.frag.spv"));
const consume_words = decodeWords(@embedFile("fixtures/indirect_consumer.comp.spv"));
const produce_words = decodeWords(@embedFile("fixtures/indirect_producer.comp.spv"));

test "native indirect draw pixels both index widths selected ranges counts and firstInstance" {
    for ([_]bool{ false, true }) |first_instance_enabled| {
        var f: Fixture = undefined;
        try f.init(first_instance_enabled);
        defer f.deinit();
        try drawConsumers(&f, false);
        try drawConsumers(&f, true);
    }
}

test "native indirect dispatch axis maxima zero invalid and producer consumer restore state" {
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    try dispatchConsumers(&f);
    try dispatchKernelVectors(&f);
    try dispatchProducerConsumer(&f);
}

test "native sanitize draws 129 records carry oracle all words and untouched output tail" {
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    try drawKernelVectors(&f);
}

test "native indirect input and packed indexed output cross effective storage windows" {
    const required: api.Limits = .{
        .max_storage_buffer_binding_size = 256,
        .max_buffer_size = 4096,
    };
    var f: Fixture = undefined;
    try f.initLimits(false, &required);
    defer f.deinit();
    try t.expectEqual(@as(u64, 256), f.device.limits.v1.max_storage_buffer_binding_size);
    try crossingDrawConsumers(&f);
    try crossingDispatchConsumer(&f, 252);
}

test "native indirect dispatch accepts storage cap16 without draw metadata cap32" {
    const required: api.Limits = .{
        .max_storage_buffer_binding_size = 16,
        .max_buffer_size = 4096,
    };
    var f: Fixture = undefined;
    try f.initLimits(false, &required);
    defer f.deinit();
    try t.expectEqual(@as(u64, 16), f.device.limits.v1.max_storage_buffer_binding_size);
    try crossingDispatchConsumer(&f, 0);
}

test "native indirect registered definitions match shader binding and workgroup ABI" {
    const definitions = engine.native_kernel_definitions;
    const draws = try definitions.definition(.{ .id = .sanitize_draws });
    try t.expectEqual(@as(usize, 4), draws.slots.len);
    const draw_sizes = [_]u32{ 16, 4, 32, 16 };
    for (draws.slots, draw_sizes, 0..) |slot, size, index| {
        try t.expectEqual(size, slot.buffer.min_size);
        const expected: definitions.BufferAccess = if (index == 3)
            .storage_write
        else
            .storage_read;
        try t.expectEqual(expected, slot.buffer.access);
    }
    try t.expectEqual(@as(u32, 32), draws.parameter_size);
    try t.expect(!draws.depth_range_push_constants);
    try t.expectEqual(@as(u32, 0x07230203), draws.stages.compute.stage.words[0]);
    try t.expectEqualSlices(u32, &.{ 64, 1, 1 }, &draws.stages.compute.workgroup_size);
    try t.expectEqualStrings("sanitize_draws", draws.stages.compute.stage.entry_point);
    const dispatch = try definitions.definition(.{ .id = .sanitize_dispatch });
    try t.expectEqual(@as(usize, 2), dispatch.slots.len);
    const dispatch_sizes = [_]u32{ 12, 12 };
    for (dispatch.slots, dispatch_sizes, 0..) |slot, size, index| {
        try t.expectEqual(size, slot.buffer.min_size);
        const expected: definitions.BufferAccess = if (index == 0)
            .storage_read
        else
            .storage_write;
        try t.expectEqual(expected, slot.buffer.access);
    }
    try t.expectEqual(@as(u32, 16), dispatch.parameter_size);
    try t.expect(!dispatch.depth_range_push_constants);
    try t.expectEqual(@as(u32, 0x07230203), dispatch.stages.compute.stage.words[0]);
    try t.expectEqualSlices(u32, &.{ 1, 1, 1 }, &dispatch.stages.compute.workgroup_size);
    try t.expectEqualStrings("sanitize_dispatch", dispatch.stages.compute.stage.entry_point);
}

const Fixture = struct {
    threaded: std.Io.Threaded,
    instance: engine.Instance,
    adapters: engine.AdapterList,
    device: engine.Device,
    first_instance_enabled: bool,

    fn init(self: *Fixture, first_instance_enabled: bool) !void {
        try self.initLimits(first_instance_enabled, null);
    }

    fn initLimits(self: *Fixture, first_instance_enabled: bool, required_limits: ?*const api.Limits) !void {
        self.threaded = .init(gpa, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.instance = .init(.{ .backend_type = .vulkan });
        errdefer self.instance.deinit(gpa, io) catch @panic("indirect instance rollback");
        self.adapters = try self.instance.enumerateAdapters(gpa, io, .{
            .backend_type = .vulkan,
            .feature_level = .core,
            .power_preference = .undefined_,
        });
        errdefer self.adapters.deinit(io) catch @panic("indirect adapters rollback");
        if (self.adapters.items.len == 0) return error.NoPhysicalDevice;
        self.first_instance_enabled = first_instance_enabled;
        const required_features: []const api.FeatureName = if (first_instance_enabled)
            &.{.indirect_first_instance}
        else
            &.{};
        self.device = try self.adapters.items[0].createDevice(gpa, io, .{
            .adapter = &self.adapters.items[0],
            .feature_level = .core,
            .required_features = required_features,
            .required_limits = required_limits,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
    }

    fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
        @panic("indirect GPU fixture uncaptured error");
    }

    fn deinit(self: *Fixture) void {
        const io = self.threaded.io();
        self.device.deinit(gpa, io) catch @panic("indirect device teardown");
        self.adapters.deinit(io) catch @panic("indirect adapter teardown");
        self.instance.deinit(gpa, io) catch @panic("indirect instance teardown");
        self.threaded.deinit();
    }

    fn release(self: *Fixture, resource: anytype) void {
        self.device.release(gpa, self.threaded.io(), resource) catch @panic("indirect alias release");
    }

    fn buffer(self: *Fixture, size: u64, usage: api.BufferUsage) !*native.Buffer {
        return self.device.createBuffer(gpa, self.threaded.io(), .{ .size = size, .usage = usage });
    }

    fn deinitEncoder(self: *Fixture, encoder: *Encoder) void {
        const io = self.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(gpa, io, &guard);
    }

    fn deinitFinished(self: *Fixture, finished: *command.encoding_context.Finished) void {
        const io = self.threaded.io();
        var guard = core.ObjectGuard.lockUncancelable(io, self.device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        finished.deinit(gpa, io, &guard);
    }

    fn submit(self: *Fixture, encoder: *Encoder) !void {
        var finished = try encoder.finish();
        defer self.deinitFinished(&finished);
        const serial = try self.device.submit(gpa, self.threaded.io(), &finished);
        try self.device.wait(self.threaded.io(), serial);
    }
};

const Compute = struct {
    shader: *native.ShaderModule,
    group_layout: *native.BindGroupLayout,
    layout: *native.PipelineLayout,
    group: *native.BindGroup,
    pipeline: *native.Pipeline,
    buffers: []const *native.Buffer,
    readonly_mask: u32,
    uniform_mask: u32,

    fn init(f: *Fixture, words: []const u32, entry: [:0]const u8, buffers: []const *native.Buffer, readonly_mask: u32, uniform_mask: u32) !Compute {
        std.debug.assert(buffers.len <= 5);
        const io = f.threaded.io();
        const shader = try f.device.createShaderModule(gpa, io, .{ .words = words });
        errdefer f.release(shader);
        var entries: [5]dusk.pipeline.bind_group_layout.Entry = undefined;
        for (buffers, 0..) |buffer, index| {
            const bit = @as(u32, 1) << @as(u5, @intCast(index));
            entries[index] = .{
                .binding_number = @intCast(index),
                .visibility = .{ .compute = true },
                .kind = .{ .buffer = .{
                    .binding_type = if (uniform_mask & bit != 0) .uniform else if (readonly_mask & bit != 0) .read_only_storage else .storage,
                    .has_dynamic_offset = false,
                    .min_binding_size = buffer.native.size,
                } },
            };
        }
        const group_layout = try f.device.createBindGroupLayout(gpa, io, .{
            .entries = entries[0..buffers.len],
        });
        errdefer f.release(group_layout);
        const layout = try f.device.createPipelineLayout(gpa, io, .{ .groups = &.{group_layout} });
        errdefer f.release(layout);
        var bindings: [5]native.Binding = undefined;
        for (buffers, 0..) |buffer, index| {
            const bit = @as(u32, 1) << @as(u5, @intCast(index));
            bindings[index] = .{ .buffer = .{
                .binding = @intCast(index),
                .buffer = buffer,
                .offset = 0,
                .size = buffer.native.size,
                .kind = if (uniform_mask & bit != 0) .uniform else if (readonly_mask & bit != 0) .read_only_storage else .storage,
                .stages = .{ .compute = true },
            } };
        }
        const group = try f.device.createBindGroup(gpa, io, .{
            .layout = layout,
            .group_index = 0,
            .bindings = bindings[0..buffers.len],
        });
        errdefer f.release(group);
        const pipeline = try f.device.createComputePipeline(gpa, io, .{
            .layout = layout,
            .compute = .{ .module = shader, .entry_point = entry, .stage = .compute },
        });
        return .{ .shader = shader, .group_layout = group_layout, .layout = layout, .group = group, .pipeline = pipeline, .buffers = buffers, .readonly_mask = readonly_mask, .uniform_mask = uniform_mask };
    }

    fn deinit(self: *Compute, f: *Fixture) void {
        f.release(self.pipeline);
        f.release(self.group);
        f.release(self.layout);
        f.release(self.group_layout);
        f.release(self.shader);
    }

    fn bind(self: *const Compute, guard: *const core.ObjectGuard, pass: *command.compute_encoder.ComputeEncoder) !void {
        const identity = @intFromPtr(&self.group_layout.header);
        try pass.setPipeline(.{ .pipeline = try self.pipeline.ref(guard), .requirements = .{
            .bind_group_layout_mask = 1,
            .bind_group_layout_ids = .{ identity, 0, 0, 0 },
        } });
        var usages: [5]command.usage.BindGroupBuffer = undefined;
        for (self.buffers, 0..) |buffer, index| {
            const bit = @as(u32, 1) << @as(u5, @intCast(index));
            usages[index] = .{ .buffer = try buffer.ref(guard), .usage = if (self.uniform_mask & bit != 0)
                (api.BufferUsage{ .uniform = true }).toFlags()
            else if (self.readonly_mask & bit != 0) engine.buffer.read_only_storage_buffer else (api.BufferUsage{ .storage = true }).toFlags() };
        }
        try pass.setBindGroup(.{ .index = 0, .group = try self.group.ref(guard), .layout_id = identity, .buffers = usages[0..self.buffers.len] });
    }
};

fn drawConsumers(f: *Fixture, index32: bool) !void {
    const io = f.threaded.io();
    const vertex = try f.device.createShaderModule(gpa, io, .{ .words = &vertex_words });
    defer f.release(vertex);
    const fragment = try f.device.createShaderModule(gpa, io, .{ .words = &fragment_words });
    defer f.release(fragment);
    const layout = try f.device.createPipelineLayout(gpa, io, .{ .groups = &.{} });
    defer f.release(layout);
    const pipeline = try f.device.createRenderPipeline(gpa, io, .{
        .layout = layout,
        .vertex = .{ .module = vertex, .entry_point = "main", .stage = .vertex },
        .fragment = .{ .module = fragment, .entry_point = "main", .stage = .fragment },
        .color_targets = &.{.{ .format = .rgba8_unorm }},
    });
    defer f.release(pipeline);
    const target = try f.device.createTexture(gpa, io, .{
        .size = .{ .width = 12, .height = 1, .depth_or_array_layers = 1 },
        .format = .rgba8_unorm,
        .usage = .{ .render_attachment = true, .copy_src = true },
    });
    defer f.release(target);
    const view = try f.device.createTextureView(gpa, io, .{
        .texture = target,
        .descriptor = .{ .format = .rgba8_unorm, .dimension = ._2d },
    });
    defer f.release(view);
    const arguments = try f.buffer(256, .{ .indirect = true, .copy_src = true, .copy_dst = true });
    defer f.release(arguments);
    const counts = try f.buffer(32, .{ .indirect = true, .copy_src = true, .copy_dst = true });
    defer f.release(counts);
    const indices = try f.buffer(32, .{ .index = true, .copy_dst = true });
    defer f.release(indices);
    const readback = try f.buffer(544, .{ .map_read = true, .copy_dst = true });
    defer f.release(readback);
    var input: [256]u8 = @splat(sentinel);
    const records = [_][5]u32{
        .{ 3, 1, 0, 0, 0 }, .{ 3, 1, 0, 0, 1 },
        .{ 3, 1, 0, 0, 0 }, .{ 3, 1, 1, 0, 0 },
        .{ 3, 1, 0, 0, 1 }, .{ 3, 1, 0, 0, 0 },
        .{ 3, 1, 0, 0, 0 }, .{ 3, 1, 0, 0, 0 },
    };
    for (records, 0..) |record, index| putWords(&input, 16 + index * 20, &record);
    // Nonindexed records use four words. The unused fifth word remains input data.
    putWords(&input, 16, &.{ 3, 1, 0, 0 });
    putWords(&input, 36, &.{ 3, 1, 0, 1 });
    putWords(&input, 176, &.{ 3, 1, 0, 0, 3, 2, 0, 0 });
    putWords(&input, 208, &.{ 3, 1, 0, 0, 0, 3, 2, 0, 0, 0 });
    var count_bytes: [32]u8 = @splat(sentinel);
    putWords(&count_bytes, 4, &.{ 0, 0xffffffff });
    var index_bytes: [32]u8 = @splat(sentinel);
    const element_bytes: u64 = if (index32) 4 else 2;
    for (0..6) |index| {
        const offset = 4 + index * @as(usize, @intCast(element_bytes));
        if (index32) std.mem.writeInt(u32, index_bytes[offset..][0..4], @intCast(index % 3), .little) else std.mem.writeInt(u16, index_bytes[offset..][0..2], @intCast(index % 3), .little);
    }
    var encoder = Encoder.init(gpa, f.device.coreDevice().borrow(), .{});
    defer f.deinitEncoder(&encoder);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        try encoder.writeBuffer(.{ .buffer = try arguments.ref(&guard), .data = &input });
        try encoder.writeBuffer(.{ .buffer = try counts.ref(&guard), .data = &count_bytes });
        try encoder.writeBuffer(.{ .buffer = try indices.ref(&guard), .data = &index_bytes });
        const padding: [544]u8 = @splat(sentinel);
        try encoder.writeBuffer(.{ .buffer = try readback.ref(&guard), .data = &padding });
    }
    var pass = try f.device.beginRenderPass(gpa, io, &encoder, .{
        .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 } }},
        .width = 12,
        .height = 1,
    });
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        pass.deinit(io, &guard);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        try pass.setPipeline(&guard, try pipeline.renderOptions(&guard));
        try pass.setViewport(.{ .width = 12, .height = 1, .min_depth = 0, .max_depth = 1 });
        for (0..12) |pixel| {
            try pass.setScissorRect(.{ .x = @intCast(pixel), .y = 0, .width = 1, .height = 1 });
            const draw = command.render_encoder_base.DrawIndirectOptions{
                .indirect_buffer = try arguments.ref(&guard),
                .indirect_buffer_size = 256,
                .indirect_offset = 16 + @as(u64, @min(pixel, 7)) * 20,
            };
            if (pixel < 2) {
                try pass.drawIndirect(draw);
            } else if (pixel < 5) {
                try pass.setIndexBuffer(.{ .buffer = try indices.ref(&guard), .buffer_size = 32, .format = if (index32) .uint32 else .uint16, .offset = 4, .size = 3 * element_bytes });
                try pass.drawIndexedIndirect(draw);
            } else if (pixel < 9) {
                // Two adjacent tightly packed records; GPU count controls both slots.
                const multi = command.render_encoder_base.MultiDrawIndirectOptions{
                    .indirect_buffer = try arguments.ref(&guard),
                    .indirect_buffer_size = 256,
                    .indirect_offset = if (pixel < 7) 176 else 208,
                    .max_draw_count = 2,
                    .draw_count_buffer = try counts.ref(&guard),
                    .draw_count_buffer_size = 32,
                    .draw_count_offset = if (pixel == 5 or pixel == 7) 4 else 8,
                };
                if (pixel < 7) try pass.multiDrawIndirect(multi) else try pass.multiDrawIndexedIndirect(multi);
            } else if (pixel == 9) {
                // The full range makes firstIndex=1 valid, unlike the selected three elements.
                try pass.setIndexBuffer(.{ .buffer = try indices.ref(&guard), .buffer_size = 32, .format = if (index32) .uint32 else .uint16, .offset = 4, .size = 6 * element_bytes });
                try pass.drawIndexedIndirect(.{ .indirect_buffer = try arguments.ref(&guard), .indirect_buffer_size = 256, .indirect_offset = 76 });
            } else {
                // No pipeline re-selection: helper state must not leak into ordinary draws.
                try pass.draw(.{ .vertex_count = 3, .instance_count = 1, .first_vertex = 0, .first_instance = if (pixel == 11) 1 else 0 });
            }
        }
        try pass.end(io, &guard);
        try encoder.copyTextureToBuffer(.{
            .source = .{ .texture = target, .format = @backingInt(api.TextureFormat.rgba8_unorm), .dimension = ._2d, .aspect = .all, .extent = .{ .width = 12, .height = 1, .depth_or_array_layers = 1 } },
            .destination = .{ .buffer = try readback.ref(&guard), .blocks_per_row = 64, .rows_per_image = 1 },
            .copy_size = .{ .width = 12, .height = 1, .depth_or_array_layers = 1 },
        });
        try encoder.copyBufferToBuffer(.{ .source = try arguments.ref(&guard), .destination = try readback.ref(&guard), .destination_offset = 256, .size = 256 });
        try encoder.copyBufferToBuffer(.{ .source = try counts.ref(&guard), .destination = try readback.ref(&guard), .destination_offset = 512, .size = 32 });
    }
    try f.submit(&encoder);
    try f.device.mapBuffer(io, readback, .{ .mode = .{ .read = true }, .size = 544 });
    defer f.device.unmapBuffer(io, readback) catch @panic("indirect pixels unmap");
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
    defer guard.unlock(io);
    const bytes = try readback.native.getConstMappedRange(0, 544);
    for (0..12) |pixel| {
        const color: [4]u8 = if (pixel == 1 or pixel == 4)
            (if (f.first_instance_enabled) .{ 0, 255, 0, 255 } else .{ 0, 0, 0, 255 })
        else if (pixel == 3 or pixel == 5 or pixel == 7) .{ 0, 0, 0, 255 } else if (pixel == 6 or pixel == 8 or pixel == 11) .{ 0, 255, 0, 255 } else .{ 255, 0, 0, 255 };
        try t.expectEqualSlices(u8, &color, bytes[pixel * 4 ..][0..4]);
    }
    try expectPadding(bytes[48..256]);
    try t.expectEqualSlices(u8, &input, bytes[256..512]);
    try t.expectEqualSlices(u8, &count_bytes, bytes[512..544]);
}

fn dispatchConsumers(f: *Fixture) !void {
    const io = f.threaded.io();
    const maximum = f.device.limits.v1.max_compute_workgroups_per_dimension;
    const vectors = [_][3]u32{ .{ 2, 3, 4 }, .{ 0, 1, 1 }, .{ maximum, 0, 1 }, .{ 0, maximum, 1 }, .{ 0, 1, maximum }, .{ maximum + 1, 1, 1 }, .{ 1, maximum + 1, 1 }, .{ 1, 1, maximum + 1 } };
    const arguments = try f.buffer(160, .{ .indirect = true, .copy_src = true, .copy_dst = true });
    defer f.release(arguments);
    const output = try f.buffer(4, .{ .storage = true, .copy_src = true, .copy_dst = true });
    defer f.release(output);
    const readback = try f.buffer(224, .{ .map_read = true, .copy_dst = true });
    defer f.release(readback);
    const bindings = [_]*native.Buffer{output};
    var compute = try Compute.init(f, &consume_words, "main", &bindings, 0, 0);
    defer compute.deinit(f);
    var input: [160]u8 = @splat(sentinel);
    for (vectors, 0..) |vector, index| putWords(&input, 8 + index * 16, &vector);
    var encoder = Encoder.init(gpa, f.device.coreDevice().borrow(), .{});
    defer f.deinitEncoder(&encoder);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        try encoder.writeBuffer(.{ .buffer = try arguments.ref(&guard), .data = &input });
        const padding: [224]u8 = @splat(sentinel);
        try encoder.writeBuffer(.{ .buffer = try readback.ref(&guard), .data = &padding });
        for (vectors, 0..) |_, index| {
            try encoder.writeBuffer(.{ .buffer = try output.ref(&guard), .data = &.{ 0, 0, 0, 0 } });
            var pass = try encoder.beginComputePass(.{});
            defer pass.deinit();
            try compute.bind(&guard, &pass);
            try pass.dispatchIndirect(.{ .buffer = try arguments.ref(&guard), .buffer_size = 160, .offset = 8 + index * 16, .usage = (api.BufferUsage{ .indirect = true }).toFlags() });
            // Same pipeline and descriptors, no setters after the sanitizer.
            try pass.dispatch(.{});
            try pass.end();
            try encoder.copyBufferToBuffer(.{ .source = try output.ref(&guard), .destination = try readback.ref(&guard), .destination_offset = index * 8, .size = 4 });
        }
        try encoder.copyBufferToBuffer(.{ .source = try arguments.ref(&guard), .destination = try readback.ref(&guard), .destination_offset = 64, .size = 160 });
    }
    try f.submit(&encoder);
    try f.device.mapBuffer(io, readback, .{ .mode = .{ .read = true }, .size = 224 });
    defer f.device.unmapBuffer(io, readback) catch @panic("indirect dispatch unmap");
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
    defer guard.unlock(io);
    const bytes = try readback.native.getConstMappedRange(0, 224);
    for (vectors, 0..) |vector, index| {
        const valid = vector[0] <= maximum and vector[1] <= maximum and vector[2] <= maximum;
        const expected: u32 = if (valid) vector[0] * vector[1] * vector[2] + 1 else 1;
        try t.expectEqual(expected, getWord(bytes, index * 8));
        try expectPadding(bytes[index * 8 + 4 ..][0..4]);
    }
    try t.expectEqualSlices(u8, &input, bytes[64..224]);
}

fn dispatchProducerConsumer(f: *Fixture) !void {
    const io = f.threaded.io();
    const arguments = try f.buffer(32, .{ .storage = true, .indirect = true, .copy_src = true, .copy_dst = true });
    defer f.release(arguments);
    const output = try f.buffer(4, .{ .storage = true, .copy_src = true, .copy_dst = true });
    defer f.release(output);
    const readback = try f.buffer(40, .{ .map_read = true, .copy_dst = true });
    defer f.release(readback);
    const producer_bindings = [_]*native.Buffer{arguments};
    const consumer_bindings = [_]*native.Buffer{output};
    var producer = try Compute.init(f, &produce_words, "main", &producer_bindings, 0, 0);
    defer producer.deinit(f);
    var consumer = try Compute.init(f, &consume_words, "main", &consumer_bindings, 0, 0);
    defer consumer.deinit(f);
    var encoder = Encoder.init(gpa, f.device.coreDevice().borrow(), .{});
    defer f.deinitEncoder(&encoder);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        const padding: [40]u8 = @splat(sentinel);
        try encoder.writeBuffer(.{ .buffer = try readback.ref(&guard), .data = &padding });
        try encoder.writeBuffer(.{ .buffer = try arguments.ref(&guard), .data = padding[0..32] });
        try encoder.writeBuffer(.{ .buffer = try output.ref(&guard), .data = &.{ 0, 0, 0, 0 } });
        var pass = try encoder.beginComputePass(.{});
        defer pass.deinit();
        try producer.bind(&guard, &pass);
        try pass.dispatch(.{});
        try consumer.bind(&guard, &pass);
        try pass.dispatchIndirect(.{ .buffer = try arguments.ref(&guard), .buffer_size = 32, .offset = 8, .usage = (api.BufferUsage{ .indirect = true }).toFlags() });
        try pass.dispatch(.{ .x = 2 });
        try pass.end();
        try encoder.copyBufferToBuffer(.{ .source = try output.ref(&guard), .destination = try readback.ref(&guard), .size = 4 });
        try encoder.copyBufferToBuffer(.{ .source = try arguments.ref(&guard), .destination = try readback.ref(&guard), .destination_offset = 8, .size = 32 });
    }
    try f.submit(&encoder);
    try f.device.mapBuffer(io, readback, .{ .mode = .{ .read = true }, .size = 40 });
    defer f.device.unmapBuffer(io, readback) catch @panic("indirect producer unmap");
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
    defer guard.unlock(io);
    const bytes = try readback.native.getConstMappedRange(0, 40);
    try t.expectEqual(@as(u32, 26), getWord(bytes, 0));
    try expectPadding(bytes[4..16]);
    try t.expectEqual(@as(u32, 2), getWord(bytes, 16));
    try t.expectEqual(@as(u32, 3), getWord(bytes, 20));
    try t.expectEqual(@as(u32, 4), getWord(bytes, 24));
    try expectPadding(bytes[28..40]);
}

// The independent oracle uses a widened addition, not the shader's limb/carry method.
fn drawOracle(record: [5]u32, bound: u64, allow_first_instance: bool, gpu_count: u32, ordinal: u32, max_draw_count: u32) [5]u32 {
    if (ordinal >= @min(gpu_count, max_draw_count)) return @splat(0);
    if (!allow_first_instance and record[4] != 0) return @splat(0);
    if (@as(u64, record[0]) + @as(u64, record[2]) > bound) return @splat(0);
    return record;
}

fn drawKernelVectors(f: *Fixture) !void {
    const count = 129;
    const io = f.threaded.io();
    const vectors = [_]struct { record: [5]u32, bound: u64 }{
        .{ .record = .{ 1, 1, 0xffffffff, 0xfffffff9, 0 }, .bound = 0x100000000 },
        .{ .record = .{ 1, 1, 0xffffffff, 0xfffffff9, 0 }, .bound = 0xffffffff },
        .{ .record = .{ 0xffffffff, 2, 0xffffffff, 0x80000000, 0 }, .bound = 0x1fffffffe },
        .{ .record = .{ 0xffffffff, 2, 0xffffffff, 0x80000000, 0 }, .bound = 0x1fffffffd },
        .{ .record = .{ 3, 1, 0, 7, 1 }, .bound = 3 },
        .{ .record = .{ 0, 0, 0xffffffff, 0xffffffff, 0xffffffff }, .bound = 0xffffffff },
        .{ .record = .{ 3, 1, 1, 0xffffffff, 0 }, .bound = 3 },
        .{ .record = .{ 3, 1, 0, 0x80000000, 0 }, .bound = 3 },
    };
    var input: [count * 24 + 32]u8 = @splat(sentinel);
    var metadata: [count * 32]u8 = @splat(0);
    var expected: [count][5]u32 = undefined;
    for (0..count) |index| {
        const vector = vectors[index % vectors.len];
        const allow = index % 2 == 0;
        const gpu_count: u32 = switch (index % 3) {
            0 => 0,
            1 => 1,
            else => 0xffffffff,
        };
        const ordinal: u32 = @intCast(index % 2);
        putWords(&input, 16 + index * 24, &vector.record);
        putWords(&metadata, index * 32, &.{
            @intCast(4 + index * 6),                       @intCast(4 + index * 5),
            @truncate(vector.bound),                       @intCast(vector.bound >> 32),
            @as(u32, 3) | (if (allow) @as(u32, 4) else 0), @intCast(index % 3),
            ordinal,                                       2,
        });
        expected[index] = drawOracle(vector.record, vector.bound, allow, gpu_count, ordinal, 2);
    }
    const output_size = count * 20 + 32;
    const arguments = try f.buffer(input.len, .{ .storage = true, .copy_src = true, .copy_dst = true });
    defer f.release(arguments);
    const counts = try f.buffer(16, .{ .storage = true, .copy_dst = true });
    defer f.release(counts);
    const metadata_buffer = try f.buffer(metadata.len, .{ .storage = true, .copy_dst = true });
    defer f.release(metadata_buffer);
    const output = try f.buffer(output_size, .{ .storage = true, .copy_src = true, .copy_dst = true });
    defer f.release(output);
    const parameters = try f.buffer(32, .{ .uniform = true, .copy_dst = true });
    defer f.release(parameters);
    const readback = try f.buffer(output_size + input.len, .{ .map_read = true, .copy_dst = true });
    defer f.release(readback);
    const definition = try engine.native_kernel_definitions.definition(.{ .id = .sanitize_draws });
    const stage = definition.stages.compute.stage;
    const bindings = [_]*native.Buffer{ arguments, counts, metadata_buffer, output, parameters };
    var compute = try Compute.init(f, stage.words, stage.entry_point, &bindings, 7, 16);
    defer compute.deinit(f);
    var encoder = Encoder.init(gpa, f.device.coreDevice().borrow(), .{});
    defer f.deinitEncoder(&encoder);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        try encoder.writeBuffer(.{ .buffer = try arguments.ref(&guard), .data = &input });
        try encoder.writeBuffer(.{ .buffer = try metadata_buffer.ref(&guard), .data = &metadata });
        var count_bytes: [16]u8 = @splat(0);
        putWords(&count_bytes, 0, &.{ 0, 1, 0xffffffff });
        try encoder.writeBuffer(.{ .buffer = try counts.ref(&guard), .data = &count_bytes });
        var parameter_bytes: [32]u8 = @splat(0);
        putWords(&parameter_bytes, 0, &.{count});
        try encoder.writeBuffer(.{ .buffer = try parameters.ref(&guard), .data = &parameter_bytes });
        const padding: [output_size]u8 = @splat(sentinel);
        try encoder.writeBuffer(.{ .buffer = try output.ref(&guard), .data = &padding });
        var pass = try encoder.beginComputePass(.{});
        defer pass.deinit();
        try compute.bind(&guard, &pass);
        try pass.dispatch(.{ .x = 3 });
        try pass.end();
        try encoder.copyBufferToBuffer(.{ .source = try output.ref(&guard), .destination = try readback.ref(&guard), .size = output_size });
        try encoder.copyBufferToBuffer(.{ .source = try arguments.ref(&guard), .destination = try readback.ref(&guard), .destination_offset = output_size, .size = input.len });
    }
    try f.submit(&encoder);
    try f.device.mapBuffer(io, readback, .{ .mode = .{ .read = true }, .size = output_size + input.len });
    defer f.device.unmapBuffer(io, readback) catch @panic("indirect vectors unmap");
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
    defer guard.unlock(io);
    const bytes = try readback.native.getConstMappedRange(0, output_size + input.len);
    try expectPadding(bytes[0..16]);
    for (expected, 0..) |record, index| {
        for (record, 0..) |word, component| {
            try t.expectEqual(word, getWord(bytes, 16 + index * 20 + component * 4));
        }
    }
    try expectPadding(bytes[16 + count * 20 .. output_size]);
    try t.expectEqualSlices(u8, &input, bytes[output_size..]);
}

fn putWords(bytes: []u8, offset: usize, words: []const u32) void {
    for (words, 0..) |word, index| std.mem.writeInt(u32, bytes[offset + index * 4 ..][0..4], word, .little);
}

fn getWord(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn expectPadding(bytes: []const u8) !void {
    for (bytes) |byte| try t.expectEqual(sentinel, byte);
}

fn decodeWords(comptime bytes: []const u8) [bytes.len / 4]u32 {
    if (bytes.len % 4 != 0) @compileError("SPIR-V fixture has partial word");
    var words: [bytes.len / 4]u32 = undefined;
    for (&words, 0..) |*word, index| word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    return words;
}

fn dispatchKernelVectors(f: *Fixture) !void {
    const io = f.threaded.io();
    const vectors = [_][3]u32{
        .{ 3, 4, 5 }, .{ 4, 4, 5 }, .{ 3, 5, 5 }, .{ 3, 4, 6 },
        .{ 0, 4, 5 }, .{ 3, 0, 5 }, .{ 3, 4, 0 }, .{ 1, 1, 1 },
    };
    var input: [144]u8 = @splat(sentinel);
    for (vectors, 0..) |vector, index| putWords(&input, 8 + index * 16, &vector);
    const arguments = try f.buffer(input.len, .{ .storage = true, .copy_src = true, .copy_dst = true });
    defer f.release(arguments);
    const output = try f.buffer(16, .{ .storage = true, .copy_src = true, .copy_dst = true });
    defer f.release(output);
    const parameters = try f.buffer(16, .{ .uniform = true, .copy_dst = true });
    defer f.release(parameters);
    const readback = try f.buffer(128 + input.len, .{ .map_read = true, .copy_dst = true });
    defer f.release(readback);
    const definition = try engine.native_kernel_definitions.definition(.{ .id = .sanitize_dispatch });
    const stage = definition.stages.compute.stage;
    const bindings = [_]*native.Buffer{ arguments, output, parameters };
    var compute = try Compute.init(f, stage.words, stage.entry_point, &bindings, 1, 4);
    defer compute.deinit(f);
    var encoder = Encoder.init(gpa, f.device.coreDevice().borrow(), .{});
    defer f.deinitEncoder(&encoder);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        try encoder.writeBuffer(.{ .buffer = try arguments.ref(&guard), .data = &input });
        for (vectors, 0..) |_, index| {
            var parameter_bytes: [16]u8 = undefined;
            putWords(&parameter_bytes, 0, &.{ @intCast(2 + index * 4), 3, 4, 5 });
            try encoder.writeBuffer(.{ .buffer = try parameters.ref(&guard), .data = &parameter_bytes });
            const padding: [16]u8 = @splat(sentinel);
            try encoder.writeBuffer(.{ .buffer = try output.ref(&guard), .data = &padding });
            var pass = try encoder.beginComputePass(.{});
            defer pass.deinit();
            try compute.bind(&guard, &pass);
            try pass.dispatch(.{});
            try pass.end();
            try encoder.copyBufferToBuffer(.{ .source = try output.ref(&guard), .destination = try readback.ref(&guard), .destination_offset = index * 16, .size = 16 });
        }
        try encoder.copyBufferToBuffer(.{ .source = try arguments.ref(&guard), .destination = try readback.ref(&guard), .destination_offset = 128, .size = input.len });
    }
    try f.submit(&encoder);
    try f.device.mapBuffer(io, readback, .{
        .mode = .{ .read = true },
        .size = 128 + input.len,
    });
    defer f.device.unmapBuffer(io, readback) catch @panic("indirect dispatch vectors unmap");
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
    defer guard.unlock(io);
    const bytes = try readback.native.getConstMappedRange(0, 128 + input.len);
    for (vectors, 0..) |vector, index| {
        const expected: [3]u32 = if (vector[0] <= 3 and vector[1] <= 4 and vector[2] <= 5)
            vector
        else
            @splat(0);
        for (expected, 0..) |word, axis| try t.expectEqual(word, getWord(bytes, index * 16 + axis * 4));
        try expectPadding(bytes[index * 16 + 12 ..][0..4]);
    }
    try t.expectEqualSlices(u8, &input, bytes[128..]);
}

fn crossingDispatchConsumer(f: *Fixture, offset: usize) !void {
    const io = f.threaded.io();
    const arguments = try f.buffer(512, .{ .indirect = true, .copy_src = true, .copy_dst = true });
    defer f.release(arguments);
    const output = try f.buffer(4, .{ .storage = true, .copy_src = true, .copy_dst = true });
    defer f.release(output);
    const readback = try f.buffer(520, .{ .map_read = true, .copy_dst = true });
    defer f.release(readback);
    const bindings = [_]*native.Buffer{output};
    var compute = try Compute.init(f, &consume_words, "main", &bindings, 0, 0);
    defer compute.deinit(f);
    var input: [512]u8 = @splat(sentinel);
    putWords(&input, offset, &.{ 2, 3, 4 });
    var encoder = Encoder.init(gpa, f.device.coreDevice().borrow(), .{});
    defer f.deinitEncoder(&encoder);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        try encoder.writeBuffer(.{ .buffer = try arguments.ref(&guard), .data = &input });
        try encoder.writeBuffer(.{ .buffer = try output.ref(&guard), .data = &.{ 0, 0, 0, 0 } });
        const padding: [520]u8 = @splat(sentinel);
        try encoder.writeBuffer(.{ .buffer = try readback.ref(&guard), .data = &padding });
        var pass = try encoder.beginComputePass(.{});
        defer pass.deinit();
        try compute.bind(&guard, &pass);
        try pass.dispatchIndirect(.{ .buffer = try arguments.ref(&guard), .buffer_size = 512, .offset = offset, .usage = (api.BufferUsage{ .indirect = true }).toFlags() });
        try pass.dispatch(.{});
        try pass.end();
        try encoder.copyBufferToBuffer(.{ .source = try output.ref(&guard), .destination = try readback.ref(&guard), .size = 4 });
        try encoder.copyBufferToBuffer(.{ .source = try arguments.ref(&guard), .destination = try readback.ref(&guard), .destination_offset = 8, .size = 512 });
    }
    try f.submit(&encoder);
    try f.device.mapBuffer(io, readback, .{ .mode = .{ .read = true }, .size = 520 });
    defer f.device.unmapBuffer(io, readback) catch @panic("indirect crossing dispatch unmap");
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
    defer guard.unlock(io);
    const bytes = try readback.native.getConstMappedRange(0, 520);
    try t.expectEqual(@as(u32, 25), getWord(bytes, 0));
    try expectPadding(bytes[4..8]);
    try t.expectEqualSlices(u8, &input, bytes[8..520]);
}

fn crossingDrawConsumers(f: *Fixture) !void {
    const io = f.threaded.io();
    const vertex = try f.device.createShaderModule(gpa, io, .{ .words = &vertex_words });
    defer f.release(vertex);
    const fragment = try f.device.createShaderModule(gpa, io, .{ .words = &fragment_words });
    defer f.release(fragment);
    const layout = try f.device.createPipelineLayout(gpa, io, .{ .groups = &.{} });
    defer f.release(layout);
    const pipeline = try f.device.createRenderPipeline(gpa, io, .{
        .layout = layout,
        .vertex = .{ .module = vertex, .entry_point = "main", .stage = .vertex },
        .fragment = .{ .module = fragment, .entry_point = "main", .stage = .fragment },
        .color_targets = &.{.{ .format = .rgba8_unorm }},
    });
    defer f.release(pipeline);
    const target = try f.device.createTexture(gpa, io, .{
        .size = .{ .width = 2, .height = 1, .depth_or_array_layers = 1 },
        .format = .rgba8_unorm,
        .usage = .{ .render_attachment = true, .copy_src = true },
    });
    defer f.release(target);
    const view = try f.device.createTextureView(gpa, io, .{
        .texture = target,
        .descriptor = .{ .format = .rgba8_unorm, .dimension = ._2d },
    });
    defer f.release(view);
    const arguments = try f.buffer(1024, .{ .indirect = true, .copy_src = true, .copy_dst = true });
    defer f.release(arguments);
    const indices = try f.buffer(16, .{ .index = true, .copy_dst = true });
    defer f.release(indices);
    const readback = try f.buffer(1280, .{ .map_read = true, .copy_dst = true });
    defer f.release(readback);
    var input: [1024]u8 = @splat(sentinel);
    for (0..20) |index| putWords(&input, 252 + index * 20, &.{ 0, 1, 0, 0, 0 });
    putWords(&input, 252, &.{ 3, 1, 0, 0, 0 });
    // Slot12 starts at byte240 in tightly packed sanitized output and crosses byte256.
    putWords(&input, 252 + 12 * 20, &.{ 3, 2, 0, 0, 0 });
    var index_bytes: [16]u8 = @splat(0);
    putWords(&index_bytes, 0, &.{ 0, 1, 2 });
    var encoder = Encoder.init(gpa, f.device.coreDevice().borrow(), .{});
    defer f.deinitEncoder(&encoder);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        try encoder.writeBuffer(.{ .buffer = try arguments.ref(&guard), .data = &input });
        try encoder.writeBuffer(.{ .buffer = try indices.ref(&guard), .data = &index_bytes });
        const padding: [1280]u8 = @splat(sentinel);
        try encoder.writeBuffer(.{ .buffer = try readback.ref(&guard), .data = &padding });
    }
    var pass = try f.device.beginRenderPass(gpa, io, &encoder, .{
        .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 } }},
        .width = 2,
        .height = 1,
    });
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        pass.deinit(io, &guard);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
        defer guard.unlock(io);
        try pass.setPipeline(&guard, try pipeline.renderOptions(&guard));
        try pass.setViewport(.{ .width = 2, .height = 1, .min_depth = 0, .max_depth = 1 });
        try pass.setIndexBuffer(.{ .buffer = try indices.ref(&guard), .buffer_size = 16, .format = .uint32, .offset = 0, .size = 12 });
        try pass.setScissorRect(.{ .x = 1, .y = 0, .width = 1, .height = 1 });
        try pass.multiDrawIndexedIndirect(.{ .indirect_buffer = try arguments.ref(&guard), .indirect_buffer_size = 1024, .indirect_offset = 252, .max_draw_count = 20 });
        try pass.setScissorRect(.{ .x = 0, .y = 0, .width = 1, .height = 1 });
        try pass.drawIndexedIndirect(.{ .indirect_buffer = try arguments.ref(&guard), .indirect_buffer_size = 1024, .indirect_offset = 252 });
        try pass.end(io, &guard);
        try encoder.copyTextureToBuffer(.{
            .source = .{ .texture = target, .format = @backingInt(api.TextureFormat.rgba8_unorm), .dimension = ._2d, .aspect = .all, .extent = .{ .width = 2, .height = 1, .depth_or_array_layers = 1 } },
            .destination = .{ .buffer = try readback.ref(&guard), .blocks_per_row = 64, .rows_per_image = 1 },
            .copy_size = .{ .width = 2, .height = 1, .depth_or_array_layers = 1 },
        });
        try encoder.copyBufferToBuffer(.{ .source = try arguments.ref(&guard), .destination = try readback.ref(&guard), .destination_offset = 256, .size = 1024 });
    }
    try f.submit(&encoder);
    try f.device.mapBuffer(io, readback, .{ .mode = .{ .read = true }, .size = 1280 });
    defer f.device.unmapBuffer(io, readback) catch @panic("indirect crossing draw unmap");
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().arena.objectList());
    defer guard.unlock(io);
    const bytes = try readback.native.getConstMappedRange(0, 1280);
    try t.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, bytes[0..8]);
    try expectPadding(bytes[8..256]);
    try t.expectEqualSlices(u8, &input, bytes[256..1280]);
}
