import XCTest
@testable import JarasApplication

final class MultiLoopEditingSelectionTests: XCTestCase {
    func testRangeToggleAndControlTargetsKeepTheirOwnSelection() {
        let rows = (0..<6).map { _ in UUID() }
        var selection = MultiLoopTrackSelection()
        selection.select(rows[1], ordered: rows)
        selection.select(rows[4], ordered: rows, extending: true)
        XCTAssertEqual(selection.ids, Set(rows[1...4]))
        selection.select(rows[2], ordered: rows, extending: true)
        XCTAssertEqual(selection.ids, Set(rows[1...2]), "Shift narrows from the original anchor")
        selection.select(rows[5], ordered: rows, additive: true)
        XCTAssertEqual(selection.targets(for: rows[2]), Set([rows[1], rows[2], rows[5]]))
        selection.select(rows[2], ordered: rows, additive: true)
        XCTAssertEqual(selection.ids, Set([rows[1], rows[5]]))
        XCTAssertEqual(selection.targets(for: rows[0]), [rows[0]], "An unselected control cannot change another selection")
    }
    func testGroupVolumeRetainsBalanceAndRecoversAfterHittingCeilings() {
        let a = UUID(), b = UUID(), outside = UUID()
        let rules = [MultiLoopTrack(id: a, gain: 0.5), MultiLoopTrack(id: b, gain: 0.25), MultiLoopTrack(id: outside)]
        let drag = MultiLoopGainDrag(source: a, targets: [a, b], rules: rules, ceilings: [a: 1, b: 0.3, outside: 1])
        XCTAssertEqual(drag.gains(at: 1), [a: 1, b: 0.3])
        XCTAssertEqual(drag.gains(at: 0.25), [a: 0.25, b: 0.125], "A clipped fader recovers its original balance on reversal")
        XCTAssertEqual(drag.gains(at: 0), [a: 0, b: 0])
        XCTAssertEqual(drag.gains(at: 0.5), [a: 0.5, b: 0.25], "Dragging through silence does not lose the gesture baseline")
        XCTAssertTrue(drag.gains(at: .nan).isEmpty)
        let silent = MultiLoopGainDrag(source: a, targets: [a, b], rules: [.init(id: a, gain: 0), .init(id: b, gain: 0)], ceilings: [a: 1, b: 0])
        XCTAssertEqual(silent.gains(at: 0.4), [a: 0.4, b: 0], "A muted base cannot be boosted by a group edit")
    }
}
