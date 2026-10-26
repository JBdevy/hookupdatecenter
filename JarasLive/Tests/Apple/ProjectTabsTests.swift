import Foundation
import Combine
import AppKit
import AVFoundation

@MainActor final class TestAlert {
    static var response: NSApplication.ModalResponse = .alertThirdButtonReturn
    var messageText = "", informativeText = ""
    var alertStyle: NSAlert.Style = .warning
    func addButton(withTitle: String) {}
    func runModal() -> NSApplication.ModalResponse { Self.response }
}
enum JarasLocalization { static func string(_ key: String) -> String { key } }
@MainActor enum ProjectSyncControl { static var following = false }
enum ProjectError: Error { case invalid(String) }
enum TestCommand { case stopAll }
struct TestPlugin { var category = "Instrument" }
struct TestFX { var instrumentKeys: [String] = []; var externalPlugins: [TestPlugin]? }
enum TestRecordingMode { case midi, audio }
struct TestTrack { var id = UUID(); var fx: TestFX?; var recordingMode = TestRecordingMode.midi }
struct TestSong { var tracks: [TestTrack] = [] }
struct TestProject { var id = UUID(); var name = "Unsaved"; var songs: [TestSong] = []; var mediaPaths: Set<String> = [] }
struct TestSnapshot { var project = TestProject() }
@MainActor final class ShowController {
    var snapshot = TestSnapshot()
    var isPlaying = false, hasUnsavedChanges = false, saving = false
    var saves = 0, stops = 0, pendingRevocation = false
    var navigateProjectTab: (Int) -> Void = { _ in }
    func send(_ command: TestCommand) { isPlaying = false; stops += 1 }
    func saveForClosing() async throws { saves += 1; hasUnsavedChanges = false }
    func finishCurrentSong(_ pending: Bool) { pendingRevocation = pending }
}
@MainActor final class StemAudioPlayback {
    static var shared = StemAudioPlayback(engine: AVAudioEngine())
    var activeMediaURLs: Set<URL> = []
    var armedMIDIRecordingTracks: Set<UUID> = []
    var allowed = true, closed = false, midi: [(UInt8, UInt8, UInt8)] = []
    init(engine: AVAudioEngine, auxiliarySelectedHardware: Bool = false) {}
    func releaseKeyboardNotes() {}
    func setArmedInstrumentTracks(_ ids: Set<UUID>) {}
    func setLicenseAllowed(_ value: Bool) { allowed = value }
    func prepareForClosing() { closed = true }
    func receiveMIDI(device: Int32, status: UInt8, number: UInt8, value: UInt8) { midi.append((status, number, value)) }
}
@MainActor final class TrackRecording {
    static var shared = TrackRecording()
    var armed: Set<UUID> = []
    var recording = false, busy = false
    func bind(_ show: ShowController) {}
    func suspendProjectTab() {}
    func finish() {}
}
@MainActor final class ProjectDocuments: ObservableObject {
    var show: ShowController
    @Published var busy = false
    @Published var ready = true
    @Published var missingAudioPrompt: Bool?
    var importingAudio = false, error = ""
    var projectTabCount = 1
    var projectTabIndex = 0
    var currentURL: URL?
    var recent: [URL] = []
    var additionalProtectedMediaURLs: () -> Set<URL> = { [] }
    var activateExistingProjectTab: ((URL) -> Bool)?
    var openInNewProjectTab: ((URL) -> Void)?
    var openRemoteInNewProjectTab: ((URL, UUID) -> Void)?
    var canChangeProject: () -> Bool = { true }
    static var remoteResults: [(UUID, String)] = []
    static func finishRemoteProjectOpening(_ id: UUID, state: String, error: String = "") { remoteResults.append((id, state)) }
    var navigateProjectTab: ((Int) -> Void)?
    init(show: ShowController) { self.show = show }
    func open(_ url: URL, remoteCommandID: UUID? = nil) {
        busy = true
        if url.lastPathComponent == "bad.jl" { error = "Invalid fixture"; ready = false }
        else { currentURL = url; ready = true }
        busy = false
        if let remoteCommandID { Self.finishRemoteProjectOpening(remoteCommandID, state: ready ? "completed" : "failed") }
    }
    func rememberProjectMedia() async throws {}
}
@MainActor final class TestAuth { var allowed = true }
@MainActor final class AppContainer {
    let remoteProjectTabID = UUID()
    var desktopWorkspaceHost: AnyObject?
    var desktopWorkspaceIdentity: UUID?
    var desktopWorkspaceEnvironment: String?
    let show = ShowController()
    let projectRecorder = TrackRecording()
    let projectAudio: StemAudioPlayback
    let auth: TestAuth
    lazy var documents = ProjectDocuments(show: show)
    init(sharedAuth: TestAuth? = nil, audio: StemAudioPlayback? = nil) throws {
        auth = sharedAuth ?? TestAuth(); projectAudio = audio ?? StemAudioPlayback.shared
    }
}
@MainActor enum ExternalPluginState { static func captureAll(show: ShowController) {} }
@MainActor final class FXWindows { static let shared = FXWindows(); func closeAll() {} }
@MainActor final class InstrumentLibrary { static let shared = InstrumentLibrary(); func setProjectDirectory(_ url: URL?) {} }
@MainActor final class VideoPlayback {
    static let shared = VideoPlayback(), teleprompter = VideoPlayback(), teleprompter2 = VideoPlayback()
    func open(directory: URL) {}
    func update(_ snapshot: TestSnapshot) {}
}
@MainActor enum TeleprompterRemote { static func setProjectDirectory(_ url: URL?) {} }
enum DAWRemoteState { struct ProjectTab { var id: UUID; var name: String; var selected: Bool } }
@MainActor enum DAWRemoteHostBridge {
    static var documents: ProjectDocuments?
    static var projectTabsProvider: () -> [DAWRemoteState.ProjectTab] = { [] }
    static var selectProjectTabHandler: ((UUID) -> Void)?
    static var closeProjectTabHandler: ((UUID) -> Void)?
    static func bind(_ show: ShowController) {}
}
@MainActor final class ResolumeController { static let shared = ResolumeController(); func bind(_ show: ShowController) {} }
@MainActor final class ControlMappings { static let shared = ControlMappings(); func bind(_ show: ShowController) {} }
@MainActor final class AudioDeviceSettings { static let shared = AudioDeviceSettings(); var canChangeConfiguration: () -> Bool = { true } }
enum ProjectTabNavigation {
    static func destination(current: Int, count: Int, direction: Int) -> Int? {
        guard count > 1, current >= 0, current < count, direction != 0 else { return nil }
        let next = current + (direction < 0 ? -1 : 1)
        return (0..<count).contains(next) ? next : nil
    }
}

// INSERT_PROJECT_TABS

@main struct Runner {
    @MainActor static func main() async throws {
        let tabs = DesktopProjectTabs.shared
        let first = try AppContainer()
        first.documents.currentURL = URL(fileURLWithPath: "/fixtures/first.jl")
        first.show.isPlaying = true; first.show.hasUnsavedChanges = true
        tabs.install(first)
        tabs.open(URL(fileURLWithPath: "/fixtures/second.jl"))
        precondition(tabs.projects.count == 2 && tabs.selected == 1)
        let second = tabs.projects[1]
        precondition(first.show.isPlaying && first.show.hasUnsavedChanges && first.show.stops == 0)
        precondition(first.projectAudio !== second.projectAudio)
        let liveMedia = URL(fileURLWithPath: "/fixtures/active.wav")
        first.projectAudio.activeMediaURLs = [liveMedia]
        first.show.snapshot.project.mediaPaths = ["Stems/first.wav"]
        second.show.snapshot.project.mediaPaths = ["Stems/second.wav"]
        let firstMedia = URL(fileURLWithPath: "/fixtures/Stems/first.wav").standardizedFileURL.resolvingSymlinksInPath()
        let secondMedia = URL(fileURLWithPath: "/fixtures/Stems/second.wav").standardizedFileURL.resolvingSymlinksInPath()
        precondition(second.documents.additionalProtectedMediaURLs() == [liveMedia, firstMedia])
        precondition(first.documents.additionalProtectedMediaURLs() == [secondMedia])
        second.show.hasUnsavedChanges = true; second.show.isPlaying = true
        let remoteTabs = DAWRemoteHostBridge.projectTabsProvider()
        precondition(remoteTabs.map(\.id) == [first.remoteProjectTabID, second.remoteProjectTabID])
        precondition(remoteTabs.map(\.name) == ["first", "second"] && remoteTabs.map(\.selected) == [false, true])
        DAWRemoteHostBridge.selectProjectTabHandler?(first.remoteProjectTabID)
        precondition(tabs.active === first && first.show.isPlaying && second.show.isPlaying)
        DAWRemoteHostBridge.selectProjectTabHandler?(UUID())
        precondition(tabs.active === first)
        DAWRemoteHostBridge.selectProjectTabHandler?(second.remoteProjectTabID)
        precondition(tabs.active === second && DAWRemoteHostBridge.projectTabsProvider().map(\.selected) == [false, true])
        print("PROJECT_TABS_REMOTE_SELECTION_AND_BACKGROUND_AUDIO_OK")
        tabs.navigate(-1)
        precondition(tabs.active === first && first.show.isPlaying && second.show.isPlaying)
        tabs.navigate(-1)
        precondition(tabs.active === first)
        tabs.navigate(1)
        precondition(tabs.active === second)
        tabs.navigate(1)
        precondition(tabs.active === second)
        tabs.receiveMIDI(device: 1, status: 0x90, number: 60, value: 100)
        precondition(first.projectAudio.midi.isEmpty && second.projectAudio.midi.count == 1)
        tabs.receiveMIDI(device: 1, status: 0xb0, number: 64, value: 0)
        precondition(first.projectAudio.midi.count == 1 && second.projectAudio.midi.count == 2)
        let existingRequest = UUID()
        tabs.open(URL(fileURLWithPath: "/fixtures/./first.jl"), remoteCommandID: existingRequest)
        precondition(ProjectDocuments.remoteResults.last?.0 == existingRequest && ProjectDocuments.remoteResults.last?.1 == "completed")
        precondition(tabs.projects.count == 2 && tabs.active === first)
        TrackRecording.shared.recording = true
        let rejectedRequest = UUID()
        tabs.navigate(1); tabs.open(URL(fileURLWithPath: "/fixtures/third.jl"), remoteCommandID: rejectedRequest)
        precondition(ProjectDocuments.remoteResults.last?.0 == rejectedRequest && ProjectDocuments.remoteResults.last?.1 == "failed")
        precondition(tabs.active === first && tabs.projects.count == 2)
        TrackRecording.shared.recording = false
        first.documents.importingAudio = true
        precondition(!first.documents.canChangeProject(), "Importing audio must close project-navigation admission")
        let importingRequest = UUID()
        tabs.open(URL(fileURLWithPath: "/fixtures/second.jl"), remoteCommandID: importingRequest)
        precondition(ProjectDocuments.remoteResults.last?.0 == importingRequest && ProjectDocuments.remoteResults.last?.1 == "failed")
        precondition(tabs.active === first && tabs.projects.count == 2, "Blocked navigation must not report completion or replace the active tab")
        first.documents.importingAudio = false
        precondition(first.documents.canChangeProject() && !second.documents.canChangeProject(), "Only the active document may replace its project")
        tabs.setPendingRevocation(true)
        precondition(first.show.pendingRevocation && second.show.pendingRevocation)
        TestAlert.response = .alertThirdButtonReturn
        let cancelled = try await tabs.confirmAndSaveBackgroundProjects(excluding: first.documents)
        precondition(!cancelled && second.show.saves == 0 && second.show.isPlaying)
        TestAlert.response = .alertFirstButtonReturn
        let saved = try await tabs.confirmAndSaveBackgroundProjects(excluding: first.documents)
        precondition(saved && second.show.saves == 1 && first.show.hasUnsavedChanges)
        let failedRequest = UUID()
        tabs.open(URL(fileURLWithPath: "/fixtures/bad.jl"), remoteCommandID: failedRequest)
        precondition(ProjectDocuments.remoteResults.last?.0 == failedRequest && ProjectDocuments.remoteResults.last?.1 == "failed")
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(tabs.projects.count == 2 && tabs.active === first && first.show.isPlaying)
        ProjectSyncControl.following = true
        tabs.close(0)
        precondition(tabs.projects.count == 2 && tabs.active === first && !first.projectAudio.closed,
                     "a following PC cannot locally close a synchronized project tab")
        ProjectSyncControl.following = false
        // Closing one tab cancels cleanly, then saves/removes only that tab.
        TestAlert.response = .alertThirdButtonReturn
        DAWRemoteHostBridge.closeProjectTabHandler?(first.remoteProjectTabID)
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(tabs.projects.count == 2 && first.show.isPlaying)
        second.show.isPlaying = true
        TestAlert.response = .alertFirstButtonReturn
        DAWRemoteHostBridge.closeProjectTabHandler?(first.remoteProjectTabID)
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(tabs.projects.count == 1 && tabs.active === second)
        precondition(first.projectAudio.closed && second.show.isPlaying)
        precondition(second.documents.additionalProtectedMediaURLs().isEmpty)
        precondition(first.show.saves == 1)
        tabs.setLicenseAllowed(false)
        precondition(!first.show.isPlaying && !second.show.isPlaying)
        precondition(!second.projectAudio.allowed)
        second.show.hasUnsavedChanges = false
        tabs.close(0)
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(tabs.projects.count == 1 && tabs.active !== second && tabs.active?.documents.ready == false)
        precondition(second.projectAudio.closed)
        tabs.stopAll()
        precondition(first.projectAudio.closed && second.projectAudio.closed)
        print("PROJECT_TABS_OK: independent sessions, background transport, navigation, duplicate files, MIDI releases, recording guard, close/save/cancel, failed-open rollback and authorization")
    }
}
