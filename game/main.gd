extends Node2D
## Godot hand-tracking test: a crosshair follows your index finger, a thumb drop fires.
## Shows live diagnostics so we can judge whether Godot is a good fit for Night Division.

const REACH := 0.18            # edge margin of the camera view that maps to the screen edge
const TRIGGER := 0.42          # thumb-to-index distance (relative to hand size) that fires
const CAMERA_PERMISSION := "android.permission.CAMERA"

var tracker: Object = null
var status_text := "starting"
var hand_seen := false
var last_seen := -10.0
var landmarks := PackedVector3Array()
var frame_aspect := 0.75
var raw_aim := Vector2.ZERO
var aim := Vector2.ZERO
var have_aim := false
var trigger_ratio := 1.0
var cocked := false
var shots := 0
var hits := 0
var flash := 0.0
var flash_pos := Vector2.ZERO
var updates := 0
var tracking_hz := 0.0
var hz_timer := 0.0
var target := Vector2(360, 520)
var target_vel := Vector2(150, 110)
var target_r := 70.0
var pop := 0.0
var pop_pos := Vector2.ZERO
var t := 0.0
var font: Font


func _ready() -> void:
	font = ThemeDB.fallback_font
	get_tree().on_request_permissions_result.connect(_on_permission_result)
	if Engine.has_singleton("HandTracker"):
		tracker = Engine.get_singleton("HandTracker")
		tracker.connect("hand_landmarks", _on_hand_landmarks)
		tracker.connect("status", _on_status)
		if OS.get_granted_permissions().has(CAMERA_PERMISSION):
			tracker.start()
		else:
			status_text = "asking for camera permission"
			OS.request_permissions()
	else:
		status_text = "HandTracker plugin not found. Touch or mouse moves the crosshair."


func _on_permission_result(permission: String, granted: bool) -> void:
	if permission != CAMERA_PERMISSION:
		return
	if granted and tracker:
		tracker.start()
	elif not granted:
		status_text = "camera permission denied"


func _on_status(message: String) -> void:
	status_text = message


## csv = "frameWidth,frameHeight,x0,y0,z0,...,x20,y20,z20" (just the size when no hand is visible)
func _on_hand_landmarks(csv: String) -> void:
	var v := csv.split_floats(",")
	updates += 1
	if v.size() < 2 + 63:
		return
	frame_aspect = v[0] / maxf(v[1], 1.0)
	landmarks.resize(21)
	for i in 21:
		landmarks[i] = Vector3(v[2 + i * 3], v[3 + i * 3], v[4 + i * 3])
	hand_seen = true
	last_seen = t
	_process_hand()


func _dist(a: int, b: int) -> float:
	return Vector2((landmarks[a].x - landmarks[b].x) * frame_aspect, landmarks[a].y - landmarks[b].y).length()


func _process_hand() -> void:
	var size := maxf(_dist(0, 9), 0.001)
	var tip := landmarks[8]
	# The front camera image is not mirrored, so flip x to make the crosshair move like a mirror.
	var nx := clampf(((1.0 - tip.x) - REACH) / (1.0 - 2.0 * REACH), 0.0, 1.0)
	var ny := clampf((tip.y - REACH) / (1.0 - 2.0 * REACH), 0.0, 1.0)
	var vp := get_viewport_rect().size
	raw_aim = Vector2(nx * vp.x, ny * vp.y)
	if not have_aim:
		aim = raw_aim
		have_aim = true
	trigger_ratio = minf(_dist(4, 5), _dist(4, 6)) / size
	if not cocked and trigger_ratio > TRIGGER * 1.45:
		cocked = true
	elif cocked and trigger_ratio < TRIGGER:
		cocked = false
		_fire()


func _fire() -> void:
	shots += 1
	flash = 1.0
	flash_pos = aim
	if aim.distance_to(target) < target_r * 1.25:
		hits += 1
		pop = 1.0
		pop_pos = target
		var vp := get_viewport_rect().size
		target = Vector2(randf_range(120, vp.x - 120), randf_range(320, vp.y - 420))
		target_vel = Vector2(randf_range(-1, 1), randf_range(-1, 1)).normalized() * randf_range(120, 220)


func _input(event: InputEvent) -> void:
	# Fallback for testing without the camera plugin: touch or mouse aims, tap fires.
	if tracker != null and hand_seen:
		return
	if event is InputEventScreenDrag or event is InputEventMouseMotion:
		raw_aim = event.position
		have_aim = true
	elif (event is InputEventScreenTouch and event.pressed) or (event is InputEventMouseButton and event.pressed):
		raw_aim = event.position
		aim = raw_aim
		have_aim = true
		_fire()


func _process(delta: float) -> void:
	t += delta
	if t - last_seen > 0.4:
		hand_seen = false
	aim = aim.lerp(raw_aim, 1.0 - exp(-delta * 16.0))
	hz_timer += delta
	if hz_timer >= 1.0:
		tracking_hz = updates / hz_timer
		updates = 0
		hz_timer = 0.0
	var vp := get_viewport_rect().size
	target += target_vel * delta
	if target.x < target_r or target.x > vp.x - target_r:
		target_vel.x *= -1
	if target.y < 300 or target.y > vp.y - 380:
		target_vel.y *= -1
	target = target.clamp(Vector2(target_r, 300), Vector2(vp.x - target_r, vp.y - 380))
	flash = maxf(0.0, flash - delta * 3.0)
	pop = maxf(0.0, pop - delta * 2.0)
	queue_redraw()


func _draw() -> void:
	var vp := get_viewport_rect().size
	var cyan := Color("#6FF3FF")
	var pink := Color("#FF4FB0")
	var amber := Color("#FFB547")
	var cream := Color("#F3F0FF")
	# background
	draw_rect(Rect2(Vector2.ZERO, vp), Color("#0F1430"))
	for i in 12:
		draw_rect(Rect2(0, vp.y * i / 12.0, vp.x, vp.y / 12.0), Color(0.18, 0.08, 0.35, 0.04 * i))
	draw_string(font, Vector2(30, 70), "Godot hand tracking test", HORIZONTAL_ALIGNMENT_LEFT, -1, 40, cream)
	draw_string(font, Vector2(30, 110), "Point a finger gun. Drop your thumb to fire.", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color(cream, 0.7))

	# target
	var tr := target_r * (1.0 + sin(t * 4.0) * 0.04)
	draw_circle(target, tr * 1.6, Color(pink, 0.12))
	draw_circle(target, tr, Color("#EE4266"))
	draw_circle(target, tr * 0.72, cream)
	draw_circle(target, tr * 0.45, Color("#EE4266"))
	draw_circle(target, tr * 0.2, cream)
	if pop > 0.0:
		draw_arc(pop_pos, target_r * (1.0 + (1.0 - pop) * 2.0), 0, TAU, 48, Color(amber, pop), 6.0)
		draw_string(font, pop_pos + Vector2(-40, -target_r - 20 - (1.0 - pop) * 60), "HIT!", HORIZONTAL_ALIGNMENT_LEFT, -1, 44, Color(amber, pop))

	# crosshair
	if have_aim:
		var col := cyan if (cocked or tracker == null or not hand_seen) else Color(cream, 0.5)
		var r := 34.0 + flash * 14.0
		draw_circle(aim, r * 1.8, Color(cyan, 0.08))
		draw_arc(aim, r, 0, TAU, 48, col, 4.0)
		for k in 4:
			var d := Vector2.from_angle(k * PI / 2 + t)
			draw_line(aim + d * (r - 10), aim + d * (r + 16), col, 4.0)
		if hand_seen and cocked:
			var pull := clampf((TRIGGER * 1.45 - trigger_ratio) / (TRIGGER * 0.45), 0.0, 1.0)
			if pull > 0.05:
				draw_arc(aim, r + 12, -PI / 2, -PI / 2 + TAU * pull, 48, amber, 6.0)
		draw_circle(aim, 5, pink)
	if flash > 0.0:
		draw_circle(flash_pos, 90 * flash, Color(cyan, 0.35 * flash))
		draw_line(Vector2(vp.x / 2, vp.y + 20), flash_pos, Color(1, 1, 1, flash), 10.0 * flash)

	# hand skeleton preview (bottom right)
	var box := Rect2(vp.x - 230, vp.y - 330, 200, 260)
	draw_rect(box, Color(0, 0, 0, 0.45))
	draw_rect(box, Color(cyan, 0.6), false, 2.0)
	if hand_seen and landmarks.size() == 21:
		var chains := [[0, 1, 2, 3, 4], [0, 5, 6, 7, 8], [5, 9, 10, 11, 12], [9, 13, 14, 15, 16], [13, 17, 18, 19, 20], [0, 17]]
		for chain in chains:
			for j in range(1, chain.size()):
				draw_line(_box_point(box, chain[j - 1]), _box_point(box, chain[j]), cyan, 3.0)
		for i in [4, 8]:
			draw_circle(_box_point(box, i), 6, amber)
	else:
		draw_string(font, box.position + Vector2(30, 135), "no hand", HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(cream, 0.6))

	# diagnostics
	var lines := [
		"Status: " + status_text,
		"Tracking: %.0f updates/s" % tracking_hz,
		"FPS: %d" % Engine.get_frames_per_second(),
		"Hand: " + ("yes" if hand_seen else "no"),
		"Trigger: %.2f (fires below %.2f)" % [trigger_ratio, TRIGGER],
		"Hits: %d / %d shots" % [hits, shots],
	]
	var y := vp.y - 300.0
	for line in lines:
		draw_string(font, Vector2(24, y), line, HORIZONTAL_ALIGNMENT_LEFT, vp.x - 280, 24, cream)
		y += 36.0


func _box_point(box: Rect2, i: int) -> Vector2:
	var p := landmarks[i]
	return box.position + Vector2((1.0 - p.x) * box.size.x, p.y * box.size.y)
