const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const resource = @import("resource.zig");

pub const TextureKind = enum {
    albedo, // BC7 sRGB
    albedo_alpha, // BC7 sRGB with alpha
    // normal_map,       // BC5 linear (2-channel)
    // roughness_metallic, // BC5 linear
    // grayscale,        // BC4
    // hdr,              // BC6H
    // ui,               // BC7 sRGB, no mips
};

pub fn TextureSource(comptime path: []const u8, comptime kind: TextureKind) []const u8 {
    _ = kind;
    const ext = std.fs.path.extension(path);
    return "res/" ++ path[0 .. path.len - ext.len] ++ ".dds";
}

pub const GpuTexture = struct {
    data: []u8 = &.{},
    image: sg.Image = .{},
    view: sg.View = .{},
    sampler: sg.Sampler = .{},
};

fn readU32(data: []const u8, offset: usize) !u32 {
    if (offset + 4 > data.len) return error.InvalidDds;
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn pixelFormatForTextureKind(kind: TextureKind) sg.PixelFormat {
    return switch (kind) {
        .albedo, .albedo_alpha => .BC7_RGBA,
    };
}

pub fn loadDdsTexture(allocator: std.mem.Allocator, path: []const u8, kind: TextureKind) !GpuTexture {
    const data = try resource.readFileAlloc(allocator, path, std.Io.Limit.limited(64 * 1024 * 1024));
    errdefer allocator.free(data);

    if (data.len < 148 or !std.mem.eql(u8, data[0..4], "DDS ")) return error.InvalidDdsMagic;
    if (try readU32(data, 4) != 124) return error.InvalidDdsHeaderSize;
    if (try readU32(data, 76) != 32) return error.InvalidDdsPixelFormatSize;
    if (try readU32(data, 84) != std.mem.readInt(u32, "DX10", .little)) return error.MissingDdsDx10Header;

    const height = try readU32(data, 12);
    const width = try readU32(data, 16);
    const dxgi_format = try readU32(data, 128);
    if (dxgi_format != 98 and dxgi_format != 99) return error.UnsupportedDdsFormat;

    const blocks_w = (width + 3) / 4;
    const blocks_h = (height + 3) / 4;
    const level_size = blocks_w * blocks_h * 16;
    if (148 + level_size > data.len) return error.InvalidDds;

    var texture = GpuTexture{ .data = data };
    texture.sampler = sg.makeSampler(.{
        .label = "texture-sampler",
    });

    var img_desc = sg.ImageDesc{
        .width = @intCast(width),
        .height = @intCast(height),
        .pixel_format = pixelFormatForTextureKind(kind),
        .label = "block-texture",
    };
    img_desc.data.mip_levels[0] = sg.asRange(data[148 .. 148 + level_size]);
    texture.image = sg.makeImage(img_desc);
    texture.view = sg.makeView(.{ .texture = .{
        .image = texture.image,
    }, .label = "texture-view" });

    return texture;
}
