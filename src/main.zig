const std = @import("std");

const za = @import("zalgebra");
const Vec3 = za.Vec3;
const Vec3_i32 = za.Vec3_i32;
const Vec4 = za.Vec4;
const Mat4 = za.Mat4;

const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const sgimgui = sokol.gfximgui;
const saudio = sokol.audio;
const slog = sokol.log;

const use_docking = @import("build_options").docking;
const ig = if (use_docking) @import("cimgui_docking") else @import("cimgui");

const obj = @import("obj.zig");
const Terrain = @import("terrain.zig");
pub const Mesh = @import("mesh.zig");
const Camera = @import("camera.zig").Camera;
const Shapes = @import("shapes.zig").Shapes;
const render = @import("render.zig");

const input = @import("input.zig");
const InputState = input.InputState;
const BuildingState = @import("building.zig").BuildingState;
const texture_mod = @import("texture.zig");
const TextureSource = texture_mod.TextureSource;

const fastnoise = @import("fastnoise");

var gpa: std.heap.DebugAllocator(.{}) = .init;

const SHADOW_MAP_SIZE: i32 = 4096;

const block_texture_source = TextureSource("p.png", .albedo);

const State = struct {
    rx: f32 = 0.0,
    ry: f32 = 0.0,
    wireframe: bool = false,
    meshes: std.ArrayList(Mesh) = .empty,
    terrain: Terrain = undefined,
    camera: Camera = .{},
    input: InputState = .{},
    light: render.LightParams = .{},
    show_light_rays: bool = false,
    shadows_enabled: bool = true,
    ambient_occlusion_enabled: bool = true,
    shapes: Shapes = undefined,
    building: BuildingState = undefined,
    terrain_renderer: render.TerrainRenderer = .{},
    mesh_renderer: render.MeshRenderer = .{},
    shadow_renderer: render.ShadowRenderer = .{},

    fn deinit(self: *@This()) void {
        for (self.meshes.items) |*mesh| {
            mesh.deinit(gpa.allocator());
        }
        self.meshes.deinit(gpa.allocator());
        self.terrain.deinit();
        self.building.deinit();
        self.shapes.deinit();
        self.terrain_renderer.deinit(gpa.allocator());
        self.mesh_renderer.deinit();
        self.shadow_renderer.deinit();
    }

    fn add_mesh(self: *@This(), mesh: Mesh) !void {
        try self.meshes.append(gpa.allocator(), mesh);
    }
};

var state: State = .{};

const Timer = struct {
    start_time: std.Io.Clock.Timestamp,
    lap_time: std.Io.Clock.Timestamp,

    fn start() !Timer {
        const now = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
        return .{
            .start_time = now,
            .lap_time = now,
        };
    }

    fn read(self: Timer) u64 {
        return @intCast(self.start_time.durationTo(std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake)).raw.toNanoseconds());
    }

    fn lap(self: *Timer) u64 {
        const now = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
        defer self.lap_time = now;
        return @intCast(self.lap_time.durationTo(now).raw.toNanoseconds());
    }
};

fn logStartupSection(name: []const u8, timer: *Timer) void {
    const ms = @as(f64, @floatFromInt(timer.lap())) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    std.debug.print("startup {s}: {d:.2} ms\n", .{ name, ms });
}

export fn init() void {
    var startup_timer = Timer.start() catch unreachable;
    var section_timer = Timer.start() catch unreachable;

    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
        .buffer_pool_size = 2048,
    });
    logStartupSection("sokol setup", &section_timer);

    sgimgui.setup(.{});
    simgui.setup(.{
        .logger = .{ .func = slog.func },
    });
    if (use_docking) {
        ig.igGetIO().*.ConfigFlags |= ig.ImGuiConfigFlags_DockingEnable;
    }
    logStartupSection("imgui setup", &section_timer);

    std.debug.print("Backend: {s}\n", .{@tagName(sg.queryBackend())});

    state.shadow_renderer = render.ShadowRenderer.init(SHADOW_MAP_SIZE);
    logStartupSection("shadow resources", &section_timer);

    const block_texture = texture_mod.loadDdsTexture(gpa.allocator(), block_texture_source, .albedo) catch |err| {
        std.debug.print("texture load failed: {s}\n", .{@errorName(err)});
        return;
    };
    state.terrain_renderer = render.TerrainRenderer.init(block_texture);
    state.mesh_renderer = render.MeshRenderer.init();
    logStartupSection("texture load", &section_timer);

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
    state.terrain = Terrain.generate_with_noise(gpa.allocator(), noise, terrain_size);
    logStartupSection("terrain generation", &section_timer);

    state.terrain.remesh_all();
    logStartupSection("terrain meshing", &section_timer);

    state.building = BuildingState.init(gpa.allocator());
    state.camera.target_pos = Vec3.new(
        @floatFromInt(terrain_size.x() * Terrain.CHUNK_SIZE / 2),
        0.0,
        @floatFromInt(terrain_size.z() * Terrain.CHUNK_SIZE / 2),
    );
    logStartupSection("building camera init", &section_timer);

    var suzanne = obj.load_mesh_from_obj(gpa.allocator(), "res/suzanne.obj") catch return;
    logStartupSection("obj load", &section_timer);

    suzanne.transform.position = Vec3.new(0, 10, 0);
    suzanne.upload();
    state.add_mesh(suzanne) catch return;
    logStartupSection("obj upload", &section_timer);

    state.shapes = Shapes.init(&state.camera, gpa.allocator());
    logStartupSection("shape pipeline", &section_timer);

    const total_ms = @as(f64, @floatFromInt(startup_timer.read())) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    std.debug.print("startup total: {d:.2} ms\n", .{total_ms});
}

export fn frame() void {
    var frame_timer = Timer.start() catch unreachable;
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

    state.camera.update(t, &state.input, &state.terrain);

    if (state.input.key_pressed(.F1)) {
        state.wireframe = !state.wireframe;
    }

    if (state.input.key_pressed(.F2)) {
        state.shadows_enabled = !state.shadows_enabled;
    }

    if (state.input.key_pressed(.F3)) {
        state.ambient_occlusion_enabled = !state.ambient_occlusion_enabled;
    }

    if (state.input.key_pressed(.L)) {
        state.show_light_rays = !state.show_light_rays;
    }

    state.building.update(&state.input, &state.camera, &state.terrain, &state.shapes);

    if (!state.building.active and state.input.mouse_pressed(.LEFT)) {
        if (state.terrain.raycast(state.camera.screen_to_ray(state.input.mouse_pos, 500))) |hit| {
            state.terrain.set_block(hit.previous, .ground, true);
        }
    }

    // Shadow pass
    var shadow_pass = sg.Pass{};
    shadow_pass.action.depth = .{ .load_action = .CLEAR, .clear_value = 1.0 };
    shadow_pass.attachments.depth_stencil = state.shadow_renderer.depthAttachment();

    sg.beginPass(shadow_pass);
    state.shadow_renderer.begin(compute_light_view_proj());

    var chunk_it = state.terrain.chunks.valueIterator();
    while (chunk_it.next()) |chunk_ptr| {
        if (chunk_ptr.mesh.vertices.items.len == 0) continue;
        state.shadow_renderer.draw(&chunk_ptr.mesh, model_matrix(&chunk_ptr.mesh));
    }
    for (state.meshes.items) |*mesh| {
        state.shadow_renderer.draw(mesh, model_matrix(mesh));
    }
    if (state.building.active and state.building.mesh_segment_count > 0) {
        state.shadow_renderer.draw(&state.building.mesh, model_matrix(&state.building.mesh));
    }
    sg.endPass();

    // Main pass
    var pass = sg.Pass{ .swapchain = sglue.swapchain() };
    pass.action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1.0 },
    };
    pass.action.depth = .{ .load_action = .CLEAR, .clear_value = 1.0 };

    sg.beginPass(pass);
    const frame_params = render.FrameParams{
        .view = state.camera.viewMatrix(),
        .projection = state.camera.projectionMatrix(),
        .light = state.light,
        .shadows_enabled = state.shadows_enabled,
        .ambient_occlusion_enabled = state.ambient_occlusion_enabled,
    };
    const shadow_map = state.shadow_renderer.shadowMap();

    chunk_it = state.terrain.chunks.valueIterator();
    while (chunk_it.next()) |chunk_ptr| {
        if (chunk_ptr.mesh.vertices.items.len == 0) continue;
        state.terrain_renderer.draw(
            &chunk_ptr.mesh,
            model_matrix(&chunk_ptr.mesh),
            frame_params,
            shadow_map,
            state.wireframe,
        );
    }

    for (state.meshes.items) |*mesh| {
        state.mesh_renderer.draw(
            mesh,
            model_matrix(mesh),
            frame_params,
            shadow_map,
            state.wireframe,
        );
    }

    if (state.building.active and state.building.mesh_segment_count > 0) {
        state.mesh_renderer.draw(
            &state.building.mesh,
            model_matrix(&state.building.mesh),
            frame_params,
            shadow_map,
            state.wireframe,
        );
    }

    // Test lines
    state.shapes.line_3d(Vec3.new(0, 20, 0), Vec3.new(10, 20, 0), Vec4.new(1, 0, 0, 1), 0.2);
    state.shapes.line_3d(Vec3.new(0, 20, 0), Vec3.new(0, 30, 0), Vec4.new(0, 1, 0, 1), 0.2);
    state.shapes.line_3d(Vec3.new(0, 20, 0), Vec3.new(0, 20, 10), Vec4.new(0, 0, 1, 1), 0.2);

    if (state.show_light_rays) {
        const ray = state.camera.screen_to_ray(state.input.mouse_pos, 500.0);
        if (state.terrain.raycast(ray)) |hit| {
            const p = hit.pos;
            const x: f32 = @floatFromInt(p.x());
            const y: f32 = @floatFromInt(p.y());
            const z: f32 = @floatFromInt(p.z());
            const light_ray = state.light.dir.scale(2.0);
            const color = Vec4.new(1, 1, 0, 1);
            const top_vertices = [4]Vec3{
                Vec3.new(x, y + 1, z),
                Vec3.new(x + 1, y + 1, z),
                Vec3.new(x, y + 1, z + 1),
                Vec3.new(x + 1, y + 1, z + 1),
            };
            for (top_vertices) |v| {
                state.shapes.line_3d(v, v.add(light_ray), color, 0.05);
            }
        }
    }

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
        ig.ImGuiWindowFlags_NoBackground | ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoInputs | ig.ImGuiWindowFlags_AlwaysAutoResize,
    );
    ig.igText("%4.1f fps \t %4.1f ms", 1 / t, t * 1000);
    ig.igText("chunk remesh avg: %.3f ms", Terrain.remesh_stats.average_ms());
    ig.igText("last remesh total: %.3f ms", Terrain.remesh_stats.last_process_ms());
    if (state.building.active) {
        const mesh = &state.building.mesh;
        ig.igText(
            "%i segments, %i vertices, %i triangles, %.1f",
            state.building.mesh_segment_count,
            mesh.vertices.items.len,
            mesh.indices.items.len / 3,
            state.building.mesh_length,
        );
    }

    ig.igEnd();

    simgui.render();
    sg.endPass();
    sg.commit();

    state.input.update();

    const cpu_us = frame_timer.read() / std.time.ns_per_us;
    _ = cpu_us;
    // std.debug.print("cpu: {d:.1}us ({d:.2}ms)\n", .{ @as(f64, @floatFromInt(cpu_us)), @as(f64, @floatFromInt(cpu_us)) / 1000.0 });
}

export fn event_handler(maybe_event: [*c]const sapp.Event) void {
    const event = maybe_event.*;
    state.input.handle_event(event);

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

fn model_matrix(mesh: *const Mesh) Mat4 {
    return Mat4.fromTranslate(mesh.transform.position)
        .mul(Mat4.fromEulerAngles(Vec3.new(state.rx, state.ry, 0)));
}

fn compute_light_view_proj() Mat4 {
    const scene_center = Vec3.new(96.0, 24.0, 96.0);
    const light_dir = state.light.dir;
    const light_eye = scene_center.add(light_dir.scale(250.0));
    const light_view = Mat4.lookAt(light_eye, scene_center, Vec3.new(0.0, 1.0, 0.0));
    const light_proj = Mat4.orthographic(-150.0, 150.0, -150.0, 150.0, 0.1, 600.0);
    return light_proj.mul(light_view);
}
