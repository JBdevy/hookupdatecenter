import XCTest
@testable import JarasApplication

final class ProjectCleanupProgressTests: XCTestCase {
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Double] = []
        func append(_ value: Double) { lock.lock(); defer { lock.unlock() }; samples.append(value) }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return samples }
    }
    func testSavingAndReopeningKeepsDeletedMediaUntilExplicitCleanup() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        let document = root.appendingPathComponent("Show.jl")
        var project = Project.empty(name: "Show")
        var track = Track(id: UUID(), name: "Audio", role: .keys)
        track.clips = [AudioClip(id: UUID(), name: "Take", startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/deleted.wav"))]
        project.songs[0].tracks = [track]
        try Data([1]).write(to: root.appendingPathComponent("Stems/deleted.wav"))
        try Data([2]).write(to: root.appendingPathComponent("Stems/unrelated.wav"))
        try ProjectBackups.save(project, to: document)
        project.songs[0].tracks[0].clips = []
        // Exceed the backup retention limit: ownership survives even when the
        // last backup referencing the deleted clip has been rotated out.
        for _ in 0..<12 { try ProjectBackups.save(project, to: document) }
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Stems/deleted.wav").path))
        let reopened = try ProjectDocumentCodec.decode(Data(contentsOf: document))
        try ProjectMediaCleanup.removeDeletedFiles(project: reopened, document: document, knownPaths: [])
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Stems/deleted.wav").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Stems/unrelated.wav").path))
    }
    func testRememberingMediaOnCloseDoesNotRemoveFilesAndCleanupKeepsCurrentSources() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        let document = root.appendingPathComponent("Show.jl")
        var project = Project.empty(name: "Show")
        var track = Track(id: UUID(), name: "Audio", role: .keys)
        track.clips = [AudioClip(id: UUID(), name: "Used", startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/used.wav"))]
        project.songs[0].tracks = [track]
        for path in ["Stems/used.wav", "Stems/deleted.wav"] { try Data([1]).write(to: root.appendingPathComponent(path)) }
        try ProjectMediaCleanup.remember(project: project, document: document, knownPaths: ["Stems/deleted.wav"])
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Stems/deleted.wav").path))
        try ProjectMediaCleanup.removeDeletedFiles(project: project, document: document, knownPaths: [])
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Stems/used.wav").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Stems/deleted.wav").path))
    }
    func testProgressCompletesWithNoUnusedMedia() throws {
        let log = ProgressLog()
        try ProjectMediaCleanup.removeDeletedFiles(project: .empty(name: "Empty"), document: URL(fileURLWithPath: "/unused/Empty.jl"), knownPaths: [], progress: log.append)
        XCTAssertEqual(log.values, [0, 1])
    }
    func testProgressTracksDeletionAndPreservesSiblingMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("Show.jl")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        var sibling = Project.empty(name: "Other")
        var track = Track(id: UUID(), name: "Shared", role: .keys)
        track.clips = [AudioClip(id: UUID(), name: "Shared", startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/shared.wav"))]
        sibling.songs[0].tracks = [track]
        try ProjectDocumentCodec.writeEncoded(ProjectDocumentCodec.encode(sibling), to: root.appendingPathComponent("Other.jl"))
        var paths: Set<String> = ["Stems/shared.wav"]
        for index in 0..<8 { paths.insert("Stems/unused\(index).wav") }
        for path in paths { try Data([1, 2, 3]).write(to: root.appendingPathComponent(path)) }
        let log = ProgressLog()
        try ProjectMediaCleanup.removeDeletedFiles(project: .empty(name: "Show"), document: document, knownPaths: paths, progress: log.append)
        XCTAssertEqual(log.values.first, 0)
        XCTAssertEqual(log.values.last, 1)
        XCTAssertGreaterThan(log.values.count, 8)
        XCTAssertTrue(zip(log.values, log.values.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertTrue(log.values.allSatisfy { (0...1).contains($0) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Stems/shared.wav").path))
        for path in paths where path != "Stems/shared.wav" { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)) }
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
        try ProjectMediaCleanup.removeDeletedFiles(project: current, document: root.appendingPathComponent("Many sources.jl"), knownPaths: original.mediaPaths)
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
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Stems/shared.wav")
        try Data([1]).write(to: source)
        try Data([0]).write(to: root.appendingPathComponent("Other.jl"))
        let log = ProgressLog()
        XCTAssertThrowsError(try ProjectMediaCleanup.removeDeletedFiles(project: .empty(name: "Show"), document: root.appendingPathComponent("Show.jl"), knownPaths: ["Stems/shared.wav"], progress: log.append))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(log.values.contains(1))
    }
}
