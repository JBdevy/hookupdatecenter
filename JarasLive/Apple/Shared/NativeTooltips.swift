import SwiftUI

/// AppKit menus use the app preference, independently of the system language.
enum JarasLocalization {
    // Language resources are immutable for the lifetime of the app. Keep the
    // resolved bundles while still reading the current language on each call.
    private static let englishBundle = localizedBundle("en")
    private static let portugueseBundle = localizedBundle("pt-BR")
    private static func localizedBundle(_ identifier: String) -> Bundle {
        Bundle.main.path(forResource: identifier, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
    static func bundle(language: String? = nil) -> Bundle {
        let selected = (language ?? UserDefaults.standard.string(forKey: "jaras.language") ?? "en").replacingOccurrences(of: "_", with: "-")
        return selected.lowercased().hasPrefix("pt") ? portugueseBundle : englishBundle
    }
    static func string(_ key: String, language: String? = nil) -> String {
        bundle(language: language).localizedString(forKey: key, value: key, table: nil)
    }
}
extension View {
    @ViewBuilder func jarasHelp(_ text: String) -> some View {
        #if os(macOS)
        modifier(LocalizedTooltip(text: text))
        #else
        help(LocalizedStringKey(text))
        #endif
    }
}
#if os(macOS)
/// One shared panel and one delayed task for the hovered control. No per-control
/// native overlay, polling loop or tooltip timer remains active when idle.
private struct LocalizedTooltip: ViewModifier {
    let text: String
    @Environment(\.locale) private var locale
    @State private var owner = UUID()
    func body(content: Content) -> some View {
        content.accessibilityHint(Text(verbatim: JarasLocalization.string(text, language: locale.identifier)))
            .onContinuousHover { phase in
                switch phase {
                case .active: JarasTooltipPresenter.shared.schedule(owner: owner, text: JarasLocalization.string(text, language: locale.identifier))
                case .ended: JarasTooltipPresenter.shared.hide(owner: owner)
                }
            }.onDisappear { JarasTooltipPresenter.shared.hide(owner: owner) }
    }
}
@MainActor private final class JarasTooltipPresenter {
    static let shared = JarasTooltipPresenter()
    private var owner: UUID?
    private var pending: DispatchWorkItem?
    private var monitor: Any?
    private var panel: NSPanel?
    func schedule(owner: UUID, text: String) {
        // Pointer motion re-arms a tooltip dismissed by a click, without
        // restarting its delay on every mouse movement inside the control.
        if self.owner == owner && (pending != nil || panel?.isVisible == true) { return }
        hide()
        guard !text.isEmpty else { return }
        self.owner = owner
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.owner == owner else { return }
            self.pending = nil
            guard NSApp.isActive else { return }
            self.present(text)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            self?.hide(); return event
        }
    }
    func hide(owner: UUID? = nil) {
        if let owner, self.owner != owner { return }
        pending?.cancel(); pending = nil; self.owner = nil
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    private func present(_ text: String) {
        let panel = self.panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = true; panel.level = .statusBar
        panel.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.98)
        panel.hasShadow = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12); label.textColor = .white
        let width = min(420, max(30, label.intrinsicContentSize.width))
        label.preferredMaxLayoutWidth = width
        let height = max(17, label.fittingSize.height)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width + 16, height: height + 10))
        label.frame = NSRect(x: 8, y: 5, width: width, height: height); container.addSubview(label)
        panel.contentView = container
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = max(screen.minX, min(point.x + 12, screen.maxX - container.frame.width))
        var y = point.y - container.frame.height - 16
        if y < screen.minY { y = point.y + 18 }
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: container.frame.size), display: true)
        panel.orderFrontRegardless()
    }
}
#endif
