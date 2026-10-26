import XCTest
@testable import JarasApplication

final class ProjectEditingTests: XCTestCase {
    func testSplitKeepsLoopPhaseAndPrintedSourceRates() throws {
        for printed in [false, true] {
            var project = Project.empty(name: "Loop split")
            var song = project.songs[0]; song.duration = 10
            song.markers = [TimelineMarker(id: UUID(), name: "Tempo", position: 0, color: 0,
                tempoBPM: 240, tempoTimebase: .relative, tempoReferenceBPM: 120)]
            var clip = AudioClip(id: UUID(), name: "Loop", startTime: 0, duration: 10, sourceOffset: 3,
                waveform: [0.1, 0.2, 0.3], audioFile: AudioFile(path: "loop.wav"),
                playbackRate: 1.5, loopStart: 2, loopLength: 5)
            clip.renderedTempo = printed ? true : nil
            var track = Track(id: UUID(), name: "Track", role: .other); track.clips = [clip]
            song.tracks = [track]; project.songs[0] = song
            project.splitItems([clip.id], at: 4)
            let split = project.songs[0].tracks[0].clips
            let consumed = 4 * (printed ? 1.5 : 3)
            XCTAssertEqual(split[1].sourceOffset, clip.sourceOffset + consumed, accuracy: 0.000001)
            XCTAssertEqual(split[0].waveform, clip.waveform)
            XCTAssertEqual(split[1].waveform, clip.waveform)
            func wrapped(_ value: Double) -> Double { 2 + (value - 2).truncatingRemainder(dividingBy: 5) }
            let left = project.songs[0].tempoAudioSegments(split[0]).last!
            let right = project.songs[0].tempoAudioSegments(split[1]).first!
            XCTAssertEqual(wrapped(left.sourceOffset + left.duration * left.audioRate), wrapped(right.sourceOffset), accuracy: 0.000001)
            XCTAssertEqual(right.audioRate, printed ? 1.5 : 3)
            try project.validate()
        }
    }

    func testSplitUsesEffectiveTempoSourcePositionForAudioVideoAndMIDI() throws {
        for kind in 0..<3 {
            var project = Project.empty(name: "Tempo split")
            var song = project.songs[0]; song.duration = 10
            let region = Part(id: UUID(), name: "Song", startTime: 0, endTime: 10)
            song.parts = [region]
            song.markers = [
                TimelineMarker(id: UUID(), name: "Fast", position: 0, color: 0, regionOwnerID: region.id,
                    tempoBPM: 240, tempoTimebase: .relative, tempoReferenceBPM: 120),
                TimelineMarker(id: UUID(), name: "Normal", position: 4, color: 0, regionOwnerID: region.id,
                    tempoBPM: 120, tempoTimebase: .relative, tempoReferenceBPM: 120)]
            var clip = AudioClip(id: UUID(), name: "Source", startTime: 0, duration: 10, sourceOffset: 3,
                waveform: (1...14).map { Double($0) / 20 }, audioFile: AudioFile(path: kind == 1 ? "movie.mov" : "source.wav"),
                regionOwnerID: region.id)
            if kind == 2 { clip.audioFile = nil; clip.midi = MIDIItem(notes: [], sourceBPM: 120) }
            var track = Track(id: UUID(), name: "Track", role: .other); track.clips = [clip]
            song.tracks = [track]; project.songs[0] = song
            let original = project
            var history = ProjectEditHistory(project)
            project.splitItems([clip.id], at: 6)
            let split = project.songs[0].tracks[0].clips
            XCTAssertEqual(split.count, 2)
            XCTAssertEqual(split[1].sourceOffset, 13, accuracy: 0.000001, "Four seconds at 2x plus two seconds at 1x consume ten source seconds")
            XCTAssertEqual(split[0].waveform.count, 10, "Waveform trimming follows the consumed source, not timeline duration")
            XCTAssertEqual(split.flatMap(\.waveform), clip.waveform)
            let segments = split.flatMap { project.songs[0].tempoAudioSegments($0) }
            for (left, right) in zip(segments, segments.dropFirst()) {
                XCTAssertEqual(left.sourceOffset + left.duration * left.audioRate, right.sourceOffset, accuracy: 0.000001)
                XCTAssertEqual(left.startTime + left.duration, right.startTime, accuracy: 0.000001)
            }
            XCTAssertEqual(segments.last!.sourceOffset + segments.last!.duration * segments.last!.audioRate, 17, accuracy: 0.000001)
            history.record(project)
            XCTAssertEqual(history.undo(), original)
            XCTAssertEqual(history.redo(), project)
            try project.validate()
        }
    }

    func testSplitPreservesOuterFadesWithoutFadingAtInternalCut() throws {
        var project = fixture()
        var clip = project.songs[0].tracks[0].clips[0]
        clip.fadeIn = 1; clip.fadeOut = 2
        clip.fadeInCurve = 0.25; clip.fadeInSCurve = 0.5
        clip.fadeOutCurve = -0.25; clip.fadeOutSCurve = 0.75
        project.songs[0].tracks[0].clips = [clip]
        project.splitItems([clip.id], at: 40)
        let halves = project.songs[0].tracks[0].clips
        XCTAssertEqual(halves[0].fadeIn, clip.fadeIn)
        XCTAssertEqual(halves[0].fadeInCurve, clip.fadeInCurve)
        XCTAssertEqual(halves[1].fadeOut, clip.fadeOut)
        XCTAssertEqual(halves[1].fadeOutCurve, clip.fadeOutCurve)
        XCTAssertNil(halves[0].fadeOut); XCTAssertNil(halves[1].fadeIn)
        XCTAssertNil(halves[0].fadeOutCurve); XCTAssertNil(halves[1].fadeInCurve)
        XCTAssertEqual(halves[0].fadeGain(at: 40 - 0.000001), 1)
        XCTAssertEqual(halves[1].fadeGain(at: 40 + 0.000001), 1)
        XCTAssertEqual(halves[0].fadeGain(at: 30), 0)
        XCTAssertEqual(halves[1].fadeGain(at: 50), 0)
        try project.validate()
    }

    func testSplitEverySelectedItemAtOneCursorPreservingUnselectedItems() throws {
        var project = fixture()
        let original = project.songs[0].tracks[0].clips[0]
        var second = original; second.id = UUID()
        var untouched = original; untouched.id = UUID()
        project.songs[0].tracks[0].clips = [original, untouched]
        var track = project.songs[0].tracks[0]; track.id = UUID(); track.clips = [second]
        project.songs[0].tracks.append(track)
        project.splitItems([original.id, second.id], at: 35)
        let selected = project.songs[0].tracks.flatMap(\.clips).filter { $0.id == original.id || $0.id == second.id }
        XCTAssertEqual(selected.count, 2)
        XCTAssertTrue(selected.allSatisfy { $0.startTime + $0.duration == 35 })
        XCTAssertEqual(project.songs[0].tracks.flatMap(\.clips).filter { $0.startTime == 35 }.count, 2)
        XCTAssertEqual(project.songs[0].tracks[0].clips.first { $0.id == untouched.id }, untouched)
    }

    func testRoundedImportedRegionOnsetUsesSameOwnershipInPreviewAndPersistence() throws {
        var project = Project.empty(name: "Rounded region")
        let region = Part(id: UUID(), name: "Song", startTime: 11958.400000432, endTime: 12174.900000432)
        let item = AudioClip(id: UUID(), name: "Click", startTime: 11958.4, duration: 216.5)
        var track = Track(id: UUID(), name: "Audio", role: .other); track.clips = [item]
        project.songs[0].parts = [region]; project.songs[0].tracks = [track]; project.songs[0].duration = 15000
        let song = project.songs[0]
        XCTAssertEqual(song.regionOwner(at: item.startTime), region.id)
        XCTAssertNil(song.regionOwner(at: region.startTime - 0.00001), "actual positions before the edge stay outside")
        XCTAssertNil(song.regionOwner(at: region.endTime), "the end is half-open")
        let preview = song.previewMovingRegion(region.id, to: 14000)
        XCTAssertEqual(preview.tracks[0].clips[0].startTime, item.startTime + 14000 - region.startTime, accuracy: 1e-9)
        project.songs[0].regionOwnershipInitialized = true
        project.songs[0].regionOwnershipVersion = 2
        let loosePreview = project.songs[0].previewMovingRegion(region.id, to: 14000)
        XCTAssertEqual(loosePreview.tracks[0].clips[0].startTime, item.startTime, "initialized nil remains deliberately unattached")
        project.songs[0].tracks[0].clips[0].regionOwnerID = region.id
        let restored = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project))
        XCTAssertEqual(restored.songs[0].regionOwnershipVersion, 2, "encrypted document retains the one-time migration version")
        let restoredPreview = restored.songs[0].previewMovingRegion(region.id, to: 14000)
        XCTAssertEqual(restoredPreview.tracks[0].clips[0].startTime, preview.tracks[0].clips[0].startTime, accuracy: 1e-9)
    }

    func testRecordingLanesOnlyExpandForOverlaps() {
        var track = Track(id: UUID(), name: "Input", role: .other)
        let original = AudioClip(id: UUID(), name: "Original", startTime: 10, duration: 5)
        track.clips = [original]
        var layout = TrackLanes(track: track)
        XCTAssertEqual(layout.recordingLane(start: 0, duration: 5, clips: track.clips), 0)
        XCTAssertEqual(layout.recordingLane(start: 15, duration: 5, clips: track.clips), 0)
        XCTAssertEqual(layout.recordingLane(start: 9, duration: 2, clips: track.clips), 1)
        let earlierTake = AudioClip(id: UUID(), name: "Take", startTime: 9, duration: 3, recordingLane: 1)
        let laterTake = AudioClip(id: UUID(), name: "Later", startTime: 20, duration: 3, recordingLane: 12)
        track.clips += [earlierTake, laterTake]
        layout = TrackLanes(track: track)
        XCTAssertEqual(layout.lanes[original.id], 0, "recording before an existing item never pushes that item down")
        XCTAssertEqual(layout.lanes[earlierTake.id], 1)
        XCTAssertEqual(layout.lanes[laterTake.id], 0, "old reservations cannot leave an empty lane above a take")
        XCTAssertEqual(layout.count, 2)
        XCTAssertEqual(layout.recordingLane(start: 10, duration: 1, clips: track.clips), 2)
        track.clips.reverse()
        XCTAssertEqual(TrackLanes(track: track), layout, "array order cannot swap takes")
    }

    func testScalarHistoryRetainsClipStorageAndSupportsUndoRedo() {
        var project = fixture()
        let waveform = (0..<100000).map { Double($0) / 100000 }
        project.songs[0].tracks[0].clips = (0..<2000).map { index in
            AudioClip(id: UUID(), name: "Item", startTime: Double(index), duration: 1, waveform: waveform)
        }
        let original = project
        var history = ProjectEditHistory(project)
        let started = Date()
        for index in 1...20 {
            project.songs[0].tracks[0].volume = Double(index) / 20
            history.record(project, preservingMediaStorage: true)
        }
        print("SCALAR_HISTORY_2000_ITEMS_20_EDITS_MS=\(Date().timeIntervalSince(started) * 1000)")
        let final = project
        let undone = history.undo()!
        XCTAssertEqual(undone.songs[0].tracks[0].volume, 0.95)
        let restored = history.redo()!
        XCTAssertEqual(restored, final)
        original.songs[0].tracks[0].clips.withUnsafeBufferPointer { old in
            restored.songs[0].tracks[0].clips.withUnsafeBufferPointer { next in
                XCTAssertEqual(old.baseAddress, next.baseAddress, "scalar history shares unchanged item storage")
            }
        }
        _ = history.undo()
        project.songs[0].tracks[0].pan = 0.5
        history.record(project, preservingMediaStorage: true)
        XCTAssertFalse(history.canRedo)
    }

    func testCompleteExportUsesAudioEndRatherThanRegionsOrAuxiliaryItems() {
        var song = fixture().songs[0]
        song.parts = [Part(id: UUID(), name: "Long region", startTime: 0, endTime: 280)]
        var video = Track(id: UUID(), name: "Video", role: TrackRole(rawValue: "video"))
        video.clips = [AudioClip(id: UUID(), name: "Movie", startTime: 200, duration: 100, waveform: [], audioFile: AudioFile(path: "Videos/movie.mov"))]
        song.tracks.append(video)
        XCTAssertEqual(song.completeAudioExportEnd, 50)
        song.tracks[0].clips[0].duration = 40
        XCTAssertEqual(song.completeAudioExportEnd, 70)
        song.tracks[0].clips = []
        XCTAssertEqual(song.completeAudioExportEnd, 0)
    }
    func testRegionUppercasePreservesOriginalAndParentheses() throws {
        var region = Part(id: UUID(), name: "Canção (Ao vivo) final (Tom: Ré)", startTime: 0, endTime: 10)
        XCTAssertEqual(region.displayName, "CANÇÃO (Ao vivo) FINAL (Tom: Ré)")
        region.uppercaseName = false
        XCTAssertEqual(region.displayName, region.name)
        let restored = try JSONDecoder().decode(Part.self, from: JSONEncoder().encode(region))
        XCTAssertEqual(restored, region)
        XCTAssertEqual(restored.displayName, "Canção (Ao vivo) final (Tom: Ré)")
        region.uppercaseName = true
        region.name = "Música (ao vivo (Solo)) fim"
        XCTAssertEqual(region.displayName, "MÚSICA (ao vivo (Solo)) FIM")
    }

    private func fixture() -> Project {
        var project = Project.empty(name: "Editing")
        project.songs[0].duration = 300
        var parent = Track(id: UUID(), name: "Keys", role: .keys)
        var child = Track(id: UUID(), name: "Piano", role: .keys)
        child.parentTrackID = parent.id; child.patch = .masterGroup; child.secondaryPatch = .stereo
        parent.clips = [AudioClip(id: UUID(), name: "Take", startTime: 30, duration: 20, waveform: [0.1,0.2,0.3,0.4], audioFile: AudioFile(path: "Stems/take.wav"), playbackRate: 2)]
        project.songs[0].tracks = [parent, child]
        return project
    }
    func testDeletePriorityAndUndoRedoPreserveMediaAndRouting() throws {
        var project = fixture(); let original = project
        let track = project.songs[0].tracks[0], clip = track.clips[0]
        XCTAssertTrue(project.tracksContainItems([track.id]))
        XCTAssertFalse(project.tracksContainItems([project.songs[0].tracks[1].id]))
        XCTAssertEqual(GridDeleteTarget(items: [clip.id], tracks: [track.id]), .items([clip.id]))
        XCTAssertEqual(GridDeleteTarget(items: [], tracks: [track.id]), .tracks([track.id]))
        var history = ProjectEditHistory(project)
        project.deleteItems([clip.id]); history.record(project)
        XCTAssertFalse(project.tracksContainItems([track.id]))
        XCTAssertEqual(project.songs[0].tracks.count, 2)
        XCTAssertEqual(history.undo(), original)
        XCTAssertEqual(history.redo(), project)
        project.deleteTracks([track.id]); history.record(project)
        XCTAssertNil(project.songs[0].tracks[0].parentTrackID)
        XCTAssertEqual(project.songs[0].tracks[0].primaryOutput, .master)
        XCTAssertEqual(project.songs[0].tracks[0].secondaryOutput, .stereo)
        try project.validate()
        _ = history.undo(); var edit = original; edit.ungroupTrack(track.id); history.record(edit)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(edit.songs[0].tracks.count, 2)
    }
    func testPlaylistRemovalDoesNotDeleteRegionAndLastEntryIsAllowed() throws {
        var project = fixture()
        let region = Part(id: UUID(), name: "Song", startTime: 30, endTime: 50)
        project.songs[0].parts = [region]
        let playlist = RegionPlaylist(id: UUID(), name: "Set", songId: project.songs[0].id, regionIds: [region.id])
        var state = RegionSetlist(); state.playlists = [playlist]; state.selectedId = playlist.id
        state.blocks = [SetlistBlock(id: UUID(), songId: project.songs[0].id, playlistId: playlist.id, name: "Block", color: 0xff0000, beforeRegionId: region.id)]
        project.regionSetlist = state
        project.removeRegion(region.id, from: playlist.id)
        XCTAssertEqual(project.songs[0].parts.count, 1)
        XCTAssertTrue(project.regionSetlist!.playlists[0].regionIds.isEmpty)
        XCTAssertNil(project.regionSetlist!.blocks![0].beforeRegionId)
        try project.validate()
        project.deleteRegion(region.id)
        XCTAssertTrue(project.songs[0].parts.isEmpty)
        XCTAssertEqual(project.songs[0].tracks[0].clips.count, 1)
        try project.validate()
    }
    func testAllRegionsDeleteRemovesOwnedContentOfEveryKindAndPreservesOverlaps() throws {
        var project = Project.empty(name: "Delete region contents")
        let songID = project.songs[0].id
        let first = Part(id: UUID(), name: "Delete", startTime: 10, endTime: 20)
        let other = Part(id: UUID(), name: "Keep", startTime: 15, endTime: 30)
        project.songs[0].parts = [first, other]
        project.songs[0].duration = 60
        project.songs[0].regionOwnershipInitialized = true
        for kind in [TrackKind.standard, .teleprompt, .teleprompt2, .chords, .click, .timecode] {
            var track = Track(id: UUID(), name: kind.title, role: TrackRole(rawValue: kind.rawValue))
            track.clips = [AudioClip(id: UUID(), name: "Owned", startTime: 12, duration: 2, regionOwnerID: first.id)]
            if kind == .timecode {
                track.clips = [AudioClip(id: Project.timecodeItemID(first.id), name: "Extended timecode", startTime: 8, duration: 15)]
            }
            project.songs[0].tracks.append(track)
        }
        let foreign = AudioClip(id: UUID(), name: "Overlapping song", startTime: 16, duration: 1, regionOwnerID: other.id)
        let loose = AudioClip(id: UUID(), name: "Loose item under region", startTime: 18, duration: 1)
        project.songs[0].tracks[0].clips += [foreign, loose]
        let normal = TimelineMarker(id: UUID(), name: "Normal", position: 10, color: 0, regionOwnerID: first.id)
        let tempo = TimelineMarker(id: UUID(), name: "Tempo", position: 12, color: 0, regionOwnerID: first.id, tempoBPM: 140)
        let section = TimelineMarker(id: UUID(), name: "Section", position: 14, color: 0, regionOwnerID: first.id, section: true)
        let loop = TimelineMarker(id: UUID(), name: "Loop", position: 15, color: 0, regionOwnerID: first.id, section: true, loopSection: true)
        let otherMarker = TimelineMarker(id: UUID(), name: "Other song", position: 17, color: 0, regionOwnerID: other.id)
        let looseMarker = TimelineMarker(id: UUID(), name: "Unattached", position: 19, color: 0)
        let boundary = TimelineMarker(id: UUID(), name: "Next", position: 20, color: 0, regionOwnerID: other.id, tempoBPM: 120)
        project.songs[0].markers = [normal, tempo, section, loop, otherMarker, looseMarker, boundary]
        let playlist = RegionPlaylist(id: UUID(), name: "Set", songId: songID, regionIds: [first.id, other.id])
        project.regionSetlist = RegionSetlist(playlists: [playlist])
        let before = project
        project.deleteSetlistEntries([first.id], song: songID, playlist: playlist.id)
        XCTAssertEqual(project.songs, before.songs, "playlist removal must leave all timeline content intact")
        project = before
        var history = ProjectEditHistory(project)
        project.deleteSetlistEntries([first.id], song: songID, playlist: nil)
        history.record(project)
        XCTAssertEqual(project.songs[0].parts, [other])
        XCTAssertEqual(project.songs[0].tracks[0].clips, [foreign, loose])
        XCTAssertTrue(project.songs[0].tracks.dropFirst().allSatisfy { $0.clips.isEmpty })
        XCTAssertEqual(project.songs[0].markers, [otherMarker, looseMarker, boundary])
        XCTAssertEqual(project.regionSetlist?.playlists[0].regionIds, [other.id])
        XCTAssertEqual(history.undo(), before)
        XCTAssertEqual(history.redo(), project)
    }
    func testAllRegionsImportedContentUsesHalfOpenRegionBoundaries() throws {
        var project = fixture()
        let first = Part(id: UUID(), name: "First", startTime: 30, endTime: 50)
        let next = Part(id: UUID(), name: "Next", startTime: 50, endTime: 70)
        project.songs[0].parts = [first, next]
        let tempo = TimelineMarker(id: UUID(), name: "Tempo", position: 30, color: 0, tempoBPM: 130)
        let cue = TimelineMarker(id: UUID(), name: "Cue", position: 40, color: 0, section: true)
        let boundary = TimelineMarker(id: UUID(), name: "Next tempo", position: 50, color: 0, tempoBPM: 140)
        project.songs[0].markers = [tempo, cue, boundary]
        project.deleteSetlistEntries([first.id], song: project.songs[0].id, playlist: nil)
        XCTAssertTrue(project.songs[0].tracks[0].clips.isEmpty)
        XCTAssertEqual(project.songs[0].markers, [boundary])
        XCTAssertEqual(project.songs[0].parts, [next])
        try project.validate()
    }
    func testAllRegionsClearsPreviouslyUnownedTempoWithoutCapturingItDuringRegionMoves() throws {
        var project = fixture()
        let first = Part(id: UUID(), name: "Moving", startTime: 0, endTime: 10)
        let next = Part(id: UUID(), name: "Next", startTime: 30, endTime: 40)
        project.songs[0].parts = [first, next]
        project.songs[0].regionOwnershipInitialized = true
        project.songs[0].tracks = []
        let before = TimelineMarker(id: UUID(), name: "Before", position: 19, color: 0, tempoBPM: 120)
        let start = TimelineMarker(id: UUID(), name: "Start", position: 20, color: 0, tempoBPM: 125)
        let inside = TimelineMarker(id: UUID(), name: "Legacy tempo", position: 25, color: 0, tempoBPM: 130)
        let foreign = TimelineMarker(id: UUID(), name: "Other song", position: 26, color: 0, regionOwnerID: next.id, tempoBPM: 135)
        let boundary = TimelineMarker(id: UUID(), name: "Next start", position: 30, color: 0, tempoBPM: 140)
        let after = TimelineMarker(id: UUID(), name: "After", position: 31, color: 0, tempoBPM: 145)
        project.songs[0].markers = [before, start, inside, foreign, boundary, after]
        project.songs[0] = project.songs[0].previewMovingRegion(first.id, to: 20)
        XCTAssertEqual(project.songs[0].markers, [before, start, inside, foreign, boundary, after], "a region moving across loose tempos does not capture or move them")
        var history = ProjectEditHistory(project)
        let original = project
        project.deleteSetlistEntries([first.id], song: project.songs[0].id, playlist: nil)
        history.record(project)
        XCTAssertEqual(project.songs[0].markers, [before, foreign, boundary, after])
        XCTAssertEqual(history.undo(), original)
        XCTAssertEqual(history.redo(), project)
        try project.validate()
    }
    func testSplitSourceOffsetsAndUnlimitedRecordingLanes() throws {
        var project = fixture(); let clip = project.songs[0].tracks[0].clips[0]
        project.splitItems([clip.id], at: 35)
        let clips = project.songs[0].tracks[0].clips
        XCTAssertEqual(clips.map(\.duration), [5,15])
        XCTAssertEqual(clips[1].sourceOffset, 10)
        XCTAssertEqual(clips[0].audioFile, clips[1].audioFile)
        XCTAssertEqual(clips[0].waveform + clips[1].waveform, clip.waveform)
        for lane in 1...20 { var take = clip; take.id = UUID(); take.recordingLane = lane; project.songs[0].tracks[0].clips.append(take) }
        XCTAssertEqual(TrackLanes(track: project.songs[0].tracks[0]).count, 21)
        try project.validate()
    }
    func testResizeKeepsOriginalSourceWithoutCreatingLoopAndKeepsSplitGain() throws {
        var project = fixture(); let original = project.songs[0].tracks[0].clips[0]
        project.resizeItem(original.id, start: 25, end: 90)
        let expanded = project.songs[0].tracks[0].clips[0]
        XCTAssertNil(expanded.loopStart)
        XCTAssertNil(expanded.loopLength)
        XCTAssertEqual(expanded.sourceOffset, 0)
        XCTAssertEqual(expanded.startTime,30)
        XCTAssertEqual(expanded.duration, 60)
        XCTAssertEqual(expanded.audioFile, original.audioFile)
        XCTAssertEqual(expanded.waveform, original.waveform)
        project.songs[0].tracks[0].clips[0].gain = 0.5
        project.splitItems([original.id], at: 40)
        XCTAssertEqual(project.songs[0].tracks[0].clips.map(\.gain), [0.5,0.5])
        XCTAssertEqual(project.songs[0].tracks[0].clips.flatMap(\.waveform), original.waveform)
        try project.validate()
    }
    func testManualCleanupKeepsRecoverableBackups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var project = fixture(); let document = root.appendingPathComponent("Show.jl")
        let source = root.appendingPathComponent("Stems/take.wav")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1,2,3,4]).write(to: source)
        try ProjectBackups.save(project, to: document)
        let known = project.mediaPaths
        project.deleteItems([project.songs[0].tracks[0].clips[0].id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try ProjectBackups.save(project, to: document)
        try ProjectMediaCleanup.removeDeletedFiles(project: project, document: document, knownPaths: known)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let backup = try ProjectDocumentCodec.decode(Data(contentsOf: ProjectBackups.files(for: document)[0]))
        let archived = try XCTUnwrap(backup.mediaPaths.first)
        XCTAssertTrue(archived.hasPrefix("backups/Media/"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(archived)), Data([1,2,3,4]))
    }
    func testBypassRetainsInstrumentAndEffectParameters() throws {
        var fx = NativeFXSettings(); fx.inserted = ["Instruments", "EQ"]; fx.instrumentID = "Piano"; fx.eqEnabled = true
        fx.setEnabled("Instruments", enabled: false); fx.setEnabled("EQ", enabled: false)
        XCTAssertEqual(fx.instrumentID, "Piano"); XCTAssertFalse(fx.isEnabled("Instruments")); XCTAssertFalse(fx.eqEnabled)
        let restored = try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(fx))
        XCTAssertEqual(restored, fx)
        fx.setEnabled("Instruments", enabled: true); XCTAssertTrue(fx.isEnabled("Instruments"))
    }
}

extension ProjectEditingTests {
    func testGroupItemMovePreservesOffsetsTracksAndClampsAsAGroup() throws {
        var song = Project.empty(name: "Group drag").songs[0]
        let first = AudioClip(id: UUID(), name: "First", startTime: 2, duration: 1)
        let second = AudioClip(id: UUID(), name: "Second", startTime: 5, duration: 1)
        var a = Track(id: UUID(), name: "A", role: .other); a.clips = [first]
        var b = Track(id: UUID(), name: "B", role: .other); b.clips = [second]
        let c = Track(id: UUID(), name: "C", role: .other)
        song.tracks = [a,b,c]
        let ids: Set<UUID> = [first.id,second.id]
        let moved = try XCTUnwrap(song.movingItems(ids, anchor: first.id, start: 8, track: b.id))
        XCTAssertTrue(moved.tracks[0].clips.isEmpty)
        XCTAssertEqual(moved.tracks[1].clips[0].startTime,8)
        XCTAssertEqual(moved.tracks[2].clips[0].startTime,11)
        let clamped = try XCTUnwrap(song.movingItems(ids, anchor: second.id, start: 0, track: nil))
        XCTAssertEqual(clamped.tracks[0].clips[0].startTime,0)
        XCTAssertEqual(clamped.tracks[1].clips[0].startTime,3)
        XCTAssertNil(song.movingItems(ids, anchor: first.id, start: 8, track: c.id))
        XCTAssertEqual(song.tracks[0].clips[0].startTime,2)
    }
}

extension ProjectEditingTests {
    func testSplitThenExpandRecoversOriginalAudioInsteadOfRepeatingTheCut() throws {
        var project = fixture(); let original = project.songs[0].tracks[0].clips[0]
        project.splitItems([original.id], at:35)
        let right = project.songs[0].tracks[0].clips[1]
        project.resizeItem(right.id,start:30,end:50)
        let restored = project.songs[0].tracks[0].clips.first { $0.id == right.id }!
        XCTAssertEqual(restored.sourceOffset,0)
        XCTAssertEqual(restored.duration,20)
        XCTAssertEqual(restored.audioFile,original.audioFile)
        XCTAssertNil(restored.loopLength)
        XCTAssertNil(restored.loopStart)
    }
}
