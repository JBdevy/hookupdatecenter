import Foundation

@main struct RemoteProjectOpeningTests {
    @MainActor static func main() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: message, code: 1) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remote-opening-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Current.jl"), destination = folder.appendingPathComponent("Next.jl")
        let documents = ProjectDocuments(), id = UUID()
        documents.ready = true; documents.currentURL = original
        documents.begin(id, destination: destination)
        documents.missingAudioPrompt = true; documents.finish()
        try require(documents.result.id == id && documents.result.state == "waiting" && documents.pending, "Missing media must keep the operation pending")
        documents.missingAudioPrompt = nil; documents.currentURL = destination; documents.finish()
        try require(documents.result.id == id && documents.result.state == "completed" && !documents.pending, "Resolved media must complete the same request")
        documents.finish()
        try require(documents.result.state == "completed", "Terminal result must survive later snapshots")

        let cancel = UUID(); documents.begin(cancel, destination: original); documents.finish()
        try require(documents.result.state == "cancelled" && documents.result.error.isEmpty, "Cancellation must preserve the old project and close the loading modal")
        let failure = UUID(); documents.begin(failure, destination: original); documents.error = "Cannot read project"; documents.finish()
        try require(documents.result.state == "failed" && !documents.result.error.isEmpty && !documents.pending, "Load failure must not leave Remote blocked")
        documents.error = ""
        let current = UUID(); documents.begin(current, destination: original)
        ProjectDocuments.finishRemoteProjectOpening(failure, state: "failed", error: "Late failure")
        try require(documents.result.id == current && documents.result.state == "opening" && documents.result.error.isEmpty, "An old request cannot override a newer opening")

        // A backup is opened as its restored .jl, not as the source .bkjl.
        let backupID = UUID(), backup = folder.appendingPathComponent("Backup.bkjl")
        documents.begin(backupID, destination: backup)
        documents.restored(current, destination: original)
        documents.restored(backupID, destination: destination)
        documents.currentURL = destination; documents.finish()
        try require(documents.result.state == "completed", "A restored backup was misreported as cancelled because its URL changed")

        try Data().write(to: destination)
        let alias = folder.appendingPathComponent("Alias.jl")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
        documents.begin(UUID(), destination: alias); documents.finish()
        try require(documents.result.state == "completed", "An alias to the current project must complete without reloading")

        // A new tab may fail while another document supplies the Remote snapshot.
        let anotherTab = ProjectDocuments(), newTabID = UUID()
        anotherTab.begin(newTabID, destination: original); anotherTab.error = "Invalid project"; anotherTab.finish()
        try require(documents.result.id == newTabID && documents.result.state == "failed", "Failed-tab state was lost when the previous document became active")
        print("REMOTE_PROJECT_OPENING_COMPLETION_ERROR_CANCEL_MISSING_BACKUP_ALIAS_STALE_NEW_TAB_OK")
    }
}
