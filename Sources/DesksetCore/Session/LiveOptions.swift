import Foundation

/// Which option changes a running skin can take without loading again (`Skin.patch(sources:)`): the Studio edits a
/// value, and its own instance of the widget — and the copy on the desktop — show it at once, keeping what they have
/// shown so far (graph history, the Calc counter, values set while they run).
///
/// A change is live when reading the section's options again gives what a reload of the new text would give after
/// its first update: the same frames, resolved options, text and measure values. The self-tests ("Session: live
/// patch") prove that for every key this table calls live, on every meter type, with sample values; anything not
/// proven here reloads:
/// - `[Rainmeter]` is read once, when the skin loads (the manual: it "does not support Dynamic Variables or changes
///   using the !SetOption bang"): every change reloads, and so does a change of a variable it uses.
/// - `[Metadata]` is only shown: live. `[Variables]` is live (the patch resolves the definitions again and reads the
///   sections that use a changed one), as long as each option using a changed variable is live where it is used.
/// - Meters: the general options and the drawing options of each type are live. `Meter`, `Container`,
///   `DynamicVariables` and `UpdateDivider` reload (the type makes another object; the other three change how and when
///   the skin reads and updates, which a reload starts afresh), and so does any key a type does not read.
/// - Measures: only a few types whose options hold no state are live, and only for the keys below; a measure that
///   averages its values (`AverageSize` above 1) always reloads. Everything else — Script, WebParser, plugins, Calc's
///   Formula (its range follows the values it has had), IfConditions (a reload runs their actions again) — reloads.
/// - A style section's keys are live when they are live in every meter that uses the style.
public enum LiveOptions {
    public enum Applies: Equatable {
        /// Applied to the running skin by reading its options again.
        case live
        /// The skin loads again from the new text.
        case reload
    }

    /// The kind of section an option is written in.
    public enum Section: Equatable {
        case rainmeter
        case metadata
        case variables
        /// A meter of this type (lowercased `Meter=`, `unsupported` for a type the engine does not draw).
        case meter(type: String)
        /// A measure of this type: a key of `measureKeys` for the types whose live keys are known, anything else for
        /// the others.
        case measure(type: String)
        /// A MeterStyle or a section nothing uses: decided by the meters that use it.
        case other
    }

    /// Whether a change of `key` in a section of `kind` is applied to the running skin.
    public static func applies(_ key: String, in kind: Section) -> Applies {
        let lower = key.trimmingCharacters(in: .whitespaces).lowercased()
        switch kind {
        case .rainmeter: return .reload
        case .metadata, .variables, .other: return .live
        case .meter(let type):
            if meterReload.contains(lower) { return .reload }
            if meterGeneral.contains(lower) || matches(lower, numbered: meterGeneralNumbered) { return .live }
            let type = type.lowercased()
            if meterKeys[type]?.contains(lower) == true || matches(lower, numbered: meterNumbered[type] ?? []) {
                return .live
            }
            return .reload
        case .measure(let type):
            guard let keys = measureKeys[type.lowercased()] else { return .reload }
            return keys.contains(lower) || measureGeneral.contains(lower) ? .live : .reload
        }
    }

    /// Whether the options of a measure of this type may be read again at any time: the types `measureKeys` lists (their
    /// options hold no state). The patch reads such a measure again when it must follow a section variable.
    public static func canReadAgain(measureType type: String) -> Bool {
        measureKeys[type.lowercased()] != nil
    }

    /// `key` is `stem` or `stemN` (N ≥ 2, or any N for `ColorMatrix`) for one of `stems`.
    static func matches(_ key: String, numbered stems: Set<String>) -> Bool {
        guard !stems.isEmpty else { return false }
        if stems.contains(key) { return true }
        let digits = key.reversed().prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count < key.count else { return false }
        return stems.contains(String(key.dropLast(digits.count)))
    }

    // MARK: Meters

    /// Keys that always reload a meter.
    static let meterReload: Set<String> = ["meter", "container", "dynamicvariables", "updatedivider"]

    /// Options every meter reads (Meter.readOptions, Glass.swift).
    static let meterGeneral: Set<String> = {
        var keys: Set<String> = [
            "x", "y", "w", "h", "hidden", "solidcolor", "solidcolor2", "gradientangle", "beveltype", "bevelcolor",
            "bevelcolor2", "padding", "antialias", "meterstyle", "group", "tooltiptext", "tooltiptitle", "tooltipicon",
            "tooltiptype", "tooltipwidth", "tooltiphidden", "mouseactioncursor", "mouseactioncursorname",
            "transformationmatrix", "onupdateaction", "macglass", "macglasscornerradius", "macglasstint",
        ]
        for kind in MouseEventKind.allCases { keys.insert(kind.rawValue.lowercased()) }
        return keys
    }()

    /// `MeasureName`, `MeasureName2`…: every meter binds them (the tooltip's `%1`, `%2`…).
    static let meterGeneralNumbered: Set<String> = ["measurename"]

    /// The general image options with an optional prefix (ImageOptions.read, MacSymbol.Style.read).
    static func imageKeys(prefix: String = "", crop: Bool = true, rotate: Bool = true) -> Set<String> {
        var keys = ["greyscale", "imagetint", "imagealpha", "imageflip", "useexiforientation", "imagepath",
                    "macsymbolsize", "macsymbolweight", "macsymbolrendering", "macsymbolcolors"]
        if crop { keys.append("imagecrop") }
        if rotate { keys.append("imagerotate") }
        return Set(keys.map { prefix + $0 })
    }

    /// The options each meter type reads besides the general ones (Engine/Meters).
    static let meterKeys: [String: Set<String>] = [
        "string": ["text", "prefix", "postfix", "numofdecimals", "autoscale", "scale", "percentual", "fontface",
                   "fontsize", "fontcolor", "fontweight", "stringstyle", "stringalign", "stringeffect",
                   "fonteffectcolor", "stringcase", "clipstring", "clipstringw", "clipstringh", "angle",
                   "trailingspaces"],
        "image": imageKeys().union(["imagename", "path", "preserveaspectratio", "scalemargins", "tile",
                                    "maskimagename", "maskimagepath", "maskimageflip", "maskimagerotate",
                                    "macdecodesize"]),
        "bar": imageKeys().union(["barcolor", "barimage", "barorientation", "flip", "barborder"]),
        "line": ["linecount", "linewidth", "horizontallines", "horizontallinecolor", "autoscale", "graphstart",
                 "graphorientation", "flip", "transformstroke"],
        "histogram": Set(["primarycolor", "secondarycolor", "bothcolor", "autoscale", "graphstart", "graphorientation",
                          "flip", "secondarymeasurename", "primaryimage", "secondaryimage", "bothimage"])
            .union(["primary", "secondary", "both"].flatMap { prefix in
                ["imagepath", "imagecrop", "imagetint", "imagealpha", "imageflip", "greyscale"].map { prefix + $0 }
            }),
        "roundline": ["linecolor", "linewidth", "startangle", "rotationangle", "solid", "linelength", "linestart",
                      "valueremainder", "valuereminder", "controlangle", "controlstart", "startshift",
                      "controllength", "lengthshift"],
        "rotator": imageKeys().union(["imagename", "startangle", "rotationangle", "offsetx", "offsety",
                                      "valueremainder", "valuereminder"]),
        "button": imageKeys(crop: false, rotate: false).union(["buttonimage", "buttoncommand"]),
        "bitmap": imageKeys(crop: false, rotate: false).union(["bitmapimage", "bitmapframes", "bitmapzeroframe",
                                                               "bitmapextend", "bitmapdigits", "bitmapalign",
                                                               "bitmapseparation", "bitmaptransitionframes"]),
        "shape": [],
    ]

    /// Numbered families of each meter type (`Shape`, `Shape2`…).
    static let meterNumbered: [String: Set<String>] = [
        "string": ["inlinesetting", "inlinepattern"],
        "image": ["colormatrix"],
        "bar": ["colormatrix"],
        "line": ["linecolor", "scale"],
        "rotator": ["colormatrix"],
        "button": ["colormatrix"],
        "bitmap": ["colormatrix"],
        "shape": ["shape"],
    ]

    // MARK: Measures

    /// Options every measure type of `measureKeys` takes live: they only change how the string is written, or the
    /// measure's groups. (MinValue and MaxValue are live only where the range does not follow the values seen.)
    static let measureGeneral: Set<String> = ["substitute", "regexpsubstitute", "group"]

    /// The measure types whose options hold no state, and their live keys.
    static let measureKeys: [String: Set<String>] = [
        "calc": [],
        "time": ["format", "formatlocale", "timezone", "daylightsavingtime", "timestamp", "timestampformat",
                 "timestamplocale", "minvalue", "maxvalue"],
        "uptime": ["format", "adddaystohours", "secondsvalue", "minvalue", "maxvalue"],
        "cpu": ["processor", "minvalue", "maxvalue"],
        "string": ["string", "minvalue", "maxvalue"],
    ]
}

extension EditorSchema.Property {
    /// Whether a change of this property of a meter of `type` shows without loading the skin again (see `LiveOptions`).
    public func applies(toMeterType type: String) -> LiveOptions.Applies {
        LiveOptions.applies(key, in: .meter(type: type))
    }
}
