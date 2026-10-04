import XCTest
@testable import JarasApplication

final class TimelinePlaybackPresentationTests: XCTestCase {
    private func transport(main: Double = 10, sub: Double = 70, playing: Bool = true,
                           subPlaying: Bool = false) -> TransportState {
        TransportState(playing: playing, position: main, queue: QueueState(),
                       loop: LoopState(enabled: false),
                       subPlay: SubPlayState(playing: subPlaying, position: sub))
    }

    func testZoomUsesSubPlayThenPlaybackThenEditingHead() {
        var sample = transport(main: 25, sub: 80, playing: false)
        sample.editPosition = 3
        XCTAssertEqual(sample.timelineZoomPosition, 3)
        sample.playing = true
        XCTAssertEqual(sample.timelineZoomPosition, 25)
        sample.subPlay.playing = true
        XCTAssertEqual(sample.timelineZoomPosition, 80)
        sample.subPlay.playing = false
        XCTAssertEqual(sample.timelineZoomPosition, 25)
        sample.playing = false
        XCTAssertEqual(sample.timelineZoomPosition, 3)
    }

    func testIntermediateFrameAdvancesOnlyRunningHeads() {
        let frame = TimelinePlaybackPresentation(transport: transport(), elapsed: 1.0 / 60,
                                                 songDuration: 100)
        XCTAssertEqual(frame.mainPosition, 10 + 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(frame.subPosition, 70)
        XCTAssertEqual(frame.followSource, .main)
        XCTAssertEqual(frame.followPosition, frame.mainPosition)
    }

    func testPausedAndStoppedSamplesDoNotAdvanceOrFollow() {
        var sample = transport(playing: false)
        sample.paused = true
        let paused = TimelinePlaybackPresentation(transport: sample, elapsed: 0.05, songDuration: 100)
        XCTAssertEqual(paused.mainPosition, 10)
        XCTAssertEqual(paused.subPosition, 70)
        XCTAssertNil(paused.followSource)
        XCTAssertNil(paused.followPosition)
        sample.paused = false
        XCTAssertEqual(TimelinePlaybackPresentation(transport: sample, elapsed: 0.05, songDuration: 100), paused)
    }

    func testSubPlayOwnsViewAndCancellationReturnsToMainImmediately() {
        var sample = transport(subPlaying: true)
        let frame = TimelinePlaybackPresentation(transport: sample, elapsed: 0.02, songDuration: 100)
        XCTAssertEqual(frame.mainPosition, 10.02, accuracy: 1e-12)
        XCTAssertEqual(frame.subPosition, 70.02, accuracy: 1e-12)
        XCTAssertEqual(frame.followSource, .sub)
        XCTAssertEqual(frame.followPosition, frame.subPosition)
        sample.subPlay.playing = false
        sample.position = 10.03
        let cancelled = TimelinePlaybackPresentation(transport: sample, elapsed: 0, songDuration: 100)
        XCTAssertEqual(cancelled.followSource, .main)
        XCTAssertEqual(cancelled.followPosition, 10.03)
    }

    func testSubPlayCanRemainTheOnlyRunningHead() {
        let frame = TimelinePlaybackPresentation(transport: transport(playing: false, subPlaying: true),
                                                 elapsed: 0.02, songDuration: 100)
        XCTAssertEqual(frame.mainPosition, 10)
        XCTAssertEqual(frame.followSource, .sub)
        XCTAssertEqual(frame.subPosition, 70.02, accuracy: 1e-12)
    }

    func testPromotionUsesNewMainSampleWithoutContinuingTheOldHead() {
        var sample = transport(subPlaying: true)
        let before = TimelinePlaybackPresentation(transport: sample, elapsed: 0.02, songDuration: 100)
        sample.subPlay.playing = false
        sample.position = before.subPosition
        sample.subPlayPromotion = 1
        let promoted = TimelinePlaybackPresentation(transport: sample, elapsed: 0, songDuration: 100)
        XCTAssertEqual(promoted.followSource, .main)
        XCTAssertEqual(promoted.followPosition, before.followPosition)
    }

    func testLoopEndpointWaitsForAuthoritativeWrapAndFreshSampleRepositions() {
        var sample = transport(main: 19.99)
        sample.loop = LoopState(enabled: true, start: 10, end: 20)
        let edge = TimelinePlaybackPresentation(transport: sample, elapsed: 0.05, songDuration: 100,
                                                mainBoundary: 19.995)
        XCTAssertEqual(edge.mainPosition, 20, "Presentation must not invent a wrap or stop at an unrelated region.")
        sample.position = 10.023
        let wrapped = TimelinePlaybackPresentation(transport: sample, elapsed: 0.01, songDuration: 100)
        XCTAssertEqual(wrapped.mainPosition, 10.033, accuracy: 1e-12)
        sample.position = 12
        XCTAssertEqual(TimelinePlaybackPresentation(transport: sample, elapsed: 0, songDuration: 100).mainPosition, 12)
    }

    func testMultiLoopEndpointAndRelease() {
        var sample = transport(main: 39.99)
        sample.multiLoop = MultiLoopPlayback(id: UUID(), start: 30, end: 40, amount: 1,
                                            gates: true, released: false, tracks: [])
        XCTAssertEqual(TimelinePlaybackPresentation(transport: sample, elapsed: 0.05, songDuration: 100).mainPosition, 40)
        sample.multiLoop?.released = true
        XCTAssertEqual(TimelinePlaybackPresentation(transport: sample, elapsed: 0.05, songDuration: 100).mainPosition,
                       40.04, accuracy: 1e-12)
    }

    func testRegionAndIgnoreNextBoundariesDoNotConstrainSubPlay() {
        var sample = transport(main: 19.99, sub: 79.99, subPlaying: true)
        let region = TimelinePlaybackPresentation(transport: sample, elapsed: 0.05, songDuration: 100,
                                                  mainBoundary: 20)
        XCTAssertEqual(region.mainPosition, 20)
        XCTAssertEqual(region.subPosition, 80.04, accuracy: 1e-12)
        sample.ignoreNextEnd = 30
        XCTAssertEqual(TimelinePlaybackPresentation(transport: sample, elapsed: 0.05, songDuration: 100,
                                                    mainBoundary: 20).mainPosition, 20.04, accuracy: 1e-12)
    }

    func testSongEndDoesNotInventStopOrPromotion() {
        let sample = transport(main: 99.99, sub: 99.98, subPlaying: true)
        let end = TimelinePlaybackPresentation(transport: sample, elapsed: 0.05, songDuration: 100)
        XCTAssertEqual(end.mainPosition, 100)
        XCTAssertEqual(end.subPosition, 100)
        XCTAssertEqual(end.followSource, .sub)
        XCTAssertTrue(sample.playing)
        XCTAssertTrue(sample.subPlay.playing)
    }

    func testStalledAndInvalidClocksNeverRunAwayOrReverse() {
        let sample = transport()
        let stalled = TimelinePlaybackPresentation(transport: sample, elapsed: 60, songDuration: 100)
        XCTAssertEqual(stalled.mainPosition, 10 + TimelinePlaybackPresentation.maximumExtrapolation, accuracy: 1e-12)
        for elapsed in [-10.0, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(TimelinePlaybackPresentation(transport: sample, elapsed: elapsed, songDuration: 100).mainPosition, 10)
        }
        XCTAssertEqual(TimelinePlaybackPresentation(transport: sample, elapsed: 0.05, songDuration: 5).mainPosition, 10,
                       "A stale duration must not drag the authoritative cursor backwards.")
    }
    func testSongDisplaysSeparateNextAndQueueAndDoNotBorrowPreviousTempo() {
        var song = Project.demo().songs[0]
        let root = Part(id: UUID(), name: "Medley", startTime: 0, endTime: 30)
        let first = Part(id: UUID(), name: "First", startTime: 0, endTime: 10, parentRegionID: root.id)
        let next = Part(id: UUID(), name: "Next", startTime: 10, endTime: 30, parentRegionID: root.id)
        let queued = Part(id: UUID(), name: "Queued", startTime: 40, endTime: 50)
        song.parts = [root, first, next, queued]
        song.markers = [.init(id: UUID(), name: "", position: 0, color: 0, tempoBPM: 100),
                        .init(id: UUID(), name: "", position: 10, color: 0, tempoBPM: 125)]
        var state = transport(main: 5)
        state.regionId = root.id; state.queuedRegionId = queued.id
        let display = TransportSongDisplays(song: song, transport: state, focusedRegion: queued.id)
        XCTAssertEqual(display.current?.id, first.id)
        XCTAssertEqual(display.next?.id, next.id)
        XCTAssertEqual(display.queued?.id, queued.id)
        XCTAssertEqual(display.currentBPM, 100)
        XCTAssertEqual(display.nextBPM, 125)
        XCTAssertNil(display.queuedBPM, "no inherited tempo from another song")
        state.playing = false
        let selected = TransportSongDisplays(song: song, transport: state, focusedRegion: queued.id)
        XCTAssertEqual(selected.current?.id, queued.id)
        XCTAssertNil(selected.currentBPM)
    }
}
