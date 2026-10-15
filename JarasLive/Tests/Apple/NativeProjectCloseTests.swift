import Foundation

enum ProjectError: Error { case invalid(String) }
struct Project { static func empty(name: String) -> Project { Project() } }
@MainActor final class Show {
    var canExecute: () -> Bool = { true }
    var failSave = false, replaces = 0
    enum Command { case stopAll }
    func send(_ value: Command) {}
    func saveForClosing() async throws {
        if failSave { throw ProjectError.invalid("Save failed") }
    }
    func replaceProject(_ project: Project) throws { replaces += 1 }
}
@MainActor final class Resource {
    static let shared = Resource(), teleprompter = Resource(), teleprompter2 = Resource()
    var closes = 0
    func finishAndWait() async {}
    func closeProject() { closes += 1 }
    func prepareForClosing() { closes += 1 }
}
typealias VideoPlayback = Resource
typealias TrackRecording = Resource
typealias StemAudioPlayback = Resource
@MainActor final class TimelineAudioWaveform {
    static let shared = TimelineAudioWaveform()
    var closes = 0
    func closeProject() async { closes += 1 }
}
actor Store {
    var selected = true
    func deselect() { selected = false }
}
@MainActor final class Documents {
    let show = Show(), store = Store()
    var busy = false, importingAudio = false, ready = true
    var error = "", status = "", opened = UUID()
    var currentURL: URL? = URL(fileURLWithPath: "/test/project.jl")
    var nativePicker: Int?, nativeAudioTarget: Int?, nativePendingCreation: Int?, afterNativeStorage: Int?
    var warnings = ["warning"], missingAudioPaths = ["missing"]
    var missingAudioPrompt: Int?, migrationNotice = "notice", pendingDeletion: Int?
    var remembered = false, reset = false
    func rememberProjectMedia() async throws { remembered = true }
    func resetProjectSelections() { reset = true }
    func clearImportSelection() {}
    func cancelNativePackageImport() {}
    // PRODUCTION_CLOSE
}

Task { @MainActor in
    for failure in ["save", "suspend", "busy", "none"] {
        let documents = Documents(), before = Resource.shared.closes
        let oldSession = documents.opened, oldURL = documents.currentURL
        documents.show.failSave = failure == "save"
        documents.busy = failure == "busy"
        var suspended = false
        do {
            try await documents.closeNativeProject {
                precondition(documents.remembered && documents.busy)
                if failure == "suspend" { throw ProjectError.invalid("Hardware still stopping") }
                suspended = true
            }
            precondition(failure == "none")
            precondition(suspended && !documents.ready && documents.currentURL == nil)
            precondition(documents.show.replaces == 1 && documents.opened != oldSession)
            precondition(documents.reset && documents.warnings.isEmpty && documents.migrationNotice.isEmpty)
            let selected = await documents.store.selected
            precondition(!selected && TimelineAudioWaveform.shared.closes == 1)
        } catch {
            precondition(failure != "none")
            precondition(documents.ready && documents.currentURL == oldURL)
            precondition(documents.opened == oldSession && documents.show.replaces == 0)
            precondition(Resource.shared.closes == before, "A failed save or hardware suspension must preserve the current resources")
        }
        precondition(documents.show.canExecute())
        precondition(documents.busy == (failure == "busy"))
    }
    print("NATIVE_PROJECT_CLOSE_UNLOAD_AND_SAVE_HARDWARE_FAILURE_PRESERVATION_OK")
    exit(0)
}
RunLoop.main.run()
