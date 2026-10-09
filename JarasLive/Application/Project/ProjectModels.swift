import Foundation

public struct TrackRole: Codable, Hashable, Sendable, RawRepresentable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let click = Self(rawValue: "click"), guide = Self(rawValue: "guide"), drums = Self(rawValue: "drums"), bass = Self(rawValue: "bass"), guitar = Self(rawValue: "guitar"), keys = Self(rawValue: "keys"), accordion = Self(rawValue: "accordion"), backingVocal = Self(rawValue: "backingVocal"), fx = Self(rawValue: "fx"), other = Self(rawValue: "other")
    public static let chords = Self(rawValue: "chords")
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(rawValue) }
}
public struct AudioFile: Codable, Equatable, Sendable { public var path: String; public var sha256: String? }
public struct AudioClip: Codable, Identifiable, Equatable, Sendable { public var id: UUID; public var name: String; public var startTime: Double; public var duration: Double; public var separatedStemTracks: [UUID]?; public var sourceOffset: Double = 0; public var waveform: [Double] = []; public var audioFile: AudioFile?; public var gain: Double?; public var phaseInverted: Bool? = nil; public var pan: Double? = nil; public var normalizationGain: Double?; public var fadeIn: Double?; public var fadeOut: Double?; public var fadeTimelineStart: Double?; public var fadeTimelineDuration: Double?; public var channelMode: Int?; public var waveformChannels: [[Double]]?; public var muted: Bool?; public var playbackRate: Double?; public var recordingLane: Int?; public var loopStart: Double?; public var loopLength: Double?; public var fx: NativeFXSettings?; public var timecode: TimecodeSettings?; public var timecodeStartOffset: Double?; public var timecodeEndOffset: Double?; public var fxBypassed: Bool?; public var text: String?; public var midi: MIDIItem?; public var frozenMIDI: Bool?; public var renderedTiming: Bool?; public var pitchSemitones: Double? = nil; public var regionOwnerID: UUID? = nil; public var audioRate: Double { playbackRate ?? 1 } }
public extension AudioClip {
    var isProjectionMedia: Bool { audioFile?.path.hasPrefix("Videos/") == true }
    var isImage: Bool { isProjectionMedia && ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "avif"].contains(URL(fileURLWithPath: audioFile?.path ?? "").pathExtension.lowercased()) }
}
/// The existing persisted channel field also identifies a MIDI take (zero PCM channels).
public enum TrackRecordingMode: Int, CaseIterable, Sendable {
    case midi = 0, mono = 1, stereo = 2
}
public struct Track: Codable, Identifiable, Equatable, Sendable {
    /// Applied only by creation paths. Decoded nil/custom colors stay unchanged.
    public static let defaultStandardColor: UInt32 = 0x828282
    public var id: UUID; public var name: String; public var role: TrackRole
    public var volume: Double = 1, pan: Double = 0
    public var phaseInverted: Bool? = nil
    /// Visual row proportion; absent in existing projects means the standard height.
    public var heightScale: Double? = nil
    public var mute = false, solo = false
    public var output = 1
    public var fx: NativeFXSettings?
    public var midiInput: Int?
    public var midiChannel: Int?
    public func acceptsMIDI(status: UInt8) -> Bool {
        status >= 0x80 && status < 0xf0 && (midiChannel == nil || midiChannel == Int(status & 0x0f) + 1)
    }
    public var parentTrackID: UUID?
    public var stereoLink: TrackStereoLink?
    public var inputPatch: OutputPatch?
    public var inputMonitoring: Bool?
    public var recordingChannels: Int?
    public var recordingMode: TrackRecordingMode { TrackRecordingMode(rawValue: recordingChannels ?? 2) ?? .stereo }
    public var recordingFormat: String?
    public var timecode: TimecodeSettings?
    public var importedTimecodeItems: Bool?
    public var color: UInt32?
    public var patch: OutputPatch?
    public var secondaryPatch: OutputPatch?
    public var outputs: [OutputPatch]?
    public var routing: TrackRouting?
    public var outputPatches: [OutputPatch] {
        outputs ?? [patch ?? (parentTrackID == nil ? .master : .masterGroup)] + (secondaryPatch.map { [$0] } ?? [])
    }
    public var primaryOutput: OutputPatch { outputPatches.first ?? .none }
    public var secondaryOutput: OutputPatch { outputPatches.count > 1 ? outputPatches[1] : .none }
    public var audioFile: AudioFile?
    public var clips: [AudioClip] = []
    public var clickSound: AudioFile?
}
public struct TrackStereoLink: Codable, Equatable, Sendable {
    public var partner: UUID
    public var left: Bool
    public var original: TrackLinkOriginal
}

/// Shared visual geometry. Overlapping items retain the existing minimum per lane.
public enum TrackHeightGeometry {
    public static let minimumScale = 0.1, maximumScale = 10.0
    public static func isValidScale(_ value: Double) -> Bool { value.isFinite && (minimumScale...maximumScale).contains(value) }
    public static func scale(_ value: Double?) -> Double { value.flatMap { isValidScale($0) ? $0 : nil } ?? 1 }
    public static func laneLimits(count: Int) -> ClosedRange<Double> { count > 1 ? 26...168 : 24...240 }
    public static func laneHeight(base: Double, scale: Double, count: Int) -> Double {
        let limits = laneLimits(count: count)
        return min(limits.upperBound, max(limits.lowerBound, base * (count > 1 ? 0.7 : 1) * scale))
    }
    /// Stop a shared zoom at the first row limit, keeping all row proportions.
    public static func globalLimits(scales: [Double], laneCounts: [Int], current: Double = 64) -> ClosedRange<Double> {
        var lower = 24.0, upper = 240.0
        for (index, scale) in scales.enumerated() {
            let count = laneCounts.indices.contains(index) ? laneCounts[index] : 1
            let limits = laneLimits(count: count), multiplier = scale * (count > 1 ? 0.7 : 1)
            lower = max(lower, limits.lowerBound / multiplier)
            upper = min(upper, limits.upperBound / multiplier)
        }
        // A malformed combination from another editor still gets bounded rows.
        return lower <= upper ? lower...upper : current...current
    }
}
public struct TrackLinkOriginal: Codable, Equatable, Sendable {
    public var name: String
    public var color: UInt32?
    public var volume: Double
    public var pan: Double
    public var inputPatch: OutputPatch?
    public var output: Int
    public var patch: OutputPatch?
    public var secondaryPatch: OutputPatch?
    public var outputs: [OutputPatch]?
    public var routing: TrackRouting?
    public init(_ track: Track) {
        name = track.name; color = track.color; volume = track.volume; pan = track.pan
        inputPatch = track.inputPatch; output = track.output; patch = track.patch
        secondaryPatch = track.secondaryPatch; outputs = track.outputs; routing = track.routing
    }
    public func restore(_ track: inout Track) {
        track.name = name; track.color = color; track.volume = volume; track.pan = pan
        track.inputPatch = inputPatch; track.output = output; track.patch = patch
        track.secondaryPatch = secondaryPatch; track.outputs = outputs; track.routing = routing
        track.stereoLink = nil
    }
}
public extension Song {
    func linkableTracks(_ ids: Set<UUID>) -> [Int]? {
        guard ids.count == 2 else { return nil }
        let indices = tracks.indices.filter { ids.contains(tracks[$0].id) }
        guard indices.count == 2, indices[1] == indices[0] + 1,
              indices.allSatisfy({ index in
                  let track = tracks[index]
                  return track.kind == .standard && track.stereoLink == nil && !tracks.contains { $0.parentTrackID == track.id }
              }) else { return nil }
        return indices
    }
    mutating func linkTracks(_ ids: Set<UUID>, firstInput: Int, color: UInt32) {
        guard let indices = linkableTracks(ids), (1...1023).contains(firstInput) else { return }
        let top = tracks[indices[0]], bottom = tracks[indices[1]]
        for (offset, index) in indices.enumerated() {
            let original = tracks[index]
            tracks[index].stereoLink = TrackStereoLink(partner: offset == 0 ? bottom.id : top.id, left: offset == 0, original: TrackLinkOriginal(original))
            tracks[index].name = (offset == 0 ? "L - " : "R - ") + original.name
            tracks[index].color = color; tracks[index].volume = top.volume; tracks[index].pan = offset == 0 ? -1 : 1
            tracks[index].inputPatch = OutputPatch(firstChannel: firstInput + offset, channelCount: 1)
        }
    }
    mutating func unlinkTracks(_ id: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == id }), let link = tracks[index].stereoLink else { return }
        link.original.restore(&tracks[index])
        if let other = tracks.firstIndex(where: { $0.id == link.partner }), let saved = tracks[other].stereoLink, saved.partner == id {
            saved.original.restore(&tracks[other])
        }
    }
}
public struct Part: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var startTime: Double
    public var endTime: Double
    public var color: UInt32? = nil
    public var uppercaseName: Bool? = nil
    public var parentRegionID: UUID? = nil
    public var pitchSemitones: Int? = nil
    public var pitchTrackIDs: [UUID]? = nil
    public var pitchGroupIDs: [UUID]? = nil
    public var multiLoops: [MultiLoop]? = nil
    public var totalLoop: Bool? = nil
    public var semitones: Int { pitchSemitones ?? 0 }
    public var usesUppercase: Bool { uppercaseName ?? true }
    public var displayName: String {
        guard usesUppercase else { return name }
        var depth = 0
        var result = ""
        for character in name {
            if character == "(" { depth += 1 }
            result += depth > 0 ? String(character) : String(character).uppercased()
            if character == ")" { depth = max(0, depth - 1) }
        }
        return result
    }
}
public struct TimelineMarker: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var position: Double
    public var color: UInt32
    public var unifiedRegionID: UUID? = nil
    public var regionOwnerID: UUID? = nil
    public var sourceRegionID: UUID? = nil
    public var tempoBPM: Double? = nil
    public var tempoBeats: Int? = nil
    public var tempoUnit: Int? = nil
    public var tempoTimebase: TempoMarkerTimebase? = nil
    public var tempoReferenceBPM: Double? = nil
    public var section: Bool? = nil
    public var loopSection: Bool? = nil
    public var isLoopSection: Bool { isSection && loopSection == true }
    public var markerEditorName: String { (isLoopSection ? "*" : isSection ? "$" : "") + name }
    public mutating func applySectionPrefix() {
        guard !isTempo else { return }
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("$") || raw.hasPrefix("*") else { return }
        section = true; loopSection = raw.hasPrefix("*")
        let slot = (1...4).contains { raw.hasPrefix("*\($0)") }
        name = String(raw.dropFirst(slot ? 2 : 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var isSection: Bool { section == true && !isTempo }
    public var isTempo: Bool { tempoBPM != nil }
    public static let maximumNameLength = 256
    public static let maximumSectionNameLength = 256
    public static func flagWidths(_ markers: [Self], scale: Double, widths: [UUID: Double], regionEnds: [UUID: Double] = [:], facesLeft: Bool = false) -> [UUID: Double] {
        let ordered = markers.enumerated().sorted { $0.element.position == $1.element.position ? $0.offset < $1.offset : $0.element.position < $1.element.position }
        var result: [UUID: Double] = [:]
        if facesLeft {
            var previousEdge = 0.0
            for (index, entry) in ordered.enumerated() {
                let marker = entry.element, x = marker.position * scale
                // At project zero the head stays inside the viewport. Every
                // subsequent tempo head ends at its own vertical line.
                let available = marker.position == 0
                    ? (index + 1 < ordered.count ? ordered[index + 1].element.position * scale - 3 : .infinity)
                    : x - previousEdge - 3
                let width = min((widths[marker.id] ?? 0) + 10, available)
                if width >= 18 { result[marker.id] = width }
                previousEdge = marker.position == 0 ? max(0, width) : x
            }
            return result
        }
        var rightHead = Double.infinity
        for entry in ordered.reversed() {
            let marker = entry.element, x = marker.position * scale
            let boundary = (regionEnds[marker.id] ?? .infinity) * scale
            let width = min((widths[marker.id] ?? 0) + 10, rightHead - x - 3, boundary - x)
            if width >= 18 { result[marker.id] = width }
            rightHead = x
        }
        return result
    }

}
public struct Song: Codable, Identifiable, Equatable, Sendable {
    /// Complete-project audio export includes leading silence and stops at the
    /// last audio item's end, independently of region or auxiliary-track bounds.
    public var completeAudioExportEnd: Double {
        tracks.filter { $0.kind == .standard }.reduce(0) { end, track in
            track.clips.reduce(end) { latest, clip in
                guard clip.audioFile != nil || track.audioFile != nil else { return latest }
                return max(latest, clip.startTime + clip.duration)
            }
        }
    }

    public var id: UUID; public var name: String; public var duration: Double; public var bpm: Double
    public var tracks: [Track]; public var parts: [Part]
    public var markers: [TimelineMarker]?
    public var beatsPerBar: Int?
    public var beatUnit: Int?
    public var regionOwnershipInitialized: Bool? = nil
    public var timeSettings: ProjectTimeSettings? = nil
    public var projectTime: ProjectTimeSettings { timeSettings ?? .legacy }
    public var meterBeats: Int { beatsPerBar ?? 4 }
    public var meterUnit: Int { beatUnit ?? 4 }
    public var barSeconds: Double { 60 / bpm * Double(meterBeats) * 4 / Double(meterUnit) }
    /// Presentation follows the internal song without changing the transport's
    /// unified boundary or queue. No sorting or list rebuilding during playback.
    public func playingSetlistRegion(_ id: UUID?, position: Double, expanded: Set<UUID>) -> Part? {
        guard let playing = parts.first(where: { $0.id == id }) else { return nil }
        let root = playing.parentRegionID.flatMap { parent in parts.first(where: { $0.id == parent }) } ?? playing
        guard expanded.contains(root.id) else { return root }
        var current: Part?
        for child in parts where child.parentRegionID == root.id && position >= child.startTime && position < child.endTime {
            if current == nil || child.startTime > current!.startTime || (child.startTime == current!.startTime && child.endTime > current!.endTime) { current = child }
        }
        return current ?? root
    }
    /// Show the next internal song until the unified region reaches its final
    /// song. This is presentation only: the armed transport queue stays intact.
    public func nextDrawerRegion(_ id: UUID?, position: Double) -> Part? {
        guard let playing = parts.first(where: { $0.id == id }) else { return nil }
        let parent = playing.parentRegionID ?? playing.id
        var next: Part?
        for child in parts where child.parentRegionID == parent && child.startTime > position {
            if next == nil || child.startTime < next!.startTime ||
                (child.startTime == next!.startTime && child.id.uuidString < next!.id.uuidString) { next = child }
        }
        return next
    }
    public func markerLabel(_ marker: TimelineMarker) -> String {
        if let bpm = marker.tempoBPM { return String(format: "%g  %d/%d", bpm, marker.tempoBeats ?? 4, marker.tempoUnit ?? 4) }
        guard let id = marker.sourceRegionID, let region = parts.first(where: { $0.id == id }) else { return marker.isSection ? marker.name.uppercased() : marker.name }
        return "\(region.semitones)st  " + marker.name
    }
    public var markerRegionEnds: [UUID: Double] {
        var result: [UUID: Double] = [:]
        let roots = parts.filter { $0.parentRegionID == nil }.sorted { $0.startTime < $1.startTime }
        let byID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        var active: [Part] = [], index = 0
        for marker in (markers ?? []).sorted(by: { $0.position < $1.position }) {
            while index < roots.count, roots[index].startTime <= marker.position {
                if roots[index].endTime > marker.position { active.append(roots[index]) }
                index += 1
            }
            active.removeAll { $0.endTime <= marker.position }
            if let group = marker.unifiedRegionID, let region = byID[group] {
                result[marker.id] = region.endTime
            } else if let end = active.map(\.endTime).min() {
                result[marker.id] = end
            }
        }
        return result
    }
    public var pitchGroups: [Track] { tracks.filter { track in track.kind == .standard && tracks.contains { $0.parentTrackID == track.id } } }
    public var pitchTracks: [Track] { let folders = Set(pitchGroups.map(\.id)); return tracks.filter { $0.kind == .standard && !folders.contains($0.id) } }
    public func pitchTargets(_ region: Part) -> (tracks: Set<UUID>, groups: Set<UUID>) {
        (Set(region.pitchTrackIDs ?? pitchTracks.map(\.id)), Set(region.pitchGroupIDs ?? pitchGroups.map(\.id)))
    }
    public func pitch(for track: UUID, region: Part?) -> Int {
        guard let region, region.semitones != 0, let source = tracks.first(where: { $0.id == track }), source.kind == .standard else { return 0 }
        let targets = pitchTargets(region)
        return targets.tracks.contains(track) || targets.groups.contains(track) || !Set(TrackHierarchy(tracks).ancestors(of: source.id)).isDisjoint(with: targets.groups) ? region.semitones : 0
    }
    public func pitchRegion(at position: Double, fallback: UUID? = nil) -> Part? {
        // Children own their audio even when a previous child's tail overlaps.
        let candidates = parts.filter { position >= $0.startTime && position < $0.endTime }
        return candidates.max { a, b in
            if (a.parentRegionID != nil) != (b.parentRegionID != nil) { return a.parentRegionID == nil }
            return a.startTime < b.startTime
        } ?? parts.first { $0.id == fallback }
    }
    public func isSilenced(_ track: Track) -> Bool {
        if track.kind != .standard { return track.mute }
        return track.mute || !(TrackHierarchy.soloAudibleTracks(tracks)?.contains(track.id) ?? true)
    }
}
public struct Setlist: Codable, Identifiable, Equatable, Sendable { public var id: UUID; public var name: String; public var songIds: [UUID] }
public struct RegionPlaylist: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var songId: UUID
    public var regionIds: [UUID]
}
public struct SetlistBlock: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var songId: UUID
    public var playlistId: UUID?
    public var name: String
    public var color: UInt32
    public var beforeRegionId: UUID?
    public var symbol: Bool?
    public var showsSymbol: Bool { symbol ?? true }
}
public enum SetlistEntry: Identifiable, Equatable, Sendable {
    case region(Part, number: Int)
    case block(SetlistBlock)
    public var id: UUID { switch self { case .region(let value, _): return value.id; case .block(let value): return value.id } }
    public var name: String { switch self { case .region(let value, _): return value.name; case .block(let value): return value.name } }
}
public struct RegionSetlist: Codable, Equatable, Sendable {
    public var playlists: [RegionPlaylist] = []
    public var selectedId: UUID?
    public var autoAdvance = false
    /// Limit generated queues to this setlist block; manual choices stay unrestricted.
    public var autoUntilBlockEnd: Bool?
    public var automaticSubplay: Bool?
    public var automaticSubplaySeconds: Double?
    public var subplayLeadTime: Double { min(5, max(1, automaticSubplaySeconds ?? 1)) }
    public var prepareWithoutPlayback: Bool?
    public var preparesWithoutPlayback: Bool { prepareWithoutPlayback ?? false }
    public var stopAtRegionEnd: Bool?
    public var stopsAtRegionEnd: Bool { stopAtRegionEnd ?? false }
    public var blocks: [SetlistBlock]?
    /// Live performance history is portable with this project, not other sessions.
    public var liveEnabled: Bool?
    public var playedLiveRegionIDs: [UUID]?
}
public extension RegionSetlist {
    @discardableResult mutating func clonePlaylist(_ id: UUID) -> UUID? {
        guard let source = playlists.first(where: { $0.id == id }) else { return nil }
        let names = Set(playlists.filter { $0.songId == source.songId }.map(\.name))
        var base = source.name
        if let dash = base.lastIndex(of: "-"), let suffix = Int(base[base.index(after: dash)...]), suffix >= 2 {
            let candidate = String(base[..<dash])
            if names.contains(candidate) { base = candidate }
        }
        let prefix = base + "-"
        let last = names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix) else { return nil }
            return Int(name.dropFirst(prefix.count))
        }.filter { $0 >= 2 && $0 < Int.max }.max() ?? 1
        var number = last + 1
        while names.contains(prefix + String(number)) { number += 1 }
        var copy = source; copy.id = UUID(); copy.name = prefix + String(number)
        playlists.append(copy)
        let copiedBlocks = (blocks ?? []).filter { $0.playlistId == source.id }.map { block -> SetlistBlock in
            var copyBlock = block; copyBlock.id = UUID(); copyBlock.playlistId = copy.id; return copyBlock
        }
        if !copiedBlocks.isEmpty { blocks = (blocks ?? []) + copiedBlocks }
        return copy.id
    }
    @discardableResult mutating func deletePlaylist(_ id: UUID) -> Bool {
        guard playlists.contains(where: { $0.id == id }) else { return false }
        playlists.removeAll { $0.id == id }
        blocks?.removeAll { $0.playlistId == id }
        if selectedId == id { selectedId = nil }
        return true
    }
}
public struct SavedProjectCursor: Codable, Equatable, Sendable {
    public let songID: UUID
    public let position: Double
    public init(songID: UUID, position: Double) { self.songID = songID; self.position = position }
}
public struct Project: Codable, Identifiable, Equatable, Sendable {
    /// Editing position captured by Save, portable with the document and backups.
    public var savedCursor: SavedProjectCursor? = nil
    /// Migrated arrangements retain their own timing when opening the document.
    public var importedTimeline: Bool? = nil
    public var id: UUID; public var name: String
    public var projectFormatVersion = 1, minimumJarasVersion = "1.0.0"
    public var createdAt: String, updatedAt: String
    public var setlists: [Setlist]; public var songs: [Song]
    public var regionSetlist: RegionSetlist?
    public var masterVolume: Double?
    public var masterMute: Bool?
    public var masterSolo: Bool?
    public var masterMono: Bool?
    public var masterPhaseInverted: Bool?
    public var masterColor: UInt32? = 0x414141
    public var masterFX: NativeFXSettings?
    public var masterPatch: OutputPatch?
    public var masterSecondaryPatch: OutputPatch?
    public var masterOutputs: [OutputPatch]?
    public var masterOutputPatches: [OutputPatch] { masterOutputs ?? [masterPatch ?? .stereo] + (masterSecondaryPatch.map { [$0] } ?? []) }
    public static func timecodeItemID(_ region: UUID) -> UUID {
        var text = region.uuidString
        let digit = Int(String(text.removeFirst()), radix: 16)!
        return UUID(uuidString: String(digit ^ 8, radix: 16) + text)!
    }
    public func validate() throws {
        guard projectFormatVersion == 1, minimumJarasVersion == "1.0.0", !name.isEmpty else { throw ProjectError.invalid("Versão ou nome do projeto inválido.") }
        if let savedCursor {
            guard savedCursor.position.isFinite, savedCursor.position >= 0 else { throw ProjectError.invalid("Invalid saved cursor position") }
        }
        guard (masterVolume ?? 1).isFinite, (0...pow(10.0, 12.0 / 20.0)).contains(masterVolume ?? 1) else { throw ProjectError.invalid("Invalid master volume") }
        guard masterColor == nil || masterColor! <= 0xffffff else { throw ProjectError.invalid("Invalid master color") }
        try masterFX?.validate()
        try masterPatch?.validate(allowMaster: false, allowNone: true)
        try masterSecondaryPatch?.validate(allowMaster: false, allowNone: true)
        for patch in masterOutputPatches { try patch.validate(allowMaster: false, allowNone: true) }
        var identifiers: Set<UUID> = [id]
        guard songs.flatMap(\.tracks).filter({ $0.kind == .timecode }).count <= 1 else { throw ProjectError.invalid("Only one Timecode track is allowed") }
        guard songs.flatMap(\.tracks).filter({ $0.kind == .click }).count <= 1 else { throw ProjectError.invalid("Only one Click track is allowed") }
        func register(_ id: UUID) throws { guard identifiers.insert(id).inserted else { throw ProjectError.invalid("UUID duplicado.") } }
        for song in songs {
            try song.validateTrackRouting()
            try register(song.id)
            guard (1...32).contains(song.meterBeats), TimelineTempo.beatUnits.contains(song.meterUnit) else { throw ProjectError.invalid("Invalid time signature.") }
            try song.projectTime.validate()
            guard song.duration.isFinite, song.duration > 0, song.bpm.isFinite, song.bpm > 0 else { throw ProjectError.invalid("Tempo de música inválido.") }
            var ancestors: [UUID] = []
            let audioTracks = Set(song.tracks.filter { $0.kind == .standard }.map(\.id))
            for track in song.tracks {
                if let parent = track.parentTrackID {
                    guard let index = ancestors.firstIndex(of: parent), parent != track.id, audioTracks.contains(parent) else { throw ProjectError.invalid("Invalid track group") }
                    ancestors.removeSubrange((index + 1)..<ancestors.count)
                } else { ancestors.removeAll(keepingCapacity: true) }
                ancestors.append(track.id)
                try register(track.id)
                if let fixed = track.fixedName { guard (track.name == fixed || (track.kind == .teleprompt && track.name == "Teleprompter")), (!track.solo || track.kind == .video || track.kind == .click), track.parentTrackID == nil else { throw ProjectError.invalid("Invalid special track") } }
                guard track.clickSound == nil || track.kind == .click else { throw ProjectError.invalid("Custom click sound requires a Click track") }
                if track.kind == .click { guard track.fx == nil, track.audioFile == nil, track.midiInput == nil, track.inputPatch == nil, track.midiChannel == nil, track.recordingChannels == nil, track.recordingFormat == nil else { throw ProjectError.invalid("Click tracks cannot record or contain FX") } }
                if track.kind.isText { guard !track.mute, track.fx == nil, track.audioFile == nil, track.midiInput == nil, track.midiChannel == nil, track.recordingFormat == nil, track.recordingChannels == nil else { throw ProjectError.invalid("Text tracks cannot contain audio controls") } }
                if let link = track.stereoLink {
                    guard track.kind == .standard, let other = song.tracks.first(where: { $0.id == link.partner }),
                          other.id != track.id, other.stereoLink?.partner == track.id, other.stereoLink?.left != link.left,
                          !song.tracks.contains(where: { $0.parentTrackID == track.id }),
                          track.volume == other.volume, track.pan == -other.pan,
                          let input = track.inputPatch, let otherInput = other.inputPatch,
                          input.channelCount == 1, otherInput.channelCount == 1,
                          otherInput.firstChannel == input.firstChannel + (link.left ? 1 : -1) else { throw ProjectError.invalid("Invalid linked tracks") }
                }
                try track.timecode?.validate()
                guard track.color == nil || track.color! <= 0xffffff else { throw ProjectError.invalid("Invalid track color") }
                guard track.heightScale == nil || TrackHeightGeometry.isValidScale(track.heightScale!) else { throw ProjectError.invalid("Invalid track height") }
                try track.fx?.validate()
                if track.kind.isSingleLane {
                    let layers = track.kind.isTeleprompter ? [track.clips.filter { !$0.isProjectionMedia }, track.clips.filter(\.isProjectionMedia)] : [track.clips]
                    for layer in layers {
                        let clips = layer.sorted { $0.startTime < $1.startTime }
                        guard zip(clips, clips.dropFirst()).allSatisfy({ $0.startTime + $0.duration <= $1.startTime + 0.0000001 }) else {
                            throw ProjectError.invalid("Teleprompter, Video and Chords items cannot overlap")
                        }
                    }
                }
                guard track.midiChannel == nil || (1...16).contains(track.midiChannel!) else { throw ProjectError.invalid("Invalid MIDI channel") }
                guard track.midiInput == nil || (1...3).contains(track.midiInput!) else { throw ProjectError.invalid("Invalid MIDI input") }
                try track.inputPatch?.validate(allowMaster: false)
                guard track.recordingChannels == nil || TrackRecordingMode(rawValue: track.recordingChannels!) != nil else { throw ProjectError.invalid("Invalid recording channel mode") }
                guard track.recordingFormat == nil || ["wav", "wav32", "mp3"].contains(track.recordingFormat!) else { throw ProjectError.invalid("Invalid recording format") }
                try track.patch?.validate(allowMaster: true, allowGroup: track.parentTrackID != nil, allowNone: true)
                try track.secondaryPatch?.validate(allowMaster: true, allowGroup: track.parentTrackID != nil, allowNone: true)
                for patch in track.outputPatches { try patch.validate(allowMaster: true, allowGroup: track.parentTrackID != nil, allowNone: true) }
                guard track.volume.isFinite, (0...pow(10.0, 12.0 / 20.0)).contains(track.volume), track.pan.isFinite, (-1...1).contains(track.pan), track.output > 0 else { throw ProjectError.invalid("Controle de pista inválido.") }
                for clip in track.clips {
                    if clip.frozenMIDI == true || clip.renderedTiming == true {
                        guard track.kind == .standard, clip.audioFile != nil, clip.midi == nil else { throw ProjectError.invalid("Frozen MIDI requires an audio item") }
                    }
                    if let midi = clip.midi {
                        guard track.kind == .standard, clip.audioFile == nil, clip.text == nil, clip.loopLength == nil else { throw ProjectError.invalid("MIDI items require an instrument track and cannot contain audio") }
                        try midi.validate()
                    }
                    guard track.kind != .click || clip.audioFile == nil || clip.isProjectionMedia else { throw ProjectError.invalid("Click items use the built-in sound") }
                    guard clip.text == nil || track.kind.isText else { throw ProjectError.invalid("Text items require a Teleprompter or Chords track") }
                    if let text = clip.text { try AudioClip.validateText(text, maximum: track.kind.maximumTextLength ?? AudioClip.maximumTextLength) }
                    // Source timing also locates the visual repeat seams of stretched text.
                    if track.kind.isText && !clip.isProjectionMedia { guard clip.audioFile == nil, clip.gain == nil, clip.muted != true, clip.waveform.isEmpty, (clip.waveformChannels ?? []).isEmpty, clip.loopLength != nil || (clip.sourceOffset == 0 && clip.loopStart == nil) else { throw ProjectError.invalid("Text items cannot contain audio") } }
                    guard clip.fx == nil || track.kind == .standard || clip.isProjectionMedia else { throw ProjectError.invalid("Item FX requires an audio item") }
                    guard clip.fxBypassed == nil || track.kind == .standard || clip.isProjectionMedia else { throw ProjectError.invalid("Item FX requires an audio item") }
                    try clip.fx?.validateForClip()
                    if let settings = clip.timecode {
                        guard track.kind == .timecode else { throw ProjectError.invalid("Timecode settings require a Timecode item") }
                        try settings.validate()
                    }
                    let timecodeOffsets = [clip.timecodeStartOffset, clip.timecodeEndOffset].compactMap { $0 }
                    guard timecodeOffsets.allSatisfy(\.isFinite), timecodeOffsets.isEmpty || track.kind == .timecode else { throw ProjectError.invalid("Invalid Timecode span") }
                    guard track.kind != .timecode || clip.isProjectionMedia || (clip.loopStart == nil && clip.loopLength == nil) else { throw ProjectError.invalid("Timecode items cannot repeat their source") }
                    if let start = clip.loopStart, !start.isFinite || start < 0 { throw ProjectError.invalid("Invalid loop start") }
                    if let length = clip.loopLength, !length.isFinite || length <= 0 { throw ProjectError.invalid("Invalid loop length") }
                    try register(clip.id)
                    guard (clip.waveformChannels ?? []).allSatisfy({ $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }) else { throw ProjectError.invalid("Invalid channel waveform") }
                    guard clip.audioRate.isFinite, (1.0/32...32).contains(clip.audioRate) else { throw ProjectError.invalid("Invalid audio playback rate.") }
                    guard clip.channelMode == nil || (0...3).contains(clip.channelMode!) else { throw ProjectError.invalid("Invalid item channel mode") }
                guard (clip.pitchSemitones ?? 0).isFinite, (-12...12).contains(clip.pitchSemitones ?? 0) else { throw ProjectError.invalid("Invalid item pitch") }
                guard clip.normalizationGain == nil || (clip.normalizationGain!.isFinite && clip.normalizationGain! >= 0 && clip.normalizationGain! <= pow(10, 24.0 / 20)) else { throw ProjectError.invalid("Invalid normalization gain") }
                    guard [clip.fadeIn, clip.fadeOut].allSatisfy({ $0 == nil || ($0!.isFinite && $0! >= 0) }) else { throw ProjectError.invalid("Invalid item fade") }
                    guard (clip.pan ?? 0).isFinite, (-1...1).contains(clip.pan ?? 0) else { throw ProjectError.invalid("Invalid item pan") }
                    guard clip.gain == nil || (clip.gain!.isFinite && clip.gain! >= 0) else { throw ProjectError.invalid("Invalid clip gain") }
                    guard clip.startTime.isFinite, clip.duration.isFinite, clip.startTime >= 0, clip.duration > 0, clip.startTime + clip.duration <= song.duration, clip.sourceOffset.isFinite, clip.sourceOffset >= 0, clip.waveform.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw ProjectError.invalid("Bloco de áudio inválido.") }
                }
                for file in [track.audioFile, track.clickSound].compactMap({ $0 }) + track.clips.compactMap(\.audioFile) {
                    let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
                    guard !file.path.isEmpty, !file.path.contains("\\"), !file.path.contains(":"), parts.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }) else { throw ProjectError.invalid("Use caminhos relativos para o áudio.") }
                    if let hash = file.sha256 { guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw ProjectError.invalid("SHA-256 inválido.") } }
                }
            }
            for marker in song.markers ?? [] {
                if let bpm = marker.tempoBPM {
                    guard bpm.isFinite, TimelineTempo.bpmRange.contains(bpm), (1...32).contains(marker.tempoBeats ?? 4), TimelineTempo.beatUnits.contains(marker.tempoUnit ?? 4), marker.unifiedRegionID == nil, marker.sourceRegionID == nil else { throw ProjectError.invalid("Invalid tempo marker") }
                    if let reference = marker.tempoReferenceBPM, !reference.isFinite || !TimelineTempo.bpmRange.contains(reference) { throw ProjectError.invalid("Invalid tempo reference") }
                } else if marker.tempoBeats != nil || marker.tempoUnit != nil || marker.tempoTimebase != nil || marker.tempoReferenceBPM != nil { throw ProjectError.invalid("Invalid tempo marker") }
                try register(marker.id)
                guard !marker.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      (marker.unifiedRegionID != nil || marker.name.count <= (marker.isSection ? TimelineMarker.maximumSectionNameLength : TimelineMarker.maximumNameLength)), marker.color <= 0xffffff,
                      marker.position.isFinite, marker.position >= 0, marker.position <= song.duration else { throw ProjectError.invalid("Invalid marker") }
            }
            guard RegionLanes(parts: song.parts).count <= 2 else { throw ProjectError.invalid("No máximo duas regiões sobrepostas.") }
            for part in song.parts {
                for loop in part.multiLoops ?? [] { try register(loop.id); try loop.validate() }
                try register(part.id)
                if let parentID = part.parentRegionID {
                    guard let parent = song.parts.first(where: { $0.id == parentID }), parent.parentRegionID == nil,
                          parent.id != part.id, part.startTime >= parent.startTime, part.endTime <= parent.endTime else {
                        throw ProjectError.invalid("Invalid unified region")
                    }
                }
                guard (-12...12).contains(part.semitones), Set(part.pitchTrackIDs ?? []).count == (part.pitchTrackIDs ?? []).count, Set(part.pitchGroupIDs ?? []).count == (part.pitchGroupIDs ?? []).count else { throw ProjectError.invalid("Invalid region pitch") }
                guard part.color == nil || part.color! <= 0xFFFFFF else { throw ProjectError.invalid("Invalid region color") }
                guard part.startTime.isFinite, part.endTime.isFinite, part.startTime >= 0, part.endTime > part.startTime, part.endTime <= song.duration else { throw ProjectError.invalid("Intervalo da parte inválido.") }
            }
        }
        if let state = regionSetlist {
            for playlist in state.playlists {
                try register(playlist.id)
                guard !playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let song = songs.first(where: { $0.id == playlist.songId }),
                      Set(playlist.regionIds).count == playlist.regionIds.count,
                      playlist.regionIds.allSatisfy({ id in song.parts.contains { $0.id == id } })
                else { throw ProjectError.invalid("Invalid region playlist") }
            }
            guard state.selectedId == nil || state.playlists.contains(where: { $0.id == state.selectedId }) else { throw ProjectError.invalid("Invalid selected playlist") }
            for block in state.blocks ?? [] {
                try register(block.id)
                guard !block.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, block.color <= 0xffffff,
                      let song = songs.first(where: { $0.id == block.songId }) else { throw ProjectError.invalid("Invalid setlist block") }
                if let playlist = block.playlistId {
                    guard let list = state.playlists.first(where: { $0.id == playlist && $0.songId == block.songId }),
                          block.beforeRegionId == nil || list.regionIds.contains(block.beforeRegionId!) else { throw ProjectError.invalid("Invalid block playlist") }
                } else if let before = block.beforeRegionId {
                    guard song.parts.contains(where: { $0.id == before }) else { throw ProjectError.invalid("Invalid block region") }
                }
            }
        }
        let songIDs = Set(songs.map(\.id))
        for setlist in setlists {
            try register(setlist.id)
            guard Set(setlist.songIds).count == setlist.songIds.count, setlist.songIds.allSatisfy(songIDs.contains) else { throw ProjectError.invalid("Repertório inválido.") }
        }
    }
    public static func empty(name: String) -> Project {
        let date = ISO8601DateFormatter().string(from: Date())
        let song = Song(id: UUID(), name: name, duration: 300, bpm: 120, tracks: [], parts: [], timeSettings: ProjectTimeSettings())
        return Project(id: UUID(), name: name, createdAt: date, updatedAt: date, setlists: [Setlist(id: UUID(), name: name, songIds: [song.id])], songs: [song])
    }
    public static func demo() -> Project {
        let names = ["Abertura", "Música 01", "Música 02", "Música 03", "Final"]
        let roles: [(String,TrackRole)] = [("Click",.click),("Guia",.guide),("Drums",.drums),("Percussão",.drums),("Bass",.bass),("Guitar L",.guitar),("Guitar R",.guitar),("Keys",.keys),("Strings",.keys),("Sanfona",.accordion),("Backing Vocal",.backingVocal),("FX",.fx)]
        let songs = names.enumerated().map { index, name -> Song in
            let duration = [96.0, 216, 240, 192, 120][index]
            let tracks = roles.enumerated().map { trackIndex, pair -> Track in
                var track = Track(id: UUID(), name: pair.0, role: pair.1)
                let sections = trackIndex < 5 ? 4 : 6
                for section in 0..<sections {
                    if trackIndex > 4 && (section + trackIndex) % 3 == 0 { continue }
                    let step = duration / Double(sections)
                    let start = Double(section) * step
                    let length = step * (trackIndex < 5 ? 1 : 0.85)
                    // Explicit demo overview, not analysis of a real audio file.
                    let peaks = (0..<96).map { sample in
                        let pulse = abs(sin(Double(sample * (trackIndex + 3) + section) * 0.43))
                        return 0.08 + pulse * (trackIndex < 5 ? 0.83 : 0.58)
                    }
                    track.clips.append(AudioClip(id: UUID(), name: pair.0, startTime: start, duration: length, waveform: peaks))
                }
                return track
            }
            return Song(id: UUID(), name: name, duration: duration, bpm: [96.0, 124, 108, 132, 90][index], tracks: tracks, parts: [])
        }
        let date = ISO8601DateFormatter().string(from: Date())
        return Project(id: UUID(), name: "Show de demonstração", createdAt: date, updatedAt: date, setlists: [Setlist(id: UUID(), name: "Repertório principal", songIds: songs.map(\.id))], songs: songs)
    }
}
public enum ProjectError: LocalizedError { case invalid(String); public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil } }
public struct QueueState: Codable, Equatable, Sendable { public var songId: UUID? }
public struct LoopState: Codable, Equatable, Sendable { public var enabled: Bool; public var start: Double? = nil; public var end: Double? = nil }
public struct SubPlayState: Codable, Equatable, Sendable { public var playing: Bool; public var position: Double }
public struct TransportState: Codable, Equatable, Sendable {
    public var multiLoopsBypassed: Bool? = nil
    public var queuedSectionMarkerId: UUID?
    public var sectionQueueStartedAt: Double?
    public var sectionJumpSerial: UInt64?
    public var multiLoop: MultiLoopPlayback?
    public var ignoreNextAfter: Double?
    public var ignoreNextEnd: Double?
    public var ignoreNextRegionId: UUID?
    public var subPlayPromotion: UInt64?
    public var playing: Bool; public var songId: UUID?; public var position: Double
    public var paused: Bool?
    public var editPosition: Double?
    public var regionId: UUID?; public var queuedRegionId: UUID?; public var queueStartedAt: Double?
    public var queue: QueueState; public var loop: LoopState; public var subPlay: SubPlayState
}
public struct AudioRoute: Codable, Sendable { public var trackId: UUID; public var output: Int }
public struct AudioRouting: Codable, Sendable { public var routes: [AudioRoute] }
public struct MixerState: Codable, Sendable { public var tracks: [Track]; public var routing: AudioRouting }
public struct ShowSnapshot: Codable, Sendable { public var project: Project; public var transport: TransportState; public var nextSongId: UUID? }

public struct PlaybackSnapshot: Codable, Sendable { public var transport: TransportState; public var nextSongId: UUID? }

/// Interval partitioning: adjacent items share a lane; simultaneous items never do.
public struct TrackLanes: Equatable {
    public var lanes: [UUID: Int] = [:]
    public var count: Int = 1
    public init(track: Track) {
        var ends: [Double] = []
        let ordered = track.clips.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.id.uuidString < $1.id.uuidString
        }
        // Lay out existing material first. A new take stays below the material
        // it overlaps, even if recording starts before that material begins.
        for clip in ordered where clip.recordingLane == nil {
            let lane = ends.firstIndex(where: { $0 <= clip.startTime }) ?? ends.count
            if lane == ends.count { ends.append(0) }
            ends[lane] = clip.startTime + clip.duration
            lanes[clip.id] = lane
        }
        var placed = ordered.filter { $0.recordingLane == nil }
        let takes = ordered.filter { $0.recordingLane != nil }.sorted {
            if $0.recordingLane != $1.recordingLane { return ($0.recordingLane ?? 0) < ($1.recordingLane ?? 0) }
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.id.uuidString < $1.id.uuidString
        }
        for clip in takes {
            let lane = recordingLane(start: clip.startTime, duration: clip.duration, clips: placed)
            lanes[clip.id] = lane
            placed.append(clip)
        }
        count = max(1, (lanes.values.max() ?? 0) + 1)
    }
    /// No overlapping item means lane zero, regardless of items elsewhere.
    public func recordingLane(start: Double, duration: Double, clips: [AudioClip]) -> Int {
        let end = start + duration
        return clips.lazy.filter { $0.startTime < end && $0.startTime + $0.duration > start }
            .compactMap { lanes[$0.id] }.max().map { $0 + 1 } ?? 0
    }
}

public struct RegionLanes: Equatable {
    public var lanes: [UUID: Int] = [:]
    public var count: Int = 1
    public init(parts: [Part]) {
        var ends: [Double] = []
        for part in parts.filter({ $0.parentRegionID == nil }).sorted(by: { $0.startTime == $1.startTime ? ($0.endTime == $1.endTime ? $0.id.uuidString < $1.id.uuidString : $0.endTime > $1.endTime) : $0.startTime < $1.startTime }) {
            let lane = ends.firstIndex(where: { $0 <= part.startTime }) ?? ends.count
            if lane == ends.count { ends.append(part.endTime) } else { ends[lane] = part.endTime }
            lanes[part.id] = lane
        }
        count = max(1, ends.count)
    }
}


public enum TrackKind: String, CaseIterable, Sendable {
    case standard, video, timecode, teleprompt, teleprompt2, chords
    case click = "generatedClick"
    public var defaultColor: UInt32? {
        switch self {
        case .click: return 0x77d18b
        case .timecode: return 0xffdc52
        case .chords: return 0x529eff
        case .teleprompt, .teleprompt2: return 0x54ff93
        case .video: return 0xb47aff
        case .standard: return nil
        }
    }
    public var title: String { switch self { case .click: return "Click"; case .standard: return "Standard"; case .video: return "Video"; case .timecode: return "Timecode"; case .teleprompt: return "Teleprompter 1"; case .teleprompt2: return "Teleprompter 2"; case .chords: return "Chords" } }
    public var isTeleprompter: Bool { self == .teleprompt || self == .teleprompt2 }
    public var isText: Bool { isTeleprompter || self == .chords }
    public var isSingleLane: Bool { isText || self == .video }
    public var maximumTextLength: Int? { isTeleprompter ? 400 : self == .chords ? 30 : nil }
}
public extension AudioClip {
    static let maximumTextLength = 400
    static func validateText(_ text: String, maximum: Int = maximumTextLength) throws {
        guard text.unicodeScalars.count <= maximum else {
            throw ProjectError.invalid(maximum == 30 ? "Chords text must contain at most 30 characters" : "Teleprompter text must contain at most 400 characters")
        }
    }
}
public struct TimecodeSettings: Codable, Equatable, Sendable {
    public var mode = "mtc"
    public var frameRate = 30.0
    public var offset = 0.0
    public var regionRelative = true
    public var midiDestination: Int32 = 0
    public init() {}
    public func validate() throws {
        guard ["mtc", "ltc"].contains(mode), [24.0,25,29.97,30].contains(frameRate), offset.isFinite, (0..<86400).contains(offset) else { throw ProjectError.invalid("Invalid timecode settings") }
    }
}
extension Track {
    public var kind: TrackKind { TrackKind(rawValue: role.rawValue) ?? .standard }
    public var fixedName: String? { kind == .standard ? nil : kind.title }
    public func canPlaceItem(start: Double, duration: Double, excluding id: UUID? = nil, media: Bool? = nil) -> Bool {
        guard start.isFinite, duration.isFinite, start >= 0, duration > 0 else { return false }
        guard kind.isSingleLane else { return true }
        let media = media ?? (id.flatMap { id in clips.first { $0.id == id }?.isProjectionMedia } ?? false)
        return !clips.contains { $0.id != id && (!kind.isTeleprompter || $0.isProjectionMedia == media) && start < $0.startTime + $0.duration - 0.0000001 && start + duration > $0.startTime + 0.0000001 }
    }
    /// Single-lane items can be dragged past one another, but never stacked.
    public func constrainedItemStart(_ proposed: Double, item: AudioClip) -> Double {
        let proposed = max(0, proposed)
        guard kind.isSingleLane, !canPlaceItem(start: proposed, duration: item.duration, excluding: item.id) else { return proposed }
        let others = clips.filter { $0.id != item.id && (!kind.isTeleprompter || $0.isProjectionMedia == item.isProjectionMedia) }
        let candidates = [0.0] + others.flatMap { [$0.startTime - item.duration, $0.startTime + $0.duration] }
        return candidates.filter { canPlaceItem(start: $0, duration: item.duration, excluding: item.id) }
            .min { abs($0 - proposed) < abs($1 - proposed) } ?? item.startTime
    }
    public func constrainedItemEdges(start: Double, end: Double, item: AudioClip) -> (Double, Double) {
        guard kind.isSingleLane else { return (start, end) }
        let others = clips.filter { $0.id != item.id && (!kind.isTeleprompter || $0.isProjectionMedia == item.isProjectionMedia) }
        let left = others.filter { $0.startTime + $0.duration <= item.startTime + 0.0000001 }.map { $0.startTime + $0.duration }.max() ?? 0
        let right = others.filter { $0.startTime >= item.startTime + item.duration - 0.0000001 }.map(\.startTime).min() ?? .infinity
        return (max(left, start), min(right, end))
    }
}

public extension Song {
    /// Resolve imported material once; nil then means intentionally unattached.
    func regionOwner(at start: Double, end: Double? = nil) -> UUID? {
        parts.filter { start >= $0.startTime - 1e-8 && start < $0.endTime - 1e-8 && (end == nil || end! <= $0.endTime + 1e-8) }
            .min {
                if ($0.parentRegionID != nil) != ($1.parentRegionID != nil) { return $0.parentRegionID != nil }
                if $0.endTime - $0.startTime != $1.endTime - $1.startTime { return $0.endTime - $0.startTime < $1.endTime - $1.startTime }
                return $0.id.uuidString < $1.id.uuidString
            }?.id
    }
    func regionOwns(_ root: UUID, owner: UUID?) -> Bool {
        guard let owner else { return false }
        return owner == root || parts.contains { $0.id == owner && $0.parentRegionID == root }
    }
    /// Match the engine's placement rule. Editing a marker in place preserves
    /// its attachment (including intentionally loose markers); moving or
    /// creating it assigns the region at the destination before any retiming.
    func markerWithRegionOwnership(_ marker: TimelineMarker) -> TimelineMarker {
        var result = marker
        if let previous = markers?.first(where: { $0.id == marker.id }), previous.position == marker.position {
            result.regionOwnerID = previous.regionOwnerID
        } else {
            result.regionOwnerID = regionOwner(at: marker.position)
        }
        return result
    }
    func itemBelongs(_ clip: AudioClip, to root: UUID) -> Bool {
        regionOwns(root, owner: regionOwnershipInitialized == true ? clip.regionOwnerID : regionOwner(at: clip.startTime))
    }
    func markerBelongs(_ marker: TimelineMarker, to root: UUID) -> Bool {
        marker.unifiedRegionID == root || regionOwns(root, owner: regionOwnershipInitialized == true ? marker.regionOwnerID : marker.sourceRegionID ?? regionOwner(at: marker.position))
    }
}

public extension Song {
    /// Visual counterpart of Engine::moveRegion. All positions are tested
    /// against the original region before applying the same displacement once.
    func previewMovingRegion(_ id: UUID, to start: Double) -> Song {
        guard start.isFinite, start >= 0,
              let region = parts.first(where: { $0.id == id && $0.parentRegionID == nil }) else { return self }
        let delta = start - region.startTime
        var result = self
        for track in result.tracks.indices {
            for index in result.tracks[track].clips.indices {
                let clip = result.tracks[track].clips[index]
                if result.tracks[track].kind == .timecode && result.tracks[track].importedTimecodeItems != true {
                    // Native Timecode may extend past its owning region's edges.
                    guard clip.id == Project.timecodeItemID(id) else { continue }
                    let newStart = max(0, start + (clip.timecodeStartOffset ?? 0))
                    let newEnd = max(newStart + 0.01, region.endTime + delta + (clip.timecodeEndOffset ?? 0))
                    result.tracks[track].clips[index].startTime = newStart
                    result.tracks[track].clips[index].duration = newEnd - newStart
                    result.duration = max(result.duration, newEnd)
                } else if itemBelongs(clip, to: id) {
                    result.tracks[track].clips[index].startTime = max(0, clip.startTime + delta)
                }
            }
        }
        for index in result.parts.indices where result.parts[index].id == id || result.parts[index].parentRegionID == id {
            result.parts[index].startTime += delta
            result.parts[index].endTime += delta
            result.duration = max(result.duration, result.parts[index].endTime)
        }
        if var markers = result.markers {
            for index in markers.indices {
                let marker = markers[index]
                if markerBelongs(marker, to: id) {
                    markers[index].position = max(0, marker.position + delta)
                    result.duration = max(result.duration, markers[index].position)
                }
            }
            result.markers = markers
        }
        return RegionLanes(parts: result.parts).count <= 2 ? result : self
    }
}

/// Forbidden region-start intervals caused by moving marker points passing
/// stationary points. Prepared once per drag, with a zoom-aware visual margin.
public struct RegionMarkerRepulsion {
    private var intervals: [ClosedRange<Double>] = []
    private let originalStart: Double
    private var minimumStart = 0.0
    public init(song: Song, region: Part, minimumGap: Double = 0.01) {
        originalStart = region.startTime
        let gap = minimumGap.isFinite ? max(0.01, minimumGap) : 0.01
        var offsets: [Double] = [], stationary: [Double] = []
        for marker in song.markers ?? [] {
            if song.markerBelongs(marker, to: region.id) { offsets.append(marker.position - region.startTime) }
            else { stationary.append(marker.position) }
        }
        minimumStart = max(0, -(offsets.min() ?? 0))
        var ranges: [ClosedRange<Double>] = []
        for offset in offsets {
            for point in stationary {
                let center = point - offset
                if center + gap > minimumStart { ranges.append((center - gap)...(center + gap)) }
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        for range in ranges {
            if let last = intervals.last, range.lowerBound < last.upperBound {
                intervals[intervals.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else { intervals.append(range) }
        }
    }
    public func resolve(_ proposed: Double) -> Double {
        guard proposed.isFinite else { return originalStart }
        let start = max(minimumStart, proposed)
        // Binary search avoids rebuilding/scanning marker pairs on each frame.
        var low = 0, high = intervals.count
        while low < high {
            let mid = (low + high) / 2
            if intervals[mid].upperBound <= start + 1e-9 { low = mid + 1 } else { high = mid }
        }
        guard low < intervals.count else { return start }
        let range = intervals[low]
        guard start > range.lowerBound + 1e-9 && start < range.upperBound - 1e-9 else { return start }
        if range.lowerBound < minimumStart { return range.upperBound }
        let left = start - range.lowerBound, right = range.upperBound - start
        if abs(left - right) <= 1e-9 { return proposed >= originalStart ? range.upperBound : range.lowerBound }
        return left < right ? range.lowerBound : range.upperBound
    }
}

public extension Song {
    /// Timeline order is the projection priority. Teleprompters opt into their
    /// own source track; the main video window scans every track from the top.
    func firstProjectionItem(at position: Double, trackKind: TrackKind? = nil) -> AudioClip? {
        guard position.isFinite else { return nil }
        for track in tracks where !track.mute && (trackKind == nil || track.kind == trackKind) {
            for clip in track.clips where clip.isProjectionMedia && clip.muted != true && position >= clip.startTime && position < clip.startTime + clip.duration { return clip }
        }
        return nil
    }
}

/// Immutable scheduling index rebuilt with the clip revision. Playback asks
/// only for items intersecting its lookahead, rather than scanning every song.
public struct AudioClipPlaybackIndex {
    private struct Entry {
        let source: Int
        let start: Double
        let end: Double
    }
    private struct Node {
        let entry: Entry
        let minimumStart: Double
        let maximumEnd: Double
        let left: Int?
        let right: Int?
    }
    private var nodes: [Node] = []
    private var root: Int?
    public init(clips: [AudioClip]) {
        var entries: [Entry] = []
        entries.reserveCapacity(clips.count)
        for (index, clip) in clips.enumerated() {
            entries.append(Entry(source: index, start: clip.startTime, end: clip.startTime + clip.duration))
        }
        entries.sort { first, second in
            first.start == second.start ? first.source < second.source : first.start < second.start
        }
        nodes.reserveCapacity(entries.count)
        root = build(entries, 0, entries.count)
    }
    private mutating func build(_ entries: [Entry], _ first: Int, _ last: Int) -> Int? {
        guard first < last else { return nil }
        let middle = (first + last) / 2
        let left = build(entries, first, middle), right = build(entries, middle + 1, last)
        let end = max(entries[middle].end, left.map { nodes[$0].maximumEnd } ?? -.infinity, right.map { nodes[$0].maximumEnd } ?? -.infinity)
        let index = nodes.count
        nodes.append(Node(entry: entries[middle], minimumStart: entries[first].start, maximumEnd: end, left: left, right: right))
        return index
    }
    public func candidates(at position: Double, lookahead: Double = 2) -> [Int] {
        guard position.isFinite, lookahead.isFinite else { return [] }
        var result: [Int] = []
        collect(root, from: position, through: position + max(0, lookahead), into: &result)
        // Preserve the existing per-track scheduling order and common onset.
        result.sort()
        return result
    }
    private func collect(_ index: Int?, from position: Double, through end: Double, into result: inout [Int]) {
        guard let index else { return }
        let node = nodes[index]
        guard node.maximumEnd > position, node.minimumStart <= end else { return }
        collect(node.left, from: position, through: end, into: &result)
        if node.entry.start <= end && node.entry.end > position { result.append(node.entry.source) }
        collect(node.right, from: position, through: end, into: &result)
    }
}
