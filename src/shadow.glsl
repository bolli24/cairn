@header const za = @import("zalgebra")
@ctype mat4 za.Mat4

@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
};

in vec4 position;

void main() {
    gl_Position = mvp * position;
    // Remap z from OpenGL NDC [-1,1] to D3D/Metal/WGSL NDC [0,1]
    #if !SOKOL_GLSL
    gl_Position.z = (gl_Position.z + gl_Position.w) * 0.5;
    #endif
}
@end

@fs fs
out vec4 frag_color;
void main() {
    frag_color = vec4(0.0, 0.0, 0.0, 1.0);
}
@end

@program shadow vs fs
