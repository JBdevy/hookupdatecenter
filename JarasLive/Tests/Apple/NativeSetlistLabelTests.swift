import SwiftUI
import AppKit
import Combine
struct Part: Equatable { var name: String; var color: UInt32?; var startTime: Double = 0; var displayName: String { name } }
struct TransportState { var position: Double = 0; var queueStartedAt: Double? }
struct ShowSnapshot { var transport: TransportState }
final class ShowController: ObservableObject {
    @Published var snapshot = ShowSnapshot(transport: TransportState())
}
extension View { func jarasHelp(_ text: String) -> some View { self } }

import SwiftUI
import AppKit
struct RowFixture: View {
 let native: Bool
 let count: Int
 var body: some View {
 VStack(spacing: 4) { ForEach(0..<count,id: \.self) { i in
  let part = Part(name: i == 0 ? "ABC DE DEUS" : i == 1 ? "ABERTURA GC 2026" : "UMA MÚSICA COM NOME BEM LONGO AQUI COM ACENTOS ÁÉÍÓÚ",color: 0x828282)
  Group {
  if native {
   RegionSetlistRow(region: part, number: i+1,selected: i % 5 == 1,active: i % 5 == 2,queued:i % 5 >= 3,prepareOnly: i%5 == 4,remaining:120+i,progress:0.65,queueProgress:0.35,expanded:i%2==0,toggleDrawer:{},select:{})
  } else {
   OriginalRegionSetlistRow(region: part, number: i+1,selected: i % 5 == 1,active: i % 5 == 2,queued:i % 5 >= 3,prepareOnly: i%5 == 4,remaining:120+i,progress:0.65,queueProgress:0.35,expanded:i%2==0,toggleDrawer:{},select:{})
  }
  }.foregroundStyle(.white)
 } }.padding(4).background(Color(hex:0x151b22))
 }
}
@MainActor func benchmarkLabels() throws {
 _=NSApplication.shared
 for count in [24,44] {
  for native in [false,true] {
   let host=NSHostingView(rootView:RowFixture(native:native,count:count))
   host.sizingOptions=[]
   let window=NSWindow(contentRect:CGRect(x:0,y:0,width:440,height:CGFloat(count*38+4)),styleMask:[],backing:.buffered,defer:false)
   window.isReleasedWhenClosed=false;window.contentView=host;host.layoutSubtreeIfNeeded()
   RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02));host.layoutSubtreeIfNeeded()
   let identities = descendants(NativeRegionSetlistLabelView.self,host).map(ObjectIdentifier.init)
   var times:[Double]=[]
   for index in 0..<35 {
    let t=ProcessInfo.processInfo.systemUptime
    host.setFrameSize(CGSize(width:440+CGFloat(index%24)*2,height:CGFloat(count*38+4)));host.layoutSubtreeIfNeeded()
    if index>=10 {times.append((ProcessInfo.processInfo.systemUptime-t)*1000)}
   }
   times.sort();print("NATIVE_SETLIST count=\(count) native=\(native) mean=\(times.reduce(0,+)/Double(times.count)) p95=\(times[Int(Double(times.count)*0.95)])")
   precondition(descendants(NativeRegionSetlistLabelView.self,host).map(ObjectIdentifier.init) == identities, "Resizing keeps the existing native row labels")
   window.close()
  }
 }
}


import SwiftUI
import AppKit
final class Actions { var selects=0; var drawers=0 }
func descendants<T: NSView>(_ type: T.Type,_ view: NSView) -> [T] { (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { descendants(type,$0) } }
@MainActor func testActions() throws {
 _=NSApplication.shared
 let actions=Actions()
 let row=RegionSetlistRow(region:Part(name:"FULL LONG REGION NAME THAT MUST REMAIN ACCESSIBLE",color:0),number:107,selected:true,active:false,queued:false,prepareOnly:false,remaining:145,progress:0,queueProgress:0,expanded:false,toggleDrawer:{actions.drawers+=1},select:{actions.selects+=1}).foregroundStyle(.white)
 // Match the real Setlist insets: the drawer must remain inside its viewport.
 let host=NSHostingView(rootView:row.padding(.leading, 8).padding(.trailing, 2))
 let window=NSWindow(contentRect:CGRect(x:300,y:300,width:340,height:34),styleMask:[.titled],backing:.buffered,defer:false)
 window.isReleasedWhenClosed=false;window.contentView=host;window.orderFront(nil)
 for _ in 0..<3 {host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))}
 let native=descendants(NativeRegionSetlistLabelView.self,host).first!
 precondition(native.accessibilityLabel() == "107, FULL LONG REGION NAME THAT MUST REMAIN ACCESSIBLE, 2m 25s")
 precondition(native.hitTest(CGPoint(x:60,y:15)) == nil, "Drawing must not capture the selection button")
 let labelFrame = native.convert(native.bounds, to: host)
 precondition(abs(labelFrame.maxX - (host.bounds.maxX - 16)) < 0.5, "Only the 14-point drawer and 2-point outer margin may remain to the right")
 func click(_ x: CGFloat) {
  let point=host.convert(CGPoint(x:x,y:17),to:nil)
  func event(_ type: NSEvent.EventType) -> NSEvent { NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)! }
  let up=event(.leftMouseUp)
  NSApp.postEvent(up,atStart:false)
  window.sendEvent(event(.leftMouseDown))
  if let posted=NSApp.nextEvent(matching:.leftMouseUp,until:Date(timeIntervalSinceNow:0.01),inMode:.default,dequeue:true) {window.sendEvent(posted)}
  RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04))
 }
 click(100);click(334)
 precondition(actions.selects == 1 && actions.drawers == 1, "Body selection and drawer actions stay separate")
 print("NATIVE_SETLIST_SELECTION_DRAWER_HIT_TEST_AND_ACCESSIBILITY_OK")
 window.close()
}



@MainActor func testVisualParity() throws {
 for width: CGFloat in [240,340,486] {
  var images:[NSBitmapImageRep]=[]
  for native in [false,true] {
   let host=NSHostingView(rootView:RowFixture(native:native,count:5))
   host.sizingOptions=[]
   let window=NSWindow(contentRect:CGRect(x:0,y:0,width:width,height:194),styleMask:[],backing:.buffered,defer:false)
   window.isReleasedWhenClosed=false;window.contentView=host
   host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02));host.layoutSubtreeIfNeeded()
   let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds)!
   host.cacheDisplay(in:host.bounds,to:bitmap);images.append(bitmap);window.close()
  }
  let old=images[0],new=images[1]
  precondition(old.pixelsWide == new.pixelsWide && old.pixelsHigh == new.pixelsHigh && old.bytesPerRow == new.bytesPerRow)
  let count=old.bytesPerRow*old.pixelsHigh
  let first=old.bitmapData!,second=new.bitmapData!
  var difference=0
  for index in 0..<count { difference += abs(Int(first[index])-Int(second[index])) }
  let mean=Double(difference)/Double(count)
  precondition(mean < 1.2,"Native text/gradient/outline/progress must match the original layout at narrow and wide widths")
  print("NATIVE_SETLIST_PIXEL_MEAN width=\(width) difference=\(mean)")
 }
}
@MainActor func testPlaybackUpdatesWithoutRebuildingRows() {
    let show = ShowController()
    let region = Part(name: "CURRENT", color: 0x44ff88, startTime: 30)
    let view = NativeRegionSetlistLabelView(frame: CGRect(x: 0, y: 0, width: 340, height: 34))
    view.configure(number: 1, name: region.name, duration: "30s", color: 0x44ff88,
        selected: false, active: true, queued: false, prepareOnly: false, progress: 0, queueProgress: 0)
    view.bindPlayback(SetlistPlaybackBinding(show: show, region: region, end: 60, playbackEnd: 60))
    func value<T>(_ name: String, _: T.Type) -> T { Mirror(reflecting: view).children.first { $0.label == name }!.value as! T }
    for sample in 1...30 { show.snapshot.transport.position = 30 + Double(sample) / 30 }
    precondition(abs(value("progress", Double.self) - 1.0 / 30) < 1e-9)
    precondition(value("durationText", String.self) == "29s")
    show.snapshot.transport.position = 45
    precondition(value("progress", Double.self) == 0.5)
    precondition(value("durationText", String.self) == "15s")
    show.snapshot.transport.position = 30 // Loop wraps reset the bar on the same sample.
    precondition(value("progress", Double.self) == 0)
    show.snapshot.transport.queueStartedAt = 30
    view.configure(number: 2, name: "QUEUED", duration: "30s", color: 0x44ff88,
        selected: false, active: false, queued: true, prepareOnly: false, progress: 0, queueProgress: 1)
    show.snapshot.transport.position = 45
    precondition(value("queueProgress", Double.self) == 0.5)
    view.bindPlayback(nil)
    show.snapshot.transport.position = 59
    precondition(value("queueProgress", Double.self) == 0.5, "Inactive rows must release their playback subscription")
    print("NATIVE_SETLIST_DIRECT_PROGRESS_COUNTDOWN_LOOP_WRAP_AND_UNSUBSCRIBE_OK")
}
@MainActor func testProgressLayersPreserveStaticDrawingAndTransitions() {
    _ = NSApplication.shared
    let show = ShowController()
    show.snapshot.transport.position = 100
    let region = Part(name: "CURRENT", color: 0x44ff88)
    let view = NativeRegionSetlistLabelView(frame: CGRect(x: 0, y: 0, width: 340, height: 34))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
    defer { window.close() }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    view.configure(number: 1, name: region.name, duration: regionDurationText(900), color: 0x44ff88,
        selected: false, active: true, queued: false, prepareOnly: false, progress: 0.1, queueProgress: 0)
    view.bindPlayback(SetlistPlaybackBinding(show: show, region: region, end: 1000, playbackEnd: 160))
    let clip = view.layer!.sublayers!.first { $0.name == "setlist-progress-clip" }!
    let bar = clip.sublayers!.first { $0.name == "setlist-progress-bar" }!
    let mask = clip.mask as! CAShapeLayer
    precondition(mask.path != nil && mask.frame == clip.bounds, "The progress strip retains the card's rounded clipping")
    precondition([clip, bar, mask].allSatisfy { $0.actions?["position"] is NSNull && $0.actions?["bounds"] is NSNull },
        "Playback layer changes must not animate or require an explicit transaction commit")
    func drawIfNeeded() { view.displayIfNeeded(); view.layer?.displayIfNeeded() }
    drawIfNeeded()
    var drawings = view.drawingCount
    precondition(drawings > 0)
    for sample in 1...29 {
        show.snapshot.transport.position = 100 + Double(sample) / 30
        precondition(abs(bar.frame.width - 340 * show.snapshot.transport.position / 1000) < 1e-9,
            "The retained bar advances at every authoritative transport sample")
        drawIfNeeded()
        precondition(view.drawingCount == drawings, "Fractional progress must reuse the static title, duration and gradient bitmap")
    }
    show.snapshot.transport.position = 101
    drawIfNeeded()
    precondition(view.drawingCount > drawings, "Crossing an integer countdown boundary redraws its new text")
    drawings = view.drawingCount
    show.snapshot.transport.position = 101.5
    drawIfNeeded()
    precondition(view.drawingCount == drawings, "A second progress sample within the same displayed countdown reuses its bitmap")
    show.snapshot.transport.position = 100
    drawIfNeeded()
    precondition(view.drawingCount > drawings && abs(bar.frame.width - 34) < 1e-9, "Loop wraps reset both the bar and countdown immediately")
    show.snapshot.transport.queueStartedAt = 100
    view.configure(number: 2, name: "QUEUED", duration: regionDurationText(1000), color: 0x44ff88,
        selected: false, active: false, queued: true, prepareOnly: false, progress: 0, queueProgress: 1)
    drawIfNeeded(); drawings = view.drawingCount
    show.snapshot.transport.position = 130
    drawIfNeeded()
    precondition(view.drawingCount == drawings && abs(bar.frame.width - 170) < 1e-9,
        "Queued progress updates independently of its unchanged full-duration label")
    precondition(bar.backgroundColor == NSColor(JarasTheme.yellow).cgColor)
    view.setFrameSize(CGSize(width: 460, height: 34))
    drawIfNeeded()
    precondition(view.drawingCount > drawings && abs(bar.frame.width - 230) < 1e-9,
        "Resizing updates both the cached label and retained progress geometry")
    precondition(mask.frame == clip.bounds)
    view.layer = CALayer()
    drawIfNeeded(); drawings = view.drawingCount
    show.snapshot.transport.position = 131
    drawIfNeeded()
    precondition(clip.superlayer === view.layer && view.drawingCount == drawings,
        "A replaced AppKit backing layer reattaches the retained progress without reformatting text")
    view.configure(number: 2, name: "QUEUED", duration: regionDurationText(1000), color: 0x44ff88,
        selected: false, active: true, queued: false, prepareOnly: false, progress: 0.131, queueProgress: 0)
    precondition(bar.backgroundColor == NSColor(JarasTheme.green).cgColor,
        "Promotion to current playback changes the strip from queued yellow to playing green")
    view.configure(number: 2, name: "QUEUED", duration: regionDurationText(1000), color: 0x44ff88,
        selected: true, active: false, queued: false, prepareOnly: false, progress: 0, queueProgress: 0)
    view.bindPlayback(nil)
    drawIfNeeded(); drawings = view.drawingCount
    show.snapshot.transport.position = 140
    drawIfNeeded()
    precondition(clip.isHidden && view.drawingCount == drawings, "Inactive selected rows hide the strip and release playback updates")
    print("NATIVE_SETLIST_RETAINED_PROGRESS_NO_STATIC_REDRAW_COUNTDOWN_QUEUE_LOOP_RESIZE_BACKING_AND_PROMOTION_OK")
}
MainActor.assumeIsolated {
 testFocusPreservesManualDrawerState()
 testLiveMarkKeepsCachedTextAndPlaybackFeedback()
 testSetlistFooterActionsAndCollapse()
 testProgressLayersPreserveStaticDrawingAndTransitions()
 testPlaybackUpdatesWithoutRebuildingRows()
 try! testVisualParity()
 try! testActions()
 try! benchmarkLabels()
}

@MainActor func testLiveMarkKeepsCachedTextAndPlaybackFeedback() {
    _ = NSApplication.shared
    let view = NativeRegionSetlistLabelView(frame: CGRect(x: 0, y: 0, width: 340, height: 34))
    let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
    defer { window.close() }
    func configure(played: Bool, selected: Bool = false, active: Bool = false, queued: Bool = false) {
        view.configure(number: 1, name: "PLAYED SONG", duration: "30s", color: 0x44ff88,
            selected: selected, active: active, queued: queued, prepareOnly: false,
            progress: 0.5, queueProgress: 0.25, playedLive: played)
        view.displayIfNeeded(); view.layer?.displayIfNeeded()
    }
    func field<T>(_ name: String, _: T.Type) -> T { Mirror(reflecting: view).children.first { $0.label == name }!.value as! T }
    func backgroundColor() -> NSColor {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 5)!.usingColorSpace(.deviceRGB)!
    }
    configure(played: false)
    let shaped = field("nameLine", CTLine.self)
    let idle = backgroundColor()
    configure(played: true)
    precondition(field("playedLive", Bool.self))
    precondition(shaped === field("nameLine", CTLine.self), "A played mark must reuse the existing shaped name")
    let played = backgroundColor()
    precondition(played.redComponent > played.blueComponent + 0.1 && played.redComponent > played.greenComponent + 0.1
        && abs(played.blueComponent - played.greenComponent) < 0.03 && played.redComponent > idle.redComponent + 0.03,
        "An idle played row changes from its neutral background to dark red, across display color profiles")
    configure(played: true, selected: true)
    let selected = backgroundColor()
    precondition(selected.blueComponent > selected.redComponent, "Selection remains visible for a played row")
    configure(played: true, active: true)
    let clip = view.layer!.sublayers!.first { $0.name == "setlist-progress-clip" }!
    let bar = clip.sublayers!.first { $0.name == "setlist-progress-bar" }!
    precondition(!clip.isHidden && bar.backgroundColor == NSColor(JarasTheme.green).cgColor && abs(bar.frame.width - 170) < 0.01)
    configure(played: true, queued: true)
    precondition(!clip.isHidden && bar.backgroundColor == NSColor(JarasTheme.yellow).cgColor && abs(bar.frame.width - 85) < 0.01)
    precondition(shaped === field("nameLine", CTLine.self), "Playback and live state changes do not rebuild text")
    print("SETLIST_LIVE_DARK_RED_AND_CACHED_NAME_PRESERVE_SELECTION_QUEUE_AND_PROGRESS_OK")
}

private func testFocusPreservesManualDrawerState() {
    let parent = UUID(), child = UUID(), normal = UUID()
    var expanded: Set<UUID> = []
    for _ in 0..<3 {
        precondition(setlistVisibleRegionID(child, parent: parent, expanded: expanded) == parent,
            "Repeated playback/selection focus must target the visible parent while the drawer is closed")
        precondition(expanded.isEmpty)
    }
    expanded.insert(parent)
    precondition(setlistVisibleRegionID(child, parent: parent, expanded: expanded) == child,
        "Manual expansion or an explicit search result may reveal the child")
    expanded.remove(parent)
    precondition(setlistVisibleRegionID(child, parent: parent, expanded: expanded) == parent,
        "Closing a playing child's drawer must move its visible highlight back to the parent")
    precondition(setlistVisibleRegionID(normal, parent: nil, expanded: expanded) == normal)
    precondition(setlistVisibleRegionID(parent, parent: nil, expanded: expanded) == parent)
    print("SETLIST_FOCUS_PRESERVES_MANUAL_DRAWER_AND_HIGHLIGHTS_VISIBLE_PARENT_OK")
}

private final class FooterTestState: ObservableObject {
    @Published var projectID = UUID()
    @Published var bypassed = false
    @Published var live = false
    @Published var parts = false
    var calls = [0, 0, 0]
}
private final class FooterFrameView: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
private struct FooterFrameProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> FooterFrameView { FooterFrameView() }
    func updateNSView(_ view: FooterFrameView, context: Context) {}
}
private struct SetlistFooterFixture: View {
    @ObservedObject var state: FooterTestState
    var body: some View {
        VStack(spacing: 0) {
            Text("Songs").frame(maxWidth: .infinity, maxHeight: .infinity)
            SetlistFooterControls(projectID: state.projectID, bypassed: state.bypassed, liveEnabled: state.live, partsOpen: state.parts,
                toggleBypass: { state.calls[0] += 1; state.bypassed.toggle() },
                toggleLive: { state.calls[1] += 1; state.live.toggle() },
                toggleParts: { state.calls[2] += 1; state.parts.toggle() })
                .background(FooterFrameProbe())
        }
    }
}
@MainActor func testSetlistFooterActionsAndCollapse() {
    let name = "catlive.footer.test." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let state = FooterTestState()
    let host = NSHostingView(rootView: SetlistFooterFixture(state: state).defaultAppStorage(defaults))
    host.sizingOptions = []
    let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 305, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
    defer { window.close() }
    func pump() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04)); host.layoutSubtreeIfNeeded() }
    func frame() -> CGRect { let probe = descendants(FooterFrameView.self, host).first!; return probe.convert(probe.bounds, to: host) }
    func click(x: CGFloat) {
        let point = host.convert(CGPoint(x: x, y: frame().midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent { NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)! }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) { window.sendEvent(up) }
        pump()
    }
    pump()
    precondition(abs(frame().height - 28) < 0.5)
    precondition(abs((host.isFlipped ? frame().maxY - host.bounds.maxY : frame().minY - host.bounds.minY)) < 0.5,
        "The compact footer ends at the bottom of its setlist without reserved empty space")
    let expectedFrame = frame()
    click(x: 48); click(x: 148); click(x: 240)
    precondition(state.calls == [1, 1, 1] && state.bypassed && state.live && state.parts, "All three compact footer controls remain independently clickable")
    precondition(window.attachedSheet == nil, "Enabling Live acts immediately without a confirmation")
    precondition(frame() == expectedFrame, "Blinking ByPass cannot resize the footer or the song list")
    click(x: 296)
    precondition(abs(frame().height - 16) < 0.5 && defaults.object(forKey: "catlive.setlist.footerVisible") as? Bool == false,
        "The chevron collapses only the footer controls and keeps its handle reachable")
    click(x: 296)
    precondition(abs(frame().height - 28) < 0.5 && state.calls == [1, 1, 1])

    func liveConfirmation() -> NSWindow {
        for _ in 0..<25 {
            if let sheet = window.attachedSheet { return sheet }
            pump()
        }
        preconditionFailure("Turning Live off must present a confirmation sheet")
    }
    func pressAlertButton(_ title: String, in sheet: NSWindow) {
        guard let content = sheet.contentView,
              let button = descendants(NSButton.self, content).first(where: { $0.title == title }) else {
            preconditionFailure("The Live confirmation must offer the \(title) action")
        }
        button.performClick(nil)
    }
    func awaitDismissal() {
        for _ in 0..<25 {
            pump()
            if window.attachedSheet == nil { return }
        }
        preconditionFailure("The Live confirmation must dismiss after its action or a stale request")
    }

    click(x: 148)
    let cancelledSheet = liveConfirmation()
    precondition(state.live && state.calls[1] == 1, "Opening the confirmation cannot clear Live or played-song marks")
    let warning = descendants(NSTextField.self, cancelledSheet.contentView!).map(\.stringValue).joined(separator: " ")
    precondition(warning.contains("played-song marks") && warning.contains("unified regions") && warning.contains("from zero"),
        "The confirmation explains that disabling clears every played mark and restarting resets playback counting")
    pressAlertButton("Cancel", in: cancelledSheet); awaitDismissal()
    precondition(state.live && state.calls[1] == 1, "Cancel must leave Live and its playback history untouched")

    click(x: 148)
    pressAlertButton("Turn off Live", in: liveConfirmation()); awaitDismissal()
    precondition(!state.live && state.calls[1] == 2, "Confirmation executes the Live reset exactly once")

    click(x: 148)
    precondition(state.live && state.calls[1] == 3 && window.attachedSheet == nil)
    click(x: 148)
    _ = liveConfirmation()
    state.projectID = UUID(); awaitDismissal()
    precondition(state.live && state.calls[1] == 3, "Changing projects dismisses a stale confirmation without toggling the new project")

    click(x: 148)
    _ = liveConfirmation()
    state.live = false; awaitDismissal()
    precondition(!state.live && state.calls[1] == 3, "A remote Live-off update dismisses the dialog without dispatching a second reset")
    precondition(frame() == expectedFrame, "Opening and dismissing Live confirmation keeps the footer geometry stable")
    print("SETLIST_LIVE_REAL_CONFIRMATION_CANCEL_CONFIRM_PROJECT_CHANGE_AND_REMOTE_OFF_OK")

    window.setContentSize(CGSize(width: 486, height: 150)); pump()
    precondition(abs(frame().width - 486) < 0.5 && abs(frame().height - 28) < 0.5)
    click(x: 477)
    precondition(abs(frame().height - 16) < 0.5, "The chevron stays in the trailing gutter after resizing")
    print("SETLIST_FOOTER_THREE_ACTIONS_BLINK_GEOMETRY_AND_COLLAPSE_REOPEN_RESIZE_OK")
}
