import XCTest
import Darwin
@testable import JarasApplication

final class PortableProjectPackageTests: XCTestCase {
    func testLargePackageImportKeepsTemporaryReadBuffersBounded() throws {
        let source = try write("Stems/large.wav", Data())
        let output = try FileHandle(forWritingTo: source)
        let chunk = Data(repeating: 37, count: 262_144)
        for _ in 0..<128 { try output.write(contentsOf: chunk) }
        try output.close()
        let archive = try autoreleasepool { try export(project(["Stems/large.wav"])) }
        final class MemoryProbe: @unchecked Sendable {
            var peak: UInt64 = 0
            func sample() -> UInt64 {
                var info = mach_task_basic_info()
                var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
                let result = withUnsafeMutablePointer(to: &info) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                    }
                }
                let bytes = result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
                peak = max(peak, bytes)
                return bytes
            }
        }
        malloc_zone_pressure_relief(nil, 0)
        let probe = MemoryProbe()
        let baseline = probe.sample()
        try autoreleasepool {
            let imported = try PortableProjectPackage.importSynchronously(archive, into: directory.appendingPathComponent("Imported"), limits: .init()) { _ in
                _ = probe.sample()
            }
            let media = imported.documentURL.deletingLastPathComponent().appendingPathComponent("Stems/large.wav")
            XCTAssertEqual(try media.resourceValues(forKeys: [.fileSizeKey]).fileSize, 33_554_432)
        }
        print("PACKAGE_IMPORT_MEMORY_GROWTH_BYTES=\(probe.peak - baseline)")
        XCTAssertLessThan(probe.peak - baseline, 16 * 1_048_576, "Import must release read buffers as it streams, even inside a long-lived autorelease pool")
    }
    func testNativeRecentProjectSurvivesSandboxReplacement() throws {
        let old = "/var/mobile/Containers/Data/Application/OLD/Documents/CatLive/Projects/Teste/Teste.jl"
        let current = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/NEW/Documents")
        let resolved = NativeRecentProjectPath.resolve(old, documents: current)
        XCTAssertEqual(resolved.path, current.appendingPathComponent("CatLive/Projects/Teste/Teste.jl").path)
        let saved = NativeRecentProjectPath.store(resolved, documents: current)
        XCTAssertEqual(saved, "Documents/CatLive/Projects/Teste/Teste.jl")
        let next = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/NEXT/Documents")
        XCTAssertEqual(NativeRecentProjectPath.resolve(saved, documents: next).path, next.appendingPathComponent("CatLive/Projects/Teste/Teste.jl").path)
        let outside = "/Users/test/Documents/External.jl"
        XCTAssertEqual(NativeRecentProjectPath.resolve(outside, documents: next).path, outside)
    }

    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func write(_ path: String, _ bytes: Data) throws -> URL {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file); return file
    }
    private func project(_ paths: [String] = []) -> Project {
        var project = Project.empty(name: "Portable show")
        project.songs[0].duration = 120
        var track = Track(id: UUID(), name: "Audio", role: .keys)
        track.clips = paths.enumerated().map { index, path in
            AudioClip(id: UUID(), name: "Item \(index)", startTime: Double(index), duration: 1, audioFile: AudioFile(path: path))
        }
        project.songs[0].tracks = [track]; return project
    }
    @discardableResult private func export(_ project: Project, instruments: [String: URL] = [:], limits: PortableProjectPackage.Limits = .init()) throws -> URL {
        let file = directory.appendingPathComponent("Show.ziplive")
        try PortableProjectPackage.exportSynchronously(project: project, directory: directory, to: file, instruments: instruments, limits: limits, progress: { _ in })
        return file
    }
    private func read(_ file: URL, limits: PortableProjectPackage.Limits = .init()) throws -> PortableProjectPackage.ImportResult {
        try PortableProjectPackage.importSynchronously(file, into: directory.appendingPathComponent("Imported"), limits: limits, progress: { _ in })
    }
    private func rewrite(_ archive: URL, mutate: (inout [String: Data]) throws -> Void, zip64: Bool = false) throws -> URL {
        let reader = try StoredProjectZIPReader(url: archive, limits: .init())
        var data = try reader.entries.keys.reduce(into: [String: Data]()) { $0[$1] = try reader.data($1, maximum: 16_777_216) }
        try mutate(&data)
        let output = directory.appendingPathComponent(UUID().uuidString + ".ziplive")
        let writer = try StoredProjectZIPWriter(url: output, forceZIP64: zip64)
        for key in data.keys.sorted() { try writer.add(path: key, data: data[key]!) }; try writer.finish()
        return output
    }
    func testRoundTripPreservesMediaNativeEffectsAndAutomationButStripsAllExternalFX() throws {
        let bytes = Data((0..<600_000).map { UInt8($0 % 251) })
        try write("Stems/audio.wav", bytes); try write("Videos/picture.png", Data("image".utf8))
        var original = project(["Stems/audio.wav", "Videos/picture.png"])
        let plugin = ExternalPlugin(classID: String(repeating: "A", count: 32), name: "VST fixture", path: "/Library/Fixture.vst3")
        var fx = NativeFXSettings(); fx.inserted = ["EQ", plugin.effectKey, NativeFXSettings.stemSeparator]
        fx.externalPlugins = [plugin]; fx.eqEnabled = true; fx.bands[2].gain = 5
        fx.stemSeparatorEnabled = true; fx.stemMix = NativeStemMix(); fx.stemMix?.sources[2].solo = true
        var automation = TrackAutomation()
        automation.envelopes = [TrackEnvelope(target: AutomationTarget(.volume), name: "Volume", defaultValue: 0.7),
            TrackEnvelope(target: AutomationTarget(.externalFX, plugin: plugin.id, parameter: 1), name: "VST", defaultValue: 0.3)]
        original.masterFX = fx; original.masterAutomation = automation
        original.songs[0].tracks[0].fx = fx; original.songs[0].tracks[0].automation = automation
        original.songs[0].tracks[0].clips[0].fx = fx; original.songs[0].tracks[0].clips[0].automation = automation
        let snapshot = original
        let result = try read(export(original))
        XCTAssertEqual(original, snapshot)
        XCTAssertEqual(result.project, PortableProjectPackage.portableCopy(original))
        XCTAssertEqual(result.removedPlugins.count, 3); XCTAssertEqual(result.requiredCapabilities, ["catstem-realtime"])
        XCTAssertEqual(result.project.masterFX?.stemMix, original.masterFX?.stemMix)
        XCTAssertEqual(result.project.masterAutomation?.envelopes.map(\.target.kind), [.volume])
        XCTAssertEqual(try Data(contentsOf: result.documentURL.deletingLastPathComponent().appendingPathComponent("Stems/audio.wav")), bytes)
        XCTAssertTrue(result.project.songs[0].tracks[0].clips[1].isProjectionMedia)
        XCTAssertEqual(try ProjectDocumentCodec.decode(Data(contentsOf: result.documentURL)), result.project)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Stems/audio.wav")), bytes)
    }
    func testRecognizesOnlyCatLiveZIPAndPreservesProjectNameInRecentFile() throws {
        let archive = try export(project())
        let zip = directory.appendingPathComponent("Show.zip")
        try FileManager.default.copyItem(at: archive, to: zip)
        let imported = try read(zip)
        XCTAssertEqual(imported.documentURL.lastPathComponent, "Portable show.jl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.documentURL.path))
        let ordinary = directory.appendingPathComponent("Other.zip")
        let writer = try StoredProjectZIPWriter(url: ordinary)
        try writer.add(path: "readme.txt", data: Data("Not a CatLive project".utf8)); try writer.finish()
        XCTAssertThrowsError(try read(ordinary))
    }
    func testExtractedProjectCanBeEditedAndBackedUpAfterDeletingArchive() async throws {
        let bytes = Data("Project media".utf8)
        try write("Stems/song.wav", bytes)
        let archive = try export(project(["Stems/song.wav"]))
        let result = try read(archive)
        try FileManager.default.removeItem(at: archive)
        let folder = result.documentURL.deletingLastPathComponent()
        for path in ["Stems", "Stems/WF", "backups"] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
        var edited = result.project
        edited.name = "Edited on iPad"
        try ProjectBackups.save(edited, to: result.documentURL)
        let reopened = try await ProjectStore(url: result.documentURL).load()
        XCTAssertEqual(reopened, edited)
        XCTAssertFalse(try ProjectBackups.files(for: result.documentURL).isEmpty)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Stems/song.wav")), bytes)
        let rediscovered = try NativeProjectFolderStorage.prepare(root: folder.deletingLastPathComponent(),
            legacy: directory.appendingPathComponent("Deleted app/Projects"), container: directory.appendingPathComponent("New app"))
        XCTAssertTrue(rediscovered.documents.contains { $0.resolvingSymlinksInPath() == result.documentURL.resolvingSymlinksInPath() })
    }
    func testDedupRequiresMatchingNameAndContentAndUsesCollisionSuffix() throws {
        for (path, content) in [("One/clip.wav", "same"), ("Two/clip.wav", "same"), ("Three/clip.wav", "different"), ("Four/other.wav", "same")] {
            try write(path, Data(content.utf8))
        }
        let result = try read(export(project(["One/clip.wav", "Two/clip.wav", "Three/clip.wav", "Four/other.wav"])))
        let files = result.project.songs[0].tracks[0].clips.compactMap(\.audioFile?.path)
        XCTAssertEqual(files[0], files[1]); XCTAssertNotEqual(files[0], files[2]); XCTAssertNotEqual(files[0], files[3])
        XCTAssertEqual(result.project.mediaPaths.count, 3)
        XCTAssertTrue(files[2].contains("-001"))
    }
    func testNativeSoundBankMissingFailsAndBundledBankResolvesAfterImport() throws {
        var original = project(); var fx = NativeFXSettings(); fx.appendNative("Instruments", instrument: "astoria-grand")
        original.songs[0].tracks[0].fx = fx
        XCTAssertThrowsError(try export(original))
        let bank = try write("Library/piano.sf2", Data("RIFF\0\0\0\0sfbk".utf8))
        let result = try read(export(original, instruments: ["astoria-grand": bank]))
        XCTAssertEqual(PortableProjectPackage.instrumentIDs(in: original), ["astoria-grand"])
        XCTAssertEqual(result.instrumentFiles["astoria-grand"]?.lastPathComponent, "astoria-grand.sf2")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.instrumentFiles["astoria-grand"])), try Data(contentsOf: bank))
    }
    func testZIP64RoundTripAndCompatibilityWithSystemUnzip() throws {
        let archive = try rewrite(export(project()), mutate: { _ in }, zip64: true)
        XCTAssertEqual(try read(archive).project.name, "Portable show")
        #if os(macOS)
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); task.arguments = ["-t", archive.path]
        task.standardOutput = Pipe(); task.standardError = Pipe(); try task.run(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        #endif
    }
    func testCorruptedContentTruncationUnknownManifestAndExtraFileRejected() throws {
        try write("Stems/audio.wav", Data("audio content".utf8))
        let archive = try export(project(["Stems/audio.wav"]))
        let wrongHash = try rewrite(archive) { $0["Stems/audio.wav"] = Data("other content".utf8) }
        XCTAssertThrowsError(try read(wrongHash))
        let extra = try rewrite(archive) { $0["Stems/hidden.wav"] = Data() }
        XCTAssertThrowsError(try read(extra))
        for key in ["format", "version"] {
            let wrongManifest = try rewrite(archive) { entries in
                var manifest = try JSONSerialization.jsonObject(with: entries["manifest.json"]!) as! [String: Any]
                manifest[key] = key == "format" ? "another-app" : 999
                entries["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest)
            }
            XCTAssertThrowsError(try read(wrongManifest))
        }
        var truncated = try Data(contentsOf: archive); truncated.removeLast()
        let file = try write("truncated.ziplive", truncated); XCTAssertThrowsError(try read(file))
        let imported = directory.appendingPathComponent("Imported")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: imported.path)) ?? [], [])
    }
    func testZIPRejectsTraversalSymlinkCaseAliasAndOverlappingEntries() throws {
        let archive = try export(project())
        let aliases = directory.appendingPathComponent("alias.ziplive")
        let writer = try StoredProjectZIPWriter(url: aliases)
        try writer.add(path: "same", data: Data()); try writer.add(path: "SAME", data: Data()); try writer.finish()
        XCTAssertThrowsError(try StoredProjectZIPReader(url: aliases, limits: .init()))
        for path in ["../escape", "/escape", "x/../../escape", "x\\escape", "x//escape", "x/./escape", "x:\u{0}escape"] {
            XCTAssertThrowsError(try PortableProjectPackage.validatePath(path))
        }
        var data = try Data(contentsOf: archive)
        let signature = Data([0x50, 0x4b, 0x01, 0x02]), start = try XCTUnwrap(data.range(of: signature)?.lowerBound)
        let attrs = UInt32(0o120777) << 16
        for n in 0..<4 { data[start + 38 + n] = UInt8(truncatingIfNeeded: attrs >> (8*n)) }
        let symlink = try write("symlink.ziplive", data); XCTAssertThrowsError(try read(symlink))
        data = try Data(contentsOf: archive)
        let second = try XCTUnwrap(data.range(of: signature, in: start + 46..<data.count)?.lowerBound)
        for n in 0..<4 { data[second + 42 + n] = 0 }
        let overlap = try write("overlap.ziplive", data); XCTAssertThrowsError(try read(overlap))
    }
    func testSourceSymlinkLimitsAndFailedExportPreserveExistingArchive() throws {
        let outside = try write("outside.wav", Data("content".utf8))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("Stems/link.wav"), withDestinationURL: outside)
        let archive = try export(project()), before = try Data(contentsOf: archive)
        XCTAssertThrowsError(try export(project(["Stems/link.wav"])))
        XCTAssertEqual(try Data(contentsOf: archive), before)
        var limit = PortableProjectPackage.Limits(); limit.maximumBytes = 1
        XCTAssertThrowsError(try read(archive, limits: limit))
        XCTAssertThrowsError(try export(project(), limits: limit))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".catlive-export-") })
    }
    func testCancelledExportPreservesExistingFileAndLeavesNoTemporaryPackage() async throws {
        let original = project(), archive = try export(original), before = try Data(contentsOf: archive), source = directory!
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PortableProjectPackage.export(project: original, directory: source, to: archive)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: archive), before)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: source.path).contains { $0.hasPrefix(".catlive-export-") })
    }
}
