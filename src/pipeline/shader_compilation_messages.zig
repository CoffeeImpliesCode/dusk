//! The diagnostics one shader-module creation produced.
//!
//! Ports the diagnostic records in `native/CompilationMessages.{h,cpp}`.
//! `one` owns its item array but borrows message text. `snapshot` and
//! `Messages.clone` own both the array and every text byte; their result is
//! independent of its source. Release each owned result once with `deinit`.
//!
//! **Every message the port produces is unanchored.** Dawn anchors a message
//! to a WGSL file: `AddMessage` (`CompilationMessages.cpp:116-181`) recomputes
//! all six positions and both UTF-16 counters from the file content. The port
//! parses no WGSL (`AGENTS.md` §3.2) and its one failure names the rule
//! `spirv.validate` broke, not a line of a source file, so every position is
//! zero. That is what `AddUnanchoredMessage` writes
//! (`CompilationMessages.cpp:88-97`), which is why the UTF-16 counting
//! helpers (`CompilationMessages.h:48`, `.cpp:56`) have no row here.
//!
//! **What this file does not claim.** It does not claim a message count. Dawn's
//! list grows with every Tint diagnostic; the port's list holds what the one
//! create pass produced, which is zero or one, and nothing appends to it
//! afterwards because the record is immutable from construction.

const std = @import("std");

/// Dawn's `wgpu::CompilationMessageType`, already generated at
/// `src/api/enums.zig:220-224`. The values are repeated here because this record
/// is the pipeline module's own and does not import the generated API surface;
/// the device method layer projects a `Message` onto the generated enum.
pub const MessageType = enum {
    /// Named with a trailing underscore because `error` is a Zig keyword. The
    /// generated enumeration spells it the same way
    /// (`src/api/enums.zig:221`).
    error_,
    warning,
    info,
};

/// One diagnostic. The nine fields are upstream's nine
/// (`CompilationMessages.h:51-61`): the text, the type, and the same three
/// positions counted twice, once in bytes of the source and once in UTF-16
/// code units.
pub const Message = struct {
    text: []const u8,
    type_: MessageType,

    /// Zero for every message the port produces, because nothing is anchored
    /// to a source position. The fields stay because the generated API record
    /// (`src/api/descriptors.zig:499-520`) has them and a projection that
    /// invented values would report positions that do not exist.
    line_num: u64 = 0,
    line_pos_in_bytes: u64 = 0,
    offset_in_bytes: u64 = 0,
    length_in_bytes: u64 = 0,
    line_pos_in_utf16: u64 = 0,
    offset_in_utf16: u64 = 0,
    length_in_utf16: u64 = 0,

    /// A message with no position, which is the only kind the port has.
    pub fn unanchored(text: []const u8, type_: MessageType) Message {
        return .{ .text = text, .type_ = type_ };
    }
};

/// Immutable diagnostic records with one owner for their allocated storage.
///
/// `one` borrows text; `snapshot` and `clone` copy it. The allocator's backing
/// state must outlive this record. Assignment aliases storage and does not
/// create another owner. Readers may share a record until its owner deinits it.
pub const Messages = struct {
    allocator: std.mem.Allocator,
    /// Owned array. An accessor's borrowed copy must not release it.
    items: []const Message,
    /// Exact text allocation from `snapshot`, or empty for borrowed text.
    owned_text: []const u8 = &.{},

    /// Releases owned text and the item array, never caller-owned text.
    /// Call once on the owner, not on a borrowed copy. All views then expire.
    pub fn deinit(self: Messages) void {
        if (self.owned_text.len != 0) self.allocator.free(self.owned_text);
        if (self.items.len != 0) self.allocator.free(self.items);
    }

    /// Copies all records and text into an independent owner. `source` must
    /// stay valid and unchanged through this call. See `snapshot` for errors.
    pub fn clone(
        allocator: std.mem.Allocator,
        source: Messages,
    ) std.mem.Allocator.Error!Messages {
        return snapshot(allocator, source.items);
    }

    /// How many messages carry `type_`. `getCompilationInfo` on a module that
    /// compiled clean answers zero for both of the types that fail a build.
    pub fn countOf(self: Messages, type_: MessageType) usize {
        // Bound: the slice.
        var count: usize = 0;
        for (self.items) |message| {
            if (message.type_ == type_) count += 1;
        }
        return count;
    }

    /// Ports `OwnedCompilationMessages::HasWarningsOrErrors`
    /// (`CompilationMessages.cpp:279-282`).
    pub fn hasWarningsOrErrors(self: Messages) bool {
        return self.countOf(.error_) != 0 or self.countOf(.warning) != 0;
    }
};

/// The no-message record. It allocates nothing, because a module that compiled
/// clean is the case the acceptance test asserts and the common one in a build.
pub fn empty(allocator: std.mem.Allocator) Messages {
    return .{ .allocator = allocator, .items = &.{} };
}

/// Owns one allocated item while borrowing `message.text` unchanged.
/// The caller keeps text alive and unchanged until the record is released.
pub fn one(
    allocator: std.mem.Allocator,
    message: Message,
) std.mem.Allocator.Error!Messages {
    const items = try allocator.alloc(Message, 1);
    items[0] = message;
    return .{ .allocator = allocator, .items = items };
}

/// Copies every metadata field and text byte into independent owned storage.
///
/// `source` and its text must stay valid and unchanged through this call only.
/// Empty text becomes `""`; no source pointer is retained. Nonempty records use
/// one item allocation and at most one contiguous text allocation. The caller
/// releases the result once with `deinit`.
///
/// Returns `error.OutOfMemory` if checked storage sizes overflow or an
/// allocation fails. On error no allocation survives and `source` is unchanged.
pub fn snapshot(
    allocator: std.mem.Allocator,
    source: []const Message,
) std.mem.Allocator.Error!Messages {
    if (source.len == 0) return empty(allocator);
    _ = std.math.mul(usize, source.len, @sizeOf(Message)) catch return error.OutOfMemory;
    var text_byte_count: usize = 0;
    for (source) |message| {
        text_byte_count = std.math.add(usize, text_byte_count, message.text.len) catch
            return error.OutOfMemory;
    }

    const items = try allocator.alloc(Message, source.len);
    errdefer allocator.free(items);
    const text: []u8 = if (text_byte_count == 0)
        &.{}
    else
        try allocator.alloc(u8, text_byte_count);
    errdefer if (text.len != 0) allocator.free(text);

    var text_offset: usize = 0;
    for (source, items) |message, *copied| {
        copied.* = message;
        if (message.text.len == 0) {
            copied.text = "";
        } else {
            const text_end = text_offset + message.text.len;
            @memcpy(text[text_offset..text_end], message.text);
            copied.text = text[text_offset..text_end];
            text_offset = text_end;
        }
    }
    std.debug.assert(text_offset == text_byte_count);
    return .{ .allocator = allocator, .items = items, .owned_text = text };
}

/// The log text `AddFormattedTintMessages` builds
/// (`CompilationMessages.cpp:192-233`), or null when there is nothing to say.
///
/// Dawn returns nothing when there is no error and no warning (`:216-218`),
/// and it keeps the "(s)" spelling (`:223`, `:229`) because a caller printing a
/// build log matches on it. The messages follow the sentence one per line,
/// where Dawn appends its formatted diagnostic list; the port has no
/// positions to format, so it appends the texts.
pub fn formattedLog(
    allocator: std.mem.Allocator,
    messages: Messages,
) std.mem.Allocator.Error!?[]u8 {
    const error_count = messages.countOf(.error_);
    const warning_count = messages.countOf(.warning);
    if (error_count == 0 and warning_count == 0) return null;

    var log: std.ArrayList(u8) = .empty;
    errdefer log.deinit(allocator);
    try log.print(allocator, "{d} error(s) and {d} warning(s) generated while " ++
        "compiling the shader:\n", .{ error_count, warning_count });

    // Bound: the slice.
    for (messages.items) |message| {
        try log.print(allocator, "\n{s}", .{message.text});
    }
    const owned = try log.toOwnedSlice(allocator);
    return owned;
}
