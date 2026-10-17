import Foundation

@main struct TimelineMovementLockTests {
    @MainActor static func fixture() -> Project {
        var project = Project.empty(name: "Timeline movement lock")
        let region = Part(id: UUID(), name: "Region", startTime: 10, endTime: 40)
        project.songs[0].parts = [region]
        project.songs[0].markers = [
            TimelineMarker(id: UUID(), name: "Cue", position: 15, color: 0x3399ff),
            TimelineMarker(id: UUID(), name: "TEMPO", position: 20, color: 0x999999, tempoBPM: 120, tempoBeats: 4, tempoUnit: 4)
        ]
        for kind in TrackKind.allCases {
            var track = Track(id: UUID(), name: kind == .standard ? "Audio" : kind.title,
                role: TrackRole(rawValue: kind == .standard ? "other" : kind.rawValue))
            var item = AudioClip(id: UUID(), name: kind.title, startTime: 12, duration: 4)
            if kind == .standard { item.audioFile = AudioFile(path: "Stems/audio.wav") }
            else if kind == .video { item.audioFile = AudioFile(path: "Videos/video.mov") }
            else if kind.isText { item.text = "Text" }
            else if kind == .timecode { track.importedTimecodeItems = true; track.timecode = TimecodeSettings(); item.timecode = TimecodeSettings() }
            track.clips = [item]
            project.songs[0].tracks.append(track)
        }
        var midi = Track(id: UUID(), name: "MIDI", role: .keys)
        var item = AudioClip(id: UUID(), name: "MIDI", startTime: 12, duration: 4)
        item.midi = MIDIItem(notes: [MIDINote(start: 0, length: 1, pitch: 60, velocity: 90, channel: 1)])
        midi.clips = [item]; project.songs[0].tracks.append(midi)
        return project
    }

    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(url: directory.appendingPathComponent("Locked.jl"))
        let original = fixture()
        try original.validate()
        precondition(original.timelineMovementLocked == nil)
        let legacy = try JSONEncoder().encode(original)
        precondition(!String(data: legacy, encoding: .utf8)!.contains("timelineMovementLocked"))
        let show = try ShowController(executor: LocalCommandExecutor(), persistence: store, initialProject: original)
        precondition(!show.timelineMovementLocked)
        var audioRevisions: [UInt64] = []
        show.audioUpdate = { _, revision in audioRevisions.append(revision) }
        show.preparePlayback()
        let audioRevision = audioRevisions.last!
        show.setTimelineMovementLocked(true)
        precondition(show.timelineMovementLocked && show.canUndo)
        precondition(audioRevisions.last == audioRevision, "locking changes no audio graph revision")
        show.undo(); precondition(!show.timelineMovementLocked)
        show.redo(); precondition(show.timelineMovementLocked)
        let locked = show.snapshot.project, revision = show.projectRevision
        let song = show.current!, region = song.parts[0]
        for track in song.tracks {
            for item in track.clips {
                show.moveClip(item.id, start: 80, track: track.id)
                show.resizeItem(item.id, start: 11, end: 18)
                precondition(show.snapshot.project == locked, "all item kinds keep position and edges while locked")
            }
        }
        let audioTrack = song.tracks.first { $0.name == "Audio" }!, audioItem = audioTrack.clips[0]
        show.moveClipToNewStandardTrack(audioItem.id, start: 80,
            newTrack: Track(id: UUID(), name: "New", role: .other))
        show.moveRegion(region.id, start: 80)
        show.resizeRegion(region.id, start: 9, end: 45)
        for marker in song.markers ?? [] {
            var moved = marker; moved.position += 20
            show.setMarker(moved)
        }
        precondition(show.snapshot.project == locked && show.projectRevision == revision,
            "blocked drags and trims neither mutate the arrangement nor enter history")
        precondition(show.copyItems([audioItem.id], moving: true))
        show.send(.editSeek, value: 80)
        precondition(show.pasteItems().isEmpty && show.snapshot.project == locked,
            "Cut/Paste cannot bypass movement locking")
        show.send(.play)
        precondition(show.snapshot.transport.playing, "transport remains usable")
        show.send(.editSeek, value: 23)
        precondition(show.snapshot.transport.editPosition == 23, "editing cursor remains usable")
        show.send(.stopAll)
        print("TIMELINE_LOCK_ALL_ITEM_KINDS_REGION_MARKER_TRIMS_CUT_PASTE_NO_HISTORY_OK")

        show.editRegion(region.id, name: "Renamed", color: 0xffaa11, uppercaseName: false)
        let renamed = show.current!.parts.first { $0.id == region.id }!
        precondition(renamed.name == "Renamed" && renamed.color == 0xffaa11 && renamed.startTime == region.startTime && renamed.endTime == region.endTime)
        var cue = show.current!.markers!.first { !$0.isTempo }!
        let cuePosition = cue.position
        cue.name = "Renamed cue"; cue.color = 0xabcdef; cue.position += 20
        show.setMarker(cue)
        let renamedCue = show.current!.markers!.first { $0.id == cue.id }!
        precondition(renamedCue.name == cue.name && renamedCue.color == cue.color && renamedCue.position == cuePosition)
        var tempo = show.current!.markers!.first { $0.isTempo && $0.position > 0 }!
        let tempoPosition = tempo.position
        tempo.tempoBPM = 135; tempo.tempoBeats = 3; tempo.tempoUnit = 8; tempo.position += 20
        show.setMarker(tempo)
        let editedTempo = show.current!.markers!.first { $0.id == tempo.id }!
        precondition(editedTempo.tempoBPM == 135 && editedTempo.tempoBeats == 3 && editedTempo.tempoUnit == 8 && editedTempo.position == tempoPosition,
            "tempo editing remains available without moving the marker")
        show.setItemFade(audioItem.id, fadeIn: true, seconds: 0.5)
        precondition(show.current!.tracks.first { $0.id == audioTrack.id }!.clips[0].fadeIn == 0.5)
        let copied = show.duplicateItems([audioItem.id])
        precondition(copied.count == 1, "creating a duplicated item remains available")
        let copiedTracks = show.duplicateTracks([audioTrack.id])
        precondition(copiedTracks.count == 1, "duplicating a complete track remains available")
        show.setMarker(TimelineMarker(id: UUID(), name: "New marker", position: 90, color: 0x123456))
        precondition(show.current!.markers!.contains { $0.name == "New marker" }, "creating a marker remains available")
        print("TIMELINE_LOCK_ALLOWS_TEMPO_NAMES_COLORS_FADES_CREATION_DUPLICATION_OK")

        try await show.flushProject()
        let document = try await store.load()!
        precondition(document.timelineMovementLocked == true)
        let reopened = try ShowController(executor: LocalCommandExecutor(), persistence: store, initialProject: document)
        precondition(reopened.timelineMovementLocked && !reopened.needsSave,
            "movement lock survives real C++ bridge, encrypted save and reopening")
        reopened.setTimelineMovementLocked(false)
        precondition(!reopened.timelineMovementLocked)
        let start = reopened.current!.tracks.first { $0.id == audioTrack.id }!.clips[0].startTime
        reopened.moveClip(audioItem.id, start: 100, track: audioTrack.id)
        precondition(reopened.current!.tracks.first { $0.id == audioTrack.id }!.clips.first { $0.id == audioItem.id }!.startTime != start,
            "unlocking restores movement")
        try await reopened.flushProject()
        let unlocked = try await store.load()!
        precondition(unlocked.timelineMovementLocked == false)
        print("TIMELINE_LOCK_REAL_CORE_ENCRYPTED_SAVE_REOPEN_UNLOCK_OK")
    }
}
