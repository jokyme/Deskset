import Foundation
@testable import DesksetCore

/// Text held in memory for some files, by path (the Studio's editing session holds its widget's files this way).
private final class MemorySources: SourceProvider {
    private var texts: [String: String] = [:]

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() }

    func set(_ url: URL, _ text: String) { texts[Self.key(url)] = text }
    func sourceText(for url: URL) -> String? { texts[Self.key(url)] }
}

func runSourceProviderTests(_ t: TestRunner) {
    t.suite("SkinFileLoader: text in memory comes before the disk") {
        let ini = "[Rainmeter]\n[Variables]\n@Include=#@#Vars.inc\n[M]\nMeter=String\nText=#Word#\nFontSize=10\n"
        let (skin, host) = try makeSkin(t, ini, files: ["Root/@Resources/Vars.inc": "[Variables]\nWord=disk\n[Extra]\nMeter=String\n"])
        guard let include = skin.includedFiles.first else { return t.check(false, "the include loads") }
        let expand: (String, [String: String]) -> String = { raw, _ in
            raw.replacingOccurrences(of: "#@#", with: skin.resourcesDirectory.path + "/")
        }
        let memory = MemorySources()
        memory.set(skin.fileURL, ini.replacingOccurrences(of: "FontSize=10", with: "FontSize=30") + "[New]\nMeter=String\n")
        memory.set(include, "[Variables]\nWord=memory\n")
        let loaded = try SkinFileLoader.load(url: skin.fileURL, sources: memory, expandVariables: expand)
        t.equal(loaded.document.section(named: "M")?.value(forKey: "FontSize"), "30", "the main file from memory")
        t.check(loaded.document.section(named: "New") != nil)
        t.equal(loaded.document.section(named: "Variables")?.value(forKey: "Word"), "memory", "an include from memory")
        t.check(loaded.document.section(named: "Extra") == nil, "the include's text on disk is not read")

        // Files it does not hold come from disk.
        let partly = MemorySources()
        partly.set(include, "[Variables]\nWord=memory\n")
        let mixed = try SkinFileLoader.load(url: skin.fileURL, sources: partly, expandVariables: expand)
        t.equal(mixed.document.section(named: "M")?.value(forKey: "FontSize"), "10", "the main file from disk")
        t.equal(mixed.document.section(named: "Variables")?.value(forKey: "Word"), "memory")

        // A skin with a provider loads from it, and so do the lookups that read its files; the disk stays as it was.
        let studio = Skin(config: skin.config, fileURL: skin.fileURL, skinsDirectory: skin.skinsDirectory,
                          system: FakeSystem(), host: host)
        studio.sourceProvider = memory
        try studio.load()
        studio.update()
        t.equal(studio.variable("Word"), "memory")
        t.equal(studio.meter(named: "M")?.rawOption("FontSize"), "30")
        t.check(studio.meter(named: "New") != nil)
        t.equal(studio.sourceText(of: include), "[Variables]\nWord=memory\n")
        t.equal(studio.definingFiles(ofSection: "New").map(\.lastPathComponent), ["Skin.ini"])
        t.equal(studio.sharedDefinition(ofVariable: "Word"), studio.includedFiles.first)
        t.equal(skin.sharedDefinition(ofVariable: "Word"), skin.includedFiles.first, "(the disk copy finds it too)")
        t.check(try String(contentsOf: skin.fileURL, encoding: .utf8).contains("FontSize=10"), "the disk is untouched")
        t.equal(skin.sourceText(of: include), "[Variables]\nWord=disk\n[Extra]\nMeter=String\n", "no provider: the disk")
    }
}
