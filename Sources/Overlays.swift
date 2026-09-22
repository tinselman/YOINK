import AppKit

// MARK: - Dimming overlay

/// Darkens every screen except the chosen rectangle, which stays clear so the user
/// can keep working in the window. Click-through, so it never intercepts input.
final class DimOverlay {
    private var windows: [NSWindow] = []

    func show(hole: NSRect?) {
        hide()
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame,
                             styleMask: .borderless,
                             backing: .buffered,
                             defer: false,
                             screen: screen)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = Levels.dim
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = DimView(frame: NSRect(origin: .zero, size: screen.frame.size))
            if let hole {
                // Convert the hole into this screen's local coordinates.
                view.hole = NSRect(x: hole.minX - screen.frame.minX,
                                   y: hole.minY - screen.frame.minY,
                                   width: hole.width, height: hole.height)
            }
            w.contentView = view
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private final class DimView: NSView {
    var hole: NSRect?

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.55).setFill()
        dirtyRect.fill()
        guard let hole, hole.intersects(bounds) else { return }
        NSColor.clear.setFill()
        hole.fill(using: .copy)

        let border = NSBezierPath(rect: hole.insetBy(dx: -1, dy: -1))
        NSColor(srgbRed: 1, green: 0.90, blue: 0.30, alpha: 0.95).setStroke()
        border.lineWidth = 2
        border.stroke()
    }
}

// MARK: - Window picker

struct WindowCandidate {
    let id: CGWindowID
    let rect: NSRect       // AppKit coordinates
    let appName: String
    let title: String
}

enum PickerMode {
    case windows
    case dragSelect
}

/// A full-screen overlay. In `windows` mode, hovering highlights the window under
/// the pointer and clicking chooses it. In `dragSelect` mode the user draws a
/// rectangle anywhere and then reshapes it by its handles.
final class WindowPicker {
    private var window: NSWindow?
    private weak var view: PickerView?
    private var onPick: ((WindowCandidate) -> Void)?
    private var onCancel: (() -> Void)?

    /// Reports the drawn rectangle in screen coordinates, or nil once cleared.
    var onDragSelection: ((NSRect?) -> Void)?

    var mode: PickerMode = .windows {
        didSet { view?.mode = mode }
    }

    /// Marks the current choice so it stays highlighted while the user looks around.
    /// `area` is what will actually be recorded, which may be inset from the window.
    func markSelected(_ candidate: WindowCandidate?, showing area: NSRect? = nil) {
        view?.selected = candidate
        view?.selectedArea = area
    }

    func show(candidates: [WindowCandidate],
              onPick: @escaping (WindowCandidate) -> Void,
              onCancel: @escaping () -> Void) {
        // A rebuild of the list (say, after changing desktop) should not throw away
        // a rectangle the user has already drawn.
        let keptSelection = view?.selection
        hide()
        self.onPick = onPick
        self.onCancel = onCancel

        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let w = PickerWindow(contentRect: union,
                             styleMask: .borderless,
                             backing: .buffered,
                             defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = Levels.picker
        w.acceptsMouseMovedEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = PickerView(frame: NSRect(origin: .zero, size: union.size))
        view.originOffset = union.origin
        view.candidates = candidates
        view.mode = mode
        view.selection = keptSelection
        // Picking does not dismiss the overlay: the user keeps clicking from window
        // to window until they press GO.
        view.onPick = { [weak self] c in self?.onPick?(c) }
        view.onCancel = { [weak self] in self?.hide(); self?.onCancel?() }
        view.onDragSelection = { [weak self] r in self?.onDragSelection?(r) }
        w.contentView = view
        self.view = view

        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
    }

    func clearDragSelection() {
        view?.selection = nil
    }

    func hide() {
        view?.stopAnts()
        window?.orderOut(nil)
        window = nil
    }

    var isVisible: Bool { window != nil }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - The overlay's view

private final class PickerView: NSView {
    var candidates: [WindowCandidate] = []
    var originOffset: NSPoint = .zero
    var onPick: ((WindowCandidate) -> Void)?
    var onCancel: (() -> Void)?
    var onDragSelection: ((NSRect?) -> Void)?

    var selected: WindowCandidate? { didSet { needsDisplay = true } }
    var selectedArea: NSRect? { didSet { needsDisplay = true } }

    var mode: PickerMode = .windows {
        didSet {
            guard mode != oldValue else { return }
            hovered = nil
            mode == .dragSelect ? startAnts() : stopAnts()
            needsDisplay = true
        }
    }

    /// The drawn rectangle, in view coordinates.
    var selection: NSRect? {
        didSet {
            needsDisplay = true
            if mode == .dragSelect, selection != nil { startAnts() }
        }
    }

    private var hovered: WindowCandidate?
    private var tracking: NSTrackingArea?

    private enum Grip {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, inside
    }

    private var dragStart: NSPoint?
    private var activeGrip: Grip?
    private var grabOrigin: NSPoint?
    private var grabbedRect: NSRect?
    private var antPhase: CGFloat = 0
    private var antTimer: Timer?

    private static let gripSize: CGFloat = 10
    private static let snapDistance: CGFloat = 8
    private static let minimumSide: CGFloat = 20

    override var acceptsFirstResponder: Bool { true }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeAlways, .mouseMoved, .inVisibleRect],
                               owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func local(_ r: NSRect) -> NSRect {
        r.offsetBy(dx: -originOffset.x, dy: -originOffset.y)
    }

    private func screenRect(_ r: NSRect) -> NSRect {
        r.offsetBy(dx: originOffset.x, dy: originOffset.y)
    }

    private func candidate(at point: NSPoint) -> WindowCandidate? {
        // `candidates` is front-to-back, so the first hit is the topmost window.
        candidates.first { local($0.rect).contains(point) }
    }

    // MARK: Marching ants

    func startAnts() {
        guard antTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 14.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.antPhase += 2
            if self.antPhase >= 12 { self.antPhase = 0 }
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        antTimer = t
    }

    func stopAnts() {
        antTimer?.invalidate()
        antTimer = nil
    }

    deinit { antTimer?.invalidate() }

    // MARK: Snapping

    /// Every edge worth snapping to: each window's frame and its content area.
    private var snapLinesX: [CGFloat] {
        candidates.flatMap { c -> [CGFloat] in
            let f = local(c.rect), inner = local(c.rect.contentAreaOnly)
            return [f.minX, f.maxX, inner.minX, inner.maxX]
        }
    }

    private var snapLinesY: [CGFloat] {
        candidates.flatMap { c -> [CGFloat] in
            let f = local(c.rect), inner = local(c.rect.contentAreaOnly)
            return [f.minY, f.maxY, inner.minY, inner.maxY]
        }
    }

    private func snapped(_ value: CGFloat, to lines: [CGFloat]) -> CGFloat {
        var best = value
        var bestDelta = PickerView.snapDistance
        for line in lines where abs(line - value) < bestDelta {
            bestDelta = abs(line - value)
            best = line
        }
        return best
    }

    private func snapping(_ rect: NSRect, keepingSize: Bool) -> NSRect {
        let xs = snapLinesX, ys = snapLinesY
        if keepingSize {
            // Moving: take whichever edge snaps by the smaller amount.
            let leftShift = snapped(rect.minX, to: xs) - rect.minX
            let rightShift = snapped(rect.maxX, to: xs) - rect.maxX
            let dx = abs(leftShift) <= abs(rightShift) ? leftShift : rightShift
            let bottomShift = snapped(rect.minY, to: ys) - rect.minY
            let topShift = snapped(rect.maxY, to: ys) - rect.maxY
            let dy = abs(bottomShift) <= abs(topShift) ? bottomShift : topShift
            return rect.offsetBy(dx: dx, dy: dy)
        }
        let minX = snapped(rect.minX, to: xs), maxX = snapped(rect.maxX, to: xs)
        let minY = snapped(rect.minY, to: ys), maxY = snapped(rect.maxY, to: ys)
        return NSRect(x: minX, y: minY,
                      width: max(maxX - minX, PickerView.minimumSide),
                      height: max(maxY - minY, PickerView.minimumSide))
    }

    // MARK: Grips

    private func gripRects(for rect: NSRect) -> [(Grip, NSRect)] {
        let g = PickerView.gripSize
        func box(_ x: CGFloat, _ y: CGFloat) -> NSRect {
            NSRect(x: x - g / 2, y: y - g / 2, width: g, height: g)
        }
        return [
            (.bottomLeft, box(rect.minX, rect.minY)),
            (.bottom, box(rect.midX, rect.minY)),
            (.bottomRight, box(rect.maxX, rect.minY)),
            (.right, box(rect.maxX, rect.midY)),
            (.topRight, box(rect.maxX, rect.maxY)),
            (.top, box(rect.midX, rect.maxY)),
            (.topLeft, box(rect.minX, rect.maxY)),
            (.left, box(rect.minX, rect.midY)),
        ]
    }

    private func grip(at point: NSPoint, in rect: NSRect) -> Grip? {
        // A slightly generous target, so the handles are not fiddly to hit.
        gripRects(for: rect).first { $0.1.insetBy(dx: -4, dy: -4).contains(point) }?.0
    }

    private func resized(_ rect: NSRect, grip: Grip, by delta: NSPoint) -> NSRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch grip {
        case .topLeft:     minX += delta.x; maxY += delta.y
        case .top:         maxY += delta.y
        case .topRight:    maxX += delta.x; maxY += delta.y
        case .right:       maxX += delta.x
        case .bottomRight: maxX += delta.x; minY += delta.y
        case .bottom:      minY += delta.y
        case .bottomLeft:  minX += delta.x; minY += delta.y
        case .left:        minX += delta.x
        case .inside:      return rect.offsetBy(dx: delta.x, dy: delta.y)
        }
        return NSRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: max(abs(maxX - minX), PickerView.minimumSide),
                      height: max(abs(maxY - minY), PickerView.minimumSide))
    }

    private func cursor(for grip: Grip?) -> NSCursor {
        switch grip {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .inside: return .openHand
        case .some: return .crosshair          // corners have no stock diagonal cursor
        case nil: return .crosshair
        }
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        guard mode == .windows else {
            if let sel = selection {
                let g = grip(at: p, in: sel) ?? (sel.contains(p) ? .inside : nil)
                cursor(for: g).set()
            } else {
                NSCursor.crosshair.set()
            }
            return
        }

        let hit = candidate(at: p)
        if hit?.id != hovered?.id {
            hovered = hit
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        guard mode == .dragSelect else {
            if let hit = candidate(at: p) ?? hovered { onPick?(hit) }
            return
        }

        if let sel = selection {
            if let g = grip(at: p, in: sel) {
                activeGrip = g
            } else if sel.contains(p) {
                activeGrip = .inside
            } else {
                // Starting outside the rectangle discards it and draws a new one.
                selection = nil
                dragStart = p
                return
            }
            grabOrigin = p
            grabbedRect = sel
            return
        }
        dragStart = p
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .dragSelect else { return }
        let p = convert(event.locationInWindow, from: nil)

        if let start = dragStart {
            let raw = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                             width: abs(p.x - start.x), height: abs(p.y - start.y))
            selection = snapping(raw, keepingSize: false)
        } else if let g = activeGrip, let base = grabbedRect, let origin = grabOrigin {
            let delta = NSPoint(x: p.x - origin.x, y: p.y - origin.y)
            selection = snapping(resized(base, grip: g, by: delta), keepingSize: g == .inside)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .dragSelect else { return }
        dragStart = nil
        activeGrip = nil
        grabOrigin = nil
        grabbedRect = nil

        if let sel = selection, sel.width >= PickerView.minimumSide, sel.height >= PickerView.minimumSide {
            onDragSelection?(screenRect(sel))
        } else {
            selection = nil
            onDragSelection?(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.55).setFill()
        dirtyRect.fill()

        mode == .dragSelect ? drawDragSelect() : drawWindowPicking()

        let hint: String
        switch mode {
        case .dragSelect:
            hint = selection == nil
                ? "Drag out the area you want to record"
                : "Drag the handles to adjust   ·   drag inside to move   ·   press GO to record"
        case .windows:
            hint = selected == nil
                ? "Click any window to choose it"
                : "Click another window to change it   ·   press GO to record"
        }
        drawChip(hint, centeredAt: NSPoint(x: bounds.midX, y: bounds.maxY - 72), emphasis: true)
    }

    private func drawWindowPicking() {
        // The chosen area stays clear and strongly outlined. It is the recorded
        // region, not necessarily the whole window.
        if let selected {
            let r = local(selectedArea ?? selected.rect)
            NSColor.clear.setFill()
            r.fill(using: .copy)
            let border = NSBezierPath(rect: r.insetBy(dx: -1.5, dy: -1.5))
            NSColor(srgbRed: 1, green: 0.90, blue: 0.30, alpha: 1).setStroke()
            border.lineWidth = 3
            border.stroke()
        }

        // Whatever is under the pointer gets a lighter preview outline.
        if let hovered, hovered.id != selected?.id {
            let r = local(hovered.rect)
            NSColor(white: 1, alpha: 0.10).setFill()
            r.fill()
            let border = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
            NSColor(white: 1, alpha: 0.75).setStroke()
            border.lineWidth = 2
            border.stroke()

            let label = hovered.title.isEmpty ? hovered.appName : "\(hovered.appName) — \(hovered.title)"
            drawChip(label, centeredAt: NSPoint(x: r.midX, y: max(r.minY - 26, 20)))
        }
    }

    private func drawDragSelect() {
        guard let sel = selection else { return }

        NSColor.clear.setFill()
        sel.fill(using: .copy)

        // Marching ants: a dark line with a white dashed line crawling along it.
        let base = NSBezierPath(rect: sel)
        base.lineWidth = 1.5
        NSColor(white: 0, alpha: 0.85).setStroke()
        base.stroke()

        let ants = NSBezierPath(rect: sel)
        ants.lineWidth = 1.5
        ants.setLineDash([6, 6], count: 2, phase: antPhase)
        NSColor.white.setStroke()
        ants.stroke()

        for (_, box) in gripRects(for: sel) {
            let handle = NSBezierPath(rect: box)
            NSColor.white.setFill()
            handle.fill()
            NSColor(white: 0, alpha: 0.8).setStroke()
            handle.lineWidth = 1
            handle.stroke()
        }

        drawChip("\(Int(sel.width)) × \(Int(sel.height))",
                 centeredAt: NSPoint(x: sel.midX, y: max(sel.minY - 26, 20)))
    }

    private func drawChip(_ text: String, centeredAt point: NSPoint, emphasis: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: emphasis ? 15 : 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        let box = NSRect(x: point.x - size.width / 2 - 12, y: point.y - size.height / 2 - 7,
                         width: size.width + 24, height: size.height + 14)
        let bg = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
        NSColor(white: 0.08, alpha: 0.92).setFill()
        bg.fill()
        NSColor(white: 1, alpha: 0.25).setStroke()
        bg.lineWidth = 1
        bg.stroke()
        s.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), withAttributes: attrs)
    }
}
