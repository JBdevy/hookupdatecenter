private final class NoticeLayoutProbeView: NSView {
    var role = ""
    override var isFlipped: Bool { true }
}
private struct NoticeLayoutProbe: NSViewRepresentable {
    let role: String
    func makeNSView(context: Context) -> NoticeLayoutProbeView { NoticeLayoutProbeView() }
    func updateNSView(_ view: NoticeLayoutProbeView, context: Context) { view.role = role }
}
private struct NoticeLayoutFixture: View {
    let portuguese: Bool
    var body: some View {
        RemoteNoticePanel {
            HStack {
                Text(verbatim: portuguese ? "Recados" : "Messages"); Spacer(); Text("20s")
                Button(portuguese ? "Fechar" : "Close") {}.frame(minWidth: 44, minHeight: 44)
            }.background(NoticeLayoutProbe(role: "header"))
        } actions: {
            RemoteNoticeActions {
              HStack(spacing: 8) {
                Button {} label: {
                    Label(portuguese ? "Enviar" : "Send", systemImage: "paperplane.fill")
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(NoticeSendButtonStyle(phase: .idle))
                    .background(NoticeLayoutProbe(role: "send"))
                Button {} label: {
                    Text(verbatim: portuguese ? "Retirar" : "Withdraw").frame(minWidth: 60, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(RemoteNoticeActionStyle()).background(NoticeLayoutProbe(role: "clear"))
              }
            } pin: {
              HStack(spacing: 8) {
                Button {} label: {
                    Label(portuguese ? "Fixar" : "Pin", systemImage: "pin").frame(minWidth: 60, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(RemoteNoticeActionStyle()).background(NoticeLayoutProbe(role: "pin"))
                Button {} label: {
                    Text(verbatim: portuguese ? "Fixar com o transporte parado" : "Pin while transport is stopped")
                        .lineLimit(2).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(RemoteNoticeActionStyle()).background(NoticeLayoutProbe(role: "stopped"))
              }
            }.font(.system(size: 13, weight: .semibold))
        } content: {
            Text("Could not confirm delivery. Check the PC.").frame(minHeight: 22)
            Text("Global · Recado 1 · Recado 2 · Recado 3").frame(height: 32)
            TextEditor(text: .constant("A message being edited"))
                .frame(height: 150).padding(5).background(NoticeLayoutProbe(role: "editor"))
            Text("500 / 500").frame(height: 25)
            HStack { Button("TP-1") {}; Button("TP-2") {} }
                .frame(height: 44).background(NoticeLayoutProbe(role: "destinations"))
        }.frame(idealWidth: 440, maxWidth: 440, idealHeight: 500, maxHeight: 500)
    }
}
private func noticeDescendants<T: NSView>(_ type: T.Type, _ root: NSView) -> [T] {
    ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { noticeDescendants(type, $0) }
}
private func settleNoticeLayout(_ root: NSView) {
    root.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    root.layoutSubtreeIfNeeded()
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let simple = RemoteNoticeActions { Text("Send") } pin: { Text("Pin") }
    let nested = RemoteNoticeActions {
        HStack { Button("Send") {}; Button("Withdraw") {} }
    } pin: {
        HStack { Label("Pin", systemImage: "pin"); Button("Pin while stopped") {} }
    }
    let bodyType = String(reflecting: type(of: simple.body))
    precondition(bodyType == String(reflecting: type(of: nested.body)),
                 "Notice action metadata must not depend on generic child tuples on iOS 16")
    precondition(bodyType.contains("AnyView") && !bodyType.contains("_ConditionalContent"),
                 "Availability branches must be erased before resolving the notice body metadata")
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: NoticeLayoutFixture(portuguese: true))
    if #available(macOS 13, *) { host.sizingOptions = [] }
    if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
    window.contentView = host
    for portuguese in [true, false] {
      host.rootView = NoticeLayoutFixture(portuguese: portuguese)
      for (name, size) in [
        ("ipad-without-keyboard", CGSize(width: 440, height: 500)),
        ("ipad-keyboard", CGSize(width: 440, height: 280)),
        ("phone-keyboard", CGSize(width: 390, height: 290)),
        ("small-phone-sidebar-keyboard", CGSize(width: 268, height: 240)),
        ("phone320-keyboard200", CGSize(width: 320, height: 200)),
        ("phone320-keyboard250", CGSize(width: 320, height: 250)),
        ("compact-keyboard", CGSize(width: 268, height: 180)),
        ("keyboard-dismissed", CGSize(width: 440, height: 500))
    ] {
        window.setContentSize(size); settleNoticeLayout(host)
        for scroll in noticeDescendants(NSScrollView.self, host) {
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        }
        settleNoticeLayout(host)
        let probes = Dictionary(uniqueKeysWithValues: noticeDescendants(NoticeLayoutProbeView.self, host).map { ($0.role, $0) })
        let header = probes["header"]!.convert(probes["header"]!.bounds, to: host)
        let actionRects = ["send", "clear", "pin", "stopped"].map { role -> CGRect in
            let probe = probes[role]!, rect = probe.convert(probe.bounds, to: host)
            precondition(rect.width >= 43.99 && rect.height >= 43.99, "\(name): \(role) keeps the full touch target")
            precondition(host.bounds.insetBy(dx: -0.1, dy: -0.1).contains(rect), "\(name): \(role) cannot be cropped by keyboard compression: \(rect)")
            precondition(abs(rect.midY - header.midY) >= (header.height + rect.height) / 2 + 7.99,
                         "\(name): the actions sit below the header with breathing room")
            return rect
        }
        for pair in zip(actionRects, actionRects.dropFirst()) {
            if abs(pair.1.midY - pair.0.midY) < 1 {
                precondition(pair.1.minX - pair.0.maxX >= 7.99, "\(name): adjacent actions remain separate")
            } else {
                precondition(abs(pair.1.midY - pair.0.midY) >= (pair.0.height + pair.1.height) / 2 + 7.99,
                             "\(name): wrapped action groups remain separate")
            }
        }
        let destination = probes["destinations"]!
        let scroll = noticeDescendants(NSScrollView.self, host).first { scroll in
            destination.isDescendant(of: scroll)
        }!
        destination.scrollToVisible(destination.bounds); settleNoticeLayout(host)
        precondition(scroll.contentView.bounds.insetBy(dx: -0.1, dy: -0.1).contains(destination.convert(destination.bounds, to: scroll.contentView)),
                     "\(name): lower editor controls remain reachable by scrolling")
        for (index, role) in ["send", "clear", "pin", "stopped"].enumerated() {
            let probe = probes[role]!
            if size.height >= 240 {
                precondition(probe.convert(probe.bounds, to: host) == actionRects[index], "\(name): scrolling the editor never moves the pinned toolbar")
            }
        }
        print("REMOTE_NOTICE_KEYBOARD_LAYOUT_OK \(name) language=\(portuguese ? "pt" : "en")")
      }
    }
    window.close()
}
