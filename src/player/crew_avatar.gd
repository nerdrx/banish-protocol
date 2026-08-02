class_name CrewAvatar
extends Node3D
## What your crewmates look like — the third-person body for every remote player.
##
## DESIGN.md: "Crewmates are humanoid program avatars — sleek dark shells with
## emissive circuit seams in their player color." M3.7 swaps the capsule-and-
## boxes placeholder for the CyberSentinel model wearing the **inverted** palette:
## a pale shell with the accents burning in the owner's lobby colour, against the
## enemy's near-black-and-red.
##
## That inversion is the entire readability argument. The silhouette is
## deliberately shared with the thing hunting you — you are an intrusion program
## rendered inside MOTHER's architecture, so of course you are wearing her
## shapes — and colour is what separates *crewmate* from *quarantine process* in
## the tenth of a second a beam sweeps past one. Bright shell, blue-ish accents,
## and a nameplate: friend. Black shell, red core: not.
##
## This is explicitly an **interim** body. The user will ship a dedicated crew
## model; when that lands, only `MODEL` and the clip names below change.
##
## ## Locomotion
##
## The clips are authored cycles on the rig (idle / walk / run, plus a kneel and
## a rise for M3's corrupted state) blended by an AnimationTree and time-scaled by
## the avatar's **replicated** speed. Nothing about the animation crosses the
## wire: `Player.sync_speed` is already streamed for the head-bob, and running the
## same blend off it on every peer costs nothing and cannot desynchronise.
##
## The stride constants below are the metres each authored cycle carries the body
## in one loop. Dividing real speed by the stride gives the playback rate that
## keeps the feet planted — get these wrong and the avatar moonwalks, which is
## the single most obvious animation fault there is.

const MODEL: String = "res://assets/models/crew_avatar.glb"

## The speed each clip was authored to travel at, in metres per second —
## measured off the exported cycles, not guessed: walk carries the body 1.560 m
## in its 1.0 s loop, run 2.467 m in its 0.667 s loop. Dividing real speed by
## these gives the playback rate that keeps the feet planted.
const WALK_SPEED_AUTHORED: float = 1.56
const RUN_SPEED_AUTHORED: float = 3.70
## Below this the avatar is standing still whatever the packets say.
const IDLE_SPEED: float = 0.35
## Cross over to the run clip well below the player's 4.2 m/s walk. Pushing the
## walk cycle to the 2.7x it would need at full walking speed reads as
## scampering; the run clip at 1.14x reads as a person moving.
const RUN_SPEED: float = 3.6
## Clamp on the playback rate, so a clip is never pushed so hard it buzzes or so
## slow it freezes mid-step.
const RATE_RANGE: Vector2 = Vector2(0.45, 2.2)

## Head-look limits, in radians. Same reasoning as the Sentinel's: a head that
## snaps is a turret, a head with no limit is an owl.
const LOOK_YAW_LIMIT: float = 0.9
const LOOK_PITCH_LIMIT: float = 0.5
const NECK_SHARE: float = 0.4

## Crew palette. Pale enough to be a readable silhouette at 15 m in a beam.
## "Pale" against an architecture that sits at 0.095 and an enemy that sits at
## 0.04 — not white. The first pass authored these at 0.60/0.74 and any light
## that touched them at arm's length blew straight to paper, which in first
## person meant your own forearm was the brightest object on screen.
const SHELL: Color = Color(0.33, 0.36, 0.41)
const PLATE: Color = Color(0.45, 0.48, 0.54)
## The default accent when a player has no colour yet. DESIGN.md's "default
## swatch bright blue".
const DEFAULT_ACCENT: Color = Color(0.32, 0.62, 1.0)
## What the seams fade toward as a process corrupts. Named rather than inline,
## because the fade and its restore have to agree about both ends.
const CORRUPT_ACCENT: Color = Color(1.0, 0.3, 0.24)
## Deliberately modest.
##
## 2.6 was chosen for the third-person read at 15 m and is completely wrong in
## first person: the same seams then sit 30 cm from the lens, where they blow
## straight through the ACES shoulder and turn your own chest into two white
## bars. Readability at distance comes from the PALE SHELL — a bright silhouette
## against near-black architecture — and the accents only have to say whose
## silhouette it is.
const ACCENT_ENERGY: float = 1.0

## Bone the breaker is socketed to.
const HAND_BONE: String = "Right wrist"
## The rifle's resting transform in that bone's space, so it sits in a closed
## fist rather than sprouting out of the wrist along the forearm. Measured in
## Blender against the same posed hand `aim_idle` holds, and carried across as a
## **quaternion on purpose**: a bone's own frame survives the glTF y-up
## conversion unchanged but the rifle's does not, so the socket rotation is not
## expressible as the axis-aligned euler it looks like it should be — and
## Godot's `Basis.from_euler` defaults to YXZ, which would silently give a third
## wrong answer.
## M4.8 re-measured these against the re-posed hold: the hands moved onto the
## weapon's ACTUAL grips (the pistol grip, and the foregrip the Surge grew in the
## same pass), so the rifle's transform in the wrist's frame moved with them.
## Printed by `tools/build_crew_avatar.py` — never hand-tuned.
##
## The AIM_ROLL change that fixed the black-silhouette first-person read moved
## these by 0.05 mm and nothing else: roll turns the wrist and the weapon
## together, so the rifle's transform *in the wrist's own frame* is invariant
## under it. Refreshed anyway, because these are transcribed numbers and a
## transcribed number that is only nearly current is how drift starts.
const HAND_OFFSET: Vector3 = Vector3(0.00457, 0.02926, -0.03751)
const HAND_ROTATION: Quaternion = Quaternion(-0.754991, -0.186312, -0.601213, 0.183897)

## Everything descended from this bone is "upper body" and takes the rifle-hold
## pose; everything below it keeps walking. Computed from the skeleton, so a
## re-export that adds a finger does not need a code change.
const SPLIT_BONE: String = "Spine"

## Chest pitch applied on top of the hold pose, in radians.
##
## The authored `aim_idle` carries the rifle 34 degrees below the view axis —
## which is a correct low-ready and, at the player's 74-degree FOV, puts the
## weapon almost entirely under the bottom edge of the screen. Rather than send
## the clip back for a re-author, the chest is pitched up a little at runtime,
## which lifts both arms and the rifle together and reads as a program bringing
## its tool up rather than as a weapon floating higher.
##
## Sign matters and is not guessable: this rotates about the avatar's own right
## axis pulled into the chest bone's parent-pose space, and positive there
## pitches the chest FORWARD. At 0.92 rad the shoulder eats a third of the
## frame; 0.34 puts the rifle in the lower-right where a held tool belongs.
const AIM_LIFT: float = 0.34

## First-person hold offset — the classic viewmodel cheat, and the reason every
## shooter you have ever played has a weapon that is anatomically in the wrong
## place.
##
## An honest two-handed low ready puts the rifle and both hands below the bottom
## edge of a 74-degree frame, because that is where a person actually holds a
## rifle they are not aiming. Games lie about this on purpose: the hold is
## translated up and toward the lens until the receiver, the foregrip and some
## knuckles ride in the lower-right of the frame, which is what makes a player
## feel they are holding something.
##
## Applied to the CHEST bone, so the arms, the hands and the weapon move as one
## piece rather than the rifle sliding out of its own grip — and applied **only
## on the owning peer**. Remote crewmates keep the honest pose, because from
## across a room the cheat would read as a program carrying its tool up by its
## chin. Same model, two truths, one of them for an audience of one.
##
## M4.7 re-anchors it. The M3.7 tuning put the receiver almost under the
## crosshair, which reads as a weapon held up at the ready — an ADS pose — and
## crowds the one part of the frame the player is actually looking at. The hold
## moves right and down until the muzzle sits around two thirds of the way across
## the frame and the bottom edge cuts through the stock, which is where a carried
## tool belongs and where every shooter since Half-Life has put one.
##
## Right is +X and up is +Y in the avatar's own frame, so this is "further out,
## and lower" — but only a little, because this bone carries the CHEST MESH. The
## outboard travel that actually moves the weapon across the frame is done at the
## shoulder instead; see FP_ARM_OFFSET.
const FP_HOLD_OFFSET: Vector3 = Vector3(0.028, 0.052, -0.030)
## The rest of the way out, applied to BOTH SHOULDERS rather than to the chest.
##
## Two things are going on here and both of them were learned the hard way.
##
## **Why not the chest.** Translating the chest far enough to put the muzzle at
## two thirds of the frame width also translates the chest plate — a large pale
## slab 30 cm from the lens — straight into view the moment the player looks
## down. The shoulders carry the arms, the hands and the rifle, and carry no
## torso geometry at all, so they can travel four times as far for free.
##
## **Why BOTH shoulders, and not just the one holding it.** `aim_idle` is a
## two-handed hold: the right hand grips the receiver (the rifle is socketed to
## `Right wrist`) and the LEFT hand is on the foregrip. Moving only the right
## shoulder moves the right arm and the weapon and leaves the left hand exactly
## where it was — a clawed hand floating in the middle of the frame holding
## nothing, which is precisely as unsettling as it sounds.
##
## Applying the SAME world-space offset to both shoulders is a rigid translation
## of the entire held-weapon assembly. The arms' relative geometry is untouched,
## so grip contact is preserved **by construction** rather than by tuning: there
## is no value of this constant that can separate a hand from the weapon, and
## none of the four states below (rest, fire, look-down, wall-tuck) can either.
##
## Bone names from the rig (dump them with src/dev/inspect_models.gd):
## Hips -> Spine -> Chest -> ChestUp -> {Left,Right} shoulder -> arm -> elbow -> wrist.
##
## **The vertical, retuned in M4.8.** M4.7 shipped this with a +5 cm lift, and
## across a milestone's worth of captures the read was consistently wrong: the
## receiver rode up under the crosshair and the barrel reached into the top
## third of the frame, which is the pose of somebody *presenting* a weapon rather
## than carrying one. Worse, it compounds — the first-person body does not pitch
## with the lens, so every time the player looks down (which is most of the time
## in a game about reading the floor) the whole assembly swings further up the
## frame from an already-high rest.
##
## The lift is now a quarter of what it was — effectively the shoulder line. At a
## level view that puts the muzzle tip just under the centre of the frame with the
## receiver low and outboard, which is where a carried tool belongs: legible, and
## not occupying the part of the frame the player is actually looking through.
##
## The number was walked in against captures rather than guessed. Two points on
## the curve, measured off a level-view frame at 1280x720: **+0.052 put the muzzle
## at 47% of frame height from the top** (above the centre line — the "presenting
## it" read), **-0.022 put it at 59%** (below centre, but the hands had left the
## bottom of the frame). Roughly 11 px of travel per centimetre.
##
## Re-tuned once more in the same milestone, and the reason is worth writing
## down: the grip surgery moved the HANDS onto the weapon's real pistol grip and
## foregrip, several centimetres lower on the model than the M3.7 pose held them.
## The whole assembly therefore dropped with them and the settled +0.012 put the
## hold under the bottom edge. This is the value that puts it back where the
## previous tuning pass left it, against a pose that is now anatomically honest.
##
## Translation only, and only on this constant: the pose, the grip, the yaw and
## the lift are all untouched, so both hands stay ON the weapon by construction
## (see the rigid-translation argument above) and every state that was tuned
## against them — rest, fire, look-down, wall-tuck — still resolves the same way.
const FP_ARM_BONES: Array[String] = ["Right shoulder", "Left shoulder"]
const FP_ARM_OFFSET: Vector3 = Vector3(0.150, 0.105, -0.010)
## Chest yaw for the first-person hold, in radians.
##
## Translating the hold outward alone leaves the barrel parallel to the view axis
## and pointing at nothing, which reads as a rifle strapped to the side of the
## camera. A couple of degrees of torso yaw cants the whole upper body so the
## muzzle angles subtly back toward the crosshair — the weapon is *aimed at where
## you are looking*, from off to one side, which is the read the classic offset
## has always depended on.
##
## Positive rotates about world up, which swings the right shoulder — and the
## rifle in its hand — outward while turning the barrel inward. Small: this is a
## whole torso, and past about 0.1 the near shoulder starts entering frame.
const FP_HOLD_YAW: float = 0.045
## Small numbers: this shifts the CHEST, and every joint from the shoulder down
## the arm multiplies it, so what reads as a 4 cm nudge at the sternum is a
## hand's width at the muzzle. The first tuning pass used 13 cm and put the
## player's own shoulder across a third of the screen.
##
## The inward cant is OFF, and it is left here documented rather than deleted
## because it is the obvious next knob and it is a trap: rolling the chest about
## its forward axis swings the near shoulder straight into the lens, and at any
## value large enough to turn the receiver's face toward the camera it also puts
## a pale slab across a third of the frame. If the weapon needs to show its side,
## rotate the socket, not the torso.
const FP_HOLD_CANT: float = 0.0
## Weapon collision, the avatar's half. See `Player._update_weapon_tuck` for the
## probe and for why NULLVOID collides the weapon instead of rendering it through
## a second camera.
##
## Applied to the same CHEST bone as the first-person hold, for the same reason:
## the arms and the rifle have to come in as one piece, or the weapon slides out
## of its own grip. Pitching the chest down by roughly three times AIM_LIFT is
## what swings the barrel under the bottom of the frame; the offset then pulls
## the whole hold back toward the sternum so the muzzle clears a wall the player
## is standing flat against.
const TUCK_PITCH: float = 0.58
const TUCK_OFFSET: Vector3 = Vector3(-0.035, -0.022, 0.095)

## Where the animation tracks live, relative to the AnimationPlayer's root.
const TRACK_PREFIX: String = "Armature/Skeleton3D"

## The two halves of the mesh. The local player hides their own head — see
## `set_first_person`.
const BODY_MESH: String = "CrewBody"
const HEAD_MESH: String = "CrewHead"

## Render layer reserved for "the local player's own body and tool".
##
## Your beam is a spotlight bolted to your head; it lights the room and it can
## never light your own chest, so a fully embodied first-person player in a game
## this dark is holding an invisible rifle in invisible hands. Every game that
## has ever shipped a viewmodel solves this with a light that only the viewmodel
## can see, and this is that light: the body and the weapon are tagged onto a
## spare render layer, and one dim omni is culled to that layer alone. It cannot
## brighten the world by a single lumen — which is the whole point, because the
## darkness is the game.
const BODY_LAYER: int = 1 << 19

var _model: Node3D = null
var _tree: AnimationTree = null
var _skeleton: Skeleton3D = null
var _neck_bone: int = -1
var _head_bone: int = -1
var _chest_bone: int = -1
## Indices of FP_ARM_BONES, resolved once. Both shoulders, always moved together.
var _arm_bones: PackedInt32Array = PackedInt32Array()
var _accent_material: StandardMaterial3D = null
## The tinted accent `repaint` built, kept because the corruption fade overwrites
## `_accent_material.emission` and has to have something true to restore.
var _accent_colour: Color = DEFAULT_ACCENT
## bone index -> the rotation the animation tree wrote this physics tick, and the
## tick it was captured on. See `_clip_rotation`.
var _clip_rotations: Dictionary = {}
var _clip_frame: int = -1
var _hand: BoneAttachment3D = null
var _eye: Node3D = null
var _body_mesh: MeshInstance3D = null
var _head_mesh: MeshInstance3D = null
var _gun: Node3D = null
var _muzzle: Node3D = null
var _has_aim: bool = false
var _first_person: bool = false
var _flash: float = 0.0
var _emitter_material: StandardMaterial3D = null
var _flash_light: OmniLight3D = null

## How long the breaker's emitter stays hot after a shot.
const FLASH_TIME: float = 0.09
## Peak energy of the light the muzzle throws into the room. See
## ViewModel.MUZZLE_FLASH_ENERGY — the two rigs hold the same weapon and it has to
## discharge the same way in both.
const MUZZLE_FLASH_ENERGY: float = 2.6

var _look: Vector2 = Vector2.ZERO
## 0..1 weapon-collision tuck, written by the owning Player once a frame.
var _tuck: float = 0.0
var _speed: float = 0.0
var _down: float = 0.0
var _was_down: bool = false
var _loaded: bool = false


static func create(colour: Color) -> CrewAvatar:
	var avatar: CrewAvatar = CrewAvatar.new()
	avatar.name = "CrewAvatar"
	avatar._build(colour)
	return avatar


## Whether the model actually loaded. The player keeps its capsule visible if
## this is false, so a missing or broken export degrades to M1's placeholder
## rather than to an invisible crewmate — which in a game this dark would be
## indistinguishable from a networking bug.
func is_loaded() -> bool:
	return _loaded


func _build(colour: Color) -> void:
	if not ResourceLoader.exists(MODEL):
		push_warning("[CrewAvatar] %s missing; falling back to the capsule shell" % MODEL)
		return
	_model = CreatureKit.instantiate(MODEL)
	if _model == null:
		return
	add_child(_model)

	repaint(colour)

	_body_mesh = _model.find_child(BODY_MESH, true, false) as MeshInstance3D
	_head_mesh = _model.find_child(HEAD_MESH, true, false) as MeshInstance3D
	_eye = _model.find_child("Eye", true, false) as Node3D

	_skeleton = CreatureKit.find_skeleton(_model)
	if _skeleton != null:
		_neck_bone = _skeleton.find_bone("Neck")
		_head_bone = _skeleton.find_bone("Head")
		_chest_bone = _skeleton.find_bone("Chest")
		# M4.9: the tail hangs and stays lively. A crewmate is a running program,
		# not a corpse — a touch more stiffness and less drag than the Sentinel, so
		# it sags heavily at rest but swings and streams as they move. Replaces the
		# baked TAIL_ARC keys the build tool used to sway it with.
		CreatureKit.build_spring_tail(_skeleton, 30.0, 1.0)
		for arm_name: String in FP_ARM_BONES:
			var found: int = _skeleton.find_bone(arm_name)
			if found >= 0:
				_arm_bones.append(found)
			else:
				push_warning("[CrewAvatar] no '%s' bone; the first-person hold "
						% arm_name + "will be lopsided")
		var hand: int = _skeleton.find_bone(HAND_BONE)
		if hand >= 0:
			_hand = BoneAttachment3D.new()
			_hand.name = "HandSocket"
			_skeleton.add_child(_hand)
			_hand.bone_idx = hand

	var player: AnimationPlayer = CreatureKit.find_player(_model)
	CreatureKit.set_looping(player, PackedStringArray(["idle", "walk", "run"]))
	var clips: Dictionary = {}
	for pair: Array in [["idle", "idle"], ["walk", "walk"], ["run", "run"],
			["kneel", "kneel"], ["rise", "rise"]]:
		if player != null and player.has_animation(String(pair[1])):
			clips[String(pair[0])] = String(pair[1])
	if clips.is_empty():
		push_warning("[CrewAvatar] %s carries no usable clips" % MODEL)
		return
	if not clips.has("idle"):
		# Whatever else is missing, the tree needs a resting state to start in.
		clips["idle"] = clips.values()[0]
	_tree = CreatureKit.build_tree(self, player, clips, "idle", 0.2)
	# The rifle hold, laid over the locomotion from the spine up. Without it a
	# walking crewmate swings both arms while apparently carrying a rifle in one
	# of them, which is the single most obvious tell that the weapon is a prop
	# stapled to a hand rather than something the character is holding.
	if player != null and player.has_animation("aim_idle"):
		_has_aim = CreatureKit.add_upper_body(_tree, _skeleton, "aim_idle",
				SPLIT_BONE, TRACK_PREFIX)
		CreatureKit.set_upper_body(_tree, 1.0 if _has_aim else 0.0)

	# Last, not the moment the .glb instantiated. `is_loaded()` is what makes
	# Player hide its capsule, so latching it before the clips are validated meant
	# a re-export that renamed them yielded a frozen T-posed body holding nothing
	# — with the placeholder shell the docstring above promises never deploying.
	_loaded = true


## The crew accent — the player's chosen shell-marker colour, used as ONE token
## across their whole identity (M4.9): the UI phosphor, the body seams (Emiss/Eyes),
## the shell rim, and the gel's internal glow all read this. Blue (DEFAULT_ACCENT)
## is ONLY the default swatch, for a program that has not picked a colour yet — it
## is no longer blended into a chosen colour. Routed through UiFx.clamp_phosphor,
## the same clamp the UI uses, so a crew colour can never fall in the reserved
## quarantine-red band the Sentinel owns: red stays faction-locked to the enemy,
## and four crewmates stay four distinguishable colours in the dark.
static func crew_accent(colour: Color) -> Color:
	if colour.get_luminance() <= 0.001:
		return DEFAULT_ACCENT
	return UiFx.clamp_phosphor(colour)


## The inverted palette, tinted per player. Called again if the owner's lobby
## colour changes.
func repaint(colour: Color) -> void:
	if _model == null:
		return
	var accent: Color = crew_accent(colour)
	# Cached, because the corruption fade lerps *from* it and has to be able to
	# put it back. It used to lerp from the untinted DEFAULT_ACCENT and restore
	# nothing (the `_down == 0` branch was a self-assignment), so the first time a
	# red-shelled crewmate went down and was restored, their seams came back
	# generic blue for the rest of the run — and colour is how you tell crew apart
	# in the dark, which is also how you tell crew from quarantine processes.
	_accent_colour = accent
	_accent_material = CreatureKit.emissive(accent, ACCENT_ENERGY, 0.55)
	var shell: StandardMaterial3D = CreatureKit.matte(SHELL, 0.15, 0.46)
	var plate: StandardMaterial3D = CreatureKit.matte(PLATE, 0.3, 0.32)
	# M4.9 materials: the Slime shell is dark glass with the pale interior Bone
	# reading through it, and the internal glow is the player's accent — the same
	# one token as the seams and the UI phosphor, so a crewmate glows their own
	# chosen colour from inside their shell as well as along their seams.
	var palette: Dictionary = {
		"LightMetal": plate,
		"Armour": shell,
		"Bone": CreatureKit.bone_material(),
		"Mask": shell,
		"Slime": CreatureKit.gel_material(accent, 1.2, 0.2),
		"Emiss": _accent_material,
		"Eyes": _accent_material,
	}
	# Two meshes now (body and head, split so a first-person player can hide
	# their own skull without hiding their hands), so the palette goes on both.
	for name: String in [BODY_MESH, HEAD_MESH]:
		CreatureKit.paint(_model.find_child(name, true, false) as MeshInstance3D, palette)


## Hangs the breaker off the right hand, so a crewmate across the room is
## visibly carrying the same tool you are.
func socket_breaker(colour: Color) -> void:
	if _hand == null or not is_instance_valid(_hand):
		return
	var gun: Node3D = CreatureKit.instantiate(CreatureKit.SURGE)
	if gun == null:
		return
	gun.name = "Surge"
	# The hand bone points down the forearm; the grip origin is at the model's
	# root, so the weapon needs a quarter turn to sit in a fist rather than
	# sprouting out of the wrist along the bone.
	gun.transform = Transform3D(Basis(HAND_ROTATION), HAND_OFFSET)
	var accent: Color = Color(0.22, 0.86, 1.0).lerp(colour, 0.35)
	_emitter_material = CreatureKit.emissive(accent, 1.1, 0.82)
	CreatureKit.paint(CreatureKit.find_mesh(gun), {
		"Base": CreatureKit.matte(Color(0.048, 0.05, 0.058), 0.25, 0.44),
		"Emiss": _emitter_material,
		"Material.001": CreatureKit.matte(Color(0.03, 0.045, 0.055), 0.9, 0.12),
	})
	_hand.add_child(gun)
	_gun = gun
	if _first_person:
		_tag_body_layer(gun)
	_muzzle = gun.find_child("Muzzle", true, false) as Node3D

	_flash_light = OmniLight3D.new()
	_flash_light.name = "MuzzleFlash"
	_flash_light.light_color = accent
	_flash_light.light_energy = 0.0
	# Attenuation, not energy, is what was blowing the frame out.
	#
	# Godot's omni falloff is pow(distance, -attenuation), and this light lives
	# INSIDE the hand holding it — roughly 0.1 m from the mesh it is brightest
	# against. At the M3.7 attenuation of 1.3 that is a x20 near-field multiplier,
	# so a 3-energy flash delivered ~60 to the player's own knuckles, blew them to
	# paper, and the glow pass then spread that across the whole frame: firing in
	# a dark corridor whited out the corridor. A gentle 0.6 decay costs nothing at
	# range (a longer reach buys it back) and keeps the near field survivable.
	_flash_light.omni_range = 9.0
	_flash_light.omni_attenuation = 0.6
	_flash_light.light_volumetric_fog_energy = 2.6
	# Casting, so a crewmate firing across a room throws your silhouette up the
	# wall for a frame. Free the rest of the time: at zero energy Godot skips the
	# shadow atlas update entirely.
	_flash_light.shadow_enabled = true
	_flash_light.shadow_bias = 0.06
	(_muzzle if _muzzle != null else gun).add_child(_flash_light)


## Everything the avatar needs, once a frame, on every peer.
##
##   `speed`    the owner's replicated planar speed
##   `heading`  world direction of travel, for the head-look; zero when still
##   `down`     0..1 corruption collapse, already eased by the player
func drive(delta: float, speed: float, heading: Vector3, down: float) -> void:
	_speed = lerpf(_speed, speed, 1.0 - exp(-9.0 * delta))
	_down = down
	_choose_clip()
	_track_head(delta, heading)

	_flash = maxf(_flash - delta, 0.0)
	var heat: float = _flash / FLASH_TIME
	if _emitter_material != null:
		# Peak dropped from 10.1 in M3.7. An emitter that far above the glow HDR
		# threshold, 40 cm from the lens, bloomed across the entire frame — a shot
		# fired in a dark corridor whited out the room it was supposed to light.
		_emitter_material.emission_energy_multiplier = 1.1 + heat * 2.8
	if _flash_light != null:
		# Squared, so the decay reads as a discharge rather than as a dimmer.
		_flash_light.light_energy = heat * heat * MUZZLE_FLASH_ENERGY
	if _accent_material != null:
		# The seams go out as the process comes apart. A downed crewmate must not
		# still be wearing their colour, or the crew cannot read the room — and a
		# *restored* one must get it back, which is why this lerps from their own
		# tinted accent and writes it unconditionally rather than self-assigning at
		# zero. At `_down == 0` the first term is exactly `_accent_colour`.
		_accent_material.emission = _accent_colour.lerp(CORRUPT_ACCENT, _down)
		_accent_material.emission_energy_multiplier = lerpf(ACCENT_ENERGY, 0.4, _down)


func _choose_clip() -> void:
	if _tree == null:
		return
	var kneeling: bool = _down > 0.5
	if kneeling != _was_down:
		_was_down = kneeling
		CreatureKit.travel(_tree, "kneel" if kneeling else "rise")
		CreatureKit.set_speed(_tree, 1.0)
		return
	if kneeling:
		return

	if _speed >= RUN_SPEED:
		CreatureKit.travel(_tree, "run")
		CreatureKit.set_speed(_tree, clampf(_speed / RUN_SPEED_AUTHORED,
				RATE_RANGE.x, RATE_RANGE.y))
	elif _speed > IDLE_SPEED:
		CreatureKit.travel(_tree, "walk")
		CreatureKit.set_speed(_tree, clampf(_speed / WALK_SPEED_AUTHORED,
				RATE_RANGE.x, RATE_RANGE.y))
	else:
		CreatureKit.travel(_tree, "idle")
		CreatureKit.set_speed(_tree, 1.0)


## Subtle head-look toward where the avatar is going. Layered on top of whatever
## the clip is doing rather than replacing it, so a walking crewmate leads the
## turn with their head the way a person does.
func _track_head(delta: float, heading: Vector3) -> void:
	if _skeleton == null or not is_instance_valid(_skeleton):
		return
	if _tree == null:
		# Nothing is writing the pose each frame, so an additive override would
		# compound on itself and the head would spin off. Leave it at rest.
		return
	var want: Vector2 = Vector2.ZERO
	if heading.length_squared() > 0.04 and _down < 0.5:
		var local: Vector3 = global_transform.basis.inverse() * heading.normalized()
		want = Vector2(
				clampf(atan2(-local.x, -local.z), -LOOK_YAW_LIMIT, LOOK_YAW_LIMIT),
				clampf(atan2(local.y, Vector2(local.x, local.z).length()),
						-LOOK_PITCH_LIMIT, LOOK_PITCH_LIMIT))
	_look = _look.lerp(want, 1.0 - exp(-5.0 * delta))
	# Chest first: the lift has to land before the neck and head are posed
	# relative to it, or the head-look fights the lean.
	if _has_aim and _down < 0.5:
		# The tuck cancels the first-person lift and then keeps going, so a player
		# pressed against a wall ends up below the honest low ready rather than
		# merely back at it.
		_aim_bone(_chest_bone, Vector2(
					FP_HOLD_YAW if _first_person else 0.0,
					-AIM_LIFT + TUCK_PITCH * _tuck),
				FP_HOLD_CANT if _first_person else 0.0)
		if _first_person:
			_shift_bone(_chest_bone, FP_HOLD_OFFSET + TUCK_OFFSET * _tuck)
			# The arms take the outboard travel — both of them, by the same
			# vector, so the two-handed grip travels as one rigid piece. They
			# give it back as the weapon tucks: a hold being pulled in to clear a
			# wall should come toward the body, not stay swung out beside it.
			var reach: Vector3 = FP_ARM_OFFSET * (1.0 - _tuck * 0.55)
			# The VERTICAL component is not "reach" and is not given back.
			#
			# Scaling it with the tuck moves the hold UP as the player presses into
			# a wall — the exact opposite of what TUCK_PITCH and TUCK_OFFSET are
			# doing on the line above, and a fight that only got noticeable once
			# M4.8 dropped the rest height and left the two effects the same size.
			# Only the outboard and forward travel comes back in.
			reach.y = FP_ARM_OFFSET.y
			for arm: int in _arm_bones:
				_shift_bone(arm, reach)
	_aim_bone(_neck_bone, _look * NECK_SHARE)
	_aim_bone(_head_bone, _look * (1.0 - NECK_SHARE))


## The basis a bone's pose is expressed in: its parent's pose, in world terms.
func _parent_basis(bone: int) -> Basis:
	var parent: int = _skeleton.get_bone_parent(bone)
	var basis: Basis = _skeleton.global_transform.basis
	if parent >= 0:
		basis = basis * _skeleton.get_bone_global_pose(parent).basis
	return basis


## Translates a bone by a world-space offset, expressed in the avatar's own
## frame. Used only for the first-person hold cheat above.
##
## Based on the bone's REST position, never on its current pose — because this
## runs from `_process` and the pose is only reset once per *physics* tick, so
## reading the live pose and adding to it compounds `fps/60` times per reset and
## the avatar's own torso becomes an exploded diagram filling the screen. (Ask
## how I know.)
##
## The cost is real and worth naming: every locomotion clip in `crew_avatar.glb`
## DOES carry a translation channel on `Chest` and on both shoulders — an earlier
## version of this comment claimed otherwise — so writing the position absolutely
## discards the authored shoulder bob. Only the local player pays it, and only in
## first person, where the bob is a hold that will not sit still.
func _shift_bone(bone: int, offset: Vector3) -> void:
	if bone < 0:
		return
	var world: Vector3 = global_transform.basis * offset
	_skeleton.set_bone_pose_position(bone,
			_skeleton.get_bone_rest(bone).origin + _parent_basis(bone).inverse() * world)


## Rotates a bone about the world up and the avatar's own right axis, pulled back
## into the bone's parent-pose space. Bone rests in an imported rig point
## wherever the artist left them, so rotating about a bone's own local axes gives
## a different, wrong answer for every rig.
func _aim_bone(bone: int, angles: Vector2, roll: float = 0.0) -> void:
	if bone < 0:
		return
	var inverse: Basis = _parent_basis(bone).inverse()
	var up: Vector3 = (inverse * Vector3.UP).normalized()
	var right: Vector3 = (inverse * global_transform.basis.x).normalized()
	var delta: Quaternion = Quaternion(up, angles.x) * Quaternion(right, -angles.y)
	if absf(roll) > 0.001:
		var forward: Vector3 = (inverse * -global_transform.basis.z).normalized()
		delta = delta * Quaternion(forward, roll)
	# Composed onto the CLIP's pose, not onto the live one.
	#
	# The tree writes the pose once per *physics* tick — `CreatureKit.build_tree`
	# pins the mixer to ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS, with its own
	# comment explaining why — while `drive()` is called from `Player._process`,
	# once per *rendered* frame. Multiplying onto the live pose therefore applied
	# the delta `fps/60` times per reset: on a 144 Hz display AIM_LIFT's 0.34 rad
	# landed as ~0.82 and FP_HOLD_YAW's 0.045 as 0.108, past the 0.1 this file's
	# own comment warns about — and because the ratio is not an integer it also
	# jittered frame to frame. At exactly 60 Hz it was correct, which is why it
	# survived review: the bug only appeared on hardware other than the
	# developer's.
	_skeleton.set_bone_pose_rotation(bone, delta * _clip_rotation(bone))


## The rotation the animation tree last wrote for `bone`, cached for the rest of
## the physics tick. Physics runs before idle within a frame, so the first read
## after a tick boundary is the tree's own clean pose; every rendered frame in
## between reuses it rather than reading back the override we just applied.
func _clip_rotation(bone: int) -> Quaternion:
	var frame: int = Engine.get_physics_frames()
	if frame != _clip_frame:
		_clip_frame = frame
		_clip_rotations.clear()
	if not _clip_rotations.has(bone):
		_clip_rotations[bone] = _skeleton.get_bone_pose_rotation(bone)
	return _clip_rotations[bone]


## Weapon collision, 0 = clear, 1 = pressed against a wall. Written by the owning
## Player every frame; only the first-person copy does anything with it.
func set_tuck(amount: float) -> void:
	_tuck = clampf(amount, 0.0, 1.0)


## One shot fired: light the emitter on the socketed rifle. Cosmetic and local —
## remote copies get their flash from `Player.show_breaker_shot`.
func fire() -> void:
	_flash = FLASH_TIME


## Where the first-person lens belongs: the eye node the exporter parked between
## the eye bones. Null until the model is loaded.
func eye() -> Node3D:
	return _eye


## World position of the breaker's emitter, so the beam-lash leaves the rifle the
## avatar is actually holding rather than a point near the camera.
func muzzle_point() -> Vector3:
	if _muzzle != null and is_instance_valid(_muzzle):
		return _muzzle.global_position
	if _gun != null and is_instance_valid(_gun):
		return _gun.global_position
	return global_position


## Turns this avatar into the local player's own body.
##
## The head goes SHADOWS_ONLY and everything else stays visible. That is the
## whole trick: the lens sits inside the skull, so rendering the skull would fill
## the frame with the inside of a jaw — but the chest, arms, hands and legs are
## exactly what the player should see when they look down, and the head still
## throws a silhouette when a crewmate's beam sweeps past.
##
## M1 solved the same problem for the capsule shell the same way; this is that
## trick applied to a mesh that has a face.
func set_first_person() -> void:
	_first_person = true
	if _head_mesh != null:
		_head_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	# The body stays fully rendered. Looking down and seeing your own chest and
	# hands is the entire point of the exercise.
	if _body_mesh != null:
		_body_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_body_mesh.layers |= BODY_LAYER
	_tag_body_layer(_gun)

	# The body light. Mounted at the sternum, aimed at nothing, culled to the
	# body layer so the room never sees it.
	var lamp: OmniLight3D = OmniLight3D.new()
	lamp.name = "BodyLight"
	lamp.position = Vector3(0.0, 1.35, -0.14)
	lamp.light_color = Color(0.78, 0.85, 1.0)
	# Feeble on purpose: it exists so your hands are not a silhouette, not so you
	# can read by them.
	lamp.light_energy = 0.7
	lamp.omni_range = 1.5
	lamp.omni_attenuation = 1.2
	lamp.light_specular = 0.5
	lamp.shadow_enabled = false
	lamp.light_volumetric_fog_energy = 0.0
	lamp.light_cull_mask = BODY_LAYER
	add_child(lamp)


## Adds every mesh under `root` to the own-body render layer.
func _tag_body_layer(root: Node) -> void:
	if root == null:
		return
	var mesh: GeometryInstance3D = root as GeometryInstance3D
	if mesh != null:
		mesh.layers |= BODY_LAYER
	for child: Node in root.get_children():
		_tag_body_layer(child)
