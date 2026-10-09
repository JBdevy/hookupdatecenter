import XCTest
@testable import JarasApplication

final class ExistingProjectMediaTests: XCTestCase {
    func testOnlyIdenticalNamesAndContentsReuseMedia() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stems = root.appendingPathComponent("Stems/batch")
        try FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)
        let saved = stems.appendingPathComponent("first.wav")
        let source = root.appendingPathComponent("first.wav")
        try Data([1, 2, 3, 4]).write(to: saved)
        try Data([1, 2, 3, 4]).write(to: source)
        var index = ExistingProjectMedia(directory: root.appendingPathComponent("Stems"))
        XCTAssertEqual(try index.identical(to: source)?.resolvingSymlinksInPath().path, saved.resolvingSymlinksInPath().path)
        let renamed = root.appendingPathComponent("renamed.wav")
        try Data([1, 2, 3, 4]).write(to: renamed)
        XCTAssertNil(try index.identical(to: renamed))
        try Data([4, 3, 2, 1]).write(to: source)
        XCTAssertNil(try index.identical(to: source))
        let anotherBatch = root.appendingPathComponent("Stems/another-batch")
        try FileManager.default.createDirectory(at: anotherBatch, withIntermediateDirectories: true)
        let second = anotherBatch.appendingPathComponent("first.wav")
        try FileManager.default.copyItem(at: source, to: second)
        try index.register(second)
        XCTAssertEqual(try index.identical(to: source)?.resolvingSymlinksInPath().path, second.resolvingSymlinksInPath().path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        var names = MediaFileNames(directory: root.appendingPathComponent("Stems"))
        XCTAssertEqual(names.allocate("first.wav"), "first-001.wav")
        XCTAssertEqual(names.allocate("first.wav"), "first-002.wav")
    }
}
