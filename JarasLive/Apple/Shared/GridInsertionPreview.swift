import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// File drags update this small overlay without invalidating timeline tiles or track layout.
@MainActor final class GridInsertionPreview: ObservableObject {
    @Published private(set) var time: Double?
    struct ExternalTarget: Equatable {
        let y: CGFloat
        let height: CGFloat
        let color: UInt32
        let newTracksY: CGFloat
        let newTrackHeight: CGFloat
    }
    @Published private(set) var externalTarget: ExternalTarget?
    @Published private(set) var externalFiles: [GridExternalMedia] = []
    private var metadataTask: Task<Void, Never>?
    private var metadataGeneration = UUID()
    func externalSources(_ urls: [URL]) {
        guard urls != externalFiles.map(\.url) else { return }
        metadataTask?.cancel()
        let generation = UUID(); metadataGeneration = generation
        externalFiles = urls.map { GridExternalMedia(url: $0, name: $0.deletingPathExtension().lastPathComponent) }
        if urls.isEmpty { externalTarget = nil; return }
        metadataTask = Task.detached(priority: .userInitiated) { [weak self] in
            for (index, url) in urls.enumerated() {
                guard !Task.isCancelled else { return }
                let duration = GridExternalMedia.duration(at: url)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.metadataGeneration == generation else { return }
                    self.externalFiles[index].duration = duration
                }
            }
        }
    }
    func targetExternal(_ target: ExternalTarget) {
        if externalTarget != target { externalTarget = target }
    }
    func update(_ position: Double?) {
        let next = position.flatMap { $0.isFinite ? max(0, $0) : nil }
        if time != next { time = next }
    }
}

struct GridInsertionPreviewOverlay: View {
    @ObservedObject var preview: GridInsertionPreview
    let scale: Double
    let rulerHeight: CGFloat
    let viewportHeight: CGFloat
    var body: some View {
        if let time = preview.time {
            Canvas { context, size in
                let color = Color(white: 0.9).opacity(0.6)
                let x = size.width / 2
                var head = Path()
                head.move(to: CGPoint(x: x - 4, y: rulerHeight - 7))
                head.addLine(to: CGPoint(x: x + 4, y: rulerHeight - 7))
                head.addLine(to: CGPoint(x: x, y: rulerHeight))
                head.closeSubpath()
                context.fill(head, with: .color(color))
                var line = Path()
                line.move(to: CGPoint(x: x, y: rulerHeight))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(color), lineWidth: 1)
            }
            .frame(width: 10, height: viewportHeight)
            .offset(x: time * scale - 5)
        }
    }
}

/// Header metadata only: no sample decoding, waveform preparation or file copies.
struct GridExternalMedia: Equatable, Sendable {
    let url: URL
    let name: String
    var duration: Double?
    static func duration(at url: URL) -> Double? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true { return 10 }
        if type?.conforms(to: .movie) == true {
            let seconds = AVURLAsset(url: url).duration.seconds
            if seconds.isFinite, seconds > 0 { return seconds }
        }
        if let file = try? AVAudioFile(forReading: url) {
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            if seconds.isFinite, seconds > 0 { return seconds }
        }
        return nil
    }
}

struct GridExternalFilePreviewOverlay: View {
    @ObservedObject var preview: GridInsertionPreview
    let scale: Double
    let viewport: CGRect
    let rulerHeight: CGFloat
    var body: some View {
        if let time = preview.time, let target = preview.externalTarget, !preview.externalFiles.isEmpty {
            Canvas { context, size in
                context.clip(to: Path(CGRect(x: 0, y: rulerHeight, width: size.width, height: max(0, size.height - rulerHeight))))
                for (index, file) in preview.externalFiles.enumerated() {
                    let y = index == 0 ? target.y : target.newTracksY + CGFloat(index - 1) * target.newTrackHeight
                    let height = index == 0 ? target.height : target.newTrackHeight
                    let rect = CGRect(x: time * scale - viewport.minX, y: y + 3 - viewport.minY,
                                      width: max(1, file.duration.map { $0 * scale } ?? 100), height: max(12, height - 6))
                    guard rect.intersects(CGRect(origin: .zero, size: size)) else { continue }
                    let color = Color(red: Double((target.color >> 16) & 255) / 255,
                                      green: Double((target.color >> 8) & 255) / 255, blue: Double(target.color & 255) / 255)
                    context.fill(Path(rect), with: .color(color.opacity(0.32)))
                    let bar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(15, rect.height))
                    context.fill(Path(bar), with: .color(color.opacity(0.9)))
                    context.stroke(Path(rect), with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
                    var titleContext = context
                    titleContext.clip(to: Path(bar))
                    let label = Text(verbatim: file.name).font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                    titleContext.draw(label, at: CGPoint(x: max(bar.minX + 4, 4), y: bar.midY), anchor: .leading)
                }
            }.frame(width: viewport.width, height: viewport.height)
                .offset(x: viewport.minX, y: viewport.minY).allowsHitTesting(false)
        }
    }
}
