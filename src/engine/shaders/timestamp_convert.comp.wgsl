// Copyright 2026 The Dusk Authors
// Portions derived from Dawn QueryHelper.cpp.
// Copyright 2020 The Dawn & Tint Authors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// 3. Neither the name of the copyright holder nor the names of its contributors
//    may be used to endorse or promote products derived from this software
//    without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

struct Parameters {
    count: u32,
    tick_mask_low: u32,
    tick_mask_high: u32,
    mantissa: u32,
    binary_shift_bits: u32,
    quantization_mask_low: u32,
    reserved0: u32,
    reserved1: u32,
}

@group(0) @binding(0) var<storage, read> raw_ticks: array<vec2u>;
@group(0) @binding(1) var<storage, read_write> nanoseconds: array<vec2u>;
@group(0) @binding(2) var<uniform> parameters: Parameters;

// A row has four products. a*b + limb + carry fits exactly in u32.
fn multiply(ticks: vec2u, multiplier: u32) -> array<u32, 6> {
    let tick_limbs = array<u32, 4>(ticks.x & 65535u, ticks.x >> 16u,
                                  ticks.y & 65535u, ticks.y >> 16u);
    let multiplier_limbs = array<u32, 2>(multiplier & 65535u, multiplier >> 16u);
    var product: array<u32, 6>;
    for (var row = 0u; row < 2u; row += 1u) {
        var carry = 0u;
        for (var column = 0u; column < 4u; column += 1u) {
            let index = row + column;
            let value = tick_limbs[column] * multiplier_limbs[row] +
                        product[index] + carry;
            product[index] = value & 65535u;
            carry = value >> 16u;
        }
        product[row + 4u] = carry;
    }
    return product;
}

fn limb_at(product: array<u32, 6>, index: i32) -> u32 {
    if (index < 0 || index >= 6) {
        return 0u;
    }
    return product[u32(index)];
}

// Four low result limbs implement floor for right shifts and modulo for left shifts.
fn shifted_limb(product: array<u32, 6>, limb: i32, shift: i32) -> u32 {
    if (shift < 0) {
        let magnitude = u32(-shift);
        let source = limb + i32(magnitude / 16u);
        let remainder = magnitude % 16u;
        if (remainder == 0u) {
            return limb_at(product, source);
        }
        return ((limb_at(product, source) >> remainder) |
                (limb_at(product, source + 1) << (16u - remainder))) & 65535u;
    }
    let magnitude = u32(shift);
    let source = limb - i32(magnitude / 16u);
    let remainder = magnitude % 16u;
    if (remainder == 0u) {
        return limb_at(product, source);
    }
    return ((limb_at(product, source) << remainder) |
            (limb_at(product, source - 1) >> (16u - remainder))) & 65535u;
}

@compute @workgroup_size(8, 1, 1)
fn timestamp_convert(@builtin(global_invocation_id) invocation: vec3u) {
    let index = invocation.x;
    if (index >= parameters.count) {
        return;
    }
    let ticks = raw_ticks[index] & vec2u(parameters.tick_mask_low, parameters.tick_mask_high);
    let product = multiply(ticks, parameters.mantissa);
    let shift = bitcast<i32>(parameters.binary_shift_bits);
    let low = shifted_limb(product, 0, shift) | (shifted_limb(product, 1, shift) << 16u);
    let high = shifted_limb(product, 2, shift) | (shifted_limb(product, 3, shift) << 16u);
    nanoseconds[index] = vec2u(low & parameters.quantization_mask_low, high);
}
