import XCTest
@testable import JarasApplication

@MainActor private final class SaveResponsivenessProbe {
    var heartbeats = 0
}

final class ProjectBackupTests: XCTestCase {
    @MainActor func testLargeDocumentSaveKeepsMainActorAvailableAndRemembersOpenedMedia() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let document = root.appendingPathComponent("Show.jl"), store = DocumentProjectStore()
        var project = Project.empty(name: "Large show")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var track = Track(id: UUID(), name: "Audio", role: .keys)
        let waveform = (0..<4096).map { Double($0 % 99) / 100 }
        track.clips = (0..<96).map { i in AudioClip(id: UUID(), name: "Take", startTime: 0, duration: 1,
            waveform: waveform, audioFile: AudioFile(path: "Stems/take-\(i).wav")) }
        project.songs[0].tracks = [track]
        try ProjectDocumentCodec.write(project, to: document)
        await store.select(url: document, savedProject: project)
        project.songs[0].tracks[0].clips.removeFirst()
        let probe = SaveResponsivenessProbe()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { probe.heartbeats += 1; try await Task.sleep(nanoseconds: 1_000_000) }
        }
        defer { heartbeat.cancel() }
        let start = Date()
        try await store.save(project)
        XCTAssertGreaterThan(probe.heartbeats, 1, "Encoding and file writes must yield the UI and playback control clock")
        let inventory = root.appendingPathComponent(".catlive-media-\(project.id.uuidString).json")
        XCTAssertTrue(try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: inventory)).contains("Stems/take-0.wav"))
        XCTAssertEqual(try ProjectDocumentCodec.decode(Data(contentsOf: document)), project)
        print("LARGE_PROJECT_BACKGROUND_SAVE_SECONDS=\(Date().timeIntervalSince(start)) UI_HEARTBEATS=\(probe.heartbeats)")
    }

    func testRepeatedDocumentSavesKeepMediaOwnershipAndDetectExternalReplacement() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let document = root.appendingPathComponent("Show.jl"), store = DocumentProjectStore()
        var project = Project.empty(name: "Show")
        func withMedia(_ path: String, in project: Project) -> Project {
            var next = project, track = Track(id: UUID(), name: "Audio", role: .keys)
            track.clips = [AudioClip(id: UUID(), name: "Take", startTime: 0, duration: 1, audioFile: AudioFile(path: path))]
            next.songs[0].tracks = [track]; return next
        }
        project = withMedia("Stems/original.wav", in: project)
        await store.select(url: document, id: project.id)
        try await store.save(project)
        project = withMedia("Stems/current.wav", in: project)
        try await store.save(project)
        let oldDate = try XCTUnwrap(try fm.attributesOfItem(atPath: document.path)[.modificationDate] as? Date)
        let savedSize = try Data(contentsOf: document).count
        let external = withMedia("Stems/outside.wav", in: project)
        try ProjectDocumentCodec.write(external, to: document)
        XCTAssertEqual(try Data(contentsOf: document).count, savedSize)
        // An atomic replacement must be detected even with a reused timestamp.
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: document.path)
        try await store.save(project)
        let inventory = root.appendingPathComponent(".catlive-media-\(project.id.uuidString).json")
        let paths = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: inventory))
        XCTAssertEqual(paths, ["Stems/original.wav", "Stems/current.wav", "Stems/outside.wav"])
        XCTAssertEqual(try ProjectDocumentCodec.decode(Data(contentsOf: document)), project)
        XCTAssertEqual(try ProjectBackups.files(for: document).count, 3)
        let backups = try ProjectBackups.files(for: document)
        try Data("damaged external replacement".utf8).write(to: document, options: .atomic)
        do { try await store.save(project); XCTFail("An externally damaged file must not be silently overwritten") } catch {}
        XCTAssertEqual(try ProjectBackups.files(for: document), backups)
        await store.deselect()
        do { try await store.save(project); XCTFail("A closed document cannot be saved") } catch {}
    }

    func testKeepsTenLatestEncryptedSavesAndPreservesOtherProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("Show.jl")
        let other = root.appendingPathComponent("Other/Other.jl")
        var project = Project.empty(name: "Show")
        try ProjectBackups.save(.empty(name: "Other"), to: other)
        for index in 1...12 {
            project.name = "Save \(index)"
            try ProjectBackups.save(project, to: document)
            XCTAssertLessThanOrEqual(try ProjectBackups.files(for: document).count, 10)
        }
        let backups = try ProjectBackups.files(for: document)
        XCTAssertEqual(backups.count, 10)
        XCTAssertTrue(backups.allSatisfy { $0.lastPathComponent.contains(" - ") && !$0.lastPathComponent.contains("--") })
        XCTAssertNotNil(backups.last?.lastPathComponent.range(of: #"^Show - \d{2}-\d{2}-\d{4} - \d{2}-\d{2}( - \d+)?\.bkjl$"#, options: .regularExpression))
        XCTAssertEqual(try ProjectBackups.files(for: other).count, 1)
        let versions = try backups.map { try ProjectDocumentCodec.decode(Data(contentsOf: $0)).name }
        XCTAssertEqual(versions, (3...12).map { "Save \($0)" })
        XCTAssertEqual(try Data(contentsOf: backups.last!), try Data(contentsOf: document))
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: Data(contentsOf: backups.last!)))
        let original = try Data(contentsOf: document)
        let recovered = try ProjectBackups.restore(backups[0])
        XCTAssertNotEqual(recovered.deletingLastPathComponent().resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        addTeardownBlock { try? FileManager.default.removeItem(at: recovered.deletingLastPathComponent()) }
        XCTAssertEqual(recovered.pathExtension, "jl")
        XCTAssertEqual(try ProjectDocumentCodec.decode(Data(contentsOf: recovered)).name, "Save 3")
        XCTAssertEqual(try Data(contentsOf: document), original)
        XCTAssertEqual(try ProjectBackups.files(for: document).count, 10)
        let another = try ProjectBackups.restore(backups[0])
        addTeardownBlock { try? FileManager.default.removeItem(at: another.deletingLastPathComponent()) }
        XCTAssertNotEqual(another, recovered)
    }
    func testSharedDirectoryRejectedBeforeBackupOrMediaWritesAndOwnDocumentCanSave() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = root.appendingPathComponent("First.jl"), next = root.appendingPathComponent("Second.jl")
        let project = Project.empty(name: "First")
        try ProjectDocumentCodec.write(project, to: existing)
        let before = try Data(contentsOf: existing)
        XCTAssertThrowsError(try ProjectDocumentCodec.write(.empty(name: "Second"), to: next))
        XCTAssertThrowsError(try ProjectBackups.save(.empty(name: "Second"), to: next))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("backups").path))
        XCTAssertFalse(fm.fileExists(atPath: next.path))
        XCTAssertEqual(try Data(contentsOf: existing), before)
        try ProjectBackups.save(project, to: existing)
        XCTAssertEqual(try ProjectBackups.files(for: existing).count, 1)
        #if os(macOS)
        let result = ProjectMigration.Result(project: .empty(name: "Import"), media: [], warnings: [])
        XCTAssertThrowsError(try ProjectMigration.save(result, to: next))
        #endif
    }
    func testRecoveryCopiesMediaIntoIndependentFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        let document = root.appendingPathComponent("Show.jl")
        var project = Project.empty(name: "Show")
        var track = Track(id: UUID(), name: "Audio", role: .keys)
        track.clips = [AudioClip(id: UUID(), name: "Take", startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/take.wav"))]
        project.songs[0].tracks = [track]
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("Stems/take.wav"))
        try ProjectBackups.save(project, to: document)
        let restored = try ProjectBackups.restore(XCTUnwrap(ProjectBackups.files(for: document).first))
        let recoveredRoot = restored.deletingLastPathComponent()
        defer { try? fm.removeItem(at: recoveredRoot) }
        XCTAssertNotEqual(recoveredRoot, root)
        try fm.removeItem(at: root)
        XCTAssertEqual(try Data(contentsOf: recoveredRoot.appendingPathComponent("Stems/take.wav")), Data([1, 2, 3]))
        try ProjectBackups.save(project, to: restored)
        XCTAssertEqual(try ProjectBackups.files(for: restored).count, 1)
    }
    func testLegacyBackupNamesMigrateWithoutChangingContentsAndContinueNumbering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("show novo.jl")
        let folder = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = try ProjectDocumentCodec.encode(Project.empty(name: "Saved"))
        let legacy = folder.appendingPathComponent("show novo--00001700000000000000.bkjl")
        try original.write(to: legacy)
        let date = ProjectBackups.date(for: legacy)
        try ProjectBackups.migrateLegacyNames(for: document)
        let first = try XCTUnwrap(ProjectBackups.files(for: document).first)
        XCTAssertNotNil(first.lastPathComponent.range(of: #"^show novo - \d{2}-\d{2}-\d{4} - \d{2}-\d{2}\.bkjl$"#, options: .regularExpression))
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(ProjectBackups.date(for: first).timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
        try ProjectBackups.save(.empty(name: "New"), to: document)
        XCTAssertEqual(try ProjectBackups.files(for: document).count, 2)
    }
    func testFailedSaveDoesNotRotateHistoryOrLeaveNewBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("Show.jl")
        try FileManager.default.createDirectory(at: document, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ProjectBackups.save(.empty(name: "Show"), to: document))
        XCTAssertTrue(try ProjectBackups.files(for: document).isEmpty)
    }
}
