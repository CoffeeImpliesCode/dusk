//! The two checks every float a pass records has to pass.
//!
//! **What this file is.** The port of `src/dawn/native/ValidationUtils.{h,cpp}`:
//! `ValidateFloat` (`ValidationUtils.cpp:34-37`) and `ValidateColor`
//! (`ValidationUtils.cpp:39-46`). Dawn's versions take a `MaybeValError` and a
//! name used only in the message; the port returns the rule, because
//! `command` does not import `core`'s error sink and the caller names the value
//! in its own context.
//!
//! **What this file does not claim.** It does not claim these are the only
//! float rules. Dawn calls `ValidateFloat` from
//! `RenderPassEncoder.cpp:237-242`, `RenderPipeline.cpp:342-343` and
//! `Sampler.cpp:41-42` — ten calls across three files, two of which are not
//! M15 files. The port's five call sites are the ones the M15 encoders make.

const std = @import("std");
const commands = @import("commands.zig");
const errors = @import("errors.zig");

/// Dawn's `ValidateFloat`. A NaN or an infinity in a value a pass records is
/// a validation error, not something the replay has to tolerate.
pub fn validateFloat(value: f32) errors.Error!void {
    if (!std.math.isFinite(value)) return error.NonFiniteFloat;
}

/// Dawn's `ValidateColor`: every component, plus the alpha. Dawn tests the
/// four components in one `DAWN_INVALID_IF` (`ValidationUtils.cpp:39-44`),
/// and the port writes one call each.
pub fn validateColor(color: commands.Color) errors.Error!void {
    try validateFloat(color.r);
    try validateFloat(color.g);
    try validateFloat(color.b);
    try validateFloat(color.a);
}

/// Dawn's `SetViewport` validation at `RenderPassEncoder.cpp:227-242`: the four
/// extents and both depths must be finite. Dawn also refuses an inverted depth
/// range in the front end (`RenderPassEncoder.cpp:279-283`); the port carries
/// no such rule.
pub fn validateViewport(viewport: commands.SetViewportCmd) errors.Error!void {
    try validateFloat(viewport.x);
    try validateFloat(viewport.y);
    try validateFloat(viewport.width);
    try validateFloat(viewport.height);
    try validateFloat(viewport.min_depth);
    try validateFloat(viewport.max_depth);
}
