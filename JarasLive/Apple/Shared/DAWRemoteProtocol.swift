import Foundation

/// The Remote exchanges native presentation state, typed actions and requested
/// still images, never screen captures, audio, file paths or pointer coordinates.
enum DAWRemoteWire {
    static let service = "jaras-live"
    static let version: UInt8 = 2
    static let maximumPacket = 2 * 1024 * 1024
    enum Packet { case command(DAWRemoteCommand), state(DAWRemoteState), acknowledge(UInt64), imageAsset(DAWRemoteImageAsset), accessRequest(DAWRemoteAccessRequest), accessStatus(DAWRemoteAccessStatus) }
    enum Failure: Error { case invalid }
    private static func encode<T: Encodable>(_ value: T, kind: UInt8) throws -> Data {
        var data = Data([0x4a, 0x4c, version, kind])
        data.append(try JSONEncoder().encode(value))
        guard data.count <= maximumPacket else { throw Failure.invalid }
        return data
    }
    static func command(_ value: DAWRemoteCommand) throws -> Data {
        guard value.valid else { throw Failure.invalid }
        return try encode(value, kind: 1)
    }
    static func state(_ value: DAWRemoteState) throws -> Data {
        guard value.valid else { throw Failure.invalid }
        return try encode(value, kind: 2)
    }
    static func accessRequest(_ request: DAWRemoteAccessRequest) throws -> Data {
        guard request.valid else { throw Failure.invalid }
        return try encode(request, kind: 5)
    }
    static func accessStatus(_ status: DAWRemoteAccessStatus) throws -> Data { try encode(status, kind: 6) }
    static func acknowledge(_ sequence: UInt64) throws -> Data { try encode(sequence, kind: 3) }
    static func imageAsset(_ asset: DAWRemoteImageAsset) throws -> Data {
        guard asset.data.count <= DAWRemoteImageAsset.maximumBytes else { throw Failure.invalid }
        var data = Data([0x4a, 0x4c, version, 4])
        var project = asset.project.uuid, id = asset.id.uuid
        withUnsafeBytes(of: &project) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &id) { data.append(contentsOf: $0) }
        data.append(asset.data)
        return data
    }
    static func decode(_ data: Data) throws -> Packet {
        guard data.count >= 4, data.count <= maximumPacket,
              Array(data.prefix(3)) == [0x4a, 0x4c, version] else { throw Failure.invalid }
        let payload = data.dropFirst(4), decoder = JSONDecoder()
        switch data[3] {
        case 1:
            guard data.count <= 8192 else { throw Failure.invalid }
            let value = try decoder.decode(DAWRemoteCommand.self, from: payload)
            guard value.valid else { throw Failure.invalid }; return .command(value)
        case 2:
            let value = try decoder.decode(DAWRemoteState.self, from: payload)
            guard value.valid else { throw Failure.invalid }; return .state(value)
        case 3:
            guard data.count <= 64 else { throw Failure.invalid }
            return .acknowledge(try decoder.decode(UInt64.self, from: payload))
        case 4:
            guard data.count >= 36, data.count - 36 <= DAWRemoteImageAsset.maximumBytes else { throw Failure.invalid }
            func uuid(at start: Int) -> UUID {
                let b = Array(data[start..<(start + 16)])
                return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
            }
            return .imageAsset(.init(project: uuid(at: 4), id: uuid(at: 20), data: Data(data.dropFirst(36))))
        case 5:
            guard data.count <= 256 else { throw Failure.invalid }
            let request = try decoder.decode(DAWRemoteAccessRequest.self, from: payload)
            guard request.valid else { throw Failure.invalid }; return .accessRequest(request)
        case 6:
            guard data.count <= 1024 else { throw Failure.invalid }
            return .accessStatus(try decoder.decode(DAWRemoteAccessStatus.self, from: payload))
        default: throw Failure.invalid
        }
    }
}
enum DAWRemoteAccess: String, Codable { case director, observer }
struct DAWRemoteAccessRequest: Codable {
    var mode: DAWRemoteAccess
    var pin: String = ""
    var valid: Bool { pin.isEmpty || (pin.utf8.count == 4 && pin.utf8.allSatisfy { (48...57).contains($0) }) }
}
struct DAWRemoteAccessStatus: Codable {
    var mode: DAWRemoteAccess?
    var requiresPIN: Bool
    var error: String? = nil
}
/// An observer may only subscribe to a local TP view or fetch its still images.
/// This whitelist is enforced by the Mac before any application command handler.
enum DAWRemoteAccessRules {
    static func allows(_ command: DAWRemoteCommand, mode: DAWRemoteAccess?) -> Bool {
        guard command.valid, let mode else { return false }
        if mode == .director { return true }
        return command.action == .requestImage || (command.action == .remotePanel && (0...2).contains(command.value))
    }
}
struct DAWRemoteImageAsset: Equatable {
    static let maximumBytes = 1_572_864
    var project: UUID
    var id: UUID
    /// Empty data is an unavailable response, preventing automatic retry loops.
    var data: Data
}
struct DAWRemoteCommand: Codable {
    enum Action: String, Codable {
        case play, pause, stop, subPlay, subStop, toggleLoop, seek
        case volume, pan, mute, solo, masterMono, selectRegion, selectSong, tempo, pitch, save, toggleRegionAuto, clipGain, clipMute, selectPlaylist, openRecentProject
        case remotePanel, noticeSend, noticeClear, noticePin, noticeDestination, noticeSaveTemplate
        case requestImage
        case timerStart, timerStop
    }
    var id = UUID()
    var project: UUID
    var song: UUID?
    var action: Action
    var target: UUID? = nil
    var value: Double = 0
    var text: String? = nil
    var enabled: Bool? = nil
    var valid: Bool {
        guard value.isFinite else { return false }
        if let text {
            guard [.noticeSend, .noticeSaveTemplate].contains(action), text.count <= 500, text.utf8.count <= 4000 else { return false }
        }
        if enabled != nil && action != .noticeDestination { return false }
        switch action {
        case .timerStart: return target == nil && (0...359999).contains(value) && value.rounded() == value
        case .timerStop: return target == nil && value == 0
        case .requestImage: return target != nil && value == 0
        case .remotePanel: return target == nil && (0...3).contains(value) && value.rounded() == value
        case .noticeSend: return target == nil && text != nil && (-1...2).contains(value) && value.rounded() == value
        case .noticeSaveTemplate: return target == nil && text != nil && (0...2).contains(value) && value.rounded() == value
        case .noticeClear: return target == nil && value == 0
        case .noticePin: return target == nil && (value == 0 || value == 1)
        case .noticeDestination: return target == nil && (value == 1 || value == 2) && enabled != nil
        case .openRecentProject: return target != nil && value == 0
        case .clipGain: return target != nil && (0...pow(10, 24.0 / 20)).contains(value)
        case .clipMute: return target != nil && value == 0
        case .volume: return (0...4).contains(value)
        case .pan: return (-1...1).contains(value) && target != nil
        case .tempo: return (20...400).contains(value)
        case .pitch: return (-6...6).contains(value) && value.rounded() == value && target != nil
        case .seek: return (0...604800).contains(value)
        case .selectRegion, .selectSong: return target != nil
        default: return value == 0
        }
    }
}
struct DAWRemoteState: Codable, Equatable {
    struct GridTempo: Codable, Equatable {
        var start: Double; var end: Double; var bpm: Double; var beats: Int; var unit: Int
        var valid: Bool {
            start.isFinite && end.isFinite && start >= 0 && end > start &&
            bpm.isFinite && (60...300).contains(bpm) && (1...32).contains(beats) &&
            [1, 2, 4, 8, 16, 32, 64].contains(unit)
        }
    }
    struct Clip: Codable, Identifiable, Equatable {
        var id: UUID; var name: String; var start: Double; var duration: Double
        var gain: Double? = nil
        var muted: Bool? = nil
        var lane: Int? = nil
    }
    struct Marker: Codable, Identifiable, Equatable {
        var id: UUID; var name: String; var position: Double; var color: UInt32
    }
    struct Track: Codable, Identifiable, Equatable {
        var id: UUID; var name: String; var color: UInt32
        var volume: Double; var pan: Double; var mute: Bool; var solo: Bool
        var clips: [Clip]
        var nameColor: UInt32? = nil
        var emphasized: Bool? = nil
        var silenced: Bool? = nil
        var laneCount: Int? = nil
        var linkedTrack: UUID? = nil
    }
    struct Region: Codable, Identifiable, Equatable {
        var id: UUID; var name: String; var start: Double; var end: Double; var color: UInt32
        var nameColor: UInt32? = nil
        var parentRegion: UUID? = nil
    }
    struct Song: Codable, Identifiable, Equatable { var id: UUID; var name: String }
    struct RecentProject: Codable, Identifiable, Equatable {
        var id: UUID; var name: String; var current: Bool
    }
    struct ProjectBrowser: Codable, Equatable {
        var recent: [RecentProject]
        var busy: Bool
        var canOpen: Bool
        var status: String
        var error: String
        var valid: Bool {
            recent.count <= 20 && Set(recent.map(\.id)).count == recent.count &&
            recent.filter(\.current).count <= 1 && recent.allSatisfy { !$0.name.isEmpty && $0.name.utf8.count <= 1024 } &&
            status.utf8.count <= 2048 && error.utf8.count <= 2048
        }
    }
    var sequence: UInt64 = 0
    var project: UUID
    var projectName: String
    var song: UUID?
    var songName: String
    var songs: [Song]
    var tracks: [Track]
    var regions: [Region]
    var timelineRegions: [Region]
    var currentRegion: UUID?
    var queuedRegion: UUID?
    var focusedRegion: UUID?
    var position: Double
    var duration: Double
    var bpm: Double
    var playing: Bool
    var paused: Bool
    var subPlaying: Bool
    var loop: Bool
    var masterVolume: Double
    var masterMute: Bool
    var masterSolo: Bool
    var masterMono: Bool
    var pendingSave: Bool
    var saving: Bool
    var message: String
    var pitchRegion: UUID? = nil
    var pitchSemitones: Int? = nil
    var setlistFontStyle: Int? = nil
    var prepareOnly: Bool? = nil
    var masterColor: UInt32? = nil
    var masterNameColor: UInt32? = nil
    var regionAuto: Bool? = nil
    var queueStartedAt: Double? = nil
    var playbackEnd: Double? = nil
    var projectSavedAt: String? = nil
    var footerInformation: String? = nil
    var upcomingName: String? = nil
    var upcomingKind: String? = nil
    var playlists: [Song]? = nil
    var selectedPlaylist: UUID? = nil
    var gridRegion: UUID? = nil
    var markers: [Marker]? = nil
    var projects: ProjectBrowser? = nil
    var teleprompters: [DAWRemoteTeleprompter]? = nil
    var notices: DAWRemoteNotices? = nil
    var timer: DAWRemoteTimerState? = nil
    var gridTempo: [GridTempo]? = nil
    var gridDivisions: Int? = nil
    var gridLines: Bool? = nil
    var gridPrimaryColor: UInt32? = nil
    var gridSecondaryColor: UInt32? = nil
    var valid: Bool {
        position.isFinite && duration.isFinite && bpm.isFinite && masterVolume.isFinite &&
        (gridTempo ?? []).count <= 32768 && (gridTempo ?? []).allSatisfy(\.valid) &&
        (gridDivisions == nil || [0, 2, 4, 8].contains(gridDivisions!)) &&
        (projects?.valid ?? true) && (notices?.valid ?? true) && (timer?.valid ?? true) &&
        (teleprompters ?? []).count <= 2 && (teleprompters ?? []).allSatisfy(\.valid) &&
        (markers ?? []).count <= 16384 && (markers ?? []).allSatisfy { $0.position.isFinite && $0.position >= 0 } &&
        position >= 0 && duration >= 0 && tracks.count <= 4096 && regions.count <= 8192 &&
        timelineRegions.count <= 8192 && songs.count <= 4096 &&
        tracks.allSatisfy { $0.volume.isFinite && $0.pan.isFinite && $0.clips.count <= 16384 && ($0.laneCount == nil || (1...10001).contains($0.laneCount!)) &&
            $0.clips.allSatisfy { $0.start.isFinite && $0.duration.isFinite && $0.duration >= 0 && ($0.lane == nil || (0...10000).contains($0.lane!)) && ($0.gain == nil || ($0.gain!.isFinite && $0.gain! >= 0 && $0.gain! <= pow(10, 24.0 / 20))) } } &&
        (regions + timelineRegions).allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }
    }
}

/// Only opaque identifiers and display names leave the Mac. Reordering recents
/// preserves identity; removing an entry also revokes its remote identifier.
struct DAWRemoteProjectCatalog {
    private var identifiers: [URL: UUID] = [:]
    mutating func update(_ urls: [URL], current: URL?) -> [DAWRemoteState.RecentProject] {
        var seen: Set<URL> = []
        let urls = urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }.prefix(20)
        identifiers = identifiers.filter { seen.contains($0.key) && urls.contains($0.key) }
        return urls.map { url in
            let id = identifiers[url] ?? UUID()
            identifiers[url] = id
            return .init(id: id, name: url.deletingPathExtension().lastPathComponent,
                         current: url == current?.standardizedFileURL)
        }
    }
    func url(for id: UUID) -> URL? { identifiers.first { $0.value == id }?.key }
}

/// Use the same -60 dB … +12 dB travel as the desktop faders.
enum DAWRemoteFaderScale {
    static func decibels(_ gain: Double) -> Double {
        guard gain.isFinite, gain > 0 else { return -60 }
        return min(12, max(-59.9, 20 * log10(gain)))
    }
    static func gain(_ decibels: Double) -> Double {
        guard decibels.isFinite, decibels > -60 else { return 0 }
        return pow(10, min(12, decibels) / 20)
    }
}

/// Drawer state belongs to the iPad presentation; choosing a child still sends
/// the normal selectRegion command to the authoritative Mac controller.
enum DAWRemoteSetlistPresentation {
    struct Row: Identifiable {
        var region: DAWRemoteState.Region
        var number: Int?
        var child: Bool
        var id: UUID { region.id }
    }
    static func children(of parent: UUID, in state: DAWRemoteState) -> [DAWRemoteState.Region] {
        state.timelineRegions.filter { $0.parentRegion == parent }.sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
    }
    static func drawer(in state: DAWRemoteState) -> DAWRemoteState.Region? {
        guard let selectedID = state.focusedRegion ?? state.currentRegion,
              let selected = (state.timelineRegions + state.regions).first(where: { $0.id == selectedID }) else { return nil }
        let parent = selected.parentRegion ?? selected.id
        guard !children(of: parent, in: state).isEmpty else { return nil }
        return state.regions.first { $0.id == parent }
    }
    static func rows(in state: DAWRemoteState, expanded: Set<UUID>, query: String) -> [Row] {
        var rows: [Row] = []
        for (index, region) in state.regions.enumerated() {
            rows.append(Row(region: region, number: index + 1, child: false))
            if expanded.contains(region.id) {
                rows += children(of: region.id, in: state).map { Row(region: $0, number: nil, child: true) }
            }
        }
        return rows.filter { query.isEmpty || $0.region.name.localizedStandardContains(query) }
    }
}

enum DAWRemoteScrollRange {
    static func clamp(_ offset: Double, content: Double, viewport: Double, topInset: Double = 0, bottomInset: Double = 0) -> Double {
        let minimum = -topInset
        return min(max(minimum, content - viewport + bottomInset), max(minimum, offset))
    }
}

/// Fractions of the space remaining after the two divider handles. A gesture
/// always derives its result from the original pair, so reversing also restores
/// a neighboring panel that the drag temporarily pushed out of view.
struct DAWRemotePanelWidths: Equatable {
    let track: Double
    let setlist: Double
    var grid: Double { max(0, 1 - track - setlist) }
    init(track: Double, setlist: Double) {
        self.track = track.isFinite ? min(1, max(0, track)) : 0
        self.setlist = setlist.isFinite ? min(1 - self.track, max(0, setlist)) : 0
    }
    func resizingTrack(by translation: Double) -> Self {
        guard translation.isFinite else { return self }
        return Self(track: track + translation, setlist: setlist)
    }
    func resizingSetlist(by translation: Double) -> Self {
        guard translation.isFinite else { return self }
        let width = min(1, max(0, setlist - translation))
        return Self(track: min(track, 1 - width), setlist: width)
    }
}

/// Match desktop lane heights while retaining alignment between mixer and grid.
enum DAWRemoteItemLayout {
    static func laneHeight(_ track: DAWRemoteState.Track) -> Double { (track.laneCount ?? 1) > 1 ? 86 * 0.7 : 86 }
    static func rowHeight(_ track: DAWRemoteState.Track) -> Double { laneHeight(track) * Double(max(1, track.laneCount ?? 1)) }
    /// Remote shows one region. Lanes occupied only by another song must not
    /// leave empty space here; overlapping visible items share the same compact
    /// interval partitioning rule as desktop TrackLanes.
    static func tracks(_ tracks: [DAWRemoteState.Track], within region: DAWRemoteState.Region?) -> [DAWRemoteState.Track] {
        tracks.map { original in
            var track = original
            track.clips = original.clips.filter { clip in
                guard let region else { return false }
                return clip.duration > 0 && clip.start < region.end && clip.start + clip.duration > region.start
            }.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
            var ends: [Double] = []
            for index in track.clips.indices {
                let clip = track.clips[index]
                let lane = ends.firstIndex { $0 <= clip.start } ?? ends.count
                if lane == ends.count { ends.append(clip.start + clip.duration) }
                else { ends[lane] = clip.start + clip.duration }
                track.clips[index].lane = lane
            }
            track.laneCount = max(1, ends.count)
            return track
        }
    }
}

/// Presentation data is requested only while an iPad teleprompter/messages panel is open.
/// It never changes the visibility of the Mac projection windows.
struct DAWRemoteTeleprompter: Codable, Equatable {
    struct Style: Codable, Equatable {
        var textColor: UInt32 = 0xffea00, chordColor: UInt32 = 0xfb923c
        var songColor: UInt32 = 0x00ff55, queueColor: UInt32 = 0xffea00
        var clockColor: UInt32 = 0x00ff55, localClockColor: UInt32 = 0x00ff55
        var borderColor: UInt32 = 0x00ff55, textBoxColor: UInt32 = 0xffea00, progressColor: UInt32 = 0xffea00
        var font = "system", chordFont = "system", textAlignment = "center"
        var textScale = 100.0, chordScale = 50.0
        var windowBorder = true, textBox = true, songEnabled = false, queueEnabled = true
        var clockEnabled = true, localClockEnabled = true, chordsEnabled = true, progressEnabled = false
        var clockPosition = "center-top", songPosition = "top", queuePosition = "top", chordPosition = "top", progressPosition = "bottom"
        var valid: Bool { textScale.isFinite && chordScale.isFinite && (0...150).contains(textScale) && (0...100).contains(chordScale) }
    }
    struct Row: Codable, Equatable, Identifiable {
        var id: UUID; var name: String; var color: UInt32; var duration: Double
    }
    struct Block: Codable, Equatable, Identifiable {
        var id: UUID; var name: String; var color: UInt32; var rows: [Row]
    }
    var index: Int
    var text: String, chords: String, song: String, queued: String
    var progress: Double
    var style: Style
    var preview: Bool = false
    var blocks: [Block] = []
    var mediaName: String? = nil
    var imageID: UUID? = nil
    // Optional for compatibility with hosts predating full native projection settings.
    var settings: TeleprompterSettings? = nil
    var resolvedSettings: TeleprompterSettings {
        if let settings { return settings.sanitized() }
        var result = TeleprompterSettings()
        result.textColor = style.textColor; result.chordColor = style.chordColor
        result.songNameColor = style.songColor; result.queueNameColor = style.queueColor
        result.clockColor = style.clockColor; result.localClockColor = style.localClockColor
        result.borderColor = style.borderColor; result.textBoxColor = style.textBoxColor; result.progressColor = style.progressColor
        result.fontFamily = style.font; result.chordFontFamily = style.chordFont; result.textAlignment = style.textAlignment
        result.textScale = style.textScale; result.chordScale = style.chordScale
        result.windowBorderEnabled = style.windowBorder; result.textBoxEnabled = style.textBox
        result.songNameEnabled = style.songEnabled; result.queueNameEnabled = style.queueEnabled
        result.clockEnabled = style.clockEnabled; result.localClockEnabled = style.localClockEnabled
        result.chordsEnabled = style.chordsEnabled; result.progressEnabled = style.progressEnabled
        result.clockPosition = style.clockPosition; result.songNamePosition = style.songPosition
        result.queueNamePosition = style.queuePosition; result.chordPosition = style.chordPosition; result.progressPosition = style.progressPosition
        return result.sanitized()
    }
    var valid: Bool {
        (1...2).contains(index) && progress.isFinite && (0...1).contains(progress) && style.valid &&
        text.utf8.count <= 65536 && chords.utf8.count <= 65536 && song.utf8.count <= 4096 && queued.utf8.count <= 4096 &&
        blocks.count <= 4 && blocks.allSatisfy { block in
            block.rows.count <= 8192 && block.rows.allSatisfy { $0.duration.isFinite && $0.duration >= 0 }
        }
    }
}
struct DAWRemoteNotices: Codable, Equatable {
    var templates: [String]
    var imageSlots: [Bool]
    var message: String
    var active: Bool, pinned: Bool
    var remaining: Int
    var window1: Bool, window2: Bool
    var textColor: UInt32, backgroundColor: UInt32, flashColor: UInt32
    var font: String, scale: Double, emoji: String
    var cleanDisplay: Bool
    var sentAt: Double
    var imageID: UUID? = nil
    var valid: Bool {
        templates.count == 3 && imageSlots.count == 3 && templates.allSatisfy { $0.count <= 500 && $0.utf8.count <= 4000 } &&
        message.count <= 500 && message.utf8.count <= 4000 && (0...20).contains(remaining) &&
        sentAt.isFinite && scale.isFinite && (50...100).contains(scale)
    }
}
struct DAWRemoteTimerState: Codable, Equatable {
    var revision: UUID
    var targetSeconds: Int
    var running: Bool
    var remainingSeconds: Double
    var commandID: UUID? = nil
    var valid: Bool { (0...359999).contains(targetSeconds) && remainingSeconds.isFinite }
}
