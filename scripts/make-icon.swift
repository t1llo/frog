import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dist/Frog.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func image(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()
    NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 205, yRadius: 205).fill()
    NSColor(calibratedRed: 0.48, green: 0.86, blue: 0.58, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 192, y: 235, width: 640, height: 480)).fill()
    NSBezierPath(ovalIn: NSRect(x: 222, y: 556, width: 235, height: 235)).fill()
    NSBezierPath(ovalIn: NSRect(x: 567, y: 556, width: 235, height: 235)).fill()
    for x in [CGFloat(270), CGFloat(615)] {
        NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: 599, width: 140, height: 140)).fill()
        NSColor(calibratedRed: 0.07, green: 0.19, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: x + 47, y: 627, width: 59, height: 73)).fill()
    }
    NSColor(calibratedRed: 0.07, green: 0.25, blue: 0.18, alpha: 1).setStroke()
    let smile = NSBezierPath()
    smile.move(to: NSPoint(x: 335, y: 468))
    smile.curve(to: NSPoint(x: 689, y: 468), controlPoint1: NSPoint(x: 430, y: 335), controlPoint2: NSPoint(x: 594, y: 335))
    smile.lineWidth = 25
    smile.lineCapStyle = .round
    smile.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try image(size: size).write(to: destination.appendingPathComponent("icon_\(size)x\(size).png"))
    try image(size: size * 2).write(to: destination.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
