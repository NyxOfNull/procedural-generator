extends Node2D

var room_width : int
var room_height : int 
var room_position : Vector2i

var rooms: Array[Rect2i] = []

var idk: bool

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	create_rooms(4)

	for room in rooms:
		print(room)
	
	#for i in range(rooms.size()):
		#if i == 0:
			#continue
		#idk = rooms[i - 1].intersects(rooms[i])
		#print(idk)
		#if(idk):
			#print("room ", i-1, " intersects room ", i)

	for i in range(rooms.size()):
		for j in range(i+1, rooms.size()):
			#if i == j:
				#continue
			idk = rooms[i].intersects(rooms[j])
			print(idk)
			if(idk):
				print("room ", j, " intersects room ", i)
			


	#print("Dungeon generator is ready!")
	#print("Room position: ", room_position)
	#print("Room size: ", room_width, " x ", room_height)
	#print("Room rectangle: ", room)

func create_rooms(num):
	rooms.clear()
	for i in range(num):
		room_width = randi_range(5, 20)
		room_height = randi_range(5, 20)
		room_position = Vector2i(randi_range(0, 20), randi_range(0, 20))
		var room := Rect2i(room_position, Vector2i(room_width, room_height))
		rooms.append(room)
	return
