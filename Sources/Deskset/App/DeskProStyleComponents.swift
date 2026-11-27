import AppKit
import DesksetCore
import DesksetDraw
import SwiftUI

/// Shared Deskset Pro visual tokens and reusable SwiftUI building blocks for Deskset's macOS 13+ windows.
enum DeskProPalette {
    static let page = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.157, alpha: 1)
            : NSColor(white: 0.93, alpha: 1)
    })

    static let box = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.20, alpha: 1)
            : .white
    })

    static let librarySidebar = Color(nsColor: .underPageBackgroundColor).opacity(0.6)

    static func hex(_ value: UInt32, alpha: Double = 1.0) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            opacity: alpha
        )
    }

    static let risoBlue = hex(0x3D5BD9)
    static let signalOrange = hex(0xFF6B2C)
    static let discoverBlue = hex(0x2F6FEB)
    static let suitePurple = hex(0x8B5CF6)
    static let loadedGreen = hex(0x10B981)
    static let privacyGreen = hex(0x2E9E62)
    static let favoriteAmber = hex(0xF59E0B)
    static let aboutInk = hex(0x1C1C1E)
    static let indigoTint = hex(0x6E5BD6)
}

/// Small brand mark rendered from `AppIcon` at crisp Retina resolution.
struct DeskAppMark: View {
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: AppIcon.image(size: max(64, size * 2)))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Draggable background region for full-size titlebarless window headers.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Configures an `NSWindow` with Deskset Pro's full-size content view and transparent title bar while keeping standard traffic lights.
enum DeskProWindowStyle {
    static func apply(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.collectionBehavior.insert(.fullScreenNone)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
    }
}

/// Deskset Pro's `SettingsGroup`: optional bold heading, rounded card container, optional secondary footer.
struct DeskProSettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DeskProPalette.box))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
        .padding(.bottom, 22)
    }
}

/// Deskset Pro's `SettingsRow`: optional tinted symbol circle, title + wrapping detail, trailing control, and inset divider.
struct DeskProSettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    var symbolTint: Color = .secondary
    var detailIsError = false
    var indent = false
    var divider = true
    @ViewBuilder let control: () -> Control
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(symbolTint)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(symbolTint.opacity(0.12)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundColor(detailIsError ? .red : .secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .opacity(isEnabled ? 1 : 0.45)
                Spacer(minLength: 12)
                control()
            }
            .padding(.leading, indent ? 54 : 14)
            .padding(.trailing, 14)
            .padding(.vertical, 7)
            .frame(minHeight: 44)

            if divider {
                Divider().padding(.leading, indent ? 54 : 14)
            }
        }
    }
}

// MARK: - Live / Off-screen Skin Thumbnail Renderer & Cache

/// Renders and caches 2x previews of installed `.ini` skins on the main thread incrementally so the Widget Library
/// card grid displays real widget previews just like Deskset Pro without blocking scrolling.
final class SkinThumbnailCache: ObservableObject {
    struct Entry {
        let image: NSImage
        let pointSize: NSSize
    }

    private var entries: [String: Entry] = [:]
    private var failedKeys: Set<String> = []
    private var order: [String] = []
    private var pendingKeys: [Request] = []
    private var scheduled = false
    private let maxEntries = 140

    private struct Request: Equatable {
        let key: String
        let config: String
        let file: String
        let isDark: Bool
    }

    func invalidateAll() {
        entries.removeAll()
        failedKeys.removeAll()
        order.removeAll()
        pendingKeys.removeAll()
        objectWillChange.send()
    }

    func thumbnail(config: String, file: String, isDark: Bool, app: AppController, immediate: Bool = false) -> Entry? {
        let url = SkinLibrary.directory(for: config, root: app.skinsDirectory).appendingPathComponent(file)
        let modTime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(config.lowercased())|\(file.lowercased())|\(isDark ? "dark" : "light")|\(Int(modTime))"
        if let hit = entries[key] {
            return hit
        }
        if failedKeys.contains(key) {
            return nil
        }
        let req = Request(key: key, config: config, file: file, isDark: isDark)
        if immediate {
            return renderNow(req, app: app)
        }
        if !pendingKeys.contains(req) {
            pendingKeys.append(req)
            scheduleNext(app: app)
        }
        return nil
    }

    /// Pre-renders up to `limit` configs synchronously for headless `--snapshot-ui`.
    func prewarm(configs: [(config: String, file: String)], isDark: Bool, app: AppController, limit: Int = 8) {
        for item in configs.prefix(limit) {
            _ = thumbnail(config: item.config, file: item.file, isDark: isDark, app: app, immediate: true)
        }
    }

    private func scheduleNext(app: AppController) {
        guard !scheduled, !pendingKeys.isEmpty else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self, weak app] in
            guard let self else { return }
            self.scheduled = false
            guard let app, !self.pendingKeys.isEmpty else { return }
            let next = self.pendingKeys.removeFirst()
            if self.entries[next.key] == nil && !self.failedKeys.contains(next.key) {
                _ = self.renderNow(next, app: app)
                self.objectWillChange.send()
            }
            if !self.pendingKeys.isEmpty {
                self.scheduleNext(app: app)
            }
        }
    }

    @discardableResult
    private func renderNow(_ req: Request, app: AppController) -> Entry? {
        let fileURL = SkinLibrary.directory(for: req.config, root: app.skinsDirectory).appendingPathComponent(req.file)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let fileSize = attrs[.size] as? Int,
              fileSize <= 2 * 1024 * 1024 else {
            failedKeys.insert(req.key)
            return nil
        }

        let host = ThumbnailSkinHost(isDark: req.isDark)

        let skin = Skin(
            config: req.config,
            fileURL: fileURL,
            skinsDirectory: app.skinsDirectory,
            system: app.system,
            host: host
        )
        do {
            try skin.load()
        } catch {
            failedKeys.insert(req.key)
            return nil
        }
        Fonts.registerFonts(for: skin)
        skin.update()

        let rawW = skin.width.isFinite ? skin.width : 0
        let rawH = skin.height.isFinite ? skin.height : 0
        guard rawW >= 2, rawH >= 2 else {
            failedKeys.insert(req.key)
            return nil
        }
        let skinW = min(rawW, 1200)
        let skinH = min(rawH, 900)
        let maxPixels: Double = 640
        let scale = min(2.0, maxPixels / max(skinW, skinH))
        let pxW = max(1, Int(ceil(skinW * scale)))
        let pxH = max(1, Int(ceil(skinH * scale)))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cg = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            failedKeys.insert(req.key)
            return nil
        }

        cg.clear(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        cg.saveGState()
        cg.translateBy(x: 0, y: CGFloat(pxH))
        cg.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let target = DrawTarget.prepareOwnedBitmap(cg, glass: .placeholder(dark: req.isDark))
        SkinRenderer.draw(skin, in: cg, target: target)
        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()
        withExtendedLifetime(host) {}

        guard let cgImage = cg.makeImage() else {
            failedKeys.insert(req.key)
            return nil
        }
        let ptSize = NSSize(width: skinW, height: skinH)
        let nsImage = NSImage(cgImage: cgImage, size: ptSize)
        let entry = Entry(image: nsImage, pointSize: ptSize)
        if entries.count >= maxEntries, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        entries[req.key] = entry
        order.append(req.key)
        return entry
    }
}

private final class ThumbnailSkinHost: SkinHost {
    let isDark: Bool

    init(isDark: Bool) {
        self.isDark = isDark
    }

    func skinNeedsDisplay(_ skin: Skin) {}
    func skin(_ skin: Skin, handle bang: Bang) -> Bool { true }
    func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {}
    func skin(_ skin: Skin, execute target: String, arguments: [String]) {}
    func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {}

    func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin) -> (width: Double, height: Double) {
        SkinRenderer.textSize(text, style: style, wrapWidth: wrapWidth, for: skin)
    }

    func textEditLayout(_ text: String, style: TextStyle, viewport: SkinRect, multiline: Bool,
                        for skin: Skin) -> TextEditLayout {
        SkinRenderer.textEditLayout(text, style: style, viewport: viewport, multiline: multiline, for: skin)
    }

    func imageSize(atPath path: String) -> (width: Double, height: Double)? {
        Images.size(atPath: path)
    }

    func environment(for skin: Skin) -> SkinEnvironment {
        var env = EnvironmentStore.shared.environment(windowFrame: nil)
        env.appearance = isDark ? .dark : .light
        env.windowFrame = SkinRect(x: 0, y: 0, width: skin.width, height: skin.height)
        return env
    }
}
