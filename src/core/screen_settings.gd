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

## HUD WIDTH — how far the instrument clusters sit toward the screen's edges.
##
## 0.0 is PT2's centred 16:9 instrument zone (`UiFx.tube_safe_rect`); 1.0 is the
## true canvas minus the tube's own glass margin. See the block comment above
## `UiFx.instrument_rect` for the measurement that produced this control.
##
## ## Why there is an `auto` flag rather than just a number
##
## The right default is a fact about the player's PANEL, and the panel can change
## between two boots (windowed, fullscreen, a second monitor). A number baked at
## first launch would be wrong for the rest of the profile's life and the player
## would never know which setting to blame. So the stored state is "the player
## has not expressed a preference" until they touch the slider, and while that
## holds, the value is DERIVED from the live aspect every time it is asked for:
## 16:9 keeps the composed zone, an ultrawide spreads to its edges. The moment
## the slider moves, the number is theirs and nothing recomputes it.
const HUD_WIDTH_MIN: float = 0.0
const HUD_WIDTH_MAX: float = 1.0
## The aspects the automatic ramp runs between. Below the first, the composed
## zone is correct and nothing moves; at and above the second there is so much
## glass outboard of a 16:9 box that a corner readout stops reading as a corner.
const HUD_WIDTH_AUTO_FROM: float = 1.90
const HUD_WIDTH_AUTO_TO: float = 2.37
## What the automatic ramp reaches. Not 1.0: the last few percent puts the crew
## cluster hard against the glass margin, and an instrument touching the bezel
## reads as a rendering fault rather than as a choice. A player who wants the
## last centimetre has the slider.
const HUD_WIDTH_AUTO_CEILING: float = 0.92
var hud_width: float = 0.0
var hud_width_auto: bool = true


func _ready() -> void:
	# Before any Control lays out. An interface built at scale 1.0 and rescaled a
	# frame later is an interface that briefly shows the player the wrong layout,
	# and — worse — snapshots the wrong geometry in everything that caches its own
	# home position (Hud's clusters do exactly that).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load()
	# `-- --hud-width 0..100`. A capture flag, so the three HUD WIDTH frames the
	# ultrawide report is answered with can be shot from one script. It does not
	# save — a capture run must never leave the developer's own profile pinned.
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var flag: int = args.find("--hud-width")
	if flag >= 0 and flag + 1 < args.size():
		hud_width = clampf(args[flag + 1].to_float() / 100.0,
				HUD_WIDTH_MIN, HUD_WIDTH_MAX)
		hud_width_auto = false
		print("[Screen] forced HUD WIDTH %d%% (capture flag; not saved)" % [
			int(hud_width * 100.0)])
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


## The HUD WIDTH the interface should lay out at, for a canvas of `view`. Reads
## the player's number once they have one, and the aspect ramp until then.
func hud_width_for(view: Vector2) -> float:
	if not hud_width_auto:
		return clampf(hud_width, HUD_WIDTH_MIN, HUD_WIDTH_MAX)
	if view.y <= 0.0:
		return HUD_WIDTH_MIN
	return auto_hud_width(view.x / view.y)


## The automatic ramp, as a pure function of aspect, so a test can assert it and
## the settings panel can show the resolved number without duplicating the rule.
static func auto_hud_width(aspect: float) -> float:
	return clampf(inverse_lerp(HUD_WIDTH_AUTO_FROM, HUD_WIDTH_AUTO_TO, aspect),
			0.0, 1.0) * HUD_WIDTH_AUTO_CEILING


## Touching the slider ends the automatic ramp for good — see the note on
## `hud_width_auto`. `changed` is what makes the HUD re-fit live under the panel,
## which matters more here than for any other row in the menu: this is a setting
## you evaluate by looking at where your own minimap went.
func set_hud_width(value: float) -> void:
	hud_width = clampf(value, HUD_WIDTH_MIN, HUD_WIDTH_MAX)
	hud_width_auto = false
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
	hud_width = clampf(float(cfg.get_value(SECTION, "hud_width", 0.0)),
			HUD_WIDTH_MIN, HUD_WIDTH_MAX)
	hud_width_auto = bool(cfg.get_value(SECTION, "hud_width_auto", true))


## Load-then-merge, then atomic temp-and-rename — the same discipline as
## `GameState.save_progress` and `AudioService._save_settings`. The merge is the
## part that is new: this file has two owners now.
func _save() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value(SECTION, "ui_scale", ui_scale)
	cfg.set_value(SECTION, "vignette", vignette)
	cfg.set_value(SECTION, "hud_width", hud_width)
	cfg.set_value(SECTION, "hud_width_auto", hud_width_auto)
	var temp: String = SETTINGS_PATH + ".tmp"
	if cfg.save(temp) == OK:
		DirAccess.rename_absolute(ProjectSettings.globalize_path(temp),
				ProjectSettings.globalize_path(SETTINGS_PATH))
	else:
		cfg.save(SETTINGS_PATH)
