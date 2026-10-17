import XCTest
@testable import JarasApplication

final class ItemFadeTests: XCTestCase {
    func testBothCurveControlsStayMonotoneAndBoundedWithExactEndpoints() {
        for c in stride(from: -1.0, through: 1.0, by: 0.2) {
            for s in stride(from: -1.0, through: 1.0, by: 0.2) {
                let curve = ItemFadeCurve(curvature: c, sCurve: s)
                XCTAssertEqual(curve.value(at: -1), 0); XCTAssertEqual(curve.value(at: 2), 1)
                var previous = 0.0
                for step in 0...200 {
                    let value = curve.value(at: Double(step) / 200)
                    XCTAssertGreaterThanOrEqual(value, previous); XCTAssertLessThanOrEqual(value, 1)
                    previous = value
                }
                for level in [0.25, 0.75] { XCTAssertEqual(curve.value(at: curve.position(at: level)), level, accuracy: 0.000002) }
            }
        }
    }
    func testLegacyCurveAndPersistence() throws {
        let original = AudioClip(id: UUID(), name: "Item", startTime: 10, duration: 8, fadeIn: 4, fadeOut: 2)
        XCTAssertEqual(original.fadeGain(at: 11), 0.15625)
        XCTAssertEqual(original.fadeGain(at: 17.5), 0.15625)
        var shaped = original
        shaped.fadeInCurve = 0.7; shaped.fadeInSCurve = -0.4; shaped.fadeOutCurve = -0.3; shaped.fadeOutSCurve = 0.6
        let restored = try JSONDecoder().decode(AudioClip.self, from: JSONEncoder().encode(shaped))
        XCTAssertEqual(shaped, restored)
        XCTAssertNotEqual(shaped.fadeGain(at: 11), original.fadeGain(at: 11))
        var segment = shaped; segment.startTime = 12; segment.duration = 2; segment.fadeTimelineStart = 10; segment.fadeTimelineDuration = 8
        XCTAssertEqual(segment.fadeGain(at: 12.5), shaped.fadeGain(at: 12.5))
    }
    func testMIDIFadesVelocityWithoutChangingNotesAndDoesNotRestartAtTempoMarkers() {
        var song = Project.empty(name: "MIDI").songs[0]
        let notes = (0..<8).map { MIDINote(start: Double($0), length: 1, pitch: 60 + $0, velocity: 100) }
        let clip = AudioClip(id: UUID(), name: "MIDI", startTime: 0, duration: 8, fadeIn: 4, fadeOut: 4, midi: MIDIItem(notes: notes, sourceBPM: 60))
        XCTAssertEqual(clip.midiPlaybackNotes().map(\.velocity), [16, 50, 84, 100, 84, 50, 16])
        XCTAssertEqual(clip.midiDisplayNotes().count, 8)
        XCTAssertEqual(clip.midi?.notes, notes)
        song.timeSettings = ProjectTimeSettings(); song.timeSettings?.timebase = .relative
        song.markers = [TimelineMarker(id: UUID(), name: "Tempo", position: 2, color: 0, tempoBPM: 240)]
        let held = AudioClip(id: UUID(), name: "Held", startTime: 0, duration: 4, fadeIn: 4, midi: MIDIItem(notes: [MIDINote(start: 0, length: 12, pitch: 60)]))
        XCTAssertTrue(song.midiPlaybackNotes(in: held).isEmpty, "A note suppressed at its onset must not restart at a later tempo boundary")
    }
}
