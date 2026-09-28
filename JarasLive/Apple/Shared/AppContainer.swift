import Foundation
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif
@MainActor final class AppContainer: ObservableObject {
    let auth: AuthService, show: ShowController, backend: MockBackendClient
    @Published private(set) var starting = true
    @Published private(set) var startupProgress = 0.1
    @Published private(set) var startupStage = "Carregando projeto…"
    private var started = false
    private var armedInstrumentObservation: AnyCancellable?
    let documents: ProjectDocuments
    let preview: Bool
    init(preview: Bool = false) throws {
        self.preview = preview
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JarasLive", isDirectory: true)
        backend = MockBackendClient(file: preview ? nil : folder.appendingPathComponent("mock-server.json"))
        let store: any SecureStore = preview ? MemorySecureStore() : KeychainStore(service: "com.hookdeveloper.jaraslive")
        #if os(macOS)
        let platform = "macOS", name = Host.current().localizedName ?? "Mac", feature = "desktop"
        #else
        let platform = "iPadOS", name = UIDevice.current.name, feature = "standalone_mobile"
        #endif
        // A Keychain failure must be visible; never replace the installation silently.
        do {
            let device = try DeviceAuthorizationService.installation(store: store, name: name, platform: platform)
            auth = AuthService(backend: backend, store: store, installation: device, feature: feature)
            let persistence = DocumentProjectStore()
            show = try ShowController(executor: LocalCommandExecutor(), persistence: persistence, initialProject: preview ? .demo() : .empty(name: "Untitled"), cursorMemory: preview ? nil : ProjectCursorMemory())
            documents = ProjectDocuments(store: persistence, show: show, preview: preview)
        } catch { throw error }
        auth.isPlaying = { [weak show] in show?.isPlaying ?? false }
        auth.onPendingRevocation = { [weak show] pending in show?.finishCurrentSong(pending) }
        show.canExecute = { [weak auth] in preview || auth?.allowed == true }
        if !preview {
            let audio = StemAudioPlayback.shared
            armedInstrumentObservation = TrackRecording.shared.$armed.sink { audio.setArmedInstrumentTracks($0) }
            audio.instrumentFile = { id in
                guard let instrument = InstrumentLibrary.catalog.first(where: { $0.id == id }), InstrumentLibrary.shared.downloaded.contains(id) else { return nil }
                return (InstrumentLibrary.shared.file(id),instrument.percussion)
            }
            show.audioUpdate = { [weak show] snapshot, revision in
                do {
                    try audio.update(snapshot, revision: revision); TrackRecording.shared.observe(snapshot); VideoPlayback.shared.update(snapshot)
                    #if os(macOS)
                    TeleprompterWindow.shared.update(snapshot, revision: show?.projectRevision ?? revision)
                    #endif
                }
                catch { show?.message = error.localizedDescription }
            }
            #if os(macOS)
            show.onProjectEdited = { [weak show] in if let show { FXWindows.shared.synchronize(show: show) } }
            show.onSetlistEdited = { [weak show] in
                guard let show else { return }
                TeleprompterWindow.shared.invalidatePreview()
                TeleprompterWindow.shared.update(show.snapshot, revision: show.projectRevision)
            }
            #endif
            show.audioFX = { audio.previewFX($0, settings: $1) }
            show.audioClipFX = { audio.previewClipFX($0, settings: $1) }
            show.audioClipFXBypass = { audio.previewClipFXBypass($0, bypassed: $1) }
            show.audioItemGain = { audio.previewItemGain($0, gain: $1) }
            show.audioVolume = { audio.previewVolume($0, gain: $1) }
            show.audioPan = { audio.previewPan($0, pan: $1) }
            show.audioMute = { [weak show] track, muted in
                audio.previewMute(track, muted: muted)
                if let track, let show, show.current?.tracks.first(where: { $0.id == track })?.kind == .timecode { audio.updateTimecode(show.snapshot) }
            }
            show.audioSolo = { audio.previewSolo($0, solo: $1) }
            show.audioClipMute = { audio.previewClipMute($0, muted: $1) }
            #if os(macOS)
            show.prepareForSave = { [weak show] in if let show { ExternalPluginState.captureAll(show: show) } }
            #endif
            show.audioRouting = { audio.previewRouting($0) }
            show.audioPatches = { [weak show] track, patches in
                audio.previewPatches(track, patches: patches)
                if let track, let show, show.current?.tracks.first(where: { $0.id == track })?.kind == .timecode { audio.updateTimecode(show.snapshot) }
            }
            show.audioPatch = { [weak show] track, patch, slot in
                audio.previewPatch(track, patch: patch, slot: slot)
                if let track, let show, show.current?.tracks.first(where: { $0.id == track })?.kind == .timecode { audio.updateTimecode(show.snapshot) }
            }
            show.audioMIDIInput = { audio.previewMIDIInput($0, slot: $1) }
            audio.prepareAfterDeviceChange = { [weak show] in show?.preparePlayback() }
            #if os(macOS)
            audio.beforeAudioGraphReset = { [weak show] in
                if let show { ExternalPluginState.captureAll(show: show) }
                FXWindows.shared.suspendAudioEditors()
            }
            audio.afterAudioGraphReset = { FXWindows.shared.restoreAudioEditors() }
            #endif
            audio.onError = { [weak show] error in show?.message = error.localizedDescription }
        }
        show.onStop = { [weak auth] in auth?.transportDidStop() }
    }
    func start() async {
        guard !preview else { starting = false; return }
        guard !started else { return }
        started = true
        let splashStarted = ProcessInfo.processInfo.systemUptime
        startupProgress = 0.15
        await Task.yield()
        // A document is loaded only after an explicit choice in the project launcher.
        startupProgress = 0.55
        startupStage = "Validando acesso…"
        await auth.restore()
        startupProgress = 1
        startupStage = "Pronto"
        // Temporary four-second minimum requested for reviewing the splash artwork.
        let remaining = max(0, 4 - (ProcessInfo.processInfo.systemUptime - splashStarted))
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        starting = false
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            if auth.allowed { await auth.revalidate() }
        }
    }
}
