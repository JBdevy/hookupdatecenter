import SwiftUI
import UIKit
import Combine

@MainActor final class TrackMeterLevel {
    @Published var levels: SIMD2<Double>
    init(_ levels: SIMD2<Double>) { self.levels = levels }
}

enum JarasTheme { static let yellow = Color.yellow, green = Color.green, text = Color.white }
enum RemoteSurface { static func fill(_ color: Color) -> Color { color } }
extension Font {
    static func jarasSystem(size: CGFloat, weight: Font.Weight, design: Font.Design = .default) -> Font { .system(size: size, weight: weight, design: design) }
}
@main struct ReuseTestApp: App {
    var body: some Scene { WindowGroup { ReuseWorkspace() } }
}

private struct ReuseWorkspace: View {
    @State private var runner = ReuseRunner()
    var body: some View {
        HStack(spacing: 4) {
            panel(mixer: true)
            panel(mixer: false)
        }.onAppear { runner.schedule() }
    }
    private func panel(mixer: Bool) -> some View {
        ScrollView {
            IpadRecycledTrackRows(ids: runner.ids, heights: runner.heights, retained: { runner.ids[0] }) { index in
                if mixer {
                    HStack {
                        IpadMixerMeter(meter: runner.meters[index], preparesOffscreen: true).frame(width: 10)
                        Text("Track \(index + 1)")
                        RemoteNativeSlider(value: Double(index % 9), range: 0...10,
                                           trackID: runner.ids[index]) { _ in runner.lastFader = index }
                            .frame(width: 72)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Clip row \(index + 1)").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(width: 360, height: runner.end)
        }
    }
}

@MainActor final class ReuseRunner {
    let ids = (0..<320).map { _ in UUID() }
    let heights = (0..<320).map { CGFloat($0.isMultiple(of: 2) ? 86 : 56) }
    let meters = (0..<320).map { TrackMeterLevel($0.isMultiple(of: 2) ? SIMD2(1, 0) : SIMD2(0, 1)) }
    var end: CGFloat { heights.reduce(0,+) + CGFloat(ids.count - 1) }
    var lastFader: Int?
    func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.verify() }
    }
    private func report(_ result: String) {
        let out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt")
        try? result.write(to: out, atomically: true, encoding: .utf8)
        exit(result.hasPrefix("PASS") ? 0 : 1)
    }
    private func descendants<T: UIView>(_ root: UIView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }
    private func children(_ root: UIViewController) -> [IpadRecycledTrackRowsController] {
        (root as? IpadRecycledTrackRowsController).map { [$0] } ?? root.children.flatMap(children)
    }
    private func verify() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { report("Missing window"); return }
        let panels = descendants(root.view, UIScrollView.self)
        let recyclers = children(root).sorted {
            $0.view.convert($0.view.bounds, to: root.view).minX < $1.view.convert($1.view.bounds, to: root.view).minX
        }
        guard panels.count == 2, recyclers.count == 2 else {
            report("Missing recycler in SwiftUI ScrollView: \(panels.count), \(recyclers.count)"); return
        }
        let mixer = recyclers[0], grid = recyclers[1]
        let originalHosts = Array(mixer.mountedHosts)
        let oldHosts = Set(originalHosts.map(ObjectIdentifier.init))
        let before = originalHosts.count
        guard before >= 6, before < 30, mixer.indices.contains(0), grid.indices.contains(0) else {
            report("Unexpected mount count or positions: \(before)"); return
        }
        let sliderViews = descendants(mixer.view, RemoteSliderTouchView.self)
        let meterViews = descendants(mixer.view, IpadMixerMeterView.self)
        let originalSliders = Set(sliderViews.map(ObjectIdentifier.init))
        let originalMeters = Set(meterViews.map(ObjectIdentifier.init))
        defer { withExtendedLifetime((originalHosts, sliderViews, meterViews)) {} }
        var reuse = 0, sliderReuse = 0, meterReuse = 0
        for track in [256, 72, 292, 18, 200, 0] {
            let offset = heights.prefix(track).reduce(0,+) + CGFloat(track)
            for panel in panels.reversed() { panel.setContentOffset(CGPoint(x: 0, y: offset), animated: false) }
            root.view.layoutIfNeeded()
            for controller in recyclers { controller.ensureVisibleLayout() }
            guard mixer.indices.contains(track), grid.indices.contains(track), mixer.indices.contains(0), grid.indices.contains(0) else {
                report("Jump \(track) left grid/mixer out of sync: \(mixer.indices), \(grid.indices)"); return
            }
            guard mixer.hostIDs.count < 35 else { report("Host pool grew: \(mixer.hostIDs.count)"); return }
            reuse += Set(mixer.hostIDs).intersection(oldHosts).count
            sliderReuse += Set(descendants(mixer.view, RemoteSliderTouchView.self).map(ObjectIdentifier.init)).intersection(originalSliders).count
            meterReuse += Set(descendants(mixer.view, IpadMixerMeterView.self).map(ObjectIdentifier.init)).intersection(originalMeters).count
            for row in track...min(track + 1, ids.count-1) {
                guard let host = mixer.host(at: row), let meter = descendants(host.view, IpadMixerMeterView.self).first else {
                    report("Meter missing at \(row)"); return
                }
                let slider = descendants(host.view, RemoteSliderTouchView.self).first
                slider?.changed?(32)
                guard lastFader == row else { report("Fader retained wrong track at \(row)"); return }
                let levels = meter.drawnMeterLevels
                guard levels == meters[row].levels else { report("Wrong meter bits at \(row): \(String(describing: levels))"); return }
            }
        }
        guard reuse > 50, sliderReuse > 30, meterReuse > 30 else {
            report("Rows or controls were recreated: hosts \(reuse), faders \(sliderReuse), meters \(meterReuse)"); return
        }
        report("PASS: 320 variable-height tracks, matched jumps, retained source row, recycled mixer hosts, retained/rebound faders and meters, and constant stereo levels.")
    }
}

extension IpadRecycledTrackRowsController {
    var mountedHosts: [UIViewController] { Array(mounted.values) }
    var hostIDs: [ObjectIdentifier] { mountedHosts.map(ObjectIdentifier.init) }
    var indices: [Int] { mounted.keys.compactMap { positions[$0] }.sorted() }
    func host(at index: Int) -> UIViewController? { mounted[ids[index]] }
    func ensureVisibleLayout() { for host in mounted.values { host.view.layoutIfNeeded() } }
}

extension IpadMixerMeterView {
    var drawnMeterLevels: SIMD2<Double>? { drawing.meterLevels }
}
extension IpadStereoMeterLayers { var meterLevels: SIMD2<Double>? { lastLevels } }
