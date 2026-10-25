# Third-party notices

The files listed below contain or derive from third-party material. The project-level MIT license does not replace these terms.

## Dawn and Tint

- **Component:** Dawn/Tint-derived port code, generated API bindings, shader sources, and associated SPIR-V outputs.
- **Paths:** `src/engine/external_texture.zig`; `src/command/allocator.zig`; `src/vk/dispatch.zig`; `src/api/*.zig`; `tools/native_ycbcr_spirv.zig`; the 97 Dawn-derived WGSL sources in `src/engine/shaders/*.wgsl`; their associated SPIR-V outputs in `src/engine/shaders/` recorded in `src/engine/shaders/native_kernels.provenance.json`.
- **License:** BSD-3-Clause.
- **Copyright holder:** The Dawn & Tint Authors.
- **Upstream:** [Dawn revision `32f77c02294310054a660c393feded4bcb3f203c`](https://dawn.googlesource.com/dawn/+/32f77c02294310054a660c393feded4bcb3f203c/); [license at that revision](https://dawn.googlesource.com/dawn/+/32f77c02294310054a660c393feded4bcb3f203c/LICENSE).

Copyright 2017-2026 The Dawn & Tint Authors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Vulkan-Headers

- **Component:** Generated Vulkan declarations.
- **Paths:** `src/vulkan.zig`.
- **License:** Apache-2.0 OR MIT; this project uses the MIT option for this file.
- **Copyright holder:** The Khronos Group Inc. (Copyright 2015-2026).
- **Upstream:** [Vulkan-Headers v1.4.365 `vulkan_core.h`](https://raw.githubusercontent.com/KhronosGroup/Vulkan-Headers/v1.4.365/include/vulkan/vulkan_core.h); [license information](https://github.com/KhronosGroup/Vulkan-Headers/blob/v1.4.365/LICENSE.md).

MIT License

Copyright 2015-2026 The Khronos Group Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
