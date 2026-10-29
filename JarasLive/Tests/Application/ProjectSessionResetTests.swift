import XCTest
@testable import JarasApplication

@MainActor private final class SessionResetExecutor: CommandExecutor {
    var project = Project.empty(name: "Session")
    var transport = TransportState(playing: false, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    var syncMixer: ProjectSyncMixer?
    func applyProjectSync(_ data: Data, elapsed: Double, first: Bool) throws -> PlaybackSnapshot {
        PlaybackSnapshot(transport: transport, syncMixer: syncMixer)
    }
    var rejectLoad = false
    var commands: [ShowCommand] = []
    func setProjectSyncID(_ id: UUID) { if project.projectSyncID == nil { project.projectSyncID = id } }
    func load(_ project: Project) throws {
        if rejectLoad { throw ProjectError.invalid("Injected load failure") }
        self.project = project
        transport = TransportState(playing: false, songId: project.songs.first?.id, position: 0,
            queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func applyProjectEdit(_ project: Project) throws { self.project = project }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        commands.append(command)
        switch command {
        case .play: transport.playing = true
        case .stop, .stopAll: transport.playing = false; transport.subPlay.playing = false
        case .subSeek: transport.subPlay.position = value
        case .editSeek: transport.editPosition = value; transport.position = value
        case .toggleMultiLoopBypass: transport.multiLoopsBypassed = !(transport.multiLoopsBypassed == true)
        case .volume, .pan:
            if let target, let index = project.songs[0].tracks.firstIndex(where: { $0.id == target }) {
                if command == .volume { project.songs[0].tracks[index].volume = value }
                else { project.songs[0].tracks[index].pan = value }
            } else if target == nil {
                if command == .volume { project.masterVolume = value }
                else { project.masterPan = value }
            }
        case .tempo: project.songs[0].bpm = value
        default: break
        }
    }
    func advance(_ elapsed: Double) { if transport.playing { transport.position += elapsed } }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func finishCurrentSong(_ enabled: Bool) {}
}

private actor SuspendedSessionSave: ProjectPersistence {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func load() async throws -> Project? { nil }
    func save(_ project: Project) async throws {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

final class ProjectSessionResetTests: XCTestCase {
    private func project() -> Project {
        var project = Project.empty(name: "Session reset")
        project.songs[0].duration = 30
        project.songs[0].parts = [Part(id: UUID(), name: "Song", startTime: 0, endTime: 30)]
        project.songs[0].tracks = [Track(id: UUID(), name: "First", role: .other), Track(id: UUID(), name: "Second", role: .other)]
        return project
    }
    @MainActor private func replace(_ show: ShowController, with project: Project, importing: Bool) throws {
        if importing { try show.importProject(ProjectDocumentCodec.encode(project)) }
        else { try show.replaceProject(project) }
    }

    @MainActor func testProjectSyncUpdatesSelectionAndMixerWithoutRequeueingOrReloadingAudio() throws {
        let project = project(), executor = SessionResetExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        let track = project.songs[0].tracks[0].id, region = project.songs[0].parts[0].id
        executor.syncMixer = ProjectSyncMixer(masterVolume: 0.6, masterPan: -0.25, masterMute: true, masterSolo: true,
            tracks: [.init(id: track, volume: 0.3, pan: 0.5, mute: true, solo: true)])
        var volumes: [Double] = [], pans: [Double] = [], mutes: [Bool] = [], solos: [Bool] = []
        show.audioVolume = { _, value in volumes.append(value) }
        show.audioPan = { _, value in pans.append(value) }
        show.audioMute = { _, value in mutes.append(value) }
        show.audioSolo = { _, value in solos.append(value) }
        let before = show.setlistFocusRequest
        try show.applyProjectSync(Data(), elapsed: 0, first: true, focused: region)
        XCTAssertEqual(show.focusedRegion, region)
        XCTAssertNotEqual(show.setlistFocusRequest, before)
        XCTAssertEqual(show.snapshot.project.masterVolume, 0.6)
        XCTAssertEqual(show.snapshot.project.songs[0].tracks[0].volume, 0.3)
        XCTAssertEqual(show.snapshot.project.songs[0].tracks[0].pan, 0.5)
        XCTAssertTrue(show.snapshot.project.songs[0].tracks[0].mute)
        XCTAssertTrue(show.snapshot.project.songs[0].tracks[0].solo)
        XCTAssertEqual(volumes, [0.6, 0.3]); XCTAssertEqual(pans, [0.5])
        XCTAssertEqual(mutes, [true, true]); XCTAssertEqual(solos, [true])
        let selected = show.setlistFocusRequest
        try show.applyProjectSync(Data(), elapsed: 0, first: false, focused: region)
        XCTAssertEqual(show.setlistFocusRequest, selected)
        XCTAssertEqual(volumes, [0.6, 0.3]); XCTAssertEqual(pans, [0.5])
        XCTAssertTrue(executor.commands.isEmpty, "Replicated focus must not select/queue the song again")
        try show.applyProjectSync(Data(), elapsed: 0, first: false, focused: nil)
        XCTAssertNil(show.focusedRegion)
    }

    @MainActor func testReloadAndImportSameIDsClearSelectionGesturesAndPendingUI() throws {
        for importing in [false, true] {
            let project = project(), executor = SessionResetExecutor()
            let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
            let tracks = project.songs[0].tracks, region = project.songs[0].parts[0].id
            show.performAction(.selectTrack, trackNumber: 1)
            show.setMixerTrackSelection(Set(tracks.map(\.id)), anchor: tracks[0].id)
            show.sendMixerControl(.pan, target: tracks[0].id, value: 0.4, preview: true)
            show.performAction(.setlistDown)
            show.performAction(.splitItems); show.performAction(.normalizeItems)
            show.performAction(.reRenderItems)
            show.performAction(.createTempoMarker); show.performAction(.addTrack)
            show.detectBPMRegion = region; show.detectBPMRegions = [region]
            show.modalNotice = "Old modal"
            show.selectTimelineRegion(region)
            show.send(.subSeek, value: 4)
            XCTAssertTrue(show.subCursorPreview)
            XCTAssertFalse(show.mixerPreviewValues.isEmpty)
            try replace(show, with: project, importing: importing)
            XCTAssertTrue(show.mixerTrackSelection.isEmpty)
            XCTAssertNil(show.selectedTrackForActions)
            XCTAssertTrue(show.mixerPreviewValues.isEmpty)
            XCTAssertFalse(show.mixerPreviewIsPan)
            XCTAssertNil(show.trackSelectionRequest); XCTAssertNil(show.setlistNavigationRequest)
            XCTAssertNil(show.detectBPMRegion); XCTAssertTrue(show.detectBPMRegions.isEmpty)
            XCTAssertNil(show.modalNotice); XCTAssertFalse(show.subCursorPreview)
            XCTAssertNil(show.selectedTimelineRegion); XCTAssertFalse(show.timelineFollowPaused)
            XCTAssertEqual(show.splitItemsRequest, 0); XCTAssertEqual(show.normalizeItemsRequest, 0)
            XCTAssertNil(show.itemProcessingRequest)
            XCTAssertEqual(show.tempoMarkerRequest, 0); XCTAssertEqual(show.addTrackRequest, 0)
            show.sendMixerControl(.volume, target: tracks[0].id, value: 0.4)
            XCTAssertEqual(show.current?.tracks[0].volume, 0.4)
            XCTAssertEqual(show.current?.tracks[1].volume, tracks[1].volume,
                           "A new session must not retain the previous multi-selection")
        }
    }

    @MainActor func testReloadAndImportReleaseOldAutomationWithoutWritingItIntoNewSession() throws {
        for importing in [false, true] {
            var project = project()
            var automation = TrackAutomation(); automation.mode = .latch
            var envelope = TrackEnvelope(target: AutomationTarget(.volume), name: "Master", defaultValue: 0.7)
            envelope.armed = true; automation.envelopes = [envelope]
            project.masterAutomation = automation
            let executor = SessionResetExecutor()
            let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
            defer { show.send(.stopAll) }
            var overrides: [UUID: Double] = [:]
            show.audioAutomationOverride = { _, envelope, value in overrides[envelope] = value }
            show.send(.play)
            XCTAssertTrue(show.recordAutomationControl(nil, target: AutomationTarget(.volume), value: 0.3))
            XCTAssertFalse(show.automation(nil).envelopes[0].points.isEmpty)
            XCTAssertFalse(overrides.isEmpty)
            try replace(show, with: project, importing: importing)
            XCTAssertEqual(show.automation(nil), automation)
            XCTAssertTrue(overrides.isEmpty, "Old Touch/Latch/Write overrides must be released")
            show.finishAutomationRecording()
            XCTAssertEqual(show.snapshot.project.masterAutomation, automation,
                           "Discarded recording must never overwrite the reloaded document")
        }
    }

    @MainActor func testOpeningSessionClearsTapHistoryButPreservesGlobalAuthorizationAndBypass() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: ShowController.multiLoopBypassDefaultsKey)
        let project = project(), executor = SessionResetExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project, globalDefaults: defaults)
        show.tapTempo(at: 10)
        try show.replaceProject(project)
        show.tapTempo(at: 11)
        XCTAssertFalse(show.hasUnsavedChanges, "One tap in the new session must not reuse the previous interval")
        XCTAssertTrue(show.snapshot.transport.multiLoopsBypassed == true)
        show.finishCurrentSong(true)
        try show.replaceProject(project)
        let before = executor.commands.count
        show.send(.play); show.sendMixerControl(.volume, target: nil, value: 0.4)
        XCTAssertEqual(executor.commands.count, before, "Authorization restrictions are global, not reset by opening a document")
    }

    @MainActor func testFailedLoadKeepsTheCurrentSessionIntact() async throws {
        let project = project(), executor = SessionResetExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        show.setMixerTrackSelection([project.songs[0].tracks[0].id], anchor: project.songs[0].tracks[0].id)
        show.modalNotice = "Current notice"
        try await show.flushProject()
        let saved = show.lastSavedAt
        let savedProject = show.snapshot.project
        XCTAssertNotNil(saved)
        executor.rejectLoad = true
        XCTAssertThrowsError(try show.replaceProject(.empty(name: "Rejected")))
        XCTAssertEqual(show.snapshot.project, savedProject)
        XCTAssertEqual(show.lastSavedAt, saved)
        XCTAssertEqual(show.modalNotice, "Current notice")
        XCTAssertEqual(show.mixerTrackSelection, [project.songs[0].tracks[0].id])
    }

    @MainActor func testOldSaveCompletionCannotUpdateReopenedDocumentWithSameProjectID() async throws {
        let project = project(), store = SuspendedSessionSave()
        let show = try ShowController(executor: SessionResetExecutor(), persistence: store, initialProject: project)
        let saving = Task { try await show.flushProject() }
        while !(await store.started) { await Task.yield() }
        try show.replaceProject(project)
        await store.resume()
        try await saving.value
        XCTAssertNil(show.lastSavedAt, "An earlier session's save must not publish into the reopened session")
    }
}
