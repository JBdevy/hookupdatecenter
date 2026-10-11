import XCTest
@testable import JarasApplication

final class TrackAutomationTests: XCTestCase {
    func testEnvToggleDisablesPlaybackPreservesPointsAndSurvivesSave() throws {
        var automation = TrackAutomation()
        automation.toggleLanes(volume: 0.5, volumeName: "Volume")
        XCTAssertEqual(automation.visibleEnvelopes.count, 1)
        XCTAssertEqual(automation.envelopes[0].defaultValue, TrackEnvelope.normalizedGain(0.5))
        automation.envelopes[0].points = [.init(time: 1, value: 0.7), .init(time: 3, value: 0.9)]
        let id = automation.envelopes[0].id, active = automation.active
        automation.toggleLanes(volume: 1, volumeName: "Volume")
        XCTAssertTrue(automation.visibleEnvelopes.isEmpty)
        XCTAssertFalse(automation.enabled)
        XCTAssertTrue(automation.active.isEmpty, "Env off hides lanes and disables their playback")
        XCTAssertEqual(automation.envelopes, active, "Turning Env off preserves its points")
        automation = try JSONDecoder().decode(TrackAutomation.self, from: JSONEncoder().encode(automation))
        XCTAssertTrue(automation.visibleEnvelopes.isEmpty)
        automation.toggleLanes(volume: 1, volumeName: "Volume")
        XCTAssertTrue(automation.enabled)
        XCTAssertEqual(automation.visibleEnvelopes.first?.id, id)
        XCTAssertEqual(automation.active, active)
        XCTAssertEqual(automation.active[0].value(at: 2), 0.8, accuracy: 1e-9)
    }
    func testOlderAutomationWithoutDisplayStateKeepsItsVisibleLanes() throws {
        var automation = TrackAutomation()
        automation.envelopes = [TrackEnvelope(target: AutomationTarget(.pan), name: "Pan", defaultValue: 0.5)]
        let data = try JSONEncoder().encode(automation)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("lanesVisible"))
        let decoded = try JSONDecoder().decode(TrackAutomation.self, from: data)
        XCTAssertEqual(decoded.visibleEnvelopes.count, 1)
    }
    func testInterpolationAndHardSteps() throws {
        var envelope = TrackEnvelope(target: AutomationTarget(.pan), name: "Pan", defaultValue: 0.5)
        XCTAssertEqual(envelope.value(at: 40), 0.5)
        envelope.insert(EnvelopePoint(time: 1, value: 0)); envelope.insert(EnvelopePoint(time: 3, value: 1))
        XCTAssertEqual(envelope.value(at: 0), 0); XCTAssertEqual(envelope.value(at: 2), 0.5)
        XCTAssertEqual(envelope.value(at: 4), 1)
        envelope.points[0].shape = .square
        XCTAssertEqual(envelope.value(at: 2.999), 0); XCTAssertEqual(envelope.value(at: 3), 1)
        envelope.points[0].shape = .smooth
        XCTAssertEqual(envelope.value(at: 1.5), 0.15625, accuracy: 1e-10)
    }
    func testTouchWritingPreservesSurroundingAutomationAndReplacesOnlyWrittenInterval() {
        var envelope = TrackEnvelope(target: AutomationTarget(.pan), name: "Pan", defaultValue: 0.5)
        envelope.points = [.init(time: 0, value: 0.2), .init(time: 10, value: 0.2)]
        envelope.write(from: nil, to: 2, value: 0.6)
        envelope.write(from: 2, to: 3, value: 0.8)
        XCTAssertEqual(envelope.value(at: 1), 0.2, accuracy: 1e-8)
        XCTAssertEqual(envelope.value(at: 2.5), 0.7, accuracy: 1e-8)
        XCTAssertEqual(envelope.value(at: 4), 0.2, accuracy: 1e-8)
        envelope.write(from: 3, to: 1, value: 0.9)
        XCTAssertEqual(envelope.value(at: 1), 0.9); XCTAssertEqual(envelope.value(at: 4), 0.2, accuracy: 1e-8)
    }
    func testProjectRoundTripAndInvalidDuplicateTargets() throws {
        var project = Project.empty(name: "Automation")
        var track = Track(id: UUID(), name: "Synth", role: .other)
        var automation = TrackAutomation(); automation.mode = .latch
        var envelope = TrackEnvelope(target: AutomationTarget(.volume), name: "Volume", defaultValue: TrackEnvelope.normalizedGain(1))
        envelope.armed = true; envelope.points = [.init(time: 0, value: 0.7), .init(time: 3, value: 0.9, shape: .smooth)]
        automation.envelopes = [envelope]; track.automation = automation
        project.songs[0].tracks = [track]; project.masterAutomation = automation
        try project.validate()
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
        envelope.id = UUID(); automation.envelopes.append(envelope)
        XCTAssertThrowsError(try automation.validate())
    }
    func testEveryNativeParameterProducesValidSettingsIncludingRepeatedEffectsAndCatStem() throws {
        var fx = NativeFXSettings()
        for name in NativeFXSettings.order { if name != "Bypass" { _ = fx.appendNative(name) } }
        _ = fx.appendNative("Compressor"); _ = fx.appendNative(NativeFXSettings.stemSeparator)
        let parameters = NativeFXParameter.automationParameters(in: fx)
        XCTAssertGreaterThan(parameters.count, 40)
        XCTAssertEqual(parameters.filter { $0.key == .stemGain }.count, 5)
        XCTAssertEqual(Set(parameters.map { AutomationTarget(.nativeFX, native: $0).key }).count, parameters.count)
        for parameter in parameters {
            for fraction in [0.0, 0.27, 0.73, 1.0] {
                var settings = fx
                XCTAssertTrue(parameter.apply(normalized: fraction, to: &settings), parameter.name)
                XCTAssertNoThrow(try settings.validate(), parameter.name)
            }
        }
        let delay = try XCTUnwrap(parameters.first { $0.key == .delayTime })
        XCTAssertNotEqual(delay.value(normalized: 0.5001), delay.value(normalized: 0.5002), "Envelopes preserve continuous precision, not 7-bit MIDI steps")
    }
    func testGainConversion() {
        for gain in [0.0, 0.1, 0.5, 1, 2, 3.98] { XCTAssertEqual(TrackEnvelope.gain(TrackEnvelope.normalizedGain(gain)), gain, accuracy: 1e-9) }
    }
    func testImportedAmplitudeEnvelopeInterpolatesGainAndPersists() throws {
        var envelope = TrackEnvelope(target: AutomationTarget(.volume), name: "Take volume", defaultValue: TrackEnvelope.normalizedGain(1))
        envelope.valueScale = .linearGain
        envelope.points = [.init(time: 2, value: TrackEnvelope.normalizedGain(0.25)), .init(time: 4, value: TrackEnvelope.normalizedGain(1))]
        XCTAssertEqual(TrackEnvelope.gain(envelope.value(at: 3)), 0.625, accuracy: 1e-10)
        var clip = AudioClip(id: UUID(), name: "Take", startTime: 10, duration: 4, sourceOffset: 2, playbackRate: 2)
        var automation = TrackAutomation(); automation.envelopes = [envelope]; clip.automation = automation
        XCTAssertEqual(clip.automationTime(at: 10.5), 3)
        clip.startTime = 30
        XCTAssertEqual(clip.automationTime(at: 30.5), 3, "Moving the item must carry its automation")
        clip.loopLength = 1
        XCTAssertEqual(clip.automationTime(at: 31), 4, "Take automation must not repeat with its media")
        clip.sourceOffset = 0; clip.automationSourceOffset = 4
        XCTAssertEqual(clip.automationTime(at: 31), 6, "Tempo fragments retain unwrapped envelope time")
        XCTAssertEqual(try JSONDecoder().decode(AudioClip.self, from: JSONEncoder().encode(clip)), clip)
    }
    func testLoopedTempoFragmentsPreserveUnwrappedTakeAutomationClock() {
        var song = Project.empty(name: "Loop automation").songs[0]; song.duration = 30
        song.timeSettings = ProjectTimeSettings(); song.timeSettings?.timebase = .relative
        song.markers = [TimelineMarker(id: UUID(), name: "Tempo", position: 8, color: 0, tempoBPM: 180),
                        TimelineMarker(id: UUID(), name: "Tempo", position: 16, color: 0, tempoBPM: 60)]
        var clip = AudioClip(id: UUID(), name: "Loop", startTime: 4, duration: 20, sourceOffset: 2, loopStart: 0, loopLength: 4)
        clip.automation = TrackAutomation()
        let segments = song.tempoAudioSegments(clip)
        XCTAssertEqual(segments.map(\.sourceOffset), [2, 2, 2])
        XCTAssertEqual(segments.map(\.automationSourceOffset), [2, 6, 18])
        XCTAssertEqual(segments.map { $0.automationTime(at: $0.startTime + 1) }, [3, 7.5, 18.5])
        XCTAssertTrue(segments.allSatisfy { $0.automation == clip.automation })
    }
}
