; Stationery · Photo Frame — its words in English. Original work, MIT licensed.
; Strings-Chinese.inc has the same keys. "%1" is the folder's name; a value may name a measure ([MeasureEvery]): it is
; read when the text is shown, so it follows the menu. Menu titles are Title Case and at most 30 characters.

[Variables]
PhotoWidget=Photo Frame
; the folder the path field suggests, ~/Pictures, by the name Finder gives it
PhotoPictures=Pictures
; the Notice by mode (2 no folder chosen yet, 3 a chosen folder shows nothing, 5 the path field): the
; Small's title (S) and the Medium's and Large's
PhotoTitleS2=Choose a Folder
PhotoTitle2=Choose a Folder of Photos
PhotoTitleS3=No Photos Found
PhotoTitle3=No Photos Found
PhotoTitleS5=Choose a Folder
PhotoTitle5=Choose a Folder
PhotoBodyS2=Show photos from any folder on your Mac.
PhotoBody2=[MeasureEvery], a photo from the folder fills the frame. For pictures in the Photos app, export them to a folder.
PhotoBodyS3=Nothing to show from “%1”.
PhotoBody3=Nothing to show from “%1”. Photo Frame shows JPEG, PNG, HEIC and WebP files.
PhotoBodyS5=Paste its path below. In Finder, select the folder and press ⌥⌘C.
PhotoBody5=Type or paste the folder’s path below, then press Return. In Finder, select the folder and press ⌥⌘C to copy its path.
PhotoChooseAction=Choose Folder…
; how often a new photo comes (PhotoInterval, in seconds)
PhotoEvery600=Every 10 minutes
PhotoEvery3600=Every hour
PhotoEvery86400=Once a day
PhotoEveryLower600=every 10 minutes
PhotoEveryLower3600=every hour
PhotoEveryLower86400=every day
PhotoMenuPreview=Open in Preview
PhotoMenuFinder=Show in Finder
PhotoMenuChoose=Choose Folder…
PhotoMenuEvery600=Change Photo: Every 10 Min
PhotoMenuEvery3600=Change Photo: Hourly
PhotoMenuEvery86400=Change Photo: Daily
PhotoMenuFileName0=File Name: Off
PhotoMenuFileName1=File Name: On
; the tooltips: on the photo, on the loading tile, and on the card by mode (as the Notice)
PhotoTip=In [MeasureParentName]. Click for the next photo; a new one comes [MeasureEveryLower].
PhotoTipLoading=Looking for photos in [MeasureFolderName]…
PhotoTipTitle2=Photo Frame
PhotoTip2=Choose the folder whose photos the frame shows: click, then paste its path. Photos in the Photos app can’t be shown; export them to a folder first.
PhotoTipTitle3=No Photos Found
PhotoTip3=Nothing to show from “[MeasureFolderName]”. The folder may be empty, missing or unreadable, or hold no JPEG, PNG, HEIC or WebP files. Click to choose another.[MeasureHint]
PhotoTipTitle5=Photo Frame
PhotoTip5=Paste the folder’s path and press Return. Escape cancels.
; a second line for folders macOS guards (Desktop, Documents, Downloads, iCloud Drive, other disks); it starts with a
; line break, because a value loses its leading spaces
PhotoHint0=
PhotoHint1=#CRLF#If macOS asked for access and it was refused, allow Deskset in System Settings › Privacy & Security › Files & Folders.
