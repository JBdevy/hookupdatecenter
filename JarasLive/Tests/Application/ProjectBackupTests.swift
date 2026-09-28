import XCTest
@testable import JarasApplication

final class ProjectBackupTests: XCTestCase {
    func testKeepsTenLatestEncryptedSavesAndPreservesOtherProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("Show.jl")
        let other = root.appendingPathComponent("Other.jl")
        var project = Project.empty(name: "Show")
        try ProjectBackups.save(.empty(name: "Other"), to: other)
        for index in 1...12 {
            project.name = "Save \(index)"
            try ProjectBackups.save(project, to: document)
            XCTAssertLessThanOrEqual(try ProjectBackups.files(for: document).count, 10)
        }
        let backups = try ProjectBackups.files(for: document)
        XCTAssertEqual(backups.count, 10)
        XCTAssertEqual(try ProjectBackups.files(for: other).count, 1)
        let versions = try backups.map { try ProjectDocumentCodec.decode(Data(contentsOf: $0)).name }
        XCTAssertEqual(versions, (3...12).map { "Save \($0)" })
        XCTAssertEqual(try Data(contentsOf: backups.last!), try Data(contentsOf: document))
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: Data(contentsOf: backups.last!)))
        let original = try Data(contentsOf: document)
        let recovered = try ProjectBackups.restore(backups[0])
        XCTAssertEqual(recovered.deletingLastPathComponent().resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(recovered.pathExtension, "jl")
        XCTAssertEqual(try ProjectDocumentCodec.decode(Data(contentsOf: recovered)).name, "Save 3")
        XCTAssertEqual(try Data(contentsOf: document), original)
        XCTAssertEqual(try ProjectBackups.files(for: document).count, 10)
        XCTAssertNotEqual(try ProjectBackups.restore(backups[0]), recovered)
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
