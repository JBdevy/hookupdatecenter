import XCTest
@testable import JarasApplication

final class ProjectBackupTests: XCTestCase {
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
