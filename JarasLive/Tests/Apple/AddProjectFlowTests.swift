import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Stand-ins prevent this extracted production workflow from displaying panels,
// scanning audio, writing projects, or depending on the running application.
enum PanelReply { case OK, cancel }
final class NSOpenPanel {
    static var creations = 0
    static var presentations = 0
    static var nextURLs: [URL] = []
    static var reply = PanelReply.OK
    static var onRun: (() -> Void)?
    static var last: NSOpenPanel?
    var canChooseDirectories = false, canChooseFiles = true, allowsMultipleSelection = false
    var urls: [URL] { Self.nextURLs }
    init() { Self.creations += 1; Self.last = self }
    func runModal() -> PanelReply { Self.presentations += 1; Self.onRun?(); return Self.reply }
}
final class NSSavePanel {
    static var creations = 0
    var allowedContentTypes: [UTType] = []
    var nameFieldStringValue = ""
    var canCreateDirectories = false
    var url: URL? = URL(fileURLWithPath: "/tmp/catlive-add-flow-unused.jl")
    init() { Self.creations += 1 }
    func runModal() -> PanelReply { .cancel }
}
struct StemScan {}
struct FixtureProject { var id = UUID() }
struct FixtureSnapshot { var project = FixtureProject() }
final class FixtureShow {
    var snapshot = FixtureSnapshot()
    var isPlaying = false
    var authorized = true
    func canExecute() -> Bool { authorized }
}
final class TrackRecording {
    static let shared = TrackRecording()
    var recording = false, busy = false
}

// EXTRACTED_PRODUCTION_TYPES

@MainActor func runAddProjectFlowTests() {
    let a = URL(fileURLWithPath: "/tmp/catlive-add-flow/A", isDirectory: true)
    let b = URL(fileURLWithPath: "/tmp/catlive-add-flow/B", isDirectory: true)
    let c = URL(fileURLWithPath: "/tmp/catlive-add-flow/C", isDirectory: true)
    let destination = URL(fileURLWithPath: "/tmp/catlive-add-flow/Current.jl")
    let other = URL(fileURLWithPath: "/tmp/catlive-add-flow/Other.jl")
    func openDocument() -> ProjectDocuments {
        let documents = ProjectDocuments()
        documents.ready = true; documents.currentURL = destination
        return documents
    }
    func beginAppend(_ documents: ProjectDocuments) {
        NSOpenPanel.nextURLs = [a, b, c]; NSOpenPanel.reply = .OK; NSOpenPanel.onRun = nil
        documents.addProject()
    }
    func assertCleared(_ documents: ProjectDocuments) {
        precondition(documents.scan == nil && documents.folderReview == nil)
        precondition(documents.folders.isEmpty && documents.selectedFolders.isEmpty)
        precondition(documents.removal.isEmpty && !documents.adding && !documents.hasAppendDestination)
    }
    let absent = ProjectDocuments()
    absent.addProject()
    precondition(absent.showingOpenProjectAlert && NSOpenPanel.creations == 0 && NSSavePanel.creations == 0,
                 "Add Project without an open document alerts without opening any panel")
    absent.cancelImport(); absent.chooseStems(adding: true)
    precondition(absent.showingOpenProjectAlert && NSOpenPanel.creations == 0)
    assertCleared(absent)

    let documents = openDocument()
    beginAppend(documents)
    precondition(NSOpenPanel.presentations == 1 && NSSavePanel.creations == 0)
    precondition(NSOpenPanel.last!.canChooseDirectories && !NSOpenPanel.last!.canChooseFiles && NSOpenPanel.last!.allowsMultipleSelection,
                 "append asks only for source folders, never a .jl source file or destination")
    precondition(documents.adding && documents.folderReview == [a, b, c] && documents.selectedFolders.isEmpty)
    precondition(documents.scan == nil && documents.analyzed.isEmpty, "folder review precedes scanning")
    documents.confirmFolders([b, a])
    precondition(documents.selectedFolders == [b, a] && documents.analyzed == [[b, a]])
    precondition(documents.folderReview == nil && documents.scan != nil)
    documents.reviewFolderOrder()
    precondition(documents.folderReview == [a, b, c] && documents.selectedFolders == [b, a] && documents.scan == nil,
                 "Back restores every original option and the explicit selected order")
    let review = FolderImportReview(folders: documents.folderReview!, selectedFolders: documents.selectedFolders,
                                    appending: documents.adding, cancel: {}, confirm: { _ in })
    precondition(review.testedSelection.folders == [a, b, c] && review.testedSelection.selected == [b, a],
                 "the real review initializer restores B then A rather than sorting or selecting everything")
    documents.confirmFolders([b, a]); documents.resolveImportDestination()
    precondition(documents.resolvedURL == destination && NSSavePanel.creations == 0,
                 "append reuses the captured project's current URL without any save dialog")
    documents.removal = "prefix"; documents.error = "old"; documents.warnings = ["old"]; documents.status = "old"
    documents.cancelImport(); assertCleared(documents)
    precondition(documents.error.isEmpty && documents.warnings.isEmpty && documents.status.isEmpty && !documents.showingOpenProjectAlert)

    let single = openDocument()
    NSOpenPanel.nextURLs = [b]; single.addProject()
    precondition(single.folderReview == [b] && single.scan == nil, "one folder still gets append review")
    single.cancelImport()

    for changedSession in [true, false] {
        let stale = openDocument(); beginAppend(stale); stale.confirmFolders([b, a])
        if changedSession { stale.show.snapshot.project.id = UUID() } else { stale.currentURL = other }
        stale.resolveImportDestination()
        precondition(stale.resolvedURL == nil && !stale.error.isEmpty && NSSavePanel.creations == 0,
                     "both project identity and current URL must still match the captured append destination")
    }
    let closed = openDocument(); beginAppend(closed); closed.confirmFolders([a])
    closed.ready = false; closed.currentURL = nil; closed.resolveImportDestination()
    precondition(closed.showingOpenProjectAlert && closed.resolvedURL == nil && NSSavePanel.creations == 0,
                 "closing the document during review cannot redirect append to a new file")

    let panelChangedSession = openDocument()
    NSOpenPanel.nextURLs = [a]
    NSOpenPanel.onRun = { panelChangedSession.show.snapshot.project.id = UUID() }
    panelChangedSession.addProject(); NSOpenPanel.onRun = nil
    panelChangedSession.confirmFolders([a]); panelChangedSession.resolveImportDestination()
    precondition(panelChangedSession.resolvedURL == nil && !panelChangedSession.error.isEmpty,
                 "session identity is captured before the source panel runs")

    let cancelled = openDocument(); beginAppend(cancelled); cancelled.confirmFolders([a])
    NSOpenPanel.reply = .cancel; cancelled.addProject(); assertCleared(cancelled)
    NSOpenPanel.reply = .OK
    let guarded = openDocument()
    let count = NSOpenPanel.creations
    guarded.busy = true; guarded.addProject(); guarded.busy = false
    guarded.show.isPlaying = true; guarded.addProject(); guarded.show.isPlaying = false
    TrackRecording.shared.recording = true; guarded.addProject(); TrackRecording.shared.recording = false
    TrackRecording.shared.busy = true; guarded.addProject(); TrackRecording.shared.busy = false
    precondition(NSOpenPanel.creations == count && NSSavePanel.creations == 0,
                 "busy, playback and recording guards never display panels")
    print("ADD_PROJECT_REAL_FLOW_OK no-project alert; folders-only; B,A back restoration; cancel; UUID+URL destination guards; zero save panels")
}
MainActor.assumeIsolated { runAddProjectFlowTests() }
