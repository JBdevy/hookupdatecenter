import AppKit
import SwiftUI
@MainActor final class Recorder { var clicks: [String] = []; var draggedX: CGFloat = -1 }
struct Anchor: NSViewRepresentable {
 let name: String
 func makeNSView(context: Context) -> NSView { let v=NSView();v.identifier = NSUserInterfaceItemIdentifier(name);return v }
 func updateNSView(_ v: NSView, context: Context) {}
}
@MainActor final class ScaleState: ObservableObject { @Published var factor = 0.8 }
struct ScaledRoot<Content: View>: View {
 @ObservedObject var state: ScaleState
 let content: Content
 var body: some View { InterfaceScaleLayout(factor: CGFloat(InterfaceScale.factor(Double(state.factor))), content: content) }
}
// The workspace has a persistent hosting view inside a native deck. This is
// intentionally different from a SwiftUI-only fixture: scaling its ancestor
// can shrink drawing while leaving the nested host's click coordinates intact.
struct WorkspaceDeck: NSViewRepresentable {
 let record: Recorder
 final class Deck: NSView {
  override var isFlipped: Bool { true }
  override func layout() { super.layout(); for view in subviews { view.frame = bounds } }
 }
 func makeNSView(context: Context) -> Deck {
  let deck = Deck(), host = NSHostingView(rootView: Fixture(record: record))
  if #available(macOS 13, *) { host.sizingOptions = [] }
  if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
  deck.addSubview(host); return deck
 }
 func updateNSView(_ view: Deck, context: Context) { view.needsLayout = true }
}
struct Nested: NSViewRepresentable {
 let record: Recorder
 func makeNSView(context:Context)->NSView { NSHostingView(rootView:Button("Nested") {record.clicks.append("NESTED")}) }
 func updateNSView(_ v:NSView,context:Context) {}
}
struct Native: NSViewRepresentable {
 let record: Recorder
 @MainActor final class Target: NSObject { let record:Recorder; init(_ r:Recorder){record=r}; @objc func click(){record.clicks.append("NATIVE")} }
 func makeCoordinator()->Target {Target(record)}
 func makeNSView(context:Context)->NSView { let b=NSButton(title:"Native",target:context.coordinator,action:#selector(Target.click));return b }
 func updateNSView(_ v:NSView,context:Context) {}
}
struct DragSurface: NSViewRepresentable {
 let record: Recorder
 final class Surface: NSView {
  var record: Recorder?
  override func mouseDown(with event: NSEvent) { mouseDragged(with:event) }
  override func mouseDragged(with event: NSEvent) { record?.draggedX = convert(event.locationInWindow,from:nil).x / bounds.width }
 }
 func makeNSView(context:Context)->Surface {let view=Surface();view.record=record;return view}
 func updateNSView(_ view:Surface,context:Context) {}
}
struct Fixture: View {
 let record: Recorder
 var body: some View {
 VStack {
 HStack(spacing: 6) {
 ForEach(["PLAY", "TP-1", "TP-2", "RECADOS", "VIDEO"], id: \.self) { name in
 Button(name) { record.clicks.append(name) }
 .buttonStyle(TransportButtonStyle(color: .red, active: true, width: 72, height: 28, bordered: false))
 .background(Anchor(name:name))
 }
 }
 HStack { Button("Top Left") { record.clicks.append("TL") }.background(Anchor(name:"TL"));Spacer();Button("Top Right") { record.clicks.append("TR") }.background(Anchor(name:"TR")) }
 Spacer()
 Native(record:record).frame(width:100,height:30).background(Anchor(name:"NATIVE"))
 Nested(record:record).frame(width:100,height:30).background(Anchor(name:"NESTED"))
 DragSurface(record:record).frame(width:160,height:20).background(Color.green).background(Anchor(name:"DRAG"))
 Spacer()
 HStack { Button("Bottom Left") { record.clicks.append("BL") }.background(Anchor(name:"BL"));Spacer();Button("Bottom Right") { record.clicks.append("BR") }.background(Anchor(name:"BR")) }
 }.padding(30).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.gray).background(Anchor(name:"FILL"))
 }
}
@main struct Test {
 @MainActor static func main() {
 let app=NSApplication.shared;app.setActivationPolicy(.regular)
 let record=Recorder();let state=ScaleState();let host=NSHostingView(rootView:ScaledRoot(state:state,content:WorkspaceDeck(record:record)))
 let win=NSWindow(contentRect:NSRect(x:300,y:200,width:900,height:600),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
 win.contentView=host;win.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)

 func spin(_ secs:Double) { let end=Date().addingTimeInterval(secs);while Date() < end { if let e=app.nextEvent(matching:.any,until:Date().addingTimeInterval(0.01),inMode:.default,dequeue:true) { app.sendEvent(e) };RunLoop.main.run(until:Date().addingTimeInterval(0.001)) } }
 func find(_ v:NSView,_ name:String)->NSView? { if v.identifier?.rawValue == name{return v};return v.subviews.compactMap{find($0,name)}.first }
 spin(0.5)
 for saved in [0.75, 1.0, 1.25, 0.6, 1.5] {
 let scale=InterfaceScale.factor(saved)
 state.factor=saved;spin(0.4)
 let fill=find(host,"FILL")!;let occupied=fill.convert(fill.bounds,to:nil)
 precondition(abs(occupied.width-host.frame.width)<0.51 && abs(occupied.height-host.frame.height)<0.51, "Layout fills window at every scale")
 let native=find(host,"NATIVE")!
 precondition(abs(native.convertToBacking(native.bounds).width-100*scale*win.backingScaleFactor)<0.01, "Backing resolution follows UI scale")
 for name in ["PLAY","TP-1","TP-2","RECADOS","VIDEO","TL","TR","BL","BR","NATIVE","NESTED"] {
 let v=find(host,name)!;let rect=v.convert(v.bounds,to:nil);let screen=win.convertToScreen(rect);let point=CGPoint(x:screen.midX,y:NSScreen.main!.frame.height-screen.midY)
 for type in [CGEventType.leftMouseDown,.leftMouseUp] {CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap);spin(0.08)}
 spin(0.04)
 precondition(record.clicks.last == name, "Physical click reaches \(name) at \(scale)")
 record.clicks.removeAll()
 precondition(abs(host.bounds.width-win.contentView!.frame.width)<0.01, "Window coordinates remain unscaled")
 }
 let drag=find(host,"DRAG")!
 let dr=win.convertToScreen(drag.convert(drag.bounds,to:nil))
 for step in 0...10 {
  let point=CGPoint(x:dr.minX+dr.width*(0.2+0.06*Double(step)),y:NSScreen.main!.frame.height-dr.midY)
  let type:CGEventType = step == 0 ? .leftMouseDown : step == 10 ? .leftMouseUp : .leftMouseDragged
  CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap);spin(0.02)
 }
 precondition(abs(record.draggedX-0.74)<0.02, "Native drags use logical positions after scaling")
 }
 let suite="CatLive.PanelScale.\(UUID())"
 let prefs=UserDefaults(suiteName:suite)!
 precondition(InterfaceScale.percentages == [100])
 for saved in [0.6, 0.75, 1.0, 1.25, 1.5, .nan, .infinity] {
  precondition(InterfaceScale.percent(saved) == 100 && InterfaceScale.factor(saved) == 1)
 }
 let sizing=InterfaceScaling(defaults:prefs)
 let original=win.contentView
 sizing.register(win,preserveFrame:true)
 prefs.set(0.6,forKey:InterfaceScale.key);sizing.refresh()
 precondition(win.contentView === original, "Scale preserves hosting identity and view tasks")
 prefs.removePersistentDomain(forName:suite)
 win.orderOut(nil)
 print("FIXED_100_PERCENT_LEGACY_PREFERENCES_NESTED_WORKSPACE_PHYSICAL_CLICKS_AND_DRAGS_OK")
 }
}
