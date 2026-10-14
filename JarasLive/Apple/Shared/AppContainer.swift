import Foundation
import Combine
import SwiftUI
#if os(macOS)
import Network
#endif
#if os(iOS)
import UIKit
#endif
enum AppStartupPresentation {
    static let minimumDuration = 3.0
    static func wait(since start: TimeInterval) async throws {
        try Task.checkCancellation()
        let remaining = minimumDuration - (ProcessInfo.processInfo.systemUptime - start)
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64((remaining * 1_000_000_000).rounded(.up)))
        }
    }
}
@MainActor final class AppContainer: ObservableObject {
    let auth: AuthService, show: ShowController
    let backend: any BackendClient
    @Published private(set) var starting = true
    @Published private(set) var startupProgress = 0.1
    @Published private(set) var startupStage = "Carregando projeto…"
    private var started = false
    #if os(iOS)
    @Published private(set) var localPlaybackEnabled = false
    private var localPlaybackTransition: UInt64 = 0
    private var mobileRouteRecovery: Task<Void, Never>?
    private var mobileRouteRevision: UInt64 = 0
    private var nativeAccessObservation: AnyCancellable?
    #endif
    #if os(macOS)
    private let accessConnectivity = NWPathMonitor()
    #endif
    private var armedInstrumentObservation: AnyCancellable?
    private var projectInstrumentObservation: AnyCancellable?
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
            show = try ShowController(executor: LocalCommandExecutor(), persistence: persistence, initialProject: preview ? .demo() : .empty(name: "Untitled"), cursorMemory: preview ? nil : ProjectCursorMemory(), globalDefaults: preview ? nil : .standard)
            documents = ProjectDocuments(store: persistence, show: show, preview: preview)
        } catch { throw error }
        #if os(macOS)
        if !preview {
            DAWRemoteSession.shared.setHostName(auth.installation.deviceName)
            auth.onDeviceNameChanged = { DAWRemoteSession.shared.setHostName($0) }
        }
        #endif
        auth.isPlaying = { [weak show] in show?.isPlaying ?? false }
        auth.onPendingRevocation = { [weak show] pending in show?.finishCurrentSong(pending) }
        #if os(iOS)
        // The mode picker and Remote never activate the local audio graph.
        show.canExecute = { [weak self] in preview || (self?.localPlaybackEnabled == true && NativePurchaseStore.shared.canAccessNative) }
        if !preview {
            nativeAccessObservation = NativePurchaseStore.shared.$canAccessNative.removeDuplicates().sink { [weak show] allowed in
                show?.finishCurrentSong(!allowed)
            }
        }
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
            projectInstrumentObservation = documents.$currentURL.removeDuplicates().sink { url in
                InstrumentLibrary.shared.setProjectDirectory(url?.deletingLastPathComponent())
            }
            #endif
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
            #if os(macOS)
            armedInstrumentObservation = TrackRecording.shared.$armed.sink { [weak show] _ in
                // Published state is sent before the REC button redraws. Queue
                // graph changes after the click, and only wake live instruments.
                Task { @MainActor [weak self, weak show] in
                    #if os(iOS)
                    guard self?.localPlaybackEnabled == true, !AudioDeviceSettings.shared.localSessionInterrupted else { return }
                    #endif
                    guard let show else { return }
                    let instruments = Set(show.snapshot.project.songs.flatMap(\.tracks).filter { track in
                        track.fx?.instrumentKeys.isEmpty == false || (track.fx?.externalPlugins?.contains { $0.category.contains("Instrument") } ?? false)
                    }.map(\.id))
                    audio.armedMIDIRecordingTracks = TrackRecording.shared.armed.intersection(Set(show.snapshot.project.songs.flatMap(\.tracks).filter { $0.recordingMode == .midi }.map(\.id)))
                    audio.setArmedInstrumentTracks(TrackRecording.shared.armed.intersection(instruments))
                }
            }
            audio.instrumentFile = { [weak audio] id in
                guard let instrument = InstrumentLibrary.catalog.first(where: { $0.id == id }),
                      let file = InstrumentLibrary.shared.resolvedFile(id, projectDirectory: audio?.mediaDirectory) else { return nil }
                return (file, instrument.percussion)
            }
            #endif
            show.selectedLoopArea = { [weak show] in
                guard let area = TimelineAreaSelection.shared.range, area.song == show?.snapshot.transport.songId else { return nil }
                return area.start...area.end
            }
            show.audioPresentationPosition = { [weak audio] head, time in audio?.presentationPosition(head: head, sampledAt: time) }
            var repeatWasEnabled = show.snapshot.transport.loop.enabled
            show.audioUpdate = { [weak self, weak show] snapshot, revision in
                #if os(iOS)
                guard self?.localPlaybackEnabled == true,
                      !AudioDeviceSettings.shared.localSessionInterrupted,
                      !AudioDeviceSettings.shared.localSessionReconfiguring else { return }
                #endif
                let repeatEnabled = snapshot.transport.loop.enabled
                if repeatWasEnabled && !repeatEnabled { TimelineAreaSelection.shared.clear() }
                repeatWasEnabled = repeatEnabled
                do {
                    try audio.update(snapshot, revision: revision, sampledAt: show?.timelinePlaybackSampleTime ?? ProcessInfo.processInfo.systemUptime)
                    TrackRecording.shared.observe(snapshot); VideoPlayback.shared.update(snapshot)
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
            show.audioAutomationOverride = { audio.overrideAutomation($0, envelope: $1, value: $2) }
            show.audioFX = { audio.previewFX($0, settings: $1) }
            show.audioClipFX = { audio.previewClipFX($0, settings: $1) }
            show.audioClipFXBypass = { audio.previewClipFXBypass($0, bypassed: $1) }
            show.audioItemFade = { audio.previewItemFade($0, fadeIn: $1, seconds: $2) }
            show.audioItemPhase = { audio.previewItemPhase($0, inverted: $1) }
            show.audioItemPan = { audio.previewItemPan($0, pan: $1) }
            show.audioItemGain = { audio.previewItemGain($0, gain: $1) }
            show.audioItemChannelMode = { audio.previewItemChannelMode($0, mode: $1) }
            show.audioItemNormalization = { audio.previewItemNormalization($0, gain: $1) }
            show.audioVolume = { audio.previewVolume($0, gain: $1) }
            show.audioMasterPan = { audio.previewMasterPan($0) }
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
            show.prepareForSave = { [weak show] in if let show { try ExternalPluginState.captureAllForSaving(show: show) } }
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
            #if os(macOS)
            do { try audio.startDeviceSession() } catch { audio.onError(error) }
            #else
            AudioDeviceSettings.shared.mobileSessionEvent = { [weak self] event in self?.handleMobileAudioEvent(event) }
            #endif
        }
        show.onStop = { [weak auth] in auth?.transportDidStop() }
    }
    #if os(iOS)
    @discardableResult
    func setLocalPlaybackEnabled(_ enabled: Bool) async -> Bool {
        guard !preview else { localPlaybackEnabled = enabled; return true }
        if enabled && !localPlaybackEnabled && !NativePurchaseStore.shared.canAccessNative {
            show.message = "Unlock Native mode to play projects on this iPad."
            return false
        }
        if enabled && localPlaybackEnabled { return true }
        localPlaybackTransition &+= 1
        mobileRouteRevision &+= 1
        mobileRouteRecovery?.cancel(); mobileRouteRecovery = nil
        let transition = localPlaybackTransition
        let audio = StemAudioPlayback.shared, settings = AudioDeviceSettings.shared
        if enabled {
            guard !localPlaybackEnabled else { return true }
            do {
                try await audio.waitForSuspendedProcessors()
                guard transition == localPlaybackTransition else { return false }
                try settings.activateLocalSession()
                settings.finishLocalRouteChange()
                localPlaybackEnabled = true
                try audio.startDeviceSession()
                if documents.ready { show.preparePlayback() }
                TrackRecording.shared.setLocalAudioAvailable(true)
                return true
            } catch {
                localPlaybackEnabled = false
                TrackRecording.shared.setLocalAudioAvailable(false)
                audio.suspendDeviceSession()
                show.message = error.localizedDescription
                do { try settings.deactivateLocalSession() }
                catch { show.message += "\n" + error.localizedDescription }
                return false
            }
        }
        show.send(.stopAll)
        localPlaybackEnabled = false
        TrackRecording.shared.setLocalAudioAvailable(false)
        audio.suspendDeviceSession()
        await TrackRecording.shared.finishAndWait()
        guard transition == localPlaybackTransition else { return true }
        do { try settings.deactivateLocalSession(); return true }
        catch { show.message = error.localizedDescription; return false }
    }
    private func handleMobileAudioEvent(_ event: MobileAudioSessionEvent) {
        guard localPlaybackEnabled else { return }
        let audio = StemAudioPlayback.shared, settings = AudioDeviceSettings.shared
        switch event {
        case .interrupted:
            mobileRouteRevision &+= 1
            mobileRouteRecovery?.cancel(); mobileRouteRecovery = nil
            settings.beginLocalRouteChange()
            audio.suspendDeviceSession()
            TrackRecording.shared.setLocalAudioAvailable(false)
            show.send(.stopAll)
        case .interruptionEnded:
            recoverMobileRoute(outputRemoved: false)
        case let .routeChanged(outputRemoved):
            recoverMobileRoute(outputRemoved: outputRemoved)
        case .mediaServicesReset:
            mobileRouteRevision &+= 1
            mobileRouteRecovery?.cancel(); mobileRouteRecovery = nil
            settings.beginLocalRouteChange()
            audio.suspendDeviceSession()
            TrackRecording.shared.setLocalAudioAvailable(false)
            show.send(.stopAll)
            localPlaybackEnabled = false
            try? settings.deactivateLocalSession()
            show.message = JarasLocalization.string("Audio services restarted. Close and reopen CatLive to restore audio.")
        }
    }
    private func recoverMobileRoute(outputRemoved: Bool) {
        let audio = StemAudioPlayback.shared, settings = AudioDeviceSettings.shared
        mobileRouteRevision &+= 1
        let revision = mobileRouteRevision, transition = localPlaybackTransition
        let alreadySuspended = mobileRouteRecovery != nil
        mobileRouteRecovery?.cancel()
        settings.beginLocalRouteChange()
        if !alreadySuspended {
            audio.suspendDeviceSession()
            TrackRecording.shared.setLocalAudioAvailable(false)
            show.send(.stopAll)
        }
        if outputRemoved { show.message = JarasLocalization.string("Audio device disconnected. Playback stopped.") }
        mobileRouteRecovery = Task { @MainActor [weak self] in
            do {
                // USB removal emits several session/engine changes while its
                // channel layout settles. Only the last route can rebuild.
                try await Task.sleep(nanoseconds: 150_000_000)
                guard let self else { return }
                await TrackRecording.shared.finishAndWait()
                try await audio.waitForSuspendedProcessors()
                try Task.checkCancellation()
                guard localPlaybackEnabled, transition == localPlaybackTransition,
                      revision == mobileRouteRevision, !settings.localSessionInterrupted else { return }
                try settings.activateLocalSession()
                settings.finishLocalRouteChange()
                try audio.startDeviceSession()
                if documents.ready { show.preparePlayback() }
                settings.inputDeviceChanged?()
                TrackRecording.shared.setLocalAudioAvailable(true)
                mobileRouteRecovery = nil
            } catch is CancellationError { }
            catch {
                guard let self, revision == mobileRouteRevision else { return }
                audio.suspendDeviceSession()
                settings.finishLocalRouteChange()
                show.message = error.localizedDescription
                mobileRouteRecovery = nil
            }
        }
    }
    #endif
    func start() async {
        guard !preview else { starting = false; return }
        guard !started else { return }
        started = true
        // A closed startup window cancels its task; a later appearance can retry.
        defer { if starting { started = false } }
        let startupBegan = ProcessInfo.processInfo.systemUptime
        startupProgress = 0.15
        await Task.yield()
        // A document is loaded only after an explicit choice in the project launcher.
        startupProgress = 0.55
        #if os(macOS)
        startupStage = "Restaurando ativação…"
        await auth.restore()
        accessConnectivity.pathUpdateHandler = { [weak auth] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak auth] in await auth?.checkOnlineAccess() }
        }
        accessConnectivity.start(queue: DispatchQueue(label: "com.catlive.account-connectivity"))
        guard !Task.isCancelled else { return }
        DAWRemoteHostBridge.bind(show)
        DAWRemoteSession.shared.restoreHostPreference()
        #endif
        startupProgress = 1
        startupStage = "Pronto"
        #if os(macOS)
        // Loading runs during the splash; only its remaining minimum time waits.
        do { try await AppStartupPresentation.wait(since: startupBegan) } catch { return }
        #endif
        guard !Task.isCancelled else { return }
        starting = false
        #if os(macOS)
        var nextQuarantineCheck = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            auth.checkLocalExpiry()
            if ProcessInfo.processInfo.systemUptime >= nextQuarantineCheck {
                nextQuarantineCheck = ProcessInfo.processInfo.systemUptime + 30
                Task { await auth.checkOnlineAccess() }
            }
        }
        #endif
    }
}
