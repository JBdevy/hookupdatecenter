#if os(macOS)
import XCTest
@testable import JarasApplication

final class ReaperMIDIImportTests: XCTestCase {
    private func imported(_ source: String, item: String = "POSITION 2\nLENGTH 4\nLOOP 0", tempo: String = "TEMPO 120 4 4", extra: String = "", directory: URL? = nil) throws -> ProjectMigration.Result {
        let folder = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if directory == nil { try? FileManager.default.removeItem(at: folder) } }
        let url = folder.appendingPathComponent("MIDI.rpp")
        let text = "<REAPER_PROJECT 0.1\n\(tempo)\n<TRACK\nNAME MIDI\n<ITEM\n\(item)\nNAME Notes\n<SOURCE MIDI\n\(source)\n>\n>\n\(extra)\n>\n>"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let result = try ReaperProjectImporter.read(url)
        XCTAssertEqual(try String(contentsOf: url), text, "Import must not modify the source project")
        return result
    }
    private func clip(_ result: ProjectMigration.Result) throws -> AudioClip { try XCTUnwrap(result.project.songs[0].tracks.first?.clips.first) }
    func testInlineChannelsVelocitySelectedMutedAndSysexOffsetsRoundTrip() throws {
        let result = try imported("""
        HASDATA 1 480 QN
        e 0 90 3c 40
        E 0 9f 48 5a
        <X 240 0
        8AECAwQF9w==
        >
        E 240 80 3c 00
        E 0 9f 48 00
        Em 0 91 30 7f
        Em 480 81 30 00
        E 960 b0 7b 00
        IGNTEMPO 0 120 4 4
        """)
        let item = try clip(result), notes = try XCTUnwrap(item.midi?.notes)
        XCTAssertEqual(notes.map(\.pitch), [60, 72])
        XCTAssertEqual(notes.map(\.channel), [1, 16])
        XCTAssertEqual(notes.map(\.velocity), [64, 90])
        XCTAssertEqual(notes.map(\.length), [1, 1])
        XCTAssertEqual(item.midiPlaybackNotes().map(\.start), [2, 2])
        XCTAssertEqual(item.midiPlaybackNotes().map(\.end), [2.5, 2.5])
        XCTAssertTrue(result.media.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("Muted MIDI") })
        XCTAssertTrue(result.warnings.contains { $0.contains("Choose an instrument") })
        XCTAssertEqual(try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(result.project)), result.project)
    }
    func testLoopTrimAndPlaybackRateMaterializeExactAudibleNotes() throws {
        let result = try imported("""
        HASDATA 1 960 QN
        E 0 90 3c 7f
        E 960 80 3c 00
        E 960 b0 7b 00
        """, item: "POSITION 10\nLENGTH 2\nLOOP 1\nSOFFS 0.25 0.5\nPLAYRATE 2 1 0")
        let item = try clip(result), notes = item.midiPlaybackNotes()
        XCTAssertEqual(notes.count, 5)
        for (actual, expected) in zip(notes.map(\.start), [10.0, 10.375, 10.875, 11.375, 11.875]) { XCTAssertEqual(actual, expected, accuracy: 1e-8) }
        for (actual, expected) in zip(notes.map(\.end), [10.125, 10.625, 11.125, 11.625, 12.0]) { XCTAssertEqual(actual, expected, accuracy: 1e-8) }
        XCTAssertEqual(item.sourceOffset, 0); XCTAssertEqual(item.audioRate, 1); XCTAssertNil(item.loopLength)
    }
    func testProjectTempoChangesAndIgnoredTempo() throws {
        let events = "HASDATA 1 960 QN\nE 0 90 3c 64\nE 3840 80 3c 00\nE 0 90 40 64\nE 960 80 40 00"
        let map = "TEMPO 120 4 4\n<TEMPOENVEX\nPT 0 120 1\nPT 2 60 1\n>"
        let result = try imported(events, item: "POSITION 1\nLENGTH 5\nLOOP 0", tempo: map)
        let notes = try clip(result).midiPlaybackNotes()
        XCTAssertEqual(notes.map(\.start), [1, 4]); XCTAssertEqual(notes.map(\.end), [4, 5])
        let ignored = try imported(events + "\nIGNTEMPO 1 120 4 4", item: "POSITION 1\nLENGTH 5\nLOOP 0", tempo: map)
        XCTAssertEqual(try clip(ignored).midiPlaybackNotes().map(\.end), [3, 3.5])
    }
    func testLinearTempoRampIsBakedIntoNoteTimes() throws {
        let result = try imported("HASDATA 1 960 QN\nE 0 90 3c 64\nE 5760 80 3c 00",
            item: "POSITION 0\nLENGTH 5\nLOOP 0", tempo: "TEMPO 120 4 4\n<TEMPOENVEX\nPT 0 120 0\nPT 4 60 1\n>")
        XCTAssertEqual(try clip(result).midiPlaybackNotes()[0].end, 4, accuracy: 1e-8)
    }
    func testRealREAPERSourceOffsetAndRateOracle() throws {
        // Generated in an isolated REAPER instance with MIDI_InsertNote;
        // MIDI_GetProjTimeFromPPQPos returned 10.222222222222/10.666666666667
        // for the first audible note. SOFFS field 2 is QN (not seconds * 2).
        let result = try imported("""
        HASDATA 1 960 QN
        E 0 90 3c 5a
        E 960 80 3c 00
        e 960 9f 48 7f
        e 960 8f 48 00
        Em 960 91 30 50
        Em 480 81 30 00
        E 1440 b0 7b 00
        IGNTEMPO 0 120 4 4
        """, item: "POSITION 10\nLENGTH 6\nLOOP 1\nSOFFS 1 1.5\nPLAYRATE 1.5 1 0", tempo: "TEMPO 90 4 4")
        let notes = try clip(result).midiPlaybackNotes()
        XCTAssertEqual(notes.map(\.pitch), [72, 60, 72, 60, 72])
        XCTAssertEqual(notes[0].start, 10.222222222222, accuracy: 1e-9)
        XCTAssertEqual(notes[0].end, 10.666666666667, accuracy: 1e-9)
        XCTAssertEqual(notes.last?.end, 16)
    }
    func testPoolReferenceBeforeDefinitionAndOverlappingPitchPairing() throws {
        let definition = """
        <ITEM
        POSITION 10
        LENGTH 4
        <SOURCE MIDI
        HASDATA 1 960 QN
        POOLEDEVTS {pool}
        E 0 90 3c 40
        E 480 90 3c 60
        E 480 80 3c 00
        E 480 80 3c 00
        E 2400 b0 7b 00
        >
        >
        """
        let result = try imported("HASDATA 1 960 QN\nPOOLEDEVTS {pool}", extra: definition)
        let notes = try clip(result).midiPlaybackNotes()
        XCTAssertEqual(notes.map(\.start), [2, 2.25]); XCTAssertEqual(notes.map(\.end), [2.5, 2.75])
        XCTAssertEqual(result.project.songs[0].tracks[0].clips[1].midi?.notes.count, 2)
    }
    private func midiFile() -> Data {
        // Type 0, PPQ 480, name, tempo 120, two channels and running-status
        // note-on velocity zero (note-off), followed by a silent end interval.
        let track: [UInt8] = [0, 0xff, 3, 4, 84, 101, 115, 116,
            0, 0xff, 0x51, 3, 7, 0xa1, 0x20,
            0, 0x90, 60, 90, 0x83, 0x60, 60, 0,
            0, 0x9f, 72, 127, 0x83, 0x60, 0x8f, 72, 0,
            0x83, 0x60, 0xff, 0x2f, 0]
        return Data(Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 1, 0xe0] + Array("MTrk".utf8) + [0, 0, 0, UInt8(track.count)] + track)
    }
    func testExternalMIDIFileAndSharedDecoderRunningStatus() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = midiFile(), url = directory.appendingPathComponent("External.mid")
        try bytes.write(to: url)
        let file = try StandardMIDIFileImport.read(bytes)
        XCTAssertEqual(file.tracks.flatMap(\.notes).map(\.channel), [1, 16])
        XCTAssertEqual(file.tracks.flatMap(\.notes).map(\.length), [1, 1])
        XCTAssertEqual(file.seconds(atBeat: 2), 1, accuracy: 1e-8)
        let result = try imported("FILE \"External.mid\"", tempo: "TEMPO 60 4 4", directory: directory)
        let notes = try clip(result).midiPlaybackNotes()
        XCTAssertEqual(notes.map(\.start), [2, 3]); XCTAssertEqual(notes.map(\.end), [3, 4])
        XCTAssertTrue(result.media.isEmpty, "MIDI notes must be embedded in the saved CatLive project")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testMalformedMIDIAndMissingExternalSourceFailExplicitly() throws {
        for source in ["HASDATA 1 0 QN", "HASDATA 1 960 QN\nE nan 90 3c 64", "HASDATA 1 960 QN\nE 0 90 ff 64", "POOLEDEVTS {missing}", "FILE \"missing.mid\""] {
            XCTAssertThrowsError(try imported(source), source)
        }
        XCTAssertThrowsError(try StandardMIDIFileImport.read(midiFile().dropLast()))
    }
}
#endif
