import AppKit

/// A ~1 inch wide reel-to-reel recorder drawn as white line art with no backing
/// panel, so it sits directly on whatever is behind it. The reels turn only while
/// a recording is running; the rest of the time it is simply there, still.
final class ReelView: NSView {
    static let size = NSSize(width: 74, height: 48)

    private var angle: CGFloat = 0
    private var timer: Timer?

    var isSpinning: Bool = false {
        didSet {
            guard isSpinning != oldValue else { return }
            isSpinning ? start() : stop()
        }
    }

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { ReelView.size }

    private func start() {
        let t = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.angle -= .pi / 18          // ~40 rpm
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds

        // A soft dark shadow keeps the white line art readable over pale windows.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()

        let leftHub = CGPoint(x: b.midX - 16, y: b.midY + 5)
        let rightHub = CGPoint(x: b.midX + 16, y: b.midY + 5)
        let radius: CGFloat = 13

        // Tape: off the left reel, down across the head, back up to the right reel.
        let tape = NSBezierPath()
        tape.move(to: CGPoint(x: leftHub.x - radius, y: leftHub.y))
        tape.curve(to: CGPoint(x: b.midX, y: b.minY + 8),
                   controlPoint1: CGPoint(x: leftHub.x - radius, y: leftHub.y - 11),
                   controlPoint2: CGPoint(x: b.midX - 11, y: b.minY + 8))
        tape.curve(to: CGPoint(x: rightHub.x + radius, y: rightHub.y),
                   controlPoint1: CGPoint(x: b.midX + 11, y: b.minY + 8),
                   controlPoint2: CGPoint(x: rightHub.x + radius, y: rightHub.y - 11))
        NSColor.white.setStroke()
        tape.lineWidth = 1.4
        tape.stroke()

        // Play head
        let head = NSBezierPath(roundedRect: NSRect(x: b.midX - 4.5, y: b.minY + 3, width: 9, height: 7),
                                xRadius: 1.5, yRadius: 1.5)
        head.lineWidth = 1.4
        head.stroke()

        drawReel(ctx, center: leftHub, radius: radius, fillRatio: 0.74)
        drawReel(ctx, center: rightHub, radius: radius, fillRatio: 0.46)

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawReel(_ ctx: CGContext, center: CGPoint, radius: CGFloat, fillRatio: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)

        // Wound tape, suggested with a translucent white disc.
        let tapeR = radius * fillRatio
        NSColor(white: 1, alpha: 0.22).setFill()
        NSBezierPath(ovalIn: NSRect(x: -tapeR, y: -tapeR, width: tapeR * 2, height: tapeR * 2)).fill()

        NSColor.white.setStroke()

        let rim = NSBezierPath(ovalIn: NSRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        rim.lineWidth = 1.6
        rim.stroke()

        let spokes = NSBezierPath()
        spokes.lineWidth = 2
        spokes.lineCapStyle = .round
        for i in 0..<3 {
            let a = CGFloat(i) * .pi / 3.0
            let p = CGPoint(x: cos(a) * (radius - 2), y: sin(a) * (radius - 2))
            spokes.move(to: CGPoint(x: -p.x, y: -p.y))
            spokes.line(to: p)
        }
        spokes.stroke()

        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: -3, y: -3, width: 6, height: 6)).fill()

        ctx.restoreGState()
    }

    deinit { timer?.invalidate() }
}
