const std = @import("std");

pub const AlphaMode = enum(u32) {
    opaque_ = 1,
    premultiplied = 2,
    unpremultiplied = 3,
};

pub const Origin2D = struct { x: u32 = 0, y: u32 = 0 };
pub const Extent2D = struct { width: u32, height: u32 };

pub const Error = error{
    BrowserCopyInternalUsageForbidden,
    BrowserCopyConversionParametersMissing,
    BrowserCopyTransferLengthInvalid,
    BrowserCopyMatrixLengthInvalid,
    BrowserCopyParameterNonFinite,
};

pub const Input = struct {
    flip_y: bool = false,
    needs_color_space_conversion: bool = false,
    src_alpha_mode: AlphaMode = .unpremultiplied,
    src_transfer_function_parameters: ?[]const f32 = null,
    conversion_matrix: ?[]const f32 = null,
    dst_transfer_function_parameters: ?[]const f32 = null,
    dst_alpha_mode: AlphaMode = .unpremultiplied,
    internal_usage: bool = false,
};

pub const Options = struct {
    flip_y: bool = false,
    needs_color_space_conversion: bool = false,
    src_alpha_mode: AlphaMode = .unpremultiplied,
    src_transfer_function_parameters: [7]f32 = identity_transfer,
    conversion_matrix: [9]f32 = identity_matrix,
    dst_transfer_function_parameters: [7]f32 = identity_transfer,
    dst_alpha_mode: AlphaMode = .unpremultiplied,

    pub fn fromInput(input: Input) Error!Options {
        if (input.internal_usage) return error.BrowserCopyInternalUsageForbidden;
        if (input.needs_color_space_conversion and
            (input.src_transfer_function_parameters == null or input.conversion_matrix == null or
                input.dst_transfer_function_parameters == null))
        {
            return error.BrowserCopyConversionParametersMissing;
        }
        var result: Options = .{
            .flip_y = input.flip_y,
            .needs_color_space_conversion = input.needs_color_space_conversion,
            .src_alpha_mode = input.src_alpha_mode,
            .dst_alpha_mode = input.dst_alpha_mode,
        };
        if (input.src_transfer_function_parameters) |values| {
            result.src_transfer_function_parameters = try copyTransfer(values);
        }
        if (input.dst_transfer_function_parameters) |values| {
            result.dst_transfer_function_parameters = try copyTransfer(values);
        }
        if (input.conversion_matrix) |values| {
            if (values.len != 9) return error.BrowserCopyMatrixLengthInvalid;
            try validateFinite(values);
            @memcpy(&result.conversion_matrix, values);
        }
        return result;
    }

    pub fn validate(self: *const Options) Error!void {
        try validateFinite(&self.src_transfer_function_parameters);
        try validateFinite(&self.dst_transfer_function_parameters);
        try validateFinite(&self.conversion_matrix);
    }
};

const identity_transfer: [7]f32 = .{ 1, 1, 0, 1, 0, 0, 0 };
const identity_matrix: [9]f32 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };

fn copyTransfer(values: []const f32) Error![7]f32 {
    if (values.len != 7) return error.BrowserCopyTransferLengthInvalid;
    try validateFinite(values);
    var result: [7]f32 = undefined;
    @memcpy(&result, values);
    return result;
}

fn validateFinite(values: []const f32) Error!void {
    std.debug.assert(values.len <= 9);
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.BrowserCopyParameterNonFinite;
    }
}
