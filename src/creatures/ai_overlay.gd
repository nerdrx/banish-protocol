class_name AIOverlay
extends Node3D
## M11 — the in-world half of the AI instrument.
##
## The trace tells you what happened; this tells you what it looked like while it
## was happening, which is the half a reviewer's eyes actually gate on. One of
## these is parented to each hunting process when `--aidebug` or `--aioverlay` is
## on, and it draws, per creature:
##
##   * the STATE LABEL — class, suspicion state, awareness, and the reason for
##     the last transition, so a capture frame is self-describing;
##   * the SIGHT CONE — the real cone, at the real half-angle and range the
##     perception model is using, so a frame showing "it did not see me" can be
##     checked rather than believed;
##   * the LAST-KNOWN POSITION — a marker with a ring whose radius IS the search
##     radius, so confidence decay is visible as the ring growing;
##   * the SEARCH PATH — a line from the creature to whatever it is currently
##     walking to, coloured by why.
##
## Everything is unshaded, depth-test-off and on its own mesh, so it renders in a
## near-black room without lighting and cannot be hidden by the geometry the
## creature is hunting through. It costs nothing when the flags are off because it
## is never constructed.
##
## Deliberately self-contained: it reads only public state off the creature it
## hangs on, so it cannot perturb the simulation it is measuring.

const COLOURS: Dictionary = {
	"UNAWARE": Color(0.45, 0.5, 0.55, 0.85),
	"CURIOUS": Color(0.95, 0.85, 0.3, 0.9),
	"ALERT": Color(1.0, 0.6, 0.15, 0.92),
	"HUNTING": Color(1.0, 0.2, 0.15, 0.95),
	"LOST": Color(0.45, 0.75, 1.0, 0.92),
}

const CONE_SEGMENTS: int = 14
const RING_SEGMENTS: int = 28

## LEGIBILITY (finisher round). Four hunters forced onto one nest printed four
## billboards on top of each other and the frame was unjudgeable — the instrument
## was measuring correctly and communicating nothing.
##
## Three rules fix it, and they are the same three any label layer needs:
##
##   * **Stack by identity.** Each creature's label sits a fixed step higher than
##     the one before it, keyed on `slot_index`, so co-located creatures form a
##     readable column instead of a pile. Deterministic, not a physics solve —
##     the same creature is always at the same height in every frame of a strip,
##     which is what makes a filmstrip comparable frame to frame.
##   * **Cull by distance.** Past `LABEL_FULL` a creature is not the subject of
##     the shot; it keeps its wires but drops to a one-line label, and past
##     `LABEL_CULL` it draws nothing at all.
##   * **Fade by distance**, so the near creature is unmistakably the subject.
const LABEL_STEP: float = 0.62
const LABEL_FULL: float = 22.0
const LABEL_CULL: float = 55.0

var _creature: Antivirus = null
var _label: Label3D = null
var _mesh: MeshInstance3D = null
var _immediate: ImmediateMesh = null
var _material: StandardMaterial3D = null
## Head height, remembered so the label stack can be re-based every frame.
var _head: float = 0.0


static func attach(creature: Antivirus, head: float) -> AIOverlay:
	var overlay: AIOverlay = AIOverlay.new()
	overlay.name = "AIOverlay"
	overlay._creature = creature
	creature.add_child(overlay)
	overlay._build(head)
	return overlay


func _build(head: float) -> void:
	_head = head
	_label = Label3D.new()
	_label.name = "State"
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.pixel_size = 0.0011
	_label.font_size = 44
	_label.outline_size = 12
	_label.modulate = Color.WHITE
	_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	_label.position = Vector3(0.0, head + 0.55, 0.0)
	add_child(_label)

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.no_depth_test = true
	_material.vertex_color_use_as_albedo = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	_immediate = ImmediateMesh.new()
	_mesh = MeshInstance3D.new()
	_mesh.name = "Wires"
	_mesh.mesh = _immediate
	_mesh.material_override = _material
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The wires are drawn in WORLD space (the LKP is a world point and must not
	# ride the creature's yaw), so the instance sits at the origin of the world
	# rather than inheriting the body's transform.
	_mesh.top_level = true
	add_child(_mesh)


func _process(_delta: float) -> void:
	if _creature == null or not is_instance_valid(_creature):
		return
	# Distance to the eye that is going to read this, which is the only thing that
	# decides how much detail is worth drawing.
	var camera: Camera3D = get_viewport().get_camera_3d()
	var eye_distance: float = 0.0 if camera == null \
			else camera.global_position.distance_to(_creature.global_position)
	if eye_distance > LABEL_CULL:
		_label.visible = false
		_mesh.visible = false
		return
	_label.visible = true
	_mesh.visible = true

	var report: Dictionary = _creature.ai_report()
	if report.is_empty():
		return
	_draw_label(report, eye_distance)
	_draw_wires(report, eye_distance)


func _draw_label(report: Dictionary, eye_distance: float) -> void:
	var state: String = String(report.get("state", "UNAWARE"))
	var colour: Color = COLOURS.get(state, Color.WHITE)
	# Near creatures read at full strength; far ones recede so the subject of the
	# frame is never ambiguous.
	var fade: float = clampf(1.0 - (eye_distance - LABEL_FULL) / (LABEL_CULL - LABEL_FULL),
			0.35, 1.0)
	_label.modulate = Color(colour.r, colour.g, colour.b, colour.a * fade)

	# The stack. Keyed on slot index so co-located hunters column up in a stable
	# order rather than overprinting — and so the same creature sits at the same
	# height in every frame of a filmstrip.
	_label.position.y = _head + 0.55 + float(_creature.slot_index % 6) * LABEL_STEP

	var lines: PackedStringArray = PackedStringArray()
	lines.append("%s · %s" % [String(report.get("kind", "?")).to_upper(), state])
	if eye_distance <= LABEL_FULL:
		# Full read, for the creature the shot is actually about.
		lines.append("aware %.2f  see %.2f  hear %.2f" % [
			float(report.get("awareness", 0.0)), float(report.get("sight", 0.0)),
			float(report.get("hearing", 0.0))])
		var conf: float = float(report.get("confidence", 0.0))
		if conf > 0.0:
			lines.append("LKP conf %.2f  r %.1fm" % [conf, float(report.get("radius", 0.0))])
		var why: String = String(report.get("why", ""))
		if not why.is_empty():
			lines.append("why: " + why)
	_label.text = "\n".join(lines)


func _draw_wires(report: Dictionary, eye_distance: float) -> void:
	_immediate.clear_surfaces()
	_immediate.surface_begin(Mesh.PRIMITIVE_LINES)

	var state: String = String(report.get("state", "UNAWARE"))
	var base: Color = COLOURS.get(state, Color.WHITE)
	var wire_fade: float = clampf(1.0 - (eye_distance - LABEL_FULL) / (LABEL_CULL - LABEL_FULL),
			0.3, 1.0)
	var colour: Color = Color(base.r, base.g, base.b, base.a * wire_fade)
	var eye: Vector3 = report.get("eye", _creature.global_position)

	# The sight cone, at the model's real half-angle and range.
	var facing: float = _creature.rotation.y
	var half: float = deg_to_rad(float(report.get("cone_deg", 60.0)))
	var reach: float = float(report.get("sight_range", 12.0))
	var cone: Color = Color(colour.r, colour.g, colour.b, 0.32)
	for i: int in CONE_SEGMENTS + 1:
		var t: float = float(i) / float(CONE_SEGMENTS)
		var yaw: float = facing - half + 2.0 * half * t
		var edge: Vector3 = eye + Vector3(-sin(yaw), 0.0, -cos(yaw)) * reach
		if i == 0 or i == CONE_SEGMENTS:
			_line(eye, edge, cone)
		if i < CONE_SEGMENTS:
			var next_yaw: float = facing - half + 2.0 * half * (float(i + 1) / float(CONE_SEGMENTS))
			_line(edge, eye + Vector3(-sin(next_yaw), 0.0, -cos(next_yaw)) * reach, cone)

	# The last-known position and its confidence ring. The ring's radius IS the
	# search radius, so watching it swell is watching the creature get less sure.
	var lkp: Vector3 = report.get("lkp", Vector3.INF)
	if lkp != Vector3.INF:
		var lkp_colour: Color = Color(1.0, 0.35, 0.9, 0.9)
		_line(lkp + Vector3(-0.7, 0.05, 0.0), lkp + Vector3(0.7, 0.05, 0.0), lkp_colour)
		_line(lkp + Vector3(0.0, 0.05, -0.7), lkp + Vector3(0.0, 0.05, 0.7), lkp_colour)
		_line(lkp + Vector3(0.0, 0.05, 0.0), lkp + Vector3(0.0, 2.0, 0.0), lkp_colour)
		var radius: float = float(report.get("radius", 0.0))
		var faint: Color = Color(lkp_colour.r, lkp_colour.g, lkp_colour.b, 0.28)
		for i: int in RING_SEGMENTS:
			var a: float = TAU * float(i) / float(RING_SEGMENTS)
			var b: float = TAU * float(i + 1) / float(RING_SEGMENTS)
			_line(lkp + Vector3(cos(a), 0.05, sin(a)) * radius,
					lkp + Vector3(cos(b), 0.05, sin(b)) * radius, faint)

	# Where it is walking, and the spots it has already ruled out.
	var goal: Vector3 = report.get("goal", Vector3.INF)
	if goal != Vector3.INF:
		_line(eye, goal + Vector3.UP * 0.4, colour)
		_line(goal + Vector3(-0.4, 0.05, -0.4), goal + Vector3(0.4, 0.05, 0.4), colour)
		_line(goal + Vector3(-0.4, 0.05, 0.4), goal + Vector3(0.4, 0.05, -0.4), colour)

	var done: Array = report.get("searched", [])
	var grey: Color = Color(0.55, 0.55, 0.6, 0.5)
	for entry: Variant in done:
		var spot: Vector3 = entry
		_line(spot + Vector3(-0.3, 0.05, 0.0), spot + Vector3(0.3, 0.05, 0.0), grey)
		_line(spot + Vector3(0.0, 0.05, -0.3), spot + Vector3(0.0, 0.05, 0.3), grey)

	_immediate.surface_end()


func _line(from: Vector3, to: Vector3, colour: Color) -> void:
	_immediate.surface_set_color(colour)
	_immediate.surface_add_vertex(from)
	_immediate.surface_set_color(colour)
	_immediate.surface_add_vertex(to)
