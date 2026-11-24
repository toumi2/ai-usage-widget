import AppKit

@MainActor
enum StatusBarIcon {
    static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            NSColor.black.set()
            for (y, fillWidth) in [(9.0, 12.0), (2.0, 7.0)] {
                let track = NSBezierPath(
                    roundedRect: NSRect(x: 1.5, y: y, width: 17, height: 4.5),
                    xRadius: 2.25,
                    yRadius: 2.25
                )
                track.lineWidth = 1
                track.stroke()

                NSBezierPath(
                    roundedRect: NSRect(x: 1.5, y: y, width: fillWidth, height: 4.5),
                    xRadius: 2.25,
                    yRadius: 2.25
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AI Usage"
        return image
    }
}
