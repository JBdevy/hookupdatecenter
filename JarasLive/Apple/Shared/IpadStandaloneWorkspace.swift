#if os(iOS)
import SwiftUI
import UIKit
import Combine

/// The iPad workspace uses the same ShowController/audio engine as the desktop.
/// This adapter projects presentation state in-process; it owns no transport timer
/// and never sends local controls through a network or Remote singleton.
@MainActor final class IpadStandalonePresentation: ObservableObject {
    let session = DAWRemoteSession(role: .client, name: UIDevice.current.name)
    let timer = RemoteLocalTimer()
    @Published private(set) var state: DAWRemoteState?
    @Published private(set) var projectRevision: UInt64 = 0
    @Published private(set) var timelineFocus: IpadTimelineFocus?
    private var subscriptions = Set<AnyCancellable>()
    private var refreshPending = false
    private var running = false
    private let mappingSession = UUID()
    private weak var show: ShowController?
    private weak var documents: ProjectDocuments?
    init(show: ShowController, documents: ProjectDocuments) {
        self.show = show; self.documents = documents
    }
    func start() {
        guard !running, let show, let documents else { return }
        running = true
        ControlMappings.shared.bind(show, session: mappingSession)
        DAWRemoteHostBridge.documents = documents
        DAWRemoteHostBridge.bind(show, session: session)
        session.startLocalWorkspace()
        DAWRemoteHostBridge.bind(show, session: .nativeHost)
        DAWRemoteSession.nativeHost.restoreHostPreference()
        for index in 1...2 {
            TeleprompterRemote.panel(index).configure(directory: documents.currentURL?.deletingLastPathComponent()) { [weak self] in
                self?.refreshTeleprompterRemote(index)
            }
        }
        for publisher in [show.objectWillChange.eraseToAnyPublisher(),
                          documents.objectWillChange.eraseToAnyPublisher(),
                          TeleprompterTimerController.shared.objectWillChange.eraseToAnyPublisher(),
                          TPNoticeController.shared.objectWillChange.eraseToAnyPublisher(),
                          LiveRecordingPreview.shared.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        }
        refresh()
        UIApplication.shared.isIdleTimerDisabled = true
    }
    private func scheduleRefresh() {
        guard running, !refreshPending else { return }
        refreshPending = true
        // Publish a completed snapshot outside UIKit's touch-tracking mode.
        // Playback keeps its own common-mode clock; scrolling must not rebuild
        // the entire workspace for every transport tick under the finger.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPending = false
                if self.running { self.refresh() }
            }
        }
    }
    func refresh() {
        if let show {
            VideoPlayback.teleprompter.update(show.snapshot)
            VideoPlayback.teleprompter2.update(show.snapshot)
        }
        session.refreshLocalWorkspace()
        if var next = session.remoteState {
            for (id, take) in LiveRecordingPreview.shared.takes {
                guard let reservation = RecordingLaneLayout.shared.items[id],
                      let index = next.tracks.firstIndex(where: { $0.id == reservation.track }) else { continue }
                let lane = reservation.clip.recordingLane ?? 0
                next.tracks[index].laneCount = max(next.tracks[index].laneCount ?? 1, lane + 1)
                if !next.tracks[index].clips.contains(where: { $0.id == id }) {
                    next.tracks[index].clips.append(.init(id: id, name: reservation.clip.name, start: take.start,
                        duration: max(0.01, take.duration), lane: lane, waveform: take.channels.first))
                }
            }
            if DAWRemoteSnapshotComparison.differs(next, from: state) { state = next }
        }
        if let show {
            if projectRevision != show.projectRevision { projectRevision = show.projectRevision }
            // Publish the request by value: the workspace deliberately does not
            // observe ShowController on every transport tick. Focus must still
            // reach the grid even when the projected remote state is unchanged.
            if timelineFocus?.id != show.regionFocusRequest {
                timelineFocus = IpadTimelineFocus(id: show.regionFocusRequest,
                    position: show.navigationFocusPosition ?? show.snapshot.transport.editPosition ?? show.snapshot.transport.position)
            }
        }
        timer.synchronize(state?.timer)
    }
    private func refreshTeleprompterRemote(_ index: Int) {
        guard running, let show else { return }
        let remote = TeleprompterRemote.panel(index)
        guard remote.enabled else { return }
        let directory = documents?.currentURL?.deletingLastPathComponent()
        remote.configure(directory: directory) { [weak self] in self?.refreshTeleprompterRemote(index) }
        let content = DAWRemoteHostBridge.teleprompter(index: index, snapshot: show.snapshot, directory: directory, remote: session)
        remote.update(text: content.text, chords: content.chords, song: content.song, queued: content.queued,
            progress: content.progress, preview: content.preview, blocks: content.blocks.map {
                TeleprompterRemoteBlock(name: $0.name, color: $0.color, duration: $0.rows.reduce(0) { $0 + $1.duration },
                    songs: $0.rows.map { TeleprompterRemoteSong(name: $0.name, color: $0.color, duration: $0.duration) })
            }, snapshot: show.snapshot)
    }
    func send(_ command: DAWRemoteCommand) { session.send(command); refresh() }
    func stop() {
        guard running else { return }
        running = false; subscriptions.removeAll()
        if ControlMappings.shared.endNativeSession(mappingSession) {
            show?.togglePartsPanel = {}; show?.toggleSetlistPanel = {}
        }
        DAWRemoteSession.nativeHost.stop()
        for index in 1...2 { TeleprompterRemote.panel(index).setEnabled(false) }
        TPNoticeController.shared.clear()
        VideoPlayback.shared.setVisible(false)
        VideoPlayback.teleprompter.setProjectionEnabled(false)
        VideoPlayback.teleprompter2.setProjectionEnabled(false)
        session.endLocalWorkspace(); state = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

@MainActor struct IpadStandaloneWorkspace: View {
    let show: ShowController
    let documents: ProjectDocuments
    let auth: AuthService
    let backend: any BackendClient
    let onExit: () -> Void
    @StateObject private var local: IpadStandalonePresentation
    @ObservedObject private var audio = AudioDeviceSettings.shared
    @ObservedObject private var recorder = TrackRecording.shared
    private struct FXTarget: Identifiable {
        let id = UUID()
        var track: UUID?
        var clip: UUID?
        var targets: [UUID?] = []
    }
    private struct PatchTarget: Identifiable {
        let id = UUID()
        var track: UUID?
        var targets: [UUID?] = []
    }
    @State private var remoteSettingsOpen = false
    @State private var remoteTeleprompter: Int?
    @State private var settingsOpen = false
    @State private var metronomeOpen = false
    @State private var regionActions: UUID?
    @State private var detectingRegion: UUID?
    @State private var addingTrack = false
    @State private var advancedOpen = false
    @State private var exportingProject = false
    @State private var regionLoops: FXTarget?
    @State private var itemMenu: FXTarget?
    @State private var editingTextItem: UUID?
    @State private var trackEdit: TrackDetailsEditRequest?
    @State private var fx: FXTarget?
    @State private var patch: PatchTarget?
    @State private var missingOutput: PatchTarget?
    init(show: ShowController, documents: ProjectDocuments, auth: AuthService,
         backend: any BackendClient, onExit: @escaping () -> Void) {
        self.show = show; self.documents = documents; self.auth = auth
        self.backend = backend; self.onExit = onExit
        _local = StateObject(wrappedValue: IpadStandalonePresentation(show: show, documents: documents))
    }
    private var dialogOpen: Bool {
        remoteSettingsOpen || remoteTeleprompter != nil || patch != nil || settingsOpen || metronomeOpen || regionActions != nil || detectingRegion != nil || exportingProject || advancedOpen || addingTrack || regionLoops != nil || itemMenu != nil || editingTextItem != nil || trackEdit != nil || fx != nil
    }
    var body: some View {
        VStack(spacing: 0) {
            if let missingOutput {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Some output channels are unavailable on this iPad.")
                        .font(.jarasCallout).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Patch") { patch = missingOutput }.buttonStyle(.bordered)
                }.padding(10).foregroundStyle(JarasTheme.yellow).background(JarasTheme.panel)
            }
            if let state = local.state {
                NativeRemoteWorkspace(state: state, computerName: UIDevice.current.name,
                    timer: local.timer, send: local.send, exitRemote: {
                        show.send(.stop); onExit()
                    }, local: true, localShow: show, timelineFocus: local.timelineFocus, openMetronome: { metronomeOpen = true }, openRegionActions: { regionActions = $0 }, detectRegionBPM: { detectingRegion = $0 }, openPatch: { patch = .init(track: $0) }, openTrackFX: { fx = .init(track: $0) },
                    openSelectedPatch: { patch = .init(track: $0.first, targets: $0.map { Optional($0) }) },
                    openSelectedFX: { fx = .init(track: $0.first, targets: $0.map { Optional($0) }) },
                    openTrackDetails: { ids in
                        let tracks = (show.current?.tracks ?? []).filter { ids.contains($0.id) }
                        guard let first = tracks.first else { return }
                        trackEdit = .init(project: show.snapshot.project.id, tracks: Set(tracks.map(\.id)),
                            name: first.name, color: first.color ?? JarasTheme.roleHex(first.role),
                            nameEditable: tracks.count == 1 && first.kind == .standard)
                    },
                    openMasterDetails: {
                        trackEdit = .init(project: show.snapshot.project.id, tracks: [], name: "Master",
                            color: show.snapshot.project.masterColor ?? 0xffdc52, nameEditable: false)
                    },
                    openItemMenu: { itemMenu = .init(clip: $0) }, openItemFX: { fx = .init(clip: $0) }, addTrack: { addingTrack = true }, addTrackAudio: { documents.chooseNativeTrackAudio($0) },
                    addTrackText: { editingTextItem = show.addTextItem(track: $0) }, addTrackMedia: { documents.chooseNativeTrackMedia($0) },
                    createPlaylist: { show.createRegionPlaylist(name: $0, selected: $1) },
                    addBlock: { show.addSetlistBlock(namePrefix: JarasLocalization.string("Bloco")) },
                    toggleRegionStop: { show.toggleRegionStop() }, stopsAtRegionEnd: show.regionSetlist.stopsAtRegionEnd,
                    exportProject: { exportingProject = true },
                    groupTracks: { show.groupTracks($0) }, groupableTracks: Set((show.current?.tracks ?? []).filter { $0.kind == .standard && $0.stereoLink == nil }.map(\.id)), openRegionLoops: { regionLoops = .init(clip: $0) }, openAdvanced: { advancedOpen = true }, openSettings: { settingsOpen = true }, openRemoteSettings: { remoteSettingsOpen = true }, openTeleprompterRemote: { remoteTeleprompter = $0 }, remote: local.session)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(RemoteSurface.background).preferredColorScheme(.dark)
        .onAppear { local.start(); inspectOutputRoutes() }
        .onDisappear { local.stop() }
        .onChange(of: local.projectRevision) { _ in inspectOutputRoutes() }
        .onChange(of: local.state?.project) { _ in inspectOutputRoutes() }
        .onChange(of: audio.channels) { _ in inspectOutputRoutes() }
        .disabled(dialogOpen || audio.localSessionReconfiguring).accessibilityHidden(dialogOpen)
        .overlay { workspaceDialogs }
        .overlay(alignment: .bottom) {
            if audio.localSessionReconfiguring && !audio.error.isEmpty {
                Text(verbatim: audio.error).font(.jarasCallout).multilineTextAlignment(.center)
                    .foregroundStyle(.white).padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.4, green: 0.08, blue: 0.08)))
                    .padding()
            }
        }
        .alert("Recording", isPresented: Binding(get: { !recorder.error.isEmpty }, set: { if !$0 { recorder.error = "" } })) {
            Button("OK") { recorder.error = "" }
        } message: { Text(LocalizedStringKey(recorder.error)) }
    }
    @ViewBuilder private var workspaceDialogs: some View {
        if remoteSettingsOpen {
            IpadCompactModal(preferredSize: CGSize(width: 440, height: 600)) {
                VStack(spacing: 0) {
                    IpadModalHeader(title: "Remote", close: { remoteSettingsOpen = false })
                    ScrollView { DAWRemoteHostView(remote: .nativeHost) }.frame(maxWidth: .infinity)
                }
            }
        } else if let index = remoteTeleprompter {
            IpadCompactModal(preferredSize: CGSize(width: 440, height: 480)) {
                ScrollView {
                    TeleprompterRemoteView(close: { remoteTeleprompter = nil }, remote: TeleprompterRemote.panel(index))
                }
            }
        } else if let edit = trackEdit {
            IpadCompactModal {
                NameColorEditor(title: "Editar pista", initialName: edit.name, initialColor: edit.color, save: { name, color in
                    guard edit.project == show.snapshot.project.id else { return }
                    if edit.tracks.isEmpty {
                        show.editMasterColor(color)
                    } else if edit.nameEditable, let track = edit.tracks.first {
                        show.editTrack(track, name: name, color: color)
                    } else {
                        show.editTrackColors(edit.tracks, color: color, project: edit.project)
                    }
                }, close: { trackEdit = nil }, nameEditable: edit.nameEditable, showsName: edit.nameEditable)
                .id(edit.id)
            }
        } else if let item = editingTextItem {
            IpadCompactModal(preferredSize: CGSize(width: 560, height: 360)) {
                TextItemEditor(text: show.current?.tracks.flatMap(\.clips).first(where: { $0.id == item })?.text ?? "",
                    apply: { show.updateTextItem(item, text: $0) }, close: { editingTextItem = nil })
            }
        } else if metronomeOpen {
            IpadCompactModal(preferredSize: CGSize(width: 620, height: 520)) {
                VStack(spacing: 0) {
                    IpadModalHeader(title: "Metronome", close: { metronomeOpen = false })
                    ScrollView { MetronomeEditor() }
                }
            }
        } else if let id = regionActions {
            IpadCompactModal(preferredSize: CGSize(width: 540, height: 520)) {
                IpadRegionActions(show: show, id: id, close: { regionActions = nil })
            }
        } else if let id = detectingRegion {
            IpadCompactModal(preferredSize: CGSize(width: 500, height: 270)) {
                IpadRegionBPMDetection(show: show, documents: documents, region: id, close: { detectingRegion = nil })
            }
        } else if let target = patch {
            IpadCompactModal(preferredSize: CGSize(width: 620, height: 540)) {
                VStack(spacing: 0) {
                    IpadModalHeader(title: "Patch", subtitle: target.track.flatMap { FXModelLookup.track($0, in: show.snapshot.project)?.name } ?? "Master", close: { patch = nil })
                    PatchEditor(show: show, track: target.track, targets: target.targets.isEmpty ? [target.track] : target.targets)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if settingsOpen {
            IpadCompactModal(preferredSize: CGSize(width: 760, height: 540)) {
                VStack(spacing: 0) {
                    IpadModalHeader(title: "Settings", close: { settingsOpen = false })
                    SettingsView(auth: auth, show: show, backend: backend)
                }
            }
        } else if exportingProject {
            IpadCompactModal(preferredSize: CGSize(width: 580, height: 400)) {
                ScrollView { PortableProjectExportView(documents: documents, close: { exportingProject = false }) }
            }
        } else if advancedOpen {
            IpadCompactModal(preferredSize: CGSize(width: 760, height: 500)) {
                AdvancedView(show: show, documents: documents, close: { advancedOpen = false })
            }
        } else if addingTrack {
            IpadCompactModal { CreateTrackEditor(show: show, close: { addingTrack = false }) }
        } else if let region = regionLoops?.clip {
            IpadCompactModal(preferredSize: CGSize(width: 680, height: 510)) {
                MultiLoopsEditor(show: show, regionID: region, close: { regionLoops = nil })
            }
        } else if let clip = itemMenu?.clip {
            IpadCompactModal(preferredSize: CGSize(width: 720, height: 600)) {
                IpadItemActions(show: show, documents: documents, item: clip, close: { itemMenu = nil })
            }
        } else if let target = fx {
            IpadCompactModal(preferredSize: CGSize(width: 980, height: 640)) {
                IpadStandaloneFXManager(show: show, track: target.track, clip: target.clip, targets: target.targets, close: { fx = nil })
            }
        }
    }

    /// Preserve imported hardware routing and let the user choose a connected
    /// output explicitly. Cache this check on edits/device changes, not meters.
    private func inspectOutputRoutes() {
        guard audio.channels > 0 else { missingOutput = nil; return }
        let unavailable: ([OutputPatch]) -> Bool = { patches in
            patches.contains { $0.firstChannel > 0 && $0.firstChannel + $0.channelCount - 1 > audio.channels }
        }
        if unavailable(show.snapshot.project.masterOutputPatches) {
            missingOutput = .init(track: nil)
        } else if let track = show.current?.tracks.first(where: { unavailable($0.outputPatches) }) {
            missingOutput = .init(track: track.id)
        } else { missingOutput = nil }
    }
}

/// Native iPad item actions share the desktop editing and effects paths.
@MainActor private struct IpadItemActions: View {
    @ObservedObject var show: ShowController
    let documents: ProjectDocuments
    let item: UUID
    let close: () -> Void
    @State private var normalize = false
    @State private var editingText = false
    @State private var fx = false
    private var track: Track? { show.current?.tracks.first { $0.clips.contains { $0.id == item } } }
    private var clip: AudioClip? { track?.clips.first { $0.id == item } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(clip?.name ?? "—").font(.jarasHeadline).lineLimit(2)
                    Spacer(); Button("Close") { close() }
                }.padding(.bottom, 6)
                if let clip {
                    if clip.midi == nil && !clip.isImage && !((track?.kind.isText ?? false) && !clip.isProjectionMedia) {
                        HStack {
                            Text("Tuner"); Spacer()
                            Button { show.setItemPitch(item, semitones: max(-12, (clip.pitchSemitones ?? 0) - 1)) } label: { Image(systemName: "minus").frame(width: 36, height: 36) }
                            Text(String(format: "%+.2g st", clip.pitchSemitones ?? 0)).monospacedDigit().frame(width: 60)
                            Button { show.setItemPitch(item, semitones: min(12, (clip.pitchSemitones ?? 0) + 1)) } label: { Image(systemName: "plus").frame(width: 36, height: 36) }
                        }.padding(8).background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                    }
                    if track?.kind.isText == true && !clip.isProjectionMedia {
                        action("Edit") { editingText = true }
                    }
                    action("FX") { fx = true }
                    action(clip.muted == true ? "Unmute items" : "Mute items") { show.send(.clipMute, target: item) }
                    action("Criar região do item") { show.regionsFromSelection([item]); close() }
                    if clip.midi == nil && !clip.isImage && (clip.audioFile ?? track?.audioFile) != nil {
                        action("Normalize…") { normalize = true }
                    }
                    Button("Delete", role: .destructive) { show.deleteItems([item]); close() }
                        .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.bordered)
                }
            }.padding(22)
        }.background(RemoteSurface.background)
            .overlay {
                if editingText { IpadCompactModal {
                    TextItemEditor(text: clip?.text ?? "", apply: { show.updateTextItem(item, text: $0) }, close: { editingText = false })
                } } else if normalize { IpadCompactModal {
                    ItemNormalizationEditor(show: show, documents: documents, items: [item], close: { normalize = false })
                } } else if fx { IpadCompactModal(preferredSize: CGSize(width: 980, height: 640)) {
                    IpadStandaloneFXManager(show: show, track: nil, clip: item, targets: [], close: { fx = false })
                } }
            }

    }
    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(LocalizedStringKey(title)).frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
        }.buttonStyle(StageButtonStyle(color: JarasTheme.panel))
    }

}

/// Track, master and item effects share the same Add / bypass / Remove manager.
@MainActor private struct IpadStandaloneFXManager: View {
    @ObservedObject var show: ShowController
    let track: UUID?
    let clip: UUID?
    let targets: [UUID?]
    let close: () -> Void
    @State private var selected: String?
    @State private var adding = false
    private var settings: NativeFXSettings { clip.map(show.clipFXSettings) ?? show.fxSettings(track) }
    private var effects: [String] { (clip == nil ? settings.effectKeys : settings.clipEffectKeys).filter { settings.kind(of: $0) != "Instruments" } }
    private var targetName: String {
        if let clip { return FXModelLookup.clip(clip, in: show.snapshot.project)?.name ?? "—" }
        return track.flatMap { FXModelLookup.track($0, in: show.snapshot.project)?.name } ?? "Master"
    }
    var body: some View {
        VStack(spacing: 12) {
            IpadModalHeader(title: "FX Manager", subtitle: targetName, close: close)
            HStack(spacing: 10) {
                VStack(spacing: 8) {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(effects, id: \.self) { effect in
                                HStack(spacing: 3) {
                                    Button("By") {
                                        if let clip { show.toggleClipFXBypass(clip, effect: effect) }
                                        else { show.toggleFXBypass(track, effect: effect) }
                                    }.frame(width: 36, height: 38).background(settings.isEnabled(effect) ? Color.white.opacity(0.12) : Color.red)
                                    Button { selected = effect } label: {
                                        Text(LocalizedStringKey(settings.kind(of: effect)))
                                            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading).contentShape(Rectangle())
                                    }
                                }.font(.jarasSystem(size: 12, weight: .semibold)).buttonStyle(.plain)
                                    .background(selected == effect ? JarasTheme.green.opacity(0.3) : Color.clear).cornerRadius(4)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Button { adding = true } label: {
                            Text("Add").frame(maxWidth: .infinity, minHeight: 38).contentShape(Rectangle())
                        }.buttonStyle(.borderedProminent).tint(JarasTheme.green)
                        Button {
                            guard let selected else { return }
                            if let clip { show.removeClipFX(clip, effect: selected) }
                            else { show.removeFX(track, effect: selected) }
                        } label: {
                            Text("Remove").frame(maxWidth: .infinity, minHeight: 38).contentShape(Rectangle())
                        }.buttonStyle(.bordered).disabled(selected == nil)
                    }.font(.jarasSystem(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                }.frame(width: 142)
                Divider()
                ScrollView {
                    if let selected, effects.contains(selected) {
                        if settings.kind(of: selected) == NativeFXSettings.stemSeparator {
                            CatStemFXEditor(show: show, track: track, clip: clip).id(selected)
                        } else {
                            FXEditor(show: show, track: track, clip: clip, clipChainEditor: true, effect: selected, close: close).id(selected)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(14)
        }.background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onAppear { selected = effects.first }
            .onChange(of: effects) { values in if !values.contains(selected ?? "") { selected = values.first } }
            .overlay {
                if adding { IpadCompactModal {
                FXInsertEditor(show: show, track: track, targets: targets.isEmpty ? [track] : targets, clip: clip,
                    inserted: { selected = $0 }, isActive: { adding }, dismiss: { adding = false })
                } }
            }
    }
}

// Local notices use the desktop's persisted appearance/template keys, but no
// NSWindow or host connection. Expiration publishes only once at its deadline.
struct TPNoticeAppearance: Codable {
    var window1 = true, window2 = true, emojiEnabled = false, cleanDisplay = true
    var emoji = "⚠️", font = "Arial"
    var scale = 100.0
    var text: UInt32 = 0xffffff, background: UInt32 = 0x000000, flash: UInt32 = 0xffdc52
}
@MainActor final class TPNoticeController: ObservableObject {
    static let shared = TPNoticeController()
    @Published var appearance: TPNoticeAppearance { didSet { persist() } }
    @Published var templates: [String] { didSet { persist() } }
    let images: [Data?]
    var draft = ""
    private var slot = -1
    @Published private(set) var message = ""
    @Published private(set) var pinned = false
    @Published private(set) var sentAt = Date.distantPast
    private(set) var remoteImage: String?
    private var deadline: Date?
    private var pausedRemaining = 20.0
    private var expiry: Task<Void, Never>?
    init() {
        let defaults = UserDefaults.standard
        appearance = defaults.data(forKey: "jaras.notices.appearance").flatMap { try? JSONDecoder().decode(TPNoticeAppearance.self, from: $0) } ?? .init()
        let stored = defaults.stringArray(forKey: "jaras.notices.templates") ?? []
        templates = (0..<3).map { stored.indices.contains($0) ? stored[$0] : "" }
        images = (0..<3).map { defaults.data(forKey: "jaras.notices.image.\($0)") }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(appearance) { UserDefaults.standard.set(data, forKey: "jaras.notices.appearance") }
        UserDefaults.standard.set(templates, forKey: "jaras.notices.templates")
    }
    var active: Bool { !message.isEmpty || remoteImage != nil }
    func select(_ index: Int) { slot = (-1...2).contains(index) ? index : -1 }
    func remaining() -> Double { pinned ? pausedRemaining : max(0, deadline?.timeIntervalSinceNow ?? 0) }
    @discardableResult func send() -> Bool {
        let text = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let image = slot >= 0 ? images[slot].flatMap { UIImage(data: $0) == nil ? nil : $0 } : nil
        guard !text.isEmpty || image != nil else { return false }
        remoteImage = image.map { "data:image/jpeg;base64," + $0.base64EncodedString() }
        message = text; sentAt = Date(); pausedRemaining = 20
        schedule(seconds: 20)
        return true
    }
    private func schedule(seconds: Double) {
        expiry?.cancel(); deadline = pinned ? nil : Date().addingTimeInterval(seconds)
        guard !pinned else { return }
        expiry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) } catch { return }
            self?.clear()
        }
    }
    func togglePin() {
        let remaining = active ? remaining() : 20
        pinned.toggle(); pausedRemaining = remaining
        if active { schedule(seconds: remaining) }
    }
    func clear() {
        expiry?.cancel(); expiry = nil; remoteImage = nil; deadline = nil
        message = ""; pinned = false
    }
}
#endif

#if os(iOS)
/// A viewport in seconds, independent of the selected region. Zoom preserves the
/// touched timeline point, and horizontal scrolling never changes item timing.
struct IpadTimelineFocus: Equatable {
    let id: UUID
    let position: Double
}

struct IpadTimelineViewport: Equatable {
    var start = 0.0
    var span = 60.0
    var end: Double { start + span }
    mutating func reset(duration: Double) {
        start = 0; span = min(300, max(30, duration.isFinite ? duration : 30))
    }
    mutating func follow(_ time: Double) {
        guard time.isFinite, time >= 0 else { return }
        if time < start || time > start + span / 2 { center(on: time) }
    }
    mutating func reveal(_ time: Double) {
        guard time.isFinite, time >= 0, time < start || time > end else { return }
        start = min(604800 - span, max(0, time - span * 0.25))
    }
    mutating func center(on time: Double) {
        guard time.isFinite else { return }
        start = min(604800 - span, max(0, time - span / 2))
    }
    mutating func zoom(factor: Double, centeredOn time: Double) {
        guard factor.isFinite, factor > 0, time.isFinite else { return }
        span = min(86400, max(0.25, span / factor))
        center(on: time)
    }
    mutating func pan(pixels: Double, width: Double) {
        guard pixels.isFinite, width.isFinite, width > 0 else { return }
        start = min(604800 - span, max(0, start - pixels / width * span))
    }
    mutating func zoom(factor: Double, anchor: Double) {
        guard factor.isFinite, factor > 0, anchor.isFinite else { return }
        let fraction = min(1, max(0, anchor)), position = start + fraction * span
        span = min(86400, max(0.25, span / factor))
        start = min(604800 - span, max(0, position - fraction * span))
    }
}

/// Recognizers are bounded to this grid. A horizontal drag and pinch coexist
/// with the existing vertical mixer/grid scroll synchronization; no touch layer
/// covers item buttons or the rest of the workspace.
@MainActor final class IpadTimelineGestureControl {
    weak var view: IpadTimelineGestureView?
    func cancelMotion() { view?.cancelMotion() }
}
struct IpadTimelineGestureProbe: UIViewRepresentable {
    let control: IpadTimelineGestureControl
    @Environment(\.isEnabled) private var enabled
    let pan: (Double, Double) -> Void
    let zoom: (Double, Double) -> Void
    func makeUIView(context: Context) -> IpadTimelineGestureView {
        let view = IpadTimelineGestureView(); control.view = view; return view
    }
    func updateUIView(_ view: IpadTimelineGestureView, context: Context) { view.panAction = pan; view.zoomAction = zoom; view.inputEnabled = enabled }
    static func dismantleUIView(_ view: IpadTimelineGestureView, coordinator: ()) { view.detach() }
}
final class IpadTimelineGestureView: UIView, UIGestureRecognizerDelegate {
    var inputEnabled = true { didSet { if !inputEnabled { stopInertia() } } }
    var panAction: ((Double, Double) -> Void)?
    var zoomAction: ((Double, Double) -> Void)?
    private weak var attached: UIView?
    private var inertia: CADisplayLink?
    private var zoomLink: CADisplayLink?
    private var pendingZoom = 1.0
    private var zoomAnchor = 0.5
    private final class ZoomTarget: NSObject {
        weak var view: IpadTimelineGestureView?
        init(_ view: IpadTimelineGestureView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) { view?.flushZoom() }
    }
    private func flushZoom() {
        let factor = pendingZoom; pendingZoom = 1
        if factor != 1 { zoomAction?(factor, zoomAnchor) }
    }
    private var velocityX: CGFloat = 0
    private var previousTime: CFTimeInterval = 0
    private final class TickTarget: NSObject {
        weak var view: IpadTimelineGestureView?
        init(_ view: IpadTimelineGestureView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) { view?.coast(link) }
    }
    private func stopInertia() { inertia?.invalidate(); inertia = nil; velocityX = 0; previousTime = 0 }
    private func coast(_ link: CADisplayLink) {
        guard window != nil, bounds.width > 0 else { stopInertia(); return }
        let dt = min(0.05, previousTime == 0 ? link.duration : link.timestamp - previousTime)
        previousTime = link.timestamp
        let damping = -log(Double(UIScrollView.DecelerationRate.normal.rawValue)) * 1000
        let decay = exp(-damping * dt)
        panAction?(Double(velocityX) * (1 - decay) / damping, Double(bounds.width))
        velocityX *= decay
        if abs(velocityX) < 5 { stopInertia() }
    }
    deinit { inertia?.invalidate(); zoomLink?.invalidate() }
    private lazy var panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(panChanged))
    private lazy var pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(pinchChanged))
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        guard let window else { return }
        // SwiftUI may place a background probe beside the scrolling content in
        // separate host views. A recognizer on that immediate parent never sees
        // grid touches. The window is their common ancestor; shouldReceive still
        // strictly limits recognition to this grid's initial touch rectangle.
        attached = window
        panRecognizer.delegate = self; pinchRecognizer.delegate = self
        // Two-finger pinches must not also translate the viewport on the same
        // frame; zoom owns its cursor anchor throughout that gesture.
        panRecognizer.maximumNumberOfTouches = 1
        panRecognizer.cancelsTouchesInView = false
        pinchRecognizer.cancelsTouchesInView = false
        window.addGestureRecognizer(panRecognizer); window.addGestureRecognizer(pinchRecognizer)
    }
    func cancelMotion() {
        stopInertia()
        zoomLink?.invalidate(); zoomLink = nil; pendingZoom = 1
        panRecognizer.isEnabled = false; pinchRecognizer.isEnabled = false
        panRecognizer.isEnabled = true; pinchRecognizer.isEnabled = true
    }
    func detach() {
        zoomLink?.invalidate(); zoomLink = nil; pendingZoom = 1
        stopInertia()
        attached?.removeGestureRecognizer(panRecognizer); attached?.removeGestureRecognizer(pinchRecognizer); attached = nil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Decide from the initial touch, before a divider drag crosses into the
        // grid. Testing only at shouldBegin would steal a neighboring handle.
        guard inputEnabled, bounds.contains(touch.location(in: self)) else { return false }
        if gestureRecognizer === panRecognizer && touch.location(in: self).y < 48 { return false }
        stopInertia()
        var touched = touch.view
        while let view = touched {
            if view is UIControl { return false }
            if view === attached { break }
            touched = view.superview
        }
        return true
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard bounds.contains(gestureRecognizer.location(in: self)) else { return false }
        if gestureRecognizer === panRecognizer {
            let velocity = panRecognizer.velocity(in: self)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    @objc private func panChanged(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began: stopInertia()
        case .changed, .ended:
            panAction?(Double(recognizer.translation(in: self).x), Double(bounds.width))
            recognizer.setTranslation(.zero, in: self)
            if recognizer.state == .ended {
                velocityX = recognizer.velocity(in: self).x
                if abs(velocityX) > 5 {
                    let link = CADisplayLink(target: TickTarget(self), selector: #selector(TickTarget.tick(_:)))
                    inertia = link; link.add(to: .main, forMode: .common)
                }
            }
        case .cancelled, .failed: stopInertia()
        default: break
        }
    }
    @objc private func pinchChanged(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .began {
            stopInertia(); pendingZoom = 1
            zoomLink?.invalidate()
            let link = CADisplayLink(target: ZoomTarget(self), selector: #selector(ZoomTarget.tick(_:)))
            link.preferredFramesPerSecond = 60
            zoomLink = link; link.add(to: .main, forMode: .common)
        }
        if [.began, .changed, .ended].contains(recognizer.state), bounds.width > 0 {
            pendingZoom *= Double(recognizer.scale)
            zoomAnchor = Double(recognizer.location(in: self).x / bounds.width)
            recognizer.scale = 1
        }
        if [.ended, .cancelled, .failed].contains(recognizer.state) {
            flushZoom(); zoomLink?.invalidate(); zoomLink = nil
        }
    }
}
/// Region touches are native recognizers: a double tap is not swallowed by
/// SwiftUI's sequenced long-press/drag gesture, and dragging uses window space.
struct IpadRegionMovePreview: Equatable { let id: UUID; let start: Double }

struct IpadTrackControlsBoundsKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}

/// Dragging the grip is a direct gesture, not a system drag-and-drop session.
/// The scroll view yields only touches starting on the grip. All destination
/// validation and the single undoable subtree move use the desktop controller.
struct IpadTrackReorderModifier: ViewModifier {
    let show: ShowController?
    let track: UUID
    let enabled: Bool
    let controller: IpadTrackReorderController
    @ViewBuilder func body(content: Content) -> some View {
        if enabled, let show, show.current?.tracks.contains(where: { $0.id == track && $0.kind == .standard }) == true {
            content.overlay {
                GeometryReader { geometry in
                    IpadTrackReorderSurface(show: show, track: track, controller: controller, rowWidth: geometry.size.width)
                        .frame(width: 36)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
        } else { content }
    }
}

@MainActor final class IpadTrackReorderController: ObservableObject {
    private final class Row {
        weak var view: IpadTrackReorderView?
        init(_ view: IpadTrackReorderView) { self.view = view }
    }
    private var rows: [ObjectIdentifier: Row] = [:]
    private weak var source: IpadTrackReorderView?
    private weak var destination: IpadTrackReorderView?
    private weak var scroll: UIScrollView?
    private var point = CGPoint.zero
    private var below = false
    private var clock: CADisplayLink?
    private var previousTime: CFTimeInterval = 0
    @MainActor private final class TickTarget {
        weak var owner: IpadTrackReorderController?
        init(_ owner: IpadTrackReorderController) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { owner?.scrollTick(link) }
    }
    fileprivate func register(_ view: IpadTrackReorderView) { rows[ObjectIdentifier(view)] = Row(view) }
    fileprivate func unregister(_ view: IpadTrackReorderView) {
        rows.removeValue(forKey: ObjectIdentifier(view))
        if source === view { cancel() }
        if destination === view { destination = nil }
    }
    fileprivate func begin(_ view: IpadTrackReorderView, point: CGPoint) {
        cancel()
        source = view; scroll = view.enclosingScrollView
        scroll?.setContentOffset(scroll?.contentOffset ?? .zero, animated: false)
        view.grip.tintColor = .systemGreen
        self.point = point; updateDestination()
        previousTime = 0
        let link = CADisplayLink(target: TickTarget(self), selector: #selector(TickTarget.tick(_:)))
        link.preferredFramesPerSecond = 30
        clock = link; link.add(to: .main, forMode: .common)
    }
    fileprivate func move(to point: CGPoint) { self.point = point; updateDestination() }
    fileprivate func end(at point: CGPoint) {
        self.point = point; updateDestination()
        let sourceID = source?.track, targetID = destination?.track, show = source?.show, after = below
        cancel()
        guard let sourceID, let targetID, let show, let tracks = show.current?.tracks,
              show.canDropTrack(sourceID, on: targetID, after: after),
              let index = tracks.firstIndex(where: { $0.id == targetID }) else { return }
        let before = after ? (index + 1 < tracks.count ? tracks[index + 1].id : nil) : targetID
        show.dropTrack(sourceID, on: targetID, before: before)
    }
    func cancel() {
        clock?.invalidate(); clock = nil
        source?.grip.tintColor = .white
        destination?.showInsertion(after: nil)
        source = nil; destination = nil; scroll = nil
    }
    private func updateDestination() {
        destination?.showInsertion(after: nil); destination = nil
        guard let source, let window = source.window, let scroll, let sourceID = source.track, let show = source.show else { return }
        let viewport = scroll.convert(scroll.bounds, to: window)
        guard point.x >= viewport.minX - 40, point.x <= viewport.maxX + 40 else { return }
        let y = min(viewport.maxY - 1, max(viewport.minY + 1, point.y))
        for row in rows.values {
            guard let view = row.view, view.window === window, let target = view.track else { continue }
            let frame = view.convert(view.bounds, to: window)
            guard y >= frame.minY, y < frame.maxY else { continue }
            let after = y >= frame.midY
            guard show.canDropTrack(sourceID, on: target, after: after) else { return }
            destination = view; below = after; view.showInsertion(after: after)
            return
        }
    }
    private func scrollTick(_ link: CADisplayLink) {
        guard let source, let window = source.window, let scroll else { cancel(); return }
        let dt = min(0.05, previousTime == 0 ? link.duration : link.timestamp - previousTime)
        previousTime = link.timestamp
        let viewport = scroll.convert(scroll.bounds, to: window)
        let margin: CGFloat = min(44, viewport.height / 4)
        let speed: CGFloat
        if point.y < viewport.minY + margin { speed = -min(1, (viewport.minY + margin - point.y) / margin) * 260 }
        else if point.y > viewport.maxY - margin { speed = min(1, (point.y - viewport.maxY + margin) / margin) * 260 }
        else { return }
        let lower = -scroll.adjustedContentInset.top
        let upper = max(lower, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let offset = min(upper, max(lower, scroll.contentOffset.y + speed * dt))
        if offset != scroll.contentOffset.y {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
            updateDestination()
        }
    }
    deinit { clock?.invalidate() }
}

private struct IpadTrackReorderSurface: UIViewRepresentable {
    let show: ShowController
    let track: UUID
    let controller: IpadTrackReorderController
    let rowWidth: CGFloat
    func makeUIView(context: Context) -> IpadTrackReorderView { IpadTrackReorderView() }
    func updateUIView(_ view: IpadTrackReorderView, context: Context) {
        view.show = show; view.track = track; view.controller = controller
        view.rowWidth = rowWidth
        controller.register(view)
    }
    static func dismantleUIView(_ view: IpadTrackReorderView, coordinator: ()) { view.controller?.unregister(view) }
}
private final class IpadTrackReorderView: UIControl, UIGestureRecognizerDelegate {
    weak var show: ShowController?
    var track: UUID?
    weak var controller: IpadTrackReorderController?
    var rowWidth: CGFloat = 0 { didSet { if oldValue != rowWidth { setNeedsLayout() } } }
    let grip = UIImageView(image: UIImage(systemName: "line.3.horizontal"))
    private let insertion = CALayer()
    private var insertionAfter: Bool?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    var enclosingScrollView: UIScrollView? {
        var parent = superview
        while let view = parent {
            if let scroll = view as? UIScrollView { return scroll }
            parent = view.superview
        }
        return nil
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        grip.contentMode = .center; grip.tintColor = .white; addSubview(grip)
        insertion.backgroundColor = UIColor.systemGreen.cgColor; insertion.isHidden = true
        layer.addSublayer(insertion)
        pan.maximumNumberOfTouches = 1; pan.delegate = self; addGestureRecognizer(pan)
        isAccessibilityElement = true; accessibilityLabel = JarasLocalization.string("Move track")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { controller?.unregister(self) }
        else { controller?.register(self); enclosingScrollView?.panGestureRecognizer.require(toFail: pan) }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point) && point.x >= bounds.maxX - 36
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        grip.frame = CGRect(x: bounds.maxX - 32, y: 0, width: 30, height: bounds.height)
        layoutInsertion()
    }
    func showInsertion(after: Bool?) { insertionAfter = after; layoutInsertion() }
    private func layoutInsertion() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        insertion.isHidden = insertionAfter == nil
        insertion.frame = CGRect(x: bounds.width - rowWidth, y: insertionAfter == true ? max(0, bounds.height - 2) : 0, width: rowWidth, height: 2)
        CATransaction.commit()
    }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: window)
        switch gesture.state {
        case .began: controller?.begin(self, point: point)
        case .changed: controller?.move(to: point)
        case .ended: controller?.end(at: point)
        case .cancelled, .failed: controller?.cancel()
        default: break
        }
    }
}

struct IpadItemResizePreview {
    let original: AudioClip
    var candidate: AudioClip
    let secondsPerPoint: Double
}
/// A control excludes resizing from the grid pan/pinch and item-menu recognizers.
struct IpadItemResizeHandle: UIViewRepresentable {
    let left: Bool
    let changed: (Double, Bool, Bool) -> Void
    func makeUIView(context: Context) -> IpadItemResizeControl { IpadItemResizeControl() }
    func updateUIView(_ view: IpadItemResizeControl, context: Context) {
        view.changed = changed
        view.accessibilityLabel = JarasLocalization.string(left ? "Item start" : "Item end")
    }
}
final class IpadItemResizeControl: UIControl, UIGestureRecognizerDelegate {
    var changed: ((Double, Bool, Bool) -> Void)?
    private let grip = CALayer()
    private lazy var drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        grip.backgroundColor = UIColor.white.cgColor
        grip.cornerRadius = 2; layer.addSublayer(grip)
        drag.delegate = self
        addGestureRecognizer(drag)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === drag else { return true }
        let velocity = drag.velocity(in: window ?? self)
        return abs(velocity.x) > abs(velocity.y)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        var parent = superview
        while let view = parent {
            if let scroll = view as? UIScrollView { scroll.panGestureRecognizer.require(toFail: drag); break }
            parent = view.superview
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        grip.frame = CGRect(x: bounds.midX - 2, y: 3, width: 4, height: max(0, bounds.height - 6))
        CATransaction.commit()
    }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed: changed?(Double(gesture.translation(in: window).x), false, false)
        case .ended: changed?(Double(gesture.translation(in: window).x), true, false)
        case .cancelled, .failed: changed?(0, true, true)
        default: break
        }
    }
}

struct IpadTrackSelectionSurface: UIViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    let excluded: [CGRect]
    let name: String
    let selected: Bool
    var holdEnabled = true
    let tap: () -> Void
    let hold: () -> Void
    func makeUIView(context: Context) -> IpadTrackSelectionTouchView { IpadTrackSelectionTouchView() }
    func updateUIView(_ view: IpadTrackSelectionTouchView, context: Context) {
        view.excluded = excluded; view.tap = tap; view.hold = hold
        view.selectionEnabled = enabled
        view.holdEnabled = holdEnabled
        view.accessibilityLabel = name
        view.accessibilityTraits = selected ? [.button, .selected] : [.button]
    }
}
final class IpadTrackSelectionTouchView: UIView, UIGestureRecognizerDelegate {
    var excluded: [CGRect] = []
    var tap: (() -> Void)?
    var hold: (() -> Void)?
    private lazy var tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
    private lazy var holdRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
    var selectionEnabled = true { didSet { updateEnabled() } }
    var holdEnabled = true { didSet { updateEnabled() } }
    private func updateEnabled() {
        tapRecognizer.isEnabled = selectionEnabled
        holdRecognizer.isEnabled = selectionEnabled && holdEnabled
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isAccessibilityElement = true
        holdRecognizer.minimumPressDuration = 0.5; holdRecognizer.allowableMovement = 12
        for recognizer in [tapRecognizer, holdRecognizer] {
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
        }
        tapRecognizer.require(toFail: holdRecognizer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        for recognizer in [tapRecognizer, holdRecognizer] where recognizer.view !== window {
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // A representable over SwiftUI controls can consume their hit on iOS 16
        // even when its own view rejects it. Observe the window from behind the
        // row instead; this surface must never be a touch target itself.
        false
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard selectionEnabled, window != nil, !isHidden, alpha > 0 else { return false }
        let point = touch.location(in: self)
        guard bounds.contains(point), !excluded.contains(where: { $0.contains(point) }) else { return false }
        var ancestor = superview
        while let view = ancestor {
            if view.isHidden || view.alpha == 0 { return false }
            if view.clipsToBounds && !view.bounds.contains(touch.location(in: view)) { return false }
            ancestor = view.superview
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        !(otherGestureRecognizer is UIPanGestureRecognizer) && !(otherGestureRecognizer is UILongPressGestureRecognizer)
    }
    override func accessibilityActivate() -> Bool { tap?(); return true }
    @objc private func tapped() { tap?() }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { hold?() }
    }
}

struct IpadRegionHeaderGesture: UIViewRepresentable {
    let singleTap: () -> Void
    let doubleTap: () -> Void
    let moved: (Double) -> Void
    let ended: (Bool) -> Void
    func makeUIView(context: Context) -> IpadRegionHeaderTouchView { IpadRegionHeaderTouchView() }
    func updateUIView(_ view: IpadRegionHeaderTouchView, context: Context) {
        view.singleTap = singleTap; view.doubleTap = doubleTap; view.moved = moved; view.ended = ended
    }
}
final class IpadRegionHeaderTouchView: UIView {
    var singleTap: (() -> Void)?
    var doubleTap: (() -> Void)?
    var moved: ((Double) -> Void)?
    var ended: ((Bool) -> Void)?
    private var origin: CGFloat?
    override init(frame: CGRect) {
        super.init(frame: frame)
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped)); double.numberOfTapsRequired = 2
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35; hold.allowableMovement = 12
        single.require(toFail: double); single.require(toFail: hold); double.require(toFail: hold)
        addGestureRecognizer(single); addGestureRecognizer(double); addGestureRecognizer(hold)
        isAccessibilityElement = true; accessibilityLabel = JarasLocalization.string("Editar região")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityActivate() -> Bool { doubleTap?(); return true }
    @objc private func tapped() { singleTap?() }
    @objc private func doubleTapped() { doubleTap?() }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began: origin = gesture.location(in: window).x; moved?(0)
        case .changed:
            if let origin { moved?(Double(gesture.location(in: window).x - origin)) }
        case .ended: origin = nil; ended?(false)
        case .cancelled, .failed:
            if origin != nil { origin = nil; ended?(true) }
        default: break
        }
    }
}

/// One desktop-style panel directly on the workspace. No UIKit sheet behind it.
struct IpadCompactModal<Content: View>: View {
    var preferredSize: CGSize? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.58).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { }
                if let preferredSize {
                    card.frame(width: min(preferredSize.width, max(1, geometry.size.width - 32)),
                               height: min(preferredSize.height, max(1, geometry.size.height - 32)))
                } else {
                    ScrollView {
                        card.padding(16).frame(maxWidth: .infinity)
                    }.fixedSize(horizontal: false, vertical: true)
                        .frame(maxHeight: max(1, geometry.size.height - 16))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.accessibilityAddTraits(.isModal)
    }
    private var card: some View {
        content()
            .font(.jarasSystem(size: 13)).tint(JarasTheme.green)
            .buttonStyle(IpadDialogButtonStyle())
            .foregroundStyle(JarasTheme.text).preferredColorScheme(.dark)
            .background(RemoteSurface.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.24)))
            .shadow(color: .black.opacity(0.65), radius: 24, y: 12)
    }
}
struct IpadModalHeader: View {
    let title: String
    var subtitle: String? = nil
    let close: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(JarasTheme.green).frame(width: 3, height: 20)
            Text(LocalizedStringKey(title)).font(.jarasSystem(size: 15, weight: .semibold))
            if let subtitle { Text(verbatim: subtitle).foregroundStyle(JarasTheme.secondary).lineLimit(1) }
            Spacer(minLength: 8)
            Button(action: close) { Image(systemName: "xmark").frame(width: 36, height: 36).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("Close")
        }.padding(.horizontal, 16).padding(.vertical, 5)
            .background(RemoteSurface.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(JarasTheme.line).frame(height: 1) }
    }
}
struct IpadDialogButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.jarasSystem(size: 13, weight: .semibold))
            .padding(.horizontal, 12).frame(minHeight: 36)
            .foregroundStyle(enabled ? JarasTheme.text : JarasTheme.secondary.opacity(0.5))
            .background(LinearGradient(colors: [Color(white: configuration.isPressed ? 0.18 : 0.32), Color(white: 0.19)], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(configuration.isPressed ? JarasTheme.green : Color.white.opacity(0.20)))
            .contentShape(Rectangle())
    }
}

@MainActor struct IpadAudioTransportButtons: View {
    let show: ShowController
    var configureMetronome: (() -> Void)?
    var only: IpadTransportControl? = nil
    var controlWidth: CGFloat? = nil
    @ObservedObject private var recorder = TrackRecording.shared
    @ObservedObject private var metronome = MetronomeSettings.shared
    var body: some View {
        HStack(spacing: 4) {
            if only == nil || only == .record {
            Button { recorder.toggle(show: show) } label: {
                Label("REC", systemImage: recorder.recording ? "stop.circle.fill" : "record.circle")
            }.buttonStyle(TransportButtonStyle(color: .red, active: recorder.recording, fontSize: 10, width: controlWidth ?? 47, height: 28))
                .modifier(JarasBlink(active: recorder.recording, interval: 0.4, lowOpacity: 0.05))
                .disabled(recorder.busy).accessibilityLabel("Record")
            }
            if only == nil || only == .metronome {
            Button { metronome.enabled.toggle() } label: { Image(systemName: "metronome") }
                .buttonStyle(TransportButtonStyle(color: metronome.enabled ? JarasTheme.yellow : JarasTheme.panel, active: metronome.enabled, fontSize: 12, width: controlWidth ?? 30, height: 28))
                .accessibilityLabel("Metronome").accessibilityValue(metronome.enabled ? "On" : "Off")
                .contextMenu { Button("Settings") { configureMetronome?() } }
            }
        }
    }
}

@MainActor private struct IpadRegionActions: View {
    @ObservedObject var show: ShowController
    let id: UUID
    let close: () -> Void
    @State private var editing = false
    @State private var unifying = false
    @State private var deleting = false
    @State private var name = ""
    private var region: Part? { show.current?.parts.first { $0.id == id } }
    private var canUnify: Bool {
        guard let region, let song = show.current else { return false }
        return song.parts.contains { $0.id != id && $0.parentRegionID == nil && $0.startTime < region.endTime && $0.endTime > region.startTime }
    }
    var body: some View {
        VStack(spacing: 14) {
            IpadModalHeader(title: "Editar região", subtitle: region?.name, close: close)
            if let region {
                if editing {
                    NameColorEditor(title: "Editar região", initialName: region.name, initialColor: region.color ?? 0x705264, save: { name, color in
                        show.editRegion(id, name: name, color: color, uppercaseName: region.usesUppercase); close()
                    }, close: close)
                } else if unifying {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    Button("Unify") { if show.unifyRegions(containing: id, name: name) { close() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("Edit song") { editing = true }
                    if canUnify { Button("Unify regions") { name = ""; unifying = true } }
                    Button("Delete region", role: .destructive) { deleting = true }
                }
            }
        }.buttonStyle(.bordered).padding(18)
            .confirmationDialog("Delete region", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete region", role: .destructive) { show.deleteRegion(id, playlist: nil); close() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The region and its contents will be deleted.") }
    }
}

@MainActor private struct IpadRegionBPMDetection: View {
    let show: ShowController
    let documents: ProjectDocuments
    let region: UUID
    let close: () -> Void
    @State private var working = false
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Detect BPM from the Click track?").font(.jarasHeadline)
            if working { ProgressView("Detecting BPM…") }
            else {
                if !error.isEmpty { Text(verbatim: error).foregroundStyle(.red) }
                HStack { Button("Cancel", action: close); Spacer(); Button("Detect BPM", action: detect) }
                    .buttonStyle(.bordered)
            }
        }.padding(24)
    }
    private func detect() {
        guard !working, let song = show.current, let part = song.parts.first(where: { $0.id == region }),
              let directory = documents.currentURL?.deletingLastPathComponent() else { return }
        let project = show.snapshot.project.id, revision = show.projectRevision
        working = true
        Task {
            defer { working = false }
            do {
                let detection = try await Task.detached(priority: .utility) {
                    try ClickTempoDetector.markersWithMeter(song: song, region: part) { file in
                        try TimelineAudioWaveform.clickTransients(directory.appendingPathComponent(file.path)).map {
                            ClickTempoDetector.Transient(position: $0.position, peak: $0.peak, shape: $0.shape)
                        }
                    }
                }.value
                guard show.snapshot.project.id == project, show.current?.id == song.id, show.projectRevision == revision else { close(); return }
                guard !detection.markers.isEmpty else { error = JarasLocalization.string("No stable click tempo was found."); return }
                if show.applyDetectedTempo(detection.markers, project: project, song: song.id, region: region) { close() }
                else { error = JarasLocalization.string(show.message) }
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
