import Foundation

enum ProjectError: Error { case invalid(String) }

// PRODUCTION_DIRECTORY_POLICY

struct StemScan { var folders = [1] }
final class FixtureShow {
    var isPlaying = false
    var canExecute: () -> Bool = { true }
    func canControl() -> Bool { canExecute() }
}
final class TrackRecording {
    static let shared = TrackRecording()
    var recording = false, busy = false
}
final class FixtureDocuments {
    var scan: StemScan? = StemScan()
    var busy = false, adding = false, error = ""
    let show = FixtureShow()
    var nativePendingCreation: (scan: StemScan?, detectBPM: Bool, recordingChannels: Int?)?
    var nativeProjectName = "Concert"
    var nativeNamePrompt = false
    var nativeStorageDirectory: URL?
    var afterNativeStorage: (() -> Void)?
    enum Picker { case storage }
    var nativePicker: Picker?
    var calls: [(detectBPM: Bool, destination: URL?)] = []
    func finish(scan: StemScan?, detectBPM: Bool, destination: URL?, recordingChannels: Int? = nil) {
        calls.append((detectBPM, destination))
    }
    // PRODUCTION_CONFIRMATION_METHODS
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let create = FixtureDocuments()
create.nativeStorageDirectory = root
create.confirmNativeStemImport(detectBPM: true)
precondition(create.calls.count == 1 && create.calls[0].detectBPM)
precondition(create.calls[0].destination == root.appendingPathComponent("Concert/Concert.jl"))
precondition(!create.nativeNamePrompt && create.nativePendingCreation == nil)

let add = FixtureDocuments(); add.adding = true
add.confirmNativeStemImport(detectBPM: false)
precondition(add.calls.count == 1 && add.calls[0].destination == nil && !add.calls[0].detectBPM)
precondition(add.nativePicker == nil && !add.nativeNamePrompt)

let invalid = FixtureDocuments(); invalid.nativeProjectName = " "
invalid.confirmNativeStemImport(detectBPM: false)
precondition(invalid.calls.isEmpty && !invalid.error.isEmpty && !invalid.nativeNamePrompt)
let collision = FixtureDocuments(); collision.nativeStorageDirectory = root
try FileManager.default.createDirectory(at: root.appendingPathComponent("Concert"), withIntermediateDirectories: true)
collision.confirmNativeStemImport(detectBPM: false)
precondition(collision.calls.count == 1 && collision.error.isEmpty)
precondition(collision.calls[0].destination == root.appendingPathComponent("Concert (2)/Concert.jl"))

let chooseStorage = FixtureDocuments(); chooseStorage.nativeProjectName = "New"
chooseStorage.confirmNativeStemImport(detectBPM: true)
precondition(chooseStorage.nativePicker != nil && chooseStorage.calls.isEmpty)
chooseStorage.nativeStorageDirectory = root; chooseStorage.afterNativeStorage?()
precondition(chooseStorage.calls.count == 1 && chooseStorage.calls[0].detectBPM)

let blocked = FixtureDocuments(); TrackRecording.shared.recording = true
blocked.confirmNativeStemImport(detectBPM: false)
precondition(blocked.calls.isEmpty && !blocked.error.isEmpty)
TrackRecording.shared.recording = false; blocked.show.canExecute = { false }; blocked.error = ""
blocked.confirmNativeStemImport(detectBPM: false)
precondition(blocked.calls.isEmpty && !blocked.error.isEmpty)
let empty = FixtureDocuments(); empty.scan = StemScan(folders: [])
empty.confirmNativeStemImport(detectBPM: false)
precondition(empty.calls.isEmpty && !empty.error.isEmpty)
print("PASS native review confirms create/add directly, preserves BPM choice, validates names/collisions, resumes after storage selection and reports blocked import")
