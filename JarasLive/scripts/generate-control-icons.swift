// Run from the JarasLive root with swift scripts/generate-control-icons.swift.
import AppKit

let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
let folder = resources.appendingPathComponent("ControlIcons")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let definitions = try String(contentsOf: resources.appendingPathComponent("DesktopToolbarSymbols.def"), encoding: .utf8)
let rows = definitions.components(separatedBy: .newlines).compactMap { line -> [String]? in
    let fields = line.components(separatedBy: "\"")
    guard fields.count == 7 else { return nil }
    return [fields[1], fields[3], fields[5]]
}
func path(_ definition: String) -> CGPath {
    var tokens = definition.split(separator: " ").makeIterator()
    func point() -> CGPoint {
        CGPoint(x: Double(tokens.next()!)!, y: Double(tokens.next()!)!)
    }
    let path = CGMutablePath()
    while let op = tokens.next() {
        switch op {
        case "m": path.move(to: point())
        case "l": path.addLine(to: point())
        case "q": let c = point(); path.addQuadCurve(to: point(), control: c)
        case "c": let a = point(), b = point(); path.addCurve(to: point(), control1: a, control2: b)
        case "z": path.closeSubpath()
        default: fatalError("Unknown path command \(op)")
        }
    }
    return path
}

let tile = 96, columns = 8
let width = columns * tile, height = ((rows.count + columns - 1) / columns) * tile
let space = CGColorSpace(name: CGColorSpace.sRGB)!
for active in [false, true] {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: CGFloat(tile) / 24, y: -CGFloat(tile) / 24)
    for (index, row) in rows.enumerated() {
        let name = row[0]
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(index % columns * 24), y: CGFloat(index / columns * 24))
        // A shared optical inset leaves room for rounded line caps at every scale.
        ctx.translateBy(x: 1.5, y: 1.5)
        ctx.scaleBy(x: 0.875, y: 0.875)
        let outline = path(row[1]), filled = path(row[2])
        let darkInk = ["pause", "fadeout"].contains(name) || (active && ["editCursor", "automationLanes", "lock", "loop", "record", "play", "stopall"].contains(name))
        let folder = name.hasPrefix("library.") || name == "folder.fill"
        let top: [CGFloat] = name == "record" && !active ? [1.0,0.39,0.36] : folder && !active ? [0.49,0.91,0.60] : darkInk ? [0.12,0.17,0.15] : active ? [0.68,1,0.78] : [0.95,0.96,0.98]
        let bottom: [CGFloat] = name == "record" && !active ? [0.92,0.12,0.12] : folder && !active ? [0.19,0.65,0.34] : darkInk ? [0.025,0.05,0.04] : active ? [0.26,0.90,0.48] : [0.66,0.70,0.75]
        let gradient = CGGradient(colorSpace: space, colorComponents: top + [1] + bottom + [1],
                                  locations: [0, 1], count: 2)!
        func ink(_ shape: CGPath, evenOdd: Bool = false) {
            guard !shape.isEmpty else { return }
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip(using: evenOdd ? .evenOdd : .winding)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 12,y: 1), end: CGPoint(x: 12,y: 23),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        func stroke(_ shape: CGPath, _ width: CGFloat) {
            ink(shape.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 2))
        }
        if active && name == "record" {
            ink(CGPath(roundedRect: CGRect(x: 7.5, y: 7.5, width: 9, height: 9), cornerWidth: 1.3, cornerHeight: 1.3, transform: nil))
        } else if !active && name == "editCursor" {
            stroke(filled, 1.8)
        } else {
            ink(filled, evenOdd: true)
        }
        if active && name == "pause" { stroke(filled, 0.8) }
        stroke(outline, active ? 2.25 : 1.85)
        if active && name == "eye" {
            ink(CGPath(ellipseIn: CGRect(x: 9.6, y: 9.6, width: 4.8, height: 4.8), transform: nil))
        }
        if active && name == "magnet" {
            ink(CGPath(rect: CGRect(x: 4.5, y: 3.5, width: 4, height: 4), transform: nil))
            ink(CGPath(rect: CGRect(x: 15.5, y: 3.5, width: 4, height: 4), transform: nil))
        }
        ctx.restoreGState()
    }
    let bitmap = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(active ? "controlsOn.png" : "controlsOff.png"))
}
try (rows.map { $0[0] }.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("controlNames.txt"), atomically: true, encoding: .utf8)
