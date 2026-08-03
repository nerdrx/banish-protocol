class_name PartitionBuilder
extends GeometryKit
## THE PARTITION — the sector of MOTHER the crew has permanently carved out, and
## the place they exist between intrusions.
##
## DESIGN.md, "Future backlog / The Partition": *a bare compromised maintenance
## bay; grows with the crew. **The hub IS the menu** — walk to the injection rig
## to pick a backdoor and launch, the Compiler terminal to spend, a roster panel
## to invite friends; crewmates physically stand in the room with you while you
## ready up. Traditional menus reduce to a thin fallback.*
##
## ## What the room has to say
##
## Every other space in this game is MOTHER's, and reads that way: sleek matte
## monoliths, hairline teal inlay, an architecture that was specified. The
## Partition is the one space that is the CREW's, and the whole composition is
## built on that contrast — her shell, their hardware bolted through it. Her
## fixtures are teal and flush; every human thing in here is amber, clamped on,
## cable-fed from a tap somebody drilled, and slightly the wrong size for the
## bracket it is sitting in. That is the cassette-futurism rule (DESIGN.md
## "HUD — cassette futurism") standing up in three dimensions: the player is a
## human-built program, so the tools they brought are old human tech.
##
## ## Authored, and that is load-bearing
##
## This builder consumes **no RNG stream**. Its only randomness is a local
## `RandomNumberGenerator` on a literal seed, the trick `LayerBuilder` already
## uses for the greybox vault, so nothing here can ever advance `Rng` and shift
## what `LayerGraph.generate(seed, layer)` produces. `--dumplayer` byte-identity
## is an invariant of the project; a hub that quietly moved the generator would
## break it in the one way nobody would think to look for.
##
## ## Motivation (DESIGN.md pillar 6)
##
## Nothing is scattered. The rig is a load, so cable trunks run TO it from the two
## wall junctions the crew tapped. The clutter accretes at the two stations where
## work happens and nowhere else. The gantry overhead is MOTHER's own maintenance
## catwalk, unreachable, which is why nothing on it is the crew's. There is no
## wind in a sealed machine space, so nothing sways: the only motion in here is
## the rig's own rings and the data pulses in her conduits.

# --- the layout, on the kit's 4 m lattice ------------------------------------
#
# Three volumes and two links. The hall is the room; the alcoves are where the
# crew put the two machines they care about, far enough apart that going to spend
# and going to read are different walks.

const HALL: Dictionary = {
	"index": 0, "min": Vector2(-16.0, -16.0), "max": Vector2(16.0, 8.0), "h": 8.0,
	"doors": [{"wall": "w", "at": -6.0}, {"wall": "e", "at": -6.0}],
}
## West alcove: the workshop. The Compiler, a bench, and everything that gets
## dragged out of a run and taken apart.
const WORKSHOP: Dictionary = {
	"index": 1, "min": Vector2(-36.0, -12.0), "max": Vector2(-24.0, 4.0), "h": 4.0,
	"doors": [{"wall": "e", "at": -6.0}],
}
## East alcove: records. One terminal, and the racks the crew reads their own
## program off.
const RECORDS: Dictionary = {
	"index": 2, "min": Vector2(24.0, -12.0), "max": Vector2(36.0, 4.0), "h": 4.0,
	"doors": [{"wall": "w", "at": -6.0}],
}
const LINK_WEST: Dictionary = {
	"id": "w", "min": Vector2(-24.0, -8.0), "max": Vector2(-16.0, -4.0), "axis": "x",
}
const LINK_EAST: Dictionary = {
	"id": "e", "min": Vector2(16.0, -8.0), "max": Vector2(24.0, -4.0), "axis": "x",
}

# --- the furniture, published to Layer ---------------------------------------

## The injection rig. North half of the hall, under the only real hole in the
## ceiling — the shaft the crew goes down. `Layer` publishes this as
## `shaft_position`, which is what makes `Run._update_muster` count the crew on
## this pad with no changes at all.
const RIG: Vector3 = Vector3(0.0, 0.0, -10.0)
## The arrival pad. South half, facing the rig across the hall, so the first thing
## a returning crew sees is the way back down. Published as `uplink_position`.
const ARRIVAL: Vector3 = Vector3(0.0, 0.0, 2.0)
## The injection selector, at the rig's shoulder — you dial the depth standing
## where you are about to commit to it.
const SELECTOR: Vector3 = Vector3(-5.0, 0.0, -7.0)
const COMPILER: Vector3 = Vector3(-30.0, 0.0, -8.0)
const PROGRAM: Vector3 = Vector3(30.0, 0.0, -8.0)
## MOTHER's lens: a sealed aperture high on the hall's north wall, above the rig.
## She watches the sector she lost; the crew works underneath it.
const LENS: Vector3 = Vector3(0.0, 5.6, -15.6)

## The framing shot: stood on the arrival pad looking north up the hall at the
## rig, which is the composition the whole room is laid out around. Yaw 0 is -Z.
const GALLERY: Vector3 = Vector3(0.0, 0.0, 6.0)
const GALLERY_YAW: float = 0.0

## Crew spawn ring, on and around the arrival pad, all facing the rig. Four,
## because `Net.MAX_CREW` is four and `_spawn_point` wraps with a modulo — a
## fifth agent standing inside the first one is the bug that rule exists to stop.
const SPAWNS: Array[Vector3] = [
	Vector3(-2.4, 0.0, 3.2),
	Vector3(2.4, 0.0, 3.2),
	Vector3(-5.0, 0.0, 5.4),
	Vector3(5.0, 0.0, 5.4),
]

## Human amber. Every crew-installed fixture in the bay runs this, against
## MOTHER's teal, and the split is the whole read of the room.
const CREW_AMBER: Color = Color(1.0, 0.66, 0.28)
## Where the crew tapped her power. Both are real sources with real loads hanging
## off them — see `_route_power`.
const TAP_WEST: Vector3 = Vector3(-15.6, 3.4, -10.0)
const TAP_EAST: Vector3 = Vector3(15.6, 3.4, -10.0)

## Local dressing generator. A literal seed, never `Rng` — see the header.
const DRESS_SEED: int = 20260803


func _build_content() -> void:
	# The rig sits under a genuine hole rather than under a light pretending to be
	# one. `ceiling_apertures` has to be filled BEFORE the shell goes up: the
	# ceiling field reads it as it stamps, so a shaft the generator learns about
	# afterwards is a light with a slab across it (INTEGRATION2 §4).
	ceiling_apertures[0] = Vector2(RIG.x, RIG.z)

	var hall: Rect2 = kit_room(HALL)
	kit_room(WORKSHOP)
	kit_room(RECORDS)
	kit_corridor(LINK_WEST)
	kit_corridor(LINK_EAST)

	_build_gantry(hall)
	technical_ceiling(hall, STOREY * 2.0, [])
	_route_power()
	_dress_rig()
	_dress_arrival()
	_dress_muster_walk()
	_dress_workshop()
	_dress_records()
	_light_hall(hall)

	_fixtures.add_child(DropInterface.create(RIG))
	_fixtures.add_child(InjectionDial.create(SELECTOR))
	_fixtures.add_child(ArrivalPad.create(ARRIVAL))
	_fixtures.add_child(ProgramTerminal.create(PROGRAM, PI))
	_fixtures.add_child(MotherLens.create(LENS))

	# The crew's Compiler. Index 0 and `sanctuary` true: the Partition is safe by
	# construction and stocks like a backdoor room, which is the whole point of
	# having carved it out. It is the SAME class the layers use — a hub-only copy
	# of a shop would be a second implementation of the purchase path, and the
	# host validation lives in that path.
	var compiler: CompilerTerminal = CompilerTerminal.create(
			0, COMPILER, 0.0, Balance.COMPILER_SANCTUARY_BONUS + 1, true)
	compiler.add_to_group("compilers")
	_fixtures.add_child(compiler)


# ------------------------------------------------------------------ structure --

## MOTHER's maintenance catwalk, running the hall's two long walls one storey up.
##
## Intricacy law: a 32x24 hall with nothing between the floor and the ceiling is
## an empty plaza, which the law names as a failure mode outright. This is the
## midground — something for a beam to break on, something for the aperture shaft
## to stripe, and a silhouette line at head height for the whole room.
##
## Deliberately unreachable, and that is the motivation: it is HERS. There is no
## ramp because the crew never had a reason to build one — everything they need is
## on the floor. Nothing of theirs is up there.
func _build_gantry(hall: Rect2) -> void:
	var y: float = STOREY
	for side: float in [-1.0, 1.0]:
		var x: float = hall.position.x + 2.0 if side < 0.0 else hall.end.x - 2.0
		var from: Vector3 = Vector3(x, y, hall.position.y + 3.0)
		var to: Vector3 = Vector3(x, y, hall.end.y - 3.0)
		# Walking plate, its underside, and the brackets carrying it. The joists are
		# what the intricacy law is about: a player under a bare four-metre plate is
		# looking at exactly the surface that has to hold up at thirty centimetres.
		var mid: Vector3 = (from + to) * 0.5
		var run: float = absf(to.z - from.z)
		_mesh_box(mid + Vector3(0.0, -0.09, 0.0), Vector3(2.2, 0.18, run), MAT_GRATE)
		_mesh_box(mid + Vector3(0.0, -0.24, 0.0), Vector3(1.9, 0.12, run), MAT_TRIM)
		var joists: int = int(run / 2.0)
		for i: int in joists + 1:
			var z: float = lerpf(from.z, to.z, float(i) / float(maxi(joists, 1)))
			_mesh_box(Vector3(x, y - 0.32, z), Vector3(2.3, 0.16, 0.14), MAT_CONDUIT)
			# Bracket back to the wall it hangs off. A cantilever with no visible
			# fixing is a plate floating in the air.
			_mesh_box(Vector3(x + side * 1.4, y - 0.62, z),
					Vector3(0.9, 0.1, 0.1), MAT_CONDUIT)
		_railing(from + Vector3(-side * 1.05, 0.0, 0.0),
				to + Vector3(-side * 1.05, 0.0, 0.0), [])


## The crew's power, as a routed graph rather than as decoration.
##
## DESIGN.md pillar 6: cables run FROM a source TO a load. There are exactly two
## sources in this room — the junctions the crew drilled into MOTHER's wall trunks
## — and every crew fixture in the bay is fed from one of them along a run you can
## follow with your eyes. Nothing is sprinkled: if a cable is there, something at
## the end of it is switched on.
func _route_power() -> void:
	for tap: Vector3 in [TAP_WEST, TAP_EAST]:
		# The tap itself: a clamped-on box with a status slot, sitting proud of her
		# flush wall because it was never meant to be there.
		_box(tap, Vector3(1.1, 1.3, 0.9), MAT_CONDUIT)
		_mesh_box(tap + Vector3(0.0, 0.2, signf(-tap.x) * 0.48),
				Vector3(0.6, 0.05, 0.02), _make_emissive(CREW_AMBER, 0.7))
		LightRig.practical(_fixtures, tap + Vector3(0.0, -0.5, signf(-tap.x) * 0.8),
				0.7, 4.2, CREW_AMBER).name = "Practical_tap_%d" % int(signf(tap.x))

	# Trunk west tap -> rig, and east tap -> rig. Both drop to the deck, run along
	# it, and climb the rig's mast: the rig is the load, so the cable arrives at it.
	for tap: Vector3 in [TAP_WEST, TAP_EAST]:
		var down: Vector3 = Vector3(tap.x, 0.35, tap.z)
		_conduit_run(tap + Vector3(0.0, -0.6, 0.0), down, 0.14)
		var elbow: Vector3 = Vector3(signf(tap.x) * 3.4, 0.35, RIG.z)
		_conduit_run(down, Vector3(down.x, 0.35, RIG.z), 0.14)
		_conduit_run(Vector3(down.x, 0.35, RIG.z), elbow, 0.14)
		_conduit_run(elbow, elbow + Vector3(0.0, 1.4, 0.0), 0.1)
		# Cable cleats every couple of metres along the deck run, because a trunk
		# lying loose on a floor is a trunk nobody installed.
		var span: float = absf(down.x - elbow.x)
		var cleats: int = maxi(int(span / 2.5), 1)
		for i: int in cleats:
			var t: float = float(i + 1) / float(cleats + 1)
			_mesh_box(Vector3(lerpf(down.x, elbow.x, t), 0.16, RIG.z),
					Vector3(0.22, 0.32, 0.3), MAT_TRIM)

	# Branch west tap -> workshop, east tap -> records. Through the link corridors
	# at head height, which is also what stops those two corridors reading as bare
	# tubes: the thing running down them has somewhere to be going.
	_branch_to(TAP_WEST, Vector3(COMPILER.x, 2.6, COMPILER.z))
	_branch_to(TAP_EAST, Vector3(PROGRAM.x, 2.6, PROGRAM.z))


func _branch_to(tap: Vector3, load_point: Vector3) -> void:
	var corner: Vector3 = Vector3(tap.x, 2.9, -6.0)
	var through: Vector3 = Vector3(load_point.x, 2.9, -6.0)
	_conduit_run(tap + Vector3(0.0, 0.4, 0.0), corner, 0.11)
	_conduit_run(corner, through, 0.11)
	_conduit_run(through, load_point, 0.11)
	# Hangers under the corridor run. Same rule as the cleats.
	var span: float = absf(through.x - corner.x)
	var hangers: int = maxi(int(span / 3.0), 1)
	for i: int in hangers:
		var t: float = float(i + 1) / float(hangers + 1)
		var at: Vector3 = corner.lerp(through, t)
		_mesh_box(at + Vector3(0.0, 0.45, 0.0), Vector3(0.06, 0.9, 0.06), MAT_CONDUIT)


# ------------------------------------------------------------------- dressing --

## The rig's floor: a marked-out muster pad the size of the muster radius, so
## "am I on it" is a thing you read off the ground rather than off the HUD.
func _dress_rig() -> void:
	var r: float = Balance.SHAFT_MUSTER_RADIUS
	var edge: StandardMaterial3D = _make_emissive(SYSTEM_TEAL, 0.42)
	var hazard: StandardMaterial3D = _make_emissive(CREW_AMBER, 0.3)
	# Four hazard bars marking the corners of the pad, not a painted circle: the
	# crew stencilled this, and stencils are straight lines.
	for i: int in 4:
		var angle: float = TAU * (float(i) + 0.5) / 4.0
		var at: Vector3 = RIG + Vector3(cos(angle), 0.0, sin(angle)) * (r - 0.6)
		_mesh_box(at + Vector3(0.0, 0.012, 0.0), Vector3(2.4, 0.024, 0.16), hazard)
		_mesh_box(at + Vector3(0.0, 0.012, 0.0), Vector3(0.16, 0.024, 2.4), hazard)
	# Her own aperture collar, up in the ceiling where the hole is. This is her
	# hardware and it is teal.
	_mesh_box(RIG + Vector3(0.0, STOREY * 2.0 - 0.2, 0.0),
			Vector3(4.6, 0.3, 4.6), MAT_CONDUIT)
	_port_ring(RIG + Vector3(0.0, STOREY * 2.0 - 0.42, 0.0), 4.2, 4.2)
	_mesh_box(RIG + Vector3(0.0, 0.014, 0.0), Vector3(3.6, 0.028, 0.05), edge)
	_mesh_box(RIG + Vector3(0.0, 0.014, 0.0), Vector3(0.05, 0.028, 3.6), edge)


## Where a crew comes home. A low plinth with a lip, so the arrival reads as a
## place you are set down on rather than as a patch of floor.
func _dress_arrival() -> void:
	# M10 Z-FIGHT: the plinth's underside was laid exactly on the plane the hub's
	# floor modules present their own undersides at — 81 m2 of coplanar
	# same-facing surface, the largest single finding `--auditz` reported
	# anywhere. Lifted clear; the lip is 18 cm tall, so 6 mm is invisible.
	_box(ARRIVAL + Vector3(0.0, 0.09 + ZFIGHT_STANDOFF, 0.0),
			Vector3(9.0, 0.18, 9.0), MAT_GRATE)
	_mesh_box(ARRIVAL + Vector3(0.0, 0.2, 0.0), Vector3(8.2, 0.05, 8.2), MAT_TRIM)
	for corner: Vector3 in [Vector3(-4.2, 0.0, -4.2), Vector3(4.2, 0.0, -4.2),
			Vector3(-4.2, 0.0, 4.2), Vector3(4.2, 0.0, 4.2)]:
		_box(ARRIVAL + corner + Vector3(0.0, 0.6, 0.0),
				Vector3(0.34, 1.2, 0.34), MAT_CONDUIT)
		_mesh_box(ARRIVAL + corner + Vector3(0.0, 1.22, 0.0),
				Vector3(0.24, 0.06, 0.24), _make_emissive(CREW_AMBER, 0.8))


## The twelve metres between the arrival pad and the rig — the walk every dive
## starts with, and the first thing the room has to not be empty in.
##
## Intricacy law, the part of it that names empty floor plazas as a failure mode
## outright: the first capture of this hall had nothing at all between the pad's
## ring and the rig's mast, so the walk read as crossing a car park. What goes
## there has to be *motivated* rather than sprinkled, and there is one obviously
## true thing about that strip of floor: it is where a crew stages what they are
## about to carry down. So it gets a staging island — gear bays either side of a
## stencilled walkway — and nothing in the middle, because the middle is the path.
func _dress_muster_walk() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = DRESS_SEED + 1
	var stencil: StandardMaterial3D = _make_emissive(CREW_AMBER, 0.22)

	# The walkway, stencilled by the crew: chevrons pointing at the rig. Painted
	# on, so they are flat, dim, and interrupted where feet have worn them.
	for i: int in 7:
		var z: float = ARRIVAL.z - 2.0 - float(i) * 1.6
		if i == 3:
			continue  # worn through in the middle, where everybody stands.
		for side: float in [-1.0, 1.0]:
			_mesh_box(Vector3(side * 0.55, 0.012, z), Vector3(1.1, 0.024, 0.14), stencil)

	# Gear bays, one either side. Low racking with crates on it — the shapes are
	# waist height on purpose: tall enough to break the floor plane and read as
	# midground, short enough that they never block the sightline from the pad to
	# the rig, which is the composition the whole room is laid out around.
	for side: float in [-1.0, 1.0]:
		var bay: float = side * 5.4
		_box(Vector3(bay, 0.42, -3.4), Vector3(2.6, 0.84, 5.6), MAT_CONDUIT)
		_mesh_box(Vector3(bay, 0.86, -3.4), Vector3(2.4, 0.06, 5.4), MAT_GRATE)
		for i: int in 4:
			var z: float = -5.6 + float(i) * 1.5
			var s: float = rng.randf_range(0.5, 0.85)
			_data_block(Vector3(bay + rng.randf_range(-0.5, 0.5), 0.9, z),
					Vector3(s, s * rng.randf_range(0.6, 1.0), s),
					rng.randf_range(-0.4, 0.4))
		# The bay's own strip light, under the shelf lip. A fixture the crew put
		# where they needed to see what they were packing.
		_mesh_box(Vector3(bay, 0.78, -3.4), Vector3(2.0, 0.03, 0.05),
				_make_emissive(CREW_AMBER, 0.6))
		LightRig.practical(_fixtures, Vector3(bay, 0.72, -3.4), 0.55, 4.4,
				CREW_AMBER).name = "Practical_bay_%d" % int(side)


## The workshop. Clutter accretes where work happens, and this is where the crew
## takes a run apart: a bench, spare racking, spools of the cable they have been
## running, and one lamp on a stand that somebody dragged over.
func _dress_workshop() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = DRESS_SEED

	# The bench, against the north wall, facing into the room.
	_box(Vector3(-30.0, 0.45, -11.0), Vector3(6.0, 0.9, 1.1), MAT_CONDUIT)
	_mesh_box(Vector3(-30.0, 0.92, -11.0), Vector3(5.7, 0.06, 0.95), MAT_TRIM)
	for i: int in 5:
		var x: float = -32.4 + float(i) * 1.2
		# Salvage on the bench, in the sizes a hand carries.
		_data_block(Vector3(x, 0.95, -11.0 + rng.randf_range(-0.2, 0.2)),
				Vector3(rng.randf_range(0.3, 0.5), rng.randf_range(0.2, 0.4),
						rng.randf_range(0.3, 0.5)), rng.randf_range(-0.5, 0.5))
	# Racking behind it. Two, not eight: the Partition starts BARE and grows with
	# the crew (DESIGN.md), so the room has to read as under-furnished on purpose.
	_data_rack(Vector3(-34.6, 0.0, -5.0), Vector3(1.5, 2.4, 0.9), PI * 0.5,
			Color(0.34, 0.9, 1.0), 5)
	_data_rack(Vector3(-34.6, 0.0, -2.6), Vector3(1.5, 2.4, 0.9), PI * 0.5,
			Color(0.34, 0.9, 1.0), 5)
	# Cable spools by the tap run, because that is what the crew has been doing
	# with the cable.
	for i: int in 3:
		var at: Vector3 = Vector3(-26.0 + float(i) * 0.9, 0.0, 1.0)
		_box(at + Vector3(0.0, 0.34, 0.0), Vector3(0.7, 0.68, 0.7), MAT_CONDUIT)
	# A stand lamp aimed at the bench: the one light in this room that a human put
	# where they wanted it.
	_box(Vector3(-27.0, 1.1, -9.4), Vector3(0.12, 2.2, 0.12), MAT_CONDUIT)
	LightRig.key(_fixtures, Vector3(-27.0, 2.2, -9.4), Vector3(-30.0, 0.9, -11.0),
			2.6, LightRig.GOBO_SLATS, 46.0, CREW_AMBER, 12.0).name = "Key_bench"


## Records. Two racks and a terminal — the crew reads what they ARE off a screen
## bolted to her wall, and the room is otherwise empty because there is nothing
## else in it yet.
func _dress_records() -> void:
	for i: int in 4:
		var z: float = -9.0 + float(i) * 2.2
		_data_rack(Vector3(34.6, 0.0, z), Vector3(1.4, 2.6, 0.9), -PI * 0.5,
				Color(0.36, 0.94, 1.0), 6)
	_box(Vector3(30.0, 0.4, -3.0), Vector3(3.4, 0.8, 1.0), MAT_CONDUIT)
	_data_block(Vector3(29.2, 0.85, -3.0), Vector3(0.5, 0.35, 0.5), 0.3)
	LightRig.practical(_fixtures, Vector3(30.0, 2.4, -6.0), 0.9, 6.0,
			CREW_AMBER).name = "Practical_records"


## The hall's light events, in the order the eye should find them.
##
## One hero shaft down the aperture onto the rig (DESIGN.md: "every important room
## earns one readable light event", and the crew's path crosses it — the walk from
## the arrival pad to the rig goes straight through it, silhouetting whoever is
## already standing there). Then two rakes along the gantry to give the midground
## an edge, then the practicals that are actually visible fixtures.
func _light_hall(hall: Rect2) -> void:
	var mid: Vector2 = hall.position + hall.size * 0.5
	LightRig.key(_fixtures, RIG + Vector3(0.0, STOREY * 2.0 - 0.5, 0.0), RIG,
			5.4, LightRig.GOBO_APERTURE, 40.0, LightRig.KEY_COLD,
			STOREY * 2.4).name = "Key_rig_aperture"
	for side: float in [-1.0, 1.0]:
		var x: float = hall.position.x + 2.0 if side < 0.0 else hall.end.x - 2.0
		LightRig.accent(_fixtures, Vector3(x - side * 0.6, STOREY * 2.0 - 0.6, mid.y),
				Vector3(x, STOREY - 0.2, mid.y), 0.85, LightRig.TEAL, 66.0,
				LightRig.GOBO_DUST, 18.0).name = "Accent_gantry_%d" % int(side)
	# The arrival pad's own wash, warm, low and short-ranged: it is the crew's
	# fixture and it lights the plinth, not the hall.
	LightRig.practical(_fixtures, ARRIVAL + Vector3(0.0, 1.6, 0.0), 1.1, 7.0,
			CREW_AMBER).name = "Practical_arrival"
	LightRig.practical(_fixtures, SELECTOR + Vector3(0.0, 1.9, 0.0), 0.7, 4.0,
			CREW_AMBER).name = "Practical_selector"

	# Two hung work lamps over the walk between the pad and the rig. The crew put
	# these here and they are the reason you can see the floor you are crossing —
	# this is the one room in the game where somebody wanted the lights on. Fed off
	# the same trunk that feeds the rig; the drop cable is emitted with them, so
	# they are lamps hanging off something rather than lamps floating.
	for i: int in 2:
		var z: float = -1.4 - float(i) * 4.6
		var mount: Vector3 = Vector3(0.0, STOREY * 2.0 - 0.6, z)
		var lamp: Vector3 = Vector3(0.0, 4.3, z)
		_conduit_run(mount, lamp + Vector3(0.0, 0.3, 0.0), 0.05)
		_mesh_box(lamp, Vector3(1.1, 0.22, 0.5), MAT_CONDUIT)
		_mesh_box(lamp + Vector3(0.0, -0.13, 0.0), Vector3(0.9, 0.05, 0.34),
				_make_emissive(CREW_AMBER, 1.1))
		LightRig.key(_fixtures, lamp + Vector3(0.0, -0.2, 0.0),
				Vector3(0.0, 0.0, z), 3.2, LightRig.GOBO_SLATS, 62.0,
				CREW_AMBER, 12.0, false).name = "Key_worklamp_%d" % i

	# And a wash up MOTHER's own wall behind the rig, so her lens is a thing you
	# can see watching rather than a prop in the dark. Cold, wide, unshadowed —
	# hers, and nothing like the amber the crew works under.
	LightRig.accent(_fixtures, Vector3(0.0, 2.2, -11.6), LENS,
			1.15, LightRig.TEAL, 52.0, LightRig.GOBO_DUST, 12.0).name = "Accent_lens"


# ------------------------------------------------------------------- spawns --

func get_spawn_point(index: int) -> Transform3D:
	# Basis identity is yaw 0, which is -Z, which is north: everybody arrives
	# looking up the hall at the rig. The first thing you see in the Partition is
	# the way back down.
	return Transform3D(Basis.IDENTITY, SPAWNS[index % SPAWNS.size()])
