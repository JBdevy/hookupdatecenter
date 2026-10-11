import AppKit
import SwiftUI

// Exercise the production rail with both sidebar lengths and actual SwiftUI
// scrolling. The iOS-16 compile in the harness also checks the supported API set.
private enum RemoteSurface { static let panel = Color.gray }
private final class SidebarProbeView: NSView {
    var index = -1
    override var isFlipped: Bool { true }
}
private struct SidebarProbe: NSViewRepresentable {
    let index: Int
    func makeNSView(context: Context) -> SidebarProbeView { SidebarProbeView() }
    func updateNSView(_ view: SidebarProbeView, context: Context) { view.index = index }
}
private struct SidebarFixture: View {
    let count: Int
    let hidden: Bool
    var body: some View {
        HStack(spacing: 0) {
            RemoteSidebarRail(hidden: hidden) {
                ForEach(0..<count - 2, id: \.self) { index in button(index) }
                Spacer(minLength: RemoteSidebarMetrics.groupSpacing)
                button(count - 2)
                button(count - 1)
            }.buttonStyle(.plain)
            Color.black.background(SidebarProbe(index: -1))
        }
    }
    private func button(_ index: Int) -> some View {
        Button {} label: {
            Text("\(index)").frame(width: 44, height: 44)
                .contentShape(Rectangle()).background(SidebarProbe(index: index))
        }
    }
}
private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
}
private func settle(_ view: NSView) {
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.035))
    view.layoutSubtreeIfNeeded()
}

_ = NSApplication.shared
for (device, size, count) in [
    ("phone-compact-director", CGSize(width: 320, height: 460), 12),
    ("phone-director", CGSize(width: 390, height: 760), 12),
    ("tablet-short-director", CGSize(width: 744, height: 380), 9),
    ("tablet-director", CGSize(width: 1024, height: 720), 9),
    ("phone-observer", CGSize(width: 320, height: 200), 5),
    ("tablet-observer", CGSize(width: 1024, height: 720), 4)
] {
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSHostingView(rootView: SidebarFixture(count: count, hidden: false))
    if #available(macOS 13, *) { root.sizingOptions = [] }
    if #available(macOS 13.3, *) { root.safeAreaRegions = [] }
    window.contentView = root; settle(root)
    let probes = descendants(SidebarProbeView.self, in: root).filter { $0.index >= 0 }.sorted { $0.index < $1.index }
    precondition(probes.count == count)
    let rects = probes.map { $0.convert($0.bounds, to: root) }
    for rect in rects {
        precondition(abs(rect.width - 44) < 0.01 && abs(rect.height - 44) < 0.01, "\(device): every button retains a full 44-point touch area")
        precondition(abs(rect.minX - 4) < 0.01, "\(device): side padding is outside the touch target")
    }
    for pair in zip(rects, rects.dropFirst()) {
        let gap = abs(pair.1.midY - pair.0.midY) - 44
        precondition(gap >= 7.99, "\(device): adjacent touch targets never overlap or lose their gap")
    }
    let workspace = descendants(SidebarProbeView.self, in: root).first { $0.index == -1 }!
    precondition(abs(workspace.convert(workspace.bounds, to: root).minX - 52) < 0.01, "\(device): rail consumes exactly its own width")
    let scroll = descendants(NSScrollView.self, in: root).first!
    let last = probes.last!
    let requiresScroll = rects.map(\.minY).min()! < 0 || rects.map(\.maxY).max()! > size.height
    if requiresScroll {
        precondition(scroll.documentView!.bounds.height > scroll.contentView.bounds.height, "\(device): compact screens grow scroll content instead of shrinking buttons")
        last.scrollToVisible(last.bounds); settle(root)
        let target = last.convert(last.bounds, to: scroll.contentView)
        precondition(scroll.contentView.bounds.insetBy(dx: -0.1, dy: -0.1).contains(target), "\(device): the final hide button remains reachable by scrolling")
    }
    root.rootView = SidebarFixture(count: count, hidden: true); settle(root)
    let hiddenWorkspace = descendants(SidebarProbeView.self, in: root).first { $0.index == -1 }!
    precondition(abs(hiddenWorkspace.convert(hiddenWorkspace.bounds, to: root).minX) < 0.01, "\(device): hiding the rail returns its entire width to the workspace")
    window.close()
    print("REMOTE_SIDEBAR_LAYOUT_OK \(device) scrolled=\(requiresScroll)")
}
