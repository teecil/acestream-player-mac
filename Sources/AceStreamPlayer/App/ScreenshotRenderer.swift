import AppKit

/// Renders the main window to PNG files in both languages and both appearances.
/// Captures our own view hierarchy (title bar buttons included), so it needs no screen
/// recording permission and works on a CI runner.
@MainActor
enum ScreenshotRenderer {
    static func run(window: NSWindow, model: AppModel, to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearances: [(name: String, appearance: NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]
        for (appearanceName, appearance) in appearances {
            window.appearance = NSAppearance(named: appearance)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil) // no focus ring in the picture
            for language in AppLanguage.allCases {
                L10n.current = language
                model.objectWillChange.send()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let file = directory.appendingPathComponent("screenshot-\(language.rawValue)-\(appearanceName).png")
                if let png = capture(window) {
                    try? png.write(to: file)
                    print("wrote \(file.path)")
                } else {
                    print("failed to capture \(file.lastPathComponent)")
                }
            }
        }
    }

    /// Draws the window's frame view at 2x and rounds the corners like a real macOS window.
    private static func capture(_ window: NSWindow) -> Data? {
        guard let frameView = window.contentView?.superview else { return nil }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        let size = frameView.bounds.size
        let scale: CGFloat = 2
        guard let raw = bitmap(size: size, scale: scale) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: raw)

        guard let rounded = bitmap(size: size, scale: scale) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rounded)
        let rect = NSRect(origin: .zero, size: size)
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).addClip()
        raw.draw(in: rect)
        if !window.isKeyWindow { paintTrafficLights(window, in: frameView) }
        NSColor.gray.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        border.lineWidth = 1
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rounded.representation(using: .png, properties: [:])
    }

    /// A CI runner can't make our window active, so AppKit draws grey title bar buttons.
    /// Paint close/minimize in their active colours (zoom stays grey: the window isn't resizable).
    private static func paintTrafficLights(_ window: NSWindow, in frameView: NSView) {
        let lights: [(NSWindow.ButtonType, NSColor)] = [
            (.closeButton, NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1)),
            (.miniaturizeButton, NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1)),
        ]
        for (type, color) in lights {
            guard let button = window.standardWindowButton(type) else { continue }
            var rect = button.convert(button.bounds, to: frameView)
            if frameView.isFlipped { rect.origin.y = frameView.bounds.height - rect.maxY }
            let diameter = min(rect.width, rect.height) - 2
            let circle = NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)
            let path = NSBezierPath(ovalIn: circle)
            color.setFill()
            path.fill()
            color.shadow(withLevel: 0.15)?.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    private static func bitmap(size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }
}
