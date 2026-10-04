import AppKit
import SwiftUI
import UniformTypeIdentifiers
// Report failed checks without launching a system crash dialog over the next test.
func precondition(_ condition: @autoclosure () -> Bool, _ message: String) {
 if !condition() { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
}
struct Part { let id: UUID; let name: String }
enum Entry { case region(Part, Int); var id: UUID { switch self { case .region(let p, _): return p.id } } }
@MainActor final class ShowController: ObservableObject {
 let current: Part? = Part(id: UUID(),name:"Project")
 let selectedRegionPlaylist: Part? = Part(id:UUID(),name:"Playlist")
 @Published var setlistEntries: [Entry] = (0..<4).map { .region(Part(id:UUID(),name:"Song \($0)"),$0) }
 @Published var setlistRevision: UInt64 = 0
 var moves = 0
 func moveSetlistEntries(_ ids:Set<UUID>,relativeTo target:UUID,after:Bool) {
  guard !ids.contains(target) else { return }
  let moving=setlistEntries.filter { ids.contains($0.id) }
  var next=setlistEntries.filter { !ids.contains($0.id) }
  guard let index=next.firstIndex(where:{$0.id==target}) else{return}
  next.insert(contentsOf:moving,at:index+(after ? 1:0));setlistEntries=next;moves+=1;setlistRevision &+= 1
 }
}
enum JarasTheme { static let green=Color.green }
struct LockedRegionDrag: ViewModifier { func body(content:Content)->some View { content } }
// INSERT_SETLIST_DRAG
struct Fixture: View {
 @ObservedObject var show:ShowController
 @State private var selection:Set<UUID>=[]
 var body:some View {
  ScrollView { LazyVStack(spacing:4) {
   ForEach(show.setlistEntries,id:\.id) { entry in
    Button {} label:{Text(entry.id.uuidString.prefix(8)).frame(width:280,height:34).background(Color.gray.opacity(0.3)).contentShape(Rectangle())}.buttonStyle(.plain)
     .modifier(PlaylistRegionDrag(show:show,playlist:show.selectedRegionPlaylist!.id,entry:entry.id,block:false,selection:$selection))
   }
   Spacer(minLength:0)
  }.padding(10) }.frame(width:300,height:240)
 }
}
MainActor.assumeIsolated {
 let app=NSApplication.shared;app.setActivationPolicy(.regular);app.finishLaunching()
 let show=ShowController(); let original=show.setlistEntries.map(\.id)
 let window=NSWindow(contentRect:NSRect(x:120,y:300,width:300,height:240),styleMask:[.titled],backing:.buffered,defer:false)
 let host=NSHostingView(rootView:Fixture(show:show));window.contentView=host;window.isReleasedWhenClosed=false
 window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
 func pump(_ s:Double){
 let end=Date().addingTimeInterval(s)
 while Date()<end { if let e=app.nextEvent(matching:.any,until:Date().addingTimeInterval(0.01),inMode:.default,dequeue:true){app.sendEvent(e)};RunLoop.main.run(until:Date().addingTimeInterval(0.001));app.updateWindows() }
 }
 pump(0.8)
 func point(_ x:Double,_ y:Double)->CGPoint {
  let p=window.convertPoint(toScreen:host.convert(NSPoint(x:x,y:y),to:nil));return CGPoint(x:p.x,y:NSScreen.screens[0].frame.height-p.y)
 }
 func event(_ type:CGEventType,_ p:CGPoint){let e=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:p,mouseButton:.left)!;e.setIntegerValueField(.mouseEventClickState,value:1);e.post(tap:.cghidEventTap);Thread.sleep(forTimeInterval:0.06)}
 @MainActor func drag(from start:CGPoint,to end:CGPoint,escape:Bool=false) {
  DispatchQueue.global().async {
   event(.mouseMoved,start);event(.leftMouseDown,start)
   for i in 1...20 { let t=Double(i)/20;event(.leftMouseDragged,CGPoint(x:start.x+(end.x-start.x)*t,y:start.y+(end.y-start.y)*t)) }
   if escape {
    for down in [true,false] {CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:down)!.post(tap:.cghidEventTap)}
    Thread.sleep(forTimeInterval:0.1)
   }
   event(.leftMouseUp,end)
  }
  pump(3)
  FileHandle.standardError.write(Data("Moves \(show.moves), order \(show.setlistEntries.map {original.firstIndex(of:$0.id)!})\n".utf8))
  precondition(SetlistReorderState.shared.target == nil && SetlistReorderState.shared.scope == nil,
               "drop/cancellation must clear the green insertion line and drag session")
 }
 drag(from:point(150,27),to:point(150,118))
 precondition(show.setlistEntries.map(\.id)==[original[1],original[2],original[0],original[3]],"mouse drop must move the song after its target")
 drag(from:point(150,103),to:point(150,15))
 precondition(show.setlistEntries.map(\.id)==original,"mouse drop must move the song before its target")
 let moves=show.moves
 drag(from:point(150,27),to:point(150,118),escape:true)
 precondition(show.moves==moves && show.setlistEntries.map(\.id)==original,"Escape must cancel without reordering")
 drag(from:point(150,27),to:point(450,118))
 precondition(show.moves==moves && show.setlistEntries.map(\.id)==original,"dropping outside must cancel without reordering")
 print("SETLIST_REAL_MOUSE_DROP_BEFORE_AFTER_AND_CANCEL_CLEANUP_OK")
 window.close()
}
