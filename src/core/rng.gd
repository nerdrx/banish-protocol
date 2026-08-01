extends Node
## Rng — seeded determinism helper.
##
## The host rolls a run seed and replicates it; every peer generates identical
## content from it (see DESIGN.md "Seeded procgen"). M1 only needs the plumbing:
## procgen lands in M2.

var run_seed: int = 0

var _streams: Dictionary[String, RandomNumberGenerator] = {}


func _ready() -> void:
	roll_new_seed()


## Rolls a fresh random run seed (host only) and returns it.
func roll_new_seed() -> int:
	var seed_rng: RandomNumberGenerator = RandomNumberGenerator.new()
	seed_rng.randomize()
	set_run_seed(int(seed_rng.randi()))
	return run_seed


## Applies a seed received from the host. Resets every named stream so peers
## that join mid-session still generate identical content.
func set_run_seed(value: int) -> void:
	run_seed = value
	_streams.clear()


## Deterministic stream for a named subsystem, so adding a new consumer does not
## shift every other consumer's sequence. Cached: successive calls continue the
## same sequence.
func stream(label: String) -> RandomNumberGenerator:
	if not _streams.has(label):
		_streams[label] = fresh(label)
	return _streams[label]


## Uncached stream. Every call returns a generator rewound to the same starting
## state, which is what procgen needs: rebuilding layer 3 must produce the layer
## 3 you already walked, not the next slice of a shared sequence.
func fresh(label: String) -> RandomNumberGenerator:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_for(label)
	return rng


## The 64-bit seed a named stream would use. Exposed so procgen can print it in
## determinism dumps.
func seed_for(label: String) -> int:
	return hash(str(run_seed, ":", label))
