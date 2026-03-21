## Camera designed to work with Planet. Handles origin shifting, dynamic clip
## planes, terrain collision, and auto-leveling — everything needed to orbit
## or walk on a large-radius planet without floating-point jitter.
##
## Place this camera as a sibling of a Planet node. Set the "planet" export
## in the inspector to point at the Planet. The camera handles the rest.
##
## This script contains NO input handling and NO _process() — it is fully
## passive. Move the camera however you like (keyboard, gamepad, scripted
## animation) from an external script, then call update(delta) each frame.
class_name PlanetCamera
extends Camera3D

## Reference to the Planet node (sibling). Set in the inspector.
@export var planet: Planet

## Minimum height above terrain surface (same units as planet radius).
@export var min_altitude: float = 0.01

## Call this once per frame AFTER moving/rotating the camera.
## Performs origin shifting, auto-leveling, clip plane adjustment, and
## triggers Planet LOD update — in the correct order, all in one call.
func update(delta: float) -> void:
	if not planet:
		push_warning("PlanetCamera: 'planet' is not set. Assign a Planet node in the inspector.")
		return
	# Origin shifting: keep PlanetCamera near world origin to prevent
	# floating-point jitter at large distances from the origin.
	var shift := global_position
	if shift.length_squared() > 1.0:
		global_position = Vector3.ZERO
		planet.global_position -= shift
	# Position relative to planet center (always from PlanetCamera, not debug)
	var rel_pos := global_position - planet.global_position
	var dist := rel_pos.length()
	# Auto-level: gradually align camera's "up" with the planet's radial direction.
	if dist > 0.001:
		_auto_level(rel_pos, dist, delta)
	# Dynamically adjust near/far clip planes based on PlanetCamera altitude.
	var surface_dist := absf(planet.get_distance_to_terrain(global_position))
	var max_far := maxf(100000.0, dist * 3.0)
	far = clampf(maxf(surface_dist * 100000.0, dist * 3.0), 1000.0, max_far)
	near = clampf(far * 0.0000001, 0.001, 10.0) # Near = far × 1e-7 for depth precision
	# Update planet LOD and shader uniforms — must happen AFTER shifting.
	planet.update(self)

## Move the camera by the given offset, optionally clamping above terrain.
## Call this instead of modifying position directly.
func move(offset: Vector3, clamp_to_terrain: bool = false) -> void:
	global_position += offset
	if clamp_to_terrain and planet:
		var altitude := planet.get_distance_to_terrain(global_position)
		if altitude < min_altitude:
			var up := (global_position - planet.global_position).normalized()
			global_position += up * (min_altitude - altitude)

## Distance from the terrain surface (always positive, works both above and
## inside the planet). Used for speed scaling and clip plane adjustment.
func get_surface_distance() -> float:
	if not planet:
		return global_position.length()
	return absf(planet.get_distance_to_terrain(global_position))

## Altitude above terrain surface (negative when inside the planet).
func get_altitude() -> float:
	if not planet:
		return global_position.length()
	return planet.get_distance_to_terrain(global_position)

func _auto_level(rel_pos: Vector3, dist: float, delta: float) -> void:
	# Fade out auto-leveling with altitude: full effect near surface, zero above atmosphere
	var altitude := dist - planet.radius
	var fade_start := planet.atmosphere_height * 0.5
	var fade_end := planet.atmosphere_height * 2.0
	var strength := 1.0 - clampf((altitude - fade_start) / (fade_end - fade_start), 0.0, 1.0)
	if strength < 0.001:
		return
	var planet_up := rel_pos / dist
	var cam_up := global_transform.basis.y
	var alignment := cam_up.dot(planet_up)
	# Only auto-level when not too inverted, blend gently
	if alignment > -0.5:
		var corrected_up := cam_up.lerp(planet_up, 1.5 * delta * strength).normalized() # Leveling speed (tuned)
		var forward := -global_transform.basis.z
		# Recompute basis from forward + corrected up
		var right := forward.cross(corrected_up).normalized()
		if right.length_squared() > 0.001:
			corrected_up = right.cross(forward).normalized()
			global_transform.basis = Basis(right, corrected_up, -forward)
