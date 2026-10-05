//! The handle, and the one byte that says what it points at.
//!
//! **What this file is.** `docs/30-port-design.md` §1.1 fixes a handle as a
//! pointer into the device arena plus one byte of kind.
//!
//! **What this file does not claim.** It does not claim the handle is safe
//! after the device is destroyed. The arena owns the memory, so a stale handle
//! reads defined memory until `Device.deinit`, and it dangles after. §1.1 says
//! the model does not cover that case.

/// The alignment every handle pointer carries.
///
/// `src/core/object.zig` makes `header: Object` the first field of every arena
/// object at compile time, so a handle always names storage laid out for one.
/// `Object` holds pointers, a slice and a function pointer, so its alignment is
/// the pointer alignment, and `object.zig` asserts the two agree. The field
/// carries the alignment so `Device.resolveHeader` casts without a run-time
/// check, and so a `?*anyopaque` from the generated API objects is checked once
/// at the boundary where the type is lost rather than at every read.
pub const object_alignment: u29 = @alignOf(usize);
pub const ObjectPtr = *align(object_alignment) anyopaque;

/// A handle carries no state of its own. Copying one is a pointer copy, and
/// there is no destructor, no `deinit` and no `release` on the handle itself.
pub const Handle = struct {
    ptr: ObjectPtr,
    kind: Kind,
    /// What the pointer points at. The API layer checks this byte at a boundary
    /// and reports a validation error, so a buffer cannot be passed where a
    /// device belongs.
    ///
    /// The typed aliases come from `dawn.json` at the milestone that generates
    /// `src/api`. A kind is added when the module that owns that object lands:
    /// M11 owns `texture`, `texture_view` and `sampler`, the three names
    /// `generator/templates/dawn/native/ObjectType.h:40-43` generates for them.
    /// M19 adds `query_set` for `ObjectType::QuerySet`, which `QuerySetBase::GetType`
    /// returns (`src/dawn/native/QuerySet.cpp:120`).
    pub const Kind = enum {
        instance,
        adapter,
        device,
        buffer,
        pipeline,
        texture,
        texture_view,
        sampler,
        query_set,
    };
};

/// The kind byte as text. A mismatch message names the kind the caller passed,
/// which is the value the caller can check against its own descriptor.
pub fn kindName(kind: Handle.Kind) []const u8 {
    return @tagName(kind);
}
