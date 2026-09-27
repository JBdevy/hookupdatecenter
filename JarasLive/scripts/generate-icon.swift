import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
var images: [[String:String]] = []
for size in [16,32,128,256,512] { for scale in [1,2] {
    let pixels=size*scale
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    let c=NSGraphicsContext.current!.cgContext
    c.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
    c.setFillColor(NSColor(srgbRed:0.065,green:0.083,blue:0.11,alpha:1).cgColor)
    c.addPath(CGPath(roundedRect:CGRect(x:64,y:64,width:896,height:896),cornerWidth:190,cornerHeight:190,transform:nil));c.fillPath()
    c.setStrokeColor(NSColor(srgbRed:0.847,green:0.984,blue:0.4,alpha:1).cgColor);c.setLineWidth(88);c.setLineCap(.round)
    c.move(to:CGPoint(x:322,y:752));c.addLine(to:CGPoint(x:558,y:752));c.addLine(to:CGPoint(x:558,y:390));c.addCurve(to:CGPoint(x:268,y:390),control1:CGPoint(x:558,y:218),control2:CGPoint(x:268,y:218));c.strokePath()
    c.setFillColor(NSColor.white.cgColor);c.move(to:CGPoint(x:677,y:608));c.addLine(to:CGPoint(x:812,y:516));c.addLine(to:CGPoint(x:677,y:424));c.closePath();c.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    let name="icon-\(size)@\(scale)x.png"
    try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(name))
    images.append(["idiom":"mac","size":"\(size)x\(size)","scale":"\(scale)x","filename":name])
} }
try JSONSerialization.data(withJSONObject:["images":images,"info":["author":"xcode","version":1]],options:.prettyPrinted).write(to:root.appendingPathComponent("Contents.json"))
