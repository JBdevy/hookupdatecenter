import XCTest
@testable import JarasApplication

final class DAWActionTests: XCTestCase {
    func testIgnoreNextDefaultZeroKeyAndMIDIMappingAreEditable() {
        var bindings = DAWActionBindings()
        XCTAssertEqual(bindings.matching(ControlInput(kind: "keyboard", label: "0", key: 29, modifiers: 0)), .ignoreNext)
        XCTAssertEqual(bindings.matching(ControlInput(kind: "keyboard", label: "0", key: 82, modifiers: 0)), .ignoreNext)
        let midi = ControlInput(kind: "midi", label: "CC 20", device: 3, channel: 0, status: 0xb0, number: 20)
        bindings.setInput(midi, action: .ignoreNext, kind: "midi")
        XCTAssertEqual(bindings.matching(midi), .ignoreNext)
        bindings.setInput(ControlInput(kind: "keyboard", label: "I", key: 34, modifiers: 0), action: .ignoreNext, kind: "keyboard")
        XCTAssertNil(bindings.matching(ControlInput(kind: "keyboard", label: "0", key: 29, modifiers: 0)))
        XCTAssertNil(bindings.matching(ControlInput(kind: "keyboard", label: "0", key: 82, modifiers: 0)))
    }

    func testDefaultsAndRemappingRemoveOldAliases() {
        var bindings = DAWActionBindings()
        XCTAssertNil(bindings.binding(.tapTempo).keyboard)
        XCTAssertNil(bindings.binding(.pause).keyboard)
        XCTAssertEqual(bindings.matching(ControlInput(kind: "keyboard", label: "", key: 1, modifiers: 0)), .splitItems)
        let cmdT = ControlInput(kind: "keyboard", label: "", key: 17, modifiers: 1 << 20)
        let ctrlT = ControlInput(kind: "keyboard", label: "", key: 17, modifiers: 1 << 18)
        XCTAssertEqual(bindings.matching(cmdT), .addTrack)
        XCTAssertEqual(bindings.matching(ctrlT), .addTrack)
        XCTAssertEqual(bindings.matching(ControlInput(kind: "keyboard", label: "", key: 49, modifiers: 0)), .playStop)
        let replacement = ControlInput(kind: "keyboard", label: "F", key: 3, modifiers: 0)
        bindings.setInput(replacement, action: .addTrack, kind: "keyboard")
        XCTAssertNil(bindings.matching(cmdT)); XCTAssertNil(bindings.matching(ctrlT))
        XCTAssertEqual(bindings.matching(replacement), .addTrack)
        XCTAssertEqual(bindings.conflict(replacement, excluding: .pause), .addTrack)
        bindings.reset(.addTrack)
        XCTAssertEqual(bindings.matching(cmdT), .addTrack)
    }
    func testNavigationKeysCannotBeRemovedOrRemappedAndFadersAreMIDIOnly() {
        var bindings = DAWActionBindings()
        let replacement = ControlInput(kind: "keyboard", label: "Q", key: 12, modifiers: 0)
        for action in [DAWAction.setlistUp, .setlistDown] {
            bindings.setInput(nil, action: action, kind: "keyboard")
            bindings.setInput(replacement, action: action, kind: "keyboard")
            XCTAssertEqual(bindings.binding(action).keyboard, action.defaultKeyboard)
        }
        for action in [DAWAction.volumeTrack, .panTrack] {
            bindings.setInput(replacement, action: action, kind: "keyboard")
            XCTAssertNil(bindings.binding(action).keyboard)
        }
        var corrupted = bindings.entries
        for index in corrupted.indices { corrupted[index].keyboard = replacement }
        let restored = DAWActionBindings(stored: corrupted)
        XCTAssertEqual(restored.binding(.setlistUp).keyboard, DAWAction.setlistUp.defaultKeyboard)
        XCTAssertNil(restored.binding(.panTrack).keyboard)
    }
    func testMIDIControlsPersistWithTrackTargetsAndAreIsolatedByDeviceChannelAndController() throws {
        var bindings = DAWActionBindings()
        let cc = ControlInput(kind: "midi", label: "Keyboard CH1 CC7", device: 27, channel: 0, status: 0xb0, number: 7)
        bindings.setInput(cc, action: .volumeTrack, kind: "midi")
        bindings.setTrack(401, action: .volumeTrack)
        XCTAssertEqual(bindings.binding(.volumeTrack).trackNumber, 400)
        bindings.setTrack(0, action: .selectTrack)
        XCTAssertEqual(bindings.binding(.selectTrack).trackNumber, 1)
        bindings.setInput(ControlInput(kind: "midi", label: "Auto", device: 27, channel: 0, status: 0x90, number: 60), action: .toggleAuto, kind: "midi")
        let decoded = try JSONDecoder().decode([DAWActionBinding].self, from: JSONEncoder().encode(bindings.entries))
        XCTAssertEqual(DAWActionBindings(stored: decoded), bindings)
        XCTAssertEqual(bindings.matching(cc), .volumeTrack)
        for (device, channel, number) in [(28, UInt8(0), UInt8(7)), (27, 1, 7), (27, 0, 8)] {
            XCTAssertNil(bindings.matching(ControlInput(kind: "midi", label: "", device: Int32(device), channel: channel, status: 0xb0, number: number)))
        }
        XCTAssertEqual(DAWActionValue.pan(0), -1)
        XCTAssertEqual(DAWActionValue.pan(64), 0)
        XCTAssertEqual(DAWActionValue.pan(127), 1)
    }
}
