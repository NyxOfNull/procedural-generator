extends Node2D

const TILE_SIZE: int = 16
const DUNGEON_WIDTH: int = 72
const DUNGEON_HEIGHT: int = 40

const ROOM_COUNT: int = 8
const MIN_ROOM_SIZE: int = 5
const MAX_ROOM_SIZE: int = 10
const ROOM_SPACING: int = 3
const MAX_ATTEMPTS: int = 200

const DOOR_WIDTH: int = 2
const CORRIDOR_WIDTH: int = 2

# Original visual style
const BACKGROUND_COLOR := Color(0.28, 0.28, 0.28)
const ROOM_COLOR := Color(0.39, 0.34, 0.30)
const CORRIDOR_COLOR := Color(0.67, 0.53, 0.34)
const WALL_COLOR := Color(0.16, 0.15, 0.18)

var rooms: Array[Rect2i] = []
var room_floors: Dictionary = {}
var corridor_floors: Dictionary = {}

var regenerate_button: Button


func _ready() -> void:
	randomize()
	_create_regenerate_button()
	generate_dungeon()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.pressed and not event.echo:
			if event.keycode == KEY_R:
				generate_dungeon()


func _create_regenerate_button() -> void:
	regenerate_button = Button.new()
	regenerate_button.text = "Regenerate Dungeon (R)"
	regenerate_button.position = Vector2(12, 12)
	regenerate_button.size = Vector2(190, 32)
	regenerate_button.pressed.connect(generate_dungeon)
	add_child(regenerate_button)


func generate_dungeon() -> void:
	rooms.clear()
	room_floors.clear()
	corridor_floors.clear()

	create_rooms()
	connect_rooms()

	queue_redraw()

	print("Rooms generated: ", rooms.size())
	print("Room tiles: ", room_floors.size())
	print("Corridor tiles: ", corridor_floors.size())


# --------------------------------------------------
# ROOM GENERATION
# --------------------------------------------------

func create_rooms() -> void:
	for i in range(ROOM_COUNT):
		var placed := false

		for attempt in range(MAX_ATTEMPTS):
			var width := randi_range(MIN_ROOM_SIZE, MAX_ROOM_SIZE)
			var height := randi_range(MIN_ROOM_SIZE, MAX_ROOM_SIZE)

			var position := Vector2i(
				randi_range(1, DUNGEON_WIDTH - width - 1),
				randi_range(1, DUNGEON_HEIGHT - height - 1)
			)

			var candidate := Rect2i(
				position,
				Vector2i(width, height)
			)

			if room_overlaps_existing(candidate):
				continue

			rooms.append(candidate)
			placed = true
			break

		if not placed:
			print("Could not place another room.")
			break

	# Carve rooms only after placement is finished.
	for room in rooms:
		for x in range(room.position.x, room.end.x):
			for y in range(room.position.y, room.end.y):
				room_floors[Vector2i(x, y)] = true


func room_overlaps_existing(candidate: Rect2i) -> bool:
	for room in rooms:
		if room.grow(ROOM_SPACING).intersects(candidate):
			return true

	return false


# --------------------------------------------------
# ROOM CONNECTIONS
# --------------------------------------------------

func connect_rooms() -> void:
	if rooms.size() < 2:
		return

	# Build a connected network by repeatedly connecting
	# the nearest unconnected room to the existing network.
	var connected: Array[int] = [0]
	var unconnected: Array[int] = []

	for i in range(1, rooms.size()):
		unconnected.append(i)

	while not unconnected.is_empty():
		var best_from := -1
		var best_to := -1
		var best_distance := INF

		for from_index in connected:
			for to_index in unconnected:
				var a := room_center(rooms[from_index])
				var b := room_center(rooms[to_index])
				var distance := a.distance_squared_to(b)

				if distance < best_distance:
					best_distance = distance
					best_from = from_index
					best_to = to_index

		if best_from == -1 or best_to == -1:
			break

		connect_two_rooms(
			rooms[best_from],
			rooms[best_to]
		)

		connected.append(best_to)
		unconnected.erase(best_to)


func room_center(room: Rect2i) -> Vector2:
	return Vector2(
		room.position.x + room.size.x / 2.0,
		room.position.y + room.size.y / 2.0
	)


# --------------------------------------------------
# DOORWAYS
# --------------------------------------------------

func connect_two_rooms(a: Rect2i, b: Rect2i) -> void:
	var center_a := room_center(a)
	var center_b := room_center(b)

	var direction := center_b - center_a

	var side_a: Vector2i
	var side_b: Vector2i

	# Select the dominant direction between the rooms.
	if abs(direction.x) >= abs(direction.y):
		if direction.x >= 0.0:
			side_a = Vector2i.RIGHT
			side_b = Vector2i.LEFT
		else:
			side_a = Vector2i.LEFT
			side_b = Vector2i.RIGHT
	else:
		if direction.y >= 0.0:
			side_a = Vector2i.DOWN
			side_b = Vector2i.UP
		else:
			side_a = Vector2i.UP
			side_b = Vector2i.DOWN

	var door_a := get_door_position(a, side_a, center_b)
	var door_b := get_door_position(b, side_b, center_a)

	# Doorway tiles are part of the corridor floor.
	carve_doorway(door_a, side_a)
	carve_doorway(door_b, side_b)

	# Start and end just outside the room walls.
	var start := door_a + side_a
	var finish := door_b + side_b

	# Try both possible L-shaped routes.
	var route_a: Array[Vector2i] = [
		start,
		Vector2i(finish.x, start.y),
		finish
	]

	var route_b: Array[Vector2i] = [
		start,
		Vector2i(start.x, finish.y),
		finish
	]

	var score_a := route_score(route_a, a, b)
	var score_b := route_score(route_b, a, b)

	var chosen_route: Array[Vector2i]

	if score_a <= score_b:
		chosen_route = route_a
	else:
		chosen_route = route_b

	carve_route(chosen_route)


func get_door_position(
	room: Rect2i,
	side: Vector2i,
	target: Vector2
) -> Vector2i:
	var half_width := int(DOOR_WIDTH / 2)

	if side == Vector2i.LEFT:
		return Vector2i(
			room.position.x,
			clampi(
				roundi(target.y) - half_width,
				room.position.y + 1,
				room.end.y - DOOR_WIDTH - 1
			)
		)

	if side == Vector2i.RIGHT:
		return Vector2i(
			room.end.x - 1,
			clampi(
				roundi(target.y) - half_width,
				room.position.y + 1,
				room.end.y - DOOR_WIDTH - 1
			)
		)

	if side == Vector2i.UP:
		return Vector2i(
			clampi(
				roundi(target.x) - half_width,
				room.position.x + 1,
				room.end.x - DOOR_WIDTH - 1
			),
			room.position.y
		)

	# DOWN
	return Vector2i(
		clampi(
			roundi(target.x) - half_width,
			room.position.x + 1,
			room.end.x - DOOR_WIDTH - 1
		),
		room.end.y - 1
	)


func carve_doorway(
	door: Vector2i,
	side: Vector2i
) -> void:
	for i in range(DOOR_WIDTH):
		var cell := door

		# The width runs along the wall, not through it.
		if side == Vector2i.LEFT or side == Vector2i.RIGHT:
			cell.y += i
		else:
			cell.x += i

		corridor_floors[cell] = true


# --------------------------------------------------
# CORRIDOR ROUTING
# --------------------------------------------------

func route_score(
	route: Array[Vector2i],
	room_a: Rect2i,
	room_b: Rect2i
) -> int:
	var score := 0

	for i in range(route.size() - 1):
		var start := route[i]
		var finish := route[i + 1]

		for cell in get_line_cells(start, finish):
			for room in rooms:
				if room == room_a or room == room_b:
					continue

				if room.has_point(cell):
					score += 1000

	return score


func carve_route(route: Array[Vector2i]) -> void:
	for i in range(route.size() - 1):
		var start := route[i]
		var finish := route[i + 1]

		for cell in get_line_cells(start, finish):
			carve_corridor(cell, start, finish)


func get_line_cells(
	start: Vector2i,
	finish: Vector2i
) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []

	if start.x == finish.x:
		var top := mini(start.y, finish.y)
		var bottom := maxi(start.y, finish.y)

		for y in range(top, bottom + 1):
			cells.append(Vector2i(start.x, y))

	elif start.y == finish.y:
		var left := mini(start.x, finish.x)
		var right := maxi(start.x, finish.x)

		for x in range(left, right + 1):
			cells.append(Vector2i(x, start.y))

	return cells


func carve_corridor(
	cell: Vector2i,
	start: Vector2i,
	finish: Vector2i
) -> void:
	var horizontal := start.y == finish.y

	# A width of two means two adjacent tiles perpendicular
	# to the direction of travel.
	for offset in range(CORRIDOR_WIDTH):
		var tile := cell

		if horizontal:
			tile.y += offset
		else:
			tile.x += offset

		# Never overwrite a room's floor data.
		if not room_floors.has(tile):
			corridor_floors[tile] = true


# --------------------------------------------------
# DRAWING
# --------------------------------------------------

func _draw() -> void:
	draw_rect(
		Rect2(
			Vector2.ZERO,
			Vector2(DUNGEON_WIDTH, DUNGEON_HEIGHT) * TILE_SIZE
		),
		BACKGROUND_COLOR
	)

	# Draw walls around the combined floor layout first.
	var all_floors: Dictionary = {}

	for cell in room_floors:
		all_floors[cell] = true

	for cell in corridor_floors:
		all_floors[cell] = true

	for cell in all_floors:
		for offset in [
			Vector2i.UP,
			Vector2i.DOWN,
			Vector2i.LEFT,
			Vector2i.RIGHT
		]:
			var neighbor: Vector2i = cell + offset

			if not all_floors.has(neighbor):
				draw_tile(neighbor, WALL_COLOR)

	# Draw room interiors.
	for cell in room_floors:
		draw_tile(cell, ROOM_COLOR)

	# Draw corridor floors and doorways on top.
	for cell in corridor_floors:
		draw_tile(cell, CORRIDOR_COLOR)


func draw_tile(cell: Vector2i, color: Color) -> void:
	draw_rect(
		Rect2(
			Vector2(cell * TILE_SIZE),
			Vector2.ONE * TILE_SIZE
		),
		color
	)
