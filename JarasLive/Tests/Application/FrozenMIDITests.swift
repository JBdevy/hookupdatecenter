import XCTest
@testable import JarasApplication

@MainActor private final class FrozenMIDIExecutor: CommandExecutor {
    var project = Project.empty(name: "Freeze")
    func load(_ value: Project) throws { project = value }
    func snapshot() throws -> ShowSnapshot {
        ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs.first?.id, position: 0,
            queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: try snapshot().transport) }
    func applyProjectEdit(_ value: Project) throws { try value.validate(); project = value }
    func replaceAudioClip(_ clip: AudioClip, track: UUID) throws {
        let channel = project.songs[0].tracks.firstIndex { $0.id == track }!
        let item = project.songs[0].tracks[channel].clips.firstIndex { $0.id == clip.id }!
        project.songs[0].tracks[channel].clips[item] = clip
    }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}

final class FrozenMIDITests: XCTestCase {
    @MainActor func testFreezeUndoRedoSaveResizeSplitAndTempo() throws {
        var project = Project.empty(name: "Freeze")
        let midi = MIDIItem(notes: [MIDINote(start: 0, length: 4, pitch: 64)])
        let original = AudioClip(id: UUID(), name: "MIDI", startTime: 2, duration: 2, midi: midi)
        var track = Track(id: UUID(), name: "Instrument", role: .keys)
        track.clips = [original]; project.songs[0].tracks = [track]
        project.songs[0].timeSettings = ProjectTimeSettings()
        project.songs[0].timeSettings?.timebase = .relative
        project.songs[0].markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 2, color: 0, tempoBPM: 240)]
        let show = try ShowController(executor: FrozenMIDIExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        var frozen = original
        frozen.audioFile = AudioFile(path: "Stems/performance.wav"); frozen.midi = nil; frozen.frozenMIDI = true
        XCTAssertTrue(show.replaceRenderedItem(frozen, original: original, track: track.id, project: project.id))
        XCTAssertEqual(show.current?.tracks[0].clips[0], frozen)
        XCTAssertEqual(show.current?.tempoAudioSegments(frozen), [frozen])
        show.undo(); XCTAssertEqual(show.current?.tracks[0].clips[0], original)
        show.redo(); XCTAssertEqual(show.current?.tracks[0].clips[0], frozen)
        let reopened = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(show.snapshot.project))
        XCTAssertEqual(reopened.songs[0].tracks[0].clips[0], frozen)
        show.resizeItem(frozen.id, start: 2.25, end: 4)
        XCTAssertEqual(show.current?.tracks[0].clips[0].frozenMIDI, true)
        show.splitItems([frozen.id], at: 3)
        let pieces = try XCTUnwrap(show.current?.tracks[0].clips)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces.allSatisfy { $0.frozenMIDI == true && $0.midi == nil })
        XCTAssertTrue(pieces.allSatisfy { show.current?.tempoAudioSegments($0) == [$0] })
        let legacy = try JSONDecoder().decode(AudioClip.self, from: JSONEncoder().encode(original))
        XCTAssertNil(legacy.frozenMIDI)
    }

    func testGlueMIDIPreservesTrimRateTempoChannelsVelocityAndGaps() throws {
        var project = Project.empty(name: "Glue MIDI")
        var track = Track(id: UUID(), name: "Keys", role: .keys)
        let a = AudioClip(id: UUID(), name: "First", startTime: 0.2, duration: 1.2, sourceOffset: 0.1, gain: 0.5, playbackRate: 1.5,
            midi: MIDIItem(notes: [MIDINote(start: 0, length: 3, pitch: 60, velocity: 100, channel: 2), MIDINote(start: 0.8, length: 0.2, pitch: 67, channel: 16)]))
        let b = AudioClip(id: UUID(), name: "Second", startTime: 2, duration: 0.6, sourceOffset: 0.05, playbackRate: 0.75,
            midi: MIDIItem(notes: [MIDINote(start: 0.2, length: 0.5, pitch: 64, velocity: 120, channel: 9)], sourceBPM: 90))
        track.clips = [a, b]; project.songs[0].tracks = [track]
        project.songs[0].timeSettings = ProjectTimeSettings(); project.songs[0].timeSettings?.timebase = .relative
        project.songs[0].markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 0.7, color: 0,
            tempoBPM: 240, tempoTimebase: .relative, tempoReferenceBPM: 120)]
        let song = project.songs[0]
        let result = try ItemGlue.midi(song: song, track: track, clips: [b, a])
        XCTAssertEqual(result.startTime, 0.2); XCTAssertEqual(result.duration, 2.4, accuracy: 0.000001)
        XCTAssertNil(result.audioFile); XCTAssertEqual(result.sourceOffset, 0); XCTAssertEqual(result.audioRate, 1)
        let expected = [a, b].flatMap { song.midiPlaybackNotes(in: $0) }.sorted { $0.start < $1.start }
        let actual = song.midiPlaybackNotes(in: result)
        XCTAssertEqual(actual.count, expected.count)
        for (new, old) in zip(actual, expected) {
            XCTAssertEqual(new.start, old.start, accuracy: 0.000001); XCTAssertEqual(new.end, old.end, accuracy: 0.000001)
            XCTAssertEqual(new.pitch, old.pitch); XCTAssertEqual(new.velocity, old.velocity); XCTAssertEqual(new.channel, old.channel)
        }
        var muted = a; muted.muted = true
        let single = try ItemGlue.midi(song: song, track: track, clips: [muted])
        XCTAssertEqual(single.muted, true); XCTAssertFalse(single.midi!.notes.isEmpty)
        XCTAssertEqual(single.startTime, a.startTime); XCTAssertEqual(single.duration, a.duration)
        let audio = AudioClip(id: UUID(), name: "Audio", startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/original.wav"))
        XCTAssertThrowsError(try ItemGlue.validate(track: track, clips: [a, audio]))
        var frozen = audio; frozen.id = UUID(); frozen.frozenMIDI = true
        XCTAssertThrowsError(try ItemGlue.validate(track: track, clips: [audio, frozen]))
    }

    @MainActor func testGlueMultipleTracksOneUndoStaleGuardAndAudioTimingRoundtrip() throws {
        var project = Project.empty(name: "Glue transaction")
        let a = AudioClip(id: UUID(), name: "A", startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/a.wav"))
        let b = AudioClip(id: UUID(), name: "B", startTime: 2, duration: 1, audioFile: AudioFile(path: "Stems/b.wav"))
        let midi = AudioClip(id: UUID(), name: "MIDI", startTime: 1, duration: 1, midi: MIDIItem(notes: [MIDINote(start: 0, length: 1, pitch: 60)]))
        var audioTrack = Track(id: UUID(), name: "Audio", role: .keys), midiTrack = Track(id: UUID(), name: "MIDI", role: .keys)
        audioTrack.clips = [a, b]; midiTrack.clips = [midi]; project.songs[0].tracks = [audioTrack, midiTrack]
        let song = project.songs[0]
        let rendered = AudioClip(id: UUID(), name: "Glued", startTime: 0, duration: 3, audioFile: AudioFile(path: "Stems/glued.wav"), renderedTiming: true)
        let combinedMIDI = try ItemGlue.midi(song: song, track: midiTrack, clips: [midi])
        let replacements = [GluedItemReplacement(track: audioTrack.id, originals: [a, b], rendered: rendered),
                            GluedItemReplacement(track: midiTrack.id, originals: [midi], rendered: combinedMIDI)]
        let show = try ShowController(executor: FrozenMIDIExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        var stale = b; stale.gain = 0.2
        XCTAssertFalse(show.replaceGluedItems([replacements[1], GluedItemReplacement(track: audioTrack.id, originals: [a, stale], rendered: rendered)], project: project.id, song: song.id))
        XCTAssertEqual(show.snapshot.project, project); XCTAssertFalse(show.canUndo)
        XCTAssertTrue(show.replaceGluedItems(replacements, project: project.id, song: song.id))
        XCTAssertEqual(show.current?.tracks[0].clips, [rendered]); XCTAssertEqual(show.current?.tracks[1].clips, [combinedMIDI])
        show.undo(); XCTAssertEqual(show.snapshot.project, project)
        show.redo(); XCTAssertEqual(show.current?.tracks[0].clips, [rendered])
        let reopened = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(show.snapshot.project))
        XCTAssertEqual(reopened.songs[0].tracks[0].clips[0].renderedTiming, true)
        XCTAssertNil(reopened.songs[0].tracks[0].clips[0].frozenMIDI)
        show.resizeItem(rendered.id, start: 0.2, end: 3); show.splitItems([rendered.id], at: 1.5)
        XCTAssertEqual(show.current?.tracks[0].clips.count, 2)
        XCTAssertTrue(show.current!.tracks[0].clips.allSatisfy { $0.renderedTiming == true })
        XCTAssertTrue(show.knownMediaPaths.isSuperset(of: ["Stems/a.wav", "Stems/b.wav", "Stems/glued.wav"]))
    }
}
