#if os(macOS)
import XCTest
@testable import JarasApplication

final class VSHookProjectImportTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VSHook-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func read(_ body: String, in directory: URL) throws -> ProjectMigration.Result {
        let file = directory.appendingPathComponent("Show.rpp")
        try ("<REAPER_PROJECT 0.1 \"7.0\" 1\nTEMPO 120 4 4\n" + body + "\n>\n")
            .write(to: file, atomically: true, encoding: .utf8)
        return try ReaperProjectImporter.read(file)
    }

    private func region(_ id: Int, _ start: Int, _ end: Int, _ name: String) -> String {
        "MARKER \(id) \(start) \"\(name)\" 1\nMARKER \(id) \(end) \"\" 1"
    }

    private func binary(_ key: String, _ value: String) -> String {
        let encoded = Array(Data((value + "\0").utf8).base64EncodedString())
        let lines = stride(from: 0, to: encoded.count, by: 60).map { String(encoded[$0..<min($0 + 60, encoded.count)]) }
        return "<BIN \(key)\n" + lines.joined(separator: "\n") + "\n>"
    }

    private func metadata(_ playlist: String = "", loops: String = "") -> String {
        "<EXTSTATE\n<CHATGPT_REGION_PLAYLIST\n" + playlist + "\n>\n<VS_HOOK_MULTILOOPS\n" + loops + "\n>\n>"
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\p")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func item(_ id: String, _ start: Int, _ end: Int, _ name: String,
                      kind: String = "song", sourceKind: String = "region", child: Bool = false,
                      marker: String = "", color: String = "", centered: Bool = false) -> String {
        ["ITEM", kind, id, String(start), String(end), escaped(name), color, sourceKind,
         "0", child ? "1" : "0", marker, "", "", centered ? "1" : "0", "1"].joined(separator: "\t")
    }

    private func assertPersisted(_ result: ProjectMigration.Result, in directory: URL,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let document = directory.appendingPathComponent("Imported.jl")
        try ProjectMigration.save(result, to: document)
        let loaded = try await ProjectStore(url: document).load()
        XCTAssertEqual(loaded, result.project, file: file, line: line)
    }

    func testBinaryRepertoiresPreserveEscapedNamesOrderBlocksAndSelectedList() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selectedName = "Domingo | Noite\tFinal\nBis\\Ao vivo"
        let playlists = [
            "PLAYLIST\tAbertura",
            item("-1", 0, 0, "Introdução | banda", kind: "block", color: "green"),
            item("7", 20, 30, "Segundo"),
            item("-2", 0, 0, "Louvor", kind: "block", color: "purple", centered: true),
            item("0", 0, 10, "Primeiro"),
            item("-3", 0, 0, "Fim", kind: "block", color: "orange"),
            "END", "PLAYLIST\t" + escaped(selectedName),
            item("0", 0, 10, "Primeiro"), item("7", 20, 30, "Segundo"), "END"
        ].joined(separator: "\n")
        let result = try read([
            region(0, 0, 10, "Primeiro"), region(7, 20, 30, "Segundo"),
            metadata(binary("PLAYLISTS_DB_V3", playlists) + "\n" + binary("LAST_PLAYLIST_NAME_V1", selectedName))
        ].joined(separator: "\n"), in: directory)
        let song = result.project.songs[0], setlist = try XCTUnwrap(result.project.regionSetlist)
        let byName = Dictionary(uniqueKeysWithValues: song.parts.map { ($0.name, $0.id) })
        XCTAssertEqual(setlist.playlists.map(\.name), ["Abertura", selectedName])
        XCTAssertEqual(setlist.playlists[0].regionIds, [byName["Segundo"]!, byName["Primeiro"]!])
        XCTAssertEqual(setlist.playlists[1].regionIds, [byName["Primeiro"]!, byName["Segundo"]!])
        XCTAssertEqual(setlist.selectedId, setlist.playlists[1].id)
        let blocks = try XCTUnwrap(setlist.blocks)
        XCTAssertEqual(blocks.map(\.name), ["Introdução | banda", "Louvor", "Fim"])
        XCTAssertEqual(blocks.map(\.beforeRegionId), [byName["Segundo"], byName["Primeiro"], nil])
        XCTAssertEqual(blocks.map(\.color), [0x2EBD5C, 0x8F57F0, 0xF58F29])
        XCTAssertEqual(blocks.map(\.symbol), [true, false, true])
        XCTAssertTrue(blocks.allSatisfy { $0.playlistId == setlist.playlists[0].id })
        try await assertPersisted(result, in: directory)
    }

    func testQuotedTabStateMigratesFourLoopSlotsWithoutCreatingDrawerSongs() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var markers: [String] = []
        for slot in 1...4 {
            markers.append("MARKER \(100 + slot * 2) \(slot * 20 - 15) \"*\(slot) entrada\" 0")
            markers.append("MARKER \(101 + slot * 2) \(slot * 20 - 10) \"*\(slot) saída\" 0")
        }
        markers.append("MARKER 199 90 \"*Ponte\" 0")
        let state = ["E", "10", "1", "0", "0", "1", "1", "0", "1", "0"].joined(separator: "\t")
        let result = try read([
            region(10, 0, 100, "Canção"), markers.joined(separator: "\n"),
            "<TRACK {11111111-1111-1111-1111-111111111111}\nNAME \"  # Keys\"\n>",
            metadata("TUNER_OFFSETS_V1 \"10=-12\"", loops: "STATE_V2 \"\(state)\"")
        ].joined(separator: "\n"), in: directory)
        let song = result.project.songs[0], part = try XCTUnwrap(song.parts.first)
        XCTAssertEqual(song.parts.count, 1, "Loop flags and other star commands are not child songs")
        XCTAssertEqual(part.semitones, -12)
        let loops = try XCTUnwrap(part.multiLoops)
        XCTAssertEqual(loops.map(\.name), ["*1", "*2", "*3", "*4"])
        XCTAssertEqual(loops.map(\.isEnabled), [true, false, true, false])
        XCTAssertEqual(loops.map(\.usesMixer), [false, true, true, false])
        XCTAssertEqual(song.markers?.count, 9)
        XCTAssertEqual(song.markers?.first(where: { $0.position == 5 })?.name, "ENTRADA")
        XCTAssertEqual(song.markers?.first(where: { $0.position == 90 })?.name, "PONTE")
        XCTAssertTrue(song.markers?.allSatisfy { !$0.name.hasPrefix("*") && $0.isSection } == true)
        XCTAssertTrue(song.markers?.allSatisfy { $0.sourceRegionID == nil && $0.unifiedRegionID == nil } == true)
        let positions = Dictionary(uniqueKeysWithValues: (song.markers ?? []).map { ($0.id, $0.position) })
        XCTAssertEqual(loops.compactMap { positions[$0.marker1] }, [5, 25, 45, 65])
        XCTAssertEqual(loops.compactMap { positions[$0.marker2] }, [10, 30, 50, 70])
        XCTAssertEqual(part.pitchTrackIDs, [song.tracks[0].id])
        try await assertPersisted(result, in: directory)
    }

    func testBinaryLoopMixerRulesUseTrackGUIDsAndSurvivePersistence() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let guitar = "{AAAAAAAA-1111-1111-1111-111111111111}", keys = "{BBBBBBBB-2222-2222-2222-222222222222}"
        let mixer = [
            ["T", "5", "1", "2", "0", "0"],
            ["P", "5", "1", guitar.lowercased(), "1", "0"],
            ["F", "5", "1", keys, "1", "1"],
            ["L", "5", "1", keys, "-9", "0"],
            ["P", "5", "1", "{DELETED-TRACK}", "0", "1"]
        ].map { $0.joined(separator: "\t") }.joined(separator: "\n")
        let result = try read([
            region(5, 0, 20, "Canção"), "MARKER 20 3 \"*1\" 0", "MARKER 21 10 \"*1\" 0",
            "<TRACK \(guitar)\nNAME \"Guitar\"\n>", "<TRACK \(keys)\nNAME \"Keys\"\n>",
            metadata(loops: binary("STATE_V2", "E\t5\t1\t0\t1\t0\t0\t0\t0\t0") + "\n" + binary("MS_STATE_V1", mixer))
        ].joined(separator: "\n"), in: directory)
        let song = result.project.songs[0], loop = try XCTUnwrap(song.parts[0].multiLoops?.first)
        XCTAssertTrue(loop.isEnabled); XCTAssertTrue(loop.usesMixer)
        XCTAssertEqual(loop.fadeSeconds, 2)
        XCTAssertEqual(loop.tracks.map(\.id), song.tracks.map(\.id))
        XCTAssertTrue(loop.tracks[0].mute); XCTAssertFalse(loop.tracks[0].solo)
        XCTAssertTrue(loop.tracks[1].autoFader)
        XCTAssertEqual(loop.tracks[1].gain, pow(10, -9.0 / 20), accuracy: 0.0000001)
        try await assertPersisted(result, in: directory)
    }

    func testTunerPreservesOctavesAndOnlySelectsHashPrefixedGroupsAndTracks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try read([
            region(1, 0, 10, "Mais"), region(2, 10, 20, "Menos"), region(3, 20, 30, "Original"),
            "<TRACK\nNAME \"  # Keys group\"\nISBUS 1 1\n>",
            "<TRACK\nNAME \"Piano\"\nISBUS 2 -1\n>",
            "<TRACK\nNAME \"# Guitar\"\n>", "<TRACK\nNAME \"Drums #\"\n>",
            metadata("TUNER_OFFSETS_V1 \"1=12|2=-12\"")
        ].joined(separator: "\n"), in: directory)
        let song = result.project.songs[0]
        XCTAssertEqual(song.parts.map(\.semitones), [12, -12, 0])
        for part in song.parts {
            XCTAssertEqual(part.pitchGroupIDs, [song.tracks[0].id])
            XCTAssertEqual(part.pitchTrackIDs, [song.tracks[2].id])
            XCTAssertEqual(song.pitch(for: song.tracks[1].id, region: part), part.semitones)
            XCTAssertEqual(song.pitch(for: song.tracks[3].id, region: part), 0)
        }
        try await assertPersisted(result, in: directory)
    }

    func testDollarAndUnpairedStarTypesSurviveImport() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try read([region(1, 0, 30, "Song"),
            "MARKER 2 5 \"$verse\" 0", "MARKER 3 10 \"*3 bridge\" 0"
        ].joined(separator: "\n"), in: directory)
        let song = result.project.songs[0], part = result.project.songs[0].parts[0]
        XCTAssertEqual(song.sectionMarkers(in: part).map(\.name), ["VERSE", "BRIDGE"])
        XCTAssertEqual(song.multiLoopMarkers(in: part).map(\.name), ["BRIDGE"])
    }

    func testUnmarkedTracksRemainUnselectedEvenWhenImportedSongHasTunerOffset() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try read([
            region(1, 0, 10, "Canção"), "<TRACK\nNAME \"Guitar #\"\n>",
            metadata("TUNER_OFFSETS_V1 \"1=8\"")
        ].joined(separator: "\n"), in: directory)
        let song = result.project.songs[0], part = song.parts[0]
        XCTAssertEqual(part.semitones, 8)
        XCTAssertEqual(part.pitchTrackIDs, []); XCTAssertEqual(part.pitchGroupIDs, [])
        XCTAssertEqual(song.pitch(for: song.tracks[0].id, region: part), 0)
    }

    func testMarkerChildAndRegionWithSameSourceNumberResolveIndependentlyAndIgnoreStaleIDs() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let playlist = [
            "PLAYLIST\tShow", item("100", 0, 20, "Filha A", sourceKind: "marker", child: true, marker: "7"),
            item("7", 50, 70, "Solta"), item("100", 0, 40, "Família"),
            item("7", 50, 70, "Repetida"), item("999", 50, 70, "Removida"),
            item("100", 0, 20, "Filha removida", sourceKind: "marker", child: true, marker: "999"), "END"
        ].joined(separator: "\n")
        let result = try read([
            region(100, 0, 40, "-- Família"), region(7, 50, 70, "Solta"),
            "MARKER 7 0 \"Filha A\" 0", "MARKER 8 20 \"Filha B\" 0",
            "MARKER 30 22 \"*2\" 0", "MARKER 31 27 \"*2\" 0",
            metadata(binary("PLAYLISTS_DB_V3", playlist) + "\nTUNER_OFFSETS_V1 \"7=3|8=-7|100=12\"",
                     loops: "STATE_V2 \"E\t8\t0\t1\t0\t0\t0\t0\t0\t0\"")
        ].joined(separator: "\n"), in: directory)
        let song = result.project.songs[0]
        let parent = try XCTUnwrap(song.parts.first { $0.name == "Família" })
        let standalone = try XCTUnwrap(song.parts.first { $0.name == "Solta" })
        let children = song.parts.filter { $0.parentRegionID == parent.id }.sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(children.map(\.name), ["Filha A", "Filha B"])
        XCTAssertEqual(children.map(\.semitones), [3, -7])
        XCTAssertEqual(parent.semitones, 0, "A VS Hook family header is never a tuner target")
        XCTAssertEqual(standalone.semitones, 3)
        XCTAssertEqual(result.project.regionSetlist?.playlists.first?.regionIds, [parent.id, standalone.id])
        XCTAssertEqual(children[1].multiLoops?.map(\.name), ["*2"])
        XCTAssertEqual(children[1].multiLoops?.first?.isEnabled, true)
        XCTAssertTrue(result.warnings.contains { $0.contains("removidas") })
        try await assertPersisted(result, in: directory)
    }

    func testNestedRegionChildrenDoNotResolveAsSameNumberMarkers() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let playlists = ["PLAYLIST\tFilhos", item("10", 0, 20, "Região filha", sourceKind: "region", child: true), "END"].joined(separator: "\n")
        let result = try read([
            region(100, 0, 40, "-- Família de regiões"), region(10, 0, 20, "Região filha"),
            region(200, 50, 80, "-- Família de marcadores"), "MARKER 10 50 \"Outro filho\" 0",
            metadata(binary("PLAYLISTS_DB_V3", playlists))
        ].joined(separator: "\n"), in: directory)
        let song = result.project.songs[0], parent = try XCTUnwrap(song.parts.first { $0.name == "Família de regiões" })
        XCTAssertEqual(result.project.regionSetlist?.playlists.first?.regionIds, [parent.id])
    }

    func testSectionPrefixesAreRemovedWithoutChangingInternalSymbolsOrCreatingSongs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try read([region(1, 0, 20, "Canção"),
            "MARKER 4 2 \"$ Refrão\" 0", "MARKER 5 6 \"$Preço $5 * final\" 0",
            "MARKER 6 10 \"$\" 0"].joined(separator: "\n"), in: directory)
        XCTAssertEqual(result.project.songs[0].parts.count, 1)
        let markers = result.project.songs[0].markers ?? []
        XCTAssertEqual(markers.map(\.name), ["REFRÃO", "PREÇO $5 * FINAL", "TRECHO"])
        XCTAssertTrue(markers.allSatisfy(\.isSection))
    }

    func testMissingLoopEnableStatePreservesPairsDisabled() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try read([region(1, 0, 20, "Canção"), "MARKER 4 2 \"*1\" 0", "MARKER 5 6 \"*1\" 0"].joined(separator: "\n"), in: directory)
        let loop = try XCTUnwrap(result.project.songs[0].parts[0].multiLoops?.first)
        XCTAssertFalse(loop.isEnabled); XCTAssertFalse(loop.usesMixer)
    }

    func testLoopAutofaderWithoutExplicitLimitFadesToSilence() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let guid = "{AAAAAAAA-1111-1111-1111-111111111111}"
        let result = try read([
            region(1, 0, 20, "Canção"), "MARKER 4 2 \"*1\" 0", "MARKER 5 6 \"*1\" 0",
            "<TRACK \(guid)\nNAME \"Guitar\"\n>",
            metadata(loops: binary("STATE_V2", "E\t1\t1\t0\t1\t0\t0\t0\t0\t0") + "\n" + binary("MS_STATE_V1", "F\t1\t1\t\(guid)\t1\t1"))
        ].joined(separator: "\n"), in: directory)
        let rule = try XCTUnwrap(result.project.songs[0].parts[0].multiLoops?.first?.tracks.first)
        XCTAssertTrue(rule.autoFader)
        XCTAssertEqual(rule.gain, 0, "VS Hook's unspecified auto-fader limit is silence, not unity gain")
    }

    func testLoopEndpointWithinVSBoundaryToleranceUsesNormalizedMarker() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try read([
            region(1, 0, 20, "Canção"), "MARKER 4 2 \"*1\" 0", "MARKER 5 20.0004 \"*1\" 0",
            metadata(loops: "STATE_V2 \"E\t1\t1\t0\t0\t0\t0\t0\t0\t0\"")
        ].joined(separator: "\n"), in: directory)
        let song = result.project.songs[0], loop = try XCTUnwrap(song.parts[0].multiLoops?.first)
        XCTAssertTrue(loop.isEnabled)
        let end = try XCTUnwrap(song.markers?.first { $0.id == loop.marker2 })
        XCTAssertEqual(end.position, song.parts[0].endTime, accuracy: 0.000001)
    }

    func testOrdinarySongCueDoesNotBecomeDrawerOrConsumeItsTunerSetting() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try read([
            region(1, 0, 20, "Canção"), "MARKER 2 7 \"Refrão\" 0", metadata("TUNER_OFFSETS_V1 \"1=9|2=-7\"")
        ].joined(separator: "\n"), in: directory)
        let song = result.project.songs[0]
        XCTAssertEqual(song.parts.count, 1)
        XCTAssertEqual(song.parts[0].semitones, 9)
        XCTAssertEqual(song.markers?.map(\.name), ["Refrão"])
        XCTAssertNil(song.markers?.first?.sourceRegionID)
    }

    func testOptInExistingVSProjectReadOnly() throws {
        guard let path = ProcessInfo.processInfo.environment["CATLIVE_TEST_VSHOOK_RPP"], !path.isEmpty else {
            throw XCTSkip("Set CATLIVE_TEST_VSHOOK_RPP to validate the existing VS Hook reference project read-only.")
        }
        let source = URL(fileURLWithPath: path), original = try Data(contentsOf: source)
        let result = try ReaperProjectImporter.read(source)
        let setlist = try XCTUnwrap(result.project.regionSetlist)
        XCTAssertEqual(setlist.playlists.map { $0.regionIds.count }, [44, 12, 7])
        XCTAssertEqual(setlist.blocks?.count, 9)
        XCTAssertEqual(setlist.playlists.first { $0.id == setlist.selectedId }?.name, "SALVADOR")
        let text = try XCTUnwrap(String(data: original, encoding: .utf8))
        func sourceStart(_ number: Int) throws -> Double {
            let regex = try NSRegularExpression(pattern: "(?m)^\\s*MARKER \(number) ([0-9.]+) ")
            let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
            let range = try XCTUnwrap(Range(match.range(at: 1), in: text))
            return try XCTUnwrap(Double(text[range]))
        }
        let song = result.project.songs[0], tunerStart = try sourceStart(41), loopStart = try sourceStart(26)
        XCTAssertEqual(song.parts.first { abs($0.startTime - tunerStart) < 0.000001 }?.semitones, 2)
        let part = try XCTUnwrap(song.parts.first { abs($0.startTime - loopStart) < 0.000001 })
        XCTAssertEqual(part.multiLoops?.first { $0.name == "*1" }?.isEnabled, true)
        XCTAssertEqual(try Data(contentsOf: source), original, "Migration must not modify the source RPP")
    }

    func testInvalidBinaryMetadataFailsInsteadOfSilentlyLosingConfiguration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try read(region(1, 0, 10, "Canção") + "\n" + metadata("<BIN PLAYLISTS_DB_V3\nnot-base64!!\n>"), in: directory))
    }
}
#endif
