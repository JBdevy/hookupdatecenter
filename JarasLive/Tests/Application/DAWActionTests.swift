import XCTest
@testable import JarasApplication

final class DAWActionTests: XCTestCase {
    func testSubPlayDefaultsToShiftSpaceWithoutEnterAliases() {
        var bindings = DAWActionBindings()
        let shortcut = ControlInput(kind: "keyboard", label: "⇧Space", key: 49, modifiers: 1 << 17)
        XCTAssertEqual(bindings.binding(.subPlayStop).keyboard, shortcut)
        XCTAssertEqual(bindings.matching(shortcut), .subPlayStop)
        XCTAssertEqual(bindings.matching(ControlInput(kind: "keyboard", label: "", key: 49, modifiers: 0)), .playStop)
        for key: UInt16 in [36, 76] {
            XCTAssertNil(bindings.matching(ControlInput(kind: "keyboard", label: "", key: key, modifiers: 0)))
        }
        let custom = ControlInput(kind: "keyboard", label: "F8", key: 100, modifiers: 0)
        XCTAssertTrue(bindings.setInput(custom, action: .subPlayStop, kind: "keyboard"))
        XCTAssertNil(bindings.matching(shortcut))
        bindings.reset(.subPlayStop, kind: "keyboard")
        XCTAssertEqual(bindings.matching(shortcut), .subPlayStop)
    }
    func testOldSubPlayDefaultMigratesWhilePreservingMIDIAndTrackTarget() throws {
        var old = DAWActionBinding(action: .subPlayStop)
        old.keyboard = ControlInput(kind: "keyboard", label: "Enter", key: 36, modifiers: 0)
        old.midi = ControlInput(kind: "midi", label: "CC 42", device: 2, channel: 1, status: 0xb0, number: 42)
        old.trackNumber = 3
        let migrated = DAWActionBindings(stored: [old])
        XCTAssertEqual(migrated.binding(.subPlayStop).keyboard, DAWAction.subPlayStop.defaultKeyboard)
        XCTAssertEqual(migrated.binding(.subPlayStop).midi, old.midi)
        XCTAssertEqual(migrated.binding(.subPlayStop).trackNumber, old.trackNumber)
        XCTAssertNil(migrated.matching(old.keyboard!))
        XCTAssertEqual(migrated.matching(old.midi!), .subPlayStop)
        let saved = try JSONDecoder().decode([DAWActionBinding].self, from: JSONEncoder().encode(migrated.entries))
        XCTAssertEqual(DAWActionBindings(stored: saved), migrated)
    }
    func testSubPlayMigrationPreservesCustomAndUnboundShortcuts() {
        let shortcuts: [ControlInput?] = [nil,
            ControlInput(kind: "keyboard", label: "F8", key: 100, modifiers: 0),
            ControlInput(kind: "keyboard", label: "⇧Enter", key: 36, modifiers: 1 << 17),
            ControlInput(kind: "keyboard", label: "Keypad Enter", key: 76, modifiers: 0),
            DAWAction.subPlayStop.defaultKeyboard]
        for shortcut in shortcuts {
            var stored = DAWActionBinding(action: .subPlayStop)
            stored.keyboard = shortcut
            XCTAssertEqual(DAWActionBindings(stored: [stored]).binding(.subPlayStop), stored)
        }
    }
    func testSubPlayMigrationPreservesExistingShiftSpaceMappingsInEitherOrder() {
        var old = DAWActionBinding(action: .subPlayStop)
        old.keyboard = ControlInput(kind: "keyboard", label: "Enter", key: 36, modifiers: 0)
        let shortcut = DAWAction.subPlayStop.defaultKeyboard!
        for action in [DAWAction.pause, .toggleAuto] {
            var existing = DAWActionBinding(action: action)
            existing.keyboard = shortcut
            for stored in [[old, existing], [existing, old]] {
                let migrated = DAWActionBindings(stored: stored)
                XCTAssertEqual(migrated.binding(.subPlayStop), old)
                XCTAssertEqual(migrated.binding(action), existing)
                XCTAssertEqual(migrated.matching(shortcut), action)
                XCTAssertEqual(migrated.matching(old.keyboard!), .subPlayStop)
            }
            let missing = DAWActionBindings(stored: [existing])
            XCTAssertNil(missing.binding(.subPlayStop).keyboard)
            XCTAssertEqual(missing.matching(shortcut), action)
        }
    }
    func testGlobalMultiloopBypassIsAssignableWithoutAnyDefaultInput() throws {
        let action = DAWAction.toggleMultiLoopBypass
        var bindings = DAWActionBindings()
        XCTAssertTrue(DAWAction.visible.contains(action))
        XCTAssertNil(action.defaultKeyboard); XCTAssertNil(bindings.binding(action).keyboard)
        XCTAssertNil(bindings.binding(action).midi)
        XCTAssertTrue(action.supportsMIDI); XCTAssertFalse(action.needsTrack); XCTAssertFalse(action.repeats)
        let key = ControlInput(kind: "keyboard", label: "F8", key: 100, modifiers: 0)
        let midi = ControlInput(kind: "midi", label: "Note", device: 9, channel: 2, status: 0x90, number: 41)
        XCTAssertTrue(bindings.setInput(key, action: action, kind: "keyboard"))
        XCTAssertTrue(bindings.setInput(midi, action: action, kind: "midi"))
        let saved = try JSONDecoder().decode([DAWActionBinding].self, from: JSONEncoder().encode(bindings.entries))
        let restored = DAWActionBindings(stored: saved)
        XCTAssertEqual(restored.matching(key), action); XCTAssertEqual(restored.matching(midi), action)
    }
    func testMasterSoloUsesTheGlobalActionAndHasNoDefaultShortcut() {
        XCTAssertEqual(DAWAction.quickMapping(command: "solo", master: true), .soloMaster)
        XCTAssertNil(DAWAction.soloMaster.defaultKeyboard)
        XCTAssertTrue(DAWAction.soloMaster.supportsMIDI)
        XCTAssertFalse(DAWAction.soloMaster.needsTrack)
    }
    func testPanelToggleDefaultsKeyboardAndMIDIRemappingPersistGlobally() throws {
        var bindings = DAWActionBindings()
        for (action, key, number) in [(DAWAction.toggleTracks, UInt16(122), UInt8(75)), (.toggleSetlist, 120, 76)] {
            let standard = ControlInput(kind: "keyboard", label: "", key: key, modifiers: 0)
            XCTAssertEqual(bindings.matching(standard), action)
            XCTAssertTrue(action.supportsMIDI); XCTAssertFalse(action.repeats); XCTAssertFalse(action.needsTrack)
            let replacement = ControlInput(kind: "keyboard", label: "Custom", key: key, modifiers: 1 << 17)
            XCTAssertTrue(bindings.setInput(replacement, action: action, kind: "keyboard"))
            XCTAssertNil(bindings.matching(standard)); XCTAssertEqual(bindings.matching(replacement), action)
            let midi = ControlInput(kind: "midi", label: "CC", device: 3, channel: 0, status: 0xb0, number: number)
            XCTAssertTrue(bindings.setInput(midi, action: action, kind: "midi"))
            XCTAssertEqual(bindings.matching(midi), action)
        }
        let saved = try JSONDecoder().decode([DAWActionBinding].self, from: JSONEncoder().encode(bindings.entries))
        XCTAssertEqual(DAWActionBindings(stored: saved), bindings)
        var existing = DAWActionBinding(action: .pause); existing.keyboard = DAWAction.toggleTracks.defaultKeyboard
        let migrated = DAWActionBindings(stored: [existing])
        XCTAssertNil(migrated.binding(.toggleTracks).keyboard, "F1 must not replace an existing global shortcut")
        XCTAssertEqual(migrated.binding(.pause).keyboard, existing.keyboard)
    }
    func testNormalizationAndTempoMarkersAreKeyboardOnly() {
        var bindings = DAWActionBindings()
        XCTAssertEqual(bindings.matching(ControlInput(kind: "keyboard", label: "N", key: 45, modifiers: 0)), .normalizeItems)
        for action in [DAWAction.normalizeItems, .createTempoMarker] {
            XCTAssertFalse(action.supportsMIDI); XCTAssertFalse(action.repeats)
            let midi = ControlInput(kind: "midi", label: "CC 50", device: 2, channel: 0, status: 0xb0, number: 50)
            XCTAssertFalse(bindings.setInput(midi, action: action, kind: "midi"))
            XCTAssertFalse(bindings.transferInput(midi, action: action, kind: "midi"))
        }
        for modifier: UInt in [1 << 20, 1 << 18] {
            XCTAssertEqual(bindings.matching(ControlInput(kind: "keyboard", label: "", key: 17, modifiers: modifier | (1 << 17))), .createTempoMarker)
        }
        let replacement = ControlInput(kind: "keyboard", label: "F8", key: 100, modifiers: 0)
        XCTAssertTrue(bindings.setInput(replacement, action: .normalizeItems, kind: "keyboard"))
        XCTAssertNil(bindings.matching(ControlInput(kind: "keyboard", label: "N", key: 45, modifiers: 0)))
        XCTAssertEqual(bindings.matching(replacement), .normalizeItems)
    }
    func testProjectionWindowShortcutsCanBeRemappedAndNeverRepeat() {
        var bindings = DAWActionBindings()
        for (action, key) in [(DAWAction.toggleVideo, UInt16(9)), (.toggleTeleprompter, 17)] {
            let input = ControlInput(kind: "keyboard", label: "", key: key, modifiers: (1 << 19) | (1 << 17))
            XCTAssertEqual(bindings.matching(input), action)
            XCTAssertFalse(action.repeats)
            let replacement = ControlInput(kind: "keyboard", label: "F9", key: 101, modifiers: 0)
            XCTAssertTrue(bindings.setInput(replacement, action: action, kind: "keyboard"))
            XCTAssertNil(bindings.matching(input))
            XCTAssertEqual(bindings.matching(replacement), action)
            bindings.reset(action)
        }
    }
    func testHoldingNavigationRepeatsButTransportTogglesRemainSinglePress() {
        for action in [DAWAction.nextRegion, .previousRegion, .nextTimelinePoint, .previousTimelinePoint] {
            XCTAssertTrue(action.repeats)
        }
        for action in [DAWAction.playStop, .subPlayStop, .pause, .repeatPlayback, .projectStart, .projectEnd] {
            XCTAssertFalse(action.repeats)
        }
    }
    func testNavigationDefaultsAndExistingGlobalShortcutsTakePrecedence() {
        let bindings = DAWActionBindings()
        for (action, key, label) in [(DAWAction.projectStart, UInt16(12), "Q"), (.projectEnd, 33, "["), (.nextRegion, 2, "D"), (.previousRegion, 0, "A"), (.nextTimelinePoint, 13, "W"), (.previousTimelinePoint, 14, "E")] {
            XCTAssertEqual(bindings.matching(ControlInput(kind: "keyboard", label: label, key: key, modifiers: 0)), action)
            XCTAssertTrue(action.supportsMIDI)
        }
        var existing = DAWActionBinding(action: .pause)
        existing.keyboard = DAWAction.projectStart.defaultKeyboard
        let migrated = DAWActionBindings(stored: [existing])
        XCTAssertEqual(migrated.binding(.pause).keyboard, existing.keyboard)
        XCTAssertNil(migrated.binding(.projectStart).keyboard, "adding an action must not steal an existing global shortcut")
    }
    func testOppositeActionsRequireExplicitTransferAndRetainTheirOtherInput() {
        var bindings = DAWActionBindings()
        let key = DAWAction.nextRegion.defaultKeyboard!
        let cc = ControlInput(kind: "midi", label: "CC 41", device: 2, channel: 0, status: 0xb0, number: 41)
        bindings.setInput(cc, action: .nextRegion, kind: "midi")
        let original = bindings
        XCTAssertFalse(bindings.setInput(key, action: .previousRegion, kind: "keyboard"))
        XCTAssertEqual(bindings, original)
        XCTAssertTrue(bindings.transferInput(key, action: .previousRegion, kind: "keyboard"))
        XCTAssertNil(bindings.binding(.nextRegion).keyboard)
        XCTAssertEqual(bindings.binding(.nextRegion).midi, cc)
        XCTAssertEqual(bindings.matching(key), .previousRegion)
        XCTAssertFalse(bindings.setInput(cc, action: .previousRegion, kind: "midi"))
        XCTAssertTrue(bindings.transferInput(cc, action: .previousRegion, kind: "midi"))
        XCTAssertNil(bindings.binding(.nextRegion).midi)
        XCTAssertEqual(bindings.matching(cc), .previousRegion)
        XCTAssertFalse(bindings.transferInput(DAWAction.setlistUp.defaultKeyboard!, action: .projectStart, kind: "keyboard"))
        XCTAssertEqual(bindings.binding(.setlistUp).keyboard, DAWAction.setlistUp.defaultKeyboard)
    }
    func testResetOneInputTabPreservesTheOtherInputAndTrackTarget() {
        var bindings = DAWActionBindings()
        let key = ControlInput(kind: "keyboard", label: "F", key: 3, modifiers: 0)
        let midi = ControlInput(kind: "midi", label: "CC 20", device: 3, channel: 0, status: 0xb0, number: 20)
        bindings.setTrack(7, action: .muteTrack)
        bindings.setInput(key, action: .muteTrack, kind: "keyboard")
        bindings.setInput(midi, action: .muteTrack, kind: "midi")
        bindings.reset(.muteTrack, kind: "midi")
        XCTAssertNil(bindings.binding(.muteTrack).midi)
        XCTAssertEqual(bindings.binding(.muteTrack).keyboard, key)
        XCTAssertEqual(bindings.binding(.muteTrack).trackNumber, 7)
        bindings.setInput(midi, action: .muteTrack, kind: "midi")
        bindings.reset(.muteTrack, kind: "keyboard")
        XCTAssertEqual(bindings.binding(.muteTrack).keyboard, DAWAction.muteTrack.defaultKeyboard)
        XCTAssertEqual(bindings.matching(midi), .muteTrack)
        XCTAssertEqual(bindings.binding(.muteTrack).trackNumber, 7)
    }
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
        for action in [DAWAction.volumeTrack, .panTrack, .volumeMaster] {
            bindings.setInput(replacement, action: action, kind: "keyboard")
            XCTAssertNil(bindings.binding(action).keyboard)
        }
        var corrupted = bindings.entries
        for index in corrupted.indices { corrupted[index].keyboard = replacement }
        let restored = DAWActionBindings(stored: corrupted)
        XCTAssertEqual(restored.binding(.setlistUp).keyboard, DAWAction.setlistUp.defaultKeyboard)
        XCTAssertNil(restored.binding(.panTrack).keyboard)
        XCTAssertNil(restored.binding(.volumeMaster).keyboard)
    }
    func testMIDIControlsPersistWithTrackTargetsAndAreIsolatedByDeviceChannelAndController() throws {
        var bindings = DAWActionBindings()
        let cc = ControlInput(kind: "midi", label: "Keyboard CH1 CC7", device: 27, channel: 0, status: 0xb0, number: 7)
        bindings.setInput(cc, action: .volumeTrack, kind: "midi")
        bindings.setTrack(1001, action: .volumeTrack)
        XCTAssertEqual(bindings.binding(.volumeTrack).trackNumber, 1001)
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
