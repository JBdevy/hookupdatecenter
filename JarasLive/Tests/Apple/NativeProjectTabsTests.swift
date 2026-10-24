import Foundation
import Combine

enum ProjectError: Error { case invalid(String) }
enum MobileAudioSessionEvent { case interrupted }
final class AVAudioEngine {}
final class JarasMobileAudioOutput { init(engine: AVAudioEngine) {} }
struct TestFX { var instrumentKeys: [String] = [] }
enum TestRecordingMode { case midi, audio }
struct TestTrack { var id = UUID(); var fx: TestFX?; var recordingMode = TestRecordingMode.audio }
struct TestSong { var tracks: [TestTrack] = [] }
struct TestProject { var name = "Untitled"; var songs: [TestSong] = []; var mediaPaths: Set<String> = [] }
struct TestSnapshot { var project = TestProject() }
@MainActor final class ShowController {
    var snapshot = TestSnapshot(), message = ""
    var playing = false, dirty = false, failSave = false
    var saves = 0
    var navigateProjectTab: (Int) -> Void = { _ in }
    func saveForClosing() async throws { if failSave { throw ProjectError.invalid("save failed") }; saves += 1; dirty = false }
}
@MainActor final class TrackRecording {
    static var shared = TrackRecording()
    var recording = false, busy = false
    var armed: Set<UUID> = []
    var suspensions = 0
    func bind(_ show: ShowController) {}
    func suspendProjectTab() { suspensions += 1 }
}
@MainActor final class StemAudioPlayback {
    static var shared = StemAudioPlayback(engine: AVAudioEngine())
    var activeMediaURLs: Set<URL> = []
    var armedMIDIRecordingTracks: Set<UUID> = []
    var closed = false
    init(engine: AVAudioEngine, mobileOutput: JarasMobileAudioOutput? = nil, auxiliarySelectedHardware: Bool = false) {}
    func releaseKeyboardNotes() {}
    func setArmedInstrumentTracks(_ ids: Set<UUID>) {}
    func prepareForClosing() { closed = true }
}
@MainActor final class ProjectDocuments: ObservableObject {
    @Published var busy = false
    @Published var missingAudioPrompt: Bool?
    var ready = true, importingAudio = false, error = ""
    var currentURL: URL?
    var projectTabCount = 1, projectTabIndex = 0
    var recent: [URL] = []
    var openInNewProjectTab: ((URL) -> Void)?
    var activateExistingProjectTab: ((URL) -> Bool)?
    var navigateProjectTab: ((Int) -> Void)?
    var additionalProtectedMediaURLs: () -> Set<URL> = { [] }
    func rememberProjectMedia() async throws {}
    func open(_ url: URL) {
        busy = true
        if url.lastPathComponent == "bad.jl" { ready = false; error = "invalid project" }
        else { currentURL = url; ready = true }
        busy = false
    }
}
@MainActor final class AppContainer {
    let remoteProjectTabID = UUID()
    let show = ShowController(), documents = ProjectDocuments()
    let auth = NSObject()
    let projectAudio: StemAudioPlayback
    let projectRecorder: TrackRecording
    var localPlaybackEnabled = false
    init(sharedAuth: NSObject? = nil, audio: StemAudioPlayback? = nil) throws {
        projectAudio = audio ?? .shared; projectRecorder = sharedAuth == nil ? .shared : TrackRecording()
    }
    func setLocalPlaybackEnabled(_ enabled: Bool) async -> Bool { localPlaybackEnabled = enabled; return true }
    func handleMobileAudioEvent(_ event: MobileAudioSessionEvent) { show.playing = false }
    func closeNativeProject(resumeAudio: Bool) async -> Bool {
        do { try await show.saveForClosing() } catch { documents.error = "save failed"; return false }
        show.playing = false; documents.ready = false; documents.currentURL = nil; localPlaybackEnabled = resumeAudio
        return true
    }
}
@MainActor enum DAWRemoteHostBridge {
    struct Tab { let id: UUID; let name: String; let selected: Bool }
    static var projectTabsProvider: () -> [Tab] = { [] }
    static var selectProjectTabHandler: ((UUID) -> Void)?
    static var documents: ProjectDocuments?
    struct Session { static let nativeHost = Session() }
    static func bind(_ show: ShowController, session: Session) {}
}
@MainActor final class InstrumentLibrary { static let shared = InstrumentLibrary(); func setProjectDirectory(_ url: URL?) {} }
@MainActor final class VideoPlayback {
    static let teleprompter = VideoPlayback(), teleprompter2 = VideoPlayback()
    func open(directory: URL) {}
}
enum TeleprompterRemote { static func setProjectDirectory(_ url: URL) {} }
enum NativeRecentProjectPath { static func resolve(_ path: String, documents: URL) -> URL { URL(fileURLWithPath: path) } }
enum ProjectTabNavigation {
    static func destination(current: Int, count: Int, direction: Int) -> Int? {
        let next = current + direction; return (0..<count).contains(next) ? next : nil
    }
}
// INSERT_NATIVE_PROJECT_TABS
@main struct NativeProjectTabsTest {
    @MainActor static func main() async throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
        func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }
        let tabs = NativeProjectTabs.shared, first = try AppContainer()
        let a = URL(fileURLWithPath: "/tmp/native-tabs/A.jl"), b = URL(fileURLWithPath: "/tmp/native-tabs/B.jl")
        first.documents.currentURL = a; first.show.playing = true; first.show.dirty = true
        tabs.install(first); _ = await first.setLocalPlaybackEnabled(true)
        first.documents.openInNewProjectTab?(b); await settle()
        check(tabs.projects.count == 2 && tabs.selected == 1, "Recent action did not create a second tab")
        let second = tabs.active!
        check(first.show.playing && first.show.dirty && first.documents.currentURL == a, "Opening a tab altered the previous project")
        check(first.projectAudio !== second.projectAudio && first.projectRecorder !== second.projectRecorder, "Tabs share project-owned audio/recording state")
        tabs.select(0); check(tabs.active === first && StemAudioPlayback.shared === first.projectAudio, "Selecting must reuse the original session")
        tabs.open(b); await settle(); check(tabs.projects.count == 2 && tabs.active === second, "Already-open projects must reuse their tab")
        TrackRecording.shared.recording = true; tabs.select(0); tabs.open(URL(fileURLWithPath: "/tmp/native-tabs/C.jl")); await settle()
        check(tabs.active === second && tabs.projects.count == 2, "Switching interrupted recording")
        TrackRecording.shared.recording = false
        second.show.failSave = true; await tabs.close(second.remoteProjectTabID)
        check(tabs.projects.count == 2 && tabs.active === second, "Failed save discarded a tab")
        second.show.failSave = false; await tabs.close(second.remoteProjectTabID)
        check(tabs.projects.count == 1 && tabs.active === first && first.show.playing, "Closing one tab stopped the other")
        tabs.open(URL(fileURLWithPath: "/tmp/native-tabs/bad.jl")); await settle(); await settle()
        check(tabs.projects.count == 1 && tabs.active === first && !first.documents.error.isEmpty, "Failed opening did not restore original tab")
        tabs.open(b); await settle(); tabs.active!.show.failSave = true
        let failedLeave = await tabs.leave(); check(!failedLeave && tabs.projects.count == 2 && first.documents.ready, "Mode exit lost documents after save failure")
        tabs.active!.show.failSave = false
        let left = await tabs.leave(); check(left && tabs.projects.count == 1 && !tabs.active!.documents.ready, "Mode exit did not close saved projects")
        print("NATIVE_PROJECT_TABS_OK: independent sessions, recent action, duplicate reuse, recording guard, save failure, opening rollback and mode exit")
    }
}
