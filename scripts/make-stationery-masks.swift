// Draws the masks of the Stationery skins (DefaultSkins/Stationery/@Resources/Suite/Masks): white rounded rectangles
// on a clear background, at twice the size in points (the skins set W and H, so they draw at @2x). The corners are
// circular arcs, like a Shape meter's rounded Rectangle, so a masked picture and the card or tile around it share one
// outline. Original work, MIT licensed like the skins.
//
//     swift scripts/make-stationery-masks.swift
//
// Art36, Art64, Art138: artwork (album covers, app icons) at 36, 64 and 138 points. Art36 keeps the 8-point radius of
// small tiles; the others take the card's corner at the 16-point inset (26 − 16 = 10).
// Card-Small, Card-Medium, Card-Large: a whole card (170 × 170, 360 × 170, 360 × 360 points, radius 26), for a photo
// that fills the card.
import AppKit
import Foundation

let masks: [(name: String, width: Int, height: Int, radius: CGFloat)] = [
    ("Art36", 36, 36, 8),
    ("Art64", 64, 64, 10),
    ("Art138", 138, 138, 10),
    ("Card-Small", 170, 170, 26),
    ("Card-Medium", 360, 170, 26),
    ("Card-Large", 360, 360, 26),
]

let scriptURL = URL(fileURLWithPath: #filePath)
let folder = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("DefaultSkins/Stationery/@Resources/Suite/Masks", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

for mask in masks {
    let scale = 2
    let width = mask.width * scale, height = mask.height * scale
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("cannot make a bitmap for \(mask.name)")
    }
    context.setShouldAntialias(true)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    let radius = mask.radius * CGFloat(scale)
    context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                           cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("cannot encode \(mask.name)")
    }
    let url = folder.appendingPathComponent(mask.name + ".png")
    try png.write(to: url)
    print("\(mask.name).png  \(width) × \(height) px, radius \(Int(radius)) px")
}
