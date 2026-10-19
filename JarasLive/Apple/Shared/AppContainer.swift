import Foundation
import Combine
import SwiftUI
import AVFoundation
#if os(macOS)
import Network
import AppKit
#endif
#if os(iOS)
import UIKit
#endif
enum AppStartupPresentation {
    #if os(macOS)
    @MainActor private static var startupSound: NSSound?
    @MainActor private static var soundPlayed = false
    @MainActor static func playSoundOnce() {
        guard !soundPlayed else { return }
        soundPlayed = true
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "jaras.startup.sound") == nil || defaults.bool(forKey: "jaras.startup.sound"),
              let url = Bundle.main.url(forResource: "StartupSound", withExtension: "wav") else { return }
        startupSound = NSSound(contentsOf: url, byReference: false)
        startupSound?.play()
    }
    #endif
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
    #if os(macOS)
    let remoteProjectTabID = UUID()
    var desktopWorkspaceHost: NSHostingView<AnyView>?
    var desktopWorkspaceIdentity: UUID?
    var desktopWorkspaceEnvironment: String?
    #endif
    let backend: any BackendClient
    @Published private(set) var starting = true
    @Published private(set) var startupProgress = 0.1
    @Published private(set) var startupStage = "Carregando projeto…"
    private var startupTask: Task<Void, Never>?
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
    let projectRecorder: TrackRecording
    let projectAudio: StemAudioPlayback
    private let tabContext: Bool
    init(preview: Bool = false, sharedAuth: AuthService? = nil, audio: StemAudioPlayback? = nil) throws {
        self.projectRecorder = sharedAuth == nil ? TrackRecording.shared : TrackRecording()
        self.projectAudio = audio ?? StemAudioPlayback.shared
        self.tabContext = sharedAuth != nil
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
            if let sharedAuth { auth = sharedAuth }
            else {
                let device = try DeviceAuthorizationService.installation(store: store, name: name, platform: platform)
                auth = AuthService(backend: backend, store: store, installation: device, feature: feature, verifier: preview ? nil : .production)
            }
            let persistence = DocumentProjectStore()
            show = try ShowController(executor: LocalCommandExecutor(), persistence: persistence, initialProject: preview ? .demo() : .empty(name: "Untitled"), cursorMemory: preview ? nil : ProjectCursorMemory(), globalDefaults: preview ? nil : .standard)
            documents = ProjectDocuments(store: persistence, show: show, preview: preview)
            documents.projectAudio = projectAudio
            projectRecorder.projectAudio = projectAudio
        } catch { throw error }
        #if os(macOS)
        if !preview {
            DAWRemoteSession.shared.setHostName(auth.installation.deviceName)
            auth.onDeviceNameChanged = { DAWRemoteSession.shared.setHostName($0) }
        }
        #endif
        if !tabContext {
            auth.isPlaying = { [weak show] in
                #if os(macOS)
                return DesktopProjectTabs.shared.anyPlaying || show?.isPlaying == true
                #else
                return show?.isPlaying ?? false
                #endif
            }
            auth.onPendingRevocation = { [weak show] pending in
                #if os(macOS)
                DesktopProjectTabs.shared.setPendingRevocation(pending)
                #endif
                show?.finishCurrentSong(pending)
            }
        }
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
            let audio = projectAudio
            let recorder = projectRecorder
            #if os(macOS)
            projectInstrumentObservation = documents.$currentURL.removeDuplicates().sink { [weak show] url in
                if DesktopProjectTabs.shared.isForeground(show) {
                    InstrumentLibrary.shared.setProjectDirectory(url?.deletingLastPathComponent())
                }
            }
            #endif
            #if os(macOS)
            if !tabContext {
            AudioLicenseAccess.shared.setAllowed(false)
            audio.setLicenseAllowed(false)
            auth.onAudioAuthorization = { [weak show] allowed in
                DesktopProjectTabs.shared.setLicenseAllowed(allowed)
                AudioLicenseAccess.shared.setAllowed(allowed)
                audio.setLicenseAllowed(allowed)
                if !allowed {
                    show?.send(.stopAll)
                    TrackRecording.shared.finish()
                }
            }
            }
            else { audio.setLicenseAllowed(auth.allowed) }
            #endif
            if !tabContext { TrackRecording.shared.bind(show) }
            #if os(macOS)
            armedInstrumentObservation = projectRecorder.$armed.sink { [weak show] _ in
                // Published state is sent before the REC button redraws. Queue
                // graph changes after the click, and only wake live instruments.
                Task { @MainActor [weak self, weak show] in
                    #if os(iOS)
                    guard self?.localPlaybackEnabled == true, !AudioDeviceSettings.shared.localSessionInterrupted else { return }
                    #endif
                    guard let show, DesktopProjectTabs.shared.isForeground(show) else { return }
                    let instruments = Set(show.snapshot.project.songs.flatMap(\.tracks).filter { track in
                        track.fx?.instrumentKeys.isEmpty == false || (track.fx?.externalPlugins?.contains { $0.category.contains("Instrument") } ?? false)
                    }.map(\.id))
                    audio.armedMIDIRecordingTracks = recorder.armed.intersection(Set(show.snapshot.project.songs.flatMap(\.tracks).filter { $0.recordingMode == .midi }.map(\.id)))
                    audio.setArmedInstrumentTracks(recorder.armed.intersection(instruments))
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
                #if os(macOS)
                let foreground = DesktopProjectTabs.shared.isForeground(show)
                #else
                let foreground = true
                #endif
                if foreground && repeatWasEnabled && !repeatEnabled { TimelineAreaSelection.shared.clear() }
                repeatWasEnabled = repeatEnabled
                do {
                    try audio.update(snapshot, revision: revision, sampledAt: show?.timelinePlaybackSampleTime ?? ProcessInfo.processInfo.systemUptime)
                    if foreground { TrackRecording.shared.observe(snapshot); VideoPlayback.shared.update(snapshot) }
                    if foreground, repeatEnabled, let start = snapshot.transport.loop.start, let end = snapshot.transport.loop.end, let song = snapshot.transport.songId {
                        TimelineAreaSelection.shared.update(song: song, from: start, to: end)
                    }
                    #if os(macOS)
                    if foreground {
                        TeleprompterWindow.shared.update(snapshot, revision: show?.projectRevision ?? revision)
                        TeleprompterWindow.second.update(snapshot, revision: show?.projectRevision ?? revision)
                    }
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
            show.audioItemFadeShape = { audio.previewItemFadeShape($0, fadeIn: $1, curvature: $2, sCurve: $3) }
            show.audioItemPhase = { audio.previewItemPhase($0, inverted: $1) }
            show.audioItemPan = { audio.previewItemPan($0, pan: $1) }
            show.audioItemGain = { audio.previewItemGain($0, gain: $1) }
            show.audioItemChannelMode = { audio.previewItemChannelMode($0, mode: $1) }
            show.audioItemNormalization = { audio.previewItemNormalization($0, gain: $1) }
            show.audioVolume = { audio.previewVolume($0, gain: $1) }
            show.audioTransportFade = { audio.setTransportFadeGains($0) }
            show.audioStartTransportFade = { audio.startTransportFade(tracks: $0, duration: $1) }
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
            show.prepareForFXChange = { [weak show] track, clip, effects in
                guard let show else { return }
                let settings = ExternalPluginState.settings(show: show, track: track, clip: clip)
                for plugin in settings.externalPlugins ?? [] where effects.contains(plugin.effectKey) {
                    try ExternalPluginState.captureForSaving(show: show, track: track, clip: clip, identifier: plugin.id)
                }
            }
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
        if tabContext { starting = false }
    }
    #if os(iOS)
    func closeNativeProject(resumeAudio: Bool = true) async -> Bool {
        guard !documents.busy else { return false }
        do {
            try await documents.closeNativeProject {
                guard await self.setLocalPlaybackEnabled(false) else {
                    throw ProjectError.invalid(self.show.message)
                }
            }
            if resumeAudio { _ = await setLocalPlaybackEnabled(true) }
            return true
        } catch {
            documents.error = error.localizedDescription
            if !localPlaybackEnabled && documents.ready { _ = await setLocalPlaybackEnabled(true) }
            return false
        }
    }
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
                settings.beginLocalRouteChange()
                TrackRecording.shared.setLocalAudioAvailable(false)
                audio.suspendDeviceSession()
                show.message = error.localizedDescription
                do {
                    try await audio.waitForSuspendedProcessors()
                    try await TrackRecording.shared.waitForLocalHardwareSuspension()
                    guard transition == localPlaybackTransition else { return false }
                    try settings.deactivateLocalSession()
                }
                catch { show.message += "\n" + error.localizedDescription }
                return false
            }
        }
        show.send(.stopAll)
        localPlaybackEnabled = false
        settings.beginLocalRouteChange()
        TrackRecording.shared.setLocalAudioAvailable(false)
        audio.suspendDeviceSession()
        do {
            try await audio.waitForSuspendedProcessors()
            try await TrackRecording.shared.waitForLocalHardwareSuspension()
            await TrackRecording.shared.finishAndWait()
            guard transition == localPlaybackTransition else { return true }
            try settings.deactivateLocalSession(); return true
        }
        catch { settings.error = error.localizedDescription; show.message = error.localizedDescription; return false }
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
            recoverMobileRoute(outputRemoved: true)
        }
    }
    private func recoverMobileRoute(outputRemoved: Bool) {
        let audio = StemAudioPlayback.shared, settings = AudioDeviceSettings.shared
        let disconnectedNotice = JarasLocalization.string("Audio device disconnected. Playback stopped.")
        settings.error = ""
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
        if outputRemoved { show.message = disconnectedNotice }
        mobileRouteRecovery = Task { @MainActor [weak self] in
            do {
                // USB removal emits several session/engine changes while its
                // channel layout settles. Only the last route can rebuild.
                try await Task.sleep(nanoseconds: 150_000_000)
                guard let self else { return }
                try await audio.waitForSuspendedProcessors()
                try await TrackRecording.shared.waitForLocalHardwareSuspension()
                await TrackRecording.shared.finishAndWait()
                try Task.checkCancellation()
                guard localPlaybackEnabled, transition == localPlaybackTransition,
                      revision == mobileRouteRevision, !settings.localSessionInterrupted else { return }
                try settings.activateLocalSession()
                settings.finishLocalRouteChange()
                try audio.startDeviceSession()
                if documents.ready { show.preparePlayback() }
                settings.inputDeviceChanged?()
                TrackRecording.shared.setLocalAudioAvailable(true)
                if show.message == disconnectedNotice { show.message = "" }
                mobileRouteRecovery = nil
            } catch is CancellationError { }
            catch {
                guard let self, revision == mobileRouteRevision else { return }
                // Keep configuration available when rebuilding a disconnected
                // route fails. Reconnecting USB or choosing an output schedules
                // another recovery; neither action requires relaunching the app.
                audio.suspendDeviceSession()
                TrackRecording.shared.setLocalAudioAvailable(false)
                settings.finishLocalRouteChange()
                settings.error = error.localizedDescription
                show.message = error.localizedDescription
                mobileRouteRecovery = nil
            }
        }
    }
    #endif
    func start() async {
        guard !preview else { starting = false; return }
        // Reparenting the hosting view for interface scaling cancels SwiftUI's
        // appearance task. Initialization belongs to the container and must
        // finish once, even when the view disappears and immediately returns.
        if tabContext { starting = false }
        else {
            if startupTask == nil { startupTask = Task { await self.initialize() } }
            await startupTask?.value
        }
        guard !Task.isCancelled else { return }
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
    private func initialize() async {
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
    }
}

#if os(macOS)
/// Controllers and audio engines live for the lifetime of the open project,
/// independently of which workspace is being shown. Selecting never reloads it.
@MainActor final class DesktopProjectTabs: ObservableObject {
    static let shared = DesktopProjectTabs()
    @Published private(set) var selected = 0 {
        didSet { for project in projects { project.documents.projectTabIndex = selected } }
    }
    @Published private(set) var projects: [AppContainer] = []
    private var openingObservers: [ObjectIdentifier: Set<AnyCancellable>] = [:]
    private var loadingProjects: Set<ObjectIdentifier> = []
    private var closingTab = false
    var active: AppContainer? { projects.indices.contains(selected) ? projects[selected] : nil }
    var anyPlaying: Bool { projects.contains { $0.show.isPlaying } }
    func isForeground(_ show: ShowController?) -> Bool {
        projects.isEmpty || (show != nil && active?.show === show)
    }
    func audio(for show: ShowController) -> StemAudioPlayback {
        projects.first { $0.show === show }?.projectAudio ?? StemAudioPlayback.shared
    }
    func install(_ initial: AppContainer) {
        guard projects.isEmpty else { return }
        projects = [initial]; configure(initial); selected = 0
        DAWRemoteHostBridge.projectTabsProvider = { [weak self] in
            guard let self else { return [] }
            return self.projects.enumerated().map { index, container in
                .init(id: container.remoteProjectTabID, name: container.documents.currentURL?.deletingPathExtension().lastPathComponent ?? container.show.snapshot.project.name, selected: index == self.selected)
            }
        }
        DAWRemoteHostBridge.selectProjectTabHandler = { [weak self] id in
            guard let self, let index = self.projects.firstIndex(where: { $0.remoteProjectTabID == id }) else { return }
            self.select(index)
        }
    }
    private func configure(_ container: AppContainer) {
        container.documents.activateExistingProjectTab = { [weak self, weak container] url in
            guard let self, let container else { return false }
            let path = url.standardizedFileURL.resolvingSymlinksInPath()
            guard let index = self.projects.firstIndex(where: { $0 !== container && $0.documents.currentURL?.standardizedFileURL.resolvingSymlinksInPath() == path }) else { return false }
            self.select(index); return true
        }
        container.documents.openInNewProjectTab = { [weak self] url in self?.open(url) }
        container.documents.navigateProjectTab = { [weak self] direction in self?.navigate(direction) }
        container.show.navigateProjectTab = { [weak self] direction in self?.navigate(direction) }
    }
    func navigate(_ direction: Int) {
        guard let index = ProjectTabNavigation.destination(current: selected, count: projects.count, direction: direction) else { return }
        select(index)
    }
    func select(_ index: Int) {
        guard !closingTab, projects.indices.contains(index), index != selected, let old = active,
              !old.documents.busy, !old.documents.importingAudio,
              !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        // Engines and processors remain owned by their tab. Closing the visible
        // editors captures their edits; a full snapshot of every FX is unnecessary.
        FXWindows.shared.closeAll()
        old.projectAudio.releaseKeyboardNotes()
        old.projectAudio.setArmedInstrumentTracks([])
        old.projectRecorder.suspendProjectTab()
        selected = index
        let next = projects[index]
        StemAudioPlayback.shared = next.projectAudio
        TrackRecording.shared = next.projectRecorder
        next.projectRecorder.bind(next.show)
        let instrumentTracks = Set(next.show.snapshot.project.songs.flatMap(\.tracks).filter {
            $0.fx?.instrumentKeys.isEmpty == false || ($0.fx?.externalPlugins?.contains { $0.category.contains("Instrument") } ?? false)
        }.map(\.id))
        next.projectAudio.setArmedInstrumentTracks(next.projectRecorder.armed.intersection(instrumentTracks))
        next.projectAudio.armedMIDIRecordingTracks = next.projectRecorder.armed.intersection(Set(next.show.snapshot.project.songs.flatMap(\.tracks).filter { $0.recordingMode == .midi }.map(\.id)))
        if let directory = next.documents.currentURL?.deletingLastPathComponent() {
            VideoPlayback.shared.open(directory: directory)
            VideoPlayback.teleprompter.open(directory: directory)
            VideoPlayback.teleprompter2.open(directory: directory)
            TeleprompterRemote.setProjectDirectory(directory)
        }
        InstrumentLibrary.shared.setProjectDirectory(next.documents.currentURL?.deletingLastPathComponent())
        DAWRemoteHostBridge.documents = next.documents
        DAWRemoteHostBridge.bind(next.show)
        ResolumeController.shared.bind(next.show)
        ControlMappings.shared.bind(next.show)
        VideoPlayback.shared.update(next.show.snapshot)
        next.documents.recent = (UserDefaults.standard.stringArray(forKey: "jaras.recentProjects") ?? []).map { URL(fileURLWithPath: $0) }
        AudioDeviceSettings.shared.canChangeConfiguration = { [weak self] in
            self?.anyPlaying != true && !TrackRecording.shared.recording && !TrackRecording.shared.busy
        }
    }
    func open(_ url: URL) {
        guard !closingTab else { return }
        guard let current = active, current.documents.ready, !current.documents.busy,
              !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let index = projects.firstIndex(where: { $0.documents.currentURL?.standardizedFileURL.resolvingSymlinksInPath() == canonical }) {
            select(index); return
        }
        do {
            let audio = StemAudioPlayback(engine: AVAudioEngine(), auxiliarySelectedHardware: true)
            let next = try AppContainer(sharedAuth: current.auth, audio: audio)
            configure(next)
            projects.append(next)
            for project in projects { project.documents.projectTabCount = projects.count }
            select(projects.count - 1)
            watchOpening(next, fallback: current)
            next.documents.open(url)
        } catch { current.documents.error = error.localizedDescription }
    }
    private func watchOpening(_ project: AppContainer, fallback: AppContainer) {
        let id = ObjectIdentifier(project)
        var subscriptions = Set<AnyCancellable>()
        let check: () -> Void = { [weak self, weak project, weak fallback] in
            DispatchQueue.main.async {
                guard let self, let project, let fallback, self.loadingProjects.contains(id),
                      !project.documents.busy else { return }
                if project.documents.ready {
                    self.loadingProjects.remove(id); self.openingObservers.removeValue(forKey: id); return
                }
                guard project.documents.missingAudioPrompt == nil,
                      let index = self.projects.firstIndex(where: { $0 === project }),
                      let previous = self.projects.firstIndex(where: { $0 === fallback }) else { return }
                let error = project.documents.error
                if self.selected == index { self.select(previous) }
                project.projectAudio.prepareForClosing()
                self.projects.remove(at: index)
                if self.selected > index { self.selected -= 1 }
                for item in self.projects { item.documents.projectTabCount = self.projects.count }
                self.loadingProjects.remove(id); self.openingObservers.removeValue(forKey: id)
                if !error.isEmpty {
                    let alert = NSAlert(); alert.alertStyle = .warning
                    alert.messageText = JarasLocalization.string(error); alert.runModal()
                }
            }
        }
        project.documents.$busy.dropFirst().sink { [weak self] busy in
            if busy { self?.loadingProjects.insert(id) } else { check() }
        }.store(in: &subscriptions)
        project.documents.$missingAudioPrompt.dropFirst().sink { _ in check() }.store(in: &subscriptions)
        openingObservers[id] = subscriptions
    }
    func setLicenseAllowed(_ allowed: Bool) {
        for project in projects {
            project.projectAudio.setLicenseAllowed(allowed)
            if !allowed { project.show.send(.stopAll); project.projectRecorder.finish() }
        }
    }
    func setPendingRevocation(_ pending: Bool) {
        for project in projects { project.show.finishCurrentSong(pending) }
    }
    func receiveMIDI(device: Int32, status: UInt8, number: UInt8, value: UInt8) {
        if projects.isEmpty { StemAudioPlayback.shared.receiveMIDI(device: device, status: status, number: number, value: value); return }
        let newNote = status & 0xf0 == 0x90 && value > 0
        for (index, project) in projects.enumerated() where !newNote || index == selected {
            project.projectAudio.receiveMIDI(device: device, status: status, number: number, value: value)
        }
    }
    func confirmAndSaveBackgroundProjects(excluding documents: ProjectDocuments) async throws -> Bool {
        for project in projects where project.documents !== documents {
            guard !project.documents.busy, !project.projectRecorder.recording, !project.projectRecorder.busy else {
                throw ProjectError.invalid("Finish the current operation before closing.")
            }
            while project.show.saving { try await Task.sleep(nanoseconds: 20_000_000) }
            if project.show.hasUnsavedChanges {
                let alert = NSAlert()
                alert.messageText = JarasLocalization.string("Do you want to save this project?")
                alert.informativeText = project.show.snapshot.project.name
                alert.addButton(withTitle: JarasLocalization.string("Save"))
                alert.addButton(withTitle: JarasLocalization.string("Close without saving"))
                alert.addButton(withTitle: JarasLocalization.string("Cancel"))
                let response = alert.runModal()
                if response == .alertThirdButtonReturn { return false }
                if response == .alertFirstButtonReturn { try await project.show.saveForClosing() }
            }
            try await project.documents.rememberProjectMedia()
        }
        return true
    }
    func close(_ index: Int) {
        guard !closingTab, projects.indices.contains(index), let current = active,
              !current.documents.busy, !current.documents.importingAudio,
              !current.projectRecorder.recording, !current.projectRecorder.busy else { return }
        select(index)
        guard selected == index else { return }
        let project = projects[index]
        guard !project.documents.busy, !project.documents.importingAudio,
              !project.projectRecorder.recording, !project.projectRecorder.busy else { return }
        closingTab = true
        Task { @MainActor in
            defer { closingTab = false }
            do {
                if project.show.hasUnsavedChanges {
                    let alert = NSAlert()
                    alert.messageText = JarasLocalization.string("Do you want to save this project?")
                    alert.informativeText = project.show.snapshot.project.name
                    alert.addButton(withTitle: JarasLocalization.string("Save"))
                    alert.addButton(withTitle: JarasLocalization.string("Close without saving"))
                    alert.addButton(withTitle: JarasLocalization.string("Cancel"))
                    let answer = alert.runModal()
                    if answer == .alertThirdButtonReturn { return }
                    if answer == .alertFirstButtonReturn { try await project.show.saveForClosing() }
                } else if project.show.isPlaying {
                    let alert = NSAlert()
                    alert.messageText = JarasLocalization.string("Close tab")
                    alert.informativeText = project.show.snapshot.project.name
                    alert.addButton(withTitle: JarasLocalization.string("Close"))
                    alert.addButton(withTitle: JarasLocalization.string("Cancel"))
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                try await project.documents.rememberProjectMedia()
                if projects.count == 1 {
                    let empty = try AppContainer(sharedAuth: project.auth,
                        audio: StemAudioPlayback(engine: AVAudioEngine(), auxiliarySelectedHardware: true))
                    empty.documents.ready = false
                    projects.append(empty); configure(empty)
                }
                guard let closing = projects.firstIndex(where: { $0 === project }) else { return }
                closingTab = false
                select(closing == 0 ? 1 : closing - 1)
                guard active !== project else { return }
                project.show.send(.stopAll)
                project.projectAudio.prepareForClosing()
                project.projectRecorder.finish()
                project.desktopWorkspaceHost = nil
                project.desktopWorkspaceIdentity = nil
                project.desktopWorkspaceEnvironment = nil
                projects.remove(at: closing)
                if selected > closing { selected -= 1 }
                for item in projects { item.documents.projectTabCount = projects.count }
            } catch { project.documents.error = error.localizedDescription }
        }
    }
    func stopAll() {
        for project in projects {
            project.show.send(.stopAll)
            project.projectAudio.prepareForClosing()
        }
    }
}
struct DesktopProjectTabBar: View {
    @ObservedObject private var tabs = DesktopProjectTabs.shared
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(tabs.projects.enumerated()), id: \.offset) { index, project in
                HStack(spacing: 0) {
                    Button { tabs.select(index) } label: {
                        Text(project.documents.currentURL?.deletingPathExtension().lastPathComponent ?? project.show.snapshot.project.name)
                            .font(.jarasSystem(size: 11, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity).frame(height: 23)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).frame(maxWidth: .infinity)
                    Button { tabs.close(index) } label: {
                        Image(systemName: "xmark").font(.jarasSystem(size: 9, weight: .semibold))
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(JarasLocalization.string("Close tab"))
                        .accessibilityIdentifier("closeProjectTab-\(index)")
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(tabs.selected == index ? Color.white : Color.white.opacity(0.6))
                .background(tabs.selected == index ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                .overlay(alignment: .bottom) {
                    if tabs.selected == index { Rectangle().fill(Color.green).frame(height: 2) }
                }
            }
        }.padding(.horizontal, 6).background(Color.black.opacity(0.2))
    }
}
struct DesktopProjectRoot: View {
    let initial: AppContainer
    @ObservedObject private var tabs = DesktopProjectTabs.shared
    var body: some View {
        let container = tabs.active ?? initial
        RootView(container: container)
    }
}
#endif
