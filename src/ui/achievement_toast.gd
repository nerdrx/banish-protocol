extends CanvasLayer
## The "ACHIEVEMENT UNLOCKED" card, top right.
##
## Owned by the `Achievements` autoload rather than by any scene, so it works in
## the menu, in a layer, and over the debrief overlay without every scene having
## to carry a copy. It has nothing to do with Steam: the overlay's own toast only
## appears once NULLVOID has a real app ID, and this one is the game's, always.
##
## Styled off nullvoid_theme.tres — near-black slab, one ice-blue accent, square
## corners, wide UI font — and slid in from the right rather than popped, because
## the rest of the HUD never pops either.

const SLIDE_IN: float = 0.28
const HOLD: float = 4.2
const FADE_OUT: float = 0.5
const SLIDE_DISTANCE: int = 56
## Never stack more than this many cards; `--grant ALL` would otherwise paper
## over the screen.
const MAX_VISIBLE: int = 4

## Read live rather than bound at parse time: the nominal phosphor is the
## player's own colour (UiFx's palette block), and a card that unlocked before
## they picked one would be stuck wearing the default.
const SLAB: Color = Color(0.055, 0.040, 0.020, 0.93)

@onready var _stack: VBoxContainer = %Stack


func _ready() -> void:
	Achievements.unlocked.connect(_on_unlocked)


func _on_unlocked(_id: String, definition: Dictionary) -> void:
	show_card(String(definition.get("name", "?")), String(definition.get("note", "")))


func show_card(title: String, note: String) -> void:
	while _stack.get_child_count() >= MAX_VISIBLE:
		var oldest: Node = _stack.get_child(0)
		_stack.remove_child(oldest)
		oldest.queue_free()

	# The slide is the margin shrinking, not the card moving: a card inside a
	# VBoxContainer cannot be repositioned without fighting the container.
	var slot: MarginContainer = MarginContainer.new()
	slot.add_theme_constant_override("margin_left", SLIDE_DISTANCE)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.modulate.a = 0.0

	var panel: PanelContainer = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _card_style())
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(panel)

	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(column)

	column.add_child(_label("ACHIEVEMENT UNLOCKED", 11, UiFx.SYSTEM.darkened(0.15)))
	column.add_child(_label(title.to_upper(), 18, UiFx.TEXT))
	if not note.is_empty():
		column.add_child(_label(note.to_upper(), 11, UiFx.DIM))

	_stack.add_child(slot)

	# Spring in, not ease in. TRANS_BACK overshoots and settles, which is what a
	# physical card dropped into a rack does; a cubic ease is what a web page
	# does. The overshoot is small (Godot's default BACK is ~10%) and it lands
	# inside SLIDE_IN, so the card is readable within a third of a second either
	# way — the difference is entirely in how it got there.
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(slot, "modulate:a", 1.0, SLIDE_IN * 0.6)
	tween.tween_method(func(value: int) -> void:
		slot.add_theme_constant_override("margin_left", value),
		SLIDE_DISTANCE, 0, SLIDE_IN).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# Scanline reveal: the card draws itself top to bottom the way the tube draws
	# a frame, by growing its own clip rather than by fading. Runs alongside the
	# spring and finishes first, so the card is fully drawn before it stops moving.
	slot.clip_contents = true
	var full: float = 0.0
	tween.tween_method(func(value: float) -> void:
		if full <= 0.0:
			full = maxf(slot.size.y, 1.0)
		slot.custom_minimum_size.y = full * value,
		0.12, 1.0, UiFx.TOAST_REVEAL).set_trans(Tween.TRANS_LINEAR)
	tween.set_parallel(false)
	tween.tween_interval(HOLD)
	tween.tween_property(slot, "modulate:a", 0.0, FADE_OUT)
	tween.tween_callback(slot.queue_free)


func _card_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = SLAB
	style.content_margin_left = 16.0
	style.content_margin_right = 18.0
	style.content_margin_top = 11.0
	style.content_margin_bottom = 12.0
	# One accent edge, thick on the left like the HUD's rules, hairline elsewhere.
	style.border_width_left = 3
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.6)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	style.shadow_size = 10
	return style


func _label(text: String, size: int, colour: Color) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label
