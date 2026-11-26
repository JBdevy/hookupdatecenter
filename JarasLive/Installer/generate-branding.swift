// Reproduce installer artwork with native vector drawing and the existing CatLive logo.
// Run from the repository root: swift JarasLive/Installer/generate-branding.swift
import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "JarasLive")
let destination = root.appendingPathComponent("Installer/Assets")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let logo = NSImage(contentsOf: root.appendingPathComponent("CatLiveLogo.png"))!
let icon = NSImage(contentsOf: root.appendingPathComponent("Apple/Assets.xcassets/CatLiveIcon.appiconset/icon-256@1x.png"))!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green:g/255, blue:b/255, alpha:a)
}
func render(_ name: String, width: Int, height: Int, scale: Int = 3, _ draw: () -> Void) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:width*scale, pixelsHigh:height*scale,
        bitsPerSample:8, samplesPerPixel:4, hasAlpha:true, isPlanar:false, colorSpaceName:.deviceRGB, bytesPerRow:0, bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    NSGraphicsContext.current!.cgContext.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
    NSGraphicsContext.current!.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    bitmap.size = NSSize(width: width, height: height)
    try bitmap.representation(using:.png,properties:[:])!.write(to:destination.appendingPathComponent(name+".png"))
    if name.hasPrefix("windows-") {
        // Classic 24-bit Windows DIB: explicit bottom-up BGR rows, no ambiguous
        // AppKit V5 orientation/alpha metadata for the installer image loader.
        let pixelsWide = width * scale, pixelsHigh = height * scale
        let rowSize = (pixelsWide * 3 + 3) & ~3
        var bmp = Data([0x42, 0x4d])
        func u16(_ value: UInt16) { var v=value.littleEndian; withUnsafeBytes(of:&v){bmp.append(contentsOf:$0)} }
        func u32(_ value: UInt32) { var v=value.littleEndian; withUnsafeBytes(of:&v){bmp.append(contentsOf:$0)} }
        u32(UInt32(54 + rowSize * pixelsHigh)); u16(0); u16(0); u32(54)
        u32(40); u32(UInt32(pixelsWide)); u32(UInt32(pixelsHigh)); u16(1); u16(24)
        u32(0); u32(UInt32(rowSize * pixelsHigh)); u32(2835); u32(2835); u32(0); u32(0)
        for y in (0..<pixelsHigh).reversed() {
            let source = bitmap.bitmapData!.advanced(by:y * bitmap.bytesPerRow)
            for x in 0..<pixelsWide {
                let p=source.advanced(by:x*4); bmp.append(contentsOf:[p[2],p[1],p[0]])
            }
            bmp.append(contentsOf:repeatElement(UInt8(0),count:rowSize-pixelsWide*3))
        }
        try bmp.write(to:destination.appendingPathComponent(name+".bmp"))
    }
}
func waveform(_ rect: NSRect, opacity: CGFloat, dark: Bool) {
    let bars = 45
    for index in 0..<bars {
        let phase = Double(index)/Double(bars-1)
        let envelope = pow(sin(phase*Double.pi),1.3)
        let pulse = 0.18 + abs(sin(Double(index)*2.07))*0.82
        let h = CGFloat(envelope*pulse)*rect.height
        let mix = CGFloat(index)/CGFloat(bars)
        let ink = dark ? color(96+70*mix,245-140*mix,111+137*mix,opacity) : color(40+78*mix,154-65*mix,82+110*mix,opacity)
        ink.setFill()
        NSBezierPath(roundedRect:NSRect(x:rect.minX+CGFloat(index)*rect.width/CGFloat(bars),y:rect.midY-h/2,width:2,height:max(2,h)),xRadius:1,yRadius:1).fill()
    }
}
try render("windows-sidebar",width:164,height:314,scale:4) {
    NSColor.black.setFill();NSRect(x:0,y:0,width:164,height:314).fill()
    for i in 0..<7 {
        color(85,245,99,0.025).setStroke()
        let path=NSBezierPath(ovalIn:NSRect(x:-110-Double(i)*16,y:190-Double(i)*10,width:300+Double(i)*30,height:300+Double(i)*30));path.lineWidth=0.5;path.stroke()
    }
    logo.draw(in:NSRect(x:5,y:94,width:154,height:154))
    color(128,142,154,0.28).setFill();NSRect(x:24,y:72,width:116,height:0.6).fill()
    waveform(NSRect(x:22,y:18,width:122,height:38),opacity:0.8,dark:true)
    color(88,240,103).setFill();NSRect(x:162,y:0,width:2,height:314).fill()
}
try render("windows-header",width:55,height:55,scale:4) {
    NSColor.white.setFill();NSRect(x:0,y:0,width:55,height:55).fill()
    icon.draw(in:NSRect(x:1,y:1,width:53,height:53))
}
try render("mac-background",width:620,height:418,scale:2) {
    // Transparent artwork leaves Installer.app's native light/dark UI intact.
    icon.draw(in:NSRect(x:32,y:55,width:112,height:112))
}
// ICO preserves each original app-icon PNG, including its alpha channel.
let iconSizes = [(16,"icon-16@1x.png"),(32,"icon-32@1x.png"),(64,"icon-32@2x.png"),
                 (128,"icon-128@1x.png"),(256,"icon-256@1x.png")]
let frames = try iconSizes.map { try Data(contentsOf:root.appendingPathComponent("Apple/Assets.xcassets/CatLiveIcon.appiconset/"+$0.1)) }
var ico = Data()
func ico16(_ value: UInt16) { var v=value.littleEndian;withUnsafeBytes(of:&v){ico.append(contentsOf:$0)} }
func ico32(_ value: UInt32) { var v=value.littleEndian;withUnsafeBytes(of:&v){ico.append(contentsOf:$0)} }
ico16(0);ico16(1);ico16(UInt16(frames.count))
var offset = 6 + 16 * frames.count
for (index,frame) in frames.enumerated() {
    let size=UInt8(iconSizes[index].0%256)
    ico.append(contentsOf:[size,size,0,0]);ico16(1);ico16(32)
    ico32(UInt32(frame.count));ico32(UInt32(offset));offset += frame.count
}
for frame in frames { ico.append(frame) }
try ico.write(to:destination.appendingPathComponent("CatLive.ico"))
print("CatLive installer artwork generated in \(destination.path)")
