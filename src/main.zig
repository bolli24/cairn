const std = @import("std");
const math = @import("std").math;

const za = @import("zalgebra");
const Vec2 = za.Vec2;
const Vec3 = za.Vec3;
const Vec3_i32 = za.Vec3_i32;
const Vec4 = za.Vec4;
const Mat4 = za.Mat4;
const Quat = za.Quat;

const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const saudio = sokol.audio;
const slog = sokol.log;
const shader = @import("shader");

const obj = @import("obj.zig");
const terrain_mod = @import("terrain.zig");
const mesh_mod = @import("mesh.zig");
pub const Mesh = mesh_mod.Mesh;
const Vertex = mesh_mod.Vertex;
const Transform = mesh_mod.Transform;
const Camera = @import("camera.zig").Camera;
const Chunk = terrain_mod.Chunk;
const Terrain = terrain_mod.Terrain;

const input = @import("input.zig");
const InputState = input.InputState;

const fastnoise = @import("fastnoise");

var gpa: std.heap.DebugAllocator(.{}) = .init;

const State = struct {
    rx: f32 = 0.0,
    ry: f32 = 0.0,
    pip: sg.Pipeline = .{},
    pip_wireframe: sg.Pipeline = .{},
    wireframe: bool = false,
    meshes: std.ArrayList(Mesh) = .empty,
    terrain: Terrain = undefined,
    camera: Camera = .{},
    input: InputState = .{},
    light_color: Vec3 = .new(1, 1, 1),
    light_pos: Vec3 = .new(40, 40, 40),
    ambient_light: Vec3 = .new(0.2, 0.2, 0.2),

    fn deinit(self: *@This()) void {
        for (self.meshes.items) |*mesh| {
            mesh.deinit(gpa.allocator());
        }
        self.meshes.deinit(gpa.allocator());
        self.terrain.deinit();
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
        .buffer_pool_size = 1024,
    });

    const noise = fastnoise.Noise(f32){
        .seed = 1337,
        .noise_type = .simplex_smooth,
        .frequency = 0.025,
        .gain = 0.40,
        // .fractal_type = .fbm,
        // .lacunarity = 0.40,
        // .cellular_distance = .euclidean,
        // .cellular_return = .distance2,
        // .cellular_jitter_mod = 0.88,
    };

    state.terrain = terrain_mod.Terrain.generate_with_noise(gpa.allocator(), noise, .new(6, 2, 6));

    var suzanne = obj.load_mesh_from_obj(gpa.allocator(), "res/suzanne.obj") catch return;
    suzanne.transform.position = Vec3.new(0, 10, 0);
    suzanne.upload();
    state.add_mesh(suzanne) catch return;

    const shd = sg.makeShader(shader.basicShaderDesc(sg.queryBackend()));

    std.debug.print("{d}", .{sg.queryBackend()});

    var pip_desc = sg.PipelineDesc{
        .shader = shd,
        .index_type = .UINT16,
        .cull_mode = .BACK,
        .face_winding = .CCW,
        .depth = .{
            .write_enabled = true,
            .compare = .LESS_EQUAL,
        },
        .label = "basic-pipeline",
    };

    pip_desc.layout.buffers[0].stride = @sizeOf(Vertex);
    pip_desc.layout.attrs[shader.ATTR_basic_position].format = .FLOAT3;
    pip_desc.layout.attrs[shader.ATTR_basic_aNormal].format = .FLOAT3;
    pip_desc.layout.attrs[shader.ATTR_basic_aNormal].offset = @offsetOf(Vertex, "normal");

    state.pip = sg.makePipeline(pip_desc);

    pip_desc.primitive_type = .LINES;
    pip_desc.label = "wireframe-pipeline";
    state.pip_wireframe = sg.makePipeline(pip_desc);
}

export fn frame() void {
    const t = @as(f32, @floatCast(sapp.frameDuration()));

    state.camera.update(t, &state.input);

    if (state.input.key_pressed(.F1)) {
        state.wireframe = !state.wireframe;
    }

    if (state.input.mouse_pressed(.LEFT)) {
        const forward = state.camera.transform.rotation.rotateVec(Vec3.new(0, 0, -1));
        if (state.terrain.raycast(state.camera.transform.position, forward, 500.0)) |hit| {
            state.terrain.set_block(hit.previous, .ground, true);
        }
    }

    var pass = sg.Pass{ .swapchain = sglue.swapchain() };

    pass.action.colors[0] = .{ .load_action = .CLEAR, .clear_value = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1.0 } };

    sg.beginPass(pass);
    sg.applyPipeline(if (state.wireframe) state.pip_wireframe else state.pip);

    var chunk_it = state.terrain.chunks.valueIterator();
    while (chunk_it.next()) |chunk_ptr| {
        if (chunk_ptr.mesh.vertices.items.len == 0) continue;
        submit_mesh(&chunk_ptr.*.mesh);
    }

    for (state.meshes.items) |*mesh| {
        submit_mesh(mesh);
    }

    sg.endPass();
    sg.commit();

    state.input.update();
}

fn submit_mesh(mesh: *const Mesh) void {
    const use_wireframe = state.wireframe and mesh.wireframe_ibuf.id != 0;

    var bind: sg.Bindings = .{};
    bind.vertex_buffers[0] = mesh.vbuf;
    bind.index_buffer = if (use_wireframe) mesh.wireframe_ibuf else mesh.ibuf;
    const vs_params = compute_vsparams(state.rx, state.ry, mesh, &state.camera);
    const fs_params = shader.FsParams{
        .base_color = mesh.color.toArray(),
        .ambient = state.ambient_light.toArray(),
        .light_color = state.light_color.toArray(),
        .light_pos = state.light_pos.toArray(),
    };

    sg.applyBindings(bind);
    sg.applyUniforms(shader.UB_vs_params, sg.asRange(&vs_params));
    sg.applyUniforms(shader.UB_fs_params, sg.asRange(&fs_params));
    const num_indices = if (use_wireframe) mesh.wireframe_indices.items.len else mesh.indices.items.len;
    sg.draw(0, @intCast(num_indices), 1);
}

export fn event_handler(maybe_event: [*c]const sapp.Event) void {
    const event = maybe_event[0];
    // const t = sapp.frameDuration();
    switch (event.type) {
        .KEY_DOWN => if (!event.key_repeat) state.input.setKey(event.key_code, .pressed),
        .KEY_UP => state.input.setKey(event.key_code, .released),
        .MOUSE_DOWN => state.input.setMouse(event.mouse_button, .pressed),
        .MOUSE_UP => state.input.setMouse(event.mouse_button, .released),
        .MOUSE_MOVE => {
            state.input.mouse_delta = state.input.mouse_delta.add(Vec2.new(event.mouse_dx, event.mouse_dy));
        },
        else => {},
    }
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
        .event_cb = event_handler,
        .cleanup_cb = cleanup,
        .width = 1920,
        .height = 1080,
        .window_title = "voxel_zig",
        .logger = .{ .func = slog.func },
    });
}

test {
    _ = @import("obj.zig");
}

fn compute_vsparams(rx: f32, ry: f32, mesh: *const Mesh, camera: *const Camera) shader.VsParams {
    const w = sapp.widthf();
    const h = sapp.heightf();
    const proj = za.perspective(60.0, w / h, 0.01, 100);
    const view = camera.transform.rotation.inv().toMat4()
        .mul(Mat4.fromTranslate(camera.transform.position.negate()));
    const model = Mat4.fromTranslate(mesh.transform.position).mul(Mat4.fromEulerAngles(Vec3.new(rx, ry, 0)));

    return .{
        .model = model,
        .view = view,
        .proj = proj,
        .normal_mat = model.inv().transpose(),
    };
}
