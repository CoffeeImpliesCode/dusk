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

fn readByte(byte_address: u32) -> u32 {
    return (source[byte_address >> 2u] >> ((byte_address & 3u) * 8u)) & 255u;
}

fn readHalf(byte_address: u32) -> u32 {
    let shift_bits = (byte_address & 3u) * 8u;
    let word_index = byte_address >> 2u;
    if (shift_bits <= 16u) {
        return (source[word_index] >> shift_bits) & 65535u;
    }
    return (source[word_index] >> 24u) | ((source[word_index + 1u] & 255u) << 8u);
}

fn readWord(byte_address: u32) -> u32 {
    let shift_bits = (byte_address & 3u) * 8u;
    let word_index = byte_address >> 2u;
    if (shift_bits == 0u) {
        return source[word_index];
    }
    return (source[word_index] >> shift_bits) |
        (source[word_index + 1u] << (32u - shift_bits));
}

fn pixelByteCount(kind: u32, channel_count: u32) -> u32 {
    if (kind <= 4u) {
        return channel_count;
    }
    if (kind <= 9u) {
        return channel_count * 2u;
    }
    if (kind <= 12u) {
        return channel_count * 4u;
    }
    return 4u;
}

fn sourceByteAddress(position: vec4f, pixel_byte_count: u32) -> u32 {
    let pixel = vec2u(position.xy) - parameters.words1.zw;
    return parameters.words0.x +
        parameters.words2.x * parameters.words0.z * parameters.words0.y +
        pixel.y * parameters.words0.y + pixel.x * pixel_byte_count;
}

fn signedByte(value: u32) -> i32 {
    return bitcast<i32>(value << 24u) >> 24u;
}

fn signedHalf(value: u32) -> i32 {
    return bitcast<i32>(value << 16u) >> 16u;
}

fn floatComponent(kind: u32, byte_address: u32) -> f32 {
    switch (kind) {
        case 1u: { return f32(readByte(byte_address)) / 255.0; }
        case 2u: { return max(f32(signedByte(readByte(byte_address))) / 127.0, -1.0); }
        case 3u: { return f32(readByte(byte_address)); }
        case 4u: { return f32(signedByte(readByte(byte_address))); }
        case 5u: { return f32(readHalf(byte_address)) / 65535.0; }
        case 6u: { return max(f32(signedHalf(readHalf(byte_address))) / 32767.0, -1.0); }
        case 7u: { return f32(readHalf(byte_address)); }
        case 8u: { return f32(signedHalf(readHalf(byte_address))); }
        case 9u: { return unpack2x16float(readHalf(byte_address)).x; }
        case 10u: { return f32(readWord(byte_address)); }
        case 11u: { return f32(bitcast<i32>(readWord(byte_address))); }
        case 12u: { return bitcast<f32>(readWord(byte_address)); }
        default: { return 0.0; }
    }
}

@fragment
fn main(@builtin(position) position: vec4f) -> @builtin(frag_depth) f32 {
    let kind = parameters.words2.w & 255u;
    let byte_address = sourceByteAddress(position, pixelByteCount(kind, 1u));
    return floatComponent(kind, byte_address);
}
