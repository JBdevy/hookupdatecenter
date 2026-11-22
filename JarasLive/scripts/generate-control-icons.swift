// Run from the JarasLive root with swift scripts/generate-control-icons.swift.
// Pass Android's drawable-nodpi directory to also export the transport drawables.
import AppKit
import ImageIO

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

struct Material {
    let color: UInt32
    var darkInk = false

    private var channels: [CGFloat] {
        [16, 8, 0].map { CGFloat((color >> $0) & 255) / 255 }
    }

    func shade(_ amount: CGFloat, alpha: CGFloat = 1) -> [CGFloat] {
        channels.map { amount >= 0 ? $0 + (1 - $0) * amount : $0 * (1 + amount) } + [alpha]
    }
}

let materials: [UInt32: [String]] = [
    0x6cafff: ["doc.text", "line.3.horizontal", "sidebar.left", "fitTime", "timelineZoomAxis", "midiPreview", "tabs.mappings", "refresh"],
    0x39dbce: ["slider.horizontal.3", "library.instruments", "itemTimebase", "projection", "eye", "tabs.waveform"],
    0x997cff: ["pause", "trackMixer", "hozMixer", "slider.vertical.3", "square.grid.3x3", "video", "automationLanes", "teleprompter2", "library.plugins", "tabs.plugins", "tabs.account"],
    0xffad61: ["stopwatch", "magnet", "note.text", "fadeout", "metronome", "tabs.metronome", "search"],
    0x52df94: ["play", "addTrack", "tabs.transport", "text.bubble", "rectangle", "tabs.actions", "save", "check", "send"],
    0xf773a8: ["square.grid.3x2.fill", "flag", "library.samplers", "editCursor", "teleprompter1", "arrow.up.and.down.text.horizontal"],
    0xf1cc5c: ["folder.fill", "books.vertical", "library.presets", "star.fill", "loop", "lock", "pin"],
    0xff5a6e: ["record", "tabs.record", "stopall", "preview", "dot.radiowaves.left.and.right"],
    0x93afd9: ["gearshape", "fitTracks", "trackHeightAxis", "list.bullet.indent", "square.grid.2x2", "unlock", "chevron.left", "chevron.right", "chevron.down"],
    0xa5befa: ["pianokeys", "speaker.wave.2", "timelineLanes", "info.circle", "projectStart", "previousTimelinePoint", "nextTimelinePoint", "projectEnd"],
]
let iconColors = Dictionary(uniqueKeysWithValues: materials.flatMap { color, names in names.map { ($0, color) } })
let indicators: Set<String> = [
    "books.vertical", "sidebar.left", "slider.horizontal.3", "slider.vertical.3", "square.grid.3x3",
    "list.bullet.indent", "text.bubble", "stopwatch", "pianokeys", "square.grid.3x2.fill", "video",
    "gearshape", "fitTracks", "fitTime", "info.circle",
    "projection", "teleprompter1", "teleprompter2", "eye", "midiPreview", "timelineLanes",
    "magnet", "itemTimebase"
]

let toolbarStatusIcons: Set<String> = ["preview", "dot.radiowaves.left.and.right", "trackMixer", "hozMixer"]

func stroke(_ path: CGPath, width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 2)
}

func transform(_ path: CGPath, dx: CGFloat, dy: CGFloat) -> CGPath {
    var offset = CGAffineTransform(translationX: dx, y: dy)
    return path.copy(using: &offset)!
}

func paintMaterial(_ context: CGContext, _ shape: CGPath, _ material: Material, prominent: Bool = false) {
    guard !shape.isEmpty else { return }
    let bounds = shape.boundingBoxOfPath
    let shadow = material.shade(material.darkInk ? -0.83 : -0.71, alpha: 0.78)
    context.setFillColor(CGColor(colorSpace: space, components: shadow)!)
    context.addPath(transform(shape, dx: 0.7, dy: 1.6))
    context.drawPath(using: .eoFill)
    context.setFillColor(CGColor(colorSpace: space, components: material.shade(material.darkInk ? -0.57 : -0.41))!)
    for step in [1.15, 0.80, 0.45] {
        context.addPath(transform(shape, dx: CGFloat(step) * 0.55, dy: CGFloat(step)))
        context.drawPath(using: .eoFill)
    }

    context.saveGState()
    context.addPath(shape)
    context.clip(using: .evenOdd)
    let brightness: [CGFloat] = material.darkInk ? [0.10, -0.07, -0.30, -0.57] :
        [prominent ? 0.70 : 0.55, prominent ? 0.30 : 0.16, -0.08, -0.36]
    let gradient = CGGradient(colorSpace: space, colorComponents: brightness.flatMap { material.shade($0) },
                              locations: [0, 0.24, 0.65, 1], count: 4)!
    context.drawLinearGradient(gradient, start: CGPoint(x: bounds.minX, y: bounds.minY),
                               end: CGPoint(x: bounds.maxX * 0.65 + bounds.minX * 0.35, y: bounds.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // A thin highlight on the upper bevel and a dark lower edge read as depth
    // even when the toolbar presents the resulting PNG at 16 points.
    context.setFillColor(CGColor(colorSpace: space, components: material.shade(material.darkInk ? 0.25 : 0.8, alpha: 0.48))!)
    context.addPath(stroke(transform(shape, dx: 0.40, dy: 0.65), width: 0.7))
    context.fillPath()
    context.setFillColor(CGColor(colorSpace: space, components: material.shade(-0.70, alpha: 0.44))!)
    context.addPath(stroke(transform(shape, dx: -0.24, dy: -0.48), width: 0.68))
    context.fillPath()
    context.restoreGState()
}

func renderSymbol(_ context: CGContext, name: String, outline: CGPath, filled: CGPath, active: Bool) {
    let darkInk = name == "fadeout" ||
        (active && ["pause", "editCursor", "automationLanes", "lock", "loop", "record", "stopall", "metronome", "save"].contains(name))
    var color = active && toolbarStatusIcons.contains(name) ? 0x54ed87 : iconColors[name, default: 0x90adcf]
    if darkInk {
        switch name {
        case "record": color = 0x681827
        case "stopall": color = 0x8e2540
        case "fadeout" where active: color = 0x4c274d
        default: color = 0x693f72
        }
    }
    let material = Material(color: color, darkInk: darkInk)
    var fills = filled
    var lines = outline
    switch name {
    case "record" where active:
        fills = CGPath(roundedRect: CGRect(x: 7.3, y: 7.3, width: 9.4, height: 9.4), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
    case "editCursor" where !active:
        fills = stroke(filled, width: 2.1)
    case "gearshape", "square.grid.2x2", "square.grid.3x3":
        fills = outline
        lines = CGMutablePath()
    case "metronome", "tabs.metronome":
        let caseBody = path("m 4 21 l 8 4 q 8.4 2.5 10 2.5 l 14 2.5 q 15.6 2.5 16 4 l 20 21 q 20.2 22 19 22 l 5 22 q 3.8 22 4 21 z")
        paintMaterial(context, caseBody, material, prominent: active)
        let pendulum = stroke(path("m 11.5 18 l 19.8 7 m 8 18 l 12 18"), width: 1.9)
        paintMaterial(context, pendulum, Material(color: darkInk ? 0xe5b394 : 0x644157), prominent: active)
        let weight = CGPath(ellipseIn: CGRect(x: 18.1, y: 5.3, width: 3.4, height: 3.4), transform: nil)
        paintMaterial(context, weight, Material(color: darkInk ? 0xffcf92 : 0xc6edff), prominent: active)
        return
    case "books.vertical":
        let covers: [(String, UInt32)] = [
            ("m 2 4 l 7 4 l 7 21 l 2 21 z", 0x55aaff),
            ("m 8.5 3 l 13.5 3 l 13.5 21 l 8.5 21 z", 0x9b70ef),
            ("m 15 5 l 19 3.5 l 24 19.5 l 20 21 z", 0xf0b452)
        ]
        for (book, tint) in covers { paintMaterial(context, path(book), Material(color: tint), prominent: active) }
        context.setFillColor(CGColor(colorSpace: space, components: [0.9, 0.94, 1, 0.65])!)
        context.fill(CGRect(x: 2.7, y: 7, width: 3.6, height: 1))
        context.fill(CGRect(x: 9.1, y: 6, width: 3.8, height: 1))
        return
    default:
        break
    }
    paintMaterial(context, stroke(lines, width: active ? 2.35 : 2.15), material, prominent: active)
    paintMaterial(context, fills, material, prominent: active)
    if active && name == "eye" {
        paintMaterial(context, CGPath(ellipseIn: CGRect(x: 9.6, y: 9.6, width: 4.8, height: 4.8), transform: nil),
                      Material(color: 0x76ffc8), prominent: true)
    }
}

let tile = 96, columns = 8
let width = columns * tile, height = ((rows.count + columns - 1) / columns) * tile
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let movingHeadURL = resources.appendingPathComponent("ControlIconSources/StageLights.png")
guard let movingHeadSource = CGImageSourceCreateWithURL(movingHeadURL as CFURL, nil),
      let movingHead = CGImageSourceCreateImageAtIndex(movingHeadSource, 0, nil),
      let movingHeadIndex = rows.firstIndex(where: { $0[0] == "stageLights" }) else {
    fatalError("Missing the grandMA2 moving-head icon or its atlas slot")
}
for active in [false, true] {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: CGFloat(tile) / 24, y: -CGFloat(tile) / 24)
    for (index, row) in rows.enumerated() {
        if index == movingHeadIndex { continue }
        let name = row[0]
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(index % columns * 24), y: CGFloat(index / columns * 24))
        ctx.translateBy(x: 1.4, y: 1.0)
        ctx.scaleBy(x: 0.86, y: 0.86)
        renderSymbol(ctx, name: name, outline: path(row[1]), filled: path(row[2]), active: active)
        if active && indicators.contains(name) {
            ctx.setFillColor(red: 0.06, green: 0.13, blue: 0.10, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: 19.1, y: 19, width: 6.1, height: 6.1))
            ctx.setFillColor(red: 0.44, green: 0.96, blue: 0.60, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: 20, y: 19.9, width: 4.3, height: 4.3))
        }
        ctx.restoreGState()
    }
    ctx.restoreGState()
    let cell = CGRect(x: movingHeadIndex % columns * tile,
                      y: height - (movingHeadIndex / columns + 1) * tile, width: tile, height: tile)
    let scale = CGFloat(tile - 4) / CGFloat(max(movingHead.width, movingHead.height))
    let artSize = CGSize(width: CGFloat(movingHead.width) * scale, height: CGFloat(movingHead.height) * scale)
    ctx.interpolationQuality = .high
    ctx.draw(movingHead, in: CGRect(x: cell.midX - artSize.width / 2, y: cell.midY - artSize.height / 2,
                                   width: artSize.width, height: artSize.height))
    if active {
        ctx.setFillColor(red: 0.44, green: 0.96, blue: 0.60, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: cell.maxX - 19, y: cell.minY + 5, width: 15, height: 15))
    }
    let image = ctx.makeImage()!
    let bitmap = NSBitmapImageRep(cgImage: image)
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(active ? "controlsOn.png" : "controlsOff.png"))
    if let output = CommandLine.arguments.dropFirst().first {
        let android = URL(fileURLWithPath: output, isDirectory: true)
        let keys = active ? ["fadeout", "loop", "play", "stopall"] : ["fadeout", "loop", "pause", "play"]
        for key in keys {
            let index = rows.firstIndex { $0[0] == key }!
            let rect = CGRect(x: index % columns * tile, y: index / columns * tile, width: tile, height: tile)
            let icon = NSBitmapImageRep(cgImage: image.cropping(to: rect)!)
            let name = "transport_\(key)_\(active ? "on" : "off").png"
            try icon.representation(using: .png, properties: [:])!.write(to: android.appendingPathComponent(name))
        }
    }
}
try (rows.map { $0[0] }.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("controlNames.txt"), atomically: true, encoding: .utf8)
