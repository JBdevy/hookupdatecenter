import XCTest
@testable import JarasApplication

final class ClickTrackTests: XCTestCase {
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
