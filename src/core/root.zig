//! `core`: the object lifetime policy and the error sets.
//!
//! **What this package is.** `docs/10-architecture.md` fixes `core` as the
//! module that owns object lifetime policy, error sets, futures and string
//! views. This file is what milestone M3 of `docs/40-plan.md` adds: the object
//! model, the three error sets, the error payload, the scopes and the sink.
//!
//! **What this file does not claim.** It does not claim futures. Dawn's
//! `AsyncTask` and `FutureUtils` are read for milestone M3 and land with the
//! worker pool at M4, because `std.Io.Future` needs a pool to be worth
//! anything. It does not claim a device beyond the arena, the scope stack and
//! the injector either.

const device = @import("device.zig");
const error_injector = @import("error_injector.zig");
const error_scope = @import("error_scope.zig");
const errors = @import("errors.zig");
const handle = @import("handle.zig");
const object = @import("object.zig");

// The error sets. A function that can fail validation and can lose the device
// declares `ValidationError || DeviceLostError`, and a reader enumerates every
// failure mode from the signature.
pub const ValidationError = errors.ValidationError;
pub const DeviceLostError = errors.DeviceLostError;
pub const UnrecoverableError = errors.UnrecoverableError;
pub const Error = errors.Error;
pub const ErrorClass = errors.ErrorClass;
pub const ErrorCode = errors.ErrorCode;
pub const ErrorContext = errors.ErrorContext;
pub const ErrorData = errors.ErrorData;
pub const message_table = errors.message_table;
pub const codeFromError = errors.codeFromError;
pub const classOf = errors.classOf;
pub const nameOf = errors.nameOf;

// The scopes and the sink.
pub const ErrorFilter = error_scope.ErrorFilter;
pub const ErrorScope = error_scope.ErrorScope;
pub const ErrorScopeStack = error_scope.ErrorScopeStack;
pub const ErrorSink = error_scope.ErrorSink;
pub const matchesFilter = error_scope.matchesFilter;

// The failure injector.
pub const ErrorInjector = error_injector.ErrorInjector;

// The object model.
pub const Device = device.Device;
pub const Handle = handle.Handle;
/// The handle's pointer type and the alignment it carries, so a module that
/// builds a handle names them instead of re-deriving the alignment.
pub const ObjectPtr = handle.ObjectPtr;
pub const object_alignment = handle.object_alignment;
pub const kindName = handle.kindName;
pub const DestroyReason = object.DestroyReason;
pub const Object = object.Object;
pub const ObjectArena = object.ObjectArena;
pub const ObjectList = object.ObjectList;
pub const ObjectState = object.State;
pub const CreateOptions = object.CreateOptions;
