import XCTest
@testable import JarasApplication

final class ResolumeTests: XCTestCase {
    func fixture() -> Project {
        var p = Project.empty(name: "Show")
        p.songs[0].duration = 50
        p.songs[0].parts = [Part(id: UUID(), name: "A", startTime: 0, endTime: 20), Part(id: UUID(), name: "B", startTime: 25, endTime: 40)]
        p.songs[0].markers = [TimelineMarker(id: UUID(), name: "Chorus", position: 10, color: 0), TimelineMarker(id: UUID(), name: "Tempo", position: 12, color: 0, tempoBPM: 130), TimelineMarker(id: UUID(), name: "Outside", position: 22, color: 0)]
        return p
    }
    func testStableAssignmentsSurviveMovingRegionsAndAppendingMarkers() throws {
        var p = fixture(), config = ResolumeSettings()
        let original = ResolumeMap.build(project: p, settings: config)
        XCTAssertEqual(original.cues.count, 3)
        config.withMarkers = original.assignments
        p.songs[0].parts[0].startTime = 41; p.songs[0].parts[0].endTime = 49
        p.songs[0].markers![0].position = 43
        p.songs[0].markers!.append(TimelineMarker(id: UUID(), name: "New", position: 42, color: 0))
        let read = ResolumeMap.build(project: p, settings: config, createMissing: false)
        XCTAssertEqual(read.assignments, original.assignments, "Playback never creates columns not yet exported")
        let updated = ResolumeMap.build(project: p, settings: config)
        XCTAssertEqual(updated.cues.first(where: { $0.name == "New" })?.column, 3)
        for (key, value) in original.assignments { XCTAssertEqual(updated.assignments[key], value) }
        p.resolume = config
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)).resolume, config)
    }
    func testUnifiedParentIsNotADeckAndSmallestRegionOwnsMarker() {
        var p = fixture()
        let parent = Part(id: UUID(), name: "Block", startTime: 0, endTime: 45)
        p.songs[0].parts[0].parentRegionID = parent.id; p.songs[0].parts[1].parentRegionID = parent.id
        p.songs[0].parts.append(parent)
        let map = ResolumeMap.build(project: p, settings: ResolumeSettings())
        XCTAssertEqual(map.cues.filter(\.isRegion).count, 2)
        XCTAssertNil(map.cues.first { $0.deckName == "Block" })
        XCTAssertEqual(map.cue(song: p.songs[0].id, at: 15)?.name, "Chorus")
        XCTAssertNil(map.cue(song: p.songs[0].id, at: 22))
    }
    func testOnlyInteriorNormalAndSectionMarkersCreateColumnsWithinTheirOwnUnifiedSong() {
        var p = fixture()
        let parent = Part(id: UUID(), name: "Block", startTime: 0, endTime: 45)
        p.songs[0].parts[0].parentRegionID = parent.id
        p.songs[0].parts[1].parentRegionID = parent.id
        p.songs[0].parts.append(parent)
        let a = p.songs[0].parts[0].id, b = p.songs[0].parts[1].id
        var markers = [
            TimelineMarker(id: UUID(), name: "A normal", position: 2, color: 0),
            TimelineMarker(id: UUID(), name: "A section", position: 5, color: 0, section: true),
            TimelineMarker(id: UUID(), name: "A loop", position: 7, color: 0, section: true, loopSection: true),
            TimelineMarker(id: UUID(), name: "Near start", position: 0.001, color: 0),
            TimelineMarker(id: UUID(), name: "Near end", position: 19.999, color: 0),
            TimelineMarker(id: UUID(), name: "B normal", position: 29, color: 0),
            TimelineMarker(id: UUID(), name: "B section", position: 35, color: 0, section: true),
            TimelineMarker(id: UUID(), name: "Outside", position: 22, color: 0),
            TimelineMarker(id: UUID(), name: "Outside section", position: 43, color: 0, section: true),
            TimelineMarker(id: UUID(), name: "Tempo", position: 12, color: 0, tempoBPM: 130),
            TimelineMarker(id: UUID(), name: "Linked region", position: 10, color: 0, sourceRegionID: a),
            TimelineMarker(id: UUID(), name: "Legacy unified boundary", position: 11, color: 0, unifiedRegionID: parent.id)
        ]
        for position in [0.0, 20.0, 25.0, 40.0] {
            markers.append(TimelineMarker(id: UUID(), name: "Boundary", position: position, color: 0))
        }
        p.songs[0].markers = markers
        var config = ResolumeSettings()
        let map = ResolumeMap.build(project: p, settings: config)
        XCTAssertEqual(Set(map.cues.filter { $0.region == a }.map(\.name)), ["Inicio", "A normal", "A section", "A loop", "Near start", "Near end"])
        XCTAssertEqual(Set(map.cues.filter { $0.region == b }.map(\.name)), ["Inicio", "B normal", "B section"])
        XCTAssertEqual(map.cues.filter(\.isRegion).count, 2)
        XCTAssertEqual(map.cues.count, 9)
        XCTAssertNil(map.cue(song: p.songs[0].id, at: 22))
        config.withMarkers = map.assignments
        let outside = markers.first { $0.name == "Outside" }!
        config.withMarkers["marker:\(outside.id.uuidString)"] = "0:99"
        let restored = ResolumeMap.build(project: p, settings: config, createMissing: false)
        XCTAssertEqual(restored.assignments, map.assignments, "Stale saved mappings must not resurrect outside markers")
        p.songs[0].parts.removeAll()
        XCTAssertTrue(ResolumeMap.build(project: p, settings: config).cues.isEmpty, "A timeline without regions must not create a virtual song")
    }
    func testExportNamesAreASCIIWithoutChangingProjectNamesOrSavedDestinations() {
        let examples = [
            ("$ Refrão", "Refrao"), ("Ação ç Ç", "Acao c C"),
            ("  \"Intro\" & <Parte> / \\ 🎶  ", "Intro Parte"),
            ("* Solo — 2_a", "Solo - 2_a"), ("🎶<>$", "Marcador")
        ]
        for (source, expected) in examples {
            XCTAssertEqual(LightingExportName.clean(source), expected)
        }
        XCTAssertEqual(LightingExportName.fileStem("CON"), "_CON")
        XCTAssertEqual(LightingExportName.fileStem("🎶"), "Projeto CatLive")
        var p = fixture()
        p.name = "Show Açúcar 🎶"
        p.songs[0].parts[0].name = "Ação"
        p.songs[0].parts[1].name = "Acao"
        p.songs[0].markers = examples.enumerated().map { index, example in
            TimelineMarker(id: UUID(), name: example.0, position: Double(index + 2), color: 0, section: true)
        }
        let originalNames = p.songs[0].markers!.map(\.name)
        var settings = ResolumeSettings()
        let map = ResolumeMap.build(project: p, settings: settings)
        for region in p.songs[0].parts {
            let start = map.cues.first { $0.region == region.id && $0.isRegion }
            XCTAssertEqual(start?.name, "Inicio")
            XCTAssertEqual(start?.position, region.startTime)
            XCTAssertEqual(start?.column, 1)
            XCTAssertEqual(start?.deckName, "Acao")
        }
        for (index, marker) in p.songs[0].markers!.enumerated() {
            let cue = map.cues.first { $0.key == "marker:\(marker.id.uuidString)" }
            XCTAssertEqual(cue?.name, examples[index].1)
            XCTAssertEqual(cue?.column, index + 2)
        }
        settings.withMarkers = map.assignments
        p.songs[0].parts[0].name = "🎶"
        let restored = ResolumeMap.build(project: p, settings: settings, createMissing: false)
        XCTAssertEqual(restored.assignments, map.assignments, "Export labels never change saved UUID mappings")
        XCTAssertEqual(restored.cues.first?.deckName, "Musica")
        XCTAssertEqual(p.name, "Show Açúcar 🎶")
        XCTAssertEqual(p.songs[0].markers!.map(\.name), originalNames)
    }
    func testPauseResumeDoesNotRestartPreparedColumnButLoopDoes() {
        let p = fixture(), map = ResolumeMap.build(project: p, settings: ResolumeSettings()), song = p.songs[0].id
        var follower = ResolumeFollower()
        let prepared = follower.update(map: map, song: song, position: 0, playing: false, time: 0)
        XCTAssertEqual(prepared.cue?.deck, 1); XCTAssertEqual(prepared.speed, 0)
        let play = follower.update(map: map, song: song, position: 0, playing: true, time: 1)
        XCTAssertNil(play.cue); XCTAssertEqual(play.speed, 1)
        _ = follower.update(map: map, song: song, position: 0.2, playing: true, time: 1.2)
        let loop = follower.update(map: map, song: song, position: 0, playing: true, time: 1.21)
        XCTAssertNotNil(loop.cue)
        let jump = follower.update(map: map, song: song, position: 26, playing: true, time: 1.3)
        XCTAssertEqual(jump.cue?.deck, 2)
        let pause = follower.update(map: map, song: song, position: 26, playing: false, time: 1.4)
        XCTAssertNil(pause.cue); XCTAssertEqual(pause.speed, 0)
        let resume = follower.update(map: map, song: song, position: 26, playing: true, time: 1.5)
        XCTAssertNil(resume.cue); XCTAssertEqual(resume.speed, 1)
    }
    func testMarkerModesKeepIndependentMappingsAndRejectInvalidSettings() throws {
        let p = fixture(); var config = ResolumeSettings()
        config.withMarkers = ["region:\(p.songs[0].parts[0].id.uuidString)": "4:0"]
        config.includeMarkers = false
        let map = ResolumeMap.build(project: p, settings: config)
        XCTAssertEqual(map.cues.count, 2); XCTAssertEqual(map.cues.first?.deck, 1)
        config.oscPort = 0; XCTAssertThrowsError(try config.validate())
        XCTAssertNil(ResolumeMap.assignment("-1:0")); XCTAssertNil(ResolumeMap.assignment("1:100000"))
    }
    func testReaperMapImportsBySourceIDsAndStaysDisabledInitially() {
        var p = fixture(); let song = p.songs[0]
        let raw = "{\"region:7\":\"3:0\",\"marker:9\":\"3:2\"}"
        let importer = VSHookProjectMigration(state: ["VS_HOOK_LOADER": ["RESOLUME_MAP_ASSIGNMENTS_WITH_MARKERS_V1": raw]], regionIDs: ["7": song.parts[0].id], sourceMarkers: [.init(number: "9", marker: song.markers![0])])
        var warnings = Set<String>(); importer.apply(to: &p, warnings: &warnings)
        XCTAssertEqual(p.resolume?.withMarkers["region:\(song.parts[0].id.uuidString)"], "3:0")
        XCTAssertEqual(p.resolume?.withMarkers["marker:\(song.markers![0].id.uuidString)"], "3:2")
        XCTAssertEqual(p.resolume?.enabled, false)
    }
}
