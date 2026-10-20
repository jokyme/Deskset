import AppKit

/// One asynchronous confirmation; cancelling its owner closes it without answering.
protocol FileTrashConfirming: AnyObject {
    func show(paths: [String], completion: @escaping (Bool) -> Void)
    func cancel()
}

final class FileTrashConfirmation: FileTrashConfirming {
    private weak var host: SkinCompanionHost?
    private var alert: NSAlert?
    private var completion: ((Bool) -> Void)?

    init(host: SkinCompanionHost) {
        self.host = host
    }

    deinit { cancel() }

    static func presentation(paths: [String]) -> (message: String, detail: String) {
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
        if let name = names.first, names.count == 1 {
            return ("Move “\(name)” to the Trash?", "You can restore this item from the Trash.")
        }
        var detail = names.prefix(8).joined(separator: "\n")
        if names.count > 8 { detail += "\n… and \(names.count - 8) more items." }
        return ("Move \(names.count) items to the Trash?", detail)
    }

    static func makeAlert(paths: [String]) -> NSAlert {
        let content = presentation(paths: paths)
        let alert = NSAlert()
        alert.icon = AppIcon.image(size: 64)
        alert.alertStyle = .warning
        alert.messageText = content.message
        alert.informativeText = content.detail
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.keyEquivalent = "\r"
        trash.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        return alert
    }

    func show(paths: [String], completion: @escaping (Bool) -> Void) {
        cancel()
        self.completion = completion
        guard let host, !host.isStopped, host.showsWindows, !paths.isEmpty else {
            finish(false)
            return
        }
        let alert = Self.makeAlert(paths: paths)
        self.alert = alert
        alert.beginSheetModal(for: host.skinWindow) { [weak self] response in
            self?.finish(response == .alertFirstButtonReturn)
        }
    }

    func cancel() {
        completion = nil
        guard let alert else { return }
        self.alert = nil
        alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel)
        alert.window.orderOut(nil)
    }

    private func finish(_ confirmed: Bool) {
        let answer = completion
        completion = nil
        alert = nil
        answer?(confirmed)
    }
}
