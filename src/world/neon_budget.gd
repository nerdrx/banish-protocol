class_name NeonBudget
extends RefCounted
## M10: how much of a frame the glowing teal inlay is allowed to own.
##
## READ THIS FIRST. There are now TWO independent axes in this file and only the
## second one ships changed:
##
##   `--neon full|half|mother|wash`  M10's density arms. Still at FULL, i.e.
##                                   still changing nothing, for the measured
##                                   reason in "WHAT THE A/B ACTUALLY FOUND".
##   `--cyan cut|legacy`             M10b's cut. DEFAULT `cut`. This is the one
##                                   that changed the picture; see
##                                   "M10b THE CUT" further down.
##
## ## The question this exists to answer
##
## Three sessions of user feedback said the same sentence — "the graphics need to
## get more alien like" — after we shipped motivated gobos, work-light practicals,
## MLI foil, soft penumbras and chamfered bevels. So the gap was never lighting
## TECHNIQUE. Put a NULLVOID bus hall next to the Alien: Isolation reference and
## the difference is blunt: the reference is a cramped space packed with
## bolted-on hardware that a work light rakes across, and ours is a dark volume
## with about twenty glowing cyan pinstripes in it. Ours reads Tron. The
## pinstripes are load-bearing for that reading, and they were never measured.
##
## This class is the measuring instrument. It gates every decorative emissive run
## the kit draws behind a named DENSITY ARM so the same room, same seed, same
## camera can be photographed at three densities and judged against the
## reference instead of against an assumption.
##
##     -- --neon full     every trace the kit has always drawn (pre-M10)
##     -- --neon half     perimeter runs keep their horizontals, lose their
##                        vertical branches; floor grid off; gates dimmed
##     -- --neon mother   inlay is reserved for MOTHER'S OWN SYSTEMS
##
## ## What "MOTHER's systems only" means, stated as a rule and not a dimmer
##
## The motivation law does not accept "fewer, because it looked busy". Every
## surviving run has to answer *does this make sense here*, so the `mother` arm
## is a GRAMMAR, not a percentage:
##
##   a GATE keeps its frame       — access control is hers, she lights what she
##                                  controls, and it is the one emissive the
##                                  player navigates by from the far end of a
##                                  dark corridor. Untouched.
##   a TRACE MODULE keeps its own — WALL_4x4_TRACE is a wall panel with a channel
##                                  cut in it and a light in the channel. The
##                                  glow belongs to a piece of hardware the
##                                  player can walk up to. Untouched.
##   a CORRIDOR keeps its floor   — the centre run is wayfinding that points both
##     line, loses its wall runs    ways in the dark. The two waist-height runs
##                                  down the walls are the pinstripes.
##   a ROOM gets perimeter runs   — a vault, a siphon plant, a drop-shaft trunk
##     ONLY if it is a system       ARE her infrastructure and read as powered.
##                                  A bus hall and a nest are rooms she has
##                                  merely built, and they go dark and physical.
##   the FLOOR GRID survives only — everywhere else it is the single most
##     in the vault                 videogame element in the kit.
##
## ## WHAT THE A/B ACTUALLY FOUND — read this before tuning anything here
##
## Four arms were shot at 3440x1440, same seed, same layer, same two cameras,
## and measured over the non-HUD region of the frame. The headline was a NULL
## RESULT for the arms and a very loud one for the diagnosis:
##
##     arm      mean Y    cyan px %   cyan share of frame luminance
##     full     0.0616      40.3%              92.2%
##     half     0.0599      40.4%              93.8%
##     mother   0.0599      40.4%              93.8%
##     wash     0.0602      40.5%              94.0%
##
## Two things follow, and they point opposite ways.
##
##   THE PREMISE IS RIGHT, AND UNDERSTATED. Forty per cent of the pixels in a
##   wide room shot are cyan-dominant and cyan carries ~93% of all the light in
##   the frame. The picture is not a dark industrial space with some teal in it;
##   it is a teal picture. That is the whole distance to the Alien: Isolation
##   reference, where the light is sodium/tungsten and the green is confined to
##   the CRT faces that are actually emitting it.
##
##   THE LEVERS IN THIS FILE ARE NOT WHERE IT LIVES. Removing every procedural
##   perimeter run, every vertical branch, the floor grid and both corridor wall
##   runs — and then, in `wash`, pulling the module practicals back 60% on top —
##   moved the frame by under 3%. The reason is structural and worth stating
##   plainly so nobody re-derives it: **`GeometryKit._build_room` and
##   `_build_corridor`, which is where most of these gates sit, are only used by
##   the hand-authored M1/M2 test layer.** A generated layer is assembled by
##   `kit_room` / `kit_corridor`, and its teal comes from somewhere else
##   entirely — the baked emissive channel on the WALL_4x4_TRACE kit module, how
##   often the variant table picks that module, `_kit_floor_field`'s inlay, and
##   the colour of the light rig itself (`LightRig.TEAL`).
##
## So the next pass at "less Tron" is a MATERIALS and LIGHT-COLOUR job — the kit
## module's emissive map, the variant table's appetite for trace modules, and the
## practicals' colour script — not a procedural-placement one. This class stays
## as the instrument that established that, and it ships at FULL so it changes
## nothing until somebody wires the arms into the path that actually runs.
##
## ## Determinism
##
## Nothing here rolls anything. The arm is a process-wide constant read from the
## command line once, and every call site is a pure function of the arm plus the
## room's own archetype — so two peers on the same build agree by construction
## and `--dumplayer` is unchanged within an arm.

## The arms, in the order they get denser.
## `wash` is `mother` plus the module-practical pullback — see `trace_glow`. It
## is ordered below MOTHER because it is the least neon of the four.
const WASH: int = -1
const MOTHER: int = 0
const HALF: int = 1
const FULL: int = 2

## The shipping default, and it is FULL — i.e. this class currently changes
## nothing about how the game looks. That is a deliberate, measured decision and
## not an oversight; see "WHAT THE A/B ACTUALLY FOUND" below.
const DEFAULT_ARM: int = FULL

## Sentinel for "not parsed yet". Deliberately not -1: WASH is -1, and using it
## as the sentinel would re-parse the command line on every call in that arm and,
## worse, make `wash` unreachable as a stored value.
const UNPARSED: int = -99

static var _arm: int = UNPARSED


## The arm this process is running. Parsed once, from the same
## `OS.get_cmdline_user_args()` every capture-only flag in the project reads —
## deliberately NOT a new branch in the shared `Debug` parser, which is
## append-only during parallel work.
static func arm() -> int:
	if _arm != UNPARSED:
		return _arm
	_arm = DEFAULT_ARM
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var at: int = args.find("--neon")
	if at >= 0 and at + 1 < args.size():
		match args[at + 1].strip_edges().to_lower():
			"wash":
				_arm = WASH
			"mother", "min", "off":
				_arm = MOTHER
			"half", "mid":
				_arm = HALF
			"full", "max", "pre-m10":
				_arm = FULL
			_:
				push_warning("[NeonBudget] unknown --neon arm '%s'" % args[at + 1])
	return _arm


static func arm_name() -> String:
	match arm():
		WASH:
			return "wash"
		MOTHER:
			return "mother"
		HALF:
			return "half"
		_:
			return "full"


## Archetypes that ARE MOTHER's running infrastructure rather than rooms she
## happens to have built. These keep their perimeter inlay in every arm.
##
## Typed literal, not a constructor call: a `const` may only hold a constant
## expression, and `PackedStringArray(...)` fails the parse and takes the
## autoloads down with it.
const SYSTEM_ROOMS: Array[String] = ["vault", "siphon", "shaft"]


## Whether a room's four-wall perimeter inlay runs at all.
static func room_perimeter(archetype: String) -> bool:
	match arm():
		FULL, HALF:
			return true
		_:
			return SYSTEM_ROOMS.has(archetype)


## Whether a perimeter run climbs vertical branches off itself. The branches are
## most of the pinstripe count in a frame — one horizontal becomes five lines the
## moment it starts sprouting.
static func trace_branches() -> bool:
	return arm() == FULL


## Whether the faint inlaid grid in a room's floor slab is drawn.
static func floor_grid(archetype: String) -> bool:
	match arm():
		FULL:
			return true
		HALF:
			return false
		_:
			# The vault floor is a data surface and the grid is what says so.
			return archetype == "vault"


## Whether a corridor's two waist-height wall runs are drawn. The corridor's
## CENTRE FLOOR run is wayfinding and is never gated — see the class docstring.
static func corridor_walls() -> bool:
	return arm() == FULL


## Multiplier on the gate frame's emission. Gates stay the brightest thing on the
## layer in every arm; `half` only stops them blooming into the pinstripes it is
## trying to be judged against.
static func gate_energy() -> float:
	match arm():
		FULL:
			return 1.0
		HALF:
			return 0.8
		_:
			return 0.85


## Multiplier on the perimeter inlay's own emission, where it survives.
static func trace_energy() -> float:
	return 1.0 if arm() == FULL else 0.8


## Multiplier on the WASH each trace module's own practical throws.
##
## THE ARM THAT THE MEASUREMENT ACTUALLY POINTED AT. The `full`/`half`/`mother`
## A/B came back a near-null: cutting every procedural perimeter run, every
## vertical branch, the floor grid and the corridor wall runs moved the frame's
## mean luminance by under 3% and its cyan pixel coverage by 0.2 points. The same
## measurement said something far louder about where the problem is:
##
##     40% of the non-HUD pixels in a wide room shot are cyan-dominant, and
##     cyan carries 92-94% of ALL the light in the frame.
##
## The neon does own the picture. It just does not live in the traces anyone
## would think to delete — it lives in `GeometryKit._trace_glow`, a 1.5-energy
## TEAL omni hung on every WALL_4x4_TRACE module, of which a layer has dozens.
## That fixture is not decoration, it is the layer's de-facto ambient, and it is
## the reason a NULLVOID room reads as lit BY cyan rather than as containing
## some. No amount of removing hairlines competes with the colour of the light.
##
## `--neon wash` is the arm that tests exactly that and nothing else: identical
## geometry to `mother`, the module practicals pulled back, so the difference in
## the numbers is attributable to the wash alone.
static func trace_glow() -> float:
	if not cyan_cut():
		return 0.4 if arm() == WASH else 1.0
	# M10b: the wash is no longer the room's light, so its energy comes down as
	# well as its reach. See `TRACE_GLOW_RANGE`.
	return TRACE_GLOW_ENERGY * (0.4 if arm() == WASH else 1.0)


# ============================================================ M10b THE CUT ====
#
# M10 measured the frame and left the diagnosis; this is the pass that acts on
# it. The measurement, re-taken with M10b's own instrument (scratchpad
# m10b/hue.py, thresholds stated in its docstring) so both arms of every A/B
# below come off ONE ruler:
#
#     frame            mean Y   cyan %px  cyan %Y   blue %Y   warm %Y
#     drop-shaft room  0.1200     29.0      57.7      40.9       0.4
#     bus junction     0.0600      3.9      16.8      74.2       5.8
#
# Read the last three columns together. COOL — cyan plus blue — carries 98.6% of
# the light in the room frame and 91.0% in the bus, which reproduces M10's ~93%
# headline; splitting it in two is what says where to aim. The cyan half is
# MOTHER's teal. The blue half is not teal at all: it is `LightRig.SERVICE` and
# `KEY_COLD` at hue 218 with saturation 0.22, i.e. the "cool-white maintenance
# light specified by an engineer" is in fact a blue light. And WARM — the
# tungsten and sodium practicals the colour-script milestone built, the fixtures
# the reference frame is actually lit by — carries FOUR TENTHS OF ONE PER CENT.
#
# So the cut has four fronts, and only the first is about teal:
#
#   1. THE TEAL STOPS BEING THE LIGHT. `_trace_glow` keeps its colour and loses
#      its reach: a channel cut in a wall spills onto the panel around it, it
#      does not light the far side of a 24 m hall. Trace modules also get rarer
#      (`WALL_VARIANTS`), the floor spine retreats to the rooms that ARE her
#      infrastructure, and the emissive strip's steady base level drops so the
#      moving packets carry the read instead of a continuous lit line. The teal
#      that survives is on hardware you can walk up to, which is the grammar
#      this class already wrote down.
#   2. THE SERVICE WHITE BECOMES WHITE. A saturation cap on the cool end of the
#      colour script, applied in `LightRig.cool_trim`. This is the single
#      biggest number in the pass and it costs no light at all — it is a hue
#      correction on fixtures that were always meant to be neutral.
#   3. TEAL LEAVES THE COLOUR SCRIPT WHERE IT WAS DECORATION. Arrival and shaft
#      lose their teal accent; the siphon's KEY stops being teal and its accent
#      becomes teal instead, so the room keeps both hues and the DOMINANT
#      fixture is the old sodium plumbing. Teal survives as a script colour only
#      in the vault and the siphon — her archive and her coolant loop.
#   4. THE PRACTICALS TAKE UP THE SLACK, which is also the answer to the user's
#      other note ("a tad bit brighter, not necessarily easier to see"). The lift
#      goes on the SHORT-RANGE fixtures that sit on visible sources, for exactly
#      the reason Photonics gives its CINEMA practical lift: it brightens the
#      pool around a lamp and leaves the far side of the room as black as it was.
#
# `-- --cyan legacy` puts every one of those back. Same build, one variable
# moved — the rule `--hardlight` and `--neon` were both written for.

## Multiplier on `_trace_glow`'s energy, and the divisor on its range.
##
## The range matters more than the energy and it is worth saying why. The fixture
## ran `omni_range = 6.4` with a 0.95 attenuation exponent, which is a room light
## by any reasonable definition — at 5 m it is still delivering a quarter of its
## output, and there are dozens of them. Pulling the reach in to 2.6 m turns it
## back into what it is supposed to be: the spill a lit groove throws on the panel
## it is cut into. The energy comes down alongside it rather than up, because the
## point is not to keep the same total light in a smaller volume; the point is
## that this fixture stops being the layer's ambient.
const TRACE_GLOW_ENERGY: float = 0.85
const TRACE_GLOW_RANGE: float = 3.6

## The steady glow of the dataflow strip, under the moving packets. 0.26 lit the
## whole strip continuously; at 0.15 the strip is mostly dark and the packets are
## the thing that reads, which is both less teal in the frame AND more contrast
## inside the effect — the "more contrast at the top" note, applied to the one
## surface in the kit that is genuinely a source.
const TRACE_BASE_LEVEL: float = 0.15
const TRACE_BASE_LEVEL_LEGACY: float = 0.26

## Saturation ceiling on the COOL end of the colour script (hue 205-265), applied
## by `LightRig.cool_trim`. SERVICE ships at 0.22 and reads as a blue light;
## real cool-white service lighting is a barely-tinted white. Deliberately below
## the 0.20 saturation floor the m10b instrument uses to call a pixel coloured at
## all, because the claim being made is that these fixtures are NOT a hue.
const COOL_SAT_CAP: float = 0.13

## Multiplier on every LightRig practical, on top of the Photonics tier gain.
##
## THE BRIGHTNESS NOTE, and the reason it is safe. "It needs to be a tad bit
## brighter, not necessarily easier to see, but brighter" is not a request for
## ambient — ambient is the one lift that IS "easier to see", because it raises
## the far side of the room by exactly as much as the near side. A practical is
## a 4-6 m fixture sitting on visible emissive geometry, so lifting it puts more
## light in the frame around a source the player can point at and adds nothing at
## all to what is visible across a hall. Same argument Photonics makes for
## PRACTICAL_GAIN_GI; this applies it at BASELINE, where the 60 fps promise and
## the user's actual playthrough both live.
##
## M8 shipped `PRACTICAL_PEAK` at 1.0 after a first cut at 1.18 blew a corridor
## floor-can into a white blob. That finding stands and this does not contradict
## it: the blob was a FOG artefact (the can's `light_volumetric_fog_energy` was
## 1.0 then and is 0.40 now), and a blown source is no longer automatically a
## defect — the reference frames this milestone is judged against have genuinely
## clipped bulbs and monitor faces in them. Clipping is measured per region now,
## not globally, and sources are allowed to blow.
const PRACTICAL_LIFT: float = 1.55

## The lift on the KEY and ACCENT layers, and it is a RESTORATION rather than a
## brightening — which is the distinction the darkness law turns on.
##
## Dosing the kit's emissive down removed real light from the frame: nine modules
## were glowing, SSIL was bouncing all of it onto the panels beside them, and the
## corridor's measured mean luminance fell 38% when the glow came off. That light
## was ambient by another name — it arrived everywhere at once, from surfaces
## nothing was shining on, which is exactly what makes a space look flat. So it
## comes back through the two fixtures whose job it was all along: a key aimed at
## the floor through a gobo, and a wash raking along a wall. Same photons, shaped.
##
## Measured to parity plus a little, which is where the "a tad bit brighter"
## note lands: the frame is not darker than it was and the light in it now has a
## direction and a source.
const KEY_LIFT: float = 1.24
const ACCENT_LIFT: float = 1.34

## The cool anchors of `Layer.GRADE_AMBIENT` / `GRADE_FOG`, rotated toward
## neutral at matched luminance. A hue change, not an exposure change — the same
## rule the grade table's own header states. Band 0 (the surface rings) was the
## offender at (0.075, 0.115, 0.200); bands 1 and 2 are already near-neutral and
## are left alone.
## Rec.709 luminance is held to 0.113 against the authored 0.1126 — a 0.4%
## difference, i.e. none — while saturation falls from 0.30 to 0.075. The first
## cut of this pair only went half way (sat 0.30) and measured as no change at
## all, which is the lesson: a "cooler neutral" that is still a THIRD saturated
## is not a neutral, it is a blue fill, and the flat ambient reaches every pixel
## in the frame whether a fixture is near it or not.
const GRADE_AMBIENT_SURFACE: Color = Color(0.111, 0.113, 0.120)
const GRADE_FOG_SURFACE: Color = Color(0.400, 0.405, 0.420)

## THE THIRD PLACE THE FRAME'S BLUE WAS HIDING, and the one that took a
## per-luminance-band census of a vault frame to find.
##
## `post_process.gdshader` adds a SHADOW LIFT — `shadow_tint * shadow_lift * dark`
## where `dark = 1 - smoothstep(0, 0.08, luma)` — so every pixel below 8% luma in
## the game, which in a NULLVOID frame is most of them, gets a constant additive
## colour. The tint was `vec3(0.36, 0.52, 0.78)`: hue 217 degrees at saturation
## 0.54. Censusing the vault frame by luminance band came back hue 215-216 in
## EVERY band including the brightest, which is the signature of an additive
## floor rather than of a light, and 217 is where it was coming from.
##
## Its JOB is right and is kept — "keep a silhouette readable against the void,
## and cool so the blacks stay blue-black instead of going muddy under glow" is a
## good note and it is the darkness pillar's friend. It just does not need to be
## a half-saturated blue to do it. Saturation 0.54 -> 0.17, and `SHADOW_LIFT` is
## re-scaled so the lift's Rec.709 LUMINANCE is identical to the old one
## (0.5047 * 0.0100 == 0.6172 * 0.0082): the silhouette is exactly as readable
## and the black is exactly as deep, it is simply no longer blue.
##
## Set from `Layer._apply_environment`, which already drives this material's LUT
## and exposure, rather than by editing the shader — `src/ui/*` belongs to
## another agent this session.
## Vector3, NOT Color, and that distinction cost a capture round. The uniform is
## `uniform vec3 shadow_tint : source_color`, and layer.tscn stores it as a
## `Vector3` — handing `set_shader_parameter` a Color for a vec3 uniform is a type
## mismatch the engine drops on the floor silently, so the first cut of this
## change measured as a perfect null and looked like a wrong diagnosis rather
## than a wrong type.
const SHADOW_TINT: Vector3 = Vector3(0.58, 0.62, 0.70)
const SHADOW_LIFT: float = 0.0082
const SHADOW_TINT_LEGACY: Vector3 = Vector3(0.36, 0.52, 0.78)
const SHADOW_LIFT_LEGACY: float = 0.010

static var _cut: int = -1


## False under `-- --cyan legacy`: the pre-M10b photograph, for the A/B.
##
## Read once and cached. This is asked inside `_wall_slot`, which runs for every
## wall module on the layer.
static func cyan_cut() -> bool:
	if _cut >= 0:
		return _cut == 1
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var at: int = args.find("--cyan")
	_cut = 1
	if at >= 0 and at + 1 < args.size():
		match args[at + 1].strip_edges().to_lower():
			"legacy", "pre-m10b", "full":
				_cut = 0
			"cut", "m10b":
				_cut = 1
			_:
				push_warning("[NeonBudget] unknown --cyan arm '%s'" % args[at + 1])
	if _cut == 0:
		print("[NeonBudget] --cyan legacy: pre-M10b neon values (capture flag)")
	return _cut == 1


## The kit's wall variant table. One entry in seven was a trace module before
## M10b and one in thirteen after — and the arithmetic is worth stating, because
## "one in seven" was itself already a reduction and it was not enough. A 24 m
## wall is six slots, so at one in seven very nearly every wall in the game has a
## lit channel in it; at one in thirteen a lit channel is something a particular
## wall has and its neighbour does not, which is the difference between a
## material and a feature.
##
## The extra slots go to PANEL and ARMOR rather than to a new module: the point
## of the change is that a wall is a wall.
const WALL_VARIANTS_CUT: Array = [
	"WALL_4x4_PANEL", "WALL_4x4_ARMOR", "WALL_4x4_PANEL", "SPLIT_2M",
	"WALL_4x4_ARMOR", "WALL_4x4_PANEL", "WALL_4x4_TRACE", "WALL_4x4_ARMOR",
	"WALL_4x4_PANEL", "SPLIT_2M", "WALL_4x4_ARMOR", "WALL_4x4_PANEL",
	"WALL_4x4_ARMOR",
]


## Whether a room's floor gets the inlaid trace spine down its centre.
##
## Corridors always keep theirs — it is wayfinding that points both ways in the
## dark, and this class has said so since M10. A ROOM is different: the spine
## runs the full depth of the room, it is a glowing cross in every cell it
## touches, and after the M10 scale pass a room is 438 m² rather than 211. So it
## stays only where the floor is genuinely a data surface, which is the same
## SYSTEM_ROOMS list the perimeter inlay already uses. A nest, which is supposed
## to be the darkest thing on the layer, was getting one — that was a bug, and
## this is where it stops.
static func room_floor_spine(archetype: String, dark: bool) -> bool:
	if not cyan_cut():
		return true
	return not dark and SYSTEM_ROOMS.has(archetype)
