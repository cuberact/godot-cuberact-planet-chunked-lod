## Visual mesh for one chunk of the planet surface.
##
## A chunk is a small rectangular patch on the ideal sphere. Terrain
## displacement and coloring is done entirely by the shader, but bounding
## data (AABB, horizon culling) accounts for the maximum terrain height.
## The mesh stores only the flat sphere grid — the shader's vertex() function
## displaces vertices using procedural noise, and fragment() colors per-pixel.
##
## Each chunk also builds a "skirt" — an extra ring of vertices pushed inward
## toward the planet center — that hides gaps between adjacent LOD levels.
## Skirt vertices are flagged via vertex color alpha = 0.0 so the shader
## knows not to displace them.
##
## Chunks are managed by Planet's pool: acquired on quadtree split, released
## on merge. The MeshInstance3D stays in the scene tree; only `visible` toggles.
class_name Chunk
extends MeshInstance3D

# ===========================================================================
#  Shared state (all chunks share these)
# ===========================================================================

## Single shared index buffer for the grid + skirt triangles.
## Built once at startup by init_shared_indices(), used by every chunk.
static var _shared_indices: PackedInt32Array


## Quadrant layout when splitting a chunk into 4 children (clockwise from TL):
##
##   TL(0) | TR(1)      Each child covers one quarter of the parent.
##   ------+------      The offset tells where this quadrant starts
##   BL(3) | BR(2)      within the parent's grid (in half-edge units).
const QUADRANT_OFFSETS: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1),
]

# ===========================================================================
#  Per-instance state
# ===========================================================================

## Planet reference — set once at creation, never changes.
var planet: Planet

## Scratch buffers — allocated once per Chunk instance, reused every rebuild.
var _sphere_positions: PackedVector3Array  ## planet-local positions on ideal sphere
var _local_positions: PackedVector3Array   ## positions relative to chunk center (mesh vertices)
var _normals: PackedVector3Array
var _colors: PackedColorArray
var _uv2: PackedVector2Array

## Four corner positions in cube space (pre-rotated per face).
## Order: TL, TR, BR, BL (clockwise from top-left).
var corners: Array[Vector3] = []

## Bounding sphere — encloses all vertices (with terrain amplitude margin).
var bounding_center: Vector3
var bounding_radius: float
var bounding_aabb: AABB  ## Axis-aligned bounding box including terrain displacement

## Horizon culling data.
var horizon_cos_alpha: float
var horizon_sin_alpha: float

## Skirt depth as a fraction of the chunk's bounding sphere radius.
const SKIRT_DEPTH_FRACTION: float = 0.15

var is_shown = false
# ===========================================================================
#  Shared index buffer initialization
# ===========================================================================

## Build the shared index buffer for the given grid size.
static func build_shared_indices(grid_size: int) -> void:
	var v_count: int = grid_size + 1
	var grid_vertex_count: int = v_count * v_count
	var indices := PackedInt32Array()
	# --- Grid triangles ---
	# Two triangles per cell (front-face winding order).
	# Grid convention: y=0 is top row, y increases downward.
	for y in range(grid_size):
		for x in range(grid_size):
			var idx_tl: int = x + y * v_count
			var idx_tr: int = (x + 1) + y * v_count
			var idx_bl: int = x + (y + 1) * v_count
			var idx_br: int = (x + 1) + (y + 1) * v_count
			indices.append(idx_tl); indices.append(idx_tr); indices.append(idx_bl)
			indices.append(idx_tr); indices.append(idx_br); indices.append(idx_bl)
	# --- Skirt triangles ---
	# Skirt = extra ring of triangles hanging below each edge of the grid.
	# Connects each grid edge vertex to a lowered copy. Hides gaps between
	# adjacent chunks at different LOD levels. 4 edges: top, right, bottom, left.
	# Winding order matches grid triangles so backface culling works correctly.
	var skirt_base: int = grid_vertex_count
	for x in range(grid_size):
		var e0: int = x
		var e1: int = x + 1
		var s0: int = skirt_base + x
		var s1: int = skirt_base + x + 1
		indices.append(e0); indices.append(s0); indices.append(e1)
		indices.append(s0); indices.append(s1); indices.append(e1)
	skirt_base = grid_vertex_count + v_count
	for y in range(grid_size):
		var e0: int = grid_size + y * v_count
		var e1: int = grid_size + (y + 1) * v_count
		var s0: int = skirt_base + y
		var s1: int = skirt_base + y + 1
		indices.append(e0); indices.append(s0); indices.append(e1)
		indices.append(s0); indices.append(s1); indices.append(e1)
	skirt_base = grid_vertex_count + 2 * v_count
	for x in range(grid_size):
		var e0: int = (grid_size - x) + grid_size * v_count
		var e1: int = (grid_size - x - 1) + grid_size * v_count
		var s0: int = skirt_base + x
		var s1: int = skirt_base + x + 1
		indices.append(e0); indices.append(s0); indices.append(e1)
		indices.append(s0); indices.append(s1); indices.append(e1)
	skirt_base = grid_vertex_count + 3 * v_count
	for y in range(grid_size):
		var e0: int = 0 + (grid_size - y) * v_count
		var e1: int = 0 + (grid_size - y - 1) * v_count
		var s0: int = skirt_base + y
		var s1: int = skirt_base + y + 1
		indices.append(e0); indices.append(s0); indices.append(e1)
		indices.append(s0); indices.append(s1); indices.append(e1)
	_shared_indices = indices

# ===========================================================================
#  Mesh building — three entry points, one shared finalization
# ===========================================================================

## Full build from 4 cube-space corners.
func build_full_mesh(new_corners: Array[Vector3]) -> void:
	corners = new_corners
	var v_count: int = planet.grid_size + 1  # vertices per edge (e.g. 17 for grid_size=16)
	var edge: int = planet.grid_size         # segments per edge (= grid_size)
	for y in range(v_count):
		var v_param: float = float(y) / edge
		for x in range(v_count):
			var u_param: float = float(x) / edge
			var cube_pos: Vector3 = _bilinear(new_corners, u_param, v_param)
			_sphere_positions[x + y * v_count] = _spherify(cube_pos)
	_finalize_mesh()

## Build by splitting from a parent chunk (optimization).
func build_mesh_from_parent(parent_chunk: Chunk, quadrant: int) -> void:
	var pc := parent_chunk.corners  # pc[0]=TL, pc[1]=TR, pc[2]=BR, pc[3]=BL
	match quadrant:
		0: # Top-left quadrant
			var c_tl := pc[0]
			var c_tr := (pc[0] + pc[1]) * 0.5
			var c_br := (pc[0] + pc[1] + pc[2] + pc[3]) * 0.25
			var c_bl := (pc[0] + pc[3]) * 0.5
			corners = [c_tl, c_tr, c_br, c_bl]
		1: # Top-right quadrant
			var c_tl := (pc[0] + pc[1]) * 0.5
			var c_tr := pc[1]
			var c_br := (pc[1] + pc[2]) * 0.5
			var c_bl := (pc[0] + pc[1] + pc[2] + pc[3]) * 0.25
			corners = [c_tl, c_tr, c_br, c_bl]
		2: # Bottom-right quadrant
			var c_tl := (pc[0] + pc[1] + pc[2] + pc[3]) * 0.25
			var c_tr := (pc[1] + pc[2]) * 0.5
			var c_br := pc[2]
			var c_bl := (pc[2] + pc[3]) * 0.5
			corners = [c_tl, c_tr, c_br, c_bl]
		3: # Bottom-left quadrant
			var c_tl := (pc[0] + pc[3]) * 0.5
			var c_tr := (pc[0] + pc[1] + pc[2] + pc[3]) * 0.25
			var c_br := (pc[2] + pc[3]) * 0.5
			var c_bl := pc[3]
			corners = [c_tl, c_tr, c_br, c_bl]
		_:
			push_error("wrong quadrant. must be 0-3")
			return
	var v_count: int = planet.grid_size + 1
	var edge: int = planet.grid_size
	var half: int = edge >> 1
	var offset: Vector2i = QUADRANT_OFFSETS[quadrant]
	var ox: int = offset.x * half
	var oy: int = offset.y * half
	for y in range(v_count):
		var v_param: float = float(y) / edge
		for x in range(v_count):
			var idx: int = x + y * v_count
			if (x % 2 == 0) and (y % 2 == 0):
				var px: int = ox + (x >> 1)
				var py: int = oy + (y >> 1)
				_sphere_positions[idx] = parent_chunk._sphere_positions[px + py * v_count]
			else:
				var u_param: float = float(x) / edge
				var cube_pos: Vector3 = _bilinear(corners, u_param, v_param)
				_sphere_positions[idx] = _spherify(cube_pos)
	_finalize_mesh()

## Build by merging 4 children back into one parent (optimization).
## Children in CW order: TL, TR, BR, BL — matching the corners convention.
func build_mesh_from_children(c_tl: Chunk, c_tr: Chunk, c_br: Chunk, c_bl: Chunk) -> void:
	corners = [c_tl.corners[0], c_tr.corners[1], c_br.corners[2], c_bl.corners[3]]
	var v_count: int = planet.grid_size + 1
	var half: int = planet.grid_size >> 1
	# CW quadrant lookup: (qx + qy*2) → [TL=0, TR=1, BL=3, BR=2]
	const Q_LOOKUP: Array[int] = [0, 1, 3, 2]
	var child_positions: Array[PackedVector3Array] = [
		c_tl._sphere_positions, c_tr._sphere_positions,
		c_br._sphere_positions, c_bl._sphere_positions,
	]
	for py in range(v_count):
		for px in range(v_count):
			var qx: int = 0 if px <= half else 1
			var qy: int = 0 if py <= half else 1
			var q: int = Q_LOOKUP[qx + qy * 2]
			var cx: int = (px - qx * half) * 2
			var cy: int = (py - qy * half) * 2
			_sphere_positions[px + py * v_count] = child_positions[q][cx + cy * v_count]
	_finalize_mesh()

# ===========================================================================
#  Setup & reset
# ===========================================================================

## One-time setup called by Planet when creating this Chunk instance.
func setup(p: Planet) -> void:
	planet = p
	var v_count: int = planet.grid_size + 1
	var grid_vertex_count: int = v_count * v_count
	var total_vertex_count: int = grid_vertex_count + 4 * v_count
	_sphere_positions.resize(grid_vertex_count)
	_local_positions.resize(total_vertex_count)
	_normals.resize(total_vertex_count)
	_colors.resize(total_vertex_count)
	_uv2.resize(total_vertex_count)

# ===========================================================================
#  Internals: finalization pipeline
# ===========================================================================

## Post-processing after _sphere_positions is populated.
## Vertices are on the ideal sphere (no terrain). Shader does displacement.
func _finalize_mesh() -> void:
	var v_count: int = planet.grid_size + 1
	var grid_vertex_count: int = v_count * v_count
	# --- Bounding sphere center from two diagonal corners (TL and BR) ---
	# On an ideal sphere, the grid is regular — no need to iterate all vertices.
	var edge: int = v_count - 1
	var corner_tl: Vector3 = _sphere_positions[0]
	var corner_br: Vector3 = _sphere_positions[edge + edge * v_count]
	var center: Vector3 = (corner_tl + corner_br) * 0.5
	bounding_center = center
	position = center
	bounding_radius = center.distance_to(corner_tl)
	# Horizon culling data from the two most extreme vertices
	var chunk_dir: Vector3 = center.normalized()
	var cos_tl: float = chunk_dir.dot(corner_tl.normalized())
	var cos_br: float = chunk_dir.dot(corner_br.normalized())
	var min_cos_alpha: float = minf(cos_tl, cos_br)
	# Also check TR-BL cross corners for non-square chunks
	var corner_tr: Vector3 = _sphere_positions[edge]
	var corner_bl: Vector3 = _sphere_positions[edge * v_count]
	min_cos_alpha = minf(min_cos_alpha, minf(chunk_dir.dot(corner_tr.normalized()), chunk_dir.dot(corner_bl.normalized())))
	horizon_cos_alpha = min_cos_alpha
	horizon_sin_alpha = sqrt(maxf(0.0, 1.0 - min_cos_alpha * min_cos_alpha))
	# --- AABB including terrain displacement and sphere curvature ---
	# Use 5 points on the ideal sphere: 4 corners + center of the chunk.
	# The center accounts for the sphere bulging outward between corners.
	# Each point also gets a displaced copy (pushed radially by terrain_height)
	# to cover the maximum possible vertex elevation from the shader.
	# Total: 10 points (5 base + 5 displaced) → min/max gives tight AABB.
	var sphere_center: Vector3 = center.normalized() * planet.radius
	var aabb_min := Vector3(INF, INF, INF)
	var aabb_max := Vector3(-INF, -INF, -INF)
	for c in [corner_tl, corner_tr, corner_br, corner_bl, sphere_center]:
		aabb_min = aabb_min.min(c)
		aabb_max = aabb_max.max(c)
		# Include displaced copy (pushed radially by terrain_height)
		var c_top: Vector3 = c + c.normalized() * planet.terrain_height
		aabb_min = aabb_min.min(c_top)
		aabb_max = aabb_max.max(c_top)
	bounding_aabb = AABB(aabb_min, aabb_max - aabb_min)
	# --- Per-vertex data: local positions, normals, colors, UV2 ---
	var simple_color := Color.from_hsv(randf(), 0.7, 0.7, 1.0)
	var noise_coeff: float = 100.0 / planet.radius # Noise space scale (tuned at radius=100)
	var uv2_value := Vector2(corner_tl.distance_to(corner_tr) * noise_coeff / planet.grid_size, 0.0)
	for i in range(grid_vertex_count):
		var sphere_vertex: Vector3 = _sphere_positions[i]
		_local_positions[i] = sphere_vertex - center
		_normals[i] = sphere_vertex.normalized()
		_colors[i] = simple_color
		_uv2[i] = uv2_value
	# --- Skirt ---
	var skirt_depth: float = bounding_radius * SKIRT_DEPTH_FRACTION
	_build_skirt(v_count, planet.grid_size, skirt_depth)
	_upload_to_array_mesh()
	visible = true

## Upload current scratch buffers to the ArrayMesh for rendering.
func _upload_to_array_mesh() -> void:
	var arr_mesh: ArrayMesh = mesh as ArrayMesh
	if arr_mesh == null:
		arr_mesh = ArrayMesh.new()
		mesh = arr_mesh
	else:
		arr_mesh.clear_surfaces()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _local_positions
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_COLOR] = _colors
	arrays[Mesh.ARRAY_TEX_UV2] = _uv2
	arrays[Mesh.ARRAY_INDEX] = _shared_indices
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Use planet-wide AABB to disable Godot's built-in frustum culling.
	# We handle culling ourselves in quad.gd via chunk.visible flag.
	custom_aabb = planet.chunk_custom_aabb

# ===========================================================================
#  Skirt helpers
# ===========================================================================

## Build skirt vertices: duplicate each edge vertex, pushed toward planet center.
## Edge order: top, right, bottom, left (matching skirt index buffer).
func _build_skirt(v_count: int, edge: int, skirt_depth: float) -> void:
	var grid_vertex_count: int = v_count * v_count
	var idx: int = grid_vertex_count
	for x in range(v_count):                                        # Top edge (y=0)
		idx = _write_skirt_vertex(idx, x, skirt_depth)
	for y in range(v_count):                                        # Right edge (x=edge)
		idx = _write_skirt_vertex(idx, edge + y * v_count, skirt_depth)
	for x in range(v_count):                                        # Bottom edge (y=edge, reversed)
		idx = _write_skirt_vertex(idx, (edge - x) + edge * v_count, skirt_depth)
	for y in range(v_count):                                        # Left edge (x=0, reversed)
		idx = _write_skirt_vertex(idx, 0 + (edge - y) * v_count, skirt_depth)

## Write one skirt vertex — flagged with alpha 0.0 so shader skips displacement.
func _write_skirt_vertex(idx: int, grid_index: int, skirt_depth: float) -> int:
	var sphere_vertex: Vector3 = _sphere_positions[grid_index]
	var lowered: Vector3 = sphere_vertex - sphere_vertex.normalized() * skirt_depth
	_local_positions[idx] = lowered - position
	_normals[idx] = _normals[grid_index]
	# Alpha 0.0 flags this as a skirt vertex — shader won't displace it
	var color: Color = _colors[grid_index]
	color.a = 0.0
	_colors[idx] = color
	_uv2[idx] = _uv2[grid_index]
	return idx + 1

# ===========================================================================
#  Math helpers
# ===========================================================================

## Bilinear interpolation of 4 corner positions by (u, v) parameters.
## Corners order: [TL, TR, BR, BL]. u goes right (0→1), v goes down (0→1).
static func _bilinear(chunk_corners: Array[Vector3], u: float, v: float) -> Vector3:
	return (
		chunk_corners[0] * (1.0 - u) * (1.0 - v) +  # TL
		chunk_corners[1] * u * (1.0 - v) +            # TR
		chunk_corners[3] * (1.0 - u) * v +             # BL
		chunk_corners[2] * u * v                       # BR
	)

## Cube-to-sphere projection (no terrain displacement — flat ideal sphere).
func _spherify(v: Vector3) -> Vector3:
	var x2: float = v.x * v.x
	var y2: float = v.y * v.y
	var z2: float = v.z * v.z
	var nx: float = v.x * sqrt(maxf(0.0, 1.0 - y2 * 0.5 - z2 * 0.5 + y2 * z2 / 3.0))
	var ny: float = v.y * sqrt(maxf(0.0, 1.0 - z2 * 0.5 - x2 * 0.5 + z2 * x2 / 3.0))
	var nz: float = v.z * sqrt(maxf(0.0, 1.0 - x2 * 0.5 - y2 * 0.5 + x2 * y2 / 3.0))
	return Vector3(nx * planet.radius, ny * planet.radius, nz * planet.radius)
