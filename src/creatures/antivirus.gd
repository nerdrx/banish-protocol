class_name Antivirus
extends CharacterBody3D
## Base for MOTHER's hunting processes. Owns everything a state machine needs and
## nothing about any particular one.
##
## Authority (DESIGN.md "Multiplayer Architecture"): the host simulates, clients
## observe. Only the host runs the state machine and moves the body; every peer
## receives pose and state through a MultiplayerSynchronizer and smooths toward
## them. A client's copy is a puppet — it never decides anything, which is why a
## client cannot see a Scrubber's state machine to predict a lunge.
##
## Existence, though, is not replicated. Which processes a layer has is a pure
## function of (seed, layer number), exactly like the walls, so every peer
## *builds* the same creatures locally and the wire only ever carries what they
## are doing. That is M2's rule ("nothing about the layout ever goes over the
## wire") applied to the things standing in the layout, and it means a peer can
## never be told about a Scrubber before it has a floor to put it on.
##
## The one thing that needs care is that a synchronizer starts streaming the
## moment a peer connects, several frames before that peer's layer scene exists.
## Visibility is therefore gated on the crew roster, which Net only writes once
## the peer's world is up.
##
## Pathing is the room graph, not a navmesh: M2's floors are flat and its
## doorways are 3.2 m wide, so "steer at the centre of the corridor into the next
## room" is enough to cross a layer, and it costs a dictionary lookup instead of
## a bake on every descent.
##
## Subclasses implement `_think()` (one decision, AI_TICK apart) and `_act()`
## (per physics frame movement), and set `sync_state` for the visuals.

## Emitted on every peer the moment this process starts coming apart. The
## director uses it to remember what a joining peer must not rebuild.
signal died

## Everything hostile is in this group; the director sweeps it on descent, and
## the siphon tap's ping is delivered through it.
const GROUP: String = "antivirus"

## Physics layer 4 — see project.godot [layer_names]. Players collide with it,
## the breaker's hitscan tests against it, and antivirus bodies ignore each other
## (a pack that shoves itself apart cannot come through a doorway).
const ANTIVIRUS_LAYER: int = 8
const WORLD_MASK: int = 1

const GRAVITY: float = 11.0
## How close to a waypoint counts as reaching it.
const WAYPOINT_RADIUS: float = 2.2
## Eye height used for line-of-sight and beam-exposure tests against a player.
const PLAYER_EYE: float = 1.62

# --- identity (set by the director on every peer before tree entry) ----------

var slot_index: int = 0
var layer_number: int = 1
## Seeded anchor this creature was bought at, and the room it belongs to.
var home: Vector3 = Vector3.ZERO
var home_room: int = -1
## Every peer's own copy of the layer layout — pathing needs no replication.
var graph: LayerGraph = null

# --- replicated -------------------------------------------------------------

var sync_position: Vector3 = Vector3.ZERO
var sync_yaw: float = 0.0
var sync_state: int = 0
## Death travels as state rather than as an RPC: an RPC would be sent to peers
## that do not have this node yet, and a streamed flag is gated by the same
## visibility rule as everything else. The host keeps the corpse alive for the
## length of the shatter, which is far longer than the stream needs.
var sync_dead: bool = false
## PT1. 0..1 remaining integrity, host-authoritative and replicated ON CHANGE, so
## the integrity readout on a CLIENT's screen shows the right number for a
## creature damaged by anyone. Health itself stays host-only — a client has no
## business knowing absolute hit points, and a fraction is all a readout draws.
var sync_integrity: float = 1.0

# --- host sim ---------------------------------------------------------------

var health: float = 100.0
## What `health` started at, so a fraction can be reported without every subclass
## remembering to publish its own maximum. Written by `set_health`.
var health_max: float = 100.0
var speed_scale: float = 1.0

var _is_host: bool = false
var _tick_clock: float = 0.0
## Anti-wedge: creatures that stop making progress against a wall pick a
## sidestep rather than grinding a corner forever.
var _stuck_time: float = 0.0
var _dodge: Vector3 = Vector3.ZERO
var _dodge_time: float = 0.0
var _dying: bool = false

var _synchronizer: MultiplayerSynchronizer = null

# --- PT1: the hit flash, and its rate governor -------------------------------

## SAFETY-CRITICAL (limbo-a11y 01-photosensitivity, DESIGN.md pillar 7).
##
## Every process in the game brightens when it is cut — the "yes, that landed"
## half of the impact feedback the first playtest asked for. The breaker fires as
## fast as `Balance.BREAKER_COOLDOWN` allows (~3.85 Hz at 0.26 s), so a held
## trigger on a Sentinel used to drive a 9x emissive spike at 3.85 Hz: OVER the
## WCAG 2.3.1 three-general-flashes-a-second ceiling, on a creature that fills
## the frame, in the DEFAULT build. The safety law is non-negotiable and it is
## not satisfied by a setting.
##
## The governor is the same shape as the muzzle flash's (see
## `ViewModel.MUZZLE_FLASH_MIN_INTERVAL`) and for the same reason: at most one
## full-amplitude flash per interval, >1/3 s, so <=3 Hz UNCONDITIONALLY with
## Reduced Flashing OFF. A shot that lands inside the interval still registers —
## the reticle ticks, the confirm sounds, the integrity readout moves — it simply
## does not re-strike the creature's emission. Independently, `hurt_flash()`
## scales by `A11y.flash_scale`, so Reduced Flashing takes it to nothing.
const HURT_FLASH_MIN_INTERVAL: float = 0.36
## 0..1, decaying. Subclasses read it through `hurt_flash()` and NEVER directly:
## the accessor is where the cap is applied, and a direct read is a hole in it.
var _hurt_flash: float = 0.0
var _since_hurt_flash: float = 10.0

# --- M7: stagger (STACK PULSE) ------------------------------------------------
#
# CONTROL, NOT DAMAGE. The killability law says every monster dies to the
# breaker; its converse is that nothing else may quietly start killing them. A
# stagger takes a process OUT OF ITS STATE MACHINE for a beat and, if it is light
# enough to be moved, shoves it — and does nothing else. `health` is not touched
# anywhere on this path.
#
# Implemented in the BASE rather than per subclass on purpose. `_physics_process`
# simply does not call `_think()` or `_act()` while the timer runs, so a committed
# lunge stops committing, a purge stops swinging and a walk stops walking, for
# every process the game has and every process it ever gets — including ones
# written after this. A subclass that needs to *forget* what it was doing
# overrides `_on_staggered()`; one that does not, does not have to know the
# mechanic exists.

## Seconds of stagger left (host-authoritative) and the shove being ridden out.
var _stagger_time: float = 0.0
var _stagger_push: Vector3 = Vector3.ZERO
## Cosmetic, on every peer: 0..1 decaying, drives the subclass's own reaction and
## the flinch. Replicated as a streamed flag rather than an RPC, for the same
## reason death is — a packet aimed at a peer whose layer is still building is an
## engine error, not a dropped message.
var sync_staggered: bool = false
var _stagger_flash: float = 0.0

# ============================================================================
# M11 — PERCEPTION, SUSPICION AND MEMORY. In the BASE, so every creature the game
# has and every creature it ever gets inherits the same mind.
# ============================================================================
#
# The M10 verdict was that the AI feels far too simple, and it was right for a
# structural reason: every creature was a single-stimulus reflex over a boolean
# sense. `_nearest_player(range, false)` — which is still below, because the
# combat code and the Auditor's strike arc legitimately want "who is beside me" —
# answers a yes/no question through walls. A creature built on yes/no cannot be
# UNCERTAIN, and a creature that cannot be uncertain cannot investigate.
#
# So the base grows a mind, in three parts, each in its own pure file so the
# whole thing is testable headlessly rather than only observable in a capture:
#
#   * `Perception`  graded senses -> a per-target AWARENESS accumulator.
#   * `Suspicion`   the ladder UNAWARE -> CURIOUS -> ALERT -> HUNTING -> LOST,
#                   with hysteresis and a deliberately reluctant descent.
#   * `HuntMemory`  last-known position with confidence decay, recently-searched
#                   spots, hot zones, and bounded escape adaptation.
#
# Three rules bound all of it and are worth stating where they are enforced:
#
#   HOST ONLY. Every line of this thinks on the host, exactly like the rest of the
#   state machine. Clients receive `sync_suspicion` and use it for the telegraph
#   and nothing else — a client that could see the ladder could predict a lunge.
#
#   NO TELEPATHY. Nothing here is shared between creatures. A hunter learns what
#   another hunter knows only by PERCEIVING something that creature did, which in
#   practice means hearing its screech through NoiseBus like any other noise.
#
#   NO OMNISCIENCE. `Perception.feed` refuses evidence of zero strength, so a
#   target cannot enter a creature's mind without a nonzero sensory reading. That
#   is the fairness invariant, asserted on the perception path rather than on the
#   outcome.

## This creature's mind. Host-authoritative; a client's copy stays empty.
var mind: Perception = Perception.new()
var memory: HuntMemory = HuntMemory.new()

## Where on the ladder it is, and how long it has been there.
var suspicion: int = Suspicion.State.UNAWARE
var _dwell: float = 0.0
## Why it last changed its mind. Goes straight into the trace and the overlay,
## because "why" is the question the whole instrument exists to answer.
var _why: String = "spawn"

## Replicated ON CHANGE so every peer can draw the telegraph for the state the
## host is actually in. It is the state and nothing else — no target, no
## awareness, no last-known position — so a client learns exactly what a player
## standing there could see and hear, and not one bit more.
var sync_suspicion: int = 0

## The search. `_search_goal` is where it is walking and WHY it chose there;
## `_search_done` is the termination flag the ladder reads to stop searching.
var _search_goal: Vector3 = Vector3.INF
var _search_dwell: float = 0.0
var _search_done: bool = false
var _search_kind: String = ""

## The Director's ZONE hint: a point it has been pointed at, never a player
## position. Decays, so a hunter that was sent somewhere and found nothing goes
## back to its own doctrine instead of orbiting a stale instruction.
var _hint: Vector3 = Vector3.INF
var _hint_life: float = 0.0

## FALSE DEPARTURE bookkeeping: seconds left of walking away before it turns
## round. Rate-limited inside `HuntMemory`.
var _depart_time: float = 0.0

## Diegetic coordination: seconds until this process may scream again.
var _screech_cooldown: float = 0.0

## Perception LOD + phase. The sense tick is offset by slot index so six
## creatures never sense on the same frame, and creatures far from every crewmate
## skip the expensive half entirely.
var _sense_tick: int = 0

## Per-creature generator for the few AI decisions that are allowed to be
## uncertain (which way to drift, whether to fake a departure). Seeded off the
## slot, NEVER off the shared Rng stream — the determinism law says the seeded
## layer dump must stay byte-identical, and AI is host-side and not part of it.
var _ai_rng: RandomNumberGenerator = RandomNumberGenerator.new()

var _overlay: AIOverlay = null
var _trace_clock: float = 0.0


# ------------------------------------------------------------------ assembly --

## Called by the director's spawn function on every peer. Subclasses build their
## body in `_assemble()`.
func setup(index: int, where: Vector3, room: int, layer: int, layout: LayerGraph) -> void:
	slot_index = index
	layer_number = layer
	home = where
	home_room = room
	graph = layout
	position = where
	sync_position = where
	collision_layer = ANTIVIRUS_LAYER
	collision_mask = WORLD_MASK
	# M6.6: the layer has ramps and stairs in it now. Without a snap, a body
	# walking down a slope leaves the surface every frame, never reports
	# `is_on_floor`, and `_steer` puts it into a permanent fall — which reads as a
	# Scrubber bouncing down a staircase. The angle is Godot's default 45 degrees
	# and every authored slope is under 27, so nothing here can climb a wall.
	floor_snap_length = 0.55
	# M11. Seeded off identity, not off the shared stream: `Rng` is the seeded
	# layer's generator and the determinism law says `--dumplayer` must stay
	# byte-identical, so nothing the AI does may consume from it.
	_ai_rng.seed = hash(str("ai:", index, ":", layer, ":", room))
	_assemble()
	_build_sync()
	# The instrument, attached only when a flag asked for it (see `AIDebug`).
	if AIDebug.active() and AIDebug.overlay:
		_overlay = AIOverlay.attach(self, _eye_height())


## Subclass hook: meshes, lights, collision shape.
func _assemble() -> void:
	pass


## Subclass hook: extra continuously-streamed properties, as `".:name"` paths.
## The Sentinel's scan angle goes through here — a sweep that misses on your
## screen and hits on the host's would be unplayable.
func _extra_sync_properties() -> Array[String]:
	return []


## The replication rig, built in code for the same reason the props are: a
## creature must be placeable without a scene dependency. Pose and death stream
## every packet; state only when it changes.
func _build_sync() -> void:
	var config: SceneReplicationConfig = SceneReplicationConfig.new()
	var streamed: Array[String] = [".:sync_position", ".:sync_yaw", ".:sync_dead"]
	streamed.append_array(_extra_sync_properties())
	for property: String in streamed:
		config.add_property(NodePath(property))
		config.property_set_spawn(NodePath(property), true)
		config.property_set_replication_mode(NodePath(property),
				SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	# M11 adds `sync_suspicion` here rather than to the streamed set: the ladder
	# changes a handful of times a minute, and the telegraph it drives is an
	# EVENT. Streaming it every packet would pay 20 Hz for a fact that is stable
	# for seconds at a time.
	#
	# ## M11 FINDING, appended to the open P0 recorded below — please read together
	#
	# Two consequences of that P0 that are worth naming before anyone tries to
	# review the M11 AI from a client's seat:
	#
	# 1. **It explains the "client holds a creature the host does not" symptom.**
	#    A two-instance run showed the host with 9 processes and the client with
	#    10, the extra being a Moth. That is not a second bug: `sync_dead` rides
	#    this same synchronizer, so a host-side `slink_away()` never reaches the
	#    client and the client keeps simulating a creature the host has deleted.
	#    Every "desync" of this shape is downstream of the one delivery fault.
	#
	# 2. **Every M11 client-side telegraph is currently dead**, and telegraphs are
	#    a ship gate. `sync_suspicion` is what drives a client's copy of the
	#    CURIOUS/ALERT/HUNTING/LOST tell; if pose does not arrive, neither does
	#    this. So on a client today the AI is not merely stale — it is unreadable,
	#    which is the specific failure the telegraph gate exists to prevent. When
	#    the P0 is fixed the telegraphs light up with it and need no change here.
	#
	# Investigated with `tools/crewsync/crewsync.py --scenario latecomer --haunt
	# moth --walk` (24 failures) and `--scenario together` (identical). NOT a
	# join-order bug and NOT caused by the M11 ambush timer, which was the
	# standing suspicion: the `together` control fails exactly as `latecomer`
	# does, and the netcode agent's own note below records it reproducing at two
	# peers with a stationary crew. Left to that agent, which owns the fix and has
	# the next experiment written down; nothing in `src/creatures` should be
	# patched speculatively underneath it.
	for occasional: String in [".:sync_state", ".:sync_integrity", ".:sync_staggered",
			".:sync_suspicion"]:
		config.add_property(NodePath(occasional))
		config.property_set_spawn(NodePath(occasional), true)
		config.property_set_replication_mode(NodePath(occasional),
				SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)

	_synchronizer = MultiplayerSynchronizer.new()
	_synchronizer.name = "Sync"
	_synchronizer.root_path = NodePath("..")
	_synchronizer.replication_interval = Balance.ANTIVIRUS_SYNC_INTERVAL
	_synchronizer.delta_interval = Balance.ANTIVIRUS_SYNC_INTERVAL
	_synchronizer.replication_config = config
	# **VISIBLE BY DEFAULT, narrowed by the filter.** This was `false`, which made
	# the filter dead code — a synchronizer's visibility filters are SUBTRACTIVE,
	# they can take a peer away from the public answer but never grant one — so
	# the gate below described an intent the code did not implement.
	#
	# Changing it does NOT fix the open P0 recorded below, and it was measured
	# not to: creature pose still fails to reach any client either way. It is
	# here because it is the honest spelling of the rule this class wants
	# ("everyone, except peers without a world"), and because when the delivery
	# bug IS fixed, `false` would silently re-break every client.
	#
	# ## OPEN P0: creature pose does not reach clients at all
	#
	# Measured on the four-peer harness (`tools/crewsync/`, `--walk`), comparing
	# the RECEIVED `sync_position` rather than the applied transform, with 2 and
	# with 4 peers, on a green tree:
	#
	#     host      t=8.9   -50.38,0.00,-18.60   (patrolling)
	#     client1   t=8.9   -46.22,0.00,-16.70   (its own locally-generated
	#                                             spawn point; never changes)
	#
	# Every antivirus stands frozen in every client's world for the whole run
	# while the host watches a normal hunt. From a client's seat that is
	# **"enemies only responded to the host"** — a sentence from a real
	# four-player playtest. It is not a four-player bug: it reproduces with a
	# single client. Nothing in this project had ever asserted anything about
	# what a CLIENT sees, so the entire creature layer was verified from the
	# host's screen and this was invisible.
	#
	# Ruled out by measurement, each with an A/B run: the roster filter (forced
	# true for every peer — no change); `public_visibility` (this line — no
	# change); the transport (host->client and client->client RPCs both verified
	# delivering); the roster itself (complete and correct on the host in every
	# scenario and join order).
	#
	# The one structural difference left standing: crew avatars are spawned
	# through a `MultiplayerSpawner` and their synchronizers replicate correctly;
	# creatures are generated locally on every peer from the seed (the
	# determinism law) and are never spawned, so their synchronizer has to
	# resolve through Godot's node-path cache instead of through a spawn. That is
	# the next thing to test, and the likely shape of the fix is to push creature
	# pose from the host the way `Run` already pushes health — `AntivirusDirector`
	# already has `_reconcile.rpc` as precedent.
	#
	# `tools/crewsync/crewsync.py --peers 2 --walk` fails on this today and is
	# the regression gate for it.
	#
	# Spelled out rather than left to the engine's default, because the whole
	# point of the paragraph above is that this value is load-bearing and easy to
	# get silently wrong.
	_synchronizer.public_visibility = true
	_synchronizer.add_visibility_filter(_peer_has_world)


## Stable 32-bit identity for the POSE RELAY, derived from the node name.
##
## The name is already deterministic content — `Scrubber_L7_3`, `Hound_L7_0_d1` —
## built identically on every peer from the seed and the directed-spawn serial, so
## hashing it gives both ends the same id with nothing crossing the wire to agree
## on it. That property is the point: the relay must not need a handshake, because
## a handshake is one more thing that can silently fail to arrive, and this entire
## exercise exists because a channel silently did not.
var _net_id: int = 0
## Separate readiness flag rather than `_net_id == 0` as a sentinel. THIS IS THE
## WHOLE FIX — see below.
var _net_id_ready: bool = false


## Stable identity for the relay.
##
## ## The bug this shape exists to avoid, because it cost most of a debugging day
##
## The first cut was:
##
##     _net_id = (hash(String(name)) & 0x7FFFFFFF) | 1
##
## with `0` used as the "not computed yet" sentinel, and the `| 1` there to make
## sure a creature could never legitimately hash to that sentinel. That `| 1`
## CLEARS THE LOW BIT AS A SOURCE OF ENTROPY: any two names whose hashes differ
## only in bit 0 collapse onto the same id.
##
## Godot's string hash is sequential in the final character, so `Scrubber_L7_0`
## and `Scrubber_L7_1` differ by exactly one — and the roster dump showed it
## plainly, three collided pairs out of six:
##
##     Scrubber_L7_0  id=1264852207     Scrubber_L7_1  id=1264852207
##     Scrubber_L7_2  id=1264852209     Scrubber_L7_3  id=1264852209
##     Scrubber_L7_4  id=1264852211     Scrubber_L7_5  id=1264852211
##
## Every id still RESOLVED — the miss counter read zero all day, which is what
## made this so hard to see — it just resolved to whichever member of the pair the
## index happened to hold, so exactly half the pack was updated and the other half
## stood frozen. Uniquely-named creatures (the Sentinel, the Moth, the hunters)
## were never affected, which is why 5 of 8 worked and the 3 that did not looked
## like an even/odd pattern.
##
## So: keep all 31 bits, and track readiness in its own flag. A sentinel value
## must never be carved out of the value space it is guarding.
func net_id() -> int:
	if not _net_id_ready:
		_net_id = hash(String(name)) & 0x7FFFFFFF
		_net_id_ready = true
	return _net_id


## Client-side. Apply one relayed record.
##
## Writes exactly the `sync_*` fields the synchronizer would have written, so
## every consumer — the gait, the emissive state read, the telegraphs, the census
## — reads one set of values and cannot tell which channel filled them. That is
## what makes this a repair rather than a second parallel truth.
func apply_relay(where: Vector3, yaw: float, state: int, suspicion_now: int,
		integrity: float, dead: bool, staggered_now: bool) -> void:
	if _is_host:
		return
	sync_position = where
	sync_yaw = yaw
	sync_state = state
	sync_suspicion = suspicion_now
	sync_integrity = integrity
	sync_staggered = staggered_now
	# Death is latched, never un-latched: an unreliable packet that arrives out of
	# order must not resurrect a creature that has already begun its shatter.
	if dead and not sync_dead:
		sync_dead = true
	add_child(_synchronizer)


func _peer_has_world(peer_id: int) -> bool:
	# ONE ANSWER, IN ONE PLACE. This used to be `Net.crew.has(peer_id)`, which
	# made the ROSTER the gate on whether a peer is streamed any creature state
	# at all — and a peer that is wrongly outside it gets every antivirus in the
	# building frozen, silently, which is a broken game rather than a cosmetic
	# fault. `Net.peer_has_world` is the same question asked of the roster AND
	# the transport, and it fails open. See the doc comment there for why the
	# two error directions are not comparable.
	return Net.peer_has_world(peer_id)


## Re-evaluates the visibility filter. Called by the director when the roster
## changes, which is the only thing the filter depends on.
func refresh_visibility() -> void:
	if _synchronizer != null and is_instance_valid(_synchronizer):
		_synchronizer.update_visibility()


func _ready() -> void:
	add_to_group(GROUP)
	# The capture harness, armed by whichever creature enters the tree first.
	# NOT in `setup()`: that runs during the director's build, BEFORE the node is
	# in the tree, so `get_tree()` there is null and every creature on the layer
	# logs an engine error for it. `_ready` is the first moment a creature has a
	# tree to hand anybody.
	AIDebug.arm_scenario(get_tree())
	_refresh_authority()
	sync_yaw = rotation.y


# ------------------------------------------------------------------- physics --

## THE ROOT CAUSE OF "EVERY CREATURE IS A STATUE ON EVERY CLIENT".
##
## This used to be latched ONCE, in `_ready()`:
##
##     _is_host = multiplayer.has_multiplayer_peer() and multiplayer.is_server()
##     if not multiplayer.has_multiplayer_peer():
##         _is_host = true          # solo: nobody else to be authority
##
## The solo fallback is correct and the server test is correct. What is wrong is
## the WORD ONCE. A layer's seeded creatures are built during layer construction,
## and on a joining client some of them enter the tree BEFORE
## `multiplayer.multiplayer_peer` has been attached. `has_multiplayer_peer()` is
## false at that instant, so the solo branch fires and those creatures conclude,
## permanently, that they are the authority.
##
## What that produces is not a creature that ignores the network. It is a creature
## that RUNS ITS OWN STATE MACHINE on the client — patrolling, hunting, writing its
## own `sync_position` every physics frame — while the host runs a completely
## different simulation of the same creature. The client's copy then overwrites
## anything the wire delivers, which is why the synchronizer looked like it was
## never delivering and why the relay initially fixed only the creatures that
## happened to be built after the handshake. Both channels were working; the
## receiver was arguing with them.
##
## It is also, precisely, the user's playtest report. Three quarters of a crew were
## each watching their own private, divergent simulation of MOTHER's antivirus.
##
## So authority is now DERIVED, never latched. It costs one boolean per creature
## per physics frame and it cannot go stale across a handshake, a re-host, or a
## layer rebuild.
func _refresh_authority() -> void:
	_is_host = (not multiplayer.has_multiplayer_peer()) or multiplayer.is_server()


func _physics_process(delta: float) -> void:
	_refresh_authority()
	# Clients learn about a death from the stream, not from a message: see
	# `sync_dead`.
	if sync_dead and not _dying:
		_begin_death()
	if _dying:
		return
	# The flinch weight decays on EVERY peer against that peer's own clock, so a
	# client's stagger reaction is never a function of packet arrival order.
	_stagger_flash = maxf(_stagger_flash - delta * 2.2, 0.0)
	if sync_staggered and _stagger_flash <= 0.0:
		_stagger_flash = 1.0
	if not _is_host:
		_smooth_remote(delta)
		return

	# M7: staggered. Out of the state machine entirely for the duration — no
	# decision, no attack, no pathing — and riding out whatever shove came with
	# it. This is what "interrupts a lunge" means mechanically: the lunge simply
	# does not get another frame of `_act`.
	if _stagger_time > 0.0:
		_stagger_time = maxf(_stagger_time - delta, 0.0)
		_ride_stagger(delta)
		if _stagger_time <= 0.0:
			sync_staggered = false
		sync_position = global_position
		sync_yaw = rotation.y
		return

	_tick_clock -= delta
	if _tick_clock <= 0.0:
		_tick_clock = Balance.AI_TICK
		# M11: SENSE, then BELIEVE, then decide. The order is the architecture —
		# `_think()` below reads `suspicion`, `mind.best()` and `search_goal()`
		# rather than asking the world questions of its own, so a creature can
		# never act on something it did not perceive.
		_perceive(Balance.AI_TICK)
		_think()

	_act(delta)

	sync_position = global_position
	sync_yaw = rotation.y


## Subclass hook: one decision. Runs at Balance.AI_TICK, host only.
func _think() -> void:
	pass


## Subclass hook: movement for this frame. Host only.
func _act(_delta: float) -> void:
	pass


# ------------------------------------------------------------------- stagger --

## Host-side. STACK PULSE landed on this process.
##
## `seconds` is how long it is out of its own state machine; `push` is metres of
## knockback for a process light enough to be moved. Heavy ones (see
## `stagger_mass`) are stunned in place instead — a 2.6 m quarantine process does
## not skid across a deck because somebody clapped, and pretending it does would
## make the ability read as a joke rather than as an interrupt.
##
## Deliberately idempotent-ish: a second pulse inside the first EXTENDS the
## stagger rather than stacking two shoves, so two crewmates pulsing together
## buy more time, not more physics.
func stagger(seconds: float, from: Vector3, push: float) -> void:
	if not _is_host or _dying or seconds <= 0.0:
		return
	_stagger_time = maxf(_stagger_time, seconds)
	sync_staggered = true
	_stagger_flash = 1.0
	var away: Vector3 = global_position - from
	away.y = 0.0
	if away.length_squared() > 0.0001 and push > 0.0 and not stagger_mass():
		# Distance over duration: the shove is spent over the whole stagger, so a
		# knocked-back Scrubber SLIDES away and settles rather than being teleported
		# and then standing still looking foolish.
		_stagger_push = away.normalized() * (push / maxf(seconds, 0.01))
	else:
		_stagger_push = Vector3.ZERO
	_on_staggered()


## Whether this process is too heavy to shove. Overridden by the Sentinel and the
## Auditor; everything else is light enough to move.
func stagger_mass() -> bool:
	return false


## Subclass hook: forget what you were doing. Called on the host at the moment a
## stagger lands, so a creature whose state machine has a committed flag (a lunge
## in flight, a purge swing armed) can drop it — the base already stops it being
## SIMULATED, and this is for the bookkeeping that would otherwise resume when the
## stagger ends.
func _on_staggered() -> void:
	pass


## Riding out the shove, host-side. Uses `move_and_slide` like everything else, so
## a knocked-back process stops at a wall instead of going through it.
func _ride_stagger(delta: float) -> void:
	velocity.x = _stagger_push.x
	velocity.z = _stagger_push.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - GRAVITY * delta
	_stagger_push = _stagger_push.lerp(Vector3.ZERO, 1.0 - exp(-6.0 * delta))
	move_and_slide()


## 0..1 flinch weight, ALREADY capped by the flash scale — the same contract
## `hurt_flash()` keeps, and the only legal way to read it. Subclasses use it to
## drive an emissive dip and a pose recoil; nothing may read `_stagger_flash`.
func stagger_flash() -> float:
	return _stagger_flash * A11y.flash_scale


func staggered() -> bool:
	return _stagger_time > 0.0 or sync_staggered


## Clients: ease onto the host's pose. No dead reckoning — a Scrubber changes
## direction constantly, and extrapolating it just makes the puppet twitch.
func _smooth_remote(delta: float) -> void:
	var blend: float = 1.0 - exp(-14.0 * delta)
	global_position = global_position.lerp(sync_position, blend)
	if global_position.distance_to(sync_position) > 8.0:
		global_position = sync_position  # respawn or teleport, not a slide.
	rotation.y = lerp_angle(rotation.y, sync_yaw, blend)


# ------------------------------------------------------------------- motion --

## Planar steering toward `target` with gravity, wall-slide and a stuck escape.
func _steer(target: Vector3, speed: float, delta: float) -> void:
	var to_target: Vector3 = target - global_position
	to_target.y = 0.0
	if _dodge_time > 0.0:
		_dodge_time -= delta
		to_target += _dodge * 6.0

	var wish: Vector3 = Vector3.ZERO
	if to_target.length_squared() > 0.04:
		wish = to_target.normalized()

	var desired: Vector3 = wish * speed
	var planar: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	planar = planar.move_toward(desired, speed * 6.0 * delta)
	velocity.x = planar.x
	velocity.z = planar.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - GRAVITY * delta

	var before: Vector3 = global_position
	move_and_slide()

	_face(wish, delta)
	_check_stuck(before, speed, wish, delta)


## Turn toward travel. Deliberately not instant: a creature that snaps to face
## you reads as a turret rather than something running at you.
func _face(wish: Vector3, delta: float) -> void:
	if wish.length_squared() < 0.01:
		return
	var want: float = atan2(-wish.x, -wish.z)
	rotation.y = lerp_angle(rotation.y, want, 1.0 - exp(-9.0 * delta))


func _check_stuck(before: Vector3, speed: float, wish: Vector3, delta: float) -> void:
	if wish.length_squared() < 0.01 or speed <= 0.01:
		_stuck_time = 0.0
		return
	var moved: float = Vector2(global_position.x - before.x,
			global_position.z - before.z).length()
	if moved > speed * delta * 0.35:
		_stuck_time = 0.0
		return

	_stuck_time += delta
	if _stuck_time < 0.5 or _dodge_time > 0.0:
		return
	# Wedged. Slide along the wall for a beat, picking the side deterministically
	# from the creature's own index so a pack does not all break the same way.
	var side: float = 1.0 if (slot_index % 2) == 0 else -1.0
	_dodge = Vector3(-wish.z, 0.0, wish.x) * side
	_dodge_time = 0.8
	_stuck_time = 0.0


# ------------------------------------------------------------------ pathing --

## Room the creature is standing in (corridors resolve to a room).
func current_room() -> int:
	if graph == null:
		return -1
	return graph.region_of(global_position)


## Waypoint on the way to `target`: straight at it while sharing a room AND a
## deck, at the connecting corridor's centre when the rooms differ, and at the
## foot of a ramp, stair or catwalk when only the elevation does. Recomputed as
## rooms and decks change, so a chase up onto a mezzanine and back down re-routes
## without any path bookkeeping.
##
## M6.6: this is the whole of the antivirus's verticality. There is still no
## navmesh — the floors are flat *within* a deck, the doorways are 3.2 m wide and
## every route between decks is a 4 m wide walkable slope, so "steer at the bottom
## of the stair, then at the top of it" gets a Sentinel onto a gallery exactly the
## way "steer at the corridor mouth" gets it into the next room. The important
## property is that the graph refuses to author a deck a route cannot reach
## (`LayerGraph.unreachable_decks`), so there is no position a player can stand in
## that this function cannot produce a path to.
func _route_to(target: Vector3) -> Vector3:
	if graph == null:
		return target
	var here: int = current_room()
	var there: int = graph.region_of(target)
	if here < 0 or there < 0:
		return target

	if here != there:
		var hop: int = graph.next_room(here, there)
		if hop < 0:
			return target
		# Leaving the room means getting back to grade first: a corridor mouth is at
		# floor level, and a creature on a gallery has to walk down before it can
		# walk out.
		var descend: Vector3 = _deck_step(here, -1)
		if descend != Vector3.INF:
			return descend
		var door: Vector3 = graph.link_point(here, hop)
		# Once through the corridor mouth, aim at the room beyond it rather than
		# standing in the doorway re-deciding.
		if Vector2(door.x - global_position.x, door.z - global_position.z).length() \
				< WAYPOINT_RADIUS:
			return graph.centre_of(hop)
		return door

	var want: int = graph.deck_at(target)
	var step: Vector3 = _deck_step(here, want)
	return step if step != Vector3.INF else target


## The next deck-graph waypoint inside `room`, or INF when this creature is
## already on the deck it wants. Once it is standing at the mouth of the route it
## aims at the far end instead, which is what makes it commit to a flight of
## stairs rather than loitering at the bottom re-deciding every tick.
func _deck_step(room: int, want: int) -> Vector3:
	var standing: int = graph.deck_at(global_position)
	if standing == want:
		return Vector3.INF
	return graph.deck_waypoint(room, standing, want, global_position)


# -------------------------------------------------------------------- senses --

## Living, running crew, as bodies. Corrupted crewmates are on the floor and
## corpses do not get hunted — DESIGN.md's restore window would be worthless if a
## pack camped the body — and anyone stood in a backdoor sanctuary is off the
## board entirely: antivirus does not go in there.
##
## **M7: a live FORK DECOY is in this list too**, and that is the whole of how the
## ability works. Everything that hunts by position — the Scrubbers, the Hound,
## the Moth, the Sentinel, the Auditor — asks this one question, so a fork becomes
## prey to all of them by being appended here rather than by five state machines
## learning about a new class. The decoy is filtered by the same sanctuary rule
## as a crew member (a fork walked into a backdoor room is off the board too), and
## by its own lure radius: past that, a process is not fooled.
##
## The damage side is safe by construction because every strike goes through
## `_land_hit`, which asks what it is aiming at before it asks anything else.
## ## M11 / PT-MULTI: "enemys only responded to the host"
##
## A live four-player session reported that the antivirus behaved as though the
## crew were one person — the host. Whatever the root cause turns out to be (a
## netcode agent owns `Net`, `RunState` and spawning and is diagnosing it in
## parallel), this function is the single door every hunting decision in the game
## walks through, and it was asking the wrong question.
##
## It used to enumerate `Net.crew.keys()` and resolve each id through
## `Net.get_player`. That makes the ROSTER the source of truth for who exists —
## so a roster that is late, partial or wrong on the host does not degrade the
## AI, it DELETES three quarters of the crew from the game's perception. There is
## no error, no warning and nothing in a log: the creatures simply hunt one
## person, which is exactly the symptom that was reported.
##
## It now asks the world instead. Every avatar is spawned as a sibling of every
## other, so ONE known avatar finds all of them, and the roster is used only as a
## hint for finding that anchor. Two properties follow, and both are the point:
##
##   * **Ownership-blind.** There is no `is_multiplayer_authority()` test on this
##     path and there must never be one. On the host that predicate is true for
##     the host's own avatar and false for every client's, so a single ownership
##     check anywhere in target acquisition produces precisely this bug. The
##     avatars a creature can hunt are the ones standing in the room, not the ones
##     this peer happens to own.
##
##   * **Roster-independent.** If `Net.crew` disagrees with the tree, the tree
##     wins. A crewmate who is physically present is huntable.
##
## `Run.is_running` still filters — a corrupted crewmate is on the floor and a
## deleted one is gone — and that predicate is permissive by construction (it
## answers true for a peer it has never heard of), so it cannot silently drop
## somebody either.
##
## `--selftest` asserts the ownership-blindness directly ("a creature can acquire
## a non-host crew member"), which is the check that would have caught this.
func _running_players() -> Array[Node3D]:
	var result: Array[Node3D] = []
	var seen: Dictionary = {}
	for body: Player in _crew_avatars():
		if not Run.is_running(body.peer_id):
			continue
		if _in_sanctuary(body.global_position):
			continue
		if seen.has(body.peer_id):
			continue
		seen[body.peer_id] = true
		result.append(body)
	for decoy: ForkDecoy in ForkDecoy.live_decoys(get_tree()):
		if _in_sanctuary(decoy.global_position):
			continue
		if decoy.global_position.distance_to(global_position) > decoy.lure_radius:
			continue
		result.append(decoy)
	return result


## EVERY crew avatar standing in this world, whoever owns it.
##
## The tree is the authority and the roster is only a way of finding it. Avatars
## are spawned as siblings under one container, so any single one of them locates
## the rest — and `Player` is a class test, not an ownership test, which is the
## whole safety property this function exists to have.
##
## Static and side-effect free so `--selftest` can call it against a synthetic
## container and assert the multi-crew contract without standing up a network.
static func crew_avatars_under(anchor: Node) -> Array[Player]:
	var out: Array[Player] = []
	if anchor == null or not is_instance_valid(anchor):
		return out
	for child: Node in anchor.get_children():
		var body: Player = child as Player
		if body != null and is_instance_valid(body):
			out.append(body)
	return out


func _crew_avatars() -> Array[Player]:
	# The anchor: any avatar this peer can already resolve. The local player is
	# the cheapest and is always present on a peer that is playing; the roster is
	# the fallback for a spectating or dedicated host.
	var anchor: Node = Net.get_player(Net.local_id())
	if anchor == null or not is_instance_valid(anchor):
		for id: int in Net.crew.keys():
			var candidate: Node = Net.get_player(int(id))
			if candidate != null and is_instance_valid(candidate):
				anchor = candidate
				break
	if anchor == null or not is_instance_valid(anchor):
		return [] as Array[Player]
	return crew_avatars_under(anchor.get_parent())


## The backdoor node room is safe ground by design (DESIGN.md: the sanctuary is
## the reward for reaching a node). Nothing hostile targets anything inside it.
func _in_sanctuary(where: Vector3) -> bool:
	if graph == null or not graph.is_backdoor:
		return false
	return graph.region_of(where) == graph.shaft_index


## Nearest running player within `range_limit` with line of sight, or null.
func _nearest_player(range_limit: float, require_los: bool = true) -> Node3D:
	var best: Node3D = null
	var best_distance: float = range_limit
	for body: Node3D in _running_players():
		var distance: float = body.global_position.distance_to(global_position)
		if distance >= best_distance:
			continue
		if require_los and not _has_los(body):
			continue
		best_distance = distance
		best = body
	return best


## Where this creature looks from. A Scrubber's sensor is at ankle height and a
## Sentinel's head is above the racking, and they should not agree about what
## counts as cover — the difference is most of why you can crawl past one and
## not the other.
func _eye_height() -> float:
	return 0.8


func _has_los(body: Node3D) -> bool:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return true
	var from: Vector3 = global_position + Vector3.UP * _eye_height()
	var to: Vector3 = body.global_position + Vector3.UP * 1.2
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = WORLD_MASK
	return space.intersect_ray(query).is_empty()


## Is this creature standing in light a player made? A beam cone with line of
## sight, or the radius of a burning flare. THE Scrubber mechanic, and the reason
## the breaker is not the only answer to one.
func _in_player_light() -> bool:
	for node: Node in get_tree().get_nodes_in_group("flares"):
		var flare: Flare = node as Flare
		if flare == null or not is_instance_valid(flare) or not flare.is_burning():
			continue
		if flare.global_position.distance_to(global_position) <= Balance.FLARE_REPEL_RADIUS:
			return true

	# The cone is per player, because Optics buys it. A crewmate three tiers into
	# the track is holding a visibly wider, longer beam, and this is where that
	# purchase turns into "the pack will not come near them".
	#
	# M11 / PT-MULTI: enumerated from the TREE, not from `Net.crew` — see
	# `_running_players` for the argument. This one had teeth of its own: driven
	# off the roster, a CLIENT's beam could silently fail to repel a Scrubber on
	# the host, so three quarters of the crew would have been holding a torch that
	# did nothing. Beam repulsion is the pack's whole counter; it must work for
	# every crewmate regardless of who owns their avatar.
	for player: Player in _crew_avatars():
		var peer: int = player.peer_id
		if not Run.is_running(peer):
			continue
		if not player.sync_beam:
			continue
		var loadout: Dictionary = Modules.loadout(peer)
		var limit: float = cos(deg_to_rad(float(loadout["beam_cone_deg"])))

		var eye: Vector3 = player.global_position + Vector3.UP * PLAYER_EYE
		var to_self: Vector3 = (global_position + Vector3.UP * 0.5) - eye
		var distance: float = to_self.length()
		if distance > float(loadout["beam_expose"]) or distance < 0.01:
			continue
		if (to_self / distance).dot(_beam_direction(player)) < limit:
			continue
		if not _has_los(player):
			continue
		return true
	return false


## Where a player's beam points, from the replicated pose rather than the node's
## smoothed transform: on the host a remote crewmate's head is still easing
## toward its last packet, and exposure should follow what they are actually
## looking at.
static func _beam_direction(player: Player) -> Vector3:
	var yaw: float = player.sync_yaw
	var pitch: float = player.sync_pitch
	return Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))


# ================================================================= M11 mind ==
#
# Everything below runs on the host only, once per AI tick, immediately before
# `_think()`. It is the same five stages for every creature in the game, and the
# per-class differences are entirely in the four small hooks at the top — which
# is the point: a hunter is not a boss with rules of its own, it is a creature
# with a different sensorium and a different doctrine over one shared mind.

# --- doctrine hooks. Override these; do not override `_perceive`. ------------

## How far this process can see, in metres, and how wide its cone is. Zero range
## means it does not see at all (the Auditor barely does; a future creature might
## not at all), which is a legitimate and characterful answer.
func sight_range() -> float:
	return 0.0


func sight_cone_deg() -> float:
	return 60.0


## How far this process hears, in ROOMS of the layer graph. The unit is rooms and
## not metres because sound in this building travels down corridors, and a slab is
## a slab — the same reasoning `alert()` has used since M2.
func hearing_rooms() -> int:
	return 1


## The audio tell for entering `state`. TELEGRAPHS ARE A SHIP GATE: if a player
## cannot tell CURIOUS from HUNTING the system has failed however good the code
## is, so every state change makes a noise and the caption goes out beside it from
## the same call site. Returning `&""` means silent, which is only correct for
## dropping back to UNAWARE.
func _telegraph_sound(_state: int) -> StringName:
	return &""


## Whether this process reacts to the ladder at all. The Auditor overrides it to
## false for the CLIMB — it has the schedule, it cannot be surprised — while still
## perceiving, which is what lets it notice you are standing in the room it was
## going to inspect anyway.
func reacts_to_suspicion() -> bool:
	return true


## Subclass hook: the ladder moved. Doctrine goes here.
func _on_suspicion(_from: int, _to: int) -> void:
	pass


## Subclass hook: a sense this class has and the base does not. The Moth's
## light-seeking is the only one today, and it is exactly why the hook exists —
## its real sensorium reaches twice as far as its cone and is not a cone at all,
## so bolting it onto `_sense_sight` would have made the base lie about what a
## cone is. Anything fed here must go through `mind.feed`, which is where the
## fairness invariant lives, and must record its keys in `fed`.
func _sense_extra(_delta: float, _fed: Dictionary) -> void:
	pass


# --- the sense tick ----------------------------------------------------------

## SENSE -> BELIEVE -> SEARCH. Host only, once per AI tick.
func _perceive(delta: float) -> void:
	memory.tick(delta)
	_search_dwell = maxf(_search_dwell - delta, 0.0)
	_screech_cooldown = maxf(_screech_cooldown - delta, 0.0)
	_depart_time = maxf(_depart_time - delta, 0.0)
	if _hint_life > 0.0:
		_hint_life -= delta
		if _hint_life <= 0.0:
			_hint = Vector3.INF
	_sense_tick += 1

	var fed: Dictionary = {}
	_sense_sight(delta, fed)
	_sense_extra(delta, fed)

	# Everything not fed this tick bleeds awareness at the rate the current rung
	# of the ladder chooses — LOST forgets slowest, which is what keeps a creature
	# looking for you long after it should have given up.
	mind.settle(fed, delta, suspicion)

	# PEAK, not attended: with four crew a creature must climb to HUNTING on the
	# strongest thing it senses even while its attention is committed elsewhere,
	# or a crewmate walking into its face while it is fixed on their friend would
	# be invisible to the ladder.
	var aware: float = mind.peak_awareness()
	var live: bool = not fed.is_empty()
	var moved: Dictionary = Suspicion.step(suspicion, aware, live, _dwell, delta,
			_search_done)
	_dwell = float(moved["dwell"])
	var next: int = int(moved["state"])
	if next != suspicion:
		_enter_suspicion(next, String(moved["reason"]))

	if suspicion == Suspicion.State.ALERT or suspicion == Suspicion.State.LOST:
		_advance_search(delta)
	else:
		_search_goal = Vector3.INF
		_search_done = false

	_trace(delta)


## SIGHT. Range and cone are tested before the raycast and the illumination
## sweep, because those are the only expensive parts and a creature facing the
## other way has already answered the question.
##
## PERFORMANCE (the 60 fps gate with 6+ creatures): a creature with no crewmate
## inside `AI_LOD_FULL_RANGE` skips this entire function on 3 of every 4 ticks. It
## cannot see you from there anyway — the sight ranges in `Balance` are all well
## under the LOD radius — so the LOD is free in behaviour and 4x in cost.
func _sense_sight(delta: float, fed: Dictionary) -> void:
	var reach: float = sight_range()
	if reach <= 0.0:
		return
	if not _sense_full() and (_sense_tick + slot_index) % Balance.AI_LOD_FAR_EVERY != 0:
		return

	var cone_cos: float = cos(deg_to_rad(sight_cone_deg()))
	var eye: Vector3 = global_position + Vector3.UP * _eye_height()
	var facing: Vector3 = Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	var strongest: float = 0.0

	for body: Node3D in _running_players():
		var to_body: Vector3 = (body.global_position + Vector3.UP * 1.2) - eye
		var distance: float = to_body.length()
		if distance < 0.01:
			continue
		var near: bool = distance <= Balance.AI_PROXIMITY
		if distance > reach and not near:
			continue
		var direction: Vector3 = to_body / distance
		var alignment: float = direction.dot(facing)
		if alignment < cone_cos and not near:
			continue
		# Only now: the raycast and the light sweep.
		var occluded: bool = not _has_los(body)
		var lit: float = _target_illumination(body)
		var strength: float = Perception.sight_strength(distance, reach, alignment,
				cone_cos, occluded, lit)
		# You cannot sneak past something you are close enough to touch, whatever
		# it happens to be facing. The mercy layer's other direction: without this
		# a player could walk through a Sentinel's back arc, which reads as a bug.
		if near and not occluded:
			strength = maxf(strength, Balance.AI_PROXIMITY_STRENGTH
					* (1.0 - distance / Balance.AI_PROXIMITY))
		if strength <= 0.0:
			continue
		strongest = maxf(strongest, strength)
		var key: String = String(body.name)
		if mind.feed(key, strength, body.global_position, "sight", delta, body):
			fed[key] = true
			memory.mark_seen(body.global_position,
					graph.region_of(body.global_position) if graph != null else -1)
	mind.last_sight = strongest


## How lit a target is, 0..1 — the room around it, plus (for a crewmate) the
## enormous fact of their own beam. This is where DESIGN.md pillar 2 becomes the
## stealth system: going dark is the crouch button.
func _target_illumination(body: Node3D) -> float:
	var ambient: float = Perception.illumination_at(get_tree(), body.global_position)
	var player: Player = body as Player
	if player == null:
		# A fork decoy is a running program, and a running program in this game
		# glows. Faint: a decoy is a rumour of a crewmate, not a torch.
		return maxf(ambient, Balance.AI_DECOY_GLOW)
	return Perception.player_illumination(get_tree(), player, ambient)


## Whether any crewmate is close enough that the expensive senses are worth
## running at full rate.
func _sense_full() -> bool:
	for body: Node3D in _running_players():
		if body.global_position.distance_to(global_position) <= Balance.AI_LOD_FULL_RANGE:
			return true
	return false


# --- hearing -----------------------------------------------------------------

## Something was loud. THE M11 replacement for `alert()`, called by the
## AntivirusDirector for every creature on the layer with the full noise record.
##
## Hearing is graded and it is a sense of WHERE, never of WHAT: it feeds an
## awareness track keyed on the noise rather than on a crewmate, so a creature
## that hears a kicked can goes to look at where the can was and finds out what
## made it by ARRIVING. That gap is the whole space a player has to lie to a
## hunter in, and it did not exist before this milestone.
##
## Note what is deliberately absent: nothing here targets a player. A noise
## produces a position and a belief; the creature still has to close the last gap
## with its own eyes.
##
## ## SIGHT IS INTEGRATED PER TICK. A NOISE IS AN IMPULSE. (Read this before
## ## touching the `feed` call below.)
##
## These are different UNITS and conflating them is a silent, review-proof bug.
##
## Sight is a *continuous* stimulus: the target is there for as long as it is
## there, so `_sense_sight` feeds it once per AI tick with `delta = AI_TICK` and
## awareness integrates it correctly over time — a second of clean sight is
## fifteen ticks of gain.
##
## A noise is *not* continuous. It happens once and it is over. There is no second
## tick of it to integrate, so charging it one tick of gain does not model a
## quieter stimulus — it undercounts the whole event by whatever the tick rate
## happens to be, which is an arbitrary number that has nothing to do with how
## loud anything was.
##
## The first cut did exactly that, and the arithmetic is worth keeping: a Scrubber
## screech heard two rooms away has strength 0.46, so at one tick it moved
## awareness by 0.46 * 0.62 * (1/15) = **0.019**, against a CURIOUS threshold of
## **0.16**. Nine screams to raise an eyebrow. The entire diegetic-coordination
## layer — the thing that makes "kill the screamer before it screams" a real
## tactic — was mechanically inert while reading as perfectly correct in every
## code review and passing every green test, because no test asserted a creature
## ACTUALLY CONVERGED on a sound.
##
## So an impulse is charged as the number of seconds of equivalent continuous
## evidence it is worth (`Balance.AI_NOISE_IMPULSE`), and that constant is in
## SECONDS on purpose: it is tick-rate independent, so changing `AI_TICK` for
## performance can never again quietly change how well anything hears.
##
## It surfaced only because the screech demo was staged explicitly and then
## failed LOUDER instead of failing quietly. Build the demo you can watch.
func hear(event: Dictionary) -> void:
	if not _is_host or _dying or graph == null:
		return
	# A process never investigates its own scream.
	if event.get("emitter", null) == self:
		return
	var where: Vector3 = event["where"]
	var room: int = graph.region_of(where)
	var rooms_away: int = graph.room_distance(current_room(), room)
	var strength: float = Perception.hearing_strength(float(event["intensity"]),
			rooms_away, hearing_rooms())
	mind.last_hearing = strength
	if strength <= 0.0:
		return
	# Hot-zone memory: a room the crew keeps being loud in draws more attention as
	# the run goes on, which is what makes a siphon you tapped ten minutes ago
	# still a bad place to stand.
	memory.warm(room, strength)
	# The track is keyed on the SOUND, not on a crewmate. This is the fairness
	# line: a creature can believe strongly that something is over there without
	# ever having acquired a person.
	var key: String = "noise:" + String(event["source"])
	# An IMPULSE, not a tick of continuous stimulus — see `AI_NOISE_IMPULSE`. A
	# noise happens once and is over; charging it one AI tick of gain undercounted
	# every sound in the game by the tick rate, which is why a screech two rooms
	# away could not raise a Hound's eyebrow.
	if mind.feed(key, strength, where, "sound", Balance.AI_NOISE_IMPULSE):
		# Fresh belief about where something is. It does not overwrite a stronger,
		# more recent SIGHT — `mark_seen` is only called when the noise is the best
		# thing this creature currently knows.
		if mind.awareness() <= strength * Perception.AWARE_GAIN * Balance.AI_TICK + 0.001 \
				or memory.confidence() <= 0.0:
			memory.mark_seen(where, room)
	# Legacy per-creature reaction. The Scrubber's converge-on-noise and the
	# Hound's noise hold still live in their own `alert()` overrides, so M6's tuned
	# behaviour is intact and M11 is additive rather than a rewrite.
	alert(where, int(event["rooms"]), float(event["seconds"]))


# --- the search --------------------------------------------------------------

## Where this creature is currently walking to check, or `Vector3.INF`.
func search_goal() -> Vector3:
	return _search_goal


## Picks and retires search targets. THE state the fear lives in.
##
## Terminates, and that is a property rather than a hope: candidates are finite,
## every spot the creature reaches is marked searched, and `next_search_spot`
## skips marked spots — so the pool strictly shrinks and `_search_done` is
## reachable. `--selftest` drives exactly this to exhaustion headlessly, because
## "the search does not loop forever" is the one claim a capture cannot make.
func _advance_search(_delta: float) -> void:
	if _search_goal != Vector3.INF:
		if global_position.distance_to(_search_goal) > Balance.AI_SEARCH_ARRIVE:
			return
		# Arrived. Stand here and look for a beat — the dwell is most of what makes
		# a search read as a search rather than as a patrol with extra steps.
		if not memory.was_searched(_search_goal):
			memory.mark_searched(_search_goal)
			_search_dwell = Balance.AI_SEARCH_DWELL
			_why = "checked %s" % _search_kind
			return
		if _search_dwell > 0.0:
			return
		_search_goal = Vector3.INF

	if _search_dwell > 0.0:
		return
	var kinds: Array[String] = []
	var spots: Array[Vector3] = _search_candidates(kinds)
	var next: Vector3 = memory.next_search_spot(spots, global_position, kinds)
	if next == Vector3.INF:
		_search_done = true
		_search_kind = ""
		return
	_search_done = false
	_search_goal = next
	_search_kind = "spot"
	for i: int in spots.size():
		if spots[i] == next and i < kinds.size():
			_search_kind = kinds[i]
			break
	_why = "search %s" % _search_kind


## The plausible places a target could have gone, drawn from the LAYER — which is
## where M6.6's verticality finally pays a behavioural dividend. A creature that
## lost you checks, in this order of preference once scored:
##
##   * the last-known position itself;
##   * the DECKS in that room — the perches, gantries, control decks and pits a
##     player climbs to break line of sight ("drop" habit);
##   * the LEDGES a player can step off ("drop" habit);
##   * the corridor mouths out of that room, and the neighbouring rooms beyond
##     them ("corner" habit).
##
## `kinds` comes back parallel to the returned array so `HuntMemory` can apply
## whatever escape habit this creature has learned. Subclasses narrow the list
## (the Sentinel refuses anything outside its zone; the Moth prefers light).
func _search_candidates(kinds: Array[String]) -> Array[Vector3]:
	var spots: Array[Vector3] = []
	if graph == null:
		return spots
	var anchor: Vector3 = memory.lkp if memory.lkp != Vector3.INF else global_position
	var room: int = memory.lkp_room if memory.lkp_room >= 0 else current_room()
	if room < 0:
		return spots

	spots.append(anchor)
	kinds.append("lkp")

	for deck_id: int in graph.decks_in(room):
		var deck: Dictionary = graph.decks[deck_id]
		var lo: Vector2 = deck["min"]
		var hi: Vector2 = deck["max"]
		spots.append(Vector3((lo.x + hi.x) * 0.5, float(deck["y"]), (lo.y + hi.y) * 0.5))
		kinds.append("drop")

	for drop: Dictionary in graph.deck_drops:
		if int(drop["room"]) != room:
			continue
		spots.append(drop["to"])
		kinds.append("drop")

	for other: int in graph.rooms.size():
		if other == room:
			continue
		if graph.room_distance(room, other) != 1:
			continue
		spots.append(graph.link_point(room, other))
		kinds.append("corner")
		spots.append(graph.centre_of(other))
		kinds.append("corner")
	return spots


# --- the ladder --------------------------------------------------------------

## One rung. Host-side; publishes the state, fires the telegraph, records the
## trace and hands the doctrine hook to the subclass.
func _enter_suspicion(next: int, reason: String) -> void:
	var previous: int = suspicion
	suspicion = next
	sync_suspicion = next
	_why = reason

	if next == Suspicion.State.LOST:
		# LIGHT ADAPTATION. How did they break contact? Inferred from geometry the
		# creature can actually see — was the place it lost them beside a ledge, or
		# was it a corner? — never from a privileged fact about the player. Bounded
		# hard inside `HuntMemory`, and it only ever changes what gets checked
		# FIRST, so the behaviour stays readable.
		memory.note_escape(_escape_habit())
		# FALSE DEPARTURE, sparingly. The terror is in the possibility, not in the
		# frequency, so this is rate-limited to once every 75 s per creature and
		# rolled off the creature's own seeded generator (reproducible in a
		# capture, not a wall-clock coin flip).
		if memory.may_false_depart(_ai_rng.randf()):
			_depart_time = HuntMemory.FALSE_DEPART_TIME
			_why = reason + "+feint"
	if next == Suspicion.State.UNAWARE:
		_search_goal = Vector3.INF
		_search_done = false

	if Suspicion.announces(previous, next):
		_telegraph(next)
	_on_suspicion(previous, next)

	if Debug.log_ai or AIDebug.tracing():
		AIDebug.write({
			"t": "%.2f" % (float(Time.get_ticks_msec()) / 1000.0),
			"id": String(name), "kind": ai_kind(),
			"st": Suspicion.label(next), "aw": "%.2f" % mind.awareness(),
			"why": reason, "lkp": AIDebug.v(memory.lkp),
			"conf": "%.2f" % memory.confidence(),
		})


## Which escape habit the geometry says the crew just used. Ledges within a
## couple of metres of the last-known position mean they dropped; anything else is
## a corner. Deliberately coarse — the point is a lean, not a model.
func _escape_habit() -> String:
	if graph == null or memory.lkp == Vector3.INF:
		return "corner"
	for drop: Dictionary in graph.deck_drops:
		if Vector3(drop["at"]).distance_to(memory.lkp) < 4.0:
			return "drop"
	return "corner"


## The tell. Audio on every peer that can hear it, plus the caption from the same
## call site so a deaf player gets the same information at the same instant. The
## posture half is the subclass's job (its emissive and its gait already read off
## `sync_state`, and M11 gives it `sync_suspicion` as well).
func _telegraph(state: int) -> void:
	var cue: StringName = _telegraph_sound(state)
	if cue != &"":
		Audio.play_3d(cue, global_position)
	var caption: StringName = Suspicion.caption_key(state)
	if caption != &"":
		Captions.emit(caption, global_position, 28.0)


## Short class tag for traces and the overlay.
func ai_kind() -> String:
	return "antivirus"


# --- diegetic coordination ---------------------------------------------------

## THE SCREECH. The one and only way information moves between processes in this
## game, and the reason the whole coordination layer stays fair.
##
## A creature that spots the crew screams. The scream is a REAL NoiseBus event at
## a REAL position with a real reach — the same bus a kicked can rides — so a
## Hound two rooms away converges because it HEARD it, not because the game told
## it. Three properties fall out of doing it this way and all three are the point:
##
##   * the player can hear it too, and can learn what it means;
##   * killing the screamer BEFORE it screams is a genuine tactic with a genuine
##     window (the cooldown below is the size of that window);
##   * no code path anywhere shares a target, a position or an awareness value
##     between two creatures, so "no telepathy" is structural rather than a rule
##     somebody has to remember.
func screech() -> void:
	if not _is_host or _dying or _screech_cooldown > 0.0:
		return
	_screech_cooldown = Balance.AI_SCREECH_COOLDOWN
	Audio.play_3d(&"scrubber_alert", global_position)
	Captions.emit(&"scrubber_screech", global_position, 34.0)
	NoiseBus.ping(global_position, Balance.AI_SCREECH_ROOMS, "scrubber_screech",
			Balance.AI_SCREECH_HOLD, -1.0, self)


## Host-side. The Director points a hunter at a ZONE — never at a player. The
## creature closes the last gap with its own senses, which is the rule that keeps
## the Director from being a wallhack with good manners.
func hint_zone(where: Vector3) -> void:
	if not _is_host or _dying:
		return
	_hint = where
	_hint_life = Balance.AI_HINT_LIFETIME


## Where doctrine should drift when it has nothing better: the Director's hint,
## else the warmest room this creature remembers, else `Vector3.INF`.
func drift_target() -> Vector3:
	if _hint != Vector3.INF:
		return _hint
	if graph != null:
		var hottest: int = memory.hottest_room()
		if hottest >= 0:
			return graph.centre_of(hottest)
	return Vector3.INF


## Speed multiplier for the current rung. Applied on top of each creature's own
## authored speeds — none of which M11 changes.
func suspicion_speed() -> float:
	match suspicion:
		Suspicion.State.CURIOUS:
			return Balance.AI_SPEED_CURIOUS
		Suspicion.State.ALERT:
			return Balance.AI_SPEED_ALERT
		Suspicion.State.LOST:
			return Balance.AI_SPEED_LOST
		_:
			return 1.0


## Whether this creature is currently pretending to leave.
func departing() -> bool:
	return _depart_time > 0.0


## The BODY this creature is entitled to strike at, or null.
##
## Non-null ONLY when the best track is a real node AND evidence arrived on the
## most recent tick — so a creature can never swing at a remembered position, and
## the whole of "it lost you" is expressed by this returning null. Every doctrine
## reads it instead of calling `_nearest_player`, which is what makes the fairness
## invariant hold at the point of contact and not only at the point of sensing.
func hunted_body() -> Node3D:
	if suspicion != Suspicion.State.HUNTING:
		return null
	var top: Dictionary = mind.best()
	if top.is_empty() or float(top.get("strength", 0.0)) <= 0.0:
		return null
	var node: Node3D = top.get("node", null) as Node3D
	if node == null or not is_instance_valid(node):
		return null
	return node


## Where doctrine should be walking, given the rung. The single place the ladder
## becomes movement:
##
##   HUNTING  the body itself while evidence is live, else where it last was;
##   LOST     the current search target — the last-known position first, then
##            outward through the plausible places;
##   ALERT    the same search, but anchored on whatever registered rather than on
##            a person;
##   CURIOUS  drift toward the thing that registered and LOOK;
##   UNAWARE  `Vector3.INF` — doctrine's own patrol owns this rung.
##
## Returns `Vector3.INF` when the mind has nothing to offer, which is the signal
## for a subclass to fall back to its own idle behaviour.
func hunt_goal() -> Vector3:
	# A FALSE DEPARTURE overrides everything for its few seconds: it walks away,
	# and then it comes back, because `_depart_time` runs out and the search goal
	# is still sitting there waiting.
	if _depart_time > 0.0:
		var away: Vector3 = drift_target()
		if away != Vector3.INF:
			return away
		if graph != null and home_room >= 0:
			return graph.centre_of(home_room)
	match suspicion:
		Suspicion.State.HUNTING:
			var body: Node3D = hunted_body()
			if body != null:
				return body.global_position
			return memory.lkp
		Suspicion.State.LOST, Suspicion.State.ALERT:
			if _search_goal != Vector3.INF:
				return _search_goal
			return memory.lkp
		Suspicion.State.CURIOUS:
			var top: Dictionary = mind.best()
			if not top.is_empty():
				return top["last_pos"]
			return memory.lkp
		_:
			return Vector3.INF


# --- the instrument ----------------------------------------------------------

## Everything the overlay draws and the trace prints, in one read-only record.
## Public because the overlay is a separate node; deliberately a copy, so nothing
## the instrument does can perturb the simulation it is measuring.
func ai_report() -> Dictionary:
	var top: Dictionary = mind.best()
	var done: Array[Vector3] = []
	for entry: Dictionary in memory.searched:
		done.append(entry["pos"])
	return {
		"kind": ai_kind(),
		"state": Suspicion.label(suspicion),
		"awareness": mind.awareness(),
		"sight": mind.last_sight,
		"hearing": mind.last_hearing,
		"confidence": memory.confidence(),
		"radius": memory.search_radius(),
		"lkp": memory.lkp,
		"goal": _search_goal,
		"searched": done,
		"why": _why,
		"target": String(top.get("key", "")),
		"eye": global_position + Vector3.UP * _eye_height(),
		"cone_deg": sight_cone_deg() * 0.5,
		"sight_range": sight_range(),
	}


func _trace(delta: float) -> void:
	if not AIDebug.tracing() or AIDebug.trace_hz <= 0.0:
		return
	_trace_clock -= delta
	if _trace_clock > 0.0:
		return
	_trace_clock = 1.0 / AIDebug.trace_hz
	var top: Dictionary = mind.best()
	AIDebug.write({
		"t": "%.2f" % (float(Time.get_ticks_msec()) / 1000.0),
		"id": String(name), "kind": ai_kind(),
		"st": Suspicion.label(suspicion), "dw": "%.1f" % _dwell,
		"aw": "%.2f" % mind.awareness(), "live": str(mind.live()),
		"see": "%.2f" % mind.last_sight, "hear": "%.2f" % mind.last_hearing,
		"lkp": AIDebug.v(memory.lkp), "conf": "%.2f" % memory.confidence(),
		"goal": AIDebug.v(_search_goal), "why": _why,
		"tgt": String(top.get("key", "-")),
		"hot": str(memory.hottest_room()),
		"adapt": "%.2f/%.2f" % [memory.bias_of("drop"), memory.bias_of("corner")],
	})


# ------------------------------------------------------------------- combat --

## What the breaker is pointing at, or null. Shared by the shooter (drawing its
## own lash the frame it fires) and the host (deciding what actually died), so
## the streak and the kill can never disagree about which creature was in the
## way. Walls win: nothing behind cover is cuttable.
## `reach` is the shooter's Breaker range (Modules), passed in rather than read
## from Balance so the shooter's predicted lash and the host's authoritative
## re-cast use the same number for the same player.
static func pick_target(tree: SceneTree, space: PhysicsDirectSpaceState3D,
		origin: Vector3, direction: Vector3,
		reach: float = Balance.BREAKER_RANGE) -> Antivirus:
	if tree == null:
		return null
	var aim: Vector3 = direction.normalized()
	var limit: float = cos(deg_to_rad(Balance.BREAKER_AIM_DEG))

	var best: Antivirus = null
	var best_dot: float = limit
	for node: Node in tree.get_nodes_in_group(GROUP):
		var creature: Antivirus = node as Antivirus
		if creature == null or not is_instance_valid(creature) or creature._dying:
			continue
		var to_creature: Vector3 = creature.aim_point() - origin
		var distance: float = to_creature.length()
		if distance > reach or distance < 0.01:
			continue
		var alignment: float = (to_creature / distance).dot(aim)
		# M12: SLACK IN METRES, NOT IN DEGREES.
		#
		# `BREAKER_AIM_DEG` is an ANGLE, so the lateral tolerance it buys grows
		# with distance. That was invisible while the cutter reached 8 m — 7.5
		# degrees bought about a metre of slop and the close-quarters feel was
		# tuned around exactly that. At the new 30 m the same angle buys nearly
		# four metres, which is not a longer-range tool, it is a soft-lock: point
		# vaguely at a dark shape across a hall and something dies.
		#
		# So the cone stays a cone up close and stops widening past
		# `BREAKER_AIM_SLACK_M`. Point-blank forgiveness is preserved to the
		# millimetre (the `minf` picks the angular term whenever it is the smaller
		# of the two, which is everywhere inside ~8 m) and the windfall at range is
		# gone: a 30 m shot now demands you are actually pointing at the thing.
		#
		# NOTHING HERE CHANGES WHAT A HIT DOES. This is purely what counts as
		# aimed at; `breaker_damage` and every health number are untouched, so the
		# killability ladder is bit-for-bit what it was.
		var slack: float = minf(distance * tan(deg_to_rad(Balance.BREAKER_AIM_DEG)),
				Balance.BREAKER_AIM_SLACK_M)
		var need: float = cos(atan(slack / distance))
		if alignment <= maxf(need, best_dot):
			continue
		if space != null:
			var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
					origin, creature.aim_point())
			query.collision_mask = WORLD_MASK
			if not space.intersect_ray(query).is_empty():
				continue
		best_dot = alignment
		best = creature
	return best


## Where the cutter aims at this creature. Subclasses that are not knee-high
## override it.
func aim_point() -> Vector3:
	return global_position + Vector3.UP * 0.5


## Host-side. THE door every hostile hit in the game goes through.
##
## M7 introduces it because three things now sit between "a process swung" and
## "a crewmate lost integrity", and each of the five creatures used to open that
## door itself with a bare `Run.damage_player(int(String(body.name)), …)`. That
## spelling was fine while the only thing a creature could ever be swinging at was
## a player; it is actively dangerous the moment a FORK DECOY is a legitimate
## target, because `int("ForkDecoy_3")` is 0 and peer 0 is not a peer — it would
## have written integrity for a crew member who does not exist.
##
## So the question is asked once, here, in order:
##
##   1. **Is it a fork?** Then nothing takes damage. The decoy soaks a strike and
##      may decompile early; that is the whole of its interaction with combat.
##   2. **Is the target inside SURGE STEP's i-frames?** Then the blow misses. The
##      Hound learns nothing from a dash — it just misses.
##   3. **Is there a CHECKSUM BARRIER over them?** Then the shell takes what it
##      can and only the remainder lands. Crew inside somebody else's shell are
##      covered too; that is the co-op play.
##   4. Otherwise it is a hit, through `Run.damage_player` exactly as before —
##      still the single door integrity leaves by.
func _land_hit(body: Node3D, amount: float) -> void:
	if not _is_host or body == null or not is_instance_valid(body) or amount <= 0.0:
		return

	var decoy: ForkDecoy = body as ForkDecoy
	if decoy != null:
		Subs.report_decoy_strike(decoy)
		return

	var player: Player = body as Player
	if player == null:
		return
	if Subs.invulnerable(player.peer_id):
		if Debug.log_ai:
			print("[AI] %s struck %s during a surge step — missed" % [
				String(name), Net.crew_name(player.peer_id)])
		return

	var landed: float = amount
	var barrier: ChecksumBarrier = ChecksumBarrier.covering(get_tree(),
			player.global_position)
	if barrier != null:
		landed = barrier.take(amount)
		Subs.report_barrier_absorb(barrier)
	if landed <= 0.0:
		return
	# 5. **M9: does a hot-patch answer this?** Asked last, after the shell, so a
	#    patch never covers for a barrier that was already covering — WATCHDOG's
	#    once-a-layer charge must be spent on a blow that was genuinely going to
	#    land. Deliberately hooked HERE rather than in `Run.damage_player`, which
	#    would also catch falls and starvation: a patch is error correction against
	#    MOTHER's writes, and a drop off a gantry is your own arithmetic.
	landed = Patches.on_incoming(player.peer_id, landed, global_position)
	if landed <= 0.0:
		return
	Run.damage_player(player.peer_id, landed, global_position)


## Host-side. Everything hostile is killable; what varies is how much a given
## shot is worth against it (see `breaker_damage`).
## M15: how this process was last hurt, so `kill()` can say how it DIED.
##
## The writer cannot see a kill method from outside `src/creatures/` — from out
## there every deletion looks identical — so 28 written lines sat unreachable for
## want of one word at the moment of death. This is that word.
##
## `kind` is optional and defaults to the breaker, so the three existing callers
## (`RunState`'s hitscan and the two `Patches` paths) compile and behave exactly as
## before. A caller that knows better may say so; one that does not is assumed to
## be the cutter, which it almost always is.
var _last_damage_kind: StringName = &"breaker"
## Set by a subclass whose `breaker_damage` applied a weak-point multiplier — see
## `Sentinel`. Cleared by any subsequent ordinary hit, so "killed on the core" is
## a claim about the LAST shot rather than about any shot in the fight.
var _last_hit_weakpoint: bool = false

## Chain bookkeeping, shared across every process on the layer: two deletions
## inside this window are a chain. Static because the fact is about the CREW's
## rate of fire, not about any one creature — and it is reset per layer by the
## director's teardown.
static var _last_kill_at: float = -999.0
const CHAIN_WINDOW: float = 3.0
## How many live processes within this radius make a death a CROWD kill.
const CROWD_RADIUS: float = 12.0
const CROWD_COUNT: int = 4


func take_damage(amount: float, _from: Vector3, kind: StringName = &"") -> void:
	if not _is_host or _dying or amount <= 0.0:
		return
	if kind != &"":
		_last_damage_kind = kind
	elif _from.distance_squared_to(global_position) < 0.01:
		# Damage whose origin IS this creature has no external source: that is a
		# damage-over-time bite (the ROT patch), not somebody shooting. Inferred
		# rather than declared because the caller lives in another agent's file;
		# an explicit `kind` from there overrides this and should.
		_last_damage_kind = &"rot"
	else:
		_last_damage_kind = &"breaker"
	# M11: being cut is EVIDENCE, and it is the strongest kind — it tells you a
	# direction and that something is definitely there. Fed through the same door
	# as sight and hearing (so the fairness invariant covers it) and keyed on the
	# wound rather than on a crewmate, because a shot from the dark does not
	# identify who fired it. The creature has to turn round and look.
	if _from != Vector3.ZERO:
		mind.feed("pain", 1.0, _from, "pain", Balance.AI_TICK)
		if graph != null:
			memory.mark_seen(_from, graph.region_of(_from))
	health -= amount
	# PT1: publish the wound before the subclass reacts to it, so a hunter that
	# changes state on being hit cannot land its packet ahead of the number the
	# integrity readout is about to draw.
	sync_integrity = clampf(health / maxf(health_max, 0.001), 0.0, 1.0)
	_on_hurt()
	if health <= 0.0:
		kill()


## Sets the starting health and remembers it as the maximum. Every subclass rolls
## its own health off `Balance` at spawn; routing it through here is what lets the
## integrity readout report a FRACTION without each of them publishing a ceiling.
func set_health(value: float) -> void:
	health = value
	health_max = maxf(value, 0.001)
	sync_integrity = 1.0


## 0..1 hit flash, ALREADY capped. The only legal way to read it.
func hurt_flash() -> float:
	return _hurt_flash * A11y.flash_scale


## One landed cut. Runs on every peer (the host directly, clients through each
## subclass's `_hit` relay), so the rate cap is enforced on every screen against
## that screen's own clock rather than trusting a packet order.
func trigger_hurt_flash() -> void:
	if _since_hurt_flash < HURT_FLASH_MIN_INTERVAL:
		return
	_since_hurt_flash = 0.0
	_hurt_flash = 1.0


## Called from each subclass's visual tick with its own decay rate.
func decay_hurt_flash(delta: float, rate: float) -> void:
	_since_hurt_flash += delta
	_hurt_flash = maxf(_hurt_flash - delta * rate, 0.0)


## Host-side death. Flips the streamed flag and plays the shatter locally; every
## peer that can see this creature does the same a packet later, and each frees
## its own copy when its animation is done.
func kill() -> void:
	if _dying:
		return
	_note_kill_method()
	sync_dead = true
	_begin_death()


## M15. One line telling the writer HOW this died, at the moment it does.
##
## Ordered most-specific first, and each arm is a fact this file can actually
## establish rather than a guess: the damage kind comes from `take_damage`, the
## weak point from the subclass's own `breaker_damage`, the chain from the clock,
## the crowd from a group count. A death that matches nothing notes nothing —
## silence is a legitimate answer and better than a wrong label.
func _note_kill_method() -> void:
	if not _is_host:
		return
	var lore: LoreDirector = LoreDirector.get_instance()
	if lore == null:
		return
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var trigger: StringName = &""
	if _last_damage_kind == &"rot":
		trigger = &"kill.rot"
	elif _last_damage_kind == &"subroutine":
		trigger = &"kill.subroutine"
	elif _last_hit_weakpoint:
		trigger = &"kill.weakpoint"
	elif now - _last_kill_at <= CHAIN_WINDOW:
		trigger = &"kill.chain"
	elif _crowd_here() >= CROWD_COUNT:
		trigger = &"kill.crowd"
	_last_kill_at = now
	if trigger != &"":
		lore.note(trigger, {"kind": ai_kind(), "layer": layer_number})


## Live processes standing near this one, itself excluded. A crowd kill is one
## taken in the middle of a pack, which is a different thing to say about a crew
## than a clean single deletion in an empty corridor.
func _crowd_here() -> int:
	var near: int = 0
	for node: Node in get_tree().get_nodes_in_group(GROUP):
		var creature: Antivirus = node as Antivirus
		if creature == null or creature == self or not is_instance_valid(creature):
			continue
		if creature._dying:
			continue
		if creature.global_position.distance_to(global_position) <= CROWD_RADIUS:
			near += 1
	return near


## What one breaker shot from `from` does to this creature. Armoured processes
## override it to make where you are standing matter — nothing in NULLVOID is
## immune to the cutter, but not everything takes the same damage from it.
func breaker_damage(_from: Vector3, base: float = Balance.BREAKER_DAMAGE) -> float:
	return base


## Subclass hook: a hit landed (host only).
func _on_hurt() -> void:
	pass


## Sends a cosmetic event to every peer whose world is already standing. A plain
## `rpc()` would also reach a peer that is still loading its layer, where the
## node this method lives on does not exist yet — and that is an engine error on
## the receiving side, not a dropped packet. The crew roster is the same gate the
## synchronizers use.
func _tell_crew(method: StringName) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	for id: int in Net.crew.keys():
		var peer: int = int(id)
		if peer != 1:
			rpc_id(peer, method)


## Subclass hook: something loud happened at `where`. Host only.
##
## `rooms` is how far the sound carried, in rooms of the layer graph, and
## `seconds` is how long it should hold this creature's attention. M2's siphon
## ping was the only caller and hard-coded both; M4.8 routes five different
## noises through `Noise` (rewires, welds, cabinet cuts, terminal queries, kicked
## debris) at three different reaches, so the numbers travel with the sound.
##
## The defaults are the siphon's, which keeps every existing call site honest.
func alert(_where: Vector3, _rooms: int = Balance.TAP_ALERT_ROOMS,
		_seconds: float = Balance.TAP_ALERT_TIME) -> void:
	pass


func _begin_death() -> void:
	_dying = true
	collision_layer = 0
	collision_mask = 0
	died.emit()
	_play_death()


## Subclass hook: the shatter. Must free the node when it is done.
func _play_death() -> void:
	queue_free()


## Called by the director on descent. Silent and immediate — the layer is being
## rewritten and nobody should see a death animation for it.
func despawn() -> void:
	_dying = true
	queue_free()
