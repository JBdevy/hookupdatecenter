import XCTest
@testable import JarasApplication

final class TeleprompterSettingsTests: XCTestCase {
    func testLegacySettingsDecodeWithoutStretchAndNewStretchPersists() throws {
        var settings = TeleprompterSettings()
        let legacy = try JSONEncoder().encode(settings)
        XCTAssertFalse(try JSONDecoder().decode(TeleprompterSettings.self, from: legacy).stretchesMedia)
        settings.stretchesMedia = true
        XCTAssertTrue(try JSONDecoder().decode(TeleprompterSettings.self, from: JSONEncoder().encode(settings)).stretchesMedia)
    }
    private func preferences() -> (UserDefaults, String) {
        let suite = "jaras-teleprompter-test-" + UUID().uuidString
        return (UserDefaults(suiteName: suite)!, suite)
    }
    func testNightAndDayRetainIndependentEditsAcrossReopening() {
        let (defaults,suite) = preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TeleprompterSettingsStore(defaults: defaults)
        XCTAssertEqual(store.selected,.night)
        var night = store.current; night.textColor = 0x123456; night.clockPosition = "left-bottom"; night.textScale = 70; night.stretchesMedia = true
        XCTAssertTrue(store.update(night))
        XCTAssertTrue(store.select(.day))
        XCTAssertEqual(store.current.textColor,0xffffff)
        var day = store.current; day.textColor = 0x654321; day.clockPosition = "right-top"; day.chordScale = 15
        XCTAssertTrue(store.update(day))
        let reopened = TeleprompterSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.selected,.day)
        XCTAssertEqual(reopened.current,day)
        reopened.select(.night)
        XCTAssertEqual(reopened.current,night)
    }
    func testTwoTelepromptersKeepSeparatePresetsAndChordVisibility() {
        let (defaults, suite) = preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let first = TeleprompterSettingsStore(defaults: defaults)
        let second = TeleprompterSettingsStore(defaults: defaults, key: "jaras.teleprompter2.settings")
        var firstNight = first.current; firstNight.chordsEnabled = false
        XCTAssertTrue(first.update(firstNight))
        XCTAssertTrue(second.select(.day))
        var secondDay = second.current; secondDay.chordsEnabled = true; secondDay.textColor = 0x123456
        XCTAssertTrue(second.update(secondDay))
        XCTAssertFalse(TeleprompterSettingsStore(defaults: defaults).current.chordsEnabled)
        let reopenedSecond = TeleprompterSettingsStore(defaults: defaults, key: "jaras.teleprompter2.settings")
        XCTAssertEqual(reopenedSecond.selected, .day)
        XCTAssertEqual(reopenedSecond.current, secondDay)
    }
    func testSanitizationProtectsSliderRangesAndDisplayChoices() {
        var value = TeleprompterSettings()
        value.chordScale = 70; value.textScale = .nan; value.clockScale = 600; value.songNameScale = 0
        value.mediaScale = .infinity; value.previewScale = -50; value.clockPosition = "invalid"; value.fontFamily = "missing"
        value.borderColor = 0xff123456
        let result = value.sanitized()
        XCTAssertEqual(result.chordScale,50)
        XCTAssertEqual(result.textScale,100)
        XCTAssertEqual(result.clockScale,100)
        XCTAssertEqual(result.songNameScale,50)
        XCTAssertEqual(result.mediaScale,100)
        XCTAssertEqual(result.previewScale,50)
        XCTAssertEqual(result.clockPosition,"center-top")
        XCTAssertEqual(result.fontFamily,"system")
        XCTAssertEqual(result.borderColor,0x123456)
    }
    func testOpeningAndSelectingCurrentPresetDoNotWritePreferences() {
        let (defaults,suite) = preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TeleprompterSettingsStore(defaults: defaults)
        XCTAssertNil(defaults.data(forKey: TeleprompterSettingsStore.preferenceKey))
        XCTAssertFalse(store.select(.night))
        XCTAssertFalse(store.update(store.current))
        XCTAssertNil(defaults.data(forKey: TeleprompterSettingsStore.preferenceKey))
        XCTAssertEqual(store.current.chordScale,50)
        XCTAssertEqual(store.current.clockExpiredColor,0xff3131)
        XCTAssertTrue(store.current.clockEnabled && store.current.localClockEnabled)
        XCTAssertEqual(store.current.display("Olá Café"),"OLÁ CAFÉ")
    }
    func testInvalidSavedDataRecoversWithoutOverwritingItOnOpen() {
        let (defaults,suite) = preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let broken = Data("incomplete settings".utf8)
        defaults.set(broken,forKey: TeleprompterSettingsStore.preferenceKey)
        let store = TeleprompterSettingsStore(defaults: defaults)
        XCTAssertEqual(store.current,TeleprompterSettings())
        XCTAssertEqual(defaults.data(forKey: TeleprompterSettingsStore.preferenceKey),broken)
        store.select(.day)
        XCTAssertEqual(TeleprompterSettingsStore(defaults: defaults).current,TeleprompterSettings(preset: .day))
    }
}
