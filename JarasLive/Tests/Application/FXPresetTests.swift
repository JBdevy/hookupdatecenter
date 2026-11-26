import XCTest
@testable import JarasApplication

final class FXPresetTests: XCTestCase {
    func testPersistentDefaultAppliesOnlyToNewMatchingProcessor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FXPresetStore(url: root.appendingPathComponent("FXPresets.json"))
        var source = NativeFXSettings(); source.appendNative("Compressor"); source.threshold = -37; source.ratio = 9
        let preset = try FXPreset(name: "Voz", settings: source, effect: "Compressor")
        var library = try store.read(); try library.save(preset)
        try library.setDefault(preset.id, plugin: preset.plugin); try store.write(library)
        var other = NativeFXSettings(); other.appendNative("Delay"); other.delayTime = 1.3
        let first = other.appendNative("Compressor")
        other = try store.applyingDefault(to: other, effect: first)
        XCTAssertEqual(other.threshold, -37); XCTAssertEqual(other.delayTime, 1.3)
        other.threshold = -11
        let repeated = other.appendNative("Compressor")
        other = try store.applyingDefault(to: other, effect: repeated)
        XCTAssertEqual(other.threshold, -11); XCTAssertEqual(other.settings(for: repeated).threshold, -37)
        XCTAssertEqual(other.settings(for: repeated).ratio, 9)
        XCTAssertEqual(source.threshold, -37)
        library = try store.read(); try library.setDefault(nil, plugin: preset.plugin); try store.write(library)
        other.removeEffect(first); other.appendNative("Compressor")
        other = try store.applyingDefault(to: other, effect: first)
        XCTAssertEqual(other.threshold, NativeFXSettings().threshold)
        XCTAssertEqual(other.settings(for: repeated).threshold, -37)
        try other.validateForClip()
    }
    func testLoadPreservesBypassAndOtherEffectsAndRejectsWrongPlugin() throws {
        var source = NativeFXSettings(); source.appendNative("EQ"); source.bands[2].gain = 7
        let preset = try FXPreset(name: "Presença", settings: source, effect: "EQ")
        var destination = NativeFXSettings(); destination.appendNative("EQ"); destination.eqEnabled = false
        destination.appendNative("Reverb"); destination.reverbMix = 68
        let result = try preset.applying(to: destination, effect: "EQ")
        XCTAssertEqual(result.bands[2].gain, 7); XCTAssertFalse(result.eqEnabled); XCTAssertEqual(result.reverbMix, 68)
        XCTAssertTrue(preset.matches(result, effect: "EQ"))
        XCTAssertThrowsError(try preset.applying(to: destination, effect: "Reverb"))
        XCTAssertThrowsError(try FXPreset(name: "Default", settings: source, effect: "EQ"))
        var library = FXPresetLibrary(); try library.save(preset)
        XCTAssertThrowsError(try library.save(FXPreset(name: "PRESENÇA", settings: source, effect: "EQ")))
        XCTAssertThrowsError(try library.setDefault(preset.id, plugin: "native:Limiter"))
    }
    func testExternalStateUsesClassIdentityWithoutCopyingSlotPathOrBypass() throws {
        let classID = String(repeating: "A", count: 32)
        var plugin = ExternalPlugin(classID: classID, name: "Kontakt", path: "/source/Kontakt.vst3")
        plugin.componentState = "Y29tcG9uZW50"; plugin.controllerState = "Y29udHJvbGxlcg=="
        var source = NativeFXSettings(); source.externalPlugins = [plugin]; source.inserted = [plugin.effectKey]
        let preset = try FXPreset(name: "Piano", settings: source, effect: plugin.effectKey)
        var target = ExternalPlugin(classID: classID.lowercased(), name: "Kontakt", path: "C:/Plugins/Kontakt.vst3")
        target.bypassed = true
        var settings = NativeFXSettings(); settings.externalPlugins = [target]; settings.inserted = [target.effectKey]
        let result = try preset.applying(to: settings, effect: target.effectKey)
        XCTAssertEqual(result.externalPlugins?[0].id, target.id)
        XCTAssertEqual(result.externalPlugins?[0].path, target.path)
        XCTAssertEqual(result.externalPlugins?[0].bypassed, true)
        XCTAssertEqual(result.externalPlugins?[0].componentState, plugin.componentState)
        XCTAssertEqual(result.externalPlugins?[0].controllerState, plugin.controllerState)
        XCTAssertEqual(result.inserted, [target.effectKey])
        XCTAssertTrue(preset.matches(result, effect: target.effectKey))
        try result.validateForClip()
    }
    func testCorruptLibraryIsNotSilentlyReplaced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("{broken".utf8); try data.write(to: url)
        XCTAssertThrowsError(try FXPresetStore(url: url).read())
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
