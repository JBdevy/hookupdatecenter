import XCTest
@testable import JarasApplication
@MainActor private final class PitchTestExecutor: CommandExecutor {
    var project = Project.empty(name: "Pitch")
    func load(_ value: Project) throws { project = value }
    func snapshot() throws -> ShowSnapshot {
        ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0,
            queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: try snapshot().transport) }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
    func setFX(_ id: UUID?, settings: NativeFXSettings) throws {
        if let id {
            for s in project.songs.indices {
                if let t = project.songs[s].tracks.firstIndex(where: { $0.id == id }) { project.songs[s].tracks[t].fx = settings }
            }
        } else { project.masterFX = settings }
    }
    func setClipFXBypass(_ id: UUID, bypassed: Bool) throws {
        for s in project.songs.indices { for t in project.songs[s].tracks.indices {
            if let c = project.songs[s].tracks[t].clips.firstIndex(where: { $0.id == id }) { project.songs[s].tracks[t].clips[c].fxBypassed = bypassed }
        } }
    }
    func setClipFX(_ id: UUID, settings: NativeFXSettings) throws {
        for s in project.songs.indices { for t in project.songs[s].tracks.indices {
            if let c = project.songs[s].tracks[t].clips.firstIndex(where: { $0.id == id }) { project.songs[s].tracks[t].clips[c].fx = settings }
        } }
    }
}
final class NativeFXTests: XCTestCase {
    @MainActor func testSessionFXBypassAllowsIndependentMainAndTrackOverrides() throws {
        var project = Project.empty(name: "Session FX")
        var fx = NativeFXSettings()
        fx.appendNative("EQ"); fx.appendNative("Delay"); fx.setEnabled("Delay", enabled: false)
        project.masterFX = fx
        let ids = (0..<3).map { _ in UUID() }
        project.songs[0].tracks = ids.map { id in
            var track = Track(id: id, name: "Track", role: .other); track.fx = fx; return track
        }
        let show = try ShowController(executor: PitchTestExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        show.toggleStripFXBypass(ids[1])
        show.toggleStripFXBypass(nil, sessionWide: true)
        for id in [nil] + ids.map(Optional.some) { XCTAssertTrue(show.fxSettings(id).allBypassed) }
        show.toggleStripFXBypass(nil)
        show.toggleStripFXBypass(ids[0])
        XCTAssertEqual(show.fxSettings(nil).sessionFXBypassed, true)
        XCTAssertTrue(show.fxSettings(nil).isEnabled("EQ"))
        XCTAssertTrue(show.fxSettings(ids[0]).isEnabled("EQ"))
        XCTAssertTrue(show.fxSettings(ids[2]).allBypassed)
        let saved = try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(show.fxSettings(ids[2])))
        XCTAssertEqual(saved.mixerBypassRestore, ["EQ"])
        show.toggleStripFXBypass(nil, sessionWide: true)
        XCTAssertNil(show.fxSettings(nil).sessionFXBypassed)
        XCTAssertTrue(show.fxSettings(ids[1]).allBypassed, "A manually bypassed track must stay bypassed")
        XCTAssertTrue(show.fxSettings(ids[2]).isEnabled("EQ"))
        XCTAssertFalse(show.fxSettings(ids[2]).isEnabled("Delay"))
    }

    @MainActor func testRemovingAllItemEffectsPreservesTrackEffectsAndTiming() throws {
        var project = Project.empty(name: "Remove item FX")
        var fx = NativeFXSettings(); fx.appendNative("EQ"); fx.appendNative("Reverb")
        var track = Track(id: UUID(), name: "Track", role: .other); track.fx = fx
        var clip = AudioClip(id: UUID(), name: "Item", startTime: 12, duration: 4, sourceOffset: 2)
        clip.fx = fx; track.clips = [clip]; project.songs[0].tracks = [track]; project.songs[0].duration = 20
        let show = try ShowController(executor: PitchTestExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        show.removeAllClipFX(clip.id)
        XCTAssertTrue(show.clipFXSettings(clip.id).inserted.isEmpty)
        XCTAssertEqual(show.current?.tracks[0].fx, fx)
        XCTAssertEqual(show.current?.tracks[0].clips[0].startTime, 12)
        XCTAssertEqual(show.current?.tracks[0].clips[0].duration, 4)
        XCTAssertEqual(show.current?.tracks[0].clips[0].sourceOffset, 2)
    }

    @MainActor func testSelectedItemFXInsertionBypassAndRemovalPreserveOtherChains() throws {
        var project = Project.empty(name: "Selected FX")
        var track = Track(id: UUID(), name: "Audio", role: .other)
        var items = (0..<3).map { AudioClip(id: UUID(), name: "Item \($0)", startTime: Double($0)*4, duration: 4) }
        var original = NativeFXSettings(); original.appendNative("Delay"); original.delayTime = 0.375
        items[0].fx = original; items[1].fx = original; items[2].fx = original
        track.clips = items; track.fx = original; project.songs[0].tracks = [track]
        let show = try ShowController(executor: PitchTestExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        show.reportItemSelection([items[0].id,items[1].id,UUID()])
        XCTAssertNotNil(show.insertClipFX(items[0].id,effect: "EQ"))
        for item in items.prefix(2) {
            let chain = show.clipFXSettings(item.id)
            XCTAssertEqual(chain.clipEffectKeys.map { chain.kind(of: $0) }, ["Delay", "EQ"])
        }
        XCTAssertEqual(show.clipFXSettings(items[0].id).delayTime,0.375)
        XCTAssertEqual(show.clipFXSettings(items[2].id),original)
        show.toggleClipFXAllBypass(items[0].id)
        XCTAssertEqual(show.current?.tracks[0].clips.map { $0.fxBypassed == true },[true,true,false])
        show.toggleClipFXAllBypass(items[0].id)
        XCTAssertEqual(show.current?.tracks[0].clips.map { $0.fxBypassed == true },[false,false,false])
        show.removeAllClipFX(items[0].id)
        XCTAssertTrue(show.clipFXSettings(items[0].id).inserted.isEmpty)
        XCTAssertTrue(show.clipFXSettings(items[1].id).inserted.isEmpty)
        XCTAssertEqual(show.clipFXSettings(items[2].id),original)
        XCTAssertEqual(show.current?.tracks[0].fx,original)
        XCTAssertEqual(show.current?.tracks[0].clips.map(\.startTime),items.map(\.startTime))
        XCTAssertNotNil(show.insertClipFX(items[2].id,effect: "Reverb"))
        XCTAssertTrue(show.clipFXSettings(items[0].id).inserted.isEmpty,"Clicking an unselected item must affect only that item")
    }

    @MainActor func testShiftItemTunerPreservesIntervalsAndSharesRangeLimit() throws {
        var project = Project.empty(name: "Tuner")
        var track = Track(id: UUID(), name: "Audio", role: .other)
        var first = AudioClip(id: UUID(), name: "One", startTime: 0, duration: 5)
        var second = AudioClip(id: UUID(), name: "Two", startTime: 0, duration: 5)
        first.pitchSemitones = -3; second.pitchSemitones = 10
        track.clips = [first, second]; project.songs[0].tracks = [track]
        let show = try ShowController(executor: PitchTestExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        show.adjustItemPitch([first.id, second.id], by: 1)
        XCTAssertEqual(show.current?.tracks[0].clips.map { $0.pitchSemitones ?? 0 }, [-2, 11])
        show.adjustItemPitch([first.id, second.id], by: 2)
        XCTAssertEqual(show.current?.tracks[0].clips.map { $0.pitchSemitones ?? 0 }, [-1, 12])
        show.adjustItemPitch([first.id, second.id], by: 1)
        XCTAssertEqual(show.current?.tracks[0].clips.map { $0.pitchSemitones ?? 0 }, [-1, 12])
        show.adjustItemPitch([second.id], by: -1)
        XCTAssertEqual(show.current?.tracks[0].clips.map { $0.pitchSemitones ?? 0 }, [-1, 11])
    }

    func testTriggerGatePersistenceInstancesAndSampleOwnership() throws {
        var project = Project.empty(name: "Trigger and gate")
        var fx = NativeFXSettings()
        fx.appendNative("CatLive Trigger"); fx.appendNative("Cat Gate")
        fx.triggerParameters.samplePath = "Stems/Kick.wav"
        fx.gateParameters.threshold = -35
        let second = fx.appendNative("CatLive Trigger")
        var draft = fx.settings(for: second)
        draft.triggerParameters.samplePath = "Stems/Snare.mp3"
        draft.triggerParameters.sustain = 0.25
        fx = fx.merging(effect: second, from: draft)
        fx.setEnabled("CatLive Trigger", enabled: false)
        XCTAssertTrue(fx.isEnabled(second)); XCTAssertFalse(fx.isEnabled("CatLive Trigger"))
        try fx.validateForClip()
        project.masterFX = fx
        XCTAssertEqual(project.mediaPaths, ["Stems/Kick.wav", "Stems/Snare.mp3"])
        XCTAssertEqual(try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project)), project)
        let preset = try FXPreset(name: "Soft snare", settings: fx, effect: second)
        XCTAssertNil(preset.native?.trigger?.samplePath)
        let applied = try preset.applying(to: fx, effect: second)
        XCTAssertEqual(applied.settings(for: second).trigger?.samplePath, "Stems/Snare.mp3")
        let restored = try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(fx))
        XCTAssertEqual(restored, fx)
        project.remapFXSamples(["Stems/Kick.wav":"Stems/Kick-001.wav"])
        XCTAssertEqual(project.mediaPaths, ["Stems/Kick-001.wav", "Stems/Snare.mp3"])
        let parameter = NativeFXParameter(effect: second, key: .triggerGain, name: "Gain", range: -24...24)
        XCTAssertTrue(parameter.apply(127, to: &fx)); XCTAssertEqual(fx.settings(for: second).triggerParameters.gain, 24)
        XCTAssertEqual(fx.triggerParameters.gain, 0)
        fx.removeEffect(second); XCTAssertEqual(fx.samplePaths, ["Stems/Kick.wav"])
        fx.gateParameters.highPass = 10000; fx.gateParameters.lowPass = 5000
        XCTAssertThrowsError(try fx.validate())
        fx.gateParameters = NativeGateSettings(); fx.triggerParameters.samplePath = "../kick.wav"
        XCTAssertThrowsError(try fx.validate())
    }

    func testRemovedEffectReinsertsFreshWithoutChangingOtherStages() throws {
        var fx = NativeFXSettings()
        fx.appendNative("EQ"); fx.appendNative("Compressor"); fx.appendNative("Delay")
        fx.bands[1].gain = 11; fx.threshold = -47; fx.delayTime = 1.7
        let duplicate = fx.appendNative("Compressor")
        var draft = fx.settings(for: duplicate); draft.threshold = -31
        fx = fx.merging(effect: duplicate, from: draft)
        fx.removeEffect("EQ"); fx.appendNative("EQ")
        XCTAssertEqual(fx.bands[1].gain, 0); XCTAssertEqual(fx.threshold, -47)
        fx.removeEffect("Compressor"); fx.appendNative("Compressor")
        XCTAssertEqual(fx.threshold, NativeFXSettings().threshold)
        XCTAssertEqual(fx.settings(for: duplicate).threshold, -31)
        XCTAssertEqual(fx.delayTime, 1.7)
        fx.removeEffect(duplicate)
        XCTAssertFalse(fx.instances?.contains { $0.effectKey == duplicate } ?? false)
        fx.removeEffect("Delay"); fx.appendNative("Delay")
        XCTAssertEqual(fx.delayTime, NativeFXSettings().delayTime)
        try fx.validate(); try fx.validateForClip()
        fx.inserted.removeAll { $0 == "Compressor" }; fx.threshold = -52
        fx.appendNative("Compressor")
        XCTAssertEqual(fx.threshold, NativeFXSettings().threshold)
    }

    func testLegacyStemMixPersistenceAndIndependentEdits() throws {
        let key = NativeFXSettings.stemSeparator
        var fx = NativeFXSettings()
        fx.inserted = [key]; fx.stemSeparatorEnabled = true; fx.stemMix = NativeStemMix()
        var draft = fx
        draft.stemParameters.sources[0].solo = true
        draft.stemParameters.sources[0].gain = 0.5
        draft.stemParameters.sources[4].solo = true
        draft.stemParameters.sources[4].mute = true
        fx.makeup = 6
        let result = fx.merging(effect: key, from: draft)
        XCTAssertEqual(result.makeup, 6)
        XCTAssertEqual(result.stemParameters.gains, [0.5, 0, 0, 0, 0])
        try result.validate()
        XCTAssertEqual(try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(result)), result)
        var legacy = NativeFXSettings()
        legacy.inserted = [key]; legacy.stemSeparatorEnabled = true
        XCTAssertFalse(legacy.isEnabled(key), "Offline projects must not automatically acquire processing latency")
        legacy.setEnabled(key, enabled: true)
        XCTAssertFalse(legacy.isEnabled(key), "Legacy settings cannot reactivate the removed realtime stage")
        legacy.stemParameters.sources.removeLast()
        XCTAssertThrowsError(try legacy.validate())
        legacy.stemParameters = NativeStemMix()
        legacy.stemParameters.sources[0].gain = .nan
        XCTAssertThrowsError(try legacy.validate())
    }
    func testRemovedStemSeparatorCannotBeInsertedAndLegacySettingsRemainReadable() throws {
        var fx = NativeFXSettings()
        let key = NativeFXSettings.stemSeparator
        XCTAssertFalse(fx.inserted.contains(key)); XCTAssertFalse(fx.isEnabled(key))
        XCTAssertEqual(fx.appendNative(key), key)
        XCTAssertTrue(fx.inserted.isEmpty)
        fx.inserted = [key]; fx.stemSeparatorEnabled = true; fx.stemMix = NativeStemMix()
        try fx.validate(); try fx.validateForClip()
        XCTAssertFalse(fx.isEnabled(key))
        XCTAssertTrue(fx.effectKeys.isEmpty && fx.clipEffectKeys.isEmpty)
        XCTAssertEqual(fx.inserted, [key])
        let saved = try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(fx))
        XCTAssertEqual(saved, fx)
        fx.setEnabled(key, enabled: false)
        XCTAssertFalse(fx.isEnabled(key))
        fx.inserted.removeAll { $0 == key }; fx.removeInstance(key)
        try fx.validate()
        XCTAssertTrue(fx.inserted.isEmpty)
    }

    func testRepeatedNativeEffectsAndInstrumentsPersistIndependentParametersAndBypass() throws {
        var fx = NativeFXSettings()
        let first = fx.appendNative("Compressor")
        let second = fx.appendNative("Compressor")
        XCTAssertNotEqual(first, second)
        var edited = fx.settings(for: second); edited.makeup = 6
        fx = fx.merging(effect: second, from: edited)
        XCTAssertEqual(fx.makeup, 0); XCTAssertEqual(fx.settings(for: second).makeup, 6)
        fx.setEnabled(first, enabled: false)
        XCTAssertFalse(fx.isEnabled(first)); XCTAssertTrue(fx.isEnabled(second))
        let piano = fx.appendNative("Instruments", instrument: "Piano")
        let layered = fx.appendNative("Instruments", instrument: "Piano")
        XCTAssertNotEqual(piano, layered); XCTAssertEqual(fx.instrumentKeys.count, 2)
        let external = ExternalPlugin(classID: String(repeating: "A", count: 32), name: "Instrument", path: "/test.vst3", category: "Instrument")
        var other = external; other.id = UUID().uuidString
        fx.externalPlugins = [external, other]; fx.inserted += [external.effectKey, other.effectKey]
        try fx.validate()
        XCTAssertEqual(try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(fx)), fx)
        let mapping = NativeFXParameter(effect: second, key: .makeup, name: "Gain", range: -12...24)
        XCTAssertTrue(mapping.apply(127, to: &fx))
        XCTAssertEqual(fx.settings(for: second).makeup, 24); XCTAssertEqual(fx.makeup, 0)
        fx.inserted.removeAll { $0 == second }; fx.removeInstance(second)
        try fx.validate(); XCTAssertEqual(fx.instrumentKeys.count, 2)
    }
    func testControllerVolumeDefaultsAndBounds() throws {
        var fx = NativeFXSettings(); let key = fx.appendNative("Instruments", instrument: "Piano")
        XCTAssertNil(fx.instrumentParameters?.controllers?.volume)
        let mapping = NativeFXParameter(effect: key, key: .instrumentVolume, name: "Volume", range: -96...0)
        XCTAssertTrue(mapping.apply(127, to: &fx)); XCTAssertEqual(fx.instrumentParameters?.controllers?.volume, 0)
        XCTAssertTrue(mapping.apply(0, to: &fx)); XCTAssertEqual(fx.instrumentParameters?.controllers?.volume, -96)
        try fx.validate()
        fx.instrumentParameters?.controllers?.volume = 1
        XCTAssertThrowsError(try fx.validate())
    }

    func testVoiceModePersistsAndLegacyControllerKeepsCategoryDefault() throws {
        let legacy = try JSONDecoder().decode(InstrumentControllerParameters.self, from: Data("{\"modulation\":true,\"pitchBend\":false}".utf8))
        XCTAssertNil(legacy.monophonic)
        for mode in [false, true] {
            let value = InstrumentControllerParameters(modulation: true, pitchBend: false, monophonic: mode)
            XCTAssertEqual(try JSONDecoder().decode(InstrumentControllerParameters.self, from: JSONEncoder().encode(value)), value)
        }
    }

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
        XCTAssertEqual(song.markerLabel(marker), "-6st  SECOND")
        song.parts[song.parts.firstIndex { $0.id == second.id }!].uppercaseName = false
        XCTAssertEqual(song.markerLabel(marker), "-6st  Second")
        song.parts[song.parts.firstIndex { $0.id == second.id }!].uppercaseName = true
        let copy = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project))
        XCTAssertEqual(copy, project)
        _ = try project.disunifyRegion(group)
        song = project.songs[0]
        XCTAssertEqual(song.parts.first { $0.id == first.id }?.semitones, 6)
        XCTAssertEqual(song.parts.first { $0.id == second.id }?.semitones, -6)
        project.songs[0].parts[0].pitchSemitones = 13
        XCTAssertThrowsError(try project.validate())
    }

    func testRegionTunerPreservesVSExactOctaveOffsetsAndExplicitTargets() throws {
        var project = Project.empty(name: "VS Hook tuner")
        let tuned = Track(id: UUID(), name: "# Keys", role: .keys)
        let untouched = Track(id: UUID(), name: "Drums", role: .drums)
        project.songs[0].tracks = [tuned, untouched]
        project.songs[0].parts = [
            Part(id: UUID(), name: "Up", startTime: 0, endTime: 10, pitchSemitones: 12,
                 pitchTrackIDs: [tuned.id], pitchGroupIDs: []),
            Part(id: UUID(), name: "Down", startTime: 10, endTime: 20, pitchSemitones: -12,
                 pitchTrackIDs: [tuned.id], pitchGroupIDs: []),
            Part(id: UUID(), name: "No targets", startTime: 20, endTime: 30, pitchSemitones: 8,
                 pitchTrackIDs: [], pitchGroupIDs: [])
        ]
        let saved = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project))
        XCTAssertEqual(saved, project)
        let song = saved.songs[0]
        for (position, semitones) in [(0.0, 12), (10.0, -12), (20.0, 0)] {
            XCTAssertEqual(song.pitch(for: tuned.id, region: song.pitchRegion(at: position)), semitones)
            XCTAssertEqual(song.pitch(for: untouched.id, region: song.pitchRegion(at: position)), 0)
        }
        for invalid in [-13, 13] {
            project.songs[0].parts[0].pitchSemitones = invalid
            XCTAssertThrowsError(try project.validate())
        }
    }

    func testRegionTunerOwnershipUsesLargestOverlapInsteadOfItemOnset() throws {
        var song = Project.empty(name: "Overlapping tuner").songs[0]
        let track = Track(id: UUID(), name: "Keys", role: .keys)
        let first = Part(id: UUID(), name: "First", startTime: 10, endTime: 20, pitchSemitones: 3)
        let second = Part(id: UUID(), name: "Second", startTime: 20, endTime: 35, pitchSemitones: -2)
        song.tracks = [track]; song.parts = [first, second]
        func pitch(_ start: Double, _ end: Double, preferred: UUID? = nil) -> Int {
            let owner = song.regionOwnerForMedia(at: start, end: end, preferred: preferred)
            return song.pitch(for: track.id, region: song.parts.first { $0.id == owner })
        }
        XCTAssertEqual(pitch(8, 18), 3, "An item beginning before the region still receives its tuner")
        XCTAssertEqual(pitch(18, 28, preferred: first.id), -2, "Largest overlap wins over an old attachment")
        XCTAssertEqual(pitch(0, 10), 0, "An item merely touching the region is outside")
        XCTAssertEqual(pitch(10, 10), 0, "Empty intervals do not acquire a tuner")
        let group = Part(id: UUID(), name: "Unified", startTime: 10, endTime: 35)
        var left = first, right = second
        left.parentRegionID = group.id; right.parentRegionID = group.id
        song.parts = [group, left, right]
        XCTAssertEqual(pitch(18, 28, preferred: left.id), -2, "Unified children use their largest covered duration")
        XCTAssertEqual(pitch(15, 25, preferred: left.id), 3, "Equal child spans preserve the existing attachment")
        XCTAssertEqual(pitch(15, 25, preferred: right.id), -2)
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
    func testTrackMIDISelectionPersistsAndIsLimitedToSixSlots() throws {
        var project = Project.demo()
        for slot in 1...6 { project.songs[0].tracks[0].midiInput = slot; try project.validate(); XCTAssertEqual(try JSONDecoder().decode(Project.self,from: JSONEncoder().encode(project)),project) }
        project.songs[0].tracks[0].midiInput = 7
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
