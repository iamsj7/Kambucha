import AppKit
import KambuchaCore

extension OverallStatus {
    /// What's cut out of the bottle. The status has to show in the menu bar, and the bottle alone can't say it.
    var menuBarCutout: String {
        switch self {
        case .uploading: "arrow.up"
        case .held, .paused: "pause.fill"
        case .attention, .waitingForDownload, .notAccepted: "exclamationmark"
        case .notConfigured: "plus"
        case .backedUp, .running, .unfinished, .driveNotConnected: "arrow.triangle.2.circlepath"
        }
    }
}

/// The tilted bottle, solid, as thin lines clog at this size. A template, so the system colours it for the menu bar.
enum MenuBarIcon {
    private static let side: CGFloat = 18
    private static let tilt: CGFloat = 20
    /// Where the cut-out sits: the middle of the bottle's body, on a 100-point grid.
    private static let centre = NSPoint(x: 43.2, y: 68.8)

    static func image(for status: OverallStatus) -> NSImage {
        let cutout = status.menuBarCutout
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            NSGraphicsContext.current?.cgContext.saveGState()
            let scale = side / 100
            var shape = AffineTransform(scale: scale)
            shape.translate(x: 50, y: 50)
            shape.rotate(byDegrees: tilt)
            shape.translate(x: -50, y: -50)
            let bottle = path()
            bottle.transform(using: shape)
            NSColor.black.setFill()
            bottle.fill()
            NSGraphicsContext.current?.cgContext.restoreGState()

            let weight = NSImage.SymbolConfiguration(pointSize: 5.8, weight: .black)
            guard let symbol = NSImage(systemSymbolName: cutout, accessibilityDescription: nil)?.withSymbolConfiguration(weight) else { return true }
            let size = symbol.size
            let rect = NSRect(x: centre.x * scale - size.width / 2, y: centre.y * scale - size.height / 2, width: size.width, height: size.height)
            symbol.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func path() -> NSBezierPath {
        let p = NSBezierPath()
        func curve(_ to: (CGFloat, CGFloat), _ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) {
            p.curve(to: NSPoint(x: to.0, y: to.1), controlPoint1: NSPoint(x: a.0, y: a.1), controlPoint2: NSPoint(x: b.0, y: b.1))
        }
        func line(_ x: CGFloat, _ y: CGFloat) { p.line(to: NSPoint(x: x, y: y)) }
        p.move(to: NSPoint(x: 43, y: 27))
        line(43, 19); line(40, 19); line(40, 8)
        curve((43, 5), (40, 6), (41, 5))
        line(57, 5)
        curve((60, 8), (59, 5), (60, 6))
        line(60, 19); line(57, 19); line(57, 27)
        curve((75, 54), (57, 37), (75, 40))
        line(75, 85)
        curve((62, 97), (75, 92), (69, 97))
        line(38, 97)
        curve((25, 85), (31, 97), (25, 92))
        line(25, 54)
        curve((43, 27), (25, 40), (43, 37))
        p.close()
        return p
    }
}
