import XCTest
@testable import JarasApplication

final class TrackVisibilityTests: XCTestCase {
    private func tracks() -> [Track] {
        let group = Track(id: UUID(), name: "Group", role: .other)
        var folder = Track(id: UUID(), name: "Nested", role: .other)
        folder.parentTrackID = group.id
        var child = Track(id: UUID(), name: "Child", role: .other)
        child.parentTrackID = folder.id
        child.clips = [AudioClip(id: UUID(), name: "Audio", startTime: 4, duration: 8, audioFile: AudioFile(path: "Stems/audio.wav"))]
        child.volume = 0.63; child.pan = -0.2
        return [group, folder, child, Track(id: UUID(), name: "Outside", role: .bass)]
    }
    func testFolderVisibilityIsRecursiveAndRetainsIndependentChildChoices() {
        let tracks = tracks()
        var state = TrackVisibilityState()
        state.setVisible(false, track: tracks[2].id, in: .trackMixer)
        state.setVisible(false, track: tracks[0].id, in: .trackMixer)
        XCTAssertEqual(state.visibleTracks(in: tracks, area: .trackMixer), [tracks[3]])
        XCTAssertEqual(state.trackMixer, [tracks[0].id, tracks[2].id])
        XCTAssertEqual(state.visibleTracks(in: tracks, area: .barMixer), tracks)
        state.setVisible(true, track: tracks[0].id, in: .trackMixer)
        XCTAssertEqual(state.visibleTracks(in: tracks, area: .trackMixer), [tracks[0], tracks[1], tracks[3]])
        state.setVisible(true, track: tracks[2].id, in: .trackMixer)
        XCTAssertEqual(state.visibleTracks(in: tracks, area: .trackMixer), tracks)
    }
    func testNewChildrenFollowHiddenParentAndMovingOutsideRestoresVisibility() {
        var tracks = tracks()
        let state = TrackVisibilityState(barMixer: [tracks[0].id])
        var newChild = Track(id: UUID(), name: "New", role: .other)
        newChild.parentTrackID = tracks[1].id
        tracks.append(newChild)
        XCTAssertTrue(state.effectiveHidden(in: tracks, area: .barMixer).contains(newChild.id))
        tracks[4].parentTrackID = nil
        XCTAssertFalse(state.effectiveHidden(in: tracks, area: .barMixer).contains(newChild.id))
        XCTAssertEqual(state.visibleTracks(in: tracks, area: .trackMixer), tracks)
    }
    func testDeleteTargetsTrackSelectedInBarMixerWhenItsGridRowIsHidden() {
        var project = Project.empty(name: "Mixer selection")
        let tracks = tracks()
        project.songs[0].tracks = tracks
        project.songs[0].parts = [Part(id: UUID(), name: "Keep region", startTime: 0, endTime: 20)]
        let song = project.songs[0], selected = tracks[2].id
        var state = TrackVisibilityState(trackMixer: [tracks[0].id])
        let target = GridDeleteTarget(items: [], tracks: [selected], song: song, visibility: state)
        XCTAssertEqual(target, .tracks([selected]), "Bar selection must not fall through to the focused region")
        if case .tracks(let ids) = target { project.deleteTracks(ids) }
        XCTAssertFalse(project.songs[0].tracks.contains { $0.id == selected })
        XCTAssertEqual(project.songs[0].parts, song.parts)
        state.barMixer = [tracks[0].id]
        XCTAssertEqual(GridDeleteTarget(items: [], tracks: [selected], song: song, visibility: state), .none)
        state.trackMixer = []
        XCTAssertEqual(GridDeleteTarget(items: [tracks[2].clips[0].id], tracks: [selected], song: song, visibility: state),
                       .items([tracks[2].clips[0].id]))
    }
    @MainActor func testPreferencesAreLocalPerProjectAndPanelAndRestoreAcrossLaunches() throws {
        let suite = "catlive.track-visibility.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID(), tracks = tracks()
        var project = Project.empty(name: "Keep project untouched")
        project.id = first; project.songs[0].tracks = tracks
        let document = try JSONEncoder().encode(project)
        let preferences = TrackVisibilityPreferences(defaults: defaults)
        XCTAssertEqual(preferences.state(for: first), TrackVisibilityState())
        preferences.setVisible(false, track: tracks[0].id, in: .trackMixer, project: first)
        preferences.setVisible(false, track: tracks[3].id, in: .barMixer, project: first)
        XCTAssertEqual(preferences.state(for: second), TrackVisibilityState())
        let restored = TrackVisibilityPreferences(defaults: defaults).state(for: first)
        XCTAssertEqual(restored.visibleTracks(in: tracks, area: .trackMixer), [tracks[3]])
        XCTAssertEqual(restored.visibleTracks(in: tracks, area: .barMixer), Array(tracks.prefix(3)))
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: document), project)
        XCTAssertEqual(project.songs[0].tracks[2].volume, 0.63)
        XCTAssertEqual(project.songs[0].tracks[2].pan, -0.2)
        XCTAssertEqual(project.songs[0].tracks[2].clips.count, 1)
        XCTAssertEqual(project.songs[0].tracks[2].parentTrackID, tracks[1].id)
        let previousRevision = preferences.revision
        preferences.setVisible(false, track: tracks[0].id, in: .trackMixer, project: first)
        XCTAssertEqual(preferences.revision, previousRevision, "Repeated checkbox state does not invalidate the workspace")
    }
}
