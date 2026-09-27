; Stationery — the suite-wide Player setting's menu items, for the widgets that show what is playing (Turntable,
; Studio VU). Original work, MIT licensed.
; Player (Variables.inc) is the player these widgets prefer, Music or Spotify. Deskset shows whichever of the two is
; playing, so the setting decides which comes first and which one "Open…" opens. The item writes Variables.inc and
; refreshes the whole suite, as the other suite items do (Suite/Tokens.inc). Include it after Suite/Tokens.inc.

[Variables]
MenuPlayerTitle=[#MenuPlayer[#Player]]
MenuPlayerAction=[!WriteKeyValue Variables Player [#PlayerNext[#Player]] "#@#Variables.inc"][!RefreshGroup Stationery]
PlayerNextMusic=Spotify
PlayerNextSpotify=Music
MenuOpenPlayerTitle=[#MenuOpenPlayer[#Player]]
; the preferred player's name ("Music", "Spotify")
PlayerDisplayName=[#PlayerName[#Player]]
