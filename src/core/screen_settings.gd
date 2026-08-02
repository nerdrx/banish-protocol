extends Node
## Screen — the DISPLAY half of the settings store (PT2 "Screen & Nav").
##
## Two numbers, both of which the first two playtests asked for by name:
##
##   **UI SCALE** — "the text is barely legible on ANY screen". The interface is
##   authored in a 1280x720 design space and `canvas_items` stretch scales it to
##   whatever the window is, so a 14 px label is 14/720ths of the screen height at
##   every resolution — geometrically consistent and, on a 1193 mm ultrawide sat
##   at desk distance, genuinely too small. The base sizes went up (see the theme
##   and UiFx.FONT), and this is the rest of the answer: a user multiplier, because
##   how big text needs to be is a fact about the player's desk, not about the game.
##
##   **VIGNETTE** — "too much". DESIGN.md pillar 2 is "the dark is the enemy", and
##   that darkness comes from LIGHTING. The vignette is a lens effect on top of it,
##   and at the shipped 1.05 on the menu it was doing structural work it has no
##   business doing: it ate the whole ticker line and half the program panel (see
##   MainMenu's tube-safe area). The default drops; the slider owns the rest.
##
## ## Where these live, and why the shader one is a global uniform
##
## Both persist to `user://settings.cfg`, the store AudioService already owns, in
## a `[display]` section beside its `[audio]` one. Both savers now LOAD-THEN-MERGE
## (a `ConfigFile.new()` + `save()` writes only what it holds, so whichever
## subsystem saved last used to erase the other's section — latent before this
## file existed, real the moment a second writer arrived).
##
## The vignette reaches the shader as a **global uniform**, exactly like
## `a11y_flash` and for exactly the same reason: `post_process.gdshader` is
## instantiated as a separate ShaderMaterial in three different scenes (the menu,
## the procedural layer, the greybox test layer), two of which belong to other
## parts of the codebase. A global uniform reaches all three from one assignment
## with no scene surgery and no per-material plumbing, and it is declared in
## project.godot so the uniform exists from engine start — this only ever SETS it.

signal changed

const SETTINGS_PATH: String = "user://settings.cfg"
const SECTION: String = "display"

## The project-wide vignette multiplier, declared in project.godot
## [shader_globals] and read by `post_process.gdshader`.
const VIGNETTE_UNIFORM: StringName = &"ui_vignette"

## Interface scale. 1.0 is the authored 1280x720 design space.
##
## The ceiling is 1.6 rather than something generous: `content_scale_factor`
## SHRINKS the 2D coordinate space (the canvas becomes 1280/scale wide), and past
## about 1.6 the injection console's own 470 px minimum width stops fitting inside
## a 16:9 tube-safe box. A slider that can hide the HOST button is worse than a
## slider that stops.
const UI_SCALE_MIN: float = 0.80
const UI_SCALE_MAX: float = 1.60
var ui_scale: float = 1.0

## Vignette weight, as a multiplier on whatever intensity each surface authored.
## 1.0 is "what the material says"; the DEFAULT IS 0.55, which is the PT1 "too
## much" complaint answered in the default build rather than in a setting nobody
## opens.
const VIGNETTE_MIN: float = 0.0
const VIGNETTE_MAX: float = 1.4
const VIGNETTE_DEFAULT: float = 0.55
var vignette: float = VIGNETTE_DEFAULT


func _ready() -> void:
	# Before any Control lays out. An interface built at scale 1.0 and rescaled a
	# frame later is an interface that briefly shows the player the wrong layout,
	# and — worse — snapshots the wrong geometry in everything that caches its own
	# home position (Hud's clusters do exactly that).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load()
	_apply()
	# `--ui-audit`. Armed from here rather than from Debug for two reasons: this is
	# the autoload that owns the canvas the audit measures, and Debug is a shared
	# file under concurrent edit — a UI instrument that only the UI needs has no
	# business widening that surface. `arm` reads the flag itself and returns null
	# without it, so this line costs one array scan on a normal boot.
	UiAudit.arm(self)


func set_ui_scale(value: float) -> void:
	ui_scale = clampf(value, UI_SCALE_MIN, UI_SCALE_MAX)
	_apply()
	_save()
	changed.emit()


func set_vignette(value: float) -> void:
	vignette = clampf(value, VIGNETTE_MIN, VIGNETTE_MAX)
	_apply()
	_save()
	changed.emit()


## `content_scale_factor` is the whole mechanism, and it is the right one for a
## reason worth writing down: under `canvas_items` stretch the root viewport keeps
## a separate 2D override size (`get_visible_rect()`) from its render size, so
## scaling the factor resizes the CANVAS COORDINATE SPACE and leaves the 3D render
## target at native window resolution. The UI gets bigger; the world does not get
## blurrier. The obvious alternative — scaling the UI Controls — would rasterise
## every glyph at the base size and then stretch it, which is how you make text
## larger and less legible at the same time.
func _apply() -> void:
	RenderingServer.global_shader_parameter_set(VIGNETTE_UNIFORM, vignette)
	var window: Window = get_window()
	if window != null:
		window.content_scale_factor = ui_scale


func _load() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	ui_scale = clampf(float(cfg.get_value(SECTION, "ui_scale", 1.0)),
			UI_SCALE_MIN, UI_SCALE_MAX)
	vignette = clampf(float(cfg.get_value(SECTION, "vignette", VIGNETTE_DEFAULT)),
			VIGNETTE_MIN, VIGNETTE_MAX)


## Load-then-merge, then atomic temp-and-rename — the same discipline as
## `GameState.save_progress` and `AudioService._save_settings`. The merge is the
## part that is new: this file has two owners now.
func _save() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value(SECTION, "ui_scale", ui_scale)
	cfg.set_value(SECTION, "vignette", vignette)
	var temp: String = SETTINGS_PATH + ".tmp"
	if cfg.save(temp) == OK:
		DirAccess.rename_absolute(ProjectSettings.globalize_path(temp),
				ProjectSettings.globalize_path(SETTINGS_PATH))
	else:
		cfg.save(SETTINGS_PATH)
