import XCTest
@testable import JarasApplication

final class ProjectCleanupProgressTests: XCTestCase {
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Double] = []
        func append(_ value: Double) { lock.lock(); defer { lock.unlock() }; samples.append(value) }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return samples }
    }
    func testProgressCompletesWithNoUnusedMedia() throws {
        let log = ProgressLog()
        try ProjectMediaCleanup.close(project: .empty(name: "Empty"), document: URL(fileURLWithPath: "/unused/Empty.jl"), knownPaths: [], progress: log.append)
        XCTAssertEqual(log.values, [0, 1])
    }
    func testProgressTracksDeletionAndPreservesSiblingMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("Show.jl")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Steams"), withIntermediateDirectories: true)
        var sibling = Project.empty(name: "Other")
        var track = Track(id: UUID(), name: "Shared", role: .keys)
        track.clips = [AudioClip(id: UUID(), name: "Shared", startTime: 0, duration: 1, audioFile: AudioFile(path: "Steams/shared.wav"))]
        sibling.songs[0].tracks = [track]
        try ProjectDocumentCodec.writeEncoded(ProjectDocumentCodec.encode(sibling), to: root.appendingPathComponent("Other.jl"))
        var paths: Set<String> = ["Steams/shared.wav"]
        for index in 0..<8 { paths.insert("Steams/unused\(index).wav") }
        for path in paths { try Data([1, 2, 3]).write(to: root.appendingPathComponent(path)) }
        let log = ProgressLog()
        try ProjectMediaCleanup.close(project: .empty(name: "Show"), document: document, knownPaths: paths, progress: log.append)
        XCTAssertEqual(log.values.first, 0)
        XCTAssertEqual(log.values.last, 1)
        XCTAssertGreaterThan(log.values.count, 8)
        XCTAssertTrue(zip(log.values, log.values.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertTrue(log.values.allSatisfy { (0...1).contains($0) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Steams/shared.wav").path))
        for path in paths where path != "Steams/shared.wav" { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)) }
    }
    func testUnreadableSiblingDoesNotDeleteMediaOrReportSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Steams"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Steams/shared.wav")
        try Data([1]).write(to: source)
        try Data([0]).write(to: root.appendingPathComponent("Other.jl"))
        let log = ProgressLog()
        XCTAssertThrowsError(try ProjectMediaCleanup.close(project: .empty(name: "Show"), document: root.appendingPathComponent("Show.jl"), knownPaths: ["Steams/shared.wav"], progress: log.append))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(log.values.contains(1))
    }
}
