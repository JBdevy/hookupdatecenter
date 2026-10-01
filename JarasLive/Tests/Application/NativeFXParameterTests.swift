import XCTest
@testable import JarasApplication

final class NativeFXParameterTests: XCTestCase {
    func testLimiterMIDITargetsOneInstanceAndPersistsIndependently() throws {
        var fx = NativeFXSettings()
        fx.appendNative("Limiter")
        let key = fx.appendNative("Limiter")
        let gain = NativeFXParameter(effect: key, key: .limiterGain, name: "Input gain", range: -24...24)
        XCTAssertTrue(gain.apply(127, to: &fx))
        XCTAssertEqual(fx.settings(for: key).limiterParameters.inputGain, 24)
        XCTAssertEqual(fx.limiterParameters.inputGain, 0)
        NativeFXParameter(effect: key, key: .limiterCeiling, name: "Ceiling", range: -24...0).apply(0, to: &fx)
        NativeFXParameter(effect: key, key: .limiterRelease, name: "Release", range: 0.01...3, logarithmic: true).apply(127, to: &fx)
        XCTAssertEqual(fx.settings(for: key).limiterParameters.ceiling, -24)
        XCTAssertEqual(fx.settings(for: key).limiterParameters.release, 3)
        NativeFXParameter(effect: key, key: .enabled, name: "Enabled", range: 0...1).apply(0, to: &fx)
        XCTAssertFalse(fx.isEnabled(key)); XCTAssertTrue(fx.isEnabled("Limiter"))
        try fx.validate()
        XCTAssertEqual(try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(fx)), fx)
        fx.limiterParameters.ceiling = 1
        XCTAssertThrowsError(try fx.validate())
    }

    func testContinuousParameterRangesAndEQBandIdentitySurviveReordering() throws {
        var fx = NativeFXSettings(); fx.inserted = ["EQ", "Compressor", "Delay"]
        let threshold = NativeFXParameter(effect: "Compressor", key: .threshold, name: "Threshold", range: -60...0)
        XCTAssertTrue(threshold.apply(0, to: &fx)); XCTAssertEqual(fx.threshold, -60)
        threshold.apply(127, to: &fx); XCTAssertEqual(fx.threshold, 0)
        let delay = NativeFXParameter(effect: "Delay", key: .delayTime, name: "Time", range: 0.01...2, logarithmic: true)
        delay.apply(0, to: &fx); XCTAssertEqual(fx.delayTime, 0.01, accuracy: 0.000001)
        delay.apply(127, to: &fx); XCTAssertEqual(fx.delayTime, 2, accuracy: 0.000001)
        let id = fx.bands[1].id
        let gain = NativeFXParameter(effect: "EQ", key: .bandGain, band: id, name: "Gain", range: -24...24)
        fx.bands.reverse(); gain.apply(127, to: &fx)
        XCTAssertEqual(fx.bands.first { $0.id == id }?.gain, 24)
        fx.bands.removeAll { $0.id == id }
        let previous = fx
        XCTAssertFalse(gain.apply(0, to: &fx)); XCTAssertEqual(fx, previous)
        XCTAssertEqual(try JSONDecoder().decode(NativeFXParameter.self, from: JSONEncoder().encode(gain)), gain)
        try fx.validate()
    }
    func testInstrumentEnvelopeCutoffAndVelocityMappingsRetainOtherParameters() throws {
        var fx = NativeFXSettings(); fx.inserted = ["Instruments"]; fx.instrumentID = "piano"
        NativeFXParameter(effect: "Instruments", key: .instrumentRelease, name: "Release", range: 0.001...20, logarithmic: true).apply(127, to: &fx)
        NativeFXParameter(effect: "Instruments", key: .velocityCutoff, name: "Cutoff", range: 20...20000, logarithmic: true).apply(0, to: &fx)
        NativeFXParameter(effect: "Instruments", key: .cutoffDepth, name: "Depth", range: 0...10).apply(127, to: &fx)
        XCTAssertEqual(fx.instrumentParameters?.release, 20)
        XCTAssertEqual(fx.instrumentParameters?.velocity?.cutoffMinimum, 20)
        XCTAssertEqual(fx.instrumentParameters?.cutoff?.depth, 10)
        XCTAssertEqual(fx.instrumentParameters?.sustain, 1)
        try fx.validate()
        fx.inserted = []
        let previous = fx
        XCTAssertFalse(NativeFXParameter(effect: "Instruments", key: .instrumentGain, name: "Gain", range: -24...12).apply(0, to: &fx))
        XCTAssertEqual(fx, previous)
    }
}
