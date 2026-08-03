class_name PocketSecretary
extends Interactable
## A POCKET SECRETARY — the handheld data slate somebody left behind, and the
## bread-and-butter vessel for M9's hot-patches.
##
## ## Why a slate and not a glowing pickup
##
## DESIGN.md's HUD is cassette futurism: the crew are a human-built program, so
## their instrument is old HUMAN tech deliberately contrasting MOTHER's sleek
## neon. A pocket secretary is that same argument as a world object — chunky
## rounded housing, a tiny phosphor screen, one hard button, the kind of thing an
## engineer clipped to a belt. It rhymes with the Northcairn legacy remnants in
## the deep layers and with the CRT terminals the crew already type at, and it is
## the exact opposite of a floating item pedestal.
##
## ## The motivation law (DESIGN.md pillar 6) is the whole placement rule
##
## A slate is not scatter and must never be placed like scatter. Somebody OWNED
## it, was using it for a job, and put it down: so the only legal anchors are
## places the layer already says work happened — a desk beside a command
## terminal, the pool of a tripod work light (a lamp somebody is coming back
## for), the shelf inside a cabinet, an opened junction. `PatchPlacement` derives
## every position from one of those and from nothing else; a layer with no
## unfinished work on it gets no slates, which is correct.
##
## ## The screen is a beacon AND a risk
##
## It glows faintly — enough to be findable in a black room with a sweep of your
## beam, nowhere near enough to light the room (pillar 2 is not negotiable for a
## pickup, and `Balance.PATCH_SLATE_SCREEN_ENERGY` is under a data chip's own
## pool). It also tells you the RARITY of what is on it before you commit, by
## colour AND by a pip count on the screen edge — colour is never the only
## channel (pillar 7). That is a deliberate design choice rather than a leak:
## reading a slate is loud, so the player deserves to know whether the noise is
## worth it. Greed with information is a decision; greed without it is a coin.
##
## ## After
##
## The slate powers dead and STAYS THERE, as inert dressing. Nothing in this game
## despawns because you touched it — a room you have looted should look looted.

const HOUSING: Color = Color(0.20, 0.19, 0.17)
const SCREEN_DEAD: Color = Color(0.10, 0.10, 0.11)

## Body of the slate, in metres. Deliberately small and hand-sized: 16 x 11 cm
## with a 2 cm shell, so it reads as something a person carried rather than as a
## crate. It sits on a surface, so its origin is its underside.
const BODY: Vector3 = Vector3(0.16, 0.022, 0.115)
## The screen inset, and how far it stands proud of the shell.
const SCREEN: Vector3 = Vector3(0.115, 0.004, 0.072)
const SCREEN_LIFT: float = 0.013
## Rarity pips along the screen's short edge — the non-colour channel.
const PIP_SIZE: Vector3 = Vector3(0.008, 0.003, 0.008)

var prop_index: int = 0
## Which vessel family this slate belongs to — a PLACED one the generator left at
## a work anchor, or a DROPPED one that fell out of a deleted process. They share
## a prop and a group and differ only in their rarity mix, so the kind travels
## with the object rather than being inferred from where it is standing; without
## it a dropped slate with index 2 and a placed slate with index 2 would be the
## same vessel to the host's lookup.
var vessel_kind: String = Patches.KIND_SLATE
## Rarity of the patch this slate holds. Every peer derives it from the same
## hash, so it is not replicated and it cannot disagree.
var rarity: int = Balance.PATCH_TIER_STABLE

var _screen_material: StandardMaterial3D = null
var _pip_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _channel: float = 0.0
var _was_taken: bool = false


static func create(index: int, where: Vector3, yaw: float, tier: int,
		kind: String = Patches.KIND_SLATE) -> PocketSecretary:
	var slate: PocketSecretary = PocketSecretary.new()
	slate.name = "PocketSecretary_%s%d" % [kind, index]
	slate.prop_index = index
	slate.vessel_kind = kind
	slate.rarity = tier
	slate.position = where
	slate.rotation.y = yaw
	slate.channel_time = Balance.PATCH_SLATE_CHANNEL
	slate._assemble()
	return slate


func _assemble() -> void:
	var shell: StandardMaterial3D = StandardMaterial3D.new()
	shell.albedo_color = HOUSING
	shell.roughness = 0.62
	shell.metallic = 0.15

	# The housing: a slab with a chamfered lip, so it reads as moulded plastic
	# with a rubber bumper rather than as a box.
	_box(Vector3(0.0, BODY.y * 0.5, 0.0), BODY, shell)
	_box(Vector3(0.0, BODY.y * 0.82, 0.0),
			Vector3(BODY.x - 0.014, BODY.y * 0.45, BODY.z - 0.014), shell)
	# One hard button, bottom edge. A pocket secretary has exactly one control and
	# the whole prop is more legible for it.
	_box(Vector3(0.0, BODY.y * 0.95, BODY.z * 0.5 - 0.014),
			Vector3(0.022, 0.006, 0.012), shell)

	# The screen. Phosphor, so it belongs to the crew's own tech rather than to
	# MOTHER's neon.
	_screen_material = _emissive(PatchFx.rarity_colour(rarity), 1.4)
	_box(Vector3(0.0, BODY.y + SCREEN_LIFT, -0.008), SCREEN, _screen_material)

	# Rarity pips, one per tier, along the top edge of the screen. Shape and count,
	# not colour: a protanope counts pips.
	_pip_material = _emissive(PatchFx.rarity_colour(rarity), 2.2)
	for i: int in rarity + 1:
		_box(Vector3(-0.040 + float(i) * 0.014, BODY.y + SCREEN_LIFT + 0.001,
				-SCREEN.z * 0.5 - 0.012), PIP_SIZE, _pip_material)

	_light = OmniLight3D.new()
	_light.name = "SlateGlow"
	_light.position = Vector3(0.0, 0.09, 0.0)
	_light.light_color = PatchFx.rarity_colour(rarity)
	_light.light_energy = Balance.PATCH_SLATE_SCREEN_ENERGY
	_light.omni_range = Balance.PATCH_SLATE_SCREEN_RANGE
	_light.omni_attenuation = 1.5
	_light.light_volumetric_fog_energy = 0.7
	# Never. A find-me beacon that re-renders the shadow atlas is a find-me
	# beacon nobody can afford three of.
	_light.shadow_enabled = false
	add_child(_light)

	# Generous probe: the slate itself is 16 cm across and a crosshair-accurate
	# pickup at running speed in the dark would be a marksmanship test, which is
	# the same argument `BREAKER_AIM_DEG` settles for the cutter.
	_add_probe(Vector3(0.62, 0.55, 0.62), Vector3(0.0, 0.20, 0.0))


func _ready() -> void:
	add_to_group(Patches.GROUP_SLATE)
	if Patches.is_taken(vessel_kind, prop_index):
		_go_dead()


# ------------------------------------------------------------- interactable --

func prompt() -> String:
	if Patches.is_taken(vessel_kind, prop_index):
		return "SLATE DEAD"
	return "HOLD E  ·  READ PATCH  (%s)" % Balance.patch_tier_name(rarity)


func prompt_title() -> String:
	if Patches.is_taken(vessel_kind, prop_index):
		return "SLATE DEAD"
	return "%s PATCH" % Balance.patch_tier_name(rarity)


func prompt_key() -> String:
	return "" if Patches.is_taken(vessel_kind, prop_index) else "E"


func prompt_glyph() -> String:
	return "▤"


func prompt_height() -> float:
	return 0.75


func available() -> bool:
	return Run.local_running() and not Patches.is_taken(vessel_kind, prop_index)


func complete() -> void:
	Patches.request_pickup(vessel_kind, prop_index)


func set_channel_visual(progress: float) -> void:
	_channel = clampf(progress, 0.0, 1.0)


# ------------------------------------------------------------------ visuals --

func _process(_delta: float) -> void:
	var spent: bool = Patches.is_taken(vessel_kind, prop_index)
	if spent:
		if not _was_taken:
			_go_dead()
		return
	# A slow standby breath, well under 3 Hz by construction (a 2.6 s cycle) and
	# scaled by the flash caps like every other lit thing in the game. The channel
	# drives it up smoothly — reading the slate wakes its screen.
	var beat: float = 0.72 + 0.28 * absf(sin(UiFx.clock() * 2.4))
	var lit: float = (beat + _channel * 2.2) * A11y.flash_scale
	_screen_material.emission_energy_multiplier = 1.4 * lit
	_pip_material.emission_energy_multiplier = 2.2 * lit
	_light.light_energy = Balance.PATCH_SLATE_SCREEN_ENERGY * lit


## Read, absorbed, and out of charge. The object stays: a room you have looted
## should look looted, and nothing in NULLVOID vanishes because you touched it.
func _go_dead() -> void:
	_was_taken = true
	_screen_material.emission = SCREEN_DEAD
	_screen_material.emission_energy_multiplier = 0.0
	_screen_material.albedo_color = SCREEN_DEAD
	_pip_material.emission_energy_multiplier = 0.0
	_pip_material.albedo_color = SCREEN_DEAD
	_light.light_energy = 0.0
	set_process(false)


# ------------------------------------------------------------------ helpers --

func _box(at: Vector3, size: Vector3, material: StandardMaterial3D) -> void:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)


func _emissive(colour: Color, energy: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour.darkened(0.7)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.35
	material.disable_receive_shadows = true
	return material
