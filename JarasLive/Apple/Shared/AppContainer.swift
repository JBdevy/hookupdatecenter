import Foundation
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif
@MainActor final class AppContainer: ObservableObject {
    let auth: AuthService, show: ShowController
    let backend: any BackendClient
    @Published private(set) var starting = true
    @Published private(set) var startupProgress = 0.1
    @Published private(set) var startupStage = "Carregando projeto…"
    private var started = false
    private var armedInstrumentObservation: AnyCancellable?
    let documents: ProjectDocuments
    let preview: Bool
    init(preview: Bool = false) throws {
        self.preview = preview
        backend = preview ? MockBackendClient() : RemoteBackendClient(baseURL: URL(string: "https://backcatlive.up.railway.app")!)
        let store: any SecureStore = preview ? MemorySecureStore() : KeychainStore(service: "com.hookdeveloper.jaraslive")
        #if os(macOS)
        let platform = "macOS", name = Host.current().localizedName ?? "Mac", feature = "desktop"
        #else
        let platform = "iPadOS", name = UIDevice.current.name, feature = "standalone_mobile"
        #endif
        // A Keychain failure must be visible; never replace the installation silently.
        do {
            let device = try DeviceAuthorizationService.installation(store: store, name: name, platform: platform)
            auth = AuthService(backend: backend, store: store, installation: device, feature: feature, verifier: preview ? nil : .production)
            let persistence = DocumentProjectStore()
            show = try ShowController(executor: LocalCommandExecutor(), persistence: persistence, initialProject: preview ? .demo() : .empty(name: "Untitled"), cursorMemory: preview ? nil : ProjectCursorMemory())
            documents = ProjectDocuments(store: persistence, show: show, preview: preview)
        } catch { throw error }
        auth.isPlaying = { [weak show] in show?.isPlaying ?? false }
        auth.onPendingRevocation = { [weak show] pending in show?.finishCurrentSong(pending) }
        #if os(iOS)
        // The iPad preview runs locally without account or license checks.
        show.canExecute = { true }
        #else
        show.canExecute = { [weak auth] in preview || auth?.allowed == true }
        #endif
        #if os(macOS)
        show.toggleVideoWindow = { VideoPlayback.shared.toggle() }
        show.toggleTeleprompterWindow = { [weak show] in
            if let show { TeleprompterWindow.shared.toggle(show: show) }
        }
        #endif
        if !preview {
            let audio = StemAudioPlayback.shared
            #if os(macOS)
            AudioLicenseAccess.shared.setAllowed(false)
            audio.setLicenseAllowed(false)
            auth.onAudioAuthorization = { [weak show] allowed in
                AudioLicenseAccess.shared.setAllowed(allowed)
                audio.setLicenseAllowed(allowed)
                if !allowed {
                    show?.send(.stopAll)
                    TrackRecording.shared.finish()
                }
            }
            #endif
            TrackRecording.shared.bind(show)
            armedInstrumentObservation = TrackRecording.shared.$armed.sink { [weak show] _ in
                // Published state is sent before the REC button redraws. Queue
                // graph changes after the click, and only wake live instruments.
                Task { @MainActor [weak show] in
                    guard let show else { return }
                    let instruments = Set(show.snapshot.project.songs.flatMap(\.tracks).filter { track in
                        track.fx?.instrumentKeys.isEmpty == false || (track.fx?.externalPlugins?.contains { $0.category.contains("Instrument") } ?? false)
                    }.map(\.id))
                    audio.setArmedInstrumentTracks(TrackRecording.shared.armed.intersection(instruments))
                }
            }
            audio.instrumentFile = { id in
                guard let instrument = InstrumentLibrary.catalog.first(where: { $0.id == id }), InstrumentLibrary.shared.downloaded.contains(id) else { return nil }
                return (InstrumentLibrary.shared.file(id),instrument.percussion)
            }
            show.selectedLoopArea = { [weak show] in
                guard let area = TimelineAreaSelection.shared.range, area.song == show?.snapshot.transport.songId else { return nil }
                return area.start...area.end
            }
            var repeatWasEnabled = show.snapshot.transport.loop.enabled
            show.audioUpdate = { [weak show] snapshot, revision in
                let repeatEnabled = snapshot.transport.loop.enabled
                if repeatWasEnabled && !repeatEnabled { TimelineAreaSelection.shared.clear() }
                repeatWasEnabled = repeatEnabled
                do {
                    try audio.update(snapshot, revision: revision); TrackRecording.shared.observe(snapshot); VideoPlayback.shared.update(snapshot)
                    if repeatEnabled, let start = snapshot.transport.loop.start, let end = snapshot.transport.loop.end, let song = snapshot.transport.songId {
                        TimelineAreaSelection.shared.update(song: song, from: start, to: end)
                    }
                    #if os(macOS)
                    TeleprompterWindow.shared.update(snapshot, revision: show?.projectRevision ?? revision)
                    TeleprompterWindow.second.update(snapshot, revision: show?.projectRevision ?? revision)
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
                TeleprompterWindow.second.invalidatePreview()
                TeleprompterWindow.second.update(show.snapshot, revision: show.projectRevision)
            }
            #endif
            show.audioFX = { audio.previewFX($0, settings: $1) }
            show.audioClipFX = { audio.previewClipFX($0, settings: $1) }
            show.audioClipFXBypass = { audio.previewClipFXBypass($0, bypassed: $1) }
            show.audioItemFade = { audio.previewItemFade($0, fadeIn: $1, seconds: $2) }
            show.audioItemGain = { audio.previewItemGain($0, gain: $1) }
            show.audioItemChannelMode = { audio.previewItemChannelMode($0, mode: $1) }
            show.audioItemNormalization = { audio.previewItemNormalization($0, gain: $1) }
            show.audioVolume = { audio.previewVolume($0, gain: $1) }
            show.audioPan = { audio.previewPan($0, pan: $1) }
            show.audioMute = { [weak show] track, muted in
                audio.previewMute(track, muted: muted)
                if let track, let show, show.current?.tracks.first(where: { $0.id == track })?.kind == .timecode { audio.updateTimecode(show.snapshot) }
            }
            show.audioSolo = { audio.previewSolo($0, solo: $1) }
            show.audioPhase = { audio.previewPhase($0, inverted: $1) }
            show.audioMasterMono = { audio.previewMasterMono($0) }
            audio.onPeakLimit = { [weak show] id in
                guard let show, show.current?.tracks.first(where: { $0.id == id })?.mute == false else { return }
                show.send(.mute, target: id)
            }
            show.audioMasterSolo = { audio.previewMasterSolo($0) }
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
            show.audioMIDIChannel = { audio.previewMIDIChannel($0, channel: $1) }
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
            do { try audio.startDeviceSession() } catch { audio.onError(error) }
        }
        show.onStop = { [weak auth] in auth?.transportDidStop() }
    }
    func start() async {
        guard !preview else { starting = false; return }
        guard !started else { return }
        started = true
        startupProgress = 0.15
        await Task.yield()
        // A document is loaded only after an explicit choice in the project launcher.
        startupProgress = 0.55
        #if os(macOS)
        startupStage = "Validando acesso…"
        await auth.restore()
        #endif
        startupProgress = 1
        startupStage = "Pronto"
        starting = false
        #if os(macOS)
        var nextValidation = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            auth.checkLocalExpiry()
            if ProcessInfo.processInfo.systemUptime >= nextValidation {
                nextValidation = ProcessInfo.processInfo.systemUptime + 30
                Task { await auth.revalidate() }
            }
        }
        #endif
    }
}
