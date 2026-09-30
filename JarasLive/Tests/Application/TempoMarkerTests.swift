import XCTest
@testable import JarasApplication
final class TempoMarkerTests: XCTestCase {
    func testGridUsesLocalBPMAndMeterUntilNextMarkerAndFreeSnapRemainsExact() {
        var song = Project.empty(name: "Tempo").songs[0]; song.duration = 30
        song.markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 8, color: 0x999999, tempoBPM: 180, tempoBeats: 3, tempoUnit: 8),
                        TimelineMarker(id: UUID(), name: "TEMPO", position: 16, color: 0x999999, tempoBPM: 60, tempoBeats: 4, tempoUnit: 4)]
        XCTAssertEqual(song.tempoSection(at: 7).bpm, 120)
        XCTAssertEqual(song.tempoSection(at: 8).barSeconds, 0.5)
        XCTAssertEqual(song.tempoSection(at: 16).barSeconds, 4)
        XCTAssertEqual(TimelineTempo.snap(8.21, song: song, pixelsPerSecond: 500), 8 + 1.0/3, accuracy: 0.000001)
        XCTAssertEqual(TimelineTempo.snap(8.213, song: song, pixelsPerSecond: 500, enabled: false), 8.213)
        XCTAssertTrue(TimelineNavigationPoints(song: song).points.isEmpty)
    }
    func testAudioSegmentsKeepSourceContinuityGainMuteFXAndStableIdentity() throws {
        var song = Project.empty(name: "Tempo").songs[0]; song.duration = 30
        song.timeSettings = ProjectTimeSettings(); song.timeSettings?.timebase = .relative
        song.markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 8, color: 0x999999, tempoBPM: 180),
                        TimelineMarker(id: UUID(), name: "TEMPO", position: 16, color: 0x999999, tempoBPM: 60)]
        let clip = AudioClip(id: UUID(), name: "Audio", startTime: 4, duration: 20, sourceOffset: 2, gain: 0.5, muted: true)
        let segments = song.tempoAudioSegments(clip)
        XCTAssertEqual(segments.map(\.audioRate), [1,1.5,0.5])
        XCTAssertEqual(segments.map(\.sourceOffset), [2,6,18])
        XCTAssertEqual(segments.map(\.duration), [4,8,8])
        XCTAssertTrue(segments.allSatisfy { $0.gain == clip.gain && $0.muted == clip.muted && $0.fx == clip.fx })
        XCTAssertEqual(segments.first?.id, clip.id)
        XCTAssertEqual(segments.map(\.id), song.tempoAudioSegments(clip).map(\.id))
        XCTAssertEqual(Set(segments.map(\.id)).count, 3)
        let saved = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(saved.markers, song.markers)
    }
    func testFreeGridKeepsWholeSourceAndItemEditsBeforeAcrossAndAfterTempoMarkers() throws {
        var song = Project.empty(name: "Free tempo").songs[0]; song.duration = 30
        song.markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 8, color: 0x999999, tempoBPM: 180, tempoBeats: 3, tempoUnit: 8),
                        TimelineMarker(id: UUID(), name: "TEMPO", position: 16, color: 0x999999, tempoBPM: 60)]
        let clips = [
            AudioClip(id: UUID(), name: "Before", startTime: 2, duration: 3, sourceOffset: 1, gain: 0.5),
            AudioClip(id: UUID(), name: "Across", startTime: 4, duration: 20, sourceOffset: 2, gain: 0.75, muted: true, playbackRate: 1.25, loopStart: 1, loopLength: 4, fx: NativeFXSettings()),
            AudioClip(id: UUID(), name: "After", startTime: 18, duration: 8, sourceOffset: 3, gain: 2)
        ]
        XCTAssertEqual(song.projectTime.timebase, .free)
        XCTAssertEqual(song.tempoSection(at: 9).bpm, 180, "the grid still follows the marker in Free Grid")
        for clip in clips {
            XCTAssertEqual(song.tempoAudioSegments(clip), [clip])
            XCTAssertEqual(song.tempoAudioSegments(clip, sections: song.tempoSections(until: 30)), [clip])
        }
        let saved = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(saved.tempoAudioSegments(clips[1]), [clips[1]])
        song.timeSettings = ProjectTimeSettings(); song.timeSettings?.timebase = .relative
        XCTAssertEqual(song.tempoAudioSegments(clips[1]).count, 3)
        song.timeSettings?.timebase = .free
        XCTAssertEqual(song.tempoAudioSegments(clips[1]), [clips[1]], "returning to Free Grid removes temporary tempo fragments")
    }
    func testMarkerTimebaseOverridesOnlyItsSectionAndGlobalInheritsProject() throws {
        var song = Project.empty(name: "Local timebase").songs[0]; song.duration = 32
        song.markers = [
            TimelineMarker(id: UUID(), name: "TEMPO", position: 8, color: 0x999999, tempoBPM: 180, tempoTimebase: .relative),
            TimelineMarker(id: UUID(), name: "TEMPO", position: 16, color: 0x999999, tempoBPM: 60, tempoTimebase: .free),
            TimelineMarker(id: UUID(), name: "TEMPO", position: 24, color: 0x999999, tempoBPM: 240, tempoTimebase: .global)
        ]
        let clip = AudioClip(id: UUID(), name: "Audio", startTime: 0, duration: 32, sourceOffset: 2)
        XCTAssertEqual(song.tempoSections(until: 32).map(\.timebase), [.free, .relative, .free, .free])
        var segments = song.tempoAudioSegments(clip)
        XCTAssertEqual(segments.map(\.audioRate), [1, 1.5, 1])
        XCTAssertEqual(segments.map(\.sourceOffset), [2, 10, 22])
        XCTAssertEqual(segments.map(\.duration), [8, 8, 16])
        song.timeSettings = ProjectTimeSettings(); song.timeSettings?.timebase = .relative
        XCTAssertEqual(song.tempoSections(until: 32).map(\.timebase), [.relative, .relative, .free, .relative])
        segments = song.tempoAudioSegments(clip)
        XCTAssertEqual(segments.map(\.audioRate), [1, 1.5, 1, 2])
        XCTAssertEqual(segments.map(\.sourceOffset), [2, 10, 22, 30])
        let saved = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(saved.markers?.map(\.tempoTimebase), [.relative, .free, .global])
        XCTAssertEqual(saved.tempoAudioSegments(clip), segments)
        var project = Project.empty(name: "Validation")
        project.songs[0].markers = [TimelineMarker(id: UUID(), name: "Regular", position: 8, color: 0x999999, tempoTimebase: .free)]
        XCTAssertThrowsError(try project.validate(), "ordinary markers cannot carry a tempo timebase")
    }
    func testMissingMarkerTimebaseDefaultsToGlobalAndFollowsProject() {
        var song = Project.empty(name: "Legacy markers").songs[0]; song.duration = 20
        let marker = TimelineMarker(id: UUID(), name: "TEMPO", position: 8, color: 0x999999, tempoBPM: 180)
        XCTAssertEqual(marker.tempoTimebase ?? .global, .global)
        song.markers = [marker]
        XCTAssertEqual(song.tempoSection(at: 9).timebase, .free)
        song.timeSettings = ProjectTimeSettings(); song.timeSettings?.timebase = .relative
        XCTAssertEqual(song.tempoSection(at: 9).timebase, .relative)
    }
}
