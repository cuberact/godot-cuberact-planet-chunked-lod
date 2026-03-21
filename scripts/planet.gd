@tool
## Planet renderer with configurable terrain.
##
## Place this node as a sibling of PlanetCamera, tweak the @export properties
## in the inspector, and run the game. The planet builds itself automatically
## in _ready(). In the editor, a small placeholder sphere marks where the
## planet will appear. User objects (trees, buildings, etc.) can be added as
## children of this node — they share the origin-shifted coordinate space.
class_name Planet
extends Node3D

# ===========================================================================
#  Configuration (@export — visible in the Godot inspector)
# ===========================================================================

## Sphere radius in km. Earth-like default.
@export_range(100.0, 10000.0) var radius: float = 6378.0
## Peak terrain displacement in km. Controls mountain height.
## Maximum terrain elevation above the ideal sphere in km.
## Terrain ranges from 0 (ocean floor) to terrain_height (highest peak).
@export_range(1.0, 100.0) var terrain_height: float = 16.0
## Atmosphere height above planet surface in km.
@export_range(110.0, 500.0) var atmosphere_height: float = 222.0
## Vertices per chunk edge (actual grid is grid_size+1 × grid_size+1).
@export var grid_size: int = 16
## Max chunk splits per frame. Higher = faster LOD convergence but choppier frames.
@export var split_budget: int = 8
## Split when a chunk spans more than this many degrees on screen.
## Lower = more detail but more chunks. 10–40 is reasonable.
@export_range(5.0, 45.0) var lod_threshold_deg: float = 10.0
## Deepest allowed quadtree level. Higher = finer detail up close.
@export_range(2, 20) var max_lod_level: int = 16
## Shared AABB for all chunks — disables Godot's built-in frustum culling.
## Covers the entire planet sphere + terrain_height. Computed once in _ready().
var chunk_custom_aabb: AABB

## Check to destroy all chunks and rebuild. Unchecks itself.
@export var rebuild: bool = false:
	set(value):
		rebuild = false
		if value and not Engine.is_editor_hint():
			rebuild_planet()

# ===========================================================================
#  Runtime state
# ===========================================================================

## The 6 root quads — one per cube face.
var root_quads: Array[Quad] = []

## Direction toward the sun (normalized). Set by your controller script each frame.
var sun_direction: Vector3 = Vector3(0.0, 0.0, 1.0)

## Frustum + horizon culling toggle (runtime only, toggled via HUD).
var culling_enabled: bool = true

## Shader normals toggle — ON = per-pixel computed normals, OFF = flat vertex normals.
var normals_enabled: bool = true

## Terrain shader material (per-pixel elevation coloring).
var shader_enabled: bool = true
var _shader_material: ShaderMaterial
var _simple_color_material: Material        ## Vertex-color material for debug mode (lazy init)

## Wireframe mode flag.
var wireframe_mode: bool = false

## Atmosphere toggle (runtime only, toggled via HUD).
var atmosphere_enabled: bool = true

## Atmosphere mesh and material.
var _atm_mesh: MeshInstance3D
var _atm_material: ShaderMaterial

## CPU-side noise for terrain height queries (camera collision, etc.)
var terrain_noise: TerrainNoise = TerrainNoise.new()

## Per-level distance thresholds for LOD decisions (precomputed, squared).
## A chunk splits when the camera is closer than split_distance_sq[level].
## Merge uses a slightly larger distance (hysteresis) to prevent flickering.
var split_distance_sq: PackedFloat64Array
var merge_distance_sq: PackedFloat64Array

## Editor-only placeholder sphere (removed at runtime).
var _preview_mesh: MeshInstance3D
const _PREVIEW_RADIUS: float = 0.5

# ---- Chunk pool (recycled MeshInstance3D nodes) ----
var _chunk_pool_node: Node3D          ## Container node for all chunks (keeps scene tree clean)
var _free_chunks: Array[Chunk] = []   ## Free chunks ready for reuse (LIFO stack)
var _next_chunk_id: int = 1           ## Rolling ID for naming new chunk nodes
var visible_chunk_count: int = 0      ## Chunks currently visible

# ===========================================================================
#  Initialization
# ===========================================================================

func _ready() -> void:
	if Engine.is_editor_hint():
		_create_preview()
		return
	# Remove editor preview if it was serialized into the scene
	if _preview_mesh:
		_preview_mesh.queue_free()
		_preview_mesh = null
	# Materials must exist before chunks are created (they reference it)
	_shader_material = load("res://materials/terrain.tres") as ShaderMaterial
	var std_mat := StandardMaterial3D.new()
	std_mat.vertex_color_use_as_albedo = true
	std_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_simple_color_material = std_mat
	# Container for all chunk meshes — keeps the scene tree clean so user
	# objects added as children of Planet don't get lost among hundreds of chunks.
	_chunk_pool_node = Node3D.new()
	_chunk_pool_node.name = "ChunkPool"
	add_child(_chunk_pool_node)
	rebuild_planet()

## Show a small translucent sphere in the editor so the user can see
## where the planet will spawn. Fixed size — actual planet is too large to preview.
func _create_preview() -> void:
	_preview_mesh = MeshInstance3D.new()
	_preview_mesh.name = "_EditorPreview"
	var sphere := SphereMesh.new()
	sphere.radius = _PREVIEW_RADIUS
	sphere.height = _PREVIEW_RADIUS * 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	_preview_mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.5, 1.0, 0.4)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_preview_mesh.material_override = mat
	add_child(_preview_mesh)

## Precompute per-level split/merge distance thresholds.
##
## The idea: a chunk should split when it appears "too large" on screen.
## Screen size depends on the chunk's real-world size and distance from camera.
## If a chunk at level L has edge_size E, it subtends angle ≈ E / distance.
## We split when that angle exceeds lod_threshold_deg.
##
## Solving for distance: split_distance = edge_size / tan(threshold).
## Merge uses threshold - 0.1° (hysteresis) to prevent split/merge flickering.
func _compute_lod_thresholds() -> void:
	split_distance_sq.resize(max_lod_level + 1)
	merge_distance_sq.resize(max_lod_level + 1)
	# Edge length of the inscribed cube for a sphere of given radius.
	# A cube inscribed in a sphere of radius R has edge = 2R / sqrt(3).
	var cube_edge: float = (radius * 2.0) / sqrt(3.0)
	for level in range(max_lod_level + 1):
		var edge_size: float = cube_edge / pow(2.0, level)
		var split_dist: float = edge_size / tan(deg_to_rad(lod_threshold_deg))
		split_distance_sq[level] = split_dist * split_dist
		# 0.1° hysteresis prevents split/merge flickering at threshold boundary
		var merge_dist: float = edge_size / tan(deg_to_rad(lod_threshold_deg - 0.1))
		merge_distance_sq[level] = merge_dist * merge_dist

## Destroy all chunks and rebuild the planet from scratch.
## Recomputes everything that depends on exported properties.
## Called from _ready() on startup and from the inspector's Rebuild checkbox.
func rebuild_planet() -> void:
	if not _chunk_pool_node:
		return
	# Validate grid_size: must be at least 4 and a power of 2.
	if grid_size < 4:
		push_warning("Planet: grid_size %d is too small, clamped to 4." % grid_size)
		grid_size = 4
	elif grid_size & (grid_size - 1) != 0: # Bitwise power-of-2 check
		var valid := 4
		while valid * 2 <= grid_size:
			valid *= 2
		push_warning("Planet: grid_size %d is not a power of 2, clamped to %d." % [grid_size, valid])
		grid_size = valid
	Chunk.build_shared_indices(grid_size)
	_compute_lod_thresholds()
	var r: float = radius + terrain_height
	chunk_custom_aabb = AABB(Vector3(-r, -r, -r), Vector3(2.0 * r, 2.0 * r, 2.0 * r))
	# Destroy old chunks — pool buffers may have wrong size for new grid_size
	for quad in root_quads:
		quad.destroy()
	root_quads.clear()
	if _chunk_pool_node:
		for chunk in _free_chunks:
			_chunk_pool_node.remove_child(chunk)
			chunk.queue_free()
		_free_chunks.clear()
		_next_chunk_id = 1
	root_quads.resize(6)
	for i in range(6):
		var face_corners: Array[Vector3] = []
		face_corners.assign(CUBE_FACES[i])
		root_quads[i] = Quad.new(self)
		root_quads[i].init_as_root_quad(face_corners)
	_rebuild_atmosphere()

func _rebuild_atmosphere() -> void:
	if _atm_mesh:
		_atm_mesh.queue_free()
		_atm_mesh = null
		_atm_material = null
	var outer_r := radius + atmosphere_height
	var sphere := SphereMesh.new()
	sphere.radius = outer_r
	sphere.height = outer_r * 2.0
	sphere.radial_segments = 64
	sphere.rings = 32
	_atm_mesh = MeshInstance3D.new()
	_atm_mesh.name = "Atmosphere"
	_atm_mesh.mesh = sphere
	# Planet-wide AABB so Godot never culls the atmosphere sphere
	_atm_mesh.custom_aabb = chunk_custom_aabb
	_atm_material = load("res://materials/atmosphere.tres") as ShaderMaterial
	# Parameters derived from planet geometry (not user-tunable)
	_atm_material.set_shader_parameter("inner_radius", radius)
	_atm_material.set_shader_parameter("outer_radius", outer_r)
	_atm_material.set_shader_parameter("atm_scale", 1.0 / atmosphere_height)
	_atm_mesh.material_override = _atm_material
	add_child(_atm_mesh)

# ===========================================================================
#  Per-frame update (called by PlanetCamera, not by _process)
# ===========================================================================

## Update LOD, shader uniforms, and atmosphere. Called by PlanetCamera.update()
## after origin shifting and clip plane adjustment are done.
func update(cam: PlanetCamera) -> void:
	if Engine.is_editor_hint():
		return
	if cam == null:
		return
	var camera_pos := to_local(cam.global_position)
	# Transform frustum planes from world space to planet local space.
	# Origin shifting moves the planet away from world origin,
	# so world-space planes don't match the planet's local coordinate system.
	var planet_pos := global_position
	var frustum_planes := []
	for p in cam.get_frustum():
		frustum_planes.append(Plane(p.normal, p.d - p.normal.dot(planet_pos)))
	# Shared split budget — a single-element array so recursive calls can
	# decrement it (GDScript arrays are passed by reference, ints are not).
	var remaining_splits: Array[int] = [split_budget]
	for quad in root_quads:
		quad.update(camera_pos, frustum_planes, remaining_splits)
	# Update shader uniforms
	if _shader_material:
		_shader_material.set_shader_parameter("planet_origin", global_position)
		_shader_material.set_shader_parameter("planet_radius", radius)
		_shader_material.set_shader_parameter("terrain_height", terrain_height)
		_shader_material.set_shader_parameter("sun_direction", sun_direction)
		terrain_noise.sync_from_material(_shader_material)
	# Update atmosphere uniforms
	if atmosphere_enabled and _atm_material:
		var cam_local := to_local(cam.global_position)
		_atm_material.set_shader_parameter("camera_pos", cam_local)
		_atm_material.set_shader_parameter("sun_direction", sun_direction)
		_atm_material.set_shader_parameter("camera_height", cam_local.length())

# ===========================================================================
#  Chunk pool — recycled MeshInstance3D nodes
# ===========================================================================

## Acquire a chunk from the pool (creates one if pool is empty).
## Returns a ready-to-use Chunk instance (still needs build_mesh called).
func _acquire_chunk() -> Chunk:
	if _free_chunks.is_empty():
		_create_pool_chunk()
	return _free_chunks.pop_back()

## Release a chunk back to the pool. Hides it immediately.
func _release_chunk(chunk: Chunk) -> void:
	_free_chunks.push_back(chunk)

## Returns the total number of chunk nodes (active + free in pool).
func get_total_chunk_count() -> int:
	return _chunk_pool_node.get_child_count() if _chunk_pool_node else 0

## Remove all unused chunks from the pool, freeing GPU memory.
## Active chunks (held by quads) are not affected.
func free_unused_chunks() -> void:
	for chunk in _free_chunks:
		_chunk_pool_node.remove_child(chunk)
		chunk.queue_free()
	_free_chunks.clear()

func _create_pool_chunk() -> void:
	var chunk := Chunk.new()
	chunk.setup(self)
	chunk.material_override = _shader_material if shader_enabled else _simple_color_material
	chunk.visible = false
	_chunk_pool_node.add_child(chunk)
	chunk.name = "Chunk_%d" % _next_chunk_id
	_next_chunk_id += 1
	_free_chunks.push_back(chunk)

# ===========================================================================
#  Toggles (called by Example via HUD signals and keyboard shortcuts)
# ===========================================================================

func set_wireframe(enabled: bool) -> void:
	wireframe_mode = enabled
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if enabled else Viewport.DEBUG_DRAW_DISABLED

func set_vsync(enabled: bool) -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if enabled else DisplayServer.VSYNC_DISABLED)

func set_culling(enabled: bool) -> void:
	culling_enabled = enabled

## Toggle per-pixel normal computation (HUD shows this as "Lights" toggle).
## When ON: shader computes normals → enables Lambert diffuse lighting.
## When OFF: flat vertex normals → no lighting, just elevation colors.
func set_normals_enabled(enabled: bool) -> void:
	normals_enabled = enabled
	if _shader_material:
		_shader_material.set_shader_parameter("compute_normals", enabled)

## Toggle between shader-computed coloring and vertex colors.
func set_shader_enabled(enabled: bool) -> void:
	shader_enabled = enabled
	var mat: Material = _shader_material if shader_enabled and _shader_material else _simple_color_material
	if _chunk_pool_node:
		for child in _chunk_pool_node.get_children():
			if child is Chunk:
				child.material_override = mat

## Toggle atmosphere on/off at runtime.
func set_atmosphere_enabled(enabled: bool) -> void:
	atmosphere_enabled = enabled
	if _atm_mesh:
		_atm_mesh.visible = enabled

# ===========================================================================
#  Terrain queries
# ===========================================================================

## Terrain height (in km) at a world-space position. Returns the noise-based
## displacement above the ideal sphere — same scale as terrain_height in inspector.
func get_terrain_height(world_pos: Vector3) -> float:
	var rel_pos := world_pos - global_position
	return terrain_noise.compute_noise(rel_pos) * terrain_height


## Distance from a world-space position to the terrain surface.
## Positive = above terrain, negative = below terrain.
func get_distance_to_terrain(world_pos: Vector3) -> float:
	var rel_pos := world_pos - global_position
	return rel_pos.length() - (radius + get_terrain_height(world_pos))

# ===========================================================================
#  Constants
# ===========================================================================

## The 6 faces of the unit cube, each defined by 4 corners:
## [bottom-left, bottom-right, top-left, top-right].
##
## The planet starts as a cube. Each face is a quadtree root that subdivides
## independently. All 6 faces are then projected onto a sphere (spherified).
##
##        +-----+
##        | Top |
##   +----+-----+----+-----+
##   |Left|Front|Right|Back |
##   +----+-----+----+-----+
##        |Botm.|
##        +-----+
##
## Each face is defined by 4 corners on the unit cube (±1, ±1, ±1).
## Corner order: TL, TR, BR, BL (clockwise, looking at the face from outside the cube).
const CUBE_FACES: Array[Array] = [
	[Vector3(-1, 1, 1), Vector3( 1, 1, 1), Vector3( 1,-1, 1), Vector3(-1,-1, 1)],  # Front  (+Z)
	[Vector3( 1, 1, 1), Vector3( 1, 1,-1), Vector3( 1,-1,-1), Vector3( 1,-1, 1)],  # Right  (+X)
	[Vector3( 1, 1,-1), Vector3(-1, 1,-1), Vector3(-1,-1,-1), Vector3( 1,-1,-1)],  # Back   (-Z)
	[Vector3(-1, 1,-1), Vector3(-1, 1, 1), Vector3(-1,-1, 1), Vector3(-1,-1,-1)],  # Left   (-X)
	[Vector3(-1, 1,-1), Vector3( 1, 1,-1), Vector3( 1, 1, 1), Vector3(-1, 1, 1)],  # Top    (+Y)
	[Vector3(-1,-1, 1), Vector3( 1,-1, 1), Vector3( 1,-1,-1), Vector3(-1,-1,-1)],  # Bottom (-Y)
]
