class_name AIDebug
extends RefCounted
## M11 — THE INSTRUMENT, BUILT FIRST.
##
## This repo's culture is that you build the instrument before you tune the
## thing: `--auditvert` before the verticality pass, `--deckwalk` before the deck
## climb, `--ui-audit` before the HUD work, `--gunlog` before the aim solve. Every
## one of those existed because a human report ("it feels off") and a clean
## measurement disagreed, and the only way through was an instrument pointed at
## what the player actually sees.
##
## "The enemy AI feels too simple" is exactly that class of report. So before a
## line of new behaviour was written, this: per creature, its current state, what
## it can see and hear RIGHT NOW and how strongly, its last-known-player-position
## and the confidence decaying on it, its current search target and WHY, and its
## recent memory — drawn in the world behind a flag and printed as a machine-
## readable trace.
##
## ## Why a static singleton rather than an autoload or a Debug section
##
## Two other agents are editing this working copy right now, and `project.godot`
## and `debug.gd`'s argument parser are the two files a third editor is most
## likely to collide in. Static vars on a `class_name` need neither: the flags
## parse themselves out of `OS.get_cmdline_user_args()` on first touch, and every
## call site is `AIDebug.something`. Nothing in the shared instrument moves.
##
## ## Flags
##
##   --aidebug              in-world overlay + trace to stdout
##   --aioverlay            overlay only (quiet), for clean capture frames
##   --ailog <path>         machine-readable trace to a file
##   --aitrace-hz <n>       trace rate, default 4 Hz (0 = state changes only)
##
## The trace line is deliberately one flat `key=value` record per sample so it
## greps, sorts and diffs. A behaviour claim in this milestone is a line in this
## file, not an impression from a screenshot.

## One line per state change, always, when any tracing is on. The rest of the
## trace is sampled; transitions are not, because a transition is the event.
const TRACE_PREFIX: String = "[AI11]"

static var _booted: bool = false

## Draw the in-world overlay (state label, sight cone, LKP marker, search path).
static var overlay: bool = false
## Print the trace to stdout.
static var trace_stdout: bool = false
## Trace samples per second per creature. 0 means transitions only.
static var trace_hz: float = 4.0
## Where the machine-readable trace is written, or "".
static var log_path: String = ""

static var _log: FileAccess = null
static var _lines: int = 0


## Parses the flags once. Every public entry point calls it, so no boot order is
## assumed and nothing has to be wired into an autoload's `_ready`.
static func ensure() -> void:
	if _booted:
		return
	_booted = true
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < args.size():
		var arg: String = args[i]
		match arg:
			"--aidebug":
				overlay = true
				trace_stdout = true
			"--aioverlay":
				overlay = true
			"--ailog":
				if i + 1 < args.size():
					i += 1
					log_path = args[i]
			"--ai-scenario":
				if i + 1 < args.size():
					i += 1
					scenario = args[i]
			"--aitrace-hz":
				if i + 1 < args.size():
					i += 1
					trace_hz = maxf(args[i].to_float(), 0.0)
			_:
				pass
		i += 1
	if not log_path.is_empty():
		_log = FileAccess.open(log_path, FileAccess.WRITE)
		if _log == null:
			printerr("[AI11] could not open trace log %s" % log_path)
		else:
			_log.store_line("# NULLVOID M11 AI trace — one record per sample")
			_log.store_line("# t id kind state dwell aware live sight hear lkp conf goal why")


static func active() -> bool:
	ensure()
	return overlay or trace_stdout or _log != null


static func tracing() -> bool:
	ensure()
	return trace_stdout or _log != null


## One trace record. `fields` is a flat dictionary; the order below is fixed so
## the file is columnar and a diff between two runs lines up.
static func write(fields: Dictionary) -> void:
	ensure()
	if not trace_stdout and _log == null:
		return
	var parts: PackedStringArray = PackedStringArray()
	for key: String in ["t", "id", "kind", "st", "dw", "aw", "live", "see", "hear",
			"lkp", "conf", "goal", "why", "tgt", "hot", "adapt"]:
		if fields.has(key):
			parts.append("%s=%s" % [key, str(fields[key])])
	var line: String = TRACE_PREFIX + " " + " ".join(parts)
	if trace_stdout:
		print(line)
	if _log != null:
		_log.store_line(line)
		_lines += 1
		# Flushed every few lines rather than every line: a capture that crashes
		# must still leave a readable trace, and an instrument that halves the
		# frame rate is measuring itself.
		if _lines % 16 == 0:
			_log.flush()


static func close() -> void:
	if _log != null:
		_log.flush()
		_log = null


# =================================================== THE SCENARIO HARNESS ====
#
# The reels are the acceptance gate, and the first attempt at them failed for a
# reason that had nothing to do with the AI: the shutter fired while the agent
# was standing at spawn, so every creature in frame was correctly and uselessly
# UNAWARE. A behaviour reel needs the behaviour to be HAPPENING when the frame is
# taken, and hoping the timing lines up is not a method.
#
# So the capture is scripted. `--ai-scenario <kind>` drives the local agent
# through a fixed sequence against a chosen hunter — approach, be seen, break
# contact, hide — with fixed dwell times, so a `--reel` filmstrip taken over the
# same window is GUARANTEED to contain the ladder rather than likely to.
#
# Scripted, not faked. Nothing here touches a creature, a perception value or a
# suspicion state: it moves the PLAYER and toggles the PLAYER's beam, and every
# transition the reel shows is the real state machine reacting to a real agent
# through the ordinary senses. The harness is a camera operator, not a puppeteer.
#
#   ladder     approach lit -> hold -> break contact + go dark -> hold long
#              (UNAWARE -> CURIOUS -> ALERT -> HUNTING -> LOST -> search -> decay)
#   screech    stand in a Scrubber's cone until it screams, then watch the Hound
#   doctrine   identical approach/hide, for the four-hunter comparison sheet
#   solo       approach, then break contact and hold: the fairness capture
#
# Armed by the first creature that reaches `Antivirus.setup`, which is the
# earliest moment the layer, the agent and the hunters all exist.

static var scenario: String = ""
static var _armed: bool = false

## How far the agent stands while being seen, as a FRACTION of the subject's own
## sight range — never a fixed distance.
##
## The first cut used a flat 11 m and filmed nothing: the Hound sees nine metres
## (`AI_SIGHT_HOUND`), so the agent was stood politely outside the sensorium of
## the creature the reel was about, and the trace correctly recorded a Hound that
## never noticed anything. Every hunter has a different reach by design — that is
## the doctrine table — so the harness has to ask the subject rather than assume.
const SCENARIO_APPROACH_FRACTION: float = 0.6
const SCENARIO_APPROACH_MIN: float = 4.0


## Called by `Antivirus.setup`. Runs once per process.
static func arm_scenario(tree: SceneTree) -> void:
	ensure()
	if scenario.is_empty() or _armed or tree == null:
		return
	_armed = true
	_run_scenario(tree)


static func _run_scenario(tree: SceneTree) -> void:
	# Deliberately detached: the caller is mid-`setup()` inside a spawn, and a
	# coroutine that awaited there would stall the build it is riding on.
	_scenario_body(tree)


static func _scenario_body(tree: SceneTree) -> void:
	await tree.create_timer(3.0).timeout
	var subject: Antivirus = _pick_subject(tree)
	var agent: Node3D = _local_agent(tree)
	if subject == null or agent == null:
		print("[AI11] scenario '%s': no subject or no agent — nothing to film" % scenario)
		return
	print("[AI11] scenario '%s' subject=%s" % [scenario, String(subject.name)])
	if scenario == "screech":
		_stage_listener(tree, subject)

	# 1. APPROACH, LIT. Stand in front of it with the beam on: the most findable a
	#    crewmate can be, so the climb is fast and unambiguous on the strip.
	var approach: float = maxf(subject.sight_range() * SCENARIO_APPROACH_FRACTION,
			SCENARIO_APPROACH_MIN)
	_set_beam(agent, true)
	print("[AI11] scenario: approach (lit, %.1f m of a %.0f m sensorium)" % [
		approach, subject.sight_range()])
	# IN FRONT OF IT, AND STAY THERE.
	#
	# The second failed cut placed the agent along the bearing it happened to
	# already be on and held for nine seconds. That put it behind a patrolling
	# Hound, which then wandered off, and the trace recorded 46 seconds of a
	# perfectly correct UNAWARE — the harness had stood the agent outside the cone
	# of the creature it was filming and then waited.
	#
	# "Approach" means walking into its view, so the harness re-seats the agent in
	# the subject's own FORWARD arc every half second while it is being seen. This
	# is still not puppeteering the creature: it moves the player into the sensor,
	# and whether that produces evidence is entirely the perception model's call.
	for _i: int in 20:
		if not is_instance_valid(subject) or not is_instance_valid(agent):
			break
		_place_in_front(agent, subject, approach)
		_set_beam(agent, true)
		await tree.create_timer(0.5).timeout

	if scenario == "screech":
		# Hold longer: the Scrubber has to acquire, scream, and the Hound has to
		# cross the layer on the noise. THE demo — the convergence is the point.
		print("[AI11] scenario: holding for screech convergence")
		for _s: int in 16:
			await tree.create_timer(1.0).timeout
			if not is_instance_valid(subject) or not is_instance_valid(agent):
				break
			_place_in_front(agent, subject, approach)
			_set_beam(agent, true)
		return

	# 2. BREAK CONTACT AND GO DARK. Beam off first, then leave — the order matters,
	#    because turning the lamp off is the thing that actually stops the evidence.
	#
	#    And then KEEP LEAVING. The first cut of this teleported once and held, and
	#    the trace showed the Hound going LOST -> HUNTING -> LOST -> HUNTING three
	#    times in forty seconds. That was not a bug in the scenario and it was not a
	#    bug in the AI: it is the tracker doctrine working exactly as specified —
	#    it walked the 46 m, re-acquired, and the whole point of the creature is
	#    that distance alone does not shake it.
	#
	#    A player breaking contact for real does not stand still while a Hound jogs
	#    at them, so neither does the harness. It re-establishes the gap once a
	#    second, which is what "kept running, dark" looks like from the creature's
	#    side, and THAT is the condition the reel needs to film: evidence genuinely
	#    stops, LOST holds, the outward search runs, and the decay is honest.
	_set_beam(agent, false)
	# A FIXED refuge, not a moving offset. The first cut re-placed the agent
	# relative to the creature every second, which flipped the bearing as the
	# creature circled and occasionally teleported the agent straight back through
	# its proximity sense — the harness was re-acquiring the agent for it. The
	# refuge is the room furthest from the subject, resolved once, and the agent
	# simply stays in it: unambiguous, reproducible frame to frame, and the honest
	# picture of somebody who ran and then stopped moving.
	var refuge: Vector3 = _far_room(subject)
	agent.global_position = refuge
	var hidden: Player = agent as Player
	if hidden != null:
		hidden.sync_position = refuge
	print("[AI11] scenario: contact broken (dark, refuge %.0f m away) — LOST and the outward search start here" % [
		refuge.distance_to(subject.global_position)])
	for _i: int in 26:
		await tree.create_timer(1.0).timeout
		if not is_instance_valid(subject) or not is_instance_valid(agent):
			break
		# Held dark and held put. Re-asserted each second because the agent is a
		# physics body and the beam is a replicated flag; nothing else moves it.
		_set_beam(agent, false)
		agent.global_position = refuge
		if hidden != null:
			hidden.sync_position = refuge
	print("[AI11] scenario: complete")


## The centre of the room furthest from `subject` on this layer — the refuge the
## hide phase retreats to. Off the creature's own graph, so it is a real room with
## a real floor rather than a point in space.
static func _far_room(subject: Antivirus) -> Vector3:
	if subject == null or subject.graph == null:
		return Vector3.ZERO
	var graph: LayerGraph = subject.graph
	var best: Vector3 = subject.global_position
	var best_distance: float = -1.0
	for i: int in graph.rooms.size():
		var centre: Vector3 = graph.centre_of(i)
		var distance: float = centre.distance_to(subject.global_position)
		if distance > best_distance:
			best_distance = distance
			best = centre
	return best


## The creature the reel is about: the nearest HUNTER to the agent, or — for the
## screech demo — the nearest Scrubber, because the Scrubber is the one that has
## to see something for the demo to work at all.
static func _pick_subject(tree: SceneTree) -> Antivirus:
	var want_scrubber: bool = scenario == "screech"
	var agent: Node3D = _local_agent(tree)
	if agent == null:
		return null

	# THE SCREECH DEMO needs the two halves of the conversation within earshot of
	# each other, and by design they are not: `HauntDirector._pick_nest` deliberately
	# enters a hunter at the anchor FURTHEST from the crew, so a Hound forced onto
	# the layer starts well past the screech's three-room reach. The first cut of
	# this picked the Scrubber nearest the AGENT, filmed a perfect screech, and
	# proved only that a Hound four rooms away correctly hears nothing.
	#
	# So for that one scenario the subject is the Scrubber nearest the HOUND. The
	# demo is about the conversation, not about the agent — the agent is only there
	# to be seen, and it gets teleported to the screamer anyway.
	var anchor: Vector3 = agent.global_position
	if want_scrubber:
		for node: Node in tree.get_nodes_in_group(Hunter.HUNTER_GROUP):
			var hunter: Hunter = node as Hunter
			if hunter != null and is_instance_valid(hunter) and hunter is Hound:
				anchor = hunter.global_position
				break

	var best: Antivirus = null
	var best_distance: float = INF
	for node: Node in tree.get_nodes_in_group(Antivirus.GROUP):
		var creature: Antivirus = node as Antivirus
		if creature == null or not is_instance_valid(creature):
			continue
		var is_scrubber: bool = creature is Scrubber
		if want_scrubber != is_scrubber:
			continue
		var distance: float = creature.global_position.distance_to(anchor)
		if distance < best_distance:
			best_distance = distance
			best = creature
	return best


static func _local_agent(tree: SceneTree) -> Node3D:
	if tree == null:
		return null
	var node: Node = Net.get_player(Net.local_id())
	return node as Node3D if node is Node3D and is_instance_valid(node) else null


## Put the agent `reach` metres from the subject, on the subject's own deck, and
## face it — so the creature and its overlay are both in frame.
static func _place(agent: Node3D, subject: Antivirus, reach: float) -> void:
	var away: Vector3 = agent.global_position - subject.global_position
	away.y = 0.0
	if away.length_squared() < 0.01:
		away = Vector3.FORWARD
	var spot: Vector3 = subject.global_position + away.normalized() * reach
	spot.y = subject.global_position.y + 0.1
	agent.global_position = spot
	var player: Player = agent as Player
	if player == null:
		return
	var to_subject: Vector3 = subject.global_position - spot
	player.rotation.y = atan2(-to_subject.x, -to_subject.z)
	player.sync_position = spot
	player.sync_yaw = player.rotation.y


## THE SCREECH DEMO'S SECOND HALF, placed rather than hoped for.
##
## `HauntDirector._pick_nest` deliberately enters a hunter at the seeded anchor
## FURTHEST from the crew — a spawn should be a thing that arrives, not a thing
## that appears on top of you — so a forced Hound reliably starts well outside the
## screech's three-room reach. Two earlier cuts of this demo fought that by
## re-picking which Scrubber screams, and both filmed a perfect screech and a
## Hound that correctly heard nothing.
##
## So stop fighting it: stand the Hound two rooms off the screamer, which is
## inside the reach and outside its own nine-metre sight. That is the honest
## staging for the claim being demonstrated — the Hound must arrive because it
## HEARD the screech, so it must begin unable to see anything.
##
## This moves a creature's BODY and touches nothing else: no awareness, no
## suspicion state, no memory, no target. Whether it then converges is entirely
## the perception model's decision, which is the whole point of filming it.
static func _stage_listener(tree: SceneTree, screamer: Antivirus) -> void:
	if screamer == null or screamer.graph == null:
		return
	var graph: LayerGraph = screamer.graph
	var here: int = graph.region_of(screamer.global_position)
	var want: int = -1
	for i: int in graph.rooms.size():
		if graph.room_distance(here, i) == 2:
			want = i
			break
	if want < 0:
		return
	for node: Node in tree.get_nodes_in_group(Hunter.HUNTER_GROUP):
		var hound: Hound = node as Hound
		if hound == null or not is_instance_valid(hound):
			continue
		var post: Vector3 = graph.centre_of(want)
		hound.global_position = post
		hound.sync_position = post
		print("[AI11] scenario: staged the Hound in %s, %d rooms from the screamer (inside its %d-room hearing, outside its %.0f m sight)" % [
			graph.room_name(want), 2, hound.hearing_rooms(), hound.sight_range()])
		return


## Put the agent in the subject's own forward arc at `reach` metres, facing back
## at it. The bearing comes from the CREATURE's yaw, not from wherever the agent
## happened to be, which is the difference between "walked into its view" and
## "stood behind it hoping".
static func _place_in_front(agent: Node3D, subject: Antivirus, reach: float) -> void:
	var forward: Vector3 = Vector3(-sin(subject.rotation.y), 0.0, -cos(subject.rotation.y))
	var spot: Vector3 = subject.global_position + forward * reach
	spot.y = subject.global_position.y + 0.1
	agent.global_position = spot
	var player: Player = agent as Player
	if player == null:
		return
	var back: Vector3 = subject.global_position - spot
	player.rotation.y = atan2(-back.x, -back.z)
	player.sync_position = spot
	player.sync_yaw = player.rotation.y


## The beam, through the same replicated flag the perception model reads — so
## "went dark" in the reel is exactly the fact the creature loses.
static func _set_beam(agent: Node3D, on: bool) -> void:
	var player: Player = agent as Player
	if player == null:
		return
	player.sync_beam = on


## Compact vector rendering for the trace. Decimetres — enough to see a creature
## move, short enough that a line stays one line.
static func v(point: Vector3) -> String:
	if point == Vector3.INF:
		return "none"
	return "%.1f/%.1f/%.1f" % [point.x, point.y, point.z]
