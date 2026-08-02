extends Node
## A11y — accessibility state, owned in one place (the platform-holder pattern:
## one global switch every effect reads, never per-effect booleans scattered
## through the code).
##
## SAFETY-CRITICAL. See limbo-a11y/specs/01-photosensitivity.md. Two tiers, and
## they are NOT the same thing:
##
##   1. **Unconditional flash caps** live in the EFFECTS themselves
##      (post_process.gdshader, flicker_light.gd, crt.gdshader, hud.gd's glitch).
##      They are hard ceilings that hold with Reduced Flashing OFF — a player who
##      never opens a menu is already safe. That is the ship gate. This autoload
##      does NOT create those caps and cannot relax them; it only pushes further
##      down from them.
##   2. **Reduced Flashing** (opt-in, offered at first launch) drives `flash_scale`
##      toward 0, calming every flash source well below the legal line.
##
## The bridge to fragment shaders is the project-wide `a11y_flash` global uniform,
## declared in project.godot [shader_globals] and its value set here — so shaders
## read the switch with no per-material plumbing and there is no load-order race
## (the uniform exists from engine start; this only ever SETS it). GDScript-driven
## effects read `A11y.flash_scale` directly.
##
## Persisted to user://a11y.cfg, deliberately SEPARATE from the program file so it
## survives a corrupt profile: a seizure-safety setting must never be lost to a
## bad save.

signal changed

const CONFIG_PATH: String = "user://a11y.cfg"
const FLASH_UNIFORM: StringName = &"a11y_flash"
const SECTION: String = "photosensitivity"
const CAPTION_SECTION: String = "captions"

## Master comfort switch. OFF by default — the shipped default build is already
## seizure-safe through the unconditional caps; this is the extra calm tier.
var reduced_flashing: bool = false
## Whether the first-launch photosensitivity warning has been acknowledged, so it
## shows exactly once but stays reachable from settings.
var warning_ack: bool = false

## 1.0 normally, 0.0 under Reduced Flashing. A continuous scalar rather than a
## bool, so a future "mild" tier costs nothing. Every temporal-flash term in the
## game multiplies by this (shaders via the `a11y_flash` uniform, GDScript
## directly). It only ever scales an ALREADY-capped effect further down.
var flash_scale: float = 1.0

## Dampened Protocol (M6, DESIGN.md mercy layer). A comfort toggle that softens
## the HAUNTING's PRESENTATION — never its difficulty. M5 shipped the audio half
## (Audio.reduced_spikes); this is the visual half, and the settings panel wires
## the single toggle to both. When on, jumpscare sharpness, hunter-reveal
## intensity and the glitch-proximity ceiling are all pulled down. Persisted with
## the flash caps, in the same resilient file: a comfort setting a haunted player
## needs must never be lost to a corrupt profile.
var dampened_protocol: bool = false

# --- captions (M5; limbo-a11y 03-captions.md) --------------------------------
#
# The directional sound captions are the deaf/HoH player's copy of the game's
# primary threat telegraph — CORE, "a competitive necessity, not a nicety". The
# menu (settings pass) is a view onto these; CaptionBus is the consumer.
# Persisted alongside the flash caps in the same resilient file: a player who
# needs captions must never lose them to a corrupt profile either.

## The whole system. DEFAULT OFF — most players use audio — but surfaced
## prominently in settings (spec 06) because the players who need it must find it
## in seconds.
var sound_captions: bool = false
## Subtitles (speech / authored text) are a separate track and default ON — the
## industry norm, low cost. Little literal dialogue exists pre-M6, so this mostly
## gates MOTHER's future glyph barks; wired now so the toggle exists.
var subtitles: bool = true
## When captions are on: append a direction arrow, bucket the distance. Both
## default ON — the direction IS the point of the system.
var caption_directional: bool = true
var caption_distance: bool = true
## Scope: false = threats only (default), true = every captioned sound incl.
## ambient flavour. Threats-only keeps the stack readable in a firefight.
var caption_all_sounds: bool = false
## 0 = S, 1 = M (default), 2 = L. Plate opacity 0..1. Max simultaneous lines.
var caption_size: int = 1
var caption_bg_opacity: float = 1.0
var caption_max_lines: int = 3


func _ready() -> void:
	_load()
	_apply()


## Per-effect comfort trim for the loud-but-optional effects (grain, shake, the
## HUD glitch). Reduced Flashing pulls these down; essential readouts stay. A hook
## for the settings pass — returns `flash_scale` today, per-effect later.
func effect_scale(_name: String) -> float:
	return flash_scale


## The Dampened Protocol switch (visual half). The settings panel flips this AND
## the audio half (Audio.reduced_spikes) from one control — presentation, not
## difficulty. Emits `changed` so a live view updates.
func set_dampened_protocol(on: bool) -> void:
	if dampened_protocol == on:
		return
	dampened_protocol = on
	_save()
	changed.emit()


## How hard a hunter reveals / a jumpscare hits, 0..1. Dampened Protocol softens
## it; everything that presents a hunter arrival multiplies by this.
func hunter_reveal_scale() -> float:
	return Balance.DAMPENED_REVEAL_SCALE if dampened_protocol else 1.0


## The ceiling on the glitch-proximity static, already inside the shaders' own
## caps. Bounded further by the flash scale (Reduced Flashing) and by Dampened
## Protocol — this is a NEW flash source, so it is capped like every other.
func glitch_proximity_ceiling() -> float:
	var ceiling: float = Balance.HAUNT_GLITCH_CEILING * flash_scale
	if dampened_protocol:
		ceiling *= Balance.DAMPENED_GLITCH_SCALE
	return ceiling


## The switch the first-launch warning and the settings menu both flip.
func set_reduced_flashing(on: bool) -> void:
	if reduced_flashing == on:
		return
	reduced_flashing = on
	_apply()
	_save()
	changed.emit()


## Called once the player has seen the first-launch caution, so it never re-shows.
func acknowledge_warning() -> void:
	if warning_ack:
		return
	warning_ack = true
	_save()


## The captions master switch, flipped by the settings panel. Emits `changed`
## like every other setting so a live view updates without polling.
func set_sound_captions(on: bool) -> void:
	if sound_captions == on:
		return
	sound_captions = on
	_save()
	changed.emit()


## Generic write for the rest of the caption sub-settings, so the settings panel
## does not need a bespoke setter per toggle. Saves and signals once.
func set_caption_option(option: StringName, value: Variant) -> void:
	match option:
		&"subtitles": subtitles = bool(value)
		&"directional": caption_directional = bool(value)
		&"distance": caption_distance = bool(value)
		&"all_sounds": caption_all_sounds = bool(value)
		&"size": caption_size = clampi(int(value), 0, 2)
		&"bg_opacity": caption_bg_opacity = clampf(float(value), 0.0, 1.0)
		&"max_lines": caption_max_lines = clampi(int(value), 2, 4)
		_:
			push_warning("[A11y] unknown caption option '%s'" % option)
			return
	_save()
	changed.emit()


func _apply() -> void:
	flash_scale = 0.0 if reduced_flashing else 1.0
	# The bridge to every fragment shader. The uniform is declared project-wide in
	# [shader_globals], so this is a pure SET — no add, no load-order race, and a
	# no-op under the headless/dummy renderer.
	RenderingServer.global_shader_parameter_set(FLASH_UNIFORM, flash_scale)


func _load() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	reduced_flashing = bool(cfg.get_value(SECTION, "reduced_flashing", false))
	warning_ack = bool(cfg.get_value(SECTION, "warning_ack", false))
	dampened_protocol = bool(cfg.get_value(SECTION, "dampened_protocol", false))
	sound_captions = bool(cfg.get_value(CAPTION_SECTION, "sound_captions", false))
	subtitles = bool(cfg.get_value(CAPTION_SECTION, "subtitles", true))
	caption_directional = bool(cfg.get_value(CAPTION_SECTION, "directional", true))
	caption_distance = bool(cfg.get_value(CAPTION_SECTION, "distance", true))
	caption_all_sounds = bool(cfg.get_value(CAPTION_SECTION, "all_sounds", false))
	caption_size = clampi(int(cfg.get_value(CAPTION_SECTION, "size", 1)), 0, 2)
	caption_bg_opacity = clampf(
			float(cfg.get_value(CAPTION_SECTION, "bg_opacity", 1.0)), 0.0, 1.0)
	caption_max_lines = clampi(int(cfg.get_value(CAPTION_SECTION, "max_lines", 3)), 2, 4)


## Same temp-then-rename discipline GameState.save_progress uses: a flash-cap or
## a caption setting lost to a half-written file on a crash is an accessibility
## regression, so the write is atomic. ConfigFile.save writes in one call, but a
## crash mid-write can still truncate; writing a temp and renaming makes the
## swap atomic on every filesystem we target.
func _save() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value(SECTION, "reduced_flashing", reduced_flashing)
	cfg.set_value(SECTION, "warning_ack", warning_ack)
	cfg.set_value(SECTION, "dampened_protocol", dampened_protocol)
	cfg.set_value(CAPTION_SECTION, "sound_captions", sound_captions)
	cfg.set_value(CAPTION_SECTION, "subtitles", subtitles)
	cfg.set_value(CAPTION_SECTION, "directional", caption_directional)
	cfg.set_value(CAPTION_SECTION, "distance", caption_distance)
	cfg.set_value(CAPTION_SECTION, "all_sounds", caption_all_sounds)
	cfg.set_value(CAPTION_SECTION, "size", caption_size)
	cfg.set_value(CAPTION_SECTION, "bg_opacity", caption_bg_opacity)
	cfg.set_value(CAPTION_SECTION, "max_lines", caption_max_lines)
	var temp: String = CONFIG_PATH + ".tmp"
	if cfg.save(temp) == OK:
		DirAccess.rename_absolute(ProjectSettings.globalize_path(temp),
				ProjectSettings.globalize_path(CONFIG_PATH))
	else:
		cfg.save(CONFIG_PATH)
