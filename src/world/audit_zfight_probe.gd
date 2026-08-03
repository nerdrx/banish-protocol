class_name AuditZFightProbe
extends Node
## The harness that drives `AuditZFight` over a seed/layer matrix and the hub.
##
## Stands each layer up for real under a throwaway host, sweeps the built scene,
## tears it down — the same shape as `Debug._deckwalk_layer`, and for the same
## reason: the audit has to see where geometry ACTUALLY ended up, not where the
## generator meant to put it. Needs no window and no `--autohost`.
##
## Armed from `Photonics._ready` alongside `--freecam`, because src/core/debug.gd
## is a shared file under concurrent edit and a new instrument has no business
## widening its parser.

## How many findings the per-layer table prints before it summarises. The class
## census below it is the part that gets acted on.
const TABLE_ROWS: int = 12

var seed_override: int = -1
var layer_override: int = -1


## Stand one up if `--auditz` was passed. `--auditz SEED LAYER` narrows to a
## single layer and prints every finding instead of the top rows.
static func arm(host: Node) -> AuditZFightProbe:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var at: int = args.find("--auditz")
	if at < 0:
		return null
	var probe: AuditZFightProbe = AuditZFightProbe.new()
	probe.name = "AuditZFightProbe"
	if at + 1 < args.size() and not args[at + 1].begins_with("--"):
		probe.seed_override = args[at + 1].to_int()
	if at + 2 < args.size() and not args[at + 2].begins_with("--"):
		probe.layer_override = args[at + 2].to_int()
	host.add_child(probe)
	return probe


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _run() -> void:
	await get_tree().process_frame
	var started: int = Time.get_ticks_msec()
	var total: int = 0
	var classes: Dictionary = {}
	var scanned: int = 0
	var patches_total: int = 0

	var seeds: Array[int] = []
	var layers: Array[int] = []
	if seed_override >= 0:
		seeds.append(seed_override)
		layers.append(layer_override if layer_override > 0 else 1)
	else:
		seeds.append_array(AuditZFight.SEEDS)
		layers.append_array(AuditZFight.LAYERS)

	print("[AuditZ] eps=%.4f m  min_area=%.3f m2  neon=%s" % [
		AuditZFight.EPS, AuditZFight.MIN_AREA, NeonBudget.arm_name()])
	print("[AuditZ] %-8s %-5s %8s %9s   worst offenders" % [
		"seed", "layer", "patches", "findings"])

	for seed_value: int in seeds:
		for layer: int in layers:
			var out: Dictionary = await _sweep_layer(seed_value, layer, classes)
			scanned += 1
			total += int(out["findings"])
			patches_total += int(out["patches"])

	# The hub is authored rather than generated, it is the first thing anybody
	# sees every session, and it is built by a DIFFERENT GeometryKit subclass — so
	# it can carry a whole class of finding the layer matrix never produces.
	var hub: Dictionary = await _sweep_hub(classes)
	scanned += 1
	total += int(hub["findings"])
	patches_total += int(hub["patches"])

	print("[AuditZ] --- classes (fix these, not the instances) ---")
	var names: Array = classes.keys()
	names.sort_custom(func(a: String, b: String) -> bool:
		return int(classes[a]) > int(classes[b]))
	for name: String in names:
		print("[AuditZ]   %-52s %4d" % [name, int(classes[name])])

	print("[AuditZ] %s %d findings over %d scenes (%d patches), %d ms" % [
		"PASS" if total == 0 else "FAIL", total, scanned, patches_total,
		Time.get_ticks_msec() - started])
	get_tree().quit(1 if total > 0 else 0)


## Whether this process can actually see where batched geometry ended up.
##
## THE INSTRUMENT-THAT-LIES GUARD. The first full run of this audit reported
## 243,086 findings, 93% of them one class — `Trim_BASEBOARD_4M` against itself,
## every single one at the identical coordinate (0.0, 0.02, 0.23). That is not
## 225,506 bugs; it is 92 baseboards read back at the origin and paired with each
## other, C(92,2) = 4,186 times per layer. `--headless` installs the dummy
## rendering driver, `get_instance_transform` asks the RenderingServer, and the
## dummy server has nothing to answer with.
##
## Taking the reading and believing it would have sent a milestone chasing a
## baseboard bug that does not exist. So the audit checks whether its own eyes
## work before it opens them: a batch with more than one instance whose first
## few transforms are ALL exactly the identity is not a scene, it is a driver.
func _multimesh_readable(root: Node) -> bool:
	var batches: int = 0
	for node: Node in root.find_children("*", "MultiMeshInstance3D", true, false):
		var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
		if mm == null or mm.instance_count < 2:
			continue
		batches += 1
		for i: int in mini(4, mm.instance_count):
			if not mm.get_instance_transform(i).is_equal_approx(Transform3D.IDENTITY):
				return true
	# No batches at all is not evidence of a broken driver.
	return batches == 0


func _sweep_layer(seed_value: int, layer: int, classes: Dictionary) -> Dictionary:
	var graph: LayerGraph = LayerGraph.generate(seed_value, layer)
	var host: Node3D = Node3D.new()
	host.name = "AuditZScratch"
	get_tree().root.add_child(host)
	var builder: ProcLayerBuilder = ProcLayerBuilder.create(graph)
	host.add_child(builder)  # GeometryKit._ready() builds synchronously.
	await get_tree().process_frame
	var out: Dictionary = _report("seed %d layer %d" % [seed_value, layer],
			"%-8d %-5d" % [seed_value, layer], builder, classes)
	host.queue_free()
	return out


func _sweep_hub(classes: Dictionary) -> Dictionary:
	var host: Node3D = Node3D.new()
	host.name = "AuditZHubScratch"
	get_tree().root.add_child(host)
	var builder: PartitionBuilder = PartitionBuilder.new()
	host.add_child(builder)
	await get_tree().process_frame
	var out: Dictionary = _report("the hub", "%-8s %-5s" % ["hub", "-"],
			builder, classes)
	host.queue_free()
	return out


func _report(what: String, prefix: String, root: Node,
		classes: Dictionary) -> Dictionary:
	if not _multimesh_readable(root):
		printerr("[AuditZ] ABORT: MultiMesh instance transforms all read back as the " +
				"identity. `MultiMesh.get_instance_transform` is served by the " +
				"RenderingServer, and the DUMMY driver `--headless` installs does not " +
				"keep the buffer — so every batched element (all the trim, all the " +
				"clutter, every deck and railing) appears stacked at the world origin " +
				"and the audit reports thousands of findings that do not exist. " +
				"Re-run under the project's gamescope wrapper:")
		printerr("[AuditZ]   env -u DISPLAY -u WAYLAND_DISPLAY gamescope -W 640 -H 480 " +
				"-w 640 -h 480 --backend headless -- godot --path . -- --auditz")
		get_tree().quit(2)
		return {"findings": 0, "patches": 0}
	var patches: Array[Dictionary] = AuditZFight.collect(root)
	var found: Array[Dictionary] = AuditZFight.findings(patches)
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["area"]) > float(b["area"]))
	print("[AuditZ] %s %8d %9d" % [prefix, patches.size(), found.size()])
	var rows: int = found.size() if seed_override >= 0 else mini(found.size(), TABLE_ROWS)
	for i: int in rows:
		var f: Dictionary = found[i]
		print("[AuditZ]     %s  gap=%.4f m  area=%.2f m2  %s  |  %s <-> %s" % [
			str((f["at"] as Vector3).snapped(Vector3.ONE * 0.01)),
			float(f["gap"]), float(f["area"]),
			["X", "Y", "Z"][int(f["axis"])] + ("+" if int(f["sign"]) > 0 else "-"),
			String(f["a"]), String(f["b"])])
		if seed_override >= 0:
			print("[AuditZ]        ids=%s  A=%s  B=%s" % [
				String(f["ids"]), str(f["ra"]), str(f["rb"])])
	if rows < found.size():
		print("[AuditZ]     ... and %d more on %s" % [found.size() - rows, what])
	for f: Dictionary in found:
		var name: String = AuditZFight.class_of(f)
		classes[name] = int(classes.get(name, 0)) + 1
	return {"findings": found.size(), "patches": patches.size()}
