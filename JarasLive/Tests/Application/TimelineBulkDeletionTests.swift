import XCTest
@testable import JarasApplication

final class TimelineBulkDeletionTests: XCTestCase {
    private func fixture() -> Project {
        var project = Project.empty(name: "Bulk timeline")
        let parent = Part(id: UUID(), name: "Unified", startTime: 0, endTime: 20)
        var child = Part(id: UUID(), name: "Member", startTime: 0, endTime: 20)
        child.parentRegionID = parent.id
        var marker = TimelineMarker(id: UUID(), name: "Member", position: 0, color: 0xffff00)
        marker.unifiedRegionID = parent.id; marker.sourceRegionID = child.id
        let manual = TimelineMarker(id: UUID(), name: "Cue", position: 5, color: 0xffffff)
        let tempo = TimelineMarker(id: UUID(), name: "Tempo", position: 10, color: 0x999999, tempoBPM: 125, tempoBeats: 4, tempoUnit: 4)
        project.songs[0].duration = 20; project.songs[0].parts = [parent, child]
        project.songs[0].markers = [marker, manual, tempo]
        var track = Track(id: UUID(), name: "Audio", role: .other)
        var clip = AudioClip(id: UUID(), name: "Take", startTime: 1, duration: 5)
        clip.regionOwnerID = parent.id; track.clips = [clip]
        project.songs[0].tracks = [track]
        return project
    }
    func testCategoriesPreserveUnifiedMarkersAndMedia() throws {
        let original = fixture(), song = original.songs[0].id
        for kind in TimelineBulkDeletion.allCases {
            var project = original
            project.deleteTimelineElements(kind, song: song)
            try project.validate()
            XCTAssertEqual(project.songs[0].tracks[0].clips.map(\.id), original.songs[0].tracks[0].clips.map(\.id))
            XCTAssertFalse((project.songs[0].markers ?? []).contains(where: kind.matches))
            if kind == .regions {
                XCTAssertTrue(project.songs[0].parts.isEmpty)
                XCTAssertNil(project.songs[0].tracks[0].clips[0].regionOwnerID)
                XCTAssertEqual(project.songs[0].markers?.count, 2)
            } else {
                XCTAssertEqual(project.songs[0].parts, original.songs[0].parts)
                XCTAssertTrue(project.songs[0].markers!.contains { $0.unifiedRegionID != nil })
            }
        }
    }
    func testUnrelatedSongAndInvalidTargetAreUnchanged() {
        let original = fixture()
        var project = original
        project.deleteTimelineElements(.regions, song: UUID())
        XCTAssertEqual(project, original)
        var other = original.songs[0]; other.id = UUID(); other.parts = []; other.markers = []; other.tracks = []
        project.songs.append(other)
        project.deleteTimelineElements(.regions, song: original.songs[0].id)
        XCTAssertEqual(project.songs[1], other)
    }
    func testConversionUsesVSHookBoundsAndExplainsFailures() throws {
        var project = Project.empty(name: "Converter")
        var song = project.songs[0]; song.duration = 40
        song.parts = [Part(id: UUID(), name: "Existing", startTime: 25, endTime: 30)]
        song.markers = [("First",0.0),("Second",10),("No audio",5),("*1",8),("Inside",26),("No audio 2",20)].map { TimelineMarker(id: UUID(), name: $0.0, position: $0.1, color: 0x123456) }
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [(0.0,20.0),(0,30),(10,25),(8,3)].map { start, length in
            var clip = AudioClip(id: UUID(), name: "Take", startTime: start, duration: length)
            clip.audioFile = AudioFile(path: "Stems/take.wav"); return clip
        }
        song.tracks = [track]; project.songs[0] = song; let before = project
        let result = try XCTUnwrap(project.convertMarkersToRegions(song: song.id))
        XCTAssertEqual(result.plans.map(\.end), [10,25]); XCTAssertEqual(result.skipped.count,4)
        XCTAssertTrue(result.message.contains("Alinhe o marcador")); XCTAssertTrue(result.message.contains("reservado"))
        XCTAssertTrue(result.message.contains("fora das regiões"))
        XCTAssertEqual(project.songs[0].tracks, before.songs[0].tracks)
        XCTAssertEqual(project.songs[0].markers?.count,4); XCTAssertEqual(project.songs[0].parts.last?.color,0x123456)
        try project.validate()
        var single = before
        let invalid = try XCTUnwrap(single.convertMarkersToRegions(song: song.id, markerID: song.markers![2].id))
        XCTAssertTrue(invalid.plans.isEmpty); XCTAssertEqual(single,before)
        XCTAssertFalse(MarkerRegionConversion.outsideRegions(song.markers![4], in: song))
    }

}
