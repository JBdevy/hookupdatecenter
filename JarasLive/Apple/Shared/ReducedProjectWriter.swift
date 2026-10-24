#if os(macOS)
import Foundation

struct ProjectReductionProgress: Sendable {
    let fraction: Double
    let message: String
}

enum ReducedProjectWriter {
    static func write(project: Project, groups: [ProjectReductionTrack], media: URL, target: URL,
                      instruments: [UUID: [String: OfflineMIDIInstrument]], cancellation: AudioExportCancellation, format: AudioExportFormat = .wav, bitDepth: Int = 32, sampleRate: Double = 48000, bitrate: Int = 320,
                      availableCapacity: (URL) throws -> Double = { folder in
                          let attributes = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
                          return (attributes[.systemFreeSize] as? NSNumber)?.doubleValue ?? -1
                      },
                      progress: @escaping @Sendable (ProjectReductionProgress) -> Void) throws {
        func report(_ fraction: Double, _ message: String) {
            progress(ProjectReductionProgress(fraction: fraction, message: message))
        }
        report(0, "Preparando redução…")
        try ProjectReduction.validate(groups, project: project)
        guard [16,24,32].contains(bitDepth), [44100.0,48000.0].contains(sampleRate), [128,160,192,224,256,320].contains(bitrate) else {
            throw AudioExportFailure.invalidFormat
        }
        try ProjectDirectoryPolicy.validate(target)
        try ProjectDirectoryPolicy.prepareNewProjectDirectory(for: target)
        let fm = FileManager.default, folder = target.deletingLastPathComponent()
        var completed = false
        var names = Set(project.mediaPaths.map { $0.lowercased() })
        defer { if !completed { try? fm.removeItem(at: folder) } }
        let estimate = ProjectReduction.estimate(groups, project: project) { path in
            let url = media.appendingPathComponent(path)
            return Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let estimatedBytes = estimate.bytes(for: format, bitDepth: bitDepth, sampleRate: sampleRate, bitrate: bitrate)
        let free = try availableCapacity(folder)
        if free >= 0 && free < estimatedBytes + 64 * 1024 * 1024 {
            throw ProjectError.invalid(String(format: "Espaço insuficiente. Projeto estimado: %.2f GB; disponível: %.2f GB. Escolha outro formato ou disco.", estimatedBytes / 1e9, free / 1e9))
        }
        let stems = folder.appendingPathComponent("Stems", isDirectory: true)
        try fm.createDirectory(at: stems, withIntermediateDirectories: true)
        var result = project
        var destinations = Array(repeating: [Track](), count: project.songs.count)
        result.id = UUID(); result.projectSyncID = UUID(); result.name = target.deletingPathExtension().lastPathComponent
        for (index, group) in groups.enumerated() {
            if cancellation.cancelled { throw CancellationError() }
            guard let si = project.songs.firstIndex(where: { !group.sources.isDisjoint(with: $0.tracks.map(\.id)) }) else { continue }
            let sourceSong = project.songs[si], sourceTracks = sourceSong.tracks.filter { group.sources.contains($0.id) }
            let trackLabel = "Pista \(index + 1)/\(groups.count): \(group.name)"
            report(0.9 * Double(index) / Double(groups.count), "Preparando \(trackLabel)")
            let spans = ProjectReduction.sampleAligned(ProjectReduction.spans(sourceTracks, in: sourceSong), sampleRate: sampleRate)
            if sourceTracks.count == 1 && (sourceTracks[0].parentTrackID == nil || spans.isEmpty) {
                var copy = sourceTracks[0]
                copy.name = copy.fixedName ?? group.name
                destinations[si].append(copy)
                report(0.9 * Double(index + 1) / Double(groups.count), "Mantendo \(trackLabel)"); continue
            }
            guard !spans.isEmpty else { throw ProjectError.invalid("A combinação \(group.name) não contém áudio ou MIDI para renderizar.") }
            var renderSong = sourceSong
            var needed = group.sources
            for source in sourceTracks {
                var cursor = source.parentTrackID
                while let id = cursor, needed.insert(id).inserted, let track = sourceSong.tracks.first(where: { $0.id == id }) {
                    cursor = track.parentTrackID
                }
            }
            renderSong.tracks = sourceSong.tracks.filter { needed.contains($0.id) }.map { original in
                var track = original
                track.mute = sourceSong.isSilenced(original); track.solo = false
                track.clips = group.sources.contains(track.id) ? track.clips.filter { ProjectReduction.isAudio($0, track: original) } : []
                if !group.sources.contains(track.id) { track.audioFile = nil }
                track.outputs = [track.parentTrackID == nil ? .master : .masterGroup]; track.patch = nil; track.secondaryPatch = nil; track.routing = nil; track.stereoLink = nil
                return track
            }
            var renderProject = project
            renderProject.masterFX = nil; renderProject.masterAutomation = nil; renderProject.masterVolume = 1; renderProject.masterPan = 0; renderProject.masterMute = false; renderProject.masterSolo = false; renderProject.masterMono = false; renderProject.masterPhaseInverted = false
            let base = group.name.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r")).joined(separator: "_").prefix(80)
            let jobs = spans.enumerated().map { n, span -> AudioExportJob in
                var suffix = n + 1, file = "\(base) - \(n + 1).\(format.fileExtension)"
                while !names.insert(("Stems/" + file).lowercased()).inserted { suffix += 1; file = "\(base) - \(suffix).\(format.fileExtension)" }
                return AudioExportJob(id: "\(index)-\(n)", fileName: file, start: span.start, end: span.end)
            }
            var renderingFile = jobs.first?.fileName ?? group.name
            do { try OfflineAudioExport.run(project: renderProject, song: renderSong, plan: AudioExportPlan(jobs: jobs), mediaDirectory: media, outputDirectory: stems, sampleRate: sampleRate, encoding: AudioExportEncoding(format: format, bitDepth: bitDepth, bitrate: bitrate, sampleRate: sampleRate, floatingPoint: bitDepth == 32), cancellation: cancellation, printTrackPolarity: true, midiInstrumentsByTrack: instruments) { value in
                // Offline export reports a fraction for the current file, not the whole plan.
                let jobIndex = jobs.firstIndex(where: { $0.fileName == value.fileName }) ?? 0
                let job = jobs[jobIndex]
                renderingFile = job.fileName
                let region = sourceSong.parts.filter { $0.startTime < job.end && $0.endTime > job.start }
                    .min { ($0.endTime - $0.startTime) < ($1.endTime - $1.startTime) }?.name ?? "Fora de região"
                let groupFraction = (Double(jobIndex) + value.fraction) / Double(jobs.count)
                report(0.9 * (Double(index) + groupFraction) / Double(groups.count),
                       "Renderizando \(trackLabel)\nMúsica/região \(jobIndex + 1)/\(jobs.count): \(region) — \(job.fileName)")
            }
            } catch {
                if cancellation.cancelled { throw CancellationError() }
                throw ProjectError.invalid("Falha ao renderizar \(group.name) — \(renderingFile): \(error.localizedDescription)")
            }
            var track = Track(id: group.id, name: group.name, role: .other, color: sourceTracks.first?.color)
            track.clips = jobs.map { job in AudioClip(id: UUID(), name: group.name, startTime: job.start, duration: job.duration, audioFile: AudioFile(path: "Stems/" + job.fileName), renderedTiming: true) }
            // Preserve non-audio items on the destination, never as extra source lanes.
            for source in sourceTracks {
                track.clips += source.clips.filter { !ProjectReduction.isAudio($0, track: source) }.map { original in
                    var clip = original
                    if clip.audioFile == nil { clip.audioFile = source.audioFile }
                    return clip
                }
            }
            destinations[si].append(track)
        }
        for si in result.songs.indices { result.songs[si].tracks = destinations[si] }
        ProjectReduction.retain(Set(destinations.flatMap { $0.map(\.id) }), in: &result)
        try result.validate()
        let paths = Array(result.mediaPaths).sorted()
        for (fileIndex, path) in paths.enumerated() {
            report(0.9 + 0.09 * Double(fileIndex) / Double(max(1, paths.count)), "Copiando mídia \(fileIndex + 1)/\(paths.count): \(URL(fileURLWithPath: path).lastPathComponent)")
            if cancellation.cancelled { throw CancellationError() }
            let destination = folder.appendingPathComponent(path).standardizedFileURL
            guard destination.path.hasPrefix(folder.standardizedFileURL.path + "/") else { throw ProjectError.invalid("Invalid project media path.") }
            if fm.fileExists(atPath: destination.path) { continue }
            let source = media.appendingPathComponent(path).standardizedFileURL
            guard source.path.hasPrefix(media.standardizedFileURL.path + "/") else { throw ProjectError.invalid("Invalid project media path.") }
            // Missing references stay recoverable, as in the original project.
            if fm.fileExists(atPath: source.path) {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: destination)
            }
        }
        report(0.99, "Salvando projeto reduzido…")
        try result.validate()
        try ProjectDocumentCodec.writeEncoded(ProjectDocumentCodec.encode(result), to: target, exclusive: true)
        completed = true; report(1, "Projeto reduzido salvo.")
    }
}
#endif
