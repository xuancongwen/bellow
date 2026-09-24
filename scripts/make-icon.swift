// Renders the BellowFlow app icon: the menu bar's waveform symbol on a warm rounded square
// laid out on Apple's 1024-point icon grid. Writes an .iconset directory; the build turns it
// into AppIcon.icns with iconutil.
//   swift scripts/make-icon.swift Resources/AppIcon.iconset
// With --favicon it writes the site's favicons instead: the tile fills the whole canvas
// (no grid margin or drop shadow), which is how browser tabs and home screens expect it.
//   swift scripts/make-icon.swift site --favicon
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let favicon = CommandLine.arguments.contains("--favicon")
if !favicon { try? FileManager.default.removeItem(at: output) }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ canvas: CGFloat, tight: Bool = false) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    // Apple's macOS icon grid: the tile fills 824/1024 of the canvas with ~22.5% corner radius.
    let inset = tight ? 0 : canvas * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    let radius = tile.width * 0.225
    let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    // Soft shadow under the tile, as the system icons have (not for favicons, which have no margin).
    context.saveGState()
    if !tight { context.setShadow(offset: CGSize(width: 0, height: -canvas * 0.01), blur: canvas * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor) }
    context.addPath(path); context.setFillColor(NSColor(red: 0.71, green: 0.28, blue: 0.12, alpha: 1).cgColor); context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(path); context.clip()
    let colors = [NSColor(red: 0.96, green: 0.58, blue: 0.40, alpha: 1).cgColor, NSColor(red: 0.71, green: 0.28, blue: 0.12, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
    // Subtle highlight along the top edge.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sheen, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.midY), options: [])
    context.restoreGState()
    // The waveform, same symbol as the menu bar item.
    let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: tile.width * 0.52, weight: .medium))!
    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect); NSColor.white.set(); rect.fill(using: .sourceAtop); return true
    }
    let size = tinted.size
    let scale = min(tile.width * 0.62 / size.width, tile.height * 0.5 / size.height)
    let drawn = CGSize(width: size.width * scale, height: size.height * scale)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -canvas * 0.006), blur: canvas * 0.012, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    tinted.draw(in: CGRect(x: tile.midX - drawn.width / 2, y: tile.midY - drawn.height / 2, width: drawn.width, height: drawn.height), from: .zero, operation: .sourceOver, fraction: 1)
    context.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

if favicon {
    for (name, size) in [("favicon-32.png", 32), ("favicon-192.png", 192), ("apple-touch-icon.png", 180), ("favicon-512.png", 512)] {
        try render(CGFloat(size), tight: true).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
    print("Wrote favicons to \(output.path)"); exit(0)
}
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let rep = render(CGFloat(points * scale))
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
print("Wrote \(output.path)")
