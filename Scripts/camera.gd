extends Camera2D
## AP2DS - fixed-zoom follow camera. Must be a descendant of the dungeon generator node.
## M = toggle a whole-dungeon overview (handy for checking generated layouts).

@export_group("Follow")
## Fixed zoom. Use whole numbers (2, 3, 4) so pixel art stays crisp.
@export_range(1.0, 8.0, 0.25) var follow_zoom: float = 3.0
@export var smooth_follow: bool = true
@export_range(1.0, 30.0) var smoothing_speed: float = 8.0

@export_group("Limits")
## Stop the camera at the edge of the rooms instead of the whole empty grid.
@export var limit_to_rooms: bool = true
@export_range(0, 12) var limit_margin_tiles: int = 3

@export_group("Debug")
@export var overview_key: Key = KEY_M

var dungeon: Node
var _overview := false
var _overview_center := Vector2.ZERO
var _shake_time := 0.0
var _shake_total := 0.0
var _shake_amount := 0.0
var _fx_rng := RandomNumberGenerator.new()   # visual only; never touches the dungeon's seeded rng

const NO_LIMIT := 10000000


func _ready() -> void:
	dungeon = _find_dungeon()
	if dungeon == null:
		push_error("[Camera] No dungeon generator found above this camera.")
		return
	_fx_rng.randomize()
	zoom = Vector2.ONE * follow_zoom
	position_smoothing_enabled = smooth_follow
	position_smoothing_speed = smoothing_speed
	limit_smoothed = true
	make_current()
	dungeon.dungeon_generated.connect(_on_dungeon_generated)
	get_viewport().size_changed.connect(_on_viewport_resized)
	_apply_limits()


func _find_dungeon() -> Node:
	var n := get_parent()
	while n != null:
		if n.has_signal("dungeon_generated"):
			return n
		n = n.get_parent()
	return null


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == overview_key:
		_set_overview(not _overview)


func _process(delta: float) -> void:
	var off := Vector2.ZERO
	if _overview:
		off = _overview_center - global_position   # look at the dungeon centre, not the player
	if _shake_time > 0.0:
		_shake_time -= delta
		var strength := clampf(_shake_time / _shake_total, 0.0, 1.0) * _shake_amount
		off += Vector2(_fx_rng.randf_range(-1.0, 1.0), _fx_rng.randf_range(-1.0, 1.0)).round() * strength
	offset = off


## Screen shake for later (hits, explosions): $Camera.shake(3.0, 0.2)
func shake(amount: float, duration: float) -> void:
	_shake_amount = amount
	_shake_total = maxf(duration, 0.01)
	_shake_time = _shake_total


func _on_dungeon_generated(_success: bool, _used_seed: int) -> void:
	_apply_limits()
	if _overview:
		_set_overview(true)
	else:
		call_deferred("_snap_to_player")   # after the player has teleported to the new start room


func _on_viewport_resized() -> void:
	if _overview:
		_set_overview(true)
	else:
		_apply_limits()


# Jump straight to the player instead of gliding across the map after a respawn.
func _snap_to_player() -> void:
	reset_smoothing()


func _set_overview(on: bool) -> void:
	if dungeon == null:
		return
	_overview = on
	if on:
		position_smoothing_enabled = false
		var world := Vector2(dungeon.dungeon_width, dungeon.dungeon_height) * float(dungeon.tile_size)
		var view := get_viewport_rect().size
		zoom = Vector2.ONE * (minf(view.x / world.x, view.y / world.y) * 0.96)
		_overview_center = dungeon.to_global(world * 0.5)
		limit_left = -NO_LIMIT
		limit_top = -NO_LIMIT
		limit_right = NO_LIMIT
		limit_bottom = NO_LIMIT
	else:
		zoom = Vector2.ONE * follow_zoom
		position_smoothing_enabled = smooth_follow
		_apply_limits()
		call_deferred("_snap_to_player")


# Keeps the view inside the dungeon (or just around its rooms).
func _apply_limits() -> void:
	if _overview or dungeon == null:
		return
	var ts := float(dungeon.tile_size)
	var bounds := Rect2(Vector2.ZERO, Vector2(dungeon.dungeon_width, dungeon.dungeon_height) * ts)
	if limit_to_rooms and not dungeon.rooms.is_empty():
		var u: Rect2i = dungeon.rooms[0].rect
		for room in dungeon.rooms:
			u = u.merge(room.rect)
		var tight := Rect2(Vector2(u.position) * ts, Vector2(u.size) * ts).grow((limit_margin_tiles + 1) * ts)
		bounds = tight.intersection(bounds)

	# The limit box must be at least as big as what the camera can see.
	var view := get_viewport_rect().size / zoom
	var box_size := Vector2(maxf(bounds.size.x, view.x), maxf(bounds.size.y, view.y))
	bounds = Rect2(bounds.get_center() - box_size * 0.5, box_size)
	bounds.position += dungeon.global_position   # limits are in global coordinates

	limit_left = floori(bounds.position.x)
	limit_top = floori(bounds.position.y)
	limit_right = ceili(bounds.end.x)
	limit_bottom = ceili(bounds.end.y)
