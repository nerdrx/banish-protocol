class_name FidelityLib
extends RefCounted
## Shared constants for the FIDELITY PASS prop kit (the Isolation benchmark).
##
## One place that knows where the fidelity gobos and materials live, so the
## three hero props and the showcase cannot drift apart. Nothing here is
## gameplay; nothing here is an autoload; nothing here touches an existing
## system. It is a lookup table with a conversion function attached.
##
## The prop kit these constants serve exists to answer one question the current
## build cannot: *what does a light look like when a person put it there?* Every
## fixture in the game right now is placed by ProcLayerBuilder from the LightRig
## recipe, which is correct and which produces rooms that are lit. The reference
## frames the user supplied are not lit — they are lit BY SOMETHING, and you can
## see the something, and the something has a cable running to a battery because
## somebody was working here at 3 a.m. and never came back. That is the motivation
## law aimed at lighting rather than at clutter.

enum Gobo {
	NONE,
	VENT_SLAT,   ## Louvre stack. The medbay reference; the default work-light mask.
	FINE_GRILLE, ## Perforated plate. Fine — reads as a fixture close to a surface.
	FAN_BLADES,  ## A stopped extract fan. A fan that is not turning is a fault.
	CABLE_TRAY,  ## Overhead ladder tray. The most "someone built this" mask.
	DRIP_GRATE,  ## Walkway grating with runnels. For rooms that should feel wet.
}

const GOBO_PATHS: Dictionary = {
	Gobo.VENT_SLAT: "res://assets/gobos/gobo_vent_slat.png",
	Gobo.FINE_GRILLE: "res://assets/gobos/gobo_fine_grille.png",
	Gobo.FAN_BLADES: "res://assets/gobos/gobo_fan_blades.png",
	Gobo.CABLE_TRAY: "res://assets/gobos/gobo_cable_tray.png",
	Gobo.DRIP_GRATE: "res://assets/gobos/gobo_drip_grate.png",
}

const MAT_MLI_GOLD: String = "res://assets/materials/fidelity/mat_mli_gold.tres"
const MAT_HAZARD_BAND: String = "res://assets/materials/fidelity/mat_hazard_band.tres"
const MAT_BRUSHED_STEEL: String = "res://assets/materials/fidelity/mat_brushed_steel.tres"
const TEX_CRT_PHOSPHOR: String = "res://assets/materials/fidelity/tex/crt_phosphor_emis.png"

## Floor grime, reused from the M4.8 clutter set rather than re-authored. The
## props do not need their own dirt library; they need the same dirt the rest of
## the world already has, or a hero prop reads as a visitor from another game.
const SCUFF_TEXTURES: Array[String] = [
	"res://assets/grime/stain_a.png",
	"res://assets/grime/stain_b.png",
	"res://assets/grime/stain_c.png",
]


static func gobo_texture(kind: Gobo) -> Texture2D:
	if kind == Gobo.NONE or not GOBO_PATHS.has(kind):
		return null
	return load(GOBO_PATHS[kind]) as Texture2D


## Blackbody colour for a colour temperature, normalised so that changing the
## temperature changes the HUE and not the exposure.
##
## Why bother, when a designer could just pick a Color: because "warm" is a
## number a lighting person already thinks in, and because the two temperatures
## this kit cares about are specific real ones. A halogen work lamp is ~3000 K
## and MOTHER's own architecture runs ~6500 K cold-blue; putting those side by
## side in one frame is the entire colour story of the Isolation medbay
## reference, and it only works if both are actually on the Planckian locus
## rather than eyeballed. An eyeballed "warm orange" next to an eyeballed "cool
## blue" reads as two gels, not as two eras of hardware.
##
## Tanner Helland's piecewise fit — accurate to a couple of percent across
## 1000-40000 K, which is far inside what anyone can see on a lamp.
static func kelvin_to_color(kelvin: float) -> Color:
	var t: float = clampf(kelvin, 1000.0, 40000.0) / 100.0
	var r: float
	var g: float
	var b: float

	if t <= 66.0:
		r = 255.0
	else:
		r = 329.698727446 * pow(t - 60.0, -0.1332047592)

	if t <= 66.0:
		g = 99.4708025861 * log(t) - 161.1195681661
	else:
		g = 288.1221695283 * pow(t - 60.0, -0.0755148492)

	if t >= 66.0:
		b = 255.0
	elif t <= 19.0:
		b = 0.0
	else:
		b = 138.5177312231 * log(t - 10.0) - 305.0447927307

	var c: Color = Color(
			clampf(r / 255.0, 0.0, 1.0),
			clampf(g / 255.0, 0.0, 1.0),
			clampf(b / 255.0, 0.0, 1.0))
	# Normalise to the brightest channel. Without this, a 2700 K lamp is
	# genuinely dimmer than a 6500 K one at the same light_energy, so retuning a
	# fixture's warmth silently retunes its exposure and every energy value in
	# the scene has to be re-found. Light3D.light_energy owns brightness; this
	# function owns hue. One knob, one job.
	var peak: float = maxf(c.r, maxf(c.g, c.b))
	if peak > 0.0001:
		c = Color(c.r / peak, c.g / peak, c.b / peak)
	return c
