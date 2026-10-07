//! Native high descriptors retain exact API format identity.
//! Physical Vulkan formats are derived only for the low creation call.
const std = @import("std");
const api = @import("../api/api.zig");
const pipeline = @import("../pipeline/pipeline.zig");
const render = @import("../pipeline/pipeline_render.zig");
const formats = @import("vulkan_format.zig");
const vulkan = @import("vulkan");

/// Undefined format is a real absent color slot, not a format selected by the backend.
pub const ColorTargetState = struct {
    format: api.TextureFormat,
    write_mask: u32 = 0xF,
    blend: ?render.BlendState = null,

    pub fn toNative(self: ColorTargetState) pipeline.ColorTargetState {
        if (self.format == .undefined_) return .{
            .format = vulkan.VK_FORMAT_UNDEFINED,
            .write_mask = 0,
            .blend = null,
        };
        return .{
            .format = formats.vkFormat(self.format),
            .write_mask = self.write_mask,
            .blend = self.blend,
        };
    }
};

/// The API depth/stencil format remains authoritative even when physical formats coincide.
pub const DepthStencilState = struct {
    format: api.TextureFormat,
    depth_write_enabled: bool = false,
    depth_compare: render.CompareFunction = .always,
    stencil_front: render.StencilFaceState = .{},
    stencil_back: render.StencilFaceState = .{},
    stencil_read_mask: u32 = std.math.maxInt(u32),
    stencil_write_mask: u32 = std.math.maxInt(u32),
    depth_bias: i32 = 0,
    depth_bias_slope_scale: f32 = 0,
    depth_bias_clamp: f32 = 0,

    pub fn toNative(self: DepthStencilState) pipeline.DepthStencilState {
        return .{
            .format = formats.vkFormat(self.format),
            .depth_write_enabled = self.depth_write_enabled,
            .depth_compare = self.depth_compare,
            .stencil_front = self.stencil_front,
            .stencil_back = self.stencil_back,
            .stencil_read_mask = self.stencil_read_mask,
            .stencil_write_mask = self.stencil_write_mask,
            .depth_bias = self.depth_bias,
            .depth_bias_slope_scale = self.depth_bias_slope_scale,
            .depth_bias_clamp = self.depth_bias_clamp,
        };
    }
};
