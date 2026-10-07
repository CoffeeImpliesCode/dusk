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
// Provenance: Dawn src/dawn/native/BlitDepthToDepth.cpp @ 32f77c02294310054a660c393feded4bcb3f203c

struct Params {
    source_origin_mip: vec4u,
    source_extent_sample: vec4u,
    destination_rectangle: vec4u,
    flags_layer: vec4u,
    affine: vec4u,
    padding: vec4u,
}

@group(0) @binding(0) var source_texture: texture_depth_multisampled_2d;
@group(0) @binding(1) var<uniform> params: Params;

fn localRatio(position: vec4f) -> vec2f {
    var ratio = (position.xy - vec2f(params.destination_rectangle.xy)) /
        vec2f(params.destination_rectangle.zw);
    if ((params.flags_layer.x & 1u) != 0u) {
        ratio.y = 1.0 - ratio.y;
    }
    return ratio;
}

fn sourceCoordinates(position: vec4f) -> vec2i {
    let relative = vec2u(floor(localRatio(position) *
        vec2f(params.source_extent_sample.xy)));
    return vec2i(params.source_origin_mip.xy + relative);
}

@fragment
fn main(@builtin(position) position: vec4f) -> @builtin(frag_depth) f32 {
    let coordinates = sourceCoordinates(position);
    return textureLoad(source_texture, coordinates, i32(params.source_extent_sample.z));
}
