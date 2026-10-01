import XCTest
@testable import JarasApplication

final class ProjectEditingTests: XCTestCase {
    func testScalarHistoryRetainsClipStorageAndSupportsUndoRedo() {
        var project = fixture()
        let waveform = (0..<100000).map { Double($0) / 100000 }
        project.songs[0].tracks[0].clips = (0..<2000).map { index in
            AudioClip(id: UUID(), name: "Item", startTime: Double(index), duration: 1, waveform: waveform)
        }
        let original = project
        var history = ProjectEditHistory(project)
        let started = Date()
        for index in 1...20 {
            project.songs[0].tracks[0].volume = Double(index) / 20
            history.record(project, preservingMediaStorage: true)
        }
        print("SCALAR_HISTORY_2000_ITEMS_20_EDITS_MS=\(Date().timeIntervalSince(started) * 1000)")
        let final = project
        let undone = history.undo()!
        XCTAssertEqual(undone.songs[0].tracks[0].volume, 0.95)
        let restored = history.redo()!
        XCTAssertEqual(restored, final)
        original.songs[0].tracks[0].clips.withUnsafeBufferPointer { old in
            restored.songs[0].tracks[0].clips.withUnsafeBufferPointer { next in
                XCTAssertEqual(old.baseAddress, next.baseAddress, "scalar history shares unchanged item storage")
            }
        }
        _ = history.undo()
        project.songs[0].tracks[0].pan = 0.5
        history.record(project, preservingMediaStorage: true)
        XCTAssertFalse(history.canRedo)
    }

    func testCompleteExportUsesAudioEndRatherThanRegionsOrAuxiliaryItems() {
        var song = fixture().songs[0]
        song.parts = [Part(id: UUID(), name: "Long region", startTime: 0, endTime: 280)]
        var video = Track(id: UUID(), name: "Video", role: TrackRole(rawValue: "video"))
        video.clips = [AudioClip(id: UUID(), name: "Movie", startTime: 200, duration: 100, waveform: [], audioFile: AudioFile(path: "Videos/movie.mov"))]
        song.tracks.append(video)
        XCTAssertEqual(song.completeAudioExportEnd, 50)
        song.tracks[0].clips[0].duration = 40
        XCTAssertEqual(song.completeAudioExportEnd, 70)
        song.tracks[0].clips = []
        XCTAssertEqual(song.completeAudioExportEnd, 0)
    }
    func testRegionUppercasePreservesOriginalAndParentheses() throws {
        var region = Part(id: UUID(), name: "Canção (Ao vivo) final (Tom: Ré)", startTime: 0, endTime: 10)
        XCTAssertEqual(region.displayName, "CANÇÃO (Ao vivo) FINAL (Tom: Ré)")
        region.uppercaseName = false
        XCTAssertEqual(region.displayName, region.name)
        let restored = try JSONDecoder().decode(Part.self, from: JSONEncoder().encode(region))
        XCTAssertEqual(restored, region)
        XCTAssertEqual(restored.displayName, "Canção (Ao vivo) final (Tom: Ré)")
        region.uppercaseName = true
        region.name = "Música (ao vivo (Solo)) fim"
        XCTAssertEqual(region.displayName, "MÚSICA (ao vivo (Solo)) FIM")
    }

    private func fixture() -> Project {
        var project = Project.empty(name: "Editing")
        project.songs[0].duration = 300
        var parent = Track(id: UUID(), name: "Keys", role: .keys)
        var child = Track(id: UUID(), name: "Piano", role: .keys)
        child.parentTrackID = parent.id; child.patch = .masterGroup; child.secondaryPatch = .stereo
        parent.clips = [AudioClip(id: UUID(), name: "Take", startTime: 30, duration: 20, waveform: [0.1,0.2,0.3,0.4], audioFile: AudioFile(path: "Steams/take.wav"), playbackRate: 2)]
        project.songs[0].tracks = [parent, child]
        return project
    }
    func testDeletePriorityAndUndoRedoPreserveMediaAndRouting() throws {
        var project = fixture(); let original = project
        let track = project.songs[0].tracks[0], clip = track.clips[0]
        XCTAssertTrue(project.tracksContainItems([track.id]))
        XCTAssertFalse(project.tracksContainItems([project.songs[0].tracks[1].id]))
        XCTAssertEqual(GridDeleteTarget(items: [clip.id], tracks: [track.id]), .items([clip.id]))
        XCTAssertEqual(GridDeleteTarget(items: [], tracks: [track.id]), .tracks([track.id]))
        var history = ProjectEditHistory(project)
        project.deleteItems([clip.id]); history.record(project)
        XCTAssertFalse(project.tracksContainItems([track.id]))
        XCTAssertEqual(project.songs[0].tracks.count, 2)
        XCTAssertEqual(history.undo(), original)
        XCTAssertEqual(history.redo(), project)
        project.deleteTracks([track.id]); history.record(project)
        XCTAssertNil(project.songs[0].tracks[0].parentTrackID)
        XCTAssertEqual(project.songs[0].tracks[0].primaryOutput, .master)
        XCTAssertEqual(project.songs[0].tracks[0].secondaryOutput, .stereo)
        try project.validate()
        _ = history.undo(); var edit = original; edit.ungroupTrack(track.id); history.record(edit)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(edit.songs[0].tracks.count, 2)
    }
    func testPlaylistRemovalDoesNotDeleteRegionAndLastEntryIsAllowed() throws {
        var project = fixture()
        let region = Part(id: UUID(), name: "Song", startTime: 30, endTime: 50)
        project.songs[0].parts = [region]
        let playlist = RegionPlaylist(id: UUID(), name: "Set", songId: project.songs[0].id, regionIds: [region.id])
        var state = RegionSetlist(); state.playlists = [playlist]; state.selectedId = playlist.id
        state.blocks = [SetlistBlock(id: UUID(), songId: project.songs[0].id, playlistId: playlist.id, name: "Block", color: 0xff0000, beforeRegionId: region.id)]
        project.regionSetlist = state
        project.removeRegion(region.id, from: playlist.id)
        XCTAssertEqual(project.songs[0].parts.count, 1)
        XCTAssertTrue(project.regionSetlist!.playlists[0].regionIds.isEmpty)
        XCTAssertNil(project.regionSetlist!.blocks![0].beforeRegionId)
        try project.validate()
        project.deleteRegion(region.id)
        XCTAssertTrue(project.songs[0].parts.isEmpty)
        XCTAssertEqual(project.songs[0].tracks[0].clips.count, 1)
        try project.validate()
    }
    func testSplitSourceOffsetsAndUnlimitedRecordingLanes() throws {
        var project = fixture(); let clip = project.songs[0].tracks[0].clips[0]
        project.splitItems([clip.id], at: 35)
        let clips = project.songs[0].tracks[0].clips
        XCTAssertEqual(clips.map(\.duration), [5,15])
        XCTAssertEqual(clips[1].sourceOffset, 10)
        XCTAssertEqual(clips[0].audioFile, clips[1].audioFile)
        XCTAssertEqual(clips[0].waveform + clips[1].waveform, clip.waveform)
        for lane in 1...20 { var take = clip; take.id = UUID(); take.recordingLane = lane; project.songs[0].tracks[0].clips.append(take) }
        XCTAssertEqual(TrackLanes(track: project.songs[0].tracks[0]).count, 21)
        try project.validate()
    }
    func testResizeRepeatsOriginalSourceAndKeepsSplitGain() throws {
        var project = fixture(); let original = project.songs[0].tracks[0].clips[0]
        project.resizeItem(original.id, start: 25, end: 90)
        let expanded = project.songs[0].tracks[0].clips[0]
        XCTAssertEqual(expanded.loopStart, 0)
        XCTAssertEqual(expanded.loopLength, 40)
        XCTAssertEqual(expanded.sourceOffset, 30)
        XCTAssertEqual(expanded.duration, 65)
        XCTAssertEqual(expanded.audioFile, original.audioFile)
        XCTAssertEqual(expanded.waveform, original.waveform)
        project.songs[0].tracks[0].clips[0].gain = 0.5
        project.splitItems([original.id], at: 40)
        XCTAssertEqual(project.songs[0].tracks[0].clips.map(\.gain), [0.5,0.5])
        XCTAssertEqual(project.songs[0].tracks[0].clips[1].waveform, original.waveform)
        try project.validate()
    }
    func testCleanupOnlyAtCloseKeepsUndoAndRecoverableBackups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var project = fixture(); let document = root.appendingPathComponent("Show.jl")
        let source = root.appendingPathComponent("Steams/take.wav")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1,2,3,4]).write(to: source)
        try ProjectBackups.save(project, to: document)
        let known = project.mediaPaths
        project.deleteItems([project.songs[0].tracks[0].clips[0].id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try ProjectBackups.save(project, to: document)
        try ProjectMediaCleanup.close(project: project, document: document, knownPaths: known)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let backup = try ProjectDocumentCodec.decode(Data(contentsOf: ProjectBackups.files(for: document)[0]))
        let archived = try XCTUnwrap(backup.mediaPaths.first)
        XCTAssertTrue(archived.hasPrefix("backups/Media/"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(archived)), Data([1,2,3,4]))
    }
    func testBypassRetainsInstrumentAndEffectParameters() throws {
        var fx = NativeFXSettings(); fx.inserted = ["Instruments", "EQ"]; fx.instrumentID = "Piano"; fx.eqEnabled = true
        fx.setEnabled("Instruments", enabled: false); fx.setEnabled("EQ", enabled: false)
        XCTAssertEqual(fx.instrumentID, "Piano"); XCTAssertFalse(fx.isEnabled("Instruments")); XCTAssertFalse(fx.eqEnabled)
        let restored = try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(fx))
        XCTAssertEqual(restored, fx)
        fx.setEnabled("Instruments", enabled: true); XCTAssertTrue(fx.isEnabled("Instruments"))
    }
}
