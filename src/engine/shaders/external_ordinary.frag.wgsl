// Copyright 2021 The Dawn & Tint Authors
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
// Derived from Dawn 32f77c02294310054a660c393feded4bcb3f203c:
// src/dawn/native/ExternalTexture.h:43-82 (transfer modes and metadata).
// src/dawn/native/ExternalTexture.cpp:165-365 (metadata and coordinate transforms).
// src/tint/lang/core/ir/transform/multiplanar_external_texture.cc:
//   362-403 (metadata), 408-666 (transfer), 681-723 (color processing),
//   883-981 (ordinary external texture sampling).
//
// SourceReady UNVERIFIED. No shader compilation or runtime result is claimed.
// The fullscreen vertex stage supplies normalized UV at location 0.
// Metadata contains the inverse mirror/rotation, crop, and half-texel bounds.
// The host admits only numPlanes 1/2 and source transfer modes 0/1/2.
// Destination transfer is always gamma, as in the pinned Tint body.

struct TransferFunctionParams {
    mode: u32,
    A: f32,
    B: f32,
    C: f32,
    D: f32,
    E: f32,
    F: f32,
    G: f32,
}

// Uniform size 288 bytes, alignment 16. The host zeros all layout padding.
struct ExternalTextureParams {
    numPlanes: u32,                       // 0
    doYuvToRgbConversionOnly: u32,         // 4, then padding at 8..15
    yuvToRgbConversionMatrix: mat3x4f,     // 16, column stride 16
    srcTransferFunction: TransferFunctionParams, // 64, size 32
    dstTransferFunction: TransferFunctionParams, // 96, size 32
    gamutConversionMatrix: mat3x3f,        // 128, column stride 16
    sampleTransform: mat3x2f,              // 176, column stride 8
    loadTransform: mat3x2f,                // 200, column stride 8
    samplePlane0RectMin: vec2f,            // 224
    samplePlane0RectMax: vec2f,            // 232
    samplePlane1RectMin: vec2f,            // 240
    samplePlane1RectMax: vec2f,            // 248
    apparentSize: vec2u,                   // 256, inclusive textureLoad bounds
    plane1CoordFactor: vec2f,              // 264, textureLoad plane size ratio
    ootfParam: vec4f,                      // 272
}

// Browser gamma packing is [G, A, B, C, D, E, F, zero], not external metadata.
struct BrowserGammaParams {
    G: f32,
    A: f32,
    B: f32,
    C: f32,
    D: f32,
    E: f32,
    F: f32,
    padding: f32,
}

// Uniform size 160 bytes, alignment 16. The host zeros all layout padding.
// Helper sampling supplies identity coordinates, gamma, gamut, and alpha modes.
struct BrowserCopyParams {
    origin: vec2f,                        // 0
    copy_size: vec2f,                     // 8
    apparent_extent: vec2f,               // 16
    flip_y: u32,                          // 24
    needs_color_space_conversion: u32,    // 28
    src_alpha_mode: u32,                  // 32: opaque 1, premult 2, unpremult 3
    dst_alpha_mode: u32,                  // 36: opaque 1, premult 2, unpremult 3
    decode_destination_srgb: u32,         // 40: host derives from actual attachment
    padding1: u32,                        // 44, zero
    src_gamma: BrowserGammaParams,        // 48, padding at 76
    dst_gamma: BrowserGammaParams,        // 80, padding at 108
    gamut: mat3x3f,                       // 112, column stride 16
}

@group(0) @binding(0) var plane0: texture_2d<f32>;
@group(0) @binding(1) var plane1: texture_2d<f32>;
@group(0) @binding(2) var planeSampler: sampler;
@group(0) @binding(3) var<uniform> metadata: ExternalTextureParams;
@group(0) @binding(4) var<uniform> browser: BrowserCopyParams;

fn applyGammaTransfer(v: vec3f, params: TransferFunctionParams) -> vec3f {
    let magnitude = abs(v);
    let polarity = sign(v);
    let linear = polarity * (params.C * magnitude + vec3f(params.F));
    let nonlinear = polarity * (
        pow(params.A * magnitude + vec3f(params.B), vec3f(params.G)) + vec3f(params.E)
    );
    return select(nonlinear, linear, magnitude < vec3f(params.D));
}

fn applyHlgChannel(v: f32, params: TransferFunctionParams) -> f32 {
    if (v <= params.D) {
        return (v * v) / params.E;
    }
    return (params.B + exp((v - params.C) / params.A)) / params.F;
}

fn applyHlgTransfer(v: vec3f, params: TransferFunctionParams) -> vec3f {
    return vec3f(
        applyHlgChannel(v.r, params),
        applyHlgChannel(v.g, params),
        applyHlgChannel(v.b, params)
    );
}

fn applyPqTransfer(v: vec3f, params: TransferFunctionParams) -> vec3f {
    let clamped = clamp(v, vec3f(0.0), vec3f(1.0));
    let powered = pow(clamped, vec3f(1.0 / params.B));
    let numerator = max(powered - vec3f(params.C), vec3f(0.0));
    let denominator = vec3f(params.D) - params.E * powered;
    return pow(numerator / denominator, vec3f(1.0 / params.A));
}

fn applySourceTransfer(v: vec3f, params: TransferFunctionParams) -> vec3f {
    if (params.mode == 0u) {
        return applyGammaTransfer(v, params);
    }
    if (params.mode == 1u) {
        return applyHlgTransfer(v, params);
    }
    return applyPqTransfer(v, params);
}

fn applyColorProcessing(rgb: vec3f) -> vec3f {
    if (metadata.doYuvToRgbConversionOnly != 0u) {
        return rgb;
    }
    var decoded = applySourceTransfer(rgb, metadata.srcTransferFunction);
    // Follow the body, not Tint's stale comment: OOTF precedes gamut conversion.
    if (metadata.ootfParam.w != 0.0) {
        let luminance = dot(metadata.ootfParam.rgb, decoded);
        let factor = sign(luminance) * pow(abs(luminance), metadata.ootfParam.w);
        decoded *= factor;
    }
    let converted = metadata.gamutConversionMatrix * decoded;
    return applyGammaTransfer(converted, metadata.dstTransferFunction);
}

fn applyBrowserGamma(v: vec3f, params: BrowserGammaParams) -> vec3f {
    return applyGammaTransfer(v, TransferFunctionParams(
        0u, params.A, params.B, params.C, params.D, params.E, params.F, params.G
    ));
}

fn decodeDestinationSrgbChannel(c: f32) -> f32 {
    if (c <= 0.04045) {
        return c / 12.92;
    }
    return pow((c + 0.055) / 1.055, 2.4);
}

fn applyBrowserColorProcessing(color: vec4f) -> vec4f {
    var rgb = color.rgb;
    var alpha = color.a;
    let conversion = browser.needs_color_space_conversion != 0u;
    if (browser.src_alpha_mode == 2u &&
        (conversion || browser.dst_alpha_mode == 3u)) {
        if (alpha != 0.0) {
            rgb /= alpha;
        }
    }
    if (conversion) {
        let decoded = applyBrowserGamma(rgb, browser.src_gamma);
        let converted = browser.gamut * decoded;
        rgb = applyBrowserGamma(converted, browser.dst_gamma);
    }
    if (browser.dst_alpha_mode == 2u &&
        (conversion || browser.src_alpha_mode == 3u)) {
        rgb *= alpha;
    }
    // Cancel the actual sRGB attachment's automatic encoding after premultiply.
    if (browser.decode_destination_srgb != 0u) {
        rgb = vec3f(
            decodeDestinationSrgbChannel(rgb.r),
            decodeDestinationSrgbChannel(rgb.g),
            decodeDestinationSrgbChannel(rgb.b)
        );
    }
    // Destination opaque alone does not discard source alpha.
    if (browser.src_alpha_mode == 1u) {
        alpha = 1.0;
    }
    return vec4f(rgb, alpha);
}

@fragment
fn external_ordinary(@location(0) uv: vec2f) -> @location(0) vec4f {
    var copyUv = uv;
    if (browser.flip_y != 0u) {
        copyUv.y = 1.0 - copyUv.y;
    }
    let apparentUv = (browser.origin + copyUv * browser.copy_size) /
        browser.apparent_extent;
    let transformed = metadata.sampleTransform * vec3f(apparentUv, 1.0);
    let plane0Coordinates = clamp(
        transformed, metadata.samplePlane0RectMin, metadata.samplePlane0RectMax
    );
    var rgb: vec3f;
    var alpha: f32;
    if (metadata.numPlanes == 1u) {
        let texel = textureSampleLevel(plane0, planeSampler, plane0Coordinates, 0.0);
        rgb = texel.rgb;
        alpha = texel.a;
    } else {
        let plane1Coordinates = clamp(
            transformed, metadata.samplePlane1RectMin, metadata.samplePlane1RectMax
        );
        let y = textureSampleLevel(plane0, planeSampler, plane0Coordinates, 0.0).r;
        let chroma = textureSampleLevel(plane1, planeSampler, plane1Coordinates, 0.0).rg;
        rgb = vec4f(y, chroma, 1.0) * metadata.yuvToRgbConversionMatrix;
        alpha = 1.0;
    }
    let externalColor = vec4f(applyColorProcessing(rgb), alpha);
    return applyBrowserColorProcessing(externalColor);
}
