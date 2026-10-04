import SwiftUI
struct RecordingPreviewTake {
    var start: Double
    var duration: Double
    var channels: [[Double]]
}
@MainActor final class LiveRecordingPreview: ObservableObject {
    static let shared = LiveRecordingPreview()
    @Published var takes: [UUID: RecordingPreviewTake] = [:]
}
/// Waveform updates do not invalidate the grid; only a change of lane does.
@MainActor final class RecordingLaneLayout: ObservableObject {
    static let shared = RecordingLaneLayout()
    struct Reservation {
        let track: UUID
        var clip: AudioClip
        let existing: [AudioClip]
        let layout: TrackLanes
    }
    private(set) var items: [UUID: Reservation] = [:]
    @Published private(set) var revision: UInt64 = 0
    func reserve(track: Track, clip: AudioClip) {
        var base = track
        base.clips += items.values.filter { $0.track == track.id }.map(\.clip)
        let layout = TrackLanes(track: base)
        var clip = clip
        clip.recordingLane = layout.recordingLane(start: clip.startTime, duration: clip.duration, clips: base.clips)
        items[clip.id] = Reservation(track: track.id, clip: clip, existing: base.clips, layout: layout)
        revision &+= 1
    }
    func update(_ id: UUID, start: Double? = nil, duration: Double? = nil) {
        guard var item = items[id] else { return }
        let oldLane = item.clip.recordingLane
        if let start { item.clip.startTime = start }
        if let duration { item.clip.duration = max(0.01, duration) }
        item.clip.recordingLane = item.layout.recordingLane(start: item.clip.startTime, duration: item.clip.duration, clips: item.existing)
        items[id] = item
        if item.clip.recordingLane != oldLane { revision &+= 1 }
    }
    func remove(_ id: UUID) { items[id] = nil; revision &+= 1 }
    func clear() { items = [:]; revision &+= 1 }
    func count(for track: UUID, existing: Int) -> Int {
        max(existing, items.values.filter { $0.track == track }.map { ($0.clip.recordingLane ?? 0) + 1 }.max() ?? 0)
    }
}
struct RecordingGridOverlay: View {
    let visibleRect: CGRect
    let tracks: [Track]
    let offsets: [CGFloat]
    let heights: [CGFloat]
    let rulerHeight: CGFloat
    let scale: CGFloat
    @ObservedObject private var preview = LiveRecordingPreview.shared
    var body: some View {
        Canvas { context,size in
            context.translateBy(x: -visibleRect.minX,y: -visibleRect.minY)
            for (id, take) in preview.takes {
                guard let reservation = RecordingLaneLayout.shared.items[id], let index = tracks.firstIndex(where: { $0.id == reservation.track }) else { continue }
                let count = RecordingLaneLayout.shared.count(for: reservation.track, existing: TrackLanes(track: tracks[index]).count)
                let laneHeight = heights[index] / CGFloat(count)
                let channels = take.channels
                let rect = CGRect(x: take.start*scale,y: rulerHeight+offsets[index]+CGFloat(reservation.clip.recordingLane ?? 0)*laneHeight+3,width: max(3,take.duration*scale),height: laneHeight-6)
                guard rect.intersects(visibleRect) else { continue }
                let shape = Path(roundedRect: rect, cornerRadius: 3)
                let color = JarasTheme.track(tracks[index], emphasized: false)
                context.fill(shape, with: .linearGradient(Gradient(colors: [color, color.opacity(0.78)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.minX, y: rect.maxY)))
                context.stroke(shape, with: .color(color.opacity(0.75)), lineWidth: 0.6)
                var ink = context
                ink.clip(to: shape)
                let headerHeight: CGFloat = rect.height <= 26 ? rect.height : 13
                ink.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)), with: .color(.black.opacity(0.16)))
                if rect.width > 8 {
                    let title = Text(verbatim: reservation.clip.name).font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                    ink.draw(title, in: CGRect(x: max(rect.minX, visibleRect.minX) + 4, y: rect.minY + 1, width: max(0, min(rect.maxX, visibleRect.maxX) - max(rect.minX, visibleRect.minX) - 8), height: headerHeight))
                }
                guard rect.height > 26 else { continue }
                let channelHeight = (rect.height-18)/Double(max(1,channels.count))
                var wave = Path()
                for (channel,peaks) in channels.enumerated() {
                    let middle = rect.minY+16+channelHeight*(Double(channel)+0.5)
                    for (sample,peak) in peaks.enumerated() {
                        let x = rect.minX+Double(sample)/Double(max(1,peaks.count))*rect.width
                        wave.move(to: CGPoint(x: x,y: middle-peak*channelHeight*0.45))
                        wave.addLine(to: CGPoint(x: x,y: middle+peak*channelHeight*0.45))
                    }
                }
                ink.stroke(wave,with: .color(.white.opacity(0.85)),lineWidth: 1)
            }
        }.frame(width: visibleRect.width,height: visibleRect.height).offset(x: visibleRect.minX,y: visibleRect.minY).allowsHitTesting(false)
    }
}
