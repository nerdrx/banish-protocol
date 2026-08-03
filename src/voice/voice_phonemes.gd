class_name VoicePhonemes
extends RefCounted
## M14 — the phoneme inventory. Formant targets, durations and source settings
## for every sound MOTHER can make.
##
## This is the table that decides what she SOUNDS like, in the same way the cue
## lists in AudioService used to. The values are a low contralto pushed toward
## the bottom of the female range and then flattened: F0 around 118 Hz, narrow
## formant bandwidths, and no vibrato anywhere. Narrow bandwidths are the whole
## trick of the register — they make each formant ring, which reads as MACHINE,
## and they are simultaneously the single biggest intelligibility win available,
## because a ringing formant is an unambiguous one. Naturalness and clarity pull
## in opposite directions here and we are chasing clarity: APOLLO, not a person.
##
## A row is a flat float array so the frame builder can read it without
## allocating. The column order is the `C_*` block below and nothing may reorder
## it — every consumer indexes numerically.
##
## STOPS store their CLOSURE length in `C_DUR` and their release in `C_FRIC_*`;
## the burst is frication with a 10 ms envelope, which is physically what a burst
## is. `C_LOCUS` is the F2 the transition points at across the closure, and it is
## the only cue there is for place of articulation in a stop — get it wrong and
## every stop sounds like /t/.

# --- column layout -----------------------------------------------------------
const C_TYPE: int = 0
const C_VOICED: int = 1
const C_F1: int = 2
const C_F2: int = 3
const C_F3: int = 4
const C_B1: int = 5
const C_B2: int = 6
const C_B3: int = 7
const C_F1B: int = 8      ## second target for diphthongs; <0 means "no glide"
const C_F2B: int = 9
const C_F3B: int = 10
const C_DUR: int = 11     ## milliseconds at neutral rate and neutral stress
const C_AMP: int = 12     ## voicing amplitude, linear 0..1
const C_FRIC_F: int = 13  ## primary frication / burst resonator
const C_FRIC_BW: int = 14
const C_FRIC_A: int = 15
const C_FRC2_F: int = 16  ## secondary frication resonator
const C_FRC2_BW: int = 17
const C_FRC2_A: int = 18
const C_NZERO: int = 19   ## nasal anti-formant, Hz; 0 = none
const C_VOT: int = 20     ## stops: aspiration after release, ms
const C_COLS: int = 21

# --- phoneme types -----------------------------------------------------------
const T_VOWEL: int = 0
const T_STOP: int = 1
const T_FRIC: int = 2
const T_NASAL: int = 3
const T_APPROX: int = 4
const T_AFFRIC: int = 5
const T_ASPIRATE: int = 6
const T_GLITCH: int = 7

## The two high formants are fixed. They carry no phonemic information in
## English and letting them move only adds ways to be wrong.
const F4: float = 3400.0
const B4: float = 220.0
const F5: float = 4300.0
const B5: float = 320.0
## The nasal POLE. Fixed at the low resonance of the nasal cavity; only the ZERO
## moves between /m/, /n/ and /ŋ/, which is correct — the cavity does not change
## shape, the branch that is coupled to it does.
const FNP: float = 270.0
const BNP: float = 110.0

## name -> row. See the column block above for the order.
const TABLE: Dictionary = {
# ------------------------------------------------------------------ vowels --
#          TYPE     VC   F1    F2    F3    B1   B2   B3    F1B   F2B   F3B  DUR  AMP  FRIC        FRIC2       NZ  VOT
"IY":   [T_VOWEL,   1.0, 300, 2350, 2950,  60, 110, 180,   -1,   -1,   -1, 130, 1.00, 0,0,0,      0,0,0,      0,  0],
"IH":   [T_VOWEL,   1.0, 420, 2050, 2700,  70, 110, 180,   -1,   -1,   -1,  92, 0.98, 0,0,0,      0,0,0,      0,  0],
"EY":   [T_VOWEL,   1.0, 450, 2100, 2800,  70, 110, 180,  350, 2300, 2900, 148, 1.00, 0,0,0,      0,0,0,      0,  0],
"EH":   [T_VOWEL,   1.0, 590, 1900, 2650,  80, 110, 180,   -1,   -1,   -1, 112, 1.00, 0,0,0,      0,0,0,      0,  0],
"AE":   [T_VOWEL,   1.0, 730, 1850, 2600,  90, 120, 190,   -1,   -1,   -1, 135, 1.00, 0,0,0,      0,0,0,      0,  0],
"AA":   [T_VOWEL,   1.0, 800, 1200, 2550,  95, 110, 190,   -1,   -1,   -1, 138, 1.00, 0,0,0,      0,0,0,      0,  0],
"AO":   [T_VOWEL,   1.0, 600,  950, 2500,  85, 100, 180,   -1,   -1,   -1, 132, 1.00, 0,0,0,      0,0,0,      0,  0],
"OW":   [T_VOWEL,   1.0, 500,  900, 2450,  75, 100, 180,  380,  800, 2400, 148, 1.00, 0,0,0,      0,0,0,      0,  0],
"UH":   [T_VOWEL,   1.0, 470, 1100, 2400,  75, 110, 180,   -1,   -1,   -1,  95, 0.96, 0,0,0,      0,0,0,      0,  0],
"UW":   [T_VOWEL,   1.0, 340,  850, 2300,  65, 100, 180,   -1,   -1,   -1, 132, 1.00, 0,0,0,      0,0,0,      0,  0],
"AH":   [T_VOWEL,   1.0, 680, 1250, 2500,  85, 110, 180,   -1,   -1,   -1, 105, 0.98, 0,0,0,      0,0,0,      0,  0],
"AX":   [T_VOWEL,   1.0, 520, 1450, 2450,  85, 120, 190,   -1,   -1,   -1,  72, 0.80, 0,0,0,      0,0,0,      0,  0],
"ER":   [T_VOWEL,   1.0, 470, 1350, 1650,  75, 110, 160,   -1,   -1,   -1, 130, 0.98, 0,0,0,      0,0,0,      0,  0],
"AY":   [T_VOWEL,   1.0, 780, 1200, 2550,  95, 110, 190,  330, 2250, 2900, 168, 1.00, 0,0,0,      0,0,0,      0,  0],
"AW":   [T_VOWEL,   1.0, 780, 1250, 2550,  95, 110, 190,  380,  830, 2350, 168, 1.00, 0,0,0,      0,0,0,      0,  0],
"OY":   [T_VOWEL,   1.0, 590,  900, 2500,  85, 100, 180,  330, 2250, 2900, 172, 1.00, 0,0,0,      0,0,0,      0,  0],
# ------------------------------------------------------------------- stops --
# F2 here is the LOCUS. The closure is `DUR`; `VOT` is the aspiration that
# follows the burst, and it is the entire voiced/voiceless distinction in
# initial position — 60 ms of it says /t/, 12 ms says /d/, and nothing else in
# the signal has to change at all.
"P":    [T_STOP,    0.0, 400,  800, 2300, 200, 150, 220,   -1,   -1,   -1,  68, 0.00, 900,900,0.55,  2000,1400,0.30, 0, 52],
"B":    [T_STOP,    1.0, 350,  800, 2300, 150, 150, 220,   -1,   -1,   -1,  52, 0.10, 800,800,0.26,  1800,1200,0.14, 0, 10],
"T":    [T_STOP,    0.0, 350, 1750, 2700, 200, 150, 220,   -1,   -1,   -1,  62, 0.00, 4000,1600,0.85, 2900,1100,0.42, 0, 58],
"D":    [T_STOP,    1.0, 320, 1750, 2700, 150, 150, 220,   -1,   -1,   -1,  48, 0.10, 3700,1500,0.40, 2700,1000,0.20, 0, 12],
"K":    [T_STOP,    0.0, 320, 1900, 2600, 200, 150, 220,   -1,   -1,   -1,  70, 0.00, 2100,1000,0.75, 3300,1500,0.40, 0, 64],
"G":    [T_STOP,    1.0, 300, 1900, 2600, 150, 150, 220,   -1,   -1,   -1,  50, 0.10, 1950, 950,0.36, 3000,1400,0.18, 0, 14],
# -------------------------------------------------------------- fricatives --
"F":    [T_FRIC,    0.0, 400,  900, 2300, 250, 200, 250,   -1,   -1,   -1, 102, 0.00, 5600,3600,0.30, 1500,1300,0.13, 0,  0],
"V":    [T_FRIC,    1.0, 350,  900, 2300, 200, 180, 250,   -1,   -1,   -1,  74, 0.30, 5000,3200,0.13, 1400,1200,0.07, 0,  0],
"TH":   [T_FRIC,    0.0, 350, 1600, 2650, 250, 200, 250,   -1,   -1,   -1,  98, 0.00, 5900,3600,0.24, 1700,1500,0.11, 0,  0],
"DH":   [T_FRIC,    1.0, 320, 1600, 2650, 200, 180, 250,   -1,   -1,   -1,  68, 0.32, 5200,3200,0.11, 1600,1400,0.06, 0,  0],
"S":    [T_FRIC,    0.0, 320, 1750, 2700, 250, 200, 250,   -1,   -1,   -1, 118, 0.00, 6300,2300,1.00, 4500,1300,0.50, 0,  0],
"Z":    [T_FRIC,    1.0, 300, 1750, 2700, 200, 180, 250,   -1,   -1,   -1,  88, 0.28, 6100,2300,0.46, 4400,1300,0.22, 0,  0],
"SH":   [T_FRIC,    0.0, 340, 1900, 2500, 250, 200, 250,   -1,   -1,   -1, 122, 0.00, 3200,1700,0.98, 4900,2100,0.52, 0,  0],
"ZH":   [T_FRIC,    1.0, 320, 1900, 2500, 200, 180, 250,   -1,   -1,   -1,  88, 0.30, 3100,1700,0.46, 4700,2000,0.24, 0,  0],
"HH":   [T_ASPIRATE,0.0, 520, 1450, 2450, 300, 260, 300,   -1,   -1,   -1,  74, 0.00, 1400,2400,0.30, 3000,2600,0.16, 0,  0],
# -------------------------------------------------------------- affricates --
# Closure, then a burst that IS the fricative. `DUR` is the closure; the frication
# columns carry the release and it runs long (the release is what makes /tʃ/ not
# /t/), handled in the frame builder.
"CH":   [T_AFFRIC,  0.0, 340, 1800, 2600, 200, 150, 220,   -1,   -1,   -1,  58, 0.00, 3200,1700,0.95, 4900,2100,0.50, 0, 70],
"JH":   [T_AFFRIC,  1.0, 320, 1800, 2600, 160, 150, 220,   -1,   -1,   -1,  46, 0.14, 3100,1700,0.48, 4700,2000,0.26, 0, 34],
# ------------------------------------------------------------------ nasals --
"M":    [T_NASAL,   1.0, 250, 1100, 2200,  90, 130, 220,   -1,   -1,   -1,  78, 0.72, 0,0,0,        0,0,0,          750, 0],
"N":    [T_NASAL,   1.0, 250, 1600, 2700,  90, 130, 220,   -1,   -1,   -1,  72, 0.72, 0,0,0,        0,0,0,         1450, 0],
"NG":   [T_NASAL,   1.0, 250, 2100, 2800,  90, 130, 220,   -1,   -1,   -1,  80, 0.70, 0,0,0,        0,0,0,         2100, 0],
# ------------------------------------------------- liquids and glides -------
# /R/'s low F3 is the strongest single formant cue in English. If exactly one
# number in this table has to be right, it is the 1600 on this row.
"L":    [T_APPROX,  1.0, 340, 1100, 2750,  85, 110, 200,   -1,   -1,   -1,  70, 0.88, 0,0,0,        0,0,0,          0,  0],
"R":    [T_APPROX,  1.0, 330, 1050, 1600,  85, 110, 160,   -1,   -1,   -1,  76, 0.90, 0,0,0,        0,0,0,          0,  0],
"W":    [T_APPROX,  1.0, 300,  720, 2300,  75, 100, 200,   -1,   -1,   -1,  60, 0.88, 0,0,0,        0,0,0,          0,  0],
"WH":   [T_APPROX,  1.0, 300,  720, 2300,  75, 100, 200,   -1,   -1,   -1,  60, 0.80, 2000,2600,0.16, 0,0,0,       0,  0],
"Y":    [T_APPROX,  1.0, 280, 2200, 3000,  70, 110, 200,   -1,   -1,   -1,  58, 0.88, 0,0,0,        0,0,0,          0,  0],
# ----------------------------------------------------------------- damage ---
# A corruption glyph. NOT A SEGMENT AND NOT A DURATION — a marker the frame
# builder consumes to damage the sound NEXT to it. Its `DUR` is zero and must
# stay zero: a decayed line has to be shorter than its clean original, never
# longer, because what corruption does is take words away. The frication columns
# are the click the tape makes where the letter used to be; see
# `VoiceFrames._damage`.
"#X":   [T_GLITCH,  0.0, 520, 1450, 2450, 400, 400, 400,   -1,   -1,   -1,   0, 0.00, 2400,3000,0.80, 5200,3200,0.40, 0,  0],
}

## Neutral (silence / phrase edge) formant target. Everything relaxes toward this
## when nothing is being said, so a phrase does not start from a discontinuity.
const NEUTRAL: Array[float] = [520.0, 1450.0, 2450.0]


## Does this phoneme name exist? Used by the selftest to prove no G2P rule can
## emit a symbol the synthesiser has never heard of — the failure mode that
## would otherwise be a silent hole in one word of one bark.
static func has(name: String) -> bool:
	return TABLE.has(name)


static func row(name: String) -> Array:
	return TABLE.get(name, TABLE["AX"]) as Array


static func type_of(name: String) -> int:
	return int((TABLE.get(name, TABLE["AX"]) as Array)[C_TYPE])


static func is_vowel(name: String) -> bool:
	return type_of(name) == T_VOWEL


## Vowel-like for syllabification purposes: a syllable can be built around a
## vowel, and — in unstressed English — around a syllabic /l/, /r/ or nasal
## (BUTTON, LITTLE, MANIFEST-ER). Treating those as nuclei is what keeps the
## syllable COUNT right, and the syllable count is the rhythm.
static func is_syllabic(name: String) -> bool:
	var t: int = type_of(name)
	return t == T_VOWEL or t == T_APPROX or t == T_NASAL
