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
    func jarasHelp(_ text: String) -> some View {
        modifier(LocalizedAccessibilityHint(text: text))
    }
}
/// Keep control descriptions available to accessibility without hover popovers
/// or extra AppKit views participating in layout and tracking.
private struct LocalizedAccessibilityHint: ViewModifier {
    let text: String
    @Environment(\.locale) private var locale
    func body(content: Content) -> some View {
        let localized = JarasLocalization.string(text, language: locale.identifier)
        content.accessibilityHint(Text(verbatim: localized))
    }
}

#if os(macOS)
import AppKit

extension View {
    @ViewBuilder func desktopIconTooltip(_ title: String?) -> some View {
        if let title { background(DesktopIconTooltip(title: title).accessibilityHidden(true)) }
        else { self }
    }
}

private struct DesktopIconTooltip: NSViewRepresentable {
    let title: String
    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> HoverView { HoverView() }
    func updateNSView(_ view: HoverView, context: Context) {
        view.title = JarasLocalization.string(title, language: locale.identifier)
    }
    static func dismantleNSView(_ view: HoverView, coordinator: ()) { view.hide() }

    final class HoverView: NSView {
        var title = ""
        private var area: NSTrackingArea?
        private var pending: Task<Void, Never>?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard area == nil else { return }
            let tracking = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(tracking)
            area = tracking
        }
        override func mouseEntered(with event: NSEvent) {
            pending?.cancel()
            pending = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 550_000_000) } catch { return }
                guard let self, let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor,
                      window.attachedSheet == nil, !NativeTimelineInputGate.shared.isBlocked(window) else { return }
                let point = window.mouseLocationOutsideOfEventStream
                guard visibleRect.contains(convert(point, from: nil)), NSEvent.pressedMouseButtons == 0 else { return }
                DesktopIconTooltipWindow.shared.present(title, owner: self, at: window.convertPoint(toScreen: point))
            }
        }
        override func mouseExited(with event: NSEvent) { hide() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { hide() }
            super.viewWillMove(toWindow: newWindow)
        }
        func hide() {
            pending?.cancel(); pending = nil
            DesktopIconTooltipWindow.shared.hide(owner: self)
        }
    }
}

@MainActor final class DesktopIconTooltipWindow {
    static let shared = DesktopIconTooltipWindow()
    private weak var owner: NSView?
    private let bubble = DesktopIconTooltipBubble()
    private let panel: NSPanel
    private var observation: NSObjectProtocol?
    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = bubble; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = true
        panel.level = .popUpMenu; panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        observation = NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        }
    }
    func present(_ text: String, owner: NSView, at point: NSPoint) {
        self.owner = owner; bubble.text = text
        let width = max(96, ceil((text as NSString).size(withAttributes: [.font: DesktopIconTooltipBubble.font]).width) + 18)
        let screen = owner.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var frame = NSRect(x: point.x + 12, y: point.y + 8, width: width, height: 22)
        if frame.maxY > screen.maxY { frame.origin.y = point.y - 30 }
        frame.origin.x = min(max(screen.minX + 4, frame.minX), screen.maxX - width - 4)
        panel.setFrame(frame, display: false); bubble.needsDisplay = true
        panel.orderFront(nil)
    }
    func hide(owner: NSView) { if self.owner === owner { panel.orderOut(nil); self.owner = nil } }
}
private final class DesktopIconTooltipBubble: NSView {
    static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    var text = ""
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor(calibratedWhite: 0.13, alpha: 0.96).setFill(); path.fill()
        NSColor(calibratedWhite: 0.48, alpha: 1).setStroke(); path.lineWidth = 1; path.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (text as NSString).draw(in: bounds.insetBy(dx: 4, dy: 2), withAttributes: [
            .font: Self.font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph
        ])
    }
}
#endif
