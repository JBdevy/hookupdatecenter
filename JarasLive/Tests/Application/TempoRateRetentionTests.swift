import XCTest
@testable import JarasApplication

final class TempoRateRetentionTests: XCTestCase {
    private func fixture() -> Song {
        var song = Project.empty(name: "Rate retention").songs[0]
        song.bpm = 120; song.duration = 20; song.timeSettings = ProjectTimeSettings()
        let clip = AudioClip(id: UUID(), name: "Audio", startTime: 0, duration: 10, playbackRate: 1.2)
        var track = Track(id: UUID(), name: "Track", role: .other); track.clips = [clip]; song.tracks = [track]
        song.markers = [TimelineMarker(id: UUID(), name: "First", position: 0, color: 0, tempoBPM: 150, tempoTimebase: .global, tempoReferenceBPM: 120),
                        TimelineMarker(id: UUID(), name: "Second", position: 5, color: 0, tempoBPM: 90, tempoTimebase: .global, tempoReferenceBPM: 90)]
        return song
    }
    private func rates(_ song: Song, item: Int = 0) -> [Double] { song.tempoAudioSegments(song.tracks[0].clips[item]).map(\.audioRate) }
    private func edit(_ song: inout Song, index: Int, bpm: Double) {
        let before = song, previous = song.markers![index]
        var marker = previous; marker.tempoBPM = bpm
        song.markers![index] = before.retainingTempoRate(marker, previous: previous)
        TempoEditMap(before: before, after: song).apply(to: &song)
    }
    func testTimebaseFreezesAndResumesWithoutChangingCurrentRateOrGeometry() throws {
        var song = fixture(); let original = song.tracks[0].clips[0]
        var settings = song.projectTime; settings.timebase = .free
        song.configureTiming(bpm: 120, beats: 4, unit: 4, settings: settings)
        XCTAssertEqual(rates(song), [1.5, 1.2]); XCTAssertEqual(song.tracks[0].clips[0], original)
        edit(&song, index: 0, bpm: 180)
        XCTAssertEqual(rates(song), [1.5, 1.2]); XCTAssertEqual(song.tracks[0].clips[0], original)
        settings.timebase = .relative; song.configureTiming(bpm: 120, beats: 4, unit: 4, settings: settings)
        XCTAssertEqual(rates(song), [1.5, 1.2])
        edit(&song, index: 0, bpm: 198)
        XCTAssertEqual(rates(song)[0], 1.65, accuracy: 1e-10)
        XCTAssertEqual(rates(song)[1], 1.2, accuracy: 1e-10)
        let restored = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(restored, song); XCTAssertEqual(rates(restored), rates(song))
    }
    func testResetClearsEveryTempoSectionOnlyForTheSelectedItemAndFollowsLaterEdits() throws {
        var song = fixture(); let original = song.tracks[0].clips[0], markers = song.markers
        var other = original; other.id = UUID(); song.tracks[0].clips.append(other)
        song.tracks[0].clips[0] = song.resettingItemRate(original)
        XCTAssertEqual(rates(song), [1]); XCTAssertEqual(rates(song, item: 1), [1.5, 1.2])
        XCTAssertEqual(song.markers, markers); XCTAssertEqual(song.tracks[0].clips[0].duration, original.duration)
        edit(&song, index: 0, bpm: 165)
        XCTAssertEqual(rates(song)[0], 1.1, accuracy: 1e-10); XCTAssertEqual(rates(song)[1], 1)
        let restored = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(restored, song); XCTAssertEqual(rates(restored), rates(song))
    }
    func testRegionTempoChangesUseOneProportionAcrossDifferentBPMS() {
        var song = fixture(); song.markers![0].tempoReferenceBPM = 150
        let region = Part(id: UUID(), name: "Song", startTime: 0, endTime: 10); song.parts = [region]
        let changes = song.regionTempoChange(15, region: region)
        let first = changes.first { $0.id == song.markers![0].id }!, second = changes.first { $0.id == song.markers![1].id }!
        XCTAssertEqual(first.tempoBPM!, 165, accuracy: 1e-10)
        XCTAssertEqual(second.tempoBPM!, 99, accuracy: 1e-10)
        XCTAssertEqual(first.tempoPlaybackRate!, 1.1, accuracy: 1e-10)
        XCTAssertEqual(second.tempoPlaybackRate!, 1.1, accuracy: 1e-10)
    }
    func testFreeTimebaseRetainsItemResetEvenWhenMarkerRateReturnsToOne() {
        var song = fixture()
        song.tracks[0].clips[0] = song.resettingItemRate(song.tracks[0].clips[0])
        edit(&song, index: 0, bpm: 120)
        XCTAssertEqual(rates(song), [0.8, 1])
        var settings = song.projectTime; settings.timebase = .free
        song.configureTiming(bpm: song.bpm, beats: 4, unit: 4, settings: settings)
        XCTAssertEqual(rates(song), [0.8, 1])
        edit(&song, index: 0, bpm: 180)
        XCTAssertEqual(rates(song), [0.8, 1])
    }
}
