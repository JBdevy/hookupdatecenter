import SwiftUI
#if os(macOS)
import UniformTypeIdentifiers
import Combine
struct DAWRemoteHostView: View {
    @ObservedObject private var remote = DAWRemoteSession.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "Remote").font(.headline)
            Text("Open Remote on the iPad and choose this computer.").font(.callout)
            Text(LocalizedStringKey(remote.status)).font(.caption).foregroundStyle(remote.connected ? JarasTheme.green : JarasTheme.secondary)
            if !remote.peerName.isEmpty { Text(verbatim: remote.peerName).font(.caption) }
            Text("Audio continues on the Mac. Keep Wi-Fi and Bluetooth on to connect directly to a nearby iPad.").font(.caption).foregroundStyle(JarasTheme.secondary)
            Button("Disable Remote") { remote.stop() }
        }.padding(20).frame(width: 320).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
    }
}
#else
import UIKit
struct DAWRemoteClientView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var remote = DAWRemoteSession.shared
    @StateObject private var localTimer = RemoteLocalTimer()
    var body: some View {
        VStack(spacing: 0) {
            if remote.connected {
                if let state = remote.remoteState {
                    NativeRemoteWorkspace(state: state, computerName: remote.peerName, timer: localTimer, send: remote.send,
                                          exitRemote: { remote.stop(); dismiss() })
                } else { ProgressView("Waiting for the computer…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                connectionPicker
            }
        }.background(JarasTheme.background).foregroundStyle(JarasTheme.text)
            .ignoresSafeArea(.container).statusBarHidden(true).persistentSystemOverlays(.hidden)
            .onAppear { remote.browse() }.onDisappear { remote.stop() }
            .onChange(of: remote.connected) { connected in
                if connected {
                    localTimer.resetSynchronization()
                    localTimer.synchronize(remote.remoteState?.timer)
                }
            }
            .onChange(of: remote.remoteState?.timer) { localTimer.synchronize($0) }
            .onChange(of: scenePhase) { phase in if phase == .active && !remote.enabled { remote.browse() } }
    }

    private var connectionPicker: some View {
        VStack(spacing: 0) {
            HStack {
                Button { remote.stop(); dismiss() } label: {
                    Label("Voltar", systemImage: "chevron.left").font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(JarasTheme.secondary)
                Spacer()
            }.padding(24)
            Spacer(minLength: 12)
            VStack(spacing: 22) {
                Image(systemName: "desktopcomputer").font(.system(size: 38, weight: .light))
                    .foregroundStyle(JarasTheme.green).frame(width: 80, height: 80)
                    .background(JarasTheme.green.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 20))
                VStack(spacing: 8) {
                    Text("Conectar ao Mac").font(.system(size: 25, weight: .semibold))
                    Text("Deixe o Wi-Fi e o Bluetooth ligados nos dois aparelhos.\nAtive Remote no Jaras do Mac e escolha-o abaixo.")
                        .font(.system(size: 14)).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
                    Label("Conexão direta · sem roteador ou internet", systemImage: "wifi")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(JarasTheme.green)
                }
                VStack(spacing: 10) {
                    HStack {
                        Text("Macs disponíveis").font(.system(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.secondary)
                        Spacer()
                        Button { remote.browse() } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 30)
                        }.buttonStyle(.plain).foregroundStyle(JarasTheme.green).disabled(remote.connecting)
                            .accessibilityLabel("Buscar Macs novamente")
                    }
                    if remote.peers.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().tint(JarasTheme.green)
                            Text("Procurando Macs…").font(.system(size: 14)).foregroundStyle(JarasTheme.secondary)
                        }.frame(maxWidth: .infinity).frame(height: 76).background(JarasTheme.background).cornerRadius(10)
                    } else {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(remote.peers, id: \.self) { peer in
                                    Button { remote.connect(peer) } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "desktopcomputer").font(.system(size: 22)).foregroundStyle(JarasTheme.green)
                                            Text(verbatim: peer.displayName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                            Spacer()
                                            if remote.connecting && remote.peerName == peer.displayName { ProgressView().tint(JarasTheme.green) }
                                            else { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.secondary) }
                                        }.padding(16).background(JarasTheme.background).cornerRadius(10)
                                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(remote.connecting && remote.peerName == peer.displayName ? JarasTheme.green : JarasTheme.line))
                                    }.buttonStyle(.plain).disabled(remote.connecting)
                                }
                            }
                        }.frame(maxHeight: min(220, CGFloat(remote.peers.count) * 68))
                    }
                    if remote.status.hasPrefix("Connection failed") {
                        Text("Não foi possível conectar. Aproxime os aparelhos e confira o Remote no Mac.")
                            .font(.system(size: 12)).foregroundStyle(JarasTheme.yellow)
                    } else if remote.status == "Disconnected" {
                        Text("Conexão encerrada. Escolha o Mac para reconectar.")
                            .font(.system(size: 12)).foregroundStyle(JarasTheme.secondary)
                    }
                }
            }.padding(28).frame(maxWidth: 520).background(JarasTheme.panel).cornerRadius(18)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(JarasTheme.line))
                .padding(.horizontal, 24)
            Spacer(minLength: 40)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

#endif

#if os(macOS)
@MainActor enum DAWRemoteHostBridge {
    static weak var documents: ProjectDocuments?
    private static var requestedPanel = 0
    private static var noticeImageDate = Date.distantPast
    private static var noticeImageData: Data?
    private static var lastTimerState: TeleprompterTimer?
    private static var timerRevision = UUID()
    private static var lastTimerCommandID: UUID?
    private static var connectionObservation: AnyCancellable?
    private static var cachedProject: UUID?, cachedSong: UUID?, cachedRevision: UInt64?
    private static var cachedItems: [UUID: (clips: [DAWRemoteState.Clip], lanes: Int)] = [:]
    static func bind(_ show: ShowController) {
        cachedProject = nil; cachedSong = nil; cachedRevision = nil; cachedItems.removeAll()

        let session = DAWRemoteSession.shared
        connectionObservation = session.$connected.removeDuplicates().sink { connected in
            MainActor.assumeIsolated { if !connected { requestedPanel = 0 } }
        }
        session.stateProvider = { [weak show] in
            guard let show, DAWRemoteSession.shared.connected else { return nil }
            let documents = Self.documents.flatMap { $0.show === show ? $0 : nil }
            let snapshot = show.snapshot, song = show.current, transport = snapshot.transport
            // Geometry and item metadata change with project edits, not transport ticks.
            if cachedProject != snapshot.project.id || cachedSong != song?.id || cachedRevision != show.projectRevision {
                cachedProject = snapshot.project.id; cachedSong = song?.id; cachedRevision = show.projectRevision
                cachedItems = Dictionary(uniqueKeysWithValues: (song?.tracks ?? []).filter { $0.kind == .standard }.map { track in
                    let lanes = TrackLanes(track: track)
                    let clips = track.clips.map { DAWRemoteState.Clip(id: $0.id, name: $0.name, start: $0.startTime, duration: $0.duration,
                        gain: $0.gain ?? 1, muted: $0.muted ?? false, lane: lanes.lanes[$0.id] ?? 0) }
                    return (track.id, (clips: clips, lanes: lanes.count))
                })
            }
            let selectedPlaylist = show.selectedRegionPlaylist
            let regionTextColor = UInt32(AppearanceColor.shared(selectedPlaylist == nil ? "jaras.setlist.allRegionsTextColor" : "jaras.setlist.playlistTextColor",
                default: selectedPlaylist == nil ? 0xffffff : 0x00ff9a).value)
            let unifiedTextColor = UInt32(AppearanceColor.shared("jaras.setlist.unifiedTextColor", default: 0xffeb3b).value)
            @MainActor func region(_ part: Part) -> DAWRemoteState.Region {
                .init(id: part.id, name: part.displayName, start: part.startTime, end: part.endTime, color: part.color ?? 0x705264,
                      nameColor: part.parentRegionID != nil ? unifiedTextColor : regionTextColor, parentRegion: part.parentRegionID)
            }
            let selected = transport.playing ? show.pitchRegion : song?.parts.first { $0.id == (show.focusedRegion ?? transport.regionId) }
            let hasMultiLoop = selected.map { part in
                part.totalLoop == true || !(part.multiLoops ?? []).isEmpty || (song?.parts.contains { candidate in
                    (candidate.id == part.parentRegionID || candidate.parentRegionID == part.id) &&
                    (candidate.totalLoop == true || !(candidate.multiLoops ?? []).isEmpty)
                } ?? false)
            } ?? false
            let information = transport.ignoreNextAfter != nil ? "Ignore Next" : hasMultiLoop ? JarasLocalization.string("This song has an active multiloop") : transport.loop.enabled ? JarasLocalization.string("Loop armed") : ""
            let internalNext = transport.playing && transport.ignoreNextAfter == nil ? song?.nextDrawerRegion(transport.regionId, position: transport.position) : nil
            let queued = transport.subPlay.playing
                ? song?.parts.first { transport.subPlay.position >= $0.startTime && transport.subPlay.position < $0.endTime }
                : song?.parts.first { $0.id == transport.queuedRegionId }
            return DAWRemoteState(project: snapshot.project.id, projectName: snapshot.project.name,
                song: song?.id, songName: song?.name ?? "—",
                songs: snapshot.project.songs.map { .init(id: $0.id, name: $0.name) },
                tracks: (song?.tracks ?? []).filter { $0.kind == .standard }.map { track in
                    let items = cachedItems[track.id]
                    return .init(id: track.id, name: track.name, color: track.color ?? JarasTheme.roleHex(track.role),
                          volume: track.volume, pan: track.pan, mute: track.mute, solo: track.solo,
                          clips: items?.clips ?? [],
                          nameColor: JarasTheme.trackNameHex(track, emphasized: show.mixerTrackSelection.contains(track.id), silenced: song?.isSilenced(track) ?? track.mute),
                          emphasized: show.mixerTrackSelection.contains(track.id), silenced: song?.isSilenced(track) ?? track.mute, laneCount: items?.lanes ?? 1, linkedTrack: track.stereoLink?.partner)
                }, regions: show.listedRegions.map(region), timelineRegions: (song?.parts ?? []).map(region),
                currentRegion: transport.regionId, queuedRegion: transport.queuedRegionId, focusedRegion: show.focusedRegion,
                position: transport.position, duration: song?.duration ?? 0,
                bpm: song?.tempoSection(at: transport.position).bpm ?? 120,
                playing: transport.playing, paused: transport.paused ?? false,
                subPlaying: transport.subPlay.playing, loop: transport.loop.enabled,
                masterVolume: snapshot.project.masterVolume ?? 1, masterMute: snapshot.project.masterMute ?? false,
                masterSolo: snapshot.project.masterSolo ?? false, masterMono: snapshot.project.masterMono ?? false,
                pendingSave: show.hasUnsavedChanges, saving: show.saving, message: show.message,
                pitchRegion: show.pitchRegion?.id, pitchSemitones: show.pitchRegion?.semitones,
                setlistFontStyle: UserDefaults.standard.integer(forKey: "jaras.setlist.fontStyle"),
                prepareOnly: show.regionSetlist.preparesWithoutPlayback,
                masterColor: snapshot.project.masterColor ?? 0xffdc52,
                masterNameColor: JarasTheme.masterNameHex(snapshot.project.masterColor ?? 0xffdc52),
                regionAuto: show.regionSetlist.autoAdvance, queueStartedAt: transport.queueStartedAt,
                playbackEnd: transport.ignoreNextEnd ?? song?.parts.first(where: { $0.id == transport.regionId })?.endTime,
                projectSavedAt: show.lastSavedAt ?? snapshot.project.updatedAt, footerInformation: information,
                upcomingName: (internalNext ?? queued)?.displayName,
                upcomingKind: internalNext != nil ? "Next song" : transport.subPlay.playing ? "Sub Play" : "Queued song",
                playlists: show.regionSetlist.playlists.filter { $0.songId == song?.id }.map { .init(id: $0.id, name: $0.name) },
                selectedPlaylist: selectedPlaylist?.id,
                gridRegion: transport.playing ? song?.playingSetlistRegion(transport.regionId, position: transport.position, expanded: [])?.id : (show.focusedRegion ?? transport.regionId),
                markers: (song?.markers ?? []).filter { !$0.isTempo }.map { .init(id: $0.id, name: $0.name, position: $0.position, color: $0.color) },
                projects: documents?.remoteProjectBrowser,
                teleprompters: (1...2).contains(requestedPanel) ? [teleprompter(index: requestedPanel, snapshot: snapshot, directory: documents?.currentURL?.deletingLastPathComponent())] : nil,
                notices: requestedPanel == 0 ? nil : notices(project: snapshot.project.id), timer: timerState())
        }
        session.commandHandler = { [weak show] command in
            guard command.valid else { return }
            if command.action == .timerStart || command.action == .timerStop {
                lastTimerCommandID = command.id; timerRevision = UUID()
            }
            guard let show, command.project == show.snapshot.project.id else { return }
            let documents = Self.documents.flatMap { $0.show === show ? $0 : nil }
            if command.action == .remotePanel { requestedPanel = Int(command.value); return }
            if handleNotice(command) { return }
            if command.action == .timerStart {
                let timer = TeleprompterTimerController.shared, seconds = Int(command.value)
                timer.stopAndReset()
                if timer.setTargetText(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)) { timer.start() }
                return
            }
            if command.action == .timerStop { TeleprompterTimerController.shared.stopAndReset(); return }
            if command.action == .openRecentProject {
                if let target = command.target { documents?.openRemoteProject(target) }
                return
            }
            guard documents?.busy != true, command.song == show.current?.id else { return }
            if [.volume, .pan, .mute, .solo].contains(command.action), let target = command.target {
                guard show.current?.tracks.contains(where: { $0.id == target }) == true else { return }
            }
            if [.clipGain, .clipMute].contains(command.action) {
                guard let target = command.target, show.current?.tracks.contains(where: { track in
                    track.kind == .standard && track.clips.contains { $0.id == target }
                }) == true else { return }
            }
            switch command.action {
            case .save: Task { await show.save() }
            case .toggleRegionAuto: show.toggleRegionAuto()
            case .clipGain:
                if let target = command.target { show.setItemGain(target, gain: command.value) }
            case .clipMute: show.send(.clipMute, target: command.target)
            case .selectPlaylist:
                if let target = command.target {
                    guard show.regionSetlist.playlists.contains(where: { $0.id == target && $0.songId == show.current?.id }) else { return }
                }
                show.selectRegionPlaylist(command.target)
            case .selectRegion:
                guard let target = command.target, show.current?.parts.contains(where: { $0.id == target }) == true else { return }
                show.focusRegion(target)
            case .selectSong:
                guard let target = command.target, show.snapshot.project.songs.contains(where: { $0.id == target }) else { return }
                show.send(show.isPlaying ? .queue : .select, target: target)
            case .pitch:
                guard let song = show.current, let region = show.pitchRegion, region.id == command.target else { return }
                let targets = song.pitchTargets(region)
                show.setRegionPitch(region.id, semitones: Int(command.value), tracks: targets.tracks, groups: targets.groups)
            case .tempo: show.setTempo(command.value)
            case .seek:
                guard !show.isPlaying, let song = show.current,
                      let target = command.target, target == (show.focusedRegion ?? show.snapshot.transport.regionId),
                      let region = song.parts.first(where: { $0.id == target }) else { return }
                show.send(.seek, value: min(region.endTime, max(region.startTime, command.value)))
            default:
                guard let action = ShowCommand(rawValue: command.action.rawValue) else { return }
                show.send(action, target: command.target, value: command.value)
            }
        }
    }

    private static func timerState() -> DAWRemoteTimerState {
        let state = TeleprompterTimerController.shared.state
        if lastTimerState != state { lastTimerState = state; timerRevision = UUID() }
        return .init(revision: timerRevision, targetSeconds: state.targetSeconds, running: state.running,
                     remainingSeconds: state.displaySeconds(at: ProcessInfo.processInfo.systemUptime), commandID: lastTimerCommandID)
    }

    private static func boundedNotice(_ text: String) -> String {
        var text = String(text.prefix(500))
        while text.utf8.count > 4000 { text.removeLast() }
        return text
    }
    private static func handleNotice(_ command: DAWRemoteCommand) -> Bool {
        let model = TPNoticeController.shared
        switch command.action {
        case .noticeSend:
            model.select(Int(command.value)); model.draft = command.text ?? ""; model.send()
        case .noticeClear: model.clear()
        case .noticePin:
            if model.pinned != (command.value == 1) { model.togglePin() }
        case .noticeDestination:
            if command.value == 1 { model.appearance.window1 = command.enabled == true }
            else { model.appearance.window2 = command.enabled == true }
        case .noticeSaveTemplate: model.templates[Int(command.value)] = command.text ?? ""
        default: return false
        }
        return true
    }
    private static func notices(project: UUID) -> DAWRemoteNotices {
        let model = TPNoticeController.shared, appearance = model.appearance
        if noticeImageDate != model.sentAt {
            noticeImageDate = model.sentAt
            noticeImageData = model.remoteImage.flatMap { value in
                value.firstIndex(of: ",").flatMap { Data(base64Encoded: String(value[value.index(after: $0)...])) }
            }
        }
        let imageID = model.active ? noticeImageData.flatMap {
            DAWRemoteSession.shared.imageID(for: $0, project: project, key: "notice-\(model.sentAt.timeIntervalSince1970)")
        } : nil
        return .init(templates: model.templates.map(boundedNotice), imageSlots: model.images.map { $0 != nil },
                     message: boundedNotice(model.message), active: model.active, pinned: model.pinned,
                     remaining: min(20, max(0, Int(ceil(model.remaining())))), window1: appearance.window1, window2: appearance.window2,
                     textColor: appearance.text, backgroundColor: appearance.background, flashColor: appearance.flash,
                     font: appearance.font, scale: appearance.scale, emoji: appearance.emojiEnabled ? appearance.emoji : "",
                     cleanDisplay: appearance.cleanDisplay, sentAt: model.sentAt.timeIntervalSince1970, imageID: imageID)
    }
    private static func teleprompter(index: Int, snapshot: ShowSnapshot, directory: URL?) -> DAWRemoteTeleprompter {
        let settings = (index == 1 ? TeleprompterPreferences.shared : .second).settings
        let controller = index == 1 ? TeleprompterWindow.shared : .second
        let transport = snapshot.transport
        let original = snapshot.project.songs.first { $0.id == transport.songId } ?? snapshot.project.songs.first
        let song = original.map { transport.multiLoop?.projectionSong($0) ?? $0 }
        let position = transport.playing ? transport.position : transport.editPosition ?? transport.position
        let region = (!transport.playing ? song?.parts.first { position >= $0.startTime && position < $0.endTime } : nil)
            ?? song?.parts.first { $0.id == transport.regionId }
            ?? song?.parts.first { position >= $0.startTime && position < $0.endTime }
        let queued = song?.parts.first { $0.id == transport.queuedRegionId }
        let kind: TrackKind = index == 1 ? .teleprompt : .teleprompt2
        var lyric: AudioClip?, chord: AudioClip?, media: AudioClip?
        for track in song?.tracks ?? [] where !track.mute && (track.kind == kind || track.kind == .chords) {
            let active = track.clips.filter { $0.muted != true && position >= $0.startTime && position < $0.startTime + $0.duration }
            if track.kind == kind {
                if lyric == nil { lyric = active.filter { !$0.isProjectionMedia }.max { $0.startTime < $1.startTime } }
                if media == nil { media = active.first { $0.isProjectionMedia } }
            } else if chord == nil { chord = active.filter { !$0.isProjectionMedia }.max { $0.startTime < $1.startTime } }
        }
        var style = DAWRemoteTeleprompter.Style()
        style.textColor = settings.textColor; style.chordColor = settings.chordColor
        style.songColor = settings.songNameColor; style.queueColor = settings.queueNameColor
        style.clockColor = settings.clockColor; style.localClockColor = settings.localClockColor
        style.borderColor = settings.borderColor; style.textBoxColor = settings.textBoxColor; style.progressColor = settings.progressColor
        style.font = settings.fontFamily; style.chordFont = settings.chordFontFamily; style.textAlignment = settings.textAlignment
        style.textScale = settings.textScale; style.chordScale = settings.chordScale
        style.windowBorder = settings.windowBorderEnabled; style.textBox = settings.textBoxEnabled
        style.songEnabled = settings.songNameEnabled; style.queueEnabled = settings.queueNameEnabled
        style.clockEnabled = settings.clockEnabled; style.localClockEnabled = settings.localClockEnabled
        style.chordsEnabled = settings.chordsEnabled; style.progressEnabled = settings.progressEnabled
        style.clockPosition = settings.clockPosition; style.songPosition = settings.songNamePosition
        style.queuePosition = settings.queueNamePosition; style.chordPosition = settings.chordPosition; style.progressPosition = settings.progressPosition
        let progressClip = settings.progressMode == "chords" ? chord : lyric
        let progress = progressClip.map { min(1, max(0, (position - $0.startTime) / max(0.001, $0.duration))) } ?? 0
        let queueName = queued?.name ?? snapshot.project.songs.first { $0.id == snapshot.nextSongId || $0.id == transport.queue.songId }?.name ?? ""
        var result = DAWRemoteTeleprompter(index: index, text: settings.display(lyric?.text ?? ""), chords: settings.display(chord?.text ?? ""),
            song: settings.display(region?.name ?? song?.name ?? ""), queued: settings.display(queueName), progress: progress,
            style: style, preview: controller.previewActive, settings: settings)
        if controller.previewActive, let song {
            let setlist = snapshot.project.regionSetlist ?? RegionSetlist()
            let playlist = setlist.playlists.first { $0.id == setlist.selectedId && $0.songId == song.id }
            let lookup = Dictionary(uniqueKeysWithValues: song.parts.map { ($0.id, $0) })
            let regions = playlist.map { $0.regionIds.compactMap { lookup[$0] } } ?? song.parts.filter { $0.parentRegionID == nil }.sorted { $0.startTime < $1.startTime }
            let headers = Dictionary(grouping: (setlist.blocks ?? []).filter { $0.songId == song.id && $0.playlistId == playlist?.id }, by: \.beforeRegionId)
            var blocks = [DAWRemoteTeleprompter.Block(id: song.id, name: "", color: 0xffea00, rows: [])]
            for part in regions {
                for header in headers[part.id] ?? [] {
                    blocks.append(.init(id: header.id, name: settings.display(header.name), color: header.color, rows: []))
                }
                let last = blocks.count - 1
                blocks[last].rows.append(.init(id: part.id, name: settings.display(part.displayName),
                    color: part.id == region?.id ? settings.highlightColor : part.id == queued?.id ? settings.queueNameColor : part.color ?? blocks[last].color,
                    duration: max(0, part.endTime - part.startTime)))
            }
            blocks += (headers[nil] ?? []).map { .init(id: $0.id, name: settings.display($0.name), color: $0.color, rows: []) }
            result.blocks = Array(blocks.filter { !$0.name.isEmpty || !$0.rows.isEmpty }.dropFirst(controller.previewPage * 4).prefix(4))
        }
        if !controller.previewActive, let media, let file = media.audioFile, let directory,
           UTType(filenameExtension: URL(fileURLWithPath: file.path).pathExtension)?.conforms(to: .image) == true {
            result.imageID = DAWRemoteSession.shared.imageID(for: directory.appendingPathComponent(file.path), project: snapshot.project.id)
            result.mediaName = media.name
        }
        return result
    }
}
#else
@MainActor private struct NativeRemoteWorkspace: View {
    let state: DAWRemoteState
    let computerName: String
    let timer: RemoteLocalTimer
    let send: (DAWRemoteCommand) -> Void
    let exitRemote: () -> Void
    @State private var navigationOpen = false
    @State private var projectsOpen = false
    @State private var playlistPickerOpen = false
    private enum PrompterPanel: Int, Identifiable {
        case first = 1, second = 2
        var id: Int { rawValue }
    }
    @State private var prompterPanel: PrompterPanel?
    @State private var prompterFullscreen = false
    @State private var noticesOpen = false
    @State private var timerOpen = false
    @State private var confirmSave = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var keyboardVisible = false
    @State private var expandedRegions: Set<UUID> = []
    @StateObject private var trackScrolling = RemoteTrackScrollController()
    @AppStorage("jaras.remote.mixerHidden") private var mixerHidden = false
    @AppStorage("jaras.remote.trackWidth") private var savedTrackFraction = 0.30
    @AppStorage("jaras.remote.setlistWidth") private var savedSetlistFraction = 0.32
    @AppStorage("jaras.remote.teleprompterSetlistWidth") private var savedPrompterSetlistFraction = 0.30
    @AppStorage("jaras.remote.teleprompterSetlistHidden") private var prompterSetlistHidden = false
    @State private var livePrompterSetlistFraction: Double?
    @State private var prompterResizeStart: Double?
    @State private var livePanelWidths: DAWRemotePanelWidths?
    @State private var trackResizeStart: DAWRemotePanelWidths?
    @State private var setlistResizeStart: DAWRemotePanelWidths?
    private var panelWidths: DAWRemotePanelWidths {
        livePanelWidths ?? .init(track: mixerHidden ? 0 : savedTrackFraction, setlist: savedSetlistFraction)
    }
    private var mixerCollapsed: Bool { panelWidths.track == 0 }
    private var prompterSetlistFraction: Double {
        if let livePrompterSetlistFraction { return livePrompterSetlistFraction }
        guard !prompterSetlistHidden else { return 0 }
        return savedPrompterSetlistFraction.isFinite ? min(1, max(0, savedPrompterSetlistFraction)) : 0.30
    }
    private func persistPrompterSetlistFraction(_ fraction: Double) {
        let width = min(1, max(0, fraction))
        if width > 0, abs(savedPrompterSetlistFraction - width) > 0.0001 { savedPrompterSetlistFraction = width }
        if prompterSetlistHidden != (width == 0) { prompterSetlistHidden = width == 0 }
    }
    private func finishPrompterResize() {
        if let livePrompterSetlistFraction { persistPrompterSetlistFraction(livePrompterSetlistFraction) }
        livePrompterSetlistFraction = nil; prompterResizeStart = nil
    }
    private func togglePrompterSetlist() {
        let restore = savedPrompterSetlistFraction.isFinite && savedPrompterSetlistFraction > 0 ? savedPrompterSetlistFraction : 0.30
        persistPrompterSetlistFraction(prompterSetlistFraction == 0 ? restore : 0)
        livePrompterSetlistFraction = nil; prompterResizeStart = nil
    }
    private func showPrompter(_ panel: PrompterPanel?) {
        finishPanelResize(); finishPrompterResize()
        if panel == nil { prompterFullscreen = false }
        prompterPanel = panel
    }
    private func togglePrompterFullscreen() {
        guard prompterPanel != nil else { return }
        searchFocused = false
        finishPrompterResize()
        prompterFullscreen.toggle()
    }
    private func persistPanelWidths(_ widths: DAWRemotePanelWidths) {
        // A zero mixer width retains its previous nonzero size for the sidebar
        // toggle. The existing hidden preference records the collapsed state.
        if widths.track > 0, abs(savedTrackFraction - widths.track) > 0.0001 { savedTrackFraction = widths.track }
        if abs(savedSetlistFraction - widths.setlist) > 0.0001 { savedSetlistFraction = widths.setlist }
        if mixerHidden != (widths.track == 0) { mixerHidden = widths.track == 0 }
    }
    private func finishPanelResize() {
        if let livePanelWidths { persistPanelWidths(livePanelWidths) }
        livePanelWidths = nil; trackResizeStart = nil; setlistResizeStart = nil
    }
    @State private var scrubPosition: Double?
    @State private var pendingSeek: Double?
    @State private var seekSentAt = Date.distantPast
    private var displayedPosition: Double {
        if !state.playing, let scrubPosition { return scrubPosition }
        if !state.playing, let pendingSeek, Date().timeIntervalSince(seekSentAt) < 2,
           abs(state.position - pendingSeek) > 0.1 { return pendingSeek }
        return state.position
    }
    private var selectedTimelineRegion: DAWRemoteState.Region? {
        let id = state.playing ? state.currentRegion : (state.focusedRegion ?? state.currentRegion)
        return (state.timelineRegions + state.regions).first { $0.id == id }
    }
    private var gridRegion: DAWRemoteState.Region? {
        state.timelineRegions.first { $0.id == state.gridRegion } ?? selectedTimelineRegion
    }
    private var visibleTracks: [DAWRemoteState.Track] { DAWRemoteItemLayout.tracks(state.tracks, within: gridRegion) }
    private var drawerRegion: DAWRemoteState.Region? { DAWRemoteSetlistPresentation.drawer(in: state) }
    private var drawerExpanded: Bool { drawerRegion.map { expandedRegions.contains($0.id) } ?? false }
    private func action(_ action: DAWRemoteCommand.Action, target: UUID? = nil, value: Double = 0) {
        send(.init(project: state.project, song: state.song, action: action, target: target, value: value))
    }
    private func updatePanelSubscription() {
        guard state.timer != nil else { return }
        action(.remotePanel, value: Double(prompterPanel?.rawValue ?? (noticesOpen ? 3 : 0)))
    }
    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - 37)
            let panelSpace = max(1, contentWidth - 20)
            HStack(spacing: 1) {
                VStack(spacing: 0) {
                    Button { withAnimation(.easeOut(duration: 0.16)) { navigationOpen.toggle() } } label: {
                        Image(systemName: "line.3.horizontal").font(.system(size: 17, weight: .semibold))
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Abrir barra lateral")
                    Button { withAnimation(.easeOut(duration: 0.16)) {
                        let current = panelWidths
                        let restored = savedTrackFraction.isFinite && savedTrackFraction > 0 ? savedTrackFraction : 0.30
                        let expand = prompterPanel != nil || mixerCollapsed
                        showPrompter(nil)
                        persistPanelWidths(.init(track: expand ? restored : 0, setlist: current.setlist))
                        livePanelWidths = nil; trackResizeStart = nil; setlistResizeStart = nil
                    } } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(prompterPanel != nil || mixerCollapsed ? Color(hex: 0xc44545) : JarasTheme.green)
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(prompterPanel != nil || mixerCollapsed ? "Expandir Track-Mixer" : "Recolher Track-Mixer")
                        .accessibilityValue(prompterPanel != nil || mixerCollapsed ? "Hidden" : "Shown")
                    Button { showPrompter(prompterPanel == .first ? nil : .first) } label: {
                        Text(verbatim: "TP1").font(.system(size: 10, weight: .bold)).frame(width: 36, height: 36)
                    }.buttonStyle(.plain).foregroundStyle(prompterPanel == .first ? JarasTheme.green : Color(hex: 0xff5555))
                        .accessibilityLabel("Teleprompter 1").accessibilityValue(prompterPanel == .first ? "On" : "Off")
                    Button { showPrompter(prompterPanel == .second ? nil : .second) } label: {
                        Text(verbatim: "TP2").font(.system(size: 10, weight: .bold)).frame(width: 36, height: 36)
                    }.buttonStyle(.plain).foregroundStyle(prompterPanel == .second ? JarasTheme.green : Color(hex: 0xff5555))
                        .accessibilityLabel("Teleprompter 2").accessibilityValue(prompterPanel == .second ? "On" : "Off")
                    Button { noticesOpen = true } label: {
                        Image(systemName: "text.bubble").font(.system(size: 15, weight: .medium)).frame(width: 36, height: 36)
                    }.buttonStyle(.plain).foregroundStyle(JarasTheme.yellow).accessibilityLabel("Notices")
                        .popover(isPresented: $noticesOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .leading) {
                            RemoteNativeNoticesView(close: { noticesOpen = false }, managesSubscription: false)
                                .frame(width: 440, height: 430).preferredColorScheme(.dark)
                        }
                    Button { timerOpen = true } label: {
                        Image(systemName: "clock").font(.system(size: 16, weight: .medium)).frame(width: 36, height: 36)
                    }.buttonStyle(.plain).foregroundStyle(Color(hex: 0x409cff)).accessibilityLabel("Timer")
                        .popover(isPresented: $timerOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .leading) {
                            VStack(spacing: 0) {
                                RemoteNativeTimerView(timer: timer, send: {
                                    guard state.timer != nil else { return }
                                    send(.init(id: $2, project: state.project, song: state.song, action: $0, value: $1))
                                }, close: { timerOpen = false })
                                if state.timer == nil {
                                    Text("Atualize o Jaras no Mac para sincronizar o cronômetro.")
                                        .font(.caption).foregroundStyle(JarasTheme.secondary).padding(12).frame(width: 300)
                                }
                            }.background(JarasTheme.panel).preferredColorScheme(.dark)
                        }
                    Spacer(minLength: 0)
                }.padding(.top, 6).frame(width: 36).background(JarasTheme.panel)
                VStack(spacing: 1) {
                    if !prompterFullscreen { transportBar }
                    HStack(spacing: 0) {
                        if let panel = prompterPanel {
                            let space = max(1, contentWidth - 10)
                            RemoteNativeTeleprompterPanel(index: panel.rawValue, timer: timer,
                                fullscreen: prompterFullscreen, toggleFullscreen: togglePrompterFullscreen,
                                toggleSetlist: togglePrompterSetlist, setlistVisible: prompterSetlistFraction > 0, managesSubscription: false)
                                .frame(width: prompterFullscreen ? contentWidth : space * (1 - prompterSetlistFraction)).clipped()
                                .allowsHitTesting(prompterFullscreen || prompterSetlistFraction < 1)
                                .accessibilityHidden(!prompterFullscreen && prompterSetlistFraction == 1)
                            resizeHandle(label: "Ajustar largura do Setlist", changed: { translation in
                                let start = prompterResizeStart ?? prompterSetlistFraction
                                if prompterResizeStart == nil { prompterResizeStart = start }
                                let width = min(1, max(0, start - translation / space))
                                if prompterSetlistFraction != width { livePrompterSetlistFraction = width }
                            }, ended: finishPrompterResize)
                                .frame(width: prompterFullscreen ? 0 : 10).clipped()
                                .allowsHitTesting(!prompterFullscreen).accessibilityHidden(prompterFullscreen)
                        } else {
                            trackMixer.frame(width: panelSpace * panelWidths.track).clipped()
                                .allowsHitTesting(!mixerCollapsed).accessibilityHidden(mixerCollapsed)
                            resizeHandle(label: "Ajustar largura do Track-Mixer", changed: { translation in
                                let start = trackResizeStart ?? panelWidths
                                if trackResizeStart == nil { trackResizeStart = start }
                                let widths = start.resizingTrack(by: translation / panelSpace)
                                if panelWidths != widths { livePanelWidths = widths }
                            }, ended: finishPanelResize)
                        RemoteNativeTimeline(state: state, tracks: visibleTracks, scrolling: trackScrolling, region: gridRegion, position: displayedPosition,
                            control: { action($0, target: $1, value: $2) },
                            preview: { scrubPosition = $0 }, seek: { position in
                                scrubPosition = nil
                                guard !state.playing, let region = selectedTimelineRegion else { return }
                                pendingSeek = position; seekSentAt = Date()
                                action(.seek, target: region.id, value: position)
                            }).frame(width: panelSpace * panelWidths.grid).clipped()
                                .allowsHitTesting(panelWidths.grid > 0).accessibilityHidden(panelWidths.grid == 0)
                        resizeHandle(label: "Ajustar largura do Setlist", changed: { translation in
                            let start = setlistResizeStart ?? panelWidths
                            if setlistResizeStart == nil { setlistResizeStart = start }
                            let widths = start.resizingSetlist(by: translation / panelSpace)
                            if panelWidths != widths { livePanelWidths = widths }
                        }, ended: finishPanelResize)
                        }
                        let setlistWidth = prompterFullscreen ? 0 : prompterPanel == nil ? panelSpace * panelWidths.setlist : max(1, contentWidth - 10) * prompterSetlistFraction
                        setlist.frame(width: setlistWidth).clipped()
                            .allowsHitTesting(setlistWidth > 0).accessibilityHidden(setlistWidth == 0)
                    }
                    if !keyboardVisible && !prompterFullscreen { footer }


                }.frame(width: contentWidth).disabled(state.projects?.busy == true)
            }
        }.background(JarasTheme.line)
            .overlay(alignment: .topLeading) {
                if navigationOpen {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.24).contentShape(Rectangle()).onTapGesture { navigationOpen = false }
                        SidebarView(close: { navigationOpen = false }, openProjects: { projectsOpen = true }, exit: exitRemote)
                            .frame(width: 210).frame(maxHeight: .infinity)
                            .shadow(color: .black.opacity(0.3), radius: 10, x: 4)
                    }
                }
            }
            .sheet(isPresented: $projectsOpen) {
                NativeRemoteProjectsView(state: state, computerName: computerName,
                    open: { action(.openRecentProject, target: $0) }, close: { projectsOpen = false })
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
            #endif
            .onAppear(perform: updatePanelSubscription)
            .onDisappear { if state.timer != nil { action(.remotePanel, value: 0) } }
            .onChange(of: prompterPanel) { _ in updatePanelSubscription() }
            .onChange(of: noticesOpen) { _ in updatePanelSubscription() }
            .onChange(of: state.project) { _ in expandedRegions.removeAll(); playlistPickerOpen = false; updatePanelSubscription() }
            .onChange(of: state.song) { _ in expandedRegions.removeAll(); scrubPosition = nil; pendingSeek = nil }
            .onChange(of: state.playing) { _ in scrubPosition = nil; pendingSeek = nil }
            .onChange(of: state.focusedRegion) { _ in scrubPosition = nil; pendingSeek = nil }
            .onChange(of: state.position) { position in
                if let pendingSeek, abs(position - pendingSeek) <= 0.1 { self.pendingSeek = nil }
            }
            .alert("Do you want to save this project?", isPresented: $confirmSave) {
                Button("Cancel", role: .cancel) {}
                Button("Save") { action(.save) }
            }
    }
    private var projectFooterText: String {
        let iso = ISO8601DateFormatter()
        let timestamp = state.projectSavedAt ?? ""
        var date = iso.date(from: timestamp)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = iso.date(from: timestamp)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return "Sessão - " + state.projectName + " - " + (date.map { formatter.string(from: $0) } ?? "—")
    }
    private var footer: some View {
        GeometryReader { geometry in
            let centerWidth = min(300, geometry.size.width * 0.30)
            let sideWidth = (geometry.size.width - centerWidth) / 2
            HStack(spacing: 0) {
                Text(verbatim: projectFooterText).lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading).frame(height: 21)
                    .background(JarasTheme.display).cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(JarasTheme.line))
                    .padding(.trailing, 8).frame(width: sideWidth)
                    .accessibilityLabel("Nome do projeto e data de salvamento")
                Color.clear.frame(width: sideWidth)
                Text(verbatim: state.footerInformation ?? "").font(.system(size: 10, weight: .bold)).lineLimit(1)
                    .foregroundStyle(JarasTheme.green).frame(width: centerWidth, height: 21)
                    .background(JarasTheme.display).cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(JarasTheme.line))
                    .accessibilityLabel("Informações")
            }.font(.system(size: 9, weight: .medium, design: .monospaced))
        }.padding(.horizontal, 8).padding(.vertical, 3).frame(height: 27).background(JarasTheme.panel)
    }
    private func resizeHandle(label: String, changed: @escaping (Double) -> Void, ended: @escaping () -> Void) -> some View {
        ZStack {
            JarasTheme.panel
            RoundedRectangle(cornerRadius: 2).fill(JarasTheme.secondary).frame(width: 3, height: 36)
        }.frame(width: 10).contentShape(Rectangle())
            // The divider moves as the panel grows. Local coordinates would
            // change the translation again during layout, feeding the width
            // update back into the gesture even with a stationary finger.
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { changed(Double($0.translation.width)) }.onEnded { _ in ended() })
            .accessibilityLabel(label)
    }
    private var masterStrip: some View {
        VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Button { action(.masterMono) } label: { Text(state.masterMono ? "Mono" : "Stereo") }
                        .font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).frame(height: 24)
                        .foregroundStyle(state.masterMono ? JarasTheme.green : JarasTheme.text)
                        .background(Color.white.opacity(0.12)).cornerRadius(3).buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button { action(.mute) } label: { Text(verbatim: "M") }
                        .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: state.masterMute ? .red : nil))
                    Button { action(.solo) } label: { Text(verbatim: "S") }
                        .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: state.masterSolo ? JarasTheme.yellow : nil))
                }.frame(height: 24)
                Text(verbatim: "Master").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(remoteColor(state.masterNameColor ?? 0xffffff))
                    .frame(maxWidth: .infinity)
                HStack(spacing: 3) {
                    Text(remoteDecibelText(state.masterVolume)).font(.system(size: 10, weight: .semibold, design: .monospaced)).frame(width: 36, alignment: .leading)
                    RemoteNativeSlider(value: DAWRemoteFaderScale.decibels(state.masterVolume), range: -60...12, height: 20) { action(.volume, value: DAWRemoteFaderScale.gain($0)) }
                        .accessibilityLabel("Master volume")
                }
            }.padding(.horizontal, 6).padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .frame(height: RemoteNativeGridMetrics.rulerAreaHeight)
                .background(remoteColor(state.masterColor ?? 0x414141).opacity(0.5)).cornerRadius(6)
    }
    private var transportBar: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Text(verbatim: selectedTimelineRegion?.name ?? state.songName)
                        .foregroundStyle(state.playing ? JarasTheme.green : JarasTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).frame(height: 25).background(JarasTheme.display).cornerRadius(5)
                        .accessibilityLabel("Música selecionada")
                    Text(verbatim: state.upcomingName ?? "—")
                        .foregroundStyle(JarasTheme.yellow).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).frame(height: 25).background(JarasTheme.display).cornerRadius(5)
                        .accessibilityLabel(state.upcomingKind ?? "Queued song")
                    Text(verbatim: timeText).monospacedDigit().frame(width: 82, height: 25)
                        .background(JarasTheme.display).cornerRadius(5).accessibilityLabel("Tempo da agulha")
                }.font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Button { action(state.playing || state.paused ? .stop : .play) } label: {
                        Label(state.playing || state.paused ? "Stop" : "Play", systemImage: state.playing || state.paused ? "stop.fill" : "play.fill")
                    }.buttonStyle(TransportButtonStyle(color: JarasTheme.green, active: state.playing, fontSize: 12, width: 72, height: 28))
                    Button { action(state.paused ? .play : .pause) } label: {
                        Label(state.paused ? "Play" : "Pause", systemImage: state.paused ? "play.fill" : "pause.fill")
                    }.buttonStyle(TransportButtonStyle(color: JarasTheme.yellow, active: state.paused, fontSize: 12, width: 72, height: 28))
                        .disabled(!state.playing && !state.paused)
                    smallButton("Sub Play", active: state.subPlaying) { action(state.subPlaying ? .subStop : .subPlay) }.disabled(!state.playing)
                    Button { action(.toggleLoop) } label: {
                        Label("Repeat", systemImage: "repeat")
                    }.buttonStyle(TransportButtonStyle(color: state.loop ? JarasTheme.yellow : .red, active: state.loop, fontSize: 12, width: 72, height: 28))
                        .modifier(JarasBlink(active: state.loop, interval: 0.55, lowOpacity: 0.45))
                    bpmControl
                    tunerControl
                }
            }.frame(maxWidth: .infinity)
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    topPrompterButton(.first, title: "TP1")
                    topPrompterButton(.second, title: "TP2")
                }.frame(height: 25)
                RemoteNativeTimerView(timer: timer, send: {
                    guard state.timer != nil else { return }
                    send(.init(id: $2, project: state.project, song: state.song, action: $0, value: $1))
                }, close: {}, compact: true)
            }.frame(width: 176)
            VStack(spacing: 5) {
            Button { confirmSave = true } label: {
                Label(state.saving ? "Salvando…" : state.pendingSave ? "Save" : "Salvo", systemImage: state.pendingSave ? "square.and.arrow.down" : "checkmark")
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: 72, height: 28)
                    .foregroundStyle(state.pendingSave ? JarasTheme.green : JarasTheme.secondary)
                    .background(RoundedRectangle(cornerRadius: 6).fill(state.pendingSave ? JarasTheme.green.opacity(0.16) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(state.pendingSave ? JarasTheme.green.opacity(0.7) : JarasTheme.line))
            }.buttonStyle(.plain).disabled(!state.pendingSave || state.saving)
                Button {
                    guard let parent = drawerRegion?.id else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        if !expandedRegions.insert(parent).inserted { expandedRegions.remove(parent) }
                    }
                } label: {
                    Image(systemName: drawerExpanded ? "chevron.up" : "chevron.down")
                }.buttonStyle(TransportButtonStyle(color: JarasTheme.panel, fontSize: 13, width: 72, height: 28))
                    .foregroundStyle(JarasTheme.green).disabled(drawerRegion == nil)
                    .opacity(drawerRegion == nil ? 0.45 : 1)
                    .accessibilityLabel(drawerExpanded ? "Fechar gaveta da região selecionada" : "Abrir gaveta da região selecionada")
                    .accessibilityValue(drawerExpanded ? "Expanded" : "Collapsed")
            }
        }.padding(6).frame(height: 82, alignment: .top).background(JarasTheme.panel)
    }
    private func topPrompterButton(_ panel: PrompterPanel, title: String) -> some View {
        Button { showPrompter(prompterPanel == panel ? nil : panel) } label: {
            Text(verbatim: title).font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 25)
                .background(JarasTheme.display).cornerRadius(5)
        }.buttonStyle(.plain).foregroundStyle(prompterPanel == panel ? JarasTheme.green : Color(hex: 0xff5555))
            .accessibilityLabel("Teleprompter \(panel.rawValue), controles superiores")
            .accessibilityValue(prompterPanel == panel ? "On" : "Off")
    }
    private var tunerControl: some View {
                HStack(spacing: 6) {
                    Button { action(.pitch, target: state.pitchRegion, value: Double((state.pitchSemitones ?? 0) - 1)) } label: { Image(systemName: "minus").frame(width: 28, height: 32) }
                        .disabled(state.pitchRegion == nil || (state.pitchSemitones ?? 0) <= -6)
                    VStack(spacing: 0) {
                        Text(verbatim: "Tuner").font(.system(size: 10))
                        Text(String(format: "%+dst", state.pitchSemitones ?? 0)).monospacedDigit()
                    }.frame(minWidth: 70, maxWidth: .infinity)
                    Button { action(.pitch, target: state.pitchRegion, value: Double((state.pitchSemitones ?? 0) + 1)) } label: { Image(systemName: "plus").frame(width: 28, height: 32) }
                        .disabled(state.pitchRegion == nil || (state.pitchSemitones ?? 0) >= 6)
                }.font(.system(size: 14, weight: .semibold)).buttonStyle(.plain).foregroundStyle(JarasTheme.green)
                .padding(.horizontal, 4).frame(minWidth: 134, maxWidth: .infinity, minHeight: 32).background(JarasTheme.display).cornerRadius(5)
    }
    private var bpmControl: some View {
        HStack(spacing: 2) {
            Button { action(.tempo, value: max(60, state.bpm - 1)) } label: {
                Image(systemName: "minus").frame(width: 28, height: 32)
            }.accessibilityLabel("Diminuir BPM")
            Text(String(format: "%.0f BPM", state.bpm)).monospacedDigit().frame(minWidth: 70, maxWidth: .infinity)
            Button { action(.tempo, value: min(300, state.bpm + 1)) } label: {
                Image(systemName: "plus").frame(width: 28, height: 32)
            }.accessibilityLabel("Aumentar BPM")
        }.font(.system(size: 14, weight: .semibold)).buttonStyle(.plain)
            .frame(minWidth: 134, maxWidth: .infinity, minHeight: 32)
            .foregroundStyle(JarasTheme.green).background(JarasTheme.display).cornerRadius(5)
    }
    private var timeText: String {
        let seconds = max(0, Int(displayedPosition))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    private func smallButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(verbatim: title) }
            .buttonStyle(TransportButtonStyle(color: JarasTheme.green, active: active, fontSize: 12, width: 72, height: 28))
    }
    private var trackMixer: some View {
        VStack(spacing: 1) {
            // Match the grid's region, marker and time lanes so both lists
            // start at the same screen Y and have identical scroll limits.
            masterStrip
            HStack(spacing: 1) {
                RemoteTrackScrollRail(controller: trackScrolling).frame(width: 28)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { number, track in
                            RemoteNativeMixerRow(track: track, number: number + 1) { command, value in
                                action(command, target: track.id, value: value)
                            }.frame(height: DAWRemoteItemLayout.rowHeight(track))
                        }
                    }
                    #if os(iOS)
                    .background(RemoteTrackScrollProbe(controller: trackScrolling))
                    #endif
                }.background(JarasTheme.background)
            }
        }
    }
    private var setlist: some View {
        VStack(spacing: 8) {
            Text(verbatim: "Setlist").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Button { playlistPickerOpen = true } label: {
                    Image(systemName: "list.bullet").foregroundStyle(JarasTheme.green).frame(width: 30, height: 28)
                }.buttonStyle(.plain).accessibilityLabel("Selecionar playlist")
                    .popover(isPresented: $playlistPickerOpen, arrowEdge: .top) {
                        RemoteNativePlaylistPicker(playlists: state.playlists ?? [], selected: state.selectedPlaylist,
                            choose: { id in action(.selectPlaylist, target: id); playlistPickerOpen = false },
                            close: { playlistPickerOpen = false }).equatable()
                    }
                TextField("Pesquisar músicas", text: $search).textFieldStyle(.roundedBorder).focused($searchFocused)
                Button { action(.toggleRegionAuto) } label: {
                    Text(verbatim: "AUTO").font(.system(size: 9, weight: .bold)).frame(width: 34, height: 26)
                        .foregroundStyle(state.regionAuto == true ? Color.black : JarasTheme.secondary)
                        .background(state.regionAuto == true ? JarasTheme.green : JarasTheme.panel).cornerRadius(4)
                }.buttonStyle(.plain).accessibilityLabel("AUTO").accessibilityValue(state.regionAuto == true ? "On" : "Off")
            }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if state.regions.isEmpty {
                            ForEach(state.songs.filter { search.isEmpty || $0.name.localizedStandardContains(search) }) { song in
                                Button { action(.selectSong, target: song.id) } label: {
                                    setlistLabel(song.name, selected: song.id == state.song, active: state.playing && song.id == state.song, queued: false, color: JarasTheme.panel)
                                }.buttonStyle(.plain)
                            }
                        } else {
                            ForEach(DAWRemoteSetlistPresentation.rows(in: state, expanded: expandedRegions, query: search)) { row in
                                let region = row.region
                                Button { action(.selectRegion, target: region.id) } label: {
                                    setlistLabel(region.name, number: row.number, selected: region.id == state.focusedRegion,
                                        active: state.playing && region.id == state.currentRegion, queued: state.playing && region.id == state.queuedRegion,
                                        color: remoteColor(region.color), nameColor: remoteColor(region.nameColor ?? (row.child ? 0xffeb3b : 0xffffff)),
                                        duration: max(0, Int(ceil(region.end - (state.playing && region.id == state.currentRegion ? state.position : region.start)))),
                                        progress: min(1, max(0, (state.position - region.start) / max(0.001, region.end - region.start))),
                                        queueProgress: min(1, max(0, ((state.playbackEnd ?? state.position) - state.position) / max(0.001, (state.playbackEnd ?? state.position) - (state.queueStartedAt ?? state.position)))))
                                }.buttonStyle(.plain).padding(.leading, row.child ? 20 : 0).id(row.id)
                            }
                        }
                    }
                }.onChange(of: expandedRegions) { expanded in
                    if let parent = drawerRegion?.id, expanded.contains(parent) {
                        withAnimation(.easeOut(duration: 0.16)) { scroll.scrollTo(parent, anchor: .top) }
                    }
                }
            }
        }.padding(10).background(JarasTheme.background)
    }
    private func setlistLabel(_ title: String, number: Int? = nil, selected: Bool = false, active: Bool, queued: Bool, color: Color, nameColor: Color = JarasTheme.text, duration: Int? = nil, progress: Double = 0, queueProgress: Double = 0) -> some View {
        let fontStyle = state.setlistFontStyle ?? 0
        return HStack(spacing: 8) {
            Rectangle().fill(active ? Color.red : queued ? (state.prepareOnly == true ? JarasTheme.green : .orange) : color).frame(width: 3)
            if let number { Text(String(format: "%02d", number)).font(.system(size: 10, design: .monospaced)).foregroundStyle(JarasTheme.secondary) }
            Text(verbatim: title)
                .font(fontStyle == 2 ? .system(size: 13, weight: .bold).italic() : .system(size: 13, weight: fontStyle == 0 ? .regular : .bold))
                .foregroundStyle(nameColor).lineLimit(2)
            Spacer(minLength: 0)
            if let duration { Text(String(format: "%dm %02ds", duration / 60, duration % 60)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(JarasTheme.text) }
            if active { Image(systemName: "play.fill").foregroundStyle(JarasTheme.green) }
            if queued { Image(systemName: "arrow.right").foregroundStyle(JarasTheme.yellow) }
        }.padding(.horizontal, 8).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 38)
            .background {
                if active {
                    LinearGradient(colors: [Color(hex: 0x8b2026), Color(hex: 0x4c171c)], startPoint: .leading, endPoint: .trailing)
                } else if queued {
                    LinearGradient(colors: state.prepareOnly == true ? [Color(hex: 0x19633a), Color(hex: 0x123b27)] : [Color(hex: 0xa84b13), Color(hex: 0x572808)], startPoint: .leading, endPoint: .trailing)
                } else if selected {
                    LinearGradient(colors: [Color(hex: 0x2457a9), Color(hex: 0x152b58)], startPoint: .leading, endPoint: .trailing)
                } else { JarasTheme.panel }
            }.cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? JarasTheme.green : .clear, lineWidth: 1.5))
            .overlay(alignment: .bottomLeading) {
                if active || queued {
                    GeometryReader { geometry in
                        Rectangle().fill(active ? JarasTheme.green : JarasTheme.yellow)
                            .frame(width: geometry.size.width * (active ? progress : queueProgress), height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }.allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 5))
    }

}
/// The center grid renders native clip geometry from the Mac state.
private enum RemoteNativeGridMetrics {
    static let regionHeight: CGFloat = 24
    static let markerHeight: CGFloat = 20
    static let timeHeight: CGFloat = 28
    static let rulerAreaHeight = regionHeight + markerHeight + timeHeight + 2
}
private struct RemoteNativeTimeline: View {
    let state: DAWRemoteState
    let tracks: [DAWRemoteState.Track]
    let scrolling: RemoteTrackScrollController
    let region: DAWRemoteState.Region?
    let position: Double
    let control: (DAWRemoteCommand.Action, UUID, Double) -> Void
    let preview: (Double) -> Void
    let seek: (Double) -> Void
    private var start: Double { region?.start ?? 0 }
    private var end: Double { region?.end ?? start }
    private var span: Double { max(0.001, end - start) }
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            VStack(spacing: 1) {
                regionLane(width: width)
                markerLane(width: width)
                ruler(width: width)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        ForEach(tracks) { track in
                            timelineRow(track, width: width).frame(height: DAWRemoteItemLayout.rowHeight(track))
                        }
                    }
                    #if os(iOS)
                    .background(RemoteTrackScrollProbe(controller: scrolling, isGrid: true))
                    #endif
                }
            }
        }.background(JarasTheme.background)
    }
    private func ruler(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            JarasTheme.display
            Canvas { context, size in
                let step = max(1, ceil(span / max(1, Double(size.width / 70))))
                for index in 0...Int(ceil(span / step)) {
                    let seconds = Double(index) * step, x = seconds / span * size.width
                    var tick = Path(); tick.move(to: CGPoint(x: x, y: 20)); tick.addLine(to: CGPoint(x: x, y: 28))
                    context.stroke(tick, with: .color(JarasTheme.secondary), lineWidth: 1)
                    let absolute = Int(start + seconds)
                    context.draw(Text(String(format: "%02d:%02d", absolute / 60, absolute % 60)).font(.system(size: 9)).foregroundColor(JarasTheme.secondary), at: CGPoint(x: x + 3, y: 10), anchor: .leading)
                }
            }
            cursor(width: width)
        }.frame(height: RemoteNativeGridMetrics.timeHeight).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard !state.playing, region != nil else { return }
                    preview(start + min(1, max(0, gesture.location.x / width)) * span)
                }
                .onEnded { gesture in
                    guard !state.playing, region != nil else { return }
                    seek(start + min(1, max(0, gesture.location.x / width)) * span)
                })
            .accessibilityLabel("Régua de tempo: arraste com o transporte parado")
    }
    private func regionLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            JarasTheme.display
            if let region {
                HStack {
                    Text(verbatim: region.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                }.foregroundStyle(remoteColor(region.nameColor ?? 0xffffff)).padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(remoteColor(region.color).opacity(0.6))
            }
            cursor(width: width)
        }.frame(height: RemoteNativeGridMetrics.regionHeight).clipped().accessibilityLabel("Faixa da região " + (region?.name ?? ""))
    }
    private func markerLane(width: CGFloat) -> some View {
        let markers = (state.markers ?? []).filter { $0.position >= start && $0.position <= end }.sorted { $0.position < $1.position }
        return ZStack(alignment: .leading) {
            JarasTheme.display
            Canvas { context, size in
                for (index, marker) in markers.enumerated() {
                    let x = (marker.position - start) / span * size.width
                    let nextX = index + 1 < markers.count ? (markers[index + 1].position - start) / span * size.width : size.width
                    let flagWidth = min(110, max(2, min(nextX - x - 2, size.width - x)))
                    let rect = CGRect(x: x, y: 1, width: flagWidth, height: size.height - 2)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(remoteColor(marker.color)))
                    if flagWidth > 15 {
                        context.draw(Text(verbatim: marker.name).font(.system(size: 9, weight: .semibold)).foregroundColor(.black), in: rect.insetBy(dx: 3, dy: 2))
                    }
                }
            }
            cursor(width: width)
        }.frame(height: RemoteNativeGridMetrics.markerHeight).clipped().accessibilityLabel("Marcadores da música")
    }
    private func cursor(width: CGFloat) -> some View {
        Rectangle().fill(JarasTheme.yellow).frame(width: 2)
            .offset(x: min(width - 2, max(0, (position - start) / span * width)))
            .allowsHitTesting(false)
    }
    private func timelineRow(_ track: DAWRemoteState.Track, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            JarasTheme.mixer.opacity(0.5)
            Canvas { context, size in
                var lines = Path()
                for index in 0...4 {
                    let x = Double(index) / 4 * size.width
                    lines.move(to: CGPoint(x: x, y: 0)); lines.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(lines, with: .color(JarasTheme.line), lineWidth: 1)
            }.allowsHitTesting(false)
            ForEach(track.clips.filter { region != nil && $0.start < end && $0.start + $0.duration > start }) { clip in
                let left = max(start, clip.start), right = min(end, clip.start + clip.duration)
                let itemWidth = max(1, (right - left) / span * width)
                RemoteNativeGridItem(clip: clip, color: track.color, nameColor: track.nameColor ?? 0xffffff,
                    scrolling: scrolling,
                    sourceFraction: (left - clip.start) / max(0.001, clip.duration),
                    visibleFraction: (right - left) / max(0.001, clip.duration),
                    mute: { control(.clipMute, clip.id, 0) },
                    setGain: { control(.clipGain, clip.id, $0) })
                    .frame(width: itemWidth, height: DAWRemoteItemLayout.laneHeight(track))
                    .offset(x: (left - start) / span * width, y: Double(clip.lane ?? 0) * DAWRemoteItemLayout.laneHeight(track))
            }
            cursor(width: width)
        }.frame(width: width, alignment: .leading).clipped().accessibilityLabel(track.name + ", clipes")
    }
}
private struct RemoteNativeGridItem: View {
    let clip: DAWRemoteState.Clip
    let color: UInt32
    let nameColor: UInt32
    let scrolling: RemoteTrackScrollController
    let sourceFraction: Double
    let visibleFraction: Double
    let mute: () -> Void
    let setGain: (Double) -> Void
    @State private var editorOpen = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: mute) { Text(verbatim: "M").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).foregroundStyle(clip.muted == true ? Color.black : Color.white)
                    .background(clip.muted == true ? Color.red : Color.black.opacity(0.28)).cornerRadius(2)
                    .accessibilityLabel("Mute do item " + clip.name)
                Text(verbatim: clip.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(remoteColor(nameColor)).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 3).frame(height: 28)
            Canvas { context, size in
                var wave = Path()
                let seed = clip.id.uuidString.utf8.reduce(0) { ($0 + Int($1)) % 997 }
                let count = max(1, Int(size.width / 3))
                for index in 0..<count {
                    let phase = (sourceFraction + Double(index) / Double(count) * visibleFraction) * 300 + Double(seed)
                    let amplitude = 0.12 + 0.78 * abs(sin(phase * 0.37) * cos(phase * 0.13))
                    let height = size.height * amplitude
                    wave.addRect(CGRect(x: CGFloat(index) * 3, y: (size.height - height) / 2, width: 1.5, height: height))
                }
                context.fill(wave, with: .color(clip.muted == true ? .gray : remoteColor(nameColor).opacity(0.75)))
            }.allowsHitTesting(false)
        }.background(remoteColor(color).opacity(clip.muted == true ? 0.25 : 0.60)).cornerRadius(3)
            .background(RemoteGridItemHoldProbe(controller: scrolling, hold: { editorOpen = true }))
            .popover(isPresented: $editorOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                RemoteNativeItemEditor(clip: clip, color: color, setGain: setGain, mute: mute, close: { editorOpen = false })
                    .preferredColorScheme(.dark)
            }
            .accessibilityLabel(clip.name).accessibilityAction(named: "Editar item") { editorOpen = true }
    }
}
/// A compact inspector anchored to the item, with the same fader and mute
/// behavior as the grid. Its stable item identity survives bridge updates.
private struct RemoteNativeItemEditor: View {
    let clip: DAWRemoteState.Clip
    let color: UInt32
    let setGain: (Double) -> Void
    let mute: () -> Void
    let close: () -> Void
    private var decibels: Double { clip.gain == 0 ? -60 : min(24, max(-59.9, 20 * log10(max(0.000001, clip.gain ?? 1)))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(remoteColor(color)).frame(width: 3, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Item volume").font(.system(size: 10, weight: .medium)).foregroundStyle(JarasTheme.secondary)
                    Text(verbatim: clip.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28).background(JarasTheme.display).cornerRadius(5)
                }.buttonStyle(.plain).foregroundStyle(JarasTheme.secondary).accessibilityLabel("Close")
            }
            HStack(spacing: 10) {
                Text(verbatim: (clip.gain == 0 ? "−∞" : String(format: "%+.1f", decibels)) + " dB")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(JarasTheme.green).frame(width: 67, height: 34)
                    .background(JarasTheme.display).cornerRadius(5)
                RemoteNativeSlider(value: decibels, range: -60...24, height: 36) {
                    setGain($0 <= -60 ? 0 : pow(10, $0 / 20))
                }.accessibilityLabel("Volume do item " + clip.name)
                Button(action: mute) {
                    Text(verbatim: "M").font(.system(size: 13, weight: .bold)).frame(width: 38, height: 34)
                        .foregroundStyle(clip.muted == true ? Color.white : JarasTheme.text)
                        .background(clip.muted == true ? Color.red.opacity(0.8) : JarasTheme.display).cornerRadius(5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(clip.muted == true ? Color.red : JarasTheme.line))
                }.buttonStyle(.plain).accessibilityLabel("Mute do item " + clip.name)
            }
        }.padding(14).frame(width: 330).fixedSize(horizontal: false, vertical: true)
            .background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
    }
}
private func remoteColor(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
}
/// Native rectangular fader with desktop travel and a local thumb during touch.
private struct RemoteNativeSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var height: CGFloat = 28
    var linked = false
    let change: (Double) -> Void
    @State private var editing = false
    @State private var draft = 0.0
    @State private var pending = false
    @State private var commitID = UUID()
    @State private var lastSentAt = 0.0
    private var displayed: Double { editing || pending ? draft : value }
    private func commit(_ next: Double) {
        draft = next; editing = false
        pending = abs(value - next) > 0.000001
        commitID = UUID()
        change(next)
    }
    private func update(_ x: CGFloat, width: CGFloat) {
        let fraction = min(1, max(0, Double((x - 6) / max(1, width - 12))))
        draft = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        if !editing { lastSentAt = 0 }
        editing = true
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSentAt >= 0.05 { lastSentAt = now; change(draft) }
    }
    var body: some View {
        GeometryReader { geometry in
            let fraction = min(1, max(0, (displayed - range.lowerBound) / (range.upperBound - range.lowerBound)))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(linked ? JarasTheme.yellow : Color.white.opacity(0.22)).frame(height: 6).padding(.horizontal, 6)
                RoundedRectangle(cornerRadius: 2).fill(linked ? JarasTheme.green : Color(white: 0.88))
                    .frame(width: 12, height: 18)
                    .overlay(Rectangle().fill(Color(white: 0.33)).frame(width: 1, height: 12))
                    .offset(x: CGFloat(fraction) * max(1, geometry.size.width - 12))
            }.frame(maxHeight: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { update($0.location.x, width: geometry.size.width) }
                    .onEnded { update($0.location.x, width: geometry.size.width); commit(draft) })
                .simultaneousGesture(TapGesture(count: 2).onEnded { commit(0) })
        }.frame(height: height)
            .onChange(of: value) { confirmed in
                if !editing, abs(confirmed - draft) <= 0.000001 { pending = false }
            }
            .task(id: commitID) {
                guard pending else { return }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                pending = false
            }
            .accessibilityElement().accessibilityValue(String(format: "%.1f", displayed))
            .accessibilityAdjustableAction { direction in
                let step = range.upperBound > 1 ? 0.5 : 0.05
                let next = min(range.upperBound, max(range.lowerBound, displayed + (direction == .increment ? step : -step)))
                commit(next)
            }
    }
}
private func remoteDecibelText(_ gain: Double) -> String {
    gain <= 0 ? "−∞" : String(format: "%+.1f", DAWRemoteFaderScale.decibels(gain))
}
private struct RemoteNativeTrackButtonStyle: ButtonStyle {
    var activeColor: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .semibold))
            .foregroundStyle(activeColor == nil ? Color.white : Color.black)
            .frame(width: 26, height: 22)
            .background(activeColor?.opacity(configuration.isPressed ? 0.75 : 1) ?? Color.white.opacity(configuration.isPressed ? 0.24 : 0.12))
            .cornerRadius(3).frame(width: 32, height: 28).contentShape(Rectangle())
    }
}
/// Keep the presented scroll view independent of transport/position snapshots.
/// Stable playlist IDs retain its scroll position while the bridge updates.
private struct RemoteNativePlaylistPicker: View, Equatable {
    let playlists: [DAWRemoteState.Song]
    let selected: UUID?
    let choose: (UUID?) -> Void
    let close: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.playlists == rhs.playlists && lhs.selected == rhs.selected }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet").foregroundStyle(JarasTheme.green)
                Text(verbatim: "Playlists").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 30, height: 30) }
                    .buttonStyle(.plain).foregroundStyle(JarasTheme.secondary).accessibilityLabel("Fechar")
            }.padding(.horizontal, 14).frame(height: 54).background(JarasTheme.panel)
            Rectangle().fill(JarasTheme.line).frame(height: 1)
            ScrollView(.vertical) {
                LazyVStack(spacing: 5) {
                    row(id: nil, name: JarasLocalization.string("Todas as músicas"))
                    ForEach(playlists) { playlist in row(id: playlist.id, name: playlist.name) }
                }.padding(10)
            }
        }.foregroundStyle(JarasTheme.text).background(JarasTheme.background)
            .frame(width: 310, height: min(420, CGFloat(playlists.count + 1) * 47 + 75))
            .preferredColorScheme(.dark)
    }
    private func row(id: UUID?, name: String) -> some View {
        Button { choose(id) } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(id == selected ? JarasTheme.green : JarasTheme.secondary.opacity(0.4)).frame(width: 3, height: 22)
                Text(verbatim: name).font(.system(size: 14, weight: id == selected ? .semibold : .medium))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if id == selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(JarasTheme.green) }
            }.padding(.horizontal, 12).frame(height: 42)
                .background(id == selected ? JarasTheme.green.opacity(0.10) : JarasTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(id == selected ? JarasTheme.green.opacity(0.5) : JarasTheme.line))
        }.buttonStyle(.plain).accessibilityAddTraits(id == selected ? .isSelected : [])
    }
}

private struct RemoteNativeMixerRow: View {
    let track: DAWRemoteState.Track
    let number: Int
    let send: (DAWRemoteCommand.Action, Double) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Spacer(minLength: 0)
                Text(verbatim: "Pan").font(.system(size: 10, weight: .semibold)).foregroundStyle(JarasTheme.text)
                RemoteNativeSlider(value: track.pan, range: -1...1) { send(.pan, $0) }.frame(width: 60)
                    .accessibilityLabel("Pan " + track.name)
                Button { send(.mute, 0) } label: { Text(verbatim: "M") }
                    .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: track.mute ? .red : nil))
                Button { send(.solo, 0) } label: { Text(verbatim: "S") }
                    .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil))
            }
            HStack(spacing: 3) {
                Text(remoteDecibelText(track.volume)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(JarasTheme.text).frame(width: 36, alignment: .leading)
                RemoteNativeSlider(value: DAWRemoteFaderScale.decibels(track.volume), range: -60...12, height: 22, linked: track.linkedTrack != nil) { send(.volume, DAWRemoteFaderScale.gain($0)) }
                    .accessibilityLabel("Volume " + track.name)
            }.frame(height: 23)
            Text(String(format: "%02d  %@", number, track.name)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                .foregroundStyle(remoteColor(track.nameColor ?? 0xffffff)).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background {
                let components = TrackNameContrast.components(track.color, emphasized: track.emphasized == true)
                Color(red: components.red, green: components.green, blue: components.blue)
                    .opacity(track.emphasized == true ? 0.65 : 0.50).saturation(track.silenced == true ? 0 : 1)
            }.background(JarasTheme.mixer)
            .overlay(Rectangle().stroke(track.emphasized == true ? Color.white.opacity(0.65) : .clear, lineWidth: 1))
    }
}

@MainActor private struct NativeRemoteProjectsView: View {
    let state: DAWRemoteState
    let computerName: String
    let open: (UUID) -> Void
    let close: () -> Void
    @State private var requested: UUID?
    private var browser: DAWRemoteState.ProjectBrowser? { state.projects }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent projects").font(.title2.bold())
                    Label { Text(verbatim: computerName) } icon: { Image(systemName: "desktopcomputer") }
                        .font(.subheadline).foregroundStyle(JarasTheme.secondary)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36)
                        .background(JarasTheme.panel).clipShape(Circle())
                }.buttonStyle(.plain).accessibilityLabel("Close")
            }
            Text("Choose a project to open on the Mac.").font(.callout).foregroundStyle(JarasTheme.secondary)
            if let browser {
                if browser.recent.isEmpty {
                    Text("No recent projects on this Mac.").foregroundStyle(JarasTheme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(browser.recent) { project in
                                Button { requested = project.id; open(project.id) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.text").font(.system(size: 22)).foregroundStyle(JarasTheme.green)
                                        Text(verbatim: project.name).font(.body.weight(.semibold)).lineLimit(2)
                                        Spacer()
                                        if project.current {
                                            Text("Open").font(.caption.weight(.semibold)).foregroundStyle(JarasTheme.green)
                                        } else if requested == project.id && browser.busy {
                                            ProgressView().tint(JarasTheme.green)
                                        } else {
                                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(JarasTheme.secondary)
                                        }
                                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(project.current ? JarasTheme.green.opacity(0.45) : JarasTheme.line))
                                }.buttonStyle(.plain).disabled(project.current || !browser.canOpen)
                            }
                        }
                    }
                }
                if !browser.status.isEmpty {
                    HStack(spacing: 10) {
                        if browser.busy { ProgressView().tint(JarasTheme.green) }
                        Text(LocalizedStringKey(browser.status)).font(.callout).foregroundStyle(JarasTheme.secondary)
                    }
                }
                if !browser.error.isEmpty {
                    Text(LocalizedStringKey(browser.error)).font(.callout).foregroundStyle(JarasTheme.yellow)
                }
            } else {
                Text("Update Jaras on the Mac to browse recent projects.").font(.callout).foregroundStyle(JarasTheme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(JarasTheme.background).foregroundStyle(JarasTheme.text)
            .onChange(of: browser?.recent.first(where: { $0.current })?.id) { current in
                if let requested, current == requested { close() }
            }
    }
}

@MainActor private final class RemoteTrackScrollController: NSObject, ObservableObject {
    #if os(iOS)
    weak var scrollView: UIScrollView? {
        didSet {
            guard oldValue !== scrollView else { return }
            trackObservation = scrollView?.observe(\.contentOffset, options: [.new]) { [weak self] source, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.synchronize(source, to: self.gridScrollView)
                }
            }
        }
    }
    weak var gridScrollView: UIScrollView? {
        didSet {
            guard oldValue !== gridScrollView else { return }
            oldValue?.removeGestureRecognizer(itemHold)
            gridScrollView?.addGestureRecognizer(itemHold)
            gridObservation = gridScrollView?.observe(\.contentOffset, options: [.new]) { [weak self] source, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.synchronize(source, to: self.scrollView)
                }
            }
        }
    }
    private var trackObservation: NSKeyValueObservation?
    private var gridObservation: NSKeyValueObservation?
    private final class HoldArea {
        weak var view: RemoteGridItemHoldArea?
        init(_ view: RemoteGridItemHoldArea) { self.view = view }
    }
    private var holdAreas: [ObjectIdentifier: HoldArea] = [:]
    private weak var heldArea: RemoteGridItemHoldArea?
    private lazy var itemHold: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(itemHeld(_:)))
        gesture.minimumPressDuration = 0.45
        gesture.allowableMovement = 8
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.cancelsTouchesInView = true
        gesture.delegate = self
        return gesture
    }()
    func registerHoldArea(_ view: RemoteGridItemHoldArea) { holdAreas[ObjectIdentifier(view)] = HoldArea(view) }
    func unregisterHoldArea(_ view: RemoteGridItemHoldArea) { holdAreas.removeValue(forKey: ObjectIdentifier(view)) }
    @objc private func itemHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let scroll = gridScrollView,
              !scroll.isDragging, let area = heldArea, area.window != nil,
              area.bounds.contains(gesture.location(in: area)) else { return }
        area.hold?()
    }
    fileprivate func receiveItemHold(_ touch: UITouch) -> Bool {
        holdAreas = holdAreas.filter { $0.value.view != nil }
        heldArea = holdAreas.values.compactMap(\.view).first { area in
            let point = touch.location(in: area)
            return area.window != nil && !area.isHidden && area.bounds.contains(point)
                && !CGRect(x: 0, y: 0, width: 35, height: 28).contains(point)
        }
        return heldArea != nil
    }
    private func synchronize(_ source: UIScrollView, to target: UIScrollView?) {
        guard let target, source.window != nil, target.window != nil else { return }
        if source === gridScrollView {
            guard source.isDragging || source.isDecelerating else { return }
        } else if gridScrollView?.isDragging == true || gridScrollView?.isDecelerating == true { return }
        let offset = DAWRemoteScrollRange.clamp(Double(source.contentOffset.y), content: Double(target.contentSize.height), viewport: Double(target.bounds.height), topInset: Double(target.adjustedContentInset.top), bottomInset: Double(target.adjustedContentInset.bottom))
        if abs(target.contentOffset.y - offset) > 0.5 {
            target.setContentOffset(CGPoint(x: target.contentOffset.x, y: offset), animated: false)
        }
    }
    private var gestureStart: CGFloat = 0
    private var momentum: Task<Void, Never>?
    private var lastTime: CFTimeInterval = 0
    private var lastTranslation: CGFloat = 0
    private var velocity: CGFloat = 0
    func begin() {
        momentum?.cancel(); momentum = nil
        gestureStart = scrollView?.contentOffset.y ?? 0
        lastTime = CACurrentMediaTime(); lastTranslation = 0; velocity = 0
    }
    func drag(_ translation: CGFloat) {
        let now = CACurrentMediaTime(), elapsed = now - lastTime
        if elapsed > 0.005 { velocity = -(translation - lastTranslation) / elapsed }
        lastTime = now; lastTranslation = translation
        move(to: gestureStart - translation, animated: false)
    }
    func end() {
        guard CACurrentMediaTime() - lastTime < 0.1, abs(velocity) > 30 else { return }
        let initialVelocity = min(5000, max(-5000, velocity))
        momentum = Task { @MainActor [weak self] in
            var speed = initialVelocity
            var timestamp = CACurrentMediaTime()
            while !Task.isCancelled, abs(speed) > 10 {
                do { try await Task.sleep(nanoseconds: 16_000_000) } catch { return }
                guard let self, let scroll = self.scrollView, scroll.window != nil,
                      !scroll.isDragging, !scroll.isDecelerating, self.gridScrollView?.isDragging != true, self.gridScrollView?.isDecelerating != true else { return }
                let now = CACurrentMediaTime(), delta = min(0.05, now - timestamp)
                timestamp = now
                let before = scroll.contentOffset.y
                self.move(to: before + speed * delta, animated: false)
                if abs(scroll.contentOffset.y - before) < 0.1 { return }
                speed *= pow(CGFloat(UIScrollView.DecelerationRate.normal.rawValue), delta * 1000)
            }
        }
    }
    func step(_ direction: Int) {
        momentum?.cancel(); momentum = nil
        guard let scrollView else { return }
        move(to: scrollView.contentOffset.y + CGFloat(direction) * max(86, scrollView.bounds.height * 0.5), animated: true)
    }
    private func move(to offset: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        let limited = DAWRemoteScrollRange.clamp(Double(offset), content: Double(scrollView.contentSize.height),
            viewport: Double(scrollView.bounds.height), topInset: Double(scrollView.adjustedContentInset.top), bottomInset: Double(scrollView.adjustedContentInset.bottom))
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: CGFloat(limited)), animated: animated)
    }
    #else
    func end() {}
    func begin() {}
    func drag(_ translation: CGFloat) {}
    func step(_ direction: Int) {}
    #endif
}
@MainActor private struct RemoteTrackScrollRail: View {
    let controller: RemoteTrackScrollController
    @State private var dragging = false
    var body: some View {
        VStack(spacing: 0) {
            Button { controller.step(-1) } label: {
                Image(systemName: "chevron.up").frame(width: 28, height: 36)
            }.accessibilityLabel("Rolar pistas para cima")
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 1).fill(JarasTheme.line).frame(width: 2, height: 44)
                .allowsHitTesting(false)
            Spacer(minLength: 0)
            Button { controller.step(1) } label: {
                Image(systemName: "chevron.down").frame(width: 28, height: 36)
            }.accessibilityLabel("Rolar pistas para baixo")
        }.font(.system(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.green)
            .buttonStyle(.plain).frame(maxHeight: .infinity).background(JarasTheme.display)
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 3)
                .onChanged {
                    if !dragging { controller.begin(); dragging = true }
                    controller.drag($0.translation.height)
                }
                .onEnded { _ in controller.end(); dragging = false })
            .accessibilityElement(children: .contain).accessibilityLabel("Área de rolagem do Track-Mixer")
    }
}
#if os(iOS)
extension RemoteTrackScrollController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        receiveItemHold(touch)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer === gridScrollView?.panGestureRecognizer
    }
}

/// Register item bounds without putting a SwiftUI recognizer between the finger
/// and UIScrollView. One native hold recognizer shares the grid's touch stream.
private struct RemoteGridItemHoldProbe: UIViewRepresentable {
    let controller: RemoteTrackScrollController
    let hold: () -> Void
    func makeUIView(context: Context) -> RemoteGridItemHoldArea {
        let view = RemoteGridItemHoldArea()
        view.isUserInteractionEnabled = false
        view.bind(controller: controller, hold: hold)
        return view
    }
    func updateUIView(_ view: RemoteGridItemHoldArea, context: Context) {
        view.bind(controller: controller, hold: hold)
    }
    static func dismantleUIView(_ view: RemoteGridItemHoldArea, coordinator: ()) { view.unbind() }
}
private final class RemoteGridItemHoldArea: UIView {
    private weak var controller: RemoteTrackScrollController?
    var hold: (() -> Void)?
    func bind(controller: RemoteTrackScrollController, hold: @escaping () -> Void) {
        if self.controller !== controller {
            self.controller?.unregisterHoldArea(self)
            self.controller = controller
            controller.registerHoldArea(self)
        }
        self.hold = hold
    }
    func unbind() {
        controller?.unregisterHoldArea(self)
        controller = nil; hold = nil
    }
}

/// Find the containing native scroll view without replacing SwiftUI's delegate.
private struct RemoteTrackScrollProbe: UIViewRepresentable {
    let controller: RemoteTrackScrollController
    var isGrid = false
    func makeUIView(context: Context) -> RemoteTrackScrollProbeView {
        let view = RemoteTrackScrollProbeView()
        view.isUserInteractionEnabled = false; view.controller = controller; view.isGrid = isGrid
        return view
    }
    func updateUIView(_ view: RemoteTrackScrollProbeView, context: Context) {
        view.controller = controller; view.isGrid = isGrid; view.resolve()
    }
}
private final class RemoteTrackScrollProbeView: UIView {
    var controller: RemoteTrackScrollController?
    var isGrid = false
    override func didMoveToWindow() { super.didMoveToWindow(); resolve() }
    override func didMoveToSuperview() { super.didMoveToSuperview(); resolve() }
    func resolve() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            var parent = self.superview
            while let view = parent {
                if let scroll = view as? UIScrollView {
                    if scroll.bounces { scroll.bounces = false }
                    if scroll.alwaysBounceVertical { scroll.alwaysBounceVertical = false }
                    if scroll.alwaysBounceHorizontal { scroll.alwaysBounceHorizontal = false }
                    scroll.contentInsetAdjustmentBehavior = .never
                    if self.isGrid { self.controller?.gridScrollView = scroll }
                    else { self.controller?.scrollView = scroll }
                    return
                }
                parent = view.superview
            }
        }
    }
}
#endif
#endif

#if os(iOS)
/// Static assets are fetched once and retained independently of the 10 Hz state stream.
private struct RemoteNativeProjectionImage: View {
    let id: UUID
    let project: UUID
    var stretch = false
    @ObservedObject private var remote = DAWRemoteSession.shared
    @State private var image: UIImage?
    @State private var loadedID: UUID?
    var body: some View {
        Group {
            if let image {
                GeometryReader { geometry in
                    if stretch { Image(uiImage: image).resizable().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                    else { Image(uiImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                }
            }
            else if loadedID == id {
                Label("Imagem indisponível", systemImage: "photo").foregroundStyle(JarasTheme.secondary)
            }
            else { ProgressView().tint(JarasTheme.green) }
        }.task(id: id) {
            image = nil; loadedID = nil
            load()
            remote.requestImage(id: id, project: project)
        }.onChange(of: remote.imageRevision) { _ in load() }
    }
    private func load() {
        guard loadedID != id else { return }
        if let data = remote.imageData(id: id, project: project) {
            loadedID = id; image = UIImage(data: data)
        } else if remote.imageUnavailable(id: id, project: project) {
            loadedID = id; image = nil
        }
    }
}

@MainActor struct RemoteNativeTeleprompterPanel: View {
    let index: Int
    @ObservedObject var timer: RemoteLocalTimer
    var fullscreen = false
    let toggleFullscreen: () -> Void
    var toggleSetlist: (() -> Void)? = nil
    var setlistVisible = true
    var managesSubscription = true
    @ObservedObject private var remote = DAWRemoteSession.shared
    private var content: DAWRemoteTeleprompter? { remote.remoteState?.teleprompters?.first { $0.index == index } }
    var body: some View {
        VStack(spacing: 6) {
            if !fullscreen {
            HStack {
                Text("TP-\(index)").font(.system(size: 15, weight: .semibold)).foregroundStyle(JarasTheme.green)
                Spacer()
                if let toggleSetlist {
                    Button(action: toggleSetlist) {
                        Image(systemName: "sidebar.right").frame(width: 30, height: 30)
                            .foregroundStyle(setlistVisible ? JarasTheme.green : JarasTheme.secondary)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(setlistVisible ? "Recolher Setlist" : "Expandir Setlist")
                        .accessibilityValue(setlistVisible ? "Shown" : "Hidden")
                }
            }.padding(.horizontal, 16).padding(.top, 8)
            }
            Group {
            if let content, let state = remote.remoteState {
                projection(content, state: state)
            } else if remote.remoteState?.timer == nil {
                Text("Atualize o Jaras no Mac para usar este painel.")
                    .font(.callout).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Aguardando teleprompter…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded(toggleFullscreen))
                .accessibilityAction(named: Text(fullscreen ? "Sair da tela cheia" : "Tela cheia"), toggleFullscreen)
        }.background(Color.black).foregroundStyle(JarasTheme.text)
            .onAppear { if managesSubscription { subscribe(index) } }
            .onChange(of: index) { if managesSubscription { subscribe($0) } }
            .onDisappear { if managesSubscription { subscribe(0) } }
    }
    private func subscribe(_ panel: Int) {
        guard let state = remote.remoteState else { return }
        remote.send(.init(project: state.project, song: state.song, action: .remotePanel, value: Double(panel)))
    }
    private func projection(_ content: DAWRemoteTeleprompter, state: DAWRemoteState) -> some View {
        TeleprompterProjectionLayout(content: content, fullscreen: fullscreen,
            timerValue: { (timer.displayText().replacingOccurrences(of: ":", with: " : "), timer.displayOpacity(), timer.expired()) },
            media: {
                if let image = content.imageID {
                    RemoteNativeProjectionImage(id: image, project: state.project, stretch: content.resolvedSettings.stretchesMedia)
                }
            })
            .overlay {
                if let notices = state.notices, notices.active && (index == 1 ? notices.window1 : notices.window2) {
                    RemoteNativeNoticeOverlay(notice: notices, project: state.project)
                }
            }
    }
}

private func remoteTPFont(_ name: String, size: CGFloat) -> Font {
    let names = ["arial": "Arial-BoldMT", "verdana": "Verdana-Bold", "tahoma": "Tahoma-Bold", "georgia": "Georgia-Bold", "trebuchet": "TrebuchetMS-Bold", "impact": "Impact", "mono": "CourierNewPS-BoldMT"]
    if let font = names[name], UIFont(name: font, size: size) != nil { return .custom(font, size: size) }
    return .system(size: size, weight: .bold, design: name == "mono" ? .monospaced : .default)
}

private struct RemoteNativeNoticeOverlay: View {
    let notice: DAWRemoteNotices
    let project: UUID
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.175)) { context in
            let elapsed = context.date.timeIntervalSince1970 - notice.sentAt
            let flash = elapsed >= 0 && elapsed < 1.05 && Int(elapsed / 0.175) % 2 == 0
            VStack {
                if let image = notice.imageID {
                    RemoteNativeProjectionImage(id: image, project: project)
                } else {
                    let text = notice.message.uppercased()
                    Text(notice.emoji.isEmpty ? text : "\(notice.emoji) \(text) \(notice.emoji)")
                        .font(.custom(notice.font, size: 56 * notice.scale / 100)).minimumScaleFactor(0.3)
                        .foregroundStyle(remoteColor(notice.textColor)).multilineTextAlignment(.center)
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: notice.cleanDisplay ? .infinity : nil)
                .background(remoteColor(flash ? notice.flashColor : notice.backgroundColor))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }.allowsHitTesting(false)
    }
}

@MainActor struct RemoteNativeNoticesView: View {
    let close: () -> Void
    var managesSubscription = true
    @ObservedObject private var remote = DAWRemoteSession.shared
    @State private var draft = ""
    @State private var globalDraft = ""
    @State private var slot = -1
    private var notices: DAWRemoteNotices? { remote.remoteState?.notices }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Recados").font(.headline)
                Spacer()
                Button("Fechar", action: close)
            }
            if let notices {
                HStack(spacing: 8) {
                    Button("Enviar") { command(.noticeSend, value: Double(slot), text: draft) }
                        .buttonStyle(.borderedProminent).tint(JarasTheme.green)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (slot < 0 || !notices.imageSlots[slot]))
                    Button("Retirar") { command(.noticeClear) }.buttonStyle(.bordered).disabled(!notices.active)
                    Button { command(.noticePin, value: notices.pinned ? 0 : 1) } label: {
                        Label("Fixar", systemImage: notices.pinned ? "pin.fill" : "pin")
                    }.buttonStyle(.bordered).tint(notices.pinned ? JarasTheme.yellow : JarasTheme.secondary)
                    Spacer(minLength: 0)
                    Text(notices.pinned ? "∞" : "\(notices.remaining)s").monospacedDigit().foregroundStyle(JarasTheme.secondary)
                }.font(.system(size: 13, weight: .semibold))
                Picker("Recado", selection: $slot) {
                    Text("Global").tag(-1)
                    ForEach(0..<3) { Text("Recado \($0 + 1)").tag($0) }
                }.pickerStyle(.segmented).onChange(of: slot) { value in
                    draft = value < 0 ? globalDraft : notices.templates[value]
                }
                TextEditor(text: $draft).font(.system(size: 18)).scrollContentBackground(.hidden)
                    .padding(5).background(JarasTheme.display).cornerRadius(6)
                    .onChange(of: draft) { value in
                        var bounded = String(value.prefix(500))
                        while bounded.utf8.count > 4000 { bounded.removeLast() }
                        if bounded != value { draft = bounded }
                        if slot < 0 { globalDraft = bounded }
                    }
                HStack {
                    Text("\(draft.count) / 500").font(.caption).foregroundStyle(JarasTheme.secondary)
                    if slot >= 0 && notices.imageSlots[slot] {
                        Label("Imagem salva", systemImage: "photo").font(.caption).foregroundStyle(JarasTheme.secondary)
                    }
                    Spacer()
                    if slot >= 0 { Button("Salvar recado") { command(.noticeSaveTemplate, value: Double(slot), text: draft) } }
                }
                HStack(spacing: 16) {
                    Toggle("TP-1", isOn: Binding(get: { notices.window1 }, set: { command(.noticeDestination, value: 1, enabled: $0) }))
                    Toggle("TP-2", isOn: Binding(get: { notices.window2 }, set: { command(.noticeDestination, value: 2, enabled: $0) }))
                }.toggleStyle(.button).tint(JarasTheme.green)
            } else if remote.remoteState?.timer == nil {
                Text("Atualize o Jaras no Mac para usar este painel.")
                    .font(.callout).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView("Aguardando recados…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(16).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onAppear { if managesSubscription { command(.remotePanel, value: 3) } }
            .onDisappear { if managesSubscription { command(.remotePanel) } }
    }
    private func command(_ action: DAWRemoteCommand.Action, value: Double = 0, text: String? = nil, enabled: Bool? = nil) {
        guard let state = remote.remoteState else { return }
        remote.send(.init(project: state.project, song: state.song, action: action, value: value, text: text, enabled: enabled))
    }
}
#endif

// MARK: - Local Remote timer
/// Anchor once per authoritative timer change. Bridge frame cadence never drives
/// the local display, which keeps counting through a connection interruption.
@MainActor final class RemoteLocalTimer: ObservableObject {
    private struct Anchor: Equatable {
        var targetSeconds = 0
        var running = false
        var remainingSeconds = 0.0
        var uptime = 0.0
    }
    @Published private var anchor = Anchor()
    private var hostRevision: UUID?
    private var pendingCommand: (id: UUID, deadline: Double)?
    private let now: () -> Double
    init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
    var running: Bool { anchor.running }
    var targetSeconds: Int { anchor.targetSeconds }
    var targetText: String { TeleprompterTimer.formatted(targetSeconds) }

    func synchronize(_ snapshot: DAWRemoteTimerState?) {
        guard let snapshot, snapshot.valid else { return }
        let timestamp = now()
        guard timestamp.isFinite else { return }
        if let pendingCommand {
            // A response to an earlier Start/Stop must not undo the latest tap.
            // Fall back to a fresh host snapshot if a command was rejected/lost.
            guard snapshot.commandID == pendingCommand.id || timestamp >= pendingCommand.deadline else { return }
            self.pendingCommand = nil
        } else if snapshot.revision == hostRevision { return }
        hostRevision = snapshot.revision
        anchor = Anchor(targetSeconds: snapshot.targetSeconds, running: snapshot.running,
                        remainingSeconds: snapshot.remainingSeconds, uptime: timestamp)
    }
    /// Use when reconnecting to a host so its latest remaining time is sampled.
    func resetSynchronization() { hostRevision = nil; pendingCommand = nil }
    @discardableResult func start(seconds: Int) -> UUID? {
        guard !running else { return nil }
        let timestamp = now()
        guard timestamp.isFinite else { return nil }
        let target = min(TeleprompterTimer.maximumTargetSeconds, max(0, seconds))
        let id = UUID(); pendingCommand = (id, timestamp + 3)
        anchor = Anchor(targetSeconds: target, running: true, remainingSeconds: Double(target), uptime: timestamp)
        return id
    }
    @discardableResult func stop() -> UUID? {
        guard running else { return nil }
        let timestamp = now()
        guard timestamp.isFinite else { return nil }
        let id = UUID(); pendingCommand = (id, timestamp + 3)
        anchor = Anchor(targetSeconds: targetSeconds, running: false, remainingSeconds: 0, uptime: timestamp)
        return id
    }
    func displaySeconds() -> Double {
        let timestamp = now()
        guard running, timestamp.isFinite else { return anchor.remainingSeconds }
        return anchor.remainingSeconds - max(0, timestamp - anchor.uptime)
    }
    func displayText() -> String {
        let safe = max(-Double(Int.max / 2), min(Double(Int.max / 2), displaySeconds()))
        return TeleprompterTimer.formatted(Int(ceil(safe)))
    }
    func expired() -> Bool { running && displaySeconds() <= 0 }
    func displayOpacity() -> Double { expired() && now().truncatingRemainder(dividingBy: 1) >= 0.5 ? 0.25 : 1 }
    private static let localClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    static func localTime(at date: Date = Date()) -> String { localClock.string(from: date) }
}

// MARK: - Local Remote timer views
@MainActor struct RemoteNativeLocalClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(verbatim: RemoteLocalTimer.localTime(at: context.date)).monospacedDigit()
        }
    }
}
@MainActor struct RemoteNativeTimerReadout: View {
    @ObservedObject var timer: RemoteLocalTimer
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text(verbatim: timer.displayText()).monospacedDigit()
                .foregroundStyle(timer.expired() ? Color.red : JarasTheme.green)
                .opacity(timer.displayOpacity())
        }
    }
}
@MainActor struct RemoteNativeTimerView: View {
    @ObservedObject var timer: RemoteLocalTimer
    let send: (DAWRemoteCommand.Action, Double, UUID) -> Void
    let close: () -> Void
    var compact = false
    @State private var digits = ["00", "00", "00"]
    @FocusState private var focused: Int?
    var body: some View {
        Group {
        if compact {
            HStack(spacing: 3) {
                Image(systemName: "clock").foregroundStyle(Color.blue).font(.system(size: 13))
                if timer.running {
                    RemoteNativeTimerReadout(timer: timer).font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(0..<3, id: \.self) { index in
                        if index > 0 { Text(verbatim: ":").foregroundStyle(Color.blue) }
                        durationField(index)
                    }
                }
                Button(action: toggleTimer) {
                    Image(systemName: timer.running ? "stop.fill" : "play.fill").frame(width: 28, height: 32)
                }.buttonStyle(.plain).foregroundStyle(timer.running ? Color.red : Color.blue)
                    .accessibilityLabel(timer.running ? "Stop timer" : "Start timer")
            }.frame(height: 32).padding(.horizontal, 3).background(JarasTheme.display).cornerRadius(5)
        } else {
        VStack(spacing: 12) {
            HStack {
                Text("Timer").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 30, height: 30) }
                    .buttonStyle(.plain).foregroundStyle(JarasTheme.secondary).accessibilityLabel("Close")
            }
            RemoteNativeTimerReadout(timer: timer)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 42).background(JarasTheme.display)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(spacing: 5) {
                        Text(LocalizedStringKey(["Hours", "Minutes", "Seconds"][index]))
                            .font(.system(size: 11)).foregroundStyle(JarasTheme.secondary)
                        durationField(index)
                    }.frame(maxWidth: .infinity)
                }
            }.disabled(timer.running)
            Button(action: toggleTimer) {
                Text(LocalizedStringKey(timer.running ? "Stop" : "Start"))
                    .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 38)
            }.buttonStyle(.plain).foregroundStyle(timer.running ? Color.white : JarasTheme.green)
                .background(timer.running ? Color.red.opacity(0.65) : JarasTheme.display)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(timer.running ? Color.red : JarasTheme.line))
        }.padding(14).frame(width: 300).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
        }
        }.onAppear(perform: synchronizeDigits)
            .onChange(of: timer.targetSeconds) { _ in synchronizeDigits() }
    }
    private func toggleTimer() {
                focused = nil
                if timer.running {
                    if let id = timer.stop() { send(.timerStop, 0, id) }
                }
                else {
                    let seconds = TeleprompterTimer.targetSeconds(from: digits.map { $0.isEmpty ? "00" : $0 }.joined(separator: ":")) ?? 0
                    if let id = timer.start(seconds: seconds) { synchronizeDigits(); send(.timerStart, Double(seconds), id) }
                }
    }
    private func durationField(_ index: Int) -> some View {
        TextField("00", text: Binding(get: { digits[index] }, set: { value in
            digits[index] = String(value.filter { $0.isASCII && $0.isNumber }.prefix(2))
        }))
        .textFieldStyle(.plain).focused($focused, equals: index)
        .font(.system(size: compact ? 14 : 22, weight: .semibold, design: .monospaced))
        .multilineTextAlignment(.center).frame(height: compact ? 30 : 40).background(JarasTheme.display)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused == index ? JarasTheme.green : JarasTheme.line))
        .accessibilityLabel(LocalizedStringKey(["Hours", "Minutes", "Seconds"][index]))
        #if os(iOS)
        .keyboardType(.numberPad)
        #endif
    }
    private func synchronizeDigits() { digits = timer.targetText.components(separatedBy: ":") }
}
