# Audio: AudioLevel, Win7Audio, AppVolume (Mac vs Windows)

Code: `Sources/Deskset/Plugins/Audio/` (app target; registered by `AudioPlugins.register()`). Tests: `Deskset --self-test "App: Audio"`.
Regression skins: `TestSkins/Audio/Visualizer` (spectrum + stereo meters), `TestSkins/Audio/Volume` (volume slider, mute,
output switch, media keys).

`Measure=MediaKey` is not part of this area any more: it lives in `Sources/Deskset/Plugins/Media/` (registered by
`MediaUIPlugins`) and is described in [`media-ui.md`](media-ui.md#mediakey-measuremediakey).

Sources: the public manual only — https://docs.rainmeter.net/manual/plugins/audiolevel/,
https://docs.rainmeter.net/manual/plugins/win7audio/, the version history — plus, for AppVolume (third party), the usage section of its public README
(https://github.com/khanhas/AppVolumePlugin, README only), and how skins in the local test corpus use these plugins
(Nelamint and Simple Clean visualizers, Enigma and PogPack volume skins). No plugin source code was read.

## Permissions at a glance

| Feature | macOS permission (asked the first time a skin needs it) | Info.plist key | When refused |
|---|---|---|---|
| AudioLevel `Port=Output` (macOS 14.2+) | System Audio Recording ("Screen & System Audio Recording → System Audio Recording Only") | `NSAudioCaptureUsageDescription` | Levels read 0 (macOS delivers silence); a compatibility note once the silence watchdog suspects a refusal |
| AudioLevel `Port=Output` (macOS 13 – 14.1) | Screen Recording, then restart Deskset | — | Levels read 0, `DeviceStatus` 0, logged once, compatibility note |
| AudioLevel `Port=Input` | Microphone | `NSMicrophoneUsageDescription` | Levels read 0, `DeviceStatus` 0, logged once, compatibility note; tried again every 10 s |
| AppVolume `NumberType=Peak`, `Mute` | System Audio Recording | `NSAudioCaptureUsageDescription` | Peak 0; mute has no effect |
| Win7Audio | none | — | — |

(MediaKey's Accessibility permission: see [`media-ui.md`](media-ui.md).)

Nothing audio-related runs until a skin uses one of these plugins, and only a skin in a skin window captures (from its
first update, see [When a capture starts](#when-a-capture-starts)): the Manage window's check of a skin that is not
loaded, `--render` and the other command-line modes (`--self-test`…) never capture and never prompt.

### Refused permissions become compatibility notes
- Windows (Rainmeter): no permissions.
- Mac (Deskset): an AudioLevel parent turns its source's refused permission into a compatibility note of its skin (the
  microphone; Screen Recording on macOS 13 – 14.1; the silence watchdog's note for System Audio Recording, see
  `Port=Output`), and takes the note back when the source reports it no longer: a source refused the microphone is
  started again every 10 seconds (macOS sends no notification when the user allows it later), and the silence note is
  cleared as soon as sound arrives. The full list of permission notes, from every area, is in
  [`app.md`](app.md#refused-permissions-become-compatibility-notes).
- Why: users need to know why a visualizer stays at 0 and where to fix it — and not after they fixed it.
- Skin impact: none.
- Status: Deskset extension

---

## AudioLevel

### Plugin=AudioLevel
- Windows (Rainmeter): built-in plugin; "monitors the amplitude of the post-mixer signal at a Windows audio endpoint … by
  creating a WASAPI capture client in loopback mode" (/manual/plugins/audiolevel/).
- Mac (Deskset): `Plugin=AudioLevel` (also `AudioLevel.dll`, `Plugins\AudioLevel.dll`) is implemented natively. One shared
  capture engine serves every AudioLevel parent of every skin: a stream is captured once however many parents and skins
  use it, starts at the first update of the first parent in a skin window and stops 3 s after the last one is gone (a
  refresh does not tear it down).
  The audio thread only copies samples into a ring buffer (no allocation, no blocking); analysis runs on a background
  thread about 60 times per second; measures read the latest values.
- Why: WASAPI does not exist on macOS.
- Skin impact: none for skin authors. Cost measured on Apple Silicon: 0.1–0.3 % of one core for the visualizers in the
  corpus (FFTSize 1024–4096, 16–121 bands); an absurd FFTSize=65536/FFTOverlap=65535/Bands=1024 stays under 10 %.
  Digital silence skips the FFT entirely.
- Status: emulated

### Port=Output (system audio), macOS 14.2 and later
- Windows (Rainmeter): loopback capture of the default (or `ID`) output endpoint.
- Mac (Deskset): a Core Audio process tap. Without `ID`: a private global stereo tap of every process (a mixdown of all
  audio apps play), read through a private aggregate device clocked by the default output device. With an `ID` that names
  an output device: a tap of that device's output stream. The tap is recreated when the default output device changes,
  when devices come and go, and when the output device's sample rate changes (≈ 0.3 s gap). An output device that also
  has inputs is not put into the aggregate (see the next entry).
- Why: process taps are the public API for system audio capture on macOS (14.2+).
- Skin impact: macOS asks once for "System Audio Recording"; while a visualizer is loaded macOS shows its purple
  audio-recording indicator in the menu bar, and the output device stays active (as with any app that records system
  audio; not for output devices with inputs, see the next entry). If the user refuses, macOS delivers silence: every
  level is 0 and Deskset cannot tell a refusal from silence for sure (`DeviceStatus` stays 1). A watchdog looks every
  10 s: a stream that carried only digital silence at two looks in a row while another app was playing sound gets a
  compatibility note pointing to the permission, which goes away as soon as sound arrives. The tap captures what apps
  play; the output device's own volume and mute are expected to apply after it, so turning the Mac's volume down
  should not shrink the meters (not verified: see "Verification" below).
- Status: emulated

### Port=Output with an output device that also has inputs (USB audio interfaces, headsets, BlackHole)
- Windows (Rainmeter): loopback capture never touches the endpoint's microphone.
- Mac (Deskset): the private aggregate device that reads the tap normally has the output device as its main sub-device
  (its clock drives the aggregate). A sub-device brings all its streams, inputs included: checked on macOS 26.5 with
  BlackHole 2ch as the sub-device, the aggregate had 4 input channels (BlackHole's 2 + the tap's 2) instead of 2. Running
  it would record that device's inputs too — the Microphone permission and the orange indicator for an audio
  interface's or a headset's microphone, and Bluetooth headsets switching to their low-quality call profile while a
  visualizer runs. So when the output device has input channels, the aggregate holds only the tap (no sub-device). That
  is also what macOS itself builds when the default output is a Multi-Output Device (checked: an aggregate cannot contain
  one, it is dropped and only the tap remains).
- Why: judgment call to keep a speaker visualizer from ever recording a microphone. The tap-only aggregate is created and
  accepted (2 input channels at 48 kHz, no output streams) but, like every capture path, it was not run with the
  permission granted (see "Verification").
- Skin impact: none intended; if system-audio levels stay at 0 with such a device as the output but work with the
  built-in speakers, this is the place to look.
- Status: emulated

### Port=Output on macOS 13 – 14.1
- Windows (Rainmeter): as above.
- Mac (Deskset): ScreenCaptureKit audio capture of the whole system mix (48 kHz stereo), with a 2×2-pixel, 1 fps video
  stream that is ignored. Needs the Screen Recording permission; `CGRequestScreenCaptureAccess` is called once and the user
  must restart Deskset after granting it. `ID` cannot select a device here (always the system mix).
  (`DESKSET_AUDIO_FORCE_SCK=1` forces this path on newer systems, for testing.)
- Why: process taps do not exist before 14.2; ScreenCaptureKit is the only public system-audio source on 13 – 14.1.
- Skin impact: a Screen Recording prompt for an audio visualizer is surprising; values are 0 until it is granted and Deskset
  restarted.
- Status: emulated (untested on those macOS versions; built and type-checked only)

### Port=Input
- Windows (Rainmeter): capture of the default (or `ID`) input endpoint.
- Mac (Deskset): an IOProc directly on the input device (default input, or the device named by `ID`); follows default-input
  changes. The Microphone permission is requested the first time; capture starts as soon as it is granted.
- Why: —
- Skin impact: while capturing, macOS shows the orange microphone indicator. Refused → 0, `DeviceStatus` 0, one log
  line and a compatibility note; the source is started again every 10 s, so allowing the microphone later in System
  Settings starts the levels (and removes the note) without a restart.
- Status: identical (behaviour), different permission UI

### Port (invalid values)
- Windows (Rainmeter): `Output` (default) or `Input`.
- Mac (Deskset): anything else is logged and treated as `Output`.
- Why: judgment call (manual silent).
- Skin impact: none for valid skins.
- Status: identical for documented values

### ID
- Windows (Rainmeter): a Windows endpoint ID such as `{0.0.0.00000000}.{5c106e65-…}`; see `Type=DeviceList`.
- Mac (Deskset): a Core Audio device UID (e.g. `BuiltInSpeakerDevice`, `AppleUSBAudioEngine:…`), or — convenience — a device
  name (case-insensitive, e.g. `ID=MacBook Pro Microphone`). An ID that matches nothing (every Windows ID) falls back to the
  default device of the port, logged once as a notice.
- Why: Windows endpoint IDs have no meaning on a Mac.
- Skin impact: skins shipped with a Windows ID keep working on the default device. `Type=DeviceList` shows the IDs to use.
- Status: emulated

### Parent / child model
- Windows (Rainmeter): a parent (no `Parent=`) captures and analyses; children (`Parent=Name`) read values. "Only the Type,
  Channel, FFTIdx and BandIdx child measure options can be changed dynamically … Parent measure options may not be changed
  dynamically."
- Mac (Deskset): same. Parent options (Port, ID, RMS*/Peak*/FFT*/Bands/Freq*/Sensitivity) are read once when the parent is
  first read; `!SetOption`/`DynamicVariables` do not change them. Child options (Type, Channel, FFTIdx, BandIdx, and Parent
  itself) are re-read normally. A parent that is `Disabled=1` at load does not start any capture until it is enabled;
  a parent disabled later (`!DisableMeasure`) keeps its capture (and the recording indicator) until the skin is
  refreshed or unloaded. The capture of a skin stops 3 s after the skin object is released (checked with the registry
  wired: releasing the skin removes the output source after the grace period). The parent must be in the same skin.
- Why: manual.
- Skin impact: none.
- Status: identical

### When a capture starts
- Windows (Rainmeter): the plugin works in loaded skins; Windows asks nothing before a loopback capture.
- Mac (Deskset): a parent reads its options when the skin loads but starts its capture at its first update, and only
  in a skin window. A skin that is only read — the Manage window checks skins that are not loaded for their
  compatibility notes — or drawn with `--render` never captures: no permission prompt, no recording indicator; in a
  render the levels read 0 and `DeviceStatus` 0, unless `DESKSET_AUDIO_DEMO=1` feeds it the demo signal. AppVolume's
  peak taps follow the same rule.
- Why: macOS shows its permission prompt and the recording indicator as soon as a capture starts. Found in review:
  selecting a visualizer that was not loaded in the Manage window started a capture (the check loaded the skin, and
  loading a parent subscribed it).
- Skin impact: none; a visualizer reads 0 in its first update either way (the capture starts in the background).
- Status: identical

### Value of the parent measure
- Windows (Rainmeter): not documented.
- Mac (Deskset): 0, unless the parent itself has a `Type=` — then it answers like a child of itself (e.g. a parent with
  `Type=RMS` reads its own RMS).
- Why: judgment call; harmless for skins that never read the parent, useful for single-measure skins.
- Skin impact: none known.
- Status: emulated

### Broken wiring
- Windows (Rainmeter): not documented.
- Mac (Deskset): a child whose `Parent` is missing, is not an AudioLevel measure, or is itself a child reads 0 (strings "")
  and logs one warning. Unknown `Type` → 0 and a warning; unknown `Channel` → Sum and a warning.
- Why: judgment call; never crash.
- Skin impact: the log names the problem.
- Status: emulated

### Channel
- Windows (Rainmeter): `L/FL/0, R/FR/1, C/2, LFE/Sub/3, BL/4, BR/5, SL/6, SR/7, Sum/Avg` (default Sum).
- Mac (Deskset): same names. The default system stream is a stereo mixdown, so `C`, `LFE`, `BL`, `BR`, `SL`, `SR` read 0
  there. With an `ID` naming a multichannel device (or an input device) the channel number is the position in the
  device's stream (0, 1, 2…), which follows the device's own channel layout rather than Windows' speaker order. Mono
  streams (most microphones) answer `L`, `R` and `C` with their only channel.
  `Sum`/`Avg` is the average of the channels: RMS = √(mean of the channels' mean squares), Peak = mean of the channels'
  peaks, FFT/Band = mean of the channels' power. Anything else (`Left`, `8`, `(1)`) is logged once and read as Sum; at
  most 8 channels are analysed.
- Why: macOS mixes apps to stereo for the global tap; channel order is device-specific.
- Skin impact: 5.1/7.1 channel meters stay at 0 unless the skin names the multichannel device with `ID`.
- Status: partial

### Type=RMS, RMSAttack, RMSDecay, RMSGain
- Windows (Rainmeter): "the signal value is squared, averaged over a period of time, then the square root … is
  calculated"; RMSAttack/RMSDecay (300 ms) are the times "over which to interpolate as the signal level increases /
  decreases"; RMSGain multiplies; value 0.0–1.0; "To disable all RMS filtering, set both RMSAttack and RMSDecay to 0".
- Mac (Deskset): the mean square of every 5 ms slice drives a one-pole follower whose time constant is RMSAttack while the
  level rises and RMSDecay while it falls (after one time constant it has covered 63 % of a step); value =
  √(filtered mean square) × RMSGain, clipped to 0…1. With both times 0 it is the RMS of the latest 5 ms slice. A
  full-scale sine reads 0.707.
- Why: the manual gives the intent, not the formula; a time-constant follower is the standard meaning of attack/decay
  times.
- Skin impact: needle speeds may differ slightly from Windows; the steady-state level of a signal is the true RMS.
- Status: emulated

### Type=Peak, PeakAttack, PeakDecay, PeakGain
- Windows (Rainmeter): like RMS but measuring peaks; defaults 50 ms / 2500 ms / 1.0.
- Mac (Deskset): the largest |sample| of each 5 ms slice drives the same kind of follower (PeakAttack rising, PeakDecay
  falling); × PeakGain, clipped to 0…1. A full-scale sine reads 1.0; after the sound stops the default peak falls to 37 % in
  2.5 s.
- Why: as for RMS.
- Skin impact: as for RMS.
- Status: emulated

### Values when nothing plays or capture stops
- Windows (Rainmeter): the version history lists a fix for the plugin "keep[ing] the last values it received" when sound
  stops.
- Mac (Deskset): when no audio arrives for 0.1 s (device stopped, capture interrupted) every value falls with its own decay
  time; they never freeze. When a capture stops (last skin gone, device lost) values are reset to 0.
- Why: matches the fixed behaviour.
- Skin impact: none.
- Status: identical

### FFTSize, FFTOverlap (and Type=FFT, FFTIdx)
- Windows (Rainmeter): FFTSize "an even integer greater than or equal to 0, usually a power of 2" (default 0 = off);
  FFTOverlap: "the FFT can be windowed to overlap successive sections. A Hann function is used"; FFTIdx 0…FFTSize/2; FFT
  value 0.0–1.0.
- Mac (Deskset): every FFTSize − FFTOverlap samples the latest FFTSize samples of each channel are Hann-windowed (periodic)
  and transformed with Accelerate/vDSP. Odd sizes are rounded up to even; sizes vDSP cannot transform directly (e.g. 1000)
  are zero-padded to the next supported length and the spectrum is read back on the FFTSize grid, so FFTIdx/FFTFreq keep
  their meaning. FFTSize is limited to 65536; FFTOverlap to FFTSize − 1. The spectrum is computed at most once per analysis
  tick (≈ 60 per second): a larger overlap lowers latency up to that rate. `FFTIdx` outside 0…FFTSize/2 reads 0. Per-bin
  values are computed only once some measure reads `Type=FFT` (bands do not need them).
- Why: judgment calls where the manual is silent (size limits, non-power-of-two sizes, update rate).
- Skin impact: none for normal sizes.
- Status: emulated

### Sensitivity and the 0…1 scale of FFT and Band values
- Windows (Rainmeter): "A number specifying in what dB range the measure will return FFT and Band data. Increasing this
  value will cause the measure to respond to quieter sounds" (default 35).
- Mac (Deskset): power is normalised so that a full-scale sine centred on a bin is 0 dB; value =
  `1 + (dB + 10) / Sensitivity`, clipped to 0…1. So Sensitivity is exactly the dB range shown, and 1.0 is reached at
  −10 dB (a band holding, per octave, the energy of a −10 dBFS sine). The +10 dB reference is a calibration choice: with
  pink noise at typical streaming loudness (−14…−10 dBFS RMS) bands read about 0.45–0.7 at Sensitivity 35 and 0.25–0.55
  at 25, with bass hits reaching the top — what the corpus visualizers are tuned for.
- Why: the manual does not define the reference level; Rainmeter's own scale could not be checked without its source.
- Skin impact: bar heights may be somewhat taller or shorter than on Windows for the same music; `Sensitivity` adjusts it.
- Status: emulated (calibrated judgment call)

### FFTAttack, FFTDecay
- Windows (Rainmeter): interpolation times for rising / falling FFT levels (default 300 / 300 ms).
- Mac (Deskset): applied to the 0…1 values of every FFT bin and band (one-pole follower, time constant = attack while
  rising, decay while falling). E.g. `FFTDecay=2500` (the corpus' "slow" peak line) falls to 37 % in 2.5 s.
- Why: smoothing the displayed value (rather than the power) makes decay times match what skin authors expect visually.
- Skin impact: none known.
- Status: emulated

### Bands, FreqMin, FreqMax, Type=Band, BandIdx
- Windows (Rainmeter): "The FFT data can be extrapolated into a number of log-spaced frequency bands"; FreqMin 20,
  FreqMax 20000; BandIdx 0…Bands−1; needs FFTSize and Bands on the parent.
- Mac (Deskset): band i spans FreqMin·r^i … FreqMin·r^(i+1) with r = (FreqMax/FreqMin)^(1/Bands). A band's power is the
  integral of the power spectrum over its range (linear interpolation between bin centres, so bands narrower than a bin
  still read smoothly, corrected for the Hann window's noise bandwidth), divided by the band's width in octaves. Pink
  noise therefore draws a flat line, and a band's value does not depend on how many bands split the range (a skin with
  121 bands and one with 10 read the same level). The part of a band above the stream's Nyquist frequency (half the
  sample rate) contributes nothing; a band entirely above it reads 0. Bands are limited to 1024; FreqMin ≥ 1 Hz; FreqMin/FreqMax given the wrong way round are swapped.
  `Type=Band` without FFTSize/Bands reads 0 and logs a warning.
- Why: the manual says "log-spaced" but not how bins are combined; per-octave density is the choice that keeps
  high-band-count skins (81, 121 bands in the corpus) as lively as the manual's 10-band example.
- Skin impact: spectrum shapes are flat for pink noise and rise 3 dB/octave for white noise.
- Status: emulated

### Type=FFTFreq, Type=BandFreq
- Windows (Rainmeter): "The frequency in Hz corresponding to the specified FFTIdx / BandIdx option."
- Mac (Deskset): FFTFreq = FFTIdx × sample rate / FFTSize, using the captured stream's rate (48000 Hz on most Macs, 44100 Hz
  on some devices; the device's nominal rate or 48000 before capture starts). BandFreq = the band's geometric centre
  √(low × high edge), independent of the stream.
- Why: the manual does not say whether the band frequency is an edge or the centre; the centre is the conventional label.
- Skin impact: labels may differ from Windows by up to half a band.
- Status: emulated

### Type=Format
- Windows (Rainmeter): "A string describing the audio format of the device."
- Mac (Deskset): e.g. `48000 Hz, 32-bit float, 2 channels` (the captured stream); before capture starts, the device's
  nominal format without bit depth (`48000 Hz, 2 channels`).
- Why: format text not documented.
- Skin impact: different wording than on Windows.
- Status: emulated

### Type=DeviceStatus
- Windows (Rainmeter): "Status (0 or 1) of the device."
- Mac (Deskset): 1 while the capture runs, 0 otherwise (no device, microphone refused, Screen Recording missing on 13–14.1,
  command-line mode). A refused System Audio Recording permission cannot be detected (macOS delivers silence), so it reads 1.
- Why: see Port=Output.
- Skin impact: "device unavailable" hints may not appear when the tap permission was refused.
- Status: partial

### Type=DeviceName, Type=DeviceID
- Windows (Rainmeter): name / Windows ID of the device connected to.
- Mac (Deskset): the Core Audio device name (localised, e.g. "MacBook Pro Speakers") and UID. Available even when nothing is
  captured (from the device list). The device list is read in the background the first time a skin needs it (an
  AudioLevel parent's first update in a skin window, or the first device name a measure reads); that first read takes
  about 60 ms (measured on macOS 26.5), and the first reader waits for it up to 0.2 s once per app run, so the skin's
  first update already shows the name (a stalled Core Audio only delays that one update by 0.2 s). Win7Audio's first
  update waits the same way.
- Why: —
- Skin impact: Mac names and IDs.
- Status: emulated

### Type=DeviceList
- Windows (Rainmeter): "A string with a list of all available device IDs for the specified Port"; the history mentions a
  4096-character buffer.
- Mac (Deskset): one device per line, `UID: Name`, in Core Audio order, output devices for `Port=Output` and input devices
  for `Port=Input` (only devices that can be the default device; Deskset's own capture devices and hidden devices are left
  out). No length limit.
- Why: the list format is not documented; the name makes the UID usable.
- Skin impact: skins that parse the Windows list format will not match.
- Status: emulated

### Deskset-only switches
- Windows (Rainmeter): —
- Mac (Deskset): environment variables for development: `DESKSET_AUDIO_DEMO=1` replaces every audio stream by a generated
  demo signal (pink noise, kick, hi-hat, melody) — no permission, works with `--render`, useful for screenshots and demo
  videos; `DESKSET_AUDIO_CAPTURE=0` turns capture off in the app and `=1` on in command-line modes (for skin windows
  only: `--render` never captures real audio); `DESKSET_AUDIO_FORCE_SCK=1` uses ScreenCaptureKit instead of a process
  tap.
- Why: testing without permission prompts.
- Skin impact: none.
- Status: Deskset extension

---

## Win7Audio

### Plugin=Win7AudioPlugin
- Windows (Rainmeter): "controls the sound device and volume" of the default Windows output endpoint.
- Mac (Deskset): `Plugin=Win7AudioPlugin` (also `Win7AudioPlugin.dll`, `Plugins\Win7AudioPlugin.dll`, `Win7Audio`) works on
  the default Core Audio output device (its virtual main volume and mute). The state is cached and kept current by Core
  Audio notifications (and re-read at most once a second while a skin reads it); commands update the cached value at once,
  so `[!CommandMeasure … "ChangeVolume 10"][!Update]` shows the new value in the same click, and reach the device
  asynchronously. While a command waits to reach the device, re-reads of the device (volume notifications, the
  once-a-second re-read, device-list changes) do not overwrite the cached volume, mute state or output device: several
  commands in quick succession — a scroll wheel sending `ChangeVolume 2` many times a second, `ToggleNext` clicked twice
  — each build on the previous one instead of on the device's older value (found in review: a re-read queued just
  before a command briefly put the old volume back, and a scroll step issued in that moment was lost). The re-read after
  the last command brings the cache back in line with the device. No permission is needed.
- Why: —
- Skin impact: none.
- Status: emulated

### Number value
- Windows (Rainmeter): "The percentage (0-100) of current volume level."
- Mac (Deskset): the volume rounded to a whole percent; **−1 while muted**; 100 for a device without a volume control
  (HDMI, some USB DACs, a Multi-Output Device — audio plays at full level, and macOS's own volume keys cannot change it
  either). MaxValue defaults to 100.
- Why: −1 for "muted" is not in the manual but is what skins rely on (the corpus' Enigma volume skin tests
  `MeasureVolume<0` and substitutes "-1" with "Muted"; PogPack substitutes "-1" with "0").
- Skin impact: identical for skins written against the real plugin.
- Status: emulated

### String value
- Windows (Rainmeter): "The name of the current sound device"; error strings `ERROR - Getting Device Description`,
  `ERROR - Getting Property`, `ERROR - Getting Default Device`.
- Mac (Deskset): the output device's name (localised, e.g. "MacBook Pro Speakers"); `ERROR - Getting Default Device` when the
  Mac has no output device; "" for the moment before the device list is first read.
- Why: the two other errors have no macOS counterpart.
- Skin impact: Mac device names.
- Status: identical

### SetVolume x, ChangeVolume x
- Windows (Rainmeter): "Set volume to x (between 0 and 100). This disables mute." / "Change the volume by x percent. Use
  negative numbers to lower volume. This disables mute."
- Mac (Deskset): same; the result is clipped to 0…100; `+5` and formulas (`(#Step#*2)`) are accepted. On a device
  without a volume control they are refused (logged). The virtual main volume may quantise to the device's steps.
- Why: —
- Skin impact: none.
- Status: identical

### ToggleMute (and Mute, Unmute)
- Windows (Rainmeter): "Toggle the mute state."
- Mac (Deskset): toggles the device's mute. A device without a mute control but with a volume control is muted by
  setting its volume to 0 and restoring it on unmute (restored too if the output device changes meanwhile). `Mute` and
  `Unmute` are accepted as well (not in the manual; harmless).
- Why: some Mac output devices have no mute control.
- Skin impact: none.
- Status: emulated

### ToggleNext, TogglePrevious, SetOutputIndex index
- Windows (Rainmeter): switch the default output device to the next / previous one (wrapping), or to "a specific device
  with index", which "depends on your system setup and number of output devices".
- Mac (Deskset): the list is Core Audio's output devices that can be the default output (hidden devices and Deskset's own
  capture devices left out), in Core Audio order; switching sets the macOS default output device (not the "sound effects"
  device). `SetOutputIndex` is 1-based (index 1 = first device, as skin authors use it on the forums); an index outside
  1…count is ignored and logged.
- Why: judgment calls: the manual gives neither the order nor the index base; ignoring a bad index avoids switching to an
  arbitrary device.
- Skin impact: device order differs from Windows; skins with hard-coded indices point to the Mac's devices.
- Status: emulated

### Other commands
- Windows (Rainmeter): only the six documented commands.
- Mac (Deskset): unknown commands are logged and ignored.
- Status: identical

---

## MediaKey

Moved: `Measure=MediaKey` (and `Plugin=MediaKey`) is implemented once, in `Sources/Deskset/Plugins/Media/`, and
documented in [`media-ui.md` → MediaKey](media-ui.md#mediakey-measuremediakey) (media keys with Accessibility, player
commands and direct volume changes without it; `Stop` goes to the player). An earlier audio-area implementation
described here (Accessibility requested on the first key, 1/16 volume steps, `Stop` ignored) no longer exists.

---

## AppVolume (third-party plugin)

### Plugin=AppVolume
- Windows (plugin README): per-app audio sessions: the parent's number is the number of apps, its string the current
  device; children (`Parent`, `Index` 1-based or `AppName`, `NumberType`/`NumType` Volume|Peak, `StringType`
  FileName|FilePath) read one app; commands Update, SetVolume x (absolute or ±relative), Mute, UnMute, ToggleMute; section
  variables `GetVolumeFromIndex(x)`, `GetPeakFromIndex(x)`, `GetFileNameFromIndex(x)`, `GetFilePathFromIndex(x)`,
  `GetVolumeFromAppName(name)`, `GetPeakFromAppName(name)`; `IgnoreSystemSound` (default 1), `ExcludeApp=a.exe;b.exe`.
- Mac (Deskset): the app list is Core Audio's list of audio client processes (macOS 14.2+, refreshed at most every 2 s in
  the background): Dock apps that use Core Audio, plus — with `IgnoreSystemSound=0` — any other process that is playing
  (system sounds, helpers). Deskset itself and `ExcludeApp` entries are left out. Names are executable names without
  ".exe" (`Spotify`); `AppName`/`ExcludeApp` match with or without ".exe", case-insensitively, and also match the bundle
  ID. FilePath is the executable path (`/Applications/Spotify.app/Contents/MacOS/Spotify`). The section variables work
  on the parent (they need `DynamicVariables=1`, as on Windows).
  Browsers and some other apps play through helper processes (Safari through `com.apple.WebKit.GPU`, Chromium browsers
  through their helper processes): the app itself may be listed with no sound of its own, and its sound belongs to the
  helper, which is listed (under the helper's executable name) only with `IgnoreSystemSound=0`.
- Why: macOS has no per-app audio sessions before 14.2 and no per-app volume at all.
- Skin impact: see the entries below; before macOS 14.2 the list is empty (number 0).
- Status: partial

### AppVolume volume and SetVolume
- Windows (plugin README): each app's own volume, settable (`SetVolume 50`, `SetVolume +20`); the README does not give
  the number range of `NumberType=Volume`.
- Mac (Deskset): always 1.0 (0 while muted by Deskset), i.e. the 0…1 range (judgment: the README is silent; 0…1 matches
  `Peak` and fills a bar with the default MaxValue); `SetVolume` is refused and logged.
- Why: macOS has no per-app volume; faking one would require re-routing every app's audio.
- Skin impact: per-app volume sliders do nothing.
- Status: not supported

### AppVolume peak
- Windows (plugin README): each app's peak level.
- Mac (Deskset): a child with `NumberType=Peak` gets its app's peak from a process tap of that app (instant attack, 300 ms
  decay); needs System Audio Recording. Only a skin in a skin window taps an app (a render reads 0, see
  [When a capture starts](#when-a-capture-starts)). `GetPeakFrom…` returns the peak of an app one of the parent's peak
  children follows, else 0.
- Why: one tap per followed app keeps the cost proportional to what the skin shows.
- Skin impact: permission prompt as for AudioLevel.
- Status: emulated

### AppVolume mute
- Windows (plugin README): Mute / UnMute / ToggleMute per app.
- Mac (Deskset): muting creates a muted process tap for that app (macOS 14.2+), which silences it until it is unmuted, the
  app quits or Deskset quits. The mute state skins read changes at once and the tap follows in the background; a failed
  tap (permission refused, the app went away) clears it again. Command-line modes never create taps.
- Why: the only public way to silence one app on macOS.
- Skin impact: needs System Audio Recording; not verified (see "Verification"). Unloading or refreshing the skin does
  not unmute the app (on Windows the mute is the system mixer's own state and outlives the skin too); unlike Windows,
  macOS has no mixer to unmute it from, so it plays again when a skin unmutes it or Deskset quits.
- Status: emulated

### AppVolume Index, Update and section variables
- Windows (plugin README): `Index` "has to be in range from 1 to number value of Parent measure"; `Update` re-reads the
  options "so you do not have to set DynamicVariables = 1"; the `Get…(x)` section variables on the parent.
- Mac (Deskset): `Index` outside 1…count (and an `AppName` that matches nothing) reads 0 with an empty string; `AppName`
  wins over `Index` when both are set (judgment). `Update` re-reads the measure's options. `GetVolumeFrom…` return
  `1`/`0` (muted), `GetPeakFrom…` the peak (see above), `GetFileNameFromIndex`/`GetFilePathFromIndex` the names, and
  an index or name that matches nothing gives `0` (numbers) or an empty string (names). Commands other than Update need
  a child measure (logged on the parent).
- Why: README silent on the out-of-range results.
- Skin impact: none known.
- Status: emulated

---

## Verification

- Verified by the self-tests (`Deskset --self-test "App: Audio"`, no permission involved): RMS/peak/FFT/band maths with
  synthetic sines and noise (levels, dB mapping, attack/decay times, Hann leakage, non-power-of-two sizes, band layout,
  white-noise slope, band-count independence), the ring buffer (interleaved, non-interleaved, overflow, tap buffer
  selection), the engine with fake backends (sharing, restart debounce, stop after the last subscriber, refusal paths),
  option parsing, all measure types, Win7Audio commands against fakes, AppVolume filtering and section variables, the
  permission notes (added, and taken back once the microphone is allowed or sound arrives), which skins capture (the
  Manage window's check of a skin that is not loaded and a render subscribe nothing; a skin window subscribes at its
  first update, not when it loads; AppVolume taps no app outside a skin window), and a read-only pass over this Mac's
  real device list and output volume.
- Verified by rendering: the corpus volume skins (Enigma, PogPack) show the Mac's real output device and volume; the
  corpus visualizers (Nelamint, Simple Clean) and `TestSkins/Audio/Visualizer` animate with `DESKSET_AUDIO_DEMO=1`.
- Verified with a throw-away program on macOS 26.5 (Apple Silicon), without starting any IO (so without a permission
  prompt): the global tap and the device tap are created, deliver interleaved Float32 stereo at the device rate (48 kHz),
  the private aggregate device built from them is accepted with the tap as its only input stream (and is filtered out of
  the device lists), and both are destroyed cleanly; Core Audio's process list (AppVolume) reads.
- Verified in review (macOS 26.5, Apple Silicon):
  - With `compat/audio` merged onto `main` (which already consults `MeasureRegistry` and lets plugins set `rawString`)
    in a scratch checkout: `Measure=Plugin`/`Plugin=AudioLevel` and `Win7AudioPlugin` resolve to these classes
    (`Measure=MediaKey`, checked then too, now resolves to the MediaUI implementation); Win7Audio's device name and
    volume reach String meters on the first update (the Enigma volume skin and `TestSkins/Audio/Volume`); the Nelamint and Simple Clean visualizers and `TestSkins/Audio/Visualizer` animate with
    `DESKSET_AUDIO_DEMO=1`; releasing a skin releases its measures and the capture source goes away after the grace period.
  - Aggregate devices, created and destroyed without starting IO: with the built-in speakers as sub-device the aggregate
    has 2 inputs (the tap) and 2 outputs; with BlackHole 2ch (which has inputs) 4 inputs; with a Multi-Output Device the
    sub-device is dropped (tap only); a tap-only aggregate has 2 inputs, no outputs, 48 kHz.
  - Win7Audio commands against a fake HAL (volume, hardware and emulated mute, device switching, commands racing
    device re-reads), AppVolume mute bookkeeping with fake taps.
- Not verified on a real stream, because each needs a permission prompt answered by a person: reading the tap
  (System Audio Recording), ScreenCaptureKit (macOS 13 – 14.1) and the microphone; muting one app with a tap; the tap-only aggregate used for output devices with inputs. These paths follow Apple's documented API usage
  and fail safe (0 values, one log line) if something is refused. To check by hand (app bundle with the Info.plist
  keys below): load `TestSkins/Audio/Visualizer`, allow System Audio Recording, play music — with the built-in speakers,
  with Bluetooth headphones (the headphones must stay in their high-quality profile and no microphone indicator may
  appear) and with a USB audio interface or BlackHole as the output.

## Engine integration notes (for maintainers)

- `AudioPlugins.register()` registers the plugins listed in `AudioPlugins.pluginTypes`: `AudioLevel`,
  `Win7AudioPlugin`, `Win7Audio` and `AppVolume` (plugin names only). `MediaKey` is registered by `MediaUIPlugins`.
  `Skin.appProvidedMeasures` in DesksetCore must list the same names (checked by `Deskset --self-test appProvidedMeasures`).
- Plugin measures set their string values through `Measure.setPluginString(_:)` (in `AudioPlugins.swift`), which sets
  `Measure.rawString` (public since the merge): Win7Audio's device name, AudioLevel's DeviceName/DeviceID/DeviceList/Format
  and AppVolume's names reach String meters, `[Measure]` section variables and IfMatch.
- AppVolume's parent implements `SectionVariableFunctions` for its `Get…(x)` section variables.
- The app bundle needs `NSAudioCaptureUsageDescription` and `NSMicrophoneUsageDescription`; a hardened-runtime build needs
  the `com.apple.security.device.audio-input` entitlement for the microphone.
