import Foundation
import DesksetCore

/// Audio plugins and measures (docs/compat/audio.md):
/// - `Plugin=AudioLevel`: VU meters and spectrum analyzers from system output (Core Audio process tap, or
///   ScreenCaptureKit before macOS 14.2) or an input device.
/// - `Plugin=Win7AudioPlugin` (also `Win7Audio`): volume, mute and output device of the Mac.
/// - `Plugin=AppVolume` (third party): audio apps, per-app peak and mute.
enum AudioPlugins {
    /// `Plugin=` names → measure types (no `Measure=` types: none of these is a Rainmeter measure type). Listed in
    /// `Skin.appProvidedMeasures` too (checked by the app self-test).
    static let pluginTypes: [(name: String, type: Measure.Type)] = [
        ("AudioLevel", AudioLevelMeasure.self),
        ("Win7AudioPlugin", Win7AudioMeasure.self),
        ("Win7Audio", Win7AudioMeasure.self),
        ("AppVolume", AppVolumeMeasure.self),
    ]

    static func register() {
        for entry in pluginTypes { MeasureRegistry.registerPlugin(entry.name, entry.type) }
    }

    /// Whether the audio measures of `skin` may subscribe to the capture engine: only a skin in a skin window (the
    /// app's `SkinController`) captures. A skin that is only read (the Manage window's compatibility check of a skin
    /// that is not loaded), drawn by `--render` or previewed off-screen never starts a capture, so it never brings up
    /// a permission prompt or the recording indicator — unless every stream is the demo signal (`demo`), which
    /// records nothing and lets renders animate.
    static func mayCapture(for skin: Skin, demo: Bool = AudioCaptureEngine.demoSignal) -> Bool {
        demo || skin.host is SkinController
    }
}

extension Measure {
    /// Hands the string value of an app-side plugin measure to the engine (what String meters, `[Measure]` and
    /// IfMatch see): sets `Measure.rawString` (nil = a number-only measure; meters format its number).
    func setPluginString(_ text: String?) {
        rawString = text
    }
}
