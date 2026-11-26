import XCTest
@testable import JarasApplication
final class ProjectRenameTests: XCTestCase {
    func testRenamePreservesIdentityAndMediaAndRedirectsFutureSaves() async throws {
        let fm=FileManager.default, root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at:root) }
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let old=root.appendingPathComponent("Before.jl"), next=root.appendingPathComponent("After.jl")
        var project=Project.empty(name:"Before"); project.projectSyncID=UUID()
        let store=DocumentProjectStore()
        await store.select(url:old,id:project.id); try await store.save(project)
        project.name="After"; try await store.save(project)
        try await store.rename(to:next,id:project.id)
        XCTAssertFalse(fm.fileExists(atPath:old.path))
        var restored=try await store.load()
        XCTAssertEqual(restored?.id,project.id); XCTAssertEqual(restored?.projectSyncID,project.projectSyncID)
        project.name="After saved again"; try await store.save(project)
        restored=try ProjectDocumentCodec.decode(Data(contentsOf:next))
        XCTAssertEqual(restored?.name,project.name)
        try Data("keep".utf8).write(to:old)
        do { try await store.rename(to:old,id:project.id); XCTFail("must not replace an existing document") } catch {}
        XCTAssertEqual(try String(contentsOf:old),"keep")
        XCTAssertTrue(fm.fileExists(atPath:next.path))
    }
    func testNamesRemainPortable() throws {
        XCTAssertEqual(try ProjectName.validated("  Show São João  "),"Show São João")
        for value in ["", "  ", "../other", "a/b", "CON", "NUL.jl", "COM1", "bad:", "bad."] {
            XCTAssertThrowsError(try ProjectName.validated(value),value)
        }
    }
}
