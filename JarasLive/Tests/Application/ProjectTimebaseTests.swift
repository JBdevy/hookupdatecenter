import XCTest
@testable import JarasApplication

final class ProjectTimebaseTests: XCTestCase {
    func testDefaultsAndProjectPersistence() throws {
        var project = Project.demo()
        XCTAssertEqual(project.songs[0].projectTime.divisions, 4)
        XCTAssertEqual(project.songs[0].projectTime.timebase, .free)
        var settings = ProjectTimeSettings()
        settings.timebase = .free; settings.divisions = 0
        settings.affectsMIDIItems = true; settings.affectsAutomationLength = false
        project.songs[0].timeSettings = settings
        try project.validate()
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
        project.songs[0].timeSettings?.divisions = 16
        XCTAssertThrowsError(try project.validate())
    }
    func testDivisionsAndNoneMatchSnappingWithoutChangingTiming() {
        let quarter = TimelineTempo.gridStep(bar: 2, beats: 4, pixelsPerSecond: 100, divisions: 4)
        XCTAssertEqual(quarter, 0.5)
        XCTAssertEqual(TimelineTempo.gridStep(bar: 2, beats: 4, pixelsPerSecond: 100, divisions: 2), 1)
        XCTAssertEqual(TimelineTempo.gridStep(bar: 2, beats: 4, pixelsPerSecond: 100, divisions: 8), 0.25)
        XCTAssertEqual(TimelineTempo.gridStep(bar: 1.5, beats: 3, pixelsPerSecond: 100, divisions: 4, unit: 8), 1)
        XCTAssertEqual(TimelineTempo.snap(1.13, bar: 2, beats: 4, pixelsPerSecond: 100, divisions: 8), 1.25)
        XCTAssertEqual(TimelineTempo.snap(1.13, bar: 2, beats: 4, pixelsPerSecond: 100, divisions: 0), 1.13)
        XCTAssertEqual(TimelineTempo.snap(1.13, bar: 2, beats: 4, pixelsPerSecond: 100, anchors: [1.1], divisions: 0), 1.1)
        var song = Project.demo().songs[0]
        let before = song
        var settings = ProjectTimeSettings(); settings.divisions = 8
        song.configureTiming(bpm: song.bpm, beats: song.meterBeats, unit: song.meterUnit, settings: settings)
        XCTAssertEqual(song.tracks, before.tracks)
        XCTAssertEqual(song.parts, before.parts)
        XCTAssertEqual(song.duration, before.duration)
        XCTAssertEqual(song.barSeconds, before.barSeconds)
    }
    func testFreeGridKeepsItemsAndRelativeGridFollowsTempo() {
        var original = Project.demo().songs[0]
        original.parts = [Part(id: UUID(), name: "Song", startTime: 30, endTime: 90)]
        var song = original, settings = ProjectTimeSettings()
        settings.timebase = .free
        song.configureTiming(bpm: original.bpm * 2, beats: 6, unit: 8, settings: settings)
        XCTAssertEqual(song.tracks, original.tracks)
        XCTAssertEqual(song.parts, original.parts)
        XCTAssertEqual(song.duration, original.duration)
        settings.timebase = .relative
        song.configureTiming(bpm: original.bpm, beats: 4, unit: 4, settings: settings)
        XCTAssertEqual(song.duration, original.duration * 2)
        XCTAssertEqual(song.parts[0].startTime, original.parts[0].startTime * 2)
        XCTAssertEqual(song.tracks[0].clips[0].audioRate, original.tracks[0].clips[0].audioRate / 2)
    }
}
