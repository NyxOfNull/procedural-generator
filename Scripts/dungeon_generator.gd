extends Node2D

var room_width : int
var room_height : int 
var room_position : Vector2i

var rooms: Array[Rect2i] = []
var centers: Array[Vector2] = []

var idk: bool

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	create_rooms(4)

	for room in rooms:
		print(room)
	

	for i in range(rooms.size()):
		for j in range(i+1, rooms.size()):
			#if i == j:
				#continue
			idk = rooms[i].intersects(rooms[j])
			print(idk)
			if(idk):
				print("room ", j, " intersects room ", i)

func room_overlaps_existing(new_room: Rect2i) -> bool:
	for room in rooms:
		if room.intersects(new_room):
			return true

	return false

func create_rooms(num):
	rooms.clear()
	for i in range(num):
		var not_valid_room : bool = true
		var room : Rect2i
		
		while not_valid_room:
			room_width = randi_range(5, 20)
			room_height = randi_range(5, 20)
			room_position = Vector2i(randi_range(0, 30), randi_range(0, 20))
			room = Rect2i(room_position, Vector2i(room_width, room_height))
			not_valid_room = room_overlaps_existing(room)
		
		rooms.append(room)
	return

func _draw():
	for room in rooms:
		var scaled_room = Rect2i(
			room.position * 16,
			room.size * 16
		)
		var center: Vector2 = scaled_room.get_center()
		centers.append(center)
		draw_circle(center, 10, Color.CYAN, true)
		draw_rect(scaled_room, Color.MEDIUM_VIOLET_RED, false, 10)
		
	var direction := (centers[0] - centers[1])
	var normalized_direction := direction.normalized()
	var distance := direction.length()
	
	
	draw_line(centers[0], centers[1], Color.AQUA)
	return
	
