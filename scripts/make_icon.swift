// Renders the app icon into an .iconset folder: swift scripts/make_icon.swift <out.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    // macOS icon grid: ~10% margin around the rounded square.
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let radius = body.width * 0.225
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(starting: NSColor(calibratedRed: 1.00, green: 0.50, blue: 0.25, alpha: 1),
                              ending: NSColor(calibratedRed: 0.84, green: 0.14, blue: 0.29, alpha: 1))!
    gradient.draw(in: shape, angle: -60)

    // Soft top highlight.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let highlight = NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))!
    highlight.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Play triangle with rounded corners.
    let r = body.width * 0.25
    let cx = body.midX + r * 0.12
    let cy = body.midY
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: cx - r * 0.8, y: cy + r))
    triangle.line(to: NSPoint(x: cx - r * 0.8, y: cy - r))
    triangle.line(to: NSPoint(x: cx + r, y: cy))
    triangle.close()
    triangle.lineJoinStyle = .round
    triangle.lineWidth = r * 0.22
    NSColor.white.setFill()
    NSColor.white.setStroke()
    triangle.fill()
    triangle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try render(pixels).write(to: output.appendingPathComponent("icon_\(name).png"))
}
print("Icon rendered to \(output.path)")
