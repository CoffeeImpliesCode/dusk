//! The failure injector. A test turns it on, names the call it wants to fail,
//! and every rule below that point fails instead.
//!
//! **What this file is.** The port of Dawn's `ErrorInjector`
//! (`src/dawn/native/ErrorInjector.h`, `src/dawn/native/ErrorInjector.cpp`),
//! which `DAWN_ENABLE_ERROR_INJECTION` builds and the Vulkan error checks call
//! into (`src/dawn/native/vulkan/VulkanError.h:51`).
//!
//! **What this file does not claim.** It does not claim Dawn's build flag. Dawn
//! compiles the injector out unless `DAWN_ENABLE_ERROR_INJECTION` is set
//! (`src/dawn/native/ErrorInjector.h:33`), and its state lives in four
//! file-scope globals (`src/dawn/native/ErrorInjector.cpp:39-42`). The port has
//! no build flag and no global: the device owns one of these and hands it down.

/// Dawn can hold one injected error at a time
/// (`src/dawn/native/ErrorInjector.cpp:80`). The port reports the second
/// request as an error instead of asserting, so a test that asks twice finds
/// out.
const std = @import("std");
pub const InjectionError = error{InjectionAlreadyPending};

pub const ErrorInjector = struct {
    is_enabled: bool = false,
    /// How many injection points the run has reached. Dawn's `sNextIndex`
    /// (`src/dawn/native/ErrorInjector.cpp:40`).
    next_index: u64 = 0,
    injected_failure_index: u64 = 0,
    has_pending_injected_error: bool = false,

    pub fn init() ErrorInjector {
        return .{};
    }

    pub fn enable(self: *ErrorInjector) void {
        self.is_enabled = true;
    }

    pub fn disable(self: *ErrorInjector) void {
        self.is_enabled = false;
    }

    /// Forgets the reached count and any pending error. Dawn's
    /// `ClearErrorInjector` (`src/dawn/native/ErrorInjector.cpp:54-57`) does
    /// exactly these two writes.
    pub fn clear(self: *ErrorInjector) void {
        self.next_index = 0;
        self.has_pending_injected_error = false;
    }

    pub fn enabled(self: *const ErrorInjector) bool {
        return self.is_enabled;
    }

    /// How many injection points the run reached, then forgets them. Dawn's
    /// `AcquireErrorInjectorCallCount`
    /// (`src/dawn/native/ErrorInjector.cpp:63-67`) does the same, so a test
    /// knows how many calls its code made.
    pub fn acquireCallCount(self: *ErrorInjector) u64 {
        const count = self.next_index;
        self.clear();
        return count;
    }

    /// Consumes one injection point and says whether this one fails.
    pub fn shouldInjectError(self: *ErrorInjector) bool {
        const index = self.next_index;
        self.next_index += 1;
        if (!self.has_pending_injected_error) return false;
        if (index != self.injected_failure_index) return false;
        self.has_pending_injected_error = false;
        return true;
    }

    /// Fails the injection point at `index`.
    pub fn injectErrorAt(self: *ErrorInjector, index: u64) InjectionError!void {
        if (self.has_pending_injected_error) return error.InjectionAlreadyPending;
        self.injected_failure_index = index;
        self.has_pending_injected_error = true;
    }

    /// The error to raise instead of running the body, or null when the body
    /// runs.
    ///
    /// Dawn's `INJECT_ERROR_OR_RUN` (`src/dawn/native/ErrorInjector.h:64-74`)
    /// wraps the statement and the candidates in a macro. Zig has no macro, so
    /// the caller writes the two steps:
    ///
    /// ```zig
    /// const candidates = [_]errors.UnrecoverableError{ .OutOfHostMemory };
    /// if (injector.maybeInjectError(errors.UnrecoverableError, &candidates)) |injected| {
    ///     return injected;
    /// }
    /// ```
    ///
    /// The candidates are read in order and one is tested per call, which is
    /// Dawn's recursion at `src/dawn/native/ErrorInjector.h:51-56`. The bound is
    /// the slice length: an empty slice tests nothing and injects nothing.
    ///
    /// A disabled injector returns null without consuming an index, so a test
    /// that enables it part-way through counts from the point it was enabled.
    /// Dawn gets the same effect from the `if` at
    /// `src/dawn/native/ErrorInjector.h:66`.
    pub fn maybeInjectError(
        self: *ErrorInjector,
        comptime ErrorSet: type,
        candidates: []const ErrorSet,
    ) ?ErrorSet {
        if (!self.is_enabled) return null;
        const candidate_count = candidates.len;
        for (candidates[0..candidate_count]) |candidate| {
            if (self.shouldInjectError()) return candidate;
        }
        return null;
    }
};

test "the injector fails exactly the call it was pointed at" {
    const Injectable = error{ OutOfHostMemory, OutOfDeviceMemory };
    const one = [_]Injectable{error.OutOfHostMemory};

    var injector: ErrorInjector = .init();
    try std.testing.expect(!injector.enabled());

    // A disabled injector is free: it consumes no index.
    try std.testing.expect(injector.maybeInjectError(Injectable, &one) == null);
    try std.testing.expectEqual(@as(u64, 0), injector.acquireCallCount());

    injector.enable();
    try std.testing.expect(injector.enabled());
    try std.testing.expect(injector.maybeInjectError(Injectable, &one) == null);
    try std.testing.expect(injector.maybeInjectError(Injectable, &one) == null);
    try std.testing.expectEqual(@as(u64, 2), injector.acquireCallCount());

    // Point at the second call the enabled injector has seen.
    try injector.injectErrorAt(1);
    try std.testing.expect(injector.maybeInjectError(Injectable, &one) == null);
    try std.testing.expectEqual(
        @as(?Injectable, error.OutOfHostMemory),
        injector.maybeInjectError(Injectable, &one),
    );

    // The injected error is spent, so the next call runs the body.
    try std.testing.expect(injector.maybeInjectError(Injectable, &one) == null);

    // Two candidates in one call are two injection points, because Dawn's
    // `MaybeInjectError` tests one error type per recursion
    // (`src/dawn/native/ErrorInjector.h:50-56`), so a call that runs the body
    // spends `candidates.len` indices. `next_index` is 3 here, the call below
    // spends 3 and 4, and the call after it opens on 5.
    const two = [_]Injectable{ error.OutOfHostMemory, error.OutOfDeviceMemory };
    try injector.injectErrorAt(5);
    try std.testing.expect(injector.maybeInjectError(Injectable, &two) == null);
    try std.testing.expectEqual(
        @as(?Injectable, error.OutOfHostMemory),
        injector.maybeInjectError(Injectable, &two),
    );

    try injector.injectErrorAt(0);
    try std.testing.expectError(error.InjectionAlreadyPending, injector.injectErrorAt(1));

    injector.clear();
    try std.testing.expect(injector.maybeInjectError(Injectable, &one) == null);

    injector.disable();
    try std.testing.expect(!injector.enabled());
}
