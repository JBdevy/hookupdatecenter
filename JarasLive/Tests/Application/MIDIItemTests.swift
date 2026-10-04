import XCTest
@testable import JarasApplication
final class MIDIItemTests: XCTestCase {
    func testEveryDivisionAndTimingMode() {
        for division in MIDIGrid.divisions {
            let straight=MIDIGrid(division:division)
            XCTAssertEqual(straight.step,4/Double(division),accuracy:1e-12)
            XCTAssertEqual(MIDIGrid(division:division,mode:.triplet).step,straight.step*2/3,accuracy:1e-12)
            XCTAssertEqual(MIDIGrid(division:division,mode:.dotted).step,straight.step*1.5,accuracy:1e-12)
            let swing=MIDIGrid(division:division,mode:.swing,swing:0.5)
            XCTAssertEqual(swing.line(1),straight.step*1.5,accuracy:1e-12)
            XCTAssertEqual(swing.line(2),straight.step*2,accuracy:1e-12)
            XCTAssertEqual(swing.snap(straight.step*1.4),swing.line(1),accuracy:1e-12)
        }
        XCTAssertEqual(MIDIGrid().snap(0.12345,bypass:true),0.12345)
    }
    func testQuantizeSelectionStrengthAndLengths() {
        let a=MIDINote(start:0.12,length:0.3,pitch:60),b=MIDINote(start:0.13,length:0.3,pitch:62)
        let grid=MIDIGrid(division:16)
        let notes=grid.quantize([a,b],selected:[a.id],strength:0.5,lengths:false)
        XCTAssertEqual(notes[0].start,0.06,accuracy:1e-12);XCTAssertEqual(notes[0].length,a.length);XCTAssertEqual(notes[1],b)
        let full=grid.quantize([a],lengths:true)[0]
        XCTAssertEqual(full.start,0);XCTAssertEqual(full.end,0.5,accuracy:1e-12)
        XCTAssertEqual(grid.quantize([a],strength:0),[a])
    }
    func testTempoChangeKeepsSustainedNoteContinuous() {
        var song=Project.empty(name:"Tempo MIDI").songs[0]
        song.timeSettings=ProjectTimeSettings(); song.timeSettings?.timebase = .relative
        song.markers=[TimelineMarker(id:UUID(),name:"TEMPO",position:2,color:0x999999,tempoBPM:240)]
        let note=MIDINote(start:0,length:12,pitch:60)
        let clip=AudioClip(id:UUID(),name:"MIDI",startTime:0,duration:4,midi:MIDIItem(notes:[note]))
        XCTAssertEqual(song.tempoAudioSegments(clip).count,2)
        let playback=song.midiPlaybackNotes(in:clip)
        XCTAssertEqual(playback.count,1,"a held note must not retrigger at a tempo marker")
        XCTAssertEqual(playback.first?.start,0); XCTAssertEqual(playback.first?.end,4)
    }
    func testTrimRateMuteAndSerialization() throws {
        let data=MIDIItem(notes:[MIDINote(start:0,length:4,pitch:60),MIDINote(start:6,length:1,pitch:64)],sourceBPM:120)
        var clip=AudioClip(id:UUID(),name:"MIDI",startTime:10,duration:1,sourceOffset:0.5,playbackRate:2,midi:data)
        let notes=clip.midiPlaybackNotes();XCTAssertEqual(notes.count,1);XCTAssertEqual(notes[0].start,10);XCTAssertEqual(notes[0].end,10.75)
        let restored=try JSONDecoder().decode(AudioClip.self,from:JSONEncoder().encode(clip));XCTAssertEqual(restored,clip)
        clip.muted=true;XCTAssertTrue(clip.midiPlaybackNotes().isEmpty)
        var invalid=data;invalid.notes[0].pitch=128;XCTAssertThrowsError(try invalid.validate())
        invalid=data;invalid.notes.append(invalid.notes[0]);XCTAssertThrowsError(try invalid.validate())
        invalid=data;invalid.notes[0].length = .nan;XCTAssertThrowsError(try invalid.validate())
    }
}

@MainActor private final class MIDIEditExecutor: CommandExecutor {
    var project=Project.empty(name:"MIDI")
    func load(_ project:Project) throws {self.project=project}
    func snapshot() throws -> ShowSnapshot {ShowSnapshot(project:project,transport:TransportState(playing:false,songId:project.songs.first?.id,position:0,queue:QueueState(),loop:LoopState(enabled:false),subPlay:SubPlayState(playing:false,position:0)))}
    func playbackSnapshot() throws -> PlaybackSnapshot {PlaybackSnapshot(transport:try snapshot().transport)}
    func applyProjectEdit(_ value:Project) throws {try value.validate();project=value}
    func setRecordingChannels(_ track: UUID, channel: Int) throws { project.songs[0].tracks[0].recordingChannels = channel }
    func setMIDIInput(_ track: UUID, slot: Int) throws { project.songs[0].tracks[0].midiInput = slot }
    func addRecordedClip(_ clip: AudioClip, track: UUID) throws { project.songs[0].tracks[0].clips.append(clip); project.songs[0].duration = max(project.songs[0].duration, clip.startTime + clip.duration) }
    func execute(_ command:ShowCommand,target:UUID?,value:Double) throws {}
    func addTrack(id:UUID,name:String,role:TrackRole) throws {}
    func advance(_ elapsed:Double) {}
    func finishCurrentSong(_ enabled:Bool) {}
}

extension MIDIItemTests {
    func testRecordingPreservesNoteOffZeroVelocityChannelsAndHeldNotes() throws {
        let song = Project.empty(name: "Capture").songs[0]
        var take = MIDIRecordingTake(track: UUID(), song: song, startTime: 10)
        take.receive(source: 1, status: 0x90, number: 60, value: 88, position: 9)
        take.receive(source: 1, status: 0x90, number: 60, value: 88, position: 10.25)
        take.receive(source: 1, status: 0x91, number: 60, value: 99, position: 10.5)
        take.receive(source: 1, status: 0x80, number: 60, value: 0, position: 11)
        take.receive(source: 1, status: 0x91, number: 60, value: 0, position: 11.5)
        take.receive(source: 2, status: 0x9f, number: 64, value: 100, position: 11.75)
        let clip = try XCTUnwrap(take.finish(at: 12))
        try clip.midi?.validate()
        XCTAssertNil(clip.audioFile)
        XCTAssertEqual(clip.startTime, 10); XCTAssertEqual(clip.duration, 2)
        let playback = song.midiPlaybackNotes(in: clip)
        XCTAssertEqual(playback.count, 3)
        XCTAssertEqual(playback.map(\.channel), [1, 2, 16])
        XCTAssertEqual(playback.map(\.velocity), [88, 99, 100])
        XCTAssertEqual(playback[0].start, 10.25, accuracy: 0.000001)
        XCTAssertEqual(playback[0].end, 11, accuracy: 0.000001)
        XCTAssertEqual(playback[1].end, 11.5, accuracy: 0.000001)
        XCTAssertEqual(playback[2].end, 12, accuracy: 0.000001)
    }
    func testRecordingSustainRetriggerAllNotesOffAndEmptyTake() throws {
        let song = Project.empty(name: "Capture").songs[0]
        var empty = MIDIRecordingTake(track: UUID(), song: song, startTime: 0)
        let emptyClip = try XCTUnwrap(empty.finish(at: 4))
        XCTAssertEqual(emptyClip.duration, 4)
        XCTAssertEqual(emptyClip.midi?.notes, [])
        var take = MIDIRecordingTake(track: UUID(), song: song, startTime: 0)
        take.receive(source: 1, status: 0xb0, number: 64, value: 127, position: 0)
        take.receive(source: 1, status: 0x90, number: 60, value: 88, position: 0)
        take.receive(source: 1, status: 0x80, number: 60, value: 0, position: 0.5)
        take.receive(source: 1, status: 0xb0, number: 64, value: 0, position: 1)
        take.receive(source: 1, status: 0x90, number: 60, value: 90, position: 1)
        take.receive(source: 1, status: 0x90, number: 60, value: 92, position: 1.5)
        take.receive(source: 1, status: 0xb0, number: 123, value: 0, position: 2)
        let clip = try XCTUnwrap(take.finish(at: 3))
        let playback = song.midiPlaybackNotes(in: clip)
        XCTAssertEqual(playback.count, 3)
        XCTAssertEqual(playback.map(\.end), [1, 1.5, 2])
    }
    func testRecordingAcrossTempoMarkersKeepsPerformedTimelineTiming() throws {
        var song = Project.empty(name: "Capture tempo").songs[0]
        song.bpm = 120; song.timeSettings = ProjectTimeSettings()
        song.markers = [TimelineMarker(id: UUID(), name: "Tempo", position: 2, color: 0x999999, tempoBPM: 240)]
        for start in [1.0, 2.5] {
            var take = MIDIRecordingTake(track: UUID(), song: song, startTime: start)
            take.receive(source: 1, status: 0x90, number: 60, value: 100, position: start + 0.25)
            take.receive(source: 1, status: 0x80, number: 60, value: 0, position: start + 2)
            let clip = try XCTUnwrap(take.finish(at: start + 3))
            let notes = song.midiPlaybackNotes(in: clip)
            XCTAssertEqual(notes.count, 1)
            XCTAssertEqual(notes[0].start, start + 0.25, accuracy: 0.000001)
            XCTAssertEqual(notes[0].end, start + 2, accuracy: 0.000001)
        }
    }
    @MainActor func testRecordingModeAndCapturedTakeUndoRedoAndEncryptedReopen() throws {
        let executor = MIDIEditExecutor()
        var project = Project.empty(name: "Captured MIDI")
        let track = Track(id: UUID(), name: "MIDI", role: .keys)
        project.songs[0].tracks = [track]
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertEqual(track.recordingMode, .stereo)
        show.setRecordingChannels(track.id, channel: TrackRecordingMode.midi.rawValue)
        XCTAssertEqual(show.current?.tracks[0].recordingMode, .midi)
        XCTAssertEqual(show.current?.tracks[0].midiInput, 1)
        var take = MIDIRecordingTake(track: track.id, song: show.current!, startTime: 1)
        take.receive(source: 1, status: 0x95, number: 64, value: 80, position: 1)
        let clip = try XCTUnwrap(take.finish(at: 2))
        show.addRecordedClip(clip, track: track.id)
        XCTAssertEqual(show.current?.tracks[0].clips, [clip])
        show.undo(); XCTAssertEqual(show.current?.tracks[0].clips, [])
        show.redo(); XCTAssertEqual(show.current?.tracks[0].clips, [clip])
        let reopened = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(show.snapshot.project))
        XCTAssertEqual(reopened, show.snapshot.project)
        XCTAssertEqual(reopened.songs[0].tracks[0].recordingMode, .midi)
        XCTAssertEqual(reopened.songs[0].tracks[0].clips[0].midi?.notes[0].channel, 6)
        show.setRecordingChannels(track.id, channel: 1)
        XCTAssertEqual(show.current?.tracks[0].recordingMode, .mono)
        show.setRecordingChannels(track.id, channel: 2)
        XCTAssertEqual(show.current?.tracks[0].recordingMode, .stereo)
        show.setRecordingChannels(track.id, channel: 3)
        XCTAssertEqual(show.current?.tracks[0].recordingMode, .stereo)
    }
}
extension MIDIItemTests {
    @MainActor func testCreateEditUndoRedoEncryptedSaveResizeAndSplit() throws {
        let executor=MIDIEditExecutor()
        var project=Project.empty(name:"MIDI")
        let track=Track(id:UUID(),name:"Piano",role:.keys);project.songs[0].tracks=[track]
        let show=try ShowController(executor:executor,persistence:MemoryProjectStore(),initialProject:project)
        let id=try XCTUnwrap(show.addMIDIItem(track:track.id,start:2,duration:2))
        var midi=MIDIItem(notes:[MIDINote(start:0,length:2,pitch:60)],sourceBPM:120)
        show.setMIDIItem(id,midi:midi)
        XCTAssertEqual(show.current?.tracks[0].clips[0].midi,midi)
        show.undo();XCTAssertEqual(show.current?.tracks[0].clips[0].midi?.notes,[])
        show.redo();XCTAssertEqual(show.current?.tracks[0].clips[0].midi,midi)
        midi.notes.append(MIDINote(start:6,length:2,pitch:64));show.setMIDIItem(id,midi:midi)
        XCTAssertEqual(show.current?.tracks[0].clips[0].duration,4,"drawing beyond the item extends it")
        let saved=try ProjectDocumentCodec.encode(show.snapshot.project)
        XCTAssertEqual(try ProjectDocumentCodec.decode(saved),show.snapshot.project)
        show.resizeItem(id,start:2.5,end:5)
        let trimmed=try XCTUnwrap(show.current?.tracks[0].clips[0]);XCTAssertNil(trimmed.loopLength);XCTAssertEqual(trimmed.sourceOffset,0.5)
        show.resizeItem(id,start:1,end:5)
        let extended=try XCTUnwrap(show.current?.tracks[0].clips[0]);XCTAssertEqual(extended.midiPlaybackNotes().first?.start,2)
        show.splitItems([id],at:3)
        XCTAssertEqual(show.current?.tracks[0].clips.count,2);XCTAssertTrue(show.current!.tracks[0].clips.allSatisfy{$0.midi != nil})
        show.canExecute={false};XCTAssertNil(show.addMIDIItem(track:track.id))
    }
}
