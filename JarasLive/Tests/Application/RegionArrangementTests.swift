import XCTest
@testable import JarasApplication

final class RegionArrangementTests: XCTestCase {
    func testSelectedRegionsInsertCumulativeSpacesAndCarryUnselectedFamiliesOnce() throws {
        var project = Project.empty(name: "Spaces")
        var song = project.songs[0]
        let ids = (0..<6).map { _ in UUID() }
        song.parts = ids.enumerated().map { Part(id: $0.element, name: "R\($0.offset)", startTime: Double($0.offset * 100), endTime: Double($0.offset * 100 + 80)) }
        let child = Part(id: UUID(), name: "Unified child", startTime: 405, endTime: 475, parentRegionID: ids[4])
        song.parts.append(child); song.duration = 700
        song.timeSettings = ProjectTimeSettings(); song.timeSettings?.timebase = .relative
        song.timeSettings?.affectsAutomationLength = false
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = ids.enumerated().map { AudioClip(id: UUID(), name: "Item\($0.offset)", startTime: Double($0.offset * 100 + 10), duration: 40, sourceOffset: 2, playbackRate: 0.75, regionOwnerID: $0.element) }
        // This crosses two regions and has the greatest duration inside R3.
        track.clips.append(AudioClip(id: UUID(), name: "Crossing", startTime: 270, duration: 100, regionOwnerID: ids[2]))
        var automation = TrackAutomation()
        var envelope = TrackEnvelope(target: AutomationTarget(.volume), name: "Volume", defaultValue: 0.5)
        envelope.points = [.init(time: 15, value: 0.2), .init(time: 315, value: 0.7), .init(time: 515, value: 0.9)]
        automation.envelopes = [envelope]; track.automation = automation
        song.tracks = [track]
        song.markers = [.init(id: UUID(), name: "Tempo", position: 310, color: 0, tempoBPM: 140, tempoTimebase: .relative),
                        .init(id: UUID(), name: "Gap", position: 290, color: 0),
                        .init(id: UUID(), name: "Child", position: 405, color: 0, unifiedRegionID: ids[4], sourceRegionID: child.id)]
        let original = song
        let plan = RegionSpacingPlan(song: song, selected: [ids[0], ids[2], ids[3], ids[4], child.id])
        plan.apply(to: &song)
        XCTAssertEqual(song.parts.prefix(6).map(\.startTime), [0, 130, 230, 360, 490, 590])
        XCTAssertEqual(song.parts.last?.startTime, 495)
        XCTAssertEqual(song.tracks[0].clips.map(\.startTime), [10, 140, 240, 370, 500, 600, 330])
        XCTAssertEqual(song.tracks[0].automation?.envelopes[0].points.map(\.time), [15, 375, 605])
        XCTAssertEqual(song.markers?.map(\.position), [370, 350, 495])
        XCTAssertEqual(song.timeSettings, original.timeSettings)
        XCTAssertEqual(song.markers?[0].tempoBPM, 140)
        for (before, after) in zip(original.tracks[0].clips, song.tracks[0].clips) {
            XCTAssertEqual(before.duration, after.duration); XCTAssertEqual(before.audioRate, after.audioRate)
            XCTAssertEqual(before.sourceOffset, after.sourceOffset)
        }
        project.songs = [song]; try project.validate()
    }
    func testFitEndUsesFarthestCoveredItemAndExcludesUnifiedAndDerivedItems() {
        var song = Project.empty(name: "Fit").songs[0]
        let a = Part(id: UUID(), name: "A", startTime: 0, endTime: 40)
        let b = Part(id: UUID(), name: "B", startTime: 100, endTime: 180)
        song.parts = [a,b]
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Long", startTime: 0, duration: 60),
                       AudioClip(id: UUID(), name: "Later end", startTime: 35, duration: 30),
                       AudioClip(id: UUID(), name: "Outside", startTime: 200, duration: 100)]
        var tc = Track(id: UUID(), name: "Timecode", role: .init(rawValue: "timecode"))
        tc.clips = [AudioClip(id: UUID(), name: "Derived", startTime: 0, duration: 1000)]
        song.tracks = [tc,track]
        XCTAssertEqual(song.endAtLongestItem(in: a.id), 65)
        XCTAssertNil(song.endAtLongestItem(in: b.id))
        song.parts[1].parentRegionID = a.id
        XCTAssertNil(song.endAtLongestItem(in: a.id)); XCTAssertNil(song.endAtLongestItem(in: b.id))
        let original = song
        RegionSpacingPlan(song: song, selected: [a.id,b.id]).apply(to: &song)
        XCTAssertEqual(song, original)
    }
}
