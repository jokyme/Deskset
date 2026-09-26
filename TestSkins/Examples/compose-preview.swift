// Renders every example skin in DefaultSkins/Deskset (dark and light theme) with `Deskset --render` and composes
// them into one preview image. Run from the repository root after `swift build`:
//
//     swift TestSkins/Examples/compose-preview.swift [out.png] [--quick]
//
// Default output: TestSkins/Examples/preview.png. The graph skins (System, Network) run about 2½ minutes of updates
// so their history graphs are full (`--quick`: a few seconds). Skins are rendered on a transparent background and
// placed on wallpaper-like gradients, so their translucency shows as it would on the desktop.
import AppKit

let fm = FileManager.default
let repo = URL(fileURLWithPath: fm.currentDirectoryPath)
let binary = repo.appendingPathComponent(".build/debug/Deskset")
let source = repo.appendingPathComponent("DefaultSkins/Deskset")
let args = Array(CommandLine.arguments.dropFirst())
let quick = args.contains("--quick")
let output = args.first { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
    ?? repo.appendingPathComponent("TestSkins/Examples/preview.png")

guard fm.isExecutableFile(atPath: binary.path), fm.fileExists(atPath: source.path) else {
    FileHandle.standardError.write("Run from the repository root after `swift build`.\n".data(using: .utf8)!)
    exit(1)
}

/// Pixels per point of the renders and of the preview.
let scale: CGFloat = 2

// MARK: Skins and layout (points)

struct Item {
    var file: String
    /// Column and top offset inside a theme panel.
    var column: Int
    var y: CGFloat
    /// Many updates to fill a history graph.
    var graph = false
}

let columnWidth: CGFloat = 260
let gap: CGFloat = 24
let margin: CGFloat = 40
let items = [
    Item(file: "Clock/Clock.ini", column: 0, y: 0),
    Item(file: "System/System.ini", column: 0, y: 132 + gap, graph: true),
    Item(file: "Clock/Dial.ini", column: 1, y: 0),
    Item(file: "Disk/Volumes.ini", column: 1, y: 184 + gap),
    Item(file: "Network/Network.ini", column: 2, y: 0, graph: true),
    Item(file: "Disk/Disk.ini", column: 2, y: 188 + gap),
    Item(file: "Calendar/Calendar.ini", column: 3, y: 0),
    Item(file: "Battery/Battery.ini", column: 3, y: 232 + gap),
]
let panelWidth = margin * 2 + columnWidth * 4 + gap * 3
let panelHeight = margin + 36 + 380 + margin

// MARK: Rendering

let work = fm.temporaryDirectory.appendingPathComponent("deskset-preview-\(getpid())")
try? fm.removeItem(at: work)

/// Copies the skins into a scratch Skins folder with the given theme.
func prepare(theme: String) throws -> URL {
    let skins = work.appendingPathComponent(theme).appendingPathComponent("Skins")
    try fm.createDirectory(at: skins, withIntermediateDirectories: true)
    let root = skins.appendingPathComponent("Deskset")
    try fm.copyItem(at: source, to: root)
    let variables = root.appendingPathComponent("@Resources/Variables.inc")
    let text = try String(contentsOf: variables, encoding: .utf8)
    try text.replacingOccurrences(of: "\nTheme=Dark\n", with: "\nTheme=\(theme)\n")
        .write(to: variables, atomically: true, encoding: .utf8)
    return root
}

func render(_ item: Item, root: URL, to png: URL) -> Process {
    let p = Process()
    p.executableURL = binary
    // One update per 0.6 s: the app samples network counters at most every 0.5 s. 230 updates fill a
    // 224-pixel graph.
    let updates = item.graph ? (quick ? "12" : "230") : "3"
    let interval = item.graph ? "600" : "100"
    p.arguments = ["--render", root.appendingPathComponent(item.file).path, "--out", png.path,
                   "--updates", updates, "--interval", interval, "--scale", "\(scale)"]
    p.standardOutput = FileHandle.nullDevice
    do { try p.run() } catch { print("cannot run \(binary.path): \(error)") }
    return p
}

let themes = ["Dark", "Light"]
var jobs: [(String, Item, URL, Process)] = []
for theme in themes {
    let root = try prepare(theme: theme)
    for item in items {
        let png = work.appendingPathComponent("\(theme)-\(item.file.replacingOccurrences(of: "/", with: "-")).png")
        jobs.append((theme, item, png, render(item, root: root, to: png)))
    }
}
print("rendering \(jobs.count) skins…")
for job in jobs { job.3.waitUntilExit() }

// MARK: Composition

let width = Int(panelWidth * scale)
let height = Int(panelHeight * CGFloat(themes.count) * scale)
guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
// Top-left origin in points.
ctx.translateBy(x: 0, y: CGFloat(height))
ctx.scaleBy(x: scale, y: -scale)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Wallpaper-like backdrop: a diagonal gradient with two soft glows.
func backdrop(_ rect: CGRect, dark: Bool) {
    ctx.saveGState()
    ctx.clip(to: rect)
    let colors = dark ? [rgb(22, 30, 72), rgb(58, 40, 98), rgb(18, 62, 96)]
        : [rgb(214, 226, 246), rgb(238, 226, 242), rgb(222, 240, 236)]
    let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY),
                           end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
    for (x, y, r, c) in dark
        ? [(0.18, 0.2, 420.0, rgb(90, 120, 255, 0.35)), (0.85, 0.9, 480.0, rgb(255, 110, 150, 0.22))]
        : [(0.2, 0.15, 420.0, rgb(255, 255, 255, 0.7)), (0.85, 0.85, 480.0, rgb(255, 200, 170, 0.35))] {
        let center = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        let glow = CGGradient(colorsSpace: nil, colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
    }
    ctx.restoreGState()
}

func label(_ text: String, at point: CGPoint, dark: Bool) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
        .foregroundColor: dark ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0, alpha: 0.7),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: point.x, y: point.y + 15)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

for (index, theme) in themes.enumerated() {
    let dark = theme == "Dark"
    let top = panelHeight * CGFloat(index)
    backdrop(CGRect(x: 0, y: top, width: panelWidth, height: panelHeight), dark: dark)
    label(dark ? "Deskset example skins — dark theme" : "Light theme", at: CGPoint(x: margin, y: top + margin - 8),
          dark: dark)
    for job in jobs where job.0 == theme {
        let item = job.1
        guard let image = NSImage(contentsOf: job.2),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("missing render for \(theme) \(item.file)")
            continue
        }
        let w = CGFloat(cg.width) / scale, h = CGFloat(cg.height) / scale
        let columnX = margin + (columnWidth + gap) * CGFloat(item.column)
        let rect = CGRect(x: columnX + (columnWidth - w) / 2, y: top + margin + 36 + item.y, width: w, height: h)
        // CGContext draws images upright in a y-up space: flip locally.
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }
}

try? fm.removeItem(at: work)
guard let composed = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]) else { exit(1) }
try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: output)
print("wrote \(output.path) \(width)x\(height)")
