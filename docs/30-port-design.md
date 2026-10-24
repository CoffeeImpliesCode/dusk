# Native API contracts

## Ownership and lifetime

Generated `api` objects contain opaque handles. Copying a handle does not retain
its owner. Their declarations do not provide general ownership or a complete
WebGPU procedure implementation. The typed native owners live in `engine`.

An `Instance` must reach its final address before adapter discovery or root
handle export. Adapter and physical-device lists retain their instance.
Devices retain their adapter, physical-device record, and instance.
Do not move these owners while children borrow them.
List and instance teardown refuse live children without consuming ownership.

Native resources have separate user references, dependency references, and GPU
leases. A resource factory returns a user reference. `Device.retain` creates
another user reference. `Device.release` consumes one. Copying a resource pointer
does not retain it. Strong dependencies and pending GPU use can keep its payload
alive after the final user release.

`Device.destroy` stops device work and retires native payloads. It retains host
aliases, the object arena, the original mutex, and parent references.
User aliases remain available for final release after logical destruction.
`Device.deinit` refuses outstanding user references, then releases host storage
and parent references. Final teardown invalidates arena-backed handles and
borrowed metadata. Use the allocator that owns the device storage.

A nonterminal completion failure keeps stopped native owners available for a
cleanup retry. Terminal Vulkan device loss permits lifetime cleanup. It does not
supply a successful completion serial or valid readback data.

## Operations and queue leases

Native operations receive `std.Io` per call. Operation admission pins the device
before native access or a wait for its device mutex. Teardown refuses conflicting
active operations and callbacks. The device mutex is nonrecursive.

`Device.getQueue(io)` returns a `QueueLease`. The lease owns a device pin and the
queue-operation gate. It stores no `Io`. Do not copy the lease, move its device,
or independently deinitialize the underlying queue.

The queue borrow ends at `lease.deinit(io)`. Repeated deinitialization is safe on
the same lease value, not on independent copies. High-level submit, unmap, and
release operations refuse a live queue lease. Queue submission declares the
resources that GPU work retains.

Native factories are synchronous. `Device.submit` consumes a finished command
stream once replay starts. `Device.wait(io, serial)` waits explicitly.
The command interface does not make all device calls asynchronous.

## Asynchronous requests

`engine.async_root_requests` handles instance, adapter, and device requests.
Completion registries track futures and callback delivery.
The request uses either the generated callback route or the native observer
route. A copied root handle does not retain its result owner.

Keep the retained-state allocator live through root release and disposal.
Keep the worker-pool initialization I/O provider live until pool join.
Each submitted I/O provider must outlive its task. Callback userdata remains
borrowed even when descriptor labels, features, and limits are copied.

A native `RootOutcome` failure transfers a `core.ErrorRef` to the receiver.
The receiver must release it. `RootReleaseResult.consumed` determines whether the
handle remains valid. A false value preserves the owner for retry. A true value
invalidates the handle even when `failure` reports an error.

Device async modules cover pipeline requests, mapping, queue completion, error
scopes, and shader compilation information. Their exported declarations do not
establish full generated-API parity.

## Descriptors and errors

Generated descriptor-chain types collect supported extensions as optional
fields. Unsupported root descriptor fields produce typed request failures.
Check the operation's error set and the lifetime comments on borrowed slices.

Vulkan dispatch uses C result constants. The Vulkan layer maps results into Zig
errors. Engine operations expose boundary-specific errors for validation,
allocation, unsupported capabilities, device loss, and cleanup.
Error scopes and native error references have separate ownership from resource
handles.

## SPIR-V stage inputs

`pipeline.pipeline.StageInput` carries a Vulkan shader module, entry point,
stage, authoritative SPIR-V bytes, and optional `api.ConstantEntry` overrides.
The bytes must match the native module. Keep override entries and their key
bytes alive and unchanged during creation and cache-key construction.
An empty override slice requests shader defaults.

Keys accept canonical decimal `SpecId` strings or unambiguous `OpName` aliases.
Values are finite `f64` scalars converted to the declaration's type.
Integer values must lie in range before truncation toward zero.
All declarations sharing a `SpecId` must convert to the same size and raw bits.
Unknown, duplicate, ambiguous, unsupported, nonfinite, or out-of-range values
produce errors before native pipeline creation.

Specialization stores Vulkan data in native byte order. Its canonical cache
bytes use sorted IDs and little-endian scalar records without ABI padding.
Equivalent aliases, input order, and converted bits share a key. Different
converted bits produce different keys. Keep the owned `Specialization` storage
live until the Vulkan pipeline creation call returns, then deinitialize it.

## Formats and copy geometry

`engine.format` separates canonical format identity from feature-dependent
capabilities. A format entry can exist while its operation remains unsupported.
Required features and compatibility-mode rules determine availability.

`engine.block_info` uses distinct texel and block count types. Conversions check
overflow, exact division, and narrowing to API integers. Zero block metadata is
unset and cannot support arithmetic. Blocks are two-dimensional, so depth
conversions preserve depth.

See [architecture](10-architecture.md) for the module layout and generation
inputs. The existing acceptance tests contain concrete lifetime, async, shader,
and resource examples.
