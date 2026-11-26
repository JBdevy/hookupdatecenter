import XCTest
@testable import JarasApplication

@MainActor private final class RecordingTemplateExecutor: CommandExecutor {
    var project = Project.empty(name: "Recording")
    func load(_ value: Project) throws { try value.validate(); project = value }
    func snapshot() throws -> ShowSnapshot {
        ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0,
            queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: try snapshot().transport) }
    func applyProjectEdit(_ value: Project) throws { try value.validate(); project = value }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}

final class RecordingTemplateTests: XCTestCase {
    func test32ChannelTemplateHasIndependentMonoInputsMasterOutputAndNoMonitoring() throws {
        let project = try Project.recordingMultitrack(name: "REC", channels: 32, trackPrefix: "Pista")
        try project.validate()
        let song = try XCTUnwrap(project.songs.first)
        XCTAssertEqual(project.songs.count, 1); XCTAssertEqual(song.tracks.count, 32)
        XCTAssertEqual(song.bpm, 120); XCTAssertEqual(song.duration, 300)
        XCTAssertEqual(project.setlists.first?.songIds, [song.id]); XCTAssertTrue(song.parts.isEmpty)
        XCTAssertEqual(Set(song.tracks.map(\.id)).count, 32)
        for (index, track) in song.tracks.enumerated() {
            XCTAssertEqual(track.name, String(format: "Pista %02d", index + 1))
            XCTAssertEqual(track.kind, .standard); XCTAssertEqual(track.color, Track.defaultStandardColor)
            XCTAssertEqual(track.inputPatch, OutputPatch(firstChannel: index + 1, channelCount: 1))
            XCTAssertEqual(track.recordingMode, .mono); XCTAssertEqual(track.inputMonitoring, true)
            XCTAssertEqual(track.outputPatches, [.master]); XCTAssertNil(track.recordingFormat)
            XCTAssertTrue(track.clips.isEmpty); XCTAssertNil(track.fx)
        }
        var arms = RecordingArmState()
        arms.set(.manual, tracks: Set(song.tracks.map(\.id)))
        XCTAssertEqual(arms.armed.count, 32)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
    }
    func testRecordingTemplateLimitsAndDefaultsDoNotInventSpecialTracks() throws {
        for count in [0, -1, 129, Int.max] { XCTAssertThrowsError(try Project.recordingMultitrack(name: "REC", channels: count)) }
        for count in [1, 128] {
            let project = try Project.recordingMultitrack(name: "REC", channels: count)
            XCTAssertEqual(project.songs[0].tracks.count, count)
            XCTAssertTrue(project.songs[0].tracks.allSatisfy { $0.kind == .standard })
        }
    }
    func testRecordingFormatOverrideAndAllMP3RatesUseEffectiveEncoderKeys() throws {
        let suite = "catlive.recording-template-tests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var track = Track(id: UUID(), name: "REC", role: .other)
        XCTAssertEqual(MediaProcessingFormat.load("record", preferences: preferences).recordingKey(for: track), "wav24pcm")
        preferences.set("MP3", forKey: "jaras.media.record.format")
        for rate in [128, 160, 192, 224, 256, 320] {
            preferences.set(rate, forKey: "jaras.media.record.bitrate")
            let format = MediaProcessingFormat.load("record", preferences: preferences)
            track.recordingFormat = nil; XCTAssertEqual(format.recordingKey(for: track), "mp3-\(rate)")
            track.recordingFormat = "wav"; XCTAssertEqual(format.recordingKey(for: track), "wav24pcm")
            track.recordingFormat = "wav32"; XCTAssertEqual(format.recordingKey(for: track), "wav32")
            track.recordingFormat = "mp3"; XCTAssertEqual(format.recordingKey(for: track), "mp3-\(rate)")
        }
        preferences.set(129, forKey: "jaras.media.record.bitrate")
        XCTAssertEqual(MediaProcessingFormat.load("record", preferences: preferences).bitrate, 320)
        preferences.set("AIFF", forKey: "jaras.media.record.format")
        preferences.set(16, forKey: "jaras.media.record.bits")
        track.recordingFormat = nil
        XCTAssertEqual(MediaProcessingFormat.load("record", preferences: preferences).recordingKey(for: track), "aiff16pcm")
        track.recordingFormat = "mp3"
        XCTAssertEqual(MediaProcessingFormat.load("record", preferences: preferences).recordingKey(for: track), "mp3-320")
    }
    @MainActor func testSelectedTrackFormatsAreOneUndoAndChangingInputKeepsAdvancedPreference() throws {
        let project = try Project.recordingMultitrack(name: "REC", channels: 3)
        let show = try ShowController(executor: RecordingTemplateExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        let ids = project.songs[0].tracks.map(\.id)
        show.setMixerTrackSelection([ids[0], ids[1]], anchor: ids[0])
        show.setRecordingFormat(ids[0], format: "wav32")
        XCTAssertEqual(show.current?.tracks.map(\.recordingFormat), ["wav32", "wav32", nil])
        show.undo(); XCTAssertEqual(show.snapshot.project, project)
        show.redo(); XCTAssertEqual(show.current?.tracks[1].recordingFormat, "wav32")
        show.setRecordingFormat(ids[0], format: nil)
        show.setRecordingInput(ids[0], input: OutputPatch(firstChannel: 7, channelCount: 1))
        XCTAssertEqual(show.current?.tracks[0].inputPatch?.firstChannel, 7)
        XCTAssertNil(show.current?.tracks[0].recordingFormat)
        show.undo(); XCTAssertEqual(show.current?.tracks[0].inputPatch?.firstChannel, 1)
        let before = show.snapshot.project
        show.setRecordingFormat(ids[0], format: "invalid")
        XCTAssertEqual(show.snapshot.project, before)
    }
}
