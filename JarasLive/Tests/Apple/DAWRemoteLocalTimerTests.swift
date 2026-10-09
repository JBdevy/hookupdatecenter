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
app.setActivationPolicy(.regular); app.finishLaunching()
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
func editableFields(_ view: NSView) -> [NSTextField] {
    if let field = view as? NSTextField, field.isEditable { return [field] }
    return view.subviews.flatMap(editableFields)
}
func nativeButtons(_ view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(nativeButtons)
}
func press(_ title: String, in object: Any) {
    if let sheet = object as? NSWindow, let content = sheet.contentView,
       let button = nativeButtons(content).first(where: { $0.title == title }) {
        let parent = sheet.sheetParent
        button.performClick(nil)
        for _ in 0..<25 { settle(); if parent?.attachedSheet == nil { break } }
        return
    }
    guard let view = object as? NSView, let window = view.window else { fatalError("Missing button container") }
    let compact = title == "Start timer" || title == "Stop timer"
    let local = NSPoint(x: compact ? view.bounds.maxX - 17 : view.bounds.midX,
                        y: compact ? view.bounds.midY : view.isFlipped ? view.bounds.maxY - 33 : view.bounds.minY + 33)
    let point = view.convert(local, to: nil)
    func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    NSApp.postEvent(event(.leftMouseUp), atStart: false)
    window.sendEvent(event(.leftMouseDown))
    if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) { window.sendEvent(up) }
    settle()
}
for compact in [false, true] {
    let uiTimer = RemoteLocalTimer(now: { uptime })
    uiTimer.synchronize(.init(revision: UUID(), targetSeconds: 90, running: false, remainingSeconds: 0))
    var commands: [(DAWRemoteCommand.Action, Double, UUID)] = []
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: compact ? 60 : 260), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: RemoteNativeTimerView(timer: uiTimer, send: { commands.append(($0, $1, $2)) }, close: {}, compact: compact))
    window.contentView = host; window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    host.layoutSubtreeIfNeeded(); window.setContentSize(host.fittingSize); settle()
    precondition(editableFields(host).count == 3, "each remote timer has three editable duration fields")
    precondition(host.fittingSize.width <= 310, "timer remains a compact floating control")
    let startLabel = compact ? "Start timer" : "Start", stopLabel = compact ? "Stop timer" : "Stop"
    press(startLabel, in: host)
    precondition(uiTimer.running && commands.count == 1 && commands[0].0 == .timerStart && window.attachedSheet == nil,
                 "remote Start changes local state and sends immediately without a dialog")
    let pendingRun = uiTimer.runID
    press(stopLabel, in: host)
    precondition(uiTimer.running && commands.count == 1 && uiTimer.runID == pendingRun,
                 "opening Stop confirmation neither stops locally nor sends a remote command")
    guard let cancelAlert = window.attachedSheet else { fatalError("remote Stop must show confirmation") }
    uptime += 1
    precondition(uiTimer.displayText() == "00:01:29", "timer continues counting while confirmation is visible")
    press("Cancel", in: cancelAlert)
    precondition(uiTimer.running && commands.count == 1 && uiTimer.runID == pendingRun, "Cancel keeps timer running and sends nothing")
    press(stopLabel, in: host)
    guard let stopAlert = window.attachedSheet else { fatalError("remote Stop confirmation can reopen") }
    press("Stop timer", in: stopAlert)
    precondition(!uiTimer.running && uiTimer.displayText() == "00:00:00" && uiTimer.targetText == "00:01:30" &&
                 commands.count == 2 && commands[1].0 == .timerStop,
                 "confirmed Stop performs the existing local reset and sends exactly one timerStop")
    press(startLabel, in: host)
    let staleRun = uiTimer.runID
    press(stopLabel, in: host)
    uiTimer.resetSynchronization()
    uiTimer.synchronize(.init(revision: UUID(), targetSeconds: 90, running: true, remainingSeconds: 89))
    settle()
    precondition(uiTimer.running && uiTimer.runID != staleRun && uiTimer.stop(ifRunID: staleRun) == nil && commands.count == 3,
                 "an observed host restart invalidates pending confirmation without stopping or sending")
    window.close()
}
withExtendedLifetime(observation) {}
print("REMOTE_LOCAL_TIMER_SYNC_COMPACT_FLOATING_START_STOP_CONFIRM_CANCEL_STALE_RUN_OK")
