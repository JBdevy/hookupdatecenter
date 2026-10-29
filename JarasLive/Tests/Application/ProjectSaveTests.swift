import XCTest
@testable import JarasApplication

@MainActor private final class SaveTestExecutor: CommandExecutor {
    var project = Project.empty(name: "Save test")
    var snapshotCount = 0
    var gainCommands = 0
    var projectEditCount = 0
    var failsGain = false
    var clipFXCommands = 0
    var failsClipFX = false
    var clipBypassCommands = 0
    var regionSelections: [UUID] = []
    var regionCommands: [ShowCommand] = []
    var playing = false
    var playCommands = 0
    var tempoBatches = 0
    var advancedTime = 0.0
    var timeAtTempoEdit = 0.0
    var regionItems: [UUID] = []
    func regionsFromClips(_ ids: [UUID]) throws { regionItems = ids }
    func setProjectSyncID(_ id: UUID) { if project.projectSyncID == nil { project.projectSyncID = id } }
    func load(_ project: Project) throws { self.project = project }
    func snapshot() throws -> ShowSnapshot {
        snapshotCount += 1
        return ShowSnapshot(project: project, transport: TransportState(playing: playing, songId: project.songs.first?.id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: TransportState(playing: playing, songId: project.songs.first?.id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))) }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        if command == .play { playCommands += 1 }
        if command == .selectRegion || command == .queueRegion, let target { regionSelections.append(target); regionCommands.append(command) }
        if [.clipGain, .clipNormalization, .clipFadeIn, .clipFadeOut].contains(command), let target {
            if failsGain { throw ProjectError.invalid("Gain command rejected") }
            for song in project.songs.indices {
                for track in project.songs[song].tracks.indices {
                    if let index = project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == target }) {
                        if command == .clipFadeIn { project.songs[song].tracks[track].clips[index].fadeIn = value }
                        else if command == .clipFadeOut { project.songs[song].tracks[track].clips[index].fadeOut = value }
                        else if command == .clipNormalization { project.songs[song].tracks[track].clips[index].normalizationGain = value }
                        else { project.songs[song].tracks[track].clips[index].gain = value }; gainCommands += 1; return
                    }
                }
            }
            throw ProjectError.invalid("Missing item")
        }
    }
    func replaceAudioClip(_ clip: AudioClip, track: UUID) throws {
        guard let channel = project.songs[0].tracks.firstIndex(where: { $0.id == track }),
              let item = project.songs[0].tracks[channel].clips.firstIndex(where: { $0.id == clip.id }) else { throw ProjectError.invalid("Missing item") }
        project.songs[0].tracks[channel].clips[item] = clip
    }
    func retimeTempoMarkers(_ markers: [TimelineMarker]) throws {
        timeAtTempoEdit = advancedTime
        let before = project.songs[0]
        try setTempoMarkers(markers)
        let map = TempoEditMap(before: before, after: project.songs[0])
        map.apply(to: &project.songs[0]); tempoBatches += 1
    }
    func setTempoMarkers(_ markers: [TimelineMarker]) throws { try setTempoMarkers(markers, removing: []) }
    func setMarker(_ marker: TimelineMarker) throws {
        if project.songs[0].markers == nil { project.songs[0].markers = [] }
        if let index = project.songs[0].markers!.firstIndex(where: { $0.id == marker.id }) { project.songs[0].markers![index] = marker }
        else { project.songs[0].markers!.append(marker) }
    }
    func setTempoMarkers(_ markers: [TimelineMarker], removing: [UUID]) throws {
        if project.songs[0].markers == nil { project.songs[0].markers = [] }
        project.songs[0].markers!.removeAll { removing.contains($0.id) || markers.map(\.id).contains($0.id) }
        project.songs[0].markers!.append(contentsOf: markers)
    }
    func applyProjectEdit(_ project: Project) throws { self.project = project; projectEditCount += 1 }
    func setFX(_ id: UUID?, settings: NativeFXSettings) throws {
        try settings.validate()
        if let id {
            guard let index = project.songs[0].tracks.firstIndex(where: { $0.id == id }) else { throw ProjectError.invalid("Missing track") }
            project.songs[0].tracks[index].fx = settings
        } else { project.masterFX = settings }
    }
    func setClipFX(_ id: UUID, settings: NativeFXSettings) throws {
        try settings.validateForClip()
        if failsClipFX { throw ProjectError.invalid("FX command rejected") }
        for song in project.songs.indices {
            for track in project.songs[song].tracks.indices where project.songs[song].tracks[track].kind == .standard {
                if let index = project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == id }) {
                    project.songs[song].tracks[track].clips[index].fx = settings; clipFXCommands += 1; return
                }
            }
        }
        throw ProjectError.invalid("Missing item")
    }
    func setClipFXBypass(_ id: UUID, bypassed: Bool) throws {
        if failsClipFX { throw ProjectError.invalid("FX command rejected") }
        for song in project.songs.indices {
            for track in project.songs[song].tracks.indices where project.songs[song].tracks[track].kind == .standard {
                if let index = project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == id }) {
                    project.songs[song].tracks[track].clips[index].fxBypassed = bypassed
                    clipBypassCommands += 1; return
                }
            }
        }
        throw ProjectError.invalid("Missing item")
    }
    func addTrack(id: UUID, name: String, role: TrackRole) throws { project.songs[0].tracks.append(Track(id: id, name: name, role: role)) }
    func addRecordedClip(_ clip: AudioClip, track: UUID) throws {
        guard let index = project.songs[0].tracks.firstIndex(where: { $0.id == track }) else { throw ProjectError.invalid("Missing track") }
        project.songs[0].tracks[index].clips.append(clip)
    }
    func reorderTrack(_ id: UUID, before: UUID?) throws {
        guard let index = project.songs[0].tracks.firstIndex(where: { $0.id == id }) else { throw ProjectError.invalid("Missing track") }
        let track = project.songs[0].tracks.remove(at: index)
        let destination = before.flatMap { target in project.songs[0].tracks.firstIndex { $0.id == target } } ?? project.songs[0].tracks.count
        project.songs[0].tracks.insert(track, at: destination)
    }
    func configureRegionSetlist(_ state: RegionSetlist) throws { project.regionSetlist = state; try project.validate() }
    func advance(_ elapsed: Double) { if playing { advancedTime += elapsed } }
    func finishCurrentSong(_ enabled: Bool) {}
}
private actor SaveTestStore: ProjectPersistence {
    let fails: Bool
    private(set) var lastProject: Project?
    init(fails: Bool = false) { self.fails = fails }
    func load() async throws -> Project? { nil }
    func save(_ project: Project) async throws {
        try await Task.sleep(nanoseconds: 30_000_000)
        if fails { throw ProjectError.invalid("Disk unavailable") }
        lastProject = project
    }
}
final class ProjectSaveTests: XCTestCase {
    @MainActor func testProjectSyncIdentityIsCreatedBySaveAndRemainsStable() async throws {
        let project = Project.empty(name: "Sync identity")
        let executor = SaveTestExecutor(), store = MemoryProjectStore()
        let show = try ShowController(executor: executor, persistence: store, initialProject: project)
        XCTAssertNil(show.snapshot.project.projectSyncID)
        try await show.flushProject()
        let id = try XCTUnwrap(show.snapshot.project.projectSyncID)
        let saved = await store.load()
        XCTAssertEqual(saved?.projectSyncID, id)
        XCTAssertEqual(executor.project.projectSyncID, id)
        try await show.flushProject()
        let savedAgain = await store.load()
        XCTAssertEqual(savedAgain?.projectSyncID, id)
        let bytes = try ProjectDocumentCodec.encode(try XCTUnwrap(savedAgain))
        XCTAssertEqual(try ProjectDocumentCodec.decode(bytes).projectSyncID, id)
    }

    private func markerOwnershipProject() -> Project {
        var project = Project.empty(name: "Marker ownership")
        project.songs[0].duration = 60
        project.songs[0].regionOwnershipInitialized = true
        project.songs[0].parts = [Part(id: UUID(), name: "Delete", startTime: 10, endTime: 30),
                                  Part(id: UUID(), name: "Keep", startTime: 30, endTime: 50)]
        project.songs[0].markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 0, color: 0, tempoBPM: 120, tempoTimebase: .free)]
        return project
    }
    @MainActor func testAllRegionsDeletionPreservesCreatedMarkersAndUndoRestoresOwnership() throws {
        var project = markerOwnershipProject()
        let first = project.songs[0].parts[0], next = project.songs[0].parts[1]
        let loose = TimelineMarker(id: UUID(), name: "Loose", position: 21, color: 0)
        let foreign = TimelineMarker(id: UUID(), name: "Other song", position: 24, color: 0, regionOwnerID: next.id, tempoBPM: 95, tempoTimebase: .free)
        project.songs[0].markers! += [loose, foreign]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let placed = [TimelineMarker(id: UUID(), name: "TEMPO", position: 10, color: 0, tempoBPM: 130, tempoTimebase: .free),
                      TimelineMarker(id: UUID(), name: "TEMPO", position: 15, color: 0, tempoBPM: 150, tempoTimebase: .free),
                      TimelineMarker(id: UUID(), name: "Cue", position: 16, color: 0),
                      TimelineMarker(id: UUID(), name: "$VERSE", position: 17, color: 0),
                      TimelineMarker(id: UUID(), name: "*LOOP", position: 18, color: 0)]
        for marker in placed { show.setMarker(marker) }
        let boundary = TimelineMarker(id: UUID(), name: "Next tempo", position: 30, color: 0, tempoBPM: 90, tempoTimebase: .free)
        show.setMarker(boundary)
        var renamed = placed[1]; renamed.name = "Edited BPM"; renamed.tempoBPM = 151
        show.setMarker(renamed) // Incoming editor value has no owner.
        for marker in placed {
            XCTAssertEqual(show.current?.markers?.first { $0.id == marker.id }?.regionOwnerID, first.id)
        }
        XCTAssertEqual(show.current?.markers?.first { $0.id == boundary.id }?.regionOwnerID, next.id)
        XCTAssertEqual(executor.project.songs[0].markers, show.current?.markers)
        let beforeDelete = show.snapshot.project
        let restored = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(beforeDelete))
        XCTAssertEqual(restored.songs[0].markers, beforeDelete.songs[0].markers)
        XCTAssertTrue(show.deleteSetlistEntries([first.id]))
        XCTAssertEqual(show.current?.parts.map(\.id), [next.id])
        XCTAssertEqual(Set(show.current?.markers?.map(\.id) ?? []), Set(beforeDelete.songs[0].markers!.map(\.id)))
        XCTAssertFalse(show.current?.markers?.contains { $0.regionOwnerID == first.id } ?? true)
        show.undo(); XCTAssertEqual(show.current?.markers, beforeDelete.songs[0].markers)
        show.redo(); XCTAssertEqual(Set(show.current?.markers?.map(\.id) ?? []), Set(beforeDelete.songs[0].markers!.map(\.id)))
        XCTAssertFalse(show.current?.markers?.contains { $0.regionOwnerID == first.id } ?? true)
    }
    @MainActor func testTempoAdjustmentAttachesNewBoundariesToCorrectSongs() throws {
        var project = markerOwnershipProject()
        let first = project.songs[0].parts[0], next = project.songs[0].parts[1]
        let inside = TimelineMarker(id: UUID(), name: "TEMPO", position: 20, color: 0, regionOwnerID: first.id, tempoBPM: 140, tempoTimebase: .free)
        let loose = TimelineMarker(id: UUID(), name: "Unattached tempo", position: 22, color: 0, tempoBPM: 150, tempoTimebase: .free)
        project.songs[0].markers! += [inside, loose]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        show.focusRegion(first.id); show.adjustTempo(1)
        XCTAssertEqual(show.current?.markers?.first { $0.position == 10 }?.regionOwnerID, first.id)
        XCTAssertEqual(show.current?.markers?.first { $0.position == 30 }?.regionOwnerID, next.id)
        XCTAssertEqual(show.current?.markers?.first { $0.id == inside.id }?.regionOwnerID, first.id)
        XCTAssertNil(show.current?.markers?.first { $0.id == loose.id }?.regionOwnerID)
        XCTAssertEqual(executor.project.songs[0].markers, show.current?.markers)
        XCTAssertTrue(show.deleteSetlistEntries([first.id]))
        XCTAssertEqual(Set(show.current?.markers?.map(\.position) ?? []), [0, 10, 20, 22, 30])
        XCTAssertFalse(show.current?.markers?.contains { $0.regionOwnerID == first.id } ?? true)
    }
    @MainActor func testRedetectedTempoReplacesOldMarkersAndAssignsRegionOwnership() throws {
        var project = markerOwnershipProject()
        let first = project.songs[0].parts[0], next = project.songs[0].parts[1]
        let owned = TimelineMarker(id: UUID(), name: "Owned tempo", position: 20, color: 0, regionOwnerID: first.id, tempoBPM: 140, tempoTimebase: .free)
        let loose = TimelineMarker(id: UUID(), name: "Loose tempo", position: 22, color: 0, tempoBPM: 140, tempoTimebase: .free)
        project.songs[0].markers! += [owned, loose]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let detected = [10.0, 15, 20, 22, 30].map { TimelineMarker(id: UUID(), name: "TEMPO", position: $0, color: 0, tempoBPM: 125, tempoTimebase: .free) }
        XCTAssertTrue(show.applyDetectedTempo(detected, project: project.id, song: project.songs[0].id, region: first.id))
        for position in [10.0, 15, 20] {
            XCTAssertEqual(show.current?.markers?.first { $0.position == position }?.regionOwnerID, first.id)
        }
        XCTAssertNotEqual(show.current?.markers?.first { $0.position == 20 }?.id, owned.id)
        XCTAssertEqual(show.current?.markers?.first { $0.position == 22 }?.regionOwnerID, first.id)
        XCTAssertEqual(show.current?.markers?.first { $0.position == 30 }?.regionOwnerID, next.id)
        XCTAssertEqual(executor.project.songs[0].markers?.sorted { $0.position < $1.position }, show.current?.markers?.sorted { $0.position < $1.position })
        XCTAssertTrue(show.deleteSetlistEntries([first.id]))
        XCTAssertEqual(Set(show.current?.markers?.map(\.position) ?? []), [0, 10, 15, 20, 22, 30])
        XCTAssertFalse(show.current?.markers?.contains { $0.regionOwnerID == first.id } ?? true)
    }
    @MainActor func testMovingMarkerAttachesItButEditingInPlaceDoesNotCaptureLooseMaterial() throws {
        var project = markerOwnershipProject()
        let first = project.songs[0].parts[0]
        var loose = TimelineMarker(id: UUID(), name: "TEMPO", position: 15, color: 0, tempoBPM: 120, tempoTimebase: .free)
        project.songs[0].markers!.append(loose)
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: project)
        loose.tempoBPM = 130; show.setMarker(loose)
        XCTAssertNil(show.current?.markers?.first { $0.id == loose.id }?.regionOwnerID)
        loose.position = 16; show.setMarker(loose)
        XCTAssertEqual(show.current?.markers?.first { $0.id == loose.id }?.regionOwnerID, first.id)
        XCTAssertTrue(show.deleteSetlistEntries([first.id]))
        XCTAssertEqual(show.current?.markers?.first { $0.id == loose.id }?.position, 16)
        XCTAssertNil(show.current?.markers?.first { $0.id == loose.id }?.regionOwnerID)
    }
    @MainActor func testRegionFromTimeSelectionPreservesExactBoundsAndSupportsUndo() throws {
        let project = Project.empty(name: "Time selection")
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: project)
        let song = project.songs[0].id
        show.regionFromTimeSelection(song: song, start: 12.125, end: 21.875)
        let region = try XCTUnwrap(show.current?.parts.first)
        XCTAssertEqual(region.startTime, 12.125); XCTAssertEqual(region.endTime, 21.875)
        XCTAssertEqual(show.focusedRegion, region.id); XCTAssertTrue(show.hasUnsavedChanges)
        XCTAssertEqual(show.current?.tracks, project.songs[0].tracks)
        show.undo(); XCTAssertEqual(show.current?.parts, [])
        show.redo(); XCTAssertEqual(show.current?.parts, [region])
        show.regionFromTimeSelection(song: song, start: 12.125, end: 50)
        XCTAssertEqual(show.current?.parts, [region]); XCTAssertNotNil(show.modalNotice)
        for (start, end) in [(0.0, 0.0), (20, 10), (-1, 10), (.nan, 10), (0, .infinity)] {
            show.regionFromTimeSelection(song: song, start: start, end: end)
        }
        show.regionFromTimeSelection(song: UUID(), start: 30, end: 40)
        XCTAssertEqual(show.current?.parts, [region])
    }
    @MainActor func testItemFXManagerRequiresExplicitInsertionBeforeEditing() throws {
        var project = Project.empty(name: "Item FX manager")
        var track = Track(id: UUID(), name: "Audio", role: .other)
        let clip = AudioClip(id: UUID(), name: "Stem", startTime: 30, duration: 10)
        track.clips = [clip]; project.songs[0].tracks = [track]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let original = show.snapshot.project, snapshots = executor.snapshotCount
        let defaults = show.clipFXSettings(clip.id)
        for _ in 0..<10 { XCTAssertEqual(show.clipFXSettings(clip.id), defaults) }
        for effect in NativeFXSettings.order.dropFirst() { XCTAssertFalse(defaults.isEnabled(effect)) }
        XCTAssertTrue(defaults.inserted.isEmpty)
        XCTAssertEqual(show.snapshot.project, original)
        XCTAssertFalse(show.hasUnsavedChanges); XCTAssertFalse(show.canUndo)
        XCTAssertEqual(executor.snapshotCount, snapshots); XCTAssertEqual(executor.clipFXCommands, 0)
        var eq = defaults; eq.bands[1].gain = 4
        show.updateClipFX(clip.id, effect: "EQ", settings: eq)
        XCTAssertFalse(show.clipFXSettings(clip.id).eqEnabled)
        XCTAssertTrue(show.clipFXSettings(clip.id).inserted.isEmpty)
        eq.eqEnabled = true
        show.updateClipFX(clip.id, effect: "EQ", settings: eq); show.commitFX()
        XCTAssertEqual(show.snapshot.project, original, "Controls for an absent effect must never insert it")
        XCTAssertFalse(show.hasUnsavedChanges); XCTAssertFalse(show.canUndo)
        XCTAssertEqual(executor.clipFXCommands, 0)
        XCTAssertEqual(show.insertClipFX(clip.id, effect: "EQ"), "EQ")
        show.updateClipFX(clip.id, effect: "EQ", settings: eq); show.commitFX()
        XCTAssertEqual(show.clipFXSettings(clip.id).inserted, ["EQ"])
        XCTAssertEqual(show.clipFXSettings(clip.id).bands[1].gain, 4)
        XCTAssertFalse(show.clipFXSettings(clip.id).compressorEnabled)
    }
    @MainActor func testClosingRemovedItemEditorsCannotReinsertEffectsDuringPlayback() throws {
        var project = Project.empty(name: "Removed item effects")
        var track = Track(id: UUID(), name: "Audio", role: .other)
        let clip = AudioClip(id: UUID(), name: "Stem", startTime: 0, duration: 10)
        track.clips = [clip]; project.songs[0].tracks = [track]
        let executor = SaveTestExecutor(); executor.playing = true
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        defer { show.send(.stopAll) }
        let transport = show.snapshot.transport
        XCTAssertNil(show.insertClipFX(clip.id, effect: NativeFXSettings.stemSeparator))
        XCTAssertFalse(show.hasUnsavedChanges)
        for kind in ["EQ", "Delay", "CatLive Trigger", "Cat Gate"] {
            let effect = try XCTUnwrap(show.insertClipFX(clip.id, effect: kind))
            let repeated = try XCTUnwrap(show.insertClipFX(clip.id, effect: kind))
            for key in Set([effect, repeated]) {
                let stale = show.clipFXSettings(clip.id).settings(for: key)
                show.removeClipFX(clip.id, effect: key)
                let removed = show.snapshot.project, commands = executor.clipFXCommands, revision = show.projectRevision
                show.updateClipFX(clip.id, effect: key, settings: stale); show.commitFX()
                XCTAssertEqual(show.snapshot.project, removed, "An outgoing editor must not recreate a removed insert")
                XCTAssertEqual(executor.clipFXCommands, commands)
                XCTAssertEqual(show.projectRevision, revision)
                XCTAssertEqual(show.snapshot.transport, transport)
            }
        }
    }
    @MainActor func testAllItemFXBypassPreservesParametersTransportAndFailedWrites() throws {
        var project = Project.empty(name: "Chain bypass")
        var track = Track(id: UUID(), name: "Audio", role: .other)
        var effects = NativeFXSettings(); effects.inserted = ["EQ", "Delay"]
        effects.eqEnabled = true; effects.delayEnabled = true; effects.feedback = 42
        let repeatedDelay = effects.appendNative("Delay")
        var repeatedSettings = effects.settings(for: repeatedDelay); repeatedSettings.delayTime = 0.875
        effects = effects.merging(effect: repeatedDelay, from: repeatedSettings)
        effects.setEnabled(repeatedDelay, enabled: false)
        var plugin = ExternalPlugin(classID: String(repeating: "C", count: 32), name: "Take FX", path: "/Library/Audio/Plug-Ins/VST3/Take.vst3")
        plugin.componentState = "retained-preset"
        effects.externalPlugins = [plugin]; effects.inserted.append(plugin.effectKey)
        let clip = AudioClip(id: UUID(), name: "Stem", startTime: 30, duration: 10, fx: effects)
        track.clips = [clip]; project.songs[0].tracks = [track]
        let executor = SaveTestExecutor(); executor.playing = true
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let transport = show.snapshot.transport, snapshots = executor.snapshotCount
        var calls: [Bool] = []
        show.audioClipFXBypass = { id, value in XCTAssertEqual(id, clip.id); calls.append(value) }
        show.toggleClipFXAllBypass(clip.id)
        XCTAssertEqual(show.current?.tracks[0].clips[0].fxBypassed, true)
        XCTAssertEqual(show.clipFXSettings(clip.id), effects)
        show.toggleClipFXAllBypass(clip.id)
        XCTAssertEqual(show.current?.tracks[0].clips[0].fxBypassed, false)
        XCTAssertEqual(calls, [true, false]); XCTAssertEqual(executor.clipBypassCommands, 2)
        XCTAssertEqual(show.snapshot.transport, transport)
        XCTAssertEqual(executor.snapshotCount, snapshots); XCTAssertEqual(executor.projectEditCount, 0)
        executor.failsClipFX = true
        let previous = show.snapshot.project
        show.toggleClipFXAllBypass(clip.id)
        XCTAssertEqual(show.snapshot.project, previous); XCTAssertEqual(calls, [true, false])
    }
    @MainActor func testPreparingPlaybackAfterDocumentOpenDoesNotEditOrReloadProject() throws {
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: .empty(name: "Playback preparation"))
        try show.replaceProject(.empty(name: "Opened document"))
        let snapshot = show.snapshot, revision = show.projectRevision, snapshots = executor.snapshotCount
        var calls = 0
        show.audioUpdate = { current, audioRevision in
            calls += 1
            XCTAssertEqual(current.project, snapshot.project)
            XCTAssertEqual(current.transport, snapshot.transport)
            XCTAssertEqual(current.nextSongId, snapshot.nextSongId)
            XCTAssertGreaterThan(audioRevision, 0)
        }
        show.preparePlayback()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(show.snapshot.project, snapshot.project)
        XCTAssertEqual(show.snapshot.transport, snapshot.transport)
        XCTAssertEqual(show.snapshot.nextSongId, snapshot.nextSongId)
        XCTAssertEqual(show.projectRevision, revision); XCTAssertEqual(executor.snapshotCount, snapshots)
        XCTAssertFalse(show.hasUnsavedChanges)
    }
    @MainActor func testTrackFXReorderIsIncrementalUndoableAndPreservesPluginState() throws {
        var project = Project.empty(name: "Ordered effects")
        var track = Track(id: UUID(), name: "Track", role: .other)
        let plugin = ExternalPlugin(classID: String(repeating: "A", count: 32), name: "External", path: "/Library/Audio/Plug-Ins/VST3/Test.vst3")
        var fx = NativeFXSettings(); fx.externalPlugins = [plugin]; fx.inserted = ["EQ", plugin.effectKey, "Compressor"]
        track.fx = fx; project.songs[0].tracks = [track]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let snapshots = executor.snapshotCount
        var previews = 0; show.audioFX = { id, _ in XCTAssertEqual(id, track.id); previews += 1 }
        show.reorderFX(track.id, effect: "Compressor", before: "EQ")
        XCTAssertEqual(show.fxSettings(track.id).effectKeys, ["Compressor", "EQ", plugin.effectKey])
        XCTAssertEqual(show.fxSettings(track.id).externalPlugins, [plugin])
        XCTAssertEqual(previews, 1); XCTAssertEqual(executor.snapshotCount, snapshots)
        XCTAssertEqual(executor.projectEditCount, 0, "the chain changes without replacing the timeline or waveforms")
        show.undo(); XCTAssertEqual(show.fxSettings(track.id), fx)
        show.redo(); XCTAssertEqual(show.fxSettings(track.id).effectKeys, ["Compressor", "EQ", plugin.effectKey])
        show.toggleFXBypass(track.id, effect: plugin.effectKey)
        XCTAssertTrue(show.fxSettings(track.id).externalPlugins![0].bypassed)
        show.removeFX(track.id, effect: plugin.effectKey)
        XCTAssertEqual(show.fxSettings(track.id).effectKeys, ["Compressor", "EQ"])
        XCTAssertTrue(show.fxSettings(track.id).externalPlugins!.isEmpty)
    }
    @MainActor func testItemFXLiveChangesMergeEditorsAndCommitOneUndoWithoutProjectSerialization() throws {
        var project = Project.empty(name: "Item effects")
        var track = Track(id: UUID(), name: "Stem", role: .other)
        let clip = AudioClip(id: UUID(), name: "Audio", startTime: 30, duration: 10, waveform: Array(repeating: 0.4, count: 2048))
        track.clips = [clip]; project.songs[0].tracks = [track]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let snapshots = executor.snapshotCount, transport = show.snapshot.transport
        var previews = 0; show.audioClipFX = { id,_ in XCTAssertEqual(id,clip.id); previews += 1 }
        show.insertClipFX(clip.id, effect: "EQ"); show.insertClipFX(clip.id, effect: "Compressor")
        let baseline = show.clipFXSettings(clip.id), revision = show.projectRevision
        for gain in 1...50 {
            var eq = baseline; eq.bands[1].gain = Double(gain) / 10
            show.updateClipFX(clip.id, effect: "EQ", settings: eq)
        }
        var compressor = baseline; compressor.threshold = -12
        show.updateClipFX(clip.id, effect: "Compressor", settings: compressor)
        XCTAssertEqual(show.projectRevision, revision, "knob motion must not rebuild the timeline")
        XCTAssertEqual(show.clipFXSettings(clip.id).bands[1].gain,5)
        XCTAssertEqual(show.clipFXSettings(clip.id).threshold,-12, "another open editor merges only its own effect")
        show.commitFX()
        XCTAssertEqual(show.projectRevision,revision+1); XCTAssertGreaterThan(previews, 2)
        XCTAssertEqual(executor.snapshotCount,snapshots); XCTAssertEqual(executor.projectEditCount,0)
        XCTAssertEqual(show.snapshot.transport,transport); XCTAssertEqual(show.current?.tracks[0].clips[0].waveform,clip.waveform)
        show.undo(); XCTAssertEqual(show.clipFXSettings(clip.id),baseline)
        show.redo(); XCTAssertEqual(show.clipFXSettings(clip.id).threshold,-12)
        show.toggleClipFXBypass(clip.id,effect: "EQ"); XCTAssertFalse(show.clipFXSettings(clip.id).eqEnabled)
        show.removeClipFX(clip.id,effect: "EQ"); XCTAssertEqual(show.clipFXSettings(clip.id).inserted,["Compressor"])
    }
    @MainActor func testItemFXManagerAddsIndependentInstancesAndRemovesThemWithoutChangingTrackFX() throws {
        var project = Project.empty(name: "Item FX manager")
        var track = Track(id: UUID(), name: "Stem", role: .other)
        let clip = AudioClip(id: UUID(), name: "Audio", startTime: 30, duration: 10)
        var trackFX = NativeFXSettings(); trackFX.appendNative("Delay"); trackFX.delayTime = 1.5
        track.fx = trackFX; track.clips = [clip]; project.songs[0].tracks = [track]
        let executor = SaveTestExecutor(); executor.playing = true
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let snapshots = executor.snapshotCount, transport = show.snapshot.transport
        var previews = 0
        show.audioClipFX = { id, _ in XCTAssertEqual(id, clip.id); previews += 1 }
        XCTAssertTrue(show.clipFXSettings(clip.id).effectKeys.isEmpty)
        let first = try XCTUnwrap(show.insertClipFX(clip.id, effect: "Delay"))
        let second = try XCTUnwrap(show.insertClipFX(clip.id, effect: "Delay"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(show.clipFXSettings(clip.id).effectKeys, [first, second])
        var draft = show.clipFXSettings(clip.id).settings(for: second); draft.delayTime = 0.875
        show.updateClipFX(clip.id, effect: second, settings: draft); show.commitFX()
        XCTAssertEqual(show.clipFXSettings(clip.id).settings(for: second).delayTime, 0.875)
        XCTAssertEqual(show.clipFXSettings(clip.id).settings(for: first).delayTime, 0.25)
        show.toggleClipFXBypass(clip.id, effect: second)
        XCTAssertTrue(show.clipFXSettings(clip.id).isEnabled(first))
        XCTAssertFalse(show.clipFXSettings(clip.id).isEnabled(second))
        let beforeRemoval = show.clipFXSettings(clip.id)
        show.removeClipFX(clip.id, effect: second)
        XCTAssertEqual(show.clipFXSettings(clip.id).effectKeys, [first])
        XCTAssertTrue(show.clipFXSettings(clip.id).instances?.isEmpty == true)
        XCTAssertEqual(show.fxSettings(track.id), trackFX)
        XCTAssertEqual(executor.snapshotCount, snapshots); XCTAssertEqual(executor.projectEditCount, 0)
        XCTAssertEqual(show.snapshot.transport, transport); XCTAssertGreaterThan(previews, 3)
        show.undo(); XCTAssertEqual(show.clipFXSettings(clip.id), beforeRemoval)
        show.redo(); XCTAssertEqual(show.clipFXSettings(clip.id).effectKeys, [first])
        show.removeClipFX(clip.id, effect: first)
        XCTAssertTrue(show.clipFXSettings(clip.id).effectKeys.isEmpty)
        XCTAssertNil(show.insertClipFX(clip.id, effect: "Instruments"))
        executor.failsClipFX = true
        XCTAssertNil(show.insertClipFX(clip.id, effect: "EQ"))
        XCTAssertTrue(show.clipFXSettings(clip.id).effectKeys.isEmpty)
    }
    @MainActor func testItemFXManagerKeepsMIDITakePluginStateThroughNativeInsertsBypassAndRemoval() throws {
        var project = Project.empty(name: "MIDI take FX manager")
        var plugin = ExternalPlugin(classID: String(repeating: "B", count: 32), name: "Take synth", path: "/Library/Audio/Plug-Ins/VST3/Synth.vst3", category: "Instrument|Synth")
        plugin.componentState = "saved-component"; plugin.controllerState = "saved-controller"
        var fx = NativeFXSettings(); fx.externalPlugins = [plugin]; fx.inserted = [plugin.effectKey]
        let midi = MIDIItem(notes: [MIDINote(start: 0, length: 4, pitch: 60)])
        let clip = AudioClip(id: UUID(), name: "Take", startTime: 0, duration: 10, fx: fx, midi: midi)
        project.songs[0].tracks = [Track(id: UUID(), name: "MIDI", role: .other, clips: [clip])]
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: project)
        let eq = try XCTUnwrap(show.insertClipFX(clip.id, effect: "EQ"))
        XCTAssertEqual(show.clipFXSettings(clip.id).externalPlugins, [plugin])
        show.toggleClipFXBypass(clip.id, effect: plugin.effectKey)
        plugin.bypassed = true
        XCTAssertEqual(show.clipFXSettings(clip.id).externalPlugins, [plugin])
        show.removeClipFX(clip.id, effect: eq)
        XCTAssertEqual(show.clipFXSettings(clip.id).externalPlugins, [plugin])
        show.removeClipFX(clip.id, effect: plugin.effectKey)
        XCTAssertTrue(show.clipFXSettings(clip.id).effectKeys.isEmpty)
        XCTAssertTrue(show.clipFXSettings(clip.id).externalPlugins?.isEmpty == true)
        XCTAssertEqual(show.current?.tracks[0].clips[0].midi, midi)
        show.undo()
        XCTAssertEqual(show.clipFXSettings(clip.id).externalPlugins, [plugin])
        XCTAssertEqual(show.current?.tracks[0].clips[0].midi, midi)
    }
    @MainActor func testItemFXRejectsInstrumentsSpecialTracksAndFailedWrites() throws {
        var project = Project.empty(name: "Restricted item effects")
        var track = Track(id: UUID(), name: "Stem", role: .other)
        let clip = AudioClip(id: UUID(), name: "Audio", startTime: 30, duration: 10)
        track.clips = [clip]
        var video = Track(id: UUID(), name: "Video", role: TrackRole(rawValue: "video"))
        let videoClip = AudioClip(id: UUID(), name: "Video", startTime: 30, duration: 10); video.clips = [videoClip]
        project.songs[0].tracks = [track,video]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        show.insertClipFX(clip.id,effect: "Instruments"); show.insertClipFX(videoClip.id,effect: "EQ")
        XCTAssertEqual(executor.clipFXCommands,0); XCTAssertFalse(show.hasUnsavedChanges)
        var invalid = NativeFXSettings(); invalid.inserted = ["Instruments"]; invalid.instrumentID = "piano"
        show.previewClipFX(clip.id,settings: invalid)
        XCTAssertEqual(executor.clipFXCommands,0); XCTAssertNil(show.current?.tracks[0].clips[0].fx)
        executor.failsClipFX = true
        show.insertClipFX(clip.id,effect: "EQ")
        XCTAssertEqual(show.snapshot.project,project); XCTAssertFalse(show.canUndo)
    }
    @MainActor func testItemGainPreviewCommitsOnceWithoutProjectSerializationAndSupportsUndo() throws {
        var project = Project.empty(name: "Item gain")
        var track = Track(id: UUID(), name: "Stem", role: .other)
        let clip = AudioClip(id: UUID(), name: "Audio", startTime: 30, duration: 10, waveform: Array(repeating: 0.4, count: 2048))
        track.clips = [clip]; project.songs[0].tracks = [track]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let snapshots = executor.snapshotCount, revision = show.projectRevision, transport = show.snapshot.transport
        var previewCount = 0, audioUpdates = 0
        show.audioItemGain = { _,_ in previewCount += 1 }; show.audioUpdate = { _,_ in audioUpdates += 1 }
        for value in 1...100 { show.previewItemGain(clip.id, gain: Double(value) / 100) }
        XCTAssertEqual(previewCount, 100); XCTAssertEqual(show.projectRevision, revision)
        XCTAssertFalse(show.hasUnsavedChanges); XCTAssertFalse(show.canUndo)
        show.setItemGain(clip.id, gain: 0.5)
        XCTAssertEqual(executor.gainCommands, 1); XCTAssertEqual(executor.snapshotCount, snapshots)
        XCTAssertEqual(executor.projectEditCount, 0); XCTAssertEqual(audioUpdates, 1)
        XCTAssertEqual(show.snapshot.transport, transport); XCTAssertEqual(show.current?.tracks[0].clips[0].gain, 0.5)
        XCTAssertEqual(show.current?.tracks[0].clips[0].waveform, clip.waveform)
        show.setItemGain(clip.id, gain: 0.5); show.setItemGain(clip.id, gain: .nan)
        XCTAssertEqual(executor.gainCommands, 1)
        show.undo(); XCTAssertEqual(show.current?.tracks[0].clips[0].gain ?? 1, 1); XCTAssertFalse(show.canUndo)
        show.redo(); XCTAssertEqual(show.current?.tracks[0].clips[0].gain, 0.5)
        executor.failsGain = true
        let unchanged = show.snapshot.project
        show.setItemGain(clip.id, gain: 0.2)
        XCTAssertEqual(show.snapshot.project, unchanged); XCTAssertEqual(previewCount, 102)
    }
    @MainActor func testItemFadesAreIncrementalSavedAndUndoable() throws {
        var project = Project.demo()
        var track = Track(id: UUID(), name: "Stem", role: .other)
        let clip = AudioClip(id: UUID(), name: "Repeated", startTime: 30, duration: 10, loopStart: 0, loopLength: 2)
        track.clips = [clip]; project.songs[0].tracks = [track]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let snapshots = executor.snapshotCount
        var previewed = 0
        show.audioItemFade = { _,_,_ in previewed += 1 }
        show.previewItemFade(clip.id, fadeIn: true, seconds: 3)
        XCTAssertEqual(show.current?.tracks[0].clips[0].fadeIn, nil)
        XCTAssertFalse(show.hasUnsavedChanges)
        show.setItemFade(clip.id, fadeIn: true, seconds: 100)
        XCTAssertEqual(show.current?.tracks[0].clips[0].fadeIn, 10)
        XCTAssertEqual(executor.snapshotCount, snapshots)
        XCTAssertEqual(previewed, 2)
        XCTAssertTrue(show.canUndo)
        let saved = try ProjectDocumentCodec.encode(show.snapshot.project)
        let restored = try ProjectDocumentCodec.decode(saved)
        XCTAssertEqual(restored.songs[0].tracks[0].clips[0].fadeIn, 10)
        XCTAssertEqual(restored.songs[0].tracks[0].clips[0].loopLength, 2)
        show.undo(); XCTAssertNil(show.current?.tracks[0].clips[0].fadeIn)
        show.redo(); XCTAssertEqual(show.current?.tracks[0].clips[0].fadeIn, 10)
        show.setItemFade(clip.id, fadeIn: false, seconds: 5)
        XCTAssertEqual(show.current?.tracks[0].clips[0].fadeOut, 5)
        show.setItemFade(clip.id, fadeIn: false, seconds: .nan)
        XCTAssertEqual(show.current?.tracks[0].clips[0].fadeOut, 5)
    }
    @MainActor func testItemGainSupportsPlus24WithoutChangingTrackVolumeOrReloading() throws {
        var project = Project.empty(name: "Gain")
        let clip = AudioClip(id: UUID(), name: "Item", startTime: 0, duration: 1)
        project.songs[0].tracks = [Track(id: UUID(), name: "Track", role: .other, clips: [clip])]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let snapshots = executor.snapshotCount
        show.setItemGain(clip.id, gain: pow(10, 24.0/20))
        XCTAssertEqual(show.current?.tracks[0].clips[0].gain, pow(10, 24.0/20))
        XCTAssertEqual(show.current?.tracks[0].volume, 1)
        XCTAssertEqual(executor.snapshotCount, snapshots); XCTAssertEqual(executor.projectEditCount, 0)
        show.setItemGain(clip.id, gain: 30)
        XCTAssertEqual(show.current?.tracks[0].clips[0].gain, pow(10, 24.0/20))
    }
    @MainActor func testRecordingInsertionDoesNotReloadPlayingProject() throws {
        var project = Project.empty(name: "Recording")
        let track = Track(id: UUID(), name: "Input", role: .other)
        project.songs[0].tracks = [track]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let snapshotCount = executor.snapshotCount
        let transport = show.snapshot.transport
        var updates = 0
        show.audioUpdate = { _,_ in updates += 1 }
        let clip = AudioClip(id: UUID(), name: "Recording", startTime: 30, duration: 12)
        show.addRecordedClip(clip, track: track.id)
        XCTAssertEqual(show.current?.tracks[0].clips, [clip])
        XCTAssertGreaterThanOrEqual(show.current?.duration ?? 0, 42)
        XCTAssertEqual(show.snapshot.transport, transport)
        XCTAssertEqual(executor.snapshotCount, snapshotCount, "finishing a take must not serialize and decode every existing waveform")
        XCTAssertEqual(updates, 1)
        XCTAssertTrue(show.hasUnsavedChanges)
    }
    @MainActor func testTimelinePresentationUsesAudioClockWithoutMovingTransport() throws {
        let executor = SaveTestExecutor(); executor.playing = true
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: Project.empty(name: "Audio presentation"), playbackClock: { 100 })
        let original = show.snapshot.transport
        show.audioPresentationPosition = { head, sampledAt in
            XCTAssertEqual(sampledAt, 100)
            XCTAssertEqual(head, 0)
            return 11.75
        }
        XCTAssertEqual(show.timelinePlaybackTransport.position, 11.75)
        XCTAssertEqual(show.timelinePlaybackTransport.editPosition, original.editPosition)
        XCTAssertEqual(show.snapshot.transport.position, original.position)
        executor.playing = false
        show.tick()
        XCTAssertEqual(show.timelinePlaybackTransport.position, show.snapshot.transport.position)
    }
    @MainActor func testLiveRegionTempoConsumesElapsedTimeBeforeRetimeWithoutObsoleteAudioUpdate() throws {
        var project = Project.empty(name: "Tempo clock")
        project.songs[0].parts = [Part(id: UUID(), name: "Song", startTime: 0, endTime: 60)]
        let executor = SaveTestExecutor(); executor.playing = true
        var now = 100.0
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project, playbackClock: { now })
        var audioUpdates = 0
        show.audioUpdate = { _, _ in audioUpdates += 1 }
        for _ in 0..<20 {
            now += 0.04
            show.adjustTempo(-1)
            XCTAssertEqual(executor.timeAtTempoEdit, now - 100, accuracy: 0.000001)
        }
        XCTAssertEqual(audioUpdates, 20, "Publish only the new tempo, not an obsolete audio update before it")
        show.tick()
        XCTAssertEqual(executor.advancedTime, 0.8, accuracy: 0.000001, "The next timer tick must not consume edit time twice")
    }
    @MainActor func testRegionTempoShiftsAllMarkersAndKeepsNextSong() throws {
        var project = Project.empty(name: "Tempo batch")
        let region = Part(id: UUID(), name: "Selected", startTime: 10, endTime: 30)
        project.songs[0].parts = [region, Part(id: UUID(), name: "Next", startTime: 30, endTime: 50)]
        project.songs[0].duration = 60
        let tempos = [(0.0,100.0),(10.0,120.0),(20.0,150.0),(30.0,90.0)]
        project.songs[0].markers = tempos.map { TimelineMarker(id: UUID(), name: "TEMPO", position: $0.0, color: 0x999999, tempoBPM: $0.1, tempoBeats: 4, tempoUnit: 4, tempoTimebase: .free, tempoReferenceBPM: $0.1) }
        let cue = TimelineMarker(id: UUID(), name: "Cue", position: 22, color: 0xffff00)
        project.songs[0].markers!.append(cue)
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        show.focusRegion(region.id)
        show.adjustTempo(1)
        XCTAssertEqual(show.current?.markers?.compactMap(\.tempoBPM), [100,121,151,90])
        XCTAssertEqual(show.current?.markers?.first(where: { $0.id == cue.id }), cue)
        XCTAssertEqual(executor.tempoBatches, 1)
        XCTAssertEqual(show.current?.parts, project.songs[0].parts)
        show.setTempo(125)
        XCTAssertEqual(show.current?.markers?.compactMap(\.tempoBPM), [100,125,155,90])
        show.adjustTempo(-1)
        XCTAssertEqual(show.current?.markers?.compactMap(\.tempoBPM), [100,124,154,90])
        XCTAssertEqual(show.current?.markers?.compactMap(\.tempoReferenceBPM), [100,120,150,90])
        XCTAssertEqual(executor.tempoBatches, 3)
        try show.snapshot.project.validate()
        let copy = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(show.snapshot.project))
        XCTAssertEqual(copy.songs[0].markers, show.current?.markers)
    }
    @MainActor func testRegionTempoBoundsApplySameDeltaAndRestoreInheritedTempo() throws {
        var project = Project.empty(name: "Tempo bounds")
        let region = Part(id: UUID(), name: "Selected", startTime: 10, endTime: 30)
        project.songs[0].parts = [region]; project.songs[0].duration = 60
        project.songs[0].markers = [
            TimelineMarker(id: UUID(), name: "TEMPO", position: 0, color: 0, tempoBPM: 120, tempoBeats: 4, tempoUnit: 4),
            TimelineMarker(id: UUID(), name: "TEMPO", position: 20, color: 0, tempoBPM: 299, tempoBeats: 3, tempoUnit: 8)]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        show.focusRegion(region.id); show.adjustTempo(2)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 10)?.tempoBPM, 121)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 20)?.tempoBPM, 300)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 30)?.tempoBPM, 299)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 5)?.tempoBPM, 120)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 20)?.tempoBeats, 3)
        show.adjustTempo(1); XCTAssertEqual(executor.tempoBatches, 1)
        show.adjustTempo(-1)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 10)?.tempoBPM, 120)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 20)?.tempoBPM, 299)
        XCTAssertEqual(show.current?.activeTempoMarker(at: 30)?.tempoBPM, 299)
        XCTAssertEqual(executor.tempoBatches, 2)
        try show.snapshot.project.validate()
    }
    @MainActor func testTempoDefaultsPersistenceAndGridSnapping() throws {
        let project = Project.empty(name: "Tempo")
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: project)
        XCTAssertEqual(show.current?.bpm, 120)
        XCTAssertEqual(show.current?.meterBeats, 4)
        XCTAssertEqual(show.current?.meterUnit, 4)
        XCTAssertEqual(show.current?.barSeconds, 2)
        show.setTempo(90); show.setMeterBeats(6); show.setMeterUnit(8)
        XCTAssertEqual(show.current?.barSeconds, 2)
        let copy = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(show.snapshot.project))
        try copy.validate()
        XCTAssertEqual(copy.songs[0].bpm, 90)
        XCTAssertEqual(copy.songs[0].meterBeats, 6)
        XCTAssertEqual(copy.songs[0].meterUnit, 8)
        XCTAssertEqual(TimelineTempo.snap(0.8, bar: 2, beats: 4, pixelsPerSecond: 40), 1)
        XCTAssertEqual(TimelineTempo.snap(0.8, bar: 2, beats: 6, pixelsPerSecond: 40), 2.0 / 3, accuracy: 0.00001)
        XCTAssertEqual(TimelineTempo.snap(-1, bar: 2, beats: 4, pixelsPerSecond: 40), 0)
        XCTAssertEqual(TimelineTempo.snap(27, bar: 2, beats: 4, pixelsPerSecond: 0.3), 32, "distant zoom includes visible secondary divisions")
        show.setMeterBeats(0); show.setMeterUnit(3)
        XCTAssertEqual(show.current?.meterBeats, 6); XCTAssertEqual(show.current?.meterUnit, 8)
        XCTAssertTrue(show.hasUnsavedChanges)
    }
    @MainActor func testTempoLimitsAndAudioRatePersistence() throws {
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: .empty(name: "Limits"))
        show.setTempo(301); XCTAssertEqual(show.current?.bpm, 300)
        show.adjustTempo(1); XCTAssertEqual(show.current?.bpm, 300)
        show.setTempo(59); XCTAssertEqual(show.current?.bpm, 60)
        show.adjustTempo(-1); XCTAssertEqual(show.current?.bpm, 60)
        var project = Project.empty(name: "Stretch")
        project.songs[0].timeSettings = ProjectTimeSettings()
        project.songs[0].timeSettings?.timebase = .relative
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 30, duration: 10, sourceOffset: 2)]
        project.songs[0].tracks = [track]
        project.songs[0].followTempo(180)
        let clip = project.songs[0].tracks[0].clips[0]
        XCTAssertEqual(clip.startTime, 20); XCTAssertEqual(clip.duration, 10 / 1.5, accuracy: 0.000001)
        XCTAssertEqual(clip.sourceOffset, 2); XCTAssertEqual(clip.audioRate, 1.5)
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        try decoded.validate(); XCTAssertEqual(decoded.songs[0].tracks[0].clips[0].audioRate, 1.5)
        project.songs[0].followTempo(120)
        XCTAssertEqual(project.songs[0].tracks[0].clips[0].duration, 10, accuracy: 0.000001)
        XCTAssertEqual(project.songs[0].tracks[0].clips[0].audioRate, 1)
    }
    func testTapTempoRoundsMeasuredBPMToWholeNumbers() {
        for (measured, expected) in [(123.2, 123.0), (123.8, 124.0)] {
            var tap = TapTempo()
            XCTAssertNil(tap.tap(at: 0))
            XCTAssertEqual(tap.tap(at: 60 / measured), expected)
            XCTAssertEqual(tap.tap(at: 120 / measured), expected)
        }
    }

    func testTapTempoAveragesAndResetsAfterIdle() {
        var tap = TapTempo()
        XCTAssertNil(tap.tap(at: 0))
        XCTAssertEqual(tap.tap(at: 0.5), 120)
        XCTAssertEqual(tap.tap(at: 1), 120)
        XCTAssertNil(tap.tap(at: 1.01), "accidental double press is ignored")
        XCTAssertNil(tap.tap(at: 6), "a new sequence starts after idle")
        XCTAssertEqual(tap.tap(at: 7), 60)
        var fast = TapTempo(); _ = fast.tap(at: 0)
        XCTAssertEqual(fast.tap(at: 0.15), 300)
        var slow = TapTempo(); _ = slow.tap(at: 0)
        XCTAssertEqual(slow.tap(at: 2), 60)
    }

    @MainActor func testPlaylistCreationPreservesChosenOrderAndDeduplicates() throws {
        var project = Project.empty(name: "Selection order")
        let regions = (0..<4).map { index in
            Part(id: UUID(), name: "Song \(index)", startTime: Double(index * 10), endTime: Double(index * 10 + 5))
        }
        project.songs[0].parts = regions; project.songs[0].duration = 40
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: project)
        let order = [regions[2].id, regions[0].id, regions[3].id, regions[1].id]
        XCTAssertTrue(show.createRegionPlaylist(name: "Chosen", selected: order + [regions[2].id, UUID()]))
        XCTAssertEqual(show.selectedRegionPlaylist?.regionIds, order)
        let restored = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(show.snapshot.project))
        XCTAssertEqual(restored.regionSetlist?.playlists.last?.regionIds, order)
    }

    @MainActor func testGlobalSearchKeepsContainingPlaylistAndFallsBackToAllRegions() throws {
        var project = Project.empty(name: "Search")
        let regions = [Part(id: UUID(), name: "Canção First", startTime: 0, endTime: 5),
                       Part(id: UUID(), name: "Outside", startTime: 10, endTime: 15)]
        project.songs[0].parts = regions; project.songs[0].duration = 20
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        XCTAssertTrue(show.createRegionPlaylist(name: "Concert", selected: [regions[0].id]))
        let playlist = try XCTUnwrap(show.selectedRegionPlaylist)
        XCTAssertEqual(show.searchRegions(" ").map(\.id), regions.map(\.id))
        XCTAssertEqual(show.searchRegions(" CANCAO ").map(\.id), [regions[0].id])
        XCTAssertEqual(show.searchRegions("outside").map(\.id), [regions[1].id])
        XCTAssertEqual(show.searchRegions("02", byRegionID: true).map(\.id), [regions[1].id])
        XCTAssertEqual(show.searchRegions("2", byRegionID: true).map(\.id), [regions[1].id])
        XCTAssertTrue(show.searchRegions("02").isEmpty)
        XCTAssertTrue(show.searchRegions("0", byRegionID: true).isEmpty)
        XCTAssertTrue(show.selectRegionSearchResult(regions[0].id))
        XCTAssertEqual(show.selectedRegionPlaylist?.id, playlist.id)
        XCTAssertEqual(executor.regionCommands.last, .selectRegion)
        let request = show.regionFocusRequest
        XCTAssertTrue(show.selectRegionSearchResult(regions[0].id))
        XCTAssertNotEqual(show.regionFocusRequest, request, "repeated selection must reveal the row again")
        XCTAssertFalse(show.selectRegionSearchResult(UUID()))
        XCTAssertEqual(show.selectedRegionPlaylist?.id, playlist.id)
        XCTAssertTrue(show.selectRegionSearchResult(regions[1].id))
        XCTAssertNil(show.selectedRegionPlaylist)
        XCTAssertEqual(show.focusedRegion, regions[1].id)
        XCTAssertEqual(show.listedRegions, regions)
        XCTAssertEqual(show.regionSetlist.playlists.first, playlist, "search must not edit playlist membership")
    }
    @MainActor func testSearchResultQueuesDuringPlaybackEvenWhenChangingPlaylist() throws {
        var project = Project.empty(name: "Playing search")
        let regions = (0..<2).map { Part(id: UUID(), name: "Song \($0)", startTime: Double($0 * 10), endTime: Double($0 * 10 + 5)) }
        project.songs[0].parts = regions; project.songs[0].duration = 20
        let executor = SaveTestExecutor(); executor.playing = true
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        XCTAssertTrue(show.createRegionPlaylist(name: "Concert", selected: [regions[0].id]))
        XCTAssertTrue(show.selectRegionSearchResult(regions[0].id))
        XCTAssertTrue(show.selectRegionSearchResult(regions[1].id))
        XCTAssertEqual(executor.regionCommands, [.queueRegion, .queueRegion])
        XCTAssertEqual(executor.regionSelections, regions.map(\.id))
        XCTAssertNil(show.selectedRegionPlaylist)
    }

    @MainActor func testNewTrackFollowsSelectionOrAppendsWithoutSelection() throws {
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: .empty(name: "Track insertion"))
        let first = try XCTUnwrap(show.addTrack(name: "First", role: .keys))
        let last = try XCTUnwrap(show.addTrack(name: "Last", role: .bass))
        let inserted = try XCTUnwrap(show.addTrack(name: "Middle", role: .guitar, after: first))
        XCTAssertEqual(show.current?.tracks.map(\.id), [first, inserted, last])
        let afterLast = try XCTUnwrap(show.addTrack(name: "After last", role: .drums, after: last))
        let appended = try XCTUnwrap(show.addTrack(name: "Appended", role: .click))
        XCTAssertEqual(show.current?.tracks.map(\.id), [first, inserted, last, afterLast, appended])
        XCTAssertTrue(show.hasUnsavedChanges)
    }

    @MainActor func testRenamePlaylistAndDeleteMultipleAllRegionsWithUndo() throws {
        var project = Project.empty(name: "Setlist editing")
        let regions = (0..<3).map { Part(id: UUID(), name: "Song \($0)", startTime: Double($0*10), endTime: Double($0*10+8)) }
        project.songs[0].parts = regions; project.songs[0].duration = 40
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        XCTAssertTrue(show.createRegionPlaylist(name: "Original", selected: regions.map(\.id)))
        let list = try XCTUnwrap(show.selectedRegionPlaylist)
        let edits = executor.projectEditCount
        XCTAssertFalse(show.renameRegionPlaylist(list.id, name: "  "))
        XCTAssertFalse(show.renameRegionPlaylist(UUID(), name: "Missing"))
        XCTAssertTrue(show.renameRegionPlaylist(list.id, name: "  New name  "))
        XCTAssertEqual(show.selectedRegionPlaylist?.name, "New name")
        XCTAssertEqual(show.selectedRegionPlaylist?.regionIds, list.regionIds)
        XCTAssertEqual(executor.projectEditCount, edits, "playlist rename must not rebuild audio")
        show.undo(); XCTAssertEqual(show.selectedRegionPlaylist?.name, "Original")
        show.selectRegionPlaylist(nil)
        let before = show.snapshot.project
        XCTAssertTrue(show.deleteSetlistEntries([regions[0].id, regions[1].id]))
        XCTAssertEqual(show.current?.parts.map(\.id), [regions[2].id])
        XCTAssertEqual(show.regionSetlist.playlists.first?.regionIds, [regions[2].id])
        XCTAssertEqual(show.current?.tracks, before.songs[0].tracks)
        show.undo(); XCTAssertEqual(show.snapshot.project, before)
    }

    @MainActor func testMixedSetlistDeleteIsAtomicUndoableAndProtectsDrawerSongs() throws {
        var project = Project.empty(name: "Mixed delete")
        let first = Part(id: UUID(), name: "First", startTime: 0, endTime: 12)
        let second = Part(id: UUID(), name: "Second", startTime: 10, endTime: 22)
        let third = Part(id: UUID(), name: "Third", startTime: 30, endTime: 40)
        project.songs[0].parts = [first, second, third]; project.songs[0].duration = 60
        let group = try project.unifyRegions(containing: first.id, name: "Group")
        let block = UUID()
        project.regionSetlist = RegionSetlist(blocks: [SetlistBlock(id: block, songId: project.songs[0].id, playlistId: nil, name: "Legacy", color: 0x54ff93)])
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let before = show.snapshot.project
        XCTAssertTrue(show.deletableSetlistEntries([first.id, second.id]).isEmpty)
        XCTAssertFalse(show.deleteSetlistEntries([first.id, second.id]))
        XCTAssertEqual(executor.projectEditCount, 0)
        XCTAssertTrue(show.deleteSetlistEntries([block, group, third.id, first.id]))
        XCTAssertEqual(executor.projectEditCount, 1, "one project update for the whole mixed selection")
        XCTAssertEqual(Set(show.current!.parts.map(\.id)), [first.id, second.id], "Deleting the wrapper preserves its songs")
        XCTAssertTrue(show.current!.parts.allSatisfy { $0.parentRegionID == nil })
        XCTAssertTrue(show.listedBlocks.isEmpty)
        XCTAssertEqual(show.current!.tracks, before.songs[0].tracks)
        show.undo()
        XCTAssertEqual(show.snapshot.project, before, "a single Undo restores all selected entries and the drawer")
    }
    @MainActor func testPlaylistDeleteKeepsGridAndOtherListsAndDoesNotRefreshAudio() throws {
        var project = Project.empty(name: "Playlist delete")
        let regions = (0..<3).map { Part(id: UUID(), name: "Song \($0)", startTime: Double($0 * 10), endTime: Double($0 * 10 + 5)) }
        project.songs[0].parts = regions; project.songs[0].duration = 40
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let globalBlock = UUID()
        XCTAssertNil(show.addSetlistBlock())
        XCTAssertTrue(show.createRegionPlaylist(name: "First", selected: regions.map(\.id)))
        let other = try XCTUnwrap(show.selectedRegionPlaylist)
        let otherBlock = try XCTUnwrap(show.addSetlistBlock())
        XCTAssertTrue(show.createRegionPlaylist(name: "Second", selected: regions.map(\.id)))
        let block1 = try XCTUnwrap(show.addSetlistBlock()), block2 = try XCTUnwrap(show.addSetlistBlock())
        let before = show.snapshot.project
        var audioRefreshes = 0
        show.audioUpdate = { _, _ in audioRefreshes += 1 }
        XCTAssertTrue(show.deleteSetlistEntries([block1, block2, regions[0].id, regions[1].id, globalBlock, otherBlock]))
        XCTAssertEqual(show.current!.parts, regions)
        XCTAssertEqual(show.listedRegions, [regions[2]])
        XCTAssertTrue(show.listedBlocks.isEmpty)
        XCTAssertEqual(show.regionSetlist.playlists.first { $0.id == other.id }, other)
        XCTAssertTrue(show.regionSetlist.blocks!.contains { $0.id == otherBlock })
        XCTAssertEqual(executor.projectEditCount, 0)
        XCTAssertEqual(audioRefreshes, 0)
        show.undo(); XCTAssertEqual(show.snapshot.project, before)
    }

    @MainActor func testDeletingOnlySetlistBlocksKeepsSongsMediaAndOtherPlaylists() throws {
        var project = Project.empty(name: "Block headers")
        let region = Part(id: UUID(), name: "Song", startTime: 0, endTime: 12)
        project.songs[0].parts = [region]; project.songs[0].duration = 20
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Song.wav", startTime: 0, duration: 12,
                                audioFile: AudioFile(path: "Stems/Song.wav"))]
        project.songs[0].tracks = [track]
        project.songs[0].markers = [TimelineMarker(id: UUID(), name: "Verse", position: 4, color: 0x00ff00)]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        XCTAssertTrue(show.createRegionPlaylist(name: "Other", selected: [region.id]))
        let otherBlock = try XCTUnwrap(show.addSetlistBlock())
        XCTAssertTrue(show.createRegionPlaylist(name: "Current", selected: [region.id]))
        let first = try XCTUnwrap(show.addSetlistBlock()), second = try XCTUnwrap(show.addSetlistBlock())
        let before = show.snapshot.project
        let edits = executor.projectEditCount
        var audioRefreshes = 0
        show.audioUpdate = { _, _ in audioRefreshes += 1 }
        show.selectSetlistBlock(first)
        XCTAssertTrue(show.deleteSetlistEntries([first, second, otherBlock]))
        XCTAssertEqual(show.snapshot.project.songs, before.songs, "headers must not remove audio, regions or markers")
        XCTAssertEqual(show.regionSetlist.playlists, before.regionSetlist?.playlists)
        XCTAssertEqual(show.regionSetlist.blocks?.map(\.id), [otherBlock], "a foreign playlist's header must be protected")
        XCTAssertEqual(executor.projectEditCount, edits)
        XCTAssertEqual(audioRefreshes, 0, "deleting a header must not interrupt the audio engine")
        show.send(.play)
        XCTAssertEqual(executor.playCommands, 1, "a deleted header must not leave a stale selection that blocks Play")
        show.undo(); XCTAssertEqual(show.snapshot.project, before)
    }

    @MainActor func testBlocksPersistWithoutBecomingSongs() throws {
        var project = Project.empty(name: "Blocks")
        let regions = (0..<3).map { Part(id: UUID(), name: "Song \($0)", startTime: Double($0*10), endTime: Double($0*10+5)) }
        project.songs[0].parts = regions; project.songs[0].duration = 30
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: project)
        let unchanged = show.snapshot.project
        XCTAssertNil(show.addSetlistBlock())
        XCTAssertEqual(show.snapshot.project, unchanged)
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertTrue(show.createRegionPlaylist(name: "Initial", selected: regions.map(\.id)))
        let initialList = try XCTUnwrap(show.selectedRegionPlaylist).id
        let first = try XCTUnwrap(show.addSetlistBlock())
        let second = try XCTUnwrap(show.addSetlistBlock())
        XCTAssertEqual(show.listedBlocks.map(\.name), ["Bloco 02", "Bloco 01"])
        XCTAssertEqual(Array(show.setlistEntries.prefix(2)).map(\.id), [second, first])
        XCTAssertEqual(show.listedRegions, regions)
        show.moveSetlistBlock(first, relativeTo: regions[0].id, after: false)
        show.moveSetlistBlock(second, relativeTo: regions[2].id, after: false)
        XCTAssertEqual(show.setlistEntries.map(\.id), [first, regions[0].id, regions[1].id, second, regions[2].id])
        show.editSetlistBlock(first, name: " Opening ", color: 0x123abc)
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(show.snapshot.project))
        try decoded.validate()
        XCTAssertEqual(decoded.regionSetlist?.blocks?.first(where: { $0.id == first })?.name, "Opening")
        XCTAssertEqual(decoded.regionSetlist?.blocks?.first(where: { $0.id == first })?.color, 0x123abc)
        XCTAssertEqual(show.setlistEntries.compactMap { entry -> Int? in if case .region(_, let number) = entry { return number }; return nil }, [1,2,3])
        XCTAssertTrue(show.createRegionPlaylist(name: "Concert", selected: regions.map(\.id)))
        XCTAssertTrue(show.listedBlocks.isEmpty, "blocks belong to their list")
        _ = show.addSetlistBlock()
        XCTAssertEqual(show.listedBlocks.map(\.name), ["Bloco 01"])
        show.selectRegionPlaylist(nil)
        XCTAssertTrue(show.listedBlocks.isEmpty)
        XCTAssertNil(show.addSetlistBlock(symbol: false))
        show.selectRegionPlaylist(initialList)
        XCTAssertEqual(show.listedBlocks.count, 2)
        var invalid = decoded
        invalid.regionSetlist?.blocks?[0].beforeRegionId = UUID()
        XCTAssertThrowsError(try invalid.validate())
    }
    @MainActor func testRegionSelectionUsesUppermostSelectedTrackInTimeOrder() throws {
        var project = Project.empty(name: "Selection")
        let first = AudioClip(id: UUID(), name: "First.wav", startTime: 1, duration: 2)
        let later = AudioClip(id: UUID(), name: "Later.wav", startTime: 5, duration: 2)
        let lower = AudioClip(id: UUID(), name: "Lower.wav", startTime: 1, duration: 2)
        let stacked = AudioClip(id: UUID(), name: "Stacked.wav", startTime: 1.5, duration: 1)
        var top = Track(id: UUID(), name: "Top", role: .other); top.clips = [later, first, stacked]
        var bottom = Track(id: UUID(), name: "Bottom", role: .other); bottom.clips = [lower]
        project.songs[0].tracks = [top, bottom]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let snapshots = executor.snapshotCount
        show.regionsFromSelection([later.id, first.id, lower.id, stacked.id])
        XCTAssertEqual(executor.regionItems, [first.id, later.id])
        XCTAssertEqual(executor.snapshotCount, snapshots + 1, "one UI refresh for the entire batch")
    }

    @MainActor func testBlockSymbolsPersistIndependentlyOfCreationDefault() throws {
        var project = Project.empty(name: "Symbols")
        let song = Part(id: UUID(), name: "Song", startTime: 0, endTime: 5)
        project.songs[0].parts = [song]
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: project)
        XCTAssertTrue(show.createRegionPlaylist(name: "Show", selected: [song.id]))
        let first = try XCTUnwrap(show.addSetlistBlock())
        let second = try XCTUnwrap(show.addSetlistBlock(symbol: false))
        XCTAssertTrue(try XCTUnwrap(show.listedBlocks.first { $0.id == first }).showsSymbol)
        XCTAssertFalse(try XCTUnwrap(show.listedBlocks.first { $0.id == second }).showsSymbol)
        show.editSetlistBlock(first, name: "Hidden", color: 0x123abc, symbol: false)
        show.editSetlistBlock(second, name: "Visible", color: 0x456abc, symbol: true)
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(show.snapshot.project))
        XCTAssertFalse(try XCTUnwrap(decoded.regionSetlist?.blocks?.first { $0.id == first }).showsSymbol)
        XCTAssertTrue(try XCTUnwrap(decoded.regionSetlist?.blocks?.first { $0.id == second }).showsSymbol)
    }

    @MainActor func testBulkBlockSymbolsAreOneUndoableIncrementalEdit() throws {
        var project = Project.empty(name: "Symbols")
        let region = Part(id: UUID(), name: "Song", startTime: 0, endTime: 5)
        project.songs[0].parts = [region]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        XCTAssertTrue(show.createRegionPlaylist(name: "Show", selected: [region.id]))
        let first = try XCTUnwrap(show.addSetlistBlock())
        let second = try XCTUnwrap(show.addSetlistBlock())
        let untouched = try XCTUnwrap(show.addSetlistBlock())
        let reads = executor.snapshotCount, revision = show.projectRevision
        var audio = 0
        show.audioUpdate = { _, _ in audio += 1 }
        show.setBlockSymbols([first, second, UUID()], enabled: false)
        XCTAssertFalse(try XCTUnwrap(show.listedBlocks.first { $0.id == first }).showsSymbol)
        XCTAssertFalse(try XCTUnwrap(show.listedBlocks.first { $0.id == second }).showsSymbol)
        XCTAssertTrue(try XCTUnwrap(show.listedBlocks.first { $0.id == untouched }).showsSymbol)
        XCTAssertEqual(reads, executor.snapshotCount); XCTAssertEqual(revision, show.projectRevision); XCTAssertEqual(audio, 0)
        show.undo()
        XCTAssertTrue(try XCTUnwrap(show.listedBlocks.first { $0.id == first }).showsSymbol)
        XCTAssertTrue(try XCTUnwrap(show.listedBlocks.first { $0.id == second }).showsSymbol)
    }

    @MainActor func testFreezeUndoRedoAndStaleRenderRejection() throws {
        var project = Project.empty(name: "Freeze")
        var track = Track(id: UUID(), name: "Keys", role: .keys)
        let old = AudioClip(id: UUID(), name: "Keys", startTime: 4, duration: 5, audioFile: AudioFile(path: "Stems/Keys.wav"), gain: 0.5)
        track.clips = [old]; project.songs[0].tracks = [track]; project.songs[0].duration = 10
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        var frozen = old; frozen.audioFile = AudioFile(path: "Stems/Keys-01.wav"); frozen.gain = 1
        let reads = executor.snapshotCount
        XCTAssertTrue(show.replaceRenderedItem(frozen, original: old, track: track.id, project: project.id))
        XCTAssertEqual(reads, executor.snapshotCount, "publishing a render does not reload the project")
        XCTAssertEqual(show.current?.tracks[0].clips[0], frozen)
        show.undo(); XCTAssertEqual(show.current?.tracks[0].clips[0], old)
        show.redo(); XCTAssertEqual(show.current?.tracks[0].clips[0], frozen)
        XCTAssertFalse(show.replaceRenderedItem(frozen, original: old, track: track.id, project: project.id))
        XCTAssertTrue(show.knownMediaPaths.contains("Stems/Keys.wav")); XCTAssertTrue(show.knownMediaPaths.contains("Stems/Keys-01.wav"))
    }
    @MainActor func testDetectedTempoBatchHasOneUndo() throws {
        let project = Project.empty(name: "Tempo")
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: project)
        let markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 0.123, color: 0x999999, tempoBPM: 120, tempoBeats: 4, tempoUnit: 4, tempoTimebase: .global),
                       TimelineMarker(id: UUID(), name: "TEMPO", position: 8.123, color: 0x999999, tempoBPM: 90, tempoBeats: 4, tempoUnit: 4, tempoTimebase: .global)]
        XCTAssertTrue(show.applyDetectedTempo(markers, project: project.id, song: project.songs[0].id))
        let saved = try XCTUnwrap(show.current?.markers)
        XCTAssertEqual(saved.first?.position, 0)
        XCTAssertEqual(saved.first?.tempoBPM, 120)
        XCTAssertEqual(Array(saved.dropFirst()), markers)
        show.undo(); XCTAssertTrue(show.current?.markers?.isEmpty ?? true)
        show.redo(); XCTAssertEqual(show.current?.markers, saved)
    }

    @MainActor func testRedetectReplacesEveryTempoMarkerInTheRegionAndCanUndo() throws {
        var project = Project.empty(name: "Redetect")
        let region = Part(id: UUID(), name: "Song", startTime: 10, endTime: 40)
        project.songs[0].parts = [region]; project.songs[0].duration = 50
        func tempo(_ time: Double) -> TimelineMarker {
            TimelineMarker(id: UUID(), name: "TEMPO", position: time, color: 0x999999,
                tempoBPM: 140, tempoBeats: 4, tempoUnit: 4, tempoTimebase: .global, tempoReferenceBPM: 140)
        }
        let outside = tempo(42), wrong = tempo(25), first = tempo(11), endBoundary = tempo(40)
        let startBoundary = TimelineMarker(id: UUID(), name: "Old start", position: 10, color: 0,
            tempoBPM: 95, tempoTimebase: .free)
        let manualTempo = TimelineMarker(id: UUID(), name: "Manual tempo", position: 18, color: 0,
            tempoBPM: 130, tempoTimebase: .relative)
        let manual = TimelineMarker(id: UUID(), name: "Cue", position: 22, color: 0xffffff)
        project.songs[0].markers = [startBoundary, first, manualTempo, wrong, endBoundary, outside, manual]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let reads = executor.snapshotCount
        let corrected = [tempo(11), tempo(24)]
        XCTAssertTrue(show.applyDetectedTempo(corrected, project: project.id, song: project.songs[0].id, region: region.id))
        let updated = try XCTUnwrap(show.current?.markers)
        for old in [startBoundary, first, manualTempo, wrong] { XCTAssertFalse(updated.contains { $0.id == old.id }) }
        XCTAssertTrue(updated.contains(outside)); XCTAssertTrue(updated.contains(endBoundary)); XCTAssertTrue(updated.contains(manual))
        XCTAssertEqual(updated.filter { $0.isTempo && $0.position >= 10 && $0.position < 40 }.map(\.position).sorted(), [11,24])
        XCTAssertEqual(executor.project.songs[0].markers?.sorted { $0.position < $1.position }, show.current?.markers?.sorted { $0.position < $1.position })
        XCTAssertEqual(executor.snapshotCount, reads, "detection publishes a batch without reloading the arrangement")
        show.undo(); XCTAssertEqual(show.current?.markers, project.songs[0].markers)
        show.redo(); XCTAssertEqual(show.current?.markers, updated)
    }

    @MainActor func testBlockIsInsertedImmediatelyAboveSelectedSong() throws {
        var project = Project.empty(name: "Block placement")
        let regions = (0..<3).map { Part(id: UUID(), name: "Song \($0)", startTime: Double($0*10), endTime: Double($0*10+5)) }
        project.songs[0].parts = regions; project.songs[0].duration = 30
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: project)
        XCTAssertTrue(show.createRegionPlaylist(name: "Initial", selected: regions.map(\.id)))
        show.focusRegion(regions[1].id)
        let first = try XCTUnwrap(show.addSetlistBlock())
        let second = try XCTUnwrap(show.addSetlistBlock())
        XCTAssertEqual(show.setlistEntries.map(\.id), [regions[0].id, first, second, regions[1].id, regions[2].id])
        XCTAssertEqual(show.focusedRegion, regions[1].id)
        XCTAssertEqual(show.listedRegions, regions, "blocks do not alter playback order or grid positions")
        XCTAssertTrue(show.createRegionPlaylist(name: "Other", selected: [regions[2].id]))
        let top = try XCTUnwrap(show.addSetlistBlock())
        XCTAssertEqual(show.setlistEntries.map(\.id), [top, regions[2].id], "selection outside this playlist falls back to its beginning")
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(show.snapshot.project))
        XCTAssertEqual(decoded.regionSetlist?.blocks?.first(where: { $0.id == second })?.beforeRegionId, regions[1].id)
    }

    @MainActor func testSetlistEditsDoNotReloadWaveformsOrInvalidateAudioAndGrid() throws {
        var project = Project.empty(name: "Fast setlist")
        let regions = (0..<4).map { Part(id: UUID(), name: "Song \($0)", startTime: Double($0*10), endTime: Double($0*10+5)) }
        project.songs[0].parts = regions; project.songs[0].duration = 40
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        XCTAssertTrue(show.createRegionPlaylist(name: "Initial", selected: regions.map(\.id)))
        let reads = executor.snapshotCount, revision = show.projectRevision
        var audioChanges = 0, displayChanges = 0
        show.audioUpdate = { _, _ in audioChanges += 1 }
        show.onSetlistEdited = { displayChanges += 1 }
        let block = try XCTUnwrap(show.addSetlistBlock())
        show.editSetlistBlock(block, name: "Intro", color: 0x123456)
        show.moveSetlistBlock(block, relativeTo: regions[1].id, after: false)
        XCTAssertTrue(show.createRegionPlaylist(name: "Show", selected: regions.map(\.id)))
        show.moveSetlistEntries([regions[0].id, regions[2].id], relativeTo: regions[3].id, after: true)
        XCTAssertEqual(show.listedRegions.map(\.id), [regions[1].id, regions[3].id, regions[0].id, regions[2].id])
        XCTAssertEqual(executor.snapshotCount, reads)
        XCTAssertEqual(show.projectRevision, revision)
        XCTAssertEqual(audioChanges, 0)
        XCTAssertEqual(displayChanges, 5, "the teleprompter preview refreshes even while stopped, without rescheduling audio")
        XCTAssertTrue(show.hasUnsavedChanges)
        XCTAssertEqual(show.snapshot.project.songs, project.songs)
    }
    @MainActor func testMixedSetlistDragPreservesOrderAndAllRegionsRejectsSongReordering() throws {
        var project = Project.empty(name: "Group drag")
        let regions = (0..<4).map { Part(id: UUID(), name: "Song \($0)", startTime: Double($0*10), endTime: Double($0*10+5)) }
        project.songs[0].parts = regions; project.songs[0].duration = 40
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: project)
        show.moveSetlistEntries([regions[0].id], relativeTo: regions[3].id, after: true)
        XCTAssertEqual(show.listedRegions, regions)
        XCTAssertTrue(show.createRegionPlaylist(name: "Show", selected: regions.map(\.id)))
        let block = try XCTUnwrap(show.addSetlistBlock())
        show.moveSetlistEntries([block, regions[0].id, regions[2].id], relativeTo: regions[3].id, after: true)
        XCTAssertEqual(show.setlistEntries.map(\.id), [regions[1].id, regions[3].id, block, regions[0].id, regions[2].id])
        XCTAssertEqual(show.listedBlocks.first?.beforeRegionId, regions[0].id)
        let before = show.snapshot.project
        show.moveSetlistEntries([block, regions[0].id], relativeTo: block, after: true)
        XCTAssertEqual(show.snapshot.project, before)
        try show.snapshot.project.validate()
    }
    @MainActor func testBlockItemDragReordersOnlySelectedRowsAcrossSongsAndBlocks() throws {
        var project = Project.empty(name: "Block item drag")
        let regions = (0..<3).map { Part(id: UUID(), name: "Song \($0)", startTime: Double($0 * 10), endTime: Double($0 * 10 + 5)) }
        project.songs[0].parts = regions; project.songs[0].duration = 30
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        XCTAssertTrue(show.createRegionPlaylist(name: "Other", selected: regions.map(\.id)))
        let otherBlock = try XCTUnwrap(show.addSetlistBlock())
        let otherList = try XCTUnwrap(show.selectedRegionPlaylist)
        XCTAssertTrue(show.createRegionPlaylist(name: "Current", selected: regions.map(\.id)))
        let first = try XCTUnwrap(show.addSetlistBlock()), second = try XCTUnwrap(show.addSetlistBlock())
        let songOrder = regions.map(\.id)
        var audioRefreshes = 0
        show.audioUpdate = { _, _ in audioRefreshes += 1 }
        let edits = executor.projectEditCount
        XCTAssertEqual(show.setlistEntries.map(\.id), [second, first] + songOrder)

        show.moveSetlistEntries([second], relativeTo: regions[1].id, after: true)
        XCTAssertEqual(show.setlistEntries.map(\.id), [first, regions[0].id, regions[1].id, second, regions[2].id])
        show.moveSetlistEntries([second], relativeTo: first, after: true)
        XCTAssertEqual(show.setlistEntries.map(\.id), [first, second] + songOrder)
        show.moveSetlistEntries([first], relativeTo: second, after: true)
        XCTAssertEqual(show.setlistEntries.map(\.id), [second, first] + songOrder, "two blocks sharing one song anchor retain drop order")
        let beforeTail = show.snapshot.project
        show.moveSetlistEntries([first], relativeTo: regions[2].id, after: true)
        XCTAssertEqual(show.setlistEntries.map(\.id), [second] + songOrder + [first])
        XCTAssertNil(show.listedBlocks.first(where: { $0.id == first })?.beforeRegionId)
        XCTAssertEqual(executor.projectEditCount, edits)
        XCTAssertEqual(audioRefreshes, 0, "moving block items is a setlist-only update")
        show.undo()
        XCTAssertEqual(show.snapshot.project, beforeTail)
        let editsAfterUndo = executor.projectEditCount, audioAfterUndo = audioRefreshes
        show.moveSetlistEntries([first], relativeTo: second, after: false)
        XCTAssertEqual(show.setlistEntries.map(\.id), [first, second] + songOrder)

        XCTAssertEqual(show.listedRegions.map(\.id), songOrder)
        XCTAssertEqual(show.snapshot.project.songs, project.songs)
        XCTAssertEqual(show.regionSetlist.playlists.first(where: { $0.id == otherList.id }), otherList)
        XCTAssertTrue(show.regionSetlist.blocks?.contains(where: { $0.id == otherBlock && $0.beforeRegionId == regions[0].id }) == true)
        XCTAssertEqual(executor.projectEditCount, editsAfterUndo)
        XCTAssertEqual(audioRefreshes, audioAfterUndo)
        try show.snapshot.project.validate()
    }
    @MainActor func testPositionalBlockMIDIIDsFollowVisibleOrderAndIgnoreNames() throws {
        var project = Project.empty(name: "Block MIDI position")
        let regions = (0..<4).map { Part(id: UUID(), name: "Song \($0)", startTime: Double($0 * 10), endTime: Double($0 * 10 + 5)) }
        project.songs[0].parts = regions; project.songs[0].duration = 40
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        XCTAssertTrue(show.createRegionPlaylist(name: "Show", selected: regions.map(\.id)))
        let first = try XCTUnwrap(show.addSetlistBlock()), second = try XCTUnwrap(show.addSetlistBlock())
        show.moveSetlistEntries([first], relativeTo: regions[1].id, after: false)
        show.moveSetlistEntries([second], relativeTo: regions[3].id, after: false)
        XCTAssertEqual(show.setlistBlockNumber(first), 1)
        XCTAssertEqual(show.setlistBlockNumber(second), 2)
        XCTAssertNil(show.setlistBlockNumber(regions[0].id))
        XCTAssertTrue(show.focusSetlistBlock(number: 1))
        XCTAssertEqual(show.focusedRegion, regions[1].id)
        XCTAssertEqual(executor.regionSelections.last, regions[1].id)
        XCTAssertEqual(executor.regionCommands.last, .selectRegion)
        XCTAssertTrue(show.focusSetlistBlock(number: 2))
        XCTAssertEqual(show.focusedRegion, regions[3].id)
        XCTAssertEqual(executor.playCommands, 0)

        show.editSetlistBlock(first, name: "Renamed block", color: 0x123456)
        XCTAssertEqual(show.setlistBlockNumber(first), 1)
        show.moveSetlistEntries([second], relativeTo: regions[0].id, after: false)
        XCTAssertEqual(show.setlistBlockNumber(second), 1)
        XCTAssertEqual(show.setlistBlockNumber(first), 2)
        XCTAssertTrue(show.focusSetlistBlock(number: 1))
        XCTAssertEqual(show.focusedRegion, regions[0].id, "global block ID 1 follows the first visible block after reordering")
        show.moveSetlistEntries([first], relativeTo: regions[3].id, after: true)
        let commands = executor.regionSelections.count
        for missing in [0, -1, 2, 3, Int.max] { XCTAssertFalse(show.focusSetlistBlock(number: missing)) }
        XCTAssertEqual(executor.regionSelections.count, commands, "a missing or trailing empty block cannot select an unrelated song")
        XCTAssertEqual(executor.playCommands, 0)
    }
    @MainActor func testPositionalBlockMIDIResolvesEachPlaylistAndProjectAndNormalQueueBehavior() throws {
        for projectNumber in 0..<2 {
            var project = Project.empty(name: "MIDI project \(projectNumber)")
            let regions = (0..<3).map { Part(id: UUID(), name: "Song \($0)", startTime: Double($0 * 10), endTime: Double($0 * 10 + 5)) }
            project.songs[0].parts = regions; project.songs[0].duration = 30
            let executor = SaveTestExecutor()
            let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
            XCTAssertTrue(show.createRegionPlaylist(name: "First list", selected: regions.map(\.id)))
            let firstList = try XCTUnwrap(show.selectedRegionPlaylist).id
            let firstBlock = try XCTUnwrap(show.addSetlistBlock())
            show.moveSetlistEntries([firstBlock], relativeTo: regions[1].id, after: false)
            XCTAssertTrue(show.createRegionPlaylist(name: "Second list", selected: regions.reversed().map(\.id)))
            let secondBlock = try XCTUnwrap(show.addSetlistBlock())
            XCTAssertNotEqual(firstBlock, secondBlock)
            XCTAssertNil(show.setlistBlockNumber(firstBlock))
            XCTAssertEqual(show.setlistBlockNumber(secondBlock), 1)
            XCTAssertTrue(show.focusSetlistBlock(number: 1))
            XCTAssertEqual(show.focusedRegion, regions[2].id)
            show.selectRegionPlaylist(firstList)
            XCTAssertTrue(show.focusSetlistBlock(number: 1))
            XCTAssertEqual(show.focusedRegion, regions[1].id)
            let runningExecutor = SaveTestExecutor(); runningExecutor.playing = true
            let runningShow = try ShowController(executor: runningExecutor, persistence: SaveTestStore(), initialProject: show.snapshot.project)
            XCTAssertTrue(runningShow.focusSetlistBlock(number: 1))
            XCTAssertEqual(runningExecutor.regionCommands.last, .queueRegion)
            XCTAssertEqual(runningExecutor.regionSelections.last, regions[1].id)
            XCTAssertEqual(runningExecutor.playCommands, 0)
            runningExecutor.playing = false; runningShow.send(.stopAll)
            XCTAssertEqual(executor.playCommands, 0, "the block MIDI action selects/queues but does not start playback")
        }
    }
    @MainActor func testSetlistChangeDuringSaveRemainsPending() async throws {
        var project = Project.empty(name: "Save block")
        let song = Part(id: UUID(), name: "Song", startTime: 0, endTime: 5)
        project.songs[0].parts = [song]
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: project)
        XCTAssertTrue(show.createRegionPlaylist(name: "Show", selected: [song.id]))
        _ = show.addSetlistBlock()
        let save = Task { try await show.flushProject() }
        while !show.saving { await Task.yield() }
        _ = show.addSetlistBlock()
        try await save.value
        XCTAssertTrue(show.hasUnsavedChanges)
        try await show.flushProject()
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertNotNil(show.lastSavedAt)
        XCTAssertNotNil(show.lastSavedAt.flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    @MainActor func testHeldArrowOnlyCommitsAfterRelease() async throws {
        var project = Project.empty(name: "Held navigation")
        let regions = (0..<20).map { Part(id: UUID(), name: "Region \($0)", startTime: Double($0 * 10), endTime: Double($0 * 10 + 5)) }
        project.songs[0].parts = regions; project.songs[0].duration = 200
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        func waitForSelections(_ count: Int) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while executor.regionSelections.count < count, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        for _ in 0..<8 { show.stepRegion(1, commitAfterDelay: false) }
        XCTAssertEqual(show.focusedRegion, regions[7].id)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(executor.regionSelections.isEmpty, "holding must not seek even before the first repeat")
        show.finishRegionNavigation()
        try await waitForSelections(1)
        XCTAssertEqual(executor.regionSelections, [regions[7].id])
        show.stepRegion(-1, commitAfterDelay: false)
        show.finishRegionNavigation()
        show.stepRegion(-1, commitAfterDelay: false)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(executor.regionSelections, [regions[7].id], "a new hold cancels the previous release")
        show.finishRegionNavigation()
        try await waitForSelections(2)
        XCTAssertEqual(executor.regionSelections, [regions[7].id, regions[5].id])
    }
    @MainActor func testArrowNavigationVisitsOpenDrawerInBothDirectionsAndSkipsClosedChildren() throws {
        var project = Project.empty(name: "Drawer navigation")
        let before = Part(id: UUID(), name: "Before", startTime: 0, endTime: 5)
        let group = Part(id: UUID(), name: "Group", startTime: 10, endTime: 30)
        var first = Part(id: UUID(), name: "First", startTime: 10, endTime: 20)
        var second = Part(id: UUID(), name: "Second", startTime: 20, endTime: 30)
        first.parentRegionID = group.id; second.parentRegionID = group.id
        let after = Part(id: UUID(), name: "After", startTime: 40, endTime: 45)
        project.songs[0].parts = [before, group, second, first, after]
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let open: [SetlistEntry] = [.region(before, number: 1), .region(group, number: 2), .region(first, number: 1), .region(second, number: 2), .region(after, number: 3)]
        for expected in [before, group, first, second, after] {
            show.stepRegion(1, entries: open, commitAfterDelay: false)
            XCTAssertEqual(show.focusedRegion, expected.id)
        }
        for expected in [second, first, group, before] {
            show.stepRegion(-1, entries: open, commitAfterDelay: false)
            XCTAssertEqual(show.focusedRegion, expected.id)
        }
        show.stepRegion(1, entries: open, commitAfterDelay: false)
        show.stepRegion(1, entries: open, commitAfterDelay: false)
        XCTAssertEqual(show.focusedRegion, first.id)
        show.stepRegion(1, entries: show.setlistEntries, commitAfterDelay: false)
        XCTAssertEqual(show.focusedRegion, after.id, "closing the drawer anchors the hidden selection to its parent")
        show.stepRegion(-1, entries: show.setlistEntries, commitAfterDelay: false)
        XCTAssertEqual(show.focusedRegion, group.id)
        show.stepRegion(-1, entries: show.setlistEntries, commitAfterDelay: false)
        XCTAssertEqual(show.focusedRegion, before.id)
        XCTAssertTrue(executor.regionSelections.isEmpty)
        XCTAssertEqual(executor.projectEditCount, 0)
        XCTAssertFalse(show.hasUnsavedChanges)
    }
    @MainActor func testDrawerArrowBrowsingUsesVisiblePlaylistOrderAndPreservesPlaybackQueue() async throws {
        var project = Project.empty(name: "Playlist drawer")
        let group = Part(id: UUID(), name: "Group", startTime: 0, endTime: 20)
        var child = Part(id: UUID(), name: "Child", startTime: 5, endTime: 20)
        child.parentRegionID = group.id
        let other = Part(id: UUID(), name: "Other", startTime: 30, endTime: 40)
        project.songs[0].parts = [group, child, other]
        let executor = SaveTestExecutor(); executor.playing = true
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let block = SetlistBlock(id: UUID(), songId: project.songs[0].id, name: "Block", color: 0x55ee88)
        let visible: [SetlistEntry] = [.region(other, number: 1), .block(block), .region(group, number: 2), .region(child, number: 1)]
        let transport = show.snapshot.transport
        for expected in [other, group, child] {
            show.stepRegion(1, entries: visible, commitAfterDelay: false)
            XCTAssertEqual(show.focusedRegion, expected.id)
        }
        show.finishRegionNavigation()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(show.focusedRegion, child.id)
        XCTAssertTrue(executor.regionSelections.isEmpty)
        XCTAssertEqual(show.snapshot.transport, transport)
    }
    @MainActor func testArrowNavigationCommitsOnlyAfterRepose() async throws {
        var project = Project.empty(name: "Navigation")
        let regions = (0..<4).map { Part(id: UUID(), name: "Region \($0)", startTime: Double($0 * 10), endTime: Double($0 * 10 + 5)) }
        project.songs[0].parts = regions; project.songs[0].duration = 40
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        show.stepRegion(1); show.stepRegion(1); show.stepRegion(1)
        XCTAssertEqual(show.focusedRegion, regions[2].id)
        XCTAssertTrue(executor.regionSelections.isEmpty)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(executor.regionSelections, [regions[2].id])
        show.stepRegion(1)
        show.focusRegion(regions[0].id)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(executor.regionSelections, [regions[2].id, regions[0].id])
    }
    @MainActor func testArrowBrowsingDuringPlaybackNeverReplacesTheQueue() async throws {
        var project = Project.empty(name: "Browse during playback")
        let regions = (0..<4).map { Part(id: UUID(), name: "Region \($0)", startTime: Double($0 * 10), endTime: Double($0 * 10 + 5)) }
        project.songs[0].parts = regions
        let executor = SaveTestExecutor(); executor.playing = true
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: project)
        let transport = show.snapshot.transport
        show.stepRegion(1); show.stepRegion(1); show.stepRegion(1)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(show.focusedRegion, regions[2].id)
        XCTAssertTrue(executor.regionSelections.isEmpty)
        XCTAssertEqual(show.snapshot.transport, transport)
        show.focusRegion(regions[0].id)
        XCTAssertEqual(executor.regionCommands, [.queueRegion], "an explicit click still queues a song")
    }

    @MainActor func testMixerRespondsWithoutRequestingFullProjectSnapshot() throws {
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: .demo())
        let track = show.snapshot.project.songs[0].tracks[0]
        let reads = executor.snapshotCount
        var updates = 0
        show.audioUpdate = { _, _ in updates += 1 }
        show.send(.mute, target: track.id)
        XCTAssertEqual(show.snapshot.project.songs[0].tracks[0].mute, !track.mute)
        show.send(.solo, target: track.id)
        XCTAssertEqual(show.snapshot.project.songs[0].tracks[0].solo, !track.solo)
        show.send(.volume, target: track.id, value: 0.25)
        XCTAssertEqual(show.snapshot.project.songs[0].tracks[0].volume, 0.25)
        show.send(.mute)
        XCTAssertEqual(show.snapshot.project.masterMute, true)
        XCTAssertEqual(executor.snapshotCount, reads)
        XCTAssertEqual(updates, 4)
        XCTAssertTrue(show.hasUnsavedChanges)
    }

    @MainActor func testPanPreviewIsImmediateWithoutRebuildingProjectAndCommitPersists() throws {
        let executor = SaveTestExecutor()
        let show = try ShowController(executor: executor, persistence: SaveTestStore(), initialProject: .demo())
        let id = show.snapshot.project.songs[0].tracks[0].id
        let reads = executor.snapshotCount
        var values: [Double] = []
        show.audioPan = { target, value in XCTAssertEqual(target, id); values.append(value) }
        show.previewTrackPan(id, pan: -2)
        show.previewTrackPan(id, pan: 0.4)
        XCTAssertEqual(values, [-1, 0.4])
        XCTAssertEqual(show.snapshot.project.songs[0].tracks[0].pan, 0)
        XCTAssertEqual(executor.snapshotCount, reads)
        show.send(.pan, target: id, value: 0.4)
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(show.snapshot.project))
        XCTAssertEqual(restored.songs[0].tracks[0].pan, 0.4)
        show.send(.pan, target: id, value: 0)
        XCTAssertEqual(show.snapshot.project.songs[0].tracks[0].pan, 0)
    }

    @MainActor func testPlaylistReorderDoesNotMoveRegionsAndRejectsAllRegions() throws {
        var project = Project.empty(name: "Playlist order")
        let a = Part(id: UUID(), name: "A", startTime: 1, endTime: 2)
        let b = Part(id: UUID(), name: "B", startTime: 3, endTime: 4)
        let c = Part(id: UUID(), name: "C", startTime: 5, endTime: 6)
        project.songs[0].parts = [a, b, c]
        project.songs[0].duration = 10
        let list = RegionPlaylist(id: UUID(), name: "Show", songId: project.songs[0].id, regionIds: [a.id, b.id, c.id])
        project.regionSetlist = RegionSetlist(playlists: [list], selectedId: list.id)
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: project)
        show.reorderPlaylistRegion(a.id, relativeTo: c.id, after: true, playlist: list.id)
        XCTAssertEqual(show.listedRegions.map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(show.snapshot.project.songs, project.songs)
        XCTAssertTrue(show.hasUnsavedChanges)
        show.selectRegionPlaylist(nil)
        let before = show.snapshot.project
        show.reorderPlaylistRegion(c.id, relativeTo: b.id, after: false, playlist: list.id)
        XCTAssertEqual(show.snapshot.project, before)
        XCTAssertEqual(show.listedRegions.map(\.id), [a.id, b.id, c.id])
    }

    @MainActor func testSaveClearsOnlyTheRevisionActuallyWritten() async throws {
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: .empty(name: "Test"))
        XCTAssertFalse(show.hasUnsavedChanges)
        show.addTrack(name: "One", role: .click)
        XCTAssertTrue(show.hasUnsavedChanges)
        let save = Task { try await show.flushProject() }
        while !show.saving { await Task.yield() }
        show.addTrack(name: "Two", role: .keys)
        try await save.value
        XCTAssertTrue(show.hasUnsavedChanges)
        try await show.flushProject()
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertFalse(show.saving)
    }
    @MainActor func testClosingRequiresTheLatestChangesToBeSaved() async throws {
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(), initialProject: .empty(name: "Close"))
        show.addTrack(name: "One", role: .keys)
        let close = Task { try await show.saveForClosing() }
        while !show.saving { await Task.yield() }
        show.addTrack(name: "Two", role: .keys)
        do { try await close.value; XCTFail("Cannot close with unsaved changes") } catch {}
        XCTAssertTrue(show.hasUnsavedChanges)
        try await show.saveForClosing()
        XCTAssertFalse(show.hasUnsavedChanges)
    }

    @MainActor func testSaveDuringAutomationKeepsPlaybackAndWritingPassUntouched() async throws {
        for mode in [AutomationMode.write, .touch, .latch] {
            var project = Project.empty(name: "Save while performing")
            var row = Track(id: UUID(), name: "Synth", role: .keys)
            var automation = TrackAutomation(); automation.mode = mode
            var envelope = TrackEnvelope(target: AutomationTarget(.pan), name: "Pan", defaultValue: 0.5)
            envelope.armed = true; automation.envelopes = [envelope]
            row.automation = automation; project.songs[0].tracks = [row]
            let executor = SaveTestExecutor(); executor.playing = true
            let store = SaveTestStore()
            let show = try ShowController(executor: executor, persistence: store, initialProject: project)
            var overrides: [Double?] = [], audioUpdates = 0
            show.audioAutomationOverride = { _, _, value in overrides.append(value) }
            show.audioUpdate = { _, _ in audioUpdates += 1 }
            XCTAssertTrue(show.recordAutomationControl(row.id, target: envelope.target, value: 0.8))
            let pending = show.automation(row.id), transport = show.snapshot.transport
            let overrideCount = overrides.count, revision = show.projectRevision
            try await show.flushProject()
            let saved = await store.lastProject
            XCTAssertEqual(saved?.songs[0].tracks[0].automation, pending)
            XCTAssertEqual(show.automation(row.id), pending, "Save must not end the current automation pass")
            XCTAssertEqual(show.automation(row.id).mode, mode)
            XCTAssertEqual(show.snapshot.transport, transport)
            XCTAssertEqual(show.projectRevision, revision)
            XCTAssertEqual(audioUpdates, 0, "Saving must not reschedule playing audio")
            XCTAssertEqual(executor.projectEditCount, 0)
            XCTAssertEqual(overrides.count, overrideCount, "Save must not release live automation overrides")
            XCTAssertFalse(show.hasUnsavedChanges)
            XCTAssertTrue(show.recordAutomationControl(row.id, target: envelope.target, value: 0.3))
            XCTAssertTrue(show.hasUnsavedChanges)
            XCTAssertEqual(show.automation(row.id).envelopes[0].value(at: 0), 0.3)
        }
    }

    @MainActor func testAutomationWrittenDuringSaveRemainsPending() async throws {
        var project = Project.empty(name: "Automation save race")
        var automation = TrackAutomation(); automation.mode = .latch
        var envelope = TrackEnvelope(target: AutomationTarget(.volume), name: "Volume", defaultValue: 0.5)
        envelope.armed = true; automation.envelopes = [envelope]; project.masterAutomation = automation
        let executor = SaveTestExecutor(); executor.playing = true
        let store = SaveTestStore()
        let show = try ShowController(executor: executor, persistence: store, initialProject: project)
        XCTAssertTrue(show.recordAutomationControl(nil, target: envelope.target, value: 0.6))
        let save = Task { try await show.flushProject() }
        while !show.saving { await Task.yield() }
        XCTAssertTrue(show.recordAutomationControl(nil, target: envelope.target, value: 0.9))
        try await save.value
        let saved = await store.lastProject
        XCTAssertEqual(saved?.masterAutomation?.envelopes[0].value(at: 0), 0.6)
        XCTAssertTrue(show.hasUnsavedChanges)
        XCTAssertEqual(show.automation(nil).envelopes[0].value(at: 0), 0.9)
        try await show.flushProject()
        let latest = await store.lastProject
        XCTAssertEqual(latest?.masterAutomation, show.automation(nil))
        XCTAssertFalse(show.hasUnsavedChanges)
    }
    @MainActor func testClosingPropagatesSaveFailure() async throws {
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(fails: true), initialProject: .empty(name: "Close failure"))
        show.addTrack(name: "One", role: .keys)
        do { try await show.saveForClosing(); XCTFail("Cannot close after failed save") } catch {}
        XCTAssertTrue(show.hasUnsavedChanges)
    }

    @MainActor func testFailedSaveKeepsPendingState() async throws {
        let show = try ShowController(executor: SaveTestExecutor(), persistence: SaveTestStore(fails: true), initialProject: .empty(name: "Test"))
        show.addTrack(name: "One", role: .click)
        await show.save()
        XCTAssertTrue(show.hasUnsavedChanges)
        XCTAssertFalse(show.saving)
        XCTAssertEqual(show.message, "Disk unavailable")
        XCTAssertEqual(show.modalNotice, "Disk unavailable", "A failed Save must show its error, not only retain the pending indicator")
        XCTAssertNil(show.lastSavedAt, "failed writes must not advance the displayed saved date")
    }
    @MainActor func testDetachedOrDifferentDocumentCannotReportSuccessfulSaveOrClearDirtyState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-save-selection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Show.jl")
        for mismatchedDocument in [false, true] {
            let store = DocumentProjectStore()
            let project = Project.empty(name: "Unsaved edits")
            if mismatchedDocument { await store.select(url: destination, id: UUID()) }
            let show = try ShowController(executor: SaveTestExecutor(), persistence: store, initialProject: project)
            show.addTrack(name: "Keep this edit", role: .keys)
            await show.save()
            XCTAssertTrue(show.hasUnsavedChanges)
            XCTAssertFalse(show.saving)
            XCTAssertNil(show.lastSavedAt)
            XCTAssertFalse(show.message.isEmpty)
            XCTAssertNotEqual(show.message, "Projeto salvo.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(show.snapshot.project.songs[0].tracks.last?.name, "Keep this edit")
        }
    }
}


extension ProjectSaveTests {
    @MainActor func testContentEditSaveUndoRedoPreservesDirtyBoundaryAndSavedContents() async throws {
        let store = MemoryProjectStore()
        let executor = SaveTestExecutor()
        var project = Project.empty(name: "Dirty save and history")
        project.savedCursor = SavedProjectCursor(songID: project.songs[0].id, position: 0)
        let show = try ShowController(executor: executor, persistence: store, initialProject: project)
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertFalse(show.needsSave)
        let track = try XCTUnwrap(show.addTrack(name: "Recorded vocal", role: .other))
        XCTAssertTrue(show.hasUnsavedChanges)
        XCTAssertTrue(show.needsSave)
        XCTAssertTrue(show.canUndo)
        try await show.flushProject()
        var stored = await store.load()
        XCTAssertTrue(try XCTUnwrap(stored).songs[0].tracks.contains { $0.id == track })
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertFalse(show.needsSave)

        show.undo()
        XCTAssertFalse(show.current!.tracks.contains { $0.id == track })
        XCTAssertTrue(show.hasUnsavedChanges, "Undo after Save changes the saved document")
        XCTAssertTrue(show.canRedo)
        try await show.flushProject()
        stored = await store.load()
        XCTAssertFalse(try XCTUnwrap(stored).songs[0].tracks.contains { $0.id == track })
        XCTAssertFalse(show.needsSave)

        show.redo()
        XCTAssertTrue(show.current!.tracks.contains { $0.id == track })
        XCTAssertTrue(show.hasUnsavedChanges, "Redo after saving the undone state is another real content edit")
        try await show.flushProject()
        stored = await store.load()
        XCTAssertTrue(try XCTUnwrap(stored).songs[0].tracks.contains { $0.id == track })
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertFalse(show.needsSave)
    }
}
