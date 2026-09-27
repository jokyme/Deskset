import Foundation

/// One edit of a widget's source files, as the Studio asks for it. These are the edits today's Studio makes to INI
/// files — the same text operations `IniWriter`, `IniKeyRemoval`, `Skin.appendSections`, `Skin.removeSection` and
/// `Skin.moveSection` make, applied to the text in memory instead of the files. Pages generated from a catalog of
/// properties will ask for property-level edits (set a property with a reach, bind it, insert, move), which the backend
/// turns into these.
public enum EditOp: Equatable {
    /// `key=value` in the first `[section]` block of `file` (added at the end of the block, or a new block at the end of
    /// the file); `afterIncludes`: after the block's `@Include` lines, so it wins over the same key of a shared file
    /// (`IniWriter.writeAfterIncludes`).
    case setValue(file: URL, section: String, key: String, value: String, afterIncludes: Bool)
    /// Every definition of `key` in the first `[section]` block of `file`.
    case removeKey(file: URL, section: String, key: String)
    /// New sections at the end of `file`, each option set in turn (`Skin.appendSections`).
    case appendSections([EditorComponents.Section], file: URL)
    /// Every block of `section` in each of `files` that has one (`Skin.removeSection`).
    case removeSection(String, files: [URL])
    /// The block of `section` moved right before `[before]` (nil: to the end of the file) — nothing when either is
    /// missing (`IniWriter.moveSection`).
    case moveSection(String, before: String?, file: URL)
    /// The whole text of `file` (the code pane's commit), in `encoding` when given (the code pane may have converted an
    /// ANSI file to Unicode), else in the file's own.
    case editSource(file: URL, text: String, encoding: TextFileEncoding?)

    /// The files the edit may change.
    public var files: [URL] {
        switch self {
        case .setValue(let file, _, _, _, _), .removeKey(let file, _, _), .appendSections(_, let file),
             .moveSection(_, _, let file), .editSource(let file, _, _):
            return [file]
        case .removeSection(_, let files):
            return files
        }
    }
}

/// The INI backend of an editing session: turns edits into changes of the files' text with today's write-back rules —
/// `IniWriter` (encoding, BOM and line endings byte for byte, first block wins, new keys at the end of the block),
/// `IniKeyRemoval`, `LayerReorder`'s section moves — applied to the text in memory. The first edit reads a file into the
/// buffers; later edits of one plan see what the earlier ones made.
public enum IniBackend {
    /// What `ops` do to the buffers' files, in order, as one change per file (nothing is changed yet: see
    /// `SourceBuffers.apply`). Files that end up as they were are left out. Throws what the file versions throw: a
    /// missing file, a section or key name that could not be read back.
    public static func plan(_ ops: [EditOp], in buffers: SourceBuffers) throws -> [SourceChange] {
        var scratch = Scratch(buffers: buffers)
        for op in ops { try scratch.apply(op) }
        return try scratch.changes()
    }

    /// The files' texts while a plan is worked out.
    struct Scratch {
        let buffers: SourceBuffers
        var files: [SourceFileID: (before: String, text: String, encodingBefore: TextFileEncoding,
                                   encoding: TextFileEncoding, source: Bool)] = [:]
        var order: [SourceFileID] = []

        init(buffers: SourceBuffers) { self.buffers = buffers }

        /// The current text of `url` in the plan (read into the buffers the first time).
        mutating func text(_ url: URL) throws -> (id: SourceFileID, text: String) {
            let id = SourceFileID(url)
            if let file = files[id] { return (id, file.text) }
            let buffer = try buffers.load(url)
            files[id] = (buffer.text, buffer.text, buffer.encoding, buffer.encoding, false)
            order.append(id)
            return (id, buffer.text)
        }

        mutating func set(_ id: SourceFileID, _ text: String) {
            files[id]?.text = text
        }

        mutating func apply(_ op: EditOp) throws {
            switch op {
            case .setValue(let file, let section, let key, let value, let afterIncludes):
                let (id, text) = try self.text(file)
                set(id, afterIncludes ? try IniWriter.writingAfterIncludes(text, value: value, key: key, section: section)
                                      : try IniWriter.updating(text, value: value, key: key, section: section))
            case .removeKey(let file, let section, let key):
                let (id, text) = try self.text(file)
                set(id, IniWriter.removingKey(text, key: key, section: section))
            case .appendSections(let sections, let file):
                let loaded = try self.text(file)
                var text = loaded.text
                for s in sections {
                    for o in s.options { text = try IniWriter.updating(text, value: o.value, key: o.key, section: s.name) }
                }
                set(loaded.id, text)
            case .removeSection(let section, let urls):
                for url in urls {
                    // A file that is gone defines nothing (`Skin.definingFiles` skips what it cannot read).
                    guard let loaded = try? self.text(url), IniWriter.definesSection(loaded.text, section: section) else {
                        continue
                    }
                    set(loaded.id, IniWriter.removingSection(loaded.text, section: section))
                }
            case .moveSection(let section, let before, let file):
                let (id, text) = try self.text(file)
                if let moved = IniWriter.movingSection(text, section: section, before: before) { set(id, moved) }
            case .editSource(let file, let text, let encoding):
                let (id, _) = try self.text(file)
                set(id, text)
                if let encoding { files[id]?.encoding = encoding }
                files[id]?.source = true
            }
        }

        /// One change per file that differs. An INI edit the file's ANSI code page cannot hold makes it UTF-16 LE with a
        /// BOM (as `IniWriter` writes it); typed code must fit the encoding the code pane gave it (`UnencodableText`).
        func changes() throws -> [SourceChange] {
            try order.compactMap { id in
                guard let file = files[id] else { return nil }
                var encoding = file.encoding
                if TextDecoding.encode(file.text, as: encoding) == nil {
                    if file.source { throw UnencodableText(file: id.url) }
                    encoding = .utf16LittleEndian(bom: true)
                }
                return SourceChange(file: id, before: file.before, after: file.text, encodingBefore: file.encodingBefore,
                                    encodingAfter: encoding)
            }
        }
    }

    /// Typed code with characters its file's encoding cannot hold (the code pane offers to convert the file first).
    public struct UnencodableText: Error, Equatable, CustomStringConvertible {
        public var file: URL
        public var description: String { "\(file.lastPathComponent) can't hold some of the characters in its encoding" }
    }
}

// MARK: - Edits of a skin's files

extension Skin {
    /// The edit `appendSections` makes: `sections` at the end of the skin file.
    public func op(appending sections: [EditorComponents.Section]) -> EditOp {
        .appendSections(sections, file: fileURL)
    }

    /// The edit `removeSection` makes: every block of the section in every file of the skin that has one.
    public func op(removingSection name: String) -> EditOp {
        .removeSection(document.section(named: name)?.name ?? name, files: sourceFiles)
    }

    /// The edit `moveSection` makes: the section's block right before `before` (nil: to the end of its file). nil when
    /// the two are in different files (the order of blocks in different files cannot change).
    public func op(movingSection name: String, before: String?) -> EditOp? {
        let file = sources.location(section: name)?.file ?? fileURL
        if let before, (sources.location(section: before)?.file ?? fileURL) != file { return nil }
        return .moveSection(document.section(named: name)?.name ?? name, before: before, file: file)
    }

    /// The edit `writeOwnOption` makes: `key=value` in the section itself (`ownTarget`).
    public func op(settingOwnOption key: String, of section: String, to value: String) -> EditOp {
        let target = ownTarget(section: section, key: key)
        return .setValue(file: target.file, section: target.section, key: key, value: value, afterIncludes: false)
    }

    /// The edit `writeOption` makes: `key=value` where the value is defined (`editTarget`).
    public func op(settingOption key: String, of section: String, to value: String) -> EditOp {
        let target = editTarget(section: section, key: key)
        return .setValue(file: target.file, section: target.section, key: key, value: value, afterIncludes: false)
    }

    /// The edit `removeOwnOption` makes (nil when the section has no own definition of the key).
    public func op(removingOwnOption key: String, of section: String) -> EditOp? {
        let sectionName = self.section(named: section)?.name ?? document.section(named: section)?.name ?? section
        guard let location = sources.location(section: sectionName, key: key) else { return nil }
        return .removeKey(file: location.file, section: sectionName, key: key)
    }
}
