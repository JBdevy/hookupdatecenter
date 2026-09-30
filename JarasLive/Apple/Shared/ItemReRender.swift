import Foundation
import AVFoundation
import SwiftUI

/// Freeze only item processing. Track/folder/Master gain, FX and song tuning
/// remain live, so the newly rendered file cannot receive them twice.
enum ItemReRender {
    static func render(project: Project, song: Song, track: Track, clip: AudioClip, directory: URL,
                       settings: MediaProcessingFormat, cancellation: AudioExportCancellation,
                       progress: (AudioExportProgress) -> Void = { _ in }) throws -> AudioClip {
        var source = song
        var time = source.projectTime; time.timebase = .free; source.timeSettings = time
        source.markers?.removeAll { $0.isTempo }
        for index in source.parts.indices { source.parts[index].pitchSemitones = 0 }
        for index in source.tracks.indices {
            source.tracks[index].fx = nil; source.tracks[index].volume = 1; source.tracks[index].pan = 0
            source.tracks[index].mute = false; source.tracks[index].solo = false
            for item in source.tracks[index].clips.indices { source.tracks[index].clips[item].muted = false }
        }
        let folder = directory.appendingPathComponent("Steams")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names = MediaFileNames(directory: folder)
        var stem = (clip.name as NSString).deletingPathExtension
        if let expression = try? NSRegularExpression(pattern: "-[0-9]{2,}$") {
            stem = expression.stringByReplacingMatches(in: stem, range: NSRange(stem.startIndex..., in: stem), withTemplate: "")
        }
        let name = names.allocate(stem + "." + settings.format.fileExtension, forceSuffix: true)
        let job = AudioExportJob(id: clip.id.uuidString, fileName: name, start: clip.startTime, end: clip.startTime + clip.duration, track: track.id, clip: clip.id)
        let url = folder.appendingPathComponent(name)
        do {
            try OfflineAudioExport.run(project: project, song: source, plan: AudioExportPlan(jobs: [job]), mediaDirectory: directory,
                                       outputDirectory: folder, sampleRate: 48000, encoding: settings.encoding, cancellation: cancellation, progress: progress)
            let file = try AVAudioFile(forReading: url)
            let overview = try StemProjectImporter.audioOverview(url, duration: Double(file.length) / file.processingFormat.sampleRate)
            var result = clip
            result.name = url.deletingPathExtension().lastPathComponent
            result.audioFile = AudioFile(path: "Steams/" + name)
            result.sourceOffset = 0; result.playbackRate = 1; result.gain = 1; result.normalizationGain = nil; result.channelMode = nil
            result.loopStart = nil; result.loopLength = nil; result.fx = nil; result.fxBypassed = nil
            result.waveform = overview.waveform; result.waveformChannels = overview.channels
            return result
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
}

@MainActor final class ItemReRenderProgress: ObservableObject {
    @Published var fileName = ""
    @Published var fraction = 0.0
    @Published var index = 0
    @Published var total = 0
    @Published var error: String?
}

struct ItemReRenderProgressView: View {
    @ObservedObject var progress: ItemReRenderProgress
    let close: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text("Re-render").font(.headline)
            Text(progress.fileName).lineLimit(2).textSelection(.enabled)
            Text("\(progress.index + 1) / \(progress.total)").monospacedDigit()
            if let error = progress.error {
                Text(error).foregroundStyle(.red)
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            } else {
                ProgressView(value: progress.fraction).progressViewStyle(.linear)
            }
        }.padding(24).frame(width: 420).interactiveDismissDisabled()
    }
}
