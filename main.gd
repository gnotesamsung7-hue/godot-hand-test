extends Node2D
## Godot hand-tracking test for Night Division.
## GUN: point your index finger, drop your thumb to fire.
## SWORD: swipe your hand fast across the targets to slash them in half.
## Hold up an open palm (or tap the button at the top) to switch modes.
## Live diagnostics show whether Godot is a good fit.

const REACH := 0.18            # edge margin of the camera view that maps to the screen edge
const TRIGGER := 0.42          # thumb-to-index distance (relative to hand size) that fires
const SWIPE_SPEED := 1.6       # screen-heights per second that counts as a slash
const PALM_HOLD := 0.6         # seconds of open palm to switch modes
const CAMERA_PERMISSION := "android.permission.CAMERA"
const BUTTON := Rect2(440, 36, 250, 64)

var tracker: Object = null
var status_text := "starting"
var hand_seen := false
var last_seen := -10.0
var landmarks := PackedVector3Array()
var frame_aspect := 0.75
var raw_aim := Vector2.ZERO
var aim := Vector2.ZERO
var have_aim := false
var trail: Array = []          # [{p: Vector2, t: float}] recent hand positions
var mode := "sword"
var palm_progress := 0.0
var palm_latched := false
var trigger_ratio := 1.0
var cocked := false
var shots := 0
var hits := 0
var flash := 0.0
var flash_pos := Vector2.ZERO
var slashes: Array = []        # [{a, b, life}]
var halves: Array = []         # [{p, v, ang, spin, r, side, life}]
var sparks: Array = []         # [{p, v, life}]
var last_slash := -10.0
var swipe_speed := 0.0
var updates := 0
var tracking_hz := 0.0
var hz_timer := 0.0
var targets: Array = []        # [{p, v, r}]
var t := 0.0
var font: Font


func _ready() -> void:
	font = ThemeDB.fallback_font
	for i in 3:
		targets.append(_new_target())
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
		status_text = "No camera plugin. Touch to play."


func _new_target() -> Dictionary:
	var vp := Vector2(720, 1280)
	return {
		"p": Vector2(randf_range(110, vp.x - 110), randf_range(330, vp.y - 460)),
		"v": Vector2(randf_range(-1, 1), randf_range(-1, 1)).normalized() * randf_range(90, 170),
		"r": 62.0,
	}


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


func _extended(tip: int, pip: int) -> bool:
	return _dist(0, tip) > _dist(0, pip) * 1.12


func _process_hand() -> void:
	var size := maxf(_dist(0, 9), 0.001)
	var tip := landmarks[8]
	# The front camera image is not mirrored, so flip x to make the crosshair move like a mirror.
	var nx := clampf(((1.0 - tip.x) - REACH) / (1.0 - 2.0 * REACH), 0.0, 1.0)
	var ny := clampf((tip.y - REACH) / (1.0 - 2.0 * REACH), 0.0, 1.0)
	var vp := get_viewport_rect().size
	_move_to(Vector2(nx * vp.x, ny * vp.y))

	# open palm held still switches modes
	var palm := _extended(8, 6) and _extended(12, 10) and _extended(16, 14) and _extended(20, 18)
	if palm and not palm_latched:
		palm_progress = minf(1.0, palm_progress + 1.0 / maxf(tracking_hz, 15.0) / PALM_HOLD)
		if palm_progress >= 1.0:
			_switch_mode()
			palm_latched = true
			palm_progress = 0.0
	else:
		palm_progress = maxf(0.0, palm_progress - 0.15)
		if not palm:
			palm_latched = false

	if mode == "gun":
		trigger_ratio = minf(_dist(4, 5), _dist(4, 6)) / size
		if not cocked and trigger_ratio > TRIGGER * 1.45:
			cocked = true
		elif cocked and trigger_ratio < TRIGGER:
			cocked = false
			_fire()


## Every new hand position: update aim, remember the trail, and check for a fast swipe.
func _move_to(p: Vector2) -> void:
	raw_aim = p
	if not have_aim:
		aim = p
		have_aim = true
	trail.append({"p": p, "t": t})
	while trail.size() > 0 and t - trail[0]["t"] > 0.25:
		trail.pop_front()
	if mode != "sword" or trail.size() < 2:
		return
	# compare against a point roughly 60-150 ms ago
	var old: Dictionary = trail[0]
	for e in trail:
		if t - e["t"] <= 0.15:
			old = e
			break
	var dt: float = t - old["t"]
	if dt < 0.04:
		return
	var vp := get_viewport_rect().size
	swipe_speed = (p - old["p"]).length() / dt / vp.y
	if swipe_speed > SWIPE_SPEED and t - last_slash > 0.22:
		last_slash = t
		_slash(old["p"], p)


func _switch_mode() -> void:
	mode = "sword" if mode == "gun" else "gun"
	cocked = false
	flash = 0.6
	flash_pos = aim


func _fire() -> void:
	shots += 1
	flash = 1.0
	flash_pos = aim
	for tg in targets:
		if aim.distance_to(tg["p"]) < tg["r"] * 1.25:
			_cut(tg, Vector2.RIGHT.rotated(randf() * TAU))
			hits += 1
			return


func _slash(a: Vector2, b: Vector2) -> void:
	shots += 1
	var dir := (b - a).normalized()
	a -= dir * 60.0
	b += dir * 60.0
	slashes.append({"a": a, "b": b, "life": 0.35})
	var cut_any := false
	for tg in targets:
		if _seg_dist(tg["p"], a, b) < tg["r"] + 18.0:
			_cut(tg, dir)
			cut_any = true
	if cut_any:
		hits += 1


func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var k := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.001), 0.0, 1.0)
	return p.distance_to(a + ab * k)


## Split a target into two halves along the slash direction, then respawn it.
func _cut(tg: Dictionary, dir: Vector2) -> void:
	var normal := Vector2(-dir.y, dir.x)
	var ang := dir.angle()
	for side in [-1.0, 1.0]:
		halves.append({"p": tg["p"], "v": normal * side * 260.0 + dir * 120.0 + Vector2(0, -80), "ang": ang,
			"spin": side * randf_range(2.0, 4.0), "r": tg["r"], "side": side, "life": 1.0})
	for i in 14:
		sparks.append({"p": tg["p"], "v": Vector2.RIGHT.rotated(randf() * TAU) * randf_range(150, 420), "life": 0.6})
	var fresh := _new_target()
	tg["p"] = fresh["p"]
	tg["v"] = fresh["v"]


func _input(event: InputEvent) -> void:
	var pos := Vector2(-1, -1)
	var pressed := false
	if event is InputEventScreenTouch and event.pressed:
		pos = event.position; pressed = true
	elif event is InputEventMouseButton and event.pressed:
		pos = event.position; pressed = true
	if pressed and BUTTON.has_point(pos):
		_switch_mode()
		return
	# Fallback for testing without the camera: touch aims, tap fires, fast drag slashes.
	if tracker != null and hand_seen:
		return
	if event is InputEventScreenDrag or event is InputEventMouseMotion:
		_move_to(event.position)
	elif pressed:
		_move_to(pos)
		aim = pos
		if mode == "gun":
			_fire()


func _process(delta: float) -> void:
	t += delta
	if t - last_seen > 0.4:
		hand_seen = false
	aim = aim.lerp(raw_aim, 1.0 - exp(-delta * 18.0))
	hz_timer += delta
	if hz_timer >= 1.0:
		tracking_hz = updates / hz_timer
		updates = 0
		hz_timer = 0.0
	var vp := get_viewport_rect().size
	for tg in targets:
		tg["p"] += tg["v"] * delta
		var r: float = tg["r"]
		if tg["p"].x < r or tg["p"].x > vp.x - r:
			tg["v"].x *= -1
		if tg["p"].y < 300 or tg["p"].y > vp.y - 420:
			tg["v"].y *= -1
		tg["p"] = tg["p"].clamp(Vector2(r, 300), Vector2(vp.x - r, vp.y - 420))
	for h in halves:
		h["v"].y += 900.0 * delta
		h["p"] += h["v"] * delta
		h["ang"] += h["spin"] * delta
		h["life"] -= delta
	halves = halves.filter(func(h): return h["life"] > 0.0)
	for s in sparks:
		s["p"] += s["v"] * delta
		s["v"] *= 0.92
		s["life"] -= delta
	sparks = sparks.filter(func(s): return s["life"] > 0.0)
	for s in slashes:
		s["life"] -= delta
	slashes = slashes.filter(func(s): return s["life"] > 0.0)
	flash = maxf(0.0, flash - delta * 3.0)
	queue_redraw()


func _draw() -> void:
	var vp := get_viewport_rect().size
	var cyan := Color("#6FF3FF")
	var pink := Color("#FF4FB0")
	var amber := Color("#FFB547")
	var cream := Color("#F3F0FF")
	var red := Color("#EE4266")

	draw_rect(Rect2(Vector2.ZERO, vp), Color("#0F1430"))
	for i in 12:
		draw_rect(Rect2(0, vp.y * i / 12.0, vp.x, vp.y / 12.0), Color(0.18, 0.08, 0.35, 0.04 * i))
	draw_string(font, Vector2(30, 70), "Godot hand test", HORIZONTAL_ALIGNMENT_LEFT, -1, 40, cream)
	var help := "Swipe fast across the targets to slash." if mode == "sword" else "Point a finger gun. Drop your thumb to fire."
	draw_string(font, Vector2(30, 112), help, HORIZONTAL_ALIGNMENT_LEFT, vp.x - 60, 24, Color(cream, 0.75))
	draw_string(font, Vector2(30, 146), "Hold an open palm to switch modes.", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(cream, 0.5))

	# mode button
	draw_rect(BUTTON, Color(amber if mode == "sword" else cyan, 0.2))
	draw_rect(BUTTON, amber if mode == "sword" else cyan, false, 3.0)
	draw_string(font, BUTTON.position + Vector2(18, 42), ("SWORD" if mode == "sword" else "GUN") + " - switch", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, cream)

	# targets
	for tg in targets:
		var p: Vector2 = tg["p"]
		var r: float = tg["r"] * (1.0 + sin(t * 4.0 + p.x) * 0.04)
		draw_circle(p, r * 1.5, Color(pink, 0.1))
		draw_circle(p, r, red)
		draw_circle(p, r * 0.72, cream)
		draw_circle(p, r * 0.45, red)
		draw_circle(p, r * 0.2, cream)

	# cut halves
	for h in halves:
		_draw_half(h, red, cream)
	for s in sparks:
		draw_circle(s["p"], 5.0 * s["life"] / 0.6 + 1.0, Color(amber, s["life"] / 0.6))

	# slash streaks
	for s in slashes:
		var k: float = s["life"] / 0.35
		var a: Vector2 = s["a"]
		var b: Vector2 = s["b"]
		var bow := (b - a).orthogonal().normalized() * (b - a).length() * 0.12
		var pts := PackedVector2Array()
		for i in 13:
			var u := i / 12.0
			pts.append(a.lerp(b, u) + bow * sin(u * PI))
		draw_polyline(pts, Color(cyan, 0.35 * k), 30.0 * k, true)
		draw_polyline(pts, Color(0.75, 1, 1, 0.8 * k), 12.0 * k, true)
		draw_polyline(pts, Color(1, 1, 1, k), 4.0 * k, true)

	# hand trail in sword mode
	if mode == "sword" and trail.size() > 1:
		for i in range(1, trail.size()):
			var age: float = t - trail[i]["t"]
			var k := clampf(1.0 - age / 0.25, 0.0, 1.0)
			draw_line(trail[i - 1]["p"], trail[i]["p"], Color(cyan, 0.5 * k), 10.0 * k)

	# cursor: crosshair (gun) or a spirit blade (sword)
	if have_aim:
		if mode == "gun":
			var col := cyan if (cocked or not hand_seen) else Color(cream, 0.5)
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
		else:
			_draw_blade(aim, cyan, amber)
		if palm_progress > 0.02:
			draw_arc(aim, 70, -PI / 2, -PI / 2 + TAU * palm_progress, 48, pink, 6.0)
	if flash > 0.0 and mode == "gun":
		draw_circle(flash_pos, 90 * flash, Color(cyan, 0.35 * flash))
		draw_line(Vector2(vp.x / 2, vp.y + 20), flash_pos, Color(1, 1, 1, flash), 10.0 * flash)

	# hand skeleton preview
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
		("Swipe: %.1f (slash above %.1f)" % [swipe_speed, SWIPE_SPEED]) if mode == "sword" else ("Trigger: %.2f (fires below %.2f)" % [trigger_ratio, TRIGGER]),
		"Hits: %d / %d %s" % [hits, shots, "slashes" if mode == "sword" else "shots"],
	]
	var y := vp.y - 300.0
	for line in lines:
		draw_string(font, Vector2(24, y), line, HORIZONTAL_ALIGNMENT_LEFT, vp.x - 280, 24, cream)
		y += 36.0


func _draw_blade(p: Vector2, cyan: Color, amber: Color) -> void:
	# a short glowing spirit blade, angled along the recent movement
	var dir := Vector2(1, -1).normalized()
	if trail.size() > 1:
		var m: Vector2 = trail[trail.size() - 1]["p"] - trail[0]["p"]
		if m.length() > 20.0:
			dir = m.normalized()
	var tip := p + dir * 70.0
	var base := p - dir * 30.0
	var n := dir.orthogonal()
	draw_circle(p, 60, Color(cyan, 0.1))
	draw_colored_polygon(PackedVector2Array([base + n * 9.0, tip, base - n * 9.0]), Color(0.8, 1, 1, 0.95))
	draw_line(base + n * 22.0, base - n * 22.0, amber, 7.0)
	draw_line(base, base - dir * 26.0, Color("#5A3A24"), 9.0)


func _draw_half(h: Dictionary, red: Color, cream: Color) -> void:
	var alpha: float = clampf(h["life"] * 1.5, 0.0, 1.0)
	var side: float = h["side"]
	var c: Vector2 = h["p"]
	var r: float = h["r"]
	var ang: float = h["ang"]
	for ring in [[1.0, red], [0.72, cream], [0.45, red], [0.2, cream]]:
		var pts := PackedVector2Array()
		var rr: float = r * ring[0]
		for i in 17:
			var a := ang + (0.0 if side > 0 else PI) + PI * i / 16.0
			pts.append(c + Vector2.from_angle(a) * rr)
		draw_colored_polygon(pts, Color(ring[1], alpha))


func _box_point(box: Rect2, i: int) -> Vector2:
	var p := landmarks[i]
	return box.position + Vector2((1.0 - p.x) * box.size.x, p.y * box.size.y)
