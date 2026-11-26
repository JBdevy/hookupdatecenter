import Foundation
import Combine

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

        let older = PreparationGate(), newer = PreparationGate()
        show.pendingSeekPreparation = { _, _, position in position == 3 ? older.task : newer.task }
        show.send(.editSeek, value: 0)
        show.send(.play)
        show.send(.seek, value: 3); show.send(.seek, value: 7)
        older.release(); await settle()
        precondition(show.isPlaying && show.preparingAudio && show.snapshot.transport.position < 3)
        newer.release(); await settle()
        precondition(!show.preparingAudio && abs(show.snapshot.transport.position - 7) < 0.5)
        let stopGate = PreparationGate()
        show.pendingSeekPreparation = { _, _, _ in stopGate.task }
        show.send(.seek, value: 9)
        show.send(.stopAll); stopGate.release(); await settle()
        precondition(!show.isPlaying && !show.preparingAudio && show.snapshot.transport.position != 9)

        show.send(.play)
        show.send(.editSeek, value: 11)
        precondition(show.snapshot.transport.editPosition == 11 && !show.preparingAudio)
        show.seekForRecording(2)
        precondition(!show.preparingAudio && abs(show.snapshot.transport.position - 2) < 0.5)
        show.send(.queueBeatSeek, value: 5)
        precondition(show.snapshot.transport.beatSeek?.destination == 5 && !show.preparingAudio)
        show.send(.stopAll)
        print("LIVE_SEEK_LATEST_WINS_STOP_EDIT_RECORDING_AND_BEAT_BOUNDARY_OK")

        let nativeGrid = ShowTimelinePresentationObserver(show: show, nativeTransportOverlay: true)
        var layoutChanges = 0
        let layoutObserver = nativeGrid.objectWillChange.sink { layoutChanges += 1 }
        show.send(.play)
        await settle()
        show.send(.stopAll)
        await settle()
        precondition(layoutChanges == 0, "Playback-only changes must not invalidate the AppKit grid's hosted rows")
        if let track = show.current?.tracks.first?.id {
            show.setMixerTrackSelection([track], anchor: track)
            precondition(layoutChanges == 1, "Native track selection must still refresh the mixer immediately")
        }
        withExtendedLifetime(layoutObserver) {}
        print("NATIVE_GRID_RETAINS_LAYOUT_ON_PLAY_STOP_AND_REFRESHES_SELECTION_OK")
    }
}
