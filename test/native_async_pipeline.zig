//! Real Vulkan pipeline creation through generated callbacks and native observers.
const std = @import("std");
const dusk = @import("dusk");
const api = dusk.api;
const core = dusk.core;
const engine = dusk.engine;
const operators = engine.native_async_pipeline;
const handles = engine.native_async_handles;
const root = engine.async_root_requests;
const fixture = @import("fixtures/workgroup_compute.zig");
const graphics = @import("fixtures/specialization_graphics.zig");
const t = std.testing;
const gpa = t.allocator;

const Fixture = struct {
    threaded: std.Io.Threaded = undefined,
    source: engine.async_registry.FutureNamespaceSource = .init(),
    instance: engine.Instance = undefined,
    adapters: engine.AdapterList = undefined,
    device: engine.Device = undefined,
    allocator: std.mem.Allocator = gpa,
    uncaptured_count: usize = 0,

    fn init(self: *Fixture) !void {
        try self.initAllocator(gpa);
    }
    fn initAllocator(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.* = .{ .allocator = allocator };
        self.threaded = .init(gpa, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.instance = engine.Instance.init(.{ .backend_type = .vulkan, .future_namespace_source = &self.source, .root_worker_count = 2 });
        errdefer self.instance.deinit(allocator, io) catch @panic("instance rollback");
        self.adapters = try self.instance.enumerateAdapters(allocator, io, .{
            .backend_type = .vulkan,
            .feature_level = .core,
            .power_preference = .undefined_,
        });
        errdefer self.adapters.deinit(io) catch @panic("adapter rollback");
        if (self.adapters.items.len == 0) return error.NoPhysicalDevice;
        self.device = try self.adapters.items[0].createDevice(allocator, io, .{
            .adapter = &self.adapters.items[0],
            .feature_level = .core,
            .uncaptured_context = self,
            .uncaptured_callback = uncaptured,
        });
        errdefer self.device.deinit(allocator, io) catch @panic("device rollback");
        _ = try engine.native_async_device.ensureRegistered(&self.device, allocator, io);
    }
    fn uncaptured(_: std.mem.Allocator, _: std.Io, raw: *anyopaque, _: core.ErrorView) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.uncaptured_count += 1;
    }
    fn drain(self: *Fixture) !void {
        const io = self.threaded.io();
        if (self.device.host_deinitialized) return;
        for (0..10_000) |_| {
            self.device.lifecycle_mutex.lockUncancelable(io);
            const remaining = self.device.active_async_operations;
            self.device.lifecycle_mutex.unlock(io);
            if (remaining == 1) {
                try dusk.platform.WorkerPool.waitForAllTasks(io, &self.instance.root_executor.?.pool, 10_000_000_000);
                return;
            }
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        return error.PipelineDrainExhausted;
    }
    fn deinit(self: *Fixture) void {
        const io = self.threaded.io();
        self.drain() catch @panic("pipeline runners retained");
        self.device.deinit(self.allocator, io) catch @panic("pipeline device teardown");
        self.adapters.deinit(io) catch @panic("pipeline adapters teardown");
        self.instance.deinit(self.allocator, io) catch @panic("pipeline instance teardown");
        self.threaded.deinit();
    }
    fn shader(self: *Fixture, words: []const u32) !*engine.native_resources.ShaderModule {
        return self.device.createShaderModule(self.allocator, self.threaded.io(), .{ .words = words });
    }
    fn exportShader(self: *Fixture, module: *engine.native_resources.ShaderModule) api.ShaderModule {
        var guard = core.ObjectGuard.lockUncancelable(self.threaded.io(), self.device.core.arena.objectList());
        defer guard.unlock(self.threaded.io());
        return handles.exportResource(api.ShaderModule, &self.device, &guard, module, .shader_module);
    }
    fn wait(self: *Fixture, future: api.Future) !void {
        var waits = [_]api.FutureWaitInfo{.{ .future = future }};
        try t.expectEqual(api.WaitStatus.success, try root.waitAny(handles.exportInstance(&self.instance), self.threaded.io(), waits.len, &waits, 10_000_000_000));
        try t.expect(waits[0].completed);
    }
};

const ComputeCall = struct {
    fixture: *Fixture,
    calls: usize = 0,
    status: ?api.CreatePipelineAsyncStatus = null,
    pipeline: ?api.ComputePipeline = null,
    destroy_refused: bool = false,
    reenter: bool = false,
    reentered: bool = false,
    fn invoke(raw: ?*anyopaque, status: api.CreatePipelineAsyncStatus, pipeline: ?api.ComputePipeline, _: []const u8) void {
        const self: *ComputeCall = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.status = status;
        self.pipeline = pipeline;
        self.fixture.device.destroy(self.fixture.allocator, self.fixture.threaded.io()) catch |err| {
            self.destroy_refused = err == error.ResourceInUse;
        };
        if (self.reenter and status == .success) {
            const f = self.fixture;
            const buffer = f.device.createBuffer(f.allocator, f.threaded.io(), .{ .size = 4, .usage = .{ .copy_dst = true } }) catch @panic("callback GPU reentry");
            f.device.release(f.allocator, f.threaded.io(), buffer) catch @panic("callback reentry release");
            self.reentered = true;
        }
    }
    fn info(self: *ComputeCall, mode: api.CallbackMode) api.CreateComputePipelineAsyncCallbackInfo {
        return .{ .mode = mode, .callback = invoke, .userdata = self };
    }
    fn successHandle(self: *const ComputeCall) !api.ComputePipeline {
        try t.expectEqual(@as(?api.CreatePipelineAsyncStatus, .success), self.status);
        return self.pipeline orelse error.MissingComputePipeline;
    }
    fn deinit(self: *ComputeCall, io: std.Io) void {
        if (self.status != .success) return;
        if (self.pipeline) |target| {
            self.pipeline = null;
            operators.releaseComputePipeline(target, io) catch @panic("compute callback alias release");
        }
    }
};

fn compute(module: api.ShaderModule) api.descriptors.ComputePipelineDescriptorChain {
    return .{ .compute = .{ .module = module } };
}

test "native async compute all callback modes preserve owned aliases and callback destroy refusal" {
    for ([_]api.CallbackMode{ .wait_any_only, .allow_process_events, .allow_spontaneous }) |mode| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const io = f.threaded.io();
        const module = try f.shader(&fixture.words);
        const descriptor = compute(f.exportShader(module));
        var call: ComputeCall = .{ .fixture = &f, .reenter = true };
        defer call.deinit(io);
        const canonical: *const api.Device.createComputePipelineAsync = operators.createComputePipelineAsync;
        const future = try canonical(handles.exportDevice(&f.device), gpa, io, &descriptor, call.info(mode));
        try f.device.release(gpa, io, module);
        if (mode == .allow_process_events) {
            for (0..10_000) |_| {
                try root.processEvents(handles.exportInstance(&f.instance), io);
                if (call.calls != 0) break;
                try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            }
            try t.expectEqual(@as(usize, 1), call.calls);
        }
        try f.wait(future);
        try t.expectEqual(@as(usize, 1), call.calls);
        const target = try call.successHandle();
        try t.expect(call.destroy_refused);
        try t.expect(call.reentered);
        const pipeline_header = try handles.resourceHeader(api.ComputePipeline, target, .native_pipeline);
        const actual: *engine.native_resources.Pipeline = @fieldParentPtr("header", pipeline_header);
        try executeCompute(&f, actual, 4, 15);
        call.deinit(io);
        try f.drain();
    }
}

test "native async compute Future and callback share the actual native cache" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const module = try f.shader(&fixture.words);
    defer f.device.release(gpa, io, module) catch @panic("shader release");
    const group_layout = try f.device.createBindGroupLayout(gpa, io, .{ .entries = &.{.{
        .binding_number = 0,
        .visibility = .{ .compute = true },
        .kind = .{ .buffer = .{
            .binding_type = .storage,
            .has_dynamic_offset = false,
            .min_binding_size = 0,
        } },
    }} });
    defer f.device.release(gpa, io, group_layout) catch @panic("compute group layout release");
    const layout = try f.device.createPipelineLayout(gpa, io, .{ .groups = &.{group_layout} });
    defer f.device.release(gpa, io, layout) catch @panic("compute layout release");
    var descriptor = compute(f.exportShader(module));
    {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        // Independent automatic layouts have different compatibility tokens.
        descriptor.layout = handles.exportResource(
            api.PipelineLayout,
            &f.device,
            &guard,
            layout,
            .pipeline_layout,
        );
    }
    var call: ComputeCall = .{ .fixture = &f };
    defer call.deinit(io);
    const callback_future = try operators.createComputePipelineAsync(handles.exportDevice(&f.device), gpa, io, &descriptor, call.info(.wait_any_only));
    var observer = try operators.createComputePipelineFuture(&f.device, gpa, io, &descriptor);
    const result = observer.await(io);
    const owned = switch (result) {
        .success => |pipeline| pipeline,
        .failure => |failure| {
            defer failure.error_ref.release();
            try f.wait(callback_future);
            return error.NativePipelineFailed;
        },
        .cancelled => {
            try f.wait(callback_future);
            return error.NativePipelineCancelled;
        },
    };
    defer f.device.release(gpa, io, owned) catch @panic("native result release");
    try f.wait(callback_future);
    const target = try call.successHandle();
    const header = try handles.resourceHeader(api.ComputePipeline, target, .native_pipeline);
    var guard = core.ObjectGuard.lockUncancelable(io, header.tracking);
    defer guard.unlock(io);
    const callback_owned: *engine.native_resources.Pipeline = @fieldParentPtr("header", header);
    try t.expectEqual(layout, callback_owned.layout);
    try t.expectEqual(layout, owned.layout);
    try t.expectEqual(callback_owned.native, owned.native);
    try t.expect(owned.native.vk_pipeline != null);
}

test "native async semantic failure routes immutable diagnostics to captured scope" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const module = try f.shader(&fixture.words);
    defer f.device.release(gpa, io, module) catch @panic("shader release");
    try f.device.pushErrorScope(gpa, io, .validation);
    var descriptor = compute(f.exportShader(module));
    descriptor.compute.entry_point = "missing";
    var call: ComputeCall = .{ .fixture = &f };
    defer call.deinit(io);
    const future = try operators.createComputePipelineAsync(handles.exportDevice(&f.device), gpa, io, &descriptor, call.info(.wait_any_only));
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
    var ticket = try f.device.core.popErrorScope(&guard);
    guard.unlock(io);
    defer {
        guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        ticket.deinit(&guard);
        guard.unlock(io);
    }
    try f.wait(future);
    try t.expectEqual(@as(?api.CreatePipelineAsyncStatus, .validation_error), call.status);
    try t.expect(call.pipeline == null);
    guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
    var captured = try ticket.take(&guard);
    guard.unlock(io);
    defer captured.deinit();
    try t.expect(captured.error_ref != null);
    try t.expect(captured.error_ref.?.view().message.len != 0);
    try t.expectEqual(@as(usize, 0), f.uncaptured_count);
}

const WorkerGates = struct {
    gates: [2]Gate = .{ .{}, .{} },
    const Gate = struct {
        mutex: std.Io.Mutex = .init,
        entered: std.atomic.Value(bool) = .init(false),
        fn run(io: std.Io, raw: *anyopaque) void {
            const self: *Gate = @ptrCast(@alignCast(raw));
            self.entered.store(true, .release);
            self.mutex.lockUncancelable(io);
            self.mutex.unlock(io);
        }
    };
    fn block(self: *WorkerGates, f: *Fixture) !void {
        const io = f.threaded.io();
        for (&self.gates) |*gate| {
            gate.mutex.lockUncancelable(io);
            try engine.native_async_device.post(&f.device, io, .{ .run = Gate.run, .context = gate });
        }
        for (0..10_000) |_| {
            if (self.gates[0].entered.load(.acquire) and self.gates[1].entered.load(.acquire)) return;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        return error.WorkerGateExhausted;
    }
    fn unblock(self: *WorkerGates, f: *Fixture) void {
        const io = f.threaded.io();
        for (&self.gates) |*gate| gate.mutex.unlock(io);
        dusk.platform.WorkerPool.waitForAllTasks(io, &f.instance.root_executor.?.pool, 10_000_000_000) catch
            @panic("worker gate tasks did not return");
    }
};

test "native observer cancellation preserves accepted work and input snapshot after user shader release" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const module = try f.shader(&fixture.words);
    var gates: WorkerGates = .{};
    try gates.block(&f);
    var blocked = true;
    defer if (blocked) gates.unblock(&f);
    var key = [_]u8{ 'l', 'o', 'c', 'a', 'l', '_', 'x' };
    var constants = [_]api.descriptors.ConstantEntryChain{.{ .key = &key, .value = 3 }};
    var descriptor = compute(f.exportShader(module));
    descriptor.compute.constant_count = 1;
    descriptor.compute.constants = &constants;
    var observer = try operators.createComputePipelineFuture(&f.device, gpa, io, &descriptor);
    var call: ComputeCall = .{ .fixture = &f };
    defer call.deinit(io);
    const future = try operators.createComputePipelineAsync(handles.exportDevice(&f.device), gpa, io, &descriptor, call.info(.wait_any_only));
    const issued = f.instance.completions.?.issued;
    try t.expect(observer.cancel(io) == .cancelled);
    try t.expectEqual(issued, f.instance.completions.?.issued);
    @memset(&key, '!');
    constants[0].value = -1;
    descriptor.compute.entry_point = "invalid after acceptance";
    try f.device.release(gpa, io, module);
    gates.unblock(&f);
    blocked = false;
    try f.wait(future);
    _ = try call.successHandle();
    call.deinit(io);
    try f.drain();
}

test "native pipeline post refusal cancels and joins prepared observer without consuming an ID" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const module = try f.shader(&fixture.words);
    defer f.device.release(gpa, io, module) catch @panic("shader release");
    const descriptor = compute(f.exportShader(module));
    var gates: WorkerGates = .{};
    try gates.block(&f);
    defer gates.unblock(&f);
    const pool = &f.instance.root_executor.?.pool;
    pool.mutex.lockUncancelable(io);
    pool.shutting_down = true;
    pool.mutex.unlock(io);
    defer {
        pool.mutex.lockUncancelable(io);
        pool.shutting_down = false;
        pool.mutex.unlock(io);
    }
    const issued = f.instance.completions.?.issued;
    try t.expectError(error.PoolShutDown, operators.createComputePipelineFuture(&f.device, gpa, io, &descriptor));
    try t.expectEqual(issued, f.instance.completions.?.issued);
    try t.expectEqual(@as(u32, 0), f.instance.completions.?.prepared_cells);
}

test "native pipeline fail-N distinguishes preaccept refusal and accepted immutable OOM" {
    var preaccept = false;
    var accepted_failure = false;
    var success = false;
    for (0..128) |offset| {
        var failing = t.FailingAllocator.init(gpa, .{});
        var f: Fixture = undefined;
        try f.initAllocator(failing.allocator());
        defer f.deinit();
        const io = f.threaded.io();
        const module = try f.shader(&fixture.words);
        defer f.device.release(f.allocator, io, module) catch @panic("shader release");
        const descriptor = compute(f.exportShader(module));
        var call: ComputeCall = .{ .fixture = &f };
        defer call.deinit(io);
        const issued = f.instance.completions.?.issued;
        failing.fail_index = failing.alloc_index + offset;
        const started = operators.createComputePipelineAsync(handles.exportDevice(&f.device), f.allocator, io, &descriptor, call.info(.wait_any_only));
        if (started) |future| {
            try f.wait(future);
            try t.expectEqual(issued + 1, f.instance.completions.?.issued);
            if (call.status == .success) {
                _ = try call.successHandle();
                call.deinit(io);
                success = true;
            } else {
                try t.expectEqual(@as(?api.CreatePipelineAsyncStatus, .internal_error), call.status);
                try t.expect(call.pipeline == null);
                accepted_failure = true;
            }
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(issued, f.instance.completions.?.issued);
            try t.expectEqual(@as(usize, 0), call.calls);
            preaccept = true;
        }
        failing.fail_index = std.math.maxInt(usize);
        try f.drain();
        if (success) break;
    }
    try t.expect(preaccept and accepted_failure and success);
}

const RenderCall = struct {
    pipeline: ?api.RenderPipeline = null,
    status: ?api.CreatePipelineAsyncStatus = null,
    fn invoke(raw: ?*anyopaque, status: api.CreatePipelineAsyncStatus, pipeline: ?api.RenderPipeline, _: []const u8) void {
        const self: *RenderCall = @ptrCast(@alignCast(raw.?));
        self.status = status;
        self.pipeline = pipeline;
    }
    fn successHandle(self: *const RenderCall) !api.RenderPipeline {
        try t.expectEqual(@as(?api.CreatePipelineAsyncStatus, .success), self.status);
        return self.pipeline orelse error.MissingRenderPipeline;
    }
    fn deinit(self: *RenderCall, io: std.Io) void {
        if (self.status != .success) return;
        if (self.pipeline) |target| {
            self.pipeline = null;
            operators.releaseRenderPipeline(target, io) catch @panic("render callback alias release");
        }
    }
};

test "native async render canonical callback and Future retain per-stage specialization" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const vertex = try f.shader(&graphics.vertex_words);
    defer f.device.release(gpa, io, vertex) catch @panic("vertex release");
    const fragment = try f.shader(&graphics.fragment_words);
    defer f.device.release(gpa, io, fragment) catch @panic("fragment release");
    const layout = try f.device.createPipelineLayout(gpa, io, .{ .groups = &.{} });
    defer f.device.release(gpa, io, layout) catch @panic("render layout release");
    const layout_handle = block: {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        break :block handles.exportResource(
            api.PipelineLayout,
            &f.device,
            &guard,
            layout,
            .pipeline_layout,
        );
    };
    const vertex_constants = [_]api.descriptors.ConstantEntryChain{.{ .key = "shift_x", .value = 0.25 }};
    const fragment_constants = [_]api.descriptors.ConstantEntryChain{.{ .key = "green", .value = 1 }};
    const targets = [_]api.descriptors.ColorTargetStateChain{.{ .format = .rgba8_unorm }};
    const fragment_state: api.descriptors.FragmentStateChain = .{
        .module = f.exportShader(fragment),
        .constant_count = 1,
        .constants = &fragment_constants,
        .target_count = 1,
        .targets = &targets,
    };
    const descriptor: api.descriptors.RenderPipelineDescriptorChain = .{
        .layout = layout_handle,
        .vertex = .{ .module = f.exportShader(vertex), .constant_count = 1, .constants = &vertex_constants },
        .primitive = .{ .strip_index_format = .undefined_ },
        .multisample = .{},
        .fragment = &fragment_state,
    };
    var call: RenderCall = .{};
    defer call.deinit(io);
    const canonical: *const api.Device.createRenderPipelineAsync = operators.createRenderPipelineAsync;
    const future = try canonical(handles.exportDevice(&f.device), gpa, io, &descriptor, .{ .mode = .wait_any_only, .callback = RenderCall.invoke, .userdata = &call });
    var observer = try operators.createRenderPipelineFuture(&f.device, gpa, io, &descriptor);
    const owned = switch (observer.await(io)) {
        .success => |pipeline| pipeline,
        .failure => |failure| {
            defer failure.error_ref.release();
            try f.wait(future);
            return error.RenderPipelineFailed;
        },
        .cancelled => {
            try f.wait(future);
            return error.RenderPipelineCancelled;
        },
    };
    defer f.device.release(gpa, io, owned) catch @panic("render native release");
    try f.wait(future);
    const target_handle = try call.successHandle();
    const header = try handles.resourceHeader(api.RenderPipeline, target_handle, .native_pipeline);
    {
        var guard = core.ObjectGuard.lockUncancelable(io, header.tracking);
        defer guard.unlock(io);
        const callback_owned: *engine.native_resources.Pipeline = @fieldParentPtr("header", header);
        try t.expectEqual(layout, callback_owned.layout);
        try t.expectEqual(layout, owned.layout);
        try t.expectEqual(callback_owned.native, owned.native);
        try t.expect(owned.native.vk_pipeline != null);
    }
    const callback_owned: *engine.native_resources.Pipeline = @fieldParentPtr("header", header);
    try executeRender(&f, callback_owned);
    try executeRender(&f, owned);
}

fn executeCompute(f: *Fixture, pipeline: *engine.native_resources.Pipeline, expected_count: u32, expected_coverage: u32) !void {
    const io = f.threaded.io();
    const output = try f.device.createBuffer(gpa, io, .{
        .size = 8,
        .usage = .{ .storage = true, .copy_src = true },
        .mapped_at_creation = true,
    });
    defer f.device.release(gpa, io, output) catch @panic("compute output release");
    {
        var guard = core.ObjectGuard.lockUncancelable(io, output.header.tracking);
        defer guard.unlock(io);
        @memset(try output.native.getMappedRange(0, 8), 0);
    }
    try f.device.unmapBuffer(io, output);
    const readback = try f.device.createBuffer(gpa, io, .{
        .size = 8,
        .usage = .{ .map_read = true, .copy_dst = true },
    });
    defer f.device.release(gpa, io, readback) catch @panic("compute readback release");
    const group = try f.device.createBindGroup(gpa, io, .{
        .layout = pipeline.layout,
        .group_index = 0,
        .bindings = &.{.{ .buffer = .{ .binding = 0, .buffer = output, .offset = 0, .size = 8, .kind = .storage, .stages = .{ .compute = true } } }},
    });
    defer f.device.release(gpa, io, group) catch @panic("compute group release");
    var encoder = dusk.command.command_encoder.CommandEncoder.init(gpa, f.device.core.borrow(), .{});
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(gpa, io, &guard);
    }
    {
        var guard = core.ObjectGuard.lockUncancelable(io, output.header.tracking);
        defer guard.unlock(io);
        var pass = try encoder.beginComputePass(.{});
        defer pass.deinit();
        try pass.setPipeline(.{ .pipeline = try pipeline.ref(&guard), .requirements = .{
            .bind_group_layout_mask = 1,
            .bind_group_layout_ids = .{ @intFromPtr(&pipeline.layout.groups[0].header), 0, 0, 0 },
        } });
        try pass.setBindGroup(.{
            .index = 0,
            .group = try group.ref(&guard),
            .layout_id = @intFromPtr(&pipeline.layout.groups[0].header),
            .min_binding_buffer_size = 8,
            .buffers = &.{.{ .buffer = try output.ref(&guard), .usage = (api.BufferUsage{ .storage = true }).toFlags() }},
        });
        try pass.dispatch(.{});
        try pass.end();
        try encoder.copyBufferToBuffer(.{
            .source = try output.ref(&guard),
            .destination = try readback.ref(&guard),
            .size = 8,
        });
    }
    var finished = try encoder.finish();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(gpa, io, &guard);
    }
    const serial = try f.device.submit(gpa, io, &finished);
    try f.device.wait(io, serial);
    {
        f.device.native.?.queue_operation_mutex.lockUncancelable(io);
        defer f.device.native.?.queue_operation_mutex.unlock(io);
        var guard = core.ObjectGuard.lockUncancelable(io, readback.header.tracking);
        defer guard.unlock(io);
        const generation = try readback.native.beginMap(.{ .mode = .{ .read = true }, .size = 8 });
        try t.expectEqual(engine.buffer.Buffer.MapCompletion.mapped, try readback.native.completeMap(generation, serial));
        const bytes = try readback.native.getConstMappedRange(0, 8);
        try t.expectEqual(expected_count, std.mem.readInt(u32, bytes[0..4], .little));
        try t.expectEqual(expected_coverage, std.mem.readInt(u32, bytes[4..8], .little));
    }
    try f.device.unmapBuffer(io, readback);
}

test "native pipeline Future LocalSize specialization reaches actual GPU readback" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const module = try f.shader(&fixture.words);
    defer f.device.release(gpa, io, module) catch @panic("shader release");
    const constants = [_]api.descriptors.ConstantEntryChain{.{ .key = "local_x", .value = 3 }};
    var descriptor = compute(f.exportShader(module));
    descriptor.compute.constant_count = 1;
    descriptor.compute.constants = &constants;
    var observer = try operators.createComputePipelineFuture(&f.device, gpa, io, &descriptor);
    const owned = switch (observer.await(io)) {
        .success => |pipeline| pipeline,
        .failure => |failure| {
            defer failure.error_ref.release();
            return error.ComputePipelineFailed;
        },
        .cancelled => return error.ComputePipelineCancelled,
    };
    defer f.device.release(gpa, io, owned) catch @panic("native pipeline release");
    try executeCompute(&f, owned, 6, 63);
}

test "native pipeline wait-only delivery can complete second request before first" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const module = try f.shader(&fixture.words);
    defer f.device.release(gpa, io, module) catch @panic("shader release");
    const descriptor = compute(f.exportShader(module));
    var first: ComputeCall = .{ .fixture = &f };
    defer first.deinit(io);
    var second: ComputeCall = .{ .fixture = &f };
    defer second.deinit(io);
    const first_future = try operators.createComputePipelineAsync(handles.exportDevice(&f.device), gpa, io, &descriptor, first.info(.wait_any_only));
    const second_future = try operators.createComputePipelineAsync(handles.exportDevice(&f.device), gpa, io, &descriptor, second.info(.wait_any_only));
    try root.processEvents(handles.exportInstance(&f.instance), io);
    try t.expectEqual(@as(usize, 0), first.calls);
    try t.expectEqual(@as(usize, 0), second.calls);
    try f.wait(second_future);
    const first_calls_before_wait = first.calls;
    const second_calls_before_wait = second.calls;
    try f.wait(first_future);
    try t.expectEqual(@as(usize, 0), first_calls_before_wait);
    try t.expectEqual(@as(usize, 1), second_calls_before_wait);
    try t.expectEqual(@as(usize, 1), first.calls);
    _ = try first.successHandle();
    _ = try second.successHandle();
}

test "native pipeline absent callback route disposes an abandoned late alias without event pumping" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const module = try f.shader(&fixture.words);
    const descriptor = compute(f.exportShader(module));
    var gates: WorkerGates = .{};
    try gates.block(&f);
    var blocked = true;
    defer if (blocked) gates.unblock(&f);
    var observer = try operators.createComputePipelineFuture(&f.device, gpa, io, &descriptor);
    try t.expect(observer.cancel(io) == .cancelled);
    try f.device.release(gpa, io, module);
    gates.unblock(&f);
    blocked = false;
    try f.drain();
    var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
    defer guard.unlock(io);
    try t.expectEqual(@as(u64, 0), f.device.core.arena.objectList().total_reference_count);
}

fn executeRender(f: *Fixture, pipeline: *engine.native_resources.Pipeline) !void {
    const io = f.threaded.io();
    const extent: u32 = 16;
    const target = try f.device.createTexture(gpa, io, .{
        .size = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 },
        .format = .rgba8_unorm,
        .usage = .{ .render_attachment = true, .copy_src = true },
    });
    defer f.device.release(gpa, io, target) catch @panic("render target release");
    const view = try f.device.createTextureView(gpa, io, .{
        .texture = target,
        .descriptor = .{ .format = .rgba8_unorm, .dimension = ._2d },
    });
    defer f.device.release(gpa, io, view) catch @panic("render view release");
    const readback = try f.device.createBuffer(gpa, io, .{
        .size = 256 * extent,
        .usage = .{ .map_read = true, .copy_dst = true },
    });
    defer f.device.release(gpa, io, readback) catch @panic("render readback release");
    var encoder = dusk.command.command_encoder.CommandEncoder.init(gpa, f.device.core.borrow(), .{});
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        encoder.deinit(gpa, io, &guard);
    }
    {
        var pass = try f.device.beginRenderPass(gpa, io, &encoder, .{
            .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_color = .{ .r = 0, .g = 0, .b = 1, .a = 1 } }},
            .width = extent,
            .height = extent,
        });
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        defer pass.deinit(io, &guard);
        try pass.setPipeline(&guard, try pipeline.renderOptions(&guard));
        try pass.draw(.{ .vertex_count = 3, .instance_count = 1, .first_vertex = 0, .first_instance = 0 });
        try pass.end(io, &guard);
        try encoder.copyTextureToBuffer(.{
            .source = .{ .texture = target, .format = @intFromEnum(api.TextureFormat.rgba8_unorm), .dimension = ._2d, .aspect = .all, .extent = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 } },
            .destination = .{ .buffer = try readback.ref(&guard), .blocks_per_row = 64, .rows_per_image = extent },
            .copy_size = .{ .width = extent, .height = extent, .depth_or_array_layers = 1 },
        });
    }
    var finished = try encoder.finish();
    defer {
        var guard = core.ObjectGuard.lockUncancelable(io, f.device.core.arena.objectList());
        defer guard.unlock(io);
        finished.deinit(gpa, io, &guard);
    }
    const serial = try f.device.submit(gpa, io, &finished);
    try f.device.wait(io, serial);
    {
        f.device.native.?.queue_operation_mutex.lockUncancelable(io);
        defer f.device.native.?.queue_operation_mutex.unlock(io);
        var guard = core.ObjectGuard.lockUncancelable(io, readback.header.tracking);
        defer guard.unlock(io);
        const generation = try readback.native.beginMap(.{ .mode = .{ .read = true }, .size = 256 * extent });
        try t.expectEqual(engine.buffer.Buffer.MapCompletion.mapped, try readback.native.completeMap(generation, serial));
        const bytes = try readback.native.getConstMappedRange(0, 256 * extent);
        const center = bytes[8 * 256 + 8 * 4 ..][0..4];
        try t.expectEqualSlices(u8, &.{ 255, 255, 0, 255 }, center);
        const corner = bytes[0..4];
        try t.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, corner);
    }
    try f.device.unmapBuffer(io, readback);
}

test "native host-only pipeline failure survives actual Device host detach before callback" {
    const Call = struct {
        status: ?api.CreatePipelineAsyncStatus = null,
        message_nonempty: bool = false,
        fn invoke(raw: ?*anyopaque, status: api.CreatePipelineAsyncStatus, target: ?api.ComputePipeline, message: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            std.debug.assert(target == null);
            self.status = status;
            self.message_nonempty = message.len != 0;
        }
    };
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    const module = try f.shader(&fixture.words);
    var descriptor = compute(f.exportShader(module));
    descriptor.compute.entry_point = "missing";
    var call: Call = .{};
    const future = try operators.createComputePipelineAsync(handles.exportDevice(&f.device), gpa, io, &descriptor, .{ .mode = .wait_any_only, .callback = Call.invoke, .userdata = &call });
    try f.device.release(gpa, io, module);
    try f.drain();
    try t.expect(call.status == null);
    try f.device.deinit(gpa, io);
    try t.expect(f.device.host_deinitialized);
    try f.wait(future);
    try t.expectEqual(@as(?api.CreatePipelineAsyncStatus, .validation_error), call.status);
    try t.expect(call.message_nonempty);
}

test "native pipeline malformed count and foreign shader refuse before acceptance" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const io = f.threaded.io();
    // A foreign shader needs a real owner, but no asynchronous registration.
    var foreign_adapters = try f.instance.enumerateAdapters(gpa, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer foreign_adapters.deinit(io) catch @panic("foreign adapters teardown");
    if (foreign_adapters.items.len == 0) return error.NoPhysicalDevice;
    var foreign = try foreign_adapters.items[0].createDevice(gpa, io, .{
        .adapter = &foreign_adapters.items[0],
        .feature_level = .core,
        .uncaptured_context = &f,
        .uncaptured_callback = Fixture.uncaptured,
    });
    defer foreign.deinit(gpa, io) catch @panic("foreign device teardown");
    const module = try f.shader(&fixture.words);
    defer f.device.release(gpa, io, module) catch @panic("shader release");
    const other_module = try foreign.createShaderModule(gpa, io, .{ .words = &fixture.words });
    defer foreign.release(gpa, io, other_module) catch @panic("foreign shader release");
    const foreign_shader = block: {
        var guard = core.ObjectGuard.lockUncancelable(io, foreign.core.arena.objectList());
        defer guard.unlock(io);
        const target = handles.exportResource(
            api.ShaderModule,
            &foreign,
            &guard,
            other_module,
            .shader_module,
        );
        try t.expectEqual(&foreign, try handles.resourceOwner(&other_module.header));
        break :block target;
    };
    try t.expect(foreign.async_state.registry == null);
    try t.expectEqual(@as(usize, 0), foreign.active_async_operations);
    var descriptor = compute(f.exportShader(module));
    descriptor.compute.constant_count = 1;
    descriptor.compute.constants = null;
    var call: ComputeCall = .{ .fixture = &f };
    defer call.deinit(io);
    const issued = f.instance.completions.?.issued;
    try t.expectError(error.InvalidRequest, operators.createComputePipelineAsync(handles.exportDevice(&f.device), gpa, io, &descriptor, call.info(.wait_any_only)));
    const foreign_descriptor = compute(foreign_shader);
    try t.expectError(error.InvalidOwner, operators.createComputePipelineAsync(handles.exportDevice(&f.device), gpa, io, &foreign_descriptor, call.info(.wait_any_only)));
    try t.expectEqual(issued, f.instance.completions.?.issued);
    try t.expectEqual(@as(usize, 0), call.calls);
    try t.expectEqual(@as(u32, 0), f.instance.completions.?.prepared_cells);
    try t.expect(foreign.async_state.registry == null);
    try t.expectEqual(@as(usize, 0), foreign.active_async_operations);
}
