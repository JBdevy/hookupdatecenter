import XCTest
@testable import JarasApplication

final class OutputPatchTests: XCTestCase {
    func testOutputChoicesUseOnlyAvailableChannels() {
        XCTAssertEqual(OutputPatch.choices(channels: 0, includeMaster: true), [.master])
        XCTAssertEqual(OutputPatch.choices(channels: 3, includeMaster: true).map(\.title), ["Master", "1+2", "1", "2", "3"])
        XCTAssertEqual(OutputPatch.choices(channels: 2, includeMaster: false).map(\.title), ["1+2", "1", "2"])
        XCTAssertThrowsError(try OutputPatch.master.validate(allowMaster: false))
    }
    func testTrackAndMasterRoutesSurviveProjectSave() throws {
        var project = Project.empty(name: "Routing")
        var track = Track(id: UUID(), name: "Piano", role: .keys)
        track.patch = OutputPatch(firstChannel: 3, channelCount: 2)
        project.songs[0].tracks.append(track)
        project.masterPatch = OutputPatch(firstChannel: 5, channelCount: 2)
        try project.validate()
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded, project)
    }
}
