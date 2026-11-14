import Foundation

@MainActor private final class PreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    lazy var task = Task { @MainActor in
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@main struct PlaybackPreparationTests {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-play-preparation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let show = try ShowController(executor: LocalCommandExecutor(),
            persistence: ProjectStore(url: folder.appendingPathComponent("Test.jl")), initialProject: .demo())
        var gate: PreparationGate?
        var starts = 0
        show.audioUpdate = { state, _ in if state.transport.playing { starts += 1 } }
        show.pendingAudioPreparation = { _, _ in gate?.task }
        func settle() async { for _ in 0..<40 { await Task.yield() } }

        show.send(.play)
        precondition(show.isPlaying && !show.preparingAudio, "An already prepared project starts synchronously")
        show.send(.stopAll)

        gate = PreparationGate(); let ready = gate!
        let before = starts
        show.send(.play)
        precondition(show.preparingAudio && show.presentationState.preparingAudio && !show.isPlaying)
        let position = show.snapshot.transport.position
        await settle()
        precondition(starts == before && show.snapshot.transport.position == position,
                     "The transport and audio cannot run ahead of pending media preparation")
        show.send(.play)
        gate = nil; ready.release(); await settle()
        precondition(show.isPlaying && !show.preparingAudio && starts == before + 1,
                     "Repeated Play while waiting must start only once")
        show.send(.stopAll)

        gate = PreparationGate(); let cancelled = gate!
        show.send(.play); show.send(.stopAll)
        precondition(!show.preparingAudio && !show.isPlaying)
        gate = nil; cancelled.release(); await settle()
        precondition(!show.isPlaying, "Stop must cancel the pending start even if I/O finishes later")

        gate = PreparationGate(); let oldCursor = gate!
        show.send(.play); show.send(.editSeek, value: 12.5)
        gate = nil; oldCursor.release(); await settle()
        precondition(!show.isPlaying && !show.preparingAudio && show.snapshot.transport.editPosition == 12.5,
                     "Seeking while waiting must not play the old cursor")

        gate = PreparationGate(); let oldRevision = gate!
        show.send(.play)
        gate = PreparationGate(); let revised = gate!
        oldRevision.release(); await settle()
        precondition(show.preparingAudio && !show.isPlaying, "A newer preparation must be awaited before starting")
        gate = nil; revised.release(); await settle()
        precondition(show.isPlaying && !show.preparingAudio)
        show.send(.stopAll)
        print("PLAYBACK_PREPARATION_READY_CANCEL_CURSOR_REVISION_OK")
    }
}
