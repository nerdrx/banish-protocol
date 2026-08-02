class_name WorldPrompt
extends Node3D
## An interaction prompt that lives **on the object**, not in the middle of your
## screen.
##
## M3.8 (DESIGN.md "diegetic program-shell UI"): a program shell would not print
## "HOLD E · SIPHON TAP" across the centre of its own lens. It would tag the
## machine. So every Interactable grows one of these — a small marker glyph, a
## keycap ring with the key in it, and a short title beside it — floating above
## the thing it names, fading in as you approach and turn toward it, and filling
## its ring while you channel.
##
## Everything about it is local presentation. It is created on every peer, reads
## only its owner's public prompt API, and writes nothing.
##
## Facing: the whole node turns to the lens once a frame, so the ring, the key
## and the title stay a single laid-out group instead of three independently
## billboarded pieces sliding past each other.

## Quad size in metres. The ring inside it is 0.6 of this across.
const RING_SIZE: float = 0.62
## Where the title sits, relative to the ring's centre.
const TITLE_OFFSET: Vector3 = Vector3(0.44, 0.0, 0.0)
## And the category glyph, just clear of the frame's top bracket. Further out
## than this and it stops reading as part of the same tag.
const GLYPH_OFFSET: Vector3 = Vector3(0.0, 0.36, 0.0)

const KEY_FONT_SIZE: int = 26
const TITLE_FONT_SIZE: int = 22
const GLYPH_FONT_SIZE: int = 18
## Label3D metres-per-pixel. 0.0045 puts a 22 pt title at ~10 cm tall, which is
## readable at six metres and unreadable at twenty — exactly the falloff wanted.
const PIXEL_SIZE: float = 0.0045

## Text is only re-read this often. `prompt_title()` formats a string on some
## interactables (the shaft counts the crew), and that is not something to do
## sixty times a second for a label that changes twice a run.
const TEXT_REFRESH: float = 0.1

static var _ring_shader: Shader = preload("res://src/shaders/nv_prompt_ring.gdshader")
static var _ui_font: Font = preload("res://assets/fonts/ui_font_wide.tres")

var _owner: Interactable = null
var _ring: MeshInstance3D = null
var _ring_material: ShaderMaterial = null
var _key: Label3D = null
var _title: Label3D = null
var _glyph: Label3D = null

var _alpha: float = 0.0
var _progress: float = 0.0
var _ready_state: bool = true
var _text_clock: float = 0.0
var _last_title: String = ""
var _last_key: String = ""
var _base_height: float = 0.0


## Builds a prompt for `host`, unparented. The caller decides when it enters the
## tree, which matters: an interactable assembles itself before `_ready`.
static func create(host: Interactable) -> WorldPrompt:
	var prompt: WorldPrompt = WorldPrompt.new()
	prompt.name = "WorldPrompt"
	prompt._owner = host
	prompt._assemble()
	return prompt


func _assemble() -> void:
	position = _owner.prompt_anchor()
	_base_height = position.y

	_ring_material = ShaderMaterial.new()
	_ring_material.shader = _ring_shader
	_ring_material.set_shader_parameter("tint", UiFx.SYSTEM)
	_ring_material.set_shader_parameter("warn_tint", UiFx.WARNING)
	_ring_material.set_shader_parameter("alpha", 0.0)

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(RING_SIZE, RING_SIZE)
	_ring = MeshInstance3D.new()
	_ring.name = "Ring"
	_ring.mesh = quad
	_ring.material_override = _ring_material
	# A prompt is furniture, not a light source: it must not bounce into GI or
	# throw a shadow of a floating rectangle across the machine it labels.
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(_ring)

	_key = _label(_owner.prompt_key(), KEY_FONT_SIZE, UiFx.TEXT,
			HORIZONTAL_ALIGNMENT_CENTER)
	_key.position = Vector3(0.0, 0.0, 0.004)
	add_child(_key)

	_title = _label(_owner.prompt_title(), TITLE_FONT_SIZE, UiFx.TEXT,
			HORIZONTAL_ALIGNMENT_LEFT)
	_title.position = TITLE_OFFSET
	add_child(_title)

	_glyph = _label(_owner.prompt_glyph(), GLYPH_FONT_SIZE, UiFx.SYSTEM,
			HORIZONTAL_ALIGNMENT_CENTER)
	_glyph.position = GLYPH_OFFSET
	add_child(_glyph)

	_last_title = _title.text
	_last_key = _key.text
	visible = false


func _label(text: String, font_size: int, colour: Color,
		align: HorizontalAlignment) -> Label3D:
	var label: Label3D = Label3D.new()
	label.text = text
	label.font = _ui_font
	label.font_size = font_size
	label.pixel_size = PIXEL_SIZE
	label.modulate = colour
	# Enough to hold the glyphs against a lit wall, not so much that the letters
	# thicken into blobs at four metres.
	label.outline_size = 6
	label.outline_modulate = Color(0.0, 0.01, 0.02, 0.85)
	label.horizontal_alignment = align
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Billboarding is the node's job, not the label's — see the class docs.
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.shaded = false
	label.double_sided = false
	label.no_depth_test = false
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Titles run to the right of the ring; centring their origin would push half
	# the text back over the keycap.
	if align == HORIZONTAL_ALIGNMENT_LEFT:
		label.offset = Vector2(0.0, 0.0)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return label


## Channel fill, forwarded from Interactable.set_channel_visual.
func set_progress(value: float) -> void:
	_progress = clampf(value, 0.0, 1.0)


func _process(delta: float) -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null or not is_instance_valid(camera):
		if visible:
			visible = false
		return

	var to_prompt: Vector3 = global_position - camera.global_position
	var distance: float = to_prompt.length()
	var target: float = _target_alpha(camera, to_prompt, distance)
	_alpha = UiFx.chase(_alpha, target, UiFx.PROMPT_FADE_RATE, delta)

	if _alpha <= 0.004:
		if visible:
			visible = false
		return
	if not visible:
		visible = true

	_face(camera)
	_float()
	_refresh_text(delta)

	_ring_material.set_shader_parameter("alpha", _alpha)
	_ring_material.set_shader_parameter("progress", _progress)
	_ring_material.set_shader_parameter("ready", 1.0 if _ready_state else 0.0)
	_ring_material.set_shader_parameter("breathe",
			0.5 + 0.5 * sin(UiFx.clock() * 1.4))

	var body: Color = UiFx.TEXT if _ready_state else UiFx.WARNING
	body.a = _alpha
	_title.modulate = body
	_key.modulate = Color(UiFx.TEXT.r, UiFx.TEXT.g, UiFx.TEXT.b, _alpha)
	_glyph.modulate = Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, _alpha * 0.85)


## Distance and view-angle falloff, with one override: whatever the crosshair is
## actually on is always fully legible, however far off-axis the maths says it
## is. A prompt that fades out while you are channelling it would be absurd.
func _target_alpha(camera: Camera3D, to_prompt: Vector3, distance: float) -> float:
	if not _owner.prompt_visible():
		return 0.0
	if _owner.focused:
		return 1.0
	if distance < 0.05:
		return 0.0

	var by_distance: float = clampf(inverse_lerp(
			UiFx.PROMPT_FADE_FAR, UiFx.PROMPT_FADE_NEAR, distance), 0.0, 1.0)
	if by_distance <= 0.0:
		return 0.0

	var forward: Vector3 = -camera.global_transform.basis.z
	var cosine: float = clampf(forward.dot(to_prompt / distance), -1.0, 1.0)
	var degrees: float = rad_to_deg(acos(cosine))
	var by_angle: float = clampf(inverse_lerp(
			UiFx.PROMPT_ANGLE_FAR_DEG, UiFx.PROMPT_ANGLE_NEAR_DEG, degrees), 0.0, 1.0)
	# Never fully solid unless it is the focus: an ambient prompt is a hint.
	return by_distance * by_angle * 0.8


## Turn the whole group to the lens. `look_at` aims -Z at its target and a
## QuadMesh faces +Z, so the target is the point mirrored *through* the prompt.
func _face(camera: Camera3D) -> void:
	var away: Vector3 = global_position * 2.0 - camera.global_position
	if absf(away.x - global_position.x) < 0.001 and absf(away.z - global_position.z) < 0.001:
		return  # directly overhead: no valid up vector, keep the last facing.
	look_at(away, Vector3.UP)


func _float() -> void:
	position.y = _base_height + sin(
			UiFx.clock() * TAU / UiFx.PROMPT_FLOAT_PERIOD) * UiFx.PROMPT_FLOAT


func _refresh_text(delta: float) -> void:
	_text_clock -= delta
	if _text_clock > 0.0:
		return
	_text_clock = TEXT_REFRESH

	_ready_state = _owner.prompt_ready()
	var title: String = _owner.prompt_title()
	if title != _last_title:
		_last_title = title
		_title.text = title
	var key: String = _owner.prompt_key()
	if key != _last_key:
		_last_key = key
		_key.text = key
