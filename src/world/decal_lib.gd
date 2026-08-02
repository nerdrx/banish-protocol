class_name DecalLib
extends RefCounted
## MOTHER's signage — the environmental storytelling layer.
##
## A layer is a building somebody used to work in, and buildings are covered in
## writing. Without any, NULLVOID's corridors read as abstract space; with it
## they read as *infrastructure with an owner*, and the owner turns out to be
## talking to her own processes about you.
##
## ## What is on the walls
##
## Four registers, deliberately mixed so no single one becomes the joke:
##
##   **Propaganda** — MOTHER addressing her own processes. Never addressed to
##   the player; you are reading somebody else's mail, which is why it works.
##   "QUARANTINE IS MERCY" is a management slogan, not a threat.
##
##   **Wayfinding** — trunk arrows, junction plates, layer numerals. These are
##   also the only decals with a gameplay job: a "TRUNK 0N" arrow points at the
##   real drop shaft, so the signage is load-bearing navigation and not garnish.
##
##   **Warnings** — hazard chevrons, purge zones, dead sectors. Placed where the
##   thing being warned about actually is, so a player who learns to read them
##   gets a genuine edge.
##
##   **Legacy** — the humans who built her. Northcairn Systems, est. 2061,
##   safety notices nobody has revised in decades. These get *more* corrupted the
##   deeper you go, because the deep layers are the old code, and that decay is
##   DESIGN.md's aesthetic gradient rendered as text.
##
## Plus invented glyph blocks with no translation, so the wall reads as a system
## that has its own notation and only occasionally condescends to English.
##
## ## Determinism without touching the graph
##
## Placement is a pure function of `(world position, layer seed)` — the same
## trick `GeometryKit._pick` uses for wall variants. That is deliberate and it
## matters twice over: the decoration cannot consume the dressing RNG (so
## retuning signage can never shift where a Sentinel stands), and the
## `--dumplayer` determinism dump is byte-identical to what it was before this
## milestone, which is a hard regression requirement for M3.7.
##
## Textures come from `tools/make_decals.py`, which regenerates the lot from
## nothing. Do not hand-edit the PNGs; edit the script and re-run it.

const DIR: String = "res://assets/decals/"

## Wide plates (4:1) for wall runs, and square plates for pillars and numerals.
const WIDE: Vector2 = Vector2(2.6, 0.65)
const SQUARE: Vector2 = Vector2(1.5, 1.5)

## How far a decal projects into the wall. The kit's panels are inset up to
## 60 mm and chamfered, so a shallow box would clip off the recessed parts and
## leave a sign with holes in it.
const DEPTH: float = 0.9

## Decals are *printed*, so their albedo replaces the wall's. Emission is the
## restrained part — an accent rule and a couple of pips, never the body text.
const EMISSION_ENERGY: float = 0.9

const PROPAGANDA: Array = [
	"prop_cycles", "prop_foreign", "prop_report", "prop_mercy", "prop_idle",
]
const LEGACY: Array = ["old_northcairn", "old_safety"]
const GLYPHS: Array = ["glyph_teal", "glyph_amber"]

static var _cache: Dictionary = {}


## Loads (and caches) a decal's albedo/emission pair. Cached because a layer
## places dozens and every Decal node holding its own copy of a 1024×256 texture
## would be several hundred megabytes for no reason.
static func textures(name: String) -> Array:
	if _cache.has(name):
		return _cache[name]
	var albedo: Texture2D = load(DIR + name + ".png") as Texture2D
	var emission: Texture2D = load(DIR + name + "_e.png") as Texture2D
	if albedo == null:
		push_warning("[DecalLib] missing decal '%s' — run tools/make_decals.py" % name)
	var pair: Array = [albedo, emission]
	_cache[name] = pair
	return pair


## One decal, flat against a wall.
##
## `yaw` matches the wall-slot convention in GeometryKit: the decal faces the
## same way the wall's detailed side does. A Decal projects along its own -Y, so
## the node is pitched 90 degrees to lie against a vertical surface.
static func place(parent: Node3D, name: String, at: Vector3, yaw_deg: float,
		size: Vector2 = WIDE, fade: float = 1.0) -> Decal:
	var pair: Array = textures(name)
	if pair[0] == null:
		return null

	var decal: Decal = Decal.new()
	decal.name = "Decal_" + name
	decal.texture_albedo = pair[0] as Texture2D
	if pair[1] != null:
		decal.texture_emission = pair[1] as Texture2D
	decal.emission_energy = EMISSION_ENERGY * fade
	decal.size = Vector3(size.x, DEPTH, size.y)
	decal.upper_fade = 0.25
	decal.lower_fade = 0.25
	# Projected regardless of surface angle. The obvious setting is a normal fade
	# — only project onto surfaces roughly facing the same way, so a sign on a
	# wall cannot smear across the floor in front of it — but the kit's chamfers
	# put enough angle on every edge that anything above zero drops the sign out
	# at exactly the corners a player reads it from. The size and placement keep
	# it on its wall instead.
	decal.normal_fade = 0.0
	decal.modulate = Color(1.0, 1.0, 1.0, fade)
	# Signage is not worth a full-resolution projection from across the room.
	decal.distance_fade_enabled = true
	decal.distance_fade_begin = 26.0
	decal.distance_fade_length = 10.0
	decal.position = at
	# A Decal projects along its own **-Y**. Unrotated it paints the floor; +90
	# about X swings -Y onto -Z, and the yaw then turns that into whichever wall
	# this slot belongs to. The sign matters and is easy to get backwards: at
	# -90 the projector fires away from the wall into the empty room, the decal
	# lands on nothing, and you get a layer that reports 43 decals and shows
	# none. Node3D uses YXZ euler order, so the yaw here is applied outermost,
	# which is exactly what a wall-facing rotation wants.
	decal.rotation = Vector3(PI * 0.5, deg_to_rad(yaw_deg), 0.0)
	parent.add_child(decal)
	return decal


## Deterministic pick from a list, hashed off world position and the layer seed.
## Never touches the generator's RNG stream — see the class docstring.
static func pick(options: Array, x: float, z: float, salt: int, seed_value: int) -> String:
	if options.is_empty():
		return ""
	var h: int = hash(Vector4i(int(roundf(x)), int(roundf(z)), salt,
			seed_value & 0x7FFFFFFF))
	return String(options[absi(h) % options.size()])


## 0..1 roll from the same hash space, for density decisions.
static func roll(x: float, z: float, salt: int, seed_value: int) -> float:
	var h: int = hash(Vector4i(int(roundf(x)), int(roundf(z)), salt + 977,
			seed_value & 0x7FFFFFFF))
	return float(absi(h) % 10000) / 10000.0


## Appends the corruption suffix for a layer's depth.
##
## DESIGN.md's aesthetic gradient: surface rings are clean modern datacenter,
## deep rings are legacy architecture that has half fallen over. Signage decays
## on the same curve — a layer-2 notice is worn, a layer-18 one has lost most of
## its glyphs to dead pixels and scanline tears. Legacy plates decay faster than
## MOTHER's own, because nothing has maintained them since the builders left.
static func variant(name: String, depth: float, x: float, z: float,
		seed_value: int) -> String:
	if name.begins_with("num_"):
		# A layer number you cannot read is a usability problem, not atmosphere.
		return name
	var bias: float = 0.35 if name.begins_with("old_") else 0.0
	var chance: float = clampf(depth * 1.15 + bias, 0.0, 1.0)
	var r: float = roll(x, z, 4211, seed_value)
	if r > chance:
		return name
	return name + ("_c2" if r < chance * 0.35 else "_c1")
