import XCTest
@testable import JarasApplication

final class OutputPatchTests: XCTestCase {
    func testNoneInputSurvivesSaveAndLinkedValidation() throws {
        var project = Project.empty(name: "Instrument without hardware input")
        var track = Track(id: UUID(), name: "Kontakt", role: .keys)
        track.inputPatch = OutputPatch.none
        track.recordingOutput = true
        project.songs[0].tracks = [track]
        try project.validate()
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.songs[0].tracks[0].inputPatch, OutputPatch.none)
        XCTAssertEqual(decoded.songs[0].tracks[0].recordingOutput, true)
        XCTAssertEqual(OutputPatch.choices(channels: 0, includeMaster: false, includeNone: true), [.none])
        let partner = Track(id: UUID(), name: "Right", role: .keys)
        project.songs[0].tracks.append(partner)
        project.songs[0].linkTracks([track.id, partner.id], firstInput: 1, color: 0x44aa55)
        for i in 0..<2 { project.songs[0].tracks[i].inputPatch = OutputPatch.none }
        XCTAssertNoThrow(try project.validate())
        project.songs[0].tracks[1].inputPatch = OutputPatch(firstChannel: 2, channelCount: 1)
        XCTAssertThrowsError(try project.validate())
    }
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
