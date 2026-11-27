import AppKit
import SwiftUI
private typealias TimelineRenderKey = Int
private enum ItemWaveformPreview { typealias State = Int }
private func itemIdentity(nativeAudioItems: Set<UUID>) -> TimelineTileIdentity {
    let renderKey = 1, extent = 500.0, colorScheme = ColorScheme.dark
    let rowHeight: CGFloat = 64, rows = (heights: [rowHeight], count: 1), rulerHeight: CGFloat = 0
    let selectedClips = Set<UUID>(), missingAudioPaths = Set<String>(), mediaDirectory: URL? = nil
    let waveformRevision: UInt64 = 0, invertWaveformColors = false
    return __ITEM_CANVAS_IDENTITY__
}

private final class Position: ObservableObject { @Published var x: CGFloat = 0 }
private var counts: [String:Int] = [:]
private struct Fixture: View {
 @ObservedObject var position: Position
 var body: some View {
  ViewportTimelineCanvas(visibleRect: CGRect(x: position.x, y: 0, width: 840, height: 600), synchronized: true, documentWidth: 6000, identity: itemIdentity(nativeAudioItems: []), tileIdentity: { _, _ in itemIdentity(nativeAudioItems: []) }) { context, _, rect, _ in
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
 window.contentView = host; window.setFrameOrigin(CGPoint(x: -20000, y: -20000)); window.orderBack(nil)
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

private final class Ownership: ObservableObject {
    @Published var nativeAudioItems: Set<UUID> = []
    let audioID = UUID()
}
private struct OwnershipFixture: View {
    @ObservedObject var owner: Ownership

    var body: some View {
        let nativeAudioItems = owner.nativeAudioItems
        let clip = owner.audioID
        ZStack {
            // The native waveform underneath the hosted item body.
            Color.green
            ViewportTimelineCanvas(visibleRect: CGRect(x: 0, y: 0, width: 32, height: 32),
                synchronized: true, documentWidth: 32, batchesViewport: true,
                identity: itemIdentity(nativeAudioItems: nativeAudioItems)) { context, _, rect, _ in
                    if !nativeAudioItems.contains(clip) {
                        context.fill(Path(rect), with: .color(.red))
                    }
                }
        }.frame(width: 32, height: 32)
    }
}

MainActor.assumeIsolated {
    let state = Ownership()
    let host = NSHostingView(rootView: OwnershipFixture(owner: state))
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 32, height: 32),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    func center() -> NSColor {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
    }
    let before = center()
    precondition(before.redComponent > before.greenComponent, "Hosted fill must initially cover the native layer")
    state.nativeAudioItems = [state.audioID]
    let after = center()
    precondition(after.greenComponent > after.redComponent, "Native waveform must be uncovered without zoom or scroll")
    state.nativeAudioItems = []
    let returned = center()
    precondition(returned.redComponent > returned.greenComponent, "Returning ownership must repaint hosted fills")
    print("ITEM_CANVAS_OWNER_TRANSITION_UNCOVERS_NATIVE_PIXELS_WITHOUT_ZOOM_OK")
}
