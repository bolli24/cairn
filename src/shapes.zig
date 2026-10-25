const za = @import("zalgebra");
const Camera = @import("camera.zig").Camera;
const Vec3 = za.Vec3;
const Mat4 = za.Mat4;
const Quat = za.Quat;

const sg = @import("sokol").gfx;
const std = @import("std");
const Vertex = @import("mesh.zig").Vertex;

const LineShader = @import("line_shader");

pub const Shapes = struct {
    const Self = @This();
    const AA_WIDTH = 0.02;
    const EPSILON = 1e-5;

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

        self.line_quad(from.add(right), from.sub(right), to.add(right), to.sub(right), color, thickness * 0.5, half_extend);
    }

    fn line_quad(self: *Self, a: Vec3, b: Vec3, c: Vec3, d: Vec3, color: za.Vec4, half_t: f32, half_extend: f32) void {
        const base: u16 = @intCast(self.vertices.items.len);
        self.vertices.appendSlice(self.allocator, &.{
            .{ .pos = a, .normal = .zero(), .uv = .new(half_t, half_extend), .color = color },
            .{ .pos = b, .normal = .zero(), .uv = .new(half_t, -half_extend), .color = color },
            .{ .pos = c, .normal = .zero(), .uv = .new(half_t, half_extend), .color = color },
            .{ .pos = d, .normal = .zero(), .uv = .new(half_t, -half_extend), .color = color },
        }) catch return;
        self.indices.appendSlice(self.allocator, &.{
            base + 0, base + 1, base + 2,
            base + 1, base + 3, base + 2,
        }) catch return;
    }

    /// Draw a full circle outline around `center` in the plane defined by `normal`.
    pub fn full_circle(self: *Self, center: Vec3, normal: Vec3, radius: f32, color: za.Vec4, thickness: f32, segments: u16) void {
        if (radius <= 0 or thickness <= 0 or segments < 3 or isZero(normal)) return;
        const axis = normal.norm();
        // Choose a reference that is not parallel to the normal.
        const reference = if (@abs(axis.y()) < 0.9) Vec3.up() else Vec3.right();
        const radial = axis.cross(reference).norm().scale(radius);
        self.circle(center.add(radial), axis, center, color, std.math.tau, thickness, segments);
    }

    /// Draw a circular arc starting at `from`, rotating `length_rad` radians around `normal` through `center`.
    pub fn circle(self: *Self, from: Vec3, normal: Vec3, center: Vec3, color: za.Vec4, length_rad: f32, thickness: f32, segments: u16) void {
        if (segments < 1 or thickness <= 0 or isZero(normal) or std.math.approxEqAbs(f32, length_rad, 0, EPSILON)) return;
        const axis = normal.norm();
        const offset = from.sub(center);
        if (isZero(axis.cross(offset))) return;
        const cam_dir = self.camera.forward();
        const half_t = thickness * 0.5;
        const half_extend = half_t + AA_WIDTH;
        const closed = std.math.approxEqAbs(f32, @abs(length_rad), std.math.tau, EPSILON);

        var prev_pos = Vec3.zero();
        var prev_neg = Vec3.zero();
        for (0..@as(usize, segments) + 1) |i| {
            const angle = length_rad * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            // Repeat the first vertex pair exactly at the full-circle seam.
            const radial = if (closed and i == segments)
                offset
            else
                Quat.fromAxis(std.math.radiansToDegrees(angle), axis).rotateVec(offset);
            const point = center.add(radial);
            const tangent = axis.cross(radial).norm();
            var side = tangent.cross(cam_dir).norm();
            if (isZero(side)) side = self.camera.transform.rotation.rotateVec(Vec3.right());
            const right = side.scale(half_extend);
            const pos = point.add(right);
            const neg = point.sub(right);
            if (i > 0) self.line_quad(prev_pos, prev_neg, pos, neg, color, half_t, half_extend);
            prev_pos = pos;
            prev_neg = neg;
        }
    }

    fn isZero(v: Vec3) bool {
        return v.dot(v) < EPSILON * EPSILON;
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
