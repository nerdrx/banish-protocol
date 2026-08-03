class_name ChecksumBarrier
extends Node3D
## CHECKSUM BARRIER — three seconds of asserted integrity, as a hex shell.
##
## The most expensive thing in the kit and the most co-operative: it absorbs for
## **anyone standing inside it**, crew included, which makes it the one
## subroutine whose value goes up with the number of people around you. A crew
## that positions for it gets several times what a lone agent does out of the same
## cast — and the lone agent still gets a full purge absorbed, which is what keeps
## it inside the solo invariant rather than beside it.
##
## ## What it absorbs, honestly
##
## **Antivirus damage.** Every hostile strike in the game arrives through
## `Antivirus._strike`, which is the single door M7 routes them all through, and
## that is where the shell takes its cut. It does NOT absorb:
##
##   * **fall damage** — that is your own commitment to a two-storey drop, and a
##     shield that made verticality free would delete the cost of the shortcut;
##   * **starvation** — the pool running dry is the clock, and the clock is not a
##     thing a program can put a shield in front of.
##
## Both exclusions are deliberate and both are the same rule: the barrier is a
## defence against MOTHER, not against arithmetic.
##
## ## Replication
##
## The shell is spawned by the host's validated cast echo and runs the same fixed
## 3 s life on every peer, exactly like a flare or a fork — so the visual costs
## one packet. What is host-authoritative is the ABSORPTION: only the host
## subtracts from the pool, and only the host decides the shell broke early. Both
## of those come back as one small event packet each.
##
## ## MOTHER notices
##
## DESIGN.md's Director tracks crew stress; a program asserting its own integrity
## inside hers is exactly the sort of thing she would look up at. Every cast pins
## the Director's combat stress (`Haunt.notice_assertion`), which is a real
## consequence rather than a flavour line: the haunting gets heavier around a crew
## that keeps shielding.

const GROUP: String = "barriers"

## Base alpha of the shell, and how hard it pulses. A 3.5 s cycle — a quarter of
## the WCAG ceiling by construction, and scaled by the flash caps on top.
const SHELL_ALPHA: float = 0.30
const PULSE_PERIOD: float = 3.5
const PULSE_DEPTH: float = 0.16

## SAFETY-CRITICAL. The shell brightens when it eats a hit, and a Scrubber pack
## can land hits faster than the WCAG ceiling allows a thing to flash. Same
## governor, same reasoning and same interval as `Antivirus.HURT_FLASH_MIN_INTERVAL`:
## at most one full-amplitude ripple per interval, so <=3 Hz unconditionally with
## Reduced Flashing OFF. A gated hit still ticks the readout and still sounds.
const HIT_FLASH_MIN_INTERVAL: float = 0.36
## How fast a ripple decays, in units per second.
const HIT_DECAY: float = 4.5

## Seconds the shell takes to collapse once it is spent or expired.
const COLLAPSE_TIME: float = 0.35

# --- identity (from the spawn packet; identical on every peer) ----------------
var barrier_id: int = 0
var caster_peer: int = 0
var radius: float = 3.4
var lifetime: float = 3.0
## Total integrity it will absorb. Host-authoritative; clients hold it only to
## draw the integrity band around the shell.
var capacity: float = 45.0
var absorbed: float = 0.0

var _tint: Color = Color(0.55, 0.85, 1.0)
var _age: float = 0.0
var _collapsing: float = -1.0
var _hit_flash: float = 0.0
var _since_hit_flash: float = 10.0
var _shell: MeshInstance3D = null
var _material: ShaderMaterial = null
var _light: OmniLight3D = null


static func create(id: int, peer: int, where: Vector3, tint: Color,
		shell_radius: float, seconds: float, absorb_capacity: float) -> ChecksumBarrier:
	var barrier: ChecksumBarrier = ChecksumBarrier.new()
	barrier.name = "ChecksumBarrier_%d" % id
	barrier.barrier_id = id
	barrier.caster_peer = peer
	barrier.radius = maxf(shell_radius, 0.5)
	barrier.lifetime = maxf(seconds, 0.2)
	barrier.capacity = maxf(absorb_capacity, 1.0)
	barrier._tint = tint
	barrier.position = where
	return barrier


func _ready() -> void:
	add_to_group(GROUP)
	_build_shell()
	set_process(true)


func _build_shell() -> void:
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 32
	sphere.rings = 16

	_shell = MeshInstance3D.new()
	_shell.name = "Shell"
	_shell.mesh = sphere
	_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The shell sits at chest height rather than at the feet: a sphere centred on
	# the deck buries its lower half in the floor and reads as a dome.
	_shell.position = Vector3(0.0, 1.0, 0.0)

	var shader: Shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 tint : source_color = vec4(0.55, 0.85, 1.0, 1.0);
uniform float alpha = 0.30;
uniform float hit = 0.0;
uniform float integrity = 1.0;
uniform float cells = 9.0;

varying vec3 world_normal;

// Standard hexagonal tiling: the nearest of the two offset lattice points, then
// the hex distance to its edge. Six lines and it is a honeycomb; anything more
// elaborate would be detail nobody reads through 30% alpha at 3 m.
float hex_edge(vec2 p) {
	vec2 r = vec2(1.0, 1.7320508);
	vec2 h = r * 0.5;
	vec2 a = mod(p, r) - h;
	vec2 b = mod(p - h, r) - h;
	vec2 gv = dot(a, a) < dot(b, b) ? a : b;
	vec2 q = abs(gv);
	return 0.5 - max(dot(q, normalize(vec2(1.0, 1.7320508))), q.x);
}

void vertex() {
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float edge = hex_edge(UV * cells);
	float line = smoothstep(0.055, 0.0, edge);
	// Fresnel: a shell is mostly rim. Without this it is a frosted ball; with it
	// the geometry inside stays visible and the shape reads as a surface of
	// something rather than a volume of fog.
	float rim = pow(1.0 - abs(dot(world_normal, normalize(-VIEW))), 2.4);
	// Integrity spends the FILL, not the lines: a failing shell thins out but
	// keeps its lattice, which is the read "the structure is holding, the
	// substance is not".
	float body = (line * 0.75 + rim * 0.85) * mix(0.35, 1.0, integrity);
	float a = alpha * (body + hit * (line * 1.2 + rim * 0.8));
	ALBEDO = tint.rgb * a * (1.0 + hit * 1.5);
	ALPHA = a;
}
"""
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.set_shader_parameter("tint", _tint)
	_material.set_shader_parameter("alpha", SHELL_ALPHA)
	_material.set_shader_parameter("hit", 0.0)
	_material.set_shader_parameter("integrity", 1.0)
	_material.set_shader_parameter("cells", 9.0)
	_shell.material_override = _material
	add_child(_shell)

	_light = OmniLight3D.new()
	_light.name = "ShellGlow"
	_light.position = Vector3(0.0, 1.0, 0.0)
	_light.light_color = _tint
	_light.light_energy = 1.1
	_light.omni_range = radius * 1.6
	_light.omni_attenuation = 1.5
	_light.light_volumetric_fog_energy = 2.0
	_light.shadow_enabled = false
	add_child(_light)


func _process(delta: float) -> void:
	_since_hit_flash += delta
	_hit_flash = maxf(_hit_flash - HIT_DECAY * delta, 0.0)

	if _collapsing >= 0.0:
		_collapsing += delta
		var out: float = clampf(1.0 - _collapsing / COLLAPSE_TIME, 0.0, 1.0)
		_material.set_shader_parameter("alpha", SHELL_ALPHA * out * A11y.flash_scale)
		# It contracts as it fails rather than fading in place. A shell that
		# vanishes was switched off; a shell that pulls in was overwhelmed.
		_shell.scale = Vector3.ONE * (0.55 + out * 0.45)
		if _light != null and is_instance_valid(_light):
			_light.light_energy = 1.1 * out
		if _collapsing >= COLLAPSE_TIME:
			queue_free()
		return

	# It rides the caster. DESIGN.md's phrasing is "around the caster", and a
	# shell pinned to the floor would turn the ability into a piece of cover
	# rather than into a thing the crew gathers on.
	var body: Node = Net.get_player(caster_peer)
	if body != null and is_instance_valid(body):
		global_position = (body as Node3D).global_position

	_age += delta
	var t: float = UiFx.clock()
	var breathe: float = 1.0 - PULSE_DEPTH * (0.5 + 0.5 * sin(t * TAU / PULSE_PERIOD))
	var left: float = clampf(1.0 - absorbed / maxf(capacity, 0.001), 0.0, 1.0)
	_material.set_shader_parameter("alpha",
			SHELL_ALPHA * breathe * A11y.flash_scale)
	_material.set_shader_parameter("integrity", left)
	# The ripple is already governed at the trigger; it is scaled here as well so
	# Reduced Flashing removes it entirely rather than merely rate-limiting it.
	_material.set_shader_parameter("hit", _hit_flash * A11y.flash_scale)
	if _light != null and is_instance_valid(_light):
		_light.light_energy = (0.7 + left * 0.4 + _hit_flash * 0.9) * breathe

	if _age >= lifetime:
		collapse()


## Whether `where` is inside this shell. The test every absorbing call makes, and
## deliberately generous by a body radius: a crewmate standing with a shoulder in
## the shell is standing in the shell.
func covers(where: Vector3) -> bool:
	return _collapsing < 0.0 \
			and where.distance_to(global_position + Vector3.UP * 1.0) <= radius + 0.4


## Host-side. Takes what it can out of `amount` and returns what is left to land.
## Returns `amount` untouched once the shell is spent, so the caller never has to
## ask whether there is a barrier — it just asks what got through.
func take(amount: float) -> float:
	if _collapsing >= 0.0 or amount <= 0.0:
		return amount
	var eaten: float = minf(amount, maxf(capacity - absorbed, 0.0))
	if eaten <= 0.0:
		return amount
	absorbed += eaten
	return amount - eaten


## Cosmetic, on every peer: the shell rippled where something hit it. Runs the
## rate governor on each screen against that screen's own clock, so the cap holds
## regardless of packet order — the same rule `Antivirus.trigger_hurt_flash` uses.
func ripple(fraction: float) -> void:
	if _since_hit_flash >= HIT_FLASH_MIN_INTERVAL:
		_since_hit_flash = 0.0
		_hit_flash = 1.0
	absorbed = clampf(fraction, 0.0, 1.0) * capacity
	Audio.play_3d(&"sub_barrier_hit", global_position)


func collapse() -> void:
	if _collapsing >= 0.0:
		return
	_collapsing = 0.0
	remove_from_group(GROUP)
	Audio.play_3d(&"sub_barrier_end", global_position)


func is_live() -> bool:
	return _collapsing < 0.0


## The shell covering `where`, or null. Host-side callers use this to route
## damage; the visual half uses it to know which barrier to ripple.
##
## Nearest-first is not needed: shells are 3 s long and overlapping ones are a
## crew deliberately stacking, in which case the first one found eating the hit is
## the correct answer and the second still has its own capacity for the next.
static func covering(tree: SceneTree, where: Vector3) -> ChecksumBarrier:
	if tree == null:
		return null
	for node: Node in tree.get_nodes_in_group(GROUP):
		var barrier: ChecksumBarrier = node as ChecksumBarrier
		if barrier != null and is_instance_valid(barrier) and barrier.covers(where):
			return barrier
	return null
