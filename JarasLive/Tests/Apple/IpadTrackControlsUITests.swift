import XCTest
final class TrackTouchTests:XCTestCase {
 func testTeleprompterControlsFitAtMinimumTrackHeight() {
  let app = XCUIApplication()
  app.launch()
  XCTAssertTrue(app.buttons["Show Remote rows"].waitForExistence(timeout: 10))
  XCTAssertEqual(app.buttons.matching(identifier: "M").count, 3)
  XCTAssertEqual(app.buttons.matching(identifier: "S").count, 3)
  XCTAssertFalse(app.buttons["Add media"].exists)
  for name in ["04  TP 1", "05  TP 2"] {
   let title = app.staticTexts[name]
   XCTAssertTrue(title.exists)
   guard let lyrics = app.buttons.matching(identifier: "Full lyrics").allElementsBoundByIndex.last(where: {
    $0.frame.maxY <= title.frame.minY + 1
   }), let addText = app.buttons.matching(identifier: "Add text").allElementsBoundByIndex.last(where: {
    $0.frame.maxY <= lyrics.frame.minY + 1
   }), let patch = app.buttons.matching(identifier: "Patch").allElementsBoundByIndex.min(by: {
    abs($0.frame.midY - addText.frame.midY) < abs($1.frame.midY - addText.frame.midY)
   }), let knob = app.descendants(matching: .any).matching(identifier: "Track volume").allElementsBoundByIndex.min(by: {
    abs($0.frame.midY - addText.frame.midY) < abs($1.frame.midY - addText.frame.midY)
   }) else {
    XCTFail("Missing a Teleprompter control on " + name)
    continue
   }
   XCTAssertEqual(knob.frame.midY, addText.frame.midY, accuracy: 1, "The volume knob aligns with Add text")
   XCTAssertLessThan(knob.frame.midX, addText.frame.minX)
   XCTAssertEqual(patch.frame.midY, addText.frame.midY, accuracy: 1, "Patch aligns with Add text")
   XCTAssertEqual(addText.frame.minX, lyrics.frame.minX, accuracy: 1, "Text actions share one column")
   XCTAssertLessThanOrEqual(lyrics.frame.minY - addText.frame.maxY, 4)
   XCTAssertGreaterThanOrEqual(title.frame.height, 13)
   XCTAssertGreaterThanOrEqual(title.frame.minY + 1, lyrics.frame.maxY)
  }
  app.buttons["Full lyrics"].firstMatch.tap()
  XCTAssertEqual(app.staticTexts["event"].label, "tp-lyrics")
  app.staticTexts["04  TP 1"].press(forDuration: 0.8)
  XCTAssertTrue(app.buttons["Add media"].waitForExistence(timeout: 3))
  app.buttons["Add media"].tap()
  XCTAssertEqual(app.staticTexts["event"].label, "tp-media")
  app.buttons["Show Remote rows"].tap()
  XCTAssertEqual(app.buttons.matching(identifier: "M").count, 5)
  XCTAssertEqual(app.buttons.matching(identifier: "S").count, 5)
 }

 func testRecordHoldOpensSettingsWithoutArmingAndKeepsMIDIChannelInAudioMode() {
  let app = XCUIApplication(); app.launch()
  let rec = app.buttons["Arm track for recording"].firstMatch
  XCTAssertTrue(rec.waitForExistence(timeout: 10))
  rec.press(forDuration: 0.8)
  XCTAssertTrue(app.staticTexts["Recording mode"].waitForExistence(timeout: 3), app.debugDescription)
  XCTAssertEqual(app.staticTexts["event"].label, "none", "Opening REC options must not arm the track")
  XCTAssertFalse(app.buttons["Insert media"].exists, "The track menu must not steal the REC hold")
  let channels = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "MIDI channel")).firstMatch
  XCTAssertTrue(channels.exists, app.debugDescription)
  channels.tap(); app.buttons["3"].firstMatch.tap()
  app.buttons["MIDI"].tap()
  XCTAssertTrue(channels.label.contains("3"))
  app.buttons["Stereo"].tap()
  XCTAssertTrue(channels.label.contains("3"), "Input MIDI channel must survive switching to audio recording")
  app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.9)).tap()
  rec.tap(); XCTAssertEqual(app.staticTexts["event"].label, "rec")
 }
 func testIconsExtendRowsAndHaveTheirOwnNativeMenuEntry() {
  let app=XCUIApplication();app.launch()
  let toggle=app.buttons["Toggle icons"]
  XCTAssertTrue(toggle.waitForExistence(timeout:10))
  let row=app.otherElements["normal-row-frame"].firstMatch
  let labels=["Patch","FX","Arm track for recording","M","S"]
  let originalWidth=row.frame.width
  let positions=labels.map {app.buttons[$0].firstMatch.frame.minX-row.frame.minX}
  toggle.tap()
  XCTAssertEqual(row.frame.width,originalWidth+40,accuracy:1)
  for (label,x) in zip(labels,positions) {
   XCTAssertEqual(app.buttons[label].firstMatch.frame.minX-row.frame.minX,x,accuracy:1,
                  "Adding an icon must not compress or move track controls")
  }
  toggle.tap();XCTAssertEqual(row.frame.width,originalWidth,accuracy:1)
  app.staticTexts["01  Normal track"].press(forDuration:0.8)
  let icon=app.buttons["Ícone da pista"]
  XCTAssertTrue(icon.waitForExistence(timeout:3));icon.tap()
  XCTAssertEqual(app.staticTexts["event"].label,"track-icon")
 }
 func testCompactRowsKeepPatchAndFXUntilTheirControlsActuallyNeedTheSpace() {
  let app=XCUIApplication();app.launch()
  XCTAssertTrue(app.buttons["Compact 285"].waitForExistence(timeout:10))
  let midi = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "MIDI activity")).firstMatch
  XCTAssertFalse(midi.exists, "The mixer no longer shows MIDI activity")
  let audio = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Audio meter")).firstMatch
  XCTAssertTrue(audio.exists)
  app.buttons["Compact 285"].tap()
  XCTAssertFalse(midi.exists, "Compact tracks hide MIDI activity")
  XCTAssertTrue(audio.exists, "Compact tracks still show audio activity")
  XCTAssertTrue(app.buttons["Patch"].exists);XCTAssertTrue(app.buttons["FX"].exists)
  app.buttons["Patch"].tap();XCTAssertEqual(app.staticTexts["event"].label,"patch")
  app.buttons["Compact 235"].tap()
  XCTAssertFalse(app.buttons["Patch"].exists);XCTAssertTrue(app.buttons["FX"].exists)
  app.buttons["FX"].tap();XCTAssertEqual(app.staticTexts["event"].label,"fx")
  app.buttons["Compact 190"].tap()
  XCTAssertFalse(app.buttons["Patch"].exists);XCTAssertFalse(app.buttons["FX"].exists)
  let meter = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Audio meter")).firstMatch
  XCTAssertTrue(meter.exists,"Compact tracks must retain their audio meter: \(app.debugDescription)")
  if meter.exists { XCTAssertGreaterThan(meter.frame.height, 0); XCTAssertLessThanOrEqual(meter.frame.height, 60) }
  XCTAssertTrue(app.buttons["Arm track for recording"].exists);XCTAssertTrue(app.buttons["M"].firstMatch.exists);XCTAssertTrue(app.buttons["S"].firstMatch.exists)
 }
 func testEmptyTrackAreaSelectsWithoutChangingControls() {
  let app=XCUIApplication();app.launch()
  let row=app.otherElements["normal-row"].firstMatch
  XCTAssertTrue(row.waitForExistence(timeout:10))
  row.coordinate(withNormalizedOffset:CGVector(dx:0.15,dy:0.08)).tap()
  XCTAssertEqual(app.staticTexts["selection"].label,"Selected: 1")
  XCTAssertEqual(app.staticTexts["event"].label,"none")
 }
 func testLongPressOffersPatchAndAddStems() {
  let app=XCUIApplication();app.launch();let name=app.staticTexts["01  Normal track"]
  XCTAssertTrue(name.waitForExistence(timeout:10));name.press(forDuration:1.2)
  XCTAssertTrue(app.buttons["Insert media"].waitForExistence(timeout:5), app.debugDescription)
  XCTAssertTrue(app.buttons["Duplicate track"].exists)
  XCTAssertTrue(app.buttons["Delete track"].exists)
  XCTAssertFalse(app.buttons["Criar item MIDI"].exists)
  app.buttons.matching(identifier:"Patch").allElementsBoundByIndex.last!.tap()
  XCTAssertEqual(app.staticTexts["event"].label,"context-patch")
 }

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

 func testNativeVolumeFaderKeepsControlDuringDiagonalDrag() {
  let app = XCUIApplication()
  app.launch()
  let fader = app.descendants(matching: .any)["Volume Normal track"].firstMatch
  XCTAssertTrue(fader.waitForExistence(timeout: 10))
  let start = fader.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
  let end = start.withOffset(CGVector(dx: 45, dy: 70))
  start.press(forDuration: 0.08, thenDragTo: end)
  XCTAssertEqual(app.staticTexts["event"].label, "volume")
 }

 func testControlsAndSelection() {
  let app=XCUIApplication();app.launch();XCTAssertTrue(app.buttons["Patch"].waitForExistence(timeout:10))
  let event=app.staticTexts["event"]
  for (label,result) in [("Patch","patch"),("FX","fx"),("Arm track for recording","rec"),("M","mute"),("S","solo"),("Insert","insert"),("Add text","text")] {
   app.buttons[label].firstMatch.tap();XCTAssertTrue(event.waitForExistence(timeout:2));XCTAssertEqual(event.label,result,"\(label) must receive its touch")
  }
  let row=app.staticTexts["01  Normal track"].firstMatch
  row.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
  XCTAssertEqual(app.staticTexts["selection"].label,"Selected: 1")
  app.buttons["edit"].tap()
  let grip=app.descendants(matching:.any)["Move track"].firstMatch
  XCTAssertTrue(grip.exists);XCTAssertLessThanOrEqual(grip.frame.width,36)
  for (label,result) in [("Patch","patch"),("FX","fx"),("Arm track for recording","rec"),("S","solo")] {
   app.buttons[label].firstMatch.tap();XCTAssertEqual(event.label,result,"Editing must leave \(label) interactive")
  }
  app.buttons["M"].firstMatch.tap();XCTAssertEqual(event.label,"mute")
  row.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:1.2)
  let group=app.buttons["Create group"]
  XCTAssertTrue(group.waitForExistence(timeout:5));group.tap()
  XCTAssertEqual(event.label,"group")
 }
}
