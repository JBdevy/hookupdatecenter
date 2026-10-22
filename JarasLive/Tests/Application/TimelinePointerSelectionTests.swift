import XCTest
@testable import JarasApplication

final class TimelinePointerSelectionTests: XCTestCase {
    func testPressOnSelectedItemKeepsGroupUntilPlainRelease() {
        let a = UUID(), b = UUID(), c = UUID()
        var selection = TimelinePointerSelection()
        selection.replace([a, b, c], anchor: a)
        selection.begin(b, additive: false)
        XCTAssertEqual(selection.items, [a, b, c])
        XCTAssertEqual(selection.anchor, b)
        selection.end(dragged: false)
        XCTAssertEqual(selection.items, [b])
        XCTAssertEqual(selection.anchor, b)
        selection.end(dragged: false)
        XCTAssertEqual(selection.items, [b], "A duplicate release must not clear the current selection")
    }

    func testDragKeepsSelectedGroupAndPressedAnchor() {
        let a = UUID(), b = UUID()
        var selection = TimelinePointerSelection()
        selection.replace([a, b], anchor: a)
        selection.begin(b, additive: false)
        selection.beginDrag()
        selection.end(dragged: true)
        XCTAssertEqual(selection.items, [a, b])
        XCTAssertEqual(selection.anchor, b)
    }

    func testClickOnEmptyGridClearsOnlyOnRelease() {
        let a = UUID(), b = UUID()
        var selection = TimelinePointerSelection()
        selection.replace([a, b], anchor: b)
        selection.begin(nil, additive: false)
        XCTAssertEqual(selection.items, [a, b])
        selection.end(dragged: false)
        XCTAssertTrue(selection.items.isEmpty)
        XCTAssertNil(selection.anchor)
    }

    func testCommandClickTogglesWithoutLeavingDeselectedAnchor() {
        let a = UUID(), b = UUID()
        var selection = TimelinePointerSelection()
        selection.replace([a], anchor: a)
        selection.begin(b, additive: true)
        selection.end(dragged: false)
        XCTAssertEqual(selection.items, [a, b])
        XCTAssertEqual(selection.anchor, b)
        selection.begin(b, additive: true)
        selection.end(dragged: false)
        XCTAssertEqual(selection.items, [a])
        XCTAssertEqual(selection.anchor, a)
        selection.begin(a, additive: true)
        selection.end(dragged: false)
        XCTAssertTrue(selection.items.isEmpty)
        XCTAssertNil(selection.anchor, "No editor or Delete action should target a deselected item")
    }

    func testCommandDragRestoresPressedItemWhileKeepingOtherSelection() {
        let a = UUID(), b = UUID()
        var selection = TimelinePointerSelection()
        selection.replace([a, b], anchor: a)
        selection.begin(b, additive: true)
        XCTAssertEqual(selection.items, [a])
        selection.beginDrag()
        selection.end(dragged: true)
        XCTAssertEqual(selection.items, [a, b])
        XCTAssertEqual(selection.anchor, b)
    }

    func testCommandClickEmptyGridPreservesSelection() {
        let a = UUID()
        var selection = TimelinePointerSelection()
        selection.replace([a], anchor: a)
        selection.begin(nil, additive: true)
        selection.end(dragged: false)
        XCTAssertEqual(selection.items, [a])
        XCTAssertEqual(selection.anchor, a)
    }

    func testPressOnNewItemReplacesOldSelectionBeforeDrag() {
        let a = UUID(), b = UUID(), c = UUID()
        var selection = TimelinePointerSelection()
        selection.replace([a, b], anchor: a)
        selection.begin(c, additive: false)
        XCTAssertEqual(selection.items, [c])
        selection.beginDrag()
        selection.end(dragged: true)
        XCTAssertEqual(selection.items, [c])
        XCTAssertEqual(selection.anchor, c)
    }

    func testRetainingAvailableItemsDropsDeletedAnchor() {
        let a = UUID(), b = UUID()
        var selection = TimelinePointerSelection()
        selection.replace([a, b], anchor: b)
        selection.retain([a])
        XCTAssertEqual(selection.items, [a])
        XCTAssertEqual(selection.anchor, a)
        selection.retain([])
        XCTAssertNil(selection.anchor)
        selection.end(dragged: false)
        XCTAssertTrue(selection.items.isEmpty)
    }
}

extension ProjectEditingTests {
    func testGroupMovePreservesSourcePlaybackAndEnvelopeMetadata() throws {
        var song = Project.empty(name: "Selected item translation").songs[0]
        song.parts = []
        var first = AudioClip(id: UUID(), name: "First", startTime: 2, duration: 3)
        first.audioFile = AudioFile(path: "Stems/first.wav")
        first.sourceOffset = 7.5; first.playbackRate = 1.25; first.gain = 0.5
        first.pan = -0.3; first.fadeIn = 0.2; first.fadeOut = 0.4; first.phaseInverted = true
        var second = AudioClip(id: UUID(), name: "Second", startTime: 8, duration: 1)
        second.audioFile = AudioFile(path: "Stems/second.wav"); second.sourceOffset = 12
        var a = Track(id: UUID(), name: "A", role: .other); a.clips = [first]
        var b = Track(id: UUID(), name: "B", role: .other); b.clips = [second]
        song.tracks = [a, b]
        let original = song
        let moved = try XCTUnwrap(song.movingItems([first.id, second.id], anchor: first.id, start: 19, track: nil))
        first.startTime += 17; second.startTime += 17
        XCTAssertEqual(moved.tracks[0].clips, [first])
        XCTAssertEqual(moved.tracks[1].clips, [second])
        XCTAssertEqual(song, original, "The preview must never mutate committed playback data")
    }

    func testGroupMoveRejectsAllItemsWhenOneSpecialTrackWouldOverlap() {
        var song = Project.empty(name: "Atomic selected item translation").songs[0]
        song.parts = []
        let audio = AudioClip(id: UUID(), name: "Audio", startTime: 1, duration: 1)
        var text = AudioClip(id: UUID(), name: "Lyrics", startTime: 1, duration: 2); text.text = "Verse"
        var occupied = AudioClip(id: UUID(), name: "Existing lyrics", startTime: 10, duration: 2); occupied.text = "Chorus"
        var a = Track(id: UUID(), name: "A", role: .other); a.clips = [audio]
        var tp = Track(id: UUID(), name: "Teleprompter", role: TrackRole(rawValue: "teleprompt")); tp.clips = [text, occupied]
        song.tracks = [a, tp]
        let before = song
        XCTAssertNil(song.movingItems([audio.id, text.id], anchor: audio.id, start: 10, track: nil))
        XCTAssertEqual(song, before)
        XCTAssertNotNil(song.movingItems([audio.id, text.id], anchor: audio.id, start: 5, track: nil))
    }
}

extension TimelineSnapTests {
    func testStrongCursorRadiusIsTwelveScreenPixelsAtDifferentZooms() {
        var song = Project.empty(name: "Screen-space magnet").songs[0]
        song.parts = []; song.markers = []; song.tracks = []; song.bpm = 120
        for scale in [10.0, 40, 100, 1000] {
            let position = 16.0
            let boundary = position + 12 / scale
            XCTAssertEqual(TimelineTempo.snap(position, song: song, pixelsPerSecond: scale, cursor: boundary,
                includeHiddenDivisions: true), boundary, accuracy: 1e-9)
            XCTAssertEqual(TimelineTempo.snap(position, song: song, pixelsPerSecond: scale, cursor: position + 13 / scale,
                includeHiddenDivisions: true), position, accuracy: 1e-9)
            XCTAssertEqual(TimelineTempo.snap(position + 0.003, song: song, pixelsPerSecond: scale, cursor: boundary,
                enabled: false, includeHiddenDivisions: true), position + 0.003, accuracy: 1e-9)
        }
    }
}
