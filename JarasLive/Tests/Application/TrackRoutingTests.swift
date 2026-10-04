import XCTest
@testable import JarasApplication
@MainActor private final class RoutingExecutor: CommandExecutor {
    var project = Project.empty(name: "Routes"), writes = 0, fullEdits = 0
    func load(_ p: Project) throws { project = p }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: try snapshot().transport) }
    func execute(_ c: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    var lastReorder: (UUID, UUID?)?
    func reorderTrack(_ id: UUID, before: UUID?) throws { lastReorder = (id, before) }
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
    @MainActor func testNormalTrackYellowDropEntersAtHitRowIncludingLastChild() throws {
        for targetIndex in [1, 4] {
            let project = groupDropProject(), tracks = project.songs[0].tracks
            let show = try ShowController(executor: RoutingExecutor(), persistence: MemoryProjectStore(), initialProject: project)
            XCTAssertTrue(show.trackDropJoinsGroup(tracks[7].id, on: tracks[targetIndex].id, after: true))
            show.dropTrack(tracks[7].id, on: tracks[targetIndex].id, before: tracks[targetIndex + 1].id)
            let result = try XCTUnwrap(show.current?.tracks)
            XCTAssertEqual(result[targetIndex + 1].id, tracks[7].id)
            XCTAssertEqual(result[targetIndex + 1].parentTrackID, tracks[0].id)
            XCTAssertEqual(result[targetIndex + 1].primaryOutput, .masterGroup)
            try show.snapshot.project.validate()
            show.undo(); XCTAssertEqual(show.current?.tracks, tracks)
            show.redo(); XCTAssertEqual(show.current?.tracks, result)
        }
    }
    @MainActor func testNormalTrackGreenDropIsOutsideAfterWholeGroup() throws {
        let project = groupDropProject(), tracks = project.songs[0].tracks
        let show = try ShowController(executor: RoutingExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertFalse(show.trackDropJoinsGroup(tracks[7].id, on: tracks[1].id, after: true, outsideGroup: true))
        let destination = try XCTUnwrap(show.current?.normalTrackDropDestination(tracks[7].id, on: tracks[1].id, after: true, outsideGroup: true))
        XCTAssertEqual(destination.indicatorTrack, tracks[4].id, "Green line previews the real boundary, not a gap between members")
        show.dropTrack(tracks[7].id, on: tracks[1].id, before: tracks[2].id, outsideGroup: true)
        XCTAssertEqual(show.current?.tracks.map(\.id), [0,1,2,3,4,7,5,6].map { tracks[$0].id })
        XCTAssertNil(show.current?.tracks[5].parentTrackID)
        try show.snapshot.project.validate()
    }
    @MainActor func testNormalTrackCanLeaveItsOwnGroupAndPreservesOtherOutputs() throws {
        var project = groupDropProject(); let tracks = project.songs[0].tracks
        project.songs[0].tracks[1].outputs = [.masterGroup, OutputPatch(firstChannel: 7, channelCount: 2)]
        let show = try ShowController(executor: RoutingExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        show.dropTrack(tracks[1].id, on: tracks[3].id, before: tracks[4].id, outsideGroup: true)
        let result = try XCTUnwrap(show.current?.tracks.first { $0.id == tracks[1].id })
        XCTAssertEqual(result.parentTrackID, tracks[0].id, "Leaving a nested group retains the outer group")
        XCTAssertEqual(result.outputPatches, [.masterGroup, OutputPatch(firstChannel: 7, channelCount: 2)])
        show.dropTrack(tracks[1].id, on: tracks[4].id, before: tracks[5].id, outsideGroup: true)
        let outside = try XCTUnwrap(show.current?.tracks.first { $0.id == tracks[1].id })
        XCTAssertNil(outside.parentTrackID)
        XCTAssertEqual(outside.outputPatches, [.master, OutputPatch(firstChannel: 7, channelCount: 2)])
        try show.snapshot.project.validate()
    }
    func testEveryNormalDropKeepsFolderMembersContiguous() throws {
        let initial = groupDropProject(), song = initial.songs[0]
        for source in song.tracks where !song.tracks.contains(where: { $0.parentTrackID == source.id }) {
            for target in song.tracks where target.id != source.id {
                for after in [false, true] { for outside in [false, true] {
                    var project = initial
                    project.moveNormalTrack(source.id, on: target.id, after: after, outsideGroup: outside, song: song.id)
                    XCTAssertEqual(Set(project.songs[0].tracks.map(\.id)), Set(song.tracks.map(\.id)))
                    XCTAssertNoThrow(try project.validate(), "source \(source.name), target \(target.name), after \(after), outside \(outside)")
                } }
            }
        }
    }
    private func groupDropProject() -> Project {
        var project = Project.empty(name: "Directional group drop")
        var tracks = (0..<8).map { Track(id: UUID(), name: "Track \($0)", role: .other) }
        tracks[1].parentTrackID = tracks[0].id
        tracks[2].parentTrackID = tracks[0].id; tracks[3].parentTrackID = tracks[2].id
        tracks[4].parentTrackID = tracks[0].id; tracks[6].parentTrackID = tracks[5].id
        tracks[2].outputs = [.masterGroup, OutputPatch(firstChannel: 5, channelCount: 2)]
        tracks[5].outputs = [.master, OutputPatch(firstChannel: 7, channelCount: 2)]
        tracks[5].volume = 0.42
        project.songs[0].tracks = tracks; return project
    }
    @MainActor func testDropAboveAdoptsFollowingSiblingsAndTheirSubtreesWithoutJoiningOldGroup() throws {
        let project = groupDropProject(), tracks = project.songs[0].tracks
        let show = try ShowController(executor: RoutingExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertFalse(show.trackDropJoinsGroup(tracks[5].id, on: tracks[2].id, after: false))
        show.dropTrack(tracks[5].id, on: tracks[2].id, before: tracks[2].id)
        let result = try XCTUnwrap(show.current?.tracks)
        XCTAssertEqual(result.map(\.id), [0,1,5,2,3,4,6,7].map { tracks[$0].id })
        XCTAssertNil(result[2].parentTrackID)
        XCTAssertEqual(result[1].parentTrackID, tracks[0].id)
        XCTAssertEqual(result[3].parentTrackID, tracks[5].id)
        XCTAssertEqual(result[4].parentTrackID, tracks[2].id)
        XCTAssertEqual(result[5].parentTrackID, tracks[5].id)
        XCTAssertEqual(result[6].parentTrackID, tracks[5].id)
        XCTAssertEqual(result[2].volume, 0.42)
        XCTAssertEqual(result[2].outputPatches, tracks[5].outputPatches)
        XCTAssertEqual(result[3].outputPatches, tracks[2].outputPatches)
        XCTAssertEqual(result[5].primaryOutput, .masterGroup)
        try show.snapshot.project.validate()
        show.undo(); XCTAssertEqual(show.current?.tracks, tracks)
        show.redo(); XCTAssertEqual(show.current?.tracks, result)
    }
    @MainActor func testDropBelowJoinsHitGroupEvenAtItsLastChild() throws {
        let project = groupDropProject(), tracks = project.songs[0].tracks, executor = RoutingExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertTrue(show.trackDropJoinsGroup(tracks[5].id, on: tracks[4].id, after: true))
        show.dropTrack(tracks[5].id, on: tracks[4].id, before: tracks[5].id)
        XCTAssertEqual(executor.lastReorder?.0, tracks[5].id)
        XCTAssertEqual(executor.lastReorder?.1, tracks[4].id, "Use the hit child so the engine joins its parent instead of using the next root")
    }
    @MainActor func testAdoptionRejectsFeedbackAndCannotTakeOwnAncestor() throws {
        var project = groupDropProject(); let tracks = project.songs[0].tracks
        project.songs[0].tracks[5].routing = TrackRouting(transmitters: [tracks[2].id])
        let show = try ShowController(executor: RoutingExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        show.dropTrack(tracks[5].id, on: tracks[2].id, before: tracks[2].id)
        XCTAssertEqual(show.snapshot.project, project, "A new routing cycle must leave every track untouched")
        project = groupDropProject(); var nested = project.songs[0].tracks
        nested[5].parentTrackID = nested[4].id; project.songs[0].tracks = nested
        try project.validate()
        let nestedShow = try ShowController(executor: RoutingExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertFalse(nestedShow.canDropTrack(nested[5].id, on: nested[2].id, after: false), "Taking following siblings cannot include the moving folder's own parent")
        XCTAssertTrue(nestedShow.canDropTrack(nested[5].id, on: nested[2].id, after: true))
    }

    @MainActor func testDropRejectsOwnDescendantsAndChildCanLeave() throws {
        var project = Project.empty(name: "Group drag")
        var tracks = (0..<5).map { Track(id: UUID(), name: "Track \($0)", role: .other) }
        tracks[1].parentTrackID = tracks[0].id
        tracks[2].parentTrackID = tracks[1].id
        tracks[3].parentTrackID = tracks[0].id
        project.songs[0].tracks = tracks
        let show = try ShowController(executor: RoutingExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertFalse(show.canDropTrack(tracks[0].id, on: tracks[1].id))
        XCTAssertFalse(show.canDropTrack(tracks[0].id, on: tracks[2].id))
        XCTAssertFalse(show.canDropTrack(tracks[0].id, on: tracks[3].id))
        XCTAssertFalse(show.canDropTrack(tracks[0].id, on: tracks[0].id))
        XCTAssertTrue(show.canDropTrack(tracks[1].id, on: tracks[0].id))
        XCTAssertTrue(show.canDropTrack(tracks[3].id, on: tracks[4].id))
        show.dropTrack(tracks[0].id, on: tracks[3].id, before: tracks[4].id)
        XCTAssertEqual(show.snapshot.project, project, "The lower half of the last child must not move its parent")
    }
    @MainActor func testRemoveFromGroupMovesSubtreeAfterLastChildAndSupportsUndo() throws {
        var project = Project.empty(name: "Remove from group")
        var tracks = (0..<6).map { Track(id: UUID(), name: "Track \($0)", role: .other) }
        tracks[1].parentTrackID = tracks[0].id; tracks[1].outputs = [.masterGroup, OutputPatch(firstChannel: 5, channelCount: 2)]
        tracks[2].parentTrackID = tracks[1].id; tracks[2].patch = .masterGroup
        tracks[3].parentTrackID = tracks[0].id; tracks[4].parentTrackID = tracks[0].id
        project.songs[0].tracks = tracks
        let show = try ShowController(executor: RoutingExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        show.removeTrackFromGroup(tracks[1].id)
        let result = try XCTUnwrap(show.current?.tracks)
        XCTAssertEqual(result.map(\.id), [0,3,4,1,2,5].map { tracks[$0].id })
        XCTAssertNil(result[3].parentTrackID)
        XCTAssertEqual(result[3].outputPatches, [.master, OutputPatch(firstChannel: 5, channelCount: 2)])
        XCTAssertEqual(result[4].parentTrackID, tracks[1].id)
        XCTAssertEqual(result[4].primaryOutput, .masterGroup)
        try show.snapshot.project.validate()
        show.undo(); XCTAssertEqual(show.current?.tracks, tracks)
        show.redo(); XCTAssertEqual(show.current?.tracks, result)
        var nested = project
        nested.removeTrackFromGroup(tracks[2].id)
        XCTAssertEqual(nested.songs[0].tracks[2].parentTrackID, tracks[0].id, "Removing from a nested folder lifts one level")
        try nested.validate()
    }

    func testNestedGroupValidationSoloAndUngroup() throws {
        var project = Project.empty(name: "Nested")
        var tracks = (0..<6).map { Track(id: UUID(), name: "Track \($0)", role: .other) }
        tracks[1].parentTrackID = tracks[0].id
        tracks[2].parentTrackID = tracks[1].id
        tracks[3].parentTrackID = tracks[2].id
        tracks[4].parentTrackID = tracks[0].id
        project.songs[0].tracks = tracks
        try project.validate()
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
        tracks[3].solo = true
        XCTAssertEqual(TrackHierarchy.soloAudibleTracks(tracks), Set(tracks.prefix(4).map(\.id)))
        tracks[3].solo = false; tracks[1].solo = true
        XCTAssertEqual(TrackHierarchy.soloAudibleTracks(tracks), Set(tracks.prefix(4).map(\.id)))
        XCTAssertEqual(project.songs[0].trackGroupDepths[tracks[3].id], 3)
        project.ungroupTrack(tracks[1].id)
        try project.validate()
        XCTAssertEqual(project.songs[0].tracks[2].parentTrackID, tracks[0].id)
        XCTAssertEqual(project.songs[0].tracks[3].parentTrackID, tracks[2].id)
        project.deleteTracks([tracks[0].id, tracks[2].id]); try project.validate()
        XCTAssertNil(project.songs[0].tracks.first { $0.id == tracks[3].id }?.parentTrackID)
        var invalid = Project.empty(name: "Cycle")
        tracks[0].parentTrackID = tracks[3].id; invalid.songs[0].tracks = tracks
        XCTAssertThrowsError(try invalid.validate())
    }

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
