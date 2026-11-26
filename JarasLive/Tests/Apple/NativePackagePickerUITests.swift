import XCTest

final class NativePackagePickerUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testBothEntryPointsOpenFilesAndCanRetryAfterCancellation() {
        let app = XCUIApplication(); app.launch()
        for (index, entry) in ["Add .ziplive", "Browse recent projects", "Add .ziplive"].enumerated() {
            app.buttons[entry].tap()
            let confirmation = app.alerts["Choose a CatLive project"]
            if entry == "Add .ziplive" {
                XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
                confirmation.buttons["Choose file"].tap()
            } else { XCTAssertFalse(confirmation.exists) }
            let cancel = app.navigationBars.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertFalse(confirmation.exists)
            cancel.tap()
            XCTAssertTrue(app.staticTexts["Cancellations: \(index + 1)"].waitForExistence(timeout: 5))
        }
    }

    func testRecentBrowserAllowsSelectingJLDocument() {
        let app = XCUIApplication(); app.launch()
        app.buttons["Browse recent projects"].tap()
        let file = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Example.jl")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30), app.debugDescription)
        file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(app.staticTexts["Opened: Example.jl"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testDestinationConfirmationOpensFolderPickerAndCancelAllowsRetry() {
        let app = XCUIApplication(); app.launch()
        for _ in 0..<2 {
            app.buttons["Choose import destination"].tap()
            let confirmation = app.alerts["Choose a folder for the imported project"]
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
            confirmation.buttons["Choose folder"].tap()
            let cancel = app.navigationBars.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertFalse(confirmation.exists)
            cancel.tap()
        }
        app.buttons["Add .ziplive"].tap()
        app.alerts.buttons["Cancel"].tap()
        XCTAssertFalse(app.navigationBars.buttons["Cancel"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Browse recent projects"].exists)
    }
}
