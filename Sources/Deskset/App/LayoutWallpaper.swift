import AppKit
import DesksetCore

/// Layouts carry the standard Wallpaper.bmp filename, including when its image uses another encoding.
/// The boundary is replaceable in tests, so a layout test never changes
/// the user's desktop. macOS desktop options stay as the user selected them; layouts do not add platform keys.
protocol LayoutWallpaper {
    func capture() throws -> Data?
    func apply(_ bitmap: Data) throws
}

final class MemoryLayoutWallpaper: LayoutWallpaper {
    var bitmap: Data?
    private(set) var applied: [Data] = []
    init(bitmap: Data? = nil) { self.bitmap = bitmap }
    func capture() throws -> Data? { bitmap }
    func apply(_ bitmap: Data) throws { self.bitmap = bitmap; applied.append(bitmap) }
}

final class SystemLayoutWallpaper: LayoutWallpaper {
    private let file: URL
    init(file: URL) { self.file = file }

    func capture() throws -> Data? {
        guard let screen = NSScreen.screens.first,
              let source = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return try Self.readPicture(at: source)
    }

    static func readPicture(at source: URL) throws -> Data {
        let data = try Data(contentsOf: source)
        guard NSBitmapImageRep(data: data) != nil else {
            throw LayoutOperationError.wallpaper(L("The current desktop picture is not a readable image."))
        }
        return data
    }

    func apply(_ bitmap: Data) throws {
        guard NSBitmapImageRep(data: bitmap) != nil else {
            throw LayoutOperationError.wallpaper(L("Wallpaper.bmp is not a readable image."))
        }
        let oldFile = try? Data(contentsOf: file)
        let desktops = NSScreen.screens.map { screen in
            (screen, NSWorkspace.shared.desktopImageURL(for: screen),
             NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.write(to: file, options: .atomic)
        do {
            for (screen, _, options) in desktops {
                try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: options)
            }
        } catch {
            if let oldFile { try? oldFile.write(to: file, options: .atomic) }
            else { try? FileManager.default.removeItem(at: file) }
            for (screen, url, options) in desktops {
                if let url { try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options) }
            }
            throw error
        }
        DesktopInputs.mainScreenDesktop.refresh()
        DesktopInputs.displayDesktops.refresh()
        DesktopInputs.allScreenDesktops.refresh()
        DesktopInputs.desktopFillColor.refresh()
    }
}
