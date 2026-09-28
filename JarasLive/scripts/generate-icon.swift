import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let sourceURL = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : URL(fileURLWithPath: "Jara Live Logo.png")
guard let source = NSImage(contentsOf: sourceURL) else { fatalError("Logo PNG not found") }
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
var images: [[String:String]] = []
for size in [16,32,128,256,512] { for scale in [1,2] {
    let pixels=size*scale
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    let c=NSGraphicsContext.current!.cgContext
    c.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
    let imageRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.10, alpha: 1).setFill()
    NSBezierPath(roundedRect: imageRect.insetBy(dx: 32, dy: 32), xRadius: 210, yRadius: 210).fill()
    source.draw(in: imageRect.insetBy(dx: 45, dy: 45), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let name="icon-\(size)@\(scale)x.png"
    try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(name))
    images.append(["idiom":"mac","size":"\(size)x\(size)","scale":"\(scale)x","filename":name])
} }
try JSONSerialization.data(withJSONObject:["images":images,"info":["author":"xcode","version":1]],options:.prettyPrinted).write(to:root.appendingPathComponent("Contents.json"))
