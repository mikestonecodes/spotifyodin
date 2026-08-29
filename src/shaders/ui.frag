#version 450
#extension GL_EXT_nonuniform_qualifier : require

// The bindless table: every texture the UI can ever draw lives here, so the
// whole frame is one descriptor set bound once and (usually) one draw call.
// Slot 0 is the font atlas, slot 1 is a 1x1 white pixel, the rest is art.
layout(set = 0, binding = 0) uniform sampler2D textures[];

layout(push_constant) uniform Push {
	vec2  inv_screen;
	float time;
} pc;

layout(location = 0)      in vec2  v_uv;
layout(location = 1)      in vec4  v_col;
layout(location = 2) flat in uint  v_tex;
layout(location = 3)      in vec2  v_pos;
layout(location = 4) flat in vec4  v_rect;
layout(location = 5) flat in float v_radius;
layout(location = 6) flat in uint  v_effect;
layout(location = 7) flat in float v_param;

layout(location = 0) out vec4 out_col;

#define EFFECT_NONE     0u
#define EFFECT_GLOW     1u // soft radial falloff, for the halo behind a button
#define EFFECT_SHEEN    2u // a highlight that travels along the progress fill
#define EFFECT_RING     3u // a ring that fades outward, for click ripples

// Signed distance to a box with rounded corners, in pixels.
float rounded_box(vec2 p, vec2 half_extent, float r) {
	vec2 q = abs(p) - half_extent + r;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
	vec4 c = v_col * texture(textures[nonuniformEXT(v_tex)], v_uv);

	// Position within the quad, -1..1 on each axis.
	vec2 p = (v_pos - v_rect.xy) / max(v_rect.zw, vec2(0.0001));

	if (v_effect == EFFECT_GLOW) {
		// Quadratic falloff reads as light rather than as a blurred circle.
		// Deliberately not time-varying: a static glow costs nothing to leave
		// on screen, because the frame does not need redrawing to hold it.
		float d = length(p);
		c.a *= pow(clamp(1.0 - d, 0.0, 1.0), 2.5);
	} else if (v_effect == EFFECT_SHEEN) {
		// A band that sweeps left to right across the filled part.
		float x = p.x * 0.5 + 0.5;
		float head = fract(pc.time * 0.30) * 1.7 - 0.35;
		float band = exp(-pow((x - head) * 5.0, 2.0));
		c.rgb += band * 0.45;
	} else if (v_effect == EFFECT_RING) {
		// Thin annulus at the quad's edge, fading as it expands.
		float d = length(p);
		float ring = smoothstep(0.55, 1.0, d) * (1.0 - smoothstep(1.0, 1.06, d));
		c.a *= ring;
	}

	if (v_radius >= 0.0) {
		float d = rounded_box(v_pos - v_rect.xy, v_rect.zw, v_radius);
		c.a *= 1.0 - smoothstep(-0.7, 0.7, d);
	}

	if (c.a <= 0.0) discard;
	out_col = c;
}
