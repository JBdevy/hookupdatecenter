import Foundation
@MainActor enum TrackRecording {
    static let shared = State()
    final class State { var recording = false; var busy = false }
}
enum NativeStemFolderBrowser {
    static func contains(_ url: URL, in root: URL) -> Bool {
        let child = url.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = root.standardizedFileURL.resolvingSymlinksInPath().path
        return child == parent || child.hasPrefix(parent + "/")
    }
}
@MainActor final class ProjectDocuments {
    enum NativePicker { case project, projectFolder, package }
    var error = ""
    var busy = false
    var nativePicker: NativePicker?
    var nativePackagePrompt: Int?
    var nativePendingProject: URL?
    var nativeProjectScope: URL?
    var nativeStorageScopes: [URL] = []
    var opened: [URL] = [], archives: [URL] = [], migrated: [URL] = []
    func open(_ url: URL) { opened.append(url) }
    func importPortablePackage(_ url: URL) { archives.append(url) }
    func importNativeDAW(_ url: URL) { migrated.append(url) }
    func cancelNativePackageImport() { nativePackagePrompt = nil }
    // PRODUCTION_METHODS
    func choose(_ url: URL) { nativePicker = nil; receiveNativeProject(url) }
}
@main struct NativeProjectBrowseTests {
    @MainActor static func main() {
        let documents = ProjectDocuments()
        documents.browse()
        precondition(documents.nativePicker == .project && documents.nativePackagePrompt == nil)
        let internalFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/CatLive/Test.jl")
        documents.choose(internalFile)
        precondition(documents.opened == [internalFile] && documents.archives.isEmpty, ".jl must open in place, never unzip")
        let external = URL(fileURLWithPath: "/Volumes/External/Show/session.jl")
        documents.choose(external)
        precondition(documents.nativePicker == nil && documents.nativePendingProject == external && documents.opened == [internalFile, external], "Open the selected external .jl immediately, retaining its file grant")
        documents.cancelNativeProjectOpen()
        precondition(documents.nativePendingProject == nil && documents.nativeProjectScope == nil)
        documents.nativeStorageScopes = [external.deletingLastPathComponent()]
        documents.choose(external)
        precondition(documents.opened.last == external && documents.nativePicker == nil, "An authorized project reopens without asking again")
        let zip = external.deletingPathExtension().appendingPathExtension("ziplive")
        documents.choose(zip)
        precondition(documents.archives == [zip] && documents.opened.count == 3, "ZipLive keeps its import/destination flow")
        let reaper = external.deletingPathExtension().appendingPathExtension("rpp")
        let logic = external.deletingPathExtension().appendingPathExtension("logicx")
        documents.choose(reaper); documents.choose(logic)
        precondition(documents.migrated == [reaper, logic], "Recognize both external DAW project formats")
        documents.busy = true; documents.browse()
        precondition(documents.nativePicker == nil, "Cannot start a second picker during project operations")
        print("NATIVE_RECENTS_JL_ZIPLIVE_ROUTING_AND_FOLDER_ACCESS_OK")
    }
}
