#if DEBUG
// A frozen copy of Fonts.swift (resolution only): see LegacySkinRenderer.swift. Debug builds only.

import AppKit
import CoreText
import DesksetCore

/// Fonts: Rainmeter sizes are points at 96 DPI; Windows font names are mapped to Mac equivalents.
///
/// `FontFace` is a family name (manual: String meter, Fonts guide). Resolution order for a face:
/// 1. an installed or registered family with that name (case-insensitive);
/// 2. the Mac system font designs (Deskset extension): `System` (the system font), `SF Pro Rounded` / `System Rounded`,
///    `SF Mono` / `System Mono`, `New York` / `System Serif` (`systemDesigns`);
/// 3. the Windows → Mac substitution table (Segoe UI → system font, Consolas → Menlo, CJK fonts…);
/// 4. a full or PostScript font name ("Fira Sans Bold", "Arial-BoldMT"): its family, with its weight / italic as
///    the implied style ("Rainmeter will figure out the actual family name when the font is loaded");
/// 5. the same again after removing trailing style words ("Roboto Light Italic" → "Roboto", 300, italic);
/// 6. Arial ("Arial is now the default font when FontFace is not specified or errors occur").
///
/// Weight: `FontWeight` (1–999) or StringStyle Bold (700) picks the family member with the closest weight
/// (OS/2 usWeightClass); "If the font does not support any additional weights, then 500 and below will use the
/// font's normal weight, and 600 and above will simulate a bold effect" — simulated with a fill + stroke.
/// Italic / Oblique use an italic member when the family has one, otherwise a slanted (simulated) font.
///
/// Frozen copy: only resolution (a FontFace, size, weight and style to a font) is copied. Registering skin fonts
/// stays with `Fonts` (it is the process's state, not drawing): this copy asks it to read a skin's font folder, and
/// forgets what it resolved whenever `Fonts.generation` moves on.
///
/// Thread-safe: resolution (`resolve`, the family lookups) is guarded by one lock, `lock`.
enum LegacyFonts {
    /// Rainmeter FontSize → macOS point size.
    static let sizeScale = 96.0 / 72.0

    /// A font request. `size` is in skin points (pixels), i.e. already multiplied by `sizeScale`.
    struct Request: Hashable {
        var face: String
        var size: CGFloat
        /// Explicit `FontWeight` / inline `Weight`.
        var weight: Int?
        /// `StringStyle=Bold` (700 unless an explicit weight is given).
        var bold = false
        var italic = false
        var oblique = false
        /// Inline `Stretch` 1…9 (5 = normal).
        var stretch: Int?
        /// Inline `Typography` features (OpenType tag, value).
        var features: [Feature] = []
    }

    struct Feature: Hashable {
        var tag: String
        var value: Int
    }

    struct Resolved {
        let font: CTFont
        /// Draw with an additional stroke to simulate bold (the family has no heavy enough member).
        let syntheticBold: Bool
        /// Characters to replace before shaping (Marlett, which has no Mac equivalent).
        let characterMap: [UInt16: UInt16]?
        /// Horizontal shear for simulated italic / oblique (0 = upright). Applied by the renderer through the text
        /// matrix, because CTRunDraw ignores a font's own matrix.
        let slant: CGFloat
        /// Line metrics (pixels) of the Windows font this one stands in for, so that line heights — and every
        /// layout stacked with `Y=0R` — match the original skin. Nil when the font is used as is.
        let lineMetrics: LineMetrics?
    }

    struct LineMetrics: Hashable {
        var ascent: CGFloat
        var descent: CGFloat
        var leading: CGFloat
    }

    /// Shear of simulated italic / oblique text (about 11°).
    static let simulatedSlant: CGFloat = 0.2

    /// Guards what resolution keeps (`cache`, `faceCache`, `memberCache`, `familyIndex`, `resolvedGeneration`).
    private static let lock = NSLock()
    private static var cache: [Request: Resolved] = [:]
    private static var faceCache: [String: FaceMatch] = [:]
    private static var memberCache: [String: [Member]] = [:]
    private static var familyIndex: [String: String]?
    /// The `Fonts.generation` what is kept was resolved at.
    private static var resolvedGeneration = Int.min

    /// Call with `lock` held: forgets what was resolved before the set of fonts last changed.
    private static func checkGeneration() {
        let current = Fonts.generation
        guard current != resolvedGeneration else { return }
        forgetResolutions()
        resolvedGeneration = current
    }

    /// Call with `lock` held.
    private static func forgetResolutions() {
        cache.removeAll()
        faceCache.removeAll()
        memberCache.removeAll()
        familyIndex = nil
    }

    // MARK: Resolution

    static func request(for style: TextStyle) -> Request {
        Request(face: style.fontFace, size: CGFloat(max(TextStyle.pixelSize(points: style.fontSize), 0.01)),
                weight: style.fontWeight, bold: style.bold, italic: style.italic)
    }

    /// The font for `request`, cached until the fonts change. Any thread.
    static func resolve(_ request: Request) -> Resolved {
        lock.lock()
        defer { lock.unlock() }
        checkGeneration()
        if let hit = cache[request] { return hit }
        if cache.count > 512 { cache.removeAll() }
        let match = faceMatch(request.face)
        let weight = request.weight ?? (request.bold ? 700 : match.weight ?? 400)
        let italic = request.italic || match.italic
        let size = min(max(request.size, 0.01), 4000)

        var font: CTFont
        var syntheticBold = false
        var slant = false
        if let family = match.family, let chosen = bestMember(family, weight: weight, italic: italic || request.oblique,
                                                             oblique: request.oblique, stretch: request.stretch) {
            font = CTFontCreateWithFontDescriptor(chosen.member.descriptor, size, nil)
            syntheticBold = weight >= 600 && chosen.member.weight < 600
            slant = chosen.needsSlant
        } else {
            font = systemFont(size: size, weight: weight, italic: italic && !request.oblique, stretch: request.stretch,
                              design: match.design)
            slant = request.oblique || (italic && !CTFontGetSymbolicTraits(font).contains(.traitItalic))
        }
        if !request.features.isEmpty {
            let settings = request.features.map {
                [kCTFontOpenTypeFeatureTag: $0.tag, kCTFontOpenTypeFeatureValue: $0.value] as [CFString: Any]
            }
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: settings] as CFDictionary)
            font = CTFontCreateCopyWithAttributes(font, size, nil, descriptor)
        }
        let metrics = match.emMetrics.map {
            LineMetrics(ascent: $0.ascent * size, descent: $0.descent * size, leading: $0.leading * size)
        }
        let resolved = Resolved(font: font, syntheticBold: syntheticBold, characterMap: match.characterMap,
                                slant: slant ? simulatedSlant : 0, lineMetrics: metrics)
        cache[request] = resolved
        return resolved
    }

    // MARK: Face names

    private struct FaceMatch {
        /// Actual family name; nil = the system font.
        var family: String?
        var weight: Int?
        var italic = false
        var characterMap: [UInt16: UInt16]?
        /// Vertical metrics in em of the substituted Windows font.
        var emMetrics: LineMetrics?
        /// With `family` nil: which design of the system font.
        var design = SystemDesign.standard
    }

    /// The designs of the Mac system font (`NSFontDescriptor.SystemDesign`).
    enum SystemDesign: CaseIterable {
        case standard, rounded, monospaced, serif

        var descriptorDesign: NSFontDescriptor.SystemDesign {
            switch self {
            case .standard: return .default
            case .rounded: return .rounded
            case .monospaced: return .monospaced
            case .serif: return .serif
            }
        }

        /// The FontFace name the editor writes for it.
        var faceName: String {
            switch self {
            case .standard: return "System"
            case .rounded: return "System Rounded"
            case .monospaced: return "System Mono"
            case .serif: return "System Serif"
            }
        }
    }

    /// FontFace names of the system font's designs (Deskset extension; lower case). Apple's own family names (SF Pro
    /// Rounded, SF Mono, New York) name them too: those families are not installed on a Mac by default, and when a
    /// user installed them, the installed family wins (resolution looks for installed families first). `System` is
    /// the system font: on Windows it names an old bitmap font, which skins hardly use.
    static let systemDesigns: [String: SystemDesign] = [
        "system": .standard,
        "system rounded": .rounded, "sf pro rounded": .rounded, "sf rounded": .rounded, "ui-rounded": .rounded,
        "system mono": .monospaced, "system monospaced": .monospaced, "sf mono": .monospaced,
        "ui-monospace": .monospaced,
        "system serif": .serif, "new york": .serif, "ui-serif": .serif,
    ]

    /// Call with `lock` held (so for everything below that keeps or reads what resolution keeps).
    private static func faceMatch(_ face: String) -> FaceMatch {
        let key = face.lowercased()
        if let hit = faceCache[key] { return hit }
        let result = computeFaceMatch(face)
        if faceCache.count > 512 { faceCache.removeAll() }
        faceCache[key] = result
        return result
    }

    private static func computeFaceMatch(_ face: String) -> FaceMatch {
        var words = face.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var impliedWeight: Int?
        var impliedItalic = false
        for _ in 0..<4 {
            guard !words.isEmpty else { break }
            let name = words.joined(separator: " ")
            let lower = name.lowercased()
            if let family = installedFamily(lower) {
                return FaceMatch(family: family, weight: impliedWeight, italic: impliedItalic)
            }
            if let design = systemDesigns[lower] {
                return FaceMatch(family: nil, weight: impliedWeight, italic: impliedItalic, design: design)
            }
            if let sub = substitutes[lower] {
                var match = FaceMatch(family: nil, weight: impliedWeight ?? sub.weight, italic: impliedItalic,
                                      characterMap: sub.characterMap, emMetrics: sub.emMetrics)
                if let target = sub.family { match.family = installedFamily(target.lowercased()) }
                return match
            }
            if let font = NSFont(name: name, size: 12), let family = font.familyName {
                let ct = font as CTFont
                let italic = CTFontGetSymbolicTraits(ct).contains(.traitItalic)
                let weight = impliedWeight ?? os2(ct)?.weight
                return FaceMatch(family: family.hasPrefix(".") ? nil : family, weight: weight,
                                 italic: impliedItalic || italic)
            }
            // Strip trailing style words ("Semibold", "Extra Light", "Italic"…) and try again.
            guard let (count, weight, italic) = styleSuffix(words) else { break }
            words.removeLast(count)
            if let weight, impliedWeight == nil { impliedWeight = weight }
            if italic { impliedItalic = true }
        }
        return FaceMatch(family: installedFamily("arial"), weight: impliedWeight, italic: impliedItalic)
    }

    /// Call with `lock` held.
    private static func installedFamily(_ lowercased: String) -> String? {
        if familyIndex == nil {
            var index: [String: String] = [:]
            let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
            for name in names where !name.hasPrefix(".") { index[name.lowercased()] = name }
            familyIndex = index
        }
        return familyIndex?[lowercased]
    }

    private static let styleWords: [String: (weight: Int?, italic: Bool)] = [
        "thin": (100, false), "hairline": (100, false), "extralight": (200, false), "ultralight": (200, false),
        "light": (300, false), "semilight": (350, false), "demilight": (350, false), "regular": (400, false),
        "normal": (400, false), "book": (400, false), "medium": (500, false), "semibold": (600, false),
        "demibold": (600, false), "bold": (700, false), "extrabold": (800, false), "ultrabold": (800, false),
        "heavy": (900, false), "black": (900, false), "extrablack": (950, false), "ultrablack": (950, false),
        "italic": (nil, true), "oblique": (nil, true),
    ]

    /// Trailing style words: (number of words, weight, italic).
    private static func styleSuffix(_ words: [String]) -> (Int, Int?, Bool)? {
        guard words.count >= 2 else { return nil }
        if words.count >= 3 {
            let two = (words[words.count - 2] + words[words.count - 1]).lowercased()
            if let style = styleWords[two] { return (2, style.weight, style.italic) }
        }
        if let style = styleWords[words[words.count - 1].lowercased()] { return (1, style.weight, style.italic) }
        return nil
    }

    private struct Substitute {
        /// Mac family; nil = the system font.
        var family: String?
        var weight: Int?
        var characterMap: [UInt16: UInt16]?
        var emMetrics: LineMetrics?
    }

    /// Segoe UI's published vertical metrics (2048 units per em: ascent 2210, descent 514, line gap 0).
    private static let segoeMetrics = LineMetrics(ascent: 2210.0 / 2048, descent: 514.0 / 2048, leading: 0)

    /// Windows fonts that macOS does not ship (fonts that macOS does ship, such as Arial, Tahoma, Verdana,
    /// Trebuchet MS, Courier New, Georgia, Impact, Webdings and Wingdings, are used directly).
    private static let substitutes: [String: Substitute] = {
        var t: [String: Substitute] = [:]
        func add(_ names: [String], _ family: String?, weight: Int? = nil, metrics: LineMetrics? = nil) {
            for n in names { t[n] = Substitute(family: family, weight: weight, emMetrics: metrics) }
        }
        // Segoe UI family (GDI names include the weight) → San Francisco, keeping Segoe UI's line height.
        add(["segoe ui", "segoe ui variable", "segoe ui variable display", "segoe ui variable text",
             "segoe ui variable small", "segoe", "selawik"], nil, metrics: segoeMetrics)
        add(["segoe ui historic", "segoe ui symbol", "segoe mdl2 assets", "segoe fluent icons"], nil)
        // Names Mac skin authors use for the system font.
        // (SF Pro Rounded, SF Mono and New York are designs of the system font: `systemDesigns`.)
        add(["system font", "system-ui", "-apple-system", "san francisco", "sf pro", "sf pro text",
             "sf pro display", ".sf ns"], nil)
        add(["segoe ui light", "segoe ui variable light"], nil, weight: 300, metrics: segoeMetrics)
        add(["segoe ui semilight", "segoe ui variable semilight"], nil, weight: 350, metrics: segoeMetrics)
        add(["segoe ui semibold", "segoe ui variable semibold"], nil, weight: 600, metrics: segoeMetrics)
        add(["segoe ui bold"], nil, weight: 700, metrics: segoeMetrics)
        add(["segoe ui black"], nil, weight: 900, metrics: segoeMetrics)
        add(["segoe ui emoji"], "Apple Color Emoji")
        add(["segoe print", "mv boli"], "Chalkboard SE")
        add(["segoe script", "ink free"], "Bradley Hand")
        add(["gabriola"], "Snell Roundhand")
        // ClearType collection and other Office / Windows fonts.
        add(["calibri", "candara", "corbel", "microsoft sans serif", "ms sans serif", "ms shell dlg",
             "ms shell dlg 2", "arial nova", "leelawadee ui", "nirmala ui", "ebrima", "gadugi", "sylfaen",
             "javanese text", "myanmar text", "mongolian baiti", "microsoft yi baiti", "microsoft tai le",
             "microsoft new tai lue", "microsoft phagspa", "microsoft himalaya"], nil)
        t["microsoft sans serif"] = Substitute(family: "Microsoft Sans Serif")
        t["ms sans serif"] = Substitute(family: "Microsoft Sans Serif")
        t["arial nova"] = Substitute(family: "Arial")
        add(["calibri light"], nil, weight: 300)
        add(["cambria", "cambria math", "constantia", "sitka", "sitka text", "sitka display", "sitka small",
             "sitka heading", "sitka subheading", "sitka banner", "georgia pro"], "Georgia")
        add(["consolas", "lucida console", "lucida sans typewriter", "cascadia code", "cascadia mono",
             "fixedsys", "terminal", "courier"], "Menlo")
        add(["lucida sans unicode", "lucida sans"], "Lucida Grande")
        add(["tahoma"], "Verdana")
        add(["verdana pro"], "Verdana")
        add(["trebuchet"], "Trebuchet MS")
        add(["ms serif", "times"], "Times New Roman")
        add(["century gothic"], "Futura")
        add(["franklin gothic medium", "franklin gothic"], "Avenir Next", weight: 500)
        add(["franklin gothic book"], "Avenir Next")
        add(["bahnschrift"], "DIN Alternate")
        add(["palatino linotype", "book antiqua"], "Palatino")
        add(["garamond"], "Baskerville")
        add(["gill sans nova"], "Gill Sans")
        add(["arial unicode ms"], "Arial")
        // CJK Windows fonts (Latin and native names).
        add(["microsoft yahei", "microsoft yahei ui", "微软雅黑", "dengxian", "等线"], "PingFang SC")
        add(["microsoft jhenghei", "microsoft jhenghei ui", "微軟正黑體"], "PingFang TC")
        add(["simsun", "nsimsun", "simsun-extb", "宋体", "新宋体"], "Songti SC")
        add(["simhei", "黑体"], "Heiti SC")
        add(["kaiti", "kaiti_gb2312", "楷体"], "Kaiti SC")
        add(["fangsong", "fangsong_gb2312", "仿宋"], "STFangsong")
        add(["mingliu", "pmingliu", "mingliu_hkscs", "細明體", "新細明體"], "Songti TC")
        add(["dfkai-sb", "標楷體"], "Kaiti TC")
        add(["meiryo", "meiryo ui", "yu gothic", "yu gothic ui", "ms gothic", "ms pgothic", "ms ui gothic",
             "メイリオ", "游ゴシック", "ｍｓ ゴシック", "ｍｓ ｐゴシック"], "Hiragino Sans")
        add(["ms mincho", "ms pmincho", "yu mincho", "游明朝", "ｍｓ 明朝"], "Hiragino Mincho ProN")
        add(["malgun gothic", "맑은 고딕", "gulim", "굴림", "dotum", "돋움", "gulimche", "dotumche"],
            "Apple SD Gothic Neo")
        add(["batang", "바탕", "batangche", "gungsuh", "궁서"], "AppleMyungjo")
        // Marlett (window-control glyphs) has no Mac equivalent: map its common letters to Unicode symbols.
        let marlett: [Character: Character] = [
            "0": "\u{2581}", "1": "\u{25A1}", "2": "\u{2750}", "r": "\u{2715}",
            "3": "\u{25C0}", "4": "\u{25B6}", "5": "\u{25B2}", "6": "\u{25BC}", "a": "\u{2713}",
        ]
        var map: [UInt16: UInt16] = [:]
        for (k, v) in marlett {
            if let a = k.utf16.first, let b = v.utf16.first { map[a] = b }
        }
        t["marlett"] = Substitute(family: nil, characterMap: map)
        return t
    }()

    // MARK: Family members

    private struct Member {
        var descriptor: CTFontDescriptor
        var weight: Int
        var width: Int
        var italic: Bool
        var oblique: Bool
    }

    /// Call with `lock` held.
    private static func members(_ family: String) -> [Member] {
        if let hit = memberCache[family] { return hit }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var result: [Member] = []
        for d in descriptors.prefix(200) {
            let font = CTFontCreateWithFontDescriptor(d, 12, nil)
            let traits = CTFontGetSymbolicTraits(font)
            let style = (CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String ?? "").lowercased()
            // Named instances of a variable font share one OS/2 table; their traits carry the real weight.
            let variable = CTFontCopyVariationAxes(font) != nil
            let metrics = variable ? nil : os2(font)
            result.append(Member(descriptor: d, weight: metrics?.weight ?? cssWeight(traitsOf: font),
                                 width: metrics?.width ?? 5, italic: traits.contains(.traitItalic),
                                 oblique: style.contains("oblique")))
        }
        memberCache[family] = result
        return result
    }

    /// Picks the member closest to the request; `needsSlant` when italic was asked for but no italic member exists.
    private static func bestMember(_ family: String, weight: Int, italic: Bool, oblique: Bool,
                                   stretch: Int?) -> (member: Member, needsSlant: Bool)? {
        var candidates = members(family)
        guard !candidates.isEmpty else { return nil }
        let wantedWidth = stretch ?? 5
        if let best = candidates.map({ abs($0.width - wantedWidth) }).min() {
            candidates = candidates.filter { abs($0.width - wantedWidth) == best }
        }
        var needsSlant = false
        if oblique {
            let obliques = candidates.filter(\.oblique)
            if !obliques.isEmpty {
                candidates = obliques
            } else {
                candidates = candidates.filter { !$0.italic }.isEmpty ? candidates : candidates.filter { !$0.italic }
                needsSlant = true
            }
        } else if italic {
            let italics = candidates.filter(\.italic)
            if italics.isEmpty { needsSlant = true } else { candidates = italics }
        } else {
            let uprights = candidates.filter { !$0.italic }
            if !uprights.isEmpty { candidates = uprights }
        }
        let heavierFirst = weight >= 500
        let chosen = candidates.min { a, b in
            let da = abs(a.weight - weight), db = abs(b.weight - weight)
            if da != db { return da < db }
            return heavierFirst ? a.weight > b.weight : a.weight < b.weight
        }
        return chosen.map { ($0, needsSlant) }
    }

    /// Call with `lock` held (see `lock` for why these stay AppKit calls). `stretch` applies to the standard design
    /// only (the rounded, monospaced and serif designs have one width). Italic keeps the weight and the width: the
    /// design's italic of the same weight, or — where there is none (the rounded design, a condensed, compressed or
    /// expanded width) — the upright font, which the caller slants.
    private static func systemFont(size: CGFloat, weight: Int, italic: Bool, stretch: Int?,
                                   design: SystemDesign = .standard) -> CTFont {
        let w = NSFont.Weight(rawValue: nsWeight(css: weight))
        var font: NSFont
        if design != .standard {
            font = NSFont.systemFont(ofSize: size, weight: w)
            if let descriptor = font.fontDescriptor.withDesign(design.descriptorDesign) {
                font = NSFont(descriptor: descriptor, size: size) ?? font
            }
        } else if let stretch, stretch != 5 {
            let width: NSFont.Width
            switch stretch {
            case ...2: width = .compressed
            case 3...4: width = .condensed
            default: width = .expanded
            }
            font = NSFont.systemFont(ofSize: size, weight: w, width: width)
        } else {
            font = NSFont.systemFont(ofSize: size, weight: w)
        }
        return italic ? italicFont(of: font as CTFont, size: size) : font as CTFont
    }

    /// The true italic of a system font at its weight and width, else the font itself (upright; the caller slants it).
    /// CoreText finds the italic of every weight (NSFontDescriptor's symbolic traits lose Medium in the monospaced and
    /// serif designs, and give an upright regular for a condensed width). For a width without italics it returns the
    /// upright face marked italic — the same face, drawn upright — so a result is taken only when it is another face,
    /// italic, at the same weight.
    private static func italicFont(of upright: CTFont, size: CGFloat) -> CTFont {
        guard let copy = CTFontCreateCopyWithSymbolicTraits(upright, size, nil, .traitItalic, .traitItalic),
              CTFontGetSymbolicTraits(copy).contains(.traitItalic),
              (CTFontCopyPostScriptName(copy) as String) != (CTFontCopyPostScriptName(upright) as String),
              abs(weightTrait(of: copy) - weightTrait(of: upright)) < 0.05 else { return upright }
        return copy
    }

    private static func weightTrait(of font: CTFont) -> Double {
        ((CTFontCopyTraits(font) as? [CFString: Any])?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
    }

    /// CSS-style weight (100…950) → NSFont.Weight / kCTFontWeightTrait, piecewise linear.
    private static let weightTable: [(css: Double, trait: Double)] = [
        (100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56),
        (900, 0.62), (1000, 0.7),
    ]

    static func nsWeight(css: Int) -> CGFloat {
        let v = Double(min(max(css, 1), 999))
        guard let first = weightTable.first, v > first.css else { return CGFloat(weightTable[0].trait) }
        for (a, b) in zip(weightTable, weightTable.dropFirst()) where v <= b.css {
            return CGFloat(a.trait + (b.trait - a.trait) * (v - a.css) / (b.css - a.css))
        }
        return CGFloat(weightTable[weightTable.count - 1].trait)
    }

    private static func cssWeight(traitsOf font: CTFont) -> Int {
        let traits = CTFontCopyTraits(font) as? [CFString: Any]
        let trait = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        for (a, b) in zip(weightTable, weightTable.dropFirst()) where trait <= b.trait {
            let t = (trait - a.trait) / max(b.trait - a.trait, 0.0001)
            return Int((a.css + (b.css - a.css) * min(max(t, 0), 1)).rounded())
        }
        return 900
    }

    /// OS/2 usWeightClass (1…1000) and usWidthClass (1…9).
    private static func os2(_ font: CTFont) -> (weight: Int, width: Int)? {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 8
        else { return nil }
        let bytes = [UInt8](table.prefix(8))
        let weight = Int(bytes[4]) << 8 | Int(bytes[5])
        let width = Int(bytes[6]) << 8 | Int(bytes[7])
        guard (1...1000).contains(weight) else { return nil }
        return (weight, (1...9).contains(width) ? width : 5)
    }
}
#endif
