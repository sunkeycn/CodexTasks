import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)]
for (name, size) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let square = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 195, yRadius: 195)
    NSGradient(starting: NSColor(calibratedRed: 0.95, green: 0.08, blue: 0.09, alpha: 1), ending: NSColor(calibratedRed: 0.82, green: 0.04, blue: 0.06, alpha: 1))!.draw(in: square, angle: 70)
    for y in [CGFloat(710), 512, 314] {
        let circle = NSBezierPath(ovalIn: NSRect(x: 232, y: y - 48, width: 96, height: 96))
        NSColor.white.withAlphaComponent(0.95).setStroke(); circle.lineWidth = 17; circle.stroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: 405, y: y)); line.line(to: NSPoint(x: y == 512 ? 735 : 790, y: y)); line.lineWidth = 30; line.lineCapStyle = .round; NSColor.white.withAlphaComponent(0.94).setStroke(); line.stroke()
    }
    let check = NSBezierPath(); check.move(to: NSPoint(x: 248, y: 712)); check.line(to: NSPoint(x: 272, y: 691)); check.line(to: NSPoint(x: 315, y: 741)); check.lineWidth = 14; check.lineCapStyle = .round; check.lineJoinStyle = .round; NSColor.white.setStroke(); check.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
}
