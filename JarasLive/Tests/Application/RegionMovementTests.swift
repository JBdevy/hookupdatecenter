import XCTest
@testable import JarasApplication

final class RegionMovementTests: XCTestCase {
    func testPreviewMovesEveryContainedKindAndBothMarkerTypesOnce() throws {
        var project = Project.empty(name: "Region movement")
        var song = project.songs[0]
        let root = Part(id: UUID(), name: "Whole", startTime: 10, endTime: 20)
        let child = Part(id: UUID(), name: "Child", startTime: 12, endTime: 18, parentRegionID: root.id)
        let next = Part(id: UUID(), name: "Next", startTime: 20, endTime: 30)
        song.parts = [root, child, next]; song.duration = 100
        song.tracks = [.standard, .video, .teleprompt, .teleprompt2, .chords, .timecode].map { (kind: TrackKind) in
            var track = Track(id: UUID(), name: kind == .standard ? "Audio" : kind.title, role: TrackRole(rawValue: kind.rawValue))
            var clip = AudioClip(id: UUID(), name: "Inside", startTime: 12, duration: 4)
            if kind.isText { clip.text = "Text" }
            else if kind == .video { clip.audioFile = AudioFile(path: "Videos/source.mov"); clip.sourceOffset = 1 }
            else if kind == .standard { clip.audioFile = AudioFile(path: "Stems/source.wav"); clip.sourceOffset = 2; clip.gain = 0.5 }
            else { track.importedTimecodeItems = true; clip.timecode = TimecodeSettings() }
            track.clips = [clip]
            return track
        }
        song.tracks[0].clips.append(AudioClip(id: UUID(), name: "Outside", startTime: 30, duration: 3))
        song.tracks[0].clips.append(AudioClip(id: UUID(), name: "Crossing boundary", startTime: 8, duration: 5))
        song.markers = [
            TimelineMarker(id: UUID(), name: "Start", position: 10, color: 0),
            TimelineMarker(id: UUID(), name: "Tempo", position: 13, color: 0, tempoBPM: 140, tempoTimebase: .relative),
            TimelineMarker(id: UUID(), name: "Cue", position: 16, color: 0),
            TimelineMarker(id: UUID(), name: "Child", position: 12, color: 0, unifiedRegionID: root.id, sourceRegionID: child.id),
            TimelineMarker(id: UUID(), name: "Next", position: 20, color: 0),
            TimelineMarker(id: UUID(), name: "Outside", position: 5, color: 0)
        ]
        project.songs = [song]; try project.validate()
        let moved = song.previewMovingRegion(root.id, to: 40)
        XCTAssertEqual(moved.parts.map(\.startTime), [40, 42, 20])
        XCTAssertEqual(moved.markers?.map(\.position), [40, 43, 46, 42, 20, 5])
        XCTAssertEqual(moved.markers?[1].tempoBPM, 140)
        XCTAssertEqual(moved.markers?[1].tempoTimebase, .relative)
        for track in song.tracks.indices {
            var expected = song.tracks[track].clips[0]; expected.startTime += 30
            XCTAssertEqual(moved.tracks[track].clips[0], expected)
        }
        XCTAssertEqual(moved.tracks[0].clips.dropFirst(), song.tracks[0].clips.dropFirst())
        XCTAssertEqual(moved.previewMovingRegion(root.id, to: 10), song)
        XCTAssertEqual(song.previewMovingRegion(child.id, to: 50), song)
        XCTAssertEqual(song.previewMovingRegion(root.id, to: -1), song)
    }
    func testPersistedOwnershipPreventsStealingOnOverlapAndReturn() throws {
        var song = Project.empty(name: "Explicit ownership").songs[0]
        let a = Part(id: UUID(), name: "A", startTime: 10, endTime: 20)
        let b = Part(id: UUID(), name: "B", startTime: 40, endTime: 60)
        song.parts = [a, b]; song.duration = 100; song.regionOwnershipInitialized = true
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Own", startTime: 12, duration: 2, regionOwnerID: a.id),
            AudioClip(id: UUID(), name: "Foreign", startTime: 45, duration: 2, regionOwnerID: b.id),
            AudioClip(id: UUID(), name: "Loose", startTime: 75, duration: 2)]
        song.tracks = [track]
        song.markers = [TimelineMarker(id: UUID(), name: "Own", position: 14, color: 0, regionOwnerID: a.id),
            TimelineMarker(id: UUID(), name: "Foreign", position: 47, color: 0, regionOwnerID: b.id),
            TimelineMarker(id: UUID(), name: "Loose", position: 78, color: 0)]
        let overlap = song.previewMovingRegion(a.id, to: 40)
        let reopened = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(overlap))
        XCTAssertEqual(reopened.previewMovingRegion(a.id, to: 10), song)
        let overLoose = reopened.previewMovingRegion(a.id, to: 70)
        XCTAssertEqual(overLoose.tracks[0].clips[2].startTime, 75)
        XCTAssertEqual(overLoose.markers?[2].position, 78)
        XCTAssertEqual(overLoose.previewMovingRegion(a.id, to: 10), song)
        // The obstacle belongs to B even when it lies underneath moved A.
        let repulsion = RegionMarkerRepulsion(song: overlap, region: overlap.parts[0])
        XCTAssertEqual(repulsion.resolve(43), 43.01, accuracy: 1e-8)
    }
    func testNativeTimecodeWithExtendedEdgesMatchesCommittedRegionMove() {
        var song = Project.empty(name: "Native TC").songs[0]
        let root = Part(id: UUID(), name: "Song", startTime: 10, endTime: 20)
        song.parts = [root]; song.duration = 30
        var track = Track(id: UUID(), name: "Timecode", role: TrackRole(rawValue: "timecode"))
        track.clips = [AudioClip(id: Project.timecodeItemID(root.id), name: "Timecode", startTime: 8, duration: 15, timecodeStartOffset: -2, timecodeEndOffset: 3)]
        song.tracks = [track]
        let moved = song.previewMovingRegion(root.id, to: 40)
        XCTAssertEqual(moved.tracks[0].clips[0].startTime, 38)
        XCTAssertEqual(moved.tracks[0].clips[0].duration, 15)
        XCTAssertEqual(moved.duration, 53)
    }
    func testMarkerRepulsionMovesWholeRegionToNearestFreeSide() {
        var song = Project.empty(name: "Repulsion").songs[0]
        let region = Part(id: UUID(), name: "Moving", startTime: 10, endTime: 20)
        song.parts = [region]; song.duration = 100
        song.markers = [
            TimelineMarker(id: UUID(), name: "Tempo", position: 13, color: 0, tempoBPM: 120),
            TimelineMarker(id: UUID(), name: "Cue", position: 16, color: 0),
            TimelineMarker(id: UUID(), name: "Drawer", position: 18, color: 0, unifiedRegionID: region.id),
            TimelineMarker(id: UUID(), name: "Stationary", position: 43, color: 0)
        ]
        let magnet = RegionMarkerRepulsion(song: song, region: region, minimumGap: 0.5)
        XCTAssertEqual(magnet.resolve(40), 40.5, accuracy: 1e-8)
        XCTAssertEqual(magnet.resolve(39.9), 39.5, accuracy: 1e-8)
        XCTAssertEqual(magnet.resolve(40.1), 40.5, accuracy: 1e-8)
        XCTAssertEqual(magnet.resolve(30), 30)
        for proposed in stride(from: 30.0, through: 45.0, by: 0.03) {
            let result = song.previewMovingRegion(region.id, to: magnet.resolve(proposed))
            for marker in result.markers!.dropLast() {
                XCTAssertGreaterThanOrEqual(abs(marker.position - 43), 0.5 - 1e-8)
            }
        }
        var atOrigin = song
        atOrigin.markers = [TimelineMarker(id: UUID(), name: "Moving", position: 10, color: 0), TimelineMarker(id: UUID(), name: "Zero", position: 0, color: 0)]
        XCTAssertEqual(RegionMarkerRepulsion(song: atOrigin, region: region, minimumGap: 0.5).resolve(0), 0.5)
        song.markers?.append(TimelineMarker(id: UUID(), name: "Close cue", position: 43.4, color: 0))
        let cluster = RegionMarkerRepulsion(song: song, region: region, minimumGap: 0.5)
        XCTAssertEqual(cluster.resolve(40.4), 40.9, accuracy: 1e-8)
        XCTAssertEqual(cluster.resolve(40.1), 39.5, accuracy: 1e-8)
    }

}
