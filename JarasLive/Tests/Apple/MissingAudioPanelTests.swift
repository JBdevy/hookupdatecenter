private final class LayoutProbeView: NSView { var role = ""; override var isFlipped: Bool { true } }
private struct LayoutProbe: NSViewRepresentable {
    let role: String
    func makeNSView(context: Context) -> LayoutProbeView { LayoutProbeView() }
    func updateNSView(_ view: LayoutProbeView, context: Context) { view.role = role }
}
private func descendants<T: NSView>(_ type: T.Type, _ root: NSView) -> [T] {
    ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants(type, $0) }
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 560, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    var opened = 0
    let paths = (0..<80).map { "Stems/song/Track \($0).wav" }
    let warnings = (0..<200).map { "Track \($0): VST3 with a long file name was not found. The project can open with the missing effects preserved." }
    let host = NSHostingView(rootView: MissingAudioRecoveryPanel(paths: paths, warnings: warnings, errors: ["Search folder unavailable"], busy: false, status: "", canCancel: true, cancel: {}, open: { opened += 1 }, search: {}))
    if #available(macOS 13, *) { host.sizingOptions = [] }
    if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
    window.contentView = host
    for size in [CGSize(width: 560, height: 440), CGSize(width: 440, height: 320), CGSize(width: 320, height: 240)] {
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded()
        let probes = Dictionary(uniqueKeysWithValues: descendants(LayoutProbeView.self, host).map { ($0.role, $0) })
        let actions = probes["actions"]!, details = probes["details"]!, header = probes["header"]!
        let bounds = host.bounds.insetBy(dx: -0.1, dy: -0.1)
        let actionRect = actions.convert(actions.bounds, to: host)
        precondition(bounds.contains(actionRect) && bounds.contains(header.convert(header.bounds, to: host)))
        precondition(!actionRect.intersects(details.convert(details.bounds, to: host)))
        let scroll = descendants(NSScrollView.self, host).first!
        precondition(!actions.isDescendant(of: scroll))
        precondition(scroll.documentView!.bounds.height > scroll.contentView.bounds.height)
        scroll.documentView!.scroll(CGPoint(x: 0, y: scroll.documentView!.bounds.height))
        host.layoutSubtreeIfNeeded()
        precondition(actions.convert(actions.bounds, to: host) == actionRect)
        print("MISSING_AUDIO_PANEL_200_WARNINGS_SCROLL_FIXED_ACTIONS_OK \(size)")
    }
    window.setContentSize(CGSize(width: 560, height: 440))
    window.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    _ = window.performKeyEquivalent(with: enter)
    precondition(opened == 1, "Return must activate Open anyway once")
    print("MISSING_AUDIO_PANEL_RETURN_DEFAULT_ACTION_OK")
    window.close()
}
