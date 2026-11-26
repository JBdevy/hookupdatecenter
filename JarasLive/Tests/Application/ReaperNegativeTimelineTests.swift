#if os(macOS)
import XCTest
@testable import JarasApplication

final class ReaperNegativeTimelineTests: XCTestCase {
    private func read(_ text: String) throws -> ProjectMigration.Result {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Negative.rpp")
        try text.write(to: source, atomically: true, encoding: .utf8)
        let original = try Data(contentsOf: source)
        let result = try ReaperProjectImporter.read(source)
        try result.project.validate()
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(result.project)), result.project)
        return result
    }
    func testHiddenNegativeItemsAreIgnoredWithoutMovingVisibleItemsRegionsOrAutomation() throws {
        let result = try read("""
        <REAPER_PROJECT 0.1
          PROJOFFS -15211.38407776579 0 0
          TEMPO 120 4 4
          MARKER 1 0 Song 1
          MARKER 1 12 "" 1
          MARKER 2 -1 Hidden 0
          MARKER 3 4 Cue 0
          <PANENV2
            PT -10 -1 0
            PT 10 1 0
          >
          <TRACK
            NAME Audio
            <ITEM
              POSITION -594434.3062285987
              LENGTH 0.36145124712493
              <SOURCE WAVE
                FILE hidden.wav
              >
            >
            <ITEM
              POSITION -2
              LENGTH 3
              <SOURCE WAVE
                FILE starts_before_boundary.wav
              >
            >
            <ITEM
              POSITION 0.07392
              LENGTH 6
              SOFFS 2
              PLAYRATE 1.25
              <SOURCE WAVE
                FILE visible.wav
              >
            >
          >
        >
        """)
        let song = result.project.songs[0], clips = song.tracks[0].clips
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].startTime, 0.07392)
        XCTAssertEqual(clips[0].duration, 6)
        XCTAssertEqual(clips[0].sourceOffset, 2)
        XCTAssertEqual(clips[0].audioRate, 1.25)
        XCTAssertEqual(song.parts[0].startTime, 0)
        XCTAssertEqual(song.parts[0].endTime, 12)
        XCTAssertEqual(song.markers?.map(\.position), [4])
        XCTAssertEqual(result.media.count, 1, "ignored items must not request media recovery or plugin scans")
        XCTAssertEqual(result.media.first?.relativePath.hasSuffix("visible.wav"), true)
        XCTAssertEqual(result.project.masterAutomation?.envelopes.first?.points.map(\.time), [0, 10])
        XCTAssertTrue(result.warnings.contains { $0.contains("2 REAPER items") })
    }
    func testNegativeRegionsAreClippedAtProjectStartAndInitialTempoRemainsCorrect() throws {
        let result = try read("""
        <REAPER_PROJECT 0.1
          TEMPO 120 4 4
          MARKER 1 -20 Hidden 1
          MARKER 1 -10 "" 1
          MARKER 2 -5 Visible 1
          MARKER 2 12 "" 1
          <TEMPOENVEX
            PT -20 100 1 262148
            PT -3 110 1
            PT 8 140 1
          >
          <TRACK
            NAME Audio
            <ITEM
              POSITION 1
              LENGTH 4
              <SOURCE WAVE
                FILE visible.wav
              >
            >
          >
        >
        """)
        let song = result.project.songs[0]
        XCTAssertEqual(song.parts.count, 1)
        XCTAssertEqual(song.parts[0].name, "Visible")
        XCTAssertEqual(song.parts[0].startTime, 0)
        XCTAssertEqual(song.parts[0].endTime, 12)
        XCTAssertEqual(song.tracks[0].clips[0].startTime, 1)
        let tempo = (song.markers ?? []).filter(\.isTempo).sorted { $0.position < $1.position }
        XCTAssertEqual(tempo.map(\.position), [0, 8])
        XCTAssertEqual(tempo.map(\.tempoBPM), [110, 140])
    }
    func testRulerTimeAndMeasureOffsetsDoNotMoveNonnegativeProjects() throws {
        for offset in ["0 0 0", "-300 -8 0", "3600 16 0"] {
            let result = try read("""
            <REAPER_PROJECT 0.1
              PROJOFFS \(offset)
              MARKER 1 8 Song 1
              MARKER 1 20 "" 1
              <TRACK
                NAME Audio
                <ITEM
                  POSITION 9
                  LENGTH 3
                  <SOURCE WAVE
                    FILE visible.wav
                  >
                >
              >
            >
            """)
            XCTAssertEqual(result.project.songs[0].tracks[0].clips[0].startTime, 9)
            XCTAssertEqual(result.project.songs[0].parts[0].startTime, 8)
        }
    }
    func testProjectContainingOnlyOffscreenItemsOpensWithoutNegativeTimeline() throws {
        let result = try read("""
        <REAPER_PROJECT 0.1
          <TRACK
            NAME Audio
            <ITEM
              POSITION -594434.3062285987
              LENGTH 0.36145124712493
            >
          >
        >
        """)
        XCTAssertTrue(result.project.songs[0].tracks[0].clips.isEmpty)
        XCTAssertTrue(result.project.songs[0].parts.isEmpty)
        XCTAssertEqual(result.project.songs[0].duration, 1)
    }
    func testCustomerProjectWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["CATLIVE_TEST_REAPER_SOURCE"] else { throw XCTSkip("Customer RPP provided locally") }
        let url = URL(fileURLWithPath: path), original = try Data(contentsOf: url)
        let result = try ReaperProjectImporter.read(url)
        try result.project.validate()
        let song = result.project.songs[0]
        XCTAssertEqual(song.parts.map(\.startTime).min(), 0)
        XCTAssertTrue(song.tracks.flatMap(\.clips).allSatisfy { $0.startTime >= 0 })
        XCTAssertTrue(result.warnings.contains { $0.contains("3 REAPER items") })
        XCTAssertFalse(result.warnings.contains { $0.contains("Nested REAPER") })
        XCTAssertEqual(try Data(contentsOf: url), original)
        let names = Dictionary(uniqueKeysWithValues: song.tracks.map { ($0.id, $0.name) })
        let report = song.tracks.map { $0.name + "\t" + ($0.parentTrackID.flatMap { names[$0] } ?? "—") }.joined(separator: "\n")
        try report.write(to: URL(fileURLWithPath: "/tmp/catlive-imported-customer-groups.tsv"), atomically: true, encoding: .utf8)
        print("CUSTOMER_REAPER_VISIBLE_FIRST_REGION_ZERO_TRACKS=\(song.tracks.count) ITEMS=\(song.tracks.flatMap(\.clips).count)")
    }
}
#endif
