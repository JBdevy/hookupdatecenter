// AppKit layer subclasses count actual setter calls in the extracted fixture.
// Ordinary header rendering remains uninstrumented in the application.
private enum HeaderSetterProbe {
    static var enabled = false
    static var values: [String: Int] = [:]
    static func note(_ name: String) { if enabled { values[name, default: 0] += 1 } }
}
private class HeaderProbeLayer: CALayer {
    override var isHidden: Bool { didSet { HeaderSetterProbe.note("hidden") } }
    override var contentsScale: CGFloat { didSet { HeaderSetterProbe.note("scale") } }
    override var backgroundColor: CGColor? { didSet { HeaderSetterProbe.note("color") } }
    override var mask: CALayer? { didSet { HeaderSetterProbe.note("mask") } }
}
private final class HeaderProbeShapeLayer: CAShapeLayer {
    override var isHidden: Bool { didSet { HeaderSetterProbe.note("hidden") } }
    override var contentsScale: CGFloat { didSet { HeaderSetterProbe.note("scale") } }
    override var fillColor: CGColor? { didSet { HeaderSetterProbe.note("color") } }
    override var strokeColor: CGColor? { didSet { HeaderSetterProbe.note("color") } }
    override var lineWidth: CGFloat { didSet { HeaderSetterProbe.note("lineWidth") } }
    override var lineDashPattern: [NSNumber]? { didSet { HeaderSetterProbe.note("dash") } }
}
@MainActor private func runHeaderLayerStateTests() {
    let header = NativeTimelineHeaderView()
    let part = Part(id: UUID(), name: "Retained region", startTime: 4, endTime: 26, color: 0x705264)
    let ordinary = TimelineMarker(id: UUID(), name: "A", position: 2, color: 0x40a050)
    let tempo = TimelineMarker(id: UUID(), name: "BPM", position: 34, color: 0x999999, tempoBPM: 128)
    var song = Song(id: UUID(), name: "Layer state", duration: 600, bpm: 120, tracks: [], parts: [part], markers: [ordinary, tempo])
    func configuration() -> NativeTimelineHeaderConfiguration {
        .init(song: song, lanes: RegionLanes(parts: song.parts), parentIDs: [], regionTargets: [],
            edit: { _ in }, delete: { _ in }, seek: { _ in }, move: { _ in })
    }
    func project(_ view: NativeTimelineHeaderView, scale: CGFloat, backing: CGFloat = 2, offset: CGFloat = 0) {
        view.project(scale: scale, viewport: CGRect(x: offset, y: 0, width: 700, height: 180),
            layoutWidth: 1_000_000, displayScale: backing)
    }
    func pixels(_ layer: CALayer, backing: CGFloat) -> Data {
        let width = Int(ceil(layer.bounds.width * backing)), height = Int(ceil(layer.bounds.height * backing))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: backing, y: backing)
        context.translateBy(x: 0, y: layer.bounds.height); context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        return Data(bytes: context.data!, count: width * height * 4)
    }
    header.configure(configuration()); project(header, scale: 10)
    HeaderSetterProbe.values.removeAll(); HeaderSetterProbe.enabled = true
    for frame in 1...20 { project(header, scale: 10 + CGFloat(frame) * 0.001) }
    HeaderSetterProbe.enabled = false
    precondition(HeaderSetterProbe.values.isEmpty,
        "changing only geometry must not toggle visibility or rewrite unchanged layer styles")
    HeaderSetterProbe.enabled = true
    project(header, scale: 10, backing: 3)
    HeaderSetterProbe.enabled = false
    precondition(HeaderSetterProbe.values["scale", default: 0] > 0, "Retina changes still update content scales")
    // A fresh node has no old image/path to accidentally leave visible. Matching
    // it across entry/exit, tiny widths and style changes catches stale content.
    var cases = 0
    for edit in 0..<5 {
        switch edit {
        case 1: song.parts[0].color = 0xff3070; song.markers?[0].color = 0xabcdef
        case 2: song.parts[0].name = "Changed title"; song.markers?[0].tempoBPM = 92
        case 3: song.markers?[0].tempoBPM = nil; song.markers?[0].sourceRegionID = part.id
        case 4: song.parts = []; song.markers = []
        default: break
        }
        header.configure(configuration())
        for backing: CGFloat in [1, 2, 3] { for scale: CGFloat in [0.05, 10.123, 60] { for offset: CGFloat in [0, 1390] {
            let fresh = NativeTimelineHeaderView(); fresh.configure(configuration())
            project(header, scale: scale, backing: backing, offset: offset)
            project(fresh, scale: scale, backing: backing, offset: offset)
            precondition(pixels(header.drawingForTest, backing: backing) == pixels(fresh.drawingForTest, backing: backing),
                "retained layer state matches fresh pixels after clipping, visibility and style changes")
            cases += 1
        } } }
    }
    print("HEADER_LAYER_STATE_OK: zero redundant style/visibility setters during zoom, Retina invalidation and \(cases) retained/fresh pixel cases")
}
MainActor.assumeIsolated { runHeaderLayerStateTests() }
