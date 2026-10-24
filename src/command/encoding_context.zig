//! The encoder-lifetime state machine every record call passes through.
//!
//! **What this file is.** The port of
//! `src/dawn/native/EncodingContext.{h,cpp}`: a five-state status, an
//! identity check that names which encoder is allowed to record right now,
//! and the pending/committed allocator pair that keeps a pass body in its own
//! block.
//!
//! **What this file does not claim.** It does not claim Dawn's encoder
//! identity. Dawn compares `const ApiObjectBase*` pointers
//! (`src/dawn/native/EncodingContext.h:150`), null-doubled so one comparison
//! covers both "is the wrong encoder" and "is there no current encoder"
//! (`EncodingContext.h:200-217`). The port issues a monotonic `EncoderId`,
//! because a pass encoder is a value in the port and has no address stable
//! across the call that created it. The state machine, the five statuses and
//! the five rules of `ValidateCanEncodeOn` are unchanged.
//!
//! It does not claim the two-level rule is a design the port invented. It is
//! Dawn's: one top-level encoder and at most one open pass
//! (`EncodingContext.h:202-203`).

const std = @import("std");
const allocator_mod = @import("allocator.zig");
const commands = @import("commands.zig");
const errors = @import("errors.zig");
const indirect_draw = @import("indirect_draw.zig");
const usage = @import("usage.zig");
const core = @import("../core/root.zig");
const attachment = @import("attachment_state.zig");

/// Which encoder is recording. `no_encoder` is the null case Dawn spells by
/// nulling both pointers (`EncodingContext.h:200-217`).
pub const EncoderId = u64;

/// The value that means "no encoder". Zero is never issued, because
/// `next_encoder_id` starts at one.
pub const no_encoder: EncoderId = 0;

/// Dawn's `EncodingContext::Status` (`EncodingContext.h:189-195`), five
/// values, in Dawn's order.
pub const Status = enum {
    open,
    finished,
    error_at_creation,
    error_in_recording,
    destroyed,
};

/// What `finish` hands back: the blocks, the usages and the status.
pub const Finished = struct {
    device: core.CoreDeviceBorrow,
    blocks: allocator_mod.Blocks,
    render_pass_usages: std.ArrayList(usage.RenderPassResourceUsage),
    compute_pass_usages: std.ArrayList(usage.ComputePassResourceUsage),
    indirect_draws: std.ArrayList(indirect_draw.IndirectDrawMetadata),
    status: Status,

    /// Borrows blocks and pass-owned leases; the Finished must outlive the cursor.
    pub fn iterator(self: *const Finished, allocator: std.mem.Allocator) allocator_mod.BorrowedIterator {
        return .{ .iterator = allocator_mod.Iterator.init(allocator, self.blocks) };
    }

    pub fn deinit(
        self: *Finished,
        allocator: std.mem.Allocator,
        io: std.Io,
        guard: *const core.ObjectGuard,
    ) void {
        guard.assertOwns(self.device.objects);
        if (self.status == .destroyed) return;
        freeBlocks(allocator, &self.blocks);
        for (self.render_pass_usages.items) |*item| item.deinit(io, guard);
        self.render_pass_usages.deinit(allocator);
        for (self.compute_pass_usages.items) |*item| item.deinit();
        self.compute_pass_usages.deinit(allocator);
        for (self.indirect_draws.items) |*item| item.deinit();
        self.indirect_draws.deinit(allocator);
        self.* = .{
            .device = self.device,
            .blocks = .empty,
            .render_pass_usages = .empty,
            .compute_pass_usages = .empty,
            .indirect_draws = .empty,
            .status = .destroyed,
        };
    }
};

/// The one object a top-level encoder owns, and the only door into the stream.
pub const Context = struct {
    allocator: std.mem.Allocator,
    device: core.CoreDeviceBorrow,
    block_size: usize,
    status: Status = .open,

    top_level_id: EncoderId = no_encoder,
    current_id: EncoderId = no_encoder,
    next_encoder_id: EncoderId = 1,

    /// The block being written now. Dawn's `mPendingCommands`
    /// (`EncodingContext.h:222`).
    pending: allocator_mod.Allocator,
    /// The blocks committed so far, in the order they were committed. Dawn's
    /// `mAllocators` (`EncodingContext.h:224`).
    allocators: std.ArrayList(allocator_mod.Blocks) = .empty,

    render_pass_usages: std.ArrayList(usage.RenderPassResourceUsage) = .empty,
    compute_pass_usages: std.ArrayList(usage.ComputePassResourceUsage) = .empty,
    indirect_draws: std.ArrayList(indirect_draw.IndirectDrawMetadata) = .empty,

    /// The labels pushed so far, borrowed from the stream blocks. Dawn says so
    /// in the member's comment (`EncodingContext.h:226-227`): the strings live
    /// in the command allocators, not here.
    debug_group_labels: std.ArrayList([]const u8) = .empty,

    compatibility_mode: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        device: core.CoreDeviceBorrow,
        block_size: usize,
        compatibility_mode: bool,
    ) allocator_mod.AllocatorError!Context {
        return .{
            .allocator = allocator,
            .device = device,
            .block_size = block_size,
            .pending = try allocator_mod.Allocator.init(allocator, block_size),
            .compatibility_mode = compatibility_mode,
        };
    }

    pub fn deinit(self: *Context, io: std.Io, guard: *const core.ObjectGuard) void {
        guard.assertOwns(self.device.objects);
        if (self.status == .destroyed) return;
        // Walked by index rather than `for (self.allocators.items)`. Each step
        // releases one element's own block array, so the loop re-reads
        // `self.allocators.items` every iteration instead of holding one slice
        // across the releases. `self.allocators` itself is not grown here, and
        // the copy the slice loop made was the only aliasing hazard in it.
        var index: usize = 0;
        while (index < self.allocators.items.len) : (index += 1) {
            freeBlocks(self.allocator, &self.allocators.items[index]);
        }
        self.allocators.deinit(self.allocator);
        for (self.render_pass_usages.items) |*item| item.deinit(io, guard);
        self.render_pass_usages.deinit(self.allocator);
        for (self.compute_pass_usages.items) |*item| item.deinit();
        self.compute_pass_usages.deinit(self.allocator);
        for (self.indirect_draws.items) |*item| item.deinit();
        self.indirect_draws.deinit(self.allocator);
        self.debug_group_labels.deinit(self.allocator);
        self.pending.deinit();
        self.status = .destroyed;
        self.current_id = no_encoder;
        self.top_level_id = no_encoder;
    }

    /// Dawn's first `EncodingContext` constructor
    /// (`EncodingContext.cpp:40-47`): the context is created with its
    /// top-level encoder, which doubles as the "still open" flag.
    pub fn open(self: *Context) EncoderId {
        self.top_level_id = self.next_encoder_id;
        self.current_id = self.top_level_id;
        self.next_encoder_id += 1;
        return self.top_level_id;
    }

    /// The second constructor (`EncodingContext.cpp:49-54`): an encoder created
    /// in a failed state nulls both pointers, so nothing can record into it.
    pub fn openFailed(self: *Context) EncoderId {
        self.top_level_id = self.next_encoder_id;
        self.current_id = no_encoder;
        self.next_encoder_id += 1;
        self.status = .error_at_creation;
        return self.top_level_id;
    }

    /// Dawn's `ValidateCanEncodeOn` (`EncodingContext.h:150-186`).
    ///
    /// The fast path is the identity comparison. The switch that follows
    /// answers "why is this the wrong encoder", and the five arms are Dawn's
    /// five cases in the same order, so the first rule a caller sees is the
    /// first thing wrong.
    pub fn validateCanEncodeOn(
        self: *const Context,
        encoder: EncoderId,
        is_top_level: bool,
    ) errors.Error!void {
        if (self.status == .open and encoder != no_encoder and encoder == self.current_id) return;
        return switch (self.status) {
            .error_at_creation => error.EncoderInvalidated,
            .error_in_recording => error.EncoderInvalidated,
            .destroyed => error.EncoderDestroyed,
            .finished => if (is_top_level) error.EncoderAlreadyFinished else error.ParentEncoderFinished,
            // Open, but `encoder` is not the current one. Dawn checks whether
            // the caller's encoder is itself an error encoder, then whether the
            // top-level encoder is locked by an open pass, then falls through
            // to "this pass has already been ended"
            // (`EncodingContext.h:173-186`). The port has no error encoders:
            // a failed encoder is `error_at_creation`, which the switch above
            // already caught, so the last two arms stand on their own.
            .open => if (is_top_level) error.PassLocked else error.PassEnded,
        };
    }

    /// Dawn's `TryEncode` (`EncodingContext.h:66-84`) with the template
    /// spelled out: check, then hand the record function the pending
    /// allocator. The port returns the typed payload so the caller fills it in
    /// place, which is what Dawn's `Allocate<T>` gives it too.
    ///
    /// The set is `errors.Error` and not the arena's: the check can raise
    /// `EncoderAlreadyFinished`, which lives in `core.Error` (`core/errors.zig:24`)
    /// and not in `CommandValidationError`, and the allocation below can raise
    /// `OutOfMemory` (`allocator.zig:184`). `errors.Error` names both and is the
    /// set every record call in this module declares (`errors.zig:211`).
    pub fn encode(
        self: *Context,
        comptime T: type,
        encoder: EncoderId,
        tag: commands.Tag,
    ) errors.Error!*T {
        try self.validateCanEncodeOn(encoder, false);
        return self.pending.allocateCommand(T, @backingInt(tag));
    }

    /// The top-level form of `encode`. A top-level command is checked with the
    /// same rules; only the failure differs.
    ///
    /// The same set as `encode` for the same two reasons, and a top-level check
    /// raises the same six rules.
    pub fn encodeTopLevel(
        self: *Context,
        comptime T: type,
        encoder: EncoderId,
        tag: commands.Tag,
    ) errors.Error!*T {
        try self.validateCanEncodeOn(encoder, true);
        return self.pending.allocateCommand(T, @backingInt(tag));
    }

    /// The counted run behind the payload just written. The check is skipped
    /// because `encode` already ran it and nothing ran in between: the caller
    /// fills the payload, then calls this.
    pub fn encodeData(
        self: *Context,
        comptime T: type,
        count: usize,
    ) allocator_mod.AllocatorError![]T {
        return self.pending.allocateData(T, count);
    }

    /// The allocator a record call writes its string into. Dawn passes the
    /// pending `CommandAllocator*` to `AddNullTerminatedString`
    /// (`Commands.cpp:433-436`).
    pub fn pendingAllocator(self: *Context) *allocator_mod.Allocator {
        return &self.pending;
    }

    /// Dawn's `WillBeginRenderPass` (`EncodingContext.cpp:154-165`): commit the
    /// pending block so the pass body starts a fresh one.
    pub fn willBeginRenderPass(self: *Context) allocator_mod.AllocatorError!void {
        try self.commitCommands();
    }

    /// Dawn's `EnterPass` (`EncodingContext.cpp:167-173`).
    pub fn enterPass(self: *Context) EncoderId {
        const id = self.next_encoder_id;
        self.next_encoder_id += 1;
        self.current_id = id;
        return id;
    }

    /// Dawn's `ExitRenderPass` (`EncodingContext.cpp:175-215`).
    ///
    /// Dawn splits the stream into three allocators here: the commands before
    /// the pass, the validation commands it injects, and the pass body. The
    /// port injects nothing — the indirect-draw validation encoder is not
    /// ported — so the order is pre-pass then pass body, which is what the two
    /// commits produce.
    ///
    /// `errors.Error` because the check raises the six encoder rules and the two
    /// appends and the commit raise `OutOfMemory`; the arena's own set
    /// (`allocator.zig:234`) carries the allocation failure but not
    /// `EncoderAlreadyFinished`.
    ///
    /// Both parameters arrive already moved out of the pass encoder, by
    /// `acquireResourceUsage` (`usage.zig:546`) and `acquireIndirectDraws`
    /// (`render_encoder_base.zig:186`). Both of those empty the source, so the
    /// caller's `defer self.deinit()` cannot recover the lists: from its first
    /// line this function owns both. Each `errdefer` is therefore armed before
    /// the first fallible step, and disarmed by an explicit empty the moment the
    /// owning list takes the value, so a later failure never frees it twice.
    pub fn exitRenderPass(
        self: *Context,
        io: std.Io,
        guard: *const core.ObjectGuard,
        encoder: EncoderId,
        pass_usage: usage.RenderPassResourceUsage,
        indirect: indirect_draw.IndirectDrawMetadata,
    ) errors.Error!void {
        guard.assertOwns(self.device.objects);
        if (pass_usage.attachment_state) |state| {
            std.debug.assert(state.header.tracking == self.device.objects);
        }
        var owned_usage = pass_usage;
        errdefer owned_usage.deinit(io, guard);
        var owned_indirect = indirect;
        errdefer owned_indirect.deinit();
        errdefer {
            self.status = .error_in_recording;
            self.current_id = no_encoder;
        }

        try self.validateCanEncodeOn(encoder, false);
        self.current_id = self.top_level_id;
        try self.render_pass_usages.append(self.allocator, owned_usage);
        // The list took the value, so this is the disarm: without it the first
        // `errdefer` frees the usage again when the next append fails.
        owned_usage = usage.RenderPassResourceUsage.init(owned_usage.allocator);
        try self.indirect_draws.append(self.allocator, owned_indirect);
        // The same for the metadata, because `commitCommands` below is still
        // fallible. What the two lists already hold stays there, because
        // `Context.deinit` walks both of them and releases it.
        owned_indirect = indirect_draw.IndirectDrawMetadata.init(owned_indirect.allocator);
        try self.commitCommands();
    }

    /// Dawn's `ExitComputePass` (`EncodingContext.cpp:217-224`).
    ///
    /// `errors.Error` for the same reason as `exitRenderPass`.
    ///
    /// The usage arrives already moved out of the pass encoder by
    /// `acquireResourceUsage` (`usage.zig:407`), so this function owns it from
    /// its first line and the same disarm rule applies.
    pub fn exitComputePass(
        self: *Context,
        encoder: EncoderId,
        pass_usage: usage.ComputePassResourceUsage,
    ) errors.Error!void {
        var owned_usage = pass_usage;
        errdefer owned_usage.deinit();

        try self.validateCanEncodeOn(encoder, false);
        self.current_id = self.top_level_id;
        try self.compute_pass_usages.append(self.allocator, owned_usage);
        // The list took the value, so this is the disarm: without it the
        // `errdefer` frees the usage again when `commitCommands` below fails.
        owned_usage = usage.ComputePassResourceUsage.init(owned_usage.allocator);
        try self.commitCommands();
    }

    /// Dawn's `EnsurePassExited` (`EncodingContext.cpp:226-234`): a pass
    /// encoder that is destroyed without ending leaves the context in a state
    /// where the top-level encoder is locked forever. The port reports it.
    pub fn ensurePassExited(self: *Context, encoder: EncoderId) errors.Error!void {
        if (self.current_id != encoder) return;
        return error.PassNotOpen;
    }

    /// Dawn's `CommitCommands` (`EncodingContext.cpp:300-304`).
    ///
    /// The element written here owns the array `acquireBlocks` moved out of the
    /// pending allocator, and holds it until `finish` merges the list. A failed
    /// append writes no element and copies nothing, so the `errdefer` releases
    /// the blocks and the array as one.
    pub fn commitCommands(self: *Context) allocator_mod.AllocatorError!void {
        var blocks = self.pending.acquireBlocks();
        if (blocks.items.len == 0) return;
        errdefer freeBlocks(self.allocator, &blocks);
        try self.allocators.append(self.allocator, blocks);
    }

    /// Dawn's `Finish` (`EncodingContext.cpp:272-298`).
    ///
    /// Dawn closes with `Status::Finished` even when the finish failed
    /// (`:289`), because a finished encoder cannot record again either way.
    /// The port does the same and returns the status with the blocks.
    pub fn finish(self: *Context) errors.Error!Finished {
        try self.validateCanEncodeOn(self.top_level_id, true);
        defer {
            self.status = .finished;
            self.current_id = no_encoder;
            self.top_level_id = no_encoder;
        }
        try self.commitCommands();
        var blocks: allocator_mod.Blocks = .empty;
        // The merge below can fail with the list half taken, so what it already
        // holds is released here. The commits it did not reach stay in
        // `self.allocators`, where `deinit` finds them.
        errdefer freeBlocks(self.allocator, &blocks);
        try takeAll(self.allocator, &blocks, self.allocators.items);
        // Every commit is in `blocks` now, so this list holds nothing but the
        // array it grew for them. `deinit` releases that array and leaves the
        // value undefined rather than `.empty`
        // (`std/array_list.zig:623-626`), and `Context.deinit` walks this list,
        // so the empty is written here.
        self.allocators.deinit(self.allocator);
        self.allocators = .empty;

        var render_usages: std.ArrayList(usage.RenderPassResourceUsage) = .empty;
        render_usages = self.render_pass_usages;
        self.render_pass_usages = .empty;
        var compute_usages: std.ArrayList(usage.ComputePassResourceUsage) = .empty;
        compute_usages = self.compute_pass_usages;
        self.compute_pass_usages = .empty;
        var indirect: std.ArrayList(indirect_draw.IndirectDrawMetadata) = .empty;
        indirect = self.indirect_draws;
        self.indirect_draws = .empty;

        self.status = .finished;
        self.current_id = no_encoder;
        self.top_level_id = no_encoder;
        return .{
            .device = self.device,
            .blocks = blocks,
            .render_pass_usages = render_usages,
            .compute_pass_usages = compute_usages,
            .indirect_draws = indirect,
            .status = .finished,
        };
    }

    /// Dawn's `PushDebugGroupLabel` (`EncodingContext.cpp:264-266`).
    pub fn pushDebugGroupLabel(self: *Context, label: []const u8) std.mem.Allocator.Error!void {
        try self.debug_group_labels.append(self.allocator, label);
    }

    /// Dawn's `PopDebugGroupLabel` (`EncodingContext.cpp:268-270`). Dawn raises
    /// the empty-stack rule at the call site, not here
    /// (`ProgrammableEncoder.cpp:100-101`). The port reports it, because a
    /// pop with no push is a caller bug and the acceptance shard asserts the
    /// rule by name.
    pub fn popDebugGroupLabel(self: *Context) errors.Error!void {
        if (self.debug_group_labels.items.len == 0) return error.DebugGroupUnbalanced;
        _ = self.debug_group_labels.pop();
    }

    /// How many debug groups are open. Dawn's
    /// `mDebugGroupStackSize` is duplicated into every encoder
    /// (`ProgrammableEncoder.h:84`); the port reads it here, so there is one
    /// counter rather than three.
    pub fn debugGroupDepth(self: *const Context) usize {
        return self.debug_group_labels.items.len;
    }
};

/// Move every committed list into `out`, in commit order.
///
/// The rule is `Iterator.appendBlocks` (`allocator.zig:271`) under another
/// name: the `Block` values move into `out` and take their `bytes` with them,
/// and the array behind each source is released here, because the source is a
/// value in a list nothing else reads. Each one is emptied on the way out, so
/// the `Context.deinit` that walks this list finds nothing to free twice.
fn takeAll(
    allocator: std.mem.Allocator,
    out: *allocator_mod.Blocks,
    sources: []allocator_mod.Blocks,
) allocator_mod.AllocatorError!void {
    for (sources) |*source| {
        try out.appendSlice(allocator, source.items);
        // `deinit` leaves the value undefined rather than `.empty`
        // (`std/array_list.zig:623-626`), and `Context.deinit` walks this list
        // to free whatever is left in it, so the empty is written here.
        source.deinit(allocator);
        source.* = .empty;
    }
}

fn freeBlocks(allocator: std.mem.Allocator, blocks: *allocator_mod.Blocks) void {
    for (blocks.items) |block| allocator.free(block.bytes);
    blocks.deinit(allocator);
}

fn unexpectedContextError(
    _: std.mem.Allocator,
    _: std.Io,
    _: *anyopaque,
    _: core.ErrorView,
) void {
    @panic("unexpected uncaptured error");
}

fn createContextAttachment(
    device: *core.Device,
    guard: *const core.ObjectGuard,
) !*attachment.CanonicalAttachmentState {
    const state = try device.create(std.testing.allocator, guard, attachment.CanonicalAttachmentState, .{
        .kind = .attachment_state,
        .initial_reference = .user,
    });
    state.value = .{};
    state.cache_hash = 0;
    state.cache_next = null;
    state.header.attach(guard, std.testing.io);
    return state;
}

test "finished ownership preserves an attachment through two independent borrowed cursors" {
    var mutex: std.Io.Mutex = .init;
    var callback_context: u8 = 0;
    var device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &mutex,
        .uncaptured_context = &callback_context,
        .uncaptured_callback = unexpectedContextError,
    });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    const state = try createContextAttachment(&device, &guard);
    var finished = block: {
        var context = try Context.init(std.testing.allocator, device.borrow(), 4096, false);
        defer context.deinit(std.testing.io, &guard);
        _ = context.open();
        const id = context.enterPass();
        var tracker = usage.RenderPassResourceUsageTracker.init(std.testing.allocator);
        defer tracker.deinit(std.testing.io, &guard);
        try tracker.usage.retainAttachmentLocked(&guard, state);
        try state.header.releaseUserLocked(&guard, std.testing.io);
        _ = try context.encode(commands.EndRenderPassCmd, id, .end_render_pass);
        try context.exitRenderPass(
            std.testing.io,
            &guard,
            id,
            tracker.acquireResourceUsage(),
            indirect_draw.IndirectDrawMetadata.init(std.testing.allocator),
        );
        try std.testing.expectEqual(@as(u32, 0), state.header.user_reference_count);
        try std.testing.expectEqual(@as(u32, 1), state.header.reference_count);
        break :block try context.finish();
    };
    defer finished.deinit(std.testing.allocator, std.testing.io, &guard);
    try std.testing.expectEqual(device.borrow().objects, finished.device.objects);
    try std.testing.expectEqual(@as(u32, 0), state.header.user_reference_count);
    try std.testing.expectError(error.ResourceInUse, device.deinit(std.testing.allocator, &guard));
    var first = finished.iterator(std.testing.allocator);
    defer first.deinit();
    var second = finished.iterator(std.testing.allocator);
    defer second.deinit();
    try std.testing.expectEqual(@as(?commands.Tag, .end_render_pass), try first.nextTag());
    _ = try first.nextCommand(commands.EndRenderPassCmd);
    first.deinit();
    try std.testing.expect(state.header.isAlive(&guard));
    try std.testing.expectEqual(@as(u32, 1), state.header.reference_count);
    try std.testing.expectEqual(@as(?commands.Tag, .end_render_pass), try second.nextTag());
    _ = try second.nextCommand(commands.EndRenderPassCmd);
    try std.testing.expectEqual(@as(?commands.Tag, null), try second.nextTag());
    second.deinit();
    finished.deinit(std.testing.allocator, std.testing.io, &guard);
    try std.testing.expectEqual(@as(u32, 0), state.header.reference_count);
}

test "render usage exit and finish allocation rollback release every attachment lease" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, contextLeaseRollback, .{});
}

fn contextLeaseRollback(allocator: std.mem.Allocator) !void {
    var mutex: std.Io.Mutex = .init;
    var callback_context: u8 = 0;
    var device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &mutex,
        .uncaptured_context = &callback_context,
        .uncaptured_callback = unexpectedContextError,
    });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    const state = try createContextAttachment(&device, &guard);
    defer {
        std.debug.assert(state.header.reference_count == 1);
        state.header.releaseUserLocked(&guard, std.testing.io) catch @panic("alias leaked");
    }
    var context = try Context.init(allocator, device.borrow(), 4096, false);
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    const id = context.enterPass();
    var tracker = usage.RenderPassResourceUsageTracker.init(allocator);
    defer tracker.deinit(std.testing.io, &guard);
    try tracker.usage.retainAttachmentLocked(&guard, state);
    _ = try context.encode(commands.EndRenderPassCmd, id, .end_render_pass);
    context.exitRenderPass(
        std.testing.io,
        &guard,
        id,
        tracker.acquireResourceUsage(),
        indirect_draw.IndirectDrawMetadata.init(allocator),
    ) catch |err| {
        try std.testing.expectEqual(Status.error_in_recording, context.status);
        try std.testing.expectEqual(no_encoder, context.current_id);
        try std.testing.expect(tracker.usage.attachment_state == null);
        return err;
    };
    var finished = context.finish() catch |err| {
        try std.testing.expectEqual(Status.finished, context.status);
        try std.testing.expectEqual(@as(u32, 2), state.header.reference_count);
        return err;
    };
    defer finished.deinit(allocator, std.testing.io, &guard);
    try std.testing.expectEqual(@as(u32, 2), state.header.reference_count);
}

test "context finish refuses open passes and invalidated zero encoder identities" {
    var mutex: std.Io.Mutex = .init;
    var callback_context: u8 = 0;
    var device = core.Device.init(std.testing.allocator, .{
        .object_mutex = &mutex,
        .uncaptured_context = &callback_context,
        .uncaptured_callback = unexpectedContextError,
    });
    var guard = core.ObjectGuard.lockUncancelable(std.testing.io, device.borrow().objects);
    defer guard.unlock(std.testing.io);
    defer device.deinit(std.testing.allocator, &guard) catch @panic("references leaked");
    var context = try Context.init(std.testing.allocator, device.borrow(), 4096, false);
    defer context.deinit(std.testing.io, &guard);
    _ = context.open();
    _ = context.enterPass();
    try std.testing.expectError(error.PassLocked, context.finish());
    try std.testing.expectEqual(Status.open, context.status);
    context.status = .error_in_recording;
    context.current_id = no_encoder;
    try std.testing.expectError(error.EncoderInvalidated, context.finish());
    try std.testing.expectError(
        error.EncoderInvalidated,
        context.validateCanEncodeOn(no_encoder, false),
    );
    context.deinit(std.testing.io, &guard);
    try std.testing.expectError(error.EncoderDestroyed, context.finish());
}
