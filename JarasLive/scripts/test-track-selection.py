from pathlib import Path
import os, subprocess, tempfile
os.chdir(Path(__file__).resolve().parent.parent)
s=Path('Apple/Shared/TrackMixerRow.swift').read_text()
router=s[s.index('@MainActor final class TrackSelectionRouter'):s.index('private final class TrackRightClickView:')]
stubs='''import AppKit
@MainActor final class TimelineTrackHeightResizeView { static func handlesPointer(_ event: NSEvent) -> Bool { false } }
@MainActor final class RightClickRouter { static let shared = RightClickRouter(); var interactionBlocked = false; func handlesModifiedLeftClick(_ event: NSEvent) -> Bool { false } }
@MainActor final class ControlMappings { static let shared = ControlMappings(); var editing: Int? }
@MainActor final class EditorSelectionRouter { static let shared = EditorSelectionRouter(); enum Area { case tracks }; func activate(_ area: Area, in window: NSWindow) {} }
enum TrackKind { case standard, click }
final class TrackRightClickView: NSView { var interactionBlocked=false; var project=UUID(); var track=UUID(); var kind=TrackKind.standard; var selected=false; var select:(()->Void)?; var dragName="Track" }
final class TrackControlSelectionExclusionView: NSView { var selectsTrack=false }
final class NativeVerticalTrackMeterView: NSView {}
final class TrackDragTitleView: NSView {}
final class TrackReorderState { static let shared=TrackReorderState(); var active=false; var source: TrackDragSource?; func begin(track:UUID) { active=true } }
final class EdgeScroll { func begin(from:NSView) {} }
final class TrackDragSource: NSObject, NSDraggingSource { var state:TrackReorderState?; let edgeScroll=EdgeScroll(); var onEnd:(()->Void)?; func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation { .move } }
extension NSFont { static func jarasSystemFont(ofSize size:CGFloat,weight:NSFont.Weight)->NSFont { systemFont(ofSize:size,weight:weight) } }
'''
test='''
@MainActor func run() {
 let app=NSApplication.shared
 let window=NSWindow(contentRect:NSRect(x:50,y:50,width:400,height:200),styleMask:[.titled],backing:.buffered,defer:false)
 let row=TrackRightClickView(frame:NSRect(x:0,y:0,width:400,height:100));window.contentView!.addSubview(row)
 window.makeKeyAndOrderFront(nil)
 let router=TrackSelectionRouter.shared;router.add(row)
 let other=UUID();var selection:Set<UUID>=[row.track,other];var calls=0
 row.selected=true;row.select={ selection=[row.track];calls+=1 }
 var serial=0.0
 func event(_ type:NSEvent.EventType, _ point:NSPoint=NSPoint(x:180,y:50))->NSEvent {
  serial+=1
  return NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:serial,windowNumber:window.windowNumber,context:nil,eventNumber:Int(serial),clickCount:1,pressure:1)!
 }
 func check(_ ok:Bool,_ message:String){if !ok{fatalError(message)}}
 router.handle(event(.leftMouseDown));check(selection.count==2,"press collapsed selection")
 router.handle(event(.leftMouseDragged));router.handle(event(.leftMouseUp));check(selection.count==2&&calls==0,"drag collapsed selection")
 router.handle(event(.leftMouseDown));router.handle(event(.leftMouseUp));check(selection==[row.track]&&calls==1,"release did not select")
 row.selected=false;selection=[other];router.handle(event(.leftMouseDown));check(selection==[row.track],"new row selection delayed past drag start");router.handle(event(.leftMouseUp))
 let area=TrackControlSelectionExclusionView(frame:NSRect(x:100,y:20,width:200,height:60));row.addSubview(area);router.addControl(area)
 let before=calls;router.handle(event(.leftMouseDown));router.handle(event(.leftMouseUp));check(calls==before,"control changed selection")
 area.selectsTrack=true;router.handle(event(.leftMouseDown));router.handle(event(.leftMouseUp));check(calls==before+1,"fader readout background cannot select")
 row.selected=true;router.handle(event(.leftMouseDown));router.resetProjectSession();router.handle(event(.leftMouseUp));check(calls==before+1,"old project released pending selection")
 print("TRACK_SELECTION_PRESS_RELEASE_DRAG_AND_CONTROL_ROUTING_OK")
 window.orderOut(nil);_ = app
}
MainActor.assumeIsolated { run() }
'''
with tempfile.TemporaryDirectory(prefix='catlive-selection-') as directory:
 root=Path(directory);source=root/'main.swift';binary=root/'test'
 source.write_text(stubs+router+test)
 subprocess.run(['swiftc','-swift-version','5',str(source),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
