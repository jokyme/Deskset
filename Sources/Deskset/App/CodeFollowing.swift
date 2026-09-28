import AppKit
import DesksetCore

/// What a step, an undo or a redo did to the text of the widget's files, for the code pane (design §9.3: "the code pane
/// receives the same TextEdits and changes only those characters"): for each file, the edits in the order they were
/// made (UTF-16 ranges, each on the text the one before it left), fingerprints of the text before the first and after the
/// last, whether its encoding changed, and the bytes the file holds now. The code pane makes the same edits in its copy
/// of a file that holds no typing of its own (`CodeEditorView.follow`) instead of reading the files again.
struct SourceTextEdits {
    struct File {
        let url: URL
        var edits: [TextEdit]
        /// The text the edits start from, and the one they leave.
        var before: TextDigest
        var after: TextDigest
        /// A change could not keep the file's encoding (an ANSI file became UTF-16): the file is read again.
        var encodingChanged: Bool
        /// What the file holds once the step is written (nil: not known).
        var bytes: Data?
    }

    var files: [File]

    /// No file's text changed (the Studio's instance took typed code that is not written yet).
    static let none = SourceTextEdits(files: [])

    init(files: [File]) { self.files = files }

    /// The edits of `changes`, made in that order to the text in memory, and the bytes `buffers` hold for each file now.
    /// A file whose changes do not follow on from each other is left out of the edits — the code pane then finds its
    /// text is not the one they start from, or never held it — so it is read again.
    init(_ changes: [SourceChange], in buffers: SourceBuffers) {
        var files: [File] = []
        var broken: Set<SourceFileID> = []
        var index: [SourceFileID: Int] = [:]
        for change in changes where !broken.contains(change.file) {
            let changed = change.encodingBefore != change.encodingAfter
            if let i = index[change.file] {
                guard files[i].after == change.digestBefore else {
                    broken.insert(change.file)
                    continue
                }
                files[i].edits.append(change.edit)
                files[i].after = change.digestAfter
                files[i].encodingChanged = files[i].encodingChanged || changed
            } else {
                index[change.file] = files.count
                files.append(File(url: change.file.url, edits: [change.edit], before: change.digestBefore,
                                  after: change.digestAfter, encodingChanged: changed, bytes: nil))
            }
        }
        for i in files.indices {
            files[i].bytes = buffers.buffer(files[i].url)?.bytes
            // A file that could not be followed reads as one whose encoding changed: read again.
            if broken.contains(SourceFileID(files[i].url)) { files[i].encodingChanged = true }
        }
        self.files = files
    }
}

extension InspectorWindowController {
    /// The code pane follows a step by its edits (`SourceTextEdits`) instead of reading the files again: when it shows
    /// the files the skin reads now, in the same order (none added or dropped: an @Include changed), and every file the
    /// step changed is followed (`CodeEditorView.follow`: no typing of its own, the same encoding, the text the step
    /// started from). False when the pane must read the files again (`syncCodePane`'s full way).
    func followCodeEdits(_ edits: SourceTextEdits, in skin: Skin) -> Bool {
        guard let codeView = loadedCodeView, let current = codeView.currentFile else { return false }
        var listed: [URL] = []
        for url in skin.sourceFiles.map(\.standardizedFileURL) where !listed.contains(url) { listed.append(url) }
        guard codeView.files == listed, listed.contains(current), codeView.follow(edits) else { return false }
        keepCodeClearOfRuler()
        codeStale = false
        return true
    }
}
