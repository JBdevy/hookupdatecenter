#if os(macOS)
import SwiftUI
import AppKit
struct TrialTitlebar: View {
    @ObservedObject var auth: AuthService
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            TrialTitlebarContent(text: auth.licenseTitle)
        }
    }
}
private struct TrialTitlebarContent: NSViewRepresentable {
    let text: String?
    func makeNSView(context: Context) -> TrialTitlebarAnchor { TrialTitlebarAnchor() }
    func updateNSView(_ view: TrialTitlebarAnchor, context: Context) { view.text = text; view.update() }
    static func dismantleNSView(_ view: TrialTitlebarAnchor, coordinator: ()) { view.detach() }
}
private final class TrialTitlebarLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
private final class TrialTitlebarAnchor: NSView {
    var text: String?
    private let label = TrialTitlebarLabel(labelWithString: "")
    private weak var mountedWindow: NSWindow?
    private var observer: NSObjectProtocol?
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.identifier = NSUserInterfaceItemIdentifier("catlive.trialTitle")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor(red: 84/255, green: 1, blue: 147/255, alpha: 1)
        label.alignment = .center; label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = text
        label.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); update() }
    func update() {
        if mountedWindow !== window {
            detach(); mountedWindow = window
            if let window {
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in self?.layoutLabel() }
            }
        }
        let visible = text != nil
        let changed = label.isHidden == visible || label.stringValue != (text ?? "")
        label.stringValue = text ?? ""; label.toolTip = text; label.isHidden = !visible
        layoutLabel()
        if changed, let window { NotificationCenter.default.post(name: .catliveTrialTitleChanged, object: window) }
    }
    private func layoutLabel() {
        guard let window = mountedWindow, let button = window.standardWindowButton(.closeButton), let titlebar = button.superview else { return }
        if label.superview !== titlebar { label.removeFromSuperview(); titlebar.addSubview(label) }
        let width = min(560, max(160, titlebar.bounds.width - 400))
        let frame = NSRect(x: floor(titlebar.bounds.midX - width / 2), y: floor(button.frame.midY - 11), width: width, height: 22)
        if label.frame != frame {
            label.frame = frame
            NotificationCenter.default.post(name: .catliveTrialTitleChanged, object: window)
        }
    }
    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        let previous = mountedWindow; mountedWindow = nil; label.removeFromSuperview()
        if let previous { NotificationCenter.default.post(name: .catliveTrialTitleChanged, object: previous) }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
extension Notification.Name { static let catliveTrialTitleChanged = Notification.Name("catlive.trialTitleChanged") }
#endif
