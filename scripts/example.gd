## Example controller for the planet demo. Creates the HUD, handles flight
## controls (WASD + mouse), and provides a debug observer mode (Tab key).
##
## This script is NOT required for PlanetCamera + Planet to work. Delete it
## and write your own controls — just move PlanetCamera from your script and
## it handles origin shifting, terrain collision, and clip planes on its own.
class_name Example
extends Node

# ===========================================================================
#  HUD colors
# ===========================================================================

const COLOR_LABEL := Color(0.65, 0.65, 0.7)
const COLOR_BG := Color(0.1, 0.1, 0.15)
const COLOR_ON := Color(0.35, 0.75, 0.35)
const COLOR_OFF := Color(0.45, 0.45, 0.5)

# ===========================================================================
#  References (auto-discovered in _ready)
# ===========================================================================

var planet_camera: PlanetCamera
var planet: Planet

# ===========================================================================
#  Flight controls state
# ===========================================================================

var speed: float = 50.0
var speed_multiplier: float = 1.0
var mouse_sensitivity: float = 0.003
var mouse_captured: bool = false

# ===========================================================================
#  Sun (visual decoration + orbiting light direction)
# ===========================================================================

var _sun_mesh: MeshInstance3D
var _sun_angle: float = PI * 0.5 + deg_to_rad(30.0)
var _sun_target_offset: float = 0.0  # accumulated manual offset, lerped into _sun_angle
var _sun_start_angle: float = PI * 0.5 + deg_to_rad(30.0)
var sun_orbit_period: float = 1200.0
var sun_distance: float = 20000.0
var _world_env: WorldEnvironment
var sun_radius: float = 200.0

# ===========================================================================
#  Debug observer mode
# ===========================================================================

var debug_mode: bool = false
var _debug_camera: Camera3D
var _frustum_mesh: MeshInstance3D
var _initial_rel_pos: Vector3
var _initial_basis: Basis

# ===========================================================================
#  HUD references
# ===========================================================================

var _hud_layer: CanvasLayer
var _hud_panel: PanelContainer
var _body: GridContainer
var _toggle_btn: Button
var _sep: HSeparator
var _fps_value: Label
var _chunks_value: Label
var _altitude_value: Label
var _speed_label: Label
var _wireframe_btn: Button
var _vsync_btn: Button
var _culling_btn: Button
var _collision_btn: Button
var _shader_btn: Button
var _lights_btn: Button
var _atmosphere_btn: Button
var _debug_btn: Button
var _hint_panel: PanelContainer
var _controls_overlay: ColorRect

var _collapsed: bool = false
var _controls_visible: bool = false
var _wireframe_on: bool = false
var _vsync_on: bool = true
var _culling_on: bool = true
var _collision_on: bool = true
var _shader_on: bool = true
var _lights_on: bool = true
var _atmosphere_on: bool = true
var _time_label: Label


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	mouse_captured = false
	# Find PlanetCamera, Planet and WorldEnvironment among siblings
	for sibling in get_parent().get_children():
		if sibling is PlanetCamera:
			planet_camera = sibling
		elif sibling is Planet:
			planet = sibling
		elif sibling is WorldEnvironment:
			_world_env = sibling
	if planet_camera and planet:
		_setup_start_view()
		_initial_rel_pos = planet_camera.global_position - planet.global_position
		_initial_basis = planet_camera.global_transform.basis
	_create_sun()
	_create_hud()


# ===========================================================================
#  Input handling
# ===========================================================================

func _unhandled_input(event: InputEvent) -> void:
	# ESC closes help overlay first, otherwise toggles mouse capture
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _controls_visible:
			_toggle_controls_overlay()
		else:
			mouse_captured = not mouse_captured
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mouse_captured else Input.MOUSE_MODE_VISIBLE
		return

	# Click to capture mouse
	if not mouse_captured and event is InputEventMouseButton and event.pressed:
		mouse_captured = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	# Scroll wheel adjusts speed multiplier
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed_multiplier = minf(speed_multiplier * 1.3, 10.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed_multiplier = maxf(speed_multiplier / 1.3, 0.1)

	# Mouse look (pitch + yaw in local space)
	if event is InputEventMouseMotion and mouse_captured:
		if planet_camera:
			var mm := event as InputEventMouseMotion
			var target: Camera3D = _debug_camera if debug_mode else planet_camera
			target.rotate_object_local(Vector3.UP, -mm.relative.x * mouse_sensitivity)
			target.rotate_object_local(Vector3.RIGHT, -mm.relative.y * mouse_sensitivity)

	# Keyboard shortcuts
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F12:
				_toggle_controls_overlay()
			KEY_H:
				_reset_camera()
			KEY_TAB:
				_toggle_debug_mode()
			KEY_V:
				_on_vsync_pressed()
			KEY_F1:
				if not OS.has_feature("web"):
					_on_wireframe_pressed()
			KEY_F2:
				_on_shader_pressed()
			KEY_F3:
				_on_lights_pressed()
			KEY_F4:
				_on_atmosphere_pressed()
			KEY_F5:
				_on_collision_pressed()
			KEY_F6:
				_on_culling_pressed()
			KEY_X:
				if planet:
					planet.free_unused_chunks()
			KEY_SPACE:
				_on_toggle()


func _process(delta: float) -> void:
	if not planet_camera:
		return

	# Flight controls: W/S = forward/back, A/D = strafe, R/F = rise/fall, Q/E = roll
	var target: Camera3D = _debug_camera if debug_mode else planet_camera
	var direction := Vector3.ZERO

	if Input.is_key_pressed(KEY_W):
		direction -= target.transform.basis.z
	if Input.is_key_pressed(KEY_S):
		direction += target.transform.basis.z
	if Input.is_key_pressed(KEY_R):
		direction += target.transform.basis.y
	if Input.is_key_pressed(KEY_F):
		direction -= target.transform.basis.y
	if Input.is_key_pressed(KEY_A):
		direction -= target.transform.basis.x
	if Input.is_key_pressed(KEY_D):
		direction += target.transform.basis.x

	# Q/E = roll
	if Input.is_key_pressed(KEY_Q):
		target.rotate_object_local(Vector3.FORWARD, -2.0 * delta)
	if Input.is_key_pressed(KEY_E):
		target.rotate_object_local(Vector3.FORWARD, 2.0 * delta)

	# O/P = time of day (hold to rotate sun continuously)
	if Input.is_key_pressed(KEY_O):
		_sun_angle -= (TAU / 96.0) * delta * 5.0
	if Input.is_key_pressed(KEY_P):
		_sun_angle += (TAU / 96.0) * delta * 5.0

	# Auto speed based on distance from ideal sphere (ignoring terrain to avoid
	# speed jitter over mountains). Works above and inside the planet.
	if debug_mode:
		# Debug camera: fixed speed, not affected by altitude
		speed = 500.0 * speed_multiplier
	else:
		var surface_dist := absf((target.global_position - planet.global_position).length() - planet.radius)
		speed = maxf(clampf(surface_dist * 0.5, 0.5, 50000.0) * speed_multiplier, 0.05)

	if direction.length_squared() > 0.0:
		var offset := direction.normalized() * speed * delta
		if target == planet_camera:
			planet_camera.move(offset, _collision_on)
		else:
			target.position += offset

	# Orbit the sun and update planet's light direction
	if planet and _sun_mesh and sun_orbit_period > 0.0:
		# Smoothly apply manual time offset (from +/- buttons)
		if absf(_sun_target_offset) > 0.001:
			var step := _sun_target_offset * minf(5.0 * delta, 1.0)
			_sun_angle += step
			_sun_target_offset -= step
		_sun_angle += (TAU / sun_orbit_period) * delta
		_sun_angle = fmod(_sun_angle, TAU)
		# Compute sun direction from orbit around Y axis
		var sun_orbit_pos := Vector3(
			sin(_sun_angle) * sun_distance,
			0.0,
			cos(_sun_angle) * sun_distance
		)
		planet.sun_direction = sun_orbit_pos.normalized()
		# Place visual sun in the right direction, but close enough to be inside far plane
		var visual_dist: float = planet_camera.far * 0.8
		var visual_radius: float = visual_dist * 0.02
		_sun_mesh.global_position = planet_camera.global_position + planet.sun_direction * visual_dist
		_sun_mesh.mesh.radius = visual_radius
		_sun_mesh.mesh.height = visual_radius * 2.0
		# Rotate skybox to match sun orbit (simulates planet rotation)
		if _world_env and _world_env.environment:
			var sky_angle := _sun_angle - _sun_start_angle
			_world_env.environment.sky_rotation = Vector3(0.0, sky_angle, 0.0)

	# Update camera (origin shift, auto-level, clip planes) and planet (LOD, shaders).
	# Must be called AFTER all movement and rotation is done this frame.
	planet_camera.update(delta)

	# Update HUD
	_update_hud()


# ===========================================================================
#  Starting camera view — positions camera to show the planet beautifully
# ===========================================================================

func _setup_start_view() -> void:
	# Camera distance: planet + atmosphere fills ~80% of the screen
	var atm_radius := planet.radius + planet.atmosphere_height
	var view_dist := atm_radius * 1.8

	# Sun starts at _sun_start_angle in the XZ plane
	# Offset camera 45° from sun direction so the terminator is visible
	var cam_horizontal_angle := _sun_start_angle + deg_to_rad(50.0)
	var cam_elevation := deg_to_rad(25.0)

	# Spherical to cartesian (Y = up)
	var cam_pos := Vector3(
		sin(cam_horizontal_angle) * cos(cam_elevation) * view_dist,
		sin(cam_elevation) * view_dist,
		cos(cam_horizontal_angle) * cos(cam_elevation) * view_dist
	)

	planet_camera.global_position = planet.global_position + cam_pos
	planet_camera.look_at(planet.global_position, Vector3.UP)


# ===========================================================================
#  Sun (visual decoration — orbiting emissive sphere)
# ===========================================================================

func _create_sun() -> void:
	if not planet:
		return
	_sun_mesh = MeshInstance3D.new()
	_sun_mesh.name = "Sun"
	var sphere := SphereMesh.new()
	sphere.radius = sun_radius
	sphere.height = sun_radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	_sun_mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.95, 0.8)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.95, 0.8)
	mat.emission_energy_multiplier = 3.0
	_sun_mesh.material_override = mat
	planet_camera.add_child(_sun_mesh)



# ===========================================================================
#  Camera reset
# ===========================================================================

func _reset_camera() -> void:
	if not planet:
		return
	var target: Camera3D = _debug_camera if debug_mode else planet_camera
	target.global_position = planet.global_position + _initial_rel_pos
	target.global_transform.basis = _initial_basis
	if not debug_mode:
		planet_camera.move(Vector3.ZERO, _collision_on)


# ===========================================================================
#  Debug observer mode
# ===========================================================================

func _toggle_debug_mode() -> void:
	if not planet_camera or not planet:
		return
	debug_mode = not debug_mode
	_apply_toggle_style(_debug_btn, debug_mode)
	if debug_mode:
		# Create debug camera as sibling (same level as PlanetCamera and Planet)
		if not _debug_camera:
			_debug_camera = Camera3D.new()
			_debug_camera.name = "DebugCamera"
			_debug_camera.near = 0.1
			_debug_camera.far = 100000.0
			get_parent().add_child(_debug_camera)
		# Match debug camera speed to current PlanetCamera speed
		speed_multiplier = clampf(speed / 500.0, 0.1, 10.0)
		# Position debug camera at PlanetCamera's current location
		_debug_camera.global_transform = planet_camera.global_transform
		_debug_camera.current = true
		planet_camera.current = false
		# Show frozen frustum wireframe at PlanetCamera's position
		var frozen_pos := planet.to_local(planet_camera.global_position)
		_show_frustum(frozen_pos, planet_camera.global_transform)
	else:
		# Teleport PlanetCamera to debug camera's position
		planet_camera.global_transform = _debug_camera.global_transform
		planet_camera.current = true
		_debug_camera.current = false
		# Push camera above terrain if collision is enabled
		planet_camera.move(Vector3.ZERO, _collision_on)
		_hide_frustum()


func _show_frustum(frozen_pos: Vector3, frozen_transform: Transform3D) -> void:
	if not _frustum_mesh:
		_frustum_mesh = MeshInstance3D.new()
		_frustum_mesh.name = "FrustumMesh"
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color.YELLOW
		mat.no_depth_test = true
		mat.render_priority = 1
		_frustum_mesh.material_override = mat
		# Child of Planet so it moves correctly with origin shifting
		planet.add_child(_frustum_mesh)
	_build_frustum_mesh(frozen_pos, frozen_transform)
	_frustum_mesh.visible = true


func _hide_frustum() -> void:
	if _frustum_mesh:
		_frustum_mesh.visible = false


func _build_frustum_mesh(frozen_pos: Vector3, frozen_transform: Transform3D) -> void:
	var fov_rad := deg_to_rad(planet_camera.fov)
	var aspect := get_viewport().get_visible_rect().size.x / get_viewport().get_visible_rect().size.y
	var near_dist: float = planet_camera.near
	var far_dist: float = minf(planet_camera.far, frozen_pos.length() * 3.0)
	var near_h: float = 2.0 * tan(fov_rad * 0.5) * near_dist
	var near_w: float = near_h * aspect
	var far_h: float = 2.0 * tan(fov_rad * 0.5) * far_dist
	var far_w: float = far_h * aspect
	var forward: Vector3 = -frozen_transform.basis.z
	var right: Vector3 = frozen_transform.basis.x
	var up: Vector3 = frozen_transform.basis.y
	# Position the mesh at the camera origin — vertices are relative to it.
	# This keeps vertex values small, avoiding float jitter on far edges.
	_frustum_mesh.position = frozen_pos
	var near_center := forward * near_dist
	var far_center := forward * far_dist
	var ntl := near_center + up * (near_h * 0.5) - right * (near_w * 0.5)
	var ntr := near_center + up * (near_h * 0.5) + right * (near_w * 0.5)
	var nbl := near_center - up * (near_h * 0.5) - right * (near_w * 0.5)
	var nbr := near_center - up * (near_h * 0.5) + right * (near_w * 0.5)
	var ftl := far_center + up * (far_h * 0.5) - right * (far_w * 0.5)
	var ftr := far_center + up * (far_h * 0.5) + right * (far_w * 0.5)
	var fbl := far_center - up * (far_h * 0.5) - right * (far_w * 0.5)
	var fbr := far_center - up * (far_h * 0.5) + right * (far_w * 0.5)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	# Near plane rectangle
	_add_line(im, ntl, ntr)
	_add_line(im, ntr, nbr)
	_add_line(im, nbr, nbl)
	_add_line(im, nbl, ntl)
	# Four edges from near plane extending outward (no far plane rectangle)
	_add_line(im, ntl, ftl)
	_add_line(im, ntr, ftr)
	_add_line(im, nbl, fbl)
	_add_line(im, nbr, fbr)
	im.surface_end()
	_frustum_mesh.mesh = im


func _add_line(im: ImmediateMesh, a: Vector3, b: Vector3) -> void:
	im.surface_add_vertex(a)
	im.surface_add_vertex(b)


# ===========================================================================
#  HUD creation (programmatic — no scene file needed)
# ===========================================================================

func _create_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "UI"
	add_child(_hud_layer)

	_hud_panel = PanelContainer.new()
	_hud_panel.anchor_left = 1.0
	_hud_panel.anchor_right = 1.0
	_hud_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_hud_panel.offset_left = -10.0
	_hud_panel.offset_top = 10.0
	_hud_layer.add_child(_hud_panel)

	# Panel style: dark semi-transparent background
	var style := StyleBoxFlat.new()
	style.bg_color = Color(COLOR_BG, 0.9)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	_hud_panel.add_theme_stylebox_override("panel", style)
	_hud_panel.mouse_filter = Control.MOUSE_FILTER_PASS

	# Root layout
	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)
	_hud_panel.add_child(root_vbox)

	# Header row (always visible)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	root_vbox.add_child(header)

	var esc_label := _make_label("Planet")
	esc_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	header.add_child(esc_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_toggle_btn = _make_solid_button("▲")
	_toggle_btn.pressed.connect(_on_toggle)
	header.add_child(_toggle_btn)

	# Separator between header and body
	_sep = HSeparator.new()
	_sep.add_theme_constant_override("separation", 4)
	root_vbox.add_child(_sep)

	# Body — 2-column grid: labels right-aligned | values left-aligned
	_body = GridContainer.new()
	_body.columns = 2
	_body.add_theme_constant_override("h_separation", 16)
	_body.add_theme_constant_override("v_separation", 8)
	root_vbox.add_child(_body)

	# FPS
	_body.add_child(_make_row_label("FPS"))
	_fps_value = _make_value_label("0")
	_body.add_child(_fps_value)

	# VSync (right after FPS — most useful toggle for performance tuning)
	_body.add_child(_make_row_label("VSync"))
	_vsync_on = DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED
	_vsync_btn = _make_toggle_button(_vsync_on)
	_vsync_btn.pressed.connect(_on_vsync_pressed)
	_body.add_child(_vsync_btn)

	# Chunks
	_body.add_child(_make_row_label("Chunks"))
	_chunks_value = _make_value_label("0")
	_body.add_child(_chunks_value)

	# Altitude
	_body.add_child(_make_row_label("Altitude"))
	_altitude_value = _make_value_label("0 km")
	_body.add_child(_altitude_value)

	# Speed
	_body.add_child(_make_row_label("Speed"))
	var speed_row := HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 6)
	_body.add_child(speed_row)

	var minus_btn := _make_solid_button("−")
	minus_btn.pressed.connect(_on_speed_minus)
	speed_row.add_child(minus_btn)

	_speed_label = _make_value_label("1.0x")
	_speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_speed_label.custom_minimum_size.x = 80
	speed_row.add_child(_speed_label)

	var plus_btn := _make_solid_button("+")
	plus_btn.pressed.connect(_on_speed_plus)
	speed_row.add_child(plus_btn)

	# Time (sun position as time of day)
	_body.add_child(_make_row_label("Time"))
	var time_row := HBoxContainer.new()
	time_row.add_theme_constant_override("separation", 6)
	_body.add_child(time_row)

	var time_minus := _make_solid_button("−")
	time_minus.pressed.connect(_on_time_minus)
	time_row.add_child(time_minus)

	_time_label = _make_value_label("12:00")
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_time_label.custom_minimum_size.x = 80
	time_row.add_child(_time_label)

	var time_plus := _make_solid_button("+")
	time_plus.pressed.connect(_on_time_plus)
	time_row.add_child(time_plus)

	# Debug mode (Tab)
	_body.add_child(_make_row_label("Debug"))
	_debug_btn = _make_toggle_button(false)
	_debug_btn.pressed.connect(_toggle_debug_mode)
	_body.add_child(_debug_btn)

	# Wireframe (F1, not supported on web)
	var wireframe_label := _make_row_label("Wireframe")
	_body.add_child(wireframe_label)
	_wireframe_btn = _make_toggle_button(false)
	_wireframe_btn.pressed.connect(_on_wireframe_pressed)
	_body.add_child(_wireframe_btn)
	if OS.has_feature("web"):
		wireframe_label.visible = false
		_wireframe_btn.visible = false

	# Shader (F2)
	_body.add_child(_make_row_label("Shader"))
	_shader_btn = _make_toggle_button(_shader_on)
	_shader_btn.pressed.connect(_on_shader_pressed)
	_body.add_child(_shader_btn)

	# Lights (F3)
	_body.add_child(_make_row_label("Lights"))
	_lights_btn = _make_toggle_button(_lights_on)
	_lights_btn.pressed.connect(_on_lights_pressed)
	_body.add_child(_lights_btn)

	# Atmosphere (F4)
	_body.add_child(_make_row_label("Atmo"))
	_atmosphere_btn = _make_toggle_button(_atmosphere_on)
	_atmosphere_btn.pressed.connect(_on_atmosphere_pressed)
	_body.add_child(_atmosphere_btn)

	# Collision (F5)
	_body.add_child(_make_row_label("Collision"))
	_collision_btn = _make_toggle_button(_collision_on)
	_collision_btn.pressed.connect(_on_collision_pressed)
	_body.add_child(_collision_btn)

	# Culling (F6)
	_body.add_child(_make_row_label("Culling"))
	_culling_btn = _make_toggle_button(_culling_on)
	_culling_btn.pressed.connect(_on_culling_pressed)
	_body.add_child(_culling_btn)

	# "press F12" hint — bottom-right corner, yellow
	_hint_panel = PanelContainer.new()
	var hint_style := StyleBoxFlat.new()
	hint_style.bg_color = Color(1.0, 0.85, 0.0)
	hint_style.content_margin_left = 12
	hint_style.content_margin_right = 12
	hint_style.content_margin_top = 6
	hint_style.content_margin_bottom = 6
	_hint_panel.add_theme_stylebox_override("panel", hint_style)
	_hint_panel.anchor_left = 1.0
	_hint_panel.anchor_top = 1.0
	_hint_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_hint_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hint_panel.offset_right = -20
	_hint_panel.offset_bottom = -20
	_hud_layer.add_child(_hint_panel)
	var hint_label := Label.new()
	hint_label.text = "press F12"
	hint_label.add_theme_font_size_override("font_size", 24)
	hint_label.add_theme_color_override("font_color", Color.BLACK)
	_hint_panel.add_child(hint_label)

	# Full-screen controls overlay (hidden by default)
	_controls_overlay = ColorRect.new()
	_controls_overlay.color = Color(0.0, 0.0, 0.0, 0.85)
	_controls_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_controls_overlay.visible = false
	_controls_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_hud_layer.add_child(_controls_overlay)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_controls_overlay.add_child(center)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 40)
	grid.add_theme_constant_override("v_separation", 4)
	center.add_child(grid)

	# Flight controls (orange)
	var color_flight := Color(1.0, 0.85, 0.5)
	_add_control_row(grid, "W / S", "fly forward / backward", color_flight)
	_add_control_row(grid, "A / D", "strafe left / right", color_flight)
	_add_control_row(grid, "R / F", "rise / fall", color_flight)
	_add_control_row(grid, "Q / E", "roll left / right", color_flight)
	_add_control_row(grid, "Mouse", "look around (click to capture)", color_flight)
	_add_control_row(grid, "Scroll", "speed multiplier", color_flight)

	# Debug controls (blue)
	var color_debug := Color(0.7, 0.8, 1.0)
	_add_control_row(grid, "Tab", "toggle debug camera", color_debug)
	_add_control_row(grid, "H", "reset camera position", color_debug)
	_add_control_row(grid, "X", "free unused chunks", color_debug)
	_add_control_row(grid, "Space", "collapse/expand panel", color_debug)

	# Toggle controls (green)
	var color_toggle := Color(0.6, 0.9, 0.6)
	_add_control_row(grid, "V", "VSync", color_toggle)
	if not OS.has_feature("web"):
		_add_control_row(grid, "F1", "wireframe", color_toggle)
	_add_control_row(grid, "F2", "shader", color_toggle)
	_add_control_row(grid, "F3", "lights", color_toggle)
	_add_control_row(grid, "F4", "atmosphere", color_toggle)
	_add_control_row(grid, "F5", "collision", color_toggle)
	_add_control_row(grid, "F6", "culling", color_toggle)
	_add_control_row(grid, "O / P", "time of day − / +", color_toggle)

	# System (grey)
	var color_sys := Color(0.6, 0.6, 0.65)
	_add_control_row(grid, "ESC", "release mouse cursor", color_sys)
	_add_control_row(grid, "F12", "toggle this help", color_sys)


func _add_control_row(grid: GridContainer, key: String, desc: String, color: Color) -> void:
	var key_label := Label.new()
	key_label.text = key
	key_label.add_theme_font_size_override("font_size", 28)
	key_label.add_theme_color_override("font_color", color)
	key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	grid.add_child(key_label)
	var desc_label := Label.new()
	desc_label.text = desc
	desc_label.add_theme_font_size_override("font_size", 28)
	desc_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	grid.add_child(desc_label)


func _toggle_controls_overlay() -> void:
	_controls_visible = not _controls_visible
	_controls_overlay.visible = _controls_visible
	_hint_panel.visible = not _controls_visible


# ===========================================================================
#  HUD updates
# ===========================================================================

func _update_hud() -> void:
	if _collapsed:
		return
	_fps_value.text = "%d" % Engine.get_frames_per_second()
	if planet:
		_chunks_value.text = "%d / %d" % [planet.visible_chunk_count, planet.get_total_chunk_count()]
	if planet_camera:
		var altitude := planet_camera.get_altitude()
		_altitude_value.text = "%.3f km" % altitude
		_speed_label.text = "%.1fx" % speed_multiplier
		_time_label.text = _sun_angle_to_time_string()


# ===========================================================================
#  HUD callbacks
# ===========================================================================

func _on_toggle() -> void:
	_collapsed = not _collapsed
	_body.visible = not _collapsed
	_sep.visible = not _collapsed
	_toggle_btn.text = "▼" if _collapsed else "▲"

func _on_speed_minus() -> void:
	speed_multiplier = maxf(speed_multiplier / 1.5, 0.1)

func _on_speed_plus() -> void:
	speed_multiplier = minf(speed_multiplier * 1.5, 10.0)

func _on_time_minus() -> void:
	# Queue a 15-minute backward shift (smoothly applied each frame)
	_sun_target_offset -= TAU / 96.0

func _on_time_plus() -> void:
	# Queue a 15-minute forward shift (smoothly applied each frame)
	_sun_target_offset += TAU / 96.0

func _sun_angle_to_time_string() -> String:
	# Map sun angle to 24h clock. Noon (12:00) = sun at start angle (directly illuminating camera start view)
	var normalized := fmod(_sun_angle - _sun_start_angle + TAU, TAU) / TAU
	var total_minutes := int(normalized * 24.0 * 60.0) + 720  # offset so start = 12:00
	total_minutes = total_minutes % 1440
	@warning_ignore("integer_division")
	var hours := total_minutes / 60
	var minutes := total_minutes % 60
	return "%02d:%02d" % [hours, minutes]

func _on_wireframe_pressed() -> void:
	_wireframe_on = not _wireframe_on
	_apply_toggle_style(_wireframe_btn, _wireframe_on)
	if planet:
		planet.set_wireframe(_wireframe_on)

func _on_vsync_pressed() -> void:
	_vsync_on = not _vsync_on
	_apply_toggle_style(_vsync_btn, _vsync_on)
	if planet:
		planet.set_vsync(_vsync_on)

func _on_culling_pressed() -> void:
	_culling_on = not _culling_on
	_apply_toggle_style(_culling_btn, _culling_on)
	if planet:
		planet.set_culling(_culling_on)

func _on_shader_pressed() -> void:
	_shader_on = not _shader_on
	_apply_toggle_style(_shader_btn, _shader_on)
	if planet:
		planet.set_shader_enabled(_shader_on)

func _on_lights_pressed() -> void:
	_lights_on = not _lights_on
	_apply_toggle_style(_lights_btn, _lights_on)
	if planet:
		planet.set_normals_enabled(_lights_on)

func _on_collision_pressed() -> void:
	_collision_on = not _collision_on
	_apply_toggle_style(_collision_btn, _collision_on)
	if _collision_on and not debug_mode:
		planet_camera.move(Vector3.ZERO, true)

func _on_atmosphere_pressed() -> void:
	_atmosphere_on = not _atmosphere_on
	_apply_toggle_style(_atmosphere_btn, _atmosphere_on)
	if planet:
		planet.set_atmosphere_enabled(_atmosphere_on)


# ===========================================================================
#  Widget factories
# ===========================================================================

func _make_row_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 24)
	lbl.add_theme_color_override("font_color", COLOR_LABEL)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return lbl

func _make_value_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 24)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return lbl

func _make_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 24)
	return lbl

func _make_solid_button(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 24)
	btn.custom_minimum_size = Vector2(38, 34)
	btn.add_theme_color_override("font_color", COLOR_BG)
	btn.add_theme_color_override("font_hover_color", COLOR_BG)
	btn.add_theme_color_override("font_pressed_color", COLOR_BG)
	btn.add_theme_color_override("font_focus_color", COLOR_BG)
	_set_all_styleboxes(btn, COLOR_LABEL)
	return btn

func _make_toggle_button(initial: bool) -> Button:
	var btn := Button.new()
	btn.add_theme_font_size_override("font_size", 24)
	btn.custom_minimum_size = Vector2(68, 34)
	btn.focus_mode = Control.FOCUS_NONE
	_apply_toggle_style(btn, initial)
	return btn

func _apply_toggle_style(btn: Button, on: bool) -> void:
	btn.text = "ON" if on else "OFF"
	var color: Color = COLOR_ON if on else COLOR_OFF
	btn.add_theme_color_override("font_color", COLOR_BG)
	btn.add_theme_color_override("font_hover_color", COLOR_BG)
	btn.add_theme_color_override("font_pressed_color", COLOR_BG)
	btn.add_theme_color_override("font_focus_color", COLOR_BG)
	_set_all_styleboxes(btn, color)

func _set_all_styleboxes(btn: Button, color: Color) -> void:
	btn.add_theme_stylebox_override("normal", _make_btn_style(color))
	btn.add_theme_stylebox_override("hover", _make_btn_style(color.lightened(0.2)))
	btn.add_theme_stylebox_override("pressed", _make_btn_style(color.darkened(0.2)))
	btn.add_theme_stylebox_override("focus", _make_btn_style(color))
	btn.add_theme_stylebox_override("disabled", _make_btn_style(color.darkened(0.4)))

func _make_btn_style(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb
