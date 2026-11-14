import Foundation

func equal(_ actual: Double, _ expected: Double, _ message: String) {
    precondition(abs(actual - expected) < 0.0000001, "\(message): \(actual), expected \(expected)")
}

var clock = AudioPresentationClock(position: 10, hostTime: 100)
clock.transition(position: 10, hostTime: 105, sampledAt: 104.9)
equal(clock.position(at: 104.99), 14.99, "An early transport wrap must finish the outgoing region")
equal(clock.position(at: 105), 10, "The output deadline must show the exact first marker")
equal(clock.position(at: 105.01), 10.01, "The new segment advances only after its deadline")
// The old presentation formula used only the newly promoted future anchor.
let priorFormula = 10 + (104.99 - 105)
precondition(priorFormula < 10 && abs(priorFormula - clock.position(at: 104.99)) > 4.9,
             "This fixture must reproduce both the early return and the pre-start position")

let initial = AudioPresentationClock(position: 20, hostTime: 200)
equal(initial.position(at: 199.8), 20, "First Play/seek must hold its target during preroll")
equal(initial.position(at: 200), 20, "First onset uses the requested target")
equal(initial.position(at: 200.2), 20.2, "First onset advances normally")

var shortLoops = AudioPresentationClock(position: 1, hostTime: 99)
shortLoops.transition(position: 2, hostTime: 100, sampledAt: 99.8)
shortLoops.transition(position: 3, hostTime: 100.02, sampledAt: 99.9)
shortLoops.transition(position: 4, hostTime: 100.04, sampledAt: 99.95)
equal(shortLoops.position(at: 99.99), 1.99, "Successive future promotions retain the audible segment")
equal(shortLoops.position(at: 100.01), 2.01, "First pending handoff remains reachable")
equal(shortLoops.position(at: 100.03), 3.01, "Second pending handoff remains reachable")
equal(shortLoops.position(at: 100.04), 4, "Third pending handoff begins at its deadline")
// A replacement invalidates only its superseded future, not the live segment.
shortLoops.transition(position: 7, hostTime: 100.03, sampledAt: 100.01)
equal(shortLoops.position(at: 100.025), 3.005, "Replacement preserves the earlier active clock")
equal(shortLoops.position(at: 100.05), 7.02, "Canceled future anchors cannot return later")

var subPlay = AudioPresentationClock(position: 30, hostTime: 300)
subPlay.transition(position: 40, hostTime: 301, sampledAt: 300.5)
var promoted = subPlay
equal(promoted.position(at: 300.9), 30.9, "SubPlay promotion retains its current audible position")
equal(promoted.position(at: 301), 40, "SubPlay promotion retains its future handoffs")
promoted = AudioPresentationClock(position: 90, hostTime: 400)
equal(promoted.position(at: 399), 90, "Seek/restart replaces all old presentation history")
equal(subPlay.position(at: 301), 40, "Independent heads do not share mutable history")

// Exercise bounded pruning under long running loops. Every assertion is
// checked against the complete mathematical sequence, including future ones.
var longRun = AudioPresentationClock(position: 0, hostTime: 0)
for index in 1...10000 {
    let boundary = Double(index) * 0.02
    longRun.transition(position: Double(index % 7), hostTime: boundary, sampledAt: boundary - 0.1)
    let sample = max(0, boundary - 0.075)
    let active = Int(floor((sample + 0.000000001) / 0.02))
    equal(longRun.position(at: sample), Double(active % 7) + sample - Double(active) * 0.02,
          "Long running loop history must preserve the sample epoch")
}
print("AUDIO_PRESENTATION_CLOCK_DEADLINE_FIRST_ONSET_SUCCESSIVE_HANDOFFS_RESET_AND_SUBPLAY_OK")
