import XCTest
import Combine
@testable import JarasApplication

@MainActor private final class SplitSelectionExecutor: CommandExecutor {
    var project = Project.empty(name: "Split")
    var rejectEdit = false
    var edits = 0
    func load(_ project: Project) throws { self.project = project }
    func snapshot() throws -> ShowSnapshot {
        ShowSnapshot(project: project, transport: TransportState(playing: false,
            songId: project.songs[0].id, position: 1, editPosition: 5,
            queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
    }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: try snapshot().transport) }
    func applyProjectEdit(_ project: Project) throws {
        if rejectEdit { throw ProjectError.invalid("Rejected edit") }
        try project.validate(); self.project = project; edits += 1
    }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}

final class SplitItemSelectionTests: XCTestCase {
    private func fixture() -> Project {
        var project = Project.empty(name: "Split selection")
        var first = Track(id: UUID(), name: "First", role: .other)
        first.clips = [AudioClip(id: UUID(), name: "A", startTime: 0, duration: 10),
            AudioClip(id: UUID(), name: "Ends at cursor", startTime: 0, duration: 5),
            AudioClip(id: UUID(), name: "Starts at cursor", startTime: 5, duration: 3),
            AudioClip(id: UUID(), name: "Outside", startTime: 12, duration: 2)]
        var second = Track(id: UUID(), name: "Second", role: .other)
        second.clips = [AudioClip(id: UUID(), name: "B", startTime: 2, duration: 8)]
        project.songs[0].tracks = [first, second]; project.songs[0].duration = 20
        var other = Project.empty(name: "Other song").songs[0]
        var otherTrack = second; otherTrack.id = UUID(); otherTrack.clips[0].id = UUID()
        other.tracks = [otherTrack]; other.duration = 20
        project.songs.append(other)
        return project
    }

    @MainActor func testSingleAndMultipleSplitsSelectOnlyTheirRightHalves() throws {
        for count in 1...2 {
            let project = fixture(), executor = SplitSelectionExecutor()
            let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
            let originals = project.songs[0].tracks.map { $0.clips[0].id }
            let selected = Set(originals.prefix(count))
            var selection = selected
            let observer = show.splitItemSelection.sink { selection = $0 }
            let right = show.splitItems(selected, at: 5)
            XCTAssertEqual(selection, right); XCTAssertEqual(right.count, count)
            XCTAssertTrue(right.isDisjoint(with: originals))
            let clips = try XCTUnwrap(show.current).tracks.flatMap(\.clips)
            XCTAssertTrue(clips.filter { right.contains($0.id) }.allSatisfy { $0.startTime == 5 && $0.duration == 5 })
            XCTAssertTrue(clips.filter { selected.contains($0.id) }.allSatisfy { $0.startTime + $0.duration == 5 })
            XCTAssertEqual(show.snapshot.project.songs[1], project.songs[1])
            XCTAssertEqual(executor.edits, 1)
            // Immediately repeating S cannot cut either new edge or change selection.
            XCTAssertTrue(show.splitItems(selection, at: 5).isEmpty)
            XCTAssertEqual(selection, right); XCTAssertEqual(executor.edits, 1)
            let next = show.splitItems(selection, at: 7)
            XCTAssertEqual(selection, next); XCTAssertEqual(next.count, count)
            XCTAssertTrue(next.isDisjoint(with: right))
            withExtendedLifetime(observer) {}
        }
    }

    @MainActor func testEmptySelectionCutsAllCrossingItemsInActiveSongOnly() throws {
        let project = fixture(), executor = SplitSelectionExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        var selection = Set<UUID>()
        let observer = show.splitItemSelection.sink { selection = $0 }
        let right = show.splitItems([], at: 5)
        XCTAssertEqual(right.count, 2); XCTAssertEqual(selection, right)
        let tracks = try XCTUnwrap(show.current).tracks
        XCTAssertEqual(tracks.map { $0.clips.count }, [5, 2])
        for original in project.songs[0].tracks[0].clips.dropFirst() {
            XCTAssertEqual(tracks[0].clips.first { $0.id == original.id }, original)
        }
        XCTAssertEqual(show.snapshot.project.songs[1], project.songs[1])
        XCTAssertEqual(show.snapshot.transport.editPosition, 5)
        XCTAssertEqual(show.snapshot.transport.position, 1)
        show.undo(); XCTAssertEqual(show.snapshot.project, project)
        show.redo(); XCTAssertEqual(show.current?.tracks, tracks)
        withExtendedLifetime(observer) {}
    }

    @MainActor func testNoCutOrFailedCommitLeavesSelectionUnchanged() throws {
        let project = fixture(), executor = SplitSelectionExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        let outside = project.songs[0].tracks[0].clips[3].id
        var notifications = 0
        let observer = show.splitItemSelection.sink { _ in notifications += 1 }
        // A nonempty selection outside the cursor must not fall back to cutting all.
        XCTAssertTrue(show.splitItems([outside], at: 5).isEmpty)
        XCTAssertTrue(show.splitItems([UUID()], at: 5).isEmpty)
        XCTAssertTrue(show.splitItems([], at: 30).isEmpty)
        XCTAssertTrue(show.splitItems([], at: .nan).isEmpty)
        executor.rejectEdit = true
        XCTAssertTrue(show.splitItems([], at: 5).isEmpty)
        XCTAssertEqual(notifications, 0); XCTAssertEqual(executor.edits, 0)
        XCTAssertEqual(show.snapshot.project, project)
        withExtendedLifetime(observer) {}
    }
}
