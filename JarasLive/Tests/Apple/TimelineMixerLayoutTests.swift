import SwiftUI
import AppKit

private final class RowView: NSView { let row: Int; init(_ row: Int) { self.row = row; super.init(frame: .zero) }; required init?(coder: NSCoder) { fatalError() } }
private struct RowProbe: NSViewRepresentable {
    let row: Int
    func makeNSView(context: Context) -> RowView { RowView(row) }
    func updateNSView(_ view: RowView, context: Context) {}
}
private func descendants(_ root: NSView) -> [RowView] {
    (root as? RowView).map { [$0] } ?? root.subviews.flatMap(descendants)
}
@MainActor func verify() {
    _ = NSApplication.shared
    let offsets: [CGFloat] = [0, 64, 144, 224]
    let heights: [CGFloat] = [64, 80, 80, 64]
    func rows(_ width: CGFloat) -> some View {
        TimelineTrackRowsLayout(width: width, height: 480, top: 71, offsets: offsets, rowHeights: heights) {
            ForEach(0..<4, id: \.self) { RowProbe(row: $0).frame(height: heights[$0]) }
        }.frame(width: width, height: 480)
    }
    let host = NSHostingView(rootView: AnyView(rows(220)))
    host.frame = NSRect(x: 0, y: 0, width: 220, height: 480)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    var views = descendants(host).sorted { $0.row < $1.row }
    precondition(views.map(\.row) == [0, 1, 2, 3], "all mixer controls stay mounted")
    let originals = views.map(ObjectIdentifier.init)
    let positions = views.map { $0.convert(CGPoint(x: 0, y: $0.bounds.maxY), to: host).y }
    for index in 1..<positions.count {
        precondition(abs(positions[index] - positions[index - 1] - heights[index - 1]) < 1, "mixer rows preserve their lane spacing")
    }
    host.rootView = AnyView(rows(270))
    host.setFrameSize(NSSize(width: 270, height: 480))
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    views = descendants(host).sorted { $0.row < $1.row }
    precondition(views.map(ObjectIdentifier.init) == originals, "changing width preserves control identity")
    print("MIXER_FIXED_LAYOUT_ROW_SPACING_AND_CONTROL_IDENTITY_OK")
    window.close()
}
MainActor.assumeIsolated { verify() }
