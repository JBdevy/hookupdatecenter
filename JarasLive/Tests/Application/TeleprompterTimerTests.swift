import XCTest
@testable import JarasApplication

final class TeleprompterTimerTests: XCTestCase {
    func testProgressiveUsesElapsedTimeAndStopResets() {
        var timer = TeleprompterTimer()
        timer.start(at: 100)
        XCTAssertEqual(timer.displaySeconds(at: 161.25), 61.25)
        timer.start(at: 170) // Repeated UI commands do not restart a running timer.
        XCTAssertEqual(timer.displaySeconds(at: 180), 80)
        timer.stopAndReset()
        XCTAssertEqual(timer.displaySeconds(at: 1000), 0)
        XCTAssertFalse(timer.running)
        timer.start(at: 2000)
        XCTAssertEqual(timer.displaySeconds(at: 2001), 1)
    }

    func testCountdownContinuesBelowZeroAndRestartUsesTarget() {
        var timer = TeleprompterTimer(mode: .countdown, targetSeconds: 10)
        XCTAssertEqual(timer.displaySeconds(at: 100), 10)
        XCTAssertFalse(timer.isExpired(at: 100))
        timer.start(at: 100)
        XCTAssertEqual(timer.displaySeconds(at: 109), 1)
        XCTAssertTrue(timer.isExpired(at: 110))
        XCTAssertEqual(timer.displaySeconds(at: 112.5), -2.5)
        timer.stopAndReset()
        XCTAssertEqual(timer.displaySeconds(at: 200), 0)
        XCTAssertFalse(timer.isExpired(at: 200))
        timer.start(at: 200)
        XCTAssertEqual(timer.displaySeconds(at: 201), 9)
    }

    func testModeAndTargetChangesApplyImmediatelyWithoutStoppingTimer() {
        var timer = TeleprompterTimer(targetSeconds: 120)
        timer.start(at: 100)
        timer.setMode(.countdown, at: 110)
        XCTAssertTrue(timer.running)
        XCTAssertEqual(timer.displaySeconds(at: 111), 119)
        timer.setTarget(seconds: 30, at: 112)
        XCTAssertEqual(timer.displaySeconds(at: 114), 28)
        timer.setMode(.progressive, at: 115)
        XCTAssertEqual(timer.displaySeconds(at: 117), 2)
        timer.setTarget(seconds: 60, at: 118)
        XCTAssertEqual(timer.displaySeconds(at: 120), 5)
        timer.setMode(.progressive, at: 121)
        XCTAssertEqual(timer.displaySeconds(at: 122), 7)
    }

    func testInitAutoUsesPlaybackEdgesPreservesPauseAndIgnoresSeeks() {
        let project = UUID(), first = UUID(), second = UUID()
        var timer = TeleprompterTimer(initAutoEnabled: true)
        timer.observePlayback(project: project, region: first, playing: false, paused: false, at: 0)
        XCTAssertFalse(timer.running)
        timer.observePlayback(project: project, region: first, playing: true, paused: false, at: 10)
        XCTAssertEqual(timer.displaySeconds(at: 13), 3)
        timer.stopAndReset()
        timer.observePlayback(project: project, region: first, playing: true, paused: false, at: 20)
        timer.observePlayback(project: project, region: first, playing: false, paused: true, at: 21)
        timer.observePlayback(project: project, region: first, playing: true, paused: false, at: 22)
        XCTAssertFalse(timer.running)
        timer.observePlayback(project: project, region: second, playing: true, paused: false, at: 30)
        XCTAssertTrue(timer.running)
        timer.observePlayback(project: project, region: first, playing: true, paused: false, at: 32)
        XCTAssertEqual(timer.displaySeconds(at: 33), 3)
        timer.stopAndReset()
        timer.observePlayback(project: project, region: first, playing: false, paused: false, at: 40)
        timer.observePlayback(project: project, region: first, playing: true, paused: false, at: 50)
        XCTAssertEqual(timer.displaySeconds(at: 51), 1)
    }

    func testTargetInputFormattingLimitsAndInvalidClockValues() {
        XCTAssertEqual(TeleprompterTimer.targetSeconds(from: "01:02:03"), 3723)
        XCTAssertEqual(TeleprompterTimer.targetSeconds(from: "200:80:99"), TeleprompterTimer.maximumTargetSeconds)
        XCTAssertEqual(TeleprompterTimer.targetSeconds(from: "00:00:00"), 0)
        for invalid in ["1:2", "::", "-1:00:00", "01:xx:00", "01: 02:03"] {
            XCTAssertNil(TeleprompterTimer.targetSeconds(from: invalid))
        }
        XCTAssertEqual(TeleprompterTimer.formatted(3723), "01:02:03")
        XCTAssertEqual(TeleprompterTimer.formatted(-61, spaced: true), "−00 : 01 : 01")
        var timer = TeleprompterTimer(mode: .countdown, targetSeconds: .max)
        XCTAssertEqual(timer.targetSeconds, TeleprompterTimer.maximumTargetSeconds)
        timer.start(at: .nan)
        XCTAssertFalse(timer.running)
        timer.start(at: 100)
        XCTAssertEqual(timer.displaySeconds(at: 99), Double(timer.targetSeconds))
        XCTAssertEqual(timer.displaySeconds(at: .infinity), Double(timer.targetSeconds))
        timer.setTarget(seconds: -1, at: 100)
        XCTAssertEqual(timer.targetSeconds, 0)
    }
}
