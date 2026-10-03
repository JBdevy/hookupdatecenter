import Foundation
import AVFoundation
import JavaScriptCore
import Accelerate
import UniformTypeIdentifiers
import ImageIO

struct ImportSuggestion: Decodable, Identifiable, Sendable {
    var text: String; var count: Int
    var id: String { text }
}
struct ImportSourceFile: Sendable { var url: URL; var name: String; var duration: Double }
struct ImportSourceFolder: Sendable { var url: URL; var files: [ImportSourceFile] }
struct StemScan: Sendable { var folders: [ImportSourceFolder]; var suggestions: [ImportSuggestion]; var warnings: [String] }
struct ImportAudit: Decodable {
    struct Stem: Decodable { var filePath: String; var fileName: String; var trackName: String; var trackKey: String; var duration: Double; var takeVolume: Double }
    struct Region: Decodable { var name: String; var start: Double; var end: Double; var files: [Stem] }
    struct Channel: Decodable { var name: String; var key: String; var groupKey: String }
    struct Group: Decodable { var key: String; var name: String; var colorHex: String; var tracks: [Channel] }
    var songs: [Region]; var tracks: [Channel]; var groups: [Group]
}

/// Runs on a worker task. Audio is read in bounded buffers, never on the UI or audio thread.
enum AudioDropLayout: String, CaseIterable, Sendable { case separateTracks, sameTrack }

enum StemProjectImporter {
    struct DroppedAudio: Sendable { let tracks: [Track]; let folders: [URL]; var folder: URL { folders[0] } }
    private struct DroppedSource {
        let url: URL
        let kind: TrackKind
        let duration: Double
    }
    private static func droppedSources(_ urls: [URL]) throws -> [DroppedSource] {
        var seen = Set<URL>(), sources: [DroppedSource] = []
        for url in urls {
            try Task.checkCancellation()
            guard seen.insert(url.standardizedFileURL).inserted else { continue }
            guard url.isFileURL else { throw ProjectError.invalid("Could not read the dropped file.") }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
            guard values.isRegularFile == true else { throw ProjectError.invalid("Select media files, not folders.") }
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
            let knownAudio = ["wav", "wave", "aif", "aiff", "mp3", "m4a", "aac", "caf", "flac"].contains(url.pathExtension.lowercased())
            let image = type?.conforms(to: .image) == true
            guard knownAudio || image || type?.conforms(to: .audio) == true || type?.conforms(to: .movie) == true else {
                throw ProjectError.invalid("Unsupported media file: " + url.lastPathComponent)
            }
            if image {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
                      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else {
                    throw ProjectError.invalid("Unsupported media file: " + url.lastPathComponent)
                }
                sources.append(DroppedSource(url: url, kind: .video, duration: 10))
                continue
            }
            let asset = AVURLAsset(url: url)
            let video = !asset.tracks(withMediaType: .video).isEmpty
            let duration: Double
            if video { duration = asset.duration.seconds }
            else {
                let audio = try AVAudioFile(forReading: url)
                duration = Double(audio.length) / audio.processingFormat.sampleRate
            }
            guard duration.isFinite, duration > 0 else { throw ProjectError.invalid("Empty media file: " + url.lastPathComponent) }
            sources.append(DroppedSource(url: url, kind: video ? .video : .standard, duration: duration))
        }
        return sources
    }
    static func prepareDroppedAudio(_ urls: [URL], start: Double, destinationTracks: [UUID], destination: URL, layout: AudioDropLayout = .separateTracks, gap: Double = 0, destinationKind: TrackKind? = nil, videoTrackAvailable: Bool = false,
                                    progress: (@Sendable (Int, Int, String) -> Void)? = nil) throws -> DroppedAudio {
        guard start.isFinite, start >= 0, gap.isFinite, (0...60).contains(gap), !urls.isEmpty else { throw ProjectError.invalid("No media files to import") }
        // Validate the entire batch before making any project directory or copying media.
        let sources = try droppedSources(urls)
        guard let kind = sources.first?.kind else { throw ProjectError.invalid("No media files to import") }
        guard sources.allSatisfy({ $0.kind == kind }) else { throw ProjectError.invalid("Drop audio and video separately") }
        if kind == .video {
            guard destinationKind == .video || destinationKind?.isTeleprompter == true, !destinationTracks.isEmpty else {
                throw ProjectError.invalid(videoTrackAvailable ? "Drop videos on an existing Video track" : "Create a Video track first, then drop the video on it")
            }
            guard layout == .sameTrack || sources.count <= destinationTracks.count else {
                throw ProjectError.invalid("Choose Same track to add these videos to the existing Video track")
            }
        } else {
            guard destinationKind == nil || destinationKind == .standard else { throw ProjectError.invalid("Audio files must be dropped on a standard audio track") }
        }
        let fm = FileManager.default
        let batch = UUID().uuidString
        var audioNames = MediaFileNames(directory: destination.deletingLastPathComponent().appendingPathComponent("Stems"))
        var videoNames = MediaFileNames(directory: destination.deletingLastPathComponent().appendingPathComponent("Videos"))
        var folders: [URL] = []
        do {
            var tracks: [Track] = []
            var cursor = start
            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                let url = source.url, isVideo = source.kind == .video
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                progress?(index, sources.count, url.lastPathComponent)
                let name = isVideo ? videoNames.allocate(url.lastPathComponent) : audioNames.allocate(url.lastPathComponent)
                let relative = (isVideo ? "Videos/" : "Stems/") + batch
                let folder = destination.deletingLastPathComponent().appendingPathComponent(relative, isDirectory: true)
                if !folders.contains(folder) {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true); folders.append(folder)
                }
                let copied = folder.appendingPathComponent(name)
                try fm.copyItem(at: url, to: copied)
                let overview = isVideo ? (waveform: [Double](), peak: 0.0, channels: [[Double]]()) : try audioOverview(copied, duration: source.duration)
                let itemName = url.deletingPathExtension().lastPathComponent
                let clip = AudioClip(id: UUID(), name: itemName, startTime: layout == .sameTrack ? cursor : start, duration: source.duration,
                                     waveform: overview.waveform, audioFile: AudioFile(path: relative + "/" + name), waveformChannels: overview.channels)
                if layout == .sameTrack, !tracks.isEmpty { tracks[0].clips.append(clip) }
                else {
                    let trackID = tracks.count < destinationTracks.count ? destinationTracks[tracks.count] : UUID()
                    var track = Track(id: trackID, name: isVideo ? (destinationKind?.title ?? "Video") : itemName, role: TrackRole(rawValue: isVideo ? (destinationKind?.rawValue ?? "video") : "other"), color: isVideo ? nil : Track.defaultStandardColor)
                    track.clips = [clip]; tracks.append(track)
                }
                cursor += source.duration + gap
                progress?(index + 1, sources.count, url.lastPathComponent)
            }
            return DroppedAudio(tracks: tracks, folders: folders)
        } catch {
            for folder in folders { try? fm.removeItem(at: folder) }
            throw error
        }
    }
    static func context() throws -> JSContext {
        guard let context = JSContext() else { throw ProjectError.invalid("Import rules unavailable") }
        context.evaluateScript(HookImportRules.source)
        if let error = context.exception { throw ProjectError.invalid(error.toString()) }
        return context
    }
    static func call<T: Decodable>(_ name: String, args: [Any], context: JSContext, as: T.Type) throws -> T {
        context.exception = nil
        guard let result = context.objectForKeyedSubscript(name)?.call(withArguments: args), context.exception == nil,
              let object = result.toObject() else { throw ProjectError.invalid(context.exception?.toString() ?? "Import analysis failed") }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static func scan(_ urls: [URL]) throws -> StemScan {
        let fm = FileManager.default
        var folders: [ImportSourceFolder] = [], names: [String] = [], warnings: [String] = []
        var visited = Set<URL>()
        for url in urls {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ProjectError.invalid("Select real song folders: \(url.lastPathComponent)") }
            guard visited.insert(url.standardizedFileURL).inserted else { continue }
            let entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            var files: [ImportSourceFile] = []
            names.append(url.lastPathComponent)
            for file in entries where ["wav", "wave", "aif", "aiff", "mp3"].contains(file.pathExtension.lowercased()) {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                do {
                    let audio = try AVAudioFile(forReading: file)
                    let duration = Double(audio.length) / audio.processingFormat.sampleRate
                    guard duration.isFinite, duration > 0 else { throw ProjectError.invalid("Invalid duration") }
                    // Duration comes from the container; scanning names must not decode every sample.
                    files.append(ImportSourceFile(url: file, name: file.lastPathComponent, duration: duration))
                    names.append(file.deletingPathExtension().lastPathComponent)
                } catch is CancellationError { throw CancellationError() }
                catch { warnings.append("\(file.lastPathComponent): \(error.localizedDescription)") }
            }
            if files.isEmpty { warnings.append("\(url.lastPathComponent): no readable WAV, AIFF or MP3 files") }
            else { folders.append(ImportSourceFolder(url: url, files: files)) }
        }
        guard !folders.isEmpty else { throw ProjectError.invalid(warnings.joined(separator: "\n")) }
        let js = try context()
        let suggestions = try call("suggestImportRemovals", args: [names, ["limit": 12]], context: js, as: [ImportSuggestion].self)
        return StemScan(folders: folders, suggestions: suggestions, warnings: warnings)
    }
    /// One bounded pass after import confirmation. Accelerate reduces whole ranges
    /// instead of doing divisions and updating Swift arrays for every sample.
    static func audioOverview(_ url: URL, duration: Double) throws -> (waveform: [Double], peak: Double, channels: [[Double]]) {
        let audio = try AVAudioFile(forReading: url)
        let bins = min(2048, max(96, Int(duration * 8)))
        var waveform = Array(repeating: 0.0, count: bins)
        var channelPeaks = Array(repeating: Array(repeating: 0.0, count: bins), count: Int(audio.processingFormat.channelCount))
        var peak: Float = 0
        guard audio.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 65536) else { throw ProjectError.invalid("Audio buffer unavailable") }
        while audio.framePosition < audio.length {
            try Task.checkCancellation()
            let offset = audio.framePosition
            guard try AudioFileRead.read(audio, into: buffer) else { break }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw ProjectError.invalid("Unreadable audio samples") }
            var local = 0
            while local < Int(buffer.frameLength) {
                let position = offset + Int64(local)
                let bin = min(bins - 1, Int(position * Int64(bins) / audio.length))
                let next = ((Int64(bin + 1) * audio.length) + Int64(bins - 1)) / Int64(bins)
                let count = min(Int(buffer.frameLength) - local, max(1, Int(next - position)))
                var segmentPeak: Float = 0
                for channel in 0..<Int(buffer.format.channelCount) {
                    var value: Float = 0
                    vDSP_maxmgv(channels[channel].advanced(by: local * buffer.stride), vDSP_Stride(buffer.stride), &value, vDSP_Length(count))
                    channelPeaks[channel][bin] = max(channelPeaks[channel][bin], min(1, Double(value)))
                    segmentPeak = max(segmentPeak, value)
                }
                peak = max(peak, segmentPeak)
                waveform[bin] = max(waveform[bin], min(1, Double(segmentPeak)))
                local += count
            }
        }
        return (waveform, Double(peak), channelPeaks)
    }
    /// Enrich older imported items once; the saved overview avoids decoding on redraw.
    public static func populateChannelOverviews(_ source: Project, directory: URL) throws -> Project {
        var project = source
        var cache: [String: [[Double]]] = [:]
        for song in project.songs.indices {
            for track in project.songs[song].tracks.indices {
                guard project.songs[song].tracks[track].kind == .standard else { continue }
                for item in project.songs[song].tracks[track].clips.indices {
                    try Task.checkCancellation()
                    let clip = project.songs[song].tracks[track].clips[item]
                    guard clip.waveformChannels == nil, let file = clip.audioFile else { continue }
                    if cache[file.path] == nil {
                        let url = directory.appendingPathComponent(file.path)
                        guard FileManager.default.fileExists(atPath: url.path) else { continue }
                        cache[file.path] = try audioOverview(url, duration: clip.duration).channels
                    }
                    project.songs[song].tracks[track].clips[item].waveformChannels = cache[file.path]
                }
            }
        }
        return project
    }
    private typealias MediaOverview = (waveform: [Double], peak: Double, channels: [[Double]])
    private struct MediaImportJob {
        let source: URL, copied: URL
        let relative: String
        let stem: ImportAudit.Stem
        let track: Int
        let start: Double
    }
    /// Only a few bounded decode buffers exist at once. The result slots retain
    /// input order even when a shorter file finishes before an earlier file.
    private static func prepareMedia(_ jobs: [MediaImportJob], progress: (@Sendable (Int, Int, String) -> Void)?) throws -> [MediaOverview] {
        try Task.checkCancellation()
        let lock = NSLock()
        var next = 0, completed = 0, failure: Error?
        var results = Array<MediaOverview?>(repeating: nil, count: jobs.count)
        var lastProgress = 0.0
        DispatchQueue.concurrentPerform(iterations: min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 1), jobs.count)) { _ in
            while true {
                lock.lock()
                guard failure == nil, next < jobs.count else { lock.unlock(); return }
                let index = next; next += 1; lock.unlock()
                let job = jobs[index]
                do {
                    let scoped = job.source.startAccessingSecurityScopedResource()
                    defer { if scoped { job.source.stopAccessingSecurityScopedResource() } }
                    try FileManager.default.copyItem(at: job.source, to: job.copied)
                    let overview = try audioOverview(job.copied, duration: job.stem.duration)
                    lock.lock(); results[index] = overview; completed += 1
                    let now = ProcessInfo.processInfo.systemUptime
                    if completed == jobs.count || now - lastProgress >= 0.1 {
                        lastProgress = now; progress?(completed, jobs.count, job.stem.fileName)
                    }
                    lock.unlock()
                } catch { lock.lock(); if failure == nil { failure = error }; lock.unlock(); return }
            }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        return try results.map { guard let result = $0 else { throw ProjectError.invalid("Missing imported audio") }; return result }
    }
    static func build(scan: StemScan, remove: String, base: Project, destination: URL, progress: (@Sendable (Int, Int, String) -> Void)? = nil) throws -> Project {
        try ProjectDirectoryPolicy.validate(destination)
        let js = try context(), fm = FileManager.default
        func clean(_ value: String, directory: Bool) throws -> String {
            guard !remove.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return value }
            let result = js.objectForKeyedSubscript("removalName")?.call(withArguments: [value, remove, directory])
            if let object = result?.toDictionary() {
                guard object["invalid"] as? Bool != true, let name = object["name"] as? String else { throw ProjectError.invalid("Cleaning would produce an invalid name: \(value)") }
                return name
            }
            return value
        }
        var virtual: [[String: Any]] = [], sources: [String: ImportSourceFile] = [:]
        for (index, folder) in scan.folders.enumerated() {
            let folderPath = "/\(index)/" + (try clean(folder.url.lastPathComponent, directory: true))
            var entries: [[String: Any]] = [], used = Set<String>()
            for file in folder.files {
                let name = try clean(file.name, directory: false)
                guard used.insert(name.folding(options: [.caseInsensitive], locale: nil)).inserted else { throw ProjectError.invalid("Cleaning creates duplicate file names: \(name)") }
                entries.append(["name": name, "duration": file.duration, "peakDb": NSNull()])
                sources[folderPath + "/" + name] = file
            }
            virtual.append(["path": folderPath, "files": entries])
        }
        let audit = try call("analyzeImport", args: [virtual], context: js, as: ImportAudit.self)
        guard !audit.songs.isEmpty else { throw ProjectError.invalid("No songs found") }
        var project = base
        guard !project.songs.isEmpty else { throw ProjectError.invalid("Missing arrangement") }
        var arrangement = project.songs[0]
        let existingTrackCount = arrangement.tracks.count
        let oldEnd = max(arrangement.parts.map(\.endTime).max() ?? 0, arrangement.tracks.flatMap(\.clips).map { $0.startTime + $0.duration }.max() ?? 0)
        let offset = oldEnd
        let existingFolders = Set(arrangement.tracks.compactMap(\.parentTrackID)).union(arrangement.tracks.filter {
            $0.kind == .standard && $0.parentTrackID == nil && $0.clips.isEmpty && !js.objectForKeyedSubscript("groupKeyFromFolderName")!.call(withArguments: [$0.name])!.toString()!.isEmpty
        }.map(\.id))
        var keys: [String: Int] = [:]
        for (index, track) in arrangement.tracks.enumerated() where track.kind == .standard && !existingFolders.contains(track.id) {
            let key = js.objectForKeyedSubscript("canonicalExistingTrackKey")!.call(withArguments: [track.name])!.toString()!
            if keys[key] == nil { keys[key] = index }
            if keys["custom:" + key] == nil { keys["custom:" + key] = index }
        }
        for channel in audit.tracks where keys[channel.key] == nil {
            let role: TrackRole = channel.name == "Click" ? .click : channel.name == "Guia" || channel.name == "Regência" ? .guide : channel.groupKey == "sanfonas" ? .accordion : channel.name.hasPrefix("Baixo") ? .bass : channel.groupKey == "teclados" ? .keys : channel.groupKey == "percussivo" ? .drums : channel.groupKey == "guitarras" ? .guitar : .other
            keys[channel.key] = arrangement.tracks.count
            arrangement.tracks.append(Track(id: UUID(), name: channel.name, role: role, color: Track.defaultStandardColor))
        }
        // A unique import directory makes rollback safe and keeps existing media untouched.
        let relativeFolder = "Stems/" + UUID().uuidString
        let media = destination.deletingLastPathComponent().appendingPathComponent(relativeFolder)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        do {
            var jobs: [MediaImportJob] = []
            var fileNames = MediaFileNames(directory: destination.deletingLastPathComponent().appendingPathComponent("Stems"))
            for (songIndex, song) in audit.songs.enumerated() {
                arrangement.parts.append(Part(id: UUID(), name: song.name, startTime: song.start + offset, endTime: song.end + offset, color: [0x53be8c,0xddad54,0x7a93dd,0xbf79b8,0x55acbe][songIndex % 5]))
                for (fileIndex, stem) in song.files.enumerated() {
                    guard let source = sources[stem.filePath], let track = keys[stem.trackKey] else { throw ProjectError.invalid("Missing imported audio") }
                    let name = fileNames.allocate(stem.fileName)
                    jobs.append(MediaImportJob(source: source.url, copied: media.appendingPathComponent(name), relative: relativeFolder + "/" + name, stem: stem, track: track, start: song.start + offset))
                }
            }
            let prepared = try prepareMedia(jobs, progress: progress)
            for (job, overview) in zip(jobs, prepared) {
                let stem = job.stem
                let internalTrack = stem.trackName == "Click" || stem.trackName.hasPrefix("Click ") || stem.trackName == "Regência" || stem.trackName.hasPrefix("Regência ")
                let gain = internalTrack && overview.peak > 0 ? pow(10, -1.0 / 20) / overview.peak : 1
                arrangement.tracks[job.track].clips.append(AudioClip(id: UUID(), name: stem.fileName, startTime: job.start, duration: stem.duration, waveform: overview.waveform, audioFile: AudioFile(path: job.relative), gain: gain, waveformChannels: overview.channels))
            }
            // Use actual placed intervals: adding the append offset in a different
            // order can otherwise leave the last clip a fraction beyond the song.
            arrangement.duration = max(arrangement.duration,
                arrangement.parts.map(\.endTime).max() ?? 0,
                arrangement.tracks.flatMap(\.clips).map { $0.startTime + $0.duration }.max() ?? 0)
            // Use the actual Hook Center audit, including Outros, instead of
            // classifying display names again or mistaking audio tracks for folders.
            for group in audit.groups {
                let members = group.tracks.compactMap { keys[$0.key] }
                guard !members.isEmpty else { continue }
                let folder = arrangement.tracks.first { existingFolders.contains($0.id) && js.objectForKeyedSubscript("groupKeyFromFolderName")!.call(withArguments: [$0.name])!.toString()! == group.key }
                let color = folder?.color ?? UInt32(group.colorHex.dropFirst(), radix: 16) ?? 0x55acbe
                let parent = folder?.id ?? UUID()
                if folder == nil { arrangement.tracks.append(Track(id: parent, name: group.name, role: .other, color: color)) }
                for index in members where arrangement.tracks[index].id != parent {
                    if arrangement.tracks[index].parentTrackID != parent {
                        arrangement.tracks[index].parentTrackID = parent
                        arrangement.tracks[index].patch = .masterGroup
                        arrangement.tracks[index].secondaryPatch = nil; arrangement.tracks[index].outputs = nil
                    }
                    // Appending media must keep colors chosen on existing tracks.
                    guard index >= existingTrackCount else { continue }
                    // Keep the folder saturated; new children use its softened hue.
                    let r = (color >> 16) & 255, g = (color >> 8) & 255, b = color & 255
                    func soft(_ value: UInt32) -> UInt32 { value + (255 - value) * 28 / 100 }
                    arrangement.tracks[index].color = soft(r) << 16 | soft(g) << 8 | soft(b)
                }
            }
            let children = Dictionary(grouping: arrangement.tracks.filter { $0.parentTrackID != nil }, by: { $0.parentTrackID! })
            let roots = arrangement.tracks.filter { $0.parentTrackID == nil }
            let percussionIDs = Set(roots.filter { js.objectForKeyedSubscript("groupKeyFromFolderName")!.call(withArguments: [$0.name])!.toString()! == "percussivo" }.map(\.id))
            arrangement.tracks = (roots.filter { !percussionIDs.contains($0.id) } + roots.filter { percussionIDs.contains($0.id) })
                .flatMap { [$0] + (children[$0.id] ?? []) }
            project.songs[0] = arrangement
            project.updatedAt = ISO8601DateFormatter().string(from: Date())
            try project.validate()
            return project
        } catch { try? fm.removeItem(at: media); throw error }
    }
}
