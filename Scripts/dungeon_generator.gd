extends Node2D

# Grid and generation settings
const TILE_SIZE: int = 16
const DUNGEON_WIDTH: int = 72
const DUNGEON_HEIGHT: int = 40

const MIN_ROOM_SIZE: int = 5
const MAX_ROOM_SIZE: int = 10
const ROOM_SPACING: int = 2
const MAX_ATTEMPTS: int = 100
const CORRIDOR_WIDTH: int = 3

# Generated dungeon data
var rooms: Array[Rect2i] = []
var floors: Dictionary = {}


func _ready() -> void:
	randomize()
	generate_dungeon()
	queue_redraw()


func generate_dungeon() -> void:
	rooms.clear()
	floors.clear()

	create_rooms(8)
	connect_rooms()

	print("Rooms generated: ", rooms.size())


# Generate rooms without overlapping or getting stuck.
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
				randi_range(1, DUNGEON_WIDTH - room_width - 1),
				randi_range(1, DUNGEON_HEIGHT - room_height - 1)
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

		# Stop trying to place rooms if the area becomes too crowded.
		if not placed:
			print("Could not place another room. Stopping.")
			break


# Check room overlap and spacing.
func room_overlaps_existing(new_room: Rect2i) -> bool:
	for room in rooms:
		if room.grow(ROOM_SPACING).intersects(new_room):
			return true

	return false


# Mark every tile inside a room as floor.
func carve_room(room: Rect2i) -> void:
	for x in range(room.position.x, room.end.x):
		for y in range(room.position.y, room.end.y):
			floors[Vector2i(x, y)] = true


# Connect consecutive rooms with L-shaped corridors.
func connect_rooms() -> void:
	for i in range(rooms.size() - 1):
		var center_a: Vector2i = room_center(rooms[i])
		var center_b: Vector2i = room_center(rooms[i + 1])

		# Travel vertically first, then horizontally.
		carve_vertical_corridor(
			center_a.x, center_a.y, center_b.y
		)

		carve_horizontal_corridor(
			center_b.y, center_a.x, center_b.x
		)


func room_center(room: Rect2i) -> Vector2i:
	return Vector2i(
		room.position.x + room.size.x / 2,
		room.position.y + room.size.y / 2
	)


# Carve a three-tile-wide vertical corridor.
func carve_vertical_corridor(
	x: int, start_y: int, end_y: int
) -> void:
	var top: int = mini(start_y, end_y)
	var bottom: int = maxi(start_y, end_y)

	for y in range(top, bottom + 1):
		for offset in range(-CORRIDOR_WIDTH / 2, CORRIDOR_WIDTH / 2 + 1):
			floors[Vector2i(x + offset, y)] = true


# Carve a three-tile-wide horizontal corridor.
func carve_horizontal_corridor(
	y: int, start_x: int, end_x: int
) -> void:
	var left: int = mini(start_x, end_x)
	var right: int = maxi(start_x, end_x)

	for x in range(left, right + 1):
		for offset in range(-CORRIDOR_WIDTH / 2, CORRIDOR_WIDTH / 2 + 1):
			floors[Vector2i(x, y + offset)] = true


# Draw the generated dungeon.
func _draw() -> void:
	# Draw floors.
	for cell in floors:
		var pixel_position := Vector2(cell * TILE_SIZE)

		draw_rect(
			Rect2(pixel_position, Vector2(TILE_SIZE, TILE_SIZE)),
			Color(0.35, 0.32, 0.29),
			true
		)

	# Draw walls wherever a floor borders an empty tile.
	for cell in floors:
		for offset in [
			Vector2i(0, -1),
			Vector2i(0, 1),
			Vector2i(-1, 0),
			Vector2i(1, 0)
		]:
			var neighbor: Vector2i = cell + offset

			if not floors.has(neighbor):
				var wall_position := Vector2(neighbor * TILE_SIZE)

				draw_rect(
					Rect2(
						wall_position,
						Vector2(TILE_SIZE, TILE_SIZE)
					),
					Color(0.18, 0.17, 0.20),
					true
				)
