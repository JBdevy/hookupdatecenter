import XCTest
@testable import JarasApplication

final class ProjectFolderDeletionTests: XCTestCase {
    func testOnlyOwnedMediaCachesAndMatchingBackupsAreDeleted() async throws {
        let (_, document) = try fixture(), fm = FileManager.default
        let folder = document.deletingLastPathComponent()
        var project = Project.empty(name: "Owned")
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Owned", startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/owned.wav"))]
        project.songs[0].tracks = [track]
        try ProjectDocumentCodec.write(project, to: document)
        let unrelated = ["notes.txt", "original.rpp", "Stems/not-owned.wav", "backups/receipt.pdf"]
        let owned = ["Stems/owned.wav", "Stems/WF/owned.wav.waveform", "Stems/deleted-earlier.wav", "backups/Media/archived.wav"]
        for path in unrelated + owned {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: url)
        }
        try ProjectMediaCleanup.remember(project: project, document: document, knownPaths: ["Stems/deleted-earlier.wav"])
        var backup = project
        backup.songs[0].tracks[0].clips[0].audioFile?.path = "backups/Media/archived.wav"
        let saved = folder.appendingPathComponent("backups/Owned.bkjl")
        try ProjectDocumentCodec.write(backup, to: saved)
        let otherBackup = folder.appendingPathComponent("backups/Another.bkjl")
        try ProjectDocumentCodec.write(.empty(name: "Another"), to: otherBackup)
        let plan = try ProjectFolderDeletion(document: document)
        try await Task.sleep(nanoseconds: 3_100_000_000)
        try plan.remove()
        for path in owned { XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(path).path), path) }
        for path in unrelated { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(path)), Data([1, 2, 3]), path) }
        XCTAssertFalse(fm.fileExists(atPath: saved.path))
        XCTAssertTrue(fm.fileExists(atPath: otherBackup.path))
        XCTAssertTrue(fm.fileExists(atPath: folder.path))
    }
    func testSiblingAddedDuringCountdownProtectsSharedAudioAndUnknownFiles() async throws {
        let (_, document) = try fixture(), fm = FileManager.default
        let folder = document.deletingLastPathComponent()
        var project = Project.empty(name: "One")
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Shared", startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/shared.wav"))]
        project.songs[0].tracks = [track]
        try ProjectDocumentCodec.write(project, to: document)
        try fm.createDirectory(at: folder.appendingPathComponent("Stems/WF"), withIntermediateDirectories: true)
        for path in ["Stems/shared.wav", "Stems/WF/shared.wav.waveform"] { try Data([4]).write(to: folder.appendingPathComponent(path)) }
        let plan = try ProjectFolderDeletion(document: document)
        var other = Project.empty(name: "Two"); other.songs[0].tracks = [track]
        let sibling = folder.appendingPathComponent("Other.jl")
        try ProjectDocumentCodec.encode(other).write(to: sibling)
        try await Task.sleep(nanoseconds: 3_100_000_000)
        try plan.remove()
        XCTAssertTrue(fm.fileExists(atPath: sibling.path))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("Stems/shared.wav").path))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("Stems/WF/shared.wav.waveform").path))
    }
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jaras-delete-\(UUID())")
        let folder = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = folder.appendingPathComponent("Show.jl")
        try ProjectDocumentCodec.write(.empty(name: "Show"), to: document)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, document)
    }
    func testDelayDeletesDocumentWithoutRemovingUnrelatedContents() async throws {
        let (root, document) = try fixture(), fm = FileManager.default
        let folder = document.deletingLastPathComponent()
        let outside = root.appendingPathComponent("outside.wav")
        try Data([1, 2, 3]).write(to: outside)
        try fm.createDirectory(at: folder.appendingPathComponent("Stems/WF"), withIntermediateDirectories: true)
        try Data([4]).write(to: folder.appendingPathComponent("Stems/WF/test.waveform"))
        try fm.createDirectory(at: folder.appendingPathComponent("backups"), withIntermediateDirectories: true)
        try Data([5]).write(to: folder.appendingPathComponent("backups/show.bkjl"))
        try fm.createSymbolicLink(at: folder.appendingPathComponent("linked.wav"), withDestinationURL: outside)
        let plan = try ProjectFolderDeletion(document: document)
        XCTAssertEqual(plan.remainingSeconds, 3)
        XCTAssertThrowsError(try plan.remove())
        XCTAssertTrue(fm.fileExists(atPath: document.path))
        XCTAssertTrue(plan.contains(document)); XCTAssertFalse(plan.contains(outside))
        XCTAssertFalse(plan.contains(root.appendingPathComponent("Project-copy/test.jl")))
        try await Task.sleep(nanoseconds: 3_100_000_000)
        try plan.remove()
        XCTAssertTrue(fm.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data([1, 2, 3]))
    }
    func testSharedProjectsUseFileOnlyDeletionAndAliasesAreRejected() throws {
        let (root, document) = try fixture(), fm = FileManager.default
        let alias = root.appendingPathComponent("Alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: document.deletingLastPathComponent())
        XCTAssertThrowsError(try ProjectFolderDeletion(document: alias.appendingPathComponent("Show.jl")))
        let other = document.deletingLastPathComponent().appendingPathComponent("Other.jl")
        try ProjectDocumentCodec.encode(.empty(name: "Other")).write(to: other)
        let plan = try ProjectFolderDeletion(document: document)
        XCTAssertFalse(plan.deletesDirectory)
        XCTAssertEqual(plan.target, document)
        XCTAssertTrue(plan.contains(document))
        XCTAssertFalse(plan.contains(other))
        try fm.removeItem(at: other)
        try fm.createSymbolicLink(at: other, withDestinationURL: document)
        XCTAssertThrowsError(try ProjectFolderDeletion(document: other))
        XCTAssertThrowsError(try ProjectFolderDeletion(document: fm.homeDirectoryForCurrentUser.appendingPathComponent("nonexistent.jl")))
        XCTAssertThrowsError(try ProjectFolderDeletion(document: root.appendingPathComponent("missing.jl")))
    }
    func testRejectsReplacedDirectoryAndNewSharedProjectAfterCountdown() async throws {
        let (_, document) = try fixture(), fm = FileManager.default
        let folder = document.deletingLastPathComponent(), moved = folder.appendingPathExtension("moved")
        let plan = try ProjectFolderDeletion(document: document)
        try await Task.sleep(nanoseconds: 3_100_000_000)
        let other = folder.appendingPathComponent("Other.jl")
        try ProjectDocumentCodec.encode(.empty(name: "Other")).write(to: other)
        try plan.validate() // A sibling never permits deleting the whole folder.
        try fm.removeItem(at: other)
        try fm.moveItem(at: folder, to: moved)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try ProjectDocumentCodec.write(.empty(name: "Replacement"), to: document)
        XCTAssertThrowsError(try plan.remove())
        XCTAssertTrue(fm.fileExists(atPath: document.path))
        XCTAssertTrue(fm.fileExists(atPath: moved.path))
    }
    func testSharedFolderDeletionKeepsSiblingAndMediaAndNeverBroadensScope() async throws {
        let (_, document) = try fixture(), fm = FileManager.default
        let folder = document.deletingLastPathComponent()
        let other = folder.appendingPathComponent("Other.jl"), media = folder.appendingPathComponent("audio.wav")
        try ProjectDocumentCodec.encode(.empty(name: "Other")).write(to: other)
        try Data([1, 2, 3]).write(to: media)
        let plan = try ProjectFolderDeletion(document: document)
        let otherPlan = try ProjectFolderDeletion(document: other)
        XCTAssertFalse(plan.deletesDirectory); XCTAssertFalse(otherPlan.deletesDirectory)
        XCTAssertThrowsError(try plan.remove())
        try await Task.sleep(nanoseconds: 3_100_000_000)
        try plan.remove()
        XCTAssertFalse(fm.fileExists(atPath: document.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path))
        // The other project is now alone, but its open confirmation still
        // authorizes only deleting its file, never the entire directory.
        try otherPlan.remove()
        XCTAssertTrue(fm.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: media), Data([1, 2, 3]))
    }
    func testProjectDirectlyInTemporaryRootOnlyDeletesItsFile() async throws {
        let fm = FileManager.default
        let document = fm.temporaryDirectory.appendingPathComponent("catlive-root-delete-\(UUID()).jl")
        defer { try? fm.removeItem(at: document) }
        try ProjectDocumentCodec.write(.empty(name: "Root"), to: document)
        let plan = try ProjectFolderDeletion(document: document)
        XCTAssertFalse(plan.deletesDirectory)
        XCTAssertFalse(plan.contains(fm.temporaryDirectory.appendingPathComponent("unrelated.jl")))
        try await Task.sleep(nanoseconds: 3_100_000_000)
        try plan.remove()
        XCTAssertFalse(fm.fileExists(atPath: document.path))
        XCTAssertTrue(fm.fileExists(atPath: fm.temporaryDirectory.path))
    }
    func testDetachedStoreCannotRecreateDeletedProject() async throws {
        let (_, document) = try fixture()
        let store = DocumentProjectStore(), project = Project.empty(name: "Session")
        await store.select(url: document, id: project.id)
        await store.deselect()
        try FileManager.default.removeItem(at: document.deletingLastPathComponent())
        do { try await store.save(project); XCTFail("A detached document must never report that it was saved") } catch {}
        let loaded = try await store.load()
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.deletingLastPathComponent().path))
    }
}
