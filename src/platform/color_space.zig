//! The colour-space constants and the two matrix shapes they are applied with.
//!
//! **What this file is.** The port of `src/dawn/common/ColorSpace.h` at Dawn
//! revision `32f77c02294310054a660c393feded4bcb3f203c`, read-only at
//! `/tmp/scratch/research/dawn`. That header declares 27
//! constants and no function, so the whole ported artefact is this table and
//! the two shapes needed to read it.
//!
//! **What this file does not claim.** It does not claim the algebra.
//! `src/dawn/common/Algebra.h` is 419 lines and 22 upstream rows that
//! `docs/40-plan.md` §A2 gives to M7 in the `engine` module. The three
//! operations `ColorSpace.h` needs are `FromRows`, `Inverse` and
//! `Mul(Matrix, Vector)`; they are here as private helpers and are not a port
//! of `Algebra.h`.
//!
//! **Column storage is load-bearing.** `Algebra.h:407-415` defines
//! `Mat<Cols>x<Rows>f` as `Matrix<Cols, Rows, float>`, `Matrix` stores
//! `std::array<Column, Cols>` (`Algebra.h:192`), and `FromRows`
//! (`Algebra.h:218-220`) transposes so that the matrix's *columns* are the
//! groups written on paper. `kYCbCrRange_Full` (`ColorSpace.h:135-140`) does
//! not use `FromRows`; it uses the column constructor (`Algebra.h:200`), so its
//! four groups are already columns. Both matrices are 4 columns of 3 and
//! consume a 4-vector, which is why the range step and the YCbCr-to-RGB step
//! cannot be swapped.

const std = @import("std");

/// Three `f32` components, the column type of every matrix here.
pub const Vec3 = [3]f32;

/// Four `f32` components. The homogeneous form the range matrices consume.
pub const Vec4 = [4]f32;

/// A 3x3 matrix stored by column, `Matrix<3, 3, float>`.
///
/// One column per unit input: `mul(m, .{ 1, 0, 0 })` is the matrix's first
/// column, which is how `ColorSpace.h` reads every one of its primaries.
pub const Matrix3 = struct {
    columns: [3]Vec3,

    /// Ports `Matrix::Identity` (`Algebra.h:238-244`).
    pub const identity: Matrix3 = .{
        .columns = .{
            .{ 1, 0, 0 },
            .{ 0, 1, 0 },
            .{ 0, 0, 1 },
        },
    };

    /// Ports `Matrix::FromRows` (`Algebra.h:218-220`).
    ///
    /// The groups are the rows a reference writes on paper, so column `j` of
    /// the result is element `j` of every group.
    pub fn fromRows(rows: [3]Vec3) Matrix3 {
        return .{
            .columns = .{
                .{ rows[0][0], rows[1][0], rows[2][0] },
                .{ rows[0][1], rows[1][1], rows[2][1] },
                .{ rows[0][2], rows[1][2], rows[2][2] },
            },
        };
    }

    /// Ports `Mul(Matrix, Vector)` (`Algebra.h:328-334`).
    pub fn mul(m: Matrix3, v: Vec3) Vec3 {
        var result: Vec3 = .{ 0, 0, 0 };
        inline for (0..3) |index| {
            result = .{
                result[0] + m.columns[index][0] * v[index],
                result[1] + m.columns[index][1] * v[index],
                result[2] + m.columns[index][2] * v[index],
            };
        }
        return result;
    }

    /// Ports `Matrix::Determinant` (`Algebra.h:362-366`).
    pub fn determinant(m: Matrix3) f32 {
        const d = m.columns;
        return d[0][0] * (d[2][2] * d[1][1] - d[1][2] * d[2][1]) +
            d[0][1] * (d[1][2] * d[2][0] - d[2][2] * d[1][0]) +
            d[0][2] * (d[2][1] * d[1][0] - d[1][1] * d[2][0]);
    }

    /// Ports `Matrix::Inverse` (`Algebra.h:377-393`).
    ///
    /// Upstream divides the whole adjugate by the determinant once, at the end
    /// of the return statement. The order is kept because a published digit of
    /// `kXYZToRGB_*` is a digit of this arithmetic.
    pub fn inverse(m: Matrix3) Matrix3 {
        const d = m.columns;
        const det = m.determinant();
        return .{
            .columns = .{
                .{
                    (d[2][2] * d[1][1] - d[1][2] * d[2][1]) / det,
                    (-d[2][2] * d[0][1] + d[0][2] * d[2][1]) / det,
                    (d[1][2] * d[0][1] - d[0][2] * d[1][1]) / det,
                },
                .{
                    (-d[2][2] * d[1][0] + d[1][2] * d[2][0]) / det,
                    (d[2][2] * d[0][0] - d[0][2] * d[2][0]) / det,
                    (-d[1][2] * d[0][0] + d[0][2] * d[1][0]) / det,
                },
                .{
                    (d[2][1] * d[1][0] - d[1][1] * d[2][0]) / det,
                    (-d[2][1] * d[0][0] + d[0][1] * d[2][0]) / det,
                    (d[1][1] * d[0][0] - d[0][1] * d[1][0]) / det,
                },
            },
        };
    }

    /// Element-wise equality, for the `k*_sRGB` alias rows (`ColorSpace.h:197`).
    pub fn eql(left: Matrix3, right: Matrix3) bool {
        return std.meta.eql(left, right);
    }
};

/// A 4x3 matrix stored by column, `Matrix<4, 3, float>`.
///
/// `Matrix::RowCount` is `Cols` (`Algebra.h:186`), so a 4-column matrix is a
/// homogeneous one: it consumes a `Vec4` and produces a `Vec3`. Both YCbCr range
/// matrices are this shape.
pub const Matrix4x3 = struct {
    columns: [4]Vec3,

    /// Ports the `std::array` constructor (`Algebra.h:200`).
    ///
    /// `kYCbCrRange_Full` (`ColorSpace.h:135-140`) is written with this one, so
    /// its four groups are columns and nothing is transposed.
    pub fn fromColumns(columns: [4]Vec3) Matrix4x3 {
        return .{ .columns = columns };
    }

    /// Ports `Matrix::FromRows` (`Algebra.h:218-220`).
    ///
    /// `kYCbCrRange_Narrow` (`ColorSpace.h:145-149`) is written with this one,
    /// so its three groups of four are rows and the result has four columns.
    pub fn fromRows(rows: [3]Vec4) Matrix4x3 {
        return .{
            .columns = .{
                .{ rows[0][0], rows[1][0], rows[2][0] },
                .{ rows[0][1], rows[1][1], rows[2][1] },
                .{ rows[0][2], rows[1][2], rows[2][2] },
                .{ rows[0][3], rows[1][3], rows[2][3] },
            },
        };
    }

    /// Ports `Mul(Matrix, Vector)` (`Algebra.h:328-334`).
    pub fn mul(m: Matrix4x3, v: Vec4) Vec3 {
        var result: Vec3 = .{ 0, 0, 0 };
        inline for (0..4) |index| {
            result = .{
                result[0] + m.columns[index][0] * v[index],
                result[1] + m.columns[index][1] * v[index],
                result[2] + m.columns[index][2] * v[index],
            };
        }
        return result;
    }
};

/// The seven coefficients of one transfer function (`ColorSpace.h:226-234`).
///
/// Dawn writes the EOTF as
/// `if (abs(v) < D) return sign(v) * (C * abs(v) + F); return pow(A*v+B, G)+E;`
/// at `ColorSpace.h:220-223`, with a typo on the second line: the parameter is
/// `v` and the comment says `x`.
pub const TransferFunction = struct {
    /// The exponent of the high branch.
    g: f32 = 1,
    /// The scale of the high branch.
    a: f32 = 1,
    /// The offset of the high branch.
    b: f32 = 0,
    /// The slope of the low branch.
    c: f32 = 0,
    /// The breakpoint between the branches.
    d: f32 = 0,
    /// The offset of the high branch, applied after the power.
    e: f32 = 0,
    /// The offset of the low branch. Every one of the seven constants sets it
    /// to `0.0f` and no branch reads a non-zero value, and it is kept because
    /// `AGENTS.md` §2 forbids deleting an upstream field.
    f: f32 = 0,

    /// Ports the piecewise formula at `ColorSpace.h:220-223`.
    pub fn apply(tf: TransferFunction, v: f32) f32 {
        if (@abs(v) < tf.d) {
            return std.math.copysign(tf.c * @abs(v) + tf.f, v);
        }
        return std.math.pow(f32, tf.a * v + tf.b, tf.g) + tf.e;
    }

    /// Element-wise equality, for the `kEOTF_Identity` row (`ColorSpace.h:236`).
    pub fn eql(left: TransferFunction, right: TransferFunction) bool {
        return left.g == right.g and left.a == right.a and left.b == right.b and
            left.c == right.c and left.d == right.d and left.e == right.e and
            left.f == right.f;
    }
};

// --- YCbCr range, `ColorSpace.h:134-149` ---------------------------------

/// `kYCbCrRange_Full` (`ColorSpace.h:135`). Written as columns, not rows.
pub const ycbcr_range_full: Matrix4x3 = Matrix4x3.fromColumns(.{
    .{ 1, 0, 0 },
    .{ 0, 1, 0 },
    .{ 0, 0, 1 },
    .{ 0, -128.0 / 255.0, -128.0 / 255.0 },
});

/// `kYCbCrRange_NarrowYFactor` (`ColorSpace.h:143`).
pub const ycbcr_range_narrow_y_factor: f32 = 255.0 / 219.0;

/// `kYCbCrRange_NarrowChromaFactor` (`ColorSpace.h:144`).
pub const ycbcr_range_narrow_chroma_factor: f32 = 255.0 / 224.0;

/// `kYCbCrRange_Narrow` (`ColorSpace.h:145`). Written as rows.
pub const ycbcr_range_narrow: Matrix4x3 = Matrix4x3.fromRows(.{
    .{ ycbcr_range_narrow_y_factor, 0, 0, -16.0 / 255.0 * ycbcr_range_narrow_y_factor },
    .{ 0, ycbcr_range_narrow_chroma_factor, 0, -128.0 / 255.0 * ycbcr_range_narrow_chroma_factor },
    .{ 0, 0, ycbcr_range_narrow_chroma_factor, -128.0 / 255.0 * ycbcr_range_narrow_chroma_factor },
});

// --- YCbCr to RGB, `ColorSpace.h:153-172` --------------------------------

/// `kYCbCrToRGB_Rec601` (`ColorSpace.h:154`).
///
/// The G row carries the literal divisions `0.202008 / 0.587` and
/// `0.419198 / 0.587` rather than the rounded 0.1873 and 0.4681 of the
/// references, and a test that pins a published digit would read one ulp off.
pub const ycbcr_to_rgb_rec_601: Matrix3 = Matrix3.fromRows(.{
    .{ 1, 0, 1.402 },
    .{ 1, -(0.202008 / 0.587), -(0.419198 / 0.587) },
    .{ 1, 1.772, 0 },
});

/// `kYCbCrToRGB_Rec709` (`ColorSpace.h:161`).
pub const ycbcr_to_rgb_rec_709: Matrix3 = Matrix3.fromRows(.{
    .{ 1, 0, 1.5748 },
    .{ 1, -(0.133974 / 0.7152), -(0.334802 / 0.7152) },
    .{ 1, 1.8556, 0 },
});

/// `kYCbCrToRGB_Rec2020` (`ColorSpace.h:168`).
pub const ycbcr_to_rgb_rec_2020: Matrix3 = Matrix3.fromRows(.{
    .{ 1, 0, 1.4746 },
    .{ 1, -(0.111567 / 0.678), -(0.387377 / 0.678) },
    .{ 1, 1.8814, 0 },
});

// --- Primaries, `ColorSpace.h:181-214` -----------------------------------

/// `kRGBToXYZ_Rec601` (`ColorSpace.h:181`). Rec 601, 625-line.
pub const rgb_to_xyz_rec_601: Matrix3 = Matrix3.fromRows(.{
    .{ 0.430554, 0.341550, 0.178352 },
    .{ 0.222004, 0.706655, 0.071341 },
    .{ 0.020182, 0.129553, 0.939322 },
});

/// `kXYZToRGB_Rec601` (`ColorSpace.h:186`).
pub const xyz_to_rgb_rec_601: Matrix3 = rgb_to_xyz_rec_601.inverse();

/// `kRGBToXYZ_Rec709` (`ColorSpace.h:189`).
pub const rgb_to_xyz_rec_709: Matrix3 = Matrix3.fromRows(.{
    .{ 0.412391, 0.357584, 0.180481 },
    .{ 0.212639, 0.715169, 0.072192 },
    .{ 0.019331, 0.119195, 0.950532 },
});

/// `kXYZToRGB_Rec709` (`ColorSpace.h:194`).
pub const xyz_to_rgb_rec_709: Matrix3 = rgb_to_xyz_rec_709.inverse();

/// `kRGBToXYZ_sRGB` (`ColorSpace.h:197`). The header states sRGB is Rec709.
pub const rgb_to_xyz_srgb: Matrix3 = rgb_to_xyz_rec_709;

/// `kXYZToRGB_sRGB` (`ColorSpace.h:198`).
pub const xyz_to_rgb_srgb: Matrix3 = xyz_to_rgb_rec_709;

/// `kRGBToXYZ_Rec2020` (`ColorSpace.h:201`).
pub const rgb_to_xyz_rec_2020: Matrix3 = Matrix3.fromRows(.{
    .{ 0.636958, 0.144617, 0.168881 },
    .{ 0.262700, 0.677998, 0.059302 },
    .{ 0.0, 0.028073, 1.060985 },
});

/// `kXYZToRGB_Rec2020` (`ColorSpace.h:206`).
pub const xyz_to_rgb_rec_2020: Matrix3 = rgb_to_xyz_rec_2020.inverse();

/// `kRGBToXYZ_DisplayP3` (`ColorSpace.h:209`).
///
/// The reference comment above it at `ColorSpace.h:208` names BT.2020, which
/// is an upstream copy-paste; the numbers are Display P3's.
pub const rgb_to_xyz_display_p3: Matrix3 = Matrix3.fromRows(.{
    .{ 0.4865709486, 0.2656676932, 0.1982172852 },
    .{ 0.2289745641, 0.6917385218, 0.0792869141 },
    .{ 0.0, 0.0451133819, 1.0439443689 },
});

/// `kXYZToRGB_DisplayP3` (`ColorSpace.h:214`).
pub const xyz_to_rgb_display_p3: Matrix3 = rgb_to_xyz_display_p3.inverse();

// --- Transfer functions, `ColorSpace.h:236-299` --------------------------

/// `kEOTF_Identity` (`ColorSpace.h:236`).
pub const eotf_identity: TransferFunction = .{};

/// `kEOTF_sRGB` (`ColorSpace.h:239`).
pub const eotf_srgb: TransferFunction = .{
    .g = 2.4,
    .a = 1.0 / 1.055,
    .b = 0.055 / 1.055,
    .c = 1.0 / 12.92,
    .d = 0.04045,
    .e = 0.0,
    .f = 0.0,
};

/// `kEOTFInverse_sRGB` (`ColorSpace.h:248`).
///
/// `a` is the six-digit `1.055^2.4 = 1.1371144` rounded to `1.13711`, so the
/// inverse maps `1.0` to `0.999996` rather than to `1.0`. That is upstream.
pub const eotf_inverse_srgb: TransferFunction = .{
    .g = 1.0 / 2.4,
    .a = 1.13711,
    .b = 0.0,
    .c = 12.92,
    .d = 0.0031308,
    .e = -0.055,
    .f = 0.0,
};

/// `kEOTF_BT_1886` (`ColorSpace.h:260`). Also known as gamma 2.4.
pub const eotf_bt_1886: TransferFunction = .{
    .g = 2.4,
    .a = 1.0,
    .b = 0.0,
    .c = 0.0,
    .d = 0.0,
    .e = 0.0,
    .f = 0.0,
};

/// `kEOTF_DisplayP3` (`ColorSpace.h:271`).
pub const eotf_display_p3: TransferFunction = .{
    .g = 2.6,
    .a = 1.0,
    .b = 0.0,
    .c = 0.0,
    .d = 0.0,
    .e = 0.0,
    .f = 0.0,
};

/// `kEOTFInverse_DisplayP3` (`ColorSpace.h:280`).
pub const eotf_inverse_display_p3: TransferFunction = .{
    .g = 1.0 / 2.6,
    .a = 1.0,
    .b = 0.0,
    .c = 0.0,
    .d = 0.0,
    .e = 0.0,
    .f = 0.0,
};

/// `kEOTF_SMPTE_170M` (`ColorSpace.h:291`).
///
/// The header has no inverse constant for it: the inverse set is sRGB and
/// Display P3 only.
pub const eotf_smpte_170m: TransferFunction = .{
    .g = 1.0 / 0.45,
    .a = 1.0 / 1.099,
    .b = 0.099 / 1.099,
    .c = 1.0 / 4.5,
    .d = 0.0812,
    .e = 0.0,
    .f = 0.0,
};

// --- Luminance, `ColorSpace.h:301-316` -----------------------------------

/// `kDefaultHDRReferenceWhiteLuminance` (`ColorSpace.h:308`). 203 nits, not the
/// 80 the sRGB specification gives.
pub const default_hdr_reference_white_luminance: f32 = 203;

/// `kPQLuminanceOf1` (`ColorSpace.h:311`).
pub const pq_luminance_of_1: f32 = 10000;

/// `kHLGLuminanceOf1` (`ColorSpace.h:316`).
pub const hlg_luminance_of_1: f32 = 1000;

comptime {
    // `ColorSpace.h:197-198` defines sRGB as an alias of Rec709. A copy that
    // drifts by one ulp is a real defect, so the identity is a compile-time
    // claim and not a test tolerance.
    if (!Matrix3.eql(rgb_to_xyz_srgb, rgb_to_xyz_rec_709)) @compileError("sRGB XYZ drifted");
    if (!Matrix3.eql(xyz_to_rgb_srgb, xyz_to_rgb_rec_709)) @compileError("sRGB inverse drifted");

    // `ColorSpace.h:236` defines the identity as the default-constructed
    // `TransferFunction`, so the default must be the identity.
    if (!TransferFunction.eql(eotf_identity, .{})) @compileError("identity is not the default");
}
