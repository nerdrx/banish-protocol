class_name VoiceRegisters
extends RefCounted
## M14 — the three registers, and the one knob that matters in each.
##
## These are the swap points, exactly as the baked cue lists in AudioService used
## to be: change a number here and she sounds different, with no other change
## anywhere in the tree. The registers correspond one-to-one with the tiers the
## voice path already has, so nothing downstream had to learn a new vocabulary.
##
##   MURMUR    she is in the walls, two rooms over, talking to herself. Slower,
##             lower, darker, and the only register that keeps the tape damage
##             turned up — it is a bed, not information, and if you miss a word
##             of it nothing is lost. Target -34 LUFS.
##   DIRECTED  she is in the channel, saying your callsign. THIS ONE HAS TO BE
##             UNDERSTOOD. Hyper-articulated (clarity 1.10), no dropouts, no
##             print-through, a presence lift at 2.6 kHz, and only enough wow and
##             hiss to place her in the fiction. Target -23 LUFS.
##             SETTLED BY AUDITION, 2026-08-03: the user heard this register both
##             dry and with the chain on and passed it. These tape numbers are no
##             longer a guess and should not be moved without a fresh audition —
##             the depth of this chain is the whole difference between "a machine
##             recorded on old gear" and "words the tape ate".
##   SUBZERO   Below the Kernel. Nearest and quietest at once: proximity shelf,
##             no room at all, heavy creak, a thread of whisper. Still legible —
##             the whisper is 0.30, not 1.0, because the register got its horror
##             from being intimate and not from being unintelligible.
##             HONEST LIMIT: this register lands about 1.5 dB under its -27 LUFS
##             target because the -3 dBTP ceiling catches it first. Creak plus
##             whisper is a genuinely peaky waveform — measured crest 25.4 dB
##             against the baked cue's 24 — and `tools/voice/sweep.gd` shows the
##             record amp buys under 2 dB across its whole useful range, at which
##             point it is squashing the register's dynamics to chase a number.
##             Quieter than intended is the safe direction, so it stands.
##
## THE CLARITY FIGURE is the one number to reach for first if a listener cannot
## make her out. It scales every vowel formant away from neutral, which is
## hyper-articulation — physically what a person does when they need to be
## understood across a room. Above about 1.20 the vowel space distorts and she
## starts to sound like a cartoon; below 1.0 she mumbles.

const MURMUR: String = "murmur"
const DIRECTED: String = "directed"
const SUBZERO: String = "subzero"
const CLEAN: String = "clean"

## Loudness targets, unchanged from the baked masters so a live line and a baked
## one sit at the same place in the mix. Deliberately far apart: the tiers must
## be distinguishable with the player's hand nowhere near a volume control.
const TARGET_LUFS: Dictionary = {
	"murmur": -34.0, "directed": -23.0, "subzero": -27.0, "clean": -23.0,
}
const CEILING_DBTP: float = -3.0

## Audio event key -> register. The keys are AudioService's, and they are the
## whole of the coupling between this module and the mixer.
const EVENT_REGISTER: Dictionary = {
	"mother_murmur": "murmur",
	"mother_address": "directed",
	"mother_close": "subzero",
}


static func register_for_event(key: StringName) -> String:
	return String(EVENT_REGISTER.get(String(key), DIRECTED))


## Everything one register needs: prosody, source, and post.
static func params(name: String) -> Dictionary:
	match name:
		MURMUR:
			return {
				"frames": {
					"rate": 0.86, "f0": 102.0, "declination": -0.14,
					"accent": 1.3, "terminal": -2.6, "final_lengthen": 1.7,
					"word_gap": 0.030, "lead_in": 0.30, "tail": 0.75,
					"breathiness": 0.22, "whisper": 0.0, "clarity": 1.00,
				},
				"klatt": {
					"creak": 0.16, "jitter": 0.0026, "open_quotient": 0.46,
					"fric_gain": 0.85, "asp_gain": 1.15,
				},
				"tape": {
					"reverb_mix": 0.55, "reverb_rt60": 1.9, "reverb_damp": 2200.0,
					"reverb_predelay": 0.018, "proximity": 0.0,
					"comp": 0.34, "comp_ratio": 4.0,
					"wow": 0.0026, "wow_hz": 0.48, "flutter": 0.0012,
					"sat": 1.2, "print_through_db": -52.0,
					"dropouts": 0.28, "dropout_depth": 0.62,
					"head_bump_db": 3.0, "azimuth_hz": 4200.0,
					"presence_db": 1.5, "presence_hz": 2400.0,
					"hiss_db": -56.0,
				},
			}
		SUBZERO:
			return {
				"frames": {
					"rate": 0.84, "f0": 90.0, "declination": -0.13,
					"accent": 1.1, "terminal": -2.8, "final_lengthen": 1.8,
					"word_gap": 0.034, "lead_in": 0.26, "tail": 0.70,
					"breathiness": 0.42, "whisper": 0.30, "clarity": 1.08,
				},
				"klatt": {
					"creak": 0.40, "jitter": 0.0048, "open_quotient": 0.52,
					"fric_gain": 1.0, "asp_gain": 1.35,
				},
				"tape": {
					"reverb_mix": 0.10, "reverb_rt60": 0.28, "reverb_damp": 6000.0,
					"reverb_predelay": 0.004, "proximity": 1.15,
					"comp": 0.08, "comp_ratio": 6.0,
					"wow": 0.0012, "wow_hz": 0.44, "flutter": 0.0007,
					"sat": 1.15, "print_through_db": -54.0,
					"dropouts": 0.0, "dropout_depth": 0.0,
					"head_bump_db": 3.5, "azimuth_hz": 10000.0,
					"presence_db": 2.5, "presence_hz": 3000.0,
					"hiss_db": -62.0,
				},
			}
		CLEAN:
			# The bench register: the synthesiser with nothing on top of it. Used
			# to tell "she is unintelligible" apart from "the tape ate her", which
			# are different bugs with different fixes.
			return {
				"frames": {
					"rate": 0.95, "f0": 118.0, "declination": -0.15,
					"accent": 1.5, "terminal": -3.0, "final_lengthen": 1.55,
					"word_gap": 0.028, "lead_in": 0.12, "tail": 0.30,
					"breathiness": 0.05, "whisper": 0.0, "clarity": 1.10,
				},
				"klatt": {
					"creak": 0.0, "jitter": 0.0012, "open_quotient": 0.42,
					"fric_gain": 1.0, "asp_gain": 1.0,
				},
				"tape": {"reverb_mix": 0.0, "comp": 0.0, "wow": 0.0,
					"flutter": 0.0, "sat": 0.0, "dropouts": 0.0,
					"head_bump_db": 0.0, "azimuth_hz": 20000.0,
					"hiss_db": -120.0, "presence_db": 0.0},
			}
		_:
			return {
				"frames": {
					"rate": 0.95, "f0": 118.0, "declination": -0.16,
					"accent": 1.5, "terminal": -3.2, "final_lengthen": 1.55,
					"word_gap": 0.030, "lead_in": 0.14, "tail": 0.34,
					"breathiness": 0.07, "whisper": 0.0, "clarity": 1.10,
				},
				"klatt": {
					"creak": 0.14, "jitter": 0.0018, "open_quotient": 0.42,
					"fric_gain": 1.0, "asp_gain": 1.0,
				},
				"tape": {
					"reverb_mix": 0.20, "reverb_rt60": 0.55, "reverb_damp": 4200.0,
					"reverb_predelay": 0.009, "proximity": 0.35,
					"comp": 0.30, "comp_ratio": 4.0,
					"wow": 0.0013, "wow_hz": 0.52, "flutter": 0.0007,
					"sat": 1.10, "print_through_db": -90.0,
					"dropouts": 0.0, "dropout_depth": 0.0,
					"head_bump_db": 2.5, "azimuth_hz": 11000.0,
					"presence_db": 3.0, "presence_hz": 2600.0,
					"hiss_db": -64.0,
				},
			}


## Dampened Protocol's audio half, applied to the SYNTHESIS rather than only to
## the bus. The comfort tier promises "no spikes", and the sharp things in her
## voice are structural — dropouts, print-through, hard bursts — so turning the
## whole line down leaves the edges exactly as abrupt. This softens the source.
static func dampen(p: Dictionary) -> Dictionary:
	var tape: Dictionary = (p["tape"] as Dictionary).duplicate()
	tape["dropouts"] = 0.0
	tape["print_through_db"] = -90.0
	tape["sat"] = minf(float(tape.get("sat", 1.0)), 0.9)
	tape["azimuth_hz"] = minf(float(tape.get("azimuth_hz", 9000.0)), 7000.0)
	var klatt: Dictionary = (p["klatt"] as Dictionary).duplicate()
	klatt["creak"] = float(klatt.get("creak", 0.0)) * 0.4
	var out: Dictionary = p.duplicate()
	out["tape"] = tape
	out["klatt"] = klatt
	return out
