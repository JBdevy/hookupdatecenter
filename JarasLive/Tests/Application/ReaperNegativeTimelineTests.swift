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
    func testFirstNegativeItemDefinesZeroPreservingArrangementMediaAndAutomation() throws {
        let result = try read("""
        <REAPER_PROJECT 0.1
          TEMPO 120 4 4
          MARKER 1 -2 Song 1
          MARKER 1 12 "" 1
          MARKER 2 -1 Cue 0
          <TEMPOENVEX
            PT -10 100 1 262148
            PT 0 120 1
          >
          <PANENV2
            PT -10 -1 0
            PT 0 1 0
          >
          <TRACK
            NAME Audio
            <PANENV2
              PT -10 -1 0
              PT 0 1 0
            >
            <ITEM
              POSITION -10
              LENGTH 3
              SOFFS 2
              PLAYRATE 1.25
              NAME First
              <SOURCE WAVE
                FILE first.wav
              >
            >
            <ITEM
              POSITION 4
              LENGTH 6
              NAME Second
              <SOURCE WAVE
                FILE second.wav
              >
            >
          >
        >
        """)
        let project = result.project, song = project.songs[0], clips = song.tracks[0].clips
        XCTAssertEqual(clips.map(\.startTime), [0, 14])
        XCTAssertEqual(clips.map(\.duration), [3, 6])
        XCTAssertEqual(clips[0].sourceOffset, 2)
        XCTAssertEqual(clips[0].audioRate, 1.25)
        XCTAssertEqual(song.parts.first(where: { $0.name == "Song" })?.startTime, 8)
        XCTAssertEqual(song.parts.first(where: { $0.name == "Song" })?.endTime, 22)
        XCTAssertEqual(song.markers?.first(where: { $0.name == "Cue" })?.position, 9)
        XCTAssertEqual(song.markers?.filter(\.isTempo).map(\.position), [0, 10])
        XCTAssertEqual(song.markers?.filter(\.isTempo).map(\.tempoBPM), [100, 120])
        XCTAssertEqual(song.tracks[0].automation?.envelopes.first?.points.map(\.time), [0, 10])
        XCTAssertEqual(project.masterAutomation?.envelopes.first?.points.map(\.time), [0, 10])
        XCTAssertEqual(song.tracks[0].automation?.envelopes.first?.value(at: 5), 0.5)
        XCTAssertEqual(result.media.count, 2)
    }
    func testEarlierNegativeRegionDefinesZeroAndMIDITimingStaysRelative() throws {
        let result = try read("""
        <REAPER_PROJECT 0.1
          TEMPO 120 4 4
          MARKER 1 -20 Song 1
          MARKER 1 -2 "" 1
          <TEMPOENVEX
            PT -20 120 1 262148
            PT -9 60 1
          >
          <TRACK
            NAME MIDI
            <ITEM
              POSITION -10
              LENGTH 4
              <SOURCE MIDI
                HASDATA 1 960 QN
                E 0 90 3c 7f
                E 960 80 3c 00
              >
            >
          >
        >
        """)
        let song = result.project.songs[0], clip = song.tracks[0].clips[0]
        XCTAssertEqual(song.parts[0].startTime, 0)
        XCTAssertEqual(song.parts[0].endTime, 18)
        XCTAssertEqual(clip.startTime, 10)
        XCTAssertEqual(clip.duration, 4)
        let note = try XCTUnwrap(clip.midi?.notes.first)
        XCTAssertEqual(note.start, 0, accuracy: 0.000001)
        XCTAssertEqual(note.length, 1, accuracy: 0.000001)
        XCTAssertEqual(song.markers?.filter(\.isTempo).map(\.position), [0, 11])
    }
    func testNonnegativeProjectsKeepTheirExistingPositions() throws {
        for position in [0, 8] {
            let result = try read("""
            <REAPER_PROJECT 0.1
              MARKER 1 4 Song 1
              MARKER 1 20 "" 1
              <TEMPOENVEX
                PT -4 100 1
                PT 4 120 1
              >
              <TRACK
                NAME Audio
                <ITEM
                  POSITION \(position)
                  LENGTH 3
                >
              >
            >
            """)
            XCTAssertEqual(result.project.songs[0].tracks[0].clips[0].startTime, Double(position))
            XCTAssertEqual(result.project.songs[0].parts[0].startTime, 4)
            XCTAssertEqual(result.project.songs[0].markers?.filter(\.isTempo).map(\.position), [4])
        }
    }
    func testNegativeOnlyItemGetsAutomaticRegionAtTheNewBeginning() throws {
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
        XCTAssertEqual(result.project.songs[0].tracks[0].clips[0].startTime, 0)
        XCTAssertEqual(result.project.songs[0].parts[0].startTime, 0)
        XCTAssertEqual(result.project.songs[0].duration, 1)
    }
}
#endif
