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
MainActor.assumeIsolated {
 testPlaybackUpdatesWithoutRebuildingRows()
 try! testVisualParity()
 try! testActions()
 try! benchmarkLabels()
}
