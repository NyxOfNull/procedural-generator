extends Node2D

# ==========================================
# SETTINGS
# ==========================================

const TILE_SIZE: int = 16
const DUNGEON_WIDTH: int = 72
const DUNGEON_HEIGHT: int = 40

const MIN_ROOM_SIZE: int = 5
const MAX_ROOM_SIZE: int = 10

const ROOM_SPACING: int = 2
const MAX_ATTEMPTS: int = 100
const ROOM_COUNT: int = 8

# Two tiles wide = 32 pixels.
const CORRIDOR_WIDTH: int = 2


# ==========================================
# COLORS
# ==========================================

const ROOM_COLOR := Color(0.42, 0.36, 0.31)
const CORRIDOR_COLOR := Color(0.68, 0.55, 0.36)
const WALL_COLOR := Color(0.17, 0.16, 0.19)


# ==========================================
# DUNGEON DATA
# ==========================================

var rooms: Array[Rect2i] = []

# Each dictionary stores Vector2i tile coordinates.
var room_tiles: Dictionary = {}
var corridor_tiles: Dictionary = {}
var floors: Dictionary = {}


# ==========================================
# GENERATION
# ==========================================

func _ready() -> void:
	randomize()
	generate_dungeon()


func generate_dungeon() -> void:
	rooms.clear()
	room_tiles.clear()
	corridor_tiles.clear()
	floors.clear()

	create_rooms(ROOM_COUNT)
	connect_rooms()

	print("Rooms generated: ", rooms.size())
	print("Room tiles: ", room_tiles.size())
	print("Corridor tiles: ", corridor_tiles.size())
	print("Total floor tiles: ", floors.size())

	queue_redraw()


# ==========================================
# ROOM GENERATION
# ==========================================

func create_rooms(amount: int) -> void:
	for i in range(amount):
		var placed: bool = false

		for attempt in range(MAX_ATTEMPTS):
			var room_width: int = randi_range(
				MIN_ROOM_SIZE, MAX_ROOM_SIZE
			)

			var room_height: int = randi_range(
				MIN_ROOM_SIZE, MAX_ROOM_SIZE
			)

			var room_position := Vector2i(
				randi_range(
					1, DUNGEON_WIDTH - room_width - 1
				),
				randi_range(
					1, DUNGEON_HEIGHT - room_height - 1
				)
			)

			var candidate := Rect2i(
				room_position,
				Vector2i(room_width, room_height)
			)

			if room_overlaps_existing(candidate):
				continue

			rooms.append(candidate)
			carve_room(candidate)

			placed = true
			break

		if not placed:
			print("Could not place another room.")
			break


func room_overlaps_existing(new_room: Rect2i) -> bool:
	for room in rooms:
		if room.grow(ROOM_SPACING).intersects(new_room):
			return true

	return false


func carve_room(room: Rect2i) -> void:
	for x in range(room.position.x, room.end.x):
		for y in range(room.position.y, room.end.y):
			var cell := Vector2i(x, y)

			room_tiles[cell] = true
			floors[cell] = true


# ==========================================
# CORRIDOR GENERATION
# ==========================================

func connect_rooms() -> void:
	if rooms.size() < 2:
		return

	for i in range(rooms.size() - 1):
		var room_a: Rect2i = rooms[i]
		var room_b: Rect2i = rooms[i + 1]

		var center_a: Vector2i = room_center(room_a)
		var center_b: Vector2i = room_center(room_b)

		# Try both possible L-shaped routes.
		var horizontal_first: Array[Vector2i] = [
			center_a,
			Vector2i(center_b.x, center_a.y),
			center_b
		]

		var vertical_first: Array[Vector2i] = [
			center_a,
			Vector2i(center_a.x, center_b.y),
			center_b
		]

		# Prefer the route that crosses fewer unrelated rooms.
		var horizontal_score: int = route_room_overlap_score(
			horizontal_first, room_a, room_b
		)

		var vertical_score: int = route_room_overlap_score(
			vertical_first, room_a, room_b
		)

		var chosen_route: Array[Vector2i]

		if horizontal_score < vertical_score:
			chosen_route = horizontal_first
		elif vertical_score < horizontal_score:
			chosen_route = vertical_first
		elif randi_range(0, 1) == 0:
			chosen_route = horizontal_first
		else:
			chosen_route = vertical_first

		for j in range(chosen_route.size() - 1):
			carve_corridor_segment(
				chosen_route[j],
				chosen_route[j + 1]
			)


func room_center(room: Rect2i) -> Vector2i:
	return Vector2i(
		room.position.x + int(room.size.x / 2),
		room.position.y + int(room.size.y / 2)
	)


# Score a route by counting how many tiles inside
# unrelated rooms it would pass through.
func route_room_overlap_score(
	route: Array[Vector2i],
	room_a: Rect2i,
	room_b: Rect2i
) -> int:
	var score: int = 0

	for i in range(route.size() - 1):
		var start: Vector2i = route[i]
		var finish: Vector2i = route[i + 1]

		var distance: int = (
			abs(finish.x - start.x)
			+ abs(finish.y - start.y)
		)

		for step in range(distance + 1):
			var cell: Vector2i = start

			if start.x != finish.x:
				cell.x += (
					signi(finish.x - start.x) * step
				)
			else:
				cell.y += (
					signi(finish.y - start.y) * step
				)

			for room in rooms:
				if room == room_a or room == room_b:
					continue

				if room.has_point(cell):
					score += 1

	return score


func carve_corridor_segment(
	start: Vector2i,
	finish: Vector2i
) -> void:
	if start.x == finish.x:
		carve_vertical_corridor(
			start.x, start.y, finish.y
		)
	elif start.y == finish.y:
		carve_horizontal_corridor(
			start.y, start.x, finish.x
		)


# Two-tile-wide vertical corridor.
func carve_vertical_corridor(
	x: int,
	start_y: int,
	end_y: int
) -> void:
	var top: int = mini(start_y, end_y)
	var bottom: int = maxi(start_y, end_y)

	for y in range(top, bottom + 1):
		for offset in range(-1, 1):
			add_corridor_tile(Vector2i(x + offset, y))


# Two-tile-wide horizontal corridor.
func carve_horizontal_corridor(
	y: int,
	start_x: int,
	end_x: int
) -> void:
	var left: int = mini(start_x, end_x)
	var right: int = maxi(start_x, end_x)

	for x in range(left, right + 1):
		for offset in range(-1, 1):
			add_corridor_tile(Vector2i(x, y + offset))


func add_corridor_tile(cell: Vector2i) -> void:
	# Keep corridors inside the dungeon grid.
	if (
		cell.x < 0
		or cell.x >= DUNGEON_WIDTH
		or cell.y < 0
		or cell.y >= DUNGEON_HEIGHT
	):
		return

	corridor_tiles[cell] = true
	floors[cell] = true


# ==========================================
# VISUALIZATION
# ==========================================

func _draw() -> void:
	draw_walls()

	# Draw corridors first.
	for cell in corridor_tiles:
		var pixel_position := Vector2(cell * TILE_SIZE)

		draw_rect(
			Rect2(
				pixel_position,
				Vector2(TILE_SIZE, TILE_SIZE)
			),
			CORRIDOR_COLOR
		)

	# Draw rooms on top so room tiles keep their color
	# even where corridor tiles overlap them.
	for cell in room_tiles:
		var pixel_position := Vector2(cell * TILE_SIZE)

		draw_rect(
			Rect2(
				pixel_position,
				Vector2(TILE_SIZE, TILE_SIZE)
			),
			ROOM_COLOR
		)


func draw_walls() -> void:
	var wall_tiles: Dictionary = {}

	var directions: Array[Vector2i] = [
		Vector2i(0, -1),
		Vector2i(0, 1),
		Vector2i(-1, 0),
		Vector2i(1, 0)
	]

	# Find empty tiles directly beside floors.
	for cell in floors:
		for direction in directions:
			var neighbor: Vector2i = cell + direction

			if not floors.has(neighbor):
				wall_tiles[neighbor] = true

	# Draw walls before the floors.
	for cell in wall_tiles:
		var pixel_position := Vector2(cell * TILE_SIZE)

		draw_rect(
			Rect2(
				pixel_position,
				Vector2(TILE_SIZE, TILE_SIZE)
			),
			WALL_COLOR
		)
