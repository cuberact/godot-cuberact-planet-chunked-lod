// Shader-only terrain for chunked LOD planet.
// Vertex shader displaces flat-sphere mesh using procedural noise.
// Fragment shader computes per-pixel elevation color and lighting from the same noise.
// We handle lighting ourselves (Lambert diffuse) instead of delegating to Godot's PBR.
shader_type spatial;
render_mode unshaded, cull_back;

group_uniforms lighting;
uniform bool compute_normals = true;
uniform float ambient_light : hint_range(0.0, 0.1) = 0.004;
uniform float shadow_strength : hint_range(0.5, 8.0) = 3.0;

group_uniforms continental;
uniform bool continental_enabled = true;
uniform float continental_large_scale : hint_range(0.01, 0.2) = 0.096;
uniform float continental_medium_scale : hint_range(0.01, 0.2) = 0.041;
uniform float continental_large_weight : hint_range(0.0, 1.0) = 0.305;
uniform float sea_level : hint_range(-0.5, 0.5) = -0.123;
uniform float coast_width : hint_range(0.005, 0.1) = 0.015;

group_uniforms mountains;
uniform bool mountains_enabled = true;
uniform float mountain_scale : hint_range(0.05, 3.0) = 1.0;
uniform int mountain_octaves : hint_range(0, 10) = 3;
uniform float mountain_height : hint_range(0.0, 2.0) = 0.465;
uniform float mountain_sharpness : hint_range(0.5, 20.0) = 4.0;

group_uniforms detail;
uniform bool detail_enabled = true;
uniform float detail_scale : hint_range(0.5, 30.0) = 10.0;
uniform int detail_octaves : hint_range(0, 10) = 4;
uniform float detail_strength : hint_range(0.0, 0.3) = 0.1;

group_uniforms micro;
uniform bool micro_enabled = true;
uniform float micro_scale : hint_range(5.0, 500.0) = 238.372;
uniform float micro_strength : hint_range(0.0001, 0.01) = 0.0011;

group_uniforms colors;
// Defaults are sRGB values that produce the original linear colors after conversion.
uniform vec3 color_deep_ocean : source_color = vec3(0.15, 0.25, 0.54);
uniform vec3 color_ocean : source_color = vec3(0.31, 0.46, 0.74);
uniform vec3 color_shallow_water : source_color = vec3(0.42, 0.70, 0.88);
uniform vec3 color_beach : source_color = vec3(0.87, 0.83, 0.65);
uniform vec3 color_lowland : source_color = vec3(0.58, 0.80, 0.42);
uniform vec3 color_highland : source_color = vec3(0.42, 0.63, 0.31);
uniform vec3 color_rock : source_color = vec3(0.70, 0.60, 0.46);
uniform vec3 color_high_rock : source_color = vec3(0.74, 0.68, 0.60);
uniform vec3 color_snow_line : source_color = vec3(0.88, 0.88, 0.90);
uniform vec3 color_snow_peak : source_color = vec3(0.92, 0.92, 0.92);

group_uniforms textures;
uniform bool textures_enabled = true;
uniform float texture_scale : hint_range(0.1, 100.0) = 10.0;
uniform float slope_threshold : hint_range(0.0, 1.0) = 0.6;
uniform float slope_blend : hint_range(0.01, 1.0) = 0.5;
uniform float texture_near : hint_range(0.0, 50.0) = 1.0;
uniform float texture_far : hint_range(1.0, 100.0) = 10.0;
uniform sampler2D tex_sand : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_grass : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_ground : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_gravel : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_snow : source_color, filter_linear_mipmap, repeat_enable;

// --- Managed by Planet node — changes here are overwritten every frame ---
group_uniforms runtime;
uniform float planet_radius;
uniform float terrain_height;
uniform vec3 planet_origin;
uniform vec3 sun_direction;

// Noise coordinate scale: maps planet_radius to ~100 units for noise input.
// Computed automatically, no manual tuning needed when radius changes.

// normal_eps is passed per-vertex via UV2.x (vertex spacing in noise space).
// This avoids instance uniforms which don't work reliably on WebGL.

varying vec3 sphere_pos;        // position on ideal sphere (noise coordinates, before displacement)
varying float real_elevation;   // actual height above ideal sphere, normalized 0..1
varying vec3 vertex_normal;     // surface normal computed in vertex shader
varying float vertex_slope;     // slope: 0 = flat, 1 = vertical cliff
varying vec3 world_position;    // world-space position for point light direction

// ==========================================================================
//  Procedural noise
// ==========================================================================

// Integer-based hash — deterministic across GPU (32-bit) and CPU (64-bit).
// No sin() dependency, results are identical on both platforms.
uint ihash(uint n) {
	n = (n << 13u) ^ n;
	n = n * (n * n * 15731u + 789221u) + 1376312589u;
	return n;
}

vec3 hash3(vec3 p) {
	uvec3 ip = uvec3(floatBitsToUint(p.x), floatBitsToUint(p.y), floatBitsToUint(p.z));
	uint hx = ihash(ip.x + ihash(ip.y + ihash(ip.z)));
	uint hy = ihash(hx + 1u);
	uint hz = ihash(hx + 2u);
	// Map to [-1, 1]
	return vec3(
		float(hx) / 2147483647.0 - 1.0,
		float(hy) / 2147483647.0 - 1.0,
		float(hz) / 2147483647.0 - 1.0
	);
}

// Gradient noise (Perlin-like) — much better contrast than value noise
float noise3d(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);

	return mix(mix(mix(dot(hash3(i + vec3(0,0,0)), f - vec3(0,0,0)),
					   dot(hash3(i + vec3(1,0,0)), f - vec3(1,0,0)), u.x),
				   mix(dot(hash3(i + vec3(0,1,0)), f - vec3(0,1,0)),
					   dot(hash3(i + vec3(1,1,0)), f - vec3(1,1,0)), u.x), u.y),
			   mix(mix(dot(hash3(i + vec3(0,0,1)), f - vec3(0,0,1)),
					   dot(hash3(i + vec3(1,0,1)), f - vec3(1,0,1)), u.x),
				   mix(dot(hash3(i + vec3(0,1,1)), f - vec3(0,1,1)),
					   dot(hash3(i + vec3(1,1,1)), f - vec3(1,1,1)), u.x), u.y), u.z);
}

// FBM using gradient noise. Returns approximately [-1, 1].
float fbm(vec3 p, int octaves) {
	float value = 0.0;
	float amp = 1.0;
	float freq = 1.0;
	float max_amp = 0.0;
	for (int i = 0; i < octaves; i++) {
		value += amp * noise3d(p * freq);
		max_amp += amp;
		freq *= 2.0;
		amp *= 0.5;
	}
	return value / max_amp; // normalize to [-1, 1]
}

// Ridged noise. Returns [0, 1].
float ridged_noise(vec3 p, int octaves) {
	float value = 0.0;
	float amp = 1.0;
	float freq = 1.0;
	float max_amp = 0.0;
	for (int i = 0; i < octaves; i++) {
		float n = 1.0 - abs(noise3d(p * freq)); // ridge fold
		value += amp * n;
		max_amp += amp;
		freq *= 2.0;
		amp *= 0.5;
	}
	return value / max_amp; // normalize to [0, 1]
}

// Compute noise for a point in planet-local space. Returns [0, 1].
// Four layers: continents (land/ocean), mountains (ridged, land only), fine detail, and micro bumps.
float compute_noise(vec3 pos) {
	// Layer 1: Continental shapes
	float continental = 0.0;
	if (continental_enabled) {
		float large = noise3d(pos * continental_large_scale);
		float medium = noise3d(pos * continental_medium_scale + vec3(31.7, 47.3, 19.1));
		continental = large * continental_large_weight + medium * (1.0 - continental_large_weight);
	}

	float sea_n = 0.05;
	float land_mask = smoothstep(-coast_width, coast_width, continental - sea_level);
	float ocean_depth = smoothstep(-0.5, -sea_level, continental) * sea_n;
	float coast_dist = clamp((continental - sea_level) * 3.0, 0.0, 1.0);

	// Layer 2: Mountains — ridged noise, only inland
	float mountains = 0.0;
	if (mountains_enabled) {
		mountains = ridged_noise(pos * mountain_scale + vec3(50.0, 30.0, 70.0), mountain_octaves);
		mountains = pow(mountains, mountain_sharpness);
	}

	// Layer 3: Detail — small hills and bumps
	float detail = 0.0;
	if (detail_enabled) {
		detail = fbm(pos * detail_scale + vec3(100.0, 200.0, 300.0), detail_octaves);
	}

	// Layer 4: Micro — single noise call, tiny bumps and dips
	float micro = 0.0;
	if (micro_enabled) {
		micro = noise3d(pos * micro_scale + vec3(77.7, 55.5, 33.3));
	}

	// Land height: build relative shape, normalize to sea_n..1.0
	float land_shape = coast_dist * 0.15
		+ mountains * mountain_height * coast_dist
		+ detail * detail_strength
		+ micro * micro_strength;
	float max_land = 0.15 + mountain_height + detail_strength + micro_strength;
	float land_height = sea_n + (land_shape / max_land) * (1.0 - sea_n);

	// Combine
	float result = mix(ocean_depth, land_height, land_mask);

	return clamp(result, 0.0, 1.0);
}


// ==========================================================================
//  Vertex shader — displace flat sphere mesh
// ==========================================================================

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float noise_coeff = 100.0 / planet_radius;
	sphere_pos = (world_pos - planet_origin) * noise_coeff;

	// Displace vertex along sphere normal
	vec3 up = normalize(sphere_pos);
	float n = compute_noise(sphere_pos);
	VERTEX += up * (n * terrain_height);

	// Compute real elevation: distance from planet center after displacement, normalized
	vec3 displaced_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float dist_from_center = length(displaced_world - planet_origin);
	real_elevation = clamp((dist_from_center - planet_radius) / terrain_height, 0.0, 1.0);
	world_position = displaced_world;


	// Compute surface normal via tangent-space gradient
	if (compute_normals) {
		vec3 ref = abs(up.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		vec3 t1 = normalize(cross(up, ref));
		vec3 t2 = cross(up, t1);

		float eps = UV2.x;
		float h1 = compute_noise(sphere_pos + t1 * eps);
		float h2 = compute_noise(sphere_pos + t2 * eps);

		float dn1 = (h1 - n) / eps;
		float dn2 = (h2 - n) / eps;

		// noise_coeff already defined above — reuse it for slope scaling
		float slope_scale = terrain_height * noise_coeff;
		vertex_normal = normalize(up - (t1 * dn1 + t2 * dn2) * slope_scale);
	} else {
		vertex_normal = up;
	}

	// Slope: 0 = flat (normal aligned with up), 1 = vertical cliff
	vertex_slope = 1.0 - abs(dot(normalize(vertex_normal), up));
}

// ==========================================================================
//  Fragment shader — per-pixel color from elevation
// ==========================================================================

// Elevation color palette — maps noise value (= real elevation) to terrain color.
// 0.0 = deepest ocean floor (on ideal sphere), 1.0 = highest peak (terrain_height above sphere).
// Sea level at ~0.05. Colors represent actual elevation, no faking.
// Colors are configurable via the "colors" uniform group above.
// Duplicate entries (same color at two heights) create flat-color zones.

// Heights where each band starts. Sea level = 0.05, land uses 0.05..1.0 range.
const float BAND_HEIGHTS[14] = {
	0.00, 0.02, 0.04,          // ocean bands (0..0.05)
	0.05, 0.07,                // beach (just above sea level)
	0.09, 0.15,                // lowland grass
	0.18, 0.28,                // highland grass
	0.35, 0.50, 0.65,          // rock
	0.80, 1.00                 // snow
};

// Look up terrain color from normalized elevation (0..1).
// Linearly interpolates between the two nearest bands.
// Colors come from uniforms; duplicate entries create flat-color zones.
vec3 elevation_color(float elev) {
	vec3 colors[14] = {
		color_deep_ocean,
		color_ocean,
		color_shallow_water,
		color_beach, color_beach,
		color_lowland, color_lowland,
		color_highland, color_highland,
		color_rock,
		color_high_rock, color_high_rock,
		color_snow_line,
		color_snow_peak
	};
	elev = clamp(elev, 0.0, 1.0);

	// Find which band we're in
	for (int i = 0; i < 13; i++) {
		if (elev < BAND_HEIGHTS[i + 1]) {
			// Interpolate between band i and band i+1
			float t = (elev - BAND_HEIGHTS[i]) / (BAND_HEIGHTS[i + 1] - BAND_HEIGHTS[i]);
			return mix(colors[i], colors[i + 1], t);
		}
	}
	return colors[13]; // snow peak
}

// Triplanar texture sampling — projects texture from 3 axes using sphere-local coordinates.
vec3 triplanar(sampler2D tex, vec3 pos, vec3 normal) {
	vec3 blend = abs(normal);
	blend = pow(blend, vec3(4.0)); // sharpen blending to reduce stretching
	blend /= (blend.x + blend.y + blend.z);

	vec2 uv_x = pos.yz * texture_scale;
	vec2 uv_y = pos.xz * texture_scale;
	vec2 uv_z = pos.xy * texture_scale;

	vec3 sx = texture(tex, uv_x).rgb;
	vec3 sy = texture(tex, uv_y).rgb;
	vec3 sz = texture(tex, uv_z).rgb;

	return sx * blend.x + sy * blend.y + sz * blend.z;
}

void fragment() {
	// Per-pixel color from noise (sharp biome boundaries even on coarse LOD)
	float elev = compute_noise(sphere_pos);
	vec3 base_color = elevation_color(elev);

	if (textures_enabled) {
		vec3 norm = normalize(vertex_normal);
		float slope = vertex_slope;

		// Sample textures via triplanar using world_position (small values near camera
		// thanks to origin shifting — gives precise UVs and correct mipmap selection)
		vec3 c_sand = triplanar(tex_sand, world_position, norm);
		vec3 c_grass = triplanar(tex_grass, world_position, norm);
		vec3 c_ground = triplanar(tex_ground, world_position, norm);
		vec3 c_gravel = triplanar(tex_gravel, world_position, norm);
		vec3 c_snow = triplanar(tex_snow, world_position, norm);

		// Splatting weights based on elevation (sea_n = 0.05 boundary)
		float sea_n = 0.05;
		float land_elev = clamp((elev - sea_n) / (1.0 - sea_n), 0.0, 1.0); // 0 = coast, 1 = peak

		// Elevation-based blending
		float w_sand = smoothstep(0.05, 0.0, land_elev);        // coast only
		float w_grass = smoothstep(0.0, 0.05, land_elev) * smoothstep(0.4, 0.25, land_elev);
		float w_ground = smoothstep(0.2, 0.4, land_elev) * smoothstep(0.75, 0.55, land_elev);
		float w_snow = smoothstep(0.65, 0.85, land_elev);
		float w_gravel = smoothstep(slope_threshold - slope_blend, slope_threshold + slope_blend, slope);

		// Gravel overrides on steep slopes
		float flat_total = w_sand + w_grass + w_ground + w_snow + 0.001;
		vec3 flat_color = (c_sand * w_sand + c_grass * w_grass + c_ground * w_ground + c_snow * w_snow) / flat_total;

		vec3 terrain_color = mix(flat_color, c_gravel, w_gravel);

		// Distance-based blend: textures close up, elevation color far away
		float dist = length(VERTEX); // distance from camera in view space
		float tex_blend = 1.0 - smoothstep(texture_near, texture_far, dist);

		// Ocean stays as elevation color (no texture)
		float is_land = smoothstep(0.04, 0.06, elev);
		base_color = mix(base_color, terrain_color, is_land * tex_blend);
	}

	// Directional light — parallel rays, like the real sun
	if (compute_normals) {
		vec3 n = normalize(vertex_normal);
		vec3 light_dir = normalize(sun_direction);
		// Hemisphere test: if this point on the planet faces away from light,
		// no direct illumination regardless of surface normal (planet self-shadow)
		vec3 planet_up = normalize(sphere_pos);
		float hemisphere = max(dot(planet_up, light_dir), 0.0);
		float diffuse = pow(max(dot(n, light_dir), 0.0), shadow_strength) * hemisphere;
		base_color *= ambient_light + (1.0 - ambient_light) * diffuse;
	}

	ALBEDO = base_color;
}
