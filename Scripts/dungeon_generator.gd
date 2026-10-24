extends Node2D
## AP2DS - Procedural dungeon generator (rooms + corridors), Godot 4.x / GDScript.
##
## HOW IT WORKS (short version, good for a presentation)
##  1. Place non-overlapping rooms. Each room's "footprint" is its floor plus a
##     one-tile wall ring around it.
##  2. Corridors are routed with A* over "anchor" cells. An anchor stands for a
##     corridor_width x corridor_width block of tiles, so the search validates the
##     WHOLE corridor footprint, not just a centerline. Anchors whose block touches
##     any room floor or wall ring are forbidden, so a corridor can never cut
##     through a room or its walls.
##  3. Rooms are linked by a randomized minimum spanning tree (always connected),
##     then a few optional extra links create loops.
##  4. Doorways are gaps in the wall ring, kept away from room corners.
##  5. Walls are derived from the final floor layout.
##  6. A validation pass checks the finished tile grid independently of the
##     generator and reports the result honestly.
##
## CONTROLS: R = new random dungeon | G = debug overlay | H = hide/show HUD
##           Type a seed (number or any text) in the box and press Enter to replay it.

signal dungeon_generated(success: bool, used_seed: int)

# ==================================================================
# CONFIGURATION (also editable in the Inspector)
# ==================================================================

@export_group("Seed")
## If true, the first dungeon uses fixed_seed instead of a random seed.
@export var use_fixed_seed: bool = false
@export var fixed_seed: int = 12345

@export_group("Dungeon")
@export_range(32, 160) var dungeon_width: int = 72
@export_range(20, 100) var dungeon_height: int = 40
@export_range(8, 48) var tile_size: int = 16

@export_group("Rooms")
@export_range(2, 24) var room_count: int = 8
@export_range(3, 20) var min_room_size: int = 5
@export_range(3, 24) var max_room_size: int = 10
## Minimum number of empty tiles between two room floors. A corridor needs
## corridor_width + 2 (two wall rings), so smaller values are raised automatically.
@export_range(1, 12) var room_spacing: int = 4
@export_range(10, 1000) var max_room_placement_attempts: int = 200

@export_group("Corridors")
## Doorways always use the same width as corridors.
@export_range(1, 4) var corridor_width: int = 2
## Wall tiles kept free between a doorway and the room corner.
@export_range(1, 3) var door_corner_margin: int = 1
## Chance that each candidate pair of nearby rooms gets an extra (loop) corridor.
@export_range(0.0, 1.0, 0.01) var extra_connection_chance: float = 0.3
@export_range(0, 8) var max_extra_connections: int = 3

@export_group("Generation")
## Whole-layout retries before settling for the best partial result.
@export_range(1, 100) var max_generation_attempts: int = 30

@export_group("Debug")
@export var show_hud: bool = true
@export var show_debug_overlay: bool = false

# ------------------------------------------------------------------
# Visual style
# ------------------------------------------------------------------
const BACKGROUND_COLOR := Color(0.10, 0.095, 0.11)
const WALL_COLOR := Color(0.20, 0.185, 0.22)       # corner / diagonal walls
const WALL_FACE_COLOR := Color(0.27, 0.25, 0.29)   # walls directly touching floor
const ROOM_COLOR := Color(0.39, 0.34, 0.30)
const CORRIDOR_COLOR := Color(0.60, 0.48, 0.32)
const DOOR_COLOR := Color(0.74, 0.62, 0.42)
const START_COLOR := Color(0.42, 0.78, 0.48)
const EXIT_COLOR := Color(0.85, 0.42, 0.38)
const EDGE_SHADE_COLOR := Color(0.0, 0.0, 0.0, 0.22)
const TREE_LINE_COLOR := Color(1.0, 0.9, 0.3, 0.9)
const EXTRA_LINE_COLOR := Color(0.3, 0.9, 1.0, 0.9)
const FLOOR_NOISE_STRENGTH := 0.08
const ROOM_TONE_RANGE := 0.04

# ------------------------------------------------------------------
# Routing / planning tuning (rarely needs changing)
# ------------------------------------------------------------------
const COST_FRESH := 1.0        # carving brand-new corridor
const COST_REUSE := 0.75       # footprint fully on an existing corridor
const COST_PARTIAL := 1.5      # footprint partly overlapping a corridor (crossings)
const COST_TOUCH := 2.5        # fresh corridor hugging another one (avoids merged wide halls)
const TURN_PENALTY := 2.0      # fewer bends = cleaner corridors
const ENTRY_PENALTY := 5.0     # leaving/entering a doorway sideways instead of straight on
const HEURISTIC_WEIGHT := 0.75 # must be <= cheapest step cost (COST_REUSE) to stay admissible
const MST_JITTER := 0.35       # random weight noise so layouts are not always the same tree
const DOOR_OPTIONS_PER_SIDE := 2
const PREFERRED_DOOR_COMBOS := 8   # door pairs compared before accepting the best one
const MAX_DOOR_COMBOS := 16        # hard cap when nothing has worked yet
const DOOR_MIN_SEPARATION := 4     # clear tiles needed between two doors on one wall
const COST_CRAMPED := 2.0          # corridor block touching a room's wall ring (avoids cramped squeezes)
const EXTRA_MIN_FRESH := 3         # a loop must carve at least this many new blocks (no stubby bridges)
const EXTRA_MAX_FRESH := 24        # ...and at most this many (no long tangles)
const JOIN_DOOR_CLEARANCE := 2     # loops may not join a corridor within this many blocks of a doorway
const MISALIGN_WEIGHT := 1.5       # prefers door pairs that allow straight corridors
const EXTRA_NEIGHBOR_CANDIDATES := 3
const EXTRA_MIN_HOP_DISTANCE := 3  # a loop must shortcut a route of at least this many corridors
const EXTRA_PATH_FACTOR := 1.5
const EXTRA_PATH_SLACK := 6
const MAX_FALLBACK_PAIR_TRIES := 30
const MAX_REPORTED_ERRORS := 12

# Tile types stored in `tiles`
const T_EMPTY := 0
const T_ROOM := 1
const T_CORRIDOR := 2
const T_DOOR := 3

const ROLE_NORMAL := 0
const ROLE_START := 1
const ROLE_EXIT := 2

# Direction order matters: index+1 = clockwise turn, index+3 = counter-clockwise turn.
const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]
const TURNS: Array[int] = [0, 1, 3]

# ==================================================================
# DATA TYPES
# ==================================================================

class DungeonRoom extends RefCounted:
	var id: int = 0
	var rect: Rect2i = Rect2i()        # FLOOR area in tile coordinates (walls are outside it)
	var role: int = 0                  # ROLE_* constant
	var tone: float = 0.0              # per-room brightness variation
	var neighbors: Array[int] = []     # ids of directly connected rooms
	var door_tiles: Array[Vector2i] = []

class Connection extends RefCounted:
	var a: int = 0
	var b: int = 0
	var is_extra: bool = false         # true = loop corridor, false = spanning-tree corridor
	var doors_a: Array[Vector2i] = []
	var doors_b: Array[Vector2i] = []
	var anchors: Array[Vector2i] = []  # corridor path; each anchor = a w*w tile block

class DoorOption extends RefCounted:
	var side: Vector2i = Vector2i.ZERO # outward normal of the wall the door is in
	var tiles: Array[Vector2i] = []    # door gap tiles (inside the wall ring)
	var anchor: Vector2i = Vector2i.ZERO # first corridor block, directly outside the door

class MinHeap extends RefCounted:
	var keys := PackedFloat32Array()
	var vals := PackedInt32Array()

	func is_empty() -> bool:
		return keys.is_empty()

	func push(key: float, val: int) -> void:
		keys.append(key)
		vals.append(val)
		var i := keys.size() - 1
		while i > 0:
			var parent := (i - 1) >> 1
			if keys[parent] <= keys[i]:
				break
			_swap(i, parent)
			i = parent

	func pop() -> int:
		var top := vals[0]
		var last := keys.size() - 1
		keys[0] = keys[last]
		vals[0] = vals[last]
		keys.resize(last)
		vals.resize(last)
		var i := 0
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var m := i
			if l < last and keys[l] < keys[m]:
				m = l
			if r < last and keys[r] < keys[m]:
				m = r
			if m == i:
				break
			_swap(i, m)
			i = m
		return top

	func _swap(i: int, j: int) -> void:
		var k := keys[i]
		keys[i] = keys[j]
		keys[j] = k
		var v := vals[i]
		vals[i] = vals[j]
		vals[j] = v

# ==================================================================
# STATE
# ==================================================================

var rng := RandomNumberGenerator.new()
var current_seed: int = 0

var rooms: Array[DungeonRoom] = []
var connections: Array[Connection] = []

var tiles := PackedByteArray()        # T_* per cell
var room_grid := PackedInt32Array()   # room id per room-floor cell, else -1
var wall_grid := PackedByteArray()    # 0 none, 1 corner/diagonal wall, 2 wall touching floor
var anchor_ok := PackedByteArray()    # 1 = a corridor block may start at this cell
var ring_blocked := PackedByteArray() # 1 = room floor or its wall ring

var start_room_id: int = -1
var exit_room_id: int = -1
var start_exit_distance: float = 0.0

var errors: Array[String] = []
var warnings: Array[String] = []
var generation_ok: bool = false
var all_rooms_connected: bool = false
var status_text: String = ""

var failed_route_searches: int = 0
var _last_path_cost: float = INF

var stat_room_tiles: int = 0
var stat_corridor_tiles: int = 0
var stat_door_tiles: int = 0
var stat_attempts: int = 0
var stat_ms: int = 0
var stat_error_overflow: int = 0

# HUD
var hud: PanelContainer
var regenerate_button: Button
var seed_edit: LineEdit
var status_label: Label
var stats_label: Label

# ==================================================================
# LIFECYCLE / INPUT / UI
# ==================================================================

func _ready() -> void:
	_create_hud()
	var first_seed := fixed_seed if use_fixed_seed else _random_seed()
	generate_dungeon(first_seed)


func _unhandled_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	if mouse != null and mouse.pressed:
		if seed_edit != null and seed_edit.has_focus():
			seed_edit.release_focus()
		return

	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return

	match key.keycode:
		KEY_R:
			generate_new_random_dungeon()
		KEY_G:
			show_debug_overlay = not show_debug_overlay
			queue_redraw()
		KEY_H:
			if hud != null:
				hud.visible = not hud.visible


func _create_hud() -> void:
	if hud != null:
		return  # never create the UI twice

	hud = PanelContainer.new()
	hud.position = Vector2(8, 8)
	hud.visible = show_hud
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.62)
	style.set_content_margin_all(8)
	style.set_corner_radius_all(4)
	hud.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	hud.add_child(box)

	var row := HBoxContainer.new()
	box.add_child(row)

	regenerate_button = Button.new()
	regenerate_button.text = "Regenerate Dungeon (R)"
	regenerate_button.focus_mode = Control.FOCUS_NONE
	regenerate_button.pressed.connect(generate_new_random_dungeon)
	row.add_child(regenerate_button)

	seed_edit = LineEdit.new()
	seed_edit.placeholder_text = "seed + Enter"
	seed_edit.custom_minimum_size = Vector2(120, 0)
	seed_edit.text_submitted.connect(_on_seed_submitted)
	row.add_child(seed_edit)

	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 13)
	box.add_child(status_label)

	stats_label = Label.new()
	stats_label.add_theme_font_size_override("font_size", 12)
	stats_label.custom_minimum_size = Vector2(360, 0)
	stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(stats_label)

	add_child(hud)


func _on_seed_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return
	var parsed_seed: int
	if trimmed.is_valid_int():
		parsed_seed = absi(trimmed.to_int())
	else:
		parsed_seed = trimmed.hash() & 0x7FFFFFFF  # any word works as a seed
	seed_edit.release_focus()
	generate_dungeon(parsed_seed)


func _random_seed() -> int:
	var r := RandomNumberGenerator.new()
	r.randomize()
	return r.randi_range(1, 99999999)


func generate_new_random_dungeon() -> void:
	generate_dungeon(_random_seed())

# ==================================================================
# PUBLIC API (for future game systems)
# ==================================================================

func get_start_room_id() -> int:
	return start_room_id

func get_exit_room_id() -> int:
	return exit_room_id

func get_room_rect_tiles(room_id: int) -> Rect2i:
	return rooms[room_id].rect

func get_room_neighbors(room_id: int) -> Array[int]:
	return rooms[room_id].neighbors

func tile_to_world(cell: Vector2i) -> Vector2:
	return Vector2(cell * tile_size)

func get_room_center_world(room_id: int) -> Vector2:
	var r := rooms[room_id].rect
	return (Vector2(r.position) + Vector2(r.size) * 0.5) * float(tile_size)

func is_walkable_tile(cell: Vector2i) -> bool:
	return _tile_at(cell.x, cell.y) != T_EMPTY

# ==================================================================
# MAIN GENERATION PIPELINE
# ==================================================================

func generate_dungeon(seed_to_use: int = -1) -> void:
	var t_start := Time.get_ticks_msec()
	current_seed = seed_to_use if seed_to_use >= 0 else _random_seed()
	rng = RandomNumberGenerator.new()
	rng.seed = current_seed   # ALL randomness below goes through `rng` => reproducible

	errors.clear()
	warnings.clear()
	stat_error_overflow = 0
	failed_route_searches = 0
	_note_config_adjustments()

	var best_rooms: Array[DungeonRoom] = []
	var best_connections: Array[Connection] = []
	var best_score := -1
	var best_short_rects: Array[Rect2i] = []
	var complete := false
	var attempt_limit := maxi(1, max_generation_attempts)
	stat_attempts = 0

	for attempt in range(attempt_limit):
		stat_attempts = attempt + 1
		var is_last := attempt == attempt_limit - 1

		_begin_attempt()
		_place_rooms()

		# Cheap early retry: if not all rooms fit, try a new placement before paying for routing.
		if rooms.size() < room_count:
			if rooms.size() > best_short_rects.size():
				best_short_rects = _collect_rects()
			if not is_last:
				continue
			if best_short_rects.size() > rooms.size():
				_begin_attempt()
				for r in best_short_rects:
					_add_room(r)

		_stamp_rooms()
		_build_corridor_space()
		_connect_rooms()

		var score := _attempt_score()
		if score > best_score:
			best_score = score
			best_rooms = rooms
			best_connections = connections

		if rooms.size() >= room_count and _all_rooms_in_one_component():
			complete = true
			break

	rooms = best_rooms
	connections = best_connections

	if rooms.size() < room_count:
		warnings.append("Only %d of %d rooms could be placed." % [rooms.size(), room_count])

	var pruned := _prune_to_largest_component()
	if pruned > 0:
		warnings.append("Removed %d room(s) that could not be connected." % pruned)

	_rebuild_tiles()
	_compute_walls()
	_assign_roles()
	_validate_layout()
	_finalize_status(complete, pruned)

	stat_ms = Time.get_ticks_msec() - t_start
	_count_tiles()
	queue_redraw()
	_update_hud()
	_print_report()
	dungeon_generated.emit(generation_ok, current_seed)


func _note_config_adjustments() -> void:
	if _effective_min_room_size() != min_room_size:
		warnings.append("min_room_size raised to %d so every wall can hold a doorway." % _effective_min_room_size())
	if _effective_room_spacing() != room_spacing:
		warnings.append("room_spacing raised to %d so corridors fit between rooms." % _effective_room_spacing())


func _effective_min_room_size() -> int:
	return maxi(min_room_size, corridor_width + 2 * door_corner_margin)


func _effective_room_spacing() -> int:
	return maxi(room_spacing, corridor_width + 2)


func _begin_attempt() -> void:
	# Fresh arrays (not .clear()) so a stored "best attempt" is never modified later.
	var fresh_rooms: Array[DungeonRoom] = []
	var fresh_connections: Array[Connection] = []
	rooms = fresh_rooms
	connections = fresh_connections
	_reset_grids()


func _reset_grids() -> void:
	var cell_count := dungeon_width * dungeon_height
	tiles = PackedByteArray()
	tiles.resize(cell_count)
	tiles.fill(T_EMPTY)
	room_grid = PackedInt32Array()
	room_grid.resize(cell_count)
	room_grid.fill(-1)
	wall_grid = PackedByteArray()
	wall_grid.resize(cell_count)
	wall_grid.fill(0)


func _attempt_score() -> int:
	# Prefer attempts with a bigger connected group, then more rooms.
	return _largest_component().size() * 100 + rooms.size()


func _all_rooms_in_one_component() -> bool:
	return not rooms.is_empty() and _largest_component().size() == rooms.size()

# ==================================================================
# ROOM PLACEMENT
# ==================================================================

func _place_rooms() -> void:
	var min_s := _effective_min_room_size()
	var max_s := maxi(max_room_size, min_s)
	var gap := _effective_room_spacing()

	for _i in range(room_count):
		var placed := false
		for _try in range(max_room_placement_attempts):
			var w := rng.randi_range(min_s, max_s)
			var h := rng.randi_range(min_s, max_s)
			# Floor must keep a 1-tile wall ring fully inside the grid.
			var max_x := dungeon_width - 1 - w
			var max_y := dungeon_height - 1 - h
			if max_x < 1 or max_y < 1:
				continue
			var candidate := Rect2i(rng.randi_range(1, max_x), rng.randi_range(1, max_y), w, h)
			if _room_conflicts(candidate, gap):
				continue
			_add_room(candidate)
			placed = true
			break
		if not placed:
			break  # dungeon is full; stop trying for this attempt


func _room_conflicts(candidate: Rect2i, gap: int) -> bool:
	for room in rooms:
		if _rects_overlap(room.rect.grow(gap), candidate):
			return true
	return false


# Strict overlap on half-open rects (touching edges do NOT overlap).
func _rects_overlap(a: Rect2i, b: Rect2i) -> bool:
	return a.position.x < b.end.x and a.end.x > b.position.x \
		and a.position.y < b.end.y and a.end.y > b.position.y


func _add_room(rect: Rect2i) -> DungeonRoom:
	var room := DungeonRoom.new()
	room.id = rooms.size()
	room.rect = rect
	room.tone = rng.randf_range(-ROOM_TONE_RANGE, ROOM_TONE_RANGE)
	rooms.append(room)
	return room


func _collect_rects() -> Array[Rect2i]:
	var result: Array[Rect2i] = []
	for room in rooms:
		result.append(room.rect)
	return result


func _stamp_rooms() -> void:
	for room in rooms:
		for y in range(room.rect.position.y, room.rect.end.y):
			for x in range(room.rect.position.x, room.rect.end.x):
				var i := y * dungeon_width + x
				tiles[i] = T_ROOM
				room_grid[i] = room.id

# ==================================================================
# CORRIDOR SPACE
# An "anchor" is the top-left tile of a corridor_width x corridor_width block.
# A path of 4-connected anchors, with every block carved, gives a corridor of
# exactly corridor_width tiles with clean square bends.
# ==================================================================

func _build_corridor_space() -> void:
	var blocked := PackedByteArray()
	blocked.resize(dungeon_width * dungeon_height)
	blocked.fill(0)

	# Room floor + 1-tile wall ring is off limits to corridors.
	for room in rooms:
		var ring := room.rect.grow(1)
		for y in range(ring.position.y, ring.end.y):
			for x in range(ring.position.x, ring.end.x):
				blocked[y * dungeon_width + x] = 1

	ring_blocked = blocked
	anchor_ok = PackedByteArray()
	anchor_ok.resize(dungeon_width * dungeon_height)
	anchor_ok.fill(0)

	var w := corridor_width
	# Corridor floor stays inside [1, size-2] so a wall tile always fits outside it.
	for ay in range(1, dungeon_height - w):
		for ax in range(1, dungeon_width - w):
			var free := true
			for dy in range(w):
				for dx in range(w):
					if blocked[(ay + dy) * dungeon_width + ax + dx] == 1:
						free = false
						break
				if not free:
					break
			if free:
				anchor_ok[ay * dungeon_width + ax] = 1


func _anchor_ok_at(x: int, y: int) -> bool:
	if x < 1 or y < 1 or x > dungeon_width - 1 - corridor_width or y > dungeon_height - 1 - corridor_width:
		return false
	return anchor_ok[y * dungeon_width + x] == 1

# ==================================================================
# ROOM GRAPH: MST + EXTRA LOOPS + FALLBACK
# ==================================================================

func _connect_rooms() -> void:
	if rooms.size() < 2:
		return
	for edge in _plan_spanning_edges():
		_try_add_connection(edge.x, edge.y, false)   # failures are repaired below
	_ensure_connectivity()
	_add_extra_connections()


# Prim's algorithm on room-to-room distances with random jitter, so the tree
# varies between seeds instead of always linking the same nearest neighbours.
func _plan_spanning_edges() -> Array[Vector2i]:
	var n := rooms.size()
	var weights := PackedFloat32Array()
	weights.resize(n * n)
	for i in range(n):
		for j in range(i + 1, n):
			var wgt := _room_distance(rooms[i], rooms[j]) * (1.0 + rng.randf() * MST_JITTER)
			weights[i * n + j] = wgt
			weights[j * n + i] = wgt

	var edges: Array[Vector2i] = []
	var in_tree := PackedByteArray()
	in_tree.resize(n)
	in_tree.fill(0)
	in_tree[rng.randi_range(0, n - 1)] = 1

	for _step in range(n - 1):
		var best := INF
		var best_i := -1
		var best_j := -1
		for i in range(n):
			if in_tree[i] == 0:
				continue
			for j in range(n):
				if in_tree[j] == 1:
					continue
				if weights[i * n + j] < best:
					best = weights[i * n + j]
					best_i = i
					best_j = j
		if best_i < 0:
			break
		in_tree[best_j] = 1
		edges.append(Vector2i(best_i, best_j))
	return edges


# Distance between room rectangles (gap) plus a little centre distance.
func _room_distance(a: DungeonRoom, b: DungeonRoom) -> float:
	var dx := maxi(0, maxi(a.rect.position.x - b.rect.end.x, b.rect.position.x - a.rect.end.x))
	var dy := maxi(0, maxi(a.rect.position.y - b.rect.end.y, b.rect.position.y - a.rect.end.y))
	var centers := Vector2(a.rect.get_center() - b.rect.get_center())
	return float(dx + dy) + 0.25 * centers.length()


func _try_add_connection(i: int, j: int, is_extra: bool) -> bool:
	var conn: Connection
	if is_extra:
		conn = _try_join(rooms[i], rooms[j])   # loops reuse existing corridors, no new doors
	else:
		conn = _try_connect(rooms[i], rooms[j], false)
	if conn == null:
		if not is_extra:
			failed_route_searches += 1
		return false
	connections.append(conn)
	if not rooms[i].neighbors.has(j):
		rooms[i].neighbors.append(j)
	if not rooms[j].neighbors.has(i):
		rooms[j].neighbors.append(i)
	return true


# If a planned spanning edge could not be routed, link the separate groups of
# rooms through ANY other pair that works (closest pairs first).
func _ensure_connectivity() -> void:
	var n := rooms.size()
	for _round in range(n * 2):
		var labels := _component_labels()
		var pairs: Array = []
		for i in range(n):
			for j in range(i + 1, n):
				if labels[i] != labels[j]:
					pairs.append([_room_distance(rooms[i], rooms[j]), i, j])
		if pairs.is_empty():
			return  # fully connected
		pairs.sort_custom(func(p, q): return p[0] < q[0])

		var linked := false
		var tries := 0
		for p in pairs:
			if tries >= MAX_FALLBACK_PAIR_TRIES:
				break
			tries += 1
			if _try_add_connection(int(p[1]), int(p[2]), false):
				linked = true
				break
		if not linked:
			return  # genuinely stuck; validation will report it


# Optional loops: nearby rooms that are NOT yet linked and are far apart in the tree.
func _add_extra_connections() -> void:
	if extra_connection_chance <= 0.0 or max_extra_connections <= 0 or rooms.size() < 4:
		return

	var candidates: Array[Vector2i] = []
	var seen := {}
	for i in range(rooms.size()):
		var order: Array = []
		for other in range(rooms.size()):
			if other != i:
				order.append([_room_distance(rooms[i], rooms[other]), other])
		order.sort_custom(func(p, q): return p[0] < q[0])
		for k in range(mini(EXTRA_NEIGHBOR_CANDIDATES, order.size())):
			var other_id: int = order[k][1]
			var key := mini(i, other_id) * 10000 + maxi(i, other_id)
			if seen.has(key):
				continue
			seen[key] = true
			if rooms[i].neighbors.has(other_id):
				continue
			candidates.append(Vector2i(mini(i, other_id), maxi(i, other_id)))

	_shuffle_vectors(candidates)

	var added := 0
	for pair in candidates:
		if added >= max_extra_connections:
			break
		if rng.randf() >= extra_connection_chance:
			continue
		var hops := _hop_distance(pair.x, pair.y)
		if hops < EXTRA_MIN_HOP_DISTANCE:
			continue  # too close in the tree (trivial loop) or unreachable
		if _try_add_connection(pair.x, pair.y, true):
			added += 1


# Fisher-Yates using the SEEDED rng (Array.shuffle() would use the global RNG).
func _shuffle_vectors(list: Array[Vector2i]) -> void:
	for i in range(list.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := list[i]
		list[i] = list[j]
		list[j] = tmp

# ==================================================================
# DOORWAYS
# ==================================================================

# Every legal doorway on a room: on any side, at least door_corner_margin tiles
# from the corners, not crowding another door, with a free corridor block outside.
func _list_door_options(room: DungeonRoom) -> Array[DoorOption]:
	var result: Array[DoorOption] = []
	var r := room.rect
	var w := corridor_width
	var m := door_corner_margin

	for side in DIRS:
		var wall_runs_along_x := side.x == 0   # UP / DOWN walls run along x
		var first := (r.position.x if wall_runs_along_x else r.position.y) + m
		var last := (r.end.x if wall_runs_along_x else r.end.y) - w - m
		var along := Vector2i(1, 0) if wall_runs_along_x else Vector2i(0, 1)

		for t in range(first, last + 1):
			# `origin` = first tile of the doorway, located in the wall ring.
			var origin: Vector2i
			if side.x > 0:
				origin = Vector2i(r.end.x, t)
			elif side.x < 0:
				origin = Vector2i(r.position.x - 1, t)
			elif side.y > 0:
				origin = Vector2i(t, r.end.y)
			else:
				origin = Vector2i(t, r.position.y - 1)

			var option := DoorOption.new()
			option.side = side
			for i in range(w):
				option.tiles.append(origin + along * i)

			# The corridor block starts directly outside the doorway. For LEFT/UP the
			# block extends toward negative coordinates, so shift the anchor back.
			var anchor := origin + side
			if side.x < 0 or side.y < 0:
				anchor += side * (w - 1)
			option.anchor = anchor

			if not _anchor_ok_at(anchor.x, anchor.y):
				continue
			if _door_conflicts(room, option):
				continue
			result.append(option)
	return result


func _door_conflicts(room: DungeonRoom, option: DoorOption) -> bool:
	for existing in room.door_tiles:
		for t in option.tiles:
			var vertical_wall := option.side.x != 0
			var same_wall := (t.x == existing.x) if vertical_wall else (t.y == existing.y)
			if not same_wall:
				continue
			var gap := absi(t.y - existing.y) if vertical_wall else absi(t.x - existing.x)
			if gap <= DOOR_MIN_SEPARATION:
				return true
	return false


# Best few doors per side, ordered by how well they face the target room.
func _rank_door_options(room: DungeonRoom, target: DungeonRoom) -> Array[DoorOption]:
	var target_center := target.rect.get_center()
	var scored: Array = []
	for candidate in _list_door_options(room):
		var dx := absi(candidate.anchor.x - target_center.x)
		var dy := absi(candidate.anchor.y - target_center.y)
		scored.append([float(dx + dy) + rng.randf() * 1.5, candidate])
	scored.sort_custom(func(p, q): return p[0] < q[0])

	var per_side := {}
	var ranked: Array[DoorOption] = []
	for entry in scored:
		var option: DoorOption = entry[1]
		var used: int = per_side.get(option.side, 0)
		if used >= DOOR_OPTIONS_PER_SIDE:
			continue
		per_side[option.side] = used + 1
		ranked.append(option)
	return ranked

# ==================================================================
# CORRIDOR ROUTING
# ==================================================================

# Tries several door pairs, routes each with A*, keeps the cheapest VALID path.
# Nothing is carved unless a path was found, so no orphan doorways are created.
func _try_connect(a: DungeonRoom, b: DungeonRoom, is_extra: bool) -> Connection:
	var options_a := _rank_door_options(a, b)
	var options_b := _rank_door_options(b, a)
	if options_a.is_empty() or options_b.is_empty():
		return null

	var combos: Array = []
	for oa in options_a:
		for ob in options_b:
			var dx := absi(oa.anchor.x - ob.anchor.x)
			var dy := absi(oa.anchor.y - ob.anchor.y)
			# Aligned doors (min(dx,dy) == 0) allow a perfectly straight corridor.
			var score := float(dx + dy) + MISALIGN_WEIGHT * float(mini(dx, dy)) + rng.randf()
			combos.append([score, oa, ob])
	combos.sort_custom(func(p, q): return p[0] < q[0])

	var best_anchors: Array[Vector2i] = []
	var best_cost := INF
	var best_a: DoorOption = null
	var best_b: DoorOption = null
	var tried := 0

	for combo in combos:
		if tried >= MAX_DOOR_COMBOS:
			break
		if tried >= PREFERRED_DOOR_COMBOS and not best_anchors.is_empty():
			break
		tried += 1
		var door_a: DoorOption = combo[1]
		var door_b: DoorOption = combo[2]
		var path := _find_corridor_path(door_a, door_b)
		if path.is_empty():
			continue
		if _last_path_cost < best_cost:
			best_cost = _last_path_cost
			best_anchors = path
			best_a = door_a
			best_b = door_b

	if best_anchors.is_empty():
		return null

	# Loop corridors must stay reasonably direct, otherwise they only add clutter.
	if is_extra:
		var direct := absi(best_a.anchor.x - best_b.anchor.x) + absi(best_a.anchor.y - best_b.anchor.y)
		if best_anchors.size() > int(direct * EXTRA_PATH_FACTOR) + EXTRA_PATH_SLACK:
			return null

	var conn := Connection.new()
	conn.a = a.id
	conn.b = b.id
	conn.is_extra = is_extra
	conn.doors_a = best_a.tiles
	conn.doors_b = best_b.tiles
	conn.anchors = best_anchors
	_stamp_connection(conn)
	return conn


# A* over (anchor cell, travel direction). The direction is part of the state so
# bends can be penalised, which produces long straight corridors with few turns.
# Returns the anchors from door A to door B, or an empty array if no path exists.
@warning_ignore("integer_division")
func _find_corridor_path(door_a: DoorOption, door_b: DoorOption) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	_last_path_cost = INF

	var w := dungeon_width
	var cell_count := dungeon_width * dungeon_height
	var start := door_a.anchor
	var goal := door_b.anchor
	var start_dir := DIRS.find(door_a.side)    # leaving door A: straight outward is free
	var goal_dir := DIRS.find(-door_b.side)    # entering door B: moving toward the room is free
	var start_idx := start.y * w + start.x
	var goal_idx := goal.y * w + goal.x
	var terminal := cell_count * 4             # virtual node meaning "arrived and accepted"

	var g := PackedFloat32Array()
	g.resize(cell_count * 4 + 1)
	g.fill(INF)
	var came := PackedInt32Array()
	came.resize(cell_count * 4 + 1)
	came.fill(-1)
	var closed := PackedByteArray()
	closed.resize(cell_count * 4 + 1)
	closed.fill(0)
	var cost_cache := PackedFloat32Array()
	cost_cache.resize(cell_count)
	cost_cache.fill(-1.0)

	var heap := MinHeap.new()
	var h_start := HEURISTIC_WEIGHT * float(absi(start.x - goal.x) + absi(start.y - goal.y))
	for d in range(4):
		var s0 := start_idx * 4 + d
		g[s0] = 0.0 if d == start_dir else ENTRY_PENALTY
		heap.push(g[s0] + h_start, s0)

	while not heap.is_empty():
		var s := heap.pop()
		if closed[s] == 1:
			continue
		closed[s] = 1

		if s == terminal:
			var cur := came[terminal]
			while cur != -1:
				var cell := cur >> 2
				result.append(Vector2i(cell % w, cell / w))
				cur = came[cur]
			result.reverse()
			_last_path_cost = g[terminal]
			return result

		var ci := s >> 2
		var dir := s & 3

		if ci == goal_idx:
			var finish_cost := g[s] + (0.0 if dir == goal_dir else ENTRY_PENALTY)
			if finish_cost < g[terminal]:
				g[terminal] = finish_cost
				came[terminal] = s
				heap.push(finish_cost, terminal)

		var cx := ci % w
		var cy := ci / w
		for turn in TURNS:
			var nd := (dir + turn) & 3
			var nx := cx + DIRS[nd].x
			var ny := cy + DIRS[nd].y
			if not _anchor_ok_at(nx, ny):
				continue
			var nci := ny * w + nx
			var ns := nci * 4 + nd
			if closed[ns] == 1:
				continue
			var step := cost_cache[nci]
			if step < 0.0:
				step = _compute_anchor_cost(nx, ny)
				cost_cache[nci] = step
			if turn != 0:
				step += TURN_PENALTY
			var ng := g[s] + step
			if ng < g[ns]:
				g[ns] = ng
				came[ns] = s
				heap.push(ng + HEURISTIC_WEIGHT * float(absi(goal.x - nx) + absi(goal.y - ny)), ns)

	return result  # empty = no valid route


# Loop corridor: starts on an existing corridor of room A and ends on an existing
# corridor of room B. It creates NO new doorways, so no wall ever gets a second door.
func _try_join(a: DungeonRoom, b: DungeonRoom) -> Connection:
	var sources := _room_corridor_anchors(a.id)
	var goals := _room_corridor_anchors(b.id)
	if sources.is_empty() or goals.is_empty():
		return null

	var path := _find_join_path(sources, goals)
	if path.size() < 2:
		return null

	# Reject loops that barely add anything or wander too far.
	var fresh := _count_fresh_anchors(path)
	if fresh < EXTRA_MIN_FRESH or fresh > EXTRA_MAX_FRESH:
		return null

	var conn := Connection.new()
	conn.a = a.id
	conn.b = b.id
	conn.is_extra = true
	conn.anchors = path
	_stamp_connection(conn)
	return conn


# Corridor blocks of every corridor that enters this room, except blocks right next
# to a doorway (joining there would look messy).
func _room_corridor_anchors(room_id: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var seen := {}
	for conn in connections:
		if conn.a != room_id and conn.b != room_id:
			continue
		var skip := JOIN_DOOR_CLEARANCE if not conn.doors_a.is_empty() else 0
		for k in range(skip, conn.anchors.size() - skip):
			var anchor := conn.anchors[k]
			var key := anchor.y * dungeon_width + anchor.x
			if seen.has(key):
				continue
			seen[key] = true
			result.append(anchor)
	return result


func _anchor_fully_corridor(ax: int, ay: int) -> bool:
	for dy in range(corridor_width):
		for dx in range(corridor_width):
			if tiles[(ay + dy) * dungeon_width + ax + dx] < T_CORRIDOR:
				return false
	return true


# Number of path blocks that actually carve new floor.
func _count_fresh_anchors(path: Array[Vector2i]) -> int:
	var count := 0
	for anchor in path:
		var fresh := false
		for dy in range(corridor_width):
			for dx in range(corridor_width):
				if tiles[(anchor.y + dy) * dungeon_width + anchor.x + dx] == T_EMPTY:
					fresh = true
		if fresh:
			count += 1
	return count


# Multi-source / multi-goal Dijkstra over (anchor, direction). Walking along or across
# existing corridors is forbidden (except for stepping onto a goal), so the result
# always carves a genuinely new branch instead of sliding along corridors that exist.
@warning_ignore("integer_division")
func _find_join_path(sources: Array[Vector2i], goals: Array[Vector2i]) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var w := dungeon_width
	var cell_count := dungeon_width * dungeon_height

	var is_source := PackedByteArray()
	is_source.resize(cell_count)
	is_source.fill(0)
	var is_goal := PackedByteArray()
	is_goal.resize(cell_count)
	is_goal.fill(0)
	for s in sources:
		is_source[s.y * w + s.x] = 1
	var goal_count := 0
	for g in goals:
		var gi := g.y * w + g.x
		if is_source[gi] == 0:
			is_goal[gi] = 1
			goal_count += 1
	if goal_count == 0:
		return result

	var g_cost := PackedFloat32Array()
	g_cost.resize(cell_count * 4)
	g_cost.fill(INF)
	var came := PackedInt32Array()
	came.resize(cell_count * 4)
	came.fill(-1)
	var closed := PackedByteArray()
	closed.resize(cell_count * 4)
	closed.fill(0)
	var cost_cache := PackedFloat32Array()
	cost_cache.resize(cell_count)
	cost_cache.fill(-1.0)

	var heap := MinHeap.new()
	for s in sources:
		var si := s.y * w + s.x
		for d in range(4):
			g_cost[si * 4 + d] = 0.0
			heap.push(0.0, si * 4 + d)

	while not heap.is_empty():
		var st := heap.pop()
		if closed[st] == 1:
			continue
		closed[st] = 1

		var ci := st >> 2
		var dir := st & 3

		if is_goal[ci] == 1:
			var cur := st
			while cur != -1:
				var cell := cur >> 2
				result.append(Vector2i(cell % w, cell / w))
				cur = came[cur]
			result.reverse()
			return result

		var cx := ci % w
		var cy := ci / w
		for turn in TURNS:
			var nd := (dir + turn) & 3
			var nx := cx + DIRS[nd].x
			var ny := cy + DIRS[nd].y
			if not _anchor_ok_at(nx, ny):
				continue
			var nci := ny * w + nx
			if is_goal[nci] == 0 and _anchor_fully_corridor(nx, ny):
				continue
			var ns := nci * 4 + nd
			if closed[ns] == 1:
				continue
			var step := cost_cache[nci]
			if step < 0.0:
				step = _compute_anchor_cost(nx, ny)
				cost_cache[nci] = step
			if turn != 0:
				step += TURN_PENALTY
			var ng := g_cost[st] + step
			if ng < g_cost[ns]:
				g_cost[ns] = ng
				came[ns] = st
				heap.push(ng, ns)

	return result  # empty = no valid join

# Cost of placing a corridor block at (ax, ay), based on existing corridors.
func _compute_base_cost(ax: int, ay: int) -> float:
	var w := corridor_width
	var overlap := 0
	for dy in range(w):
		var row := (ay + dy) * dungeon_width + ax
		for dx in range(w):
			if tiles[row + dx] >= T_CORRIDOR:   # corridor or door
				overlap += 1
	if overlap == w * w:
		return COST_REUSE      # perfectly on an existing corridor: junctions stay tidy
	if overlap > 0:
		return COST_PARTIAL    # partial overlap: normal at crossings, discouraged for long runs

	# Fresh ground. Penalise running flush against another corridor, which would
	# fuse two corridors into one wide hall without a wall between them.
	for i in range(w):
		if tiles[(ay - 1) * dungeon_width + ax + i] >= T_CORRIDOR \
			or tiles[(ay + w) * dungeon_width + ax + i] >= T_CORRIDOR \
			or tiles[(ay + i) * dungeon_width + ax - 1] >= T_CORRIDOR \
			or tiles[(ay + i) * dungeon_width + ax + w] >= T_CORRIDOR:
			return COST_FRESH + COST_TOUCH
	return COST_FRESH


# Base cost (from existing corridors) plus a penalty for running flush against a room's wall.
func _compute_anchor_cost(ax: int, ay: int) -> float:
	var cost := _compute_base_cost(ax, ay)
	if _anchor_touches_room_ring(ax, ay):
		cost += COST_CRAMPED
	return cost


# True if any tile directly around the corridor block belongs to a room's wall ring.
func _anchor_touches_room_ring(ax: int, ay: int) -> bool:
	var w := corridor_width
	for dy in range(-1, w + 1):
		for dx in range(-1, w + 1):
			if dx >= 0 and dx < w and dy >= 0 and dy < w:
				continue  # the block itself
			if ring_blocked[(ay + dy) * dungeon_width + ax + dx] == 1:
				return true
	return false

# Writes a connection into the tile grid. Used both when a corridor is first
# created and when the grid is rebuilt from scratch (e.g. after pruning).
func _stamp_connection(conn: Connection) -> void:
	var w := corridor_width
	for anchor in conn.anchors:
		for dy in range(w):
			for dx in range(w):
				var i := (anchor.y + dy) * dungeon_width + anchor.x + dx
				if tiles[i] == T_EMPTY:
					tiles[i] = T_CORRIDOR
	for d in conn.doors_a:
		tiles[d.y * dungeon_width + d.x] = T_DOOR
	for d in conn.doors_b:
		tiles[d.y * dungeon_width + d.x] = T_DOOR
	rooms[conn.a].door_tiles.append_array(conn.doors_a)
	rooms[conn.b].door_tiles.append_array(conn.doors_b)

# ==================================================================
# GRAPH HELPERS
# ==================================================================

func _component_labels() -> PackedInt32Array:
	var n := rooms.size()
	var labels := PackedInt32Array()
	labels.resize(n)
	labels.fill(-1)
	var next_label := 0
	for s in range(n):
		if labels[s] != -1:
			continue
		var queue: Array[int] = [s]
		labels[s] = next_label
		var head := 0
		while head < queue.size():
			var cur := queue[head]
			head += 1
			for nb in rooms[cur].neighbors:
				if labels[nb] == -1:
					labels[nb] = next_label
					queue.append(nb)
		next_label += 1
	return labels


# Room ids of the biggest connected group (ties: the group containing the lowest id).
func _largest_component() -> Array[int]:
	var result: Array[int] = []
	var n := rooms.size()
	if n == 0:
		return result
	var labels := _component_labels()
	var counts := PackedInt32Array()
	counts.resize(n)
	counts.fill(0)
	for l in labels:
		counts[l] += 1
	var best_label := 0
	for l in range(n):
		if counts[l] > counts[best_label]:
			best_label = l
	for i in range(n):
		if labels[i] == best_label:
			result.append(i)
	return result


func _hop_distance(from_id: int, to_id: int) -> int:
	if from_id == to_id:
		return 0
	var dist := PackedInt32Array()
	dist.resize(rooms.size())
	dist.fill(-1)
	dist[from_id] = 0
	var queue: Array[int] = [from_id]
	var head := 0
	while head < queue.size():
		var cur := queue[head]
		head += 1
		for nb in rooms[cur].neighbors:
			if dist[nb] == -1:
				dist[nb] = dist[cur] + 1
				if nb == to_id:
					return dist[nb]
				queue.append(nb)
	return -1


func _rebuild_room_graph() -> void:
	for room in rooms:
		room.neighbors.clear()
	for conn in connections:
		if not rooms[conn.a].neighbors.has(conn.b):
			rooms[conn.a].neighbors.append(conn.b)
		if not rooms[conn.b].neighbors.has(conn.a):
			rooms[conn.b].neighbors.append(conn.a)


# Last-resort partial result: keep only the biggest connected group of rooms.
func _prune_to_largest_component() -> int:
	if rooms.is_empty():
		return 0
	var keep := _largest_component()
	if keep.size() == rooms.size():
		return 0
	var removed := rooms.size() - keep.size()

	var remap := {}
	var kept_rooms: Array[DungeonRoom] = []
	for old_id in keep:
		remap[old_id] = kept_rooms.size()
		kept_rooms.append(rooms[old_id])

	var kept_connections: Array[Connection] = []
	for conn in connections:
		if remap.has(conn.a) and remap.has(conn.b):
			conn.a = remap[conn.a]
			conn.b = remap[conn.b]
			kept_connections.append(conn)

	for i in range(kept_rooms.size()):
		kept_rooms[i].id = i
	rooms = kept_rooms
	connections = kept_connections
	_rebuild_room_graph()
	return removed


func _rebuild_tiles() -> void:
	_reset_grids()
	for room in rooms:
		room.door_tiles.clear()
	_stamp_rooms()
	for conn in connections:
		_stamp_connection(conn)


# Walls are DERIVED from the final floor layout: any empty tile within one tile
# (including diagonals, so corners are closed) of a walkable tile becomes a wall.
func _compute_walls() -> void:
	for y in range(dungeon_height):
		for x in range(dungeon_width):
			if tiles[y * dungeon_width + x] == T_EMPTY:
				continue
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var nx := x + dx
					var ny := y + dy
					if nx < 0 or ny < 0 or nx >= dungeon_width or ny >= dungeon_height:
						continue
					var ni := ny * dungeon_width + nx
					if tiles[ni] != T_EMPTY:
						continue
					var level := 2 if (dx == 0 or dy == 0) else 1
					if level > wall_grid[ni]:
						wall_grid[ni] = level

# ==================================================================
# START / EXIT ROOMS
# ==================================================================

# Picks the two rooms that are farthest apart ALONG THE CORRIDORS (shortest path
# through the room graph, Floyd-Warshall; fine for a few dozen rooms).
func _assign_roles() -> void:
	for room in rooms:
		room.role = ROLE_NORMAL
	start_room_id = -1
	exit_room_id = -1
	start_exit_distance = 0.0

	var n := rooms.size()
	if n == 0:
		return
	if n == 1:
		start_room_id = 0
		rooms[0].role = ROLE_START
		return

	var dist := PackedFloat32Array()
	dist.resize(n * n)
	dist.fill(INF)
	for i in range(n):
		dist[i * n + i] = 0.0
	for conn in connections:
		var length := float(conn.anchors.size() + corridor_width)
		dist[conn.a * n + conn.b] = minf(dist[conn.a * n + conn.b], length)
		dist[conn.b * n + conn.a] = minf(dist[conn.b * n + conn.a], length)
	for k in range(n):
		for i in range(n):
			for j in range(n):
				var alt := dist[i * n + k] + dist[k * n + j]
				if alt < dist[i * n + j]:
					dist[i * n + j] = alt

	var best_i := -1
	var best_j := -1
	var best_d := -1.0
	var best_euclid := -1.0
	for i in range(n):
		for j in range(i + 1, n):
			var d := dist[i * n + j]
			if d == INF:
				continue
			var euclid := Vector2(rooms[i].rect.get_center()).distance_to(Vector2(rooms[j].rect.get_center()))
			if d > best_d + 0.001 or (absf(d - best_d) <= 0.001 and euclid > best_euclid):
				best_d = d
				best_euclid = euclid
				best_i = i
				best_j = j

	if best_i < 0:
		best_i = 0
		best_j = n - 1   # disconnected fallback; validation reports the real problem
		best_d = 0.0

	# Start on the left-most of the pair, exit on the other.
	if rooms[best_i].rect.get_center().x > rooms[best_j].rect.get_center().x:
		var tmp := best_i
		best_i = best_j
		best_j = tmp
	start_room_id = best_i
	exit_room_id = best_j
	start_exit_distance = best_d
	rooms[start_room_id].role = ROLE_START
	rooms[exit_room_id].role = ROLE_EXIT

# ==================================================================
# VALIDATION
# Inspects the FINISHED tile grid, independent of how it was generated.
# ==================================================================

func _add_error(message: String) -> void:
	if errors.size() < MAX_REPORTED_ERRORS:
		errors.append(message)
	else:
		stat_error_overflow += 1


func _tile_at(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= dungeon_width or y >= dungeon_height:
		return T_EMPTY
	return tiles[y * dungeon_width + x]


func _is_wall_xy(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= dungeon_width or y >= dungeon_height:
		return false
	return wall_grid[y * dungeon_width + x] != 0


func _validate_layout() -> void:
	all_rooms_connected = false
	var n := rooms.size()
	if n == 0:
		_add_error("No rooms were generated.")
		return

	# 1. Room bounds and spacing.
	var gap := _effective_room_spacing()
	for i in range(n):
		var r := rooms[i].rect
		if r.position.x < 1 or r.position.y < 1 or r.end.x > dungeon_width - 1 or r.end.y > dungeon_height - 1:
			_add_error("Room %d leaves the dungeon bounds." % i)
		for j in range(i + 1, n):
			if _rects_overlap(r.grow(gap), rooms[j].rect):
				_add_error("Rooms %d and %d are closer than the minimum spacing." % [i, j])

	# 2-3. Tile-level checks: borders, corridors inside walls, merged geometry.
	for y in range(dungeon_height):
		for x in range(dungeon_width):
			var t := tiles[y * dungeon_width + x]
			if t == T_EMPTY:
				continue
			if x < 1 or y < 1 or x > dungeon_width - 2 or y > dungeon_height - 2:
				_add_error("Floor tile on the dungeon border at (%d, %d)." % [x, y])
			if t == T_CORRIDOR:
				for room in rooms:
					if room.rect.grow(1).has_point(Vector2i(x, y)):
						_add_error("Corridor tile (%d, %d) intrudes into room %d or its walls." % [x, y, room.id])
						break
			elif t == T_ROOM:
				var rid := room_grid[y * dungeon_width + x]
				for d in DIRS:
					var nt := _tile_at(x + d.x, y + d.y)
					if nt == T_CORRIDOR:
						_add_error("Corridor touches room %d floor directly at (%d, %d)." % [rid, x, y])
					elif nt == T_ROOM and room_grid[(y + d.y) * dungeon_width + x + d.x] != rid:
						_add_error("Rooms %d and %d are merged at (%d, %d)." % [rid, room_grid[(y + d.y) * dungeon_width + x + d.x], x, y])

	# 4. Doorways: on a wall, away from corners, open on both sides.
	var m := door_corner_margin
	for room in rooms:
		var r := room.rect
		for d in room.door_tiles:
			var side := _door_side(r, d)
			if side == Vector2i.ZERO:
				_add_error("Door (%d, %d) of room %d is not on its wall." % [d.x, d.y, room.id])
				continue
			var idx_along := (d.x - r.position.x) if side.x == 0 else (d.y - r.position.y)
			var wall_len := r.size.x if side.x == 0 else r.size.y
			if idx_along < m or idx_along > wall_len - 1 - m:
				_add_error("Door (%d, %d) of room %d is too close to a corner." % [d.x, d.y, room.id])
			var inside := d - side
			var outside := d + side
			if _tile_at(inside.x, inside.y) != T_ROOM:
				_add_error("Door (%d, %d) of room %d does not open into the room." % [d.x, d.y, room.id])
			if _tile_at(outside.x, outside.y) != T_CORRIDOR:
				_add_error("Door (%d, %d) of room %d does not open onto a corridor." % [d.x, d.y, room.id])

	# 5. Every corridor path must be one continuous 4-connected chain.
	for conn in connections:
		for i in range(1, conn.anchors.size()):
			var delta := conn.anchors[i] - conn.anchors[i - 1]
			if absi(delta.x) + absi(delta.y) != 1:
				_add_error("Corridor %d-%d has a gap in its path." % [conn.a, conn.b])
				break

	# 6. Connectivity by flood fill over walkable tiles (not over the room graph).
	var visited := PackedByteArray()
	visited.resize(dungeon_width * dungeon_height)
	visited.fill(0)
	var origin := rooms[0].rect.position
	var stack: Array[Vector2i] = [origin]
	visited[origin.y * dungeon_width + origin.x] = 1
	var reached := 0
	while not stack.is_empty():
		var cell: Vector2i = stack.pop_back()
		reached += 1
		for d in DIRS:
			var nx := cell.x + d.x
			var ny := cell.y + d.y
			if _tile_at(nx, ny) == T_EMPTY:
				continue
			var ni := ny * dungeon_width + nx
			if visited[ni] == 0:
				visited[ni] = 1
				stack.append(Vector2i(nx, ny))

	var walkable_total := 0
	for t in tiles:
		if t != T_EMPTY:
			walkable_total += 1

	var unreachable_rooms := 0
	for room in rooms:
		var p := room.rect.position
		if visited[p.y * dungeon_width + p.x] == 0:
			unreachable_rooms += 1
	all_rooms_connected = unreachable_rooms == 0
	if not all_rooms_connected:
		_add_error("%d room(s) are NOT reachable from room 0 through floor tiles." % unreachable_rooms)
	if reached != walkable_total:
		_add_error("%d floor tile(s) are orphaned (not reachable from room 0)." % (walkable_total - reached))


# Which wall (outward normal) a door tile belongs to, or ZERO if it is on none.
func _door_side(r: Rect2i, d: Vector2i) -> Vector2i:
	if d.x == r.end.x and d.y >= r.position.y and d.y < r.end.y:
		return Vector2i(1, 0)
	if d.x == r.position.x - 1 and d.y >= r.position.y and d.y < r.end.y:
		return Vector2i(-1, 0)
	if d.y == r.end.y and d.x >= r.position.x and d.x < r.end.x:
		return Vector2i(0, 1)
	if d.y == r.position.y - 1 and d.x >= r.position.x and d.x < r.end.x:
		return Vector2i(0, -1)
	return Vector2i.ZERO


func _finalize_status(complete: bool, pruned: int) -> void:
	if not errors.is_empty():
		generation_ok = false
		status_text = "INVALID - validation failed"
	elif rooms.size() < room_count or pruned > 0 or not complete:
		generation_ok = false
		status_text = "PARTIAL - valid but incomplete"
	else:
		generation_ok = true
		status_text = "OK - all checks passed"


func _count_tiles() -> void:
	stat_room_tiles = 0
	stat_corridor_tiles = 0
	stat_door_tiles = 0
	for t in tiles:
		if t == T_ROOM:
			stat_room_tiles += 1
		elif t == T_CORRIDOR:
			stat_corridor_tiles += 1
		elif t == T_DOOR:
			stat_door_tiles += 1

# ==================================================================
# REPORTING / HUD
# ==================================================================

func _stats_lines() -> PackedStringArray:
	var extras := 0
	for conn in connections:
		if conn.is_extra:
			extras += 1
	var lines := PackedStringArray()
	lines.append("Seed: %d" % current_seed)
	lines.append("Rooms: %d / %d    Corridors: %d (%d loops)" % [rooms.size(), room_count, connections.size(), extras])
	lines.append("Tiles: %d room, %d corridor, %d door" % [stat_room_tiles, stat_corridor_tiles, stat_door_tiles])
	if start_room_id >= 0 and exit_room_id >= 0:
		lines.append("Start: room %d    Exit: room %d (route ~%d tiles)" % [start_room_id, exit_room_id, int(start_exit_distance)])
	lines.append("Connectivity: %s" % ("all rooms reachable" if all_rooms_connected else "BROKEN"))
	lines.append("Attempts: %d/%d, failed route searches: %d, %d ms" % [stat_attempts, max_generation_attempts, failed_route_searches, stat_ms])
	return lines


func _update_hud() -> void:
	if status_label == null or stats_label == null:
		return
	if seed_edit != null and not seed_edit.has_focus():
		seed_edit.text = str(current_seed)

	var color := Color(0.55, 0.9, 0.55)
	if not errors.is_empty():
		color = Color(1.0, 0.45, 0.4)
	elif not generation_ok:
		color = Color(1.0, 0.8, 0.35)
	status_label.text = status_text
	status_label.add_theme_color_override("font_color", color)

	var text := "\n".join(_stats_lines())
	for message in errors:
		text += "\nERROR: " + message
	if stat_error_overflow > 0:
		text += "\n(+%d more errors)" % stat_error_overflow
	for message in warnings:
		text += "\nWarning: " + message
	text += "\n[R] new   [G] debug   [H] hide HUD"
	stats_label.text = text


func _print_report() -> void:
	print("[Dungeon] ", status_text)
	for line in _stats_lines():
		print("[Dungeon]   ", line)
	for message in warnings:
		push_warning("[Dungeon] " + message)
	for message in errors:
		push_error("[Dungeon] " + message)

# ==================================================================
# DRAWING
# ==================================================================

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(dungeon_width, dungeon_height) * float(tile_size)), BACKGROUND_COLOR)
	if tiles.size() != dungeon_width * dungeon_height:
		return

	# Walls first.
	for y in range(dungeon_height):
		for x in range(dungeon_width):
			var wv := wall_grid[y * dungeon_width + x]
			if wv != 0:
				_draw_tile(x, y, WALL_FACE_COLOR if wv == 2 else WALL_COLOR)

	# Floors with subtle per-tile and per-room variation, plus edge shading.
	for y in range(dungeon_height):
		for x in range(dungeon_width):
			var i := y * dungeon_width + x
			var t := tiles[i]
			if t == T_EMPTY:
				continue
			var noise := _cell_noise(Vector2i(x, y)) - 0.5
			var color: Color
			if t == T_ROOM:
				color = _shade(ROOM_COLOR, 1.0 + rooms[room_grid[i]].tone + noise * FLOOR_NOISE_STRENGTH)
			elif t == T_CORRIDOR:
				color = _shade(CORRIDOR_COLOR, 1.0 + noise * FLOOR_NOISE_STRENGTH * 0.75)
			else:
				color = DOOR_COLOR
			_draw_tile(x, y, color)
			_draw_floor_edges(x, y)

	_draw_role_markers()
	if show_debug_overlay:
		_draw_debug_overlay()


func _draw_tile(x: int, y: int, color: Color) -> void:
	draw_rect(Rect2(x * tile_size, y * tile_size, tile_size, tile_size), color)


# Thin dark strip on floor edges that touch a wall: gives depth and keeps
# doorway jambs and corridor edges readable at 16 px.
func _draw_floor_edges(x: int, y: int) -> void:
	var ts := float(tile_size)
	var s := ts * 0.125
	var px := x * ts
	var py := y * ts
	if _is_wall_xy(x, y - 1):
		draw_rect(Rect2(px, py, ts, s), EDGE_SHADE_COLOR)
	if _is_wall_xy(x, y + 1):
		draw_rect(Rect2(px, py + ts - s, ts, s), EDGE_SHADE_COLOR)
	if _is_wall_xy(x - 1, y):
		draw_rect(Rect2(px, py, s, ts), EDGE_SHADE_COLOR)
	if _is_wall_xy(x + 1, y):
		draw_rect(Rect2(px + ts - s, py, s, ts), EDGE_SHADE_COLOR)


func _shade(color: Color, factor: float) -> Color:
	return Color(color.r * factor, color.g * factor, color.b * factor)


# Deterministic 0..1 noise per tile (depends on the seed, so a seed always looks the same).
func _cell_noise(cell: Vector2i) -> float:
	var h: int = (cell.x * 73856093) ^ (cell.y * 19349663) ^ (current_seed * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	return float(h & 1023) / 1023.0


func _draw_role_markers() -> void:
	var font := ThemeDB.fallback_font
	var ts := float(tile_size)
	for room in rooms:
		if room.role == ROLE_NORMAL:
			continue
		var is_start := room.role == ROLE_START
		var color := START_COLOR if is_start else EXIT_COLOR
		var rect_px := Rect2(Vector2(room.rect.position) * ts, Vector2(room.rect.size) * ts)
		draw_rect(rect_px, Color(color.r, color.g, color.b, 0.16))
		var center := rect_px.get_center()
		draw_circle(center, ts * 0.55, Color(0, 0, 0, 0.45))
		draw_circle(center, ts * 0.42, color)
		draw_string(font, center + Vector2(-ts * 0.5, ts * 0.2), "S" if is_start else "E",
			HORIZONTAL_ALIGNMENT_CENTER, ts, int(ts * 0.6), Color(0.08, 0.08, 0.08))


func _draw_debug_overlay() -> void:
	var font := ThemeDB.fallback_font
	var ts := float(tile_size)
	var half := corridor_width * 0.5
	for conn in connections:
		if conn.anchors.size() < 2:
			continue
		var points := PackedVector2Array()
		for anchor in conn.anchors:
			points.append((Vector2(anchor) + Vector2(half, half)) * ts)
		draw_polyline(points, EXTRA_LINE_COLOR if conn.is_extra else TREE_LINE_COLOR, 2.0)
	for room in rooms:
		var p := Vector2(room.rect.position) * ts + Vector2(3, 12)
		draw_string(font, p, str(room.id), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)
