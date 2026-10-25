# dusk

A Zig implementation of a WebGPU-style GPU engine, based on
[Dawn](https://dawn.googlesource.com/dawn), with a Vulkan backend.

Experimental. The API is incomplete and unstable. WebGPU conformance and broad
platform support are not established.

The library accepts SPIR-V shaders. It does not include a WGSL compiler or link
Dawn C++. A null backend supports CPU-only tests.

## Requirements

- Zig 0.17.0.
- libc, linked through the published module.
- A Vulkan loader and a Vulkan 1.1-capable driver for native execution.
  Individual operations can require additional device features.

Generated Vulkan bindings and shader binaries are checked in. Ordinary consumers
do not need Vulkan headers or Tint. The optional Nix development environment
supplies development tools, a Vulkan loader, validation layers, and lavapipe.
Validation layers are not a library runtime requirement.

## Use

The build publishes the Zig module `dusk`. It does not publish an executable,
a C library, or an artifact named `dusk`.

For a local checkout, add this entry to your `build.zig.zon` dependencies:

```zig
.dusk = .{ .path = "../dusk" },
```

In your `build.zig`, import the module into your executable:

```zig
const dusk = b.dependency("dusk", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("dusk", dusk.module("dusk"));
```

For example, enumerate Vulkan adapters with caller-supplied allocation and I/O:

```zig
const std = @import("std");
const dusk = @import("dusk");

pub fn discover(allocator: std.mem.Allocator, io: std.Io) !void {
    var instance = dusk.engine.Instance.init(.{ .backend_type = .vulkan });
    defer instance.deinit(allocator, io) catch @panic("instance teardown failed");

    var adapters = try instance.enumerateAdapters(allocator, io, .{
        .backend_type = .vulkan,
        .feature_level = .core,
        .power_preference = .undefined_,
    });
    defer adapters.deinit(io) catch @panic("adapter teardown failed");

    for (adapters.items) |*adapter| {
        _ = adapter.getFeatureLevel();
    }
}
```

Keep owners at stable addresses while children borrow them. See the
[lifetime contracts](docs/30-port-design.md) before creating devices or resources.
The existing [native device tests](test/native_device.zig) show resource and queue
operations.

## Build and test

```sh
zig build               # configure the graph; no default compile artifact
zig build test          # full suite; requires a working Vulkan driver
zig build cross-test    # CPU-only Debug library tests
zig build test-null-device # CPU-only null-backend tests
zig build test-memory   # CPU-only memory acceptance shard
```

`zig build test` includes native GPU tests and needs a working Vulkan driver.
Lavapipe supports these offscreen tests without a display. These tests do not
establish support for every surface, external-memory mechanism, or operating system.
On high-core-count hosts, use `LP_NUM_THREADS=2 zig build test` with lavapipe.
The development shell sets this limit to keep the driver worker pool within the
test process address-space limit.

For the optional development shell, run `devenv shell`.

## Generated files

`zig build generate -Dheader-dir=/path/to/include` rewrites `src/vulkan.zig` and
`src/vk/dispatch.zig`. The include directory must contain
`vulkan/vulkan_core.h` and `vk_video` from the pinned Vulkan-Headers tree.
`DUSK_VULKAN_HEADERS` supplies the default in the development shell.
See [generation inputs](docs/10-architecture.md#generation-inputs) for the pin and
shader tooling.

## Design

- [Architecture and generation inputs](docs/10-architecture.md)
- [Ownership, concurrency, and shader contracts](docs/30-port-design.md)

## License

Dawn-derived port code, generated API bindings, and shader sources and binaries retain Dawn’s BSD-3-Clause terms. The generated Vulkan bindings use Khronos’s MIT option.

MIT, see [LICENSE](LICENSE). Third-party components keep their own licenses: see THIRD_PARTY_NOTICES.md
