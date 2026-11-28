import AVFoundation
import SwiftUI

struct RegionBPMPlan: Decodable {
    let region: UUID
    let targetBPM: Double
    let source: [Double]
    let output: [Double]
    let parts: [Part]
    let markers: [TimelineMarker]

    static func make(project: Project, song: Song, region: UUID, bpm: Double, clickBeats: [Double] = []) throws -> Self {
        var metadata = Project.empty(name: "Adjust BPM")
        var header = song
        header.tracks = []
        metadata.songs = [header]
        let data = try JarasCoreBridge.regionTempoPlan(JSONEncoder().encode(metadata), region: region.uuidString, target: bpm, clickBeats: clickBeats.map { NSNumber(value: $0) })
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func time(_ value: Double) -> Double {
        guard let start = source.first, let end = source.last, value > start else { return value }
        if value >= end { return value + (output.last! - end) }
        var lo = 0, hi = source.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if source[mid] <= value { lo = mid } else { hi = mid }
        }
        return output[lo] + (value-source[lo]) * (output[hi]-output[lo]) / (source[hi]-source[lo])
    }
    func itemEdges(_ clip: AudioClip) -> [Double] {
        let end = clip.startTime + clip.duration
        return [clip.startTime] + source.filter { $0 > clip.startTime && $0 < end } + [end]
    }

    private static func printItem(_ clip: AudioClip, track: Track, song: Song, project: Project, folder: URL,
                                  cancellation: AudioExportCancellation, progress: (AudioExportProgress) -> Void) throws -> AudioClip {
        var isolated = song, lane = track
        lane.clips = [clip]; lane.parentTrackID = nil; lane.role = .other
        isolated.tracks = [lane]
        return try ItemReRender.render(project: project, song: isolated, track: lane, clip: clip, directory: folder,
                                       settings: MediaProcessingFormat(format: .wav, bitDepth: 32, bitrate: 320),
                                       cancellation: cancellation, progress: progress)
    }
    private static func discardIntermediate(_ file: URL) {
        try? FileManager.default.removeItem(at: TimelineAudioWaveform.diskCacheURL(file))
        try? FileManager.default.removeItem(at: file)
    }
    private func hasAudio(_ clip: AudioClip, _ track: Track) -> Bool {
        clip.startTime < source.last! && clip.startTime + clip.duration > source[0] &&
            !clip.isImage && clip.text == nil && (clip.midi == nil || clip.frozenMIDI == true) && (clip.audioFile ?? track.audioFile) != nil
    }

    func render(project: Project, song: Song, folder: URL, cancellation: AudioExportCancellation,
                report: @escaping (Double, String) -> Void) throws -> (song: Song, files: [URL], plan: Self) {
        let clickItems = song.tracks.filter { track in
            track.role == .click || track.kind == .click || track.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Click") == .orderedSame
        }.flatMap { track in track.clips.filter { hasAudio($0, track) }.map { (track, $0) } }
        var prepared = [UUID: AudioClip]()
        defer {
            for clip in prepared.values {
                if let file = clip.audioFile { Self.discardIntermediate(folder.projectMedia(file.path)) }
            }
        }
        var beats = [Double]()
        let count = song.tracks.reduce(0) { total, track in total + track.clips.filter { hasAudio($0, track) }.count }
        let units = Double(max(1, count + clickItems.count))
        for (index, entry) in clickItems.enumerated() {
            if cancellation.cancelled { throw CancellationError() }
            let (track, clip) = entry
            let printed = try Self.printItem(clip, track: track, song: song, project: project, folder: folder, cancellation: cancellation) {
                report((Double(index) + $0.fraction * 0.85) / units, clip.name)
            }
            prepared[clip.id] = printed
            let file = folder.projectMedia(printed.audioFile!.path)
            let pulses = try TimelineAudioWaveform.clickTransients(file, cancelled: { cancellation.cancelled })
                .map { ClickTempoDetector.Transient(position: $0.position, peak: $0.peak) }
            beats.append(contentsOf: ClickTempoDetector.primaryTransients(pulses).map { clip.startTime + $0.position })
            report(Double(index + 1) / units, clip.name)
        }
        let plan = beats.isEmpty ? self : try Self.make(project: project, song: song, region: region, bpm: targetBPM, clickBeats: beats)
        let rendered = try plan.renderItems(project: project, song: song, folder: folder, cancellation: cancellation, prepared: prepared) {
            report((Double(clickItems.count) + $0 * Double(max(1, count))) / units, $1)
        }
        return (rendered.song, rendered.files, plan)
    }

    private func renderItems(project: Project, song: Song, folder: URL, cancellation: AudioExportCancellation,
                             prepared: [UUID: AudioClip], report: @escaping (Double, String) -> Void) throws -> (song: Song, files: [URL]) {
        let stems = folder.appendingPathComponent("Stems", isDirectory: true)
        try FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)
        var names = MediaFileNames(directory: stems)
        var next = song
        let oldStarts = Dictionary(uniqueKeysWithValues: song.parts.map { ($0.id, $0.startTime) })
        next.parts = parts; next.markers = markers; next.duration = time(song.duration)
        var files: [URL] = []
        let regionStart = source[0], regionEnd = source.last!
        let total = song.tracks.reduce(0) { sum, track in sum + track.clips.filter { hasAudio($0, track) }.count }
        var completed = 0
        do {
            for row in song.tracks.indices {
                let track = song.tracks[row]
                next.tracks[row].automation?.mapTimelineTimes(time)
                if let markers = track.programChanges {
                    next.tracks[row].programChanges = markers.map { var m = $0; m.position = time(m.position); return m }
                }
                if let chords = track.chordMarkers {
                    next.tracks[row].chordMarkers = chords.map { var m = $0
                        if let start = oldStarts[m.regionID] { m.offset = time(start + m.offset) - time(start) }
                        return m
                    }
                }
                for index in track.clips.indices {
                    if cancellation.cancelled { throw CancellationError() }
                    let original = track.clips[index], start = original.startTime, end = start + original.duration
                    var clip = original
                    if hasAudio(original, track) {
                        let base = Double(completed), count = Double(max(1,total))
                        var last = -1.0
                        func advance(_ value: Double) {
                            let progress = (base + value)/count
                            if progress >= last + 0.001 || value == 1 { last = progress; report(progress, original.name) }
                        }
                        advance(0)
                        do {
                            let printed = try prepared[original.id] ?? Self.printItem(original, track: track, song: song, project: project,
                                folder: folder, cancellation: cancellation) { advance(0.45 * $0.fraction) }
                            let intermediate = folder.projectMedia(printed.audioFile!.path)
                            defer { if prepared[original.id] == nil { Self.discardIntermediate(intermediate) } }
                            let name = names.allocate((original.name as NSString).deletingPathExtension + "-BPM.wav", forceSuffix: true)
                            let destination = stems.appendingPathComponent(name)
                            let edges = itemEdges(original)
                            try JarasCoreBridge.renderFixedTempo(intermediate, to: destination,
                                source: edges.map { NSNumber(value: $0-start) },
                                outputTimes: edges.map { NSNumber(value: time($0)-time(start)) }) { partial in
                                    advance(0.45 + 0.53 * partial); return !cancellation.cancelled
                                }
                            files.append(destination)
                            let overview = try StemProjectImporter.audioOverview(destination, duration: time(end)-time(start))
                            clip = printed; clip.name = original.name; clip.waveform = overview.waveform; clip.waveformChannels = overview.channels
                            clip.audioFile = AudioFile(path: "Stems/" + name); clip.tempoRateReferences = nil
                            if original.isProjectionMedia {
                                clip.adjustedVideo = original.adjustedVideoSource(at: edges, newTime: time)
                            }
                        } catch where original.isProjectionMedia && AudioFileRead.isVideoWithoutAudio(error) {
                            clip.adjustedVideo = original.adjustedVideoSource(at: itemEdges(original), newTime: time)
                        }
                        completed += 1; advance(1)
                    } else if let midi = original.midi, start < regionEnd, end > regionStart {
                        clip = original.mappingMIDITime(song: song, map: time, midi: midi)
                        clip.tempoRateReferences = markers.compactMap { marker in
                            guard marker.isTempo else { return nil }
                            return ItemTempoReference(markerID: marker.id, rate: next.tempoPlaybackRate(for: marker))
                        }
                    }
                    clip.startTime = time(start); clip.duration = time(end) - clip.startTime
                    if track.kind == .timecode, track.importedTimecodeItems != true, clip.audioFile == nil,
                       let part = next.parts.first(where: { Project.timecodeItemID($0.id) == clip.id }) {
                        clip.timecodeStartOffset = clip.startTime - part.startTime
                        clip.timecodeEndOffset = clip.startTime + clip.duration - part.endTime
                    }
                    next.tracks[row].clips[index] = clip
                }
            }
            if cancellation.cancelled { throw CancellationError() }
            return (next,files)
        } catch {
            for url in files { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}

struct RegionBPMHost: View {
    let show: ShowController
    let documents: ProjectDocuments
    private struct Request: Identifiable { let id: UUID; let project: UUID }
    @State private var request: Request?
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onReceive(show.$adjustBPMRegion) { region in
                guard let region else { return }
                DispatchQueue.main.async {
                    guard show.adjustBPMRegion == region else { return }
                    show.adjustBPMRegion = nil
                    request = Request(id: region, project: show.snapshot.project.id)
                }
            }
            .sheet(item: $request) { value in
                RegionBPMSheet(show: show, documents: documents, region: value.id, projectID: value.project) { request = nil }
            }
    }
}

#if os(macOS)
private struct RegionBPMInput: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void

    final class Field: NSTextField, NSTextFieldDelegate {
        var input: RegionBPMInput?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, window.makeFirstResponder(self) else { return }
                self.selectText(nil)
            }
        }
        func controlTextDidChange(_ notification: Notification) { input?.text = stringValue }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSResponder.insertNewline(_:)) else { return false }
            input?.submit()
            return true
        }
    }
    func makeNSView(context: Context) -> Field {
        let field = Field(string: text)
        field.delegate = field
        field.placeholderString = "BPM"
        field.setAccessibilityLabel("BPM")
        field.setAccessibilityIdentifier("adjust-bpm-target")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: Field, context: Context) { field.input = self }
}
#else
private struct RegionBPMInput: UIViewRepresentable {
    @Binding var text: String
    let submit: () -> Void

    final class Field: UITextField, UITextFieldDelegate {
        var input: RegionBPMInput?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.becomeFirstResponder() else { return }
                self.selectAll(nil)
            }
        }
        @objc func edited() { input?.text = text ?? "" }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { input?.submit(); return false }
    }
    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.text = text
        field.placeholder = "BPM"
        field.accessibilityIdentifier = "adjust-bpm-target"
        field.accessibilityLabel = "BPM"
        field.borderStyle = .roundedRect
        field.keyboardType = .decimalPad
        field.delegate = field
        field.addTarget(field, action: #selector(Field.edited), for: .editingChanged)
        return field
    }
    func updateUIView(_ field: Field, context: Context) { field.input = self }
}
#endif

struct RegionBPMSheet: View {
    let show: ShowController
    let documents: ProjectDocuments
    let region: UUID
    let projectID: UUID
    let close: () -> Void
    private enum Step { case confirm, target, running, error }
    @State private var step = Step.confirm
    @State private var bpm = ""
    @State private var error = ""
    @State private var file = ""
    @State private var progress = 0.0
    @State private var cancel = AudioExportCancellation()
    private var target: Double? {
        guard let v = Double(bpm.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")),
              TimelineTempo.bpmRange.contains(v) else { return nil }
        return v
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Adjust BPM").font(.headline)
            switch step {
            case .confirm:
                Text("Render all audio items in this region at a fixed BPM? The following songs will move together.")
                HStack { Spacer(); Button("Cancel", action: close); Button("Continue") { step = .target }.keyboardShortcut(.defaultAction) }
            case .target:
                Text("Target BPM")
                RegionBPMInput(text: $bpm) { if let target { run(target) } }
                    .frame(maxWidth: .infinity).frame(height: 30)
                HStack { Spacer(); Button("Cancel", action: close); Button("Adjust BPM") { if let target { run(target) } }
                    .disabled(target == nil).keyboardShortcut(.defaultAction) }
            case .running:
                Text(file).lineLimit(1)
                ProgressView(value: progress)
                HStack { Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit(); Spacer(); Button("Cancel") { cancel.cancel() } }
            case .error:
                Text(verbatim: JarasLocalization.string(error))
                HStack { Spacer(); Button("OK", action: close).keyboardShortcut(.defaultAction) }
            }
        }
        #if os(iOS)
        .padding(20)
        #else
        .padding(24).frame(idealWidth: 390, maxWidth: 440)
        #endif
        .interactiveDismissDisabled(step == .running)
        .onAppear {
            guard let song = show.current, let part = song.parts.first(where: { $0.id == region }) else { close(); return }
            let initial = song.tempoSection(at: part.startTime).bpm
            bpm = String(format: "%g", initial)
            do { _ = try RegionBPMPlan.make(project: show.snapshot.project, song: song, region: region, bpm: initial) }
            catch { self.error = error.localizedDescription; step = .error }
        }
    }
    private func run(_ target: Double) {
        guard step == .target else { return }
        guard !documents.busy, show.canControl(), show.tunerInputAllowed, projectID == show.snapshot.project.id,
              let song = show.current, let directory = documents.currentURL?.deletingLastPathComponent() else {
            error = "Stop playback and wait for the project to finish loading."; step = .error; return
        }
        let token = cancel
        guard let part = song.parts.first(where: { $0.id == region }) else { close(); return }
        let ids = Set(song.tracks.flatMap { track in track.clips.filter { clip in
            return clip.startTime < part.endTime && clip.startTime+clip.duration > part.startTime && clip.fx != nil
        }.map(\.id) })
        if !ids.isEmpty {
            do { try show.prepareItemsForRendering(ids) }
            catch { self.error = error.localizedDescription; step = .error; return }
        }
        guard let currentSong = show.current else { close(); return }
        let project = show.snapshot.project
        step = .running; documents.busy = true
        Task { @MainActor in
            defer { documents.busy = false }
            do {
                let plan = try RegionBPMPlan.make(project: project, song: currentSong, region: region, bpm: target)
                let result = try await Task.detached(priority: .userInitiated) {
                    try plan.render(project: project, song: currentSong, folder: directory, cancellation: token) { fraction, name in
                        Task { @MainActor in if fraction >= progress { progress = fraction; file = name } }
                    }
                }.value
                guard !token.cancelled, show.commitRegionBPM(result.song, original: currentSong, projectID: projectID, mapTime: result.plan.time) else {
                    for url in result.files { try? FileManager.default.removeItem(at: url) }
                    if token.cancelled { close(); return }
                    throw ProjectError.invalid("The project changed during Adjust BPM.")
                }
                close()
            } catch {
                if token.cancelled { close() } else { self.error = error.localizedDescription; step = .error }
            }
        }
    }
}


private extension AudioClip {
    func mappingMIDITime(song: Song, map: (Double) -> Double, midi: MIDIItem) -> Self {
        var neutral = self
        neutral.muted = false; neutral.gain = 1; neutral.fadeIn = nil; neutral.fadeOut = nil
        neutral.pitchSemitones = nil
        var copy = self, updated = midi
        let beats = midi.sourceBPM / 60, origin = map(startTime)
        var seen: Set<UUID> = []
        updated.notes = song.midiPlaybackNotes(in: neutral).map { note in
            MIDINote(id: seen.insert(note.sourceID).inserted ? note.sourceID : UUID(),
                     start: (map(note.start)-origin)*beats, length: (map(note.end)-map(note.start))*beats,
                     pitch: note.pitch, velocity: note.velocity, channel: note.channel)
        }
        copy.midi = updated; copy.sourceOffset = 0; copy.playbackRate = 1
        copy.renderedTempo = nil; copy.tempoBasePlaybackRate = nil; copy.tempoRateReferences = nil
        copy.loopStart = nil; copy.loopLength = nil; copy.elasticPoints = nil; copy.elasticSourceScale = nil
        return copy
    }
}
