const za = @import("zalgebra");
const Camera = @import("camera.zig").Camera;
const Vec3 = za.Vec3;
const Mat4 = za.Mat4;

const sg = @import("sokol").gfx;
const std = @import("std");
const Vertex = @import("mesh.zig").Vertex;

const LineShader = @import("line_shader");

pub const Shapes = struct {
    const Self = @This();
    const AA_WIDTH = 0.02;

    camera: *const Camera,
    shader: sg.Shader = .{},
    pipeline: sg.Pipeline = .{},
    vbuf: sg.Buffer = .{},
    ibuf: sg.Buffer = .{},
    allocator: std.mem.Allocator,
    vertices: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u16) = .empty,

    pub fn init(camera: *const Camera, allocator: std.mem.Allocator) Self {
        const shader = sg.makeShader(LineShader.basicShaderDesc(sg.queryBackend()));
        var pipeline_desc = sg.PipelineDesc{
            .shader = shader,
            .index_type = .UINT16,
            .cull_mode = .NONE,
            .depth = .{
                .write_enabled = true,
                .compare = .LESS_EQUAL,
            },
            .label = "shapes-pipeline",
        };
        pipeline_desc.colors[0] = .{
            .blend = .{
                .enabled = true,
                .src_factor_rgb = .SRC_ALPHA,
                .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                .src_factor_alpha = .SRC_ALPHA,
                .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
            },
        };
        pipeline_desc.layout.buffers[0].stride = @sizeOf(Vertex);
        pipeline_desc.layout.attrs[LineShader.ATTR_basic_position].format = .FLOAT3;
        pipeline_desc.layout.attrs[LineShader.ATTR_basic_aUv].format = .FLOAT2;
        pipeline_desc.layout.attrs[LineShader.ATTR_basic_aUv].offset = @offsetOf(Vertex, "uv");
        pipeline_desc.layout.attrs[LineShader.ATTR_basic_color0].format = .FLOAT4;
        pipeline_desc.layout.attrs[LineShader.ATTR_basic_color0].offset = @offsetOf(Vertex, "color");

        return .{
            .camera = camera,
            .shader = shader,
            .pipeline = sg.makePipeline(pipeline_desc),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.vbuf.id != 0) sg.destroyBuffer(self.vbuf);
        if (self.ibuf.id != 0) sg.destroyBuffer(self.ibuf);
        if (self.pipeline.id != 0) sg.destroyPipeline(self.pipeline);
        if (self.shader.id != 0) sg.destroyShader(self.shader);
        self.vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
    }

    pub fn line_3d(self: *Self, from: Vec3, to: Vec3, color: za.Vec4, thickness: f32) void {
        const dir = to.sub(from).norm();
        const cam_dir = self.camera.forward();
        const half_extend = thickness * 0.5 + AA_WIDTH;
        const right = dir.cross(cam_dir).norm().scale(half_extend);
        const half_t = thickness * 0.5;

        const base: u16 = @intCast(self.vertices.items.len);
        self.vertices.appendSlice(self.allocator, &.{
            .{ .pos = from.add(right), .normal = .zero(), .uv = .new(half_t, half_extend), .color = color },
            .{ .pos = from.sub(right), .normal = .zero(), .uv = .new(half_t, -half_extend), .color = color },
            .{ .pos = to.add(right), .normal = .zero(), .uv = .new(half_t, half_extend), .color = color },
            .{ .pos = to.sub(right), .normal = .zero(), .uv = .new(half_t, -half_extend), .color = color },
        }) catch return;
        self.indices.appendSlice(self.allocator, &.{
            base + 0, base + 1, base + 2,
            base + 1, base + 3, base + 2,
        }) catch return;
    }

    pub fn draw_all(self: *Self) void {
        if (self.vertices.items.len == 0) return;

        self.upload();

        var bind = sg.Bindings{};
        bind.vertex_buffers[0] = self.vbuf;
        bind.index_buffer = self.ibuf;

        const vs_params: LineShader.VsParams = .{
            .proj = self.camera.projectionMatrix(),
            .view = self.camera.viewMatrix(),
        };

        const fs_params: LineShader.FsParams = .{
            .aa_width = AA_WIDTH,
        };

        sg.applyPipeline(self.pipeline);
        sg.applyBindings(bind);
        sg.applyUniforms(LineShader.UB_vs_params, sg.asRange(&vs_params));
        sg.applyUniforms(LineShader.UB_fs_params, sg.asRange(&fs_params));
        sg.draw(0, @intCast(self.indices.items.len), 1);

        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
    }

    fn upload(self: *Self) void {
        if (self.vbuf.id != 0) sg.destroyBuffer(self.vbuf);
        if (self.ibuf.id != 0) sg.destroyBuffer(self.ibuf);
        self.vbuf = .{};
        self.ibuf = .{};

        self.vbuf = sg.makeBuffer(.{ .data = .{
            .ptr = self.vertices.items.ptr,
            .size = self.vertices.items.len * @sizeOf(Vertex),
        } });

        self.ibuf = sg.makeBuffer(.{
            .usage = .{ .index_buffer = true },
            .data = sg.asRange(self.indices.items),
        });
    }
};
