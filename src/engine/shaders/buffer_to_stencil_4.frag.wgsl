// Copyright 2023 The Dawn & Tint Authors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Provenance: Dawn src/dawn/native/BlitBufferToDepthStencil.cpp @ 32f77c02294310054a660c393feded4bcb3f203c

struct Parameters {
    words0: vec4u,
    words1: vec4u,
    words2: vec4u,
    words3: vec4u,
}

@group(0) @binding(0) var<storage, read> source: array<u32>;
@group(0) @binding(1) var<uniform> parameters: Parameters;

const stencil_mask: u32 = 16u;

fn readByte(byte_address: u32) -> u32 {
    return (source[byte_address >> 2u] >> ((byte_address & 3u) * 8u)) & 255u;
}

fn sourceByteAddress(position: vec4f, pixel_byte_count: u32) -> u32 {
    let pixel = vec2u(position.xy) - parameters.words1.zw;
    return parameters.words0.x +
        parameters.words2.x * parameters.words0.z * parameters.words0.y +
        pixel.y * parameters.words0.y + pixel.x * pixel_byte_count;
}

@fragment
fn main(@builtin(position) position: vec4f) {
    let byte_address = sourceByteAddress(position, 1u);
    let stencil = readByte(byte_address);
    if ((stencil & stencil_mask) == 0u) {
        discard;
    }
}
