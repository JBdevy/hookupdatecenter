import XCTest
@testable import JarasApplication

final class WindowsFXPortabilityTests: XCTestCase {
    /// The Windows self-test creates this file through Session.copyEffect and
    /// ProjectCodec.encode; it is deliberately not a hand-written Swift fixture.
    func testWindowsCopiedAndLegacyFXDecodeOnMac() throws {
        guard let path = ProcessInfo.processInfo.environment["CATLIVE_WINDOWS_FX_FIXTURE"] else {
            throw XCTSkip("Set CATLIVE_WINDOWS_FX_FIXTURE to the Windows self-test fx-portability.json")
        }
        let project = try ProjectDocumentCodec.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        let tracks = try XCTUnwrap(project.songs.first).tracks
        let source = try XCTUnwrap(tracks.first { $0.name == "Source" })
        let destination = try XCTUnwrap(tracks.first { $0.name == "Destination" })
        let original = try XCTUnwrap(source.fx), copied = try XCTUnwrap(destination.fx)
        let processor = try XCTUnwrap(copied.instances?.first { $0.kind == "Compressor" })
        XCTAssertTrue(copied.inserted.contains(processor.effectKey))
        XCTAssertEqual(processor.settings.inserted, ["Compressor"])
        XCTAssertEqual(processor.settings.threshold, -39)
        XCTAssertEqual(processor.settings.ratio, 9)
        XCTAssertEqual(processor.settings.makeup, 7)
        XCTAssertFalse(processor.settings.compressorEnabled)
        XCTAssertEqual(original.threshold, -39)
        let sourcePlugin = try XCTUnwrap(original.externalPlugins?.first)
        let destinationPlugin = try XCTUnwrap(copied.externalPlugins?.first)
        XCTAssertNotEqual(sourcePlugin.id, destinationPlugin.id)
        XCTAssertEqual(destinationPlugin.componentState, "bGlicmFyeS1lZGl0ZWQ=")
        XCTAssertEqual(destinationPlugin.controllerState, "dWktc3RhdGU=")
        XCTAssertTrue(destinationPlugin.bypassed)
        let master = try XCTUnwrap(project.masterFX)
        XCTAssertEqual(master.externalPlugins?.first, sourcePlugin)
        XCTAssertFalse(master.eqEnabled)
        XCTAssertFalse(master.compressorEnabled)
        XCTAssertFalse(master.delayEnabled)
        XCTAssertFalse(master.reverbEnabled)
        let item = try XCTUnwrap(source.clips.first?.fx)
        XCTAssertEqual(item.inserted, ["Delay"])
        XCTAssertTrue(item.delayEnabled)
        XCTAssertEqual(item.delayTime, 1.25)
        XCTAssertEqual(item.feedback, 48)
        XCTAssertEqual(try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project)), project)
    }
}
