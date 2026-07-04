import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "Assets/dmg-background.png"
let size = NSSize(width: 560, height: 320)
let image = NSImage(size: size)

image.lockFocus()

NSColor(red: 0.055, green: 0.059, blue: 0.067, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

let gradient = NSGradient(colors: [
    NSColor(red: 0.11, green: 0.32, blue: 0.58, alpha: 0.28),
    NSColor(red: 0.95, green: 0.35, blue: 0.22, alpha: 0.16),
    NSColor.clear
])!
gradient.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height), angle: 18)

let title = "Drag to Applications"
let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.9)
]
let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.46)
]

title.draw(at: NSPoint(x: 174, y: 238), withAttributes: titleAttributes)
"Install Music Visualizer".draw(at: NSPoint(x: 196, y: 216), withAttributes: subtitleAttributes)

let arrowPath = NSBezierPath()
arrowPath.move(to: NSPoint(x: 215, y: 142))
arrowPath.curve(
    to: NSPoint(x: 342, y: 142),
    controlPoint1: NSPoint(x: 255, y: 176),
    controlPoint2: NSPoint(x: 306, y: 176)
)
arrowPath.lineWidth = 5
arrowPath.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.72).setStroke()
arrowPath.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: 342, y: 142))
arrowHead.line(to: NSPoint(x: 321, y: 158))
arrowHead.move(to: NSPoint(x: 342, y: 142))
arrowHead.line(to: NSPoint(x: 321, y: 126))
arrowHead.lineWidth = 5
arrowHead.lineCapStyle = .round
arrowHead.stroke()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Could not render DMG background")
}

try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: output).deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: URL(fileURLWithPath: output))

