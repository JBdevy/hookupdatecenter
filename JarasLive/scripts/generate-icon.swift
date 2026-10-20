import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let sourceURL = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : URL(fileURLWithPath: "CatLiveLogo.png")
guard let source = NSImage(contentsOf: sourceURL) else { fatalError("Logo PNG not found") }
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
func fittedRect(in rect: CGRect) -> CGRect {
    let available = rect.insetBy(dx: rect.width * 72 / 1024, dy: rect.height * 72 / 1024)
    let fit = min(available.width / source.size.width, available.height / source.size.height)
    let size = NSSize(width: source.size.width * fit, height: source.size.height * fit)
    return NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                  width: size.width, height: size.height)
}
if CommandLine.arguments.dropFirst(3).contains("composer") {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: fittedRect(in: CGRect(x: 0, y: 0, width: 1024, height: 1024)),
                from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Artwork.png"))
    exit(0)
}
let iPad = CommandLine.arguments.dropFirst(3).contains("ipad")
if iPad {
    let contentsURL = root.appendingPathComponent("Contents.json")
    let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: contentsURL)) as! [String: Any]
    let entries = contents["images"] as! [[String: String]]
    for entry in entries {
        guard let name = entry["filename"], let size = entry["size"], let scale = entry["scale"],
              let points = Double(size.components(separatedBy: "x")[0]),
              let multiplier = Double(scale.replacingOccurrences(of: "x", with: "")) else { continue }
        let pixels = Int((points * multiplier).rounded())
        // App Store icons must be opaque. The supplied artwork is fitted intact.
        guard let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: pixels, height: pixels,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Cannot render icon") }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.fill(rect)
        context.draw(image, in: fittedRect(in: rect))
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
    }
    exit(0)
}
var images: [[String:String]] = []
for size in [16,32,128,256,512] { for scale in [1,2] {
    let pixels=size*scale
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    let c=NSGraphicsContext.current!.cgContext
    c.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
    let imageRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    NSColor.black.setFill()
    let tile = NSBezierPath(roundedRect: imageRect.insetBy(dx: 16, dy: 16), xRadius: 210, yRadius: 210)
    tile.fill(); tile.addClip()
    // Fit the complete supplied logo inside the tile's corner-safe area.
    // New artwork must not inherit the previous logo's crop coordinates.
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: fittedRect(in: imageRect), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let name="icon-\(size)@\(scale)x.png"
    try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(name))
    images.append(["idiom":"mac","size":"\(size)x\(size)","scale":"\(scale)x","filename":name])
} }
try JSONSerialization.data(withJSONObject:["images":images,"info":["author":"xcode","version":1]],options:.prettyPrinted).write(to:root.appendingPathComponent("Contents.json"))
