import XCTest
@testable import JarasApplication

final class VSHookTeleprompterMigrationTests: XCTestCase {
    private func fixture(_ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("reaper-extstate.ini")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
    private func defaults() -> UserDefaults {
        let suite = "catlive-tp-migration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    func testBothWindowsPresetsScalesFontsAndNoticeSettingsPersistOnlyOnce() throws {
        let file = try fixture("""
        [VS_HOOK_NATIVE_TELEPROMPT]
        TP1_SETTINGS_V1={"preset":"day","textColor":"#112233","fontFamily":"Trebuchet MS","songNameScale":1.8,"clockScale":1.4,"localClockDepth":1.7,"mediaStretch":true,"clearMode":true,"ignorePreview":true}
        TP1_NIGHT_SETTINGS_V1={"textColor":"#445566","previewScale":2.4,"chordScale":0.9}
        TP1_DAY_SETTINGS_V1={"textColor":"#ffffff"}
        TP2_SETTINGS_V1={"preset":"night","fontFamily":"Segoe UI","queueNameScale":1.9,"windowBorderEnabled":false}
        TP2_DAY_SETTINGS_V1={"fontFamily":"Arial","textScale":0.4}
        TECHNICAL_NOTICE_SETTINGS_V1={"textColor":"#aabbcc","backgroundColor":"#123456","flashColor":"#abcdef","textScale":0.65,"fontFamily":"Trebuchet MS","window1Enabled":false,"window2Enabled":true,"emojiEnabled":true,"cleanDisplay":false,"emoji":"🎹","recadosTemplates":["JSON 1","JSON 2","JSON 3"]}
        RECADOS_TEMPLATE_1_V1=Saved 1
        TECHNICAL_NOTICE_ACTIVE_V1={"text":"A stale notice must not be sent"}
        [SOME_OTHER_PLUGIN]
        TP1_SETTINGS_V1={"textColor":"#000000"}
        """)
        let payload = try XCTUnwrap(VSHookTeleprompterMigration.read(resourceFile: file))
        let defaults = defaults()
        XCTAssertTrue(VSHookTeleprompterMigration.applyOnce(payload, defaults: defaults))
        let first = TeleprompterSettingsStore(defaults: defaults)
        XCTAssertEqual(first.selected, .day)
        XCTAssertEqual(first.current.textColor, 0x112233)
        XCTAssertEqual(first.current.fontFamily, "trebuchet")
        XCTAssertEqual(first.current.songNameScale, 180)
        XCTAssertEqual(first.current.clockScale, 140)
        XCTAssertEqual(first.current.localClockScale, 170)
        XCTAssertTrue(first.current.stretchesMedia && first.current.isClear)
        XCTAssertTrue(first.current.ignoresPreview)
        first.select(.night)
        XCTAssertEqual(first.current.textColor, 0x445566)
        XCTAssertEqual(first.current.previewScale, 240)
        XCTAssertEqual(first.current.chordScale, 90)
        let second = TeleprompterSettingsStore(defaults: defaults, key: "jaras.teleprompter2.settings")
        XCTAssertEqual(second.current.fontFamily, "segoe")
        XCTAssertFalse(second.current.previewEnabled || second.current.windowBorderEnabled)
        second.select(.day)
        XCTAssertEqual(second.current.textScale, 40)
        let notice = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "jaras.notices.appearance"))) as? [String: Any])
        XCTAssertEqual(notice["text"] as? Int, 0xaabbcc)
        XCTAssertEqual(notice["scale"] as? Double, 65)
        XCTAssertEqual(notice["font"] as? String, "Trebuchet MS")
        XCTAssertEqual(notice["window1"] as? Bool, false)
        XCTAssertEqual(defaults.stringArray(forKey: "jaras.notices.templates"), ["Saved 1", "JSON 2", "JSON 3"])
        XCTAssertNil(defaults.object(forKey: "TECHNICAL_NOTICE_ACTIVE_V1"))
        var custom = first.current; custom.textColor = 0x987654
        first.update(custom)
        XCTAssertFalse(VSHookTeleprompterMigration.applyOnce(payload, defaults: defaults))
        XCTAssertEqual(TeleprompterSettingsStore(defaults: defaults).current.textColor, 0x987654)
    }
    func testNoVSHookMalformedAndUnknownSettingsLeavePreferencesUntouched() throws {
        let defaults = defaults(), store = TeleprompterSettingsStore(defaults: defaults)
        var settings = store.current; settings.clockColor = 0x456789; store.update(settings)
        let before = defaults.data(forKey: TeleprompterSettingsStore.preferenceKey)
        for text in ["[Other]\nTP1_SETTINGS_V1={\"textScale\":0.5}",
                     "[VS_HOOK_NATIVE_TELEPROMPT]\nTP1_SETTINGS_V1=broken\nTP2_SETTINGS_V1={}",
                     "[VS_HOOK_NATIVE_TELEPROMPT]\nTP1_SETTINGS_V1={\"unknown\":42,\"textScale\":true,\"textColor\":\"invalid\"}"] {
            let payload = VSHookTeleprompterMigration.read(resourceFile: try fixture(text))
            XCTAssertNil(payload)
            XCTAssertFalse(VSHookTeleprompterMigration.applyOnce(payload, defaults: defaults))
            XCTAssertFalse(defaults.bool(forKey: VSHookTeleprompterMigration.importedKey))
            XCTAssertEqual(defaults.data(forKey: TeleprompterSettingsStore.preferenceKey), before)
        }
        XCTAssertFalse(VSHookTeleprompterMigration.applyOnce(nil, defaults: defaults))
    }
    func testPortableResourceLookupLegacyAliasesAndCopiedImages() throws {
        let file = try fixture("""
        [VS_HOOK_NATIVE_TELEPROMPT]
        TP1_SETTINGS_V1={"borderEnabled":false,"showChords":false,"rgbBorderEnabled":true,"clockPosition":"bottom","previewDurationEnabled":false,"localClockDepth":12}
        RECADOS_IMAGE_1_V1=notice.png
        RECADOS_IMAGE_2_V1=missing.png
        """)
        let original = file.deletingLastPathComponent().appendingPathComponent("notice.png")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try bytes.write(to: original)
        let project = file.deletingLastPathComponent().appendingPathComponent("Projects/demo.rpp")
        let payload = try XCTUnwrap(VSHookTeleprompterMigration.read(for: project))
        let first = try XCTUnwrap(payload.first).night
        XCTAssertFalse(first.windowBorderEnabled || first.chordsEnabled || first.previewSongDurationEnabled || first.previewBlockDurationEnabled)
        XCTAssertTrue(first.rgbWindowBorderEnabled)
        XCTAssertEqual(first.clockPosition, "center-bottom")
        XCTAssertEqual(first.localClockScale, 100)
        let defaults = defaults()
        XCTAssertTrue(VSHookTeleprompterMigration.applyOnce(payload, defaults: defaults))
        try FileManager.default.removeItem(at: original)
        XCTAssertEqual(defaults.data(forKey: "jaras.notices.image.0"), bytes)
        XCTAssertNil(defaults.data(forKey: "jaras.notices.image.1"))
    }
    func testNoticeOnlySettingsDoNotResetEitherTeleprompter() throws {
        let file = try fixture("[VS_HOOK_NATIVE_TELEPROMPT]\nTECHNICAL_NOTICE_SETTINGS_V1={\"window2Enabled\":false}")
        let defaults = defaults()
        var custom = TeleprompterSettings(); custom.clockScale = 130
        TeleprompterSettingsStore(defaults: defaults).update(custom)
        let payload = try XCTUnwrap(VSHookTeleprompterMigration.read(resourceFile: file))
        XCTAssertNil(payload.first); XCTAssertNil(payload.second)
        XCTAssertTrue(VSHookTeleprompterMigration.applyOnce(payload, defaults: defaults))
        XCTAssertEqual(TeleprompterSettingsStore(defaults: defaults).current, custom)
        XCTAssertNil(defaults.data(forKey: "jaras.teleprompter2.settings"))
    }
}
