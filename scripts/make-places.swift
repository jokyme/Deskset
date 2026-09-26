// Builds Data/Places/places.tsv, the offline place table of the weather plugins, from GeoNames
// (https://download.geonames.org/export/dump/, CC BY 4.0): cities15000.txt, countryInfo.txt and admin1CodesASCII.txt.
//
//     curl -O https://download.geonames.org/export/dump/cities15000.zip && unzip cities15000.zip
//     curl -O https://download.geonames.org/export/dump/countryInfo.txt
//     curl -O https://download.geonames.org/export/dump/admin1CodesASCII.txt
//     swift scripts/make-places.swift <folder with the three files> [YYYY-MM-DD download date]
//
// Output (UTF-8, one place per line, largest population first):
//     name⇥asciiname⇥alternates(,)⇥lat⇥lon⇥country⇥admin1⇥population⇥timezone
// followed by `#country⇥CC⇥English name`, `#admin1⇥CC.code⇥name` and `#meta⇥key⇥value` rows.
// Alternate names are trimmed (URLs, names with digits, names over 40 characters, 3–4 letter capital codes such as
// airport codes, names that fold to the place's own name, and the few names in `excludedAlternates` are dropped). Every place keeps its alternates in the
// scripts of its country's languages and its Chinese names; the other alternates (other scripts, Latin spellings in
// other languages) are kept for the largest places, as many as fit in 4 MB.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift scripts/make-places.swift <geonames folder> [download date]\n".data(using: .utf8)!)
    exit(2)
}
let folder = URL(fileURLWithPath: args[1])
let downloaded = args.count >= 3 ? args[2] : ISO8601DateFormatter().string(from: Date()).prefix(10).description
let budget = 4 * 1024 * 1024
let scriptURL = URL(fileURLWithPath: #filePath)
let output = scriptURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Data/Places/places.tsv")

func lines(_ name: String) -> [Substring] {
    guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else {
        FileHandle.standardError.write("cannot read \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    return text.split(whereSeparator: { $0.isNewline })
}

func fold(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// The script of a name: its first letter's Unicode block, by range.
func script(_ s: String) -> String {
    for u in s.unicodeScalars where u.properties.isAlphabetic {
        let v = u.value
        switch v {
        case 0..<0x250, 0x1E00...0x1EFF: return "Latin"
        case 0x370...0x3FF, 0x1F00...0x1FFF: return "Greek"
        case 0x400...0x52F: return "Cyrillic"
        case 0x530...0x58F: return "Armenian"
        case 0x590...0x5FF: return "Hebrew"
        case 0x600...0x6FF, 0x750...0x77F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return "Arabic"
        case 0x780...0x7BF: return "Thaana"
        case 0x900...0x97F: return "Devanagari"
        case 0x980...0x9FF: return "Bengali"
        case 0xA00...0xA7F: return "Gurmukhi"
        case 0xA80...0xAFF: return "Gujarati"
        case 0xB00...0xB7F: return "Oriya"
        case 0xB80...0xBFF: return "Tamil"
        case 0xC00...0xC7F: return "Telugu"
        case 0xC80...0xCFF: return "Kannada"
        case 0xD00...0xD7F: return "Malayalam"
        case 0xD80...0xDFF: return "Sinhala"
        case 0xE00...0xE7F: return "Thai"
        case 0xE80...0xEFF: return "Lao"
        case 0x1000...0x109F: return "Myanmar"
        case 0x10A0...0x10FF: return "Georgian"
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return "Hangul"
        case 0x1200...0x139F: return "Ethiopic"
        case 0x1780...0x17FF: return "Khmer"
        case 0x3040...0x30FF: return "Kana"
        case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF: return "CJK"
        default: return "Other"
        }
    }
    return "Other"
}

/// Scripts of each country's own languages: alternates in them are kept for every place of the country.
let localScripts: [String: Set<String>] = {
    var map: [String: Set<String>] = [:]
    func add(_ scripts: Set<String>, _ countries: String) {
        for c in countries.split(separator: " ") { map[String(c), default: []].formUnion(scripts) }
    }
    add(["Cyrillic"], "RU UA BY BG KZ KG RS MK MN TJ ME BA")
    add(["Arabic"], "SA AE EG IQ SY JO LB KW QA BH OM YE LY TN DZ MA SD PS IR AF PK EH MR")
    add(["Devanagari", "Bengali", "Gurmukhi", "Gujarati", "Oriya", "Tamil", "Telugu", "Kannada", "Malayalam"], "IN")
    add(["Devanagari"], "NP")
    add(["Bengali"], "BD")
    add(["Sinhala", "Tamil"], "LK")
    add(["Thai"], "TH")
    add(["Lao"], "LA")
    add(["Khmer"], "KH")
    add(["Myanmar"], "MM")
    add(["Georgian"], "GE")
    add(["Armenian"], "AM")
    add(["Greek"], "GR CY")
    add(["Hebrew"], "IL")
    add(["Hangul"], "KR KP")
    add(["Kana", "CJK"], "JP")
    add(["CJK"], "CN TW HK MO SG")
    add(["Ethiopic"], "ET ER")
    add(["Thaana"], "MV")
    return map
}()

/// Alternate names left out on purpose, by the SHA-256 of their folded form (so this list does not repeat them): one
/// former colonial-era name that the repository's automated text checks would refuse.
let excludedAlternates: Set<String> = ["23c13d4536ba2e0861ccc8c9e6f42bf1b01305f27e3d851ca8c29207e9bde239"]

func sha256(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

func keepAlternate(_ a: String, name: String, ascii: String) -> Bool {
    let t = a.trimmingCharacters(in: .whitespaces)
    if t.isEmpty || t.count > 40 { return false }
    if excludedAlternates.contains(sha256(fold(t))) { return false }
    if t.contains("://") || t.lowercased().hasPrefix("http") || t.contains("wikipedia") { return false }
    // Decimal digits only: Character.isNumber is also true for Chinese numerals such as 京 and 陆.
    if t.unicodeScalars.contains(where: { $0.properties.numericType == .decimal }) { return false }
    if (3...4).contains(t.count), t.allSatisfy({ $0.isASCII && $0.isUppercase }) { return false }
    let f = fold(t)
    return f != fold(name) && f != fold(ascii)
}

struct Place {
    var name: String, ascii: String, alternates: [String], lat: String, lon: String, country: String, admin1: String
    var population: Int, zone: String
    /// Alternates kept only while the table fits the budget.
    var extra: [String] = []
}

var places: [Place] = []
for line in lines("cities15000.txt") {
    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard f.count >= 18, let lat = Double(f[4]), let lon = Double(f[5]) else { continue }
    var seen = Set<String>()
    var alternates: [String] = []
    for a in f[3].split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) })
        where keepAlternate(a, name: f[1], ascii: f[2]) {
        if seen.insert(fold(a)).inserted { alternates.append(a) }
    }
    // Essential: the country's own scripts, and Chinese names everywhere; the rest is extra.
    let local = localScripts[f[8]] ?? []
    let essential = alternates.filter { let s = script($0); return local.contains(s) || s == "CJK" }
    let extra = alternates.filter { let s = script($0); return !(local.contains(s) || s == "CJK") }
    places.append(Place(name: f[1], ascii: f[2], alternates: essential, lat: String(format: "%.2f", lat),
                        lon: String(format: "%.2f", lon), country: f[8], admin1: f[10], population: Int(f[14]) ?? 0,
                        zone: f[17], extra: extra))
}
places.sort { $0.population != $1.population ? $0.population > $1.population : $0.name < $1.name }

var countries: [(String, String)] = []
for line in lines("countryInfo.txt") where !line.hasPrefix("#") {
    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    if f.count > 4 { countries.append((f[0], f[4])) }
}
let usedAdmin1 = Set(places.map { "\($0.country).\($0.admin1)" })
var regions: [(String, String)] = []
for line in lines("admin1CodesASCII.txt") {
    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    if f.count >= 2, usedAdmin1.contains(f[0]) { regions.append((f[0], f[1])) }
}

func render(_ places: [Place]) -> String {
    var out = ""
    for p in places {
        out += [p.name, p.ascii, p.alternates.joined(separator: ","), p.lat, p.lon, p.country, p.admin1,
                String(p.population), p.zone].joined(separator: "\t") + "\n"
    }
    for (code, name) in countries { out += "#country\t\(code)\t\(name)\n" }
    for (code, name) in regions.sorted(by: { $0.0 < $1.0 }) { out += "#admin1\t\(code)\t\(name)\n" }
    out += "#meta\tsource\tGeoNames cities15000 (https://download.geonames.org/export/dump/), trimmed\n"
    out += "#meta\tlicense\tCC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)\n"
    out += "#meta\tdownloaded\t\(downloaded)\n"
    out += "#meta\tplaces\t\(places.count)\n"
    return out
}

// Essential alternates for every place; then every other alternate of the largest places while the table fits.
var size = render(places).utf8.count
var withExtras = 0
for i in places.indices {
    let added = places[i].extra.reduce(0) { $0 + $1.utf8.count + 1 }
    guard size + added <= budget - 4096 else { break }
    places[i].alternates += places[i].extra
    size += added
    withExtras = i + 1
}
let text = render(places)
guard text.utf8.count <= budget else {
    FileHandle.standardError.write("the table is over budget: \(text.utf8.count) bytes\n".data(using: .utf8)!)
    exit(1)
}
try text.write(to: output, atomically: true, encoding: .utf8)
print("places: \(places.count), size: \(text.utf8.count) bytes, every alternate kept for the \(withExtras) largest places")
