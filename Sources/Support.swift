import AppKit

// MARK: - Coordinate conversion
// ScreenCaptureKit / CoreGraphics use a top-left origin on the primary display.
// AppKit uses a bottom-left origin. The conversion is its own inverse.
enum Coord {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }
    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

// MARK: - Preferences

enum RecordMode: String {
    case window
    case fullscreen
}

/// What a window recording covers, or whether the user draws the area themselves.
enum SelectionMode: String, CaseIterable {
    case noBorder
    case border
    case dragSelect

    var title: String {
        switch self {
        case .noBorder: return "NO BORDER"
        case .border: return "BORDER"
        case .dragSelect: return "DRAG SELECT"
        }
    }
}

final class Prefs {
    static let shared = Prefs()
    private let defaults = UserDefaults.standard

    var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: "saveDirectory") {
                return URL(fileURLWithPath: path)
            }
            return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set { defaults.set(newValue.path, forKey: "saveDirectory") }
    }

    var mode: RecordMode {
        get { RecordMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .window }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }

    /// Defaults to trimming the chrome: most people want the window's contents.
    var selectionMode: SelectionMode {
        get { SelectionMode(rawValue: defaults.string(forKey: "selectionMode") ?? "") ?? .noBorder }
        set { defaults.set(newValue.rawValue, forKey: "selectionMode") }
    }

    func newOutputURL() -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screen Recording \(fmt.string(from: Date())).mov"
        return saveDirectory.appendingPathComponent(name)
    }
}

// MARK: - Palette

enum Palette {
    static let go = NSColor(srgbRed: 0.90, green: 0.19, blue: 0.16, alpha: 1)
    static let goDown = NSColor(srgbRed: 0.74, green: 0.13, blue: 0.11, alpha: 1)
    static let stop = NSColor(srgbRed: 0.14, green: 0.72, blue: 0.33, alpha: 1)
    static let stopDown = NSColor(srgbRed: 0.09, green: 0.56, blue: 0.25, alpha: 1)
    static let off = NSColor(srgbRed: 0.27, green: 0.28, blue: 0.31, alpha: 1)
    static let offDown = NSColor(srgbRed: 0.18, green: 0.19, blue: 0.21, alpha: 1)
    static let segmentOn = NSColor(srgbRed: 0.87, green: 0.13, blue: 0.11, alpha: 1)
    static let segmentOff = NSColor(white: 0.16, alpha: 0.92)
}

// MARK: - What a window recording actually covers

extension NSRect {
    /// Trims a window's title bar and its outer edge, leaving the content area.
    /// macOS gives us only the full frame, so the title bar height comes from the
    /// standard metric for a titled window rather than from the window itself.
    var contentAreaOnly: NSRect {
        let content = NSWindow.contentRect(forFrameRect: self,
                                           styleMask: [.titled, .closable, .miniaturizable, .resizable])
        let trimmed = content.insetBy(dx: 1, dy: 1)
        return trimmed.width >= 40 && trimmed.height >= 40 ? trimmed : self
    }
}

// MARK: - Overlay window levels
// Above every ordinary app window so the dimming actually dims.

enum Levels {
    static let dim = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    static let picker = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
    static let controls = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 2)
}
