import AppKit
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: 1024, height: 1024)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let background = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.32, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.39, blue: 0.68, alpha: 1))!.draw(in: background, angle: 65)
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let chip = NSBezierPath(roundedRect: NSRect(x: 310, y: 310, width: 404, height: 404), xRadius: 64, yRadius: 64)
        chip.lineWidth = 30; chip.stroke()
        for coordinate in stride(from: 376, through: 648, by: 68) {
            let pins = NSBezierPath(); pins.lineWidth = 24; pins.lineCapStyle = .round
            pins.move(to: NSPoint(x: coordinate, y: 240)); pins.line(to: NSPoint(x: coordinate, y: 294))
            pins.move(to: NSPoint(x: coordinate, y: 730)); pins.line(to: NSPoint(x: coordinate, y: 784))
            pins.move(to: NSPoint(x: 240, y: coordinate)); pins.line(to: NSPoint(x: 294, y: coordinate))
            pins.move(to: NSPoint(x: 730, y: coordinate)); pins.line(to: NSPoint(x: 784, y: coordinate))
            pins.stroke()
        }
        NSColor(calibratedRed: 0.40, green: 0.94, blue: 0.73, alpha: 1).setFill()
        for (x, height) in [(390, 104), (480, 175), (570, 248)] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 390, width: 60, height: height), xRadius: 12, yRadius: 12).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(destination)/icon_\(size)x\(size)\(suffix).png"))
    }
}
