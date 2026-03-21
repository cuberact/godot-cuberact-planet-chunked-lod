## A single node in the planet's quadtree LOD (Level of Detail) structure.
##
## The planet surface is divided into a tree of quads. Each Quad is either:
##   - A LEAF: holds a Chunk (visible mesh) from the pool
##   - An INTERIOR node: has 4 children, no mesh of its own
##
## Every frame, each Quad decides whether to:
##   - SPLIT: replace itself with 4 smaller children (camera got closer)
##   - MERGE: collapse 4 children back into one (camera moved away)
##   - STAY: keep current detail level
##
## Culling skips chunks that are outside the camera's view (frustum culling)
## or hidden behind the planet's curved horizon (horizon culling).
class_name Quad
extends RefCounted

# ===========================================================================
#  Frustum test results
# ===========================================================================

## Frustum test returns one of these values:
const FRUSTUM_OUTSIDE: int = 0   ## Entirely outside the view — don't render
const FRUSTUM_INTERSECT: int = 1 ## Partially inside — test children individually
const FRUSTUM_INSIDE: int = 2    ## Fully inside — skip frustum test for children

# ===========================================================================
#  Tree structure
# ===========================================================================

var planet: Planet
var parent: Quad = null
var children: Array[Quad] = []
var level: int = 0  ## Depth in the quadtree (0 = root, each split adds 1)

## Visual mesh — only set for leaf nodes. Interior nodes have null here.
var chunk: Chunk = null

## Bounding sphere enclosing all chunk vertices.
## Copied from Chunk after build — used for culling and LOD distance checks.
var bounding_center: Vector3
var bounding_radius: float
var bounding_aabb: AABB

## Horizon culling data — copied from Chunk after build.
var horizon_cos_alpha: float
var horizon_sin_alpha: float

## Current frustum test result for this node (see FRUSTUM_* constants above).
var frustum_state: int = FRUSTUM_INTERSECT
# ===========================================================================
#  Initialization
# ===========================================================================

func _init(planet_ref: Planet) -> void:
	if planet_ref == null:
		push_error("parameter planet_ref can not be null.")
	planet = planet_ref

func init_as_root_quad(corners: Array[Vector3]) -> void:
	chunk = planet._acquire_chunk()
	chunk.build_full_mesh(corners)
	_copy_bounds_from_chunk()

func init_as_child_quad(parent_quad: Quad, quadrant: int) -> void:
	if parent_quad == null:
		push_warning("parameter parent_quad can not be null.")
		return
	if parent_quad.chunk == null:
		push_error("parent_quad.chunk is null at level %d, quadrant %d" % [parent_quad.level, quadrant])
		return
	parent = parent_quad
	level = parent_quad.level + 1
	chunk = planet._acquire_chunk()
	chunk.build_mesh_from_parent(parent_quad.chunk, quadrant)
	_copy_bounds_from_chunk()

func _copy_bounds_from_chunk() -> void:
	# Copy bounding/culling data from the built chunk
	bounding_center = chunk.bounding_center
	bounding_radius = chunk.bounding_radius
	bounding_aabb = chunk.bounding_aabb
	horizon_cos_alpha = chunk.horizon_cos_alpha
	horizon_sin_alpha = chunk.horizon_sin_alpha

# ===========================================================================
#  Per-frame update (LOD decisions + culling)
# ===========================================================================

## Main update: decide visibility, then split/merge/recurse.
##
## split_budget is a single-element Array [remaining_splits] passed by reference
## so all recursive calls share one counter. This limits expensive splits per
## frame (merges are cheap — no limit needed).
func update(camera_pos: Vector3, frustum_planes: Array, split_budget: Array[int]) -> void:
	# --- Culling: is this quad visible from the camera? ---
	var is_visible: bool
	if not planet.culling_enabled:
		frustum_state = FRUSTUM_INSIDE
		is_visible = true
	else:
		var above_horizon: bool = _is_above_horizon(camera_pos)
		# If parent is fully inside frustum, so are all children — skip the test
		if parent and parent.frustum_state == FRUSTUM_INSIDE:
			frustum_state = FRUSTUM_INSIDE
		elif not frustum_planes.is_empty():
			frustum_state = _test_frustum(frustum_planes)
		else:
			frustum_state = FRUSTUM_INTERSECT
		is_visible = above_horizon and frustum_state != FRUSTUM_OUTSIDE
	# --- LOD decisions ---
	if not children.is_empty():
		# Interior node: check if we should merge children back
		if _should_merge(camera_pos):
			_merge()
			_set_chunk_visible(is_visible)
		elif not is_visible:
			# Not visible — skip splits, but propagate hiding and allow merges
			for child in children:
				child._update_hidden(camera_pos)
		else:
			for child in children:
				child.update(camera_pos, frustum_planes, split_budget)
	else:
		# Leaf node: check if we should split into 4 children
		if is_visible and _should_split(camera_pos) and split_budget[0] > 0:
			split_budget[0] -= 1
			_split()
			# Don't recurse into new children this frame — they'll update next
			# frame. This limits split cascades to one level per frame.
		else:
			_set_chunk_visible(is_visible)

## Lightweight update for nodes known to be invisible.
## Skips culling and split decisions — only hides leaves and allows merges.
func _update_hidden(camera_pos: Vector3) -> void:
	if not children.is_empty():
		if _should_merge(camera_pos):
			_merge()
			_set_chunk_visible(false)
		else:
			for child in children:
				child._update_hidden(camera_pos)
	else:
		_set_chunk_visible(false)

# ===========================================================================
#  Split & merge
# ===========================================================================

## Split this leaf into 4 children (higher detail).
## Computes the 4 child corner sets from edge midpoints of the current chunk.
func _split() -> void:
	# IMPORTANT: Create all children BEFORE releasing the parent chunk.
	# Children read from parent's _sphere_positions buffer. The pool is LIFO,
	# so releasing first would hand back the same Chunk instance to a child,
	# overwriting the data that other children still need to read.
	children.resize(4)  # CW order: [0]=TL, [1]=TR, [2]=BR, [3]=BL
	for quadrant in range(4):
		children[quadrant] = Quad.new(planet)
		children[quadrant].init_as_child_quad(self, quadrant)
	_release_chunk()
	# Propagate AABB up the tree — child AABBs can extend beyond parent's
	# sampled AABB due to sphere curvature between sample points.
	_propagate_aabb_up()

## Merge 4 children back into one leaf (lower detail).
func _merge() -> void:
	# IMPORTANT: Build parent mesh BEFORE releasing children — same LIFO
	# pool reason as in _split() above.
	chunk = planet._acquire_chunk()
	chunk.build_mesh_from_children(
		children[0].chunk, children[1].chunk,
		children[2].chunk, children[3].chunk)
	bounding_center = chunk.bounding_center
	bounding_radius = chunk.bounding_radius
	bounding_aabb = chunk.bounding_aabb
	horizon_cos_alpha = chunk.horizon_cos_alpha
	horizon_sin_alpha = chunk.horizon_sin_alpha
	for child in children:
		child._release_chunk()
	children.clear()

## Recompute this node's AABB from children and propagate up to root.
## Called after split — ensures all ancestors have conservative AABBs.
func _propagate_aabb_up() -> void:
	if children.is_empty():
		return
	bounding_aabb = children[0].bounding_aabb
	for i in range(1, 4):
		bounding_aabb = bounding_aabb.merge(children[i].bounding_aabb)
	if parent:
		parent._propagate_aabb_up()


## Recursively release all chunks in this subtree.
func destroy() -> void:
	if not children.is_empty():
		for child in children:
			child.destroy()
		children.clear()
	_release_chunk()

# ===========================================================================
#  Chunk (mesh) management
# ===========================================================================

## Return the chunk to the pool and clear the reference.
func _release_chunk() -> void:
	if chunk != null:
		_set_chunk_visible(false)
		planet._release_chunk(chunk)
		chunk = null

## Show or hide this node's chunk mesh.
func _set_chunk_visible(show: bool) -> void:
	if chunk != null:
		if chunk.is_shown != show:
			planet.visible_chunk_count += 1 if show else -1
		chunk.visible = show
		chunk.is_shown = show

# ===========================================================================
#  LOD distance helpers
# ===========================================================================

## Squared distance from camera to the nearest point of the bounding sphere.
## Used for split/merge decisions — squared to avoid an unnecessary sqrt.
func _nearest_distance_sq(camera_pos: Vector3) -> float:
	var center_dist_sq: float = camera_pos.distance_squared_to(bounding_center)
	# Subtract bounding radius to get distance to nearest surface point
	center_dist_sq -= bounding_radius * bounding_radius
	return maxf(center_dist_sq, 0.0)

## Should this leaf split into 4 children? (camera is close enough)
func _should_split(camera_pos: Vector3) -> bool:
	if level >= planet.max_lod_level or level >= planet.split_distance_sq.size():
		return false
	return _nearest_distance_sq(camera_pos) < planet.split_distance_sq[level]

## Should these 4 children merge back into one? (camera moved far enough away)
## Only merges when ALL children are leaves (no grandchildren).
func _should_merge(camera_pos: Vector3) -> bool:
	if children.is_empty():
		return false
	if level >= planet.merge_distance_sq.size():
		return true  # beyond current threshold array — merge back
	for child in children:
		if not child.children.is_empty():
			return false  # has grandchildren — can't merge yet
	return _nearest_distance_sq(camera_pos) > planet.merge_distance_sq[level]

# ===========================================================================
#  Culling helpers
# ===========================================================================

## Horizon test: is this chunk above the planet's curved horizon?
##
## Imagine standing on the planet and looking at the horizon — it's a circle
## around you where the surface curves away. Chunks beyond that circle are
## hidden by the planet itself and don't need to be rendered.
##
## The test uses angular geometry on the sphere:
## 1. Camera's horizon angle: how far around the sphere the camera can see
##    (depends on altitude — higher up = see farther)
## 2. Chunk's angular extent: how much of the sphere this chunk covers
## 3. Terrain extension: mountains can peek above the geometric horizon
##
## Returns true if any part of the chunk could be visible.
func _is_above_horizon(camera_pos: Vector3) -> bool:
	var camera_distance: float = camera_pos.length()
	# Camera inside the planet — everything is visible
	if camera_distance <= planet.radius:
		return true
	var camera_dir: Vector3 = camera_pos / camera_distance
	var chunk_dir: Vector3 = bounding_center.normalized()
	var cos_angle_to_chunk: float = camera_dir.dot(chunk_dir)
	# Camera is within the chunk's angular extent — always visible
	if cos_angle_to_chunk >= horizon_cos_alpha:
		return true
	# Compute the combined horizon angle:
	# camera_horizon + terrain_extension = total visible angle from camera
	var cos_camera_horizon: float = planet.radius / camera_distance
	var sin_camera_horizon: float = sqrt(maxf(0.0, 1.0 - cos_camera_horizon * cos_camera_horizon))
	var cos_terrain_extend: float = planet.radius / (planet.radius + planet.terrain_height)
	var sin_terrain_extend: float = sqrt(maxf(0.0, 1.0 - cos_terrain_extend * cos_terrain_extend))
	# Combined horizon angle (cos(a+b) = cos(a)cos(b) - sin(a)sin(b))
	var cos_total_horizon: float = cos_camera_horizon * cos_terrain_extend - sin_camera_horizon * sin_terrain_extend
	# Nearest edge of chunk (subtract chunk's angular radius from angle to center)
	# cos(a-b) = cos(a)cos(b) + sin(a)sin(b)
	var sin_angle_to_chunk: float = sqrt(maxf(0.0, 1.0 - cos_angle_to_chunk * cos_angle_to_chunk))
	var cos_nearest_edge: float = cos_angle_to_chunk * horizon_cos_alpha + sin_angle_to_chunk * horizon_sin_alpha
	return cos_nearest_edge > cos_total_horizon

## Frustum test: is this chunk's bounding box inside the camera's view frustum?
## Uses AABB vs frustum planes test — accounts for shader displacement via terrain_height.
## Returns FRUSTUM_OUTSIDE, FRUSTUM_INTERSECT, or FRUSTUM_INSIDE.
##
## Godot frustum planes have normals pointing OUTWARD (away from frustum interior).
## distance_to > 0 = outside frustum, distance_to < 0 = inside frustum.
func _test_frustum(planes: Array) -> int:
	var fully_inside_count: int = 0
	var aabb_min: Vector3 = bounding_aabb.position
	var aabb_max: Vector3 = bounding_aabb.position + bounding_aabb.size
	for plane in planes:
		# n-vertex: the corner most AGAINST the plane normal (closest to inside).
		# If even this corner is outside → entire AABB is outside.
		var n_vertex := Vector3(
			aabb_min.x if plane.normal.x >= 0.0 else aabb_max.x,
			aabb_min.y if plane.normal.y >= 0.0 else aabb_max.y,
			aabb_min.z if plane.normal.z >= 0.0 else aabb_max.z
		)
		if plane.distance_to(n_vertex) > 0.0:
			return FRUSTUM_OUTSIDE
		# p-vertex: the corner most ALONG the plane normal (closest to outside).
		# If even this corner is inside → entire AABB is inside this plane.
		var p_vertex := Vector3(
			aabb_max.x if plane.normal.x >= 0.0 else aabb_min.x,
			aabb_max.y if plane.normal.y >= 0.0 else aabb_min.y,
			aabb_max.z if plane.normal.z >= 0.0 else aabb_min.z
		)
		if plane.distance_to(p_vertex) <= 0.0:
			fully_inside_count += 1
	if fully_inside_count == planes.size():
		return FRUSTUM_INSIDE
	return FRUSTUM_INTERSECT
