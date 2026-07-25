const std = @import("std");
const sokol = @import("sokol");
const cimgui = @import("cimgui");

const tex = @import("build_textures.zig");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) !void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("voxel_zig", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    const opt_docking = b.option(bool, "docking", "Build with docking support") orelse false;

    const cimgui_conf = cimgui.getConfig(opt_docking);

    const is_nix = b.graph.environ_map.get("IN_NIX_SHELL") != null;
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .with_sokol_imgui = true,
        .with_tracing = true,
        .dynamic_linkage = is_nix,
    });
    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });
    // inject the cimgui header search path into the sokol C library compile step
    dep_sokol.artifact("sokol_clib").root_module.addIncludePath(dep_cimgui.path(cimgui_conf.include_dir));

    const dep_zalgebra = b.dependency("zalgebra", .{
        .target = target,
        .optimize = optimize,
    });

    const dep_fastnoise = b.dependency("fastnoiselite", .{
        .target = target,
        .optimize = optimize,
    });

    const dep_zigimg = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const dep_bc7enc = b.dependency("bc7enc", .{
        .target = target,
        .optimize = optimize,
    });

    const bc7enc = b.addExecutable(.{
        .name = "bc7enc",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = false,
            .link_libcpp = true,
        }),
    });
    bc7enc.root_module.addCSourceFile(.{ .file = dep_bc7enc.path("bc7enc.c") });
    bc7enc.root_module.addCSourceFile(.{ .file = dep_bc7enc.path("bc7decomp.cpp"), .flags = &.{"-std=c++17"} });
    bc7enc.root_module.addCSourceFile(.{ .file = dep_bc7enc.path("test.cpp"), .flags = &.{"-std=c++17"} });
    bc7enc.root_module.addCSourceFile(.{ .file = dep_bc7enc.path("lodepng.cpp"), .flags = &.{"-std=c++17"} });
    b.getInstallStep().dependOn(&b.addInstallArtifact(bc7enc, .{
        .dest_dir = .{ .override = .prefix },
    }).step);

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.

    var terrain_shader_module = try createShaderModule(b, dep_sokol, "src/terrain.glsl");
    terrain_shader_module.addImport("zalgebra", dep_zalgebra.module("zalgebra"));

    var mesh_shader_module = try createShaderModule(b, dep_sokol, "src/mesh.glsl");
    mesh_shader_module.addImport("zalgebra", dep_zalgebra.module("zalgebra"));

    var line_shader_module = try createShaderModule(b, dep_sokol, "src/line.glsl");
    line_shader_module.addImport("zalgebra", dep_zalgebra.module("zalgebra"));

    var shadow_shader_module = try createShaderModule(b, dep_sokol, "src/shadow.glsl");
    shadow_shader_module.addImport("zalgebra", dep_zalgebra.module("zalgebra"));

    try tex.addTextureBuildSteps(b, bc7enc, "src", "res");

    const exe = b.addExecutable(.{
        .name = "voxel_zig",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                .{
                    .name = "sokol",
                    .module = dep_sokol.module("sokol"),
                },
                .{
                    .name = cimgui_conf.module_name,
                    .module = dep_cimgui.module(cimgui_conf.module_name),
                },

                .{
                    .name = "zalgebra",
                    .module = dep_zalgebra.module("zalgebra"),
                },
                .{
                    .name = "fastnoise",
                    .module = dep_fastnoise.module("fastnoise"),
                },
                .{
                    .name = "zigimg",
                    .module = dep_zigimg.module("zigimg"),
                },
                .{
                    .name = "terrain_shader",
                    .module = terrain_shader_module,
                },
                .{
                    .name = "mesh_shader",
                    .module = mesh_shader_module,
                },
                .{
                    .name = "line_shader",
                    .module = line_shader_module,
                },
                .{
                    .name = "shadow_shader",
                    .module = shadow_shader_module,
                },
            },
        }),
    });

    const mod_options = b.addOptions();
    mod_options.addOption(bool, "docking", opt_docking);
    exe.root_module.addOptions("build_options", mod_options);

    // On NixOS, Zig's linker can't resolve transitive shared library deps
    // from static archives. Building sokol as a dynamic lib avoids this.
    // We still need to add transitive deps that Xcursor requires,
    // and install the shared lib next to the executable.
    if (is_nix) {
        exe.root_module.linkSystemLibrary("Xrender", .{});
        exe.root_module.linkSystemLibrary("Xfixes", .{});
        exe.root_module.addRPath(.{ .cwd_relative = "$ORIGIN" });
        b.getInstallStep().dependOn(&b.addInstallArtifact(dep_sokol.artifact("sokol_clib"), .{
            .dest_dir = .{ .override = .prefix },
        }).step);
    }

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .prefix },
    }).step);
    b.installDirectory(.{
        .source_dir = b.path("res"),
        .install_dir = .prefix,
        .install_subdir = "res",
    });

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path("zig-out"));
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

fn createShaderModule(b: *std.Build, dep_sokol: *std.Build.Dependency, comptime glsl_path: []const u8) !*std.Build.Module {
    const name = comptime std.fs.path.stem(glsl_path);
    const mod_sokol = dep_sokol.module("sokol");
    const dep_shdc = dep_sokol.builder.dependency("shdc", .{});
    return sokol.shdc.createModule(b, name, mod_sokol, .{
        .shdc_dep = dep_shdc,
        .input = glsl_path,
        .output = name ++ ".zig",
        .slang = .{
            .glsl410 = true,
            .glsl300es = true,
            .hlsl4 = true,
            .metal_macos = true,
            .wgsl = true,
        },
    });
}
