import XCTest
@testable import JarasApplication

final class SMK37IntegrationTests: XCTestCase {
    func testPlayingAndQueuedSongTitlesAreAtomicBoundedAndClearable() throws {
        let packet = try XCTUnwrap(SMK37Protocol.decode(SMK37Protocol.songTitles(playing: "Body Splash", queued: "Next song")))
        XCTAssertEqual(packet.command, 0x1a)
        XCTAssertEqual(packet.payload[0], 11)
        XCTAssertEqual(String(bytes: packet.payload[1..<12], encoding: .ascii), "Body Splash")
        XCTAssertEqual(packet.payload[12], 9)
        XCTAssertEqual(String(bytes: packet.payload[13...], encoding: .ascii), "Next song")
        let long = try XCTUnwrap(SMK37Protocol.decode(SMK37Protocol.songTitles(playing: String(repeating: "A", count: 100), queued: String(repeating: "B", count: 100))))
        XCTAssertEqual(long.payload.count, 74)
        XCTAssertEqual(long.payload[0], 36); XCTAssertEqual(long.payload[37], 36)
        XCTAssertLessThanOrEqual(long.payload.count + 9, 96)
        XCTAssertEqual(SMK37Protocol.decode(SMK37Protocol.songTitles(playing: "", queued: ""))?.payload, [0,0])
    }

    func testPlaylistHeaderIsPersistentBoundedAndChecksummed() throws {
        let all = try XCTUnwrap(SMK37Protocol.decode(SMK37Protocol.playlist("All regions")))
        XCTAssertEqual(all.command, 0x19)
        XCTAssertEqual(String(bytes: all.payload, encoding: .ascii), "All regions")
        let long = try XCTUnwrap(SMK37Protocol.decode(SMK37Protocol.playlist(String(repeating: "A", count: 60))))
        XCTAssertEqual(long.payload.count, 36)
        XCTAssertEqual(Array(long.payload.suffix(3)), [46,46,46])
    }

    func testCenteredNavigationEdgesAndRepeatedNames() {
        XCTAssertEqual(SMK37Protocol.window(["Intro", "Song", "Song", "Final"], selected: 2), ["Intro", "Song", "Song", "Final", ""])
        XCTAssertEqual(SMK37Protocol.window(["A", "B", "C"], selected: 0), ["", "", "A", "B", "C"])
        XCTAssertEqual(SMK37Protocol.window(["A"], selected: 0), ["", "", "A", "", ""])
        let long = SMK37Protocol.navigation(kind: 3, rows: Array(repeating: String(repeating: "ã", count: 100), count: 5))
        XCTAssertEqual(long.count, 95)
        let packet = SMK37Protocol.decode(long)!
        XCTAssertEqual(packet.command, 0x17)
        var offset = 1
        for i in 0..<5 {
            let length = Int(packet.payload[offset]); offset += 1
            XCTAssertEqual(length, i == 2 ? 24 : 14)
            XCTAssertEqual(Array(packet.payload[(offset + length - 3)..<(offset + length)]), [46,46,46])
            offset += length
        }
        XCTAssertEqual(offset, packet.payload.count)
        XCTAssertTrue(SMK37Protocol.navigation(kind: 4, rows: Array(repeating: "", count: 5)).isEmpty)
    }
    func testPlaybackIsRelativeClampedAndSupportsLongProjects() {
        let middle = SMK37Protocol.decode(SMK37Protocol.playback(position: 130, start: 100, end: 160))!
        XCTAssertEqual(middle.command, 0x18)
        XCTAssertEqual(middle.payload, [100,0,30,0,0,60,0,0])
        XCTAssertEqual(SMK37Protocol.decode(SMK37Protocol.playback(position: 99, start: 100, end: 160))?.payload.prefix(5), [0,0,0,0,0])
        let end = SMK37Protocol.decode(SMK37Protocol.playback(position: 200, start: 100, end: 160))!.payload
        XCTAssertEqual(end, [72,1,60,0,0,60,0,0])
        let long = SMK37Protocol.decode(SMK37Protocol.playback(position: 162000, start: 0, end: 162000))!.payload
        XCTAssertEqual(Int(long[5]) | Int(long[6]) << 7 | Int(long[7]) << 14, 162000)
        XCTAssertEqual(SMK37Protocol.decode(SMK37Protocol.playback(position: .nan, start: 0, end: 1))?.payload, Array(repeating: 0, count: 8))
    }

    func testWireBoundsChecksumAndLongNames() {
        let packet = SMK37Protocol.pad(15, preset: 5, name: "Flauta e metais – refrão", rgb: 0xf108bc)
        let parsed = SMK37Protocol.decode(packet)
        XCTAssertEqual(parsed?.command, 0x11)
        XCTAssertEqual(Array(parsed!.payload.prefix(8)), [5,15,15,1,0,8,11,12])
        XCTAssertTrue(String(bytes: parsed!.payload.dropFirst(8), encoding: .ascii)!.contains("refrao"))
        var corrupt = packet; corrupt[10] ^= 1; XCTAssertNil(SMK37Protocol.decode(corrupt))
        XCTAssertNil(SMK37Protocol.decode(Array(packet.dropLast())))
        XCTAssertEqual(SMK37Protocol.text(String(repeating: "A", count: 100)).count, 64)
        XCTAssertEqual(SMK37Protocol.pad(16, preset: 0, name: "Bad", rgb: 0), [])
    }
    func testAutomaticHandshakeAndGateOwnership() {
        var session = SMK37Session()
        XCTAssertFalse(session.claims(status: 0xb0, number: 102))
        XCTAssertEqual(session.receive(SMK37Protocol.encode(0x41, [0,0,0]), at: 0), [.connected])
        let first = session.midi(status: 0xb0, number: 104, value: 127)
        guard case let .padDown(token, preset, pad) = first.first else { return XCTFail("pad press") }
        XCTAssertEqual(preset, 0); XCTAssertEqual(pad, 2)
        XCTAssertEqual(session.midi(status: 0xb0, number: 104, value: 127), [])
        XCTAssertEqual(session.receive(SMK37Protocol.encode(0x20, [4,12]), at: 1), [.preset(4)])
        XCTAssertEqual(session.midi(status: 0xb0, number: 104, value: 0), [.padUp(token: token)])
        _ = session.midi(status: 0xbc, number: 102, value: 127)
        XCTAssertEqual(session.expire(at: 3).count, 1)
        XCTAssertFalse(session.claims(status: 0xbc, number: 102))
    }
    func testDAWPositionsPreviewKnobAndPressEdges() {
        var session = SMK37Session()
        _ = session.receive(SMK37Protocol.encode(0x41,[0,0,1]), at: 0)
        XCTAssertEqual(session.midi(status: 0xb0,number: 102,value: 127), [.action(.record)])
        XCTAssertEqual(session.midi(status: 0xb0,number: 104,value: 127), [.action(.preview)])
        XCTAssertEqual(session.midi(status: 0xb0,number: 110,value: 127), [.action(.playStop)])
        XCTAssertEqual(session.midi(status: 0xb0,number: 110,value: 127), [])
        XCTAssertEqual(session.midi(status: 0xb0,number: 110,value: 0), [])
        XCTAssertEqual(session.midi(status: 0xb0,number: 110,value: 127), [.action(.playStop)])
        XCTAssertEqual(session.midi(status: 0xb0,number: 107,value: 127), [.action(.queuedParts(-1))])
        XCTAssertEqual(session.midi(status: 0xb0,number: 108,value: 127), [.action(.queuedParts(1))])
        XCTAssertEqual(session.midi(status: 0xb0,number: 105,value: 127), [.action(.scrollTracks(-1))])
        XCTAssertEqual(session.midi(status: 0xb0,number: 106,value: 127), [.action(.scrollTracks(1))])
        XCTAssertEqual(session.receive(SMK37Protocol.encode(0x23,[65]), at: 1), [.action(.previewPage(1))])
        XCTAssertEqual(session.receive(SMK37Protocol.encode(0x23,[63]), at: 1), [.action(.previewPage(-1))])
        XCTAssertEqual(SMK37Action.pad(1), nil)
    }
    func testOneBlueSelectionAndSinglePanelTabRouting() {
        let markers = [UUID(), UUID(), UUID()]
        var navigation = SMK37Navigation()
        XCTAssertEqual(navigation.move(queued: false, direction: 1, leftOpen: true, setlistOpen: true, markers: markers), markers[0])
        XCTAssertEqual(navigation.focus, .parts(panel: .setlist, queued: false, marker: markers[0]))
        _ = navigation.move(queued: true, direction: 1, leftOpen: true, setlistOpen: true, markers: markers)
        XCTAssertEqual(navigation.focus, .parts(panel: .left, queued: true, marker: markers[0]))
        _ = navigation.move(queued: true, direction: 1, leftOpen: false, setlistOpen: true, markers: markers)
        XCTAssertEqual(navigation.focus, .parts(panel: .setlist, queued: true, marker: markers[1]))
        _ = navigation.move(queued: false, direction: 1, leftOpen: true, setlistOpen: false, markers: markers)
        XCTAssertEqual(navigation.focus, .parts(panel: .left, queued: false, marker: markers[0]))
        navigation.selectSongs(); XCTAssertEqual(navigation.focus, .songs)
        XCTAssertNil(navigation.move(queued: true, direction: 1, leftOpen: false, setlistOpen: false, markers: markers))
        XCTAssertEqual(navigation.focus, .songs)
    }
    func testFragmentedSysexRealtimeAndRunningStatus() {
        var stream = SMK37Stream()
        let frame = SMK37Protocol.encode(0x41, [2, 5, 1])
        XCTAssertEqual(stream.feed(Array(frame.prefix(4))), [])
        XCTAssertEqual(stream.feed([0xf8] + Array(frame.dropFirst(4)) + [0xb0, 110, 127, 0xf8, 110, 0]),
                       [.sysex(frame), .short(0xb0, 110, 127), .short(0xb0, 110, 0)])
        XCTAssertEqual(stream.feed([0xf0] + Array(repeating: 1, count: 120) + [0xf7]), [])
        XCTAssertEqual(stream.feed(frame), [.sysex(frame)])
    }
    func testHostPresetChangePreservesHeldOwnership() {
        var session = SMK37Session()
        _ = session.receive(SMK37Protocol.encode(0x41, [0,0,0]), at: 0)
        guard case let .padDown(token, _, _) = session.midi(status: 0xb0, number: 102, value: 127).first else { return XCTFail() }
        session.selectHostPreset(5)
        guard case let .padDown(_, preset, _) = session.midi(status: 0xb0, number: 103, value: 127).first else { return XCTFail() }
        XCTAssertEqual(preset, 5)
        XCTAssertEqual(session.midi(status: 0xb0, number: 102, value: 0), [.padUp(token: token)])
    }

    func testFreeModeLeavesAllCCsToNormalMappings() {
        var session = SMK37Session()
        _ = session.receive(SMK37Protocol.encode(0x41, [0,0,0]), at: 0)
        guard case let .padDown(token, _, _) = session.midi(status: 0xb0, number: 102, value: 127).first else { return XCTFail() }
        XCTAssertEqual(session.receive(SMK37Protocol.encode(0x22, [2,0,0]), at: 1), [.padUp(token: token)])
        for cc in 0..<128 {
            XCTAssertFalse(session.claims(status: 0xb0, number: UInt8(cc)))
            XCTAssertEqual(session.midi(status: 0xb0, number: UInt8(cc), value: 127), [])
        }
        for command: UInt8 in [0x23, 0x24, 0x25] {
            XCTAssertEqual(session.receive(SMK37Protocol.encode(command, [1]), at: 1), [])
        }
        _ = session.receive(SMK37Protocol.encode(0x22, [1,0,0]), at: 1)
        XCTAssertEqual(session.receive(SMK37Protocol.encode(0x24, [65]), at: 1), [.action(.playlist(1))])
        XCTAssertEqual(session.receive(SMK37Protocol.encode(0x24, [63]), at: 1), [.action(.playlist(-1))])
        XCTAssertEqual(session.receive(SMK37Protocol.encode(0x25, [1]), at: 1), [.action(.fadeout(true))])
        XCTAssertEqual(session.receive(SMK37Protocol.encode(0x25, [0]), at: 1), [.action(.fadeout(false))])
        XCTAssertEqual(session.receive(SMK37Protocol.encode(0x25, [2]), at: 1), [])
        XCTAssertEqual(SMK37Protocol.decode(SMK37Protocol.transport(paused: true, recording: true, looping: true, auto: true, preview: true, playing: true, queued: true))?.payload, [127])
    }

    func testPadsFXFaderControlsOnlyBusAndNeverExceedsUnity() {
        var session = SMK37Session()
        XCTAssertFalse(session.claims(status: 0xb0, number: 23))
        _ = session.receive(SMK37Protocol.encode(0x41, [0,0,0]), at: 0)
        var previous = -1.0
        for value: UInt8 in 0...127 {
            XCTAssertEqual(session.midi(status: 0xbf, number: 23, value: value), [.action(.padBusVolume(value))])
            let gain = SMK37Protocol.padBusGain(value)
            XCTAssertGreaterThanOrEqual(gain, previous)
            XCTAssertLessThanOrEqual(gain, 1)
            previous = gain
        }
        XCTAssertEqual(SMK37Protocol.padBusGain(0), 0)
        XCTAssertEqual(SMK37Protocol.padBusGain(127), 1)
        for mode: UInt8 in [1,2] {
            _ = session.receive(SMK37Protocol.encode(0x22, [mode,0,0]), at: 1)
            XCTAssertFalse(session.claims(status: 0xb0, number: 23))
            XCTAssertEqual(session.midi(status: 0xb0, number: 23, value: 127), [])
        }
    }

    func testFadeoutWireAndVolumeLabels() {
        XCTAssertEqual(SMK37Protocol.padBusLabel(gain: 0), "VINHETAS FX -INF dB")
        XCTAssertEqual(SMK37Protocol.padBusLabel(gain: 1), "VINHETAS FX 0.0 dB")
        XCTAssertEqual(SMK37Protocol.padBusLabel(gain: 0.1), "VINHETAS FX -20.0 dB")
        XCTAssertEqual(SMK37Protocol.decode(SMK37Protocol.fadeout(active: true, remaining: 5, duration: 5))?.payload, [1,50,127])
        XCTAssertEqual(SMK37Protocol.decode(SMK37Protocol.fadeout(active: true, remaining: 2.5, duration: 5))?.payload, [1,25,64])
        XCTAssertEqual(SMK37Protocol.decode(SMK37Protocol.fadeout(active: true, remaining: 0, duration: 5))?.payload, [1,0,0])
        XCTAssertEqual(SMK37Protocol.decode(SMK37Protocol.fadeout(active: false, remaining: 3, duration: 5))?.payload, [0,0,0])
        XCTAssertEqual(SMK37Protocol.decode(SMK37Protocol.fadeout(active: true, remaining: .nan, duration: 5))?.payload, [0,0,0])
    }

    func testBluetoothFeedbackHasBoundedBurstsAndLeavesTimeForNotes() {
        var budget = SMK37FeedbackBudget()
        XCTAssertTrue(budget.allow(bytes: 95, at: 0))
        XCTAssertFalse(budget.allow(bytes: 95, at: 0))
        XCTAssertFalse(budget.allow(bytes: 10, at: 0.01))
        XCTAssertTrue(budget.allow(bytes: 10, at: 0.02))
        XCTAssertFalse(budget.allow(bytes: 97, at: 1))
        XCTAssertFalse(budget.allow(bytes: 0, at: 1))
        XCTAssertFalse(budget.allow(bytes: 10, at: .nan))
        XCTAssertFalse(budget.allow(bytes: 10, at: -1))
        var flood = SMK37FeedbackBudget(), total = 0, last = -Double.infinity
        for step in 0...2000 {
            let now = Double(step) / 1000
            if flood.allow(bytes: 80, at: now) {
                XCTAssertGreaterThanOrEqual(now - last, 0.02 - 1e-9)
                last = now; total += 80
            }
        }
        XCTAssertLessThanOrEqual(total, 96 + 2400)
        XCTAssertGreaterThan(total, 2000, "metadata must still make progress")
    }

}
