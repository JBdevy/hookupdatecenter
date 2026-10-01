import XCTest
@testable import JarasApplication
final class ClickTempoTests: XCTestCase {
    func testTempoChangesKeepTheirFirstBeatAndIgnoreDroppedBeats() {
        let first = (0..<12).map { 0.123 + Double($0) * 0.5 }
        let second = (0..<12).filter { $0 != 5 }.map { 6.123 + Double($0) * (2.0 / 3.0) }
        let sections = ClickTempoDetector.sections(onsets: first + second)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].position, 0.123, accuracy: 1e-9)
        XCTAssertEqual(sections[0].bpm, 120)
        XCTAssertEqual(sections[1].position, 6.123, accuracy: 1e-9)
        XCTAssertEqual(sections[1].bpm, 90)
    }
    func testSustainedHalfTempoAndDoubleTempoAreChangesNotMissingClicks() {
        for rates in [[120.0, 60, 120], [90.0, 180, 90], [120.0, 122, 118]] {
            var time = 1.123, onsets: [Double] = [], starts: [Double] = []
            for bpm in rates {
                starts.append(time)
                for _ in 0..<24 { onsets.append(time); time += 60 / bpm }
            }
            let detected = ClickTempoDetector.sections(onsets: onsets)
            XCTAssertEqual(detected.map(\.bpm), rates)
            XCTAssertEqual(detected.count, starts.count)
            for (section, start) in zip(detected, starts) { XCTAssertEqual(section.position, start, accuracy: 1e-9) }
        }
    }
    func testOnlyAnIsolatedMissingPulseDoesNotCreateHalfTempo() {
        let onsets = (0..<40).filter { ![9, 19, 29].contains($0) }.map { 0.125 + Double($0) * 0.5 }
        let detected = ClickTempoDetector.sections(onsets: onsets)
        XCTAssertEqual(detected, [.init(position: 0.125, bpm: 120)])
    }
    private func clicks(_ rates: [Double], beats: [Int]) -> (onsets: [Double], starts: [Double]) {
        var time = 0.123, onsets: [Double] = [], starts: [Double] = []
        for (rate, count) in zip(rates, beats) {
            starts.append(time)
            for _ in 0..<count { onsets.append(time); time += 60/rate }
        }
        return (onsets, starts)
    }
    func testFourStableBarsPerTempoPreserveEveryMarker() {
        for meter in [3,4,6] {
            let rates = [100.0,140,160]
            let input = clicks(rates, beats: [Int](repeating: meter * 4, count: rates.count))
            let result = ClickTempoDetector.sections(onsets: input.onsets, beatsPerBar: meter)
            XCTAssertEqual(result.map(\.bpm), rates)
            for (section, start) in zip(result, input.starts) { XCTAssertEqual(section.position, start, accuracy: 1e-9) }
        }
    }
    func testAnIsolatedShortSectionIsNotContinuousInstability() {
        for middle in [4,8] {
            let rates = [100.0,140,160]
            let input = clicks(rates, beats: [16,middle,16])
            let result = ClickTempoDetector.sections(onsets: input.onsets)
            XCTAssertEqual(result.map(\.bpm), rates)
            for (section, start) in zip(result, input.starts) { XCTAssertEqual(section.position, start, accuracy: 1e-9) }
        }
    }
    func testContinuousTwoBarChangesUseOneGenericMarkerInTheCurrentMeter() {
        for meter in [3,4,6] {
            let rates = [100.0,140,160,110,150]
            let input = clicks(rates, beats: [Int](repeating: meter * 2, count: rates.count))
            XCTAssertEqual(ClickTempoDetector.sections(onsets: input.onsets, beatsPerBar: meter), [.init(position: 0.123, bpm: 120)])
        }
        let input = clicks([119.6,130.6,140.6,150.6], beats: [8,8,8,16])
        XCTAssertEqual(ClickTempoDetector.sections(onsets: input.onsets), [.init(position: 0.123, bpm: 120)], "rounding must not change the two-bar boundary")
    }
    func testLongStableSectionBreaksTheSequenceOfFrequentChanges() {
        let rates = [100.0,140,160,110,150,130]
        let input = clicks(rates, beats: [8,8,16,8,8,16])
        let result = ClickTempoDetector.sections(onsets: input.onsets)
        XCTAssertEqual(result.map(\.bpm), rates)
        for (section, start) in zip(result, input.starts) { XCTAssertEqual(section.position, start, accuracy: 1e-9) }
    }
    func testAttackJitterDoesNotInventTempoOrDelayInitialMarker() {
        let jitter = [0.0048, 0.0017, 0.0004, 0.005, -0.0005, 0.003, 0.0002, 0.0]
        let onsets = (0..<600).map { 1.3 + Double($0)*0.4 + jitter[$0 % jitter.count] }
        XCTAssertEqual(ClickTempoDetector.sections(onsets: onsets), [.init(position: onsets[0], bpm: 150)])
        let first = (0..<80).map { 0.123 + Double($0)*0.5 + jitter[$0 % jitter.count] }
        let second = (0..<80).map { 40.123 + Double($0)*60/122 + jitter[$0 % jitter.count] }
        let detected = ClickTempoDetector.sections(onsets: first + second)
        XCTAssertEqual(detected.map(\.bpm), [120,122])
        XCTAssertEqual(detected.last?.position, second[0])
    }
    func testContinuousDriftFallsBackAndLongFixedClickKeepsOneMarker() {
        var time = 0.123, drifting: [Double] = []
        for i in 0..<80 { drifting.append(time); time += 60 / (100 + Double(i)) }
        XCTAssertEqual(ClickTempoDetector.sections(onsets: drifting), [.init(position: 0.123, bpm: 120)])
        let fixed: [Double] = (0..<20000).map { index in
            let jitter: Double = index % 2 == 0 ? 0.001 : -0.001
            return 0.123 + Double(index)*0.5 + jitter
        }
        XCTAssertEqual(ClickTempoDetector.sections(onsets: fixed), [.init(position: fixed[0], bpm: 120)])
    }
    func testGenericTempoForRapidChangesHasFourFourMeter() throws {
        var song = Project.empty(name: "Variable").songs[0]
        song.beatsPerBar = 6
        let region = Part(id: UUID(), name: "Variable", startTime: 10, endTime: 80)
        var track = Track(id: UUID(), name: "Click", role: .click)
        track.clips = [AudioClip(id: UUID(), name: "Click", startTime: 10, duration: 70, audioFile: AudioFile(path: "click.wav"))]
        song.tracks = [track]
        var pulses: [Double] = [], time = 0.123
        for (bpm, count) in [(100.0,12),(140.0,12),(160.0,12),(110.0,24)] {
            for _ in 0..<count { pulses.append(time); time += 60/bpm }
        }
        let result = try ClickTempoDetector.markers(song: song, region: region) { _ in pulses }
        XCTAssertEqual(result.markers.count, 1)
        XCTAssertEqual(result.markers[0].position, 10.123, accuracy: 1e-9)
        XCTAssertEqual(result.markers[0].tempoBPM, 120)
        XCTAssertEqual(result.markers[0].tempoBeats, 4)
        XCTAssertEqual(result.markers[0].tempoUnit, 4)
    }
    func testMarkerPositionUsesTrimmedRateAdjustedClickOnsets() throws {
        var song = Project.empty(name: "Offset").songs[0]
        let region = Part(id: UUID(), name: "Song", startTime: 10, endTime: 50)
        var track = Track(id: UUID(), name: "CLICK", role: .click)
        track.clips = [AudioClip(id: UUID(), name: "Click", startTime: 12, duration: 30, sourceOffset: 2,
            audioFile: AudioFile(path: "Stems/Click.wav"), playbackRate: 1.25)]
        song.tracks = [track]
        let first = (0..<16).map { 2.125 + Double($0) * 0.5 }
        let second = (0..<16).map { 10.125 + Double($0) * 0.75 }
        let result = try ClickTempoDetector.markers(song: song, region: region) { _ in first + second }
        XCTAssertEqual(result.markers.count, 2)
        XCTAssertEqual(result.markers.map(\.tempoBPM), [150,100])
        XCTAssertEqual(result.markers[0].position, 12.1, accuracy: 1e-9)
        XCTAssertEqual(result.markers[1].position, 18.5, accuracy: 1e-9)
    }
    func testNoiseDoesNotInventTempo() {
        XCTAssertTrue(ClickTempoDetector.sections(onsets: []).isEmpty)
        XCTAssertTrue(ClickTempoDetector.sections(onsets: [0, 0.01, 0.04, 1.8, 1.85, 1.88, 1.9]).isEmpty)
    }
    func testMarkersFollowClickClipPositionAndFallBackOnlyWithoutClickAudio() throws {
        var song = Project.empty(name: "Test").songs[0]
        let region = Part(id: UUID(), name: "Song", startTime: 10, endTime: 30)
        var click = Track(id: UUID(), name: "CLICK", role: .click)
        click.clips = [AudioClip(id: UUID(), name: "Click", startTime: 12, duration: 12,
                                 audioFile: AudioFile(path: "Stems/Click.wav"))]
        song.tracks = [click]
        let onsets = (0..<12).map { 0.125 + Double($0) * 0.5 }
        let detected = try ClickTempoDetector.markers(song: song, region: region) { _ in onsets }
        XCTAssertTrue(detected.hasClickAudio)
        XCTAssertEqual(detected.markers.count, 1)
        XCTAssertEqual(detected.markers[0].position, 12.125, accuracy: 1e-9)
        XCTAssertEqual(detected.markers[0].tempoBPM, 120)

        song.tracks = []
        let fallback = try ClickTempoDetector.markers(song: song, region: region) { _ in
            XCTFail("A file should not be read without a Click clip")
            return []
        }
        XCTAssertFalse(fallback.hasClickAudio)
        XCTAssertEqual(fallback.markers.map(\.position), [10])
        XCTAssertEqual(fallback.markers.first?.tempoBPM, 120)
        XCTAssertEqual(fallback.markers.first?.tempoBeats, 4)
        XCTAssertEqual(fallback.markers.first?.tempoUnit, 4)

        song.tracks = [click]
        let silent = try ClickTempoDetector.markers(song: song, region: region) { _ in [] }
        XCTAssertTrue(silent.hasClickAudio)
        XCTAssertTrue(silent.markers.isEmpty)
    }
    func testDetectedTempoRoundsToWholeBPMWithoutMovingTheFirstPulse() throws {
        for (measured, expected) in [(143.91, 144.0), (143.499, 143.0), (119.501, 120.0)] {
            let onsets = (0..<20).map { 2.123 + Double($0) * 60 / measured }
            let sections = ClickTempoDetector.sections(onsets: onsets)
            XCTAssertEqual(sections.count, 1)
            let section = try XCTUnwrap(sections.first)
            XCTAssertEqual(section.bpm, expected)
            XCTAssertEqual(section.position, 2.123, accuracy: 1e-9)
        }
    }
    func testAccentPatternsEstimateSimpleAndCompoundMeters() {
        for (count, unit) in [(2,4),(3,4),(4,4),(5,4),(6,4),(7,4),(9,4),(12,4)] {
            let pulses = (0..<count*5).map { i in
                ClickTempoDetector.Transient(position: Double(i)*0.4, peak: i % count == 0 ? 0.9 : 0.45)
            }
            let meter = ClickTempoDetector.meter(transients: pulses)
            XCTAssertEqual(meter?.beats, count)
            XCTAssertEqual(meter?.unit, unit)
        }
        let sameVolume = (0..<30).map { i in
            ClickTempoDetector.Transient(position: Double(i)*0.4, peak: 0.8, shape: [i % 6 == 0 ? 1.0 : 0.4, 0.5])
        }
        XCTAssertEqual(ClickTempoDetector.meter(transients: sameVolume)?.beats, 6)
        XCTAssertNil(ClickTempoDetector.meter(transients: (0..<40).map { .init(position: Double($0)*0.5) }))
        XCTAssertNil(ClickTempoDetector.meter(transients: Array(sameVolume.prefix(6))), "one bar is insufficient evidence")
    }
    func testDetectedMeterReferencePreservesAudioAndProjectChoice() throws {
        for mode in [ProjectTimebase.free, .relative] {
            var song = Project.empty(name: "Detected meter").songs[0]
            song.timeSettings?.timebase = mode
            let region = Part(id: UUID(), name: "Song", startTime: 0, endTime: 20)
            var track = Track(id: UUID(), name: "Click", role: .click)
            let clip = AudioClip(id: UUID(), name: "Click", startTime: 0, duration: 20, audioFile: AudioFile(path: "Steams/click.wav"), gain: 0.5, muted: true)
            track.clips = [clip]; song.tracks = [track]; song.parts = [region]
            let before = song
            let detection = try ClickTempoDetector.markersWithMeter(song: song, region: region, transientsFor: { _ in
                (0..<36).map { .init(position: Double($0)*0.4, peak: $0 % 6 == 0 ? 0.9 : 0.45) }
            })
            XCTAssertEqual(song, before, "analysis never changes the live song")
            let marker = try XCTUnwrap(detection.markers.first)
            XCTAssertEqual(marker.tempoBPM, 150)
            XCTAssertEqual(marker.tempoBeats, 6); XCTAssertEqual(marker.tempoUnit, 4)
            XCTAssertEqual(marker.tempoReferenceBPM, 150)
            song.insertDetectedTempo(detection.markers)
            XCTAssertEqual(song.timeSettings, before.timeSettings)
            XCTAssertEqual(song.tracks, before.tracks); XCTAssertEqual(song.parts, before.parts)
            XCTAssertTrue(song.tempoAudioSegments(clip).allSatisfy { $0.audioRate == clip.audioRate })
            song.markers![0].tempoBPM = 300
            XCTAssertEqual(song.tempoAudioSegments(clip).first?.audioRate, mode == .relative ? 2 : 1)
            let saved = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
            XCTAssertEqual(saved.markers?.first?.tempoReferenceBPM, 150)
        }
    }
    func testNewProjectRelativeAndLegacyProjectFree() throws {
        XCTAssertEqual(ProjectTimeSettings().timebase, .relative)
        var song = Project.empty(name: "New").songs[0]
        XCTAssertEqual(song.projectTime.timebase, .relative)
        song.timeSettings = nil
        let restored = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(restored.projectTime.timebase, .free)
    }
    func testSuffixesIncludeAllExistingFilesAndRetainedUndoMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: nested.appendingPathComponent("Click.wav"))
        try Data([1]).write(to: root.appendingPathComponent("click-01.wav"))
        var names = MediaFileNames(directory: root)
        XCTAssertEqual(names.allocate("Click.wav"), "Click-02.wav")
        XCTAssertEqual(names.allocate("Click.wav"), "Click-03.wav")
        XCTAssertEqual(names.allocate("Sanfona.wav", forceSuffix: true), "Sanfona-01.wav")
        XCTAssertEqual(names.allocate("Sanfona.wav", forceSuffix: true), "Sanfona-02.wav")
    }
}
