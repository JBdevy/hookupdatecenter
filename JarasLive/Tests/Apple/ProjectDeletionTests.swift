import Foundation
import Combine

enum Failure: Error { case disk }
enum RecentProjectEntry { static var missing = false; static func isMissing(_ url: URL) -> Bool { missing } }
struct Project { var id = UUID(); static func empty(name: String) -> Project { Project() } }
struct Snapshot { var project = Project() }
enum Command { case stopAll }
@MainActor final class Show {
    var isPlaying = false, saving = false, saves = 0, hasUnsavedChanges = true, failSave = false
    var canExecute: () -> Bool = { true }
    var snapshot = Snapshot()
    func saveForClosing() async throws { if failSave { throw Failure.disk }; saves += 1; hasUnsavedChanges = false }
    func send(_ command: Command) {}
    func replaceProject(_ project: Project) throws { snapshot.project = project; hasUnsavedChanges = false }
    func preparePlayback() {}
}
actor Store {
    var selected = true
    func deselect() { selected = false }
    func select(url: URL, id: UUID) { selected = true }
}
struct ProjectFolderDeletion: Identifiable, Sendable {
    var id = UUID(), remainingSeconds = 0, fail = false
    let document: URL
    init(document: URL) throws { self.document = document }
    func contains(_ url: URL) -> Bool { url.path.hasPrefix(document.deletingLastPathComponent().path + "/") }
    func validate() throws { if remainingSeconds > 0 { throw Failure.disk } }
    func remove() throws { if fail { throw Failure.disk } }
}
@MainActor final class TrackRecording {
    static let shared = TrackRecording()
    var recording = false, busy = false
    func closeProject() {}
    func open(directory: URL, project: UUID) {}
}
@MainActor final class FXWindows { static let shared = FXWindows(); func closeAll() {} }
@MainActor final class TeleprompterWindow {
    static let shared = TeleprompterWindow(), second = TeleprompterWindow()
    var visible = false
    func toggle(show: Show) { visible.toggle() }
}
@MainActor final class TeleprompterRemote { static let shared = TeleprompterRemote(); func setDirectory(_ directory: URL?) {} }
@MainActor final class VideoPlayback {
    static let shared = VideoPlayback(), teleprompter = VideoPlayback(), teleprompter2 = VideoPlayback()
    func closeProject() {}; func open(directory: URL) {}
}
@MainActor final class StemAudioPlayback {
    static let shared = StemAudioPlayback()
    func prepareForClosing() {}; func open(directory: URL) {}
}
let testPreferences = UserDefaults(suiteName: "jaras-delete-test-\(UUID())")!
@MainActor final class ProjectDocuments {
    let show = Show(), store = Store()
    var ready = true, busy = false, importingAudio = false, adding = false
    var status = "", error = "", migrationNotice = ""
    var currentURL: URL? = URL(fileURLWithPath: "/fixture/current/Show.jl")
    var recent = [URL(fileURLWithPath: "/fixture/current/Show.jl"), URL(fileURLWithPath: "/fixture/other/Show.jl")]
    var scan: Int?, folderReview: Int?, addTarget: Int?, missingAudioPrompt: Int?, pendingAudioDrop: Int?
    var warnings: [String] = [], missingAudioPaths: Set<String> = []
    var opened = UUID()
    // INSERT_DELETION_CONTROLLER
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
Task { @MainActor in
    let stale = ProjectDocuments()
    let staleURL = stale.recent[0], existingURL = stale.recent[1]
    RecentProjectEntry.missing = true
    stale.requestDeletion(staleURL)
    require(stale.recent == [existingURL], "missing entry alone is removed")
    require(stale.pendingDeletion == nil && !stale.busy && stale.ready, "no file deletion or session transition for missing recent")
    RecentProjectEntry.missing = false

    for (other, failure) in [(false, false), (true, false), (false, true)] {
        let docs = ProjectDocuments(), oldProject = UUID()
        docs.show.snapshot.project.id = oldProject
        let target = docs.recent[other ? 1 : 0]
        var deletion = try ProjectFolderDeletion(document: target)
        deletion.remainingSeconds = 3
        docs.pendingDeletion = deletion
        docs.deleteProject(deletion)
        require(!docs.busy && docs.ready, "countdown cannot be bypassed through controller")
        deletion.remainingSeconds = 0; deletion.fail = failure; docs.pendingDeletion = deletion
        docs.deleteProject(deletion)
        while docs.busy { try await Task.sleep(nanoseconds: 1_000_000) }
        let selected = await docs.store.selected
        require(docs.show.canExecute(), "command gate restored")
        if failure {
            require(docs.ready && docs.currentURL != nil && selected, "failed deletion keeps current document selected")
            require(docs.recent.count == 2 && !docs.error.isEmpty, "failed deletion retains recent entry and reports error")
        } else {
            require(!docs.ready && docs.currentURL == nil && !selected, "success returns to startup and detaches store")
            require(docs.show.snapshot.project.id != oldProject && !docs.show.hasUnsavedChanges, "old project leaves memory")
            require(docs.recent.count == 1 && !docs.recent.contains(target), "deleted recent entry removed")
            require(docs.show.saves == (other ? 1 : 0), "save unrelated project, never save deleted project")
        }
    }
    let docs = ProjectDocuments()
    docs.show.failSave = true
    let deletion = try ProjectFolderDeletion(document: docs.recent[1]); docs.pendingDeletion = deletion
    docs.deleteProject(deletion)
    while docs.busy { try await Task.sleep(nanoseconds: 1_000_000) }
    require(docs.ready && docs.recent.count == 2 && !docs.error.isEmpty, "failed save aborts deletion")
    print("PROJECT_DELETE_COUNTDOWN_STARTUP_STORE_RESET_SAVE_OTHER_AND_FAILURE_RECOVERY_OK")
    exit(0)
}
RunLoop.main.run()
