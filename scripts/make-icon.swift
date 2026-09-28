import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dist/Frog.iconset", isDirectory: true)
guard let source = NSImage(contentsOfFile: "docs/images/frog_logo.png") else { fatalError("Missing docs/images/frog_logo.png") }
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
func image(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try image(size: size).write(to: destination.appendingPathComponent("icon_\(size)x\(size).png"))
    try image(size: size * 2).write(to: destination.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
