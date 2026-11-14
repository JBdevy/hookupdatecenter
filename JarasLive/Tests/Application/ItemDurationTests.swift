import XCTest
@testable import JarasApplication

final class ItemDurationTests: XCTestCase {
    func testTimecodeSourceClockFollowsTempoWithContinuousAddressesAndKeepsFPS() {
        var song = Project.empty(name: "Timecode clock").songs[0]; song.bpm = 120; song.duration = 20
        song.markers = [.init(id: UUID(), name: "Tempo", position: 5, color: 0, tempoBPM: 180, tempoTimebase: .relative, tempoReferenceBPM: 120)]
        let clip = AudioClip(id: UUID(), name: "LTC", startTime: 2, duration: 10, playbackRate: 1.25)
        let fragments = song.timecodePlaybackSegments(clip, origin: 0)
        XCTAssertEqual(fragments.map(\.audioRate), [1.25, 1.875])
        XCTAssertEqual(fragments.map(\.sourceOffset), [2.5, 6.25])
        let track = Track(id: UUID(), name: "Timecode", role: TrackRole(rawValue: "timecode"))
        XCTAssertTrue(clip.supportsRate(on: track))
        XCTAssertEqual(song.item(clip, withRate: 2).duration, 6.625)
    }
    func testMIDIRatePreservesNotesAndSourceSpanAndChangesPlaybackTiming() {
        var song = Project.empty(name: "MIDI rate").songs[0]
        song.bpm = 120; song.duration = 20
        let notes = [MIDINote(start: 2, length: 2, pitch: 60), MIDINote(start: 6, length: 2, pitch: 64)]
        let clip = AudioClip(id: UUID(), name: "MIDI", startTime: 3, duration: 4, midi: MIDIItem(notes: notes))
        let faster = song.item(clip, withRate: 2)
        XCTAssertEqual(faster.duration, 2)
        XCTAssertEqual(faster.midi, clip.midi, "Changing rate must preserve editable MIDI source notes")
        XCTAssertEqual(song.midiPlaybackNotes(in: faster).map(\.start), [3.5, 4.5])
        XCTAssertEqual(song.midiPlaybackNotes(in: faster).map(\.end), [4, 5])
        XCTAssertEqual(song.item(faster, withRate: 1).duration, 4)
    }
    func testGeneratedClickRateKeepsBeatCountAcrossFreeTempoChanges() {
        var song = Project.empty(name: "Click rate").songs[0]
        song.bpm = 120; song.duration = 20
        song.markers = [.init(id: UUID(), name: "Faster", position: 5, color: 0, tempoBPM: 240, tempoTimebase: .free)]
        let track = Track(id: UUID(), name: "Click", role: TrackRole(rawValue: "generatedClick"))
        let clip = AudioClip(id: UUID(), name: "Click", startTime: 0, duration: 10)
        let faster = song.item(clip, withRate: 2, on: track)
        XCTAssertEqual(faster.duration, 6.25)
        XCTAssertEqual(song.item(faster, withRate: 1, on: track).duration, 10)
        XCTAssertNil(faster.audioFile)
    }

    func testRateTextPreservesImportedPrecisionAndStepsDoNotRoundItToTwoDecimals() {
        let precise = 1.1234567890123456
        var value = ItemRateSettings(baseBPM: 146, rate: precise)
        XCTAssertEqual(Double(value.rateText)?.bitPattern, precise.bitPattern)
        value.stepRate(1); XCTAssertEqual(value.rate, precise + 0.01)
        value.stepRate(-1); XCTAssertEqual(value.rate.bitPattern, precise.bitPattern)
        value.reset(); XCTAssertEqual(value.rateText, "1.000000")
        for _ in 0..<20 { value.stepRate(1) }
        XCTAssertEqual(value.rateText, "1.200000")
        for _ in 0..<20 { value.stepRate(-1) }
        XCTAssertEqual(value.rateText, "1.000000")
    }
    func testRateAndSignedBPMControlsStayLinkedAndResetToOne() {
        var value = ItemRateSettings(baseBPM: 120)
        value.stepRate(-1); XCTAssertEqual(value.rate, 0.99); XCTAssertEqual(value.bpmOffset, -1.2, accuracy: 1e-9)
        value.reset(); value.stepRate(1); XCTAssertEqual(value.rate, 1.01)
        value.reset(); value.stepBPM(-1); XCTAssertEqual(value.bpmOffset, -1, accuracy: 1e-9)
        value.bpmOffset = 24; XCTAssertEqual(value.rate, 1.2)
        value.bpmOffset = -12; XCTAssertEqual(value.rate, 0.9)
        value.reset(); XCTAssertEqual(value.rate, 1); XCTAssertEqual(value.bpmOffset, 0)
        value.bpmOffset = -120; XCTAssertFalse(value.isValid)
    }
    func testRateChangePreservesSourceSpanAcrossTempoChangesAndKeepsTrimAndLoops() {
        var song = Project.empty(name: "Rate duration").songs[0]
        song.bpm = 120; song.timeSettings = ProjectTimeSettings(); song.timeSettings?.timebase = .relative
        song.markers = [.init(id: UUID(), name: "Faster", position: 5, color: 0, tempoBPM: 240, tempoTimebase: .relative, tempoReferenceBPM: 120)]
        let original = AudioClip(id: UUID(), name: "Source", startTime: 0, duration: 10, sourceOffset: 3,
                                 gain: 0.4, loopStart: 0, loopLength: 8)
        let faster = song.item(original, withRate: 2)
        XCTAssertEqual(faster.duration, 6.25, accuracy: 1e-9)
        XCTAssertEqual(song.tempoAudioSegments(faster).reduce(0) { $0 + $1.duration * $1.audioRate }, 15, accuracy: 1e-9)
        let slower = song.item(original, withRate: 0.5)
        XCTAssertEqual(slower.duration, 17.5, accuracy: 1e-9)
        XCTAssertEqual(faster.sourceOffset, 3); XCTAssertEqual(faster.loopLength, 8); XCTAssertEqual(faster.gain, 0.4)
        XCTAssertEqual(song.item(faster, withRate: 1).duration, original.duration, accuracy: 1e-9)
        var video = original; video.audioFile = AudioFile(path: "Videos/source.mp4")
        XCTAssertEqual(song.item(video, withRate: 2).duration, 5, "Projection playback uses its own constant source rate")
        XCTAssertEqual(song.restoringItemDuration(video, sourceDuration: 20).duration, 20)
    }
    func testFullSourceRestorationPreservesPositionRateMixAndTakeAutomation() {
        let song = Project.empty(name: "Duration").songs[0]
        var clip = AudioClip(id: UUID(), name: "Trimmed", startTime: 10, duration: 2, sourceOffset: 3, gain: 0.4, pan: -0.2, playbackRate: 2, loopStart: 1, loopLength: 4)
        clip.automation = TrackAutomation()
        let restored = song.restoringItemDuration(clip, sourceDuration: 20)
        XCTAssertEqual(restored.startTime, 10); XCTAssertEqual(restored.duration, 10)
        XCTAssertEqual(restored.sourceOffset, 0); XCTAssertNil(restored.loopLength)
        XCTAssertEqual(restored.audioRate, 2); XCTAssertEqual(restored.gain, 0.4); XCTAssertEqual(restored.pan, -0.2)
        XCTAssertEqual(restored.automation, clip.automation)
    }
    func testRestorationIntegratesLaterTempoMarkersAndPrintedSourcesBypassThem() {
        var song = Project.empty(name: "Tempo duration").songs[0]
        song.bpm = 120; song.timeSettings = ProjectTimeSettings(); song.timeSettings?.timebase = .relative
        song.markers = [.init(id: UUID(), name: "Tempo", position: 5, color: 0, tempoBPM: 240, tempoTimebase: .relative, tempoReferenceBPM: 120)]
        var clip = AudioClip(id: UUID(), name: "Trimmed", startTime: 3, duration: 1, sourceOffset: 8)
        let restored = song.restoringItemDuration(clip, sourceDuration: 10)
        XCTAssertEqual(restored.duration, 6)
        XCTAssertEqual(song.tempoAudioSegments(restored).reduce(0) { $0 + $1.duration * $1.audioRate }, 10, accuracy: 1e-9)
        clip.renderedTempo = true
        XCTAssertEqual(song.restoringItemDuration(clip, sourceDuration: 10).duration, 10)
        XCTAssertEqual(song.restoringItemDuration(clip, sourceDuration: .nan), clip)
    }
}
