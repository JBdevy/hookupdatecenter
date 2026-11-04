import AppKit
import AVFoundation
import UniformTypeIdentifiers
@testable import JarasApplication

@MainActor final class PasteExecutor: CommandExecutor {
    var project = Project.empty(name: "Destination")
    var transport = TransportState(playing: false, position: 0, editPosition: 73.125,
        queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    func load(_ value: Project) throws { project = value; transport.songId = value.songs[0].id }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func applyProjectEdit(_ value: Project) throws { try value.validate(); project = value }
    func pasteItems(_ entries: [GridItemClipboard.Entry], song: UUID, moving: Bool) throws { try project.pasteItems(entries, song: song, moving: moving) }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws { if command == .editSeek { transport.editPosition = value } }
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
}
@MainActor final class ProjectDocuments {
    let show: ShowController
    var currentURL: URL?
    var ready = true, busy = false, status = "", error = ""
    struct Audio { var mediaDirectory: URL? }
    var projectAudio = Audio()
    init(show: ShowController, file: URL) { self.show = show; currentURL = file }
    // INSERT_DOCUMENT_PASTE
}
// INSERT_MEDIA_CLIPBOARD

@main struct Runner {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let from = root.appendingPathComponent("Source"), to = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: from.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let media = from.appendingPathComponent("Stems/source.wav")
        try Data("independent media copy".utf8).write(to: media)
        var source = Project.empty(name: "Source")
        var track = Track(id: UUID(), name: "Piano", role: .keys)
        let clip = AudioClip(id: UUID(), name: "Piano.wav", startTime: 12, duration: 5, audioFile: AudioFile(path: "Stems/source.wav"))
        track.clips = [clip]; source.songs[0].tracks = [track]
        let sourceShow = try ShowController(executor: PasteExecutor(), persistence: MemoryProjectStore(), initialProject: source)
        precondition(sourceShow.copyItems([clip.id]))
        let clipboard = GridMediaClipboard.shared
        clipboard.items = sourceShow.copiedGridItems; clipboard.directory = from; clipboard.session = sourceShow.projectSessionID
        clipboard.didCopyItems()
        let empty = Project.empty(name: "Other tab")
        let destination = try ShowController(executor: PasteExecutor(), persistence: MemoryProjectStore(), initialProject: empty)
        let documents = ProjectDocuments(show: destination, file: to.appendingPathComponent("Other tab.jl"))
        var pasted: Set<UUID> = []
        documents.pasteGridItems(selectedTracks: []) { pasted = $0 }
        while documents.busy { try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(pasted.count == 1 && destination.current?.tracks.count == 1)
        let copied = destination.current!.tracks[0].clips[0]
        precondition(copied.id != clip.id && abs(copied.startTime - 73.125) < 0.000001)
        precondition(destination.current!.tracks[0].name == "Piano")
        let copiedData = try Data(contentsOf: to.appendingPathComponent(copied.audioFile!.path))
        let sourceData = try Data(contentsOf: media)
        precondition(copiedData == sourceData)
        precondition(sourceShow.snapshot.project == source && !sourceShow.hasUnsavedChanges)
        destination.undo(); precondition(destination.snapshot.project == empty, "The new track and item must undo together")
        destination.redo(); precondition(destination.current?.tracks[0].clips.count == 1)
        let target = destination.current!.tracks[0].id
        destination.send(.editSeek, value: 90)
        documents.pasteGridItems(selectedTracks: [target]) { pasted = $0 }
        while documents.busy { try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(destination.current?.tracks.count == 1 && destination.current?.tracks[0].clips.count == 2)
        precondition(destination.current?.tracks[0].clips.last?.startTime == 90)
        try FileManager.default.removeItem(at: media)
        let before = destination.snapshot.project
        documents.pasteGridItems(selectedTracks: [target]) { _ in preconditionFailure("Missing media cannot complete") }
        while documents.busy { try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(destination.snapshot.project == before && destination.modalNotice?.isEmpty == false)
        print("PROJECT_DOCUMENT_PASTE_EMPTY_TAB_CREATES_TRACK_COPIES_MEDIA_AT_CURSOR_UNDO_REPEAT_AND_VISIBLE_FAILURE_OK")
        if CommandLine.arguments.count == 3 {
            // Optional read-only reproduction from real projects. Pasted media
            // and document edits remain in the temporary fixture directory.
            let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let targetURL = URL(fileURLWithPath: CommandLine.arguments[2])
            let original = try ProjectDocumentCodec.decode(Data(contentsOf: sourceURL))
            let target = try ProjectDocumentCodec.decode(Data(contentsOf: targetURL))
            let sample = original.songs[0].tracks.filter { $0.kind == .standard }.flatMap(\.clips).first { $0.audioFile != nil }!
            let sourceController = try ShowController(executor: PasteExecutor(), persistence: MemoryProjectStore(), initialProject: original)
            precondition(sourceController.copyItems([sample.id]))
            clipboard.items = sourceController.copiedGridItems
            clipboard.directory = sourceURL.deletingLastPathComponent()
            clipboard.session = sourceController.projectSessionID; clipboard.didCopyItems()
            let targetController = try ShowController(executor: PasteExecutor(), persistence: MemoryProjectStore(), initialProject: target)
            let projectDirectory = root.appendingPathComponent("Real project reproduction")
            try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
            let targetDocuments = ProjectDocuments(show: targetController, file: projectDirectory.appendingPathComponent(targetURL.lastPathComponent))
            targetController.send(.editSeek, value: 125.5)
            var copiedIDs: Set<UUID> = []
            targetDocuments.pasteGridItems(selectedTracks: []) { copiedIDs = $0 }
            while targetDocuments.busy { try await Task.sleep(nanoseconds: 1_000_000) }
            precondition(copiedIDs.count == 1, targetController.modalNotice ?? "Real project paste did not finish")
            let item = targetController.current!.tracks.flatMap(\.clips).first { copiedIDs.contains($0.id) }!
            precondition(item.startTime == 125.5 && FileManager.default.fileExists(atPath: projectDirectory.appendingPathComponent(item.audioFile!.path).path))
            precondition(sourceController.snapshot.project == original)
            targetController.undo(); precondition(targetController.snapshot.project == target)
            print("REAL_SOURCE_PROJECT_TO_EMPTY_DESTINATION_TAB_PASTE_AND_UNDO_OK")
        }
    }
}
