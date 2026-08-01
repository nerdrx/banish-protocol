class_name DataShard
extends Node3D
## A fragment of MOTHER's data, lying where the generator dropped it.
##
## DESIGN.md "Data (salvage)": glowing shard pickups, auto-magnet on proximity,
## buffered weight slows you slightly. Placement is seeded (LayerGraph), so every
## peer builds the same shards in the same places and only the *taking* crosses
## the wire — an index and a peer id.
##
## The magnet is cosmetic and runs everywhere; the absorb is a host decision, so
## two players reaching for the same shard can never both bank it.
##
## ## What this looks like, and why it changed in M3.7
##
## M2 shipped this as a bright cyan octahedron hovering at chest height. Against
## the look-dev kit that stopped working: it was the only object in the game with
## no surface at all — a floating volume of pure emission next to walls carrying
## chamfers, roughness breakup and wet-floor reflections. It read as a debug
## gizmo somebody forgot to remove.
##
## It is now a **data chip lying on the deck**: a 13 cm hexagonal wafer, mostly
## dark machined material, with a thin emissive circuit inlay cut into its top
## face and a slow pulse. Discoverability comes from the pulse and from the
## reflection the wet floor throws back — not from the chip being a lantern. In a
## game whose first pillar is that unrendered space is near-black, salvage that
## lights the room it is lying in is salvage that has undone the pillar.
##
## Each shard also drops one or two **spent** wafers beside it, dark and inert.
## They are decoration, chosen deterministically from the shard index so every
## peer draws the same spill, and they exist because a single chip on a bare
## floor reads as placed while a small spill reads as dropped. Crucially they are
## NOT extra pickups: the graph's shard count is what the determinism dump
## records and what the economy is balanced against, and it has not moved.

## Slow drift on the inlay pulse. It is not a beacon; it is a chip idling.
const PULSE_RATE: float = 1.35
## Lift and spin only happen once a carrier is pulling the chip in.
const MAGNET_SPIN: float = 5.5
const MAGNET_LIFT: float = 0.55

## Chip geometry. 13 cm across and 12 mm thick — a physical object at a physical
## scale, which is most of what stops it reading as a UI element in the world.
const CHIP_RADIUS: float = 0.065
const CHIP_THICKNESS: float = 0.012

## How high a resting chip sits. It lies ON the deck now, clear of z-fighting
## with the floor plate and nothing more. Debug.--grab teleports the avatar to
## `shard.global_position - UP * REST_HEIGHT`, so this staying honest is what
## keeps the automated salvage run standing on the floor.
const REST_HEIGHT: float = 0.008

## Deepened from (0.42, 0.95, 1.0) in M3.7. The old value was nearly white to
## begin with, so any emission energy at all pushed all three channels through
## the ACES shoulder together and a shard rendered as a white blob rather than as
## something cyan and valuable. Saturation is what survives a tonemap; brightness
## is not.
const COLOUR: Color = Color(0.20, 0.84, 1.0)
## Emission on the inlay at rest, and the ceiling it pulses to. Both an order of
## magnitude below the old floating-crystal values: the inlay is a few square
## centimetres of surface, not a light source.
const INLAY_ENERGY: float = 0.5
const INLAY_PULSE: float = 0.34
## The pool under the chip. Small enough that a room full of them is still dark.
const GLOW_ENERGY: float = 0.22

var shard_index: int = 0
var value: int = 10

var _home: Vector3 = Vector3.ZERO
var _material: StandardMaterial3D = null
var _inlay_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _core: Node3D = null
var _taken: bool = false
var _absorb: float = 0.0
## 0..1 how far into the magnet pull this chip is. Drives the lift, the spin and
## the inlay brightening, so all three are one gesture instead of three timers.
var _magnet: float = 0.0


static func create(index: int, where: Vector3, worth: int) -> DataShard:
	var shard: DataShard = DataShard.new()
	shard.name = "DataShard%d" % index
	shard.shard_index = index
	shard.value = worth
	shard.position = where + Vector3.UP * REST_HEIGHT
	shard._home = shard.position
	shard._assemble()
	return shard


func _assemble() -> void:
	# One deterministic stream per shard, so the tilt of a chip and the spill
	# around it are the same on every client without a byte of replication.
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = hash(str(shard_index, ":chip"))

	# The wafer body. Machined and dark: this is the same material language as
	# the kit's panel trim, because a data chip and a wall panel came out of the
	# same factory.
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.075, 0.079, 0.09)
	_material.metallic = 0.62
	_material.roughness = 0.34

	# The inlay. Thin, recessed, and the only emissive surface on the object —
	# a few square centimetres rather than a hovering volume.
	_inlay_material = StandardMaterial3D.new()
	_inlay_material.albedo_color = COLOUR.darkened(0.7)
	_inlay_material.emission_enabled = true
	_inlay_material.emission = COLOUR
	_inlay_material.emission_energy_multiplier = INLAY_ENERGY
	_inlay_material.metallic = 0.0
	_inlay_material.roughness = 0.28
	_inlay_material.disable_receive_shadows = true

	_core = Node3D.new()
	_core.name = "Chip"
	add_child(_core)
	_build_chip(_core, _material, _inlay_material)
	# Chips do not land flat. A couple of degrees of tilt is the difference
	# between "dropped here" and "placed here by a level designer".
	_core.rotation = Vector3(rng.randf_range(-0.06, 0.06),
			rng.randf_range(-PI, PI), rng.randf_range(-0.06, 0.06))

	# The spill: inert wafers beside the live one. Dark, no inlay, no light.
	var spent: StandardMaterial3D = StandardMaterial3D.new()
	spent.albedo_color = Color(0.05, 0.052, 0.058)
	spent.metallic = 0.5
	spent.roughness = 0.55
	for i: int in rng.randi_range(0, 2):
		var dead: Node3D = Node3D.new()
		dead.name = "Spent%d" % i
		var angle: float = rng.randf_range(0.0, TAU)
		var reach: float = rng.randf_range(0.14, 0.4)
		dead.position = Vector3(cos(angle) * reach, -0.001, sin(angle) * reach)
		dead.rotation = Vector3(rng.randf_range(-0.09, 0.09),
				rng.randf_range(-PI, PI), rng.randf_range(-0.09, 0.09))
		dead.scale = Vector3.ONE * rng.randf_range(0.7, 1.0)
		add_child(dead)
		_build_chip(dead, spent, null)

	# A small pool under the chip, not a lamp. It exists so the chip sits in a
	# faint halo on a wet floor and the SSR has something to mirror; at this
	# range and energy it cannot light the room, which is the point.
	_light = OmniLight3D.new()
	_light.name = "ChipGlow"
	_light.position = Vector3(0.0, 0.05, 0.0)
	_light.light_color = COLOUR
	_light.light_energy = GLOW_ENERGY
	_light.omni_range = 1.15
	_light.omni_attenuation = 1.8
	_light.light_specular = 0.9
	_light.light_volumetric_fog_energy = 0.6
	_light.shadow_enabled = false
	add_child(_light)


## One hexagonal wafer: a shallow bevelled disc with an inlay ring and two
## crossing traces cut into its top face. Built from prisms rather than a mesh
## asset so the chip stays a few hundred triangles and needs no import step.
func _build_chip(parent: Node3D, body: StandardMaterial3D,
		inlay: StandardMaterial3D) -> void:
	var plate: MeshInstance3D = MeshInstance3D.new()
	var disc: CylinderMesh = CylinderMesh.new()
	disc.top_radius = CHIP_RADIUS * 0.94
	disc.bottom_radius = CHIP_RADIUS
	disc.height = CHIP_THICKNESS
	disc.radial_segments = 6
	disc.rings = 0
	plate.mesh = disc
	plate.position = Vector3(0.0, CHIP_THICKNESS * 0.5, 0.0)
	plate.material_override = body
	plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(plate)

	if inlay == null:
		return

	# Inlay ring, sunk a hair under the top face so it reads as cut in.
	var ring: MeshInstance3D = MeshInstance3D.new()
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = CHIP_RADIUS * 0.50
	torus.outer_radius = CHIP_RADIUS * 0.58
	torus.rings = 6
	torus.ring_segments = 4
	ring.mesh = torus
	ring.position = Vector3(0.0, CHIP_THICKNESS * 0.92, 0.0)
	ring.material_override = inlay
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(ring)

	# Two traces running out of the ring to the wafer's edge.
	for i: int in 2:
		var trace: MeshInstance3D = MeshInstance3D.new()
		var bar: BoxMesh = BoxMesh.new()
		bar.size = Vector3(CHIP_RADIUS * 1.7, 0.0022, 0.0045)
		trace.mesh = bar
		trace.position = Vector3(0.0, CHIP_THICKNESS * 0.94, 0.0)
		trace.rotation.y = float(i) * PI * 0.5
		trace.material_override = inlay
		trace.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(trace)


func _ready() -> void:
	add_to_group("data_shards")
	# Rebuilt geometry (a mid-layer rejoin) must not resurrect a taken shard.
	if Run.is_shard_taken(shard_index):
		_vanish()
	Run.shard_taken.connect(_on_shard_taken)


func _process(delta: float) -> void:
	if _taken:
		# Collapse into the buffer: shrink and brighten over a few frames.
		_absorb = maxf(_absorb - delta * 3.5, 0.0)
		scale = Vector3.ONE * _absorb
		_light.light_energy = (GLOW_ENERGY + 0.9) * _absorb
		if _absorb <= 0.001:
			visible = false
			set_process(false)
		return

	var t: float = float(Time.get_ticks_msec()) / 1000.0
	# Slow breath on the inlay. This is the whole discoverability budget: a chip
	# you find because something on the floor pulsed, not because it was lit.
	var pulse: float = 0.5 + 0.5 * sin(t * PULSE_RATE + float(shard_index) * 1.7)
	var target: Vector3 = _home

	# Magnet. Cosmetic on every peer — the host's copy is the one that decides
	# the shard has actually been absorbed.
	var claimant: Node3D = _nearest_carrier()
	if claimant != null:
		var pull: Vector3 = claimant.global_position + Vector3.UP * 1.0
		target = target.lerp(pull, 0.55)
		# Only now does it come off the deck and spin. A chip being pulled into a
		# buffer is allowed to look like an event; a chip lying still is not.
		_magnet = minf(_magnet + delta * 4.0, 1.0)
		pulse = 1.0
	else:
		_magnet = maxf(_magnet - delta * 3.0, 0.0)

	_inlay_material.emission_energy_multiplier = INLAY_ENERGY \
			+ INLAY_PULSE * pulse + _magnet * 2.4
	_light.light_energy = GLOW_ENERGY * (0.75 + 0.25 * pulse) + _magnet * 0.7
	_core.position.y = _magnet * MAGNET_LIFT
	_core.rotation.y += delta * MAGNET_SPIN * _magnet
	_core.rotation.z = _magnet * 0.5

	global_position = global_position.lerp(target, 1.0 - exp(-7.0 * delta))

	if claimant == null or not multiplayer.is_server():
		return
	if global_position.distance_to(claimant.global_position + Vector3.UP * 1.0) \
			<= Balance.SHARD_ABSORB_RADIUS:
		Run.take_shard(shard_index, int(String(claimant.name)), value)


## Closest player whose buffer this shard would fall into. Corrupted and
## decompiled crew do not attract salvage.
func _nearest_carrier() -> Node3D:
	var best: Node3D = null
	var best_distance: float = Balance.SHARD_MAGNET_RADIUS
	for id: int in Net.crew.keys():
		var peer: int = int(id)
		if not Run.is_running(peer):
			continue
		var node: Node = Net.get_player(peer)
		if node == null or not is_instance_valid(node):
			continue
		var body: Node3D = node as Node3D
		var distance: float = body.global_position.distance_to(global_position)
		if distance < best_distance:
			best_distance = distance
			best = body
	return best


func _on_shard_taken(index: int, _peer_id: int, _worth: int) -> void:
	if index != shard_index or _taken:
		return
	_taken = true
	_absorb = 1.0


func _vanish() -> void:
	_taken = true
	_absorb = 0.0
	visible = false
	set_process(false)
