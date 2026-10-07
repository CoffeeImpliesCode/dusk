//! Sampler identity, native rollback, and actual GPU sampling after user release.
const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const engine = dusk.engine;
const core = dusk.core;
const sampler = engine.sampler;
const t = std.testing;
const gpa = t.allocator;

test "sampler semantic identity excludes labels and normalizes signed zero" {
    const base = try sampler.semanticKey(.{ .compare = .undefined_ });
    const alias = try sampler.semanticKey(.{
        .label = "not identity",
        .compare = .undefined_,
        .lod_min_clamp = -0.0,
    });
    try t.expect(base.eql(alias));
    try t.expectEqual(base.hash(), alias.hash());
    inline for (.{
        .{ "address_mode_u", api.AddressMode.repeat },
        .{ "address_mode_v", api.AddressMode.repeat },
        .{ "address_mode_w", api.AddressMode.mirror_repeat },
        .{ "mag_filter", api.FilterMode.linear },
        .{ "min_filter", api.FilterMode.linear },
        .{ "mipmap_filter", api.MipmapFilterMode.linear },
        .{ "lod_min_clamp", @as(f32, 1) },
        .{ "lod_max_clamp", @as(f32, 16) },
        .{ "compare", api.CompareFunction.never },
    }) |change| {
        var descriptor: api.descriptors.SamplerDescriptorChain = .{ .compare = .undefined_ };
        @field(descriptor, change[0]) = change[1];
        try t.expect(!base.eql(try sampler.semanticKey(descriptor)));
    }
    const anisotropic = try sampler.semanticKey(.{
        .compare = .undefined_,
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_filter = .linear,
        .max_anisotropy = 2,
    });
    var isotropic = anisotropic;
    isotropic.max_anisotropy = 1;
    try t.expect(!anisotropic.eql(isotropic));
    var conversion = base;
    conversion.y_cb_cr = .{};
    try t.expect(!base.eql(conversion));
    inline for (@typeInfo(api.descriptors.YCbCrVkDescriptor).@"struct".fields) |field| {
        var changed = conversion;
        const value = &@field(changed.y_cb_cr.?, field.name);
        switch (@typeInfo(field.type)) {
            .bool => value.* = true,
            .@"enum" => value.* = .linear,
            .int => value.* = 1,
            else => @compileError("uncovered conversion field"),
        }
        try t.expect(!conversion.eql(changed));
    }
    try t.expectError(error.SamplerLodClampNotFinite, sampler.semanticKey(.{
        .compare = .undefined_,
        .lod_max_clamp = std.math.inf(f32),
    }));
    try t.expectError(error.SamplerLodClampNotFinite, sampler.semanticKey(.{
        .compare = .undefined_,
        .lod_min_clamp = std.math.nan(f32),
    }));
}

const Fixture = struct {
    instance: engine.Instance = undefined,
    adapters: engine.AdapterList = undefined,
    device: engine.Device = undefined,
    io: std.Io = undefined,
    fn init(self: *Fixture) !void {
        try self.initIo(t.io);
    }
    fn initIo(self: *Fixture, io: std.Io) !void {
        self.io = io;
        self.instance = engine.Instance.init(.{ .backend_type = .vulkan });
        errdefer self.instance.deinit(gpa, io) catch @panic("instance rollback");
        self.adapters = try self.instance.enumerateAdapters(gpa, io, .{
            .backend_type = .vulkan,
            .feature_level = .core,
            .power_preference = .undefined_,
        });
        errdefer self.adapters.deinit(io) catch @panic("adapter rollback");
        if (self.adapters.items.len == 0) return error.NoPhysicalDevice;
        self.device = try self.adapters.items[0].createDevice(gpa, io, .{
            .adapter = &self.adapters.items[0],
            .feature_level = .core,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
    }
    fn uncaptured(_: std.mem.Allocator, _: std.Io, _: *anyopaque, _: core.ErrorView) void {
        @panic("unexpected sampler device error");
    }
    fn deinit(self: *Fixture) void {
        self.device.deinit(gpa, self.io) catch @panic("device teardown");
        self.adapters.deinit(self.io) catch @panic("adapter teardown");
        self.instance.deinit(gpa, self.io) catch @panic("instance teardown");
    }
};

test "native sampler aliases prune weak membership on final user release" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const first = try f.device.createSampler(gpa, t.io, .{ .compare = .undefined_ });
    {
        defer f.device.release(gpa, t.io, first) catch @panic("first sampler release");
        {
            const alias = try f.device.createSampler(gpa, t.io, .{
                .label = "alias",
                .compare = .undefined_,
                .lod_min_clamp = -0.0,
            });
            defer f.device.release(gpa, t.io, alias) catch @panic("alias sampler release");
            try t.expectEqual(first, alias);
            try t.expect(first.native.?.sampler != null);
            try t.expectEqual(@as(u32, 2), first.header.user_reference_count);
        }
        try t.expectEqual(@as(u32, 1), first.header.user_reference_count);
    }
    try t.expectEqual(@as(@TypeOf(first.header.state), .destroyed), first.header.state);
    try t.expectEqual(@as(?*sampler.Sampler, null), first.cache_next);
    const fresh = try f.device.createSampler(gpa, t.io, .{ .compare = .undefined_ });
    defer f.device.release(gpa, t.io, fresh) catch @panic("sampler release");
    try t.expect(first != fresh);
}

const SamplerRace = struct {
    fixture: *Fixture,
    entered: std.Io.Event = .unset,
    result: ?*sampler.Sampler = null,
    failure: ?anyerror = null,

    fn run(self: *SamplerRace) void {
        const io = self.fixture.io;
        self.fixture.device.acquireOperation(io) catch |err| {
            self.failure = err;
            self.entered.set(io);
            return;
        };
        defer self.fixture.device.releaseOperation(io);
        self.entered.set(io);
        self.result = self.fixture.device.createSampler(gpa, io, .{
            .compare = .undefined_,
        }) catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "two actual native concurrent sampler misses publish one owner and two aliases" {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var f: Fixture = .{};
    try f.initIo(io);
    defer f.deinit();
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.coreDevice().borrow().objectList());
    var locked = true;
    defer if (locked) guard.unlock(io);
    try f.device.bindObjectsLocked(&guard, gpa);
    const before = f.device.native.?.native_device.sampler_allocation_count;
    var first: SamplerRace = .{ .fixture = &f };
    var second: SamplerRace = .{ .fixture = &f };
    const first_thread = try std.Thread.spawn(.{}, SamplerRace.run, .{&first});
    var first_joined = false;
    defer {
        if (locked) {
            guard.unlock(io);
            locked = false;
        }
        if (!first_joined) first_thread.join();
        if (first.result) |owned| f.device.release(gpa, io, owned) catch @panic("first race alias release");
    }
    const second_thread = try std.Thread.spawn(.{}, SamplerRace.run, .{&second});
    var second_joined = false;
    defer {
        if (locked) {
            guard.unlock(io);
            locked = false;
        }
        if (!second_joined) second_thread.join();
        if (second.result) |owned| f.device.release(gpa, io, owned) catch @panic("second race alias release");
    }
    first.entered.waitUncancelable(io);
    second.entered.waitUncancelable(io);
    guard.unlock(io);
    locked = false;
    first_thread.join();
    first_joined = true;
    second_thread.join();
    second_joined = true;
    if (first.failure) |err| return err;
    if (second.failure) |err| return err;
    const original = first.result orelse return error.TestUnexpectedResult;
    const alias = second.result orelse return error.TestUnexpectedResult;
    try t.expect(original == alias);
    var inspect = core.ObjectGuard.lockUncancelable(io, original.header.tracking);
    defer inspect.unlock(io);
    try t.expect(original.native.?.sampler != null);
    try t.expectEqual(@as(u32, 2), original.header.user_reference_count);
    try t.expectEqual(before + 1, f.device.native.?.native_device.sampler_allocation_count);
}

test "bind group and pending GPU work retain sampler after every sampler user releases" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const shader_bytes align(4) = @embedFile("fixtures/native_sampler.comp.spv").*;
    const words: []const u32 = std.mem.bytesAsSlice(u32, &shader_bytes);
    const module = try f.device.createShaderModule(gpa, t.io, .{ .words = words });
    defer f.device.release(gpa, t.io, module) catch @panic("module release");
    const layout = try f.device.createBindGroupLayout(gpa, t.io, .{ .entries = &.{
        .{ .binding_number = 0, .visibility = .{ .compute = true }, .kind = .{ .sampled_texture = .{ .sample_type = .float_filterable, .view_dimension = .two_d, .multisampled = false } } },
        .{ .binding_number = 1, .visibility = .{ .compute = true }, .kind = .{ .sampler = .{ .binding_type = .filtering } } },
        .{ .binding_number = 2, .visibility = .{ .compute = true }, .kind = .{ .buffer = .{ .binding_type = .storage, .has_dynamic_offset = false, .min_binding_size = 16 } } },
    } });
    defer f.device.release(gpa, t.io, layout) catch @panic("layout release");
    const pipeline_layout = try f.device.createPipelineLayout(gpa, t.io, .{ .groups = &.{layout} });
    defer f.device.release(gpa, t.io, pipeline_layout) catch @panic("pipeline layout release");
    const pipeline = try f.device.createComputePipeline(gpa, t.io, .{
        .layout = pipeline_layout,
        .compute = .{ .module = module, .entry_point = "main", .stage = .compute },
    });
    defer f.device.release(gpa, t.io, pipeline) catch @panic("pipeline release");
    const image = try f.device.createTexture(gpa, t.io, .{
        .size = .{ .width = 2, .height = 1, .depth_or_array_layers = 1 },
        .format = .rgba8_unorm,
        .usage = .{ .copy_dst = true, .texture_binding = true },
    });
    defer f.device.release(gpa, t.io, image) catch @panic("image release");
    const view = try f.device.createTextureView(gpa, t.io, .{
        .texture = image,
        .descriptor = .{ .format = .rgba8_unorm, .dimension = ._2d },
    });
    defer f.device.release(gpa, t.io, view) catch @panic("view release");
    const output = try f.device.createBuffer(gpa, t.io, .{
        .size = 16,
        .usage = .{ .storage = true, .copy_src = true },
    });
    defer f.device.release(gpa, t.io, output) catch @panic("output release");
    const readback = try f.device.createBuffer(gpa, t.io, .{
        .size = 32,
        .usage = .{ .copy_dst = true, .map_read = true },
        .mapped_at_creation = true,
    });
    defer f.device.release(gpa, t.io, readback) catch @panic("readback release");
    {
        var guard = core.ObjectGuard.lockUncancelable(t.io, readback.header.tracking);
        defer guard.unlock(t.io);
        @memset(try readback.native.getMappedRange(0, 32), 0xa5);
    }
    try f.device.unmapBuffer(t.io, readback);
    const upload = try f.device.createBuffer(gpa, t.io, .{
        .size = 256,
        .usage = .{ .copy_src = true },
        .mapped_at_creation = true,
    });
    defer f.device.release(gpa, t.io, upload) catch @panic("upload release");
    {
        var guard = core.ObjectGuard.lockUncancelable(t.io, upload.header.tracking);
        defer guard.unlock(t.io);
        const bytes = try upload.native.getMappedRange(0, 256);
        @memset(bytes, 0xa5);
        @memcpy(bytes[0..8], &[_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 });
    }
    try f.device.unmapBuffer(t.io, upload);
    var source: *sampler.Sampler = undefined;
    const group = block: {
        source = try f.device.createSampler(gpa, t.io, .{
            .compare = .undefined_,
            .min_filter = .linear,
            .mag_filter = .linear,
        });
        defer f.device.release(gpa, t.io, source) catch @panic("source sampler release");
        const alias = try f.device.createSampler(gpa, t.io, .{
            .compare = .undefined_,
            .min_filter = .linear,
            .mag_filter = .linear,
            .label = "released alias",
        });
        defer f.device.release(gpa, t.io, alias) catch @panic("source alias release");
        break :block try f.device.createBindGroup(gpa, t.io, .{
            .layout = pipeline_layout,
            .group_index = 0,
            .bindings = &.{
                .{ .texture = .{ .binding = 0, .view = view, .stages = .{ .compute = true } } },
                .{ .sampler = .{ .binding = 1, .sampler = source } },
                .{ .buffer = .{ .binding = 2, .buffer = output, .offset = 0, .size = 16, .kind = .storage, .stages = .{ .compute = true } } },
            },
        });
    };
    var group_user: ?*engine.native_resources.BindGroup = group;
    defer if (group_user) |owned| f.device.release(gpa, t.io, owned) catch @panic("group release");
    try t.expectEqual(@as(u32, 0), source.header.user_reference_count);
    try t.expectEqual(@as(@TypeOf(source.header.state), .alive), source.header.state);
    var encoder = dusk.command.command_encoder.CommandEncoder.init(
        gpa,
        f.device.coreDevice().borrow(),
        .{},
    );
    defer {
        var guard = core.ObjectGuard.lockUncancelable(t.io, image.header.tracking);
        defer guard.unlock(t.io);
        encoder.deinit(gpa, t.io, &guard);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(t.io, image.header.tracking);
        defer guard.unlock(t.io);
        try encoder.copyBufferToTexture(.{
            .source = .{ .buffer = try upload.ref(&guard), .blocks_per_row = 64, .rows_per_image = 1 },
            .destination = .{ .texture = image, .format = @intFromEnum(api.TextureFormat.rgba8_unorm), .dimension = ._2d, .aspect = .all, .extent = .{ .width = 2, .height = 1, .depth_or_array_layers = 1 } },
            .copy_size = .{ .width = 2, .height = 1, .depth_or_array_layers = 1 },
        });
        var pass = try encoder.beginComputePass(.{});
        defer pass.deinit();
        try pass.setPipeline(.{ .pipeline = try pipeline.ref(&guard), .requirements = .{
            .bind_group_layout_mask = 1,
            .bind_group_layout_ids = .{ @intFromPtr(&layout.header), 0, 0, 0 },
        } });
        try pass.setBindGroup(.{
            .index = 0,
            .group = try group.ref(&guard),
            .layout_id = @intFromPtr(&layout.header),
            .min_binding_buffer_size = 16,
            .buffers = &.{.{ .buffer = try output.ref(&guard), .usage = (api.BufferUsage{ .storage = true }).toFlags() }},
            .textures = &.{.{ .texture = image, .mip_level = 0, .array_layer = 0, .aspect = .all, .usage = (api.TextureUsage{ .texture_binding = true }).toFlags(), .shader_stages = (api.ShaderStage{ .compute = true }).toFlags() }},
        });
        try pass.dispatch(.{});
        try pass.end();
        try encoder.copyBufferToBuffer(.{
            .source = try output.ref(&guard),
            .destination = try readback.ref(&guard),
            .size = 16,
        });
    }
    var finished = try encoder.finish();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(t.io, image.header.tracking);
        defer guard.unlock(t.io);
        finished.deinit(gpa, t.io, &guard);
    }
    const serial = try f.device.submit(gpa, t.io, &finished);
    try f.device.release(gpa, t.io, group);
    group_user = null;
    try t.expectEqual(@as(@TypeOf(source.header.state), .alive), source.header.state);
    try f.device.wait(t.io, serial);
    {
        f.device.native.?.queue_operation_mutex.lockUncancelable(t.io);
        defer f.device.native.?.queue_operation_mutex.unlock(t.io);
        var guard = core.ObjectGuard.lockUncancelable(t.io, readback.header.tracking);
        defer guard.unlock(t.io);
        const generation = try readback.native.beginMap(.{ .mode = .{ .read = true }, .size = 32 });
        try t.expectEqual(engine.buffer.Buffer.MapCompletion.mapped, try readback.native.completeMap(generation, serial));
        const bytes = try readback.native.getConstMappedRange(0, 32);
        // UNORM8 stores c/(2^8-1); check the midpoint within one source quantum.
        // Fixed-function sampling precision can be limited by the texel format:
        // https://docs.vulkan.org/spec/latest/chapters/fundamentals.html#fundamentals-numerics
        // This rejects nearest filtering (0 or 1), while G=0 and A=1 stay exact.
        const unorm8_quantum: f32 = 1.0 / 255.0;
        const expected = [_]f32{ 0.5, 0, 0.5, 1 };
        for (expected, 0..) |component, index| {
            const word: *const [4]u8 = @ptrCast(bytes[index * 4 ..][0..4].ptr);
            const actual: f32 = @bitCast(std.mem.readInt(u32, word, .little));
            if (index == 0 or index == 2) {
                try t.expectApproxEqAbs(component, actual, unorm8_quantum);
            } else {
                try t.expectEqual(component, actual);
            }
        }
        for (bytes[16..]) |canary| try t.expectEqual(@as(u8, 0xa5), canary);
    }
    try f.device.unmapBuffer(t.io, readback);
    try t.expectEqual(@as(@TypeOf(source.header.state), .destroyed), source.header.state);
}

fn createSamplerFailN(allocator: std.mem.Allocator, native: *engine.vulkan_device.Device) !void {
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(allocator, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(t.io, arena.objectList());
    defer guard.unlock(t.io);
    defer arena.deinit(allocator, &guard) catch @panic("fail-N arena teardown");
    const backend = sampler.NativeBackend.fromDevice(native);
    const before = native.handles.totalCount();
    defer t.expectEqual(before, native.handles.totalCount()) catch @panic("fail-N native leak");
    const owned = try sampler.Sampler.createNative(allocator, t.io, &guard, &arena, backend, .{
        .label = "fail-N native sampler",
        .compare = .undefined_,
    });
    defer owned.header.releaseUserLocked(&guard, t.io) catch @panic("fail-N sampler release");
    try t.expect(owned.native.?.sampler != null);
    try t.expectEqual(@as(u32, 1), owned.header.reference_count);
    try t.expectEqual(@as(u32, 1), owned.header.user_reference_count);
}

test "real native sampler allocation failure rolls back host references and native handles" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try t.checkAllAllocationFailures(gpa, createSamplerFailN, .{&f.device.native.?.native_device});
}

test "native sampler cleanup refusal preserves handle and reports the exact failure" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var procs = f.device.native.?.native_device.procs.*;
    var backend = sampler.NativeBackend.fromDevice(&f.device.native.?.native_device);
    backend.procs = &procs;
    var native = try sampler.NativePayload.create(backend, try sampler.semanticKey(.{ .compare = .undefined_ }));
    defer native.destroy() catch @panic("sampler cleanup retry failed");
    const destroy_sampler = procs.destroy_sampler;
    procs.destroy_sampler = null;
    try t.expectError(error.MissingDeviceProc, native.destroy());
    try t.expect(native.sampler != null);
    procs.destroy_sampler = destroy_sampler;
}

test "native sampler rejects unsupported anisotropy and YCbCr without creating handles" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var backend = sampler.NativeBackend.fromDevice(&f.device.native.?.native_device);
    const before = backend.handles.totalCount();
    backend.anisotropy_enabled = false;
    try t.expectError(error.SamplerAnisotropyUnsupported, sampler.NativePayload.create(backend, try sampler.semanticKey(.{ .compare = .undefined_, .min_filter = .linear, .mag_filter = .linear, .mipmap_filter = .linear, .max_anisotropy = 2 })));
    backend.y_cb_cr_enabled = false;
    try t.expectError(error.SamplerYCbCrUnsupported, sampler.NativePayload.create(backend, try sampler.semanticKey(.{ .compare = .undefined_, .y_cb_cr_vk_descriptor = .{} })));
    try t.expectEqual(before, backend.handles.totalCount());
}

test "native sampler preserves each ordinary semantic distinction in canonical identity" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const base = try f.device.createSampler(gpa, t.io, .{ .compare = .undefined_ });
    defer f.device.release(gpa, t.io, base) catch @panic("base sampler release");
    inline for (.{
        .{ "address_mode_u", api.AddressMode.repeat },
        .{ "address_mode_v", api.AddressMode.repeat },
        .{ "address_mode_w", api.AddressMode.mirror_repeat },
        .{ "mag_filter", api.FilterMode.linear },
        .{ "min_filter", api.FilterMode.linear },
        .{ "mipmap_filter", api.MipmapFilterMode.linear },
        .{ "lod_min_clamp", @as(f32, 1) },
        .{ "lod_max_clamp", @as(f32, 16) },
        .{ "compare", api.CompareFunction.never },
    }) |change| {
        var descriptor: api.descriptors.SamplerDescriptorChain = .{ .compare = .undefined_ };
        @field(descriptor, change[0]) = change[1];
        const distinct = try f.device.createSampler(gpa, t.io, descriptor);
        defer f.device.release(gpa, t.io, distinct) catch @panic("distinct sampler release");
        try t.expect(base != distinct);
        try t.expect(!base.key.eql(distinct.key));
        try t.expect(base.native.?.sampler != distinct.native.?.sampler);
    }
    const zero = try f.device.createSampler(gpa, t.io, .{
        .compare = .undefined_,
        .lod_min_clamp = 0.0,
        .lod_max_clamp = 0.0,
    });
    defer f.device.release(gpa, t.io, zero) catch @panic("zero sampler release");
    const signed_zero = try f.device.createSampler(gpa, t.io, .{
        .compare = .undefined_,
        .lod_min_clamp = -0.0,
        .lod_max_clamp = -0.0,
    });
    defer f.device.release(gpa, t.io, signed_zero) catch @panic("signed zero sampler release");
    try t.expectEqual(zero, signed_zero);
    var anisotropy_descriptor: api.descriptors.SamplerDescriptorChain = .{
        .compare = .undefined_,
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_filter = .linear,
        .max_anisotropy = 2,
    };
    const native_device = &f.device.native.?.native_device;
    if (native_device.enabled_features.samplerAnisotropy != 0 and
        native_device.physical.properties.limits.maxSamplerAnisotropy >= 2)
    {
        const anisotropic = try f.device.createSampler(gpa, t.io, anisotropy_descriptor);
        defer f.device.release(gpa, t.io, anisotropic) catch @panic("anisotropic sampler release");
        anisotropy_descriptor.max_anisotropy = 1;
        const isotropic = try f.device.createSampler(gpa, t.io, anisotropy_descriptor);
        defer f.device.release(gpa, t.io, isotropic) catch @panic("isotropic sampler release");
        try t.expect(anisotropic != isotropic);
    }
}

test "native conversion ownership reflects actual enabled device and format support" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const native_device = &f.device.native.?.native_device;
    const backend = sampler.NativeBackend.fromDevice(native_device);
    const before = backend.handles.totalCount();
    defer t.expectEqual(before, backend.handles.totalCount()) catch @panic("conversion handle leak");
    if (!native_device.sampler_y_cb_cr_enabled) {
        try t.expectError(error.SamplerYCbCrUnsupported, sampler.NativePayload.create(backend, try sampler.semanticKey(.{ .compare = .undefined_, .y_cb_cr_vk_descriptor = .{
            .vk_format = 1000156002,
        } })));
        return;
    }
    if (try supportedConversionKey(backend)) |key| {
        var payload = try sampler.NativePayload.create(backend, key);
        defer payload.destroy() catch @panic("conversion release");
        try t.expect(payload.sampler != null);
        try t.expect(payload.conversion != null);
        try t.expectEqual(before + 2, backend.handles.totalCount());
    } else {
        try t.expectEqual(before, backend.handles.totalCount());
    }
}

test "sampler header destructor saves and reports native cleanup failure" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const Cleanup = struct {
        calls: u32 = 0,
        failure: ?sampler.NativeError = null,
        fn report(raw: *anyopaque, err: sampler.NativeError) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.failure = err;
        }
    };
    var cleanup: Cleanup = .{};
    var procs = f.device.native.?.native_device.procs.*;
    var backend = sampler.NativeBackend.fromDevice(&f.device.native.?.native_device);
    backend.procs = &procs;
    backend.cleanup_context = &cleanup;
    backend.record_cleanup_error = Cleanup.report;
    var mutex: std.Io.Mutex = .init;
    var arena = core.ObjectArena.init(gpa, .{ .object_mutex = &mutex });
    var guard = core.ObjectGuard.lockUncancelable(t.io, arena.objectList());
    defer guard.unlock(t.io);
    defer arena.deinit(gpa, &guard) catch @panic("cleanup arena teardown");
    const owned = try sampler.Sampler.createNative(gpa, t.io, &guard, &arena, backend, .{
        .compare = .undefined_,
    });
    const original = procs.destroy_sampler;
    procs.destroy_sampler = null;
    try owned.header.releaseUserLocked(&guard, t.io);
    try t.expectEqual(@as(u32, 1), cleanup.calls);
    try t.expectEqual(error.MissingDeviceProc, cleanup.failure.?);
    try t.expectEqual(error.MissingDeviceProc, owned.cleanup_error.?);
    try t.expect(owned.native.?.sampler != null);
    procs.destroy_sampler = original;
    try owned.native.?.destroy();
}

test "cache alias reference overflow leaves original sampler and native ownership unchanged" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const owned = try f.device.createSampler(gpa, t.io, .{ .compare = .undefined_ });
    defer f.device.release(gpa, t.io, owned) catch @panic("overflow sampler release");
    const handle = owned.native.?.sampler;
    const native_count = f.device.native.?.native_device.handles.totalCount();
    {
        var guard = core.ObjectGuard.lockUncancelable(t.io, owned.header.tracking);
        defer guard.unlock(t.io);
        owned.header.reference_count = std.math.maxInt(u32);
    }
    defer {
        var guard = core.ObjectGuard.lockUncancelable(t.io, owned.header.tracking);
        defer guard.unlock(t.io);
        owned.header.reference_count = 1;
    }
    try t.expectError(error.ReferenceCountOverflow, f.device.createSampler(gpa, t.io, .{
        .compare = .undefined_,
        .label = "overflow alias",
    }));
    try t.expectEqual(@as(u32, 1), owned.header.user_reference_count);
    try t.expectEqual(handle, owned.native.?.sampler);
    try t.expectEqual(native_count, f.device.native.?.native_device.handles.totalCount());
}

fn supportedConversionKey(backend: sampler.NativeBackend) !?sampler.SemanticKey {
    if (!backend.y_cb_cr_enabled) return null;
    // Core 1.1's complete contiguous conversion-format domain is finite.
    for (1000156000..1000156034) |format| {
        for (0..2) |location| {
            const key = try sampler.semanticKey(.{ .compare = .undefined_, .y_cb_cr_vk_descriptor = .{
                .vk_format = @intCast(format),
                .vk_x_chroma_offset = @intCast(location),
                .vk_y_chroma_offset = @intCast(location),
            } });
            backend.validate(key) catch |err| switch (err) {
                error.SamplerYCbCrFormatUnsupported => continue,
                else => return err,
            };
            return key;
        }
    }
    return null;
}

test "sampler creation failure destroys a real previously created conversion" {
    const vk = dusk.platform.vulkan_bindings;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var procs = f.device.native.?.native_device.procs.*;
    var backend = sampler.NativeBackend.fromDevice(&f.device.native.?.native_device);
    backend.procs = &procs;
    const key = (try supportedConversionKey(backend)) orelse return;
    const before = backend.handles.totalCount();
    const Failure = struct {
        fn create(_: vk.VkDevice, _: [*c]const vk.VkSamplerCreateInfo, _: [*c]const vk.VkAllocationCallbacks, output: [*c]vk.VkSampler) callconv(.c) vk.VkResult {
            // Vulkan error outputs are undefined and must never become owned handles.
            output[0] = @ptrFromInt(0x1000);
            return vk.VK_ERROR_OUT_OF_HOST_MEMORY;
        }
    };
    procs.create_sampler = Failure.create;
    try t.expectError(error.OutOfHostMemory, sampler.NativePayload.create(backend, key));
    try t.expectEqual(before, backend.handles.totalCount());
}

test "retired cached sampler is not reused while its old user alias survives" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const old = try f.device.createSampler(gpa, t.io, .{ .compare = .undefined_ });
    defer f.device.release(gpa, t.io, old) catch @panic("retired sampler release");
    {
        var guard = core.ObjectGuard.lockUncancelable(t.io, old.header.tracking);
        defer guard.unlock(t.io);
        old.header.retirePayloadLocked(&guard, t.io, .early_destroy);
        try t.expectEqual(@as(?*anyopaque, null), old.header.cache_context);
        try t.expectEqual(@as(u32, 1), old.header.user_reference_count);
        try t.expectEqual(@as(@TypeOf(old.native.?.sampler), null), old.native.?.sampler);
    }
    const fresh = try f.device.createSampler(gpa, t.io, .{ .compare = .undefined_ });
    defer f.device.release(gpa, t.io, fresh) catch @panic("fresh sampler release");
    try t.expect(old != fresh);
    var storage: [1024]u8 = undefined;
    var foreign = std.heap.FixedBufferAllocator.init(&storage);
    try t.expectError(error.AllocatorMismatch, f.device.createSampler(foreign.allocator(), t.io, .{
        .compare = .undefined_,
        .label = "wrong allocator alias",
    }));
    try t.expectEqual(@as(u32, 1), fresh.header.user_reference_count);
}

test "core-only sampler is fully initialized metadata with no native ownership" {
    var mutex: std.Io.Mutex = .init;
    var context: u8 = 0;
    var device = core.Device.init(gpa, .{
        .object_mutex = &mutex,
        .uncaptured_context = &context,
        .uncaptured_callback = Fixture.uncaptured,
    });
    var guard = core.ObjectGuard.lockUncancelable(t.io, device.borrow().objectList());
    defer guard.unlock(t.io);
    defer device.deinit(gpa, &guard) catch @panic("core sampler teardown");
    const handle = try sampler.Sampler.create(gpa, t.io, &guard, &device, .{
        .compare = .undefined_,
        .lod_min_clamp = -0.0,
    });
    const metadata = try sampler.resolveSampler(&device, &guard, handle);
    defer metadata.header.releaseUserLocked(&guard, t.io) catch @panic("metadata release");
    try t.expect(metadata.native == null);
    try t.expectEqual(@as(?sampler.NativeError, null), metadata.cleanup_error);
    try t.expectEqual(@as(u64, 0), metadata.cache_hash);
    try t.expectEqual(@as(?*sampler.Sampler, null), metadata.cache_next);
    try t.expectEqual(@as(?*anyopaque, null), metadata.header.cache_context);
    try t.expect(metadata.key.eql(try sampler.semanticKey(.{ .compare = .undefined_ })));
    try t.expectEqual(@as(u32, 0), @as(u32, @bitCast(metadata.lod_min_clamp)));
    try t.expectEqual(api.SamplerBindingType.non_filtering, metadata.bindingType(&guard));
}

test "native sampler allocation limit admits cached aliases but refuses distinct native creation" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const native_device = &f.device.native.?.native_device;
    const original_limit = native_device.physical.properties.limits.maxSamplerAllocationCount;
    {
        var guard = core.ObjectGuard.lockUncancelable(t.io, f.device.core.arena.objectList());
        defer guard.unlock(t.io);
        try t.expectEqual(@as(u32, 0), native_device.sampler_allocation_count);
        native_device.physical.properties.limits.maxSamplerAllocationCount = 1;
    }
    defer {
        var guard = core.ObjectGuard.lockUncancelable(t.io, f.device.core.arena.objectList());
        defer guard.unlock(t.io);
        native_device.physical.properties.limits.maxSamplerAllocationCount = original_limit;
    }
    var old: *sampler.Sampler = undefined;
    {
        old = try f.device.createSampler(gpa, t.io, .{ .compare = .undefined_ });
        defer f.device.release(gpa, t.io, old) catch @panic("limited sampler release");
        const alias = try f.device.createSampler(gpa, t.io, .{
            .compare = .undefined_,
            .label = "alias at native limit",
        });
        defer f.device.release(gpa, t.io, alias) catch @panic("limited alias release");
        try t.expectEqual(old, alias);
        try t.expectEqual(@as(u32, 1), native_device.sampler_allocation_count);
        const handles_before = native_device.handles.totalCount();
        try t.expectError(error.TooManyObjects, f.device.createSampler(gpa, t.io, .{
            .compare = .undefined_,
            .address_mode_u = .repeat,
        }));
        try t.expectEqual(handles_before, native_device.handles.totalCount());
        try t.expectEqual(@as(u32, 1), native_device.sampler_allocation_count);
    }
    try t.expectEqual(@as(u32, 0), native_device.sampler_allocation_count);
    const fresh = try f.device.createSampler(gpa, t.io, .{ .compare = .undefined_ });
    defer f.device.release(gpa, t.io, fresh) catch @panic("limited fresh release");
    try t.expect(fresh != old);
    try t.expectEqual(@as(u32, 1), native_device.sampler_allocation_count);
}
