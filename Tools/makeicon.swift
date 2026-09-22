// Draws the YOINK! app icon and writes Resources/AppIcon.icns.
// Not part of the app target - run with: swift Tools/makeicon.swift
import AppKit
import Foundation

let yellow = NSColor(srgbRed: 1.00, green: 0.84, blue: 0.09, alpha: 1)
let red = NSColor(srgbRed: 0.87, green: 0.13, blue: 0.11, alpha: 1)

func drawIcon(size: CGFloat) {
    let s = size / 1024.0
    func u(_ v: CGFloat) -> CGFloat { v * s }

    // Yellow rounded square
    let inset = u(76)
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: u(200), yRadius: u(200))
    yellow.setFill()
    shape.fill()

    // Bold red dashed outline, set in from the edge like a selection marquee.
    let marginBox = body.insetBy(dx: u(62), dy: u(62))
    let marquee = NSBezierPath(roundedRect: marginBox, xRadius: u(150), yRadius: u(150))
    marquee.lineWidth = u(30)
    marquee.setLineDash([u(86), u(52)], count: 2, phase: u(20))
    marquee.lineCapStyle = .butt
    red.setStroke()
    marquee.stroke()

    // YOINK! in a bold cartoon face, scaled to fit inside the marquee.
    let target = marginBox.width - u(90)
    var pointSize = u(300)
    var font = NSFont(name: "ChalkboardSE-Bold", size: pointSize)
        ?? NSFont.systemFont(ofSize: pointSize, weight: .black)
    let word = "YOINK!" as NSString
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: red]
    var measured = word.size(withAttributes: attrs)
    if measured.width > 0 {
        pointSize *= target / measured.width
        font = NSFont(name: "ChalkboardSE-Bold", size: pointSize)
            ?? NSFont.systemFont(ofSize: pointSize, weight: .black)
        attrs[.font] = font
        measured = word.size(withAttributes: attrs)
    }
    word.draw(at: NSPoint(x: (size - measured.width) / 2,
                          y: (size - measured.height) / 2 - u(10)),
              withAttributes: attrs)
}

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    try png(px).write(to: iconset.appendingPathComponent("\(name).png"))
}
try png(1024).write(to: root.appendingPathComponent("build/icon-preview.png"))
try png(128).write(to: root.appendingPathComponent("build/icon-small.png"))

let out = root.appendingPathComponent("Resources/AppIcon.icns")
try? FileManager.default.createDirectory(at: root.appendingPathComponent("Resources"),
                                         withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
