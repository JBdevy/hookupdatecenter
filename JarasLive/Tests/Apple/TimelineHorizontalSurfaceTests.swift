import AppKit
import SwiftUI
private final class Position: ObservableObject { @Published var x: CGFloat = 0 }
private var counts: [String:Int] = [:]
private struct Fixture: View {
 @ObservedObject var position: Position
 var body: some View {
  ViewportTimelineCanvas(visibleRect: CGRect(x: position.x, y: 0, width: 840, height: 600), synchronized: true, documentWidth: 6000, identity: TimelineTileIdentity(), tileIdentity: { _, _ in TimelineTileIdentity() }) { context, _, rect, _ in
   let key = "\(rect.minX):\(rect.minY):\(rect.width):\(rect.height)"
   counts[key, default: 0] += 1
   context.fill(Path(rect), with: .color(.green))
  }.frame(width: 6000,height: 1200)
 }
}
MainActor.assumeIsolated {
 _ = NSApplication.shared
 let state = Position()
 let host = NSHostingView(rootView: Fixture(position: state))
 let window = NSWindow(contentRect: NSRect(x:0,y:0,width:840,height:600),styleMask:[.borderless],backing:.buffered,defer:false)
 window.contentView = host; window.orderFrontRegardless()
 func settle() { for _ in 0..<3 { host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.03)) } }
 settle()
 for x: CGFloat in [500,512,520,1024,1030,512,0] {
  let before = counts
  state.x = x; settle()
  for (key,count) in before where counts[key] != nil { precondition(counts[key] == count, "retained surface redrawn during scroll: \(key)") }
 }
 window.orderOut(nil)
 print("SCROLL_BUCKET_BOUNDARIES_RETAIN_COMPLETE_WAVEFORM_SURFACES_OK")
}
