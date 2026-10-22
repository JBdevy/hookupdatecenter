// Tests the production iPad processing coordinator with deterministic render and
// project adapters. Audio rendering itself is covered by ItemReRender tests.
import Foundation
import Combine

struct AudioFile { var path: String }
struct AudioClip { var id = UUID(); var name: String; var audioFile: AudioFile? }
struct Track { var id = UUID(); var clips: [AudioClip] }
struct Song { var id = UUID(); var tracks: [Track] }
struct Project { var id = UUID() }
struct Snapshot { var project = Project() }
struct GluedItemReplacement { var rendered: AudioClip }
struct AudioExportProgress { var fileName: String; var fraction: Double }
struct MediaProcessingFormat { static func load(_ name: String) -> Self { Self() } }
struct OfflineMIDIInstrument { }
final class AudioExportCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
enum JarasLocalization { static func string(_ value: String) -> String { value } }
@MainActor final class ShowController {
    var current: Song?; var snapshot = Snapshot(); var message = "Changed project"
    var accepts = true; var installed: [UUID] = []; var glued = false
    func canControl() -> Bool { true }
    func replaceRenderedItem(_ result: AudioClip, original: AudioClip, track: UUID, project: UUID) -> Bool {
        guard accepts else { return false }; installed.append(original.id); return true
    }
    func replaceGluedItems(_ replacements: [GluedItemReplacement], project: UUID, song: UUID) -> Bool {
        guard accepts else { return false }; glued = true; return true
    }
}
@MainActor final class ProjectDocuments { var busy = false; var currentURL: URL? }
enum ItemReRender {
    enum Behavior { case success, cancelAfterWrite, fail }
    static var behavior: Behavior = .success
    static var midiChannelCounts: [Int] = []
    static func midiInstruments(for track: Track, projectDirectory: URL) -> [String: OfflineMIDIInstrument] { [:] }
    static func render(project: Project, song: Song, track: Track, clip: AudioClip, directory: URL,
                       settings: MediaProcessingFormat, cancellation: AudioExportCancellation,
                       progress: (AudioExportProgress) -> Void) throws -> AudioClip {
        if case .fail = behavior { throw NSError(domain: "Render failure", code: 1) }
        let path = "Stems/" + clip.id.uuidString + ".wav"
        try Data("new audio".utf8).write(to: directory.appendingPathComponent(path))
        progress(.init(fileName: clip.name, fraction: 1))
        if case .cancelAfterWrite = behavior { cancellation.cancel() }
        return AudioClip(id: clip.id, name: clip.name, audioFile: AudioFile(path: path))
    }
    static func renderMIDI(project: Project, song: Song, track: Track, clip: AudioClip, directory: URL,
                           channels: Int, instruments: [String: OfflineMIDIInstrument], cancellation: AudioExportCancellation,
                           progress: (AudioExportProgress) -> Void) throws -> AudioClip {
        midiChannelCounts.append(channels)
        return try render(project: project, song: song, track: track, clip: clip, directory: directory,
                          settings: .init(), cancellation: cancellation, progress: progress)
    }
    static func glueSelection(project: Project, song: Song, ids: Set<UUID>, directory: URL,
                              cancellation: AudioExportCancellation, instruments: [UUID: [String: OfflineMIDIInstrument]],
                              progress: (Int, Int, AudioExportProgress) -> Void) throws -> [GluedItemReplacement] {
        let track = song.tracks[0], clip = track.clips[0]
        let result = try render(project: project, song: song, track: track, clip: clip, directory: directory,
                                settings: .init(), cancellation: cancellation, progress: { progress(0, 1, $0) })
        return [.init(rendered: result)]
    }
    static func discardGluedAudio(_ replacements: [GluedItemReplacement], directory: URL) {
        for item in replacements { if let path = item.rendered.audioFile?.path { try? FileManager.default.removeItem(at: directory.appendingPathComponent(path)) } }
    }
}
// PRODUCTION_COORDINATOR

@main struct Tests {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-ipad-item-processing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Stems/original.wav")
        try Data("original audio".utf8).write(to: original)
        let first = AudioClip(name: "First", audioFile: .init(path: "Stems/original.wav"))
        let second = AudioClip(name: "Second", audioFile: .init(path: "Stems/original.wav"))
        let unselected = AudioClip(name: "Unselected", audioFile: .init(path: "Stems/original.wav"))
        let show = ShowController(); show.current = Song(tracks: [.init(clips: [first, second, unselected])])
        let documents = ProjectDocuments(); documents.currentURL = folder.appendingPathComponent("Project.jl")
        func complete(_ session: IpadItemProcessingSession) async throws {
            for _ in 0..<300 {
                if !session.running { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            fatalError("Processing failed to finish")
        }
        func cleanResults() {
            for clip in [first, second] { try? FileManager.default.removeItem(at: folder.appendingPathComponent("Stems/" + clip.id.uuidString + ".wav")) }
        }
        func noNewFiles() -> Bool {
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("Stems/" + first.id.uuidString + ".wav").path)
        }
        let success = IpadItemProcessingSession()
        success.start(show: show, documents: documents, ids: [first.id, second.id], operation: .render)
        assert(documents.busy && success.running)
        try await complete(success)
        assert(success.finished && !documents.busy && show.installed == [first.id, second.id])
        assert(!show.installed.contains(unselected.id)); cleanResults()
        show.installed = []; show.accepts = false
        let stale = IpadItemProcessingSession()
        stale.start(show: show, documents: documents, ids: [first.id], operation: .render)
        try await complete(stale)
        assert(!stale.finished && !documents.busy && show.installed.isEmpty && noNewFiles())
        show.accepts = true; ItemReRender.behavior = .cancelAfterWrite
        let cancelled = IpadItemProcessingSession()
        cancelled.start(show: show, documents: documents, ids: [first.id], operation: .render)
        try await complete(cancelled)
        assert(!cancelled.finished && !documents.busy && show.installed.isEmpty && noNewFiles())
        let cancelledGlue = IpadItemProcessingSession()
        cancelledGlue.start(show: show, documents: documents, ids: [first.id, second.id], operation: .glue)
        try await complete(cancelledGlue)
        assert(!show.glued && !cancelledGlue.finished && !documents.busy && noNewFiles())
        ItemReRender.behavior = .success
        let midi = IpadItemProcessingSession()
        midi.start(show: show, documents: documents, ids: [first.id], operation: .midi(channels: 1))
        try await complete(midi)
        assert(midi.finished && ItemReRender.midiChannelCounts == [1]); cleanResults()
        ItemReRender.behavior = .fail
        let failure = IpadItemProcessingSession()
        failure.start(show: show, documents: documents, ids: [first.id], operation: .render)
        try await complete(failure)
        assert(!failure.finished && !failure.error.isEmpty && !documents.busy && noNewFiles())
        let preserved = try Data(contentsOf: original)
        assert(preserved == Data("original audio".utf8))
        print("IPAD_ITEM_PROCESSING_SELECTION_CANCEL_STALE_MIDI_FAILURE_OK scenarios=6")
    }
}
