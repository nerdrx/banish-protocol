@tool
extends Node3D
## GI CORRECTNESS PROBE — is godotengine/godot#115599 present on 4.7.1?
##
##   tools/fidelity_bench/shoot.sh res://tools/fidelity_bench/gi_probe.tscn \
##       <out>.png 1280x720 200 Cam -- (see gi_probe.sh, which adds --gi)
##
## WHAT IS BEING TESTED
## Godot 4.6 shipped a regression (#115599) in which sky, VoxelGI and SDFGI
## lighting rendered wrong — reported as black, blown out, or simply not
## contributing. This project's whole look-dev direction assumes indirect light
## works (the layer environment leans on SSIL precisely because it could not
## lean on a real GI solution), and the PHOTONICS milestone wants to know
## whether SDFGI is on the table at all before anyone budgets milliseconds for
## it. So the question is not "how fast is SDFGI" — it is "does SDFGI produce
## correct light on 4.7.1, yes or no".
##
## THE TEST IS A CORNELL BOX, because a Cornell box has exactly one job: it
## makes indirect light impossible to miss. A single spot fires at the ceiling,
## so NOTHING in the room is directly lit except a strip of ceiling. Every other
## surface can only be lit by bounce. The side walls are saturated red and blue,
## so bounce is not merely brighter, it is COLOURED, and a solution that is
## silently returning grey ambient instead of real GI fails visibly.
##
## Three modes, selected with `--gi off|sdfgi|voxelgi`:
##   off      the control. The room should be nearly black below the ceiling.
##   sdfgi    Environment.sdfgi_enabled. Expect the floor to lift and to pick up
##            red on the left and blue on the right.
##   voxelgi  a VoxelGI node baked at runtime. Same expectation.
##
## The verdict is not eyeballed: tools/fidelity_bench/gi_probe.sh renders all
## three and prints per-region mean luminance and per-region red-minus-blue, so
## "SDFGI contributes coloured bounce" is a number.
##
## SSIL and SSR are switched OFF in every mode. Both are screen-space and both
## would contribute bounce of their own, which would make an SDFGI failure look
## like a partial success.

@export var gi_mode: String = "off":
	set(v):
		gi_mode = v
		_apply()


func _ready() -> void:
	# The mode comes from the command line so one scene covers all three runs.
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--gi" and i + 1 < args.size():
			gi_mode = args[i + 1]
	_apply()


func _apply() -> void:
	if not is_inside_tree():
		return
	var we: WorldEnvironment = get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null or we.environment == null:
		return

	# Duplicate rather than mutate: the environment is the game's own shared
	# .tres and a probe has no business editing it, even in memory.
	var env: Environment = we.environment.duplicate() as Environment
	env.ssil_enabled = false
	env.ssr_enabled = false
	env.ssao_enabled = false
	env.volumetric_fog_enabled = false
	env.glow_enabled = false
	# Ambient to zero. With the project's 0.36 cool ambient still on, every
	# surface in the box is lifted by a constant and a GI failure hides inside it.
	env.ambient_light_energy = 0.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.sdfgi_enabled = (gi_mode == "sdfgi")
	if env.sdfgi_enabled:
		# Small cells: the box is 6 m across, and the default 0.2 m cascade-0
		# cell would put the whole room inside two probes.
		env.sdfgi_min_cell_size = 0.08
		env.sdfgi_cascades = 4
		env.sdfgi_bounce_feedback = 0.5
		env.sdfgi_energy = 1.0
		env.sdfgi_use_occlusion = true
		env.sdfgi_read_sky_light = false
	we.environment = env

	var voxel: VoxelGI = get_node_or_null("VoxelGI") as VoxelGI
	if voxel != null:
		voxel.visible = (gi_mode == "voxelgi")
		if gi_mode == "voxelgi" and not Engine.is_editor_hint():
			# Bake at runtime so the probe needs no committed .res payload and
			# can never be testing a stale bake from a different engine build.
			voxel.bake(self, false)
	print("[GIProbe] mode=%s sdfgi=%s voxelgi=%s" % [
		gi_mode, str(env.sdfgi_enabled), str(voxel != null and voxel.visible)])
