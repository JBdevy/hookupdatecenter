import XCTest
@testable import JarasApplication

final class TemporaryProjectTests: XCTestCase {
    private final class ProgressLog: @unchecked Sendable {
        let lock = NSLock()
        var values: [TemporaryProjectSession.SaveProgress] = []
        func append(_ value: TemporaryProjectSession.SaveProgress) {
            lock.lock(); defer { lock.unlock() }; values.append(value)
        }
    }
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-temporary-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testCrashRecoveryAndLiveSessionProtection() throws {
        let root = try root(), fm = FileManager.default
        var session: TemporaryProjectSession? = try TemporaryProjectSession(documents: root)
        let media = session!.directory.appendingPathComponent("unfinished.wav")
        try Data([1,2,3]).write(to: media)
        XCTAssertThrowsError(try TemporaryProjectSession(documents: root))
        XCTAssertTrue(fm.fileExists(atPath: media.path))
        session = nil // Release lock as on process exit, deliberately leaving media.
        XCTAssertTrue(fm.fileExists(atPath: media.path))
        let resumed = try TemporaryProjectSession(documents: root)
        XCTAssertFalse(fm.fileExists(atPath: media.path))
        try Data([4]).write(to: media)
        try resumed.discard()
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: resumed.directory.path), [])
    }
    func testPromotionCopiesMediaPreservesIdentityAndOnlyCleansScratch() throws {
        let root = try root(), fm = FileManager.default
        let session = try TemporaryProjectSession(documents: root)
        var project = Project.empty(name: "Temporary")
        var track = Track(id: UUID(), name: "Voice", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Audio", startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/audio.wav"))]
        project.songs[0].tracks = [track]
        let source = session.directory.appendingPathComponent("Stems/audio.wav")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1,2,3,4]).write(to: source)
        let target = root.appendingPathComponent("Saved/Saved.jl")
        let saved = try session.export(project, to: target)
        XCTAssertEqual(saved.id, project.id); XCTAssertEqual(saved.name, "Saved")
        XCTAssertEqual(saved.songs[0].tracks, project.songs[0].tracks)
        XCTAssertEqual(try ProjectDocumentCodec.decode(Data(contentsOf: target)), saved)
        XCTAssertEqual(try Data(contentsOf: target.deletingLastPathComponent().appendingPathComponent("Stems/audio.wav")), Data([1,2,3,4]))
        XCTAssertTrue(fm.fileExists(atPath: source.path)) // Copy before closing the scratch readers.
        try session.discard()
        XCTAssertTrue(fm.fileExists(atPath: target.path))
        XCTAssertFalse(fm.fileExists(atPath: source.path))
    }
    func testUnsafeDestinationAndMissingMediaKeepScratch() throws {
        let root = try root(), fm = FileManager.default
        let session = try TemporaryProjectSession(documents: root)
        var project = Project.empty(name: "Temporary")
        let document = session.directory.appendingPathComponent("Temporary.jl")
        try ProjectDocumentCodec.write(project, to: document)
        XCTAssertThrowsError(try session.export(project, to: session.directory.appendingPathComponent("nested/New.jl")))
        XCTAssertThrowsError(try session.export(project, to: root.appendingPathComponent("Existing.jl")))
        var track = Track(id: UUID(), name: "Missing", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Missing", startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/missing.wav"))]
        project.songs[0].tracks = [track]
        let target = root.appendingPathComponent("Failed/Failed.jl")
        XCTAssertThrowsError(try session.export(project, to: target))
        XCTAssertFalse(fm.fileExists(atPath: target.deletingLastPathComponent().path))
        XCTAssertTrue(fm.fileExists(atPath: document.path))
    }
    func testSavingProgressNamesCopiesAndFinishesOnlyAfterDocumentCommit() throws {
        let root = try root(), session = try TemporaryProjectSession(documents: root)
        let fm = FileManager.default, progress = ProgressLog()
        var project = Project.empty(name: "Temporary")
        var track = Track(id: UUID(), name: "Two media files", role: .other)
        track.clips = try ["a.wav", "b.wav"].enumerated().map { index, name in
            try Data(repeating: UInt8(index + 1), count: 1024).write(to: session.directory.appendingPathComponent(name))
            return AudioClip(id: UUID(), name: name, startTime: Double(index), duration: 1, audioFile: AudioFile(path: name))
        }
        project.songs[0].tracks = [track]
        let destination = root.appendingPathComponent("Saved/Saved.jl")
        _ = try session.export(project, to: destination) { value in
            if value.stage == .complete { XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path)) }
            progress.append(value)
        }
        XCTAssertEqual(progress.values.map(\.sequence), [0, 1, 2, 3, 4])
        XCTAssertEqual(progress.values.filter { $0.stage == .copying }.map(\.fileName), ["a.wav", "b.wav"])
        XCTAssertEqual(progress.values.last?.fraction, 1)
        for name in ["a.wav", "b.wav"] {
            XCTAssertEqual(try Data(contentsOf: destination.deletingLastPathComponent().appendingPathComponent(name)),
                           try Data(contentsOf: session.directory.appendingPathComponent(name)))
        }
        try fm.removeItem(at: session.directory.appendingPathComponent("b.wav"))
        let failed = ProgressLog()
        XCTAssertThrowsError(try session.export(project, to: root.appendingPathComponent("Failed/Failed.jl")) { failed.append($0) })
        XCTAssertFalse(failed.values.contains { $0.stage == .complete })
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Failed").path))
    }
    func testSymlinkRootRejectedAndChildLinkCannotDeleteOutside() throws {
        let root = try root(), fm = FileManager.default
        let outside = root.appendingPathComponent("normal")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let protected = outside.appendingPathComponent("keep.wav")
        try Data([7]).write(to: protected)
        let scratch = root.appendingPathComponent("catlive-temp")
        try fm.createSymbolicLink(at: scratch, withDestinationURL: outside)
        XCTAssertThrowsError(try TemporaryProjectSession(documents: root))
        XCTAssertTrue(fm.fileExists(atPath: protected.path))
        try fm.removeItem(at: scratch)
        let session = try TemporaryProjectSession(documents: root)
        try fm.createSymbolicLink(at: scratch.appendingPathComponent("link"), withDestinationURL: outside)
        try session.discard()
        XCTAssertTrue(fm.fileExists(atPath: protected.path))
    }
}
