#if os(macOS)
import AppKit
import SwiftUI

/// SwiftUI must own the transform as well as the layout proposal. Scaling a
/// hosting view's AppKit bounds alone leaves SwiftUI's hit regions unscaled.
struct InterfaceScaleLayout<Content: View>: View {
    let factor: CGFloat
    let content: Content
    var body: some View {
        GeometryReader { viewport in
            content
                .frame(width: viewport.size.width / factor, height: viewport.size.height / factor)
                .scaleEffect(factor, anchor: .topLeading)
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
        }
    }
}

private struct InterfaceScaleModifier: ViewModifier {
    @AppStorage(InterfaceScale.key) private var value = 1.0
    func body(content: Content) -> some View {
        InterfaceScaleLayout(factor: CGFloat(InterfaceScale.factor(value)), content: content)
    }
}
private struct InterfaceScaleFixedModifier: ViewModifier {
    let width: CGFloat, height: CGFloat
    @AppStorage(InterfaceScale.key) private var value = 1.0
    func body(content: Content) -> some View {
        let factor = CGFloat(InterfaceScale.factor(value))
        content.frame(width: width, height: height)
            .scaleEffect(factor, anchor: .center)
            .frame(width: width * factor, height: height * factor)
    }
}
extension View {
    func interfaceScaled() -> some View { modifier(InterfaceScaleModifier()) }
    func interfaceScaledFrame(width: CGFloat, height: CGFloat) -> some View {
        modifier(InterfaceScaleFixedModifier(width: width, height: height))
    }
}

/// Only panel sizing belongs to AppKit. Keep content views, responder chains,
/// gesture coordinates and the window chrome in their normal coordinate space.
@MainActor final class InterfaceScaling {
    static let shared = InterfaceScaling()
    private let windows = NSMapTable<NSWindow, ScaledWindow>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var observation: NSObjectProtocol?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        observation = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
    }
    deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    var factor: CGFloat { CGFloat(InterfaceScale.factor(defaults.object(forKey: InterfaceScale.key) as? Double ?? 1)) }
    func register(_ window: NSWindow, preserveFrame: Bool = false) {
        if let existing = windows.object(forKey: window) { existing.apply(factor); return }
        let value = ScaledWindow(window: window, preserveFrame: preserveFrame)
        windows.setObject(value, forKey: window)
        value.apply(factor)
    }
    func refresh() {
        for entry in windows.objectEnumerator()?.allObjects as? [ScaledWindow] ?? [] { entry.apply(factor) }
    }
    @MainActor private final class ScaledWindow {
        weak var window: NSWindow?
        let preserveFrame: Bool
        let originalMinimum: NSSize
        var factor: CGFloat = 1
        init(window: NSWindow, preserveFrame: Bool) {
            self.window = window; self.preserveFrame = preserveFrame; originalMinimum = window.minSize
        }
        func apply(_ next: CGFloat) {
            guard let window, let content = window.contentView else { return }
            let previous = factor; factor = next
            guard !preserveFrame, previous != next else { return }
            let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let decoration = window.frame.height - content.frame.height
            window.minSize = NSSize(width: min(screen.width, originalMinimum.width * next),
                                    height: min(screen.height, originalMinimum.height * next))
            window.setContentSize(NSSize(width: min(screen.width, content.frame.width * next / previous),
                                         height: min(screen.height - decoration, content.frame.height * next / previous)))
            var frame = window.frame
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
    }
}

struct InterfaceScaleAnchor: NSViewRepresentable {
    var preserveFrame = false
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.preserveFrame = preserveFrame; view.attach() }
    final class Anchor: NSView {
        var preserveFrame = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        func attach() {
            guard let window else { return }
            DispatchQueue.main.async { [weak window, weak self] in
                guard let self, let window else { return }
                InterfaceScaling.shared.register(window, preserveFrame: self.preserveFrame)
            }
        }
    }
}
#endif
