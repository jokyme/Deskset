# Contributing to Deskset

Thanks for helping! Bug reports, skin compatibility reports, fixes and new features are all welcome. For anything
bigger than a small fix, please open an issue first so we can agree on the approach.

## The clean-room rule (required)

Deskset is a clean-room implementation of Rainmeter's skin format, written only from the public documentation.

- **Do not read, copy or translate Rainmeter's source code** (github.com/rainmeter/rainmeter or any fork) while
  working on Deskset, and do not paste code from it into issues or pull requests.
- Work from [the Rainmeter manual](https://docs.rainmeter.net/manual/), public forum answers about how skins behave,
  and what you can observe by running skins.
- If you have studied Rainmeter's source for the part you want to change, please pick a different area.
- When the manual is silent or ambiguous, make a reasoned judgment, write it down (see below) and add a test.

## No third-party skins or assets

- Do not commit skins, images, fonts or other files you did not create, even as test fixtures. A link to where a skin
  is published is enough for an issue.
- Test skins (`TestSkins/`) and example skins (`DefaultSkins/`) must be original work.

## Document every difference from Windows

Whenever Deskset behaves differently from Rainmeter on Windows (a Windows-only feature, a macOS limitation, a
judgment call), describe it in `docs/compat/<area>.md` and in both summaries, `docs/COMPATIBILITY.md` and
`docs/COMPATIBILITY.zh-CN.md`. The format is described in [docs/compat/README.md](docs/compat/README.md).

## Development

You need macOS 13 or later and Xcode 26 (Swift 6.2) or later.

```bash
swift build
swift run DesksetSelfTest            # engine self-tests (add a suite prefix to run a subset)
.build/debug/Deskset --self-test     # app self-tests (add a filter to run a subset)
bash scripts/build-app.sh            # build/Deskset.app
```

- The package uses the Swift 5 language mode (`swift-tools-version:5.9`).
- Keep logic in `DesksetCore` (Foundation only) where possible; the app target stays thin.
- The app must not use SwiftPM resources or `Bundle.module`: files the app needs are copied into the bundle by
  `scripts/build-app.sh`.
- Tests are plain executables (no XCTest). New behavior needs self-tests; run both suites before opening a pull
  request.
- `scripts/check-main-thread.sh [filter]` runs both suites with Apple's Main Thread Checker loaded (it comes with
  Xcode and works outside it) and lists every call into AppKit it saw off the main thread; the full output stays in
  the folder it prints. Run it when you change which thread runs what. (ThreadSanitizer does not work yet: on
  macOS 26.5 with Xcode 26.2 its runtime crashes at startup.)
- Skin work that runs later — timers, delays, the results of background work — goes through the skin's executor
  (`Skin.executor`, or `Skin.async` / `Skin.hop()`), never `DispatchQueue.main` or `RunLoop.main` directly: skins are
  moving off the main thread ([docs/skin-threading.md](docs/skin-threading.md)). Debug builds check that a skin is
  only touched where its executor runs.
- Anything that makes two runs of the same skin differ goes through the skin's seams, so that a run can be replayed
  with a fixed clock, seed and data (`--render --clock --seed --data`): the time, uptime and time zone through
  `Skin.skinClock`, the locale through `Skin.locale`, random numbers through `Skin.random`, timers and delays through
  the executor, background work and its result through `Skin.startBackground` / `Skin.backgroundHop`, and every
  effect outside the skin (starting a program, writing a file, opening a URL, sending a key or setting the volume)
  through `Skin.sideEffects` (files the skin reads back go through `Skin.readablePath`). Services a skin reads
  (NowPlaying, weather, audio levels…) sit behind a protocol with a fake, and a measure that reads one directly names
  it in `Measure.liveInputs`, so that a run in virtual time reports it when it is not faked. Iterate in a defined
  order where the order reaches the skin (the skin's meters, sorted keys), never a set's or dictionary's own: Swift
  seeds it at random in every process. `DesksetCore`'s formatting takes the clock, time zone and locale as arguments
  (the engine passes the skin's; the app's UI uses `MacTimeFormatting`). `swift scripts/check-seams.swift --check`
  (run by CI, a few seconds) fails on a new direct `Date()`, `.random`, timer, queue, thread, `async` hand-over,
  iteration in hash order or outside effect in the engine, plugins and services; route it through a seam, or add it
  to `scripts/seams-allowlist.tsv` with a note saying why. The list only shrinks: the check also fails when an
  allowance is higher than the sources need, so lower it (`--update` does) when you remove a direct call.
- `Deskset --render Skin.ini --out skin.png` draws a skin without a window, which is handy for checking a change by eye.
- Skins update and draw on the main thread, so anything that keeps it busy makes animated skins skip frames. Build
  windows in steps (`MainThreadSteps`, as the skin editor does) rather than all at once. To find stalls,
  `defaults write app.deskset.Deskset MainThreadStallLog -int 50` logs every main-thread step of 50 ms or more to
  `~/Library/Logs/Deskset/Deskset.log`, with what was running (read at launch; `defaults delete` to turn it off).

## Weather requests

The weather plugins identify Deskset to MET Norway in their User-Agent (`METNorway.userAgentProduct` and
`METNorway.userAgentContact` in `Sources/DesksetCore/Weather/METNorway.swift`), as MET Norway's terms require. If you
distribute a modified build of your own, change both to your app's name and a contact address of yours. Tests must
never reach the real service: use the fixtures, a fake transport or the loopback test server.

## Pull requests

- Keep each pull request focused on one change and describe how you tested it.
- Include screenshots for visible changes.
- CI builds and tests every pull request on Apple silicon and Intel.

## License of contributions

Deskset is licensed under the GNU General Public License v3. By submitting a contribution you agree that it is
licensed under the same terms.
