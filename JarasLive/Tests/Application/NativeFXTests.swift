import XCTest
@testable import JarasApplication
final class NativeFXTests: XCTestCase {
    func testPitchRangePersistenceLegacyDefaultsAndMIDISemitoneSteps() throws {
        var settings = NativeFXSettings()
        let legacy = try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(legacy.semitones, 0); XCTAssertFalse(legacy.isEnabled("Pitch"))
        settings.inserted = ["Pitch"]; settings.setEnabled("Pitch", enabled: true); settings.pitchSemitones = -12
        try settings.validateForClip()
        XCTAssertEqual(try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(settings)), settings)
        let parameter = NativeFXParameter(effect: "Pitch", key: .pitchSemitones, name: "Semitones", range: -12...12)
        XCTAssertTrue(parameter.apply(127, to: &settings)); XCTAssertEqual(settings.semitones, 12)
        XCTAssertTrue(parameter.apply(63, to: &settings)); XCTAssertEqual(settings.semitones, 0)
        XCTAssertTrue(parameter.apply(0, to: &settings)); XCTAssertEqual(settings.semitones, -12)
        settings.pitchSemitones = 13; XCTAssertThrowsError(try settings.validate())
        settings.pitchSemitones = 0.5; XCTAssertThrowsError(try settings.validate())
    }
    func testRegionPitchTargetsAreIndependentAndSurviveUnificationAndDocuments() throws {
        var project = Project.empty(name: "Pitch")
        var folder = Track(id: UUID(), name: "Keys", role: .keys)
        var piano = Track(id: UUID(), name: "Piano", role: .keys); piano.parentTrackID = folder.id
        let drums = Track(id: UUID(), name: "Drums", role: .drums)
        let video = Track(id: UUID(), name: "Video", role: TrackRole(rawValue: "video"))
        folder.clips = []
        project.songs[0].tracks = [folder, piano, drums, video]
        let first = Part(id: UUID(), name: "First", startTime: 0, endTime: 10, pitchSemitones: 6, pitchTrackIDs: [], pitchGroupIDs: [folder.id])
        let second = Part(id: UUID(), name: "Second", startTime: 8, endTime: 20, pitchSemitones: -6, pitchTrackIDs: [piano.id], pitchGroupIDs: [])
        project.songs[0].parts = [first, second]
        let group = try project.unifyRegions(containing: first.id, name: "Group")
        var song = project.songs[0]
        XCTAssertEqual(song.pitchGroups.map(\.id), [folder.id])
        let defaults = Part(id: UUID(), name: "Defaults", startTime: 0, endTime: 1, pitchSemitones: 6)
        XCTAssertEqual(song.pitch(for: folder.id, region: defaults), 6)
        XCTAssertEqual(song.pitch(for: piano.id, region: defaults), 6, "selecting a track and its group never doubles transposition")
        XCTAssertEqual(song.pitch(for: video.id, region: defaults), 0)
        XCTAssertEqual(song.pitchTracks.map(\.id), [piano.id, drums.id])
        XCTAssertEqual(song.pitch(for: piano.id, region: song.pitchRegion(at: 0)), 6)
        XCTAssertEqual(song.pitch(for: piano.id, region: song.pitchRegion(at: 8)), -6)
        XCTAssertEqual(song.pitch(for: drums.id, region: first), 0)
        XCTAssertEqual(song.pitch(for: video.id, region: first), 0)
        let marker = try XCTUnwrap(song.markers?.first { $0.sourceRegionID == second.id })
        XCTAssertEqual(song.markerLabel(marker), "-6st  " + marker.name)
        let copy = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project))
        XCTAssertEqual(copy, project)
        _ = try project.disunifyRegion(group)
        song = project.songs[0]
        XCTAssertEqual(song.parts.first { $0.id == first.id }?.semitones, 6)
        XCTAssertEqual(song.parts.first { $0.id == second.id }?.semitones, -6)
        project.songs[0].parts[0].pitchSemitones = 7
        XCTAssertThrowsError(try project.validate())
    }

    func testSettingsPersistIndependentlyOfWhichEditorIsOpen() throws {
        var project = Project.demo()
        var fx = NativeFXSettings()
        fx.inserted = ["Reverb", "Compressor", "EQ"]
        fx.compressorEnabled = true; fx.ratio = 6; fx.attack = 0.015; fx.release = 0.5
        fx.reverbEnabled = true; fx.reverbRoom = 2; fx.reverbDecay = 7; fx.reverbLowCut = 120; fx.reverbHighCut = 8000
        project.songs[0].tracks[0].fx = fx
        project.masterFX = fx
        let copy = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(copy, project)
        XCTAssertEqual(fx.effectKeys, ["Reverb", "Compressor", "EQ"])
        try fx.validate()
        fx.ratio = .nan
        XCTAssertThrowsError(try fx.validate())
    }
    func testIndependentEffectWindowsDoNotOverwriteEachOther() throws {
        var original = NativeFXSettings(); original.inserted = NativeFXSettings.order
        var eq = original; eq.bands[1].gain = 9
        var compressor = original; compressor.ratio = 8
        var reverb = original; reverb.reverbDecay = 6
        let result = original.merging(effect: "EQ", from: eq).merging(effect: "Compressor", from: compressor).merging(effect: "Reverb", from: reverb)
        XCTAssertEqual(result.bands[1].gain, 9)
        XCTAssertEqual(result.ratio, 8)
        XCTAssertEqual(result.reverbDecay, 6)
        XCTAssertEqual(result.inserted, NativeFXSettings.order)
    }
    func testExternalChainHasNoArtificialCountLimitAndKeepsInterleavedOrder() throws {
        var fx = NativeFXSettings()
        let plugins = (0..<40).map { ExternalPlugin(classID: String(repeating: "A", count: 32), name: "Plugin \($0)", path: "/Library/Audio/Plug-Ins/VST3/Test.vst3") }
        fx.externalPlugins = plugins
        fx.inserted = [plugins[0].effectKey, "EQ", "Compressor"] + plugins.dropFirst().map(\.effectKey) + ["Reverb"]
        try fx.validate()
        let copy = try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(fx))
        XCTAssertEqual(copy.effectKeys, fx.inserted)
        var draft = fx; draft.ratio = 12
        XCTAssertEqual(fx.merging(effect: "Compressor", from: draft).effectKeys, fx.inserted)
        fx.externalPlugins?.append(plugins[0])
        XCTAssertThrowsError(try fx.validate(), "duplicate instances remain invalid")
    }
    func testInstrumentVelocityFilterAndControllerParametersPersist() throws {
        var parameters = InstrumentParameters(drums: true)
        XCTAssertEqual(parameters.release, 20)
        parameters.velocity = InstrumentVelocityParameters()
        parameters.velocity?.curve = .soft
        parameters.velocity?.cutoffMinimum = 350
        parameters.cutoff = InstrumentCutoffParameters()
        parameters.cutoff?.frequency = 6000
        parameters.cutoff?.attack = 0.4
        parameters.cutoff?.depth = 4
        parameters.controllers = InstrumentControllerParameters(modulation: true, pitchBend: false)
        try parameters.validate()
        XCTAssertEqual(try JSONDecoder().decode(InstrumentParameters.self, from: JSONEncoder().encode(parameters)), parameters)
        XCTAssertGreaterThan(InstrumentVelocityCurve.soft.value(0.5), InstrumentVelocityCurve.medium.value(0.5))
        XCTAssertLessThan(InstrumentVelocityCurve.hard.value(0.5), InstrumentVelocityCurve.medium.value(0.5))
        parameters.velocity?.cutoffMinimum = -1
        XCTAssertThrowsError(try parameters.validate())
        parameters.velocity?.cutoffMinimum = 300
        parameters.cutoff?.attack = .nan
        XCTAssertThrowsError(try parameters.validate())
    }
    func testInstrumentEnvelopeDefaults() throws {
        let parameters = InstrumentParameters()
        XCTAssertEqual(parameters.attack, 0)
        XCTAssertEqual(parameters.hold, 10)
        XCTAssertEqual(parameters.decay, 10)
        XCTAssertEqual(parameters.sustain, 1)
        XCTAssertEqual(parameters.release, 0.3)
        XCTAssertEqual(parameters.gain, 0)
        try parameters.validate()
    }
    func testInstrumentReplacementAndEnvelopePersistWithOtherEffects() throws {
        var fx = NativeFXSettings(); fx.inserted = ["Instruments", "EQ"]
        fx.instrumentID = "astoria-grand"; fx.bands[1].gain = 8
        var draft = fx
        draft.instrumentID = "gemani-pad"
        var parameters = InstrumentParameters()
        parameters.attack = 2; parameters.sustain = 0.7; parameters.gain = -6
        draft.instrumentParameters = parameters
        let replaced = fx.merging(effect: "Instruments", from: draft)
        try replaced.validate()
        XCTAssertEqual(replaced.inserted.filter { $0 == "Instruments" }.count, 1)
        XCTAssertEqual(replaced.instrumentID, "gemani-pad")
        XCTAssertEqual(replaced.bands[1].gain, 8)
        XCTAssertEqual(try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(replaced)), replaced)
        parameters.attack = .nan
        XCTAssertThrowsError(try parameters.validate())
    }
    func testTrackMIDISelectionPersistsAndIsLimitedToThreeSlots() throws {
        var project = Project.demo()
        for slot in 1...3 { project.songs[0].tracks[0].midiInput = slot; try project.validate(); XCTAssertEqual(try JSONDecoder().decode(Project.self,from: JSONEncoder().encode(project)),project) }
        project.songs[0].tracks[0].midiInput = 4
        XCTAssertThrowsError(try project.validate())
    }
    func testRecordingWaveformHistoryStaysBounded() {
        var overview = RecordingOverview(channels: 2,sampleRate: 100)
        for frame in 0..<50_000 {
            overview.append(frame%3 == 0 ? 0.8 : 0.2,channel: 0); overview.append(0.4,channel: 1); overview.endFrame()
        }
        XCTAssertLessThanOrEqual(overview.snapshot[0].count,1024)
        XCTAssertEqual(overview.snapshot[0].max()!,0.8,accuracy: 0.0001)
        XCTAssertEqual(overview.snapshot[1].max()!,0.4,accuracy: 0.0001)
    }
    func testEQBandLimitAndSlopeResponse() throws {
        var fx = NativeFXSettings()
        XCTAssertEqual(fx.bands.count, 5)
        for _ in 0..<5 { fx.bands.append(EQBand(frequency: 1000)) }
        try fx.validate()
        fx.bands.append(EQBand(frequency: 1000))
        XCTAssertThrowsError(try fx.validate())
        for rate in [44100.0,48000.0] {
            for slope in [6,12,24,36,48,72,96,192] {
                var band = EQBand(frequency: 1000, type: "lowCut"); band.slope = slope
                XCTAssertEqual(band.response(frequency: 1000, rate: rate), -3.0103, accuracy: 0.02)
                XCTAssertLessThan(band.response(frequency: 100, rate: rate), -Double(slope)*3)
                XCTAssertTrue(band.coefficients(rate: rate).joined().allSatisfy(\.isFinite))
            }
        }
    }
}
