import XCTest
final class TrackTouchTests:XCTestCase {
 func testTempoAndPitchDiscardTapsUntilAcknowledged() {
  let app=XCUIApplication();app.launch();let tempo=app.buttons["Aumentar BPM"];XCTAssertTrue(tempo.waitForExistence(timeout:10))
  let tempoPoint=tempo.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
  tempoPoint.tap();tempoPoint.tap();tempoPoint.tap()
  XCTAssertEqual(app.staticTexts["tempo-requests"].label,"Tempo requests: 1")
  XCTAssertFalse(tempo.isEnabled)
  let pitch=app.buttons["Aumentar afinação"],pitchPoint=pitch.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
  pitchPoint.tap();pitchPoint.tap();pitchPoint.tap()
  XCTAssertEqual(app.staticTexts["pitch-requests"].label,"Pitch requests: 1")
  XCTAssertFalse(pitch.isEnabled)
  app.buttons["Apply values"].tap()
  XCTAssertTrue(tempo.isEnabled);XCTAssertTrue(pitch.isEnabled)
  tempo.tap();pitch.tap()
  XCTAssertEqual(app.staticTexts["tempo-requests"].label,"Tempo requests: 2")
  XCTAssertEqual(app.staticTexts["pitch-requests"].label,"Pitch requests: 2")
 }

 func testControlsAndSelection() {
  let app=XCUIApplication();app.launch();XCTAssertTrue(app.buttons["Patch"].waitForExistence(timeout:10))
  let event=app.staticTexts["event"]
  for (label,result) in [("Patch","patch"),("FX","fx"),("REC","rec"),("M","mute"),("S","solo"),("Insert","insert"),("Add text","text")] {
   app.buttons[label].firstMatch.tap();XCTAssertTrue(event.waitForExistence(timeout:2));XCTAssertEqual(event.label,result,"\(label) must receive its touch")
  }
  let row=app.staticTexts["01  Normal track"].firstMatch
  row.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
  XCTAssertEqual(app.staticTexts["selection"].label,"Selected: 1")
  app.buttons["edit"].tap()
  app.buttons["M"].firstMatch.tap();XCTAssertEqual(event.label,"mute")
  row.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.7)
  XCTAssertEqual(event.label,"menu")
 }
}
