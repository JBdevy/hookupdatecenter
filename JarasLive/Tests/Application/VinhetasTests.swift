import XCTest
@testable import JarasApplication
final class VinhetasTests: XCTestCase {
    func testPadMappingFooterAndRemovalPersistAcrossPresets() throws {
        var library = VinhetasLibrary()
        let cc = ControlInput(kind: "midi", label: "CC", channel: 0, status: 0xb0, number: 20)
        let note = ControlInput(kind: "midi", label: "Note", channel: 0, status: 0x90, number: 60)
        library.padMappings[0] = cc; library.padMappings[1] = note
        XCTAssertEqual(library.padMappingLabel(0), "CC 20")
        XCTAssertEqual(library.padMappingLabel(1), "Note 60")
        XCTAssertEqual(library.padMappingLabel(2), "")
        library.select(4)
        XCTAssertEqual(library.padMappingLabel(0), "CC 20")
        library.padMappings[0] = nil
        let restored = try JSONDecoder().decode(VinhetasLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(restored.padMappingLabel(0), "")
        XCTAssertFalse(restored.handles(cc)); XCTAssertTrue(restored.handles(note))
        XCTAssertEqual(restored.presets, library.presets)
    }

    func testMappingFollowsPresetAndNoteReleaseKeepsOriginalVoice() throws {
        var library = VinhetasLibrary(), triggers = VinhetasTriggers()
        let note = ControlInput(kind: "midi", label: "Note", device: 1, channel: 0, status: 0x90, number: 60)
        library.padMappings[0] = note
        library.presets[0].pads[0].audioFile = "one.wav"
        library.presets[1].pads[0].audioFile = "two.wav"
        guard case .start(let first) = triggers.midi(input: note, value: 100, library: library).first else { return XCTFail() }
        library.select(1)
        XCTAssertEqual(triggers.midi(input: note, value: 0, library: library), [.stop(first.id)])
        guard case .start(let second) = triggers.midi(input: note, value: 100, library: library).first else { return XCTFail() }
        XCTAssertEqual(second.preset, 1); XCTAssertEqual(second.pad, 0)
        XCTAssertEqual(library.padMappings.count, 16)
        var decoded = try JSONDecoder().decode(VinhetasLibrary.self, from: JSONEncoder().encode(library))
        try decoded.validate(); XCTAssertEqual(decoded, library)
    }
    func testMouseRetriggersOverlapAndGateStopsOnlyHeldVoice() {
        var library = VinhetasLibrary(), triggers = VinhetasTriggers()
        library.presets[0].pads[0].audioFile = "one.wav"
        let a = triggers.mouseDown(pad: 0, library: library)
        XCTAssertTrue(triggers.mouseUp(pad: 0).isEmpty)
        XCTAssertNotEqual(a, triggers.mouseDown(pad: 0, library: library))
        library.presets[0].pads[0].gate = true
        guard case .start(let held) = triggers.mouseDown(pad: 0, library: library).first else { return XCTFail() }
        library.select(1)
        XCTAssertEqual(triggers.mouseUp(pad: 0), [.stop(held.id)])
    }
    func testCCDoesNotRepeatWhileHeldAndIgnoresMouseGate() {
        var library = VinhetasLibrary(), triggers = VinhetasTriggers()
        let cc = ControlInput(kind: "midi", label: "CC", device: 1, channel: 0, status: 0xb0, number: 20)
        library.padMappings[0] = cc; library.presets[0].pads[0].gate = true
        library.presets[0].pads[0].audioFile = "one.mp3"
        XCTAssertEqual(triggers.midi(input: cc, value: 127, library: library).count, 1)
        XCTAssertTrue(triggers.midi(input: cc, value: 64, library: library).isEmpty)
        XCTAssertTrue(triggers.midi(input: cc, value: 0, library: library).isEmpty)
        XCTAssertEqual(triggers.midi(input: cc, value: 127, library: library).count, 1)
    }
    func testGlobalChannelFiltersPadsAndPresetsWithoutRelearning() throws {
        var library = VinhetasLibrary(), triggers = VinhetasTriggers()
        let note = ControlInput(kind: "midi", label: "Note", device: 1, channel: 0, status: 0x90, number: 60)
        library.padMappings[0] = note; library.presets[0].pads[0].audioFile = "one.wav"
        var other = note; other.channel = 9
        XCTAssertTrue(library.handles(other)) // Omni.
        library.midiChannel = 10
        XCTAssertFalse(library.handles(note)); XCTAssertTrue(library.handles(other))
        XCTAssertTrue(triggers.midi(input: note, value: 100, library: library).isEmpty)
        guard case .start(let voice) = triggers.midi(input: other, value: 100, library: library).first else { return XCTFail() }
        library.midiChannel = 2
        XCTAssertEqual(triggers.midi(input: other, value: 0, library: library), [.stop(voice.id)])
        library.presetMappings[1] = note
        var channelTwo = note; channelTwo.channel = 1
        XCTAssertEqual(triggers.midi(input: channelTwo, value: 100, library: library), [.select(1)])
        let encoded = try JSONEncoder().encode(library)
        XCTAssertEqual(try JSONDecoder().decode(VinhetasLibrary.self, from: encoded).midiChannel, 2)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "midiChannel")
        XCTAssertNil(try JSONDecoder().decode(VinhetasLibrary.self, from: JSONSerialization.data(withJSONObject: legacy)).midiChannel)
    }

    func testRemoteGateRetainsVoiceAcrossPresetsAndNeverStopsMouseVoice() {
        var library = VinhetasLibrary(), triggers = VinhetasTriggers()
        library.presets[0].pads[0].audioFile = "one.wav"
        library.presets[0].pads[0].gate = true
        let remoteID = UUID()
        guard case .start(let remote) = triggers.remoteDown(id: remoteID, preset: 0, pad: 0, library: library).first else { return XCTFail() }
        XCTAssertEqual(remote.id, remoteID)
        guard case .start(let mouse) = triggers.mouseDown(pad: 0, library: library).first else { return XCTFail() }
        XCTAssertTrue(triggers.remoteDown(id: remoteID, preset: 0, pad: 0, library: library).isEmpty)
        library.select(1)
        XCTAssertEqual(triggers.remoteUp(id: remoteID), [.stop(remote.id)])
        XCTAssertTrue(triggers.remoteUp(id: remoteID).isEmpty)
        XCTAssertEqual(triggers.mouseUp(pad: 0), [.stop(mouse.id)])
        XCTAssertTrue(triggers.remoteDown(id: UUID(), preset: 0, pad: 0, library: library).isEmpty)
    }
    func testRemoteOneShotsOverlapAndIgnoreReleaseWithGateOff() {
        var library = VinhetasLibrary(), triggers = VinhetasTriggers()
        library.presets[0].pads[0].audioFile = "one.wav"
        let first = UUID(), second = UUID()
        XCTAssertEqual(triggers.remoteDown(id: first, preset: 0, pad: 0, library: library).count, 1)
        XCTAssertEqual(triggers.remoteDown(id: second, preset: 0, pad: 0, library: library).count, 1)
        XCTAssertTrue(triggers.remoteUp(id: first).isEmpty)
        XCTAssertTrue(triggers.remoteUp(id: second).isEmpty)
        XCTAssertTrue(triggers.remoteDown(id: UUID(), preset: 0, pad: 16, library: library).isEmpty)
    }

}
