extends Node
## Fx (autoload) — the juice layer: every cosmetic burst the moment-to-moment
## loop throws off, in one pooled place.
##
## M7 exists because the game read as cheap. It was not missing systems — it was
## missing the half-second of consequence that every action is supposed to leave
## behind. A shot that produces a thin line and a hitmarker is a spreadsheet
## entry; a shot that spits light out of the emitter, cracks sparks off the wall,
## leaves a scorch that fades, and — when it lands the last hit — takes the thing
## apart into glowing fragments that tumble and go out, is a weapon.
##
## ## Four rules, and all four are load-bearing
##
##   1. **Everything here is COSMETIC AND LOCAL.** Nothing in this file changes
##      the simulation, and nothing in it is replicated. Every effect is spawned
##      from an event that is *already* on every peer (a `_breaker_shot` echo, a
##      creature's streamed `sync_dead`, a validated cast), so four machines draw
##      the same burst from one packet. Adding an RPC for a spark would be paying
##      twice for a fact everyone already has.
##
##   2. **It never touches the RNG stream.** DESIGN.md's determinism law: seeded
##      generation must not be perturbed by presentation. Every "random" angle,
##      tumble and offset here is `UiFx.hash01()` of something the event already
##      carries (a position, a slot index, a frame counter) — so the variation is
##      free, identical on every peer, and invisible to `--dumplayer`. There is
##      not one call to `randf` in this file, on purpose.
##
##   3. **Pooled, never allocated per event.** The budget is four players, six
##      processes and their effects at 60 fps. A `CPUParticles3D.new()` per
##      breaker shot at 3.85 Hz per player is 15 node allocations a second and
##      the GC churn to match. Every emitter below is built once, parked, and
##      moved into place with `restart()`. The pools are small and deliberately
##      steal their own oldest member rather than grow.
##
##   4. **The safety law binds every light in here** (DESIGN.md pillar 7). No
##      effect in this file repeats: each is one rise-and-fall envelope, so none
##      of them can strobe by construction. On top of that the blooms go through
##      `flash_gate()`, a rate governor of exactly the shape
##      `Antivirus.trigger_hurt_flash` and `ViewModel.fire` already use — at most
##      one full-amplitude bloom per `Balance.SUB_FLASH_MIN_INTERVAL`, so <=3 Hz
##      UNCONDITIONALLY with Reduced Flashing off. `--selftest` asserts it.
##
## ## Where the nodes live
##
## Not here. This is an autoload, and an autoload `Node` has no `World3D` — a
## `CPUParticles3D` parented to it renders nothing. The pools live under a
## `FxPool` node this service creates inside the current layer, and the layer
## frees them on descent along with everything else. `_root()` rebuilds it on
## demand, so a descent, a rebuild or an editor run all work without bookkeeping.

# --- pool sizes ---------------------------------------------------------------
#
# Sized against the stated worst case (4 crew + 6 processes in one room) rather
# than generously. When a pool is exhausted the oldest member is stolen, which
# for a 0.4 s spark burst is invisible and for a 1.35 s shatter is the correct
# trade — a seventh simultaneous death is not a frame budget we are spending.
const POOL_SPARKS: int = 10
const POOL_MUZZLE: int = 6
const POOL_DUST: int = 6
const POOL_SHATTER: int = 5
const POOL_GLOW: int = 8
const POOL_RING: int = 4

# --- M12 SENSATION pools ------------------------------------------------------
#
# "we neeed mooooore particle effects." Sized the same way M7's were: against the
# stated worst case (4 crew + 6 processes in one room), stealing the oldest when
# exhausted rather than growing. Every one of these is a one-shot emitter parked
# at `emitting = false`, which costs a transform and nothing else while idle —
# the budget that matters is how many can be ALIVE at once, and that is what
# these numbers are.
#
#   DEBRIS   chunky surface fragments: glass off a screen, plating off a wall.
#   MIST     gel splatter, steam and coolant. Soft, lit, slow.
#   EMBER    the half of an impact that OUTLIVES it — fragments that arc, slow
#            and settle instead of vanishing at the end of a 0.42 s burst.
#   MOTE     data motes: loot, siphon taps, exfil.
#   ARC      electrical arcing off cut cable and damaged machinery.
#   WAKE     movement disturbance: dust pushed by a sprint, a hard landing, a
#            2.6 m process putting its foot down.
const POOL_DEBRIS: int = 6
const POOL_MIST: int = 5
const POOL_EMBER: int = 6
const POOL_MOTE: int = 6
const POOL_ARC: int = 4
const POOL_WAKE: int = 5

## Fragment/spark colours. Impact sparks are the breaker's own cut colour so the
## spray reads as belonging to the tool; everything else is tinted by the caller.
const SPARK_COLOUR: Color = Color(0.72, 0.96, 1.0)

## How long a spark burst and a muzzle spit live. Short: these are the transient
## half of an impact, and the scorch and the ember are the half that lingers.
const SPARK_LIFETIME: float = 0.42
const MUZZLE_LIFETIME: float = 0.16

## Expanding ring geometry for STACK PULSE, in mesh units at scale 1.
const RING_SEGMENTS: int = 40

# --- the pool root, rebuilt per layer ----------------------------------------
var _root_node: Node3D = null

var _sparks: Array[CPUParticles3D] = []
var _muzzles: Array[CPUParticles3D] = []
var _dust: Array[CPUParticles3D] = []
var _shatter: Array[CPUParticles3D] = []
var _glows: Array[OmniLight3D] = []
var _rings: Array[MeshInstance3D] = []
var _next_spark: int = 0
var _next_muzzle: int = 0
var _next_dust: int = 0
var _next_shatter: int = 0
var _next_glow: int = 0
var _next_ring: int = 0

# --- M12 pools ----------------------------------------------------------------
var _debris: Array[CPUParticles3D] = []
var _mist: Array[CPUParticles3D] = []
var _embers: Array[CPUParticles3D] = []
var _motes: Array[CPUParticles3D] = []
var _arcs: Array[CPUParticles3D] = []
var _wakes: Array[CPUParticles3D] = []
var _next_debris: int = 0
var _next_mist: int = 0
var _next_ember: int = 0
var _next_mote: int = 0
var _next_arc: int = 0
var _next_wake: int = 0

## Live decaying glows: [light, energy]. Walked in `_process` so a pooled light
## fades out rather than being switched off by whoever grabbed it next.
var _glow_decay: Array[float] = []
## Live expanding rings: seconds elapsed, per pool slot. -1 means idle.
var _ring_age: Array[float] = []
var _ring_span: Array[float] = []
var _ring_life: Array[float] = []

# --- the scorch pool ---------------------------------------------------------
var _scorches: Array[Decal] = []
var _scorch_age: Array[float] = []
var _next_scorch: int = 0

# --- governors ----------------------------------------------------------------
## SAFETY-CRITICAL. Seconds since the last full-amplitude bloom. Starts large so
## the first event of a run is never swallowed.
var _since_flash: float = 99.0
## Seconds since the last accepted screen-shake impulse. See `shake()`.
var _since_shake: float = 99.0
## SAFETY-CRITICAL. Seconds since the last ARC. Arcing is the one effect in this
## file whose real-world referent genuinely strobes, so it gets its own governor
## on top of the bloom gate — see `arc()`.
var _since_arc: float = 99.0
## Weight of that last impulse, so a bigger one arriving inside the window is
## admitted at the difference rather than dropped outright.
var _last_shake: float = 0.0

## `--log-fx`-free instrumentation: how many effects have been spawned this run,
## by family. Printed by the perf census so a dense-fight measurement can say
## what it was measuring.
var counts: Dictionary = {}


func _ready() -> void:
	# The layer frees the pool root with everything else; drop the cached handle
	# so the next effect rebuilds rather than writing into a freed node.
	Run.descent_started.connect(_forget)
	Run.run_ended.connect(func(_s: Dictionary) -> void: _forget(0))
	# M12: data motes where a chip was lifted. The signal is replicated (it fires
	# on every peer), the position comes from the seeded graph every peer already
	# holds, and nothing new crosses the wire — the same contract as every other
	# effect in this file.
	Run.shard_taken.connect(_on_shard_taken)
	set_process(true)


## A chip was absorbed, on every peer. `index` is the seeded shard index, so its
## world position is a lookup in the graph rather than anything replicated.
func _on_shard_taken(index: int, _peer_id: int, _worth: int) -> void:
	var layer: Node = get_tree().get_first_node_in_group("layer")
	if layer == null or not is_instance_valid(layer):
		return
	var graph: LayerGraph = layer.get("graph") as LayerGraph
	if graph == null or index < 0 or index >= graph.shard_points.size():
		return
	motes(graph.shard_points[index] + Vector3.UP * 0.25, Color(0.62, 0.95, 1.0), 8)


func _forget(_next_layer: int) -> void:
	_root_node = null
	_sparks.clear()
	_muzzles.clear()
	_dust.clear()
	_shatter.clear()
	_glows.clear()
	_rings.clear()
	_scorches.clear()
	_debris.clear()
	_mist.clear()
	_embers.clear()
	_motes.clear()
	_arcs.clear()
	_wakes.clear()
	_glow_decay.clear()
	_ring_age.clear()
	_ring_span.clear()
	_ring_life.clear()
	_scorch_age.clear()
	_next_spark = 0
	_next_muzzle = 0
	_next_dust = 0
	_next_shatter = 0
	_next_glow = 0
	_next_ring = 0
	_next_scorch = 0
	_next_debris = 0
	_next_mist = 0
	_next_ember = 0
	_next_mote = 0
	_next_arc = 0
	_next_wake = 0
	_since_arc = 99.0


# ------------------------------------------------------------------ governors --

## SAFETY-CRITICAL (DESIGN.md pillar 7, limbo-a11y 01-photosensitivity).
##
## Returns 1.0 when a full-amplitude bloom is allowed right now, 0.0 when one
## landed too recently. The same shape as `Antivirus.trigger_hurt_flash` and
## `ViewModel.fire`, and for the same reason: several of M7's effects are large
## light sources, the player controls how often they fire, and a ceiling that
## depends on a cooldown constant somebody might later cut is not a ceiling.
##
## A gated event still READS — its particles, its sound, its ring and its
## emitter glow all play. What is withheld is the wide-area luminance term, which
## is the only part WCAG 2.3.1 is about.
##
## Callers multiply by `A11y.flash_scale` on top, so Reduced Flashing takes even
## an allowed bloom to nothing.
func flash_gate() -> float:
	if _since_flash < Balance.SUB_FLASH_MIN_INTERVAL:
		return 0.0
	_since_flash = 0.0
	return 1.0


## Hand a shake impulse to the local lens, governed.
##
## M7 adds impacts, landings, kills and four abilities to a camera that had two
## shake sources. Without a governor a firefight is a tremor and nobody can aim
## through it. Three bounds, in order:
##
##   * **rate** — at most one impulse per `Balance.SHAKE_MIN_INTERVAL` (2/s).
##     An impulse arriving inside the window is not dropped: it is admitted at
##     the DIFFERENCE over the last one, so a kill during sustained fire still
##     punches through while ten small hits do not stack.
##   * **ceiling** — the accumulated weight is clamped by `Player.add_shake`.
##   * **comfort** — scaled by `A11y.effect_scale("shake")`, so Reduced Flashing
##     removes it entirely.
func shake(amount: float) -> void:
	var scaled: float = amount * A11y.effect_scale("shake")
	if scaled <= 0.0:
		return
	if _since_shake < Balance.SHAKE_MIN_INTERVAL:
		var over: float = scaled - _last_shake
		if over <= 0.0:
			return
		scaled = over
	else:
		_since_shake = 0.0
	_last_shake = maxf(_last_shake, scaled)
	var body: Node = Net.get_player(Net.local_id())
	if body == null or not is_instance_valid(body):
		return
	var player: Player = body as Player
	if player != null:
		player.add_shake(minf(scaled, Balance.SHAKE_CEILING))


func _process(delta: float) -> void:
	_since_flash += delta
	_since_shake += delta
	_since_arc += delta
	if _since_shake >= Balance.SHAKE_MIN_INTERVAL:
		_last_shake = 0.0

	for i: int in _glow_decay.size():
		if _glow_decay[i] <= 0.0:
			continue
		_glow_decay[i] = maxf(_glow_decay[i] - Balance.SUB_FLASH_DECAY * delta, 0.0)
		var light: OmniLight3D = _glows[i]
		if light != null and is_instance_valid(light):
			light.light_energy = _glow_decay[i]

	for i: int in _ring_age.size():
		if _ring_age[i] < 0.0:
			continue
		_ring_age[i] += delta
		var ring: MeshInstance3D = _rings[i]
		if ring == null or not is_instance_valid(ring):
			_ring_age[i] = -1.0
			continue
		var through: float = _ring_age[i] / maxf(_ring_life[i], 0.01)
		if through >= 1.0:
			ring.visible = false
			_ring_age[i] = -1.0
			continue
		# Out fast, then coast — a shockwave decelerates, it does not travel at a
		# constant speed. `1 - (1-t)^2` is the cheapest curve that reads right.
		var eased: float = 1.0 - pow(1.0 - through, 2.0)
		var span: float = _ring_span[i] * eased
		ring.scale = Vector3(span, span, span)
		var material: StandardMaterial3D = ring.material_override as StandardMaterial3D
		if material != null:
			material.albedo_color.a = (1.0 - through) * 0.85

	for i: int in _scorch_age.size():
		if _scorch_age[i] <= 0.0:
			continue
		_scorch_age[i] = maxf(_scorch_age[i] - delta, 0.0)
		var decal: Decal = _scorches[i]
		if decal != null and is_instance_valid(decal):
			var life: float = _scorch_age[i] / Balance.SCORCH_LIFETIME
			decal.albedo_mix = life * 0.85
			decal.emission_energy = life * life * 1.6
			if _scorch_age[i] <= 0.0:
				decal.visible = false


# ------------------------------------------------------------------- the pool --

## The pool's home inside the current layer, built on first use and rebuilt after
## a descent frees it. Returns null before there is a layer at all (the menu, a
## headless selftest), and every public method below no-ops on that.
func _root() -> Node3D:
	if _root_node != null and is_instance_valid(_root_node):
		return _root_node
	var layer: Node = get_tree().get_first_node_in_group("layer")
	if layer == null or not (layer is Node3D):
		return null
	_root_node = Node3D.new()
	_root_node.name = "FxPool"
	layer.add_child(_root_node)
	_build_pools()
	return _root_node


func _build_pools() -> void:
	for i: int in POOL_SPARKS:
		_sparks.append(_make_sparks("Sparks_%d" % i))
	for i: int in POOL_MUZZLE:
		_muzzles.append(_make_muzzle("Muzzle_%d" % i))
	for i: int in POOL_DUST:
		_dust.append(_make_dust("Dust_%d" % i))
	for i: int in POOL_SHATTER:
		_shatter.append(_make_shatter("Shatter_%d" % i))
	for i: int in POOL_GLOW:
		var light: OmniLight3D = OmniLight3D.new()
		light.name = "Glow_%d" % i
		light.light_energy = 0.0
		light.omni_range = 8.0
		light.omni_attenuation = 1.3
		light.light_volumetric_fog_energy = 1.8
		# Never. A pooled one-shot light that casts shadows re-renders the whole
		# shadow atlas on every breaker shot, four times over in a crew.
		light.shadow_enabled = false
		_root_node.add_child(light)
		_glows.append(light)
		_glow_decay.append(0.0)
	for i: int in POOL_RING:
		_rings.append(_make_ring("Ring_%d" % i))
		_ring_age.append(-1.0)
		_ring_span.append(1.0)
		_ring_life.append(0.5)
	for i: int in Balance.SCORCH_POOL:
		_scorches.append(_make_scorch("Scorch_%d" % i))
		_scorch_age.append(0.0)
	for i: int in POOL_DEBRIS:
		_debris.append(_make_debris("Debris_%d" % i))
	for i: int in POOL_MIST:
		_mist.append(_make_mist("Mist_%d" % i))
	for i: int in POOL_EMBER:
		_embers.append(_make_ember("Ember_%d" % i))
	for i: int in POOL_MOTE:
		_motes.append(_make_mote("Mote_%d" % i))
	for i: int in POOL_ARC:
		_arcs.append(_make_arc("Arc_%d" % i))
	for i: int in POOL_WAKE:
		_wakes.append(_make_wake("Wake_%d" % i))


func _make_sparks(node_name: String) -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = node_name
	p.emitting = false
	p.one_shot = true
	p.amount = 16
	p.lifetime = SPARK_LIFETIME
	p.explosiveness = 1.0
	p.spread = 74.0
	p.initial_velocity_min = 2.2
	p.initial_velocity_max = 7.0
	p.gravity = Vector3(0.0, -8.5, 0.0)
	p.damping_min = 1.0
	p.damping_max = 4.0
	p.scale_amount_min = 0.014
	p.scale_amount_max = 0.05
	# Sparks STREAK. A spark that keeps a fixed square profile reads as confetti;
	# stretching it along its own velocity is what makes it read as something
	# moving fast enough to glow.
	p.mesh = _streak_mesh()
	p.material_override = _additive(SPARK_COLOUR, 2.4)
	p.color_ramp = _fade_ramp()
	_root_node.add_child(p)
	return p


func _make_muzzle(node_name: String) -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = node_name
	p.emitting = false
	p.one_shot = true
	p.amount = 10
	p.lifetime = MUZZLE_LIFETIME
	p.explosiveness = 1.0
	# A narrow cone out of the barrel, not a sphere: this is the tool venting
	# down its own axis, and a spherical spit reads as an explosion in your hand.
	p.spread = 17.0
	p.initial_velocity_min = 5.0
	p.initial_velocity_max = 12.0
	p.gravity = Vector3.ZERO
	p.damping_min = 6.0
	p.damping_max = 14.0
	p.scale_amount_min = 0.012
	p.scale_amount_max = 0.038
	p.mesh = _streak_mesh()
	p.material_override = _additive(SPARK_COLOUR, 3.0)
	p.color_ramp = _fade_ramp()
	_root_node.add_child(p)
	return p


func _make_dust(node_name: String) -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = node_name
	p.emitting = false
	p.one_shot = true
	p.amount = Balance.LAND_DUST_HURT
	p.lifetime = 0.9
	p.explosiveness = 0.9
	# Outward and barely up: a landing pushes air along the deck. Dust that goes
	# up reads as a smoke puff, which is a different, softer event.
	p.direction = Vector3(0.0, 0.22, 0.0)
	p.spread = 88.0
	p.initial_velocity_min = 0.7
	p.initial_velocity_max = 2.8
	p.gravity = Vector3(0.0, -0.9, 0.0)
	p.damping_min = 1.4
	p.damping_max = 3.2
	p.scale_amount_min = 0.05
	p.scale_amount_max = 0.19
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2.ONE
	p.mesh = quad
	# LIT, not additive. Pillar 2: the dark is the enemy and your beam is what
	# reveals it. Dust that glowed would be the one thing in a black room you can
	# see without a light, which is the exact failure the Scrubber shatter was
	# fixed for in M3.7.
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.34, 0.34, 0.38, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true
	mat.disable_receive_shadows = true
	mat.roughness = 1.0
	p.material_override = mat
	p.color_ramp = _fade_ramp()
	_root_node.add_child(p)
	return p


func _make_shatter(node_name: String) -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = node_name
	p.emitting = false
	p.one_shot = true
	p.amount = Balance.SHATTER_FRAGMENTS_HEAVY
	p.lifetime = Balance.SHATTER_LIFETIME
	p.explosiveness = 1.0
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 1.8
	p.initial_velocity_max = 6.4
	p.gravity = Vector3(0.0, -8.0, 0.0)
	# The fragments TUMBLE, hard. This is the difference between a mesh coming
	# apart and a puff of sparks: plating turns in the air.
	p.angular_velocity_min = -620.0
	p.angular_velocity_max = 620.0
	p.damping_min = 0.3
	p.damping_max = 1.8
	p.scale_amount_min = 0.04
	p.scale_amount_max = 0.17
	var tri: PrismMesh = PrismMesh.new()
	tri.size = Vector3.ONE
	p.mesh = tri
	# The tint is per-call; the material is duplicated on grab so two creatures
	# dying in the same second do not share one colour.
	p.material_override = _fragment_material(Color(1.0, 0.2, 0.16))
	p.color_ramp = _fade_ramp()
	_root_node.add_child(p)
	return p


func _make_ring(node_name: String) -> MeshInstance3D:
	var ring: MeshInstance3D = MeshInstance3D.new()
	ring.name = node_name
	ring.visible = false
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.mesh = _ring_mesh()
	ring.material_override = _additive(Color(0.72, 0.92, 1.0), 2.2)
	_root_node.add_child(ring)
	return ring


func _make_scorch(node_name: String) -> Decal:
	var decal: Decal = Decal.new()
	decal.name = node_name
	decal.visible = false
	decal.size = Vector3(Balance.SCORCH_SIZE, 0.5, Balance.SCORCH_SIZE)
	decal.texture_albedo = _scorch_texture()
	decal.texture_emission = _scorch_texture()
	decal.modulate = Color(0.06, 0.05, 0.05)
	decal.emission_energy = 0.0
	decal.albedo_mix = 0.0
	# Small: a scorch that fades in over its own distance ring reads as soot
	# rather than as a sticker.
	decal.upper_fade = 0.4
	decal.lower_fade = 0.4
	decal.distance_fade_enabled = true
	decal.distance_fade_begin = 18.0
	decal.distance_fade_length = 8.0
	_root_node.add_child(decal)
	return decal


# --------------------------------------------------------------- shared assets --

## One 64x64 radial falloff, built once and shared by every scorch. Generated
## rather than authored so the effect ships with no new binary asset and cannot
## drift from an import setting.
static var _scorch_tex: ImageTexture = null

static func _scorch_texture() -> ImageTexture:
	if _scorch_tex != null:
		return _scorch_tex
	var size: int = 64
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var centre: float = float(size - 1) * 0.5
	for y: int in size:
		for x: int in size:
			var dx: float = (float(x) - centre) / centre
			var dy: float = (float(y) - centre) / centre
			var r: float = sqrt(dx * dx + dy * dy)
			# Sooty core, ragged edge. The hash term breaks the perfect circle up
			# so a burn mark does not read as a printed dot.
			var edge: float = 0.78 + UiFx.hash01(float(x) * 3.1 + float(y) * 7.7) * 0.2
			var a: float = clampf(1.0 - r / edge, 0.0, 1.0)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, a * a))
	_scorch_tex = ImageTexture.create_from_image(image)
	return _scorch_tex


static func _streak_mesh() -> BoxMesh:
	var box: BoxMesh = BoxMesh.new()
	# Long on Z, thin on X/Y. CPUParticles3D orients a mesh along its velocity
	# when `particle_flag_align_y` is off and the mesh is longer than it is wide,
	# which is what turns a cube into a tracer.
	box.size = Vector3(0.35, 0.35, 2.6)
	return box


static func _ring_mesh() -> TorusMesh:
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = 0.94
	torus.outer_radius = 1.0
	torus.rings = RING_SEGMENTS
	torus.ring_segments = 6
	return torus


static func _additive(colour: Color, energy: float) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(colour.r * energy, colour.g * energy, colour.b * energy,
			colour.a)
	mat.disable_receive_shadows = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


## Shatter fragments are LIT plating with a coal of emission in them, never flat
## emissive. Same argument M3.7 settled for the Scrubber's own shatter: in a
## pitch-black nest, thirty self-lit chips would be the only thing in the room
## that does not need your beam, in a game whose second pillar is that light is
## the only thing that renders anything.
static func _fragment_material(tint: Color) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.10, 0.10, 0.12)
	mat.metallic = 0.5
	mat.roughness = 0.45
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 0.85
	mat.vertex_color_use_as_albedo = false
	mat.disable_receive_shadows = true
	return mat


## Fade in fast, out slow. A particle that appears at full alpha pops.
static func _fade_ramp() -> Gradient:
	var ramp: Gradient = Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.12, 0.62, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0), Color(1.0, 1.0, 1.0, 1.0),
		Color(1.0, 1.0, 1.0, 0.75), Color(1.0, 1.0, 1.0, 0.0)])
	return ramp


func _bump(family: String) -> void:
	counts[family] = int(counts.get(family, 0)) + 1


# --------------------------------------------------------------- public effects --

## The emitter venting. Fired on the same frame as the lash, on every peer that
## can see the shooter — so a crewmate's shot spits light out of THEIR barrel on
## your screen.
##
## Three parts, and the split matters: the **spit** is particles (always plays),
## the **bloom** is a light (rate-governed — this is the wide-area luminance
## term), and the **shimmer** is a brief heat wobble at the barrel. A governed
## shot still spits and still shimmers; only the bloom is withheld.
func muzzle(where: Vector3, direction: Vector3, tint: Color = SPARK_COLOUR) -> void:
	if _root() == null:
		return
	_bump("muzzle")
	var spit: CPUParticles3D = _muzzles[_next_muzzle]
	_next_muzzle = (_next_muzzle + 1) % _muzzles.size()
	spit.global_position = where
	if direction.length_squared() > 0.0001:
		spit.direction = direction.normalized()
	spit.restart()
	_glow(where, tint, Balance.SUB_FLASH_ENERGY * 0.55, 5.0)


## One cut landing on something. `normal` is the surface it hit, so the spray
## comes off the wall rather than out of it.
##
## The scorch is deliberately NOT drawn on a creature — a decal projected onto a
## thing that is about to be deleted is a decal hanging in mid-air a second
## later. `on_world` is false for a creature hit.
##
## M12 KEEPS THIS SIGNATURE and forwards it. Every caller that does not know
## what it hit gets the metal reading, which is the right default for a station
## built out of structural slab — and the ones that DO know call `impact_on`
## directly. Left as a named function rather than folded away because the host's
## echo path genuinely has no surface to report (it re-broadcasts an endpoint,
## not a collider) and "unclassified" is an honest answer there, not a gap.
func impact(where: Vector3, normal: Vector3, tint: Color = SPARK_COLOUR,
		on_world: bool = true) -> void:
	impact_on(where, normal, SURF_METAL, tint, on_world)


## A pooled burn mark that fades. The oldest is recycled once the pool is full,
## which at 24 marks and a 7 s life means a sustained firefight always has room.
func scorch(where: Vector3, normal: Vector3) -> void:
	if _root() == null or _scorches.is_empty():
		return
	_bump("scorch")
	var decal: Decal = _scorches[_next_scorch]
	var slot: int = _next_scorch
	_next_scorch = (_next_scorch + 1) % _scorches.size()
	decal.global_position = where + normal * 0.02
	# A Decal projects down its own -Y. Point that at the surface, and give each
	# mark a hash-derived spin so twenty shots into one wall are twenty marks
	# rather than one stamp printed twenty times.
	var up: Vector3 = normal.normalized() if normal.length_squared() > 0.0001 else Vector3.UP
	var side: Vector3 = Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var basis: Basis = Basis(up.cross(side).normalized(), up,
			side.cross(up).normalized()).orthonormalized()
	var spin: float = UiFx.hash01(where.x * 12.9 + where.y * 78.2 + where.z * 37.7) * TAU
	decal.global_transform = Transform3D(basis, decal.global_position)
	decal.rotate(up, spin)
	var size: float = Balance.SCORCH_SIZE * (0.7 + UiFx.hash01(where.z * 4.1) * 0.6)
	decal.size = Vector3(size, 0.5, size)
	decal.visible = true
	_scorch_age[slot] = Balance.SCORCH_LIFETIME


## THE money effect: a process being deleted comes apart.
##
## Glowing tri fragments blown out of the body, gravity-scattered, tumbling, and
## a dying coal at the point of deletion that FADES rather than flashes — the
## safety law applied to the prettiest thing in the game rather than in spite of
## it. Tinted per creature so a Scrubber, a Sentinel and a Hound do not decompile
## the same colour.
##
## `heavy` picks the fragment budget: a 2.6 m quarantine process throws twice
## what a knee-high cleaner does, and the sound and the shake follow.
##
## Local and cosmetic. It is called from `_play_death`, which every peer already
## runs off the streamed `sync_dead` flag, so nothing new crosses the wire — and
## the variation is hashed off the position, so all four screens shatter the same
## way without a packet.
func decompile(where: Vector3, tint: Color, heavy: bool = false,
		body_height: float = 0.6) -> void:
	if _root() == null:
		return
	_bump("decompile")
	var burst: CPUParticles3D = _shatter[_next_shatter]
	_next_shatter = (_next_shatter + 1) % _shatter.size()
	burst.global_position = where + Vector3.UP * body_height
	burst.amount = Balance.SHATTER_FRAGMENTS_HEAVY if heavy \
			else Balance.SHATTER_FRAGMENTS_LIGHT
	burst.initial_velocity_max = 8.5 if heavy else 6.4
	burst.scale_amount_max = 0.26 if heavy else 0.17
	# Duplicated per grab: two creatures dying inside one shatter lifetime must
	# not share a tint. The duplicate is one small resource, once per death.
	burst.material_override = _fragment_material(tint)
	burst.restart()
	# The coal. Bright, then out over about a third of a second — a fading glow,
	# never a flashing one, and gated like every other bloom in the file.
	_glow(where + Vector3.UP * body_height, tint,
			Balance.SHATTER_GLOW_ENERGY * flash_gate() * A11y.flash_scale,
			11.0 if heavy else 7.0)
	shake(0.42 if heavy else 0.22)
	# M12: the per-bestiary garnish. Resolved by looking at what is standing here
	# rather than by a new argument, so the five creature scripts keep calling
	# exactly what they already call — see `_creature_kind_at`.
	_death_signature(where, _creature_kind_at(where), tint, heavy, body_height)


## Sparks skating off armour the cutter did not get through. Tighter, faster and
## colder than an `impact` — the read is "that did nothing", and it has to be
## legible as a different event from a hit that landed.
func armour_spark(where: Vector3, normal: Vector3) -> void:
	if _root() == null:
		return
	_bump("armour")
	var burst: CPUParticles3D = _sparks[_next_spark]
	_next_spark = (_next_spark + 1) % _sparks.size()
	burst.global_position = where
	burst.direction = normal if normal.length_squared() > 0.0001 else Vector3.UP
	var mat: StandardMaterial3D = burst.material_override as StandardMaterial3D
	if mat != null:
		# Cold white, not the cut's teal: a deflection is the tool failing, and it
		# should not wear the tool's own confirm colour.
		mat.albedo_color = Color(2.0, 2.1, 2.4, 1.0)
	burst.restart()


## A weak point giving way. The Sentinel's core, and anything else that later
## earns one: a hard outward burst plus a bright, short bloom, because this is
## the single most rewarding thing the breaker can do and it should say so.
func core_breach(where: Vector3, tint: Color) -> void:
	if _root() == null:
		return
	_bump("core_breach")
	var burst: CPUParticles3D = _sparks[_next_spark]
	_next_spark = (_next_spark + 1) % _sparks.size()
	burst.global_position = where
	burst.direction = Vector3.UP
	var mat: StandardMaterial3D = burst.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(tint.r * 3.0, tint.g * 3.0, tint.b * 3.0, 1.0)
	burst.restart()
	_glow(where, tint, Balance.SUB_FLASH_ENERGY * 0.7 * flash_gate() * A11y.flash_scale,
			7.0)
	shake(0.3)


## A landing, scaled by how hard it was. `tier` is 0 soft / 1 loud / 2 hurt,
## resolved by the caller off the same thresholds that decide the NOISE — so what
## you see and what the Hound hears are one fact reported in two senses.
func land_dust(where: Vector3, tier: int) -> void:
	if _root() == null:
		return
	_bump("land")
	var puff: CPUParticles3D = _dust[_next_dust]
	_next_dust = (_next_dust + 1) % _dust.size()
	puff.global_position = where
	match tier:
		2: puff.amount = Balance.LAND_DUST_HURT
		1: puff.amount = Balance.LAND_DUST_LOUD
		_: puff.amount = Balance.LAND_DUST_SOFT
	puff.initial_velocity_max = 1.8 + float(tier) * 1.1
	puff.restart()


## An expanding shockwave ring, flat on the deck. STACK PULSE's shape, and the
## one piece of the pulse that tells a player exactly how far it reached — the
## radius is the ability's own, so the ring IS the hitbox.
func pulse_ring(where: Vector3, radius: float, tint: Color, life: float = 0.5) -> void:
	if _root() == null or _rings.is_empty():
		return
	_bump("ring")
	var slot: int = _next_ring
	_next_ring = (_next_ring + 1) % _rings.size()
	var ring: MeshInstance3D = _rings[slot]
	ring.global_position = where + Vector3.UP * 0.12
	ring.scale = Vector3.ONE * 0.05
	ring.visible = true
	var mat: StandardMaterial3D = ring.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(tint.r * 2.2, tint.g * 2.2, tint.b * 2.2, 0.85)
	_ring_age[slot] = 0.0
	_ring_span[slot] = radius
	_ring_life[slot] = life


## A pooled, decaying point light for a caller outside this file — the ability
## kit's cast blooms. Public half of `_glow`, with the same contract: the CALLER
## multiplies by `flash_gate() * A11y.flash_scale` when the light is wide-area
## luminance, and says at its own call site why it did or did not.
func bloom(where: Vector3, tint: Color, energy: float, reach: float) -> void:
	_bump("bloom")
	if _root() == null:
		return
	_glow(where, tint, energy, reach)


## A pooled point light that fades. Every bloom in the file goes through here so
## there is exactly one place a light energy is written and exactly one decay
## curve. Callers that are wide-area luminance multiply `energy` by
## `flash_gate() * A11y.flash_scale` before calling; small local embers do not,
## and the reasoning for each is at the call site.
func _glow(where: Vector3, tint: Color, energy: float, reach: float) -> void:
	if energy <= 0.001 or _glows.is_empty():
		return
	var slot: int = _next_glow
	_next_glow = (_next_glow + 1) % _glows.size()
	var light: OmniLight3D = _glows[slot]
	light.global_position = where
	light.light_color = tint
	light.omni_range = reach
	light.light_energy = energy
	_glow_decay[slot] = energy


# ============================================================ M12 SENSATION ==
#
# "we neeed mooooore particle effects."
#
# M7 gave the loop its half-second of consequence. This deepens it everywhere the
# loop actually lives, and the through-line is one idea: **a hit should tell you
# what you hit.** A cut into wall plating, into a Sentinel's gel torso, into a
# glyph panel and into a creature currently throw the same teal spray, and that
# single fact costs more perceived quality than any amount of extra sparks would
# buy. Surface-aware impacts are first below because they are the multiplier.
#
# ## The four M7 rules still bind, unchanged
#
#   1. Cosmetic and local. Nothing here is replicated; every effect is spawned
#      from an event that is ALREADY on every peer.
#   2. Never touches the RNG stream. Variation is `UiFx.hash01()` of something
#      the event already carries. There is still not one `randf` in this file.
#   3. Pooled, never allocated per event.
#   4. The safety law binds every light. Two governors now: `flash_gate()` for
#      blooms, and `_since_arc` for arcing specifically — see `arc()`.
#
# ## And one new rule, which is really the darkness law restated
#
#   5. **Particles are LIT. They do not light the room.** Pillar 2 says the dark
#      is the enemy and your beam is the only thing that reveals it. Every new
#      emitter below whose referent is matter — debris, gel, glass, steam,
#      coolant, dust, settling embers — uses a LIT material with at most a coal
#      of emission in it, exactly as M3.7 settled for the Scrubber shatter. Only
#      the things that are genuinely made of light (sparks, arcs, data motes)
#      are additive, and each of those is a small, short, local source.
#
# ## How this reaches files this milestone does not own
#
# Several things that should throw particles live in `src/world`, `src/creatures`
# and `src/patches`, which other milestones own. Rather than edit them — or,
# worse, duplicate their state machines — the integration point is
# `Fx.cue(key, where)`, called from `AudioService.play_3d`. Every one of those
# events already announces itself there, on every peer, at the exact moment and
# position it happened. The sound of a thing happening is a perfectly good place
# to hang the sight of it, and it is a place nobody else has to be told about.

# --- surfaces ------------------------------------------------------------------
#
# What the cut landed ON. The caller resolves this (the breaker knows what its
# ray hit); this file only knows what each one should look like.
const SURF_METAL: StringName = &"metal"       ## structural slab, plating, the default.
const SURF_GEL: StringName = &"gel"           ## the Slime slot: Sentinel torso, avatar shells.
const SURF_SCREEN: StringName = &"screen"     ## glyph panels, CRTs, holographic signage.
const SURF_CABLE: StringName = &"cable"       ## conduit and cable runs. Arcs.
const SURF_GRATE: StringName = &"grate"       ## deck grating and dusty floor: throws dust.
const SURF_CREATURE: StringName = &"creature" ## a body. Never scorched.

## Per-surface debris tint. Lit, dark, and only the emission carries colour —
## see rule 5 above.
const TINT_METAL: Color = Color(0.62, 0.68, 0.78)
const TINT_GEL: Color = Color(0.30, 0.92, 0.78)
const TINT_SCREEN: Color = Color(0.55, 0.86, 1.0)
const TINT_CABLE: Color = Color(0.55, 0.80, 1.0)
const TINT_GRATE: Color = Color(0.40, 0.38, 0.36)

## SAFETY-CRITICAL (DESIGN.md pillar 7). Minimum seconds between accepted arcs.
## 0.36 s is 2.78 Hz, under the 3 Hz ceiling with margin, and it is a SEPARATE
## governor from `flash_gate` on purpose: arcing is the one effect in this file
## whose real referent actually strobes, so it must not be able to spend the
## shared bloom budget and then arc again on the next frame with the light
## withheld but the particles still flickering. Both halves are gated together.
const ARC_MIN_INTERVAL: float = 0.36

## How long a settling ember lives. Deliberately long: the whole point is that a
## fight leaves the room changed for a beat afterwards.
const EMBER_LIFETIME: float = 2.6
## Data motes drift for about this long before they are gone.
const MOTE_LIFETIME: float = 1.5


# ------------------------------------------------------------ M12 factories --

## Chunky surface fragments. Bigger, slower and heavier than a spark: this is the
## wall coming off, not the cut glowing.
func _make_debris(node_name: String) -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = node_name
	p.emitting = false
	p.one_shot = true
	p.amount = Balance.M12_DEBRIS_FRAGMENTS
	p.lifetime = 1.1
	p.explosiveness = 1.0
	p.spread = 62.0
	p.initial_velocity_min = 1.4
	p.initial_velocity_max = 4.6
	p.gravity = Vector3(0.0, -9.2, 0.0)
	p.angular_velocity_min = -420.0
	p.angular_velocity_max = 420.0
	p.damping_min = 0.4
	p.damping_max = 2.0
	p.scale_amount_min = 0.02
	p.scale_amount_max = 0.075
	var chip: PrismMesh = PrismMesh.new()
	chip.size = Vector3.ONE
	p.mesh = chip
	p.material_override = _chip_material(TINT_METAL)
	p.color_ramp = _fade_ramp()
	_root_node.add_child(p)
	return p


## Soft volumetric puffs: gel splatter, steam, coolant. LIT and billboarded —
## this is the family that would most obviously break the darkness law if it
## glowed, because a steam jet is large and lasts.
func _make_mist(node_name: String) -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = node_name
	p.emitting = false
	p.one_shot = true
	p.amount = Balance.M12_MIST_PARTICLES
	p.lifetime = 1.4
	p.explosiveness = 0.55
	p.spread = 26.0
	p.initial_velocity_min = 1.6
	p.initial_velocity_max = 5.0
	p.gravity = Vector3(0.0, 0.5, 0.0)
	p.damping_min = 1.8
	p.damping_max = 4.0
	p.scale_amount_min = 0.10
	p.scale_amount_max = 0.42
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2.ONE
	p.mesh = quad
	p.material_override = _soft_material(Color(0.72, 0.76, 0.80, 0.42))
	p.color_ramp = _fade_ramp()
	_root_node.add_child(p)
	return p


## The half of an impact that outlives it. Low velocity, heavy damping, a long
## life and a colour ramp that goes out — fragments that arc, slow and come to
## rest rather than blinking off at the end of the burst.
func _make_ember(node_name: String) -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = node_name
	p.emitting = false
	p.one_shot = true
	p.amount = Balance.M12_EMBER_COUNT
	p.lifetime = EMBER_LIFETIME
	p.explosiveness = 0.9
	p.spread = 78.0
	p.initial_velocity_min = 0.9
	p.initial_velocity_max = 3.4
	p.gravity = Vector3(0.0, -6.2, 0.0)
	# Heavy damping is what makes them SETTLE: they lose their horizontal speed
	# fast, drop, and the ramp takes them out while they are nearly still. A
	# particle system cannot rest on a floor, but it can stop moving and go dark
	# in the same place a resting fragment would be, which is what the eye reads.
	p.damping_min = 3.2
	p.damping_max = 6.5
	p.scale_amount_min = 0.012
	p.scale_amount_max = 0.038
	var bit: BoxMesh = BoxMesh.new()
	bit.size = Vector3.ONE
	p.mesh = bit
	p.material_override = _chip_material(SPARK_COLOUR)
	p.color_ramp = _ember_ramp()
	_root_node.add_child(p)
	return p


## Data motes. The one new family that is honestly made of light: these are bits
## of MOTHER's data coming loose, they are small, they are additive, and they
## drift upward and out. Loot, siphon taps, exfil.
func _make_mote(node_name: String) -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = node_name
	p.emitting = false
	p.one_shot = true
	p.amount = Balance.M12_MOTE_COUNT
	p.lifetime = MOTE_LIFETIME
	p.explosiveness = 0.75
	p.direction = Vector3.UP
	p.spread = 55.0
	p.initial_velocity_min = 0.6
	p.initial_velocity_max = 2.4
	# Data does not fall. A faint upward drift instead: it is being read OUT.
	p.gravity = Vector3(0.0, 0.85, 0.0)
	p.damping_min = 1.0
	p.damping_max = 2.6
	p.scale_amount_min = 0.010
	p.scale_amount_max = 0.030
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2.ONE
	p.mesh = quad
	var mat: StandardMaterial3D = _additive(Color(0.62, 0.95, 1.0), 2.0)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	p.material_override = mat
	p.color_ramp = _fade_ramp()
	_root_node.add_child(p)
	return p


## Electrical arcing. Fast, hot, short streaks along the surface.
func _make_arc(node_name: String) -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = node_name
	p.emitting = false
	p.one_shot = true
	p.amount = Balance.M12_ARC_SPARKS
	p.lifetime = 0.30
	p.explosiveness = 1.0
	p.spread = 55.0
	p.initial_velocity_min = 3.5
	p.initial_velocity_max = 11.0
	p.gravity = Vector3(0.0, -11.0, 0.0)
	p.damping_min = 2.0
	p.damping_max = 7.0
	p.scale_amount_min = 0.010
	p.scale_amount_max = 0.036
	p.mesh = _streak_mesh()
	p.material_override = _additive(Color(0.80, 0.92, 1.0), 2.8)
	p.color_ramp = _fade_ramp()
	_root_node.add_child(p)
	return p


## Movement disturbance: dust pushed by a sprint, a hard landing, a heavy foot.
## The same lit-dust argument as M7's landing puff, but wider and lazier — this
## one is air moving, not deck being struck.
func _make_wake(node_name: String) -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = node_name
	p.emitting = false
	p.one_shot = true
	p.amount = Balance.M12_WAKE_PARTICLES
	p.lifetime = 1.6
	p.explosiveness = 0.45
	p.direction = Vector3(0.0, 0.35, 0.0)
	p.spread = 92.0
	p.initial_velocity_min = 0.3
	p.initial_velocity_max = 1.5
	p.gravity = Vector3(0.0, -0.35, 0.0)
	p.damping_min = 1.2
	p.damping_max = 2.6
	p.scale_amount_min = 0.06
	p.scale_amount_max = 0.26
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2.ONE
	p.mesh = quad
	p.material_override = _soft_material(Color(0.34, 0.34, 0.38, 0.30))
	p.color_ramp = _fade_ramp()
	_root_node.add_child(p)
	return p


# ------------------------------------------------------------ M12 materials --

## Lit plating chips with a coal of emission. Rule 5: matter is lit.
static func _chip_material(tint: Color) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.13, 0.13, 0.15)
	mat.metallic = 0.55
	mat.roughness = 0.40
	mat.emission_enabled = true
	mat.emission = tint
	# Deliberately low. High enough to catch the eye when your beam is off it,
	# low enough that thirty chips are not a light source.
	mat.emission_energy_multiplier = 0.55
	mat.disable_receive_shadows = true
	return mat


## One 32x32 soft radial disc, built once and shared by every gaseous emitter.
##
## THIS IS NOT A GARNISH. A billboarded QuadMesh with no alpha texture is a hard
## SQUARE, and at the scale a steam plume wants (0.1-0.5 m) that reads as a
## handful of white boxes rather than as vapour — the first particle showcase
## made exactly that mistake and it was the most obviously cheap thing in the
## sheet. Generated rather than authored for the same reason the scorch texture
## is: it ships with no new binary asset and cannot drift from an import setting.
static var _soft_tex: ImageTexture = null

static func _soft_texture() -> ImageTexture:
	if _soft_tex != null:
		return _soft_tex
	var size: int = 32
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var centre: float = float(size - 1) * 0.5
	for y: int in size:
		for x: int in size:
			var dx: float = (float(x) - centre) / centre
			var dy: float = (float(y) - centre) / centre
			var r: float = sqrt(dx * dx + dy * dy)
			# Squared falloff: a linear disc still shows a visible rim.
			var a: float = clampf(1.0 - r, 0.0, 1.0)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, a * a))
	_soft_tex = ImageTexture.create_from_image(image)
	return _soft_tex


## Soft lit billboards for anything gaseous or dusty. No emission at all: steam
## in a black room is invisible until your beam finds it, which is correct.
static func _soft_material(tint: Color) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.albedo_texture = _soft_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true
	mat.disable_receive_shadows = true
	mat.roughness = 1.0
	return mat


## Wet, translucent gel. The Slime slot's own language (DESIGN.md): glassy, dark,
## with light circulating UNDER glass rather than bright jelly.
static func _gel_material(tint: Color) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.06, 0.14, 0.12, 0.78)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.metallic = 0.0
	mat.roughness = 0.08
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 0.45
	mat.disable_receive_shadows = true
	return mat


## An ember ramp: up fast, hold, then a long dim to nothing. Distinct from
## `_fade_ramp` because a settling fragment should be visibly cooling for most of
## its life rather than fading out at the end of it.
static func _ember_ramp() -> Gradient:
	var ramp: Gradient = Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.06, 0.35, 0.75, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0), Color(1.0, 1.0, 1.0, 1.0),
		Color(0.95, 0.88, 0.80, 0.85), Color(0.7, 0.55, 0.45, 0.35),
		Color(0.4, 0.3, 0.25, 0.0)])
	return ramp


# ------------------------------------------------------- M12 public effects --

## How much bigger a burst has to be to read at this distance from the ear.
##
## M12 took the breaker from 8 m to 30 m, which quietly broke every impact in
## the game: a 2 cm spark at 30 m is one pixel, so a shot at the edge of your
## beam landed with no visible confirmation at all. Scale is ramped with distance
## and clamped, so a far hit reads and a near one does not turn into confetti.
## Hash-free and deterministic — it is a function of two positions.
func _distance_scale(where: Vector3) -> float:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return 1.0
	var d: float = cam.global_position.distance_to(where)
	return clampf(1.0 + d * Balance.M12_DISTANCE_SCALE_PER_M, 1.0,
			Balance.M12_DISTANCE_SCALE_MAX)


## THE MULTIPLIER: one cut, told apart by what it landed on.
##
## This is the single highest-value effect in the milestone, and it is not
## because it adds particles — it is because it removes a lie. Every hit in the
## game threw the same teal spray whether it went into structural plating, into
## a Sentinel's gel torso, into a glyph panel or into a cable run, and a player
## reading that spray learned nothing about the world. Now a hit on metal throws
## hot chips and a scorch, gel throws slow wet blobs and no scorch at all, a
## screen bursts into glass and dying phosphor, a cable arcs, and grating coughs
## dust. Same weapon, four readings.
##
## `surface` is resolved by the CALLER, because the caller is the thing that
## cast the ray and knows what it hit. `Breaker.show_lash` does it from the
## collider; the audio-driven `cue` path does it from the event.
func impact_on(where: Vector3, normal: Vector3, surface: StringName,
		tint: Color = SPARK_COLOUR, on_world: bool = true) -> void:
	if _root() == null:
		return
	_bump("impact_%s" % String(surface))
	var away: Vector3 = normal if normal.length_squared() > 0.0001 else Vector3.UP
	away = away.normalized()
	var scale: float = _distance_scale(where)

	match surface:
		SURF_GEL:
			# Wet, slow, heavy. No sparks: gel does not spark, and the absence is
			# most of what tells you this hit something ALIVE. No scorch either —
			# see `impact`'s note about decals on things that are about to die.
			_splatter(where, away, TINT_GEL, scale)
			_glow(where + away * 0.1, TINT_GEL, Balance.SUB_FLASH_ENERGY * 0.22, 2.6)
		SURF_SCREEN:
			# Glass, and the panel's own phosphor dying with it. The brightest of
			# the four, and the only one that leaves motes: a glyph panel is
			# MOTHER's data, and breaking it spills some.
			_shards(where, away, TINT_SCREEN, scale)
			_spark_burst(where, away, TINT_SCREEN, scale, 1.15)
			motes(where + away * 0.15, TINT_SCREEN, 6)
			_glow(where + away * 0.1, TINT_SCREEN, Balance.SUB_FLASH_ENERGY * 0.34, 3.6)
			if on_world:
				scorch(where, away)
		SURF_CABLE:
			# Conduit. This one ARCS, and the arc is the governed one — see `arc`.
			_spark_burst(where, away, TINT_CABLE, scale, 1.0)
			arc(where, away, TINT_CABLE)
			if on_world:
				scorch(where, away)
		SURF_GRATE:
			# Deck grating and dusty floor: a cut coughs more dust than it throws
			# chips, and the dust is the read.
			_spark_burst(where, away, tint, scale, 0.7)
			disturb(where, away, 0.55)
			if on_world:
				scorch(where, away)
		SURF_CREATURE:
			_spark_burst(where, away, tint, scale, 0.85)
			_glow(where + away * 0.1, tint, Balance.SUB_FLASH_ENERGY * 0.30, 3.2)
		_:
			# SURF_METAL, and the default for anything unclassified. The M7
			# impact, plus the two things it was missing: chunky plating debris,
			# and embers that outlive the burst.
			_spark_burst(where, away, tint, scale, 1.0)
			_chips(where, away, TINT_METAL, scale)
			_ember(where, away, tint, scale)
			_glow(where + away * 0.1, tint, Balance.SUB_FLASH_ENERGY * 0.30, 3.2)
			if on_world:
				scorch(where, away)


## The M7 spark burst, re-parameterised. Split out of `impact` so every surface
## above can reach for it at its own weight without duplicating the pool dance.
func _spark_burst(where: Vector3, normal: Vector3, tint: Color, scale: float,
		weight: float) -> void:
	var burst: CPUParticles3D = _sparks[_next_spark]
	_next_spark = (_next_spark + 1) % _sparks.size()
	burst.global_position = where
	burst.direction = normal
	burst.amount = maxi(int(16.0 * weight), 4)
	burst.scale_amount_min = 0.014 * scale
	burst.scale_amount_max = 0.05 * scale
	var mat: StandardMaterial3D = burst.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(tint.r * 2.4, tint.g * 2.4, tint.b * 2.4, 1.0)
	burst.restart()


## Plating fragments off a hard surface.
func _chips(where: Vector3, normal: Vector3, tint: Color, scale: float) -> void:
	if _debris.is_empty():
		return
	var burst: CPUParticles3D = _debris[_next_debris]
	_next_debris = (_next_debris + 1) % _debris.size()
	burst.global_position = where
	burst.direction = normal
	burst.amount = Balance.M12_DEBRIS_FRAGMENTS
	burst.scale_amount_min = 0.02 * scale
	burst.scale_amount_max = 0.075 * scale
	burst.material_override = _chip_material(tint)
	burst.restart()


## Glass off a panel. Faster and flatter than plating, and it keeps spinning.
func _shards(where: Vector3, normal: Vector3, tint: Color, scale: float) -> void:
	if _debris.is_empty():
		return
	var burst: CPUParticles3D = _debris[_next_debris]
	_next_debris = (_next_debris + 1) % _debris.size()
	burst.global_position = where
	burst.direction = normal
	burst.amount = Balance.M12_DEBRIS_FRAGMENTS + 6
	burst.initial_velocity_max = 7.4
	burst.angular_velocity_max = 900.0
	burst.scale_amount_min = 0.012 * scale
	burst.scale_amount_max = 0.05 * scale
	burst.material_override = _chip_material(tint)
	burst.restart()


## Gel. Slow, wet, and it falls.
func _splatter(where: Vector3, normal: Vector3, tint: Color, scale: float) -> void:
	if _mist.is_empty():
		return
	var burst: CPUParticles3D = _mist[_next_mist]
	_next_mist = (_next_mist + 1) % _mist.size()
	burst.global_position = where
	burst.direction = normal
	burst.amount = Balance.M12_MIST_PARTICLES
	burst.initial_velocity_min = 0.8
	burst.initial_velocity_max = 3.0
	burst.gravity = Vector3(0.0, -5.5, 0.0)
	burst.scale_amount_min = 0.04 * scale
	burst.scale_amount_max = 0.16 * scale
	burst.material_override = _gel_material(tint)
	burst.restart()


## The lingering half of a hit: fragments that arc out, slow, and go dark where
## they land instead of vanishing when the burst ends.
func _ember(where: Vector3, normal: Vector3, tint: Color, scale: float) -> void:
	if _embers.is_empty():
		return
	var burst: CPUParticles3D = _embers[_next_ember]
	_next_ember = (_next_ember + 1) % _embers.size()
	burst.global_position = where
	burst.direction = normal
	burst.amount = Balance.M12_EMBER_COUNT
	burst.scale_amount_min = 0.012 * scale
	burst.scale_amount_max = 0.038 * scale
	burst.material_override = _chip_material(tint)
	burst.restart()


## Electrical arcing off cut conduit or damaged machinery.
##
## SAFETY-CRITICAL. This is the one effect in the file whose real-world referent
## strobes, so it carries its own governor on top of the shared bloom gate: at
## most one arc per `ARC_MIN_INTERVAL` (2.78 Hz, under the 3 Hz ceiling with
## margin), and the particles and the light are gated TOGETHER — a refused arc
## produces nothing at all rather than a lightless flicker, because a flicker is
## still a flicker. `--selftest` asserts the rate.
func arc(where: Vector3, normal: Vector3, tint: Color = TINT_CABLE) -> void:
	if not arc_gate():
		return
	if _root() == null or _arcs.is_empty():
		return
	_bump("arc")
	var burst: CPUParticles3D = _arcs[_next_arc]
	_next_arc = (_next_arc + 1) % _arcs.size()
	burst.global_position = where
	burst.direction = normal if normal.length_squared() > 0.0001 else Vector3.UP
	burst.restart()
	# Small, short, and still through the shared gate and the A11y scale: an arc
	# is a bright thing next to a wall and the caps are unconditional.
	_glow(where, tint, arc_bloom_energy(), 4.2)


## SAFETY-CRITICAL. The arc rate governor, split out as a public predicate so
## `--selftest` can drive it directly — a cap that can only be checked by
## standing up a layer and watching sparks is a cap nobody checks.
##
## Note the ORDER in `arc()`: this is consulted BEFORE the pool is touched, so a
## refused arc produces no particles AND no light. Gating only the bloom would
## leave a lightless spark flicker at the ungoverned call rate, and a flicker is
## still a flicker as far as WCAG 2.3.1 is concerned.
func arc_gate() -> bool:
	if _since_arc < ARC_MIN_INTERVAL:
		return false
	_since_arc = 0.0
	return true


## The bloom energy an accepted arc would use, as a pure function of the caps.
## Public so the selftest can assert that Reduced Flashing takes it to exactly
## zero rather than merely to something small.
func arc_bloom_energy() -> float:
	return Balance.SUB_FLASH_ENERGY * 0.45 * flash_gate() * A11y.flash_scale


## Steam or coolant venting from something that just broke.
##
## `hot` picks which: steam rises, is white and is slow; coolant is cyan, fast
## and falls. Both are LIT and neither emits — a vent plume in a black room is
## invisible until a beam finds it, and finding one with your beam is a nice
## moment the darkness law gives us for free.
func jet(where: Vector3, direction: Vector3, hot: bool = true) -> void:
	if _root() == null or _mist.is_empty():
		return
	_bump("jet_hot" if hot else "jet_cold")
	var burst: CPUParticles3D = _mist[_next_mist]
	_next_mist = (_next_mist + 1) % _mist.size()
	burst.global_position = where
	burst.direction = direction.normalized() if direction.length_squared() > 0.0001 \
			else Vector3.UP
	burst.amount = Balance.M12_MIST_PARTICLES
	burst.lifetime = 1.8 if hot else 1.0
	burst.initial_velocity_min = 2.4 if hot else 4.5
	burst.initial_velocity_max = 6.0 if hot else 10.0
	burst.gravity = Vector3(0.0, 1.6 if hot else -3.4, 0.0)
	burst.scale_amount_min = 0.12
	burst.scale_amount_max = 0.5 if hot else 0.28
	burst.material_override = _soft_material(
			Color(0.78, 0.80, 0.82, 0.40) if hot else Color(0.42, 0.78, 0.86, 0.46))
	burst.restart()


## Data coming loose: loot collected, a siphon tap surging, an exfil uploading.
## The one new family that is genuinely made of light, and it is small, brief and
## local — the darkness law's exception is data, because data IS the glow in this
## world's fiction.
func motes(where: Vector3, tint: Color = Color(0.62, 0.95, 1.0), count: int = -1) -> void:
	if _root() == null or _motes.is_empty():
		return
	_bump("motes")
	var burst: CPUParticles3D = _motes[_next_mote]
	_next_mote = (_next_mote + 1) % _motes.size()
	burst.global_position = where
	burst.amount = Balance.M12_MOTE_COUNT if count <= 0 else count
	var mat: StandardMaterial3D = burst.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(tint.r * 2.0, tint.g * 2.0, tint.b * 2.0, 1.0)
	burst.restart()


## Air being pushed: a sprint through dust, a hard landing, a heavy foot.
## `strength` 0..1 scales the count and the reach.
func disturb(where: Vector3, direction: Vector3, strength: float = 1.0) -> void:
	if _root() == null or _wakes.is_empty():
		return
	_bump("disturb")
	var burst: CPUParticles3D = _wakes[_next_wake]
	_next_wake = (_next_wake + 1) % _wakes.size()
	burst.global_position = where
	burst.direction = direction.normalized() if direction.length_squared() > 0.0001 \
			else Vector3.UP
	burst.amount = maxi(int(float(Balance.M12_WAKE_PARTICLES) * clampf(strength, 0.1, 1.0)), 3)
	burst.gravity = Vector3(0.0, -0.35, 0.0)
	burst.initial_velocity_max = 1.5 + strength * 1.6
	burst.lifetime = 1.6
	burst.scale_amount_min = 0.06
	burst.scale_amount_max = 0.26
	burst.material_override = _soft_material(Color(0.34, 0.34, 0.38, 0.30))
	burst.restart()


# ------------------------------------------------- M11 hunter presence hooks --
#
# The hunter pass wants weight. These are the callable effects it asks for, built
# here so there is exactly one pooled, governed, darkness-law-abiding place they
# can come from — M11 decides WHEN, this decides what it looks like.

## A heavy process putting its foot down. Debris kicked off the deck, air pushed
## outward, and — the part that actually sells 2.6 metres of mass — dust shaken
## loose from the ceiling ABOVE the footfall, arriving a beat later.
##
## `weight` 0..1: a Hound's trot is 0.3, a Sentinel's stomp is 1.0.
func footfall(where: Vector3, weight: float = 1.0) -> void:
	if _root() == null:
		return
	_bump("footfall")
	weight = clampf(weight, 0.0, 1.0)
	disturb(where, Vector3.UP, 0.35 + weight * 0.5)
	if weight >= 0.6:
		# Only the genuinely heavy ones displace the deck itself.
		_chips(where + Vector3.UP * 0.05, Vector3.UP, TINT_GRATE, 1.0)
		ceiling_dust(where, Balance.M12_CEILING_DUST_RADIUS * weight)


## Dust shaken out of the ceiling over `where`. Falls slowly, which is what makes
## it read as a consequence of the thump rather than part of it.
func ceiling_dust(where: Vector3, radius: float = -1.0) -> void:
	if _root() == null or _wakes.is_empty():
		return
	_bump("ceiling_dust")
	var burst: CPUParticles3D = _wakes[_next_wake]
	_next_wake = (_next_wake + 1) % _wakes.size()
	burst.global_position = where + Vector3.UP * Balance.M12_CEILING_DUST_HEIGHT
	burst.direction = Vector3.DOWN
	burst.amount = Balance.M12_WAKE_PARTICLES
	burst.lifetime = 2.4
	burst.initial_velocity_min = 0.05
	burst.initial_velocity_max = 0.4
	burst.gravity = Vector3(0.0, -Balance.M12_CEILING_DUST_FALL, 0.0)
	burst.scale_amount_min = 0.03
	burst.scale_amount_max = 0.14
	burst.material_override = _soft_material(Color(0.36, 0.35, 0.33, 0.34))
	var span: float = Balance.M12_CEILING_DUST_RADIUS if radius <= 0.0 else radius
	burst.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE_SURFACE
	burst.emission_sphere_radius = maxf(span, 0.2)
	burst.restart()


## A telegraphed attack about to land: the ring IS the reach, and the air inside
## it moves. Same contract as `pulse_ring` — the radius drawn is the radius that
## will hurt, so a player who reads it and steps out of it is correct to.
func telegraph(where: Vector3, radius: float, tint: Color) -> void:
	if _root() == null:
		return
	_bump("telegraph")
	pulse_ring(where, radius, tint, Balance.M12_TELEGRAPH_LIFE)
	disturb(where, Vector3.UP, 0.7)


# ---------------------------------------------------- creature signatures --

## Which bestiary entry is standing at `where`. Resolved by LOOKING rather than
## by being told, and that is deliberate: the five creature scripts live in
## `src/creatures`, which this milestone does not own, and asking them to pass a
## kind would mean editing five files in somebody else's tree. The creature is
## still in the scene when it plays its own death, so the nearest one within a
## body's length IS the one that died.
##
## Returns an empty StringName when nothing is close enough, which every caller
## treats as "use the generic burst".
func _creature_kind_at(where: Vector3) -> StringName:
	var best: StringName = &""
	var best_d: float = 2.0
	for node: Node in get_tree().get_nodes_in_group(Antivirus.GROUP):
		var creature: Node3D = node as Node3D
		if creature == null or not is_instance_valid(creature):
			continue
		var d: float = creature.global_position.distance_to(where)
		if d < best_d:
			best_d = d
			var script: Script = creature.get_script()
			if script != null:
				best = StringName(script.get_global_name())
	return best


## A cut landing on a body, keyed to which body. Called by the breaker instead of
## the generic impact when its ray resolved a creature.
##
## The Sentinel and the Auditor are the two with real gel in them (DESIGN.md's
## Slime slot), so they splatter; the Scrubber and the Hound are dry shells that
## throw chips; the Moth is thin and throws almost nothing but light. All five
## still die to the breaker — the killability law is not negotiable, and none of
## this changes what a hit is WORTH, only what it looks like.
func creature_hit(where: Vector3, normal: Vector3, tint: Color) -> void:
	if _root() == null:
		return
	var kind: StringName = _creature_kind_at(where)
	var scale: float = _distance_scale(where)
	var away: Vector3 = normal if normal.length_squared() > 0.0001 else Vector3.UP
	away = away.normalized()
	_bump("creature_hit")
	match kind:
		&"Sentinel", &"Auditor":
			_splatter(where, away, tint, scale)
			_spark_burst(where, away, tint, scale, 0.6)
		&"Moth":
			_spark_burst(where, away, tint, scale, 0.5)
			motes(where, tint, 5)
		&"Hound", &"Scrubber":
			_spark_burst(where, away, tint, scale, 0.9)
			_chips(where, away, tint, scale * 0.8)
		_:
			_spark_burst(where, away, tint, scale, 0.85)
	_glow(where + away * 0.1, tint, Balance.SUB_FLASH_ENERGY * 0.30, 3.2)


## The per-creature garnish on top of M7's shatter, hung off `decompile` so the
## five creature scripts keep calling exactly what they already call.
func _death_signature(where: Vector3, kind: StringName, tint: Color,
		heavy: bool, body_height: float) -> void:
	var at: Vector3 = where + Vector3.UP * body_height
	match kind:
		&"Sentinel":
			# The big one comes apart WET and vents what was keeping it cool.
			_splatter(at, Vector3.UP, TINT_GEL, 1.2)
			jet(at, Vector3.UP, false)
			ceiling_dust(where, Balance.M12_CEILING_DUST_RADIUS)
			motes(at, tint, 10)
		&"Auditor":
			# It was carrying an index. Deleting it spills the index.
			_splatter(at, Vector3.UP, TINT_GEL, 1.0)
			motes(at, tint, Balance.M12_MOTE_COUNT)
			_ember(at, Vector3.UP, tint, 1.2)
		&"Hound":
			# It flees to recompile; when it finally dies it comes apart dry and
			# hard, and it leaves embers cooling where it fell.
			_chips(at, Vector3.UP, tint, 1.1)
			_ember(at, Vector3.UP, tint, 1.2)
		&"Moth":
			# Thin, and mostly light. It goes out rather than breaking.
			motes(at, tint, Balance.M12_MOTE_COUNT)
		&"Scrubber":
			_chips(at, Vector3.UP, tint, 0.9)
			_ember(at, Vector3.UP, tint, 0.9)
		_:
			_ember(at, Vector3.UP, tint, 1.0)
	if heavy:
		disturb(where, Vector3.UP, 0.9)


# ------------------------------------------------------ MOTHER's particulate --

## She is speaking, and this deep the architecture does not hold together while
## she does. Particulate only: NOTHING here touches a light, a shader or the HUD,
## so DESIGN.md pillar 7 is untouched by construction — the same guarantee the
## voice tier itself makes.
##
## Gated by depth rather than by what she said, because the effect is a statement
## about how far down you are.
func mother_glitch(where: Vector3, layer: int) -> void:
	if _root() == null or _motes.is_empty():
		return
	if layer < Balance.M12_MOTHER_GLITCH_LAYER:
		return
	_bump("mother_glitch")
	var burst: CPUParticles3D = _motes[_next_mote]
	_next_mote = (_next_mote + 1) % _motes.size()
	burst.global_position = where
	burst.amount = Balance.M12_MOTHER_GLITCH_COUNT
	burst.lifetime = 2.2
	burst.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	burst.emission_sphere_radius = Balance.M12_MOTHER_GLITCH_RADIUS
	# Her colour, not the crew's teal, and dim: this is corruption in the air,
	# not a firework.
	var mat: StandardMaterial3D = burst.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(1.6, 0.5, 0.62, 1.0)
	burst.restart()


# ------------------------------------------------------------ the cue table --

## An audio event just fired at a position, on this peer. Throw its particles.
##
## This is the integration point for everything that should throw particles but
## lives in a file this milestone does not own — world props, patches, siphons,
## bulkheads. Every one of them already announces itself through
## `AudioService.play_3d`, on every peer, at the right moment and the right
## place, so hanging the sight of a thing off the sound of it costs no new
## plumbing, no new RPC and no edits in anybody else's tree.
##
## Silent no-op for every key not listed, which is most of them.
func cue(key: StringName, where: Vector3) -> void:
	if _root_node == null and _root() == null:
		return
	match key:
		# --- data coming loose ------------------------------------------------
		&"siphon_surge":
			motes(where + Vector3.UP * 1.0, Color(0.55, 0.95, 1.0), 20)
			jet(where + Vector3.UP * 0.4, Vector3.UP, true)
		&"patch_pickup", &"patch_pickup_kernel":
			motes(where + Vector3.UP * 0.6, Color(0.85, 0.72, 1.0), 12)
		&"patch_cache_open":
			motes(where + Vector3.UP * 0.7, Color(0.85, 0.72, 1.0), 16)
			jet(where, Vector3.UP, true)
		&"backdoor_root_complete", &"exfil_upload":
			motes(where + Vector3.UP * 1.2, Color(0.62, 0.95, 1.0), 20)
		# --- things being cut or broken ---------------------------------------
		&"cabinet_cut":
			impact_on(where, Vector3.UP, SURF_CABLE, TINT_CABLE, true)
		&"weld_complete":
			_spark_burst(where, Vector3.UP, SPARK_COLOUR, _distance_scale(where), 1.2)
			_ember(where, Vector3.UP, SPARK_COLOUR, 1.0)
		&"cabinet_creak":
			disturb(where, Vector3.UP, 0.3)
		&"rewire_clunk":
			arc(where, Vector3.UP, TINT_CABLE)
		&"terminal_corrupt":
			impact_on(where, Vector3.UP, SURF_SCREEN, TINT_SCREEN, false)
		# --- heavy architecture -----------------------------------------------
		&"bulkhead_seal", &"bulkhead_reopen":
			disturb(where, Vector3.UP, 1.0)
			ceiling_dust(where, 2.6)
		&"debris":
			disturb(where, Vector3.UP, 0.45)
		&"dropshaft":
			motes(where, Color(0.55, 0.9, 1.0), 18)
		_:
			pass
