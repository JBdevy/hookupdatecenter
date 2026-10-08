import SwiftUI
import AppKit
struct Part: Identifiable { let id = UUID(); var name: String; var color: UInt32?; var usesUppercase = true }
extension Color { init(hex: UInt32) { self.init(red: Double(hex >> 16 & 255)/255, green: Double(hex >> 8 & 255)/255, blue: Double(hex & 255)/255) } }
struct InputValidationShake: GeometryEffect { var animatableData: Double; func effectValue(size: CGSize) -> ProjectionTransform { ProjectionTransform(.identity) } }
final class FixtureState: ObservableObject {
 @Published var editing: UUID?; @Published var unifying: UUID?
 let parts: [Part]
 var saved: [(UUID,String)] = []; var unified: [(UUID,String)] = []
 init(_ count: Int) { parts = (0..<count).map { Part(name: "Region \($0)", color: 0x704250) } }
 func editRegion(_ id: UUID, name: String, color: UInt32, uppercaseName: Bool) { saved.append((id,name)) }
 func unifyRegions(containing id: UUID, name: String) -> Bool { unified.append((id,name)); return true }
}
final class Hit: NSView { let identity: UUID; init(_ id: UUID) { identity=id; super.init(frame: .zero) }; required init?(coder: NSCoder) { fatalError() } }
struct HitSurface: NSViewRepresentable {
 let id: UUID
 static var creations=0
 func makeNSView(context: Context) -> Hit { Self.creations += 1; return Hit(id) }
 func updateNSView(_ view: Hit, context: Context) {}
}

import SwiftUI
import AppKit
func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] { (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { descendants(type,$0) } }
struct Strip: View {
 @ObservedObject var state: FixtureState
 let lazy: Bool
 var body: some View {
 GeometryReader { geometry in
  HStack(spacing: 0) { ForEach(state.parts.indices, id: \.self) { index in
   if lazy { LazyRegionFixture(show: state, index: index, width: geometry.size.width / CGFloat(state.parts.count)) }
   else { EagerRegionFixture(show: state, index: index, width: geometry.size.width / CGFloat(state.parts.count)) }
  } }.frame(height: 24)
 }.frame(height: 60)
 }
}
@MainActor func run() throws {
 _ = NSApplication.shared
 if ProcessInfo.processInfo.environment["CATLIVE_TEST_EDITORS_ONLY"] != "1" {
 for count in [44,200] {
 for lazy in [false,true] {
  let state=FixtureState(count), host=NSHostingView(rootView: Strip(state: state, lazy: lazy))
  let window=NSWindow(contentRect: CGRect(x:0,y:0,width:1400,height:80), styleMask: [.borderless], backing: .buffered, defer: false)
  window.isReleasedWhenClosed=false; window.contentView=host
  host.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date(timeIntervalSinceNow:0.02))
  let ids=descendants(Hit.self,host).map { ObjectIdentifier($0) }
  var times:[Double]=[]
  for index in 0..<70 {
   let start=ProcessInfo.processInfo.systemUptime
   host.setFrameSize(CGSize(width:1400+CGFloat(index%20)*2,height:80)); host.layoutSubtreeIfNeeded()
   if index>=10 { times.append((ProcessInfo.processInfo.systemUptime-start)*1000) }
  }
  precondition(descendants(Hit.self,host).map { ObjectIdentifier($0) } == ids)
  times.sort();print("REGION_POPOVER count=\(count) lazy=\(lazy) mean=\(times.reduce(0,+)/Double(times.count)) p95=\(times[Int(Double(times.count)*0.95)]) mounted=\(ids.count)")
  window.close()
 }
 }
 }
 func settle(_ host: NSView) { for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date(timeIntervalSinceNow:0.03)) } }
 var frames:[CGRect]=[]
 for lazy in [false,true] {
  let state=FixtureState(3), host=NSHostingView(rootView: Strip(state: state, lazy: lazy))
  let window=NSWindow(contentRect: CGRect(x: ProcessInfo.processInfo.environment["CATLIVE_TEST_OFFSCREEN"] == "1" ? -10000 : 500, y:250,width:720,height:80), styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed=false; window.contentView=host; window.orderFront(nil); settle(host)
  let originalIDs=descendants(Hit.self,host).map { ObjectIdentifier($0) }
  state.editing=state.parts[1].id; settle(host)
  let dialogs=NSApp.windows.filter { $0 !== window && $0.isVisible && $0.contentView != nil }
  let pop=try { () throws -> NSWindow in guard let pop=dialogs.first else { fatalError("No editor") };return pop }()
  let fields=descendants(NSTextField.self,pop.contentView!).filter { $0.isEditable }
  precondition(fields.contains { $0.stringValue == state.parts[1].name }, "The requested region's editor opens")
  frames.append(pop.frame)
  let event=NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:pop.windowNumber, context:nil, characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
  precondition(pop.performKeyEquivalent(with:event), "Return reaches the editor default action");settle(host)
  precondition(state.saved.count == 1 && state.saved[0].0 == state.parts[1].id,"Enter confirms exactly the opened region")
  precondition(state.editing == nil,"Confirm dismisses the region editor")
  state.editing=state.parts[2].id; settle(host)
  let cancelPop=NSApp.windows.first { $0 !== window && $0.isVisible && $0.contentView != nil }!
  let esc=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:cancelPop.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
  if !cancelPop.performKeyEquivalent(with:esc) { cancelPop.sendEvent(esc) };settle(host)
  precondition(state.editing == nil && state.saved.count == 1,"Escape dismisses without saving")
  state.unifying=state.parts[0].id; settle(host)
  let unifyPop=NSApp.windows.first { $0 !== window && $0.isVisible && $0.contentView != nil }!
  let unifyEnter=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:unifyPop.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
  precondition(unifyPop.performKeyEquivalent(with:unifyEnter));settle(host)
  precondition(state.unified.isEmpty && state.unifying != nil,"An unnamed unified region stays open")
  let unifyField=descendants(NSTextField.self,unifyPop.contentView!).first { $0.isEditable }!
  unifyField.stringValue="Special Set"
  unifyField.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:unifyField));settle(host)
  precondition(unifyPop.performKeyEquivalent(with:unifyEnter));settle(host)
  precondition(state.unified.count == 1 && state.unified[0].0 == state.parts[0].id && state.unified[0].1 == "Special Set","Unify confirms the requested region and entered name")
  precondition(state.unifying == nil,"Unify dismisses on success")
  precondition(descendants(Hit.self,host).map { ObjectIdentifier($0) } == originalIDs,"Opening editors preserves hit target identity")
  window.close();settle(host)
 }
 precondition(abs(frames[0].midX-frames[1].midX)<1 && abs(frames[0].midY-frames[1].midY)<1,"Conditional editor keeps the original region anchor")
 print("REGION_POPOVER_EDITOR_ENTER_ESCAPE_UNIFY_AND_ANCHOR_OK")

}
MainActor.assumeIsolated { try! run() }
