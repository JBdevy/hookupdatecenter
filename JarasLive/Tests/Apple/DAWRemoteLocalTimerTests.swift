// Runs against the production RemoteLocalTimer and timer views extracted from DAWRemoteView.swift.
var uptime = 100.0
let timer = RemoteLocalTimer(now: { uptime })
var publications = 0
let observation = timer.objectWillChange.sink { publications += 1 }
var snapshot = DAWRemoteTimerState(revision: UUID(), targetSeconds: 300, running: true, remainingSeconds: 120)
timer.synchronize(snapshot)
precondition(timer.running && timer.targetSeconds == 300 && timer.displayText() == "00:02:00")
let firstPublicationCount = publications
uptime += 15
precondition(timer.displayText() == "00:01:45", "countdown advances with no bridge snapshots")
for index in 0..<1000 {
    snapshot.remainingSeconds = Double(index)
    timer.synchronize(snapshot)
}
precondition(timer.displayText() == "00:01:45" && publications == firstPublicationCount,
             "same revision bridge frames cannot reset the countdown or publish local state changes")
uptime += 106
precondition(timer.displayText() == "−00:00:01" && timer.expired(), "local countdown continues below zero without host frames")
let bright = timer.displayOpacity()
uptime += 0.5
precondition(timer.displayOpacity() != bright, "local expired readout blinks without bridge ticks")

snapshot = .init(revision: UUID(), targetSeconds: 300, running: true, remainingSeconds: 80)
timer.synchronize(snapshot)
precondition(timer.displayText() == "00:01:20", "a new host start/configuration anchors its current remaining duration")
uptime += 6
precondition(timer.displayText() == "00:01:14")
snapshot = .init(revision: UUID(), targetSeconds: 300, running: false, remainingSeconds: 0)
timer.synchronize(snapshot)
precondition(!timer.running && timer.displayText() == "00:00:00" && timer.targetText == "00:05:00")
let startID = timer.start(seconds: 90)!
uptime += 0.2
timer.synchronize(snapshot)
precondition(timer.running && timer.displayText() == "00:01:30", "an old host frame cannot undo the pending local start")
snapshot = .init(revision: UUID(), targetSeconds: 90, running: true, remainingSeconds: 84.8, commandID: startID)
timer.synchronize(snapshot)
precondition(timer.displayText() == "00:01:25", "the authoritative start echo corrects latency once")
let stopID = timer.stop()!
timer.synchronize(snapshot)
precondition(!timer.running && timer.displayText() == "00:00:00" && timer.targetText == "00:01:30",
             "an old running frame cannot undo the pending local stop")
snapshot = .init(revision: UUID(), targetSeconds: 90, running: false, remainingSeconds: 0, commandID: stopID)
timer.synchronize(snapshot)

let earlierStart = timer.start(seconds: 60)!
let latestStop = timer.stop()!
timer.synchronize(.init(revision: UUID(), targetSeconds: 60, running: true, remainingSeconds: 60, commandID: earlierStart))
precondition(!timer.running, "an earlier Start acknowledgement cannot undo a later local Stop")
timer.synchronize(.init(revision: UUID(), targetSeconds: 60, running: false, remainingSeconds: 0, commandID: latestStop))
let nextStart = timer.start(seconds: 30)!
timer.synchronize(.init(revision: UUID(), targetSeconds: 60, running: false, remainingSeconds: 0, commandID: latestStop))
precondition(timer.running && timer.targetSeconds == 30, "an earlier Stop acknowledgement cannot undo a later local Start")
timer.synchronize(.init(revision: UUID(), targetSeconds: 30, running: true, remainingSeconds: 29.8, commandID: nextStart))
timer.stop()
uptime += 3.1
timer.synchronize(.init(revision: UUID(), targetSeconds: 30, running: true, remainingSeconds: 26))
precondition(timer.running && timer.displayText() == "00:00:26", "a missing acknowledgement falls back to the authoritative host snapshot without lingering")
let rejectedID = timer.stop()!
timer.synchronize(.init(revision: UUID(), targetSeconds: 30, running: true, remainingSeconds: 25.8, commandID: rejectedID))
precondition(timer.running, "a rejection acknowledgement immediately restores the authoritative host timer")
timer.stop()
timer.resetSynchronization()
timer.synchronize(.init(revision: UUID(), targetSeconds: 90, running: false, remainingSeconds: 0))

let beforeInvalid = publications
timer.synchronize(.init(revision: UUID(), targetSeconds: 360000, running: true, remainingSeconds: 10))
timer.synchronize(.init(revision: UUID(), targetSeconds: 5, running: true, remainingSeconds: .nan))
precondition(publications == beforeInvalid && !timer.running, "malformed snapshots never corrupt local time")
snapshot = .init(revision: UUID(), targetSeconds: 90, running: true, remainingSeconds: 70)
timer.synchronize(snapshot)
uptime += 4
snapshot.remainingSeconds = 50
timer.synchronize(snapshot)
precondition(timer.displayText() == "00:01:06")
timer.resetSynchronization()
timer.synchronize(snapshot)
precondition(timer.displayText() == "00:00:50", "reconnecting resamples the same host revision once")
timer.stop()
timer.start(seconds: .max)
precondition(timer.targetText == "99:59:59", "duration keeps the Mac input limits")
timer.stop()
let now = Date(timeIntervalSince1970: 1_700_000_000)
let firstClock = RemoteLocalTimer.localTime(at: now)
let nextClock = RemoteLocalTimer.localTime(at: now.addingTimeInterval(1))
precondition(firstClock.count == 8 && firstClock != nextClock, "wall-clock readout uses local Date independently of the countdown")

let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let host = NSHostingView(rootView: RemoteNativeTimerView(timer: timer, send: { _, _, _ in fatalError("test must not send bridge commands") }, close: {}))
window.contentView = host
window.orderFront(nil)
host.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
func editableFields(_ view: NSView) -> [NSTextField] {
    if let field = view as? NSTextField, field.isEditable { return [field] }
    return view.subviews.flatMap(editableFields)
}
precondition(editableFields(host).count == 3, "small floating timer has exactly three native editable duration fields")
precondition(host.fittingSize.width <= 310, "timer remains a compact floating control")
window.close()
withExtendedLifetime(observation) {}
print("REMOTE_LOCAL_TIMER_MONOTONIC_NO_TICK_BRIDGE_SYNC_RECONNECT_AND_COMPACT_INPUTS_OK")
