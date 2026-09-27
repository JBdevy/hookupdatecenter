import SwiftUI
struct TransportView: View {
    @ObservedObject var show: ShowController
    var body: some View {
        let transport = show.snapshot.transport
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(clockText(transport.position)).font(.system(size: 25, weight: .semibold, design: .monospaced)).foregroundStyle(JarasTheme.green)
                Text("/ \(clockText(show.current?.duration ?? 0))").font(.system(size: 10, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
            }.frame(width: 88)
            Button { show.send(.previous) } label: { Image(systemName: "backward.end.fill") }.accessibilityLabel("Música anterior")
            Button { show.send(transport.playing ? .stop : .play) } label: { Label(LocalizedStringKey(transport.playing ? "Stop" : "Play"), systemImage: transport.playing ? "stop.fill" : "play.fill").frame(minWidth: 56) }.buttonStyle(StageButtonStyle(color: JarasTheme.green, active: transport.playing))
            Button { show.send(.stopAll) } label: { Image(systemName: "stop.fill") }.accessibilityLabel("Parar tudo")
            Button { show.send(.next) } label: { Image(systemName: "forward.end.fill") }.accessibilityLabel("Próxima música")
            Button { show.send(.toggleLoop) } label: { Image(systemName: "repeat") }.buttonStyle(StageButtonStyle(color: JarasTheme.accent, active: transport.loop.enabled)).accessibilityLabel("Loop")
            Rectangle().fill(JarasTheme.line).frame(width: 1, height: 34).padding(.horizontal, 4)
            Button { show.send(transport.subPlay.playing ? .subStop : .subPlay) } label: { Label("Sub Play", systemImage: transport.subPlay.playing ? "pause.fill" : "play.fill") }.buttonStyle(StageButtonStyle(color: JarasTheme.yellow, active: transport.subPlay.playing))
            Text(clockText(transport.subPlay.position)).font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(JarasTheme.yellow).frame(width: 58)
        }
        #if os(macOS)
        .background(TransportSpaceKey(toggle: { show.send(show.isPlaying ? .stopAll : .play) }, toggleSub: { show.send(show.snapshot.transport.subPlay.playing ? .subStop : .subPlay) }))
        #endif
        .buttonStyle(StageButtonStyle()).padding(.vertical, 7).frame(maxWidth: .infinity).background(JarasTheme.panel)
    }
}
struct TransportPreview: PreviewProvider { static var previews: some View { TransportView(show: try! AppContainer(preview: true).show).frame(width: 980) } }

#if os(macOS)
import AppKit
private struct TransportSpaceKey: NSViewRepresentable {
    let toggle: () -> Void
    let toggleSub: () -> Void
    func makeNSView(context: Context) -> TransportKeyView { TransportKeyView() }
    func updateNSView(_ view: TransportKeyView, context: Context) { view.toggle = toggle; view.toggleSub = toggleSub }
}
private final class TransportKeyView: NSView {
    var toggle: (() -> Void)?
    var toggleSub: (() -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.isKeyWindow == true,
                  self.window?.attachedSheet == nil, event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(self.window?.firstResponder is NSTextView),
                  !(self.window?.firstResponder is NSTextField) else { return event }
            if !event.isARepeat {
                if event.modifierFlags.contains(.shift) { self.toggleSub?() }
                else { self.toggle?() }
            }
            return nil
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
#endif
