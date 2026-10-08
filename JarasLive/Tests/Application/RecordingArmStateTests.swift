import XCTest
@testable import JarasApplication

final class RecordingArmStateTests: XCTestCase {
    func testAutomaticSelectionHandoffPreservesManuallyArmedTracks() {
        let first = UUID(), second = UUID(), manual = UUID()
        var state = RecordingArmState()
        XCTAssertFalse(state.hasConfiguredTracks)
        state.set(.automatic, tracks: [first, second])
        XCTAssertTrue(state.hasConfiguredTracks, "Deselected automatic REC still needs arming reconciliation")
        XCTAssertTrue(state.armed.isEmpty)
        state.set(.manual, tracks: [manual])
        XCTAssertEqual(state.armed, [manual])
        state.select([first])
        XCTAssertEqual(state.armed, [first, manual])
        state.select([second])
        XCTAssertEqual(state.armed, [second, manual])
        state.select([first, second])
        XCTAssertEqual(state.armed, [first, second, manual])
        state.select([])
        XCTAssertEqual(state.armed, [manual])
        XCTAssertEqual(state.mode(for: first), .automatic)
    }
    func testCycleAndDeletionNeverRearmAnOffOrRemovedTrack() {
        let track = UUID()
        var state = RecordingArmState()
        state.select([track])
        for mode in [RecordingArmState.Mode.manual, .automatic, .off] {
            state.set(state.mode(for: track).next, tracks: [track])
            XCTAssertEqual(state.mode(for: track), mode)
            XCTAssertEqual(state.armed.contains(track), mode != .off)
        }
        state.select([]); state.select([track])
        XCTAssertTrue(state.armed.isEmpty)
        XCTAssertFalse(state.hasConfiguredTracks)
        state.set(.automatic, tracks: [track]); state.retain([])
        state.select([track])
        XCTAssertTrue(state.armed.isEmpty)
        XCTAssertEqual(state.mode(for: track), .off)
        XCTAssertFalse(state.hasConfiguredTracks)
    }
    func testTrackSelectionActionCanMapKeyboardAndMIDIIndependently() throws {
        var bindings = DAWActionBindings()
        let key = ControlInput(kind: "keyboard", label: "F8", key: 100, modifiers: 0)
        let midi = ControlInput(kind: "midi", label: "CC42", device: 2, channel: 0, status: 0xb0, number: 42)
        XCTAssertTrue(DAWAction.visible.contains(.selectTrack))
        XCTAssertTrue(bindings.setInput(key, action: .selectTrack, kind: "keyboard"))
        XCTAssertTrue(bindings.setInput(midi, action: .selectTrack, kind: "midi"))
        bindings.setTrack(3, action: .selectTrack)
        let restored = DAWActionBindings(stored: try JSONDecoder().decode([DAWActionBinding].self, from: JSONEncoder().encode(bindings.entries)))
        XCTAssertEqual(restored.matching(key), .selectTrack)
        XCTAssertEqual(restored.matching(midi), .selectTrack)
        XCTAssertEqual(restored.binding(.selectTrack).trackNumber, 3)
    }
}
