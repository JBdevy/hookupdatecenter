import Foundation
import UniformTypeIdentifiers

// Panel, save and media-work stand-ins keep this harness away from real files.
// The admission and snapshot-capture control flow is extracted from production.
enum ProjectError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
struct Project: Equatable {
    var id = UUID()
    var pluginState = "old preset"
    var cursor = 0.0
    static func empty(name: String) -> Project { Project() }
}
struct Snapshot { var project = Project() }
struct StemScan {}
enum ProjectDirectoryPolicy { static func validate(_ url: URL) throws {} }
final class TrackRecording {
    static let shared = TrackRecording()
    var recording = false, busy = false
}
enum PanelReply { case OK, cancel }
final class NSSavePanel {
    var allowedContentTypes: [UTType] = []
    var nameFieldStringValue = "", canCreateDirectories = false
    var url: URL?
    func runModal() -> PanelReply { .cancel }
}
@MainActor final class FixtureShow {
    var snapshot = Snapshot()
    var isPlaying = false, hasUnsavedChanges = true
    var failSave = false, changedWhileSaving = false
    var canExecute: () -> Bool = { true }
    var saveWasLocked = false
    var cursor = 42.5
    var saved: Project?
    func flushProject() async throws {
        saveWasLocked = !canExecute()
        if failSave { throw ProjectError.invalid("Disk unavailable") }
        // Native editors hand the latest plugin preset to prepareForSave().
        snapshot.project.pluginState = "captured current preset"
        saved = snapshot.project
        saved?.cursor = cursor
        hasUnsavedChanges = changedWhileSaving
        await Task.yield()
    }
    func saveForClosing() async throws {
        if hasUnsavedChanges { try await flushProject() }
        if hasUnsavedChanges { throw ProjectError.invalid("Project changed while saving") }
    }
}
@MainActor final class FixtureStore {
    let show: FixtureShow
    init(show: FixtureShow) { self.show = show }
    func load() async throws -> Project? { show.saved }
}
@MainActor final class ProjectDocuments {
    var ready = true, busy = false, adding = true, showingOpenProjectAlert = false
    var currentURL: URL?
    var appendDestination: (project: UUID, url: URL)?
    var removal = "", error = "", status = ""
    let show = FixtureShow()
    lazy var store = FixtureStore(show: show)
    var openingRequests = 0, migrationRequests = 0
    var capturedBase: Project?
    func importDAW(_ url: URL) { migrationRequests += 1 }
    func closeProjectEditors() {}
    func runAppend() { finish(scan: StemScan(), detectBPM: false) }
    // INSERT_TRANSITION_METHODS
}

Task { @MainActor in
    var failures = 0
    func check(_ condition: Bool, _ message: String = "Unexpected transition state") {
        if !condition { failures += 1; fputs("FAIL: \(message)\n", stderr) }
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("catlive-transition-test-" + UUID().uuidString)
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let current = root.appendingPathComponent("Show.jl")
        let alias = root.appendingPathComponent("Alias.jl")
        try Data([1]).write(to: current)
        try fm.createSymbolicLink(at: alias, withDestinationURL: current)
        let docs = ProjectDocuments()
        docs.currentURL = current
        let dirty = docs.show.snapshot.project
        for path in [current, root.appendingPathComponent("unused/../Show.jl"), alias] { docs.open(path) }
        check(docs.openingRequests == 0, "Reopening the active document must not read a stale disk snapshot")
        check(docs.show.snapshot.project == dirty && docs.show.hasUnsavedChanges && docs.show.saved == nil)
        docs.open(root.appendingPathComponent("Other.jl"))
        check(docs.openingRequests == 1, "Different documents still enter the opening workflow")
        docs.ready = false; docs.open(current)
        check(docs.openingRequests == 2, "A previous path is loadable when no project is active")
        if failures == 0 { print("PROJECT_REOPEN_PRESERVES_UNSAVED_EDITS_AND_PATH_ALIASES_OK") }

        for (fails, changes) in [(false, false), (true, false), (false, true)] {
            let docs = ProjectDocuments()
            docs.currentURL = current
            docs.appendDestination = (docs.show.snapshot.project.id, current)
            docs.show.failSave = fails; docs.show.changedWhileSaving = changes
            docs.runAppend()
            while docs.busy { await Task.yield() }
            if fails || changes {
                check(docs.capturedBase == nil && !docs.error.isEmpty,
                             "An unsuccessful or stale save must never start an append from an unsafe snapshot")
            } else {
                check(docs.capturedBase == docs.show.saved && docs.capturedBase?.pluginState == "captured current preset",
                             "Add Project must retain preset state captured while saving the current project")
                check(docs.capturedBase?.cursor == 42.5, "The appended document retains the newly saved cursor")
            }
            check(docs.show.saveWasLocked && docs.show.canExecute(), "Commands stay locked during transition and the original gate is restored")
        }
        let navigation = ProjectDocuments()
        navigation.currentURL = current
        navigation.appendDestination = (navigation.show.snapshot.project.id, current)
        navigation.show.hasUnsavedChanges = false
        navigation.runAppend()
        while navigation.busy { await Task.yield() }
        check(navigation.capturedBase?.cursor == 42.5, "Cursor-only navigation is saved before appending")
        if failures == 0 { print("PROJECT_APPEND_CAPTURES_COMMITTED_PRESETS_CURSOR_AND_STOPS_ON_SAVE_FAILURE_OR_EDIT_RACE_OK") }
        exit(failures == 0 ? 0 : 1)
    } catch {
        fputs("Project transition test failed: \(error)\n", stderr)
        exit(1)
    }
}
dispatchMain()
