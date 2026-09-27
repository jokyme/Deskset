; Stationery · Sentence Clock — the words' own alphas in the Dark look (and the Clear look). Original work, MIT
; licensed. The same names as Theme-Light.inc.

[Variables]
; lit words (98 %)
OnA=250
; unlit words (18 %), with "Unlit Words: Visible" (26 %), and while the pointer is over the words (33 %)
OffSubtle=46
OffVisible=66
OffHover=84
; a soft white glow on the lit words, like a backlit word clock. A text shadow's alpha is multiplied by the text's, so
; the unlit words get almost none of it. SentenceGlow (Variables.inc) turns it off
WordGlow=Shadow | 0 | 0 | 6 | 255,255,255,(128 * #SentenceGlow#)
RuleA=46
