import Foundation

/// The Remote exchanges native presentation state, typed actions and requested
/// still images, never screen captures, audio, file paths or pointer coordinates.
enum DAWRemoteWire {
    static let service = "jaras-live"
    static let version: UInt8 = 2
    static let maximumPacket = 2 * 1024 * 1024
    enum Packet { case projectSync(Data), command(DAWRemoteCommand), state(DAWRemoteState), acknowledge(UInt64), noticeReceipt(DAWRemoteNoticeReceipt), imageAsset(DAWRemoteImageAsset), accessRequest(DAWRemoteAccessRequest), accessStatus(DAWRemoteAccessStatus) }
    enum Failure: Error { case invalid }
    private static func encode<T: Encodable>(_ value: T, kind: UInt8) throws -> Data {
        var data = Data([0x4a, 0x4c, version, kind])
        data.append(try JSONEncoder().encode(value))
        guard data.count <= maximumPacket else { throw Failure.invalid }
        return data
    }
    static func projectSync(_ payload: Data) throws -> Data {
        guard payload.count <= 524288 else { throw Failure.invalid }
        return Data([0x4a, 0x4c, version, 8]) + payload
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
    static func noticeReceipt(_ receipt: DAWRemoteNoticeReceipt) throws -> Data { try encode(receipt, kind: 7) }
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
        case 8:
            guard data.count <= 524292 else { throw Failure.invalid }; return .projectSync(Data(payload))
        case 7:
            guard data.count <= 256 else { throw Failure.invalid }
            return .noticeReceipt(try decoder.decode(DAWRemoteNoticeReceipt.self, from: payload))
        default: throw Failure.invalid
        }
    }
}
enum DAWRemoteAccess: String, Codable { case director, observer, notices }
struct DAWRemoteAccessRequest: Codable {
    var mode: DAWRemoteAccess
    var pin: String = ""
    var valid: Bool { pin.isEmpty || (pin.utf8.count == 4 && pin.utf8.allSatisfy { (48...57).contains($0) }) }
}
struct DAWRemoteAccessStatus: Codable {
    var mode: DAWRemoteAccess?
    var requiresPIN: Bool
    var noticesRequiresPIN: Bool? = nil
    var error: String? = nil
}
/// An observer may only subscribe to a local TP view or fetch its still images.
/// This whitelist is enforced by the Mac before any application command handler.
enum DAWRemoteAccessRules {
    static func allows(_ command: DAWRemoteCommand, mode: DAWRemoteAccess?) -> Bool {
        guard command.valid, let mode else { return false }
        if mode == .director { return true }
        if mode == .notices {
            switch command.action {
            case .noticeSend, .noticeClear, .noticePin, .noticeDestination, .noticeSaveTemplate: return true
            case .remotePanel: return command.value == 0 || command.value == 3
            default: return false
            }
        }
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
struct DAWRemoteNoticeReceipt: Codable, Equatable {
    var commandID: UUID
    var project: UUID
    var accepted: Bool
}
enum DAWRemoteNoticeDelivery: Equatable {
    case accepted, rejected, disconnected, unconfirmed
}
struct DAWRemoteCommand: Codable {
    enum Action: String, Codable {
        case play, pause, stop, subPlay, subStop, toggleLoop, seek, queueSection, cancelSection, toggleMultiLoopBypass, toggleSetlistLive
        case volume, pan, mute, solo, masterMono, resetMeterPeak, selectRegion, selectSong, tempo, pitch, save, toggleRegionAuto, clipGain, clipMute, selectPlaylist, openRecentProject, openRecentProjectInNewTab, selectProjectTab, closeProjectTab
        case remotePanel, noticeSend, noticeClear, noticePin, noticeDestination, noticeSaveTemplate
        case requestImage
        case timerStart, timerStop
        case togglePreview, selectPreviewPage
        case vinhetasDown, vinhetasUp, vinhetasPreset, vinhetasVolume, vinhetasGate, vinhetasPanic
        case editRegion, deleteRegion, duplicateRegion, renamePlaylist, duplicatePlaylist, deletePlaylist
    }
    var id = UUID()
    var project: UUID
    var song: UUID?
    var action: Action
    var target: UUID? = nil
    var value: Double = 0
    var text: String? = nil
    var enabled: Bool? = nil
    /// Opt in so hosts never send an unknown packet kind to older clients.
    var noticeReceiptRequested: Bool? = nil
    var playlist: UUID? = nil
    var pad: Int? = nil
    var preset: Int? = nil
    var valid: Bool {
        guard value.isFinite else { return false }
        if let text {
            guard [.noticeSend, .noticeSaveTemplate, .editRegion, .renamePlaylist].contains(action), text.count <= 500, text.utf8.count <= 4000 else { return false }
        }
        if playlist != nil && ![.deleteRegion, .duplicateRegion].contains(action) { return false }
        let padActions: Set<Action> = [.vinhetasDown, .vinhetasVolume, .vinhetasGate]
        if padActions.contains(action) {
            guard let pad, (0..<16).contains(pad), let preset, (0..<6).contains(preset) else { return false }
        } else if pad != nil || preset != nil { return false }
        if enabled != nil && action != .noticeDestination && action != .vinhetasGate { return false }
        if noticeReceiptRequested != nil && action != .noticeSend { return false }
        switch action {
        case .vinhetasDown: return target != nil && value == 0 && enabled == nil
        case .vinhetasUp: return target != nil && value == 0
        case .vinhetasPreset: return target == nil && (0..<6).contains(value) && value.rounded() == value
        case .vinhetasVolume: return target == nil && (0...2).contains(value)
        case .vinhetasGate: return target == nil && value == 0 && enabled != nil
        case .vinhetasPanic: return target == nil && value == 0
        case .editRegion: return target != nil && text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && (0...16777215).contains(value) && value.rounded() == value
        case .renamePlaylist: return target != nil && value == 0 && text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .duplicateRegion: return target != nil && playlist != nil && value == 0
        case .deleteRegion, .duplicatePlaylist, .deletePlaylist: return target != nil && value == 0
        case .toggleMultiLoopBypass, .toggleSetlistLive, .cancelSection: return target == nil && value == 0
        case .resetMeterPeak: return value == 0
        case .timerStart: return target == nil && (0...359999).contains(value) && value.rounded() == value
        case .timerStop: return target == nil && value == 0
        case .togglePreview: return target == nil && value == 0
        case .selectPreviewPage: return target == nil && (0...5).contains(value) && value.rounded() == value
        case .requestImage: return target != nil && value == 0
        case .remotePanel: return target == nil && (0...3).contains(value) && value.rounded() == value
        case .noticeSend: return target == nil && text != nil && (-1...2).contains(value) && value.rounded() == value
        case .noticeSaveTemplate: return target == nil && text != nil && (0...2).contains(value) && value.rounded() == value
        case .noticeClear: return target == nil && value == 0
        case .noticePin: return target == nil && (value == 0 || value == 1)
        case .noticeDestination: return target == nil && (value == 1 || value == 2) && enabled != nil
        case .openRecentProject, .openRecentProjectInNewTab, .selectProjectTab, .closeProjectTab: return target != nil && value == 0
        case .clipGain: return target != nil && (0...pow(10, 24.0 / 20)).contains(value)
        case .clipMute, .queueSection: return target != nil && value == 0
        case .volume: return (0...4).contains(value)
        case .pan: return (-1...1).contains(value)
        case .tempo: return (20...400).contains(value)
        case .pitch: return (-12...12).contains(value) && value.rounded() == value && target != nil
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
            bpm.isFinite && bpm > 0 && (1...32).contains(beats) &&
            [1, 2, 4, 8, 16, 32, 64].contains(unit)
        }
    }
    struct Clip: Codable, Identifiable, Equatable {
        var id: UUID; var name: String; var start: Double; var duration: Double
        var gain: Double? = nil
        var muted: Bool? = nil
        var lane: Int? = nil
        /// In-process only: never encoded into Remote packets or accepted from a peer.
        var waveform: [Double]? = nil
        var waveformLoopLength: Double? = nil
        var waveformOffset: Double? = nil
        var waveformRate: Double? = nil
        private enum CodingKeys: String, CodingKey { case id, name, start, duration, gain, muted, lane }
    }
    struct Marker: Codable, Identifiable, Equatable {
        var id: UUID; var name: String; var position: Double; var color: UInt32
        var section: Bool? = nil
        var unifiedRegionID: UUID? = nil
        var sourceRegionID: UUID? = nil
    }
    struct SectionPlayback: Codable, Equatable {
        var currentRegion: UUID?
        var secondaryRegion: UUID?
        var position: Double
        var secondaryPosition: Double?
        var queuedMarker: UUID?
        var queueStartedAt: Double?
        var nextTrigger: Double?
        var currentEnd: Double? = nil
        var valid: Bool {
            [position, secondaryPosition, queueStartedAt, nextTrigger, currentEnd].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 }
        }
    }
    struct SongDisplays: Codable, Equatable {
        var current: String?
        var currentBPM: Double?
        var next: String?
        var nextBPM: Double?
        var queued: String?
        var queuedBPM: Double?
        var playlistSeconds: Double
        var valid: Bool {
            playlistSeconds.isFinite && playlistSeconds >= 0 &&
                [currentBPM, nextBPM, queuedBPM].compactMap { $0 }.allSatisfy { $0.isFinite && $0 > 0 }
        }
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
        var heightScale: Double? = nil
        var peakDB: Double? = nil
        var canMeter: Bool? = nil
        var parentTrack: UUID? = nil
        /// Presentation metadata owned by the host project, never a Remote edit.
        var instrumentIcon: String? = nil
        /// Clip geometry belongs to the grid. Position packets or changes to
        /// clips must not rebuild the mixer's faders and native touch views.
        func hasSameMixerControls(as other: Self) -> Bool {
            id == other.id && name == other.name && color == other.color &&
            volume == other.volume && pan == other.pan && mute == other.mute && solo == other.solo &&
            nameColor == other.nameColor && emphasized == other.emphasized && silenced == other.silenced &&
            linkedTrack == other.linkedTrack && peakDB == other.peakDB && canMeter == other.canMeter && parentTrack == other.parentTrack && instrumentIcon == other.instrumentIcon
        }
    }
    struct Region: Codable, Identifiable, Equatable {
        var id: UUID; var name: String; var start: Double; var end: Double; var color: UInt32
        var nameColor: UInt32? = nil
        var parentRegion: UUID? = nil
        var sourceRegionId: UUID? = nil
    }
    struct Song: Codable, Identifiable, Equatable { var id: UUID; var name: String }
    struct SetlistBlock: Codable, Identifiable, Equatable {
        var id: UUID
        var name: String
        var color: UInt32
        var beforeRegion: UUID?
        var symbol: Bool = true
        var nameColor: UInt32? = nil
        var valid: Bool { name.utf8.count <= 4096 && color <= 0xffffff && (nameColor ?? 0) <= 0xffffff }
    }
    struct RecentProject: Codable, Identifiable, Equatable {
        var id: UUID; var name: String; var current: Bool
    }
    struct ProjectBrowser: Codable, Equatable {
        var recent: [RecentProject]
        var busy: Bool
        var canOpen: Bool
        var canOpenInNewTab: Bool? = nil
        var status: String
        var error: String
        var commandID: UUID? = nil
        var commandState: String? = nil
        var valid: Bool {
            (commandState.map { ["opening", "completed", "failed", "cancelled", "waiting"].contains($0) } ?? true) &&
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
    var currentPlaylistEntryId: UUID? = nil
    var queuedPlaylistEntryId: UUID? = nil
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
    var tempoNeedsRender: Bool? = nil
    var loopStart: Double? = nil
    var loopEnd: Double? = nil
    var multiLoopsBypassed: Bool? = nil
    var setlistLiveEnabled: Bool? = nil
    var playedLiveRegionIDs: [UUID]? = nil
    var masterPeakDB: Double? = nil
    var masterPan: Double? = nil
    var pitchRegion: UUID? = nil
    var pitchSemitones: Int? = nil
    var setlistFontStyle: Int? = nil
    var prepareOnly: Bool? = nil
    var masterColor: UInt32? = nil
    var masterNameColor: UInt32? = nil
    var regionAuto: Bool? = nil
    var regionAutoUntilBlockEnd: Bool? = nil
    var queueStartedAt: Double? = nil
    var playbackEnd: Double? = nil
    var projectSavedAt: String? = nil
    var footerInformation: String? = nil
    var footerLoopBeatPhase: Int? = nil
    var upcomingName: String? = nil
    var upcomingKind: String? = nil
    var playlists: [Song]? = nil
    var selectedPlaylist: UUID? = nil
    var gridRegion: UUID? = nil
    var markers: [Marker]? = nil
    struct ProjectTab: Codable, Identifiable, Equatable {
        var id: UUID
        var name: String
        var selected: Bool
    }
    var projects: ProjectBrowser? = nil
    var projectTabs: [ProjectTab]? = nil
    // Legacy wire field only. Current clients choose list/footer using their buttons.
    var sectionListVertical: Bool? = nil
    var teleprompters: [DAWRemoteTeleprompter]? = nil
    var notices: DAWRemoteNotices? = nil
    var timer: DAWRemoteTimerState? = nil
    var gridTempo: [GridTempo]? = nil
    var gridDivisions: Int? = nil
    var gridLines: Bool? = nil
    var gridPrimaryColor: UInt32? = nil
    var gridSecondaryColor: UInt32? = nil
    var gridBackgroundColor: UInt32? = nil
    var playCursorColor: UInt32? = nil
    var editCursorColor: UInt32? = nil
    var subPlayCursorColor: UInt32? = nil
    var editPosition: Double? = nil
    var subPlayPosition: Double? = nil
    var sectionPlayback: SectionPlayback? = nil
    var songDisplays: SongDisplays? = nil
    /// Separators belonging to the current playlist (or All regions), in their
    /// saved order. These are presentation headers, never playback regions.
    var setlistBlocks: [SetlistBlock]? = nil
    /// Global host controls, independent of which TP the Remote is viewing.
    /// Missing fields identify a host without Preview control support.
    var previewActive: Bool? = nil
    var previewPage: Int? = nil
    var vinhetas: DAWRemoteVinhetas? = nil
    /// Original unified songs keep their active child; only aliases replace the displayed row ID.
    var setlistCurrentEntryId: UUID? {
        if let id = currentPlaylistEntryId, regions.contains(where: { $0.id == id && $0.sourceRegionId != nil }) { return id }
        return currentRegion
    }
    var setlistQueuedEntryId: UUID? { queuedPlaylistEntryId ?? queuedRegion }
    static func validPeak(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= -24 } ?? true }
    var valid: Bool {
        position.isFinite && duration.isFinite && bpm.isFinite && masterVolume.isFinite && Self.validPeak(masterPeakDB) &&
        (masterPan == nil || (masterPan!.isFinite && (-1...1).contains(masterPan!))) &&
        (loopStart == nil || (loopStart!.isFinite && loopStart! >= 0)) &&
        (loopEnd == nil || (loopEnd!.isFinite && loopEnd! >= (loopStart ?? 0))) &&
        (editPosition == nil || (editPosition!.isFinite && editPosition! >= 0)) &&
        (subPlayPosition == nil || (subPlayPosition!.isFinite && subPlayPosition! >= 0)) &&
        [gridBackgroundColor, gridPrimaryColor, gridSecondaryColor, playCursorColor, editCursorColor, subPlayCursorColor].allSatisfy { $0 == nil || $0! <= 0xffffff } &&
        (gridTempo ?? []).count <= 32768 && (gridTempo ?? []).allSatisfy(\.valid) &&
        (footerLoopBeatPhase == nil || [0, 1, 3].contains(footerLoopBeatPhase!)) &&
        (gridDivisions == nil || [0, 2, 4, 8].contains(gridDivisions!)) &&
        (previewPage == nil || (0...5).contains(previewPage!)) && (vinhetas?.valid ?? true) &&
        (playedLiveRegionIDs ?? []).count <= 8192 &&
        Set(playedLiveRegionIDs ?? []).count == (playedLiveRegionIDs ?? []).count &&
        (setlistBlocks ?? []).count <= 8192 && (setlistBlocks ?? []).allSatisfy(\.valid) &&
        Set((setlistBlocks ?? []).map(\.id)).count == (setlistBlocks ?? []).count &&
        (projectTabs ?? []).count <= 1024 && (projectTabs ?? []).allSatisfy { $0.name.utf8.count <= 4096 } &&
        Set((projectTabs ?? []).map(\.id)).count == (projectTabs ?? []).count &&
        ((projectTabs ?? []).isEmpty || (projectTabs ?? []).filter(\.selected).count == 1) &&
        (songDisplays?.valid ?? true) && (sectionPlayback?.valid ?? true) && (projects?.valid ?? true) && (notices?.valid ?? true) && (timer?.valid ?? true) &&
        (teleprompters ?? []).count <= 2 && (teleprompters ?? []).allSatisfy(\.valid) &&
        (markers ?? []).count <= 16384 && (markers ?? []).allSatisfy { $0.position.isFinite && $0.position >= 0 } &&
        Set((markers ?? []).map(\.id)).count == (markers ?? []).count &&
        position >= 0 && duration >= 0 && tracks.count <= 4096 && regions.count <= 8192 &&
        timelineRegions.count <= 8192 && songs.count <= 4096 &&
        tracks.allSatisfy { Self.validPeak($0.peakDB) && $0.volume.isFinite && $0.pan.isFinite && ($0.heightScale == nil || ($0.heightScale!.isFinite && (0.1...10).contains($0.heightScale!))) && $0.clips.count <= 16384 && ($0.laneCount == nil || (1...10001).contains($0.laneCount!)) &&
            $0.clips.allSatisfy { $0.start.isFinite && $0.duration.isFinite && $0.duration >= 0 && ($0.lane == nil || (0...10000).contains($0.lane!)) && ($0.gain == nil || ($0.gain!.isFinite && $0.gain! >= 0)) } } &&
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
    enum Entry: Identifiable {
        enum ID: Hashable { case region(UUID), block(UUID) }
        case region(Row), block(DAWRemoteState.SetlistBlock)
        var id: ID {
            switch self { case .region(let row): return .region(row.id); case .block(let block): return .block(block.id) }
        }
    }
    struct Row: Identifiable {
        var region: DAWRemoteState.Region
        var number: Int?
        var child: Bool
        var hasDrawer: Bool = false
        var id: UUID { region.id }
    }
    static func canQueueDuplicate(_ entry: UUID, in state: DAWRemoteState) -> Bool {
        guard let source = state.regions.first(where: { $0.id == entry })?.sourceRegionId else { return true }
        func root(_ id: UUID?) -> UUID? {
            guard let id else { return nil }
            return state.timelineRegions.first(where: { $0.id == id })?.parentRegion ?? id
        }
        let current = root(state.currentRegion)
        let secondary = state.subPlaying ? root(state.sectionPlayback?.secondaryRegion ?? state.queuedRegion) : nil
        return !(state.playing && source == current) && source != secondary
    }
    static func children(of parent: UUID, in state: DAWRemoteState) -> [DAWRemoteState.Region] {
        state.timelineRegions.filter { $0.parentRegion == parent }.sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
    }
    static func canToggleDrawer(_ id: UUID, in state: DAWRemoteState) -> Bool {
        state.regions.contains { $0.id == id && $0.parentRegion == nil } &&
            state.timelineRegions.contains { $0.parentRegion == id }
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
        let parents = Set(state.timelineRegions.compactMap(\.parentRegion))
        for (index, region) in state.regions.enumerated() {
            rows.append(Row(region: region, number: index + 1, child: false, hasDrawer: region.parentRegion == nil && parents.contains(region.id)))
            if expanded.contains(region.id) {
                rows += children(of: region.id, in: state).map { Row(region: $0, number: nil, child: true) }
            }
        }
        return rows.filter { query.isEmpty || $0.region.name.localizedStandardContains(query) }
    }
    static func entries(rows: [Row], blocks: [DAWRemoteState.SetlistBlock], query: String) -> [Entry] {
        let headers = Dictionary(grouping: blocks, by: \.beforeRegion)
        var result: [Entry] = []
        var section: [Entry] = []
        func appendSection() {
            guard !section.isEmpty else { return }
            if query.isEmpty { result += section; section.removeAll(keepingCapacity: true); return }
            let matchingHeader = section.contains { entry in
                if case .block(let block) = entry { return block.name.localizedStandardContains(query) }; return false
            }
            let matchingRows = section.filter { entry in
                if case .region(let row) = entry { return matchingHeader || row.region.name.localizedStandardContains(query) }; return false
            }
            if matchingHeader || !matchingRows.isEmpty {
                result += section.filter { if case .block = $0 { return true }; return false }
                result += matchingRows
            }
            section.removeAll(keepingCapacity: true)
        }
        for row in rows {
            if !row.child, let before = headers[row.id], !before.isEmpty {
                appendSection(); section += before.map(Entry.block)
            }
            section.append(.region(row))
        }
        appendSection()
        result += (headers[nil] ?? []).filter { query.isEmpty || $0.name.localizedStandardContains(query) }.map(Entry.block)
        return result
    }
}

/// Playback packets reuse list structure. Only edits, searching or a manual
/// drawer change rebuild the visible rows; transport progress stays separate.
final class DAWRemoteSetlistRowsCache {
    private var regions: [DAWRemoteState.Region] = []
    private var timeline: [DAWRemoteState.Region] = []
    private var expanded: Set<UUID> = []
    private var query = ""
    private var cached: [DAWRemoteSetlistPresentation.Row] = []
    private var blocks: [DAWRemoteState.SetlistBlock] = []
    private var cachedEntries: [DAWRemoteSetlistPresentation.Entry] = []
    private var initialized = false
    private(set) var rebuildCount = 0
    func rows(in state: DAWRemoteState, expanded: Set<UUID>, query: String) -> [DAWRemoteSetlistPresentation.Row] {
        update(in: state, expanded: expanded, query: query)
        return cached
    }
    func entries(in state: DAWRemoteState, expanded: Set<UUID>, query: String) -> [DAWRemoteSetlistPresentation.Entry] {
        update(in: state, expanded: expanded, query: query)
        return cachedEntries
    }
    private func update(in state: DAWRemoteState, expanded: Set<UUID>, query: String) {
        if initialized && regions == state.regions && timeline == state.timelineRegions && blocks == (state.setlistBlocks ?? []) && self.expanded == expanded && self.query == query { return }
        initialized = true; regions = state.regions; timeline = state.timelineRegions
        self.expanded = expanded; self.query = query; blocks = state.setlistBlocks ?? []
        let allRows = DAWRemoteSetlistPresentation.rows(in: state, expanded: expanded, query: "")
        cached = allRows.filter { query.isEmpty || $0.region.name.localizedStandardContains(query) }
        cachedEntries = DAWRemoteSetlistPresentation.entries(rows: allRows, blocks: blocks, query: query)
        rebuildCount += 1
    }
}

/// The SubPlay head owns the Remote viewport until the Mac promotes or cancels it.
/// A queued/focused song cannot steal the viewport from either playing head.
enum DAWRemoteTimelinePresentation {
    static func region(in state: DAWRemoteState) -> DAWRemoteState.Region? {
        let regions = state.timelineRegions + state.regions
        func root(_ region: DAWRemoteState.Region) -> DAWRemoteState.Region {
            region.parentRegion.flatMap { parent in regions.first { $0.id == parent } } ?? region
        }
        if state.subPlaying {
            guard let position = state.subPlayPosition ?? state.sectionPlayback?.secondaryPosition else { return nil }
            let contains: (DAWRemoteState.Region) -> Bool = { position >= $0.start && position < $0.end }
            if let section = regions.first(where: { $0.id == state.sectionPlayback?.secondaryRegion && contains($0) }) {
                return root(section)
            }
            return regions.filter(contains).min { ($0.end - $0.start) < ($1.end - $1.start) }.map(root)
        }
        let selected = state.playing ? state.currentRegion : state.focusedRegion ?? state.currentRegion
        return regions.first { $0.id == state.gridRegion } ?? regions.first { $0.id == selected }.map(root)
    }
}

/// Reject vertical scrolling before the native edge gesture begins, so the
/// underlying scroll view keeps its touch stream.
enum DAWRemoteSidebarGesture {
    static func shouldBegin(horizontal: Double, vertical: Double) -> Bool {
        horizontal.isFinite && vertical.isFinite && horizontal > 0 && horizontal > abs(vertical) * 1.5
    }
    static func shouldReveal(horizontal: Double, vertical: Double) -> Bool {
        horizontal >= 36 && shouldBegin(horizontal: horizontal, vertical: vertical)
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
enum DAWRemotePhonePanel: CaseIterable {
    case grid, mixer, setlist, teleprompter1, teleprompter2, notices, sections, vinhetas
    func selecting(_ panel: Self) -> Self { panel == self ? .grid : panel }
    func togglingFooterParts() -> Self { self == .sections ? .setlist : .sections }
    var subscription: Int {
        switch self { case .teleprompter1: return 1; case .teleprompter2: return 2; case .notices: return 3; default: return 0 }
    }
}

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
    static func heightScale(_ value: Double) -> Double { value.isFinite ? min(3, max(0.35, value)) : 1 }
    static func laneHeight(_ track: DAWRemoteState.Track, scale: Double = 1) -> Double {
        max(28, ((track.laneCount ?? 1) > 1 ? 86 * 0.7 : 86) * heightScale(scale) * (track.heightScale ?? 1))
    }
    static func rowHeight(_ track: DAWRemoteState.Track, scale: Double = 1) -> Double {
        laneHeight(track, scale: scale) * Double(max(1, track.laneCount ?? 1))
    }
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

/// Keep the lane partitioning independent of volume, peaks and transport.
/// Incoming scalar controls are copied through even when clip layout is reused.
final class DAWRemoteItemLayoutCache {
    private struct Entry {
        var source: [DAWRemoteState.Clip]
        var clips: [DAWRemoteState.Clip]
        var lanes: Int
    }
    private var regionStart: Double?, regionEnd: Double?
    private var entries: [UUID: Entry] = [:]
    private var lastInput: [DAWRemoteState.Track] = []
    private var lastOutput: [DAWRemoteState.Track] = []
    private(set) var rebuildCount = 0
    func tracks(_ tracks: [DAWRemoteState.Track], within region: DAWRemoteState.Region?) -> [DAWRemoteState.Track] {
        let regionChanged = regionStart != region?.start || regionEnd != region?.end
        if !regionChanged && tracks == lastInput { return lastOutput }
        if regionChanged { entries.removeAll(keepingCapacity: true) }
        regionStart = region?.start; regionEnd = region?.end
        let ids = Set(tracks.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        let output = tracks.map { original in
            var track = original
            if let entry = entries[track.id], entry.source == track.clips {
                track.clips = entry.clips; track.laneCount = entry.lanes
            } else {
                track = DAWRemoteItemLayout.tracks([original], within: region)[0]
                entries[track.id] = Entry(source: original.clips, clips: track.clips, lanes: track.laneCount ?? 1)
                rebuildCount += 1
            }
            return track
        }
        lastInput = tracks; lastOutput = output
        return output
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
        // Optional fields let updated clients keep accepting older hosts.
        var liveExecuted: Bool? = nil
        var playing: Bool? = nil
        var queued: Bool? = nil
        var playbackProgress: Double? = nil
        var progressFraction: Double { min(1, max(0, playbackProgress ?? 0)) }
        var hasPlaybackHighlight: Bool { playing == true || queued == true }
        var previewTextColor: UInt32 { liveExecuted == true ? 0xff4040 : hasPlaybackHighlight ? 0xffffff : color }
    }
    struct Block: Codable, Equatable, Identifiable {
        var id: UUID; var name: String; var color: UInt32; var rows: [Row]
        var nameColor: UInt32? = nil
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
            block.rows.count <= 8192 && block.rows.allSatisfy { $0.duration.isFinite && $0.duration >= 0 &&
                ($0.playbackProgress.map { $0.isFinite && (0...1).contains($0) } ?? true) }
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

/// Parts consumes the remaining grid, never the saved Setlist or mixer widths.
struct DAWRemotePartsWidths {
    let content: Double
    let handle: Double
    var total: Double { content + handle }
    init(available: Double, requested: Double, visible: Bool, handle: Double) {
        let available = available.isFinite ? max(0, available) : 0
        self.handle = visible ? min(available, max(0, handle)) : 0
        self.content = visible ? min(max(0, available - self.handle), max(0, requested.isFinite ? requested : 240)) : 0
    }
}

/// The same parent chain is sent to native and LAN workspaces. Hidden rows
/// still participate in ancestry; only the final displayed rows need guides.
struct DAWRemoteTrackHierarchy {
    private let parents: [UUID: UUID]
    let folders: Set<UUID>
    init(_ tracks: [DAWRemoteState.Track]) {
        parents = Dictionary(tracks.compactMap { track in track.parentTrack.map { (track.id, $0) } },
                             uniquingKeysWith: { first, _ in first })
        folders = Set(parents.values)
    }
    func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = [], visited: Set<UUID> = [id], next = parents[id]
        while let parent = next, visited.insert(parent).inserted {
            result.append(parent); next = parents[parent]
        }
        return Array(result.reversed())
    }
}

/// Observer cues use the host's audible position, never a local wall clock.
/// The same snapshot is published by desktop hosts and the iPad native host.
struct DAWRemoteSectionCue: Equatable {
    var marker: UUID
    var name: String
    var seconds: Int
    var armed: Bool

    static func current(in state: DAWRemoteState, leadTime: Double = 5) -> Self? {
        guard state.playing, !state.paused, leadTime.isFinite, leadTime > 0 else { return nil }
        let playback = state.sectionPlayback
        let position = playback?.position ?? state.position
        guard position.isFinite else { return nil }
        let markers = (state.markers ?? []).filter { $0.section == true }
        let target: DAWRemoteState.Marker
        let boundary: Double
        let armed: Bool
        if let id = playback?.queuedMarker {
            guard let marker = markers.first(where: { $0.id == id }),
                  let trigger = playback?.nextTrigger else { return nil }
            target = marker; boundary = trigger; armed = true
        } else {
            let region = state.timelineRegions.first { $0.id == playback?.currentRegion }
                ?? state.timelineRegions.filter { position >= $0.start && position < $0.end }
                    .sorted { ($0.parentRegion != nil ? 0 : 1, $0.end - $0.start) < ($1.parentRegion != nil ? 0 : 1, $1.end - $1.start) }.first
            guard let region else { return nil }
            let end = playback?.currentEnd ?? region.end
            guard let marker = markers.filter({ $0.position > position && $0.position >= region.start && $0.position < end })
                .min(by: { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }) else { return nil }
            // A loop returns before this marker, so it is not the next audible section.
            if state.loop, let loopEnd = state.loopEnd, marker.position >= loopEnd { return nil }
            target = marker; boundary = marker.position; armed = false
        }
        let remaining = boundary - position
        guard remaining.isFinite, remaining > 0, remaining <= leadTime else { return nil }
        return .init(marker: target.id, name: target.name, seconds: Int(ceil(remaining)), armed: armed)
    }
}

/// Presentation only: audio paths and MIDI mappings stay on the host.
struct DAWRemoteVinhetas: Codable, Equatable {
    struct Pad: Codable, Equatable {
        var name: String
        var color: UInt32
        var volume: Double
        var gate: Bool
        var loaded: Bool
        var active: Bool
        var valid: Bool { name.utf8.count <= 4096 && color <= 0xffffff && volume.isFinite && (0...2).contains(volume) }
    }
    struct Preset: Codable, Equatable {
        var name: String
        var color: UInt32
        var pads: [Pad]
        var valid: Bool { name.utf8.count <= 4096 && color <= 0xffffff && pads.count == 16 && pads.allSatisfy(\.valid) }
    }
    var selectedPreset: Int
    var available: Bool
    var presets: [Preset]
    var receivedPresses: [UUID]? = nil
    var valid: Bool { (0..<6).contains(selectedPreset) && presets.count == 6 && presets.allSatisfy(\.valid) &&
        (receivedPresses ?? []).count <= 256 && Set(receivedPresses ?? []).count == (receivedPresses ?? []).count }
}
/// Pads light immediately on the client. Host snapshots may end an acknowledged
/// local trigger, but an older false snapshot can never undo a fresh press.
struct DAWRemoteVinhetasFeedback {
    private struct Key: Hashable { let preset: Int; let pad: Int }
    private struct Press { let id: UUID; let gate: Bool; var held: Bool; var sounding: Bool; var confirmed = false }
    private var presses: [Key: Press] = [:]
    private struct Gate { var baseline: Bool; var awaiting: [Bool]; var expires: TimeInterval }
    private var gates: [Key: Gate] = [:]
    private(set) var gateRevision = UUID()
    func gate(preset: Int, pad: Int, confirmed: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let gate = gates[Key(preset: preset, pad: pad)], gate.expires > now else { return confirmed }
        return gate.awaiting.last ?? confirmed
    }
    @discardableResult mutating func toggleGate(preset: Int, pad: Int, confirmed: Bool,
                                               now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let key = Key(preset: preset, pad: pad)
        let desired = !gate(preset: preset, pad: pad, confirmed: confirmed, now: now)
        var prediction = gates[key].flatMap { $0.expires > now ? $0 : nil } ?? Gate(baseline: confirmed, awaiting: [], expires: now)
        prediction.awaiting.append(desired); prediction.expires = now + 2
        gates[key] = prediction; gateRevision = UUID()
        if desired { stop(preset: preset, pad: pad) }
        return desired
    }
    mutating func expireGates(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        gates = gates.filter { $0.value.expires > now }
    }
    mutating func stopAll() { presses.removeAll() }
    mutating func down(id: UUID, preset: Int, pad: Int, gate: Bool) {
        presses[Key(preset: preset, pad: pad)] = Press(id: id, gate: gate, held: gate, sounding: !gate)
    }
    mutating func up(preset: Int, pad: Int) {
        let key = Key(preset: preset, pad: pad)
        if presses[key]?.gate == true { presses[key]?.held = false; presses[key]?.sounding = false }
    }
    mutating func stop(preset: Int, pad: Int) { presses[Key(preset: preset, pad: pad)] = nil }
    mutating func reset() { presses.removeAll(); gates.removeAll() }
    func lit(preset: Int, pad: Int) -> Bool {
        let press = presses[Key(preset: preset, pad: pad)]
        return press?.held == true || press?.sounding == true
    }
    mutating func receive(_ state: DAWRemoteVinhetas, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        expireGates(now: now)
        for (key, stored) in gates {
            var prediction = stored
            let confirmed = state.presets[key.preset].pads[key.pad].gate
            // Consume observed transitions in order. A stale initial value
            // cannot acknowledge the last of two rapid, opposite taps.
            if confirmed != prediction.baseline {
                prediction.baseline = confirmed
                if let index = prediction.awaiting.firstIndex(of: confirmed) { prediction.awaiting.removeFirst(index + 1) }
            }
            gates[key] = prediction.awaiting.isEmpty ? nil : prediction
        }
        let acknowledged = Set(state.receivedPresses ?? [])
        for (key, stored) in presses {
            var press = stored
            press.confirmed = press.confirmed || acknowledged.contains(press.id)
            presses[key] = press.confirmed && !press.held && !state.presets[key.preset].pads[key.pad].active ? nil : press
        }
    }
}

/// The audible transport owns the title, independently of list browsing or a
/// cached display string from the previous song.
extension DAWRemoteState {
    var showsSetlistSelection: Bool { !playing && !subPlaying }
    var currentSongName: String {
        if playing {
            let regions = timelineRegions.isEmpty ? self.regions : timelineRegions
            if let id = sectionPlayback?.currentRegion,
               let part = regions.first(where: { $0.id == id }), position >= part.start,
               position < (sectionPlayback?.currentEnd ?? part.end) { return part.name }
            if let part = regions.filter({ position >= $0.start && position < $0.end })
                .min(by: { $0.end - $0.start < $1.end - $1.start }) { return part.name }
            if let part = regions.first(where: { $0.id == currentRegion }) { return part.name }
        }
        return songDisplays?.current ?? (timelineRegions + regions).first(where: { $0.id == (focusedRegion ?? currentRegion) })?.name ?? songName
    }
}
