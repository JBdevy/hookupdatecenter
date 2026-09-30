import XCTest
@testable import JarasApplication
final class TrackLinkTests: XCTestCase {
    func testEligibilityAndExactRestoration() throws {
        var project = Project.empty(name: "Link")
        var a = Track(id: UUID(), name: "Keys A", role: .keys)
        a.color = 0x123456; a.volume = 0.6; a.pan = 0.2; a.inputPatch = OutputPatch(firstChannel: 5, channelCount: 2)
        var b = Track(id: UUID(), name: "Keys B", role: .keys)
        b.color = 0x654321; b.volume = 0.4; b.pan = -0.3
        let c = Track(id: UUID(), name: "Other", role: .keys)
        project.songs[0].tracks = [a,b,c]
        XCTAssertNil(project.songs[0].linkableTracks([a.id,c.id]))
        XCTAssertNil(project.songs[0].linkableTracks([a.id]))
        project.songs[0].linkTracks([a.id,b.id],firstInput: 5,color: a.color!)
        try project.validate()
        XCTAssertEqual(project.songs[0].tracks[1].inputPatch, OutputPatch(firstChannel: 6,channelCount: 1))
        XCTAssertEqual(project.songs[0].tracks[0].name, "L - Keys A")
        XCTAssertEqual(project.songs[0].tracks[1].name, "R - Keys B")
        XCTAssertEqual(project.songs[0].tracks[1].color, a.color)
        XCTAssertNil(project.songs[0].linkableTracks([a.id,b.id]))
        project = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        project.songs[0].unlinkTracks(b.id)
        XCTAssertEqual(project.songs[0].tracks, [a,b,c])
        project.songs[0].tracks[1].parentTrackID = a.id
        XCTAssertNil(project.songs[0].linkableTracks([a.id,b.id]))
    }
    func testDeletingPartnerRestoresSurvivor() throws {
        var p = Project.empty(name: "Delete")
        let a = Track(id: UUID(),name: "A",role: .keys), b = Track(id: UUID(),name: "B",role: .keys)
        p.songs[0].tracks = [a,b]
        p.songs[0].linkTracks([a.id,b.id],firstInput: 1,color: 0xffcc00)
        p.deleteTracks([a.id]); try p.validate()
        XCTAssertEqual(p.songs[0].tracks, [b])
    }
}
