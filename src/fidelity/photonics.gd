extends Node
## Photonics — the renderer's quality store, and the one place that knows what
## each knob costs.
##
## THE PROBLEM THIS SOLVES
## The fidelity pass added four things the game can now do that it could not
## before: real area lights, SDFGI, full-march SSR, and camera-following dust.
## Every one of them is worth having and not one of them is free. Shipping them
## all on would break the 60 fps promise; shipping them all off would mean the
## work only exists in screenshots. So they become a TIER the player chooses,
## with the cost of each row written next to it in milliseconds.
##
## THE THREE TIERS
##   BASELINE  exactly what the game shipped before this pass — the same
##             Environment, the same fixture counts. It is the default and it is
##             the tier the 60 fps promise is made about. Nothing in ENHANCED or
##             CINEMA is allowed to change what BASELINE does.
##   ENHANCED  the cheap half of the pass: full-march SSR, a couple of real area
##             lights on the props a room is composed around, denser air.
##   CINEMA    SDFGI. It is the only thing in here that changes the LOOK of the
##             game rather than its fidelity, because real bounce lets the flat
##             ambient come down further — which is a DARKNESS-LAW WIN, not a
##             brightness one. It is also the most expensive row on the page.
##
## THE TIER-GATE ORDER
## When the tier drops, features are surrendered in this order:
##
##     SSIL / SDFGI   →   SSR / volumetrics   →   SSAO
##
## Most expensive first, and *last* the one whose absence is most visible: SSAO
## at 0.85 m radius is what makes the kit's 60 mm panel recesses read as
## recesses, and a room without it looks like untextured boxes no matter what
## else is on. A quality ladder that drops contact shading first is a ladder
## that makes the cheap tier look broken rather than cheap.
##
## THE NUMBERS ARE ESTIMATES AND THEY SAY SO
## Every cost on the settings page is prefixed `EST`. They come from the
## published cost profile of each effect at 1440p and from the fidelity bench's
## own A/B captures, NOT from a profiler run on this build in these rooms. When
## somebody measures them, the prefix comes off and the number changes. An
## estimate presented as a measurement is the fastest way to lose the ability to
## tell the difference later.
##
## WHAT THIS AUTOLOAD OWNS AND WHAT IT DOES NOT
## It owns the SETTINGS and the ENVIRONMENT knobs derived from them. It does not
## own the fixtures: the area-light budget is applied by ranking whatever props
## have registered themselves in `AREA_LIGHT_GROUP`, and the dust box reads
## `dust_scale` itself. Nothing here reaches into a scene by path.

signal changed

const SETTINGS_PATH: String = "user://settings.cfg"
const SECTION: String = "photonics"

## Props that CAN be a real area light and are willing to be told whether they
## are. Anything in this group must expose a `use_area_light` bool property.
const AREA_LIGHT_GROUP: StringName = &"area_light_candidates"

enum Tier {
	BASELINE,  ## the shipped renderer. The 60 fps promise is about this row.
	ENHANCED,
	CINEMA,
}

## SSR march budget. Not a resolution — Godot's SSR has no half-res switch — but
## the ray-march step count, which is where essentially all of its cost lives.
enum Ssr {
	OFF,
	HALF,  ## 28 steps. Reflects the near floor; long corridors fade out early.
	FULL,  ## 56 steps, the authored value in layer_environment.tres.
}

## Volumetric quality. Drives the froxel grid AND the dust density together,
## because they are one artistic idea — "how much is in the air" — and letting a
## player set dense air with no motes in it produces a fog machine.
enum Volumetrics {
	OFF,
	STANDARD,  ## 128x128x192, the shipped grid.
	HIGH,      ## 192x192x256. Finer froxels = the gobo blades survive further.
}

const SSR_STEPS: Array[int] = [0, 28, 56]
const VOLUME_SIZE: Array[int] = [128, 128, 192]
const VOLUME_DEPTH: Array[int] = [192, 192, 256]
## How much dust rides each volumetric tier. Off means off — a dust box with no
## fog around it is a field of floating specks with nothing to be suspended in.
const DUST_SCALE: Array[float] = [0.0, 0.55, 1.0]

## What CINEMA does to the flat ambient, and what it gives back.
##
## ## The first version of this tier was wrong, and the A/B is what said so
##
## CINEMA originally only did the first half: ambient x0.55 on the theory that
## SDFGI would supply the bounce the flat fill was faking. Shot against BASELINE
## in the work-light room it read as *the same photograph, underexposed* — which
## is the exact failure a quality tier must not have, because a player who turns
## on the expensive setting and gets a darker picture concludes the setting is
## broken and turns it off.
##
## The diagnosis is specific and it is a property of THIS game rather than of
## SDFGI: real bounce needs something to bounce OFF. Every architectural fixture
## in a NULLVOID room is a tight cone aimed at a floor, so the light that reaches
## a wall is already nearly nothing and 90% of nearly nothing is still nothing.
## SDFGI had no diet.
##
## So the tier now moves three numbers together, and the middle one is the fix:
##
##   AMBIENT      down, but only to 0.78. Still a darkness-law win — the flat
##                lift is the thing that makes a room readable without a beam —
##                just no longer the ONLY thing the tier does.
##   PRACTICALS   up, x1.75. This is the compensating lift, and it goes here
##                rather than on ambient FOR A REASON: a practical is a
##                short-range fixture (4-6 m) sitting on visible emissive
##                geometry. Lifting it brightens the pool AROUND A VISIBLE
##                SOURCE and leaves the far side of the room exactly as black as
##                it was. That is more light in the frame and no more visibility
##                across it, which is the only kind of brightness this game can
##                spend. It also hands SDFGI a diet: a dozen 6-metre pools per
##                layer is precisely the short-range, high-frequency lighting
##                that bounce reads well.
##   SDFGI ENERGY up, to 1.35, so what does bounce actually lands.
##
## The result is meant to be the more expensive photograph of the same scene:
## brighter where a light is, no easier to navigate, and with coloured bounce on
## the surfaces beside every fixture.
const SDFGI_AMBIENT_SCALE: float = 0.78
const SDFGI_ENERGY: float = 1.35
## Multiplier on every LightRig practical when the tier is running SDFGI. Read at
## fixture-build time by `LightRig.practical` and re-applied live by
## `Layer.refresh_environment`, so moving the setting does not need a rebuild.
const PRACTICAL_GAIN_GI: float = 1.75

# --- the state ---------------------------------------------------------------

var tier: Tier = Tier.BASELINE
var sdfgi: bool = false
var sdfgi_half_res: bool = true
var ssil: bool = true
var ssao: bool = true
var ssr: Ssr = Ssr.FULL
var volumetrics: Volumetrics = Volumetrics.STANDARD
var soft_shadows: bool = true
## 0, 2, 4 or 6. How many props in the world may be a REAL AreaLight3D at once.
## Zero is not a degraded mode — see FidelitySlatPanel's own docstring: the
## fallback is an emissive diffuser plus a cheap fill, which is what most
## instances in a real layer should be anyway.
var area_light_budget: int = 0
var hdr_output: bool = false

## Set by `_apply_area_budget`; read by the settings panel so the row can say how
## many candidates actually exist rather than only what the cap is.
var area_light_candidates: int = 0

var _tick: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load()
	_force_tier_from_cmdline()
	_apply_project_settings()
	_apply_hdr()
	# `--freecam`. Armed from here for the same reason `--photonics` is parsed
	# here and `--ui-audit` is armed from Screen: it is a capture-only concern
	# belonging to the fidelity pass, and src/core/debug.gd is a shared file under
	# concurrent edit. Returns null without the flag, so this costs one array scan.
	FreecamProbe.arm(self)


## `-- --photonics baseline|enhanced|cinema`. A capture flag, and it lives here
## rather than in Debug for two reasons: this autoload owns the state, and
## src/core/debug.gd is a shared file under concurrent edit that a quality
## setting has no business widening.
##
## It deliberately does NOT save. A capture run must never leave the developer's
## own settings.cfg on CINEMA because a sheet was shot last night.
func _force_tier_from_cmdline() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var index: int = args.find("--photonics")
	if index < 0 or index + 1 >= args.size():
		return
	match args[index + 1].to_lower():
		"baseline":
			tier = Tier.BASELINE
		"enhanced":
			tier = Tier.ENHANCED
		"cinema":
			tier = Tier.CINEMA
		_:
			push_warning("[Photonics] unknown tier '%s'" % args[index + 1])
			return
	var values: Dictionary = preset(tier)
	sdfgi = bool(values["sdfgi"])
	sdfgi_half_res = bool(values["sdfgi_half_res"])
	ssil = bool(values["ssil"])
	ssao = bool(values["ssao"])
	ssr = values["ssr"] as Ssr
	volumetrics = values["volumetrics"] as Volumetrics
	soft_shadows = bool(values["soft_shadows"])
	area_light_budget = int(values["area_light_budget"])
	# `--photonics cinema nofog` — the tier with the air taken out, for the
	# ambush-readability A/B. The A/B has to be the SAME tier with ONE variable
	# moved, or it is two different pictures rather than a comparison.
	if index + 2 < args.size() and args[index + 2].to_lower() == "nofog":
		volumetrics = Volumetrics.OFF
	print("[Photonics] forced tier %s%s (capture flag; not saved)" % [
		args[index + 1].to_upper(),
		"  fog OFF" if volumetrics == Volumetrics.OFF else ""])


## How much brighter the LightRig practicals run at the current tier. One
## function rather than a raw constant so the coupling to SDFGI is stated in one
## place — the lift exists to feed the bounce, so it lives and dies with it.
func practical_gain() -> float:
	return PRACTICAL_GAIN_GI if sdfgi else 1.0


## The dust box's density multiplier. One function rather than a raw field so the
## coupling to the volumetric tier is stated once, here, and DustAir cannot drift
## out of step with it by reading the wrong number.
func dust_scale() -> float:
	return DUST_SCALE[int(volumetrics)]


# ------------------------------------------------------------------- presets --

## What each tier means, as data. Applying a tier writes every row, so a player
## who has been fiddling gets a known state back rather than a mixture.
static func preset(which: Tier) -> Dictionary:
	match which:
		Tier.ENHANCED:
			return {
				"sdfgi": false, "sdfgi_half_res": true,
				"ssil": true, "ssao": true,
				"ssr": Ssr.FULL, "volumetrics": Volumetrics.HIGH,
				"soft_shadows": true, "area_light_budget": 2,
			}
		Tier.CINEMA:
			return {
				"sdfgi": true, "sdfgi_half_res": true,
				"ssil": true, "ssao": true,
				"ssr": Ssr.FULL, "volumetrics": Volumetrics.HIGH,
				"soft_shadows": true, "area_light_budget": 6,
			}
		_:
			# BASELINE is not a taste. It is a COPY of what layer_environment.tres
			# and project.godot ship, so "put it back the way it was" is a button
			# rather than a memory.
			return {
				"sdfgi": false, "sdfgi_half_res": true,
				"ssil": true, "ssao": true,
				"ssr": Ssr.FULL, "volumetrics": Volumetrics.STANDARD,
				"soft_shadows": true, "area_light_budget": 0,
			}


func set_tier(which: Tier) -> void:
	tier = which
	var values: Dictionary = preset(which)
	sdfgi = bool(values["sdfgi"])
	sdfgi_half_res = bool(values["sdfgi_half_res"])
	ssil = bool(values["ssil"])
	ssao = bool(values["ssao"])
	ssr = values["ssr"] as Ssr
	volumetrics = values["volumetrics"] as Volumetrics
	soft_shadows = bool(values["soft_shadows"])
	area_light_budget = int(values["area_light_budget"])
	_commit()


## Every individual row lands here. Changing one moves the tier readout to
## CUSTOM rather than silently claiming the player is still on a preset — a
## quality page that lies about which preset you are on is a page nobody can
## report a performance problem against.
func set_option(option: StringName, value: Variant) -> void:
	match option:
		&"sdfgi":
			sdfgi = bool(value)
			# SDFGI is CINEMA-only in the presets, but switching it on by hand is
			# allowed: the tier is a starting point, not a licence.
		&"sdfgi_half_res": sdfgi_half_res = bool(value)
		&"ssil": ssil = bool(value)
		&"ssao": ssao = bool(value)
		&"ssr": ssr = clampi(int(value), 0, 2) as Ssr
		&"volumetrics": volumetrics = clampi(int(value), 0, 2) as Volumetrics
		&"soft_shadows": soft_shadows = bool(value)
		&"area_light_budget": area_light_budget = clampi(int(value), 0, 6)
		&"hdr_output":
			hdr_output = bool(value)
			_apply_hdr()
		_:
			push_warning("[Photonics] unknown option '%s'" % option)
			return
	_commit()


## Which preset the current row values correspond to, or -1 for a custom mix.
func matched_tier() -> int:
	for candidate: int in [int(Tier.BASELINE), int(Tier.ENHANCED), int(Tier.CINEMA)]:
		var values: Dictionary = preset(candidate as Tier)
		if bool(values["sdfgi"]) == sdfgi and bool(values["ssil"]) == ssil \
				and bool(values["ssao"]) == ssao \
				and int(values["ssr"]) == int(ssr) \
				and int(values["volumetrics"]) == int(volumetrics) \
				and bool(values["soft_shadows"]) == soft_shadows \
				and int(values["area_light_budget"]) == area_light_budget:
			return candidate
	return -1


func _commit() -> void:
	_apply_project_settings()
	apply_to_world()
	_save()
	changed.emit()


# ------------------------------------------------------------------- applying --

## Rewrite one Environment in place from the current settings.
##
## Called by Layer on every build (the Environment is duplicated per layer, so a
## write here can never leak back into the shared .tres) and again whenever a
## setting moves. Everything it touches is a field this store owns; the authored
## resource still decides every number that is not on the settings page.
func apply_environment(env: Environment) -> void:
	if env == null:
		return
	env.ssil_enabled = ssil
	env.ssao_enabled = ssao
	env.ssr_enabled = ssr != Ssr.OFF
	env.ssr_max_steps = SSR_STEPS[int(ssr)]
	env.volumetric_fog_enabled = volumetrics != Volumetrics.OFF

	env.sdfgi_enabled = sdfgi
	if sdfgi:
		env.sdfgi_use_occlusion = true
		env.sdfgi_cascades = 4
		# 0.5 m cells. The kit's detail is at panel scale and SDFGI is never going
		# to resolve a 60 mm recess — that is SSAO's job and SSAO stays on. What
		# this has to resolve is a ROOM: a 0.5 m probe grid over four cascades
		# covers a whole layer's play space, and finer would spend the cascades on
		# geometry the bounce cannot see anyway.
		env.sdfgi_min_cell_size = 0.5
		# Layers are wide and short — 4 m and 8 m storeys over 130 m of lattice —
		# so the vertical axis is compressed and the cascades buy floor area.
		env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_75_PERCENT
		# The whole reason CINEMA exists. Real bounce replaces the flat lift, so
		# the lift comes off — the tier makes the game DARKER and more readable at
		# the same time, which is the only kind of quality tier this game wants.
		env.sdfgi_energy = SDFGI_ENERGY
		env.sdfgi_bounce_feedback = 0.5
		env.ambient_light_energy *= SDFGI_AMBIENT_SCALE
	RenderingServer.gi_set_use_half_resolution(sdfgi and sdfgi_half_res)


## The current layer's WorldEnvironment, if one is standing. Layer re-applies on
## every build; this is for the settings page, where a slider has to change the
## world under the panel or nobody can judge it.
func apply_to_world() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	for node: Node in tree.get_nodes_in_group("layer"):
		var layer: Node = node
		if layer.has_method("refresh_environment"):
			layer.call("refresh_environment")
	_apply_area_budget()


func _apply_project_settings() -> void:
	RenderingServer.environment_set_volumetric_fog_volume_size(
			VOLUME_SIZE[int(volumetrics)], VOLUME_DEPTH[int(volumetrics)])
	RenderingServer.positional_soft_shadow_filter_set_quality(
			RenderingServer.SHADOW_QUALITY_SOFT_HIGH if soft_shadows
			else RenderingServer.SHADOW_QUALITY_HARD)


## HDR OUTPUT. Verified end-to-end on this machine (Wayland, enabled=true,
## 500/1000 nits) by tools/fidelity_bench/hdr_probe.sh — so it ships. It is
## still gated on the CAPABILITY rather than on the platform name, because
## "supported" is a property of the windowing system the process is talking to
## and an X11 session on the same machine cannot do it.
func _apply_hdr() -> void:
	var win: int = DisplayServer.MAIN_WINDOW_ID
	if not hdr_supported():
		return
	DisplayServer.window_request_hdr_output(hdr_output, win)


static func hdr_supported() -> bool:
	if not DisplayServer.has_method("window_is_hdr_output_supported"):
		return false
	return DisplayServer.window_is_hdr_output_supported(
			DisplayServer.MAIN_WINDOW_ID)


## Why HDR is greyed out, in the player's language. Empty string = it is not.
static func hdr_reason() -> String:
	if hdr_supported():
		return ""
	if DisplayServer.get_name().to_lower().contains("x11"):
		return "Requires Wayland. This session is running on X11."
	return "This display or compositor does not offer an HDR output."


# ------------------------------------------------------- the area-light budget --

## Hands out the `area_light_budget` real area lights to the CLOSEST candidates.
##
## Distance rank rather than a per-prop authored flag, because which prop is the
## hero changes as the player walks: the diffuser panel a room was composed
## around stops being the light that matters the moment you leave that room. The
## per-instance export still wins for a prop nobody registered — this only ever
## rewrites candidates that opted in.
func _apply_area_budget() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var candidates: Array[Node] = tree.get_nodes_in_group(AREA_LIGHT_GROUP)
	area_light_candidates = candidates.size()
	if candidates.is_empty():
		return
	var eye: Vector3 = _eye()
	var ranked: Array[Dictionary] = []
	for node: Node in candidates:
		var spatial: Node3D = node as Node3D
		if spatial == null or not is_instance_valid(spatial):
			continue
		ranked.append({"node": spatial,
				"d": spatial.global_position.distance_squared_to(eye)})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["d"]) < float(b["d"]))
	for i: int in ranked.size():
		var spatial: Node3D = ranked[i]["node"]
		spatial.set("use_area_light", i < area_light_budget)


func _eye() -> Vector3:
	var tree: SceneTree = get_tree()
	if tree == null:
		return Vector3.ZERO
	var view: Viewport = tree.root.get_viewport()
	if view == null:
		return Vector3.ZERO
	var cam: Camera3D = view.get_camera_3d()
	return Vector3.ZERO if cam == null else cam.global_position


## The budget is re-ranked on a slow timer rather than every frame. Two seconds
## of staleness is invisible — an area light 12 m away that should have handed
## over to one 11 m away is not a thing anybody sees — and a per-frame sort over
## every candidate on the layer is a cost the budget exists to avoid paying.
func _process(delta: float) -> void:
	if area_light_budget <= 0:
		return
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = 2.0
	_apply_area_budget()


# ------------------------------------------------------------------- storage --

## Same `user://settings.cfg` the DISPLAY and AUDIO rows live in, in a section of
## its own, load-then-merge like every other writer of that file (see
## `Screen._save` for why that discipline is not optional once a file has more
## than one owner).
func _load() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	tier = clampi(int(cfg.get_value(SECTION, "tier", int(Tier.BASELINE))), 0, 2) as Tier
	var base: Dictionary = preset(tier)
	sdfgi = bool(cfg.get_value(SECTION, "sdfgi", base["sdfgi"]))
	sdfgi_half_res = bool(cfg.get_value(SECTION, "sdfgi_half_res", base["sdfgi_half_res"]))
	ssil = bool(cfg.get_value(SECTION, "ssil", base["ssil"]))
	ssao = bool(cfg.get_value(SECTION, "ssao", base["ssao"]))
	ssr = clampi(int(cfg.get_value(SECTION, "ssr", base["ssr"])), 0, 2) as Ssr
	volumetrics = clampi(int(cfg.get_value(SECTION, "volumetrics",
			base["volumetrics"])), 0, 2) as Volumetrics
	soft_shadows = bool(cfg.get_value(SECTION, "soft_shadows", base["soft_shadows"]))
	area_light_budget = clampi(int(cfg.get_value(SECTION, "area_light_budget",
			base["area_light_budget"])), 0, 6)
	hdr_output = bool(cfg.get_value(SECTION, "hdr_output", false))


func _save() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value(SECTION, "tier", int(tier))
	cfg.set_value(SECTION, "sdfgi", sdfgi)
	cfg.set_value(SECTION, "sdfgi_half_res", sdfgi_half_res)
	cfg.set_value(SECTION, "ssil", ssil)
	cfg.set_value(SECTION, "ssao", ssao)
	cfg.set_value(SECTION, "ssr", int(ssr))
	cfg.set_value(SECTION, "volumetrics", int(volumetrics))
	cfg.set_value(SECTION, "soft_shadows", soft_shadows)
	cfg.set_value(SECTION, "area_light_budget", area_light_budget)
	cfg.set_value(SECTION, "hdr_output", hdr_output)
	var temp: String = SETTINGS_PATH + ".tmp"
	if cfg.save(temp) == OK:
		DirAccess.rename_absolute(ProjectSettings.globalize_path(temp),
				ProjectSettings.globalize_path(SETTINGS_PATH))
	else:
		cfg.save(SETTINGS_PATH)
