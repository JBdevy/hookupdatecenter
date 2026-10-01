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
    func testBatchArchivesManySourcesAndPreservesAllBackupStatesAndDates() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("backups"), withIntermediateDirectories: true)
        var original = Project.empty(name: "Many sources")
        var track = Track(id: UUID(), name: "Audio", role: .keys)
        for index in 0..<32 {
            let path = "Stems/take-\(index).wav"
            try Data([UInt8(index), 42]).write(to: root.appendingPathComponent(path))
            var clip = AudioClip(id: UUID(), name: String(index), startTime: Double(index), duration: 1, audioFile: AudioFile(path: path))
            clip.gain = 0.5; clip.fadeIn = 0.25; clip.muted = index.isMultiple(of: 2)
            track.clips.append(clip)
        }
        original.songs[0].tracks = [track]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var backupURLs: [URL] = []
        for index in 0..<3 {
            let url = root.appendingPathComponent("backups/Many sources-\(index).bkjl")
            try ProjectDocumentCodec.write(original, to: url)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            backupURLs.append(url)
        }
        var current = original
        current.songs[0].tracks[0].clips = [track.clips[0]]
        try ProjectMediaCleanup.close(project: current, document: root.appendingPathComponent("Many sources.jl"), knownPaths: original.mediaPaths)
        var archivedPaths: Set<String>?
        for url in backupURLs {
            let recovered = try ProjectDocumentCodec.decode(Data(contentsOf: url))
            XCTAssertEqual(recovered.songs[0].tracks[0].clips.count, 32)
            if let archivedPaths { XCTAssertEqual(recovered.mediaPaths, archivedPaths) }
            archivedPaths = recovered.mediaPaths
            for (index, clip) in recovered.songs[0].tracks[0].clips.enumerated() {
                let path = try XCTUnwrap(clip.audioFile?.path)
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data([UInt8(index), 42]))
                XCTAssertEqual(clip.gain, 0.5); XCTAssertEqual(clip.fadeIn, 0.25)
                XCTAssertEqual(clip.muted, index.isMultiple(of: 2))
                if index > 0 {
                    XCTAssertTrue(path.hasPrefix("backups/Media/"))
                    XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Stems/take-\(index).wav").path))
                }
            }
            XCTAssertEqual(try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, date)
        }
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Stems/take-0.wav").path))
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
