//! The diagnostics one shader-module creation produced.
//!
//! Ports `native/CompilationMessages.{h,cpp}`. Dawn splits the table in two:
//! `ParsedCompilationMessages` (`CompilationMessages.h:69`) is what Tint fills,
//! and `OwnedCompilationMessages` (`:94`) is the immutable owning form that
//! builds the pointer chain the C API hands out (`CompilationMessages.cpp:236-268`).
//! The port has one form, because the thing it fills is a Zig slice and the
//! thing the C API reads is a slice of generated structs the device layer
//! projects.
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

/// The messages one shader module carries. Immutable after construction, so a
/// reader needs no lock, which is the property Dawn gets from `NonMovable` and
/// never writing a member again (`CompilationMessages.h:91-93`).
pub const Messages = struct {
    allocator: std.mem.Allocator,
    items: []const Message,

    /// Releases the slice. An empty record holds the empty slice and not an
    /// allocation, so there is nothing to free.
    pub fn deinit(self: Messages) void {
        if (self.items.len == 0) return;
        self.allocator.free(self.items);
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

/// One message, held in a one-element slice.
///
/// Ports `ParsedCompilationMessages::AddMessage(CompilationMessageContent&&)`
/// (`CompilationMessages.cpp:180-182`), which appends a record somebody else
/// built. The port takes one record rather than a vector because there is one
/// producer and one consumer, and a one-element allocation is the whole
/// difference between a list and no list.
pub fn one(
    allocator: std.mem.Allocator,
    message: Message,
) std.mem.Allocator.Error!Messages {
    const items = try allocator.alloc(Message, 1);
    items[0] = message;
    return .{ .allocator = allocator, .items = items };
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
