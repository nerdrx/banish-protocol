class_name SettingsPanel
extends CanvasLayer
## The audio-comfort settings surface — the M5 slice of the full accessibility
## menu (limbo-a11y 06-settings-menu.md), shipped now because M5 is the milestone
## that gives the game things to turn down.
##
## CRT-styled to extend the console language, but deliberately UNDER-tubed: this
## is the one screen where legibility beats flavour, because a menu you cannot
## read cannot fix the thing you opened it to fix. High-contrast phosphor text on
## a calm dark plate, no glitch drivers.
##
## It is a thin VIEW: every control reads and writes the single stores that own
## the state (AudioService → user://settings.cfg, A11y → user://a11y.cfg) through
## their setters, which persist atomically. The panel holds no state of its own,
## so it is always correct even if something else changed a value while it was
## closed. Reachable from the main menu and the in-run pause overlay — someone
## mid-run who needs the spikes softened must not have to quit.
##
## The full IA (photosensitivity, colour, captions detail, controls, comfort,
## cognitive) is a later pass; this ships the audio + captions rows the sound
## milestone is responsible for.

const TITLE: String = "DISPLAY  ·  AUDIO  ·  COMFORT"


## Build the panel over `host` and return it. One live at a time — a second call
## while one is open just focuses the existing one.
static func open(host: Node) -> SettingsPanel:
	var existing: SettingsPanel = host.get_tree().root.find_child(
			"SettingsPanel", true, false) as SettingsPanel
	if existing != null and is_instance_valid(existing):
		return existing
	var panel: SettingsPanel = SettingsPanel.new()
	panel.name = "SettingsPanel"
	host.add_child(panel)
	return panel


func _ready() -> void:
	layer = 80
	_build()
	Audio.play_2d(&"ui_selftest")  # the instrument surfacing.


func _build() -> void:
	var dim: ColorRect = ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP  # swallow clicks behind it.
	add_child(dim)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.add_child(center)

	var plate: PanelContainer = PanelContainer.new()
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = Color(0.03, 0.035, 0.045, 0.98)
	box.border_color = UiFx.DIM
	box.set_border_width_all(1)
	box.set_corner_radius_all(2)
	box.set_content_margin_all(26)
	plate.add_theme_stylebox_override("panel", box)
	plate.custom_minimum_size = Vector2(660.0, 0.0)
	center.add_child(plate)

	# PT2: the panel scrolls, and it has to, because PT2 is what made it able to
	# outgrow the screen. UI SCALE shrinks the 2D canvas — at x1.45 the canvas is
	# 496 rows tall and this panel is over 700 — so the very setting a player opens
	# this to change is the one that can push CLOSE off the bottom edge. Capped at
	# 82% of the viewport height rather than a fixed number, so it is the SCREEN
	# that decides, at every aspect and every scale.
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(660.0, 0.0)
	scroll.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	plate.add_child(scroll)

	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)

	# Deferred: the column has no height until it has been laid out once, and a
	# cap applied before that is a cap applied to zero.
	#
	# And re-run on every viewport change, which is not belt-and-braces here: this
	# panel OWNS the UI SCALE slider, so the single most likely resize in the game
	# is the player dragging that slider with this panel open. Capping once on open
	# meant the cap was computed for the canvas the panel was opened at, and
	# dragging scale up grew the panel past the bottom of the screen — taking the
	# slider that caused it with it.
	var refit: Callable = func() -> void:
		if not is_instance_valid(scroll):
			return
		var ceiling: float = get_viewport().get_visible_rect().size.y * 0.82
		scroll.custom_minimum_size = Vector2(660.0,
				minf(column.get_combined_minimum_size().y, ceiling))
	refit.call_deferred()
	get_viewport().size_changed.connect(refit)

	_header(column, TITLE)
	_rule(column)

	# --- display (PT2) ---
	#
	# First, above the mixer, because these are the two rows the last two
	# playtests asked for by name — "barely legible on ANY screen" and "the
	# vignette is too much" — and a player who opened this panel to fix either of
	# them should not have to scroll past four volume sliders to find it.
	#
	# Both write through `Screen`, which applies and persists on every drag, so
	# the effect is live UNDER the panel: the plate you are reading gets bigger as
	# you drag UI SCALE, and the corners of the frame come back as you drag
	# VIGNETTE down. A display setting you have to close a menu to evaluate is a
	# display setting nobody tunes correctly.
	_section(column, "DISPLAY")
	_ranged(column, "UI SCALE", Screen.ui_scale,
			Screen.UI_SCALE_MIN, Screen.UI_SCALE_MAX, 0.05, "x%.2f",
			func(v: float) -> void: Screen.set_ui_scale(v))
	_gloss(column, "Size of every readout and menu. The world is untouched — this "
			+ "resizes the interface's own coordinate space, so text stays sharp.")
	_ranged(column, "VIGNETTE", Screen.vignette,
			Screen.VIGNETTE_MIN, Screen.VIGNETTE_MAX, 0.05, "%d%%",
			func(v: float) -> void: Screen.set_vignette(v))
	_gloss(column, "Darkening at the corners of the frame. A lens effect only — "
			+ "the dark of the game itself comes from the lighting and does not move.")

	_rule(column)
	# --- volumes ---
	_section(column, "LEVELS")
	_slider(column, "MASTER", Audio.vol_master,
			func(v: float) -> void: Audio.set_volume(&"master", v))
	_slider(column, "MUSIC", Audio.vol_music,
			func(v: float) -> void: Audio.set_volume(&"music", v))
	_slider(column, "SFX", Audio.vol_sfx,
			func(v: float) -> void: Audio.set_volume(&"sfx", v))
	_slider(column, "VOICE", Audio.vol_voice,
			func(v: float) -> void: Audio.set_volume(&"voice", v))

	_rule(column)
	_section(column, "ACCESSIBILITY")
	# The two TEXT tracks, adjacent and one line apart.
	#
	# PT1: they used to be neither. `SOUND CAPTIONS` was here alone under COMFORT
	# and the subtitle track — MOTHER's speech, the text a player actually sees
	# most — had no control anywhere in the game and defaulted on. A player
	# hunting for the switch found this one, flipped it, and nothing happened,
	# because it governs a different track. Two text features need two visible
	# switches, side by side, or the one you can see gets blamed for the one you
	# cannot. See A11y.subtitles for why the default moved as well.
	_toggle(column, "SOUND CAPTIONS", A11y.sound_captions,
			"Directional captions for threats and world sounds. The deaf/HoH threat telegraph.",
			func(on: bool) -> void: A11y.set_sound_captions(on))
	_toggle(column, "SUBTITLES", A11y.subtitles,
			"MOTHER's speech, as text under the reticle.",
			func(on: bool) -> void: A11y.set_caption_option(&"subtitles", on))

	_rule(column)
	_section(column, "COMFORT")
	_toggle(column, "CRT WHINE (15.7 kHz)", Audio.crt_whine,
			"The tube's flyback whine. Off notches it out — kill it if it hurts.",
			func(on: bool) -> void: Audio.set_crt_whine(on))
	# Dampened Protocol (M6): ONE comfort switch across both senses. M5 shipped the
	# audio half (reduced spikes); M6 adds the visual half (hunter reveals,
	# jumpscare sharpness, the glitch-proximity ceiling). It softens how the
	# haunting is PRESENTED — it does not touch difficulty. Wired here to both
	# stores from the single control (A11y owns the visual state, Audio the audio).
	_toggle(column, "DAMPENED PROTOCOL", A11y.dampened_protocol,
			"Softens hunter reveals, jumpscares and audio spikes. Comfort only — the threat is unchanged.",
			func(on: bool) -> void:
				A11y.set_dampened_protocol(on)
				Audio.set_reduced_spikes(on))

	_rule(column)
	var close: Button = _button(column, "CLOSE")
	close.pressed.connect(_close)


# ------------------------------------------------------------- row builders --

func _header(parent: Control, text: String) -> void:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_override("font", _font())
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", UiFx.SYSTEM)
	parent.add_child(label)


func _section(parent: Control, text: String) -> void:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_override("font", _font())
	label.add_theme_font_size_override("font_size", UiFx.FONT_SMALL)
	label.add_theme_color_override("font_color", UiFx.CAPTION)
	parent.add_child(label)


func _rule(parent: Control) -> void:
	var line: ColorRect = ColorRect.new()
	line.custom_minimum_size = Vector2(0.0, 1.0)
	line.color = Color(UiFx.DIM.r, UiFx.DIM.g, UiFx.DIM.b, 0.4)
	parent.add_child(line)


## A labelled 0–100 % slider. Shows the live value; writes through `apply` on
## every drag (the store persists), so there is no separate save step.
func _slider(parent: Control, name: String, value: float, apply: Callable) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	parent.add_child(row)

	var label: Label = Label.new()
	label.text = name
	label.custom_minimum_size = Vector2(120.0, 0.0)
	label.add_theme_font_override("font", _font())
	label.add_theme_font_size_override("font_size", UiFx.FONT_HEAD)
	label.add_theme_color_override("font_color", UiFx.TEXT)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	var slider: HSlider = HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = value
	slider.custom_minimum_size = Vector2(300.0, 0.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)

	var readout: Label = Label.new()
	readout.text = "%3d%%" % int(round(value * 100.0))
	readout.custom_minimum_size = Vector2(56.0, 0.0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.add_theme_font_override("font", _font())
	readout.add_theme_font_size_override("font_size", UiFx.FONT_HEAD)
	readout.add_theme_color_override("font_color", UiFx.SYSTEM)
	readout.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(readout)

	slider.value_changed.connect(func(v: float) -> void:
		readout.text = "%3d%%" % int(round(v * 100.0))
		apply.call(v))


## `_slider`'s general cousin: an arbitrary range with its own readout format.
##
## Kept separate rather than generalising `_slider` because the 0-100 % form is
## the right one for four mixer rows and the wrong one for a scale factor — "UI
## SCALE 62%" tells a player nothing, "UI SCALE x1.30" tells them exactly what
## they have. `format` carries a float for a multiplier and an int percentage for
## a weight; the call site picks.
func _ranged(parent: Control, name: String, value: float, low: float, high: float,
		step: float, format: String, apply: Callable) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	parent.add_child(row)

	var label: Label = Label.new()
	label.text = name
	label.custom_minimum_size = Vector2(120.0, 0.0)
	label.add_theme_font_override("font", _font())
	label.add_theme_font_size_override("font_size", UiFx.FONT_HEAD)
	label.add_theme_color_override("font_color", UiFx.TEXT)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	var slider: HSlider = HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(300.0, 0.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)

	var percent: bool = format.ends_with("%%")
	var readout: Label = Label.new()
	readout.text = format % (roundf(value * 100.0) if percent else value)
	readout.custom_minimum_size = Vector2(84.0, 0.0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.add_theme_font_override("font", _font())
	readout.add_theme_font_size_override("font_size", UiFx.FONT_HEAD)
	readout.add_theme_color_override("font_color", UiFx.SYSTEM)
	readout.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(readout)

	slider.value_changed.connect(func(v: float) -> void:
		readout.text = format % (roundf(v * 100.0) if percent else v)
		apply.call(v))


## A standalone gloss line, for the rows that are not toggles.
func _gloss(parent: Control, text: String) -> void:
	var note: Label = Label.new()
	note.text = text
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_override("font", _font())
	note.add_theme_font_size_override("font_size", UiFx.FONT_SMALL)
	note.add_theme_color_override("font_color", UiFx.CAPTION)
	parent.add_child(note)


## A labelled on/off with a one-line plain-language gloss under it.
func _toggle(parent: Control, name: String, on: bool, gloss: String, apply: Callable) -> void:
	var wrap: VBoxContainer = VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 1)
	parent.add_child(wrap)

	var check: CheckButton = CheckButton.new()
	check.text = name
	check.button_pressed = on
	check.add_theme_font_override("font", _font())
	check.add_theme_font_size_override("font_size", UiFx.FONT_HEAD)
	check.add_theme_color_override("font_color", UiFx.TEXT)
	check.add_theme_color_override("font_pressed_color", UiFx.SYSTEM)
	wrap.add_child(check)

	var note: Label = Label.new()
	note.text = gloss
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_override("font", _font())
	note.add_theme_font_size_override("font_size", UiFx.FONT_SMALL)
	note.add_theme_color_override("font_color", UiFx.CAPTION)
	wrap.add_child(note)

	check.toggled.connect(func(pressed: bool) -> void:
		Audio.play_2d(&"ui_select")
		apply.call(pressed))


func _button(parent: Control, text: String) -> Button:
	var button: Button = Button.new()
	button.text = text
	button.add_theme_font_override("font", _font())
	button.add_theme_font_size_override("font_size", UiFx.FONT_HEAD)
	button.mouse_entered.connect(func() -> void: Audio.play_2d(&"ui_hover"))
	parent.add_child(button)
	return button


func _font() -> Font:
	return load("res://assets/fonts/ui_font.tres") as Font


func _close() -> void:
	Audio.play_2d(&"ui_back")
	queue_free()


## Esc closes it, wherever it was opened from.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()
