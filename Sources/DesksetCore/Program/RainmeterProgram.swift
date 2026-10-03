import Foundation

/// The initially qualified Rainmeter compatibility profile. This is static source, not a captured scene or a
/// live kernel graph. Construction is internal to the checked converter; the existing WidgetProgram is unchanged.
package struct RainmeterProgram: Equatable, Sendable {
    package struct Source: Equatable, Sendable {
        package let file: URL
        package let line: Int
    }
    package struct Entry: Equatable, Sendable {
        package let key: String
        package let value: String
        package let source: Source?
    }
    package enum Kernel: String, Equatable, Sendable {
        case time, calc, string, image

        var measureClass: Measure.Type? {
            switch self {
            case .time: return TimeMeasure.self
            case .calc: return CalcMeasure.self
            case .string, .image: return nil
            }
        }
    }
    package struct Section: Equatable, Sendable {
        package let name: String
        package let entries: [Entry]
        package let source: Source?
        package let kernel: Kernel?

        var ini: IniSection {
            IniSection(name: name, entries: entries.map { IniEntry(key: $0.key, value: $0.value) })
        }
    }
    package struct Window: Equatable, Sendable {
        package let updateMilliseconds: Int
        package let backgroundMode: Int
        package let solidColor: RGBA
        package let accurateText: Bool
        package let skinWidth: Double?
        package let skinHeight: Double?

        var settings: SkinSettings {
            var value = SkinSettings()
            value.update = updateMilliseconds
            value.backgroundMode = backgroundMode
            value.solidColor = solidColor
            value.accurateText = accurateText
            value.skinWidth = skinWidth
            value.skinHeight = skinHeight
            return value
        }
    }

    package let config: String
    package let fileURL: URL
    package let skinsDirectory: URL
    package let resourcesDirectory: URL
    /// Exact bytes read once before preflight, also supplied to the temporary loader after decoding.
    package let sourceBytes: Data
    package let sections: [Section]
    package let staticBuiltins: [String: String]
    package let window: Window

    var sourceMap: IniSourceMap {
        var map = IniSourceMap()
        for section in sections {
            let name = section.name.lowercased()
            if let source = section.source {
                map.sections[name] = IniSourceLocation(file: source.file, line: source.line)
            }
            for entry in section.entries {
                if let source = entry.source {
                    map.options[name, default: [:]][entry.key.lowercased()] =
                        IniSourceLocation(file: source.file, line: source.line)
                }
            }
        }
        return map
    }
}

package enum RainmeterProgramError: Error, Equatable {
    case outsideInitialProfile(section: String, key: String, source: RainmeterProgram.Source?, reason: String)
    case inconsistentFrozenInput
    case unexpectedService(String)
    case closed
}

/// The caller supplies the same text cache used for drawing, at the owner's original updateCount.
package protocol RainmeterTextMeasuring: AnyObject {
    func measure(_ text: String, style: TextStyle, wrapWidth: Double?, cycle: Int) -> SkinSize?
}
