import XCTest
@testable import JarasApplication
final class ProjectEncryptionTests: XCTestCase {
    func testEncryptedRoundTripAndUniqueCiphertext() throws {
        let project = Project.empty(name: "Private song name")
        let first = try ProjectDocumentCodec.encode(project)
        let second = try ProjectDocumentCodec.encode(project)
        XCTAssertNotEqual(first, second)
        XCTAssertNil(first.range(of: Data(project.name.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self, from: first))
        XCTAssertEqual(try ProjectDocumentCodec.decode(first), project)
        XCTAssertEqual(try ProjectDocumentCodec.decode(second), project)
    }
    func testCorruptionTruncationAndUnknownVersionsAreRejected() throws {
        let data = try ProjectDocumentCodec.encode(.empty(name: "Test"))
        var tampered = data; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try ProjectDocumentCodec.decode(tampered))
        XCTAssertThrowsError(try ProjectDocumentCodec.decode(data.prefix(20)))
        var future = data; future[8] = 2
        XCTAssertThrowsError(try ProjectDocumentCodec.decode(future))
    }
    func testExistingDocumentBecomesEncryptedWhenSaved() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jl")
        defer { try? FileManager.default.removeItem(at: url) }
        let project = Project.empty(name: "Existing project")
        try JSONEncoder().encode(project).write(to: url)
        let store = ProjectStore(url: url)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, project)
        try await store.save(project)
        XCTAssertNotEqual(try Data(contentsOf: url).first, 123)
        let reopened = try await store.load()
        XCTAssertEqual(reopened, project)
    }
}
