# cairn

Voxel and terrain engine in Zig, built on sokol. Runs natively and in the browser via WebAssembly/WebGL 2.

- Chunked voxel terrain (16³ chunks), generated with FastNoiseLite
- Block placement and a build mode for placing ranges
- Shadows and ambient occlusion
- Textures compressed to BC7 at build time
- Dear ImGui for debug UI
- Requires Zig 0.17.0

## Building

```sh
zig build run                                   # native
zig build -Dtarget=wasm32-emscripten install-emsdk
zig build -Dtarget=wasm32-emscripten run        # web, output in zig-out/web
```

Demo: https://henrikhuth.de/projects/cairn/
