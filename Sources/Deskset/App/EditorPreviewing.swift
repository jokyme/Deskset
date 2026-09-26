import AppKit
import DesksetCore

/// Preview-then-commit for the inspector's continuous controls (sliders, circular sliders, held steppers), the way
/// color picking works: every step is shown at once with `Skin.preview` / `previewVariables` and nothing is written;
/// the value is written once when the mouse goes up (or after a short pause for keyboard steps), as one undo step.
extension InspectorWindowController {
    typealias PreviewTarget = InspectorState.PreviewTarget

    /// Shows `value` for `target` live; writes it now when `finished`, else after a pause without further steps.
    /// Typed code not committed yet is committed first, so the preview (and the write that ends it) is on top of it.
    func previewProperty(_ target: PreviewTarget, value: String, finished: Bool) {
        let state = inspectorState
        if codeHasUncommittedChanges, !committingCode { guard flushCode() else { return } }
        if let current = state.preview, current != target { commitPendingPreview() }
        guard let skin else { return }
        if state.preview == nil {
            state.previewOriginal = writtenValue(of: target)
            // Closing the window writes the value (or, when the skin is already gone, at least ends the preview, so
            // the skin on the desktop does not keep showing it).
            if let observer = state.closeObserver { NotificationCenter.default.removeObserver(observer) }
            let owner = controller
            state.closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                         queue: nil) { [weak self, weak skin, weak owner] _ in
                guard let self else { skin?.endPreview(); return }
                if self.skin != nil {
                    self.commitPendingPreview()
                } else if let skin {
                    // The window let go of the skin first: write without an undo step (its undo stack closes too).
                    self.writePendingPreview(to: skin, controller: owner)
                }
            }
        }
        state.preview = target
        state.previewValue = value
        if let variable = target.variable {
            skin.previewVariables([variable: value])
        } else if target.section.caseInsensitiveCompare("Variables") == .orderedSame {
            skin.previewVariables([target.key: value])
        } else {
            skin.preview(section: target.section, [target.key: value])
        }
        // The live tick compares the rows with the skin's options: a previewed value must not look like a change made
        // elsewhere (that would rebuild the inspector under the pointer).
        rows = currentRows()
        canvas.needsDisplay = true
        state.previewTimer?.invalidate()
        state.previewTimer = nil
        if finished {
            commitPendingPreview()
        } else {
            let timer = Timer(timeInterval: 0.8, repeats: false) { [weak self] _ in self?.commitPendingPreview() }
            RunLoop.main.add(timer, forMode: .default)
            state.previewTimer = timer
        }
    }

    /// Writes a pending preview now (nothing when it ended where it started).
    func commitPendingPreview() {
        let state = inspectorState
        state.previewTimer?.invalidate()
        state.previewTimer = nil
        stopObservingClose()
        guard let target = state.preview, let value = state.previewValue else { return }
        let original = state.previewOriginal
        state.preview = nil
        state.previewValue = nil
        state.previewOriginal = nil
        if value == original {
            skin?.endPreview()
            rows = currentRows()
            canvas.needsDisplay = true
            return
        }
        // A Shape layer's option from a look other widgets share: the layer's own value (`writeShapeOption`).
        if target.variable == nil, writesOwnShapeOption(meter: target.section, key: target.key) {
            return writeShapeOption(value, key: target.key, meter: target.section, label: target.name)
        }
        writeProperty(section: target.section, key: target.key, value: value, variable: target.variable, label: target.name)
    }

    /// Drops a pending preview without writing it.
    func cancelPendingPreview() {
        let state = inspectorState
        state.previewTimer?.invalidate()
        state.previewTimer = nil
        stopObservingClose()
        guard state.preview != nil else { return }
        state.preview = nil
        state.previewValue = nil
        state.previewOriginal = nil
        skin?.endPreview()
        rows = currentRows()
        canvas.needsDisplay = true
    }

    /// Writes a pending preview straight to `skin` and refreshes it (the window is closing).
    func writePendingPreview(to skin: Skin, controller owner: SkinController?) {
        let state = inspectorState
        state.previewTimer?.invalidate()
        state.previewTimer = nil
        stopObservingClose()
        defer { state.preview = nil; state.previewValue = nil; state.previewOriginal = nil }
        skin.endPreview()
        guard let target = state.preview, let value = state.previewValue, value != state.previewOriginal else { return }
        do {
            if let variable = target.variable {
                try skin.writeOption(section: "Variables", key: variable, value: value)
            } else {
                try skin.writeOption(section: target.section, key: target.key, value: value)
            }
            if let owner, !owner.isStopped { app.refresh(owner) }
        } catch {
            Log.write("Could not save \(target.key): \(error)", level: .warning)
        }
    }

    private func stopObservingClose() {
        if let observer = inspectorState.closeObserver { NotificationCenter.default.removeObserver(observer) }
        inspectorState.closeObserver = nil
    }

    /// Whether a continuous control is previewing (self-tests).
    var isPreviewingProperty: Bool { inspectorState.preview != nil }

    /// The text written in the file for a preview target (the variable's definition for `#Var#` values).
    func writtenValue(of target: PreviewTarget) -> String? {
        guard let skin else { return nil }
        if let variable = target.variable {
            return skin.inspectedVariables().first { $0.name.caseInsensitiveCompare(variable) == .orderedSame }?.raw
        }
        if target.section.caseInsensitiveCompare("Variables") == .orderedSame {
            return skin.inspectedVariables().first { $0.name.caseInsensitiveCompare(target.key) == .orderedSame }?.raw
        }
        return skin.inspectedOptions(ofSection: target.section)
            .first { $0.key.caseInsensitiveCompare(target.key) == .orderedSame }?.raw
    }

    /// The whole inspector column (not only what its scroll view shows) on the pane's background, for checking the
    /// layout of long inspectors (self-tests write it when DESKSET_INSPECTOR_SNAPSHOTS names a folder).
    func inspectorDocumentSnapshot() -> NSBitmapImageRep? {
        let stack = inspectorStack
        stack.layoutSubtreeIfNeeded()
        // The cards themselves (the stack can be taller than its content while the scroll view settles).
        let content = stack.arrangedSubviews.reduce(NSRect.null) { $0.union($1.frame) }
        guard !content.isNull else { return nil }
        let rect = NSRect(x: 0, y: content.minY - 18, width: stack.bounds.width, height: content.height + 36)
            .intersection(stack.bounds)
        let size = rect.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        let dark = stack.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        context.cgContext.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(red: 0.965, green: 0.962, blue: 0.957, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let part = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return rep }
        part.size = size
        stack.cacheDisplay(in: rect, to: part)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        part.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
