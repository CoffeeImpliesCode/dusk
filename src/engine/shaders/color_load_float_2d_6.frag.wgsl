// Copyright 2020 The Dawn & Tint Authors
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
// Provenance: Dawn src/dawn/native/CopyTextureForBrowserHelper.cpp @ 32f77c02294310054a660c393feded4bcb3f203c

struct Params {
    source_origin_mip: vec4u,
    source_extent_sample: vec4u,
    destination_rectangle: vec4u,
    flags_layer: vec4u,
    affine: vec4u,
    padding: vec4u,
    source_transfer_0: vec4f,
    source_transfer_1: vec4f,
    destination_transfer_0: vec4f,
    destination_transfer_1: vec4f,
    conversion_matrix_0: vec4f,
    conversion_matrix_1: vec4f,
    conversion_matrix_2: vec4f,
    reserved: vec4u,
}

@group(0) @binding(0) var source_texture: texture_2d<f32>;
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

fn decodeSrgbChannel(value: f32) -> f32 {
    if (value <= 0.04045) {
        return value / 12.92;
    }
    return pow((value + 0.055) / 1.055, 2.4);
}

fn encodeSrgbChannel(value: f32) -> f32 {
    if (value <= 0.0031308) {
        return value * 12.92;
    }
    return 1.055 * pow(value, 1.0 / 2.4) - 0.055;
}

fn transferChannel(value: f32, coefficients_0: vec4f, coefficients_1: vec4f) -> f32 {
    let magnitude = abs(value);
    if (magnitude < coefficients_1.x) {
        return sign(value) * (coefficients_0.w * magnitude + coefficients_1.z);
    }
    return sign(value) * (pow(coefficients_0.y * magnitude + coefficients_0.z,
        coefficients_0.x) + coefficients_1.y);
}

fn transferColor(color: vec3f, coefficients_0: vec4f, coefficients_1: vec4f) -> vec3f {
    return vec3f(transferChannel(color.r, coefficients_0, coefficients_1),
        transferChannel(color.g, coefficients_0, coefficients_1),
        transferChannel(color.b, coefficients_0, coefficients_1));
}

fn transformColor(input_color: vec4f) -> vec4f {
    let flags = params.flags_layer.x;
    var color = input_color;
    if ((flags & 2u) != 0u) {
        color = color.bgra;
    }
    if (((flags & 8u) != 0u) && (color.a != 0.0)) {
        color = vec4f(color.rgb / color.a, color.a);
    }
    if ((flags & 16u) != 0u) {
        color = vec4f(decodeSrgbChannel(color.r), decodeSrgbChannel(color.g),
            decodeSrgbChannel(color.b), color.a);
    }
    if ((flags & 128u) != 0u) {
        let source_linear = transferColor(color.rgb, params.source_transfer_0,
            params.source_transfer_1);
        let converted = params.conversion_matrix_0.xyz * source_linear.x +
            params.conversion_matrix_1.xyz * source_linear.y +
            params.conversion_matrix_2.xyz * source_linear.z;
        color = vec4f(transferColor(converted, params.destination_transfer_0,
            params.destination_transfer_1), color.a);
    }
    if ((flags & 32u) != 0u) {
        color = vec4f(encodeSrgbChannel(color.r), encodeSrgbChannel(color.g),
            encodeSrgbChannel(color.b), color.a);
    }
    if ((flags & 4u) != 0u) {
        color = vec4f(color.rgb * color.a, color.a);
    }
    if ((flags & 512u) != 0u) {
        color = vec4f(decodeSrgbChannel(color.r), decodeSrgbChannel(color.g),
            decodeSrgbChannel(color.b), color.a);
    }
    if ((flags & 256u) != 0u) {
        color.a = 1.0;
    }
    return color;
}

@fragment
fn main(@builtin(position) position: vec4f) -> @location(6) vec4f {
    let coordinates = sourceCoordinates(position);
    var color = textureLoad(source_texture, coordinates, i32(params.source_origin_mip.w));
    return transformColor(color);
}
