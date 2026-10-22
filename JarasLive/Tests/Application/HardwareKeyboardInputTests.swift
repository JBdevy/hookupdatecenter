import XCTest
@testable import JarasApplication

final class HardwareKeyboardInputTests: XCTestCase {
    func testPhysicalIPadKeysUseExistingDesktopActions() throws {
        let bindings = DAWActionBindings()
        let cases: [(Int, HardwareKeyboardModifiers, DAWAction)] = [
            (0x10, [], .muteTrack), (0x16, .shift, .soloTrack),
            (0x2c, [], .playStop), (0x2c, .shift, .subPlayStop),
            (0x15, [], .repeatPlayback),
            (0x0b, .option, .toggleBarMixer), (0x17, .option, .toggleTracks),
            (0x16, .option, .toggleSetlist), (0x17, .command, .addTrack),
            (0x19, [.option, .shift], .toggleVideo), (0x17, [.option, .shift], .toggleTeleprompter),
            (0x17, [.command, .shift], .createTempoMarker),
            (0x52, [], .setlistUp), (0x51, [], .setlistDown),
            (0x2d, [], .tempoDown), (0x2e, .shift, .tempoUp),
            (0x57, [], .tempoUp), (0x56, [], .tempoDown), (0x62, [], .ignoreNext),
            (0x27, [], .ignoreNext), (0x16, [], .splitItems), (0x11, [], .normalizeItems),
            (0x14, [], .projectStart), (0x2f, [], .projectEnd),
            (0x07, [], .nextRegion), (0x04, [], .previousRegion),
            (0x1a, [], .nextTimelinePoint), (0x08, [], .previousTimelinePoint)
        ]
        XCTAssertEqual(Set(cases.map { $0.2 }), Set(DAWAction.allCases.filter { $0.defaultKeyboard != nil }),
                       "Every desktop default shortcut needs a matching physical iPad key")
        for (usage, modifiers, expected) in cases {
            let event = try XCTUnwrap(HardwareKeyboardInput.event(hidUsage: usage, modifierFlags: modifiers.rawValue))
            XCTAssertEqual(bindings.matching(event.input), expected, "HID \(usage)")
        }
    }

    func testSavedCustomMappingSurvivesDeviceAndKeyboardLayout() throws {
        let saved = ControlInput(kind: "keyboard", label: "⌘⇧G", key: 5, modifiers: 1 << 20 | 1 << 17)
        let data = try JSONEncoder().encode(saved)
        let restored = try JSONDecoder().decode(ControlInput.self, from: data)
        // Caps Lock and Num Lock must not create a different binding. Localized
        // characters affect the learn label, never the physical key identity.
        let event = try XCTUnwrap(HardwareKeyboardInput.event(hidUsage: 0x0a,
            modifierFlags: 1 << 20 | 1 << 17 | 1 << 16 | 1 << 21, characters: "ğ"))
        XCTAssertTrue(restored.matches(event.input))
        XCTAssertEqual(event.input.label, "⇧⌘Ğ")
        XCTAssertEqual(event.modifiers, [.command, .shift])
    }

    func testEditorKeysAndNumericEnterRemainDistinct() throws {
        let cases: [(Int, UInt16)] = [(0x2a, 51), (0x4c, 117), (0x28, 36), (0x58, 76),
                                     (0x06, 8), (0x1b, 7), (0x19, 9), (0x07, 2), (0x1d, 6)]
        for (usage, code) in cases { XCTAssertEqual(HardwareKeyboardInput.keyCode(hidUsage: usage), code) }
        let enter = try XCTUnwrap(HardwareKeyboardInput.event(hidUsage: 0x58, modifierFlags: 0))
        XCTAssertEqual(enter.input.label, "Enter")
        XCTAssertEqual(HardwareKeyboardInput.event(hidUsage: 0x4c, modifierFlags: 0)?.input.label, "Forward Delete")
        XCTAssertNil(HardwareKeyboardInput.keyCode(hidUsage: 0))
        XCTAssertNil(HardwareKeyboardInput.keyCode(hidUsage: 0xffff))
    }

    func testRepeatAndReleaseKeepTheSameBindingIdentity() throws {
        let down = try XCTUnwrap(HardwareKeyboardInput.event(hidUsage: 0x50, modifierFlags: 1 << 17))
        let repeated = try XCTUnwrap(HardwareKeyboardInput.event(hidUsage: 0x50, modifierFlags: 1 << 17, isRepeat: true))
        let up = try XCTUnwrap(HardwareKeyboardInput.event(hidUsage: 0x50, modifierFlags: 1 << 17, phase: .up))
        XCTAssertEqual(down.input, repeated.input); XCTAssertEqual(down.input, up.input)
        XCTAssertTrue(repeated.isRepeat); XCTAssertEqual(up.phase, .up)
        XCTAssertTrue(DAWAction.tempoUp.repeats)
        XCTAssertFalse(DAWAction.playStop.repeats)
        XCTAssertTrue(try XCTUnwrap(HardwareKeyboardInput.event(hidUsage: 0xe7, modifierFlags: 1 << 20)).isModifier)
        XCTAssertFalse(down.isModifier)
    }

    func testTextAndConfirmationModalsOwnKeyboard() {
        XCTAssertTrue(HardwareKeyboardFocusContext().permitsShortcuts)
        XCTAssertFalse(HardwareKeyboardFocusContext(enabled: false).permitsShortcuts)
        XCTAssertFalse(HardwareKeyboardFocusContext(applicationActive: false).permitsShortcuts)
        XCTAssertFalse(HardwareKeyboardFocusContext(textEditing: true).permitsShortcuts)
        XCTAssertFalse(HardwareKeyboardFocusContext(modalPresented: true).permitsShortcuts)
        XCTAssertTrue(HardwareKeyboardFocusContext(modalPresented: true, learningMapping: true).permitsShortcuts)
        XCTAssertFalse(HardwareKeyboardFocusContext(textEditing: true, modalPresented: true, learningMapping: true).permitsShortcuts)
        XCTAssertFalse(HardwareKeyboardFocusContext(modalPresented: true, learningMapping: true, transferringMapping: true).permitsShortcuts)
    }
}
