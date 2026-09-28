import XCTest
@testable import JarasApplication

final class ClipFXTests: XCTestCase {
    private func fixture() -> Project {
        var project = Project.empty(name: "Item effects")
        project.songs[0].duration = 300
        var effects = NativeFXSettings()
        effects.inserted = ["EQ", "Compressor", "Pitch", "Delay", "Reverb"]
        effects.eqEnabled = true; effects.bands[2].gain = 5
        effects.compressorEnabled = true; effects.ratio = 7
        effects.delayEnabled = true; effects.feedback = 42
        effects.reverbEnabled = true; effects.reverbDecay = 6
        let clip = AudioClip(id: UUID(), name: "Take", startTime: 30, duration: 60,
                             sourceOffset: 2, waveform: [0.1, 0.5], audioFile: AudioFile(path: "Steams/take.wav"),
                             gain: 0.5, waveformChannels: [[0.1,0.5],[0.4,0.2]], muted: true,
                             playbackRate: 1.5, recordingLane: 2, loopStart: 1, loopLength: 3, fx: effects)
        var track = Track(id: UUID(), name: "Audio", role: .keys)
        track.clips = [clip]
        project.songs[0].tracks = [track]
        return project
    }
    func testEncryptedDocumentRetainsItemChainAndAllAudioMetadata() throws {
        let project = fixture()
        let decoded = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project))
        XCTAssertEqual(decoded, project)
        XCTAssertNil(decoded.songs[0].tracks[0].fx, "item processing remains independent of track processing")
        XCTAssertEqual(decoded.songs[0].tracks[0].clips[0].fx?.inserted, NativeFXSettings.order.dropFirst().map { $0 })
        var empty = project
        empty.songs[0].tracks[0].clips[0].fx = nil
        let json = try JSONEncoder().encode(empty)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("\"fx\""))
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: json), empty)
    }
    func testSplitResizeAndUndoKeepIndependentItemSettings() throws {
        var project = fixture()
        let original = project
        let id = project.songs[0].tracks[0].clips[0].id
        var history = ProjectEditHistory(project)
        project.resizeItem(id, start: 25, end: 100)
        project.splitItems([id], at: 45)
        XCTAssertEqual(project.songs[0].tracks[0].clips.count, 2)
        XCTAssertEqual(project.songs[0].tracks[0].clips[0].fx, original.songs[0].tracks[0].clips[0].fx)
        XCTAssertEqual(project.songs[0].tracks[0].clips[1].fx, original.songs[0].tracks[0].clips[0].fx)
        project.songs[0].tracks[0].clips[1].fx?.bands[2].gain = -8
        XCTAssertEqual(project.songs[0].tracks[0].clips[0].fx?.bands[2].gain, 5)
        history.record(project)
        XCTAssertEqual(history.undo(), original)
        XCTAssertEqual(history.redo(), project)
        try project.validate()
    }
    func testGlobalItemBypassPersistsWithoutChangingEffectFlagsAndSurvivesEdits() throws {
        var project = fixture()
        let originalSettings = project.songs[0].tracks[0].clips[0].fx
        XCTAssertNil(project.songs[0].tracks[0].clips[0].fxBypassed)
        var history = ProjectEditHistory(project)
        project.songs[0].tracks[0].clips[0].fxBypassed = true
        history.record(project)
        XCTAssertEqual(try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project)), project)
        let id = project.songs[0].tracks[0].clips[0].id
        project.resizeItem(id, start: 25, end: 100)
        project.splitItems([id], at: 45)
        XCTAssertEqual(project.songs[0].tracks[0].clips.map(\.fxBypassed), [true, true])
        XCTAssertTrue(project.songs[0].tracks[0].clips.allSatisfy { $0.fx == originalSettings })
        project.songs[0].tracks[0].clips[1].fxBypassed = false
        XCTAssertEqual(project.songs[0].tracks[0].clips[0].fxBypassed, true)
        XCTAssertEqual(try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project)), project)
        XCTAssertNil(history.undo()?.songs[0].tracks[0].clips[0].fxBypassed)
        XCTAssertEqual(history.redo()?.songs[0].tracks[0].clips[0].fxBypassed, true)
        var special = fixture()
        special.songs[0].tracks[0].role = .init(rawValue: "video")
        special.songs[0].tracks[0].name = "Video"
        special.songs[0].tracks[0].clips[0].fx = nil
        for flag in [false, true] {
            special.songs[0].tracks[0].clips[0].fxBypassed = flag
            XCTAssertThrowsError(try special.validate())
        }
    }
    func testItemEffectsRejectInstrumentsUnknownEffectsAndSpecialTracks() throws {
        var project = fixture()
        var effects = NativeFXSettings()
        for invalid in ["Instruments", "External"] {
            effects.inserted = [invalid]
            project.songs[0].tracks[0].clips[0].fx = effects
            XCTAssertThrowsError(try project.validate())
        }
        effects.inserted = ["EQ"]
        effects.instrumentID = "Astoria"
        XCTAssertThrowsError(try effects.validateForClip())
        effects.instrumentID = nil; effects.instrumentParameters = InstrumentParameters()
        XCTAssertThrowsError(try effects.validateForClip())
        effects.instrumentParameters = nil; effects.instrumentBypassed = true
        XCTAssertThrowsError(try effects.validateForClip())
        effects.instrumentBypassed = nil; effects.bands[0].gain = .infinity
        XCTAssertThrowsError(try effects.validateForClip())
        effects = NativeFXSettings(); effects.inserted = ["EQ"]; effects.eqEnabled = true
        project.songs[0].tracks[0].clips[0].fx = effects
        project.songs[0].tracks[0].role = TrackRole(rawValue: "video")
        project.songs[0].tracks[0].name = "Video"
        XCTAssertThrowsError(try project.validate())
    }
}
