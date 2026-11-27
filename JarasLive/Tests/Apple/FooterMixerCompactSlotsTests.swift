import SwiftUI
import AppKit

private typealias FooterMixerStripContentKey = Int
private final class FooterMixerHostingView: NSHostingView<AnyView> {
    func registerChannelGeometry(_ view: FooterMixerStripGeometryView) {}
}
private struct NativeLibraryTrackDrop {
    static let type = NSPasteboard.PasteboardType("fixture")
    func operation(for sender: NSDraggingInfo, in view: NSView) -> NSDragOperation { [] }
    func perform(_ sender: NSDraggingInfo, in view: NSView) -> Bool { false }
}
private extension View {
    func workspaceControlsAppearActive() -> some View { self }
}

// PRODUCTION_CHANNEL_GEOMETRY

private struct Slot: NSViewRepresentable {
    let tag: Int
    func makeNSView(context: Context) -> NSButton { NSButton() }
    func updateNSView(_ button: NSButton, context: Context) { button.tag = tag }
}
@MainActor private func button(_ root: NSView) -> NSButton? {
    if let hit = root as? NSButton { return hit }
    return root.subviews.lazy.compactMap(button).first
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let rect = NSRect(x: -20000, y: -20000, width: 85, height: 724)
    let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let geometry = FooterMixerStripGeometryView()
    geometry.setViewportHeight(230)
    func update(_ value: Int) {
        geometry.update(iconHeight: 0, slots: AnyView(Slot(tag: value)), contentKey: value) { _ in AnyView(Color.gray) }
    }
    func settle() {
        for _ in 0..<3 { geometry.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.015)) }
    }
    update(1)
    window.contentView = geometry
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    settle()
    precondition(geometry.subviews.count == 1, "The zero-height FX/Sends region must not create a hosting tree")
    update(2)
    geometry.setViewportHeight(360); settle()
    let slots = geometry.subviews.first { button($0)?.tag == 2 }
    precondition(slots != nil && slots?.isHidden == false, "Expanding a channel must install its latest controls immediately")
    geometry.setViewportHeight(230); settle()
    precondition(slots?.isHidden == true)
    update(3)
    geometry.setViewportHeight(380); settle()
    precondition(geometry.subviews.count == 2 && slots.map { button($0)?.tag == 3 } == true,
                 "A hidden channel must reuse its existing host with updated controls when expanded")
    print("COMPACT_HOZ_CHANNEL_SKIPS_HIDDEN_FX_HOST_AND_RETAINS_EXPANDED_CONTROLS_OK")
}
