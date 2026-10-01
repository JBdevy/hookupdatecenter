import XCTest
@testable import JarasApplication
final class TempoMarkerTests: XCTestCase {
    func testMeasureNumbersFollowTempoSectionsAndKeepTheirOriginalCountWhenZoomedOut() {
        let sections = [TimelineTempoSection(start: 0, end: 6, bpm: 120, beats: 4, unit: 4, timebase: .free),
                        TimelineTempoSection(start: 6, end: 9, bpm: 120, beats: 3, unit: 4, timebase: .free)]
        let bars = TimelineTempo.visibleBars(in: sections, from: 0, to: 9, pixelsPerSecond: 100)
        XCTAssertEqual(bars.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(bars.map(\.time), [0, 2, 4, 6, 7.5])
        let zoomed = TimelineTempo.visibleBars(in: sections, from: 3, to: 9, pixelsPerSecond: 8)
        XCTAssertEqual(zoomed.map(\.number), [3, 4])
        XCTAssertEqual(zoomed.map(\.time), [4, 6])
    }
    func testItemSnapOnlyCapturesNearbyGridButCursorKeepsNearestDivision() {
        let song = resizeSong()
        for scale in [50.0, 100.0, 200.0] {
            let near = 4 + 3 / scale
            let far = 4 + 6 / scale
            XCTAssertEqual(TimelineTempo.snap(near, song: song, pixelsPerSecond: scale, gridTolerancePixels: 4), 4, accuracy: 0.000001)
            XCTAssertEqual(TimelineTempo.snap(far, song: song, pixelsPerSecond: scale, gridTolerancePixels: 4), far, accuracy: 0.000001)
            XCTAssertEqual(TimelineTempo.snap(far, song: song, pixelsPerSecond: scale), 4, accuracy: 0.000001)
            XCTAssertEqual(TimelineTempo.snap(near, song: song, pixelsPerSecond: scale, enabled: false, gridTolerancePixels: 4), near, accuracy: 0.000001)
        }
    }
    private func resizeSong() -> Song {
        var song = Project.empty(name: "Resize").songs[0]
        song.timeSettings = ProjectTimeSettings(); song.duration = 30
        song.parts = [Part(id: UUID(), name: "First", startTime: 2, endTime: 12), Part(id: UUID(), name: "Second", startTime: 17, endTime: 27)]
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "First", startTime: 2, duration: 10, sourceOffset: 1, audioFile: AudioFile(path: "stems/first.wav"), gain: 0.5, muted: true, fx: NativeFXSettings()),
                       AudioClip(id: UUID(), name: "Second", startTime: 17, duration: 10, audioFile: AudioFile(path: "stems/second.wav"))]
        song.tracks = [track]
        song.markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 2, color: 0x999999, tempoBPM: 120, tempoBeats: 4, tempoUnit: 4, tempoTimebase: .global, tempoReferenceBPM: 120),
                        TimelineMarker(id: UUID(), name: "TEMPO", position: 17, color: 0x999999, tempoBPM: 120, tempoBeats: 4, tempoUnit: 4, tempoTimebase: .global, tempoReferenceBPM: 120),
                        TimelineMarker(id: UUID(), name: "Bridge", position: 8, color: 0xff4400)]
        return song
    }
    func testTempoEditResizesCompleteAudioAndRegionsKeepsGapsAndRestoresExactly() throws {
        let original = resizeSong()
        var faster = original; faster.markers![0].tempoBPM = 240
        let warp = TempoEditMap(before: original, after: faster)
        warp.apply(to: &faster)
        XCTAssertEqual(faster.parts.map(\.startTime), [2,12])
        XCTAssertEqual(faster.parts.map(\.endTime), [7,22])
        XCTAssertEqual(faster.parts[1].startTime - faster.parts[0].endTime, 5)
        XCTAssertEqual(faster.tracks[0].clips.map(\.duration), [5,10])
        XCTAssertEqual(faster.markers!.map(\.position), [2,12,5])
        XCTAssertEqual(faster.duration, 25)
        for (old, clip) in zip(original.tracks[0].clips, faster.tracks[0].clips) {
            XCTAssertEqual(faster.tempoAudioSegments(clip).reduce(0) {$0 + $1.duration * $1.audioRate}, 10, accuracy: 1e-10, "the final source sample remains inside the item")
            XCTAssertEqual(clip.id, old.id); XCTAssertEqual(clip.sourceOffset, old.sourceOffset)
            XCTAssertEqual(clip.fx, old.fx); XCTAssertEqual(clip.gain, old.gain); XCTAssertEqual(clip.muted, old.muted)
        }
        var restored = faster; restored.markers![0].tempoBPM = 120
        TempoEditMap(before: faster, after: restored).apply(to: &restored)
        XCTAssertEqual(restored, original)
        var slower = original; slower.markers![0].tempoBPM = 60
        TempoEditMap(before: original, after: slower).apply(to: &slower)
        XCTAssertEqual(slower.parts.map(\.startTime), [2,27])
        XCTAssertEqual(slower.parts.map(\.endTime), [22,37])
        XCTAssertEqual(slower.tracks[0].clips[0].duration, 20)
    }
    func testTempoEditInsideSongKeepsEverySourceSegmentAndFreeGridDoesNotResize() {
        var before = resizeSong()
        before.markers!.append(TimelineMarker(id: UUID(), name: "TEMPO", position: 7, color: 0x999999, tempoBPM: 120, tempoTimebase: .global, tempoReferenceBPM: 120))
        var after = before; after.markers![3].tempoBPM = 240
        TempoEditMap(before: before, after: after).apply(to: &after)
        XCTAssertEqual(after.parts[0].endTime, 9.5)
        XCTAssertEqual(after.parts[1].startTime, 14.5)
        let pieces = after.tempoAudioSegments(after.tracks[0].clips[0])
        XCTAssertEqual(pieces.map(\.duration), [5,2.5])
        XCTAssertEqual(pieces.map(\.sourceOffset), [1,6])
        XCTAssertEqual(pieces.last!.sourceOffset + pieces.last!.duration * pieces.last!.audioRate, 11)
        before.timeSettings = .legacy
        after = before; after.markers![3].tempoBPM = 240
        let unchanged = after
        let map = TempoEditMap(before: before, after: after); map.apply(to: &after)
        XCTAssertFalse(map.changesTime); XCTAssertEqual(after, unchanged)
    }
    func testUnifiedSongTailIgnoresNextSongsTempoAndResize() {
        var song = resizeSong()
        let group = UUID()
        song.parts[0].startTime = 0; song.parts[0].endTime = 12; song.parts[0].parentRegionID = group
        song.parts[1].startTime = 10; song.parts[1].endTime = 20; song.parts[1].parentRegionID = group
        song.parts.append(Part(id: group, name: "Special", startTime: 0, endTime: 20))
        song.tracks[0].clips[0].startTime = 0; song.tracks[0].clips[0].duration = 12
        song.tracks[0].clips[1].startTime = 10; song.tracks[0].clips[1].duration = 10
        song.markers![0].position = 0; song.markers![1].position = 10
        var faster = song; faster.markers![1].tempoBPM = 240
        TempoEditMap(before: song, after: faster).apply(to: &faster)
        XCTAssertEqual(faster.tracks[0].clips[0].duration, 12)
        XCTAssertEqual(faster.parts[0].endTime, 12)
        XCTAssertEqual(faster.tracks[0].clips[1].duration, 5)
        XCTAssertEqual(faster.parts[1].endTime, 15)
        XCTAssertEqual(faster.parts[2].endTime, 15)
        let tail = faster.tempoAudioSegments(faster.tracks[0].clips[0])
        XCTAssertEqual(tail.count, 1); XCTAssertEqual(tail[0].audioRate, 1); XCTAssertEqual(tail[0].duration, 12)
        XCTAssertEqual(faster.tempoAudioSegments(faster.tracks[0].clips[1])[0].audioRate, 2)
        var restored = faster; restored.markers![1].tempoBPM = 120
        TempoEditMap(before: faster, after: restored).apply(to: &restored)
        XCTAssertEqual(restored, song)
        // Changing the first song still stretches its entire tail across the next song.
        faster = song; faster.markers![0].tempoBPM = 240
        TempoEditMap(before: song, after: faster).apply(to: &faster)
        XCTAssertEqual(faster.tracks[0].clips[0].duration, 6)
        XCTAssertEqual(faster.tracks[0].clips[1].startTime, 5)
        XCTAssertEqual(faster.tracks[0].clips[1].duration, 10)
        XCTAssertEqual(faster.tempoAudioSegments(faster.tracks[0].clips[0]).map(\.audioRate), [2])
    }
    func testCutPiecesBelongToSongWhoseMarkerPrecedesTheirCurrentStart() {
        var song = resizeSong()
        let group = UUID()
        song.parts[0].startTime = 0; song.parts[0].endTime = 8; song.parts[0].parentRegionID = group
        song.parts[1].startTime = 10; song.parts[1].endTime = 20; song.parts[1].parentRegionID = group
        song.parts.append(Part(id: group, name: "Special", startTime: 0, endTime: 20))
        song.markers![0].position = 0; song.markers![0].tempoBPM = 150
        song.markers![1].position = 10; song.markers![1].tempoBPM = 240
        var cut = song.tracks[0].clips[0]
        cut.startTime = 9; cut.duration = 5; cut.sourceOffset = 7
        XCTAssertEqual(song.tempoOwner(at: cut.startTime)?.id, song.parts[0].id)
        let first = song.tempoAudioSegments(cut)
        XCTAssertEqual(first.map(\.audioRate), [1.25])
        XCTAssertEqual(first[0].sourceOffset, 7)
        cut.startTime = 10
        XCTAssertEqual(song.tempoOwner(at: cut.startTime)?.id, song.parts[1].id)
        XCTAssertEqual(song.tempoAudioSegments(cut).map(\.audioRate), [2])
        cut.startTime = 11
        XCTAssertEqual(song.tempoAudioSegments(cut).map(\.audioRate), [2])
    }
    func testMarkerDragSnapsNormalMarkersAndProtectsRegionsFromTempoMarkers() {
        var song = Project.empty(name: "Drag").songs[0]
        song.parts = [Part(id: UUID(), name: "Song", startTime: 10, endTime: 20)]
        let normal = TimelineMarker(id: UUID(), name: "Manual", position: 4, color: 0)
        XCTAssertEqual(song.markerDragPosition(normal, to: 4.23, pixelsPerSecond: 100, free: false), 4)
        XCTAssertEqual(song.markerDragPosition(normal, to: 4.23, pixelsPerSecond: 100, free: true), 4.23)
        var tempo = TimelineMarker(id: UUID(), name: "Tempo", position: 5, color: 0, tempoBPM: 120)
        XCTAssertEqual(song.markerDragPosition(tempo, to: 6.231, pixelsPerSecond: 100, free: false), 6.231)
        XCTAssertLessThan(song.markerDragPosition(tempo, to: 15, pixelsPerSecond: 100, free: true), 10)
        tempo.position = 25
        XCTAssertEqual(song.markerDragPosition(tempo, to: 15, pixelsPerSecond: 100, free: false), 20)
        tempo.position = 10
        XCTAssertFalse(song.canDragMarker(tempo))
        XCTAssertEqual(song.markerDragPosition(tempo, to: 30, pixelsPerSecond: 100, free: true), 10)
        var child = normal; child.sourceRegionID = song.parts[0].id
        XCTAssertFalse(song.canDragMarker(child))
    }
    func testAdvancedTimingPreferencesAreGlobalAcrossProjects() throws {
        let suite = "jaras-timing-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var settings = ProjectTimeSettings(); settings.divisions = 0; settings.timebase = .free
        let global = GlobalProjectTiming(bpm: 140, beats: 7, unit: 4, settings: settings)
        global.save(preferences: preferences)
        let loaded = try XCTUnwrap(GlobalProjectTiming.load(preferences: preferences))
        XCTAssertEqual(loaded, global)
        for name in ["First", "Second"] {
            var project = Project.empty(name: name)
            loaded.apply(to: &project)
            XCTAssertEqual(project.songs[0].bpm, 140)
            XCTAssertEqual(project.songs[0].meterBeats, 7)
            XCTAssertEqual(project.songs[0].projectTime, settings)
        }
    }
    func testInitialTempoMarkerFillsLeadInWithoutDuplicatingAnExistingOrigin() {
        var song = Project.empty(name: "Lead in").songs[0]
        let marker = TimelineMarker(id: UUID(), name: "TEMPO", position: 12, color: 0x999999, tempoBPM: 150, tempoBeats: 7, tempoUnit: 4)
        song.markers = [marker]
        song.ensureInitialTempoMarker()
        XCTAssertEqual(song.markers?.first?.position, 0)
        XCTAssertEqual(song.markers?.first?.tempoBPM, 120)
        XCTAssertEqual(song.markers?.first?.tempoBeats, 4)
        XCTAssertEqual(song.markers?.first?.tempoUnit, 4)
        let once = song.markers
        song.ensureInitialTempoMarker()
        XCTAssertEqual(song.markers, once)
        XCTAssertEqual(song.activeTempoMarker(at: 12), marker)
    }
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
        var song = Project.empty(name: "Free tempo").songs[0]; song.timeSettings = .legacy; song.duration = 30
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
        var song = Project.empty(name: "Local timebase").songs[0]; song.timeSettings = .legacy; song.duration = 32
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
        var song = Project.empty(name: "Legacy markers").songs[0]; song.timeSettings = .legacy; song.duration = 20
        let marker = TimelineMarker(id: UUID(), name: "TEMPO", position: 8, color: 0x999999, tempoBPM: 180)
        XCTAssertEqual(marker.tempoTimebase ?? .global, .global)
        song.markers = [marker]
        XCTAssertEqual(song.tempoSection(at: 9).timebase, .free)
        song.timeSettings = ProjectTimeSettings(); song.timeSettings?.timebase = .relative
        XCTAssertEqual(song.tempoSection(at: 9).timebase, .relative)
    }
}
