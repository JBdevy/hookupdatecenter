import XCTest
@testable import JarasApplication

final class DrummerPadKitTests: XCTestCase {
    func testPadLayoutsAndPresetRoundTrip() throws {
        for kind in DrummerPadKind.allCases {
            var kit = DrummerPadKit(kind)
            let last = kit.pads.count - 1
            XCTAssertEqual(kit.pads.count / kind.columns, kind == .compact ? 4 : 6)
            XCTAssertEqual(kit.pads[last].note, 36 + last)
            kit.map(note: 36, to: last)
            XCTAssertNil(kit.pads[0].note)
            kit.pads[last].name = "Snare"
            kit.pads[last].sample = "Native/Drums/snare.wav"
            kit.pads[last].volume = 0.25
            kit.volume = 0.7
            try kit.validate(kind)
            var fx = NativeFXSettings()
            let key = fx.appendNative(kind.rawValue)
            fx.setDrumKit(kit, for: kind)
            let preset = try FXPreset(name: "Live", settings: fx, effect: key)
            let reopened = try JSONDecoder().decode(FXPreset.self, from: JSONEncoder().encode(preset))
            XCTAssertEqual(reopened.native?.drumKit(kind), kit)
            let recalled = try reopened.applying(to: fx, effect: key)
            XCTAssertEqual(recalled.settings(for: key).drumKit(kind), kit)
            XCTAssertEqual(try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(fx)).drumKit(kind), kit)
            XCTAssertTrue(fx.hasDrummerPad)
            fx.setEnabled(key, enabled: false)
            XCTAssertFalse(fx.hasDrummerPad)
            XCTAssertEqual(fx.drumKit(kind), kit)
            kit.pads[last].sample = "Native/../elsewhere.wav"
            XCTAssertThrowsError(try kit.validate(kind))
        }
    }
}
