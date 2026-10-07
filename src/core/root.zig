//! Core object identity, guarded reference lifetimes, and error ownership.
//!
//! Each device binds a stable caller-owned object mutex. Create, attach,
//! resolve, retain, release, and payload retirement require ObjectGuard.
//! Payload retirement leaves reference ledgers and arena headers intact; final
//! deinit refuses user/internal references and then reclaims the one arena.
//! Copying handles or borrows does not retain. Owned error scopes share this
//! guard; accepted-task leases retain stable records past pop, and explicit
//! post-unlock deliveries own immutable diagnostics through callback return.

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
pub const ErrorDraft = errors.ErrorDraft;
pub const ErrorView = errors.ErrorView;
pub const ErrorRef = errors.ErrorRef;
pub const ErrorReservation = errors.ErrorReservation;
pub const ErrorRetainError = errors.ErrorRetainError;
pub const ErrorReferenceCountError = errors.ErrorReferenceCountError;
pub const message_table = errors.message_table;
pub const codeFromError = errors.codeFromError;
pub const classOf = errors.classOf;
pub const nameOf = errors.nameOf;

// The scopes and the sink.
pub const ErrorFilter = error_scope.ErrorFilter;
pub const ScopeRecord = error_scope.ScopeRecord;
pub const ScopeResult = error_scope.ScopeResult;
pub const ScopeTicket = error_scope.ScopeTicket;
pub const ScopeBinding = error_scope.ScopeBinding;
pub const OwnedScopeBinding = error_scope.OwnedScopeBinding;
pub const PreparedScopeBinding = error_scope.PreparedScopeBinding;
pub const ScopeBindingOptions = error_scope.ScopeBindingOptions;
pub const ScopeBindingRelease = error_scope.ScopeBindingRelease;
pub const ScopeReleaseContextFn = error_scope.ScopeReleaseContextFn;
pub const PopBoundResult = error_scope.PopBoundResult;
pub const PopBoundError = error_scope.PopBoundError;
pub const prepareBinding = error_scope.prepareBinding;
pub const ScopeLeaseSet = error_scope.ScopeLeaseSet;
pub const ScopeSettlement = error_scope.ScopeSettlement;
pub const ScopeCaptureMask = error_scope.ScopeCaptureMask;
pub const ScopeNotifyFn = error_scope.ScopeNotifyFn;
pub const ScopeAllocationError = error_scope.ScopeAllocationError;
pub const ScopeTakeError = error_scope.ScopeTakeError;
pub const ScopeWaitError = error_scope.ScopeWaitError;
pub const PopError = error_scope.PopError;
pub const UncapturedDelivery = error_scope.UncapturedDelivery;
pub const UncapturedErrorCallback = error_scope.UncapturedErrorCallback;
pub const ErrorScopeStack = error_scope.ErrorScopeStack;
pub const ErrorSink = error_scope.ErrorSink;
pub const matchesFilter = error_scope.matchesFilter;

// The failure injector.
pub const ErrorInjector = error_injector.ErrorInjector;

// The object model.
pub const Device = device.Device;
pub const DeviceInitOptions = device.Device.InitOptions;
pub const HandleError = device.HandleError;
pub const CoreDeviceBorrow = handle.CoreDeviceBorrow;
pub const Handle = handle.Handle;
/// The handle's pointer type and the alignment it carries, so a module that
/// builds a handle names them instead of re-deriving the alignment.
pub const ObjectPtr = handle.ObjectPtr;
pub const object_alignment = handle.object_alignment;
pub const kindName = handle.kindName;
pub const DestroyReason = object.DestroyReason;
pub const DestroyFn = object.DestroyFn;
pub const CacheRemoveFn = object.CacheRemoveFn;
pub const ReferenceClass = object.ReferenceClass;
pub const ReferenceError = object.ReferenceError;
pub const LifetimeError = object.LifetimeError;
pub const CreateError = object.CreateError;
pub const ObjectGuard = object.ObjectGuard;
pub const Object = object.Object;
pub const ObjectArena = object.ObjectArena;
pub const ObjectList = object.ObjectList;
pub const ObjectState = object.State;
pub const CreateOptions = object.CreateOptions;
