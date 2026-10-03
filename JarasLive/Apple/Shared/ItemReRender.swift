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
        let folder = directory.appendingPathComponent("Stems")
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
            result.audioFile = AudioFile(path: "Stems/" + name)
            result.fadeIn = nil; result.fadeOut = nil; result.fadeTimelineStart = nil; result.fadeTimelineDuration = nil
            result.sourceOffset = 0; result.playbackRate = 1; result.gain = 1; result.normalizationGain = nil; result.channelMode = nil
            result.loopStart = nil; result.loopLength = nil; result.fx = nil; result.fxBypassed = nil
            result.waveform = overview.waveform; result.waveformChannels = overview.channels
            return result
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    static func glueSelection(project: Project, song: Song, ids: Set<UUID>, directory: URL,
                              cancellation: AudioExportCancellation,
                              progress: (Int, Int, AudioExportProgress) -> Void = { _, _, _ in }) throws -> [GluedItemReplacement] {
        let groups = song.tracks.filter { $0.kind == .standard }.compactMap { track -> (Track, [AudioClip])? in
            let clips = track.clips.filter { ids.contains($0.id) }
            return clips.isEmpty ? nil : (track, clips)
        }
        guard !groups.isEmpty else { throw ProjectError.invalid("Select audio or MIDI items to unify.") }
        for (track, clips) in groups { try ItemGlue.validate(track: track, clips: clips) }
        var replacements: [GluedItemReplacement] = []
        do {
            for (index, group) in groups.enumerated() {
                if cancellation.cancelled { throw CancellationError() }
                progress(index, groups.count, AudioExportProgress(completed: 0, total: 1, fileName: group.0.name,
                    fraction: 0, waveform: [], clipped: [], peak: 0))
                let rendered = try glue(project: project, song: song, track: group.0, clips: group.1, directory: directory,
                    cancellation: cancellation) { progress(index, groups.count, $0) }
                replacements.append(GluedItemReplacement(track: group.0.id, originals: group.1, rendered: rendered))
            }
            if cancellation.cancelled { throw CancellationError() }
            return replacements
        } catch { discardGluedAudio(replacements, directory: directory); throw error }
    }

    static func discardGluedAudio(_ replacements: [GluedItemReplacement], directory: URL) {
        let originals = Set(replacements.flatMap { $0.originals.compactMap { $0.audioFile?.path } })
        for replacement in replacements {
            if let path = replacement.rendered.audioFile?.path, path.hasPrefix("Stems/"), !originals.contains(path) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(path))
            }
        }
    }

    static func glue(project: Project, song: Song, track: Track, clips: [AudioClip], directory: URL,
                     cancellation: AudioExportCancellation, progress: (AudioExportProgress) -> Void = { _ in }) throws -> AudioClip {
        if cancellation.cancelled { throw CancellationError() }
        try ItemGlue.validate(track: track, clips: clips)
        if clips[0].midi != nil {
            let result = try ItemGlue.midi(song: song, track: track, clips: clips)
            if cancellation.cancelled { throw CancellationError() }
            return result
        }
        let ordered = clips.sorted { $0.startTime < $1.startTime }
        let start = ordered[0].startTime, end = ordered.map { $0.startTime + $0.duration }.max()!
        let allMuted = ordered.allSatisfy { $0.muted == true }
        var source = song, renderedTrack = track
        renderedTrack.clips = ordered
        if allMuted { for index in renderedTrack.clips.indices { renderedTrack.clips[index].muted = false } }
        renderedTrack.fx = nil; renderedTrack.volume = 1; renderedTrack.pan = 0
        renderedTrack.mute = false; renderedTrack.solo = false; renderedTrack.parentTrackID = nil
        source.tracks = [renderedTrack]
        let folder = directory.appendingPathComponent("Stems")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names = MediaFileNames(directory: folder)
        let name = names.allocate((ordered[0].name as NSString).deletingPathExtension + ".wav", forceSuffix: true)
        let url = folder.appendingPathComponent(name)
        let id = UUID()
        let job = AudioExportJob(id: id.uuidString, fileName: name, start: start, end: end, track: track.id, clip: nil)
        do {
            try OfflineAudioExport.run(project: project, song: source, plan: AudioExportPlan(jobs: [job]), mediaDirectory: directory,
                outputDirectory: folder, sampleRate: 48000, encoding: AudioExportEncoding(channels: 2),
                cancellation: cancellation, progress: progress)
            if cancellation.cancelled { throw CancellationError() }
            let overview = try StemProjectImporter.audioOverview(url, duration: end - start)
            return AudioClip(id: id, name: url.deletingPathExtension().lastPathComponent, startTime: start, duration: end - start,
                waveform: overview.waveform, audioFile: AudioFile(path: "Stems/" + name), gain: 1,
                waveformChannels: overview.channels, muted: allMuted ? true : nil, playbackRate: 1,
                recordingLane: ordered[0].recordingLane, frozenMIDI: ordered[0].frozenMIDI == true ? true : nil, renderedTiming: true)
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    @MainActor static func midiInstruments(for track: Track) -> [String: OfflineMIDIInstrument] {
        guard let fx = track.fx else { return [:] }
        var sources: [String: OfflineMIDIInstrument] = [:]
        for key in fx.instrumentKeys where fx.isEnabled(key) {
            let voice = fx.settings(for: key)
            guard let id = voice.instrumentID else { continue }
            let category = InstrumentLibrary.category(id)
            var parameters = voice.instrumentParameters ?? InstrumentLibrary.parameters(id)
            if parameters.controllers == nil { parameters.controllers = InstrumentLibrary.controllers(category) }
            sources[key] = OfflineMIDIInstrument(url: InstrumentLibrary.shared.file(id), parameters: parameters,
                                                drums: category == .drum, monophonic: category == .lead)
        }
        return sources
    }

    /// Print the MIDI source through its complete ordered instrument/FX chain.
    /// The fader and pan stay live, and the source MIDI remains in undo history.
    static func renderMIDI(project: Project, song: Song, track: Track, clip: AudioClip, directory: URL,
                           channels: Int, instruments: [String: OfflineMIDIInstrument], cancellation: AudioExportCancellation,
                           progress: (AudioExportProgress) -> Void = { _ in }) throws -> AudioClip {
        guard clip.midi != nil, [1, 2].contains(channels), clip.duration > 0 else { throw AudioExportFailure.invalidFormat }
        var source = song, renderedTrack = track, sourceClip = clip
        sourceClip.muted = false
        renderedTrack.clips = [sourceClip]
        renderedTrack.volume = 1; renderedTrack.pan = 0; renderedTrack.mute = false; renderedTrack.solo = false
        renderedTrack.parentTrackID = nil
        source.tracks = [renderedTrack]
        let folder = directory.appendingPathComponent("Stems")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names = MediaFileNames(directory: folder)
        let name = names.allocate((clip.name as NSString).deletingPathExtension + ".wav", forceSuffix: true)
        let url = folder.appendingPathComponent(name)
        let job = AudioExportJob(id: clip.id.uuidString, fileName: name, start: clip.startTime, end: clip.startTime + clip.duration, track: track.id, clip: clip.id)
        do {
            try OfflineAudioExport.run(project: project, song: source, plan: AudioExportPlan(jobs: [job]), mediaDirectory: directory,
                                       outputDirectory: folder, sampleRate: 48000, encoding: AudioExportEncoding(channels: channels),
                                       cancellation: cancellation, midiInstruments: instruments, progress: progress)
            let overview = try StemProjectImporter.audioOverview(url, duration: clip.duration)
            var result = clip
            result.name = url.deletingPathExtension().lastPathComponent
            result.audioFile = AudioFile(path: "Stems/" + name); result.midi = nil; result.frozenMIDI = true
            result.sourceOffset = 0; result.playbackRate = 1; result.gain = 1; result.normalizationGain = nil; result.channelMode = nil
            result.loopStart = nil; result.loopLength = nil
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
    var title = "Re-render"
    var cancel: (() -> Void)? = nil
    let close: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text(JarasLocalization.string(title)).font(.headline)
            Text(progress.fileName).lineLimit(2).textSelection(.enabled)
            Text("\(progress.index + 1) / \(progress.total)").monospacedDigit()
            if let error = progress.error {
                Text(error).foregroundStyle(.red)
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            } else {
                ProgressView(value: progress.fraction).progressViewStyle(.linear)
                if let cancel { Button("Cancel", action: cancel).keyboardShortcut(.cancelAction) }
            }
        }.padding(24).frame(width: 420).interactiveDismissDisabled()
    }
}
