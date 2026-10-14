import XCTest
final class WaveformDisplayTests: XCTestCase {
    func testRapidPanPresentsOnlyWithUIKitAndStopsDrawingWhenIdle() {
        let app = XCUIApplication(); app.launch()
        let result = app.staticTexts["waveform-display-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        let done = NSPredicate(format: "label BEGINSWITH 'PASS:' OR label BEGINSWITH 'FAIL:'")
        expectation(for: done, evaluatedWith: result)
        waitForExpectations(timeout: 40)
        XCTAssertTrue(result.label.hasPrefix("PASS:"), result.label)
    }
}
