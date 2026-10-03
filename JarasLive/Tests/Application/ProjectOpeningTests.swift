import XCTest
@testable import JarasApplication

final class ProjectOpeningTests: XCTestCase {
    func testSearchIgnoresCaseAccentsAndMatchesFolderAndMultipleTerms() {
        let url = URL(fileURLWithPath: "/Shows/Verão/Canção 3.jl")
        XCTAssertTrue(RecentProjectEntry.matches(url, query: " CANCAO 3 "))
        XCTAssertTrue(RecentProjectEntry.matches(url, query: "verao canção"))
        XCTAssertTrue(RecentProjectEntry.matches(url, query: "   "))
        XCTAssertFalse(RecentProjectEntry.matches(url, query: "outro"))
    }
    func testMissingEntryDoesNotDeleteParentOrExistingProjectsWithSameName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let valid = root.appendingPathComponent("3.jl"), missing = root.appendingPathComponent("absent/3.jl")
        try Data("fixture".utf8).write(to: valid)
        XCTAssertFalse(RecentProjectEntry.isMissing(valid))
        XCTAssertTrue(RecentProjectEntry.isMissing(missing))
        let recent = [missing, valid].filter { !RecentProjectEntry.isMissing($0) }
        XCTAssertEqual(recent, [valid])
        XCTAssertEqual(try Data(contentsOf: valid), Data("fixture".utf8))
    }
    func testCancellationReachesDetachedReaderAndPreventsActivation() async throws {
        let started = ProjectOpeningCancellation(), stopped = ProjectOpeningCancellation()
        let task = Task {
            try await ProjectOpeningWork.run {
                started.cancel()
                defer { stopped.cancel() }
                while true { try Task.checkCancellation(); Thread.sleep(forTimeInterval: 0.005) }
            }
        }
        while !started.cancelled { try await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled opening must not activate") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertTrue(stopped.cancelled)
    }
    func testCancelledTaskCannotAcceptUncooperativeReaderResult() async throws {
        let task = Task {
            try await ProjectOpeningWork.run { Thread.sleep(forTimeInterval: 0.02); return "project" }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Must discard stale result") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
    }
}
