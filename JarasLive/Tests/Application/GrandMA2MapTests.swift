import XCTest
@testable import JarasApplication

final class GrandMA2MapTests: XCTestCase {
    func testStableAssignmentsPartialSelectionAndWindowsRoundTrip() throws {
        var project = Project.empty(name: "Show ação")
        let a = Part(id: UUID(), name: "Canção A", startTime: 0, endTime: 20)
        let b = Part(id: UUID(), name: "Canção B", startTime: 30, endTime: 50)
        project.songs[0].duration = 100; project.songs[0].parts = [a, b]
        let first = try GrandMA2Map.build(project: project, settings: GrandMA2Settings())
        XCTAssertEqual(first.plan.regions.map(\.offset), [0, 1])
        XCTAssertEqual(first.plan.regions.map(\.name), ["Cancao A", "Cancao B"])
        project.windowsLighting = first.persisted
        project.songs[0].parts = [b, Part(id: UUID(), name: "New", startTime: 60, endTime: 80)]
        let next = try GrandMA2Map.build(project: project, settings: GrandMA2Settings(), selected: [b.id])
        XCTAssertEqual(next.plan.regions.map(\.offset), [1, 2], "Deleted assignments stay reserved")
        XCTAssertEqual(next.plan.regions.map(\.selected), [true, false], "Unselected songs still supply Off events")
        project.windowsLighting = next.persisted
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(try GrandMA2Map.build(project: restored, settings: GrandMA2Settings()).plan.regions.map(\.offset), [1, 2])
    }
    func testMultipleTimelinesReserveAbsoluteTimeAndRejectGrowth() throws {
        var project = Project.empty(name: "Show")
        project.songs[0].duration = 60
        project.songs[0].parts = [Part(id: UUID(), name: "A", startTime: 10, endTime: 50)]
        var other = project.songs[0]; other.id = UUID()
        other.parts = [Part(id: UUID(), name: "B", startTime: 5, endTime: 40)]
        project.songs.append(other)
        let map = try GrandMA2Map.build(project: project, settings: GrandMA2Settings())
        XCTAssertEqual(map.plan.regions.map(\.start), [10, 185])
        XCTAssertEqual(map.plan.regions[1].cues[0].position, 185)
        project.windowsLighting = map.persisted
        project.songs[0].duration = 500
        XCTAssertThrowsError(try GrandMA2Map.build(project: project, settings: GrandMA2Settings()))
    }
    func testOverflowAndOpaquePlatformSettings() throws {
        var project = Project.empty(name: "Show")
        project.songs[0].parts = [Part(id: UUID(), name: "A", startTime: 0, endTime: 10), Part(id: UUID(), name: "B", startTime: 20, endTime: 30)]
        project.windowsLighting = .object(["futureOption": .string("preserve")])
        var settings = GrandMA2Settings(); settings.sequence = 9999
        XCTAssertThrowsError(try GrandMA2Map.build(project: project, settings: settings))
        let map = try GrandMA2Map.build(project: project, settings: GrandMA2Settings())
        guard case .object(let raw) = map.persisted else { return XCTFail("Object expected") }
        XCTAssertEqual(raw["futureOption"], .string("preserve"))
    }
    func testWindowsLowercaseIDsAndRemainingTimelineKeepTheirAssignments() throws {
        var project = Project.empty(name: "Show")
        let song = project.songs[0].id, region = UUID()
        project.songs[0].duration = 60
        project.songs[0].parts = [Part(id: region, name: "Remaining song", startTime: 10, endTime: 50)]
        let saved: [String: Any] = ["committed": true,
            "assignments": ["region:\(region.uuidString.lowercased())": 7],
            "starts": [song.uuidString.lowercased(): ["start": 180, "end": 300]]]
        project.windowsLighting = try JSONDecoder().decode(PortableProjectJSON.self, from: JSONSerialization.data(withJSONObject: saved))
        let map = try GrandMA2Map.build(project: project, settings: GrandMA2Settings())
        XCTAssertEqual(map.plan.regions[0].offset, 7)
        XCTAssertEqual(map.plan.regions[0].start, 190)
        XCTAssertEqual(map.plan.regions[0].cues[0].position, 190)
    }
}
