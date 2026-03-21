// Atmospheric scattering shader based on Sean O'Neil's technique (GPU Gems 2, 2004).
// Renders Rayleigh + Mie single-scattering on a transparent sphere around the planet.
// All scattering is computed per-pixel (in the fragment shader) for artifact-free results.
//
// Original: Sean O'Neil, Copyright (c) 2004
// Adapted for Godot 4.x by Cuberact.

shader_type spatial;
render_mode blend_mix, unshaded, depth_draw_never, cull_front;

// --- Scattering parameters (tune these in the inspector for visual quality) ---
group_uniforms scattering;
uniform float kr : hint_range(0.0, 0.01) = 0.0035;          // Rayleigh scattering coefficient
uniform float km : hint_range(0.0, 0.01) = 0.001;           // Mie scattering coefficient
uniform float sun_intensity : hint_range(0.0, 50.0) = 20.0; // Sun brightness
uniform float g : hint_range(-1.0, 0.0) = -0.95;            // Mie phase asymmetry (negative = forward scattering)
uniform float scale_depth : hint_range(0.0, 1.0) = 0.25;    // Altitude fraction of average density
uniform int num_samples : hint_range(1, 8) = 4;             // Ray march steps (more = better but slower)
uniform float wavelength_r : hint_range(0.3, 1.0) = 0.650;   // Red wavelength in micrometers
uniform float wavelength_g : hint_range(0.3, 1.0) = 0.570;   // Green wavelength in micrometers
uniform float wavelength_b : hint_range(0.3, 1.0) = 0.475;   // Blue wavelength in micrometers

// --- Managed by Planet node — changes here are overwritten every frame ---
group_uniforms runtime;
uniform vec3 camera_pos;          // Camera position in planet-local space
uniform vec3 sun_direction;       // Normalized direction toward the sun
uniform float camera_height;      // Distance from camera to planet center
uniform float inner_radius;       // Planet surface radius (km)
uniform float outer_radius;       // Atmosphere edge radius (km)
uniform float atm_scale;          // 1.0 / (outer_radius - inner_radius)

// Pass vertex world position to fragment shader
varying vec3 vertex_pos;

// Polynomial approximation of the Chapman function for optical depth.
// From O'Neil's original implementation.
float scale_func(float cos_angle, float sd) {
	float x = 1.0 - cos_angle;
	return sd * exp(-0.00287 + x * (0.459 + x * (3.83 + x * (-6.80 + x * 5.25))));
}

void vertex() {
	vertex_pos = VERTEX;
}

void fragment() {
	// Ray from camera to this pixel's position on the atmosphere sphere
	vec3 pos = vertex_pos;
	vec3 ray = pos - camera_pos;
	float far_dist = length(ray);
	ray /= far_dist;

	// Precompute scattering constants
	vec3 wl = vec3(wavelength_r, wavelength_g, wavelength_b);
	vec3 inv_wavelength4 = 1.0 / (wl * wl * wl * wl);
	float kr_sun = kr * sun_intensity;
	float km_sun = km * sun_intensity;
	float kr_4pi = kr * 4.0 * PI;
	float km_4pi = km * 4.0 * PI;
	float scale_over_depth = atm_scale / scale_depth;

	// Find ray-atmosphere intersection. When camera is outside, near_dist > 0
	// and the ray starts at the atmosphere boundary. When camera is inside,
	// near_dist <= 0 so we clamp to 0 and start at the camera position.
	float B = 2.0 * dot(camera_pos, ray);
	float C = camera_height * camera_height - outer_radius * outer_radius;
	float det = max(0.0, B * B - 4.0 * C);
	float near_dist = max(0.0, 0.5 * (-B - sqrt(det)));
	vec3 start_pos = camera_pos + ray * near_dist;
	far_dist -= near_dist;

	float start_height = length(start_pos);
	float start_angle = dot(ray, start_pos) / start_height;
	float start_depth = exp(scale_over_depth * (inner_radius - start_height));
	float start_offset = start_depth * scale_func(start_angle, scale_depth);

	// Ray march through the atmosphere
	float sample_length = far_dist / float(num_samples);
	float scaled_length = sample_length * atm_scale;
	vec3 sample_ray = ray * sample_length;
	vec3 sample_point = start_pos + sample_ray * 0.5;

	vec3 front_color = vec3(0.0);
	for (int i = 0; i < num_samples; i++) {
		float h = length(sample_point);
		float d = exp(scale_over_depth * (inner_radius - h));
		float light_angle = dot(sun_direction, sample_point) / h;
		float camera_angle = dot(ray, sample_point) / h;
		float scatter = start_offset + d * (scale_func(light_angle, scale_depth) - scale_func(camera_angle, scale_depth));
		vec3 attenuate = exp(-scatter * (inv_wavelength4 * kr_4pi + km_4pi));
		front_color += attenuate * (d * scaled_length);
		sample_point += sample_ray;
	}

	// Rayleigh and Mie colors
	vec3 rayleigh_color = front_color * (inv_wavelength4 * kr_sun);
	vec3 mie_color = front_color * km_sun;

	// Phase functions
	float cos_angle = dot(sun_direction, normalize(camera_pos - pos));

	// Rayleigh phase function: 3/4 * (1 + cos²θ)
	float rayleigh_phase = 0.75 * (1.0 + cos_angle * cos_angle);

	// Henyey-Greenstein Mie phase function
	float g2 = g * g;
	float mie_phase = 1.5 * ((1.0 - g2) / (2.0 + g2))
		* (1.0 + cos_angle * cos_angle)
		/ pow(1.0 + g2 - 2.0 * g * cos_angle, 1.5);

	ALBEDO = rayleigh_phase * rayleigh_color + mie_phase * mie_color;
	// Alpha from scattering intensity — strong scattering hides stars behind the sky
	ALPHA = clamp(max(ALBEDO.r, max(ALBEDO.g, ALBEDO.b)) * 5.0, 0.0, 1.0);
}
