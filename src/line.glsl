@header const za = @import("zalgebra")
@ctype mat4 za.Mat4
@ctype vec4 za.Vec4
@ctype vec2 za.Vec2

@vs vs
layout(binding=0) uniform vs_params {
    mat4 view;
    mat4 proj;
};

in vec4 position;
in vec4 aUv;
in vec4 color0;

out vec4 vColor;
out vec2 uv;

void main() {
    gl_Position = proj * view  * position;
    vColor = color0;
    uv = vec2(aUv);
}
@end

@fs fs
layout(binding=1) uniform fs_params {
    float aa_width;
};

in vec4 vColor;
in vec2 uv;

out vec4 frag_color;

void main() {
	// uv.x = half-thickness (line edge distance), uv.y = perpendicular distance
    float half_t = uv.x;
    float dist = abs(uv.y);
    float alpha = 1.0 - smoothstep(half_t - aa_width, half_t, dist);

    frag_color = vec4(vColor.rgb, vColor.a * alpha);
}
@end

@program basic vs fs