import Foundation

@main struct RecordingLaneLayoutTests {
    @MainActor static func main() {
        var track = Track(id: UUID(), name: "Input", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Existing", startTime: 10, duration: 5)]
        let take = AudioClip(id: UUID(), name: "Input - 001", startTime: 8, duration: 0.01)
        let layout = RecordingLaneLayout()
        layout.reserve(track: track, clip: take)
        precondition(layout.items[take.id]?.clip.recordingLane == 0)
        let initialRevision = layout.revision
        for step in 1...20 { layout.update(take.id, duration: Double(step) / 10) }
        precondition(layout.revision == initialRevision, "growing waveforms must not rebuild the grid")
        layout.update(take.id, duration: 2.1)
        precondition(layout.items[take.id]?.clip.recordingLane == 1, "take moves below an item it reaches")
        precondition(layout.count(for: track.id, existing: 1) == 2)
        precondition(layout.revision == initialRevision + 1)
        layout.update(take.id, duration: 4)
        precondition(layout.revision == initialRevision + 1)
        var committed = layout.items[take.id]!.clip
        committed.duration = 4
        track.clips.append(committed)
        precondition(TrackLanes(track: track).lanes[take.id] == 1, "Stop preserves the preview lane")
        layout.remove(take.id)
        let later = AudioClip(id: UUID(), name: "Input - 002", startTime: 20, duration: 1)
        layout.reserve(track: track, clip: later)
        precondition(layout.items[later.id]?.clip.recordingLane == 0, "no empty space above a non-overlapping take")
        layout.update(later.id, start: 11)
        precondition(layout.items[later.id]?.clip.recordingLane == 2, "actual capture start rechecks overlaps")
        layout.clear()
        precondition(layout.items.isEmpty)
        print("RECORDING_LIVE_LANES_OVERLAP_GROWTH_FINALIZATION_AND_NO_GRID_INVALIDATION_OK")
    }
}
