import AppKit

enum AppMaintenancePanelSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Maintenance panel: default action, Escape and close preserve semantic button responses") {
            let offer = AppMaintenancePanel()
            offer.messageText = "Deskset 0.2.1 is available"
            offer.addButton(withTitle: "Update")
            offer.addButton(withTitle: "Skip This Version")
            offer.addButton(withTitle: "Close")
            t.equal(offer.buttons.first?.keyEquivalent, "\r")
            var primaryDuringModal = false
            var secondaryNotPrimaryDuringModal = false
            t.equal(run(offer) { panel in
                let primaryBtn = panel.buttons.first as? MaintenanceActionButton
                primaryDuringModal = primaryBtn?.rendersAsPrimary == true
                secondaryNotPrimaryDuringModal = panel.buttons.dropFirst()
                    .compactMap { $0 as? MaintenanceActionButton }
                    .allSatisfy { !$0.rendersAsPrimary }
                // App self-tests prohibit activation, so AppKit ignores synthetic Return key events.
                // Exercise the same button that a real key-window Return invokes.
                panel.buttons.first?.performClick(nil)
            }, .alertFirstButtonReturn)
            t.check(primaryDuringModal, "primary Update button stays primary while NSApp.runModal is active")
            t.check(secondaryNotPrimaryDuringModal, "secondary buttons stay non-primary during runModal")
            t.equal(run(offer) { $0.window.cancelOperation(nil) }, .alertThirdButtonReturn)
            t.equal(run(offer) { $0.window.performClose(nil) }, .alertThirdButtonReturn)

            let close = AppMaintenancePanel()
            close.addButton(withTitle: "Close")
            t.equal(close.buttons.first?.keyEquivalent, "\r")
            t.equal(run(close) { $0.window.cancelOperation(nil) }, .alertFirstButtonReturn,
                    "a single Close supports Escape as well as Return")
            t.equal(run(close) { panel in
                panel.buttons.first?.performClick(nil)
            }, .alertFirstButtonReturn)
        }

        t.suite("App: Maintenance panel: active installation cannot be dismissed by Escape or close") {
            let panel = AppInstallation.makeProgress(destination: URL(fileURLWithPath: "/Applications/Deskset.app"))
            t.check(panel.buttons.isEmpty, "the progress UI has no interactive modal action")
            t.check(panel.window.standardWindowButton(.closeButton)?.isEnabled == false)
            t.equal(run(panel, completion: { $0.dismiss(response: .OK) }) { current in
                current.window.cancelOperation(nil)
                current.window.performClose(nil)
            }, .OK, "only the explicit operation completion closes progress")
        }

        t.suite("App: Maintenance panel: long errors remain selectable within the screen") {
            let panel = AppMaintenancePanel()
            let text = Array(repeating: "A detailed installation error with a recoverable application path.", count: 120).joined(separator: "\n")
            panel.messageText = "Couldn’t install Deskset"
            panel.informativeText = text
            panel.addButton(withTitle: "Close")
            panel.content.fit(window: panel.window)
            panel.content.layoutSubtreeIfNeeded()
            t.equal(panel.informativeText, text, "all error text is preserved")
            t.check(panel.content.detail.isSelectable)
            let scroll = panel.content.detail.enclosingScrollView
            t.check(scroll != nil)
            t.check((scroll?.documentView?.frame.height ?? 0) > (scroll?.contentView.bounds.height ?? 0),
                    "long details can scroll instead of growing the window")
            if let screen = panel.window.screen ?? NSScreen.main {
                t.check(panel.window.frame.height <= screen.visibleFrame.height)
            }
        }

        t.suite("App: Maintenance panel: recovery and relaunch failures do not promise an unchanged application") {
            let backup = URL(fileURLWithPath: "/Applications/Deskset.recovery.app")
            let recovery = AppInstallation.makeFailure(error: AppInstallation.Failure.recovery(backup))
            t.check(recovery.content.errorLabel.stringValue.contains(backup.path), "keep the recovery location visible")
            t.check(!recovery.informativeText.contains("not been changed"), "failed rollback cannot promise an unchanged installed app")
            let launch = AppUpdateInstaller.makeFailureAlert(error: AppUpdateInstaller.Failure.launchFailed,
                                                            destination: URL(fileURLWithPath: "/Applications/Deskset.app"))
            t.check(launch.content.errorLabel.stringValue.contains(AppUpdateInstaller.Failure.launchFailed.localizedDescription))
            t.check(!launch.informativeText.contains("previous application"), "a relaunch failure can follow a successful replacement")
        }

        t.suite("App: Maintenance panel: indeterminate progress animates only while visible and respects Reduce Motion") {
            var reduceMotion = false
            let bar = MaintenanceProgressBarView(frame: NSRect(x: 0, y: 0, width: 364, height: 6),
                                                 reduceMotion: { reduceMotion })
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 364, height: 6))
            host.addSubview(bar)
            let window = MaintenancePanelContent.makeWindow(title: "Progress animation test")
            window.alphaValue = 0
            window.contentView = host
            defer { window.close() }
            t.check(!bar.isAnimating, "an unopened panel has no animation timer")

            window.orderFront(nil)
            bar.fraction = nil
            t.check(bar.isAnimating, "showing indeterminate progress starts its own animation")
            t.check(CodeFollowingSelfTests.wait(1) { bar.animationPhase > 0.02 }, "the visible highlight advances")
            let firstFrame = progressImage(bar)
            let firstPhase = bar.animationPhase
            t.check(CodeFollowingSelfTests.wait(1) { bar.animationPhase > firstPhase + 0.1 })
            t.check(firstFrame != nil && firstFrame != progressImage(bar), "the rendered progress pixels move")
            let modalPhase = bar.animationPhase
            let modalDeadline = Date(timeIntervalSinceNow: 1)
            while bar.animationPhase == modalPhase && Date() < modalDeadline {
                _ = RunLoop.main.run(mode: .modalPanel, before: modalDeadline)
            }
            t.check(bar.animationPhase != modalPhase, "the highlight also advances in an installer modal loop")

            bar.fraction = 0.48
            t.check(!bar.isAnimating, "determinate progress stops the timer immediately")
            t.equal(bar.accessibilityValue() as? Int, 48)
            bar.fraction = nil
            bar.isHidden = true
            t.check(!bar.isAnimating, "hiding the progress view stops the timer")
            bar.isHidden = false
            t.check(bar.isAnimating, "unhiding the progress view resumes activity")
            host.isHidden = true
            t.check(!bar.isAnimating, "hiding its containing card stops the timer")
            host.isHidden = false
            t.check(bar.isAnimating)

            reduceMotion = true
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            t.check(!bar.isAnimating, "Reduce Motion stops movement without changing system preferences")
            t.equal(bar.accessibilityValue() as? String, "Indeterminate", "a static cue must not claim a percentage")
            reduceMotion = false
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            t.check(bar.isAnimating, "changes to Reduce Motion take effect while the panel is open")

            window.orderOut(nil)
            t.check(CodeFollowingSelfTests.wait(1) { !bar.isAnimating }, "ordering the panel out stops the timer")
            window.orderFront(nil)
            bar.fraction = nil
            t.check(bar.isAnimating)
            window.close()
            t.check(!bar.isAnimating, "closing a retained panel stops its timer immediately")
            window.orderFront(nil)
            bar.fraction = nil
            t.check(bar.isAnimating, "a reused panel can animate again")
            bar.removeFromSuperview()
            t.check(!bar.isAnimating, "removing the progress view tears down the timer")
        }

        t.suite("App: Maintenance panel: exact 520pt geometry and all update/install states") {
            let state = AppState(fileURL: t.temporaryDirectory("panel-geometry").appendingPathComponent("state.json"))
            let app = AppController(state: state, presentsWindows: false)
            let release = AppRelease(version: ReleaseVersion("0.2.1")!,
                                     url: URL(string: "https://github.com/jokyme/Deskset/releases/tag/v0.2.1")!)

            let offer = app.makeUpdateAlert(.available(release))
            offer.content.fit(window: offer.window)
            t.equal(offer.content.frame.size, NSSize(width: 520, height: 244))
            t.equal(offer.content.cardView.frame, NSRect(x: 104, y: 88, width: 392, height: 68))
            t.equal(offer.buttons[0].frame, NSRect(x: 408, y: 202, width: 88, height: 28), "Update button matches Fig 2")
            t.equal(offer.buttons[1].frame, NSRect(x: 24, y: 202, width: 128, height: 28), "Skip This Version button matches Fig 2")
            t.equal(offer.buttons[2].frame, NSRect(x: 316, y: 202, width: 84, height: 28), "Close button matches Fig 2")
            t.equal(offer.content.badgeView.accessibilityRole(), .staticText)
            t.equal(offer.content.badgeView.accessibilityLabel(), AppUpdateAsset.processorName)
            t.check(offer.buttons[0].focusRingType == .exterior && offer.buttons[0].canBecomeKeyView)

            let upToDate = app.makeUpdateAlert(.upToDate)
            upToDate.content.fit(window: upToDate.window)
            t.equal(upToDate.content.frame.size, NSSize(width: 520, height: 224))
            t.equal(upToDate.content.cardView.frame, NSRect(x: 104, y: 88, width: 392, height: 48))
            t.equal(upToDate.buttons[0].frame, NSRect(x: 412, y: 182, width: 84, height: 28))

            let noRelease = app.makeUpdateAlert(.noRelease)
            noRelease.content.fit(window: noRelease.window)
            t.equal(noRelease.content.frame.size, NSSize(width: 520, height: 224))

            let checkFailed = app.makeUpdateAlert(.failed("The update server connection was interrupted."))
            checkFailed.content.fit(window: checkFailed.window)
            t.equal(checkFailed.content.frame.size, NSSize(width: 520, height: 244))

            let dest = URL(fileURLWithPath: "/Applications/Deskset.app")
            let firstInstall = AppInstallation.makeConfirmation(sourceVersion: "0.2.1", installedVersion: nil, destination: dest)
            firstInstall.content.fit(window: firstInstall.window)
            t.equal(firstInstall.content.frame.size, NSSize(width: 520, height: 244))
            t.equal(firstInstall.buttons[0].frame, NSRect(x: 330, y: 202, width: 166, height: 28))
            t.equal(firstInstall.buttons[1].frame, NSRect(x: 238, y: 202, width: 84, height: 28))
            t.check(firstInstall.content.footnote.frame.maxX <= firstInstall.buttons[1].frame.minX - 12,
                    "footnote never overlaps trailing button pair")

            let replaceInstall = AppInstallation.makeConfirmation(sourceVersion: "0.2.1", installedVersion: "0.2.0", destination: dest)
            replaceInstall.content.fit(window: replaceInstall.window)
            t.equal(replaceInstall.content.frame.size, NSSize(width: 520, height: 244))
            t.equal(replaceInstall.buttons[0].frame, NSRect(x: 360, y: 202, width: 136, height: 28))
            t.equal(replaceInstall.buttons[1].frame, NSRect(x: 268, y: 202, width: 84, height: 28))
            t.check(replaceInstall.content.footnote.frame.maxX <= replaceInstall.buttons[1].frame.minX - 12)

            let conflict = AppInstallation.makeRunningConflict(sourceVersion: "0.2.1", destination: dest)
            conflict.content.fit(window: conflict.window)
            t.equal(conflict.content.frame.size, NSSize(width: 520, height: 244))

            let installProg = AppInstallation.makeProgress(sourceVersion: "0.2.1", destination: dest)
            installProg.content.fit(window: installProg.window)
            t.equal(installProg.content.frame.size, NSSize(width: 520, height: 244))
            t.equal(installProg.content.progressBar.accessibilityRole(), .progressIndicator)
            t.equal(installProg.content.progressBar.accessibilityValue() as? String, "Indeterminate")
            installProg.content.setProgress(visible: true, fraction: 0.48, text: "Downloading update package…")
            t.equal(installProg.content.progressBar.accessibilityValue() as? Int, 48)
            t.equal(installProg.content.progressBar.accessibilityValueDescription(), "48%")

            let installFail = AppInstallation.makeFailure(error: AppInstallation.Failure.signature)
            installFail.content.fit(window: installFail.window)
            t.equal(installFail.content.frame.size, NSSize(width: 520, height: 244))

            let launchFail = AppInstallation.makeLaunchFailure(error: AppUpdateInstaller.Failure.launchFailed, destination: dest)
            launchFail.content.fit(window: launchFail.window)
            t.equal(launchFail.content.frame.size, NSSize(width: 520, height: 244))

            let helperFail = AppUpdateInstaller.makeFailureAlert(error: AppUpdateInstaller.Failure.helperFailed, destination: dest)
            helperFail.content.fit(window: helperFail.window)
            t.equal(helperFail.content.frame.size, NSSize(width: 520, height: 244))

            let longDest = URL(fileURLWithPath: "/Users/administrator/Library/Application Support/Very/Long/Nested/Path/Applications/Deskset.app")
            let longConfirm = AppInstallation.makeConfirmation(sourceVersion: "0.2.1-rc.100", installedVersion: nil, destination: longDest)
            longConfirm.content.fit(window: longConfirm.window)
            t.check(longConfirm.content.cardMainValue.isSelectable)
            t.check(longConfirm.content.cardMainValue.stringValue.contains(longDest.path))
            t.check(longConfirm.content.cardView.frame.height > 68, "long path wraps without silent truncation")
        }
    }

    private static func progressImage(_ bar: MaintenanceProgressBarView) -> Data? {
        guard let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else { return nil }
        bar.cacheDisplay(in: bar.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func run(_ panel: AppMaintenancePanel, completion: ((AppMaintenancePanel) -> Void)? = nil,
                            action: @escaping (AppMaintenancePanel) -> Void) -> NSApplication.ModalResponse? {
        var result: NSApplication.ModalResponse?
        panel.window.alphaValue = 0
        RunLoop.main.perform {
            let trigger = Timer(timeInterval: 0.02, repeats: false) { _ in action(panel) }
            let complete = Timer(timeInterval: 0.06, repeats: false) { _ in completion?(panel) }
            let watchdog = Timer(timeInterval: 3, repeats: false) { _ in panel.dismiss(response: .abort) }
            [trigger, complete, watchdog].forEach { RunLoop.main.add($0, forMode: .modalPanel) }
            result = panel.runModal()
            [trigger, complete, watchdog].forEach { $0.invalidate() }
        }
        _ = CodeFollowingSelfTests.wait(4) { result != nil }
        return result
    }
}
