import AppKit
import Foundation

// A filled, transparent template of the same frog face used by the Dock icon.
// Render once into a packaged asset; status-item rendering need not draw paths.
let destination = CommandLine.arguments.dropFirst().first ?? "native/FrogApp/Resources/FrogMenuIcon.png"
let scale: CGFloat = 3
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 66, pixelsHigh: 54, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
NSColor.black.setFill()
NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 20, height: 13)).fill()
NSBezierPath(ovalIn: NSRect(x: 3, y: 9, width: 7, height: 8)).fill()
NSBezierPath(ovalIn: NSRect(x: 12, y: 9, width: 7, height: 8)).fill()
NSGraphicsContext.current?.compositingOperation = .destinationOut
NSColor.black.setFill()
for x in [CGFloat(5.4), CGFloat(14.4)] { NSBezierPath(ovalIn: NSRect(x: x, y: 12, width: 2.2, height: 2.6)).fill() }
let smile = NSBezierPath()
smile.move(to: NSPoint(x: 6, y: 7)); smile.curve(to: NSPoint(x: 16, y: 7), controlPoint1: NSPoint(x: 8, y: 3), controlPoint2: NSPoint(x: 14, y: 3))
smile.lineWidth = 1.2; smile.lineCapStyle = .round; NSColor.black.setStroke(); smile.stroke()
NSGraphicsContext.restoreGraphicsState()
bitmap.size = NSSize(width: 22, height: 18)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
