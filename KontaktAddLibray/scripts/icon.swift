import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let s = CGFloat(pixels), bounds = NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9)
        NSColor(calibratedWhite: 0.105, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: s * 0.19, yRadius: s * 0.19).fill()
        let green = NSColor(calibratedRed: 0.40, green: 0.87, blue: 0.57, alpha: 1)
        for index in 0..<5 {
            green.setFill()
            NSBezierPath(roundedRect: NSRect(x: s * (0.20 + Double(index) * 0.125), y: s * 0.28, width: s * 0.10, height: s * 0.45), xRadius: s * 0.018, yRadius: s * 0.018).fill()
        }
        for index in [0, 1, 3] {
            NSColor(calibratedWhite: 0.105, alpha: 1).setFill()
            NSRect(x: s * (0.275 + Double(index) * 0.125), y: s * 0.49, width: s * 0.07, height: s * 0.25).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
