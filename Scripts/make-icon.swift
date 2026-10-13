// Draws the MeshKit app icon: a mesh of linked nodes around a radio hub, on a gradient tile.
//
//   swift Scripts/make-icon.swift Resources         # writes Resources/AppIcon.icns and Resources/icon-readme.png
//
// Needs macOS (CoreGraphics, ImageIO, and the `iconutil` / `sips` tools).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 188, cornerHeight: 188, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x14214F)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [rgb(0x1A2466), rgb(0x1C5C9E), rgb(0x16B3A8)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: tile.minX + 120, y: tile.maxY - 60), startRadius: 0,
                       endCenter: CGPoint(x: tile.minX + 120, y: tile.maxY - 60), endRadius: 620, options: [])

let hub = CGPoint(x: 512, y: 512)
let nodeRadius = 262.0
let nodes: [CGPoint] = (0..<6).map { i in
    let angle = Double.pi / 6 + Double(i) * Double.pi / 3
    return CGPoint(x: hub.x + CGFloat(cos(angle) * nodeRadius), y: hub.y + CGFloat(sin(angle) * nodeRadius))
}

for (i, radius) in [112.0, 178.0, 244.0, 310.0].enumerated() {
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.20 - Double(i) * 0.04))
    ctx.setLineWidth(7)
    ctx.strokeEllipse(in: CGRect(x: hub.x - radius, y: hub.y - radius, width: radius * 2, height: radius * 2))
}

ctx.setLineCap(.round)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.42))
ctx.setLineWidth(9)
for i in 0..<6 { ctx.move(to: nodes[i]); ctx.addLine(to: nodes[(i + 1) % 6]); ctx.strokePath() }
ctx.setStrokeColor(rgb(0xFFFFFF, 0.78))
ctx.setLineWidth(13)
for n in nodes { ctx.move(to: hub); ctx.addLine(to: n); ctx.strokePath() }

for n in nodes {
    ctx.setFillColor(rgb(0xFFFFFF, 0.18)); ctx.fillEllipse(in: CGRect(x: n.x - 46, y: n.y - 46, width: 92, height: 92))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: n.x - 29, y: n.y - 29, width: 58, height: 58))
}

ctx.setFillColor(rgb(0xFFFFFF, 0.24)); ctx.fillEllipse(in: CGRect(x: hub.x - 100, y: hub.y - 100, width: 200, height: 200))
ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: hub.x - 72, y: hub.y - 72, width: 144, height: 144))
ctx.setFillColor(rgb(0x1A2466)); ctx.fillEllipse(in: CGRect(x: hub.x - 28, y: hub.y - 28, width: 56, height: 56))
ctx.restoreGState()

ctx.addPath(tilePath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.18)); ctx.setLineWidth(3); ctx.strokePath()

guard let image = ctx.makeImage() else { fatalError("no image") }

func writePNG(_ img: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("no destination") }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let png = FileManager.default.temporaryDirectory.appendingPathComponent("MeshKit-icon-1024.png")
writePNG(image, to: png)

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    let out = iconset.appendingPathComponent("\(name).png")
    let sips = Process()
    sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    sips.arguments = ["-z", "\(px)", "\(px)", png.path, "--out", out.path]
    sips.standardOutput = FileHandle.nullDevice
    try sips.run(); sips.waitUntilExit()
}
let util = Process()
util.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
util.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try util.run(); util.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
let readme = Process()
readme.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
readme.arguments = ["-z", "256", "256", png.path, "--out", outDir.appendingPathComponent("icon-readme.png").path]
readme.standardOutput = FileHandle.nullDevice
try readme.run(); readme.waitUntilExit()
try? FileManager.default.removeItem(at: png)
print("wrote AppIcon.icns and icon-readme.png in \(outDir.path)")
