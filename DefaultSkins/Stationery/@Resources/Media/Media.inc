; Stationery — what the media widgets share. Original work, MIT licensed.
;
; Now Playing and Spectrum (and the collection's Turntable and Studio VU) include this file after Suite/Styles.inc:
;     @Include4=#@#Media/Media.inc
; It brings the suite's Player item and the media widgets' words (Media/Strings-<Language>.inc).
;
; Player (Variables.inc) is the player a media widget prefers and opens: Music or Spotify. Whichever of the two is
; playing is still shown. Deskset reads only these two players; other apps, web browsers among them, can't be shown.

[Variables]
@IncludeMediaStrings=#@#Media/Strings-#Language#.inc

; ---------------------------------------------------------------- the players
; 1 Music, 2 Spotify: the index of the preferred player, and the other one
PlayerIndexMusic=1
PlayerIndexSpotify=2
PlayerNextMusic=Spotify
PlayerNextSpotify=Music
; the apps, by index (opening an app by its path asks for nothing)
PlayerApp1=/System/Applications/Music.app
PlayerApp2=/Applications/Spotify.app
PlayerAppMusic=/System/Applications/Music.app
PlayerAppSpotify=/Applications/Spotify.app

; ---------------------------------------------------------------- the suite's Player item
; A media widget lists it with its own items (titles from the Strings, current value shown); like every suite item
; it writes Variables.inc and refreshes the whole suite:
;     ContextTitleN=#MenuPlayerTitle#    ContextActionN=#MenuPlayerAction#
MenuPlayerTitle=[#MenuPlayer[#Player]]
MenuPlayerAction=[!WriteKeyValue Variables Player [#PlayerNext[#Player]] "#@#Variables.inc"][!RefreshGroup Stationery]

; ---------------------------------------------------------------- for widgets that name the preferred player
; the card's "Open …" item ("Open Music"), as Turntable and Studio VU show it
MenuOpenPlayerTitle=[#MediaOpen[#PlayerIndex[#Player]]]
