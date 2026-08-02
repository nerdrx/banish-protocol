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


func _ready() -> void:
	_load()
	_apply()


## Per-effect comfort trim for the loud-but-optional effects (grain, shake, the
## HUD glitch). Reduced Flashing pulls these down; essential readouts stay. A hook
## for the settings pass — returns `flash_scale` today, per-effect later.
func effect_scale(_name: String) -> float:
	return flash_scale


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


func _save() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value(SECTION, "reduced_flashing", reduced_flashing)
	cfg.set_value(SECTION, "warning_ack", warning_ack)
	cfg.save(CONFIG_PATH)
