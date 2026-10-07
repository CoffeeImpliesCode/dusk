//! Borrowed object handles and the immutable canonical device locator.
//!
//! Handle copies and CoreDeviceBorrow copies acquire no reference. Payload
//! retirement preserves retained headers; final core Device.deinit invalidates
//! all pointers. A caller must hold a real owned alias/lease while borrowing
//! identity, and ObjectGuard while resolving or reading payload/header state.

const object = @import("object.zig");

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
        shader_module,
        bind_group_layout,
        pipeline_layout,
        bind_group,
        native_pipeline,
        native_buffer,
        attachment_state,
        render_bundle,
        external_texture,
    };
};

/// The kind byte as text. A mismatch message names the kind the caller passed,
/// which is the value the caller can check against its own descriptor.
pub fn kindName(kind: Handle.Kind) []const u8 {
    return @tagName(kind);
}

/// Borrows the list at its final stable address, without another header or
/// allocation. High owner metadata is bound once before resource publication.
/// Locating that owner grants no payload access or host lifetime pin by itself.
pub const CoreDeviceBorrow = struct {
    objects: *object.ObjectList,

    /// The immutable lock/ownership locator, valid through final core deinit.
    pub fn objectList(self: CoreDeviceBorrow) *object.ObjectList {
        return self.objects;
    }

    /// The once-bound high owner, or null for standalone core. Read only after
    /// binding/resource publication; the caller must then obtain its host pin.
    pub fn highOwner(self: CoreDeviceBorrow) ?*anyopaque {
        return self.objects.high_owner;
    }
};
