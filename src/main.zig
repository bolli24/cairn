const std = @import("std");
const math = @import("std").math;

const zigimg = @import("zigimg");

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
const simgui = sokol.imgui;
const sgimgui = sokol.sgimgui;
const saudio = sokol.audio;
const slog = sokol.log;
const shader = @import("shader");
const line_shader = @import("line_shader");
const shadow_shader = @import("shadow_shader");

const use_docking = @import("build_options").docking;
const ig = if (use_docking) @import("cimgui_docking") else @import("cimgui");

const obj = @import("obj.zig");
const terrain_mod = @import("terrain.zig");
const mesh_mod = @import("mesh.zig");
pub const Mesh = mesh_mod.Mesh;
const Vertex = mesh_mod.Vertex;
const Camera = @import("camera.zig").Camera;
const Chunk = terrain_mod.Chunk;
const Terrain = terrain_mod.Terrain;
const Shapes = @import("shapes.zig").Shapes;

const input = @import("input.zig");
const InputState = input.InputState;
const BuildingState = @import("building.zig").BuildingState;

const fastnoise = @import("fastnoise");

var gpa: std.heap.DebugAllocator(.{}) = .init;

const SHADOW_MAP_SIZE: i32 = 4096;

const Light = struct {
    color: Vec3 = .new(1, 1, 1),
    dir: Vec3 = Vec3.new(0.7, 0.6, 0.4).norm(),
    ambient: Vec3 = .new(0.4, 0.4, 0.4),
    brightness: f32 = 1.5,
};

const Shadow = struct {
    depth_img: sg.Image = .{},
    depth_view: sg.View = .{},
    tex_view: sg.View = .{},
    sampler: sg.Sampler = .{},
    pip: sg.Pipeline = .{},
    light_view_proj: Mat4 = Mat4.identity(),
};

const Texture = struct {
    image_data: zigimg.Image = .{},
    image: sg.Image = .{},
    view: sg.View = .{},
    sampler: sg.Sampler = .{},
};

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
    light: Light = .{},
    show_light_rays: bool = false,
    shapes: Shapes = undefined,
    building: BuildingState = undefined,
    shadow: Shadow = .{},
    texture: Texture = .{},

    fn deinit(self: *@This()) void {
        for (self.meshes.items) |*mesh| {
            mesh.deinit(gpa.allocator());
        }
        self.meshes.deinit(gpa.allocator());
        self.terrain.deinit();
        self.building.deinit();
        self.shapes.deinit();
        self.texture.image_data.deinit(gpa.allocator());
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
        .buffer_pool_size = 2048,
    });

    sgimgui.setup(.{});
    simgui.setup(.{
        .logger = .{ .func = slog.func },
    });
    if (use_docking) {
        ig.igGetIO().*.ConfigFlags |= ig.ImGuiConfigFlags_DockingEnable;
    }

    std.debug.print("Backend: {s}\n", .{@tagName(sg.queryBackend())});

    // Shadow map resources
    state.shadow.depth_img = sg.makeImage(.{
        .usage = .{ .depth_stencil_attachment = true },
        .width = SHADOW_MAP_SIZE,
        .height = SHADOW_MAP_SIZE,
        .pixel_format = .DEPTH,
        .label = "shadow-depth-img",
    });
    state.shadow.depth_view = sg.makeView(.{
        .depth_stencil_attachment = .{ .image = state.shadow.depth_img },
        .label = "shadow-depth-att-view",
    });
    state.shadow.tex_view = sg.makeView(.{
        .texture = .{ .image = state.shadow.depth_img },
        .label = "shadow-tex-view",
    });
    state.shadow.sampler = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
        .label = "shadow-sampler",
    });

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    state.texture.image_data = zigimg.Image.fromFilePath(gpa.allocator(), "res/p.png", read_buffer[0..]) catch return;

    state.texture.sampler = sg.makeSampler(.{
        .label = "texture-sampler",
    });

    var img_desc = sg.ImageDesc{
        .width = @intCast(state.texture.image_data.width),
        .height = @intCast(state.texture.image_data.height),
        .label = "block-texture",
    };
    img_desc.data.mip_levels[0] = sg.asRange(state.texture.image_data.pixels.rgba32);
    state.texture.image = sg.makeImage(img_desc);

    state.texture.view = sg.makeView(.{ .texture = .{
        .image = state.texture.image,
    }, .label = "texture-view" });

    const noise = fastnoise.Noise(f32){
        .seed = 1337,
        .noise_type = .simplex_smooth,
        .frequency = 0.025,
        .gain = 0.40,
        .fractal_type = .fbm,
        .lacunarity = 0.40,
        .cellular_distance = .euclidean,
        .cellular_return = .distance2,
        .cellular_jitter_mod = 0.88,
    };

    const terrain_size = za.Vec3_usize.new(12, 3, 12);
    state.terrain = terrain_mod.Terrain.generate_with_noise(gpa.allocator(), noise, terrain_size);
    state.building = BuildingState.init(gpa.allocator());
    state.camera.target_pos = Vec2.new(
        @floatFromInt(terrain_size.x() * terrain_mod.CHUNK_SIZE / 2),
        @floatFromInt(terrain_size.z() * terrain_mod.CHUNK_SIZE / 2),
    );

    var suzanne = obj.load_mesh_from_obj(gpa.allocator(), "res/suzanne.obj") catch return;
    suzanne.transform.position = Vec3.new(0, 10, 0);
    suzanne.upload();
    state.add_mesh(suzanne) catch return;

    // Shadow pipeline
    const shadow_shd = sg.makeShader(shadow_shader.shadowShaderDesc(sg.queryBackend()));
    var shadow_pip_desc = sg.PipelineDesc{
        .shader = shadow_shd,
        .index_type = .UINT16,
        .cull_mode = .BACK,
        .face_winding = .CCW,
        .depth = .{
            .write_enabled = true,
            .compare = .LESS_EQUAL,
            .pixel_format = .DEPTH,
        },
        .label = "shadow-pipeline",
    };
    shadow_pip_desc.colors[0].pixel_format = .NONE;
    shadow_pip_desc.layout.buffers[0].stride = @sizeOf(Vertex);
    shadow_pip_desc.layout.attrs[shadow_shader.ATTR_shadow_position].format = .FLOAT3;
    state.shadow.pip = sg.makePipeline(shadow_pip_desc);

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

    pip_desc.layout.buffers[0].stride = @sizeOf(Vertex);
    pip_desc.layout.attrs[shader.ATTR_basic_position].format = .FLOAT3;
    pip_desc.layout.attrs[shader.ATTR_basic_aNormal].format = .FLOAT3;
    pip_desc.layout.attrs[shader.ATTR_basic_aNormal].offset = @offsetOf(Vertex, "normal");
    pip_desc.layout.attrs[shader.ATTR_basic_aUv].format = .FLOAT2;
    pip_desc.layout.attrs[shader.ATTR_basic_aUv].offset = @offsetOf(Vertex, "uv");
    pip_desc.layout.attrs[shader.ATTR_basic_ao].format = .FLOAT;
    pip_desc.layout.attrs[shader.ATTR_basic_ao].offset = @offsetOf(Vertex, "ao");

    state.pip = sg.makePipeline(pip_desc);

    pip_desc.primitive_type = .LINES;
    pip_desc.label = "wireframe-pipeline";

    state.pip_wireframe = sg.makePipeline(pip_desc);

    const line_shd = sg.makeShader(line_shader.basicShaderDesc(sg.queryBackend()));
    var line_pip_desc = sg.PipelineDesc{
        .shader = line_shd,
        .index_type = .UINT16,
        .cull_mode = .NONE,
        .depth = .{
            .write_enabled = true,
            .compare = .LESS_EQUAL,
        },
        .label = "shapes-pipeline",
    };
    line_pip_desc.colors[0] = .{
        .blend = .{
            .enabled = true,
            .src_factor_rgb = .SRC_ALPHA,
            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
            .src_factor_alpha = .SRC_ALPHA,
            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        },
    };
    line_pip_desc.layout.buffers[0].stride = @sizeOf(Vertex);
    line_pip_desc.layout.attrs[line_shader.ATTR_basic_position].format = .FLOAT3;
    line_pip_desc.layout.attrs[line_shader.ATTR_basic_aUv].format = .FLOAT2;
    line_pip_desc.layout.attrs[line_shader.ATTR_basic_aUv].offset = @offsetOf(Vertex, "uv");
    line_pip_desc.layout.attrs[line_shader.ATTR_basic_color0].format = .FLOAT4;
    line_pip_desc.layout.attrs[line_shader.ATTR_basic_color0].offset = @offsetOf(Vertex, "color");

    state.shapes = .{
        .camera = &state.camera,
        .pipeline = sg.makePipeline(line_pip_desc),
        .allocator = gpa.allocator(),
    };

    state.shadow.light_view_proj = compute_light_view_proj();
}

export fn frame() void {
    var frame_timer = std.time.Timer.start() catch unreachable;
    const t = @as(f32, @floatCast(sapp.frameDuration()));

    // call simgui.newFrame() before any ImGui calls
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });

    if (ig.igBeginMainMenuBar()) {
        sgimgui.drawMenu("sokol-gfx");
        ig.igEndMainMenuBar();
    }
    sgimgui.draw();

    state.camera.update(t, &state.input);

    if (state.input.key_pressed(.F1)) {
        state.wireframe = !state.wireframe;
    }

    if (state.input.key_pressed(.L)) {
        state.show_light_rays = !state.show_light_rays;
    }

    state.building.update(&state.input, &state.camera, &state.terrain, &state.shapes);

    if (!state.building.active and state.input.mouse_pressed(.LEFT)) {
        if (state.terrain.raycast(state.camera.transform.position, state.camera.forward(), 500.0)) |hit| {
            state.terrain.set_block(hit.previous, .ground, true);
        }
    }

    // Shadow pass
    var shadow_pass = sg.Pass{};
    shadow_pass.action.depth = .{ .load_action = .CLEAR, .clear_value = 1.0 };
    shadow_pass.attachments.depth_stencil = state.shadow.depth_view;

    sg.beginPass(shadow_pass);
    sg.applyPipeline(state.shadow.pip);

    var chunk_it = state.terrain.chunks.valueIterator();
    while (chunk_it.next()) |chunk_ptr| {
        if (chunk_ptr.mesh.vertices.items.len == 0) continue;
        submit_shadow_mesh(&chunk_ptr.*.mesh);
    }
    for (state.meshes.items) |*mesh| {
        submit_shadow_mesh(mesh);
    }
    sg.endPass();

    // Main pass
    var pass = sg.Pass{ .swapchain = sglue.swapchain() };
    pass.action.colors[0] = .{ .load_action = .CLEAR, .clear_value = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1.0 } };
    pass.action.depth = .{ .load_action = .CLEAR, .clear_value = 1.0 };

    sg.beginPass(pass);
    sg.applyPipeline(if (state.wireframe) state.pip_wireframe else state.pip);

    chunk_it = state.terrain.chunks.valueIterator();
    while (chunk_it.next()) |chunk_ptr| {
        if (chunk_ptr.mesh.vertices.items.len == 0) continue;
        submit_mesh(&chunk_ptr.*.mesh);
    }

    for (state.meshes.items) |*mesh| {
        submit_mesh(mesh);
    }

    // Test lines
    state.shapes.line_3d(Vec3.new(0, 20, 0), Vec3.new(10, 20, 0), Vec4.new(1, 0, 0, 1), 0.2);
    state.shapes.line_3d(Vec3.new(0, 20, 0), Vec3.new(0, 30, 0), Vec4.new(0, 1, 0, 1), 0.2);
    state.shapes.line_3d(Vec3.new(0, 20, 0), Vec3.new(0, 20, 10), Vec4.new(0, 0, 1, 1), 0.2);

    if (state.show_light_rays) {
        if (state.terrain.raycast(state.camera.transform.position, state.camera.screen_to_ray(state.input.mouse_pos), 500.0)) |hit| {
            const p = hit.pos;
            const x: f32 = @floatFromInt(p.x());
            const y: f32 = @floatFromInt(p.y());
            const z: f32 = @floatFromInt(p.z());
            const ray = state.light.dir.scale(2.0);
            const color = Vec4.new(1, 1, 0, 1);
            const top_vertices = [4]Vec3{
                Vec3.new(x, y + 1, z),
                Vec3.new(x + 1, y + 1, z),
                Vec3.new(x, y + 1, z + 1),
                Vec3.new(x + 1, y + 1, z + 1),
            };
            for (top_vertices) |v| {
                state.shapes.line_3d(v, v.add(ray), color, 0.05);
            }
        }
    }

    sg.applyPipeline(state.shapes.pipeline);
    state.shapes.draw_all();

    sg.endPass();

    var pass_action = sg.PassAction{};
    pass_action.colors[0] = .{
        .load_action = .LOAD,
    };

    sg.beginPass(.{
        .action = pass_action,
        .swapchain = sglue.swapchain(),
    });

    ig.igSetNextWindowPos(.{ .x = 10, .y = 20 }, ig.ImGuiCond_Once);
    _ = ig.igBegin(
        "debug_text",
        null,
        ig.ImGuiWindowFlags_NoBackground | ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoInputs,
    );
    ig.igText("%4.1f fps \t %4.1f ms", 1 / t, t * 1000);

    ig.igEnd();

    simgui.render();
    sg.endPass();
    sg.commit();

    state.input.update();

    const cpu_us = frame_timer.read() / std.time.ns_per_us;
    _ = cpu_us;
    // std.debug.print("cpu: {d:.1}us ({d:.2}ms)\n", .{ @as(f64, @floatFromInt(cpu_us)), @as(f64, @floatFromInt(cpu_us)) / 1000.0 });
}

fn submit_mesh(mesh: *const Mesh) void {
    const use_wireframe = state.wireframe and mesh.wireframe_ibuf.id != 0;

    var bind: sg.Bindings = .{};
    bind.vertex_buffers[0] = mesh.vbuf;
    bind.index_buffer = if (use_wireframe) mesh.wireframe_ibuf else mesh.ibuf;
    bind.views[shader.VIEW_color_map] = state.texture.view;
    bind.samplers[shader.SMP_color_smp] = state.texture.sampler;
    bind.views[shader.VIEW_shadow_map] = state.shadow.tex_view;
    bind.samplers[shader.SMP_shadow_smp] = state.shadow.sampler;
    const vs_params = compute_vsparams(state.rx, state.ry, mesh, &state.camera);
    const fs_params = shader.FsParams{
        .base_color = mesh.color.toArray(),
        .ambient = state.light.ambient.toArray(),
        .light_color = state.light.color.toArray(),
        .light_dir = state.light.dir.toArray(),
        .ao_strength = 0.6,
        .brightness = state.light.brightness,
    };

    sg.applyBindings(bind);
    sg.applyUniforms(shader.UB_vs_params, sg.asRange(&vs_params));
    sg.applyUniforms(shader.UB_fs_params, sg.asRange(&fs_params));
    const num_indices = if (use_wireframe) mesh.wireframe_indices.items.len else mesh.indices.items.len;
    sg.draw(0, @intCast(num_indices), 1);
}

export fn event_handler(maybe_event: [*c]const sapp.Event) void {
    const event = maybe_event.*;
    // const t = sapp.frameDuration();
    switch (event.type) {
        .KEY_DOWN => if (!event.key_repeat) state.input.setKey(event.key_code, .pressed),
        .KEY_UP => state.input.setKey(event.key_code, .released),
        .MOUSE_DOWN => state.input.setMouse(event.mouse_button, .pressed),
        .MOUSE_UP => state.input.setMouse(event.mouse_button, .released),
        .MOUSE_MOVE => {
            state.input.mouse_pos = Vec2.new(event.mouse_x, event.mouse_y);
            state.input.mouse_delta = state.input.mouse_delta.add(Vec2.new(event.mouse_dx, event.mouse_dy));
        },
        .MOUSE_SCROLL => {
            state.input.scroll_delta = state.input.scroll_delta.add(Vec2.new(event.scroll_x, event.scroll_y));
        },
        else => {},
    }

    _ = simgui.handleEvent(maybe_event.*);
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
    const proj = camera.projectionMatrix();
    const view = camera.viewMatrix();
    const model = Mat4.fromTranslate(mesh.transform.position).mul(Mat4.fromEulerAngles(Vec3.new(rx, ry, 0)));

    return .{
        .model = model,
        .view = view,
        .proj = proj,
        .normal_mat = model.inv().transpose(),
        .light_space = state.shadow.light_view_proj,
    };
}

fn compute_light_view_proj() Mat4 {
    const scene_center = Vec3.new(96.0, 24.0, 96.0);
    const light_dir = state.light.dir;
    const light_eye = scene_center.add(light_dir.scale(250.0));
    const light_view = Mat4.lookAt(light_eye, scene_center, Vec3.new(0.0, 0.0, 1.0));
    const light_proj = Mat4.orthographic(-150.0, 150.0, -150.0, 150.0, 0.1, 600.0);
    return light_proj.mul(light_view);
}

fn submit_shadow_mesh(mesh: *const Mesh) void {
    var bind: sg.Bindings = .{};
    bind.vertex_buffers[0] = mesh.vbuf;
    bind.index_buffer = mesh.ibuf;

    const model = Mat4.fromTranslate(mesh.transform.position)
        .mul(Mat4.fromEulerAngles(Vec3.new(state.rx, state.ry, 0)));
    const vs_params = shadow_shader.VsParams{ .mvp = state.shadow.light_view_proj.mul(model) };

    sg.applyBindings(bind);
    sg.applyUniforms(shadow_shader.UB_vs_params, sg.asRange(&vs_params));
    sg.draw(0, @intCast(mesh.indices.items.len), 1);
}
