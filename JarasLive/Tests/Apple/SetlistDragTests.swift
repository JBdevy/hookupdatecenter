import AppKit
import SwiftUI
import UniformTypeIdentifiers
// Report failed checks without launching a system crash dialog over the next test.
func precondition(_ condition: @autoclosure () -> Bool, _ message: String) {
 if !condition() { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
}
struct Part { let id: UUID; let name: String }
struct SetlistBlock { let id: UUID; let name: String; var color: UInt32 = 0x69ed91; var showsSymbol = true }
enum Entry {
 case region(Part, Int), block(SetlistBlock)
 var id: UUID { switch self { case .region(let p, _): return p.id; case .block(let b): return b.id } }
 var name: String { switch self { case .region(let p, _): return p.name; case .block(let b): return b.name } }
 var isBlock: Bool { if case .block = self { return true }; return false }
}
extension Color { init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, opacity: 1) } }
@MainActor final class ShowController: ObservableObject {
 var projectSessionID = UUID()
 let current: Part? = Part(id: UUID(),name:"Project")
 let selectedRegionPlaylist: Part? = Part(id:UUID(),name:"Playlist")
 @Published var setlistEntries: [Entry] = (0..<4).map { .region(Part(id:UUID(),name:"Song \($0)"),$0) }
 @Published var setlistRevision: UInt64 = 0
 @Published var selection: Set<UUID> = []
 var moves = 0
 var deferPress = false
 var deferredPressWasNotMouseDown = false
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
 var body:some View {
  ScrollView { LazyVStack(spacing:4) {
   ForEach(show.setlistEntries,id:\.id) { entry in
    Group {
     switch entry {
     case .block(let block):
      SetlistBlockRow(block: block, nameColor: 0x69ed91, showSymbols: true, selected: show.selection.contains(block.id))
       .overlay(RoundedRectangle(cornerRadius: 4).stroke(show.selection.contains(block.id) ? Color.green : .clear, lineWidth: 1))
       .onTapGesture { show.selection = [block.id] }
       .contextMenu { Button("Edit block") {}; Divider(); Button("Delete block", role: .destructive) {} }
     case .region:
    Button {} label:{Text(entry.id.uuidString.prefix(8)).frame(width:280,height:34).background(Color.gray.opacity(0.3)).contentShape(Rectangle())}.buttonStyle(SetlistPressStyle(select: {
      let flags = NSApp.currentEvent?.modifierFlags ?? []
      let apply = {
       if show.deferPress { show.deferredPressWasNotMouseDown = NSApp.currentEvent?.type != .leftMouseDown }
       if flags.contains(.command) { if !show.selection.insert(entry.id).inserted { show.selection.remove(entry.id) } }
       else if !SetlistSelectionPhase.press.preservesSelection(selected: show.selection.contains(entry.id), count: show.selection.count, modifying: false) { show.selection = [entry.id] }
      }
      if show.deferPress { DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: apply) }
      else { apply() }
     }))
     }
    }.modifier(PlaylistRegionDrag(show:show,playlist:show.selectedRegionPlaylist!.id,entry:entry.id,block:entry.isBlock,selection:$show.selection,name:entry.name,released: { show.selection = [entry.id] }))
   }
   Spacer(minLength:0)
  }.padding(10) }.frame(width:300,height:240)
 }
}
MainActor.assumeIsolated {
 let previousApplication = NSWorkspace.shared.frontmostApplication
 defer { previousApplication?.activate(options: .activateIgnoringOtherApps) }
 let app=NSApplication.shared;app.setActivationPolicy(.regular);app.finishLaunching()
 let scale = Double(ProcessInfo.processInfo.environment["CATLIVE_SETLIST_TEST_SCALE"] ?? "1")!
 let blocksOnly = ProcessInfo.processInfo.environment["CATLIVE_SETLIST_BLOCKS_ONLY"] == "1"
 let show=ShowController(); let original=show.setlistEntries.map(\.id)
 let window=NSWindow(contentRect:NSRect(x:120,y:300,width:300 * scale,height:240 * scale),styleMask:[.titled],backing:.buffered,defer:false)
 let host=NSHostingView(rootView:InterfaceScaleLayout(factor: scale, content: Fixture(show:show)));window.contentView=host;window.isReleasedWhenClosed=false
 window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
 func pump(_ s:Double){
 let end=Date().addingTimeInterval(s)
 while Date()<end { if let e=app.nextEvent(matching:.any,until:Date().addingTimeInterval(0.01),inMode:.default,dequeue:true){app.sendEvent(e)};RunLoop.main.run(until:Date().addingTimeInterval(0.001));app.updateWindows() }
 }
 pump(0.8)
 precondition(app.isActive && window.isKeyWindow, "fixture did not acquire keyboard focus; real mouse test cannot run")
 func point(_ x:Double,_ y:Double)->CGPoint {
  let p=window.convertPoint(toScreen:host.convert(NSPoint(x:x * scale,y:y * scale),to:nil));return CGPoint(x:p.x,y:NSScreen.screens[0].frame.height-p.y)
 }
 func event(_ type:CGEventType,_ p:CGPoint){let e=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:p,mouseButton:.left)!;e.setIntegerValueField(.mouseEventClickState,value:1);e.post(tap:.cghidEventTap);Thread.sleep(forTimeInterval:0.06)}
 @MainActor func drag(from start:CGPoint,to end:CGPoint,escape:Bool=false) {
  precondition(app.isActive && window.isKeyWindow, "fixture lost focus; refusing to send mouse events to another application")
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
  func rows(_ view: NSView) -> [SetlistNativeDragView] {
   (view as? SetlistNativeDragView).map { [$0] } ?? view.subviews.flatMap(rows)
  }
  if ProcessInfo.processInfo.environment["CATLIVE_SETLIST_DRAG_TRACE"] == "1" {
   for row in rows(host) {
    FileHandle.standardError.write(Data("ROW \(row.name) frame=\(host.convert(row.bounds, from: row)) visible=\(row.visibleRect) hidden=\(row.isHiddenOrHasHiddenAncestor)\n".utf8))
   }
  }
  FileHandle.standardError.write(Data("Moves \(show.moves), order \(show.setlistEntries.map {original.firstIndex(of:$0.id).map(String.init) ?? $0.name})\n".utf8))
  precondition(SetlistReorderState.shared.target == nil && SetlistReorderState.shared.scope == nil,
               "drop/cancellation must clear the green insertion line and drag session")
 }
 if !blocksOnly {
 drag(from:point(150,27),to:point(150,118))
 precondition(show.setlistEntries.map(\.id)==[original[1],original[2],original[0],original[3]],"mouse drop must move the song after its target")
 drag(from:point(150,103),to:point(150,15))
 precondition(show.setlistEntries.map(\.id)==original,"mouse drop must move the song before its target")
 let moves=show.moves
 drag(from:point(150,27),to:point(150,118),escape:true)
 precondition(show.moves==moves && show.setlistEntries.map(\.id)==original,"Escape must cancel without reordering")
 drag(from:point(150,27),to:point(450,118))
 precondition(show.moves==moves && show.setlistEntries.map(\.id)==original,"dropping outside must cancel without reordering")
 show.selection = Set(original.prefix(2)); show.deferPress = true; pump(0.2)
 let held = point(150,27)
 DispatchQueue.global().async { event(.mouseMoved,held); event(.leftMouseDown,held); event(.mouseMoved,held) }
 pump(0.5)
 precondition(show.deferredPressWasNotMouseDown, "regression must deliver selection after the global mouse-down event")
 precondition(show.selection == Set(original.prefix(2)), "holding a selected row must keep all songs selected even after a deferred SwiftUI callback")
 DispatchQueue.global().async { event(.leftMouseUp,held) }; pump(0.4)
 precondition(show.selection == [original[0]], "only mouse-up without dragging may collapse the held selection")
 show.deferPress = false; show.selection = Set(original.prefix(2)); pump(0.2)
 drag(from:point(150,27),to:point(150,150))
 precondition(show.setlistEntries.map(\.id)==[original[2],original[3],original[0],original[1]],
              "dragging a selected row preserves and moves both songs in their original order")
 precondition(show.selection == Set(original.prefix(2)), "a group drag must not collapse selection")
 let groupMoves=show.moves
 let click=point(150,103)
 DispatchQueue.global().async { event(.mouseMoved,click);event(.leftMouseDown,click);event(.leftMouseUp,click) }
 pump(0.8)
 precondition(show.selection == [original[0]] && show.moves == groupMoves,
              "releasing a plain click without dragging collapses to the clicked song")
 }
 let block = SetlistBlock(id: UUID(), name: "Bloco 01")
 let block2 = SetlistBlock(id: UUID(), name: "Bloco 02")
 let songs = original.map { id in Entry.region(Part(id: id, name: "Song"), 1) }
 show.selection = []
 show.setlistEntries = [.block(block), songs[0], songs[1], .block(block2), songs[2], songs[3]]
 pump(0.4)
 let blockOriginal = show.setlistEntries.map(\.id)
 // Block rows are 24pt high and song rows 34pt; use the real block rendering,
 // tap gesture and context menu rather than wrapping it in a song Button.
 drag(from:point(150,22),to:point(150,102))
 precondition(show.setlistEntries.map(\.id) == [original[0], original[1], block.id, block2.id, original[2], original[3]],
              "dragging Bloco01 must move only its header after the target song")
 drag(from:point(150,98),to:point(150,15))
 precondition(show.setlistEntries.map(\.id) == blockOriginal, "a block can return before the first song")
 let blockMoves = show.moves
 drag(from:point(150,22),to:point(150,102),escape:true)
 precondition(show.moves == blockMoves && show.setlistEntries.map(\.id) == blockOriginal,
              "Escape cancels a block drag without moving its songs")
 drag(from:point(150,22),to:point(150,210))
 precondition(show.setlistEntries.map(\.id) == [original[0], original[1], block2.id, original[2], original[3], block.id],
              "a block can move after the last song without taking its songs")
 drag(from:point(150,202),to:point(150,15))
 precondition(show.setlistEntries.map(\.id) == blockOriginal, "the last block can return to the list start")
 show.setlistEntries = [.block(block), .block(block2)] + songs
 show.selection = []; pump(0.4)
 drag(from:point(150,22),to:point(150,60))
 precondition(show.setlistEntries.map(\.id) == [block2.id, block.id] + original,
              "blocks sharing the same following song can exchange order")
 show.setlistEntries = [.block(block), songs[0], songs[1], .block(block2), songs[2], songs[3]]
 show.selection = [block.id, block2.id]; pump(0.4)
 drag(from:point(150,22),to:point(150,210))
 precondition(show.setlistEntries.map(\.id) == original + [block.id, block2.id],
              "dragging selected blocks moves only those headers and preserves song order")
 precondition(show.selection == [block.id, block2.id], "dragging multiple blocks must preserve selection")
 print("SETLIST_BLOCK_REAL_MOUSE_MOVE_HEADER_ONLY_SAME_ANCHOR_TAIL_MULTI_CANCEL_OK scale=\(scale)")
 if !blocksOnly {
  print("SETLIST_MULTI_SELECTION_DRAG_AND_RELEASE_CLICK_OK")
  print("SETLIST_REAL_MOUSE_DROP_BEFORE_AFTER_AND_CANCEL_CLEANUP_OK")
 }
 window.close()
}
