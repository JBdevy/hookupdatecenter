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
            if kind != .programChange { track.clips = [item] }
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
        let midiURL = directory.appendingPathComponent("MIDI de teste.mid")
        let midiBytes: [UInt8] = [77,84,104,100, 0,0,0,6, 0,0,0,1,0,96,
                                  77,84,114,107, 0,0,0,12, 0,0x90,60,100, 96,0x80,60,0, 0,0xff,0x2f,0]
        try Data(midiBytes).write(to: midiURL)
        precondition(GridMediaFileFilter.accepts(midiURL))
        let targetTrack = UUID()
        let drop = try StemProjectImporter.prepareDroppedAudio([midiURL], start: 7, destinationTracks: [targetTrack],
            destination: directory.appendingPathComponent("Test.jl"))
        let midiClip = drop.tracks.first?.clips.first
        precondition(drop.tracks.first?.id == targetTrack && midiClip?.startTime == 7 && midiClip?.duration == 0.5 &&
                     midiClip?.midi?.notes.first?.pitch == 60 && midiClip?.audioFile == nil && drop.folders.isEmpty)
        print("LIBRARY_MIDI_FILE_DROPS_EDITABLE_NOTES_ON_TARGET_TRACK_OK")
        let original = fixture()
        try original.validate()
        precondition(original.timelineMovementLocked == nil)
        let legacy = try JSONEncoder().encode(original)
        precondition(!String(data: legacy, encoding: .utf8)!.contains("timelineMovementLocked"))
        let executor = LocalCommandExecutor()
        let show = try ShowController(executor: executor, persistence: store, initialProject: original)
        let muteIDs = Set(show.current!.tracks.filter { $0.kind == .standard }.compactMap { $0.clips.first?.id })
        precondition(muteIDs.count == 2)
        var mutedEvents = Set<UUID>(), audioUpdates = 0
        show.audioClipMute = { id, muted in if muted { mutedEvents.insert(id) } }
        show.audioUpdate = { _, _ in audioUpdates += 1 }
        let beforeMute = show.projectRevision
        show.setItemsMix(muteIDs, muted: true)
        let mutedCore = try executor.snapshot().project
        precondition(mutedEvents == muteIDs && show.projectRevision == beforeMute + 1 && audioUpdates == 0)
        precondition(mutedCore.songs[0].tracks.flatMap(\.clips).filter { $0.muted == true }.count == 2)
        mutedEvents.removeAll()
        show.setItemsMix(muteIDs, muted: true)
        precondition(mutedEvents.isEmpty && show.projectRevision == beforeMute + 1)
        do {
            try executor.setItemsMuted(muteIDs.union([UUID()]), muted: false)
            preconditionFailure("Invalid batch was partially accepted")
        } catch {
            let stillMuted = try executor.snapshot().project
            precondition(stillMuted == mutedCore)
        }
        show.undo()
        precondition(show.current!.tracks.flatMap(\.clips).allSatisfy { $0.muted != true })
        show.redo()
        precondition(show.current!.tracks.flatMap(\.clips).filter { $0.muted == true }.count == 2)
        show.undo()
        print("BATCH_ITEM_MUTE_UPDATES_VOICES_ATOMICALLY_AND_SUPPORTS_UNDO_OK")
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
        precondition(!show.copyItems([audioItem.id], moving: true))
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

        let scoped = try ShowController(executor: LocalCommandExecutor(), persistence: store, initialProject: original)
        scoped.setTimelineLockOptions(2)
        precondition(!scoped.timelineMovementLocked && scoped.timelineActiveLockOptions == 0 && scoped.timelineLockOptions == 2,
            "the popover configures the lock without enabling it")
        scoped.setTimelineMovementLocked(true)
        scoped.moveClip(audioItem.id, start: 90, track: audioTrack.id)
        precondition(scoped.current!.tracks.first { $0.id == audioTrack.id }!.clips[0].startTime == audioItem.startTime)
        scoped.moveRegion(region.id, start: region.startTime + 10)
        precondition(scoped.current!.tracks.first { $0.id == audioTrack.id }!.clips[0].startTime == audioItem.startTime + 10,
            "item lock prevents only individual moves; unlocked region carries its contents")
        scoped.setTimelineLockOptions(1)
        let regionStart = scoped.current!.parts.first { $0.id == region.id }!.startTime
        scoped.moveRegion(region.id, start: 90)
        precondition(scoped.current!.parts.first { $0.id == region.id }!.startTime == regionStart)
        scoped.moveClip(audioItem.id, start: 60, track: audioTrack.id)
        precondition(scoped.current!.tracks.first { $0.id == audioTrack.id }!.clips[0].startTime == 60)
        var heardGain: [UUID: Double] = [:], heardPan: [UUID: Double] = [:]
        scoped.audioItemGain = { heardGain[$0] = $1 }
        scoped.audioItemPan = { heardPan[$0] = $1 }
        scoped.previewItemGain(audioItem.id, gain: 0.1)
        scoped.previewItemPan(audioItem.id, pan: -0.75)
        scoped.setTimelineLockOptions(4)
        let legacyMixMask = TimelineLocks.itemVolume | TimelineLocks.itemPan
        precondition(scoped.timelineLockOptions == legacyMixMask && !scoped.timelineItemMuteLocked)
        let mixBefore = scoped.current!.tracks.first { $0.id == audioTrack.id }!.clips[0]
        precondition(heardGain[audioItem.id] == (mixBefore.gain ?? 1) && heardPan[audioItem.id] == (mixBefore.pan ?? 0),
            "locking mix during a live preview restores committed audio values")
        scoped.setItemGain(audioItem.id, gain: 0.25); scoped.setItemPan(audioItem.id, pan: -0.5)
        scoped.setItemsMix([audioItem.id], gain: 0.5, pan: 0.5)
        scoped.send(.clipGain, target: audioItem.id, value: 0.2)
        let mixAfter = scoped.current!.tracks.first { $0.id == audioTrack.id }!.clips[0]
        precondition(mixAfter.gain == mixBefore.gain && mixAfter.pan == mixBefore.pan)
        scoped.moveClip(audioItem.id, start: 65, track: audioTrack.id)
        precondition(scoped.current!.tracks.first { $0.id == audioTrack.id }!.clips[0].startTime == 65)
        try await scoped.flushProject()
        let partial = try await store.load()!
        precondition(partial.effectiveTimelineLocks == legacyMixMask && partial.timelineMovementLocked == true)
        scoped.setTimelineMovementLocked(false); scoped.setItemGain(audioItem.id, gain: 0.25)
        precondition(scoped.current!.tracks.first { $0.id == audioTrack.id }!.clips[0].gain == 0.25)
        precondition(scoped.timelineLockOptions == legacyMixMask && scoped.timelineActiveLockOptions == 0)
        try await scoped.flushProject()
        let configured = try await store.load()!
        precondition(configured.configuredTimelineLocks == legacyMixMask && configured.effectiveTimelineLocks == 0)
        scoped.setTimelineMovementLocked(true)
        precondition(scoped.timelineActiveLockOptions == legacyMixMask && !scoped.timelineItemsLocked && !scoped.timelineRegionsLocked,
            "re-enabling restores the remembered categories, not all categories")
        let item = { scoped.current!.tracks.first { $0.id == audioTrack.id }!.clips[0] }
        scoped.setTimelineLockOptions(TimelineLocks.itemVolume | TimelineLocks.itemMute)
        scoped.setItemGain(audioItem.id, gain: 0.5)
        scoped.setItemPan(audioItem.id, pan: -0.5)
        scoped.send(.clipMute, target: audioItem.id)
        scoped.setItemsMix([audioItem.id], muted: true)
        precondition(item().gain == 0.25 && item().pan == -0.5 && item().muted != true)
        scoped.setTimelineLockOptions(TimelineLocks.itemPan)
        scoped.setItemGain(audioItem.id, gain: 0.5)
        scoped.setItemPan(audioItem.id, pan: 0.5)
        scoped.send(.clipMute, target: audioItem.id)
        precondition(item().gain == 0.5 && item().pan == -0.5 && item().muted == true)
        try await scoped.flushProject()
        let panOnly = try await store.load()!
        precondition(panOnly.effectiveTimelineLocks == TimelineLocks.itemPan)
        print("TIMELINE_LOCK_INDEPENDENT_SCOPES_REGION_CONTENTS_MIX_AND_PARTIAL_SAVE_OK")
    }
}
