extends CharacterBody2D
## AP2DS - placeholder top-down player. Must be a direct child of the dungeon generator node.
## Controls: WASD / arrow keys = move, Space = dash, mouse = aim.

signal room_changed(room_id: int)   # -1 = not inside a room (corridor / doorway)

@export_group("Movement")
@export var max_speed: float = 110.0
@export var acceleration: float = 900.0
@export var friction: float = 1100.0

@export_group("Dash")
@export var dash_speed: float = 280.0
@export var dash_time: float = 0.14
@export var dash_cooldown: float = 0.6

@export_group("Body")
## Collision radius in pixels. Corridors and doorways are 32 px wide, so keep this well under 16.
@export var body_radius: float = 5.0
@export var body_color: Color = Color(0.45, 0.85, 0.9)

var dungeon                          # the parent dungeon_generator node
var aim_dir: Vector2 = Vector2.RIGHT
var current_room_id: int = -1

var _dash_left: float = 0.0
var _dash_cd: float = 0.0
var _dash_vec: Vector2 = Vector2.ZERO


func _ready() -> void:
	dungeon = get_parent()
	z_index = 1                              # above the tile layers and start/exit markers
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING   # top-down: no floor/ceiling logic
	collision_layer = 2                      # the player lives on layer 2
	collision_mask = 1                       # ...and collides with layer 1 (wall tiles)
	_ensure_collision_shape()
	_ensure_input_actions()

	if dungeon != null and dungeon.has_signal("dungeon_generated"):
		dungeon.dungeon_generated.connect(_on_dungeon_generated)
		# In case the dungeon already exists (player added later).
		if dungeon.get_start_room_id() >= 0:
			spawn_at_start()


func _on_dungeon_generated(_success: bool, _used_seed: int) -> void:
	spawn_at_start()


# Teleports the player to the centre of the start room.
func spawn_at_start() -> void:
	var start_id: int = dungeon.get_start_room_id()
	if start_id < 0:
		push_warning("[Player] The dungeon has no start room - nothing to spawn in.")
		return
	position = dungeon.get_room_center_world(start_id)   # local to the dungeon node
	velocity = Vector2.ZERO
	_dash_left = 0.0
	_dash_cd = 0.0
	current_room_id = -2                     # force room_changed to fire for the first room
	_update_current_room()


func _physics_process(delta: float) -> void:
	# Don't move while typing in the seed box (WASD would otherwise still count as input).
	var typing := get_viewport().gui_get_focus_owner() != null
	var dir := Vector2.ZERO
	if not typing:
		dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")

	var to_mouse := get_global_mouse_position() - global_position
	if to_mouse.length() > 1.0:
		aim_dir = to_mouse.normalized()

	_dash_cd = maxf(0.0, _dash_cd - delta)

	if _dash_left > 0.0:
		_dash_left -= delta
		velocity = _dash_vec * dash_speed
	else:
		if not typing and Input.is_action_just_pressed("dash") and _dash_cd <= 0.0 and dir != Vector2.ZERO:
			_dash_vec = dir.normalized()
			_dash_left = dash_time
			_dash_cd = dash_cooldown
			velocity = _dash_vec * dash_speed
		elif dir != Vector2.ZERO:
			velocity = velocity.move_toward(dir * max_speed, acceleration * delta)
		else:
			velocity = velocity.move_toward(Vector2.ZERO, friction * delta)

	move_and_slide()
	_update_current_room()
	queue_redraw()


# Which room (if any) the player is standing in, using the generator's public API.
func _update_current_room() -> void:
	var ts: int = dungeon.tile_size
	var tile := Vector2i(floori(position.x / ts), floori(position.y / ts))
	var found := -1
	for id in range(dungeon.rooms.size()):
		if dungeon.get_room_rect_tiles(id).has_point(tile):
			found = id
			break
	if found != current_room_id:
		current_room_id = found
		room_changed.emit(found)


func _draw() -> void:
	var color := body_color if _dash_cd <= 0.0 else body_color.darkened(0.35)
	draw_circle(Vector2(0, 2), body_radius + 1.0, Color(0, 0, 0, 0.35))      # shadow
	draw_circle(Vector2.ZERO, body_radius, color)
	draw_line(aim_dir * 3.0, aim_dir * (body_radius + 5.0), Color.WHITE, 2.0)  # aim pointer


func _ensure_collision_shape() -> void:
	for child in get_children():
		if child is CollisionShape2D:
			return
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = body_radius
	shape.shape = circle
	add_child(shape)


# Creates the input actions in code, so no Project Settings editing is needed.
# If you already defined actions with these names, yours are left alone.
func _ensure_input_actions() -> void:
	_add_action_if_missing("move_left", [KEY_A, KEY_LEFT])
	_add_action_if_missing("move_right", [KEY_D, KEY_RIGHT])
	_add_action_if_missing("move_up", [KEY_W, KEY_UP])
	_add_action_if_missing("move_down", [KEY_S, KEY_DOWN])
	_add_action_if_missing("dash", [KEY_SPACE])


func _add_action_if_missing(action: StringName, keys: Array) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for key in keys:
		var event := InputEventKey.new()
		event.physical_keycode = key
		InputMap.action_add_event(action, event)
