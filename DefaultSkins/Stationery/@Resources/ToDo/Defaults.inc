; Stationery · To Do — the list's defaults, its run-time state and its lookup tables. Original work, MIT licensed.
;
; Every size includes this file before Stationery.inc (Deskset's settings folder), where the list is kept, so the
; user's items win and a slot the file does not have reads as empty. Stationery.inc holds, per slot 1–12:
;   Todo<n>       the item's text, escaped as it was typed (an empty text is a free slot)
;   TodoDone<n>   0 open, 1 done
;   TodoOrder<n>  when the item was added (UTC seconds since 1601): the list shows the newest first

[Variables]
Todo1=
TodoDone1=0
TodoOrder1=0
Todo2=
TodoDone2=0
TodoOrder2=0
Todo3=
TodoDone3=0
TodoOrder3=0
Todo4=
TodoDone4=0
TodoOrder4=0
Todo5=
TodoDone5=0
TodoOrder5=0
Todo6=
TodoDone6=0
TodoOrder6=0
Todo7=
TodoDone7=0
TodoOrder7=0
Todo8=
TodoDone8=0
TodoOrder8=0
Todo9=
TodoDone9=0
TodoOrder9=0
Todo10=
TodoDone10=0
TodoOrder10=0
Todo11=
TodoDone11=0
TodoOrder11=0
Todo12=
TodoDone12=0
TodoOrder12=0
; run-time state (never written): the first row shown, the edit box's slot and mode, Clear Completed at work,
; the circle under the pointer and its disc, and the variable the edit box's trigger sets
Offset=0
Editing=0
EditSlot=1
Adding=0
Clearing=0
HoverSlot=1
PadShown=0
PadPressed=0
Typed=
; tables read through nested variables: by done (0 / 1), by the circle's press, by a full list
CheckSymbol0=circle
CheckSymbol1=checkmark.circle.fill
CheckTint0=#SecondaryTextColor#
CheckTint1=#AccentColor#
ItemAlpha0=#Alpha1#
ItemAlpha1=#Alpha3#
Strike0=None
Strike1=Strikethrough
PadFill0=#HoverColor#
PadFill1=#PressedColor#
AddTint0=#AccentTextColor#
AddTint1=#FaintColor#
; one relayout after any change: the list's measures, then its meters
Relayout=[!UpdateMeasureGroup List][!UpdateMeterGroup Items][!Redraw]
