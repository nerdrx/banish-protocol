class_name MotherVoice
extends RefCounted
## M14 — HER VOICE, LIVE. The façade: one call in, a playable stream out.
##
## AudioService used to pick one of fifteen pre-baked cues by hashing the bark
## text. That could never say your callsign, because a callsign is not known at
## build time — and the fifteen cues were speech-SHAPED rather than speech, which
## a player heard as "generic grunts". Both problems have the same answer: build
## the audio at runtime from the words.
##
## ## The whole integration
##
## ONE call, at the top of `AudioService._voice_stream`:
##
##     var live: AudioStream = MotherVoice.stream_for(text, ev.key)
##     if live != null:
##         return live
##
## Everything else about the voice tier is unchanged — the buses, the
## spatialisation, the threat sidechain, the music duck, the Dampened trim, and
## above all the CAPTION, which is still emitted from that same call site with
## the same text. A deaf player reads exactly what a hearing player hears,
## including their own callsign, because there is still only one place where
## either of them happens.
##
## ## Threading and the cache
##
## Synthesis is 150-400 ms of arithmetic. That is nothing on a worker thread and
## it is four dropped frames on the main one, so it never runs on the main one.
## `stream_for` is therefore a CACHE LOOKUP and nothing else: a hit returns a
## stream immediately, a miss returns null and enqueues the work, and the line is
## silent that once. The cache is keyed by (register, dampened, text) and is
## content-addressed — the same input is byte-identical audio every time, which
## the selftest asserts, because every noise source in the chain is seeded from
## the key rather than from the engine RNG.
##
## Misses are made rare by PRE-WARMING rather than by blocking:
##   * at load, the phrase bodies she is most likely to reach for;
##   * at menu/lobby time, the local player's own callsign, because the first
##     time she says your name is the moment the whole feature is judged;
##   * on layer entry, the address bodies legal at that depth.
## See `prewarm_*` below for the budget each of those costs.
##
## ## Multiplayer
##
## Audio is generated LOCALLY on every peer from the replicated bark text; not
## one byte of audio goes on the wire. Every peer therefore speaks the same
## sentence with the same voice, including the same callsign — see "WHERE THE
## SLOTS WENT" below for why everyone hearing YOUR FRIEND'S name is the argued
## decision and not just the cheap one.

const RATE: int = 48000

## Cache ceiling in bytes of 16-bit PCM. 12 MB is roughly forty lines of hers,
## which is more than a run reaches for; past that the least-recently-used entry
## goes. Deliberately a byte budget and not an entry count, because her lines
## range from a one-word callsign to a 4 s sentence.
const CACHE_BYTES: int = 12 * 1024 * 1024

## How many synthesis jobs may be in flight at once. Two: enough that a prewarm
## sweep finishes promptly, few enough that it cannot take the machine away from
## the frame.
const MAX_JOBS: int = 2

static var _mutex: Mutex = Mutex.new()
static var _cache: Dictionary = {}          ## key -> {pcm, seconds, lufs, dbtp, used}
static var _pending: Dictionary = {}        ## key -> true while a job owns it
static var _queue: Array[Dictionary] = []
static var _jobs: Array = []                ## live _Job refs, so they are not freed
static var _bytes: int = 0
static var _clock: int = 0
static var _enabled: bool = true
static var _env_read: bool = false
static var _stat_hits: int = 0
static var _stat_misses: int = 0
static var _stat_synth: int = 0
static var _stat_us: int = 0
static var _waiters: Dictionary = {}        ## key -> Array[Callable], main-thread
static var _unspeakable: Dictionary = {}    ## key -> true; synthesis produced nothing
static var _stat_late: int = 0
static var _durations: Dictionary = {}     ## key -> seconds, for `duration_for`


# ==========================================================================
# THE HOOK
# ==========================================================================

## "Is this line speakable RIGHT NOW, and if not, call me back when it is."
##
## THIS IS THE HOOK THAT MATTERS, and it exists because the first design was
## wrong. The original plan was: cache hit plays, cache miss is silent, and
## pre-warming makes misses rare. That reasoning held for a 183-line corpus. M15
## then grew the corpus past 800 lines with an anti-repetition bag on top, which
## means the NEXT thing she says is very often a sentence no run has ever spoken
## — so "a miss is silence" would have made her mute most of the time, and no
## amount of pre-warming fixes a distribution that is deliberately novel.
##
## So a miss is not silence: it is a DELAY. The line is synthesised on a worker
## (150-500 ms) and the caller's own speak path is re-entered when it lands, so
## the caption, the ducking, the murmur density roll and the emitter placement
## all still happen exactly once, just a beat later. On a machine that composes
## sentences, a beat of dead air before she talks is not a defect — it is the
## most characterful thing in the feature.
##
## Returns TRUE if the caller should proceed immediately. Returns FALSE if it
## should stop and wait for `on_ready`, which is invoked on the MAIN THREAD via
## `call_deferred`.
##
## The wait is UNBOUNDED IN CALLS but bounded in time, and getting that
## distinction wrong was a real bug: an earlier version let a line wait only
## once, on the theory that a second refusal meant a synthesis failure. What it
## actually meant was that the same line had been asked for twice while its
## single job was still running, and the second ask sailed through the guard into
## a cache miss and silence. So the only thing that makes a caller give up is a
## line that has been synthesised and produced nothing — recorded in
## `_unspeakable`, which cannot grow without a completed job.
static func await_line(text: String, event_key: StringName,
		on_ready: Callable) -> bool:
	if not _live() or text.strip_edges().is_empty():
		return true
	var register: String = VoiceRegisters.register_for_event(event_key)
	var key: String = _key(text, register)
	_mutex.lock()
	var ready: bool = _cache.has(key)
	var dead: bool = _unspeakable.has(key)
	if not ready and not dead:
		if not _waiters.has(key):
			_waiters[key] = [] as Array
		(_waiters[key] as Array).append(on_ready)
		_stat_late += 1
	_mutex.unlock()
	if ready or dead:
		return true
	warm(text, register)
	return false


## Cached audio for this line in this register, or null if it is not ready yet.
## Never blocks, never allocates on the audio path beyond one AudioStreamWAV.
static func stream_for(text: String, event_key: StringName) -> AudioStream:
	if not _live() or text.strip_edges().is_empty():
		return null
	var register: String = VoiceRegisters.register_for_event(event_key)
	var key: String = _key(text, register)
	_mutex.lock()
	var hit: Dictionary = _cache.get(key, {}) as Dictionary
	if not hit.is_empty():
		_clock += 1
		hit["used"] = _clock
		_stat_hits += 1
	else:
		_stat_misses += 1
	_mutex.unlock()
	if hit.is_empty():
		warm(text, register)
		return null
	var stream: AudioStreamWAV = AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = hit["pcm"]
	return stream


## Is this line already speakable? The prewarm reporting and the selftest use it;
## nothing on the hot path needs to ask.
static func is_ready(text: String, register: String) -> bool:
	_mutex.lock()
	var got: bool = _cache.has(_key(text, register))
	_mutex.unlock()
	return got


## Queue a line for background synthesis. Idempotent and cheap to call often.
static func warm(text: String, register: String) -> void:
	if not _live() or text.strip_edges().is_empty():
		return
	var key: String = _key(text, register)
	_mutex.lock()
	var need: bool = not _cache.has(key) and not _pending.has(key)
	if need:
		_pending[key] = true
		_queue.append({"key": key, "text": text, "register": register,
				"dampened": _dampened()})
	_mutex.unlock()
	if need:
		_pump()


## EXACTLY how long she will take to say this, in seconds, WITHOUT synthesising
## it. Costs one letter-to-sound pass and one frame build — MEASURED at 2.4 ms
## for a fresh three-second line, not the sub-millisecond it looks like — and is
## memoised by (register, text), so the first ask about a line is 2.4 ms and
## every later one is a dictionary lookup. A director scoring a handful of
## candidates per bark is fine; one scoring all 800 lines of the corpus on a
## frame is not, and should warm the memo on a layer seam instead.
##
## This is not an estimate. The synthesiser renders `track.seconds * RATE`
## samples and every stage of the post chain is length-preserving, so the number
## returned here is the number of seconds of audio that will exist.
##
## THE REASON IT IS PUBLIC: her lines are HEARD now, not read, so a bark's length
## is a duration in the mix rather than a character count on a caption. A fixed
## cooldown between barks either wastes silence after a short line or lets a long
## one get run over by the next. Whoever owns the pacing can now derive the gap
## from what she is actually about to say. Measured over the corpus: she speaks
## 11.5 characters / 2.94 syllables / 2.17 words per second in the directed
## register, and 9.6 / 2.46 / 1.82 in the murmur and Below-the-Kernel registers —
## but those are averages, and this is the specific answer.
static func duration_for(text: String, register: String = "") -> float:
	if text.strip_edges().is_empty():
		return 0.0
	var reg: String = register if not register.is_empty() else VoiceRegisters.DIRECTED
	var memo: String = reg + "\u0001" + text
	_mutex.lock()
	var known: float = float(_durations.get(memo, -1.0))
	_mutex.unlock()
	if known >= 0.0:
		return known
	var params: Dictionary = VoiceRegisters.params(reg)
	var track: VoiceFrames.Track = VoiceFrames.build(text, params["frames"] as Dictionary)
	_mutex.lock()
	# Bounded: a director may ask about every line in an 800-line corpus, and
	# eight hundred floats is nothing, but a run that asks about generated text
	# forever should not grow without limit.
	if _durations.size() > 4096:
		_durations.clear()
	_durations[memo] = track.seconds
	_mutex.unlock()
	return track.seconds


## Same question for a bark category rather than an event key, which is the shape
## a director has to hand.
static func duration_for_category(text: String, category: String, layer: int) -> float:
	return duration_for(text, register_for_category(category, layer))


# ==========================================================================
# PRE-WARM
# ==========================================================================

## The local player's callsign, spoken alone. Call this from the menu or the hub
## the moment a name is known: it is one short utterance (~0.6 s of audio, ~60 ms
## of work) and it is the single highest-value thing in the cache, because the
## first time she says your name is the moment this feature is judged.
static func prewarm_callsign(name: String) -> void:
	if name.strip_edges().is_empty():
		return
	warm(name + ".", VoiceRegisters.DIRECTED)
	warm(name + ".", VoiceRegisters.SUBZERO)


## Every crew member's callsign. Four names, ~250 ms of worker time total.
static func prewarm_crew() -> void:
	for id: Variant in _crew_ids():
		prewarm_callsign(_crew_name(int(id)))


## Warm a batch of lines she is likely to reach for next.
##
## The TEXT comes from whoever owns the corpus — M15's `LoreDirector` renders a
## bark with every `{SLOT}` already filled, and this module deliberately does not
## know how that happened. One renderer, one source of truth for what she says;
## this file only turns a finished sentence into sound.
##
## BUDGET, measured on this machine: 240 ms of worker time per second of audio
## dry, 440 ms with the full tape chain, so a twelve-line sweep of ~3 s lines is
## roughly 5 s of background work spread over two threads. It belongs on a layer
## seam, where there is already a loading pause, and it never blocks anything.
static func prewarm_texts(texts: PackedStringArray, register: String) -> void:
	for t: String in texts:
		warm(t, register)


## Which register a bark category lands in. Mirrors `AudioService.voice_tier_for`
## without depending on it — the tier table lives over there and this is only a
## prediction, so a drift between the two costs one cache miss and nothing else.
static func register_for_category(category: String, layer: int) -> String:
	match category:
		"address", "hunt", "epitaph", "exfil":
			return VoiceRegisters.DIRECTED
		"kernel_leak":
			return VoiceRegisters.SUBZERO if layer >= 20 else VoiceRegisters.DIRECTED
		_:
			return VoiceRegisters.MURMUR


# ==========================================================================
# WHERE THE SLOTS WENT, AND THE MULTIPLAYER DECISION
# ==========================================================================
#
# M14 originally carried its own `{SLOT}` filler. It does not any more, and the
# deletion is the right call rather than a concession: M15's LoreDirector already
# renders a bark with `{CALLSIGN}`, `{DATA}`, `{LAYER}`, `{CREW_COUNT}`,
# `{CREWMATE}` and the rest substituted, refuses to speak a line whose slots it
# cannot fill, and hands back finished text. Two substitution passes over the
# same braces is two places for the caption and the audio to disagree, which is
# the one thing the accessibility gate cannot tolerate. So: ONE renderer, and
# this module receives a sentence.
#
# THE MULTIPLAYER QUESTION the milestone asked to be decided and argued:
# **everyone hears the same name.** That falls out of the architecture for free —
# the host renders the line, the rendered text is RPC'd, and each peer
# synthesises audio LOCALLY from that identical text — but it is also the right
# answer on its own terms, and the alternative was seriously considered.
#
# The alternative is per-listener substitution: each player hears their own
# callsign in the same sentence. It sounds more personal and is in fact the
# cheaper effect, because it turns a singling-out into a broadcast. Nobody is
# picked; everybody is addressed; the moment costs nothing to produce and means
# nothing when it lands. What makes "MOTHER said a name" frightening is that it
# was not yours, that you are listening to it happen to someone whose breathing
# you can hear on comms, and that the selection was hers and you do not know the
# rule. Your turn coming is the content.
#
# There is also a duller and more decisive reason: the crew talk. A co-op horror
# game lives on the sentence "did you hear what she just called you", and a crew
# who cannot agree on what she said cannot use her at all. Rendered both ways
# (same bark, two peer identities, `--dumpvoice`); the shared reading is the only
# one that survives being talked about.
#
# NOT ONE BYTE OF AUDIO GOES ON THE WIRE. Every peer synthesises from replicated
# text, which is a few dozen bytes she was already sending.


# ------------------------------------------------------- autoload access ----
#
# The autoloads are reached through the tree rather than by their global names,
# and that is not squeamishness: this module is also driven by the offline bench
# (`tools/voice/render.gd`), which Godot compiles BEFORE the autoload singletons
# are registered, so a bare `Net.crew` here is a compile error that takes the
# whole bench down. Going through the tree also means the synthesis core can be
# unit-tested with no game standing up at all, which is how the selftest runs it.

static func _autoload(name: StringName) -> Node:
	var loop: MainLoop = Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return null
	var root: Window = (loop as SceneTree).root
	return root.get_node_or_null(NodePath(name)) if root != null else null


static func _crew_ids() -> Array:
	var net: Node = _autoload(&"Net")
	if net == null:
		return []
	var crew: Dictionary = net.get("crew") as Dictionary
	return crew.keys() if crew != null else []


static func _crew_name(id: int) -> String:
	var net: Node = _autoload(&"Net")
	return String(net.call("crew_name", id)) if net != null else ""


# ==========================================================================
# SYNTHESIS
# ==========================================================================

## Synchronous render, for the bench and the selftest. Never call this from a
## frame — it is the thing the whole threading apparatus exists to keep off one.
static func render_debug(text: String, register: String,
		dry: bool = false) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	var params: Dictionary = VoiceRegisters.params(register)
	if dry:
		params = VoiceRegisters.params(VoiceRegisters.CLEAN)
	var samples: PackedFloat32Array = _synthesise(text, params, register, dry)
	var rep: Dictionary = VoiceMeter.normalise_to(samples, RATE,
			float(VoiceRegisters.TARGET_LUFS.get(register, -23.0)),
			VoiceRegisters.CEILING_DBTP)
	return {
		"samples": samples,
		"lufs": rep["lufs"],
		"dbtp": rep["dbtp"],
		"gain_db": rep["gain_db"],
		"usec": Time.get_ticks_usec() - t0,
		"phones": " ".join(VoiceG2P.tokenise(text)),
	}


static func _synthesise(text: String, params: Dictionary, register: String,
		dry: bool) -> PackedFloat32Array:
	var seed: int = _seed(text, register)
	var track: VoiceFrames.Track = VoiceFrames.build(text,
			params["frames"] as Dictionary)
	if track.n <= 0:
		return PackedFloat32Array()
	var samples: PackedFloat32Array = VoiceKlatt.render(track, RATE,
			params["klatt"] as Dictionary, seed)
	if dry:
		return VoiceWav.peak_normalise(samples, 0.9)
	return VoiceTape.process(samples, RATE, params["tape"] as Dictionary, seed)


## A stable 31-bit seed from the cache key. `String.hash()` is the engine's own
## stable hash, not a per-process randomised one, so two peers synthesising the
## same line produce the same tape damage and the same hiss — which is what makes
## "we both heard the same thing" literally true rather than approximately.
static func _seed(text: String, register: String) -> int:
	return absi((text + "/" + register).hash()) | 1


static func _key(text: String, register: String) -> String:
	return "%s\u0001%d\u0001%s" % [register, 1 if _dampened() else 0, text]


## Dampened Protocol changes what she SOUNDS like, not just how loud she is, so
## it is part of the cache key. Read through the tree rather than held, because
## the player can toggle it mid-run from the accessibility menu.
static func _dampened() -> bool:
	var audio: Node = _autoload(&"Audio")
	return audio != null and bool(audio.get("dampened"))


# ==========================================================================
# THE WORKER
# ==========================================================================

class _Job extends RefCounted:
	var key: String = ""
	var text: String = ""
	var register: String = ""
	var dampened: bool = false

	## The pool calls this. Publishing the result and retiring the job happen in
	## ONE locked step — see `_finish`. Doing them separately let `flush()` observe
	## an empty job list a few microseconds before the cache entry existed, which
	## is a race that only ever fires in the selftest and only ever looks like a
	## cache bug.
	func run() -> void:
		var t0: int = Time.get_ticks_usec()
		var params: Dictionary = VoiceRegisters.params(register)
		if dampened:
			params = VoiceRegisters.dampen(params)
		var samples: PackedFloat32Array = MotherVoice._synthesise(
				text, params, register, false)
		var rep: Dictionary = VoiceMeter.normalise_to(samples, MotherVoice.RATE,
				float(VoiceRegisters.TARGET_LUFS.get(register, -23.0)),
				VoiceRegisters.CEILING_DBTP)
		MotherVoice._finish(self, key, samples, rep, Time.get_ticks_usec() - t0)


## Publish a finished utterance and retire its job, atomically.
##
## The atomicity is the point: a waiter (the selftest's `flush`, and nothing in
## the game) decides "she is ready" by seeing no jobs and no queue, so the job
## must not disappear from the list before its audio appears in the cache.
static func _finish(job: RefCounted, key: String, samples: PackedFloat32Array,
		rep: Dictionary, usec: int) -> void:
	var pcm: PackedByteArray = VoiceWav.pcm16(samples)
	_mutex.lock()
	var waiting: Array = _waiters.get(key, []) as Array
	_waiters.erase(key)
	if pcm.is_empty():
		# Nothing to say — an empty string, or a token the rules reduced to no
		# phonemes at all. Remembered so callers stop waiting on it forever.
		_unspeakable[key] = true
	else:
		_clock += 1
		_cache[key] = {
			"pcm": pcm, "seconds": float(samples.size()) / float(RATE),
			"lufs": rep["lufs"], "dbtp": rep["dbtp"], "used": _clock,
		}
		_bytes += pcm.size()
	_pending.erase(key)
	_jobs.erase(job)
	_stat_synth += 1
	_stat_us += usec
	_evict()
	_mutex.unlock()
	_pump()
	# Back onto the main thread before anyone touches a player or a caption.
	for cb: Callable in waiting:
		if cb.is_valid():
			cb.call_deferred()


## LRU eviction. Called with the mutex held.
static func _evict() -> void:
	while _bytes > CACHE_BYTES and _cache.size() > 1:
		var oldest: String = ""
		var oldest_t: int = 1 << 62
		for k: Variant in _cache:
			var e: Dictionary = _cache[k] as Dictionary
			if int(e["used"]) < oldest_t:
				oldest_t = int(e["used"])
				oldest = String(k)
		if oldest.is_empty():
			return
		_bytes -= (_cache[oldest] as Dictionary)["pcm"].size()
		_cache.erase(oldest)


## Start jobs until MAX_JOBS are in flight. Safe to call from any thread.
static func _pump() -> void:
	_mutex.lock()
	while _jobs.size() < MAX_JOBS and not _queue.is_empty():
		var item: Dictionary = _queue.pop_front()
		var job: _Job = _Job.new()
		job.key = String(item["key"])
		job.text = String(item["text"])
		job.register = String(item["register"])
		job.dampened = bool(item["dampened"])
		_jobs.append(job)
		# The pool owns the thread and the engine waits on it at shutdown, which
		# a bare Thread does not — and a Thread left running at quit is a hard
		# error in Godot, not a warning.
		WorkerThreadPool.add_task(job.run, false, "MotherVoice")
	_mutex.unlock()


## Cache and timing figures, for `--selftest` and for the bench.
static func stats() -> Dictionary:
	_mutex.lock()
	var out: Dictionary = {
		"entries": _cache.size(), "bytes": _bytes,
		"pending": _pending.size(), "queued": _queue.size(),
		"jobs": _jobs.size(),
		"hits": _stat_hits, "misses": _stat_misses,
		"synthesised": _stat_synth, "spoken_late": _stat_late,
		"avg_ms": (float(_stat_us) / 1000.0 / float(maxi(_stat_synth, 1))),
	}
	_mutex.unlock()
	return out


## Block until every queued line is synthesised. THE BENCH AND THE SELFTEST ONLY
## — nothing in the game may wait on her voice.
static func flush(timeout_ms: int = 30000) -> void:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		_mutex.lock()
		var busy: bool = not _queue.is_empty() or not _jobs.is_empty()
		_mutex.unlock()
		if not busy:
			return
		OS.delay_msec(4)


## `BP_VOICE_LIVE=0` puts her back on the fifteen baked cues, for A/B against the
## register she was auditioned in. Read once, lazily, because a static class has
## no `_ready` to read it in and this must not cost an environment lookup per
## bark. Anything other than "0" leaves the live voice on, so a typo cannot
## silently ship the old voice.
static func _live() -> bool:
	if not _env_read:
		_env_read = true
		if OS.get_environment("BP_VOICE_LIVE").strip_edges() == "0":
			_enabled = false
			print("[Voice] BP_VOICE_LIVE=0 — runtime synthesis off, baked cues only")
	return _enabled


static func set_enabled(on: bool) -> void:
	_env_read = true
	_enabled = on


static func clear() -> void:
	_mutex.lock()
	_cache.clear()
	_unspeakable.clear()
	_bytes = 0
	_mutex.unlock()
