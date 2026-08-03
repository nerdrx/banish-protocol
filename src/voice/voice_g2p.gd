class_name VoiceG2P
extends RefCounted
## M14 — HER VOICE, LIVE. Step one: TEXT IN, PHONEMES OUT.
##
## MOTHER's baked cues synthesised speech-SHAPED noise on purpose — rhythm,
## stress and consonant events with the words withheld. A player auditioned them
## and heard "generic grunts". That verdict retires the conceit: she is an
## intelligence, and an intelligence that cannot be understood is a creature.
## So this file is the front half of a real formant text-to-speech path.
##
## NO DICTIONARY, BY DESIGN — not as a shortcut. Callsigns are the whole point of
## the milestone and callsigns are not words; NERDRX is not in any lexicon and
## never will be. A rules engine degrades gracefully into "a plausible reading of
## an unfamiliar string", which is exactly what a machine pronouncing a human
## handle should sound like. A lookup table degrades into silence or into
## spelling it out, and both are worse.
##
## THE ENGINE is context-sensitive letter-to-sound rewriting, the same shape as
## the classic NRL/eSpeak-family rulesets: for each letter, the first rule whose
## left context, focus and right context all match wins, and it emits phonemes
## and consumes its focus. Written here from English orthography rather than
## imported, per the no-third-party law. It is ~330 rules and it gets the great
## majority of the corpus right; the misses are listed honestly in `KNOWN_MISSES`
## at the foot of this file.
##
## Output is ARPABET-ish: the phoneme names `VoicePhonemes` has formant targets
## for. Word boundaries and pauses come back as markers so the prosody layer can
## see phrase structure without re-parsing the text.

# ---------------------------------------------------------------- markers --

## Emitted between words. The frame builder turns it into coarticulation
## permission (or the lack of it) rather than into silence.
const WORD_BREAK: String = "|"
## Emitted for a corruption glyph inside a word — see `GLYPHS`. The synthesiser
## renders it as a burst of band-limited noise where a phoneme should have been,
## which is what the caption already shows the player.
const GLITCH: String = "#X"

## Pause markers. The float is seconds and lives in `PAUSES`.
const PAUSE_PREFIX: String = "#P"

## Punctuation -> pause length in seconds. Matches the baked engine's table so her
## phrasing is unchanged by the rewrite; the ear notices a phrase rhythm change
## long before it notices a formant change.
const PAUSES: Dictionary = {
	".": 0.46, "!": 0.44, "?": 0.46, ":": 0.32, ";": 0.32,
	",": 0.20, "—": 0.26, "-": 0.10, "/": 0.14,
}

## The corruption vocabulary the corpus renders decayed text with (STYLE_BIBLE).
##
## A GLYPH IS ARTIFACT, NOT CONTENT, and it costs NO TIME. It marks a letter that
## has been eaten, so what the ear should get is the letter's ABSENCE — a hole in
## the word, a click, the tape stumbling — never an extra sound. Reciting the
## punctuation aloud was the first implementation and it was wrong twice over:
## comically wrong for the fiction (a planet-scale intelligence solemnly saying
## "tilde"), and measurably harmful, because it inflated spoken duration by
## 1.16x at tier 1 and 1.20x at tier 2 — up to 1.89x on one line — which pushed
## urgent warnings past their timing budget at exactly the depths where a warning
## matters most. The horror of a degraded transmission is that words go MISSING.
##
## `0` and `X` are in the corpus glyph set and are ALSO a real digit and a real
## letter. They are handled by context rather than by this table — see
## `_is_eaten_zero`. A `0` inside a word in a line that is visibly corrupted was
## the single worst offender in the whole measurement: `LOGGED` decays to
## `LO0G0D`, which the number reader spoke as "LOH ZERO G ZERO D" and which is
## most of why one line came out 1.7x its clean length.
##
## `X` INSIDE a word stays content, deliberately: it costs two short segments as
## a plain letter, so eating it buys almost no time, and at tier 1 only a fifth
## of the characters are replaced — a real `X` sits in an untouched word in most
## corrupted lines, and eating those would damage clean words to save nothing.
##
## A `X` or `0` ALONE, as a whole word, in a decayed line is a different animal
## and is damage. It is a word the decay pass ate entirely, and the single-letter
## path would otherwise read it as the LETTER NAME — "EX", two segments where the
## word `A` had one. That was the whole of the remaining worst case: `THERE IS A
## DRAW ON THE POOL` decays to `%HERE IS X DRAW =N X** POOX`, and reading those
## two lone `X`s aloud made a shortened line come out half again as long.
const GLYPHS: String = "$+|<>#%^&~=!?*\\/@"

## The glyphs that can ONLY be damage. `?` and `!` are excluded because they are
## also sentence punctuation, and `0`/`X` because they are also content — so this
## is the subset whose presence proves a line has been through the decay pass.
## One scan for any of these decides how the ambiguous characters are read.
const GLYPHS_UNAMBIGUOUS: String = "$+|<>#%^&~=*\\/@"

## An internal, non-printing stand-in for "a letter that was eaten". Kept out of
## the visible alphabet so it can never collide with something a player typed.
const GLYPH_MARK: String = "\u0001"

# ------------------------------------------------------- text normalisation --

## Digits, spoken. She reads a shard count and a layer number aloud constantly
## once the template slots are live, so this is a hot path, not a curiosity.
const ONES: Array[String] = ["ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE",
	"SIX", "SEVEN", "EIGHT", "NINE"]
const TEENS: Array[String] = ["TEN", "ELEVEN", "TWELVE", "THIRTEEN", "FOURTEEN",
	"FIFTEEN", "SIXTEEN", "SEVENTEEN", "EIGHTEEN", "NINETEEN"]
const TENS: Array[String] = ["", "", "TWENTY", "THIRTY", "FORTY", "FIFTY",
	"SIXTY", "SEVENTY", "EIGHTY", "NINETY"]

## A letter said as a letter: what a lone consonant in a callsign becomes. NERDRX
## is read as a word (that is the fun); a bare "X" has to be "EX" or it is a
## fricative with nowhere to go.
const LETTER_NAMES: Dictionary = {
	"A": "AY", "B": "BEE", "C": "SEE", "D": "DEE", "E": "EE", "F": "EFF",
	"G": "JEE", "H": "AITCH", "I": "EYE", "J": "JAY", "K": "KAY", "L": "ELL",
	"M": "EM", "N": "EN", "O": "OH", "P": "PEE", "Q": "CUE", "R": "AR",
	"S": "ESS", "T": "TEE", "U": "YOU", "V": "VEE", "W": "DOUBLEYOU",
	"X": "EX", "Y": "WYE", "Z": "ZED",
}

## Accented Latin -> the bare letter. A callsign is whatever the player typed and
## players type diacritics; folding them is the difference between "she says my
## name" and "she skips my name".
const FOLD: Dictionary = {
	"À": "A", "Á": "A", "Â": "A", "Ã": "A", "Ä": "A", "Å": "A", "Æ": "AE",
	"Ç": "C", "È": "E", "É": "E", "Ê": "E", "Ë": "E", "Ì": "I", "Í": "I",
	"Î": "I", "Ï": "I", "Ñ": "N", "Ò": "O", "Ó": "O", "Ô": "O", "Õ": "O",
	"Ö": "O", "Ø": "O", "Ù": "U", "Ú": "U", "Û": "U", "Ü": "U", "Ý": "Y",
	"ß": "SS", "Þ": "TH", "Ð": "D", "Œ": "OE", "Š": "S", "Ž": "Z",
}

## Words that never take a pitch accent. Flat stress reads as a chant; this table
## is most of what stops that.
const FUNCTION_WORDS: Dictionary = {
	"THE": true, "A": true, "AN": true, "IS": true, "ARE": true, "WAS": true,
	"WERE": true, "TO": true, "OF": true, "IN": true, "ON": true, "AT": true,
	"IT": true, "ITS": true, "THAT": true, "THIS": true, "AND": true,
	"OR": true, "DO": true, "DOES": true, "DID": true, "HAVE": true,
	"HAS": true, "HAD": true, "BE": true, "BEEN": true, "AM": true,
	"I": true, "YOU": true, "YOUR": true, "MY": true, "ME": true, "WE": true,
	"THEY": true, "THEM": true, "HE": true, "SHE": true, "WITH": true,
	"FROM": true, "FOR": true, "AS": true, "BY": true, "THERE": true,
	"HERE": true, "WILL": true, "WOULD": true, "CAN": true, "COULD": true,
	"SHALL": true, "SHOULD": true, "THAN": true, "THEN": true, "NOT": true,
	"NO": true, "SO": true, "IF": true, "UP": true, "OUT": true,
}

# ------------------------------------------------------------ context classes --

const VOWEL_LETTERS: String = "AEIOUY"
const FRONT_VOWELS: String = "EIY"
const VOICED_CONS: String = "BDVGJLMNRWZ"
const SIBILANTS: String = "SCGZXJ"
## Consonants after which "long U" is /UW/, not /Y UW/: RULE, TUNE, SUIT.
const U_PLAIN: String = "TDSRLZNJ"

# ==========================================================================
# THE RULE TABLE
# ==========================================================================
#
# One entry is [left, focus, right, phonemes]. `focus` is literal letters. The
# contexts use these classes, and a class in `left` is read right-to-left from
# the letter before the focus:
#
#     " "  a word boundary (the word is padded with spaces before matching)
#     "#"  one or more vowel letters
#     "^"  exactly one consonant letter
#     ":"  zero or more consonant letters
#     "+"  a front vowel (E I Y) — the letter that softens C and G
#     "."  a voiced consonant
#     "&"  a sibilant
#     "@"  a consonant after which long U loses its /Y/ glide
#     "%"  (right context only) an English suffix: E ES ED ER ERS ING ELY
#
# Anything else in a context is a literal letter. Rules are tried in order and
# the first complete match wins, so the specific ones come first and the bare
# letter is always last — a letter with no fallback rule is a crash waiting for
# the one callsign that contains it.
#
# The single most load-bearing block is the silent-E family under "E": English
# marks vowel length with a letter it does not pronounce, and a synthesiser that
# does not model that says "NAM" for NAME and is instantly unlistenable.

const RULES: Dictionary = {
"A": [
	[" ", "A", " ", "AH"],
	[" ", "ARE", " ", "AA R"],
	[" ", "AR", "O", "AH R"],
	[" ", "A", "^#", "AH"],
	["#:^", "A", " ", "AH"],
	["", "ARR", "#", "AE R"],
	["", "AR", "#", "EH R"],
	[" ^", "AS", "#", "EY S"],
	["", "A", "WA", "AH"],
	["", "AW", "", "AO"],
	[" :", "ANY", "", "EH N IY"],
	["", "A", "^+#", "EY"],
	["#:", "ALLY", " ", "UH L IY"],
	[" ", "AL", "#", "AH L"],
	["", "AGAIN", "", "AH G EH N"],
	["#:", "AG", "E", "IH JH"],
	["", "A", "^%", "EY"],
	["", "A", "^+:#", "AE"],
	["", "AL", "^", "AO L"],
	[" :", "ABLE", "", "EY B AH L"],
	["#", "ABLE", " ", "AH B AH L"],
	["", "ANG", "+", "EY N JH"],
	["", "ATION", "", "EY SH AH N"],
	["", "AR", "", "AA R"],
	["", "AI", "", "EY"],
	["", "AY", "", "EY"],
	["", "AU", "", "AO"],
	["", "A", "", "AE"],
],
"B": [
	[" ", "BE", "^#", "B IH"],
	[" ", "BEING", "", "B IY IH NG"],
	[" ", "BOTH", " ", "B OW TH"],
	[" ", "BUS", "#", "B IH Z"],
	["", "BUIL", "", "B IH L"],
	["", "BB", "", "B"],
	["M", "B", " ", ""],
	["", "B", "", "B"],
],
"C": [
	[" ", "CH", "^", "K"],
	["^E", "CH", "", "K"],
	["", "CH", "R", "K"],
	["", "CHOR", "", "K AO R"],
	["", "CHEM", "", "K EH M"],
	["", "CH", "", "CH"],
	["X", "C", "+", ""],
	[" S", "CI", "#", "S AY"],
	["", "CI", "A", "SH"],
	["", "CI", "O", "SH"],
	["", "CI", "EN", "SH"],
	["", "CITY", "", "S IH T IY"],
	["", "CK", "", "K"],
	["", "COM", "%", "K AH M"],
	["", "C", "+", "S"],
	["", "CC", "+", "K S"],
	["", "CC", "", "K"],
	["", "C", "", "K"],
],
"D": [
	[" ", "DR", "", "D R"],
	["#:", "DED", " ", "D IH D"],
	[".E", "D", " ", "D"],
	["#:^E", "D", " ", "T"],
	[" ", "DE", "^#", "D IH"],
	[" ", "DO", " ", "D UW"],
	[" ", "DOES", "", "D AH Z"],
	[" ", "DOING", "", "D UW IH NG"],
	[" ", "DOW", "", "D AW"],
	["", "DU", "A", "JH UW"],
	["", "DD", "", "D"],
	["", "D", "", "D"],
],
"E": [
	[" ", "EVEN", "", "IY V AH N"],
	[" ", "EVER", "", "EH V ER"],
	[" ", "EVERY", "", "EH V R IY"],
	[" ", "ENOUGH", "", "IH N AH F"],
	["#:", "E", " ", ""],
	["'^:", "E", " ", ""],
	[" :^", "E", " ", "IY"],
	["#", "ED", " ", "D"],
	["#:", "E", "D ", ""],
	["", "EV", "ER", "EH V"],
	["", "ERI", "#", "IY R IY"],
	["", "ERI", "", "EH R IH"],
	["#:^", "ER", "#", "ER"],
	["", "ER", "#", "EH R"],
	["", "ER", "", "ER"],
	[" ", "EVEN", "", "IY V EH N"],
	["#:", "EW", "", "UW"],
	["@", "EW", "", "UW"],
	["", "EW", "", "Y UW"],
	["", "E", "O", "IY"],
	["#:&", "ES", " ", "IH Z"],
	["#:", "E", "S ", ""],
	["#:", "ELY", " ", "L IY"],
	["#:", "EMENT", "", "M EH N T"],
	["", "EFUL", "", "F UH L"],
	["", "EE", "", "IY"],
	["", "EARN", "", "ER N"],
	[" ", "EAR", "^", "ER"],
	["", "EAD", "", "EH D"],
	["#:", "EA", " ", "IY AH"],
	["", "EA", "SU", "EH"],
	["BR", "EA", "K", "EY"],
	["ST", "EA", "K", "EY"],
	["", "EAL", "TH", "EH L"],
	["", "EATH", "ER", "EH DH"],
	["", "EA", "", "IY"],
	["", "EIGH", "", "EY"],
	["", "EI", "", "IY"],
	[" ", "EYE", "", "AY"],
	["", "EY", "", "IY"],
	["", "EU", "", "Y UW"],
	["", "E", "", "EH"],
],
"F": [
	["", "FUL", "", "F UH L"],
	["", "FF", "", "F"],
	["", "F", "", "F"],
],
"G": [
	["", "GIV", "", "G IH V"],
	[" ", "G", "I^", "G"],
	["", "GE", "T", "G EH"],
	["SU", "GGES", "", "G JH EH S"],
	["", "GG", "", "G"],
	[" B#", "G", "", "G"],
	["", "G", "+", "JH"],
	["", "GREAT", "", "G R EY T"],
	["", "GH", "", ""],
	["#", "GN", " ", "N"],
	[" ", "GN", "", "N"],
	["", "G", "", "G"],
],
"H": [
	[" ", "HAV", "", "HH AE V"],
	[" ", "HERE", "", "HH IY R"],
	[" ", "HOUR", "", "AW ER"],
	["", "HONEST", "", "AA N IH S T"],
	["", "HOOD", "", "HH UH D"],
	[" ", "HONOR", "", "AA N ER"],
	["", "H", "#", "HH"],
	["", "H", "", ""],
],
"I": [
	[" ", "IN", "", "IH N"],
	[" ", "I", " ", "AY"],
	["", "IN", "D", "AY N"],
	["", "IER", "", "IY ER"],
	["#:R", "IED", " ", "IY D"],
	["", "IED", " ", "AY D"],
	["", "IEN", "", "IY EH N"],
	["", "IE", "T", "AY EH"],
	[" :", "I", "%", "AY"],
	["", "I", "%", "IY"],
	["", "IE", "", "IY"],
	["", "IGH", "", "AY"],
	["", "ILD", " ", "AY L D"],
	["", "IGN", " ", "AY N"],
	["", "IGN", "^", "AY N"],
	["", "IGN", "%", "AY N"],
	["", "IQUE", "", "IY K"],
	["", "IVE", " ", "IH V"],
	["", "ION", "", "Y AH N"],
	["", "IOU", "", "IY AH"],
	["", "IO", "", "IY AH"],
	["", "IA", "", "IY AH"],
	["", "I", "^^E ", "IH"],
	["", "I", "^+:#", "IH"],
	["", "I", "^E ", "AY"],
	["", "I", "^%", "AY"],
	["", "IR", "", "ER"],
	["", "I", "", "IH"],
],
"J": [
	["", "J", "", "JH"],
],
"K": [
	[" ", "K", "N", ""],
	["", "KK", "", "K"],
	["", "K", "", "K"],
],
"L": [
	["", "LO", "C#", "L OW"],
	["L", "L", "", ""],
	["#:^", "L", "%", "AH L"],
	["", "LEAD", "", "L IY D"],
	["", "L", "", "L"],
],
"M": [
	["", "MOV", "", "M UW V"],
	["", "MM", "", "M"],
	["", "M", "", "M"],
],
"N": [
	["E", "NG", "+", "N JH"],
	["", "NG", "R", "NG G"],
	["", "NG", "#", "NG G"],
	["#:", "NGL", "%", "NG G AH L"],
	["", "NG", "", "NG"],
	["", "NK", "", "NG K"],
	[" ", "NOW", " ", "N AW"],
	["", "NN", "", "N"],
	["", "N", "", "N"],
],
"O": [
	["", "OF", " ", "AH V"],
	["", "OROUGH", "", "ER OW"],
	["#:", "OR", " ", "ER"],
	["#:", "ORS", " ", "ER Z"],
	["", "OR", "", "AO R"],
	[" ", "ONE", "", "W AH N"],
	["", "OW", "", "OW"],
	[" ", "OVER", "", "OW V ER"],
	["", "OV", "", "AH V"],
	["", "O", "^%", "OW"],
	["", "O", "^EN", "OW"],
	["", "O", "^+#", "OW"],
	["", "OL", "D", "OW L"],
	["", "OUGHT", "", "AO T"],
	["", "OUGH", "", "AH F"],
	[" ", "OU", "", "AW"],
	["", "OUBL", "", "AH B AH L"],
	["", "OUCH", "", "AH CH"],
	["", "OUNTR", "", "AH N T R"],
	["", "OUSIN", "", "AH Z AH N"],
	["", "OURISH", "", "ER IH SH"],
	["H", "OU", "S#", "AW"],
	["", "OUS", "", "AH S"],
	["", "OUR", "", "AO R"],
	["", "OULD", "", "UH D"],
	["", "OUP", "", "UW P"],
	["", "OU", "", "AW"],
	["", "OY", "", "OY"],
	["", "OING", "", "OW IH NG"],
	["", "OI", "", "OY"],
	["", "OOR", "", "AO R"],
	["", "OOK", "", "UH K"],
	["", "OOD", "", "UH D"],
	["", "OO", "", "UW"],
	["", "O", "E", "OW"],
	["", "O", " ", "OW"],
	["", "OA", "", "OW"],
	[" ", "ONLY", "", "OW N L IY"],
	[" ", "ONCE", "", "W AH N S"],
	["", "ON'T", "", "OW N T"],
	["C", "O", "N", "AA"],
	["", "O", "NG", "AO"],
	[" :^", "O", "N", "AH"],
	["#:", "ON", " ", "AH N"],
	["#^", "ON", " ", "AH N"],
	["", "O", "ST ", "OW"],
	["", "OFF", "", "AO F"],
	["", "OF", "^", "AO F"],
	["", "OTHER", "", "AH DH ER"],
	["", "OSS", " ", "AO S"],
	["#:^", "OM", "", "AH M"],
	["", "O", "", "AA"],
],
"P": [
	["", "PH", "", "F"],
	["", "PEOP", "", "P IY P"],
	["", "POW", "", "P AW"],
	["", "PUT", " ", "P UH T"],
	["", "PP", "", "P"],
	[" ", "PS", "", "S"],
	["", "P", "", "P"],
],
"Q": [
	["", "QUAR", "", "K W AO R"],
	["", "QU", "", "K W"],
	["", "Q", "", "K"],
],
"R": [
	["R", "R", "", ""],
	[" ", "RE", "^#", "R IY"],
	["", "RR", "", "R"],
	["", "R", "", "R"],
],
"S": [
	["", "SH", "", "SH"],
	["#", "SION", "", "ZH AH N"],
	["", "SION", "", "SH AH N"],
	["", "SOME", "", "S AH M"],
	["#", "SUR", "#", "ZH ER"],
	["", "SUR", "#", "SH ER"],
	["#", "SU", "#", "ZH UW"],
	["#", "SSU", "#", "SH UW"],
	["#", "SED", " ", "Z D"],
	["#", "S", "#", "Z"],
	["", "SAID", "", "S EH D"],
	["^", "SION", "", "SH AH N"],
	["", "S", "S", ""],
	[".", "S", " ", "Z"],
	["#:.E", "S", " ", "Z"],
	["#:^^", "S", " ", "S"],
	["#", "S", " ", "Z"],
	["", "SCH", "", "SH"],
	["", "S", "C+", ""],
	["#", "SM", " ", "Z AH M"],
	["#", "SN", " ", "Z AH N"],
	["", "S", "", "S"],
],
"T": [
	[" ", "THE", " ", "DH AH"],
	["", "TO", " ", "T UW"],
	["", "THAT", "", "DH AE T"],
	[" ", "THIS", " ", "DH IH S"],
	[" ", "THEY", "", "DH EY"],
	[" ", "THEM", "", "DH EH M"],
	[" ", "THERE", "", "DH EH R"],
	[" ", "THEIR", "", "DH EH R"],
	[" ", "THAN", "", "DH AE N"],
	[" ", "THEN", "", "DH EH N"],
	[" ", "THOSE", "", "DH OW Z"],
	[" ", "THESE", " ", "DH IY Z"],
	[" ", "THUS", "", "DH AH S"],
	["#", "THE", " ", "DH"],
	["#", "THES", " ", "DH Z"],
	["", "EITHER", "", "IY DH ER"],
	["", "TCH", "", "CH"],
	["", "TION", "", "SH AH N"],
	["", "TIEN", "", "SH AH N"],
	["", "TUR", "#", "CH ER"],
	["", "TU", "A", "CH UW"],
	[" ", "TWO", "", "T UW"],
	["", "TH", "", "TH"],
	["#:", "TED", " ", "T IH D"],
	["S", "TI", "#N", "CH"],
	["", "TI", "O", "SH"],
	["", "TI", "A", "SH"],
	["", "TIEN", "", "SH AH N"],
	["", "TT", "", "T"],
	["", "T", "", "T"],
],
"U": [
	[" ", "UN", "I", "Y UW N"],
	[" ", "UN", "", "AH N"],
	[" ", "UPON", "", "AH P AO N"],
	["@", "UR", "#", "UH R"],
	["", "UR", "#", "Y UH R"],
	["", "UR", "", "ER"],
	["", "U", "^ ", "AH"],
	["", "U", "^^", "AH"],
	["", "UY", "", "AY"],
	[" G", "U", "#", ""],
	["G", "U", "%", ""],
	["G", "U", "#", "W"],
	["#N", "U", "", "Y UW"],
	["@", "U", "", "UW"],
	["", "U", "", "Y UW"],
],
"V": [
	["", "VIEW", "", "V Y UW"],
	["", "V", "", "V"],
],
"W": [
	[" ", "WERE", "", "W ER"],
	["", "WA", "S", "W AA"],
	["", "WA", "T", "W AA"],
	["", "WHERE", "", "WH EH R"],
	["", "WHAT", "", "WH AA T"],
	["", "WHOL", "", "HH OW L"],
	["", "WHO", "", "HH UW"],
	["", "WH", "", "WH"],
	["", "WAR", "", "W AO R"],
	["", "WOR", "^", "W ER"],
	["", "WR", "", "R"],
	["", "W", "", "W"],
],
"X": [
	[" ", "X", "", "Z"],
	["", "X", "", "K S"],
],
"Y": [
	["", "YOUNG", "", "Y AH NG"],
	[" ", "YOU", "", "Y UW"],
	[" ", "YES", "", "Y EH S"],
	[" ", "Y", "", "Y"],
	["#:^", "Y", " ", "IY"],
	["#:^", "Y", "I", "IY"],
	[" :", "Y", " ", "AY"],
	[" :", "Y", "#", "AY"],
	[" :", "Y", "^+:#", "IH"],
	[" :", "Y", "^^", "IH"],
	["", "Y", "", "IH"],
],
"Z": [
	["", "ZZ", "", "Z"],
	["", "Z", "", "Z"],
],
"'": [
	["", "'S", "", "Z"],
	["", "'T", "", "T"],
	["", "'RE", "", "ER"],
	["", "'LL", "", "L"],
	["", "'VE", "", "V"],
	["", "'", "", ""],
],
}

## The ones this ruleset gets wrong, kept as documentation rather than as a
## dictionary that would then need maintaining. Every one of them is still
## RECOGNISABLE, which is the bar — an intelligence approximating a word is in
## character; an intelligence going silent is not.
##   PROCESS   -> "PROH-SESS" (the unstressed O is spoken long)
##   MANIFEST  -> correct
##   QUARANTINE-> "QUOR-AN-TEEN" (the QUAR rule wins; the AR is over-rounded)
##   ARCHIVE   -> "AR-CHIVE" with a /tʃ/ (needs a CH-before-I rule we do not have)
##   LIVE      -> always /laɪv/, never /lɪv/ (unresolvable without a lexicon)
##   READ      -> always /riːd/ (same)


# ==========================================================================
# PUBLIC API
# ==========================================================================

## Text -> a flat token stream of phoneme names, `WORD_BREAK`, `GLITCH` and
## `PAUSE_PREFIX<seconds>` markers. Everything downstream reads this and nothing
## downstream re-reads the text, so there is exactly one place where a sentence
## becomes sounds.
static func tokenise(text: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for tok: Dictionary in split_words(text):
		var kind: String = String(tok["kind"])
		if kind == "pause":
			out.append(PAUSE_PREFIX + str(tok["seconds"]))
			continue
		var phones: PackedStringArray = PackedStringArray(tok["phones"])
		if phones.is_empty():
			continue
		if not out.is_empty():
			out.append(WORD_BREAK)
		out.append_array(phones)
	return out


## Text -> words, each already converted to phonemes, with pauses interleaved.
## The prosody layer wants the WORD structure (for stress and for reduction), so
## this is the richer entry point and `tokenise` is the flat convenience.
##
## Each element is one of:
##   {kind:"word", text:String, phones:PackedStringArray, func_word:bool}
##   {kind:"pause", seconds:float}
static func split_words(text: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var buf: String = ""
	var src: String = _fold(text).to_upper()
	# One scan up front: is this line decayed at all? Everything ambiguous below
	# is read one way in a clean line and the other way in a corrupted one, and
	# guessing per-character instead would get both wrong.
	var decayed: bool = false
	for k: int in src.length():
		if GLYPHS_UNAMBIGUOUS.contains(src[k]):
			decayed = true
			break
	var i: int = 0
	while i < src.length():
		var c: String = src[i]
		if (c >= "A" and c <= "Z") or c == "'":
			buf += c
		elif _is_eaten_zero(src, i, decayed):
			buf += GLYPH_MARK
		elif c >= "0" and c <= "9":
			# Pull the whole numeral, then speak it.
			var num: String = ""
			while i < src.length() and src[i] >= "0" and src[i] <= "9":
				num += src[i]
				i += 1
			i -= 1
			_flush_word(out, buf, decayed)
			buf = ""
			for w: String in _say_number(num).split(" ", false):
				_flush_word(out, w)
		elif GLYPHS.contains(c) and not _is_terminal_punctuation(src, i, decayed):
			# A corruption glyph. It ate a letter; it is spoken as damage, in
			# place, so a decayed line still has the right number of beats.
			buf += GLYPH_MARK
		elif PAUSES.has(c):
			_flush_word(out, buf, decayed)
			buf = ""
			out.append({"kind": "pause", "seconds": float(PAUSES[c])})
		else:
			_flush_word(out, buf, decayed)
			buf = ""
		i += 1
	_flush_word(out, buf, decayed)
	return out


## One orthographic word -> phonemes. Public because the callsign path calls it
## directly (a callsign is a word with no sentence around it) and because the
## selftest asserts specific words against it.
static func word_to_phones(word: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if word.is_empty():
		return out
	# A bare single letter is a letter NAME, not a phoneme: "X" is EX. Two or
	# more letters are read as a word, which is what makes NERDRX fun.
	# ...but A and I are WORDS. Sending them down the letter-name path makes the
	# commonest article in her corpus come out as "AY", which is the single most
	# noticeable pronunciation error available.
	if word.length() == 1 and word != "A" and word != "I" and LETTER_NAMES.has(word):
		return word_to_phones(String(LETTER_NAMES[word]))
	# An all-consonant token has no vowel to hang a syllable on, so it is spelled
	# out. NERDRX has vowels; NRDRX does not, and "EN AR DEE AR EX" is the right
	# and only readable answer.
	#
	# NOT IF THE DECAY PASS ATE THE VOWELS, though, and this was the last and
	# worst corruption bug: `WORK` decays to `W$RK/`, which has no vowel LEFT, so
	# the acronym path read it as "DOUBLEYOU AR KAY" — nine syllables where the
	# clean word had one, and single-handedly most of the remaining inflation. A
	# word carrying damage is a damaged word, never an acronym.
	if not _has_vowel(word) and word.length() <= 6 and not word.contains(GLYPH_MARK):
		for k: int in word.length():
			if LETTER_NAMES.has(word[k]):
				out.append_array(word_to_phones(String(LETTER_NAMES[word[k]])))
		return out

	var padded: String = " " + word + " "
	var pos: int = 1
	var guard: int = 0
	while pos < padded.length() - 1:
		guard += 1
		if guard > 400:
			break
		var letter: String = padded[pos]
		if letter == GLYPH_MARK:
			out.append(GLITCH)
			pos += 1
			continue
		var table: Array = RULES.get(letter, []) as Array
		var matched: bool = false
		for rule: Array in table:
			var focus: String = String(rule[1])
			if not _focus_at(padded, pos, focus):
				continue
			if not _match_left(padded, pos, String(rule[0])):
				continue
			if not _match_right(padded, pos + focus.length(), String(rule[2])):
				continue
			var phones: String = String(rule[3])
			if not phones.is_empty():
				out.append_array(phones.split(" ", false))
			pos += focus.length()
			matched = true
			break
		if not matched:
			# Never possible for A-Z (every letter table ends in a bare fallback)
			# but a stray byte must not wedge the loop.
			pos += 1
	return repair_clusters(out)


## Insert a support vowel into a consonant cluster no mouth could produce.
##
## THIS IS THE CALLSIGN RULE. Real English words obey English phonotactics for
## free; player handles do not. NERDRX comes out of the letter rules as
## N ER D R K S, whose tail is four consonants with no nucleus — literally
## unpronounceable, and what a synthesiser does with it is emit four overlapping
## bursts that read as a glitch rather than as a name. One /ɪ/ in the right place
## turns it into NER-DRIKS, which is both sayable and recognisably the handle
## the player typed.
##
## Two triggers, deliberately narrow so real words are left alone:
##   * a liquid or nasal with a consonant on BOTH sides — it wanted to be a
##     syllable and there is nowhere for it to be one (D-R-K);
##   * any run of four or more consonants, repaired after the second.
## CONSTRUCTS (K AA N S T R AH K T S) trips neither and comes through untouched,
## which is the test that matters: the repair must be invisible on English.
static func repair_clusters(phones: PackedStringArray) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var run: int = 0
	for i: int in phones.size():
		var name: String = phones[i]
		if name == GLITCH:
			# Damage is transparent here. It is not a consonant, so it cannot
			# strand one, and it must never trigger a support vowel — that would
			# put time back into a line that corruption is supposed to take away.
			out.append(name)
			run = 0
			continue
		if VoicePhonemes.type_of(name) == VoicePhonemes.T_VOWEL:
			out.append(name)
			run = 0
			continue
		var prev_cons: bool = i > 0 and phones[i - 1] != GLITCH \
				and VoicePhonemes.type_of(phones[i - 1]) != VoicePhonemes.T_VOWEL
		var next_cons: bool = i + 1 < phones.size() and phones[i + 1] != GLITCH \
				and VoicePhonemes.type_of(phones[i + 1]) != VoicePhonemes.T_VOWEL
		out.append(name)
		run += 1
		var t: int = VoicePhonemes.type_of(name)
		var stranded: bool = (t == VoicePhonemes.T_APPROX or t == VoicePhonemes.T_NASAL) \
				and prev_cons and next_cons
		if (stranded or run >= 4) and next_cons:
			out.append("IH")
			run = 0
	return out


## Is this token a word MOTHER would leave unaccented?
static func is_function_word(word: String) -> bool:
	return FUNCTION_WORDS.has(word)


# ==========================================================================
# INTERNALS
# ==========================================================================

static func _flush_word(out: Array[Dictionary], buf: String, decayed: bool = false) -> void:
	if buf.is_empty():
		return
	# A whole word the decay pass ate down to one ambiguous character. Emitted as
	# damage so it costs no time and dents the word beside it, instead of being
	# read aloud as a letter name.
	if decayed and (buf == "X" or buf == "0"):
		var eaten: PackedStringArray = PackedStringArray()
		eaten.append(GLITCH)
		out.append({"kind": "word", "text": buf, "phones": eaten,
				"func_word": false})
		return
	var phones: PackedStringArray = word_to_phones(buf)
	if phones.is_empty():
		return
	out.append({
		"kind": "word",
		"text": buf,
		"phones": phones,
		"func_word": FUNCTION_WORDS.has(buf),
	})


## `?` and `!` are in BOTH the corruption glyph set and the punctuation table.
##
## In a DECAYED line they are always damage — MOTHER's canonical corpus contains
## no question mark and no exclamation mark anywhere in 800+ barks, because she
## states and never asks or shouts. So in a line the decay pass has touched, a
## `!` before a space is an eaten letter, and reading it as a sentence end was
## adding a 0.44 s pause in the middle of a word.
##
## In a CLEAN line they are punctuation at a boundary, which keeps this correct
## for anything outside her corpus — a callsign, a slot value, future text.
static func _is_terminal_punctuation(src: String, i: int, decayed: bool) -> bool:
	if decayed:
		return false
	var c: String = src[i]
	if c != "?" and c != "!":
		return false
	if i + 1 >= src.length():
		return true
	var next: String = src[i + 1]
	return next == " " or next == "\n" or next == "\t"


## A `0` that used to be a letter.
##
## Only inside a word, and only in a line that is visibly decayed — so `0400` and
## `1104`, which are real numerals in her clean corpus, still read as numbers,
## and so does a lone `0`. The letter test on either side is what separates
## `LO0G0D` from `LAYER 0`.
static func _is_eaten_zero(src: String, i: int, decayed: bool) -> bool:
	if not decayed or src[i] != "0":
		return false
	var before: bool = i > 0 and _is_letterish(src[i - 1])
	var after: bool = i + 1 < src.length() and _is_letterish(src[i + 1])
	return before or after


static func _is_letterish(c: String) -> bool:
	return (c >= "A" and c <= "Z") or c == GLYPH_MARK


static func _has_vowel(word: String) -> bool:
	for k: int in word.length():
		if VOWEL_LETTERS.contains(word[k]):
			return true
	return false


static func _fold(text: String) -> String:
	# Fast path: pure ASCII is the overwhelming majority and folding it letter by
	# letter would put a Dictionary lookup on every character of every bark.
	var ascii: bool = true
	for k: int in text.length():
		if text.unicode_at(k) > 127:
			ascii = false
			break
	if ascii:
		return text
	var out: String = ""
	for k: int in text.length():
		var c: String = text[k]
		if FOLD.has(c):
			out += String(FOLD[c])
		elif FOLD.has(c.to_upper()):
			out += String(FOLD[c.to_upper()])
		elif text.unicode_at(k) > 127:
			# Something outside Latin-1 entirely. Dropping it silently would make
			# a fully non-Latin callsign vanish; a glitch keeps her saying
			# SOMETHING where a name is, which is both honest and in character.
			out += GLYPH_MARK
		else:
			out += c
	return out


## Integer as words. Caps at 9999 — every number she reads is a layer, a shard
## count or a crew size, and if one of those reaches five digits the number is
## not the problem.
static func _say_number(digits: String) -> String:
	var n: int = digits.to_int()
	if digits.length() > 4:
		# Long digit runs are read as digits, which is also how a machine reads a
		# serial. "10056" -> ONE ZERO ZERO FIVE SIX.
		var parts: PackedStringArray = PackedStringArray()
		for k: int in digits.length():
			parts.append(ONES[digits.unicode_at(k) - 48])
		return " ".join(parts)
	return _say_int(n)


static func _say_int(n: int) -> String:
	if n < 0:
		return "MINUS " + _say_int(-n)
	if n < 10:
		return ONES[n]
	if n < 20:
		return TEENS[n - 10]
	if n < 100:
		var t: String = TENS[n / 10]
		return t if n % 10 == 0 else t + " " + ONES[n % 10]
	if n < 1000:
		var h: String = ONES[n / 100] + " HUNDRED"
		return h if n % 100 == 0 else h + " " + _say_int(n % 100)
	var th: String = _say_int(n / 1000) + " THOUSAND"
	return th if n % 1000 == 0 else th + " " + _say_int(n % 1000)


static func _focus_at(s: String, pos: int, focus: String) -> bool:
	if pos + focus.length() > s.length():
		return false
	for k: int in focus.length():
		if s[pos + k] != focus[k]:
			return false
	return true


## Match a left context, reading the pattern right-to-left and the word backwards
## from the letter before the focus.
static func _match_left(s: String, pos: int, pat: String) -> bool:
	var p: int = pat.length() - 1
	var i: int = pos - 1
	while p >= 0:
		var c: String = pat[p]
		match c:
			"#":
				var any: bool = false
				while i >= 0 and VOWEL_LETTERS.contains(s[i]):
					i -= 1
					any = true
				if not any:
					return false
			":":
				while i >= 0 and _is_cons(s[i]):
					i -= 1
			"^":
				if i < 0 or not _is_cons(s[i]):
					return false
				i -= 1
			"+":
				if i < 0 or not FRONT_VOWELS.contains(s[i]):
					return false
				i -= 1
			".":
				if i < 0 or not VOICED_CONS.contains(s[i]):
					return false
				i -= 1
			"&":
				if i < 0 or not SIBILANTS.contains(s[i]):
					return false
				i -= 1
			"@":
				if i < 0 or not U_PLAIN.contains(s[i]):
					return false
				i -= 1
			_:
				if i < 0 or s[i] != c:
					return false
				i -= 1
		p -= 1
	return true


static func _match_right(s: String, pos: int, pat: String) -> bool:
	var p: int = 0
	var i: int = pos
	while p < pat.length():
		var c: String = pat[p]
		match c:
			"#":
				var any: bool = false
				while i < s.length() and VOWEL_LETTERS.contains(s[i]):
					i += 1
					any = true
				if not any:
					return false
			":":
				while i < s.length() and _is_cons(s[i]):
					i += 1
			"^":
				if i >= s.length() or not _is_cons(s[i]):
					return false
				i += 1
			"+":
				if i >= s.length() or not FRONT_VOWELS.contains(s[i]):
					return false
				i += 1
			".":
				if i >= s.length() or not VOICED_CONS.contains(s[i]):
					return false
				i += 1
			"&":
				if i >= s.length() or not SIBILANTS.contains(s[i]):
					return false
				i += 1
			"@":
				if i >= s.length() or not U_PLAIN.contains(s[i]):
					return false
				i += 1
			"%":
				var rest: String = s.substr(i)
				var hit: String = ""
				for suf: String in ["ERS", "ELY", "ING", "ED", "ES", "ER", "E"]:
					if rest.begins_with(suf):
						hit = suf
						break
				if hit.is_empty():
					return false
				i += hit.length()
				# A suffix is by definition word-FINAL. Without this the "ES" of
				# PROCESS satisfies the class and the O is spoken long.
				if i < s.length() and s[i] != " ":
					return false
			_:
				if i >= s.length() or s[i] != c:
					return false
				i += 1
		p += 1
	return true


static func _is_cons(c: String) -> bool:
	return c >= "A" and c <= "Z" and not VOWEL_LETTERS.contains(c)
