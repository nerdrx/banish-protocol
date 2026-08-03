#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — SOUND LAB: sound classes and their objective functions.
#
# This is the opinionated file. Everything else in tools/soundlab/ measures; this
# one says what the measurements SHOULD be, per class, and why.
#
# HOW TO READ A CRITERION
# ----------------------
#   Crit("band_sub", "min", 0.06, soft=0.03, w=2.0, why="...")
#
#   feature   a key from descriptors.FEATURES
#   kind      "min"   -> want >= target
#             "max"   -> want <= target
#             "band"  -> want target[0] <= v <= target[1]
#   soft      the width of the penalty ramp. A value exactly at the target
#             scores 1.0; one `soft` past it scores ~0.37 (exp falloff), so the
#             objective is smooth and an optimiser can climb it. Hard cliffs
#             make search harnesses stall; this is why nothing here is a
#             boolean.
#   w         weight. The class score is the weighted mean of criterion scores,
#             so weights are relative within a class only.
#
# HONESTY ABOUT THE TARGETS
# -------------------------
# Three kinds of number appear below, and they are labelled in `why`:
#   [PHYS]  physically or perceptually grounded — an attack under ~10 ms is what
#           makes a transient read as an impact rather than as a swell; energy
#           below 80 Hz is the only thing a subwoofer can reproduce; a decaying
#           centroid is what every struck object in the physical world does.
#   [FIT]   read off the shipped library's own best-sounding members, i.e. an
#           empirical house style rather than a law. These are the ones to argue
#           with.
#   [CALL]  a judgement call about what BANISH PROTOCOL wants specifically, from
#           DESIGN.md. Someone else's horror game could reasonably invert them.
#
# The quiet-instrument rule (DESIGN.md M4.9) is the reason several classes have
# a MAXIMUM loudness and a maximum sharpness rather than a minimum: in this game
# a confirm that fires every few seconds must not become the firefight.
#
# THE CREST CHEAT — FOUND BY THE SEARCH, FIXED IN THE REMASTER
# ------------------------------------------------------------
# An optimiser will exploit any criterion that can be satisfied by a cheat, and
# it found one: `crest_db` used to be peak divided by the RMS of the WHOLE
# FILE, so inserting a stretch of silence in the middle of a sound raised it
# for free. The impact_heavy shortlist visibly did this — several winners had a
# ~250 ms hole between the break and the debris, and the weapon_fire winners
# were over half dead air. Nothing about that hole was good; it was an artefact
# of the measurement, not a property of a good impact.
#
# APPLIED (sound remaster). `descriptors.crest_db` now divides by the RMS of
# the sound's ACTIVE region — every 10 ms window within 40 dB of the envelope
# peak, expanded back to samples — and `silence_frac` reports what was
# excluded. Every event class that scores crest_db now also caps silence_frac,
# so a gap is a penalty instead of a free gain. Measured effect on the shipped
# library: crest never rose, and fell by up to 4.5 dB on files that are more
# than half dead air (the UI clicks). Effect on the search: see the remaster's
# SEARCH_RESULTS — the impact_heavy and weapon_fire shortlists it had produced
# do not survive it, which was the point.
#
# The general lesson stands and is worth more than the fix: LOOK AT THE
# WAVEFORM of any winner before adopting it. charts.py --compare exists for
# exactly this.
# ---------------------------------------------------------------------------
from __future__ import annotations

import math
import re
from dataclasses import dataclass, field


@dataclass
class Crit:
    feature: str
    kind: str                  # "min" | "max" | "band"
    target: float | tuple
    soft: float
    w: float = 1.0
    why: str = ""

    def score(self, v: float) -> float:
        """1.0 inside spec, decaying exponentially outside. Never zero, so an
           optimiser always has a gradient to follow out of a bad region."""
        if self.kind == "min":
            d = max(self.target - v, 0.0)
        elif self.kind == "max":
            d = max(v - self.target, 0.0)
        else:
            lo, hi = self.target
            d = max(lo - v, 0.0) + max(v - hi, 0.0)
        if d <= 0.0:
            return 1.0
        return math.exp(-d / max(self.soft, 1e-9))


@dataclass
class SoundClass:
    name: str
    blurb: str
    crits: list[Crit] = field(default_factory=list)
    # A prompt for the semantic (CLAP) scorer. Only used if CLAP is available.
    clap_positive: list[str] = field(default_factory=list)
    clap_negative: list[str] = field(default_factory=list)
    scored: bool = True        # False = measured but not graded (music, voice)

    def score(self, d: dict) -> tuple[float, list[tuple[str, float, float]]]:
        """Returns (0..1 score, [(feature, value, criterion score)])."""
        parts, wsum, acc = [], 0.0, 0.0
        for c in self.crits:
            v = float(d.get(c.feature, 0.0))
            s = c.score(v)
            parts.append((c.feature, v, s))
            acc += s * c.w
            wsum += c.w
        return (acc / wsum if wsum else 0.0), parts

    def failures(self, d: dict, thresh: float = 0.6) -> list[str]:
        out = []
        for c in self.crits:
            v = float(d.get(c.feature, 0.0))
            if c.score(v) < thresh:
                tgt = (("%.3g-%.3g" % c.target) if c.kind == "band"
                       else "%.3g" % c.target)
                out.append("%s=%.3g (want %s %s)" % (c.feature, v, c.kind, tgt))
        return out


# ---------------------------------------------------------------------------
# The taxonomy. First matching pattern wins, so order matters: specific before
# general.
# ---------------------------------------------------------------------------
ROUTES: list[tuple[str, str]] = [
    (r"/mus_", "music"),
    (r"/mv_", "voice_mother"),
    (r"player_breath_|player_corruption_downed_|player_pulse_low_cycles", "player_body_loop"),
    (r"player_hurt_|player_death_delete", "player_vocal"),
    (r"player_footstep_|player_land_", "footfall"),
    (r"sub_step_whump|sub_stack_pulse", "impact_heavy"),
    (r"bulkhead_seal_slam|sentinel_death_collapse", "impact_heavy"),
    (r"death_shatter|player_death|flare_die", "death_shatter"),
    (r"breaker_shot_", "weapon_fire"),
    (r"sentinel_purge_strike", "creature_attack"),
    (r"breaker_|weld_|flare_", "weapon_mech"),
    (r"hound_howl", "creature_call"),
    (r"scrubber_alert|sentinel_scan_sweep|scrubber_lunge_shriek", "creature_windup"),
    (r"scrubber_hurt|sentinel_core_hit", "creature_hurt"),
    (r"scrubber_idle_chitter", "creature_idle"),
    (r"skitter_loop|prowl_loop|glide_stutter", "creature_locomotion"),
    (r"presence_drone_loop", "creature_presence"),
    (r"klaxon|patch_watchdog|exfil_countdown_tick", "alarm"),
    (r"datachip_pickup|patch_pickup", "pickup"),
    (r"debris_clatter", "debris"),
    (r"terminal_key_click|ui_gauge_tick|ui_menu_hover_tick|ui_selftest_beep", "ui_tick"),
    (r"ui_refusal|ui_sub_refused|ui_menu_back", "ui_negative"),
    (r"ui_hit_confirm|ui_menu_select_clack|ui_purchase_success|ui_sub_ready|ui_toast_reveal", "ui_confirm"),
    (r"^ui/|ui_", "ui_other"),
    # ui_shaft_siphon is deliberately NOT here: make_sfx.py describes it as "a
    # pool filling, not an event", which is a UI swell and not a whoosh.
    (r"dropshaft_rush|dropshaft_descent", "whoosh"),
    (r"rewire_switch_clunk|cabinet_creak_open|patch_cache_open|cabinet_lock_cut", "mechanism"),
    (r"bulkhead_mother_reopen", "mechanism"),
    (r"loop\.ogg$|compiler_hum|^ambient/|amb_", "ambience_bed"),
    (r".*", "misc"),
]


def classify(rel: str) -> str:
    for pat, name in ROUTES:
        if re.search(pat, rel):
            return name
    return "misc"


# ---------------------------------------------------------------------------
# The objective functions.
# ---------------------------------------------------------------------------

def _C(*a, **k) -> Crit:
    return Crit(*a, **k)


CLASSES: dict[str, SoundClass] = {}


def _add(c: SoundClass) -> None:
    CLASSES[c.name] = c


_add(SoundClass(
    "footfall",
    "A hunter's step. The single most important sound in a stalker game: it is "
    "how the player locates a thing they cannot see, and it has to arrive as "
    "WEIGHT before it arrives as information.",
    crits=[
        _C("band_sub", "min", 0.06, soft=0.04, w=2.0,
           why="[PHYS] A step from something heavy is a floor deflecting. Below "
               "80 Hz is the only band that says 'mass'; without it the ear "
               "hears a tap regardless of level. 6 % of total power is the "
               "point at which it is audible on a soundbar."),
        _C("weight_db", "min", -6.0, soft=4.0, w=1.5,
           why="[PHYS] Sub+low together should own most of the sound's energy. "
               "-6 dB = a quarter of the power in the bottom two bands."),
        _C("attack_ms", "max", 8.0, soft=6.0, w=2.0,
           why="[PHYS] A footfall is an impact. 10-90 % rise beyond ~10 ms and "
               "the ear stops hearing a strike and starts hearing a swell; the "
               "boundary is around 8 ms for broadband material."),
        _C("crest_db", "min", 12.0, soft=5.0, w=1.5,
           why="[PHYS] The peak-to-RMS ratio IS the punch. It must be measured "
               "AFTER loudness normalisation (which the whole library is), "
               "because a squashed source cannot get it back downstream."),
        _C("centroid_drop_oct", "min", 0.5, soft=0.5, w=2.0,
           why="[PHYS] The most important line in this file. A real impact is "
               "bright at the strike and dark in the ring-out, because the "
               "high partials radiate away first. A sound whose spectrum does "
               "not fall over its decay reads as synthetic no matter what else "
               "is right, and that is the number-one cause of 'generic'."),
        _C("decay_t60_ms", "band", (120.0, 900.0), soft=200.0, w=1.0,
           why="[CALL] Long enough to imply a room, short enough to fire twice "
               "a second at a walk without turning into mud."),
        _C("duration_s", "band", (0.15, 0.9), soft=0.2, w=0.5,
           why="[CALL] Under 0.15 s there is no tail to imply a space."),
        _C("hnr_db", "max", 6.0, soft=5.0, w=1.0,
           why="[PHYS] A footstep is not pitched. High HNR means a sine is "
               "showing through, which is the classic synthetic-kick tell."),
        _C("bw20_oct", "min", 4.0, soft=1.5, w=1.0,
           why="[PHYS] Real impacts excite everything. Under four octaves "
               "within 20 dB of peak and the sound is a filtered tone."),
        _C("silence_frac", "max", 0.12, soft=0.10, w=1.0,
           why="[PHYS] Crest is a criterion here, so the gap cheat is "
               "available here. Shipped footfalls sit at 0.03-0.11."),
    ],
    clap_positive=["a heavy metal footstep of a huge machine on a metal floor",
                   "massive industrial footfall, deep thud, cavernous room",
                   "the heavy step of a large creature, deep impact with rumble"],
    clap_negative=["a light tap on a table", "a high pitched digital beep",
                   "a synthesizer bass note"],
))

_add(SoundClass(
    "impact_heavy",
    "Something enormous meets something solid: a bulkhead sealing, a Sentinel "
    "hitting the deck, the surge step's whump. Allowed to be the loudest thing "
    "in the room.",
    crits=[
        _C("band_sub", "min", 0.10, soft=0.06, w=2.5,
           why="[PHYS] Same physics as the footfall, further. The single "
               "descriptor that separates 'big' from 'loud'."),
        _C("attack_ms", "max", 6.0, soft=5.0, w=2.0,
           why="[PHYS] Metal-on-metal contact is effectively instantaneous."),
        _C("crest_db", "min", 13.0, soft=5.0, w=1.5,
           why="[PHYS] See footfall. A heavy impact that survives BS.1770 "
               "normalisation with 13 dB of crest still hits."),
        _C("centroid_drop_oct", "min", 1.0, soft=0.7, w=2.5,
           why="[PHYS] The bigger the object, the more dramatically it darkens: "
               "a struck girder loses two octaves of centroid in its first "
               "200 ms. This is the descriptor to optimise hardest."),
        _C("decay_t60_ms", "band", (400.0, 3000.0), soft=500.0, w=1.0,
           why="[CALL] The tail is the room. A big impact in a big space should "
               "keep speaking for the better part of a second."),
        _C("bw20_oct", "min", 5.0, soft=1.5, w=1.0,
           why="[PHYS] A real collision is broadband by definition."),
        _C("roughness", "min", 0.5, soft=0.5, w=1.0,
           why="[FIT] Some grind in the tail. A perfectly smooth decay is a "
               "reverb tail, not a structure complaining."),
        _C("silence_frac", "max", 0.12, soft=0.10, w=1.5,
           why="[PHYS] The criterion that closes the crest cheat. This is the "
               "class the optimiser exploited it in: shipped impacts sit at "
               "0.01-0.08 dead air, and half the winning shortlist sat at "
               "0.34-0.55 — a 250 ms hole between the break and the debris, "
               "which is not a property of a good impact but of a bad "
               "denominator. Weighted highest here because here it was found."),
    ],
    clap_positive=["a huge metal impact, massive crash, deep boom",
                   "an enormous industrial slam with a long cavernous tail",
                   "heavy machinery crashing down, deep low frequency impact"],
    clap_negative=["a small click", "a soft pop", "a musical chord"],
))

_add(SoundClass(
    "creature_windup",
    "The tell. A wind-up exists so the player has 300-600 ms to make a "
    "decision, so it must be UNMISTAKABLE and it must RISE — a threat that "
    "does not escalate over its own length is just a noise.",
    crits=[
        _C("centroid_slope_oct_per_s", "min", 0.4, soft=0.5, w=2.5,
           why="[PHYS] Rising spectrum = approaching / accelerating / "
               "escalating. This is the inverse of the impact rule and the "
               "reason wind-ups need their own class rather than a generic "
               "'creature' bucket."),
        _C("duration_s", "band", (0.35, 1.6), soft=0.3, w=1.5,
           why="[CALL] Shorter than 0.35 s and the player cannot act on it; "
               "longer than ~1.6 s and the tell stops being a tell."),
        _C("roughness", "min", 1.5, soft=1.0, w=2.0,
           why="[PHYS] Roughness (amplitude modulation around 70 Hz) is the "
               "measurable correlate of 'snarl'. A smooth rising tone is a "
               "siren; a rough one is an animal."),
        _C("env_range_db", "min", 12.0, soft=6.0, w=1.5,
           why="[PHYS] It has to grow. A flat envelope cannot signal a "
               "commitment about to happen."),
        _C("bw20_oct", "min", 3.5, soft=1.5, w=1.0,
           why="[PHYS] Vocal-tract-like sources are broadband."),
        _C("hnr_db", "band", (-6.0, 12.0), soft=6.0, w=1.0,
           why="[FIT] Partly pitched, partly noise. Pure noise is wind; pure "
               "tone is a machine. A throat is between them."),
        _C("attack_ms", "band", (8.0, 120.0), soft=40.0, w=0.8,
           why="[CALL] A wind-up should NOT click on. It is a breath being "
               "taken, not an event firing."),
    ],
    clap_positive=["a monster growling and building up to an attack",
                   "a creature snarling, rising aggressive vocalisation",
                   "a menacing mechanical creature charging up, rising whine"],
    clap_negative=["a calm ambient drone", "a musical note", "a door closing"],
))

_add(SoundClass(
    "death_shatter",
    "Something stops existing. The payoff sound of the game loop; it is allowed "
    "to be complicated, and it should have at least two distinct events in it "
    "(the break, then the collapse).",
    crits=[
        _C("centroid_drop_oct", "min", 1.0, soft=0.8, w=2.0,
           why="[PHYS] Bright shatter, dark debris. Same physics as an impact."),
        _C("flux", "min", 0.05, soft=0.04, w=2.0,
           why="[PHYS] Spectral flux measures how much the spectrum CHANGES "
               "frame to frame. A death sound with low flux is a single gesture "
               "and will read as thin; a good one is a sequence."),
        _C("duration_s", "band", (0.5, 3.0), soft=0.6, w=1.0,
           why="[CALL] Long enough to be an event the player watches."),
        _C("band_sub", "min", 0.04, soft=0.03, w=1.5,
           why="[PHYS] The collapse half needs weight or the death reads as a "
               "sound effect rather than as a consequence."),
        _C("env_range_db", "min", 16.0, soft=6.0, w=1.5,
           why="[PHYS] Two events means the envelope must go down between "
               "them. A monotonic decay is one event."),
        _C("bw20_oct", "min", 5.0, soft=1.5, w=1.0,
           why="[PHYS] Breakage is broadband."),
        _C("silence_frac", "max", 0.18, soft=0.12, w=1.0,
           why="[PHYS] Looser than impact_heavy on purpose: this class is "
               "explicitly asked for TWO events with a valley between them, so "
               "some quiet in the middle is the brief. What it may not do is "
               "buy crest with a hole — 0.18 permits a real gap and refuses a "
               "half-empty file."),
    ],
    clap_positive=["glass and metal shattering then collapsing into rubble",
                   "a machine breaking apart and falling to pieces",
                   "a violent destruction, shatter followed by debris"],
    clap_negative=["a smooth synthesiser pad", "a single beep"],
))

_add(SoundClass(
    "weapon_fire",
    "The breaker discharging. Fires hundreds of times a run, so it must be "
    "short, must have a transient, and must not fatigue.",
    crits=[
        _C("attack_ms", "max", 4.0, soft=4.0, w=3.0,
           why="[PHYS] A discharge is an instantaneous event. This is the "
               "highest-weighted criterion in the file: a weapon whose loudest "
               "moment arrives tens of milliseconds after the trigger feels "
               "disconnected from the input, and no amount of EQ fixes it."),
        _C("peak_time_ms", "max", 12.0, soft=10.0, w=2.0,
           why="[PHYS] Time-to-peak, measured separately from the 10-90 rise, "
               "because a sound can have a fast rise late. The player's finger "
               "moved at t=0."),
        _C("crest_db", "min", 14.0, soft=5.0, w=2.0,
           why="[PHYS] Punch, post-normalisation."),
        _C("centroid_drop_oct", "min", 0.6, soft=0.5, w=1.5,
           why="[PHYS] Crack then body. The bright crack must die first."),
        _C("duration_s", "band", (0.12, 0.6), soft=0.2, w=1.0,
           why="[CALL] Under 0.6 s or successive shots comb into porridge at "
               "the fire rate."),
        _C("band_low", "min", 0.10, soft=0.08, w=1.5,
           why="[FIT] The 80-250 Hz band is where a weapon gets its authority. "
               "Our breaker currently lives almost entirely above 1 kHz."),
        _C("band_sub", "min", 0.04, soft=0.03, w=1.5,
           why="[PHYS] Added in the remaster. The original objective set a "
               "minimum on band_low only, and the weapon recipe's lowest "
               "oscillator was floored at 60 Hz — so every shortlisted "
               "candidate measured band_sub = 0.000 and the objective never "
               "complained. A search can only find what its space contains and "
               "will not tell you what the space is missing; the criterion and "
               "the sub layer in synth.py were added together. 4 % rather than "
               "the impact's 10 % because a rifle is not a bulkhead: enough to "
               "be felt in the chest, not enough to be a kick drum."),
        _C("silence_frac", "max", 0.12, soft=0.10, w=1.0,
           why="[PHYS] See the header. Shipped one-shots sit at 0.01-0.16; the "
               "weapon_fire winners this replaces sat at 0.43-0.59, i.e. over "
               "half dead air, which is what bought them their crest."),
        _C("sharpness_acum", "max", 2.6, soft=0.6, w=1.0,
           why="[PHYS] Zwicker sharpness above ~2.6 acum is the listener-"
               "fatigue region. A gun fired 400 times a run must sit below it."),
    ],
    clap_positive=["a sharp energy weapon discharge, electric crack with a low thump",
                   "a powerful gunshot, sharp crack and deep body",
                   "a sci-fi rifle firing, punchy and aggressive"],
    clap_negative=["a long ambient drone", "a soft whoosh", "a musical chime"],
))

_add(SoundClass(
    "ui_tick",
    "The interface's smallest unit. It fires constantly, so the objective is "
    "mostly about what it must NOT do.",
    crits=[
        _C("duration_s", "max", 0.12, soft=0.06, w=2.0,
           why="[CALL] Quiet-instrument rule. A tick that outlives the gesture "
               "that caused it becomes a sound effect."),
        _C("attack_ms", "max", 3.0, soft=3.0, w=1.5,
           why="[PHYS] A tick IS its transient."),
        _C("sharpness_acum", "max", 3.2, soft=0.5, w=2.0,
           why="[PHYS] The fatigue ceiling again, and the reason a UI set gets "
               "described as 'shrill'. Sharpness, not brightness, is what the "
               "ear objects to."),
        _C("lufs_i", "max", -22.0, soft=4.0, w=1.5,
           why="[CALL] DESIGN.md M4.9. It must sit under everything."),
        _C("decay_linearity", "min", 0.7, soft=0.25, w=1.0,
           why="[PHYS] A clean exponential ring-out. A tick with a lumpy decay "
               "sounds like a buffer, not like a relay."),
    ],
    clap_positive=["a small mechanical relay click", "a subtle interface tick",
                   "a quiet electrical contact click"],
    clap_negative=["a loud alarm", "a deep bass impact"],
))

_add(SoundClass(
    "ui_confirm",
    "A positive acknowledgement. Same fatigue rules as the tick, plus it has to "
    "read as pleasant without becoming a fanfare.",
    crits=[
        _C("duration_s", "max", 0.45, soft=0.2, w=1.0, why="[CALL] Quiet-instrument rule."),
        _C("attack_ms", "max", 6.0, soft=5.0, w=1.0, why="[PHYS] It is an event."),
        _C("sharpness_acum", "max", 3.0, soft=0.5, w=1.5, why="[PHYS] Fatigue ceiling."),
        _C("hnr_db", "min", 2.0, soft=6.0, w=1.0,
           why="[CALL] Pitched, unlike everything organic in the game. The "
               "interface is the one place in BANISH PROTOCOL allowed to be "
               "musical, and that is how the player tells it from the world."),
        _C("roughness", "max", 1.2, soft=0.8, w=1.5,
           why="[PHYS] Roughness is the correlate of unpleasantness. A confirm "
               "with roughness reads as a warning."),
    ],
    clap_positive=["a pleasant soft interface confirmation chime",
                   "a short warm two note electronic confirmation"],
    clap_negative=["a harsh buzzer", "a monster growl"],
))

_add(SoundClass(
    "ui_negative",
    "A refusal. The one UI class that is ALLOWED to be rough — that is its job "
    "— but not allowed to be loud.",
    crits=[
        _C("roughness", "min", 1.0, soft=0.8, w=2.0,
           why="[PHYS] Roughness is how a sound says no without being loud. "
               "This is the class where the descriptor earns its keep."),
        _C("duration_s", "max", 0.35, soft=0.15, w=1.0, why="[CALL] Brief."),
        _C("lufs_i", "max", -18.0, soft=4.0, w=1.5,
           why="[CALL] A refusal is information, not an alarm (make_sfx.py "
               "already encodes this as a -18 LUFS target)."),
        _C("sharpness_acum", "max", 3.0, soft=0.6, w=1.0, why="[PHYS] Fatigue ceiling."),
    ],
    clap_positive=["a harsh electronic error buzz, a refusal",
                   "a short dissonant negative interface buzzer"],
    clap_negative=["a pleasant chime", "a calm drone"],
))

_add(SoundClass(
    "pickup",
    "An acquisition. Must be legible over a fight and must resolve.",
    crits=[
        _C("duration_s", "band", (0.15, 1.1), soft=0.3, w=1.0, why="[CALL]"),
        _C("hnr_db", "min", 3.0, soft=6.0, w=1.5,
           why="[CALL] Pitched and resolving — the crew's own hardware voice."),
        _C("attack_ms", "max", 12.0, soft=10.0, w=1.0, why="[PHYS] An event."),
        _C("sharpness_acum", "max", 3.0, soft=0.6, w=1.0, why="[PHYS] Fatigue."),
        _C("centroid_drift_oct_per_s", "min", 1.0, soft=1.5, w=1.0,
           why="[FIT] A pickup that is one static chord is the definition of "
               "'generic chime'. Some movement, in either direction."),
    ],
    clap_positive=["a rewarding item pickup chime", "a short bright acquisition sound"],
    clap_negative=["a monster roar", "a heavy impact"],
))

_add(SoundClass(
    "alarm",
    "A klaxon or a watchdog. Designed to be noticed, which makes it the class "
    "most at risk of hurting.",
    crits=[
        _C("roughness", "min", 1.0, soft=1.0, w=1.5,
           why="[PHYS] Urgency without brightness. The reason a real klaxon is "
               "modulated rather than a loud sine."),
        _C("sharpness_acum", "max", 3.4, soft=0.6, w=2.0,
           why="[PHYS] Above ~3.4 acum on a repeating cue is where players "
               "reach for the volume knob."),
        _C("env_range_db", "min", 8.0, soft=5.0, w=1.0,
           why="[PHYS] Pulsing, not droning."),
        _C("band_mid", "min", 0.10, soft=0.08, w=1.0,
           why="[PHYS] 800-2500 Hz is the ear's most sensitive band and the "
               "one that survives a busy mix."),
    ],
    clap_positive=["an industrial alarm klaxon blaring, urgent warning",
                   "an emergency siren pulsing"],
    clap_negative=["a calm chime", "a soft ambient pad"],
))

_add(SoundClass(
    "creature_locomotion",
    "Skitters, prowls, glides — looping movement. The player tracks position "
    "with these, so the priority is that they never become a static texture.",
    crits=[
        _C("flux", "min", 0.04, soft=0.03, w=2.0,
           why="[PHYS] A loop with low flux is a drone with a name. Movement "
               "must be audible frame to frame or the loop point becomes the "
               "only event in it."),
        _C("env_range_db", "min", 10.0, soft=6.0, w=2.0,
           why="[PHYS] Feet are discrete. A locomotion loop whose envelope is "
               "flat is wind, not walking."),
        _C("roughness", "min", 0.8, soft=0.8, w=1.0, why="[PHYS] Organic texture."),
        _C("band_sub", "min", 0.02, soft=0.02, w=1.0,
           why="[CALL] Even a small creature should put SOMETHING under 80 Hz "
               "into the floor, because that is the cue that survives a wall."),
    ],
    clap_positive=["skittering claws on metal, a creature moving",
                   "the sound of something walking and scraping nearby"],
    clap_negative=["a musical loop", "a steady electrical hum"],
))

_add(SoundClass(
    "creature_presence",
    "The drone that means it is in the room. Must be felt continuously without "
    "ever becoming background.",
    crits=[
        _C("band_sub", "min", 0.08, soft=0.05, w=2.0,
           why="[PHYS] Presence is a pressure sensation before it is a sound."),
        _C("flux", "min", 0.02, soft=0.02, w=1.5,
           why="[PHYS] It must breathe or the ear filters it out inside ten "
               "seconds — the reason a static drone stops being frightening."),
        _C("roughness", "min", 0.8, soft=0.8, w=1.5, why="[PHYS] Menace is rough."),
        _C("sharpness_acum", "max", 2.2, soft=0.6, w=1.0,
           why="[CALL] It plays for minutes. Sharpness must be low or the "
               "encounter becomes physically tiring."),
    ],
    clap_positive=["a menacing low mechanical drone, something huge nearby",
                   "an ominous throbbing presence, deep and unsettling"],
    clap_negative=["a pleasant pad", "a bright chime"],
))

_add(SoundClass(
    "ambience_bed",
    "The room itself. Judged almost entirely on whether it MOVES.",
    crits=[
        _C("flux", "min", 0.02, soft=0.015, w=2.0,
           why="[PHYS] Adaptation: the auditory system stops reporting a truly "
               "stationary stimulus. An ambience with no flux is silence with a "
               "CPU cost."),
        _C("centroid_drift_oct_per_s", "min", 0.5, soft=0.6, w=1.5,
           why="[PHYS] Same argument in the spectral domain."),
        _C("sharpness_acum", "max", 2.0, soft=0.5, w=1.5,
           why="[CALL] It plays for the whole level."),
        _C("band_sub", "min", 0.05, soft=0.04, w=1.0,
           why="[CALL] The station is a machine. It should be felt."),
        _C("env_range_db", "band", (4.0, 24.0), soft=6.0, w=1.0,
           why="[CALL] Some life, but a bed that lurches is a cue."),
    ],
    clap_positive=["a dark industrial room tone, distant machinery",
                   "an unsettling ambient background of a derelict space station"],
    clap_negative=["a melody", "a loud impact"],
))

_add(SoundClass(
    "mechanism",
    "Levers, bolts, hatches. The class where 'generic' is most forgivable and "
    "most common.",
    crits=[
        _C("flux", "min", 0.04, soft=0.03, w=2.0,
           why="[PHYS] A mechanism is a SEQUENCE — latch, travel, stop. One "
               "gesture is a click with reverb on it."),
        _C("env_range_db", "min", 14.0, soft=6.0, w=1.5,
           why="[PHYS] Same argument: distinct events need envelope valleys."),
        _C("attack_ms", "max", 8.0, soft=6.0, w=1.0, why="[PHYS] Contact."),
        _C("band_low", "min", 0.06, soft=0.05, w=1.0,
           why="[FIT] Mass behind the mechanism."),
        _C("bw20_oct", "min", 4.0, soft=1.5, w=1.0, why="[PHYS] Broadband contact."),
    ],
    clap_positive=["a heavy industrial lever being thrown, metal mechanism",
                   "a large bolt releasing and a hatch opening"],
    clap_negative=["a musical note", "a soft pad"],
))

_add(SoundClass(
    "debris",
    "Rubble settling. Should read as MANY objects, which is a flux and "
    "envelope-range question, not a level question.",
    crits=[
        _C("flux", "min", 0.06, soft=0.04, w=2.5,
           why="[PHYS] Many discrete impacts = high frame-to-frame spectral "
               "change. This is the whole class in one number."),
        _C("env_range_db", "min", 16.0, soft=6.0, w=2.0,
           why="[PHYS] Gaps between the pieces."),
        _C("hnr_db", "max", 4.0, soft=5.0, w=1.0, why="[PHYS] Unpitched."),
        _C("duration_s", "band", (0.3, 2.0), soft=0.4, w=1.0, why="[CALL]"),
    ],
    clap_positive=["rubble and small metal debris clattering and settling",
                   "many small pieces of scrap falling on a metal floor"],
    clap_negative=["a single tone", "a smooth whoosh"],
))

_add(SoundClass(
    "whoosh",
    "Movement through air. The one class where a static spectrum is a hanging "
    "offence, because the whole illusion is Doppler and pressure.",
    crits=[
        _C("centroid_drift_oct_per_s", "min", 1.0, soft=1.0, w=2.5,
           why="[PHYS] A whoosh IS a moving spectrum. Without drift it is hiss."),
        _C("env_range_db", "min", 12.0, soft=6.0, w=1.5,
           why="[PHYS] Approach and recede."),
        _C("band_sub", "min", 0.03, soft=0.03, w=1.0,
           why="[PHYS] Air pressure has a low component; a whoosh made only of "
               "filtered white noise is the classic thin-whoosh failure."),
        _C("hnr_db", "max", 2.0, soft=5.0, w=1.0, why="[PHYS] Air is not pitched."),
    ],
    clap_positive=["a fast whoosh of air, falling rapidly down a shaft",
                   "rushing wind passing by, sense of speed"],
    clap_negative=["a steady tone", "a click"],
))

_add(SoundClass(
    "creature_call",
    "A long-range vocalisation — the Hound's howl. Not a tell and not an "
    "attack: it exists to be heard through two walls and to tell the player "
    "which way to run. Graded on carry and on articulation, not on transient.",
    crits=[
        _C("band_low", "min", 0.10, soft=0.07, w=2.0,
           why="[PHYS] Low frequencies diffract around geometry and survive "
               "Godot's occlusion filtering. A call whose energy is all above "
               "1 kHz simply is not there once a bulkhead is in the way."),
        _C("env_range_db", "min", 12.0, soft=6.0, w=2.0,
           why="[PHYS] A howl is shaped — it swells and breaks. A flat "
               "envelope over four seconds is a synthesiser pad with a name."),
        _C("roughness", "min", 1.2, soft=0.9, w=2.0,
           why="[PHYS] The rasp is the animal. Without modulation in the "
               "60-100 Hz range this is a theremin."),
        _C("centroid_drift_oct_per_s", "min", 0.6, soft=0.6, w=1.5,
           why="[PHYS] A vocal tract moves. A static formant is the tell that "
               "nothing is producing this sound."),
        _C("duration_s", "band", (1.5, 5.0), soft=1.0, w=0.5, why="[CALL]"),
    ],
    clap_positive=["a wolf howling in a huge echoing space",
                   "a distant creature calling, long mournful howl"],
    clap_negative=["a steady electronic drone", "a machine hum"],
))

_add(SoundClass(
    "creature_attack",
    "A committed strike from an enemy — the Sentinel's purge. It is allowed a "
    "wind-up, but the STRIKE inside it has to be a real transient.",
    crits=[
        _C("env_range_db", "min", 18.0, soft=7.0, w=2.0,
           why="[PHYS] Charge, then hit. Two events need a valley between "
               "them; without one, the strike is buried in its own wind-up."),
        _C("flux", "min", 0.04, soft=0.03, w=2.0,
           why="[PHYS] Same argument, spectral side: an attack that is one "
               "continuous gesture reads as a whoosh, not as a blow."),
        _C("attack_slope_db_per_ms", "min", 2.0, soft=2.0, w=2.0,
           why="[PHYS] Measured instead of attack TIME, because the wind-up "
               "legitimately delays the peak. What matters is that the loudest "
               "moment is reached fast once it starts."),
        _C("band_sub", "min", 0.05, soft=0.04, w=1.5,
           why="[PHYS] The hit lands in the floor."),
        _C("centroid_drop_oct", "min", 0.5, soft=0.6, w=1.5,
           why="[PHYS] Bright strike, dark aftermath."),
    ],
    clap_positive=["a powerful energy weapon strike from a machine, charge then discharge",
                   "a heavy attack impact, whoosh into a slam"],
    clap_negative=["a gentle chime", "a static drone"],
))

_add(SoundClass(
    "creature_hurt",
    "Damage feedback on an enemy. Must be legible under weapon fire.",
    crits=[
        _C("attack_ms", "max", 8.0, soft=6.0, w=2.0, why="[PHYS] Instant feedback."),
        _C("duration_s", "max", 0.6, soft=0.25, w=1.0,
           why="[CALL] Shorter than the fire interval or hits smear together."),
        _C("roughness", "min", 1.0, soft=0.8, w=1.5, why="[PHYS] Pain is rough."),
        _C("band_mid", "min", 0.08, soft=0.06, w=1.5,
           why="[PHYS] It has to cut through the weapon, which owns the "
               "high-mid. The ear's most sensitive band is the free lane."),
        _C("crest_db", "min", 10.0, soft=5.0, w=1.0, why="[PHYS] Punch."),
    ],
    clap_positive=["a creature yelping in pain, short aggressive hurt vocalisation"],
    clap_negative=["a calm drone", "a chime"],
))

_add(SoundClass(
    "creature_idle",
    "Chitters and mutters. Their only job is to be varied.",
    crits=[
        _C("flux", "min", 0.05, soft=0.04, w=2.0,
           why="[PHYS] Idles repeat more than anything else in the game. A "
               "static idle is the fastest route to 'I have heard this'."),
        _C("env_range_db", "min", 12.0, soft=6.0, w=1.5, why="[PHYS] Articulation."),
        _C("roughness", "min", 1.0, soft=0.8, w=1.0, why="[PHYS] Organic."),
        _C("duration_s", "max", 1.2, soft=0.4, w=0.5, why="[CALL]"),
    ],
    clap_positive=["a small creature chittering and muttering"],
    clap_negative=["a machine hum", "a chord"],
))

_add(SoundClass(
    "player_vocal",
    "The player's own body. Intimate, close-mic, never heroic.",
    crits=[
        _C("band_low", "min", 0.08, soft=0.06, w=1.5,
           why="[PHYS] Proximity effect. A close voice has chest in it; without "
               "the 80-250 Hz band it sounds like it is happening to someone "
               "else, which for a first-person game is the whole failure."),
        _C("sharpness_acum", "max", 2.4, soft=0.6, w=1.0, why="[PHYS] Not shrill."),
        _C("roughness", "min", 0.8, soft=0.8, w=1.0, why="[PHYS] Strain is rough."),
        _C("duration_s", "max", 1.2, soft=0.5, w=0.5, why="[CALL]"),
    ],
    clap_positive=["a person grunting in pain, close and breathy"],
    clap_negative=["a synthesiser", "a metal impact"],
))

_add(SoundClass(
    "player_body_loop",
    "Breathing and heartbeat loops. Must be felt and not consciously heard.",
    crits=[
        _C("sharpness_acum", "max", 1.8, soft=0.5, w=2.0,
           why="[CALL] These loop for minutes at a time under everything else."),
        _C("env_range_db", "min", 8.0, soft=5.0, w=1.5,
           why="[PHYS] Breath is periodic; a flat breath loop is a hiss."),
        _C("band_low", "min", 0.08, soft=0.06, w=1.0, why="[PHYS] Proximity."),
        _C("lufs_i", "max", -24.0, soft=5.0, w=1.0, why="[CALL] Under everything."),
    ],
    clap_positive=["close breathing of a frightened person, intimate"],
    clap_negative=["a loud alarm", "music"],
))

_add(SoundClass(
    "weapon_mech",
    "Heat ticks, cooldowns, welds. Machine chatter around the weapon.",
    crits=[
        _C("sharpness_acum", "max", 3.0, soft=0.6, w=1.5, why="[PHYS] Fatigue."),
        _C("lufs_i", "max", -20.0, soft=5.0, w=1.0,
           why="[CALL] Never louder than the shot it belongs to."),
        _C("flux", "min", 0.03, soft=0.025, w=1.5,
           why="[PHYS] Mechanism = sequence, as above."),
        _C("bw20_oct", "min", 3.0, soft=1.5, w=1.0, why="[PHYS] Contact noise."),
    ],
    clap_positive=["a weapon mechanism cycling, mechanical clicks and hiss"],
    clap_negative=["a musical chord"],
))

_add(SoundClass("ui_other", "Interface sounds without a tighter class.", crits=[
    _C("sharpness_acum", "max", 3.2, soft=0.6, w=1.5, why="[PHYS] Fatigue ceiling."),
    _C("lufs_i", "max", -18.0, soft=5.0, w=1.0, why="[CALL] Quiet-instrument rule."),
    _C("flux", "min", 0.02, soft=0.02, w=1.0, why="[PHYS] Some movement."),
]))

_add(SoundClass("misc", "Unrouted. Graded on the universal defects only.", crits=[
    _C("bw20_oct", "min", 3.0, soft=1.5, w=1.0, why="[PHYS] Not narrow-band."),
    _C("flux", "min", 0.02, soft=0.02, w=1.0, why="[PHYS] Not static."),
    _C("sharpness_acum", "max", 3.4, soft=0.8, w=1.0, why="[PHYS] Not fatiguing."),
]))

# Measured, charted, clustered — but NOT graded. Music and the MOTHER voice are
# other agents' domains with their own aesthetics (M12 and M14), and a
# footfall-shaped objective function would say nothing true about either.
_add(SoundClass("music", "Music. Measured, not graded — M12's domain.",
                crits=[], scored=False))
_add(SoundClass("voice_mother", "MOTHER's voice. Measured, not graded — M14's domain.",
                crits=[], scored=False))


def score(rel: str, d: dict) -> tuple[str, float, list[str]]:
    """(class name, 0..1 score, list of failing criteria) for one descriptor row."""
    cname = classify(rel)
    cls = CLASSES.get(cname, CLASSES["misc"])
    if not cls.scored:
        return cname, float("nan"), []
    s, _ = cls.score(d)
    return cname, s, cls.failures(d)
