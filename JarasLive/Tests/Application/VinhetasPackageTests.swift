import XCTest
@testable import JarasApplication

final class VinhetasPackageTests: XCTestCase {
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testAllPresetsAndSharedMediaRoundTrip() throws {
        let root = try temporary(), archive = root.appendingPathComponent("Pads.zipfx")
        var library = VinhetasLibrary(); library.selectedPreset = 5; library.midiChannel = 16
        library.padMappings[0] = ControlInput(kind: "midi", label: "Flauta", device: 12, channel: 15, status: 0xb0, number: 22)
        library.presetMappings[5] = ControlInput(kind: "midi", label: "Banco", channel: 15, status: 0x90, number: 77)
        let bytes = Data([4, 5, 6, 7]); try bytes.write(to: root.appendingPathComponent("shared.wav"))
        for p in 0..<6 {
            library.presets[p].name = "Banco \(p) · Ação"
            for n in 0..<16 { library.presets[p].pads[n].audioFile = "shared.wav"; library.presets[p].pads[n].volume = Double(n) / 10; library.presets[p].pads[n].gate = n % 2 == 0 }
        }
        try VinhetasPackage.export(library, directory: root, to: archive)
        let stage = root.appendingPathComponent("Imported")
        var restored = try VinhetasPackage.prepareImport(archive, into: stage)
        let files = try FileManager.default.contentsOfDirectory(atPath: stage.path)
        XCTAssertEqual(files.count, 1); XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent(files[0])), bytes)
        for p in 0..<6 { for n in 0..<16 { XCTAssertEqual(restored.presets[p].pads[n].audioFile, files[0]); restored.presets[p].pads[n].audioFile = "shared.wav" } }
        XCTAssertEqual(restored, library)
        // Re-exporting the same destination must replace it atomically.
        try VinhetasPackage.export(library, directory: root, to: archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }
    func testEmptyLibraryIsPortable() throws {
        let root = try temporary(), archive = root.appendingPathComponent("empty.zipfx"), original = VinhetasLibrary()
        try VinhetasPackage.export(original, directory: root, to: archive)
        XCTAssertEqual(try VinhetasPackage.prepareImport(archive, into: root.appendingPathComponent("import")), original)
    }
    func testFailureDoesNotReplaceExistingExportOrAcceptEscapedSources() throws {
        let root = try temporary(), archive = root.appendingPathComponent("old.zipfx"), sentinel = Data("keep".utf8)
        try sentinel.write(to: archive)
        var library = VinhetasLibrary(); library.presets[0].pads[0].audioFile = "../outside.wav"
        XCTAssertThrowsError(try VinhetasPackage.export(library, directory: root, to: archive))
        XCTAssertEqual(try Data(contentsOf: archive), sentinel)
    }
    func testCorruptedMediaRemovesStagingWithoutReplacingInstalledFiles() throws {
        let root = try temporary(), archive = root.appendingPathComponent("bad.zipfx"), stage = root.appendingPathComponent("stage")
        let audio = root.appendingPathComponent("test.wav"); try Data([1, 2, 3]).write(to: audio)
        var record = try PortableProjectPackage.fingerprint(audio); record.path = "Audio/test.wav"; record.sha256 = String(repeating: "0", count: 64)
        var library = VinhetasLibrary(); library.presets[0].pads[0].audioFile = record.path
        let zip = try StoredProjectZIPWriter(url: archive)
        try zip.add(path: "manifest.json", data: JSONEncoder().encode(VinhetasPackage.Manifest(library: library, files: [record])))
        try zip.add(path: record.path, data: Data([1, 2, 3])); try zip.finish()
        XCTAssertThrowsError(try VinhetasPackage.prepareImport(archive, into: stage))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3]))
    }
    func testUnlistedMediaAndFutureFormatAreRejected() throws {
        let root = try temporary()
        for future in [false, true] {
            let archive = root.appendingPathComponent("\(future).zipfx"), zip = try StoredProjectZIPWriter(url: archive)
            var manifest = VinhetasPackage.Manifest(library: VinhetasLibrary(), files: [])
            if future { manifest.version = 100 } else { try zip.add(path: "Audio/extra.wav", data: Data([1])) }
            try zip.add(path: "manifest.json", data: JSONEncoder().encode(manifest)); try zip.finish()
            XCTAssertThrowsError(try VinhetasPackage.prepareImport(archive, into: root.appendingPathComponent("stage")))
        }
    }
    func testCrossPlatformArchiveExchange() throws {
        guard let directory = ProcessInfo.processInfo.environment["CATLIVE_ZIPFX_EXCHANGE"] else { throw XCTSkip("Optional Windows archive exchange") }
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let win = root.appendingPathComponent("windows.zipfx")
        if FileManager.default.fileExists(atPath: win.path) {
            let stage = root.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) }
            let library = try VinhetasPackage.prepareImport(win, into: stage)
            XCTAssertEqual(library.presets[0].name, "Metais e efeitos")
            XCTAssertEqual(library.padMappings[0]?.channel, 15)
            XCTAssertEqual(library.presets[5].pads[15].volume, 0.25)
            XCTAssertEqual(library.presets[0].pads[0].audioFile, library.presets[5].pads[15].audioFile)
            XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent(library.presets[0].pads[0].audioFile!)), try Data(contentsOf: root.appendingPathComponent("tone.wav")))
        } else {
            var library = VinhetasLibrary(); library.presets[0].name = "Metais e efeitos"
            library.midiChannel = 16; library.selectedPreset = 5
            library.padMappings[0] = ControlInput(kind: "midi", label: "CC", channel: 15, status: 0xb0, number: 23)
            library.presets[0].pads[0].audioFile = "tone.wav"
            library.presets[5].pads[15].audioFile = "tone.wav"; library.presets[5].pads[15].volume = 0.25
            try VinhetasPackage.export(library, directory: root, to: root.appendingPathComponent("swift.zipfx"))
        }
    }

}
