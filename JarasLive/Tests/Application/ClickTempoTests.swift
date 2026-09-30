import XCTest
@testable import JarasApplication
final class ClickTempoTests: XCTestCase {
    func testTempoChangesKeepTheirFirstBeatAndIgnoreDroppedBeats() {
        let first = (0..<12).map { 0.123 + Double($0) * 0.5 }
        let second = (0..<12).filter { $0 != 5 }.map { 6.123 + Double($0) * (2.0 / 3.0) }
        let sections = ClickTempoDetector.sections(onsets: first + second)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].position, 0.123, accuracy: 1e-9)
        XCTAssertEqual(sections[0].bpm, 120)
        XCTAssertEqual(sections[1].position, 6.123, accuracy: 1e-9)
        XCTAssertEqual(sections[1].bpm, 90)
    }
    func testNoiseDoesNotInventTempo() {
        XCTAssertTrue(ClickTempoDetector.sections(onsets: []).isEmpty)
        XCTAssertTrue(ClickTempoDetector.sections(onsets: [0, 0.01, 0.04, 1.8, 1.85, 1.88, 1.9]).isEmpty)
    }
    func testMarkersFollowClickClipPositionAndFallBackOnlyWithoutClickAudio() throws {
        var song = Project.empty(name: "Test").songs[0]
        let region = Part(id: UUID(), name: "Song", startTime: 10, endTime: 30)
        var click = Track(id: UUID(), name: "CLICK", role: .click)
        click.clips = [AudioClip(id: UUID(), name: "Click", startTime: 12, duration: 12,
                                 audioFile: AudioFile(path: "Stems/Click.wav"))]
        song.tracks = [click]
        let onsets = (0..<12).map { 0.125 + Double($0) * 0.5 }
        let detected = try ClickTempoDetector.markers(song: song, region: region) { _ in onsets }
        XCTAssertTrue(detected.hasClickAudio)
        XCTAssertEqual(detected.markers.count, 1)
        XCTAssertEqual(detected.markers[0].position, 12.125, accuracy: 1e-9)
        XCTAssertEqual(detected.markers[0].tempoBPM, 120)

        song.tracks = []
        let fallback = try ClickTempoDetector.markers(song: song, region: region) { _ in
            XCTFail("A file should not be read without a Click clip")
            return []
        }
        XCTAssertFalse(fallback.hasClickAudio)
        XCTAssertEqual(fallback.markers.map(\.position), [10])
        XCTAssertEqual(fallback.markers.first?.tempoBPM, 120)
        XCTAssertEqual(fallback.markers.first?.tempoBeats, 4)
        XCTAssertEqual(fallback.markers.first?.tempoUnit, 4)

        song.tracks = [click]
        let silent = try ClickTempoDetector.markers(song: song, region: region) { _ in [] }
        XCTAssertTrue(silent.hasClickAudio)
        XCTAssertTrue(silent.markers.isEmpty)
    }
    func testDetectedTempoRoundsToWholeBPMWithoutMovingTheFirstPulse() throws {
        for (measured, expected) in [(143.91, 144.0), (143.499, 143.0), (119.501, 120.0)] {
            let onsets = (0..<20).map { 2.123 + Double($0) * 60 / measured }
            let sections = ClickTempoDetector.sections(onsets: onsets)
            XCTAssertEqual(sections.count, 1)
            let section = try XCTUnwrap(sections.first)
            XCTAssertEqual(section.bpm, expected)
            XCTAssertEqual(section.position, 2.123, accuracy: 1e-9)
        }
    }
    func testSuffixesIncludeAllExistingFilesAndRetainedUndoMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: nested.appendingPathComponent("Click.wav"))
        try Data([1]).write(to: root.appendingPathComponent("click-01.wav"))
        var names = MediaFileNames(directory: root)
        XCTAssertEqual(names.allocate("Click.wav"), "Click-02.wav")
        XCTAssertEqual(names.allocate("Click.wav"), "Click-03.wav")
        XCTAssertEqual(names.allocate("Sanfona.wav", forceSuffix: true), "Sanfona-01.wav")
        XCTAssertEqual(names.allocate("Sanfona.wav", forceSuffix: true), "Sanfona-02.wav")
    }
}
