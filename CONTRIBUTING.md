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
- `Deskset --render Skin.ini --out skin.png` draws a skin without a window, which is handy for checking a change by eye.
- Skins update and draw on the main thread, so anything that keeps it busy makes animated skins skip frames. Build
  windows in steps (`MainThreadSteps`, as the skin editor does) rather than all at once. To find stalls,
  `defaults write app.deskset.Deskset MainThreadStallLog -int 50` logs every main-thread step of 50 ms or more to
  `~/Library/Logs/Deskset/Deskset.log`, with what was running (read at launch; `defaults delete` to turn it off).

## Pull requests

- Keep each pull request focused on one change and describe how you tested it.
- Include screenshots for visible changes.
- CI builds and tests every pull request on Apple silicon and Intel.

## License of contributions

Deskset is licensed under the GNU General Public License v3. By submitting a contribution you agree that it is
licensed under the same terms.
