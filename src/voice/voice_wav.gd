class_name VoiceWav
extends RefCounted
## M14 — buffers to playable audio, and to files for auditioning.
##
## The game path is `to_stream`: a 16-bit mono `AudioStreamWAV` handed straight
## to the AudioStreamPlayer the voice tier already owns. No import step, no
## resource path, no disk — a runtime voice that wrote files would be a runtime
## voice that needed a writable directory on a shipped build.
##
## `write_file` exists for the bench and the selftest. It is a hand-rolled RIFF
## writer rather than anything Godot-side, because Godot has no WAV *encoder* and
## the alternative (an ogg round trip through ffmpeg) is not available at runtime.

const HEAD_ROOM: float = 0.995


## Float samples -> a stream the mixer can play. 16-bit because that is what
## AudioStreamWAV supports without a format conversion on our side, and because
## the cassette noise floor is 40 dB above the 16-bit one.
static func to_stream(samples: PackedFloat32Array, rate: int) -> AudioStreamWAV:
	var stream: AudioStreamWAV = AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = false
	stream.data = pcm16(samples)
	return stream


static func write_file(path: String, samples: PackedFloat32Array, rate: int) -> bool:
	var pcm: PackedByteArray = pcm16(samples)
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[Voice] cannot write %s" % path)
		return false
	var data_len: int = pcm.size()
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + data_len)
	f.store_buffer("WAVE".to_ascii_buffer())
	f.store_buffer("fmt ".to_ascii_buffer())
	f.store_32(16)
	f.store_16(1)          # PCM
	f.store_16(1)          # mono
	f.store_32(rate)
	f.store_32(rate * 2)   # byte rate
	f.store_16(2)          # block align
	f.store_16(16)         # bits
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(data_len)
	f.store_buffer(pcm)
	f.close()
	return true


static func pcm16(samples: PackedFloat32Array) -> PackedByteArray:
	var out: PackedByteArray = PackedByteArray()
	out.resize(samples.size() * 2)
	for i: int in samples.size():
		var v: float = clampf(samples[i], -HEAD_ROOM, HEAD_ROOM)
		var s: int = int(round(v * 32767.0))
		out.encode_s16(i * 2, s)
	return out


## Peak-normalise in place, for the bench only. The shipping path normalises to
## LUFS through `VoiceMeter`; a peak normalise on material that is mostly silence
## is exactly the mistake the loudness meter exists to prevent.
static func peak_normalise(samples: PackedFloat32Array, to: float = 0.9) -> PackedFloat32Array:
	var peak: float = 0.0
	for v: float in samples:
		peak = maxf(peak, absf(v))
	if peak <= 1e-9:
		return samples
	var g: float = to / peak
	for i: int in samples.size():
		samples[i] = samples[i] * g
	return samples
