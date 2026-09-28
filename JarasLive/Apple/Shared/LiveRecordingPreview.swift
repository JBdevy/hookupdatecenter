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
/// Layout changes only at arm/disarm completion, independent of waveform updates.
@MainActor final class RecordingLaneLayout: ObservableObject {
    static let shared = RecordingLaneLayout()
    struct Reservation { let track: UUID; var clip: AudioClip }
    private(set) var items: [UUID: Reservation] = [:]
    @Published private(set) var revision: UInt64 = 0
    func reserve(track: UUID, clip: AudioClip) { items[clip.id] = Reservation(track: track, clip: clip); revision &+= 1 }
    func move(_ id: UUID, start: Double) { items[id]?.clip.startTime = start; revision &+= 1 }
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
                let shape = Path(roundedRect: rect,cornerRadius: 3)
                context.fill(shape,with: .color(.red.opacity(0.32)))
                context.stroke(shape,with: .color(.red),lineWidth: 1)
                context.fill(Path(CGRect(x: rect.minX,y: rect.minY,width: rect.width,height: 14)),with: .color(.red.opacity(0.6)))
                if rect.width > 40 { context.draw(Text(verbatim: "REC").font(.system(size: 9,weight: .bold)).foregroundColor(.white),at: CGPoint(x: rect.minX+5,y: rect.minY+2),anchor: .topLeading) }
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
                context.stroke(wave,with: .color(.white.opacity(0.85)),lineWidth: 1)
            }
        }.frame(width: visibleRect.width,height: visibleRect.height).offset(x: visibleRect.minX,y: visibleRect.minY).allowsHitTesting(false)
    }
}
