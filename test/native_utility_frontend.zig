const std = @import("std");
const dusk = @import("dusk");
const command = dusk.command;
const commands = command.commands;
const usage = command.usage;

const transfer = [7]f32{ 2.2, 1.1, 0.2, 0.3, 0.4, 0.5, 0.6 };
const matrix = [9]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };

fn conversionInput() commands.BrowserCopyInput {
    return .{
        .flip_y = true,
        .needs_color_space_conversion = true,
        .src_alpha_mode = .premultiplied,
        .dst_alpha_mode = .opaque_,
        .src_transfer_function_parameters = &transfer,
        .dst_transfer_function_parameters = &transfer,
        .conversion_matrix = &matrix,
    };
}

test "browser copy owns every coefficient after application storage changes" {
    var src = transfer;
    var dst = transfer;
    var gamut = matrix;
    var input = conversionInput();
    input.src_transfer_function_parameters = &src;
    input.dst_transfer_function_parameters = &dst;
    input.conversion_matrix = &gamut;
    const owned = try commands.BrowserCopyOptions.fromInput(input);
    src = @splat(0);
    dst = @splat(0);
    gamut = @splat(0);
    try std.testing.expectEqualSlices(f32, &transfer, &owned.src_transfer_function_parameters);
    try std.testing.expectEqualSlices(f32, &transfer, &owned.dst_transfer_function_parameters);
    try std.testing.expectEqualSlices(f32, &matrix, &owned.conversion_matrix);
    try std.testing.expect(owned.flip_y);
    try std.testing.expect(owned.needs_color_space_conversion);
    try std.testing.expectEqual(commands.AlphaMode.premultiplied, owned.src_alpha_mode);
    try std.testing.expectEqual(commands.AlphaMode.opaque_, owned.dst_alpha_mode);
}

test "browser conversion requires all three exact coefficient arrays" {
    inline for (.{ "src_transfer_function_parameters", "dst_transfer_function_parameters" }) |field| {
        for ([_]usize{ 0, 6, 8 }) |length| {
            var input = conversionInput();
            const values: [8]f32 = @splat(1);
            @field(input, field) = values[0..length];
            try std.testing.expectError(
                error.BrowserCopyTransferLengthInvalid,
                commands.BrowserCopyOptions.fromInput(input),
            );
        }
    }
    for ([_]usize{ 0, 8, 10 }) |length| {
        var input = conversionInput();
        const values: [10]f32 = @splat(1);
        input.conversion_matrix = values[0..length];
        try std.testing.expectError(
            error.BrowserCopyMatrixLengthInvalid,
            commands.BrowserCopyOptions.fromInput(input),
        );
    }
    inline for (.{
        "src_transfer_function_parameters", "dst_transfer_function_parameters", "conversion_matrix",
    }) |field| {
        var input = conversionInput();
        @field(input, field) = null;
        try std.testing.expectError(
            error.BrowserCopyConversionParametersMissing,
            commands.BrowserCopyOptions.fromInput(input),
        );
    }
}

test "browser copy rejects nonfinite coefficients at every position" {
    inline for (.{ "src_transfer_function_parameters", "dst_transfer_function_parameters" }) |field| {
        for (0..7) |index| {
            for ([_]f32{ std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) }) |invalid| {
                var values = transfer;
                values[index] = invalid;
                var input = conversionInput();
                @field(input, field) = &values;
                try std.testing.expectError(
                    error.BrowserCopyParameterNonFinite,
                    commands.BrowserCopyOptions.fromInput(input),
                );
            }
        }
    }
    for (0..9) |index| {
        var values = matrix;
        values[index] = std.math.nan(f32);
        var input = conversionInput();
        input.conversion_matrix = &values;
        try std.testing.expectError(
            error.BrowserCopyParameterNonFinite,
            commands.BrowserCopyOptions.fromInput(input),
        );
    }
}

test "browser copy cannot request private usage permissions" {
    try std.testing.expectError(
        error.BrowserCopyInternalUsageForbidden,
        commands.BrowserCopyOptions.fromInput(.{ .internal_usage = true }),
    );
}

test "inactive browser conversion still validates supplied array values" {
    var input = conversionInput();
    input.needs_color_space_conversion = false;
    input.src_transfer_function_parameters = &.{1};
    try std.testing.expectError(
        error.BrowserCopyTransferLengthInvalid,
        commands.BrowserCopyOptions.fromInput(input),
    );
}

test "render indirect arguments and count cannot have writable storage use" {
    const indirect = (dusk.api.BufferUsage{ .indirect = true }).toFlags();
    const writable = (dusk.api.BufferUsage{ .storage = true }).toFlags();
    var args: u8 = 0;
    var count: u8 = 0;
    inline for (.{ false, true }) |write_first| {
        inline for (.{ false, true }) |count_buffer| {
            var tracker = usage.SyncScopeUsageTracker.init(std.testing.allocator);
            defer tracker.deinit();
            const ref: commands.Ref = if (count_buffer) &count else &args;
            _ = try tracker.bufferUsedAs(ref, if (write_first) writable else indirect);
            _ = try tracker.bufferUsedAs(ref, if (write_first) indirect else writable);
            try std.testing.expectError(
                error.IndirectBufferWrittenInRenderPass,
                tracker.scope.validateIndirectReadonly(),
            );
        }
    }
}

test "render indirect buffers may have read-only storage use" {
    var buffer: u8 = 0;
    var tracker = usage.SyncScopeUsageTracker.init(std.testing.allocator);
    defer tracker.deinit();
    _ = try tracker.bufferUsedAs(&buffer, (dusk.api.BufferUsage{ .indirect = true }).toFlags());
    _ = try tracker.bufferUsedAs(&buffer, 1 << 30);
    try tracker.scope.validateIndirectReadonly();
}

const Fixture = struct {
    mutex: std.Io.Mutex = .init,
    device: dusk.core.Device,
    guard: dusk.core.ObjectGuard,
    attachment: *command.attachment_state.CanonicalAttachmentState,

    fn init(self: *Fixture) !void {
        self.* = .{ .device = undefined, .guard = undefined, .attachment = undefined };
        self.device = dusk.core.Device.init(std.testing.allocator, .{
            .object_mutex = &self.mutex,
            .uncaptured_context = self,
            .uncaptured_callback = unexpectedError,
        });
        self.guard = dusk.core.ObjectGuard.lockUncancelable(
            std.testing.io,
            self.device.borrow().objects,
        );
        errdefer self.guard.unlock(std.testing.io);
        errdefer self.device.deinit(std.testing.allocator, &self.guard) catch
            @panic("fixture initialization leaked references");
        self.device.bindTrackingOwner(&self.guard, self);
        self.attachment = try self.device.create(
            std.testing.allocator,
            &self.guard,
            command.attachment_state.CanonicalAttachmentState,
            .{ .kind = .attachment_state, .initial_reference = .user },
        );
        var value: command.attachment_state.AttachmentState = .{};
        value.color_attachments_set = 1;
        value.color_formats[0] = @intFromEnum(dusk.api.TextureFormat.rgba8_unorm);
        self.attachment.value = value;
        self.attachment.cache_hash = 0;
        self.attachment.cache_next = null;
        self.attachment.header.attach(&self.guard, std.testing.io);
    }

    fn deinit(self: *Fixture) void {
        self.attachment.header.releaseUserLocked(&self.guard, std.testing.io) catch
            @panic("fixture attachment release failed");
        self.device.deinit(std.testing.allocator, &self.guard) catch
            @panic("fixture leaked references");
        self.guard.unlock(std.testing.io);
    }

    fn unexpectedError(
        _: std.mem.Allocator,
        _: std.Io,
        _: *anyopaque,
        _: dusk.core.ErrorView,
    ) void {
        @panic("unexpected frontend error");
    }
};

test "browser commands preserve owned transform intent through finish and generic skip" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var source: u8 = 0;
    var destination: u8 = 0;
    var external: u8 = 0;
    var encoder = command.CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    var coefficients = transfer;
    var input = conversionInput();
    input.src_transfer_function_parameters = &coefficients;
    const options = try commands.BrowserCopyOptions.fromInput(input);
    try encoder.copyTextureForBrowser(.{
        .source = &source,
        .destination = &destination,
        .source_origin = .{ .x = 2, .y = 3 },
        .destination_origin = .{ .x = 5, .y = 7 },
        .copy_size = .{ .width = 11, .height = 13 },
        .options = options,
    });
    try encoder.copyExternalTextureForBrowser(.{
        .source = &external,
        .destination = &destination,
        .source_origin = .{ .x = 17, .y = 19 },
        .destination_origin = .{ .x = 23, .y = 29 },
        .copy_size = .{ .width = 31, .height = 37 },
        .natural_size = .{ .width = 61, .height = 67 },
        .options = options,
    });
    coefficients = @splat(0);
    try encoder.clearBuffer(.{ .offset = 41, .size = 43 });
    var finished = try encoder.finish();
    defer finished.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    var cursor = finished.iterator(std.testing.allocator);
    defer cursor.deinit();
    try std.testing.expectEqual(commands.Tag.copy_texture_for_browser, (try cursor.nextTag()).?);
    const texture_copy = try cursor.nextCommand(commands.CopyTextureForBrowserCmd);
    try std.testing.expectEqual(@as(commands.Ref, &source), texture_copy.source);
    try std.testing.expectEqual(@as(commands.Ref, &destination), texture_copy.destination);
    try std.testing.expectEqual(@as(u32, 2), texture_copy.source_origin.x);
    try std.testing.expectEqual(@as(u32, 3), texture_copy.source_origin.y);
    try std.testing.expectEqual(@as(u32, 5), texture_copy.destination_origin.x);
    try std.testing.expectEqual(@as(u32, 7), texture_copy.destination_origin.y);
    try std.testing.expectEqual(@as(u32, 11), texture_copy.copy_size.width);
    try std.testing.expectEqual(@as(u32, 13), texture_copy.copy_size.height);
    try std.testing.expectEqualSlices(
        f32,
        &transfer,
        &texture_copy.options.src_transfer_function_parameters,
    );
    try std.testing.expectEqual(commands.Tag.copy_external_texture_for_browser, (try cursor.nextTag()).?);
    const external_copy = try cursor.nextCommand(commands.CopyExternalTextureForBrowserCmd);
    try std.testing.expectEqual(@as(commands.Ref, &external), external_copy.source);
    try std.testing.expectEqual(@as(u32, 17), external_copy.source_origin.x);
    try std.testing.expectEqual(@as(u32, 19), external_copy.source_origin.y);
    try std.testing.expectEqual(@as(u32, 23), external_copy.destination_origin.x);
    try std.testing.expectEqual(@as(u32, 29), external_copy.destination_origin.y);
    try std.testing.expectEqual(@as(u32, 31), external_copy.copy_size.width);
    try std.testing.expectEqual(@as(u32, 37), external_copy.copy_size.height);
    try std.testing.expectEqual(@as(u32, 61), external_copy.natural_size.width);
    try std.testing.expectEqual(@as(u32, 67), external_copy.natural_size.height);
    try std.testing.expectEqualSlices(f32, &matrix, &external_copy.options.conversion_matrix);
    try std.testing.expectEqual(commands.Tag.clear_buffer, (try cursor.nextTag()).?);
    _ = try cursor.nextCommand(commands.ClearBufferCmd);
    try std.testing.expectEqual(@as(?commands.Tag, null), try cursor.nextTag());
    var skipped = finished.iterator(std.testing.allocator);
    defer skipped.deinit();
    for ([_]commands.Tag{
        .copy_texture_for_browser, .copy_external_texture_for_browser, .clear_buffer,
    }) |tag| {
        try std.testing.expectEqual(tag, (try skipped.nextTag()).?);
        try commands.skip(&skipped.iterator, tag);
    }
    try std.testing.expectEqual(@as(?commands.Tag, null), try skipped.nextTag());
}

test "render end refuses indirect storage aliases before the encoder can finish" {
    inline for (.{ false, true }) |indexed| {
        inline for (.{ false, true }) |multi| {
            inline for (.{ false, true }) |write_first| {
                var fixture: Fixture = undefined;
                try fixture.init();
                defer fixture.deinit();
                var pipeline: u8 = 0;
                var args: u8 = 0;
                var count: u8 = 0;
                var index: u8 = 0;
                var group: u8 = 0;
                var encoder = command.CommandEncoder.init(
                    std.testing.allocator,
                    fixture.device.borrow(),
                    .{},
                );
                defer encoder.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
                var pass = try encoder.beginRenderPass(
                    std.testing.io,
                    &fixture.guard,
                    fixture.attachment,
                    .{},
                );
                defer pass.deinit(std.testing.io, &fixture.guard);
                try pass.setPipeline(&fixture.guard, .{
                    .pipeline = &pipeline,
                    .requirements = .{},
                    .attachment_state = fixture.attachment,
                });
                if (indexed) try pass.setIndexBuffer(.{
                    .buffer = &index,
                    .buffer_size = 16,
                    .format = .uint16,
                });
                const writable_binding = command.programmable_encoder.SetBindGroupOptions{
                    .index = 0,
                    .group = &group,
                    .buffers = &.{.{
                        .buffer = if (multi) &count else &args,
                        .usage = (dusk.api.BufferUsage{ .storage = true }).toFlags(),
                    }},
                };
                if (write_first) try pass.setBindGroup(writable_binding);
                if (multi) {
                    const draw: command.render_encoder_base.MultiDrawIndirectOptions = .{
                        .indirect_buffer = &args,
                        .indirect_buffer_size = 64,
                        .indirect_offset = 0,
                        .max_draw_count = 2,
                        .draw_count_buffer = &count,
                        .draw_count_buffer_size = 4,
                    };
                    if (indexed) {
                        try pass.multiDrawIndexedIndirect(draw);
                    } else {
                        try pass.multiDrawIndirect(draw);
                    }
                } else {
                    const draw: command.render_encoder_base.DrawIndirectOptions = .{
                        .indirect_buffer = &args,
                        .indirect_buffer_size = 32,
                        .indirect_offset = 0,
                    };
                    if (indexed) {
                        try pass.drawIndexedIndirect(draw);
                    } else {
                        try pass.drawIndirect(draw);
                    }
                }
                if (!write_first) try pass.setBindGroup(writable_binding);
                try std.testing.expectError(
                    error.IndirectBufferWrittenInRenderPass,
                    pass.end(std.testing.io, &fixture.guard),
                );
                try std.testing.expectError(error.EncoderInvalidated, encoder.finish());
            }
        }
    }
}

test "merged render bundle storage usage cannot write a pass indirect argument" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var pipeline: u8 = 0;
    var args: u8 = 0;
    var group: u8 = 0;
    var bundle_encoder = try command.render_bundle.RenderBundleEncoder.init(
        std.testing.allocator,
        std.testing.io,
        &fixture.guard,
        &fixture.device,
        fixture.attachment,
        .{},
    );
    defer bundle_encoder.deinit(std.testing.io, &fixture.guard);
    try bundle_encoder.setBindGroup(.{
        .index = 0,
        .group = &group,
        .buffers = &.{.{
            .buffer = &args,
            .usage = (dusk.api.BufferUsage{ .storage = true }).toFlags(),
        }},
    });
    const bundle = try bundle_encoder.finish(std.testing.io, &fixture.guard);
    defer bundle.header.releaseUserLocked(&fixture.guard, std.testing.io) catch
        @panic("bundle release failed");
    var encoder = command.CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    var pass = try encoder.beginRenderPass(
        std.testing.io,
        &fixture.guard,
        fixture.attachment,
        .{},
    );
    defer pass.deinit(std.testing.io, &fixture.guard);
    try pass.setPipeline(&fixture.guard, .{
        .pipeline = &pipeline,
        .requirements = .{},
        .attachment_state = fixture.attachment,
    });
    try pass.drawIndirect(.{
        .indirect_buffer = &args,
        .indirect_buffer_size = 16,
        .indirect_offset = 0,
    });
    try pass.executeBundles(&fixture.guard, &.{bundle});
    try std.testing.expectError(
        error.IndirectBufferWrittenInRenderPass,
        pass.end(std.testing.io, &fixture.guard),
    );
    try std.testing.expectError(error.EncoderInvalidated, encoder.finish());
}

test "read-only storage alias of a render indirect argument can finish" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var pipeline: u8 = 0;
    var args: u8 = 0;
    var group: u8 = 0;
    var encoder = command.CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    var pass = try encoder.beginRenderPass(
        std.testing.io,
        &fixture.guard,
        fixture.attachment,
        .{},
    );
    defer pass.deinit(std.testing.io, &fixture.guard);
    try pass.setPipeline(&fixture.guard, .{
        .pipeline = &pipeline,
        .requirements = .{},
        .attachment_state = fixture.attachment,
    });
    try pass.setBindGroup(.{
        .index = 0,
        .group = &group,
        .buffers = &.{.{ .buffer = &args, .usage = 1 << 30 }},
    });
    try pass.drawIndirect(.{
        .indirect_buffer = &args,
        .indirect_buffer_size = 16,
        .indirect_offset = 0,
    });
    try pass.end(std.testing.io, &fixture.guard);
    var finished = try encoder.finish();
    defer finished.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    const flags = finished.render_pass_usages.items[0].scope.buffer_sync_infos.items[0].usage;
    try std.testing.expectEqual(
        (dusk.api.BufferUsage{ .indirect = true }).toFlags() | (1 << 30),
        flags,
    );
}

test "invalid recorded browser coefficients append no command" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var source: u8 = 0;
    var destination: u8 = 0;
    var encoder = command.CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    var options: commands.BrowserCopyOptions = .{};
    options.dst_transfer_function_parameters[6] = std.math.nan(f32);
    try std.testing.expectError(error.BrowserCopyParameterNonFinite, encoder.copyTextureForBrowser(.{
        .source = &source,
        .destination = &destination,
        .source_origin = .{},
        .destination_origin = .{},
        .copy_size = .{ .width = 1, .height = 1 },
        .options = options,
    }));
    try encoder.clearBuffer(.{ .offset = 4, .size = 8 });
    var finished = try encoder.finish();
    defer finished.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    var cursor = finished.iterator(std.testing.allocator);
    defer cursor.deinit();
    try std.testing.expectEqual(commands.Tag.clear_buffer, (try cursor.nextTag()).?);
    try commands.skip(&cursor.iterator, .clear_buffer);
    try std.testing.expectEqual(@as(?commands.Tag, null), try cursor.nextTag());
}

test "browser copy preserves locked and finished encoder error precedence" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var source: u8 = 0;
    var destination: u8 = 0;
    var encoder = command.CommandEncoder.init(std.testing.allocator, fixture.device.borrow(), .{});
    defer encoder.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    var options: commands.BrowserCopyOptions = .{};
    options.conversion_matrix[8] = std.math.inf(f32);
    const copy: commands.CopyExternalTextureForBrowserCmd = .{
        .source = &source,
        .destination = &destination,
        .source_origin = .{},
        .destination_origin = .{},
        .copy_size = .{ .width = 1, .height = 1 },
        .natural_size = .{ .width = 1, .height = 1 },
        .options = options,
    };
    var pass = try encoder.beginRenderPass(
        std.testing.io,
        &fixture.guard,
        fixture.attachment,
        .{},
    );
    defer pass.deinit(std.testing.io, &fixture.guard);
    try std.testing.expectError(error.PassLocked, encoder.copyExternalTextureForBrowser(copy));
    try pass.end(std.testing.io, &fixture.guard);
    var finished = try encoder.finish();
    defer finished.deinit(std.testing.allocator, std.testing.io, &fixture.guard);
    try std.testing.expectError(
        error.EncoderAlreadyFinished,
        encoder.copyExternalTextureForBrowser(copy),
    );
}
