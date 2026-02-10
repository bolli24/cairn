const std = @import("std");
const math = @import("std").math;

const za = @import("zalgebra");
const Vec3 = za.Vec3;
const Mat4 = za.Mat4;

const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const saudio = sokol.audio;
const slog = sokol.log;
const shader = @import("shader");

var gpa: std.heap.DebugAllocator(.{}) = .init;

const Mesh = struct {
    const Self = @This();
    vertices: std.ArrayList(f32) = .empty,
    indices: std.ArrayList(u16) = .empty,
    vbuf: sg.Buffer = .{},
    ibuf: sg.Buffer = .{},
    pos: Vec3 = .zero(),

    fn init(vertices: []const f32, indices: []const u16) !Self {
        var self: Self = .{};

        try self.vertices.appendSlice(gpa.allocator(), vertices);
        try self.indices.appendSlice(gpa.allocator(), indices);

        return self;
    }

    fn deinit(self: *Self) void {
        self.vertices.deinit(gpa.allocator());
        self.indices.deinit(gpa.allocator());
    }

    fn upload(self: *Self) void {
        if (self.vbuf.id != 0) sg.destroyBuffer(self.vbuf);
        if (self.ibuf.id != 0) sg.destroyBuffer(self.ibuf);

        self.vbuf = sg.makeBuffer(.{ .data = sg.asRange(self.vertices.items) });
        self.ibuf = sg.makeBuffer(.{
            .usage = .{ .index_buffer = true },
            .data = sg.asRange(self.indices.items),
        });
    }

    fn clone(self: *Self) !Self {
        const new_mesh = Self{
            .vertices = try self.vertices.clone(gpa.allocator()),
            .indices = try self.indices.clone(gpa.allocator()),
        };

        return new_mesh;
    }
};

const State = struct {
    rx: f32 = 0.0,
    ry: f32 = 0.0,
    pip: sg.Pipeline = .{},
    meshes: std.ArrayList(Mesh) = .empty,

    fn deinit(self: *@This()) void {
        for (self.meshes.items) |*mesh| {
            mesh.deinit();
        }
        self.meshes.deinit(gpa.allocator());
    }

    fn add_mesh(self: *@This(), mesh: Mesh) !void {
        try self.meshes.append(gpa.allocator(), mesh);
    }
};

var state: State = .{};

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    var mesh_a = Mesh.init(
        &.{ -1.0, -1.0, -1.0, 1.0, 0.0, 0.0, 1.0, 1.0, -1.0, -1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 1.0, -1.0, 1.0, 0.0, 0.0, 1.0, -1.0, 1.0, -1.0, 1.0, 0.0, 0.0, 1.0, -1.0, -1.0, 1.0, 0.0, 1.0, 0.0, 1.0, 1.0, -1.0, 1.0, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 1.0, 0.0, 1.0, -1.0, 1.0, 1.0, 0.0, 1.0, 0.0, 1.0, -1.0, -1.0, -1.0, 0.0, 0.0, 1.0, 1.0, -1.0, 1.0, -1.0, 0.0, 0.0, 1.0, 1.0, -1.0, 1.0, 1.0, 0.0, 0.0, 1.0, 1.0, -1.0, -1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 1.0, -1.0, -1.0, 1.0, 0.5, 0.0, 1.0, 1.0, 1.0, -1.0, 1.0, 0.5, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.5, 0.0, 1.0, 1.0, -1.0, 1.0, 1.0, 0.5, 0.0, 1.0, -1.0, -1.0, -1.0, 0.0, 0.5, 1.0, 1.0, -1.0, -1.0, 1.0, 0.0, 0.5, 1.0, 1.0, 1.0, -1.0, 1.0, 0.0, 0.5, 1.0, 1.0, 1.0, -1.0, -1.0, 0.0, 0.5, 1.0, 1.0, -1.0, 1.0, -1.0, 1.0, 0.0, 0.5, 1.0, -1.0, 1.0, 1.0, 1.0, 0.0, 0.5, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.5, 1.0, 1.0, 1.0, -1.0, 1.0, 0.0, 0.5, 1.0 },
        &.{ 0, 1, 2, 0, 2, 3, 6, 5, 4, 7, 6, 4, 8, 9, 10, 8, 10, 11, 14, 13, 12, 15, 14, 12, 16, 17, 18, 16, 18, 19, 22, 21, 20, 23, 22, 20 },
    ) catch return;
    mesh_a.pos = Vec3.right();

    var mesh_b = mesh_a.clone() catch return;
    mesh_b.pos = Vec3.left();

    mesh_a.upload();
    mesh_b.upload();

    state.add_mesh(mesh_a) catch return;
    state.add_mesh(mesh_b) catch return;

    const shd = sg.makeShader(shader.cubeShaderDesc(sg.queryBackend()));

    var pip_desc = sg.PipelineDesc{
        .shader = shd,
        .index_type = .UINT16,
        .cull_mode = .BACK,
        .depth = .{
            .write_enabled = true,
            .compare = .LESS_EQUAL,
        },
        .label = "cube-pipeline",
    };

    pip_desc.layout.buffers[0].stride = 28;
    pip_desc.layout.attrs[shader.ATTR_cube_position].format = .FLOAT3;
    pip_desc.layout.attrs[shader.ATTR_cube_color0].format = .FLOAT4;

    state.pip = sg.makePipeline(pip_desc);
}

export fn frame() void {
    const t = sapp.frameDuration();
    state.rx = state.rx + 50.0 * @as(f32, @floatCast(t));
    state.ry = state.ry + 100.0 * @as(f32, @floatCast(t));

    var pass = sg.Pass{ .swapchain = sglue.swapchain() };

    pass.action.colors[0] = .{ .load_action = .CLEAR, .clear_value = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1.0 } };

    sg.beginPass(pass);
    sg.applyPipeline(state.pip);

    for (state.meshes.items) |*mesh| {
        var bind: sg.Bindings = .{};
        bind.vertex_buffers[0] = mesh.vbuf;
        bind.index_buffer = mesh.ibuf;
        const vs_params = compute_vsparams(state.rx, state.ry, mesh);

        sg.applyBindings(bind);
        sg.applyUniforms(shader.UB_vs_params, sg.asRange(&vs_params));
        sg.draw(0, @intCast(mesh.indices.items.len), 1);
    }

    sg.endPass();
    sg.commit();
}

export fn cleanup() void {
    state.deinit();
    const check = gpa.deinit();
    if (check == .leak) {
        @panic("memory leak detected");
    }
    sg.shutdown();
}

pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        // .event_cb = input,
        .cleanup_cb = cleanup,
        .width = 720,
        .height = 480,
        .window_title = "voxel_zig",
        .logger = .{ .func = slog.func },
    });
}

fn compute_vsparams(rx: f32, ry: f32, mesh: *Mesh) shader.VsParams {
    const w = sapp.widthf();
    const h = sapp.heightf();
    const proj = za.perspective(60.0, w / h, 0.01, 100);
    const view = za.lookAt(Vec3.new(0.0, 1.5, 4.0), Vec3.zero(), Vec3.up());
    const view_proj = proj.mul(view);
    const model = Mat4.fromTranslate(mesh.pos).mul(Mat4.fromEulerAngles(Vec3.new(rx, ry, 0)));
    return .{ .mvp = view_proj.mul(model) };
}
