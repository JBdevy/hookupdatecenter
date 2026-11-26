import Foundation

/// The Remote exchanges native presentation state, typed actions and requested
/// still images and optional stereo audio from the desktop Main.
enum DAWRemoteWire {
    static let service = "jaras-live"
    static let version: UInt8 = 2
    static let maximumPacket = 2 * 1024 * 1024
    enum Packet {
        case projectSync(Data), command(DAWRemoteCommand), state(DAWRemoteState), acknowledge(UInt64)
        case noticeReceipt(DAWRemoteNoticeReceipt), imageAsset(DAWRemoteImageAsset)
        case accessRequest(DAWRemoteAccessRequest), accessStatus(DAWRemoteAccessStatus)
        case mainAudioSubscription(Bool), mainAudio(Data)
    }
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
    static func mainAudioSubscription(_ enabled: Bool) -> Data {
        Data([0x4a, 0x4c, version, 9]) + Data((enabled ? "true" : "false").utf8)
    }
    static func mainAudio(_ payload: Data) -> Data {
        Data([0x4a, 0x4c, version, 10]) + payload
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
        case 9:
            guard data.count <= 9 else { throw Failure.invalid }
            return .mainAudioSubscription(try decoder.decode(Bool.self, from: payload))
        case 10:
            guard (8...8200).contains(payload.count), payload.count.isMultiple(of: 4) else { throw Failure.invalid }
            return .mainAudio(Data(payload))
        default: throw Failure.invalid
        }
    }
}
enum DAWRemoteAccess: String, Codable { case director, observer, notices }

struct DAWRemoteBatteryWarning {
    private var previous: Int?
    private var lastAlert: TimeInterval?

    mutating func reset() {
        previous = nil
        lastAlert = nil
    }

    mutating func update(_ percent: Int, now: TimeInterval) -> Int? {
        guard (0...100).contains(percent) else { return nil }
        let threshold = Self.threshold(percent)
        let crossed = threshold != nil && (previous.map { percent < $0 && Self.threshold($0) != threshold } ?? true)
        guard !crossed || lastAlert.map({ now - $0 >= 60 }) != false else { return nil }
        previous = percent
        if crossed {
            lastAlert = now
            return percent
        }
        return nil
    }

    private static func threshold(_ percent: Int) -> Int? {
        if percent <= 10 { return percent }
        if percent <= 15 { return 15 }
        if percent <= 20 { return 20 }
        return nil
    }
}
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
            case .noticeSend, .noticeClear, .noticePin, .noticePinStopped, .noticeDestination, .noticeSaveTemplate: return true
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
        case volume, pan, mute, solo, masterMono, resetMeterPeak, selectRegion, selectSong, tempo, tapTempo, pitch, save, toggleRegionAuto, clipGain, clipMute, selectPlaylist, openRecentProject, openRecentProjectInNewTab, selectProjectTab, closeProjectTab
        case remotePanel, noticeSend, noticeClear, noticePin, noticePinStopped, noticeDestination, noticeSaveTemplate
        case requestImage
        case timerStart, timerStartProgressive, timerSetMode, timerStop, transportFadeout
        case togglePreview, selectPreviewPage, toggleRecord, browseRegion
        case vinhetasDown, vinhetasUp, vinhetasPreset, vinhetasVolume, vinhetasGate, vinhetasPanic
        case editRegion, deleteRegion, duplicateRegion, renamePlaylist, duplicatePlaylist, deletePlaylist
        case setOutputRoutes
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
    var outputRoutes: [OutputPatch]? = nil
    var valid: Bool {
        guard value.isFinite else { return false }
        if let text {
            guard [.noticeSend, .noticeSaveTemplate, .noticePinStopped, .editRegion, .renamePlaylist].contains(action), text.count <= 500, text.utf8.count <= 4000 else { return false }
        }
        if playlist != nil && ![.deleteRegion, .duplicateRegion].contains(action) { return false }
        let padActions: Set<Action> = [.vinhetasDown, .vinhetasVolume, .vinhetasGate]
        if padActions.contains(action) {
            guard let pad, (0..<16).contains(pad), let preset, (0..<6).contains(preset) else { return false }
        } else if pad != nil || preset != nil { return false }
        if enabled != nil && action != .noticeDestination && action != .noticePinStopped && action != .vinhetasGate && action != .transportFadeout { return false }
        if noticeReceiptRequested != nil && action != .noticeSend { return false }
        if outputRoutes != nil && action != .setOutputRoutes { return false }
        switch action {
        case .setOutputRoutes:
            guard let outputRoutes, outputRoutes.count <= 64, value == 0 else { return false }
            return outputRoutes.allSatisfy {
                (try? $0.validate(allowMaster: target != nil, allowGroup: target != nil, allowNone: true)) != nil
            }
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
        case .transportFadeout: return target == nil && value == 0 && enabled != nil
        case .timerSetMode: return target == nil && (value == 0 || value == 1)
        case .timerStartProgressive: return target == nil && value == 0
        case .timerStop: return target == nil && value == 0
        case .togglePreview, .toggleRecord: return target == nil && value == 0
        case .selectPreviewPage: return target == nil && (0...5).contains(value) && value.rounded() == value
        case .requestImage: return target != nil && value == 0
        case .remotePanel: return target == nil && (0...3).contains(value) && value.rounded() == value
        case .noticeSend: return target == nil && text != nil && (-1...2).contains(value) && value.rounded() == value
        case .noticeSaveTemplate: return target == nil && text != nil && (0...2).contains(value) && value.rounded() == value
        case .noticeClear: return target == nil && value == 0
        case .noticePin: return target == nil && (value == 0 || value == 1)
        case .noticePinStopped:
            return target == nil && enabled != nil && (enabled == false || text != nil) &&
                (-1...2).contains(value) && value.rounded() == value
        case .noticeDestination: return target == nil && (value == 1 || value == 2) && enabled != nil
        case .openRecentProject, .openRecentProjectInNewTab, .selectProjectTab, .closeProjectTab: return target != nil && value == 0
        case .clipGain: return target != nil && (0...pow(10, 24.0 / 20)).contains(value)
        case .clipMute, .queueSection, .browseRegion: return target != nil && value == 0
        case .volume: return (0...4).contains(value)
        case .pan: return (-1...1).contains(value)
        case .tapTempo: return target == nil ? value == 0 : value >= 0
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
        var loopSection: Bool? = nil
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
        var compactComponents: Bool? = nil
        var minimumHeight: Double? = nil
        var peakDB: Double? = nil
        var canMeter: Bool? = nil
        var parentTrack: UUID? = nil
        /// Presentation metadata owned by the host project, never a Remote edit.
        var instrumentIcon: String? = nil
        var role: String? = nil
        var outputRoutes: [OutputPatch]? = nil
        /// Clip geometry belongs to the grid. Position packets or changes to
        /// clips must not rebuild the mixer's faders and native touch views.
        func hasSameMixerControls(as other: Self) -> Bool {
            id == other.id && name == other.name && color == other.color &&
            volume == other.volume && pan == other.pan && mute == other.mute && solo == other.solo &&
            nameColor == other.nameColor && emphasized == other.emphasized && silenced == other.silenced &&
            linkedTrack == other.linkedTrack && peakDB == other.peakDB && canMeter == other.canMeter && parentTrack == other.parentTrack && instrumentIcon == other.instrumentIcon && role == other.role
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
    var transportPreparing: Bool? = nil
    var transportControlRunning: Bool { playing || paused || transportPreparing == true }
    var tempoNeedsRender: Bool? = nil
    var loopStart: Double? = nil
    var loopEnd: Double? = nil
    var multiLoopsBypassed: Bool? = nil
    var setlistLiveEnabled: Bool? = nil
    var playedLiveRegionIDs: [UUID]? = nil
    var masterPeakDB: Double? = nil
    var masterPan: Double? = nil
    var patchOutputChannels: Int? = nil
    var masterOutputRoutes: [OutputPatch]? = nil
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
    var desktopBatteryPercent: Int? = nil
    var mainAudioAvailable: Bool? = nil
    var fadeout: DAWRemoteFadeoutState? = nil
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
    var previewSlots: TeleprompterPreviewSlots? = nil
    var vinhetas: DAWRemoteVinhetas? = nil
    var recording: Bool? = nil
    var smkLoopName: String? = nil
    var smkLoopColor: UInt32? = nil
    var trackMixerStripeOnly: Bool? = nil
    var gridInvertsWaveforms: Bool? = nil
    /// Original unified songs keep their active child; only aliases replace the displayed row ID.
    var setlistCurrentEntryId: UUID? {
        if let id = currentPlaylistEntryId, regions.contains(where: { $0.id == id && $0.sourceRegionId != nil }) { return id }
        return currentRegion
    }
    var setlistQueuedEntryId: UUID? { queuedPlaylistEntryId ?? queuedRegion }
    static func validPeak(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= -24 } ?? true }
    var valid: Bool {
        (smkLoopName?.utf8.count ?? 0) <= 4096 && (smkLoopColor ?? 0) <= 0xffffff &&
        (fadeout?.valid ?? true) && position.isFinite && duration.isFinite && bpm.isFinite && masterVolume.isFinite && Self.validPeak(masterPeakDB) &&
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
        (desktopBatteryPercent.map { (0...100).contains($0) } ?? true) &&
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
        tracks.allSatisfy { ($0.minimumHeight == nil || ($0.minimumHeight!.isFinite && (0...10000).contains($0.minimumHeight!))) && Self.validPeak($0.peakDB) && $0.volume.isFinite && $0.pan.isFinite && ($0.heightScale == nil || ($0.heightScale!.isFinite && (0.1...10).contains($0.heightScale!))) && $0.clips.count <= 16384 && ($0.laneCount == nil || (1...10001).contains($0.laneCount!)) &&
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

/// Predict only the stopped selection at a block boundary. Playback commands
/// remain exclusively owned by the host; this never starts or stops audio.
struct DAWRemoteBlockPreparation: Equatable {
    var project: UUID
    var song: UUID?
    var playlist: UUID?
    var current: UUID
    var occurrence: UUID?
    var destination: DAWRemoteState.Region
    var end: Double

    init?(_ state: DAWRemoteState, stopping: Bool = false) {
        guard state.playing || (stopping && state.paused), !state.subPlaying,
              stopping || (!state.paused && !state.loop),
              state.regionAutoUntilBlockEnd == true, state.queuedRegion == nil,
              stopping || state.sectionPlayback?.queuedMarker == nil,
              let current = state.currentRegion else { return nil }
        let physical = state.timelineRegions.first { $0.id == current }
        let root = physical?.parentRegion ?? current
        var entries = state.regions.filter { $0.parentRegion == nil }
        if state.selectedPlaylist == nil { entries.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start } }
        guard let index = entries.firstIndex(where: { $0.id == (state.currentPlaylistEntryId ?? root) }),
              entries.indices.contains(index + 1) else { return nil }
        let target = entries[index + 1]
        guard state.setlistBlocks?.contains(where: { $0.beforeRegion == target.id }) == true,
              let owner = state.timelineRegions.first(where: { $0.id == root }) ?? entries.first(where: { $0.id == root }),
              owner.end.isFinite, stopping || owner.end > state.position else { return nil }
        // Ignore-next and section jumps can change the real completion boundary.
        guard stopping || state.playbackEnd == nil || abs(state.playbackEnd! - owner.end) < 1e-6 else { return nil }
        project = state.project; song = state.song; playlist = state.selectedPlaylist
        self.current = current; occurrence = state.currentPlaylistEntryId
        destination = target; end = owner.end
    }
    func applying(to state: DAWRemoteState) -> DAWRemoteState {
        var next = state
        next.playing = false; next.paused = false
        next.position = destination.start; next.editPosition = destination.start
        next.currentRegion = destination.sourceRegionId ?? destination.id
        next.currentPlaylistEntryId = playlist == nil ? nil : destination.id
        next.focusedRegion = destination.id; next.gridRegion = next.currentRegion
        next.queuedRegion = nil; next.queuedPlaylistEntryId = nil; next.queueStartedAt = nil
        next.playbackEnd = destination.end; next.sectionPlayback = nil
        // Derived titles from the outgoing packet must not cover the local selection.
        next.songDisplays = nil
        return next
    }
}

/// Play/Stop feedback belongs to the transport button. Grid position, meters
/// and audio still use the host snapshot.
struct DAWRemoteTransportFeedback {
    static let timeout: TimeInterval = 3
    let running: Bool
    private let project: UUID
    private let song: UUID?
    private var waitForEarlierTransition: Bool

    init(running: Bool, state: DAWRemoteState, previous: Self?) {
        self.running = running
        project = state.project
        song = state.song
        // A snapshot already matches the final state after a quick reversal.
        // Hold the last tap through a delayed snapshot for the first command.
        waitForEarlierTransition = previous?.matches(state) == true && previous?.running != running
            && state.transportControlRunning == running
    }

    mutating func isPending(after state: DAWRemoteState) -> Bool {
        guard matches(state) else { return false }
        if state.transportControlRunning != running { waitForEarlierTransition = false; return true }
        return waitForEarlierTransition
    }

    private func matches(_ state: DAWRemoteState) -> Bool { project == state.project && song == state.song }
}

/// Optimistic control values are reconciled against the raw host snapshot. A
/// late packet may update meters and cursor position without undoing a local edit.
struct DAWRemoteControlFeedback {
    private typealias State = DAWRemoteState
    private struct Key: Hashable { var field: AnyKeyPath; var target: UUID?; var index: Int? = nil }
    private struct Edit {
        var key: Key
        var matches: (State) -> Bool
        var apply: (inout State) -> Void
        var expiration: TimeInterval
        var waitForChange: Bool
    }
    private var project: UUID?
    private var song: UUID?
    private var edits: [Edit] = []
    var nextExpiration: TimeInterval? { edits.map(\.expiration).min() }

    mutating func receive(_ host: DAWRemoteState, now: TimeInterval) {
        scope(host)
        edits = edits.filter { stored in
            guard stored.expiration > now else { return false }
            return !stored.matches(host) || stored.waitForChange
        }.map { stored in
            var edit = stored
            if !edit.matches(host) { edit.waitForChange = false }
            return edit
        }
    }
    mutating func expire(now: TimeInterval) { edits.removeAll { $0.expiration <= now } }
    mutating func reset() { self = Self() }

    func overlay(_ host: DAWRemoteState) -> DAWRemoteState {
        guard !edits.isEmpty, host.project == project, host.song == song else { return host }
        var result = host
        for edit in edits { edit.apply(&result) }
        if edits.contains(where: { $0.key.field == \DAWRemoteState.Track.mute || $0.key.field == \DAWRemoteState.Track.solo }) {
            let original = Self.silentTracks(host.tracks)
            let current = Self.silentTracks(result.tracks)
            for index in result.tracks.indices {
                let id = result.tracks[index].id
                let hiddenSolo = host.tracks[index].silenced == true && !original.contains(id)
                result.tracks[index].silenced = current.contains(id) || hiddenSolo
            }
        }
        return result
    }

    @discardableResult mutating func record(_ command: DAWRemoteCommand, display: DAWRemoteState,
                                            host: DAWRemoteState, now: TimeInterval) -> Bool {
        guard command.project == host.project, command.song == nil || command.song == host.song else { return false }
        scope(host)
        let target = command.target
        let oldCount = edits.count
        switch command.action {
        case .pause:
            guard display.playing else { return false }
            put(\.paused, true, host: host, now: now) { $0.playing = false; $0.subPlaying = false }
        case .play, .stop:
            // Play/Stop visual feedback has its own host preparation handling.
            edits.removeAll { $0.key.field == \State.paused }
            return edits.count != oldCount
        case .toggleLoop: put(\.loop, !display.loop, host: host, now: now)
        case .toggleMultiLoopBypass: put(\.multiLoopsBypassed, display.multiLoopsBypassed != true, host: host, now: now)
        case .toggleSetlistLive:
            let enabled = display.setlistLiveEnabled != true
            put(\.setlistLiveEnabled, enabled, host: host, now: now) { if !enabled { $0.playedLiveRegionIDs = [] } }
        case .toggleRegionAuto: put(\.regionAuto, display.regionAuto != true, host: host, now: now)
        case .toggleRecord: put(\.recording, display.recording != true, host: host, now: now)
        case .togglePreview:
            guard let active = display.previewActive else { return false }
            put(\.previewActive, !active, host: host, now: now) { state in
                for index in state.teleprompters?.indices ?? 0..<0 { state.teleprompters?[index].preview = !active }
            }
        case .selectPreviewPage: put(\.previewPage, Int(command.value), host: host, now: now)
        case .subPlay, .subStop: put(\.subPlaying, command.action == .subPlay, host: host, now: now)
        case .tempo: put(\.bpm, command.value, host: host, now: now)
        case .pitch:
            guard let target, display.pitchRegion == target else { return false }
            let semitones = Int(command.value)
            add(Key(field: \State.pitchSemitones, target: target), host: host, now: now,
                matches: { $0.pitchRegion != target || $0.pitchSemitones == semitones },
                apply: { if $0.pitchRegion == target { $0.pitchSemitones = semitones } })
        case .masterMono: put(\.masterMono, !display.masterMono, host: host, now: now)
        case .mute, .solo, .volume, .pan, .resetMeterPeak, .setOutputRoutes:
            let gain = min(pow(10, 12.0 / 20), command.value)
            if let target {
                guard let track = display.tracks.first(where: { $0.id == target }) else { return false }
                switch command.action {
                case .mute: putTrack(\.mute, !track.mute, id: target, host: host, now: now)
                case .solo: putTrack(\.solo, !track.solo, id: target, host: host, now: now)
                case .volume: putTrack(\.volume, gain, id: target, host: host, now: now)
                case .pan:
                    putTrack(\.pan, command.value, id: target, host: host, now: now)
                    if let partner = track.linkedTrack, display.tracks.contains(where: { $0.id == partner && $0.linkedTrack == target }) {
                        putTrack(\.pan, -command.value, id: partner, host: host, now: now)
                    }
                case .resetMeterPeak: putTrack(\.peakDB, nil, id: target, host: host, now: now)
                case .setOutputRoutes: putTrack(\.outputRoutes, command.outputRoutes, id: target, host: host, now: now)
                default: return false
                }
            } else {
                switch command.action {
                case .mute: put(\.masterMute, !display.masterMute, host: host, now: now)
                case .solo: put(\.masterSolo, !display.masterSolo, host: host, now: now)
                case .volume: put(\.masterVolume, gain, host: host, now: now)
                case .pan: put(\.masterPan, command.value, host: host, now: now)
                case .resetMeterPeak: put(\.masterPeakDB, nil, host: host, now: now)
                case .setOutputRoutes: put(\.masterOutputRoutes, command.outputRoutes, host: host, now: now)
                default: return false
                }
            }
        case .clipMute, .clipGain:
            guard let target, let clip = display.tracks.lazy.compactMap({ $0.clips.first(where: { $0.id == target }) }).first else { return false }
            if command.action == .clipMute { putClip(\.muted, clip.muted != true, id: target, host: host, now: now) }
            else { putClip(\.gain, command.value, id: target, host: host, now: now) }
        case .queueSection, .cancelSection:
            let marker = command.action == .queueSection ? target : nil
            guard display.sectionPlayback != nil else { return false }
            add(Key(field: \State.sectionPlayback, target: nil), host: host, now: now,
                matches: { $0.sectionPlayback?.queuedMarker == marker }, apply: { $0.sectionPlayback?.queuedMarker = marker })
        case .selectRegion, .browseRegion:
            guard let target, let region = (display.regions + display.timelineRegions).first(where: { $0.id == target }) else { return false }
            let source = region.sourceRegionId ?? region.id
            if command.action == .browseRegion {
                put(\.focusedRegion, target, host: host, now: now)
            } else if display.playing {
                guard DAWRemoteSetlistPresentation.canQueueDuplicate(target, in: display) else { return false }
                let current = display.timelineRegions.first { $0.id == display.currentRegion }
                if let parent = region.parentRegion, parent == current?.id || parent == current?.parentRegion { return false }
                let queued = display.setlistQueuedEntryId == target
                let focusingCurrent = source == current?.id || source == current?.parentRegion
                put(\.focusedRegion, queued ? nil : target, host: host, now: now) { state in
                    guard !focusingCurrent else { return }
                    state.queuedRegion = queued ? nil : source
                    state.queuedPlaylistEntryId = queued || state.selectedPlaylist == nil ? nil : target
                    state.songDisplays?.queued = queued ? nil : region.name
                    state.songDisplays?.queuedBPM = nil
                    state.sectionPlayback?.secondaryRegion = state.queuedRegion
                    state.queueStartedAt = queued ? nil : state.position
                    if queued { state.regionAuto = false; state.subPlaying = false }
                }
            } else {
                put(\.focusedRegion, target, host: host, now: now) { state in
                    state.currentRegion = source; state.currentPlaylistEntryId = state.selectedPlaylist == nil ? nil : target
                    state.gridRegion = region.parentRegion ?? source
                    state.position = region.start; state.editPosition = region.start
                    state.songDisplays?.current = region.name; state.songDisplays?.currentBPM = nil
                    state.sectionPlayback?.currentRegion = source; state.sectionPlayback?.position = region.start
                }
            }
        case .selectPlaylist:
            guard target == nil || display.playlists?.contains(where: { $0.id == target }) == true else { return false }
            put(\.selectedPlaylist, target, host: host, now: now)
        case .editRegion:
            guard let target, let name = command.text?.trimmingCharacters(in: .whitespacesAndNewlines), let region = display.regions.first(where: { $0.id == target }) else { return false }
            let source = region.sourceRegionId ?? target, color = UInt32(command.value)
            add(Key(field: \State.regions, target: source), host: host, now: now,
                matches: { state in state.timelineRegions.first(where: { $0.id == source }).map { $0.name == name && $0.color == color } ?? true },
                apply: { state in
                    for index in state.regions.indices where (state.regions[index].sourceRegionId ?? state.regions[index].id) == source {
                        state.regions[index].name = name; state.regions[index].color = color
                    }
                    if let index = state.timelineRegions.firstIndex(where: { $0.id == source }) {
                        state.timelineRegions[index].name = name; state.timelineRegions[index].color = color
                    }
                })
        case .deleteRegion:
            guard let target else { return false }
            add(Key(field: \State.regions, target: target), host: host, now: now,
                matches: { !$0.regions.contains(where: { $0.id == target }) },
                apply: { state in
                    state.regions.removeAll { $0.id == target }
                    if command.playlist == nil { state.timelineRegions.removeAll { $0.id == target || $0.parentRegion == target } }
                })
        case .renamePlaylist, .deletePlaylist:
            guard let target else { return false }
            let name = command.action == .deletePlaylist ? nil : command.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            add(Key(field: \State.playlists, target: target), host: host, now: now,
                matches: { $0.playlists?.first(where: { $0.id == target })?.name == name },
                apply: { state in
                    if let name, let index = state.playlists?.firstIndex(where: { $0.id == target }) { state.playlists?[index].name = name }
                    else { state.playlists?.removeAll { $0.id == target } }
                })
        case .vinhetasPreset:
            let preset = Int(command.value)
            add(Key(field: \DAWRemoteVinhetas.selectedPreset, target: nil), host: host, now: now,
                matches: { $0.vinhetas?.selectedPreset == preset }, apply: { $0.vinhetas?.selectedPreset = preset })
        case .vinhetasVolume:
            guard let preset = command.preset, let pad = command.pad, let pads = display.vinhetas?.presets, pads.indices.contains(preset), pads[preset].pads.indices.contains(pad) else { return false }
            add(Key(field: \DAWRemoteVinhetas.Pad.volume, target: nil, index: preset * 16 + pad), host: host, now: now,
                matches: { $0.vinhetas?.presets[preset].pads[pad].volume == command.value },
                apply: { $0.vinhetas?.presets[preset].pads[pad].volume = command.value })
        case .save:
            guard display.pendingSave, !display.saving else { return false }
            add(Key(field: \State.saving, target: nil), host: host, now: now,
                matches: { $0.saving || !$0.pendingSave }, apply: { $0.saving = true })
        case .openRecentProject, .openRecentProjectInNewTab:
            guard display.projects?.busy == false else { return false }
            add(Key(field: \State.projects, target: nil), host: host, now: now,
                matches: { $0.projects?.busy == true || $0.projects?.commandID == command.id },
                apply: { $0.projects?.busy = true; $0.projects?.canOpen = false; $0.projects?.canOpenInNewTab = false })
        case .noticeClear, .noticePin, .noticePinStopped, .noticeDestination, .noticeSaveTemplate:
            guard display.notices != nil else { return false }
            switch command.action {
            case .noticeClear:
                add(Key(field: \DAWRemoteNotices.active, target: nil), host: host, now: now,
                    matches: { $0.notices?.active != true },
                    apply: { $0.notices?.active = false; $0.notices?.pinned = false; $0.notices?.remaining = 0 })
            case .noticePin: putNotice(\.pinned, command.value == 1, host: host, now: now)
            case .noticePinStopped: putNotice(\.pinWhenStopped, command.enabled, host: host, now: now)
            case .noticeDestination:
                putNotice(command.value == 1 ? \.window1 : \.window2, command.enabled == true, host: host, now: now)
            case .noticeSaveTemplate:
                let index = Int(command.value), text = command.text ?? ""
                add(Key(field: \DAWRemoteNotices.templates, target: nil, index: index), host: host, now: now,
                    matches: { $0.notices?.templates[index] == text }, apply: { $0.notices?.templates[index] = text })
            default: return false
            }
        default: return false
        }
        return true
    }

    private mutating func scope(_ state: State) {
        guard state.project != project || state.song != song else { return }
        edits.removeAll(); project = state.project; song = state.song
    }
    private mutating func add(_ key: Key, host: State, now: TimeInterval, matches: @escaping (State) -> Bool,
                              apply: @escaping (inout State) -> Void) {
        let pending = edits.contains { $0.key == key }
        edits.removeAll { $0.key == key }
        edits.append(Edit(key: key, matches: matches, apply: apply, expiration: now + 3, waitForChange: pending && matches(host)))
    }
    private mutating func put<Value: Equatable>(_ path: WritableKeyPath<State, Value>, _ value: Value, host: State, now: TimeInterval,
                                                apply: @escaping (inout State) -> Void = { _ in }) {
        add(Key(field: path, target: nil), host: host, now: now, matches: { $0[keyPath: path] == value },
            apply: { $0[keyPath: path] = value; apply(&$0) })
    }
    private mutating func putTrack<Value: Equatable>(_ path: WritableKeyPath<State.Track, Value>, _ value: Value,
                                                     id: UUID, host: State, now: TimeInterval) {
        add(Key(field: path, target: id), host: host, now: now,
            matches: { $0.tracks.first(where: { $0.id == id }).map { $0[keyPath: path] == value } ?? true },
            apply: { if let index = $0.tracks.firstIndex(where: { $0.id == id }) { $0.tracks[index][keyPath: path] = value } })
    }
    private mutating func putNotice<Value: Equatable>(_ path: WritableKeyPath<DAWRemoteNotices, Value>, _ value: Value,
                                                      host: State, now: TimeInterval) {
        add(Key(field: path, target: nil), host: host, now: now,
            matches: { $0.notices.map { $0[keyPath: path] == value } ?? true },
            apply: { $0.notices?[keyPath: path] = value })
    }
    private mutating func putClip<Value: Equatable>(_ path: WritableKeyPath<State.Clip, Value>, _ value: Value,
                                                    id: UUID, host: State, now: TimeInterval) {
        add(Key(field: path, target: id), host: host, now: now,
            matches: { state in state.tracks.lazy.compactMap { $0.clips.first(where: { $0.id == id }) }.first.map { $0[keyPath: path] == value } ?? true },
            apply: { state in
                for track in state.tracks.indices {
                    guard let clip = state.tracks[track].clips.firstIndex(where: { $0.id == id }) else { continue }
                    state.tracks[track].clips[clip][keyPath: path] = value
                    break
                }
            })
    }
    private static func silentTracks(_ tracks: [State.Track]) -> Set<UUID> {
        let hierarchy = DAWRemoteTrackHierarchy(tracks)
        let solos = Set(tracks.lazy.filter(\.solo).map(\.id))
        guard !solos.isEmpty else { return Set(tracks.lazy.filter(\.mute).map(\.id)) }
        let soloAncestors = solos.reduce(into: Set<UUID>()) { $0.formUnion(hierarchy.ancestors(of: $1)) }
        return Set(tracks.lazy.filter { track in
            track.mute || (!solos.contains(track.id) && !soloAncestors.contains(track.id) && !hierarchy.ancestors(of: track.id).contains(where: solos.contains))
        }.map(\.id))
    }
}

/// Keeps the predicted selection through a late packet for the same advancing
/// song. A seek, a new queue, loop, project or playlist immediately supersedes it.
struct DAWRemoteBlockFeedback {
    private(set) var confirmed: DAWRemoteState?
    private(set) var plan: DAWRemoteBlockPreparation?
    private(set) var deadline: Double?
    private var completed = false
    private var manualStopUntil: Double?
    mutating func stop(_ state: DAWRemoteState, now: Double) -> DAWRemoteState? {
        reset()
        guard let next = DAWRemoteBlockPreparation(state, stopping: true) else { return nil }
        confirmed = state; plan = next; completed = true
        manualStopUntil = now + 1.5; deadline = manualStopUntil
        return next.applying(to: state)
    }
    mutating func receive(_ state: DAWRemoteState, now: Double) -> DAWRemoteState {
        if let until = manualStopUntil {
            if now < until, let plan, DAWRemoteBlockPreparation(state, stopping: true) == plan,
               state.position + 1e-6 >= (confirmed?.position ?? 0) {
                confirmed = state
                return plan.applying(to: state)
            }
            reset() // Host confirmation, a seek or timeout supersedes optimism.
        }
        let next = DAWRemoteBlockPreparation(state)
        let samePosition = next == plan && state.position == confirmed?.position
        let previousDeadline = deadline
        if next != plan || state.position + 1e-6 < (confirmed?.position ?? 0) { completed = false }
        confirmed = state; plan = next
        deadline = next == nil || completed ? nil : (samePosition ? previousDeadline : nil) ?? (now + max(0, next!.end - state.position))
        return completed ? next!.applying(to: state) : state
    }
    mutating func advance(now: Double) -> DAWRemoteState? {
        guard let deadline, now >= deadline, let plan, let confirmed else { return nil }
        if manualStopUntil != nil { reset(); return confirmed }
        completed = true; self.deadline = nil
        return plan.applying(to: confirmed)
    }
    mutating func reset() { self = Self() }
}

/// Drawer state belongs to the local presentation; choosing a child still sends
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
    /// Observer browsing is independent of both playback heads. A hidden child
    /// points to its drawer; playlist copies retain their own entry identity.
    static func observerFocus(in state: DAWRemoteState, expanded: Set<UUID>) -> UUID? {
        guard let id = state.focusedRegion else { return nil }
        if state.regions.contains(where: { $0.id == id }) { return id }
        guard let parent = state.timelineRegions.first(where: { $0.id == id })?.parentRegion,
              state.regions.contains(where: { $0.id == parent }) else { return nil }
        return expanded.contains(parent) ? id : parent
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
    private var order: Int?
    private var cached: [DAWRemoteSetlistPresentation.Row] = []
    private var blocks: [DAWRemoteState.SetlistBlock] = []
    private var cachedEntries: [DAWRemoteSetlistPresentation.Entry] = []
    private var initialized = false
    private(set) var rebuildCount = 0
    func rows(in state: DAWRemoteState, expanded: Set<UUID>, query: String) -> [DAWRemoteSetlistPresentation.Row] {
        update(in: state, expanded: expanded, query: query)
        return cached
    }
    func entries(in state: DAWRemoteState, expanded: Set<UUID>, query: String, order: Int? = nil) -> [DAWRemoteSetlistPresentation.Entry] {
        update(in: state, expanded: expanded, query: query, order: state.selectedPlaylist == nil ? order : nil)
        return cachedEntries
    }
    private func update(in state: DAWRemoteState, expanded: Set<UUID>, query: String, order: Int? = nil) {
        if initialized && regions == state.regions && timeline == state.timelineRegions && blocks == (state.setlistBlocks ?? []) && self.expanded == expanded && self.query == query && self.order == order { return }
        initialized = true; regions = state.regions; timeline = state.timelineRegions
        self.expanded = expanded; self.query = query; blocks = state.setlistBlocks ?? []
        self.order = order
        var presentation = state
        if let order {
            presentation.regions = state.regions.enumerated().sorted { a, b in
                if order != 0 {
                    let result = a.element.name.compare(b.element.name, options: [.numeric, .caseInsensitive, .diacriticInsensitive], locale: .current)
                    if result != .orderedSame { return order == 1 ? result == .orderedAscending : result == .orderedDescending }
                }
                if a.element.start != b.element.start { return a.element.start < b.element.start }
                return a.offset < b.offset
            }.map(\.element)
        }
        let allRows = DAWRemoteSetlistPresentation.rows(in: presentation, expanded: expanded, query: "")
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

struct TabletWorkspacePanelWidths {
    let track: Double
    let setlist: Double
    let grid: Double

    init(trackVisible: Bool, trackWidth: Double, setlistFraction: Double, reference: Double, available: Double) {
        let available = max(0, available)
        track = trackVisible ? min(available, trackWidth) : 0
        setlist = min(setlistFraction * reference, available - track)
        grid = available - track - setlist
    }
}

enum NativeRegionDrawerSwipe {
    static func isHorizontal(x: Double, y: Double) -> Bool { abs(x) > abs(y) * 1.3 }
    static func expansion(x: Double, y: Double) -> Bool? {
        guard abs(x) >= 28, isHorizontal(x: x, y: y) else { return nil }
        return x < 0
    }
}

/// Match desktop lane heights while retaining alignment between mixer and grid.
enum DAWRemoteItemLayout {
    static let defaultLaneHeight = 86.0
    static let maximumHeightScale = 3.0
    static func heightScale(_ value: Double) -> Double { value.isFinite ? min(maximumHeightScale, max(0.1, value)) : 1 }
    static func laneHeight(_ track: DAWRemoteState.Track, scale: Double = 1) -> Double {
        max((track.laneCount ?? 1) > 1 ? 26 : 24, defaultLaneHeight * ((track.laneCount ?? 1) > 1 ? 0.7 : 1) * heightScale(scale) * (track.heightScale ?? 1))
    }
    static func rowHeight(_ track: DAWRemoteState.Track, scale: Double = 1, minimum: Double = 0) -> Double {
        max(track.compactComponents == true ? min(TrackHeightGeometry.compactMinimumLaneHeight, minimum) : minimum, track.minimumHeight ?? 0, laneHeight(track, scale: scale) * Double(max(1, track.laneCount ?? 1)))
    }
    static func resizedTrackHeightScale(_ track: DAWRemoteState.Track, scale: Double,
                                        minimum: Double, translation: Double) -> Double? {
        guard translation.isFinite else { return nil }
        let count = max(1, track.laneCount ?? 1)
        let unit = defaultLaneHeight * (count > 1 ? 0.7 : 1) * heightScale(scale) * Double(count)
        var shortest = track
        shortest.heightScale = TrackHeightGeometry.minimumScale
        let floor = rowHeight(shortest, scale: scale, minimum: minimum)
        let start = rowHeight(track, scale: scale, minimum: minimum)
        let ceiling = max(start, Double(count) * TrackHeightGeometry.laneLimits(count: count).upperBound)
        let height = min(ceiling, max(floor, start + translation))
        guard abs(height - start) > 0.01 else { return nil }
        return min(TrackHeightGeometry.maximumScale, max(TrackHeightGeometry.minimumScale, height / unit))
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
    var textStyled: String? = nil, chordsStyled: String? = nil
    var progress: Double
    var style: Style
    var preview: Bool = false
    var blocks: [Block] = []
    var mediaName: String? = nil
    var imageID: UUID? = nil
    // Optional for compatibility with hosts predating full native projection settings.
    var settings: TeleprompterSettings? = nil
    // Optional so clients can still decode projection data from older hosts.
    var loopActive: Bool? = nil
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
    /// Optional capability fields keep older desktop snapshots compatible.
    var pinWhenStopped: Bool? = nil
    var stoppedNoticeActive: Bool? = nil
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
    var mode: String? = nil // Missing on older hosts means countdown.
    var valid: Bool { (0...359999).contains(targetSeconds) && remainingSeconds.isFinite &&
        (mode == nil || mode == "progressive" || mode == "countdown") }
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
    var transportDisplayRegion: Region? {
        guard playing || paused else { return nil }
        let list = timelineRegions.isEmpty ? regions : timelineRegions
        if let id = sectionPlayback?.currentRegion,
           let region = list.first(where: { $0.id == id }), position >= region.start,
           position < (sectionPlayback?.currentEnd ?? region.end) { return region }
        var current: Region?
        for region in list where position >= region.start && position < region.end {
            if let previous = current, previous.end - previous.start <= region.end - region.start { continue }
            current = region
        }
        return current ?? list.first { $0.id == currentRegion }
    }
    func nativeTransportSongName(selectedRegionID: UUID?) -> String {
        if playing || paused { return transportDisplayRegion?.name ?? "—" }
        guard let selectedRegionID else { return "—" }
        return (timelineRegions + regions).first { $0.id == selectedRegionID }?.name ?? "—"
    }
    var currentSongName: String {
        if let region = transportDisplayRegion { return region.name }
        return songDisplays?.current ?? (timelineRegions + regions).first(where: { $0.id == (focusedRegion ?? currentRegion) })?.name ?? songName
    }
}

/// Optional capability for older hosts; remaining time is relative, never wall-clock dependent.
struct DAWRemoteFadeoutState: Codable, Equatable {
    var runID: UUID?
    var duration: Double
    var remaining: Double
    var lastCommandID: UUID? = nil
    var active: Bool { runID != nil }
    var valid: Bool { duration.isFinite && (1...5).contains(duration) && remaining.isFinite && (0...duration).contains(remaining) && (active || remaining == 0) }
}

enum DAWRemoteItemWaveform {
    static func amplitude(seed: Int, fraction: Double, gain: Double?) -> Double {
        let phase = fraction * 300 + Double(seed)
        let scale = gain.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 1
        return min(1, (0.12 + 0.78 * abs(sin(phase * 0.37) * cos(phase * 0.13))) * scale)
    }
}
