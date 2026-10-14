import Foundation

// Only backend/audio dependencies are stand-ins. Commit blocks come directly
// from ProjectDocuments, and saves write isolated temporary documents.
enum ProjectError: Error { case rejected, noDocument }
struct Project: Codable, Equatable { var id: UUID; var name: String }
struct Snapshot { var project: Project }
final class NSItemProvider {}
enum AudioDropLayout { case sameTrack }
@MainActor enum EditorCloseRecorder {
    static var currentProject: () -> UUID? = { nil }
    static var closedProjects: [UUID?] = []
    static func close() { closedProjects.append(currentProject()) }
}
@MainActor final class FXWindows { static let shared = FXWindows(); func closeAll() { EditorCloseRecorder.close() } }
@MainActor enum AutomationWindows { static func closeAll() { EditorCloseRecorder.close() } }
@MainActor final class MIDIEditorWindows { static let shared = MIDIEditorWindows(); func closeAll() { EditorCloseRecorder.close() } }
@MainActor enum SetlistSessionState { static func reset() {} }
@MainActor enum TrackMixerRow { static func resetProjectSession() {} }
@MainActor final class TPNoticeController { static let shared = TPNoticeController(); func clear() {} }
@MainActor final class TeleprompterTimerController {
    static let shared = TeleprompterTimerController()
    var running = false
    func stopAndReset() { running = false }
}
@MainActor final class FixtureShow {
    var snapshot: Snapshot
    var hasUnsavedChanges = false, failReplacement = false, replacementWasLocked = false
    var canExecute: () -> Bool = { true }
    var projectSessionID = UUID()
    init(_ project: Project) { snapshot = Snapshot(project: project) }
    func saveForClosing() async throws { hasUnsavedChanges = false }
    func replaceProject(_ project: Project) throws {
        replacementWasLocked = !canExecute()
        if failReplacement { throw ProjectError.rejected }
        snapshot.project = project
        projectSessionID = UUID()
    }
}
@MainActor final class FixtureStore {
    private(set) var url: URL?
    private var projectID: UUID?
    func select(url: URL, id: UUID) async { self.url = url; projectID = id; await Task.yield() }
    func save(_ project: Project) throws {
        guard let url, project.id == projectID else { throw ProjectError.noDocument }
        try JSONEncoder().encode(project).write(to: url, options: .atomic)
    }
}
@MainActor final class ProjectDocuments {
    let show: FixtureShow
    let store = FixtureStore()
    var ready = true, canCancelOpening = true
    var currentURL: URL?
    var storeDuringPreload: URL?
    // INSERT_PENDING_DROP_TYPE
    var pendingAudioDrop: PendingAudioDrop?
    var audioImportError = ""
    var importedDrops = 0
    init(_ project: Project, url: URL) { show = FixtureShow(project); currentURL = url }
    func rememberProjectMedia() async throws { await Task.yield() }
    func preloadTimelineWaveforms(_ project: Project, at url: URL) async {
        storeDuringPreload = store.url
        await Task.yield()
    }
    func importAudio(_ providers: [NSItemProvider], start: Double, track: UUID?, song: UUID, layout: AudioDropLayout, gap: Double) -> Bool {
        importedDrops += 1
        return true
    }
    func confirmCapturedDrop(_ drop: PendingAudioDrop) {
        let show = show, documents = self
        let layout = AudioDropLayout.sameTrack, gap = 0.0
        // INSERT_DROP_CONFIRMATION
    }
    // INSERT_SESSION_HELPERS
    func activate(_ project: Project, at url: URL) async throws {
        // INSERT_ACTIVATION_COMMIT
    }
    func finishCreationOrAppend(_ project: Project, at url: URL) async throws {
        // The outer Create/Add operation holds this lock before its media worker.
        let canExecute = show.canExecute
        show.canExecute = { false }
        defer { show.canExecute = canExecute }
        // The creation worker starts after editors close and presets save.
        closeProjectEditors()
        let result: (Project, [String]) = (project, [])
        // INSERT_CREATION_COMMIT
    }
}

Task { @MainActor in
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; fputs("FAIL: \(message)\n", stderr) }
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("catlive-activation-test-" + UUID().uuidString)
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let oldURL = root.appendingPathComponent("Current.jl"), newURL = root.appendingPathComponent("Copied.jl")
        for creation in [false, true] {
            // Finder copies preserve UUIDs: checking only UUID at save time
            // cannot prevent overwriting the wrong document in this case.
            let id = UUID()
            let current = Project(id: id, name: "current session")
            let incoming = Project(id: id, name: "different copied document")
            for fails in [true, false] {
                try JSONEncoder().encode(current).write(to: oldURL)
                let incomingBytes = try JSONEncoder().encode(incoming)
                try incomingBytes.write(to: newURL)
                let docs = ProjectDocuments(current, url: oldURL)
                EditorCloseRecorder.currentProject = { docs.show.snapshot.project.id }
                EditorCloseRecorder.closedProjects = []
                let selection = AudioExportSelection.shared, selectedItem = UUID()
                selection.setTracks([selectedItem], song: id)
                selection.setClips([selectedItem], song: id)
                selection.setRegions([selectedItem], song: id)
                TimelineAreaSelection.shared.update(song: id, from: 2, to: 8)
                TeleprompterTimerController.shared.running = true
                let pendingDrop = ProjectDocuments.PendingAudioDrop(providers: [NSItemProvider()], start: 12,
                    track: selectedItem, song: id, project: id, session: docs.show.projectSessionID)
                docs.pendingAudioDrop = pendingDrop
                docs.audioImportError = "Previous project's import error"
                await docs.store.select(url: oldURL, id: id)
                docs.show.failReplacement = fails
                do {
                    if creation { try await docs.finishCreationOrAppend(incoming, at: newURL) }
                    else { try await docs.activate(incoming, at: newURL) }
                    check(!fails, "A backend load failure must propagate")
                } catch { check(fails, "A successful replacement must not throw") }
                check(docs.show.replacementWasLocked && docs.show.canExecute(), "The commit must lock commands and restore the prior gate")
                check(EditorCloseRecorder.closedProjects.count == 3 && EditorCloseRecorder.closedProjects.allSatisfy { $0 == current.id },
                      "FX, automation and MIDI editors must close against the outgoing project")
                if creation { check(docs.storeDuringPreload == oldURL, "Media preparation must not redirect saves") }
                if fails {
                    check(docs.pendingAudioDrop?.id == pendingDrop.id && !docs.audioImportError.isEmpty,
                          "Rejected activation must retain the current pending import")
                    docs.confirmCapturedDrop(pendingDrop)
                    check(docs.importedDrops == 1, "A pending drop in the unchanged session must still work")
                    check(TeleprompterTimerController.shared.running, "A rejected activation must retain the running timer")
                    check(selection.tracks(id) == [selectedItem] && selection.clips(id) == [selectedItem] && selection.regions(id) == [selectedItem] && TimelineAreaSelection.shared.range != nil,
                          "Rejected activation must retain the current selection")
                    check(docs.store.url == oldURL && docs.show.snapshot.project == current, "A rejected replacement retains the current save destination")
                    try docs.store.save(docs.show.snapshot.project)
                    check(try Data(contentsOf: newURL) == incomingBytes, "Saving after a rejected same-UUID replacement must not overwrite the incoming document")
                } else {
                    check(docs.pendingAudioDrop == nil && docs.audioImportError.isEmpty,
                          "A committed replacement must dismiss old import options and errors")
                    let nextDrop = ProjectDocuments.PendingAudioDrop(providers: [NSItemProvider()], start: 20,
                        track: selectedItem, song: id, project: id, session: docs.show.projectSessionID)
                    docs.pendingAudioDrop = nextDrop
                    docs.confirmCapturedDrop(pendingDrop)
                    check(docs.importedDrops == 0,
                          "A late confirmation from the previous session must not import into a same-UUID copy")
                    check(docs.pendingAudioDrop?.id == nextDrop.id,
                          "A late confirmation must not dismiss the new session's pending drop")
                    check(!TeleprompterTimerController.shared.running, "A committed replacement must reset the previous project's timer")
                    check(selection.tracks(id).isEmpty && selection.clips(id).isEmpty && selection.regions(id).isEmpty && TimelineAreaSelection.shared.range == nil,
                          "A same-UUID copy must start without old export or grid-area selections")
                    check(docs.store.url == newURL && docs.show.snapshot.project == incoming, "Only a committed replacement selects the new save destination")
                }
            }
        }
        if failures == 0 { print("PROJECT_ACTIVATION_AND_CREATE_COMMIT_PRESERVE_SAVE_DESTINATION_ON_BACKEND_FAILURE_OK") }
        exit(failures == 0 ? 0 : 1)
    } catch {
        fputs("Project activation fixture failed: \(error)\n", stderr)
        exit(1)
    }
}
dispatchMain()
