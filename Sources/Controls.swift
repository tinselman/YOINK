import AppKit

// MARK: - Button

final class PillButton: NSView {
    static let size = NSSize(width: 132, height: 44)

    var title: String = "GO" { didSet { needsDisplay = true } }
    var baseColor: NSColor = Palette.go { didSet { needsDisplay = true } }
    var downColor: NSColor = Palette.goDown
    var onClick: (() -> Void)?

    private var isDown = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { PillButton.size }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        (isDown ? downColor : baseColor).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 1, alpha: 0.35).setStroke()
        path.lineWidth = 1
        path.stroke()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .heavy),
            .foregroundColor: NSColor.white,
            .kern: 1.8,
            .paragraphStyle: style,
        ]
        let text = title as NSString
        let h = text.size(withAttributes: attrs).height
        text.draw(in: NSRect(x: 0, y: r.midY - h / 2, width: bounds.width, height: h), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        isDown = true
        // Track until mouse-up so a drag off the button cancels the press.
        while true {
            guard let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            let inside = bounds.contains(convert(e.locationInWindow, from: nil))
            if e.type == .leftMouseDragged {
                isDown = inside
            } else {
                isDown = false
                if inside { onClick?() }
                break
            }
        }
    }
}

// MARK: - Two-way radio switch

/// A pair of mutually exclusive options drawn as one pill, e.g. NO BORDER / BORDER.
final class SegmentedToggle: NSView {
    static let size = NSSize(width: 340, height: 32)

    var titles: [String] = [] { didSet { needsDisplay = true } }
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var onChange: ((Int) -> Void)?

    override var intrinsicContentSize: NSSize { SegmentedToggle.size }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !titles.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil)
        let index = min(titles.count - 1, max(0, Int(p.x / (bounds.width / CGFloat(titles.count)))))
        guard index != selectedIndex else { return }
        selectedIndex = index
        onChange?(index)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let outline = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.4)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        Palette.segmentOff.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Selected segment
        let segment = r.width / CGFloat(max(titles.count, 1))
        let chosen = NSRect(x: r.minX + segment * CGFloat(selectedIndex), y: r.minY,
                            width: segment, height: r.height)
        NSGraphicsContext.saveGraphicsState()
        outline.setClip()
        Palette.segmentOn.setFill()
        NSBezierPath(roundedRect: chosen.insetBy(dx: 2, dy: 2),
                     xRadius: (r.height - 4) / 2, yRadius: (r.height - 4) / 2).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 1, alpha: 0.28).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        for (i, title) in titles.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
                .foregroundColor: i == selectedIndex ? NSColor.white : NSColor(white: 1, alpha: 0.55),
                .kern: 0.6,
                .paragraphStyle: style,
            ]
            let text = title as NSString
            let h = text.size(withAttributes: attrs).height
            let cell = NSRect(x: r.minX + segment * CGFloat(i), y: r.midY - h / 2,
                              width: segment, height: h)
            text.draw(in: cell, withAttributes: attrs)
        }
    }
}

// MARK: - Floating control panel

/// GO and OFF sit side by side just outside the chosen window, with the
/// reel-to-reel directly beneath them. GO becomes STOP while recording; the
/// buttons never move between those states.
final class ControlPanel {
    private let panel: NSPanel
    private let goButton = PillButton()
    private let offButton = PillButton()
    private let borderToggle = SegmentedToggle()
    private let reel = ReelView()

    static let gap: CGFloat = 14
    static let reelGap: CGFloat = 10
    static let buttonGap: CGFloat = 12
    static let toggleGap: CGFloat = 8
    static var panelSize: NSSize {
        NSSize(width: max(SegmentedToggle.size.width, PillButton.size.width * 2 + buttonGap),
               height: SegmentedToggle.size.height + toggleGap
                     + PillButton.size.height + reelGap + ReelView.size.height)
    }

    var onGo: (() -> Void)? {
        get { goButton.onClick }
        set { goButton.onClick = newValue }
    }

    var onOff: (() -> Void)? {
        get { offButton.onClick }
        set { offButton.onClick = newValue }
    }

    /// Reports the mode the user picked from the switch.
    var onModeChange: ((SelectionMode) -> Void)?

    func setSelectionMode(_ mode: SelectionMode) {
        borderToggle.selectedIndex = SelectionMode.allCases.firstIndex(of: mode) ?? 0
    }

    init() {
        let size = ControlPanel.panelSize
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Levels.controls
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        let content = NSView(frame: NSRect(origin: .zero, size: size))

        borderToggle.frame = NSRect(x: (size.width - SegmentedToggle.size.width) / 2,
                                    y: size.height - SegmentedToggle.size.height,
                                    width: SegmentedToggle.size.width,
                                    height: SegmentedToggle.size.height)
        borderToggle.titles = SelectionMode.allCases.map(\.title)
        borderToggle.onChange = { [weak self] index in
            self?.onModeChange?(SelectionMode.allCases[index])
        }
        content.addSubview(borderToggle)

        let buttonY = size.height - SegmentedToggle.size.height - ControlPanel.toggleGap
                    - PillButton.size.height
        let rowWidth = PillButton.size.width * 2 + ControlPanel.buttonGap
        let rowX = (size.width - rowWidth) / 2
        goButton.frame = NSRect(x: rowX, y: buttonY,
                                width: PillButton.size.width, height: PillButton.size.height)
        offButton.frame = NSRect(x: rowX + PillButton.size.width + ControlPanel.buttonGap, y: buttonY,
                                 width: PillButton.size.width, height: PillButton.size.height)
        offButton.title = "OFF"
        offButton.baseColor = Palette.off
        offButton.downColor = Palette.offDown

        reel.frame = NSRect(x: (size.width - ReelView.size.width) / 2,
                            y: buttonY - ControlPanel.reelGap - ReelView.size.height,
                            width: ReelView.size.width, height: ReelView.size.height)

        content.addSubview(goButton)
        content.addSubview(offButton)
        content.addSubview(reel)
        panel.contentView = content
    }

    func showRecording(_ recording: Bool) {
        goButton.title = recording ? "STOP" : "GO"
        goButton.baseColor = recording ? Palette.stop : Palette.go
        goButton.downColor = recording ? Palette.stopDown : Palette.goDown
        reel.isSpinning = recording
    }

    /// Places the panel just outside `target`, preferring below. Falls back to above
    /// when there is no room, keeping the reel clear of the recorded area either way.
    func place(around target: NSRect, on screen: NSScreen) {
        let size = ControlPanel.panelSize
        let bounds = screen.frame
        let x = min(max(target.midX - size.width / 2, bounds.minX + 8), bounds.maxX - size.width - 8)

        let below = target.minY - ControlPanel.gap - size.height
        let above = target.maxY + ControlPanel.gap
        var y: CGFloat
        if below >= bounds.minY + 8 {
            y = below
        } else if above + size.height <= bounds.maxY - 8 {
            y = above
        } else {
            y = max(bounds.minY + 8, min(below, bounds.maxY - size.height - 8))
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// Fullscreen mode: hovers over the recorded image, bottom centre.
    func placeForFullscreen(on screen: NSScreen) {
        let size = ControlPanel.panelSize
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 28,
                              width: size.width, height: size.height), display: true)
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
}
