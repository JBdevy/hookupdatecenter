import XCTest
@testable import JarasApplication

final class ClickTrackTests: XCTestCase {
    func testDoubleClickIsPerItemPersistsAndKeepsBarAccents() throws {
        var project = fixture()
        project.insertClickItems(track: project.songs[0].tracks[0].id)
        project.songs[0].tracks[0].clips[0].clickDouble = true
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        let song = restored.songs[0], track = song.tracks[0]
        XCTAssertEqual(track.clips[0].clickDouble, true)
        XCTAssertNil(track.clips[1].clickDouble)
        XCTAssertEqual(track.clips.map(\.duration), [4,4])
        let sections = ClickTrackProgram.sections(song: song, track: track)
        XCTAssertEqual(sections.map(\.bpm), [240,120])
        XCTAssertEqual(sections.map(\.beats), [8,4], "Doubled subdivisions retain the original bar accents")
        let timing = song.tempoSections(until: song.duration)
        let normal = ClickTrackProgram.visibleBeats(sections: timing, start: 1, end: 5, visibleStart: 0, visibleEnd: 30, pixelsPerSecond: 100)
        let doubled = ClickTrackProgram.visibleBeats(sections: timing, start: 1, end: 5, visibleStart: 0, visibleEnd: 30, pixelsPerSecond: 100, doubled: true)
        XCTAssertEqual(doubled.count, normal.count * 2)
        XCTAssertEqual(doubled[1]-doubled[0], 0.25)
        var overlap = track; var copy = track.clips[0]; copy.clickDouble = false; overlap.clips.append(copy)
        XCTAssertEqual(ClickTrackProgram.sections(song: song, track: overlap), sections)
        project.songs[0].tracks[0].clips[0].clickDouble = false
        XCTAssertEqual(ClickTrackProgram.sections(song: project.songs[0], track: project.songs[0].tracks[0]).map(\.bpm), [120,120])
    }
    func testClickCanTrimExtendAndSplitButCannotMoveOutsideItsRegion() throws {
        var project = fixture()
        let trackID = project.songs[0].tracks[0].id, owner = project.songs[0].parts[0].id
        project.insertClickItems(track: trackID)
        let id = project.songs[0].tracks[0].clips[0].id
        project.songs[0].tracks[0].clips[0].clickDouble = true
        project.resizeItem(id, start: 2, end: 4)
        var clip = project.songs[0].tracks[0].clips[0]
        XCTAssertEqual(clip.startTime, 2); XCTAssertEqual(clip.duration, 2)
        XCTAssertNil(clip.loopLength); XCTAssertEqual(clip.sourceOffset, 0)
        project.resizeItem(id, start: 0, end: 30)
        clip = project.songs[0].tracks[0].clips[0]
        XCTAssertEqual(clip.startTime, 1); XCTAssertEqual(clip.duration, 4)
        XCTAssertEqual(clip.regionOwnerID, owner)
        XCTAssertNil(project.songs[0].movingItems([id], anchor: id, start: 2, track: trackID))
        XCTAssertNil(GridItemClipboard(project: project, song: project.songs[0].id, selected: [id], moving: true))
        XCTAssertNil(GridItemClipboard(project: project, song: project.songs[0].id, selected: [id]))
        XCTAssertThrowsError(try project.pasteItems([.init(track: trackID, clip: clip)], song: project.songs[0].id, moving: true))
        project.splitItems([id], at: 3)
        let fragments = project.songs[0].tracks[0].clips.filter { $0.regionOwnerID == owner }
        XCTAssertEqual(fragments.count, 2)
        XCTAssertEqual(fragments.map(\.startTime), [1,3]); XCTAssertEqual(fragments.map(\.duration), [2,2])
        XCTAssertTrue(fragments.allSatisfy { $0.clickDouble == true && $0.sourceOffset == 0 && $0.loopLength == nil })
        XCTAssertEqual(project.insertClickItems(track: trackID), 0)
        project.deleteItems([id])
        XCTAssertEqual(project.insertClickItems(track: trackID), 0, "A remaining cut fragment prevents Insert from recreating the full click")
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(restored, project)
        try restored.validate()
    }
    func testLegacyClickBoundsResolveBeforeSplitInsideUnifiedChild() {
        var project = fixture()
        project.insertClickItems(track: project.songs[0].tracks[0].id)
        let root = project.songs[0].parts[0]
        project.songs[0].parts.append(Part(id: UUID(), name: "Child", startTime: 2, endTime: 4, parentRegionID: root.id))
        project.songs[0].tracks[0].clips[0].regionOwnerID = nil
        let id = project.songs[0].tracks[0].clips[0].id
        project.splitItems([id], at: 3)
        let pieces = project.songs[0].tracks[0].clips.filter { $0.startTime < 5 }
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces.allSatisfy { $0.regionOwnerID == root.id })
        project.resizeItem(pieces[1].id, start: 3, end: 7)
        XCTAssertEqual(project.songs[0].tracks[0].clips[1].startTime + project.songs[0].tracks[0].clips[1].duration, 5)
    }
    private func fixture() -> Project {
        var project = Project.empty(name: "Click")
        project.songs[0].duration = 30
        project.songs[0].bpm = 120
        project.songs[0].parts = [Part(id: UUID(), name: "First", startTime: 1, endTime: 5),
                                  Part(id: UUID(), name: "Second", startTime: 8, endTime: 12)]
        project.songs[0].tracks = [Track(id: UUID(), name: "Click", role: TrackRole(rawValue: TrackKind.click.rawValue))]
        return project
    }
    func testInsertIsIdempotentAddsOnlyNewRegionsAndSurvivesSave() throws {
        var project = fixture(); let id = project.songs[0].tracks[0].id
        XCTAssertEqual(project.insertClickItems(track: id), 2)
        let original = project
        XCTAssertEqual(project.insertClickItems(track: id), 0)
        XCTAssertEqual(original, project)
        project.songs[0].parts.append(Part(id: UUID(), name: "Third", startTime: 18, endTime: 23))
        XCTAssertEqual(project.insertClickItems(track: id), 1)
        XCTAssertEqual(project.songs[0].tracks[0].clips.map(\.startTime), [1, 8, 18])
        XCTAssertEqual(project.songs[0].tracks[0].clips.map(\.duration), [4, 4, 5])
        XCTAssertTrue(project.songs[0].tracks[0].clips.allSatisfy { $0.audioFile == nil })
        try project.validate()
        var restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(restored, project)
        XCTAssertEqual(restored.insertClickItems(track: id), 0)
        restored.songs[0].tracks[0].clips.removeFirst()
        XCTAssertEqual(restored.insertClickItems(track: id), 1, "Insert can restore a deleted click")
    }
    func testUnifiedRegionHasOneClickAndMovesWithItsRegion() throws {
        var project = fixture(); let id = project.songs[0].tracks[0].id
        let root = project.songs[0].parts[0]
        project.songs[0].parts.append(Part(id: UUID(), name: "Child", startTime: 2, endTime: 4, parentRegionID: root.id))
        XCTAssertEqual(project.insertClickItems(track: id), 2)
        let clips = project.songs[0].tracks[0].clips
        project.songs[0] = project.songs[0].previewMovingRegion(root.id, to: 20)
        XCTAssertEqual(project.songs[0].tracks[0].clips[0].startTime, 20)
        XCTAssertEqual(project.songs[0].tracks[0].clips[0].duration, clips[0].duration)
        XCTAssertEqual(project.insertClickItems(track: id), 0)
        try project.validate()
    }
    func testTempoAndMeterChangesKeepMarkerPhaseAndGaps() {
        var project = fixture(); let id = project.songs[0].tracks[0].id
        project.songs[0].parts[0].startTime = 1.1
        project.songs[0].markers = [TimelineMarker(id: UUID(), name: "Tempo", position: 3, color: 0, tempoBPM: 90, tempoBeats: 6, tempoUnit: 8)]
        project.insertClickItems(track: id)
        let song = project.songs[0]
        let sections = ClickTrackProgram.sections(song: song, track: song.tracks[0])
        XCTAssertEqual(sections.map(\.start), [1.1, 3, 8])
        XCTAssertEqual(sections.map(\.end), [3, 5, 12])
        XCTAssertEqual(sections.map(\.origin), [0, 3, 3])
        XCTAssertEqual(sections.map(\.bpm), [120, 90, 90])
        XCTAssertEqual(sections.map(\.unit), [4, 8, 8])
        XCTAssertEqual(sections.map(\.beats), [4, 6, 6])
        var duplicate = song.tracks[0]; duplicate.clips.append(duplicate.clips[0])
        XCTAssertEqual(ClickTrackProgram.sections(song: song, track: duplicate), sections, "Overlaps cannot double the click")
        duplicate.clips.removeAll()
        XCTAssertTrue(ClickTrackProgram.sections(song: song, track: duplicate).isEmpty)
    }
    func testOrdinaryClickAudioIsNotSpecialAndSpecialHasNoRecordingOrFX() throws {
        var project = fixture()
        XCTAssertEqual(Track(id: UUID(), name: "Click audio", role: .click).kind, .standard)
        project.songs[0].tracks[0].solo = true
        try project.validate()
        project.songs[0].tracks[0].fx = NativeFXSettings()
        XCTAssertThrowsError(try project.validate())
        project.songs[0].tracks[0].fx = nil
        project.songs[0].tracks[0].recordingFormat = "wav"
        XCTAssertThrowsError(try project.validate())
        project.songs[0].tracks[0].recordingFormat = nil
        project.songs[0].tracks.append(Track(id: UUID(), name: "Click", role: TrackRole(rawValue: TrackKind.click.rawValue)))
        XCTAssertThrowsError(try project.validate())
    }
    func testIllustratedPeaksFollowBeatGridAcrossTempoAndMeterChanges() {
        let timing = [TimelineTempoSection(start: 0, end: 2, bpm: 120, beats: 4, unit: 4, timebase: .free),
                      TimelineTempoSection(start: 2, end: 5, bpm: 60, beats: 6, unit: 8, timebase: .free)]
        let beats = ClickTrackProgram.visibleBeats(sections: timing, start: 0.1, end: 4.7, visibleStart: 0, visibleEnd: 5, pixelsPerSecond: 100)
        XCTAssertEqual(beats, [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5])
        let tile = ClickTrackProgram.visibleBeats(sections: timing, start: 0.1, end: 4.7, visibleStart: 1.8, visibleEnd: 3.2, pixelsPerSecond: 100)
        XCTAssertEqual(tile, [2, 2.5, 3])
        let distant = ClickTrackProgram.visibleBeats(sections: timing, start: 0, end: 5, visibleStart: 0, visibleEnd: 5, pixelsPerSecond: 0.1)
        XCTAssertLessThanOrEqual(distant.count, 2)
    }
    func testCustomSoundIsOwnedMediaAndSurvivesSaveAndMissingFileRecovery() throws {
        var project = fixture()
        project.songs[0].tracks[0].clickSound = AudioFile(path: "Stems/Click/test.wav")
        try project.validate()
        XCTAssertTrue(project.mediaPaths.contains("Stems/Click/test.wav"))
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(restored.songs[0].tracks[0].clickSound, project.songs[0].tracks[0].clickSound)
        let missing = ProjectAudioRecovery.missingPaths(in: project, directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(missing, ["Stems/Click/test.wav"])
        project.songs[0].tracks[0].clickSound = AudioFile(path: "../outside.wav")
        XCTAssertThrowsError(try project.validate())
    }

}

extension ClickTrackTests {
    func testExclusiveClickSubplayKeepsIncomingProgramAfterPromotion() {
        var project = Project.empty(name: "Click Subplay")
        let first = Part(id: UUID(), name: "Previous", startTime: 0, endTime: 4)
        let next = Part(id: UUID(), name: "Incoming", startTime: 2, endTime: 6)
        var song = project.songs[0]; song.duration = 6; song.bpm = 120
        song.parts = [first, next]; song.regionOwnershipInitialized = true
        var track = Track(id: UUID(), name: "Click", role: TrackRole(rawValue: "generatedClick"))
        var old = AudioClip(id: Project.clickItemID(first.id), name: "Old", startTime: 0, duration: 4)
        old.regionOwnerID = first.id; old.clickDouble = true
        var incoming = AudioClip(id: Project.clickItemID(next.id), name: "Incoming", startTime: 2, duration: 4)
        incoming.regionOwnerID = next.id
        track.clips = [old, incoming]; song.tracks = [track]; project.songs = [song]
        var transport = TransportState(playing: true, songId: song.id, position: 1,
            queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 2))
        let selected: Set<UUID> = [track.id]
        func sections(_ head: Int) -> [ClickTrackSection] {
            ClickTrackProgram.sections(song: song, track: track, transport: transport, head: head, selectedTracks: selected)
        }
        XCTAssertEqual(sections(0).first?.bpm, 240)
        let unchanged = ClickTrackProgram.playbackContext(song: song, track: track, transport: transport, head: 0, selectedTracks: selected)
        transport.position += 0.1
        XCTAssertEqual(ClickTrackProgram.playbackContext(song: song, track: track, transport: transport, head: 0, selectedTracks: selected), unchanged,
            "Advancing playback never rebuilds generator programs")
        transport.subPlay.playing = true; transport.subExclusivePlaybackRegionId = next.id
        XCTAssertTrue(sections(0).isEmpty, "The previous music's click stops when selected for Subplay")
        XCTAssertEqual(sections(1).map(\.bpm), [120], "Only the incoming item's own 1x setting plays")
        XCTAssertEqual(sections(1).map(\.start), [2]); XCTAssertEqual(sections(1).map(\.end), [6])
        XCTAssertFalse(ClickTrackProgram.sections(song: song, track: track, transport: transport, head: 0, selectedTracks: []).isEmpty,
            "Tracks not chosen for exclusive Subplay keep sounding")
        transport.subPlay.playing = false; transport.subExclusivePlaybackRegionId = nil
        transport.exclusivePlaybackRegionId = next.id; transport.position = 3
        XCTAssertEqual(sections(0).map(\.bpm), [120], "Promotion retains incoming membership through the entire song")
        track.clips[0].regionOwnerID = nil; track.clips[1].regionOwnerID = nil
        XCTAssertEqual(sections(0).map(\.bpm), [120], "Older generated click items resolve their original region")
        transport.exclusivePlaybackRegionId = nil
        XCTAssertEqual(sections(0).first?.bpm, 240, "A later independent Play restores ordinary click membership")
    }
}
