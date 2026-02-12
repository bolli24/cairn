const std = @import("std");
const math = @import("std").math;

const za = @import("zalgebra");
const Vec2 = za.Vec2;
const Vec3 = za.Vec3;
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

var gpa: std.heap.DebugAllocator(.{}) = .init;

const MOUSE_ROTATE_SPEED = 0.2;

const Transform = struct {
    position: Vec3 = .zero(),
    rotation: Quat = .identity(),
    scale: Vec3 = .one(),
};

pub const Mesh = struct {
    const Self = @This();
    vertices: std.ArrayList(Vec3) = .empty,
    normals: std.ArrayList(Vec3) = .empty,
    indices: std.ArrayList(u16) = .empty,
    vbuf: sg.Buffer = .{},
    ibuf: sg.Buffer = .{},
    nbuf: sg.Buffer = .{},
    transform: Transform = .{},
    allocator: std.mem.Allocator,

    fn init(vertices: []const Vec3, indices: []const u16, allocator: std.mem.Allocator) !Self {
        var self: Self = .{ .allocator = allocator };

        try self.vertices.appendSlice(allocator, vertices);
        try self.indices.appendSlice(allocator, indices);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.vertices.deinit(self.allocator);
        self.normals.deinit(self.allocator);
        self.indices.deinit(self.allocator);
    }

    fn upload(self: *Self) void {
        if (self.vbuf.id != 0) sg.destroyBuffer(self.vbuf);
        if (self.nbuf.id != 0) sg.destroyBuffer(self.nbuf);
        if (self.ibuf.id != 0) sg.destroyBuffer(self.ibuf);

        self.vbuf = sg.makeBuffer(.{ .data = .{
            .ptr = self.vertices.items.ptr,
            .size = self.vertices.items.len * @sizeOf(Vec3),
        } });

        if (self.normals.items.len > 0) {
            self.nbuf = sg.makeBuffer(.{ .data = .{
                .ptr = self.normals.items.ptr,
                .size = self.normals.items.len * @sizeOf(Vec3),
            } });
        }

        self.ibuf = sg.makeBuffer(.{
            .usage = .{ .index_buffer = true },
            .data = sg.asRange(self.indices.items),
        });
    }

    fn clone(self: *Self) !Self {
        const new_mesh = Self{
            .vertices = try self.vertices.clone(self.allocator),
            .normals = try self.normals.clone(self.allocator),
            .indices = try self.indices.clone(self.allocator),
        };

        return new_mesh;
    }
};

const Camera = struct {
    const Self = @This();
    transform: Transform = .{ .position = Vec3.new(0.0, 1.5, 4.0) },
    pitch: f32 = 0.0,
    yaw: f32 = 0.0,
    _mouse_start_pos: Vec2 = Vec2.zero(),

    fn rotate(self: *Self, dx: f32, dy: f32) void {
        self.yaw += dx;
        self.pitch = math.clamp(self.pitch + dy, -89.0, 89.0);
        const yaw_q = Quat.fromAxis(self.yaw, Vec3.up());
        const pitch_q = Quat.fromAxis(self.pitch, Vec3.right());
        self.transform.rotation = yaw_q.mul(pitch_q);
    }

    fn update(self: *Self, t: f32) void {
        const forward = self.transform.rotation.rotateVec(Vec3.new(0, 0, -1));
        const right = self.transform.rotation.rotateVec(Vec3.new(1, 0, 0));
        const speed: f32 = 10.0;
        const pos = &self.transform.position;

        if (state.input.key_down(.W)) pos.* = pos.add(forward.scale(speed * t));
        if (state.input.key_down(.S)) pos.* = pos.sub(forward.scale(speed * t));
        if (state.input.key_down(.D)) pos.* = pos.add(right.scale(speed * t));
        if (state.input.key_down(.A)) pos.* = pos.sub(right.scale(speed * t));

        if (state.input.mouse_down(.RIGHT)) {
            self.rotate(
                -state.input.mouse_delta.x() * MOUSE_ROTATE_SPEED,
                -state.input.mouse_delta.y() * MOUSE_ROTATE_SPEED,
            );
        }

        if (state.input.mouse_pressed(.RIGHT)) {
            sapp.lockMouse(true);
        } else if (state.input.mouse_released(.RIGHT)) {
            sapp.lockMouse(false);
        }
    }
};

const input = @import("input.zig");
const InputState = input.InputState;

const State = struct {
    rx: f32 = 0.0,
    ry: f32 = 0.0,
    pip: sg.Pipeline = .{},
    meshes: std.ArrayList(Mesh) = .empty,
    camera: Camera = .{},
    input: InputState = .{},

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

    var suzanne = obj.load_mesh_from_obj(gpa.allocator(), "res/suzanne.obj") catch return;
    suzanne.upload();
    state.add_mesh(suzanne) catch return;

    const shd = sg.makeShader(shader.basicShaderDesc(sg.queryBackend()));

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

    pip_desc.layout.buffers[0].stride = @sizeOf(Vec3);
    pip_desc.layout.buffers[1].stride = @sizeOf(Vec3);
    pip_desc.layout.attrs[shader.ATTR_basic_position].format = .FLOAT3;
    pip_desc.layout.attrs[shader.ATTR_basic_aNormal].format = .FLOAT3;
    pip_desc.layout.attrs[shader.ATTR_basic_aNormal].buffer_index = 1;

    state.pip = sg.makePipeline(pip_desc);
}

export fn frame() void {
    const t = @as(f32, @floatCast(sapp.frameDuration()));
    // state.rx += 50.0 * @as(f32, @floatCast(t));
    // state.ry += 100.0 * @as(f32, @floatCast(t));

    state.camera.update(t);

    var pass = sg.Pass{ .swapchain = sglue.swapchain() };

    pass.action.colors[0] = .{ .load_action = .CLEAR, .clear_value = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1.0 } };

    sg.beginPass(pass);
    sg.applyPipeline(state.pip);

    for (state.meshes.items) |*mesh| {
        var bind: sg.Bindings = .{};
        bind.vertex_buffers[0] = mesh.vbuf;
        bind.vertex_buffers[1] = mesh.nbuf;
        bind.index_buffer = mesh.ibuf;
        const vs_params = compute_vsparams(state.rx, state.ry, mesh, &state.camera);
        const fs_params = shader.FsParams{
            .base_color = .{ 0.5, 0.1, 1.0 },
            .ambient = .{ 0.2, 0.2, 0.2 },
            .light_color = .{ 0.1, 0.5, 0.1 },
            .light_pos = .{ 4.0, 4.0, 4.0 },
        };

        sg.applyBindings(bind);
        sg.applyUniforms(shader.UB_vs_params, sg.asRange(&vs_params));
        sg.applyUniforms(shader.UB_fs_params, sg.asRange(&fs_params));
        sg.draw(0, @intCast(mesh.indices.items.len), 1);
    }

    sg.endPass();
    sg.commit();

    state.input.update();
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
