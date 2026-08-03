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
	set_process(true)


func _forget(_next_layer: int) -> void:
	_root_node = null
	_sparks.clear()
	_muzzles.clear()
	_dust.clear()
	_shatter.clear()
	_glows.clear()
	_rings.clear()
	_scorches.clear()
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
func impact(where: Vector3, normal: Vector3, tint: Color = SPARK_COLOUR,
		on_world: bool = true) -> void:
	if _root() == null:
		return
	_bump("impact")
	var burst: CPUParticles3D = _sparks[_next_spark]
	_next_spark = (_next_spark + 1) % _sparks.size()
	burst.global_position = where
	burst.direction = normal if normal.length_squared() > 0.0001 else Vector3.UP
	var mat: StandardMaterial3D = burst.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(tint.r * 2.4, tint.g * 2.4, tint.b * 2.4, 1.0)
	burst.restart()
	# The ember: a small, short glow at the point of the cut. Not gated — it is a
	# 3 m-range point light at a fifth of the bloom ceiling, which is an order of
	# magnitude below anything WCAG measures, and gating it would take the read
	# off the one thing a point-blank shot has.
	_glow(where + normal * 0.1, tint, Balance.SUB_FLASH_ENERGY * 0.30, 3.2)
	if on_world:
		scorch(where, normal)


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
