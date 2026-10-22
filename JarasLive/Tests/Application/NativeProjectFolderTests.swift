import XCTest
@testable import JarasApplication

final class NativeProjectFolderTests: XCTestCase {
    func testProjectCreationUsesNamedFolderAndDoesNotReuseExistingProjectOrMedia() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let selection = root.appendingPathComponent("Show São João.jl")
        let first = ProjectDirectoryPolicy.newProjectDestination(for: selection)
        XCTAssertEqual(first, root.appendingPathComponent("Show São João/Show São João.jl"))
        try ProjectDirectoryPolicy.prepareNewProjectDirectory(for: first)
        // A user-created empty directory selected explicitly can be used directly.
        XCTAssertEqual(ProjectDirectoryPolicy.newProjectDestination(for: first), first)
        try Data("saved project".utf8).write(to: first)
        let second = ProjectDirectoryPolicy.newProjectDestination(for: selection)
        XCTAssertEqual(second, root.appendingPathComponent("Show São João (2)/Show São João.jl"))
        XCTAssertEqual(ProjectDirectoryPolicy.newProjectDestination(for: first), second)
        XCTAssertThrowsError(try ProjectDirectoryPolicy.prepareNewProjectDirectory(for: first))
        XCTAssertEqual(try String(contentsOf: first), "saved project")
        try ProjectDirectoryPolicy.prepareNewProjectDirectory(for: second)
        let media = second.deletingLastPathComponent().appendingPathComponent("audio.wav")
        try Data([1, 2, 3]).write(to: media)
        XCTAssertThrowsError(try ProjectDirectoryPolicy.prepareNewProjectDirectory(for: second))
        XCTAssertEqual(ProjectDirectoryPolicy.availableFolder(named: "Show São João", in: root).lastPathComponent, "Show São João (3)")
        XCTAssertEqual(try Data(contentsOf: media), Data([1, 2, 3]))
    }
    func testProjectFolderCollisionIncludesFilesAndDanglingSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data([9]).write(to: root.appendingPathComponent("Show"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Show (2)"), withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertEqual(ProjectDirectoryPolicy.availableFolder(named: "Show", in: root).lastPathComponent, "Show (3)")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Show")), Data([9]))
    }
    func testExtractedPortableProjectSurvivesAppContainerDeletion() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let container = base.appendingPathComponent("app", isDirectory: true)
        let source = container.appendingPathComponent("Documents/Original", isDirectory: true)
        try fm.createDirectory(at: source.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        let audio = Data(repeating: 77, count: 40000)
        try audio.write(to: source.appendingPathComponent("Stems/audio.wav"))
        var project = Project.empty(name: "External import")
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Audio", startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/audio.wav"))]
        project.songs[0].tracks = [track]
        let archive = base.appendingPathComponent("Show.ziplive")
        _ = try await PortableProjectPackage.export(project: project, directory: source, to: archive)
        let external = try NativeProjectFolderStorage.externalRoot(base.appendingPathComponent("User projects"), container: container)
        let imported = try await PortableProjectPackage.importPackage(archive, into: external)
        try fm.removeItem(at: container)
        XCTAssertEqual(try ProjectDocumentCodec.decode(Data(contentsOf: imported.document)), project)
        let media = try XCTUnwrap(imported.project.mediaPaths.first)
        XCTAssertEqual(try Data(contentsOf: imported.document.deletingLastPathComponent().appendingPathComponent(media)), audio)
        let restored = try NativeProjectFolderStorage.prepare(root: external, legacy: container.appendingPathComponent("Documents/CatLive/Projects"), container: container)
        XCTAssertTrue(restored.documents.map { $0.resolvingSymlinksInPath() }.contains(imported.document.resolvingSymlinksInPath()))
    }
    func testExternalCopySurvivesContainerDeletionAndRediscoversProjects() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let container = base.appendingPathComponent("app")
        let legacy = container.appendingPathComponent("Documents/CatLive/Projects")
        let folder = legacy.appendingPathComponent("Show")
        try fm.createDirectory(at: folder.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        let document = folder.appendingPathComponent("Show.jl")
        try Data("project-data".utf8).write(to: document)
        let audio = Data(repeating: 77, count: 40000)
        try audio.write(to: folder.appendingPathComponent("Stems/audio.wav"))
        let external = base.appendingPathComponent("external")
        let first = try NativeProjectFolderStorage.prepare(root: external, legacy: legacy, container: container)
        let saved = try XCTUnwrap(first.movedDocuments[document.standardizedFileURL])
        XCTAssertTrue(fm.fileExists(atPath: document.path))
        XCTAssertEqual(try Data(contentsOf: saved.deletingLastPathComponent().appendingPathComponent("Stems/audio.wav")), audio)
        let repeated = try NativeProjectFolderStorage.prepare(root: external, legacy: legacy, container: container)
        XCTAssertEqual(repeated.documents.count, 1)
        try Data("external-user-edit".utf8).write(to: saved)
        let collision = try NativeProjectFolderStorage.prepare(root: external, legacy: legacy, container: container)
        XCTAssertEqual(collision.documents.count, 2)
        XCTAssertEqual(try Data(contentsOf: saved), Data("external-user-edit".utf8))
        XCTAssertNotEqual(collision.movedDocuments[document.standardizedFileURL], saved)
        try fm.removeItem(at: container)
        let rediscovered = try NativeProjectFolderStorage.prepare(root: external, legacy: legacy, container: container)
        XCTAssertEqual(rediscovered.documents.count, 2)
        XCTAssertTrue(fm.fileExists(atPath: saved.path))
    }
    func testRejectsOwnContainerAndSymlinkToIt() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let container = base.appendingPathComponent("app")
        let documents = container.appendingPathComponent("Documents")
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        let alias = base.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: documents)
        for root in [container, documents, alias] {
            XCTAssertThrowsError(try NativeProjectFolderStorage.prepare(root: root, legacy: documents, container: container))
        }
    }
    func testExternalProviderPathIsNotRebasedIntoOurSandbox() {
        let ownDocuments = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/OWN/Documents")
        let provider = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/PROVIDER/Documents/CatLive/Projects/Show/Show.jl")
        let stored = NativeRecentProjectPath.store(provider, documents: ownDocuments)
        XCTAssertEqual(NativeRecentProjectPath.resolve(stored, documents: ownDocuments), provider)
    }
}
