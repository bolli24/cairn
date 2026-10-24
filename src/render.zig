const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;

const za = @import("zalgebra");
const Mat4 = za.Mat4;
const Vec3 = za.Vec3;

const Mesh = @import("mesh.zig");
const Vertex = Mesh.Vertex;
const GpuTexture = @import("texture.zig").GpuTexture;

const TerrainShader = @import("terrain_shader");
const MeshShader = @import("mesh_shader");
const ShadowShader = @import("shadow_shader");

pub const LightParams = struct {
    color: Vec3 = .new(1, 1, 1),
    dir: Vec3 = Vec3.new(0.7, 0.6, 0.4).norm(),
    ambient: Vec3 = .new(0.6, 0.6, 0.6),
    brightness: f32 = 1.5,
};

pub const FrameParams = struct {
    view: Mat4,
    projection: Mat4,
    light: LightParams,
    shadows_enabled: bool,
    ambient_occlusion_enabled: bool,
};

pub const ShadowMap = struct {
    view: sg.View,
    sampler: sg.Sampler,
    view_projection: Mat4,
};

pub const TerrainRenderer = struct {
    const Self = @This();

    shader: sg.Shader = .{},
    solid_pipeline: sg.Pipeline = .{},
    wireframe_pipeline: sg.Pipeline = .{},
    block_texture: GpuTexture = .{},

    pub fn init(block_texture: GpuTexture) Self {
        const shader = sg.makeShader(TerrainShader.basicShaderDesc(sg.queryBackend()));
        var pipeline_desc = sg.PipelineDesc{
            .shader = shader,
            .index_type = .UINT16,
            .cull_mode = .BACK,
            .face_winding = .CCW,
            .depth = .{
                .write_enabled = true,
                .compare = .LESS_EQUAL,
            },
            .label = "terrain-pipeline",
        };
        pipeline_desc.layout.buffers[0].stride = @sizeOf(Vertex);
        pipeline_desc.layout.attrs[TerrainShader.ATTR_basic_position].format = .FLOAT3;
        pipeline_desc.layout.attrs[TerrainShader.ATTR_basic_aNormal].format = .FLOAT3;
        pipeline_desc.layout.attrs[TerrainShader.ATTR_basic_aNormal].offset = @offsetOf(Vertex, "normal");
        pipeline_desc.layout.attrs[TerrainShader.ATTR_basic_aUv].format = .FLOAT2;
        pipeline_desc.layout.attrs[TerrainShader.ATTR_basic_aUv].offset = @offsetOf(Vertex, "uv");
        pipeline_desc.layout.attrs[TerrainShader.ATTR_basic_ao].format = .FLOAT;
        pipeline_desc.layout.attrs[TerrainShader.ATTR_basic_ao].offset = @offsetOf(Vertex, "ao");

        const solid_pipeline = sg.makePipeline(pipeline_desc);
        pipeline_desc.primitive_type = .LINES;
        pipeline_desc.label = "terrain-wireframe-pipeline";

        return .{
            .shader = shader,
            .solid_pipeline = solid_pipeline,
            .wireframe_pipeline = sg.makePipeline(pipeline_desc),
            .block_texture = block_texture,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.solid_pipeline.id != 0) sg.destroyPipeline(self.solid_pipeline);
        if (self.wireframe_pipeline.id != 0) sg.destroyPipeline(self.wireframe_pipeline);
        if (self.shader.id != 0) sg.destroyShader(self.shader);
        self.block_texture.deinit(allocator);
        self.* = .{};
    }

    pub fn draw(
        self: *const Self,
        mesh: *const Mesh,
        model: Mat4,
        frame: FrameParams,
        shadow_map: ShadowMap,
        wireframe: bool,
    ) void {
        const use_wireframe = wireframe and mesh.wireframe_ibuf.id != 0;
        sg.applyPipeline(if (use_wireframe) self.wireframe_pipeline else self.solid_pipeline);

        var bindings: sg.Bindings = .{};
        bindings.vertex_buffers[0] = mesh.vbuf;
        bindings.index_buffer = if (use_wireframe) mesh.wireframe_ibuf else mesh.ibuf;
        bindings.views[TerrainShader.VIEW_color_map] = self.block_texture.view;
        bindings.samplers[TerrainShader.SMP_color_smp] = self.block_texture.sampler;
        bindings.views[TerrainShader.VIEW_shadow_map] = shadow_map.view;
        bindings.samplers[TerrainShader.SMP_shadow_smp] = shadow_map.sampler;

        const vs_params = TerrainShader.VsParams{
            .model = model,
            .view = frame.view,
            .proj = frame.projection,
            .normal_mat = model.inv().transpose(),
            .light_space = shadow_map.view_projection,
        };
        const fs_params = TerrainShader.FsParams{
            .base_color = mesh.color.toArray(),
            .ambient = frame.light.ambient.toArray(),
            .light_color = frame.light.color.toArray(),
            .light_dir = frame.light.dir.toArray(),
            .ao_strength = if (frame.ambient_occlusion_enabled) 0.6 else 0.0,
            .brightness = frame.light.brightness,
            .shadow_strength = if (frame.shadows_enabled) 1.0 else 0.0,
        };

        sg.applyBindings(bindings);
        sg.applyUniforms(TerrainShader.UB_vs_params, sg.asRange(&vs_params));
        sg.applyUniforms(TerrainShader.UB_fs_params, sg.asRange(&fs_params));
        const index_count = if (use_wireframe) mesh.wireframe_indices.items.len else mesh.indices.items.len;
        sg.draw(0, @intCast(index_count), 1);
    }
};

pub const MeshRenderer = struct {
    const Self = @This();

    shader: sg.Shader = .{},
    solid_pipeline: sg.Pipeline = .{},
    wireframe_pipeline: sg.Pipeline = .{},

    pub fn init() Self {
        const shader = sg.makeShader(MeshShader.basicShaderDesc(sg.queryBackend()));
        var pipeline_desc = sg.PipelineDesc{
            .shader = shader,
            .index_type = .UINT16,
            .cull_mode = .BACK,
            .face_winding = .CCW,
            .depth = .{
                .write_enabled = true,
                .compare = .LESS_EQUAL,
            },
            .label = "mesh-pipeline",
        };
        pipeline_desc.layout.buffers[0].stride = @sizeOf(Vertex);
        pipeline_desc.layout.attrs[MeshShader.ATTR_basic_position].format = .FLOAT3;
        pipeline_desc.layout.attrs[MeshShader.ATTR_basic_aNormal].format = .FLOAT3;
        pipeline_desc.layout.attrs[MeshShader.ATTR_basic_aNormal].offset = @offsetOf(Vertex, "normal");

        const solid_pipeline = sg.makePipeline(pipeline_desc);
        pipeline_desc.primitive_type = .LINES;
        pipeline_desc.label = "mesh-wireframe-pipeline";

        return .{
            .shader = shader,
            .solid_pipeline = solid_pipeline,
            .wireframe_pipeline = sg.makePipeline(pipeline_desc),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.solid_pipeline.id != 0) sg.destroyPipeline(self.solid_pipeline);
        if (self.wireframe_pipeline.id != 0) sg.destroyPipeline(self.wireframe_pipeline);
        if (self.shader.id != 0) sg.destroyShader(self.shader);
        self.* = .{};
    }

    pub fn draw(
        self: *const Self,
        mesh: *const Mesh,
        model: Mat4,
        frame: FrameParams,
        shadow_map: ShadowMap,
        wireframe: bool,
    ) void {
        const use_wireframe = wireframe and mesh.wireframe_ibuf.id != 0;
        sg.applyPipeline(if (use_wireframe) self.wireframe_pipeline else self.solid_pipeline);

        var bindings: sg.Bindings = .{};
        bindings.vertex_buffers[0] = mesh.vbuf;
        bindings.index_buffer = if (use_wireframe) mesh.wireframe_ibuf else mesh.ibuf;
        bindings.views[MeshShader.VIEW_shadow_map] = shadow_map.view;
        bindings.samplers[MeshShader.SMP_shadow_smp] = shadow_map.sampler;

        const vs_params = MeshShader.VsParams{
            .model = model,
            .view = frame.view,
            .proj = frame.projection,
            .normal_mat = model.inv().transpose(),
            .light_space = shadow_map.view_projection,
        };
        const fs_params = MeshShader.FsParams{
            .base_color = mesh.color.toArray(),
            .ambient = frame.light.ambient.toArray(),
            .light_color = frame.light.color.toArray(),
            .light_dir = frame.light.dir.toArray(),
            .brightness = frame.light.brightness,
            .shadow_strength = if (frame.shadows_enabled) 1.0 else 0.0,
        };

        sg.applyBindings(bindings);
        sg.applyUniforms(MeshShader.UB_vs_params, sg.asRange(&vs_params));
        sg.applyUniforms(MeshShader.UB_fs_params, sg.asRange(&fs_params));
        const index_count = if (use_wireframe) mesh.wireframe_indices.items.len else mesh.indices.items.len;
        sg.draw(0, @intCast(index_count), 1);
    }
};

pub const ShadowRenderer = struct {
    const Self = @This();

    depth_image: sg.Image = .{},
    depth_attachment: sg.View = .{},
    texture_view: sg.View = .{},
    sampler: sg.Sampler = .{},
    shader: sg.Shader = .{},
    pipeline: sg.Pipeline = .{},
    light_view_projection: Mat4 = Mat4.identity(),

    pub fn init(map_size: i32) Self {
        const depth_image = sg.makeImage(.{
            .usage = .{ .depth_stencil_attachment = true },
            .width = map_size,
            .height = map_size,
            .pixel_format = .DEPTH,
            .label = "shadow-depth-image",
        });
        const depth_attachment = sg.makeView(.{
            .depth_stencil_attachment = .{ .image = depth_image },
            .label = "shadow-depth-attachment",
        });
        const texture_view = sg.makeView(.{
            .texture = .{ .image = depth_image },
            .label = "shadow-texture-view",
        });
        const sampler = sg.makeSampler(.{
            .min_filter = .NEAREST,
            .mag_filter = .NEAREST,
            .wrap_u = .CLAMP_TO_EDGE,
            .wrap_v = .CLAMP_TO_EDGE,
            .label = "shadow-sampler",
        });

        const shader = sg.makeShader(ShadowShader.shadowShaderDesc(sg.queryBackend()));
        var pipeline_desc = sg.PipelineDesc{
            .shader = shader,
            .index_type = .UINT16,
            .cull_mode = .BACK,
            .face_winding = .CCW,
            .depth = .{
                .write_enabled = true,
                .compare = .LESS_EQUAL,
                .pixel_format = .DEPTH,
                .bias = 2.5,
                .bias_slope_scale = 2.5,
            },
            .label = "shadow-pipeline",
        };
        pipeline_desc.colors[0].pixel_format = .NONE;
        pipeline_desc.layout.buffers[0].stride = @sizeOf(Vertex);
        pipeline_desc.layout.attrs[ShadowShader.ATTR_shadow_position].format = .FLOAT3;

        return .{
            .depth_image = depth_image,
            .depth_attachment = depth_attachment,
            .texture_view = texture_view,
            .sampler = sampler,
            .shader = shader,
            .pipeline = sg.makePipeline(pipeline_desc),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.pipeline.id != 0) sg.destroyPipeline(self.pipeline);
        if (self.shader.id != 0) sg.destroyShader(self.shader);
        if (self.depth_attachment.id != 0) sg.destroyView(self.depth_attachment);
        if (self.texture_view.id != 0) sg.destroyView(self.texture_view);
        if (self.depth_image.id != 0) sg.destroyImage(self.depth_image);
        if (self.sampler.id != 0) sg.destroySampler(self.sampler);
        self.* = .{};
    }

    pub fn depthAttachment(self: *const Self) sg.View {
        return self.depth_attachment;
    }

    pub fn begin(self: *Self, light_view_projection: Mat4) void {
        self.light_view_projection = light_view_projection;
        sg.applyPipeline(self.pipeline);
    }

    pub fn draw(self: *const Self, mesh: *const Mesh, model: Mat4) void {
        var bindings: sg.Bindings = .{};
        bindings.vertex_buffers[0] = mesh.vbuf;
        bindings.index_buffer = mesh.ibuf;

        const vs_params = ShadowShader.VsParams{
            .mvp = self.light_view_projection.mul(model),
        };

        sg.applyBindings(bindings);
        sg.applyUniforms(ShadowShader.UB_vs_params, sg.asRange(&vs_params));
        sg.draw(0, @intCast(mesh.indices.items.len), 1);
    }

    pub fn shadowMap(self: *const Self) ShadowMap {
        return .{
            .view = self.texture_view,
            .sampler = self.sampler,
            .view_projection = self.light_view_projection,
        };
    }
};
