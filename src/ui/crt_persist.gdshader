shader_type canvas_item;
render_mode unshaded, blend_mul;

// Phosphor persistence, done for real.
//
// A CRT dot does not stop the instant the beam leaves it — it decays. That decay
// is why an Alien: Isolation readout leaves a faint trail behind a moving needle
// and why a number that changes leaves a ghost of the old one for a frame or
// two. Faking it per-element (hold a copy, tween its alpha) means writing bespoke
// ghosting into every widget on the HUD and getting it slightly wrong in each.
//
// Instead the tube's own framebuffer is kept between frames — `Hud._build_tube`
// sets the SubViewport's clear mode to NEVER — and this rect, drawn FIRST inside
// it, fades whatever is still there before the new frame draws over the top.
//
// The trick is the blend mode, and getting it wrong the first time turned the
// whole interface into an opaque black slab over the world. Premultiplied-alpha
// blending is `dst = src.rgb + dst * (1 - src.a)`, which decays the COLOUR
// correctly and drives the ALPHA the wrong way — every frame adds (1 - src.a) to
// it, so a transparent viewport goes fully opaque in about ten frames.
//
// `blend_mul` is `dst = src * dst` on all four channels, which is exactly the
// decay wanted: writing vec4(persistence) leaves `dst * persistence` in colour
// AND in alpha, so the empty parts of the interface stay empty and the world
// behind them stays visible. One full-rect draw, no texture fetch, and every
// element on the interface gets correct decay for free — including ones nobody
// has written yet.
//
// `persistence` is the fraction surviving each frame. It has to be applied
// per-frame at a fixed rate or the trail length becomes a function of frame rate,
// so the script computes it from a half-life in seconds; see UiFx.PHOSPHOR_HALFLIFE.

uniform float persistence : hint_range(0.0, 0.98) = 0.55;

void fragment() {
	COLOR = vec4(persistence);
}
