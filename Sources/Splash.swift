import AppKit

/// The opening screen. It also doubles as the app's only status surface while
/// macOS is being asked for Screen Recording access, so the app is never sitting
/// there silently with nothing on screen.
final class Splash {
    private let window: NSPanel
    private let status = NSTextField(labelWithString: "")

    private static let yellow = NSColor(srgbRed: 1.00, green: 0.84, blue: 0.09, alpha: 1)
    private static let red = NSColor(srgbRed: 0.87, green: 0.13, blue: 0.11, alpha: 1)
    private static let ink = NSColor(srgbRed: 0.35, green: 0.12, blue: 0.06, alpha: 1)

    private static let credits = """
        A Screen Capture Utility
        by
        Robyn Miller

        Find out more about Robyn
        and his creations
        at:
        """

    private static let siteTitle = "robynmiller.net"
    private static let siteURL = URL(string: "https://robynmiller.net")!

    init() {
        let size = NSSize(width: 420, height: 440)
        window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered,
                         defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = Levels.controls
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false

        let card = SplashCard(frame: NSRect(origin: .zero, size: size))
        window.contentView = card

        let cartoon = NSFont(name: "ChalkboardSE-Bold", size: 58)
            ?? NSFont.systemFont(ofSize: 58, weight: .black)
        let title = NSTextField(labelWithString: "YOINK!")
        title.font = cartoon
        title.textColor = Splash.red
        title.alignment = .center
        title.frame = NSRect(x: 0, y: size.height - 128, width: size.width, height: 70)
        card.addSubview(title)

        let body = NSTextField(wrappingLabelWithString: Splash.credits)
        body.font = NSFont(name: "ChalkboardSE-Regular", size: 16)
            ?? NSFont.systemFont(ofSize: 16)
        body.textColor = Splash.ink
        body.alignment = .center
        body.isSelectable = false
        body.frame = NSRect(x: 30, y: 118, width: size.width - 60, height: size.height - 258)
        card.addSubview(body)

        let link = LinkLabel(frame: NSRect(x: 40, y: 86, width: size.width - 80, height: 28))
        link.title = Splash.siteTitle
        link.font = NSFont(name: "ChalkboardSE-Bold", size: 17) ?? NSFont.boldSystemFont(ofSize: 17)
        link.color = Splash.red
        link.onClick = { NSWorkspace.shared.open(Splash.siteURL) }
        card.addSubview(link)

        status.font = NSFont(name: "ChalkboardSE-Regular", size: 13)
            ?? NSFont.systemFont(ofSize: 13)
        status.textColor = Splash.ink.withAlphaComponent(0.75)
        status.alignment = .center
        status.frame = NSRect(x: 20, y: 46, width: size.width - 40, height: 34)
        status.maximumNumberOfLines = 2
        card.addSubview(status)

        card.onClick = { [weak self] in self?.hide() }
    }

    func show(status text: String = "") {
        status.stringValue = text
        if let screen = NSScreen.main {
            let f = window.frame
            window.setFrameOrigin(NSPoint(x: screen.frame.midX - f.width / 2,
                                          y: screen.frame.midY - f.height / 2 + 40))
        }
        window.orderFrontRegardless()
    }

    func setStatus(_ text: String) {
        status.stringValue = text
    }

    func hide() {
        window.orderOut(nil)
    }

    var isVisible: Bool { window.isVisible }
}

/// A clickable, underlined line of text that opens a URL. Built by hand rather
/// than with an NSTextField link attribute, because the splash panel is
/// non-activating and swallows clicks for dismissal.
private final class LinkLabel: NSView {
    var title = ""
    var font = NSFont.boldSystemFont(ofSize: 17)
    var color = NSColor.systemRed
    var onClick: (() -> Void)?

    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                               owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: hovering ? color.blended(withFraction: 0.3, of: .black) ?? color : color,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .paragraphStyle: style,
        ]
        let text = title as NSString
        let h = text.size(withAttributes: attrs).height
        text.draw(in: NSRect(x: 0, y: bounds.midY - h / 2, width: bounds.width, height: h),
                  withAttributes: attrs)
    }
}

/// Yellow card with the dashed red marquee from the icon.
private final class SplashCard: NSView {
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 6, dy: 6)
        let shape = NSBezierPath(roundedRect: body, xRadius: 26, yRadius: 26)
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.09, alpha: 1).setFill()
        shape.fill()

        let marquee = NSBezierPath(roundedRect: body.insetBy(dx: 14, dy: 14), xRadius: 18, yRadius: 18)
        marquee.lineWidth = 6
        marquee.setLineDash([18, 11], count: 2, phase: 4)
        NSColor(srgbRed: 0.87, green: 0.13, blue: 0.11, alpha: 1).setStroke()
        marquee.stroke()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
