@header const za = @import("zalgebra")
@ctype mat4 za.Mat4
@ctype vec4 za.Vec4

@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
};

in vec4 position;

void main() {
    gl_Position = mvp * position;
}
@end

@fs fs
layout(binding=1) uniform fs_params {
    vec4 color;
};

out vec4 frag_color;

void main() {
    frag_color = color;
}
@end

@program cube vs fs