import XCTest
@testable import JarasApplication

@MainActor private final class CursorExecutor: CommandExecutor {
    var project = Project.empty(name: "Cursor")
    var loadCount = 0
    var snapshotCount = 0
    var regionCommands: [ShowCommand] = []
    var regionCommandResult: TransportState?
    var transport = TransportState(playing: false, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    func load(_ project: Project) throws {
        loadCount += 1
        self.project = project
        transport.playing = false; transport.subPlay.playing = false
        transport.songId = project.songs.first?.id; transport.position = 0; transport.editPosition = 0
    }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        switch command {
        case .editSeek: transport.editPosition = value; if !transport.playing { transport.position = value }
        case .select: transport.songId = target
        case .play:
            if !transport.playing && !(transport.paused ?? false) { transport.position = transport.editPosition ?? transport.position }
            transport.playing = true
            transport.regionId = project.songs.first?.parts.filter {
                $0.parentRegionID == nil && transport.position >= $0.startTime && transport.position < $0.endTime
            }.min { $0.endTime - $0.startTime < $1.endTime - $1.startTime }?.id
        case .selectRegion, .queueRegion:
            regionCommands.append(command)
            if let regionCommandResult { transport = regionCommandResult }
        case .subPlay: transport.subPlay.playing = transport.playing
        case .stop, .stopAll: transport.playing = false
        default: break
        }
    }
    func setMarker(_ marker: TimelineMarker) throws {
        if project.songs[0].markers == nil { project.songs[0].markers = [] }
        if let index = project.songs[0].markers?.firstIndex(where: { $0.id == marker.id }) { project.songs[0].markers![index] = marker }
        else { project.songs[0].markers?.append(marker) }
        project.songs[0].duration = max(project.songs[0].duration, marker.position)
    }
    func deleteManualMarker(_ id: UUID) throws { project.songs[0].markers?.removeAll { $0.id == id } }
    func setProjectTiming(bpm: Double, beats: Int, unit: Int, settings: ProjectTimeSettings) throws {
        project.songs[0].configureTiming(bpm: bpm, beats: beats, unit: unit, settings: settings)
    }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func snapshot() throws -> ShowSnapshot { snapshotCount += 1; return ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func configureRegionSetlist(_ state: RegionSetlist) throws { project.regionSetlist = state }
    func advance(_ elapsed: Double) { transport.position += elapsed }
    func finishCurrentSong(_ enabled: Bool) {}
}

final class ProjectCursorTests: XCTestCase {
    @MainActor func testSelectingPlayingSongPreservesQueueForDesktopAndRemoteFocusAction() throws {
        var project = Project.empty(name: "Queue clicks")
        let parent = Part(id: UUID(), name: "Group", startTime: 10, endTime: 80)
        let child = Part(id: UUID(), name: "Playing", startTime: 30, endTime: 80, parentRegionID: parent.id)
        let queued = Part(id: UUID(), name: "Queued", startTime: 90, endTime: 100)
        project.songs[0].parts = [parent, child, queued]; project.songs[0].duration = 110
        project.regionSetlist = RegionSetlist(); project.regionSetlist?.autoAdvance = true
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        executor.transport.playing = true; executor.transport.position = 40
        executor.transport.regionId = parent.id; executor.transport.queuedRegionId = queued.id
        executor.transport.queueStartedAt = 20
        show.send(.pause)
        let commands = executor.regionCommands.count
        for id in [parent.id, child.id] {
            show.focusRegion(id)
            XCTAssertEqual(show.focusedRegion, id)
            XCTAssertEqual(show.snapshot.transport.queuedRegionId, queued.id)
            XCTAssertEqual(show.snapshot.transport.queueStartedAt, 20)
            XCTAssertTrue(show.regionSetlist.autoAdvance)
            XCTAssertEqual(executor.regionCommands.count, commands, "playing selection must not send a queue replacement")
        }
        show.send(.stopAll)
    }
    @MainActor func testQueueCancellationPublishesAutoOffWithoutReloadingMediaOrStoppingPlayback() throws {
        var project = Project.empty(name: "Cancel queue")
        let playing = Part(id: UUID(), name: "Playing", startTime: 0, endTime: 60)
        let queued = Part(id: UUID(), name: "Queued", startTime: 60, endTime: 120)
        project.songs[0].parts = [playing, queued]; project.songs[0].duration = 120
        project.regionSetlist = RegionSetlist(); project.regionSetlist?.autoAdvance = true
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        executor.transport.playing = true; executor.transport.position = 20
        executor.transport.regionId = playing.id; executor.transport.queuedRegionId = queued.id
        executor.transport.loop.enabled = true
        show.send(.pause)
        let loads = executor.loadCount, snapshots = executor.snapshotCount
        var cancelled = executor.transport; cancelled.queuedRegionId = nil
        executor.regionCommandResult = cancelled
        show.focusRegion(queued.id)
        XCTAssertEqual(executor.regionCommands.last, .queueRegion)
        XCTAssertNil(show.snapshot.transport.queuedRegionId)
        XCTAssertFalse(show.regionSetlist.autoAdvance, "Remote state and desktop Auto must reflect the engine's cancellation")
        XCTAssertTrue(show.hasUnsavedChanges, "Auto preference change must be saved")
        XCTAssertTrue(show.snapshot.transport.playing); XCTAssertTrue(show.snapshot.transport.loop.enabled)
        XCTAssertEqual(executor.loadCount, loads); XCTAssertEqual(executor.snapshotCount, snapshots)
        show.send(.stopAll)
    }
    @MainActor func testDuplicateMarkerCreationIsRejectedBeforeEditingAndAtCommit() throws {
        var project = Project.empty(name: "Duplicate markers")
        var marker = TimelineMarker(id: UUID(), name: "Verse", position: 10, color: 0x51ef93)
        project.songs[0].markers = [marker]
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertFalse(show.canCreateMarker(at: 10))
        XCTAssertEqual(show.modalNotice, "A marker already exists at this position.")
        XCTAssertEqual(show.message, "", "duplicate warnings belong only to the modal")
        var duplicate = marker; duplicate.id = UUID()
        show.setMarker(duplicate)
        XCTAssertEqual(show.current?.markers?.count, 1)
        XCTAssertFalse(show.hasUnsavedChanges)
        marker.name = "Chorus"; show.setMarker(marker)
        XCTAssertEqual(show.current?.markers?.first?.name, "Chorus")
        XCTAssertTrue(show.canCreateMarker(at: 11))
        XCTAssertTrue(show.canCreateMarker(at: 10, tempo: true), "tempo lane and normal markers can coincide")
    }
    @MainActor func testTempoButtonsEditMarkerUnderGreenCursorAndPreserveOtherTiming() throws {
        var project = Project.empty(name: "Tempo buttons")
        let first = TimelineMarker(id: UUID(), name: "A", position: 10, color: 0x999999, tempoBPM: 90, tempoBeats: 3, tempoUnit: 4)
        let second = TimelineMarker(id: UUID(), name: "B", position: 20, color: 0x999999, tempoBPM: 140, tempoBeats: 7, tempoUnit: 8)
        project.songs[0].markers = [second, first]
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        let loads = executor.loadCount
        show.send(.editSeek, value: 10)
        show.adjustTempo(1)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 10)?.tempoBPM, 91)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 19)?.tempoBeats, 3)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 20), second)
        XCTAssertEqual(show.current?.bpm, 120)
        show.send(.editSeek, value: 25)
        show.adjustTempo(-1)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 25)?.tempoBPM, 139)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 25)?.tempoUnit, 8)
        show.adjustTempo(1000)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 25)?.tempoBPM, 300)
        show.adjustTempo(-1000)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 25)?.tempoBPM, 60)
        show.send(.editSeek, value: 5)
        show.adjustTempo(1)
        XCTAssertEqual(show.current?.bpm, 120)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 5)?.tempoBPM, 121)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 25)?.tempoBPM, 60)
        XCTAssertEqual(executor.loadCount, loads, "tempo edits must not reload the project")
    }

    @MainActor func testMarkerUpdatesAreIncrementalAndRefreshAudioOnlyForRelativeTempo() throws {
        for mode in ProjectTimebase.allCases {
            var project = Project.empty(name: "Markers")
            project.songs[0].timeSettings = ProjectTimeSettings(); project.songs[0].timeSettings?.timebase = mode
            let executor = CursorExecutor()
            let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
            let reads = executor.snapshotCount, loads = executor.loadCount
            let transport = show.snapshot.transport
            var audioRevisions: [UInt64] = []; show.audioUpdate = { _,revision in audioRevisions.append(revision) }
            let marker = TimelineMarker(id: UUID(), name: "Entry", position: 20, color: 0x51ef93)
            show.setMarker(marker); XCTAssertEqual(audioRevisions, [0])
            var tempo = TimelineMarker(id: UUID(), name: "TEMPO", position: 340, color: 0x999999, tempoBPM: 180, tempoBeats: 3, tempoUnit: 8)
            show.setMarker(tempo)
            XCTAssertEqual(show.current?.markers?.first?.position, 0)
            XCTAssertEqual(show.current?.markers?.filter { $0.position > 0 }, [marker, tempo]); XCTAssertEqual(show.current?.duration, 340)
            tempo.tempoBPM = 90; show.setMarker(tempo)
            show.deleteManualMarker(tempo.id)
            XCTAssertEqual(audioRevisions, mode == .relative ? [0, 1, 2, 3] : [0, 0, 0, 0])
            XCTAssertEqual(show.current?.markers?.filter { $0.position > 0 }, [marker])
            XCTAssertEqual(executor.snapshotCount, reads); XCTAssertEqual(executor.loadCount, loads)
            XCTAssertEqual(show.snapshot.transport, transport)
            XCTAssertTrue(show.hasUnsavedChanges)
        }
    }
    @MainActor func testTimebaseSwitchRefreshesTempoPlaybackWithoutReloadingProjectOrMovingCursor() throws {
        var project = Project.empty(name: "Timebase switch")
        project.songs[0].timeSettings = .legacy
        project.songs[0].markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 8, color: 0x999999, tempoBPM: 180)]
        var track = Track(id: UUID(), name: "Audio", role: .keys)
        let clip = AudioClip(id: UUID(), name: "Audio", startTime: 4, duration: 20, sourceOffset: 2, playbackRate: 1.25)
        track.clips = [clip]; project.songs[0].tracks = [track]
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        show.send(.editSeek, value: 12)
        let reads = executor.snapshotCount, loads = executor.loadCount, transport = show.snapshot.transport
        var revisions: [UInt64] = []; show.audioUpdate = { _,revision in revisions.append(revision) }
        var settings = ProjectTimeSettings(); settings.timebase = .relative
        XCTAssertTrue(show.configureProjectTime(bpm: 120, beats: 4, unit: 4, settings: settings))
        XCTAssertEqual(show.current?.tempoAudioSegments(clip).map(\.audioRate), [1.25, 1.875])
        settings.timebase = .free
        XCTAssertTrue(show.configureProjectTime(bpm: 120, beats: 4, unit: 4, settings: settings))
        XCTAssertEqual(show.current?.tempoAudioSegments(clip), [clip])
        settings.divisions = 0
        XCTAssertTrue(show.configureProjectTime(bpm: 120, beats: 4, unit: 4, settings: settings))
        XCTAssertEqual(revisions, [1, 2, 2], "switching timebase updates voices, while a grid-only edit keeps them")
        XCTAssertEqual(show.current?.tracks, [track]); XCTAssertEqual(show.snapshot.transport, transport)
        XCTAssertEqual(executor.snapshotCount, reads); XCTAssertEqual(executor.loadCount, loads)
        XCTAssertEqual(show.snapshot.project, executor.project)
    }
    @MainActor func testLocalRelativeAndFreeMarkersRefreshOnlyAudioAffectedByTheirBoundaries() throws {
        let executor = CursorExecutor()
        var project = Project.empty(name: "Local timebase"); project.songs[0].timeSettings = .legacy
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        let reads = executor.snapshotCount, loads = executor.loadCount, transport = show.snapshot.transport
        var revisions: [UInt64] = []; show.audioUpdate = { _,revision in revisions.append(revision) }
        let relative = TimelineMarker(id: UUID(), name: "TEMPO", position: 8, color: 0x999999, tempoBPM: 180, tempoTimebase: .relative)
        var free = TimelineMarker(id: UUID(), name: "TEMPO", position: 16, color: 0x999999, tempoBPM: 60, tempoTimebase: .free)
        show.setMarker(relative); show.setMarker(free)
        free.position = 12; show.setMarker(free)
        show.deleteManualMarker(relative.id); show.deleteManualMarker(free.id)
        var global = TimelineMarker(id: UUID(), name: "TEMPO", position: 20, color: 0x999999, tempoBPM: 180, tempoTimebase: .global)
        show.setMarker(global)
        var settings = ProjectTimeSettings(); settings.timebase = .relative
        XCTAssertTrue(show.configureProjectTime(bpm: 120, beats: 4, unit: 4, settings: settings))
        global.tempoTimebase = .free; show.setMarker(global)
        settings.timebase = .free
        XCTAssertTrue(show.configureProjectTime(bpm: 120, beats: 4, unit: 4, settings: settings))
        XCTAssertEqual(revisions, [1, 2, 3, 4, 4, 4, 5, 6, 7])
        XCTAssertEqual(executor.snapshotCount, reads); XCTAssertEqual(executor.loadCount, loads)
        XCTAssertEqual(show.snapshot.transport, transport)
        XCTAssertEqual(show.snapshot.project, executor.project)
    }
    @MainActor func testProjectionWindowActionsAvoidAudioAndProjectReload() throws {
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: .empty(name: "Window actions"))
        show.performAction(.normalizeItems); XCTAssertEqual(show.normalizeItemsRequest, 1)
        show.performAction(.createTempoMarker); XCTAssertEqual(show.tempoMarkerRequest, 1)
        var videoVisible = false, teleprompterVisible = false, tracksVisible = true, setlistVisible = true, audioUpdates = 0
        show.toggleVideoWindow = { videoVisible.toggle() }
        show.toggleTeleprompterWindow = { teleprompterVisible.toggle() }
        show.toggleTracksPanel = { tracksVisible.toggle() }
        show.toggleSetlistPanel = { setlistVisible.toggle() }
        show.audioUpdate = { _,_ in audioUpdates += 1 }
        let loads = executor.loadCount, snapshots = executor.snapshotCount
        for action in [DAWAction.toggleVideo, .toggleTeleprompter, .toggleTracks, .toggleSetlist] { show.performAction(action) }
        XCTAssertTrue(videoVisible); XCTAssertTrue(teleprompterVisible)
        XCTAssertFalse(tracksVisible); XCTAssertFalse(setlistVisible)
        for action in [DAWAction.toggleVideo, .toggleTeleprompter, .toggleTracks, .toggleSetlist] { show.performAction(action) }
        XCTAssertFalse(videoVisible); XCTAssertFalse(teleprompterVisible)
        XCTAssertTrue(tracksVisible); XCTAssertTrue(setlistVisible)
        XCTAssertEqual(executor.loadCount, loads); XCTAssertEqual(executor.snapshotCount, snapshots)
        XCTAssertEqual(audioUpdates, 0); XCTAssertFalse(show.hasUnsavedChanges)
    }
    @MainActor func testNavigationMovesGreenCursorOnePointAtATimeWithoutReloadingOrInterruptingPlayback() throws {
        var project = Project.empty(name: "Navigation")
        let first = Part(id: UUID(), name: "First", startTime: 30, endTime: 50)
        let special = Part(id: UUID(), name: "Special", startTime: 70, endTime: 110)
        let child = Part(id: UUID(), name: "Child", startTime: 80, endTime: 90, parentRegionID: special.id)
        project.songs[0].parts = [special, child, first]
        project.songs[0].markers = [TimelineMarker(id: UUID(), name: "Child", position: 80, color: 0x54ff93, unifiedRegionID: special.id, sourceRegionID: child.id),
                                    TimelineMarker(id: UUID(), name: "Same point", position: 50, color: 0x54ff93),
                                    TimelineMarker(id: UUID(), name: "Last", position: 140, color: 0x54ff93)]
        project.songs[0].duration = 400
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        let loads = executor.loadCount, snapshots = executor.snapshotCount
        for expected in [30.0, 50, 70, 80, 110, 140] {
            show.performAction(.nextTimelinePoint)
            XCTAssertEqual(show.snapshot.transport.editPosition, expected)
            XCTAssertEqual(show.navigationFocusPosition, expected)
        }
        show.performAction(.nextTimelinePoint)
        XCTAssertEqual(show.snapshot.transport.editPosition, 140, "reaching the last point does not wrap")
        for expected in [110.0, 80, 70, 50, 30] {
            show.performAction(.previousTimelinePoint)
            XCTAssertEqual(show.snapshot.transport.editPosition, expected)
        }
        show.performAction(.projectStart); XCTAssertEqual(show.snapshot.transport.editPosition, 0)
        show.performAction(.nextRegion); XCTAssertEqual(show.snapshot.transport.editPosition, 30)
        show.performAction(.nextRegion); XCTAssertEqual(show.snapshot.transport.editPosition, 70, "unified children are markers rather than additional region bands")
        show.performAction(.previousRegion); XCTAssertEqual(show.snapshot.transport.editPosition, 30)
        show.performAction(.projectEnd); XCTAssertEqual(show.snapshot.transport.editPosition, 140, "end means last marker or region end, ignoring later media and empty grid")
        show.send(.editSeek, value: 32); XCTAssertNil(show.navigationFocusPosition)
        show.send(.play); executor.transport.queuedRegionId = special.id
        show.performAction(.projectEnd)
        XCTAssertTrue(show.snapshot.transport.playing)
        XCTAssertEqual(show.snapshot.transport.editPosition, 140)
        XCTAssertLessThan(show.snapshot.transport.position, 50)
        XCTAssertEqual(show.snapshot.transport.queuedRegionId, special.id)
        XCTAssertEqual(executor.loadCount, loads); XCTAssertEqual(executor.snapshotCount, snapshots)
        XCTAssertFalse(show.hasUnsavedChanges)
        show.send(.stopAll)
    }
    @MainActor func testGridPlaySelectsPlayingRegionWithoutSeekingQueueingOrReloading() throws {
        var project = Project.empty(name: "Grid play")
        let first = Part(id: UUID(), name: "First", startTime: 30, endTime: 40)
        let second = Part(id: UUID(), name: "Second", startTime: 70, endTime: 90)
        project.songs[0].parts = [first, second]; project.songs[0].duration = 100
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        show.focusRegion(first.id)
        executor.regionCommands.removeAll()
        let loads = executor.loadCount, snapshots = executor.snapshotCount
        show.send(.editSeek, value: 75)
        XCTAssertEqual(show.focusedRegion, second.id, "positioning the editing cursor must select the song before Play")
        let request = show.setlistFocusRequest
        show.send(.play)
        XCTAssertEqual(show.focusedRegion, second.id)
        XCTAssertNotEqual(show.setlistFocusRequest, request)
        XCTAssertEqual(show.snapshot.transport.position, 75)
        XCTAssertEqual(show.snapshot.transport.editPosition, 75)
        XCTAssertTrue(executor.regionCommands.isEmpty)
        XCTAssertEqual(executor.loadCount, loads); XCTAssertEqual(executor.snapshotCount, snapshots)
        XCTAssertFalse(show.hasUnsavedChanges)
        show.stepRegion(-1, commitAfterDelay: false)
        show.tick(); show.send(.subPlay)
        XCTAssertEqual(show.focusedRegion, first.id, "ticks and subplay must preserve browsing selection")
        show.send(.stopAll)
        show.send(.editSeek, value: 50); show.send(.play)
        XCTAssertEqual(show.focusedRegion, first.id, "playing a gap must not select an unrelated region")
        show.send(.stopAll)
    }

    @MainActor func testEditingCursorSelectsImmediatelyDuringPlaybackWithoutMovingPlaybackOrQueue() throws {
        var project = Project.empty(name: "Editing while playing")
        let first = Part(id: UUID(), name: "First", startTime: 30, endTime: 40)
        let second = Part(id: UUID(), name: "Second", startTime: 70, endTime: 90)
        project.songs[0].parts = [first, second]; project.songs[0].duration = 100
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        show.send(.editSeek, value: 32); show.send(.play)
        executor.transport.queuedRegionId = second.id
        let loads = executor.loadCount, snapshots = executor.snapshotCount
        let gridRequest = show.regionFocusRequest
        show.send(.editSeek, value: 75)
        XCTAssertEqual(show.focusedRegion, second.id)
        XCTAssertEqual(show.snapshot.transport.editPosition, 75)
        XCTAssertEqual(show.snapshot.transport.regionId, first.id)
        XCTAssertEqual(show.snapshot.transport.queuedRegionId, second.id)
        XCTAssertLessThan(show.snapshot.transport.position, 40, "green cursor movement must not seek the running purple cursor")
        XCTAssertTrue(show.snapshot.transport.playing)
        XCTAssertEqual(show.regionFocusRequest, gridRequest, "revealing the setlist row must not recenter the grid away from the clicked point")
        let request = show.setlistFocusRequest
        show.send(.editSeek, value: 76)
        XCTAssertEqual(show.setlistFocusRequest, request, "movement within the same song must not repeatedly rebuild or scroll the setlist")
        XCTAssertTrue(executor.regionCommands.isEmpty)
        XCTAssertEqual(executor.loadCount, loads); XCTAssertEqual(executor.snapshotCount, snapshots)
        XCTAssertFalse(show.hasUnsavedChanges)
        show.send(.stopAll)
    }

    @MainActor func testGridPlayRevealsUnifiedChildAndSwitchesOnlyAnUnrelatedPlaylist() throws {
        var project = Project.empty(name: "Drawer play")
        let outside = Part(id: UUID(), name: "Outside", startTime: 0, endTime: 10)
        let root = Part(id: UUID(), name: "Special", startTime: 30, endTime: 90)
        let first = Part(id: UUID(), name: "First", startTime: 30, endTime: 65, parentRegionID: root.id)
        let second = Part(id: UUID(), name: "Second", startTime: 60, endTime: 90, parentRegionID: root.id)
        project.songs[0].parts = [outside, root, first, second]; project.songs[0].duration = 100
        let playlist = RegionPlaylist(id: UUID(), name: "Concert", songId: project.songs[0].id, regionIds: [root.id])
        project.regionSetlist = RegionSetlist(playlists: [playlist], selectedId: playlist.id)
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        let loads = executor.loadCount, snapshots = executor.snapshotCount
        show.send(.editSeek, value: 70)
        XCTAssertEqual(show.focusedRegion, second.id, "editing cursor must reveal the unified child before Play")
        show.send(.play)
        XCTAssertEqual(show.focusedRegion, second.id)
        XCTAssertEqual(show.selectedRegionPlaylist?.id, playlist.id)
        XCTAssertEqual(show.snapshot.transport.regionId, root.id)
        XCTAssertFalse(show.hasUnsavedChanges)
        show.send(.stopAll); show.send(.editSeek, value: 5)
        XCTAssertEqual(show.focusedRegion, outside.id)
        XCTAssertNil(show.selectedRegionPlaylist, "a cursor selection outside the playlist must already be visible in All Regions")
        show.send(.play)
        XCTAssertEqual(show.focusedRegion, outside.id)
        XCTAssertNil(show.selectedRegionPlaylist)
        XCTAssertEqual(show.regionSetlist.playlists, [playlist])
        XCTAssertEqual(show.snapshot.transport.position, 5)
        XCTAssertTrue(executor.regionCommands.isEmpty)
        XCTAssertEqual(executor.loadCount, loads); XCTAssertEqual(executor.snapshotCount, snapshots)
        show.send(.stopAll)
    }

    @MainActor func testSpecialSelectionUsesFirstChildPitchAndPlaybackUsesCurrentChild() throws {
        var project = Project.empty(name: "Pitch display")
        let group = Part(id: UUID(), name: "Special", startTime: 0, endTime: 30)
        let first = Part(id: UUID(), name: "First", startTime: 0, endTime: 20, parentRegionID: group.id, pitchSemitones: 4)
        let last = Part(id: UUID(), name: "Last", startTime: 15, endTime: 30, parentRegionID: group.id, pitchSemitones: -2)
        project.songs[0].parts = [group, last, first]
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        show.focusRegion(group.id)
        XCTAssertEqual(show.pitchRegion?.id, first.id); XCTAssertEqual(show.pitchRegion?.semitones, 4)
        show.focusRegion(last.id)
        XCTAssertEqual(show.pitchRegion?.semitones, -2)
        executor.transport.playing = true; executor.transport.position = 18; executor.transport.regionId = group.id
        show.send(.ignoreNext)
        XCTAssertEqual(show.pitchRegion?.id, last.id)
    }

    @MainActor func testStopPublishesOnlyFinalAudioState() throws {
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: .empty(name: "Transport"))
        var renderedStates: [Bool] = []
        show.audioUpdate = { snapshot, _ in renderedStates.append(snapshot.transport.playing) }
        show.send(.play)
        XCTAssertEqual(renderedStates, [true])
        renderedStates.removeAll()
        show.send(.stop)
        XCTAssertEqual(renderedStates, [false], "Stop must not schedule a redundant playing update before stopping")
        XCTAssertFalse(show.isPlaying)
    }

    @MainActor func testReopeningRemembersEditingCursorWithoutSavingOrAutoplay() throws {
        let suite = "jaras-test-cursor-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = Project.empty(name: "One")
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project, cursorMemory: ProjectCursorMemory(preferences: defaults))
        show.send(.editSeek, value: 42.125)
        XCTAssertFalse(show.hasUnsavedChanges, "navigation is local workspace state")
        show.send(.play)
        executor.advance(12)
        show.tick()
        show.send(.stop)
        let reopened = try ShowController(executor: CursorExecutor(), persistence: MemoryProjectStore(), initialProject: project, cursorMemory: ProjectCursorMemory(preferences: defaults))
        XCTAssertEqual(reopened.snapshot.transport.editPosition, 42.125)
        XCTAssertEqual(reopened.snapshot.transport.position, 42.125)
        XCTAssertEqual(reopened.restoredCursorPosition, 42.125)
        XCTAssertFalse(reopened.isPlaying)
        let other = Project.empty(name: "Two")
        try reopened.replaceProject(other)
        XCTAssertEqual(reopened.snapshot.transport.position, 0)
        reopened.send(.editSeek, value: 17)
        try reopened.replaceProject(project)
        XCTAssertEqual(reopened.snapshot.transport.position, 42.125)
        try reopened.replaceProject(other)
        XCTAssertEqual(reopened.snapshot.transport.position, 17)
    }
    @MainActor func testSavedCursorClampsToProjectEndAndIgnoresInvalidPosition() throws {
        let suite = "jaras-test-cursor-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = ProjectCursorMemory(preferences: defaults)
        let project = Project.empty(name: "Shortened")
        memory.remember(project: project.id, songID: project.songs[0].id, position: project.songs[0].duration + 90)
        memory.remember(project: project.id, songID: project.songs[0].id, position: .nan)
        let show = try ShowController(executor: CursorExecutor(), persistence: MemoryProjectStore(), initialProject: project, cursorMemory: memory)
        XCTAssertEqual(show.snapshot.transport.position, project.songs[0].duration)
        XCTAssertFalse(show.isPlaying)
    }
}
