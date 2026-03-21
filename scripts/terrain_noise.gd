## CPU-side replica of terrain.gdshader noise.
## Used for terrain collision — computes raw noise value (0..1) for a given
## direction from planet center. Does NOT know about planet radius or
## terrain_height — those belong to Planet.
## Noise parameters are read from the shader material to stay in sync.
class_name TerrainNoise

# Cached parameters (refreshed each frame from shader material)
var continental_enabled: bool = true
var continental_large_scale: float = 0.096
var continental_medium_scale: float = 0.041
var continental_large_weight: float = 0.305
var sea_level: float = -0.123
var coast_width: float = 0.015
var mountains_enabled: bool = true
var mountain_scale: float = 1.0
var mountain_octaves: int = 3
var mountain_height: float = 0.465
var mountain_sharpness: float = 4.0
var detail_enabled: bool = true
var detail_scale: float = 10.0
var detail_octaves: int = 4
var detail_strength: float = 0.1
var micro_enabled: bool = true
var micro_scale: float = 238.372
var micro_strength: float = 0.0011

## Compute terrain noise value (0..1) for a given direction from planet center.
## Accepts any vector — only the direction matters (it will be normalized).
## Internally maps to a radius-100 sphere where the noise is tuned.
func compute_noise(direction: Vector3) -> float:
	var pos := direction.normalized() * 100.0 # Fixed radius — noise was tuned at this scale
	# Layer 1: Continental shapes
	var continental := 0.0
	if continental_enabled:
		var large := _noise3d(pos * continental_large_scale)
		# + Vector3(...) offsets decorrelate noise samples from each other
		var medium := _noise3d(pos * continental_medium_scale + Vector3(31.7, 47.3, 19.1))
		continental = large * continental_large_weight + medium * (1.0 - continental_large_weight)
	var ocean_floor := 0.05
	var land_mask := smoothstep(-coast_width, coast_width, continental - sea_level)
	var ocean_depth := smoothstep(-0.5, -sea_level, continental) * ocean_floor
	var inland_factor := clampf((continental - sea_level) * 3.0, 0.0, 1.0)
	# Layer 2: Mountains
	var mountains := 0.0
	if mountains_enabled:
		mountains = _ridged_noise(pos * mountain_scale + Vector3(50.0, 30.0, 70.0), mountain_octaves)
		mountains = pow(mountains, mountain_sharpness)
	# Layer 3: Detail
	var detail := 0.0
	if detail_enabled:
		detail = _fbm(pos * detail_scale + Vector3(100.0, 200.0, 300.0), detail_octaves)
	# Layer 4: Micro — single noise call, tiny bumps
	var micro := 0.0
	if micro_enabled:
		micro = _noise3d(pos * micro_scale + Vector3(77.7, 55.5, 33.3))
	# Land height: normalize to ocean_floor..1.0
	var raw_land_elevation := inland_factor * 0.15 \
		+ mountains * mountain_height * inland_factor \
		+ detail * detail_strength \
		+ micro * micro_strength
	var max_land_elevation := 0.15 + mountain_height + detail_strength + micro_strength
	var land_height := ocean_floor + (raw_land_elevation / max_land_elevation) * (1.0 - ocean_floor)
	# Combine
	var result := lerpf(ocean_depth, land_height, land_mask)
	return clampf(result, 0.0, 1.0)

## Sync noise parameters from shader material.
## Only reads noise-specific uniforms — radius and terrain_height are Planet's job.
func sync_from_material(mat: ShaderMaterial) -> void:
	continental_enabled = mat.get_shader_parameter("continental_enabled")
	continental_large_scale = mat.get_shader_parameter("continental_large_scale")
	continental_medium_scale = mat.get_shader_parameter("continental_medium_scale")
	continental_large_weight = mat.get_shader_parameter("continental_large_weight")
	sea_level = mat.get_shader_parameter("sea_level")
	coast_width = mat.get_shader_parameter("coast_width")
	mountains_enabled = mat.get_shader_parameter("mountains_enabled")
	mountain_scale = mat.get_shader_parameter("mountain_scale")
	mountain_octaves = mat.get_shader_parameter("mountain_octaves")
	mountain_height = mat.get_shader_parameter("mountain_height")
	mountain_sharpness = mat.get_shader_parameter("mountain_sharpness")
	detail_enabled = mat.get_shader_parameter("detail_enabled")
	detail_scale = mat.get_shader_parameter("detail_scale")
	detail_octaves = mat.get_shader_parameter("detail_octaves")
	detail_strength = mat.get_shader_parameter("detail_strength")
	micro_enabled = mat.get_shader_parameter("micro_enabled")
	micro_scale = mat.get_shader_parameter("micro_scale")
	micro_strength = mat.get_shader_parameter("micro_strength")

# ==========================================================================
#  Noise functions — exact replica of terrain.gdshader
# ==========================================================================

## Integer hash — must match shader's ihash() exactly.
## Uses 32-bit unsigned arithmetic (wrapping) to stay deterministic.
static func _ihash(n: int) -> int:
	# Work in 32-bit unsigned space
	n = n & 0xFFFFFFFF
	n = ((n << 13) ^ n) & 0xFFFFFFFF
	n = (n * ((n * n * 15731 + 789221) & 0xFFFFFFFF) + 1376312589) & 0xFFFFFFFF
	return n

## floatBitsToUint equivalent — reinterpret float32 bits as uint32.
static func _float_bits_to_uint(v: float) -> int:
	var buf := PackedByteArray()
	buf.resize(4)
	buf.encode_float(0, v)
	return buf.decode_u32(0)

## Truncate double to float32 to match GLSL precision.
static func _to_f32(v: float) -> float:
	var buf := PackedByteArray()
	buf.resize(4)
	buf.encode_float(0, v)
	return buf.decode_float(0)

func _hash3(p: Vector3) -> Vector3:
	# Truncate to float32 to match GLSL float precision
	var ipx := _float_bits_to_uint(_to_f32(p.x))
	var ipy := _float_bits_to_uint(_to_f32(p.y))
	var ipz := _float_bits_to_uint(_to_f32(p.z))
	# Chain hashes — identical to shader
	var hx := _ihash(ipx + _ihash(ipy + _ihash(ipz)))
	var hy := _ihash(hx + 1)
	var hz := _ihash(hx + 2)
	# Map to [-1, 1] — divide by 2^31 - 1, same as shader
	return Vector3(
		float(hx) / 2147483647.0 - 1.0,
		float(hy) / 2147483647.0 - 1.0,
		float(hz) / 2147483647.0 - 1.0
	)

func _noise3d(p: Vector3) -> float:
	# Truncate to float32 to match GLSL precision throughout
	p = Vector3(_to_f32(p.x), _to_f32(p.y), _to_f32(p.z))
	var i := Vector3(floor(p.x), floor(p.y), floor(p.z))
	var f := Vector3(p.x - i.x, p.y - i.y, p.z - i.z)
	# Smoothstep: u = f * f * (3 - 2*f)
	var u := Vector3(
		f.x * f.x * (3.0 - 2.0 * f.x),
		f.y * f.y * (3.0 - 2.0 * f.y),
		f.z * f.z * (3.0 - 2.0 * f.z)
	)
	var c000 := _hash3(i).dot(f)
	var c100 := _hash3(i + Vector3(1,0,0)).dot(f - Vector3(1,0,0))
	var c010 := _hash3(i + Vector3(0,1,0)).dot(f - Vector3(0,1,0))
	var c110 := _hash3(i + Vector3(1,1,0)).dot(f - Vector3(1,1,0))
	var c001 := _hash3(i + Vector3(0,0,1)).dot(f - Vector3(0,0,1))
	var c101 := _hash3(i + Vector3(1,0,1)).dot(f - Vector3(1,0,1))
	var c011 := _hash3(i + Vector3(0,1,1)).dot(f - Vector3(0,1,1))
	var c111 := _hash3(i + Vector3(1,1,1)).dot(f - Vector3(1,1,1))
	return lerpf(
		lerpf(lerpf(c000, c100, u.x), lerpf(c010, c110, u.x), u.y),
		lerpf(lerpf(c001, c101, u.x), lerpf(c011, c111, u.x), u.y),
		u.z
	)

func _fbm(p: Vector3, octaves: int) -> float:
	var value := 0.0
	var amp := 1.0
	var freq := 1.0
	var max_amp := 0.0
	for _octave in range(octaves):
		value += amp * _noise3d(p * freq)
		max_amp += amp
		freq *= 2.0
		amp *= 0.5
	return value / max_amp

func _ridged_noise(p: Vector3, octaves: int) -> float:
	var value := 0.0
	var amp := 1.0
	var freq := 1.0
	var max_amp := 0.0
	for _octave in range(octaves):
		var n := 1.0 - absf(_noise3d(p * freq)) # Invert abs(noise) to create ridges
		value += amp * n
		max_amp += amp
		freq *= 2.0
		amp *= 0.5
	return value / max_amp
