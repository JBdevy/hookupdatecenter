import Foundation

@main struct ProjectCursorBridgeTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(url: directory.appendingPathComponent("Cursor.jl"))
        let show = try ShowController(executor: LocalCommandExecutor(), persistence: store,
            initialProject: .demo())
        show.send(.editSeek, value: 42.125)
        try await show.flushProject()
        guard let document = try await store.load() else { fatalError("Saved document missing") }
        precondition(document.savedCursor?.position == 42.125)
        // A new controller and real native executor have no local cursor memory.
        let reopened = try ShowController(executor: LocalCommandExecutor(), persistence: store,
            initialProject: document)
        precondition(reopened.snapshot.transport.editPosition == 42.125)
        precondition(reopened.snapshot.transport.position == 42.125)
        precondition(reopened.restoredCursorPosition == 42.125 && !reopened.isPlaying)
        precondition(!reopened.needsSave)
        let track = reopened.current!.tracks[0].id
        let item = reopened.current!.tracks[0].clips[0].id
        reopened.toggleItemPhase(item)
        reopened.setItemPan(item, pan: -0.75)
        precondition(reopened.current!.tracks[0].clips[0].phaseInverted == true)
        precondition(reopened.current!.tracks[0].clips[0].pan == -0.75)
        reopened.send(.volume, target: track, value: 0.5)
        reopened.send(.editSeek, value: 71.5)
        precondition(reopened.needsSave)
        try await reopened.flushProject()
        precondition(!reopened.needsSave)
        let editedDocument = try await store.load()!
        let next = try ShowController(executor: LocalCommandExecutor(), persistence: store,
            initialProject: editedDocument)
        precondition(next.snapshot.project.savedCursor?.position == 71.5)
        precondition(next.snapshot.transport.editPosition == 71.5)
        precondition(next.current!.tracks[0].volume == 0.5)
        precondition(next.current!.tracks[0].clips[0].phaseInverted == true)
        precondition(next.current!.tracks[0].clips[0].pan == -0.75)
        for kind in TrackKind.allCases where kind != .video {
            let executor = LocalCommandExecutor()
            var project = Project.empty(name: "Movie on " + kind.title)
            var track = Track(id: UUID(), name: kind.title, role: TrackRole(rawValue: kind == .standard ? "other" : kind.rawValue))
            if kind == .timecode { track.timecode = TimecodeSettings() }
            project.songs[0].tracks = [track]
            try executor.load(project)
            let media = AudioClip(id: UUID(), name: "Movie", startTime: 40, duration: 2, audioFile: AudioFile(path: "Videos/movie.mov"))
            track.clips = [media]
            try executor.insertAudioTracks([track], song: project.songs[0].id)
            var state = try executor.snapshot()
            precondition(state.project.songs[0].tracks[0].clips.contains { $0.id == media.id })
            try executor.moveClip(media.id, start: 50, track: track.id)
            try executor.execute(.clipPhase, target: media.id, value: 1)
            try executor.execute(.clipPan, target: media.id, value: 0.6)
            try executor.setClipFX(media.id, settings: NativeFXSettings())
            if kind == .timecode {
                var tc = TimecodeSettings(); tc.mode = "ltc"
                try executor.setTimecode(track.id, settings: tc)
                let named = try executor.snapshot(); precondition(named.project.songs[0].tracks[0].clips.first { $0.id == media.id }?.name == "Movie")
            }
            state = try executor.snapshot()
            let clip = state.project.songs[0].tracks[0].clips.first { $0.id == media.id }!
            precondition(clip.startTime == 50 && clip.phaseInverted == true && clip.pan == 0.6)
            var copied = track; copied.clips = [clip]; copied.clips[0].id = UUID(); copied.clips[0].startTime = 60
            try executor.pasteItems([GridItemClipboard.Entry(track: track.id, clip: copied.clips[0])], song: project.songs[0].id, moving: false)
            state = try executor.snapshot()
            state.project.deleteItems([media.id, copied.clips[0].id])
            try executor.applyProjectEdit(state.project)
            let deleted = try executor.snapshot(); precondition(deleted.project.songs[0].tracks[0].clips.allSatisfy { !$0.isProjectionMedia })
        }
        print("NATIVE_MEDIA_ALL_TRACK_KINDS_INSERT_MOVE_PASTE_FX_MIX_DELETE_OK")
        print("PROJECT_CURSOR_ENCRYPTED_SAVE_NATIVE_REOPEN_AND_RESAVE_OK")
    }
}
