import AppKit

public enum AppIcon {
    public static let symbolName = "network"

    private static let badgeSymbolName = "exclamationmark.circle.fill"
    private static let tint = NSColor(srgbRed: 0.20, green: 0.52, blue: 0.90, alpha: 1)

    public static func menuBar(attention: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard
            let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: "awsssh")?
                .withSymbolConfiguration(config)
        else { return NSImage() }
        base.isTemplate = true
        guard attention else { return base }

        let badgeConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        guard
            let badge = NSImage(systemSymbolName: badgeSymbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(badgeConfig)
        else { return base }

        let canvas = NSImage(size: NSSize(width: base.size.width + 3, height: base.size.height))
        canvas.lockFocus()
        defer { canvas.unlockFocus() }

        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)

        let badgeRect = NSRect(
            x: canvas.size.width - badge.size.width,
            y: 0,
            width: badge.size.width,
            height: badge.size.height)

        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.2, dy: -1.2)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        badge.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1)

        canvas.isTemplate = true
        canvas.accessibilityDescription = "awsssh, attention needed"
        return canvas
    }

    private static func render(size: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.56, weight: .medium)
        guard
            let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        else { return nil }

        let canvas = NSImage(size: NSSize(width: size, height: size))
        canvas.lockFocus()
        defer { canvas.unlockFocus() }

        let inset = size * 0.06
        let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let path = NSBezierPath(roundedRect: plate, xRadius: size * 0.22, yRadius: size * 0.22)
        tint.setFill()
        path.fill()

        let symbolSize = symbol.size
        let origin = NSPoint(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2)
        let tinted = NSImage(size: symbolSize)
        tinted.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: symbolSize).fill(using: .sourceOver)
        symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)

        return canvas
    }

    public static func png(size: CGFloat) -> Data? {
        guard
            let image = render(size: size),
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        rep.size = NSSize(width: size, height: size)
        return rep.representation(using: .png, properties: [:])
    }
}
