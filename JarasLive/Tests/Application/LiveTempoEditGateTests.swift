import XCTest
@testable import JarasApplication
final class LiveTempoEditGateTests: XCTestCase {
    func testImmediateFirstExactBoundaryAndDiscardedInputsDoNotDelayDeadline() {
        var gate = LiveTempoEditGate()
        XCTAssertTrue(gate.accept(running: true, at: 10))
        for time in [10.01,10.2,10.499] { XCTAssertFalse(gate.accept(running: true, at: time)) }
        XCTAssertTrue(gate.accept(running: true, at: 10.5))
        XCTAssertFalse(gate.accept(running: true, at: 10.999))
        XCTAssertTrue(gate.accept(running: false, at: 11))
        XCTAssertTrue(gate.accept(running: false, at: 11))
        XCTAssertTrue(gate.accept(running: true, at: 11))
        gate.reset()
        XCTAssertTrue(gate.accept(running: true, at: 11.01))
    }
}
