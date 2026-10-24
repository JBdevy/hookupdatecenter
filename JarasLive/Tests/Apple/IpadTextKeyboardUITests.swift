import XCTest
final class KeyboardTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication(); app.launch()
    }
    private func key(_ id: String) -> XCUIElement {
        let button = app.buttons["cat-key-" + id].firstMatch
        if ["select-all", "copy"].contains(id) {
            let names = id == "select-all" ? ["Select All", "Selecionar Tudo", "Selecionar tudo"] : ["Copy", "Copiar"]
            let action = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", names)).firstMatch
            if !action.exists {
                let field = app.textFields["Nome"].exists ? app.textFields["Nome"] : app.textFields["search"]
                field.press(forDuration: 0.8)
            }
            XCTAssertTrue(action.waitForExistence(timeout: 3))
            return action
        }
        return button
    }
    func testShiftAccentsNumbersAndOutsideTap() {
        app.textFields["search"].tap()
        XCTAssertTrue(key("a").waitForExistence(timeout: 5))
        key("shift").tap(); key("a").tap(); key("b").tap()
        XCTAssertEqual(app.textFields["search"].value as? String, "Ab")
        key("shift").doubleTap(); key("c").tap(); key("d").tap()
        XCTAssertEqual(app.textFields["search"].value as? String, "AbCD")
        key("shift").tap(); key("a").press(forDuration: 0.6); key("accent-ã").tap()
        key("page").tap(); key("3").tap()
        XCTAssertEqual(app.textFields["search"].value as? String, "AbCDã3")
        key("!").tap()
        XCTAssertEqual(app.textFields["search"].value as? String, "AbCDã3!")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.4)).tap()
        XCTAssertTrue(key("a").waitForNonExistence(timeout: 3))
        XCTAssertFalse(key("close").exists)
    }
    func testEditModalStaysAboveKeyboardAndSaveActsOnce() {
        app.buttons["Editar"].tap()
        XCTAssertTrue(key("close").waitForExistence(timeout: 5))
        let save = app.buttons["Salvar"].firstMatch
        XCTAssertTrue(save.isHittable)
        XCTAssertGreaterThan(app.staticTexts["Editar pista"].frame.minY, app.frame.minY)
        XCTAssertLessThan(save.frame.maxY, key("undo").frame.minY)
        key("select-all").tap(); key("shift").tap(); key("v").tap(); key("o").tap(); key("z").tap()
        save.tap()
        XCTAssertEqual(app.staticTexts["saved"].label, "Salvo: Voz")
        XCTAssertFalse(app.buttons["Salvar"].exists)
        XCTAssertTrue(key("close").waitForNonExistence(timeout: 3))
    }
    func testCursorSelectionDeleteAndClipboard() {
        app.textFields["search"].tap(); XCTAssertTrue(key("a").waitForExistence(timeout: 5))
        key("a").tap(); key("b").tap(); key("c").tap()
        key("delete").tap()
        XCTAssertEqual(app.textFields["search"].value as? String, "ab")
        key("select-all").tap(); key("copy").tap(); key("delete").tap(); key("paste").tap()
        XCTAssertEqual(app.textFields["search"].value as? String, "ab")
    }
    func testMultilineAndNumericFieldSwitch() {
        app.textViews["notes"].tap(); XCTAssertTrue(key("a").waitForExistence(timeout: 5))
        key("a").tap(); key("return").tap(); key("b").tap()
        XCTAssertEqual(app.textViews["notes"].value as? String, "a\nb")
        app.secureTextFields["pin"].tap()
        XCTAssertTrue(key("1").waitForExistence(timeout: 3)); XCTAssertTrue(key("@").exists)
        key("1").tap(); key("2").tap(); key("close").tap()
        XCTAssertFalse(key("close").exists)
    }
    func testReturnSubmitsAndLongPressOffersAccents() {
        app.buttons["Editar"].tap(); XCTAssertTrue(key("a").waitForExistence(timeout: 5))
        key("select-all").tap(); key("a").press(forDuration: 0.6)
        XCTAssertTrue(key("accent-ã").waitForExistence(timeout: 2)); key("accent-ã").tap()
        XCTAssertEqual(app.textFields["Nome"].value as? String, "ã")
        key("return").tap()
        XCTAssertEqual(app.staticTexts["saved"].label, "Salvo: ã")
        XCTAssertFalse(app.buttons["Salvar"].exists)
    }
    func testNativeKeyPositionsAndEmoji() {
        app.textFields["search"].tap(); XCTAssertTrue(key("q").waitForExistence(timeout: 5))
        XCTAssertFalse(key("accents").exists); XCTAssertFalse(key("editing-tools").exists); XCTAssertFalse(key("ç").exists)
        XCTAssertGreaterThan(key("delete").frame.minX, key("p").frame.minX)
        XCTAssertEqual(key("delete").frame.midY, key("q").frame.midY, accuracy: 1)
        XCTAssertEqual(key("return").frame.midY, key("a").frame.midY, accuracy: 1)
        XCTAssertLessThan(key("page").frame.minX, key("space").frame.minX)
        XCTAssertGreaterThan(key("page-right").frame.minX, key("space").frame.minX)
        key("emoji").tap(); app.descendants(matching: .any)["cat-emoji-😀"].firstMatch.tap()
        XCTAssertEqual(app.textFields["search"].value as? String, "😀")
    }
}
