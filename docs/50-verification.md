# 50 — Verification

This document owns how correctness is proven on this machine: what a test may
observe, which layers and drivers it runs against, how a shader fixture is
produced, what the house gate proves, what a green gate leaves unproven, and
how a citation is resolved.


It adds no upstream claim of its own. Every statement about Dawn cites the
pinned tree at `32f77c02294310054a660c393feded4bcb3f203c` with a `path:line`,
or cites `docs/02-dawn-design.md`.

## Grades

Every claim in this document carries a grade.

| Grade | Meaning |
| --- | --- |
| A | Measured on this host. The command and its output are quoted. |
| B | Read from the pinned Dawn tree or the Vulkan registry, with `path:line`. |
| C | Decided here, with no measurement behind it. |

---

## 1. The host is headless

### 1.1 What was measured

Grade A. There is no display server.

```
$ echo "DISPLAY=[${DISPLAY-unset}] WAYLAND_DISPLAY=[${WAYLAND_DISPLAY-unset}]"
DISPLAY=[unset] WAYLAND_DISPLAY=[unset]
```

```
$ vulkaninfo --summary                      # inside devenv
'DISPLAY' environment variable not set... skipping surface info
```

The instance extension list outside devenv, on the four RTX A6000 devices,
holds 24 entries. Seven of them:

```
Vulkan Instance Version: 1.4.309
Instance Extensions: count = 24
VK_EXT_acquire_drm_display             : extension revision 1
VK_EXT_swapchain_colorspace           : extension revision 5
VK_KHR_display                         : extension revision 23
VK_KHR_surface                         : extension revision 25
VK_KHR_wayland_surface                 : extension revision 6
VK_KHR_xcb_surface                     : extension revision 6
VK_KHR_xlib_surface                    : extension revision 6
```

`VK_EXT_headless_surface` is not among the 24. `VK_KHR_display` is.

The instance extension list inside devenv, on lavapipe, holds 19 entries. Seven
of them:

```
Vulkan Instance Version: 1.4.357
Instance Extensions: count = 19
VK_EXT_debug_utils                    : extension revision 2
VK_EXT_headless_surface                : extension revision 1
VK_EXT_swapchain_colorspace           : extension revision 5
VK_KHR_surface                         : extension revision 25
VK_KHR_wayland_surface                 : extension revision 6
VK_KHR_xcb_surface                     : extension revision 6
VK_KHR_xlib_surface                    : extension revision 6
```

`VK_EXT_headless_surface` is present here. `VK_KHR_display` is not. The full
`vulkaninfo` output inside devenv holds zero lines matching `VK_KHR_display`:

```
$ vulkaninfo 2>/dev/null | grep -c "VK_KHR_display"
0
```

**This corrects the premise this document was written against.** The extension
is absent from the host list and present inside devenv. Neither list carries
both extensions, so no configuration on this machine can name a display for a
headless surface.

`AGENTS.md:174-176` states the corrected form: `VK_EXT_headless_surface` is
present inside devenv on lavapipe and absent outside it on NVIDIA, and
`VK_KHR_display` is the other way round. The rule it draws from that, at
`AGENTS.md:177-179`, is unchanged by the correction.

`UNKNOWN:` whether lavapipe accepts `vkCreateHeadlessSurfaceEXT` when
`VK_KHR_display` is absent. Settled by a small program that fills a
`VkHeadlessSurfaceCreateInfoEXT` with `.flags = 0` and
`.pNext = null`, calls `vkCreateHeadlessSurfaceEXT`, and prints the result
code. The outcome changes no decision in this document.

### 1.2 The decision

**Decision: a test observes a rendered result only by copying it out of an
image.**

- Priority: a test must observe a real rendered result, not a proxy for one.
- Constraint: no `DISPLAY`, no `WAYLAND_DISPLAY`, and no display in either
  extension list. A present path needs a display engine, and none exists.
- Cost imposed on consumers: `platform` ships no tested surface creation. A
  consumer that needs a window writes its own. The swapchain path, if it ever
  lands, has no test on this host.
- Counterchoice: `VK_EXT_headless_surface`. It genuinely wins on a machine that
  advertises both it and `VK_KHR_display` with a connected panel, because a
  present path exercises acquire and present, which a copy never touches. On
  this host neither configuration has both extensions.
- Grade: A for the measurements, C for the decision.

### 1.3 What the constraint permits

A test may create a `VkInstance`, an `XlibSurface`, and a `WaylandSurface`. The
window-system extensions are advertised on both drivers. A test may not create a
`VkSwapchainKHR`, because a swapchain needs a surface backed by a reachable
native window, and no such window exists. `AGENTS.md:177-179` states the same
rule for tests.

---

## 2. The offscreen render pipeline

### 2.1 The sequence at the WebGPU level

This is what a test writes. `command` records it and `engine` replays it into
`vk`, which is the split `docs/10-architecture.md:67-69` requires.

1. Create a texture with `usage = .render_attachment | .copy_src`,
   `format = .r8g8b8a8_unorm`, `size = { width_px, height_px, 1 }`, and a mip
   level count of 1.
2. Create a buffer with `usage = .copy_dst | .map_read` and
   `size = staging_byte_count` from §2.4.
3. `beginRenderPass` with one colour attachment whose `loadOp` is `.clear`,
   whose `clearValue` carries the expected bytes, and whose `storeOp` is
   `.store`.
4. `end`, then `copyTextureToBuffer` from that texture into that buffer.
5. `submit`.
6. `mapAsync(.read)`, wait, read the bytes, `unmap`.

### 2.2 The sequence at the Vulkan level

This is what `engine` and `vk` produce from those six steps.

1. `vkCreateImage` with `imageType = .e2d`,
   `format = VK_FORMAT_R8G8B8A8_UNORM`, `mipLevels = 1`, `arrayLayers = 1`,
   `samples = VK_SAMPLE_COUNT_1_BIT`, `tiling = VK_IMAGE_TILING_OPTIMAL`,
   `usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT`,
   `initialLayout = VK_IMAGE_LAYOUT_UNDEFINED`, `sharingMode = VK_SHARING_MODE_EXCLUSIVE`.
2. `vkCreateImageMemory`, `vkBindImageMemory`, `vkCreateImageView` with
   `viewType = VK_IMAGE_VIEW_TYPE_2D`, `subresourceRange` covering one layer and
   one mip level.
3. A `VkFramebuffer` with one `VkFramebufferAttachment`.
4. `vkCmdBeginRenderPass`. Its `renderArea` is
   `{{0, 0}, { width_px, height_px }}`, and its clear colour is a
   `VkClearColorValue` of the form `.{ .uint32 = { r, g, b, a } }`. Its single
   `VkAttachmentDescription` reads:

   | Field | Value |
   | --- | --- |
   | `format` | `VK_FORMAT_R8G8B8A8_UNORM` |
   | `samples` | `VK_SAMPLE_COUNT_1_BIT` |
   | `loadOp` | `VK_ATTACHMENT_LOAD_OP_CLEAR` |
   | `storeOp` | `VK_ATTACHMENT_STORE_OP_STORE` |
   | `stencilLoadOp` | `VK_ATTACHMENT_LOAD_OP_DONT_CARE` |
   | `stencilStoreOp` | `VK_ATTACHMENT_STORE_OP_DONT_CARE` |
   | `initialLayout` | `VK_IMAGE_LAYOUT_UNDEFINED` |
   | `finalLayout` | `VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL` |

   The image leaves the pass already in `TRANSFER_SRC_OPTIMAL`, so the copy
   needs no second barrier. A test that renders then copies therefore proves
   one layout transition, not two.
5. `vkCmdEndRenderPass`, then `vkCmdCopyImageToBuffer` with
   `srcImageLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL`.
6. `vkQueueSubmit` with one `VkSubmitInfo` whose `commandBufferCount` is 1,
   and a fence. The test waits on that fence with `vkWaitForFences`.
7. `vkMapMemory` at offset 0, read, `vkUnmapMemory`.

The staging buffer is a `VkBuffer` whose `usage` is
`VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_MAPPING_READ_BIT`, bound to
a memory type whose `memoryPropertyFlags` carry
`VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT`.
`HOST_COHERENT` means the test does not call `vkFlushMappedMemoryRanges` or
`vkInvalidateMappedMemoryRanges` after the map.

`docs/10-architecture.md:48` puts VMA under the device-memory layer. The
host-visible staging allocation is the one allocation a test asks VMA for by
hand, because the WebGPU surface has no concept of a host-visible heap.

### 2.3 The copy struct

The header is authoritative. `/usr/include/vulkan/vulkan_core.h:4083-4090`,
grade A for the file, grade B for the rule:

```c
typedef struct VkBufferImageCopy {
    VkDeviceSize                bufferOffset;
    uint32_t                    bufferRowLength;
    uint32_t                    bufferImageHeight;
    VkImageSubresourceLayers    imageSubresource;
    VkOffset3D                  imageOffset;
    VkExtent3D                  imageExtent;
} VkBufferImageCopy;
```

`src/vulkan.zig` is generated by `zig translate-c`
(`docs/10-architecture.md:13`, `docs/20-dependencies.md:52-55`). The generator
keeps the C spelling for these fields: `src/vulkan.zig:4531-4538` reads
`bufferOffset`, `bufferRowLength`, `bufferImageHeight`, `imageSubresource`,
`imageOffset` and `imageExtent`. The C names above are the contract, and they
are also the Zig names.

The mapping from the WebGPU copy fields:

| WebGPU field | `VkBufferImageCopy` field | Value in a test |
| --- | --- | --- |
| `buffer` | not a field | resolved to a `VkBuffer` by `engine` |
| `offset` | `bufferOffset` | `0` |
| `bytesPerRow` | `bufferRowLength` | `bytes_per_row / texel_block_size_byte_count` |
| `rowsPerImage` | `bufferImageHeight` | `height_texel_count`, or `0` for a single layer |
| `texture` | `imageSubresource` | `aspectMask = VK_IMAGE_ASPECT_COLOR_BIT`, `mipLevel = 0`, `baseArrayLayer = 0`, `layerCount = 1` |
| copy origin | `imageOffset` | `{ .x = 0, .y = 0, .z = 0 }` |
| `copySize` | `imageExtent` | `{ .width = width_texel_count, .height = height_texel_count, .depth = 1 }` |

`bufferRowLength` counts texels and `bytesPerRow` counts bytes. For
`R8G8B8A8_UNORM` the two are the same number. For a compressed format they are
not, and the division is required. Dawn makes the same conversion and says so
in a comment at `src/dawn/native/vulkan/UtilsVulkan.cpp:247-251`. Its block
overload converts blocks to texels at `UtilsVulkan.cpp:233`.

### 2.4 The alignment rule

Vulkan, grade B:

- `bufferRowLength` must be `0` or at least `imageExtent.width`.
  `/usr/share/vulkan/registry/validusage.json:39484-39486`,
  `VUID-VkBufferImageCopy-bufferRowLength-09101`.
- `bufferImageHeight` must be `0` or at least `imageExtent.height`.
  `validusage.json:39489-39490`,
  `VUID-VkBufferImageCopy-bufferImageHeight-09102`.
- `imageSubresource.aspectMask` must have one bit set.
  `validusage.json:39494-39495`,
  `VUID-VkBufferImageCopy-aspectMask-09103`.
- `imageExtent` must be non-zero in all three components.
  `validusage.json:39499-39511`.
- `bufferOffset` must be a multiple of `4` when the queue family supports
  neither graphics nor compute.
  `validusage.json:38936-38937`,
  `VUID-vkCmdCopyBufferToImage-commandBuffer-07737`.

Measured on lavapipe, grade A:

```
	optimalBufferCopyOffsetAlignment                = 0x00000080
	minMemoryMapAlignment                           = 64
	maxImageDimension2D                             = 16384
```

`0x00000080` is 128. The port uses `optimalBufferCopyOffsetAlignment` when the
device reports it non-zero, and `4` otherwise.

WebGPU is stricter than Vulkan here, and the port inherits that, grade B. Dawn
defines the constant at `src/dawn/common/Constants.h:44` and rejects a
misaligned stride at `src/dawn/native/CommandValidation.cpp:426-435`:

```cpp
    auto alignment = kTextureBytesPerRowAlignment;
    ...
        DAWN_INVALID_IF(texelCopyBufferInfo.layout.bytesPerRow % alignment != 0,
                        "bytesPerRow (%u) is not a multiple of %u.",
```

The port therefore computes:

```zig
texel_block_size_byte_count = 4;                      // R8G8B8A8_UNORM, 1 texel per pixel
bytes_per_row = alignForwardBytes(
    texel_block_size_byte_count * width_texel_count,
    256,
);
staging_byte_count = bytes_per_row * (height_texel_count - 1)
    + texel_block_size_byte_count * width_texel_count;
```

`alignForwardBytes` names its rounding rule in its own name, as
`AGENTS.md:58-59` requires. The result is a multiple of 128, so the Vulkan
offset rule holds for any buffer offset the port accepts, and a multiple of 256,
so the WebGPU stride rule holds by construction.

The staging size is the last row's true length, not the padded length. Padding
the final row as well is allowed and wastes at most 252 bytes, but the smaller
value keeps the test arithmetic checkable by hand.

### 2.5 The pixel format

`VK_FORMAT_R8G8B8A8_UNORM` is the default target. The Vulkan specification
makes it a mandatory format with `VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT`,
`VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT`, `VK_FORMAT_FEATURE_TRANSFER_SRC_BIT` and
`VK_FORMAT_FEATURE_TRANSFER_DST_BIT`, so every conformant implementation
accepts it. Grade C, from the specification, because the bit values were not
read on this host.

A test still asserts the bits through `vkGetPhysicalDeviceFormatProperties`
rather than assuming them. A driver that disagrees is a defect the test should
report, not a condition it should tolerate.

Two other formats have their own jobs:

| Format | Used for | The test must first check |
| --- | --- | --- |
| `VK_FORMAT_R8G8B8A8_UNORM` | clear-only tests, exact byte comparison | mandatory, no check needed |
| `VK_FORMAT_R16G16B16A16_SFLOAT` | shader arithmetic, no format quantisation | `VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT` |
| `VK_FORMAT_R4G4B4A4_UNORM` | the quantisation case in §3.3 | `VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT` |

`VK_FORMAT_R4G4B4A4_UNORM` is not a mandatory format. A test that uses it skips
itself when the query reports the bit missing. That skip is the first real use
of the predicate in §9.3.

`UNKNOWN:` the `linearTilingFeatures` bits lavapipe reports for
`VK_FORMAT_R16G16B16A16_SFLOAT` and `VK_FORMAT_R4G4B4A4_UNORM`. The full
`vulkaninfo` output inside devenv is 1575 lines, ends in the device-features
section, and holds no `R8G8B8A8_UNORM` line, so this `vulkaninfo` does not
report per-format properties. Settled by the format-property query the test
performs anyway.

---

## 3. Turning pixels into an assertion

### 3.1 The readback helper

One helper owns the whole path, so no test repeats the alignment arithmetic:

```zig
// test/support/Readback.zig
pub const ReadbackOptions = struct {
    allocator: std.mem.Allocator,
    device: *core.Device,
    texture: api.Texture,
    origin_px: api.Origin2D,
    extent_px: api.Extent2D,
    format: api.TextureFormat,
};

pub fn readTextureToHostBytes(options: ReadbackOptions) ![]align(4) u8;
pub fn freeHostBytes(allocator: std.mem.Allocator, bytes: []align(4) u8) void;
```

The house form for six named inputs is an options struct. `AGENTS.md:56-57`
requires one as soon as two parameters share a type.

Two rules the helper enforces:

1. It never returns padding. It copies `texel_block_size_byte_count *
   width_texel_count` bytes out of each row and advances by `bytes_per_row`.
   Vulkan leaves the bytes between the end of one row and the start of the next
   undefined, so a test that reads them is nondeterministic.
2. It fails when `vkGetPhysicalDeviceFormatProperties` reports no
   `VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT`, and it fails when device
   enumeration returned zero devices. See §5.3.

### 3.2 Exact equality

An exact comparison is right when the target carries no arithmetic. A
clear-only pass writes a byte quad that the driver copies without arithmetic,
so every bit is the caller's.

```zig
pub fn expectPixelsExact(options: PixelAssertOptions) !void;
```

`PixelAssertOptions` carries the same readback fields plus `expected: []const
u8`, one `u32` little-endian quad per pixel, and it compares with
`std.testing.expectEqualSlices(u8, ...)`.

A clear-only test proves: the clear value reached the attachment, the load and
store ops are the ones the pass asked for, the attachment format is the one the
test named, the copy read the right subresource, the extent is right, and no
missing barrier left the previous contents in place.

### 3.3 Approximate equality

An exact comparison is usually wrong for a floating-point target. A fragment
shader computes in `f32`, and the Vulkan specification grants no bit-exactness
across implementations. That is grade C, read from the specification rather
than measured. A driver may fuse a multiply and an add, reorder an expression,
or keep a different intermediate precision. llvmpipe and the NVIDIA driver are
two implementations, and a green suite must not depend on them agreeing bit for
bit.

```zig
pub fn expectPixelsAbsolute(options: PixelAssertOptions) !void;
```

The comparison is `@abs(actual - expected) <= tolerance` per channel, with the
expected values decoded into `[0, 1]`.

The tolerance follows the quantum of the target, not a habit:

| Target | Compare in | Tolerance | Reason |
| --- | --- | --- | --- |
| `R8G8B8A8_UNORM`, shader output | normalized `f32` | `1.0 / 255.0` | one code value of the format |
| `R16G16B16A16_SFLOAT`, shader output | `f32` | `1.0 / 512.0` | half a binary16 ULP at 1.0, which is `2^-11` |
| `R4G4B4A4_UNORM`, pass-through shader | code units | `0` | every expected value is exactly `k / 15` |
| `R4G4B4A4_UNORM`, shader with arithmetic | code units | `1` | one code value, which is `1 / 15` |

For a 4-bit unorm target the right tolerance is `0` when the shader writes
exactly representable values and the arithmetic is a copy. It is `1` code value
when a multiply or a divide sits in between, because a single rounding step can
cross a quantisation boundary. Compare in code units rather than in
normalized floats, so a failure reads "off by one code" instead of "off by
0.0667" and a rounding accident cannot satisfy the assertion.

Dawn draws the same line. `ExpectEq` takes a tolerance that defaults to zero
(`src/dawn/tests/DawnTest.h:1042`), `CheckImpl` for `float` compares
`abs(expected - actual) > tolerance` (`DawnTest.cpp:2552-2559`), the
`uint16_t` overload compares in integer code units (`DawnTest.cpp:2562-2571`),
and the macros `EXPECT_PIXEL_RGBA8_EQ` and
`EXPECT_PIXEL_FLOAT_TOLERANCE_EQ` select between them
(`DawnTest.h:125` and `DawnTest.h:134`).

### 3.4 Which catches which

| Defect | Exact on a clear | Absolute on a shader |
| --- | --- | --- |
| Wrong clear colour | catches | catches |
| Wrong `loadOp` or `storeOp` | catches | catches |
| Wrong attachment format | catches | catches |
| Wrong copy extent | catches | catches |
| Row pitch off by one byte | catches | catches |
| Missing layout transition before the copy | catches | catches |
| Wrong pipeline state | no coverage | catches |
| Wrong bind group or descriptor | no coverage | catches |
| Wrong vertex layout or interpolation | no coverage | catches |
| Driver rounding regression | no coverage | catches |

The exact comparison proves nothing about shader behaviour, because a
clear-only pass runs no shader. The approximate comparison cannot distinguish a
one-code difference from a real regression, so it never replaces the exact one.

### 3.5 The layer's contribution

A synchronisation defect, such as a barrier with the wrong stage mask, may not
change a single pixel on lavapipe, which executes serially. It is caught by the
layer, not by the readback. That is why the layer matrix in §4 and the readback
matrix here are both required. `devenv.nix:122-125` names the same two defects.

---

## 4. The layer matrix

### 4.1 What the shell sets

Grade A. `devenv.nix:114-137` sets, and the shell exports:

```
VK_LAYER_PATH=/nix/store/2p3ff6vbl8i2gyf2zvickc48k7hm9x0k-vulkan-validation-layers-1.4.357.0/share/vulkan/explicit_layer.d
VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
VK_LAYER_VALIDATE_SYNC=1
VK_LAYER_LOG_PATH=stderr
VK_LAYER_LOG_LEVEL=info
```

Inside devenv the layer resolves and announces itself:

```
Instance Layers: count = 1
VK_LAYER_KHRONOS_validation Khronos Validation Layer 1.4.357  version 1
```

Outside devenv the same variables are exported and the layer does not load:

```
ERROR: [Loader Message] Code 0 : Layer "VK_LAYER_KHRONOS_validation" was not found but was requested by env var VK_INSTANCE_LAYERS!
```

The cause is `VK_LAYER_PATH`, not a missing layer. It names a store path that
does not exist on this host:

```
$ ls -d /nix/store/2p3ff6vbl8i2gyf2zvickc48k7hm9x0k-vulkan-validation-layers-1.4.357.0
ls: cannot access '/nix/store/2p3ff6vbl8i2gyf2zvickc48k7hm9x0k-vulkan-validation-layers-1.4.357.0': No such file or directory
```

The host does carry a copy of the layer, at
`/usr/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json`, and it
loads when `VK_LAYER_PATH` is cleared. Grade A:

```
$ env -u VK_LAYER_PATH vulkaninfo --summary 2>/dev/null | sed -n '/^Instance Layers/,/^$/p'
Instance Layers: count = 3
VK_LAYER_KHRONOS_validation Khronos Validation Layer  1.4.309  version 1
VK_LAYER_NV_optimus         NVIDIA Optimus layer      1.4.351  version 1
VK_LAYER_NV_present         NVIDIA Presentation Layer 1.4.351  version 1
```

So the layer version a run reports is the one the search path names: 1.4.357
inside devenv, 1.4.309 outside it. Every layer-dependent result is an
inside-devenv result.

The layer writes to stderr, not to a file. Grade A, measured inside devenv:

```
$ vulkaninfo --summary 2>/dev/null | grep -c -E "^(WARNING|ERROR)"
0
$ vulkaninfo --summary 2>&1 >/dev/null | grep -c -E "^(WARNING|ERROR)"
2
```

### 4.2 The three configurations

A suite must cover three.

| Mode | Purpose | Environment |
| --- | --- | --- |
| `none` | prove the library runs with no layer | `VK_LOADER_LAYERS_DISABLE=*` |
| `validation` | prove the layer reports nothing | `VK_INSTANCE_LAYERS` removed, `VK_LOADER_LAYERS_ENABLE=VK_LAYER_KHRONOS_validation` |
| `validation_sync` | prove the barrier and queue hazards are absent | as above, plus the inherited `VK_LAYER_VALIDATE_SYNC=1` |

Per-process selection works, grade A:

```
$ VK_LOADER_LAYERS_DISABLE='*' vulkaninfo --summary 2>&1 | sed -n '/^Instance Layers/,/^$/p'
Instance Layers:
----------------
WARNING: [Loader Message] Code 0 : Layer "VK_LAYER_KHRONOS_validation" forced disabled because name matches filter of env var 'VK_LOADER_LAYERS_DISABLE'.
```

Each enabled mode clears `VK_INSTANCE_LAYERS` and selects the layer through
`VK_LOADER_LAYERS_ENABLE` instead. Grade A:

```
$ env -u VK_INSTANCE_LAYERS VK_LOADER_LAYERS_ENABLE=VK_LAYER_KHRONOS_validation \
      vulkaninfo --summary 2>/dev/null | sed -n '/^Instance Layers/,/^$/p'
Instance Layers: count = 1
--------------------------
VK_LAYER_KHRONOS_validation Khronos Validation Layer 1.4.357  version 1
```

The loader confirms the selection on stderr:

```
WARNING: [Loader Message] Code 0 : Layer "VK_LAYER_KHRONOS_validation" forced enabled due to env var 'VK_LOADER_LAYERS_ENABLE'
```

Clearing `VK_INSTANCE_LAYERS` is deliberate. It makes the selection explicit
in the child's environment instead of inherited from the shell, so a mode never
depends on what the shell happens to export.

The third mode inherits `VK_LAYER_VALIDATE_SYNC=1` from the shell as it stands.
§4.6 gives why that needs no adjustment per process.

### 4.3 How a suite selects the mode

A test binary spawns itself once per mode and reads the mode from
`DUSK_TEST_LAYER_MODE`. The parent owns no device and asserts only on the exit
code.

```zig
// test/support/LayerMatrix.zig
pub const LayerMode = enum { none, validation, validation_sync };

pub fn runLayerMatrix(self: *Self, run_child: *const fn (LayerMode) !void) !void;
```

`std.process.Child.env_map` replaces the child's whole environment, so the
parent builds it from `std.process.getEnvMap` and then applies the mode: it sets
the mode's keys and omits the keys the mode must not have. That keeps
`VK_DRIVER_FILES` from §5.1 and `VK_LAYER_PATH` from §4.1.

The child runs with `stdio = .{ .stdout = .inherit, .stderr = .pipe }`.
Nothing in the parent mutates the shell environment. `devenv.nix:116-119`
requires exactly this: the zero-layer path sets its variable per process rather
than in the shared shell.

The gate therefore covers all three modes in one `zig build test` run, without a
shell wrapper and without a second task.

### 4.4 How a suite asserts the layer reported nothing

Two mechanisms. The first is primary because it needs nothing from the library.

**Primary: read the child's stderr.** The parent scans the captured byte stream
and fails when a line begins with `ERROR: [` or contains `Validation Error`. The
filter must not match `WARNING`, because the loader writes benign lines of its
own, measured above:

```
WARNING: [Loader Message] Code 0 : env var 'VK_INSTANCE_LAYERS' defined and adding layers "VK_LAYER_KHRONOS_validation"
```

**Secondary: a debug-utils messenger.** `VK_EXT_debug_utils` is advertised by
both drivers, measured in the two lists in §1.1. The test creates a
`VkDebugUtilsMessengerEXT` through `vkCreateDebugUtilsMessengerEXT`, collects
`VkDebugUtilsMessengerCallbackDataEXT` into a slice, and asserts the count is
zero. This mechanism survives a change to `VK_LAYER_LOG_PATH`, and it reports a
severity and a message id rather than a line of text.

The messenger needs the raw `VkInstance`. The native-handle accessor that
`docs/30-port-design.md` owns provides it. The test uses that accessor and the
library never reads it itself.

### 4.5 The rules

1. **The library must run correctly with zero layers.** A change that works
   only with the layer enabled is broken (`AGENTS.md:112-113`).
2. **The layer is never a runtime dependency.** `build.zig.zon` holds no entry
   for it, `.paths` names no layer file, and `platform` never opens
   `VK_LAYER_KHRONOS_validation` through `vkEnumerateInstanceLayerProperties`.
3. **A mode that reports a validation error fails the suite.** The layer does
   not decide pass or fail. `abort_on_error` stays off for the reason
   `devenv.nix:133-135` gives: a layer that aborts takes the whole shard with it.
4. **Every layer result names its mode.** A failure reported as "validation
   failed" without the mode is not evidence.

### 4.6 The modern spelling, and why the old one is absent

`devenv.nix:130` sets `VK_LAYER_VALIDATE_SYNC=1`, not `VK_LAYER_ENABLES`.
`devenv.nix:122-129` records why, and the reason is measured: the loader prints
this when both spellings are present.

```
WARNING: [Validation] Code 0 : vkCreateInstance(): Application is using deprecated "enables" (VK_LAYER_ENABLES) layer settings.
Deprecated settings and new settings cannot be mixed, and deprecated ones take precedence. Consider only using the new settings:
  Deprecated: VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT | New: "validate_sync" (VK_LAYER_VALIDATE_SYNC=1)
```

A child process inherits the shell's `VK_LAYER_VALIDATE_SYNC` and never reads it
if it also carries `VK_LAYER_ENABLES`, because the deprecated setting wins. So
the third mode in §4.2 has nothing to remove, and the shell needs no change.

---

## 5. The driver matrix

### 5.1 Inside devenv: lavapipe

Grade A. One device, and it is a CPU.

```
$ env | grep '^VK_DRIVER_FILES='
VK_DRIVER_FILES=/nix/store/0f4ri4jl678q74i5z0h9f4pg2sj59slp-mesa-26.2.2/share/vulkan/icd.d/lvp_icd.x86_64.json
$ vulkaninfo --summary 2>/dev/null | sed -n '/^Devices:/,$p'
GPU0:
	apiVersion         = 1.4.354
	deviceType         = PHYSICAL_DEVICE_TYPE_CPU
	deviceName         = llvmpipe (LLVM 21.1.8, 256 bits)
	driverName         = llvmpipe
	conformanceVersion = 1.3.1.1
```

The list holds one entry, `GPU0`.

`devenv.nix:155-173` explains why. The devenv container's `/usr` is not the
host's `/usr`, so `/usr/share/vulkan/icd.d` does not exist inside it and the
NVIDIA ICD is unreachable. The shell sets `VK_DRIVER_FILES` to the single
lavapipe ICD.

### 5.2 Outside devenv: four NVIDIA RTX A6000

Grade A. Four discrete devices.

```
$ vulkaninfo --summary 2>/dev/null | grep -E '^(GPU|	(apiVersion|deviceType|deviceName|driverName))'
GPU0:
	apiVersion         = 1.4.351
	deviceType         = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
	deviceName         = NVIDIA RTX A6000
	driverName         = NVIDIA
```

`GPU1`, `GPU2` and `GPU3` repeat those four fields with the same values. The
full summary also reports `driverVersion = 615.71.9.0`, `vendorID = 0x10de`,
`deviceID = 0x2230`, `driverID = DRIVER_ID_NVIDIA_PROPRIETARY`, and
`conformanceVersion = 1.4.3.3`. The loader reads
`/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json`, whose `library_path` is
`/usr/lib64/libGLX_nvidia.so.0`.

`DUSK_VK_DRIVER_FILES` overrides the list. `devenv.nix:175-196` builds
`VK_DRIVER_FILES` from it when it is non-empty, and otherwise from the single
lavapipe path. Outside devenv, pointing `VK_DRIVER_FILES` at `/nonexistent.json`
shows what a driver failure looks like, and it is what a device enumeration must
not be confused with:

```
ERROR: [Loader Message] Code 0 : loader_get_json: Failed to open JSON file /nonexistent.json
ERROR: [Loader Message] Code 0 : vkCreateInstance: Found no drivers!
Cannot create Vulkan instance.
This problem is often caused by a faulty installation of the Vulkan driver or attempting to use a GPU that does not support Vulkan.
ERROR at .../Vulkan-Tools-1.4.304/vulkaninfo/./vulkaninfo.h:456:vkCreateInstance failed with ERROR_INCOMPATIBLE_DRIVER
```

### 5.3 Zero devices must fail the run

A green run that enumerated nothing has proved nothing. Grade A for the
failure, grade C for the rule.

```zig
test "device enumeration is not empty" {
    const devices = try engine.enumeratePhysicalDevices(instance);
    try std.testing.expect(devices.len > 0);
}
```

The engine returns `error.NoPhysicalDevice` rather than an empty slice, so no
caller can mistake it for a healthy device with nothing to do. The staging and
readback helpers in §3.1 propagate that error rather than returning an empty
result.

### 5.4 What each configuration proves

| | lavapipe inside devenv | NVIDIA outside devenv |
| --- | --- | --- |
| reachable from the gate | yes | no |
| layer active | yes | no, `VK_LAYER_PATH` names a store path absent on this host (§4.1) |
| reproducible on any machine | yes | no |
| real device-local memory | no | yes |
| vendor queue families and limits | no | yes |
| vendor driver defects | no | yes |
| concurrency, because a real driver is not serial | no | yes |

lavapipe proves that the port issues a call sequence the specification permits,
and it proves it reproducibly. The NVIDIA run proves that a vendor driver
accepts the same sequence, and it is the only place a real memory heap, a real
queue family set, and a real driver bug appear. Neither substitutes for the
other: a suite that runs only on lavapipe cannot find a driver bug, and a suite
that runs only on NVIDIA cannot run on a machine without one.

The four identical A6000 devices are the reason per-adapter parameterisation
(§9.2) has an observable axis. Four rows with equal properties today mean that a
divergence tomorrow comes from the device or the driver, not from the test.

---

## 6. Shader fixtures

### 6.1 The layout

```
test/
  fixtures/
    triangle.vert.wgsl           committed
    triangle.vert.spv            committed, generated
    triangle.frag.wgsl           committed
    triangle.frag.spv            committed, generated
    occlusion.vert.wgsl          committed
    occlusion.vert.spv           committed, generated
    occlusion.frag.wgsl          committed
    occlusion.frag.spv           committed, generated
```

`docs/10-architecture.md:27` places `test/` at the top level. The WGSL file is
the source of truth for review, and the `.spv` file is the artefact the test
loads. One flat `fixtures/` directory holds the pairs: the stage already names
itself in the file name, so a subdirectory per shader would repeat it.

`test/spirv/corpus/`, its `MANIFEST.txt` and `test/support/` are not on disk.
§7.1 and §7.2 name what belongs there when it lands.

### 6.2 Regeneration

The regeneration step is a test-time external tool. It is never a build input
and never linked. `docs/20-dependencies.md` records the decision.

**Where the translator comes from.** `pkgs.tint` in nixpkgs is 0.1.7 and ships
no binary, so it cannot be used. The translator is built from the pinned Dawn
checkout, and `devenv.nix` task `dusk:build-tint` does it, caching the result
at `${cacheRoot}/tools/tint` and exporting it as `DUSK_TINT`.

It is built **inside devenv**, and that is not incidental. The devenv container
has no `/lib64` at all — only the nix glibc — so a binary linked against the
host toolchain dies there with `cannot execute: required file not found`. This
was observed, then fixed by building against the nix toolchain inside the
shell. The task disables the six back ends and both window systems, because
otherwise the configure step demands `xkbcommon`, which is absent.

The command line, measured against that binary:

```bash
"$DUSK_TINT" <fixture>.wgsl --format=spirv --ep <name> --ep <name> -o <out>.spv
```

Two flags were measured rather than assumed:

- the output-format flag is **`--format`**, not `--output-format`;
- a module with more than one entry point **refuses to emit** without an
  explicit `--ep` per entry point: `Emitting to a file but the module has
  multiple entry points. Please provide the '--ep <name>' option`.

Observed on `test/fixtures/triangle.vert.wgsl`, inside devenv:

```text
 0000000 03 02 23 07 00 03 01 00
SPIRV_VALID
```

`07230203` is the SPIR-V magic number and `00010300` is SPIR-V 1.3, little
endian. The `SPIRV_VALID` line is `spirv-val` from `spirv-tools`, run
separately.

**The build is byte-deterministic**, which the drift check in §6.3 depends on.
Regenerating one fixture twice and comparing:

```text
c72977d67e8e003d080c3bc0398a546635ff1257cb84ccc62b55797c1344081e  /tmp/tv1.spv
c72977d67e8e003d080c3bc0398a546635ff1257cb84ccc62b55797c1344081e  /tmp/tv2.spv
```

The translator is pinned twice: to the Dawn commit recorded in
`docs/02-dawn-design.md`, and to the host toolchain through the cache path.
Changing either changes the digests, which the drift check turns into a
visible failure rather than a silent one.

### 6.3 The drift check

The gate step regenerates every fixture into a scratch directory and compares it
to the committed `.spv`. The comparison is a byte comparison, not a semantic
one.

```bash
for wgsl in test/fixtures/*.wgsl; do
  spv="${wgsl%.wgsl}.spv"
  generated="${SCRATCH}/$(basename "${wgsl%.wgsl}").spv"
  # Entry points come from a sidecar next to the fixture; `--ep` is mandatory
  # for a multi-entry-point module and `--format`, not `--output-format`, names
  # the output language.
  dusk-wgsl-to-spv "$wgsl" "$generated" --ep vs_main --ep fs_main
  cmp -s "$generated" "$spv" || {
    printf 'fixture drift: %s\n' "$wgsl" >&2
    exit 1
  }
done
```

Two of the four fixtures drift today, so the step is red on this tree:

```text
SAME test/fixtures/occlusion.frag.spv
SAME test/fixtures/occlusion.vert.spv
DRIFT test/fixtures/triangle.frag.spv
DRIFT test/fixtures/triangle.vert.spv
```

The committed `.spv` files are not regenerated here. A regeneration belongs to
the change that altered the WGSL, and this document is not that change.

The step runs inside devenv, where `DUSK_TINT` is exported, so the binary
matches the glibc the tests run on. `dusk-wgsl-to-spv` is the `devenv.nix` task
of that name; it fails with a clear message when the translator has not been
built.

A drift failure names the WGSL file and does not modify the committed `.spv`. A
developer who changed a shader and forgot to regenerate sees the failure, runs
the regeneration, and commits both files in the same change.

`.paths` in `build.zig.zon:25-34` lists `build.zig`, `build.zig.zon`, `src`,
`docs`, `README.md`, `AGENTS.md`, `test` and `tools`. A consumer who installs
the package by hash therefore receives the fixtures and the generators.

### 6.4 The rule

The library never links the translator. `src/spirv` never parses WGSL, and
`build.zig.zon` holds no entry for `tint` (`AGENTS.md:116-123`). A shader that
reaches `vkCreateShaderModule` reached it as the caller's own words
(`docs/10-architecture.md:133-137`).

---

## 7. SPIR-V validation in tests

### 7.1 `spirv-val` proves a fixture before the engine sees it

`spirv-tools` is a test-time tool. Grade A:

```
$ devenv shell -- command -v spirv-val
/nix/store/v7n98xb3g3xfrlqg4kdpiq47k7jcjg2h-spirv-tools-1.4.357.0/bin/spirv-val
$ spirv-val --version
SPIRV-Tools v2026.3 unknown hash, 1980-01-01T00:00:00+00:00
Targets:
  SPIR-V 1.0 ... SPIR-V 1.6
  SPIR-V 1.0 (under Vulkan 1.0 semantics)
  ...
  SPIR-V 1.6 (under Vulkan 1.4 semantics)
```

The gate step runs it on every fixture before the test binary loads it:

```bash
spirv-val --target-env vulkan1.3 test/fixtures/*.spv
```

`docs/20-dependencies.md:97-99` states the rule: `spirv-tools` is in
`devenv.nix`, absent from `build.zig.zon`, and not linked. `devenv.nix:50-51`
puts it in the shell.

The reason is diagnostic. A fixture that `spirv-val` rejects fails with the
tool's own message and the file name, instead of failing later as a
`vkCreateShaderModule` error or a validation error with no source location.

### 7.2 The Zig validator is tested separately

`spirv-val` proves the fixture. It does not prove `src/spirv.validate`. Those
are two different implementations of the same specification, and the second one
is ours.

The corpus in §6.1 tests the Zig validator directly. It has not landed, so the
tests below name the shape rather than the file list:

```zig
test "every valid corpus module passes the Zig validator" {
    for (corpus_paths("valid")) |path| {
        const words = try readSpv(path);
        try spirv.validate(words);
    }
}

test "every invalid corpus module is rejected with its recorded rule" {
    for (corpus_paths("invalid")) |path| {
        const words = try readSpv(path);
        try std.testing.expectError(
            error.InvalidModule,
            spirv.validate(words),
        );
        try expectRecordedRule(path, try lastRuleId());
    }
}
```

`MANIFEST.txt` records the expected outcome and the rule identity for every
corpus file, so a rejection for the wrong reason fails the test. A validator
that rejects everything passes the first test and fails the second.

Dawn does the same thing with the same library:
`src/dawn/native/SpirvValidation.cpp:37-79` builds a `spvtools::SpirvTools`,
sets a message consumer, calls `Validate`, and disassembles on failure. The
port replaces the library with Zig and keeps the corpus.

### 7.3 What this is not

`spirv-val` is not a build input. It never runs inside `zig build`. It runs in
the fixture step of the gate, and a fixture that it rejects fails the gate.

---

## 8. The house gate

### 8.1 The ten stages

Grade A. `zig-gate --help` prints the order:

```
sections (in order)
  1 fmt         zig fmt --check over the project file list
  2 build       zig build
  3 test        zig build test
  4 ast-check   zig ast-check over the project file list
  5 ziglint     ziglint over the project file list          (asserts)
  6 zlint       zlint -S over the project file list         (asserts)
  7 zbc         zbc escape analysis                         (advisory)
  8 zwanzig     zwanzig over the project file list         (asserts all findings)
  9 cross-test  cross-test matrix, narrowed by ./cross-test.profile.sh
 10 zig-cov     coverage, opt-in via --cov                  (advisory)
```

The block above is the tool's own help text, quoted as printed. Two of its
labels do not match what the stage does. Stage 6 is `zlint -S`, and `-S` is
stdin mode, not strict mode; the gate feeds it the file list on stdin and no
`--deny-warnings`, so a warning does not change `zlint`'s exit status and the
stage counts errors and warnings together from its summary line. Stage 8
asserts every class it prints: `zig-gate` counts the findings in each class,
prints the count with `(asserted)`, and fails the stage when the total is above
zero. `devenv.nix` sets no `ZWANZIG_ARGS`, so no rule is excluded and no class
is advisory. §8.5 records what the stage does with the one class it reports.

What each one proves:

| Stage | Proves | Does not prove |
| --- | --- | --- |
| 1 `fmt` | every project file parses and is formatted | that it compiles |
| 2 `build` | the published module compiles for the host in Debug | that any test passes |
| 3 `test` | the Debug and ReleaseSafe shards run and every registered test passes | anything about ReleaseFast or ReleaseSmall |
| 4 `ast-check` | every project file parses on its own, including a file the build graph does not reference | any semantics |
| 5 `ziglint` | the stage fails when `ziglint` reports one finding over the selected source | that the rules are the right ones |
| 6 `zlint -S` | the stage fails when `zlint` reports one error or one warning over the selected source | that the two sets are complete |
| 7 `zbc` | 0 errors over the 123 selected files, and 21 warnings that do not fail the stage | the absence of a use-after-free; the two `heap-leak` findings it once raised were not defects (§8.5.2) |
| 8 `zwanzig` | the stage fails on one finding in any class. It reports 9, all `store-violations-engine`, so it is red | that its rules cover the module |
| 9 `cross-test` | the Debug shard builds and runs in every matrix row | the Vulkan half, which is native-only (§10) |
| 10 `zig-cov` | a coverage figure, when `--cov` is passed | anything: it is advisory and off by default |

The lint stages read the project's hand-written source. `devenv.nix:95-101`
excludes `src/vulkan.zig` and `src/api/` from every source-selection stage:
`src/vulkan.zig` is `zig translate-c` output over the pinned header, and
`src/api/` comes from `tools/gen_api.zig`. Both carry a "do not edit" banner,
so a finding in either is a finding in its generator, and a hand fix is erased
by the next `zig build generate`. A finding in either file is therefore fixed
in `tools/gen_api.zig` or in the `translate-c` invocation in `build.zig`, never
in the generated file.

`devenv.nix:208-209` runs `zig-gate` as `gate:dusk`. `devenv.nix:206-207`
records that `zbc` errors fail even with `ZBC_STRICT=0`.

### 8.2 The two safety modes

`build.zig` runs the library tests in **Debug** and **ReleaseSafe**, and it
applies an address-space ceiling of 4 GiB to each native run through
`ulimit -v`. That ceiling is what turns an unbounded allocation loop into a
fast, visible failure instead of a machine-wide problem.

### 8.3 What a green gate does not prove

1. **A coverage percentage.** `zig-cov` is advisory and off unless `--cov` is
   passed. Nothing in the gate asserts a figure, and a coverage number is not a
   quality measure.
2. **Fuzzing.** No stage runs a fuzzer. `AGENTS.md:94-95` requires fuzzing at
   every decoder boundary, and until that exists the gate proves nothing about
   malformed SPIR-V, a truncated buffer, or an out-of-range descriptor.
3. **Sanitizers.** No stage runs an address or undefined-behaviour sanitizer.
4. **`ReleaseFast` and `ReleaseSmall`.** `zig build test` runs Debug and
   ReleaseSafe. An optimization-mode-dependent defect passes the gate.
5. **The absence of a leak.** Zig's test runner installs a leak-detecting
   allocator, and it reports a leak only for what was allocated through it.
   `docs/10-architecture.md:79-80,88-90` gives every WebGPU object a
   `std.heap.ArenaAllocator` that is reclaimed in one step when the device is
   destroyed, so an object leak is invisible to the checker by construction. A
   test must pass an explicit `std.testing.allocator` to anything it wants
   watched.

A green gate is evidence that the tree compiles, that the registered tests pass
in two safety modes on the host, that the analyser stages found nothing to fail
on, and that three foreign targets build and run the Debug shard. It is not
evidence of coverage, of robustness against malformed input, or of memory
correctness.

The gate is not green as the tree stands. Stage 8 reports 9
`store-violations-engine` findings and asserts all of them (§8.5.1), so a run
ends red there. Stage 7 reports 0 errors and passes. A red stage is a fact
about the gate, not about the code: §8.5 records the one class that is a
measured limit of the analyser rather than a defect in this tree, and it is
still asserted.

### 8.4 One run is a snapshot, not a gate

A single compile, test, or probe run samples one state of one tree. While other
workers are editing that tree, the sample may describe a file that no longer
exists in that form. A machine-level fact read off one such sample is a claim
about a moment, not about the machine. Two facts of that shape arose here:

- A missing Vulkan driver was reported from one probe run taken while a peer was
  mid-refactor. The host has four NVIDIA RTX A6000 devices at
  `apiVersion = 1.4.351`, loaded through `/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json`.
- A `MissingGlobalProc` was given two causes that were both wrong. The cause was
  a half-rewritten `src/engine/vulkan_device.zig`.

One environment trap makes the first shape easy to fall into, because it puts an
error on stderr in front of a working device. `VK_INSTANCE_LAYERS` is set in this
shell to `VK_LAYER_KHRONOS_validation`, and outside devenv `VK_LAYER_PATH` names a
store path absent on this host (§4.1), so `vulkaninfo` prints this before it
reports any device at all:

```
ERROR: [Loader Message] Code 0 : Layer "VK_LAYER_KHRONOS_validation" was not found but was requested by env var VK_INSTANCE_LAYERS!
```

That line is a statement about the layer, not about a driver. Clearing
`VK_INSTANCE_LAYERS` removes it and leaves the device list unchanged:

```
$ env -u VK_INSTANCE_LAYERS vulkaninfo --summary 2>/dev/null | grep -c '^GPU'
4
```

So a loader error is read with the device list beside it, never alone.

`store-violations-engine` is not a class the gate sets aside. §8.5 measures
what it reports and what the stage does with it.

The rest of this document describes a settled tree. Where it quotes a run, the
run is named; where the tree was moving, the sentence records the measurement
and not the conclusion drawn from it.

### 8.5 Two analyser findings that are limits, not defects

Two stages of the gate report findings that measurement, not argument, shows
to be limits of the analysers rather than defects in this tree. One is
asserted and leaves the stage red. The other is exempted per site and the
stage passes. Both are recorded here so the histogram is readable.

**A clean result is evidence only after the detector is shown to work.** The
ordering is the reusable part. A negative result from a leak detector or an
escape analyser is worthless until the same detector has been made to fail on
a deliberate violation, so that came first. Grade A, Zig 0.16.0:

```
$ zig test detector.zig        # a double free and a leak, one per run
1/2 ...a deliberate double free is caught...Segmentation fault at address 0x7f579f4c0000
std/mem/Allocator.zig:448:5: in free__anon_37932
    @memset(bytes, undefined);
detector.zig:11:31: in test.a deliberate double free is caught
error: the following test command terminated with signal ABRT
```

```
$ zig test leak_only.zig       # the leak half alone: the abort above kills the run
All 1 tests passed.
1 errors were logged.
1 tests leaked memory.
error: the following test command failed with exit code 1
```

So `std.testing.allocator` catches a double free on the second `free` and
fails a run that leaks, on this toolchain. The two halves cannot share a run,
because the first aborts the process before the second is reached.

#### 8.5.1 `store-violations-engine`: nine findings, all one class

`zwanzig` reports 9 findings over the 123 selected files, and every one is
`store-violations-engine`:

| File | Line | Finding |
| --- | --- | --- |
| `src/command/encoding_context.zig` | 413 | double free |
| `src/engine/vulkan_device.zig` | 1305 | resource leak |
| `src/platform/loader.zig` | 96 | double free |
| `src/spirv/reflect.zig` | 156 | double free |
| `tools/gen_api.zig` | 1063, 2720, 2749, 2769, 2879 | resource leak |

**The limit.** The rule does not model `errdefer` as an ownership transfer. A
correctly undone allocation, where the callee takes over the value and the
caller's `errdefer` must not run, reads as unreleased; a correctly moved
allocation reads as a double free. `AGENTS.md:82-85` makes `errdefer` mandatory
on every allocating function, so the code is written to a rule the analyser
does not implement.

**The load-bearing case is the five in `tools/gen_api.zig`.** They allocate
from `gpa`, which is `init.arena.allocator()` (`tools/gen_api.zig:3336`), and
`std.process.Init.arena` is documented at `lib/std/process.zig:33-35` as
"Permanent storage for the entire process, cleaned automatically on exit."
Satisfying the rule there would mean a per-allocation free of memory the arena
owns, which is a real defect. The other four are the same shape with a
caller-supplied allocator.

**The detector was checked on the two code paths the rule misreads.** Grade A,
every allocation-failure index from 0 up to the first success, with
`std.testing.allocator` as the back end:

```
$ zig test --dep dusk -Mroot=fail_n.zig -Mdusk=dusk_shim.zig
1/2 fail_n.test.fail-N over two commits and the merge in finish...OK
2/2 fail_n.test.fail-N over the iterator merge...OK
All 2 tests passed.

$ zig test --dep dusk -Mroot=loader_n.zig -Mdusk=dusk_shim.zig
1/1 loader_n.test.fail-N over the loader's joined candidate name...OK
All 1 tests passed.
```

Four of four passed: two through `src/command/encoding_context.zig`, whose
`freeBlocks` (`src/command/encoding_context.zig:412-415`) is the double-free
site, and one through `src/platform/loader.zig:96`, whose
`defer if (joined) |name| allocator.free(name);` is the other. Every
`error.OutOfMemory` path and every `errdefer` on those paths ran at least once
and released what it owned.

**The ruling.** The project owner owns `zwanzig` as a fork and has ruled the
`errdefer` correct as written, not to be rewritten to satisfy the rule. The
limit belongs to the tool. The stage is not exempted: `devenv.nix` sets no
`ZWANZIG_ARGS`, `zig-gate` asserts every class, and the 9 findings above make
stage 8 red.

#### 8.5.2 `heap-leak`: two findings, exempted per site

`zbc` reported 4 errors. Two were defects and were fixed. The remaining two are
`heap-leak` at `src/engine/query_set.zig` and `src/engine/texture.zig`, both
reading "destructor does not free `self`", and both wrong.

**The limit.** Both objects are arena objects. `Device.create` reaches
`ObjectArena.create` (`src/core/object.zig:354-361`), which takes the block with
`arena_allocator.create(T)`, and `ObjectArena.deinit`
(`src/core/object.zig:400-405`) reclaims every block with `reset(.free_all)`.
The rule classifies a factory named `create` as a heap factory and asks the
destructor for a call that cannot release anything.

**The proof is a leak-detector run, not an argument.** Sixty-four `QuerySet`s
and sixty-four `Texture`s through the real path, each torn down, then
`Device.deinit`, with the arena capacity asserted above zero beforehand so the
blocks were really held. `std.testing.allocator`, the leak detector, reports
nothing.

**The control.** `ArenaAllocator.free` rewinds only when the block ends at the
arena's newest byte, and returns otherwise
(`lib/std/heap/ArenaAllocator.zig:620-623`). Both constructors allocate after
the object block: `QuerySet.create` the availability vector, `Texture.create`
the view formats, the offset table, the initialized flags and the store. The
object block is therefore never that byte, and `allocator.destroy(self)` in
either destructor is a guaranteed no-op that reads as a release. The suggested
call is not merely redundant: the same `free` rewinds `end_index` by
`memory.len` when the block does end at the newest byte
(`lib/std/heap/ArenaAllocator.zig:625-635`), so whether it releases anything
depends on what the arena handed out afterwards. That is a live-block hazard,
not a redundant call.

**The rule's own escape is unavailable.** It is satisfied by renaming the
destructor, and `ObjectArena.assertHeader` requires the method be named
`destroy`: `@hasDecl(T, "destroy")` is a compile error otherwise
(`src/core/object.zig:286-288`). Renaming `Device.create` would clear the
finding and was refused, because renaming a public method so a pattern
detector stops matching costs the house naming convention and buys nothing.

**The exemption taken, and why that one.** `zbc --list-invariants` prints
`heap_leak`, and `--disable=heap_leak` does silence the rule, so the finding
can be exempted by id. It was not used: `--disable` is all-or-nothing for the
whole run, so it would also silence the rule for every genuine heap object in
the 123 files, which is worse than the finding. The exemption in the tree is
per site, one line above each declaration:

```
    // zbc-disable-next-line: heap-leak
    pub fn destroy(self: *QuerySet, reason: object.DestroyReason) void {
```

Measured: it takes the two findings to zero and changes nothing else, and
`src/platform/loader.zig` still reports its own unrelated warning. The
directive must be the line immediately above the declaration; with an evidence
block between them it applies to a comment and the finding returns, which was
observed and corrected. The evidence lives in the same comment block, where a
reader reaches it. Stage 7 now reports 0 errors and 21 warnings, and the
warnings do not fail it.

**What is not claimed.** Neither ruling claims the rules are correct
elsewhere, and neither is a precedent for exempting a class. A finding carries
its own evidence or it is answered with a fix.

---

## 9. The test taxonomy

`docs/02-dawn-design.md:372-375` names three cross-cutting mechanisms in Dawn.
This is the whole of the upstream test infrastructure that a port must
re-create. Each is decided here.

### 9.1 The deferred expectation engine

**Upstream.** `DawnTest.h:873-885` holds a `DeferredExpectation` list. A
`ReadbackSlot` at `DawnTest.h:849-851` names the buffer each expectation reads.
`TearDown` resolves everything: `DawnTest.cpp:1774-1775` calls
`ResolveDeferredExpectationsNow`, which at `DawnTest.cpp:2480-2494` maps every
slot synchronously, checks the replayed buffers, resolves the expectations, and
clears the lists. `ResolveExpectations` at `DawnTest.cpp:2329-2337` walks the
list once the data is mapped.

**Decision: keep it, in the same shape.**

- Priority: a WebGPU submission is asynchronous by contract, so an assertion
  written right after a submit has no data to read. Resolving at teardown is
  what makes `expectPixel` a one-line call at the point of interest.
- Constraint: the port has one device mutex and one serial timeline
  (`docs/10-architecture.md:102-103`), exactly the shape that makes a deferred
  list coherent.
- Cost imposed on consumers: a failing assertion reports at `TearDown`, not at
  the line that made it. The message must therefore carry the source location,
  which is what Dawn's `DeferredExpectation::file` and `::line` fields do at
  `DawnTest.h:874-875`.
- Counterchoice: resolve each expectation immediately, which removes the list
  and reports at the right line. It genuinely wins when the engine is
  synchronous, or when a test asserts once and then finishes. It loses here,
  because a render test that asserts four pixels then reads them back would
  wait four times instead of once.
- Grade: B for the upstream shape, C for the port's version.

Zig spelling, in `test/support/Expectation.zig`:

```zig
pub const Expectation = struct {
    file: []const u8,
    line: u32,
    slot_index: u32,
    check: *const CheckFn,
    context: *anyopaque,
};

pub fn expectPixel(self: *Self, options: PixelAssertOptions) !void;
```

`CheckFn` is a function pointer with the context last, matching the house
callback rule in `AGENTS.md:56-57`.

### 9.2 Per-adapter parameterisation

**Upstream.** `AdapterTestConfig.h:78-86` defines `AdapterTestParam`, which
carries the adapter properties, the forced workarounds, and the compatibility
flag. `DawnTest.h:938-939` makes it the default parameter type of
`DawnTestWithParams`.

**Decision: keep it, reduced to the axes that can differ here.**

- Priority: a test that runs once proves nothing about the other configuration.
  Inside devenv there is one device, so the axes that matter are the ones a
  driver can vary.
- Constraint: the port has one back end, so Dawn's seven back-end axes
  (`AdapterTestConfig.h:90-112`) collapse to one value.
- Cost imposed on consumers: a test runs N times. On this host N is 1 inside
  devenv and 4 outside it. A suite that runs the shader tests four times on a
  CPU rasteriser becomes slow, so the matrix is narrowed by a test's own
  declaration of which axes it is sensitive to.
- Counterchoice: run once against adapter 0. It genuinely wins when the driver
  is known uniform, which is the case for the four identical A6000 devices and
  is the reason a naive port would choose it. It loses on the day the four
  devices differ, because no test would notice.
- Grade: B for the upstream shape, A for the device counts in §5.

The axes are `driver_name`, `device_type`, `compatibility_mode` and `selected`.
`compatibility_mode` is a runtime derivation and never a build flag
(`docs/10-architecture.md:147-150`).

### 9.3 Skip predicates

**Upstream.** `DawnTest.h:900-907` defines `DAWN_SKIP_TEST_IF_BASE`.
`DAWN_TEST_UNSUPPORTED_IF` at `DawnTest.h:911` skips a test that needs a
feature or a toggle. `DAWN_SUPPRESS_TEST_IF` at `DawnTest.h:916` skips a test
that fails on a named hardware and backend combination, and it is cancelled by
`--run-suppressed-tests` (`DawnTest.cpp:623-624`).

**Decision: keep both, and make a skip visible.**

- Priority: a feature that the device does not expose must not fail the suite,
  and the reason must survive into the output.
- Constraint: a skip is silent coverage loss. It is the easiest way for a green
  suite to mean nothing.
- Cost imposed on consumers: every skip prints its predicate and its reason,
  the suite reports the skip count, and a suite whose skip ratio rises above a
  declared bound fails.
- Counterchoice: delete the predicates and let the device-dependent tests fail
  on the device that cannot run them. It genuinely wins when the whole matrix is
  known and small, because there is then no silent hole to guard. It loses as
  soon as a second driver appears, which §5.2 already provides.
- Grade: B for the upstream shape, C for the port's rules.

Zig spelling:

```zig
pub fn skipIfUnsupported(condition: bool, options: SkipOptions) error{Skipped}!void;
pub fn skipIfSuppressed(condition: bool, options: SkipOptions) error{Skipped}!void;
```

§2.5 gives the first real use. `VK_FORMAT_R4G4B4A4_UNORM` is not a mandatory
format, so a test that uses it skips itself when the format-property query
reports the bit missing.

---

## 10. Cross-test

### 10.1 The matrix

`cross-test.profile.sh:46-50` sets it, and `cross-test.profile.sh:54` sets
`CROSS_REQUIRE_RUNNERS=1`.

| Row | What it is |
| --- | --- |
| `x86_64-linux` | the host target, so a gap in the matrix can never hide a native break |
| `aarch64-linux` | foreign 64-bit little-endian, the phone and embedded ABI |
| `powerpc64-linux` | foreign 64-bit **big-endian** |

`cross-test.profile.sh:22-24` gives the reason for `CROSS_REQUIRE_RUNNERS=1`:
a missing runner must fail rather than silently degrade execution coverage into
compile-only coverage. A broken qemu install must not look green.

`build.zig` wires the step as `cross-test`, which runs the Debug shard through
the build system's own runner selection, native for the host and `qemu_user` for
a foreign target. `cross_run.has_side_effects = true`, because a cached run
executes no test and would otherwise report coverage it never produced.

### 10.2 What a foreign row proves

`cross-test.profile.sh:35-41` states the split, and this document repeats it:

- A foreign row **can** prove that `src/core`, `src/math`, the wire encoding
  and the C ABI struct packing execute correctly under a foreign ABI. The
  `powerpc64-linux` row is the only big-endian execution evidence in the
  project, and those are byte layouts, so a byte order or an alignment bug is
  only visible there.
- A foreign row **cannot** prove anything about Vulkan. No foreign architecture
  on this host has a Vulkan loader or an ICD. `src/vulkan/**` and every
  milestone that opens a `VkInstance` stay native-only and are proven by a
  native run against the host loader.

The consequence for this document: the readback pipeline in §2, the layer matrix
in §4, and the driver matrix in §5 are native-only evidence. The cross-test
shard does not open an instance and must not be given code that would make it
try.

### 10.3 Budgets

`cross-test.profile.sh:59-62` sets `CROSS_JOBS=2`, `CROSS_BUILD_JOBS=2`,
`CROSS_BUILD_TIMEOUT=3600` and `CROSS_TIMEOUT=600`. The build budget is
generous because a foreign row builds every Zig dependency from source under
`qemu_user`.

`cross-test --help` names the evidence layout: `PREFIX/runs/RUN_ID/{build,run}-TARGET.log`
and `summary.json`, with `PREFIX/cross-test-summary.json` as the current-run
summary. `devenv.nix:92-93` points `GATE_CROSS_OUTPUT` at local disk, because the
checkout is on NFS.

---

## 11. What counts as evidence

Three claims, and each is weaker than it sounds.

### 11.1 A build claim

> The code compiles for target T in mode M.

Established by gate stage 2, or by stage 9 for a foreign target. It establishes
that the compiler accepted the source and that the link resolved.

It does **not** establish that the code runs, that it produces the right answer,
or that it terminates. A build claim about the Vulkan half inside devenv is a
link claim only, because the container's loader reaches lavapipe and nothing
else (§5.1). Outside devenv the same loader reaches four NVIDIA devices, and a
link proves nothing about what they do with the call.

### 11.2 A test claim

> A named test passed, in a named layer mode, on a named driver, in a named
> optimisation mode, on a named target.

Established by gate stage 3, read together with the mode it ran in. The mode
must be in the claim, because §4.2 gives three modes and they prove different
things.

It does **not** establish that the test would fail without the change it is
testing. Nothing in this project runs a mutation, so a test that asserts
nothing passes exactly as loudly as a test that catches a bug.

### 11.3 A runtime observation

> This binary, in this environment, produced this output.

Established by a quoted command. The driver lists in §1.1, §5.1 and §5.2 are
runtime observations.

It does **not** establish generality. Four identical RTX A6000 devices say
nothing about a driver from another vendor, and one lavapipe run says nothing
about a machine whose Mesa is a different version.

### 11.4 The rule

Every claim in a commit message, a review, or a release note names its
configuration: layer mode, driver, target, optimisation mode. A claim without
one is an observation, and it is labelled as one.

---

## 12. Citations

A citation is checked in two places, and the two checks catch different
failures. Neither substitutes for the other.

### 12.1 A bare continuation inherits its file

**Rule: a bare continuation citation inherits its file from the nearest
preceding named citation in the same comment block, and a block whose named
file changes invalidates every bare line after it.**

Grade C, decided here. It is a rule rather than a caution because the failure
is silent: a bare `:210-259` carries no file name, so nothing fails to
compile and no reader can see which file it resolved to. The file has to be
re-derived before the line can be read.

Two obligations follow.

- Re-resolve per comment block, never once per file.
- Name the file when the claim outlives the block that named it.

Two measured instances, both from the audit in §12.4.

1. `src/pipeline/bind_group_descriptor_set.zig:130` carried a bare `:62` that
   resolved against the `BindGroupLayoutVk.cpp:56` named a line earlier in the
   same comment and landed on a texture-index comment at
   `src/dawn/native/vulkan/BindGroupLayoutVk.cpp:62`. The
   `DAWN_CHECK(count > 0)` it claims is at
   `src/dawn/native/vulkan/DescriptorSetAllocator.cpp:62`.
2. `src/engine/vulkan_device.zig:690` carried `:389` against `BackendVk.h`,
   which holds 128 lines. The loader gate it claims is
   `src/dawn/native/vulkan/VulkanInfo.cpp:86-94`.

Neither was visible before re-resolution. Grade B, read at the pin.

### 12.2 A full citation is checked on the line

**Rule: read the cited line, and where the row names a symbol, require that
symbol to be on it.**

Grade C, decided here. A line count is not the check. It catches a citation
that points past the end of its file and catches nothing else. The
`docs/40-plan.md` audit found both shapes. `DescriptorSetAllocator.h:154`
against a 117-line file and `Device.h:1755` against a 771-line file were out of
range. `BindGroupLayoutInternal.cpp:214`, corrected to `:917`, and
`BindingInfo.h:174`, corrected to `:267`, were both in range and both held
something else, and a length check passes them unchanged. Grade B for the four
file lengths, read at the pin.

A citation that points into a real file looks checked. That is the check a
reader skips.

### 12.3 What neither check settles

Rows whose symbol cell is prose rather than an identifier, the `the X check`
rows, cannot be settled by matching a symbol on a line. They are settled by
reading the surrounding statement rather than the cited line alone. That is
slower, and it is the honest reason a full audit costs what it does. A
surviving miss is most likely to hide in these rows.

A primary cite names its file. A bare continuation does not, which is why
§12.1 and §12.2 are separate rules and not one.

The rates that carry both mechanisms, counted by the `docs/40-plan.md` audit:
57 of 2,492 primary cites needed correcting, and 24 of 41 bare records in one
batch resolved to the wrong file. Grade A.

### 12.4 The `src/` and `test/` audit result

Grade A. One pass over `src/` and `test/` re-resolved every citation against
the pinned tree and read it.

| Records | Count |
| --- | --- |
| Total | 4,186 |
| Corrected | 1,278 |
| Read at the pin, already right | 2,908 |
| Unverifiable | 34 |

The 34 unverifiable are accounted and none of them blocks. 22 are
`vk_mem_alloc.h` cites in `src/memory/vma.zig` against a VMA header absent
from both the pinned Dawn tree and this host. 11 are Vulkan and C header cites
in generated or boundary files. 1 is in `src/vulkan.zig`, verified correct
against Zig 0.16.0 std and left alone.

The correction count does not read without its split. 1,499 of the 4,186
records are bare continuations, 1,204 of the form `:210-259` and 295 bare
`:NNN` with no file in reach, so more than a third inherit their file from the
block around them. What the audit mostly found was inherited-file risk caught
by re-resolution, not wrong citation text. Read alone, "1,278 corrected"
overstates how much individual text was wrong; the bulk is inherited-file
risk. §12.1 is the rule this tree needs, at 1,499 of 4,186 records.

`src/vulkan.zig` and everything under `src/api/` were never edited; both are
generated (`docs/10-architecture.md:13`, `:16`, `:24`). `src/api/` carries
`dawn.json:NNN` records its own generator emits, and `src/vulkan.zig` carries
only transpiler-warning paths. No claim in this project is authored in a
generated file, so every claim lives in hand-written source or hand-written
docs.

---

## Not claimed here

This document does not claim any of the following.

1. **Coverage.** No figure is claimed, and no stage of the gate asserts one.
2. **Fuzzing.** No decoder boundary is fuzzed. A malformed SPIR-V module, a
   truncated descriptor, or an out-of-range limit is not covered by anything
   described here.
3. **Sanitizers.** No address or undefined-behaviour sanitizer runs.
4. **`ReleaseFast` and `ReleaseSmall`.** `zig build test` runs Debug and
   ReleaseSafe. An optimization-mode defect passes the gate.
5. **The absence of a leak.** The default test allocator does not see an
   allocation made through a device arena.
6. **A swapchain, a surface, or a present.** No test on this host creates one,
   so the swapchain path is untested by construction. See §1.2.
7. **Vulkan on a foreign architecture.** No foreign row has a loader or an ICD.
   See §10.2.
8. **The NVIDIA driver from inside devenv.** It is unreachable there
   (§5.1), so a green gate never exercises it.
9. **A performance figure.** Nothing here was measured for speed, and no
   tolerance was chosen by timing.
10. **WebGPU conformance.** Nothing here runs `webgpu-cts`.
    `docs/02-dawn-design.md:463-464` records that the conformance list lives in
    a separate checkout.
11. **`tint`'s exact interface.** It is not installed, so §6.2 names the shape
    of the step and not its flags.
12. **The `linearTilingFeatures` bits of the two optional formats.** See §2.5.
13. **A leak or a double free found by `store-violations-engine`.** The rule
    does not model `errdefer`, so its 9 findings are not evidence of a defect
    here. The stage still fails on them. See §8.5.1.
14. **A leak found by `zbc`'s `heap-leak`.** Two arena destructors were
    exempted per site after a leak-detector run reported none. See §8.5.2.
15. **Any machine-level fact from a run taken while the tree was moving.** A
    single run is a snapshot. See §8.4.

16. **A count of the citations in `docs/`.** The §12 figures cover `src/` and
    `test/` only.

## Open items

Each item is `UNKNOWN:` with the action that would settle it.

1. `VK_EXT_headless_surface` behaviour on lavapipe without `VK_KHR_display`.
   Settled by a small program that calls `vkCreateHeadlessSurfaceEXT`.
2. ~~The exact `tint` command line and whether it is byte-deterministic.~~ Both
   settled in §6.2: `--format=spirv` with an explicit `--ep` per entry point,
   and the output is byte-deterministic across runs.
3. `VK_FORMAT_R16G16B16A16_SFLOAT` and `VK_FORMAT_R4G4B4A4_UNORM`
   `linearTilingFeatures` on lavapipe. Settled by the format-property query the
   test performs.
4. ~~The `snake_case` spelling `zig translate-c` gives the `VkBufferImageCopy`
   fields.~~ It gives none: `src/vulkan.zig:4531-4538` keeps the C spelling, so
   the field is `bufferOffset`, not `buffer_offset`. §2.3 uses the C names.
5. ~~Whether `pkgs.tint` resolves in the pinned nixpkgs.~~ It resolves at
   0.1.7 and ships no binary, which is why the translator is built from the
   pinned Dawn checkout instead. Recorded in §6.2.
6. ~~`AGENTS.md` stated that `VK_EXT_headless_surface` is absent.~~ Corrected
   by the integration owner: it is present inside devenv on lavapipe and absent
   outside it on NVIDIA, while `VK_KHR_display` is the other way round. The
   offscreen-only decision rests on the absent display server, not the
   extension.
7. ~~`devenv.nix` did not provide a WGSL translator.~~ It now builds one with
   the `dusk:build-tint` task and exports it as `DUSK_TINT`. §6.2 is runnable.
8. ~~`.paths` in `build.zig.zon` did not list `test`.~~ It does, along with
   `tools` (`build.zig.zon:25-34`), and both directories exist. Recorded in §6.3.
