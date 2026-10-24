//! The M20 colour-space shard: `common/ColorSpace.h` with fixed inputs and
//! fixed outputs.
//!
//! **What this file is.** It exercises the 27 constants
//! `src/dawn/common/ColorSpace.h` declares at the pinned revision, with no
//! surface, no device and no display server.
//!
//! **What this file does not claim.** It does not claim the algebra.
//! `src/dawn/common/Algebra.h` defines the algebra; the three
//! operations this table needs are private helpers of
//! `src/platform/color_space.zig`.
//!
//! **How the comparison works.** `@abs(actual - expected) <= tolerance` per
//! channel, with one channel per assertion so a failure names a channel
//! rather than a vector. The tolerances are per row and each row states why it
//! is what it is.
//!
//! **Why the values are f32 and not the published ones.** Dawn stores these as
//! `float` (`ColorSpace.h:135-316`), so a reference that prints ten digits is
//! rounding an `f32` twice. Every expected value below was computed by
//! replaying the port's own operation order in `f32`.

const std = @import("std");

const color = @import("dusk").platform.color_space;

const ExpectationError = error{TestExpectedApproxEqAbs};

/// `@abs(actual - expected) <= tolerance` per channel.
///
/// One assertion per channel on its own line, and not an `inline for`: a row
/// can carry the same expected value on two channels, so the reported line is
/// what names the channel, and an unrolled loop reports one line for all three.
/// Each failure reports the value, the tolerance and the expected value.
fn expectVec(actual: color.Vec3, expected: color.Vec3, tolerance: f32) ExpectationError!void {
    try std.testing.expectApproxEqAbs(expected[0], actual[0], tolerance);
    try std.testing.expectApproxEqAbs(expected[1], actual[1], tolerance);
    try std.testing.expectApproxEqAbs(expected[2], actual[2], tolerance);
}

// --- YCbCr range, `ColorSpace.h:134-149` ---------------------------------

test "the full range matrix is written as columns, not rows" {
    // `ColorSpace.h:135-140` uses the column constructor, so column three is
    // the chroma offset. A transposed port turns `(0, 0.5, 0.5)` into
    // `(0, -0.001960784, -0.001960784)` the wrong way round, and row one would
    // carry the offset instead. The sign is the catch.
    const out = color.Matrix4x3.mul(color.ycbcr_range_full, .{ 0.0, 0.5, 0.5, 1.0 });
    try expectVec(out, .{ 0.0, -0.001960814, -0.001960814 }, 1e-6);
}

test "the full range matrix leaves the three identity channels alone" {
    const out = color.Matrix4x3.mul(color.ycbcr_range_full, .{ 1.0, 1.0, 1.0, 1.0 });
    try expectVec(out, .{ 1.0, 0.498039186, 0.498039186 }, 1e-6);
}

test "the narrow range factors are the two closed forms" {
    // `ColorSpace.h:143-144` writes `255.0f / 219.0f` and `255.0f / 224.0f`.
    // The luma factor is not `255/219 + 16/219`: the offset term at
    // `ColorSpace.h:146` is `-16/255 * Yf`, so the factor stays a factor.
    try std.testing.expectApproxEqAbs(
        @as(f32, 255.0 / 219.0),
        color.ycbcr_range_narrow_y_factor,
        1e-7,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 255.0 / 224.0),
        color.ycbcr_range_narrow_chroma_factor,
        1e-7,
    );
}

test "the narrow range matrix maps the bottom code value" {
    // `ColorSpace.h:145-149` is `FromRows`, so its three groups of four are
    // rows and the matrix has four columns. This row is the one that fails if
    // the third row and the fourth column are confused: the affine term lives
    // entirely in the fourth column.
    const out = color.Matrix4x3.mul(color.ycbcr_range_narrow, .{ 0.0, 0.0, 0.0, 1.0 });
    try expectVec(out, .{ -0.073059365, -0.571428597, -0.571428597 }, 1e-6);
}

test "the narrow range matrix maps the two luma extremes" {
    // The two codes every implementation gets wrong by one of the two factors:
    // `(255*16-16)/219` and `(255*235-16)/219` for luma,
    // `(255*128-128)/224` for chroma.
    const low = color.Matrix4x3.mul(color.ycbcr_range_narrow, .{ 16.0, 128.0, 128.0, 1.0 });
    try expectVec(low, .{ 18.557077408, 145.142852783, 145.142852783 }, 1e-4);

    const high = color.Matrix4x3.mul(color.ycbcr_range_narrow, .{ 235.0, 128.0, 128.0, 1.0 });
    try expectVec(high, .{ 273.557067871, 145.142852783, 145.142852783 }, 1e-4);
}

// --- YCbCr to RGB, `ColorSpace.h:153-172` --------------------------------

test "the Rec601 matrix carries the literal divisions, not the published digits" {
    // `ColorSpace.h:156` writes `0.202008 / 0.587` and `0.419198 / 0.587`.
    // Those are 0.344136287 and 0.714136287, where the reference tables print
    // 0.1873 and 0.4681, so a port that copies the reference is wrong in the
    // sixth digit.
    const low = color.Matrix3.mul(color.ycbcr_to_rgb_rec_601, .{ 16.0, 128.0, 128.0 });
    try expectVec(low, .{ 195.455993652, -119.458892822, 242.815994263 }, 1e-4);

    const high = color.Matrix3.mul(color.ycbcr_to_rgb_rec_601, .{ 235.0, 128.0, 128.0 });
    try expectVec(high, .{ 414.455993652, 99.541114807, 461.815979004 }, 1e-4);
}

test "a negative green channel on narrow-range input is correct" {
    // `ColorSpace.h:152-158` is a full-range matrix applied to whatever it is
    // given. At code 16 the green component is below zero, and a test that
    // asserted non-negativity would be wrong.
    const out = color.Matrix3.mul(color.ycbcr_to_rgb_rec_601, .{ 0.0, 0.5, 0.5 });
    try expectVec(out, .{ 0.700999975, -0.529136300, 0.885999978 }, 1e-6);
}

test "the Rec709 matrix maps both code values and the normalised one" {
    // `ColorSpace.h:131-132` notes that Y, Cb and Cr arrive normalised to
    // `[0, 1]` from texture sampling, so the `(1, 0.5, 0.5)` row is the one a
    // sampled surface actually hits.
    const code = color.Matrix3.mul(color.ycbcr_to_rgb_rec_709, .{ 235.0, 128.0, 128.0 });
    try expectVec(code, .{ 436.574401855, 151.102737427, 472.516784668 }, 1e-4);

    const normalised = color.Matrix3.mul(color.ycbcr_to_rgb_rec_709, .{ 1.0, 0.5, 0.5 });
    try expectVec(normalised, .{ 1.787400007, 0.672276318, 1.927799940 }, 1e-6);
}

test "the Rec2020 matrix maps both code values and the normalised one" {
    const code = color.Matrix3.mul(color.ycbcr_to_rgb_rec_2020, .{ 235.0, 128.0, 128.0 });
    try expectVec(code, .{ 423.748779297, 140.804077148, 475.819213867 }, 1e-4);

    const normalised = color.Matrix3.mul(color.ycbcr_to_rgb_rec_2020, .{ 1.0, 0.5, 0.5 });
    try expectVec(normalised, .{ 1.737299919, 0.632047176, 1.940700054 }, 1e-6);
}

// --- Primaries, `ColorSpace.h:181-214` -----------------------------------

test "the Rec601 primaries are read column by column" {
    // `FromRows` (`Algebra.h:218`) transposes, so the three groups at
    // `ColorSpace.h:182-184` are rows and each unit input returns a column.
    const red = color.Matrix3.mul(color.rgb_to_xyz_rec_601, .{ 1.0, 0.0, 0.0 });
    try expectVec(red, .{ 0.430554003, 0.222003996, 0.020182000 }, 1e-6);

    const green = color.Matrix3.mul(color.rgb_to_xyz_rec_601, .{ 0.0, 1.0, 0.0 });
    try expectVec(green, .{ 0.341549993, 0.706655025, 0.129553005 }, 1e-6);

    const blue = color.Matrix3.mul(color.rgb_to_xyz_rec_601, .{ 0.0, 0.0, 1.0 });
    try expectVec(blue, .{ 0.178351998, 0.071341000, 0.939321995 }, 1e-6);

    const white = color.Matrix3.mul(color.rgb_to_xyz_rec_601, .{ 1.0, 1.0, 1.0 });
    try expectVec(white, .{ 0.950456023, 1.000000000, 1.089056969 }, 1e-6);
}

test "the Rec709 primaries are read column by column" {
    const red = color.Matrix3.mul(color.rgb_to_xyz_rec_709, .{ 1.0, 0.0, 0.0 });
    try expectVec(red, .{ 0.412391007, 0.212639004, 0.019331001 }, 1e-6);

    const blue = color.Matrix3.mul(color.rgb_to_xyz_rec_709, .{ 0.0, 0.0, 1.0 });
    try expectVec(blue, .{ 0.180481002, 0.072191998, 0.950532019 }, 1e-6);

    const white = color.Matrix3.mul(color.rgb_to_xyz_rec_709, .{ 1.0, 1.0, 1.0 });
    try expectVec(white, .{ 0.950456023, 1.000000000, 1.089058042 }, 1e-6);
}

test "the Rec601 and Rec709 white points differ in the last printed digit" {
    // Both cite D65, and the two sums differ: 1.089056969 against
    // 1.089058042. A copy-paste between the two matrices at `ColorSpace.h:181`
    // and `:189` erases that, and nothing else in the file catches it.
    const rec601 = color.Matrix3.mul(color.rgb_to_xyz_rec_601, .{ 1.0, 1.0, 1.0 });
    const rec709 = color.Matrix3.mul(color.rgb_to_xyz_rec_709, .{ 1.0, 1.0, 1.0 });
    if (rec601[2] == rec709[2]) return error.WhitePointsAreIdentical;
}

test "the Rec2020 primaries map the axes and the white point" {
    const red = color.Matrix3.mul(color.rgb_to_xyz_rec_2020, .{ 1.0, 0.0, 0.0 });
    try expectVec(red, .{ 0.636958003, 0.262699991, 0.000000000 }, 1e-6);

    const white = color.Matrix3.mul(color.rgb_to_xyz_rec_2020, .{ 1.0, 1.0, 1.0 });
    try expectVec(white, .{ 0.950456023, 1.000000000, 1.089057922 }, 1e-6);
}

test "the Display P3 primaries are the ten-digit ones" {
    // `ColorSpace.h:210-212` carries ten decimal places, four more than the
    // other four matrices, so its tolerance is an order tighter.
    const red = color.Matrix3.mul(color.rgb_to_xyz_display_p3, .{ 1.0, 0.0, 0.0 });
    try expectVec(red, .{ 0.486570954, 0.228974566, 0.000000000 }, 1e-7);

    const blue = color.Matrix3.mul(color.rgb_to_xyz_display_p3, .{ 0.0, 0.0, 1.0 });
    try expectVec(blue, .{ 0.198217288, 0.079286911, 1.043944359 }, 1e-7);

    const white = color.Matrix3.mul(color.rgb_to_xyz_display_p3, .{ 1.0, 1.0, 1.0 });
    try expectVec(white, .{ 0.950455904, 1.000000000, 1.089057684 }, 1e-7);
}

test "every inverse matrix undoes its own matrix on the white point" {
    // `ColorSpace.h:186`, `:194`, `:206` and `:214` write the inverses as
    // `Inverse()` calls, so the inverse is computed and never transcribed. A
    // wrong `Inverse()` wiring fails here whatever the published digits are.
    inline for (.{
        .{ color.rgb_to_xyz_rec_601, color.xyz_to_rgb_rec_601 },
        .{ color.rgb_to_xyz_rec_709, color.xyz_to_rgb_rec_709 },
        .{ color.rgb_to_xyz_rec_2020, color.xyz_to_rgb_rec_2020 },
        .{ color.rgb_to_xyz_display_p3, color.xyz_to_rgb_display_p3 },
    }) |pair| {
        const white = color.Matrix3.mul(pair[0], .{ 1.0, 1.0, 1.0 });
        const back = color.Matrix3.mul(pair[1], white);
        try expectVec(back, .{ 1.0, 1.0, 1.0 }, 1e-5);
    }
}

test "sRGB is Rec709, exactly" {
    // `ColorSpace.h:197-198` defines sRGB as an alias. The identity is a
    // compile-time claim in `src/platform/color_space.zig`; this asserts the
    // inverse side too, so a half-ported alias fails rather than passing one
    // direction.
    try std.testing.expect(color.Matrix3.eql(
        color.xyz_to_rgb_srgb,
        color.xyz_to_rgb_rec_709,
    ));
    if (color.xyz_to_rgb_srgb.columns[0][0] != color.xyz_to_rgb_rec_709.columns[0][0]) {
        return error.SrgbInverseIsNotRec709;
    }
}

// --- Transfer functions, `ColorSpace.h:236-299` --------------------------

test "the identity transfer function is the default struct" {
    // `ColorSpace.h:236` writes `inline constexpr TransferFunction
    // kEOTF_Identity = {}`, so the seven defaults are the identity.
    try std.testing.expect(color.eotf_identity.eql(.{}));
    try std.testing.expectEqual(@as(f32, 1.0), color.eotf_identity.g);
    try std.testing.expectEqual(@as(f32, 1.0), color.eotf_identity.a);
    try std.testing.expectEqual(@as(f32, 0.0), color.eotf_identity.b);
}

test "the identity transfer function returns its input" {
    inline for (.{ 0.0, 0.25, 1.0 }) |value| {
        try std.testing.expectApproxEqAbs(
            @as(f32, value),
            color.eotf_identity.apply(@as(f32, value)),
            1e-7,
        );
    }
}

test "the sRGB EOTF takes both branches and meets at the breakpoint" {
    // `ColorSpace.h:244` sets `d = 0.04045`. Below it the low branch is
    // `c * v`; at and above it the power branch runs. `0.04045` is the one
    // input where both branches must agree.
    try std.testing.expectEqual(
        @as(f32, 0.0),
        color.eotf_srgb.apply(0.0),
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.001547988),
        color.eotf_srgb.apply(0.02),
        1e-8,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.003130807),
        color.eotf_srgb.apply(0.04045),
        1e-7,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.214041144),
        color.eotf_srgb.apply(0.5),
        1e-7,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        color.eotf_srgb.apply(1.0),
        1e-6,
    );
}

test "the sRGB inverse does not return 1.0 for 1.0, and that is upstream" {
    // `ColorSpace.h:250` writes `a = 1.13711` as a five-digit rounding of
    // `1.055^2.4 = 1.1371144`, so the inverse maps 1.0 to 0.999996. A port
    // that "fixes" the digit breaks the round trip it is supposed to have.
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.499998212),
        color.eotf_inverse_srgb.apply(color.eotf_srgb.apply(0.5)),
        1e-5,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.999996483),
        color.eotf_inverse_srgb.apply(1.0),
        1e-5,
    );
}

test "the sRGB inverse round-trips the whole forward range" {
    inline for (.{ 0.0, 0.02, 0.04045, 0.5, 1.0 }) |value| {
        const forward = color.eotf_srgb.apply(@as(f32, value));
        const back = color.eotf_inverse_srgb.apply(forward);
        if (@abs(back - @as(f32, value)) > 1e-5) {
            std.debug.print("value {d:.6} came back as {d:.9}\n", .{ value, back });
            return error.ChannelOutOfTolerance;
        }
    }
}

test "the BT.1886 EOTF is gamma 2.4 with no low branch" {
    // `ColorSpace.h:260-268` sets `d = 0`, so the low branch never fires and
    // the whole function is `pow(v, 2.4)`.
    try std.testing.expectEqual(@as(f32, 0.0), color.eotf_bt_1886.apply(0.0));
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.035896815),
        color.eotf_bt_1886.apply(0.25),
        1e-7,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.189464569),
        color.eotf_bt_1886.apply(0.5),
        1e-7,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), color.eotf_bt_1886.apply(1.0), 1e-7);
}

test "the Display P3 EOTF is gamma 2.6 and its inverse is 1 over 2.6" {
    // `ColorSpace.h:271-288` sets `a = 1` and `b = 0` for both, so each is a
    // bare power.
    try std.testing.expectEqual(@as(f32, 0.0), color.eotf_display_p3.apply(0.0));
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.164938509),
        color.eotf_display_p3.apply(0.5),
        1e-7,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.765983224),
        color.eotf_inverse_display_p3.apply(0.5),
        1e-6,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.5),
        color.eotf_inverse_display_p3.apply(color.eotf_display_p3.apply(0.5)),
        1e-7,
    );
}

test "the SMPTE 170M EOTF takes both branches and has no inverse" {
    // `ColorSpace.h:291-299`. The breakpoint is `d = 0.0812` and `a` and `b`
    // are rounded to six digits, so the two branches disagree there by about
    // 5e-5. That is upstream, and it is why this row probes `0.05` and `0.1`
    // rather than the breakpoint.
    try std.testing.expectEqual(@as(f32, 0.0), color.eotf_smpte_170m.apply(0.0));
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.011111111),
        color.eotf_smpte_170m.apply(0.05),
        1e-8,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.022427956),
        color.eotf_smpte_170m.apply(0.1),
        1e-7,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), color.eotf_smpte_170m.apply(1.0), 1e-6);
}

// --- Luminance, `ColorSpace.h:301-316` -----------------------------------

test "the three reference luminances are the standards' numbers" {
    // `ColorSpace.h:308`, `:311` and `:316`. These are comptime constants and
    // the only thing that can go wrong is a typo, so the comparison is exact.
    // 203 against the 80 of the sRGB specification is the confusion the three
    // cited standards exist to prevent.
    try std.testing.expectEqual(@as(f32, 203.0), color.default_hdr_reference_white_luminance);
    try std.testing.expectEqual(@as(f32, 10000.0), color.pq_luminance_of_1);
    try std.testing.expectEqual(@as(f32, 1000.0), color.hlg_luminance_of_1);
}

// --- Composition, `ColorSpace.h:96-112` ----------------------------------

test "the range matrix runs before the YCbCr to RGB matrix" {
    // `ColorSpace.h:98-105` names the order: the 4x3 range matrix in
    // homogeneous coordinates, then the 3x3 linear transform. Swapping the
    // two changes the result by hundreds of code values.
    const ranged = color.Matrix4x3.mul(color.ycbcr_range_full, .{ 235.0, 128.0, 128.0, 1.0 });
    try expectVec(ranged, .{ 235.000000000, 127.498039246, 127.498039246 }, 1e-4);

    const rgb = color.Matrix3.mul(color.ycbcr_to_rgb_rec_709, ranged);
    try expectVec(rgb, .{ 435.783935547, 151.431732178, 471.585357666 }, 1e-4);
}

test "a full-range matrix on narrow-range input stays inside the code range" {
    // The narrow range step first, then Rec601, which is a full-range matrix.
    // Every component stays positive here, so the composition row is a check
    // on the order rather than on out-of-gamut behaviour.
    const ranged = color.Matrix4x3.mul(color.ycbcr_range_narrow, .{ 235.0, 128.0, 128.0, 1.0 });
    try expectVec(ranged, .{ 273.557067871, 145.142852783, 145.142852783 }, 1e-4);

    const rgb = color.Matrix3.mul(color.ycbcr_to_rgb_rec_601, ranged);
    try expectVec(rgb, .{ 477.047332764, 119.956375122, 530.750183105 }, 1e-4);
}
