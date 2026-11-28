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
struct ImportSourceFile: Sendable {
    enum Payload: Sendable { case audio, lyrics(JLLyricsDocument), video(TrackKind) }
    var url: URL
    var name: String
    var duration: Double
    var payload: Payload = .audio
    var isAudio: Bool { if case .audio = payload { return true }; return false }
}
struct ImportSourceFolder: Sendable {
    var url: URL
    var files: [ImportSourceFile]
    var regionData: MultitrackRegionData? = nil
    var accessRoot: URL? = nil
    var drawer: MultitrackDrawerData? = nil
}

struct MultitrackDrawerData: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let folder: String
        let offset: Double
        let cue: Double
        let data: MultitrackRegionData
        var cueID: UUID? = nil
        var cueName: String? = nil
        var cueColor: UInt32? = nil
    }
    let version: Int
    let name: String
    let duration: Double
    let color: UInt32?
    let uppercaseName: Bool?
    let entries: [Entry]
    var pitchSemitones: Int? = nil

    var leadingOffset: Double { min(0, entries.map { $0.offset - $0.data.region.startTime }.min() ?? 0) }
    var occupiedEnd: Double {
        max(duration, entries.map { $0.offset - $0.data.region.startTime + $0.data.arrangement.duration }.max() ?? 0)
    }
    func validate() throws {
        guard version == 2, duration.isFinite, duration > 0, !entries.isEmpty,
              (-12...12).contains(pitchSemitones ?? 0),
              Set(entries.map(\.folder)).count == entries.count else {
            throw ProjectError.invalid("Invalid Multitrack drawer data.")
        }
        for entry in entries {
            try entry.data.validate()
            guard MultitrackRegionData.isFilename(entry.folder), entry.offset.isFinite, entry.offset >= 0,
                  entry.cue.isFinite, entry.cue >= 0, entry.cue < duration,
                  entry.offset + entry.data.region.endTime - entry.data.region.startTime <= duration + 1e-6 else {
                throw ProjectError.invalid("Invalid song in Multitrack drawer.")
            }
        }
    }
}

struct MultitrackRegionData: Codable, Sendable {
    struct RenderedStem: Codable, Sendable {
        struct Item: Codable, Sendable {
            let offset: Double
            let duration: Double
            let rate: Double
            var pitchSemitones: Double? = nil
        }
        let file: String
        let track: UUID
        let items: [Item]
    }
    let version: Int
    let project: Project
    let renderedStems: [RenderedStem]
    let lyricsFiles: [String]
    var tunerUnbaked: Bool? = nil

    var arrangement: Song { project.songs[0] }
    var region: Part { arrangement.parts[0] }

    static let prefix = ".jldata-"
    static func isManifest(_ name: String) -> Bool { name.lowercased().hasPrefix(prefix) }
    static func isFilename(_ filename: String) -> Bool {
        !filename.isEmpty && filename != "." && filename != ".." &&
        !filename.contains("/") && !filename.contains("\\") && !filename.contains(":")
    }

    static func read(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (1...32 * 1024 * 1024).contains(values.fileSize ?? 0) else {
            throw ProjectError.invalid("Invalid Multitrack region data.")
        }
        let data = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try data.validate()
        return data
    }
    func validate() throws {
        try project.validate()
        guard version == 1, project.songs.count == 1, arrangement.parts.count == 1,
              renderedStems.allSatisfy({ stem in
                  Self.isFilename(stem.file) && arrangement.tracks.contains { $0.id == stem.track } &&
                  stem.items.allSatisfy { $0.offset.isFinite && $0.duration.isFinite && $0.duration > 0 && $0.rate.isFinite && $0.rate > 0 && (-12...12).contains($0.pitchSemitones ?? 0) }
              }),
              lyricsFiles.allSatisfy(Self.isFilename),
              arrangement.tracks.flatMap(\.clips).allSatisfy({ clip in
                  if let file = clip.audioFile { return file.path.hasPrefix("Videos/") && Self.isFilename(String(file.path.dropFirst(7))) }
                  return clip.text != nil
              }) else { throw ProjectError.invalid("Invalid Multitrack region data.") }
    }

    fileprivate static func explicitTransportPitchTargets(song: Song, region: Part, tracks: [Track]) -> [UUID]? {
        guard region.pitchTrackIDs != nil || region.pitchGroupIDs != nil else { return nil }
        let selected = song.pitchTargets(region)
        let hierarchy = TrackHierarchy(song.tracks)
        return tracks.filter {
            $0.kind == .standard && (selected.tracks.contains($0.id) || selected.groups.contains($0.id) ||
                !selected.groups.isDisjoint(with: hierarchy.ancestors(of: $0.id)))
        }.map(\.id)
    }

    static func snapshot(song: Song, region: Part, tracks: [Track],
                         renderedStems: [RenderedStem], lyricsFiles: [String], fullItems: Bool = false,
                         tunerUnbaked: Bool = false, printedRateChange: Bool = false) throws -> Self {
        let includesTempoMarkers = !printedRateChange && !renderedStems.contains { stem in
            stem.items.contains { abs($0.rate - 1) > 1e-7 }
        }
        let origin = region.startTime
        let printedItems = fullItems ? renderedStems.flatMap(\.items) : []
        var first = min(origin, tracks.flatMap(\.clips).map(\.startTime).min() ?? origin,
                        origin + (printedItems.map(\.offset).min() ?? 0))
        let trackIDs = Set(tracks.map(\.id))
        var project = Project.empty(name: region.name)
        var part = region
        part.parentRegionID = nil
        part.multiLoops = nil
        if tunerUnbaked {
            part.pitchTrackIDs = explicitTransportPitchTargets(song: song, region: region, tracks: tracks)
            part.pitchGroupIDs = part.pitchTrackIDs == nil ? nil : []
        } else {
            part.pitchTrackIDs = region.pitchTrackIDs?.filter(trackIDs.contains)
            part.pitchGroupIDs = region.pitchGroupIDs?.filter(trackIDs.contains)
        }
        var snapshot = project.songs[0]
        snapshot.bpm = song.bpm
        snapshot.beatsPerBar = song.beatsPerBar; snapshot.beatUnit = song.beatUnit
        snapshot.timeSettings = song.timeSettings
        let root = fullItems ? song.parts.first { $0.id == region.parentRegionID } : nil
        let siblings = root.map { parent in song.parts.filter { $0.parentRegionID == parent.id } } ?? []
        let siblingIDs = Set(siblings.map(\.id))
        var markers = (song.markers ?? []).filter { marker in
            guard marker.sourceRegionID == nil, includesTempoMarkers || !marker.isTempo else { return false }
            if let root {
                guard marker.position >= root.startTime, marker.position < root.endTime else { return false }
                if let owner = marker.regionOwnerID, siblingIDs.contains(owner) { return owner == region.id }
                if let owner = marker.regionOwnerID, owner != root.id { return false }
                let owner = song.dominantUnifiedOwner(at: marker.position, end: marker.position + 1e-6, group: root.id)
                    ?? siblings.min(by: { song.playbackRegionStart($0) < song.playbackRegionStart($1) })?.id
                return owner == region.id
            }
            return marker.position >= origin && marker.position < region.endTime &&
                (marker.regionOwnerID == nil || marker.regionOwnerID == region.id || marker.regionOwnerID == region.parentRegionID)
        }
        first = min(first, markers.map(\.position).min() ?? first)
        let shift = -first
        part.startTime += shift; part.endTime += shift
        snapshot.parts = [part]
        if includesTempoMarkers, !markers.contains(where: { $0.isTempo && abs($0.position - origin) < 1e-7 }) {
            let section = song.tempoSection(at: origin)
            markers.append(TimelineMarker(id: UUID(), name: "TEMPO", position: origin, color: 0x999999,
                tempoBPM: section.bpm, tempoBeats: section.beats, tempoUnit: section.unit,
                tempoTimebase: .global, tempoPlaybackRate: section.audioRate(baseBPM: song.bpm)))
        }
        let markerIDs = Set(markers.map(\.id))
        snapshot.markers = markers.map { source in
            var marker = source
            marker.position += shift; marker.regionOwnerID = part.id
            marker.unifiedRegionID = nil
            if marker.isTempo { marker.tempoPlaybackRate = song.tempoPlaybackRate(for: source) }
            if !fullItems, let target = marker.automaticSectionTargetID, !markerIDs.contains(target) {
                marker.automaticSectionTargetID = nil; marker.automaticSectionRepeatCount = nil
            }
            return marker
        }
        snapshot.tracks = tracks.map { source in
            var track = source
            track.audioFile = nil; track.clickSound = nil
            track.programChanges = source.programChanges?.filter {
                $0.position >= origin && $0.position < region.endTime
            }.map { marker in
                var marker = marker
                marker.position += shift
                return marker
            }
            if track.parentTrackID.map({ !trackIDs.contains($0) }) == true {
                let outputs = track.outputPatches.filter { $0 != .masterGroup }
                track.parentTrackID = nil; track.outputs = outputs.isEmpty ? [.master] : outputs
                track.patch = nil; track.secondaryPatch = nil
            }
            if track.stereoLink.map({ !trackIDs.contains($0.partner) }) == true { track.stereoLink = nil }
            if var routing = track.routing {
                if routing.mainReceiveSlot != nil { routing.receives = routing.receives.map { $0.flatMap { trackIDs.contains($0) ? $0 : nil } } }
                else { routing.receives = routing.receives.filter { $0.map(trackIDs.contains) ?? false } }
                routing.transmitters = routing.transmitters.filter { $0.map(trackIDs.contains) ?? false }
                routing.removeUnusedSendSettings()
                track.routing = routing
            }
            track.automation?.mapTimelineTimes { max(0, $0 + shift) }
            track.clips = track.clips.map { source in
                var item = source
                item.startTime += shift
                item.fadeTimelineStart = item.fadeTimelineStart.map { max(0, $0 + shift) }
                item.regionOwnerID = part.id
                item.tempoRateReferences = item.tempoRateReferences?.filter { markerIDs.contains($0.markerID) }
                item.separatedStemTracks = nil
                return item
            }
            return track
        }
        snapshot.duration = max(0.01, part.endTime, snapshot.tracks.flatMap(\.clips).map { $0.startTime + $0.duration }.max() ?? 0,
                                part.startTime + (printedItems.map { $0.offset + $0.duration }.max() ?? 0),
                                snapshot.markers?.map(\.position).max() ?? 0)
        project.songs = [snapshot]
        try project.validate()
        let stems = renderedStems.map { stem in
            RenderedStem(file: stem.file, track: stem.track, items: stem.items.map { item in
                RenderedStem.Item(offset: item.offset, duration: item.duration, rate: item.rate)
            })
        }
        return Self(version: 1, project: project, renderedStems: stems, lyricsFiles: lyricsFiles, tunerUnbaked: tunerUnbaked ? true : nil)
    }
}

struct StemScan: Sendable { var folders: [ImportSourceFolder]; var suggestions: [ImportSuggestion]; var warnings: [String] }
struct ImportAudit: Decodable {
    struct Stem: Decodable { var filePath: String; var fileName: String; var trackName: String; var trackKey: String; var duration: Double; var takeVolume: Double }
    struct Region: Decodable { var name: String; var start: Double; var end: Double; var files: [Stem]; var folderPath: String }
    struct Channel: Decodable { var name: String; var key: String; var groupKey: String }
    struct Group: Decodable { var key: String; var name: String; var colorHex: String; var tracks: [Channel] }
    var songs: [Region]; var tracks: [Channel]; var groups: [Group]
}

enum GridMediaFileFilter {
    static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath else { return false }
        let ext = url.pathExtension.lowercased()
        if ["jllyrics", "mid", "midi"].contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .image)
    }
}

/// Runs on a worker task. Audio is read in bounded buffers, never on the UI or audio thread.
enum AudioDropLayout: String, CaseIterable, Sendable { case separateTracks, sameTrack, stacked }

enum StemProjectImporter {
    struct DroppedAudio: Sendable { let tracks: [Track]; let folders: [URL]; var folder: URL { folders[0] } }

    static func gridDropRows(in tracks: [Track], startingAt index: Int, limit: Int) -> [Int] {
        guard tracks.indices.contains(index), limit > 0 else { return [] }
        var rows = [index]
        for next in (index + 1)..<tracks.count {
            guard rows.count < limit else { break }
            if tracks[next].kind == .standard { rows.append(next) }
        }
        return rows
    }

    static func readMIDIItem(_ url: URL, start: Double) throws -> AudioClip {
        let unreadable = ProjectError.invalid("Could not read the MIDI file.")
        var source: MusicSequence?
        guard NewMusicSequence(&source) == noErr, let source else { throw unreadable }
        defer { DisposeMusicSequence(source) }
        guard MusicSequenceFileLoad(source, url as CFURL, .midiType, []) == noErr else { throw unreadable }
        var count: UInt32 = 0
        MusicSequenceGetTrackCount(source, &count)
        var notes: [MIDINote] = [], duration = 0.0
        for index in 0..<count {
            var track: MusicTrack?
            var iterator: MusicEventIterator?
            guard MusicSequenceGetIndTrack(source, index, &track) == noErr, let track,
                  NewMusicEventIterator(track, &iterator) == noErr, let iterator else { continue }
            defer { DisposeMusicEventIterator(iterator) }
            var hasEvent = DarwinBoolean(false)
            while MusicEventIteratorHasCurrentEvent(iterator, &hasEvent) == noErr, hasEvent.boolValue {
                var beat: MusicTimeStamp = 0, kind: MusicEventType = 0, size: UInt32 = 0
                var data: UnsafeRawPointer?
                MusicEventIteratorGetEventInfo(iterator, &beat, &kind, &data, &size)
                if kind == kMusicEventType_MIDINoteMessage, let data, size >= MemoryLayout<MIDINoteMessage>.size {
                    let note = data.load(as: MIDINoteMessage.self)
                    var begin = 0.0, end = 0.0
                    if note.velocity > 0, MusicSequenceGetSecondsForBeats(source, beat, &begin) == noErr,
                       MusicSequenceGetSecondsForBeats(source, beat + Double(note.duration), &end) == noErr,
                       begin.isFinite, end.isFinite, begin >= 0, end > begin {
                        notes.append(.init(start: begin * 2, length: (end - begin) * 2, pitch: Int(note.note),
                                           velocity: Int(note.velocity), channel: Int(note.channel) + 1))
                        duration = max(duration, end)
                    }
                }
                MusicEventIteratorNextEvent(iterator)
            }
        }
        guard !notes.isEmpty else { throw ProjectError.invalid("The MIDI file contains no notes.") }
        var item = AudioClip(id: UUID(), name: url.deletingPathExtension().lastPathComponent, startTime: start, duration: duration)
        item.midi = MIDIItem(notes: notes)
        return item
    }

    private struct DroppedSource {
        let url: URL
        let kind: TrackKind
        let duration: Double
        var midi: MIDIItem? = nil
    }
    private static func droppedSources(_ urls: [URL]) throws -> [DroppedSource] {
        var seen = Set<URL>(), sources: [DroppedSource] = []
        for url in urls {
            try Task.checkCancellation()
            guard seen.insert(url.standardizedFileURL).inserted else { continue }
            guard url.isFileURL else { continue }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
            guard values.isRegularFile == true else { continue }
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
            if ["mid", "midi"].contains(url.pathExtension.lowercased()) {
                if let item = try? readMIDIItem(url, start: 0) {
                    sources.append(DroppedSource(url: url, kind: .standard, duration: item.duration, midi: item.midi))
                }
                continue
            }
            let knownAudio = ["wav", "wave", "aif", "aiff", "mp3", "m4a", "aac", "caf", "flac"].contains(url.pathExtension.lowercased())
            let image = type?.conforms(to: .image) == true
            guard knownAudio || image || type?.conforms(to: .audio) == true || type?.conforms(to: .movie) == true else {
                continue
            }
            if image {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
                      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else {
                    continue
                }
                sources.append(DroppedSource(url: url, kind: .video, duration: 10))
                continue
            }
            let asset = AVURLAsset(url: url)
            let video = !asset.tracks(withMediaType: .video).isEmpty
            let duration: Double
            if video { duration = asset.duration.seconds }
            else {
                guard FileManager.default.isReadableFile(atPath: url.path) else { throw CocoaError(.fileReadNoPermission) }
                guard let audio = try? AVAudioFile(forReading: url) else { continue }
                duration = Double(audio.length) / audio.processingFormat.sampleRate
            }
            guard duration.isFinite, duration > 0 else { continue }
            sources.append(DroppedSource(url: url, kind: video ? .video : .standard, duration: duration))
        }
        return sources
    }
    static func prepareDroppedAudio(_ urls: [URL], start: Double, destinationTracks: [UUID], destination: URL, layout: AudioDropLayout = .separateTracks, gap: Double = 0, destinationKind: TrackKind? = nil, videoTrackAvailable: Bool = false, deferWaveform: Bool = false,
                                    progress: (@Sendable (Int, Int, String) -> Void)? = nil) throws -> DroppedAudio {
        guard start.isFinite, start >= 0, gap.isFinite, (0...60).contains(gap), !urls.isEmpty else { throw ProjectError.invalid("No media files to import") }
        guard destinationKind != .programChange else { throw ProjectError.invalid("Program Change tracks accept only program markers") }
        // Validate the entire batch before making any project directory or copying media.
        let sources = try droppedSources(urls)
        guard !sources.isEmpty else { return DroppedAudio(tracks: [], folders: []) }
        if sources.contains(where: { $0.kind != .video }) || layout == .stacked {
            guard destinationKind == nil || destinationKind == .standard else { throw ProjectError.invalid("Audio files must be dropped on a standard audio track") }
        }
        let fm = FileManager.default
        var audioNames = MediaFileNames(directory: destination.deletingLastPathComponent().appendingPathComponent("Stems"))
        var videoNames = MediaFileNames(directory: destination.deletingLastPathComponent().appendingPathComponent("Videos"))
        let projectDirectory = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        var audioMedia = ExistingProjectMedia(directory: projectDirectory.appendingPathComponent("Stems"))
        var videoMedia = ExistingProjectMedia(directory: projectDirectory.appendingPathComponent("Videos"))
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
                let itemName = url.deletingPathExtension().lastPathComponent
                let itemStart = layout == .sameTrack ? cursor : start
                var clip: AudioClip
                if let midi = source.midi {
                    clip = AudioClip(id: UUID(), name: itemName, startTime: itemStart, duration: source.duration)
                    clip.midi = midi
                } else {
                    let existing = try (isVideo ? videoMedia : audioMedia).identical(to: url)
                    let copied: URL
                    if let existing {
                        copied = existing
                    } else {
                        let name = isVideo ? videoNames.allocate(url.lastPathComponent) : audioNames.allocate(url.lastPathComponent)
                        let folder = projectDirectory.appendingPathComponent((isVideo ? "Videos" : "Stems"), isDirectory: true)
                        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                        copied = folder.appendingPathComponent(name)
                        try fm.copyItem(at: url, to: copied); folders.append(copied)
                        if isVideo { try videoMedia.register(copied) } else { try audioMedia.register(copied) }
                    }
                    let basePath = (projectDirectory.path as NSString).resolvingSymlinksInPath
                    let copiedPath = (copied.path as NSString).resolvingSymlinksInPath
                    guard copiedPath.hasPrefix(basePath + "/") else { throw ProjectError.invalid("Imported media must stay inside the project folder") }
                    let mediaPath = String(copiedPath.dropFirst(basePath.count + 1))
                    if isVideo && !AVURLAsset(url: copied).tracks(withMediaType: .audio).isEmpty { _ = try AudioFileRead.openMedia(copied) }
                    let overview = (isVideo || deferWaveform) ? (waveform: [Double](), peak: 0.0, channels: [[Double]]()) : try audioOverview(copied, duration: source.duration)
                    clip = AudioClip(id: UUID(), name: itemName, startTime: itemStart, duration: source.duration,
                                         waveform: overview.waveform, audioFile: AudioFile(path: mediaPath), waveformChannels: overview.channels)
                }
                if layout != .separateTracks, !tracks.isEmpty { tracks[0].clips.append(clip) }
                else {
                    let trackID = tracks.count < destinationTracks.count ? destinationTracks[tracks.count] : UUID()
                    let kind = index == 0 ? destinationKind : nil
                    var track = Track(id: trackID, name: isVideo && kind?.isText == true ? (kind?.title ?? itemName) : itemName,
                                      role: TrackRole(rawValue: isVideo && kind != .video ? (kind?.rawValue ?? "other") : "other"),
                                      color: Track.defaultStandardColor)
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
        let candidates = try urls.flatMap { root -> [(URL, URL)] in
            let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard !children.contains(where: { MultitrackRegionData.isManifest($0.lastPathComponent) }) else { return [(root, root)] }
            let exportedRegions = try children.filter { child in
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
                return (try? fm.contentsOfDirectory(atPath: child.path).contains(where: MultitrackRegionData.isManifest)) == true
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            return exportedRegions.isEmpty ? [(root, root)] : exportedRegions.map { ($0, root) }
        }
        let expanded = try candidates.flatMap { url, accessRoot -> [(URL, URL, MultitrackRegionData?, MultitrackDrawerData?)] in
            let names = try fm.contentsOfDirectory(atPath: url.path).filter(MultitrackRegionData.isManifest)
            guard names.count <= 1 else { throw ProjectError.invalid("Multiple Multitrack manifests in " + url.lastPathComponent) }
            guard let name = names.first else { return [(url, accessRoot, nil, nil)] }
            let manifest = url.appendingPathComponent(name)
            let properties = try manifest.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard properties.isSymbolicLink != true, properties.isRegularFile == true,
                  (1...32 * 1024 * 1024).contains(properties.fileSize ?? 0) else {
                throw ProjectError.invalid("Invalid Multitrack region data.")
            }
            let bytes = try Data(contentsOf: manifest)
            struct Version: Decodable { let version: Int }
            if try JSONDecoder().decode(Version.self, from: bytes).version == 2 {
                let drawer = try JSONDecoder().decode(MultitrackDrawerData.self, from: bytes)
                try drawer.validate()
                return drawer.entries.map { (url.appendingPathComponent($0.folder, isDirectory: true), accessRoot, $0.data, drawer) }
            }
            let data = try JSONDecoder().decode(MultitrackRegionData.self, from: bytes)
            try data.validate()
            return [(url, accessRoot, data, nil)]
        }
        for (url, accessRoot, regionData, drawer) in expanded {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ProjectError.invalid("Select real song folders: \(url.lastPathComponent)") }
            guard visited.insert(url.standardizedFileURL).inserted else { continue }
            let entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            var files: [ImportSourceFile] = []
            names.append(url.lastPathComponent)
            for file in entries {
                guard try file.resourceValues(forKeys: [.isHiddenKey]).isHidden != true else { continue }
                let ext = file.pathExtension.lowercased()
                let isAudio = ["wav", "wave", "aif", "aiff", "mp3"].contains(ext)
                let isLyrics = ext == "jllyrics"
                let isVideo = UTType(filenameExtension: ext)?.conforms(to: .movie) == true
                guard isAudio || isLyrics || (isVideo && regionData == nil) else { continue }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                do {
                    if isLyrics {
                        let document = try JSONDecoder().decode(JLLyricsDocument.self, from: Data(contentsOf: file))
                        let clips = try document.clips(at: regionData?.region.startTime ?? 0)
                        let duration = clips.map { $0.startTime + $0.duration }.max() ?? 0
                        files.append(.init(url: file, name: file.lastPathComponent, duration: duration, payload: .lyrics(document)))
                        continue
                    }
                    if isVideo {
                        let asset = AVURLAsset(url: file)
                        let duration = asset.duration.seconds
                        guard duration.isFinite, duration > 0, !asset.tracks(withMediaType: .video).isEmpty else { continue }
                        let name = file.deletingPathExtension().lastPathComponent
                        let prefixed = name.range(of: #"^teleprompter[ _-]*([12])(?:[^0-9]|$)"#,
                            options: [.regularExpression, .caseInsensitive])
                        let kind: TrackKind = prefixed.map { name[$0].contains("2") ? .teleprompt2 : .teleprompt } ?? .standard
                        files.append(.init(url: file, name: file.lastPathComponent, duration: duration, payload: .video(kind)))
                        continue
                    }
                    let duration: Double
                    #if os(iOS)
                    var coordinationError: NSError?
                    var read: Result<Double, Error>?
                    NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { available in
                        read = Result {
                            let audio = try AVAudioFile(forReading: available)
                            return Double(audio.length) / audio.processingFormat.sampleRate
                        }
                    }
                    if let coordinationError { throw coordinationError }
                    guard let read else { throw ProjectError.invalid("Could not access the selected file.") }
                    duration = try read.get()
                    #else
                    let audio = try AVAudioFile(forReading: file)
                    duration = Double(audio.length) / audio.processingFormat.sampleRate
                    #endif
                    guard duration.isFinite, duration > 0 else { throw ProjectError.invalid("Invalid duration") }
                    // Duration comes from the container; scanning names must not decode every sample.
                    files.append(ImportSourceFile(url: file, name: file.lastPathComponent, duration: duration))
                    names.append(file.deletingPathExtension().lastPathComponent)
                } catch is CancellationError { throw CancellationError() }
                catch { warnings.append("\(file.lastPathComponent): \(error.localizedDescription)") }
            }
            if files.isEmpty && regionData == nil {
                let containsProject = entries.contains { file in
                    file.pathExtension.lowercased() == "jl" &&
                        (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
                let reason = containsProject ? "contains a CatLive project" : "no readable WAV, AIFF or MP3 files"
                warnings.append("\(url.lastPathComponent): \(reason)")
            } else {
                folders.append(ImportSourceFolder(url: url, files: files, regionData: regionData, accessRoot: accessRoot, drawer: drawer))
            }
        }
        guard !folders.isEmpty else { throw ProjectError.invalid(warnings.joined(separator: "\n")) }
        let js = try context()
        let suggestions = try call("suggestImportRemovals", args: [names, ["limit": 12]], context: js, as: [ImportSuggestion].self)
        return StemScan(folders: folders, suggestions: suggestions, warnings: [])
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
    public static func populateChannelOverviews(_ source: Project, directory: URL,
                                                externalOverviewIsCurrent: ((URL) -> Bool)? = nil,
                                                onUnreadable: ((String, Error) -> Void)? = nil) throws -> Project {
        var project = source
        var cache: [String: [[Double]]] = [:]
        var externalOverviews: [String: Bool] = [:]
        var unreadable = Set<String>()
        for song in project.songs.indices {
            for track in project.songs[song].tracks.indices {
                guard project.songs[song].tracks[track].kind == .standard else { continue }
                for item in project.songs[song].tracks[track].clips.indices {
                    try Task.checkCancellation()
                    let clip = project.songs[song].tracks[track].clips[item]
                    guard !clip.isProjectionMedia, clip.waveformChannels == nil, let file = clip.audioFile else { continue }
                    if unreadable.contains(file.path) { continue }
                    // Documents can use separate peak files instead of embedding
                    // a second waveform in every repeated instance of a source.
                    if clip.waveform.isEmpty, let externalOverviewIsCurrent {
                        let current: Bool
                        if let cached = externalOverviews[file.path] { current = cached }
                        else {
                            current = externalOverviewIsCurrent(directory.projectMedia(file.path))
                            externalOverviews[file.path] = current
                        }
                        if current { continue }
                    }
                    if cache[file.path] == nil {
                        let url = directory.projectMedia(file.path)
                        guard FileManager.default.fileExists(atPath: url.path) else { continue }
                        do { cache[file.path] = try audioOverview(url, duration: clip.duration).channels }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            if let onUnreadable {
                                unreadable.insert(file.path)
                                onUnreadable(file.path, error)
                                continue
                            }
                            // CoreAudio errors omit the source name. Preserve its
                            // domain/code while identifying the failing project asset.
                            let underlying = error as NSError
                            var info = underlying.userInfo
                            info[NSUnderlyingErrorKey] = underlying
                            info[NSFilePathErrorKey] = url.path
                            info[NSURLErrorKey] = url
                            info[NSLocalizedDescriptionKey] = file.path + "\n" + underlying.localizedDescription
                            throw NSError(domain: underlying.domain, code: underlying.code, userInfo: info)
                        }
                    }
                    project.songs[song].tracks[track].clips[item].waveformChannels = cache[file.path]
                }
            }
        }
        return project
    }
    private typealias MediaOverview = (waveform: [Double], peak: Double, channels: [[Double]])
    private struct MediaImportJob {
        let source: URL, copy: URL?
        let relative: String
        let stem: ImportAudit.Stem
        let track: Int
        let start: Double
        let duration: Double
        let fileName: String
        let renderedRegion: UUID?
        let renderedSourceTrack: UUID?
        let pitchSemitones: Double?
    }
    /// Only a few bounded decode buffers exist at once. The result slots retain
    /// input order even when a shorter file finishes before an earlier file.
    private static func prepareMedia(_ jobs: [MediaImportJob], created: inout [URL], progress: (@Sendable (Int, Int, String) -> Void)?) throws -> [Result<MediaOverview, Error>] {
        try Task.checkCancellation()
        let lock = NSLock()
        var next = 0, completed = 0, failure: Error?
        var results = Array<Result<MediaOverview, Error>?>(repeating: nil, count: jobs.count)
        var written: [URL] = []
        defer { created.append(contentsOf: written) }
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
                    if let copy = job.copy {
                        try FileManager.default.copyItem(at: job.source, to: copy)
                        lock.lock(); written.append(copy); lock.unlock()
                    }
                    let overview = Result { try audioOverview(job.copy ?? job.source, duration: job.duration) }
                    if case .failure(let error) = overview {
                        if error is CancellationError { throw error }
                        if let copy = job.copy { try FileManager.default.removeItem(at: copy) }
                    }
                    lock.lock(); results[index] = overview; completed += 1
                    let now = ProcessInfo.processInfo.systemUptime
                    if completed == jobs.count || now - lastProgress >= 0.1 {
                        lastProgress = now; progress?(completed, jobs.count, job.stem.fileName)
                    }
                    lock.unlock()
                } catch {
                    let reported: Error
                    if error is CancellationError { reported = error }
                    else {
                        // Review already read the container header. Decoding its
                        // samples can still fail; retain the original source path
                        // because the incomplete destination is removed on rollback.
                        let underlying = error as NSError
                        var info = underlying.userInfo
                        info[NSUnderlyingErrorKey] = underlying
                        info[NSFilePathErrorKey] = job.source.path
                        info[NSURLErrorKey] = job.source
                        info[NSLocalizedDescriptionKey] = job.source.path + "\n" + underlying.localizedDescription
                        reported = NSError(domain: underlying.domain, code: underlying.code, userInfo: info)
                    }
                    lock.lock(); if failure == nil { failure = reported }; lock.unlock(); return
                }
            }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        return try results.map { guard let result = $0 else { throw ProjectError.invalid("Missing imported audio") }; return result }
    }
    private static func restoreMultitrack(_ data: MultitrackRegionData, folder: URL, accessRoot: URL?, arrangement: inout Song,
                                          regionIndex: Int, directory: URL, lyrics: [JLLyricsDocument], drawerMarkerIDs: [UUID: UUID]?,
                                          renderedTracks: [UUID: Set<UUID>],
                                          videoNames: inout MediaFileNames, copied: inout [URL], copyMedia: Bool,
                                          progress: (@Sendable (Int, Int, String) -> Void)?,
                                          onUnreadable: ((String, Error) -> Void)?) throws {
        let fm = FileManager.default
        let snapshot = data.arrangement
        let origin = arrangement.parts[regionIndex].startTime
        let regionID = arrangement.parts[regionIndex].id
        let access = accessRoot ?? folder
        let scoped = access.startAccessingSecurityScopedResource()
        defer { if scoped { access.stopAccessingSecurityScopedResource() } }

        var targets: [UUID: UUID] = [:]
        for track in snapshot.tracks {
            let existing = arrangement.tracks.first {
                $0.id == track.id || (track.fixedName != nil && $0.kind == track.kind)
            }
            targets[track.id] = existing?.id ?? track.id
        }
        func insertTrack(_ track: Track, into arrangement: inout Song) {
            if track.fixedName != nil {
                let firstStandard = arrangement.tracks.firstIndex { $0.fixedName == nil } ?? arrangement.tracks.count
                arrangement.tracks.insert(track, at: firstStandard)
            } else { arrangement.tracks.append(track) }
        }
        let markers = snapshot.markers ?? []
        let markerIDs = drawerMarkerIDs ?? Dictionary(uniqueKeysWithValues: markers.map { ($0.id, UUID()) })
        if arrangement.markers == nil { arrangement.markers = [] }
        for var marker in markers {
            marker.id = markerIDs[marker.id]!
            marker.position += origin
            marker.regionOwnerID = regionID
            marker.automaticSectionTargetID = marker.automaticSectionTargetID.flatMap { markerIDs[$0] }
            if marker.automaticSectionTargetID == nil { marker.automaticSectionRepeatCount = nil }
            arrangement.markers!.append(marker)
        }

        var part = data.region
        part.id = regionID
        part.startTime += origin; part.endTime += origin
        let pitch = snapshot.pitchTargets(data.region)
        part.pitchGroupIDs = []
        arrangement.parts[regionIndex] = part

        var copiedAssets: [String: String] = [:]
        var rawClips: [UUID: [AudioClip]] = [:]
        let lyricsKinds = Set(lyrics.map(\.kind))
        let total = snapshot.tracks.flatMap(\.clips).count
        var count = 0
        func importedVideo(_ filename: String) throws -> String {
            guard MultitrackRegionData.isFilename(filename) else { throw ProjectError.invalid("Invalid Multitrack media name.") }
            let source = folder.appendingPathComponent(filename)
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ProjectError.invalid("Multitrack media is unavailable.") }
            if !copyMedia { return try LinkedStemMedia.shared.reference(to: source, accessRoot: access, video: true) }
            let allocated = videoNames.allocate(filename)
            let target = directory.appendingPathComponent("Videos", isDirectory: true).appendingPathComponent(allocated)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
            copied.append(target)
            return "Videos/" + allocated
        }
        for track in snapshot.tracks {
            for var item in track.clips {
                try Task.checkCancellation()
                count += 1; progress?(count, total, item.name)
                if item.audioFile == nil && lyricsKinds.contains(track.kind) { continue }
                if let audio = item.audioFile {
                    let filename = String(audio.path.dropFirst(7))
                    if copiedAssets[filename] == nil {
                        do {
                            copiedAssets[filename] = try importedVideo(filename)
                        } catch { onUnreadable?(folder.appendingPathComponent(filename).path, error); continue }
                    }
                    item.audioFile = copiedAssets[filename].map { AudioFile(path: $0) }
                }
                item.id = UUID(); item.startTime += origin; item.regionOwnerID = regionID
                item.fadeTimelineStart = item.fadeTimelineStart.map { $0 + origin }
                item.tempoRateReferences = item.tempoRateReferences?.compactMap { reference in
                    markerIDs[reference.markerID].map { ItemTempoReference(markerID: $0, rate: reference.rate) }
                }
                rawClips[track.id, default: []].append(item)
            }
        }
        let rawTargets = Set(rawClips.keys).union(snapshot.tracks.filter {
            !($0.programChanges?.isEmpty ?? true) || lyricsKinds.contains($0.kind)
        }.map(\.id))
        for source in snapshot.tracks where rawTargets.contains(source.id) {
            if let id = targets[source.id] {
                let clips = rawClips[source.id] ?? []
                let programChanges = source.programChanges?.map { marker in
                    var marker = marker
                    marker.id = UUID(); marker.position += origin
                    return marker
                }
                if let index = arrangement.tracks.firstIndex(where: { $0.id == id }) {
                    arrangement.tracks[index].clips += clips
                    if let programChanges, !programChanges.isEmpty {
                        arrangement.tracks[index].programChanges = (arrangement.tracks[index].programChanges ?? []) + programChanges
                    }
                } else {
                    var track = source
                    track.id = id; track.clips = clips; track.parentTrackID = nil
                    track.programChanges = programChanges
                    if source.outputPatches.contains(.masterGroup) {
                        let outputs = source.outputPatches.filter { $0 != .masterGroup }
                        track.outputs = outputs.isEmpty ? [.master] : outputs
                        track.patch = nil; track.secondaryPatch = nil
                    }
                    track.stereoLink = nil
                    if let routing = track.routing {
                        var mapped = TrackRouting(
                            receives: routing.receives.compactMap { $0.flatMap { rawTargets.contains($0) ? targets[$0] : nil } }.map(Optional.some),
                            transmitters: routing.transmitters.compactMap { $0.flatMap { rawTargets.contains($0) ? targets[$0] : nil } }.map(Optional.some))
                        for source in routing.transmitters.compactMap({ $0 }) where rawTargets.contains(source) {
                            if let destination = targets[source] {
                                mapped.setSendTap(routing.sendTap(to: source), to: destination)
                                mapped.setSendGain(routing.sendGain(to: source), to: destination)
                            }
                        }
                        track.routing = mapped
                    }
                    track.automation?.mapTimelineTimes { $0 + origin }
                    insertTrack(track, into: &arrangement)
                }
            }
        }
        for document in lyrics { try arrangement.insertLyrics(document, at: part.startTime, region: regionID) }
        if data.tunerUnbaked == true {
            let selected = MultitrackRegionData.explicitTransportPitchTargets(song: snapshot, region: data.region, tracks: snapshot.tracks)
            let mapped = selected.map { ids -> Set<UUID> in
                var destinations = Set<UUID>()
                for source in ids {
                    destinations.formUnion(renderedTracks[source] ?? [])
                    if rawTargets.contains(source), let id = targets[source] { destinations.insert(id) }
                }
                return destinations
            }
            arrangement.parts[regionIndex].pitchTrackIDs = mapped.map { ids in
                arrangement.tracks.compactMap { ids.contains($0.id) ? $0.id : nil }
            }
            arrangement.parts[regionIndex].pitchGroupIDs = mapped == nil ? nil : []
        } else {
            arrangement.parts[regionIndex].pitchTrackIDs = pitch.tracks.compactMap { id in
                rawClips[id] == nil ? nil : targets[id]
            }
        }
        arrangement.duration = max(arrangement.duration, origin + snapshot.duration)
    }

    static func build(scan: StemScan, remove: String, base: Project, destination: URL, progress: (@Sendable (Int, Int, String) -> Void)? = nil,
                      onUnreadable: ((String, Error) -> Void)? = nil, copyMedia: Bool = true) throws -> Project {
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
        var virtual: [[String: Any]] = [], sources: [String: [ImportSourceFile]] = [:]
        var supplemental: [String: [ImportSourceFile]] = [:]
        var sourceFolders: [String: ImportSourceFolder] = [:]
        for (index, folder) in scan.folders.enumerated() {
            let folderPath = "/\(index)/" + (try clean(folder.url.lastPathComponent, directory: true))
            sourceFolders[folderPath] = folder
            var entries: [[String: Any]] = [], used = Set<String>()
            var separateItems: [UUID: String] = [:]
            let metadata = folder.regionData
            let renderedByName = Dictionary((metadata?.renderedStems ?? []).map { ($0.file, $0) },
                                            uniquingKeysWith: { first, _ in first })
            let trackNames = Dictionary(uniqueKeysWithValues: (metadata?.arrangement.tracks ?? []).map { ($0.id, $0.name) })
            for file in folder.files where file.isAudio {
                let separated = renderedByName[file.name]
                if let separated, let shared = separateItems[separated.track] {
                    sources[folderPath + "/" + shared, default: []].append(file)
                    continue
                }
                let basename = folder.drawer == nil ? nil : separated.flatMap { trackNames[$0.track] }
                let candidate = try clean(basename.map { $0.replacingOccurrences(of: "/", with: "_") + ".wav" } ?? file.name, directory: false)
                var name = candidate
                if let separated {
                    var ordinal = 2
                    while used.contains(name.folding(options: [.caseInsensitive], locale: nil)) {
                        name = (candidate as NSString).deletingPathExtension + " " + String(ordinal) + "." + (candidate as NSString).pathExtension
                        ordinal += 1
                    }
                    separateItems[separated.track] = name
                }
                guard used.insert(name.folding(options: [.caseInsensitive], locale: nil)).inserted else { throw ProjectError.invalid("Cleaning creates duplicate file names: \(name)") }
                entries.append(["name": name, "duration": file.duration, "peakDb": NSNull()])
                sources[folderPath + "/" + name] = [file]
            }
            let other = folder.files.filter { !$0.isAudio }
            supplemental[folderPath] = other
            let audioEnd = folder.files.filter(\.isAudio).map(\.duration).max() ?? 0
            var videoTimes: [TrackKind: Double] = [:]
            var visualEnd = folder.regionData?.arrangement.duration ?? 0
            for media in other {
                switch media.payload {
                case .video(let kind):
                    videoTimes[kind, default: 0] += media.duration
                    visualEnd = max(visualEnd, videoTimes[kind, default: 0])
                case .lyrics: visualEnd = max(visualEnd, media.duration)
                case .audio: break
                }
            }
            if visualEnd > audioEnd {
                // The audit uses this duration for region spacing. No track or
                // media file is created for this synthetic entry.
                entries.append(["name": UUID().uuidString + ".wav", "duration": visualEnd, "peakDb": NSNull()])
            }
            virtual.append(["path": folderPath, "files": entries])
        }
        var project = base
        guard !project.songs.isEmpty else { throw ProjectError.invalid("Missing arrangement") }
        var arrangement = project.songs[0]
        let existingTrackCount = arrangement.tracks.count
        let oldEnd = max(arrangement.parts.map(\.endTime).max() ?? 0, arrangement.tracks.flatMap(\.clips).map { $0.startTime + $0.duration }.max() ?? 0)
        let offset = oldEnd
        let existingFolders = Set(arrangement.tracks.compactMap(\.parentTrackID)).union(arrangement.tracks.filter {
            $0.kind == .standard && $0.role == .other && $0.parentTrackID == nil && $0.clips.isEmpty && $0.name.trimmingCharacters(in: .whitespaces).hasPrefix("#") && !js.objectForKeyedSubscript("groupKeyFromFolderName")!.call(withArguments: [$0.name])!.toString()!.isEmpty
        }.map(\.id))
        let existingIndices = Dictionary(uniqueKeysWithValues: arrangement.tracks.enumerated().map { ($0.element.id, $0.offset) })
        let existingLayout: [[String: Any]] = arrangement.tracks.enumerated().filter { $0.element.kind == .standard && $0.element.role.rawValue != "vinhetas" }.map { index, track in
            ["index": index, "name": track.name, "isFolder": existingFolders.contains(track.id),
             "parentIndex": track.parentTrackID.flatMap { existingIndices[$0] } as Any? ?? NSNull()]
        }
        let audit = try call("analyzeImport", args: [virtual, existingLayout], context: js, as: ImportAudit.self)
        guard !audit.songs.isEmpty else { throw ProjectError.invalid("No songs found") }
        var rootAnchors: [UUID: UUID] = [:]
        var keys: [String: Int] = [:]
        for (index, track) in arrangement.tracks.enumerated() where track.kind == .standard && track.role.rawValue != "vinhetas" && !existingFolders.contains(track.id) {
            keys["existing:\(index)"] = index
            let key = js.objectForKeyedSubscript("canonicalExistingTrackKey")!.call(withArguments: [track.name])!.toString()!
            if keys[key] == nil { keys[key] = index }
            if keys["custom:" + key] == nil { keys["custom:" + key] = index }
        }
        let audioKeys = Set(audit.songs.flatMap(\.files).filter { sources[$0.filePath] != nil }.map(\.trackKey))
        func importedIcon(_ name: String) -> String {
            js.objectForKeyedSubscript("catLiveStemIcon")?.call(withArguments: [name])?.toString() ?? "png:Other/waveform"
        }
        for channel in audit.tracks where audioKeys.contains(channel.key) && keys[channel.key] == nil {
            let role: TrackRole = channel.name == "Click" ? .click : channel.name == "Guia" || channel.name == "Regência" ? .guide : channel.groupKey == "sanfonas" ? .accordion : channel.name.hasPrefix("Baixo") ? .bass : channel.groupKey == "teclados" ? .keys : channel.groupKey == "percussivo" ? .drums : channel.groupKey == "guitarras" ? .guitar : .other
            keys[channel.key] = arrangement.tracks.count
            arrangement.tracks.append(Track(id: UUID(), name: channel.name, role: role,
                instrumentIcon: importedIcon(channel.name), color: Track.defaultStandardColor))
        }
        // Allocate unique filenames and roll back only files owned by this import.
        let relativeFolder = "Stems"
        let media = destination.deletingLastPathComponent().appendingPathComponent(relativeFolder)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        var jobs: [MediaImportJob] = []
        var copiedVideo: [URL] = [], copiedAudio: [URL] = []
        var regionIndices: [Int] = []
        var drawerPlacement: [URL: (id: UUID, start: Double)] = [:]
        var drawerChildren: [String: (parent: UUID, cue: Double, entry: MultitrackDrawerData.Entry)] = [:]
        var drawerMarkerIDs: [UUID: [UUID: UUID]] = [:]
        do {
            var fileNames = MediaFileNames(directory: destination.deletingLastPathComponent().appendingPathComponent("Stems"))
            var previousAuditEnd = 0.0, occupiedEnd = offset
            for (songIndex, song) in audit.songs.enumerated() {
                let gap = max(0, song.start - previousAuditEnd)
                previousAuditEnd = song.end
                let folder = sourceFolders[song.folderPath]
                let metadata = folder?.regionData
                var origin = occupiedEnd + gap
                if let folder, let drawer = folder.drawer,
                   let child = drawer.entries.first(where: { $0.folder == folder.url.lastPathComponent }) {
                    let root = folder.url.deletingLastPathComponent()
                    let placement: (id: UUID, start: Double)
                    if let existing = drawerPlacement[root] { placement = existing }
                    else {
                        placement = (UUID(), origin - drawer.leadingOffset)
                        arrangement.parts.append(Part(id: placement.id, name: drawer.name, startTime: placement.start,
                            endTime: placement.start + drawer.duration, color: drawer.color, uppercaseName: drawer.uppercaseName,
                            pitchSemitones: drawer.pitchSemitones))
                        drawerPlacement[root] = placement
                        let markers = drawer.entries.flatMap { entry in
                            (entry.data.arrangement.markers ?? []).map(\.id) + (entry.cueID.map { [$0] } ?? [])
                        }
                        drawerMarkerIDs[placement.id] = Dictionary(markers.map { ($0, UUID()) }, uniquingKeysWith: { first, _ in first })
                        occupiedEnd = placement.start + drawer.occupiedEnd
                    }
                    origin = placement.start + child.offset - child.data.region.startTime
                    drawerChildren[song.folderPath] = (placement.id, placement.start + child.cue, child)
                } else { occupiedEnd = origin + song.end - song.start }
                regionIndices.append(arrangement.parts.count)
                let region = Part(id: UUID(), name: song.name, startTime: origin, endTime: origin + song.end - song.start,
                    color: [0x53be8c,0xddad54,0x7a93dd,0xbf79b8,0x55acbe][songIndex % 5])
                arrangement.parts.append(region)
                let renderedFiles = Dictionary((metadata?.renderedStems ?? []).map { ($0.file, $0) },
                                               uniquingKeysWith: { first, _ in first })
                for stem in song.files {
                    guard let files = sources[stem.filePath] else { continue }
                    guard let track = keys[stem.trackKey] else { throw ProjectError.invalid("Missing imported audio") }
                    for source in files {
                        let filename = renderedFiles[source.name] != nil ? source.name : stem.fileName
                        let name = fileNames.allocate(filename)
                        let rendered = renderedFiles[source.name]
                        let item = folder?.drawer != nil ? rendered?.items.first : nil
                        let path = copyMedia ? relativeFolder + "/" + name : try LinkedStemMedia.shared.reference(
                            to: source.url, accessRoot: folder?.accessRoot ?? source.url.deletingLastPathComponent())
                        jobs.append(MediaImportJob(source: source.url, copy: copyMedia ? media.appendingPathComponent(name) : nil, relative: path,
                            stem: stem, track: track, start: region.startTime + (metadata?.region.startTime ?? 0) + (item?.offset ?? 0),
                            duration: item?.duration ?? source.duration, fileName: filename, renderedRegion: rendered == nil ? nil : region.id,
                            renderedSourceTrack: rendered?.track, pitchSemitones: metadata?.tunerUnbaked == true && rendered?.items.count == 1
                                ? rendered?.items.first?.pitchSemitones : nil))
                    }
                }
            }
            let prepared = try prepareMedia(jobs, created: &copiedAudio, progress: progress)
            var renderedTracks: [UUID: [UUID: Set<UUID>]] = [:]
            for (job, result) in zip(jobs, prepared) {
                guard case .success(let overview) = result else {
                    if case .failure(let error) = result { onUnreadable?(job.source.path, error) }
                    continue
                }
                let stem = job.stem
                let internalTrack = stem.trackName == "Click" || stem.trackName.hasPrefix("Click ") || stem.trackName == "Regência" || stem.trackName.hasPrefix("Regência ")
                let gain = internalTrack && overview.peak > 0 ? pow(10, -1.0 / 20) / overview.peak : 1
                var clip = AudioClip(id: UUID(), name: job.fileName, startTime: job.start, duration: job.duration,
                    waveform: overview.waveform, audioFile: AudioFile(path: job.relative), gain: gain, waveformChannels: overview.channels)
                if let region = job.renderedRegion, let source = job.renderedSourceTrack {
                    clip.renderedTempo = true; clip.regionOwnerID = region
                    renderedTracks[region, default: [:]][source, default: []].insert(arrangement.tracks[job.track].id)
                }
                clip.pitchSemitones = job.pitchSemitones
                arrangement.tracks[job.track].clips.append(clip)
            }
            // Use actual placed intervals: adding the append offset in a different
            // order can otherwise leave the last clip a fraction beyond the song.
            arrangement.duration = max(arrangement.duration,
                arrangement.parts.map(\.endTime).max() ?? 0,
                arrangement.tracks.flatMap(\.clips).map { $0.startTime + $0.duration }.max() ?? 0)
            // Use the actual Hook Center audit, including Outros, instead of
            // classifying display names again or mistaking audio tracks for folders.
            for group in audit.groups {
                let members = group.tracks.compactMap { keys[$0.key] }.filter {
                    $0 >= existingTrackCount && !arrangement.tracks[$0].clips.isEmpty
                }
                guard !members.isEmpty else { continue }
                struct Destination: Decodable { var folderIndex: Int?; var anchorIndex: Int? }
                let target = try call("existingImportGroupDestination", args: [existingLayout, group.key], context: js, as: Destination.self)
                let folder = target.folderIndex.map { arrangement.tracks[$0] }
                let anchor = target.anchorIndex.map { arrangement.tracks[$0] }
                let color = folder?.color ?? anchor?.color ?? UInt32(group.colorHex.dropFirst(), radix: 16) ?? 0x55acbe
                let parent: UUID? = folder?.id ?? (anchor == nil ? UUID() : nil)
                if folder == nil, let parent {
                    arrangement.tracks.append(Track(id: parent, name: group.name, role: .other,
                        instrumentIcon: importedIcon(group.name), color: color))
                }
                for index in members {
                    arrangement.tracks[index].parentTrackID = parent
                    if parent != nil {
                        arrangement.tracks[index].patch = .masterGroup
                        arrangement.tracks[index].secondaryPatch = nil; arrangement.tracks[index].outputs = nil
                    } else if let anchor { rootAnchors[arrangement.tracks[index].id] = anchor.id }
                    // Keep the folder saturated; new children use its softened hue.
                    let r = (color >> 16) & 255, g = (color >> 8) & 255, b = color & 255
                    func soft(_ value: UInt32) -> UInt32 { value + (255 - value) * 28 / 100 }
                    arrangement.tracks[index].color = soft(r) << 16 | soft(g) << 8 | soft(b)
                }
            }
            // Preserve every existing track's identity, order, routing and parent.
            // Only brand-new tracks are inserted, at the end of the matching
            // folder's subtree. Never regroup a reused track, even when it has
            // a different category or no parent at all.
            let populatedParents = Set(arrangement.tracks.compactMap(\.parentTrackID))
            let additions = arrangement.tracks.dropFirst(existingTrackCount).filter {
                !$0.clips.isEmpty || populatedParents.contains($0.id)
            }
            var ordered = Array(arrangement.tracks.prefix(existingTrackCount))
            let newRoots = additions.filter { $0.parentTrackID == nil && rootAnchors[$0.id] == nil }
            if existingTrackCount == 0 {
                ordered += newRoots.filter { js.objectForKeyedSubscript("groupKeyFromFolderName")!.call(withArguments: [$0.name])!.toString()! != "percussivo" }
                ordered += newRoots.filter { js.objectForKeyedSubscript("groupKeyFromFolderName")!.call(withArguments: [$0.name])!.toString()! == "percussivo" }
            } else { ordered += newRoots }
            var lastRootInsertion: [UUID: UUID] = [:]
            for track in additions where rootAnchors[track.id] != nil {
                let anchor = rootAnchors[track.id]!
                let previous = lastRootInsertion[anchor] ?? anchor
                if let index = ordered.firstIndex(where: { $0.id == previous }) { ordered.insert(track, at: index + 1) }
                else { ordered.append(track) }
                lastRootInsertion[anchor] = track.id
            }
            let parents = Dictionary(uniqueKeysWithValues: arrangement.tracks.map { ($0.id, $0.parentTrackID) })
            func belongs(_ track: Track, to parent: UUID) -> Bool {
                var ancestor = track.parentTrackID
                var visited = Set<UUID>()
                while let id = ancestor, visited.insert(id).inserted {
                    if id == parent { return true }
                    ancestor = parents[id] ?? nil
                }
                return false
            }
            for track in additions where track.parentTrackID != nil {
                guard let parent = track.parentTrackID, let index = ordered.firstIndex(where: { $0.id == parent }) else {
                    ordered.append(track); continue
                }
                var insertion = index + 1
                while insertion < ordered.count && belongs(ordered[insertion], to: parent) { insertion += 1 }
                ordered.insert(track, at: insertion)
            }
            arrangement.tracks = ordered
            let videoDirectory = destination.deletingLastPathComponent().appendingPathComponent("Videos")
            var videoNames = MediaFileNames(directory: videoDirectory)
            for (index, entry) in audit.songs.enumerated() {
                let regionIndex = regionIndices[index]
                let region = arrangement.parts[regionIndex]
                if let folder = sourceFolders[entry.folderPath], let data = folder.regionData {
                    let lyrics = (supplemental[entry.folderPath] ?? []).compactMap { source -> JLLyricsDocument? in
                        if case .lyrics(let document) = source.payload { return document }
                        return nil
                    }
                    let child = drawerChildren[entry.folderPath]
                    let markerIDs = child.flatMap { drawerMarkerIDs[$0.parent] }
                    try restoreMultitrack(data, folder: folder.url, accessRoot: folder.accessRoot, arrangement: &arrangement, regionIndex: regionIndex,
                        directory: destination.deletingLastPathComponent(), lyrics: lyrics, drawerMarkerIDs: markerIDs,
                        renderedTracks: renderedTracks[region.id] ?? [:], videoNames: &videoNames, copied: &copiedVideo, copyMedia: copyMedia, progress: progress, onUnreadable: onUnreadable)
                    if let child, let parent = arrangement.parts.first(where: { $0.id == child.parent }) {
                        arrangement.parts[regionIndex].parentRegionID = child.parent
                        arrangement.parts[regionIndex].startTime = max(parent.startTime, arrangement.parts[regionIndex].startTime)
                        arrangement.parts[regionIndex].endTime = min(parent.endTime, arrangement.parts[regionIndex].endTime)
                        let part = arrangement.parts[regionIndex]
                        let flagID = child.entry.cueID.flatMap { markerIDs?[$0] } ?? UUID()
                        arrangement.markers?.append(TimelineMarker(id: flagID, name: child.entry.cueName ?? part.name,
                            position: child.cue, color: child.entry.cueColor ?? part.color ?? 0x999999, unifiedRegionID: child.parent,
                            regionOwnerID: part.id, sourceRegionID: part.id))
                    }
                    continue
                }
                for file in supplemental[entry.folderPath] ?? [] {
                    try Task.checkCancellation()
                    switch file.payload {
                    case .audio: break
                    case .lyrics(let document):
                        try arrangement.insertLyrics(document, at: region.startTime, region: region.id)
                    case .video(let kind):
                        let target = arrangement.tracks.firstIndex(where: {
                            $0.kind == kind && (kind != .standard || ($0.parentTrackID == nil && $0.name == "Video"))
                        })
                        let path: String
                        if copyMedia {
                            let name = videoNames.allocate(file.name)
                            let copy = videoDirectory.appendingPathComponent(name)
                            try fm.createDirectory(at: videoDirectory, withIntermediateDirectories: true)
                            try fm.copyItem(at: file.url, to: copy)
                            copiedVideo.append(copy)
                            path = "Videos/" + name
                        } else {
                            let root = sourceFolders[entry.folderPath]?.accessRoot ?? file.url.deletingLastPathComponent()
                            path = try LinkedStemMedia.shared.reference(to: file.url, accessRoot: root, video: true)
                        }
                        let currentEnd = target.flatMap { row in
                            arrangement.tracks[row].clips.filter(\.isProjectionMedia).filter { $0.regionOwnerID == region.id }
                                .map { $0.startTime + $0.duration }.max()
                        } ?? region.startTime
                        var clip = AudioClip(id: UUID(), name: file.url.deletingPathExtension().lastPathComponent,
                            startTime: currentEnd, duration: file.duration, audioFile: AudioFile(path: path))
                        clip.regionOwnerID = region.id
                        if let target { arrangement.tracks[target].clips.append(clip) }
                        else {
                            var track = Track(id: UUID(), name: kind == .standard ? "Video" : kind.title,
                                role: kind == .standard ? .other : TrackRole(rawValue: kind.rawValue), color: kind.defaultColor ?? Track.defaultStandardColor)
                            track.clips = [clip]
                            let beforeInternal = kind == .standard ? arrangement.tracks.firstIndex {
                                $0.parentTrackID == nil && js.objectForKeyedSubscript("groupKeyFromFolderName")?
                                    .call(withArguments: [$0.name])?.toString() == "interno"
                            } : nil
                            let before = beforeInternal ?? arrangement.tracks.firstIndex { $0.kind == .standard }
                            arrangement.tracks.insert(track, at: before ?? arrangement.tracks.endIndex)
                        }
                        arrangement.duration = max(arrangement.duration, currentEnd + file.duration)
                    }
                }
            }
            var names = GridItemNames(project.songs[0].tracks)
            let existing = Set(project.songs[0].tracks.flatMap { $0.clips.map(\.id) })
            for row in arrangement.tracks.indices {
                for index in arrangement.tracks[row].clips.indices where !existing.contains(arrangement.tracks[row].clips[index].id) {
                    arrangement.tracks[row].clips[index].name = names.allocate(arrangement.tracks[row].clips[index].name)
                }
            }
            project.songs[0] = arrangement
            project.updatedAt = ISO8601DateFormatter().string(from: Date())
            try project.validate()
            return project
        } catch {
            for copy in copiedAudio { try? fm.removeItem(at: copy) }
            for file in copiedVideo { try? fm.removeItem(at: file) }
            throw error
        }
    }
}
