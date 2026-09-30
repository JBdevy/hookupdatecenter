import XCTest
@testable import JarasApplication
@MainActor private final class RoutingExecutor: CommandExecutor {
    var project = Project.empty(name: "Routes"), writes = 0, fullEdits = 0
    func load(_ p: Project) throws { project = p }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: try snapshot().transport) }
    func execute(_ c: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
    func setTrackRouting(_ routes: [UUID: TrackRouting]) throws {
        var next = project
        for song in next.songs.indices { for track in next.songs[song].tracks.indices { if let routing = routes[next.songs[song].tracks[track].id] { next.songs[song].tracks[track].routing = routing } } }
        try next.validate(); project = next; writes += 1
    }
    func setOutputPatches(track: UUID?, patches: [OutputPatch]) throws {
        var next = project
        if let track {
            for song in next.songs.indices { for index in next.songs[song].tracks.indices where next.songs[song].tracks[index].id == track {
                next.songs[song].tracks[index].outputs = patches
                next.songs[song].tracks[index].patch = nil; next.songs[song].tracks[index].secondaryPatch = nil
            } }
        } else { next.masterOutputs = patches; next.masterPatch = nil; next.masterSecondaryPatch = nil }
        try next.validate(); project = next; writes += 1
    }
    func applyProjectEdit(_ p: Project) throws { try p.validate(); project = p; fullEdits += 1 }
}
final class TrackRoutingTests: XCTestCase {
    @MainActor func testSharedMixerSelectionKeepsAnchorAndDoesNotReloadAudio() throws {
        var p = Project.empty(name: "Mixer selection")
        let first = Track(id: UUID(), name: "Left", role: .keys)
        let second = Track(id: UUID(), name: "Right", role: .keys)
        let video = Track(id: UUID(), name: "Video", role: TrackRole(rawValue: "video"))
        p.songs[0].tracks = [first, second, video]
        let executor = RoutingExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: p)
        var audioUpdates = 0
        show.audioUpdate = { _, _ in audioUpdates += 1 }
        show.setMixerTrackSelection([first.id, second.id, video.id, UUID()], anchor: second.id)
        XCTAssertEqual(show.mixerTrackSelection, [first.id, second.id])
        XCTAssertEqual(show.selectedTrackForActions, second.id)
        XCTAssertNotNil(show.current?.linkableTracks(show.mixerTrackSelection))
        show.setMixerTrackSelection([first.id], anchor: second.id)
        XCTAssertEqual(show.selectedTrackForActions, first.id)
        show.setMixerTrackSelection([], anchor: nil)
        XCTAssertTrue(show.mixerTrackSelection.isEmpty)
        XCTAssertNil(show.selectedTrackForActions)
        XCTAssertEqual(audioUpdates, 0); XCTAssertEqual(executor.fullEdits, 0)
        XCTAssertFalse(show.hasUnsavedChanges)
    }

    func testArbitraryRouteListsAndLegacyOutputsRoundTrip() throws {
        var p = Project.empty(name: "Dynamic")
        var tracks = (0..<6).map { Track(id: UUID(), name: "Track \($0)", role: .other) }
        tracks[0].patch = .master; tracks[0].secondaryPatch = .stereo
        XCTAssertEqual(tracks[0].outputPatches, [.master, .stereo])
        tracks[0].outputs = [.master, .stereo, OutputPatch(firstChannel: 3, channelCount: 2), OutputPatch(firstChannel: 5, channelCount: 1)]
        tracks[0].routing = TrackRouting(receives: [], transmitters: tracks.dropFirst().map { Optional($0.id) })
        tracks[5].routing = TrackRouting(receives: [tracks[0].id], transmitters: [])
        p.masterOutputs = [.stereo, OutputPatch(firstChannel: 3, channelCount: 2), OutputPatch(firstChannel: 5, channelCount: 2)]
        p.songs[0].tracks = tracks; try p.validate()
        XCTAssertEqual(p.songs[0].trackConnections.count, 5)
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(restored, p)
        p.songs[0].tracks[0].outputs = []; p.masterOutputs = []
        try p.validate(); XCTAssertEqual(p.songs[0].tracks[0].primaryOutput, .none)
        p.songs[0].tracks[5].routing?.transmitters = [nil, nil, nil, tracks[0].id]
        XCTAssertThrowsError(try p.validate())
    }
    @MainActor func testAddRemoveMultipleRoutesAndOutputsStayIncremental() throws {
        var p = Project.empty(name: "Dynamic")
        let tracks = (0..<6).map { Track(id: UUID(), name: "Track \($0)", role: .other) }; p.songs[0].tracks = tracks
        let executor = RoutingExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: p)
        var refreshes = 0, outputs = 0
        show.audioUpdate = { _, _ in refreshes += 1 }; show.audioPatches = { _, _ in outputs += 1 }
        for index in 0..<5 { show.addTrackRoute([tracks[0].id], receive: false); show.setTrackRouting([tracks[0].id], receive: false, slot: index, other: tracks[index + 1].id) }
        XCTAssertEqual(show.current?.tracks[0].routing?.transmitters.count, 5)
        show.removeTrackRoute([tracks[0].id], receive: false, slot: 2)
        XCTAssertEqual(show.current?.tracks[0].routing?.transmitters, [tracks[1].id, tracks[2].id, tracks[4].id, tracks[5].id])
        let before = show.snapshot.project
        show.setTrackRouting([tracks[5].id], receive: false, slot: 4, other: tracks[0].id)
        XCTAssertEqual(show.snapshot.project, before)
        show.setOutputPatches(track: tracks[0].id, patches: [.master, .stereo, OutputPatch(firstChannel: 3, channelCount: 2)])
        XCTAssertEqual(show.current?.tracks[0].outputPatches.count, 3)
        show.setOutputPatches(track: tracks[0].id, patches: [])
        XCTAssertEqual(show.current?.tracks[0].outputPatches, [])
        show.undo(); XCTAssertEqual(show.current?.tracks[0].outputPatches.count, 3)
        XCTAssertEqual(refreshes, 1, "Only Undo refreshes audio; route edits use incremental callbacks")
        XCTAssertEqual(outputs, 2)
    }
    func testReceiveAndTransmitterDeduplicateAndPersistTwoSlots() throws {
        var p = Project.empty(name: "Routes")
        var a = Track(id: UUID(), name: "A", role: .other), b = Track(id: UUID(), name: "B", role: .other)
        let c = Track(id: UUID(), name: "C", role: .other)
        a.routing = TrackRouting(transmitters: [b.id, c.id]); b.routing = TrackRouting(receives: [a.id, nil])
        p.songs[0].tracks = [a, b, c]; try p.validate()
        XCTAssertEqual(p.songs[0].trackConnections.count, 2)
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(restored.songs[0].trackConnections, p.songs[0].trackConnections)
        var cycle = p; cycle.songs[0].tracks[2].routing = TrackRouting(transmitters: [a.id, nil])
        XCTAssertThrowsError(try cycle.validate())
        cycle = p; cycle.songs[0].tracks[0].routing?.receives = [a.id, nil]
        XCTAssertThrowsError(try cycle.validate())
        cycle = p; cycle.songs[0].tracks[0].routing?.receives = [UUID(), nil]
        XCTAssertThrowsError(try cycle.validate())
    }
    func testGroupOutputsParticipateInFeedbackDetectionAndDeleteClearsRoutes() throws {
        var p = Project.empty(name: "Group")
        var folder = Track(id: UUID(), name: "Folder", role: .other)
        var child = Track(id: UUID(), name: "Child", role: .other); child.parentTrackID = folder.id
        folder.routing = TrackRouting(transmitters: [child.id, nil])
        p.songs[0].tracks = [folder, child]
        XCTAssertThrowsError(try p.validate())
        p.songs[0].tracks[1].patch = .master; try p.validate()
        p.deleteTracks([child.id]); try p.validate()
        XCTAssertEqual(p.songs[0].tracks[0].routing?.transmitters, [nil, nil])
    }
    @MainActor func testBatchRoutingIsIncrementalUndoableAndRejectsFeedbackBeforeMutation() throws {
        var p = Project.empty(name: "Batch")
        let tracks = (0..<3).map { Track(id: UUID(), name: "Track \($0)", role: .other) }; p.songs[0].tracks = tracks
        let executor = RoutingExecutor()
        // Independent controller below exposes native write and refresh counts.
        let controller = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: p)
        var audio = 0, reloads = 0
        controller.audioRouting = { _ in audio += 1 }; controller.audioUpdate = { _, _ in reloads += 1 }
        controller.setTrackRouting([tracks[0].id, tracks[1].id], receive: false, slot: 0, other: tracks[2].id)
        XCTAssertEqual(executor.writes, 1); XCTAssertEqual(executor.fullEdits, 0); XCTAssertEqual(audio, 1); XCTAssertEqual(reloads, 0)
        let before = controller.snapshot.project
        controller.setTrackRouting([tracks[2].id], receive: false, slot: 1, other: tracks[0].id)
        XCTAssertEqual(controller.snapshot.project, before); XCTAssertEqual(executor.writes, 1)
        controller.undo(); XCTAssertEqual(controller.snapshot.project, p)
    }
}
