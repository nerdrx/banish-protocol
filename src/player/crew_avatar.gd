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
##
## PT4 re-authored the LEFT hand onto the handguard (see `FOREGRIP_LOCAL` in the
## build tool) and moved these by 0.04 mm — same invariance, same reason: the
## right hand and the weapon are one rigid piece and the left hand is not part
## of the socket. Transcribed again anyway, same doctrine.
const HAND_OFFSET: Vector3 = Vector3(0.00461, 0.02928, -0.03747)
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
## PT1 drops the vertical by 2 cm, 0.105 -> 0.085. Two reports arrived together
## off the same frames — "the gun doesn't move with the camera" and "it reads as
## pointing above the reticle" — and the second had a third, quieter half: the
## hold sat a touch high in the frame. The convergence below does most of that
## work (it takes the emitter 21 cm down), and this is the remainder: enough that
## the receiver stops crowding the centre, small enough that the knuckles stay
## on the bottom edge where M4.8 walked them to.
const FP_ARM_OFFSET: Vector3 = Vector3(0.150, 0.085, -0.010)
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
## PT1 — the first-person hold PITCHES WITH THE LENS.
##
## The top complaint out of the first friend playtest was "the gun doesn't
## properly move with the camera", and every scripted capture in this repo had
## said the hold was fine, because no scripted capture had ever moved a mouse
## vertically. `--gunlog` (Debug) measured it in a live session and the answer was
## not subtle. The GRIP, in the lens's own frame, metres, as the player looks
## around (a hold bolted to the lens holds all three numbers still):
##
##   lens pitch  -1.45 (full down)  ->  (0.27, +0.16, -0.20)
##   lens pitch   0.00 (level)      ->  (0.27, -0.27, -0.21)
##   lens pitch  +0.70              ->  (0.27, -0.44, +0.06)   BEHIND the lens
##
## Six hundred millimetres of travel, on a weapon held two hundred from the eye.
##
## The cause is structural. Yaw is free — the avatar is a child of the Player and
## `rotate_y` in `_unhandled_input` turns them both on the same frame — but PITCH
## lives on the `Head` node, which carries the camera and nothing else. The body
## never pitched at all. Look up and the weapon sinks out of the bottom of the
## world; look down and your own torso swings across the frame. A player reads
## that, correctly, as a gun that is not attached to their view.
##
## The fix is the one every shooter uses, adapted to a rig where the arms are
## real bones on a real body: the hold is **rigidly rotated about the lens** by
## the lens's own pitch. Rotating a rigid body about a point is a rotation plus a
## translation, and both are applied to the two SHOULDER bones — the same two
## bones the outboard cheat already moves, for the same reason (they carry the
## arms, the hands and the rifle, and no torso geometry at all). Everything below
## them follows for free, so the two-handed grip survives by construction.
##
## `_hold_pitch` reads the live lens angle, written from `Player._process` on the
## same frame the mouse moved it — never from the replicated pose, which is a
## physics tick old and would reintroduce exactly the lag this is fixing.
##
## **One rotation, at one joint, and that is not a style choice.** Two obvious
## refinements were built, measured and thrown away, and both failed the same way:
##
##   * splitting the pitch so the CHEST folds a quarter of it (a person looking at
##     their own boots does bend) — but the chest folds about the sternum, not
##     about the lens, so a quarter of the rotation escapes the compensation. The
##     grip drifted 8 cm vertically and 21 cm in depth across the pitch range, and
##     at a full look-up it ended 8 cm from the near plane and clipped away.
##   * easing the follow off toward the pitch limits, to spare the shoulder seam —
##     which reintroduces exactly the sliding the complaint is about, in the
##     situation (looking at the floor, looking at the ceiling) where a player is
##     most likely to be checking whether their weapon is still there.
##
## With the whole rotation at the compensated joint the hold is EXACT: measured
## across the full ±1.45 rad of lens travel, the grip and the emitter each move
## less than one millimetre. That is the number this constant is 1.0 for.
##
## PT4 SUPERSEDES THE MECHANISM AND KEEPS THE LAW. The hold no longer follows the
## lens's PITCH; it is placed in the lens's whole TRANSFORM, every frame, by
## `_pitch_hold`. Head pitch was never the only thing between the eye and the
## world — `Player._update_view` also writes a bob, a landing dip, a breathing
## sway and a hit shake onto `camera`, in translation AND in rotation, including
## ROLL — and a hold that compensated for one term of that and not the other four
## is a hold that slides whenever the player is doing anything. The constant stays
## at 1.0 and stays documented because the law it encodes ("all of it, at one
## joint, no easing") is what PT4 kept; the arithmetic moved to the lens basis.
const FP_PITCH_FOLLOW: float = 1.0

## AIM CONVERGENCE — solved against the live geometry, every frame, forever.
##
## ## What three rounds of this complaint got wrong
##
## "The gun reads as pointing ABOVE the reticle" (PT1), "still looks crooked"
## (PT2), and then, from a real session at 3440x1440: "GUN STILL DOESNT POINT
## TOWARDS THE RETICLE" (PT4). Each round measured clean and each round shipped a
## CONSTANT: a closed-form yaw/pitch pair solved once, at a level view, against
## one frame of one pose.
##
## The standing hypothesis going into PT4 was ultrawide — every constant solved
## against the 16:9 design camera, the game is hor+, therefore a baked
## convergence must point somewhere else at 21:9. **It is wrong.** `--aimtrace`
## (Debug), same scene, same frame count, three windows:
##
##   1280x720   mean miss at 12 m   46.5 cm
##   3440x1440  mean miss at 12 m   45.1 cm
##   5120x1440  mean miss at 12 m   46.6 cm
##
## Aspect changes nothing and it cannot. The reticle is the lens's own forward
## ray; a convergence puts the barrel line through a point ON that ray; and a 3D
## line through a point projects to a 2D line through that point's projection at
## every field of view and every aspect there is. Field of view does not enter
## either, which is why there is no `fov` anywhere below and why a future FOV
## slider needs no hook here. Anything in this file that claimed to solve
## convergence "for the aspect" would be solving a problem that does not exist.
##
## ## What is actually wrong
##
## The same instrument, standing perfectly still at a level view, sampled over
## two seconds instead of photographed once:
##
##   miss at 12 m   min 27.7 cm   mean 96.5 cm   max 127.4 cm
##   roll                                         -2.6 deg .. +5.7 deg
##
## **The miss is not a number, it is a cycle**, and it goes round once per loop
## of the `aim_idle` clip. Every pose this file writes is composed ONTO the clip
## (`_clip_rotation`, and it has to be, or the walk stops walking) — so the
## clip's own motion on the chest and the shoulders travels down the arm, through
## the wrist, and comes out of the muzzle multiplied by half a metre of barrel.
## A constant cannot cancel a moving thing. The three previous rounds each solved
## for one phase of that cycle, verified at that phase, and shipped; a player,
## who sees all of it, correctly reported the gun does not point at the reticle.
##
## `Player`'s own lens is the second half. Bob, dip, breath and shake are written
## onto `camera` on top of the head's pitch, and the hold compensated for the
## pitch alone — so the barrel also drifted off the reticle whenever the player
## walked, landed, or got hit.
##
## ## The fix
##
## Both halves are the same mistake — a constant standing in for something live —
## so they get the same fix. Nothing is baked. Every frame, `_pitch_hold`:
##
##   1. MEASURES the weapon where the animation actually left it this frame: the
##      grip and the emitter, derived from the wrist bone rather than read off
##      the socket node (which is one frame stale — see `_follow_hand`).
##   2. Reads the LIVE LENS — `Player` hands over the camera's full transform in
##      the avatar's frame, not a pitch angle — and puts the aim point at
##      `CONVERGE_DISTANCE` down its forward axis.
##   3. Solves the one rotation about the grip that takes the measured barrel
##      onto that point, and the one roll about the result that levels the weapon
##      to the lens's own horizon. Both in closed form, no iteration, no solver.
##
## The barrel is then on the reticle BY CONSTRUCTION rather than by tuning: at
## any pitch, at any aspect, at any field of view, at any phase of any clip, and
## at whatever the animation does next month. The residual is floating point.
##
## The distance is a choice, not a measurement. Converge too near and the barrel
## visibly crosses the sight line and points inboard of the reticle at range;
## too far and it never quite arrives. Twelve metres is past the breaker's own
## eight-metre reach and inside the range anything is legible at in this dark, so
## the barrel is on the crosshair everywhere a shot can actually land.
const CONVERGE_DISTANCE: float = 12.0

## Where the grip sits in the LENS's own frame, in metres. Right, up, forward.
##
## The hold is rigid in this frame — that is what every round of "the gun doesn't
## move with the camera" has been asking for, and PT4 is the first version that
## delivers it against the whole lens rather than against its pitch.
##
## Measured, not chosen: this is the mean of the settled grip over a full loop of
## the idle clip on the build this replaced, so the weapon sits exactly where four
## milestones of framing tuning left it and the fix changes where the gun POINTS
## without changing where it SITS. `FP_ARM_OFFSET` and `FP_HOLD_OFFSET` still pose
## the arms and still decide what the elbow does; they no longer decide where the
## hold ends up, because a chain of five bone offsets deciding that was how the
## grip quietly moved 8 cm between milestones and nobody noticed.
const HOLD_LENS_OFFSET: Vector3 = Vector3(0.233, -0.167, -0.108)

## Sway — the whisper of weight, and NEVER the aim.
##
## The distinction is the whole lesson of this file, and PT4 sharpened it. PT1
## made the sway a ROTATION of the hold: 0.055 rad of yaw lean, which is 3.2
## degrees, which is **66 cm at the convergence distance**. So the one part of
## the hold that was deliberately allowed to move was, on its own, thirteen times
## the error budget this milestone is held to — and it moved exactly when a live
## player was turning, which is exactly when they were looking at it. Every
## scripted capture missed it because no scripted capture had ever swung a mouse.
##
## Sway is now expressed only in the two channels that CANNOT take the barrel off
## the reticle:
##
##   * a TRANSLATION of the grip in the lens's frame. The aim is re-solved from
##     wherever the grip ends up, so a hold that has leaned 4 cm into a turn is
##     still pointing at the crosshair — it is just pointing at it from slightly
##     to one side, which is what a carried weapon does.
##   * a ROLL about the barrel's own axis, which by definition moves no point on
##     that axis at all. It is free, so it is where most of the character went.
##
## Metres and radians. Bigger than the numbers they replace, and the hold reads
## as heavier rather than looser, because none of it is error any more.
const HOLD_SWAY_LAG: float = 16.0
const HOLD_SWAY_SHIFT: Vector2 = Vector2(0.038, 0.030)
const HOLD_SWAY_ROLL: float = 0.075
## Angular rate, in rad/s, at which the sway offset saturates. A brisk turn is
## ~3 rad/s; a flick is ten times that, and past saturation extra speed must not
## buy extra lean or a fast player's weapon swings out of frame.
const HOLD_SWAY_SATURATION: float = 7.0

## How much of the lens's walk bob the weapon is allowed to LAG behind.
##
## A hold that is rigid in the lens's frame does not bob, because the lens is
## bobbing under it and they move together — which is correct, and dead. This
## puts a fraction of the bob back as a counter-translation, so the weapon rides
## the walk cycle visibly while staying exactly on the reticle (see the sway note
## above: a translation cannot take the barrel off the crosshair). Zero is a
## weapon welded to the eye; one is a weapon that ignores the walk entirely.
const HOLD_BOB_LAG: float = 0.55

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

## PT4: AND the same two moves again, in the LENS's frame.
##
## This is the one thing the per-frame placement broke and had to be given back
## deliberately, and it is worth naming loudly because the failure mode is
## dangerous: the hold is now placed at `HOLD_LENS_OFFSET` outright, so a tuck
## expressed ONLY as a chest pose gets silently cancelled by the very next line
## and the weapon goes back to clipping straight through the wall the probe
## just found. The chest pair above still runs — it is what makes the TORSO hunch,
## which is most of what the tuck reads as — and these two are what actually move
## the weapon now.
##
## Metres and radians in the lens's own axes: in toward the body, down, and back
## toward the eye; then the aim itself drops, because a weapon brought in to
## clear a wall points at the floor in front of it and not at the crosshair. That
## last one is the single deliberate exception to this file's convergence law,
## and it is deliberate: at full tuck the player is not aiming.
const TUCK_LENS_SHIFT: Vector3 = Vector3(-0.055, -0.085, 0.110)
const TUCK_LENS_AIM: float = 0.58

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
## The weapon socket. A plain Node3D driven by `_follow_hand`, NOT a
## BoneAttachment3D — see that function for the bug that cost this milestone an
## afternoon.
var _hand: Node3D = null
var _hand_bone: int = -1
var _eye: Node3D = null
var _body_mesh: MeshInstance3D = null
var _head_mesh: MeshInstance3D = null
var _gun: Node3D = null
var _muzzle: Node3D = null
var _has_aim: bool = false
var _first_person: bool = false
var _flash: float = 0.0
## Flash-rate governor state (see MUZZLE_FLASH_MIN_INTERVAL). `_since_full_flash`
## counts up in `drive`; `_room_gate` is 1 for a shot allowed a full room flash,
## 0 for one the rate cap suppressed. Starts large so the first shot flashes.
var _since_full_flash: float = 10.0
var _room_gate: float = 0.0
var _emitter_material: StandardMaterial3D = null
var _flash_light: OmniLight3D = null

## How long the breaker's emitter stays hot after a shot.
const FLASH_TIME: float = 0.09
## Peak energy of the light the muzzle throws into the room. See
## ViewModel.MUZZLE_FLASH_ENERGY — the two rigs hold the same weapon and it has to
## discharge the same way in both.
const MUZZLE_FLASH_ENERGY: float = 2.6
## SAFETY-CRITICAL (limbo-a11y 01-photosensitivity): the muzzle flash's rate cap.
## See ViewModel.MUZZLE_FLASH_MIN_INTERVAL — the two rigs discharge the same way,
## so they share the same governor. >1/3 s between full room flashes keeps a held
## trigger under the WCAG 2.3.1 three-flashes-a-second ceiling, unconditionally,
## and this copy protects the third-person view of a crewmate firing at you too.
const MUZZLE_FLASH_MIN_INTERVAL: float = 0.34

var _look: Vector2 = Vector2.ZERO
## PT1/PT4. The live LENS, in the avatar's own frame, written by the owning
## Player every rendered frame — see `set_lens`. The hold is placed in this frame
## outright, which is what makes it track.
##
## `_lens_pitch` survives only as the sway's input; the placement uses the basis,
## because head pitch is one of five things `Player._update_view` puts between the
## eye and the world and a hold that follows one of them slides under the other
## four.
var _hold_pitch: float = 0.0
var _lens_local: Vector3 = Vector3(0.0, 1.62, -0.16)
var _lens_basis: Basis = Basis.IDENTITY
## The walk bob the lens is currently carrying, in the lens's frame, so the hold
## can lag a fraction of it back. See HOLD_BOB_LAG.
var _lens_bob: Vector3 = Vector3.ZERO
## Additive hold sway, chasing the lens's angular rate. See HOLD_SWAY_LAG.
var _hold_sway: Vector2 = Vector2.ZERO
var _last_hold_look: Vector2 = Vector2.ZERO
var _pending_look: Vector2 = Vector2.ZERO
var _has_hold_look: bool = false
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
		_hand_bone = _skeleton.find_bone(HAND_BONE)
		if _hand_bone >= 0:
			_hand = Node3D.new()
			_hand.name = "HandSocket"
			_skeleton.add_child(_hand)

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
	_advance_hold_sway(delta)
	_choose_clip()
	_track_head(delta, heading)
	_follow_hand()

	_since_full_flash += delta
	_flash = maxf(_flash - delta, 0.0)
	var heat: float = _flash / FLASH_TIME
	if _emitter_material != null:
		# Peak dropped from 10.1 in M3.7. An emitter that far above the glow HDR
		# threshold, 40 cm from the lens, bloomed across the entire frame — a shot
		# fired in a dark corridor whited out the room it was supposed to light.
		_emitter_material.emission_energy_multiplier = 1.1 + heat * 2.8
	if _flash_light != null:
		# Squared, so the decay reads as a discharge rather than as a dimmer. Gated
		# by the flash-rate governor (`_room_gate`) and scaled by A11y.flash_scale —
		# SAFETY-CRITICAL, see MUZZLE_FLASH_MIN_INTERVAL.
		_flash_light.light_energy = heat * heat * MUZZLE_FLASH_ENERGY \
				* _room_gate * A11y.flash_scale
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
			_pitch_hold(reach)
	_aim_bone(_neck_bone, _look * NECK_SHARE)
	_aim_bone(_head_bone, _look * (1.0 - NECK_SHARE))


## Places the held-weapon assembly: measured where the animation left it, then
## moved bodily onto the lens and turned until the barrel is on the crosshair.
## `reach` is the outboard cheat this hold already had.
##
## ONE rigid transform, solved this frame, landing on the two shoulder bones —
## because moving a rigid body about a point that is not its own origin is a
## rotation plus a translation, and the shoulders are where this file is allowed
## to apply both (they carry the arms, the hands and the rifle, and no torso
## geometry). Everything below them follows for free, so the two-handed grip and
## every wrist angle survive by construction: nothing here poses a wrist.
##
## The map every point X of the assembly goes through is
##
##     X  ->  want_grip + R * (X - grip)
##
## with `grip` measured this frame and `want_grip` read off the live lens. Feed
## it the grip and you get `want_grip`; feed it the emitter and you get a point
## on the sight line — which is the whole claim of this function, and it is an
## identity rather than a tuning.
##
## ## Why it is solved and not baked
##
## See the CONVERGENCE note above. Briefly: the pose this rotation corrects is
## written by an animation clip, so it MOVES, and three milestones of constants
## each cancelled one phase of that movement and left a 1.3 metre cycle in the
## other phases.
##
## ## Order
##
## The swing is solved against the wanted grip, not the measured one, so the
## translation is folded in before the aim rather than after it. Solving the
## other way round and then translating would slide the barrel off the point it
## had just been aimed at, by the full lever arm of the offset — which is the
## same class of mistake as converging outside the lens rotation, and it is worth
## naming because the code reads almost identically either way.
##
## The shoulder's starting position is read back out of the skeleton rather than
## derived from the rest pose, because the base pose is not the rest pose: the
## chest carries the aim lift, the first-person yaw and the wall tuck, and every
## one of those has already moved the shoulder before we get here. Reading the
## answer is both shorter and immune to the next thing that poses the chest.
func _pitch_hold(reach: Vector3) -> void:
	if _arm_bones.is_empty():
		return
	var to_local: Transform3D = global_transform.affine_inverse() \
			* _skeleton.global_transform

	# The base pose, on BOTH arms, BEFORE anything is measured — so every number
	# below describes the pose this function is actually correcting. (The version
	# this replaces measured the grip before applying the reach and then pivoted
	# the convergence about a point 17 cm from the hand it meant to pivot about.)
	#
	# ## The rotation reset is not tidiness. It is the whole frame-rate story.
	#
	# This function SOLVES its rotation from the pose it measures, and then writes
	# that solution as `total * clip` — so the thing it measures had better be the
	# CLIP, or it is correcting one pose and composing onto another.
	#
	# The AnimationTree writes the clip once per PHYSICS tick and `drive()` runs
	# once per RENDERED frame. At 60/60 they alternate and the pose read here is
	# always the clip's, which is why every capture on this machine was clean. Put
	# two rendered frames inside one tick — which is what a 120 Hz panel does to a
	# 60 Hz simulation, and what most of the machines this ships to will do — and
	# the second frame measures last frame's ALREADY-CORRECTED arm, solves a swing
	# that assumes it is uncorrected, and lands the barrel a whole correction off.
	# Measured with `--physics-hz 30`, before this line existed:
	#
	#     miss at 12 m   median 0.26 cm   p95 4115 cm   max 19076 cm
	#     grip           281 mm of travel PER FRAME, alternating
	#
	# Which is not a small aim error. It is the hands and the weapon jumping a
	# quarter of a metre on every other frame — the "upper body and hands with the
	# gun kept flickering" report, exactly, and invisible to a 60 Hz test rig.
	#
	# `_clip_rotation` is cached for the whole physics tick (it captures the
	# tree's own pose on the first read, which happens here), so this restores the
	# same clean pose on every rendered frame inside a tick, however many there
	# are. The position is already immune: `_shift_bone` writes from the REST
	# pose, absolutely, for exactly this reason — see its own note.
	for arm: int in _arm_bones:
		_skeleton.set_bone_pose_rotation(arm, _clip_rotation(arm))
		_shift_bone(arm, reach)

	# --- where the weapon is, this frame -------------------------------------
	var gun: Transform3D = _gun_local(to_local)
	var grip: Vector3 = gun.origin
	var bore: Vector3 = gun.basis * _emitter_in_gun()
	var aimed: bool = bore.length_squared() > 1.0e-8
	if aimed:
		bore = bore.normalized()

	# --- where the lens is, this frame ---------------------------------------
	#
	# `_lens_basis` is the camera's own basis in the avatar's frame, so it already
	# carries the head pitch AND the bob roll, the landing dip and the hit shake.
	# The hold rides all of it, which is what "attached to the view" has to mean.
	var sway: Vector3 = Vector3(
			_hold_sway.x * HOLD_SWAY_SHIFT.x,
			-_hold_sway.y * HOLD_SWAY_SHIFT.y,
			0.0) - _lens_bob * HOLD_BOB_LAG + TUCK_LENS_SHIFT * _tuck
	var want_grip: Vector3 = _lens_local + _lens_basis * (HOLD_LENS_OFFSET + sway)
	var total: Basis = Basis.IDENTITY
	if aimed:
		# The aim drops as the weapon tucks — see TUCK_LENS_AIM. Everywhere else
		# this is exactly the sight line.
		var aim: Vector3 = _lens_local + _lens_basis \
				* (Basis(Vector3.RIGHT, -TUCK_LENS_AIM * _tuck)
					* Vector3(0.0, 0.0, -CONVERGE_DISTANCE))
		var want_bore: Vector3 = (aim - want_grip).normalized()
		# 1. the minimal swing that lands the barrel on the sight line.
		total = _swing(bore, want_bore)
		# 2. and the roll about that barrel, which cannot disturb step 1 because
		#    every point on the axis of a rotation is a fixed point of it. Levels
		#    the weapon to the LENS's horizon rather than to the world's, so a
		#    hold under a rolling lens rolls with it instead of appearing to
		#    counter-rotate. `_hold_sway` buys its lean here for free.
		var up: Vector3 = (total * (gun.basis * Vector3.UP)).normalized()
		var in_lens: Vector3 = _lens_basis.inverse() * up
		total = Basis(want_bore,
				-atan2(in_lens.x, in_lens.y) - _hold_sway.x * HOLD_SWAY_ROLL) * total

	# --- and put it there ----------------------------------------------------
	for arm: int in _arm_bones:
		var shoulder: Vector3 = to_local * _skeleton.get_bone_global_pose(arm).origin
		var placed: Vector3 = want_grip + total * (shoulder - grip)
		_twist_bone(arm, total)
		_shift_bone(arm, reach + placed - shoulder)


## The minimal rotation taking `from` onto `to`, both unit. No roll about the
## result by construction — the axis is perpendicular to both, so nothing spins
## about the barrel that this function did not have to spin.
static func _swing(from: Vector3, to: Vector3) -> Basis:
	var along: float = clampf(from.dot(to), -1.0, 1.0)
	if along > 0.9999999:
		return Basis.IDENTITY
	var axis: Vector3 = from.cross(to)
	if axis.length_squared() < 1.0e-14:
		# Antiparallel: the swing is a half turn about anything perpendicular. A
		# hold can never reach this, and a solver that returns garbage at its one
		# singularity is a solver that fails on the frame somebody photographs.
		axis = from.cross(Vector3.UP)
		if axis.length_squared() < 1.0e-14:
			axis = from.cross(Vector3.RIGHT)
	return Basis(axis.normalized(), acos(along))


## The emitter's position in the WEAPON's own frame — the constant that turns the
## gun's transform into a barrel direction.
##
## Read off the live nodes every frame rather than cached, and that is not
## laziness: the socket is re-seated at the end of `drive()`, so both of these
## transforms are one frame stale — and stale by exactly the same amount, which
## makes the RELATIVE transform between them exact. A cached copy would have to
## be invalidated by whatever re-sockets the weapon next, and nothing else in
## this file needs a cache-invalidation rule.
##
## Zero when there is no weapon, which reads as "no barrel" and switches the
## convergence off rather than aiming an imaginary one.
func _emitter_in_gun() -> Vector3:
	if _gun == null or not is_instance_valid(_gun) \
			or _muzzle == null or not is_instance_valid(_muzzle):
		return Vector3.ZERO
	return _gun.global_transform.affine_inverse() * _muzzle.global_position


## The weapon's whole transform in the avatar's frame, THIS frame, derived from
## the wrist bone rather than read off the socket node. See `_grip_local` for why
## the socket cannot be asked.
func _gun_local(to_local: Transform3D) -> Transform3D:
	if _hand_bone < 0:
		return Transform3D(Basis.IDENTITY, _lens_local)
	return to_local * (_skeleton.get_bone_global_pose(_hand_bone)
			* Transform3D(Basis(HAND_ROTATION), HAND_OFFSET))


## Where the breaker's own origin sits in the avatar's frame, THIS frame, derived
## from the wrist bone rather than read off the socket node.
##
## The socket is only re-seated at the end of `drive()` (see `_follow_hand`), so
## reading `_gun.global_position` here would pivot this frame's convergence about
## last frame's grip — a lag of exactly the kind the rest of this file exists to
## remove. The bone pose is current the moment it is asked for.
func _grip_local(to_local: Transform3D) -> Vector3:
	if _hand_bone < 0:
		return _lens_local
	return to_local * (_skeleton.get_bone_global_pose(_hand_bone)
			* Transform3D(Basis(HAND_ROTATION), HAND_OFFSET)).origin


## Composes an arbitrary world-space rotation onto a bone's clip pose.
##
## `_aim_bone`'s (yaw, pitch) pair cannot express this: the convergence and the
## lens pitch are rotations about DIFFERENT axes applied in a fixed order, and
## decomposing their product back into one yaw and one pitch is only exact when
## one of them is zero. Every argument in `_aim_bone` about composing onto the
## CLIP's pose rather than the live one applies here unchanged — see
## `_clip_rotation`.
func _twist_bone(bone: int, avatar_delta: Basis) -> void:
	if bone < 0:
		return
	var body: Basis = global_transform.basis
	var world: Basis = body * avatar_delta * body.inverse()
	var parent: Basis = _parent_basis(bone)
	var local: Basis = parent.inverse() * world * parent
	_skeleton.set_bone_pose_rotation(bone,
			local.get_rotation_quaternion() * _clip_rotation(bone))


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


## PT1. Where the lens is and where it is pointing, in the avatar's own frame,
## written by the owning Player from `_process` — the SAME frame the mouse moved
## it, which is the entire point. Reading the replicated `sync_pitch` instead
## would pose the hold one physics tick behind the view it is supposed to be
## bolted to, which is the lag half of the complaint this exists to answer.
##
## `look` is (yaw, pitch), and it is now ONLY the sway's input — the rate of a
## mouse, not the pose of a hold. `lens` is the camera's whole transform in this
## avatar's frame, which is the pose: PT4 replaced "rotate the hold about the eye
## by the head's pitch" with "put the hold in the lens", because the head's pitch
## is one of five things `Player._update_view` writes between the eye and the
## world and the other four (bob, landing dip, breath, hit shake — translation
## AND rotation, roll included) were sliding the weapon every time the player
## moved. Handing over the transform instead of an angle means the next thing
## anybody adds to that lens is followed for free.
##
## `bob` is the walk cycle's own contribution to that transform, passed
## separately so the hold can lag a fraction of it back and read as carried
## rather than welded. See HOLD_BOB_LAG.
##
## Only the local first-person copy is ever told.
func set_lens(look: Vector2, lens: Transform3D, bob: Vector3) -> void:
	_hold_pitch = look.y
	_lens_local = lens.origin
	_lens_basis = lens.basis
	_lens_bob = bob
	_last_hold_look = look if not _has_hold_look else _last_hold_look
	_has_hold_look = true
	_pending_look = look


## The additive lean. Chases the lens's angular RATE (not its angle), saturates
## early, and settles fast — see HOLD_SWAY_LAG for why this is an offset laid on
## a rigid hold rather than a smoothing of the hold itself.
func _advance_hold_sway(delta: float) -> void:
	if not _first_person or delta <= 0.0:
		return
	var dyaw: float = wrapf(_pending_look.x - _last_hold_look.x, -PI, PI)
	var dpitch: float = _pending_look.y - _last_hold_look.y
	_last_hold_look = _pending_look
	var want: Vector2 = Vector2(
			clampf(dyaw / delta / HOLD_SWAY_SATURATION, -1.0, 1.0),
			clampf(dpitch / delta / HOLD_SWAY_SATURATION, -1.0, 1.0))
	_hold_sway = _hold_sway.lerp(want, 1.0 - exp(-HOLD_SWAY_LAG * delta))


## Weapon collision, 0 = clear, 1 = pressed against a wall. Written by the owning
## Player every frame; only the first-person copy does anything with it.
func set_tuck(amount: float) -> void:
	_tuck = clampf(amount, 0.0, 1.0)


## One shot fired: light the emitter on the socketed rifle. Called on the local
## embodied copy from `Player._fire_muzzle`, and on a remote copy from
## `Player.show_breaker_shot` when a crewmate's shot arrives.
func fire() -> void:
	_flash = FLASH_TIME
	# Flash-rate governor — see ViewModel.fire and MUZZLE_FLASH_MIN_INTERVAL. A
	# too-soon shot keeps its emitter glow but not its room-casting flash.
	if _since_full_flash >= MUZZLE_FLASH_MIN_INTERVAL:
		_room_gate = 1.0
		_since_full_flash = 0.0
	else:
		_room_gate = 0.0


## Where the first-person lens belongs: the eye node the exporter parked between
## the eye bones. Null until the model is loaded.
func eye() -> Node3D:
	return _eye


## Puts the weapon socket on the hand bone, AFTER this frame's pose is final.
##
## This replaces a `BoneAttachment3D`, and the reason is the second real bug PT1
## turned up — the one behind "the hands looked cursed on the gun".
##
## `BoneAttachment3D` refreshes itself from the skeleton's `skeleton_updated`
## signal, which fires when the skeleton processes its own update. Every pose this
## file writes — the aim lift, the first-person yaw, the outboard shoulder cheat,
## the wall tuck, and now the pitch follow — is written from `drive()`, i.e. from
## `Player._process`, i.e. AFTER that update has already run for the frame; the
## AnimationTree then overwrites the bones from its physics callback before the
## next one. So the socket was never posed from the pose the ARMS were being
## rendered with. Measured, with the pitch follow deliberately exaggerated to make
## it visible: the wrist bone at (0.297, 1.298, -0.153) and the weapon it is
## supposedly gripping at (0.281, 1.448, -0.349) — **25 cm apart**. Both hands are
## posed onto a grip that is not where the weapon is, which is exactly what
## "cursed, very bent" looks like from behind the lens.
##
## It was invisible before this milestone because every override this file wrote
## was CONSTANT: a socket driven from a stale pose still converges on the right
## answer when the right answer never changes. The moment the hold started
## tracking a live mouse, the lag became the whole effect.
##
## A plain Node3D we position ourselves cannot drift: it is written at the end of
## `drive()`, so the weapon is always socketed to the pose the same frame renders.
func _follow_hand() -> void:
	if _hand == null or not is_instance_valid(_hand) or _hand_bone < 0:
		return
	_hand.transform = _skeleton.get_bone_global_pose(_hand_bone)


## World position of the breaker's own origin — the grip, not the barrel tip.
## Read by `--gunlog`; see `Player.hold_world_point`.
func hold_point() -> Vector3:
	if _gun != null and is_instance_valid(_gun):
		return _gun.global_position
	return global_position


## The weapon's own orientation in the world, so an instrument can ask what its
## ROLL is relative to the lens rather than guessing from a picture. Identity
## when there is no weapon, which reads as "no cant" and is the honest answer.
func hold_basis() -> Basis:
	if _gun != null and is_instance_valid(_gun):
		return _gun.global_transform.basis.orthonormalized()
	return global_transform.basis


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

	# The body light, culled to the body layer so the room never sees it.
	#
	# ## PT4 re-aimed it, and the reason is a number
	#
	# It used to sit at the sternum with a metre and a half of reach, which meant
	# the nearest thing to it was the player's own chest at fifteen centimetres.
	# Looking straight down — which M6.6's decks made an ordinary thing to do,
	# not a stunt — that chest is the whole frame, and it clipped:
	#
	#   lens pitch -1.45, 3440x1440    pixels at full white
	#     as shipped                     1.024 %
	#     with this lamp switched off    0.173 %
	#     with the ACCENT emission off   1.013 %   (i.e. not the accents)
	#
	# Five sixths of the blowout was one light. Not the emissive seams, which were
	# the obvious suspect and are innocent.
	#
	# The fix is geometric and STATIC, deliberately. The tempting fix is to fade
	# the lamp as the player looks down, and it is a trap: that makes a light
	# whose brightness tracks the mouse, a fast flick strobes it, and every
	# temporal-brightness effect in this game has to answer to the 3 Hz flash
	# ceiling (DESIGN.md pillar 7). A lamp that does not change cannot flash.
	#
	#   * MOVED OUT IN FRONT of the chest — 60 cm forward, level with the hold —
	#     so the chest is beyond the lamp's reach entirely instead of being the
	#     nearest thing to it. Halfway measures do not work here and both were
	#     tried: leaving it at the sternum and merely dimming it takes the
	#     blowout from 1.02% to 0.61% and costs the hands; moving it INTO the
	#     hold instead of in front of it puts the lamp inside the forearm and
	#     takes the blowout to 7.88%, which is worse than shipping it.
	#   * REACH cut to 0.8 m. It has to cover the grip and stop; 1.5 m reached
	#     the hips, the far shoulder and both knees.
	#   * ATTENUATION up, so what is left falls off hard across the body's depth.
	#   * SPECULAR OFF. A point light 10 cm inside your own pauldron puts a
	#     mirror highlight on it, and a specular highlight is the one term that
	#     goes straight past white with nothing to clamp it.
	#
	# It is better on BOTH axes rather than a trade, which is how you know it is
	# the geometry that was wrong and not the brightness:
	#
	#                      look-down clipping     level-view hands
	#     as shipped         3.180 % / 1.024 %      0.042
	#     this               0.995 % / 0.243 %      0.099
	#     lamp switched off  0.817 % / 0.173 %      —
	#
	# i.e. the blowout is now within a rounding error of having no lamp at all,
	# and the hands are two and a half times better lit than the version that was
	# causing it.
	var lamp: OmniLight3D = OmniLight3D.new()
	lamp.name = "BodyLight"
	lamp.position = Vector3(0.10, 1.48, -0.60)
	lamp.light_color = Color(0.78, 0.85, 1.0)
	# Feeble on purpose: it exists so your hands are not a silhouette, not so you
	# can read by them.
	lamp.light_energy = 0.75
	lamp.omni_range = 0.8
	lamp.omni_attenuation = 2.2
	lamp.light_specular = 0.0
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
