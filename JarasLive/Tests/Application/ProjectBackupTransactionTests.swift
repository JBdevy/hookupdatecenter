import XCTest
@testable import JarasApplication
#if canImport(Darwin)
import Darwin
#endif

final class ProjectBackupTransactionTests: XCTestCase {
    private let fm = FileManager.default

    private func directory() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func assertNoStagingFiles(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let files = try XCTUnwrap(fm.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        XCTAssertFalse(files.contains { $0.lastPathComponent.hasPrefix(".catlive-save-") }, file: file, line: line)
    }

    func testCloneAndOrdinaryCopyAreIndependentAndPublishExclusively() throws {
        let root = try directory(), source = root.appendingPathComponent("source.tmp")
        let bytes = Data((0..<32_768).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        let clone = root.appendingPathComponent("cloned.bkjl"), copy = root.appendingPathComponent("copied.bkjl")
        let cloned = try ProjectSaveFiles.copyBackup(from: source, to: clone)
        if try source.resourceValues(forKeys: [.volumeSupportsFileCloningKey]).volumeSupportsFileCloning == true {
            XCTAssertTrue(cloned, "The normal save path must use a clone on a volume that supports it")
        }
        XCTAssertFalse(try ProjectSaveFiles.copyBackup(from: source, to: copy, allowClone: false))
        let inode = try fm.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber
        for backup in [clone, copy] {
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
            XCTAssertNotEqual(try fm.attributesOfItem(atPath: backup.path)[.systemFileNumber] as? NSNumber, inode)
            XCTAssertEqual(try fm.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber, 0o600)
        }
        // An in-place edit proves these are independent snapshots, not hard links.
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: Data([255])); try handle.close()
        for backup in [clone, copy] { XCTAssertEqual(try Data(contentsOf: backup), bytes) }
        XCTAssertThrowsError(try ProjectSaveFiles.copyBackup(from: source, to: clone))
        XCTAssertThrowsError(try ProjectSaveFiles.copyBackup(from: source, to: copy, allowClone: false))
        for backup in [clone, copy] { XCTAssertEqual(try Data(contentsOf: backup), bytes) }
        XCTAssertThrowsError(try ProjectSaveFiles.copyBackup(from: root.appendingPathComponent("missing"), to: root.appendingPathComponent("failed.bkjl")))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("failed.bkjl").path))
        try assertNoStagingFiles(root)
    }

    func testSaveWritesOncePreservesPermissionsAndBacksUpTheSameEncryptedBytes() throws {
        let root = try directory(), document = root.appendingPathComponent("Show.jl")
        var project = Project.empty(name: "First")
        var operations = ProjectBackups.SaveFiles(), writes = 0, backups = 0
        operations.write = { data, temporary in
            writes += 1
            XCTAssertEqual(temporary.pathExtension, "tmp")
            XCTAssertEqual(temporary.deletingLastPathComponent().path, root.path)
            XCTAssertEqual(try self.fm.attributesOfItem(atPath: temporary.path)[.posixPermissions] as? NSNumber, 0o600)
            try data.write(to: temporary, options: .atomic)
        }
        operations.backup = { source, destination in
            backups += 1
            try ProjectSaveFiles.copyBackup(from: source, to: destination)
            XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: destination))
        }
        try ProjectBackups.save(project, to: document, files: operations)
        XCTAssertEqual(writes, 1); XCTAssertEqual(backups, 1)
        XCTAssertEqual(try fm.attributesOfItem(atPath: document.path)[.posixPermissions] as? NSNumber, 0o600)
        let firstBytes = try Data(contentsOf: document)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: document.path)
        project.name = "Next"
        try ProjectBackups.save(project, to: document, previousMediaPaths: [], files: operations)
        XCTAssertEqual(writes, 2); XCTAssertEqual(backups, 2)
        XCTAssertEqual(try fm.attributesOfItem(atPath: document.path)[.posixPermissions] as? NSNumber, 0o640)
        let history = try ProjectBackups.files(for: document)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(try Data(contentsOf: history[0]), firstBytes)
        XCTAssertEqual(try Data(contentsOf: history[1]), try Data(contentsOf: document))
        XCTAssertEqual(try fm.attributesOfItem(atPath: history[1].path)[.posixPermissions] as? NSNumber, 0o640)
        XCTAssertEqual(try ProjectDocumentCodec.decode(Data(contentsOf: document)), project)
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: Data(contentsOf: history[1])))
        try assertNoStagingFiles(root)
    }

    #if canImport(Darwin)
    func testPublicationOnVolumesWithoutExclusiveRenamePreservesExistingFiles() throws {
        let root = try directory(), bytes = Data([0, 1, 2, 3])
        for code in [ENOTSUP, ENOSYS, EINVAL] {
            let source = root.appendingPathComponent("source-\(code).tmp")
            let destination = root.appendingPathComponent("backup-\(code).bkjl")
            try bytes.write(to: source)
            let unsupported: (URL, URL) throws -> Void = { _, _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            try ProjectSaveFiles.publishBackup(source, to: destination, exclusiveRename: unsupported)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertFalse(fm.fileExists(atPath: source.path))
            try Data([9]).write(to: source)
            XCTAssertThrowsError(try ProjectSaveFiles.publishBackup(source, to: destination, exclusiveRename: unsupported))
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertEqual(try Data(contentsOf: source), Data([9]))
        }
        let source = root.appendingPathComponent("io-error.tmp"), destination = root.appendingPathComponent("io-error.bkjl")
        try bytes.write(to: source)
        XCTAssertThrowsError(try ProjectSaveFiles.publishBackup(source, to: destination, exclusiveRename: { _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    #endif

    func testFailuresKeepOriginalAndFullHistoryWithoutLeakingStagingOrRotating() throws {
        let root = try directory(), document = root.appendingPathComponent("Show.jl")
        var project = Project.empty(name: "Saved")
        for index in 1...10 {
            project.name = "Save \(index)"
            try ProjectBackups.save(project, to: document)
        }
        let original = try Data(contentsOf: document), history = try ProjectBackups.files(for: document)
        let originalHistory = try history.map { try Data(contentsOf: $0) }
        project.name = "Must not replace original"
        for failure in 0..<3 {
            var operations = ProjectBackups.SaveFiles()
            switch failure {
            case 0:
                operations.write = { _, url in
                    try Data([1, 2, 3]).write(to: url, options: .atomic)
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            case 1:
                operations.backup = { _, url in
                    try ProjectSaveFiles.copyBackup(from: root.appendingPathComponent("missing"), to: url)
                }
            default:
                operations.commit = { _, _ in throw CocoaError(.fileWriteNoPermission) }
            }
            XCTAssertThrowsError(try ProjectBackups.save(project, to: document, previousMediaPaths: [], files: operations))
            XCTAssertEqual(try Data(contentsOf: document), original)
            XCTAssertEqual(try ProjectBackups.files(for: document), history)
            XCTAssertEqual(try history.map { try Data(contentsOf: $0) }, originalHistory)
            try assertNoStagingFiles(root)
        }
    }

    func testFailedFirstCommitLeavesNoDocumentOrBackupAndRetryCanSave() throws {
        let root = try directory(), document = root.appendingPathComponent("Show.jl")
        let project = Project.empty(name: "New")
        var operations = ProjectBackups.SaveFiles()
        operations.commit = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try ProjectBackups.save(project, to: document, files: operations))
        XCTAssertFalse(fm.fileExists(atPath: document.path))
        XCTAssertTrue(try ProjectBackups.files(for: document).isEmpty)
        try assertNoStagingFiles(root)
        try ProjectBackups.save(project, to: document)
        XCTAssertEqual(try ProjectDocumentCodec.decode(Data(contentsOf: document)), project)
        XCTAssertEqual(try ProjectBackups.files(for: document).count, 1)
    }

    func testConcurrentBackupNameIsNotReplacedOrRemovedOnFailure() throws {
        let root = try directory(), document = root.appendingPathComponent("Show.jl")
        let project = Project.empty(name: "Existing")
        try ProjectBackups.save(project, to: document)
        let original = try Data(contentsOf: document), history = try ProjectBackups.files(for: document)
        let concurrentBytes = Data("another writer owns this backup".utf8)
        var concurrent: URL?, operations = ProjectBackups.SaveFiles()
        operations.backup = { source, destination in
            concurrent = destination
            try concurrentBytes.write(to: destination, options: .withoutOverwriting)
            try ProjectSaveFiles.copyBackup(from: source, to: destination)
        }
        XCTAssertThrowsError(try ProjectBackups.save(project, to: document, files: operations))
        XCTAssertEqual(try Data(contentsOf: document), original)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(concurrent)), concurrentBytes)
        XCTAssertTrue(history.allSatisfy { self.fm.fileExists(atPath: $0.path) })
        XCTAssertEqual(try ProjectBackups.files(for: document).count, 2)
        try assertNoStagingFiles(root)
    }

    func testDirectoryPolicyIsRecheckedBeforeCommit() throws {
        let root = try directory(), document = root.appendingPathComponent("Show.jl")
        let project = Project.empty(name: "Existing")
        try ProjectBackups.save(project, to: document)
        let original = try Data(contentsOf: document), history = try ProjectBackups.files(for: document)
        let other = root.appendingPathComponent("Another.jl"), otherBytes = Data("another project arrived".utf8)
        var operations = ProjectBackups.SaveFiles()
        operations.backup = { source, destination in
            try ProjectSaveFiles.copyBackup(from: source, to: destination)
            try otherBytes.write(to: other, options: .withoutOverwriting)
        }
        XCTAssertThrowsError(try ProjectBackups.save(project, to: document, files: operations))
        XCTAssertEqual(try Data(contentsOf: document), original)
        XCTAssertEqual(try ProjectBackups.files(for: document), history)
        XCTAssertEqual(try Data(contentsOf: other), otherBytes)
        try assertNoStagingFiles(root)
    }
}
